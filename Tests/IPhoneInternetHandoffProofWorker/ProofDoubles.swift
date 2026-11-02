import CodexTravelModeCore
import Foundation

let proofPassword = "proof-secret-sentinel-7E4C2A"
let proofDevice = "en0"
let proofTargetSSID = "Example iPhone"

actor ManualHandoffScheduler: HandoffScheduling {
    private var elapsed = Duration.zero
    private let trace: TraceRecorder
    private var blocksSleepsUntilCancelled: Bool

    init(trace: TraceRecorder, blocksSleepsUntilCancelled: Bool = false) {
        self.trace = trace
        self.blocksSleepsUntilCancelled = blocksSleepsUntilCancelled
    }

    func now() -> Duration {
        elapsed
    }

    func sleep(for duration: Duration) async throws {
        try Task.checkCancellation()
        elapsed += duration
        trace.recordSchedulerSleep(duration: duration, elapsed: elapsed)
        if blocksSleepsUntilCancelled {
            trace.recordEvent("scheduler_sleep_blocked", detail: String(durationMilliseconds(duration)))
            do {
                try await Task.sleep(for: .seconds(60))
            } catch {
                trace.recordEvent("scheduler_sleep_cancelled")
                throw CancellationError()
            }
        }
        await Task.yield()
        try Task.checkCancellation()
    }

    func advance(by duration: Duration) {
        elapsed += duration
        trace.recordEvent(
            "scheduler_advanced",
            detail: String(durationMilliseconds(duration)),
            manualTime: elapsed
        )
    }
}

actor RecordingLidProvider: LidStateProviding {
    private var reading: ProviderReading<LidState>
    private let trace: TraceRecorder
    private let scheduler: ManualHandoffScheduler

    init(_ state: LidState, trace: TraceRecorder, scheduler: ManualHandoffScheduler) {
        reading = .value(state)
        self.trace = trace
        self.scheduler = scheduler
    }

    func set(_ state: LidState) {
        reading = .value(state)
        trace.recordEvent("lid_set", detail: state.rawValue)
    }

    func setFailure(_ category: ConnectivityProviderFailureCategory, detail: String) {
        reading = .failure(.init(category: category, detail: detail))
        trace.recordEvent("lid_provider_failure_set", detail: category.rawValue)
    }

    func readLidState(timeout: Duration) async -> ProviderReading<LidState> {
        trace.recordLidRead(reading, timeout: timeout, manualTime: await scheduler.now())
        return reading
    }
}

actor RecordingConnectivityProvider: WiFiConnectivityProviding {
    private var observation: WiFiConnectivityObservation
    private let trace: TraceRecorder
    private let scheduler: ManualHandoffScheduler
    private let advancesByTimeout: Bool
    private var blocksReadsUntilCancelled = false
    private var readDispatches = 0

    init(
        _ observation: WiFiConnectivityObservation,
        trace: TraceRecorder,
        scheduler: ManualHandoffScheduler,
        advancesByTimeout: Bool = false
    ) {
        self.observation = observation
        self.trace = trace
        self.scheduler = scheduler
        self.advancesByTimeout = advancesByTimeout
    }

    func set(_ observation: WiFiConnectivityObservation, event: String = "connectivity_set") {
        self.observation = observation
        trace.recordEvent(event)
    }

    func setPower(_ enabled: Bool) {
        observation = WiFiConnectivityObservation(
            device: observation.device,
            power: .value(enabled),
            ssid: observation.ssid,
            addresses: observation.addresses,
            defaultRouteInterface: observation.defaultRouteInterface
        )
        trace.recordEvent("connectivity_power_set", detail: String(enabled))
    }

    func connect(ssid: String) {
        observation = healthyObservation(ssid: ssid)
        trace.recordEvent("connectivity_associated", detail: hex(Data(ssid.utf8)))
    }

    func setBlocksReadsUntilCancelled(_ value: Bool) {
        blocksReadsUntilCancelled = value
        trace.recordEvent("connectivity_blocking_set", detail: String(value))
    }

    func readDispatchCount() -> Int { readDispatches }

    func readConnectivity(device: String, timeout: Duration) async -> WiFiConnectivityObservation {
        readDispatches += 1
        let startedAt = await scheduler.now()
        trace.recordEvent(
            "connectivity_read_dispatched",
            detail: String(readDispatches),
            manualTime: startedAt
        )
        if blocksReadsUntilCancelled {
            do {
                try await Task.sleep(for: .seconds(60))
            } catch {
                trace.recordEvent("connectivity_read_cancelled", detail: String(readDispatches))
            }
        }
        let value = WiFiConnectivityObservation(
            device: device,
            power: observation.power,
            ssid: observation.ssid,
            addresses: observation.addresses,
            defaultRouteInterface: observation.defaultRouteInterface
        )
        trace.recordConnectivityRead(value, timeout: timeout, manualTime: startedAt)
        if advancesByTimeout {
            await scheduler.advance(by: timeout)
        }
        return value
    }
}

final class RecordingReachabilityChecker: OutboundReachabilityChecking, @unchecked Sendable {
    private let client: URLSessionOutboundReachabilityClient
    private let trace: TraceRecorder
    private let scheduler: ManualHandoffScheduler
    private let advancesByTimeout: Bool
    private let lock = NSLock()
    private var dispatches = 0

    init(
        endpoint: URL,
        trace: TraceRecorder,
        scheduler: ManualHandoffScheduler,
        advancesByTimeout: Bool = false
    ) {
        client = URLSessionOutboundReachabilityClient(endpoint: endpoint)
        self.trace = trace
        self.scheduler = scheduler
        self.advancesByTimeout = advancesByTimeout
    }

    func check(timeout: Duration, nonce: String) async -> ReachabilityResult {
        let callID = UUID().uuidString
        lock.withLock { dispatches += 1 }
        let startedAt = await scheduler.now()
        trace.recordReachabilityDispatch(
            callID: callID,
            timeout: timeout,
            nonce: nonce,
            manualTime: startedAt
        )
        let result = await client.check(timeout: timeout, nonce: nonce)
        if advancesByTimeout {
            await scheduler.advance(by: timeout)
        }
        trace.recordReachabilityReturn(
            callID: callID,
            timeout: timeout,
            nonce: nonce,
            result: result,
            manualTime: await scheduler.now()
        )
        return result
    }

    func dispatchCount() -> Int {
        lock.withLock { dispatches }
    }
}

enum FakeJoinBehavior: Sendable {
    case connectTarget
    case leaveUnchanged
    case commandFailure
    case blockUntilCancelled
}

actor RecordingSessionManager: TravelSessionManaging {
    private let trace: TraceRecorder
    private let connectivity: RecordingConnectivityProvider
    private let scheduler: ManualHandoffScheduler
    private let advancesAssociationByTimeout: Bool
    private var activeSessionID: String
    private var lifecycleState = TravelSessionLifecycle.off
    private var joinBehavior: FakeJoinBehavior
    private var powerCommandFails = false
    private var powerBlocksUntilCancelled = false
    private var powerDispatches = 0
    private var authorizedEpisode: HandoffEpisodeToken?

    init(
        sessionID: String,
        connectivity: RecordingConnectivityProvider,
        trace: TraceRecorder,
        scheduler: ManualHandoffScheduler,
        joinBehavior: FakeJoinBehavior = .connectTarget,
        advancesAssociationByTimeout: Bool = false
    ) {
        activeSessionID = sessionID
        self.connectivity = connectivity
        self.trace = trace
        self.scheduler = scheduler
        self.joinBehavior = joinBehavior
        self.advancesAssociationByTimeout = advancesAssociationByTimeout
    }

    func setJoinBehavior(_ value: FakeJoinBehavior) {
        joinBehavior = value
        trace.recordEvent("join_behavior_set", sessionID: activeSessionID, detail: String(describing: value))
    }

    func setPowerCommandFails(_ value: Bool) {
        powerCommandFails = value
        trace.recordEvent("power_behavior_set", sessionID: activeSessionID, detail: value ? "command_failure" : "success")
    }

    func setPowerBlocksUntilCancelled(_ value: Bool) {
        powerBlocksUntilCancelled = value
        trace.recordEvent("power_blocking_set", sessionID: activeSessionID, detail: String(value))
    }

    func powerDispatchCount() -> Int { powerDispatches }

    func setActiveSessionID(_ value: String) {
        activeSessionID = value
        authorizedEpisode = nil
        trace.recordEvent("active_session_set", sessionID: value)
    }

    func start(configuration: TravelSessionConfiguration) -> TravelSessionTransitionResult {
        lifecycleState = .active
        authorizedEpisode = nil
        trace.recordCommand(
            source: "session_manager_fake",
            phase: "return",
            operation: "session_start",
            sessionID: activeSessionID,
            device: configuration.wifiDevice,
            result: CommandResult(exitCode: 0)
        )
        return TravelSessionTransitionResult(
            lifecycle: .active,
            sessionID: activeSessionID,
            canTerminate: false
        )
    }

    func stop() -> TravelSessionTransitionResult {
        lifecycleState = .off
        authorizedEpisode = nil
        trace.recordCommand(
            source: "session_manager_fake",
            phase: "return",
            operation: "session_stop",
            sessionID: activeSessionID,
            result: CommandResult(exitCode: 0)
        )
        return TravelSessionTransitionResult(lifecycle: .off)
    }

    func requestQuit() -> TravelSessionTransitionResult {
        stop()
    }

    func recover() -> TravelSessionTransitionResult {
        stop()
    }

    func lifecycle() -> TravelSessionLifecycle {
        lifecycleState
    }

    func authorizeHandoffEpisode(_ token: HandoffEpisodeToken) async -> CommandResult {
        let manualTime = await scheduler.now()
        trace.recordCommand(
            source: "session_manager_fake",
            phase: "dispatch",
            operation: "handoff_authorize",
            episode: token,
            manualTime: manualTime
        )
        let result: CommandResult
        if token.sessionID != activeSessionID || token.episodeID.isEmpty {
            result = CommandResult(
                exitCode: 1,
                standardError: "stale handoff episode",
                failureCategory: .staleSession
            )
        } else if let authorizedEpisode, authorizedEpisode != token {
            result = CommandResult(
                exitCode: 1,
                standardError: "another handoff episode is authorized",
                failureCategory: .staleSession
            )
        } else {
            authorizedEpisode = token
            result = CommandResult(exitCode: 0)
        }
        trace.recordCommand(
            source: "session_manager_fake",
            phase: "return",
            operation: "handoff_authorize",
            episode: token,
            result: result,
            manualTime: await scheduler.now()
        )
        return result
    }

    func finishHandoffEpisode(_ token: HandoffEpisodeToken) async {
        await recordEpisodeClosure(operation: "handoff_finish", token: token)
    }

    func cancelHandoffEpisode(_ token: HandoffEpisodeToken) async {
        await recordEpisodeClosure(operation: "handoff_cancel", token: token)
    }

    private func recordEpisodeClosure(operation: String, token: HandoffEpisodeToken) async {
        trace.recordCommand(
            source: "session_manager_fake",
            phase: "dispatch",
            operation: operation,
            episode: token,
            manualTime: await scheduler.now()
        )
        let result: CommandResult
        if authorizedEpisode == token {
            authorizedEpisode = nil
            result = CommandResult(exitCode: 0)
        } else {
            result = CommandResult(
                exitCode: 1,
                standardError: "handoff episode is not authorized",
                failureCategory: .staleSession
            )
        }
        trace.recordCommand(
            source: "session_manager_fake",
            phase: "return",
            operation: operation,
            episode: token,
            result: result,
            manualTime: await scheduler.now()
        )
    }

    func setWiFiPower(device: String, enabled: Bool) async -> CommandResult {
        await setWiFiPower(
            expectedSessionID: activeSessionID,
            device: device,
            enabled: enabled,
            timeout: HandoffRetryPolicy.production.powerTimeout
        )
    }

    func setWiFiPower(
        expectedSessionID: String,
        device: String,
        enabled: Bool,
        timeout: Duration
    ) async -> CommandResult {
        await performWiFiPower(
            sessionID: expectedSessionID,
            episode: nil,
            attempt: nil,
            device: device,
            enabled: enabled,
            timeout: timeout
        )
    }

    func setWiFiPower(
        operation: HandoffOperationIdentity,
        device: String,
        enabled: Bool,
        timeout: Duration
    ) async -> CommandResult {
        await performWiFiPower(
            sessionID: operation.episode.sessionID,
            episode: operation.episode,
            attempt: operation.attempt,
            device: device,
            enabled: enabled,
            timeout: timeout
        )
    }

    private func performWiFiPower(
        sessionID: String,
        episode: HandoffEpisodeToken?,
        attempt: Int?,
        device: String,
        enabled: Bool,
        timeout: Duration
    ) async -> CommandResult {
        powerDispatches += 1
        let startedAt = await scheduler.now()
        trace.recordCommand(
            source: "session_manager_fake",
            phase: "dispatch",
            operation: "wifi_power",
            sessionID: sessionID,
            episode: episode,
            attempt: attempt,
            device: device,
            power: enabled,
            timeout: timeout,
            manualTime: startedAt
        )
        let result: CommandResult
        if !operationIsAuthorized(sessionID: sessionID, episode: episode, attempt: attempt) {
            result = CommandResult(exitCode: 1, standardError: "stale session", failureCategory: .staleSession)
        } else if powerBlocksUntilCancelled {
            do {
                try await Task.sleep(for: .seconds(60))
                result = CommandResult(exitCode: 9, standardError: "blocking power command released")
            } catch {
                result = CommandResult(exitCode: 130, standardError: "power command cancelled", failureCategory: .cancelled)
            }
        } else if powerCommandFails {
            result = CommandResult(exitCode: 9, standardError: "power command failed", failureCategory: .commandFailed)
        } else {
            await connectivity.setPower(enabled)
            result = CommandResult(exitCode: 0)
        }
        trace.recordCommand(
            source: "session_manager_fake",
            phase: "return",
            operation: "wifi_power",
            sessionID: sessionID,
            episode: episode,
            attempt: attempt,
            device: device,
            power: enabled,
            timeout: timeout,
            result: result,
            manualTime: await scheduler.now()
        )
        return result
    }

    func associate(device: String, ssid: String, password: String?) async -> CommandResult {
        await associate(
            expectedSessionID: activeSessionID,
            device: device,
            ssid: ssid,
            password: password,
            timeout: HandoffRetryPolicy.production.associationTimeout
        )
    }

    func associate(
        expectedSessionID: String,
        device: String,
        ssid: String,
        password: String?,
        timeout: Duration
    ) async -> CommandResult {
        await performAssociation(
            sessionID: expectedSessionID,
            episode: nil,
            attempt: nil,
            device: device,
            ssid: ssid,
            timeout: timeout
        )
    }

    func associate(
        operation: HandoffOperationIdentity,
        device: String,
        ssid: String,
        password: String?,
        timeout: Duration
    ) async -> CommandResult {
        await performAssociation(
            sessionID: operation.episode.sessionID,
            episode: operation.episode,
            attempt: operation.attempt,
            device: device,
            ssid: ssid,
            timeout: timeout
        )
    }

    private func performAssociation(
        sessionID: String,
        episode: HandoffEpisodeToken?,
        attempt: Int?,
        device: String,
        ssid: String,
        timeout: Duration
    ) async -> CommandResult {
        let startedAt = await scheduler.now()
        trace.recordCommand(
            source: "session_manager_fake",
            phase: "dispatch",
            operation: "associate",
            sessionID: sessionID,
            episode: episode,
            attempt: attempt,
            device: device,
            ssid: ssid,
            timeout: timeout,
            manualTime: startedAt
        )
        if advancesAssociationByTimeout {
            await scheduler.advance(by: timeout)
        }
        let behavior = joinBehavior
        let result: CommandResult
        if !operationIsAuthorized(sessionID: sessionID, episode: episode, attempt: attempt) {
            result = CommandResult(exitCode: 1, standardError: "stale session", failureCategory: .staleSession)
        } else {
            switch behavior {
            case .connectTarget:
                await connectivity.connect(ssid: ssid)
                result = CommandResult(exitCode: 0)
            case .leaveUnchanged:
                result = CommandResult(exitCode: 0)
            case .commandFailure:
                result = CommandResult(exitCode: 8, standardError: "association command failed", failureCategory: .commandFailed)
            case .blockUntilCancelled:
                do {
                    try await Task.sleep(for: .seconds(60))
                    result = CommandResult(exitCode: 8, standardError: "blocking association released")
                } catch {
                    result = CommandResult(exitCode: 130, standardError: "association cancelled", failureCategory: .cancelled)
                }
            }
        }
        trace.recordCommand(
            source: "session_manager_fake",
            phase: "return",
            operation: "associate",
            sessionID: sessionID,
            episode: episode,
            attempt: attempt,
            device: device,
            ssid: ssid,
            timeout: timeout,
            result: result,
            manualTime: await scheduler.now()
        )
        return result
    }

    private func operationIsAuthorized(
        sessionID: String,
        episode: HandoffEpisodeToken?,
        attempt: Int?
    ) -> Bool {
        guard sessionID == activeSessionID else { return false }
        guard let episode else { return true }
        guard let attempt, attempt > 0 else { return false }
        return authorizedEpisode == episode
    }
}

final class IdentityRecordingSessionManager: TravelSessionManaging, @unchecked Sendable {
    private let base: any TravelSessionManaging
    private let trace: TraceRecorder
    private let scheduler: ManualHandoffScheduler

    init(
        base: any TravelSessionManaging,
        trace: TraceRecorder,
        scheduler: ManualHandoffScheduler
    ) {
        self.base = base
        self.trace = trace
        self.scheduler = scheduler
    }

    func start(configuration: TravelSessionConfiguration) async -> TravelSessionTransitionResult {
        await base.start(configuration: configuration)
    }

    func stop() async -> TravelSessionTransitionResult { await base.stop() }
    func requestQuit() async -> TravelSessionTransitionResult { await base.requestQuit() }
    func recover() async -> TravelSessionTransitionResult { await base.recover() }
    func lifecycle() async -> TravelSessionLifecycle { await base.lifecycle() }
    func protectionEvents() async -> AsyncStream<SleepOverrideLeaseProtectionEvent> {
        await base.protectionEvents()
    }

    func setWiFiPower(device: String, enabled: Bool) async -> CommandResult {
        await base.setWiFiPower(device: device, enabled: enabled)
    }

    func setWiFiPower(
        expectedSessionID: String,
        device: String,
        enabled: Bool,
        timeout: Duration
    ) async -> CommandResult {
        await base.setWiFiPower(
            expectedSessionID: expectedSessionID,
            device: device,
            enabled: enabled,
            timeout: timeout
        )
    }

    func associate(device: String, ssid: String, password: String?) async -> CommandResult {
        await base.associate(device: device, ssid: ssid, password: password)
    }

    func associate(
        device: String,
        ssid: String,
        password: String?,
        timeout: Duration
    ) async -> CommandResult {
        await base.associate(device: device, ssid: ssid, password: password, timeout: timeout)
    }

    func associate(
        expectedSessionID: String,
        device: String,
        ssid: String,
        password: String?,
        timeout: Duration
    ) async -> CommandResult {
        await base.associate(
            expectedSessionID: expectedSessionID,
            device: device,
            ssid: ssid,
            password: password,
            timeout: timeout
        )
    }

    func authorizeHandoffEpisode(_ token: HandoffEpisodeToken) async -> CommandResult {
        trace.recordCommand(
            source: "session_manager_real_proxy",
            phase: "dispatch",
            operation: "handoff_authorize",
            episode: token,
            manualTime: await scheduler.now()
        )
        let result = await base.authorizeHandoffEpisode(token)
        trace.recordCommand(
            source: "session_manager_real_proxy",
            phase: "return",
            operation: "handoff_authorize",
            episode: token,
            result: result,
            manualTime: await scheduler.now()
        )
        return result
    }

    func finishHandoffEpisode(_ token: HandoffEpisodeToken) async {
        trace.recordCommand(
            source: "session_manager_real_proxy",
            phase: "dispatch",
            operation: "handoff_finish",
            episode: token,
            manualTime: await scheduler.now()
        )
        await base.finishHandoffEpisode(token)
        trace.recordCommand(
            source: "session_manager_real_proxy",
            phase: "return",
            operation: "handoff_finish",
            episode: token,
            result: CommandResult(exitCode: 0),
            manualTime: await scheduler.now()
        )
    }

    func cancelHandoffEpisode(_ token: HandoffEpisodeToken) async {
        trace.recordCommand(
            source: "session_manager_real_proxy",
            phase: "dispatch",
            operation: "handoff_cancel",
            episode: token,
            manualTime: await scheduler.now()
        )
        await base.cancelHandoffEpisode(token)
        trace.recordCommand(
            source: "session_manager_real_proxy",
            phase: "return",
            operation: "handoff_cancel",
            episode: token,
            result: CommandResult(exitCode: 0),
            manualTime: await scheduler.now()
        )
    }

    func setWiFiPower(
        operation: HandoffOperationIdentity,
        device: String,
        enabled: Bool,
        timeout: Duration
    ) async -> CommandResult {
        trace.recordCommand(
            source: "session_manager_real_proxy",
            phase: "dispatch",
            operation: "wifi_power",
            episode: operation.episode,
            attempt: operation.attempt,
            device: device,
            power: enabled,
            timeout: timeout,
            manualTime: await scheduler.now()
        )
        let result = await base.setWiFiPower(
            operation: operation,
            device: device,
            enabled: enabled,
            timeout: timeout
        )
        trace.recordCommand(
            source: "session_manager_real_proxy",
            phase: "return",
            operation: "wifi_power",
            episode: operation.episode,
            attempt: operation.attempt,
            device: device,
            power: enabled,
            timeout: timeout,
            result: result,
            manualTime: await scheduler.now()
        )
        return result
    }

    func associate(
        operation: HandoffOperationIdentity,
        device: String,
        ssid: String,
        password: String?,
        timeout: Duration
    ) async -> CommandResult {
        trace.recordCommand(
            source: "session_manager_real_proxy",
            phase: "dispatch",
            operation: "associate",
            episode: operation.episode,
            attempt: operation.attempt,
            device: device,
            ssid: ssid,
            timeout: timeout,
            manualTime: await scheduler.now()
        )
        let result = await base.associate(
            operation: operation,
            device: device,
            ssid: ssid,
            password: password,
            timeout: timeout
        )
        trace.recordCommand(
            source: "session_manager_real_proxy",
            phase: "return",
            operation: "associate",
            episode: operation.episode,
            attempt: operation.attempt,
            device: device,
            ssid: ssid,
            timeout: timeout,
            result: result,
            manualTime: await scheduler.now()
        )
        return result
    }
}

final class ProofSettingsStore: TravelSettingsStoring, @unchecked Sendable {
    private let revision: HotspotConfigurationRevision

    init(ssid: String = proofTargetSSID, device: String = proofDevice) throws {
        revision = try HotspotConfigurationRevision(
            revisionID: "proof-config-revision",
            ssid: ssid,
            wifiDevice: device,
            credentialReference: "proof-keychain-reference"
        )
    }

    func load() -> TravelModeSettings {
        TravelModeSettings(hotspotSSID: revision.ssid, wifiDevice: revision.wifiDevice ?? "")
    }

    func hasSavedHotspotPassword() -> Bool { true }
    func loadHotspotPassword() throws -> String { proofPassword }
    func loadHotspotPassword(credentialReference: String) throws -> String { proofPassword }
    func save(_ settings: TravelModeSettings) throws {}
    func recoverHotspotConfiguration() throws {}
    func activeHotspotConfiguration() throws -> HotspotConfigurationRevision? { revision }
    func legacyHotspotDraft() -> TravelModeSettings? { nil }
}

actor ProofGateway: TravelCommandGateway {
    private let trace: TraceRecorder

    init(trace: TraceRecorder) {
        self.trace = trace
    }

    func startKeepAwake() {
        trace.recordEvent("keep_awake_started")
    }

    func stopKeepAwake() {
        trace.recordEvent("keep_awake_stopped")
    }

    func currentLidClosed() -> Bool? { nil }
    func discoverWiFiDevice() -> String? { proofDevice }
    func currentWiFiStatus(device: String) -> WiFiStatus {
        WiFiStatus(device: device, networkName: nil, rawOutput: "proof gateway")
    }
    func currentWiFiPower(device: String) -> Bool? { true }
    func setWiFiPower(device: String, enabled: Bool) -> CommandResult { CommandResult(exitCode: 0) }
    func joinWiFi(device: String, ssid: String, password: String?) -> CommandResult { CommandResult(exitCode: 0) }
    func openWiFiSettings() {}
    func isCodexRunning() -> Bool { true }
}

actor ProofDiscoveryProvider: WiFiDiscoveryProviding {
    func snapshot() -> WiFiDiscoverySnapshot {
        WiFiDiscoverySnapshot(
            interfaceName: proofDevice,
            rememberedNetworks: [],
            visibleNetworks: [],
            visibleScanStatus: .completed
        )
    }

    func requestLocationAuthorization() {}
}

actor RecordingJournalStore: TravelSessionJournalStoring {
    private var journal: TravelSessionJournal?
    private let trace: TraceRecorder

    init(trace: TraceRecorder) {
        self.trace = trace
    }

    func load() throws -> TravelSessionJournal? {
        if let journal { trace.recordJournal(operation: "load", journal: journal) }
        return journal
    }

    func create(_ candidate: TravelSessionJournal) throws -> TravelSessionJournal {
        guard journal == nil else { throw TravelSessionJournalError.alreadyExists }
        journal = candidate
        trace.recordJournal(operation: "create", journal: candidate)
        return candidate
    }

    func update(
        _ candidate: TravelSessionJournal,
        expectedRevision: Int
    ) throws -> TravelSessionJournal {
        guard let current = journal else { throw TravelSessionJournalError.missing }
        guard current.sessionID == candidate.sessionID else { throw TravelSessionJournalError.staleSession }
        guard current.revision == expectedRevision else {
            throw TravelSessionJournalError.staleRevision(expected: expectedRevision, actual: current.revision)
        }
        var updated = candidate
        updated.revision = expectedRevision + 1
        journal = updated
        trace.recordJournal(operation: "update", journal: updated)
        return updated
    }

    func clear(sessionID: String, expectedRevision: Int) throws {
        guard let current = journal else { throw TravelSessionJournalError.missing }
        guard current.sessionID == sessionID else { throw TravelSessionJournalError.staleSession }
        guard current.revision == expectedRevision else {
            throw TravelSessionJournalError.staleRevision(expected: expectedRevision, actual: current.revision)
        }
        trace.recordJournalClear(sessionID: sessionID, revision: expectedRevision)
        journal = nil
    }
}

enum SystemAssociationBehavior: Sendable {
    case connect
    case commandFailure
    case failFirstThenConnect
    case blockUntilCancelled
}

actor RecordingSessionSystem: TravelSessionSystemControlling, WiFiConnectivityProviding {
    private var power: Bool
    private var ssid: String?
    private var associationBehavior: SystemAssociationBehavior
    private var associationDispatches = 0
    private let trace: TraceRecorder

    init(
        power: Bool,
        ssid: String?,
        trace: TraceRecorder,
        associationBehavior: SystemAssociationBehavior = .connect
    ) {
        self.power = power
        self.ssid = ssid
        self.trace = trace
        self.associationBehavior = associationBehavior
    }

    func setAssociationBehavior(_ value: SystemAssociationBehavior) {
        associationBehavior = value
        trace.recordEvent("system_association_behavior_set", detail: String(describing: value))
    }

    func currentWiFiPower(device: String) -> Bool { power }
    func currentAssociatedSSID(device: String) -> String? { ssid }

    func setWiFiPower(device: String, enabled: Bool) -> CommandResult {
        trace.recordCommand(
            source: "travel_session_system",
            phase: "dispatch",
            operation: "wifi_power",
            device: device,
            power: enabled
        )
        power = enabled
        let result = CommandResult(exitCode: 0)
        trace.recordCommand(
            source: "travel_session_system",
            phase: "return",
            operation: "wifi_power",
            device: device,
            power: enabled,
            result: result
        )
        return result
    }

    func associate(device: String, ssid: String, password: String?) async -> CommandResult {
        await associate(device: device, ssid: ssid, password: password, timeout: .seconds(10))
    }

    func associate(
        device: String,
        ssid: String,
        password: String?,
        timeout: Duration
    ) async -> CommandResult {
        associationDispatches += 1
        trace.recordCommand(
            source: "travel_session_system",
            phase: "dispatch",
            operation: "associate",
            device: device,
            ssid: ssid,
            timeout: timeout
        )
        let behavior = associationBehavior
        let result: CommandResult
        switch behavior {
        case .connect:
            self.ssid = ssid
            result = CommandResult(exitCode: 0)
        case .commandFailure:
            result = CommandResult(exitCode: 7, standardError: "system association failed", failureCategory: .commandFailed)
        case .failFirstThenConnect:
            if associationDispatches == 1 {
                result = CommandResult(
                    exitCode: 7,
                    standardError: "first system association failed",
                    failureCategory: .commandFailed
                )
            } else {
                self.ssid = ssid
                result = CommandResult(exitCode: 0)
            }
        case .blockUntilCancelled:
            do {
                try await Task.sleep(for: .seconds(60))
                result = CommandResult(exitCode: 7, standardError: "blocking system association released")
            } catch {
                result = CommandResult(exitCode: 130, standardError: "system association cancelled", failureCategory: .cancelled)
            }
        }
        trace.recordCommand(
            source: "travel_session_system",
            phase: "return",
            operation: "associate",
            device: device,
            ssid: ssid,
            timeout: timeout,
            result: result
        )
        return result
    }

    func readConnectivity(device: String, timeout: Duration) -> WiFiConnectivityObservation {
        let observation: WiFiConnectivityObservation
        if power, let ssid {
            observation = healthyObservation(ssid: ssid)
        } else {
            observation = disconnectedObservation(power: power)
        }
        trace.recordConnectivityRead(observation, timeout: timeout)
        return observation
    }
}

final class ProofLeaseClient: SleepOverrideLeaseClient, @unchecked Sendable {
    func acquire(sessionID: String, requestID: String) async throws -> SleepOverrideLeaseReceipt {
        receipt(sessionID: sessionID, requestID: requestID, leaseID: "lease-\(sessionID)", phase: .active)
    }

    func resolve(sessionID: String, requestID: String) async throws -> SleepOverrideLeaseResolution {
        .found(receipt(sessionID: sessionID, requestID: requestID, leaseID: "lease-\(sessionID)", phase: .active))
    }

    func status(binding: SleepOverrideLeaseBinding) async throws -> SleepOverrideLeaseReceipt {
        SleepOverrideLeaseReceipt(phase: .released, binding: binding)
    }

    func release(binding: SleepOverrideLeaseBinding) async throws -> SleepOverrideLeaseReceipt {
        SleepOverrideLeaseReceipt(phase: .released, binding: binding)
    }

    func acknowledgeRelease(binding: SleepOverrideLeaseBinding) async throws {}

    private func receipt(
        sessionID: String,
        requestID: String,
        leaseID: String,
        phase: SleepOverrideLeasePhase
    ) -> SleepOverrideLeaseReceipt {
        SleepOverrideLeaseReceipt(
            phase: phase,
            binding: SleepOverrideLeaseBinding(
                sessionID: sessionID,
                requestID: requestID,
                leaseID: leaseID,
                generation: "proof-generation"
            )
        )
    }
}

func healthyObservation(ssid: String, device: String = proofDevice) -> WiFiConnectivityObservation {
    WiFiConnectivityObservation(
        device: device,
        power: .value(true),
        ssid: .value(ExactUTF8String(ssid)),
        addresses: .value([IPAddress("10.23.45.67")!]),
        defaultRouteInterface: .value(device)
    )
}

func disconnectedObservation(power: Bool, device: String = proofDevice) -> WiFiConnectivityObservation {
    WiFiConnectivityObservation(
        device: device,
        power: .value(power),
        ssid: .value(nil),
        addresses: .value([]),
        defaultRouteInterface: .value(nil)
    )
}

func providerFailureObservation(device: String = proofDevice) -> WiFiConnectivityObservation {
    let failure = ConnectivityProviderFailure(category: .commandFailed, detail: "provider command failed")
    return WiFiConnectivityObservation(
        device: device,
        power: .failure(failure),
        ssid: .failure(failure),
        addresses: .failure(failure),
        defaultRouteInterface: .failure(failure)
    )
}
