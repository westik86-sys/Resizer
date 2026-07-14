import Foundation

nonisolated enum FFprobeClientError: Error, Sendable, Equatable {
    case bundledExecutableUnavailable
    case invalidExecutableURL
    case invalidSourceURL
    case invalidConfiguration
    case invalidProcessEventSequence
    case outputTooLarge(limit: Int)
    case processFailed(
        termination: ProcessTerminationStatus,
        diagnosticTail: BoundedData
    )
}

nonisolated struct FFprobeClient: MediaProbing, Sendable {
    static let defaultMaximumOutputByteCount = 8 * 1_024 * 1_024
    static let maximumOutputByteCount = 64 * 1_024 * 1_024

    private static let diagnosticByteLimit = 256 * 1_024

    private let executableURL: URL
    private let processRunner: any ProcessRunning
    private let maximumOutputByteCount: Int
    private let parser = FFprobeParser()

    init(
        executableURL: URL,
        processRunner: any ProcessRunning,
        maximumOutputByteCount: Int = Self.defaultMaximumOutputByteCount
    ) throws {
        guard executableURL.isFileURL,
              executableURL.path.hasPrefix("/"),
              !executableURL.path.contains("\0") else {
            throw FFprobeClientError.invalidExecutableURL
        }
        guard (1...Self.maximumOutputByteCount).contains(
            maximumOutputByteCount
        ) else {
            throw FFprobeClientError.invalidConfiguration
        }

        self.executableURL = executableURL.standardizedFileURL
        self.processRunner = processRunner
        self.maximumOutputByteCount = maximumOutputByteCount
    }

    static func bundled(
        processRunner: any ProcessRunning
    ) throws -> FFprobeClient {
        let bundle = Bundle.main
        guard let candidate = bundle.url(
            forAuxiliaryExecutable: "ffprobe"
        )?.standardizedFileURL else {
            throw FFprobeClientError.bundledExecutableUnavailable
        }

        let resolvedBundle = bundle.bundleURL
            .resolvingSymlinksInPath()
            .standardizedFileURL
        let resolvedCandidate = candidate
            .resolvingSymlinksInPath()
            .standardizedFileURL
        let isInsideBundle = resolvedCandidate.path.hasPrefix(
            resolvedBundle.path + "/"
        )
        let resourceValues = try? resolvedCandidate.resourceValues(
            forKeys: [.isRegularFileKey]
        )
        guard resolvedCandidate.isFileURL,
              isInsideBundle,
              resourceValues?.isRegularFile == true,
              FileManager.default.isExecutableFile(
                atPath: resolvedCandidate.path
              ) else {
            throw FFprobeClientError.bundledExecutableUnavailable
        }

        return try FFprobeClient(
            executableURL: resolvedCandidate,
            processRunner: processRunner
        )
    }

    func probe(_ sourceURL: URL) async throws -> MediaInfo {
        guard sourceURL.isFileURL,
              sourceURL.path.hasPrefix("/"),
              !sourceURL.path.contains("\0") else {
            throw FFprobeClientError.invalidSourceURL
        }
        try Task.checkCancellation()

        return try await probe(
            arguments: [
                "-v", "error",
                "-print_format", "json",
                "-show_format",
                "-show_streams",
                "-show_chapters",
                sourceURL.path,
            ],
            inheritedFileDescriptor: nil
        )
    }

    func probe(
        _ reservation: TemporaryOutputReservation
    ) async throws -> MediaInfo {
        guard reservation.temporaryURL.isFileURL,
              let fileDescriptor = reservation.lease.fileDescriptor,
              fileDescriptor >= 0 else {
            throw FFprobeClientError.invalidSourceURL
        }
        try Task.checkCancellation()

        return try await probe(
            arguments: [
                "-v", "error",
                "-print_format", "json",
                "-show_format",
                "-show_streams",
                "-show_chapters",
                "fd:3",
            ],
            inheritedFileDescriptor: try ProcessInheritedFileDescriptor(
                lease: reservation.lease,
                childDescriptor: 3
            )
        )
    }

    private func probe(
        arguments: [String],
        inheritedFileDescriptor: ProcessInheritedFileDescriptor?
    ) async throws -> MediaInfo {
        let request = try ProcessRequest(
            executableURL: executableURL,
            arguments: arguments,
            environment: [:],
            diagnosticByteLimit: Self.diagnosticByteLimit,
            eventBufferCapacity: ProcessRequest.maximumEventBufferCapacity,
            cancellationPolicy: .signalsOnly,
            inheritedFileDescriptor: inheritedFileDescriptor
        )
        let stream = try await processRunner.start(request)

        return try await withTaskCancellationHandler {
            do {
                return try await collect(
                    stream,
                    executionID: request.id
                )
            } catch is CancellationError {
                await cancelAndWait(executionID: request.id)
                throw CancellationError()
            } catch {
                await cancelAndWait(executionID: request.id)
                throw error
            }
        } onCancel: {
            Task {
                await processRunner.cancel(executionID: request.id)
            }
        }
    }

    private func collect(
        _ stream: AsyncThrowingStream<ProcessEvent, any Error>,
        executionID: ProcessExecutionID
    ) async throws -> MediaInfo {
        var standardOutput = Data()
        var result: ProcessResult?
        var outputWasTooLarge = false
        var cancellationTask: Task<Void, Never>?

        for try await event in stream {
            guard result == nil else {
                throw FFprobeClientError.invalidProcessEventSequence
            }

            switch event {
            case .standardOutput(let data):
                guard !outputWasTooLarge else {
                    continue
                }
                guard data.count <= maximumOutputByteCount - standardOutput.count else {
                    outputWasTooLarge = true
                    cancellationTask = Task.detached {
                        await processRunner.cancel(executionID: executionID)
                    }
                    continue
                }
                standardOutput.append(data)
            case .standardError:
                break
            case .terminated(let processResult):
                guard processResult.executionID == executionID else {
                    throw FFprobeClientError.invalidProcessEventSequence
                }
                result = processResult
            }
        }

        await cancellationTask?.value
        try Task.checkCancellation()

        if outputWasTooLarge {
            throw FFprobeClientError.outputTooLarge(
                limit: maximumOutputByteCount
            )
        }
        guard let result else {
            throw FFprobeClientError.invalidProcessEventSequence
        }
        guard result.termination.reason == .exit,
              result.termination.status == 0 else {
            throw FFprobeClientError.processFailed(
                termination: result.termination,
                diagnosticTail: result.diagnosticTail
            )
        }
        return try parser.parse(standardOutput)
    }

    private func cancelAndWait(executionID: ProcessExecutionID) async {
        let cleanupTask = Task.detached {
            await processRunner.cancel(executionID: executionID)
        }
        await cleanupTask.value
    }
}
