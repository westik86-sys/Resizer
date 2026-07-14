import SwiftUI

struct SettingsView: View {
    @AppStorage(CompressionPreferences.outputFilenameSuffixKey)
    private var storedFilenameSuffix = CompressionPreferences.defaultOutputFilenameSuffix

    @AppStorage(CompressionPreferences.outputConflictPolicyKey)
    private var storedConflictPolicy = CompressionPreferences.defaultOutputConflictPolicy.rawValue

    @State private var filenameSuffixDraft = CompressionPreferences.defaultOutputFilenameSuffix

    var body: some View {
        Form {
            Section("Output files") {
                LabeledContent("Filename suffix") {
                    TextField("Filename suffix", text: $filenameSuffixDraft)
                        .frame(width: 210)
                        .multilineTextAlignment(.trailing)
                        .accessibilityIdentifier("settings-output-filename-suffix")
                        .onSubmit(normalizeFilenameSuffixDraft)
                }

                filenameSuffixGuidance

                Picker("If a file already exists", selection: $storedConflictPolicy) {
                    ForEach(OutputConflictPreference.allCases) { policy in
                        Text(policy.title).tag(policy.rawValue)
                    }
                }
                .pickerStyle(.radioGroup)
                .accessibilityIdentifier("settings-output-conflict-policy")

                Text(conflictPolicy.helpText)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Label(
                    "Existing files and the original video are never overwritten.",
                    systemImage: "lock.shield"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Section("About") {
                LabeledContent("Resizer", value: appVersionDescription)
                LabeledContent(
                    "Bundled FFmpeg",
                    value: CompressionPreferences.bundledFFmpegVersion
                )
                LabeledContent(
                    "License profile",
                    value: CompressionPreferences.bundledFFmpegLicenseProfile
                )

                Text(String(
                    localized: "FFmpeg is bundled with Resizer and built using an LGPL-only profile. GPL and nonfree components, including libx264 and libx265, are not included."
                ))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("settings-ffmpeg-license-disclosure")

                legalDisclosure(
                    title: String(localized: "Third-party notices"),
                    text: BundledLegalDocuments.thirdPartyNotices,
                    identifier: "settings-third-party-notices"
                )
                legalDisclosure(
                    title: String(localized: "GNU LGPL 2.1 license"),
                    text: BundledLegalDocuments.lgpl21,
                    identifier: "settings-lgpl-21"
                )
                legalDisclosure(
                    title: String(localized: "GNU LGPL 3 license"),
                    text: BundledLegalDocuments.lgpl3,
                    identifier: "settings-lgpl-3"
                )
            }
        }
        .formStyle(.grouped)
        .frame(width: 540, height: 560)
        .onAppear(perform: restoreValidatedPreferences)
        .onChange(of: filenameSuffixDraft) { _, newValue in
            persistFilenameSuffixIfValid(newValue)
        }
    }

    @ViewBuilder
    private var filenameSuffixGuidance: some View {
        switch CompressionPreferences.validateOutputFilenameSuffix(filenameSuffixDraft) {
        case let .valid(normalizedValue):
            Text("Example: Video\(normalizedValue).mp4")
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("settings-output-filename-example")
        case let .invalid(reason):
            Label(reason.message, systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.red)
                .accessibilityIdentifier("settings-output-filename-error")
        }
    }

    private var conflictPolicy: OutputConflictPreference {
        OutputConflictPreference(rawValue: storedConflictPolicy)
            ?? CompressionPreferences.defaultOutputConflictPolicy
    }

    private func legalDisclosure(
        title: String,
        text: String,
        identifier: String
    ) -> some View {
        DisclosureGroup(title) {
            ScrollView {
                Text(text)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 6)
            }
            .frame(height: 130)
        }
        .accessibilityIdentifier(identifier)
    }

    private var appVersionDescription: String {
        let version = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleShortVersionString"
        ) as? String
        let build = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleVersion"
        ) as? String

        return switch (version, build) {
        case let (version?, build?):
            String(localized: "Version \(version) (\(build))")
        case let (version?, nil):
            String(localized: "Version \(version)")
        case let (nil, build?):
            String(localized: "Build \(build)")
        case (nil, nil):
            String(localized: "Development build")
        }
    }

    private func restoreValidatedPreferences() {
        switch CompressionPreferences.validateOutputFilenameSuffix(storedFilenameSuffix) {
        case let .valid(normalizedValue):
            storedFilenameSuffix = normalizedValue
            filenameSuffixDraft = normalizedValue
        case .invalid:
            storedFilenameSuffix = CompressionPreferences.defaultOutputFilenameSuffix
            filenameSuffixDraft = CompressionPreferences.defaultOutputFilenameSuffix
        }

        if OutputConflictPreference(rawValue: storedConflictPolicy) == nil {
            storedConflictPolicy = CompressionPreferences.defaultOutputConflictPolicy.rawValue
        }
    }

    private func persistFilenameSuffixIfValid(_ candidate: String) {
        guard case let .valid(normalizedValue) =
            CompressionPreferences.validateOutputFilenameSuffix(candidate) else {
            return
        }

        storedFilenameSuffix = normalizedValue
    }

    private func normalizeFilenameSuffixDraft() {
        guard case let .valid(normalizedValue) =
            CompressionPreferences.validateOutputFilenameSuffix(filenameSuffixDraft) else {
            return
        }

        filenameSuffixDraft = normalizedValue
    }
}

private enum BundledLegalDocuments {
    static let thirdPartyNotices = load(
        resource: "THIRD_PARTY_NOTICES",
        fileExtension: "md"
    )
    static let lgpl21 = load(
        resource: "COPYING.LGPLv2.1",
        fileExtension: "txt"
    )
    static let lgpl3 = load(
        resource: "COPYING.LGPLv3",
        fileExtension: "txt"
    )

    private static func load(
        resource: String,
        fileExtension: String
    ) -> String {
        guard let url = Bundle.main.url(
            forResource: resource,
            withExtension: fileExtension
        ), let text = try? String(contentsOf: url, encoding: .utf8) else {
            return String(localized: "Bundled legal document unavailable.")
        }
        return text
    }
}

#Preview {
    SettingsView()
}
