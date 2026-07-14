import SwiftUI

@main
struct ResizerApp: App {
    @NSApplicationDelegateAdaptor(ApplicationLifecycleDelegate.self)
    private var lifecycleDelegate

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
                .onAppear {
                    lifecycleDelegate.installShutdownAction {
                        await composition.compressionFeatureModel.shutdown()
                    }
                }
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
            String(localized: "Resizer couldn’t start"),
            systemImage: "exclamationmark.triangle",
            description: Text(
                String(
                    localized: "The bundled video tools are unavailable or invalid. Reinstall Resizer and try again."
                )
            )
        )
        .accessibilityIdentifier("startup-failure")
        .frame(minWidth: 560, minHeight: 360)
        .padding(32)
    }
}
