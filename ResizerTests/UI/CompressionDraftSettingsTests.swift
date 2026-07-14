import Testing
@testable import Resizer

@Suite("Compression draft settings")
struct CompressionDraftSettingsTests {
    @Test(
        "Every preset produces its exact domain recipe",
        arguments: CompressionPreset.allCases
    )
    func presetRecipe(preset: CompressionPreset) throws {
        let settings = CompressionDraftSettings(preset: preset)

        #expect(settings.selectedPreset == preset)
        #expect(settings.origin == .preset(preset))
        #expect(
            try settings.makeRecipe()
                == CompressionRecipe(preset: preset)
        )
    }

    @Test(
        "Applying a preset restores the complete preset recipe",
        arguments: CompressionPreset.allCases
    )
    func applyPreset(preset: CompressionPreset) throws {
        var settings = CompressionDraftSettings(preset: .balanced)
        try settings.setQuality(0.12)
        settings.setResolution(.original)
        settings.setFrameRate(.original)
        settings.setAudio(.remove)
        settings.setMetadata(.remove)

        settings.apply(preset: preset)

        #expect(settings.origin == .preset(preset))
        #expect(
            try settings.makeRecipe()
                == CompressionRecipe(preset: preset)
        )
    }

    @Test("Manual quality is bounded, typed, and marks the recipe custom")
    func manualQuality() throws {
        var settings = CompressionDraftSettings()

        try settings.setQuality(0.73)

        #expect(settings.selectedPreset == nil)
        #expect(settings.origin == .custom)
        #expect(
            try settings.makeRecipe().rateControl
                == .quality(VideoQuality(0.73))
        )
    }

    @Test(
        "Every bounded resolution maps to a typed scale policy",
        arguments: CompressionDraftSettings.ResolutionOption.allCases
    )
    func manualResolution(
        option: CompressionDraftSettings.ResolutionOption
    ) throws {
        var settings = CompressionDraftSettings()

        settings.setResolution(option)

        #expect(settings.origin == .custom)
        #expect(try settings.makeRecipe().scalePolicy == expected(option))
    }

    @Test(
        "Every bounded frame rate maps to a typed frame-rate policy",
        arguments: CompressionDraftSettings.FrameRateOption.allCases
    )
    func manualFrameRate(
        option: CompressionDraftSettings.FrameRateOption
    ) throws {
        var settings = CompressionDraftSettings()

        settings.setFrameRate(option)

        #expect(settings.origin == .custom)
        #expect(
            try settings.makeRecipe().frameRatePolicy == expected(option)
        )
    }

    @Test(
        "Every bounded audio option maps to a typed audio policy",
        arguments: CompressionDraftSettings.AudioOption.allCases
    )
    func manualAudio(
        option: CompressionDraftSettings.AudioOption
    ) throws {
        var settings = CompressionDraftSettings()

        settings.setAudio(option)

        #expect(settings.origin == .custom)
        #expect(try settings.makeRecipe().audioPolicy == expected(option))
    }

    @Test(
        "Every bounded metadata option maps to a typed metadata policy",
        arguments: CompressionDraftSettings.MetadataOption.allCases
    )
    func manualMetadata(
        option: CompressionDraftSettings.MetadataOption
    ) throws {
        var settings = CompressionDraftSettings()

        settings.setMetadata(option)

        #expect(settings.origin == .custom)
        #expect(
            try settings.makeRecipe().metadataPolicy == expected(option)
        )
    }

    @Test(
        "Invalid quality is rejected without clamping or mutating the draft",
        arguments: [-0.01, 1.01, .infinity, -.infinity, .nan]
    )
    func invalidQuality(value: Double) throws {
        var settings = CompressionDraftSettings(preset: .balanced)
        let original = settings

        #expect(throws: CompressionRecipeValidationError.invalidVideoQuality) {
            try settings.setQuality(value)
        }
        #expect(settings == original)
        #expect(settings.origin == .preset(.balanced))
    }

    @Test("Quality endpoints are accepted without clamping", arguments: [0, 1])
    func qualityEndpoints(value: Double) throws {
        var settings = CompressionDraftSettings()

        try settings.setQuality(value)

        #expect(settings.quality == value)
        #expect(
            try settings.makeRecipe().rateControl
                == .quality(VideoQuality(value))
        )
        #expect(settings.origin == .custom)
    }

    private func expected(
        _ option: CompressionDraftSettings.ResolutionOption
    ) throws -> ScalePolicy {
        switch option {
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

    private func expected(
        _ option: CompressionDraftSettings.FrameRateOption
    ) throws -> FrameRatePolicy {
        switch option {
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

    private func expected(
        _ option: CompressionDraftSettings.AudioOption
    ) throws -> AudioPolicy {
        switch option {
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

    private func expected(
        _ option: CompressionDraftSettings.MetadataOption
    ) -> MetadataPolicy {
        switch option {
        case .preserve:
            .preserveCommon
        case .remove:
            .remove
        }
    }
}
