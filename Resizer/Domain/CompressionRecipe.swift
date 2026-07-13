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
    case preset(CompressionPreset)
    case custom
}

nonisolated enum CompressionPreset: String, CaseIterable, Sendable, Equatable {
    case highQuality
    case balanced
    case smallFile

    static let `default`: CompressionPreset = .balanced
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
