import CodexTravelModeCore
import XCTest

final class TravelInternetHandoffCoordinatorTests: XCTestCase {
    func testInitiallyClosedHealthyTargetDoesNotMutateWiFi() async throws {
        let harness = makeHarness(lid: .closed, observation: healthyObservation(ssid: "iPhone"))

        _ = await harness.coordinator.activate(harness.context)
        let publication = try await waitForPublication(harness.coordinator) {
            if case .connectedViaConfiguredHotspot = $0.state { return true }
            return false
        }

        XCTAssertEqual(publication.sessionID, harness.context.sessionID)
        let commands = await harness.session.commands()
        XCTAssertEqual(commands, [])
    }

    func testOpenToClosedHandoffJoinsOnceAndHealthyTicksDoNotChurn() async throws {
        let harness = makeHarness(lid: .open, observation: healthyObservation(ssid: "Office"))
        await harness.session.setConnectOnJoin(true)
        _ = await harness.coordinator.activate(harness.context)

        await harness.lid.set(.closed)
        _ = await harness.coordinator.tick(generation: harness.context.generation)
        _ = try await waitForPublication(harness.coordinator) {
            if case .connectedViaConfiguredHotspot = $0.state { return true }
            return false
        }
        for _ in 0..<10 {
            _ = await harness.coordinator.tick(generation: harness.context.generation)
        }

        let commands = await harness.session.commands()
        XCTAssertEqual(commands, ["join:iPhone"])
    }

    func testExhaustionLatchesUntilExplicitRetry() async throws {
        let harness = makeHarness(lid: .closed, observation: disconnectedObservation(power: true))
        _ = await harness.coordinator.activate(harness.context)
        _ = try await waitForPublication(harness.coordinator) {
            if case .failed = $0.state { return $0.episodeID != nil }
            return false
        }

        for _ in 0..<10 {
            _ = await harness.coordinator.tick(generation: harness.context.generation)
        }
        let exhaustedCommands = await harness.session.commands()
        XCTAssertEqual(exhaustedCommands, ["join:iPhone", "join:iPhone", "join:iPhone"])

        _ = await harness.coordinator.retry(generation: harness.context.generation)
        _ = try await waitForCommandCount(harness.session, count: 6)
        let retriedCommands = await harness.session.commands()
        XCTAssertEqual(retriedCommands.count, 6)
    }

    func testPowerIsEnabledBeforeAssociation() async throws {
        let harness = makeHarness(lid: .closed, observation: disconnectedObservation(power: false))
        await harness.session.setConnectOnJoin(true)

        _ = await harness.coordinator.activate(harness.context)
        _ = try await waitForPublication(harness.coordinator) {
            if case .connectedViaConfiguredHotspot = $0.state { return true }
            return false
        }

        let commands = await harness.session.commands()
        XCTAssertEqual(commands, ["power:true", "join:iPhone"])
    }

    func testInitialOpenDisconnectionWaitsButConfirmedDisconnectionFallsBack() async throws {
        let harness = makeHarness(lid: .open, observation: disconnectedObservation(power: true))
        await harness.session.setConnectOnJoin(true)
        _ = await harness.coordinator.activate(harness.context)
        let initialCommands = await harness.session.commands()
        XCTAssertEqual(initialCommands, [])

        await harness.connectivity.set(healthyObservation(ssid: "Office"))
        _ = await harness.coordinator.tick(generation: harness.context.generation)
        await harness.connectivity.set(disconnectedObservation(power: true))
        _ = await harness.coordinator.tick(generation: harness.context.generation)
        _ = try await waitForCommandCount(harness.session, count: 1)

        let commands = await harness.session.commands()
        XCTAssertEqual(commands, ["join:iPhone"])
    }

    func testOpenProviderGapCannotSynthesizeAssociatedToDisconnectedFallback() async throws {
        let harness = makeHarness(lid: .open, observation: healthyObservation(ssid: "Office"))
        await harness.session.setConnectOnJoin(true)
        _ = await harness.coordinator.activate(harness.context)

        await harness.connectivity.set(WiFiConnectivityObservation(
            device: "en0",
            power: .failure(ConnectivityProviderFailure(
                category: .commandFailed,
                detail: "temporary provider failure"
            )),
            ssid: .value(nil),
            addresses: .value([]),
            defaultRouteInterface: .value(nil)
        ))
        _ = await harness.coordinator.tick(generation: harness.context.generation)
        await harness.connectivity.set(disconnectedObservation(power: true))
        _ = await harness.coordinator.tick(generation: harness.context.generation)

        let commands = await harness.session.commands()
        XCTAssertEqual(commands, [])
    }

    func testReopeningCancelsCloseOwnedAssociationAndLaterCloseStartsOneFreshEpisode() async throws {
        let harness = makeHarness(lid: .open, observation: healthyObservation(ssid: "Office"))
        await harness.session.setConnectOnJoin(true)
        await harness.session.gateAssociationCalls([1])
        _ = await harness.coordinator.activate(harness.context)

        await harness.lid.set(.closed)
        _ = await harness.coordinator.tick(generation: harness.context.generation)
        _ = try await waitForCommandCount(harness.session, count: 1)

        await harness.lid.set(.open)
        _ = await harness.coordinator.tick(generation: harness.context.generation)
        let reopened = await harness.coordinator.currentPublication()
        XCTAssertEqual(reopened.state, .waitingForConnection)

        await harness.lid.set(.closed)
        _ = await harness.coordinator.tick(generation: harness.context.generation)
        await harness.session.releaseAssociation(call: 1)

        _ = try await waitForCommandCount(harness.session, count: 2)
        _ = try await waitForPublication(harness.coordinator) {
            if case .connectedViaConfiguredHotspot = $0.state { return true }
            return false
        }
        for _ in 0..<10 {
            _ = await harness.coordinator.tick(generation: harness.context.generation)
        }

        let commands = await harness.session.commands()
        let cancelledCalls = await harness.session.cancelledAssociationCalls()
        let sessionIDs = await harness.session.expectedSessionIDs()
        XCTAssertEqual(commands, ["join:iPhone", "join:iPhone"])
        XCTAssertEqual(cancelledCalls, [1])
        XCTAssertEqual(sessionIDs, [harness.context.sessionID, harness.context.sessionID])
    }

    func testInvalidateDuringAssociationCannotRetryOrPublishAfterRelease() async throws {
        let harness = makeHarness(lid: .closed, observation: disconnectedObservation(power: true))
        await harness.session.gateAssociationCalls([1])
        _ = await harness.coordinator.activate(harness.context)
        _ = try await waitForCommandCount(harness.session, count: 1)

        let cancelledEpisode = await harness.coordinator.invalidate(
            generation: harness.context.generation
        )
        let invalidatedPublication = await harness.coordinator.currentPublication()
        XCTAssertEqual(
            invalidatedPublication,
            TravelInternetStatePublication(
                sessionID: nil,
                generation: nil,
                episodeID: nil,
                state: .inactive
            )
        )

        await harness.session.releaseAssociation(call: 1)
        await cancelledEpisode?.value
        for _ in 0..<5 {
            _ = await harness.coordinator.tick(generation: harness.context.generation)
        }

        let commands = await harness.session.commands()
        let cancelledCalls = await harness.session.cancelledAssociationCalls()
        let finalPublication = await harness.coordinator.currentPublication()
        XCTAssertEqual(commands, ["join:iPhone"])
        XCTAssertEqual(cancelledCalls, [1])
        XCTAssertEqual(finalPublication.state, .inactive)
    }

    func testStaleSessionAssociationFailureIsTerminal() async throws {
        let harness = makeHarness(lid: .closed, observation: disconnectedObservation(power: true))
        await harness.session.setAssociationResults([
            CommandResult(
                exitCode: 1,
                standardError: "The active session changed.",
                failureCategory: .staleSession
            )
        ])

        _ = await harness.coordinator.activate(harness.context)
        let publication = try await waitForPublication(harness.coordinator) {
            if case .failed(let failure) = $0.state {
                return failure.kind == .staleSession
            }
            return false
        }

        guard case .failed(let failure) = publication.state else {
            return XCTFail("Expected a terminal stale-session failure.")
        }
        XCTAssertEqual(failure.kind, .staleSession)
        XCTAssertFalse(failure.retryable)
        let commands = await harness.session.commands()
        XCTAssertEqual(commands, ["join:iPhone"])
    }

    func testClosedPathLossQueuesOneRecoveryUntilFiveSecondCooldownExpires() async throws {
        let scheduler = ManualHandoffScheduler()
        let harness = makeHarness(
            lid: .closed,
            observation: healthyObservation(ssid: "iPhone"),
            scheduler: scheduler
        )
        await harness.session.setConnectOnJoin(true)
        _ = await harness.coordinator.activate(harness.context)
        _ = try await waitForPublication(harness.coordinator) {
            if case .connectedViaConfiguredHotspot = $0.state { return true }
            return false
        }

        await harness.connectivity.set(disconnectedObservation(power: true))
        _ = await harness.coordinator.tick(generation: harness.context.generation)
        await scheduler.advance(by: .seconds(4))
        for _ in 0..<5 {
            _ = await harness.coordinator.tick(generation: harness.context.generation)
        }
        let commandsDuringCooldown = await harness.session.commands()
        XCTAssertEqual(commandsDuringCooldown, [])

        await scheduler.advance(by: .seconds(1))
        _ = await harness.coordinator.tick(generation: harness.context.generation)
        _ = try await waitForCommandCount(harness.session, count: 1)
        _ = try await waitForPublication(harness.coordinator) {
            if case .connectedViaConfiguredHotspot = $0.state { return true }
            return false
        }
        for _ in 0..<10 {
            _ = await harness.coordinator.tick(generation: harness.context.generation)
        }

        let commandsAfterRecovery = await harness.session.commands()
        XCTAssertEqual(commandsAfterRecovery, ["join:iPhone"])
    }

    func testClosedProviderGapDoesNotEraseLaterAuthoritativeTargetLoss() async throws {
        let scheduler = ManualHandoffScheduler()
        let harness = makeHarness(
            lid: .closed,
            observation: healthyObservation(ssid: "iPhone"),
            scheduler: scheduler
        )
        await harness.session.setConnectOnJoin(true)
        _ = await harness.coordinator.activate(harness.context)
        _ = try await waitForPublication(harness.coordinator) {
            if case .connectedViaConfiguredHotspot = $0.state { return true }
            return false
        }

        await harness.connectivity.set(WiFiConnectivityObservation(
            device: "en0",
            power: .failure(ConnectivityProviderFailure(
                category: .commandFailed,
                detail: "temporary provider failure"
            )),
            ssid: .value(nil),
            addresses: .value([]),
            defaultRouteInterface: .value(nil)
        ))
        _ = await harness.coordinator.tick(generation: harness.context.generation)
        await harness.connectivity.set(disconnectedObservation(power: true))
        _ = await harness.coordinator.tick(generation: harness.context.generation)
        let commandsDuringGap = await harness.session.commands()
        XCTAssertEqual(commandsDuringGap, [])

        await scheduler.advance(by: .seconds(5))
        _ = await harness.coordinator.tick(generation: harness.context.generation)
        _ = try await waitForCommandCount(harness.session, count: 1)

        let commandsAfterRecovery = await harness.session.commands()
        XCTAssertEqual(commandsAfterRecovery, ["join:iPhone"])
    }

    func testCanonicallyEquivalentButByteDistinctSSIDIsNotHealthyTarget() async throws {
        let composed = ExactUTF8String("\u{00E9}")!
        let decomposed = ExactUTF8String("e\u{0301}")!
        XCTAssertEqual(composed.stringValue, decomposed.stringValue)
        XCTAssertNotEqual(composed.utf8Bytes, decomposed.utf8Bytes)

        let connectivity = CoordinatorConnectivityProvider(
            healthyObservation(ssid: decomposed.stringValue)
        )
        let session = CoordinatorSessionManager(connectivity: connectivity)
        let engine = TravelInternetHandoffEngine(
            connectivityProvider: connectivity,
            reachabilityChecker: CoordinatorReachabilityChecker(),
            sessionManager: session
        )
        let context = HandoffSessionContext(
            sessionID: "session-exact-bytes",
            device: "en0",
            targetSSID: composed,
            password: "private-password"
        )

        let evaluation = try await engine.inspect(
            context: context,
            deadline: .seconds(30),
            scheduler: ImmediateHandoffScheduler()
        )

        XCTAssertEqual(evaluation.classification, .healthyOther(decomposed))
        XCTAssertFalse(evaluation.classification.isHealthyTarget)
    }

    @MainActor
    func testAppStateBindsReturnedSessionIDAndInvalidatesBeforeSessionStop() async throws {
        let durableSessionID = "durable-session-42"
        let lid = CoordinatorLidProvider(.closed)
        let connectivity = CoordinatorConnectivityProvider(disconnectedObservation(power: true))
        let session = CoordinatorSessionManager(connectivity: connectivity)
        await session.setStartSessionID(durableSessionID)
        await session.gateAssociationCalls([1])
        let engine = TravelInternetHandoffEngine(
            connectivityProvider: connectivity,
            reachabilityChecker: CoordinatorReachabilityChecker(),
            sessionManager: session
        )
        let coordinator = TravelInternetHandoffCoordinator(
            lidProvider: lid,
            engine: engine,
            scheduler: ImmediateHandoffScheduler()
        )
        await session.observeCoordinatorWhenStopping(coordinator)
        let app = TravelModeAppState(
            gateway: HandoffAppGateway(),
            settingsStore: HandoffAppSettingsStore(),
            wifiDiscovery: HandoffAppWiFiDiscovery(),
            sessionManager: session,
            internetHandoffCoordinator: coordinator
        )

        await app.start()
        _ = try await waitForCommandCount(session, count: 1)
        let expectedSessionIDs = await session.expectedSessionIDs()
        XCTAssertEqual(expectedSessionIDs, [durableSessionID])

        let stopTask = Task { @MainActor in
            await app.stop()
        }
        try await waitForSessionStop(session)
        let stopObservedInactive = await session.stopObservedInactiveCoordinator()
        XCTAssertTrue(stopObservedInactive)
        await session.releaseAssociation(call: 1)
        await stopTask.value

        XCTAssertEqual(app.internetRuntimeState, .inactive)
        let cancelledCalls = await session.cancelledAssociationCalls()
        let commands = await session.commands()
        XCTAssertEqual(cancelledCalls, [1])
        XCTAssertEqual(commands, ["join:iPhone"])
    }
}

private struct CoordinatorHarness {
    let coordinator: TravelInternetHandoffCoordinator
    let context: HandoffSessionContext
    let lid: CoordinatorLidProvider
    let connectivity: CoordinatorConnectivityProvider
    let session: CoordinatorSessionManager
}

private func makeHarness(
    lid: LidState,
    observation: WiFiConnectivityObservation,
    scheduler: any HandoffScheduling = ImmediateHandoffScheduler(),
    policy: HandoffRetryPolicy = .production
) -> CoordinatorHarness {
    let lidProvider = CoordinatorLidProvider(lid)
    let connectivity = CoordinatorConnectivityProvider(observation)
    let session = CoordinatorSessionManager(connectivity: connectivity)
    let engine = TravelInternetHandoffEngine(
        connectivityProvider: connectivity,
        reachabilityChecker: CoordinatorReachabilityChecker(),
        sessionManager: session,
        policy: policy
    )
    let coordinator = TravelInternetHandoffCoordinator(
        lidProvider: lidProvider,
        engine: engine,
        scheduler: scheduler,
        policy: policy
    )
    let context = HandoffSessionContext(
        sessionID: "session-A",
        generation: UUID(),
        device: "en0",
        targetSSID: ExactUTF8String("iPhone")!,
        password: "private-password"
    )
    return CoordinatorHarness(
        coordinator: coordinator,
        context: context,
        lid: lidProvider,
        connectivity: connectivity,
        session: session
    )
}

private actor CoordinatorLidProvider: LidStateProviding {
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

private actor CoordinatorConnectivityProvider: WiFiConnectivityProviding {
    private var observation: WiFiConnectivityObservation

    init(_ observation: WiFiConnectivityObservation) {
        self.observation = observation
    }

    func set(_ observation: WiFiConnectivityObservation) {
        self.observation = observation
    }

    func setPower(_ enabled: Bool) {
        observation = WiFiConnectivityObservation(
            device: observation.device,
            power: .value(enabled),
            ssid: observation.ssid,
            addresses: observation.addresses,
            defaultRouteInterface: observation.defaultRouteInterface
        )
    }

    func connect(ssid: String) {
        observation = healthyObservation(ssid: ssid)
    }

    func readConnectivity(device: String, timeout: Duration) async -> WiFiConnectivityObservation {
        observation
    }
}

private actor CoordinatorReachabilityChecker: OutboundReachabilityChecking {
    func check(timeout: Duration, nonce: String) async -> ReachabilityResult {
        .reachable(statusCode: 204)
    }
}

private actor ImmediateHandoffScheduler: HandoffScheduling {
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

private actor ManualHandoffScheduler: HandoffScheduling {
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

    func advance(by duration: Duration) {
        elapsed += duration
    }
}

private actor CoordinatorSessionManager: TravelSessionManaging {
    private let connectivity: CoordinatorConnectivityProvider
    private var commandLog: [String] = []
    private var connectOnJoin = false
    private var associationResults: [CommandResult] = []
    private var gatedAssociationCalls: Set<Int> = []
    private var associationWaiters: [Int: CheckedContinuation<Void, Never>] = [:]
    private var releasedAssociationCalls: Set<Int> = []
    private var cancelledAssociationCallLog: [Int] = []
    private var expectedSessionIDLog: [String] = []
    private var configuredStartSessionID = "session-A"
    private var currentLifecycle = TravelSessionLifecycle.off
    private var stopCount = 0
    private var coordinatorObservedOnStop: TravelInternetHandoffCoordinator?
    private var stopObservedInactive = false

    init(connectivity: CoordinatorConnectivityProvider) {
        self.connectivity = connectivity
    }

    func setConnectOnJoin(_ enabled: Bool) {
        connectOnJoin = enabled
    }

    func setAssociationResults(_ results: [CommandResult]) {
        associationResults = results
    }

    func gateAssociationCalls(_ calls: Set<Int>) {
        gatedAssociationCalls = calls
    }

    func releaseAssociation(call: Int) {
        releasedAssociationCalls.insert(call)
        associationWaiters.removeValue(forKey: call)?.resume()
    }

    func cancelledAssociationCalls() -> [Int] {
        cancelledAssociationCallLog
    }

    func expectedSessionIDs() -> [String] {
        expectedSessionIDLog
    }

    func setStartSessionID(_ sessionID: String) {
        configuredStartSessionID = sessionID
    }

    func observeCoordinatorWhenStopping(_ coordinator: TravelInternetHandoffCoordinator) {
        coordinatorObservedOnStop = coordinator
    }

    func stopCallCount() -> Int {
        stopCount
    }

    func stopObservedInactiveCoordinator() -> Bool {
        stopObservedInactive
    }

    func commands() -> [String] {
        commandLog
    }

    func start(configuration: TravelSessionConfiguration) async -> TravelSessionTransitionResult {
        currentLifecycle = .active
        return TravelSessionTransitionResult(lifecycle: .active, sessionID: configuredStartSessionID)
    }

    func stop() async -> TravelSessionTransitionResult {
        stopCount += 1
        if let coordinatorObservedOnStop {
            let publication = await coordinatorObservedOnStop.currentPublication()
            stopObservedInactive = publication.state == .inactive
        }
        currentLifecycle = .off
        return TravelSessionTransitionResult(lifecycle: .off)
    }

    func requestQuit() async -> TravelSessionTransitionResult {
        TravelSessionTransitionResult(lifecycle: .off)
    }

    func recover() async -> TravelSessionTransitionResult {
        TravelSessionTransitionResult(lifecycle: .off)
    }

    func lifecycle() async -> TravelSessionLifecycle {
        currentLifecycle
    }

    func setWiFiPower(device: String, enabled: Bool) async -> CommandResult {
        await setWiFiPower(
            expectedSessionID: "session-A",
            device: device,
            enabled: enabled,
            timeout: .seconds(3)
        )
    }

    func setWiFiPower(
        expectedSessionID: String,
        device: String,
        enabled: Bool,
        timeout: Duration
    ) async -> CommandResult {
        commandLog.append("power:\(enabled)")
        await connectivity.setPower(enabled)
        return CommandResult(exitCode: 0)
    }

    func associate(device: String, ssid: String, password: String?) async -> CommandResult {
        await associate(
            expectedSessionID: "session-A",
            device: device,
            ssid: ssid,
            password: password,
            timeout: .seconds(5)
        )
    }

    func associate(
        expectedSessionID: String,
        device: String,
        ssid: String,
        password: String?,
        timeout: Duration
    ) async -> CommandResult {
        expectedSessionIDLog.append(expectedSessionID)
        commandLog.append("join:\(ssid)")
        let call = commandLog.lazy.filter { $0.hasPrefix("join:") }.count
        if gatedAssociationCalls.contains(call), !releasedAssociationCalls.contains(call) {
            await withCheckedContinuation { continuation in
                associationWaiters[call] = continuation
            }
        }
        if Task.isCancelled {
            cancelledAssociationCallLog.append(call)
            return CommandResult(
                exitCode: 130,
                standardError: "association cancelled",
                failureCategory: .cancelled
            )
        }
        let result = associationResults.indices.contains(call - 1)
            ? associationResults[call - 1]
            : CommandResult(exitCode: 0)
        if connectOnJoin, result.succeeded {
            await connectivity.connect(ssid: ssid)
        }
        return result
    }
}

private func healthyObservation(ssid: String) -> WiFiConnectivityObservation {
    WiFiConnectivityObservation(
        device: "en0",
        power: .value(true),
        ssid: .value(ExactUTF8String(ssid)),
        addresses: .value([IPAddress("10.0.0.2")!]),
        defaultRouteInterface: .value("en0")
    )
}

private func disconnectedObservation(power: Bool) -> WiFiConnectivityObservation {
    WiFiConnectivityObservation(
        device: "en0",
        power: .value(power),
        ssid: .value(nil),
        addresses: .value([]),
        defaultRouteInterface: .value(nil)
    )
}

private func waitForPublication(
    _ coordinator: TravelInternetHandoffCoordinator,
    predicate: (TravelInternetStatePublication) -> Bool
) async throws -> TravelInternetStatePublication {
    for _ in 0..<500 {
        let publication = await coordinator.currentPublication()
        if predicate(publication) { return publication }
        try await Task.sleep(for: .milliseconds(2))
    }
    XCTFail("Timed out waiting for Travel Internet state.")
    return await coordinator.currentPublication()
}

private func waitForCommandCount(
    _ session: CoordinatorSessionManager,
    count: Int
) async throws -> [String] {
    for _ in 0..<500 {
        let commands = await session.commands()
        if commands.count >= count { return commands }
        try await Task.sleep(for: .milliseconds(2))
    }
    XCTFail("Timed out waiting for \(count) commands.")
    return await session.commands()
}

private func waitForSessionStop(_ session: CoordinatorSessionManager) async throws {
    for _ in 0..<500 {
        if await session.stopCallCount() > 0 { return }
        try await Task.sleep(for: .milliseconds(2))
    }
    XCTFail("Timed out waiting for transactional Stop.")
}

private final class HandoffAppGateway: TravelCommandGateway, @unchecked Sendable {
    func startKeepAwake() async throws {}
    func stopKeepAwake() async {}
    func currentLidClosed() async -> Bool? { true }
    func discoverWiFiDevice() async -> String? { "en0" }
    func currentWiFiStatus(device: String) async -> WiFiStatus {
        WiFiStatus(device: device, networkName: nil, rawOutput: "not associated")
    }
    func currentWiFiPower(device: String) async -> Bool? { true }
    func setWiFiPower(device: String, enabled: Bool) async -> CommandResult {
        CommandResult(exitCode: 0)
    }
    func joinWiFi(device: String, ssid: String, password: String?) async -> CommandResult {
        CommandResult(exitCode: 0)
    }
    func openWiFiSettings() async {}
    func isCodexRunning() async -> Bool { true }
}

private final class HandoffAppSettingsStore: TravelSettingsStoring, @unchecked Sendable {
    private let revision = try! HotspotConfigurationRevision(
        revisionID: "handoff-app-revision",
        ssid: "iPhone",
        wifiDevice: "en0",
        credentialReference: "handoff-app-credential"
    )

    func load() -> TravelModeSettings {
        TravelModeSettings(hotspotSSID: "iPhone", wifiDevice: "en0")
    }

    func hasSavedHotspotPassword() -> Bool { true }
    func loadHotspotPassword() throws -> String { "private-password" }

    func loadHotspotPassword(credentialReference: String) throws -> String {
        XCTAssertEqual(credentialReference, revision.credentialReference)
        return "private-password"
    }

    func save(_ settings: TravelModeSettings) throws {}
    func activeHotspotConfiguration() throws -> HotspotConfigurationRevision? { revision }
}

private actor HandoffAppWiFiDiscovery: WiFiDiscoveryProviding {
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
