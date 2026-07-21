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
        #expect(
            recipe.rateControl
                == .libx264CRF(try X264ConstantRateFactor(22))
        )
        #expect(recipe.outputPixelFormat == .yuv420p)
        #expect(recipe.scalePolicy == .original)
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

    @Test("Quick preserves confirmed ten-bit 4:4:4 SDR through libx264")
    func quickTenBit444Mode() throws {
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
            origin: .primary(settings)
        )
        #expect(
            recipe.rateControl
                == .libx264CRF(try X264ConstantRateFactor(22))
        )
        #expect(recipe.outputPixelFormat == .yuv444p10le)
    }

    @Test("Pixel-format derivation is independent of the later SDR gate")
    func unknownRangeTenBitStillDerivesTenBitFormat() throws {
        let mediaInfo = try TestFixtures.mediaInfo(
            pixelFormat: "yuv420p10le",
            bitDepth: 10,
            dynamicRange: .unknown
        )

        let recipe = try AutomaticCompressionPolicy().recipe(for: mediaInfo)

        #expect(recipe.videoCodec == .h264Libx264)
        #expect(recipe.outputPixelFormat == .yuv420p10le)
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

    @Test("Quick and Flexible match CompressO's mono AAC default")
    func monoAudioBitRate() throws {
        let mediaInfo = try mediaInfo(
            audioStreams: [try audioStream(index: 1, channelCount: 1)]
        )
        let settings: [PrimaryCompressionSettings] = [
            .quick(audio: .keep),
            .flexible(
                try FlexibleCompressionSettings(
                    quality: VideoQuality(0.75),
                    resolution: .source,
                    frameRate: .source,
                    audioPreference: .keep
                )
            ),
        ]

        for setting in settings {
            let recipe = try AutomaticCompressionPolicy().recipe(
                for: mediaInfo,
                settings: setting
            )

            #expect(
                recipe.audioPolicy == .aac(
                    try AudioBitRate(bitsPerSecond: 69_000)
                )
            )
        }
    }

    @Test("Non-mono and unknown channel counts retain the quality-safe rate")
    func nonMonoAudioBitRate() throws {
        let channelCounts: [Int?] = [2, 6, nil]

        for channelCount in channelCounts {
            let mediaInfo = try mediaInfo(
                audioStreams: [
                    try audioStream(
                        index: 1,
                        channelCount: channelCount,
                        channelLayout: channelCount == nil ? "mono" : nil
                    ),
                ]
            )
            let recipe = try AutomaticCompressionPolicy().recipe(
                for: mediaInfo,
                settings: .quick(audio: .keep)
            )

            #expect(
                recipe.audioPolicy == .aac(
                    try AudioBitRate(bitsPerSecond: 128_000)
                )
            )
        }
    }

    @Test("Audio rate follows the same preferred stream used by FFmpeg")
    func preferredAudioStreamControlsBitRate() throws {
        let mediaInfo = try mediaInfo(
            audioStreams: [
                try audioStream(index: 1, channelCount: 2),
                try audioStream(
                    index: 9,
                    channelCount: 1,
                    isDefault: true
                ),
            ]
        )

        let recipe = try AutomaticCompressionPolicy().recipe(for: mediaInfo)

        #expect(mediaInfo.preferredAudioStream?.index == 9)
        #expect(
            recipe.audioPolicy == .aac(
                try AudioBitRate(bitsPerSecond: 69_000)
            )
        )
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
                #expect(
                    recipe.rateControl
                        == .libx264CRF(try X264ConstantRateFactor(27))
                )
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

    @Test("Flexible H.264 quality follows the bounded CompressO CRF curve")
    func flexibleX264QualityMapping() throws {
        for (quality, expectedCRF) in [(0.30, 33), (0.75, 27), (0.90, 26)] {
            let settings = PrimaryCompressionSettings.flexible(
                try FlexibleCompressionSettings(
                    quality: VideoQuality(quality),
                    resolution: .source,
                    frameRate: .source,
                    audioPreference: .remove
                )
            )
            let recipe = try AutomaticCompressionPolicy().recipe(
                for: TestFixtures.mediaInfo(),
                settings: settings
            )

            #expect(
                recipe.rateControl
                    == .libx264CRF(
                        try X264ConstantRateFactor(expectedCRF)
                    )
            )
        }
    }

    @Test("Flexible keeps ten-bit depth while using its bounded x264 CRF")
    func flexibleTenBitMode() throws {
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

        #expect(recipe.videoCodec == .h264Libx264)
        #expect(recipe.outputPixelFormat == .yuv420p10le)
        #expect(
            recipe.rateControl
                == .libx264CRF(try X264ConstantRateFactor(26))
        )
        #expect(recipe.audioPolicy == .remove)
    }

    @Test("Ten-bit source chroma maps to the matching typed x264 output")
    func tenBitChromaMapping() throws {
        let cases: [(String, OutputPixelFormat)] = [
            ("yuv420p10le", .yuv420p10le),
            ("p010le", .yuv420p10le),
            ("yuv422p10le", .yuv422p10le),
            ("p210le", .yuv422p10le),
            ("yuv444p10le", .yuv444p10le),
            ("p410le", .yuv444p10le),
        ]

        for (sourcePixelFormat, expectedOutput) in cases {
            let mediaInfo = try TestFixtures.mediaInfo(
                pixelFormat: sourcePixelFormat,
                bitDepth: 10,
                dynamicRange: .sdr
            )

            let recipe = try AutomaticCompressionPolicy().recipe(
                for: mediaInfo
            )

            #expect(recipe.videoCodec == .h264Libx264)
            #expect(recipe.outputPixelFormat == expectedOutput)
        }
    }

    @Test("Sources deeper than ten bits retain chroma and target ten bits")
    func higherDepthChromaMapping() throws {
        let cases: [(String, Int, OutputPixelFormat)] = [
            ("yuv420p12le", 12, .yuv420p10le),
            ("p012le", 12, .yuv420p10le),
            ("yuv422p12le", 12, .yuv422p10le),
            ("p212le", 12, .yuv422p10le),
            ("yuv444p16le", 16, .yuv444p10le),
            ("p416le", 16, .yuv444p10le),
        ]

        for (pixelFormat, bitDepth, expectedOutput) in cases {
            let mediaInfo = try TestFixtures.mediaInfo(
                pixelFormat: pixelFormat,
                bitDepth: bitDepth,
                dynamicRange: .sdr
            )

            #expect(
                try AutomaticCompressionPolicy().recipe(for: mediaInfo)
                    .outputPixelFormat == expectedOutput
            )
        }
    }

    @Test("Unsupported high-depth chroma fails closed")
    func rejectsUnsupportedHighDepthChroma() throws {
        let mediaInfo = try TestFixtures.mediaInfo(
            pixelFormat: "gbrp10le",
            bitDepth: 10,
            dynamicRange: .sdr
        )

        #expect(
            throws: CompressionRecipeValidationError
                .unsupportedSourcePixelFormat(
                    pixelFormat: "gbrp10le",
                    bitDepth: 10
                )
        ) {
            _ = try AutomaticCompressionPolicy().recipe(for: mediaInfo)
        }
    }

    @Test("Contradictory bit depth and pixel format fail closed")
    func rejectsContradictoryDepthMetadata() throws {
        let cases: [(String, Int)] = [
            ("yuv444p10le", 8),
            ("yuv444p12le", 10),
            ("yuv444p10le", 12),
        ]

        for (pixelFormat, bitDepth) in cases {
            let mediaInfo = try TestFixtures.mediaInfo(
                pixelFormat: pixelFormat,
                bitDepth: bitDepth,
                dynamicRange: .sdr
            )

            #expect(
                throws: CompressionRecipeValidationError
                    .unsupportedSourcePixelFormat(
                        pixelFormat: pixelFormat,
                        bitDepth: bitDepth
                    )
            ) {
                _ = try AutomaticCompressionPolicy().recipe(for: mediaInfo)
            }
        }
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
    }

    private func expectCommonContract(
        _ recipe: CompressionRecipe,
        origin: RecipeOrigin,
        videoCodec: VideoCodec = .h264Libx264
    ) {
        #expect(recipe.origin == origin)
        #expect(recipe.container == .mp4)
        #expect(recipe.videoCodec == videoCodec)
        #expect(recipe.metadataPolicy == .preserveCommon)
    }

    private func mediaInfo(
        audioStreams: [AudioStreamInfo]
    ) throws -> MediaInfo {
        let videoOnly = try TestFixtures.mediaInfo(includeAudio: false)
        return try MediaInfo(
            formatNames: videoOnly.formatNames,
            durationMicroseconds: videoOnly.durationMicroseconds,
            byteCount: videoOnly.byteCount,
            bitRate: videoOnly.bitRate,
            streams: videoOnly.streams + audioStreams.map(MediaStream.audio)
        )
    }

    private func audioStream(
        index: Int,
        channelCount: Int?,
        channelLayout: String? = nil,
        isDefault: Bool = false
    ) throws -> AudioStreamInfo {
        let resolvedLayout: String?
        if let channelLayout {
            resolvedLayout = channelLayout
        } else if channelCount == 1 {
            resolvedLayout = "mono"
        } else if channelCount == 2 {
            resolvedLayout = "stereo"
        } else {
            resolvedLayout = nil
        }

        return try AudioStreamInfo(
            index: index,
            codecName: "aac",
            sampleRate: 48_000,
            channelCount: channelCount,
            channelLayout: resolvedLayout,
            bitRate: 128_000,
            languageCode: nil,
            disposition: StreamDisposition(
                isDefault: isDefault,
                isForced: false,
                isAttachedPicture: false
            )
        )
    }
}
