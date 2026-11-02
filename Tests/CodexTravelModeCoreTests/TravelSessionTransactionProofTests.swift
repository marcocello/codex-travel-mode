import Darwin
import CodexTravelModeCore
import Foundation
import XCTest

final class TravelSessionTransactionProofTests: XCTestCase {
    func testProductionProcessRunnerTerminatesAssociationCommandAtTimeout() async throws {
        let runner = ProcessShellCommandRunner()
        let workspace = try makeWorkspace()
        let lateEffect = workspace.appendingPathComponent("late-effect")
        let clock = ContinuousClock()
        let started = clock.now

        let output = await runner.run(
            try proofHostURL(),
            arguments: [
                "--scenario", "timeout-worker",
                "--workspace", workspace.path
            ],
            timeout: .milliseconds(50)
        )
        let elapsed = started.duration(to: clock.now)

        XCTAssertEqual(output.exitCode, 124)
        XCTAssertEqual(output.standardError, "Command timed out and was terminated.")
        XCTAssertLessThan(elapsed, .seconds(2))
        try await Task.sleep(for: .milliseconds(700))
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: lateEffect.path),
            "Timed-out proof worker survived long enough to perform its late outer effect."
        )
    }

    func testPersistedCreateReadbackFailureRetainsOwnedJournal() throws {
        let workspace = try runCompletedScenario("persisted-readback-failure")
        let artifacts = try loadCase("persisted-readback-failure", workspace: workspace)
        let created = try decode(
            JournalArtifact.self,
            at: caseDirectory("persisted-readback-failure", workspace: workspace)
                .appendingPathComponent("created-journal.json")
        )
        let retained = try XCTUnwrap(artifacts.journal)

        XCTAssertEqual(artifacts.result.lifecycle, "cleanup_required")
        XCTAssertFalse(artifacts.result.canTerminate)
        XCTAssertEqual(created.phase, "preparing")
        XCTAssertEqual(retained.phase, "cleanup_required")
        XCTAssertEqual(retained.sessionID, created.sessionID)
        XCTAssertEqual(retained.leaseRequestID, created.leaseRequestID)
        XCTAssertEqual(retained.wifiBaseline.device, created.wifiBaseline.device)
        XCTAssertEqual(retained.wifiBaseline.powerEnabled, created.wifiBaseline.powerEnabled)
        XCTAssertEqual(retained.wifiBaseline.associatedSSID, created.wifiBaseline.associatedSSID)
        XCTAssertTrue(artifacts.provider.mutations.isEmpty)
        XCTAssertTrue(artifacts.lease.mutations.isEmpty)
    }

    func testQuitRetriesTerminationMarkAfterCreateCancellationRace() throws {
        let workspace = try runCompletedScenario("quit-create-race")
        let artifacts = try loadCase("quit-create-race", workspace: workspace)
        let directory = caseDirectory("quit-create-race", workspace: workspace)
        let created = try decode(
            JournalArtifact.self,
            at: directory.appendingPathComponent("created-journal.json")
        )
        let race = try decode([String].self, at: directory.appendingPathComponent("create-race.json"))
        let competingStart = try decode(
            ResultArtifact.self,
            at: directory.appendingPathComponent("concurrent-start-result.json")
        )
        let retained = try XCTUnwrap(artifacts.journal)

        XCTAssertEqual(
            race,
            [
                "create_entered_without_journal",
                "cancellation_observed_before_create",
                "create_gate_observed",
                "journal_persisted_after_cancellation",
                "clear_rejected"
            ]
        )
        XCTAssertTrue(["preparing", "cleanup_required"].contains(competingStart.lifecycle))
        XCTAssertFalse(competingStart.canTerminate)
        XCTAssertNotNil(competingStart.error)
        XCTAssertEqual(artifacts.result.lifecycle, "cleanup_required")
        XCTAssertFalse(artifacts.result.canTerminate)
        XCTAssertEqual(retained.sessionID, created.sessionID)
        XCTAssertEqual(retained.phase, "cleanup_required")
        XCTAssertTrue(retained.terminationRequested)
        XCTAssertTrue(artifacts.provider.mutations.isEmpty)
        XCTAssertTrue(artifacts.lease.mutations.isEmpty)
    }

    func testUnownedOperationsAndCaptureFailureMakeZeroMutations() throws {
        let workspace = try runCompletedScenario("unowned-and-capture-failure")
        let names = [
            "stop-off",
            "quit-off",
            "recover-off",
            "capture-failure",
            "journal-readback-failure"
        ]

        for name in names {
            let artifacts = try loadCase(name, workspace: workspace)
            assertOff(artifacts)
            XCTAssertTrue(artifacts.provider.mutations.isEmpty, name)
            XCTAssertTrue(artifacts.lease.mutations.isEmpty, name)
        }
    }

    func testExactPowerAndPriorAssociationRoundTrip() throws {
        let startedAt = Date()
        let workspace = try runCompletedScenario("exact-roundtrip")
        XCTAssertLessThan(Date().timeIntervalSince(startedAt), 3)
        let disabled = try loadCase("wifi-false-roundtrip", workspace: workspace)
        assertOff(disabled)
        XCTAssertFalse(disabled.provider.wifiPower)
        XCTAssertEqual(successfulPowerTargets(disabled), ["true", "false"])
        XCTAssertEqual(disabled.lease.phase, "released")
        let activeJournal = try XCTUnwrap(disabled.activeJournal)
        let activeBinding = try XCTUnwrap(activeJournal.leaseBinding)
        let releasedReceipt = try XCTUnwrap(disabled.lease.releasedReceipt)
        XCTAssertEqual(activeJournal.leaseStatus, "active")
        assertBindingOwnedByJournal(activeBinding, journal: activeJournal)
        XCTAssertEqual(activeBinding, releasedReceipt)
        assertOrdered(
            [
                "lease_acquired",
                "session_active",
                "lease_released",
                "journal_cleared",
                "lease_acknowledged"
            ],
            in: disabled.trace
        )

        let enabled = try loadCase("wifi-true-no-power-write", workspace: workspace)
        assertOff(enabled)
        XCTAssertTrue(enabled.provider.wifiPower)
        XCTAssertTrue(powerMutations(enabled).isEmpty)

        let available = try loadCase("prior-network-available", workspace: workspace)
        assertOff(available)
        XCTAssertEqual(available.provider.ssid, "Office")
        XCTAssertTrue(available.provider.mutations.contains {
            $0.kind == "associate" && $0.target == "Office" && $0.succeeded
        })

        let unavailable = try loadCase("prior-network-unavailable", workspace: workspace)
        assertOff(unavailable)
        XCTAssertNotNil(unavailable.result.warning)
        XCTAssertTrue(unavailable.provider.mutations.contains {
            $0.kind == "associate" && $0.target == "Office" && !$0.succeeded
        })
        XCTAssertFalse(unavailable.provider.wifiPower)
        XCTAssertEqual(successfulPowerTargets(unavailable), ["true", "false"])
        XCTAssertEqual(unavailable.lease.phase, "released")

        let unassociated = try loadCase("prior-network-unassociated", workspace: workspace)
        assertOff(unassociated)
        XCTAssertTrue(unassociated.provider.wifiPower)
        XCTAssertEqual(unassociated.provider.ssid, "iPhone")
        XCTAssertNil(unassociated.result.warning)
        XCTAssertNil(unassociated.activeJournal?.wifiBaseline.associatedSSID)
        XCTAssertEqual(
            unassociated.provider.mutations.filter {
                $0.kind == "associate" && $0.succeeded
            }.compactMap(\.target),
            ["iPhone"]
        )
        XCTAssertEqual(unassociated.lease.phase, "released")

        let unrelated = try loadCase("unrelated-setting", workspace: workspace)
        assertOff(unrelated)
        XCTAssertEqual(unrelated.provider.unrelatedPowerValue, 17)
    }

    func testProductionRuntimeWiringRestoresAtRawGatewayBoundary() throws {
        let workspace = try runCompletedScenario("runtime-wiring-roundtrip")
        let artifacts = try loadCase("runtime-wiring-roundtrip", workspace: workspace)
        let app = try decode(
            RuntimeAppStateArtifact.self,
            at: caseDirectory("runtime-wiring-roundtrip", workspace: workspace)
                .appendingPathComponent("app.json")
        )

        assertOff(artifacts)
        XCTAssertFalse(app.isRunning)
        XCTAssertEqual(app.latestStatus, "Stopped")
        XCTAssertNil(app.lastErrorMessage)
        XCTAssertFalse(artifacts.provider.wifiPower)
        XCTAssertEqual(artifacts.provider.ssid, "Office")
        XCTAssertEqual(successfulPowerTargets(artifacts), ["true", "false"])
        XCTAssertEqual(
            artifacts.provider.mutations.filter {
                $0.kind == "associate" && $0.succeeded
            }.compactMap(\.target),
            ["iPhone", "Office"]
        )
        XCTAssertEqual(
            artifacts.provider.mutations.map { "\($0.kind):\($0.target ?? "-")" },
            [
                "set_wifi_power:true",
                "start_keep_awake:-",
                "associate:iPhone",
                "stop_keep_awake:-",
                "associate:Office",
                "set_wifi_power:false"
            ]
        )
        let activeJournal = try XCTUnwrap(artifacts.activeJournal)
        XCTAssertFalse(activeJournal.wifiBaseline.powerEnabled)
        XCTAssertEqual(activeJournal.wifiBaseline.associatedSSID, "Office")
        XCTAssertEqual(activeJournal.leaseStatus, "active")
        XCTAssertEqual(artifacts.lease.phase, "released")
        assertOrdered(
            [
                "lease_acquired",
                "session_active",
                "lease_released",
                "journal_cleared",
                "lease_acknowledged"
            ],
            in: artifacts.trace
        )
    }

    func testReadbackAndRestoreFailuresRetainRecoveryUntilRetry() throws {
        let workspace = try runCompletedScenario("failure-and-retry")
        for name in [
            "wrong-readback-before-retry",
            "failed-write-before-retry",
            "restore-failure-before-retry"
        ] {
            let artifacts = try loadCase(name, workspace: workspace)
            XCTAssertEqual(artifacts.result.lifecycle, "cleanup_required", name)
            XCTAssertNotNil(artifacts.result.error, name)
            XCTAssertNotNil(artifacts.journal, name)
            XCTAssertFalse(artifacts.journal?.sessionID.isEmpty ?? true, name)
        }

        let failedRestore = try loadCase(
            "restore-failure-before-retry",
            workspace: workspace
        )
        XCTAssertEqual(failedRestore.lease.phase, "released")
        XCTAssertTrue(failedRestore.lease.mutations.contains { $0.kind == "release" })

        let retried = try loadCase("after-retry", workspace: workspace)
        assertOff(retried)
        XCTAssertFalse(retried.provider.wifiPower)
        let successfulRestores = powerMutations(retried).filter {
            $0.target == "false" && $0.succeeded
        }
        XCTAssertEqual(successfulRestores.count, 1)
    }

    func testSessionAndLeaseBindingsRejectStaleCleanup() throws {
        let workspace = try runCompletedScenario("binding-and-serialization")
        let mismatches = [
            ("mismatched-session-receipt", "session_id"),
            ("mismatched-request-receipt", "request_id"),
            ("mismatched-lease-receipt", "lease_id"),
            ("mismatched-generation-receipt", "generation")
        ]
        for (name, mismatchedField) in mismatches {
            let mismatch = try loadCase(name, workspace: workspace)
            XCTAssertEqual(mismatch.result.lifecycle, "cleanup_required", name)
            let journal = try XCTUnwrap(mismatch.journal, name)
            let journalBinding = try XCTUnwrap(journal.leaseBinding, name)
            let releasedReceipt = try XCTUnwrap(mismatch.lease.releasedReceipt, name)
            assertBindingOwnedByJournal(journalBinding, journal: journal)
            assertOnlyField(
                mismatchedField,
                differsBetween: journalBinding,
                and: releasedReceipt,
                file: #filePath,
                line: #line
            )
            XCTAssertFalse(mismatch.trace.contains { $0.kind == "journal_cleared" }, name)
        }

        let stale = try loadCase("stale-session", workspace: workspace)
        XCTAssertEqual(stale.result.lifecycle, "cleanup_required")
        XCTAssertNotNil(stale.journal)
        XCTAssertEqual(stale.journal?.phase, "preparing")
        XCTAssertFalse(stale.trace.contains { $0.kind == "journal_cleared" })

        let serialized = try loadCase("recovery-versus-start", workspace: workspace)
        assertOff(serialized)
        XCTAssertEqual(
            serialized.trace.filter { $0.kind == "start_rejected_existing_recovery" }.count,
            1
        )
        XCTAssertEqual(Set(serialized.trace.compactMap(\.sessionID)).count, 1)
        assertOrdered(
            [
                "start_rejected_existing_recovery",
                "lease_released",
                "journal_cleared",
                "lease_acknowledged"
            ],
            in: serialized.trace
        )
    }

    func testQuitDuringPreparingCompensatesBeforeExit() throws {
        let workspace = try runCompletedScenario("quit-during-preparing")
        for name in ["capture", "lease-acquisition", "mutation-dispatch", "verification"] {
            let artifacts = try loadCase(name, workspace: workspace)
            assertOff(artifacts)
            XCTAssertTrue(artifacts.result.canTerminate, name)
            XCTAssertEqual(artifacts.lease.phase, "released", name)
        }
    }

    func testQuitWaitsForActiveAssociationAndRestoresIt() throws {
        let workspace = try runCompletedScenario("quit-active-association")
        let artifacts = try loadCase("active-association", workspace: workspace)
        assertOff(artifacts)
        XCTAssertEqual(artifacts.provider.ssid, "Office")
        XCTAssertEqual(
            artifacts.provider.mutations.filter {
                $0.kind == "associate" && $0.succeeded
            }.compactMap(\.target),
            ["iPhone", "Office"]
        )
        XCTAssertEqual(artifacts.lease.phase, "released")
        assertOrdered(
            ["lease_released", "journal_cleared", "lease_acknowledged"],
            in: artifacts.trace
        )
    }

    func testFailedQuitCompensationKeepsProcessAlive() throws {
        let workspace = try makeWorkspace()
        let process = try launchHost(
            scenario: "quit-compensation-failure",
            workspace: workspace
        )
        let resultPath = caseDirectory("failed-compensation", workspace: workspace)
            .appendingPathComponent("result.json")
        guard waitForPath(resultPath, process: process) else {
            process.waitUntilExit()
            XCTFail("Proof host exited before publishing cleanup_required.")
            return
        }

        XCTAssertTrue(process.isRunning)
        let artifacts = try loadCase("failed-compensation", workspace: workspace)
        XCTAssertEqual(artifacts.result.lifecycle, "cleanup_required")
        XCTAssertFalse(artifacts.result.canTerminate)
        XCTAssertNotNil(artifacts.journal)
        XCTAssertTrue(artifacts.journal?.terminationRequested == true)

        let observationDeadline = Date().addingTimeInterval(0.4)
        while Date() < observationDeadline {
            XCTAssertTrue(process.isRunning, "Proof host self-terminated during failed compensation.")
            Thread.sleep(forTimeInterval: 0.02)
        }
        let observedAgain = try loadCase("failed-compensation", workspace: workspace)
        XCTAssertEqual(observedAgain.result.lifecycle, "cleanup_required")
        XCTAssertFalse(observedAgain.result.canTerminate)
        XCTAssertEqual(observedAgain.journal?.sessionID, artifacts.journal?.sessionID)
        XCTAssertTrue(process.isRunning)

        kill(process.processIdentifier, SIGKILL)
        process.waitUntilExit()
    }

    func testProcessDeathAtEveryWriteAheadBoundaryRecovers() throws {
        let checkpoints = [
            "after-intent-persist",
            "after-dispatch",
            "after-verification",
            "before-completion-persist"
        ]

        for checkpoint in checkpoints {
            try assertRecoveryAfterProcessDeath(
                scenario: "crash-start",
                checkpoint: checkpoint,
                journalPhase: "preparing",
                baselinePower: false,
                mutationKind: "wifi_power",
                mutationBaseline: "false",
                mutationTarget: "true",
                finalPower: false,
                finalSSID: "Office"
            )
            try assertRecoveryAfterProcessDeath(
                scenario: "crash-association",
                checkpoint: checkpoint,
                journalPhase: "active",
                baselinePower: true,
                mutationKind: "association",
                mutationBaseline: "Office",
                mutationTarget: "iPhone",
                finalPower: true,
                finalSSID: "Office"
            )
            try assertRecoveryAfterProcessDeath(
                scenario: "crash-restore",
                checkpoint: checkpoint,
                journalPhase: "restoring",
                baselinePower: false,
                mutationKind: "wifi_power",
                mutationBaseline: "true",
                mutationTarget: "false",
                finalPower: false,
                finalSSID: "Office"
            )
        }
    }

    func testProcessDeathAfterLeaseReceiptResolvesExactHelperIdentity() throws {
        let workspace = try makeWorkspace()
        let process = try launchHost(scenario: "crash-lease-receipt", workspace: workspace)
        let marker = workspace.appendingPathComponent("checkpoint")
        guard waitForPath(
            marker,
            expectedText: "lease_receipt_returned",
            process: process
        ) else {
            process.waitUntilExit()
            XCTFail("Proof host exited before the returned lease receipt boundary.")
            return
        }

        let pending = try decode(
            JournalArtifact.self,
            at: workspace.appendingPathComponent("session-journal.json")
        )
        let activeLease = try decode(
            LeaseState.self,
            at: workspace.appendingPathComponent("lease-state.json")
        )
        let helperBinding = try XCTUnwrap(activeLease.activeBinding)
        XCTAssertEqual(pending.phase, "preparing")
        XCTAssertNil(pending.leaseBinding)
        XCTAssertNil(pending.leaseStatus)
        XCTAssertEqual(activeLease.phase, "active")
        assertBindingOwnedByJournal(helperBinding, journal: pending)

        kill(process.processIdentifier, SIGKILL)
        process.waitUntilExit()
        _ = try runCompletedScenario("recover-existing", workspace: workspace)

        let recovered = try loadCase("recovery", workspace: workspace)
        assertOff(recovered)
        XCTAssertEqual(recovered.lease.phase, "released")
        XCTAssertEqual(recovered.lease.releasedReceipt, helperBinding)
        XCTAssertEqual(
            recovered.lease.mutations.filter { $0.kind == "resolve" }.compactMap(\.binding),
            [helperBinding]
        )
        XCTAssertEqual(
            recovered.lease.mutations.filter { $0.kind == "release" }.compactMap(\.binding),
            [helperBinding]
        )
        assertOrdered(
            [
                "lease_receipt_returned",
                "lease_released",
                "journal_cleared",
                "lease_acknowledged"
            ],
            in: recovered.trace
        )
    }
}

private extension TravelSessionTransactionProofTests {
    struct ResultArtifact: Decodable {
        var lifecycle: String
        var warning: String?
        var error: String?
        var canTerminate: Bool
    }

    struct RuntimeAppStateArtifact: Decodable {
        var isRunning: Bool
        var latestStatus: String
        var lastErrorMessage: String?

        enum CodingKeys: String, CodingKey {
            case isRunning = "is_running"
            case latestStatus = "latest_status"
            case lastErrorMessage = "last_error_message"
        }
    }

    struct ProviderMutation: Decodable {
        var kind: String
        var target: String?
        var succeeded: Bool
    }

    struct ProviderState: Decodable {
        var wifiPower: Bool
        var ssid: String?
        var unrelatedPowerValue: Int
        var mutations: [ProviderMutation]

        enum CodingKeys: String, CodingKey {
            case wifiPower = "wifi_power"
            case ssid
            case unrelatedPowerValue = "unrelated_power_value"
            case mutations
        }
    }

    struct LeaseMutation: Decodable {
        var kind: String
        var binding: LeaseBinding?
    }

    struct LeaseBinding: Codable, Equatable {
        var sessionID: String
        var requestID: String
        var leaseID: String
        var generation: String

        enum CodingKeys: String, CodingKey {
            case sessionID = "session_id"
            case requestID = "request_id"
            case leaseID = "lease_id"
            case generation
        }
    }

    struct LeaseState: Decodable {
        var phase: String
        var activeBinding: LeaseBinding?
        var releasedReceipt: LeaseBinding?
        var mutations: [LeaseMutation]

        enum CodingKeys: String, CodingKey {
            case phase
            case activeBinding = "active_binding"
            case releasedReceipt = "released_receipt"
            case mutations
        }
    }

    struct WiFiBaselineArtifact: Decodable {
        var device: String
        var powerEnabled: Bool
        var associatedSSID: String?

        enum CodingKeys: String, CodingKey {
            case device
            case powerEnabled = "power_enabled"
            case associatedSSID = "associated_ssid"
        }
    }

    struct MutationIntentArtifact: Decodable {
        var id: String
        var kind: String
        var baseline: String
        var target: String
        var phase: String
    }

    struct JournalArtifact: Decodable {
        var schemaVersion: Int
        var revision: Int
        var sessionID: String
        var phase: String
        var wifiBaseline: WiFiBaselineArtifact
        var pendingMutation: MutationIntentArtifact?
        var leaseRequestID: String
        var leaseBinding: LeaseBinding?
        var leaseStatus: String?
        var terminationRequested: Bool

        enum CodingKeys: String, CodingKey {
            case schemaVersion = "schema_version"
            case revision
            case sessionID = "session_id"
            case phase
            case wifiBaseline = "wifi_baseline"
            case pendingMutation = "pending_mutation"
            case leaseRequestID = "lease_request_id"
            case leaseBinding = "lease_binding"
            case leaseStatus = "lease_status"
            case terminationRequested = "termination_requested"
        }
    }

    struct TraceEvent: Decodable {
        var sequence: Int
        var kind: String
        var sessionID: String?
        var value: String?

        enum CodingKeys: String, CodingKey {
            case sequence
            case kind
            case sessionID = "session_id"
            case value
        }
    }

    struct CaseArtifacts {
        var result: ResultArtifact
        var provider: ProviderState
        var lease: LeaseState
        var trace: [TraceEvent]
        var journal: JournalArtifact?
        var activeJournal: JournalArtifact?
    }

    func assertRecoveryAfterProcessDeath(
        scenario: String,
        checkpoint: String,
        journalPhase: String,
        baselinePower: Bool,
        mutationKind: String,
        mutationBaseline: String,
        mutationTarget: String,
        finalPower: Bool,
        finalSSID: String?
    ) throws {
        let workspace = try makeWorkspace()
        let process = try launchHost(
            scenario: scenario,
            workspace: workspace,
            extraArguments: ["--checkpoint", checkpoint]
        )
        let marker = workspace.appendingPathComponent("checkpoint")
        guard waitForPath(marker, expectedText: checkpoint, process: process) else {
            process.waitUntilExit()
            XCTFail("Proof host exited before checkpoint \(checkpoint).")
            return
        }

        let pending = try decode(
            JournalArtifact.self,
            at: workspace.appendingPathComponent("session-journal.json")
        )
        assertPendingCrashJournal(
            pending,
            checkpoint: checkpoint,
            journalPhase: journalPhase,
            baselinePower: baselinePower,
            mutationKind: mutationKind,
            mutationBaseline: mutationBaseline,
            mutationTarget: mutationTarget
        )

        kill(process.processIdentifier, SIGKILL)
        process.waitUntilExit()
        _ = try runCompletedScenario("recover-existing", workspace: workspace)

        let artifacts = try loadCase("recovery", workspace: workspace)
        assertOff(artifacts)
        XCTAssertEqual(artifacts.provider.wifiPower, finalPower)
        XCTAssertEqual(artifacts.provider.ssid, finalSSID)
        XCTAssertEqual(artifacts.lease.phase, "released")
        XCTAssertTrue(artifacts.trace.contains {
            $0.kind == "checkpoint_recovered" && $0.value == checkpoint
        })
    }

    func runCompletedScenario(_ scenario: String, workspace: URL? = nil) throws -> URL {
        let workspace = try workspace ?? makeWorkspace()
        let process = try launchHost(scenario: scenario, workspace: workspace)
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, "Scenario \(scenario) failed.")
        return workspace
    }

    func launchHost(
        scenario: String,
        workspace: URL,
        extraArguments: [String] = []
    ) throws -> Process {
        let process = Process()
        process.executableURL = try proofHostURL()
        process.arguments = [
            "--scenario", scenario,
            "--workspace", workspace.path
        ] + extraArguments
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try process.run()
        return process
    }

    func proofHostURL() throws -> URL {
        let path = try XCTUnwrap(
            ProcessInfo.processInfo.environment["TRAVEL_SESSION_PROOF_HOST"],
            "TRAVEL_SESSION_PROOF_HOST is required."
        )
        let url = URL(fileURLWithPath: path)
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: url.path))
        return url
    }

    func makeWorkspace() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("travel-session-proof-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func caseDirectory(_ name: String, workspace: URL) -> URL {
        workspace.appendingPathComponent("cases/\(name)", isDirectory: true)
    }

    func loadCase(_ name: String, workspace: URL) throws -> CaseArtifacts {
        let directory = caseDirectory(name, workspace: workspace)
        return CaseArtifacts(
            result: try decode(ResultArtifact.self, at: directory.appendingPathComponent("result.json")),
            provider: try decode(ProviderState.self, at: directory.appendingPathComponent("provider.json")),
            lease: try decode(LeaseState.self, at: directory.appendingPathComponent("lease.json")),
            trace: try decode([TraceEvent].self, at: directory.appendingPathComponent("trace.json")),
            journal: try decodeIfPresent(
                JournalArtifact.self,
                at: directory.appendingPathComponent("session-journal.json")
            ),
            activeJournal: try decodeIfPresent(
                JournalArtifact.self,
                at: directory.appendingPathComponent("active-journal.json")
            )
        )
    }

    func decode<Value: Decodable>(_ type: Value.Type, at url: URL) throws -> Value {
        try JSONDecoder().decode(type, from: Data(contentsOf: url))
    }

    func decodeIfPresent<Value: Decodable>(
        _ type: Value.Type,
        at url: URL
    ) throws -> Value? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try decode(type, at: url)
    }

    func waitForPath(
        _ url: URL,
        expectedText: String? = nil,
        process: Process,
        timeout: TimeInterval = 5
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline, process.isRunning {
            if FileManager.default.fileExists(atPath: url.path) {
                guard let expectedText else { return true }
                if (try? String(contentsOf: url, encoding: .utf8)) == expectedText {
                    return true
                }
            }
            Thread.sleep(forTimeInterval: 0.02)
        }
        return false
    }

    func assertOff(
        _ artifacts: CaseArtifacts,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(artifacts.result.lifecycle, "off", file: file, line: line)
        XCTAssertTrue(artifacts.result.canTerminate, file: file, line: line)
        XCTAssertNil(artifacts.journal, file: file, line: line)
    }

    func powerMutations(_ artifacts: CaseArtifacts) -> [ProviderMutation] {
        artifacts.provider.mutations.filter { $0.kind == "set_wifi_power" }
    }

    func successfulPowerTargets(_ artifacts: CaseArtifacts) -> [String] {
        powerMutations(artifacts).filter(\.succeeded).compactMap(\.target)
    }

    func assertOrdered(
        _ kinds: [String],
        in trace: [TraceEvent],
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let positions = kinds.compactMap { kind in
            trace.first(where: { $0.kind == kind })?.sequence
        }
        XCTAssertEqual(positions.count, kinds.count, file: file, line: line)
        XCTAssertEqual(positions, positions.sorted(), file: file, line: line)
    }

    func assertPendingCrashJournal(
        _ journal: JournalArtifact,
        checkpoint: String,
        journalPhase: String,
        baselinePower: Bool,
        mutationKind: String,
        mutationBaseline: String,
        mutationTarget: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(journal.schemaVersion, 1, file: file, line: line)
        XCTAssertGreaterThanOrEqual(journal.revision, 1, file: file, line: line)
        XCTAssertFalse(journal.sessionID.isEmpty, file: file, line: line)
        XCTAssertEqual(journal.phase, journalPhase, file: file, line: line)
        XCTAssertEqual(journal.wifiBaseline.device, "en0", file: file, line: line)
        XCTAssertEqual(
            journal.wifiBaseline.powerEnabled,
            baselinePower,
            file: file,
            line: line
        )
        XCTAssertFalse(journal.leaseRequestID.isEmpty, file: file, line: line)
        if let binding = journal.leaseBinding {
            assertBindingOwnedByJournal(binding, journal: journal, file: file, line: line)
        } else {
            XCTFail("Crash journal is missing the helper lease binding.", file: file, line: line)
        }
        XCTAssertEqual(journal.leaseStatus, "active", file: file, line: line)
        XCTAssertFalse(journal.pendingMutation?.id.isEmpty ?? true, file: file, line: line)
        XCTAssertEqual(journal.pendingMutation?.kind, mutationKind, file: file, line: line)
        XCTAssertEqual(journal.pendingMutation?.baseline, mutationBaseline, file: file, line: line)
        XCTAssertEqual(journal.pendingMutation?.target, mutationTarget, file: file, line: line)
        let expectedPhase = checkpoint == "after-intent-persist" ? "prepared" :
            checkpoint == "after-dispatch" ? "dispatched" : "verified"
        XCTAssertEqual(journal.pendingMutation?.phase, expectedPhase, file: file, line: line)
    }

    func assertBindingOwnedByJournal(
        _ binding: LeaseBinding,
        journal: JournalArtifact,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(binding.sessionID, journal.sessionID, file: file, line: line)
        XCTAssertEqual(binding.requestID, journal.leaseRequestID, file: file, line: line)
        XCTAssertFalse(binding.leaseID.isEmpty, file: file, line: line)
        XCTAssertFalse(binding.generation.isEmpty, file: file, line: line)
    }

    func assertOnlyField(
        _ expectedField: String,
        differsBetween expected: LeaseBinding,
        and actual: LeaseBinding,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let differences = [
            "session_id": expected.sessionID != actual.sessionID,
            "request_id": expected.requestID != actual.requestID,
            "lease_id": expected.leaseID != actual.leaseID,
            "generation": expected.generation != actual.generation
        ].filter(\.value).map(\.key)
        XCTAssertEqual(differences, [expectedField], file: file, line: line)
    }
}
