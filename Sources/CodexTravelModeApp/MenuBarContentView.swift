import AppKit
import CodexTravelModeCore
import SwiftUI

struct MenuBarContentView: View {
    @ObservedObject var appState: TravelModeAppState
    let onQuit: () -> Void
    @State private var isShowingAdminPromptNotice = false

    private var labelColor: Color {
        Color(nsColor: .labelColor)
    }

    private var secondaryColor: Color {
        Color(nsColor: .secondaryLabelColor)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            Divider()
            settings
            Divider()
            status
            Divider()
            actions
        }
        .frame(width: 300)
        .padding(12)
        .environment(\.controlActiveState, .key)
        .alert("Admin Password Required", isPresented: $isShowingAdminPromptNotice) {
            Button("Cancel", role: .cancel) {}
            Button("Continue") {
                Task {
                    await appState.start()
                }
            }
        } message: {
            Text("macOS will ask for your password to enable lid-closed travel mode.")
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(appState.isRunning ? "Travel Mode On" : "Travel Mode Off")
                .font(.headline)
                .foregroundColor(labelColor)
            Text(appState.latestStatus)
                .font(.caption)
                .foregroundColor(secondaryColor)
                .lineLimit(2)
        }
    }

    private var settings: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("Hotspot", selection: $appState.settings.hotspotSSID) {
                hotspotChoices
            }
            .pickerStyle(.menu)
            .disabled(appState.isRunning || appState.availableHotspots.isEmpty)

            SecureField("Hotspot password", text: $appState.settings.hotspotPassword)
                .textFieldStyle(.roundedBorder)
                .disabled(appState.isRunning)

            Button("Save Hotspot") {
                do {
                    try appState.saveSettings()
                } catch {
                    appState.lastErrorMessage = error.localizedDescription
                }
            }
            .buttonStyle(.bordered)
            .disabled(appState.isRunning || appState.settings.hotspotSSID.isEmpty)
        }
    }

    @ViewBuilder
    private var hotspotChoices: some View {
        if appState.availableHotspots.isEmpty && appState.settings.hotspotSSID.isEmpty {
            Text("No saved hotspots").tag("")
        } else {
            if !appState.settings.hotspotSSID.isEmpty {
                Text(appState.settings.hotspotSSID).tag(appState.settings.hotspotSSID)
            }

            ForEach(visibleHotspots, id: \.self) { network in
                Text(network).tag(network)
            }
        }
    }

    private var visibleHotspots: [String] {
        appState.availableHotspots.filter { $0 != appState.settings.hotspotSSID }
    }

    private var status: some View {
        VStack(alignment: .leading, spacing: 4) {
            statusRow("Hotspot", selectedHotspotLabel)
            statusRow("Password", appState.hasSavedHotspotPassword ? "Saved" : "Missing")
            statusRow("Codex", appState.isCodexRunning ? "Running" : "Not running")
            statusRow("Wi-Fi", appState.latestWiFiNetwork)

            if let error = appState.lastErrorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundColor(.red)
                    .lineLimit(3)
                    .padding(.top, 2)
            }
        }
    }

    private var selectedHotspotLabel: String {
        appState.settings.hotspotSSID.isEmpty ? "Not selected" : appState.settings.hotspotSSID
    }

    private var actions: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button(appState.isRunning ? "Stop" : "Start") {
                if appState.isRunning {
                    Task {
                        await appState.stop()
                    }
                } else {
                    isShowingAdminPromptNotice = true
                }
            }
            .buttonStyle(.borderedProminent)
            .frame(maxWidth: .infinity)
            .disabled(!appState.isRunning && !appState.canStart)

            HStack {
                Button("Refresh") {
                    Task {
                        await appState.refreshStatus()
                    }
                }

                Spacer()

                Button("Quit") {
                    onQuit()
                }
            }
            .buttonStyle(.plain)
            .foregroundColor(labelColor)
        }
    }

    private func statusRow(_ title: String, _ value: String) -> some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.caption)
                .foregroundColor(secondaryColor)
                .frame(width: 58, alignment: .leading)
            Text(value)
                .font(.caption)
                .foregroundColor(labelColor)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
        }
    }
}
