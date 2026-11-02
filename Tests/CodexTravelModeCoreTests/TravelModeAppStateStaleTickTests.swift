import CodexTravelModeCore
import XCTest

@MainActor
final class TravelModeAppStateStaleTickTests: XCTestCase {
    func testStopWhileKeepAwakeStartIsBlockedCannotResurrectTravelMode() async throws {
        let harness = try makeStaleTickHarness()
        await harness.gateway.blockNextKeepAwakeStart()

        let staleStart = Task { @MainActor in
            await harness.app.start()
        }
        await harness.gateway.waitUntilKeepAwakeStartIsBlocked()

        let lifecycleWhileBlocked = await harness.session.lifecycle()
        XCTAssertEqual(lifecycleWhileBlocked, .active)
        let publicationWhileBlocked = await harness.coordinator.currentPublication()
        XCTAssertEqual(publicationWhileBlocked.state, .inactive)

        // If the stale activation reaches the handoff coordinator after Stop,
        // these observations make the resulting mutation immediately visible.
        await harness.lid.set(.closed)
        await harness.connectivity.set(disconnectedObservation())

        let stopTask = Task { @MainActor in
            await harness.app.stop()
        }
        for _ in 0..<100 {
            if await harness.session.lifecycle() == .off { break }
            await Task.yield()
        }
        XCTAssertEqual(harness.app.lifecyclePresentation, .restoring)
        XCTAssertFalse(harness.app.isCleanlyOffForTermination)

        await harness.gateway.releaseBlockedKeepAwakeStart()
        await staleStart.value
        await stopTask.value

        XCTAssertFalse(harness.app.isRunning)
        XCTAssertEqual(harness.app.internetRuntimeState, .inactive)
        XCTAssertEqual(harness.app.latestStatus, "Stopped")
        let finalLifecycle = await harness.session.lifecycle()
        let finalPublication = await harness.coordinator.currentPublication()
        let gatewayMutations = await harness.gateway.mutationSnapshot()
        let sessionMutations = await harness.session.mutationSnapshot()
        XCTAssertEqual(finalLifecycle, .off)
        XCTAssertEqual(finalPublication.state, .inactive)
        XCTAssertEqual(gatewayMutations, StaleTickMutationSnapshot())
        XCTAssertEqual(sessionMutations, StaleTickMutationSnapshot())

        let keepAwake = await harness.gateway.keepAwakeSnapshot()
        XCTAssertEqual(keepAwake.startCalls, 1)
        XCTAssertEqual(keepAwake.startCompletions, 1)
        XCTAssertGreaterThanOrEqual(keepAwake.stopCalls, 1)
        XCTAssertFalse(
            keepAwake.isRunning,
            "A late keep-awake start completion must be compensated after Stop wins activation."
        )
    }

    func testStopWhileCodexReadIsBlockedDiscardsStaleSyncWithoutLegacyFallback() async throws {
        let harness = try makeStaleTickHarness()
        await harness.app.start()

        XCTAssertTrue(harness.app.isRunning)
        XCTAssertTrue(harness.app.isCodexRunning)
        XCTAssertEqual(
            harness.app.internetRuntimeState,
            .preservingCurrentNetwork(ExactUTF8String("Office")!)
        )

        await harness.gateway.blockNextCodexRead(returning: false)
        let staleSync = Task { @MainActor in
            await harness.app.syncOnce()
        }
        await harness.gateway.waitUntilCodexReadIsBlocked()

        // Make either stale coordinator work or a legacy fallthrough observable.
        await harness.lid.set(.closed)
        await harness.connectivity.set(disconnectedObservation())
        await harness.gateway.setLegacyFallbackInputs(lidClosed: true)

        let stopTask = Task { @MainActor in
            await harness.app.stop()
        }
        await stopTask.value

        XCTAssertFalse(harness.app.isRunning)
        XCTAssertEqual(harness.app.internetRuntimeState, .inactive)
        XCTAssertEqual(harness.app.latestStatus, "Stopped")
        let stoppedLogs = harness.app.logs

        await harness.gateway.releaseBlockedCodexRead()
        await staleSync.value

        XCTAssertFalse(harness.app.isRunning)
        XCTAssertTrue(
            harness.app.isCodexRunning,
            "The stale false result must not publish after Stop invalidates its generation."
        )
        XCTAssertEqual(harness.app.internetRuntimeState, .inactive)
        XCTAssertEqual(harness.app.latestStatus, "Stopped")
        XCTAssertEqual(harness.app.logs, stoppedLogs)

        let gatewayMutations = await harness.gateway.mutationSnapshot()
        let sessionMutations = await harness.session.mutationSnapshot()
        let legacyObservationCount = await harness.gateway.legacyObservationCount()
        let finalPublication = await harness.coordinator.currentPublication()
        XCTAssertEqual(gatewayMutations, StaleTickMutationSnapshot())
        XCTAssertEqual(sessionMutations, StaleTickMutationSnapshot())
        XCTAssertEqual(
            legacyObservationCount,
            0,
            "A coordinator-backed app must not fall through to the legacy status/lid path."
        )
        XCTAssertEqual(finalPublication.state, .inactive)
    }

    func testDirectRetryDoesNothingWhileInactiveOrActiveWithoutRetryableEpisode() async throws {
        let harness = try makeStaleTickHarness()

        await harness.app.retryInternetHandoff()

        let inactivePublication = await harness.coordinator.currentPublication()
        let inactiveCodexReads = await harness.gateway.codexReadCount()
        let inactiveGatewayMutations = await harness.gateway.mutationSnapshot()
        let inactiveSessionMutations = await harness.session.mutationSnapshot()
        XCTAssertFalse(harness.app.canRetryInternetHandoff)
        XCTAssertEqual(inactivePublication.state, .inactive)
        XCTAssertEqual(inactiveCodexReads, 0)
        XCTAssertEqual(inactiveGatewayMutations, StaleTickMutationSnapshot())
        XCTAssertEqual(inactiveSessionMutations, StaleTickMutationSnapshot())

        await harness.app.start()
        let stateBeforeRetry = harness.app.internetRuntimeState
        let statusBeforeRetry = harness.app.latestStatus
        let logsBeforeRetry = harness.app.logs
        let publicationBeforeRetry = await harness.coordinator.currentPublication()
        XCTAssertFalse(harness.app.canRetryInternetHandoff)

        await harness.app.retryInternetHandoff()

        let publicationAfterRetry = await harness.coordinator.currentPublication()
        let gatewayMutationsAfterRetry = await harness.gateway.mutationSnapshot()
        let sessionMutationsAfterRetry = await harness.session.mutationSnapshot()
        XCTAssertFalse(harness.app.canRetryInternetHandoff)
        XCTAssertEqual(harness.app.internetRuntimeState, stateBeforeRetry)
        XCTAssertEqual(harness.app.latestStatus, statusBeforeRetry)
        XCTAssertEqual(harness.app.logs, logsBeforeRetry)
        XCTAssertEqual(publicationAfterRetry, publicationBeforeRetry)
        XCTAssertEqual(gatewayMutationsAfterRetry, StaleTickMutationSnapshot())
        XCTAssertEqual(sessionMutationsAfterRetry, StaleTickMutationSnapshot())

        await harness.app.stop()
    }
}

private struct StaleTickHarness {
    let app: TravelModeAppState
    let gateway: StaleTickGateway
    let coordinator: TravelInternetHandoffCoordinator
    let lid: StaleTickLidProvider
    let connectivity: StaleTickConnectivityProvider
    let session: StaleTickSessionManager
}

@MainActor
private func makeStaleTickHarness() throws -> StaleTickHarness {
    let gateway = StaleTickGateway()
    let lid = StaleTickLidProvider(.open)
    let connectivity = StaleTickConnectivityProvider(healthyOfficeObservation())
    let session = StaleTickSessionManager()
    let engine = TravelInternetHandoffEngine(
        connectivityProvider: connectivity,
        reachabilityChecker: StaleTickReachabilityChecker(),
        sessionManager: session
    )
    let coordinator = TravelInternetHandoffCoordinator(
        lidProvider: lid,
        engine: engine,
        scheduler: StaleTickScheduler()
    )
    let app = TravelModeAppState(
        gateway: gateway,
        settingsStore: try StaleTickSettingsStore(),
        wifiDiscovery: StaleTickWiFiDiscovery(),
        sessionManager: session,
        internetHandoffCoordinator: coordinator
    )
    return StaleTickHarness(
        app: app,
        gateway: gateway,
        coordinator: coordinator,
        lid: lid,
        connectivity: connectivity,
        session: session
    )
}

private struct StaleTickMutationSnapshot: Equatable, Sendable {
    var powerCalls = 0
    var associationCalls = 0
}

private struct StaleTickKeepAwakeSnapshot: Equatable, Sendable {
    var startCalls = 0
    var startCompletions = 0
    var stopCalls = 0
    var isRunning = false
}

private actor StaleTickGateway: TravelCommandGateway {
    private var shouldBlockNextKeepAwakeStart = false
    private var keepAwakeStartIsBlocked = false
    private var blockedKeepAwakeContinuation: CheckedContinuation<Void, Never>?
    private var blockedKeepAwakeWaiters: [CheckedContinuation<Void, Never>] = []
    private var keepAwake = StaleTickKeepAwakeSnapshot()
    private var shouldBlockNextCodexRead = false
    private var blockedCodexResult = false
    private var codexReads = 0
    private var blockedCodexRead = false
    private var blockedCodexContinuation: CheckedContinuation<Bool, Never>?
    private var blockedReadWaiters: [CheckedContinuation<Void, Never>] = []
    private var legacyLidClosed = false
    private var legacyStatusReads = 0
    private var legacyLidReads = 0
    private var mutations = StaleTickMutationSnapshot()

    func blockNextKeepAwakeStart() {
        shouldBlockNextKeepAwakeStart = true
    }

    func waitUntilKeepAwakeStartIsBlocked() async {
        if keepAwakeStartIsBlocked { return }
        await withCheckedContinuation { continuation in
            blockedKeepAwakeWaiters.append(continuation)
        }
    }

    func releaseBlockedKeepAwakeStart() {
        keepAwakeStartIsBlocked = false
        blockedKeepAwakeContinuation?.resume()
        blockedKeepAwakeContinuation = nil
    }

    func keepAwakeSnapshot() -> StaleTickKeepAwakeSnapshot {
        keepAwake
    }

    func blockNextCodexRead(returning result: Bool) {
        shouldBlockNextCodexRead = true
        blockedCodexResult = result
    }

    func waitUntilCodexReadIsBlocked() async {
        if blockedCodexRead { return }
        await withCheckedContinuation { continuation in
            blockedReadWaiters.append(continuation)
        }
    }

    func releaseBlockedCodexRead() {
        blockedCodexRead = false
        blockedCodexContinuation?.resume(returning: blockedCodexResult)
        blockedCodexContinuation = nil
    }

    func setLegacyFallbackInputs(lidClosed: Bool) {
        legacyLidClosed = lidClosed
    }

    func codexReadCount() -> Int {
        codexReads
    }

    func legacyObservationCount() -> Int {
        legacyStatusReads + legacyLidReads
    }

    func mutationSnapshot() -> StaleTickMutationSnapshot {
        mutations
    }

    func startKeepAwake() async throws {
        keepAwake.startCalls += 1
        if shouldBlockNextKeepAwakeStart {
            shouldBlockNextKeepAwakeStart = false
            await withCheckedContinuation { continuation in
                keepAwakeStartIsBlocked = true
                blockedKeepAwakeContinuation = continuation
                let waiters = blockedKeepAwakeWaiters
                blockedKeepAwakeWaiters.removeAll()
                waiters.forEach { $0.resume() }
            }
        }
        keepAwake.startCompletions += 1
        keepAwake.isRunning = true
    }

    func stopKeepAwake() async {
        keepAwake.stopCalls += 1
        keepAwake.isRunning = false
    }

    func currentLidClosed() async -> Bool? {
        legacyLidReads += 1
        return legacyLidClosed
    }

    func discoverWiFiDevice() async -> String? {
        "en0"
    }

    func currentWiFiStatus(device: String) async -> WiFiStatus {
        legacyStatusReads += 1
        return WiFiStatus(device: device, networkName: nil, rawOutput: "")
    }

    func currentWiFiPower(device: String) async -> Bool? {
        false
    }

    func setWiFiPower(device: String, enabled: Bool) async -> CommandResult {
        mutations.powerCalls += 1
        return CommandResult(exitCode: 0)
    }

    func joinWiFi(device: String, ssid: String, password: String?) async -> CommandResult {
        mutations.associationCalls += 1
        return CommandResult(exitCode: 0)
    }

    func openWiFiSettings() async {}

    func isCodexRunning() async -> Bool {
        codexReads += 1
        guard shouldBlockNextCodexRead else { return true }
        shouldBlockNextCodexRead = false
        return await withCheckedContinuation { continuation in
            blockedCodexRead = true
            blockedCodexContinuation = continuation
            let waiters = blockedReadWaiters
            blockedReadWaiters.removeAll()
            waiters.forEach { $0.resume() }
        }
    }
}

private actor StaleTickLidProvider: LidStateProviding {
    private var state: LidState

    init(_ state: LidState) {
        self.state = state
    }

    func set(_ state: LidState) {
        self.state = state
    }

    func readLidState(timeout: Duration) async -> ProviderReading<LidState> {
        .value(state)
    }
}

private actor StaleTickConnectivityProvider: WiFiConnectivityProviding {
    private var observation: WiFiConnectivityObservation

    init(_ observation: WiFiConnectivityObservation) {
        self.observation = observation
    }

    func set(_ observation: WiFiConnectivityObservation) {
        self.observation = observation
    }

    func readConnectivity(device: String, timeout: Duration) async -> WiFiConnectivityObservation {
        observation
    }
}

private actor StaleTickReachabilityChecker: OutboundReachabilityChecking {
    func check(timeout: Duration, nonce: String) async -> ReachabilityResult {
        .reachable(statusCode: 204)
    }
}

private actor StaleTickScheduler: HandoffScheduling {
    private var elapsed = Duration.zero

    func now() async -> Duration {
        elapsed
    }

    func sleep(for duration: Duration) async throws {
        try Task.checkCancellation()
        elapsed += duration
        await Task.yield()
        try Task.checkCancellation()
    }
}

private actor StaleTickSessionManager: TravelSessionManaging {
    private var currentLifecycle = TravelSessionLifecycle.off
    private var mutations = StaleTickMutationSnapshot()

    func mutationSnapshot() -> StaleTickMutationSnapshot {
        mutations
    }

    func start(configuration: TravelSessionConfiguration) async -> TravelSessionTransitionResult {
        currentLifecycle = .active
        return TravelSessionTransitionResult(
            lifecycle: .active,
            sessionID: "stale-tick-session"
        )
    }

    func stop() async -> TravelSessionTransitionResult {
        currentLifecycle = .off
        return TravelSessionTransitionResult(lifecycle: .off)
    }

    func requestQuit() async -> TravelSessionTransitionResult {
        currentLifecycle = .off
        return TravelSessionTransitionResult(lifecycle: .off)
    }

    func recover() async -> TravelSessionTransitionResult {
        currentLifecycle = .off
        return TravelSessionTransitionResult(lifecycle: .off)
    }

    func lifecycle() async -> TravelSessionLifecycle {
        currentLifecycle
    }

    func setWiFiPower(device: String, enabled: Bool) async -> CommandResult {
        mutations.powerCalls += 1
        return CommandResult(exitCode: 0)
    }

    func associate(device: String, ssid: String, password: String?) async -> CommandResult {
        mutations.associationCalls += 1
        return CommandResult(exitCode: 0)
    }
}

private struct StaleTickWiFiDiscovery: WiFiDiscoveryProviding {
    func snapshot() async -> WiFiDiscoverySnapshot {
        WiFiDiscoverySnapshot(
            interfaceName: "en0",
            rememberedNetworks: [],
            visibleNetworks: [],
            visibleScanStatus: .completed
        )
    }

    func requestLocationAuthorization() async {}
}

private final class StaleTickSettingsStore: TravelSettingsStoring, @unchecked Sendable {
    private let revision: HotspotConfigurationRevision
    private let password = "private-password"

    init() throws {
        revision = try HotspotConfigurationRevision(
            revisionID: "stale-tick-revision",
            ssid: "iPhone",
            wifiDevice: "en0",
            credentialReference: "stale-tick-credential"
        )
    }

    func load() -> TravelModeSettings {
        TravelModeSettings(hotspotSSID: revision.ssid, wifiDevice: revision.wifiDevice ?? "")
    }

    func hasSavedHotspotPassword() -> Bool {
        true
    }

    func loadHotspotPassword() throws -> String {
        password
    }

    func loadHotspotPassword(credentialReference: String) throws -> String {
        password
    }

    func save(_ settings: TravelModeSettings) throws {}

    func activeHotspotConfiguration() throws -> HotspotConfigurationRevision? {
        revision
    }
}

private func healthyOfficeObservation() -> WiFiConnectivityObservation {
    WiFiConnectivityObservation(
        device: "en0",
        power: .value(true),
        ssid: .value(ExactUTF8String("Office")),
        addresses: .value([IPAddress("192.0.2.10")!]),
        defaultRouteInterface: .value("en0")
    )
}

private func disconnectedObservation() -> WiFiConnectivityObservation {
    WiFiConnectivityObservation(
        device: "en0",
        power: .value(false),
        ssid: .value(nil),
        addresses: .value([]),
        defaultRouteInterface: .value(nil)
    )
}
