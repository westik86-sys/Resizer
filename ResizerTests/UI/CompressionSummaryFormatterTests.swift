import Testing
@testable import Resizer

@Suite("Compression summary formatter")
struct CompressionSummaryFormatterTests {
    @Test("Video summary exposes preserved ten-bit chroma")
    func videoCodecSummary() {
        let cases: [(OutputPixelFormat, String)] = [
            (.yuv420p, "H.264"),
            (.yuv420p10le, "H.264 10-bit 4:2:0"),
            (.yuv422p10le, "H.264 10-bit 4:2:2"),
            (.yuv444p10le, "H.264 10-bit 4:4:4"),
        ]

        for (pixelFormat, expected) in cases {
            #expect(
                CompressionSummaryFormatter.videoCodecSummary(
                    outputPixelFormat: pixelFormat
                ) == expected
            )
        }
    }

    @Test("A source below the FPS cap is described as unchanged")
    func sourceBelowCap() throws {
        let summary = CompressionSummaryFormatter.frameRateSummary(
            policy: .capped(try FrameRateLimit(framesPerSecond: 30)),
            sourceFramesPerSecond: 24
        )

        #expect(summary == .source(24))
        #expect(
            CompressionSummaryFormatter.frameRateSummary(
                policy: .capped(try FrameRateLimit(framesPerSecond: 30)),
                sourceFramesPerSecond: 30
            ) == .source(30)
        )
    }

    @Test("A source above the FPS cap is described by the maximum")
    func sourceAboveCap() throws {
        let summary = CompressionSummaryFormatter.frameRateSummary(
            policy: .capped(try FrameRateLimit(framesPerSecond: 30)),
            sourceFramesPerSecond: 60
        )

        #expect(summary == .maximum(30))
    }

    @Test("Original FPS displays the known source value")
    func originalKnownSource() {
        let summary = CompressionSummaryFormatter.frameRateSummary(
            policy: .original,
            sourceFramesPerSecond: 23.976
        )

        #expect(summary == .source(23.976))
    }

    @Test("Unknown or invalid FPS keeps policy-level wording")
    func unknownSource() throws {
        let capped = try FrameRateLimit(framesPerSecond: 30)

        #expect(
            CompressionSummaryFormatter.frameRateSummary(
                policy: .capped(capped),
                sourceFramesPerSecond: nil
            ) == .maximum(30)
        )
        #expect(
            CompressionSummaryFormatter.frameRateSummary(
                policy: .original,
                sourceFramesPerSecond: .nan
            ) == .originalUnknown
        )
    }
}
