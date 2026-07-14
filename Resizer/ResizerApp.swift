import SwiftUI

@main
struct ResizerApp: App {
    private let bootstrap: AppBootstrap

    init() {
        bootstrap = AppBootstrap.load()
    }

    var body: some Scene {
        WindowGroup {
            switch bootstrap {
            case .ready(let composition):
                CompressionRootView(
                    model: composition.compressionFeatureModel
                )
            case .failed:
                StartupFailureView()
            }
        }

        Settings {
            SettingsView()
        }
    }
}

@MainActor
private enum AppBootstrap {
    case ready(AppComposition)
    case failed

    static func load() -> AppBootstrap {
        do {
            return .ready(try AppComposition.production())
        } catch {
            // Startup errors may contain local bundle paths. The UI presents
            // an actionable, deliberately generic message instead.
            return .failed
        }
    }
}

private struct CompressionRootView: View {
    @StateObject private var model: CompressionFeatureModel

    init(model: CompressionFeatureModel) {
        _model = StateObject(wrappedValue: model)
    }

    var body: some View {
        ContentView(model: model)
    }
}

private struct StartupFailureView: View {
    var body: some View {
        ContentUnavailableView(
            "Resizer couldn’t start",
            systemImage: "exclamationmark.triangle",
            description: Text(
                "The bundled video tools are unavailable or invalid. Reinstall Resizer and try again."
            )
        )
        .accessibilityIdentifier("startup-failure")
        .frame(minWidth: 560, minHeight: 360)
        .padding(32)
    }
}
