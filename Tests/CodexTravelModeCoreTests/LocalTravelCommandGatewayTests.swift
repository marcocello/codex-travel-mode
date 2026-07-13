import CodexTravelModeCore
import Foundation
import XCTest

final class LocalTravelCommandGatewayTests: XCTestCase {
    func testParseNetworkNameFromNetworksetupOutput() {
        XCTAssertEqual(
            parseNetworkName("Current Wi-Fi Network: Office\n"),
            "Office"
        )
    }

    func testParseNetworkNameReturnsNilWhenNotAssociated() {
        XCTAssertNil(parseNetworkName("You are not associated with an AirPort network.\n"))
    }

    func testParseDefaultRouteInterface() {
        let output = """
           route to: default
        destination: default
            gateway: 10.0.0.1
          interface: en0
        """

        XCTAssertEqual(parseDefaultRouteInterface(output), "en0")
    }

    func testParseIPv4Address() {
        XCTAssertEqual(parseIPv4Address("10.0.0.124\n"), "10.0.0.124")
        XCTAssertNil(parseIPv4Address("ipconfig_server_port failed\n"))
    }

    func testCurrentWiFiStatusUsesDefaultRouteWhenSSIDIsUnavailable() async {
        let runner = OrderedOutputRunner(
            outputs: [
                ShellCommandOutput(
                    exitCode: 0,
                    standardOutput: "You are not associated with an AirPort network.\n",
                    standardError: ""
                ),
                ShellCommandOutput(
                    exitCode: 0,
                    standardOutput: "interface: en0\n",
                    standardError: ""
                ),
                ShellCommandOutput(
                    exitCode: 0,
                    standardOutput: "10.0.0.124\n",
                    standardError: ""
                )
            ]
        )
        let gateway = LocalTravelCommandGateway(runner: runner)

        let status = await gateway.currentWiFiStatus(device: "en0")

        XCTAssertEqual(status.networkName, "Connected on en0")
        XCTAssertFalse(status.commandFailed)
        XCTAssertEqual(runner.commands.map(\.arguments), [
            ["-getairportnetwork", "en0"],
            ["-n", "get", "default"],
            ["getifaddr", "en0"]
        ])
    }

    func testParseWiFiDeviceFromHardwarePorts() {
        let output = """
        Hardware Port: Ethernet
        Device: en7

        Hardware Port: Wi-Fi
        Device: en0
        """

        XCTAssertEqual(parseWiFiDevice(output), "en0")
    }

    func testParsePreferredNetworksSkipsHeaderAndTrimsValues() {
        let output = """
        Preferred networks on en0:
            Office
            iPhone
        """

        XCTAssertEqual(parsePreferredNetworks(output), ["Office", "iPhone"])
    }

    func testParseScannedNetworksExtractsSSIDBeforeBSSID() {
        let output = """
                            SSID BSSID             RSSI CHANNEL HT CC SECURITY
                          Office 00:11:22:33:44:55 -48  11      Y  US WPA2
                          iPhone aa:bb:cc:dd:ee:ff -50  6       Y  US WPA2
        """

        XCTAssertEqual(parseScannedNetworks(output), ["Office", "iPhone"])
    }

    func testParseWiFiPower() {
        XCTAssertEqual(parseWiFiPower("Wi-Fi Power (en0): On\n"), true)
        XCTAssertEqual(parseWiFiPower("Wi-Fi Power (en0): Off\n"), false)
        XCTAssertNil(parseWiFiPower("AuthorizationCreate() failed: -60008\n"))
    }

    func testParseDisablesleep() {
        let output = """
        Battery Power:
         disablesleep        0
        AC Power:
         disablesleep        1
        """

        XCTAssertEqual(parseDisablesleep(output), false)
    }

    func testParsePowerSettingsSnapshot() {
        let output = """
        Battery Power:
         sleep                1
         ttyskeepawake        1
        AC Power:
         sleep                0
         ttyskeepawake        1
        """

        XCTAssertEqual(
            parsePowerSettingsSnapshot(output),
            PowerSettingsSnapshot(
                battery: PowerProfileSettings(sleep: 1, ttysKeepAwake: 1),
                ac: PowerProfileSettings(sleep: 0, ttysKeepAwake: 1)
            )
        )
    }

    func testPmsetRestoreCommandsIncludeSleepAndTtysKeepAwake() {
        let snapshot = PowerSettingsSnapshot(
            battery: PowerProfileSettings(sleep: 1, ttysKeepAwake: 0),
            ac: PowerProfileSettings(sleep: 30, ttysKeepAwake: 0)
        )

        XCTAssertEqual(
            pmsetRestoreCommands(snapshot),
            [
                "pmset -b sleep 1 ttyskeepawake 0",
                "pmset -c sleep 30 ttyskeepawake 0"
            ]
        )
    }

    func testParseSleepDisabledFromLivePmsetOutput() {
        let output = """
        System-wide power settings:
         SleepDisabled        1
        Currently in use:
         sleep                1
        """

        XCTAssertEqual(parseDisablesleep(output), true)
    }

    func testParseClamshellClosed() {
        XCTAssertEqual(parseClamshellClosed(#""AppleClamshellState" = Yes"#), true)
        XCTAssertEqual(parseClamshellClosed(#""AppleClamshellState" = No"#), false)
        XCTAssertNil(parseClamshellClosed(#""AppleClamshellCausesSleep" = Yes"#))
    }

    func testKeepAwakeArgumentsAreTiedToAppProcess() {
        XCTAssertEqual(keepAwakeArguments(processID: 12345), ["-dim", "-w", "12345"])
    }

    func testJoinWiFiIncludesPasswordWhenProvided() async {
        let runner = RecordingRunner()
        let gateway = LocalTravelCommandGateway(runner: runner)

        _ = await gateway.joinWiFi(device: "en0", ssid: "iPhone", password: "secret")

        XCTAssertEqual(
            runner.commands.last?.arguments,
            ["-setairportnetwork", "en0", "iPhone", "secret"]
        )
    }

    func testJoinWiFiUsesPasswordWithAssociationManagerWhenProvided() async {
        let runner = RecordingRunner()
        let associationManager = RecordingAssociationManager(associateResult: CommandResult(exitCode: 0))
        let gateway = LocalTravelCommandGateway(
            runner: runner,
            associationManager: associationManager
        )

        let result = await gateway.joinWiFi(device: "en0", ssid: "iPhone", password: "secret")

        XCTAssertTrue(result.succeeded)
        XCTAssertEqual(
            associationManager.associateAttempts,
            [AssociationAttempt(device: "en0", ssid: "iPhone", password: "secret")]
        )
    }

    func testSetWiFiPowerUsesAssociationManagerBeforeNetworksetup() async {
        let runner = RecordingRunner()
        let associationManager = RecordingAssociationManager()
        let gateway = LocalTravelCommandGateway(
            runner: runner,
            associationManager: associationManager
        )

        await gateway.setWiFiPower(device: "en0", enabled: true)

        XCTAssertEqual(associationManager.powerAttempts, [PowerAttempt(device: "en0", enabled: true)])
        XCTAssertEqual(runner.commands.last?.arguments, ["-setairportpower", "en0", "on"])
    }

    func testRestorePowerSettingsUsesAdministratorPmsetScript() async throws {
        let runner = RecordingRunner()
        let gateway = LocalTravelCommandGateway(runner: runner)
        let snapshot = PowerSettingsSnapshot(
            battery: PowerProfileSettings(sleep: 1, ttysKeepAwake: 0),
            ac: PowerProfileSettings(sleep: 30, ttysKeepAwake: 0)
        )

        try await gateway.restorePowerSettings(snapshot)

        let script = try XCTUnwrap(runner.commands.last?.arguments.last)
        XCTAssertEqual(runner.commands.last?.path, "/usr/bin/osascript")
        XCTAssertTrue(script.contains("pmset -b sleep 1 ttyskeepawake 0"))
        XCTAssertTrue(script.contains("pmset -c sleep 30 ttyskeepawake 0"))
        XCTAssertTrue(script.contains("with administrator privileges"))
    }

    func testCodexRunningUsesExactProcessName() async {
        let runner = RecordingRunner(output: ShellCommandOutput(exitCode: 0, standardOutput: "123\n", standardError: ""))
        let gateway = LocalTravelCommandGateway(runner: runner)

        let isRunning = await gateway.isCodexRunning()

        XCTAssertEqual(isRunning, true)
        XCTAssertEqual(runner.commands.last?.arguments, ["-x", "Codex"])
    }

    func testCodexNotRunningWhenExactProcessIsMissing() async {
        let runner = RecordingRunner(output: ShellCommandOutput(exitCode: 1, standardOutput: "", standardError: ""))
        let gateway = LocalTravelCommandGateway(runner: runner)

        let isRunning = await gateway.isCodexRunning()

        XCTAssertEqual(isRunning, false)
    }

    func testLidClosedOverrideAdminPromptExplainsWhyPermissionIsNeeded() async throws {
        let runner = RecordingRunner()
        let gateway = LocalTravelCommandGateway(runner: runner)

        try await gateway.setLidClosedSleepOverride(enabled: true)

        let script = try XCTUnwrap(runner.commands.last?.arguments.last)
        XCTAssertTrue(script.contains("with administrator privileges"))
        XCTAssertTrue(script.contains("Codex Travel Mode needs an administrator password"))
    }

    func testSettingsLoadDoesNotReadKeychainPassword() {
        let defaults = UserDefaults(suiteName: "CodexTravelModeTests.\(UUID().uuidString)")!
        defaults.set("iPhone", forKey: "fallbackHotspotSSID")
        defaults.set("en0", forKey: "wifiDevice")
        let keychain = SpyKeychainPasswordStore(password: "secret")
        let store = UserDefaultsTravelSettingsStore(defaults: defaults, keychain: keychain)

        let settings = store.load()

        XCTAssertEqual(settings.hotspotSSID, "iPhone")
        XCTAssertEqual(settings.hotspotPassword, "")
        XCTAssertEqual(settings.wifiDevice, "en0")
        XCTAssertEqual(keychain.readAccounts, [])
    }

    func testSettingsSaveWithBlankPasswordPreservesSavedKeychainPassword() throws {
        let defaults = UserDefaults(suiteName: "CodexTravelModeTests.\(UUID().uuidString)")!
        let keychain = SpyKeychainPasswordStore(password: "secret")
        let store = UserDefaultsTravelSettingsStore(defaults: defaults, keychain: keychain)

        try store.save(
            TravelModeSettings(
                hotspotSSID: "iPhone",
                hotspotPassword: "",
                wifiDevice: "en0"
            )
        )

        XCTAssertEqual(defaults.string(forKey: "fallbackHotspotSSID"), "iPhone")
        XCTAssertEqual(defaults.string(forKey: "wifiDevice"), "en0")
        XCTAssertTrue(keychain.savedPasswords.isEmpty)
    }

    func testSettingsSaveTracksWhetherPasswordWasSaved() throws {
        let defaults = UserDefaults(suiteName: "CodexTravelModeTests.\(UUID().uuidString)")!
        let keychain = SpyKeychainPasswordStore(password: "secret")
        let store = UserDefaultsTravelSettingsStore(defaults: defaults, keychain: keychain)

        XCTAssertEqual(store.hasSavedHotspotPassword(), false)

        try store.save(
            TravelModeSettings(
                hotspotSSID: "iPhone",
                hotspotPassword: "secret",
                wifiDevice: "en0"
            )
        )

        XCTAssertEqual(store.hasSavedHotspotPassword(), true)
    }

    func testSettingsStorePersistsRestoreSnapshotUntilCleared() {
        let defaults = UserDefaults(suiteName: "CodexTravelModeTests.\(UUID().uuidString)")!
        let keychain = SpyKeychainPasswordStore(password: "secret")
        let store = UserDefaultsTravelSettingsStore(defaults: defaults, keychain: keychain)
        let snapshot = TravelRestoreSnapshot(
            lidClosedSleepOverrideEnabled: false,
            wifiDevice: "en0",
            wifiPowerEnabled: true
        )

        store.saveRestoreSnapshot(snapshot)

        XCTAssertEqual(store.loadRestoreSnapshot(), snapshot)

        store.clearRestoreSnapshot()

        XCTAssertNil(store.loadRestoreSnapshot())
    }
}

private final class SpyKeychainPasswordStore: KeychainPasswordStoring, @unchecked Sendable {
    private let password: String
    var readAccounts: [String] = []
    var savedPasswords: [(password: String, account: String)] = []

    init(password: String) {
        self.password = password
    }

    func readPassword(account: String) throws -> String {
        readAccounts.append(account)
        return password
    }

    func savePassword(_ password: String, account: String) throws {
        savedPasswords.append((password: password, account: account))
    }
}

private final class RecordingRunner: ShellCommandRunning, @unchecked Sendable {
    struct Command: Equatable {
        var path: String
        var arguments: [String]
    }

    var commands: [Command] = []
    private let output: ShellCommandOutput

    init(output: ShellCommandOutput = ShellCommandOutput(exitCode: 0, standardOutput: "", standardError: "")) {
        self.output = output
    }

    func run(_ executableURL: URL, arguments: [String]) async -> ShellCommandOutput {
        commands.append(Command(path: executableURL.path, arguments: arguments))
        return output
    }
}

private final class OrderedOutputRunner: ShellCommandRunning, @unchecked Sendable {
    var commands: [RecordingRunner.Command] = []
    private var outputs: [ShellCommandOutput]

    init(outputs: [ShellCommandOutput]) {
        self.outputs = outputs
    }

    func run(_ executableURL: URL, arguments: [String]) async -> ShellCommandOutput {
        commands.append(RecordingRunner.Command(path: executableURL.path, arguments: arguments))
        guard !outputs.isEmpty else {
            return ShellCommandOutput(
                exitCode: 1,
                standardOutput: "",
                standardError: "No output configured."
            )
        }
        return outputs.removeFirst()
    }
}

private struct AssociationAttempt: Equatable {
    var device: String
    var ssid: String
    var password: String
}

private struct PowerAttempt: Equatable {
    var device: String
    var enabled: Bool
}

private final class RecordingAssociationManager: WiFiAssociationManaging, @unchecked Sendable {
    private let associateResult: CommandResult
    var associateAttempts: [AssociationAttempt] = []
    var powerAttempts: [PowerAttempt] = []

    init(associateResult: CommandResult = CommandResult(exitCode: 0)) {
        self.associateResult = associateResult
    }

    func setPower(device: String, enabled: Bool) async -> CommandResult {
        powerAttempts.append(PowerAttempt(device: device, enabled: enabled))
        return CommandResult(exitCode: 0)
    }

    func associate(device: String, ssid: String, password: String) async -> CommandResult {
        associateAttempts.append(AssociationAttempt(device: device, ssid: ssid, password: password))
        return associateResult
    }
}
