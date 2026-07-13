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
        return try optionalPositiveInt(stream.bitsPerSample)
    }

    private func frameRate(
        average: String?,
        real: String?
    ) -> RationalFrameRate? {
        parseFrameRate(average) ?? parseFrameRate(real)
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
