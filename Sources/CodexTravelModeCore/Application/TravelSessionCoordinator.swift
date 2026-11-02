import Foundation
import CodexTravelModeSleepLease

public struct TravelSessionConfiguration: Equatable, Sendable {
    public var wifiDevice: String

    public init(wifiDevice: String) {
        self.wifiDevice = wifiDevice.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

public protocol TravelSessionManaging: Sendable {
    func start(configuration: TravelSessionConfiguration) async -> TravelSessionTransitionResult
    func stop() async -> TravelSessionTransitionResult
    func requestQuit() async -> TravelSessionTransitionResult
    func recover() async -> TravelSessionTransitionResult
    func lifecycle() async -> TravelSessionLifecycle
    func protectionEvents() async -> AsyncStream<SleepOverrideLeaseProtectionEvent>
    func setWiFiPower(device: String, enabled: Bool) async -> CommandResult
    func associate(device: String, ssid: String, password: String?) async -> CommandResult
    func associate(
        device: String,
        ssid: String,
        password: String?,
        timeout: Duration
    ) async -> CommandResult
    func setWiFiPower(
        expectedSessionID: String,
        device: String,
        enabled: Bool,
        timeout: Duration
    ) async -> CommandResult
    func associate(
        expectedSessionID: String,
        device: String,
        ssid: String,
        password: String?,
        timeout: Duration
    ) async -> CommandResult
    func authorizeHandoffEpisode(_ token: HandoffEpisodeToken) async -> CommandResult
    func finishHandoffEpisode(_ token: HandoffEpisodeToken) async
    func cancelHandoffEpisode(_ token: HandoffEpisodeToken) async
    func setWiFiPower(
        operation: HandoffOperationIdentity,
        device: String,
        enabled: Bool,
        timeout: Duration
    ) async -> CommandResult
    func associate(
        operation: HandoffOperationIdentity,
        device: String,
        ssid: String,
        password: String?,
        timeout: Duration
    ) async -> CommandResult
}

public extension TravelSessionManaging {
    func protectionEvents() async -> AsyncStream<SleepOverrideLeaseProtectionEvent> {
        AsyncStream { continuation in
            continuation.finish()
        }
    }

    func associate(
        device: String,
        ssid: String,
        password: String?,
        timeout: Duration
    ) async -> CommandResult {
        await associate(device: device, ssid: ssid, password: password)
    }

    func setWiFiPower(
        expectedSessionID: String,
        device: String,
        enabled: Bool,
        timeout: Duration
    ) async -> CommandResult {
        await setWiFiPower(device: device, enabled: enabled)
    }

    func associate(
        expectedSessionID: String,
        device: String,
        ssid: String,
        password: String?,
        timeout: Duration
    ) async -> CommandResult {
        await associate(device: device, ssid: ssid, password: password, timeout: timeout)
    }

    func authorizeHandoffEpisode(_ token: HandoffEpisodeToken) async -> CommandResult {
        CommandResult(exitCode: 0)
    }

    func finishHandoffEpisode(_ token: HandoffEpisodeToken) async {}

    func cancelHandoffEpisode(_ token: HandoffEpisodeToken) async {}

    func setWiFiPower(
        operation: HandoffOperationIdentity,
        device: String,
        enabled: Bool,
        timeout: Duration
    ) async -> CommandResult {
        await setWiFiPower(
            expectedSessionID: operation.episode.sessionID,
            device: device,
            enabled: enabled,
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
        await associate(
            expectedSessionID: operation.episode.sessionID,
            device: device,
            ssid: ssid,
            password: password,
            timeout: timeout
        )
    }
}

private struct RuntimeMutationCommandFailure: LocalizedError, Sendable {
    let result: CommandResult

    var errorDescription: String? {
        result.detail
    }
}

public actor TravelSessionCoordinator: TravelSessionManaging {
    private typealias TransitionTask = Task<TravelSessionTransitionResult, Never>
    private typealias CommandTask = Task<CommandResult, Never>

    private struct RuntimeMutationSlot {
        var id: UUID
        var sessionID: String?
        var handoffOperation: HandoffOperationIdentity?
        var task: CommandTask
    }

    private let journalStore: any TravelSessionJournalStoring
    private let system: any TravelSessionSystemControlling
    private let leaseClient: any SleepOverrideLeaseClient
    private let observer: any TravelSessionBoundaryObserving
    private let associationRestoreTimeout: Duration
    private var activationTask: (id: UUID, task: TransitionTask)?
    private var activationCandidateSessionID: String?
    private var activationSessionID: String?
    private var authorizedHandoffEpisode: HandoffEpisodeToken?
    private var authorizedHandoffAttempt: Int?
    private var runtimeMutationTask: RuntimeMutationSlot?
    private var cleanupTask: (id: UUID, task: TransitionTask)?
    private var cleanupRequestCount = 0

    public init(
        journalStore: any TravelSessionJournalStoring,
        system: any TravelSessionSystemControlling,
        leaseClient: any SleepOverrideLeaseClient,
        observer: any TravelSessionBoundaryObserving = NoOpTravelSessionBoundaryObserver(),
        associationRestoreTimeout: Duration = .seconds(10)
    ) {
        self.journalStore = journalStore
        self.system = system
        self.leaseClient = leaseClient
        self.observer = observer
        self.associationRestoreTimeout = associationRestoreTimeout
    }

    public func start(
        configuration: TravelSessionConfiguration
    ) async -> TravelSessionTransitionResult {
        if cleanupRequestCount > 0 || cleanupTask != nil {
            let sessionID = try? await journalStore.load()?.sessionID
            await observer.reached(
                .startRejectedExistingRecovery,
                sessionID: sessionID,
                value: nil
            )
            return TravelSessionTransitionResult(
                lifecycle: .cleanupRequired,
                error: "Previous Travel Mode cleanup must finish before Start."
            )
        }
        guard activationTask == nil, runtimeMutationTask == nil else {
            return TravelSessionTransitionResult(
                lifecycle: .preparing,
                error: "Travel Mode activation is already in progress."
            )
        }

        let id = UUID()
        let task = Task { await self.performStart(configuration: configuration) }
        activationTask = (id, task)
        let result = await task.value
        if activationTask?.id == id {
            activationTask = nil
            activationCandidateSessionID = nil
            activationSessionID = nil
        }
        return result
    }

    public func stop() async -> TravelSessionTransitionResult {
        cleanupRequestCount += 1
        defer { cleanupRequestCount -= 1 }
        authorizedHandoffEpisode = nil
        authorizedHandoffAttempt = nil
        await cancelActivation(recordTermination: false)
        await cancelRuntimeMutation()
        return await beginCleanup()
    }

    public func requestQuit() async -> TravelSessionTransitionResult {
        cleanupRequestCount += 1
        defer { cleanupRequestCount -= 1 }
        let inFlightSessionID = activationSessionID
            ?? activationCandidateSessionID
            ?? runtimeMutationTask?.sessionID
        let hasUnidentifiedWork = (activationTask != nil || runtimeMutationTask != nil)
            && inFlightSessionID == nil
        if !hasUnidentifiedWork {
            await markTerminationRequested(expectedSessionID: inFlightSessionID)
        }
        authorizedHandoffEpisode = nil
        authorizedHandoffAttempt = nil
        await cancelActivation(recordTermination: false)
        await cancelRuntimeMutation()
        await markTerminationRequested(expectedSessionID: inFlightSessionID)
        return await beginCleanup()
    }

    public func recover() async -> TravelSessionTransitionResult {
        guard activationTask == nil else {
            return TravelSessionTransitionResult(
                lifecycle: .preparing,
                error: "Travel Mode activation is still in progress."
            )
        }
        cleanupRequestCount += 1
        defer { cleanupRequestCount -= 1 }
        authorizedHandoffEpisode = nil
        authorizedHandoffAttempt = nil
        await cancelRuntimeMutation()
        return await beginCleanup()
    }

    public func lifecycle() async -> TravelSessionLifecycle {
        do {
            return try await journalStore.load()?.phase ?? .off
        } catch {
            return .cleanupRequired
        }
    }

    public func protectionEvents() async -> AsyncStream<SleepOverrideLeaseProtectionEvent> {
        leaseClient.protectionEvents()
    }

    public func authorizeHandoffEpisode(
        _ token: HandoffEpisodeToken
    ) async -> CommandResult {
        do {
            try validateTokenShape(token)
            try Task.checkCancellation()
            guard cleanupTask == nil, cleanupRequestCount == 0,
                  runtimeMutationTask == nil else {
                return staleHandoffResult("Another session transition is in progress.")
            }
            guard authorizedHandoffEpisode == nil || authorizedHandoffEpisode == token else {
                return staleHandoffResult("A different internet-handoff episode owns the session.")
            }
            guard let journal = try await journalStore.load() else {
                return staleHandoffResult("The Travel Mode session is unavailable.")
            }
            try Task.checkCancellation()
            guard cleanupTask == nil, cleanupRequestCount == 0,
                  runtimeMutationTask == nil,
                  authorizedHandoffEpisode == nil || authorizedHandoffEpisode == token,
                  journal.sessionID == token.sessionID,
                  journal.phase == .active else {
                return staleHandoffResult("The internet-handoff episode is stale.")
            }
            if authorizedHandoffEpisode == nil {
                authorizedHandoffEpisode = token
                authorizedHandoffAttempt = nil
            }
            return CommandResult(exitCode: 0)
        } catch is CancellationError {
            return CommandResult(
                exitCode: 130,
                standardError: "Internet-handoff authorization was cancelled.",
                failureCategory: .cancelled
            )
        } catch {
            return staleHandoffResult(error.localizedDescription)
        }
    }

    public func finishHandoffEpisode(_ token: HandoffEpisodeToken) async {
        guard authorizedHandoffEpisode == token
                || runtimeMutationTask?.handoffOperation?.episode == token else { return }
        if authorizedHandoffEpisode == token {
            authorizedHandoffEpisode = nil
            authorizedHandoffAttempt = nil
        }
        await cancelRuntimeMutation(ownedBy: token)
    }

    public func cancelHandoffEpisode(_ token: HandoffEpisodeToken) async {
        guard authorizedHandoffEpisode == token
                || runtimeMutationTask?.handoffOperation?.episode == token else { return }
        if authorizedHandoffEpisode == token {
            authorizedHandoffEpisode = nil
            authorizedHandoffAttempt = nil
        }
        await cancelRuntimeMutation(ownedBy: token)
    }

    public func setWiFiPower(device: String, enabled: Bool) async -> CommandResult {
        await beginRuntimePowerMutation(
            expectedSessionID: nil,
            handoffOperation: nil,
            device: device,
            enabled: enabled,
            timeout: nil
        )
    }

    public func setWiFiPower(
        expectedSessionID: String,
        device: String,
        enabled: Bool,
        timeout: Duration
    ) async -> CommandResult {
        guard !expectedSessionID.isEmpty else {
            return CommandResult(exitCode: 1, standardError: "Travel Mode session ID is required.")
        }
        return await beginRuntimePowerMutation(
            expectedSessionID: expectedSessionID,
            handoffOperation: nil,
            device: device,
            enabled: enabled,
            timeout: timeout
        )
    }

    public func associate(
        device: String,
        ssid: String,
        password: String?
    ) async -> CommandResult {
        await beginRuntimeAssociation(
            expectedSessionID: nil,
            handoffOperation: nil,
            device: device,
            ssid: ssid,
            password: password,
            timeout: nil
        )
    }

    public func associate(
        device: String,
        ssid: String,
        password: String?,
        timeout: Duration
    ) async -> CommandResult {
        await beginRuntimeAssociation(
            expectedSessionID: nil,
            handoffOperation: nil,
            device: device,
            ssid: ssid,
            password: password,
            timeout: timeout
        )
    }

    public func associate(
        expectedSessionID: String,
        device: String,
        ssid: String,
        password: String?,
        timeout: Duration
    ) async -> CommandResult {
        guard !expectedSessionID.isEmpty else {
            return CommandResult(exitCode: 1, standardError: "Travel Mode session ID is required.")
        }
        return await beginRuntimeAssociation(
            expectedSessionID: expectedSessionID,
            handoffOperation: nil,
            device: device,
            ssid: ssid,
            password: password,
            timeout: timeout
        )
    }

    public func setWiFiPower(
        operation: HandoffOperationIdentity,
        device: String,
        enabled: Bool,
        timeout: Duration
    ) async -> CommandResult {
        await beginRuntimePowerMutation(
            expectedSessionID: operation.episode.sessionID,
            handoffOperation: operation,
            device: device,
            enabled: enabled,
            timeout: timeout
        )
    }

    public func associate(
        operation: HandoffOperationIdentity,
        device: String,
        ssid: String,
        password: String?,
        timeout: Duration
    ) async -> CommandResult {
        await beginRuntimeAssociation(
            expectedSessionID: operation.episode.sessionID,
            handoffOperation: operation,
            device: device,
            ssid: ssid,
            password: password,
            timeout: timeout
        )
    }
}

private extension TravelSessionCoordinator {
    func beginRuntimePowerMutation(
        expectedSessionID: String?,
        handoffOperation: HandoffOperationIdentity?,
        device: String,
        enabled: Bool,
        timeout: Duration?
    ) async -> CommandResult {
        guard runtimeMutationTask == nil,
              cleanupTask == nil,
              cleanupRequestCount == 0 else {
            return CommandResult(exitCode: 1, standardError: "Another session transition is in progress.")
        }
        if let handoffOperation {
            do {
                try claimAuthorizedOperation(handoffOperation)
            } catch {
                return staleHandoffResult(error.localizedDescription)
            }
        }
        let id = UUID()
        let task = Task {
            await self.performRuntimePowerMutation(
                id: id,
                expectedSessionID: expectedSessionID,
                handoffOperation: handoffOperation,
                device: device,
                enabled: enabled,
                timeout: timeout
            )
        }
        runtimeMutationTask = RuntimeMutationSlot(
            id: id,
            sessionID: expectedSessionID,
            handoffOperation: handoffOperation,
            task: task
        )
        let result = await task.value
        clearRuntimeMutation(id: id)
        return result
    }

    func beginRuntimeAssociation(
        expectedSessionID: String?,
        handoffOperation: HandoffOperationIdentity?,
        device: String,
        ssid: String,
        password: String?,
        timeout: Duration?
    ) async -> CommandResult {
        guard runtimeMutationTask == nil,
              cleanupTask == nil,
              cleanupRequestCount == 0 else {
            return CommandResult(exitCode: 1, standardError: "Another session transition is in progress.")
        }
        if let handoffOperation {
            do {
                try claimAuthorizedOperation(handoffOperation)
            } catch {
                return staleHandoffResult(error.localizedDescription)
            }
        }
        let id = UUID()
        let task = Task {
            await self.performRuntimeAssociation(
                id: id,
                expectedSessionID: expectedSessionID,
                handoffOperation: handoffOperation,
                device: device,
                ssid: ssid,
                password: password,
                timeout: timeout
            )
        }
        runtimeMutationTask = RuntimeMutationSlot(
            id: id,
            sessionID: expectedSessionID,
            handoffOperation: handoffOperation,
            task: task
        )
        let result = await task.value
        clearRuntimeMutation(id: id)
        return result
    }
}

private extension TravelSessionCoordinator {
    func performRuntimePowerMutation(
        id: UUID,
        expectedSessionID: String?,
        handoffOperation: HandoffOperationIdentity?,
        device: String,
        enabled: Bool,
        timeout: Duration?
    ) async -> CommandResult {
        var ownedSessionID: String?
        do {
            try Task.checkCancellation()
            let journal = try await requireActiveJournal(
                device: device,
                expectedSessionID: expectedSessionID,
                observesCancellation: true,
                handoffOperation: handoffOperation
            )
            ownedSessionID = journal.sessionID
            assignRuntimeSession(id: id, sessionID: journal.sessionID)
            try Task.checkCancellation()
            let (_, result) = try await mutateWiFiPower(
                journal: journal,
                target: enabled,
                observesCancellation: true,
                expectedSessionID: journal.sessionID,
                handoffOperation: handoffOperation,
                timeout: timeout
            )
            return result
        } catch let failure as RuntimeMutationCommandFailure {
            if handoffOperation != nil, let ownedSessionID {
                await reconcileHandoffFailure(failure, expectedSessionID: ownedSessionID)
            } else {
                await retainFailure(failure, expectedSessionID: ownedSessionID)
            }
            return failure.result
        } catch TravelSessionJournalError.staleSession {
            return CommandResult(
                exitCode: 1,
                standardError: TravelSessionJournalError.staleSession.localizedDescription,
                failureCategory: .staleSession
            )
        } catch is CancellationError {
            if handoffOperation != nil, let ownedSessionID {
                await reconcileHandoffFailure(
                    CancellationError(),
                    expectedSessionID: ownedSessionID
                )
            }
            return CommandResult(
                exitCode: 130,
                standardError: "The session-bound Wi-Fi power command was cancelled.",
                failureCategory: .cancelled
            )
        } catch {
            if handoffOperation != nil, let ownedSessionID {
                await reconcileHandoffFailure(error, expectedSessionID: ownedSessionID)
            } else {
                await retainFailure(error, expectedSessionID: ownedSessionID)
            }
            return CommandResult(exitCode: 1, standardError: error.localizedDescription)
        }
    }

    func performRuntimeAssociation(
        id: UUID,
        expectedSessionID: String?,
        handoffOperation: HandoffOperationIdentity?,
        device: String,
        ssid: String,
        password: String?,
        timeout: Duration?
    ) async -> CommandResult {
        var ownedSessionID: String?
        do {
            try Task.checkCancellation()
            let journal = try await requireActiveJournal(
                device: device,
                expectedSessionID: expectedSessionID,
                observesCancellation: true,
                handoffOperation: handoffOperation
            )
            ownedSessionID = journal.sessionID
            assignRuntimeSession(id: id, sessionID: journal.sessionID)
            try Task.checkCancellation()
            let (_, result) = try await mutateAssociation(
                journal: journal,
                target: ssid,
                password: password,
                observesCancellation: true,
                timeout: timeout,
                expectedSessionID: journal.sessionID,
                handoffOperation: handoffOperation
            )
            return result
        } catch let failure as RuntimeMutationCommandFailure {
            if handoffOperation != nil, let ownedSessionID {
                await reconcileHandoffFailure(failure, expectedSessionID: ownedSessionID)
            } else {
                await retainFailure(failure, expectedSessionID: ownedSessionID)
            }
            return failure.result
        } catch TravelSessionJournalError.staleSession {
            return CommandResult(
                exitCode: 1,
                standardError: TravelSessionJournalError.staleSession.localizedDescription,
                failureCategory: .staleSession
            )
        } catch is CancellationError {
            if handoffOperation != nil, let ownedSessionID {
                await reconcileHandoffFailure(
                    CancellationError(),
                    expectedSessionID: ownedSessionID
                )
            }
            return CommandResult(
                exitCode: 130,
                standardError: "The session-bound Wi-Fi association was cancelled.",
                failureCategory: .cancelled
            )
        } catch {
            if handoffOperation != nil, let ownedSessionID {
                await reconcileHandoffFailure(error, expectedSessionID: ownedSessionID)
            } else {
                await retainFailure(error, expectedSessionID: ownedSessionID)
            }
            return CommandResult(exitCode: 1, standardError: error.localizedDescription)
        }
    }

    func assignRuntimeSession(id: UUID, sessionID: String) {
        guard var slot = runtimeMutationTask, slot.id == id else { return }
        slot.sessionID = sessionID
        runtimeMutationTask = slot
    }

    func clearRuntimeMutation(id: UUID) {
        guard runtimeMutationTask?.id == id else { return }
        runtimeMutationTask = nil
    }

    func cancelRuntimeMutation() async {
        guard let slot = runtimeMutationTask else { return }
        slot.task.cancel()
        _ = await slot.task.value
        clearRuntimeMutation(id: slot.id)
    }

    func cancelRuntimeMutation(ownedBy token: HandoffEpisodeToken) async {
        guard let slot = runtimeMutationTask,
              slot.handoffOperation?.episode == token else { return }
        slot.task.cancel()
        _ = await slot.task.value
        clearRuntimeMutation(id: slot.id)
    }

    func validateTokenShape(_ token: HandoffEpisodeToken) throws {
        guard !token.sessionID.isEmpty, !token.episodeID.isEmpty else {
            throw TravelSessionJournalError.staleSession
        }
    }

    func validateAuthorizedOperation(_ operation: HandoffOperationIdentity) throws {
        try Task.checkCancellation()
        try validateTokenShape(operation.episode)
        guard operation.attempt > 0,
              authorizedHandoffEpisode == operation.episode,
              authorizedHandoffAttempt == operation.attempt else {
            throw TravelSessionJournalError.staleSession
        }
    }

    func claimAuthorizedOperation(_ operation: HandoffOperationIdentity) throws {
        try Task.checkCancellation()
        try validateTokenShape(operation.episode)
        guard operation.attempt > 0,
              authorizedHandoffEpisode == operation.episode else {
            throw TravelSessionJournalError.staleSession
        }
        if let authorizedHandoffAttempt,
           operation.attempt < authorizedHandoffAttempt {
            throw TravelSessionJournalError.staleSession
        }
        authorizedHandoffAttempt = operation.attempt
    }

    func staleHandoffResult(_ detail: String) -> CommandResult {
        CommandResult(
            exitCode: 1,
            standardError: detail,
            failureCategory: .staleSession
        )
    }

    func reconcileHandoffFailure(
        _ originalError: Error,
        expectedSessionID: String
    ) async {
        let journalStore = self.journalStore
        let system = self.system
        let reconciliation = Task.detached {
            try await Self.reconcileHandoffMutation(
                expectedSessionID: expectedSessionID,
                journalStore: journalStore,
                system: system
            )
        }
        do {
            _ = try await reconciliation.value
        } catch {
            let uncertainty = TravelSessionSystemError.verificationFailed(
                "\(originalError.localizedDescription) Reconciliation failed: \(error.localizedDescription)"
            )
            await retainFailure(uncertainty, expectedSessionID: expectedSessionID)
        }
    }

    nonisolated static func reconcileHandoffMutation(
        expectedSessionID: String,
        journalStore: any TravelSessionJournalStoring,
        system: any TravelSessionSystemControlling
    ) async throws -> TravelSessionJournal {
        guard let journal = try await journalStore.load(),
              journal.sessionID == expectedSessionID else {
            throw TravelSessionJournalError.staleSession
        }
        guard journal.phase == .active else {
            throw TravelSessionSystemError.stateUnavailable(
                "The matching Travel Mode session is no longer active."
            )
        }
        guard let intent = journal.pendingMutation else { return journal }

        var reconciled = journal
        switch intent.kind {
        case .wifiPower:
            guard let baseline = Bool(intent.baseline),
                  let target = Bool(intent.target) else {
                throw TravelSessionSystemError.verificationFailed(
                    "The pending Wi-Fi power intent is invalid."
                )
            }
            let observed = try await system.currentWiFiPower(
                device: journal.wifiBaseline.device,
                timeout: .seconds(2)
            )
            guard observed == baseline || observed == target else {
                throw TravelSessionSystemError.verificationFailed(
                    "Wi-Fi power readback matches neither the pending baseline nor target."
                )
            }
            reconciled.pendingMutation = nil
            reconciled.changedWiFiPower = observed != journal.wifiBaseline.powerEnabled
        case .association:
            let baseline = intent.baseline.isEmpty ? nil : intent.baseline
            let target = intent.target.isEmpty ? nil : intent.target
            let observed = try await system.currentAssociatedSSID(
                device: journal.wifiBaseline.device,
                timeout: .seconds(2)
            )
            guard exactSSIDEqual(observed, baseline) || exactSSIDEqual(observed, target) else {
                throw TravelSessionSystemError.verificationFailed(
                    "Wi-Fi association readback matches neither the pending baseline nor target."
                )
            }
            reconciled.pendingMutation = nil
            reconciled.changedAssociation = !exactSSIDEqual(
                observed,
                journal.wifiBaseline.associatedSSID
            )
        }
        return try await journalStore.update(
            reconciled,
            expectedRevision: journal.revision
        )
    }
}

private extension TravelSessionCoordinator {
    func performStart(
        configuration: TravelSessionConfiguration
    ) async -> TravelSessionTransitionResult {
        var expectedSessionID: String?
        do {
            guard !configuration.wifiDevice.isEmpty else {
                throw TravelSessionSystemError.stateUnavailable("Wi-Fi device is empty.")
            }
            if let existing = try await journalStore.load() {
                await observer.reached(
                    .startRejectedExistingRecovery,
                    sessionID: existing.sessionID,
                    value: nil
                )
                return TravelSessionTransitionResult(
                    lifecycle: .cleanupRequired,
                    error: "Previous Travel Mode cleanup must finish before Start."
                )
            }

            let baseline = try await captureBaseline(device: configuration.wifiDevice)
            try Task.checkCancellation()
            let candidate = TravelSessionJournal(wifiBaseline: baseline)
            expectedSessionID = candidate.sessionID
            activationCandidateSessionID = candidate.sessionID
            var journal = try await journalStore.create(candidate)
            activationCandidateSessionID = nil
            activationSessionID = journal.sessionID
            try Task.checkCancellation()
            journal = try await acquireLease(for: journal)
            try Task.checkCancellation()
            if !baseline.powerEnabled {
                (journal, _) = try await mutateWiFiPower(
                    journal: journal,
                    target: true,
                    observesCancellation: true
                )
            }
            try Task.checkCancellation()
            journal = try await update(journal) { $0.phase = .active }
            await observer.reached(.sessionActive, sessionID: journal.sessionID, value: nil)
            return TravelSessionTransitionResult(
                lifecycle: .active,
                sessionID: journal.sessionID,
                canTerminate: false
            )
        } catch {
            return await transitionFailure(error, expectedSessionID: expectedSessionID)
        }
    }

    func captureBaseline(device: String) async throws -> TravelWiFiBaseline {
        async let power = system.currentWiFiPower(device: device)
        async let ssid = system.currentAssociatedSSID(device: device)
        return try await TravelWiFiBaseline(
            device: device,
            powerEnabled: power,
            associatedSSID: ssid
        )
    }

    func acquireLease(for journal: TravelSessionJournal) async throws -> TravelSessionJournal {
        let receipt = try await leaseClient.acquire(
            sessionID: journal.sessionID,
            requestID: journal.leaseRequestID
        )
        try validate(receipt, journal: journal, requiredPhase: .active)
        await observer.reached(
            .leaseReceiptReturned,
            sessionID: journal.sessionID,
            value: receipt.binding.leaseID
        )
        let updated = try await update(journal) {
            $0.leaseBinding = receipt.binding
            $0.leaseStatus = .active
        }
        await observer.reached(.leaseAcquired, sessionID: journal.sessionID, value: nil)
        return updated
    }

    func transitionFailure(
        _ error: Error,
        expectedSessionID: String?
    ) async -> TravelSessionTransitionResult {
        guard let expectedSessionID else {
            return TravelSessionTransitionResult(lifecycle: .off, error: error.localizedDescription)
        }
        let journal: TravelSessionJournal?
        do {
            journal = try await journalStore.load()
        } catch {
            return TravelSessionTransitionResult(
                lifecycle: .cleanupRequired,
                error: error.localizedDescription,
                canTerminate: false
            )
        }
        guard let journal else {
            return TravelSessionTransitionResult(
                lifecycle: .off,
                error: error.localizedDescription
            )
        }
        guard journal.sessionID == expectedSessionID else {
            return TravelSessionTransitionResult(
                lifecycle: .cleanupRequired,
                error: error.localizedDescription,
                canTerminate: false
            )
        }
        if let leaseError = error as? SleepOverrideLeaseError,
           leaseError.isDefinitivePreDispatchFailure,
           journal.leaseBinding == nil,
           journal.pendingMutation == nil,
           !journal.changedWiFiPower,
           !journal.changedAssociation {
            do {
                try await journalStore.clear(
                    sessionID: journal.sessionID,
                    expectedRevision: journal.revision
                )
                await observer.reached(.journalCleared, sessionID: journal.sessionID, value: nil)
                return TravelSessionTransitionResult(
                    lifecycle: .off,
                    error: error.localizedDescription
                )
            } catch {
                return TravelSessionTransitionResult(
                    lifecycle: .cleanupRequired,
                    error: error.localizedDescription,
                    canTerminate: false
                )
            }
        }
        let retained = await retainFailure(error, journal: journal)
        return TravelSessionTransitionResult(
            lifecycle: retained?.phase ?? .cleanupRequired,
            error: error.localizedDescription,
            canTerminate: false
        )
    }

    func requireActiveJournal(
        device: String,
        expectedSessionID: String?,
        observesCancellation: Bool,
        handoffOperation: HandoffOperationIdentity? = nil
    ) async throws -> TravelSessionJournal {
        if observesCancellation {
            try Task.checkCancellation()
        }
        if let handoffOperation {
            try validateAuthorizedOperation(handoffOperation)
        }
        guard let journal = try await journalStore.load() else {
            throw TravelSessionJournalError.missing
        }
        if observesCancellation {
            try Task.checkCancellation()
            guard cleanupTask == nil, cleanupRequestCount == 0 else {
                throw CancellationError()
            }
        }
        if let handoffOperation {
            try validateAuthorizedOperation(handoffOperation)
        }
        if let expectedSessionID {
            guard !expectedSessionID.isEmpty else {
                throw TravelSessionSystemError.stateUnavailable(
                    "Travel Mode session ID is required."
                )
            }
            guard journal.sessionID == expectedSessionID else {
                throw TravelSessionJournalError.staleSession
            }
        }
        guard journal.phase == .active, journal.wifiBaseline.device == device else {
            throw TravelSessionSystemError.stateUnavailable("No matching active Travel Mode session.")
        }
        return journal
    }

    func validateRuntimeMutation(
        sessionID: String,
        device: String,
        handoffOperation: HandoffOperationIdentity? = nil
    ) async throws -> TravelSessionJournal {
        try Task.checkCancellation()
        if let handoffOperation {
            try validateAuthorizedOperation(handoffOperation)
        }
        guard cleanupTask == nil, cleanupRequestCount == 0 else {
            throw CancellationError()
        }
        guard let journal = try await journalStore.load() else {
            throw TravelSessionJournalError.missing
        }
        try Task.checkCancellation()
        if let handoffOperation {
            try validateAuthorizedOperation(handoffOperation)
        }
        guard cleanupTask == nil, cleanupRequestCount == 0 else {
            throw CancellationError()
        }
        guard journal.sessionID == sessionID else {
            throw TravelSessionJournalError.staleSession
        }
        guard journal.phase == .active, journal.wifiBaseline.device == device else {
            throw TravelSessionSystemError.stateUnavailable("No matching active Travel Mode session.")
        }
        return journal
    }
}

private extension TravelSessionCoordinator {
    func mutateWiFiPower(
        journal: TravelSessionJournal,
        target: Bool,
        observesCancellation: Bool,
        expectedSessionID: String? = nil,
        handoffOperation: HandoffOperationIdentity? = nil,
        timeout: Duration? = nil
    ) async throws -> (TravelSessionJournal, CommandResult) {
        let device = journal.wifiBaseline.device
        let deadline = runtimeMutationDeadline(timeout)
        let baseline = try await currentWiFiPower(device: device, deadline: deadline)
        try await validateMutationContinuation(
            observesCancellation: observesCancellation,
            expectedSessionID: expectedSessionID,
            handoffOperation: handoffOperation,
            device: device
        )
        if baseline == target {
            return (journal, CommandResult(exitCode: 0))
        }

        let intent = TravelSessionMutationIntent(
            kind: .wifiPower,
            baseline: String(baseline),
            target: String(target)
        )
        var current = try await update(journal) { $0.pendingMutation = intent }
        try await checkpoint(
            .afterIntentPersist,
            journal: current,
            cancellable: observesCancellation,
            expectedSessionID: expectedSessionID,
            handoffOperation: handoffOperation
        )

        try await validateMutationContinuation(
            observesCancellation: observesCancellation,
            expectedSessionID: expectedSessionID,
            handoffOperation: handoffOperation,
            device: device
        )
        let result = try await runPowerCommand(
            device: device,
            enabled: target,
            timeout: try remainingRuntimeMutationTime(deadline)
        )
        try await validateMutationContinuation(
            observesCancellation: observesCancellation,
            expectedSessionID: expectedSessionID,
            handoffOperation: handoffOperation,
            device: device
        )
        current = try await setPendingPhase(.dispatched, journal: current)
        try await checkpoint(
            .afterDispatch,
            journal: current,
            cancellable: observesCancellation,
            expectedSessionID: expectedSessionID,
            handoffOperation: handoffOperation
        )
        guard result.succeeded else {
            throw RuntimeMutationCommandFailure(result: result)
        }

        let observed = try await currentWiFiPower(device: device, deadline: deadline)
        try await validateMutationContinuation(
            observesCancellation: observesCancellation,
            expectedSessionID: expectedSessionID,
            handoffOperation: handoffOperation,
            device: device
        )
        guard observed == target else {
            throw TravelSessionSystemError.verificationFailed(
                "Wi-Fi power on \(device) is \(observed), expected \(target)."
            )
        }
        current = try await setPendingPhase(.verified, journal: current)
        try await checkpoint(
            .afterVerification,
            journal: current,
            cancellable: observesCancellation,
            expectedSessionID: expectedSessionID,
            handoffOperation: handoffOperation
        )
        try await checkpoint(
            .beforeCompletionPersist,
            journal: current,
            cancellable: observesCancellation,
            expectedSessionID: expectedSessionID,
            handoffOperation: handoffOperation
        )
        current = try await update(current) {
            $0.pendingMutation = nil
            $0.changedWiFiPower = target != $0.wifiBaseline.powerEnabled
        }
        try await validateMutationContinuation(
            observesCancellation: observesCancellation,
            expectedSessionID: expectedSessionID,
            handoffOperation: handoffOperation,
            device: device
        )
        return (current, result)
    }

    func mutateAssociation(
        journal: TravelSessionJournal,
        target: String,
        password: String?,
        observesCancellation: Bool,
        timeout: Duration? = nil,
        expectedSessionID: String? = nil,
        handoffOperation: HandoffOperationIdentity? = nil
    ) async throws -> (TravelSessionJournal, CommandResult) {
        let device = journal.wifiBaseline.device
        let deadline = runtimeMutationDeadline(timeout)
        let baseline = try await currentAssociatedSSID(device: device, deadline: deadline)
        try await validateMutationContinuation(
            observesCancellation: observesCancellation,
            expectedSessionID: expectedSessionID,
            handoffOperation: handoffOperation,
            device: device
        )
        if exactSSIDEqual(baseline, target) {
            return (journal, CommandResult(exitCode: 0))
        }

        let intent = TravelSessionMutationIntent(
            kind: .association,
            baseline: baseline ?? "",
            target: target
        )
        var current = try await update(journal) { $0.pendingMutation = intent }
        try await checkpoint(
            .afterIntentPersist,
            journal: current,
            cancellable: observesCancellation,
            expectedSessionID: expectedSessionID,
            handoffOperation: handoffOperation
        )

        try await validateMutationContinuation(
            observesCancellation: observesCancellation,
            expectedSessionID: expectedSessionID,
            handoffOperation: handoffOperation,
            device: device
        )
        let result: CommandResult
        if let boundedTimeout = try remainingRuntimeMutationTime(deadline) {
            result = await system.associate(
                device: device,
                ssid: target,
                password: password,
                timeout: boundedTimeout
            )
        } else {
            result = await system.associate(device: device, ssid: target, password: password)
        }
        try await validateMutationContinuation(
            observesCancellation: observesCancellation,
            expectedSessionID: expectedSessionID,
            handoffOperation: handoffOperation,
            device: device
        )
        current = try await setPendingPhase(.dispatched, journal: current)
        try await checkpoint(
            .afterDispatch,
            journal: current,
            cancellable: observesCancellation,
            expectedSessionID: expectedSessionID,
            handoffOperation: handoffOperation
        )
        guard result.succeeded else {
            throw RuntimeMutationCommandFailure(result: result)
        }

        let observed = try await currentAssociatedSSID(device: device, deadline: deadline)
        try await validateMutationContinuation(
            observesCancellation: observesCancellation,
            expectedSessionID: expectedSessionID,
            handoffOperation: handoffOperation,
            device: device
        )
        guard exactSSIDEqual(observed, target) else {
            throw TravelSessionSystemError.verificationFailed(
                "Wi-Fi association is '\(observed ?? "none")', expected '\(target)'."
            )
        }
        current = try await setPendingPhase(.verified, journal: current)
        try await checkpoint(
            .afterVerification,
            journal: current,
            cancellable: observesCancellation,
            expectedSessionID: expectedSessionID,
            handoffOperation: handoffOperation
        )
        try await checkpoint(
            .beforeCompletionPersist,
            journal: current,
            cancellable: observesCancellation,
            expectedSessionID: expectedSessionID,
            handoffOperation: handoffOperation
        )
        current = try await update(current) {
            $0.pendingMutation = nil
            $0.changedAssociation = !exactSSIDEqual(target, $0.wifiBaseline.associatedSSID)
        }
        try await validateMutationContinuation(
            observesCancellation: observesCancellation,
            expectedSessionID: expectedSessionID,
            handoffOperation: handoffOperation,
            device: device
        )
        return (current, result)
    }

    func setPendingPhase(
        _ phase: TravelSessionMutationPhase,
        journal: TravelSessionJournal
    ) async throws -> TravelSessionJournal {
        try await update(journal) { $0.pendingMutation?.phase = phase }
    }

    func checkpoint(
        _ boundary: TravelSessionBoundary,
        journal: TravelSessionJournal,
        cancellable: Bool,
        expectedSessionID: String? = nil,
        handoffOperation: HandoffOperationIdentity? = nil
    ) async throws {
        try await validateMutationContinuation(
            observesCancellation: cancellable,
            expectedSessionID: expectedSessionID,
            handoffOperation: handoffOperation,
            device: journal.wifiBaseline.device
        )
        await observer.reached(
            boundary,
            sessionID: journal.sessionID,
            value: journal.pendingMutation?.id
        )
        try await validateMutationContinuation(
            observesCancellation: cancellable,
            expectedSessionID: expectedSessionID,
            handoffOperation: handoffOperation,
            device: journal.wifiBaseline.device
        )
    }

    func validateMutationContinuation(
        observesCancellation: Bool,
        expectedSessionID: String?,
        handoffOperation: HandoffOperationIdentity? = nil,
        device: String
    ) async throws {
        guard let expectedSessionID else {
            if observesCancellation {
                try Task.checkCancellation()
            }
            return
        }
        _ = try await validateRuntimeMutation(
            sessionID: expectedSessionID,
            device: device,
            handoffOperation: handoffOperation
        )
    }

    func runtimeMutationDeadline(_ timeout: Duration?) -> ContinuousClock.Instant? {
        guard let timeout else { return nil }
        return ContinuousClock().now.advanced(by: timeout)
    }

    func remainingRuntimeMutationTime(
        _ deadline: ContinuousClock.Instant?,
        cappedAt cap: Duration? = nil
    ) throws -> Duration? {
        guard let deadline else { return nil }
        let remaining = ContinuousClock().now.duration(to: deadline)
        guard remaining > .zero else {
            throw TravelSessionSystemError.commandFailed(
                "The session-bound network operation timed out."
            )
        }
        return cap.map { min($0, remaining) } ?? remaining
    }

    func currentWiFiPower(
        device: String,
        deadline: ContinuousClock.Instant?
    ) async throws -> Bool {
        if let timeout = try remainingRuntimeMutationTime(deadline, cappedAt: .seconds(2)) {
            return try await system.currentWiFiPower(device: device, timeout: timeout)
        }
        return try await system.currentWiFiPower(device: device)
    }

    func currentAssociatedSSID(
        device: String,
        deadline: ContinuousClock.Instant?
    ) async throws -> String? {
        if let timeout = try remainingRuntimeMutationTime(deadline, cappedAt: .seconds(2)) {
            return try await system.currentAssociatedSSID(device: device, timeout: timeout)
        }
        return try await system.currentAssociatedSSID(device: device)
    }

    func runPowerCommand(
        device: String,
        enabled: Bool,
        timeout: Duration?
    ) async throws -> CommandResult {
        guard let timeout else {
            return await system.setWiFiPower(device: device, enabled: enabled)
        }
        guard timeout > .zero else {
            return CommandResult(
                exitCode: 124,
                standardError: "Wi-Fi power command timed out before dispatch.",
                failureCategory: .timedOut
            )
        }
        return await system.setWiFiPower(
            device: device,
            enabled: enabled,
            timeout: timeout
        )
    }
}

private func exactSSIDEqual(_ lhs: String?, _ rhs: String?) -> Bool {
    switch (lhs, rhs) {
    case (nil, nil):
        return true
    case (.some(let lhs), .some(let rhs)):
        return lhs.hasExactUTF8Representation(as: rhs)
    case (.some, nil), (nil, .some):
        return false
    }
}

private extension TravelSessionCoordinator {
    func performCleanup() async -> TravelSessionTransitionResult {
        var ownedSessionID: String?
        do {
            guard var journal = try await journalStore.load() else {
                return TravelSessionTransitionResult(lifecycle: .off)
            }
            ownedSessionID = journal.sessionID
            journal = try await update(journal) {
                $0.phase = .restoring
                $0.lastCleanupFailure = nil
            }
            journal = try await reconcilePendingMutation(journal)
            let association = await restoreAssociationIfNeeded(journal)
            journal = association.journal

            var failures: [String] = []
            do {
                journal = try await restorePowerIfNeeded(journal)
            } catch {
                failures.append(error.localizedDescription)
                journal = (try? await journalStore.load()) ?? journal
            }
            do {
                journal = try await releaseLeaseIfNeeded(journal)
            } catch {
                failures.append(error.localizedDescription)
                journal = (try? await journalStore.load()) ?? journal
            }
            guard failures.isEmpty else {
                return await cleanupFailure(
                    failures,
                    journal: journal,
                    expectedSessionID: ownedSessionID,
                    warning: association.warning
                )
            }
            try await journalStore.clear(
                sessionID: journal.sessionID,
                expectedRevision: journal.revision
            )
            await observer.reached(.journalCleared, sessionID: journal.sessionID, value: nil)
            let acknowledgementWarning = await acknowledgeReleasedLease(journal.leaseBinding)
            let warning = [association.warning, acknowledgementWarning]
                .compactMap { $0 }
                .joined(separator: " ")
            return TravelSessionTransitionResult(
                lifecycle: .off,
                warning: warning.isEmpty ? nil : warning
            )
        } catch {
            return await cleanupFailure(
                [error.localizedDescription],
                expectedSessionID: ownedSessionID
            )
        }
    }

    func reconcilePendingMutation(
        _ journal: TravelSessionJournal
    ) async throws -> TravelSessionJournal {
        guard let intent = journal.pendingMutation else { return journal }
        switch intent.kind {
        case .wifiPower:
            let observed = try await system.currentWiFiPower(device: journal.wifiBaseline.device)
            guard observed == Bool(intent.target) || observed == Bool(intent.baseline) else {
                throw TravelSessionSystemError.verificationFailed("Unrecognized Wi-Fi power state.")
            }
            return try await update(journal) {
                $0.pendingMutation = nil
                $0.changedWiFiPower = observed != $0.wifiBaseline.powerEnabled
            }
        case .association:
            let observed = try await system.currentAssociatedSSID(device: journal.wifiBaseline.device)
            return try await update(journal) {
                $0.pendingMutation = nil
                $0.changedAssociation = !exactSSIDEqual(observed, $0.wifiBaseline.associatedSSID)
            }
        }
    }

    func restoreAssociationIfNeeded(
        _ journal: TravelSessionJournal
    ) async -> (journal: TravelSessionJournal, warning: String?) {
        guard journal.changedAssociation,
              let prior = journal.wifiBaseline.associatedSSID,
              !prior.isEmpty else {
            return (journal, nil)
        }
        do {
            let (updated, _) = try await mutateAssociation(
                journal: journal,
                target: prior,
                password: nil,
                observesCancellation: false,
                timeout: associationRestoreTimeout
            )
            return (updated, nil)
        } catch {
            let latest = (try? await journalStore.load()) ?? journal
            let retired = (try? await update(latest) {
                $0.pendingMutation = nil
                $0.changedAssociation = false
            }) ?? latest
            return (
                retired,
                "Previous Wi-Fi network '\(prior)' was not restored: \(error.localizedDescription)"
            )
        }
    }

    func restorePowerIfNeeded(
        _ journal: TravelSessionJournal
    ) async throws -> TravelSessionJournal {
        guard journal.changedWiFiPower else { return journal }
        let (updated, _) = try await mutateWiFiPower(
            journal: journal,
            target: journal.wifiBaseline.powerEnabled,
            observesCancellation: false
        )
        return updated
    }
}

private extension TravelSessionCoordinator {
    func releaseLeaseIfNeeded(
        _ journal: TravelSessionJournal
    ) async throws -> TravelSessionJournal {
        var current = journal
        if current.leaseBinding == nil {
            let resolution = try await leaseClient.resolve(
                sessionID: current.sessionID,
                requestID: current.leaseRequestID
            )
            guard case .found(let receipt) = resolution else { return current }
            try validateResolved(receipt, journal: current)
            current = try await update(current) {
                $0.leaseBinding = receipt.binding
                $0.leaseStatus = receipt.phase
            }
        }
        guard let binding = current.leaseBinding else { return current }
        let released = try await leaseClient.release(binding: binding)
        try validate(released, journal: current, requiredPhase: .released)
        let status = try await leaseClient.status(binding: binding)
        try validate(status, journal: current, requiredPhase: .released)
        current = try await update(current) { $0.leaseStatus = .released }
        await observer.reached(.leaseReleased, sessionID: current.sessionID, value: nil)
        return current
    }

    func validateResolved(
        _ receipt: SleepOverrideLeaseReceipt,
        journal: TravelSessionJournal
    ) throws {
        try validate(receipt, journal: journal, requiredPhase: receipt.phase)
    }

    func acknowledgeReleasedLease(_ binding: SleepOverrideLeaseBinding?) async -> String? {
        guard let binding else { return nil }
        do {
            try await leaseClient.acknowledgeRelease(binding: binding)
            await observer.reached(.leaseAcknowledged, sessionID: binding.sessionID, value: nil)
            return nil
        } catch {
            return "The released helper receipt could not be acknowledged: \(error.localizedDescription)"
        }
    }

    func cleanupFailure(
        _ failures: [String],
        journal: TravelSessionJournal? = nil,
        expectedSessionID: String? = nil,
        warning: String? = nil
    ) async -> TravelSessionTransitionResult {
        let detail = failures.joined(separator: " ")
        let retainedJournal: TravelSessionJournal?
        if let journal {
            retainedJournal = journal
        } else {
            retainedJournal = try? await journalStore.load()
        }
        if let retainedJournal,
           expectedSessionID == nil || retainedJournal.sessionID == expectedSessionID {
            _ = await retainFailure(
                TravelSessionSystemError.verificationFailed(detail),
                journal: retainedJournal
            )
        }
        return TravelSessionTransitionResult(
            lifecycle: .cleanupRequired,
            warning: warning,
            error: detail,
            canTerminate: false
        )
    }

    func retainFailure(_ error: Error, expectedSessionID: String?) async {
        guard let expectedSessionID,
              let journal = try? await journalStore.load(),
              journal.sessionID == expectedSessionID else { return }
        _ = await retainFailure(error, journal: journal)
    }

    func retainFailure(
        _ error: Error,
        journal: TravelSessionJournal
    ) async -> TravelSessionJournal? {
        try? await update(journal) {
            $0.phase = .cleanupRequired
            $0.lastCleanupFailure = error.localizedDescription
        }
    }
}

private extension TravelSessionCoordinator {
    func cancelActivation(recordTermination: Bool) async {
        if recordTermination {
            await markTerminationRequested(
                expectedSessionID: activationSessionID ?? activationCandidateSessionID
            )
        }
        guard let activationTask else { return }
        activationTask.task.cancel()
        _ = await activationTask.task.value
        if self.activationTask?.id == activationTask.id {
            self.activationTask = nil
            activationCandidateSessionID = nil
            activationSessionID = nil
        }
    }

    func beginCleanup() async -> TravelSessionTransitionResult {
        if let cleanupTask {
            return await cleanupTask.task.value
        }
        let id = UUID()
        let task = Task { await self.performCleanup() }
        cleanupTask = (id, task)
        let result = await task.value
        if cleanupTask?.id == id {
            cleanupTask = nil
        }
        return result
    }

    func markTerminationRequested(expectedSessionID: String? = nil) async {
        for _ in 0..<3 {
            guard let journal = try? await journalStore.load() else { return }
            guard expectedSessionID == nil || journal.sessionID == expectedSessionID else {
                return
            }
            do {
                _ = try await update(journal) { $0.terminationRequested = true }
                return
            } catch TravelSessionJournalError.staleRevision {
                continue
            } catch {
                return
            }
        }
    }

    func update(
        _ journal: TravelSessionJournal,
        change: (inout TravelSessionJournal) -> Void
    ) async throws -> TravelSessionJournal {
        var candidate = journal
        change(&candidate)
        return try await journalStore.update(candidate, expectedRevision: journal.revision)
    }

    func validate(
        _ receipt: SleepOverrideLeaseReceipt,
        journal: TravelSessionJournal,
        requiredPhase: SleepOverrideLeasePhase
    ) throws {
        let binding = receipt.binding
        guard receipt.phase == requiredPhase,
              binding.sessionID == journal.sessionID,
              binding.requestID == journal.leaseRequestID,
              !binding.leaseID.isEmpty,
              !binding.generation.isEmpty else {
            throw SleepOverrideLeaseError.invalidReceipt
        }
        if let owned = journal.leaseBinding, owned != binding {
            throw SleepOverrideLeaseError.invalidReceipt
        }
    }
}
