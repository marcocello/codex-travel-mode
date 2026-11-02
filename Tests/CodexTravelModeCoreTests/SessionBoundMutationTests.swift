import CodexTravelModeCore
import XCTest

final class SessionBoundMutationTests: XCTestCase {
    func testSuccessfulStartReturnsPersistedSessionIdentifier() async throws {
        let store = SessionBoundJournalStore()
        let coordinator = makeCoordinator(store: store)

        let result = await coordinator.start(
            configuration: TravelSessionConfiguration(wifiDevice: "en0")
        )
        let loadedJournal = try await store.load()
        let journal = try XCTUnwrap(loadedJournal)

        XCTAssertEqual(result.lifecycle, .active)
        XCTAssertEqual(result.sessionID, journal.sessionID)
        XCTAssertFalse(try XCTUnwrap(result.sessionID).isEmpty)
    }

    func testStrictMutationsRejectMissingAndStaleSessionBeforeIntentPersistence() async throws {
        let store = SessionBoundJournalStore()
        let system = SessionBoundSystem()
        let coordinator = makeCoordinator(store: store, system: system)
        let started = await coordinator.start(
            configuration: TravelSessionConfiguration(wifiDevice: "en0")
        )
        let loadedActive = try await store.load()
        let active = try XCTUnwrap(loadedActive)

        let missing = await coordinator.setWiFiPower(
            expectedSessionID: "",
            device: "en0",
            enabled: false,
            timeout: .seconds(1)
        )
        let stale = await coordinator.associate(
            expectedSessionID: "stale-session",
            device: "en0",
            ssid: "iPhone",
            password: "secret",
            timeout: .milliseconds(321)
        )
        let loadedRetained = try await store.load()
        let retained = try XCTUnwrap(loadedRetained)
        let snapshot = await system.snapshot()

        XCTAssertEqual(started.sessionID, active.sessionID)
        XCTAssertFalse(missing.succeeded)
        XCTAssertFalse(stale.succeeded)
        XCTAssertNil(retained.pendingMutation)
        XCTAssertEqual(retained.revision, active.revision)
        XCTAssertEqual(retained.phase, .active)
        XCTAssertTrue(snapshot.powerWrites.isEmpty)
        XCTAssertTrue(snapshot.associations.isEmpty)
    }

    func testHandoffMutationsRejectOldGenerationAndEpisodeWithinSameSession() async throws {
        let store = SessionBoundJournalStore()
        let system = SessionBoundSystem()
        let coordinator = makeCoordinator(store: store, system: system)
        let started = await coordinator.start(
            configuration: TravelSessionConfiguration(wifiDevice: "en0")
        )
        let sessionID = try XCTUnwrap(started.sessionID)
        let generation = UUID()
        let current = HandoffEpisodeToken(
            sessionID: sessionID,
            generation: generation,
            episodeID: "\(sessionID):2"
        )
        let oldGeneration = HandoffEpisodeToken(
            sessionID: sessionID,
            generation: UUID(),
            episodeID: current.episodeID
        )
        let oldEpisode = HandoffEpisodeToken(
            sessionID: sessionID,
            generation: generation,
            episodeID: "\(sessionID):1"
        )

        let authorization = await coordinator.authorizeHandoffEpisode(current)
        let currentAttempt = await coordinator.setWiFiPower(
            operation: HandoffOperationIdentity(episode: current, attempt: 2),
            device: "en0",
            enabled: true,
            timeout: .seconds(1)
        )
        let retiredAttemptResult = await coordinator.associate(
            operation: HandoffOperationIdentity(episode: current, attempt: 1),
            device: "en0",
            ssid: "iPhone",
            password: "secret",
            timeout: .seconds(1)
        )
        let oldGenerationResult = await coordinator.associate(
            operation: HandoffOperationIdentity(episode: oldGeneration, attempt: 1),
            device: "en0",
            ssid: "iPhone",
            password: "secret",
            timeout: .seconds(1)
        )
        let oldEpisodeResult = await coordinator.associate(
            operation: HandoffOperationIdentity(episode: oldEpisode, attempt: 1),
            device: "en0",
            ssid: "iPhone",
            password: "secret",
            timeout: .seconds(1)
        )
        let invalidAttemptResult = await coordinator.setWiFiPower(
            operation: HandoffOperationIdentity(episode: current, attempt: 0),
            device: "en0",
            enabled: false,
            timeout: .seconds(1)
        )
        let loadedRetained = try await store.load()
        let retained = try XCTUnwrap(loadedRetained)
        let snapshot = await system.snapshot()

        XCTAssertTrue(authorization.succeeded)
        XCTAssertTrue(currentAttempt.succeeded)
        XCTAssertEqual(retiredAttemptResult.failureCategory, .staleSession)
        XCTAssertEqual(oldGenerationResult.failureCategory, .staleSession)
        XCTAssertEqual(oldEpisodeResult.failureCategory, .staleSession)
        XCTAssertEqual(invalidAttemptResult.failureCategory, .staleSession)
        XCTAssertNil(retained.pendingMutation)
        XCTAssertTrue(snapshot.powerWrites.isEmpty)
        XCTAssertTrue(snapshot.associations.isEmpty)

        await coordinator.finishHandoffEpisode(current)
        let finishedEpisodeResult = await coordinator.associate(
            operation: HandoffOperationIdentity(episode: current, attempt: 1),
            device: "en0",
            ssid: "iPhone",
            password: "secret",
            timeout: .seconds(1)
        )
        XCTAssertEqual(finishedEpisodeResult.failureCategory, .staleSession)
    }

    func testBusyHigherAttemptCannotRetireTheInFlightAttempt() async throws {
        let store = SessionBoundJournalStore()
        let system = SessionBoundSystem()
        let observer = SuspendedIntentObserver()
        let coordinator = makeCoordinator(store: store, system: system, observer: observer)
        let started = await coordinator.start(
            configuration: TravelSessionConfiguration(wifiDevice: "en0")
        )
        let sessionID = try XCTUnwrap(started.sessionID)
        let token = HandoffEpisodeToken(
            sessionID: sessionID,
            generation: UUID(),
            episodeID: "\(sessionID):1"
        )
        let authorization = await coordinator.authorizeHandoffEpisode(token)
        XCTAssertTrue(authorization.succeeded)

        let firstAttempt = Task {
            await coordinator.associate(
                operation: HandoffOperationIdentity(episode: token, attempt: 1),
                device: "en0",
                ssid: "iPhone",
                password: "secret",
                timeout: .seconds(1)
            )
        }
        await observer.waitUntilSuspended()
        let rejectedHigherAttempt = await coordinator.associate(
            operation: HandoffOperationIdentity(episode: token, attempt: 2),
            device: "en0",
            ssid: "iPhone",
            password: "secret",
            timeout: .seconds(1)
        )
        XCTAssertFalse(rejectedHigherAttempt.succeeded)

        await observer.resume()
        let firstResult = await firstAttempt.value
        let loadedJournal = try await store.load()
        let journal = try XCTUnwrap(loadedJournal)
        let snapshot = await system.snapshot()
        XCTAssertTrue(firstResult.succeeded)
        XCTAssertEqual(journal.phase, .active)
        XCTAssertNil(journal.pendingMutation)
        XCTAssertEqual(snapshot.associations, ["iPhone"])

        let acceptedHigherAttempt = await coordinator.associate(
            operation: HandoffOperationIdentity(episode: token, attempt: 2),
            device: "en0",
            ssid: "iPhone",
            password: "secret",
            timeout: .seconds(1)
        )
        XCTAssertTrue(acceptedHigherAttempt.succeeded)
    }

    func testFailedHandoffAssociationReconcilesActiveSessionForRetryAndNextEpisode() async throws {
        let store = SessionBoundJournalStore()
        let system = HandoffReconciliationSystem(behaviors: [.failNotApplied, .succeed])
        let coordinator = makeCoordinator(store: store, system: system)
        let started = await coordinator.start(
            configuration: TravelSessionConfiguration(wifiDevice: "en0")
        )
        let sessionID = try XCTUnwrap(started.sessionID)
        let generation = UUID()
        let firstEpisode = HandoffEpisodeToken(
            sessionID: sessionID,
            generation: generation,
            episodeID: "\(sessionID):1"
        )
        let firstAuthorization = await coordinator.authorizeHandoffEpisode(firstEpisode)
        XCTAssertTrue(firstAuthorization.succeeded)

        let failed = await coordinator.associate(
            operation: HandoffOperationIdentity(episode: firstEpisode, attempt: 1),
            device: "en0",
            ssid: "iPhone",
            password: "secret",
            timeout: .seconds(1)
        )
        let loadedAfterFailure = try await store.load()
        let afterFailure = try XCTUnwrap(loadedAfterFailure)
        XCTAssertFalse(failed.succeeded)
        XCTAssertEqual(afterFailure.phase, .active)
        XCTAssertNil(afterFailure.pendingMutation)
        XCTAssertFalse(afterFailure.changedAssociation)

        let succeeded = await coordinator.associate(
            operation: HandoffOperationIdentity(episode: firstEpisode, attempt: 2),
            device: "en0",
            ssid: "iPhone",
            password: "secret",
            timeout: .seconds(1)
        )
        let loadedAfterSuccess = try await store.load()
        let afterSuccess = try XCTUnwrap(loadedAfterSuccess)
        XCTAssertTrue(succeeded.succeeded)
        XCTAssertEqual(afterSuccess.phase, .active)
        XCTAssertNil(afterSuccess.pendingMutation)
        XCTAssertTrue(afterSuccess.changedAssociation)
        let successfulSnapshot = await system.snapshot()
        XCTAssertEqual(successfulSnapshot.associationTargets, ["iPhone", "iPhone"])

        await coordinator.finishHandoffEpisode(firstEpisode)
        let nextEpisode = HandoffEpisodeToken(
            sessionID: sessionID,
            generation: generation,
            episodeID: "\(sessionID):2"
        )
        let nextAuthorization = await coordinator.authorizeHandoffEpisode(nextEpisode)
        XCTAssertTrue(nextAuthorization.succeeded)
        await coordinator.finishHandoffEpisode(nextEpisode)

        let stopped = await coordinator.stop()
        let restored = await system.snapshot()
        XCTAssertEqual(stopped.lifecycle, .off)
        XCTAssertEqual(restored.ssid, "Office")
    }

    func testCancelledHandoffReconcilesAppliedAndNotAppliedBeforeStopRestoresBaseline() async throws {
        for behavior in [
            HandoffReconciliationSystem.Behavior.cancelNotApplied,
            .cancelApplied,
        ] {
            let store = SessionBoundJournalStore()
            let system = HandoffReconciliationSystem(behaviors: [behavior])
            let coordinator = makeCoordinator(store: store, system: system)
            let started = await coordinator.start(
                configuration: TravelSessionConfiguration(wifiDevice: "en0")
            )
            let sessionID = try XCTUnwrap(started.sessionID)
            let token = HandoffEpisodeToken(
                sessionID: sessionID,
                generation: UUID(),
                episodeID: "\(sessionID):1"
            )
            let authorization = await coordinator.authorizeHandoffEpisode(token)
            XCTAssertTrue(authorization.succeeded)

            let mutation = Task {
                await coordinator.associate(
                    operation: HandoffOperationIdentity(episode: token, attempt: 1),
                    device: "en0",
                    ssid: "iPhone",
                    password: "secret",
                    timeout: .seconds(5)
                )
            }
            try await waitForReconciliationAssociation(system)
            await coordinator.cancelHandoffEpisode(token)
            let result = await mutation.value
            let loadedReconciled = try await store.load()
            let reconciled = try XCTUnwrap(loadedReconciled)
            let cancelledSnapshot = await system.snapshot()

            XCTAssertEqual(result.failureCategory, .cancelled)
            XCTAssertTrue(cancelledSnapshot.cancellationObserved)
            XCTAssertEqual(reconciled.phase, .active)
            XCTAssertNil(reconciled.pendingMutation)
            XCTAssertEqual(reconciled.changedAssociation, behavior == .cancelApplied)

            let nextToken = HandoffEpisodeToken(
                sessionID: sessionID,
                generation: token.generation,
                episodeID: "\(sessionID):2"
            )
            let nextAuthorization = await coordinator.authorizeHandoffEpisode(nextToken)
            XCTAssertTrue(nextAuthorization.succeeded)
            await coordinator.finishHandoffEpisode(nextToken)

            let stopped = await coordinator.stop()
            let final = await system.snapshot()
            XCTAssertEqual(stopped.lifecycle, .off)
            XCTAssertEqual(final.ssid, "Office")
            let cleared = try await store.load()
            XCTAssertNil(cleared)
        }
    }

    func testOutputSignalledCancellationRemainsTerminalAfterReconciliation() async throws {
        for behavior in [
            HandoffReconciliationSystem.Behavior.signalCancelledNotApplied,
            .signalCancelledApplied,
        ] {
            let store = SessionBoundJournalStore()
            let system = HandoffReconciliationSystem(behaviors: [behavior])
            let coordinator = makeCoordinator(store: store, system: system)
            let started = await coordinator.start(
                configuration: TravelSessionConfiguration(wifiDevice: "en0")
            )
            let sessionID = try XCTUnwrap(started.sessionID)
            let token = HandoffEpisodeToken(
                sessionID: sessionID,
                generation: UUID(),
                episodeID: "\(sessionID):1"
            )
            let authorization = await coordinator.authorizeHandoffEpisode(token)
            XCTAssertTrue(authorization.succeeded)

            let result = await coordinator.associate(
                operation: HandoffOperationIdentity(episode: token, attempt: 1),
                device: "en0",
                ssid: "iPhone",
                password: "secret",
                timeout: .seconds(1)
            )
            let loadedJournal = try await store.load()
            let journal = try XCTUnwrap(loadedJournal)
            XCTAssertEqual(result.failureCategory, .cancelled)
            XCTAssertEqual(journal.phase, .active)
            XCTAssertNil(journal.pendingMutation)
            XCTAssertEqual(journal.changedAssociation, behavior == .signalCancelledApplied)

            await coordinator.finishHandoffEpisode(token)
            let stopped = await coordinator.stop()
            let final = await system.snapshot()
            XCTAssertEqual(stopped.lifecycle, .off)
            XCTAssertEqual(final.ssid, "Office")
        }
    }

    func testFailedHandoffReconciliationAloneRequiresCleanup() async throws {
        let store = SessionBoundJournalStore()
        let system = HandoffReconciliationSystem(
            behaviors: [.failNotApplied],
            failReadbackAfterDispatch: true
        )
        let coordinator = makeCoordinator(store: store, system: system)
        let started = await coordinator.start(
            configuration: TravelSessionConfiguration(wifiDevice: "en0")
        )
        let sessionID = try XCTUnwrap(started.sessionID)
        let token = HandoffEpisodeToken(
            sessionID: sessionID,
            generation: UUID(),
            episodeID: "\(sessionID):1"
        )
        let authorization = await coordinator.authorizeHandoffEpisode(token)
        XCTAssertTrue(authorization.succeeded)

        let result = await coordinator.associate(
            operation: HandoffOperationIdentity(episode: token, attempt: 1),
            device: "en0",
            ssid: "iPhone",
            password: "secret",
            timeout: .seconds(1)
        )
        let loadedJournal = try await store.load()
        let journal = try XCTUnwrap(loadedJournal)

        XCTAssertFalse(result.succeeded)
        XCTAssertEqual(journal.phase, .cleanupRequired)
        XCTAssertNotNil(journal.pendingMutation)
        let lifecycle = await coordinator.lifecycle()
        XCTAssertEqual(lifecycle, .cleanupRequired)
    }

    func testStrictAssociationPropagatesTimeoutAndCommitsOwnedMutation() async throws {
        let store = SessionBoundJournalStore()
        let system = SessionBoundSystem()
        let coordinator = makeCoordinator(store: store, system: system)
        let started = await coordinator.start(
            configuration: TravelSessionConfiguration(wifiDevice: "en0")
        )
        let sessionID = try XCTUnwrap(started.sessionID)

        let result = await coordinator.associate(
            expectedSessionID: sessionID,
            device: "en0",
            ssid: "iPhone",
            password: "secret",
            timeout: .milliseconds(321)
        )
        let loadedJournal = try await store.load()
        let journal = try XCTUnwrap(loadedJournal)
        let snapshot = await system.snapshot()

        XCTAssertTrue(result.succeeded)
        XCTAssertEqual(snapshot.associations, ["iPhone"])
        let forwardedTimeout = try XCTUnwrap(snapshot.timeouts.first)
        XCTAssertEqual(snapshot.timeouts.count, 1)
        XCTAssertGreaterThan(forwardedTimeout, .zero)
        XCTAssertLessThanOrEqual(forwardedTimeout, .milliseconds(321))
        XCTAssertNil(journal.pendingMutation)
        XCTAssertTrue(journal.changedAssociation)
    }

    func testStrictPowerMutationHonorsItsBoundedTimeout() async throws {
        let store = SessionBoundJournalStore()
        let system = SessionBoundSystem(powerDelay: .seconds(2))
        let coordinator = makeCoordinator(store: store, system: system)
        let started = await coordinator.start(
            configuration: TravelSessionConfiguration(wifiDevice: "en0")
        )
        let sessionID = try XCTUnwrap(started.sessionID)
        let clock = ContinuousClock()
        let start = clock.now

        let result = await coordinator.setWiFiPower(
            expectedSessionID: sessionID,
            device: "en0",
            enabled: false,
            timeout: .milliseconds(30)
        )
        let elapsed = start.duration(to: clock.now)
        let snapshot = await system.snapshot()

        XCTAssertFalse(result.succeeded)
        XCTAssertLessThan(elapsed, .seconds(1))
        XCTAssertTrue(snapshot.powerWrites.isEmpty)
    }

    func testSessionIdentityIsRecheckedAfterObserverSuspensionBeforeDispatch() async throws {
        let store = SessionBoundJournalStore()
        let system = SessionBoundSystem()
        let observer = SuspendedIntentObserver()
        let coordinator = makeCoordinator(store: store, system: system, observer: observer)
        let started = await coordinator.start(
            configuration: TravelSessionConfiguration(wifiDevice: "en0")
        )
        let sessionID = try XCTUnwrap(started.sessionID)

        let mutation = Task {
            await coordinator.associate(
                expectedSessionID: sessionID,
                device: "en0",
                ssid: "iPhone",
                password: "secret",
                timeout: .seconds(1)
            )
        }
        await observer.waitUntilSuspended()
        await store.forceReplace(
            TravelSessionJournal(
                sessionID: "replacement-session",
                wifiBaseline: TravelWiFiBaseline(
                    device: "en0",
                    powerEnabled: true,
                    associatedSSID: "Office"
                )
            )
        )
        await observer.resume()
        let result = await mutation.value
        let snapshot = await system.snapshot()

        XCTAssertFalse(result.succeeded)
        XCTAssertTrue(snapshot.associations.isEmpty)
    }

    func testTransactionalGatewayForwardsAssociationTimeout() async {
        let manager = RecordingSessionManager()
        let gateway = TransactionalTravelCommandGateway(
            rawGateway: SessionBoundRawGateway(),
            sessionManager: manager
        )

        let result = await gateway.joinWiFi(
            device: "en0",
            ssid: "iPhone",
            password: "secret",
            timeout: .milliseconds(777)
        )

        XCTAssertTrue(result.succeeded)
        let call = await manager.associationCall()
        XCTAssertEqual(call?.ssid, "iPhone")
        XCTAssertEqual(call?.timeout, .milliseconds(777))
    }

    func testProcessRunnerTerminatesUnderlyingProcessOnTaskCancellation() async throws {
        let runner = ProcessShellCommandRunner()
        let clock = ContinuousClock()
        let started = clock.now
        let task = Task {
            await runner.run(
                URL(fileURLWithPath: "/bin/sleep"),
                arguments: ["2"]
            )
        }

        try await Task.sleep(for: .milliseconds(50))
        task.cancel()
        let output = await task.value
        let elapsed = started.duration(to: clock.now)

        XCTAssertEqual(output.exitCode, 130)
        XCTAssertEqual(output.standardError, "Command was cancelled and terminated.")
        XCTAssertLessThan(elapsed, .seconds(1))
    }

    func testLidReopenRevokesAndAwaitsActualSessionOwnedAssociation() async throws {
        let store = SessionBoundJournalStore()
        let system = ReopenBlockingSessionSystem()
        let session = makeCoordinator(store: store, system: system)
        let started = await session.start(
            configuration: TravelSessionConfiguration(wifiDevice: "en0")
        )
        let sessionID = try XCTUnwrap(started.sessionID)
        let lid = ReopenLidProvider(.open)
        let connectivity = ReopenConnectivityProvider()
        let engine = TravelInternetHandoffEngine(
            connectivityProvider: connectivity,
            reachabilityChecker: ReopenReachabilityChecker(),
            sessionManager: session,
            policy: HandoffRetryPolicy(maxAttempts: 1)
        )
        let coordinator = TravelInternetHandoffCoordinator(
            lidProvider: lid,
            engine: engine,
            scheduler: ReopenHandoffScheduler(),
            policy: HandoffRetryPolicy(maxAttempts: 1)
        )
        let context = HandoffSessionContext(
            sessionID: sessionID,
            generation: UUID(),
            device: "en0",
            targetSSID: ExactUTF8String("iPhone")!,
            password: "secret"
        )

        _ = await coordinator.activate(context)
        await lid.set(.closed)
        _ = await coordinator.tick(generation: context.generation)
        try await waitForBlockingAssociation(system)

        await lid.set(.open)
        _ = await coordinator.tick(generation: context.generation)
        let mutationAfterReopen = await system.snapshot()
        let publicationAfterReopen = await coordinator.currentPublication()

        XCTAssertTrue(mutationAfterReopen.cancellationObserved)
        XCTAssertTrue(mutationAfterReopen.appliedAssociations.isEmpty)
        if case .associating = publicationAfterReopen.state {
            XCTFail("A cancelled close-owned episode published a late association state.")
        }

        try await Task.sleep(for: .milliseconds(30))
        let mutationAfterDelay = await system.snapshot()
        let publicationAfterDelay = await coordinator.currentPublication()
        XCTAssertEqual(mutationAfterDelay.appliedAssociations, [])
        XCTAssertEqual(publicationAfterDelay, publicationAfterReopen)

        let revokedToken = HandoffEpisodeToken(
            sessionID: sessionID,
            generation: context.generation,
            episodeID: "\(sessionID):1"
        )
        let lateMutation = await session.associate(
            operation: HandoffOperationIdentity(episode: revokedToken, attempt: 1),
            device: "en0",
            ssid: "iPhone",
            password: "secret",
            timeout: .seconds(1)
        )
        XCTAssertEqual(lateMutation.failureCategory, .staleSession)

        let invalidation = await coordinator.invalidate(generation: context.generation)
        await invalidation?.value
        _ = await session.stop()
    }

    private func makeCoordinator(
        store: SessionBoundJournalStore,
        system: any TravelSessionSystemControlling = SessionBoundSystem(),
        observer: any TravelSessionBoundaryObserving = NoOpTravelSessionBoundaryObserver()
    ) -> TravelSessionCoordinator {
        TravelSessionCoordinator(
            journalStore: store,
            system: system,
            leaseClient: SessionBoundLeaseClient(),
            observer: observer
        )
    }
}

private actor SessionBoundJournalStore: TravelSessionJournalStoring {
    private var journal: TravelSessionJournal?

    func load() async throws -> TravelSessionJournal? { journal }

    func create(_ candidate: TravelSessionJournal) async throws -> TravelSessionJournal {
        guard journal == nil else { throw TravelSessionJournalError.alreadyExists }
        journal = candidate
        return candidate
    }

    func update(
        _ candidate: TravelSessionJournal,
        expectedRevision: Int
    ) async throws -> TravelSessionJournal {
        guard let current = journal else { throw TravelSessionJournalError.missing }
        guard current.sessionID == candidate.sessionID else {
            throw TravelSessionJournalError.staleSession
        }
        guard current.revision == expectedRevision else {
            throw TravelSessionJournalError.staleRevision(
                expected: expectedRevision,
                actual: current.revision
            )
        }
        var persisted = candidate
        persisted.revision += 1
        journal = persisted
        return persisted
    }

    func clear(sessionID: String, expectedRevision: Int) async throws {
        guard let current = journal else { throw TravelSessionJournalError.missing }
        guard current.sessionID == sessionID else { throw TravelSessionJournalError.staleSession }
        guard current.revision == expectedRevision else {
            throw TravelSessionJournalError.staleRevision(
                expected: expectedRevision,
                actual: current.revision
            )
        }
        journal = nil
    }

    func forceReplace(_ replacement: TravelSessionJournal) {
        journal = replacement
    }
}

private actor SessionBoundSystem: TravelSessionSystemControlling {
    struct Snapshot: Sendable {
        var powerWrites: [Bool]
        var associations: [String]
        var timeouts: [Duration]
    }

    private var powerEnabled = true
    private var ssid: String? = "Office"
    private let powerDelay: Duration?
    private var powerWrites: [Bool] = []
    private var associations: [String] = []
    private var timeouts: [Duration] = []

    init(powerDelay: Duration? = nil) {
        self.powerDelay = powerDelay
    }

    func currentWiFiPower(device: String) async throws -> Bool { powerEnabled }
    func currentAssociatedSSID(device: String) async throws -> String? { ssid }

    func setWiFiPower(device: String, enabled: Bool) async -> CommandResult {
        if let powerDelay {
            do {
                try await Task.sleep(for: powerDelay)
            } catch {
                return CommandResult(exitCode: 130, standardError: "cancelled")
            }
        }
        powerEnabled = enabled
        powerWrites.append(enabled)
        return CommandResult(exitCode: 0)
    }

    func setWiFiPower(
        device: String,
        enabled: Bool,
        timeout: Duration
    ) async -> CommandResult {
        if let powerDelay, powerDelay > timeout {
            do {
                try await Task.sleep(for: timeout)
            } catch {
                return CommandResult(
                    exitCode: 130,
                    standardError: "cancelled",
                    failureCategory: .cancelled
                )
            }
            return CommandResult(
                exitCode: 124,
                standardError: "timed out",
                failureCategory: .timedOut
            )
        }
        return await setWiFiPower(device: device, enabled: enabled)
    }

    func associate(device: String, ssid: String, password: String?) async -> CommandResult {
        self.ssid = ssid
        associations.append(ssid)
        return CommandResult(exitCode: 0)
    }

    func associate(
        device: String,
        ssid: String,
        password: String?,
        timeout: Duration
    ) async -> CommandResult {
        timeouts.append(timeout)
        return await associate(device: device, ssid: ssid, password: password)
    }

    func snapshot() -> Snapshot {
        Snapshot(
            powerWrites: powerWrites,
            associations: associations,
            timeouts: timeouts
        )
    }
}

private actor HandoffReconciliationSystem: TravelSessionSystemControlling {
    enum Behavior: Equatable, Sendable {
        case succeed
        case failNotApplied
        case cancelNotApplied
        case cancelApplied
        case signalCancelledNotApplied
        case signalCancelledApplied
    }

    struct Snapshot: Sendable {
        let ssid: String?
        let associationTargets: [String]
        let cancellationObserved: Bool
        let blockingAssociationStarted: Bool
    }

    private var ssid: String? = "Office"
    private var behaviors: [Behavior]
    private let failReadbackAfterDispatch: Bool
    private var associationTargets: [String] = []
    private var cancellationObserved = false
    private var blockingAssociationStarted = false

    init(
        behaviors: [Behavior],
        failReadbackAfterDispatch: Bool = false
    ) {
        self.behaviors = behaviors
        self.failReadbackAfterDispatch = failReadbackAfterDispatch
    }

    func currentWiFiPower(device: String) async throws -> Bool { true }

    func currentAssociatedSSID(device: String) async throws -> String? {
        if failReadbackAfterDispatch, !associationTargets.isEmpty {
            throw TravelSessionSystemError.stateUnavailable(
                "Authoritative association readback failed."
            )
        }
        return ssid
    }

    func currentAssociatedSSID(
        device: String,
        timeout: Duration
    ) async throws -> String? {
        try await currentAssociatedSSID(device: device)
    }

    func setWiFiPower(device: String, enabled: Bool) async -> CommandResult {
        CommandResult(exitCode: 0)
    }

    func associate(device: String, ssid: String, password: String?) async -> CommandResult {
        associationTargets.append(ssid)
        let behavior = behaviors.isEmpty ? .succeed : behaviors.removeFirst()
        switch behavior {
        case .succeed:
            self.ssid = ssid
            return CommandResult(exitCode: 0)
        case .failNotApplied:
            return CommandResult(exitCode: 7, standardError: "association failed")
        case .signalCancelledNotApplied, .signalCancelledApplied:
            if behavior == .signalCancelledApplied {
                self.ssid = ssid
            }
            return CommandResult(
                exitCode: 130,
                standardError: "association provider reported cancellation",
                failureCategory: .cancelled
            )
        case .cancelNotApplied, .cancelApplied:
            if behavior == .cancelApplied {
                self.ssid = ssid
            }
            blockingAssociationStarted = true
            do {
                try await Task.sleep(for: .seconds(10))
            } catch {
                cancellationObserved = true
                return CommandResult(
                    exitCode: 130,
                    standardError: "association cancelled",
                    failureCategory: .cancelled
                )
            }
            return CommandResult(exitCode: 0)
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

    func snapshot() -> Snapshot {
        Snapshot(
            ssid: ssid,
            associationTargets: associationTargets,
            cancellationObserved: cancellationObserved,
            blockingAssociationStarted: blockingAssociationStarted
        )
    }
}

private func waitForReconciliationAssociation(
    _ system: HandoffReconciliationSystem
) async throws {
    for _ in 0..<500 {
        if await system.snapshot().blockingAssociationStarted { return }
        try await Task.sleep(for: .milliseconds(2))
    }
    XCTFail("Timed out waiting for the cancellable handoff association.")
}

private actor ReopenBlockingSessionSystem: TravelSessionSystemControlling {
    struct Snapshot: Sendable {
        let associationStarted: Bool
        let cancellationObserved: Bool
        let appliedAssociations: [String]
    }

    private var ssid: String? = "Office"
    private var associationStarted = false
    private var cancellationObserved = false
    private var appliedAssociations: [String] = []

    func currentWiFiPower(device: String) async throws -> Bool { true }
    func currentAssociatedSSID(device: String) async throws -> String? { ssid }

    func setWiFiPower(device: String, enabled: Bool) async -> CommandResult {
        CommandResult(exitCode: 0)
    }

    func associate(device: String, ssid: String, password: String?) async -> CommandResult {
        associationStarted = true
        do {
            try await Task.sleep(for: .seconds(10))
        } catch {
            cancellationObserved = true
            return CommandResult(
                exitCode: 130,
                standardError: "association provider cancelled",
                failureCategory: .cancelled
            )
        }
        guard !Task.isCancelled else {
            cancellationObserved = true
            return CommandResult(
                exitCode: 130,
                standardError: "association provider cancelled",
                failureCategory: .cancelled
            )
        }
        self.ssid = ssid
        appliedAssociations.append(ssid)
        return CommandResult(exitCode: 0)
    }

    func associate(
        device: String,
        ssid: String,
        password: String?,
        timeout: Duration
    ) async -> CommandResult {
        await associate(device: device, ssid: ssid, password: password)
    }

    func snapshot() -> Snapshot {
        Snapshot(
            associationStarted: associationStarted,
            cancellationObserved: cancellationObserved,
            appliedAssociations: appliedAssociations
        )
    }
}

private actor ReopenLidProvider: LidStateProviding {
    private var state: LidState

    init(_ state: LidState) {
        self.state = state
    }

    func set(_ state: LidState) {
        self.state = state
    }

    func readLidState(timeout: Duration) async -> ProviderReading<LidState> {
        .value(state)
    }
}

private actor ReopenConnectivityProvider: WiFiConnectivityProviding {
    func readConnectivity(device: String, timeout: Duration) async -> WiFiConnectivityObservation {
        WiFiConnectivityObservation(
            device: device,
            power: .value(true),
            ssid: .value(ExactUTF8String("Office")),
            addresses: .value([IPAddress("10.0.0.2")!]),
            defaultRouteInterface: .value(device)
        )
    }
}

private actor ReopenReachabilityChecker: OutboundReachabilityChecking {
    func check(timeout: Duration, nonce: String) async -> ReachabilityResult {
        .reachable(statusCode: 204)
    }
}

private actor ReopenHandoffScheduler: HandoffScheduling {
    private var elapsed = Duration.zero

    func now() async -> Duration { elapsed }

    func sleep(for duration: Duration) async throws {
        try Task.checkCancellation()
        elapsed += duration
        await Task.yield()
        try Task.checkCancellation()
    }
}

private func waitForBlockingAssociation(
    _ system: ReopenBlockingSessionSystem
) async throws {
    for _ in 0..<500 {
        if await system.snapshot().associationStarted { return }
        try await Task.sleep(for: .milliseconds(2))
    }
    XCTFail("Timed out waiting for the real session-owned association.")
}

private struct SessionBoundLeaseClient: SleepOverrideLeaseClient {
    func acquire(
        sessionID: String,
        requestID: String
    ) async throws -> SleepOverrideLeaseReceipt {
        SleepOverrideLeaseReceipt(
            phase: .active,
            binding: binding(sessionID: sessionID, requestID: requestID)
        )
    }

    func resolve(
        sessionID: String,
        requestID: String
    ) async throws -> SleepOverrideLeaseResolution {
        .found(
            SleepOverrideLeaseReceipt(
                phase: .active,
                binding: binding(sessionID: sessionID, requestID: requestID)
            )
        )
    }

    func status(binding: SleepOverrideLeaseBinding) async throws -> SleepOverrideLeaseReceipt {
        SleepOverrideLeaseReceipt(phase: .released, binding: binding)
    }

    func release(binding: SleepOverrideLeaseBinding) async throws -> SleepOverrideLeaseReceipt {
        SleepOverrideLeaseReceipt(phase: .released, binding: binding)
    }

    func acknowledgeRelease(binding: SleepOverrideLeaseBinding) async throws {}

    private func binding(
        sessionID: String,
        requestID: String
    ) -> SleepOverrideLeaseBinding {
        SleepOverrideLeaseBinding(
            sessionID: sessionID,
            requestID: requestID,
            leaseID: "lease-\(sessionID)",
            generation: "generation-1"
        )
    }
}

private actor SuspendedIntentObserver: TravelSessionBoundaryObserving {
    private var didSuspend = false
    private var suspensionWaiters: [CheckedContinuation<Void, Never>] = []
    private var resumeContinuation: CheckedContinuation<Void, Never>?

    func reached(
        _ boundary: TravelSessionBoundary,
        sessionID: String?,
        value: String?
    ) async {
        guard boundary == .afterIntentPersist else { return }
        didSuspend = true
        let waiters = suspensionWaiters
        suspensionWaiters.removeAll()
        waiters.forEach { $0.resume() }
        await withCheckedContinuation { continuation in
            resumeContinuation = continuation
        }
    }

    func waitUntilSuspended() async {
        if didSuspend { return }
        await withCheckedContinuation { continuation in
            suspensionWaiters.append(continuation)
        }
    }

    func resume() {
        resumeContinuation?.resume()
        resumeContinuation = nil
    }
}

private actor RecordingSessionManager: TravelSessionManaging {
    struct AssociationCall: Sendable {
        var ssid: String
        var timeout: Duration
    }

    private var call: AssociationCall?

    func start(configuration: TravelSessionConfiguration) async -> TravelSessionTransitionResult {
        TravelSessionTransitionResult(lifecycle: .active, sessionID: "session", canTerminate: false)
    }

    func stop() async -> TravelSessionTransitionResult {
        TravelSessionTransitionResult(lifecycle: .off)
    }

    func requestQuit() async -> TravelSessionTransitionResult {
        TravelSessionTransitionResult(lifecycle: .off)
    }

    func recover() async -> TravelSessionTransitionResult {
        TravelSessionTransitionResult(lifecycle: .off)
    }

    func lifecycle() async -> TravelSessionLifecycle { .active }

    func setWiFiPower(device: String, enabled: Bool) async -> CommandResult {
        CommandResult(exitCode: 0)
    }

    func associate(device: String, ssid: String, password: String?) async -> CommandResult {
        CommandResult(exitCode: 0)
    }

    func associate(
        device: String,
        ssid: String,
        password: String?,
        timeout: Duration
    ) async -> CommandResult {
        call = AssociationCall(ssid: ssid, timeout: timeout)
        return CommandResult(exitCode: 0)
    }

    func associationCall() -> AssociationCall? { call }
}

private struct SessionBoundRawGateway: TravelCommandGateway {
    func startKeepAwake() async throws {}
    func stopKeepAwake() async {}
    func currentLidClosed() async -> Bool? { false }
    func discoverWiFiDevice() async -> String? { "en0" }
    func currentWiFiStatus(device: String) async -> WiFiStatus {
        WiFiStatus(device: device, networkName: "Office", rawOutput: "Office")
    }
    func currentWiFiPower(device: String) async -> Bool? { true }
    func setWiFiPower(device: String, enabled: Bool) async -> CommandResult {
        CommandResult(exitCode: 0)
    }
    func joinWiFi(device: String, ssid: String, password: String?) async -> CommandResult {
        CommandResult(exitCode: 0)
    }
    func openWiFiSettings() async {}
    func isCodexRunning() async -> Bool { true }
}
