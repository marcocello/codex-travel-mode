import CodexTravelModeCore
import Foundation
import XCTest

@MainActor
final class CoreWLANWiFiDiscoveryProviderTests: XCTestCase {
    func testSSIDIdentityUsesExactCaseSensitiveUTF8BytesWithinPublicBounds() throws {
        XCTAssertNil(WiFiSSID(displayName: ""))
        XCTAssertNil(WiFiSSID(displayName: String(repeating: "a", count: 33)))
        XCTAssertNil(WiFiSSID(utf8Bytes: Data([0xFF])))

        let uppercase = try XCTUnwrap(WiFiSSID(displayName: "iPhone"))
        let lowercase = try XCTUnwrap(WiFiSSID(displayName: "iphone"))
        let composed = try XCTUnwrap(WiFiSSID(displayName: "\u{00E9}"))
        let decomposed = try XCTUnwrap(WiFiSSID(displayName: "e\u{0301}"))
        XCTAssertNotEqual(uppercase, lowercase)
        XCTAssertNotEqual(composed, decomposed)
        XCTAssertEqual(uppercase.displayName, "iPhone")
        XCTAssertEqual(uppercase.utf8Bytes, Data("iPhone".utf8))
    }

    func testCompletedSnapshotPreservesProfileOrderAndSortsVisibleExactBytes() async throws {
        let system = StubDiscoverySystem(
            profile: profile("en7", ["Remembered", "Remembered", "iphone"]),
            visible: [data("zeta"), data("iPhone"), data("alpha"), data("alpha"), nil]
        )
        let provider = makeProvider(system: system, authorization: .authorized)

        let snapshot = await provider.snapshot()

        XCTAssertEqual(snapshot.interfaceName, "en7")
        XCTAssertEqual(snapshot.visibleScanStatus, .completed)
        XCTAssertEqual(snapshot.rememberedNetworks.map(\.displayName), ["Remembered", "iphone"])
        XCTAssertEqual(snapshot.visibleNetworks.map(\.displayName), ["alpha", "iPhone", "zeta"])
        XCTAssertEqual(
            snapshot.selectableNetworks.map(\.displayName),
            ["Remembered", "iphone", "alpha", "iPhone", "zeta"]
        )
        XCTAssertFalse(system.wasCalledOnMainThread)
        XCTAssertEqual(system.requestedInterfaces, ["en7"])
    }

    func testEveryNonAuthorizedStatusRetainsRememberedProfilesAndSkipsScan() async {
        let cases: [(WiFiDiscoveryAuthorizationStatus, WiFiVisibleScanStatus)] = [
            (.notDetermined, .notDetermined),
            (.denied, .denied),
            (.restricted, .restricted),
            (.servicesDisabled, .servicesDisabled)
        ]

        for (authorization, expectedStatus) in cases {
            let system = StubDiscoverySystem(
                profile: profile("en0", ["Remembered"]),
                visible: [data("Visible")]
            )
            let provider = makeProvider(system: system, authorization: authorization)

            let snapshot = await provider.snapshot()

            XCTAssertEqual(snapshot.interfaceName, "en0")
            XCTAssertEqual(snapshot.rememberedNetworks.map(\.displayName), ["Remembered"])
            XCTAssertTrue(snapshot.visibleNetworks.isEmpty)
            XCTAssertEqual(snapshot.visibleScanStatus, expectedStatus)
            XCTAssertEqual(system.visibleCallCount, 0)
        }
    }

    func testNoInterfaceAndProviderFailuresRemainDistinct() async {
        let noInterface = StubDiscoverySystem(profileError: WiFiDiscoverySystemError.noWiFiInterface)
        let noInterfaceSnapshot = await makeProvider(
            system: noInterface,
            authorization: .authorized
        ).snapshot()
        XCTAssertNil(noInterfaceSnapshot.interfaceName)
        XCTAssertEqual(noInterfaceSnapshot.visibleScanStatus, .noWiFiInterface)

        let profileFailure = StubDiscoverySystem(profileError: StubError.failed)
        let profileFailureSnapshot = await makeProvider(
            system: profileFailure,
            authorization: .authorized
        ).snapshot()
        XCTAssertEqual(profileFailureSnapshot.visibleScanStatus, .providerFailed)

        let scanFailure = StubDiscoverySystem(
            profile: WiFiDiscoveryInterfaceProfile(
                interfaceName: "en0",
                rememberedSSIDData: [data("Remembered"), nil, Data([0xFF])]
            ),
            visibleError: StubError.failed
        )
        let scanFailureSnapshot = await makeProvider(
            system: scanFailure,
            authorization: .authorized
        ).snapshot()
        XCTAssertEqual(scanFailureSnapshot.interfaceName, "en0")
        XCTAssertEqual(scanFailureSnapshot.rememberedNetworks.map(\.displayName), ["Remembered"])
        XCTAssertEqual(scanFailureSnapshot.visibleScanStatus, .providerFailed)
    }

    func testNonemptyRawScanWithNoValidSSIDIsPermissionDeniedNotEmpty() async {
        let system = StubDiscoverySystem(
            profile: profile("en0", ["Remembered"]),
            visible: [nil, Data([0xFF])]
        )
        let snapshot = await makeProvider(system: system, authorization: .authorized).snapshot()

        XCTAssertEqual(snapshot.rememberedNetworks.map(\.displayName), ["Remembered"])
        XCTAssertTrue(snapshot.visibleNetworks.isEmpty)
        XCTAssertEqual(snapshot.visibleScanStatus, .denied)
    }

    func testAuthorizedEmptyScanIsCompleted() async {
        let system = StubDiscoverySystem(profile: profile("en0", []), visible: [])
        let snapshot = await makeProvider(system: system, authorization: .authorized).snapshot()

        XCTAssertEqual(snapshot.interfaceName, "en0")
        XCTAssertEqual(snapshot.visibleScanStatus, .completed)
        XCTAssertTrue(snapshot.selectableNetworks.isEmpty)
    }

    func testPermissionRequestIsExplicitAndDoesNotTriggerDiscovery() async {
        let authorization = StubAuthorizationProvider(status: .notDetermined)
        let system = StubDiscoverySystem(profile: profile("en0", ["Remembered"]))
        let provider = CoreWLANWiFiDiscoveryProvider(
            system: system,
            authorization: authorization
        )

        XCTAssertEqual(authorization.requestCount, 0)
        await provider.requestLocationAuthorization()

        XCTAssertEqual(authorization.requestCount, 1)
        XCTAssertEqual(system.profileCallCount, 0)
        XCTAssertEqual(system.visibleCallCount, 0)
    }

    func testConcurrentSnapshotsSerializeAllBlockingSystemCalls() async {
        let system = StubDiscoverySystem(
            profile: profile("en0", ["Remembered"]),
            visible: [data("Visible")],
            operationDelay: 0.02
        )
        let provider = makeProvider(system: system, authorization: .authorized)

        async let first = provider.snapshot()
        async let second = provider.snapshot()
        _ = await (first, second)

        XCTAssertEqual(system.maximumConcurrentCalls, 1)
        XCTAssertEqual(system.profileCallCount, 2)
        XCTAssertEqual(system.visibleCallCount, 2)
    }

    private func makeProvider(
        system: StubDiscoverySystem,
        authorization: WiFiDiscoveryAuthorizationStatus
    ) -> CoreWLANWiFiDiscoveryProvider {
        CoreWLANWiFiDiscoveryProvider(
            system: system,
            authorization: StubAuthorizationProvider(status: authorization)
        )
    }
}

@MainActor
private final class StubAuthorizationProvider: WiFiDiscoveryAuthorizationProviding {
    let status: WiFiDiscoveryAuthorizationStatus
    var requestCount = 0

    init(status: WiFiDiscoveryAuthorizationStatus) {
        self.status = status
    }

    func currentStatus() -> WiFiDiscoveryAuthorizationStatus {
        status
    }

    func requestWhenInUseAuthorization() {
        requestCount += 1
    }
}

private final class StubDiscoverySystem: WiFiDiscoverySystemProviding, @unchecked Sendable {
    private let lock = NSLock()
    private let profileResult: Result<WiFiDiscoveryInterfaceProfile, Error>
    private let visibleResult: Result<[Data?], Error>
    private let operationDelay: TimeInterval
    private var activeCalls = 0
    private(set) var maximumConcurrentCalls = 0
    private(set) var profileCallCount = 0
    private(set) var visibleCallCount = 0
    private(set) var requestedInterfaces: [String] = []
    private(set) var wasCalledOnMainThread = false

    init(
        profile: WiFiDiscoveryInterfaceProfile = WiFiDiscoveryInterfaceProfile(
            interfaceName: "en0",
            rememberedSSIDData: []
        ),
        visible: [Data?] = [],
        profileError: Error? = nil,
        visibleError: Error? = nil,
        operationDelay: TimeInterval = 0
    ) {
        profileResult = profileError.map(Result.failure) ?? .success(profile)
        visibleResult = visibleError.map(Result.failure) ?? .success(visible)
        self.operationDelay = operationDelay
    }

    func interfaceProfile() throws -> WiFiDiscoveryInterfaceProfile {
        beginCall()
        defer { endCall() }
        lock.withLock { profileCallCount += 1 }
        return try profileResult.get()
    }

    func visibleSSIDData(interfaceName: String) throws -> [Data?] {
        beginCall()
        defer { endCall() }
        lock.withLock {
            visibleCallCount += 1
            requestedInterfaces.append(interfaceName)
        }
        return try visibleResult.get()
    }

    private func beginCall() {
        lock.withLock {
            activeCalls += 1
            maximumConcurrentCalls = max(maximumConcurrentCalls, activeCalls)
            wasCalledOnMainThread = wasCalledOnMainThread || Thread.isMainThread
        }
        if operationDelay > 0 {
            Thread.sleep(forTimeInterval: operationDelay)
        }
    }

    private func endCall() {
        lock.withLock { activeCalls -= 1 }
    }
}

private enum StubError: Error {
    case failed
}

private func profile(_ interfaceName: String, _ names: [String]) -> WiFiDiscoveryInterfaceProfile {
    WiFiDiscoveryInterfaceProfile(
        interfaceName: interfaceName,
        rememberedSSIDData: names.map { data($0) }
    )
}

private func data(_ value: String) -> Data {
    Data(value.utf8)
}
