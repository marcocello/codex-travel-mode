import AppKit
import CodexTravelModeCore
import SwiftUI

struct MenuBarLifecycleContent {
    let header: String
    let primaryAction: String
    let accessibilityLabel: String
    let symbolName: String
    let tint: NSColor
    let preferredPopoverSize: NSSize

    init(
        presentation: TravelModeLifecyclePresentation,
        hasPendingQuitIntent: Bool
    ) {
        switch presentation {
        case .off:
            header = "Travel Mode Off"
            primaryAction = "Start"
            accessibilityLabel = "Codex Travel Mode: Off"
            symbolName = "wifi.router"
            tint = .secondaryLabelColor
            preferredPopoverSize = NSSize(width: 344, height: 620)
        case .preparing:
            header = "Preparing Travel Mode"
            primaryAction = "Preparing…"
            accessibilityLabel = "Codex Travel Mode: Preparing"
            symbolName = "hourglass"
            tint = .systemOrange
            preferredPopoverSize = NSSize(width: 344, height: 330)
        case .active:
            header = "Travel Mode On"
            primaryAction = "Stop & Restore"
            accessibilityLabel = "Codex Travel Mode: Active"
            symbolName = "wifi.router.fill"
            tint = .systemGreen
            preferredPopoverSize = NSSize(width: 344, height: 390)
        case .restoring:
            header = "Restoring Travel Mode"
            primaryAction = "Restoring…"
            accessibilityLabel = "Codex Travel Mode: Restoring"
            symbolName = "arrow.triangle.2.circlepath"
            tint = .systemOrange
            preferredPopoverSize = NSSize(width: 344, height: 330)
        case .recovering:
            header = "Recovering Travel Mode"
            primaryAction = "Recovering…"
            accessibilityLabel = "Codex Travel Mode: Recovering"
            symbolName = "arrow.triangle.2.circlepath"
            tint = .systemOrange
            preferredPopoverSize = NSSize(width: 344, height: 330)
        case .cleanupRequired:
            header = "Cleanup Required"
            primaryAction = hasPendingQuitIntent
                ? "Retry Cleanup & Quit"
                : "Retry Cleanup"
            accessibilityLabel = "Codex Travel Mode: Cleanup Required"
            symbolName = "exclamationmark.triangle.fill"
            tint = .systemRed
            preferredPopoverSize = NSSize(width: 344, height: 410)
        }
    }
}

struct MenuBarContentView: View {
    @ObservedObject var appState: TravelModeAppState
    let onQuit: () -> Void
    let onRetryCleanupAndQuit: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isConfirmingStart = false

    private var lifecycleContent: MenuBarLifecycleContent {
        MenuBarLifecycleContent(
            presentation: appState.lifecyclePresentation,
            hasPendingQuitIntent: appState.hasPendingQuitIntent
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            LifecycleHero(
                content: lifecycleContent,
                message: isShowingStartConfirmation
                    ? "Review the protection step before continuing."
                    : safeStatusMessage
            )
            if isShowingStartConfirmation {
                startConfirmationSurface
                startConfirmationActions
            } else {
                lifecycleSurface
                actions
            }
        }
        .frame(width: 316)
        .padding(14)
        .environment(\.controlActiveState, .key)
        .animation(
            reduceMotion ? nil : .easeInOut(duration: 0.16),
            value: appState.lifecyclePresentation
        )
        .animation(
            reduceMotion ? nil : .easeInOut(duration: 0.16),
            value: isConfirmingStart
        )
    }

    @ViewBuilder
    private var lifecycleSurface: some View {
        switch appState.lifecyclePresentation {
        case .off:
            offSurface
        case .preparing, .restoring, .recovering:
            activitySurface
        case .active:
            activeSurface
        case .cleanupRequired:
            recoverySurface
        }
    }

    private var offSurface: some View {
        VStack(alignment: .leading, spacing: 10) {
            hotspotSetupCard
            readinessCard
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("travel.surface.off")
        .transition(.opacity)
    }

    private var hotspotSetupCard: some View {
        MenuBarCard("Fallback hotspot") {
            Picker("Discovered network", selection: discoveredHotspotSelection) {
                Text(
                    appState.availableHotspots.isEmpty
                        ? "No discovered networks"
                        : "Choose a discovered network"
                )
                .tag(nil as WiFiSSID?)

                ForEach(appState.availableHotspots, id: \.utf8Bytes) { network in
                    Text(network.displayName).tag(network as WiFiSSID?)
                }
            }
            .pickerStyle(.menu)
            .accessibilityIdentifier("hotspot.discovered-network")
            .disabled(configurationControlsDisabled || appState.availableHotspots.isEmpty)

            Text("Or enter the exact network name")
                .font(.caption2)
                .foregroundColor(Color(nsColor: .tertiaryLabelColor))

            TextField("Hotspot name", text: $appState.settings.hotspotSSID)
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("hotspot.manual-ssid")
                .disabled(configurationControlsDisabled)

            SecureField("Hotspot password", text: $appState.settings.hotspotPassword)
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("hotspot.password")
                .disabled(configurationControlsDisabled)

            discoveryStatus

            HStack {
                Button("Refresh Networks") {
                    Task {
                        await appState.refreshConfiguration(requestAuthorization: true)
                    }
                }
                .accessibilityIdentifier("hotspot.refresh-networks")
                .disabled(configurationControlsDisabled || isDiscoveryLoading)

                Spacer()

                Button(appState.isSavingConfiguration ? "Saving…" : "Save Hotspot") {
                    saveSettings()
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("hotspot.save")
                .disabled(saveHotspotDisabled)
            }

            if appState.hasUnsavedHotspotDraft {
                Label("Unsaved hotspot changes", systemImage: "circle.fill")
                    .font(.caption2)
                    .foregroundColor(Color(nsColor: .systemOrange))
                    .labelStyle(.titleAndIcon)
            }
        }
    }

    private var discoveryStatus: some View {
        HStack(alignment: .top, spacing: 6) {
            if isDiscoveryLoading {
                ProgressView()
                    .controlSize(.small)
            } else {
                Image(systemName: discoveryStatusSymbol)
                    .foregroundColor(discoveryMessageColor)
                    .accessibilityHidden(true)
            }
            Text(discoveryMessage)
                .font(.caption2)
                .foregroundColor(discoveryMessageColor)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var readinessCard: some View {
        MenuBarCard("Readiness") {
            ReadinessRow(
                title: "Hotspot",
                value: selectedHotspotLabel,
                level: appState.committedHotspotSSID == nil ? .attention : .ready,
                identifier: TravelModeStatusAccessibility.committedHotspot,
                semanticValue: selectedHotspotLabel
            )
            ReadinessRow(
                title: "Password",
                value: appState.hasSavedHotspotPassword ? "Saved" : "Missing",
                level: appState.hasSavedHotspotPassword ? .ready : .attention,
                identifier: TravelModeStatusAccessibility.savedCredential,
                semanticValue: String(appState.hasSavedHotspotPassword)
            )
            ReadinessRow(
                title: "Codex",
                value: appState.isCodexRunning ? "Running" : "Not running",
                level: appState.isCodexRunning ? .ready : .attention,
                identifier: TravelModeStatusAccessibility.codexRunning,
                semanticValue: String(appState.isCodexRunning)
            )
            ReadinessRow(
                title: "Wi-Fi device",
                value: appState.committedWiFiDevice ?? "Not detected",
                level: appState.committedWiFiDevice == nil ? .attention : .ready,
                identifier: TravelModeStatusAccessibility.wifiDevice,
                semanticValue: appState.committedWiFiDevice ?? "unavailable"
            )
            ReadinessRow(
                title: "Location",
                value: locationStatusLabel,
                level: locationReadinessLevel,
                identifier: TravelModeStatusAccessibility.locationAuthorization,
                semanticValue: appState.locationAuthorizationStatus?.rawValue ?? "unavailable"
            )
            ReadinessRow(
                title: "Nearby",
                value: appState.isCommittedHotspotVisible ? "Visible" : "Not visible",
                level: appState.isCommittedHotspotVisible ? .ready : .neutral,
                identifier: TravelModeStatusAccessibility.targetVisible,
                semanticValue: String(appState.isCommittedHotspotVisible)
            )
        }
    }

    private var activeSurface: some View {
        MenuBarCard("Protected session", tint: Color(nsColor: .systemGreen)) {
            Label("Travel protection is active", systemImage: "checkmark.shield.fill")
                .font(.callout.weight(.semibold))
                .foregroundColor(Color(nsColor: .systemGreen))

            Divider()

            SessionStatusRow(
                title: "Fallback",
                value: selectedHotspotLabel,
                identifier: TravelModeStatusAccessibility.committedHotspot,
                semanticValue: selectedHotspotLabel
            )
            SessionStatusRow(
                title: "Current Wi-Fi",
                value: appState.latestWiFiNetwork,
                identifier: "travel.status.wifi",
                semanticValue: appState.latestWiFiNetwork
            )
            SessionStatusRow(
                title: "Codex",
                value: appState.isCodexRunning ? "Running" : "Not running",
                identifier: TravelModeStatusAccessibility.codexRunning,
                semanticValue: String(appState.isCodexRunning)
            )

            Divider()

            Label(
                "Stop or Quit restores the power and Wi-Fi settings saved before this session.",
                systemImage: "arrow.uturn.backward.circle"
            )
            .font(.caption)
            .foregroundColor(Color(nsColor: .secondaryLabelColor))
            .fixedSize(horizontal: false, vertical: true)

            if appState.lastErrorMessage != nil {
                Label(safeErrorMessage, systemImage: "exclamationmark.circle")
                    .font(.caption)
                    .foregroundColor(Color(nsColor: .systemRed))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("travel.surface.active")
        .transition(.opacity)
    }

    private var activitySurface: some View {
        MenuBarCard(tint: Color(nsColor: .systemOrange)) {
            HStack(spacing: 10) {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel(transitionTitle)

                VStack(alignment: .leading, spacing: 2) {
                    Text(transitionTitle)
                        .font(.callout.weight(.semibold))
                    Text(transitionDetail)
                        .font(.caption)
                        .foregroundColor(Color(nsColor: .secondaryLabelColor))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Divider()

            Label("Keep Travel Mode open until this finishes.", systemImage: "lock.shield")
                .font(.caption)
                .foregroundColor(Color(nsColor: .secondaryLabelColor))
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("travel.surface.activity")
        .transition(.opacity)
    }

    private var recoverySurface: some View {
        MenuBarCard(tint: Color(nsColor: .systemRed)) {
            Label("Restoration needs attention", systemImage: "exclamationmark.shield.fill")
                .font(.callout.weight(.semibold))
                .foregroundColor(Color(nsColor: .systemRed))

            Text(safeErrorMessage)
                .font(.caption)
                .foregroundColor(Color(nsColor: .labelColor))
                .fixedSize(horizontal: false, vertical: true)

            Divider()

            Label(recoveryGuidance, systemImage: "arrow.clockwise.circle")
                .font(.caption)
                .foregroundColor(Color(nsColor: .secondaryLabelColor))
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("travel.surface.recovery")
        .transition(.opacity)
    }

    private var startConfirmationSurface: some View {
        VStack(alignment: .leading, spacing: 12) {
            MenuBarCard(tint: Color(nsColor: .controlAccentColor)) {
                Label("Enable Travel Protection", systemImage: "shield.lefthalf.filled")
                    .font(.callout.weight(.semibold))
                    .foregroundColor(Color(nsColor: .controlAccentColor))

                Text("Travel Mode will save the current power and Wi-Fi state before changing anything.")
                    .font(.caption)
                    .foregroundColor(Color(nsColor: .labelColor))
                    .fixedSize(horizontal: false, vertical: true)

                Divider()

                confirmationDetail(
                    "Keep this Mac awake while the lid is closed",
                    symbol: "moon.zzz"
                )
                confirmationDetail(
                    "Restore saved settings when you Stop or Quit",
                    symbol: "arrow.uturn.backward.circle"
                )
                confirmationDetail(
                    "macOS may ask you to approve the background helper",
                    symbol: "lock.shield"
                )
            }

            Label("Nothing changes until you press Continue.", systemImage: "checkmark.circle")
                .font(.caption)
                .foregroundColor(Color(nsColor: .secondaryLabelColor))
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("travel.surface.start-confirmation")
        .transition(.opacity)
    }

    private func confirmationDetail(_ text: String, symbol: String) -> some View {
        Label(text, systemImage: symbol)
            .font(.caption)
            .foregroundColor(Color(nsColor: .secondaryLabelColor))
            .fixedSize(horizontal: false, vertical: true)
    }

    private var startConfirmationActions: some View {
        VStack(spacing: 9) {
            Button {
                isConfirmingStart = false
                Task {
                    await appState.start()
                }
            } label: {
                Text("Continue")
                    .font(.body.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 2)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .accessibilityIdentifier("travel.primary-action")

            Button(role: .cancel) {
                isConfirmingStart = false
            } label: {
                Text("Cancel")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 2)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .accessibilityIdentifier("travel.cancel-start")
        }
    }

    private var actions: some View {
        VStack(alignment: .leading, spacing: 9) {
            Button(action: performPrimaryAction) {
                Text(lifecycleContent.primaryAction)
                    .font(.body.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 2)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .accessibilityIdentifier("travel.primary-action")
            .disabled(!primaryActionEnabled)

            if appState.canRetryInternetHandoff {
                Button("Retry iPhone Internet") {
                    Task {
                        await appState.retryInternetHandoff()
                    }
                }
                .buttonStyle(.bordered)
                .frame(maxWidth: .infinity)
                .accessibilityIdentifier("travel.retry-internet")
            }

            HStack {
                Button("Refresh Status") {
                    Task {
                        await appState.refreshStatus()
                    }
                }
                .accessibilityIdentifier("travel.refresh-status")
                .disabled(!statusRefreshEnabled)

                Spacer()

                Button("Quit") {
                    onQuit()
                }
                .accessibilityIdentifier("travel.quit")
            }
            .buttonStyle(.plain)
            .foregroundColor(Color(nsColor: .labelColor))
        }
    }

    private var discoveredHotspotSelection: Binding<WiFiSSID?> {
        Binding(
            get: {
                guard let draft = WiFiSSID(displayName: appState.settings.hotspotSSID) else {
                    return nil
                }
                return appState.availableHotspots.first { $0 == draft }
            },
            set: { network in
                guard let network else { return }
                appState.settings.hotspotSSID = network.displayName
            }
        )
    }

    private var configurationControlsDisabled: Bool {
        appState.isConfigurationLocked
    }

    private var isShowingStartConfirmation: Bool {
        isConfirmingStart && appState.lifecyclePresentation == .off
    }

    private var saveHotspotDisabled: Bool {
        configurationControlsDisabled
            || !appState.hasUnsavedHotspotDraft
            || appState.settings.hotspotSSID.isEmpty
    }

    private var isDiscoveryLoading: Bool {
        if case .loading = appState.discoveryState {
            return true
        }
        return false
    }

    private var discoveryStatusSymbol: String {
        guard case .loaded(let snapshot) = appState.discoveryState else {
            return "info.circle"
        }
        switch snapshot.visibleScanStatus {
        case .completed:
            return "checkmark.circle"
        case .notDetermined:
            return "location.circle"
        case .denied, .restricted, .servicesDisabled, .noWiFiInterface, .providerFailed:
            return "exclamationmark.circle"
        }
    }

    private var discoveryMessage: String {
        switch appState.discoveryState {
        case .idle:
            return "Refresh to load remembered and nearby networks."
        case .loading:
            return "Loading remembered and nearby networks…"
        case .loaded(let snapshot):
            return discoveryMessage(for: snapshot)
        }
    }

    private var discoveryMessageColor: Color {
        guard case .loaded(let snapshot) = appState.discoveryState else {
            return Color(nsColor: .secondaryLabelColor)
        }
        switch snapshot.visibleScanStatus {
        case .completed:
            return Color(nsColor: .secondaryLabelColor)
        case .notDetermined:
            return Color(nsColor: .systemOrange)
        case .denied, .restricted, .servicesDisabled, .noWiFiInterface, .providerFailed:
            return Color(nsColor: .systemRed)
        }
    }

    private func discoveryMessage(for snapshot: WiFiDiscoverySnapshot) -> String {
        switch snapshot.visibleScanStatus {
        case .completed:
            if snapshot.visibleNetworks.isEmpty && snapshot.rememberedNetworks.isEmpty {
                return "No networks found. Enter the exact hotspot name."
            }
            if snapshot.visibleNetworks.isEmpty {
                return "No nearby networks; remembered networks remain available."
            }
            return "Network list is up to date."
        case .notDetermined:
            return "Refresh Networks to allow nearby-network access."
        case .denied:
            return "Location access is off; remembered networks still work."
        case .restricted:
            return "Location access is restricted; remembered networks still work."
        case .servicesDisabled:
            return "Location Services are off; enter the hotspot name manually."
        case .noWiFiInterface:
            return "No Wi-Fi interface is available right now."
        case .providerFailed:
            return "Networks could not be loaded. Enter the name or retry."
        }
    }

    private var selectedHotspotLabel: String {
        appState.committedHotspotSSID ?? "Not selected"
    }

    private var locationStatusLabel: String {
        switch appState.locationAuthorizationStatus {
        case .completed: "Authorized"
        case .notDetermined: "Not determined"
        case .denied: "Denied"
        case .restricted: "Restricted"
        case .servicesDisabled: "Services off"
        case .noWiFiInterface: "No Wi-Fi"
        case .providerFailed: "Unavailable"
        case nil: "Unavailable"
        }
    }

    private var locationReadinessLevel: ReadinessLevel {
        switch appState.locationAuthorizationStatus {
        case .completed:
            return .ready
        case .notDetermined, nil:
            return .neutral
        case .denied, .restricted, .servicesDisabled, .noWiFiInterface, .providerFailed:
            return .attention
        }
    }

    private var transitionTitle: String {
        switch appState.lifecyclePresentation {
        case .preparing: "Securing your session"
        case .restoring: "Restoring saved settings"
        case .recovering: "Recovering saved settings"
        case .off, .active, .cleanupRequired: "Updating Travel Mode"
        }
    }

    private var transitionDetail: String {
        switch appState.lifecyclePresentation {
        case .preparing:
            return "Saving the current power and Wi-Fi state before protection starts."
        case .restoring:
            return "Returning power and Wi-Fi to their pre-session state."
        case .recovering:
            return "Finishing restoration from an interrupted session."
        case .off, .active, .cleanupRequired:
            return "Travel Mode is updating its session state."
        }
    }

    private var recoveryGuidance: String {
        appState.hasPendingQuitIntent
            ? "The app will quit automatically after cleanup verifies the saved settings are restored."
            : "The app will stay open and keep ownership of the saved session until cleanup succeeds."
    }

    private var primaryActionEnabled: Bool {
        switch appState.lifecyclePresentation {
        case .off:
            return appState.canStart
        case .active, .cleanupRequired:
            return true
        case .preparing, .restoring, .recovering:
            return false
        }
    }

    private var statusRefreshEnabled: Bool {
        switch appState.lifecyclePresentation {
        case .off, .active, .cleanupRequired:
            return true
        case .preparing, .restoring, .recovering:
            return false
        }
    }

    private var safeStatusMessage: String {
        switch appState.lifecyclePresentation {
        case .off:
            if appState.lastErrorMessage != nil {
                return "The previous action did not finish. Review readiness and try again."
            }
            if appState.canStart {
                return "Ready to keep this session working while you travel."
            }
            if appState.hasUnsavedHotspotDraft {
                return "Save the fallback hotspot before starting."
            }
            return "Complete the readiness checks below to start safely."
        case .preparing:
            return "Travel Mode is preparing a protected session."
        case .active:
            return appState.latestStatus
        case .restoring:
            return "Restoring the settings saved before Travel Mode started."
        case .recovering:
            return "Recovering settings from an interrupted Travel Mode session."
        case .cleanupRequired:
            return "Some saved settings still need to be restored."
        }
    }

    private var safeErrorMessage: String {
        switch appState.lifecyclePresentation {
        case .cleanupRequired:
            return "Restoration is incomplete. Retry cleanup and approve the administrator request if macOS asks."
        case .off, .preparing, .active, .restoring, .recovering:
            return "Travel Mode could not complete that action. Check the current status and try again."
        }
    }

    private func saveSettings() {
        Task {
            do {
                try await appState.saveSettings()
            } catch {
                appState.lastErrorMessage = error.localizedDescription
            }
        }
    }

    private func performPrimaryAction() {
        switch appState.lifecyclePresentation {
        case .off:
            isConfirmingStart = true
        case .active:
            Task {
                await appState.stop()
            }
        case .cleanupRequired:
            if appState.hasPendingQuitIntent {
                onRetryCleanupAndQuit()
            } else {
                Task {
                    await appState.retryCleanup()
                }
            }
        case .preparing, .restoring, .recovering:
            break
        }
    }
}
