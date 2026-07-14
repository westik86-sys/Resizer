nonisolated struct MediaInfo: Sendable, Equatable {
    let formatNames: [String]
    let durationMicroseconds: Int64?
    let byteCount: Int64
    let bitRate: Int64?
    let streams: [MediaStream]

    init(
        formatNames: [String],
        durationMicroseconds: Int64?,
        byteCount: Int64,
        bitRate: Int64?,
        streams: [MediaStream]
    ) throws {
        guard durationMicroseconds.map({ $0 >= 0 }) ?? true,
              byteCount >= 0,
              bitRate.map({ $0 >= 0 }) ?? true else {
            throw MediaInfoValidationError.invalidContainerMetric
        }

        let streamIndexes = streams.map(\.index)
        guard Set(streamIndexes).count == streamIndexes.count else {
            throw MediaInfoValidationError.duplicateStreamIndex
        }

        self.formatNames = formatNames
        self.durationMicroseconds = durationMicroseconds
        self.byteCount = byteCount
        self.bitRate = bitRate
        self.streams = streams
    }

    var videoStreams: [VideoStreamInfo] {
        streams.compactMap { stream in
            guard case .video(let video) = stream else { return nil }
            return video
        }
    }

    var audioStreams: [AudioStreamInfo] {
        streams.compactMap { stream in
            guard case .audio(let audio) = stream else { return nil }
            return audio
        }
    }
}

nonisolated enum MediaStream: Sendable, Equatable {
    case video(VideoStreamInfo)
    case audio(AudioStreamInfo)
    case subtitle(SubtitleStreamInfo)
    case other(OtherStreamInfo)

    var index: Int {
        switch self {
        case .video(let stream):
            stream.index
        case .audio(let stream):
            stream.index
        case .subtitle(let stream):
            stream.index
        case .other(let stream):
            stream.index
        }
    }
}

nonisolated struct StreamDisposition: Sendable, Equatable {
    let isDefault: Bool
    let isForced: Bool
    let isAttachedPicture: Bool

    static let none = StreamDisposition(
        isDefault: false,
        isForced: false,
        isAttachedPicture: false
    )
}

nonisolated struct VideoColorMetadata: Sendable, Equatable {
    let primaries: String?
    let transfer: String?
    let space: String?

    static let unknown = VideoColorMetadata(
        primaries: nil,
        transfer: nil,
        space: nil
    )
}

nonisolated struct VideoStreamInfo: Sendable, Equatable {
    let index: Int
    let codecName: String?
    let encodedWidth: Int?
    let encodedHeight: Int?
    let frameRate: RationalFrameRate?
    let sampleAspectRatio: RationalAspectRatio?
    let rotationDegrees: Int?
    let pixelFormat: String?
    let bitDepth: Int?
    let colorMetadata: VideoColorMetadata
    let dynamicRange: DynamicRange
    let disposition: StreamDisposition

    init(
        index: Int,
        codecName: String?,
        encodedWidth: Int?,
        encodedHeight: Int?,
        frameRate: RationalFrameRate?,
        sampleAspectRatio: RationalAspectRatio? = nil,
        rotationDegrees: Int?,
        pixelFormat: String?,
        bitDepth: Int?,
        colorMetadata: VideoColorMetadata = .unknown,
        dynamicRange: DynamicRange,
        disposition: StreamDisposition = .none
    ) throws {
        guard index >= 0,
              encodedWidth.map({ $0 > 0 }) ?? true,
              encodedHeight.map({ $0 > 0 }) ?? true,
              bitDepth.map({ $0 > 0 }) ?? true else {
            throw MediaInfoValidationError.invalidStreamMetric
        }

        self.index = index
        self.codecName = codecName
        self.encodedWidth = encodedWidth
        self.encodedHeight = encodedHeight
        self.frameRate = frameRate
        self.sampleAspectRatio = sampleAspectRatio
        self.rotationDegrees = rotationDegrees
        self.pixelFormat = pixelFormat
        self.bitDepth = bitDepth
        self.colorMetadata = colorMetadata
        self.dynamicRange = dynamicRange
        self.disposition = disposition
    }
}

nonisolated struct AudioStreamInfo: Sendable, Equatable {
    let index: Int
    let codecName: String?
    let sampleRate: Int?
    let channelCount: Int?
    let channelLayout: String?
    let bitRate: Int64?
    let languageCode: String?
    let disposition: StreamDisposition

    init(
        index: Int,
        codecName: String?,
        sampleRate: Int?,
        channelCount: Int?,
        channelLayout: String?,
        bitRate: Int64?,
        languageCode: String?,
        disposition: StreamDisposition = .none
    ) throws {
        guard index >= 0,
              sampleRate.map({ $0 > 0 }) ?? true,
              channelCount.map({ $0 > 0 }) ?? true,
              bitRate.map({ $0 >= 0 }) ?? true else {
            throw MediaInfoValidationError.invalidStreamMetric
        }

        self.index = index
        self.codecName = codecName
        self.sampleRate = sampleRate
        self.channelCount = channelCount
        self.channelLayout = channelLayout
        self.bitRate = bitRate
        self.languageCode = languageCode
        self.disposition = disposition
    }
}

nonisolated struct SubtitleStreamInfo: Sendable, Equatable {
    let index: Int
    let codecName: String?
    let languageCode: String?
    let disposition: StreamDisposition

    init(
        index: Int,
        codecName: String?,
        languageCode: String?,
        disposition: StreamDisposition = .none
    ) throws {
        guard index >= 0 else {
            throw MediaInfoValidationError.invalidStreamMetric
        }

        self.index = index
        self.codecName = codecName
        self.languageCode = languageCode
        self.disposition = disposition
    }
}

nonisolated struct OtherStreamInfo: Sendable, Equatable {
    let index: Int
    let codecType: String?
    let codecName: String?
    let disposition: StreamDisposition

    init(
        index: Int,
        codecType: String?,
        codecName: String?,
        disposition: StreamDisposition = .none
    ) throws {
        guard index >= 0 else {
            throw MediaInfoValidationError.invalidStreamMetric
        }

        self.index = index
        self.codecType = codecType
        self.codecName = codecName
        self.disposition = disposition
    }
}

nonisolated enum DynamicRange: Sendable, Equatable {
    case sdr
    case hdr
    case unknown
}

nonisolated struct RationalFrameRate: Sendable, Equatable {
    let numerator: Int64
    let denominator: Int64

    init(numerator: Int64, denominator: Int64) throws {
        guard numerator > 0, denominator > 0 else {
            throw MediaInfoValidationError.invalidFrameRate
        }
        self.numerator = numerator
        self.denominator = denominator
    }

    var doubleValue: Double {
        Double(numerator) / Double(denominator)
    }
}

nonisolated struct RationalAspectRatio: Sendable, Equatable {
    let numerator: Int64
    let denominator: Int64

    init(numerator: Int64, denominator: Int64) throws {
        guard numerator > 0, denominator > 0 else {
            throw MediaInfoValidationError.invalidAspectRatio
        }
        self.numerator = numerator
        self.denominator = denominator
    }

    var isSquare: Bool {
        numerator == denominator
    }
}

nonisolated enum MediaInfoValidationError: Error, Sendable, Equatable {
    case invalidContainerMetric
    case duplicateStreamIndex
    case invalidStreamMetric
    case invalidFrameRate
    case invalidAspectRatio
}
