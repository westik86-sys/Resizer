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

    @Test("High Quality produces the complete stable argument vector")
    func highQualityGoldenArguments() async throws {
        let recipe = try CompressionRecipe(preset: .highQuality)
        let request = try makeRequest(recipe: recipe)

        let arguments = try await FFmpegCommandBuilder().arguments(for: request)

        #expect(
            arguments == [
                "-hide_banner",
                "-loglevel", "warning",
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
                "-global_quality:v:0", "85",
                "-pix_fmt:v:0", "yuv420p",
                "-filter:v:0",
                "scale=w='max(2,trunc(iw/2)*2)':"
                    + "h='max(2,trunc(ih/2)*2)':flags=lanczos",
                "-c:a:0", "aac",
                "-b:a:0", "192000",
                "-map_metadata:g", "0:g",
                "-map_metadata:s:v:0", "0:s:2",
                "-map_metadata:s:a:0", "0:s:5",
                "-map_chapters", "0",
                "-metadata:s:v:0", "rotate=0",
                "-movflags", "+faststart",
                "-f", "mp4",
                "-n",
                Self.temporaryURL.path,
            ]
        )
    }

    @Test("Balanced produces the complete stable argument vector")
    func balancedGoldenArguments() async throws {
        let recipe = try CompressionRecipe(preset: .balanced)
        let request = try makeRequest(recipe: recipe)

        let arguments = try await FFmpegCommandBuilder().arguments(for: request)

        #expect(
            arguments == [
                "-hide_banner",
                "-loglevel", "warning",
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
                "-global_quality:v:0", "65",
                "-pix_fmt:v:0", "yuv420p",
                "-filter:v:0",
                "scale=w='if(gte(iw,ih),min(iw,1920),min(iw,1080))':"
                    + "h='if(gte(iw,ih),min(ih,1080),min(ih,1920))':"
                    + "force_original_aspect_ratio=decrease:"
                    + "force_divisible_by=2:reset_sar=1:flags=lanczos",
                "-fpsmax:v:0", "30",
                "-c:a:0", "aac",
                "-b:a:0", "128000",
                "-map_metadata:g", "0:g",
                "-map_metadata:s:v:0", "0:s:2",
                "-map_metadata:s:a:0", "0:s:5",
                "-map_chapters", "0",
                "-metadata:s:v:0", "rotate=0",
                "-movflags", "+faststart",
                "-f", "mp4",
                "-n",
                Self.temporaryURL.path,
            ]
        )
    }

    @Test("Small File produces the complete stable argument vector")
    func smallFileGoldenArguments() async throws {
        let recipe = try CompressionRecipe(preset: .smallFile)
        let request = try makeRequest(recipe: recipe)

        let arguments = try await FFmpegCommandBuilder().arguments(for: request)

        #expect(
            arguments == [
                "-hide_banner",
                "-loglevel", "warning",
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
                "-global_quality:v:0", "45",
                "-pix_fmt:v:0", "yuv420p",
                "-filter:v:0",
                "scale=w='if(gte(iw,ih),min(iw,1280),min(iw,720))':"
                    + "h='if(gte(iw,ih),min(ih,720),min(ih,1280))':"
                    + "force_original_aspect_ratio=decrease:"
                    + "force_divisible_by=2:reset_sar=1:flags=lanczos",
                "-fpsmax:v:0", "24",
                "-c:a:0", "aac",
                "-b:a:0", "96000",
                "-map_metadata:g", "0:g",
                "-map_metadata:s:v:0", "0:s:2",
                "-map_metadata:s:a:0", "0:s:5",
                "-map_chapters", "0",
                "-metadata:s:v:0", "rotate=0",
                "-movflags", "+faststart",
                "-f", "mp4",
                "-n",
                Self.temporaryURL.path,
            ]
        )
    }

    @Test("AAC policy accepts input without an audio stream")
    func aacWithoutAudioStream() async throws {
        let mediaInfo = try makeMediaInfo(
            streams: [.video(try makeVideo(index: 2))]
        )
        let request = try makeRequest(
            recipe: CompressionRecipe(preset: .balanced),
            mediaInfo: mediaInfo
        )

        let arguments = try await FFmpegCommandBuilder().arguments(for: request)

        #expect(optionValues("-map", in: arguments) == ["0:2"])
        #expect(arguments.contains("-an"))
        #expect(!arguments.contains("-c:a:0"))
        #expect(!arguments.contains("-b:a:0"))
        #expect(!arguments.contains("-map_metadata:s:a:0"))
    }

    @Test("Mute omits the input audio map and audio encoder")
    func muteRemovesAudio() async throws {
        let recipe = try customRecipe(audioPolicy: .remove)
        let request = try makeRequest(recipe: recipe)

        let arguments = try await FFmpegCommandBuilder().arguments(for: request)

        #expect(optionValues("-map", in: arguments) == ["0:2"])
        #expect(arguments.contains("-an"))
        #expect(!arguments.contains("-c:a:0"))
        #expect(!arguments.contains("-b:a:0"))
        #expect(!arguments.contains("-map_metadata:s:a:0"))
    }

    @Test("Remove metadata maps global, selected streams, and chapters to none")
    func removesMetadata() async throws {
        let recipe = try customRecipe(metadataPolicy: .remove)
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
        let request = try makeRequest(
            recipe: CompressionRecipe(preset: .highQuality),
            mediaInfo: mediaInfo
        )

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
        let request = try makeRequest(
            recipe: CompressionRecipe(preset: .highQuality),
            mediaInfo: mediaInfo
        )

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
        let request = try makeRequest(
            recipe: CompressionRecipe(preset: .highQuality),
            mediaInfo: mediaInfo
        )

        await expectBuilderError(.unsupportedVideoFormat(streamIndex: 6)) {
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
        let request = try makeRequest(
            recipe: CompressionRecipe(preset: .balanced),
            mediaInfo: mediaInfo
        )

        await expectBuilderError(.missingVideoStream) {
            try await FFmpegCommandBuilder().arguments(for: request)
        }
    }

    @Test("Quality endpoints and fractional FPS serialize deterministically")
    func qualityAndFractionalFrameRateArguments() async throws {
        let zeroQuality = try customRecipe(
            quality: 0,
            frameRatePolicy: .capped(
                try FrameRateLimit(framesPerSecond: 29.97)
            )
        )
        let fullQuality = try customRecipe(quality: 1)

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

    @Test("Validated requests expose only a job temporary output to FFmpeg")
    func outputSafetyArguments() async throws {
        let recipe = try CompressionRecipe(preset: .balanced)
        let request = try makeRequest(recipe: recipe)
        let arguments = try await FFmpegCommandBuilder().arguments(for: request)

        #expect(arguments.suffix(2) == ["-n", Self.temporaryURL.path])
        #expect(arguments.last == Self.temporaryURL.path)
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

    private func planningRequest() throws -> OutputPlanningRequest {
        OutputPlanningRequest(
            jobID: Self.jobID,
            inputURL: Self.inputURL,
            policy: try OutputPolicy(directoryURL: Self.outputDirectory)
        )
    }

    private func customRecipe(
        quality: Double = 0.65,
        scalePolicy: ScalePolicy = .original,
        frameRatePolicy: FrameRatePolicy = .original,
        audioPolicy: AudioPolicy? = nil,
        metadataPolicy: MetadataPolicy = .preserveCommon
    ) throws -> CompressionRecipe {
        CompressionRecipe(
            origin: .custom,
            container: .mp4,
            videoCodec: .h264VideoToolbox,
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
        bitDepth: Int? = 8,
        dynamicRange: DynamicRange = .sdr,
        disposition: StreamDisposition = .none
    ) throws -> VideoStreamInfo {
        try VideoStreamInfo(
            index: index,
            codecName: "h264",
            encodedWidth: 1_920,
            encodedHeight: 1_080,
            frameRate: try RationalFrameRate(numerator: 30_000, denominator: 1_001),
            rotationDegrees: 0,
            pixelFormat: "yuv420p",
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
