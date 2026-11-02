import Foundation
import CodexTravelModeSleepLease

public enum TravelSessionLifecycle: String, Codable, Sendable {
    case off
    case preparing
    case active
    case restoring
    case cleanupRequired = "cleanup_required"
}

public enum TravelSessionMutationKind: String, Codable, Sendable {
    case wifiPower = "wifi_power"
    case association
}

public enum TravelSessionMutationPhase: String, Codable, Sendable {
    case prepared
    case dispatched
    case verified
}

public struct TravelWiFiBaseline: Codable, Equatable, Sendable {
    public var device: String
    public var powerEnabled: Bool
    public var associatedSSID: String?

    public init(device: String, powerEnabled: Bool, associatedSSID: String?) {
        self.device = device
        self.powerEnabled = powerEnabled
        self.associatedSSID = associatedSSID
    }

    enum CodingKeys: String, CodingKey {
        case device
        case powerEnabled = "power_enabled"
        case associatedSSID = "associated_ssid"
    }
}

public struct TravelSessionMutationIntent: Codable, Equatable, Sendable {
    public var id: String
    public var kind: TravelSessionMutationKind
    public var baseline: String
    public var target: String
    public var phase: TravelSessionMutationPhase

    public init(
        id: String = UUID().uuidString,
        kind: TravelSessionMutationKind,
        baseline: String,
        target: String,
        phase: TravelSessionMutationPhase = .prepared
    ) {
        self.id = id
        self.kind = kind
        self.baseline = baseline
        self.target = target
        self.phase = phase
    }
}

public struct TravelSessionJournal: Codable, Equatable, Sendable {
    public var schemaVersion: Int
    public var revision: Int
    public var sessionID: String
    public var phase: TravelSessionLifecycle
    public var wifiBaseline: TravelWiFiBaseline
    public var pendingMutation: TravelSessionMutationIntent?
    public var changedWiFiPower: Bool
    public var changedAssociation: Bool
    public var leaseRequestID: String
    public var leaseBinding: SleepOverrideLeaseBinding?
    public var leaseStatus: SleepOverrideLeasePhase?
    public var terminationRequested: Bool
    public var createdAt: String
    public var lastCleanupFailure: String?

    public init(
        sessionID: String = UUID().uuidString,
        wifiBaseline: TravelWiFiBaseline,
        leaseRequestID: String = UUID().uuidString,
        createdAt: String = ISO8601DateFormatter().string(from: Date())
    ) {
        self.schemaVersion = 1
        self.revision = 0
        self.sessionID = sessionID
        self.phase = .preparing
        self.wifiBaseline = wifiBaseline
        self.pendingMutation = nil
        self.changedWiFiPower = false
        self.changedAssociation = false
        self.leaseRequestID = leaseRequestID
        self.leaseBinding = nil
        self.leaseStatus = nil
        self.terminationRequested = false
        self.createdAt = createdAt
        self.lastCleanupFailure = nil
    }

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case revision
        case sessionID = "session_id"
        case phase
        case wifiBaseline = "wifi_baseline"
        case pendingMutation = "pending_mutation"
        case changedWiFiPower = "changed_wifi_power"
        case changedAssociation = "changed_association"
        case leaseRequestID = "lease_request_id"
        case leaseBinding = "lease_binding"
        case leaseStatus = "lease_status"
        case terminationRequested = "termination_requested"
        case createdAt = "created_at"
        case lastCleanupFailure = "last_cleanup_failure"
    }
}

public struct TravelSessionTransitionResult: Codable, Equatable, Sendable {
    public var lifecycle: TravelSessionLifecycle
    public var sessionID: String?
    public var warning: String?
    public var error: String?
    public var canTerminate: Bool

    public init(
        lifecycle: TravelSessionLifecycle,
        sessionID: String? = nil,
        warning: String? = nil,
        error: String? = nil,
        canTerminate: Bool? = nil
    ) {
        self.lifecycle = lifecycle
        self.sessionID = sessionID
        self.warning = warning
        self.error = error
        self.canTerminate = canTerminate ?? (lifecycle == .off)
    }
}
