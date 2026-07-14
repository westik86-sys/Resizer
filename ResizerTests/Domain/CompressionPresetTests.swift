import Testing
@testable import Resizer

@Suite("Compression preset recipes")
struct CompressionPresetTests {
    @Test("High Quality preserves original video characteristics")
    func highQuality() throws {
        let recipe = try CompressionRecipe(preset: .highQuality)

        expectCommonContract(recipe, preset: .highQuality)
        #expect(recipe.rateControl == .quality(try VideoQuality(0.85)))
        #expect(recipe.scalePolicy == .original)
        #expect(recipe.frameRatePolicy == .original)
        #expect(
            recipe.audioPolicy == .aac(
                try AudioBitRate(bitsPerSecond: 192_000)
            )
        )
    }

    @Test("Balanced is the default 1080p and 30 FPS recipe")
    func balanced() throws {
        let recipe = try CompressionRecipe(preset: .balanced)

        #expect(CompressionPreset.default == .balanced)
        expectCommonContract(recipe, preset: .balanced)
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
        #expect(
            try CompressionRecipe(preset: .default)
                == CompressionRecipe(preset: .balanced)
        )
    }

    @Test("Small File caps output at 720p and 24 FPS")
    func smallFile() throws {
        let recipe = try CompressionRecipe(preset: .smallFile)

        expectCommonContract(recipe, preset: .smallFile)
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

    @Test("Preset qualities are distinct and decrease with output size")
    func monotonicQualities() throws {
        let highQuality = quality(
            in: try CompressionRecipe(preset: .highQuality)
        )
        let balanced = quality(
            in: try CompressionRecipe(preset: .balanced)
        )
        let smallFile = quality(
            in: try CompressionRecipe(preset: .smallFile)
        )

        #expect(highQuality > balanced)
        #expect(balanced > smallFile)
        #expect(Set([highQuality, balanced, smallFile]).count == 3)
    }

    private func expectCommonContract(
        _ recipe: CompressionRecipe,
        preset: CompressionPreset
    ) {
        #expect(recipe.origin == .preset(preset))
        #expect(recipe.container == .mp4)
        #expect(recipe.videoCodec == .h264VideoToolbox)
        #expect(recipe.metadataPolicy == .preserveCommon)
    }

    private func quality(in recipe: CompressionRecipe) -> Double {
        switch recipe.rateControl {
        case .quality(let quality):
            quality.value
        }
    }
}
