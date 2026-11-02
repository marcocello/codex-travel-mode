import Foundation

public struct TravelModeSettings: Equatable, Sendable {
    public var hotspotSSID: String
    public var hotspotPassword: String
    public var wifiDevice: String

    public init(
        hotspotSSID: String = "",
        hotspotPassword: String = "",
        wifiDevice: String = ""
    ) {
        self.hotspotSSID = hotspotSSID
        self.hotspotPassword = hotspotPassword
        self.wifiDevice = wifiDevice
    }

    public var trimmedHotspotSSID: String {
        hotspotSSID
    }

    public var trimmedHotspotPassword: String {
        hotspotPassword
    }

    public var trimmedWiFiDevice: String {
        wifiDevice.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.hotspotSSID.hasExactUTF8Representation(as: rhs.hotspotSSID)
            && lhs.hotspotPassword.hasExactUTF8Representation(as: rhs.hotspotPassword)
            && lhs.wifiDevice == rhs.wifiDevice
    }
}
