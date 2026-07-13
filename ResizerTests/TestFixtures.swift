import Foundation
@testable import Resizer

nonisolated enum TestFixtures {
    static func mediaInfo() throws -> MediaInfo {
        try MediaInfo(
            formatNames: ["mov", "mp4"],
            durationMicroseconds: 10_000_000,
            byteCount: 4_096,
            bitRate: 2_000_000,
            streams: [
                .video(
                    try VideoStreamInfo(
                        index: 0,
                        codecName: "h264",
                        encodedWidth: 1_920,
                        encodedHeight: 1_080,
                        frameRate: try RationalFrameRate(
                            numerator: 30_000,
                            denominator: 1_001
                        ),
                        rotationDegrees: 0,
                        pixelFormat: "yuv420p",
                        bitDepth: 8,
                        dynamicRange: .sdr
                    )
                ),
                .audio(
                    try AudioStreamInfo(
                        index: 1,
                        codecName: "aac",
                        sampleRate: 48_000,
                        channelCount: 2,
                        channelLayout: "stereo",
                        bitRate: 128_000,
                        languageCode: nil
                    )
                ),
            ]
        )
    }

    static func configuration() throws -> JobConfiguration {
        let recipe = CompressionRecipe(
            origin: .preset(.balanced),
            container: .mp4,
            videoCodec: .h264VideoToolbox,
            rateControl: .quality(try VideoQuality(0.65)),
            scalePolicy: .maximum(
                try ResolutionLimit(
                    maximumLongEdge: 1_920,
                    maximumShortEdge: 1_080
                )
            ),
            frameRatePolicy: .capped(
                try FrameRateLimit(framesPerSecond: 30)
            ),
            audioPolicy: .aac(
                try AudioBitRate(bitsPerSecond: 128_000)
            ),
            metadataPolicy: .preserveCommon
        )
        let outputPolicy = try OutputPolicy(
            directoryURL: URL(fileURLWithPath: "/tmp/ResizerTests", isDirectory: true)
        )
        return JobConfiguration(recipe: recipe, outputPolicy: outputPolicy)
    }

    static func progress(
        processedMicroseconds: Int64 = 5_000_000,
        totalMicroseconds: Int64? = 10_000_000
    ) throws -> TranscodeProgress {
        try TranscodeProgress(
            processedMicroseconds: processedMicroseconds,
            totalMicroseconds: totalMicroseconds,
            frame: 150,
            framesPerSecond: 30,
            speed: 1.5,
            outputByteCount: 2_048,
            duplicatedFrames: 0,
            droppedFrames: 0
        )
    }

    static func result() throws -> CompressionResult {
        try CompressionResult(
            outputURL: URL(fileURLWithPath: "/tmp/ResizerTests/result.mp4"),
            outputByteCount: 2_048,
            elapsed: .seconds(4)
        )
    }

    static func failure(stage: FailureStage) -> TranscodeFailure {
        TranscodeFailure(
            stage: stage,
            reason: .unknown,
            diagnosticTail: nil
        )
    }

    static func dependencies() throws -> CompressionCoordinatorDependencies {
        let mediaInfo = try mediaInfo()
        return CompressionCoordinatorDependencies(
            mediaProber: FakeMediaProber { _ in mediaInfo },
            transcoder: FakeTranscoder(
                handler: { _, _ in
                    try TranscodeResult(byteCount: 1)
                },
                cancellationHandler: { _ in }
            ),
            outputPlanner: FakeOutputPlanner { request in
                let directory = request.policy.directoryURL
                return try OutputPlan(
                    request: request,
                    temporaryURL: directory.appendingPathComponent(
                        "\(request.jobID.uuidString).partial.mp4"
                    ),
                    finalURL: directory.appendingPathComponent("test.mp4")
                )
            },
            fileAccess: PassthroughFileAccess(
                metadataProvider: { _ in nil },
                commitHandler: { _ in },
                cleanupHandler: { _ in }
            )
        )
    }
}
