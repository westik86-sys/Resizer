import Foundation
import Testing
@testable import Resizer

@Suite("Typed FFmpeg command builder")
struct FFmpegCommandBuilderTests {
    private static let jobID = UUID(
        uuidString: "01234567-89AB-CDEF-0123-456789ABCDEF"
    )!
    private static let jobToken = jobID.uuidString.lowercased()
    private static let inputURL = URL(
        fileURLWithPath: "/tmp/Клипы/лето 2026.mov"
    )
    private static let outputDirectory = URL(
        fileURLWithPath: "/tmp/Результаты с пробелами",
        isDirectory: true
    )
    private static let temporaryURL = outputDirectory.appendingPathComponent(
        "результат.\(jobToken).partial.mp4"
    )

    @Test("Automatic mode produces the complete stable argument vector")
    func automaticGoldenArguments() async throws {
        let request = try makeAutomaticRequest()

        let arguments = try await FFmpegCommandBuilder().arguments(for: request)

        #expect(
            arguments == [
                "-hide_banner",
                "-loglevel", "error",
                "-stats_period", "0.25",
                "-nostats",
                "-progress", "pipe:1",
                "-autorotate",
                "-i", Self.inputURL.path,
                "-map", "0:2",
                "-map", "0:5",
                "-sn",
                "-dn",
                "-c:v:0", "h264_videotoolbox",
                "-global_quality:v:0", "75",
                "-pix_fmt:v:0", "yuv420p",
                "-color_range:v:0", "tv",
                "-filter:v:0",
                "scale=w='if(gte(iw,ih),min(iw,1920),min(iw,1080))':"
                    + "h='if(gte(iw,ih),min(ih,1080),min(ih,1920))':"
                    + "force_original_aspect_ratio=decrease:"
                    + "force_divisible_by=2:reset_sar=1:flags=lanczos:"
                    + "out_range=tv",
                "-fpsmax:v:0", "30",
                "-c:a:0", "aac",
                "-b:a:0", "128000",
                "-map_metadata:g", "0:g",
                "-map_metadata:s:v:0", "0:s:2",
                "-map_metadata:s:a:0", "0:s:5",
                "-map_chapters", "0",
                "-metadata:s:v:0", "rotate=0",
                "-write_tmcd", "0",
                "-movflags", "+faststart",
                "-f", "mp4",
                "fd:3",
            ]
        )
    }

    @Test("Confirmed ten-bit SDR uses the fixed HEVC Main10 argument path")
    func main10Arguments() async throws {
        let mediaInfo = try makeMediaInfo(
            streams: [
                .video(
                    try makeVideo(
                        index: 2,
                        codecName: "h264",
                        pixelFormat: "yuv444p10le",
                        bitDepth: 10,
                        dynamicRange: .sdr
                    )
                ),
                .audio(try makeAudio(index: 5)),
            ]
        )
        let request = try makeAutomaticRequest(mediaInfo: mediaInfo)

        let arguments = try await FFmpegCommandBuilder().arguments(for: request)

        #expect(optionValues("-c:v:0", in: arguments) == ["hevc_videotoolbox"])
        #expect(optionValues("-global_quality:v:0", in: arguments) == ["70"])
        #expect(optionValues("-pix_fmt:v:0", in: arguments) == ["p010le"])
        #expect(optionValues("-profile:v:0", in: arguments) == ["main10"])
        #expect(optionValues("-allow_sw:v:0", in: arguments) == ["1"])
        #expect(optionValues("-tag:v:0", in: arguments) == ["hvc1"])
        #expect(
            optionValues("-filter:v:0", in: arguments).allSatisfy {
                !$0.contains("sws_dither")
            }
        )
    }

    @Test("Ten-to-eight-bit compatibility conversion uses error diffusion")
    func h264FallbackDithersTenBitSource() async throws {
        let mediaInfo = try makeMediaInfo(
            streams: [
                .video(
                    try makeVideo(
                        index: 2,
                        pixelFormat: "yuv420p10le",
                        bitDepth: 10,
                        dynamicRange: .sdr
                    )
                ),
            ]
        )
        let request = try makeRequest(
            recipe: makeRecipe(videoCodec: .h264VideoToolbox),
            mediaInfo: mediaInfo
        )

        let arguments = try await FFmpegCommandBuilder().arguments(for: request)

        #expect(
            optionValues("-filter:v:0", in: arguments).allSatisfy {
                $0.hasSuffix(":sws_dither=ed")
            }
        )
    }

    @Test("Flexible settings produce bounded video and explicit audio removal")
    func flexibleAudioRemovalArguments() async throws {
        let mediaInfo = try makeMediaInfo()
        let settings = PrimaryCompressionSettings.flexible(
            try FlexibleCompressionSettings(
                quality: VideoQuality(0.80),
                resolution: .p720,
                frameRate: .fps24,
                audioPreference: .remove
            )
        )
        let recipe = try AutomaticCompressionPolicy().recipe(
            for: mediaInfo,
            settings: settings
        )
        let request = try makeRequest(recipe: recipe, mediaInfo: mediaInfo)

        let arguments = try await FFmpegCommandBuilder().arguments(for: request)

        #expect(optionValues("-global_quality:v:0", in: arguments) == ["80"])
        #expect(
            optionValues("-filter:v:0", in: arguments) == [
                "scale=w='if(gte(iw,ih),min(iw,1280),min(iw,720))':"
                    + "h='if(gte(iw,ih),min(ih,720),min(ih,1280))':"
                    + "force_original_aspect_ratio=decrease:"
                    + "force_divisible_by=2:reset_sar=1:flags=lanczos:"
                    + "out_range=tv",
            ]
        )
        #expect(optionValues("-fpsmax:v:0", in: arguments) == ["24"])
        #expect(optionValues("-map", in: arguments) == ["0:2"])
        #expect(arguments.contains("-an"))
        #expect(!arguments.contains("-c:a:0"))
        #expect(!arguments.contains("-b:a:0"))
        #expect(!arguments.contains("-map_metadata:s:a:0"))
    }

    @Test("Automatic mode omits audio arguments when the source has no audio")
    func automaticWithoutAudioStream() async throws {
        let mediaInfo = try makeMediaInfo(
            streams: [.video(try makeVideo(index: 2))]
        )
        let request = try makeAutomaticRequest(mediaInfo: mediaInfo)

        let arguments = try await FFmpegCommandBuilder().arguments(for: request)

        #expect(optionValues("-map", in: arguments) == ["0:2"])
        #expect(arguments.contains("-an"))
        #expect(!arguments.contains("-c:a:0"))
        #expect(!arguments.contains("-b:a:0"))
        #expect(!arguments.contains("-map_metadata:s:a:0"))
    }

    @Test("Full-range SDR HEVC input becomes limited-range H.264 output")
    func fullRangeHEVCInputUsesH264CompatibilityOutput() async throws {
        let mediaInfo = try makeMediaInfo(
            streams: [
                .video(
                    try makeVideo(
                        index: 2,
                        codecName: "hevc",
                        pixelFormat: "yuvj420p"
                    )
                ),
                .audio(try makeAudio(index: 5)),
            ]
        )
        let request = try makeAutomaticRequest(mediaInfo: mediaInfo)

        let arguments = try await FFmpegCommandBuilder().arguments(for: request)

        #expect(
            optionValues("-c:v:0", in: arguments) == ["h264_videotoolbox"]
        )
        #expect(optionValues("-pix_fmt:v:0", in: arguments) == ["yuv420p"])
        #expect(optionValues("-color_range:v:0", in: arguments) == ["tv"])
        #expect(
            try #require(optionValues("-filter:v:0", in: arguments).first)
                .contains("out_range=tv")
        )
        #expect(optionValues("-map", in: arguments) == ["0:2", "0:5"])
    }

    @Test("Remove metadata maps global, selected streams, and chapters to none")
    func removesMetadata() async throws {
        let recipe = try makeRecipe(metadataPolicy: .remove)
        let request = try makeRequest(recipe: recipe)

        let arguments = try await FFmpegCommandBuilder().arguments(for: request)

        #expect(optionValues("-map_metadata:g", in: arguments) == ["-1"])
        #expect(optionValues("-map_metadata:s:v:0", in: arguments) == ["-1"])
        #expect(optionValues("-map_metadata:s:a:0", in: arguments) == ["-1"])
        #expect(optionValues("-map_chapters", in: arguments) == ["-1"])
        #expect(optionValues("-metadata:s:v:0", in: arguments) == ["rotate=0"])
    }

    @Test("Default streams win by lowest absolute index and cover art is ignored")
    func selectsDefaultStreamsAndIgnoresAttachedPicture() async throws {
        let mediaInfo = try makeMediaInfo(
            streams: [
                .video(
                    try makeVideo(
                        index: 0,
                        disposition: disposition(
                            isDefault: true,
                            isAttachedPicture: true
                        )
                    )
                ),
                .video(try makeVideo(index: 8)),
                .video(
                    try makeVideo(
                        index: 4,
                        disposition: disposition(isDefault: true)
                    )
                ),
                .video(
                    try makeVideo(
                        index: 2,
                        disposition: disposition(isDefault: true)
                    )
                ),
                .audio(try makeAudio(index: 1)),
                .audio(
                    try makeAudio(
                        index: 9,
                        disposition: disposition(isDefault: true)
                    )
                ),
                .audio(
                    try makeAudio(
                        index: 5,
                        disposition: disposition(isDefault: true)
                    )
                ),
            ]
        )
        let request = try makeAutomaticRequest(mediaInfo: mediaInfo)

        let arguments = try await FFmpegCommandBuilder().arguments(for: request)

        #expect(optionValues("-map", in: arguments) == ["0:2", "0:5"])
        #expect(
            optionValues("-map_metadata:s:v:0", in: arguments) == ["0:s:2"]
        )
        #expect(
            optionValues("-map_metadata:s:a:0", in: arguments) == ["0:s:5"]
        )
    }

    @Test("HDR video is rejected before arguments are returned")
    func rejectsHDR() async throws {
        let mediaInfo = try makeMediaInfo(
            streams: [
                .video(
                    try makeVideo(
                        index: 7,
                        bitDepth: 10,
                        dynamicRange: .hdr
                    )
                ),
            ]
        )
        let request = try makeAutomaticRequest(mediaInfo: mediaInfo)

        await expectBuilderError(.unsupportedVideoFormat(streamIndex: 7)) {
            try await FFmpegCommandBuilder().arguments(for: request)
        }
    }

    @Test("Unlabelled video above 8-bit is rejected conservatively")
    func rejectsUnknownTenBitVideo() async throws {
        let mediaInfo = try makeMediaInfo(
            streams: [
                .video(
                    try makeVideo(
                        index: 6,
                        bitDepth: 10,
                        dynamicRange: .unknown
                    )
                ),
            ]
        )
        let request = try makeAutomaticRequest(mediaInfo: mediaInfo)

        await expectBuilderError(.unsupportedVideoFormat(streamIndex: 6)) {
            try await FFmpegCommandBuilder().arguments(for: request)
        }
    }

    @Test("Unknown range with unknown bit depth is rejected fail-closed")
    func rejectsUnknownUnclassifiedDepth() async throws {
        let mediaInfo = try makeMediaInfo(
            streams: [
                .video(
                    try makeVideo(
                        index: 8,
                        bitDepth: nil,
                        dynamicRange: .unknown
                    )
                ),
            ]
        )
        let request = try makeAutomaticRequest(mediaInfo: mediaInfo)

        await expectBuilderError(.unsupportedVideoFormat(streamIndex: 8)) {
            try await FFmpegCommandBuilder().arguments(for: request)
        }
    }

    @Test("Anamorphic source pixels are rejected before encode")
    func rejectsNonSquareSampleAspectRatio() async throws {
        let mediaInfo = try makeMediaInfo(
            streams: [
                .video(
                    try makeVideo(
                        index: 4,
                        sampleAspectRatio: RationalAspectRatio(
                            numerator: 32,
                            denominator: 27
                        )
                    )
                ),
            ]
        )
        let request = try makeAutomaticRequest(mediaInfo: mediaInfo)

        await expectBuilderError(.unsupportedVideoFormat(streamIndex: 4)) {
            try await FFmpegCommandBuilder().arguments(for: request)
        }
    }

    @Test("Only attached pictures do not satisfy the video requirement")
    func rejectsAttachedPictureOnlyInput() async throws {
        let mediaInfo = try makeMediaInfo(
            streams: [
                .video(
                    try makeVideo(
                        index: 3,
                        disposition: disposition(isAttachedPicture: true)
                    )
                ),
            ]
        )
        let request = try makeAutomaticRequest(mediaInfo: mediaInfo)

        await expectBuilderError(.missingVideoStream) {
            try await FFmpegCommandBuilder().arguments(for: request)
        }
    }

    @Test("Quality endpoints and fractional FPS serialize deterministically")
    func qualityAndFractionalFrameRateArguments() async throws {
        let zeroQuality = try makeRecipe(
            quality: 0,
            frameRatePolicy: .capped(
                try FrameRateLimit(framesPerSecond: 29.97)
            )
        )
        let fullQuality = try makeRecipe(quality: 1)

        let zeroArguments = try await FFmpegCommandBuilder().arguments(
            for: makeRequest(recipe: zeroQuality)
        )
        let fullArguments = try await FFmpegCommandBuilder().arguments(
            for: makeRequest(recipe: fullQuality)
        )

        #expect(
            optionValues("-global_quality:v:0", in: zeroArguments) == ["1"]
        )
        #expect(optionValues("-fpsmax:v:0", in: zeroArguments) == ["29.97"])
        #expect(
            optionValues("-global_quality:v:0", in: fullArguments) == ["100"]
        )
        #expect(!fullArguments.contains("-fpsmax:v:0"))
    }

    @Test("Validated requests route media through the reserved stdout descriptor")
    func outputSafetyArguments() async throws {
        let request = try makeAutomaticRequest()
        let arguments = try await FFmpegCommandBuilder().arguments(for: request)

        #expect(arguments.suffix(3) == ["-f", "mp4", "fd:3"])
        #expect(optionValues("-write_tmcd", in: arguments) == ["0"])
        #expect(arguments.last == "fd:3")
        #expect(!arguments.contains("-n"))
        #expect(!arguments.contains(Self.temporaryURL.path))
        #expect(Self.temporaryURL.lastPathComponent.hasSuffix(".partial.mp4"))
        #expect(
            Self.temporaryURL.lastPathComponent.lowercased()
                .contains(Self.jobToken)
        )
        #expect(!arguments.contains("/tmp/Результаты с пробелами/final.mp4"))
    }

    @Test("Unsafe URLs are rejected before a command request can be formed")
    func unsafeOutputPlanCannotCreateRequest() throws {
        let remoteInput = URL(string: "https://example.com/video.mov")!
        let remoteRequest = OutputPlanningRequest(
            jobID: Self.jobID,
            inputURL: remoteInput,
            policy: try OutputPolicy(directoryURL: Self.outputDirectory)
        )

        #expect(throws: OutputPlanValidationError.invalidPlan) {
            _ = try OutputPlan(
                request: remoteRequest,
                temporaryURL: Self.temporaryURL,
                finalURL: Self.outputDirectory.appendingPathComponent(
                    "final.mp4"
                )
            )
        }

        let wrongTemporaryURL = Self.outputDirectory.appendingPathComponent(
            "not-job-owned.mp4"
        )
        let normalRequest = try planningRequest()
        #expect(throws: OutputPlanValidationError.invalidPlan) {
            _ = try OutputPlan(
                request: normalRequest,
                temporaryURL: wrongTemporaryURL,
                finalURL: Self.outputDirectory.appendingPathComponent(
                    "final.mp4"
                )
            )
        }

        let aliasDirectory = URL(
            fileURLWithPath: "/tmp/alias",
            isDirectory: true
        )
        let aliasURL = aliasDirectory.appendingPathComponent(
            "source.\(Self.jobToken).partial.mp4"
        )
        let aliasRequest = OutputPlanningRequest(
            jobID: Self.jobID,
            inputURL: aliasURL,
            policy: try OutputPolicy(directoryURL: aliasDirectory)
        )
        #expect(throws: OutputPlanValidationError.invalidPlan) {
            _ = try OutputPlan(
                request: aliasRequest,
                temporaryURL: aliasURL,
                finalURL: aliasDirectory.appendingPathComponent("final.mp4")
            )
        }
    }

    private func makeRequest(
        recipe: CompressionRecipe,
        mediaInfo: MediaInfo? = nil
    ) throws -> TranscodeCommandRequest {
        let planningRequest = try planningRequest()
        let outputPlan = try OutputPlan(
            request: planningRequest,
            temporaryURL: Self.temporaryURL,
            finalURL: Self.outputDirectory.appendingPathComponent("final.mp4")
        )
        let transcodeRequest = TranscodeRequest(
            outputPlan: outputPlan,
            mediaInfo: try mediaInfo ?? makeMediaInfo(),
            recipe: recipe
        )
        return TranscodeCommandRequest(transcodeRequest: transcodeRequest)
    }

    private func makeAutomaticRequest(
        mediaInfo: MediaInfo? = nil
    ) throws -> TranscodeCommandRequest {
        let mediaInfo = try mediaInfo ?? makeMediaInfo()
        let recipe = try AutomaticCompressionPolicy().recipe(
            for: mediaInfo,
            settings: .quick(audio: .keep)
        )
        return try makeRequest(recipe: recipe, mediaInfo: mediaInfo)
    }

    private func planningRequest() throws -> OutputPlanningRequest {
        OutputPlanningRequest(
            jobID: Self.jobID,
            inputURL: Self.inputURL,
            policy: try OutputPolicy(directoryURL: Self.outputDirectory)
        )
    }

    private func makeRecipe(
        videoCodec: VideoCodec = .h264VideoToolbox,
        quality: Double = 0.65,
        scalePolicy: ScalePolicy = .original,
        frameRatePolicy: FrameRatePolicy = .original,
        audioPolicy: AudioPolicy? = nil,
        metadataPolicy: MetadataPolicy = .preserveCommon
    ) throws -> CompressionRecipe {
        CompressionRecipe(
            origin: .primary(.quick(audio: .keep)),
            container: .mp4,
            videoCodec: videoCodec,
            rateControl: .quality(try VideoQuality(quality)),
            scalePolicy: scalePolicy,
            frameRatePolicy: frameRatePolicy,
            audioPolicy: try audioPolicy ?? .aac(
                AudioBitRate(bitsPerSecond: 128_000)
            ),
            metadataPolicy: metadataPolicy
        )
    }

    private func makeMediaInfo(
        streams: [MediaStream]? = nil
    ) throws -> MediaInfo {
        try MediaInfo(
            formatNames: ["mov", "mp4"],
            durationMicroseconds: 5_000_000,
            byteCount: 8_000_000,
            bitRate: 12_800_000,
            streams: try streams ?? [
                .video(makeVideo(index: 2)),
                .audio(makeAudio(index: 5)),
            ]
        )
    }

    private func makeVideo(
        index: Int,
        codecName: String = "h264",
        pixelFormat: String? = "yuv420p",
        bitDepth: Int? = 8,
        dynamicRange: DynamicRange = .sdr,
        sampleAspectRatio: RationalAspectRatio? = nil,
        disposition: StreamDisposition = .none
    ) throws -> VideoStreamInfo {
        try VideoStreamInfo(
            index: index,
            codecName: codecName,
            encodedWidth: 1_920,
            encodedHeight: 1_080,
            frameRate: try RationalFrameRate(numerator: 30_000, denominator: 1_001),
            sampleAspectRatio: sampleAspectRatio,
            rotationDegrees: 0,
            pixelFormat: pixelFormat,
            bitDepth: bitDepth,
            dynamicRange: dynamicRange,
            disposition: disposition
        )
    }

    private func makeAudio(
        index: Int,
        disposition: StreamDisposition = .none
    ) throws -> AudioStreamInfo {
        try AudioStreamInfo(
            index: index,
            codecName: "aac",
            sampleRate: 48_000,
            channelCount: 2,
            channelLayout: "stereo",
            bitRate: 128_000,
            languageCode: "eng",
            disposition: disposition
        )
    }

    private func disposition(
        isDefault: Bool = false,
        isAttachedPicture: Bool = false
    ) -> StreamDisposition {
        StreamDisposition(
            isDefault: isDefault,
            isForced: false,
            isAttachedPicture: isAttachedPicture
        )
    }

    private func optionValues(_ option: String, in arguments: [String]) -> [String] {
        arguments.indices.compactMap { index in
            guard arguments[index] == option,
                  arguments.indices.contains(index + 1) else {
                return nil
            }
            return arguments[index + 1]
        }
    }

    private func expectBuilderError(
        _ expected: FFmpegCommandBuilderError,
        operation: () async throws -> [String]
    ) async {
        do {
            _ = try await operation()
            Issue.record("Expected FFmpegCommandBuilderError \(expected)")
        } catch let error as FFmpegCommandBuilderError {
            #expect(error == expected)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }
}
