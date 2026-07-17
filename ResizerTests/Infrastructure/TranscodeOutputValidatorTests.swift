import Testing
@testable import Resizer

@Suite("Transcode output validator")
struct TranscodeOutputValidatorTests {
    private let validator: any TranscodeOutputValidating =
        TranscodeOutputValidator()

    @Test("A compatible MP4 result passes validation")
    func acceptsCompatibleResult() throws {
        let source = try makeMediaInfo()
        let output = try makeMediaInfo(
            formatNames: ["mov", "MP4", "m4a"],
            durationMicroseconds: 9_750_000,
            streams: [
                .video(
                    try makeVideo(
                        bitDepth: nil,
                        dynamicRange: .unknown
                    )
                ),
                .audio(try makeAudio()),
            ]
        )

        try validator.validate(
            output: output,
            source: source,
            recipe: makeRecipe()
        )
    }

    @Test("Source autorotation is reflected in normalized output dimensions")
    func acceptsNormalizedPortraitResult() throws {
        let source = try makeMediaInfo(
            streams: [
                .video(
                    try makeVideo(
                        width: 1_920,
                        height: 1_080,
                        rotation: -90
                    )
                ),
                .audio(try makeAudio()),
            ]
        )
        let output = try makeMediaInfo(
            streams: [
                .video(
                    try makeVideo(
                        width: 1_080,
                        height: 1_920,
                        rotation: nil
                    )
                ),
                .audio(try makeAudio()),
            ]
        )

        try validator.validate(
            output: output,
            source: source,
            recipe: makeRecipe()
        )
    }

    @Test("MP4 must be one of the probed container aliases")
    func rejectsUnexpectedContainer() throws {
        let source = try makeMediaInfo()
        let output = try makeMediaInfo(formatNames: ["matroska", "webm"])

        #expect(
            throws: TranscodeOutputValidationError.unexpectedContainer(
                actual: ["matroska", "webm"]
            )
        ) {
            try validator.validate(
                output: output,
                source: source,
                recipe: makeRecipe()
            )
        }
    }

    @Test("Attached pictures, subtitles, and data streams are rejected")
    func rejectsUnsupportedStreams() throws {
        let source = try makeMediaInfo()
        let attached = try makeMediaInfo(
            streams: [
                .video(try makeVideo()),
                .audio(try makeAudio()),
                .video(
                    try makeVideo(
                        index: 2,
                        disposition: StreamDisposition(
                            isDefault: false,
                            isForced: false,
                            isAttachedPicture: true
                        )
                    )
                ),
            ]
        )
        let subtitle = try makeMediaInfo(
            streams: [
                .video(try makeVideo()),
                .audio(try makeAudio()),
                .subtitle(
                    try SubtitleStreamInfo(
                        index: 2,
                        codecName: "mov_text",
                        languageCode: nil
                    )
                ),
            ]
        )
        let data = try makeMediaInfo(
            streams: [
                .video(try makeVideo()),
                .audio(try makeAudio()),
                .other(
                    try OtherStreamInfo(
                        index: 2,
                        codecType: "data",
                        codecName: "bin_data"
                    )
                ),
            ]
        )

        try expectError(
            .unsupportedStream(index: 2, kind: .attachment),
            output: attached,
            source: source
        )
        try expectError(
            .unsupportedStream(index: 2, kind: .subtitle),
            output: subtitle,
            source: source
        )
        try expectError(
            .unsupportedStream(
                index: 2,
                kind: .other(codecType: "data")
            ),
            output: data,
            source: source
        )
    }

    @Test("Output contains exactly one ordinary video stream")
    func validatesVideoStreamCount() throws {
        let source = try makeMediaInfo()
        let noVideo = try makeMediaInfo(streams: [.audio(try makeAudio())])
        let twoVideos = try makeMediaInfo(
            streams: [
                .video(try makeVideo()),
                .audio(try makeAudio()),
                .video(try makeVideo(index: 2)),
            ]
        )

        try expectError(
            .unexpectedVideoStreamCount(actual: 0),
            output: noVideo,
            source: source
        )
        try expectError(
            .unexpectedVideoStreamCount(actual: 2),
            output: twoVideos,
            source: source
        )
    }

    @Test("Output video is H.264 yuv420p and SDR-compatible")
    func validatesVideoEncoding() throws {
        let source = try makeMediaInfo()
        let wrongCodec = try outputReplacingVideo(
            try makeVideo(codecName: "hevc")
        )
        let wrongPixelFormat = try outputReplacingVideo(
            try makeVideo(pixelFormat: "yuv444p")
        )
        let hdr = try outputReplacingVideo(
            try makeVideo(bitDepth: 10, dynamicRange: .hdr)
        )
        let tenBitUnknown = try outputReplacingVideo(
            try makeVideo(bitDepth: 10, dynamicRange: .unknown)
        )

        try expectError(
            .unexpectedVideoCodec(index: 0, actual: "hevc"),
            output: wrongCodec,
            source: source
        )
        try expectError(
            .unexpectedPixelFormat(index: 0, actual: "yuv444p"),
            output: wrongPixelFormat,
            source: source
        )
        try expectError(
            .incompatibleVideoRange(
                index: 0,
                dynamicRange: .hdr,
                bitDepth: 10
            ),
            output: hdr,
            source: source
        )
        try expectError(
            .incompatibleVideoRange(
                index: 0,
                dynamicRange: .unknown,
                bitDepth: 10
            ),
            output: tenBitUnknown,
            source: source
        )
    }

    @Test("HEVC Main10 recipe requires a proven ten-bit SDR result")
    func validatesMain10Encoding() throws {
        let source = try makeMediaInfo(
            streams: [
                .video(
                    try makeVideo(
                        codecName: "h264",
                        pixelFormat: "yuv444p10le",
                        bitDepth: 10,
                        dynamicRange: .sdr
                    )
                ),
                .audio(try makeAudio()),
            ]
        )
        let recipe = try makeRecipe(videoCodec: .hevcMain10VideoToolbox)
        let compatible = try outputReplacingVideo(
            makeVideo(
                codecName: "hevc",
                pixelFormat: "yuv420p10le",
                bitDepth: 10,
                dynamicRange: .sdr
            )
        )

        try validator.validate(
            output: compatible,
            source: source,
            recipe: recipe
        )

        let eightBit = try outputReplacingVideo(
            makeVideo(
                codecName: "hevc",
                pixelFormat: "yuv420p10le",
                bitDepth: 8,
                dynamicRange: .sdr
            )
        )
        try expectError(
            .incompatibleVideoRange(
                index: 0,
                dynamicRange: .sdr,
                bitDepth: 8
            ),
            output: eightBit,
            source: source,
            recipe: recipe
        )
    }

    @Test("Output dimensions are present, positive, and even")
    func validatesOutputDimensions() throws {
        let source = try makeMediaInfo()
        let missing = try outputReplacingVideo(
            try makeVideo(width: nil, height: 1_080)
        )
        let odd = try outputReplacingVideo(
            try makeVideo(width: 1_919, height: 1_079)
        )

        try expectError(
            .invalidVideoDimensions(index: 0, width: nil, height: 1_080),
            output: missing,
            source: source
        )
        try expectError(
            .invalidVideoDimensions(
                index: 0,
                width: 1_919,
                height: 1_079
            ),
            output: odd,
            source: source
        )
    }

    @Test("Output rotation metadata is normalized")
    func validatesOutputRotation() throws {
        let source = try makeMediaInfo()
        let rotated = try outputReplacingVideo(
            try makeVideo(rotation: 90)
        )

        try expectError(
            .nonNormalizedRotation(index: 0, degrees: 90),
            output: rotated,
            source: source
        )

        let fullTurn = try outputReplacingVideo(
            try makeVideo(rotation: 360)
        )
        try validator.validate(
            output: fullTurn,
            source: source,
            recipe: makeRecipe()
        )
    }

    @Test("AAC is required only when the source has audio and policy keeps it")
    func validatesAudioPolicy() throws {
        let sourceWithAudio = try makeMediaInfo()
        let sourceWithoutAudio = try makeMediaInfo(
            streams: [.video(try makeVideo())]
        )
        let outputWithoutAudio = try makeMediaInfo(
            streams: [.video(try makeVideo())]
        )

        try validator.validate(
            output: outputWithoutAudio,
            source: sourceWithoutAudio,
            recipe: makeRecipe()
        )
        try validator.validate(
            output: outputWithoutAudio,
            source: sourceWithAudio,
            recipe: makeRecipe(audioPolicy: .remove)
        )

        try expectError(
            .unexpectedAudioStreamCount(expected: 1, actual: 0),
            output: outputWithoutAudio,
            source: sourceWithAudio
        )

        let mutedButPresent = try makeMediaInfo()
        #expect(
            throws: TranscodeOutputValidationError
                .unexpectedAudioStreamCount(expected: 0, actual: 1)
        ) {
            try validator.validate(
                output: mutedButPresent,
                source: sourceWithAudio,
                recipe: makeRecipe(audioPolicy: .remove)
            )
        }
    }

    @Test("A kept audio stream is uniquely AAC")
    func validatesAudioCodecAndCount() throws {
        let source = try makeMediaInfo()
        let wrongCodec = try makeMediaInfo(
            streams: [
                .video(try makeVideo()),
                .audio(try makeAudio(codecName: "mp3")),
            ]
        )
        let duplicate = try makeMediaInfo(
            streams: [
                .video(try makeVideo()),
                .audio(try makeAudio()),
                .audio(try makeAudio(index: 2)),
            ]
        )

        try expectError(
            .unexpectedAudioCodec(index: 1, actual: "mp3"),
            output: wrongCodec,
            source: source
        )
        try expectError(
            .unexpectedAudioStreamCount(expected: 1, actual: 2),
            output: duplicate,
            source: source
        )
    }

    @Test("Duration tolerance is 1%, clamped to 250 ms through 2 s")
    func validatesDurationTolerance() throws {
        let cases: [(Int64, Int64)] = [
            (10_000_000, 9_750_000),
            (100_000_000, 99_000_000),
            (500_000_000, 498_000_000),
        ]
        for (sourceDuration, outputDuration) in cases {
            try validator.validate(
                output: makeMediaInfo(
                    durationMicroseconds: outputDuration
                ),
                source: makeMediaInfo(
                    durationMicroseconds: sourceDuration
                ),
                recipe: makeRecipe()
            )
        }

        let source = try makeMediaInfo(durationMicroseconds: 10_000_000)
        let outsideTolerance = try makeMediaInfo(
            durationMicroseconds: 9_749_999
        )
        try expectError(
            .durationMismatch(
                sourceMicroseconds: 10_000_000,
                outputMicroseconds: 9_749_999,
                toleranceMicroseconds: 250_000
            ),
            output: outsideTolerance,
            source: source
        )
    }

    @Test("Both source and output durations must be known and positive")
    func requiresPositiveDurations() throws {
        let valid = try makeMediaInfo()
        let missingSource = try makeMediaInfo(durationMicroseconds: nil)
        let zeroOutput = try makeMediaInfo(durationMicroseconds: 0)

        try expectError(
            .invalidSourceDuration(actual: nil),
            output: valid,
            source: missingSource
        )
        try expectError(
            .invalidOutputDuration(actual: 0),
            output: zeroOutput,
            source: valid
        )
    }

    @Test("Original scale rounds odd source dimensions down to even values")
    func validatesOriginalScale() throws {
        let source = try makeMediaInfo(
            streams: [
                .video(
                    try makeVideo(width: 1_919, height: 1_079)
                ),
                .audio(try makeAudio()),
            ]
        )
        let output = try makeMediaInfo(
            streams: [
                .video(
                    try makeVideo(width: 1_918, height: 1_078)
                ),
                .audio(try makeAudio()),
            ]
        )

        try validator.validate(
            output: output,
            source: source,
            recipe: makeRecipe()
        )
    }

    @Test("Capped scale respects both edge limits and the selected scale")
    func validatesCappedScale() throws {
        let source = try makeMediaInfo(
            streams: [
                .video(
                    try makeVideo(width: 4_000, height: 2_500)
                ),
                .audio(try makeAudio()),
            ]
        )
        let valid = try makeMediaInfo(
            streams: [
                .video(
                    try makeVideo(width: 1_728, height: 1_080)
                ),
                .audio(try makeAudio()),
            ]
        )
        let overLimit = try makeMediaInfo(
            streams: [
                .video(
                    try makeVideo(width: 1_922, height: 1_080)
                ),
                .audio(try makeAudio()),
            ]
        )
        let underScaled = try makeMediaInfo(
            streams: [
                .video(
                    try makeVideo(width: 1_280, height: 800)
                ),
                .audio(try makeAudio()),
            ]
        )
        let recipe = try makeRecipe(
            scalePolicy: .maximum(
                ResolutionLimit(
                    maximumLongEdge: 1_920,
                    maximumShortEdge: 1_080
                )
            )
        )

        try validator.validate(output: valid, source: source, recipe: recipe)
        #expect(
            throws: TranscodeOutputValidationError.resolutionOutOfBounds(
                sourceWidth: 4_000,
                sourceHeight: 2_500,
                outputWidth: 1_922,
                outputHeight: 1_080,
                maximumLongEdge: 1_920,
                maximumShortEdge: 1_080
            )
        ) {
            try validator.validate(
                output: overLimit,
                source: source,
                recipe: recipe
            )
        }
        #expect(
            throws: TranscodeOutputValidationError.resolutionMismatch(
                expectedWidth: 1_728,
                expectedHeight: 1_080,
                actualWidth: 1_280,
                actualHeight: 800,
                tolerance: 2
            )
        ) {
            try validator.validate(
                output: underScaled,
                source: source,
                recipe: recipe
            )
        }
    }

    @Test("Capped scale rejects distortion beyond rounding tolerance")
    func validatesAspectRatio() throws {
        let source = try makeMediaInfo(
            streams: [
                .video(try makeVideo(width: 202, height: 102)),
                .audio(try makeAudio()),
            ]
        )
        let distorted = try makeMediaInfo(
            streams: [
                .video(try makeVideo(width: 200, height: 98)),
                .audio(try makeAudio()),
            ]
        )
        let recipe = try makeRecipe(
            scalePolicy: .maximum(
                ResolutionLimit(
                    maximumLongEdge: 200,
                    maximumShortEdge: 100
                )
            )
        )

        #expect(
            throws: TranscodeOutputValidationError.aspectRatioMismatch(
                sourceWidth: 202,
                sourceHeight: 102,
                outputWidth: 200,
                outputHeight: 98
            )
        ) {
            try validator.validate(
                output: distorted,
                source: source,
                recipe: recipe
            )
        }
    }

    @Test("Source selection matches the command builder")
    func selectsDefaultSourceVideo() throws {
        let source = try makeMediaInfo(
            streams: [
                .video(try makeVideo(index: 8, width: 640, height: 360)),
                .video(
                    try makeVideo(
                        index: 4,
                        width: 1_280,
                        height: 720,
                        disposition: StreamDisposition(
                            isDefault: true,
                            isForced: false,
                            isAttachedPicture: false
                        )
                    )
                ),
                .video(
                    try makeVideo(
                        index: 2,
                        width: 1_920,
                        height: 1_080,
                        disposition: StreamDisposition(
                            isDefault: true,
                            isForced: false,
                            isAttachedPicture: false
                        )
                    )
                ),
                .audio(try makeAudio(index: 1)),
            ]
        )

        try validator.validate(
            output: makeMediaInfo(),
            source: source,
            recipe: makeRecipe()
        )
    }

    private func expectError(
        _ expected: TranscodeOutputValidationError,
        output: MediaInfo,
        source: MediaInfo,
        recipe: CompressionRecipe? = nil
    ) throws {
        #expect(throws: expected) {
            try validator.validate(
                output: output,
                source: source,
                recipe: try recipe ?? makeRecipe()
            )
        }
    }

    private func outputReplacingVideo(
        _ video: VideoStreamInfo
    ) throws -> MediaInfo {
        try makeMediaInfo(
            streams: [
                .video(video),
                .audio(makeAudio()),
            ]
        )
    }

    private func makeRecipe(
        videoCodec: VideoCodec = .h264Libx264,
        scalePolicy: ScalePolicy = .original,
        audioPolicy: AudioPolicy? = nil
    ) throws -> CompressionRecipe {
        try CompressionRecipe(
            origin: .primary(.quick(audio: .keep)),
            container: .mp4,
            videoCodec: videoCodec,
            rateControl: videoCodec == .h264Libx264
                ? .libx264CRF(X264ConstantRateFactor(24))
                : .videoToolboxQuality(VideoQuality(0.65)),
            scalePolicy: scalePolicy,
            frameRatePolicy: .original,
            audioPolicy: audioPolicy ?? .aac(
                AudioBitRate(bitsPerSecond: 128_000)
            ),
            metadataPolicy: .preserveCommon
        )
    }

    private func makeMediaInfo(
        formatNames: [String] = ["mov", "mp4"],
        durationMicroseconds: Int64? = 10_000_000,
        streams: [MediaStream]? = nil
    ) throws -> MediaInfo {
        try MediaInfo(
            formatNames: formatNames,
            durationMicroseconds: durationMicroseconds,
            byteCount: 1_000_000,
            bitRate: 800_000,
            streams: try streams ?? [
                .video(makeVideo()),
                .audio(makeAudio()),
            ]
        )
    }

    private func makeVideo(
        index: Int = 0,
        codecName: String? = "h264",
        width: Int? = 1_920,
        height: Int? = 1_080,
        rotation: Int? = 0,
        pixelFormat: String? = "yuv420p",
        bitDepth: Int? = 8,
        dynamicRange: DynamicRange = .sdr,
        disposition: StreamDisposition = .none
    ) throws -> VideoStreamInfo {
        try VideoStreamInfo(
            index: index,
            codecName: codecName,
            encodedWidth: width,
            encodedHeight: height,
            frameRate: try RationalFrameRate(
                numerator: 30_000,
                denominator: 1_001
            ),
            rotationDegrees: rotation,
            pixelFormat: pixelFormat,
            bitDepth: bitDepth,
            dynamicRange: dynamicRange,
            disposition: disposition
        )
    }

    private func makeAudio(
        index: Int = 1,
        codecName: String? = "aac"
    ) throws -> AudioStreamInfo {
        try AudioStreamInfo(
            index: index,
            codecName: codecName,
            sampleRate: 48_000,
            channelCount: 2,
            channelLayout: "stereo",
            bitRate: 128_000,
            languageCode: nil
        )
    }
}
