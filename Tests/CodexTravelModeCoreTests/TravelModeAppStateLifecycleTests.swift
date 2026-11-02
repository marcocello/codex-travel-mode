import Foundation
import XCTest
@testable import CodexTravelModeCore

@MainActor
final class TravelModeAppStateLifecycleTests: XCTestCase {
    func testStartupBeginsRecoveringThenCleanOffQuitMakesNoMutationCalls() async {
        let manager = LifecycleSessionManager(lifecycle: .off)
        let gateway = LifecycleGateway()
        let app = makeLifecycleApp(gateway: gateway, manager: manager)

        XCTAssertEqual(app.lifecyclePresentation, .recovering)
        await app.recoverPreviousSessionIfNeeded()
        XCTAssertEqual(app.lifecyclePresentation, .off)
        XCTAssertTrue(app.isCleanlyOffForTermination)
        let before = await manager.counts()

        let canQuit = await app.requestQuit()
        let after = await manager.counts()
        let gatewayCounts = await gateway.mutationCounts()
        XCTAssertTrue(canQuit)
        XCTAssertEqual(after, before)
        XCTAssertEqual(gatewayCounts, LifecycleGateway.Counts())
        XCTAssertFalse(app.hasPendingQuitIntent)
    }

    func testPreparingActiveRestoringAndOffFollowStructuredLifecycle() async {
        let manager = LifecycleSessionManager(lifecycle: .off)
        await manager.setSuspended(.start, true)
        let gateway = LifecycleGateway()
        let app = makeLifecycleApp(gateway: gateway, manager: manager)

        let start = Task { @MainActor in await app.start() }
        await manager.waitForCount(.start, 1)
        XCTAssertEqual(app.lifecyclePresentation, .preparing)
        await manager.resume(.start)
        await start.value
        XCTAssertEqual(app.lifecyclePresentation, .active)

        await manager.setSuspended(.stop, true)
        let stop = Task { @MainActor in await app.stop() }
        await manager.waitForCount(.stop, 1)
        XCTAssertEqual(app.lifecyclePresentation, .restoring)
        XCTAssertFalse(app.isCleanlyOffForTermination)
        await manager.resume(.stop)
        await stop.value

        XCTAssertEqual(app.lifecyclePresentation, .off)
        XCTAssertTrue(app.isCleanlyOffForTermination)
    }

    func testStopFailureHasNoQuitIntentAndRetryUsesRecovery() async {
        let unsafe = "sudo pmset -b disablesleep 1 --password sentinel-secret"
        let manager = LifecycleSessionManager(
            lifecycle: .off,
            stopResults: [
                TravelSessionTransitionResult(
                    lifecycle: .cleanupRequired,
                    warning: unsafe,
                    error: unsafe,
                    canTerminate: false
                )
            ],
            recoverResults: [TravelSessionTransitionResult(lifecycle: .off)]
        )
        let gateway = LifecycleGateway()
        let app = makeLifecycleApp(gateway: gateway, manager: manager)
        await app.start()

        await app.stop()

        XCTAssertEqual(app.lifecyclePresentation, .cleanupRequired)
        XCTAssertFalse(app.hasPendingQuitIntent)
        XCTAssertFalse(app.canStart)
        assertNoUnsafeSessionText(app, sentinel: "sentinel-secret")

        let shouldTerminate = await app.retryCleanup()
        XCTAssertFalse(shouldTerminate)
        XCTAssertEqual(app.lifecyclePresentation, .off)
        XCTAssertTrue(app.isCleanlyOffForTermination)
        let counts = await manager.counts()
        XCTAssertEqual(counts.stop, 1)
        XCTAssertEqual(counts.recover, 1)
        XCTAssertEqual(counts.quit, 0)
    }

    func testQuitFailurePreservesIntentAndRetryCanAuthorizeTermination() async {
        let manager = LifecycleSessionManager(
            lifecycle: .off,
            quitResults: [
                TravelSessionTransitionResult(
                    lifecycle: .cleanupRequired,
                    error: "raw-script sentinel-password",
                    canTerminate: false
                ),
                TravelSessionTransitionResult(lifecycle: .off),
            ]
        )
        let app = makeLifecycleApp(gateway: LifecycleGateway(), manager: manager)
        await app.start()

        let firstQuit = await app.requestQuit()
        XCTAssertFalse(firstQuit)
        XCTAssertTrue(app.hasPendingQuitIntent)
        XCTAssertEqual(app.lifecyclePresentation, .cleanupRequired)
        assertNoUnsafeSessionText(app, sentinel: "sentinel-password")

        let retryCanTerminate = await app.retryCleanup()
        XCTAssertTrue(retryCanTerminate)
        XCTAssertTrue(app.hasPendingQuitIntent)
        XCTAssertTrue(app.isCleanlyOffForTermination)
        let retryCounts = await manager.counts()
        XCTAssertEqual(retryCounts.quit, 2)
    }

    func testQuitDuringStartupRecoveryCoalescesWithOwnedRecovery() async {
        let manager = LifecycleSessionManager(
            lifecycle: .cleanupRequired,
            recoverResults: [TravelSessionTransitionResult(lifecycle: .off)]
        )
        await manager.setSuspended(.recover, true)
        let app = makeLifecycleApp(gateway: LifecycleGateway(), manager: manager)

        let recovery = Task { @MainActor in await app.recoverPreviousSessionIfNeeded() }
        await manager.waitForCount(.recover, 1)
        XCTAssertEqual(app.lifecyclePresentation, .recovering)

        let quit = Task { @MainActor in await app.requestQuit() }
        await Task.yield()
        XCTAssertTrue(app.hasPendingQuitIntent)
        var counts = await manager.counts()
        XCTAssertEqual(counts.recover, 1)
        XCTAssertEqual(counts.quit, 0)

        await manager.resume(.recover)
        await recovery.value
        let canQuit = await quit.value
        XCTAssertTrue(canQuit)
        counts = await manager.counts()
        XCTAssertEqual(counts.recover, 1)
        XCTAssertEqual(counts.quit, 0)
        XCTAssertTrue(app.isCleanlyOffForTermination)
    }

    func testStopWaitsForDelayedOuterStartCompensationBeforeOff() async {
        let manager = LifecycleSessionManager(lifecycle: .off)
        let gateway = LifecycleGateway(suspendStartKeepAwake: true)
        let app = makeLifecycleApp(gateway: gateway, manager: manager)

        let start = Task { @MainActor in await app.start() }
        await gateway.waitForStartCount(1)
        let stop = Task { @MainActor in await app.stop() }
        await manager.waitForCount(.stop, 1)
        await Task.yield()

        XCTAssertEqual(app.lifecyclePresentation, .restoring)
        XCTAssertFalse(app.isCleanlyOffForTermination)
        await gateway.resumeStartKeepAwake()
        await start.value
        await stop.value

        XCTAssertEqual(app.lifecyclePresentation, .off)
        XCTAssertTrue(app.isCleanlyOffForTermination)
        let gatewayCounts = await gateway.mutationCounts()
        XCTAssertGreaterThanOrEqual(gatewayCounts.stopKeepAwake, 2)
    }

    func testQuitWaitsForDelayedOuterStartCompensationAndKeepsIntent() async {
        let manager = LifecycleSessionManager(lifecycle: .off)
        let gateway = LifecycleGateway(suspendStartKeepAwake: true)
        let app = makeLifecycleApp(gateway: gateway, manager: manager)

        let start = Task { @MainActor in await app.start() }
        await gateway.waitForStartCount(1)
        let quit = Task { @MainActor in await app.requestQuit() }
        await manager.waitForCount(.quit, 1)
        await Task.yield()

        XCTAssertTrue(app.hasPendingQuitIntent)
        XCTAssertEqual(app.lifecyclePresentation, .restoring)
        XCTAssertFalse(app.isCleanlyOffForTermination)
        await gateway.resumeStartKeepAwake()
        await start.value

        let canQuit = await quit.value
        XCTAssertTrue(canQuit)
        XCTAssertTrue(app.isCleanlyOffForTermination)
        let counts = await manager.counts()
        XCTAssertEqual(counts.quit, 1)
    }

    func testRepeatedStopRetryAndQuitCoalesceOneCleanupAttempt() async {
        let manager = LifecycleSessionManager(lifecycle: .off)
        let app = makeLifecycleApp(gateway: LifecycleGateway(), manager: manager)
        await app.start()
        await manager.setSuspended(.stop, true)

        let firstStop = Task { @MainActor in await app.stop() }
        await manager.waitForCount(.stop, 1)
        let secondStop = Task { @MainActor in await app.stop() }
        let retry = Task { @MainActor in await app.retryCleanup() }
        let quit = Task { @MainActor in await app.requestQuit() }
        await Task.yield()

        let inFlightCounts = await manager.counts()
        XCTAssertEqual(inFlightCounts.stop, 1)
        XCTAssertTrue(app.hasPendingQuitIntent)
        await manager.resume(.stop)
        await firstStop.value
        await secondStop.value
        _ = await retry.value
        let canQuit = await quit.value
        XCTAssertTrue(canQuit)
        let counts = await manager.counts()
        XCTAssertEqual(counts.stop, 1)
        XCTAssertEqual(counts.recover, 0)
        XCTAssertEqual(counts.quit, 0)
    }

    func testStartFailureCompensatesWithoutWaitingOnItsOwnFence() async {
        let manager = LifecycleSessionManager(lifecycle: .off)
        let gateway = LifecycleGateway(failStartKeepAwake: true)
        let app = makeLifecycleApp(gateway: gateway, manager: manager)

        await app.start()

        XCTAssertEqual(app.lifecyclePresentation, .off)
        XCTAssertTrue(app.isCleanlyOffForTermination)
        let counts = await manager.counts()
        XCTAssertEqual(counts.stop, 1)
        XCTAssertEqual(app.lastErrorMessage, "Travel Mode could not start safely.")
    }

    private func assertNoUnsafeSessionText(
        _ app: TravelModeAppState,
        sentinel: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let exposed = ([app.latestStatus, app.lastErrorMessage ?? ""] + app.logs)
            .joined(separator: "\n")
            .lowercased()
        XCTAssertFalse(exposed.contains(sentinel.lowercased()), file: file, line: line)
        XCTAssertFalse(exposed.contains("sudo"), file: file, line: line)
        XCTAssertFalse(exposed.contains("pmset"), file: file, line: line)
        XCTAssertFalse(exposed.contains("--password"), file: file, line: line)
    }
}

@MainActor
private func makeLifecycleApp(
    gateway: LifecycleGateway,
    manager: LifecycleSessionManager
) -> TravelModeAppState {
    TravelModeAppState(
        gateway: gateway,
        settingsStore: LifecycleSettingsStore(),
        wifiDiscovery: LifecycleDiscoveryProvider(),
        sessionManager: manager
    )
}

private final class LifecycleSettingsStore: TravelSettingsStoring, @unchecked Sendable {
    private let revision = try! HotspotConfigurationRevision(
        revisionID: "lifecycle-revision",
        ssid: "Configured iPhone",
        wifiDevice: "en0",
        credentialReference: "lifecycle-credential"
    )

    func load() -> TravelModeSettings {
        TravelModeSettings(hotspotSSID: revision.ssid, wifiDevice: revision.wifiDevice ?? "")
    }

    func hasSavedHotspotPassword() -> Bool { true }
    func loadHotspotPassword() throws -> String { "fixture-password" }

    func loadHotspotPassword(credentialReference: String) throws -> String {
        XCTAssertEqual(credentialReference, revision.credentialReference)
        return "fixture-password"
    }

    func save(_ settings: TravelModeSettings) throws {}
    func activeHotspotConfiguration() throws -> HotspotConfigurationRevision? { revision }
}

private actor LifecycleDiscoveryProvider: WiFiDiscoveryProviding {
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

private actor LifecycleGateway: TravelCommandGateway {
    struct Counts: Equatable {
        var startKeepAwake = 0
        var stopKeepAwake = 0
        var wifiPower = 0
        var association = 0
    }

    private enum FixtureError: Error { case startFailed }
    private let suspendStartKeepAwake: Bool
    private let failStartKeepAwake: Bool
    private var counts = Counts()
    private var startWaiters: [CheckedContinuation<Void, Never>] = []

    init(suspendStartKeepAwake: Bool = false, failStartKeepAwake: Bool = false) {
        self.suspendStartKeepAwake = suspendStartKeepAwake
        self.failStartKeepAwake = failStartKeepAwake
    }

    func startKeepAwake() async throws {
        counts.startKeepAwake += 1
        if suspendStartKeepAwake {
            await withCheckedContinuation { startWaiters.append($0) }
        }
        if failStartKeepAwake { throw FixtureError.startFailed }
    }

    func stopKeepAwake() async { counts.stopKeepAwake += 1 }
    func currentLidClosed() async -> Bool? { false }
    func discoverWiFiDevice() async -> String? { "en0" }
    func currentWiFiStatus(device: String) async -> WiFiStatus {
        WiFiStatus(device: device, networkName: "Office", rawOutput: "Office")
    }
    func currentWiFiPower(device: String) async -> Bool? { true }
    func setWiFiPower(device: String, enabled: Bool) async -> CommandResult {
        counts.wifiPower += 1
        return CommandResult(exitCode: 0)
    }
    func joinWiFi(device: String, ssid: String, password: String?) async -> CommandResult {
        counts.association += 1
        return CommandResult(exitCode: 0)
    }
    func openWiFiSettings() async {}
    func isCodexRunning() async -> Bool { true }

    func waitForStartCount(_ expected: Int) async {
        while counts.startKeepAwake < expected { await Task.yield() }
    }

    func resumeStartKeepAwake() {
        let waiters = startWaiters
        startWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    func mutationCounts() -> Counts { counts }
}

private actor LifecycleSessionManager: TravelSessionManaging {
    enum Operation: Hashable { case start, stop, quit, recover }

    struct Counts: Equatable {
        var lifecycle = 0
        var start = 0
        var stop = 0
        var quit = 0
        var recover = 0
    }

    private var currentLifecycle: TravelSessionLifecycle
    private var startResults: [TravelSessionTransitionResult]
    private var stopResults: [TravelSessionTransitionResult]
    private var quitResults: [TravelSessionTransitionResult]
    private var recoverResults: [TravelSessionTransitionResult]
    private var currentCounts = Counts()
    private var suspended: Set<Operation> = []
    private var waiters: [Operation: [CheckedContinuation<Void, Never>]] = [:]

    init(
        lifecycle: TravelSessionLifecycle,
        startResults: [TravelSessionTransitionResult] = [
            TravelSessionTransitionResult(
                lifecycle: .active,
                sessionID: "lifecycle-session",
                canTerminate: false
            )
        ],
        stopResults: [TravelSessionTransitionResult] = [
            TravelSessionTransitionResult(lifecycle: .off)
        ],
        quitResults: [TravelSessionTransitionResult] = [
            TravelSessionTransitionResult(lifecycle: .off)
        ],
        recoverResults: [TravelSessionTransitionResult] = [
            TravelSessionTransitionResult(lifecycle: .off)
        ]
    ) {
        self.currentLifecycle = lifecycle
        self.startResults = startResults
        self.stopResults = stopResults
        self.quitResults = quitResults
        self.recoverResults = recoverResults
    }

    func start(configuration: TravelSessionConfiguration) async -> TravelSessionTransitionResult {
        currentCounts.start += 1
        await pauseIfNeeded(.start)
        return consume(&startResults, fallback: .active)
    }

    func stop() async -> TravelSessionTransitionResult {
        currentCounts.stop += 1
        await pauseIfNeeded(.stop)
        return consume(&stopResults, fallback: .off)
    }

    func requestQuit() async -> TravelSessionTransitionResult {
        currentCounts.quit += 1
        await pauseIfNeeded(.quit)
        return consume(&quitResults, fallback: .off)
    }

    func recover() async -> TravelSessionTransitionResult {
        currentCounts.recover += 1
        await pauseIfNeeded(.recover)
        return consume(&recoverResults, fallback: .off)
    }

    func lifecycle() async -> TravelSessionLifecycle {
        currentCounts.lifecycle += 1
        return currentLifecycle
    }

    func setWiFiPower(device: String, enabled: Bool) async -> CommandResult {
        CommandResult(exitCode: 0)
    }

    func associate(device: String, ssid: String, password: String?) async -> CommandResult {
        CommandResult(exitCode: 0)
    }

    func setSuspended(_ operation: Operation, _ value: Bool) {
        if value {
            suspended.insert(operation)
        } else {
            suspended.remove(operation)
        }
    }

    func waitForCount(_ operation: Operation, _ expected: Int) async {
        while count(for: operation) < expected { await Task.yield() }
    }

    func resume(_ operation: Operation) {
        suspended.remove(operation)
        let continuations = waiters.removeValue(forKey: operation) ?? []
        continuations.forEach { $0.resume() }
    }

    func counts() -> Counts { currentCounts }

    private func pauseIfNeeded(_ operation: Operation) async {
        guard suspended.contains(operation) else { return }
        await withCheckedContinuation { continuation in
            waiters[operation, default: []].append(continuation)
        }
    }

    private func count(for operation: Operation) -> Int {
        switch operation {
        case .start: currentCounts.start
        case .stop: currentCounts.stop
        case .quit: currentCounts.quit
        case .recover: currentCounts.recover
        }
    }

    private func consume(
        _ results: inout [TravelSessionTransitionResult],
        fallback: TravelSessionLifecycle
    ) -> TravelSessionTransitionResult {
        let result = results.isEmpty
            ? TravelSessionTransitionResult(lifecycle: fallback)
            : results.removeFirst()
        currentLifecycle = result.lifecycle
        return result
    }
}
