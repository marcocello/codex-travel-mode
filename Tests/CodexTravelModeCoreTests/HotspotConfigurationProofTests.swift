import Foundation
import XCTest

final class HotspotConfigurationProofTests: XCTestCase {
    func testArtifactSchemaRejectsSelfAttestationAndNonPrivateSecretLeakage() throws {
        let artifact = try ProofArtifact.load()

        XCTAssertEqual(try integer("schema_version", in: artifact.document), 1)
        XCTAssertGreaterThanOrEqual(artifact.scenarios.count, 32)

        let forbidden = forbiddenKeyPaths(in: artifact.document)
        XCTAssertEqual(forbidden, [], "Raw evidence must not contain producer-authored verdicts")

        for scenario in artifact.scenarios {
            XCTAssertFalse(try scenario.string("name").isEmpty)
            XCTAssertFalse(try scenario.string("launch_id").isEmpty)
            XCTAssertGreaterThan(try scenario.integer("pid"), 0)
            XCTAssertFalse(try scenario.array("operations").isEmpty)
            _ = try scenario.array("options")
            _ = try scenario.object("control_enabled_states")
            try assertSequentialOperations(scenario)
            if scenario.object["control_state_source"] != nil {
                try assertRenderedControlSnapshot(in: scenario)
            }
        }

        try assertSentinelAbsentFromNonPrivateJSON(under: artifact.outputURL)
    }

    func testDiscoveryLoadingExactIdentityStatesAndStaleRefresh() throws {
        let artifact = try ProofArtifact.load()
        let fresh = try artifact.onlyScenario(named: "fresh-loading")
        XCTAssertEqual(try fresh.string("discovery_state"), "loading")
        XCTAssertEqual(try fresh.options(), [])
        XCTAssertEqual(try fresh.string("draft_ssid"), "")
        XCTAssertNil(try fresh.optionalString("committed_ssid"))
        XCTAssertFalse(try fresh.bool("start_eligibility"))
        XCTAssertFalse(try control("refresh_networks", in: fresh))
        XCTAssertTrue(try operationNames(in: fresh).contains("loading_observed"))
        XCTAssertTrue(
            try renderedMessages(in: fresh).contains("Loading remembered and nearby networks…")
        )
        try assertNativeScreenshot(in: fresh)
        try assertNoSecretReadDelta(in: fresh)

        let exact = try artifact.onlyScenario(named: "exact-discovery-order")
        let expectedNames = [
            "Office",
            "Caf\u{00E9}",
            "Example iPhone",
            "Airport",
            "Cafe\u{0301}",
            "office",
        ]
        XCTAssertEqual(try exact.options(), expectedNames.map(ObservedOption.init))
        XCTAssertEqual(try exact.string("draft_ssid"), "")
        XCTAssertNil(try exact.optionalString("committed_ssid"))
        XCTAssertFalse(try exact.bool("start_eligibility"))
        XCTAssertTrue(try renderedMessages(in: exact).contains("Network list refreshed."))
        try assertNativeScreenshot(in: exact)
        try assertNoSecretReadDelta(in: exact)

        let expectedStates: Set<String> = [
            "not_determined",
            "denied",
            "restricted",
            "services_disabled",
            "no_wifi_interface",
            "provider_failed",
            "completed",
        ]
        let matrix = try artifact.scenarios(named: "discovery-status-matrix")
        XCTAssertEqual(matrix.count, expectedStates.count)
        XCTAssertEqual(Set(try matrix.map { try $0.string("discovery_state") }), expectedStates)
        for scenario in matrix {
            let state = try scenario.string("discovery_state")
            let expectedOptions = state == "completed" ? [] : [ObservedOption("Office")]
            XCTAssertEqual(try scenario.options(), expectedOptions, "Unexpected options for \(state)")
            XCTAssertTrue(try control("manual_ssid", in: scenario))
            XCTAssertTrue(try control("refresh_networks", in: scenario))
            try assertNoSecretReadDelta(in: scenario)
        }

        let denied = try artifact.onlyScenario(
            named: "discovery-status-matrix",
            field: "discovery_state",
            value: "denied"
        )
        XCTAssertTrue(
            try renderedMessages(in: denied).contains(
                "Location permission was denied. Remembered networks remain selectable."
            )
        )

        let screenshotStates = [
            ("not_determined", "Location permission is needed to show nearby networks. Refresh Networks requests it."),
            ("no_wifi_interface", "No Wi-Fi interface is available. Enter the SSID manually when Wi-Fi is available."),
            ("provider_failed", "Wi-Fi networks could not be loaded. Enter the SSID manually or try again."),
            ("completed", "No remembered or nearby networks were found. Enter the SSID manually."),
        ]
        for (state, message) in screenshotStates {
            let scenario = try artifact.onlyScenario(
                named: "discovery-status-matrix",
                field: "discovery_state",
                value: state
            )
            XCTAssertTrue(try renderedMessages(in: scenario).contains(message), state)
            try assertNativeScreenshot(in: scenario)
        }

        let stale = try artifact.onlyScenario(named: "stale-refresh")
        XCTAssertEqual(try stale.string("draft_ssid"), "Manual Draft")
        XCTAssertEqual(try stale.options(), [ObservedOption("Latest Network")])
        XCTAssertFalse(try operationNames(in: stale).contains("Stale Network"))
        try assertNoSecretReadDelta(in: stale)
    }

    func testManualSaveAndUnsavedDraftRuntimeIsolation() throws {
        let artifact = try ProofArtifact.load()
        let manual = try artifact.onlyScenario(named: "manual-save-after-denial")
        XCTAssertEqual(try manual.string("discovery_state"), "denied")
        XCTAssertEqual(try manual.string("draft_ssid"), "Example iPhone")
        XCTAssertEqual(try manual.string("committed_ssid"), "Example iPhone")
        XCTAssertEqual(try manual.string("wifi_device"), "en0")
        XCTAssertTrue(try manual.bool("start_eligibility"))
        XCTAssertFalse(try control("save_hotspot", in: manual))
        XCTAssertTrue(try control("start", in: manual))
        XCTAssertEqual(try operationValue("store_save_count", in: manual), "1")
        XCTAssertNil(try manual.revision("before_revision"))
        let manualRevision = try XCTUnwrap(manual.revision("after_revision"))
        XCTAssertEqual(manualRevision.ssid, "Example iPhone")
        XCTAssertEqual(manualRevision.wifiDevice, "en0")
        XCTAssertEqual(try manual.array("credential_inventory").count, 1)
        let manualReads = try secretReadCounts(in: manual)
        XCTAssertEqual(manualReads.afterActions - manualReads.afterInitialization, 1)
        XCTAssertEqual(manualReads.afterRender, manualReads.afterActions)
        try assertNativeScreenshot(in: manual)

        let unsaved = try artifact.onlyScenario(named: "unsaved-draft-start")
        XCTAssertEqual(try unsaved.string("draft_ssid"), "Draft iPhone")
        XCTAssertEqual(try unsaved.string("committed_ssid"), "Example iPhone")
        XCTAssertFalse(try unsaved.bool("start_eligibility"))
        XCTAssertEqual(try operationValue("session_start_count", in: unsaved), "0")
        XCTAssertEqual(try operationValue("keep_awake_start_count", in: unsaved), "0")
        XCTAssertEqual(try operationValue("association_count", in: unsaved), "0")
        XCTAssertEqual(
            try unsaved.revision("before_revision"),
            try unsaved.revision("after_revision")
        )
        try assertNoSecretReadDelta(in: unsaved)
    }

    func testSavedSelectionSurvivesFailureAndEveryLifecycleLocksMutation() throws {
        let artifact = try ProofArtifact.load()
        let saved = try artifact.onlyScenario(named: "saved-selection-after-failure")
        XCTAssertEqual(try saved.string("discovery_state"), "provider_failed")
        XCTAssertEqual(try saved.options(), [ObservedOption("Example iPhone")])
        XCTAssertEqual(try saved.string("draft_ssid"), "Example iPhone")
        XCTAssertEqual(try saved.string("committed_ssid"), "Example iPhone")
        XCTAssertTrue(try saved.bool("start_eligibility"))
        XCTAssertEqual(
            try saved.revision("before_revision"),
            try saved.revision("after_revision")
        )
        try assertNativeScreenshot(in: saved)
        try assertNoSecretReadDelta(in: saved)

        let lockedLifecycles = ["preparing", "active", "restoring", "cleanup_required"]
        let lockedScenarios = try artifact.scenarios(named: "lifecycle-lock-matrix")
        XCTAssertEqual(lockedScenarios.count, lockedLifecycles.count)
        XCTAssertEqual(
            Set(try lockedScenarios.map { try $0.string("lifecycle") }),
            Set(lockedLifecycles)
        )
        for lifecycle in lockedLifecycles {
            let scenario = try artifact.onlyScenario(
                named: "lifecycle-lock-matrix",
                field: "lifecycle",
                value: lifecycle
            )
            XCTAssertTrue(try scenario.bool("configuration_locked"))
            XCTAssertFalse(try scenario.bool("start_eligibility"))
            for controlName in [
                "discovered_network",
                "manual_ssid",
                "password",
                "refresh_networks",
                "save_hotspot",
                "start",
            ] {
                XCTAssertFalse(try control(controlName, in: scenario), "\(controlName) in \(lifecycle)")
            }
            XCTAssertEqual(try operationValue("discovery_request_count", in: scenario), "0")
            XCTAssertEqual(try operationValue("store_save_count", in: scenario), "0")
            XCTAssertEqual(try operationValue("session_start_count", in: scenario), "0")
            XCTAssertEqual(
                try scenario.revision("before_revision"),
                try scenario.revision("after_revision")
            )
            if lifecycle == "active" {
                XCTAssertTrue(
                    try renderedMessages(in: scenario).contains(
                        "Hotspot configuration is locked while Travel Mode is active or changing state."
                    )
                )
                try assertNativeScreenshot(in: scenario)
            }
            try assertNoSecretReadDelta(in: scenario)
        }
    }

    func testSaveStartAndQuitRacesSerializeAtCoherentBoundaries() throws {
        let artifact = try ProofArtifact.load()

        let doubleSave = try artifact.onlyScenario(named: "double-save-race")
        XCTAssertEqual(try operationValue("save_gate_entered", in: doubleSave), "true")
        XCTAssertEqual(try operationValue("second_save_error", in: doubleSave), "cleanup_pending")
        XCTAssertEqual(try operationValue("first_save_result", in: doubleSave), "success")
        XCTAssertEqual(try operationValue("store_save_count", in: doubleSave), "1")
        XCTAssertEqual(try doubleSave.revision("after_revision")?.wifiDevice, "en1")
        XCTAssertTrue(try doubleSave.bool("start_eligibility"))

        let saveStart = try artifact.onlyScenario(named: "save-start-race")
        XCTAssertEqual(try operationValue("save_gate_entered", in: saveStart), "true")
        XCTAssertEqual(
            try operationValue("session_start_count_during_save", in: saveStart),
            "0"
        )
        XCTAssertEqual(try operationValue("save_result", in: saveStart), "success")
        XCTAssertEqual(try operationValue("store_save_count", in: saveStart), "1")
        XCTAssertEqual(try operationValue("session_start_count_final", in: saveStart), "0")
        XCTAssertEqual(try saveStart.revision("after_revision")?.wifiDevice, "en1")

        let saveFirstQuit = try artifact.onlyScenario(
            named: "quit-save-race",
            field: "variant",
            value: "save-first"
        )
        XCTAssertEqual(
            try operationValue("quit_count_before_release", in: saveFirstQuit),
            "0"
        )
        XCTAssertEqual(
            try operationValue("second_save_error", in: saveFirstQuit),
            "cleanup_pending"
        )
        XCTAssertEqual(try operationValue("save_result", in: saveFirstQuit), "success")
        XCTAssertEqual(try operationValue("quit_result", in: saveFirstQuit), "true")
        XCTAssertEqual(try operationValue("quit_count_final", in: saveFirstQuit), "1")
        XCTAssertEqual(try operationValue("store_save_count", in: saveFirstQuit), "1")
        XCTAssertEqual(try operationValue("session_start_count", in: saveFirstQuit), "0")
        XCTAssertEqual(try saveFirstQuit.revision("after_revision")?.wifiDevice, "en1")

        let quitFirstSave = try artifact.onlyScenario(
            named: "quit-save-race",
            field: "variant",
            value: "quit-first"
        )
        XCTAssertEqual(try operationValue("quit_stop_gate_entered", in: quitFirstSave), "true")
        XCTAssertEqual(try operationValue("save_error", in: quitFirstSave), "cleanup_pending")
        XCTAssertEqual(
            try operationValue("store_save_count_before_release", in: quitFirstSave),
            "0"
        )
        XCTAssertEqual(
            try operationValue("session_start_count_before_release", in: quitFirstSave),
            "0"
        )
        XCTAssertEqual(
            try operationValue("discovery_request_count_before_release", in: quitFirstSave),
            "0"
        )
        XCTAssertEqual(try operationValue("quit_result", in: quitFirstSave), "true")
        XCTAssertEqual(try operationValue("quit_count_final", in: quitFirstSave), "1")
        XCTAssertEqual(
            try quitFirstSave.revision("before_revision"),
            try quitFirstSave.revision("after_revision")
        )

        for scenario in [saveFirstQuit, quitFirstSave] {
            XCTAssertTrue(try scenario.bool("configuration_locked"), scenario.context)
            for controlName in [
                "discovered_network",
                "manual_ssid",
                "password",
                "refresh_networks",
                "save_hotspot",
                "start",
            ] {
                XCTAssertFalse(try control(controlName, in: scenario), scenario.context)
            }
        }
    }

    func testFaultCategoriesResolveToPriorOrCommittedCandidate() throws {
        let artifact = try ProofArtifact.load()
        let expected = [
            FaultExpectation(
                "keychain-stage-failure",
                fault: "credential_stage_failure",
                error: "credential_stage_failed",
                activeSSID: "Old iPhone",
                inventoryCount: 1,
                operation: "credential_stage_failure"
            ),
            FaultExpectation(
                "keychain-verification-failure",
                fault: "credential_verification_mismatch",
                error: "credential_readback_mismatch",
                activeSSID: "Old iPhone",
                inventoryCount: 1,
                operation: "credential_verification_mismatch"
            ),
            FaultExpectation(
                "keychain-verification-read-failure",
                fault: "credential_verification_read_failure",
                error: "credential_verification_read_failed",
                activeSSID: "Old iPhone",
                inventoryCount: 1,
                operation: "credential_verification_read_failure"
            ),
            FaultExpectation(
                "pointer-commit-failure",
                fault: "active_pointer_precommit_failure",
                error: "persistence_failed",
                activeSSID: "Old iPhone",
                inventoryCount: 1,
                operation: "active_pointer_precommit_failure"
            ),
            FaultExpectation(
                "pointer-ambiguous-readback",
                fault: "active_pointer_ambiguous_failure",
                error: nil,
                activeSSID: "New iPhone",
                inventoryCount: 1,
                operation: "active_pointer_ambiguous_failure"
            ),
            FaultExpectation(
                "credential-cleanup-failure",
                fault: "cleanup_deletion_failure",
                error: "cleanup_failed",
                activeSSID: "New iPhone",
                inventoryCount: 2,
                operation: "credential_cleanup_failure",
                journalPhase: "cleanup_pending"
            ),
        ]

        for item in expected {
            let scenario = try artifact.onlyScenario(named: item.name)
            XCTAssertEqual(try scenario.string("injected_fault"), item.fault)
            XCTAssertEqual(try scenario.optionalString("error_category"), item.error)
            let before = try XCTUnwrap(scenario.revision("before_revision"))
            let after = try XCTUnwrap(scenario.revision("after_revision"))
            XCTAssertEqual(before.ssid, "Old iPhone")
            XCTAssertEqual(after.ssid, item.activeSSID)
            if item.activeSSID == "Old iPhone" {
                XCTAssertEqual(after, before, item.name)
            } else {
                XCTAssertNotEqual(after.revisionID, before.revisionID, item.name)
                XCTAssertNotEqual(after.credentialReference, before.credentialReference, item.name)
            }
            XCTAssertEqual(try scenario.optionalJournalPhase(), item.journalPhase)
            let inventory = try scenario.credentialInventory()
            XCTAssertEqual(inventory.count, item.inventoryCount, item.name)
            try assertActiveCredential(after, isPresentIn: inventory, context: item.name)
            XCTAssertTrue(try operationNames(in: scenario).contains(item.operation), item.name)
        }
    }

    func testFourSIGKILLBoundariesRecoverInDistinctProcesses() throws {
        let artifact = try ProofArtifact.load()
        let expected = [
            CrashExpectation("crash-before-staging", boundary: "before_staging", phase: "prepared", activeSSID: "Old iPhone"),
            CrashExpectation("crash-after-staging", boundary: "after_verified_staging", phase: "credential_staged", activeSSID: "Old iPhone"),
            CrashExpectation("crash-after-pointer-commit", boundary: "after_pointer_commit", phase: "pointer_committed", activeSSID: "New iPhone"),
            CrashExpectation("crash-during-cleanup", boundary: "during_cleanup", phase: "cleanup_pending", activeSSID: "New iPhone"),
        ]
        var allPIDs: [Int] = []
        var launchIDs: [String] = []

        for item in expected {
            let scenario = try artifact.onlyScenario(named: item.name)
            let killedPID = try scenario.integer("pid")
            let recoveryPID = try scenario.integer("recovery_pid")
            let killedLaunchID = try scenario.string("launch_id")
            let recoveryLaunchID = try scenario.string("recovery_launch_id")
            allPIDs.append(contentsOf: [killedPID, recoveryPID])
            launchIDs.append(contentsOf: [killedLaunchID, recoveryLaunchID])
            XCTAssertNotEqual(killedPID, recoveryPID)
            XCTAssertEqual(try scenario.integer("checkpoint_pid"), killedPID)
            XCTAssertEqual(try scenario.integer("wait_status"), 137)
            XCTAssertEqual(try scenario.string("process_state_after_wait"), "reaped")
            XCTAssertEqual(try scenario.string("termination_signal"), "SIGKILL")
            XCTAssertEqual(try scenario.string("boundary"), item.boundary)
            XCTAssertEqual(try scenario.journal("checkpoint_journal").phase, item.phase)
            XCTAssertNil(try scenario.optionalObject("save_journal"))
            XCTAssertTrue(try scenario.bool("start_eligibility"))

            let before = try XCTUnwrap(scenario.revision("before_revision"))
            let after = try XCTUnwrap(scenario.revision("after_revision"))
            XCTAssertEqual(before.ssid, "Old iPhone")
            XCTAssertEqual(after.ssid, item.activeSSID)
            if item.activeSSID == "Old iPhone" {
                XCTAssertEqual(after, before, item.name)
            } else {
                XCTAssertNotEqual(after.revisionID, before.revisionID, item.name)
                XCTAssertNotEqual(after.credentialReference, before.credentialReference, item.name)
            }

            let inventory = try scenario.credentialInventory()
            XCTAssertEqual(inventory.count, 1, item.name)
            try assertActiveCredential(after, isPresentIn: inventory, context: item.name)
            let operations = try operationNames(in: scenario)
            XCTAssertTrue(operations.contains("checkpoint_\(item.phase)"), item.name)
            XCTAssertTrue(operations.contains("recovery_started"), item.name)
            XCTAssertTrue(operations.contains("recovery_returned"), item.name)
            XCTAssertTrue(operations.contains("active_credential_validated"), item.name)

            let rawOperations = try scenario.array("operations").enumerated().map { index, raw in
                try object(raw, context: "\(scenario.context).operations[\(index)]")
            }
            let killedOperations = try rawOperations.filter {
                try string("launch_id", in: $0, context: scenario.context) == killedLaunchID
            }
            XCTAssertFalse(killedOperations.isEmpty, item.name)
            for operation in killedOperations {
                XCTAssertEqual(
                    try integer("pid", in: operation, context: scenario.context),
                    killedPID,
                    item.name
                )
            }
            XCTAssertEqual(
                try string(
                    "operation",
                    in: try XCTUnwrap(killedOperations.last),
                    context: scenario.context
                ),
                "checkpoint_\(item.phase)",
                item.name
            )

            let recoveryOperations = try rawOperations.filter {
                try string("launch_id", in: $0, context: scenario.context) == recoveryLaunchID
            }
            XCTAssertFalse(recoveryOperations.isEmpty, item.name)
            for operation in recoveryOperations {
                XCTAssertEqual(
                    try integer("pid", in: operation, context: scenario.context),
                    recoveryPID,
                    item.name
                )
            }
        }

        XCTAssertEqual(Set(allPIDs).count, allPIDs.count)
        XCTAssertEqual(Set(launchIDs).count, launchIDs.count)
    }

    func testLegacyInvalidDeviceMigratesToNilWithoutSecretOrJournalResidue() throws {
        let artifact = try ProofArtifact.load()
        let scenario = try artifact.onlyScenario(named: "legacy-migration")
        XCTAssertNil(try scenario.revision("before_revision"))
        let active = try XCTUnwrap(scenario.revision("after_revision"))
        XCTAssertEqual(active.ssid, "Legacy iPhone")
        XCTAssertNil(active.wifiDevice)
        XCTAssertFalse(try scenario.bool("start_eligibility"))
        XCTAssertNil(try scenario.optionalString("error_category"))
        XCTAssertNil(try scenario.optionalObject("save_journal"))

        let inventory = try scenario.credentialInventory()
        XCTAssertEqual(inventory.count, 1)
        try assertActiveCredential(active, isPresentIn: inventory, context: "legacy-migration")
        XCTAssertFalse(inventory.contains { $0.credentialReference == "fallbackHotspotPassword" })
        let operations = try operationNames(in: scenario)
        XCTAssertTrue(operations.contains("legacy_configuration_seeded"))
        XCTAssertTrue(operations.contains("legacy_active_credential_validated"))
        XCTAssertTrue(operations.contains("legacy_migration_returned"))
        XCTAssertTrue(operations.contains("credential_cleanup"))
    }
}

private typealias JSONObject = [String: Any]

private struct ProofArtifact {
    let outputURL: URL
    let document: JSONObject
    let scenarios: [Scenario]

    static func load() throws -> ProofArtifact {
        guard let outputPath = ProcessInfo.processInfo.environment[
            "HOTSPOT_CONFIGURATION_PROOF_OUTPUT"
        ], !outputPath.isEmpty else {
            throw XCTSkip("HOTSPOT_CONFIGURATION_PROOF_OUTPUT is not set")
        }
        let outputURL = URL(fileURLWithPath: outputPath, isDirectory: true).standardizedFileURL
        let readbackURL = outputURL.appendingPathComponent("provider-readback.json")
        guard FileManager.default.fileExists(atPath: readbackURL.path) else {
            throw ProofArtifactError("Missing provider read-back at \(readbackURL.path)")
        }
        let data = try Data(contentsOf: readbackURL)
        let raw = try JSONSerialization.jsonObject(with: data, options: [])
        let document = try object(raw, context: "provider-readback.json")
        let scenarios = try array("scenarios", in: document).enumerated().map { index, raw in
            Scenario(
                object: try object(raw, context: "scenarios[\(index)]"),
                context: "scenarios[\(index)]"
            )
        }
        guard !scenarios.isEmpty else {
            throw ProofArtifactError("provider-readback.json contains no scenarios")
        }
        return ProofArtifact(outputURL: outputURL, document: document, scenarios: scenarios)
    }

    func scenarios(named name: String) throws -> [Scenario] {
        try scenarios.filter { try $0.string("name") == name }
    }

    func onlyScenario(named name: String) throws -> Scenario {
        let matches = try scenarios(named: name)
        guard matches.count == 1 else {
            throw ProofArtifactError("Expected one '\(name)' scenario; found \(matches.count)")
        }
        return matches[0]
    }

    func onlyScenario(named name: String, field: String, value: String) throws -> Scenario {
        let matches = try scenarios(named: name).filter { try $0.string(field) == value }
        guard matches.count == 1 else {
            throw ProofArtifactError(
                "Expected one '\(name)' scenario with \(field)=\(value); found \(matches.count)"
            )
        }
        return matches[0]
    }
}

private struct Scenario {
    let object: JSONObject
    let context: String

    func string(_ key: String) throws -> String {
        try CodexTravelModeCoreTests.string(key, in: object, context: context)
    }

    func optionalString(_ key: String) throws -> String? {
        try CodexTravelModeCoreTests.optionalString(key, in: object, context: context)
    }

    func integer(_ key: String) throws -> Int {
        try CodexTravelModeCoreTests.integer(key, in: object, context: context)
    }

    func bool(_ key: String) throws -> Bool {
        try CodexTravelModeCoreTests.bool(key, in: object, context: context)
    }

    func array(_ key: String) throws -> [Any] {
        try CodexTravelModeCoreTests.array(key, in: object, context: context)
    }

    func object(_ key: String) throws -> JSONObject {
        try CodexTravelModeCoreTests.object(object[key], context: "\(context).\(key)")
    }

    func optionalObject(_ key: String) throws -> JSONObject? {
        guard let raw = object[key], !(raw is NSNull) else { return nil }
        return try CodexTravelModeCoreTests.object(raw, context: "\(context).\(key)")
    }

    func options() throws -> [ObservedOption] {
        try array("options").enumerated().map { index, raw in
            let value = try CodexTravelModeCoreTests.object(
                raw,
                context: "\(context).options[\(index)]"
            )
            let name = try CodexTravelModeCoreTests.string(
                "display_name",
                in: value,
                context: context
            )
            let hex = try CodexTravelModeCoreTests.string(
                "utf8_hex",
                in: value,
                context: context
            )
            let option = ObservedOption(displayName: name, utf8Hex: hex)
            guard option.utf8Hex == Data(option.displayName.utf8).lowerHex else {
                throw ProofArtifactError("Option display bytes disagree in \(context): \(name)")
            }
            return option
        }
    }

    func revision(_ key: String) throws -> ObservedRevision? {
        guard let value = try optionalObject(key) else { return nil }
        return try ObservedRevision(value, context: "\(context).\(key)")
    }

    func journal(_ key: String) throws -> ObservedJournal {
        ObservedJournal(
            phase: try CodexTravelModeCoreTests.string(
                "phase",
                in: object(key),
                context: "\(context).\(key)"
            )
        )
    }

    func optionalJournalPhase() throws -> String? {
        guard let journal = try optionalObject("save_journal") else { return nil }
        return try CodexTravelModeCoreTests.string(
            "phase",
            in: journal,
            context: "\(context).save_journal"
        )
    }

    func credentialInventory() throws -> [ObservedCredential] {
        try array("credential_inventory").enumerated().map { index, raw in
            try ObservedCredential(
                CodexTravelModeCoreTests.object(
                    raw,
                    context: "\(context).credential_inventory[\(index)]"
                ),
                context: "\(context).credential_inventory[\(index)]"
            )
        }
    }
}

private struct ObservedOption: Equatable {
    let displayName: String
    let utf8Hex: String

    init(_ displayName: String) {
        self.init(displayName: displayName, utf8Hex: Data(displayName.utf8).lowerHex)
    }

    init(displayName: String, utf8Hex: String) {
        self.displayName = displayName
        self.utf8Hex = utf8Hex
    }
}

private struct ObservedRevision: Equatable {
    let schemaVersion: Int?
    let revisionID: String
    let ssid: String
    let wifiDevice: String?
    let credentialReference: String

    init(_ value: JSONObject, context: String) throws {
        schemaVersion = try optionalInteger("schema_version", in: value, context: context)
        revisionID = try string("revision_id", in: value, context: context)
        ssid = try string("ssid", in: value, context: context)
        wifiDevice = try optionalString("wifi_device", in: value, context: context)
        credentialReference = try string("credential_reference", in: value, context: context)
        guard !revisionID.isEmpty, !credentialReference.isEmpty else {
            throw ProofArtifactError("Empty revision identity in \(context)")
        }
        if let schemaVersion, schemaVersion != 1 {
            throw ProofArtifactError("Unexpected revision schema \(schemaVersion) in \(context)")
        }
    }
}

private struct ObservedCredential {
    let credentialReference: String
    let fingerprint: String

    init(_ value: JSONObject, context: String) throws {
        credentialReference = try string("credential_reference", in: value, context: context)
        fingerprint = try string("fingerprint", in: value, context: context)
        guard !credentialReference.isEmpty,
              fingerprint.range(
                of: #"^[0-9a-f]{64}$"#,
                options: .regularExpression
              ) != nil else {
            throw ProofArtifactError("Invalid redacted credential inventory item in \(context)")
        }
    }
}

private struct ObservedJournal {
    let phase: String
}

private struct SecretReadCounts {
    let afterInitialization: Int
    let afterActions: Int
    let afterRender: Int
}

private struct FaultExpectation {
    let name: String
    let fault: String
    let error: String?
    let activeSSID: String
    let inventoryCount: Int
    let operation: String
    let journalPhase: String?

    init(
        _ name: String,
        fault: String,
        error: String?,
        activeSSID: String,
        inventoryCount: Int,
        operation: String,
        journalPhase: String? = nil
    ) {
        self.name = name
        self.fault = fault
        self.error = error
        self.activeSSID = activeSSID
        self.inventoryCount = inventoryCount
        self.operation = operation
        self.journalPhase = journalPhase
    }
}

private struct CrashExpectation {
    let name: String
    let boundary: String
    let phase: String
    let activeSSID: String

    init(_ name: String, boundary: String, phase: String, activeSSID: String) {
        self.name = name
        self.boundary = boundary
        self.phase = phase
        self.activeSSID = activeSSID
    }
}

private func control(_ name: String, in scenario: Scenario) throws -> Bool {
    try bool(
        name,
        in: scenario.object("control_enabled_states"),
        context: "\(scenario.context).control_enabled_states"
    )
}

private func renderedMessages(in scenario: Scenario) throws -> [String] {
    try scenario.array("rendered_messages").enumerated().map { index, raw in
        guard let message = raw as? String else {
            throw ProofArtifactError(
                "Expected string at \(scenario.context).rendered_messages[\(index)]"
            )
        }
        return message
    }
}

private func assertRenderedControlSnapshot(in scenario: Scenario) throws {
    XCTAssertEqual(
        try scenario.string("control_state_source"),
        "in_process_accessibility_hierarchy",
        scenario.context
    )
    let elements = try scenario.array("rendered_elements").enumerated().map { index, raw in
        try object(raw, context: "\(scenario.context).rendered_elements[\(index)]")
    }
    XCTAssertGreaterThanOrEqual(elements.count, 10, scenario.context)
    XCTAssertFalse(try renderedMessages(in: scenario).isEmpty, scenario.context)

    let controls = [
        "discovered_network": "hotspot.discovered-network",
        "manual_ssid": "hotspot.manual-ssid",
        "password": "hotspot.password",
        "refresh_networks": "hotspot.refresh-networks",
        "save_hotspot": "hotspot.save",
        "primary_action": "travel.primary-action",
    ]
    for (controlName, identifier) in controls {
        let matches = try elements.filter {
            try optionalString("identifier", in: $0, context: scenario.context) == identifier
        }
        XCTAssertEqual(matches.count, 1, "\(identifier) in \(scenario.context)")
        let element = try XCTUnwrap(matches.first)
        XCTAssertEqual(
            try bool("enabled", in: element, context: scenario.context),
            try control(controlName, in: scenario),
            identifier
        )
        XCTAssertGreaterThan(try integer("width", in: try object(element["frame"], context: scenario.context)), 0)
        XCTAssertGreaterThan(try integer("height", in: try object(element["frame"], context: scenario.context)), 0)
        XCTAssertFalse(try string("source_class", in: element, context: scenario.context).isEmpty)
    }

    let password = try XCTUnwrap(elements.first {
        (try? optionalString("identifier", in: $0, context: scenario.context)) == "hotspot.password"
    })
    XCTAssertTrue(try bool("protected_content", in: password, context: scenario.context))
    XCTAssertNil(try optionalString("value", in: password, context: scenario.context))

    let primary = try XCTUnwrap(elements.first {
        (try? optionalString("identifier", in: $0, context: scenario.context)) == "travel.primary-action"
    })
    let primaryName = try optionalString("label", in: primary, context: scenario.context)
        ?? optionalString("value", in: primary)
    let primaryEnabled = try bool("enabled", in: primary, context: scenario.context)
    XCTAssertEqual(try control("start", in: scenario), primaryName == "Start" && primaryEnabled)
    XCTAssertEqual(
        try control("stop", in: scenario),
        primaryName == "Stop & Restore" && primaryEnabled
    )
}

private func secretReadCounts(in scenario: Scenario) throws -> SecretReadCounts {
    let counts = try scenario.object("secret_read_counts")
    return SecretReadCounts(
        afterInitialization: try integer(
            "after_initialization",
            in: counts,
            context: scenario.context
        ),
        afterActions: try integer("after_scenario_actions", in: counts, context: scenario.context),
        afterRender: try integer("after_render", in: counts, context: scenario.context)
    )
}

private func assertNoSecretReadDelta(in scenario: Scenario) throws {
    let counts = try secretReadCounts(in: scenario)
    XCTAssertEqual(counts.afterActions, counts.afterInitialization, scenario.context)
    XCTAssertEqual(counts.afterRender, counts.afterActions, scenario.context)
}

private func operationNames(in scenario: Scenario) throws -> [String] {
    try scenario.array("operations").enumerated().map { index, raw in
        let operation = try object(raw, context: "\(scenario.context).operations[\(index)]")
        if let name = try optionalString("name", in: operation, context: scenario.context) {
            return name
        }
        return try string("operation", in: operation, context: scenario.context)
    }
}

private func operationValue(_ name: String, in scenario: Scenario) throws -> String? {
    for (index, raw) in try scenario.array("operations").enumerated() {
        let operation = try object(raw, context: "\(scenario.context).operations[\(index)]")
        let observedName = try optionalString("name", in: operation, context: scenario.context)
            ?? optionalString("operation", in: operation)
        if observedName == name {
            return try optionalString("value", in: operation, context: scenario.context)
        }
    }
    return nil
}

private func assertSequentialOperations(_ scenario: Scenario) throws {
    let operations = try scenario.array("operations")
    let sequence = try operations.enumerated().map { index, raw in
        try integer(
            "sequence",
            in: object(raw, context: "\(scenario.context).operations[\(index)]"),
            context: scenario.context
        )
    }
    XCTAssertEqual(sequence, Array(1...operations.count), scenario.context)
}

private func assertNativeScreenshot(in scenario: Scenario) throws {
    let screenshot = try XCTUnwrap(scenario.optionalObject("screenshot"))
    XCTAssertFalse(try string("path", in: screenshot, context: scenario.context).isEmpty)
    XCTAssertFalse(
        try string("rendered_view_identifier", in: screenshot, context: scenario.context).isEmpty
    )
    XCTAssertGreaterThanOrEqual(try integer("width", in: screenshot), 280)
    XCTAssertGreaterThanOrEqual(try integer("height", in: screenshot), 180)
    XCTAssertEqual(
        try integer("source_pid", in: screenshot),
        try scenario.integer("pid")
    )
}

private func assertActiveCredential(
    _ revision: ObservedRevision,
    isPresentIn inventory: [ObservedCredential],
    context: String
) throws {
    let matching = inventory.filter {
        $0.credentialReference == revision.credentialReference
    }
    guard matching.count == 1 else {
        throw ProofArtifactError(
            "Expected exactly one active credential in \(context); found \(matching.count)"
        )
    }
}

private func assertSentinelAbsentFromNonPrivateJSON(under outputURL: URL) throws {
    let sentinel = ProcessInfo.processInfo.environment["HOTSPOT_PROOF_PASSWORD_SENTINEL"]
        ?? "hotspot-proof-password-sentinel-7f3c"
    let privateRoot = outputURL.appendingPathComponent("private", isDirectory: true)
        .standardizedFileURL
    guard let enumerator = FileManager.default.enumerator(
        at: outputURL,
        includingPropertiesForKeys: [.isDirectoryKey],
        options: [.skipsHiddenFiles]
    ) else {
        throw ProofArtifactError("Could not enumerate proof output at \(outputURL.path)")
    }
    var scannedCount = 0
    while let url = enumerator.nextObject() as? URL {
        let standardized = url.standardizedFileURL
        if standardized.path == privateRoot.path {
            enumerator.skipDescendants()
            continue
        }
        if standardized.path.hasPrefix(privateRoot.path + "/") { continue }
        guard standardized.pathExtension.lowercased() == "json" else { continue }
        let data = try Data(contentsOf: standardized)
        scannedCount += 1
        guard data.range(of: Data(sentinel.utf8)) == nil else {
            throw ProofArtifactError("Password sentinel escaped into \(standardized.path)")
        }
    }
    guard scannedCount > 0 else {
        throw ProofArtifactError("No non-private JSON proof artifacts were scanned")
    }
}

private func forbiddenKeyPaths(in value: Any, path: String = "$" ) -> [String] {
    let forbidden = Set(["verdict", "pass", "passed", "check", "checks"])
    if let object = value as? JSONObject {
        return object.flatMap { key, child -> [String] in
            let childPath = "\(path).\(key)"
            let own = forbidden.contains(key.lowercased()) ? [childPath] : []
            return own + forbiddenKeyPaths(in: child, path: childPath)
        }.sorted()
    }
    if let array = value as? [Any] {
        return array.enumerated().flatMap { index, child in
            forbiddenKeyPaths(in: child, path: "\(path)[\(index)]")
        }.sorted()
    }
    return []
}

private func object(_ value: Any?, context: String) throws -> JSONObject {
    guard let value = value as? JSONObject else {
        throw ProofArtifactError("Expected object at \(context)")
    }
    return value
}

private func array(_ key: String, in value: JSONObject, context: String = "artifact") throws -> [Any] {
    guard let result = value[key] as? [Any] else {
        throw ProofArtifactError("Expected array at \(context).\(key)")
    }
    return result
}

private func string(_ key: String, in value: JSONObject, context: String = "artifact") throws -> String {
    guard let result = value[key] as? String else {
        throw ProofArtifactError("Expected string at \(context).\(key)")
    }
    return result
}

private func optionalString(
    _ key: String,
    in value: JSONObject,
    context: String = "artifact"
) throws -> String? {
    guard let raw = value[key], !(raw is NSNull) else { return nil }
    guard let result = raw as? String else {
        throw ProofArtifactError("Expected optional string at \(context).\(key)")
    }
    return result
}

private func optionalString(_ key: String, in value: JSONObject) -> String? {
    let raw = value[key]
    return raw is NSNull ? nil : raw as? String
}

private func integer(_ key: String, in value: JSONObject, context: String = "artifact") throws -> Int {
    guard let result = value[key] as? Int else {
        throw ProofArtifactError("Expected integer at \(context).\(key)")
    }
    return result
}

private func optionalInteger(
    _ key: String,
    in value: JSONObject,
    context: String = "artifact"
) throws -> Int? {
    guard let raw = value[key], !(raw is NSNull) else { return nil }
    guard let result = raw as? Int else {
        throw ProofArtifactError("Expected optional integer at \(context).\(key)")
    }
    return result
}

private func bool(_ key: String, in value: JSONObject, context: String = "artifact") throws -> Bool {
    guard let result = value[key] as? Bool else {
        throw ProofArtifactError("Expected Boolean at \(context).\(key)")
    }
    return result
}

private struct ProofArtifactError: LocalizedError {
    let message: String

    init(_ message: String) {
        self.message = message
    }

    var errorDescription: String? { message }
}

private extension Data {
    var lowerHex: String {
        map { String(format: "%02x", $0) }.joined()
    }
}
