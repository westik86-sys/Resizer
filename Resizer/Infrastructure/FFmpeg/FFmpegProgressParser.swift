import Foundation

nonisolated enum FFmpegProgressParsingError: Error, Sendable, Equatable {
    case invalidTotalDuration
    case invalidPendingByteLimit
    case pendingByteLimitExceeded(maximumByteCount: Int)
    case invalidUTF8
    case malformedLine
    case duplicateValue(key: String)
    case invalidValue(key: String)
    case missingProcessedTime
    case invalidSnapshot
    case incompleteRecord
    case missingEndMarker
    case dataAfterEnd
    case parserFinished
}

/// Incrementally parses the records emitted by `ffmpeg -progress pipe:1`.
///
/// A snapshot is emitted only after a `progress=continue` or `progress=end`
/// marker. The parser deliberately owns no process or pipe state, so callers
/// can feed it chunks of any size from whichever process runner drains stderr.
nonisolated struct FFmpegProgressParser: Sendable {
    static let defaultMaximumPendingByteCount = 16 * 1_024

    private let totalDurationMicroseconds: Int64?
    private let maximumPendingByteCount: Int
    private var pendingLine = Data()
    private var record = Record()
    private(set) var receivedEnd = false
    private var isFinished = false

    init(
        totalDurationMicroseconds: Int64?,
        maximumPendingByteCount: Int = defaultMaximumPendingByteCount
    ) throws {
        guard totalDurationMicroseconds.map({ $0 >= 0 }) ?? true else {
            throw FFmpegProgressParsingError.invalidTotalDuration
        }
        guard maximumPendingByteCount > 0 else {
            throw FFmpegProgressParsingError.invalidPendingByteLimit
        }

        self.totalDurationMicroseconds = totalDurationMicroseconds
        self.maximumPendingByteCount = maximumPendingByteCount
    }

    mutating func consume(_ data: Data) throws -> [TranscodeProgress] {
        guard !isFinished else {
            throw FFmpegProgressParsingError.parserFinished
        }

        var snapshots: [TranscodeProgress] = []
        for byte in data {
            if receivedEnd {
                guard byte == ASCII.carriageReturn || byte == ASCII.lineFeed else {
                    throw FFmpegProgressParsingError.dataAfterEnd
                }
                continue
            }

            if byte == ASCII.lineFeed {
                if pendingLine.last == ASCII.carriageReturn {
                    pendingLine.removeLast()
                }
                if let snapshot = try consumePendingLine() {
                    snapshots.append(snapshot)
                }
            } else {
                guard pendingLine.count < maximumPendingByteCount else {
                    throw FFmpegProgressParsingError.pendingByteLimitExceeded(
                        maximumByteCount: maximumPendingByteCount
                    )
                }
                pendingLine.append(byte)
            }
        }
        return snapshots
    }

    /// Flushes a final non-newline-terminated line and verifies normal FFmpeg
    /// progress completion. Call this once stderr reaches EOF.
    mutating func finish() throws -> [TranscodeProgress] {
        guard !isFinished else {
            throw FFmpegProgressParsingError.parserFinished
        }
        isFinished = true

        var snapshots: [TranscodeProgress] = []
        if !pendingLine.isEmpty {
            if pendingLine.last == ASCII.carriageReturn {
                pendingLine.removeLast()
            }
            if let snapshot = try consumePendingLine() {
                snapshots.append(snapshot)
            }
        }

        guard record.isEmpty else {
            throw FFmpegProgressParsingError.incompleteRecord
        }
        guard receivedEnd else {
            throw FFmpegProgressParsingError.missingEndMarker
        }
        return snapshots
    }

    private mutating func consumePendingLine() throws -> TranscodeProgress? {
        defer { pendingLine.removeAll(keepingCapacity: true) }

        guard !pendingLine.isEmpty else { return nil }
        guard let line = String(data: pendingLine, encoding: .utf8) else {
            throw FFmpegProgressParsingError.invalidUTF8
        }
        guard let separator = line.firstIndex(of: "=") else {
            throw FFmpegProgressParsingError.malformedLine
        }

        let key = String(line[..<separator])
        let value = String(line[line.index(after: separator)...])
        guard !key.isEmpty else {
            throw FFmpegProgressParsingError.malformedLine
        }

        if key == "progress" {
            return try completeRecord(marker: value)
        }
        guard let key = MetricKey(rawValue: key) else {
            return nil
        }

        try record.store(value, for: key)
        return nil
    }

    private mutating func completeRecord(
        marker: String
    ) throws -> TranscodeProgress? {
        guard marker == "continue" || marker == "end" else {
            throw FFmpegProgressParsingError.invalidValue(key: "progress")
        }
        guard let processedMicroseconds = record.processedMicroseconds else {
            // FFmpeg can emit a complete heartbeat where every out_time form
            // is N/A while audio/video clocks are being reconciled. It is not
            // a malformed record and must not turn a successful encode into a
            // parser failure, but it also carries no publishable progress.
            guard record.hasProcessedTimeField else {
                throw FFmpegProgressParsingError.missingProcessedTime
            }
            record = Record()
            if marker == "end" {
                receivedEnd = true
            }
            return nil
        }

        guard processedMicroseconds >= 0 else {
            throw FFmpegProgressParsingError.missingProcessedTime
        }

        let snapshot: TranscodeProgress
        do {
            snapshot = try TranscodeProgress(
                processedMicroseconds: processedMicroseconds,
                totalMicroseconds: totalDurationMicroseconds,
                frame: record.frame,
                framesPerSecond: record.framesPerSecond,
                speed: record.speed,
                outputByteCount: record.outputByteCount,
                duplicatedFrames: record.duplicatedFrames,
                droppedFrames: record.droppedFrames
            )
        } catch {
            throw FFmpegProgressParsingError.invalidSnapshot
        }

        record = Record()
        if marker == "end" {
            receivedEnd = true
        }
        return snapshot
    }
}

private extension FFmpegProgressParser {
    nonisolated enum ASCII {
        static let carriageReturn: UInt8 = 13
        static let lineFeed: UInt8 = 10
    }

    nonisolated enum MetricKey: String, Sendable {
        case outTimeMicroseconds = "out_time_us"
        case outTimeLegacyMicroseconds = "out_time_ms"
        case outTime = "out_time"
        case frame
        case framesPerSecond = "fps"
        case speed
        case outputByteCount = "total_size"
        case duplicatedFrames = "dup_frames"
        case droppedFrames = "drop_frames"
    }

    nonisolated struct Record: Sendable {
        private var seenKeys: Set<MetricKey> = []
        private var outTimeMicroseconds: Int64?
        private var outTimeLegacyMicroseconds: Int64?
        private var outTime: Int64?
        private(set) var frame: Int64?
        private(set) var framesPerSecond: Double?
        private(set) var speed: Double?
        private(set) var outputByteCount: Int64?
        private(set) var duplicatedFrames: Int64?
        private(set) var droppedFrames: Int64?

        var isEmpty: Bool {
            seenKeys.isEmpty
        }

        var processedMicroseconds: Int64? {
            outTimeMicroseconds
                ?? outTimeLegacyMicroseconds
                ?? outTime
        }

        var hasProcessedTimeField: Bool {
            seenKeys.contains(.outTimeMicroseconds)
                || seenKeys.contains(.outTimeLegacyMicroseconds)
                || seenKeys.contains(.outTime)
        }

        mutating func store(
            _ value: String,
            for key: MetricKey
        ) throws {
            guard seenKeys.insert(key).inserted else {
                throw FFmpegProgressParsingError.duplicateValue(
                    key: key.rawValue
                )
            }

            switch key {
            case .outTimeMicroseconds:
                outTimeMicroseconds = try optionalNonNegativeInteger(
                    value,
                    key: key
                )
            case .outTimeLegacyMicroseconds:
                // Despite its historical name, FFmpeg emits this value in
                // microseconds, alongside out_time_us.
                outTimeLegacyMicroseconds = try optionalNonNegativeInteger(
                    value,
                    key: key
                )
            case .outTime:
                outTime = try optionalTimestampMicroseconds(value, key: key)
            case .frame:
                frame = try optionalNonNegativeInteger(value, key: key)
            case .framesPerSecond:
                framesPerSecond = try optionalNonNegativeDouble(
                    value,
                    key: key
                )
            case .speed:
                speed = try optionalSpeed(value, key: key)
            case .outputByteCount:
                outputByteCount = try optionalNonNegativeInteger(
                    value,
                    key: key
                )
            case .duplicatedFrames:
                duplicatedFrames = try optionalNonNegativeInteger(
                    value,
                    key: key
                )
            case .droppedFrames:
                droppedFrames = try optionalNonNegativeInteger(
                    value,
                    key: key
                )
            }
        }

        private func optionalNonNegativeInteger(
            _ value: String,
            key: MetricKey
        ) throws -> Int64? {
            guard !isUnavailable(value) else { return nil }
            guard let parsed = Int64(value), parsed >= 0 else {
                throw FFmpegProgressParsingError.invalidValue(
                    key: key.rawValue
                )
            }
            return parsed
        }

        private func optionalNonNegativeDouble(
            _ value: String,
            key: MetricKey
        ) throws -> Double? {
            guard !isUnavailable(value) else { return nil }
            guard let parsed = Double(value),
                  parsed.isFinite,
                  parsed >= 0 else {
                throw FFmpegProgressParsingError.invalidValue(
                    key: key.rawValue
                )
            }
            return parsed
        }

        private func optionalSpeed(
            _ value: String,
            key: MetricKey
        ) throws -> Double? {
            guard !isUnavailable(value) else { return nil }
            guard value.last == "x",
                  let parsed = Double(value.dropLast()),
                  parsed.isFinite,
                  parsed >= 0 else {
                throw FFmpegProgressParsingError.invalidValue(
                    key: key.rawValue
                )
            }
            return parsed
        }

        private func optionalTimestampMicroseconds(
            _ value: String,
            key: MetricKey
        ) throws -> Int64? {
            guard !isUnavailable(value) else { return nil }
            let components = value.split(
                separator: ":",
                omittingEmptySubsequences: false
            )
            guard components.count == 3,
                  let hours = Int64(components[0]),
                  let minutes = Int64(components[1]),
                  hours >= 0,
                  minutes >= 0,
                  minutes < 60,
                  let seconds = exactDecimal(String(components[2])),
                  seconds >= 0,
                  seconds < 60 else {
                throw FFmpegProgressParsingError.invalidValue(
                    key: key.rawValue
                )
            }

            let (hourMicroseconds, hoursOverflow) = hours
                .multipliedReportingOverflow(by: 3_600_000_000)
            let minuteMicroseconds = minutes * 60_000_000
            guard !hoursOverflow else {
                throw FFmpegProgressParsingError.invalidValue(
                    key: key.rawValue
                )
            }

            var scaledSeconds = seconds * Decimal(1_000_000)
            var roundedSeconds = Decimal()
            NSDecimalRound(&roundedSeconds, &scaledSeconds, 0, .plain)
            guard roundedSeconds >= 0,
                  roundedSeconds <= Decimal(Int64.max) else {
                throw FFmpegProgressParsingError.invalidValue(
                    key: key.rawValue
                )
            }
            let secondMicroseconds = NSDecimalNumber(
                decimal: roundedSeconds
            ).int64Value

            let (hoursAndMinutes, minutesOverflow) = hourMicroseconds
                .addingReportingOverflow(minuteMicroseconds)
            let (total, secondsOverflow) = hoursAndMinutes
                .addingReportingOverflow(secondMicroseconds)
            guard !minutesOverflow, !secondsOverflow else {
                throw FFmpegProgressParsingError.invalidValue(
                    key: key.rawValue
                )
            }
            return total
        }

        private func exactDecimal(_ value: String) -> Decimal? {
            guard !value.isEmpty,
                  value == value.trimmingCharacters(
                    in: .whitespacesAndNewlines
                  ) else {
                return nil
            }
            let scanner = Scanner(string: value)
            scanner.locale = Locale(identifier: "en_US_POSIX")
            scanner.charactersToBeSkipped = nil
            guard let decimal = scanner.scanDecimal(), scanner.isAtEnd else {
                return nil
            }
            return decimal
        }

        private func isUnavailable(_ value: String) -> Bool {
            value.caseInsensitiveCompare("N/A") == .orderedSame
        }
    }
}
