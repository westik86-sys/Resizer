import Testing
@testable import Resizer

@Suite("Automatic compression policy")
struct AutomaticCompressionPolicyTests {
    @Test("Quick derives the balanced first-attempt recipe")
    func quickMode() throws {
        let settings = PrimaryCompressionSettings.quick(audio: .keep)
        let recipe = try AutomaticCompressionPolicy().recipe(
            for: TestFixtures.mediaInfo(),
            settings: settings
        )

        expectCommonContract(recipe, origin: .primary(settings))
        #expect(recipe.rateControl == .quality(try VideoQuality(0.75)))
        #expect(
            recipe.scalePolicy == .maximum(
                try ResolutionLimit(
                    maximumLongEdge: 1_920,
                    maximumShortEdge: 1_080
                )
            )
        )
        #expect(
            recipe.frameRatePolicy == .capped(
                try FrameRateLimit(framesPerSecond: 30)
            )
        )
        #expect(
            recipe.audioPolicy == .aac(
                try AudioBitRate(bitsPerSecond: 128_000)
            )
        )
    }

    @Test("Quick preserves confirmed ten-bit SDR through HEVC Main10")
    func quickMain10Mode() throws {
        let mediaInfo = try TestFixtures.mediaInfo(
            videoCodec: "h264",
            pixelFormat: "yuv444p10le",
            bitDepth: 10,
            dynamicRange: .sdr
        )
        let settings = PrimaryCompressionSettings.quick(audio: .keep)

        let recipe = try AutomaticCompressionPolicy().recipe(
            for: mediaInfo,
            settings: settings
        )

        expectCommonContract(
            recipe,
            origin: .primary(settings),
            videoCodec: .hevcMain10VideoToolbox
        )
        #expect(recipe.rateControl == .quality(try VideoQuality(0.80)))
    }

    @Test("Unknown-range ten-bit input does not enter the Main10 SDR path")
    func unknownRangeTenBitStaysOnCompatibilityPath() throws {
        let mediaInfo = try TestFixtures.mediaInfo(
            pixelFormat: "yuv420p10le",
            bitDepth: 10,
            dynamicRange: .unknown
        )

        let recipe = try AutomaticCompressionPolicy().recipe(for: mediaInfo)

        #expect(recipe.videoCodec == .h264VideoToolbox)
    }

    @Test("Quick can remove audio from an input that contains it")
    func quickAudioRemoval() throws {
        let settings = PrimaryCompressionSettings.quick(audio: .remove)

        let recipe = try AutomaticCompressionPolicy().recipe(
            for: TestFixtures.mediaInfo(),
            settings: settings
        )

        #expect(recipe.origin == .primary(settings))
        #expect(recipe.audioPolicy == .remove)
    }

    @Test("Flexible maps every bounded resolution and frame-rate option")
    func flexibleOptions() throws {
        let resolutions: [(FlexibleResolution, ScalePolicy)] = [
            (FlexibleResolution.source, ScalePolicy.original),
            (
                FlexibleResolution.p1080,
                ScalePolicy.maximum(
                    try ResolutionLimit(
                        maximumLongEdge: 1_920,
                        maximumShortEdge: 1_080
                    )
                )
            ),
            (
                FlexibleResolution.p720,
                ScalePolicy.maximum(
                    try ResolutionLimit(
                        maximumLongEdge: 1_280,
                        maximumShortEdge: 720
                    )
                )
            ),
            (
                FlexibleResolution.p480,
                ScalePolicy.maximum(
                    try ResolutionLimit(
                        maximumLongEdge: 854,
                        maximumShortEdge: 480
                    )
                )
            ),
        ]
        let frameRates: [(FlexibleFrameRate, FrameRatePolicy)] = [
            (FlexibleFrameRate.source, FrameRatePolicy.original),
            (
                FlexibleFrameRate.fps60,
                FrameRatePolicy.capped(
                    try FrameRateLimit(framesPerSecond: 60)
                )
            ),
            (
                FlexibleFrameRate.fps30,
                FrameRatePolicy.capped(
                    try FrameRateLimit(framesPerSecond: 30)
                )
            ),
            (
                FlexibleFrameRate.fps24,
                FrameRatePolicy.capped(
                    try FrameRateLimit(framesPerSecond: 24)
                )
            ),
        ]

        for resolution in resolutions {
            for frameRate in frameRates {
                let flexible = try FlexibleCompressionSettings(
                    quality: VideoQuality(0.75),
                    resolution: resolution.0,
                    frameRate: frameRate.0,
                    audioPreference: .keep
                )
                let settings = PrimaryCompressionSettings.flexible(flexible)

                let recipe = try AutomaticCompressionPolicy().recipe(
                    for: TestFixtures.mediaInfo(),
                    settings: settings
                )

                expectCommonContract(recipe, origin: .primary(settings))
                #expect(recipe.rateControl == .quality(try VideoQuality(0.75)))
                #expect(recipe.scalePolicy == resolution.1)
                #expect(recipe.frameRatePolicy == frameRate.1)
                #expect(
                    recipe.audioPolicy == .aac(
                        try AudioBitRate(bitsPerSecond: 128_000)
                    )
                )
            }
        }
    }

    @Test("Flexible rejects quality outside its product bounds")
    func flexibleQualityBounds() throws {
        for quality in [0.29, 0.91] {
            #expect(
                throws: CompressionRecipeValidationError
                    .invalidFlexibleVideoQuality
            ) {
                _ = try FlexibleCompressionSettings(
                    quality: VideoQuality(quality),
                    resolution: .source,
                    frameRate: .source,
                    audioPreference: .keep
                )
            }
        }

        for quality in [0.30, 0.90] {
            let settings = try FlexibleCompressionSettings(
                quality: VideoQuality(quality),
                resolution: .source,
                frameRate: .source,
                audioPreference: .remove
            )
            #expect(settings.quality == (try VideoQuality(quality)))
        }
    }

    @Test("Flexible keeps its selected quality on the Main10 path")
    func flexibleMain10Mode() throws {
        let mediaInfo = try TestFixtures.mediaInfo(
            videoCodec: "hevc",
            pixelFormat: "yuv420p10le",
            bitDepth: 10,
            dynamicRange: .sdr
        )
        let settings = PrimaryCompressionSettings.flexible(
            try FlexibleCompressionSettings(
                quality: VideoQuality(0.85),
                resolution: .source,
                frameRate: .source,
                audioPreference: .remove
            )
        )

        let recipe = try AutomaticCompressionPolicy().recipe(
            for: mediaInfo,
            settings: settings
        )

        #expect(recipe.videoCodec == .hevcMain10VideoToolbox)
        #expect(recipe.rateControl == .quality(try VideoQuality(0.85)))
        #expect(recipe.audioPolicy == .remove)
    }

    @Test("Compact retry derives the fixed secondary recipe")
    func compactRetryMode() throws {
        let recipe = try AutomaticCompressionPolicy().compactRecipe(
            for: TestFixtures.mediaInfo(),
            audio: .keep
        )

        expectCommonContract(recipe, origin: .compactRetry(audio: .keep))
        #expect(recipe.rateControl == .quality(try VideoQuality(0.45)))
        #expect(
            recipe.scalePolicy == .maximum(
                try ResolutionLimit(
                    maximumLongEdge: 1_280,
                    maximumShortEdge: 720
                )
            )
        )
        #expect(
            recipe.frameRatePolicy == .capped(
                try FrameRateLimit(framesPerSecond: 24)
            )
        )
        #expect(
            recipe.audioPolicy == .aac(
                try AudioBitRate(bitsPerSecond: 96_000)
            )
        )
    }

    @Test("Compact retry keeps confirmed ten-bit SDR as Main10")
    func compactRetryMain10Mode() throws {
        let mediaInfo = try TestFixtures.mediaInfo(
            videoCodec: "hevc",
            pixelFormat: "yuv420p10le",
            bitDepth: 10,
            dynamicRange: .sdr
        )

        let recipe = try AutomaticCompressionPolicy().compactRecipe(
            for: mediaInfo,
            audio: .keep
        )

        #expect(recipe.videoCodec == .hevcMain10VideoToolbox)
        #expect(recipe.rateControl == .quality(try VideoQuality(0.60)))
    }

    @Test("Compact retry inherits the Quick remove-audio choice")
    func compactRetryAudioRemoval() throws {
        let recipe = try AutomaticCompressionPolicy().compactRecipe(
            for: TestFixtures.mediaInfo(),
            audio: .remove
        )

        #expect(recipe.origin == .compactRetry(audio: .remove))
        #expect(recipe.audioPolicy == .remove)
    }

    @Test("Every recipe removes audio when the source has no audio stream")
    func sourceWithoutAudio() throws {
        let mediaInfo = try TestFixtures.mediaInfo(includeAudio: false)
        let policy = AutomaticCompressionPolicy()

        #expect(
            try policy.recipe(
                for: mediaInfo,
                settings: .quick(audio: .keep)
            ).audioPolicy
                == .remove
        )
        #expect(
            try policy.compactRecipe(
                for: mediaInfo,
                audio: .keep
            ).audioPolicy
                == .remove
        )
    }

    @Test("Omitted mode uses the automatic contract")
    func defaultMode() throws {
        let mediaInfo = try TestFixtures.mediaInfo()
        let policy = AutomaticCompressionPolicy()

        #expect(
            try policy.recipe(for: mediaInfo)
                == policy.recipe(for: mediaInfo, mode: .automatic)
        )
    }

    private func expectCommonContract(
        _ recipe: CompressionRecipe,
        origin: RecipeOrigin,
        videoCodec: VideoCodec = .h264VideoToolbox
    ) {
        #expect(recipe.origin == origin)
        #expect(recipe.container == .mp4)
        #expect(recipe.videoCodec == videoCodec)
        #expect(recipe.metadataPolicy == .preserveCommon)
    }
}
