import Foundation

public struct TransactionalTravelCommandGateway: TravelCommandGateway {
    private let rawGateway: any TravelCommandGateway
    private let sessionManager: any TravelSessionManaging

    public init(
        rawGateway: any TravelCommandGateway,
        sessionManager: any TravelSessionManaging
    ) {
        self.rawGateway = rawGateway
        self.sessionManager = sessionManager
    }

    public func startKeepAwake() async throws {
        try await rawGateway.startKeepAwake()
    }

    public func stopKeepAwake() async {
        await rawGateway.stopKeepAwake()
    }

    public func currentLidClosed() async -> Bool? {
        await rawGateway.currentLidClosed()
    }

    public func discoverWiFiDevice() async -> String? {
        await rawGateway.discoverWiFiDevice()
    }

    public func currentWiFiStatus(device: String) async -> WiFiStatus {
        await rawGateway.currentWiFiStatus(device: device)
    }

    public func currentWiFiStatus(device: String, timeout: Duration) async -> WiFiStatus {
        await rawGateway.currentWiFiStatus(device: device, timeout: timeout)
    }

    public func currentWiFiPower(device: String) async -> Bool? {
        await rawGateway.currentWiFiPower(device: device)
    }

    public func currentWiFiPower(device: String, timeout: Duration) async -> Bool? {
        await rawGateway.currentWiFiPower(device: device, timeout: timeout)
    }

    public func setWiFiPower(device: String, enabled: Bool) async -> CommandResult {
        await sessionManager.setWiFiPower(device: device, enabled: enabled)
    }

    public func joinWiFi(
        device: String,
        ssid: String,
        password: String?
    ) async -> CommandResult {
        await sessionManager.associate(device: device, ssid: ssid, password: password)
    }

    public func joinWiFi(
        device: String,
        ssid: String,
        password: String?,
        timeout: Duration
    ) async -> CommandResult {
        await sessionManager.associate(
            device: device,
            ssid: ssid,
            password: password,
            timeout: timeout
        )
    }

    public func openWiFiSettings() async {
        await rawGateway.openWiFiSettings()
    }

    public func isCodexRunning() async -> Bool {
        await rawGateway.isCodexRunning()
    }
}
