import Foundation
import Testing
@testable import Resizer

@Suite("Domain value validation")
struct DomainValueTests {
    @Test("Video quality accepts only finite normalized values")
    func videoQualityValidation() throws {
        #expect(try VideoQuality(0).value == 0)
        #expect(try VideoQuality(1).value == 1)
        #expect(throws: CompressionRecipeValidationError.invalidVideoQuality) {
            _ = try VideoQuality(-0.1)
        }
        #expect(throws: CompressionRecipeValidationError.invalidVideoQuality) {
            _ = try VideoQuality(.infinity)
        }
    }

    @Test("Rational frame rate preserves NTSC values")
    func rationalFrameRate() throws {
        let rate = try RationalFrameRate(numerator: 30_000, denominator: 1_001)
        #expect(abs(rate.doubleValue - 29.970_029_97) < 0.000_001)
        #expect(throws: MediaInfoValidationError.invalidFrameRate) {
            _ = try RationalFrameRate(numerator: 30, denominator: 0)
        }
        #expect(throws: MediaInfoValidationError.invalidFrameRate) {
            _ = try RationalFrameRate(numerator: 0, denominator: 1)
        }
    }

    @Test("Progress clamps fraction and supports unknown duration")
    func progressFraction() throws {
        let halfway = try TestFixtures.progress(processedMicroseconds: 5, totalMicroseconds: 10)
        let overrun = try TestFixtures.progress(processedMicroseconds: 12, totalMicroseconds: 10)
        let unknown = try TestFixtures.progress(processedMicroseconds: 5, totalMicroseconds: nil)

        #expect(halfway.fractionCompleted == 0.5)
        #expect(overrun.fractionCompleted == 1)
        #expect(unknown.fractionCompleted == nil)
        #expect(throws: TranscodeProgressValidationError.invalidMetric) {
            _ = try TranscodeProgress(
                processedMicroseconds: -1,
                totalMicroseconds: 10
            )
        }
    }

    @Test("Output policy is file-only and has no overwrite option")
    func outputPolicyValidation() throws {
        let policy = try OutputPolicy(
            directoryURL: URL(fileURLWithPath: "/tmp/output", isDirectory: true)
        )
        #expect(policy.conflictPolicy == .appendNumericSuffix)
        #expect(throws: OutputPolicyValidationError.invalidPolicy) {
            _ = try OutputPolicy(directoryURL: URL(string: "https://example.com")!)
        }
        #expect(throws: OutputPolicyValidationError.invalidPolicy) {
            _ = try OutputPolicy(
                directoryURL: URL(fileURLWithPath: "/tmp"),
                filenameSuffix: "../unsafe"
            )
        }
    }

    @Test("Recipe limits stay within the bounded MVP controls")
    func recipeLimits() {
        #expect(throws: CompressionRecipeValidationError.invalidResolutionLimit) {
            _ = try ResolutionLimit(
                maximumLongEdge: 720,
                maximumShortEdge: 1_280
            )
        }
        #expect(throws: CompressionRecipeValidationError.invalidFrameRateLimit) {
            _ = try FrameRateLimit(framesPerSecond: 60.1)
        }
    }

    @Test("Media metadata rejects invalid metrics and duplicate streams")
    func mediaInfoValidation() throws {
        let video = try VideoStreamInfo(
            index: 0,
            codecName: "h264",
            encodedWidth: 1_920,
            encodedHeight: 1_080,
            frameRate: try RationalFrameRate(numerator: 30, denominator: 1),
            rotationDegrees: 0,
            pixelFormat: "yuv420p",
            bitDepth: 8,
            dynamicRange: .sdr,
            disposition: StreamDisposition(
                isDefault: true,
                isForced: false,
                isAttachedPicture: false
            )
        )

        #expect(throws: MediaInfoValidationError.invalidContainerMetric) {
            _ = try MediaInfo(
                formatNames: ["mov"],
                durationMicroseconds: -1,
                byteCount: 10,
                bitRate: nil,
                streams: [.video(video)]
            )
        }
        #expect(throws: MediaInfoValidationError.duplicateStreamIndex) {
            _ = try MediaInfo(
                formatNames: ["mov"],
                durationMicroseconds: 1,
                byteCount: 10,
                bitRate: nil,
                streams: [.video(video), .video(video)]
            )
        }
        #expect(throws: MediaInfoValidationError.invalidStreamMetric) {
            _ = try AudioStreamInfo(
                index: -1,
                codecName: "aac",
                sampleRate: 48_000,
                channelCount: 2,
                channelLayout: "stereo",
                bitRate: 128_000,
                languageCode: nil
            )
        }
    }

    @Test("Completed results require a non-empty local output")
    func resultValidation() {
        #expect(throws: CompressionResultValidationError.invalidResult) {
            _ = try CompressionResult(
                outputURL: URL(string: "https://example.com/output.mp4")!,
                outputByteCount: 1,
                elapsed: .seconds(1)
            )
        }
        #expect(throws: CompressionResultValidationError.invalidResult) {
            _ = try CompressionResult(
                outputURL: URL(fileURLWithPath: "/tmp/output.mp4"),
                outputByteCount: 0,
                elapsed: .seconds(1)
            )
        }
        #expect(throws: CompressionResultValidationError.invalidResult) {
            _ = try CompressionResult(
                outputURL: URL(fileURLWithPath: "/tmp/output.mp4"),
                outputByteCount: 1,
                elapsed: .seconds(-1)
            )
        }
    }

    @Test("Failure diagnostics cannot exceed their declared bound")
    func failureDiagnosticValidation() throws {
        let diagnostic = try BoundedDiagnostic(
            text: "tail",
            utf8ByteLimit: 4,
            wasTruncated: true
        )

        #expect(diagnostic.wasTruncated)
        #expect(throws: TranscodeFailureValidationError.invalidDiagnostic) {
            _ = try BoundedDiagnostic(
                text: "too long",
                utf8ByteLimit: 3,
                wasTruncated: false
            )
        }
    }
}
