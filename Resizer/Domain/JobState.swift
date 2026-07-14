nonisolated enum JobPhase: String, CaseIterable, Sendable, Equatable {
    case draft
    case probing
    case ready
    case queued
    case running
    case finishing
    case cancelling
    case cancelled
    case completed
    case failed
}

nonisolated enum FinishingPhase: Sendable, Equatable {
    case validating
    case committing
}

nonisolated enum RetryTarget: Sendable, Equatable {
    case probing
    case ready
}

nonisolated enum JobState: Sendable, Equatable {
    case draft
    case probing
    case ready
    case queued
    case running(progress: TranscodeProgress?)
    case finishing(FinishingPhase)
    case cancelling(lastProgress: TranscodeProgress?)
    case cancelled
    case completed(CompressionResult)
    case failed(TranscodeFailure)

    var phase: JobPhase {
        switch self {
        case .draft:
            .draft
        case .probing:
            .probing
        case .ready:
            .ready
        case .queued:
            .queued
        case .running:
            .running
        case .finishing:
            .finishing
        case .cancelling:
            .cancelling
        case .cancelled:
            .cancelled
        case .completed:
            .completed
        case .failed:
            .failed
        }
    }

    func canTransition(to next: JobState) -> Bool {
        switch (self, next) {
        case (.draft, .probing):
            true
        case (.probing, .ready):
            true
        case (.probing, .failed(let failure)):
            failure.stage == .probe
        case (.probing, .cancelled):
            true
        case (.ready, .queued):
            true
        case (.ready, .cancelled):
            true
        case (.queued, .running):
            true
        case (.queued, .failed(let failure)):
            failure.stage == .preflight
        case (.queued, .cancelled):
            true
        case (.running, .finishing(.validating)):
            true
        case (.running, .cancelling):
            true
        case (.running, .failed(let failure)):
            failure.stage == .encode
        case (.finishing(.validating), .finishing(.committing)):
            true
        case (.finishing(.validating), .failed(let failure)):
            failure.stage == .validate
        case (.finishing(.committing), .completed):
            true
        case (.finishing(.committing), .failed(let failure)):
            failure.stage == .commit
        case (.cancelling, .cancelled):
            true
        case (.cancelling, .failed(let failure)):
            failure.stage == .encode && failure.reason == .fileSystem
        case (.cancelled, .ready):
            true
        case (.cancelled, .probing):
            true
        case (.failed(let failure), .probing):
            failure.retryTarget == .probing
        case (.failed(let failure), .ready):
            failure.retryTarget == .ready
        default:
            false
        }
    }

    func transitioning(to next: JobState) throws -> JobState {
        guard canTransition(to: next) else {
            throw JobTransitionError(from: phase, to: next.phase)
        }
        return next
    }
}

nonisolated struct JobTransitionError: Error, Sendable, Equatable {
    let from: JobPhase
    let to: JobPhase
}
