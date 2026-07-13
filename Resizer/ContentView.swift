import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    private enum ImportTarget {
        case input
        case outputDirectory

        var allowedContentTypes: [UTType] {
            switch self {
            case .input:
                [.mpeg4Movie, .quickTimeMovie]
            case .outputDirectory:
                [.folder]
            }
        }
    }

    @StateObject private var model = ToolchainSpikeModel()
    @State private var importTarget: ImportTarget = .input
    @State private var isImporterPresented = false

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 6) {
                Label("FFmpeg Toolchain Spike", systemImage: "wrench.and.screwdriver")
                    .font(.title2.weight(.semibold))
                Text("Temporary stage 2 diagnostic for H.264/AAC MOV or MP4 files.")
                    .foregroundStyle(.secondary)
            }

            GroupBox("Selections") {
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 14) {
                    GridRow {
                        Text("Input video")
                            .foregroundStyle(.secondary)
                        Text(model.inputURL?.lastPathComponent ?? "Not selected")
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Button("Choose File…") {
                            importTarget = .input
                            isImporterPresented = true
                        }
                    }

                    GridRow {
                        Text("Output folder")
                            .foregroundStyle(.secondary)
                        Text(model.outputDirectoryURL?.path(percentEncoded: false) ?? "Not selected")
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Button("Choose Folder…") {
                            importTarget = .outputDirectory
                            isImporterPresented = true
                        }
                    }
                }
                .padding(.vertical, 4)
            }

            statusView

            HStack {
                Spacer()
                Button("Run Probe + 3 Second Encode") {
                    model.run()
                }
                .buttonStyle(.borderedProminent)
                .disabled(!model.canRun)
            }
        }
        .padding(24)
        .frame(minWidth: 640, minHeight: 430)
        .fileImporter(
            isPresented: $isImporterPresented,
            allowedContentTypes: importTarget.allowedContentTypes,
            allowsMultipleSelection: false
        ) { result in
            handleSelection(result)
        }
    }

    @ViewBuilder
    private var statusView: some View {
        switch model.state {
        case .idle:
            ContentUnavailableView(
                "Ready for a diagnostic run",
                systemImage: "video",
                description: Text(
                    "The source remains unchanged. A unique temporary MP4 is validated before it is renamed."
                )
            )
        case .unavailable(let message):
            statusPanel(title: "Toolchain unavailable", message: message, color: .red)
        case .running:
            HStack(spacing: 12) {
                ProgressView()
                    .controlSize(.small)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Running bundled tools…")
                        .font(.headline)
                    Text("Probing, encoding, and validating the temporary output.")
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
        case .succeeded(let report):
            let size = ByteCountFormatter.string(
                fromByteCount: Int64(report.outputByteCount),
                countStyle: .file
            )
            statusPanel(
                title: "Diagnostic encode succeeded",
                message: "Input video: \(report.inputVideoCodec)\nOutput: \(report.outputURL.path(percentEncoded: false))\nSize: \(size)",
                color: .green
            )
        case .failed(let message):
            statusPanel(title: "Diagnostic run failed", message: message, color: .red)
        }
    }

    private func statusPanel(
        title: String,
        message: String,
        color: Color
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.headline)
                .foregroundStyle(color)
            Text(message)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
    }

    private func handleSelection(
        _ result: Result<[URL], any Error>
    ) {
        switch result {
        case .success(let urls):
            if let url = urls.first {
                switch importTarget {
                case .input:
                    model.selectInput(url)
                case .outputDirectory:
                    model.selectOutputDirectory(url)
                }
            }
        case .failure(let error):
            model.reportSelectionError(error)
        }
    }
}

#Preview {
    ContentView()
}
