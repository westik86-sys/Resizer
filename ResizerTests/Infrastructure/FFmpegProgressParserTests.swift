import Foundation
import Testing
@testable import Resizer

@Suite("Machine-readable FFmpeg progress parser")
struct FFmpegProgressParserTests {
    @Test("Arbitrary fragments produce one validated progress snapshot")
    func arbitraryFragments() throws {
        let text = """
        frame=61
        fps=29.97
        bitrate=N/A
        total_size=1048576
        out_time_us=2000000
        out_time_ms=2000000
        out_time=00:00:02.000000
        dup_frames=2
        drop_frames=1
        speed=1.25x
        note=данные
        progress=end

        """
        var parser = try FFmpegProgressParser(
            totalDurationMicroseconds: 4_000_000
        )
        var snapshots: [TranscodeProgress] = []

        for byte in Data(text.utf8) {
            snapshots += try parser.consume(Data([byte]))
        }
        snapshots += try parser.finish()

        let snapshot = try #require(snapshots.first)
        #expect(snapshots.count == 1)
        #expect(snapshot.processedMicroseconds == 2_000_000)
        #expect(snapshot.totalMicroseconds == 4_000_000)
        #expect(snapshot.fractionCompleted == 0.5)
        #expect(snapshot.frame == 61)
        #expect(snapshot.framesPerSecond == 29.97)
        #expect(snapshot.speed == 1.25)
        #expect(snapshot.outputByteCount == 1_048_576)
        #expect(snapshot.duplicatedFrames == 2)
        #expect(snapshot.droppedFrames == 1)
        #expect(parser.receivedEnd)
    }

    @Test("Multiple records in one chunk publish at their terminators")
    func multipleRecords() throws {
        let data = Data(
            """
            out_time_us=250000
            frame=8
            progress=continue
            out_time_us=1000000
            frame=30
            progress=end

            """.utf8
        )
        var parser = try FFmpegProgressParser(
            totalDurationMicroseconds: nil
        )

        let snapshots = try parser.consume(data) + parser.finish()

        #expect(snapshots.map(\.processedMicroseconds) == [250_000, 1_000_000])
        #expect(snapshots.map(\.frame) == [8, 30])
        #expect(snapshots.allSatisfy { $0.fractionCompleted == nil })
    }

    @Test("CRLF and unavailable optional metrics are accepted")
    func carriageReturnsAndUnavailableMetrics() throws {
        let data = Data(
            "out_time_us=N/A\r\nout_time_ms=1250000\r\n"
                .appending("frame=N/A\r\nfps=n/a\r\nspeed=N/A\r\n")
                .appending("total_size=N/A\r\ndup_frames=N/A\r\n")
                .appending("drop_frames=N/A\r\nprogress=end\r\n")
                .utf8
        )
        var parser = try FFmpegProgressParser(
            totalDurationMicroseconds: 2_500_000
        )

        let snapshots = try parser.consume(data) + parser.finish()
        let snapshot = try #require(snapshots.first)

        #expect(snapshot.processedMicroseconds == 1_250_000)
        #expect(snapshot.fractionCompleted == 0.5)
        #expect(snapshot.frame == nil)
        #expect(snapshot.framesPerSecond == nil)
        #expect(snapshot.speed == nil)
        #expect(snapshot.outputByteCount == nil)
        #expect(snapshot.duplicatedFrames == nil)
        #expect(snapshot.droppedFrames == nil)
    }

    @Test("Space-padded numeric fields emitted by FFmpeg are accepted")
    func paddedNumericMetrics() throws {
        let data = Data(
            "frame= 95 \n"
                .appending("fps= 29.97\n")
                .appending("total_size= 262192 \n")
                .appending("out_time_us= 3133333\n")
                .appending("speed= 4.1x\n")
                .appending("progress=end\n")
                .utf8
        )
        var parser = try FFmpegProgressParser(
            totalDurationMicroseconds: 6_266_666
        )

        let snapshots = try parser.consume(data) + parser.finish()
        let snapshot = try #require(snapshots.first)

        #expect(snapshot.processedMicroseconds == 3_133_333)
        #expect(snapshot.frame == 95)
        #expect(snapshot.framesPerSecond == 29.97)
        #expect(snapshot.speed == 4.1)
        #expect(snapshot.outputByteCount == 262_192)
    }

    @Test("Formatted out_time is the last-resort time fallback")
    func formattedTimeFallback() throws {
        let data = Data(
            """
            out_time_us=N/A
            out_time_ms=N/A
            out_time=01:02:03.250001
            progress=end
            """.utf8
        )
        var parser = try FFmpegProgressParser(
            totalDurationMicroseconds: 4_000_000_000
        )

        let snapshots = try parser.consume(data) + parser.finish()

        #expect(snapshots.first?.processedMicroseconds == 3_723_250_001)
    }

    @Test("out_time_us has priority over compatibility fallbacks")
    func primaryTimeWins() throws {
        let data = Data(
            """
            out_time_us=5
            out_time_ms=9
            out_time=00:00:00.000011
            progress=end
            """.utf8
        )
        var parser = try FFmpegProgressParser(
            totalDurationMicroseconds: 10
        )

        let snapshots = try parser.consume(data) + parser.finish()

        #expect(snapshots.first?.processedMicroseconds == 5)
        #expect(snapshots.first?.fractionCompleted == 0.5)
    }

    @Test("All-N/A FFmpeg heartbeat records are skipped without failing")
    func unavailableTimeHeartbeat() throws {
        let data = Data(
            """
            out_time_us=859138
            progress=continue
            out_time_us=N/A
            out_time_ms=N/A
            out_time=N/A
            progress=continue
            out_time_us=933333
            progress=end

            """.utf8
        )
        var parser = try FFmpegProgressParser(
            totalDurationMicroseconds: 933_333
        )

        let snapshots = try parser.consume(data) + parser.finish()

        #expect(
            snapshots.map(\.processedMicroseconds)
                == [859_138, 933_333]
        )
        #expect(parser.receivedEnd)
    }

    @Test("Unknown keys and values containing equals signs are ignored")
    func unknownKeys() throws {
        let data = Data(
            "unknown=a=b=c\nout_time_us=0\nprogress=end\n".utf8
        )
        var parser = try FFmpegProgressParser(
            totalDurationMicroseconds: 0
        )

        let snapshots = try parser.consume(data) + parser.finish()

        #expect(snapshots.count == 1)
        #expect(snapshots.first?.fractionCompleted == nil)
    }

    @Test("Every corrupt present known metric is rejected")
    func corruptKnownMetrics() throws {
        let cases: [(line: String, expectedKey: String)] = [
            ("out_time_us=-1", "out_time_us"),
            ("out_time_ms=one", "out_time_ms"),
            ("out_time=00:60:00.000000", "out_time"),
            ("frame=1.5", "frame"),
            ("fps=NaN", "fps"),
            ("speed=1.2", "speed"),
            ("speed=N/Ax", "speed"),
            ("total_size=-1", "total_size"),
            ("dup_frames=two", "dup_frames"),
            ("drop_frames=-2", "drop_frames"),
        ]

        for testCase in cases {
            var parser = try FFmpegProgressParser(
                totalDurationMicroseconds: nil
            )
            do {
                _ = try parser.consume(Data("\(testCase.line)\n".utf8))
                Issue.record("Expected \(testCase.line) to fail")
            } catch let error as FFmpegProgressParsingError {
                #expect(
                    error == .invalidValue(key: testCase.expectedKey),
                    "Unexpected error for \(testCase.line): \(error)"
                )
            }
        }
    }

    @Test("Invalid progress markers and missing processed time are rejected")
    func invalidTerminators() throws {
        var invalidMarkerParser = try FFmpegProgressParser(
            totalDurationMicroseconds: nil
        )
        #expect(
            throws: FFmpegProgressParsingError.invalidValue(key: "progress")
        ) {
            try invalidMarkerParser.consume(
                Data("out_time_us=1\nprogress=waiting\n".utf8)
            )
        }

        var missingTimeParser = try FFmpegProgressParser(
            totalDurationMicroseconds: nil
        )
        #expect(throws: FFmpegProgressParsingError.missingProcessedTime) {
            try missingTimeParser.consume(
                Data("frame=1\nprogress=end\n".utf8)
            )
        }
    }

    @Test("Duplicate known metrics and malformed lines are rejected")
    func duplicateAndMalformedLines() throws {
        var duplicateParser = try FFmpegProgressParser(
            totalDurationMicroseconds: nil
        )
        #expect(
            throws: FFmpegProgressParsingError.duplicateValue(key: "frame")
        ) {
            try duplicateParser.consume(Data("frame=1\nframe=2\n".utf8))
        }

        var malformedParser = try FFmpegProgressParser(
            totalDurationMicroseconds: nil
        )
        #expect(throws: FFmpegProgressParsingError.malformedLine) {
            try malformedParser.consume(Data("not-a-pair\n".utf8))
        }
    }

    @Test("Invalid UTF-8 and overlong pending lines are bounded errors")
    func invalidBytesAndBufferBound() throws {
        var utf8Parser = try FFmpegProgressParser(
            totalDurationMicroseconds: nil
        )
        #expect(throws: FFmpegProgressParsingError.invalidUTF8) {
            try utf8Parser.consume(Data([0x66, 0x6f, 0x6f, 0x3d, 0xff, 0x0a]))
        }

        var boundedParser = try FFmpegProgressParser(
            totalDurationMicroseconds: nil,
            maximumPendingByteCount: 4
        )
        #expect(
            throws: FFmpegProgressParsingError
                .pendingByteLimitExceeded(maximumByteCount: 4)
        ) {
            try boundedParser.consume(Data("abcde".utf8))
        }
    }

    @Test("finish flushes a final line without a newline")
    func finishFlushesFinalLine() throws {
        var parser = try FFmpegProgressParser(
            totalDurationMicroseconds: 2
        )
        let streamed = try parser.consume(Data("out_time_us=1\n".utf8))
        let flushed = try parser.consume(Data("progress=".utf8))
            + parser.consume(Data("end".utf8))
            + parser.finish()

        #expect(streamed.isEmpty)
        #expect(flushed.count == 1)
        #expect(flushed.first?.fractionCompleted == 0.5)
    }

    @Test("EOF requires both a complete record and an end marker")
    func deterministicEOFValidation() throws {
        var incompleteParser = try FFmpegProgressParser(
            totalDurationMicroseconds: nil
        )
        _ = try incompleteParser.consume(Data("out_time_us=1\n".utf8))
        #expect(throws: FFmpegProgressParsingError.incompleteRecord) {
            try incompleteParser.finish()
        }

        var missingEndParser = try FFmpegProgressParser(
            totalDurationMicroseconds: nil
        )
        _ = try missingEndParser.consume(
            Data("out_time_us=1\nprogress=continue\n".utf8)
        )
        #expect(throws: FFmpegProgressParsingError.missingEndMarker) {
            try missingEndParser.finish()
        }
    }

    @Test("End accepts trailing newlines but no further data")
    func dataAfterEnd() throws {
        var parser = try FFmpegProgressParser(
            totalDurationMicroseconds: nil
        )
        _ = try parser.consume(
            Data("out_time_us=1\nprogress=end\n\r\n".utf8)
        )

        #expect(throws: FFmpegProgressParsingError.dataAfterEnd) {
            try parser.consume(Data("frame=2\n".utf8))
        }
    }

    @Test("A finished parser cannot be consumed or finished twice")
    func parserLifecycle() throws {
        var parser = try FFmpegProgressParser(
            totalDurationMicroseconds: nil
        )
        _ = try parser.consume(Data("out_time_us=0\nprogress=end\n".utf8))
        _ = try parser.finish()

        #expect(throws: FFmpegProgressParsingError.parserFinished) {
            try parser.consume(Data())
        }
        #expect(throws: FFmpegProgressParsingError.parserFinished) {
            try parser.finish()
        }
    }

    @Test("Invalid parser configuration is rejected")
    func invalidConfiguration() {
        #expect(throws: FFmpegProgressParsingError.invalidTotalDuration) {
            try FFmpegProgressParser(totalDurationMicroseconds: -1)
        }
        #expect(throws: FFmpegProgressParsingError.invalidPendingByteLimit) {
            try FFmpegProgressParser(
                totalDurationMicroseconds: nil,
                maximumPendingByteCount: 0
            )
        }
    }
}
