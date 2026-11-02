import Foundation

public enum SleepOverrideLeaseJournalPhase: String, Codable, Equatable, Sendable {
    case prepared
    case applied
    case active
    case restoring
    case restored
    case receiptCommitted = "receipt_committed"
    case cleanupRequired = "cleanup_required"
}

public enum SleepOverrideLeasePendingOperation: String, Codable, Equatable, Sendable {
    case enableOverride = "enable_override"
    case restoreBaseline = "restore_baseline"
    case commitReceipt = "commit_receipt"
    case removeJournal = "remove_journal"
}

public struct SleepOverrideLeaseJournal: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var revision: UInt64
    public var binding: SleepOverrideLeaseBinding
    public var principal: SleepOverrideLeaseCallerPrincipal
    public var ownerConnectionID: SleepOverrideLeaseConnectionID
    public var baselineSleepDisabled: Bool
    public var changedSleepDisabled: Bool
    public var phase: SleepOverrideLeaseJournalPhase
    public var pendingOperation: SleepOverrideLeasePendingOperation?
    public var createdAt: Date
    public var updatedAt: Date
    public var lastFailure: String?
    public var cleanupAttempt: Int

    public init(
        schemaVersion: Int = SleepOverrideLeaseJournal.currentSchemaVersion,
        revision: UInt64 = 0,
        binding: SleepOverrideLeaseBinding,
        principal: SleepOverrideLeaseCallerPrincipal,
        ownerConnectionID: SleepOverrideLeaseConnectionID,
        baselineSleepDisabled: Bool,
        changedSleepDisabled: Bool,
        phase: SleepOverrideLeaseJournalPhase,
        pendingOperation: SleepOverrideLeasePendingOperation?,
        createdAt: Date,
        updatedAt: Date,
        lastFailure: String? = nil,
        cleanupAttempt: Int = 0
    ) {
        self.schemaVersion = schemaVersion
        self.revision = revision
        self.binding = binding
        self.principal = principal
        self.ownerConnectionID = ownerConnectionID
        self.baselineSleepDisabled = baselineSleepDisabled
        self.changedSleepDisabled = changedSleepDisabled
        self.phase = phase
        self.pendingOperation = pendingOperation
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.lastFailure = lastFailure
        self.cleanupAttempt = cleanupAttempt
    }

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case revision
        case binding
        case principal
        case ownerConnectionID = "owner_connection_id"
        case baselineSleepDisabled = "baseline_sleep_disabled"
        case changedSleepDisabled = "changed_sleep_disabled"
        case phase
        case pendingOperation = "pending_operation"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case lastFailure = "last_failure"
        case cleanupAttempt = "cleanup_attempt"
    }
}

public struct SleepOverrideLeaseStoredReceipt: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var binding: SleepOverrideLeaseBinding
    public var principal: SleepOverrideLeaseCallerPrincipal
    public var releasedAt: Date

    public init(
        schemaVersion: Int = SleepOverrideLeaseStoredReceipt.currentSchemaVersion,
        binding: SleepOverrideLeaseBinding,
        principal: SleepOverrideLeaseCallerPrincipal,
        releasedAt: Date
    ) {
        self.schemaVersion = schemaVersion
        self.binding = binding
        self.principal = principal
        self.releasedAt = releasedAt
    }
}

public enum SleepOverrideLeaseStateStoreError: LocalizedError, Equatable, Sendable {
    case activeJournalAlreadyExists
    case activeJournalMissing
    case staleJournalRevision(expected: UInt64, actual: UInt64)
    case bindingMismatch
    case immutableReceiptConflict
    case corruptState(String)
    case unsafePath(String)
    case readbackMismatch(String)

    public var errorDescription: String? {
        switch self {
        case .activeJournalAlreadyExists:
            "An active sleep-override journal already exists."
        case .activeJournalMissing:
            "The active sleep-override journal is missing."
        case .staleJournalRevision(let expected, let actual):
            "Sleep-override journal revision \(expected) is stale; current revision is \(actual)."
        case .bindingMismatch:
            "The requested sleep-override binding does not own this record."
        case .immutableReceiptConflict:
            "A different immutable receipt already occupies this binding."
        case .corruptState(let detail):
            "The durable sleep-override state is corrupt: \(detail)"
        case .unsafePath(let detail):
            "The durable sleep-override path is unsafe: \(detail)"
        case .readbackMismatch(let detail):
            "The durable sleep-override read-back did not match: \(detail)"
        }
    }
}

public protocol SleepOverrideLeaseStateStoring: Sendable {
    func loadActiveJournal() async throws -> SleepOverrideLeaseJournal?
    func createActiveJournal(
        _ journal: SleepOverrideLeaseJournal
    ) async throws -> SleepOverrideLeaseJournal
    func updateActiveJournal(
        _ journal: SleepOverrideLeaseJournal,
        expectedRevision: UInt64
    ) async throws -> SleepOverrideLeaseJournal
    func removeActiveJournal(
        binding: SleepOverrideLeaseBinding,
        expectedRevision: UInt64
    ) async throws
    func loadReleasedReceipt(
        binding: SleepOverrideLeaseBinding
    ) async throws -> SleepOverrideLeaseStoredReceipt?
    func findReleasedReceipt(
        sessionID: String,
        requestID: String
    ) async throws -> SleepOverrideLeaseStoredReceipt?
    func createReleasedReceipt(
        _ receipt: SleepOverrideLeaseStoredReceipt
    ) async throws -> SleepOverrideLeaseStoredReceipt
    func removeReleasedReceipt(
        binding: SleepOverrideLeaseBinding,
        expectedPrincipal: SleepOverrideLeaseCallerPrincipal
    ) async throws
}

public protocol SleepOverridePowerBackend: Sendable {
    func readSleepDisabled() async throws -> Bool
    func setSleepDisabled(_ enabled: Bool) async throws
}

public protocol SleepOverrideLeaseClock: Sendable {
    func now() async -> Date
    func sleep(for duration: Duration) async throws
}

public struct ContinuousSleepOverrideLeaseClock: SleepOverrideLeaseClock {
    public init() {}

    public func now() async -> Date {
        Date()
    }

    public func sleep(for duration: Duration) async throws {
        try await ContinuousClock().sleep(for: duration)
    }
}

public enum SleepOverrideLeaseTransitionPoint: String, Codable, Equatable, Sendable {
    case preparedPersisted = "prepared_persisted"
    case overrideWriteCompleted = "override_write_completed"
    case appliedPersisted = "applied_persisted"
    case activePersisted = "active_persisted"
    case restoringPersisted = "restoring_persisted"
    case baselineRestored = "baseline_restored"
    case restoredPersisted = "restored_persisted"
    case receiptPersisted = "receipt_persisted"
    case receiptCommittedPersisted = "receipt_committed_persisted"
    case activeJournalRemoved = "active_journal_removed"
    case cleanupRequiredPersisted = "cleanup_required_persisted"
}

public struct SleepOverrideLeaseTransition: Equatable, Sendable {
    public var point: SleepOverrideLeaseTransitionPoint
    public var binding: SleepOverrideLeaseBinding
    public var revision: UInt64

    public init(
        point: SleepOverrideLeaseTransitionPoint,
        binding: SleepOverrideLeaseBinding,
        revision: UInt64
    ) {
        self.point = point
        self.binding = binding
        self.revision = revision
    }
}

public protocol SleepOverrideLeaseTransitionObserving: Sendable {
    func observe(_ transition: SleepOverrideLeaseTransition) async
}

public struct NoOpSleepOverrideLeaseTransitionObserver: SleepOverrideLeaseTransitionObserving {
    public init() {}

    public func observe(_ transition: SleepOverrideLeaseTransition) async {}
}
