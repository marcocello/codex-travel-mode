import CodexTravelModeCore
import CodexTravelModeSleepLease
import Foundation

let lifecycleProofSensitiveFailure =
    "PROOF_SECRET_7f4d9a password=hunter-proof /usr/bin/pmset -b disablesleep 1"

struct LifecycleProofArguments {
    let scenario: String
    let launchID: String
    let fragmentURL: URL
    let markerURL: URL
    let livenessReceiptURL: URL
    let screenshotDirectory: URL

    static func parse(_ values: [String]) throws -> LifecycleProofArguments {
        func value(_ flag: String) -> String? {
            guard let index = values.firstIndex(of: flag), index + 1 < values.count else {
                return nil
            }
            return values[index + 1]
        }
        guard let scenario = value("--scenario"),
              let launchID = value("--launch-id"),
              let fragment = value("--fragment"),
              let marker = value("--marker"),
              let livenessReceipt = value("--liveness-receipt"),
              let screenshots = value("--screenshots") else {
            throw LifecycleProofError.invalidArguments
        }
        return LifecycleProofArguments(
            scenario: scenario,
            launchID: launchID,
            fragmentURL: URL(fileURLWithPath: fragment),
            markerURL: URL(fileURLWithPath: marker),
            livenessReceiptURL: URL(fileURLWithPath: livenessReceipt),
            screenshotDirectory: URL(fileURLWithPath: screenshots)
        )
    }
}

enum LifecycleProofError: LocalizedError {
    case invalidArguments
    case unknownScenario(String)
    case missingControl(String)
    case timeout(String)
    case rendering(String)

    var errorDescription: String? {
        switch self {
        case .invalidArguments:
            "Required arguments: --scenario NAME --launch-id ID --fragment PATH --marker PATH --liveness-receipt PATH --screenshots DIR"
        case .unknownScenario(let name):
            "Unknown lifecycle proof scenario: \(name)"
        case .missingControl(let name):
            "The production UI did not expose control \(name)."
        case .timeout(let detail):
            "Timed out waiting for \(detail)."
        case .rendering(let detail):
            "Native lifecycle UI rendering failed: \(detail)"
        }
    }
}

final class LifecycleProofTrace: @unchecked Sendable {
    private let lock = NSLock()
    private let outputURL: URL
    private var nextSequence = 1
    private var document: [String: Any]

    private static let collectionNames = [
        "input_events", "lifecycle_publications", "pending_quit_publications",
        "popover_records", "status_item_records", "accessibility_snapshots",
        "journal_snapshots", "commands", "termination_records", "activation_tasks",
        "process_records", "screenshots",
    ]

    init(arguments: LifecycleProofArguments) throws {
        outputURL = arguments.fragmentURL
        document = [
            "name": arguments.scenario,
            "launch_id": arguments.launchID,
            "pid": Int(ProcessInfo.processInfo.processIdentifier),
        ]
        for name in Self.collectionNames { document[name] = [[String: Any]]() }
        try persist()
    }

    @discardableResult
    func record(_ collection: String, _ values: [String: Any]) -> Int {
        lock.lock()
        defer { lock.unlock() }
        let sequence = nextSequence
        nextSequence += 1
        var record = values
        record["sequence"] = sequence
        var records = document[collection] as? [[String: Any]] ?? []
        records.append(record)
        document[collection] = records
        do {
            try persistLocked()
        } catch {
            FileHandle.standardError.write(Data("proof trace write failed: \(error)\n".utf8))
        }
        return sequence
    }

    func writeMarker(to url: URL) throws {
        try Data("ready\n".utf8).write(to: url, options: .atomic)
    }

    private func persist() throws {
        lock.lock()
        defer { lock.unlock() }
        try persistLocked()
    }

    private func persistLocked() throws {
        try FileManager.default.createDirectory(
            at: outputURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let data = try JSONSerialization.data(
            withJSONObject: document,
            options: [.prettyPrinted, .sortedKeys]
        )
        try data.write(to: outputURL, options: .atomic)
    }
}

actor LifecycleProofGate {
    private var isReleased = false

    func wait() async throws {
        while !isReleased {
            try Task.checkCancellation()
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    func release() { isReleased = true }
}

final class LifecycleProofSettingsStore: TravelSettingsStoring, @unchecked Sendable {
    private let lock = NSLock()
    private let revision: HotspotConfigurationRevision
    private let password = "proof-only-password"

    init() throws {
        revision = try HotspotConfigurationRevision(
            revisionID: "lifecycle-proof-revision",
            ssid: "Proof iPhone",
            wifiDevice: "en0",
            credentialReference: "lifecycle-proof-credential"
        )
    }

    func load() -> TravelModeSettings {
        TravelModeSettings(hotspotSSID: revision.ssid, wifiDevice: revision.wifiDevice ?? "")
    }
    func hasSavedHotspotPassword() -> Bool { true }
    func loadHotspotPassword() throws -> String { password }
    func loadHotspotPassword(credentialReference: String) throws -> String {
        guard credentialReference == revision.credentialReference else {
            throw HotspotConfigurationError.credentialMissing(credentialReference)
        }
        return password
    }
    func save(_ settings: TravelModeSettings) throws {}
    func recoverHotspotConfiguration() throws {}
    func activeHotspotConfiguration() throws -> HotspotConfigurationRevision? { revision }
    func legacyHotspotDraft() -> TravelModeSettings? { nil }
}

struct LifecycleProofDiscovery: WiFiDiscoveryProviding {
    func snapshot() async -> WiFiDiscoverySnapshot {
        WiFiDiscoverySnapshot(
            interfaceName: "en0",
            rememberedNetworks: [WiFiSSID(displayName: "Proof iPhone")].compactMap { $0 },
            visibleNetworks: [],
            visibleScanStatus: .completed
        )
    }
    func requestLocationAuthorization() async {}
}

actor LifecycleProofGateway: TravelCommandGateway {
    private let trace: LifecycleProofTrace
    private var keepAwakeStarted = false
    init(trace: LifecycleProofTrace) { self.trace = trace }

    func startKeepAwake() async throws {
        keepAwakeStarted = true
        trace.record("commands", [
            "source": "outer_provider", "operation": "keep_awake_start", "phase": "dispatch",
        ])
        trace.record("commands", [
            "source": "outer_provider", "operation": "keep_awake_start", "phase": "return",
            "exit_code": 0,
        ])
    }
    func stopKeepAwake() async {
        guard keepAwakeStarted else { return }
        keepAwakeStarted = false
        trace.record("commands", [
            "source": "outer_provider", "operation": "keep_awake_stop", "phase": "dispatch",
        ])
        trace.record("commands", [
            "source": "outer_provider", "operation": "keep_awake_stop", "phase": "return",
            "exit_code": 0,
        ])
    }
    func currentLidClosed() async -> Bool? { false }
    func discoverWiFiDevice() async -> String? { "en0" }
    func currentWiFiStatus(device: String) async -> WiFiStatus {
        WiFiStatus(device: device, networkName: "Office", rawOutput: "proof read-back")
    }
    func currentWiFiStatus(device: String, timeout: Duration) async -> WiFiStatus {
        await currentWiFiStatus(device: device)
    }
    func currentWiFiPower(device: String) async -> Bool? { true }
    func currentWiFiPower(device: String, timeout: Duration) async -> Bool? { true }
    func setWiFiPower(device: String, enabled: Bool) async -> CommandResult {
        CommandResult(exitCode: 0)
    }
    func setWiFiPower(device: String, enabled: Bool, timeout: Duration) async -> CommandResult {
        CommandResult(exitCode: 0)
    }
    func joinWiFi(device: String, ssid: String, password: String?) async -> CommandResult {
        CommandResult(exitCode: 0)
    }
    func joinWiFi(
        device: String, ssid: String, password: String?, timeout: Duration
    ) async -> CommandResult {
        CommandResult(exitCode: 0)
    }
    func openWiFiSettings() async {}
    func isCodexRunning() async -> Bool { true }
}

actor LifecycleProofSystem: TravelSessionSystemControlling {
    private let trace: LifecycleProofTrace
    private let baselineGate: LifecycleProofGate?
    private var powerEnabled = true
    private var ssid: String? = "Office"

    init(trace: LifecycleProofTrace, baselineGate: LifecycleProofGate? = nil) {
        self.trace = trace
        self.baselineGate = baselineGate
    }

    func currentWiFiPower(device: String) async throws -> Bool {
        trace.record("commands", [
            "source": "outer_provider", "operation": "read_wifi_power", "phase": "dispatch",
        ])
        do {
            try await baselineGate?.wait()
        } catch {
            trace.record("commands", [
                "source": "outer_provider", "operation": "read_wifi_power",
                "phase": "cancelled", "gate": "baseline",
            ])
            throw error
        }
        trace.record("commands", [
            "source": "outer_provider", "operation": "read_wifi_power", "phase": "return",
            "value": powerEnabled,
        ])
        return powerEnabled
    }
    func currentWiFiPower(device: String, timeout: Duration) async throws -> Bool {
        try await currentWiFiPower(device: device)
    }
    func currentAssociatedSSID(device: String) async throws -> String? {
        trace.record("commands", [
            "source": "outer_provider", "operation": "read_wifi_association", "phase": "dispatch",
        ])
        do {
            try await baselineGate?.wait()
        } catch {
            trace.record("commands", [
                "source": "outer_provider", "operation": "read_wifi_association",
                "phase": "cancelled", "gate": "baseline",
            ])
            throw error
        }
        trace.record("commands", [
            "source": "outer_provider", "operation": "read_wifi_association", "phase": "return",
            "value": ssid ?? NSNull(),
        ])
        return ssid
    }
    func currentAssociatedSSID(device: String, timeout: Duration) async throws -> String? {
        try await currentAssociatedSSID(device: device)
    }
    func setWiFiPower(device: String, enabled: Bool) async -> CommandResult {
        powerEnabled = enabled
        return CommandResult(exitCode: 0)
    }
    func setWiFiPower(device: String, enabled: Bool, timeout: Duration) async -> CommandResult {
        await setWiFiPower(device: device, enabled: enabled)
    }
    func associate(device: String, ssid: String, password: String?) async -> CommandResult {
        self.ssid = ssid
        return CommandResult(exitCode: 0)
    }
    func associate(
        device: String, ssid: String, password: String?, timeout: Duration
    ) async -> CommandResult {
        await associate(device: device, ssid: ssid, password: password)
    }
}

actor LifecycleProofLeaseClient: SleepOverrideLeaseClient {
    private let trace: LifecycleProofTrace
    private let acquireGate: LifecycleProofGate?
    private let releaseGate: LifecycleProofGate?
    private var releaseFailures: Int
    private let releaseFailureCategory: String
    private let releaseFailureDetail: String
    private var binding: SleepOverrideLeaseBinding?
    private var cleanupOperation: String

    init(
        trace: LifecycleProofTrace,
        acquireGate: LifecycleProofGate? = nil,
        releaseGate: LifecycleProofGate? = nil,
        releaseFailures: Int = 0,
        releaseFailureCategory: String = "command_failed",
        releaseFailureDetail: String = "proof-injected cleanup failure",
        cleanupOperation: String = "cleanup"
    ) {
        self.trace = trace
        self.acquireGate = acquireGate
        self.releaseGate = releaseGate
        self.releaseFailures = releaseFailures
        self.releaseFailureCategory = releaseFailureCategory
        self.releaseFailureDetail = releaseFailureDetail
        self.cleanupOperation = cleanupOperation
    }

    func setCleanupOperation(_ value: String) { cleanupOperation = value }

    func seed(binding: SleepOverrideLeaseBinding) { self.binding = binding }

    func acquire(sessionID: String, requestID: String) async throws -> SleepOverrideLeaseReceipt {
        trace.record("commands", [
            "source": "outer_provider", "operation": "lease_acquire", "phase": "dispatch",
            "session_id": sessionID, "request_id": requestID,
        ])
        do {
            try await acquireGate?.wait()
        } catch {
            trace.record("commands", [
                "source": "outer_provider", "operation": "lease_acquire",
                "phase": "cancelled", "gate": "acquire", "session_id": sessionID,
            ])
            throw error
        }
        let value = SleepOverrideLeaseBinding(
            sessionID: sessionID,
            requestID: requestID,
            leaseID: "proof-lease-\(sessionID)",
            generation: "proof-generation"
        )
        binding = value
        trace.record("commands", [
            "source": "outer_provider", "operation": "lease_acquire", "phase": "return",
            "session_id": sessionID, "exit_code": 0,
        ])
        return SleepOverrideLeaseReceipt(phase: .active, binding: value)
    }

    func resolve(sessionID: String, requestID: String) async throws -> SleepOverrideLeaseResolution {
        guard let binding,
              binding.sessionID == sessionID,
              binding.requestID == requestID else { return .authoritativeNotFound }
        return .found(SleepOverrideLeaseReceipt(phase: .active, binding: binding))
    }

    func status(binding: SleepOverrideLeaseBinding) async throws -> SleepOverrideLeaseReceipt {
        SleepOverrideLeaseReceipt(phase: .released, binding: binding)
    }

    func release(binding: SleepOverrideLeaseBinding) async throws -> SleepOverrideLeaseReceipt {
        let operation = cleanupOperation
        trace.record("commands", [
            "source": "outer_provider", "operation": operation, "phase": "dispatch",
            "session_id": binding.sessionID,
        ])
        try await releaseGate?.wait()
        if releaseFailures > 0 {
            releaseFailures -= 1
            trace.record("commands", [
                "source": "outer_provider", "operation": operation, "phase": "return",
                "session_id": binding.sessionID, "failure_category": releaseFailureCategory,
                "raw_detail": releaseFailureDetail,
            ])
            throw SleepOverrideLeaseError.cleanupRequired(releaseFailureDetail)
        }
        trace.record("commands", [
            "source": "outer_provider", "operation": operation, "phase": "return",
            "session_id": binding.sessionID, "exit_code": 0,
        ])
        return SleepOverrideLeaseReceipt(phase: .released, binding: binding)
    }

    func acknowledgeRelease(binding: SleepOverrideLeaseBinding) async throws {}
    func retryCleanup(binding: SleepOverrideLeaseBinding) async throws -> SleepOverrideLeaseReceipt {
        try await release(binding: binding)
    }
    nonisolated func protectionEvents() -> AsyncStream<SleepOverrideLeaseProtectionEvent> {
        AsyncStream { $0.finish() }
    }
}

actor LifecycleProofJournalStore: TravelSessionJournalStoring {
    private let base: FileTravelSessionJournalStore
    private let trace: LifecycleProofTrace
    let fileURL: URL

    init(fileURL: URL, trace: LifecycleProofTrace) {
        self.fileURL = fileURL
        self.trace = trace
        self.base = FileTravelSessionJournalStore(fileURL: fileURL)
    }

    func load() async throws -> TravelSessionJournal? {
        try await base.load()
    }

    func create(_ journal: TravelSessionJournal) async throws -> TravelSessionJournal {
        let value = try await base.create(journal)
        record(value, kind: "created")
        return value
    }

    func update(
        _ journal: TravelSessionJournal,
        expectedRevision: Int
    ) async throws -> TravelSessionJournal {
        let value = try await base.update(journal, expectedRevision: expectedRevision)
        record(value, kind: "updated")
        return value
    }

    func clear(sessionID: String, expectedRevision: Int) async throws {
        try await base.clear(sessionID: sessionID, expectedRevision: expectedRevision)
        trace.record("journal_snapshots", [
            "state": "journal_cleared", "kind": "cleared", "phase": "cleared",
            "session_id": sessionID, "path": fileURL.path, "byte_count": 0,
        ])
    }

    func recordCurrent(kind: String = "readback") async {
        guard let value = try? await base.load() else {
            trace.record("journal_snapshots", [
                "state": "journal_absent", "kind": kind, "phase": "cleared",
                "path": fileURL.path, "byte_count": 0,
            ])
            return
        }
        record(value, kind: kind)
    }

    private func record(_ journal: TravelSessionJournal, kind: String) {
        let byteCount = (try? Data(contentsOf: fileURL).count) ?? 0
        trace.record("journal_snapshots", [
            "state": "journal_present", "kind": kind, "phase": journal.phase.rawValue,
            "session_id": journal.sessionID, "revision": journal.revision,
            "termination_requested": journal.terminationRequested,
            "lease_status": journal.leaseStatus?.rawValue ?? NSNull(),
            "path": fileURL.path, "byte_count": byteCount,
        ])
    }
}

actor LifecycleProofBoundaryObserver: TravelSessionBoundaryObserving {
    private let trace: LifecycleProofTrace
    private let heldBoundary: TravelSessionBoundary?
    private let gate: LifecycleProofGate?

    init(
        trace: LifecycleProofTrace,
        heldBoundary: TravelSessionBoundary? = nil,
        gate: LifecycleProofGate? = nil
    ) {
        self.trace = trace
        self.heldBoundary = heldBoundary
        self.gate = gate
    }

    func reached(
        _ boundary: TravelSessionBoundary,
        sessionID: String?,
        value: String?
    ) async {
        trace.record("commands", [
            "source": "production_session_owner", "operation": "boundary",
            "phase": boundary.rawValue, "session_id": sessionID ?? NSNull(),
        ])
        guard heldBoundary?.rawValue == boundary.rawValue else { return }
        do {
            try await gate?.wait()
            trace.record("commands", [
                "source": "outer_provider", "operation": "boundary_gate",
                "phase": "return", "boundary": boundary.rawValue,
                "session_id": sessionID ?? NSNull(),
            ])
        } catch {
            trace.record("commands", [
                "source": "outer_provider", "operation": "boundary_gate",
                "phase": "cancelled", "boundary": boundary.rawValue,
                "session_id": sessionID ?? NSNull(),
            ])
        }
    }
}
