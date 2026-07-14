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

                Text(
                    "FFmpeg is bundled with Resizer and built using an LGPL-only profile. "
                    + "GPL and nonfree components, including libx264 and libx265, are not included."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("settings-ffmpeg-license-disclosure")
            }
        }
        .formStyle(.grouped)
        .frame(width: 500, height: 420)
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

    private var appVersionDescription: String {
        let version = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleShortVersionString"
        ) as? String
        let build = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleVersion"
        ) as? String

        return switch (version, build) {
        case let (version?, build?):
            "Version \(version) (\(build))"
        case let (version?, nil):
            "Version \(version)"
        case let (nil, build?):
            "Build \(build)"
        case (nil, nil):
            "Development build"
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

#Preview {
    SettingsView()
}
