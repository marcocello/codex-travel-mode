import Foundation

public protocol WiFiDiscoveryProviding: Sendable {
    func snapshot() async -> WiFiDiscoverySnapshot
    func requestLocationAuthorization() async
}

public enum WiFiDiscoveryAuthorizationStatus: Equatable, Sendable {
    case notDetermined
    case denied
    case restricted
    case servicesDisabled
    case authorized
}

@MainActor
public protocol WiFiDiscoveryAuthorizationProviding: Sendable {
    func currentStatus() -> WiFiDiscoveryAuthorizationStatus
    func requestWhenInUseAuthorization()
}

public struct WiFiDiscoveryInterfaceProfile: Equatable, Sendable {
    public let interfaceName: String
    public let rememberedSSIDData: [Data?]

    public init(interfaceName: String, rememberedSSIDData: [Data?]) {
        self.interfaceName = interfaceName
        self.rememberedSSIDData = rememberedSSIDData
    }
}

public enum WiFiDiscoverySystemError: Error, Equatable, Sendable {
    case noWiFiInterface
    case providerFailed
}

public protocol WiFiDiscoverySystemProviding: Sendable {
    func interfaceProfile() throws -> WiFiDiscoveryInterfaceProfile
    func visibleSSIDData(interfaceName: String) throws -> [Data?]
}
