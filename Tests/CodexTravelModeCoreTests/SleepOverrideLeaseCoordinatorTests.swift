import CodexTravelModeCore
import XCTest

final class SleepOverrideLeaseCoordinatorTests: XCTestCase {
    func testDefinitivePreDispatchFailureClearsUntouchedJournalAndStaysOff() async throws {
        let store = InMemoryTravelSessionJournalStore()
        let coordinator = TravelSessionCoordinator(
            journalStore: store,
            system: FixedTravelSessionSystem(),
            leaseClient: CoordinatorLeaseClient(mode: .definitivePreDispatchFailure)
        )

        let result = await coordinator.start(
            configuration: TravelSessionConfiguration(wifiDevice: "en0")
        )

        XCTAssertEqual(result.lifecycle, .off)
        let persisted = try await store.load()
        XCTAssertNil(persisted)
    }

    func testUncertainDispatchRetainsJournalForExactResolution() async throws {
        let store = InMemoryTravelSessionJournalStore()
        let coordinator = TravelSessionCoordinator(
            journalStore: store,
            system: FixedTravelSessionSystem(),
            leaseClient: CoordinatorLeaseClient(mode: .uncertainDispatchFailure)
        )

        let result = await coordinator.start(
            configuration: TravelSessionConfiguration(wifiDevice: "en0")
        )

        XCTAssertEqual(result.lifecycle, .cleanupRequired)
        let persisted = try await store.load()
        XCTAssertEqual(persisted?.phase, .cleanupRequired)
    }

    func testUnavailableResolutionNeverClearsRecoveryJournal() async throws {
        let store = InMemoryTravelSessionJournalStore()
        _ = try await store.create(makeJournal())
        let coordinator = TravelSessionCoordinator(
            journalStore: store,
            system: FixedTravelSessionSystem(),
            leaseClient: CoordinatorLeaseClient(mode: .unavailableResolution)
        )

        let result = await coordinator.recover()

        XCTAssertEqual(result.lifecycle, .cleanupRequired)
        let persisted = try await store.load()
        XCTAssertNotNil(persisted)
    }

    func testAuthenticatedAuthoritativeNotFoundCanFinishAppCleanup() async throws {
        let store = InMemoryTravelSessionJournalStore()
        _ = try await store.create(makeJournal())
        let coordinator = TravelSessionCoordinator(
            journalStore: store,
            system: FixedTravelSessionSystem(),
            leaseClient: CoordinatorLeaseClient(mode: .authoritativeNotFound)
        )

        let result = await coordinator.recover()

        XCTAssertEqual(result.lifecycle, .off)
        let persisted = try await store.load()
        XCTAssertNil(persisted)
    }

    func testResolvedCleanupRequiredLeasePersistsBindingAndFinishesCleanup() async throws {
        let store = InMemoryTravelSessionJournalStore()
        _ = try await store.create(makeJournal())
        let coordinator = TravelSessionCoordinator(
            journalStore: store,
            system: FixedTravelSessionSystem(),
            leaseClient: CoordinatorLeaseClient(mode: .cleanupRequiredResolution)
        )

        let result = await coordinator.recover()

        XCTAssertEqual(result.lifecycle, .off)
        let persisted = try await store.load()
        XCTAssertNil(persisted)
    }

    private func makeJournal() -> TravelSessionJournal {
        TravelSessionJournal(
            sessionID: "session-recovery",
            wifiBaseline: TravelWiFiBaseline(
                device: "en0",
                powerEnabled: true,
                associatedSSID: "Office"
            ),
            leaseRequestID: "request-recovery"
        )
    }
}

private actor InMemoryTravelSessionJournalStore: TravelSessionJournalStoring {
    private var journal: TravelSessionJournal?

    func load() async throws -> TravelSessionJournal? {
        journal
    }

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
        persisted.revision = expectedRevision + 1
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
}

private struct FixedTravelSessionSystem: TravelSessionSystemControlling {
    func currentWiFiPower(device: String) async throws -> Bool { true }
    func currentAssociatedSSID(device: String) async throws -> String? { "Office" }

    func setWiFiPower(device: String, enabled: Bool) async -> CommandResult {
        CommandResult(exitCode: 0)
    }

    func associate(device: String, ssid: String, password: String?) async -> CommandResult {
        CommandResult(exitCode: 0)
    }
}

private struct CoordinatorLeaseClient: SleepOverrideLeaseClient {
    enum Mode: Sendable {
        case definitivePreDispatchFailure
        case uncertainDispatchFailure
        case unavailableResolution
        case authoritativeNotFound
        case cleanupRequiredResolution
    }

    let mode: Mode

    func acquire(
        sessionID: String,
        requestID: String
    ) async throws -> SleepOverrideLeaseReceipt {
        switch mode {
        case .definitivePreDispatchFailure:
            throw SleepOverrideLeaseError.helperUnavailable(.definitelyNotSent)
        case .uncertainDispatchFailure:
            throw SleepOverrideLeaseError.helperUnavailable(.mayHaveReachedHelper)
        case .unavailableResolution, .authoritativeNotFound, .cleanupRequiredResolution:
            throw SleepOverrideLeaseError.invalidResponse("Acquire is not used by this test.")
        }
    }

    func resolve(
        sessionID: String,
        requestID: String
    ) async throws -> SleepOverrideLeaseResolution {
        switch mode {
        case .authoritativeNotFound:
            return .authoritativeNotFound
        case .unavailableResolution:
            throw SleepOverrideLeaseError.helperUnavailable(.definitelyNotSent)
        case .cleanupRequiredResolution:
            return .found(
                SleepOverrideLeaseReceipt(
                    phase: .cleanupRequired,
                    binding: recoveryBinding
                )
            )
        case .definitivePreDispatchFailure, .uncertainDispatchFailure:
            throw SleepOverrideLeaseError.invalidResponse("Resolve is not used by this test.")
        }
    }

    func status(binding: SleepOverrideLeaseBinding) async throws -> SleepOverrideLeaseReceipt {
        if mode == .cleanupRequiredResolution, binding == recoveryBinding {
            return SleepOverrideLeaseReceipt(phase: .released, binding: binding)
        }
        throw SleepOverrideLeaseError.invalidResponse("Status is not used by this test.")
    }

    func release(binding: SleepOverrideLeaseBinding) async throws -> SleepOverrideLeaseReceipt {
        if mode == .cleanupRequiredResolution, binding == recoveryBinding {
            return SleepOverrideLeaseReceipt(phase: .released, binding: binding)
        }
        throw SleepOverrideLeaseError.invalidResponse("Release is not used by this test.")
    }

    func acknowledgeRelease(binding: SleepOverrideLeaseBinding) async throws {
        if mode == .cleanupRequiredResolution, binding == recoveryBinding { return }
        throw SleepOverrideLeaseError.invalidResponse("Acknowledge is not used by this test.")
    }

    private var recoveryBinding: SleepOverrideLeaseBinding {
        SleepOverrideLeaseBinding(
            sessionID: "session-recovery",
            requestID: "request-recovery",
            leaseID: "lease-recovery",
            generation: "generation-recovery"
        )
    }
}
