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

    func testCurrentWiFiStatusNeverSynthesizesSSIDFromRouteAndAddress() async {
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

        XCTAssertNil(status.networkName)
        XCTAssertFalse(status.commandFailed)
        XCTAssertEqual(runner.commands.map(\.arguments), [
            ["-getairportnetwork", "en0"]
        ])
    }

    func testSessionBaselineDoesNotPersistRouteOnlyConnectionLabelAsSSID() async throws {
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
        let controller = GatewayTravelSessionSystemController(gateway: gateway)

        let baselineSSID = try await controller.currentAssociatedSSID(device: "en0")

        XCTAssertNil(baselineSSID)
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

    func testParseWiFiPower() {
        XCTAssertEqual(parseWiFiPower("Wi-Fi Power (en0): On\n"), true)
        XCTAssertEqual(parseWiFiPower("Wi-Fi Power (en0): Off\n"), false)
        XCTAssertNil(parseWiFiPower("AuthorizationCreate() failed: -60008\n"))
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

    func testJoinWiFiDoesNotRepeatSuccessfulNetworksetupAssociation() async {
        let runner = RecordingRunner()
        let associationManager = RecordingAssociationManager(associateResult: CommandResult(exitCode: 0))
        let gateway = LocalTravelCommandGateway(
            runner: runner,
            associationManager: associationManager
        )

        let result = await gateway.joinWiFi(device: "en0", ssid: "iPhone", password: "secret")

        XCTAssertTrue(result.succeeded)
        XCTAssertTrue(associationManager.associateAttempts.isEmpty)
    }

    func testSetWiFiPowerReturnsSuccessfulAssociationManagerResult() async {
        let runner = RecordingRunner()
        let associationManager = RecordingAssociationManager()
        let gateway = LocalTravelCommandGateway(
            runner: runner,
            associationManager: associationManager
        )

        let result = await gateway.setWiFiPower(device: "en0", enabled: true)

        XCTAssertTrue(result.succeeded)
        XCTAssertEqual(associationManager.powerAttempts, [PowerAttempt(device: "en0", enabled: true)])
        XCTAssertNil(runner.commands.last)
    }

    func testBoundedPowerMutationUsesProcessDeadlineAndClassifiesTimeout() async {
        let runner = TimeoutRecordingRunner(
            output: ShellCommandOutput(
                exitCode: 124,
                standardOutput: "",
                standardError: "Command timed out and was terminated."
            )
        )
        let gateway = LocalTravelCommandGateway(runner: runner)

        let result = await gateway.setWiFiPower(
            device: "en0",
            enabled: true,
            timeout: .milliseconds(250)
        )

        XCTAssertEqual(result.failureCategory, .timedOut)
        XCTAssertEqual(runner.commands.map(\.arguments), [
            ["-setairportpower", "en0", "on"]
        ])
        XCTAssertEqual(runner.timeouts, [.milliseconds(250)])
    }

    func testCodexRunningUsesExactLiveBundleIdentityWithoutShellCommands() async {
        let runner = RecordingRunner()
        let applications = StubRunningApplicationProvider(applications: [
            RunningApplicationIdentity(
                bundleIdentifier: "com.openai.codex",
                isTerminated: false
            )
        ])
        let gateway = LocalTravelCommandGateway(
            runner: runner,
            runningApplicationProvider: applications
        )

        let isRunning = await gateway.isCodexRunning()

        XCTAssertTrue(isRunning)
        XCTAssertTrue(runner.commands.isEmpty)
    }

    func testCodexNotRunningForTerminatedOrDifferentBundleIdentity() async {
        let applications = StubRunningApplicationProvider(applications: [
            RunningApplicationIdentity(
                bundleIdentifier: "com.openai.codex",
                isTerminated: true
            ),
            RunningApplicationIdentity(
                bundleIdentifier: "com.openai.chatgpt",
                isTerminated: false
            ),
            RunningApplicationIdentity(bundleIdentifier: nil, isTerminated: false)
        ])
        let gateway = LocalTravelCommandGateway(runningApplicationProvider: applications)

        let isRunning = await gateway.isCodexRunning()

        XCTAssertFalse(isRunning)
    }

    func testLiveCodexWorkspaceDetectionWhenRequired() async throws {
        guard ProcessInfo.processInfo.environment["REQUIRE_LIVE_CODEX_RUNNING"] == "1" else {
            throw XCTSkip("Live Codex workspace detection is exercised by the lifecycle proof.")
        }

        let gateway = LocalTravelCommandGateway()
        let isRunning = await gateway.isCodexRunning()

        XCTAssertTrue(
            isRunning,
            "Expected the running com.openai.codex desktop bundle to satisfy readiness."
        )
    }

    func testSettingsLoadDoesNotReadKeychainPassword() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("settings-load-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let defaults = UserDefaults(suiteName: "CodexTravelModeTests.\(UUID().uuidString)")!
        defaults.set("iPhone", forKey: "fallbackHotspotSSID")
        defaults.set("en0", forKey: "wifiDevice")
        let keychain = SpyKeychainPasswordStore(
            passwords: ["fallbackHotspotPassword": "secret"]
        )
        let store = FileTravelSettingsStore(
            rootURL: root,
            defaults: defaults,
            keychain: keychain
        )
        let readsAfterMigration = keychain.readAccounts

        let settings = store.load()

        XCTAssertEqual(settings.hotspotSSID, "iPhone")
        XCTAssertEqual(settings.hotspotPassword, "")
        XCTAssertEqual(settings.wifiDevice, "en0")
        XCTAssertFalse(readsAfterMigration.isEmpty)
        XCTAssertEqual(keychain.readAccounts, readsAfterMigration)
        XCTAssertNotNil(try store.activeHotspotConfiguration())
    }

    func testSettingsSaveWithBlankPasswordPreservesSavedKeychainPassword() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("settings-blank-save-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let defaults = UserDefaults(suiteName: "CodexTravelModeTests.\(UUID().uuidString)")!
        let keychain = SpyKeychainPasswordStore()
        let store = FileTravelSettingsStore(
            rootURL: root,
            defaults: defaults,
            keychain: keychain
        )

        try store.save(
            TravelModeSettings(
                hotspotSSID: "iPhone",
                hotspotPassword: "secret",
                wifiDevice: "en0"
            )
        )
        let seeded = try XCTUnwrap(store.activeHotspotConfiguration())
        let stagedCredentialCount = keychain.savedPasswords.count

        try store.save(
            TravelModeSettings(
                hotspotSSID: "iPhone",
                hotspotPassword: "",
                wifiDevice: "en1"
            )
        )

        let committed = try XCTUnwrap(store.activeHotspotConfiguration())
        XCTAssertEqual(committed.ssid, "iPhone")
        XCTAssertEqual(committed.wifiDevice, "en1")
        XCTAssertEqual(committed.credentialReference, seeded.credentialReference)
        XCTAssertEqual(keychain.savedPasswords.count, stagedCredentialCount)
        XCTAssertTrue(try keychain.passwordExists(account: committed.credentialReference))
        XCTAssertEqual(try store.loadHotspotPassword(), "secret")
    }

    func testSettingsSaveTracksWhetherPasswordWasSaved() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("settings-save-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let defaults = UserDefaults(suiteName: "CodexTravelModeTests.\(UUID().uuidString)")!
        let keychain = SpyKeychainPasswordStore()
        let store = FileTravelSettingsStore(
            rootURL: root,
            defaults: defaults,
            keychain: keychain
        )

        XCTAssertEqual(store.hasSavedHotspotPassword(), false)

        try store.save(
            TravelModeSettings(
                hotspotSSID: "iPhone",
                hotspotPassword: "secret",
                wifiDevice: "en0"
            )
        )

        let active = try XCTUnwrap(store.activeHotspotConfiguration())
        XCTAssertEqual(active.ssid, "iPhone")
        XCTAssertEqual(active.wifiDevice, "en0")
        XCTAssertTrue(try keychain.passwordExists(account: active.credentialReference))
        XCTAssertEqual(try store.loadHotspotPassword(), "secret")
        XCTAssertEqual(store.hasSavedHotspotPassword(), true)
    }

}

private final class SpyKeychainPasswordStore: KeychainPasswordStoring, @unchecked Sendable {
    private var passwords: [String: String]
    var readAccounts: [String] = []
    var savedPasswords: [(password: String, account: String)] = []
    var deletedAccounts: [String] = []

    init(passwords: [String: String] = [:]) {
        self.passwords = passwords
    }

    func readPassword(account: String) throws -> String {
        readAccounts.append(account)
        guard let password = passwords[account] else {
            throw KeychainError.notFound
        }
        return password
    }

    func savePassword(_ password: String, account: String) throws {
        passwords[account] = password
        savedPasswords.append((password: password, account: account))
    }

    func passwordExists(account: String) throws -> Bool {
        passwords[account] != nil
    }

    func deletePassword(account: String) throws {
        passwords.removeValue(forKey: account)
        deletedAccounts.append(account)
    }
}

private struct StubRunningApplicationProvider: RunningApplicationProviding {
    var applications: [RunningApplicationIdentity]

    func runningApplications() async -> [RunningApplicationIdentity] {
        applications
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

private final class TimeoutRecordingRunner: ShellCommandRunning, @unchecked Sendable {
    private let output: ShellCommandOutput
    var commands: [RecordingRunner.Command] = []
    var timeouts: [Duration] = []

    init(output: ShellCommandOutput) {
        self.output = output
    }

    func run(_ executableURL: URL, arguments: [String]) async -> ShellCommandOutput {
        commands.append(RecordingRunner.Command(path: executableURL.path, arguments: arguments))
        return output
    }

    func run(
        _ executableURL: URL,
        arguments: [String],
        timeout: Duration
    ) async -> ShellCommandOutput {
        commands.append(RecordingRunner.Command(path: executableURL.path, arguments: arguments))
        timeouts.append(timeout)
        return output
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
