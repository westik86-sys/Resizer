import Foundation
import Testing
@testable import Resizer

@Suite("Diagnostic report privacy")
struct DiagnosticReportBuilderTests {
    @Test("Report is structured and redacts selected paths and filenames")
    func structuredRedactedReport() throws {
        let jobID = UUID(uuidString: "7C45B7E0-E030-4E3C-A234-75552ABFB51A")!
        let inputURL = URL(
            fileURLWithPath: "/Users/alice/Private Clips/Семья 2026.mov"
        )
        let outputPolicy = try OutputPolicy(
            directoryURL: URL(
                fileURLWithPath: "/Volumes/Client Drive/Private Exports",
                isDirectory: true
            ),
            filenameSuffix: "-compressed"
        )
        let rawTail = """
        alice/Private Clips/Семья 2026.mov
        useful encoder detail
        input: /Users/alice/Private Clips/Семья 2026.mov
        output: /Volumes/Client Drive/Private Exports/Семья 2026-compressed.mp4
        collision output: Семья 2026-compressed-42.mp4
        temporary: Семья 2026-compressed.7c45b7e0-e030-4e3c-a234-75552abfb51a.partial.mp4
        unrelated absolute path: /private/var/folders/private-token/file
        """
        let diagnostic = try BoundedDiagnostic(
            text: rawTail,
            utf8ByteLimit: 2_048,
            wasTruncated: true
        )
        let failure = TranscodeFailure(
            stage: .encode,
            reason: .processFailed(exitCode: 17),
            diagnosticTail: diagnostic
        )

        let report = DiagnosticReportBuilder.make(
            failure: failure,
            inputURL: inputURL,
            outputPolicy: outputPolicy,
            jobID: jobID,
            context: DiagnosticReportContext(
                applicationVersion: "1.2 (42)",
                ffmpegVersion: "8.1.2",
                ffmpegLicenseProfile: "GPL 2.0-or-later"
            )
        )

        #expect(report.contains("1.2 (42)"))
        #expect(report.contains("8.1.2"))
        #expect(report.contains("GPL 2.0-or-later"))
        #expect(report.contains("encode"))
        #expect(report.contains("process_failed"))
        #expect(report.contains("17"))
        #expect(report.contains("useful encoder detail"))
        #expect(report.contains("<redacted"))
        #expect(!report.contains("alice"))
        #expect(!report.contains("Семья"))
        #expect(!report.contains("Private Clips"))
        #expect(!report.contains("Client Drive"))
        #expect(!report.contains("private-token"))
        #expect(report.contains("<redacted-truncated-prefix>"))
        #expect(report.utf8.count <= diagnostic.utf8ByteLimit + 2_048)
    }

    @Test("Report exists for a filesystem failure without a process tail")
    func reportWithoutTail() {
        let failure = TranscodeFailure(
            stage: .commit,
            reason: .outputUnavailable,
            diagnosticTail: nil,
            technicalCode: .processLaunchFailed
        )

        let report = DiagnosticReportBuilder.make(
            failure: failure,
            inputURL: URL(fileURLWithPath: "/tmp/private-name.mov"),
            outputPolicy: nil,
            jobID: UUID(),
            context: DiagnosticReportContext(
                applicationVersion: "dev",
                ffmpegVersion: "8.1.2",
                ffmpegLicenseProfile: "GPL 2.0-or-later"
            )
        )

        #expect(report.contains("commit"))
        #expect(report.contains("output_unavailable"))
        #expect(report.contains("Technical code: process_launch_failed"))
        #expect(!report.contains("private-name.mov"))
    }
}
