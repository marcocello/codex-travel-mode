import Foundation

public struct GatewayTravelSessionSystemController: TravelSessionSystemControlling {
    private let gateway: any TravelCommandGateway

    public init(gateway: any TravelCommandGateway) {
        self.gateway = gateway
    }

    public func currentWiFiPower(device: String) async throws -> Bool {
        guard let enabled = await gateway.currentWiFiPower(device: device) else {
            throw TravelSessionSystemError.stateUnavailable(
                "Wi-Fi power for \(device) could not be read."
            )
        }
        return enabled
    }

    public func currentWiFiPower(device: String, timeout: Duration) async throws -> Bool {
        guard let enabled = await gateway.currentWiFiPower(device: device, timeout: timeout) else {
            throw TravelSessionSystemError.stateUnavailable(
                "Wi-Fi power for \(device) could not be read within its bound."
            )
        }
        return enabled
    }

    public func currentAssociatedSSID(device: String) async throws -> String? {
        let status = await gateway.currentWiFiStatus(device: device)
        try validate(status: status, requestedDevice: device)
        if status.networkName == routeOnlyConnectionLabel(for: device) {
            return nil
        }
        return status.networkName
    }

    public func currentAssociatedSSID(device: String, timeout: Duration) async throws -> String? {
        let status = await gateway.currentWiFiStatus(device: device, timeout: timeout)
        try validate(status: status, requestedDevice: device)
        return status.networkName
    }

    public func setWiFiPower(device: String, enabled: Bool) async -> CommandResult {
        await gateway.setWiFiPower(device: device, enabled: enabled)
    }

    public func setWiFiPower(
        device: String,
        enabled: Bool,
        timeout: Duration
    ) async -> CommandResult {
        await gateway.setWiFiPower(device: device, enabled: enabled, timeout: timeout)
    }

    public func associate(
        device: String,
        ssid: String,
        password: String?
    ) async -> CommandResult {
        await gateway.joinWiFi(device: device, ssid: ssid, password: password)
    }

    public func associate(
        device: String,
        ssid: String,
        password: String?,
        timeout: Duration
    ) async -> CommandResult {
        await gateway.joinWiFi(
            device: device,
            ssid: ssid,
            password: password,
            timeout: timeout
        )
    }
}

private extension GatewayTravelSessionSystemController {
    func validate(status: WiFiStatus, requestedDevice: String) throws {
        if status.commandFailed {
            throw TravelSessionSystemError.stateUnavailable(statusDetail(status))
        }

        guard status.device == requestedDevice else {
            throw TravelSessionSystemError.stateUnavailable(
                "Wi-Fi status for \(requestedDevice) was not returned."
            )
        }

        let rawOutput = status.rawOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard status.networkName?.isEmpty == false || !rawOutput.isEmpty else {
            throw TravelSessionSystemError.stateUnavailable(
                "Wi-Fi association status for \(requestedDevice) could not be read."
            )
        }
    }

    func statusDetail(_ status: WiFiStatus) -> String {
        let detail = status.rawOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        return detail.isEmpty ? "Wi-Fi association status could not be read." : detail
    }

    func routeOnlyConnectionLabel(for device: String) -> String {
        "Connected on \(device)"
    }
}
