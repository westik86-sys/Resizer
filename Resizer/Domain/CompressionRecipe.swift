import Foundation

nonisolated struct CompressionRecipe: Sendable, Equatable {
    let origin: RecipeOrigin
    let container: OutputContainer
    let videoCodec: VideoCodec
    let outputPixelFormat: OutputPixelFormat
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
}

nonisolated enum RateControl: Sendable, Equatable {
    case libx264CRF(X264ConstantRateFactor)
}

/// The closed set of pixel formats emitted by the audited bundled libx264
/// profile. Eight-bit sources deliberately use the broadly compatible 4:2:0
/// format. SDR sources above eight bits keep their chroma sampling and use the
/// verified ten-bit x264 path; sources above ten bits are dithered down rather
/// than silently falling back to an eight-bit encode.
nonisolated enum OutputPixelFormat: String, Sendable, Equatable, CaseIterable {
    case yuv420p
    case yuv420p10le
    case yuv422p10le
    case yuv444p10le

    var bitDepth: Int {
        switch self {
        case .yuv420p:
            8
        case .yuv420p10le, .yuv422p10le, .yuv444p10le:
            10
        }
    }

    var chromaSubsampling: String {
        switch self {
        case .yuv420p, .yuv420p10le:
            "4:2:0"
        case .yuv422p10le:
            "4:2:2"
        case .yuv444p10le:
            "4:4:4"
        }
    }

    static func preservingSource(
        _ video: VideoStreamInfo
    ) throws -> OutputPixelFormat {
        let normalized = video.pixelFormat?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let highDepthFormat = normalized.flatMap(highDepthOutputFormat)
        let pixelFormatBitDepth = inferredSourceBitDepth(
            from: normalized
        )

        if let metadataBitDepth = video.bitDepth,
           let pixelFormatBitDepth,
           metadataBitDepth != pixelFormatBitDepth {
            throw CompressionRecipeValidationError
                .unsupportedSourcePixelFormat(
                    pixelFormat: video.pixelFormat,
                    bitDepth: video.bitDepth
                )
        }
        let effectiveBitDepth = video.bitDepth ?? pixelFormatBitDepth

        if let effectiveBitDepth, effectiveBitDepth <= 8 {
            guard highDepthFormat == nil else {
                throw CompressionRecipeValidationError
                    .unsupportedSourcePixelFormat(
                        pixelFormat: video.pixelFormat,
                        bitDepth: video.bitDepth
                    )
            }
            return .yuv420p
        }

        if effectiveBitDepth.map({ $0 > 8 }) == true,
           let highDepthFormat {
            return highDepthFormat
        }

        throw CompressionRecipeValidationError.unsupportedSourcePixelFormat(
            pixelFormat: video.pixelFormat,
            bitDepth: video.bitDepth
        )
    }

    /// Returns the depth encoded by a supported pixel-format name. Keeping
    /// this independent from ffprobe's scalar fields lets policy validation
    /// reject contradictory metadata and lets the command builder dither a
    /// higher-depth source even when the scalar field was omitted.
    static func inferredSourceBitDepth(
        from pixelFormat: String?
    ) -> Int? {
        guard var normalized = pixelFormat?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased(),
              !normalized.isEmpty else {
            return nil
        }
        if normalized.hasSuffix("le") || normalized.hasSuffix("be") {
            normalized.removeLast(2)
        }
        if knownEightBitSourceFormats.contains(normalized) {
            return 8
        }
        for prefix in ["yuv420p", "yuv422p", "yuv444p"] {
            if let depth = planarDepth(in: normalized, prefix: prefix) {
                return depth
            }
        }
        for prefix in ["p0", "p2", "p4"] where normalized.hasPrefix(prefix) {
            let digits = normalized.dropFirst(prefix.count)
            guard !digits.isEmpty,
                  digits.allSatisfy(\.isNumber) else {
                return nil
            }
            return Int(digits)
        }
        return nil
    }

    private static let knownEightBitSourceFormats: Set<String> = [
        "gray", "gray8", "nv12", "uyvy422", "yuv420p", "yuv422p",
        "yuv444p", "yuvj420p", "yuvj422p", "yuvj444p", "yuyv422",
    ]

    private static func highDepthOutputFormat(
        _ pixelFormat: String
    ) -> OutputPixelFormat? {
        let inferredDepth = inferredSourceBitDepth(from: pixelFormat)
        if planarDepth(in: pixelFormat, prefix: "yuv420p")
                .map({ $0 > 8 }) == true
            || pixelFormat.hasPrefix("p01")
                && inferredDepth.map({ $0 > 8 }) == true {
            return .yuv420p10le
        }
        if planarDepth(in: pixelFormat, prefix: "yuv422p")
                .map({ $0 > 8 }) == true
            || pixelFormat.hasPrefix("p21")
                && inferredDepth.map({ $0 > 8 }) == true {
            return .yuv422p10le
        }
        if planarDepth(in: pixelFormat, prefix: "yuv444p")
                .map({ $0 > 8 }) == true
            || pixelFormat.hasPrefix("p41")
                && inferredDepth.map({ $0 > 8 }) == true {
            return .yuv444p10le
        }
        return nil
    }

    private static func planarDepth(
        in pixelFormat: String,
        prefix: String
    ) -> Int? {
        guard pixelFormat.hasPrefix(prefix) else { return nil }
        let suffix = pixelFormat.dropFirst(prefix.count)
        let digits = suffix.prefix(while: \.isNumber)
        let remainder = suffix.dropFirst(digits.count)
        guard !digits.isEmpty,
              remainder.isEmpty || remainder == "le" || remainder == "be"
        else {
            return nil
        }
        return Int(digits)
    }
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
    case unsupportedSourcePixelFormat(pixelFormat: String?, bitDepth: Int?)
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
            let outputPixelFormat = try outputPixelFormat(for: mediaInfo)
            return try makeRecipe(
                for: mediaInfo,
                origin: .primary(settings),
                outputPixelFormat: outputPixelFormat,
                rateControl: .libx264CRF(
                    try X264ConstantRateFactor(22)
                ),
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
            let outputPixelFormat = try outputPixelFormat(for: mediaInfo)
            return try makeRecipe(
                for: mediaInfo,
                origin: .primary(settings),
                outputPixelFormat: outputPixelFormat,
                rateControl: try rateControl(
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
        outputPixelFormat: OutputPixelFormat,
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
            videoCodec: .h264Libx264,
            outputPixelFormat: outputPixelFormat,
            rateControl: rateControl,
            scalePolicy: scalePolicy,
            frameRatePolicy: frameRatePolicy,
            audioPolicy: audioPolicy,
            metadataPolicy: .preserveCommon
        )
    }

    /// Select the same ordinary video stream used by the command builder and
    /// derive a fail-closed libx264 output format from its probed depth/chroma.
    private func outputPixelFormat(
        for mediaInfo: MediaInfo
    ) throws -> OutputPixelFormat {
        let candidates = mediaInfo.videoStreams.filter {
            !$0.disposition.isAttachedPicture
        }
        guard let video = candidates
            .filter(\.disposition.isDefault)
            .min(by: { $0.index < $1.index })
                ?? candidates.min(by: { $0.index < $1.index }) else {
            throw CompressionRecipeValidationError
                .unsupportedSourcePixelFormat(
                    pixelFormat: nil,
                    bitDepth: nil
                )
        }
        return try OutputPixelFormat.preservingSource(video)
    }

    /// Flexible quality follows CompressO's bounded CRF curve: the exposed
    /// 30...90% range maps to CRF 33...26, while Quick uses CRF 22 directly.
    private func rateControl(
        flexibleQuality quality: VideoQuality
    ) throws -> RateControl {
        let percentage = Int((quality.value * 100).rounded())
        let crf = 36 - ((12 * percentage) / 100)
        return .libx264CRF(try X264ConstantRateFactor(crf))
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
