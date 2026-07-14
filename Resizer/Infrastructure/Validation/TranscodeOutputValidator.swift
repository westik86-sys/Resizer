import Foundation

nonisolated protocol TranscodeOutputValidating: Sendable {
    func validate(
        output: MediaInfo,
        source: MediaInfo,
        recipe: CompressionRecipe
    ) throws
}

nonisolated enum UnsupportedTranscodeOutputStream: Sendable, Equatable {
    case attachment
    case subtitle
    case other(codecType: String?)
}

nonisolated enum TranscodeOutputValidationError: Error, Sendable, Equatable {
    case unexpectedContainer(actual: [String])
    case unsupportedStream(
        index: Int,
        kind: UnsupportedTranscodeOutputStream
    )
    case unexpectedVideoStreamCount(actual: Int)
    case unexpectedVideoCodec(index: Int, actual: String?)
    case unexpectedPixelFormat(index: Int, actual: String?)
    case incompatibleVideoRange(
        index: Int,
        dynamicRange: DynamicRange,
        bitDepth: Int?
    )
    case invalidVideoDimensions(
        index: Int,
        width: Int?,
        height: Int?
    )
    case nonNormalizedRotation(index: Int, degrees: Int)
    case unexpectedAudioStreamCount(expected: Int, actual: Int)
    case unexpectedAudioCodec(index: Int, actual: String?)
    case missingSourceVideoStream
    case missingSourceVideoDimensions(index: Int)
    case unsupportedSourceRotation(index: Int, degrees: Int)
    case invalidSourceDuration(actual: Int64?)
    case invalidOutputDuration(actual: Int64?)
    case durationMismatch(
        sourceMicroseconds: Int64,
        outputMicroseconds: Int64,
        toleranceMicroseconds: Int64
    )
    case resolutionOutOfBounds(
        sourceWidth: Int,
        sourceHeight: Int,
        outputWidth: Int,
        outputHeight: Int,
        maximumLongEdge: Int,
        maximumShortEdge: Int
    )
    case resolutionMismatch(
        expectedWidth: Int,
        expectedHeight: Int,
        actualWidth: Int,
        actualHeight: Int,
        tolerance: Int
    )
    case aspectRatioMismatch(
        sourceWidth: Int,
        sourceHeight: Int,
        outputWidth: Int,
        outputHeight: Int
    )
}

nonisolated struct TranscodeOutputValidator:
    TranscodeOutputValidating,
    Sendable
{
    func validate(
        output: MediaInfo,
        source: MediaInfo,
        recipe: CompressionRecipe
    ) throws {
        try validateContainer(output, recipe: recipe)
        try validateUnsupportedStreams(output)

        let outputVideo = try validatedOutputVideo(output)
        try validateAudio(output, source: source, recipe: recipe)
        try validateDuration(output, source: source)

        let sourceVideo = try selectedSourceVideo(source)
        let sourceDimensions = try displayDimensions(of: sourceVideo)
        let outputDimensions = try dimensions(of: outputVideo)
        try validateScale(
            source: sourceDimensions,
            output: outputDimensions,
            policy: recipe.scalePolicy
        )
        try validateAspectRatio(
            source: sourceDimensions,
            output: outputDimensions
        )
    }

    private func validateContainer(
        _ output: MediaInfo,
        recipe: CompressionRecipe
    ) throws {
        switch recipe.container {
        case .mp4:
            let names = output.formatNames.map { normalizedName($0) }
            guard names.contains("mp4") else {
                throw TranscodeOutputValidationError.unexpectedContainer(
                    actual: output.formatNames
                )
            }
        }
    }

    private func validateUnsupportedStreams(_ output: MediaInfo) throws {
        for stream in output.streams {
            if disposition(of: stream).isAttachedPicture {
                throw TranscodeOutputValidationError.unsupportedStream(
                    index: stream.index,
                    kind: .attachment
                )
            }

            switch stream {
            case .video, .audio:
                continue
            case .subtitle:
                throw TranscodeOutputValidationError.unsupportedStream(
                    index: stream.index,
                    kind: .subtitle
                )
            case .other(let other):
                throw TranscodeOutputValidationError.unsupportedStream(
                    index: stream.index,
                    kind: .other(codecType: other.codecType)
                )
            }
        }
    }

    private func validatedOutputVideo(
        _ output: MediaInfo
    ) throws -> VideoStreamInfo {
        let videos = output.videoStreams
        guard videos.count == 1, let video = videos.first else {
            throw TranscodeOutputValidationError
                .unexpectedVideoStreamCount(actual: videos.count)
        }
        guard normalizedName(video.codecName) == "h264" else {
            throw TranscodeOutputValidationError.unexpectedVideoCodec(
                index: video.index,
                actual: video.codecName
            )
        }
        guard normalizedName(video.pixelFormat) == "yuv420p" else {
            throw TranscodeOutputValidationError.unexpectedPixelFormat(
                index: video.index,
                actual: video.pixelFormat
            )
        }

        let isEightBitOrUnspecified = video.bitDepth.map { $0 <= 8 } ?? true
        guard video.dynamicRange != .hdr, isEightBitOrUnspecified else {
            throw TranscodeOutputValidationError.incompatibleVideoRange(
                index: video.index,
                dynamicRange: video.dynamicRange,
                bitDepth: video.bitDepth
            )
        }

        if let rotation = video.rotationDegrees,
           normalizedRotation(rotation) != 0 {
            throw TranscodeOutputValidationError.nonNormalizedRotation(
                index: video.index,
                degrees: rotation
            )
        }

        _ = try dimensions(of: video)
        return video
    }

    private func validateAudio(
        _ output: MediaInfo,
        source: MediaInfo,
        recipe: CompressionRecipe
    ) throws {
        let expectedCount: Int
        switch recipe.audioPolicy {
        case .aac where !source.audioStreams.isEmpty:
            expectedCount = 1
        case .aac, .remove:
            expectedCount = 0
        }

        let audioStreams = output.audioStreams
        guard audioStreams.count == expectedCount else {
            throw TranscodeOutputValidationError.unexpectedAudioStreamCount(
                expected: expectedCount,
                actual: audioStreams.count
            )
        }
        guard let audio = audioStreams.first else { return }
        guard normalizedName(audio.codecName) == "aac" else {
            throw TranscodeOutputValidationError.unexpectedAudioCodec(
                index: audio.index,
                actual: audio.codecName
            )
        }
    }

    private func validateDuration(
        _ output: MediaInfo,
        source: MediaInfo
    ) throws {
        guard let sourceDuration = source.durationMicroseconds,
              sourceDuration > 0 else {
            throw TranscodeOutputValidationError.invalidSourceDuration(
                actual: source.durationMicroseconds
            )
        }
        guard let outputDuration = output.durationMicroseconds,
              outputDuration > 0 else {
            throw TranscodeOutputValidationError.invalidOutputDuration(
                actual: output.durationMicroseconds
            )
        }

        let tolerance = max(
            250_000,
            min(2_000_000, sourceDuration / 100)
        )
        let difference = sourceDuration >= outputDuration
            ? sourceDuration - outputDuration
            : outputDuration - sourceDuration
        guard difference <= tolerance else {
            throw TranscodeOutputValidationError.durationMismatch(
                sourceMicroseconds: sourceDuration,
                outputMicroseconds: outputDuration,
                toleranceMicroseconds: tolerance
            )
        }
    }

    private func selectedSourceVideo(
        _ source: MediaInfo
    ) throws -> VideoStreamInfo {
        let candidates = source.videoStreams.filter {
            !$0.disposition.isAttachedPicture
        }
        guard !candidates.isEmpty else {
            throw TranscodeOutputValidationError.missingSourceVideoStream
        }
        return candidates
            .filter(\.disposition.isDefault)
            .min(by: { $0.index < $1.index })
            ?? candidates.min(by: { $0.index < $1.index })!
    }

    private func displayDimensions(
        of video: VideoStreamInfo
    ) throws -> Dimensions {
        let encoded = try dimensions(
            of: video,
            requireEven: false,
            missingError: .missingSourceVideoDimensions(index: video.index)
        )
        let rotation = normalizedRotation(video.rotationDegrees ?? 0)
        switch rotation {
        case 0, 180:
            return encoded
        case 90, 270:
            return Dimensions(width: encoded.height, height: encoded.width)
        default:
            throw TranscodeOutputValidationError.unsupportedSourceRotation(
                index: video.index,
                degrees: video.rotationDegrees ?? 0
            )
        }
    }

    private func dimensions(of video: VideoStreamInfo) throws -> Dimensions {
        try dimensions(
            of: video,
            requireEven: true,
            missingError: .invalidVideoDimensions(
                index: video.index,
                width: video.encodedWidth,
                height: video.encodedHeight
            )
        )
    }

    private func dimensions(
        of video: VideoStreamInfo,
        requireEven: Bool,
        missingError: TranscodeOutputValidationError
    ) throws -> Dimensions {
        guard let width = video.encodedWidth,
              let height = video.encodedHeight,
              width > 0,
              height > 0,
              !requireEven || (
                  width.isMultiple(of: 2) && height.isMultiple(of: 2)
              ) else {
            throw missingError
        }
        return Dimensions(width: width, height: height)
    }

    private func validateScale(
        source: Dimensions,
        output: Dimensions,
        policy: ScalePolicy
    ) throws {
        switch policy {
        case .original:
            let expected = Dimensions(
                width: evenFloor(source.width),
                height: evenFloor(source.height)
            )
            try requireResolution(
                output,
                expected: expected,
                tolerance: 0
            )
        case .maximum(let limit):
            guard output.width <= source.width,
                  output.height <= source.height,
                  max(output.width, output.height) <= limit.maximumLongEdge,
                  min(output.width, output.height) <= limit.maximumShortEdge else {
                throw TranscodeOutputValidationError.resolutionOutOfBounds(
                    sourceWidth: source.width,
                    sourceHeight: source.height,
                    outputWidth: output.width,
                    outputHeight: output.height,
                    maximumLongEdge: limit.maximumLongEdge,
                    maximumShortEdge: limit.maximumShortEdge
                )
            }

            let scale = min(
                1,
                Double(limit.maximumLongEdge)
                    / Double(max(source.width, source.height)),
                Double(limit.maximumShortEdge)
                    / Double(min(source.width, source.height))
            )
            let expected = Dimensions(
                width: evenFloor(Double(source.width) * scale),
                height: evenFloor(Double(source.height) * scale)
            )
            try requireResolution(
                output,
                expected: expected,
                tolerance: 2
            )
        }
    }

    private func requireResolution(
        _ actual: Dimensions,
        expected: Dimensions,
        tolerance: Int
    ) throws {
        guard distance(actual.width, expected.width) <= tolerance,
              distance(actual.height, expected.height) <= tolerance else {
            throw TranscodeOutputValidationError.resolutionMismatch(
                expectedWidth: expected.width,
                expectedHeight: expected.height,
                actualWidth: actual.width,
                actualHeight: actual.height,
                tolerance: tolerance
            )
        }
    }

    private func validateAspectRatio(
        source: Dimensions,
        output: Dimensions
    ) throws {
        let sourceRatio = Double(source.width) / Double(source.height)
        let outputRatio = Double(output.width) / Double(output.height)
        let relativeDifference = abs(outputRatio - sourceRatio) / sourceRatio
        let roundingAllowance = 2 / Double(output.width)
            + 2 / Double(output.height)
        guard relativeDifference <= max(0.01, roundingAllowance) else {
            throw TranscodeOutputValidationError.aspectRatioMismatch(
                sourceWidth: source.width,
                sourceHeight: source.height,
                outputWidth: output.width,
                outputHeight: output.height
            )
        }
    }

    private func disposition(of stream: MediaStream) -> StreamDisposition {
        switch stream {
        case .video(let video):
            video.disposition
        case .audio(let audio):
            audio.disposition
        case .subtitle(let subtitle):
            subtitle.disposition
        case .other(let other):
            other.disposition
        }
    }

    private func normalizedName(_ value: String?) -> String {
        value?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() ?? ""
    }

    private func normalizedRotation(_ degrees: Int) -> Int {
        let remainder = degrees % 360
        return remainder >= 0 ? remainder : remainder + 360
    }

    private func evenFloor(_ value: Int) -> Int {
        max(2, value - value % 2)
    }

    private func evenFloor(_ value: Double) -> Int {
        max(2, Int(value / 2) * 2)
    }

    private func distance(_ lhs: Int, _ rhs: Int) -> Int {
        lhs >= rhs ? lhs - rhs : rhs - lhs
    }
}

private nonisolated struct Dimensions: Sendable, Equatable {
    let width: Int
    let height: Int
}
