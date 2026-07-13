import Foundation

nonisolated struct CompressionCoordinatorDependencies: Sendable {
    let mediaProber: any MediaProbing
    let transcoder: any Transcoding
    let outputPlanner: any OutputPlanning
    let fileAccess: any FileAccessing
}

nonisolated struct CompressionSnapshot: Sendable, Equatable {
    let jobs: [CompressionJob]

    static let empty = CompressionSnapshot(jobs: [])
}

nonisolated enum CompressionCoordinatorError: Error, Sendable, Equatable {
    case duplicateJob(CompressionJob.ID)
    case jobNotFound(CompressionJob.ID)
    case activeJobExists(CompressionJob.ID)
}

actor CompressionCoordinator {
    private let dependencies: CompressionCoordinatorDependencies
    private var jobsByID: [CompressionJob.ID: CompressionJob] = [:]
    private var jobOrder: [CompressionJob.ID] = []

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

    func job(id: CompressionJob.ID) -> CompressionJob? {
        jobsByID[id]
    }

    func snapshot() -> CompressionSnapshot {
        CompressionSnapshot(jobs: jobOrder.compactMap { jobsByID[$0] })
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
