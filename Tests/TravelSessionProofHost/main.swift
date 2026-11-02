import CodexTravelModeCore
import Darwin
import Foundation

private struct HostArguments {
    var scenario: String
    var workspace: URL
    var checkpoint: String?

    init(arguments: [String]) throws {
        var values: [String: String] = [:]
        var index = 1
        while index < arguments.count {
            guard index + 1 < arguments.count, arguments[index].hasPrefix("--") else {
                throw HostError.invalidArguments
            }
            values[arguments[index]] = arguments[index + 1]
            index += 2
        }
        guard let scenario = values["--scenario"],
              let workspace = values["--workspace"] else {
            throw HostError.invalidArguments
        }
        self.scenario = scenario
        self.workspace = URL(fileURLWithPath: workspace, isDirectory: true)
        self.checkpoint = values["--checkpoint"]
    }
}

private enum HostError: LocalizedError {
    case invalidArguments
    case unsupportedScenario(String)
    case timedOut(String)
    case unexpectedResult(String)
    case missingState(String)

    var errorDescription: String? {
        switch self {
        case .invalidArguments:
            "Usage: travel-session-proof-host --scenario NAME --workspace PATH [--checkpoint NAME]"
        case .unsupportedScenario(let scenario):
            "Unsupported proof scenario: \(scenario)"
        case .timedOut(let stage):
            "Timed out waiting for proof stage: \(stage)"
        case .unexpectedResult(let detail):
            "Unexpected coordinator result: \(detail)"
        case .missingState(let detail):
            "Required proof state is missing: \(detail)"
        }
    }
}

private struct ProviderMutationArtifact: Codable, Sendable {
    var kind: String
    var target: String?
    var succeeded: Bool
}

private struct ProviderArtifact: Codable, Sendable {
    var wifiPower: Bool
    var ssid: String?
    var unrelatedPowerValue: Int
    var mutations: [ProviderMutationArtifact]

    enum CodingKeys: String, CodingKey {
        case wifiPower = "wifi_power"
        case ssid
        case unrelatedPowerValue = "unrelated_power_value"
        case mutations
    }
}

private struct LeaseMutationArtifact: Codable, Sendable {
    var kind: String
    var binding: SleepOverrideLeaseBinding?

    init(kind: String, binding: SleepOverrideLeaseBinding? = nil) {
        self.kind = kind
        self.binding = binding
    }
}

private struct LeaseArtifact: Codable, Sendable {
    var phase: String
    var activeBinding: SleepOverrideLeaseBinding?
    var releasedReceipt: SleepOverrideLeaseBinding?
    var mutations: [LeaseMutationArtifact]

    enum CodingKeys: String, CodingKey {
        case phase
        case activeBinding = "active_binding"
        case releasedReceipt = "released_receipt"
        case mutations
    }
}

private struct TraceEventArtifact: Codable, Sendable {
    var sequence: Int
    var kind: String
    var sessionID: String?
    var value: String?

    enum CodingKeys: String, CodingKey {
        case sequence
        case kind
        case sessionID = "session_id"
        case value
    }
}

private enum PowerWriteBehavior: Sendable {
    case normal
    case fail
    case reportSuccessWithoutChange
}

private enum SystemBlockingStage: Sendable {
    case capture
    case mutationDispatch
    case verification
}

private actor FileBackedSystemController: TravelSessionSystemControlling {
    private let fileURL: URL
    private let journalURL: URL
    private var state: ProviderArtifact
    private var powerWriteBehavior: PowerWriteBehavior = .normal
    private var failedAssociationTargets: Set<String> = []
    private var hangingAssociationTargets: Set<String> = []
    private var captureFailure = false
    private var blockingStage: SystemBlockingStage?
    private var stageMarkerURL: URL?
    private var stageGateURL: URL?
    private var stageWasReached = false
    private var wifiReadCount = 0

    init(
        fileURL: URL,
        journalURL: URL,
        initialPower: Bool,
        initialSSID: String?
    ) throws {
        self.fileURL = fileURL
        self.journalURL = journalURL
        if FileManager.default.fileExists(atPath: fileURL.path) {
            self.state = try decodeJSON(ProviderArtifact.self, at: fileURL)
        } else {
            self.state = ProviderArtifact(
                wifiPower: initialPower,
                ssid: initialSSID,
                unrelatedPowerValue: 17,
                mutations: []
            )
            try writeJSON(self.state, to: fileURL)
        }
    }

    func configurePowerWrite(_ behavior: PowerWriteBehavior) {
        powerWriteBehavior = behavior
    }

    func configureCaptureFailure(_ enabled: Bool) {
        captureFailure = enabled
    }

    func configureAssociationFailure(target: String, enabled: Bool) {
        if enabled {
            failedAssociationTargets.insert(target)
        } else {
            failedAssociationTargets.remove(target)
        }
    }

    func configureAssociationHang(target: String, enabled: Bool) {
        if enabled {
            hangingAssociationTargets.insert(target)
        } else {
            hangingAssociationTargets.remove(target)
        }
    }

    func configureBlockingStage(
        _ stage: SystemBlockingStage?,
        markerURL: URL?,
        gateURL: URL? = nil
    ) {
        blockingStage = stage
        stageMarkerURL = markerURL
        stageGateURL = gateURL
        stageWasReached = false
    }

    func snapshot() -> ProviderArtifact {
        state
    }

    func currentWiFiPower(device: String) async throws -> Bool {
        wifiReadCount += 1
        if captureFailure {
            throw TravelSessionSystemError.stateUnavailable("injected Wi-Fi power capture failure")
        }
        if blockingStage == .capture, wifiReadCount == 1, !stageWasReached {
            try await blockThrowing(stage: "capture")
        }
        if blockingStage == .verification, wifiReadCount >= 3, !stageWasReached {
            try await blockThrowing(stage: "verification")
        }
        return state.wifiPower
    }

    func currentAssociatedSSID(device: String) async throws -> String? {
        state.ssid
    }

    func setWiFiPower(device: String, enabled: Bool) async -> CommandResult {
        if blockingStage == .mutationDispatch, !stageWasReached {
            await blockNonThrowing(stage: "mutation-dispatch")
        }
        guard intentAllows(kind: .wifiPower, target: String(enabled)) else {
            return CommandResult(
                exitCode: 1,
                standardError: "Wi-Fi power command had no readable prepared journal intent."
            )
        }
        let succeeded = powerWriteBehavior != .fail
        state.mutations.append(
            ProviderMutationArtifact(
                kind: "set_wifi_power",
                target: String(enabled),
                succeeded: succeeded
            )
        )
        if powerWriteBehavior == .normal {
            state.wifiPower = enabled
        }
        do {
            try persist()
        } catch {
            return CommandResult(exitCode: 1, standardError: error.localizedDescription)
        }
        return succeeded
            ? CommandResult(exitCode: 0)
            : CommandResult(exitCode: 1, standardError: "injected Wi-Fi power write failure")
    }

    func associate(device: String, ssid: String, password: String?) async -> CommandResult {
        guard intentAllows(kind: .association, target: ssid) else {
            return CommandResult(
                exitCode: 1,
                standardError: "Association command had no readable prepared journal intent."
            )
        }
        if blockingStage == .mutationDispatch, !stageWasReached {
            await blockNonThrowing(stage: "mutation-dispatch")
        }
        let succeeded = !failedAssociationTargets.contains(ssid)
        state.mutations.append(
            ProviderMutationArtifact(kind: "associate", target: ssid, succeeded: succeeded)
        )
        if succeeded {
            state.ssid = ssid
        }
        do {
            try persist()
        } catch {
            return CommandResult(exitCode: 1, standardError: error.localizedDescription)
        }
        return succeeded
            ? CommandResult(exitCode: 0)
            : CommandResult(exitCode: 1, standardError: "network is unavailable")
    }

    func associate(
        device: String,
        ssid: String,
        password: String?,
        timeout: Duration
    ) async -> CommandResult {
        guard hangingAssociationTargets.contains(ssid) else {
            return await associate(device: device, ssid: ssid, password: password)
        }
        try? await Task.sleep(for: timeout)
        state.mutations.append(
            ProviderMutationArtifact(kind: "associate", target: ssid, succeeded: false)
        )
        try? persist()
        return CommandResult(exitCode: 124, standardError: "association timed out")
    }

    private func blockThrowing(stage: String) async throws {
        stageWasReached = true
        if let stageMarkerURL {
            try writeExact(stage, to: stageMarkerURL)
        }
        try await Task.sleep(nanoseconds: 30_000_000_000)
    }

    private func blockNonThrowing(stage: String) async {
        stageWasReached = true
        if let stageMarkerURL {
            try? writeExact(stage, to: stageMarkerURL)
        }
        if let stageGateURL {
            while !FileManager.default.fileExists(atPath: stageGateURL.path),
                  !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 10_000_000)
            }
            return
        }
        try? await Task.sleep(nanoseconds: 30_000_000_000)
    }

    private func persist() throws {
        try writeJSON(state, to: fileURL)
    }

    private func intentAllows(kind: TravelSessionMutationKind, target: String) -> Bool {
        guard let data = try? Data(contentsOf: journalURL),
              let journal = try? JSONDecoder().decode(TravelSessionJournal.self, from: data),
              let intent = journal.pendingMutation else {
            return false
        }
        return intent.kind == kind && intent.target == target && intent.phase == .prepared
    }
}

private actor FileBackedRawTravelCommandGateway: TravelCommandGateway {
    private let fileURL: URL
    private let journalURL: URL
    private var state: ProviderArtifact

    init(
        fileURL: URL,
        journalURL: URL,
        initialPower: Bool,
        initialSSID: String?
    ) throws {
        self.fileURL = fileURL
        self.journalURL = journalURL
        self.state = ProviderArtifact(
            wifiPower: initialPower,
            ssid: initialSSID,
            unrelatedPowerValue: 17,
            mutations: []
        )
        try writeJSON(state, to: fileURL)
    }

    func snapshot() -> ProviderArtifact {
        state
    }

    func startKeepAwake() async throws {
        state.mutations.append(
            ProviderMutationArtifact(kind: "start_keep_awake", target: nil, succeeded: true)
        )
        try persist()
    }

    func stopKeepAwake() async {
        state.mutations.append(
            ProviderMutationArtifact(kind: "stop_keep_awake", target: nil, succeeded: true)
        )
        try? persist()
    }

    func currentLidClosed() async -> Bool? {
        true
    }

    func discoverWiFiDevice() async -> String? {
        "en0"
    }

    func knownWiFiNetworks(device: String) async -> [String] {
        ["Office", "iPhone"]
    }

    func scanWiFiNetworks(device: String) async -> [String] {
        ["Office", "iPhone"]
    }

    func currentWiFiStatus(device: String) async -> WiFiStatus {
        let detail = state.ssid.map { "Current Wi-Fi Network: \($0)" }
            ?? "You are not associated with an AirPort network."
        return WiFiStatus(device: device, networkName: state.ssid, rawOutput: detail)
    }

    func currentWiFiPower(device: String) async -> Bool? {
        state.wifiPower
    }

    func setWiFiPower(device: String, enabled: Bool) async -> CommandResult {
        guard intentAllows(kind: .wifiPower, target: String(enabled)) else {
            return CommandResult(
                exitCode: 1,
                standardError: "Raw power write had no matching persisted transaction intent."
            )
        }
        state.wifiPower = enabled
        state.mutations.append(
            ProviderMutationArtifact(
                kind: "set_wifi_power",
                target: String(enabled),
                succeeded: true
            )
        )
        do {
            try persist()
            return CommandResult(exitCode: 0)
        } catch {
            return CommandResult(exitCode: 1, standardError: error.localizedDescription)
        }
    }

    func joinWiFi(
        device: String,
        ssid: String,
        password: String?
    ) async -> CommandResult {
        guard intentAllows(kind: .association, target: ssid) else {
            return CommandResult(
                exitCode: 1,
                standardError: "Raw association had no matching persisted transaction intent."
            )
        }
        state.ssid = ssid
        state.mutations.append(
            ProviderMutationArtifact(kind: "associate", target: ssid, succeeded: true)
        )
        do {
            try persist()
            return CommandResult(exitCode: 0)
        } catch {
            return CommandResult(exitCode: 1, standardError: error.localizedDescription)
        }
    }

    func openWiFiSettings() async {
        state.mutations.append(
            ProviderMutationArtifact(kind: "open_wifi_settings", target: nil, succeeded: true)
        )
        try? persist()
    }

    func isCodexRunning() async -> Bool {
        true
    }

    private func persist() throws {
        try writeJSON(state, to: fileURL)
    }

    private func intentAllows(kind: TravelSessionMutationKind, target: String) -> Bool {
        guard let data = try? Data(contentsOf: journalURL),
              let journal = try? JSONDecoder().decode(TravelSessionJournal.self, from: data),
              let intent = journal.pendingMutation else {
            return false
        }
        return intent.kind == kind && intent.target == target && intent.phase == .prepared
    }
}

private struct RuntimeSettingsStore: TravelSettingsStoring {
    let settings: TravelModeSettings

    func load() -> TravelModeSettings { settings }
    func hasSavedHotspotPassword() -> Bool { true }
    func loadHotspotPassword() throws -> String { "secret" }
    func loadHotspotPassword(credentialReference: String) throws -> String { "secret" }
    func save(_ settings: TravelModeSettings) throws {}

    func activeHotspotConfiguration() throws -> HotspotConfigurationRevision? {
        try HotspotConfigurationRevision(
            revisionID: "runtime-wiring-revision",
            ssid: settings.hotspotSSID,
            wifiDevice: settings.wifiDevice,
            credentialReference: "runtime-wiring-credential"
        )
    }
}

private struct RuntimeAppArtifact: Codable, Sendable {
    var isRunning: Bool
    var latestStatus: String
    var lastErrorMessage: String?

    enum CodingKeys: String, CodingKey {
        case isRunning = "is_running"
        case latestStatus = "latest_status"
        case lastErrorMessage = "last_error_message"
    }
}

private enum ReceiptMismatch: Sendable {
    case sessionID
    case requestID
    case leaseID
    case generation
}

private actor FileBackedLeaseClient: SleepOverrideLeaseClient {
    private let fileURL: URL
    private let journalURL: URL
    private var state: LeaseArtifact
    private var releaseMismatch: ReceiptMismatch?
    private var blockAcquire = false
    private var stageMarkerURL: URL?
    private var acquireStageWasReached = false
    private var releaseMarkerURL: URL?
    private var releaseGateURL: URL?

    init(fileURL: URL, journalURL: URL) throws {
        self.fileURL = fileURL
        self.journalURL = journalURL
        if FileManager.default.fileExists(atPath: fileURL.path) {
            self.state = try decodeJSON(LeaseArtifact.self, at: fileURL)
        } else {
            self.state = LeaseArtifact(
                phase: SleepOverrideLeasePhase.released.rawValue,
                activeBinding: nil,
                releasedReceipt: nil,
                mutations: []
            )
            try writeJSON(self.state, to: fileURL)
        }
    }

    func configureReleaseMismatch(_ mismatch: ReceiptMismatch?) {
        releaseMismatch = mismatch
    }

    func configureBlockedAcquire(_ enabled: Bool, markerURL: URL?) {
        blockAcquire = enabled
        stageMarkerURL = markerURL
        acquireStageWasReached = false
    }

    func configureBlockedRelease(markerURL: URL, gateURL: URL) {
        releaseMarkerURL = markerURL
        releaseGateURL = gateURL
    }

    func snapshot() -> LeaseArtifact {
        state
    }

    func acquire(
        sessionID: String,
        requestID: String
    ) async throws -> SleepOverrideLeaseReceipt {
        guard persistedRequestMatches(sessionID: sessionID, requestID: requestID) else {
            throw SleepOverrideLeaseError.invalidReceipt
        }
        if blockAcquire, !acquireStageWasReached {
            acquireStageWasReached = true
            if let stageMarkerURL {
                try writeExact("lease-acquisition", to: stageMarkerURL)
            }
            try await Task.sleep(nanoseconds: 30_000_000_000)
        }
        let binding = SleepOverrideLeaseBinding(
            sessionID: sessionID,
            requestID: requestID,
            leaseID: "lease-\(UUID().uuidString)",
            generation: "generation-1"
        )
        state.phase = SleepOverrideLeasePhase.active.rawValue
        state.activeBinding = binding
        state.releasedReceipt = nil
        state.mutations.append(LeaseMutationArtifact(kind: "acquire", binding: binding))
        try persist()
        return SleepOverrideLeaseReceipt(phase: .active, binding: binding)
    }

    func resolve(
        sessionID: String,
        requestID: String
    ) async throws -> SleepOverrideLeaseResolution {
        guard let binding = state.activeBinding,
              binding.sessionID == sessionID,
              binding.requestID == requestID,
              let phase = SleepOverrideLeasePhase(rawValue: state.phase) else {
            return .authoritativeNotFound
        }
        let receiptBinding = phase == .released
            ? (state.releasedReceipt ?? binding)
            : binding
        state.mutations.append(LeaseMutationArtifact(kind: "resolve", binding: binding))
        try persist()
        return .found(SleepOverrideLeaseReceipt(phase: phase, binding: receiptBinding))
    }

    func status(
        binding: SleepOverrideLeaseBinding
    ) async throws -> SleepOverrideLeaseReceipt {
        guard let phase = SleepOverrideLeasePhase(rawValue: state.phase) else {
            throw SleepOverrideLeaseError.invalidReceipt
        }
        let receiptBinding = phase == .released
            ? (state.releasedReceipt ?? binding)
            : (state.activeBinding ?? binding)
        state.mutations.append(LeaseMutationArtifact(kind: "status", binding: binding))
        try persist()
        return SleepOverrideLeaseReceipt(phase: phase, binding: receiptBinding)
    }

    func release(
        binding: SleepOverrideLeaseBinding
    ) async throws -> SleepOverrideLeaseReceipt {
        if let markerURL = releaseMarkerURL, let gateURL = releaseGateURL {
            releaseMarkerURL = nil
            releaseGateURL = nil
            try writeExact("release-in-flight", to: markerURL)
            while !FileManager.default.fileExists(atPath: gateURL.path) {
                try await Task.sleep(nanoseconds: 10_000_000)
            }
        }
        var receiptBinding = binding
        switch releaseMismatch {
        case .sessionID:
            receiptBinding.sessionID += "-mismatch"
        case .requestID:
            receiptBinding.requestID += "-mismatch"
        case .leaseID:
            receiptBinding.leaseID += "-mismatch"
        case .generation:
            receiptBinding.generation += "-mismatch"
        case nil:
            break
        }
        state.phase = SleepOverrideLeasePhase.released.rawValue
        state.releasedReceipt = receiptBinding
        state.mutations.append(LeaseMutationArtifact(kind: "release", binding: binding))
        try persist()
        return SleepOverrideLeaseReceipt(phase: .released, binding: receiptBinding)
    }

    func acknowledgeRelease(binding: SleepOverrideLeaseBinding) async throws {
        state.mutations.append(
            LeaseMutationArtifact(kind: "acknowledge_release", binding: binding)
        )
        try persist()
    }

    private func persist() throws {
        try writeJSON(state, to: fileURL)
    }

    private func persistedRequestMatches(sessionID: String, requestID: String) -> Bool {
        guard let data = try? Data(contentsOf: journalURL),
              let journal = try? JSONDecoder().decode(TravelSessionJournal.self, from: data) else {
            return false
        }
        return journal.sessionID == sessionID && journal.leaseRequestID == requestID
    }
}

private actor FileBackedBoundaryObserver: TravelSessionBoundaryObserving {
    private let fileURL: URL
    private let checkpoint: String?
    private let checkpointURL: URL?
    private var events: [TraceEventArtifact]
    private var checkpointWasReached = false

    init(fileURL: URL, checkpoint: String? = nil, checkpointURL: URL? = nil) throws {
        self.fileURL = fileURL
        self.checkpoint = checkpoint
        self.checkpointURL = checkpointURL
        if FileManager.default.fileExists(atPath: fileURL.path) {
            self.events = try decodeJSON([TraceEventArtifact].self, at: fileURL)
        } else {
            self.events = []
            try writeJSON(self.events, to: fileURL)
        }
    }

    func reached(
        _ boundary: TravelSessionBoundary,
        sessionID: String?,
        value: String?
    ) async {
        append(kind: boundary.rawValue, sessionID: sessionID, value: value)
        guard boundary.rawValue == checkpoint, !checkpointWasReached else { return }
        checkpointWasReached = true
        if let checkpointURL, let checkpoint {
            try? writeExact(checkpoint, to: checkpointURL)
        }
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
    }

    func record(kind: String, sessionID: String?, value: String?) {
        append(kind: kind, sessionID: sessionID, value: value)
    }

    func snapshot() -> [TraceEventArtifact] {
        events
    }

    private func append(kind: String, sessionID: String?, value: String?) {
        events.append(
            TraceEventArtifact(
                sequence: events.count + 1,
                kind: kind,
                sessionID: sessionID,
                value: value
            )
        )
        try? writeJSON(events, to: fileURL)
    }
}

private actor ReadbackFailingJournalStore: TravelSessionJournalStoring {
    private let base: FileTravelSessionJournalStore

    init(base: FileTravelSessionJournalStore) {
        self.base = base
    }

    func load() async throws -> TravelSessionJournal? {
        try await base.load()
    }

    func create(_ journal: TravelSessionJournal) async throws -> TravelSessionJournal {
        throw TravelSessionJournalError.readbackMismatch
    }

    func update(
        _ journal: TravelSessionJournal,
        expectedRevision: Int
    ) async throws -> TravelSessionJournal {
        return try await base.update(journal, expectedRevision: expectedRevision)
    }

    func clear(sessionID: String, expectedRevision: Int) async throws {
        try await base.clear(sessionID: sessionID, expectedRevision: expectedRevision)
    }
}

private actor PersistedReadbackFailureJournalStore: TravelSessionJournalStoring {
    private let base: FileTravelSessionJournalStore
    private let journalURL: URL
    private let createdJournalURL: URL

    init(
        base: FileTravelSessionJournalStore,
        journalURL: URL,
        createdJournalURL: URL
    ) {
        self.base = base
        self.journalURL = journalURL
        self.createdJournalURL = createdJournalURL
    }

    func load() async throws -> TravelSessionJournal? {
        try await base.load()
    }

    func create(_ journal: TravelSessionJournal) async throws -> TravelSessionJournal {
        _ = try await base.create(journal)
        try Data(contentsOf: journalURL).write(to: createdJournalURL, options: .atomic)
        throw TravelSessionJournalError.readbackMismatch
    }

    func update(
        _ journal: TravelSessionJournal,
        expectedRevision: Int
    ) async throws -> TravelSessionJournal {
        try await base.update(journal, expectedRevision: expectedRevision)
    }

    func clear(sessionID: String, expectedRevision: Int) async throws {
        try await base.clear(sessionID: sessionID, expectedRevision: expectedRevision)
    }
}

private actor BlockingCreateJournalStore: TravelSessionJournalStoring {
    private let base: FileTravelSessionJournalStore
    private let journalURL: URL
    private let enteredURL: URL
    private let cancellationURL: URL
    private let gateURL: URL
    private let createdJournalURL: URL
    private let traceURL: URL
    private var events: [String] = []

    init(
        base: FileTravelSessionJournalStore,
        journalURL: URL,
        artifactDirectory: URL,
        runtimeDirectory: URL
    ) throws {
        self.base = base
        self.journalURL = journalURL
        self.enteredURL = runtimeDirectory.appendingPathComponent("create-entered")
        self.cancellationURL = runtimeDirectory.appendingPathComponent("cancellation-observed")
        self.gateURL = runtimeDirectory.appendingPathComponent("allow-create")
        self.createdJournalURL = artifactDirectory.appendingPathComponent("created-journal.json")
        self.traceURL = artifactDirectory.appendingPathComponent("create-race.json")
        try writeJSON(events, to: traceURL)
    }

    func load() async throws -> TravelSessionJournal? {
        try await base.load()
    }

    func create(_ journal: TravelSessionJournal) async throws -> TravelSessionJournal {
        append("create_entered_without_journal")
        try writeExact("create-entered", to: enteredURL)
        var recordedCancellation = false
        while !FileManager.default.fileExists(atPath: gateURL.path) {
            if Task.isCancelled, !recordedCancellation {
                recordedCancellation = true
                append("cancellation_observed_before_create")
                try writeExact("cancellation-observed", to: cancellationURL)
            }
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        append("create_gate_observed")
        let persisted = try await base.create(journal)
        try Data(contentsOf: journalURL).write(to: createdJournalURL, options: .atomic)
        append("journal_persisted_after_cancellation")
        return persisted
    }

    func update(
        _ journal: TravelSessionJournal,
        expectedRevision: Int
    ) async throws -> TravelSessionJournal {
        try await base.update(journal, expectedRevision: expectedRevision)
    }

    func clear(sessionID: String, expectedRevision: Int) async throws {
        append("clear_rejected")
        throw TravelSessionJournalError.readbackMismatch
    }

    func enteredMarkerURL() -> URL { enteredURL }
    func cancellationMarkerURL() -> URL { cancellationURL }
    func createGateURL() -> URL { gateURL }

    private func append(_ event: String) {
        events.append(event)
        try? writeJSON(events, to: traceURL)
    }
}

private struct CaseEnvironment: Sendable {
    var coordinator: TravelSessionCoordinator
    var baseStore: FileTravelSessionJournalStore
    var system: FileBackedSystemController
    var lease: FileBackedLeaseClient
    var observer: FileBackedBoundaryObserver
}

private struct ProofHostRunner {
    let workspace: URL

    private var journalURL: URL {
        workspace.appendingPathComponent("session-journal.json", isDirectory: false)
    }

    func run(scenario: String, checkpoint: String?) async throws {
        try FileManager.default.createDirectory(
            at: workspace,
            withIntermediateDirectories: true
        )
        switch scenario {
        case "unowned-and-capture-failure":
            try await runUnownedAndCaptureFailure()
        case "exact-roundtrip":
            try await runExactRoundTrip()
        case "runtime-wiring-roundtrip":
            try await runRuntimeWiringRoundTrip()
        case "persisted-readback-failure":
            try await runPersistedReadbackFailure()
        case "quit-create-race":
            try await runQuitCreateRace()
        case "failure-and-retry":
            try await runFailureAndRetry()
        case "binding-and-serialization":
            try await runBindingAndSerialization()
        case "quit-during-preparing":
            try await runQuitDuringPreparing()
        case "quit-active-association":
            try await runQuitActiveAssociation()
        case "quit-compensation-failure":
            try await runFailedQuitCompensation()
        case "crash-start":
            guard let checkpoint else { throw HostError.invalidArguments }
            try await runCrashStart(checkpoint: checkpoint)
        case "crash-association":
            guard let checkpoint else { throw HostError.invalidArguments }
            try await runCrashAssociation(checkpoint: checkpoint)
        case "crash-restore":
            guard let checkpoint else { throw HostError.invalidArguments }
            try await runCrashRestore(checkpoint: checkpoint)
        case "crash-lease-receipt":
            try await runCrashLeaseReceipt()
        case "recover-existing":
            try await runRecovery()
        case "timeout-worker":
            try await runTimeoutWorker()
        default:
            throw HostError.unsupportedScenario(scenario)
        }
    }

    private func makeEnvironment(
        runtimeName: String,
        initialPower: Bool,
        initialSSID: String? = "Office",
        failCreate: Bool = false,
        associationRestoreTimeout: Duration = .seconds(10)
    ) async throws -> CaseEnvironment {
        let runtime = workspace.appendingPathComponent("runtime/\(runtimeName)", isDirectory: true)
        try FileManager.default.createDirectory(at: runtime, withIntermediateDirectories: true)
        let base = FileTravelSessionJournalStore(fileURL: journalURL)
        let system = try FileBackedSystemController(
            fileURL: runtime.appendingPathComponent("provider-state.json"),
            journalURL: journalURL,
            initialPower: initialPower,
            initialSSID: initialSSID
        )
        let lease = try FileBackedLeaseClient(
            fileURL: runtime.appendingPathComponent("lease-state.json"),
            journalURL: journalURL
        )
        let observer = try FileBackedBoundaryObserver(
            fileURL: runtime.appendingPathComponent("trace-state.json")
        )
        let store: any TravelSessionJournalStoring
        if failCreate {
            store = ReadbackFailingJournalStore(base: base)
        } else {
            store = base
        }
        let coordinator = TravelSessionCoordinator(
            journalStore: store,
            system: system,
            leaseClient: lease,
            observer: observer,
            associationRestoreTimeout: associationRestoreTimeout
        )
        return CaseEnvironment(
            coordinator: coordinator,
            baseStore: base,
            system: system,
            lease: lease,
            observer: observer
        )
    }

    private func record(
        _ name: String,
        result: TravelSessionTransitionResult,
        environment: CaseEnvironment,
        activeJournal: Data? = nil
    ) async throws {
        let directory = workspace.appendingPathComponent("cases/\(name)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try writeJSON(
            await environment.system.snapshot(),
            to: directory.appendingPathComponent("provider.json")
        )
        try writeJSON(
            await environment.lease.snapshot(),
            to: directory.appendingPathComponent("lease.json")
        )
        try writeJSON(
            await environment.observer.snapshot(),
            to: directory.appendingPathComponent("trace.json")
        )
        if FileManager.default.fileExists(atPath: journalURL.path) {
            try Data(contentsOf: journalURL).write(
                to: directory.appendingPathComponent("session-journal.json"),
                options: .atomic
            )
        }
        if let activeJournal {
            try activeJournal.write(
                to: directory.appendingPathComponent("active-journal.json"),
                options: .atomic
            )
        }
        // The liveness proof waits for result.json before reading the complete case.
        // Publish it last so its atomic appearance is also the completion signal.
        try writeJSON(result, to: directory.appendingPathComponent("result.json"))
    }

    private func requireActive(
        _ result: TravelSessionTransitionResult,
        context: String
    ) throws {
        guard result.lifecycle == .active,
              FileManager.default.fileExists(atPath: journalURL.path) else {
            throw HostError.unexpectedResult("\(context) did not become active: \(result)")
        }
    }

    private func requireOff(
        _ result: TravelSessionTransitionResult,
        context: String
    ) throws {
        guard result.lifecycle == .off,
              !FileManager.default.fileExists(atPath: journalURL.path) else {
            throw HostError.unexpectedResult("\(context) did not become off: \(result)")
        }
    }
}

private extension ProofHostRunner {
    func runUnownedAndCaptureFailure() async throws {
        for (name, operation) in [
            ("stop-off", "stop"),
            ("quit-off", "quit"),
            ("recover-off", "recover")
        ] {
            let environment = try await makeEnvironment(
                runtimeName: name,
                initialPower: true
            )
            let result: TravelSessionTransitionResult
            switch operation {
            case "stop": result = await environment.coordinator.stop()
            case "quit": result = await environment.coordinator.requestQuit()
            default: result = await environment.coordinator.recover()
            }
            try requireOff(result, context: name)
            try await record(name, result: result, environment: environment)
        }

        let capture = try await makeEnvironment(
            runtimeName: "capture-failure",
            initialPower: true
        )
        await capture.system.configureCaptureFailure(true)
        let captureResult = await capture.coordinator.start(
            configuration: TravelSessionConfiguration(wifiDevice: "en0")
        )
        try requireOff(captureResult, context: "capture-failure")
        try await record("capture-failure", result: captureResult, environment: capture)

        let readback = try await makeEnvironment(
            runtimeName: "journal-readback-failure",
            initialPower: false,
            failCreate: true
        )
        let readbackResult = await readback.coordinator.start(
            configuration: TravelSessionConfiguration(wifiDevice: "en0")
        )
        try requireOff(readbackResult, context: "journal-readback-failure")
        try await record(
            "journal-readback-failure",
            result: readbackResult,
            environment: readback
        )
    }

    func runExactRoundTrip() async throws {
        let disabled = try await makeEnvironment(
            runtimeName: "wifi-false-roundtrip",
            initialPower: false
        )
        let disabledStart = await disabled.coordinator.start(
            configuration: TravelSessionConfiguration(wifiDevice: "en0")
        )
        try requireActive(disabledStart, context: "wifi-false-roundtrip")
        let activeJournal = try Data(contentsOf: journalURL)
        let disabledStop = await disabled.coordinator.stop()
        try requireOff(disabledStop, context: "wifi-false-roundtrip stop")
        try await record(
            "wifi-false-roundtrip",
            result: disabledStop,
            environment: disabled,
            activeJournal: activeJournal
        )

        let enabled = try await makeEnvironment(
            runtimeName: "wifi-true-no-power-write",
            initialPower: true
        )
        try requireActive(
            await enabled.coordinator.start(
                configuration: TravelSessionConfiguration(wifiDevice: "en0")
            ),
            context: "wifi-true-no-power-write"
        )
        let enabledStop = await enabled.coordinator.stop()
        try requireOff(enabledStop, context: "wifi-true-no-power-write stop")
        try await record(
            "wifi-true-no-power-write",
            result: enabledStop,
            environment: enabled
        )

        try await runAssociationRoundTrip(available: true)
        try await runAssociationRoundTrip(available: false)
        try await runUnassociatedBaselineRoundTrip()

        let unrelated = try await makeEnvironment(
            runtimeName: "unrelated-setting",
            initialPower: false
        )
        try requireActive(
            await unrelated.coordinator.start(
                configuration: TravelSessionConfiguration(wifiDevice: "en0")
            ),
            context: "unrelated-setting"
        )
        let unrelatedStop = await unrelated.coordinator.stop()
        try requireOff(unrelatedStop, context: "unrelated-setting stop")
        try await record("unrelated-setting", result: unrelatedStop, environment: unrelated)
    }

    func runAssociationRoundTrip(available: Bool) async throws {
        let name = available ? "prior-network-available" : "prior-network-unavailable"
        let environment = try await makeEnvironment(
            runtimeName: name,
            initialPower: available,
            associationRestoreTimeout: .milliseconds(100)
        )
        try requireActive(
            await environment.coordinator.start(
                configuration: TravelSessionConfiguration(wifiDevice: "en0")
            ),
            context: name
        )
        let joined = await environment.coordinator.associate(
            device: "en0",
            ssid: "iPhone",
            password: nil
        )
        guard joined.succeeded else {
            throw HostError.unexpectedResult("\(name) could not join the target network")
        }
        if !available {
            await environment.system.configureAssociationHang(target: "Office", enabled: true)
        }
        let result = await environment.coordinator.stop()
        try requireOff(result, context: "\(name) stop")
        try await record(name, result: result, environment: environment)
    }

    func runUnassociatedBaselineRoundTrip() async throws {
        let name = "prior-network-unassociated"
        let environment = try await makeEnvironment(
            runtimeName: name,
            initialPower: true,
            initialSSID: nil
        )
        try requireActive(
            await environment.coordinator.start(
                configuration: TravelSessionConfiguration(wifiDevice: "en0")
            ),
            context: name
        )
        let activeJournal = try Data(contentsOf: journalURL)
        let joined = await environment.coordinator.associate(
            device: "en0",
            ssid: "iPhone",
            password: nil
        )
        guard joined.succeeded else {
            throw HostError.unexpectedResult("\(name) could not join the target network")
        }
        let result = await environment.coordinator.stop()
        try requireOff(result, context: "\(name) stop")
        try await record(
            name,
            result: result,
            environment: environment,
            activeJournal: activeJournal
        )
    }

    func runPersistedReadbackFailure() async throws {
        let name = "persisted-readback-failure"
        let runtime = workspace.appendingPathComponent("runtime/\(name)", isDirectory: true)
        let artifactDirectory = workspace.appendingPathComponent("cases/\(name)", isDirectory: true)
        try FileManager.default.createDirectory(at: runtime, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: artifactDirectory,
            withIntermediateDirectories: true
        )
        let base = FileTravelSessionJournalStore(fileURL: journalURL)
        let system = try FileBackedSystemController(
            fileURL: runtime.appendingPathComponent("provider-state.json"),
            journalURL: journalURL,
            initialPower: true,
            initialSSID: "Office"
        )
        let lease = try FileBackedLeaseClient(
            fileURL: runtime.appendingPathComponent("lease-state.json"),
            journalURL: journalURL
        )
        let observer = try FileBackedBoundaryObserver(
            fileURL: runtime.appendingPathComponent("trace-state.json")
        )
        let store = PersistedReadbackFailureJournalStore(
            base: base,
            journalURL: journalURL,
            createdJournalURL: artifactDirectory.appendingPathComponent("created-journal.json")
        )
        let coordinator = TravelSessionCoordinator(
            journalStore: store,
            system: system,
            leaseClient: lease,
            observer: observer
        )
        let result = await coordinator.start(
            configuration: TravelSessionConfiguration(wifiDevice: "en0")
        )
        try await record(
            name,
            result: result,
            environment: CaseEnvironment(
                coordinator: coordinator,
                baseStore: base,
                system: system,
                lease: lease,
                observer: observer
            )
        )
    }

    func runQuitCreateRace() async throws {
        let name = "quit-create-race"
        let runtime = workspace.appendingPathComponent("runtime/\(name)", isDirectory: true)
        let artifactDirectory = workspace.appendingPathComponent("cases/\(name)", isDirectory: true)
        try FileManager.default.createDirectory(at: runtime, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: artifactDirectory,
            withIntermediateDirectories: true
        )
        let base = FileTravelSessionJournalStore(fileURL: journalURL)
        let system = try FileBackedSystemController(
            fileURL: runtime.appendingPathComponent("provider-state.json"),
            journalURL: journalURL,
            initialPower: true,
            initialSSID: "Office"
        )
        let lease = try FileBackedLeaseClient(
            fileURL: runtime.appendingPathComponent("lease-state.json"),
            journalURL: journalURL
        )
        let observer = try FileBackedBoundaryObserver(
            fileURL: runtime.appendingPathComponent("trace-state.json")
        )
        let store = try BlockingCreateJournalStore(
            base: base,
            journalURL: journalURL,
            artifactDirectory: artifactDirectory,
            runtimeDirectory: runtime
        )
        let coordinator = TravelSessionCoordinator(
            journalStore: store,
            system: system,
            leaseClient: lease,
            observer: observer
        )
        let start = Task {
            await coordinator.start(
                configuration: TravelSessionConfiguration(wifiDevice: "en0")
            )
        }
        try await waitForPath(
            runtime.appendingPathComponent("create-entered"),
            stage: "create entered before persistence"
        )
        let quit = Task { await coordinator.requestQuit() }
        try await waitForPath(
            runtime.appendingPathComponent("cancellation-observed"),
            stage: "Quit cancellation before persistence"
        )
        let competingStart = await coordinator.start(
            configuration: TravelSessionConfiguration(wifiDevice: "en0")
        )
        try writeJSON(
            competingStart,
            to: artifactDirectory.appendingPathComponent("concurrent-start-result.json")
        )
        try writeExact("allow-create", to: runtime.appendingPathComponent("allow-create"))
        _ = await start.value
        let result = await quit.value
        try await record(
            name,
            result: result,
            environment: CaseEnvironment(
                coordinator: coordinator,
                baseStore: base,
                system: system,
                lease: lease,
                observer: observer
            )
        )
    }
}

private extension ProofHostRunner {
    @MainActor
    func runRuntimeWiringRoundTrip() async throws {
        let runtime = workspace.appendingPathComponent(
            "runtime/runtime-wiring-roundtrip",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: runtime, withIntermediateDirectories: true)
        let rawGateway = try FileBackedRawTravelCommandGateway(
            fileURL: runtime.appendingPathComponent("raw-gateway-state.json"),
            journalURL: journalURL,
            initialPower: false,
            initialSSID: "Office"
        )
        let lease = try FileBackedLeaseClient(
            fileURL: runtime.appendingPathComponent("lease-state.json"),
            journalURL: journalURL
        )
        let observer = try FileBackedBoundaryObserver(
            fileURL: runtime.appendingPathComponent("trace-state.json")
        )
        let coordinator = TravelSessionCoordinator(
            journalStore: FileTravelSessionJournalStore(fileURL: journalURL),
            system: GatewayTravelSessionSystemController(gateway: rawGateway),
            leaseClient: lease,
            observer: observer
        )
        let transactionalGateway = TransactionalTravelCommandGateway(
            rawGateway: rawGateway,
            sessionManager: coordinator
        )
        let app = TravelModeAppState(
            gateway: transactionalGateway,
            engine: TravelModeEngine(verificationAttempts: 1),
            settingsStore: RuntimeSettingsStore(
                settings: TravelModeSettings(
                    hotspotSSID: "iPhone",
                    hotspotPassword: "secret",
                    wifiDevice: "en0"
                )
            ),
            sessionManager: coordinator
        )

        await app.start()
        guard app.isRunning, await coordinator.lifecycle() == .active else {
            throw HostError.unexpectedResult("production app wiring did not become active")
        }
        let activeJournal = try Data(contentsOf: journalURL)
        await app.syncOnce()
        guard await rawGateway.snapshot().ssid == "iPhone" else {
            throw HostError.unexpectedResult("production app wiring did not join iPhone")
        }
        await app.stop()

        let lifecycle = await coordinator.lifecycle()
        let provider = await rawGateway.snapshot()
        let leaseState = await lease.snapshot()
        let trace = await observer.snapshot()
        let appArtifact = RuntimeAppArtifact(
            isRunning: app.isRunning,
            latestStatus: app.latestStatus,
            lastErrorMessage: app.lastErrorMessage
        )
        try writeRuntimeWiringArtifacts(
            result: TravelSessionTransitionResult(
                lifecycle: lifecycle,
                error: app.lastErrorMessage
            ),
            provider: provider,
            lease: leaseState,
            trace: trace,
            app: appArtifact,
            activeJournal: activeJournal
        )
        let effects = provider.mutations.map { mutation in
            "\(mutation.kind):\(mutation.target ?? "-")"
        }
        guard lifecycle == .off,
              !app.isRunning,
              app.lastErrorMessage == nil,
              provider.wifiPower == false,
              provider.ssid == "Office",
              leaseState.phase == SleepOverrideLeasePhase.released.rawValue,
              !FileManager.default.fileExists(atPath: journalURL.path),
              effects == [
                  "set_wifi_power:true",
                  "start_keep_awake:-",
                  "associate:iPhone",
                  "stop_keep_awake:-",
                  "associate:Office",
                  "set_wifi_power:false"
              ] else {
            throw HostError.unexpectedResult(
                "production wiring did not restore exactly: lifecycle=\(lifecycle.rawValue), "
                    + "running=\(app.isRunning), power=\(provider.wifiPower), "
                    + "ssid=\(provider.ssid ?? "none"), effects=\(effects)"
            )
        }
    }

    func writeRuntimeWiringArtifacts(
        result: TravelSessionTransitionResult,
        provider: ProviderArtifact,
        lease: LeaseArtifact,
        trace: [TraceEventArtifact],
        app: RuntimeAppArtifact,
        activeJournal: Data
    ) throws {
        let directory = workspace.appendingPathComponent(
            "cases/runtime-wiring-roundtrip",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try writeJSON(result, to: directory.appendingPathComponent("result.json"))
        try writeJSON(provider, to: directory.appendingPathComponent("provider.json"))
        try writeJSON(lease, to: directory.appendingPathComponent("lease.json"))
        try writeJSON(trace, to: directory.appendingPathComponent("trace.json"))
        try writeJSON(app, to: directory.appendingPathComponent("app.json"))
        try activeJournal.write(
            to: directory.appendingPathComponent("active-journal.json"),
            options: .atomic
        )
        if FileManager.default.fileExists(atPath: journalURL.path) {
            try Data(contentsOf: journalURL).write(
                to: directory.appendingPathComponent("session-journal.json"),
                options: .atomic
            )
        }
    }
}

private extension ProofHostRunner {
    func runFailureAndRetry() async throws {
        try await runStartFailure(
            name: "wrong-readback-before-retry",
            behavior: .reportSuccessWithoutChange
        )
        try await runStartFailure(
            name: "failed-write-before-retry",
            behavior: .fail
        )

        let restore = try await makeEnvironment(
            runtimeName: "restore-failure",
            initialPower: false
        )
        try requireActive(
            await restore.coordinator.start(
                configuration: TravelSessionConfiguration(wifiDevice: "en0")
            ),
            context: "restore-failure"
        )
        await restore.system.configurePowerWrite(.fail)
        let failed = await restore.coordinator.stop()
        guard failed.lifecycle == .cleanupRequired else {
            throw HostError.unexpectedResult("restore failure did not retain cleanup")
        }
        try await record(
            "restore-failure-before-retry",
            result: failed,
            environment: restore
        )
        await restore.system.configurePowerWrite(.normal)
        let recovered = await restore.coordinator.recover()
        try requireOff(recovered, context: "restore retry")
        try await record("after-retry", result: recovered, environment: restore)
    }

    func runStartFailure(name: String, behavior: PowerWriteBehavior) async throws {
        let environment = try await makeEnvironment(runtimeName: name, initialPower: false)
        await environment.system.configurePowerWrite(behavior)
        let failed = await environment.coordinator.start(
            configuration: TravelSessionConfiguration(wifiDevice: "en0")
        )
        guard failed.lifecycle == .cleanupRequired else {
            throw HostError.unexpectedResult("\(name) did not retain cleanup")
        }
        try await record(name, result: failed, environment: environment)
        await environment.system.configurePowerWrite(.normal)
        let recovered = await environment.coordinator.recover()
        try requireOff(recovered, context: "\(name) retry")
    }
}

private extension ProofHostRunner {
    func runBindingAndSerialization() async throws {
        let mismatches: [(String, ReceiptMismatch)] = [
            ("mismatched-session-receipt", .sessionID),
            ("mismatched-request-receipt", .requestID),
            ("mismatched-lease-receipt", .leaseID),
            ("mismatched-generation-receipt", .generation)
        ]
        for (name, mismatch) in mismatches {
            try await runReceiptMismatch(name: name, mismatch: mismatch)
        }
        try await runStaleSession()
        try await runRecoveryVersusStart()
    }

    func runReceiptMismatch(name: String, mismatch: ReceiptMismatch) async throws {
        let environment = try await makeEnvironment(runtimeName: name, initialPower: true)
        try requireActive(
            await environment.coordinator.start(
                configuration: TravelSessionConfiguration(wifiDevice: "en0")
            ),
            context: name
        )
        await environment.lease.configureReleaseMismatch(mismatch)
        let failed = await environment.coordinator.stop()
        guard failed.lifecycle == .cleanupRequired else {
            throw HostError.unexpectedResult("\(name) accepted a mismatched receipt")
        }
        try await record(name, result: failed, environment: environment)
        await environment.lease.configureReleaseMismatch(nil)
        let recovered = await environment.coordinator.recover()
        try requireOff(recovered, context: "\(name) cleanup")
    }

    func runStaleSession() async throws {
        let environment = try await makeEnvironment(
            runtimeName: "stale-session",
            initialPower: true
        )
        try requireActive(
            await environment.coordinator.start(
                configuration: TravelSessionConfiguration(wifiDevice: "en0")
            ),
            context: "stale-session"
        )
        let runtime = workspace.appendingPathComponent(
            "runtime/stale-session",
            isDirectory: true
        )
        let releaseMarker = runtime.appendingPathComponent("release-in-flight")
        let releaseGate = runtime.appendingPathComponent("allow-release")
        await environment.lease.configureBlockedRelease(
            markerURL: releaseMarker,
            gateURL: releaseGate
        )
        let stop = Task { await environment.coordinator.stop() }
        try await waitForPath(releaseMarker, stage: "stale-session helper release")
        guard let owned = try await environment.baseStore.load() else {
            throw HostError.missingState("owned stale-session journal")
        }
        try await environment.baseStore.clear(
            sessionID: owned.sessionID,
            expectedRevision: owned.revision
        )
        _ = try await environment.baseStore.create(
            TravelSessionJournal(wifiBaseline: owned.wifiBaseline)
        )
        try writeExact("allow-release", to: releaseGate)
        let failed = await stop.value
        guard failed.lifecycle == .cleanupRequired else {
            throw HostError.unexpectedResult("stale session cleanup was accepted")
        }
        try await record("stale-session", result: failed, environment: environment)
        let recovered = await environment.coordinator.recover()
        try requireOff(recovered, context: "stale-session recovery")
    }

    func runRecoveryVersusStart() async throws {
        let environment = try await makeEnvironment(
            runtimeName: "recovery-versus-start",
            initialPower: true
        )
        try requireActive(
            await environment.coordinator.start(
                configuration: TravelSessionConfiguration(wifiDevice: "en0")
            ),
            context: "recovery-versus-start"
        )
        let runtime = workspace.appendingPathComponent(
            "runtime/recovery-versus-start",
            isDirectory: true
        )
        let releaseMarker = runtime.appendingPathComponent("release-in-flight")
        let releaseGate = runtime.appendingPathComponent("allow-release")
        await environment.lease.configureBlockedRelease(
            markerURL: releaseMarker,
            gateURL: releaseGate
        )
        let recovery = Task { await environment.coordinator.recover() }
        try await waitForPath(releaseMarker, stage: "helper release in flight")
        let rejected = await environment.coordinator.start(
            configuration: TravelSessionConfiguration(wifiDevice: "en0")
        )
        guard rejected.lifecycle == .cleanupRequired else {
            throw HostError.unexpectedResult("competing start was not rejected")
        }
        try writeExact("allow-release", to: releaseGate)
        let recovered = await recovery.value
        try requireOff(recovered, context: "recovery-versus-start cleanup")
        try await record(
            "recovery-versus-start",
            result: recovered,
            environment: environment
        )
    }
}

private extension ProofHostRunner {
    func runQuitDuringPreparing() async throws {
        try await runQuitCase(name: "capture", systemStage: .capture)
        try await runQuitCase(name: "lease-acquisition", blockLease: true)
        try await runQuitCase(name: "mutation-dispatch", systemStage: .mutationDispatch)
        try await runQuitCase(name: "verification", systemStage: .verification)
    }

    func runQuitCase(
        name: String,
        systemStage: SystemBlockingStage? = nil,
        blockLease: Bool = false
    ) async throws {
        let environment = try await makeEnvironment(runtimeName: name, initialPower: false)
        let marker = workspace.appendingPathComponent("runtime/\(name)/stage")
        if let systemStage {
            await environment.system.configureBlockingStage(systemStage, markerURL: marker)
        }
        if blockLease {
            await environment.lease.configureBlockedAcquire(true, markerURL: marker)
        }
        let start = Task {
            await environment.coordinator.start(
                configuration: TravelSessionConfiguration(wifiDevice: "en0")
            )
        }
        try await waitForPath(marker, stage: name)
        let quit = await environment.coordinator.requestQuit()
        _ = await start.value
        try requireOff(quit, context: "quit during \(name)")
        try await record(name, result: quit, environment: environment)
    }

    func runFailedQuitCompensation() async throws {
        let environment = try await makeEnvironment(
            runtimeName: "failed-compensation",
            initialPower: false
        )
        try requireActive(
            await environment.coordinator.start(
                configuration: TravelSessionConfiguration(wifiDevice: "en0")
            ),
            context: "failed quit compensation"
        )
        await environment.system.configurePowerWrite(.fail)
        let failed = await environment.coordinator.requestQuit()
        guard failed.lifecycle == .cleanupRequired, !failed.canTerminate else {
            throw HostError.unexpectedResult("failed quit compensation allowed termination")
        }
        try await record(
            "failed-compensation",
            result: failed,
            environment: environment
        )
        while true {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
    }

    func runQuitActiveAssociation() async throws {
        let environment = try await makeEnvironment(
            runtimeName: "active-association",
            initialPower: true,
            initialSSID: "Office"
        )
        try requireActive(
            await environment.coordinator.start(
                configuration: TravelSessionConfiguration(wifiDevice: "en0")
            ),
            context: "active association setup"
        )
        let runtime = workspace.appendingPathComponent(
            "runtime/active-association",
            isDirectory: true
        )
        let dispatchMarker = runtime.appendingPathComponent("association-dispatch-in-flight")
        let dispatchGate = runtime.appendingPathComponent("allow-association-dispatch")
        let releaseMarker = runtime.appendingPathComponent("release-in-flight")
        let releaseGate = runtime.appendingPathComponent("allow-release")
        await environment.system.configureBlockingStage(
            .mutationDispatch,
            markerURL: dispatchMarker,
            gateURL: dispatchGate
        )
        await environment.lease.configureBlockedRelease(
            markerURL: releaseMarker,
            gateURL: releaseGate
        )
        let association = Task {
            await environment.coordinator.associate(
                device: "en0",
                ssid: "iPhone",
                password: nil
            )
        }
        try await waitForPath(dispatchMarker, stage: "active association dispatch")
        let quit = Task { await environment.coordinator.requestQuit() }
        try await waitForTerminationRequested(journalURL, stage: "active association quit")
        try writeExact("allow-association-dispatch", to: dispatchGate)
        let associationResult = await association.value
        try await waitForPath(releaseMarker, stage: "active association helper release")
        try writeExact("allow-release", to: releaseGate)
        let quitResult = await quit.value
        try await record(
            "active-association",
            result: quitResult,
            environment: environment
        )
        let provider = await environment.system.snapshot()
        let lease = await environment.lease.snapshot()
        let associationTargets = provider.mutations.filter {
            $0.kind == "associate" && $0.succeeded
        }.compactMap(\.target)
        guard quitResult.lifecycle == .off,
              provider.ssid == "Office",
              associationTargets == ["iPhone", "Office"],
              lease.phase == SleepOverrideLeasePhase.released.rawValue else {
            throw HostError.unexpectedResult(
                "active association quit did not wait and restore: "
                    + "association=\(associationResult), quit=\(quitResult), "
                    + "ssid=\(provider.ssid ?? "none"), targets=\(associationTargets), "
                    + "lease=\(lease.phase)"
            )
        }
    }
}

private extension ProofHostRunner {
    func runTimeoutWorker() async throws {
        signal(SIGTERM, SIG_IGN)
        try await Task.sleep(nanoseconds: 600_000_000)
        try writeExact("late-effect", to: workspace.appendingPathComponent("late-effect"))
        while true {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
    }

    func runCrashStart(checkpoint: String) async throws {
        try validateCrashCheckpoint(checkpoint)
        let system = try FileBackedSystemController(
            fileURL: workspace.appendingPathComponent("provider-state.json"),
            journalURL: journalURL,
            initialPower: false,
            initialSSID: "Office"
        )
        let lease = try FileBackedLeaseClient(
            fileURL: workspace.appendingPathComponent("lease-state.json"),
            journalURL: journalURL
        )
        let observer = try FileBackedBoundaryObserver(
            fileURL: workspace.appendingPathComponent("trace-state.json"),
            checkpoint: checkpoint,
            checkpointURL: workspace.appendingPathComponent("checkpoint")
        )
        let coordinator = TravelSessionCoordinator(
            journalStore: FileTravelSessionJournalStore(fileURL: journalURL),
            system: system,
            leaseClient: lease,
            observer: observer
        )
        let result = await coordinator.start(
            configuration: TravelSessionConfiguration(wifiDevice: "en0")
        )
        throw HostError.unexpectedResult("crash checkpoint returned: \(result)")
    }

    func runCrashAssociation(checkpoint: String) async throws {
        try validateCrashCheckpoint(checkpoint)
        let system = try FileBackedSystemController(
            fileURL: workspace.appendingPathComponent("provider-state.json"),
            journalURL: journalURL,
            initialPower: true,
            initialSSID: "Office"
        )
        let lease = try FileBackedLeaseClient(
            fileURL: workspace.appendingPathComponent("lease-state.json"),
            journalURL: journalURL
        )
        let observer = try FileBackedBoundaryObserver(
            fileURL: workspace.appendingPathComponent("trace-state.json"),
            checkpoint: checkpoint,
            checkpointURL: workspace.appendingPathComponent("checkpoint")
        )
        let coordinator = TravelSessionCoordinator(
            journalStore: FileTravelSessionJournalStore(fileURL: journalURL),
            system: system,
            leaseClient: lease,
            observer: observer
        )
        try requireActive(
            await coordinator.start(
                configuration: TravelSessionConfiguration(wifiDevice: "en0")
            ),
            context: "crash association setup"
        )
        let result = await coordinator.associate(
            device: "en0",
            ssid: "iPhone",
            password: nil
        )
        throw HostError.unexpectedResult("association crash checkpoint returned: \(result)")
    }

    func runCrashRestore(checkpoint: String) async throws {
        try validateCrashCheckpoint(checkpoint)
        let system = try FileBackedSystemController(
            fileURL: workspace.appendingPathComponent("provider-state.json"),
            journalURL: journalURL,
            initialPower: false,
            initialSSID: "Office"
        )
        let lease = try FileBackedLeaseClient(
            fileURL: workspace.appendingPathComponent("lease-state.json"),
            journalURL: journalURL
        )
        let store = FileTravelSessionJournalStore(fileURL: journalURL)
        let setupObserver = try FileBackedBoundaryObserver(
            fileURL: workspace.appendingPathComponent("trace-state.json")
        )
        let setup = TravelSessionCoordinator(
            journalStore: store,
            system: system,
            leaseClient: lease,
            observer: setupObserver
        )
        try requireActive(
            await setup.start(
                configuration: TravelSessionConfiguration(wifiDevice: "en0")
            ),
            context: "crash restore setup"
        )
        let blockingObserver = try FileBackedBoundaryObserver(
            fileURL: workspace.appendingPathComponent("trace-state.json"),
            checkpoint: checkpoint,
            checkpointURL: workspace.appendingPathComponent("checkpoint")
        )
        let cleanup = TravelSessionCoordinator(
            journalStore: store,
            system: system,
            leaseClient: lease,
            observer: blockingObserver
        )
        let result = await cleanup.stop()
        throw HostError.unexpectedResult("restore crash checkpoint returned: \(result)")
    }

    func runCrashLeaseReceipt() async throws {
        let system = try FileBackedSystemController(
            fileURL: workspace.appendingPathComponent("provider-state.json"),
            journalURL: journalURL,
            initialPower: true,
            initialSSID: "Office"
        )
        let lease = try FileBackedLeaseClient(
            fileURL: workspace.appendingPathComponent("lease-state.json"),
            journalURL: journalURL
        )
        let observer = try FileBackedBoundaryObserver(
            fileURL: workspace.appendingPathComponent("trace-state.json"),
            checkpoint: TravelSessionBoundary.leaseReceiptReturned.rawValue,
            checkpointURL: workspace.appendingPathComponent("checkpoint")
        )
        let coordinator = TravelSessionCoordinator(
            journalStore: FileTravelSessionJournalStore(fileURL: journalURL),
            system: system,
            leaseClient: lease,
            observer: observer
        )
        let result = await coordinator.start(
            configuration: TravelSessionConfiguration(wifiDevice: "en0")
        )
        throw HostError.unexpectedResult("lease receipt crash checkpoint returned: \(result)")
    }

    func validateCrashCheckpoint(_ checkpoint: String) throws {
        let allowed = Set([
            TravelSessionBoundary.afterIntentPersist.rawValue,
            TravelSessionBoundary.afterDispatch.rawValue,
            TravelSessionBoundary.afterVerification.rawValue,
            TravelSessionBoundary.beforeCompletionPersist.rawValue
        ])
        guard allowed.contains(checkpoint) else {
            throw HostError.invalidArguments
        }
    }

    func runRecovery() async throws {
        let base = FileTravelSessionJournalStore(fileURL: journalURL)
        guard let journal = try await base.load() else {
            throw HostError.missingState("session-journal.json")
        }
        let checkpointURL = workspace.appendingPathComponent("checkpoint")
        let checkpoint = try String(contentsOf: checkpointURL, encoding: .utf8)
        let system = try FileBackedSystemController(
            fileURL: workspace.appendingPathComponent("provider-state.json"),
            journalURL: journalURL,
            initialPower: false,
            initialSSID: "Office"
        )
        let lease = try FileBackedLeaseClient(
            fileURL: workspace.appendingPathComponent("lease-state.json"),
            journalURL: journalURL
        )
        let observer = try FileBackedBoundaryObserver(
            fileURL: workspace.appendingPathComponent("trace-state.json")
        )
        await observer.record(
            kind: "checkpoint_recovered",
            sessionID: journal.sessionID,
            value: checkpoint
        )
        let coordinator = TravelSessionCoordinator(
            journalStore: base,
            system: system,
            leaseClient: lease,
            observer: observer
        )
        let recovered = await coordinator.recover()
        try requireOff(recovered, context: "process-death recovery")
        let environment = CaseEnvironment(
            coordinator: coordinator,
            baseStore: base,
            system: system,
            lease: lease,
            observer: observer
        )
        try await record("recovery", result: recovered, environment: environment)
    }
}

private func waitForPath(
    _ url: URL,
    stage: String,
    timeout: TimeInterval = 5
) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if FileManager.default.fileExists(atPath: url.path) {
            return
        }
        try await Task.sleep(nanoseconds: 10_000_000)
    }
    throw HostError.timedOut(stage)
}

private func waitForTerminationRequested(
    _ journalURL: URL,
    stage: String,
    timeout: TimeInterval = 5
) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if let data = try? Data(contentsOf: journalURL),
           let journal = try? JSONDecoder().decode(TravelSessionJournal.self, from: data),
           journal.terminationRequested {
            return
        }
        try await Task.sleep(nanoseconds: 10_000_000)
    }
    throw HostError.timedOut(stage)
}

private func decodeJSON<Value: Decodable>(_ type: Value.Type, at url: URL) throws -> Value {
    try JSONDecoder().decode(type, from: Data(contentsOf: url))
}

private func writeJSON<Value: Encodable>(_ value: Value, to url: URL) throws {
    try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    try encoder.encode(value).write(to: url, options: .atomic)
}

private func writeExact(_ value: String, to url: URL) throws {
    try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    try Data(value.utf8).write(to: url, options: .atomic)
}

@main
private struct TravelSessionProofHost {
    static func main() async {
        do {
            let arguments = try HostArguments(arguments: CommandLine.arguments)
            try await ProofHostRunner(workspace: arguments.workspace).run(
                scenario: arguments.scenario,
                checkpoint: arguments.checkpoint
            )
        } catch {
            FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8))
            exit(EXIT_FAILURE)
        }
    }
}
