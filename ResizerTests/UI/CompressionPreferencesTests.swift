import Testing
@testable import Resizer

@Suite("Compression preferences")
struct CompressionPreferencesTests {
    @Test("The default suffix is safe and normalized")
    func defaultSuffix() {
        #expect(
            CompressionPreferences.validateOutputFilenameSuffix(
                CompressionPreferences.defaultOutputFilenameSuffix
            ) == .valid(
                normalizedValue: CompressionPreferences
                    .defaultOutputFilenameSuffix
            )
        )
    }

    @Test("Surrounding whitespace is removed before persistence")
    func normalizedSuffix() {
        #expect(
            CompressionPreferences.validateOutputFilenameSuffix(
                "  -small copy  \n"
            ) == .valid(normalizedValue: "-small copy")
        )
    }

    @Test(
        "Empty and reserved path components are rejected",
        arguments: ["", "   ", ".", ".."]
    )
    func invalidComponents(candidate: String) {
        let result = CompressionPreferences.validateOutputFilenameSuffix(
            candidate
        )
        switch result {
        case .invalid:
            break
        case .valid:
            Issue.record("Expected an invalid filename suffix")
        }
    }

    @Test("The suffix length limit is exact")
    func suffixLengthLimit() {
        let maximum = CompressionPreferences
            .maximumOutputFilenameSuffixLength
        let accepted = String(repeating: "a", count: maximum)
        let rejected = String(repeating: "a", count: maximum + 1)

        #expect(
            CompressionPreferences.validateOutputFilenameSuffix(accepted)
                == .valid(normalizedValue: accepted)
        )
        #expect(
            CompressionPreferences.validateOutputFilenameSuffix(rejected)
                == .invalid(.tooLong(maximumLength: maximum))
        )
    }

    @Test(
        "Separators and control characters are rejected",
        arguments: ["bad/name", "bad:name", "bad\u{0}name", "bad\tname"]
    )
    func unsupportedCharacters(candidate: String) {
        #expect(
            CompressionPreferences.validateOutputFilenameSuffix(candidate)
                == .invalid(.unsupportedCharacter)
        )
    }

    @Test("Every stored conflict preference maps to its typed policy")
    func conflictPolicies() {
        #expect(
            OutputConflictPreference.appendNumericSuffix.domainValue
                == .appendNumericSuffix
        )
        #expect(OutputConflictPreference.fail.domainValue == .fail)
        #expect(
            CompressionPreferences.defaultOutputConflictPolicy
                == .appendNumericSuffix
        )
    }
}
