import SwiftUI

@main
struct ResizerApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }

        Settings {
            SettingsView()
        }
    }
}
