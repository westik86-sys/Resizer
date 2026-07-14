import Foundation
import Testing
@testable import Resizer

@Suite("Failure presentation")
struct FailurePresentationTests {
    @Test("Every typed failure has actionable primary copy")
    func allReasonsHaveCopy() {
        let reasons: [FailureReason] = [
            .serviceUnavailable,
            .invalidMedia,
            .inputUnavailable,
            .outputUnavailable,
            .outputConflict,
            .unsupportedOutputFileSystem,
            .insufficientStorage,
            .processFailed(exitCode: 41),
            .fileSystem,
            .unknown,
        ]

        for reason in reasons {
            let presentation = CompressionFailurePresentation.transcode(
                TranscodeFailure(
                    stage: .encode,
                    reason: reason,
                    diagnosticTail: nil
                )
            )
            #expect(!presentation.title.isEmpty)
            #expect(!presentation.detail.isEmpty)
        }
    }

    @Test("Technical process status stays out of the primary error message")
    func processExitCodeIsDiagnosticOnly() {
        let presentation = CompressionFailurePresentation.transcode(
            TranscodeFailure(
                stage: .encode,
                reason: .processFailed(exitCode: 98_765),
                diagnosticTail: nil
            )
        )

        #expect(!presentation.title.contains("98765"))
        #expect(!presentation.detail.contains("98765"))
        #expect(
            presentation.detail == String(
                localized: "The bundled video tool stopped unexpectedly. Retry or open Diagnostics for technical details."
            )
        )
    }

    @Test("Workflow stages identify the failed operation")
    func stageTitles() {
        let stages: [FailureStage] = [
            .probe, .preflight, .encode, .validate, .commit,
        ]
        let titles = Set(stages.map { stage in
            CompressionFailurePresentation.transcode(
                TranscodeFailure(
                    stage: stage,
                    reason: .unknown,
                    diagnosticTail: nil
                )
            ).title
        })

        #expect(titles.count == stages.count)
        #expect(!CompressionFailurePresentation.cancelled.detail.isEmpty)
    }
}
