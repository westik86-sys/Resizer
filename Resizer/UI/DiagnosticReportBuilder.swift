import Foundation

nonisolated struct DiagnosticReportContext: Sendable, Equatable {
    let applicationVersion: String
    let ffmpegVersion: String
    let ffmpegLicenseProfile: String

    static func current(bundle: Bundle = .main) -> DiagnosticReportContext {
        let version = bundle.object(
            forInfoDictionaryKey: "CFBundleShortVersionString"
        ) as? String
        let build = bundle.object(
            forInfoDictionaryKey: "CFBundleVersion"
        ) as? String
        let applicationVersion = switch (version, build) {
        case let (version?, build?):
            "\(version) (\(build))"
        case let (version?, nil):
            version
        case let (nil, build?):
            build
        case (nil, nil):
            String(localized: "Development build")
        }

        return DiagnosticReportContext(
            applicationVersion: applicationVersion,
            ffmpegVersion: CompressionPreferences.bundledFFmpegVersion,
            ffmpegLicenseProfile:
                CompressionPreferences.bundledFFmpegLicenseProfile
        )
    }
}

/// Produces a bounded support report without exposing selected paths or media
/// filenames. Exit status is intentionally confined to this disclosure; the
/// primary error presentation remains actionable and non-technical.
nonisolated enum DiagnosticReportBuilder {
    static func make(
        failure: TranscodeFailure,
        inputURL: URL,
        outputPolicy: OutputPolicy?,
        jobID: CompressionJob.ID,
        context: DiagnosticReportContext = .current()
    ) -> String {
        var lines = [
            String(localized: "Resizer diagnostic report"),
            String(
                localized: "Application version: \(context.applicationVersion)"
            ),
            String(localized: "FFmpeg version: \(context.ffmpegVersion)"),
            String(
                localized: "FFmpeg license profile: \(context.ffmpegLicenseProfile)"
            ),
            String(localized: "Failure stage: \(stageName(failure.stage))"),
            String(localized: "Failure reason: \(reasonName(failure.reason))"),
        ]

        if case .processFailed(let exitCode) = failure.reason {
            if let exitCode {
                lines.append(String(localized: "Exit code: \(exitCode)"))
            } else {
                lines.append(String(localized: "Exit code: unavailable"))
            }
        }

        let wasTruncated = failure.diagnosticTail?.wasTruncated == true
        lines.append(
            wasTruncated
                ? String(localized: "Diagnostic tail truncated: Yes")
                : String(localized: "Diagnostic tail truncated: No")
        )
        lines.append(String(localized: "Paths and filenames are redacted."))

        guard let tail = failure.diagnosticTail, !tail.text.isEmpty else {
            lines.append("")
            lines.append(String(localized: "No diagnostic tail was captured."))
            return lines.joined(separator: "\n")
        }

        lines.append("")
        lines.append(String(localized: "Bounded diagnostic tail:"))
        lines.append(
            sanitize(
                tail.text,
                inputURL: inputURL,
                outputPolicy: outputPolicy,
                jobID: jobID,
                leadingFragmentWasTruncated: wasTruncated
            )
        )
        return lines.joined(separator: "\n")
    }

    private static func stageName(_ stage: FailureStage) -> String {
        switch stage {
        case .probe: "probe"
        case .preflight: "preflight"
        case .encode: "encode"
        case .validate: "validate"
        case .commit: "commit"
        }
    }

    private static func reasonName(_ reason: FailureReason) -> String {
        switch reason {
        case .serviceUnavailable: "service_unavailable"
        case .invalidMedia: "invalid_media"
        case .inputUnavailable: "input_unavailable"
        case .outputUnavailable: "output_unavailable"
        case .outputConflict: "output_conflict"
        case .unsupportedOutputFileSystem:
            "unsupported_output_file_system"
        case .insufficientStorage: "insufficient_storage"
        case .processFailed: "process_failed"
        case .fileSystem: "file_system"
        case .unknown: "unknown"
        }
    }

    private static func sanitize(
        _ text: String,
        inputURL: URL,
        outputPolicy: OutputPolicy?,
        jobID: CompressionJob.ID,
        leadingFragmentWasTruncated: Bool
    ) -> String {
        let normalizedInput = inputURL.standardizedFileURL
        let sourceStem = normalizedInput
            .deletingPathExtension()
            .lastPathComponent
        var sensitiveValues = Set([
            inputURL.path,
            inputURL.absoluteString,
            normalizedInput.path,
            normalizedInput.absoluteString,
            inputURL.lastPathComponent,
            sourceStem,
        ])

        if let outputPolicy {
            let directory = outputPolicy.directoryURL.standardizedFileURL
            sensitiveValues.formUnion([
                outputPolicy.directoryURL.path,
                outputPolicy.directoryURL.absoluteString,
                directory.path,
                directory.absoluteString,
                directory.lastPathComponent,
            ])

            let baseStem = sourceStem + outputPolicy.filenameSuffix
            sensitiveValues.insert("\(baseStem).mp4")
            sensitiveValues.insert(
                "\(baseStem).\(jobID.uuidString.lowercased()).partial.mp4"
            )
            for index in 2 ... 20 {
                sensitiveValues.insert("\(baseStem)-\(index).mp4")
                sensitiveValues.insert(
                    "\(baseStem)-\(index).\(jobID.uuidString.lowercased()).partial.mp4"
                )
            }
        }

        var sanitized: String
        if leadingFragmentWasTruncated {
            // The bounded tail can begin in the middle of an absolute path,
            // after its leading slash and known components were discarded.
            // No suffix matching can prove that fragment is safe, so redact
            // the incomplete first line before applying exact/path filters.
            if let firstLineEnd = text.firstIndex(of: "\n") {
                sanitized = "<redacted-truncated-prefix>"
                    + text[firstLineEnd...]
            } else {
                sanitized = "<redacted-truncated-prefix>"
            }
        } else {
            sanitized = text
        }
        for value in sensitiveValues
            .filter({ $0.count >= 2 })
            .sorted(by: { $0.utf8.count > $1.utf8.count }) {
            sanitized = sanitized.replacingOccurrences(
                of: value,
                with: "<redacted>"
            )
            if let decoded = value.removingPercentEncoding, decoded != value {
                sanitized = sanitized.replacingOccurrences(
                    of: decoded,
                    with: "<redacted>"
                )
            }
        }

        // Unknown absolute paths are also private. Redacting through the end
        // of their line is deliberately conservative and avoids attempting to
        // infer where a path containing spaces ends.
        let pattern = #"(?:file://|/)(?:Users|Volumes|Applications|Library|private|tmp|var)/[^\r\n\t]*"#
        guard let expression = try? NSRegularExpression(pattern: pattern) else {
            return sanitized
        }
        let range = NSRange(sanitized.startIndex..., in: sanitized)
        return expression.stringByReplacingMatches(
            in: sanitized,
            range: range,
            withTemplate: "<redacted-path>"
        )
    }
}
