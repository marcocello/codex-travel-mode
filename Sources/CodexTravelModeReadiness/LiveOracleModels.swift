import Foundation

public enum LiveOracleVerdict: String, Codable, Sendable {
    case accept
    case reject
}

public enum LiveOracleArtifactRole: String, Codable, Sendable {
    case controller
    case observer
}

public enum LiveOraclePowerSource: String, Codable, Sendable {
    case battery
    case ac
    case unknown
}

public enum LiveOracleJournalState: String, Codable, Sendable {
    case absent
    case present
    case indeterminate
}

public enum LiveOracleObserverEventKind: String, Codable, Sendable {
    case preflightSample = "preflight_sample"
    case scenarioBaseline = "scenario_baseline"
    case closedBeforeTransport = "closed_before_transport"
    case closedAfterTransport = "closed_after_transport"
    case mandatoryCleanup = "mandatory_cleanup"
    case processExit = "process_exit"
    case ownerDeathHelperStage = "owner_death_helper_stage"
    case ownerDeathRelaunchedCleanup = "owner_death_relaunched_cleanup"
    case scenarioFinal = "scenario_final"
    case unsafeAction = "unsafe_action"
    case observationFailure = "observation_failure"
    case attachRejected = "attach_rejected"
}

public enum LiveOracleControllerEventKind: String, Codable, Sendable {
    case heartbeatSubmitRequest = "heartbeat_submit_request"
    case heartbeatReadbackRequest = "heartbeat_readback_request"
    case appLaunchRequest = "app_launch_request"
    case ownerDeathSIGKILLRequest = "owner_death_sigkill_request"
    case start = "start"
    case lidClose = "lid_close"
    case lidOpen = "lid_open"
    case stopRestore = "stop_restore"
    case quit
    case relaunch
    case cleanupEntered = "cleanup_entered"
    case productionStopRequested = "production_stop_requested"
    case productionQuitRequested = "production_quit_requested"
    case startupRecoveryRequested = "startup_recovery_requested"
    case helperOwnerDeathWait = "helper_owner_death_wait"
    case safetyTerminateRequested = "safety_terminate_requested"
    case directRescueRequested = "direct_rescue_requested"
}

public struct LiveOracleFileMetadata: Equatable, Sendable {
    public let byteCount: Int64
    public let mode: UInt16
    public let ownerUID: UInt32
    public let isRegularFile: Bool

    public init(byteCount: Int64, mode: UInt16, ownerUID: UInt32, isRegularFile: Bool) {
        self.byteCount = byteCount
        self.mode = mode
        self.ownerUID = ownerUID
        self.isRegularFile = isRegularFile
    }
}

public struct LiveOracleRequest: Sendable {
    public let evidenceDirectory: URL
    public let oracle: LiveProofProcessIdentity
    public let expectedOwnerUID: UInt32
    public let forbiddenSentinels: [Data]
    public let allowedAuxiliaryNames: Set<String>

    public init(
        evidenceDirectory: URL,
        oracle: LiveProofProcessIdentity,
        expectedOwnerUID: UInt32,
        forbiddenSentinels: [Data] = [],
        allowedAuxiliaryNames: Set<String> = [".arming-consumed"]
    ) {
        self.evidenceDirectory = evidenceDirectory.standardizedFileURL
        self.oracle = oracle
        self.expectedOwnerUID = expectedOwnerUID
        self.forbiddenSentinels = forbiddenSentinels
        self.allowedAuxiliaryNames = allowedAuxiliaryNames
    }
}

public struct LiveOracleReport: Codable, Equatable, Sendable {
    public static let schema = "codex-travel-mode-oracle-report/v1"

    public let schema: String
    public let runID: String?
    public let oracle: LiveProofProcessIdentity
    public let verdict: LiveOracleVerdict
    public let issueCodes: [String]

    enum CodingKeys: String, CodingKey {
        case schema
        case runID = "run_id"
        case oracle
        case verdict
        case issueCodes = "issue_codes"
    }

    init(
        runID: String?,
        oracle: LiveProofProcessIdentity,
        verdict: LiveOracleVerdict,
        issueCodes: [String]
    ) {
        schema = Self.schema
        self.runID = runID
        self.oracle = oracle
        self.verdict = verdict
        self.issueCodes = issueCodes
    }
}

public struct LiveOracleManifestEntry: Codable, Equatable, Sendable {
    public let name: String
    public let role: LiveOracleArtifactRole
    public let author: LiveProofProcessIdentity
    public let byteCount: Int64
    public let mode: UInt16
    public let sha256: String

    enum CodingKeys: String, CodingKey {
        case name
        case role
        case author
        case byteCount = "byte_count"
        case mode
        case sha256
    }

    public init(
        name: String,
        role: LiveOracleArtifactRole,
        author: LiveProofProcessIdentity,
        byteCount: Int64,
        mode: UInt16 = 0o400,
        sha256: String
    ) {
        self.name = name
        self.role = role
        self.author = author
        self.byteCount = byteCount
        self.mode = mode
        self.sha256 = sha256
    }
}

public struct LiveOracleSealManifest: Codable, Equatable, Sendable {
    public static let schema = "codex-travel-mode-seal-manifest/v2"

    public let schema: String
    public let runID: String
    public let author: LiveProofProcessIdentity
    public let entries: [LiveOracleManifestEntry]

    enum CodingKeys: String, CodingKey {
        case schema
        case runID = "run_id"
        case author
        case entries
    }

    public init(
        runID: String,
        author: LiveProofProcessIdentity,
        entries: [LiveOracleManifestEntry]
    ) {
        schema = Self.schema
        self.runID = runID
        self.author = author
        self.entries = entries.sorted { $0.name < $1.name }
    }
}

public struct LiveOracleProviderCapability: Codable, Equatable, Sendable {
    public static let schema = "codex-travel-mode-heartbeat-capability/v1"
    public static let protocolName = "codex-travel-mode-heartbeat/v1"

    public let schema: String
    public let protocolName: String
    public let capabilityPath: String
    public let submitPath: String
    public let readbackPath: String
    public let serverUnixMilliseconds: Int64
    public let clockOffsetMilliseconds: Int64
    public let maximumClockSkewSeconds: Int

    enum CodingKeys: String, CodingKey {
        case schema
        case protocolName = "protocol"
        case capabilityPath = "capability_path"
        case submitPath = "submit_path"
        case readbackPath = "readback_path"
        case serverUnixMilliseconds = "server_unix_milliseconds"
        case clockOffsetMilliseconds = "clock_offset_milliseconds"
        case maximumClockSkewSeconds = "maximum_clock_skew_seconds"
    }

    public init(
        capabilityPath: String,
        submitPath: String,
        readbackPath: String,
        serverUnixMilliseconds: Int64,
        clockOffsetMilliseconds: Int64,
        maximumClockSkewSeconds: Int
    ) {
        schema = Self.schema
        protocolName = Self.protocolName
        self.capabilityPath = capabilityPath
        self.submitPath = submitPath
        self.readbackPath = readbackPath
        self.serverUnixMilliseconds = serverUnixMilliseconds
        self.clockOffsetMilliseconds = clockOffsetMilliseconds
        self.maximumClockSkewSeconds = maximumClockSkewSeconds
    }
}

public struct LiveOraclePreflightReadback: Codable, Equatable, Sendable {
    public static let schema = "codex-travel-mode-preflight-readback/v1"

    public let schema: String
    public let runID: String
    public let producer: LiveProofProcessIdentity
    public let observerPublicKey: String
    public let machineDigest: String
    public let baselineDigest: String
    public let appIdentityDigest: String
    public let helperIdentityDigest: String
    public let priorSSIDDigest: String
    public let targetSSIDDigest: String
    public let providerOrigin: String
    public let providerPublicKey: String
    public let outputDirectoryDigest: String
    public let directoryMode: UInt16
    public let socketMode: UInt16
    public let observerUIDDigest: String
    public let preflightPeerUIDDigest: String
    public let capability: LiveOracleProviderCapability

    enum CodingKeys: String, CodingKey {
        case schema
        case runID = "run_id"
        case producer
        case observerPublicKey = "observer_public_key"
        case machineDigest = "machine_digest"
        case baselineDigest = "baseline_digest"
        case appIdentityDigest = "app_identity_digest"
        case helperIdentityDigest = "helper_identity_digest"
        case priorSSIDDigest = "prior_ssid_digest"
        case targetSSIDDigest = "target_ssid_digest"
        case providerOrigin = "provider_origin"
        case providerPublicKey = "provider_public_key"
        case outputDirectoryDigest = "output_directory_digest"
        case directoryMode = "directory_mode"
        case socketMode = "socket_mode"
        case observerUIDDigest = "observer_uid_digest"
        case preflightPeerUIDDigest = "preflight_peer_uid_digest"
        case capability
    }

    public init(
        runID: String,
        producer: LiveProofProcessIdentity,
        observerPublicKey: String,
        machineDigest: String,
        baselineDigest: String,
        appIdentityDigest: String,
        helperIdentityDigest: String,
        priorSSIDDigest: String,
        targetSSIDDigest: String,
        providerOrigin: String,
        providerPublicKey: String,
        outputDirectoryDigest: String,
        directoryMode: UInt16 = 0o700,
        socketMode: UInt16 = 0o600,
        observerUIDDigest: String,
        preflightPeerUIDDigest: String,
        capability: LiveOracleProviderCapability
    ) {
        schema = Self.schema
        self.runID = runID
        self.producer = producer
        self.observerPublicKey = observerPublicKey
        self.machineDigest = machineDigest
        self.baselineDigest = baselineDigest
        self.appIdentityDigest = appIdentityDigest
        self.helperIdentityDigest = helperIdentityDigest
        self.priorSSIDDigest = priorSSIDDigest
        self.targetSSIDDigest = targetSSIDDigest
        self.providerOrigin = providerOrigin
        self.providerPublicKey = providerPublicKey
        self.outputDirectoryDigest = outputDirectoryDigest
        self.directoryMode = directoryMode
        self.socketMode = socketMode
        self.observerUIDDigest = observerUIDDigest
        self.preflightPeerUIDDigest = preflightPeerUIDDigest
        self.capability = capability
    }
}

public struct LiveOracleSystemSnapshot: Codable, Equatable, Sendable {
    public let powerSource: LiveOraclePowerSource
    public let batteryPercent: Int
    public let lidClosed: Bool
    public let sleepDisabled: Int
    public let wifiPower: Bool
    public let selectedWiFiDeviceDigest: String
    public let ssidDigest: String?
    public let usableAddressDigests: [String]
    public let routeRemoteAddressDigest: String?
    public let routeDeviceDigest: String?
    public let appRunning: Bool
    public let appJournal: LiveOracleJournalState
    public let helperJournal: LiveOracleJournalState
    public let helperJournalAuthorizationCode: Int
    public let appIdentityDigest: String
    public let helperIdentityDigest: String

    enum CodingKeys: String, CodingKey {
        case powerSource = "power_source"
        case batteryPercent = "battery_percent"
        case lidClosed = "lid_closed"
        case sleepDisabled = "sleep_disabled"
        case wifiPower = "wifi_power"
        case selectedWiFiDeviceDigest = "selected_wifi_device_digest"
        case ssidDigest = "ssid_digest"
        case usableAddressDigests = "usable_address_digests"
        case routeRemoteAddressDigest = "route_remote_address_digest"
        case routeDeviceDigest = "route_device_digest"
        case appRunning = "app_running"
        case appJournal = "app_journal"
        case helperJournal = "helper_journal"
        case helperJournalAuthorizationCode = "helper_journal_authorization_code"
        case appIdentityDigest = "app_identity_digest"
        case helperIdentityDigest = "helper_identity_digest"
    }

    public init(
        powerSource: LiveOraclePowerSource,
        batteryPercent: Int,
        lidClosed: Bool,
        sleepDisabled: Int,
        wifiPower: Bool,
        selectedWiFiDeviceDigest: String,
        ssidDigest: String?,
        usableAddressDigests: [String],
        routeRemoteAddressDigest: String?,
        routeDeviceDigest: String?,
        appRunning: Bool,
        appJournal: LiveOracleJournalState,
        helperJournal: LiveOracleJournalState,
        helperJournalAuthorizationCode: Int,
        appIdentityDigest: String,
        helperIdentityDigest: String
    ) {
        self.powerSource = powerSource
        self.batteryPercent = batteryPercent
        self.lidClosed = lidClosed
        self.sleepDisabled = sleepDisabled
        self.wifiPower = wifiPower
        self.selectedWiFiDeviceDigest = selectedWiFiDeviceDigest
        self.ssidDigest = ssidDigest
        self.usableAddressDigests = usableAddressDigests
        self.routeRemoteAddressDigest = routeRemoteAddressDigest
        self.routeDeviceDigest = routeDeviceDigest
        self.appRunning = appRunning
        self.appJournal = appJournal
        self.helperJournal = helperJournal
        self.helperJournalAuthorizationCode = helperJournalAuthorizationCode
        self.appIdentityDigest = appIdentityDigest
        self.helperIdentityDigest = helperIdentityDigest
    }
}

public struct LiveOracleObserverEventPayload: Codable, Equatable, Sendable {
    public static let schema = "codex-travel-mode-observer-event-payload/v1"

    public let schema: String
    public let runID: String
    public let eventSequence: Int
    public let requestSequence: Int
    public let phase: LiveProofHandshakePhase
    public let unixMilliseconds: Int64
    public let monotonicNanoseconds: UInt64
    public let scenario: ReadinessScenario?
    public let kind: LiveOracleObserverEventKind
    public let baselineDigest: String?
    public let snapshot: LiveOracleSystemSnapshot?
    public let process: LiveProofProcessIdentity?
    public let failureCode: String?

    enum CodingKeys: String, CodingKey {
        case schema
        case runID = "run_id"
        case eventSequence = "event_sequence"
        case requestSequence = "request_sequence"
        case phase
        case unixMilliseconds = "unix_milliseconds"
        case monotonicNanoseconds = "monotonic_nanoseconds"
        case scenario
        case kind
        case baselineDigest = "baseline_digest"
        case snapshot
        case process
        case failureCode = "failure_code"
    }

    public init(
        runID: String,
        eventSequence: Int,
        requestSequence: Int,
        phase: LiveProofHandshakePhase,
        unixMilliseconds: Int64,
        monotonicNanoseconds: UInt64,
        scenario: ReadinessScenario?,
        kind: LiveOracleObserverEventKind,
        baselineDigest: String? = nil,
        snapshot: LiveOracleSystemSnapshot? = nil,
        process: LiveProofProcessIdentity? = nil,
        failureCode: String? = nil
    ) {
        schema = Self.schema
        self.runID = runID
        self.eventSequence = eventSequence
        self.requestSequence = requestSequence
        self.phase = phase
        self.unixMilliseconds = unixMilliseconds
        self.monotonicNanoseconds = monotonicNanoseconds
        self.scenario = scenario
        self.kind = kind
        self.baselineDigest = baselineDigest
        self.snapshot = snapshot
        self.process = process
        self.failureCode = failureCode
    }
}

public struct LiveOracleObserverEventsArtifact: Codable, Equatable, Sendable {
    public static let schema = "codex-travel-mode-observer-events/v2"

    public let schema: String
    public let runID: String
    public let producer: LiveProofProcessIdentity
    public let observerPublicKey: String
    public let handshakes: [LiveProofSignedPayload]
    public let sessionPeerUIDDigests: [String]
    public let sessionCount: Int
    public let rejectedAttachCount: Int
    public let events: [LiveProofSignedEventEnvelope]

    enum CodingKeys: String, CodingKey {
        case schema
        case runID = "run_id"
        case producer
        case observerPublicKey = "observer_public_key"
        case handshakes
        case sessionPeerUIDDigests = "session_peer_uid_digests"
        case sessionCount = "session_count"
        case rejectedAttachCount = "rejected_attach_count"
        case events
    }

    public init(
        runID: String,
        producer: LiveProofProcessIdentity,
        observerPublicKey: String,
        handshakes: [LiveProofSignedPayload],
        sessionPeerUIDDigests: [String],
        sessionCount: Int,
        rejectedAttachCount: Int,
        events: [LiveProofSignedEventEnvelope]
    ) {
        schema = Self.schema
        self.runID = runID
        self.producer = producer
        self.observerPublicKey = observerPublicKey
        self.handshakes = handshakes
        self.sessionPeerUIDDigests = sessionPeerUIDDigests
        self.sessionCount = sessionCount
        self.rejectedAttachCount = rejectedAttachCount
        self.events = events
    }
}

public struct LiveOracleObserverSealPayload: Codable, Equatable, Sendable {
    public static let schema = "codex-travel-mode-observer-seal-payload/v2"

    public let schema: String
    public let runID: String
    public let observer: LiveProofProcessIdentity
    public let observerPublicKey: String
    public let eventCount: Int
    public let finalEnvelopeSHA256: String
    public let observerOwnedFiles: [LiveOracleManifestEntry]

    enum CodingKeys: String, CodingKey {
        case schema
        case runID = "run_id"
        case observer
        case observerPublicKey = "observer_public_key"
        case eventCount = "event_count"
        case finalEnvelopeSHA256 = "final_envelope_sha256"
        case observerOwnedFiles = "observer_owned_files"
    }

    public init(
        runID: String,
        observer: LiveProofProcessIdentity,
        observerPublicKey: String,
        eventCount: Int,
        finalEnvelopeSHA256: String,
        observerOwnedFiles: [LiveOracleManifestEntry]
    ) {
        schema = Self.schema
        self.runID = runID
        self.observer = observer
        self.observerPublicKey = observerPublicKey
        self.eventCount = eventCount
        self.finalEnvelopeSHA256 = finalEnvelopeSHA256
        self.observerOwnedFiles = observerOwnedFiles.sorted { $0.name < $1.name }
    }
}

public struct LiveOracleControllerEvent: Codable, Equatable, Sendable {
    public let sequence: Int
    public let unixMilliseconds: Int64
    public let monotonicNanoseconds: UInt64
    public let scenario: ReadinessScenario?
    public let kind: LiveOracleControllerEventKind
    public let heartbeatSequence: Int?
    public let nonce: String?
    public let process: LiveProofProcessIdentity?
    public let signal: Int32?

    enum CodingKeys: String, CodingKey {
        case sequence
        case unixMilliseconds = "unix_milliseconds"
        case monotonicNanoseconds = "monotonic_nanoseconds"
        case scenario
        case kind
        case heartbeatSequence = "heartbeat_sequence"
        case nonce
        case process
        case signal
    }

    public init(
        sequence: Int,
        unixMilliseconds: Int64,
        monotonicNanoseconds: UInt64,
        scenario: ReadinessScenario?,
        kind: LiveOracleControllerEventKind,
        heartbeatSequence: Int? = nil,
        nonce: String? = nil,
        process: LiveProofProcessIdentity? = nil,
        signal: Int32? = nil
    ) {
        self.sequence = sequence
        self.unixMilliseconds = unixMilliseconds
        self.monotonicNanoseconds = monotonicNanoseconds
        self.scenario = scenario
        self.kind = kind
        self.heartbeatSequence = heartbeatSequence
        self.nonce = nonce
        self.process = process
        self.signal = signal
    }
}

public struct LiveOracleControllerArtifact: Codable, Equatable, Sendable {
    public let schema: String
    public let runID: String
    public let producer: LiveProofProcessIdentity
    public let events: [LiveOracleControllerEvent]

    enum CodingKeys: String, CodingKey {
        case schema
        case runID = "run_id"
        case producer
        case events
    }

    public init(
        schema: String,
        runID: String,
        producer: LiveProofProcessIdentity,
        events: [LiveOracleControllerEvent]
    ) {
        self.schema = schema
        self.runID = runID
        self.producer = producer
        self.events = events
    }
}

public struct LiveOracleProviderTransportRecord: Codable, Equatable, Sendable {
    public let scenario: ReadinessScenario
    public let sequence: Int
    public let nonce: String
    public let dispatchUnixMilliseconds: Int64
    public let completionUnixMilliseconds: Int64
    public let localAddressDigest: String
    public let remoteAddressDigest: String
    public let beforeObserverEventSequence: Int
    public let afterObserverEventSequence: Int

    enum CodingKeys: String, CodingKey {
        case scenario
        case sequence
        case nonce
        case dispatchUnixMilliseconds = "dispatch_unix_milliseconds"
        case completionUnixMilliseconds = "completion_unix_milliseconds"
        case localAddressDigest = "local_address_digest"
        case remoteAddressDigest = "remote_address_digest"
        case beforeObserverEventSequence = "before_observer_event_sequence"
        case afterObserverEventSequence = "after_observer_event_sequence"
    }

    public init(
        scenario: ReadinessScenario,
        sequence: Int,
        nonce: String,
        dispatchUnixMilliseconds: Int64,
        completionUnixMilliseconds: Int64,
        localAddressDigest: String,
        remoteAddressDigest: String,
        beforeObserverEventSequence: Int,
        afterObserverEventSequence: Int
    ) {
        self.scenario = scenario
        self.sequence = sequence
        self.nonce = nonce
        self.dispatchUnixMilliseconds = dispatchUnixMilliseconds
        self.completionUnixMilliseconds = completionUnixMilliseconds
        self.localAddressDigest = localAddressDigest
        self.remoteAddressDigest = remoteAddressDigest
        self.beforeObserverEventSequence = beforeObserverEventSequence
        self.afterObserverEventSequence = afterObserverEventSequence
    }
}

public struct LiveOracleProviderTransportArtifact: Codable, Equatable, Sendable {
    public static let schema = "codex-travel-mode-provider-transport-events/v1"

    public let schema: String
    public let runID: String
    public let producer: LiveProofProcessIdentity
    public let records: [LiveOracleProviderTransportRecord]

    enum CodingKeys: String, CodingKey {
        case schema
        case runID = "run_id"
        case producer
        case records
    }

    public init(
        runID: String,
        producer: LiveProofProcessIdentity,
        records: [LiveOracleProviderTransportRecord]
    ) {
        schema = Self.schema
        self.runID = runID
        self.producer = producer
        self.records = records
    }
}

public struct LiveOracleProviderReceiptSet: Codable, Equatable, Sendable {
    public let scenario: ReadinessScenario
    public let receipts: [LiveProofProviderReceipt]

    public init(scenario: ReadinessScenario, receipts: [LiveProofProviderReceipt]) {
        self.scenario = scenario
        self.receipts = receipts
    }
}

public struct LiveOracleProviderReceiptsArtifact: Codable, Equatable, Sendable {
    public static let schema = "codex-travel-mode-provider-receipts/v1"

    public let schema: String
    public let runID: String
    public let producer: LiveProofProcessIdentity
    public let receiptSets: [LiveOracleProviderReceiptSet]

    enum CodingKeys: String, CodingKey {
        case schema
        case runID = "run_id"
        case producer
        case receiptSets = "receipt_sets"
    }

    public init(
        runID: String,
        producer: LiveProofProcessIdentity,
        receiptSets: [LiveOracleProviderReceiptSet]
    ) {
        schema = Self.schema
        self.runID = runID
        self.producer = producer
        self.receiptSets = receiptSets
    }
}
