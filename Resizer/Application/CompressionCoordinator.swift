import Foundation

nonisolated struct CompressionCoordinatorDependencies: Sendable {
    let mediaProber: any MediaProbing
    let transcoder: any Transcoding
    let outputPlanner: any OutputPlanning
    let fileAccess: any FileAccessing
    let outputValidator: any TranscodeOutputValidating

    init(
        mediaProber: any MediaProbing,
        transcoder: any Transcoding,
        outputPlanner: any OutputPlanning,
        fileAccess: any FileAccessing,
        outputValidator: any TranscodeOutputValidating =
            TranscodeOutputValidator()
    ) {
        self.mediaProber = mediaProber
        self.transcoder = transcoder
        self.outputPlanner = outputPlanner
        self.fileAccess = fileAccess
        self.outputValidator = outputValidator
    }
}

nonisolated struct CompressionSnapshot: Sendable, Equatable {
    let jobs: [CompressionJob]

    static let empty = CompressionSnapshot(jobs: [])
}

nonisolated enum CompressionCoordinatorError: Error, Sendable, Equatable {
    case duplicateJob(CompressionJob.ID)
    case jobNotFound(CompressionJob.ID)
    case activeJobExists(CompressionJob.ID)
    case workflowAlreadyRunning(CompressionJob.ID)
}

nonisolated enum CompressionWorkflowError: Error, Sendable, Equatable {
    case inputMissing
    case inputEmpty
    case outputDirectoryUnavailable
    case temporaryOutputAlreadyExists
    case finalOutputAlreadyExists
    case temporaryOutputInvalid
    case temporaryCleanupFailed
    case workflowStateChanged(JobPhase)
}

private nonisolated struct PreRunCancellation: Sendable {
    let token: UUID
    let cancel: @Sendable () -> Void
}

actor CompressionCoordinator {
    private let dependencies: CompressionCoordinatorDependencies
    private var jobsByID: [CompressionJob.ID: CompressionJob] = [:]
    private var jobOrder: [CompressionJob.ID] = []
    private var workflowJobIDs: Set<CompressionJob.ID> = []
    private var cancellationIntents: Set<CompressionJob.ID> = []
    private var preRunCancellations: [
        CompressionJob.ID: PreRunCancellation
    ] = [:]
    private var transcodeCancellations: [
        CompressionJob.ID: PreRunCancellation
    ] = [:]

    init(dependencies: CompressionCoordinatorDependencies) {
        self.dependencies = dependencies
    }

    @discardableResult
    func createJob(
        inputURL: URL,
        id: CompressionJob.ID = UUID(),
        createdAt: Date = Date()
    ) throws -> CompressionJob {
        let job = try CompressionJob(
            id: id,
            inputURL: inputURL,
            createdAt: createdAt
        )
        try register(job)
        return job
    }

    func register(_ job: CompressionJob) throws {
        guard jobsByID[job.id] == nil else {
            throw CompressionCoordinatorError.duplicateJob(job.id)
        }
        try requireAvailableActiveSlot(for: job)
        jobsByID[job.id] = job
        jobOrder.append(job.id)
    }

    @discardableResult
    func transition(
        jobID: CompressionJob.ID,
        to next: JobState
    ) throws -> CompressionJob {
        var job = try requireJob(jobID)
        try job.transition(to: next)
        try requireAvailableActiveSlot(for: job)
        jobsByID[jobID] = job
        return job
    }

    @discardableResult
    func recordMediaInfo(
        _ mediaInfo: MediaInfo,
        for jobID: CompressionJob.ID
    ) throws -> CompressionJob {
        var job = try requireJob(jobID)
        try job.recordMediaInfo(mediaInfo)
        jobsByID[jobID] = job
        return job
    }

    @discardableResult
    func configure(
        _ configuration: JobConfiguration,
        for jobID: CompressionJob.ID
    ) throws -> CompressionJob {
        var job = try requireJob(jobID)
        try job.configure(configuration)
        jobsByID[jobID] = job
        return job
    }

    @discardableResult
    func updateProgress(
        _ progress: TranscodeProgress,
        for jobID: CompressionJob.ID
    ) throws -> CompressionJob {
        var job = try requireJob(jobID)
        try job.updateProgress(progress)
        jobsByID[jobID] = job
        return job
    }

    /// Executes the complete headless workflow while retaining security-scoped
    /// access to both user-selected locations.
    @discardableResult
    func process(
        jobID: CompressionJob.ID,
        configuration: JobConfiguration
    ) async throws -> CompressionJob {
        let job = try requireJob(jobID)
        guard workflowJobIDs.insert(jobID).inserted else {
            throw CompressionCoordinatorError.workflowAlreadyRunning(jobID)
        }
        defer {
            workflowJobIDs.remove(jobID)
            cancellationIntents.remove(jobID)
            preRunCancellations.removeValue(forKey: jobID)
            transcodeCancellations.removeValue(forKey: jobID)
        }

        _ = try transition(jobID: jobID, to: .probing)
        let clock = ContinuousClock()
        let startedAt = clock.now
        let selectedURLs = [
            job.inputURL,
            configuration.outputPolicy.directoryURL,
        ]

        return try await withTaskCancellationHandler {
            do {
                return try await dependencies.fileAccess
                    .withSecurityScopedAccess(to: selectedURLs) { [self] in
                        try await runScopedWorkflow(
                            jobID: jobID,
                            configuration: configuration,
                            startedAt: startedAt,
                            clock: clock
                        )
                    }
            } catch {
                try await finishWorkflowAfterError(error, jobID: jobID)
            }
        } onCancel: {
            Task { [self] in
                await cancel(jobID: jobID)
            }
        }
    }

    /// Records cancellation before touching the process so cancellation wins
    /// any later nonzero exit. Cancellation during probe/preflight is retained
    /// and resolved before FFmpeg is launched.
    func cancel(jobID: CompressionJob.ID) async {
        guard workflowJobIDs.contains(jobID),
              var job = jobsByID[jobID] else {
            return
        }

        switch job.state {
        case .probing, .queued:
            cancellationIntents.insert(jobID)
            preRunCancellations[jobID]?.cancel()
            return
        case .ready:
            cancellationIntents.insert(jobID)
            preRunCancellations[jobID]?.cancel()
            return
        case .running(let progress):
            cancellationIntents.insert(jobID)
            transcodeCancellations[jobID]?.cancel()
            guard (try? job.transition(
                to: .cancelling(lastProgress: progress)
            )) != nil else {
                return
            }
            jobsByID[jobID] = job
        case .cancelling:
            cancellationIntents.insert(jobID)
            transcodeCancellations[jobID]?.cancel()
        case .finishing, .draft, .cancelled, .completed, .failed:
            // Once validation has been claimed, normal completion wins.
            return
        }

        await dependencies.transcoder.cancel(jobID: jobID)
    }

    func job(id: CompressionJob.ID) -> CompressionJob? {
        jobsByID[id]
    }

    func snapshot() -> CompressionSnapshot {
        CompressionSnapshot(jobs: jobOrder.compactMap { jobsByID[$0] })
    }

    private func runScopedWorkflow(
        jobID: CompressionJob.ID,
        configuration: JobConfiguration,
        startedAt: ContinuousClock.Instant,
        clock: ContinuousClock
    ) async throws -> CompressionJob {
        var outputPlan: OutputPlan?
        var outputReservation: TemporaryOutputReservation?
        var expectedTemporaryMetadata: FileMetadata?
        var didCommit = false

        do {
            let inputURL = try requireJob(jobID).inputURL
            let sourceMedia = try await runProbe(
                inputURL,
                jobID: jobID
            )
            _ = try recordMediaInfo(sourceMedia, for: jobID)
            _ = try transition(jobID: jobID, to: .ready)
            _ = try configure(configuration, for: jobID)
            _ = try transition(jobID: jobID, to: .queued)

            let plan = try await runOutputPlanning(
                OutputPlanningRequest(
                    jobID: jobID,
                    inputURL: inputURL,
                    policy: configuration.outputPolicy
                ),
                jobID: jobID
            )
            outputPlan = plan
            let request = TranscodeRequest(
                outputPlan: plan,
                mediaInfo: sourceMedia,
                recipe: configuration.recipe
            )

            try await validateFilePreflight(plan)
            try await runTranscodePreflight(request, jobID: jobID)
            let reservation = try await runTemporaryReservation(
                plan,
                jobID: jobID
            )
            outputReservation = reservation
            expectedTemporaryMetadata = reservation.metadata

            _ = try transition(
                jobID: jobID,
                to: .running(progress: nil)
            )
            if Task.isCancelled || cancellationIntents.contains(jobID) {
                _ = try transition(
                    jobID: jobID,
                    to: .cancelling(lastProgress: nil)
                )
                throw CancellationError()
            }

            let transcodeResult = try await runTranscode(
                request,
                reservation: reservation,
                jobID: jobID
            )
            expectedTemporaryMetadata = transcodeResult.temporaryMetadata

            try claimValidation(jobID: jobID)
            let validatedOutput = try await validateTemporaryOutput(
                plan: plan,
                source: sourceMedia,
                recipe: configuration.recipe,
                transcodeResult: transcodeResult,
                reservation: reservation
            )

            _ = try transition(
                jobID: jobID,
                to: .finishing(.committing)
            )
            try await commitWithoutCallerCancellation(
                plan,
                reservation: reservation,
                expectedTemporaryMetadata: validatedOutput
            )
            didCommit = true

            let result = try CompressionResult(
                outputURL: plan.finalURL,
                outputByteCount: validatedOutput.byteCount,
                elapsed: startedAt.duration(to: clock.now)
            )
            return try transition(
                jobID: jobID,
                to: .completed(result)
            )
        } catch {
            if let outputPlan,
               let outputReservation,
               expectedTemporaryMetadata != nil,
               !didCommit {
                do {
                    try await cleanupWithoutCallerCancellation(
                        outputPlan,
                        reservation: outputReservation,
                        expectedTemporaryMetadata: expectedTemporaryMetadata
                    )
                } catch {
                    throw CompressionWorkflowError.temporaryCleanupFailed
                }
            }
            throw error
        }
    }

    private func validateFilePreflight(_ plan: OutputPlan) async throws {
        let input = try await runMetadataRead(
            plan.inputURL,
            jobID: plan.jobID
        )
        guard let input else {
            throw CompressionWorkflowError.inputMissing
        }
        guard !input.isDirectory else {
            throw CompressionWorkflowError.inputMissing
        }
        guard input.byteCount > 0 else {
            throw CompressionWorkflowError.inputEmpty
        }

        let directory = plan.temporaryURL.deletingLastPathComponent()
        let directoryMetadata = try await runMetadataRead(
            directory,
            jobID: plan.jobID
        )
        guard directoryMetadata?.isDirectory == true else {
            throw CompressionWorkflowError.outputDirectoryUnavailable
        }
        guard try await runMetadataRead(
            plan.temporaryURL,
            jobID: plan.jobID
        ) == nil else {
            throw CompressionWorkflowError.temporaryOutputAlreadyExists
        }
        guard try await runMetadataRead(
            plan.finalURL,
            jobID: plan.jobID
        ) == nil else {
            throw CompressionWorkflowError.finalOutputAlreadyExists
        }
    }

    private func validateTemporaryOutput(
        plan: OutputPlan,
        source: MediaInfo,
        recipe: CompressionRecipe,
        transcodeResult: TranscodeResult,
        reservation: TemporaryOutputReservation
    ) async throws -> FileMetadata {
        let prober = dependencies.mediaProber
        let validator = dependencies.outputValidator
        let fileAccess = dependencies.fileAccess
        let task = Task.detached {
            let expectedMetadata = transcodeResult.temporaryMetadata
            guard let metadata = try await fileAccess.metadata(
                      for: reservation
                  ), metadata == expectedMetadata,
                  !metadata.isDirectory,
                  metadata.byteCount > 0,
                  metadata.byteCount == transcodeResult.byteCount,
                  metadata.identity != nil else {
                throw CompressionWorkflowError.temporaryOutputInvalid
            }
            let output = try await prober.probe(reservation)
            guard let metadataAfterProbe = try await fileAccess.metadata(
                for: reservation
            ), metadataAfterProbe == metadata else {
                throw CompressionWorkflowError.temporaryOutputInvalid
            }
            try validator.validate(
                output: output,
                source: source,
                recipe: recipe
            )
            return metadataAfterProbe
        }
        return try await task.value
    }

    private func claimValidation(jobID: CompressionJob.ID) throws {
        var job = try requireJob(jobID)
        if Task.isCancelled || cancellationIntents.contains(jobID) {
            if case .running(let progress) = job.state {
                try job.transition(
                    to: .cancelling(lastProgress: progress)
                )
                jobsByID[jobID] = job
            }
            throw CancellationError()
        }
        guard case .running = job.state else {
            if case .cancelling = job.state {
                throw CancellationError()
            }
            throw CompressionWorkflowError.workflowStateChanged(
                job.state.phase
            )
        }
        _ = try transition(
            jobID: jobID,
            to: .finishing(.validating)
        )
    }

    private func recordWorkflowProgress(
        _ progress: TranscodeProgress,
        for jobID: CompressionJob.ID
    ) {
        guard let job = jobsByID[jobID] else { return }
        switch job.state {
        case .running, .cancelling:
            _ = try? updateProgress(progress, for: jobID)
        case .draft, .probing, .ready, .queued, .finishing,
             .cancelled, .completed, .failed:
            break
        }
    }

    private func finishWorkflowAfterError(
        _ error: any Error,
        jobID: CompressionJob.ID
    ) async throws -> Never {
        let currentState = jobsByID[jobID]?.state
        let cancellationCanStillWin = currentState.map {
            switch $0.phase {
            case .probing, .ready, .queued, .running, .cancelling,
                 .cancelled:
                true
            case .draft, .finishing, .completed, .failed:
                false
            }
        } ?? false
        let cancellationWon = cancellationCanStillWin
            && (
                cancellationIntents.contains(jobID)
                    || currentState.map {
                        if case .cancelling = $0 { return true }
                        return false
                    } == true
                    || currentState == .cancelled
                    || Task.isCancelled
                    || error is CancellationError
            )
        let cleanupFailed = (error as? CompressionWorkflowError)
            == .temporaryCleanupFailed

        if cancellationWon && !cleanupFailed {
            var shouldCancelProcess = false
            if var job = jobsByID[jobID] {
                switch job.state {
                case .probing, .ready, .queued:
                    if (try? job.transition(to: .cancelled)) != nil {
                        jobsByID[jobID] = job
                    }
                case .running(let progress):
                    if (try? job.transition(
                        to: .cancelling(lastProgress: progress)
                    )) != nil {
                        jobsByID[jobID] = job
                        shouldCancelProcess = true
                    }
                case .cancelling:
                    shouldCancelProcess = true
                case .draft, .cancelled, .completed, .failed, .finishing:
                    break
                }
            }
            if shouldCancelProcess {
                await dependencies.transcoder.cancel(jobID: jobID)
            }
            if var job = jobsByID[jobID],
               case .cancelling = job.state,
               (try? job.transition(to: .cancelled)) != nil {
                    jobsByID[jobID] = job
            }
            throw CancellationError()
        }

        guard let state = jobsByID[jobID]?.state,
              let stage = failureStage(for: state) else {
            throw error
        }
        let failure = makeFailure(stage: stage, error: error)
        _ = try transition(jobID: jobID, to: .failed(failure))
        throw failure
    }

    private func failureStage(for state: JobState) -> FailureStage? {
        switch state {
        case .probing:
            .probe
        case .queued:
            .preflight
        case .running:
            .encode
        case .finishing(.validating):
            .validate
        case .finishing(.committing):
            .commit
        case .cancelling:
            .encode
        case .draft, .ready, .cancelled, .completed, .failed:
            nil
        }
    }

    private func makeFailure(
        stage: FailureStage,
        error: any Error
    ) -> TranscodeFailure {
        if case .processFailed(let termination, let tail) =
            error as? FFprobeClientError {
            return processFailure(
                stage: stage,
                termination: termination,
                tail: tail
            )
        }
        if case .processFailed(let termination, let tail) =
            error as? FFmpegCapabilityClientError {
            return processFailure(
                stage: stage,
                termination: termination,
                tail: tail
            )
        }
        if case .processFailed(let termination, let tail) =
            error as? FFmpegTranscodingServiceError {
            return processFailure(
                stage: stage,
                termination: termination,
                tail: tail
            )
        }

        let reason: FailureReason
        if error is SecurityScopedFileAccessError
            || error is OutputPlannerError {
            reason = .fileSystem
        } else if error is ProcessRunnerError {
            reason = .serviceUnavailable
        } else if let probeError = error as? FFprobeClientError {
            switch probeError {
            case .invalidSourceURL:
                reason = .fileSystem
            case .bundledExecutableUnavailable, .invalidExecutableURL,
                 .invalidConfiguration, .invalidProcessEventSequence,
                 .outputTooLarge:
                reason = .serviceUnavailable
            case .processFailed:
                // Process failures are returned above with their exit status
                // and bounded diagnostic tail.
                reason = .unknown
            }
        } else if let preflightError = error as? FFmpegPreflightError {
            switch preflightError {
            case .unavailableCapability:
                reason = .serviceUnavailable
            case .unsupportedInputFormat, .missingVideoStream,
                 .missingCodecName, .unsupportedDecoder:
                reason = .invalidMedia
            }
        } else if error is FFmpegCapabilityClientError {
            reason = .serviceUnavailable
        } else if let builderError = error as? FFmpegCommandBuilderError {
            switch builderError {
            case .missingVideoStream, .unsupportedVideoFormat:
                reason = .invalidMedia
            case .invalidInputURL, .invalidTemporaryOutputURL,
                 .inputOutputAlias:
                reason = .fileSystem
            }
        } else if let serviceError =
            error as? FFmpegTranscodingServiceError {
            switch serviceError {
            case .temporaryOutputMissing, .invalidTemporaryOutput:
                reason = .fileSystem
            case .bundledExecutableUnavailable, .invalidExecutableURL,
                 .invalidProcessRequest, .invalidTemporaryReservation,
                 .invalidProcessEventSequence, .progressParsing:
                reason = .serviceUnavailable
            case .duplicateJob, .processFailed:
                reason = .unknown
            }
        } else if let workflowError = error as? CompressionWorkflowError {
            switch workflowError {
            case .inputEmpty, .temporaryOutputInvalid:
                reason = .invalidMedia
            case .inputMissing, .outputDirectoryUnavailable,
                 .temporaryOutputAlreadyExists, .finalOutputAlreadyExists:
                reason = .fileSystem
            case .temporaryCleanupFailed:
                reason = .fileSystem
            case .workflowStateChanged:
                reason = .unknown
            }
        } else {
            switch stage {
            case .probe, .validate:
                reason = .invalidMedia
            case .preflight:
                reason = .invalidMedia
            case .encode:
                reason = .unknown
            case .commit:
                reason = .fileSystem
            }
        }
        return TranscodeFailure(
            stage: stage,
            reason: reason,
            diagnosticTail: nil
        )
    }

    private func processFailure(
        stage: FailureStage,
        termination: ProcessTerminationStatus,
        tail: BoundedData
    ) -> TranscodeFailure {
        let diagnostic = boundedDiagnostic(from: tail)
        return TranscodeFailure(
            stage: stage,
            reason: .processFailed(
                exitCode: termination.reason == .exit
                    ? termination.status
                    : nil
            ),
            diagnosticTail: diagnostic
        )
    }

    private func boundedDiagnostic(
        from tail: BoundedData
    ) -> BoundedDiagnostic? {
        let decoded = String(decoding: tail.data, as: UTF8.self)
        var text = ""
        text.reserveCapacity(min(tail.byteLimit, decoded.utf8.count))
        var byteCount = 0

        for scalar in decoded.unicodeScalars {
            let scalarByteCount = String(scalar).utf8.count
            guard byteCount <= tail.byteLimit - scalarByteCount else {
                break
            }
            text.unicodeScalars.append(scalar)
            byteCount += scalarByteCount
        }

        return try? BoundedDiagnostic(
            text: text,
            utf8ByteLimit: tail.byteLimit,
            wasTruncated: tail.wasTruncated
                || byteCount < decoded.utf8.count
        )
    }

    private func runProbe(
        _ sourceURL: URL,
        jobID: CompressionJob.ID
    ) async throws -> MediaInfo {
        let prober = dependencies.mediaProber
        return try await runPreRunOperation(jobID: jobID) {
            try await prober.probe(sourceURL)
        }
    }

    private func runOutputPlanning(
        _ request: OutputPlanningRequest,
        jobID: CompressionJob.ID
    ) async throws -> OutputPlan {
        let planner = dependencies.outputPlanner
        return try await runPreRunOperation(jobID: jobID) {
            try await planner.planOutput(for: request)
        }
    }

    private func runTranscodePreflight(
        _ request: TranscodeRequest,
        jobID: CompressionJob.ID
    ) async throws {
        let transcoder = dependencies.transcoder
        try await runPreRunOperation(jobID: jobID) {
            try await transcoder.preflight(request)
        }
    }

    private func runMetadataRead(
        _ url: URL,
        jobID: CompressionJob.ID
    ) async throws -> FileMetadata? {
        let fileAccess = dependencies.fileAccess
        return try await runPreRunOperation(jobID: jobID) {
            try await fileAccess.metadata(at: url)
        }
    }

    private func runTemporaryReservation(
        _ plan: OutputPlan,
        jobID: CompressionJob.ID
    ) async throws -> TemporaryOutputReservation {
        let fileAccess = dependencies.fileAccess
        return try await runPreRunOperation(jobID: jobID) {
            try await fileAccess.reserveTemporaryOutput(plan)
        }
    }

    private func runPreRunOperation<Value: Sendable>(
        jobID: CompressionJob.ID,
        operation: @escaping @Sendable () async throws -> Value
    ) async throws -> Value {
        let token = UUID()
        let task = Task<Value, any Error> {
            try await operation()
        }
        preRunCancellations[jobID] = PreRunCancellation(
            token: token,
            cancel: { task.cancel() }
        )
        if Task.isCancelled || cancellationIntents.contains(jobID) {
            task.cancel()
        }
        defer {
            if preRunCancellations[jobID]?.token == token {
                preRunCancellations.removeValue(forKey: jobID)
            }
        }

        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    private func runTranscode(
        _ request: TranscodeRequest,
        reservation: TemporaryOutputReservation,
        jobID: CompressionJob.ID
    ) async throws -> TranscodeResult {
        let transcoder = dependencies.transcoder
        let token = UUID()
        let task = Task<TranscodeResult, any Error> { [self] in
            try await transcoder.transcode(
                request,
                reservation: reservation,
                onProgress: { [self] progress in
                    await recordWorkflowProgress(progress, for: jobID)
                }
            )
        }
        transcodeCancellations[jobID] = PreRunCancellation(
            token: token,
            cancel: { task.cancel() }
        )
        if Task.isCancelled || cancellationIntents.contains(jobID) {
            task.cancel()
        }
        defer {
            if transcodeCancellations[jobID]?.token == token {
                transcodeCancellations.removeValue(forKey: jobID)
            }
        }

        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    private func commitWithoutCallerCancellation(
        _ plan: OutputPlan,
        reservation: TemporaryOutputReservation,
        expectedTemporaryMetadata: FileMetadata
    ) async throws {
        let fileAccess = dependencies.fileAccess
        try await Task.detached {
            try await fileAccess.commitWithoutReplacing(
                plan,
                reservation: reservation,
                expectedTemporaryMetadata: expectedTemporaryMetadata
            )
        }.value
    }

    private func cleanupWithoutCallerCancellation(
        _ plan: OutputPlan,
        reservation: TemporaryOutputReservation,
        expectedTemporaryMetadata: FileMetadata?
    ) async throws {
        let fileAccess = dependencies.fileAccess
        let task = Task.detached {
            try await fileAccess.cleanupTemporaryOutput(
                plan,
                reservation: reservation,
                expectedTemporaryMetadata: expectedTemporaryMetadata
            )
        }
        try await task.value
    }

    private func requireJob(_ id: CompressionJob.ID) throws -> CompressionJob {
        guard let job = jobsByID[id] else {
            throw CompressionCoordinatorError.jobNotFound(id)
        }
        return job
    }

    private func requireAvailableActiveSlot(
        for candidate: CompressionJob
    ) throws {
        guard Self.isActive(candidate.state),
              let activeID = jobOrder.first(where: { id in
                  id != candidate.id
                      && jobsByID[id].map { Self.isActive($0.state) } == true
              }) else {
            return
        }

        throw CompressionCoordinatorError.activeJobExists(activeID)
    }

    private static func isActive(_ state: JobState) -> Bool {
        switch state.phase {
        case .running, .finishing, .cancelling:
            true
        case .draft, .probing, .ready, .queued, .cancelled, .completed, .failed:
            false
        }
    }
}
