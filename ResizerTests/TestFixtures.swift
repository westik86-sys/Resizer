import Foundation
@testable import Resizer

nonisolated enum TestFixtures {
    static func mediaInfo(
        includeAudio: Bool = true,
        videoCodec: String = "h264",
        pixelFormat: String = "yuv420p",
        bitDepth: Int = 8,
        dynamicRange: DynamicRange = .sdr
    ) throws -> MediaInfo {
        var streams: [MediaStream] = [
            .video(
                try VideoStreamInfo(
                    index: 0,
                    codecName: videoCodec,
                    encodedWidth: 1_920,
                    encodedHeight: 1_080,
                    frameRate: try RationalFrameRate(
                        numerator: 30_000,
                        denominator: 1_001
                    ),
                    rotationDegrees: 0,
                    pixelFormat: pixelFormat,
                    bitDepth: bitDepth,
                    dynamicRange: dynamicRange
                )
            ),
        ]
        if includeAudio {
            streams.append(
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
                )
            )
        }

        return try MediaInfo(
            formatNames: ["mov", "mp4"],
            durationMicroseconds: 10_000_000,
            byteCount: 4_096,
            bitRate: 2_000_000,
            streams: streams
        )
    }

    static func configuration(
        mediaInfo: MediaInfo? = nil
    ) throws -> JobConfiguration {
        let recipe = try AutomaticCompressionPolicy().recipe(
            for: mediaInfo ?? self.mediaInfo(),
            settings: .quick(audio: .keep)
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
            sourceByteCount: 4_096,
            outputByteCount: 2_048,
            elapsed: .seconds(4)
        )
    }

    static func noBenefitResult() throws -> CompressionNoBenefitResult {
        try CompressionNoBenefitResult(
            sourceByteCount: 4_096,
            candidateByteCount: 4_096,
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
                    try TranscodeResult(
                        byteCount: 1,
                        temporaryMetadata: FileMetadata(
                            byteCount: 1,
                            isDirectory: false,
                            identity: FileIdentity(device: 1, inode: 1)
                        )
                    )
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
