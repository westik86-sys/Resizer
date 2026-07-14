import Foundation

nonisolated struct CompressionJob: Identifiable, Sendable, Equatable {
    let id: UUID
    let inputURL: URL
    let createdAt: Date

    private(set) var mediaInfo: MediaInfo?
    private(set) var configuration: JobConfiguration?
    private(set) var state: JobState

    init(
        id: UUID = UUID(),
        inputURL: URL,
        createdAt: Date = Date()
    ) throws {
        guard inputURL.isFileURL else {
            throw CompressionJobValidationError.invalidInputURL
        }
        self.id = id
        self.inputURL = inputURL
        self.createdAt = createdAt
        mediaInfo = nil
        configuration = nil
        state = .draft
    }

    mutating func transition(to next: JobState) throws {
        let transitionedState = try state.transitioning(to: next)
        try validatePrerequisites(for: transitionedState)
        if transitionedState.phase == .probing {
            mediaInfo = nil
            configuration = nil
        }
        state = transitionedState
    }

    mutating func recordMediaInfo(_ mediaInfo: MediaInfo) throws {
        guard state.phase == .probing else {
            throw CompressionJobMutationError.operationRequires(.probing)
        }
        self.mediaInfo = mediaInfo
    }

    mutating func configure(_ configuration: JobConfiguration) throws {
        guard state.phase == .ready else {
            throw CompressionJobMutationError.operationRequires(.ready)
        }
        self.configuration = configuration
    }

    mutating func updateProgress(_ progress: TranscodeProgress) throws {
        switch state {
        case .running:
            state = .running(progress: progress)
        case .cancelling:
            state = .cancelling(lastProgress: progress)
        default:
            throw CompressionJobMutationError.operationRequires(.running)
        }
    }

    private func validatePrerequisites(for next: JobState) throws {
        if case .completed(let result) = next,
           result.outputURL.standardizedFileURL == inputURL.standardizedFileURL {
            throw CompressionJobMutationError.outputAliasesInput
        }

        switch next.phase {
        case .ready:
            guard mediaInfo != nil else {
                throw CompressionJobMutationError.missingMediaInfo
            }
        case .cancelled where state.phase == .probing
            || state.phase == .ready:
            break
        case .queued, .running, .finishing, .cancelling, .cancelled, .completed:
            guard mediaInfo != nil else {
                throw CompressionJobMutationError.missingMediaInfo
            }
            guard configuration != nil else {
                throw CompressionJobMutationError.missingConfiguration
            }
        case .draft, .probing, .failed:
            break
        }
    }
}

nonisolated enum CompressionJobValidationError: Error, Sendable, Equatable {
    case invalidInputURL
}

nonisolated enum CompressionJobMutationError: Error, Sendable, Equatable {
    case missingMediaInfo
    case missingConfiguration
    case outputAliasesInput
    case operationRequires(JobPhase)
}
