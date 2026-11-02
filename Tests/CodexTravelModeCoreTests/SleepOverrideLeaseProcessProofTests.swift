import CodexTravelModeCore
import CodexTravelModeSleepLease
import CodexTravelModeSleepLeaseXPC
import Darwin
import Foundation
import ObjectiveC
import SleepOverrideLeaseProofSupport
import XCTest

final class SleepOverrideLeaseProcessProofTests: XCTestCase {
    func testResolutionDistinguishesAuthoritativeNotFoundFromEveryUnavailablePath() async throws {
        let unavailable = UnavailableSleepOverrideLeaseClient()
        let unavailableError = await captureLeaseError {
            _ = try await unavailable.resolve(sessionID: "missing", requestID: "missing")
        }
        XCTAssertEqual(unavailableError, .helperUnavailable(.definitelyNotSent))

        let workspace = try LeaseProofWorkspace(baseline: false)
        defer { workspace.remove() }
        let helper = try launchHelper(workspace: workspace)
        defer { stopProcess(helper) }
        let (transport, client) = try await makeProofClient(workspace: workspace)

        let resolution = try await client.resolve(sessionID: "never", requestID: "accepted")
        XCTAssertEqual(resolution, .authoritativeNotFound)

        let authError = await captureTransportError {
            _ = try await ProofSocketLeaseTransport(
                socketPath: workspace.socketURL.path,
                credential: "not-authenticated"
            )
        }
        XCTAssertEqual(authError, .unauthenticated(.definitelyNotSent))

        stopProcess(helper)
        let interrupted = await captureLeaseError {
            _ = try await client.resolve(sessionID: "never", requestID: "accepted")
        }
        XCTAssertNotNil(interrupted)
        XCTAssertNotEqual(interrupted, .invalidReceipt)
        transport.closeOwnerConnection()
    }

    func testCleanRoundTripsAreExactIdempotentAndRetainMultipleReceipts() async throws {
        let disabled = try LeaseProofWorkspace(baseline: false)
        defer { disabled.remove() }
        let disabledHelper = try launchHelper(workspace: disabled)
        defer { stopProcess(disabledHelper) }
        let (transport, client) = try await makeProofClient(workspace: disabled)

        let first = try await client.acquire(sessionID: "disabled", requestID: "request-1")
        let duplicate = try await client.acquire(sessionID: "disabled", requestID: "request-1")
        XCTAssertEqual(first, duplicate)
        let activeStatus = try await client.status(binding: first.binding)
        XCTAssertEqual(activeStatus, first)
        XCTAssertEqual(writeTargets(in: try powerTrace(disabled)), [true])

        let released = try await client.release(binding: first.binding)
        XCTAssertEqual(released.phase, .released)
        let releasedAgain = try await client.release(binding: first.binding)
        XCTAssertEqual(releasedAgain, released)
        XCTAssertFalse(try powerState(disabled).sleepDisabled)
        XCTAssertEqual(writeTargets(in: try powerTrace(disabled)), [true, false])
        try assertReceiptCommittedBeforeJournalRemoval(disabled, binding: first.binding)
        let persistedReceipt = try XCTUnwrap(receiptFiles(disabled).first)
        let persistedKeys = try recursiveJSONKeys(at: persistedReceipt)
        XCTAssertFalse(persistedKeys.contains("baseline_sleep_disabled"))
        XCTAssertFalse(persistedKeys.contains {
            let key = $0.lowercased()
            return key.contains("baseline") || key.contains("original")
        })

        let second = try await client.acquire(sessionID: "disabled-2", requestID: "request-2")
        _ = try await client.release(binding: second.binding)
        XCTAssertEqual(try receiptFiles(disabled).count, 2)
        try await client.acknowledgeRelease(binding: first.binding)
        XCTAssertEqual(try receiptFiles(disabled).count, 1)

        let (_, otherPrincipal) = try await makeProofClient(
            workspace: disabled,
            credential: "owner-b"
        )
        let otherAcknowledgementError = await captureLeaseError {
            try await otherPrincipal.acknowledgeRelease(binding: second.binding)
        }
        XCTAssertNotNil(otherAcknowledgementError)
        XCTAssertEqual(try receiptFiles(disabled).count, 1)

        let active = try await client.acquire(sessionID: "disabled-3", requestID: "request-3")
        let activeAcknowledgementError = await captureLeaseError {
            try await client.acknowledgeRelease(binding: active.binding)
        }
        XCTAssertNotNil(activeAcknowledgementError)
        _ = try await client.release(binding: active.binding)
        transport.closeOwnerConnection()

        let enabled = try LeaseProofWorkspace(baseline: true)
        defer { enabled.remove() }
        let enabledHelper = try launchHelper(workspace: enabled)
        defer { stopProcess(enabledHelper) }
        let (_, enabledClient) = try await makeProofClient(workspace: enabled)
        let enabledLease = try await enabledClient.acquire(
            sessionID: "enabled",
            requestID: "request-enabled"
        )
        XCTAssertTrue(writeTargets(in: try powerTrace(enabled)).isEmpty)
        try writeJSON(ProofPowerState(sleepDisabled: false), to: enabled.powerStateURL)
        _ = try await enabledClient.release(binding: enabledLease.binding)
        XCTAssertTrue(try powerState(enabled).sleepDisabled)
        XCTAssertEqual(writeTargets(in: try powerTrace(enabled)), [true])
    }

    func testSIGKILLOwnerRestoresWithinFiveSecondsAndLeavesExactReceipt() async throws {
        let workspace = try LeaseProofWorkspace(baseline: false)
        defer { workspace.remove() }
        let helper = try launchHelper(workspace: workspace)
        defer { stopProcess(helper) }
        let owner = try launchOwner(
            workspace: workspace,
            scenario: "acquire-and-hold",
            sessionID: "owner-death",
            requestID: "request-owner-death"
        )
        defer { stopProcess(owner) }
        let ownerReady = try await waitForPath(workspace.ownerMarkerURL, process: owner)
        XCTAssertTrue(ownerReady)
        let artifact = try decode(ProofOwnerArtifact.self, at: workspace.ownerArtifactURL)
        let binding = try XCTUnwrap(artifact.receipt?.binding)
        XCTAssertTrue(try powerState(workspace).sleepDisabled)

        let started = Date()
        stopProcess(owner)
        let restored = try await waitUntil(timeout: 5) {
            try !powerState(workspace).sleepDisabled
                && !FileManager.default.fileExists(atPath: workspace.activeJournalURL.path)
                && receiptFiles(workspace).count == 1
        }
        XCTAssertTrue(restored)
        XCTAssertLessThan(Date().timeIntervalSince(started), 5)

        let (_, recoveringClient) = try await makeProofClient(workspace: workspace)
        let exact = try await recoveringClient.status(binding: binding)
        XCTAssertEqual(exact, SleepOverrideLeaseReceipt(phase: .released, binding: binding))
        let traceCount = try powerTrace(workspace).count
        for mismatched in binding.singleFieldMismatches() {
            let mismatchError = await captureLeaseError {
                _ = try await recoveringClient.status(binding: mismatched)
            }
            XCTAssertNotNil(mismatchError)
        }
        XCTAssertEqual(try powerTrace(workspace).count, traceCount)
        try assertReceiptCommittedBeforeJournalRemoval(workspace, binding: binding)
    }

    func testHelperRestartReconcilesEveryAcquisitionBoundaryAndLostResponse() async throws {
        let checkpoints = [
            "before_service_dispatch",
            SleepOverrideLeaseTransitionPoint.preparedPersisted.rawValue,
            SleepOverrideLeaseTransitionPoint.overrideWriteCompleted.rawValue,
            SleepOverrideLeaseTransitionPoint.appliedPersisted.rawValue,
            SleepOverrideLeaseTransitionPoint.activePersisted.rawValue
        ]
        for checkpoint in checkpoints {
            try await assertRestartRecovery(at: checkpoint)
        }
        try await assertRecoveryWhenOwnerDiesBeforeAcquireResponse()
    }

    func testVerificationFailureCompensatesAndBackoffRetriesAreDeterministic() async throws {
        let verification = try LeaseProofWorkspace(baseline: false)
        defer { verification.remove() }
        try writeJSON(
            ProofPowerControl(ignoreWritesRemaining: 1),
            to: verification.powerControlURL
        )
        let verificationHelper = try launchHelper(workspace: verification)
        defer { stopProcess(verificationHelper) }
        let (_, verificationClient) = try await makeProofClient(workspace: verification)
        let verificationError = await captureLeaseError {
            _ = try await verificationClient.acquire(
                sessionID: "verification",
                requestID: "request-verification"
            )
        }
        XCTAssertNotNil(verificationError)
        let compensated = try await waitUntil {
            try !powerState(verification).sleepDisabled
                && !FileManager.default.fileExists(atPath: verification.activeJournalURL.path)
        }
        XCTAssertTrue(compensated)
        XCTAssertFalse(try transitionTrace(verification).contains { $0.point == .activePersisted })

        let automatic = try LeaseProofWorkspace(baseline: false)
        defer { automatic.remove() }
        let automaticHelper = try launchHelper(workspace: automatic)
        defer { stopProcess(automaticHelper) }
        let (ownerTransport, ownerClient) = try await makeProofClient(workspace: automatic)
        let lease = try await ownerClient.acquire(sessionID: "retry", requestID: "automatic")
        try writeJSON(
            ProofPowerControl(failWritesRemaining: 5),
            to: automatic.powerControlURL
        )
        let failureStarted = Date()
        ownerTransport.closeOwnerConnection()
        let cleanupPersisted = try await waitUntil(timeout: 2) {
            try activeJournal(automatic)?.phase == .cleanupRequired
        }
        XCTAssertTrue(cleanupPersisted)
        XCTAssertLessThan(Date().timeIntervalSince(failureStarted), 2)
        let (clockTransport, _) = try await makeProofClient(workspace: automatic)
        for delay in [250, 500, 1_000, 2_000] {
            try await clockTransport.advanceClock(milliseconds: delay)
            let nextRetryScheduled = try await waitUntil {
                try clockDelays(automatic).count >= expectedClockTraceCount(after: delay)
            }
            XCTAssertTrue(nextRetryScheduled)
        }
        XCTAssertEqual(Array(try clockDelays(automatic).prefix(5)), [250, 500, 1_000, 2_000, 2_000])
        try writeJSON(ProofPowerControl(), to: automatic.powerControlURL)
        try await clockTransport.advanceClock(milliseconds: 2_000)
        let automaticRestored = try await waitUntil {
            try activeJournal(automatic) == nil && !powerState(automatic).sleepDisabled
        }
        XCTAssertTrue(automaticRestored)
        let (_, receiptClient) = try await makeProofClient(workspace: automatic)
        let receiptStatus = try await receiptClient.status(binding: lease.binding)
        XCTAssertEqual(receiptStatus.phase, .released)

        try await assertManualRetryBypassesScheduledDelay()
    }

    func testReceiptTransitionCrashesConvergeWithoutDuplicateRestore() async throws {
        for checkpoint in [
            SleepOverrideLeaseTransitionPoint.restoringPersisted,
            .baselineRestored,
            .restoredPersisted,
            SleepOverrideLeaseTransitionPoint.receiptPersisted,
            .receiptCommittedPersisted,
            .activeJournalRemoved
        ] {
            try await assertReceiptCrashRecovery(at: checkpoint)
        }
        try await assertCleanupRequiredCrashRecovery()
    }

    func testAuthorizationBindingsProtocolShapeAndMetacharactersCannotMutateOperation() async throws {
        let workspace = try LeaseProofWorkspace(baseline: false)
        defer { workspace.remove() }
        let helper = try launchHelper(workspace: workspace)
        defer { stopProcess(helper) }
        let (_, owner) = try await makeProofClient(workspace: workspace)
        let active = try await owner.acquire(sessionID: "exclusive", requestID: "request-exclusive")
        let writesBefore = writeTargets(in: try powerTrace(workspace))

        let (_, secondConnection) = try await makeProofClient(workspace: workspace)
        let concurrentError = await captureLeaseError {
            _ = try await secondConnection.acquire(sessionID: "second", requestID: "owner")
        }
        XCTAssertNotNil(concurrentError)
        let (_, otherPrincipal) = try await makeProofClient(workspace: workspace, credential: "owner-b")
        let principalError = await captureLeaseError {
            _ = try await otherPrincipal.release(binding: active.binding)
        }
        XCTAssertNotNil(principalError)
        let staleError = await captureLeaseError {
            _ = try await owner.release(binding: active.binding.replacing(leaseID: "stale"))
        }
        XCTAssertNotNil(staleError)
        XCTAssertEqual(writeTargets(in: try powerTrace(workspace)), writesBefore)
        _ = try await owner.release(binding: active.binding)

        try assertProductionXPCSelectorSurface()
        let malformedTraceCount = try powerTrace(workspace).count
        let malformedReceiptCount = try receiptFiles(workspace).count
        let malformedPower = try powerState(workspace)
        try await sendMalformedEnvelope(workspace: workspace)
        XCTAssertEqual(try powerTrace(workspace).count, malformedTraceCount)
        XCTAssertEqual(try receiptFiles(workspace).count, malformedReceiptCount)
        XCTAssertEqual(try powerState(workspace), malformedPower)
        XCTAssertNil(try activeJournal(workspace))
        let traceCount = try powerTrace(workspace).count
        let sentinel = workspace.rootURL.appendingPathComponent("injected")
        let session = "session;$(touch \(sentinel.path)) & 'quoted'"
        let request = "request | /usr/bin/false > \(sentinel.path)"
        let metacharLease = try await owner.acquire(sessionID: session, requestID: request)
        _ = try await owner.release(binding: metacharLease.binding)
        XCTAssertFalse(FileManager.default.fileExists(atPath: sentinel.path))
        let newEntries = Array(try powerTrace(workspace).dropFirst(traceCount))
        XCTAssertTrue(newEntries.allSatisfy {
            Set($0.arguments).isSubset(of: ["read", "write", "true", "false"])
        })
    }

    func testCoordinatorMapsDefinitiveUncertainAndNotFoundWithoutFalseCleanup() async throws {
        let definitive = try LeaseProofWorkspace(baseline: false)
        defer { definitive.remove() }
        let definitiveResult = await coordinator(
            workspace: definitive,
            transport: ScenarioLeaseTransport(mode: .definitiveAcquireFailure)
        ).start(configuration: TravelSessionConfiguration(wifiDevice: "en0"))
        XCTAssertEqual(definitiveResult.lifecycle, .off)
        XCTAssertFalse(FileManager.default.fileExists(atPath: definitive.appJournalURL.path))

        let uncertain = try LeaseProofWorkspace(baseline: false)
        defer { uncertain.remove() }
        let uncertainResult = await coordinator(
            workspace: uncertain,
            transport: ScenarioLeaseTransport(mode: .uncertainAcquireFailure)
        ).start(configuration: TravelSessionConfiguration(wifiDevice: "en0"))
        XCTAssertEqual(uncertainResult.lifecycle, .cleanupRequired)
        XCTAssertTrue(FileManager.default.fileExists(atPath: uncertain.appJournalURL.path))

        let notFound = try LeaseProofWorkspace(baseline: false)
        defer { notFound.remove() }
        try await seedAppJournal(notFound)
        let notFoundResult = await coordinator(
            workspace: notFound,
            transport: ScenarioLeaseTransport(mode: .authoritativeNotFound)
        ).recover()
        XCTAssertEqual(notFoundResult.lifecycle, .off)
        XCTAssertFalse(FileManager.default.fileExists(atPath: notFound.appJournalURL.path))

        let unavailable = try LeaseProofWorkspace(baseline: false)
        defer { unavailable.remove() }
        try await seedAppJournal(unavailable)
        let unavailableResult = await coordinator(
            workspace: unavailable,
            transport: ScenarioLeaseTransport(mode: .unavailableResolve)
        ).recover()
        XCTAssertEqual(unavailableResult.lifecycle, .cleanupRequired)
        XCTAssertTrue(FileManager.default.fileExists(atPath: unavailable.appJournalURL.path))
    }

    @MainActor
    func testProductionAppStopAndQuitClearJournalBeforeAcknowledgingReceipt() async throws {
        let workspace = try LeaseProofWorkspace(baseline: false)
        defer { workspace.remove() }
        let helper = try launchHelper(workspace: workspace)
        defer { stopProcess(helper) }
        let (_, client) = try await makeProofClient(workspace: workspace)
        let rawGateway = ProofAppGateway()
        let recorder = ProofSessionBoundaryRecorder()
        let sessionCoordinator = TravelSessionCoordinator(
            journalStore: FileTravelSessionJournalStore(fileURL: workspace.appJournalURL),
            system: GatewayTravelSessionSystemController(gateway: rawGateway),
            leaseClient: client,
            observer: recorder
        )
        let gateway = TransactionalTravelCommandGateway(
            rawGateway: rawGateway,
            sessionManager: sessionCoordinator
        )
        let app = TravelModeAppState(
            gateway: gateway,
            settingsStore: ProofSettingsStore(),
            sessionManager: sessionCoordinator
        )

        await app.start()
        XCTAssertTrue(app.isRunning)
        await app.stop()
        XCTAssertFalse(app.isRunning)
        XCTAssertFalse(FileManager.default.fileExists(atPath: workspace.appJournalURL.path))
        XCTAssertEqual(try receiptFiles(workspace).count, 0)

        await app.start()
        XCTAssertTrue(app.isRunning)
        let canQuit = await app.requestQuit()
        XCTAssertTrue(canQuit)
        XCTAssertFalse(app.isRunning)
        XCTAssertFalse(FileManager.default.fileExists(atPath: workspace.appJournalURL.path))
        XCTAssertEqual(try receiptFiles(workspace).count, 0)
        XCTAssertFalse(try powerState(workspace).sleepDisabled)

        let lifecycle = await sessionCoordinator.lifecycle()
        XCTAssertEqual(lifecycle, .off)
        let cleanupBoundaries = await recorder.snapshot().filter {
            [.leaseReleased, .journalCleared, .leaseAcknowledged].contains($0)
        }
        XCTAssertEqual(
            cleanupBoundaries,
            [
                .leaseReleased, .journalCleared, .leaseAcknowledged,
                .leaseReleased, .journalCleared, .leaseAcknowledged
            ]
        )
        let bindings = try transitionTrace(workspace)
            .filter { $0.point == .activePersisted }
            .map(\.binding)
        XCTAssertEqual(bindings.count, 2)
        for binding in bindings {
            try assertTransitionReceiptBeforeJournalRemoval(workspace, binding: binding)
        }
    }

    @MainActor
    func testProductionAppStateRevokesActiveAndStopsWorkWhenHelperDisappears() async throws {
        let workspace = try LeaseProofWorkspace(baseline: false)
        defer { workspace.remove() }
        var helper = try launchHelper(workspace: workspace)
        defer { stopProcess(helper) }
        let (_, client) = try await makeProofClient(workspace: workspace)
        let rawGateway = ProofAppGateway()
        let sessionCoordinator = TravelSessionCoordinator(
            journalStore: FileTravelSessionJournalStore(fileURL: workspace.appJournalURL),
            system: GatewayTravelSessionSystemController(gateway: rawGateway),
            leaseClient: client
        )
        let gateway = TransactionalTravelCommandGateway(
            rawGateway: rawGateway,
            sessionManager: sessionCoordinator
        )
        let app = TravelModeAppState(
            gateway: gateway,
            settingsStore: ProofSettingsStore(),
            sessionManager: sessionCoordinator
        )

        await app.start()
        XCTAssertTrue(app.isRunning)
        let activeLifecycle = await sessionCoordinator.lifecycle()
        XCTAssertEqual(activeLifecycle, .active)
        let beforeLoss = await rawGateway.snapshot()
        XCTAssertTrue(beforeLoss.keepAwake)

        stopProcess(helper)
        let appRevoked = try await waitForAppToStop(app)
        XCTAssertTrue(appRevoked)
        let afterLoss = await rawGateway.snapshot()
        XCTAssertFalse(afterLoss.keepAwake)
        XCTAssertTrue(app.latestStatus.localizedCaseInsensitiveContains("protection")
            || app.latestStatus.localizedCaseInsensitiveContains("cleanup"))
        let stoppedPollCount = afterLoss.statusReads
        try await Task.sleep(for: .milliseconds(1_200))
        let settledGateway = await rawGateway.snapshot()
        XCTAssertEqual(settledGateway.statusReads, stoppedPollCount)
        let lostLifecycle = await sessionCoordinator.lifecycle()
        XCTAssertEqual(lostLifecycle, .cleanupRequired)

        helper = try launchHelper(workspace: workspace)
        let helperReconciled = try await waitForHelperRestoration(workspace)
        XCTAssertTrue(helperReconciled)
        XCTAssertEqual(try receiptFiles(workspace).count, 1)
    }
}

private extension SleepOverrideLeaseProcessProofTests {
    func assertRestartRecovery(at checkpoint: String) async throws {
        let workspace = try LeaseProofWorkspace(baseline: false)
        defer { workspace.remove() }
        var helper = try launchHelper(workspace: workspace, checkpoint: checkpoint)
        defer { stopProcess(helper) }
        let owner = try launchOwner(
            workspace: workspace,
            scenario: "acquire-and-hold",
            sessionID: "crash-\(checkpoint)",
            requestID: "request-\(checkpoint)"
        )
        defer { stopProcess(owner) }
        let checkpointReached = try await waitForPath(
            workspace.checkpointMarkerURL,
            process: helper
        )
        XCTAssertTrue(checkpointReached)
        stopProcess(helper)
        stopProcess(owner)

        helper = try launchHelper(workspace: workspace)
        let startupRecovered = try await waitUntil {
            try activeJournal(workspace) == nil && !powerState(workspace).sleepDisabled
        }
        XCTAssertTrue(startupRecovered)
        let (_, recovering) = try await makeProofClient(workspace: workspace)
        let resolution = try await recovering.resolve(
            sessionID: "crash-\(checkpoint)",
            requestID: "request-\(checkpoint)"
        )
        if checkpoint == "before_service_dispatch" {
            XCTAssertEqual(resolution, .authoritativeNotFound)
        } else if case .found(let receipt) = resolution {
            XCTAssertEqual(receipt.phase, .released)
        } else {
            XCTFail("Persisted acquisition checkpoint did not resolve to its released receipt.")
        }
        let next = try await recovering.acquire(
            sessionID: "next-\(checkpoint)",
            requestID: "next-request-\(checkpoint)"
        )
        _ = try await recovering.release(binding: next.binding)
    }

    func assertRecoveryWhenOwnerDiesBeforeAcquireResponse() async throws {
        let workspace = try LeaseProofWorkspace(baseline: false)
        defer { workspace.remove() }
        let helper = try launchHelper(
            workspace: workspace,
            checkpoint: SleepOverrideLeaseTransitionPoint.activePersisted.rawValue,
            usesGate: true
        )
        defer { stopProcess(helper) }
        let owner = try launchOwner(
            workspace: workspace,
            scenario: "acquire-and-hold",
            sessionID: "lost-response",
            requestID: "request-lost-response"
        )
        defer { stopProcess(owner) }
        let checkpointReached = try await waitForPath(
            workspace.checkpointMarkerURL,
            process: helper
        )
        XCTAssertTrue(checkpointReached)
        stopProcess(owner)
        try Data("continue\n".utf8).write(to: workspace.checkpointGateURL, options: .atomic)
        let releasedAfterLostResponse = try await waitUntil {
            try activeJournal(workspace) == nil && receiptFiles(workspace).count == 1
        }
        XCTAssertTrue(releasedAfterLostResponse)
        let (_, recovering) = try await makeProofClient(workspace: workspace)
        let resolution = try await recovering.resolve(
            sessionID: "lost-response",
            requestID: "request-lost-response"
        )
        guard case .found(let receipt) = resolution else {
            return XCTFail("Lost acquisition response was not exactly recoverable.")
        }
        XCTAssertEqual(receipt.phase, .released)
    }

    func assertManualRetryBypassesScheduledDelay() async throws {
        let workspace = try LeaseProofWorkspace(baseline: false)
        defer { workspace.remove() }
        let helper = try launchHelper(workspace: workspace)
        defer { stopProcess(helper) }
        let (transport, client) = try await makeProofClient(workspace: workspace)
        let lease = try await client.acquire(sessionID: "retry", requestID: "manual")
        try writeJSON(
            ProofPowerControl(failWritesRemaining: 1),
            to: workspace.powerControlURL
        )
        transport.closeOwnerConnection()
        let cleanupPersisted = try await waitUntil {
            try activeJournal(workspace)?.phase == .cleanupRequired
        }
        XCTAssertTrue(cleanupPersisted)
        XCTAssertEqual(try clockDelays(workspace).first, 250)
        try writeJSON(ProofPowerControl(), to: workspace.powerControlURL)
        let (_, retrying) = try await makeProofClient(workspace: workspace)
        let released = try await retrying.retryCleanup(binding: lease.binding)
        XCTAssertEqual(released.phase, .released)
        XCTAssertFalse(try powerState(workspace).sleepDisabled)
        XCTAssertEqual(try clockDelays(workspace), [250])
    }

    func assertReceiptCrashRecovery(
        at checkpoint: SleepOverrideLeaseTransitionPoint
    ) async throws {
        let workspace = try LeaseProofWorkspace(baseline: false)
        defer { workspace.remove() }
        var helper = try launchHelper(
            workspace: workspace,
            checkpoint: checkpoint.rawValue
        )
        defer { stopProcess(helper) }
        let (transport, client) = try await makeProofClient(workspace: workspace)
        let acquired = try await client.acquire(
            sessionID: "receipt-\(checkpoint.rawValue)",
            requestID: "request-receipt-\(checkpoint.rawValue)"
        )
        let release = Task { try await client.release(binding: acquired.binding) }
        let checkpointReached = try await waitForPath(
            workspace.checkpointMarkerURL,
            process: helper
        )
        XCTAssertTrue(checkpointReached)
        stopProcess(helper)
        transport.closeOwnerConnection()
        _ = try? await release.value

        helper = try launchHelper(workspace: workspace)
        let startupRecovered = try await waitUntil {
            try activeJournal(workspace) == nil && receiptFiles(workspace).count == 1
        }
        XCTAssertTrue(startupRecovered)
        XCTAssertEqual(writeTargets(in: try powerTrace(workspace)), [true, false])
        let (_, recovering) = try await makeProofClient(workspace: workspace)
        let status = try await recovering.status(binding: acquired.binding)
        XCTAssertEqual(status.phase, .released)
    }

    func assertCleanupRequiredCrashRecovery() async throws {
        let workspace = try LeaseProofWorkspace(baseline: false)
        defer { workspace.remove() }
        var helper = try launchHelper(
            workspace: workspace,
            checkpoint: SleepOverrideLeaseTransitionPoint.cleanupRequiredPersisted.rawValue
        )
        defer { stopProcess(helper) }
        let (transport, client) = try await makeProofClient(workspace: workspace)
        let acquired = try await client.acquire(
            sessionID: "cleanup-required-crash",
            requestID: "request-cleanup-required-crash"
        )
        try writeJSON(
            ProofPowerControl(failWritesRemaining: 1),
            to: workspace.powerControlURL
        )
        let release = Task { try await client.release(binding: acquired.binding) }
        let checkpointReached = try await waitForPath(
            workspace.checkpointMarkerURL,
            process: helper
        )
        XCTAssertTrue(checkpointReached)
        let journalAtCrash = try activeJournal(workspace)
        XCTAssertEqual(journalAtCrash?.phase, .cleanupRequired)
        stopProcess(helper)
        transport.closeOwnerConnection()
        _ = try? await release.value
        try writeJSON(ProofPowerControl(), to: workspace.powerControlURL)

        helper = try launchHelper(workspace: workspace)
        let startupRecovered = try await waitForHelperRestoration(workspace)
        XCTAssertTrue(startupRecovered)
        let (_, recovering) = try await makeProofClient(workspace: workspace)
        let status = try await recovering.status(binding: acquired.binding)
        XCTAssertEqual(status.phase, .released)
    }
}

private extension SleepOverrideLeaseProcessProofTests {
    func coordinator(
        workspace: LeaseProofWorkspace,
        transport: ScenarioLeaseTransport
    ) -> TravelSessionCoordinator {
        let gateway = ProofAppGateway()
        return TravelSessionCoordinator(
            journalStore: FileTravelSessionJournalStore(fileURL: workspace.appJournalURL),
            system: GatewayTravelSessionSystemController(gateway: gateway),
            leaseClient: TransportSleepOverrideLeaseClient(transport: transport)
        )
    }

    func seedAppJournal(_ workspace: LeaseProofWorkspace) async throws {
        let store = FileTravelSessionJournalStore(fileURL: workspace.appJournalURL)
        _ = try await store.create(
            TravelSessionJournal(
                sessionID: "app-session",
                wifiBaseline: TravelWiFiBaseline(
                    device: "en0",
                    powerEnabled: true,
                    associatedSSID: "Office"
                ),
                leaseRequestID: "app-request"
            )
        )
    }

    func captureLeaseError(
        _ operation: () async throws -> Void
    ) async -> SleepOverrideLeaseError? {
        do {
            try await operation()
            XCTFail("Expected a structured sleep-override lease failure.")
            return nil
        } catch let error as SleepOverrideLeaseError {
            return error
        } catch {
            XCTFail("Expected SleepOverrideLeaseError, got \(error).")
            return nil
        }
    }

    func captureTransportError(
        _ operation: () async throws -> Void
    ) async -> SleepOverrideLeaseTransportError? {
        do {
            try await operation()
            XCTFail("Expected a structured sleep-override transport failure.")
            return nil
        } catch let error as SleepOverrideLeaseTransportError {
            return error
        } catch {
            XCTFail("Expected SleepOverrideLeaseTransportError, got \(error).")
            return nil
        }
    }

    func assertReceiptCommittedBeforeJournalRemoval(
        _ workspace: LeaseProofWorkspace,
        binding: SleepOverrideLeaseBinding,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let relevant = try transitionTrace(workspace).filter { $0.binding == binding }
        let points = relevant.map(\.point)
        guard let receipt = points.firstIndex(of: .receiptPersisted),
              let removed = points.firstIndex(of: .activeJournalRemoved) else {
            XCTFail("Missing receipt/journal transition evidence.", file: file, line: line)
            return
        }
        XCTAssertLessThan(receipt, removed, file: file, line: line)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: workspace.activeJournalURL.path),
            file: file,
            line: line
        )
        XCTAssertTrue(
            try receiptFiles(workspace).contains { url in
                try decodeStoredReceipt(at: url).binding == binding
            },
            file: file,
            line: line
        )
    }

    func assertTransitionReceiptBeforeJournalRemoval(
        _ workspace: LeaseProofWorkspace,
        binding: SleepOverrideLeaseBinding,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let points = try transitionTrace(workspace)
            .filter { $0.binding == binding }
            .map(\.point)
        guard let receipt = points.firstIndex(of: .receiptPersisted),
              let removed = points.firstIndex(of: .activeJournalRemoved) else {
            XCTFail("Missing receipt/journal transition evidence.", file: file, line: line)
            return
        }
        XCTAssertLessThan(receipt, removed, file: file, line: line)
    }

    func assertProductionXPCSelectorSurface(
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        var count: UInt32 = 0
        guard let descriptions = protocol_copyMethodDescriptionList(
            SleepOverrideLeaseXPCProtocol.self,
            true,
            true,
            &count
        ) else {
            return XCTFail("Could not inspect the production XPC protocol.", file: file, line: line)
        }
        defer { free(descriptions) }
        let selectors = (0..<Int(count)).compactMap { index -> String? in
            guard let selector = descriptions[index].name else { return nil }
            return NSStringFromSelector(selector)
        }
        XCTAssertEqual(
            Set(selectors),
            Set([
                "acquireWithSessionID:requestID:reply:",
                "resolveWithSessionID:requestID:reply:",
                "statusWithBinding:reply:",
                "releaseWithBinding:reply:",
                "acknowledgeReleaseWithBinding:reply:",
                "retryCleanupWithBinding:reply:"
            ]),
            file: file,
            line: line
        )
        let forbidden = ["pid", "principal", "command", "path", "executable"]
        XCTAssertFalse(
            selectors.contains { selector in
                forbidden.contains { selector.localizedCaseInsensitiveContains($0) }
            },
            file: file,
            line: line
        )
    }

    func sendMalformedEnvelope(workspace: LeaseProofWorkspace) async throws {
        let socket = try ProofUnixSocket(connectingTo: workspace.socketURL.path)
        defer { socket.close() }
        let authentication = try await socket.request(
            ProofLeaseRequest(operation: .authenticate, credential: "owner-a")
        )
        XCTAssertEqual(authentication.outcome, .acknowledged)
        let descriptor = try socket.rawDescriptor()
        let payload = Data("{\"correlation_id\":\"bad\",\"operation\":\"run_command\",\"command\":\"pmset\"}\n".utf8)
        _ = payload.withUnsafeBytes { bytes in
            Darwin.send(descriptor, bytes.baseAddress, bytes.count, 0)
        }
        try await Task.sleep(for: .milliseconds(50))
    }

    func expectedClockTraceCount(after delay: Int) -> Int {
        switch delay {
        case 250: 2
        case 500: 3
        case 1_000: 4
        default: 5
        }
    }
}

private func makeProofClient(
    workspace: LeaseProofWorkspace,
    credential: String = "owner-a"
) async throws -> (ProofSocketLeaseTransport, TransportSleepOverrideLeaseClient) {
    let transport = try await ProofSocketLeaseTransport(
        socketPath: workspace.socketURL.path,
        credential: credential
    )
    return (transport, TransportSleepOverrideLeaseClient(transport: transport))
}

private struct LeaseProofWorkspace: Sendable {
    let rootURL: URL
    let stateRootURL: URL
    let socketURL: URL
    let powerStateURL: URL
    let powerTraceURL: URL
    let powerControlURL: URL
    let transitionTraceURL: URL
    let clockTraceURL: URL
    let checkpointMarkerURL: URL
    let checkpointGateURL: URL
    let ownerArtifactURL: URL
    let ownerMarkerURL: URL
    let appJournalURL: URL

    init(baseline: Bool) throws {
        rootURL = URL(
            fileURLWithPath: "/tmp/ctl-\(UUID().uuidString.prefix(12))",
            isDirectory: true
        )
        stateRootURL = rootURL.appendingPathComponent("lease", isDirectory: true)
        socketURL = rootURL.appendingPathComponent("helper.sock")
        powerStateURL = rootURL.appendingPathComponent("power.json")
        powerTraceURL = rootURL.appendingPathComponent("power-trace.jsonl")
        powerControlURL = rootURL.appendingPathComponent("power-control.json")
        transitionTraceURL = rootURL.appendingPathComponent("transitions.jsonl")
        clockTraceURL = rootURL.appendingPathComponent("clock.txt")
        checkpointMarkerURL = rootURL.appendingPathComponent("checkpoint.json")
        checkpointGateURL = rootURL.appendingPathComponent("checkpoint-gate")
        ownerArtifactURL = rootURL.appendingPathComponent("owner.json")
        ownerMarkerURL = rootURL.appendingPathComponent("owner-ready")
        appJournalURL = rootURL.appendingPathComponent("app-journal.json")
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: stateRootURL,
            withIntermediateDirectories: false
        )
        guard Darwin.chmod(stateRootURL.path, 0o700) == 0,
              Darwin.chown(stateRootURL.path, geteuid(), getegid()) == 0 else {
            throw ProofLeaseSupportError.invalidArguments(
                "Could not establish safe ownership for the proof lease store."
            )
        }
        try writeJSON(ProofPowerState(sleepDisabled: baseline), to: powerStateURL)
        try writeJSON(ProofPowerControl(), to: powerControlURL)
    }

    var activeJournalURL: URL {
        stateRootURL.appendingPathComponent("active-lease.json")
    }

    var receiptsURL: URL {
        stateRootURL.appendingPathComponent("released-receipts", isDirectory: true)
    }

    func remove() {
        try? FileManager.default.removeItem(at: rootURL)
    }
}

private func launchHelper(
    workspace: LeaseProofWorkspace,
    checkpoint: String? = nil,
    usesGate: Bool = false
) throws -> Process {
    try? FileManager.default.removeItem(at: workspace.socketURL)
    let process = Process()
    process.executableURL = try requiredExecutable("SLEEP_OVERRIDE_LEASE_PROOF_HELPER")
    var arguments = [
        "--socket", workspace.socketURL.path,
        "--state-root", workspace.stateRootURL.path,
        "--power-executable", try requiredExecutable("SLEEP_OVERRIDE_LEASE_FAKE_POWER").path,
        "--power-state", workspace.powerStateURL.path,
        "--power-trace", workspace.powerTraceURL.path,
        "--power-control", workspace.powerControlURL.path,
        "--transition-trace", workspace.transitionTraceURL.path,
        "--clock-trace", workspace.clockTraceURL.path
    ]
    if let checkpoint {
        arguments += [
            "--checkpoint", checkpoint,
            "--checkpoint-marker", workspace.checkpointMarkerURL.path
        ]
        if usesGate {
            arguments += ["--checkpoint-gate", workspace.checkpointGateURL.path]
        }
    }
    process.arguments = arguments
    let output = Pipe()
    let errors = Pipe()
    process.standardOutput = output
    process.standardError = errors
    try process.run()
    guard waitForPathSynchronously(workspace.socketURL, process: process) else {
        stopProcess(process)
        let detail = String(
            decoding: errors.fileHandleForReading.readDataToEndOfFile(),
            as: UTF8.self
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        throw ProofLeaseSupportError.invalidArguments(
            detail.isEmpty ? "Proof helper exited before opening its socket." : detail
        )
    }
    return process
}

private func launchOwner(
    workspace: LeaseProofWorkspace,
    scenario: String,
    sessionID: String,
    requestID: String,
    credential: String = "owner-a"
) throws -> Process {
    let process = Process()
    process.executableURL = try requiredExecutable("SLEEP_OVERRIDE_LEASE_PROOF_OWNER")
    process.arguments = [
        "--scenario", scenario,
        "--socket", workspace.socketURL.path,
        "--credential", credential,
        "--session", sessionID,
        "--request", requestID,
        "--artifact", workspace.ownerArtifactURL.path,
        "--marker", workspace.ownerMarkerURL.path
    ]
    process.standardOutput = Pipe()
    process.standardError = Pipe()
    try process.run()
    return process
}

private func requiredExecutable(_ variable: String) throws -> URL {
    guard let path = ProcessInfo.processInfo.environment[variable] else {
        throw ProofLeaseSupportError.invalidArguments("\(variable) is required by the process proof.")
    }
    let url = URL(fileURLWithPath: path)
    guard FileManager.default.isExecutableFile(atPath: url.path) else {
        throw ProofLeaseSupportError.invalidArguments("\(variable) is not executable: \(path)")
    }
    return url
}

private func stopProcess(
    _ process: Process,
    file: StaticString = #filePath,
    line: UInt = #line
) {
    let processID = process.processIdentifier
    let result = kill(processID, SIGKILL)
    if result != 0 {
        guard errno != ESRCH else { return }
        XCTFail(
            "Could not stop proof process \(processID): \(String(cString: strerror(errno)))",
            file: file,
            line: line
        )
        return
    }
    var status: Int32 = 0
    let deadline = Date().addingTimeInterval(3)
    while Date() < deadline {
        let waited = Darwin.waitpid(processID, &status, WNOHANG)
        if waited == processID { return }
        if waited == -1 {
            if errno == ECHILD || errno == ESRCH { return }
            if errno != EINTR {
                XCTFail(
                    "Could not reap proof process \(processID): \(String(cString: strerror(errno)))",
                    file: file,
                    line: line
                )
                return
            }
        }
        Thread.sleep(forTimeInterval: 0.01)
    }
    XCTFail(
        "Proof process \(processID) did not exit within three seconds of SIGKILL.",
        file: file,
        line: line
    )
}

private func waitForPathSynchronously(
    _ url: URL,
    process: Process,
    timeout: TimeInterval = 3
) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if FileManager.default.fileExists(atPath: url.path) { return true }
        if !proofProcessExists(process) { return false }
        Thread.sleep(forTimeInterval: 0.01)
    }
    return false
}

private func waitForPath(
    _ url: URL,
    process: Process,
    timeout: TimeInterval = 4
) async throws -> Bool {
    try await waitUntil(timeout: timeout) {
        FileManager.default.fileExists(atPath: url.path) || !proofProcessExists(process)
    } && FileManager.default.fileExists(atPath: url.path)
}

private func proofProcessExists(_ process: Process) -> Bool {
    let result = kill(process.processIdentifier, 0)
    return result == 0 || errno == EPERM
}

private func waitUntil(
    timeout: TimeInterval = 4,
    condition: () throws -> Bool
) async throws -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if try condition() { return true }
        try await Task.sleep(for: .milliseconds(10))
    }
    return try condition()
}

@MainActor
private func waitForAppToStop(
    _ app: TravelModeAppState,
    timeout: TimeInterval = 4
) async throws -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if !app.isRunning { return true }
        try await Task.sleep(for: .milliseconds(10))
    }
    return !app.isRunning
}

private func waitForHelperRestoration(
    _ workspace: LeaseProofWorkspace
) async throws -> Bool {
    try await waitUntil {
        try activeJournal(workspace) == nil && !powerState(workspace).sleepDisabled
    }
}

private func powerState(_ workspace: LeaseProofWorkspace) throws -> ProofPowerState {
    try decode(ProofPowerState.self, at: workspace.powerStateURL)
}

private func powerTrace(
    _ workspace: LeaseProofWorkspace
) throws -> [ProofPowerTraceEntry] {
    try decodeJSONLines(ProofPowerTraceEntry.self, at: workspace.powerTraceURL)
}

private func transitionTrace(
    _ workspace: LeaseProofWorkspace
) throws -> [ProofLeaseTransitionArtifact] {
    try decodeJSONLines(ProofLeaseTransitionArtifact.self, at: workspace.transitionTraceURL)
}

private func clockDelays(_ workspace: LeaseProofWorkspace) throws -> [Int] {
    guard FileManager.default.fileExists(atPath: workspace.clockTraceURL.path) else { return [] }
    return try String(contentsOf: workspace.clockTraceURL, encoding: .utf8)
        .split(whereSeparator: \.isNewline)
        .compactMap { Int($0) }
}

private func activeJournal(
    _ workspace: LeaseProofWorkspace
) throws -> SleepOverrideLeaseJournal? {
    guard FileManager.default.fileExists(atPath: workspace.activeJournalURL.path) else {
        return nil
    }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .secondsSince1970
    return try decoder.decode(
        SleepOverrideLeaseJournal.self,
        from: Data(contentsOf: workspace.activeJournalURL)
    )
}

private func receiptFiles(_ workspace: LeaseProofWorkspace) throws -> [URL] {
    guard FileManager.default.fileExists(atPath: workspace.receiptsURL.path) else { return [] }
    return try FileManager.default.contentsOfDirectory(
        at: workspace.receiptsURL,
        includingPropertiesForKeys: nil
    ).filter { $0.pathExtension == "json" }
}

private func recursiveJSONKeys(at url: URL) throws -> Set<String> {
    let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url))
    return recursiveJSONKeys(in: object)
}

private func recursiveJSONKeys(in value: Any) -> Set<String> {
    if let dictionary = value as? [String: Any] {
        return dictionary.reduce(into: Set(dictionary.keys)) { keys, entry in
            keys.formUnion(recursiveJSONKeys(in: entry.value))
        }
    }
    if let array = value as? [Any] {
        return array.reduce(into: Set<String>()) { keys, element in
            keys.formUnion(recursiveJSONKeys(in: element))
        }
    }
    return []
}

private func decodeStoredReceipt(at url: URL) throws -> SleepOverrideLeaseStoredReceipt {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .secondsSince1970
    return try decoder.decode(SleepOverrideLeaseStoredReceipt.self, from: Data(contentsOf: url))
}

private func writeTargets(in trace: [ProofPowerTraceEntry]) -> [Bool] {
    trace.filter { $0.operation == "write" }.compactMap(\.requestedValue)
}

private func decode<Value: Decodable>(_ type: Value.Type, at url: URL) throws -> Value {
    try JSONDecoder().decode(type, from: Data(contentsOf: url))
}

private func decodeJSONLines<Value: Decodable>(
    _ type: Value.Type,
    at url: URL
) throws -> [Value] {
    guard FileManager.default.fileExists(atPath: url.path) else { return [] }
    return try Data(contentsOf: url).split(separator: 0x0A).map {
        try JSONDecoder().decode(type, from: Data($0))
    }
}

private func writeJSON<Value: Encodable>(_ value: Value, to url: URL) throws {
    try JSONEncoder().encode(value).write(to: url, options: .atomic)
}

private extension SleepOverrideLeaseBinding {
    func replacing(
        sessionID: String? = nil,
        requestID: String? = nil,
        leaseID: String? = nil,
        generation: String? = nil
    ) -> Self {
        SleepOverrideLeaseBinding(
            sessionID: sessionID ?? self.sessionID,
            requestID: requestID ?? self.requestID,
            leaseID: leaseID ?? self.leaseID,
            generation: generation ?? self.generation
        )
    }

    func singleFieldMismatches() -> [Self] {
        [
            replacing(sessionID: "mismatched-session"),
            replacing(requestID: "mismatched-request"),
            replacing(leaseID: "mismatched-lease"),
            replacing(generation: "mismatched-generation")
        ]
    }
}

private final class ScenarioLeaseTransport: SleepOverrideLeaseTransport, @unchecked Sendable {
    enum Mode: Sendable {
        case definitiveAcquireFailure
        case uncertainAcquireFailure
        case authoritativeNotFound
        case unavailableResolve
    }

    let mode: Mode

    init(mode: Mode) {
        self.mode = mode
    }

    func acquire(
        _ request: SleepOverrideLeaseAcquireRequest
    ) async throws -> SleepOverrideLeaseTransportReply {
        switch mode {
        case .definitiveAcquireFailure:
            throw SleepOverrideLeaseTransportError.helperUnavailable(.definitelyNotSent)
        case .uncertainAcquireFailure:
            throw SleepOverrideLeaseTransportError.interruptedAfterPossibleDispatch
        case .authoritativeNotFound, .unavailableResolve:
            throw SleepOverrideLeaseTransportError.invalidResponse("Unexpected acquire.")
        }
    }

    func resolve(
        _ request: SleepOverrideLeaseAcquireRequest
    ) async throws -> SleepOverrideLeaseTransportReply {
        switch mode {
        case .authoritativeNotFound:
            return .authoritativeNotFound
        case .unavailableResolve:
            throw SleepOverrideLeaseTransportError.helperUnavailable(.mayHaveReachedHelper)
        case .definitiveAcquireFailure, .uncertainAcquireFailure:
            throw SleepOverrideLeaseTransportError.invalidResponse("Unexpected resolve.")
        }
    }

    func status(
        _ request: SleepOverrideLeaseBindingRequest
    ) async throws -> SleepOverrideLeaseTransportReply {
        throw SleepOverrideLeaseTransportError.invalidResponse("Unexpected status.")
    }

    func release(
        _ request: SleepOverrideLeaseBindingRequest
    ) async throws -> SleepOverrideLeaseTransportReply {
        throw SleepOverrideLeaseTransportError.invalidResponse("Unexpected release.")
    }

    func acknowledgeRelease(
        _ request: SleepOverrideLeaseBindingRequest
    ) async throws -> SleepOverrideLeaseTransportReply {
        throw SleepOverrideLeaseTransportError.invalidResponse("Unexpected acknowledgement.")
    }

    func retryCleanup(
        _ request: SleepOverrideLeaseBindingRequest
    ) async throws -> SleepOverrideLeaseTransportReply {
        throw SleepOverrideLeaseTransportError.invalidResponse("Unexpected retry.")
    }

    func protectionEvents() -> AsyncStream<SleepOverrideLeaseProtectionEvent> {
        AsyncStream { $0.finish() }
    }
}

private actor ProofSessionBoundaryRecorder: TravelSessionBoundaryObserving {
    private var boundaries: [TravelSessionBoundary] = []

    func reached(
        _ boundary: TravelSessionBoundary,
        sessionID: String?,
        value: String?
    ) async {
        boundaries.append(boundary)
    }

    func snapshot() -> [TravelSessionBoundary] {
        boundaries
    }
}

private actor ProofAppGateway: TravelCommandGateway {
    struct Snapshot: Sendable {
        var keepAwake: Bool
        var statusReads: Int
    }

    private var keepAwake = false
    private var statusReads = 0
    private var wifiPower = true
    private var ssid: String? = "Office"

    func snapshot() -> Snapshot {
        Snapshot(keepAwake: keepAwake, statusReads: statusReads)
    }

    func startKeepAwake() async throws {
        keepAwake = true
    }

    func stopKeepAwake() async {
        keepAwake = false
    }

    func currentLidClosed() async -> Bool? {
        false
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
        statusReads += 1
        let output = ssid.map { "Current Wi-Fi Network: \($0)" }
            ?? "You are not associated with a Wi-Fi network."
        return WiFiStatus(device: device, networkName: ssid, rawOutput: output)
    }

    func currentWiFiPower(device: String) async -> Bool? {
        wifiPower
    }

    func setWiFiPower(device: String, enabled: Bool) async -> CommandResult {
        wifiPower = enabled
        return CommandResult(exitCode: 0)
    }

    func joinWiFi(device: String, ssid: String, password: String?) async -> CommandResult {
        self.ssid = ssid
        return CommandResult(exitCode: 0)
    }

    func openWiFiSettings() async {}

    func isCodexRunning() async -> Bool {
        true
    }
}

private struct ProofSettingsStore: TravelSettingsStoring, Sendable {
    func load() -> TravelModeSettings {
        TravelModeSettings(hotspotSSID: "iPhone", hotspotPassword: "", wifiDevice: "en0")
    }

    func hasSavedHotspotPassword() -> Bool {
        true
    }

    func loadHotspotPassword() throws -> String {
        "proof-password"
    }

    func loadHotspotPassword(credentialReference: String) throws -> String {
        try loadHotspotPassword()
    }

    func save(_ settings: TravelModeSettings) throws {}

    func activeHotspotConfiguration() throws -> HotspotConfigurationRevision? {
        try HotspotConfigurationRevision(
            revisionID: "sleep-lease-proof-revision",
            ssid: "iPhone",
            wifiDevice: "en0",
            credentialReference: "sleep-lease-proof-credential"
        )
    }
}
