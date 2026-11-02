import AppKit
import CoreWLAN
import Foundation

public struct RunningApplicationIdentity: Equatable, Sendable {
    public var bundleIdentifier: String?
    public var isTerminated: Bool

    public init(bundleIdentifier: String?, isTerminated: Bool) {
        self.bundleIdentifier = bundleIdentifier
        self.isTerminated = isTerminated
    }
}

public protocol RunningApplicationProviding: Sendable {
    func runningApplications() async -> [RunningApplicationIdentity]
}

public struct WorkspaceRunningApplicationProvider: RunningApplicationProviding {
    public init() {}

    public func runningApplications() async -> [RunningApplicationIdentity] {
        await MainActor.run {
            NSWorkspace.shared.runningApplications.map { application in
                RunningApplicationIdentity(
                    bundleIdentifier: application.bundleIdentifier,
                    isTerminated: application.isTerminated
                )
            }
        }
    }
}

public final class LocalTravelCommandGateway: TravelCommandGateway, LidStateProviding,
    WiFiConnectivityProviding, @unchecked Sendable
{
    private let runner: ShellCommandRunning
    private let associationManager: WiFiAssociationManaging?
    private let runningApplicationProvider: RunningApplicationProviding
    private let networksetupURL = URL(fileURLWithPath: "/usr/sbin/networksetup")
    private let caffeinateURL = URL(fileURLWithPath: "/usr/bin/caffeinate")
    private let routeURL = URL(fileURLWithPath: "/sbin/route")
    private let ifconfigURL = URL(fileURLWithPath: "/sbin/ifconfig")
    private let openURL = URL(fileURLWithPath: "/usr/bin/open")
    private let ioregURL = URL(fileURLWithPath: "/usr/sbin/ioreg")
    private let keepAwakeStore = KeepAwakeProcessStore()

    public init(
        runner: ShellCommandRunning = ProcessShellCommandRunner(),
        associationManager: WiFiAssociationManaging? = nil,
        runningApplicationProvider: RunningApplicationProviding = WorkspaceRunningApplicationProvider()
    ) {
        self.runner = runner
        self.associationManager = associationManager
        self.runningApplicationProvider = runningApplicationProvider
    }

    public func startKeepAwake() async throws {
        try await keepAwakeStore.start(caffeinateURL: caffeinateURL)
    }

    public func stopKeepAwake() async {
        await keepAwakeStore.stop()
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

    public func currentWiFiStatus(device: String) async -> WiFiStatus {
        let output = await runner.run(networksetupURL, arguments: ["-getairportnetwork", device])
        let raw = output.standardOutput.isEmpty ? output.standardError : output.standardOutput
        if let networkName = parseNetworkName(raw) {
            return WiFiStatus(
                device: device,
                networkName: networkName,
                rawOutput: raw,
                providerExitCode: output.exitCode
            )
        }
        return WiFiStatus(
            device: device,
            networkName: nil,
            rawOutput: raw,
            providerExitCode: output.exitCode
        )
    }

    public func currentWiFiStatus(device: String, timeout: Duration) async -> WiFiStatus {
        let output = await runner.run(
            networksetupURL,
            arguments: ["-getairportnetwork", device],
            timeout: timeout
        )
        let raw = output.standardOutput.isEmpty ? output.standardError : output.standardOutput
        return WiFiStatus(
            device: device,
            networkName: parseNetworkName(raw),
            rawOutput: raw,
            providerExitCode: output.exitCode
        )
    }

    public func readLidState(timeout: Duration) async -> ProviderReading<LidState> {
        let output = await runner.run(
            ioregURL,
            arguments: ["-r", "-k", "AppleClamshellState"],
            timeout: timeout
        )
        if let failure = providerFailure(for: output, operation: "lid state") {
            return .failure(failure)
        }
        let raw = preferredOutput(output)
        guard !raw.isEmpty else {
            return .failure(
                ConnectivityProviderFailure(
                    category: .unavailable,
                    detail: "The lid state provider returned no reading."
                )
            )
        }
        guard let closed = parseClamshellClosed(raw) else {
            return .failure(
                ConnectivityProviderFailure(
                    category: .malformedOutput,
                    detail: "The lid state provider returned an unreadable value."
                )
            )
        }
        return .value(closed ? .closed : .open)
    }

    public func readConnectivity(
        device: String,
        timeout: Duration
    ) async -> WiFiConnectivityObservation {
        async let powerOutput = runner.run(
            networksetupURL,
            arguments: ["-getairportpower", device],
            timeout: timeout
        )
        async let ssidOutput = runner.run(
            networksetupURL,
            arguments: ["-getairportnetwork", device],
            timeout: timeout
        )
        async let addressOutput = runner.run(
            ifconfigURL,
            arguments: [device],
            timeout: timeout
        )
        async let routeOutput = runner.run(
            routeURL,
            arguments: ["-n", "get", "default"],
            timeout: timeout
        )

        let outputs = await (powerOutput, ssidOutput, addressOutput, routeOutput)
        return WiFiConnectivityObservation(
            device: device,
            power: powerReading(outputs.0),
            ssid: ssidReading(outputs.1),
            addresses: addressReading(outputs.2),
            defaultRouteInterface: routeReading(outputs.3)
        )
    }

    public func currentWiFiPower(device: String) async -> Bool? {
        let output = await runner.run(networksetupURL, arguments: ["-getairportpower", device])
        let raw = output.standardOutput.isEmpty ? output.standardError : output.standardOutput
        return parseWiFiPower(raw)
    }

    public func currentWiFiPower(device: String, timeout: Duration) async -> Bool? {
        let output = await runner.run(
            networksetupURL,
            arguments: ["-getairportpower", device],
            timeout: timeout
        )
        guard output.exitCode == 0 else { return nil }
        let raw = output.standardOutput.isEmpty ? output.standardError : output.standardOutput
        return parseWiFiPower(raw)
    }

    public func setWiFiPower(device: String, enabled: Bool) async -> CommandResult {
        if let associationResult = await associationManager?.setPower(
            device: device,
            enabled: enabled
        ), associationResult.succeeded {
            return associationResult
        }
        let output = await runner.run(
            networksetupURL,
            arguments: ["-setairportpower", device, enabled ? "on" : "off"]
        )
        return commandResult(from: output)
    }

    public func setWiFiPower(
        device: String,
        enabled: Bool,
        timeout: Duration
    ) async -> CommandResult {
        let output = await runner.run(
            networksetupURL,
            arguments: ["-setairportpower", device, enabled ? "on" : "off"],
            timeout: timeout
        )
        return commandResult(from: output)
    }

    public func joinWiFi(device: String, ssid: String, password: String?) async -> CommandResult {
        await joinWiFi(
            device: device,
            ssid: ssid,
            password: password,
            timeout: .seconds(15)
        )
    }

    public func joinWiFi(
        device: String,
        ssid: String,
        password: String?,
        timeout: Duration
    ) async -> CommandResult {
        var arguments = ["-setairportnetwork", device, ssid]
        if let password, !password.isEmpty {
            arguments.append(password)
        }
        let output = await runner.run(
            networksetupURL,
            arguments: arguments,
            timeout: timeout
        )
        return commandResult(from: output)
    }

    public func openWiFiSettings() async {
        _ = await runner.run(
            openURL,
            arguments: ["x-apple.systempreferences:com.apple.Network-Settings.extension"]
        )
    }

    public func isCodexRunning() async -> Bool {
        let applications = await runningApplicationProvider.runningApplications()
        return applications.contains { application in
            application.bundleIdentifier == "com.openai.codex" && !application.isTerminated
        }
    }

    private func powerReading(_ output: ShellCommandOutput) -> ProviderReading<Bool> {
        if let failure = providerFailure(for: output, operation: "Wi-Fi power") {
            return .failure(failure)
        }
        guard let power = parseWiFiPower(preferredOutput(output)) else {
            return .failure(
                ConnectivityProviderFailure(
                    category: .malformedOutput,
                    detail: "The Wi-Fi power provider returned an unreadable value."
                )
            )
        }
        return .value(power)
    }

    private func ssidReading(
        _ output: ShellCommandOutput
    ) -> ProviderReading<ExactUTF8String?> {
        if let failure = providerFailure(for: output, operation: "Wi-Fi association") {
            return .failure(failure)
        }
        let raw = preferredOutput(output)
        if let ssid = parseExactNetworkName(raw) {
            return .value(ssid)
        }
        if isOrdinaryWiFiDisconnection(raw) {
            return .value(nil)
        }
        return .failure(
            ConnectivityProviderFailure(
                category: raw.isEmpty ? .unavailable : .malformedOutput,
                detail: raw.isEmpty
                    ? "The Wi-Fi association provider returned no reading."
                    : "The Wi-Fi association provider returned an unreadable value."
            )
        )
    }

    private func addressReading(
        _ output: ShellCommandOutput
    ) -> ProviderReading<[IPAddress]> {
        if let failure = providerFailure(for: output, operation: "interface address") {
            return .failure(failure)
        }
        switch parseInterfaceAddresses(preferredOutput(output)) {
        case let .success(addresses):
            return .value(addresses)
        case .failure:
            return .failure(
                ConnectivityProviderFailure(
                    category: .malformedOutput,
                    detail: "The interface address provider returned an unreadable value."
                )
            )
        }
    }

    private func routeReading(
        _ output: ShellCommandOutput
    ) -> ProviderReading<String?> {
        let raw = preferredOutput(output)
        if output.exitCode != 0, isOrdinaryMissingRoute(raw) {
            return .value(nil)
        }
        if let failure = providerFailure(for: output, operation: "default route") {
            return .failure(failure)
        }
        if let interface = parseDefaultRouteInterface(raw) {
            return .value(interface)
        }
        return .failure(
            ConnectivityProviderFailure(
                category: raw.isEmpty ? .unavailable : .malformedOutput,
                detail: raw.isEmpty
                    ? "The default-route provider returned no reading."
                    : "The default-route provider returned an unreadable value."
            )
        )
    }

    private func commandResult(from output: ShellCommandOutput) -> CommandResult {
        let failureCategory: CommandResult.FailureCategory?
        switch output.exitCode {
        case 124:
            failureCategory = .timedOut
        case 130:
            failureCategory = .cancelled
        default:
            failureCategory = nil
        }
        return CommandResult(
            exitCode: output.exitCode,
            standardOutput: output.standardOutput,
            standardError: output.standardError,
            failureCategory: failureCategory
        )
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
            guard interface.powerOn() else {
                return CommandResult(
                    exitCode: 1,
                    standardError: "Wi-Fi power is off; enable it before association."
                )
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

public func parseNetworkName(_ rawOutput: String) -> String? {
    parseExactNetworkName(rawOutput)?.stringValue
}

public func parseExactNetworkName(_ rawOutput: String) -> ExactUTF8String? {
    let prefix = "Current Wi-Fi Network: "
    for rawLine in rawOutput.split(
        separator: "\n",
        omittingEmptySubsequences: false
    ) {
        let line = rawLine.last == "\r" ? rawLine.dropLast() : rawLine[...]
        guard line.hasPrefix(prefix) else {
            continue
        }
        return ExactUTF8String(String(line.dropFirst(prefix.count)))
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

public enum InterfaceAddressParseError: Error, Equatable, Sendable {
    case malformedAddress
}

public func parseInterfaceAddresses(
    _ rawOutput: String
) -> Result<[IPAddress], InterfaceAddressParseError> {
    var addresses: [IPAddress] = []
    for rawLine in rawOutput.split(separator: "\n") {
        let fields = rawLine.split(whereSeparator: \Character.isWhitespace)
        guard fields.first == "inet" || fields.first == "inet6" else {
            continue
        }
        guard fields.count >= 2, let address = IPAddress(String(fields[1])) else {
            return .failure(.malformedAddress)
        }
        addresses.append(address)
    }
    return .success(addresses)
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

private func preferredOutput(_ output: ShellCommandOutput) -> String {
    output.standardOutput.isEmpty ? output.standardError : output.standardOutput
}

private func providerFailure(
    for output: ShellCommandOutput,
    operation: String
) -> ConnectivityProviderFailure? {
    guard output.exitCode != 0 else {
        return nil
    }
    if output.exitCode == 124 {
        return ConnectivityProviderFailure(
            category: .timedOut,
            detail: "The \(operation) provider timed out."
        )
    }
    let raw = preferredOutput(output)
    let unavailable = output.exitCode == 127
        || raw.localizedCaseInsensitiveContains("no such file")
    return ConnectivityProviderFailure(
        category: unavailable ? .unavailable : .commandFailed,
        detail: unavailable
            ? "The \(operation) provider is unavailable."
            : "The \(operation) provider command failed with exit \(output.exitCode)."
    )
}

private func isOrdinaryWiFiDisconnection(_ rawOutput: String) -> Bool {
    rawOutput.localizedCaseInsensitiveContains("not associated with an AirPort network")
        || rawOutput.localizedCaseInsensitiveContains("Wi-Fi power is currently off")
}

private func isOrdinaryMissingRoute(_ rawOutput: String) -> Bool {
    rawOutput.localizedCaseInsensitiveContains("not in table")
        || rawOutput.localizedCaseInsensitiveContains("route has not been found")
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
