import Combine
import Foundation

@MainActor
public final class TravelModeAppState: ObservableObject {
    @Published public var settings = TravelModeSettings()
    @Published public private(set) var isRunning = false
    @Published public private(set) var latestStatus = "Stopped"
    @Published public private(set) var latestWiFiNetwork = "Unknown"
    @Published public private(set) var availableHotspots: [String] = []
    @Published public private(set) var isCodexRunning = false
    @Published public private(set) var hasSavedHotspotPassword = false
    @Published public private(set) var logs: [String] = []
    @Published public var lastErrorMessage: String?

    private let gateway: TravelCommandGateway
    private let engine: TravelModeEngine
    private let settingsStore: TravelSettingsStoring
    private var loopTask: Task<Void, Never>?
    private var lidOverrideActive = false
    private var lastPreservedNetwork: String?
    private var fallbackArmed = false
    private var restoreSnapshot: TravelRestoreSnapshot?

    public init(
        gateway: TravelCommandGateway,
        engine: TravelModeEngine = TravelModeEngine(),
        settingsStore: TravelSettingsStoring = UserDefaultsTravelSettingsStore()
    ) {
        self.gateway = gateway
        self.engine = engine
        self.settingsStore = settingsStore
        self.settings = settingsStore.load()
        self.hasSavedHotspotPassword = settingsStore.hasSavedHotspotPassword()
    }

    public var canStart: Bool {
        !isRunning
            && isCodexRunning
            && !settings.trimmedHotspotSSID.isEmpty
            && !settings.trimmedWiFiDevice.isEmpty
            && hasSavedHotspotPassword
    }

    public func refreshConfiguration() async {
        if settings.trimmedWiFiDevice.isEmpty, let device = await gateway.discoverWiFiDevice() {
            settings.wifiDevice = device
        }

        let device = settings.trimmedWiFiDevice
        guard !device.isEmpty else {
            latestWiFiNetwork = "Missing Wi-Fi device"
            availableHotspots = []
            return
        }

        let networks = mergedNetworks(
            preferred: await gateway.knownWiFiNetworks(device: device),
            scanned: await gateway.scanWiFiNetworks(device: device)
        )

        let currentSelection = settings.trimmedHotspotSSID
        availableHotspots = networksIncludingCurrentSelection(
            networks: networks,
            currentSelection: currentSelection
        )

        if currentSelection.isEmpty {
            settings.hotspotSSID = preferredDefaultHotspot(from: networks)
        }
    }

    public func start() async {
        guard !isRunning else { return }
        do {
            guard await validateCanStart() else {
                return
            }
            let snapshot = await captureRestoreSnapshot()
            restoreSnapshot = snapshot
            settingsStore.saveRestoreSnapshot(snapshot)
            try await gateway.startKeepAwake()
            try await gateway.setLidClosedSleepOverride(enabled: true)
            lidOverrideActive = true
            isRunning = true
            latestStatus = "Travel Mode active"
            appendLog("Travel Mode started")
            lastErrorMessage = nil
            _ = await ensureFallbackIsArmedIfPossible()
            beginLoop()
        } catch {
            lastErrorMessage = error.localizedDescription
            await stop()
        }
    }

    public func stop() async {
        loopTask?.cancel()
        loopTask = nil
        await gateway.stopKeepAwake()
        let restored = await restoreSystemState()
        lidOverrideActive = false
        isRunning = false
        latestStatus = "Stopped"
        appendLog("Travel Mode stopped")
        lastPreservedNetwork = nil
        fallbackArmed = false
        if restored {
            settingsStore.clearRestoreSnapshot()
            restoreSnapshot = nil
        }
    }

    public func recoverPreviousSessionIfNeeded() async {
        guard settingsStore.loadRestoreSnapshot() != nil else {
            return
        }

        appendLog("Recovering previous Travel Mode power settings")
        let restored = await restoreSystemState()
        if restored {
            settingsStore.clearRestoreSnapshot()
            restoreSnapshot = nil
            latestStatus = "Recovered previous Travel Mode settings"
            appendLog(latestStatus)
        }
    }

    public func refreshStatus() async {
        if settings.trimmedWiFiDevice.isEmpty {
            await refreshConfiguration()
        }

        let device = settings.trimmedWiFiDevice
        guard !device.isEmpty else {
            latestWiFiNetwork = "Missing Wi-Fi device"
            return
        }

        let status = await gateway.currentWiFiStatus(device: device)
        latestWiFiNetwork = status.networkName ?? "Not associated"
        isCodexRunning = await gateway.isCodexRunning()
        hasSavedHotspotPassword = settingsStore.hasSavedHotspotPassword()
    }

    private func preferredDefaultHotspot(from networks: [String]) -> String {
        networks.first { $0.localizedCaseInsensitiveContains("iphone") }
            ?? networks.first
            ?? ""
    }

    private func mergedNetworks(preferred: [String], scanned: [String]) -> [String] {
        var merged: [String] = []
        for network in preferred + scanned {
            guard !network.isEmpty, !merged.contains(network) else {
                continue
            }
            merged.append(network)
        }
        return merged
    }

    private func networksIncludingCurrentSelection(
        networks: [String],
        currentSelection: String
    ) -> [String] {
        guard !currentSelection.isEmpty, !networks.contains(currentSelection) else {
            return networks
        }
        return [currentSelection] + networks
    }

    public func syncOnce() async {
        isCodexRunning = await gateway.isCodexRunning()
        guard await ensureFallbackIsArmedIfPossible() else {
            return
        }
        let forceFallback = await shouldForceFallbackForClosedLid()
        let event = await engine.sync(
            settings: settings,
            gateway: gateway,
            passwordProvider: { [settingsStore] in
                try? settingsStore.loadHotspotPassword()
            },
            forceFallback: forceFallback
        )
        apply(event)
    }

    public func openWiFiSettings() async {
        await gateway.openWiFiSettings()
    }

    public func saveSettings() throws {
        try settingsStore.save(settings)
        hasSavedHotspotPassword = settingsStore.hasSavedHotspotPassword()
        latestStatus = "Saved fallback hotspot '\(settings.trimmedHotspotSSID)'"
        appendLog(latestStatus)
    }

    private func beginLoop() {
        loopTask?.cancel()
        loopTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled else { break }
                await self?.syncOnce()
            }
        }
    }

    private func validateCanStart() async -> Bool {
        isCodexRunning = await gateway.isCodexRunning()
        guard isCodexRunning else {
            latestStatus = "Cannot start: Codex is not running."
            appendLog(latestStatus)
            return false
        }

        guard !settings.trimmedHotspotSSID.isEmpty else {
            latestStatus = "Cannot start: select a fallback hotspot."
            appendLog(latestStatus)
            return false
        }

        hasSavedHotspotPassword = settingsStore.hasSavedHotspotPassword()
        guard hasSavedHotspotPassword else {
            latestStatus = "Cannot start: save the hotspot password first."
            appendLog(latestStatus)
            return false
        }

        if settings.trimmedWiFiDevice.isEmpty {
            await refreshConfiguration()
        }

        guard !settings.trimmedWiFiDevice.isEmpty else {
            latestStatus = "Cannot start: Wi-Fi device was not detected."
            appendLog(latestStatus)
            return false
        }

        return true
    }

    private func shouldForceFallbackForClosedLid() async -> Bool {
        guard await gateway.currentLidClosed() == true else {
            return false
        }
        latestStatus = "Lid closed; switching to fallback hotspot '\(settings.trimmedHotspotSSID)'."
        appendLog(latestStatus)
        return true
    }

    private func captureRestoreSnapshot() async -> TravelRestoreSnapshot {
        let device = settings.trimmedWiFiDevice
        let wifiPower = device.isEmpty ? nil : await gateway.currentWiFiPower(device: device)
        return TravelRestoreSnapshot(
            lidClosedSleepOverrideEnabled: await gateway.currentLidClosedSleepOverride(),
            powerSettings: await gateway.currentPowerSettings(),
            wifiDevice: device.isEmpty ? nil : device,
            wifiPowerEnabled: wifiPower
        )
    }

    private func restoreSystemState() async -> Bool {
        let snapshot = restoreSnapshot ?? settingsStore.loadRestoreSnapshot()
        var lidOverrideNeedsCleanup = snapshot?.lidClosedSleepOverrideEnabled != nil
        if !lidOverrideNeedsCleanup {
            lidOverrideNeedsCleanup = await gateway.currentLidClosedSleepOverride() == true
        }
        if lidOverrideNeedsCleanup {
            do {
                try await gateway.setLidClosedSleepOverride(enabled: false)
                appendLog("Restored lid-closed sleep override to disabled")
            } catch {
                lastErrorMessage = error.localizedDescription
                return false
            }
        }

        if let powerSettings = snapshot?.powerSettings {
            do {
                try await gateway.restorePowerSettings(powerSettings)
                appendLog("Restored saved pmset sleep and ttyskeepawake values")
            } catch {
                lastErrorMessage = error.localizedDescription
                return false
            }
        }

        guard
            let device = snapshot?.wifiDevice,
            let wifiPower = snapshot?.wifiPowerEnabled
        else {
            return true
        }
        await gateway.setWiFiPower(device: device, enabled: wifiPower)
        appendLog("Restored Wi-Fi power on \(device) to \(wifiPower ? "on" : "off")")
        return true
    }

    private func apply(_ event: TravelModeEvent) {
        appendLog(event.message)
        switch event {
        case .preservedCurrentWiFi(let network):
            latestWiFiNetwork = network
            guard lastPreservedNetwork != network else { return }
            latestStatus = event.message
            lastPreservedNetwork = network
        default:
            latestStatus = event.message
            if case .hotspotConnected(let network) = event {
                latestWiFiNetwork = network
                lastPreservedNetwork = network
            } else {
                lastPreservedNetwork = nil
            }
        }
    }

    private func ensureFallbackIsArmedIfPossible() async -> Bool {
        if fallbackArmed {
            return true
        }

        let device = settings.trimmedWiFiDevice
        guard !device.isEmpty else {
            latestStatus = "Missing Wi-Fi device"
            appendLog(latestStatus)
            return false
        }

        let status = await gateway.currentWiFiStatus(device: device)
        if status.commandFailed {
            latestStatus = "Could not read Wi-Fi status: \(status.rawOutput.trimmingCharacters(in: .whitespacesAndNewlines))"
            appendLog(latestStatus)
            return false
        }

        if let network = status.networkName, !network.isEmpty {
            fallbackArmed = true
            latestWiFiNetwork = network
            latestStatus = "Watching Wi-Fi '\(network)'; fallback will run if it disconnects."
            appendLog(latestStatus)
            return false
        }

        latestWiFiNetwork = "Not associated"
        latestStatus = "Travel Mode active; waiting for a connected Wi-Fi network to disconnect."
        appendLog(latestStatus)
        fallbackArmed = true
        return false
    }

    private func appendLog(_ message: String) {
        guard logs.last != message else {
            return
        }
        logs.append(message)
        if logs.count > 100 {
            logs.removeFirst(logs.count - 100)
        }
    }
}
