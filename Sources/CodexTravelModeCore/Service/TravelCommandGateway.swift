import Foundation

public protocol TravelCommandGateway: Sendable {
    func startKeepAwake() async throws
    func stopKeepAwake() async
    func currentLidClosedSleepOverride() async -> Bool?
    func setLidClosedSleepOverride(enabled: Bool) async throws
    func currentPowerSettings() async -> PowerSettingsSnapshot?
    func restorePowerSettings(_ snapshot: PowerSettingsSnapshot) async throws
    func currentLidClosed() async -> Bool?
    func discoverWiFiDevice() async -> String?
    func knownWiFiNetworks(device: String) async -> [String]
    func scanWiFiNetworks(device: String) async -> [String]
    func currentWiFiStatus(device: String) async -> WiFiStatus
    func currentWiFiPower(device: String) async -> Bool?
    func setWiFiPower(device: String, enabled: Bool) async
    func joinWiFi(device: String, ssid: String, password: String?) async -> CommandResult
    func openWiFiSettings() async
    func isCodexRunning() async -> Bool
}

public struct CommandResult: Equatable, Sendable {
    public var exitCode: Int32
    public var standardOutput: String
    public var standardError: String

    public init(exitCode: Int32, standardOutput: String = "", standardError: String = "") {
        self.exitCode = exitCode
        self.standardOutput = standardOutput
        self.standardError = standardError
    }

    public var succeeded: Bool {
        exitCode == 0
    }

    public var detail: String {
        let output = [standardError, standardOutput]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
        return output ?? "command exited \(exitCode)"
    }
}
