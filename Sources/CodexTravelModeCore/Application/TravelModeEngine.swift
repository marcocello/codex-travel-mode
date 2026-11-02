import Foundation

public final class TravelModeEngine: Sendable {
    private let verificationAttempts: Int
    private let verificationDelay: Duration

    public init(verificationAttempts: Int = 1, verificationDelay: Duration = .zero) {
        self.verificationAttempts = max(1, verificationAttempts)
        self.verificationDelay = verificationDelay
    }

    public static func production() -> TravelModeEngine {
        TravelModeEngine(verificationAttempts: 8, verificationDelay: .seconds(1))
    }

    public func sync(
        settings: TravelModeSettings,
        gateway: TravelCommandGateway,
        passwordProvider: @Sendable () -> String? = { nil },
        forceFallback: Bool = false
    ) async -> TravelModeEvent {
        let ssid = settings.trimmedHotspotSSID
        let device = settings.trimmedWiFiDevice

        guard !ssid.isEmpty else {
            return .missingHotspotSSID
        }
        guard !device.isEmpty else {
            return .missingWiFiDevice
        }

        let status = await gateway.currentWiFiStatus(device: device)
        if !forceFallback, let network = status.networkName, !network.isEmpty {
            return .preservedCurrentWiFi(network)
        }

        let powerResult = await gateway.setWiFiPower(device: device, enabled: true)
        guard powerResult.succeeded else {
            return .hotspotFailed(powerResult.detail)
        }
        let password = settings.trimmedHotspotPassword.isEmpty
            ? passwordProvider()
            : settings.trimmedHotspotPassword
        guard let password, !password.isEmpty else {
            return .hotspotFailed("No hotspot password was available. Save the hotspot password again.")
        }
        let result = await gateway.joinWiFi(device: device, ssid: ssid, password: password)
        guard result.succeeded else {
            return .hotspotFailed(result.detail)
        }

        let updatedStatus = await verifiedHotspotStatus(device: device, ssid: ssid, gateway: gateway)
        if updatedStatus.networkName == ssid {
            return .hotspotConnected(ssid)
        }

        let detail = updatedStatus.rawOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        let fallbackDetail = detail.isEmpty ? "Wi-Fi is still not associated" : detail
        return .hotspotFailed(
            "\(fallbackDetail)\n\nPassword was provided to the password-based join backends, but macOS did not associate to '\(ssid)'."
        )
    }

    private func verifiedHotspotStatus(
        device: String,
        ssid: String,
        gateway: TravelCommandGateway
    ) async -> WiFiStatus {
        var lastStatus = WiFiStatus(device: device, networkName: nil, rawOutput: "")
        for attempt in 1...verificationAttempts {
            lastStatus = await gateway.currentWiFiStatus(device: device)
            if lastStatus.networkName == ssid || attempt == verificationAttempts {
                return lastStatus
            }
            if verificationDelay > .zero {
                try? await Task.sleep(for: verificationDelay)
            }
        }
        return lastStatus
    }
}
