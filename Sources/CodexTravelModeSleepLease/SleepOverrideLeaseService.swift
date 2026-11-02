import Foundation

public actor SleepOverrideLeaseService {
    private struct ScheduledRetry {
        var token: UUID
        var binding: SleepOverrideLeaseBinding
        var task: Task<Void, Never>
    }

    private let store: any SleepOverrideLeaseStateStoring
    private let powerBackend: any SleepOverridePowerBackend
    private let clock: any SleepOverrideLeaseClock
    private let transitionObserver: any SleepOverrideLeaseTransitionObserving
    private var startupReconciled = false
    private var operationLocked = false
    private var operationWaiters: [CheckedContinuation<Void, Never>] = []
    private var scheduledRetry: ScheduledRetry?
    private var invalidatedConnectionIDs: Set<SleepOverrideLeaseConnectionID> = []

    public init(
        store: any SleepOverrideLeaseStateStoring,
        powerBackend: any SleepOverridePowerBackend,
        clock: any SleepOverrideLeaseClock = ContinuousSleepOverrideLeaseClock(),
        transitionObserver: any SleepOverrideLeaseTransitionObserving =
            NoOpSleepOverrideLeaseTransitionObserver()
    ) {
        self.store = store
        self.powerBackend = powerBackend
        self.clock = clock
        self.transitionObserver = transitionObserver
    }

    deinit {
        scheduledRetry?.task.cancel()
    }

    public func reconcileOnStartup() async throws {
        await lockOperation()
        defer { unlockOperation() }
        try await reconcileOnStartupLocked()
    }

    public func acquire(
        sessionID: String,
        requestID: String,
        context: SleepOverrideLeaseCallContext
    ) async throws -> SleepOverrideLeaseReceipt {
        await lockOperation()
        defer { unlockOperation() }
        try validate(sessionID: sessionID, requestID: requestID, context: context)
        guard !invalidatedConnectionIDs.contains(context.connectionID) else {
            throw SleepOverrideLeaseError.rejected(
                "The owning connection ended before lease acquisition."
            )
        }
        try await ensureStartupReconciled()
        if let existing = try await existingAcquisition(
            sessionID: sessionID,
            requestID: requestID,
            context: context
        ) {
            return existing
        }
        return try await performAcquisition(
            sessionID: sessionID,
            requestID: requestID,
            context: context
        )
    }

    public func resolve(
        sessionID: String,
        requestID: String,
        context: SleepOverrideLeaseCallContext
    ) async throws -> SleepOverrideLeaseResolution {
        await lockOperation()
        defer { unlockOperation() }
        try validate(sessionID: sessionID, requestID: requestID, context: context)
        try await ensureStartupReconciled()
        if let journal = try await loadValidatedJournal(),
           journal.binding.sessionID == sessionID,
           journal.binding.requestID == requestID {
            try validate(principal: context.principal, owns: journal)
            return .found(receipt(for: journal))
        }
        guard let stored = try await store.findReleasedReceipt(
            sessionID: sessionID,
            requestID: requestID
        ) else {
            return .authoritativeNotFound
        }
        try validate(principal: context.principal, owns: stored)
        return .found(releasedReceipt(for: stored))
    }

    public func status(
        binding: SleepOverrideLeaseBinding,
        context: SleepOverrideLeaseCallContext
    ) async throws -> SleepOverrideLeaseReceipt {
        await lockOperation()
        defer { unlockOperation() }
        try validate(binding: binding, context: context)
        try await ensureStartupReconciled()
        if let journal = try await loadValidatedJournal(), journal.binding == binding {
            try validate(principal: context.principal, owns: journal)
            return receipt(for: journal)
        }
        guard let stored = try await store.loadReleasedReceipt(binding: binding) else {
            throw SleepOverrideLeaseError.invalidReceipt
        }
        try validate(principal: context.principal, owns: stored)
        return releasedReceipt(for: stored)
    }

    public func release(
        binding: SleepOverrideLeaseBinding,
        context: SleepOverrideLeaseCallContext
    ) async throws -> SleepOverrideLeaseReceipt {
        await lockOperation()
        defer { unlockOperation() }
        try validate(binding: binding, context: context)
        try await ensureStartupReconciled()
        if let journal = try await loadValidatedJournal(), journal.binding == binding {
            try validate(principal: context.principal, owns: journal)
            return try await restoreAndRelease(journal)
        }
        guard let stored = try await store.loadReleasedReceipt(binding: binding) else {
            throw SleepOverrideLeaseError.invalidReceipt
        }
        try validate(principal: context.principal, owns: stored)
        return releasedReceipt(for: stored)
    }

    public func acknowledgeRelease(
        binding: SleepOverrideLeaseBinding,
        context: SleepOverrideLeaseCallContext
    ) async throws {
        await lockOperation()
        defer { unlockOperation() }
        try validate(binding: binding, context: context)
        try await ensureStartupReconciled()
        if let journal = try await loadValidatedJournal(), journal.binding == binding {
            throw SleepOverrideLeaseError.rejected("An active lease cannot be acknowledged.")
        }
        guard let receipt = try await store.loadReleasedReceipt(binding: binding) else {
            throw SleepOverrideLeaseError.invalidReceipt
        }
        try validate(principal: context.principal, owns: receipt)
        try await store.removeReleasedReceipt(
            binding: binding,
            expectedPrincipal: context.principal
        )
    }

    public func retryCleanup(
        binding: SleepOverrideLeaseBinding,
        context: SleepOverrideLeaseCallContext
    ) async throws -> SleepOverrideLeaseReceipt {
        await lockOperation()
        defer { unlockOperation() }
        try validate(binding: binding, context: context)
        try await ensureStartupReconciled()
        if let journal = try await loadValidatedJournal(), journal.binding == binding {
            try validate(principal: context.principal, owns: journal)
            guard journal.phase == .cleanupRequired || journal.phase == .restoring ||
                    journal.phase == .restored || journal.phase == .receiptCommitted else {
                throw SleepOverrideLeaseError.rejected("The active lease does not require cleanup.")
            }
            cancelScheduledRetry(for: binding)
            return try await restoreAndRelease(journal)
        }
        guard let receipt = try await store.loadReleasedReceipt(binding: binding) else {
            throw SleepOverrideLeaseError.invalidReceipt
        }
        try validate(principal: context.principal, owns: receipt)
        return releasedReceipt(for: receipt)
    }

    public func connectionInvalidated(id: SleepOverrideLeaseConnectionID) async {
        invalidatedConnectionIDs.insert(id)
        await lockOperation()
        defer { unlockOperation() }
        do {
            try await ensureStartupReconciled()
            guard let journal = try await loadValidatedJournal(),
                  journal.ownerConnectionID == id else { return }
            _ = try await restoreAndRelease(journal)
        } catch {
            // Durable cleanup state and retry scheduling are handled by restoreAndRelease.
        }
    }
}

private extension SleepOverrideLeaseService {
    func reconcileOnStartupLocked() async throws {
        guard !startupReconciled else { return }
        guard let journal = try await loadValidatedJournal() else {
            startupReconciled = true
            return
        }
        _ = try await restoreAndRelease(journal)
        startupReconciled = true
    }

    func ensureStartupReconciled() async throws {
        if !startupReconciled {
            try await reconcileOnStartupLocked()
        }
    }

    func existingAcquisition(
        sessionID: String,
        requestID: String,
        context: SleepOverrideLeaseCallContext
    ) async throws -> SleepOverrideLeaseReceipt? {
        if let journal = try await loadValidatedJournal() {
            guard journal.binding.sessionID == sessionID,
                  journal.binding.requestID == requestID else {
                throw SleepOverrideLeaseError.rejected(
                    "Another sleep-override lease already owns the fixed operation."
                )
            }
            try validate(principal: context.principal, owns: journal)
            return receipt(for: journal)
        }
        guard let stored = try await store.findReleasedReceipt(
            sessionID: sessionID,
            requestID: requestID
        ) else { return nil }
        try validate(principal: context.principal, owns: stored)
        return releasedReceipt(for: stored)
    }

    func performAcquisition(
        sessionID: String,
        requestID: String,
        context: SleepOverrideLeaseCallContext
    ) async throws -> SleepOverrideLeaseReceipt {
        let baseline = try await powerBackend.readSleepDisabled()
        let timestamp = await clock.now()
        let binding = SleepOverrideLeaseBinding(
            sessionID: sessionID,
            requestID: requestID,
            leaseID: UUID().uuidString,
            generation: UUID().uuidString
        )
        let candidate = SleepOverrideLeaseJournal(
            binding: binding,
            principal: context.principal,
            ownerConnectionID: context.connectionID,
            baselineSleepDisabled: baseline,
            changedSleepDisabled: !baseline,
            phase: .prepared,
            pendingOperation: baseline ? nil : .enableOverride,
            createdAt: timestamp,
            updatedAt: timestamp
        )
        do {
            var journal = try await store.createActiveJournal(candidate)
            await observe(.preparedPersisted, journal: journal)
            journal = try await applyOverride(journal)
            journal = try await persist(
                journal,
                phase: .active,
                pendingOperation: nil,
                lastFailure: nil
            )
            await observe(.activePersisted, journal: journal)
            return receipt(for: journal)
        } catch {
            _ = try await compensateFailedAcquisition(binding: binding, originalError: error)
            throw SleepOverrideLeaseError.interruptedAfterPossibleDispatch
        }
    }

    func applyOverride(
        _ journal: SleepOverrideLeaseJournal
    ) async throws -> SleepOverrideLeaseJournal {
        if !journal.baselineSleepDisabled {
            try await powerBackend.setSleepDisabled(true)
            await observe(.overrideWriteCompleted, journal: journal)
        }
        guard try await powerBackend.readSleepDisabled() else {
            throw SleepOverrideLeaseError.invalidResponse(
                "SleepDisabled did not read back as enabled after acquisition."
            )
        }
        let applied = try await persist(
            journal,
            phase: .applied,
            pendingOperation: nil,
            lastFailure: nil
        )
        await observe(.appliedPersisted, journal: applied)
        return applied
    }

    func compensateFailedAcquisition(
        binding: SleepOverrideLeaseBinding,
        originalError: Error
    ) async throws -> SleepOverrideLeaseReceipt {
        guard let journal = try await loadValidatedJournal(), journal.binding == binding else {
            throw originalError
        }
        return try await restoreAndRelease(journal)
    }
}

private extension SleepOverrideLeaseService {
    func restoreAndRelease(
        _ initial: SleepOverrideLeaseJournal
    ) async throws -> SleepOverrideLeaseReceipt {
        let existingReceipt: SleepOverrideLeaseStoredReceipt?
        do {
            existingReceipt = try await store.loadReleasedReceipt(binding: initial.binding)
        } catch {
            existingReceipt = nil
        }
        if let existingReceipt {
            guard existingReceipt.principal == initial.principal else {
                return try await retainCleanupFailure(
                    for: initial.binding,
                    error: SleepOverrideLeaseStateStoreError.immutableReceiptConflict
                )
            }
            return try await finishExistingReceipt(initial)
        }
        do {
            var journal = try await persist(
                initial,
                phase: .restoring,
                pendingOperation: .restoreBaseline,
                lastFailure: nil
            )
            await observe(.restoringPersisted, journal: journal)
            try await restoreBaseline(journal)
            await observe(.baselineRestored, journal: journal)
            journal = try await persist(
                journal,
                phase: .restored,
                pendingOperation: .commitReceipt,
                lastFailure: nil,
                cleanupAttempt: 0
            )
            await observe(.restoredPersisted, journal: journal)
            return try await commitReceiptAndRemoveJournal(journal)
        } catch {
            return try await retainCleanupFailure(for: initial.binding, error: error)
        }
    }

    func finishExistingReceipt(
        _ initial: SleepOverrideLeaseJournal
    ) async throws -> SleepOverrideLeaseReceipt {
        do {
            var journal = initial
            if journal.phase != .receiptCommitted &&
                !(journal.phase == .cleanupRequired && journal.pendingOperation == .removeJournal) {
                journal = try await persist(
                    journal,
                    phase: .cleanupRequired,
                    pendingOperation: .removeJournal,
                    lastFailure: "Recovered a durable released receipt before journal removal."
                )
                await observe(.cleanupRequiredPersisted, journal: journal)
            }
            return try await finishCommittedReceipt(journal)
        } catch {
            return try await retainCleanupFailure(for: initial.binding, error: error)
        }
    }

    func restoreBaseline(_ journal: SleepOverrideLeaseJournal) async throws {
        let current = try await powerBackend.readSleepDisabled()
        if current != journal.baselineSleepDisabled {
            try await powerBackend.setSleepDisabled(journal.baselineSleepDisabled)
        }
        let readback = try await powerBackend.readSleepDisabled()
        guard readback == journal.baselineSleepDisabled else {
            throw SleepOverrideLeaseError.invalidResponse(
                "SleepDisabled did not read back as the captured baseline."
            )
        }
    }

    func commitReceiptAndRemoveJournal(
        _ initial: SleepOverrideLeaseJournal
    ) async throws -> SleepOverrideLeaseReceipt {
        let candidate = SleepOverrideLeaseStoredReceipt(
            binding: initial.binding,
            principal: initial.principal,
            releasedAt: initial.updatedAt
        )
        let stored = try await store.createReleasedReceipt(candidate)
        guard stored == candidate else {
            throw SleepOverrideLeaseStateStoreError.readbackMismatch("released receipt")
        }
        await observe(.receiptPersisted, journal: initial)
        let committed = try await persist(
            initial,
            phase: .receiptCommitted,
            pendingOperation: .removeJournal,
            lastFailure: nil,
            cleanupAttempt: 0
        )
        await observe(.receiptCommittedPersisted, journal: committed)
        return try await finishCommittedReceipt(committed)
    }

    func finishCommittedReceipt(
        _ journal: SleepOverrideLeaseJournal
    ) async throws -> SleepOverrideLeaseReceipt {
        guard let stored = try await store.loadReleasedReceipt(binding: journal.binding),
              stored.principal == journal.principal else {
            throw SleepOverrideLeaseStateStoreError.corruptState(
                "A committed journal has no matching immutable receipt."
            )
        }
        try await store.removeActiveJournal(
            binding: journal.binding,
            expectedRevision: journal.revision
        )
        await observe(.activeJournalRemoved, journal: journal)
        cancelScheduledRetry(for: journal.binding)
        return releasedReceipt(for: stored)
    }

    func retainCleanupFailure(
        for binding: SleepOverrideLeaseBinding,
        error: Error
    ) async throws -> SleepOverrideLeaseReceipt {
        guard var latest = try await loadValidatedJournal(), latest.binding == binding else {
            if let receipt = try await store.loadReleasedReceipt(binding: binding) {
                return releasedReceipt(for: receipt)
            }
            throw SleepOverrideLeaseError.cleanupRequired(error.localizedDescription)
        }
        let pending = try await cleanupPendingOperation(for: latest)
        latest = try await persist(
            latest,
            phase: .cleanupRequired,
            pendingOperation: pending,
            lastFailure: error.localizedDescription,
            cleanupAttempt: latest.cleanupAttempt + 1
        )
        await observe(.cleanupRequiredPersisted, journal: latest)
        scheduleRetry(for: latest)
        return receipt(for: latest)
    }

    func cleanupPendingOperation(
        for journal: SleepOverrideLeaseJournal
    ) async throws -> SleepOverrideLeasePendingOperation {
        do {
            if let receipt = try await store.loadReleasedReceipt(binding: journal.binding) {
                return receipt.principal == journal.principal ? .removeJournal : .restoreBaseline
            }
        } catch {
            return .restoreBaseline
        }
        return .restoreBaseline
    }
}

private extension SleepOverrideLeaseService {
    func persist(
        _ journal: SleepOverrideLeaseJournal,
        phase: SleepOverrideLeaseJournalPhase,
        pendingOperation: SleepOverrideLeasePendingOperation?,
        lastFailure: String?,
        cleanupAttempt: Int? = nil
    ) async throws -> SleepOverrideLeaseJournal {
        var candidate = journal
        candidate.phase = phase
        candidate.pendingOperation = pendingOperation
        candidate.lastFailure = lastFailure
        candidate.cleanupAttempt = cleanupAttempt ?? journal.cleanupAttempt
        candidate.updatedAt = await clock.now()
        return try await store.updateActiveJournal(
            candidate,
            expectedRevision: journal.revision
        )
    }

    func loadValidatedJournal() async throws -> SleepOverrideLeaseJournal? {
        guard let journal = try await store.loadActiveJournal() else { return nil }
        guard journal.schemaVersion == SleepOverrideLeaseJournal.currentSchemaVersion,
              journal.revision > 0,
              journal.cleanupAttempt >= 0,
              !journal.binding.sessionID.isEmpty,
              !journal.binding.requestID.isEmpty,
              !journal.binding.leaseID.isEmpty,
              !journal.binding.generation.isEmpty,
              !journal.ownerConnectionID.rawValue.isEmpty else {
            throw SleepOverrideLeaseStateStoreError.corruptState("invalid active journal fields")
        }
        return journal
    }

    func receipt(for journal: SleepOverrideLeaseJournal) -> SleepOverrideLeaseReceipt {
        let phase: SleepOverrideLeasePhase
        switch journal.phase {
        case .prepared, .applied:
            phase = .acquiring
        case .active:
            phase = .active
        case .restoring, .restored:
            phase = .restoring
        case .cleanupRequired:
            phase = .cleanupRequired
        case .receiptCommitted:
            phase = .released
        }
        return SleepOverrideLeaseReceipt(phase: phase, binding: journal.binding)
    }

    func releasedReceipt(
        for stored: SleepOverrideLeaseStoredReceipt
    ) -> SleepOverrideLeaseReceipt {
        SleepOverrideLeaseReceipt(phase: .released, binding: stored.binding)
    }

    func observe(
        _ point: SleepOverrideLeaseTransitionPoint,
        journal: SleepOverrideLeaseJournal
    ) async {
        await transitionObserver.observe(
            SleepOverrideLeaseTransition(
                point: point,
                binding: journal.binding,
                revision: journal.revision
            )
        )
    }
}

private extension SleepOverrideLeaseService {
    func scheduleRetry(for journal: SleepOverrideLeaseJournal) {
        cancelScheduledRetry(for: journal.binding)
        let token = UUID()
        let delay = retryDelay(afterFailureCount: journal.cleanupAttempt)
        let clock = self.clock
        let binding = journal.binding
        let task = Task { [weak self] in
            do {
                try await clock.sleep(for: delay)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            await self?.runScheduledRetry(binding: binding, token: token)
        }
        scheduledRetry = ScheduledRetry(token: token, binding: binding, task: task)
    }

    func runScheduledRetry(binding: SleepOverrideLeaseBinding, token: UUID) async {
        guard let scheduledRetry,
              scheduledRetry.token == token,
              scheduledRetry.binding == binding else { return }
        self.scheduledRetry = nil
        await lockOperation()
        defer { unlockOperation() }
        do {
            guard let journal = try await loadValidatedJournal(),
                  journal.binding == binding,
                  journal.phase == .cleanupRequired else { return }
            _ = try await restoreAndRelease(journal)
        } catch {
            // The last durable cleanup state remains authoritative.
        }
    }

    func cancelScheduledRetry(for binding: SleepOverrideLeaseBinding) {
        guard scheduledRetry?.binding == binding else { return }
        scheduledRetry?.task.cancel()
        scheduledRetry = nil
    }

    func retryDelay(afterFailureCount count: Int) -> Duration {
        switch count {
        case ...1:
            .milliseconds(250)
        case 2:
            .milliseconds(500)
        case 3:
            .seconds(1)
        default:
            .seconds(2)
        }
    }
}

private extension SleepOverrideLeaseService {
    func validate(
        sessionID: String,
        requestID: String,
        context: SleepOverrideLeaseCallContext
    ) throws {
        try validateIdentifier(sessionID, label: "session ID")
        try validateIdentifier(requestID, label: "request ID")
        try validate(context: context)
    }

    func validate(
        binding: SleepOverrideLeaseBinding,
        context: SleepOverrideLeaseCallContext
    ) throws {
        try validateIdentifier(binding.sessionID, label: "session ID")
        try validateIdentifier(binding.requestID, label: "request ID")
        try validateIdentifier(binding.leaseID, label: "lease ID")
        try validateIdentifier(binding.generation, label: "generation")
        try validate(context: context)
    }

    func validate(context: SleepOverrideLeaseCallContext) throws {
        try validateIdentifier(context.principal.bundleIdentifier, label: "bundle identifier")
        try validateIdentifier(context.principal.teamIdentifier, label: "team identifier")
        try validateIdentifier(context.connectionID.rawValue, label: "connection ID")
    }

    func validateIdentifier(_ value: String, label: String) throws {
        guard !value.isEmpty, value.utf8.count <= 1_024 else {
            throw SleepOverrideLeaseError.rejected("The \(label) is invalid.")
        }
    }

    func validate(
        principal: SleepOverrideLeaseCallerPrincipal,
        owns journal: SleepOverrideLeaseJournal
    ) throws {
        guard principal == journal.principal else {
            throw SleepOverrideLeaseError.rejected("The caller does not own this lease.")
        }
    }

    func validate(
        principal: SleepOverrideLeaseCallerPrincipal,
        owns receipt: SleepOverrideLeaseStoredReceipt
    ) throws {
        guard principal == receipt.principal else {
            throw SleepOverrideLeaseError.rejected("The caller does not own this receipt.")
        }
    }
}

private extension SleepOverrideLeaseService {
    func lockOperation() async {
        if !operationLocked {
            operationLocked = true
            return
        }
        await withCheckedContinuation { continuation in
            operationWaiters.append(continuation)
        }
    }

    func unlockOperation() {
        guard !operationWaiters.isEmpty else {
            operationLocked = false
            return
        }
        let continuation = operationWaiters.removeFirst()
        continuation.resume()
    }
}
