import Foundation
import Testing
@testable import Resizer

@Suite("FFmpeg transcoding service")
struct FFmpegTranscodingServiceTests {
    @Test("Preflight validates the typed command and actual capabilities")
    func preflightUsesBuilderAndCapabilities() async throws {
        let request = try makeRequest()
        let builder = TranscodingCommandBuilderStub(arguments: ["-typed"])
        let runner = TranscodingProcessRunnerStub(instructions: [])
        let fileAccess = TranscodingFileAccessStub(metadata: nil)
        let service = try makeService(
            runner: runner,
            builder: builder,
            capabilities: supportedCapabilities(),
            fileAccess: fileAccess
        )

        try await service.preflight(request)

        let commandRequests = await builder.recordedRequests()
        #expect(commandRequests.count == 1)
        #expect(commandRequests.first?.jobID == request.jobID)
        #expect(await runner.recordedRequests().isEmpty)

        let unavailable = FFmpegCapabilities(
            decoders: ["h264", "hevc", "aac"],
            encoders: ["aac"],
            filters: ["scale", "aresample"],
            demuxers: ["mov", "mp4"],
            muxers: ["mp4"],
            inputProtocols: ["file"],
            outputProtocols: ["fd", "pipe"]
        )
        let rejectedService = try makeService(
            runner: runner,
            builder: TranscodingCommandBuilderStub(arguments: ["-typed"]),
            capabilities: unavailable,
            fileAccess: fileAccess
        )

        do {
            try await rejectedService.preflight(request)
            Issue.record("Expected capability preflight to fail")
        } catch let error as FFmpegPreflightError {
            #expect(
                error == .unavailableCapability(
                    category: .encoder,
                    name: "h264_videotoolbox"
                )
            )
        }
    }

    @Test("Success streams progress serially and validates the temp file")
    func successfulTranscode() async throws {
        let request = try makeRequest()
        let arguments = ["-typed", "значение"]
        let builder = TranscodingCommandBuilderStub(arguments: arguments)
        let runner = TranscodingProcessRunnerStub(
            instructions: successfulInstructions()
        )
        let fileAccess = TranscodingFileAccessStub(
            metadata: FileMetadata(
                byteCount: 2_048,
                isDirectory: false,
                identity: FileIdentity(device: 1, inode: 2)
            )
        )
        let observer = TranscodingProgressObserver()
        let service = try makeService(
            runner: runner,
            builder: builder,
            capabilities: supportedCapabilities(),
            fileAccess: fileAccess
        )

        let reservation = try makeReservation(for: request)
        let result = try await service.transcode(
            request,
            reservation: reservation
        ) { progress in
            await observer.record(progress)
        }

        #expect(result.byteCount == 2_048)
        #expect(result.temporaryMetadata.identity == FileIdentity(
            device: 1,
            inode: 2
        ))
        #expect(
            await observer.processedMicroseconds() == [
                5_000_000,
                10_000_000,
            ]
        )
        #expect(await observer.maximumConcurrentCallbacks() == 1)

        let processRequest = try #require(
            await runner.recordedRequests().first
        )
        #expect(processRequest.executableURL.path == "/Bundle/ffmpeg")
        #expect(processRequest.arguments == arguments)
        #expect(processRequest.environment["LC_ALL"] == "C")
        #expect(processRequest.environment["LANG"] == "C")
        #expect(
            processRequest.diagnosticByteLimit
                == FFmpegTranscodingService.diagnosticByteLimit
        )
        #expect(
            processRequest.eventBufferCapacity
                == ProcessRequest.maximumEventBufferCapacity
        )
        #expect(
            processRequest.cancellationPolicy.standardInput
                == .cancellationMessage(Data("q\n".utf8))
        )
        #expect(
            processRequest.cancellationPolicy.gracefulInputWait
                == FFmpegTranscodingService.gracefulCancellationWait
        )
        #expect(
            processRequest.cancellationPolicy.interruptWait
                == FFmpegTranscodingService.interruptCancellationWait
        )
        #expect(
            processRequest.cancellationPolicy.terminateWait
                == FFmpegTranscodingService.terminateCancellationWait
        )
        #expect(
            processRequest.standardOutputDestination
                == .stream
        )
        #expect(processRequest.inheritedFileDescriptor?.childDescriptor == 3)
        #expect(
            processRequest.inheritedFileDescriptor?.lease
                === reservation.lease
        )

        #expect(
            await fileAccess.recordedScopes() == [[
                request.inputURL,
                request.temporaryOutputURL.deletingLastPathComponent(),
            ]]
        )
        #expect(
            await fileAccess.recordedMetadataURLs()
                == [request.temporaryOutputURL]
        )
    }

    @Test("A reservation for another plan fails before process launch")
    func reservationMismatchFailsClosed() async throws {
        let request = try makeRequest()
        let runner = TranscodingProcessRunnerStub(instructions: [])
        let service = try makeService(
            runner: runner,
            builder: TranscodingCommandBuilderStub(arguments: ["-typed"]),
            capabilities: supportedCapabilities(),
            fileAccess: TranscodingFileAccessStub(metadata: nil)
        )
        let otherRequest = try makeRequest(
            jobID: UUID(
                uuidString: "BBBBBBBB-CCCC-4DDD-8EEE-FFFFFFFFFFFF"
            )!
        )
        let mismatchedReservation = try makeReservation(for: otherRequest)

        do {
            _ = try await service.transcode(
                request,
                reservation: mismatchedReservation,
                onProgress: { _ in }
            )
            Issue.record("Expected mismatched reservation rejection")
        } catch let error as FFmpegTranscodingServiceError {
            #expect(error == .invalidTemporaryReservation)
        }
        #expect(await runner.recordedRequests().isEmpty)
    }

    @Test("A zero exit requires a final progress=end marker")
    func successfulExitRequiresProgressEnd() async throws {
        let request = try makeRequest()
        let runner = TranscodingProcessRunnerStub(
            instructions: [
                .standardOutput(
                    Data(
                        "out_time_us=5000000\nprogress=continue\n".utf8
                    )
                ),
                .terminated(status: 0, reason: .exit, diagnostic: Data()),
            ]
        )
        let fileAccess = TranscodingFileAccessStub(
            metadata: FileMetadata(byteCount: 2_048, isDirectory: false)
        )
        let service = try makeService(
            runner: runner,
            builder: TranscodingCommandBuilderStub(arguments: ["-typed"]),
            capabilities: supportedCapabilities(),
            fileAccess: fileAccess
        )

        do {
            _ = try await service.transcode(
                request,
                reservation: makeReservation(for: request)
            ) { _ in }
            Issue.record("Expected missing progress=end to fail")
        } catch let error as FFmpegTranscodingServiceError {
            #expect(error == .progressParsing(.missingEndMarker))
        }
        #expect(await fileAccess.recordedMetadataURLs().isEmpty)
    }

    @Test("A nonzero process diagnostic wins an EOF progress error")
    func processFailureWinsProgressEOFError() async throws {
        let request = try makeRequest()
        let diagnostic = Data("encoder unavailable\n".utf8)
        let runner = TranscodingProcessRunnerStub(
            instructions: [
                .standardOutput(
                    Data(
                        "out_time_us=N/A\nout_time_ms=N/A\n"
                            .appending("out_time=N/A\nprogress=end\n")
                            .utf8
                    )
                ),
                .standardError(diagnostic),
                .terminated(
                    status: 1,
                    reason: .exit,
                    diagnostic: diagnostic
                ),
            ]
        )
        let fileAccess = TranscodingFileAccessStub(metadata: nil)
        let service = try makeService(
            runner: runner,
            builder: TranscodingCommandBuilderStub(arguments: ["-typed"]),
            capabilities: supportedCapabilities(),
            fileAccess: fileAccess
        )

        do {
            _ = try await service.transcode(
                request,
                reservation: makeReservation(for: request)
            ) { _ in }
            Issue.record("Expected FFmpeg failure")
        } catch let error as FFmpegTranscodingServiceError {
            guard case .processFailed(
                let termination,
                let diagnosticTail
            ) = error else {
                Issue.record("Unexpected error: \(error)")
                return
            }
            #expect(termination.status == 1)
            #expect(termination.reason == .exit)
            #expect(diagnosticTail.data == diagnostic)
        }
        #expect(await fileAccess.recordedMetadataURLs().isEmpty)
    }

    @Test("The temporary result must exist and be a nonempty regular file")
    func validatesTemporaryMetadata() async throws {
        let request = try makeRequest()

        let missingService = try makeService(
            runner: TranscodingProcessRunnerStub(
                instructions: successfulInstructions()
            ),
            builder: TranscodingCommandBuilderStub(arguments: ["-typed"]),
            capabilities: supportedCapabilities(),
            fileAccess: TranscodingFileAccessStub(metadata: nil)
        )
        do {
            _ = try await missingService.transcode(
                request,
                reservation: makeReservation(for: request)
            ) { _ in }
            Issue.record("Expected a missing temp output to fail")
        } catch let error as FFmpegTranscodingServiceError {
            #expect(error == .temporaryOutputMissing)
        }

        let emptyService = try makeService(
            runner: TranscodingProcessRunnerStub(
                instructions: successfulInstructions()
            ),
            builder: TranscodingCommandBuilderStub(arguments: ["-typed"]),
            capabilities: supportedCapabilities(),
            fileAccess: TranscodingFileAccessStub(
                metadata: FileMetadata(byteCount: 0, isDirectory: false)
            )
        )
        do {
            _ = try await emptyService.transcode(
                request,
                reservation: makeReservation(for: request)
            ) { _ in }
            Issue.record("Expected an empty temp output to fail")
        } catch let error as FFmpegTranscodingServiceError {
            #expect(error == .invalidTemporaryOutput)
        }
    }

    @Test("Cancellation for an inactive job cannot poison a later execution")
    func inactiveCancellationIsNoOp() async throws {
        let request = try makeRequest()
        let runner = TranscodingProcessRunnerStub(
            instructions: successfulInstructions()
        )
        let builder = TranscodingCommandBuilderStub(arguments: ["-typed"])
        let service = try makeService(
            runner: runner,
            builder: builder,
            capabilities: supportedCapabilities(),
            fileAccess: TranscodingFileAccessStub(
                metadata: FileMetadata(
                    byteCount: 2_048,
                    isDirectory: false,
                    identity: FileIdentity(device: 1, inode: 3)
                )
            )
        )

        await service.cancel(jobID: request.jobID)

        let result = try await service.transcode(
            request,
            reservation: makeReservation(
                for: request,
                identity: FileIdentity(device: 1, inode: 3)
            )
        ) { _ in }

        #expect(result.byteCount == 2_048)
        #expect(await runner.recordedRequests().count == 1)
        #expect(await builder.recordedRequests().count == 1)
    }

    @Test("Duplicate active job IDs are rejected and external cancel wins")
    func duplicateAndExternalCancellation() async throws {
        let request = try makeRequest()
        let runner = TranscodingProcessRunnerStub(
            instructions: [],
            holdOpen: true
        )
        let service = try makeService(
            runner: runner,
            builder: TranscodingCommandBuilderStub(arguments: ["-typed"]),
            capabilities: supportedCapabilities(),
            fileAccess: TranscodingFileAccessStub(metadata: nil)
        )
        let first = Task {
            try await service.transcode(
                request,
                reservation: self.makeReservation(for: request)
            ) { _ in }
        }
        await runner.waitUntilStarted()

        do {
            _ = try await service.transcode(
                request,
                reservation: makeReservation(for: request)
            ) { _ in }
            Issue.record("Expected duplicate job rejection")
        } catch let error as FFmpegTranscodingServiceError {
            #expect(error == .duplicateJob(request.jobID))
        }

        await service.cancel(jobID: request.jobID)
        try await expectCancellation(first)
        #expect(!(await runner.recordedCancellationRequests()).isEmpty)
    }

    @Test("Cancellation is resent after delayed process registration")
    func cancellationDuringStartRegistration() async throws {
        let request = try makeRequest()
        let runner = TranscodingProcessRunnerStub(
            instructions: [],
            holdOpen: true,
            delayRegistration: true
        )
        let service = try makeService(
            runner: runner,
            builder: TranscodingCommandBuilderStub(arguments: ["-typed"]),
            capabilities: supportedCapabilities(),
            fileAccess: TranscodingFileAccessStub(metadata: nil)
        )
        let operation = Task {
            try await service.transcode(
                request,
                reservation: self.makeReservation(for: request)
            ) { _ in }
        }
        await runner.waitUntilStarted()

        await service.cancel(jobID: request.jobID)
        await runner.releaseStart()

        try await expectCancellation(operation)
        let cancellationIDs = await runner.recordedCancellationRequests()
        #expect(cancellationIDs.count >= 2)
        #expect(Set(cancellationIDs).count == 1)
    }

    @Test("Task cancellation tears down the registered execution")
    func taskCancellation() async throws {
        let request = try makeRequest()
        let runner = TranscodingProcessRunnerStub(
            instructions: [],
            holdOpen: true
        )
        let service = try makeService(
            runner: runner,
            builder: TranscodingCommandBuilderStub(arguments: ["-typed"]),
            capabilities: supportedCapabilities(),
            fileAccess: TranscodingFileAccessStub(metadata: nil)
        )
        let operation = Task {
            try await service.transcode(
                request,
                reservation: self.makeReservation(for: request)
            ) { _ in }
        }
        await runner.waitUntilStarted()

        operation.cancel()

        try await expectCancellation(operation)
        #expect(!(await runner.recordedCancellationRequests()).isEmpty)
    }

    @Test("Invalid executable and terminal event identity fail closed")
    func invalidContracts() async throws {
        let runner = TranscodingProcessRunnerStub(instructions: [])
        let builder = TranscodingCommandBuilderStub(arguments: ["-typed"])
        let fileAccess = TranscodingFileAccessStub(metadata: nil)

        #expect(throws: FFmpegTranscodingServiceError.invalidExecutableURL) {
            try FFmpegTranscodingService(
                executableURL: URL(string: "https://example.com/ffmpeg")!,
                processRunner: runner,
                commandBuilder: builder,
                capabilityProvider: FixedFFmpegCapabilityProvider(
                    value: supportedCapabilities()
                ),
                fileAccess: fileAccess
            )
        }

        let request = try makeRequest()
        let mismatchedRunner = TranscodingProcessRunnerStub(
            instructions: [
                .standardOutput(
                    Data("out_time_us=1\nprogress=end\n".utf8)
                ),
                .terminated(
                    status: 0,
                    reason: .exit,
                    diagnostic: Data(),
                    executionID: ProcessExecutionID()
                ),
            ]
        )
        let service = try makeService(
            runner: mismatchedRunner,
            builder: builder,
            capabilities: supportedCapabilities(),
            fileAccess: fileAccess
        )
        do {
            _ = try await service.transcode(
                request,
                reservation: makeReservation(for: request)
            ) { _ in }
            Issue.record("Expected invalid terminal event identity")
        } catch let error as FFmpegTranscodingServiceError {
            #expect(error == .invalidProcessEventSequence)
        }
    }

    private func makeService(
        runner: any ProcessRunning,
        builder: any CommandBuilding,
        capabilities: FFmpegCapabilities,
        fileAccess: any FileAccessing
    ) throws -> FFmpegTranscodingService {
        try FFmpegTranscodingService(
            executableURL: URL(fileURLWithPath: "/Bundle/ffmpeg"),
            processRunner: runner,
            commandBuilder: builder,
            capabilityProvider: FixedFFmpegCapabilityProvider(
                value: capabilities
            ),
            fileAccess: fileAccess
        )
    }

    private func makeRequest(
        jobID: UUID = UUID(
            uuidString: "AAAAAAAA-BBBB-4CCC-8DDD-EEEEEEEEEEEE"
        )!
    ) throws -> TranscodeRequest {
        let plan = try makeOutputPlan(jobID: jobID)
        let mediaInfo = try TestFixtures.mediaInfo()
        return TranscodeRequest(
            outputPlan: plan,
            mediaInfo: mediaInfo,
            recipe: try AutomaticCompressionPolicy().recipe(for: mediaInfo)
        )
    }

    private func makeReservation(
        for request: TranscodeRequest,
        identity: FileIdentity = FileIdentity(device: 1, inode: 2)
    ) throws -> TemporaryOutputReservation {
        try TemporaryOutputReservation(
            plan: makeOutputPlan(jobID: request.jobID),
            metadata: FileMetadata(
                byteCount: 0,
                isDirectory: false,
                identity: identity
            )
        )
    }

    private func makeOutputPlan(jobID: UUID) throws -> OutputPlan {
        let outputDirectory = URL(
            fileURLWithPath: "/tmp/FFmpegTranscodingServiceTests",
            isDirectory: true
        )
        let planningRequest = OutputPlanningRequest(
            jobID: jobID,
            inputURL: URL(fileURLWithPath: "/tmp/source.mov"),
            policy: try OutputPolicy(directoryURL: outputDirectory)
        )
        return try OutputPlan(
            request: planningRequest,
            temporaryURL: outputDirectory.appendingPathComponent(
                "source.\(jobID.uuidString.lowercased()).partial.mp4"
            ),
            finalURL: outputDirectory.appendingPathComponent("source.mp4")
        )
    }

    private func supportedCapabilities() -> FFmpegCapabilities {
        FFmpegCapabilities(
            decoders: ["h264", "aac"],
            encoders: ["h264_videotoolbox", "aac"],
            filters: ["scale", "aresample"],
            demuxers: ["mov", "mp4"],
            muxers: ["mp4"],
            inputProtocols: ["file"],
            outputProtocols: ["fd", "pipe"]
        )
    }

    private func successfulInstructions() -> [TranscodingRunnerInstruction] {
        [
            .standardOutput(
                Data(
                    "frame=150\nout_time_us=5000000\nfps=30\n".utf8
                )
            ),
            .standardOutput(
                Data("speed=1.5x\nprogress=continue\n".utf8)
            ),
            .standardOutput(
                Data(
                    "out_time_us=N/A\nout_time_ms=N/A\n"
                        .appending("out_time=N/A\nprogress=continue\n")
                        .utf8
                )
            ),
            .standardOutput(
                Data(
                    "frame=300\nout_time_us=10000000\nfps=30\n"
                        .appending("speed=1.4x\nprogress=end\n")
                        .utf8
                )
            ),
            .terminated(status: 0, reason: .exit, diagnostic: Data()),
        ]
    }

    private func expectCancellation(
        _ operation: Task<TranscodeResult, any Error>
    ) async throws {
        do {
            _ = try await ProcessHarnessFixture.withTimeout {
                try await operation.value
            }
            Issue.record("Expected CancellationError")
        } catch is CancellationError {
            // Expected.
        }
    }
}

private actor TranscodingCommandBuilderStub: CommandBuilding {
    private let value: [String]
    private var requests: [TranscodeCommandRequest] = []

    init(arguments: [String]) {
        value = arguments
    }

    func arguments(
        for request: TranscodeCommandRequest
    ) async throws -> [String] {
        requests.append(request)
        return value
    }

    func recordedRequests() -> [TranscodeCommandRequest] {
        requests
    }
}

private actor TranscodingFileAccessStub: FileAccessing {
    private let metadataValue: FileMetadata?
    private var scopes: [[URL]] = []
    private var metadataURLs: [URL] = []

    init(metadata: FileMetadata?) {
        metadataValue = metadata
    }

    func withSecurityScopedAccess<Result: Sendable>(
        to selectedURLs: [URL],
        perform operation: @Sendable () async throws -> Result
    ) async throws -> Result {
        scopes.append(selectedURLs)
        return try await operation()
    }

    func metadata(at url: URL) async throws -> FileMetadata? {
        metadataURLs.append(url)
        return metadataValue
    }

    func reserveTemporaryOutput(
        _ plan: OutputPlan
    ) async throws -> TemporaryOutputReservation {
        try TemporaryOutputReservation(
            plan: plan,
            metadata: FileMetadata(
                byteCount: 0,
                isDirectory: false,
                identity: FileIdentity(device: 1, inode: 2)
            )
        )
    }

    func commitWithoutReplacing(
        _ plan: OutputPlan,
        reservation: TemporaryOutputReservation,
        expectedTemporaryMetadata: FileMetadata
    ) async throws {
        _ = plan
        _ = reservation
        _ = expectedTemporaryMetadata
    }

    func cleanupTemporaryOutput(
        _ plan: OutputPlan,
        reservation: TemporaryOutputReservation,
        expectedTemporaryMetadata: FileMetadata?
    ) async throws {
        _ = plan
        _ = reservation
        _ = expectedTemporaryMetadata
    }

    func recordedScopes() -> [[URL]] {
        scopes
    }

    func recordedMetadataURLs() -> [URL] {
        metadataURLs
    }
}

private actor TranscodingProgressObserver {
    private var values: [Int64] = []
    private var activeCallbackCount = 0
    private var maximumActiveCallbackCount = 0

    func record(_ progress: TranscodeProgress) async {
        activeCallbackCount += 1
        maximumActiveCallbackCount = max(
            maximumActiveCallbackCount,
            activeCallbackCount
        )
        await Task.yield()
        values.append(progress.processedMicroseconds)
        activeCallbackCount -= 1
    }

    func processedMicroseconds() -> [Int64] {
        values
    }

    func maximumConcurrentCallbacks() -> Int {
        maximumActiveCallbackCount
    }
}

private nonisolated enum TranscodingRunnerInstruction: Sendable {
    case standardOutput(Data)
    case standardError(Data)
    case terminated(
        status: Int32,
        reason: ProcessExitReason,
        diagnostic: Data,
        executionID: ProcessExecutionID? = nil
    )
}

private actor TranscodingProcessRunnerStub: ProcessRunning {
    private let instructions: [TranscodingRunnerInstruction]
    private let holdOpen: Bool
    private let delayRegistration: Bool

    private var requests: [ProcessRequest] = []
    private var cancellationRequests: [ProcessExecutionID] = []
    private var continuations: [
        ProcessExecutionID:
            AsyncThrowingStream<ProcessEvent, any Error>.Continuation
    ] = [:]
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var registrationWaiters: [CheckedContinuation<Void, Never>] = []
    private var registrationWasReleased: Bool

    init(
        instructions: [TranscodingRunnerInstruction],
        holdOpen: Bool = false,
        delayRegistration: Bool = false
    ) {
        self.instructions = instructions
        self.holdOpen = holdOpen
        self.delayRegistration = delayRegistration
        registrationWasReleased = !delayRegistration
    }

    func start(
        _ request: ProcessRequest
    ) async throws -> AsyncThrowingStream<ProcessEvent, any Error> {
        requests.append(request)
        let waiters = startWaiters
        startWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }

        if delayRegistration, !registrationWasReleased {
            await withCheckedContinuation { continuation in
                registrationWaiters.append(continuation)
            }
        }

        let pair = AsyncThrowingStream<ProcessEvent, any Error>.makeStream(
            bufferingPolicy: .unbounded
        )
        for instruction in instructions {
            switch instruction {
            case .standardOutput(let data):
                _ = pair.continuation.yield(.standardOutput(data))
            case .standardError(let data):
                _ = pair.continuation.yield(.standardError(data))
            case .terminated(
                let status,
                let reason,
                let diagnostic,
                let executionID
            ):
                _ = pair.continuation.yield(
                    .terminated(
                        try processResult(
                            executionID: executionID ?? request.id,
                            status: status,
                            reason: reason,
                            diagnostic: diagnostic,
                            wasCancellationRequested: false
                        )
                    )
                )
            }
        }

        if holdOpen {
            continuations[request.id] = pair.continuation
        } else {
            pair.continuation.finish()
        }
        return pair.stream
    }

    func cancel(executionID: ProcessExecutionID) async {
        cancellationRequests.append(executionID)
        guard let continuation = continuations.removeValue(
            forKey: executionID
        ) else {
            return
        }
        let result = try? processResult(
            executionID: executionID,
            status: 255,
            reason: .exit,
            diagnostic: Data("cancelled\n".utf8),
            wasCancellationRequested: true
        )
        if let result {
            _ = continuation.yield(.terminated(result))
        }
        continuation.finish()
    }

    func waitUntilStarted() async {
        guard requests.isEmpty else { return }
        await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }

    func releaseStart() {
        registrationWasReleased = true
        let waiters = registrationWaiters
        registrationWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
    }

    func recordedRequests() -> [ProcessRequest] {
        requests
    }

    func recordedCancellationRequests() -> [ProcessExecutionID] {
        cancellationRequests
    }

    private func processResult(
        executionID: ProcessExecutionID,
        status: Int32,
        reason: ProcessExitReason,
        diagnostic: Data,
        wasCancellationRequested: Bool
    ) throws -> ProcessResult {
        ProcessResult(
            executionID: executionID,
            processIdentifier: 42,
            termination: ProcessTerminationStatus(
                status: status,
                reason: reason
            ),
            diagnosticTail: try BoundedData(
                data: diagnostic,
                byteLimit: 1_024,
                wasTruncated: false
            ),
            wasCancellationRequested: wasCancellationRequested,
            lastCancellationStep: wasCancellationRequested
                ? .gracefulInput
                : nil
        )
    }
}
