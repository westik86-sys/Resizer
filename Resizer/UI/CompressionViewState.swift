import Foundation

nonisolated enum CompressionRunningStage: Sendable, Equatable {
    case preparing
    case encoding(TranscodeProgress?)
    case validating
    case committing
}

nonisolated enum CompressionFailurePresentation: Sendable, Equatable {
    case transcode(TranscodeFailure)
    case cancelled
}

/// A single presentation state for the one-file workflow.
///
/// Persistent workflow state always comes from `CompressionJob.state`.
/// `importing` and `validationError` are the only transient UI-owned cases.
nonisolated enum CompressionViewState: Sendable, Equatable {
    case empty
    case importing
    case probing(CompressionJob)
    case ready(CompressionJob)
    case running(CompressionJob, CompressionRunningStage)
    case cancelling(CompressionJob, TranscodeProgress?)
    case success(CompressionJob, CompressionResult)
    case failure(CompressionJob, CompressionFailurePresentation)
    case validationError(String)
}
