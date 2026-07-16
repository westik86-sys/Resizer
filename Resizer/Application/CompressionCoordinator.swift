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
    let activeJobID: CompressionJob.ID?
    let isDraining: Bool
    let revision: UInt64

    init(
        jobs: [CompressionJob],
        activeJobID: CompressionJob.ID? = nil,
        isDraining: Bool = false,
        revision: UInt64 = 0
    ) {
        self.jobs = jobs
        self.activeJobID = activeJobID
        self.isDraining = isDraining
        self.revision = revision
    }

    var queuedJobIDs: [CompressionJob.ID] {
        jobs.compactMap { job in
            guard case .queued = job.state,
                  job.id != activeJobID else {
                return nil
            }
            return job.id
        }
    }

    static let empty = CompressionSnapshot(jobs: [])
}

nonisolated struct JobQueueImport: Sendable, Equatable {
    let id: CompressionJob.ID
    let inputURL: URL
    let createdAt: Date
    let mode: CompressionMode

    init(
        inputURL: URL,
        id: CompressionJob.ID = UUID(),
        createdAt: Date = Date(),
        mode: CompressionMode = .automatic
    ) {
        self.id = id
        self.inputURL = inputURL
        self.createdAt = createdAt
        self.mode = mode
    }
}

nonisolated enum CompressionCoordinatorError: Error, Sendable, Equatable {
    case duplicateJob(CompressionJob.ID)
    case jobNotFound(CompressionJob.ID)
    case activeJobExists(CompressionJob.ID)
    case workflowAlreadyRunning(CompressionJob.ID)
    case queueMutationRequiresQueued(CompressionJob.ID)
    case jobNotRemovable(CompressionJob.ID)
    case activeQueueJob(CompressionJob.ID)
    case invalidQueueSuccessor(CompressionJob.ID)
    case shuttingDown
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

private nonisolated enum CompressionWorkflowOutcome: Sendable {
    case completed(CompressionResult)
    case noBenefit(CompressionNoBenefitResult)
}

/// The UI-facing seam preserves the coordinator's actor isolation while
/// allowing deterministic presentation tests to supply an in-memory actor.
/// Its synchronous requirements are actor-isolated and therefore must be
/// called with `await` from the main actor.
nonisolated protocol JobQueueCoordinating: Actor {
    @discardableResult
    func add(
        _ imports: [JobQueueImport]
    ) async throws -> [CompressionJob.ID]

    func createJob(
        inputURL: URL,
        id: CompressionJob.ID,
        createdAt: Date
    ) throws -> CompressionJob

    func prepare(jobID: CompressionJob.ID) async throws -> CompressionJob

    @discardableResult
    func enqueue(
        jobID: CompressionJob.ID,
        configuration: JobConfiguration
    ) throws -> CompressionJob

    func startQueue()

    @discardableResult
    func retryQueued(
        jobID: CompressionJob.ID,
        configuration: JobConfiguration
    ) async throws -> CompressionJob

    func moveQueued(
        jobID: CompressionJob.ID,
        before successorID: CompressionJob.ID?
    ) throws

    func removeJob(jobID: CompressionJob.ID) throws

    func cancel(jobID: CompressionJob.ID) async
    func shutdown() async
    func snapshot() -> CompressionSnapshot
    func snapshots() -> AsyncStream<CompressionSnapshot>
}

/// Low-level workflow operations stay outside the UI-facing queue protocol so
/// production presentation code cannot bypass the single FIFO driver. They
/// remain available to the headless integration and focused workflow tests.
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
    func shutdown() async
    func snapshot() -> CompressionSnapshot
    func snapshots() -> AsyncStream<CompressionSnapshot>
}

extension JobQueueCoordinating {
    /// Lightweight presentation fakes have no child processes to drain.
    /// Production overrides this requirement with the full shutdown barrier.
    func shutdown() async {}
}

actor JobQueueCoordinator: CompressionCoordinating, JobQueueCoordinating {
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
    private var activeQueueJobID: CompressionJob.ID?
    private var queueDriverToken: UUID?
    private var queueDriverTask: Task<Void, Never>?
    private var snapshotRevision: UInt64 = 0
    private var cancellationFailureStages: [
        CompressionJob.ID: FailureStage
    ] = [:]
    private var isShuttingDown = false
    private var workflowDrainWaiters: [
        CheckedContinuation<Void, Never>
    ] = []

    init(dependencies: CompressionCoordinatorDependencies) {
        self.dependencies = dependencies
    }

    deinit {
        queueDriverTask?.cancel()
    }

    /// Registers every selected file before probing begins so concurrent UI
    /// actions can address stable job IDs. Probe/capability failure belongs to
    /// that job and never prevents the remaining imports from being prepared.
    @discardableResult
    func add(
        _ imports: [JobQueueImport]
    ) async throws -> [CompressionJob.ID] {
        guard !isShuttingDown else {
            throw CompressionCoordinatorError.shuttingDown
        }
        let jobs = try imports.map { item in
            try CompressionJob(
                id: item.id,
                inputURL: item.inputURL,
                createdAt: item.createdAt,
                mode: item.mode
            )
        }

        var seenIDs: Set<CompressionJob.ID> = []
        for job in jobs {
            guard jobsByID[job.id] == nil,
                  seenIDs.insert(job.id).inserted else {
                throw CompressionCoordinatorError.duplicateJob(job.id)
            }
            try requireAvailableActiveSlot(for: job)
        }

        for job in jobs {
            jobsByID[job.id] = job
            jobOrder.append(job.id)
        }
        if !jobs.isEmpty {
            publishSnapshot()
        }

        for job in jobs {
            guard !Task.isCancelled,
                  jobsByID[job.id]?.state.phase == .draft else {
                continue
            }
            do {
                _ = try await prepare(jobID: job.id)
            } catch {
                // The workflow records a bounded per-job failure/cancellation.
                // Batch import intentionally proceeds to the next input.
            }
        }

        return jobs.map(\.id)
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
        guard !isShuttingDown else {
            throw CompressionCoordinatorError.shuttingDown
        }
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
                            recipe: try preparationAdmissionRecipe(
                                for: mediaInfo,
                                mode: job.mode
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

    /// Preparation verifies the common video-only path. Audio capability is
    /// validated later against the immutable recipe captured at enqueue, so
    /// an unsupported source audio stream can still be intentionally removed.
    private func preparationAdmissionRecipe(
        for mediaInfo: MediaInfo,
        mode: CompressionMode
    ) throws -> CompressionRecipe {
        switch mode {
        case .automatic:
            try AutomaticCompressionPolicy().recipe(
                for: mediaInfo,
                settings: .quick(audio: .remove)
            )
        case .compactRetry:
            try AutomaticCompressionPolicy().compactRecipe(
                for: mediaInfo,
                audio: .remove
            )
        }
    }

    /// Captures an immutable configuration and appends a prepared job to the
    /// FIFO without starting it. Keeping this transition separate is what
    /// makes queued cancellation, removal, and reordering deterministic.
    @discardableResult
    func enqueue(
        jobID: CompressionJob.ID,
        configuration: JobConfiguration
    ) throws -> CompressionJob {
        guard !isShuttingDown else {
            throw CompressionCoordinatorError.shuttingDown
        }
        let job = try requireJob(jobID)
        guard activeQueueJobID != jobID,
              !workflowJobIDs.contains(jobID) else {
            throw CompressionCoordinatorError.activeQueueJob(jobID)
        }

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
        let queued = try transition(jobID: jobID, to: .queued)
        // FIFO is defined by admission to the waiting queue, not by import
        // time. This also keeps a later retry behind every existing waiter.
        jobOrder.removeAll { $0 == jobID }
        jobOrder.append(jobID)
        publishSnapshot()
        return queued
    }

    /// Starts the single actor-owned driver. Repeated wakeups are no-ops; a
    /// newly enqueued job is observed by the existing loop before it exits.
    func startQueue() {
        guard !isShuttingDown,
              queueDriverTask == nil,
              firstWaitingJobID() != nil else {
            return
        }

        let token = UUID()
        queueDriverToken = token
        queueDriverTask = Task { [weak self] in
            await self?.drainQueue(token: token)
        }
        publishSnapshot()
    }

    /// Restores one terminal job, appends exactly one new attempt to the tail,
    /// and wakes the same FIFO driver used by every other queue entry.
    @discardableResult
    func retryQueued(
        jobID: CompressionJob.ID,
        configuration: JobConfiguration
    ) async throws -> CompressionJob {
        guard !isShuttingDown else {
            throw CompressionCoordinatorError.shuttingDown
        }
        let job = try requireJob(jobID)
        guard activeQueueJobID != jobID,
              !workflowJobIDs.contains(jobID) else {
            throw CompressionCoordinatorError.activeQueueJob(jobID)
        }

        let repeatedPreparation: Bool
        switch job.state {
        case .failed(let failure) where failure.retryTarget == .probing:
            _ = try await prepare(jobID: jobID)
            repeatedPreparation = true
        case .cancelled where job.mediaInfo == nil:
            _ = try await prepare(jobID: jobID)
            repeatedPreparation = true
        case .failed(let failure) where failure.retryTarget == .ready:
            repeatedPreparation = false
        case .cancelled where job.mediaInfo != nil:
            repeatedPreparation = false
        default:
            throw CompressionWorkflowError.workflowStateChanged(
                job.state.phase
            )
        }

        // `prepare` publishes `ready` before returning. A cancellation can win
        // that suspension point; never revive that cancelled attempt.
        if repeatedPreparation {
            let prepared = try requireJob(jobID)
            guard case .ready = prepared.state else {
                throw CompressionWorkflowError.workflowStateChanged(
                    prepared.state.phase
                )
            }
        }

        let queued = try enqueue(
            jobID: jobID,
            configuration: configuration
        )
        startQueue()
        return queued
    }

    func moveQueued(
        jobID: CompressionJob.ID,
        before successorID: CompressionJob.ID?
    ) throws {
        try requireWaitingQueueMutation(jobID)
        if let successorID {
            guard successorID != jobID else { return }
            try requireWaitingQueueMutation(successorID)
        }

        guard let currentIndex = jobOrder.firstIndex(of: jobID) else {
            throw CompressionCoordinatorError.jobNotFound(jobID)
        }
        jobOrder.remove(at: currentIndex)

        if let successorID {
            guard let successorIndex = jobOrder.firstIndex(of: successorID) else {
                throw CompressionCoordinatorError.invalidQueueSuccessor(
                    successorID
                )
            }
            jobOrder.insert(jobID, at: successorIndex)
        } else if let lastWaitingIndex = jobOrder.lastIndex(where: {
            isWaitingQueueJob($0)
        }) {
            jobOrder.insert(jobID, at: lastWaitingIndex + 1)
        } else {
            jobOrder.insert(jobID, at: min(currentIndex, jobOrder.count))
        }
        publishSnapshot()
    }

    func removeJob(jobID: CompressionJob.ID) throws {
        let job = try requireJob(jobID)
        guard jobID != activeQueueJobID,
              !workflowJobIDs.contains(jobID) else {
            throw CompressionCoordinatorError.activeQueueJob(jobID)
        }
        switch job.state {
        case .ready, .queued, .cancelled, .completed, .noBenefit, .failed:
            break
        case .draft, .probing, .running, .finishing, .cancelling:
            throw CompressionCoordinatorError.jobNotRemovable(jobID)
        }
        jobsByID.removeValue(forKey: jobID)
        jobOrder.removeAll { $0 == jobID }
        cancellationIntents.remove(jobID)
        preRunCancellations.removeValue(forKey: jobID)
        transcodeCancellations.removeValue(forKey: jobID)
        publishSnapshot()
    }

    /// Compatibility entry point for the already-tested one-file workflow.
    /// Production UI receives only `JobQueueCoordinating` and cannot call it.
    @discardableResult
    func startPrepared(
        jobID: CompressionJob.ID,
        configuration: JobConfiguration
    ) async throws -> CompressionJob {
        _ = try enqueue(jobID: jobID, configuration: configuration)
        return try await runQueued(jobID: jobID)
    }

    private func runQueued(
        jobID: CompressionJob.ID
    ) async throws -> CompressionJob {
        let job = try requireJob(jobID)
        guard case .queued = job.state,
              let configuration = job.configuration else {
            throw CompressionWorkflowError.workflowStateChanged(
                job.state.phase
            )
        }
        try beginWorkflow(jobID: jobID)
        defer { endWorkflow(jobID: jobID) }

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

        // Draft imports, prepared inputs, and waiting queue entries have no
        // process to stop. Their cancellation is an immediate state change.
        guard workflowJobIDs.contains(jobID) else {
            switch job.state {
            case .draft, .ready, .queued:
                guard (try? job.transition(to: .cancelled)) != nil else {
                    return
                }
                jobsByID[jobID] = job
                publishSnapshot()
            case .probing, .running, .finishing, .cancelling,
                 .cancelled, .completed, .noBenefit, .failed:
                break
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
            cancellationFailureStages[jobID] = .encode
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
        case .finishing(let phase):
            cancellationIntents.insert(jobID)
            cancellationFailureStages[jobID] = switch phase {
            case .validating: .validate
            case .committing: .commit
            }
            preRunCancellations[jobID]?.cancel()
            guard (try? job.transition(
                to: .cancelling(lastProgress: nil)
            )) != nil else {
                return
            }
            jobsByID[jobID] = job
            publishSnapshot()
            return
        case .draft, .cancelled, .completed, .noBenefit, .failed:
            return
        }

        await dependencies.transcoder.cancel(jobID: jobID)
    }

    /// Stops admission, cancels every active or waiting job, and does not
    /// return until all workflow tasks have completed their exact cleanup.
    /// The application delegate uses this barrier before acknowledging a
    /// normal macOS termination request, preventing orphan encoder children.
    func shutdown() async {
        if !isShuttingDown {
            isShuttingDown = true
            queueDriverTask?.cancel()
            publishSnapshot()
        }

        let jobIDs = jobOrder
        for jobID in jobIDs {
            await cancel(jobID: jobID)
        }

        await waitForWorkflowDrain()

        // A queue driver can be between its workflow return and its final
        // actor hop after the workflow set becomes empty.
        if let queueDriverTask {
            queueDriverTask.cancel()
            await queueDriverTask.value
        }
    }

    func job(id: CompressionJob.ID) -> CompressionJob? {
        jobsByID[id]
    }

    func snapshot() -> CompressionSnapshot {
        CompressionSnapshot(
            jobs: jobOrder.compactMap { jobsByID[$0] },
            activeJobID: activeQueueJobID,
            isDraining: queueDriverTask != nil,
            revision: snapshotRevision
        )
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
        let outcome = try await runScopedWorkflowToOutcome(
            jobID: jobID,
            configuration: configuration,
            shouldProbeInput: shouldProbeInput,
            startedAt: startedAt,
            clock: clock
        )
        switch outcome {
        case .completed(let result):
            return try transition(jobID: jobID, to: .completed(result))
        case .noBenefit(let result):
            return try transition(jobID: jobID, to: .noBenefit(result))
        }
    }

    private func runScopedWorkflowToOutcome(
        jobID: CompressionJob.ID,
        configuration: JobConfiguration,
        shouldProbeInput: Bool,
        startedAt: ContinuousClock.Instant,
        clock: ContinuousClock
    ) async throws -> CompressionWorkflowOutcome {
        var outputPlan: OutputPlan?
        var outputReservation: TemporaryOutputReservation?
        var expectedTemporaryMetadata: FileMetadata?
        var cleanupAttempted = false
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

            let sourceMetadata = try await validateFilePreflight(plan)
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
                reservation: reservation,
                jobID: jobID
            )

            if validatedOutput.byteCount >= sourceMetadata.byteCount {
                cleanupAttempted = true
                do {
                    try await cleanupWithoutCallerCancellation(
                        plan,
                        reservation: reservation,
                        expectedTemporaryMetadata: validatedOutput
                    )
                } catch {
                    throw CompressionWorkflowError.temporaryCleanupFailed
                }
                expectedTemporaryMetadata = nil
                let result = try CompressionNoBenefitResult(
                    sourceByteCount: sourceMetadata.byteCount,
                    candidateByteCount: validatedOutput.byteCount,
                    elapsed: startedAt.duration(to: clock.now)
                )
                return .noBenefit(result)
            }

            _ = try transition(
                jobID: jobID,
                to: .finishing(.committing)
            )
            try await commitCancellableUntilPublication(
                plan,
                reservation: reservation,
                expectedTemporaryMetadata: validatedOutput,
                jobID: jobID
            )
            didCommit = true

            let result = try CompressionResult(
                outputURL: plan.finalURL,
                sourceByteCount: sourceMetadata.byteCount,
                outputByteCount: validatedOutput.byteCount,
                elapsed: startedAt.duration(to: clock.now)
            )
            return .completed(result)
        } catch {
            if let outputPlan,
               let outputReservation,
               expectedTemporaryMetadata != nil,
               !cleanupAttempted,
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

    private func validateFilePreflight(
        _ plan: OutputPlan
    ) async throws -> FileMetadata {
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
        return input
    }

    private func validateTemporaryOutput(
        plan: OutputPlan,
        source: MediaInfo,
        recipe: CompressionRecipe,
        transcodeResult: TranscodeResult,
        reservation: TemporaryOutputReservation,
        jobID: CompressionJob.ID
    ) async throws -> FileMetadata {
        let prober = dependencies.mediaProber
        let validator = dependencies.outputValidator
        let fileAccess = dependencies.fileAccess
        return try await runPreRunOperation(jobID: jobID) {
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
             .cancelled, .completed, .noBenefit, .failed:
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
                 .finishing, .cancelled:
                true
            case .draft, .completed, .noBenefit, .failed:
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
                    shouldCancelProcess =
                        (cancellationFailureStages[jobID] ?? .encode)
                        == .encode
                case .finishing(let phase):
                    cancellationFailureStages[jobID] = switch phase {
                    case .validating: .validate
                    case .committing: .commit
                    }
                    if (try? job.transition(
                        to: .cancelling(lastProgress: nil)
                    )) != nil {
                        jobsByID[jobID] = job
                    }
                case .draft, .cancelled, .completed, .noBenefit, .failed:
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
              let stage = failureStage(for: state, jobID: jobID) else {
            throw error
        }
        let failure = makeFailure(stage: stage, error: error)
        _ = try transition(jobID: jobID, to: .failed(failure))
        throw failure
    }

    private func failureStage(
        for state: JobState,
        jobID: CompressionJob.ID
    ) -> FailureStage? {
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
            cancellationFailureStages[jobID] ?? .encode
        case .draft, .ready, .cancelled, .completed, .noBenefit, .failed:
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
        if let fileError = error as? SecurityScopedFileAccessError {
            switch fileError {
            case .inputMissing:
                reason = .inputUnavailable
            case .outputDirectoryMissing, .reservationFailed,
                 .commitFailed, .invalidOutputPlan:
                reason = .outputUnavailable
            case .temporaryOutputAlreadyExists, .finalOutputAlreadyExists:
                reason = .outputConflict
            case .unsupportedOutputFileSystem:
                reason = .unsupportedOutputFileSystem
            case .insufficientStorage:
                reason = .insufficientStorage
            case .invalidURL, .temporaryOutputMissing,
                 .temporaryOutputChanged, .symbolicLinkNotAllowed,
                 .unsupportedFileType, .inputOutputAlias,
                 .metadataReadFailed, .cleanupFailed:
                reason = .fileSystem
            }
        } else if let plannerError = error as? OutputPlannerError {
            switch plannerError {
            case .invalidInputURL:
                reason = .inputUnavailable
            case .invalidOutputDirectoryURL:
                reason = .outputUnavailable
            case .outputCollision, .temporaryCollision:
                reason = .outputConflict
            case .invalidOutputName, .invalidGeneratedPlan:
                reason = .fileSystem
            }
        } else if error is ProcessRunnerError {
            reason = .serviceUnavailable
        } else if let probeError = error as? FFprobeClientError {
            switch probeError {
            case .invalidSourceURL:
                reason = .inputUnavailable
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
            case .invalidInputURL:
                reason = .inputUnavailable
            case .invalidTemporaryOutputURL:
                reason = .outputUnavailable
            case .inputOutputAlias:
                reason = .outputConflict
            }
        } else if let serviceError =
            error as? FFmpegTranscodingServiceError {
            switch serviceError {
            case .temporaryOutputMissing, .invalidTemporaryOutput:
                reason = .outputUnavailable
            case .bundledExecutableUnavailable, .invalidExecutableURL,
                 .invalidProcessRequest, .invalidTemporaryReservation,
                 .invalidProcessEventSequence, .progressParsing:
                reason = .serviceUnavailable
            case .duplicateJob, .processFailed:
                reason = .unknown
            }
        } else if let workflowError = error as? CompressionWorkflowError {
            switch workflowError {
            case .inputEmpty:
                reason = .invalidMedia
            case .inputMissing:
                reason = .inputUnavailable
            case .outputDirectoryUnavailable:
                reason = .outputUnavailable
            case .temporaryOutputAlreadyExists, .finalOutputAlreadyExists:
                reason = .outputConflict
            case .temporaryOutputInvalid:
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
            diagnosticTail: nil,
            technicalCode: failureTechnicalCode(for: error)
        )
    }

    private func failureTechnicalCode(
        for error: any Error
    ) -> FailureTechnicalCode? {
        if let runnerError = error as? ProcessRunnerError {
            switch runnerError {
            case .executionIDAlreadyUsed:
                return .processExecutionIDAlreadyUsed
            case .standardInputConfigurationFailed:
                return .processStandardInputConfigurationFailed
            case .standardOutputConfigurationFailed:
                return .processStandardOutputConfigurationFailed
            case .launchFailed:
                return .processLaunchFailed
            case .outputReadFailed(_, let channel):
                return switch channel {
                case .standardOutput: .processStandardOutputReadFailed
                case .standardError: .processStandardErrorReadFailed
                }
            case .eventBufferOverflow:
                return .processEventBufferOverflow
            }
        }

        guard let serviceError = error as? FFmpegTranscodingServiceError else {
            return nil
        }
        return switch serviceError {
        case .bundledExecutableUnavailable:
            .transcoderExecutableUnavailable
        case .invalidExecutableURL:
            .transcoderExecutableInvalid
        case .duplicateJob:
            .transcoderDuplicateJob
        case .invalidProcessRequest:
            .transcoderInvalidProcessRequest
        case .invalidTemporaryReservation:
            .transcoderInvalidTemporaryReservation
        case .invalidProcessEventSequence:
            .transcoderInvalidProcessEventSequence
        case .progressParsing:
            .transcoderProgressProtocolError
        case .temporaryOutputMissing:
            .transcoderTemporaryOutputMissing
        case .invalidTemporaryOutput:
            .transcoderTemporaryOutputInvalid
        case .processFailed:
            nil
        }
    }

    private func processFailure(
        stage: FailureStage,
        termination: ProcessTerminationStatus,
        tail: BoundedData
    ) -> TranscodeFailure {
        let diagnostic = boundedDiagnostic(from: tail)
        let normalizedDiagnostic = String(
            decoding: tail.data,
            as: UTF8.self
        ).lowercased()
        let reason: FailureReason
        if stage != .probe,
           normalizedDiagnostic.contains("no space left on device")
            || normalizedDiagnostic.contains("disk quota exceeded") {
            reason = .insufficientStorage
        } else {
            reason = .processFailed(
                exitCode: termination.reason == .exit
                    ? termination.status
                    : nil
            )
        }
        return TranscodeFailure(
            stage: stage,
            reason: reason,
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

    private func commitCancellableUntilPublication(
        _ plan: OutputPlan,
        reservation: TemporaryOutputReservation,
        expectedTemporaryMetadata: FileMetadata,
        jobID: CompressionJob.ID
    ) async throws {
        let fileAccess = dependencies.fileAccess
        try await runPreRunOperation(jobID: jobID) {
            try await fileAccess.commitWithoutReplacing(
                plan,
                reservation: reservation,
                expectedTemporaryMetadata: expectedTemporaryMetadata
            )
        }
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
        guard !isShuttingDown else {
            throw CompressionCoordinatorError.shuttingDown
        }
        guard workflowJobIDs.insert(jobID).inserted else {
            throw CompressionCoordinatorError.workflowAlreadyRunning(jobID)
        }
    }

    private func endWorkflow(jobID: CompressionJob.ID) {
        workflowJobIDs.remove(jobID)
        cancellationIntents.remove(jobID)
        cancellationFailureStages.removeValue(forKey: jobID)
        preRunCancellations.removeValue(forKey: jobID)
        transcodeCancellations.removeValue(forKey: jobID)

        if workflowJobIDs.isEmpty {
            let waiters = workflowDrainWaiters
            workflowDrainWaiters.removeAll(keepingCapacity: false)
            for waiter in waiters {
                waiter.resume()
            }
        }
    }

    private func waitForWorkflowDrain() async {
        guard !workflowJobIDs.isEmpty else { return }
        await withCheckedContinuation { continuation in
            workflowDrainWaiters.append(continuation)
        }
    }

    private func firstWaitingJobID() -> CompressionJob.ID? {
        jobOrder.first(where: { isWaitingQueueJob($0) })
    }

    private func isWaitingQueueJob(_ jobID: CompressionJob.ID) -> Bool {
        guard jobID != activeQueueJobID,
              !workflowJobIDs.contains(jobID),
              let job = jobsByID[jobID],
              case .queued = job.state else {
            return false
        }
        return true
    }

    private func requireWaitingQueueMutation(
        _ jobID: CompressionJob.ID
    ) throws {
        let job = try requireJob(jobID)
        guard case .queued = job.state else {
            throw CompressionCoordinatorError.queueMutationRequiresQueued(
                jobID
            )
        }
        guard jobID != activeQueueJobID,
              !workflowJobIDs.contains(jobID) else {
            throw CompressionCoordinatorError.activeQueueJob(jobID)
        }
    }

    private func drainQueue(token: UUID) async {
        while queueDriverToken == token,
              !isShuttingDown,
              !Task.isCancelled {
            guard activeQueueJobID == nil else {
                finishQueueDriver(token: token)
                return
            }
            guard let jobID = firstWaitingJobID() else {
                finishQueueDriver(token: token)
                return
            }

            // Claim the head before the first await. Every concurrent wakeup,
            // reorder, remove, or cancel observes this ownership immediately.
            activeQueueJobID = jobID
            publishSnapshot()

            do {
                _ = try await runQueued(jobID: jobID)
            } catch {
                terminalizeUnexpectedQueueDriverError(jobID: jobID)
            }

            if activeQueueJobID == jobID {
                activeQueueJobID = nil
                publishSnapshot()
            }
        }

        finishQueueDriver(token: token)
    }

    private func terminalizeUnexpectedQueueDriverError(
        jobID: CompressionJob.ID
    ) {
        guard let job = jobsByID[jobID],
              case .queued = job.state else {
            return
        }
        _ = try? transition(
            jobID: jobID,
            to: .failed(
                TranscodeFailure(
                    stage: .preflight,
                    reason: .unknown,
                    diagnosticTail: nil
                )
            )
        )
    }

    private func finishQueueDriver(token: UUID) {
        guard queueDriverToken == token else { return }
        activeQueueJobID = nil
        queueDriverToken = nil
        queueDriverTask = nil
        publishSnapshot()
    }

    private func publishSnapshot() {
        snapshotRevision &+= 1
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
        case .draft, .probing, .ready, .queued, .cancelled, .completed,
             .noBenefit, .failed:
            false
        }
    }
}

/// Source compatibility for the completed single-file stages and their
/// headless tests. New production code names the queue-owning actor directly.
typealias CompressionCoordinator = JobQueueCoordinator
