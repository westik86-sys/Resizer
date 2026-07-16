import Foundation
import Testing
@testable import Resizer

@Suite("Bundled FFmpeg capability preflight")
struct FFmpegCapabilitiesTests {
    @Test("Capability tables map into normalized name sets")
    func parsesCapabilityTables() throws {
        let value = try parseCapabilities()

        #expect(value.decoders == ["h264", "hevc", "aac"])
        #expect(value.encoders == ["h264_videotoolbox", "aac"])
        #expect(value.filters == ["scale", "aresample"])
        #expect(value.demuxers == ["mov", "mp4", "m4a"])
        #expect(value.muxers == ["mov", "mp4"])
        #expect(value.inputProtocols == ["fd", "file", "pipe"])
        #expect(value.outputProtocols == ["fd", "file", "pipe"])
    }

    @Test("Invalid UTF-8 or an empty capability section fails closed")
    func rejectsInvalidCapabilityOutput() throws {
        let parser = FFmpegCapabilityParser()
        #expect(
            throws: FFmpegCapabilityClientError.invalidCapabilityOutput
        ) {
            try parser.parse(
                decoders: Data([0xff]),
                encoders: encoderOutput,
                filters: filterOutput,
                demuxers: demuxerOutput,
                muxers: muxerOutput,
                protocols: protocolOutput
            )
        }
        #expect(
            throws: FFmpegCapabilityClientError.invalidCapabilityOutput
        ) {
            try parser.parse(
                decoders: Data(),
                encoders: encoderOutput,
                filters: filterOutput,
                demuxers: demuxerOutput,
                muxers: muxerOutput,
                protocols: protocolOutput
            )
        }
    }

    @Test("The audited H.264/HEVC/AAC profile accepts H.264 input")
    func acceptsSupportedRequest() throws {
        let mediaInfo = try TestFixtures.mediaInfo()
        let request = try makeRequest(
            mediaInfo: mediaInfo,
            recipe: automaticRecipe(for: mediaInfo)
        )

        try FFmpegPreflightValidator().validate(
            request,
            capabilities: parseCapabilities()
        )
    }

    @Test("The audited profile accepts SDR HEVC input")
    func acceptsHEVCInput() throws {
        let mediaInfo = try videoOnlyMediaInfo(codecName: "hevc")
        let request = try makeRequest(
            mediaInfo: mediaInfo,
            recipe: automaticRecipe(for: mediaInfo)
        )

        try FFmpegPreflightValidator().validate(
            request,
            capabilities: parseCapabilities()
        )
    }

    @Test("HEVC input fails closed when the bundled decoder is unavailable")
    func rejectsHEVCWithoutBundledDecoder() throws {
        let supported = try parseCapabilities()
        let capabilities = FFmpegCapabilities(
            decoders: supported.decoders.subtracting(["hevc"]),
            encoders: supported.encoders,
            filters: supported.filters,
            demuxers: supported.demuxers,
            muxers: supported.muxers,
            inputProtocols: supported.inputProtocols,
            outputProtocols: supported.outputProtocols
        )
        let mediaInfo = try videoOnlyMediaInfo(codecName: "hevc")
        let request = try makeRequest(
            mediaInfo: mediaInfo,
            recipe: automaticRecipe(for: mediaInfo)
        )

        #expect(
            throws: FFmpegPreflightError.unsupportedDecoder(
                streamIndex: 3,
                codecName: "hevc"
            )
        ) {
            try FFmpegPreflightValidator().validate(
                request,
                capabilities: capabilities
            )
        }
    }

    @Test("The descriptor output profile requires both fd and pipe protocols")
    func requiresDescriptorOutputProtocols() throws {
        let mediaInfo = try TestFixtures.mediaInfo()
        let request = try makeRequest(
            mediaInfo: mediaInfo,
            recipe: automaticRecipe(for: mediaInfo)
        )
        let supported = try parseCapabilities()

        for missingProtocol in ["fd", "pipe"] {
            let capabilities = FFmpegCapabilities(
                decoders: supported.decoders,
                encoders: supported.encoders,
                filters: supported.filters,
                demuxers: supported.demuxers,
                muxers: supported.muxers,
                inputProtocols: supported.inputProtocols,
                outputProtocols: supported.outputProtocols.subtracting([
                    missingProtocol,
                ])
            )

            #expect(
                throws: FFmpegPreflightError.unavailableCapability(
                    category: .outputProtocol,
                    name: missingProtocol
                )
            ) {
                try FFmpegPreflightValidator().validate(
                    request,
                    capabilities: capabilities
                )
            }
        }
    }

    @Test("Unsupported selected video decoder is a typed preflight error")
    func rejectsUnsupportedVideoDecoder() throws {
        let mediaInfo = try videoOnlyMediaInfo(codecName: "vp9")
        let request = try makeRequest(
            mediaInfo: mediaInfo,
            recipe: automaticRecipe(for: mediaInfo)
        )

        #expect(
            throws: FFmpegPreflightError.unsupportedDecoder(
                streamIndex: 3,
                codecName: "vp9"
            )
        ) {
            try FFmpegPreflightValidator().validate(
                request,
                capabilities: parseCapabilities()
            )
        }
    }

    @Test("Automatic video-only input needs no audio decoder or AAC encoder")
    func automaticVideoOnlySkipsAudioCapabilities() throws {
        let source = try TestFixtures.mediaInfo()
        let mediaInfo = try MediaInfo(
            formatNames: source.formatNames,
            durationMicroseconds: source.durationMicroseconds,
            byteCount: source.byteCount,
            bitRate: source.bitRate,
            streams: source.streams.filter {
                if case .audio = $0 { return false }
                return true
            }
        )
        let recipe = try automaticRecipe(for: mediaInfo)
        var capabilities = try parseCapabilities()
        capabilities = FFmpegCapabilities(
            decoders: capabilities.decoders,
            encoders: ["h264_videotoolbox"],
            filters: ["scale"],
            demuxers: capabilities.demuxers,
            muxers: capabilities.muxers,
            inputProtocols: capabilities.inputProtocols,
            outputProtocols: capabilities.outputProtocols
        )

        try FFmpegPreflightValidator().validate(
            makeRequest(mediaInfo: mediaInfo, recipe: recipe),
            capabilities: capabilities
        )
    }

    @Test("The runtime client executes six exact queries once and caches")
    func clientQueriesAndCaches() async throws {
        let runner = FFprobeProcessRunnerStub(
            scriptsByLastArgument: try capabilityScripts()
        )
        let executableURL = URL(fileURLWithPath: "/Bundle/ffmpeg")
        let client = try FFmpegCapabilityClient(
            executableURL: executableURL,
            processRunner: runner
        )

        let first = try await client.capabilities()
        let second = try await client.capabilities()
        let requests = await runner.recordedRequests()

        #expect(first == second)
        #expect(requests.count == 6)
        #expect(
            Set(requests.map(\.arguments)) == Set([
                ["-hide_banner", "-decoders"],
                ["-hide_banner", "-encoders"],
                ["-hide_banner", "-filters"],
                ["-hide_banner", "-demuxers"],
                ["-hide_banner", "-muxers"],
                ["-hide_banner", "-protocols"],
            ])
        )
        #expect(requests.allSatisfy { $0.executableURL == executableURL })
        #expect(requests.allSatisfy { $0.environment["LC_ALL"] == "C" })
    }

    @Test("Concurrent capability callers share one discovery task")
    func clientDiscoveryIsSingleFlight() async throws {
        let runner = FFprobeProcessRunnerStub(
            scriptsByLastArgument: try capabilityScripts()
        )
        let client = try FFmpegCapabilityClient(
            executableURL: URL(fileURLWithPath: "/Bundle/ffmpeg"),
            processRunner: runner
        )

        let values = try await withThrowingTaskGroup(
            of: FFmpegCapabilities.self,
            returning: [FFmpegCapabilities].self
        ) { group in
            for _ in 0..<16 {
                group.addTask {
                    try await client.capabilities()
                }
            }
            var values: [FFmpegCapabilities] = []
            for try await value in group {
                values.append(value)
            }
            return values
        }

        #expect(values.count == 16)
        #expect(values.allSatisfy { $0 == values.first })
        #expect(await runner.recordedRequests().count == 6)
    }

    @Test("Discovery starts all queries in parallel, times out, and retries")
    func discoveryTimeoutCancelsAllQueriesAndIsNotCached() async throws {
        let runner = HoldingCapabilityRunner()
        let timeoutGate = CapabilityTimeoutGate(runner: runner)
        let client = try FFmpegCapabilityClient(
            executableURL: URL(fileURLWithPath: "/Bundle/ffmpeg"),
            processRunner: runner,
            discoveryTimeout: .seconds(30),
            sleep: { duration in
                try await timeoutGate.wait(duration)
            }
        )

        for expectedRequestCount in [6, 12] {
            do {
                _ = try await client.capabilities()
                Issue.record("Expected capability discovery timeout")
            } catch let error as FFmpegCapabilityClientError {
                #expect(error == .discoveryTimedOut)
            }

            #expect(await runner.requestCount() == expectedRequestCount)
            #expect(
                await runner.uniqueCancellationCount()
                    == expectedRequestCount
            )
            #expect(await runner.heldExecutionCount() == 0)
        }
    }

    @Test("Cancelling the sole waiter tears down capability discovery")
    func soleWaiterCancellationStopsDiscovery() async throws {
        let runner = HoldingCapabilityRunner()
        let client = try FFmpegCapabilityClient(
            executableURL: URL(fileURLWithPath: "/Bundle/ffmpeg"),
            processRunner: runner,
            discoveryTimeout: .seconds(30)
        )
        let operation = Task {
            try await client.capabilities()
        }

        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(3))
        while await runner.requestCount() < 6, clock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(await runner.requestCount() == 6)

        operation.cancel()
        do {
            _ = try await operation.value
            Issue.record("Expected capability discovery cancellation")
        } catch is CancellationError {
            // Expected.
        }

        #expect(await runner.uniqueCancellationCount() == 6)
        #expect(await runner.heldExecutionCount() == 0)
    }

    @Test("The final cancelled waiter stays suspended until discovery drains")
    func finalWaiterCancellationWaitsForDiscoveryDrain() async throws {
        let runner = HoldingCapabilityRunner(blocksCancellation: true)
        let client = try FFmpegCapabilityClient(
            executableURL: URL(fileURLWithPath: "/Bundle/ffmpeg"),
            processRunner: runner,
            discoveryTimeout: .seconds(30)
        )
        let operation = Task { try await client.capabilities() }
        let completion = CapabilityCompletionProbe()
        let observer = Task {
            _ = await operation.result
            await completion.markCompleted()
        }
        try await waitForRequestCount(6, runner: runner)

        operation.cancel()
        try await waitForCancellationCount(6, runner: runner)
        for _ in 0..<100 {
            await Task.yield()
        }

        #expect(!(await completion.isCompleted()))
        #expect(await runner.heldExecutionCount() == 6)

        await runner.releaseCancellation()
        do {
            _ = try await operation.value
            Issue.record("Expected capability discovery cancellation")
        } catch is CancellationError {
            // Expected only after every held query has drained.
        }
        await observer.value

        #expect(await completion.isCompleted())
        #expect(await runner.heldExecutionCount() == 0)
    }

    @Test("A new caller never joins a cancelled discovery generation")
    func cancelledGenerationIsDetachedBeforeTeardown() async throws {
        let runner = HoldingCapabilityRunner(blocksCancellation: true)
        let client = try FFmpegCapabilityClient(
            executableURL: URL(fileURLWithPath: "/Bundle/ffmpeg"),
            processRunner: runner,
            discoveryTimeout: .seconds(30)
        )
        let first = Task { try await client.capabilities() }
        try await waitForRequestCount(6, runner: runner)

        first.cancel()
        try await waitForCancellationCount(6, runner: runner)

        let second = Task { try await client.capabilities() }
        try await waitForRequestCount(12, runner: runner)
        #expect(await runner.requestCount() == 12)

        second.cancel()
        await runner.releaseCancellation()
        for operation in [first, second] {
            do {
                _ = try await operation.value
                Issue.record("Expected cancellation")
            } catch is CancellationError {
                // Expected.
            }
        }
        #expect(await runner.heldExecutionCount() == 0)
    }

    @Test("One cancelled waiter returns while shared discovery continues")
    func cancelledWaiterDoesNotBlockOrPoisonPeer() async throws {
        let runner = HoldingCapabilityRunner()
        let client = try FFmpegCapabilityClient(
            executableURL: URL(fileURLWithPath: "/Bundle/ffmpeg"),
            processRunner: runner,
            discoveryTimeout: .seconds(30)
        )
        let first = Task { try await client.capabilities() }
        let second = Task { try await client.capabilities() }
        try await waitForRequestCount(6, runner: runner)

        first.cancel()
        do {
            _ = try await first.value
            Issue.record("Expected first waiter cancellation")
        } catch is CancellationError {
            // Expected without waiting for the shared discovery.
        }
        #expect(await runner.uniqueCancellationCount() == 0)
        #expect(await runner.heldExecutionCount() == 6)

        second.cancel()
        do {
            _ = try await second.value
            Issue.record("Expected second waiter cancellation")
        } catch is CancellationError {
            // The final waiter owns shared teardown.
        }
        #expect(await runner.uniqueCancellationCount() == 6)
        #expect(await runner.heldExecutionCount() == 0)
    }

    private func waitForRequestCount(
        _ count: Int,
        runner: HoldingCapabilityRunner
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(3))
        while await runner.requestCount() < count, clock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    private func waitForCancellationCount(
        _ count: Int,
        runner: HoldingCapabilityRunner
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(3))
        while await runner.uniqueCancellationCount() < count,
              clock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    private func parseCapabilities() throws -> FFmpegCapabilities {
        try FFmpegCapabilityParser().parse(
            decoders: decoderOutput,
            encoders: encoderOutput,
            filters: filterOutput,
            demuxers: demuxerOutput,
            muxers: muxerOutput,
            protocols: protocolOutput
        )
    }

    private func capabilityScripts() throws -> [
        String: FFprobeRunnerScript
    ] {
        [
            "-decoders": try .success(
                standardOutputChunks: [decoderOutput]
            ),
            "-encoders": try .success(
                standardOutputChunks: [encoderOutput]
            ),
            "-filters": try .success(
                standardOutputChunks: [filterOutput]
            ),
            "-demuxers": try .success(
                standardOutputChunks: [demuxerOutput]
            ),
            "-muxers": try .success(
                standardOutputChunks: [muxerOutput]
            ),
            "-protocols": try .success(
                standardOutputChunks: [protocolOutput]
            ),
        ]
    }

    private func makeRequest(
        mediaInfo: MediaInfo,
        recipe: CompressionRecipe
    ) throws -> TranscodeRequest {
        let jobID = UUID(
            uuidString: "AAAAAAAA-BBBB-4CCC-8DDD-EEEEEEEEEEEE"
        )!
        let directory = URL(
            fileURLWithPath: "/tmp/ResizerCapabilities",
            isDirectory: true
        )
        let planningRequest = OutputPlanningRequest(
            jobID: jobID,
            inputURL: URL(fileURLWithPath: "/tmp/source.mov"),
            policy: try OutputPolicy(directoryURL: directory)
        )
        let plan = try OutputPlan(
            request: planningRequest,
            temporaryURL: directory.appendingPathComponent(
                "source.\(jobID.uuidString.lowercased()).partial.mp4"
            ),
            finalURL: directory.appendingPathComponent("source.mp4")
        )
        return TranscodeRequest(
            outputPlan: plan,
            mediaInfo: mediaInfo,
            recipe: recipe
        )
    }

    private func videoOnlyMediaInfo(codecName: String) throws -> MediaInfo {
        try MediaInfo(
            formatNames: ["mov", "mp4"],
            durationMicroseconds: 1_000_000,
            byteCount: 1_000,
            bitRate: nil,
            streams: [
                .video(
                    try VideoStreamInfo(
                        index: 3,
                        codecName: codecName,
                        encodedWidth: 1_920,
                        encodedHeight: 1_080,
                        frameRate: nil,
                        rotationDegrees: nil,
                        pixelFormat: "yuv420p",
                        bitDepth: 8,
                        dynamicRange: .sdr
                    )
                ),
            ]
        )
    }

    private func automaticRecipe(
        for mediaInfo: MediaInfo,
        mode: CompressionMode = .automatic
    ) throws -> CompressionRecipe {
        try AutomaticCompressionPolicy().recipe(
            for: mediaInfo,
            mode: mode
        )
    }

    private var decoderOutput: Data {
        Data(
            """
            Decoders:
             V..... = Video
             ------
             VFS..D h264                 H.264
             VFS..D hevc                 HEVC
             A....D aac                  AAC
            """.utf8
        )
    }

    private var encoderOutput: Data {
        Data(
            """
            Encoders:
             V..... = Video
             ------
             V....D h264_videotoolbox    VideoToolbox H.264
             A....D aac                  AAC
            """.utf8
        )
    }

    private var filterOutput: Data {
        Data(
            """
            Filters:
              T.. = Timeline support
              ------
             .. scale             V->V       Scale
             .. aresample         A->A       Resample
            """.utf8
        )
    }

    private var demuxerOutput: Data {
        Data(
            """
            Formats:
             D.. = Demuxing supported
             ---
             D   mov,mp4,m4a QuickTime / MOV
            """.utf8
        )
    }

    private var muxerOutput: Data {
        Data(
            """
            Formats:
             .E. = Muxing supported
             ---
              E  mov             QuickTime / MOV
              E  mp4             MP4
            """.utf8
        )
    }

    private var protocolOutput: Data {
        Data(
            """
            Supported file protocols:
            Input:
              fd
              file
              pipe
            Output:
              fd
              file
              pipe
            """.utf8
        )
    }
}

private actor HoldingCapabilityRunner: ProcessRunning {
    private let blocksCancellation: Bool
    private var requests: [ProcessRequest] = []
    private var continuations: [
        ProcessExecutionID:
            AsyncThrowingStream<ProcessEvent, any Error>.Continuation
    ] = [:]
    private var cancellations: [ProcessExecutionID] = []
    private var cancellationWasReleased: Bool
    private var cancellationWaiters: [
        CheckedContinuation<Void, Never>
    ] = []

    init(blocksCancellation: Bool = false) {
        self.blocksCancellation = blocksCancellation
        cancellationWasReleased = !blocksCancellation
    }

    func start(
        _ request: ProcessRequest
    ) async throws -> AsyncThrowingStream<ProcessEvent, any Error> {
        requests.append(request)
        let pair = AsyncThrowingStream<ProcessEvent, any Error>.makeStream(
            bufferingPolicy: .unbounded
        )
        continuations[request.id] = pair.continuation
        return pair.stream
    }

    func cancel(executionID: ProcessExecutionID) async {
        cancellations.append(executionID)
        if blocksCancellation, !cancellationWasReleased {
            await withCheckedContinuation { continuation in
                cancellationWaiters.append(continuation)
            }
        }
        continuations.removeValue(forKey: executionID)?.finish()
    }

    func requestCount() -> Int {
        requests.count
    }

    func uniqueCancellationCount() -> Int {
        Set(cancellations).count
    }

    func heldExecutionCount() -> Int {
        continuations.count
    }

    func releaseCancellation() {
        cancellationWasReleased = true
        let waiters = cancellationWaiters
        cancellationWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }
}

private actor CapabilityCompletionProbe {
    private var completed = false

    func markCompleted() {
        completed = true
    }

    func isCompleted() -> Bool {
        completed
    }
}

private actor CapabilityTimeoutGate {
    private let runner: HoldingCapabilityRunner
    private var nextRequestCount = 6

    init(runner: HoldingCapabilityRunner) {
        self.runner = runner
    }

    func wait(_ duration: Duration) async throws {
        _ = duration
        let target = nextRequestCount
        nextRequestCount += 6
        while await runner.requestCount() < target {
            try Task.checkCancellation()
            await Task.yield()
        }
    }
}
