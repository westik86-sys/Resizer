import Foundation

nonisolated enum FFmpegTranscodingServiceError: Error, Sendable, Equatable {
    case bundledExecutableUnavailable
    case invalidExecutableURL
    case duplicateJob(CompressionJob.ID)
    case invalidProcessRequest
    case invalidTemporaryReservation
    case invalidProcessEventSequence
    case progressParsing(FFmpegProgressParsingError)
    case processFailed(
        termination: ProcessTerminationStatus,
        diagnosticTail: BoundedData
    )
    case temporaryOutputMissing
    case invalidTemporaryOutput
}

/// Owns one FFmpeg execution lifecycle per job while delegating all raw
/// process and pipe ownership to `ProcessRunning`.
actor FFmpegTranscodingService: Transcoding {
    static let diagnosticByteLimit = 1 * 1_024 * 1_024
    static let gracefulCancellationWait: Duration = .seconds(2)
    static let interruptCancellationWait: Duration = .seconds(1)
    static let terminateCancellationWait: Duration = .seconds(1)

    private nonisolated struct ActiveToken: Sendable, Equatable {
        let rawValue = UUID()
    }

    private nonisolated struct ActiveJob: Sendable {
        let token: ActiveToken
        var executionID: ProcessExecutionID?
        var cancellationWasRequested: Bool
    }

    private let executableURL: URL
    private let processRunner: any ProcessRunning
    private let commandBuilder: any CommandBuilding
    private let capabilityProvider: any FFmpegCapabilityProviding
    private let fileAccess: any FileAccessing
    private let preflightValidator = FFmpegPreflightValidator()

    private var activeJobs: [CompressionJob.ID: ActiveJob] = [:]

    init(
        executableURL: URL,
        processRunner: any ProcessRunning,
        commandBuilder: any CommandBuilding,
        capabilityProvider: any FFmpegCapabilityProviding,
        fileAccess: any FileAccessing
    ) throws {
        guard executableURL.isFileURL,
              executableURL.path.hasPrefix("/"),
              !executableURL.path.contains("\0") else {
            throw FFmpegTranscodingServiceError.invalidExecutableURL
        }

        self.executableURL = executableURL.standardizedFileURL
        self.processRunner = processRunner
        self.commandBuilder = commandBuilder
        self.capabilityProvider = capabilityProvider
        self.fileAccess = fileAccess
    }

    static func bundled(
        processRunner: any ProcessRunning,
        fileAccess: any FileAccessing
    ) throws -> FFmpegTranscodingService {
        let bundle = Bundle.main
        guard let candidate = bundle.url(
            forAuxiliaryExecutable: "ffmpeg"
        )?.standardizedFileURL else {
            throw FFmpegTranscodingServiceError
                .bundledExecutableUnavailable
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
            throw FFmpegTranscodingServiceError
                .bundledExecutableUnavailable
        }

        let capabilityProvider = try FFmpegCapabilityClient(
            executableURL: resolvedCandidate,
            processRunner: processRunner
        )
        return try FFmpegTranscodingService(
            executableURL: resolvedCandidate,
            processRunner: processRunner,
            commandBuilder: FFmpegCommandBuilder(),
            capabilityProvider: capabilityProvider,
            fileAccess: fileAccess
        )
    }

    /// Validates both the typed command mapping and the capabilities reported
    /// by the actual bundled FFmpeg build.
    func preflight(_ request: TranscodeRequest) async throws {
        _ = try await preparedArguments(for: request, activeToken: nil)
    }

    func transcode(
        _ request: TranscodeRequest,
        reservation: TemporaryOutputReservation,
        onProgress: @escaping @Sendable (TranscodeProgress) async -> Void
    ) async throws -> TranscodeResult {
        try validate(reservation: reservation, for: request)
        let activeToken = try register(jobID: request.jobID)
        defer { unregister(jobID: request.jobID, token: activeToken) }

        return try await withTaskCancellationHandler {
            do {
                try requireNotCancelled(
                    jobID: request.jobID,
                    token: activeToken
                )
                let selectedURLs = [
                    request.inputURL,
                    request.temporaryOutputURL.deletingLastPathComponent(),
                ]
                return try await fileAccess.withSecurityScopedAccess(
                    to: selectedURLs
                ) { [self] in
                    try await run(
                        request,
                        activeToken: activeToken,
                        reservation: reservation,
                        onProgress: onProgress
                    )
                }
            } catch {
                if let executionID = executionID(
                    jobID: request.jobID,
                    token: activeToken
                ) {
                    await cancelAndWait(executionID: executionID)
                }

                if error is CancellationError
                    || Task.isCancelled
                    || cancellationWasRequested(
                        jobID: request.jobID,
                        token: activeToken
                    ) {
                    throw CancellationError()
                }
                throw error
            }
        } onCancel: { [self] in
            Task {
                await cancel(
                    jobID: request.jobID,
                    activeToken: activeToken
                )
            }
        }
    }

    func cancel(jobID: CompressionJob.ID) async {
        guard var activeJob = activeJobs[jobID] else {
            return
        }

        activeJob.cancellationWasRequested = true
        activeJobs[jobID] = activeJob
        guard let executionID = activeJob.executionID else { return }
        await cancelAndWait(executionID: executionID)
    }

    private func run(
        _ request: TranscodeRequest,
        activeToken: ActiveToken,
        reservation: TemporaryOutputReservation,
        onProgress: @escaping @Sendable (TranscodeProgress) async -> Void
    ) async throws -> TranscodeResult {
        let arguments = try await preparedArguments(
            for: request,
            activeToken: activeToken
        )
        try requireNotCancelled(jobID: request.jobID, token: activeToken)

        let processRequest = try makeProcessRequest(
            arguments: arguments,
            reservation: reservation
        )
        try register(
            executionID: processRequest.id,
            jobID: request.jobID,
            token: activeToken
        )

        let stream = try await processRunner.start(processRequest)

        // A cancellation can arrive after the execution ID is stored but
        // before the runner has registered it. Rechecking after `start`
        // closes that race and sends cancellation again when necessary.
        try requireNotCancelled(jobID: request.jobID, token: activeToken)

        let processResult = try await collect(
            stream,
            executionID: processRequest.id,
            totalDurationMicroseconds: request.mediaInfo.durationMicroseconds,
            onProgress: onProgress
        )

        try requireNotCancelled(jobID: request.jobID, token: activeToken)
        guard processResult.termination.reason == .exit,
              processResult.termination.status == 0 else {
            throw FFmpegTranscodingServiceError.processFailed(
                termination: processResult.termination,
                diagnosticTail: processResult.diagnosticTail
            )
        }

        let metadata = try await fileAccess.metadata(
            at: request.temporaryOutputURL
        )
        try requireNotCancelled(jobID: request.jobID, token: activeToken)
        guard let metadata else {
            throw FFmpegTranscodingServiceError.temporaryOutputMissing
        }
        guard !metadata.isDirectory,
              metadata.byteCount > 0,
              metadata.identity == reservation.metadata.identity else {
            throw FFmpegTranscodingServiceError.invalidTemporaryOutput
        }
        return try TranscodeResult(
            byteCount: metadata.byteCount,
            temporaryMetadata: metadata
        )
    }

    private func preparedArguments(
        for request: TranscodeRequest,
        activeToken: ActiveToken?
    ) async throws -> [String] {
        try checkCancellation(
            jobID: request.jobID,
            activeToken: activeToken
        )
        let arguments = try await commandBuilder.arguments(
            for: TranscodeCommandRequest(transcodeRequest: request)
        )

        try checkCancellation(
            jobID: request.jobID,
            activeToken: activeToken
        )
        let capabilities = try await capabilityProvider.capabilities()

        try checkCancellation(
            jobID: request.jobID,
            activeToken: activeToken
        )
        try preflightValidator.validate(request, capabilities: capabilities)
        return arguments
    }

    private func collect(
        _ stream: AsyncThrowingStream<ProcessEvent, any Error>,
        executionID: ProcessExecutionID,
        totalDurationMicroseconds: Int64?,
        onProgress: @escaping @Sendable (TranscodeProgress) async -> Void
    ) async throws -> ProcessResult {
        var parser = try FFmpegProgressParser(
            totalDurationMicroseconds: totalDurationMicroseconds
        )
        var processResult: ProcessResult?
        var progressError: FFmpegProgressParsingError?

        for try await event in stream {
            guard processResult == nil else {
                throw FFmpegTranscodingServiceError
                    .invalidProcessEventSequence
            }

            switch event {
            case .standardError(let data):
                guard progressError == nil else { continue }
                let snapshots: [TranscodeProgress]
                do {
                    snapshots = try parser.consume(data)
                } catch let error as FFmpegProgressParsingError {
                    // Keep draining until the terminal/EOF barrier. FFmpeg can
                    // emit unavailable progress values while exiting with a
                    // useful nonzero diagnostic, which has higher priority.
                    progressError = error
                    continue
                }
                for snapshot in snapshots {
                    await onProgress(snapshot)
                }
            case .standardOutput:
                // Media stdout is bound directly to the pre-reserved inode;
                // no byte event may be emitted for this execution.
                throw FFmpegTranscodingServiceError
                    .invalidProcessEventSequence
            case .terminated(let result):
                guard result.executionID == executionID else {
                    throw FFmpegTranscodingServiceError
                        .invalidProcessEventSequence
                }
                processResult = result
            }
        }

        guard let processResult else {
            throw FFmpegTranscodingServiceError.invalidProcessEventSequence
        }

        // ProcessRunner emits `.terminated` only after process termination and
        // EOF from both pipes. A nonzero process diagnostic is therefore more
        // useful than a missing progress=end caused by that same failure.
        guard processResult.termination.reason == .exit,
              processResult.termination.status == 0 else {
            return processResult
        }

        if let progressError {
            throw FFmpegTranscodingServiceError
                .progressParsing(progressError)
        }

        let finalSnapshots: [TranscodeProgress]
        do {
            finalSnapshots = try parser.finish()
        } catch let error as FFmpegProgressParsingError {
            throw FFmpegTranscodingServiceError.progressParsing(error)
        }
        for snapshot in finalSnapshots {
            await onProgress(snapshot)
        }
        return processResult
    }

    private func makeProcessRequest(
        arguments: [String],
        reservation: TemporaryOutputReservation
    ) throws -> ProcessRequest {
        guard let identity = reservation.metadata.identity else {
            throw FFmpegTranscodingServiceError.invalidTemporaryReservation
        }
        do {
            return try ProcessRequest(
                executableURL: executableURL,
                arguments: arguments,
                environment: [:],
                diagnosticByteLimit: Self.diagnosticByteLimit,
                eventBufferCapacity: ProcessRequest
                    .maximumEventBufferCapacity,
                cancellationPolicy: try ProcessCancellationPolicy(
                    standardInput: .cancellationMessage(Data("q\n".utf8)),
                    gracefulInputWait: Self.gracefulCancellationWait,
                    interruptWait: Self.interruptCancellationWait,
                    terminateWait: Self.terminateCancellationWait
                ),
                standardOutputDestination: .existingFile(
                    url: reservation.temporaryURL,
                    expectedIdentity: identity
                )
            )
        } catch {
            throw FFmpegTranscodingServiceError.invalidProcessRequest
        }
    }

    private func validate(
        reservation: TemporaryOutputReservation,
        for request: TranscodeRequest
    ) throws {
        guard reservation.jobID == request.jobID,
              reservation.temporaryURL
                == request.temporaryOutputURL.standardizedFileURL,
              reservation.metadata.byteCount == 0,
              !reservation.metadata.isDirectory,
              reservation.metadata.identity != nil else {
            throw FFmpegTranscodingServiceError.invalidTemporaryReservation
        }
    }

    private func register(jobID: CompressionJob.ID) throws -> ActiveToken {
        guard activeJobs[jobID] == nil else {
            throw FFmpegTranscodingServiceError.duplicateJob(jobID)
        }
        let token = ActiveToken()
        activeJobs[jobID] = ActiveJob(
            token: token,
            executionID: nil,
            cancellationWasRequested: Task.isCancelled
        )
        return token
    }

    private func register(
        executionID: ProcessExecutionID,
        jobID: CompressionJob.ID,
        token: ActiveToken
    ) throws {
        guard var activeJob = activeJobs[jobID],
              activeJob.token == token else {
            throw CancellationError()
        }
        activeJob.executionID = executionID
        activeJobs[jobID] = activeJob
    }

    private func unregister(
        jobID: CompressionJob.ID,
        token: ActiveToken
    ) {
        guard activeJobs[jobID]?.token == token else { return }
        activeJobs.removeValue(forKey: jobID)
    }

    private func checkCancellation(
        jobID: CompressionJob.ID,
        activeToken: ActiveToken?
    ) throws {
        if let activeToken {
            try requireNotCancelled(jobID: jobID, token: activeToken)
        } else {
            try Task.checkCancellation()
        }
    }

    private func requireNotCancelled(
        jobID: CompressionJob.ID,
        token: ActiveToken
    ) throws {
        guard !Task.isCancelled,
              let activeJob = activeJobs[jobID],
              activeJob.token == token,
              !activeJob.cancellationWasRequested else {
            throw CancellationError()
        }
    }

    private func cancellationWasRequested(
        jobID: CompressionJob.ID,
        token: ActiveToken
    ) -> Bool {
        guard let activeJob = activeJobs[jobID],
              activeJob.token == token else {
            return Task.isCancelled
        }
        return Task.isCancelled || activeJob.cancellationWasRequested
    }

    private func executionID(
        jobID: CompressionJob.ID,
        token: ActiveToken
    ) -> ProcessExecutionID? {
        guard let activeJob = activeJobs[jobID],
              activeJob.token == token else {
            return nil
        }
        return activeJob.executionID
    }

    private func cancel(
        jobID: CompressionJob.ID,
        activeToken: ActiveToken
    ) async {
        guard var activeJob = activeJobs[jobID],
              activeJob.token == activeToken else {
            return
        }
        activeJob.cancellationWasRequested = true
        activeJobs[jobID] = activeJob
        guard let executionID = activeJob.executionID else { return }
        await cancelAndWait(executionID: executionID)
    }

    private func cancelAndWait(executionID: ProcessExecutionID) async {
        let runner = processRunner
        let cancellationTask = Task.detached(priority: .utility) {
            await runner.cancel(executionID: executionID)
        }
        await cancellationTask.value
    }
}
