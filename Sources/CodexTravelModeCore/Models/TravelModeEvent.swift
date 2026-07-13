import Foundation

public enum TravelModeEvent: Equatable, Sendable {
    case preservedCurrentWiFi(String)
    case hotspotConnected(String)
    case hotspotFailed(String)
    case missingHotspotSSID
    case missingWiFiDevice

    public var message: String {
        switch self {
        case .preservedCurrentWiFi(let network):
            return "Wi-Fi connected to '\(network)'; preserving current network"
        case .hotspotConnected(let network):
            return "Connected to hotspot '\(network)'"
        case .hotspotFailed(let detail):
            return """
            Could not join the fallback hotspot.

            macOS still reports: \(detail)

            The app uses the saved hotspot password with networksetup. If this repeats, macOS is refusing to associate to that SSID; check that Personal Hotspot is discoverable and the saved password is correct.
            """
        case .missingHotspotSSID:
            return "Hotspot name is required."
        case .missingWiFiDevice:
            return "Wi-Fi device is required."
        }
    }
}
