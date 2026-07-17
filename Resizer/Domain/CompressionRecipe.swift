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
    case primary(PrimaryCompressionSettings)
}

nonisolated enum CompressionControlMode: Sendable, Equatable, CaseIterable {
    case quick
    case flexible
}

nonisolated enum AudioPreference: Sendable, Equatable {
    case keep
    case remove
}

nonisolated enum FlexibleResolution: Sendable, Equatable, CaseIterable {
    case source
    case p1080
    case p720
    case p480
}

nonisolated enum FlexibleFrameRate: Sendable, Equatable, CaseIterable {
    case source
    case fps60
    case fps30
    case fps24
}

nonisolated struct FlexibleCompressionSettings: Sendable, Equatable {
    static let minimumQuality = 0.30
    static let maximumQuality = 0.90

    let quality: VideoQuality
    let resolution: FlexibleResolution
    let frameRate: FlexibleFrameRate
    let audioPreference: AudioPreference

    init(
        quality: VideoQuality,
        resolution: FlexibleResolution,
        frameRate: FlexibleFrameRate,
        audioPreference: AudioPreference
    ) throws {
        guard (Self.minimumQuality ... Self.maximumQuality).contains(
            quality.value
        ) else {
            throw CompressionRecipeValidationError.invalidFlexibleVideoQuality
        }

        self.quality = quality
        self.resolution = resolution
        self.frameRate = frameRate
        self.audioPreference = audioPreference
    }
}

nonisolated enum PrimaryCompressionSettings: Sendable, Equatable {
    case quick(audio: AudioPreference)
    case flexible(FlexibleCompressionSettings)

    var controlMode: CompressionControlMode {
        switch self {
        case .quick:
            .quick
        case .flexible:
            .flexible
        }
    }

    var audioPreference: AudioPreference {
        switch self {
        case .quick(let audio):
            audio
        case .flexible(let settings):
            settings.audioPreference
        }
    }
}

nonisolated enum OutputContainer: Sendable, Equatable {
    case mp4
}

nonisolated enum VideoCodec: Sendable, Equatable {
    case h264Libx264
    case hevcMain10VideoToolbox
}

nonisolated enum RateControl: Sendable, Equatable {
    case libx264CRF(X264ConstantRateFactor)
    case videoToolboxQuality(VideoQuality)
}

nonisolated struct X264ConstantRateFactor: Sendable, Equatable {
    static let minimum = 0
    static let maximum = 51

    let value: Int

    init(_ value: Int) throws {
        guard (Self.minimum ... Self.maximum).contains(value) else {
            throw CompressionRecipeValidationError.invalidX264ConstantRateFactor
        }
        self.value = value
    }
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
    case invalidX264ConstantRateFactor
    case invalidFlexibleVideoQuality
    case invalidResolutionLimit
    case invalidFrameRateLimit
    case invalidAudioBitRate
}

nonisolated struct AutomaticCompressionPolicy: Sendable {
    private static let monoAACBitsPerSecond = 69_000
    private static let defaultAACBitsPerSecond = 128_000

    func recipe(
        for mediaInfo: MediaInfo
    ) throws -> CompressionRecipe {
        try recipe(
            for: mediaInfo,
            settings: .quick(audio: .keep)
        )
    }

    func recipe(
        for mediaInfo: MediaInfo,
        settings: PrimaryCompressionSettings
    ) throws -> CompressionRecipe {
        switch settings {
        case .quick(let audio):
            let videoCodec = videoCodec(for: mediaInfo)
            return try makeRecipe(
                for: mediaInfo,
                origin: .primary(settings),
                videoCodec: videoCodec,
                rateControl: videoCodec == .hevcMain10VideoToolbox
                    ? .videoToolboxQuality(try VideoQuality(0.70))
                    : .libx264CRF(try X264ConstantRateFactor(24)),
                scalePolicy: .maximum(
                    try ResolutionLimit(
                        maximumLongEdge: 1_920,
                        maximumShortEdge: 1_080
                    )
                ),
                frameRatePolicy: .capped(
                    try FrameRateLimit(framesPerSecond: 30)
                ),
                audioPreference: audio
            )
        case .flexible(let flexible):
            let videoCodec = videoCodec(for: mediaInfo)
            return try makeRecipe(
                for: mediaInfo,
                origin: .primary(settings),
                videoCodec: videoCodec,
                rateControl: try rateControl(
                    for: videoCodec,
                    flexibleQuality: flexible.quality
                ),
                scalePolicy: try scalePolicy(for: flexible.resolution),
                frameRatePolicy: try frameRatePolicy(for: flexible.frameRate),
                audioPreference: flexible.audioPreference
            )
        }
    }

    private func makeRecipe(
        for mediaInfo: MediaInfo,
        origin: RecipeOrigin,
        videoCodec: VideoCodec,
        rateControl: RateControl,
        scalePolicy: ScalePolicy,
        frameRatePolicy: FrameRatePolicy,
        audioPreference: AudioPreference
    ) throws -> CompressionRecipe {
        let audioPolicy: AudioPolicy
        if audioPreference == .remove {
            audioPolicy = .remove
        } else if let audio = mediaInfo.preferredAudioStream {
            let bitsPerSecond = audio.channelCount == 1
                ? Self.monoAACBitsPerSecond
                : Self.defaultAACBitsPerSecond
            audioPolicy = .aac(
                try AudioBitRate(bitsPerSecond: bitsPerSecond)
            )
        } else {
            audioPolicy = .remove
        }

        return CompressionRecipe(
            origin: origin,
            container: .mp4,
            videoCodec: videoCodec,
            rateControl: rateControl,
            scalePolicy: scalePolicy,
            frameRatePolicy: frameRatePolicy,
            audioPolicy: audioPolicy,
            metadataPolicy: .preserveCommon
        )
    }

    /// A confirmed SDR source above eight bits keeps its tonal precision in a
    /// Main10 output. Unknown-range and ordinary eight-bit inputs stay on the
    /// broadly compatible H.264 path; HDR remains rejected by infrastructure.
    private func videoCodec(for mediaInfo: MediaInfo) -> VideoCodec {
        let candidates = mediaInfo.videoStreams.filter {
            !$0.disposition.isAttachedPicture
        }
        guard let video = candidates
            .filter(\.disposition.isDefault)
            .min(by: { $0.index < $1.index })
                ?? candidates.min(by: { $0.index < $1.index }),
              video.dynamicRange == .sdr,
              let bitDepth = video.bitDepth,
              bitDepth > 8 else {
            return .h264Libx264
        }
        return .hevcMain10VideoToolbox
    }

    /// Flexible quality follows CompressO's bounded CRF curve: the exposed
    /// 30...90% range maps to CRF 33...26, while Quick uses the preset's
    /// highest-quality CRF 24 directly.
    private func rateControl(
        for codec: VideoCodec,
        flexibleQuality quality: VideoQuality
    ) throws -> RateControl {
        switch codec {
        case .h264Libx264:
            let percentage = Int((quality.value * 100).rounded())
            let crf = 36 - ((12 * percentage) / 100)
            return .libx264CRF(try X264ConstantRateFactor(crf))
        case .hevcMain10VideoToolbox:
            return .videoToolboxQuality(quality)
        }
    }

    private func scalePolicy(
        for resolution: FlexibleResolution
    ) throws -> ScalePolicy {
        switch resolution {
        case .source:
            .original
        case .p1080:
            .maximum(
                try ResolutionLimit(
                    maximumLongEdge: 1_920,
                    maximumShortEdge: 1_080
                )
            )
        case .p720:
            .maximum(
                try ResolutionLimit(
                    maximumLongEdge: 1_280,
                    maximumShortEdge: 720
                )
            )
        case .p480:
            .maximum(
                try ResolutionLimit(
                    maximumLongEdge: 854,
                    maximumShortEdge: 480
                )
            )
        }
    }

    private func frameRatePolicy(
        for frameRate: FlexibleFrameRate
    ) throws -> FrameRatePolicy {
        switch frameRate {
        case .source:
            .original
        case .fps60:
            .capped(try FrameRateLimit(framesPerSecond: 60))
        case .fps30:
            .capped(try FrameRateLimit(framesPerSecond: 30))
        case .fps24:
            .capped(try FrameRateLimit(framesPerSecond: 24))
        }
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
