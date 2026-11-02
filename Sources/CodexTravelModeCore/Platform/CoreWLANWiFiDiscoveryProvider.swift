import CoreLocation
import CoreWLAN
import Foundation

public final class CoreWLANWiFiDiscoveryProvider: WiFiDiscoveryProviding, @unchecked Sendable {
    private let authorization: any WiFiDiscoveryAuthorizationProviding
    private let worker: CoreWLANWiFiDiscoveryWorker

    @MainActor
    public convenience init() {
        self.init(
            system: CoreWLANDiscoverySystem(),
            authorization: CoreLocationWiFiDiscoveryAuthorizationProvider()
        )
    }

    public init(
        system: any WiFiDiscoverySystemProviding,
        authorization: any WiFiDiscoveryAuthorizationProviding
    ) {
        self.authorization = authorization
        self.worker = CoreWLANWiFiDiscoveryWorker(system: system)
    }

    public func snapshot() async -> WiFiDiscoverySnapshot {
        let authorizationStatus = await authorization.currentStatus()
        return await worker.snapshot(authorizationStatus: authorizationStatus)
    }

    public func requestLocationAuthorization() async {
        await authorization.requestWhenInUseAuthorization()
    }
}

@MainActor
public final class CoreLocationWiFiDiscoveryAuthorizationProvider:
    NSObject,
    WiFiDiscoveryAuthorizationProviding,
    CLLocationManagerDelegate
{
    private let manager: CLLocationManager

    public override convenience init() {
        self.init(manager: CLLocationManager())
    }

    init(manager: CLLocationManager) {
        self.manager = manager
        super.init()
        manager.delegate = self
    }

    public func currentStatus() -> WiFiDiscoveryAuthorizationStatus {
        guard CLLocationManager.locationServicesEnabled() else {
            return .servicesDisabled
        }
        switch manager.authorizationStatus {
        case .notDetermined:
            return .notDetermined
        case .denied:
            return .denied
        case .restricted:
            return .restricted
        case .authorizedAlways, .authorizedWhenInUse:
            return .authorized
        @unknown default:
            return .restricted
        }
    }

    public func requestWhenInUseAuthorization() {
        guard currentStatus() == .notDetermined else { return }
        manager.requestWhenInUseAuthorization()
    }
}

private final class CoreWLANDiscoverySystem: WiFiDiscoverySystemProviding, @unchecked Sendable {
    private let client: CWWiFiClient

    init(client: CWWiFiClient = .shared()) {
        self.client = client
    }

    func interfaceProfile() throws -> WiFiDiscoveryInterfaceProfile {
        guard let interface = client.interface(),
              let interfaceName = interface.interfaceName else {
            throw WiFiDiscoverySystemError.noWiFiInterface
        }
        guard let configuration = interface.configuration() else {
            throw WiFiDiscoverySystemError.providerFailed
        }
        let rememberedData = configuration.networkProfiles.array.map { profile -> Data? in
            (profile as? CWNetworkProfile)?.ssidData
        }
        return WiFiDiscoveryInterfaceProfile(
            interfaceName: interfaceName,
            rememberedSSIDData: rememberedData
        )
    }

    func visibleSSIDData(interfaceName: String) throws -> [Data?] {
        guard let interface = client.interface(withName: interfaceName) else {
            throw WiFiDiscoverySystemError.noWiFiInterface
        }
        return try interface.scanForNetworks(withName: nil).map(\.ssidData)
    }
}

private final class CoreWLANWiFiDiscoveryWorker: @unchecked Sendable {
    private let system: any WiFiDiscoverySystemProviding
    private let queue = DispatchQueue(label: "com.codex.travelmode.wifi-discovery")

    init(system: any WiFiDiscoverySystemProviding) {
        self.system = system
    }

    func snapshot(
        authorizationStatus: WiFiDiscoveryAuthorizationStatus
    ) async -> WiFiDiscoverySnapshot {
        await withCheckedContinuation { continuation in
            queue.async { [system] in
                continuation.resume(
                    returning: Self.makeSnapshot(
                        system: system,
                        authorizationStatus: authorizationStatus
                    )
                )
            }
        }
    }

    private static func makeSnapshot(
        system: any WiFiDiscoverySystemProviding,
        authorizationStatus: WiFiDiscoveryAuthorizationStatus
    ) -> WiFiDiscoverySnapshot {
        let profile: WiFiDiscoveryInterfaceProfile
        do {
            profile = try system.interfaceProfile()
        } catch WiFiDiscoverySystemError.noWiFiInterface {
            return emptySnapshot(status: .noWiFiInterface)
        } catch {
            return emptySnapshot(status: .providerFailed)
        }

        let remembered = profile.rememberedSSIDData.compactMap { data in
            data.flatMap(WiFiSSID.init(utf8Bytes:))
        }
        guard authorizationStatus == .authorized else {
            return WiFiDiscoverySnapshot(
                interfaceName: profile.interfaceName,
                rememberedNetworks: remembered,
                visibleNetworks: [],
                visibleScanStatus: scanStatus(for: authorizationStatus)
            )
        }

        let rawVisible: [Data?]
        do {
            rawVisible = try system.visibleSSIDData(interfaceName: profile.interfaceName)
        } catch WiFiDiscoverySystemError.noWiFiInterface {
            return WiFiDiscoverySnapshot(
                interfaceName: nil,
                rememberedNetworks: remembered,
                visibleNetworks: [],
                visibleScanStatus: .noWiFiInterface
            )
        } catch {
            return WiFiDiscoverySnapshot(
                interfaceName: profile.interfaceName,
                rememberedNetworks: remembered,
                visibleNetworks: [],
                visibleScanStatus: .providerFailed
            )
        }

        let visible = rawVisible.compactMap { data in
            data.flatMap(WiFiSSID.init(utf8Bytes:))
        }
        let status: WiFiVisibleScanStatus = rawVisible.isEmpty || !visible.isEmpty
            ? .completed
            : .denied
        return WiFiDiscoverySnapshot(
            interfaceName: profile.interfaceName,
            rememberedNetworks: remembered,
            visibleNetworks: visible,
            visibleScanStatus: status
        )
    }

    private static func scanStatus(
        for authorizationStatus: WiFiDiscoveryAuthorizationStatus
    ) -> WiFiVisibleScanStatus {
        switch authorizationStatus {
        case .notDetermined: .notDetermined
        case .denied: .denied
        case .restricted: .restricted
        case .servicesDisabled: .servicesDisabled
        case .authorized: .completed
        }
    }

    private static func emptySnapshot(status: WiFiVisibleScanStatus) -> WiFiDiscoverySnapshot {
        WiFiDiscoverySnapshot(
            interfaceName: nil,
            rememberedNetworks: [],
            visibleNetworks: [],
            visibleScanStatus: status
        )
    }
}
