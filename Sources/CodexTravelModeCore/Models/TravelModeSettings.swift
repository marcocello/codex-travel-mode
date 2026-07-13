import Foundation

public struct TravelModeSettings: Equatable, Sendable {
    public var hotspotSSID: String
    public var hotspotPassword: String
    public var wifiDevice: String

    public init(
        hotspotSSID: String = "iPhone",
        hotspotPassword: String = "",
        wifiDevice: String = ""
    ) {
        self.hotspotSSID = hotspotSSID
        self.hotspotPassword = hotspotPassword
        self.wifiDevice = wifiDevice
    }

    public var trimmedHotspotSSID: String {
        hotspotSSID.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public var trimmedHotspotPassword: String {
        hotspotPassword.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public var trimmedWiFiDevice: String {
        wifiDevice.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
