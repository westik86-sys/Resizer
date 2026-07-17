import Foundation

nonisolated enum CompressionPreferences {
    static let outputFilenameSuffixKey = "output.filenameSuffix"
    static let outputConflictPolicyKey = "output.conflictPolicy"

    static let defaultOutputFilenameSuffix = "-compressed"
    static let defaultOutputConflictPolicy = OutputConflictPreference.appendNumericSuffix
    static let maximumOutputFilenameSuffixLength = 40

    static let bundledFFmpegVersion = "8.1.2"
    static let bundledFFmpegLicenseProfile = "GPL 2.0-or-later"

    static func validateOutputFilenameSuffix(
        _ candidate: String
    ) -> OutputFilenameSuffixValidation {
        let normalizedValue = candidate.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !normalizedValue.isEmpty else {
            return .invalid(.empty)
        }
        guard normalizedValue != ".", normalizedValue != ".." else {
            return .invalid(.reservedName)
        }
        guard normalizedValue.count <= maximumOutputFilenameSuffixLength else {
            return .invalid(.tooLong(maximumLength: maximumOutputFilenameSuffixLength))
        }
        guard !normalizedValue.contains("/"),
              !normalizedValue.contains(":"),
              normalizedValue.rangeOfCharacter(from: .controlCharacters) == nil else {
            return .invalid(.unsupportedCharacter)
        }

        return .valid(normalizedValue: normalizedValue)
    }
}

nonisolated enum OutputConflictPreference: String, CaseIterable, Identifiable, Sendable {
    case appendNumericSuffix
    case fail

    var id: String { rawValue }

    var domainValue: OutputConflictPolicy {
        switch self {
        case .appendNumericSuffix:
            .appendNumericSuffix
        case .fail:
            .fail
        }
    }

    var title: String {
        switch self {
        case .appendNumericSuffix:
            String(localized: "Add a number")
        case .fail:
            String(localized: "Stop and show an error")
        }
    }

    var helpText: String {
        switch self {
        case .appendNumericSuffix:
            String(
                localized: "Creates Video-compressed-2.mp4, then advances the number as needed."
            )
        case .fail:
            String(
                localized: "Stops before encoding when the intended output name is already in use."
            )
        }
    }
}

nonisolated enum OutputFilenameSuffixValidation: Sendable, Equatable {
    case valid(normalizedValue: String)
    case invalid(OutputFilenameSuffixValidationError)
}

nonisolated enum OutputFilenameSuffixValidationError: Sendable, Equatable {
    case empty
    case reservedName
    case tooLong(maximumLength: Int)
    case unsupportedCharacter

    var message: String {
        switch self {
        case .empty:
            String(
                localized: "Enter a suffix so the output cannot reuse the original name."
            )
        case .reservedName:
            String(
                localized: "A single or double period cannot be used as the filename suffix."
            )
        case let .tooLong(maximumLength):
            String(
                localized: "Use no more than \(maximumLength) characters."
            )
        case .unsupportedCharacter:
            String(
                localized: "The suffix cannot contain slashes, colons, line breaks, or control characters."
            )
        }
    }
}
