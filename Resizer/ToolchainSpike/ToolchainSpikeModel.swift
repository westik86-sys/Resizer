import Combine
import SwiftUI

nonisolated enum ToolchainSpikeViewState: Sendable {
    case idle
    case unavailable(String)
    case running
    case succeeded(ToolchainSpikeReport)
    case failed(String)
}

@MainActor
final class ToolchainSpikeModel: ObservableObject {
    @Published private(set) var state: ToolchainSpikeViewState = .idle
    @Published private(set) var inputURL: URL?
    @Published private(set) var outputDirectoryURL: URL?

    private let service: ToolchainSpikeService?
    private var runTask: Task<Void, Never>?

    init(bundle: Bundle = .main) {
        guard let ffmpegURL = bundle.url(
            forAuxiliaryExecutable: "ffmpeg"
        ), let ffprobeURL = bundle.url(
            forAuxiliaryExecutable: "ffprobe"
        ) else {
            service = nil
            state = .unavailable("Bundled ffmpeg or ffprobe is missing.")
            return
        }

        let fileManager = FileManager.default
        guard fileManager.isExecutableFile(atPath: ffmpegURL.path),
              fileManager.isExecutableFile(atPath: ffprobeURL.path) else {
            service = nil
            state = .unavailable(
                "Bundled ffmpeg or ffprobe is not executable."
            )
            return
        }

        service = ToolchainSpikeService(
            ffmpegURL: ffmpegURL,
            ffprobeURL: ffprobeURL,
            processRunner: SpikeProcessRunner()
        )
    }

    var canRun: Bool {
        service != nil
            && inputURL != nil
            && outputDirectoryURL != nil
            && runTask == nil
    }

    func selectInput(_ url: URL) {
        guard runTask == nil else { return }
        inputURL = url
        resetTransientState()
    }

    func selectOutputDirectory(_ url: URL) {
        guard runTask == nil else { return }
        outputDirectoryURL = url
        resetTransientState()
    }

    func reportSelectionError(_ error: any Error) {
        guard runTask == nil else { return }
        state = .failed(error.localizedDescription)
    }

    func run() {
        guard runTask == nil,
              let service,
              let inputURL,
              let outputDirectoryURL else {
            return
        }

        state = .running

        runTask = Task { [weak self] in
            defer { self?.runTask = nil }

            do {
                let report = try await service.run(
                    inputURL: inputURL,
                    outputDirectoryURL: outputDirectoryURL
                )
                self?.state = .succeeded(report)
            } catch let failure as ToolchainSpikeFailure {
                self?.state = .failed(failure.message)
            } catch {
                self?.state = .failed(error.localizedDescription)
            }
        }
    }

    private func resetTransientState() {
        switch state {
        case .failed, .succeeded:
            state = .idle
        case .idle, .unavailable, .running:
            break
        }
    }
}
