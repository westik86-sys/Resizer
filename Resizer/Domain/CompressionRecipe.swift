import Foundation

nonisolated struct CompressionRecipe: Sendable, Equatable {
    let origin: RecipeOrigin
    let container: OutputContainer
    let videoCodec: VideoCodec
    let rateControl: RateControl
    let scalePolicy: ScalePolicy
    let frameRatePolicy: FrameRatePolicy
    let audioPolicy: AudioPolicy
    let metadataPolicy: MetadataPolicy
}

nonisolated enum RecipeOrigin: Sendable, Equatable {
    case mode(CompressionMode)
}

nonisolated enum CompressionMode: Sendable, Equatable {
    case automatic
    case compactRetry
}

nonisolated enum OutputContainer: Sendable, Equatable {
    case mp4
}

nonisolated enum VideoCodec: Sendable, Equatable {
    case h264VideoToolbox
}

nonisolated enum RateControl: Sendable, Equatable {
    case quality(VideoQuality)
}

nonisolated struct VideoQuality: Sendable, Equatable {
    let value: Double

    init(_ value: Double) throws {
        guard value.isFinite, (0 ... 1).contains(value) else {
            throw CompressionRecipeValidationError.invalidVideoQuality
        }
        self.value = value
    }
}

nonisolated enum ScalePolicy: Sendable, Equatable {
    case original
    case maximum(ResolutionLimit)
}

nonisolated struct ResolutionLimit: Sendable, Equatable {
    let maximumLongEdge: Int
    let maximumShortEdge: Int

    init(maximumLongEdge: Int, maximumShortEdge: Int) throws {
        guard maximumLongEdge > 0,
              maximumShortEdge > 0,
              maximumLongEdge >= maximumShortEdge else {
            throw CompressionRecipeValidationError.invalidResolutionLimit
        }
        self.maximumLongEdge = maximumLongEdge
        self.maximumShortEdge = maximumShortEdge
    }
}

nonisolated enum FrameRatePolicy: Sendable, Equatable {
    case original
    case capped(FrameRateLimit)
}

nonisolated struct FrameRateLimit: Sendable, Equatable {
    let framesPerSecond: Double

    init(framesPerSecond: Double) throws {
        guard framesPerSecond.isFinite,
              framesPerSecond > 0,
              framesPerSecond <= 60 else {
            throw CompressionRecipeValidationError.invalidFrameRateLimit
        }
        self.framesPerSecond = framesPerSecond
    }
}

nonisolated enum AudioPolicy: Sendable, Equatable {
    case aac(AudioBitRate)
    case remove
}

nonisolated struct AudioBitRate: Sendable, Equatable {
    let bitsPerSecond: Int

    init(bitsPerSecond: Int) throws {
        guard bitsPerSecond > 0 else {
            throw CompressionRecipeValidationError.invalidAudioBitRate
        }
        self.bitsPerSecond = bitsPerSecond
    }
}

nonisolated enum MetadataPolicy: Sendable, Equatable {
    case preserveCommon
    case remove
}

nonisolated enum CompressionRecipeValidationError: Error, Sendable, Equatable {
    case invalidVideoQuality
    case invalidResolutionLimit
    case invalidFrameRateLimit
    case invalidAudioBitRate
}

nonisolated struct AutomaticCompressionPolicy: Sendable {
    func recipe(
        for mediaInfo: MediaInfo,
        mode: CompressionMode = .automatic
    ) throws -> CompressionRecipe {
        let audioPolicy: AudioPolicy
        if mediaInfo.audioStreams.isEmpty {
            audioPolicy = .remove
        } else {
            let bitsPerSecond = switch mode {
            case .automatic: 128_000
            case .compactRetry: 96_000
            }
            audioPolicy = .aac(
                try AudioBitRate(bitsPerSecond: bitsPerSecond)
            )
        }

        let values = switch mode {
        case .automatic:
            (
                quality: 0.65,
                maximumLongEdge: 1_920,
                maximumShortEdge: 1_080,
                framesPerSecond: 30.0
            )
        case .compactRetry:
            (
                quality: 0.45,
                maximumLongEdge: 1_280,
                maximumShortEdge: 720,
                framesPerSecond: 24.0
            )
        }

        return CompressionRecipe(
            origin: .mode(mode),
            container: .mp4,
            videoCodec: .h264VideoToolbox,
            rateControl: .quality(try VideoQuality(values.quality)),
            scalePolicy: .maximum(
                try ResolutionLimit(
                    maximumLongEdge: values.maximumLongEdge,
                    maximumShortEdge: values.maximumShortEdge
                )
            ),
            frameRatePolicy: .capped(
                try FrameRateLimit(
                    framesPerSecond: values.framesPerSecond
                )
            ),
            audioPolicy: audioPolicy,
            metadataPolicy: .preserveCommon
        )
    }
}

nonisolated struct OutputPolicy: Sendable, Equatable {
    let directoryURL: URL
    let filenameSuffix: String
    let conflictPolicy: OutputConflictPolicy

    init(
        directoryURL: URL,
        filenameSuffix: String = "-compressed",
        conflictPolicy: OutputConflictPolicy = .appendNumericSuffix
    ) throws {
        let trimmedSuffix = filenameSuffix.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard directoryURL.isFileURL,
              !trimmedSuffix.isEmpty,
              !trimmedSuffix.contains("/"),
              !trimmedSuffix.contains(":") else {
            throw OutputPolicyValidationError.invalidPolicy
        }

        self.directoryURL = directoryURL
        self.filenameSuffix = trimmedSuffix
        self.conflictPolicy = conflictPolicy
    }
}

nonisolated enum OutputConflictPolicy: Sendable, Equatable {
    case appendNumericSuffix
    case fail
}

nonisolated enum OutputPolicyValidationError: Error, Sendable, Equatable {
    case invalidPolicy
}

nonisolated struct JobConfiguration: Sendable, Equatable {
    let recipe: CompressionRecipe
    let outputPolicy: OutputPolicy
}
