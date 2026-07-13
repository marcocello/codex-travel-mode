import CodexTravelModeCore
import XCTest

final class TravelModeEngineTests: XCTestCase {
    func testPreservesCurrentWiFiAndDoesNotJoinHotspot() async {
        let gateway = StubGateway(
            statuses: [
                WiFiStatus(device: "en0", networkName: "Office", rawOutput: "Current Wi-Fi Network: Office")
            ]
        )
        let settings = TravelModeSettings(hotspotSSID: "iPhone", wifiDevice: "en0")

        let event = await TravelModeEngine().sync(settings: settings, gateway: gateway)

        XCTAssertEqual(event, .preservedCurrentWiFi("Office"))
        XCTAssertEqual(gateway.joinAttempts, [])
        XCTAssertEqual(gateway.wifiPowerChanges, [])
    }

    func testPreservedCurrentWiFiDoesNotLoadFallbackPassword() async {
        let gateway = StubGateway(
            statuses: [
                WiFiStatus(device: "en0", networkName: "Office", rawOutput: "Current Wi-Fi Network: Office")
            ]
        )
        let settings = TravelModeSettings(hotspotSSID: "iPhone", wifiDevice: "en0")
        let passwordProvider = PasswordProviderSpy(password: "secret")

        let event = await TravelModeEngine().sync(
            settings: settings,
            gateway: gateway,
            passwordProvider: {
                passwordProvider.password()
            }
        )

        XCTAssertEqual(event, .preservedCurrentWiFi("Office"))
        XCTAssertEqual(passwordProvider.readCount, 0)
    }

    func testDisconnectedWiFiJoinsHotspotAndVerifiesConnection() async {
        let gateway = StubGateway(
            statuses: [
                WiFiStatus(
                    device: "en0",
                    networkName: nil,
                    rawOutput: "You are not associated with an AirPort network."
                ),
                WiFiStatus(device: "en0", networkName: "iPhone", rawOutput: "Current Wi-Fi Network: iPhone")
            ]
        )
        let settings = TravelModeSettings(
            hotspotSSID: "iPhone",
            hotspotPassword: "secret",
            wifiDevice: "en0"
        )

        let event = await TravelModeEngine().sync(settings: settings, gateway: gateway)

        XCTAssertEqual(event, .hotspotConnected("iPhone"))
        XCTAssertEqual(gateway.wifiPowerChanges, [true])
        XCTAssertEqual(gateway.joinAttempts, [JoinAttempt(device: "en0", ssid: "iPhone", password: "secret")])
    }

    func testDisconnectedWiFiWaitsForDelayedHotspotAssociation() async {
        let gateway = StubGateway(
            statuses: [
                WiFiStatus(
                    device: "en0",
                    networkName: nil,
                    rawOutput: "You are not associated with an AirPort network."
                ),
                WiFiStatus(
                    device: "en0",
                    networkName: nil,
                    rawOutput: "You are not associated with an AirPort network."
                ),
                WiFiStatus(device: "en0", networkName: "iPhone", rawOutput: "Current Wi-Fi Network: iPhone")
            ]
        )
        let settings = TravelModeSettings(
            hotspotSSID: "iPhone",
            hotspotPassword: "secret",
            wifiDevice: "en0"
        )
        let engine = TravelModeEngine(verificationAttempts: 2, verificationDelay: .zero)

        let event = await engine.sync(settings: settings, gateway: gateway)

        XCTAssertEqual(event, .hotspotConnected("iPhone"))
        XCTAssertEqual(gateway.joinAttempts, [JoinAttempt(device: "en0", ssid: "iPhone", password: "secret")])
    }

    func testDisconnectedWiFiFailureReportsPasswordWasProvided() async {
        let gateway = StubGateway(
            statuses: [
                WiFiStatus(
                    device: "en0",
                    networkName: nil,
                    rawOutput: "You are not associated with an AirPort network."
                ),
                WiFiStatus(
                    device: "en0",
                    networkName: nil,
                    rawOutput: "You are not associated with an AirPort network."
                )
            ]
        )
        let settings = TravelModeSettings(
            hotspotSSID: "iPhone",
            hotspotPassword: "secret",
            wifiDevice: "en0"
        )

        let event = await TravelModeEngine().sync(settings: settings, gateway: gateway)

        XCTAssertEqual(
            event,
            .hotspotFailed(
                "You are not associated with an AirPort network.\n\nPassword was provided to the password-based join backends, but macOS did not associate to 'iPhone'."
            )
        )
        XCTAssertEqual(gateway.joinAttempts, [JoinAttempt(device: "en0", ssid: "iPhone", password: "secret")])
    }

    func testDisconnectedWiFiLoadsSavedFallbackPasswordWhenNeeded() async {
        let gateway = StubGateway(
            statuses: [
                WiFiStatus(
                    device: "en0",
                    networkName: nil,
                    rawOutput: "You are not associated with an AirPort network."
                ),
                WiFiStatus(device: "en0", networkName: "iPhone", rawOutput: "Current Wi-Fi Network: iPhone")
            ]
        )
        let settings = TravelModeSettings(hotspotSSID: "iPhone", wifiDevice: "en0")

        let event = await TravelModeEngine().sync(
            settings: settings,
            gateway: gateway,
            passwordProvider: { "secret" }
        )

        XCTAssertEqual(event, .hotspotConnected("iPhone"))
        XCTAssertEqual(gateway.joinAttempts, [JoinAttempt(device: "en0", ssid: "iPhone", password: "secret")])
    }

    func testDisconnectedWiFiDoesNotJoinWithoutPassword() async {
        let gateway = StubGateway(
            statuses: [
                WiFiStatus(
                    device: "en0",
                    networkName: nil,
                    rawOutput: "You are not associated with an AirPort network."
                )
            ]
        )
        let settings = TravelModeSettings(hotspotSSID: "iPhone", wifiDevice: "en0")

        let event = await TravelModeEngine().sync(settings: settings, gateway: gateway)

        XCTAssertEqual(
            event.message,
            "Could not join the fallback hotspot.\n\nmacOS still reports: No hotspot password was available. Save the hotspot password again.\n\nThe app uses the saved hotspot password with networksetup. If this repeats, macOS is refusing to associate to that SSID; check that Personal Hotspot is discoverable and the saved password is correct."
        )
        XCTAssertEqual(gateway.joinAttempts, [])
    }

    func testMissingSettingsAreReportedWithoutCommands() async {
        let gateway = StubGateway(statuses: [])

        let event = await TravelModeEngine().sync(
            settings: TravelModeSettings(hotspotSSID: "", wifiDevice: "en0"),
            gateway: gateway
        )

        XCTAssertEqual(event, .missingHotspotSSID)
        XCTAssertEqual(gateway.commandsStarted, false)
    }
}

@MainActor
final class TravelModeAppStateTests: XCTestCase {
    private func makeAppState(
        gateway: StubGateway,
        settings: TravelModeSettings = TravelModeSettings()
    ) -> TravelModeAppState {
        TravelModeAppState(
            gateway: gateway,
            settingsStore: InMemorySettingsStore(settings: settings)
        )
    }

    func testRefreshConfigurationDiscoversWiFiDeviceAndSelectableNetworks() async {
        let gateway = StubGateway(
            statuses: [
                WiFiStatus(device: "en0", networkName: "Office", rawOutput: "Current Wi-Fi Network: Office")
            ],
            discoveredDevice: "en0",
            knownNetworks: ["Office"],
            scannedNetworks: ["iPhone"]
        )
        let appState = makeAppState(gateway: gateway)

        await appState.refreshConfiguration()

        XCTAssertEqual(appState.settings.wifiDevice, "en0")
        XCTAssertEqual(appState.availableHotspots, ["Office", "iPhone"])
        XCTAssertEqual(appState.settings.hotspotSSID, "iPhone")
    }

    func testRefreshConfigurationKeepsExistingHotspotSelection() async {
        let gateway = StubGateway(discoveredDevice: "en0", knownNetworks: ["Office", "iPhone"])
        let appState = makeAppState(gateway: gateway)
        appState.settings.hotspotSSID = "Office"

        await appState.refreshConfiguration()

        XCTAssertEqual(appState.settings.hotspotSSID, "Office")
    }

    func testRefreshConfigurationKeepsSelectedHotspotWhenItIsNotCurrentlyVisible() async {
        let gateway = StubGateway(discoveredDevice: "en0", knownNetworks: ["CIC"], scannedNetworks: [])
        let appState = makeAppState(
            gateway: gateway,
            settings: TravelModeSettings(hotspotSSID: "iPhone", wifiDevice: "")
        )

        await appState.refreshConfiguration()

        XCTAssertEqual(appState.settings.hotspotSSID, "iPhone")
        XCTAssertEqual(appState.availableHotspots, ["iPhone", "CIC"])
    }

    func testLoadsSavedSettingsOnInitAndCanSaveSelection() async throws {
        let store = InMemorySettingsStore(
            settings: TravelModeSettings(
                hotspotSSID: "iPhone",
                hotspotPassword: "secret",
                wifiDevice: "en0"
            )
        )
        let appState = TravelModeAppState(gateway: StubGateway(), settingsStore: store)

        XCTAssertEqual(appState.settings.hotspotSSID, "iPhone")
        XCTAssertEqual(appState.settings.hotspotPassword, "secret")
        XCTAssertEqual(appState.settings.wifiDevice, "en0")

        appState.settings.hotspotSSID = "Office"
        appState.settings.hotspotPassword = "next-secret"
        try appState.saveSettings()

        XCTAssertEqual(store.savedSettings?.hotspotSSID, "Office")
        XCTAssertEqual(store.savedSettings?.hotspotPassword, "next-secret")
    }

    func testStartAlwaysEnablesAndStopRestoresLidOverride() async {
        let gateway = StubGateway(
            statuses: [
                WiFiStatus(device: "en0", networkName: "Office", rawOutput: "Current Wi-Fi Network: Office")
            ],
            discoveredDevice: "en0",
            knownNetworks: ["Office", "iPhone"],
            codexRunning: true,
            lidClosedSleepOverride: false,
            wifiPower: true
        )
        let appState = makeAppState(
            gateway: gateway,
            settings: TravelModeSettings(hotspotSSID: "iPhone", hotspotPassword: "secret", wifiDevice: "en0")
        )

        await appState.start()
        await appState.stop()

        XCTAssertEqual(gateway.lidOverrideChanges, [true, false])
    }

    func testStopAlwaysTurnsOffLidClosedSleepOverride() async {
        let gateway = StubGateway(
            statuses: [
                WiFiStatus(device: "en0", networkName: "Office", rawOutput: "Current Wi-Fi Network: Office")
            ],
            codexRunning: true,
            lidClosedSleepOverride: true,
            wifiPower: true
        )
        let appState = makeAppState(
            gateway: gateway,
            settings: TravelModeSettings(hotspotSSID: "iPhone", hotspotPassword: "secret", wifiDevice: "en0")
        )

        await appState.start()
        await appState.stop()

        XCTAssertEqual(gateway.lidOverrideChanges, [true, false])
    }

    func testStopRestoresPersistedSnapshotWhenMemorySnapshotIsMissing() async {
        let store = InMemorySettingsStore(
            settings: TravelModeSettings(hotspotSSID: "iPhone", hotspotPassword: "secret", wifiDevice: "en0")
        )
        store.restoreSnapshot = TravelRestoreSnapshot(
            lidClosedSleepOverrideEnabled: false,
            wifiDevice: "en0",
            wifiPowerEnabled: true
        )
        let gateway = StubGateway()
        let appState = TravelModeAppState(gateway: gateway, settingsStore: store)

        await appState.stop()

        XCTAssertEqual(gateway.lidOverrideChanges, [false])
        XCTAssertEqual(gateway.wifiPowerChanges, [true])
        XCTAssertNil(store.restoreSnapshot)
    }

    func testRecoverPreviousSessionRestoresPersistedSnapshot() async {
        let powerSettings = PowerSettingsSnapshot(
            battery: PowerProfileSettings(sleep: 1, ttysKeepAwake: 0),
            ac: PowerProfileSettings(sleep: 30, ttysKeepAwake: 0)
        )
        let store = InMemorySettingsStore(
            settings: TravelModeSettings(hotspotSSID: "iPhone", hotspotPassword: "secret", wifiDevice: "en0")
        )
        store.restoreSnapshot = TravelRestoreSnapshot(
            lidClosedSleepOverrideEnabled: false,
            powerSettings: powerSettings,
            wifiDevice: "en0",
            wifiPowerEnabled: true
        )
        let gateway = StubGateway()
        let appState = TravelModeAppState(gateway: gateway, settingsStore: store)

        await appState.recoverPreviousSessionIfNeeded()

        XCTAssertEqual(gateway.lidOverrideChanges, [false])
        XCTAssertEqual(gateway.restoredPowerSettings, [powerSettings])
        XCTAssertEqual(gateway.wifiPowerChanges, [true])
        XCTAssertNil(store.restoreSnapshot)
        XCTAssertEqual(appState.latestStatus, "Recovered previous Travel Mode settings")
    }

    func testStopTurnsOffCurrentLidClosedSleepOverrideWithoutSnapshot() async {
        let gateway = StubGateway(lidClosedSleepOverride: true)
        let appState = makeAppState(gateway: gateway)

        await appState.stop()

        XCTAssertEqual(gateway.lidOverrideChanges, [false])
    }

    func testStopRestoresWiFiPowerSnapshot() async {
        let gateway = StubGateway(
            statuses: [
                WiFiStatus(device: "en0", networkName: "Office", rawOutput: "Current Wi-Fi Network: Office")
            ],
            codexRunning: true,
            lidClosedSleepOverride: false,
            wifiPower: false
        )
        let appState = makeAppState(
            gateway: gateway,
            settings: TravelModeSettings(hotspotSSID: "iPhone", hotspotPassword: "secret", wifiDevice: "en0")
        )

        await appState.start()
        await appState.stop()

        XCTAssertEqual(gateway.wifiPowerChanges, [false])
    }

    func testStopRestoresSleepAndTtysKeepAwakeSnapshot() async {
        let powerSettings = PowerSettingsSnapshot(
            battery: PowerProfileSettings(sleep: 1, ttysKeepAwake: 0),
            ac: PowerProfileSettings(sleep: 30, ttysKeepAwake: 0)
        )
        let gateway = StubGateway(
            statuses: [
                WiFiStatus(device: "en0", networkName: "Office", rawOutput: "Current Wi-Fi Network: Office")
            ],
            codexRunning: true,
            lidClosedSleepOverride: false,
            powerSettings: powerSettings,
            wifiPower: true
        )
        let appState = makeAppState(
            gateway: gateway,
            settings: TravelModeSettings(hotspotSSID: "iPhone", hotspotPassword: "secret", wifiDevice: "en0")
        )

        await appState.start()
        await appState.stop()

        XCTAssertEqual(gateway.restoredPowerSettings, [powerSettings])
    }

    func testOpenWiFiSettingsDelegatesToGateway() async {
        let gateway = StubGateway()
        let appState = makeAppState(gateway: gateway)

        await appState.openWiFiSettings()

        XCTAssertEqual(gateway.didOpenWiFiSettings, true)
    }

    func testRefreshStatusTracksCodexRunning() async {
        let gateway = StubGateway(
            statuses: [
                WiFiStatus(device: "en0", networkName: "Office", rawOutput: "Current Wi-Fi Network: Office")
            ],
            codexRunning: true
        )
        let appState = makeAppState(gateway: gateway)
        appState.settings.wifiDevice = "en0"

        await appState.refreshStatus()

        XCTAssertEqual(appState.isCodexRunning, true)
    }

    func testStartRequiresCodexRunning() async {
        let gateway = StubGateway(codexRunning: false)
        let appState = makeAppState(
            gateway: gateway,
            settings: TravelModeSettings(hotspotSSID: "iPhone", hotspotPassword: "secret", wifiDevice: "en0")
        )

        await appState.start()

        XCTAssertEqual(appState.isRunning, false)
        XCTAssertEqual(appState.latestStatus, "Cannot start: Codex is not running.")
        XCTAssertEqual(gateway.lidOverrideChanges, [])
    }

    func testStartRequiresSavedHotspotPassword() async {
        let gateway = StubGateway(codexRunning: true)
        let appState = makeAppState(
            gateway: gateway,
            settings: TravelModeSettings(hotspotSSID: "iPhone", hotspotPassword: "", wifiDevice: "en0")
        )

        await appState.start()

        XCTAssertEqual(appState.isRunning, false)
        XCTAssertEqual(appState.latestStatus, "Cannot start: save the hotspot password first.")
        XCTAssertEqual(gateway.lidOverrideChanges, [])
    }

    func testStartWhileDisconnectedDoesNotImmediatelyJoinFallback() async {
        let gateway = StubGateway(
            statuses: [
                WiFiStatus(
                    device: "en0",
                    networkName: nil,
                    rawOutput: "You are not associated with an AirPort network."
                )
            ],
            codexRunning: true
        )
        let appState = makeAppState(gateway: gateway)
        appState.settings = TravelModeSettings(
            hotspotSSID: "iPhone",
            hotspotPassword: "secret",
            wifiDevice: "en0"
        )

        await appState.syncOnce()

        XCTAssertEqual(gateway.joinAttempts, [])
        XCTAssertEqual(
            appState.latestStatus,
            "Travel Mode active; waiting for a connected Wi-Fi network to disconnect."
        )
    }

    func testRunningTravelModeJoinsFallbackAfterInitialDisconnectedState() async {
        let gateway = StubGateway(
            statuses: [
                WiFiStatus(
                    device: "en0",
                    networkName: nil,
                    rawOutput: "You are not associated with an AirPort network."
                ),
                WiFiStatus(
                    device: "en0",
                    networkName: nil,
                    rawOutput: "Wi-Fi power is currently off."
                ),
                WiFiStatus(device: "en0", networkName: "iPhone", rawOutput: "Current Wi-Fi Network: iPhone")
            ],
            codexRunning: true
        )
        let appState = makeAppState(
            gateway: gateway,
            settings: TravelModeSettings(
                hotspotSSID: "iPhone",
                hotspotPassword: "secret",
                wifiDevice: "en0"
            )
        )

        await appState.start()
        await appState.syncOnce()
        await appState.stop()

        XCTAssertEqual(gateway.joinAttempts, [JoinAttempt(device: "en0", ssid: "iPhone", password: "secret")])
    }

    func testWiFiStatusCommandFailureIsShownInsteadOfWaitingForDisconnect() async {
        let gateway = StubGateway(
            statuses: [
                WiFiStatus(
                    device: "en0",
                    networkName: nil,
                    rawOutput: "AuthorizationCreate() failed: -60008"
                )
            ]
        )
        let appState = makeAppState(
            gateway: gateway,
            settings: TravelModeSettings(hotspotSSID: "iPhone", wifiDevice: "en0")
        )

        await appState.syncOnce()

        XCTAssertEqual(gateway.joinAttempts, [])
        XCTAssertEqual(
            appState.latestStatus,
            "Could not read Wi-Fi status: AuthorizationCreate() failed: -60008"
        )
    }

    func testStartWhileConnectedArmsFallbackWithoutJoiningHotspot() async {
        let gateway = StubGateway(
            statuses: [
                WiFiStatus(device: "en0", networkName: "CIC", rawOutput: "Current Wi-Fi Network: CIC")
            ],
            codexRunning: true
        )
        let appState = makeAppState(
            gateway: gateway,
            settings: TravelModeSettings(
                hotspotSSID: "iPhone",
                hotspotPassword: "secret",
                wifiDevice: "en0"
            )
        )

        await appState.start()
        await appState.stop()

        XCTAssertEqual(
            appState.logs,
            [
                "Travel Mode started",
                "Watching Wi-Fi 'CIC'; fallback will run if it disconnects.",
                "Travel Mode stopped"
            ]
        )
        XCTAssertEqual(gateway.joinAttempts, [])
    }

    func testStartConnectedThenManualDisconnectJoinsFallbackHotspot() async {
        let gateway = StubGateway(
            statuses: [
                WiFiStatus(device: "en0", networkName: "CIC", rawOutput: "Current Wi-Fi Network: CIC"),
                WiFiStatus(
                    device: "en0",
                    networkName: nil,
                    rawOutput: "You are not associated with an AirPort network."
                ),
                WiFiStatus(device: "en0", networkName: "iPhone", rawOutput: "Current Wi-Fi Network: iPhone")
            ],
            codexRunning: true
        )
        let appState = makeAppState(
            gateway: gateway,
            settings: TravelModeSettings(
                hotspotSSID: "iPhone",
                hotspotPassword: "secret",
                wifiDevice: "en0"
            )
        )

        await appState.start()
        await appState.syncOnce()
        await appState.stop()

        XCTAssertEqual(gateway.joinAttempts, [JoinAttempt(device: "en0", ssid: "iPhone", password: "secret")])
    }

    func testClosedLidForcesFallbackEvenWhileWiFiIsConnected() async {
        let gateway = StubGateway(
            statuses: [
                WiFiStatus(device: "en0", networkName: "CIC", rawOutput: "Current Wi-Fi Network: CIC"),
                WiFiStatus(device: "en0", networkName: "CIC", rawOutput: "Current Wi-Fi Network: CIC"),
                WiFiStatus(device: "en0", networkName: "iPhone", rawOutput: "Current Wi-Fi Network: iPhone")
            ],
            codexRunning: true,
            lidClosed: true
        )
        let appState = makeAppState(
            gateway: gateway,
            settings: TravelModeSettings(
                hotspotSSID: "iPhone",
                hotspotPassword: "secret",
                wifiDevice: "en0"
            )
        )

        await appState.start()
        await appState.syncOnce()

        XCTAssertEqual(gateway.joinAttempts, [JoinAttempt(device: "en0", ssid: "iPhone", password: "secret")])
        XCTAssertEqual(appState.latestStatus, "Connected to hotspot 'iPhone'")
    }

    func testFallbackJoinsOnlyAfterConnectedNetworkIsLost() async {
        let gateway = StubGateway(
            statuses: [
                WiFiStatus(device: "en0", networkName: "CIC", rawOutput: "Current Wi-Fi Network: CIC"),
                WiFiStatus(
                    device: "en0",
                    networkName: nil,
                    rawOutput: "You are not associated with an AirPort network."
                ),
                WiFiStatus(device: "en0", networkName: "iPhone", rawOutput: "Current Wi-Fi Network: iPhone")
            ]
        )
        let appState = makeAppState(
            gateway: gateway,
            settings: TravelModeSettings(
                hotspotSSID: "iPhone",
                hotspotPassword: "secret",
                wifiDevice: "en0"
            )
        )

        await appState.syncOnce()
        await appState.syncOnce()

        XCTAssertEqual(gateway.joinAttempts, [JoinAttempt(device: "en0", ssid: "iPhone", password: "secret")])
    }

    func testConnectedNetworkStatusSaysFallbackRunsIfItDisconnects() async {
        let gateway = StubGateway(
            statuses: [
                WiFiStatus(device: "en0", networkName: "CIC", rawOutput: "Current Wi-Fi Network: CIC")
            ]
        )
        let appState = makeAppState(
            gateway: gateway,
            settings: TravelModeSettings(
                hotspotSSID: "iPhone",
                hotspotPassword: "secret",
                wifiDevice: "en0"
            )
        )

        await appState.syncOnce()

        XCTAssertEqual(
            appState.latestStatus,
            "Watching Wi-Fi 'CIC'; fallback will run if it disconnects."
        )
        XCTAssertEqual(gateway.joinAttempts, [])
    }
}

private final class InMemorySettingsStore: TravelSettingsStoring, @unchecked Sendable {
    private let loadedSettings: TravelModeSettings
    var savedSettings: TravelModeSettings?
    var restoreSnapshot: TravelRestoreSnapshot?

    init(settings: TravelModeSettings) {
        self.loadedSettings = settings
    }

    func load() -> TravelModeSettings {
        loadedSettings
    }

    func hasSavedHotspotPassword() -> Bool {
        !loadedSettings.trimmedHotspotPassword.isEmpty
    }

    func loadHotspotPassword() throws -> String {
        loadedSettings.hotspotPassword
    }

    func save(_ settings: TravelModeSettings) throws {
        savedSettings = settings
    }

    func loadRestoreSnapshot() -> TravelRestoreSnapshot? {
        restoreSnapshot
    }

    func saveRestoreSnapshot(_ snapshot: TravelRestoreSnapshot) {
        restoreSnapshot = snapshot
    }

    func clearRestoreSnapshot() {
        restoreSnapshot = nil
    }
}

private struct JoinAttempt: Equatable, Sendable {
    var device: String
    var ssid: String
    var password: String?
}

private final class PasswordProviderSpy: @unchecked Sendable {
    private let storedPassword: String
    var readCount = 0

    init(password: String) {
        self.storedPassword = password
    }

    func password() -> String {
        readCount += 1
        return storedPassword
    }
}

private final class StubGateway: TravelCommandGateway, @unchecked Sendable {
    private var statuses: [WiFiStatus]
    private let discoveredDevice: String?
    private let knownNetworks: [String]
    private let scannedNetworks: [String]
    private let codexRunning: Bool
    private let lidClosedSleepOverride: Bool?
    private let powerSettings: PowerSettingsSnapshot?
    private let lidClosed: Bool?
    private let wifiPower: Bool?
    var joinAttempts: [JoinAttempt] = []
    var wifiPowerChanges: [Bool] = []
    var lidOverrideChanges: [Bool] = []
    var restoredPowerSettings: [PowerSettingsSnapshot] = []
    var didOpenWiFiSettings = false
    var commandsStarted = false

    init(
        statuses: [WiFiStatus] = [],
        discoveredDevice: String? = nil,
        knownNetworks: [String] = [],
        scannedNetworks: [String] = [],
        codexRunning: Bool = false,
        lidClosedSleepOverride: Bool? = nil,
        powerSettings: PowerSettingsSnapshot? = nil,
        lidClosed: Bool? = false,
        wifiPower: Bool? = nil
    ) {
        self.statuses = statuses
        self.discoveredDevice = discoveredDevice
        self.knownNetworks = knownNetworks
        self.scannedNetworks = scannedNetworks
        self.codexRunning = codexRunning
        self.lidClosedSleepOverride = lidClosedSleepOverride
        self.powerSettings = powerSettings
        self.lidClosed = lidClosed
        self.wifiPower = wifiPower
    }

    func discoverWiFiDevice() async -> String? {
        discoveredDevice
    }

    func knownWiFiNetworks(device: String) async -> [String] {
        knownNetworks
    }

    func scanWiFiNetworks(device: String) async -> [String] {
        scannedNetworks
    }

    func startKeepAwake() async throws {
        commandsStarted = true
    }

    func stopKeepAwake() async {}

    func currentLidClosedSleepOverride() async -> Bool? {
        lidClosedSleepOverride
    }

    func setLidClosedSleepOverride(enabled: Bool) async throws {
        commandsStarted = true
        lidOverrideChanges.append(enabled)
    }

    func currentPowerSettings() async -> PowerSettingsSnapshot? {
        powerSettings
    }

    func restorePowerSettings(_ snapshot: PowerSettingsSnapshot) async throws {
        restoredPowerSettings.append(snapshot)
    }

    func currentLidClosed() async -> Bool? {
        lidClosed
    }

    func currentWiFiStatus(device: String) async -> WiFiStatus {
        if statuses.isEmpty {
            return WiFiStatus(device: device, networkName: nil, rawOutput: "")
        }
        return statuses.removeFirst()
    }

    func currentWiFiPower(device: String) async -> Bool? {
        wifiPower
    }

    func setWiFiPower(device: String, enabled: Bool) async {
        wifiPowerChanges.append(enabled)
    }

    func joinWiFi(device: String, ssid: String, password: String?) async -> CommandResult {
        joinAttempts.append(JoinAttempt(device: device, ssid: ssid, password: password))
        return CommandResult(exitCode: 0)
    }

    func openWiFiSettings() async {
        didOpenWiFiSettings = true
    }

    func isCodexRunning() async -> Bool {
        codexRunning
    }
}
