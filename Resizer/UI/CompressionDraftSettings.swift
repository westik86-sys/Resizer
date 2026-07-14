import Foundation

/// A bounded, UI-facing draft that can only produce supported recipes.
///
/// Every manual setter deliberately clears the selected preset, even when the
/// selected value happens to equal that preset's value. Re-applying a preset
/// restores its complete recipe and its preset origin.
nonisolated struct CompressionDraftSettings: Sendable, Equatable {
    nonisolated enum ResolutionOption: CaseIterable, Sendable, Equatable {
        case original
        case p2160
        case p1080
        case p720
        case p480
    }

    nonisolated enum FrameRateOption: CaseIterable, Sendable, Equatable {
        case original
        case fps60
        case fps30
        case fps24
    }

    nonisolated enum AudioOption: CaseIterable, Sendable, Equatable {
        case aac192Kbps
        case aac128Kbps
        case aac96Kbps
        case remove
    }

    nonisolated enum MetadataOption: CaseIterable, Sendable, Equatable {
        case preserve
        case remove
    }

    private(set) var selectedPreset: CompressionPreset?
    private(set) var quality: Double
    private(set) var resolution: ResolutionOption
    private(set) var frameRate: FrameRateOption
    private(set) var audio: AudioOption
    private(set) var metadata: MetadataOption

    var origin: RecipeOrigin {
        selectedPreset.map(RecipeOrigin.preset) ?? .custom
    }

    init(preset: CompressionPreset = .default) {
        selectedPreset = nil
        quality = 0
        resolution = .original
        frameRate = .original
        audio = .remove
        metadata = .remove
        apply(preset: preset)
    }

    mutating func apply(preset: CompressionPreset) {
        switch preset {
        case .highQuality:
            quality = 0.85
            resolution = .original
            frameRate = .original
            audio = .aac192Kbps
            metadata = .preserve
        case .balanced:
            quality = 0.65
            resolution = .p1080
            frameRate = .fps30
            audio = .aac128Kbps
            metadata = .preserve
        case .smallFile:
            quality = 0.45
            resolution = .p720
            frameRate = .fps24
            audio = .aac96Kbps
            metadata = .preserve
        }

        selectedPreset = preset
    }

    mutating func setQuality(_ value: Double) throws {
        _ = try VideoQuality(value)
        quality = value
        selectedPreset = nil
    }

    mutating func setResolution(_ option: ResolutionOption) {
        resolution = option
        selectedPreset = nil
    }

    mutating func setFrameRate(_ option: FrameRateOption) {
        frameRate = option
        selectedPreset = nil
    }

    mutating func setAudio(_ option: AudioOption) {
        audio = option
        selectedPreset = nil
    }

    mutating func setMetadata(_ option: MetadataOption) {
        metadata = option
        selectedPreset = nil
    }

    func makeRecipe() throws -> CompressionRecipe {
        CompressionRecipe(
            origin: origin,
            container: .mp4,
            videoCodec: .h264VideoToolbox,
            rateControl: .quality(try VideoQuality(quality)),
            scalePolicy: try resolution.scalePolicy,
            frameRatePolicy: try frameRate.frameRatePolicy,
            audioPolicy: try audio.audioPolicy,
            metadataPolicy: metadata.metadataPolicy
        )
    }
}

private extension CompressionDraftSettings.ResolutionOption {
    nonisolated var scalePolicy: ScalePolicy {
        get throws {
            switch self {
            case .original:
                .original
            case .p2160:
                .maximum(
                    try ResolutionLimit(
                        maximumLongEdge: 3_840,
                        maximumShortEdge: 2_160
                    )
                )
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
    }
}

private extension CompressionDraftSettings.FrameRateOption {
    nonisolated var frameRatePolicy: FrameRatePolicy {
        get throws {
            switch self {
            case .original:
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
}

private extension CompressionDraftSettings.AudioOption {
    nonisolated var audioPolicy: AudioPolicy {
        get throws {
            switch self {
            case .aac192Kbps:
                .aac(try AudioBitRate(bitsPerSecond: 192_000))
            case .aac128Kbps:
                .aac(try AudioBitRate(bitsPerSecond: 128_000))
            case .aac96Kbps:
                .aac(try AudioBitRate(bitsPerSecond: 96_000))
            case .remove:
                .remove
            }
        }
    }
}

private extension CompressionDraftSettings.MetadataOption {
    nonisolated var metadataPolicy: MetadataPolicy {
        switch self {
        case .preserve:
            .preserveCommon
        case .remove:
            .remove
        }
    }
}
