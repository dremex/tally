import ServiceManagement
import SwiftUI

struct SettingsView: View {
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Toggle("Launch at login", isOn: $launchAtLogin)
                .onChange(of: launchAtLogin) { _, enabled in setLaunchAtLogin(enabled) }

            if let error {
                Text(error).font(.caption).foregroundStyle(Theme.red)
            }

            Divider()

            VStack(alignment: .leading, spacing: 4) {
                Text("About").font(.headline)
                Text(
                    "Tally samples interface counters every second and per-app usage (via nettop) every 5 seconds while running. History is stored locally in SQLite for ~30 days; daily/monthly totals are derived from it."
                )
                .font(.caption).foregroundStyle(.secondary)
                Text("DB: ~/Library/Application Support/Tally/tally.sqlite")
                    .font(.caption2).foregroundStyle(.tertiary).textSelection(.enabled)
            }

            Spacer()

            Button(role: .destructive) {
                NSApplication.shared.terminate(nil)
            } label: {
                Label("Quit Tally", systemImage: "power").frame(maxWidth: .infinity)
            }
        }
        .padding()
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            error = nil
        } catch {
            self.error = "Couldn't update login item: \(error.localizedDescription)"
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }
}
