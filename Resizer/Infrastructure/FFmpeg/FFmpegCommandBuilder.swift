import Foundation

nonisolated enum FFmpegCommandBuilderError: Error, Sendable, Equatable {
    case invalidInputURL
    case invalidTemporaryOutputURL
    case inputOutputAlias
    case missingVideoStream
    case unsupportedVideoFormat(streamIndex: Int)
    case incompatibleOutputPixelFormat(
        streamIndex: Int,
        expected: OutputPixelFormat,
        actual: OutputPixelFormat
    )
}

nonisolated struct FFmpegCommandBuilder: CommandBuilding, Sendable {
    func arguments(
        for request: TranscodeCommandRequest
    ) async throws -> [String] {
        let inputURL = try validatedInputURL(request.inputURL)
        let temporaryURL = try validatedTemporaryURL(
            request.temporaryOutputURL,
            jobID: request.jobID
        )
        guard inputURL != temporaryURL else {
            throw FFmpegCommandBuilderError.inputOutputAlias
        }

        let video = try selectedVideo(in: request.mediaInfo)
        let audio = request.mediaInfo.preferredAudioStream
        try validateSDRConversion(video)
        try validateOutputPixelFormat(
            request.recipe.outputPixelFormat,
            source: video
        )

        var arguments = [
            "-hide_banner",
            "-loglevel", "error",
            "-stats_period", "0.25",
            "-nostats",
            "-progress", "pipe:1",
            "-autorotate",
            "-i", inputURL.path,
            "-map", "0:\(video.index)",
        ]

        if case .aac = request.recipe.audioPolicy, let audio {
            arguments.append(contentsOf: ["-map", "0:\(audio.index)"])
        }
        arguments.append(contentsOf: ["-sn", "-dn"])

        arguments.append(contentsOf: [
            "-c:v:0", videoCodecArgument(request.recipe.videoCodec),
        ])
        arguments.append(contentsOf: try rateControlArguments(
            request.recipe.rateControl,
            codec: request.recipe.videoCodec
        ))
        arguments.append(contentsOf: [
            "-pix_fmt:v:0",
            request.recipe.outputPixelFormat.rawValue,
            "-color_range:v:0", "tv",
        ])
        arguments.append(contentsOf: codecArguments(request.recipe.videoCodec))
        arguments.append(contentsOf: [
            "-filter:v:0",
            scaleFilter(
                request.recipe.scalePolicy,
                useErrorDiffusion: needsDithering(
                    source: video,
                    outputPixelFormat: request.recipe.outputPixelFormat
                )
            ),
        ])

        if case .capped(let limit) = request.recipe.frameRatePolicy {
            arguments.append(contentsOf: [
                "-fpsmax:v:0",
                decimalArgument(limit.framesPerSecond),
            ])
        }

        switch request.recipe.audioPolicy {
        case .aac(let bitRate) where audio != nil:
            arguments.append(contentsOf: [
                "-c:a:0", "aac",
                "-b:a:0", String(bitRate.bitsPerSecond),
            ])
        case .aac, .remove:
            arguments.append("-an")
        }

        let metadataAudio: AudioStreamInfo?
        switch request.recipe.audioPolicy {
        case .aac:
            metadataAudio = audio
        case .remove:
            metadataAudio = nil
        }

        appendMetadataArguments(
            to: &arguments,
            policy: request.recipe.metadataPolicy,
            video: video,
            audio: metadataAudio
        )

        arguments.append(contentsOf: [
            "-metadata:s:v:0", "rotate=0",
            "-write_tmcd", "0",
            "-movflags", "+faststart",
            "-f", containerArgument(request.recipe.container),
            "fd:3",
        ])
        return arguments
    }

    private func validatedInputURL(_ url: URL) throws -> URL {
        guard url.isFileURL,
              url.path.hasPrefix("/"),
              !url.path.contains("\0") else {
            throw FFmpegCommandBuilderError.invalidInputURL
        }
        return url.standardizedFileURL
    }

    private func validatedTemporaryURL(
        _ url: URL,
        jobID: CompressionJob.ID
    ) throws -> URL {
        guard url.isFileURL,
              url.path.hasPrefix("/"),
              !url.path.contains("\0") else {
            throw FFmpegCommandBuilderError.invalidTemporaryOutputURL
        }

        let standardized = url.standardizedFileURL
        let name = standardized.lastPathComponent.lowercased()
        let jobToken = jobID.uuidString.lowercased()
        guard standardized.pathExtension.lowercased() == "mp4",
              name.hasSuffix(".partial.mp4"),
              name.contains(jobToken) else {
            throw FFmpegCommandBuilderError.invalidTemporaryOutputURL
        }
        return standardized
    }

    private func selectedVideo(in mediaInfo: MediaInfo) throws -> VideoStreamInfo {
        let candidates = mediaInfo.videoStreams.filter {
            !$0.disposition.isAttachedPicture
        }
        guard !candidates.isEmpty else {
            throw FFmpegCommandBuilderError.missingVideoStream
        }
        return candidates
            .filter(\.disposition.isDefault)
            .min(by: { $0.index < $1.index })
            ?? candidates.min(by: { $0.index < $1.index })!
    }

    private func validateSDRConversion(_ video: VideoStreamInfo) throws {
        if let sampleAspectRatio = video.sampleAspectRatio,
           !sampleAspectRatio.isSquare {
            throw FFmpegCommandBuilderError.unsupportedVideoFormat(
                streamIndex: video.index
            )
        }
        let depthIsNotProvenEightBit = video.bitDepth.map { $0 > 8 } ?? true
        let couldBeUnlabelledHDR = video.dynamicRange == .unknown
            && depthIsNotProvenEightBit
        guard video.dynamicRange != .hdr, !couldBeUnlabelledHDR else {
            throw FFmpegCommandBuilderError.unsupportedVideoFormat(
                streamIndex: video.index
            )
        }
    }

    private func validateOutputPixelFormat(
        _ outputPixelFormat: OutputPixelFormat,
        source video: VideoStreamInfo
    ) throws {
        let expected: OutputPixelFormat
        do {
            expected = try OutputPixelFormat.preservingSource(video)
        } catch {
            throw FFmpegCommandBuilderError.unsupportedVideoFormat(
                streamIndex: video.index
            )
        }
        guard outputPixelFormat == expected else {
            throw FFmpegCommandBuilderError.incompatibleOutputPixelFormat(
                streamIndex: video.index,
                expected: expected,
                actual: outputPixelFormat
            )
        }
    }

    private func videoCodecArgument(_ codec: VideoCodec) -> String {
        switch codec {
        case .h264Libx264:
            "libx264"
        }
    }

    private func codecArguments(_ codec: VideoCodec) -> [String] {
        switch codec {
        case .h264Libx264:
            [
                "-preset:v:0", "medium",
                "-x264-params:v:0",
                "fullrange=off:videoformat=component",
            ]
        }
    }

    private func needsDithering(
        source: VideoStreamInfo,
        outputPixelFormat: OutputPixelFormat
    ) -> Bool {
        let sourceBitDepth = source.bitDepth
            ?? OutputPixelFormat.inferredSourceBitDepth(
                from: source.pixelFormat
            )
        return sourceBitDepth.map {
            $0 > outputPixelFormat.bitDepth
        } ?? false
    }

    private func rateControlArguments(
        _ rateControl: RateControl,
        codec: VideoCodec
    ) throws -> [String] {
        switch (codec, rateControl) {
        case (.h264Libx264, .libx264CRF(let crf)):
            return ["-crf:v:0", String(crf.value)]
        }
    }

    private func scaleFilter(
        _ policy: ScalePolicy,
        useErrorDiffusion: Bool
    ) -> String {
        let base = switch policy {
        case .original:
            "scale=w='max(2,trunc(iw/2)*2)':"
                + "h='max(2,trunc(ih/2)*2)':"
                + "flags=lanczos:out_range=tv"
        case .maximum(let limit):
            "scale=w='if(gte(iw,ih),"
                + "min(iw,\(limit.maximumLongEdge)),"
                + "min(iw,\(limit.maximumShortEdge)))':"
                + "h='if(gte(iw,ih),"
                + "min(ih,\(limit.maximumShortEdge)),"
                + "min(ih,\(limit.maximumLongEdge)))':"
                + "force_original_aspect_ratio=decrease:"
                + "force_divisible_by=2:reset_sar=1:flags=lanczos"
                + ":out_range=tv"
        }
        return useErrorDiffusion ? base + ":sws_dither=ed" : base
    }

    private func decimalArgument(_ value: Double) -> String {
        if value.rounded() == value {
            return String(Int(value))
        }
        return String(value)
    }

    private func appendMetadataArguments(
        to arguments: inout [String],
        policy: MetadataPolicy,
        video: VideoStreamInfo,
        audio: AudioStreamInfo?
    ) {
        switch policy {
        case .preserveCommon:
            arguments.append(contentsOf: [
                "-map_metadata:g", "0:g",
                "-map_metadata:s:v:0", "0:s:\(video.index)",
            ])
            if let audio {
                arguments.append(contentsOf: [
                    "-map_metadata:s:a:0", "0:s:\(audio.index)",
                ])
            }
            arguments.append(contentsOf: ["-map_chapters", "0"])
        case .remove:
            arguments.append(contentsOf: [
                "-map_metadata:g", "-1",
                "-map_metadata:s:v:0", "-1",
            ])
            if audio != nil {
                arguments.append(contentsOf: [
                    "-map_metadata:s:a:0", "-1",
                ])
            }
            arguments.append(contentsOf: ["-map_chapters", "-1"])
        }
    }

    private func containerArgument(_ container: OutputContainer) -> String {
        switch container {
        case .mp4:
            "mp4"
        }
    }
}
