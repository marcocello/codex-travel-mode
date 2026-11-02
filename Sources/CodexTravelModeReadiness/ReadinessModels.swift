import Foundation

public enum ReadinessScenario: String, Codable, CaseIterable, Sendable {
    case stop
    case quit
    case ownerDeath = "owner_death"
}

public enum ReadinessStage: String, Codable, Sendable {
    case scenarioBaseline = "scenario_baseline"
    case activeBeforeLid = "active_before_lid"
    case closedBeforeSubmit = "closed_before_submit"
    case closedAfterSubmit = "closed_after_submit"
    case reopened
    case postStop = "post_stop"
    case preQuitExit = "pre_quit_exit"
    case postQuitExit = "post_quit_exit"
    case ownerDeathPreKill = "owner_death_pre_kill"
    case ownerDeathHelperRecovered = "owner_death_helper_recovered"
    case ownerDeathPostRelaunch = "owner_death_post_relaunch"
    case final
}

public enum ReadinessActor: String, Codable, Sendable {
    case harness
    case operatorUser = "operator"
    case system
    case app
    case helper
    case provider
}

public struct ReadinessRecordHeader: Codable, Equatable, Sendable {
    public var eventSequence: Int
    public var wallTime: String
    public var monotonicNanoseconds: UInt64
    public var scenario: ReadinessScenario
    public var actor: ReadinessActor

    enum CodingKeys: String, CodingKey {
        case eventSequence = "event_sequence"
        case wallTime = "wall_time"
        case monotonicNanoseconds = "monotonic_nanoseconds"
        case scenario
        case actor
    }

    public init(
        eventSequence: Int,
        wallTime: String,
        monotonicNanoseconds: UInt64,
        scenario: ReadinessScenario,
        actor: ReadinessActor
    ) {
        self.eventSequence = eventSequence
        self.wallTime = wallTime
        self.monotonicNanoseconds = monotonicNanoseconds
        self.scenario = scenario
        self.actor = actor
    }
}

public struct ReadinessRawEnvelope<Record: Codable & Sendable>: Codable, Sendable {
    public var schemaVersion: Int
    public var runID: String
    public var producerPID: Int32
    public var targetSSIDDigest: String
    public var records: [Record]

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case runID = "run_id"
        case producerPID = "producer_pid"
        case targetSSIDDigest = "target_ssid_digest"
        case records
    }

    public init(
        runID: String,
        producerPID: Int32,
        targetSSIDDigest: String,
        records: [Record] = []
    ) {
        self.schemaVersion = 1
        self.runID = runID
        self.producerPID = producerPID
        self.targetSSIDDigest = targetSSIDDigest
        self.records = records
    }
}

public enum ReadinessScenarioEventKind: String, Codable, Sendable {
    case scenarioStarted = "scenario_started"
    case baselineCaptured = "baseline_captured"
    case appActiveObserved = "app_active_observed"
    case lidClosedObserved = "lid_closed_observed"
    case heartbeatWindowOpened = "heartbeat_window_opened"
    case heartbeatWindowClosed = "heartbeat_window_closed"
    case restorationObserved = "restoration_observed"
    case scenarioClosed = "scenario_closed"
    case scenarioAborted = "scenario_aborted"
}

public struct ReadinessScenarioEvent: Codable, Equatable, Sendable {
    public var header: ReadinessRecordHeader
    public var kind: ReadinessScenarioEventKind
    public var stage: ReadinessStage
    public var detailCode: String?

    enum CodingKeys: String, CodingKey {
        case header
        case kind
        case stage
        case detailCode = "detail_code"
    }
}

public enum ReadinessPowerSource: String, Codable, Sendable {
    case battery
    case ac
    case unknown
}

public enum ReadinessAddressClass: String, Codable, Sendable {
    case usableIPv4 = "usable_ipv4"
    case usableIPv6 = "usable_ipv6"
    case loopback
    case linkLocal = "link_local"
    case unspecified
}

public struct ReadinessSystemSnapshot: Codable, Equatable, Sendable {
    public var header: ReadinessRecordHeader
    public var stage: ReadinessStage
    public var sleepDisabled: Bool
    public var powerSource: ReadinessPowerSource
    public var batteryPercent: Int
    public var lidClosed: Bool
    public var wifiDevice: String
    public var wifiPower: Bool
    public var ssidDigest: String?
    public var addressClasses: [ReadinessAddressClass]
    public var providerRouteDevice: String?
    public var appExecutableHash: String
    public var helperExecutableHash: String
    public var teamIdentifier: String

    enum CodingKeys: String, CodingKey {
        case header
        case stage
        case sleepDisabled = "sleep_disabled"
        case powerSource = "power_source"
        case batteryPercent = "battery_percent"
        case lidClosed = "lid_closed"
        case wifiDevice = "wifi_device"
        case wifiPower = "wifi_power"
        case ssidDigest = "ssid_digest"
        case addressClasses = "address_classes"
        case providerRouteDevice = "provider_route_device"
        case appExecutableHash = "app_executable_hash"
        case helperExecutableHash = "helper_executable_hash"
        case teamIdentifier = "team_identifier"
    }
}

public enum ReadinessProcessEventKind: String, Codable, Sendable {
    case launchRequested = "launch_requested"
    case appeared
    case identityCaptured = "identity_captured"
    case quitControlAnnounced = "quit_control_announced"
    case exitObserved = "exit_observed"
    case sigkillRequested = "sigkill_requested"
    case sigkillObserved = "sigkill_observed"
    case relaunchAnnounced = "relaunch_announced"
    case reappeared
}

public struct ReadinessProcessEvent: Codable, Equatable, Sendable {
    public var header: ReadinessRecordHeader
    public var kind: ReadinessProcessEventKind
    public var pid: Int32
    public var startIdentityDigest: String
    public var executablePathDigest: String
    public var teamIdentifier: String
    public var signal: Int32?

    enum CodingKeys: String, CodingKey {
        case header
        case kind
        case pid
        case startIdentityDigest = "start_identity_digest"
        case executablePathDigest = "executable_path_digest"
        case teamIdentifier = "team_identifier"
        case signal
    }
}

public enum ReadinessJournalState: String, Codable, Sendable {
    case absent
    case present
    case indeterminate
}

public struct ReadinessJournalPresence: Codable, Equatable, Sendable {
    public var header: ReadinessRecordHeader
    public var stage: ReadinessStage
    public var appJournalState: ReadinessJournalState
    public var helperJournalState: ReadinessJournalState

    enum CodingKeys: String, CodingKey {
        case header
        case stage
        case appJournalState = "app_journal_state"
        case helperJournalState = "helper_journal_state"
    }
}

public enum ReadinessOperatorEventKind: String, Codable, Sendable {
    case safetyAcknowledged = "safety_acknowledged"
    case startAnnounced = "start_announced"
    case lidCloseAnnounced = "lid_close_announced"
    case lidOpenAnnounced = "lid_open_announced"
    case stopAnnounced = "stop_announced"
    case quitAnnounced = "quit_announced"
    case relaunchAnnounced = "relaunch_announced"
}

public struct ReadinessOperatorEvent: Codable, Equatable, Sendable {
    public var header: ReadinessRecordHeader
    public var kind: ReadinessOperatorEventKind
    public var inputSource: String

    enum CodingKeys: String, CodingKey {
        case header
        case kind
        case inputSource = "input_source"
    }
}

public enum ReadinessCleanupEventKind: String, Codable, Sendable {
    case cleanupEntered = "cleanup_entered"
    case appkitTerminationRequested = "appkit_termination_requested"
    case operatorStopRequested = "operator_stop_requested"
    case operatorRelaunchRequested = "operator_relaunch_requested"
    case helperOwnerDeathWait = "helper_owner_death_wait"
    case baselineReobserved = "baseline_reobserved"
    case cleanupAbandoned = "cleanup_abandoned"
}

public enum ReadinessCleanupProvenance: String, Codable, Sendable {
    case productionAppKitQuit = "production_appkit_quit"
    case productionManualControl = "production_manual_control"
    case productionStartupRecovery = "production_startup_recovery"
    case helperOwnerDeath = "helper_owner_death"
    case none
}

public struct ReadinessCleanupEvent: Codable, Equatable, Sendable {
    public var header: ReadinessRecordHeader
    public var kind: ReadinessCleanupEventKind
    public var provenance: ReadinessCleanupProvenance
    public var reasonCode: String

    enum CodingKeys: String, CodingKey {
        case header
        case kind
        case provenance
        case reasonCode = "reason_code"
    }
}

public struct ReadinessProviderReceiptRecord: Codable, Equatable, Sendable {
    public var header: ReadinessRecordHeader
    public var snapshotEventSequence: Int
    public var readAt: String
    public var canonicalPayloadBase64: String
    public var signatureBase64: String
    public var submitHTTPStatus: Int
    public var readbackHTTPStatus: Int

    enum CodingKeys: String, CodingKey {
        case header
        case snapshotEventSequence = "snapshot_event_sequence"
        case readAt = "read_at"
        case canonicalPayloadBase64 = "canonical_payload_base64"
        case signatureBase64 = "signature_base64"
        case submitHTTPStatus = "submit_http_status"
        case readbackHTTPStatus = "readback_http_status"
    }
}

public struct ReadinessCanonicalProviderReceipt: Codable, Equatable, Sendable {
    public var schemaVersion: Int
    public var runID: String
    public var scenario: ReadinessScenario
    public var nonce: String
    public var heartbeatSequence: Int
    public var clientSentAt: String
    public var serverReceivedAt: String
    public var sourceAddressDigest: String

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case runID = "run_id"
        case scenario
        case nonce
        case heartbeatSequence = "heartbeat_sequence"
        case clientSentAt = "client_sent_at"
        case serverReceivedAt = "server_received_at"
        case sourceAddressDigest = "source_address_digest"
    }
}

public struct ReadinessCommandRecord: Codable, Equatable, Sendable {
    public var sequence: Int
    public var wallTime: String
    public var executable: String
    public var arguments: [String]
    public var exitStatus: Int32
    public var standardOutputDigest: String
    public var standardErrorDigest: String
    public var elapsedMilliseconds: Int

    enum CodingKeys: String, CodingKey {
        case sequence
        case wallTime = "wall_time"
        case executable
        case arguments
        case exitStatus = "exit_status"
        case standardOutputDigest = "standard_output_digest"
        case standardErrorDigest = "standard_error_digest"
        case elapsedMilliseconds = "elapsed_milliseconds"
    }
}

public struct ReadinessRestorationDifference: Codable, Equatable, Sendable {
    public var field: String
    public var baseline: String
    public var observed: String
    public var relation: String
}
