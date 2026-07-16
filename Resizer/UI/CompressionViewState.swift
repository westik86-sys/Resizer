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

extension CompressionFailurePresentation {
    nonisolated var title: String {
        switch self {
        case .cancelled:
            String(localized: "Compression cancelled")
        case .transcode(let failure):
            switch failure.stage {
            case .probe: String(localized: "Couldn’t read this video")
            case .preflight:
                String(localized: "Couldn’t prepare compression")
            case .encode: String(localized: "Compression failed")
            case .validate:
                String(localized: "Couldn’t validate the compressed copy")
            case .commit:
                String(localized: "Couldn’t save the compressed copy")
            }
        }
    }

    nonisolated var detail: String {
        switch self {
        case .cancelled:
            String(
                localized: "No final output was published. You can safely retry."
            )
        case .transcode(let failure):
            switch failure.reason {
            case .serviceUnavailable:
                String(
                    localized: "The bundled video tools or required encoder are unavailable."
                )
            case .invalidMedia:
                String(
                    localized: "The selected video contains media this version cannot process."
                )
            case .inputUnavailable:
                String(
                    localized: "The source video is no longer available. Select it again and retry."
                )
            case .outputUnavailable:
                String(
                    localized: "The output folder is unavailable. Reconnect the disk or choose another folder."
                )
            case .outputConflict:
                String(
                    localized: "The intended output name is already in use. Choose automatic numbering or another folder."
                )
            case .unsupportedOutputFileSystem:
                String(
                    localized: "This output disk cannot publish files safely. Choose another folder."
                )
            case .insufficientStorage:
                String(
                    localized: "There is not enough free space in the output folder. Free some space and retry."
                )
            case .processFailed:
                String(
                    localized: "The bundled video tool stopped unexpectedly. Retry or open Diagnostics for technical details."
                )
            case .fileSystem:
                String(
                    localized: "Check that the selected file and output folder are still available."
                )
            case .unknown:
                String(
                    localized: "The operation stopped unexpectedly. Diagnostics may contain more detail."
                )
            }
        }
    }
}

/// Detail presentation for the currently selected queue item.
///
/// Persistent workflow state always comes from `CompressionJob.state`.
/// `importing` and `validationError` are the only transient UI-owned cases.
nonisolated enum CompressionViewState: Sendable, Equatable {
    case empty
    case importing
    case probing(CompressionJob)
    case ready(CompressionJob)
    case queued(CompressionJob, position: Int)
    case running(CompressionJob, CompressionRunningStage)
    case cancelling(CompressionJob, TranscodeProgress?)
    case success(CompressionJob, CompressionResult)
    case noBenefit(CompressionJob, CompressionNoBenefitResult)
    case failure(CompressionJob, CompressionFailurePresentation)
    case validationError(String)
}
