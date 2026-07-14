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

/// The UI-facing seam preserves the coordinator's actor isolation while
/// allowing deterministic presentation tests to supply an in-memory actor.
/// Its synchronous requirements are actor-isolated and therefore must be
/// called with `await` from the main actor.
nonisolated protocol CompressionCoordinating: Actor {
    func createJob(
        inputURL: URL,
        id: CompressionJob.ID,
        createdAt: Date
    ) throws -> CompressionJob

    func prepare(jobID: CompressionJob.ID) async throws -> CompressionJob

    func startPrepared(
        jobID: CompressionJob.ID,
        configuration: JobConfiguration
    ) async throws -> CompressionJob

    func retry(
        jobID: CompressionJob.ID,
        configuration: JobConfiguration
    ) async throws -> CompressionJob

    func cancel(jobID: CompressionJob.ID) async
    func snapshot() -> CompressionSnapshot
    func snapshots() -> AsyncStream<CompressionSnapshot>
}

actor CompressionCoordinator: CompressionCoordinating {
    private let dependencies: CompressionCoordinatorDependencies
    private var jobsByID: [CompressionJob.ID: CompressionJob] = [:]
    private var jobOrder: [CompressionJob.ID] = []
    private var snapshotContinuations: [
        UUID: AsyncStream<CompressionSnapshot>.Continuation
    ] = [:]
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
        publishSnapshot()
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
        publishSnapshot()
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
        publishSnapshot()
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
        publishSnapshot()
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
        publishSnapshot()
        return job
    }

    /// Probes one selected input and intentionally stops in `ready` so the UI
    /// can present metadata and let the user choose a typed configuration.
    @discardableResult
    func prepare(jobID: CompressionJob.ID) async throws -> CompressionJob {
        let job = try requireJob(jobID)
        try beginWorkflow(jobID: jobID)
        defer { endWorkflow(jobID: jobID) }

        _ = try transition(jobID: jobID, to: .probing)

        return try await withTaskCancellationHandler {
            do {
                return try await dependencies.fileAccess
                    .withSecurityScopedAccess(to: [job.inputURL]) { [self] in
                        let mediaInfo = try await runProbe(
                            job.inputURL,
                            jobID: jobID
                        )
                        try await runCapabilityValidation(
                            mediaInfo,
                            recipe: CompressionRecipe(
                                preset: .default
                            ),
                            jobID: jobID
                        )
                        return try await finishPreparation(
                            mediaInfo,
                            jobID: jobID
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

    /// Runs encode/validate/commit for a job whose input was already probed.
    /// Retrying an encode-side failure reuses its immutable probe result while
    /// still rebuilding the complete typed configuration and output plan.
    @discardableResult
    func startPrepared(
        jobID: CompressionJob.ID,
        configuration: JobConfiguration
    ) async throws -> CompressionJob {
        let job = try requireJob(jobID)
        try beginWorkflow(jobID: jobID)
        defer { endWorkflow(jobID: jobID) }

        switch job.state {
        case .ready:
            break
        case .failed(let failure) where failure.retryTarget == .ready:
            _ = try transition(jobID: jobID, to: .ready)
        case .cancelled where job.mediaInfo != nil:
            _ = try transition(jobID: jobID, to: .ready)
        default:
            throw CompressionWorkflowError.workflowStateChanged(
                job.state.phase
            )
        }
        _ = try configure(configuration, for: jobID)
        _ = try transition(jobID: jobID, to: .queued)

        return try await runWorkflowWithSelectedAccess(
            jobID: jobID,
            configuration: configuration,
            shouldProbeInput: false
        )
    }

    /// Executes the complete headless workflow while retaining security-scoped
    /// access to both user-selected locations.
    @discardableResult
    func process(
        jobID: CompressionJob.ID,
        configuration: JobConfiguration
    ) async throws -> CompressionJob {
        _ = try requireJob(jobID)
        try beginWorkflow(jobID: jobID)
        defer { endWorkflow(jobID: jobID) }

        _ = try transition(jobID: jobID, to: .probing)
        return try await runWorkflowWithSelectedAccess(
            jobID: jobID,
            configuration: configuration,
            shouldProbeInput: true
        )
    }

    /// Routes the Retry action through the state machine instead of creating a
    /// second job. Probe failures repeat only preparation; later failures and
    /// encode cancellations restart from the retained ready metadata.
    @discardableResult
    func retry(
        jobID: CompressionJob.ID,
        configuration: JobConfiguration
    ) async throws -> CompressionJob {
        let job = try requireJob(jobID)
        switch job.state {
        case .failed(let failure) where failure.retryTarget == .probing:
            return try await prepare(jobID: jobID)
        case .failed(let failure) where failure.retryTarget == .ready:
            return try await startPrepared(
                jobID: jobID,
                configuration: configuration
            )
        case .cancelled where job.mediaInfo == nil:
            return try await prepare(jobID: jobID)
        case .cancelled:
            return try await startPrepared(
                jobID: jobID,
                configuration: configuration
            )
        default:
            throw CompressionWorkflowError.workflowStateChanged(
                job.state.phase
            )
        }
    }

    private func runWorkflowWithSelectedAccess(
        jobID: CompressionJob.ID,
        configuration: JobConfiguration,
        shouldProbeInput: Bool
    ) async throws -> CompressionJob {
        let job = try requireJob(jobID)
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
                            shouldProbeInput: shouldProbeInput,
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
        guard var job = jobsByID[jobID] else { return }

        // Preparation intentionally ends at `ready`. At that point there is
        // no process to cancel, but the single active slot still has to be
        // released before the UI can select a different input.
        guard workflowJobIDs.contains(jobID) else {
            if case .ready = job.state,
               (try? job.transition(to: .cancelled)) != nil {
                jobsByID[jobID] = job
                publishSnapshot()
            }
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
            if (try? job.transition(to: .cancelled)) != nil {
                jobsByID[jobID] = job
                publishSnapshot()
            }
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
            publishSnapshot()
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

    /// Delivers the current snapshot immediately and then only the newest
    /// pending value, preventing a slow UI consumer from accumulating progress
    /// updates in memory.
    func snapshots() -> AsyncStream<CompressionSnapshot> {
        let identifier = UUID()
        let pair = AsyncStream<CompressionSnapshot>.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )
        snapshotContinuations[identifier] = pair.continuation
        pair.continuation.onTermination = { [weak self] _ in
            Task {
                await self?.removeSnapshotContinuation(identifier)
            }
        }
        pair.continuation.yield(snapshot())
        return pair.stream
    }

    private func runScopedWorkflow(
        jobID: CompressionJob.ID,
        configuration: JobConfiguration,
        shouldProbeInput: Bool,
        startedAt: ContinuousClock.Instant,
        clock: ContinuousClock
    ) async throws -> CompressionJob {
        var outputPlan: OutputPlan?
        var outputReservation: TemporaryOutputReservation?
        var expectedTemporaryMetadata: FileMetadata?
        var didCommit = false

        do {
            let job = try requireJob(jobID)
            let inputURL = job.inputURL
            let sourceMedia: MediaInfo
            if shouldProbeInput {
                sourceMedia = try await runProbe(
                    inputURL,
                    jobID: jobID
                )
                _ = try recordMediaInfo(sourceMedia, for: jobID)
                _ = try transition(jobID: jobID, to: .ready)
                _ = try configure(configuration, for: jobID)
                _ = try transition(jobID: jobID, to: .queued)
            } else {
                guard case .queued = job.state,
                      let preparedMedia = job.mediaInfo else {
                    throw CompressionWorkflowError.workflowStateChanged(
                        job.state.phase
                    )
                }
                sourceMedia = preparedMedia
            }

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
                publishSnapshot()
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
            publishSnapshot()
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

    private func runCapabilityValidation(
        _ mediaInfo: MediaInfo,
        recipe: CompressionRecipe,
        jobID: CompressionJob.ID
    ) async throws {
        let transcoder = dependencies.transcoder
        try await runPreRunOperation(jobID: jobID) {
            try await transcoder.validateCapabilities(
                for: mediaInfo,
                recipe: recipe
            )
        }
    }

    /// The last cancellation check, media publication, and transition to
    /// `ready` are one actor-isolated critical section. A cancel that wins the
    /// actor before this method is observed; a later cancel sees `ready` and
    /// moves the job directly to `cancelled`.
    private func finishPreparation(
        _ mediaInfo: MediaInfo,
        jobID: CompressionJob.ID
    ) throws -> CompressionJob {
        guard !Task.isCancelled,
              !cancellationIntents.contains(jobID) else {
            throw CancellationError()
        }
        _ = try recordMediaInfo(mediaInfo, for: jobID)
        return try transition(jobID: jobID, to: .ready)
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

    private func beginWorkflow(jobID: CompressionJob.ID) throws {
        guard workflowJobIDs.insert(jobID).inserted else {
            throw CompressionCoordinatorError.workflowAlreadyRunning(jobID)
        }
    }

    private func endWorkflow(jobID: CompressionJob.ID) {
        workflowJobIDs.remove(jobID)
        cancellationIntents.remove(jobID)
        preRunCancellations.removeValue(forKey: jobID)
        transcodeCancellations.removeValue(forKey: jobID)
    }

    private func publishSnapshot() {
        let value = snapshot()
        for continuation in snapshotContinuations.values {
            continuation.yield(value)
        }
    }

    private func removeSnapshotContinuation(_ identifier: UUID) {
        snapshotContinuations.removeValue(forKey: identifier)
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
