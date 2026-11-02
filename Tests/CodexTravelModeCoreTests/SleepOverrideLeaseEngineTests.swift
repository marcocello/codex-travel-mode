import CodexTravelModeCore
import Darwin
import Foundation
import XCTest

final class SleepOverrideLeaseEngineTests: XCTestCase {
    func testProductionStorageProfilePinsRootWheelAndRejectsUnsafeMetadata() {
        let profile = FileSleepOverrideLeaseStateStore.productionSecurityProfile

        XCTAssertEqual(profile.owner, 0)
        XCTAssertEqual(profile.group, 0)
        XCTAssertEqual(profile.expectedMode(for: S_IFDIR), 0o750)
        XCTAssertEqual(profile.expectedMode(for: S_IFREG), 0o600)
        XCTAssertNil(profile.expectedMode(for: S_IFLNK))
        XCTAssertTrue(profile.owns(userID: 0, groupID: 0))
        XCTAssertFalse(profile.owns(userID: 501, groupID: 0))
        XCTAssertFalse(profile.owns(userID: 0, groupID: 20))
        XCTAssertNotEqual(profile.expectedMode(for: S_IFDIR), 0o755)
        XCTAssertNotEqual(profile.expectedMode(for: S_IFREG), 0o644)
    }

    func testAcquireReleaseAndReceiptOperationsAreExactAndIdempotent() async throws {
        let store = LeaseMemoryStore()
        let power = LeaseTestPowerBackend(initialValue: false)
        let clock = LeaseRecordingClock()
        let service = SleepOverrideLeaseService(store: store, powerBackend: power, clock: clock)
        let context = makeContext(connection: "owner-a")

        let acquired = try await service.acquire(
            sessionID: "session;safe",
            requestID: "request/also-safe",
            context: context
        )
        XCTAssertEqual(acquired.phase, .active)
        let duplicate = try await service.acquire(
            sessionID: "session;safe",
            requestID: "request/also-safe",
            context: makeContext(connection: "replacement-connection")
        )
        XCTAssertEqual(duplicate, acquired)
        let acquireWrites = await power.successfulWrites()
        XCTAssertEqual(acquireWrites, [true])

        await assertSleepLeaseError(.rejected("")) {
            _ = try await service.acquire(
                sessionID: "other-session",
                requestID: "other-request",
                context: context
            )
        }

        let released = try await service.release(binding: acquired.binding, context: context)
        XCTAssertEqual(released.phase, .released)
        let duplicateRelease = try await service.release(
            binding: acquired.binding,
            context: context
        )
        XCTAssertEqual(duplicateRelease, released)
        let releaseWrites = await power.successfulWrites()
        XCTAssertEqual(releaseWrites, [true, false])
        let releasedStatus = try await service.status(binding: acquired.binding, context: context)
        XCTAssertEqual(releasedStatus, released)

        try await service.acknowledgeRelease(binding: acquired.binding, context: context)
        await assertSleepLeaseError(.invalidReceipt) {
            _ = try await service.status(binding: acquired.binding, context: context)
        }
    }

    func testEnabledBaselinePerformsNoAcquireWriteAndRestoresLaterDrift() async throws {
        let store = LeaseMemoryStore()
        let power = LeaseTestPowerBackend(initialValue: true)
        let service = SleepOverrideLeaseService(store: store, powerBackend: power)
        let context = makeContext(connection: "owner-enabled")

        let acquired = try await service.acquire(
            sessionID: "enabled-session",
            requestID: "enabled-request",
            context: context
        )
        let acquireWrites = await power.successfulWrites()
        XCTAssertTrue(acquireWrites.isEmpty)

        await power.simulateExternalDrift(to: false)
        let released = try await service.release(binding: acquired.binding, context: context)

        XCTAssertEqual(released.phase, .released)
        let finalValue = await power.currentValue()
        let writes = await power.successfulWrites()
        XCTAssertTrue(finalValue)
        XCTAssertEqual(writes, [true])
    }

    func testOwnerConnectionInvalidationRestoresAndLeavesExactReceipt() async throws {
        let store = LeaseMemoryStore()
        let power = LeaseTestPowerBackend(initialValue: false)
        let service = SleepOverrideLeaseService(store: store, powerBackend: power)
        let context = makeContext(connection: "connection-that-dies")
        let acquired = try await service.acquire(
            sessionID: "owner-death-session",
            requestID: "owner-death-request",
            context: context
        )

        await service.connectionInvalidated(id: SleepOverrideLeaseConnectionID(rawValue: "other"))
        let stillActive = try await service.status(binding: acquired.binding, context: context)
        XCTAssertEqual(stillActive.phase, .active)

        await service.connectionInvalidated(id: context.connectionID)
        let status = try await service.status(binding: acquired.binding, context: context)

        XCTAssertEqual(status, SleepOverrideLeaseReceipt(phase: .released, binding: acquired.binding))
        let finalValue = await power.currentValue()
        let finalJournal = await store.journalSnapshot()
        let receiptCount = await store.receiptCount()
        XCTAssertFalse(finalValue)
        XCTAssertNil(finalJournal)
        XCTAssertEqual(receiptCount, 1)
    }

    func testInvalidationBeforeAcquireCannotActivateDeadConnection() async throws {
        let store = LeaseMemoryStore()
        let power = LeaseTestPowerBackend(initialValue: false)
        let service = SleepOverrideLeaseService(store: store, powerBackend: power)
        let context = makeContext(connection: "already-invalidated")

        await service.connectionInvalidated(id: context.connectionID)
        await assertSleepLeaseError(.rejected("")) {
            _ = try await service.acquire(
                sessionID: "late-session",
                requestID: "late-request",
                context: context
            )
        }

        let journal = await store.journalSnapshot()
        let writes = await power.successfulWrites()
        let powerValue = await power.currentValue()
        XCTAssertNil(journal)
        XCTAssertTrue(writes.isEmpty)
        XCTAssertFalse(powerValue)
    }

    func testDifferentPrincipalAndEveryStaleBindingRemainMutationFree() async throws {
        let store = LeaseMemoryStore()
        let power = LeaseTestPowerBackend(initialValue: false)
        let service = SleepOverrideLeaseService(store: store, powerBackend: power)
        let owner = makeContext(connection: "exact-owner")
        let acquired = try await service.acquire(
            sessionID: "exact-session",
            requestID: "exact-request",
            context: owner
        )
        let stranger = SleepOverrideLeaseCallContext(
            principal: SleepOverrideLeaseCallerPrincipal(
                bundleIdentifier: "com.codex.travelmode",
                teamIdentifier: "OTHERTEAM",
                effectiveUserID: 501
            ),
            connectionID: SleepOverrideLeaseConnectionID(rawValue: "stranger")
        )

        await assertSleepLeaseError(.rejected("")) {
            _ = try await service.release(binding: acquired.binding, context: stranger)
        }
        for stale in staleBindings(from: acquired.binding) {
            await assertSleepLeaseError(.invalidReceipt) {
                _ = try await service.status(binding: stale, context: owner)
            }
        }
        let writesBeforeRelease = await power.successfulWrites()
        XCTAssertEqual(writesBeforeRelease, [true])

        _ = try await service.release(binding: acquired.binding, context: owner)
        for stale in staleBindings(from: acquired.binding) {
            await assertSleepLeaseError(.invalidReceipt) {
                try await service.acknowledgeRelease(binding: stale, context: owner)
            }
        }
        let exactReceipt = await store.receiptSnapshot(binding: acquired.binding)
        let writesAfterRelease = await power.successfulWrites()
        XCTAssertNotNil(exactReceipt)
        XCTAssertEqual(writesAfterRelease, [true, false])
    }

    func testFailedAcquireCompensatesButStillFailsAndResolvesReleasedReceipt() async throws {
        let store = LeaseMemoryStore()
        let power = LeaseTestPowerBackend(initialValue: false)
        await power.failReads(numbered: [2])
        let service = SleepOverrideLeaseService(store: store, powerBackend: power)
        let context = makeContext(connection: "interrupted-acquire")

        await assertSleepLeaseError(.interruptedAfterPossibleDispatch) {
            _ = try await service.acquire(
                sessionID: "interrupted-session",
                requestID: "interrupted-request",
                context: context
            )
        }
        let resolution = try await service.resolve(
            sessionID: "interrupted-session",
            requestID: "interrupted-request",
            context: context
        )

        guard case .found(let receipt) = resolution else {
            return XCTFail("Compensated acquisition was not durably resolvable.")
        }
        XCTAssertEqual(receipt.phase, .released)
        let finalValue = await power.currentValue()
        let writes = await power.successfulWrites()
        XCTAssertFalse(finalValue)
        XCTAssertEqual(writes, [true, false])
    }

    func testReceiptWriteBeforeJournalAdvanceReconcilesWithoutSecondPowerWrite() async throws {
        let store = LeaseMemoryStore()
        let power = LeaseTestPowerBackend(initialValue: false)
        let clock = LeaseRecordingClock()
        let firstService = SleepOverrideLeaseService(
            store: store,
            powerBackend: power,
            clock: clock
        )
        let context = makeContext(connection: "receipt-checkpoint")
        let acquired = try await firstService.acquire(
            sessionID: "receipt-session",
            requestID: "receipt-request",
            context: context
        )
        await store.failNextUpdate(entering: .receiptCommitted)

        let incomplete = try await firstService.release(binding: acquired.binding, context: context)
        XCTAssertEqual(incomplete.phase, .cleanupRequired)
        let retainedJournal = await store.journalSnapshot()
        let receiptSnapshot = await store.receiptSnapshot(binding: acquired.binding)
        let storedReceipt = try XCTUnwrap(receiptSnapshot)
        let writesBeforeRestart = await power.successfulWrites()
        XCTAssertEqual(retainedJournal?.pendingOperation, .removeJournal)
        XCTAssertEqual(writesBeforeRestart, [true, false])

        let restartedService = SleepOverrideLeaseService(
            store: store,
            powerBackend: power,
            clock: clock
        )
        try await restartedService.reconcileOnStartup()

        let finalJournal = await store.journalSnapshot()
        let finalReceipt = await store.receiptSnapshot(binding: acquired.binding)
        let writesAfterRestart = await power.successfulWrites()
        XCTAssertNil(finalJournal)
        XCTAssertEqual(finalReceipt, storedReceipt)
        XCTAssertEqual(writesAfterRestart, [true, false])
    }

    func testStartupRestoresOrphanBeforeAllowingNewLeaseAndKeepsOlderReceipt() async throws {
        let store = LeaseMemoryStore()
        let power = LeaseTestPowerBackend(initialValue: false)
        let original = SleepOverrideLeaseService(store: store, powerBackend: power)
        let originalContext = makeContext(connection: "orphan-owner")
        let orphan = try await original.acquire(
            sessionID: "orphan-session",
            requestID: "orphan-request",
            context: originalContext
        )
        let activeValue = await power.currentValue()
        XCTAssertTrue(activeValue)

        let restarted = SleepOverrideLeaseService(store: store, powerBackend: power)
        try await restarted.reconcileOnStartup()
        let restoredValue = await power.currentValue()
        let orphanStatus = try await restarted.status(
            binding: orphan.binding,
            context: originalContext
        )
        XCTAssertFalse(restoredValue)
        XCTAssertEqual(orphanStatus.phase, .released)

        let nextContext = makeContext(connection: "next-owner")
        let next = try await restarted.acquire(
            sessionID: "next-session",
            requestID: "next-request",
            context: nextContext
        )
        XCTAssertEqual(next.phase, .active)
        _ = try await restarted.release(binding: next.binding, context: nextContext)
        let receiptCount = await store.receiptCount()
        XCTAssertEqual(receiptCount, 2)
    }

    func testCleanupRetriesUseExactCappedBackoffAndManualRetryBypassesDelay() async throws {
        let store = LeaseMemoryStore()
        let power = LeaseTestPowerBackend(initialValue: false)
        let clock = LeaseRecordingClock()
        let service = SleepOverrideLeaseService(store: store, powerBackend: power, clock: clock)
        let context = makeContext(connection: "retry-owner")
        let acquired = try await service.acquire(
            sessionID: "retry-session",
            requestID: "retry-request",
            context: context
        )
        await power.failNextWrites(5)

        var result = try await service.release(binding: acquired.binding, context: context)
        XCTAssertEqual(result.phase, .cleanupRequired)
        await waitForDelayCount(1, clock: clock)
        for expectedCount in 2...5 {
            result = try await service.retryCleanup(binding: acquired.binding, context: context)
            XCTAssertEqual(result.phase, .cleanupRequired)
            await waitForDelayCount(expectedCount, clock: clock)
        }
        let delays = await clock.recordedDelays()
        let expectedDelays: [Duration] = [
            .milliseconds(250),
            .milliseconds(500),
            .seconds(1),
            .seconds(2),
            .seconds(2)
        ]
        XCTAssertEqual(delays, expectedDelays)

        result = try await service.retryCleanup(binding: acquired.binding, context: context)
        XCTAssertEqual(result.phase, .released)
        let finalValue = await power.currentValue()
        let writes = await power.successfulWrites()
        XCTAssertFalse(finalValue)
        XCTAssertEqual(writes, [true, false])
    }

    func testAutomaticRetryRunsWhenDeterministicClockAdvances() async throws {
        let store = LeaseMemoryStore()
        let power = LeaseTestPowerBackend(initialValue: false)
        let clock = LeaseAdvancingClock()
        let service = SleepOverrideLeaseService(store: store, powerBackend: power, clock: clock)
        let context = makeContext(connection: "automatic-retry-owner")
        let acquired = try await service.acquire(
            sessionID: "automatic-retry-session",
            requestID: "automatic-retry-request",
            context: context
        )
        await power.failNextWrites(1)

        let incomplete = try await service.release(binding: acquired.binding, context: context)
        XCTAssertEqual(incomplete.phase, .cleanupRequired)
        await waitForSleeper(clock: clock)
        await clock.advance(milliseconds: 250)
        await waitForReleasedReceipt(acquired.binding, store: store)

        let status = try await service.status(binding: acquired.binding, context: context)
        let delays = await clock.recordedDelays()
        let finalValue = await power.currentValue()
        XCTAssertEqual(status.phase, .released)
        XCTAssertEqual(delays, [.milliseconds(250)])
        XCTAssertFalse(finalValue)
    }

    func testFileStoreRoundTripsFractionalDatesAndRejectsStaleCASAndSymlinkRoot() async throws {
        let workspace = FileManager.default.temporaryDirectory.appendingPathComponent(
            "lease-store-tests-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: workspace) }
        let root = workspace.appendingPathComponent("state", isDirectory: true)
        let store = FileSleepOverrideLeaseStateStore(policy: .testSafe(rootDirectory: root))
        let journal = makeJournal(updatedAt: Date(timeIntervalSince1970: 1_700_000_000.123456))

        let created = try await store.createActiveJournal(journal)
        let readback = try await store.loadActiveJournal()
        XCTAssertEqual(readback, created)
        let journalMode = try permissionMode(
            at: root.appendingPathComponent("active-lease.json")
        )
        let rootMode = try permissionMode(at: root)
        let receiptsMode = try permissionMode(
            at: root.appendingPathComponent("released-receipts", isDirectory: true)
        )
        XCTAssertEqual(journalMode, 0o600)
        XCTAssertEqual(rootMode, 0o700)
        XCTAssertEqual(receiptsMode, 0o700)
        await assertStoreError {
            _ = try await store.updateActiveJournal(created, expectedRevision: 99)
        }
        var liveTimestampUpdate = created
        liveTimestampUpdate.updatedAt = Date()
        let updated = try await store.updateActiveJournal(
            liveTimestampUpdate,
            expectedRevision: created.revision
        )
        let updatedReadback = try await store.loadActiveJournal()
        XCTAssertEqual(updatedReadback, updated)

        let symlinkRoot = workspace.appendingPathComponent("linked-state", isDirectory: true)
        let target = workspace.appendingPathComponent("target", isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: target.path
        )
        try FileManager.default.createSymbolicLink(at: symlinkRoot, withDestinationURL: target)
        let unsafeStore = FileSleepOverrideLeaseStateStore(
            policy: .testSafe(rootDirectory: symlinkRoot)
        )
        await assertStoreError {
            _ = try await unsafeStore.loadActiveJournal()
        }
    }

    func testUnknownReceiptSchemaRestoresBaselineAndRetainsCleanupJournal() async throws {
        let workspace = FileManager.default.temporaryDirectory.appendingPathComponent(
            "lease-receipt-schema-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: false)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: workspace.path
        )
        defer { try? FileManager.default.removeItem(at: workspace) }
        let store = FileSleepOverrideLeaseStateStore(policy: .testSafe(rootDirectory: workspace))
        let journal = try await store.createActiveJournal(
            makeJournal(updatedAt: Date(timeIntervalSince1970: 1_700_000_000))
        )
        _ = try await store.createReleasedReceipt(
            SleepOverrideLeaseStoredReceipt(
                binding: journal.binding,
                principal: journal.principal,
                releasedAt: journal.updatedAt
            )
        )
        let receiptDirectory = workspace.appendingPathComponent(
            "released-receipts",
            isDirectory: true
        )
        let receiptURL = try XCTUnwrap(
            FileManager.default.contentsOfDirectory(
                at: receiptDirectory,
                includingPropertiesForKeys: nil
            ).first
        )
        try replaceSchemaVersion(in: receiptURL, with: 999)
        await assertStoreError {
            _ = try await store.loadReleasedReceipt(binding: journal.binding)
        }
        let power = LeaseTestPowerBackend(initialValue: true)
        let service = SleepOverrideLeaseService(
            store: store,
            powerBackend: power,
            clock: LeaseRecordingClock()
        )

        try await service.reconcileOnStartup()

        let retained = try await store.loadActiveJournal()
        let finalPower = await power.currentValue()
        let writes = await power.successfulWrites()
        XCTAssertFalse(
            finalPower,
            "Observed writes: \(writes); failure: \(retained?.lastFailure ?? "none")"
        )
        XCTAssertEqual(writes, [false])
        XCTAssertEqual(retained?.phase, .cleanupRequired)
        XCTAssertEqual(retained?.binding, journal.binding)
    }
}

private extension SleepOverrideLeaseEngineTests {
    func makeContext(connection: String) -> SleepOverrideLeaseCallContext {
        SleepOverrideLeaseCallContext(
            principal: SleepOverrideLeaseCallerPrincipal(
                bundleIdentifier: "com.codex.travelmode",
                teamIdentifier: "TEAM123",
                effectiveUserID: 501
            ),
            connectionID: SleepOverrideLeaseConnectionID(rawValue: connection)
        )
    }

    func makeJournal(updatedAt: Date) -> SleepOverrideLeaseJournal {
        SleepOverrideLeaseJournal(
            binding: SleepOverrideLeaseBinding(
                sessionID: "store-session",
                requestID: "store-request",
                leaseID: "store-lease",
                generation: "store-generation"
            ),
            principal: makeContext(connection: "store-owner").principal,
            ownerConnectionID: SleepOverrideLeaseConnectionID(rawValue: "store-owner"),
            baselineSleepDisabled: false,
            changedSleepDisabled: true,
            phase: .prepared,
            pendingOperation: .enableOverride,
            createdAt: updatedAt,
            updatedAt: updatedAt
        )
    }

    func staleBindings(
        from binding: SleepOverrideLeaseBinding
    ) -> [SleepOverrideLeaseBinding] {
        [
            SleepOverrideLeaseBinding(
                sessionID: "stale",
                requestID: binding.requestID,
                leaseID: binding.leaseID,
                generation: binding.generation
            ),
            SleepOverrideLeaseBinding(
                sessionID: binding.sessionID,
                requestID: "stale",
                leaseID: binding.leaseID,
                generation: binding.generation
            ),
            SleepOverrideLeaseBinding(
                sessionID: binding.sessionID,
                requestID: binding.requestID,
                leaseID: "stale",
                generation: binding.generation
            ),
            SleepOverrideLeaseBinding(
                sessionID: binding.sessionID,
                requestID: binding.requestID,
                leaseID: binding.leaseID,
                generation: "stale"
            )
        ]
    }

    func permissionMode(at url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes[.posixPermissions] as? NSNumber)?.intValue ?? -1
    }

    func replaceSchemaVersion(in url: URL, with version: Int) throws {
        let data = try Data(contentsOf: url)
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        object["schemaVersion"] = version
        let updated = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.truncate(atOffset: 0)
        try handle.write(contentsOf: updated)
        try handle.synchronize()
    }

    func assertSleepLeaseError(
        _ expected: SleepOverrideLeaseError,
        operation: () async throws -> Void
    ) async {
        do {
            try await operation()
            XCTFail("Expected SleepOverrideLeaseError.")
        } catch let error as SleepOverrideLeaseError {
            switch (expected, error) {
            case (.rejected, .rejected),
                 (.invalidReceipt, .invalidReceipt),
                 (.interruptedAfterPossibleDispatch, .interruptedAfterPossibleDispatch):
                break
            default:
                XCTFail("Unexpected lease error: \(error)")
            }
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func assertStoreError(operation: () async throws -> Void) async {
        do {
            try await operation()
            XCTFail("Expected a state-store error.")
        } catch is SleepOverrideLeaseStateStoreError {
            return
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func waitForDelayCount(_ expected: Int, clock: LeaseRecordingClock) async {
        for _ in 0..<200 {
            if await clock.recordedDelays().count >= expected { return }
            await Task.yield()
        }
        XCTFail("Timed out waiting for retry delay \(expected).")
    }

    func waitForSleeper(clock: LeaseAdvancingClock) async {
        for _ in 0..<200 {
            if await clock.sleeperCount() == 1 { return }
            await Task.yield()
        }
        XCTFail("Timed out waiting for the automatic retry sleeper.")
    }

    func waitForReleasedReceipt(
        _ binding: SleepOverrideLeaseBinding,
        store: LeaseMemoryStore
    ) async {
        for _ in 0..<200 {
            if await store.receiptSnapshot(binding: binding) != nil { return }
            await Task.yield()
        }
        XCTFail("Timed out waiting for automatic cleanup.")
    }
}

private enum LeaseTestFailure: Error {
    case injectedRead
    case injectedWrite
    case injectedStoreUpdate
}

private actor LeaseTestPowerBackend: SleepOverridePowerBackend {
    private var value: Bool
    private var writes: [Bool] = []
    private var readCount = 0
    private var failedReadNumbers: Set<Int> = []
    private var remainingWriteFailures = 0

    init(initialValue: Bool) {
        self.value = initialValue
    }

    func readSleepDisabled() async throws -> Bool {
        readCount += 1
        if failedReadNumbers.remove(readCount) != nil {
            throw LeaseTestFailure.injectedRead
        }
        return value
    }

    func setSleepDisabled(_ enabled: Bool) async throws {
        if remainingWriteFailures > 0 {
            remainingWriteFailures -= 1
            throw LeaseTestFailure.injectedWrite
        }
        value = enabled
        writes.append(enabled)
    }

    func failReads(numbered: Set<Int>) {
        failedReadNumbers.formUnion(numbered)
    }

    func failNextWrites(_ count: Int) {
        remainingWriteFailures = count
    }

    func simulateExternalDrift(to newValue: Bool) {
        value = newValue
    }

    func currentValue() -> Bool {
        value
    }

    func successfulWrites() -> [Bool] {
        writes
    }
}

private actor LeaseRecordingClock: SleepOverrideLeaseClock {
    private var timestamp = Date(timeIntervalSince1970: 1_700_000_000.123456)
    private var delays: [Duration] = []

    func now() async -> Date {
        timestamp.addTimeInterval(0.001)
        return timestamp
    }

    func sleep(for duration: Duration) async throws {
        delays.append(duration)
        throw CancellationError()
    }

    func recordedDelays() -> [Duration] {
        delays
    }
}

private actor LeaseAdvancingClock: SleepOverrideLeaseClock {
    private struct Sleeper {
        var deadline: Date
        var continuation: CheckedContinuation<Void, Error>
    }

    private var timestamp = Date(timeIntervalSince1970: 1_700_000_000)
    private var sleepers: [UUID: Sleeper] = [:]
    private var delays: [Duration] = []

    func now() async -> Date {
        timestamp
    }

    func sleep(for duration: Duration) async throws {
        let id = UUID()
        delays.append(duration)
        let deadline = timestamp.addingTimeInterval(duration.timeInterval)
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                sleepers[id] = Sleeper(deadline: deadline, continuation: continuation)
            }
        } onCancel: {
            Task { await self.cancel(id: id) }
        }
    }

    func advance(milliseconds: Int) {
        timestamp = timestamp.addingTimeInterval(Double(milliseconds) / 1_000)
        let ready = sleepers.filter { $0.value.deadline <= timestamp }
        for (id, sleeper) in ready {
            sleepers[id] = nil
            sleeper.continuation.resume()
        }
    }

    func sleeperCount() -> Int {
        sleepers.count
    }

    func recordedDelays() -> [Duration] {
        delays
    }

    private func cancel(id: UUID) {
        sleepers.removeValue(forKey: id)?.continuation.resume(throwing: CancellationError())
    }
}

private extension Duration {
    var timeInterval: TimeInterval {
        let components = self.components
        return Double(components.seconds) + Double(components.attoseconds) / 1e18
    }
}

private actor LeaseMemoryStore: SleepOverrideLeaseStateStoring {
    private var journal: SleepOverrideLeaseJournal?
    private var receipts: [SleepOverrideLeaseBinding: SleepOverrideLeaseStoredReceipt] = [:]
    private var failedUpdatePhase: SleepOverrideLeaseJournalPhase?

    func loadActiveJournal() async throws -> SleepOverrideLeaseJournal? {
        journal
    }

    func createActiveJournal(
        _ candidate: SleepOverrideLeaseJournal
    ) async throws -> SleepOverrideLeaseJournal {
        guard journal == nil else {
            throw SleepOverrideLeaseStateStoreError.activeJournalAlreadyExists
        }
        var persisted = candidate
        persisted.revision = 1
        journal = persisted
        return persisted
    }

    func updateActiveJournal(
        _ candidate: SleepOverrideLeaseJournal,
        expectedRevision: UInt64
    ) async throws -> SleepOverrideLeaseJournal {
        guard let current = journal else {
            throw SleepOverrideLeaseStateStoreError.activeJournalMissing
        }
        guard current.binding == candidate.binding else {
            throw SleepOverrideLeaseStateStoreError.bindingMismatch
        }
        guard current.revision == expectedRevision else {
            throw SleepOverrideLeaseStateStoreError.staleJournalRevision(
                expected: expectedRevision,
                actual: current.revision
            )
        }
        if failedUpdatePhase == candidate.phase {
            failedUpdatePhase = nil
            throw LeaseTestFailure.injectedStoreUpdate
        }
        var persisted = candidate
        persisted.revision = current.revision + 1
        journal = persisted
        return persisted
    }

    func removeActiveJournal(
        binding: SleepOverrideLeaseBinding,
        expectedRevision: UInt64
    ) async throws {
        guard let current = journal else {
            throw SleepOverrideLeaseStateStoreError.activeJournalMissing
        }
        guard current.binding == binding else {
            throw SleepOverrideLeaseStateStoreError.bindingMismatch
        }
        guard current.revision == expectedRevision else {
            throw SleepOverrideLeaseStateStoreError.staleJournalRevision(
                expected: expectedRevision,
                actual: current.revision
            )
        }
        journal = nil
    }

    func loadReleasedReceipt(
        binding: SleepOverrideLeaseBinding
    ) async throws -> SleepOverrideLeaseStoredReceipt? {
        receipts[binding]
    }

    func findReleasedReceipt(
        sessionID: String,
        requestID: String
    ) async throws -> SleepOverrideLeaseStoredReceipt? {
        receipts.values.first {
            $0.binding.sessionID == sessionID && $0.binding.requestID == requestID
        }
    }

    func createReleasedReceipt(
        _ receipt: SleepOverrideLeaseStoredReceipt
    ) async throws -> SleepOverrideLeaseStoredReceipt {
        if let existing = receipts[receipt.binding] {
            guard existing == receipt else {
                throw SleepOverrideLeaseStateStoreError.immutableReceiptConflict
            }
            return existing
        }
        receipts[receipt.binding] = receipt
        return receipt
    }

    func removeReleasedReceipt(
        binding: SleepOverrideLeaseBinding,
        expectedPrincipal: SleepOverrideLeaseCallerPrincipal
    ) async throws {
        guard let receipt = receipts[binding] else { return }
        guard receipt.principal == expectedPrincipal else {
            throw SleepOverrideLeaseStateStoreError.bindingMismatch
        }
        receipts[binding] = nil
    }

    func failNextUpdate(entering phase: SleepOverrideLeaseJournalPhase) {
        failedUpdatePhase = phase
    }

    func journalSnapshot() -> SleepOverrideLeaseJournal? {
        journal
    }

    func receiptSnapshot(
        binding: SleepOverrideLeaseBinding
    ) -> SleepOverrideLeaseStoredReceipt? {
        receipts[binding]
    }

    func receiptCount() -> Int {
        receipts.count
    }
}
