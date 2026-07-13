import CoreWLAN
import Foundation

public final class LocalTravelCommandGateway: TravelCommandGateway, @unchecked Sendable {
    private let runner: ShellCommandRunning
    private let associationManager: WiFiAssociationManaging?
    private let networksetupURL = URL(fileURLWithPath: "/usr/sbin/networksetup")
    private let osascriptURL = URL(fileURLWithPath: "/usr/bin/osascript")
    private let caffeinateURL = URL(fileURLWithPath: "/usr/bin/caffeinate")
    private let pmsetURL = URL(fileURLWithPath: "/usr/bin/pmset")
    private let routeURL = URL(fileURLWithPath: "/sbin/route")
    private let ipconfigURL = URL(fileURLWithPath: "/usr/sbin/ipconfig")
    private let openURL = URL(fileURLWithPath: "/usr/bin/open")
    private let ioregURL = URL(fileURLWithPath: "/usr/sbin/ioreg")
    private let pgrepURL = URL(fileURLWithPath: "/usr/bin/pgrep")
    private let airportURL = URL(
        fileURLWithPath: "/System/Library/PrivateFrameworks/Apple80211.framework/Versions/Current/Resources/airport"
    )
    private let keepAwakeStore = KeepAwakeProcessStore()

    public init(
        runner: ShellCommandRunning = ProcessShellCommandRunner(),
        associationManager: WiFiAssociationManaging? = nil
    ) {
        self.runner = runner
        self.associationManager = associationManager
    }

    public func startKeepAwake() async throws {
        try await keepAwakeStore.start(caffeinateURL: caffeinateURL)
    }

    public func stopKeepAwake() async {
        await keepAwakeStore.stop()
    }

    public func currentLidClosedSleepOverride() async -> Bool? {
        let output = await runner.run(pmsetURL, arguments: ["-g"])
        let raw = output.standardOutput.isEmpty ? output.standardError : output.standardOutput
        return parseDisablesleep(raw)
    }

    public func setLidClosedSleepOverride(enabled: Bool) async throws {
        let value = enabled ? "1" : "0"
        let reason = enabled
            ? "Codex Travel Mode needs an administrator password to keep the Mac awake with the lid closed."
            : "Codex Travel Mode needs an administrator password to restore normal lid-closed sleep."
        let script = """
        do shell script "pmset -a disablesleep \(value)" with administrator privileges with prompt "\(reason)"
        """
        let output = await runner.run(osascriptURL, arguments: ["-e", script])
        if output.exitCode != 0 {
            throw TravelCommandError.commandFailed(output.standardError)
        }
    }

    public func currentPowerSettings() async -> PowerSettingsSnapshot? {
        let output = await runner.run(pmsetURL, arguments: ["-g", "custom"])
        let raw = output.standardOutput.isEmpty ? output.standardError : output.standardOutput
        return parsePowerSettingsSnapshot(raw)
    }

    public func restorePowerSettings(_ snapshot: PowerSettingsSnapshot) async throws {
        let commands = pmsetRestoreCommands(snapshot)
        guard !commands.isEmpty else {
            return
        }
        let joinedCommands = commands.joined(separator: "; ")
        let reason = "Codex Travel Mode needs an administrator password to restore previous sleep settings."
        let script = """
        do shell script "\(joinedCommands)" with administrator privileges with prompt "\(reason)"
        """
        let output = await runner.run(osascriptURL, arguments: ["-e", script])
        if output.exitCode != 0 {
            throw TravelCommandError.commandFailed(output.standardError)
        }
    }

    public func currentLidClosed() async -> Bool? {
        let output = await runner.run(ioregURL, arguments: ["-r", "-k", "AppleClamshellState"])
        let raw = output.standardOutput.isEmpty ? output.standardError : output.standardOutput
        return parseClamshellClosed(raw)
    }

    public func discoverWiFiDevice() async -> String? {
        let output = await runner.run(networksetupURL, arguments: ["-listallhardwareports"])
        let raw = output.standardOutput.isEmpty ? output.standardError : output.standardOutput
        return parseWiFiDevice(raw)
    }

    public func knownWiFiNetworks(device: String) async -> [String] {
        let output = await runner.run(networksetupURL, arguments: ["-listpreferredwirelessnetworks", device])
        let raw = output.standardOutput.isEmpty ? output.standardError : output.standardOutput
        return parsePreferredNetworks(raw)
    }

    public func scanWiFiNetworks(device: String) async -> [String] {
        let output = await runner.run(airportURL, arguments: ["-s"])
        let raw = output.standardOutput.isEmpty ? output.standardError : output.standardOutput
        return parseScannedNetworks(raw)
    }

    public func currentWiFiStatus(device: String) async -> WiFiStatus {
        let output = await runner.run(networksetupURL, arguments: ["-getairportnetwork", device])
        let raw = output.standardOutput.isEmpty ? output.standardError : output.standardOutput
        if let networkName = parseNetworkName(raw) {
            return WiFiStatus(device: device, networkName: networkName, rawOutput: raw)
        }

        if await deviceHasDefaultRouteAndAddress(device) {
            return WiFiStatus(
                device: device,
                networkName: "Connected on \(device)",
                rawOutput: "\(device) has an IP address and owns the default route."
            )
        }

        return WiFiStatus(device: device, networkName: nil, rawOutput: raw)
    }

    public func currentWiFiPower(device: String) async -> Bool? {
        let output = await runner.run(networksetupURL, arguments: ["-getairportpower", device])
        let raw = output.standardOutput.isEmpty ? output.standardError : output.standardOutput
        return parseWiFiPower(raw)
    }

    public func setWiFiPower(device: String, enabled: Bool) async {
        _ = await associationManager?.setPower(device: device, enabled: enabled)
        _ = await runner.run(
            networksetupURL,
            arguments: ["-setairportpower", device, enabled ? "on" : "off"]
        )
    }

    public func joinWiFi(device: String, ssid: String, password: String?) async -> CommandResult {
        var arguments = ["-setairportnetwork", device, ssid]
        if let password, !password.isEmpty {
            arguments.append(password)
        }
        let output = await runner.run(networksetupURL, arguments: arguments)
        if
            let associationManager,
            let password,
            !password.isEmpty
        {
            let associationResult = await associationManager.associate(
                device: device,
                ssid: ssid,
                password: password
            )
            if associationResult.succeeded {
                return associationResult
            }
        }
        return CommandResult(
            exitCode: output.exitCode,
            standardOutput: output.standardOutput,
            standardError: output.standardError
        )
    }

    public func openWiFiSettings() async {
        _ = await runner.run(
            openURL,
            arguments: ["x-apple.systempreferences:com.apple.Network-Settings.extension"]
        )
    }

    public func isCodexRunning() async -> Bool {
        let output = await runner.run(pgrepURL, arguments: ["-x", "Codex"])
        return output.exitCode == 0 && !output.standardOutput.isEmpty
    }

    private func deviceHasDefaultRouteAndAddress(_ device: String) async -> Bool {
        let routeOutput = await runner.run(routeURL, arguments: ["-n", "get", "default"])
        let routeRaw = routeOutput.standardOutput.isEmpty
            ? routeOutput.standardError
            : routeOutput.standardOutput
        guard parseDefaultRouteInterface(routeRaw) == device else {
            return false
        }

        let addressOutput = await runner.run(ipconfigURL, arguments: ["getifaddr", device])
        let addressRaw = addressOutput.standardOutput.isEmpty
            ? addressOutput.standardError
            : addressOutput.standardOutput
        return parseIPv4Address(addressRaw) != nil
    }
}

public protocol WiFiAssociationManaging: Sendable {
    func setPower(device: String, enabled: Bool) async -> CommandResult
    func associate(device: String, ssid: String, password: String) async -> CommandResult
}

public final class CoreWLANAssociationManager: WiFiAssociationManaging, @unchecked Sendable {
    public init() {}

    public func setPower(device: String, enabled: Bool) async -> CommandResult {
        guard let interface = CWWiFiClient.shared().interface(withName: device) else {
            return CommandResult(exitCode: 1, standardError: "Wi-Fi interface \(device) was not found.")
        }

        do {
            try interface.setPower(enabled)
            return CommandResult(exitCode: 0)
        } catch {
            return CommandResult(exitCode: 1, standardError: error.localizedDescription)
        }
    }

    public func associate(device: String, ssid: String, password: String) async -> CommandResult {
        guard let interface = CWWiFiClient.shared().interface(withName: device) else {
            return CommandResult(exitCode: 1, standardError: "Wi-Fi interface \(device) was not found.")
        }

        do {
            if !interface.powerOn() {
                try interface.setPower(true)
            }
            let networks = try interface.scanForNetworks(withName: ssid)
            guard let network = networks.first else {
                return CommandResult(exitCode: 1, standardError: "Hotspot '\(ssid)' was not visible to CoreWLAN.")
            }
            try interface.associate(to: network, password: password)
            return CommandResult(exitCode: 0)
        } catch {
            return CommandResult(exitCode: 1, standardError: error.localizedDescription)
        }
    }
}

private actor KeepAwakeProcessStore {
    private var caffeinateProcess: Process?

    func start(caffeinateURL: URL) throws {
        if caffeinateProcess?.isRunning == true {
            return
        }

        let process = Process()
        process.executableURL = caffeinateURL
        process.arguments = keepAwakeArguments(processID: ProcessInfo.processInfo.processIdentifier)
        try process.run()
        caffeinateProcess = process
    }

    func stop() {
        let process = caffeinateProcess
        caffeinateProcess = nil

        if process?.isRunning == true {
            process?.terminate()
        }
    }
}

public func keepAwakeArguments(processID: Int32) -> [String] {
    ["-dim", "-w", String(processID)]
}

public enum TravelCommandError: LocalizedError {
    case commandFailed(String)

    public var errorDescription: String? {
        switch self {
        case .commandFailed(let detail):
            return detail.isEmpty ? "Command failed." : detail
        }
    }
}

public func parseNetworkName(_ rawOutput: String) -> String? {
    for line in rawOutput.split(separator: "\n") {
        let parts = line.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2 else {
            continue
        }
        guard parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
            .localizedCaseInsensitiveCompare("Current Wi-Fi Network") == .orderedSame
        else {
            continue
        }
        let network = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
        return network.isEmpty ? nil : network
    }
    return nil
}

public func parseDefaultRouteInterface(_ rawOutput: String) -> String? {
    for line in rawOutput.split(separator: "\n") {
        let parts = line.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2 else {
            continue
        }
        guard parts[0].trimmingCharacters(in: .whitespacesAndNewlines) == "interface" else {
            continue
        }
        let interface = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
        return interface.isEmpty ? nil : interface
    }
    return nil
}

public func parseIPv4Address(_ rawOutput: String) -> String? {
    let address = rawOutput.trimmingCharacters(in: .whitespacesAndNewlines)
    guard address.range(of: #"^\d{1,3}(\.\d{1,3}){3}$"#, options: .regularExpression) != nil else {
        return nil
    }
    return address
}

public func parsePowerSettingsSnapshot(_ rawOutput: String) -> PowerSettingsSnapshot? {
    var currentProfile: PowerProfileKind?
    var battery = PowerProfileSettings(sleep: nil, ttysKeepAwake: nil)
    var ac = PowerProfileSettings(sleep: nil, ttysKeepAwake: nil)

    for rawLine in rawOutput.split(separator: "\n") {
        let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
        if line == "Battery Power:" {
            currentProfile = .battery
            continue
        }
        if line == "AC Power:" {
            currentProfile = .ac
            continue
        }

        let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
        guard parts.count == 2, let value = Int(parts[1]) else {
            continue
        }

        switch (currentProfile, parts[0]) {
        case (.battery, "sleep"):
            battery.sleep = value
        case (.battery, "ttyskeepawake"):
            battery.ttysKeepAwake = value
        case (.ac, "sleep"):
            ac.sleep = value
        case (.ac, "ttyskeepawake"):
            ac.ttysKeepAwake = value
        default:
            continue
        }
    }

    let batterySnapshot = battery.sleep == nil && battery.ttysKeepAwake == nil ? nil : battery
    let acSnapshot = ac.sleep == nil && ac.ttysKeepAwake == nil ? nil : ac
    guard batterySnapshot != nil || acSnapshot != nil else {
        return nil
    }
    return PowerSettingsSnapshot(battery: batterySnapshot, ac: acSnapshot)
}

public func pmsetRestoreCommands(_ snapshot: PowerSettingsSnapshot) -> [String] {
    [
        pmsetRestoreCommand(flag: "-b", profile: snapshot.battery),
        pmsetRestoreCommand(flag: "-c", profile: snapshot.ac)
    ].compactMap { $0 }
}

private enum PowerProfileKind {
    case battery
    case ac
}

private func pmsetRestoreCommand(flag: String, profile: PowerProfileSettings?) -> String? {
    guard let profile else {
        return nil
    }

    var arguments: [String] = []
    if let sleep = profile.sleep {
        arguments.append("sleep \(sleep)")
    }
    if let ttysKeepAwake = profile.ttysKeepAwake {
        arguments.append("ttyskeepawake \(ttysKeepAwake)")
    }
    guard !arguments.isEmpty else {
        return nil
    }
    return "pmset \(flag) \(arguments.joined(separator: " "))"
}

public func parseWiFiPower(_ rawOutput: String) -> Bool? {
    let normalized = rawOutput.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    if normalized.hasSuffix(": on") {
        return true
    }
    if normalized.hasSuffix(": off") {
        return false
    }
    return nil
}

public func parseDisablesleep(_ rawOutput: String) -> Bool? {
    for line in rawOutput.split(separator: "\n") {
        let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
        guard parts.count == 2, parts[0] == "disablesleep" || parts[0] == "SleepDisabled" else {
            continue
        }
        if parts[1] == "1" {
            return true
        }
        if parts[1] == "0" {
            return false
        }
    }
    return nil
}

public func parseClamshellClosed(_ rawOutput: String) -> Bool? {
    for line in rawOutput.split(separator: "\n") {
        guard line.contains("AppleClamshellState") else {
            continue
        }
        if line.contains("Yes") {
            return true
        }
        if line.contains("No") {
            return false
        }
    }
    return nil
}

public func parseWiFiDevice(_ rawOutput: String) -> String? {
    var previousLine = ""
    for rawLine in rawOutput.split(separator: "\n") {
        let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
        if previousLine == "Hardware Port: Wi-Fi", line.hasPrefix("Device:") {
            let device = line
                .replacingOccurrences(of: "Device:", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return device.isEmpty ? nil : device
        }
        previousLine = line
    }
    return nil
}

public func parsePreferredNetworks(_ rawOutput: String) -> [String] {
    rawOutput
        .split(separator: "\n")
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty && !$0.localizedCaseInsensitiveContains("Preferred networks on") }
}

public func parseScannedNetworks(_ rawOutput: String) -> [String] {
    var networks: [String] = []
    for rawLine in rawOutput.split(separator: "\n") {
        let line = String(rawLine)
        guard !line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            continue
        }
        guard !line.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("SSID ") else {
            continue
        }

        let bssidRange = line.range(
            of: #"([0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2}"#,
            options: .regularExpression
        )
        let ssid = if let bssidRange {
            String(line[..<bssidRange.lowerBound])
                .trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            line.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if !ssid.isEmpty, !networks.contains(ssid) {
            networks.append(ssid)
        }
    }
    return networks
}
