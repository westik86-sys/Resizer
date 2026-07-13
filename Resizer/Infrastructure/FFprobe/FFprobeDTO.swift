import Foundation

nonisolated struct FFprobeScalar: Decodable, Sendable, Equatable {
    private enum Storage: Sendable, Equatable {
        case integer(Int64)
        case floatingPoint(Double)
        case text(String)
    }

    private let storage: Storage

    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(Int64.self) {
            storage = .integer(value)
        } else if let value = try? container.decode(Double.self) {
            storage = .floatingPoint(value)
        } else if let value = try? container.decode(String.self) {
            storage = .text(value)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Expected a string or JSON number."
            )
        }
    }

    func decimalValue() throws -> Decimal? {
        switch storage {
        case .integer(let value):
            return Decimal(value)
        case .floatingPoint(let value):
            guard value.isFinite else {
                throw ConversionError.invalidNumber
            }
            return Decimal(value)
        case .text(let value):
            let text = value.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            if text.caseInsensitiveCompare("N/A") == .orderedSame {
                return nil
            }

            let scanner = Scanner(string: text)
            scanner.locale = Locale(identifier: "en_US_POSIX")
            scanner.charactersToBeSkipped = nil
            guard !text.isEmpty,
                  let decimal = scanner.scanDecimal(),
                  scanner.isAtEnd else {
                throw ConversionError.invalidNumber
            }
            return decimal
        }
    }

    func int64Value() throws -> Int64? {
        guard let decimalValue = try decimalValue() else {
            return nil
        }
        let candidate = NSDecimalNumber(decimal: decimalValue).int64Value
        guard Decimal(candidate) == decimalValue else {
            throw ConversionError.invalidInteger
        }
        return candidate
    }

    private enum ConversionError: Error {
        case invalidNumber
        case invalidInteger
    }
}

nonisolated struct FFprobeDocumentDTO: Decodable, Sendable, Equatable {
    nonisolated struct StreamDTO: Decodable, Sendable, Equatable {
        let index: FFprobeScalar?
        let codecName: String?
        let codecType: String?
        let width: FFprobeScalar?
        let height: FFprobeScalar?
        let averageFrameRate: String?
        let realFrameRate: String?
        let pixelFormat: String?
        let bitsPerRawSample: FFprobeScalar?
        let bitsPerSample: FFprobeScalar?
        let sampleRate: FFprobeScalar?
        let channels: FFprobeScalar?
        let channelLayout: String?
        let bitRate: FFprobeScalar?
        let colorPrimaries: String?
        let colorTransfer: String?
        let colorSpace: String?
        let disposition: DispositionDTO?
        let tags: TagsDTO?
        let sideDataList: [SideDataDTO]

        enum CodingKeys: String, CodingKey {
            case index
            case codecName = "codec_name"
            case codecType = "codec_type"
            case width
            case height
            case averageFrameRate = "avg_frame_rate"
            case realFrameRate = "r_frame_rate"
            case pixelFormat = "pix_fmt"
            case bitsPerRawSample = "bits_per_raw_sample"
            case bitsPerSample = "bits_per_sample"
            case sampleRate = "sample_rate"
            case channels
            case channelLayout = "channel_layout"
            case bitRate = "bit_rate"
            case colorPrimaries = "color_primaries"
            case colorTransfer = "color_transfer"
            case colorSpace = "color_space"
            case disposition
            case tags
            case sideDataList = "side_data_list"
        }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            index = try container.decodeIfPresent(
                FFprobeScalar.self,
                forKey: .index
            )
            codecName = try container.decodeIfPresent(
                String.self,
                forKey: .codecName
            )
            codecType = try container.decodeIfPresent(
                String.self,
                forKey: .codecType
            )
            width = try container.decodeIfPresent(
                FFprobeScalar.self,
                forKey: .width
            )
            height = try container.decodeIfPresent(
                FFprobeScalar.self,
                forKey: .height
            )
            averageFrameRate = try container.decodeIfPresent(
                String.self,
                forKey: .averageFrameRate
            )
            realFrameRate = try container.decodeIfPresent(
                String.self,
                forKey: .realFrameRate
            )
            pixelFormat = try container.decodeIfPresent(
                String.self,
                forKey: .pixelFormat
            )
            bitsPerRawSample = try container.decodeIfPresent(
                FFprobeScalar.self,
                forKey: .bitsPerRawSample
            )
            bitsPerSample = try container.decodeIfPresent(
                FFprobeScalar.self,
                forKey: .bitsPerSample
            )
            sampleRate = try container.decodeIfPresent(
                FFprobeScalar.self,
                forKey: .sampleRate
            )
            channels = try container.decodeIfPresent(
                FFprobeScalar.self,
                forKey: .channels
            )
            channelLayout = try container.decodeIfPresent(
                String.self,
                forKey: .channelLayout
            )
            bitRate = try container.decodeIfPresent(
                FFprobeScalar.self,
                forKey: .bitRate
            )
            colorPrimaries = try container.decodeIfPresent(
                String.self,
                forKey: .colorPrimaries
            )
            colorTransfer = try container.decodeIfPresent(
                String.self,
                forKey: .colorTransfer
            )
            colorSpace = try container.decodeIfPresent(
                String.self,
                forKey: .colorSpace
            )
            disposition = try container.decodeIfPresent(
                DispositionDTO.self,
                forKey: .disposition
            )
            tags = try container.decodeIfPresent(TagsDTO.self, forKey: .tags)
            sideDataList = try container.decodeIfPresent(
                [SideDataDTO].self,
                forKey: .sideDataList
            ) ?? []
        }
    }

    nonisolated struct DispositionDTO: Decodable, Sendable, Equatable {
        let defaultValue: FFprobeScalar?
        let forced: FFprobeScalar?
        let attachedPicture: FFprobeScalar?

        enum CodingKeys: String, CodingKey {
            case defaultValue = "default"
            case forced
            case attachedPicture = "attached_pic"
        }
    }

    nonisolated struct TagsDTO: Decodable, Sendable, Equatable {
        let language: String?
        let rotation: String?

        enum CodingKeys: String, CodingKey {
            case language
            case rotation = "rotate"
        }
    }

    nonisolated struct SideDataDTO: Decodable, Sendable, Equatable {
        let sideDataType: String?
        let rotation: FFprobeScalar?

        enum CodingKeys: String, CodingKey {
            case sideDataType = "side_data_type"
            case rotation
        }
    }

    nonisolated struct FormatDTO: Decodable, Sendable, Equatable {
        let formatName: String?
        let duration: FFprobeScalar?
        let size: FFprobeScalar?
        let bitRate: FFprobeScalar?

        enum CodingKeys: String, CodingKey {
            case formatName = "format_name"
            case duration
            case size
            case bitRate = "bit_rate"
        }
    }

    nonisolated struct ChapterDTO: Decodable, Sendable, Equatable {}

    let streams: [StreamDTO]
    let format: FormatDTO?
    let chapters: [ChapterDTO]

    enum CodingKeys: String, CodingKey {
        case streams
        case format
        case chapters
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        streams = try container.decodeIfPresent(
            [StreamDTO].self,
            forKey: .streams
        ) ?? []
        format = try container.decodeIfPresent(FormatDTO.self, forKey: .format)
        chapters = try container.decodeIfPresent(
            [ChapterDTO].self,
            forKey: .chapters
        ) ?? []
    }
}
