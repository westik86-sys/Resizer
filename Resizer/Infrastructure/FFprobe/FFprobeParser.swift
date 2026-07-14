import Foundation

nonisolated enum FFprobeParsingError: Error, Sendable, Equatable {
    case malformedJSON
    case invalidMetadata
}

nonisolated struct FFprobeParser: Sendable {
    func parse(_ data: Data) throws -> MediaInfo {
        let document: FFprobeDocumentDTO
        do {
            document = try JSONDecoder().decode(
                FFprobeDocumentDTO.self,
                from: data
            )
        } catch {
            throw FFprobeParsingError.malformedJSON
        }

        do {
            return try map(document)
        } catch {
            throw FFprobeParsingError.invalidMetadata
        }
    }

    private func map(_ document: FFprobeDocumentDTO) throws -> MediaInfo {
        let formatNames = document.format?.formatName?
            .split(separator: ",")
            .map {
                $0.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            .filter { !$0.isEmpty } ?? []
        let durationMicroseconds = try microseconds(
            from: document.format?.duration
        )
        let byteCount = try nonNegativeInteger(
            document.format?.size,
            missingValue: 0
        )
        let bitRate = try optionalNonNegativeInteger(
            document.format?.bitRate
        )
        let streams = try document.streams.map(mapStream)

        return try MediaInfo(
            formatNames: formatNames,
            durationMicroseconds: durationMicroseconds,
            byteCount: byteCount,
            bitRate: bitRate,
            streams: streams
        )
    }

    private func mapStream(
        _ stream: FFprobeDocumentDTO.StreamDTO
    ) throws -> MediaStream {
        guard let indexValue = stream.index,
              let rawIndex = try indexValue.int64Value(),
              rawIndex >= 0,
              let index = Int(exactly: rawIndex) else {
            throw FFprobeParsingError.invalidMetadata
        }

        let disposition = StreamDisposition(
            isDefault: try flag(stream.disposition?.defaultValue),
            isForced: try flag(stream.disposition?.forced),
            isAttachedPicture: try flag(
                stream.disposition?.attachedPicture
            )
        )
        let codecType = cleaned(stream.codecType)?.lowercased()

        switch codecType {
        case "video":
            let colorMetadata = VideoColorMetadata(
                primaries: cleaned(stream.colorPrimaries),
                transfer: cleaned(stream.colorTransfer),
                space: cleaned(stream.colorSpace)
            )
            return .video(
                try VideoStreamInfo(
                    index: index,
                    codecName: cleaned(stream.codecName),
                    encodedWidth: try optionalPositiveInt(stream.width),
                    encodedHeight: try optionalPositiveInt(stream.height),
                    frameRate: frameRate(
                        average: stream.averageFrameRate,
                        real: stream.realFrameRate
                    ),
                    sampleAspectRatio: try sampleAspectRatio(
                        stream.sampleAspectRatio
                    ),
                    rotationDegrees: try rotation(stream),
                    pixelFormat: cleaned(stream.pixelFormat),
                    bitDepth: try bitDepth(stream),
                    colorMetadata: colorMetadata,
                    dynamicRange: dynamicRange(
                        transfer: colorMetadata.transfer
                    ),
                    disposition: disposition
                )
            )
        case "audio":
            return .audio(
                try AudioStreamInfo(
                    index: index,
                    codecName: cleaned(stream.codecName),
                    sampleRate: try optionalPositiveInt(stream.sampleRate),
                    channelCount: try optionalPositiveInt(stream.channels),
                    channelLayout: cleaned(stream.channelLayout),
                    bitRate: try optionalNonNegativeInteger(stream.bitRate),
                    languageCode: cleaned(stream.tags?.language),
                    disposition: disposition
                )
            )
        case "subtitle":
            return .subtitle(
                try SubtitleStreamInfo(
                    index: index,
                    codecName: cleaned(stream.codecName),
                    languageCode: cleaned(stream.tags?.language),
                    disposition: disposition
                )
            )
        default:
            return .other(
                try OtherStreamInfo(
                    index: index,
                    codecType: cleaned(stream.codecType),
                    codecName: cleaned(stream.codecName),
                    disposition: disposition
                )
            )
        }
    }

    private func microseconds(from value: FFprobeScalar?) throws -> Int64? {
        guard let value else {
            return nil
        }
        guard let seconds = try value.decimalValue() else {
            return nil
        }
        guard seconds >= 0 else {
            throw FFprobeParsingError.invalidMetadata
        }

        var scaled = seconds * Decimal(1_000_000)
        var rounded = Decimal()
        NSDecimalRound(&rounded, &scaled, 0, .plain)
        guard rounded >= 0, rounded <= Decimal(Int64.max) else {
            throw FFprobeParsingError.invalidMetadata
        }
        return NSDecimalNumber(decimal: rounded).int64Value
    }

    private func nonNegativeInteger(
        _ value: FFprobeScalar?,
        missingValue: Int64
    ) throws -> Int64 {
        try optionalNonNegativeInteger(value) ?? missingValue
    }

    private func optionalNonNegativeInteger(
        _ value: FFprobeScalar?
    ) throws -> Int64? {
        guard let value else {
            return nil
        }
        guard let integer = try value.int64Value() else { return nil }
        guard integer >= 0 else {
            throw FFprobeParsingError.invalidMetadata
        }
        return integer
    }

    private func optionalPositiveInt(
        _ value: FFprobeScalar?
    ) throws -> Int? {
        guard let value else {
            return nil
        }
        guard let integer = try value.int64Value() else { return nil }
        guard integer >= 0 else {
            throw FFprobeParsingError.invalidMetadata
        }
        guard integer > 0 else {
            return nil
        }
        guard let converted = Int(exactly: integer) else {
            throw FFprobeParsingError.invalidMetadata
        }
        return converted
    }

    private func bitDepth(
        _ stream: FFprobeDocumentDTO.StreamDTO
    ) throws -> Int? {
        if let value = try optionalPositiveInt(stream.bitsPerRawSample) {
            return value
        }
        if let value = try optionalPositiveInt(stream.bitsPerSample) {
            return value
        }
        return inferredBitDepth(from: cleaned(stream.pixelFormat))
    }

    /// FFprobe commonly omits both bit-depth fields for HEVC Main10 while
    /// still reporting an endian-qualified pixel format such as
    /// `yuv420p10le`. Recover the trailing component conservatively so an
    /// unlabelled 10-bit/HDR source cannot pass the SDR-only preflight.
    private func inferredBitDepth(from pixelFormat: String?) -> Int? {
        guard var candidate = pixelFormat?.lowercased(),
              !candidate.isEmpty else {
            return nil
        }

        if candidate.hasSuffix("le") || candidate.hasSuffix("be") {
            candidate.removeLast(2)
        }

        let exactDepths: [String: Int] = [
            "yuv420p": 8,
            "yuvj420p": 8,
            "yuv422p": 8,
            "yuvj422p": 8,
            "yuv444p": 8,
            "yuvj444p": 8,
            "uyvy422": 8,
            "yuyv422": 8,
            "nv12": 8,
            "nv21": 8,
            "rgb24": 8,
            "bgr24": 8,
            "rgba": 8,
            "bgra": 8,
            "argb": 8,
            "abgr": 8,
            "gray": 8,
            "gray8": 8,
            "p010": 10,
            "p210": 10,
            "p410": 10,
            "y210": 10,
            "v210": 10,
            "v410": 10,
            "nv20": 10,
            "x2rgb10": 10,
            "x2bgr10": 10,
            "y410": 10,
            "xv30": 10,
            "p012": 12,
            "p212": 12,
            "p412": 12,
            "y212": 12,
            "xyz12": 12,
            "y412": 12,
            "xv36": 12,
            "p016": 16,
            "p216": 16,
            "p416": 16,
            "y216": 16,
            "rgb48": 16,
            "bgr48": 16,
            "rgba64": 16,
            "bgra64": 16,
            "argb64": 16,
            "abgr64": 16,
            "y416": 16,
            "gbrpf32": 32,
            "gbrapf32": 32,
        ]
        if let exact = exactDepths[candidate] {
            return exact
        }

        for depth in [9, 10, 12, 14, 16] {
            if candidate.hasSuffix("p\(depth)")
                || candidate.hasSuffix("gray\(depth)") {
                return depth
            }
        }
        return nil
    }

    private func frameRate(
        average: String?,
        real: String?
    ) -> RationalFrameRate? {
        parseFrameRate(average) ?? parseFrameRate(real)
    }

    private func sampleAspectRatio(
        _ value: String?
    ) throws -> RationalAspectRatio? {
        guard let value = cleaned(value),
              value.uppercased() != "N/A" else {
            return nil
        }
        let components = value.split(
            separator: ":",
            omittingEmptySubsequences: false
        )
        guard components.count == 2,
              let numerator = Int64(components[0]),
              let denominator = Int64(components[1]) else {
            throw FFprobeParsingError.invalidMetadata
        }
        if numerator == 0, denominator > 0 {
            return nil
        }
        return try RationalAspectRatio(
            numerator: numerator,
            denominator: denominator
        )
    }

    private func parseFrameRate(_ value: String?) -> RationalFrameRate? {
        guard let value else {
            return nil
        }
        let components = value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: "/", omittingEmptySubsequences: false)
        guard components.count == 2,
              let numerator = Int64(components[0]),
              let denominator = Int64(components[1]),
              numerator > 0,
              denominator > 0 else {
            return nil
        }
        return try? RationalFrameRate(
            numerator: numerator,
            denominator: denominator
        )
    }

    private func rotation(
        _ stream: FFprobeDocumentDTO.StreamDTO
    ) throws -> Int? {
        for sideData in stream.sideDataList where sideData.sideDataType?
            .lowercased()
            .contains("display matrix") == true {
            guard let rawRotation = try sideData.rotation?.int64Value() else {
                continue
            }
            guard let value = Int(exactly: rawRotation) else {
                throw FFprobeParsingError.invalidMetadata
            }
            return value
        }

        guard let tag = cleaned(stream.tags?.rotation) else {
            return nil
        }
        if tag.caseInsensitiveCompare("N/A") == .orderedSame {
            return nil
        }
        guard let value = Int(tag) else {
            throw FFprobeParsingError.invalidMetadata
        }
        return value
    }

    private func dynamicRange(transfer: String?) -> DynamicRange {
        guard let transfer = cleaned(transfer)?.lowercased() else {
            return .unknown
        }
        if ["smpte2084", "arib-std-b67"].contains(transfer) {
            return .hdr
        }
        if [
            "bt709",
            "smpte170m",
            "bt470m",
            "bt470bg",
            "iec61966-2-1",
            "gamma22",
            "gamma28",
        ].contains(transfer) {
            return .sdr
        }
        return .unknown
    }

    private func flag(_ value: FFprobeScalar?) throws -> Bool {
        guard let value,
              let integer = try value.int64Value() else {
            return false
        }
        return integer != 0
    }

    private func cleaned(_ value: String?) -> String? {
        guard let value else {
            return nil
        }
        let cleaned = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? nil : cleaned
    }
}
