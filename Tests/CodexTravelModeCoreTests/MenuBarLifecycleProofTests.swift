import AppKit
import Foundation
import XCTest

private let lifecycleProofSensitiveFailure =
    "PROOF_SECRET_7f4d9a password=hunter-proof /usr/bin/pmset -b disablesleep 1"

final class MenuBarLifecycleProofTests: XCTestCase {
    func testUIEvidenceIsBoundToActualPopoverAndStatusButtonObjects() throws {
        let artifact = try LifecycleArtifact.load()
        for scenario in artifact.scenarios {
            let scenarioName = try scenario.string("name")
            let snapshots = try scenario.records("accessibility_snapshots")
            let contentViewIDs = Set(try snapshots.map { try $0.string("popover_content_view_id") })
            XCTAssertEqual(contentViewIDs.count, 1, scenarioName)
            XCTAssertTrue(try snapshots.allSatisfy {
                let windowNumber = try $0.integer("popover_window_number")
                let buttonID = try $0.string("status_button_object_id")
                return windowNumber > 0
                    && $0.optionalBool("popover_window_visible") == true
                    && !buttonID.isEmpty
            })

            let nativePresses = try scenario.records("input_events").filter {
                $0.optionalString("source") == "native_accessibility_press"
            }
            XCTAssertTrue(try nativePresses.allSatisfy {
                let contentViewID = try $0.string("popover_content_view_id")
                let controlID = try $0.string("control_object_id")
                let windowNumber = try $0.integer("control_window_number")
                return contentViewIDs.contains(contentViewID)
                    && !controlID.isEmpty
                    && windowNumber > 0
            })

            XCTAssertTrue(try scenario.records("status_item_records").allSatisfy {
                let buttonID = try $0.string("button_object_id")
                let imageID = try $0.string("image_object_id")
                let windowNumber = try $0.integer("button_window_number")
                return !buttonID.isEmpty && !imageID.isEmpty && windowNumber > 0
            })
        }

        for screenshot in try artifact.root.records("screenshots") {
            let scenario = try XCTUnwrap(artifact.scenarios.first {
                $0.optionalInteger("pid") == screenshot.optionalInteger("producer_pid")
            })
            let snapshot = try XCTUnwrap(try scenario.records("accessibility_snapshots").first {
                $0.optionalString("snapshot_id") == screenshot.optionalString("accessibility_snapshot_id")
            })
            XCTAssertEqual(
                screenshot.optionalString("popover_content_view_id"),
                snapshot.optionalString("popover_content_view_id")
            )
            XCTAssertEqual(
                screenshot.optionalInteger("popover_window_number"),
                snapshot.optionalInteger("popover_window_number")
            )
        }
    }

    func testRawArtifactHasRequiredCrossProcessShapeAndNativePNGs() throws {
        let artifact = try LifecycleArtifact.load()
        XCTAssertEqual(try artifact.root.integer("schema_version"), 1)
        let driverPID = try artifact.root.integer("driver_pid")
        XCTAssertGreaterThan(driverPID, 0)
        XCTAssertEqual(Set(artifact.scenarioNames), Set(requiredLifecycleScenarios))
        XCTAssertEqual(forbiddenKeyPaths(in: artifact.root), [])

        var launchIDs: Set<String> = []
        for scenario in artifact.scenarios {
            XCTAssertGreaterThan(try scenario.integer("pid"), 0)
            XCTAssertTrue(launchIDs.insert(try scenario.string("launch_id")).inserted)
            try assertOrderedRecords(in: scenario)
            XCTAssertFalse(try scenario.records("input_events").isEmpty)
            XCTAssertFalse(try scenario.records("lifecycle_publications").isEmpty)
            XCTAssertFalse(try scenario.records("status_item_records").isEmpty)
            XCTAssertFalse(try scenario.records("accessibility_snapshots").isEmpty)
            XCTAssertFalse(try scenario.records("journal_snapshots").isEmpty)
            XCTAssertFalse(try scenario.records("process_records").isEmpty)
            let terminalReceipts = try scenario.records("process_records").filter {
                ["exited", "driver_completed", "driver_reaped"].contains(
                    $0.optionalString("state") ?? ""
                )
            }
            let scenarioName = try scenario.string("name")
            XCTAssertEqual(terminalReceipts.count, 1, scenarioName)
            XCTAssertEqual(terminalReceipts[0].optionalInteger("observer_pid"), driverPID)
            XCTAssertEqual(
                terminalReceipts[0].optionalInteger("observed_pid"),
                try scenario.integer("pid")
            )
        }

        let screenshots = try artifact.root.records("screenshots")
        XCTAssertEqual(Set(try screenshots.map { try $0.string("state") }), Set([
            "off", "start_confirmation", "preparing", "active", "restoring", "recovery",
            "cleanup_required",
        ]))
        for screenshot in screenshots {
            XCTAssertGreaterThan(try screenshot.integer("producer_pid"), 0)
            XCTAssertFalse(try screenshot.string("accessibility_snapshot_id").isEmpty)
            try assertPNG(at: screenshot.string("path"))
        }
    }

    func testLifecyclePresentationAndStatusItemMappingAreExact() throws {
        let artifact = try LifecycleArtifact.load()
        let mapping: [(String, String, String, String, String, String, String)] = [
            ("off", "Travel Mode Off", "Start", "travel.surface.off", "Codex Travel Mode: Off", "wifi.router", "secondary"),
            ("preparing", "Preparing Travel Mode", "Preparing…", "travel.surface.activity", "Codex Travel Mode: Preparing", "hourglass", "orange"),
            ("active", "Travel Mode On", "Stop & Restore", "travel.surface.active", "Codex Travel Mode: Active", "wifi.router.fill", "green"),
            ("restoring", "Restoring Travel Mode", "Restoring…", "travel.surface.activity", "Codex Travel Mode: Restoring", "arrow.triangle.2.circlepath", "orange"),
            ("recovery", "Recovering Travel Mode", "Recovering…", "travel.surface.activity", "Codex Travel Mode: Recovering", "arrow.triangle.2.circlepath", "orange"),
            ("cleanup_required", "Cleanup Required", "Retry Cleanup", "travel.surface.recovery", "Codex Travel Mode: Cleanup Required", "exclamationmark.triangle.fill", "red"),
        ]

        for (state, header, action, surface, statusLabel, symbol, tint) in mapping {
            let snapshots = artifact.accessibilitySnapshots(state: state)
            XCTAssertFalse(snapshots.isEmpty, state)
            XCTAssertTrue(snapshots.contains { $0.labels.contains(header) }, state)
            XCTAssertTrue(snapshots.contains { $0.labels.contains(action) }, state)
            XCTAssertTrue(snapshots.contains { $0.identifiers.contains(surface) }, state)
            let statusRecords = artifact.statusRecords(state: state)
            XCTAssertTrue(statusRecords.contains {
                $0.optionalString("label") == statusLabel
                    && $0.optionalString("symbol") == symbol
                    && $0.optionalString("tint") == tint
            }, state)

            let controls = snapshots.flatMap(\.elements)
            let settings = controls.filter { ($0.optionalString("identifier") ?? "").hasPrefix("hotspot.") }
            if state == "off" {
                XCTAssertFalse(settings.isEmpty, state)
                XCTAssertTrue(settings.contains { $0.optionalBool("enabled") == true })
            } else {
                XCTAssertTrue(settings.isEmpty, state)
            }

            XCTAssertTrue(snapshots.allSatisfy { snapshot in
                snapshot.elements.contains {
                    $0.optionalString("identifier") == "travel.primary-action"
                        && $0.optionalString("role") == NSAccessibility.Role.button.rawValue
                }
            }, state)
        }

        let quitFailure = try artifact.scenario("quit-failure-retry-success")
        XCTAssertTrue(try quitFailure.accessibilitySnapshots().contains {
            $0.labels.contains("Retry Cleanup & Quit")
        })
    }

    func testPopoverDismissalPreservesActiveAndDispatchesNoCleanup() throws {
        let scenario = try LifecycleArtifact.load().scenario("active-dismiss-reopen")
        XCTAssertTrue(try lifecycleValues(in: scenario).contains("active"))
        XCTAssertGreaterThanOrEqual(
            try scenario.accessibilitySnapshots().filter { $0.state == "active" }.count,
            2
        )
        XCTAssertTrue(try popoverStates(in: scenario).contains(["shown", "hidden", "shown"]))
        XCTAssertEqual(cleanupDispatches(in: scenario).count, 0)
        XCTAssertTrue(try scenario.statusRecords().contains {
            $0.optionalString("popover_state") == "hidden"
                && $0.optionalString("label") == "Codex Travel Mode: Active"
        })
        XCTAssertTrue(try journalPhases(in: scenario).contains("active"))
    }

    func testStartConfirmationIsVisibleInsideTheProductionPopoverBeforeActivation() throws {
        let scenario = try LifecycleArtifact.load().scenario("pre-start-cancel")
        let confirmation = try XCTUnwrap(try scenario.accessibilitySnapshots().first {
            $0.state == "start_confirmation"
        })
        XCTAssertTrue(confirmation.identifiers.contains("travel.surface.start-confirmation"))
        XCTAssertTrue(confirmation.labels.contains("Enable Travel Protection"))
        XCTAssertTrue(confirmation.labels.contains("Continue"))
        XCTAssertTrue(confirmation.labels.contains("Cancel"))

        let start = try findRecord(named: "start_notice", in: scenario, collection: "input_events")
        let cancel = try findRecord(
            named: "cancel_start_notice", in: scenario, collection: "input_events"
        )
        XCTAssertEqual(
            start.optionalString("popover_content_view_id"),
            confirmation.record.optionalString("popover_content_view_id")
        )
        XCTAssertEqual(
            cancel.optionalString("popover_content_view_id"),
            confirmation.record.optionalString("popover_content_view_id")
        )
        try assertOrdered(start, cancel)
        XCTAssertEqual(providerCommands(in: scenario).count, 0)
        XCTAssertEqual(try lifecycleValues(in: scenario).last, "off")
    }

    func testStopAndRetryOnlyPublishOffAfterVerifiedJournalClear() throws {
        let success = try LifecycleArtifact.load().scenario("stop-success")
        try assertOrdered(
            findRecord(named: "restoring", in: success, collection: "lifecycle_publications"),
            findRecord(named: "journal_cleared", in: success, collection: "journal_snapshots"),
            lastRecord(named: "off", in: success, collection: "lifecycle_publications")
        )
        XCTAssertTrue(try success.processStates().contains("alive"))

        let retry = try LifecycleArtifact.load().scenario("stop-failure-retry-success")
        let cleanupRequired = try findRecord(
            named: "cleanup_required", in: retry, collection: "lifecycle_publications"
        )
        let retryInput = try findRecord(named: "retry_cleanup", in: retry, collection: "input_events")
        let finalOff = try lastRecord(named: "off", in: retry, collection: "lifecycle_publications")
        try assertOrdered(cleanupRequired, retryInput, finalOff)
        XCTAssertEqual(cleanupDispatches(in: retry).count, 2)
        XCTAssertFalse(try pendingQuitValues(in: retry).contains(true))
        XCTAssertTrue(try retry.processStates().contains("alive"))
    }

    func testQuitDefersAndRetryExitsOnlyAfterVerifiedOff() throws {
        let artifact = try LifecycleArtifact.load()
        let clean = try artifact.scenario("clean-off-quit")
        XCTAssertEqual(cleanupDispatches(in: clean).count, 0)
        XCTAssertEqual(try terminationDecisions(in: clean), ["terminate_now"])
        XCTAssertEqual(try deferredTerminationReplies(in: clean), [])
        XCTAssertTrue(try clean.processStates().contains("exited"))

        let failed = try artifact.scenario("quit-failure-retry-success")
        XCTAssertEqual(
            try terminationDecisions(in: failed),
            ["terminate_later", "terminate_cancel", "terminate_now"]
        )
        XCTAssertEqual(try deferredTerminationReplies(in: failed), ["cancel"])
        let requests = terminationRequests(in: failed)
        XCTAssertEqual(requests.count, 2)
        let initialLater = try terminationRecord(
            in: failed, kind: "initial_decision", valueKey: "decision", value: "terminate_later"
        )
        let pendingQuit = try XCTUnwrap(try failed.records("pending_quit_publications").first {
            $0.optionalBool("value") == true
        })
        let restoring = try findRecord(
            named: "restoring", in: failed, collection: "lifecycle_publications"
        )
        let cleanupDispatch = try XCTUnwrap(cleanupDispatches(in: failed).first)
        let cleanupFailure = try XCTUnwrap(try failed.records("commands").first {
            $0.optionalString("operation") == "cleanup"
                && $0.optionalString("phase") == "return"
                && $0.optionalString("failure_category") != nil
        })
        XCTAssertEqual(cleanupFailure.optionalString("failure_category"), "authorization_cancelled")
        let cleanup = try findRecord(named: "cleanup_required", in: failed, collection: "lifecycle_publications")
        let deferredCancel = try terminationRecord(
            in: failed, kind: "deferred_reply", valueKey: "outcome", value: "cancel"
        )
        let freshQuit = try findRecord(
            named: "quit_after_cleanup_required", in: failed, collection: "input_events"
        )
        let terminateCancel = try terminationRecord(
            in: failed, kind: "initial_decision", valueKey: "decision", value: "terminate_cancel"
        )
        let alive = try XCTUnwrap(try failed.records("process_records").first {
            $0.optionalString("state") == "driver_observed_alive"
        })
        XCTAssertEqual(alive.optionalInteger("observer_pid"), try artifact.root.integer("driver_pid"))
        XCTAssertEqual(alive.optionalInteger("observed_pid"), try failed.integer("pid"))
        let retry = try findRecord(named: "retry_cleanup_and_quit", in: failed, collection: "input_events")
        let retrySequence = try retry.integer("sequence")
        XCTAssertEqual(try cleanupDispatches(in: failed).filter {
            try $0.integer("sequence") < retrySequence
        }.count, 1)
        let finalOff = try lastRecord(named: "off", in: failed, collection: "lifecycle_publications")
        let retryTerminateNow = try terminationRecord(
            in: failed, kind: "initial_decision", valueKey: "decision", value: "terminate_now"
        )
        let exited = try lastRecord(named: "exited", in: failed, collection: "process_records")
        try assertOrdered(
            requests[0], initialLater, pendingQuit, restoring, cleanupDispatch, cleanupFailure,
            cleanup, deferredCancel, freshQuit, requests[1], terminateCancel, alive, retry,
            finalOff, retryTerminateNow, exited
        )
        XCTAssertTrue(try pendingQuitValues(in: failed).contains(true))
    }

    func testRepeatedQuitCoalescesAtActualAppKitDeliveryBoundary() throws {
        let repeatedSuccess = try LifecycleArtifact.load().scenario("repeated-quit-delayed-success")
        let repeatedSuccessRequests = terminationRequests(in: repeatedSuccess)
        XCTAssertEqual(repeatedSuccessRequests.count, 2)
        XCTAssertTrue(repeatedSuccessRequests.allSatisfy {
            $0.optionalString("delivery") == "external_appkit"
        })
        let repeatedSuccessDecisions = try initialTerminationRecords(in: repeatedSuccess)
        XCTAssertTrue((1...2).contains(repeatedSuccessDecisions.count))
        XCTAssertTrue(repeatedSuccessDecisions.allSatisfy {
            $0.optionalString("decision") == "terminate_later"
        })
        XCTAssertEqual(try deferredTerminationReplies(in: repeatedSuccess), ["allow"])
        XCTAssertEqual(cleanupDispatches(in: repeatedSuccess).count, 1)
        XCTAssertTrue(try repeatedSuccess.processStates().contains("alive"))
        XCTAssertTrue(try repeatedSuccess.processStates().contains("exited"))
        try assertOrdered(
            repeatedSuccessRequests[0], repeatedSuccessDecisions[0], repeatedSuccessRequests[1],
            lastRecord(named: "off", in: repeatedSuccess, collection: "lifecycle_publications"),
            terminationRecord(
                in: repeatedSuccess, kind: "deferred_reply", valueKey: "outcome", value: "allow"
            ),
            lastRecord(named: "exited", in: repeatedSuccess, collection: "process_records")
        )

        let repeatedFailure = try LifecycleArtifact.load().scenario("repeated-quit-failure")
        let repeatedFailureRequests = terminationRequests(in: repeatedFailure)
        XCTAssertEqual(repeatedFailureRequests.count, 2)
        XCTAssertTrue(repeatedFailureRequests.allSatisfy {
            $0.optionalString("delivery") == "external_appkit"
        })
        let repeatedFailureDecisions = try initialTerminationRecords(in: repeatedFailure)
        XCTAssertTrue((1...2).contains(repeatedFailureDecisions.count))
        XCTAssertTrue(repeatedFailureDecisions.allSatisfy {
            ["terminate_later", "terminate_cancel"].contains($0.optionalString("decision") ?? "")
        })
        XCTAssertTrue(repeatedFailureDecisions.contains {
            $0.optionalString("decision") == "terminate_later"
        })
        XCTAssertFalse(repeatedFailureDecisions.contains {
            $0.optionalString("decision") == "terminate_now"
        })
        XCTAssertEqual(try deferredTerminationReplies(in: repeatedFailure), ["cancel"])
        XCTAssertEqual(cleanupDispatches(in: repeatedFailure).count, 1)
        let repeatedCleanupRequired = try findRecord(
            named: "cleanup_required",
            in: repeatedFailure,
            collection: "lifecycle_publications"
        )
        let repeatedCleanupSequence = try repeatedCleanupRequired.integer("sequence")
        for decision in repeatedFailureDecisions {
            let sequence = try decision.integer("sequence")
            if decision.optionalString("decision") == "terminate_later" {
                XCTAssertLessThan(sequence, repeatedCleanupSequence)
            } else {
                XCTAssertGreaterThan(sequence, repeatedCleanupSequence)
            }
        }
        XCTAssertTrue(try repeatedFailure.processStates().contains("alive"))
        XCTAssertFalse(try repeatedFailure.processStates().contains("exited"))
    }

    func testPreparingQuitSettlesTheProductionActivationTaskBeforeExit() throws {
        let preStart = try LifecycleArtifact.load().scenario("pre-start-cancel")
        XCTAssertEqual(providerCommands(in: preStart).count, 0)
        XCTAssertEqual(try lifecycleValues(in: preStart).last, "off")
        XCTAssertTrue(try preStart.processStates().contains("alive"))

        let cases: [(String, String, String?, String?)] = [
            ("preparing-quit-before-journal", "read_wifi_association", "baseline", nil),
            ("preparing-quit-after-journal", "lease_acquire", "acquire", nil),
            ("preparing-quit-after-lease", "boundary_gate", nil, "lease_acquired"),
        ]
        for (name, operation, gate, boundary) in cases {
            let scenario = try LifecycleArtifact.load().scenario(name)
            XCTAssertTrue(try lifecycleValues(in: scenario).contains("preparing"), name)
            XCTAssertEqual(try terminationDecisions(in: scenario), ["terminate_later"], name)
            XCTAssertEqual(try deferredTerminationReplies(in: scenario), ["allow"], name)
            XCTAssertEqual(activationTaskStates(in: scenario), ["idle", "in_flight", "resolved"])
            XCTAssertTrue(activationTasks(in: scenario).allSatisfy {
                $0.optionalString("source") == "production_activation_task"
            })
            let cancelled = try commandRecord(
                in: scenario, operation: operation, phase: "cancelled",
                gate: gate, boundary: boundary
            )
            let resolved = try activationTaskRecord(in: scenario, state: "resolved")
            let allow = try terminationRecord(
                in: scenario, kind: "deferred_reply", valueKey: "outcome", value: "allow"
            )
            let exited = try lastRecord(named: "exited", in: scenario, collection: "process_records")
            try assertOrdered(cancelled, resolved, allow, exited)
            XCTAssertEqual(try lifecycleValues(in: scenario).last, "off", name)
            XCTAssertEqual(try journalPhases(in: scenario).last, "cleared", name)
        }
    }

    func testLatePreparingCompensationFailureCancelsQuitAndKeepsAppAlive() throws {
        let artifact = try LifecycleArtifact.load()
        let scenario = try artifact.scenario("preparing-quit-after-lease-failure")
        XCTAssertEqual(try terminationDecisions(in: scenario), ["terminate_later"])
        XCTAssertEqual(try deferredTerminationReplies(in: scenario), ["cancel"])
        XCTAssertEqual(activationTaskStates(in: scenario), ["idle", "in_flight", "resolved"])
        XCTAssertTrue(activationTasks(in: scenario).allSatisfy {
            $0.optionalString("source") == "production_activation_task"
        })
        XCTAssertEqual(cleanupDispatches(in: scenario).count, 1)
        XCTAssertEqual(try lifecycleValues(in: scenario).last, "cleanup_required")
        XCTAssertTrue(try pendingQuitValues(in: scenario).contains(true))
        XCTAssertFalse(try scenario.processStates().contains("exited"))

        let cancelledGate = try commandRecord(
            in: scenario, operation: "boundary_gate", phase: "cancelled",
            boundary: "lease_acquired"
        )
        let resolved = try activationTaskRecord(in: scenario, state: "resolved")
        let cleanupFailure = try commandRecord(in: scenario, operation: "cleanup", phase: "return")
        XCTAssertNotNil(cleanupFailure.optionalString("failure_category"))
        let cleanupRequired = try findRecord(
            named: "cleanup_required", in: scenario, collection: "lifecycle_publications"
        )
        let deferredCancel = try terminationRecord(
            in: scenario, kind: "deferred_reply", valueKey: "outcome", value: "cancel"
        )
        let alive = try externalLivenessRecord(in: scenario, artifact: artifact)
        try assertOrdered(cancelledGate, resolved, cleanupRequired, deferredCancel, alive)
        try assertOrdered(cancelledGate, cleanupFailure, cleanupRequired)
    }

    func testStartupRecoveryQuitFailureCancelsTerminationAndRetainsOwnership() throws {
        let artifact = try LifecycleArtifact.load()
        let recoverySuccess = try LifecycleArtifact.load().scenario("startup-recovery-success")
        XCTAssertEqual(try lifecycleValues(in: recoverySuccess).first, "recovery")
        XCTAssertEqual(try lifecycleValues(in: recoverySuccess).last, "off")
        XCTAssertTrue(try recoverySuccess.processStates().contains("alive"))

        let recoveryFailure = try LifecycleArtifact.load().scenario("startup-recovery-failure")
        XCTAssertEqual(try lifecycleValues(in: recoveryFailure).first, "recovery")
        XCTAssertEqual(try lifecycleValues(in: recoveryFailure).last, "cleanup_required")
        XCTAssertTrue(try recoveryFailure.processStates().contains("alive"))

        let recoveryQuit = try LifecycleArtifact.load().scenario("quit-during-startup-recovery")
        XCTAssertEqual(recoveryDispatches(in: recoveryQuit).count, 1)
        XCTAssertEqual(try terminationDecisions(in: recoveryQuit), ["terminate_later"])
        XCTAssertEqual(try deferredTerminationReplies(in: recoveryQuit), ["allow"])
        XCTAssertEqual(try lifecycleValues(in: recoveryQuit).last, "off")
        XCTAssertTrue(try recoveryQuit.processStates().contains("exited"))

        let failedQuit = try artifact.scenario("quit-during-startup-recovery-failure")
        XCTAssertEqual(recoveryDispatches(in: failedQuit).count, 1)
        XCTAssertEqual(try lifecycleValues(in: failedQuit).first, "recovery")
        XCTAssertEqual(try terminationDecisions(in: failedQuit), ["terminate_later"])
        XCTAssertEqual(try deferredTerminationReplies(in: failedQuit), ["cancel"])
        XCTAssertEqual(try lifecycleValues(in: failedQuit).last, "cleanup_required")
        XCTAssertTrue(try pendingQuitValues(in: failedQuit).contains(true))
        XCTAssertFalse(try failedQuit.processStates().contains("exited"))
        let request = try XCTUnwrap(terminationRequests(in: failedQuit).first)
        let terminateLater = try terminationRecord(
            in: failedQuit, kind: "initial_decision",
            valueKey: "decision", value: "terminate_later"
        )
        let failure = try commandRecord(in: failedQuit, operation: "recover", phase: "return")
        XCTAssertNotNil(failure.optionalString("failure_category"))
        let cleanupRequired = try findRecord(
            named: "cleanup_required", in: failedQuit, collection: "lifecycle_publications"
        )
        let deferredCancel = try terminationRecord(
            in: failedQuit, kind: "deferred_reply", valueKey: "outcome", value: "cancel"
        )
        let alive = try externalLivenessRecord(in: failedQuit, artifact: artifact)
        try assertOrdered(request, terminateLater, failure, cleanupRequired, deferredCancel, alive)
    }

    func testSensitiveProviderFailureIsAbsentFromRenderedUIAndStatusItem() throws {
        let scenario = try LifecycleArtifact.load().scenario("quit-failure-retry-success")
        let failure = try commandRecord(in: scenario, operation: "cleanup", phase: "return")
        XCTAssertEqual(failure.optionalString("failure_category"), "authorization_cancelled")
        XCTAssertEqual(failure.optionalString("raw_detail"), lifecycleProofSensitiveFailure)

        let rendered = try renderedUserFacingStrings(in: scenario).joined(separator: "\n")
        for forbidden in [
            lifecycleProofSensitiveFailure, "PROOF_SECRET_7f4d9a", "hunter-proof",
            "/usr/bin/pmset", "disablesleep",
        ] {
            XCTAssertFalse(rendered.localizedCaseInsensitiveContains(forbidden), forbidden)
        }
        XCTAssertTrue(rendered.contains("Cleanup Required"))
        XCTAssertTrue(rendered.contains("Retry Cleanup & Quit"))
    }

    func testReleaseBundleHasNoProofSelectionSurface() throws {
        let artifact = try LifecycleArtifact.load()
        let requiredQueries = [
            "LifecycleUIProofApp", "LIFECYCLE_PROOF_SCENARIO",
            "lifecycle-readback.json", "run_lifecycle_ui_proof",
            "lifecycle-ui-proof-app", "Codex Travel Mode Lifecycle Proof",
            "--launch-id", "--fragment", "--liveness-receipt",
        ]
        let inventory = try artifact.root.records("release_inventory")
        let paths = Set(try inventory.map { try $0.string("relative_path") })
        XCTAssertTrue(paths.contains("Contents/MacOS/codex-travel-mode"))
        XCTAssertTrue(paths.contains("Contents/Resources/codex-travel-mode-sleep-helper"))
        XCTAssertFalse(paths.contains { $0.lowercased().contains("proof") })

        let binaryRecords = try artifact.root.records("release_binary_records")
        XCTAssertEqual(binaryRecords.count, requiredQueries.count * 2)
        XCTAssertEqual(
            Set(binaryRecords.compactMap { $0.optionalString("binary_role") }),
            Set(["main", "sleep_helper"])
        )
        XCTAssertEqual(
            Set(binaryRecords.compactMap { $0.optionalString("query") }),
            Set(requiredQueries)
        )
        XCTAssertTrue(try binaryRecords.allSatisfy { try $0.integer("occurrences") == 0 })

        let bundleRecords = try artifact.root.records("release_bundle_records")
        XCTAssertEqual(Set(bundleRecords.compactMap { $0.optionalString("query") }), Set(requiredQueries))
        XCTAssertTrue(try bundleRecords.allSatisfy { record in
            let occurrences = try record.integer("occurrences")
            let matchingPaths = try record.strings("matching_paths")
            return occurrences == 0 && matchingPaths.isEmpty
        })
    }
}

private let requiredLifecycleScenarios = [
    "clean-off-quit",
    "pre-start-cancel",
    "preparing-quit-before-journal",
    "preparing-quit-after-journal",
    "preparing-quit-after-lease",
    "preparing-quit-after-lease-failure",
    "active-dismiss-reopen",
    "stop-success",
    "stop-failure-retry-success",
    "quit-failure-retry-success",
    "repeated-quit-delayed-success",
    "repeated-quit-failure",
    "startup-recovery-success",
    "startup-recovery-failure",
    "quit-during-startup-recovery",
    "quit-during-startup-recovery-failure",
]

private struct LifecycleArtifact {
    let outputURL: URL
    let root: JSONRecord
    let scenarios: [JSONRecord]

    static func load() throws -> LifecycleArtifact {
        guard let path = ProcessInfo.processInfo.environment["LIFECYCLE_PROOF_ARTIFACT_PATH"],
              !path.isEmpty else {
            throw XCTSkip("LIFECYCLE_PROOF_ARTIFACT_PATH is not set")
        }
        let url = URL(fileURLWithPath: path)
        let data = try Data(contentsOf: url)
        let raw = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let root = JSONRecord(raw)
        return LifecycleArtifact(
            outputURL: url.deletingLastPathComponent(),
            root: root,
            scenarios: try root.records("scenarios")
        )
    }

    var scenarioNames: [String] { scenarios.compactMap { $0.optionalString("name") } }

    func scenario(_ name: String) throws -> JSONRecord {
        try XCTUnwrap(scenarios.filter { $0.optionalString("name") == name }.only, name)
    }

    func accessibilitySnapshots(state: String) -> [AccessibilitySnapshot] {
        scenarios.flatMap { (try? $0.accessibilitySnapshots()) ?? [] }
            .filter { $0.state == state }
    }

    func statusRecords(state: String) -> [JSONRecord] {
        scenarios.flatMap { (try? $0.statusRecords()) ?? [] }
            .filter { $0.optionalString("state") == state }
    }
}

private struct JSONRecord {
    let object: [String: Any]
    init(_ object: [String: Any]) { self.object = object }

    func string(_ key: String) throws -> String { try XCTUnwrap(object[key] as? String, key) }
    func integer(_ key: String) throws -> Int { try XCTUnwrap((object[key] as? NSNumber)?.intValue, key) }
    func records(_ key: String) throws -> [JSONRecord] {
        try XCTUnwrap(object[key] as? [[String: Any]], key).map(JSONRecord.init)
    }
    func strings(_ key: String) throws -> [String] {
        try XCTUnwrap(object[key] as? [String], key)
    }
    func optionalString(_ key: String) -> String? { object[key] as? String }
    func optionalInteger(_ key: String) -> Int? { (object[key] as? NSNumber)?.intValue }
    func optionalBool(_ key: String) -> Bool? { (object[key] as? NSNumber)?.boolValue }

    func accessibilitySnapshots() throws -> [AccessibilitySnapshot] {
        try records("accessibility_snapshots").map(AccessibilitySnapshot.init)
    }
    func statusRecords() throws -> [JSONRecord] { try records("status_item_records") }
    func processStates() throws -> [String] { try records("process_records").compactMap { $0.optionalString("state") } }
}

private struct AccessibilitySnapshot {
    let record: JSONRecord
    let elements: [JSONRecord]
    init(_ record: JSONRecord) throws {
        self.record = record
        self.elements = try record.records("elements")
    }
    var state: String { record.optionalString("state") ?? "" }
    var labels: [String] { elements.compactMap { $0.optionalString("label") } }
    var identifiers: [String] { elements.compactMap { $0.optionalString("identifier") } }
}

private func lifecycleValues(in scenario: JSONRecord) throws -> [String] {
    try scenario.records("lifecycle_publications").compactMap { $0.optionalString("state") }
}
private func pendingQuitValues(in scenario: JSONRecord) throws -> [Bool] {
    try scenario.records("pending_quit_publications").compactMap { $0.optionalBool("value") }
}
private func popoverStates(in scenario: JSONRecord) throws -> [String] {
    try scenario.records("popover_records").compactMap { $0.optionalString("state") }
}
private func journalPhases(in scenario: JSONRecord) throws -> [String] {
    try scenario.records("journal_snapshots").compactMap { $0.optionalString("phase") }
}
private func terminationDecisions(in scenario: JSONRecord) throws -> [String] {
    try initialTerminationRecords(in: scenario).compactMap { $0.optionalString("decision") }
}
private func initialTerminationRecords(in scenario: JSONRecord) throws -> [JSONRecord] {
    try scenario.records("termination_records").filter {
        $0.optionalString("kind") == "initial_decision"
    }
}
private func deferredTerminationReplies(in scenario: JSONRecord) throws -> [String] {
    try scenario.records("termination_records").filter {
        $0.optionalString("kind") == "deferred_reply"
    }.compactMap { $0.optionalString("outcome") }
}
private func terminationRequests(in scenario: JSONRecord) -> [JSONRecord] {
    ((try? scenario.records("termination_records")) ?? []).filter { $0.optionalString("kind") == "request" }
}
private func cleanupDispatches(in scenario: JSONRecord) -> [JSONRecord] {
    ((try? scenario.records("commands")) ?? []).filter {
        $0.optionalString("operation") == "cleanup" && $0.optionalString("phase") == "dispatch"
    }
}
private func recoveryDispatches(in scenario: JSONRecord) -> [JSONRecord] {
    ((try? scenario.records("commands")) ?? []).filter {
        $0.optionalString("operation") == "recover" && $0.optionalString("phase") == "dispatch"
    }
}
private func providerCommands(in scenario: JSONRecord) -> [JSONRecord] {
    ((try? scenario.records("commands")) ?? []).filter { $0.optionalString("source") == "outer_provider" }
}
private func activationTasks(in scenario: JSONRecord) -> [JSONRecord] {
    ((try? scenario.records("activation_tasks")) ?? [])
}
private func activationTaskStates(in scenario: JSONRecord) -> [String] {
    activationTasks(in: scenario).compactMap { $0.optionalString("state") }
}

private func activationTaskRecord(in scenario: JSONRecord, state: String) throws -> JSONRecord {
    try XCTUnwrap(activationTasks(in: scenario).first {
        $0.optionalString("state") == state
            && $0.optionalString("source") == "production_activation_task"
    }, "Missing production activation task state \(state)")
}

private func commandRecord(
    in scenario: JSONRecord,
    operation: String,
    phase: String,
    gate: String? = nil,
    boundary: String? = nil
) throws -> JSONRecord {
    try XCTUnwrap(try scenario.records("commands").first { record in
        record.optionalString("operation") == operation
            && record.optionalString("phase") == phase
            && (gate == nil || record.optionalString("gate") == gate)
            && (boundary == nil || record.optionalString("boundary") == boundary)
    }, "Missing command \(operation)/\(phase)")
}

private func externalLivenessRecord(
    in scenario: JSONRecord,
    artifact: LifecycleArtifact
) throws -> JSONRecord {
    let record = try XCTUnwrap(try scenario.records("process_records").first {
        $0.optionalString("state") == "driver_observed_alive"
    })
    XCTAssertEqual(record.optionalInteger("observer_pid"), try artifact.root.integer("driver_pid"))
    XCTAssertEqual(record.optionalInteger("observed_pid"), try scenario.integer("pid"))
    let checkpointSequence = try record.integer("checkpoint_sequence")
    XCTAssertTrue(try scenario.records("process_records").contains {
        $0.optionalString("state") == "awaiting_driver_liveness"
            && $0.optionalInteger("sequence") == checkpointSequence
    })
    return record
}

private func renderedUserFacingStrings(in scenario: JSONRecord) throws -> [String] {
    let snapshotStrings = try scenario.records("accessibility_snapshots").flatMap { snapshot in
        try snapshot.records("elements").flatMap { element in
            [element.optionalString("label"), element.optionalString("value")].compactMap { $0 }
        }
    }
    let statusStrings = try scenario.records("status_item_records").flatMap { record in
        ["label", "symbol", "tint", "tool_tip"].compactMap { record.optionalString($0) }
    }
    return snapshotStrings + statusStrings
}

private func terminationRecord(
    in scenario: JSONRecord,
    kind: String,
    valueKey: String,
    value: String
) throws -> JSONRecord {
    try XCTUnwrap(try scenario.records("termination_records").first {
        $0.optionalString("kind") == kind && $0.optionalString(valueKey) == value
    }, "Missing termination record \(kind) with \(valueKey)=\(value)")
}

private func findRecord(named name: String, in scenario: JSONRecord, collection: String) throws -> JSONRecord {
    try XCTUnwrap(try scenario.records(collection).first {
        $0.optionalString("state") == name || $0.optionalString("kind") == name || $0.optionalString("phase") == name
    }, "Missing \(name) in \(collection)")
}
private func lastRecord(named name: String, in scenario: JSONRecord, collection: String) throws -> JSONRecord {
    try XCTUnwrap(try scenario.records(collection).last {
        $0.optionalString("state") == name || $0.optionalString("kind") == name || $0.optionalString("phase") == name
    }, "Missing final \(name) in \(collection)")
}
private func assertOrdered(_ records: JSONRecord...) throws {
    let sequences = try records.map { try $0.integer("sequence") }
    XCTAssertEqual(sequences, sequences.sorted())
    XCTAssertEqual(sequences.count, Set(sequences).count)
}

private func assertOrderedRecords(in scenario: JSONRecord) throws {
    let keys = [
        "input_events", "lifecycle_publications", "pending_quit_publications", "popover_records",
        "status_item_records", "accessibility_snapshots", "journal_snapshots", "commands",
        "termination_records", "activation_tasks", "process_records",
    ]
    let sequences = try keys.flatMap { try scenario.records($0).map { try $0.integer("sequence") } }
    let scenarioName = try scenario.string("name")
    XCTAssertEqual(sequences.count, Set(sequences).count, scenarioName)
    XCTAssertTrue(sequences.allSatisfy { $0 > 0 }, scenarioName)
}

private func assertPNG(at path: String) throws {
    let data = try Data(contentsOf: URL(fileURLWithPath: path))
    XCTAssertGreaterThan(data.count, 100)
    XCTAssertEqual(Array(data.prefix(8)), [137, 80, 78, 71, 13, 10, 26, 10])
    XCTAssertEqual(String(data: data[12..<16], encoding: .ascii), "IHDR")
    let width = data[16..<20].reduce(0) { ($0 << 8) | Int($1) }
    let height = data[20..<24].reduce(0) { ($0 << 8) | Int($1) }
    XCTAssertGreaterThan(width, 100)
    XCTAssertGreaterThan(height, 100)
    let bitmap = try XCTUnwrap(NSBitmapImageRep(data: data))
    let xStride = max(bitmap.pixelsWide / 100, 1)
    let yStride = max(bitmap.pixelsHigh / 100, 1)
    var sampled = 0
    var opaque = 0
    var nonblack = 0
    var colors: Set<Int> = []
    for y in stride(from: 0, to: bitmap.pixelsHigh, by: yStride) {
        for x in stride(from: 0, to: bitmap.pixelsWide, by: xStride) {
            guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else {
                continue
            }
            sampled += 1
            if color.alphaComponent > 0.95 { opaque += 1 }
            let brightness = color.redComponent + color.greenComponent + color.blueComponent
            if brightness > 0.12 { nonblack += 1 }
            let quantized = Int(color.redComponent * 15) << 8
                | Int(color.greenComponent * 15) << 4
                | Int(color.blueComponent * 15)
            colors.insert(quantized)
        }
    }
    XCTAssertGreaterThan(sampled, 1_000)
    XCTAssertGreaterThan(Double(opaque) / Double(sampled), 0.95)
    XCTAssertGreaterThan(Double(nonblack) / Double(sampled), 0.70)
    XCTAssertGreaterThan(colors.count, 12)
}

private func forbiddenKeyPaths(in record: JSONRecord) -> [String] {
    let forbidden = Set(["pass", "passed", "verdict", "checks", "assertions", "expected"])
    var paths: [String] = []
    func walk(_ value: Any, path: String) {
        if let object = value as? [String: Any] {
            for (key, child) in object {
                let childPath = path.isEmpty ? key : "\(path).\(key)"
                if forbidden.contains(key.lowercased()) { paths.append(childPath) }
                walk(child, path: childPath)
            }
        } else if let array = value as? [Any] {
            for (index, child) in array.enumerated() { walk(child, path: "\(path)[\(index)]") }
        }
    }
    walk(record.object, path: "")
    return paths.sorted()
}

private extension Array {
    var only: Element? { count == 1 ? first : nil }
}
