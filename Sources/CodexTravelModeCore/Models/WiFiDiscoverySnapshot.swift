import Foundation

public struct WiFiSSID: Equatable, Hashable, Sendable {
    public let utf8Bytes: Data

    public init?(utf8Bytes: Data) {
        guard (1...32).contains(utf8Bytes.count),
              String(data: utf8Bytes, encoding: .utf8) != nil else {
            return nil
        }
        self.utf8Bytes = utf8Bytes
    }

    public init?(displayName: String) {
        self.init(utf8Bytes: Data(displayName.utf8))
    }

    public var displayName: String {
        String(data: utf8Bytes, encoding: .utf8)!
    }
}

public enum WiFiVisibleScanStatus: String, Equatable, Sendable {
    case notDetermined = "not_determined"
    case denied
    case restricted
    case servicesDisabled = "services_disabled"
    case noWiFiInterface = "no_wifi_interface"
    case providerFailed = "provider_failed"
    case completed
}

public struct WiFiDiscoverySnapshot: Equatable, Sendable {
    public let interfaceName: String?
    public let rememberedNetworks: [WiFiSSID]
    public let visibleNetworks: [WiFiSSID]
    public let visibleScanStatus: WiFiVisibleScanStatus

    public init(
        interfaceName: String?,
        rememberedNetworks: [WiFiSSID],
        visibleNetworks: [WiFiSSID],
        visibleScanStatus: WiFiVisibleScanStatus
    ) {
        self.interfaceName = interfaceName
        self.rememberedNetworks = rememberedNetworks.removingExactDuplicates()
        self.visibleNetworks = visibleNetworks
            .removingExactDuplicates()
            .sorted { $0.utf8Bytes.lexicographicallyPrecedes($1.utf8Bytes) }
        self.visibleScanStatus = visibleScanStatus
    }

    public var selectableNetworks: [WiFiSSID] {
        (rememberedNetworks + visibleNetworks).removingExactDuplicates()
    }
}

private extension Array where Element == WiFiSSID {
    func removingExactDuplicates() -> [WiFiSSID] {
        var seen: Set<Data> = []
        return filter { seen.insert($0.utf8Bytes).inserted }
    }
}
