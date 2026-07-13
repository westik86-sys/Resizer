import SwiftUI

struct SettingsView: View {
    var body: some View {
        Form {
            Text("Settings will be added in a later milestone.")
                .foregroundStyle(.secondary)
        }
        .padding()
        .frame(width: 420)
    }
}

#Preview {
    SettingsView()
}
