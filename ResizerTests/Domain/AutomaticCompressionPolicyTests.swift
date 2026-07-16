import Testing
@testable import Resizer

@Suite("Automatic compression policy")
struct AutomaticCompressionPolicyTests {
    @Test("Automatic mode derives the first-attempt recipe")
    func automaticMode() throws {
        let recipe = try AutomaticCompressionPolicy().recipe(
            for: TestFixtures.mediaInfo(),
            mode: .automatic
        )

        expectCommonContract(recipe, mode: .automatic)
        #expect(recipe.rateControl == .quality(try VideoQuality(0.65)))
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

    @Test("Compact retry derives the fixed secondary recipe")
    func compactRetryMode() throws {
        let recipe = try AutomaticCompressionPolicy().recipe(
            for: TestFixtures.mediaInfo(),
            mode: .compactRetry
        )

        expectCommonContract(recipe, mode: .compactRetry)
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

    @Test("Both modes remove audio when the source has no audio stream")
    func sourceWithoutAudio() throws {
        let mediaInfo = try TestFixtures.mediaInfo(includeAudio: false)
        let policy = AutomaticCompressionPolicy()

        #expect(
            try policy.recipe(for: mediaInfo, mode: .automatic).audioPolicy
                == .remove
        )
        #expect(
            try policy.recipe(for: mediaInfo, mode: .compactRetry).audioPolicy
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
        mode: CompressionMode
    ) {
        #expect(recipe.origin == .mode(mode))
        #expect(recipe.container == .mp4)
        #expect(recipe.videoCodec == .h264VideoToolbox)
        #expect(recipe.metadataPolicy == .preserveCommon)
    }
}
