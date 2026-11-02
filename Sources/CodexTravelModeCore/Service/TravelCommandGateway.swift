import Foundation

public protocol TravelCommandGateway: Sendable {
    func startKeepAwake() async throws
    func stopKeepAwake() async
    func currentLidClosed() async -> Bool?
    func discoverWiFiDevice() async -> String?
    func currentWiFiStatus(device: String) async -> WiFiStatus
    func currentWiFiStatus(device: String, timeout: Duration) async -> WiFiStatus
    func currentWiFiPower(device: String) async -> Bool?
    func currentWiFiPower(device: String, timeout: Duration) async -> Bool?
    func setWiFiPower(device: String, enabled: Bool) async -> CommandResult
    func setWiFiPower(
        device: String,
        enabled: Bool,
        timeout: Duration
    ) async -> CommandResult
    func joinWiFi(device: String, ssid: String, password: String?) async -> CommandResult
    func joinWiFi(
        device: String,
        ssid: String,
        password: String?,
        timeout: Duration
    ) async -> CommandResult
    func openWiFiSettings() async
    func isCodexRunning() async -> Bool
}

public extension TravelCommandGateway {
    func currentWiFiStatus(device: String, timeout: Duration) async -> WiFiStatus {
        await currentWiFiStatus(device: device)
    }

    func currentWiFiPower(device: String, timeout: Duration) async -> Bool? {
        await currentWiFiPower(device: device)
    }

    func setWiFiPower(
        device: String,
        enabled: Bool,
        timeout: Duration
    ) async -> CommandResult {
        await setWiFiPower(device: device, enabled: enabled)
    }

    func joinWiFi(
        device: String,
        ssid: String,
        password: String?,
        timeout: Duration
    ) async -> CommandResult {
        await joinWiFi(device: device, ssid: ssid, password: password)
    }
}

public struct CommandResult: Equatable, Sendable {
    public enum FailureCategory: String, Equatable, Sendable {
        case timedOut = "timed_out"
        case cancelled
        case staleSession = "stale_session"
        case commandFailed = "command_failed"
    }

    public var exitCode: Int32
    public var standardOutput: String
    public var standardError: String
    public var failureCategory: FailureCategory?

    public init(
        exitCode: Int32,
        standardOutput: String = "",
        standardError: String = "",
        failureCategory: FailureCategory? = nil
    ) {
        self.exitCode = exitCode
        self.standardOutput = standardOutput
        self.standardError = standardError
        self.failureCategory = failureCategory
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
