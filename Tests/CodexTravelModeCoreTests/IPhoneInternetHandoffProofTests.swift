import Foundation
import XCTest

final class IPhoneInternetHandoffProofTests: XCTestCase {
    func testArtifactIsRawCrossProcessEvidenceWithoutCredentialOrVerdictKeys() throws {
        let artifact = try HandoffArtifact.load()
        XCTAssertEqual(try artifact.root.integer("schema_version"), 1)
        XCTAssertGreaterThan(try artifact.root.integer("worker_pid"), 0)
        XCTAssertEqual(Set(artifact.scenarioNames), Set(requiredScenarioNames))
        XCTAssertEqual(forbiddenKeyPaths(in: artifact.root), [])
        XCTAssertFalse(artifact.rawText.contains("proof-secret-sentinel"))

        for scenario in artifact.scenarios {
            let scenarioName = try scenario.string("name")
            let entrypoint = try scenario.string("entrypoint")
            XCTAssertFalse(entrypoint.isEmpty)
            let publications = try scenario.records("publications")
            for publication in publications where publication.optionalString("state") != "inactive" {
                XCTAssertNotNil(publication.optionalString("session_id"), scenarioName)
                XCTAssertNotNil(publication.optionalString("generation_id"), scenarioName)
            }
            for publication in publications where publication.optionalString("episode_id") != nil {
                let sessionID = try XCTUnwrap(publication.optionalString("session_id"))
                let episodeID = try XCTUnwrap(publication.optionalString("episode_id"))
                XCTAssertTrue(episodeID.hasPrefix(sessionID + ":"), scenarioName)
            }
        }
    }

    func testEveryEpisodeMutationCarriesAuthorizedPublishedIdentityAndOrderedAttempt() throws {
        let artifact = try HandoffArtifact.load()
        for scenario in artifact.scenarios {
            let scenarioName = try scenario.string("name")
            let commands = try scenario.records("commands")
            let publications = try scenario.records("publications")
            let mutations = episodeMutationCommands(in: scenario)

            for mutation in mutations {
                let sessionID = try mutation.string("session_id")
                let generationID = try mutation.string("generation_id")
                let episodeID = try mutation.string("episode_id")
                let attempt = try mutation.integer("attempt")
                let mutationSequence = try mutation.integer("sequence")
                XCTAssertFalse(sessionID.isEmpty, scenarioName)
                XCTAssertFalse(generationID.isEmpty, scenarioName)
                XCTAssertFalse(episodeID.isEmpty, scenarioName)
                XCTAssertTrue((1...3).contains(attempt), scenarioName)

                XCTAssertTrue(publications.contains {
                    $0.optionalString("session_id") == sessionID
                        && $0.optionalString("generation_id") == generationID
                        && $0.optionalString("episode_id") == episodeID
                }, "Mutation has no publication with the same identity: \(scenarioName)")

                XCTAssertTrue(commands.contains {
                    $0.optionalString("source") == mutation.optionalString("source")
                        && $0.optionalString("operation") == "handoff_authorize"
                        && $0.optionalString("phase") == "return"
                        && $0.optionalInteger("exit_code") == 0
                        && $0.optionalString("session_id") == sessionID
                        && $0.optionalString("generation_id") == generationID
                        && $0.optionalString("episode_id") == episodeID
                        && ($0.optionalInteger("sequence") ?? Int.max) < mutationSequence
                }, "Mutation was not preceded by successful exact-token authorization: \(scenarioName)")

                if mutation.optionalString("phase") == "return" {
                    XCTAssertTrue(mutations.contains {
                        $0.optionalString("phase") == "dispatch"
                            && $0.optionalString("source") == mutation.optionalString("source")
                            && $0.optionalString("operation") == mutation.optionalString("operation")
                            && $0.optionalString("session_id") == sessionID
                            && $0.optionalString("generation_id") == generationID
                            && $0.optionalString("episode_id") == episodeID
                            && $0.optionalInteger("attempt") == attempt
                            && ($0.optionalInteger("sequence") ?? Int.max) < mutationSequence
                    }, "Mutation return has no matching earlier dispatch: \(scenarioName)")
                }
            }

            let dispatchesByEpisode = Dictionary(grouping: mutations.filter {
                $0.optionalString("phase") == "dispatch"
            }) {
                [
                    $0.optionalString("session_id") ?? "",
                    $0.optionalString("generation_id") ?? "",
                    $0.optionalString("episode_id") ?? "",
                ].joined(separator: "|")
            }
            for dispatches in dispatchesByEpisode.values {
                let attempts = dispatches
                    .sorted { ($0.optionalInteger("sequence") ?? 0) < ($1.optionalInteger("sequence") ?? 0) }
                    .compactMap { $0.optionalInteger("attempt") }
                XCTAssertEqual(attempts, attempts.sorted(), scenarioName)
                if let maximum = attempts.max() {
                    XCTAssertEqual(Set(attempts).sorted(), Array(1...maximum), scenarioName)
                }
            }
        }
    }

    func testAppStateAndInitiallyClosedPathsAreTransitionOwnedAndIdempotent() throws {
        let artifact = try HandoffArtifact.load()
        let app = try artifact.scenario("app_state_open_close_idempotent")
        XCTAssertEqual(try app.string("entrypoint"), "TravelModeAppState.start/syncOnce/stop")
        XCTAssertEqual(dispatchCommands("associate", in: app).count, 1)
        XCTAssertEqual(dispatchCommands("wifi_power", in: app).count, 0)
        XCTAssertEqual(events("app_sync_called", in: app).filter {
            $0.optionalString("detail")?.hasPrefix("stable_closed_tick_") == true
        }.count, 10)
        XCTAssertTrue(states(in: app).contains("preserving_current_network"))
        XCTAssertTrue(states(in: app).contains("connected_via_configured_hotspot"))
        XCTAssertEqual(episodeIDs(in: app).count, 1)
        try assertRealProbePrecedesConnection(in: app)

        let initiallyClosed = try artifact.scenario("initially_closed_healthy_target")
        XCTAssertEqual(dispatchCommands("associate", in: initiallyClosed).count, 0)
        XCTAssertEqual(dispatchCommands("wifi_power", in: initiallyClosed).count, 0)
        XCTAssertEqual(events("coordinator_tick", in: initiallyClosed).count, 10)
        XCTAssertTrue(states(in: initiallyClosed).contains("connected_via_configured_hotspot"))
        XCTAssertEqual(episodeIDs(in: initiallyClosed).count, 1)
        try assertRealProbePrecedesConnection(in: initiallyClosed)
    }

    func testEveryConnectivityDimensionAndProviderFailureRemainDistinct() throws {
        let artifact = try HandoffArtifact.load()
        let matrix: [(String, String)] = [
            ("partial_ssid_only", "partial_connectivity"),
            ("partial_address_only", "partial_connectivity"),
            ("partial_wrong_route", "partial_connectivity"),
            ("partial_http_rejected", "reachability_failed"),
            ("provider_failure_is_not_disconnection", "connectivity_provider_failed"),
        ]
        for (name, failureKind) in matrix {
            let scenario = try artifact.scenario(name)
            XCTAssertFalse(states(in: scenario).contains("connected_via_configured_hotspot"), name)
            XCTAssertTrue(failureKinds(in: scenario).contains(failureKind), name)
        }

        let rejected = try artifact.scenario("partial_http_rejected")
        XCTAssertTrue(try rejected.records("http_receipts").contains {
            $0.optionalInteger("response_code") == 503
        })
        XCTAssertTrue(try rejected.records("reachability_calls").contains {
            $0.optionalString("phase") == "return"
                && $0.optionalString("outcome") == "rejected_status"
                && $0.optionalInteger("response_code") == 503
        })

        let provider = try artifact.scenario("provider_failure_is_not_disconnection")
        XCTAssertEqual(dispatchCommands("associate", in: provider).count, 0)
        XCTAssertTrue(try provider.records("provider_reads").contains {
            $0.optionalString("failure_category") == "command_failed"
        })

        let power = try artifact.scenario("wifi_power_enable_failure")
        XCTAssertEqual(dispatchCommands("wifi_power", in: power).count, 3)
        XCTAssertEqual(dispatchCommands("associate", in: power).count, 0)
        XCTAssertTrue(failureKinds(in: power).contains("wifi_power_command_failed"))
    }

    func testRetryExhaustionLatchesAndExplicitRetryOwnsOneFreshEpisode() throws {
        let scenario = try HandoffArtifact.load().scenario("retry_exhaustion_explicit_retry")
        let retryEvent = try XCTUnwrap(events("explicit_retry_called", in: scenario).only)
        let retrySequence = try retryEvent.integer("sequence")
        let joins = dispatchCommands("associate", in: scenario)
        XCTAssertEqual(joins.filter { ($0.optionalInteger("sequence") ?? 0) < retrySequence }.count, 3)
        XCTAssertEqual(joins.filter { ($0.optionalInteger("sequence") ?? 0) > retrySequence }.count, 1)
        XCTAssertEqual(events("post_exhaustion_tick", in: scenario).count, 10)
        XCTAssertEqual(episodeIDs(in: scenario).count, 2)
        XCTAssertTrue(states(in: scenario).contains("failed"))
        XCTAssertTrue(states(in: scenario).contains("connected_via_configured_hotspot"))
        XCTAssertEqual(try scenario.integer("final_manual_time_milliseconds"), 3_000)
        XCTAssertLessThanOrEqual(try scenario.integer("final_manual_time_milliseconds"), 30_000)
        XCTAssertEqual(
            try scenario.records("scheduler_sleeps").map { try $0.integer("duration_milliseconds") },
            [1_000, 2_000]
        )
        XCTAssertTrue(joins.allSatisfy { ($0.optionalInteger("timeout_milliseconds") ?? 0) <= 5_000 })
        try assertRealProbePrecedesConnection(in: scenario)
    }

    func testEpisodeBudgetCapsFinalOperationAndStartsNothingAtOrAfterDeadline() throws {
        let scenario = try HandoffArtifact.load().scenario("episode_budget_exhaustion")
        let deadline = 30_000
        XCTAssertEqual(try scenario.integer("final_manual_time_milliseconds"), deadline)
        XCTAssertTrue(failureKinds(in: scenario).contains("deadline_exceeded"))

        let wifiReads = try scenario.records("provider_reads").filter {
            $0.optionalString("provider") == "wifi_connectivity"
        }
        let reachabilityDispatches = try scenario.records("reachability_calls").filter {
            $0.optionalString("phase") == "dispatch"
        }
        let mutationDispatches = episodeMutationCommands(in: scenario).filter {
            $0.optionalString("phase") == "dispatch"
        }
        let timedStarts = wifiReads + reachabilityDispatches + mutationDispatches
        XCTAssertFalse(timedStarts.isEmpty)
        for start in timedStarts {
            let manualTime = try start.integer("manual_time_milliseconds")
            let timeout = try start.integer("timeout_milliseconds")
            XCTAssertLessThan(manualTime, deadline)
            XCTAssertLessThanOrEqual(manualTime + timeout, deadline)
        }

        let finalProviderRead = try XCTUnwrap(wifiReads.max {
            ($0.optionalInteger("manual_time_milliseconds") ?? 0)
                < ($1.optionalInteger("manual_time_milliseconds") ?? 0)
        })
        XCTAssertEqual(finalProviderRead.optionalInteger("manual_time_milliseconds"), 29_000)
        XCTAssertEqual(finalProviderRead.optionalInteger("timeout_milliseconds"), 1_000)
        XCTAssertEqual(
            mutationDispatches.filter { $0.optionalString("operation") == "associate" }
                .compactMap { $0.optionalInteger("attempt") },
            [1, 2]
        )

        let advances = events("scheduler_advanced", in: scenario)
        XCTAssertEqual(advances.last?.optionalInteger("manual_time_milliseconds"), deadline)
        let consumedOperationTime = advances.compactMap { event -> Int? in
            guard let detail = event.optionalString("detail") else { return nil }
            return Int(detail)
        }.reduce(0, +)
        let consumedBackoffTime = try scenario.records("scheduler_sleeps")
            .map { try $0.integer("duration_milliseconds") }
            .reduce(0, +)
        XCTAssertEqual(consumedOperationTime + consumedBackoffTime, deadline)
    }

    func testClosedHealthyPathLossStartsExactlyOneCooledDownRecovery() throws {
        let scenario = try HandoffArtifact.load().scenario("closed_healthy_path_loss_single_recovery")
        XCTAssertEqual(dispatchCommands("associate", in: scenario).count, 1)
        XCTAssertEqual(events("post_recovery_closed_tick", in: scenario).count, 10)
        XCTAssertEqual(
            Set((try scenario.records("publications")).filter {
                $0.optionalString("state") == "handoff_pending"
                    && $0.optionalString("trigger") == "closed_path_lost"
            }.compactMap { $0.optionalString("episode_id") }).count,
            1
        )
        XCTAssertEqual(episodeIDs(in: scenario).count, 2)
        XCTAssertEqual(try scenario.integer("final_manual_time_milliseconds"), 5_000)
        try assertRealProbePrecedesConnection(in: scenario)
    }

    func testOpenLidDisconnectionAndExactByteSSIDEdgesDoNotCollapse() throws {
        let artifact = try HandoffArtifact.load()
        let initial = try artifact.scenario("initial_open_disconnected_waits")
        XCTAssertEqual(events("open_disconnected_tick", in: initial).count, 10)
        XCTAssertEqual(dispatchCommands("associate", in: initial).count, 0)
        XCTAssertEqual(Set(states(in: initial)), Set(["waiting_for_connection", "inactive"]))

        let fallback = try artifact.scenario("open_associated_to_disconnected_fallback")
        XCTAssertTrue(states(in: fallback).contains("preserving_current_network"))
        XCTAssertEqual(dispatchCommands("associate", in: fallback).count, 1)
        XCTAssertEqual(episodeTriggers(in: fallback), Set(["open_disconnection"]))
        try assertRealProbePrecedesConnection(in: fallback)

        let exact = try artifact.scenario("exact_byte_ssid_identity")
        let composed = try XCTUnwrap(events("ssid_fixture_composed", in: exact).only?.optionalString("detail"))
        let decomposed = try XCTUnwrap(events("ssid_fixture_decomposed", in: exact).only?.optionalString("detail"))
        XCTAssertNotEqual(composed, decomposed)
        XCTAssertEqual(dispatchCommands("associate", in: exact).count, 1)
        XCTAssertEqual(dispatchCommands("associate", in: exact).only?.optionalString("ssid_utf8_hex"), composed)
        XCTAssertTrue(try exact.records("provider_reads").contains {
            $0.optionalString("ssid_utf8_hex") == decomposed
        })
        try assertRealProbePrecedesConnection(in: exact)
    }

    func testReopenCancelsCloseEpisodeAndLaterCloseGetsNewOwnership() throws {
        let scenario = try HandoffArtifact.load().scenario("reopen_cancels_close_episode_then_reclose")
        let joins = dispatchCommands("associate", in: scenario)
        XCTAssertEqual(joins.count, 2)
        XCTAssertEqual(episodeIDs(in: scenario).count, 2)
        XCTAssertTrue(states(in: scenario).contains("waiting_for_connection"))
        XCTAssertTrue(states(in: scenario).contains("connected_via_configured_hotspot"))
        let cancelled = try scenario.records("commands").filter {
            $0.optionalString("operation") == "associate"
                && $0.optionalString("phase") == "return"
                && $0.optionalString("failure_category") == "cancelled"
        }
        XCTAssertEqual(cancelled.count, 1)
        let cancellationSequence = try XCTUnwrap(cancelled.only?.optionalInteger("sequence"))
        XCTAssertLessThan(cancellationSequence, try XCTUnwrap(joins.last?.optionalInteger("sequence")))
        try assertRealProbePrecedesConnection(in: scenario)
    }

    func testStopDuringEveryAsyncPhasePreventsLaterDispatchAndPublication() throws {
        let artifact = try HandoffArtifact.load()
        let cases: [(String, String?, Int)] = [
            ("stop_during_power", "wifi_power", 1),
            ("stop_during_association", "associate", 1),
            ("stop_during_connectivity_read", nil, 0),
            ("stop_during_probe", nil, 0),
            ("stop_during_backoff", "associate", 1),
        ]
        for (name, operation, dispatchCount) in cases {
            let scenario = try artifact.scenario(name)
            let invalidation = try XCTUnwrap(events("invalidation_requested", in: scenario).only)
            let invalidationSequence = try invalidation.integer("sequence")
            let dispatches = (try scenario.records("commands")).filter {
                $0.optionalString("phase") == "dispatch"
                    && ["wifi_power", "associate"].contains($0.optionalString("operation") ?? "")
            }
            XCTAssertEqual(dispatches.count, dispatchCount, name)
            if let operation {
                XCTAssertEqual(dispatches.map { $0.optionalString("operation") }, [operation], name)
            }
            XCTAssertFalse(dispatches.contains {
                ($0.optionalInteger("sequence") ?? 0) > invalidationSequence
            }, name)
            let laterPublications = (try scenario.records("publications")).filter {
                ($0.optionalInteger("sequence") ?? 0) > invalidationSequence
            }
            XCTAssertFalse(laterPublications.isEmpty, name)
            XCTAssertTrue(laterPublications.allSatisfy {
                $0.optionalString("state") == "inactive"
            }, name)
            XCTAssertEqual(events("post_invalidation_observation_window", in: scenario).count, 1)
        }

        let power = try artifact.scenario("stop_during_power")
        XCTAssertTrue(try power.records("commands").contains {
            $0.optionalString("operation") == "wifi_power"
                && $0.optionalString("phase") == "return"
                && $0.optionalString("failure_category") == "cancelled"
        })
        let connectivity = try artifact.scenario("stop_during_connectivity_read")
        XCTAssertEqual(events("connectivity_read_cancelled", in: connectivity).count, 1)
        let probe = try artifact.scenario("stop_during_probe")
        XCTAssertTrue(try probe.records("reachability_calls").contains {
            $0.optionalString("phase") == "return" && $0.optionalString("outcome") == "cancelled"
        })
        let backoff = try artifact.scenario("stop_during_backoff")
        XCTAssertEqual(events("scheduler_sleep_cancelled", in: backoff).count, 1)
    }

    func testTransactionalPowerAndAssociationAreJournaledBeforeDispatchAndRestored() throws {
        let scenario = try HandoffArtifact.load().scenario("transactional_power_order_and_restore")
        let commands = try scenario.records("commands").filter {
            $0.optionalString("source") == "travel_session_system"
                && $0.optionalString("phase") == "dispatch"
        }
        XCTAssertEqual(commands.map { $0.optionalString("operation") }, [
            "wifi_power", "associate", "associate", "wifi_power",
        ])
        XCTAssertEqual(commands[0].optionalBool("power"), true)
        XCTAssertEqual(commands[1].optionalString("ssid_utf8_hex"), utf8Hex("Example iPhone"))
        XCTAssertEqual(commands[2].optionalString("ssid_utf8_hex"), utf8Hex("Office WiFi"))
        XCTAssertEqual(commands[3].optionalBool("power"), false)

        let journals = try scenario.records("journal_snapshots")
        let created = try XCTUnwrap(journals.first { $0.optionalString("operation") == "create" })
        XCTAssertEqual(created.optionalBool("baseline_power"), false)
        XCTAssertEqual(created.optionalString("baseline_ssidutf8_hex"), utf8Hex("Office WiFi"))
        let preparedPowerOn = try XCTUnwrap(journals.first {
            $0.optionalString("mutation_kind") == "wifi_power"
                && $0.optionalString("mutation_phase") == "prepared"
                && $0.optionalString("mutation_target_utf8_hex") == utf8Hex("true")
        })
        XCTAssertLessThan(try preparedPowerOn.integer("sequence"), try commands[0].integer("sequence"))
        let preparedTarget = try XCTUnwrap(journals.first {
            $0.optionalString("mutation_kind") == "association"
                && $0.optionalString("mutation_phase") == "prepared"
                && $0.optionalString("mutation_target_utf8_hex") == utf8Hex("Example iPhone")
        })
        XCTAssertLessThan(try preparedTarget.integer("sequence"), try commands[1].integer("sequence"))
        XCTAssertEqual(journals.last?.optionalString("operation"), "clear")
        XCTAssertTrue(states(in: scenario).contains("connected_via_configured_hotspot"))
        try assertRealProbePrecedesConnection(in: scenario)
    }

    func testTransactionalRetryReconcilesFailedMutationThenRestoresExactBaseline() throws {
        let scenario = try HandoffArtifact.load().scenario("transactional_retry_reconciliation")
        let commands = try scenario.records("commands")
        let proxyAssociations = commands.filter {
            $0.optionalString("source") == "session_manager_real_proxy"
                && $0.optionalString("operation") == "associate"
        }
        let proxyDispatches = proxyAssociations.filter { $0.optionalString("phase") == "dispatch" }
        let proxyReturns = proxyAssociations.filter { $0.optionalString("phase") == "return" }
        XCTAssertEqual(proxyDispatches.compactMap { $0.optionalInteger("attempt") }, [1, 2])
        XCTAssertEqual(proxyReturns.count, 2)
        XCTAssertNotEqual(proxyReturns[0].optionalInteger("exit_code"), 0)
        XCTAssertEqual(proxyReturns[0].optionalString("failure_category"), "command_failed")
        XCTAssertEqual(proxyReturns[1].optionalInteger("exit_code"), 0)
        XCTAssertEqual(Set(proxyDispatches.compactMap { $0.optionalString("session_id") }).count, 1)
        XCTAssertEqual(Set(proxyDispatches.compactMap { $0.optionalString("generation_id") }).count, 1)
        XCTAssertEqual(Set(proxyDispatches.compactMap { $0.optionalString("episode_id") }).count, 1)

        let systemAssociations = commands.filter {
            $0.optionalString("source") == "travel_session_system"
                && $0.optionalString("operation") == "associate"
        }
        let systemDispatches = systemAssociations.filter { $0.optionalString("phase") == "dispatch" }
        XCTAssertEqual(systemDispatches.compactMap { $0.optionalString("ssid_utf8_hex") }, [
            utf8Hex("Example iPhone"), utf8Hex("Example iPhone"), utf8Hex("Office WiFi"),
        ])
        let firstSystemFailure = try XCTUnwrap(systemAssociations.first {
            $0.optionalString("phase") == "return"
                && $0.optionalString("ssid_utf8_hex") == utf8Hex("Example iPhone")
                && ($0.optionalInteger("exit_code") ?? 0) != 0
        })
        let firstProxyReturn = try XCTUnwrap(proxyReturns.first)
        let secondProxyDispatch = try XCTUnwrap(proxyDispatches.last)
        XCTAssertLessThan(try firstSystemFailure.integer("sequence"), try firstProxyReturn.integer("sequence"))
        XCTAssertLessThan(try firstProxyReturn.integer("sequence"), try secondProxyDispatch.integer("sequence"))

        let baselineReadback = try XCTUnwrap(try scenario.records("provider_reads").first {
            $0.optionalString("provider") == "wifi_connectivity"
                && $0.optionalString("ssid_utf8_hex") == utf8Hex("Office WiFi")
                && ($0.optionalInteger("sequence") ?? 0) > (firstProxyReturn.optionalInteger("sequence") ?? Int.max)
                && ($0.optionalInteger("sequence") ?? Int.max) < (secondProxyDispatch.optionalInteger("sequence") ?? 0)
        })
        XCTAssertEqual(baselineReadback.optionalBool("power"), true)

        let journals = try scenario.records("journal_snapshots")
        let reconciled = try XCTUnwrap(journals.first {
            $0.optionalString("operation") == "update"
                && $0.optionalString("phase") == "active"
                && $0["mutation_kind"] == nil
                && $0.optionalBool("changed_association") == false
                && ($0.optionalInteger("sequence") ?? 0) > (firstSystemFailure.optionalInteger("sequence") ?? Int.max)
                && ($0.optionalInteger("sequence") ?? Int.max) < (secondProxyDispatch.optionalInteger("sequence") ?? 0)
        })
        XCTAssertEqual(reconciled.optionalString("baseline_ssidutf8_hex"), utf8Hex("Office WiFi"))
        XCTAssertEqual(reconciled.optionalBool("baseline_power"), true)
        let updateRevisions = journals.filter { $0.optionalString("operation") == "update" }
            .compactMap { $0.optionalInteger("revision") }
        XCTAssertEqual(updateRevisions, Array(1...updateRevisions.count))
        XCTAssertEqual(journals.last?.optionalString("operation"), "clear")

        let finalReadback = try XCTUnwrap(try scenario.records("provider_reads").last)
        XCTAssertEqual(finalReadback.optionalString("ssid_utf8_hex"), utf8Hex("Office WiFi"))
        XCTAssertEqual(finalReadback.optionalBool("power"), true)
        XCTAssertTrue(states(in: scenario).contains("connected_via_configured_hotspot"))
        try assertRealProbePrecedesConnection(in: scenario)
    }

    func testStoppedSessionCannotMutateOrPublishIntoNextSession() throws {
        let scenario = try HandoffArtifact.load().scenario("cross_session_stop_cancellation")
        let sessionAEvent = try XCTUnwrap(events("session_A_started", in: scenario).only)
        let sessionBEvent = try XCTUnwrap(events("session_B_started", in: scenario).only)
        let sessionA = try sessionAEvent.string("session_id")
        let sessionB = try sessionBEvent.string("session_id")
        XCTAssertNotEqual(sessionA, sessionB)

        let commands = try scenario.records("commands")
        let cancelledA = try XCTUnwrap(commands.first {
            $0.optionalString("operation") == "associate"
                && $0.optionalString("phase") == "return"
                && $0.optionalString("failure_category") == "cancelled"
        })
        XCTAssertLessThan(try cancelledA.integer("sequence"), try sessionBEvent.integer("sequence"))

        let journals = try scenario.records("journal_snapshots")
        XCTAssertEqual(journals.filter { $0.optionalString("operation") == "create" }.count, 2)
        XCTAssertEqual(journals.filter { $0.optionalString("operation") == "clear" }.count, 2)
        let startBSequence = try sessionBEvent.integer("sequence")
        for journal in journals where (journal.optionalInteger("sequence") ?? 0) >= startBSequence {
            XCTAssertEqual(journal.optionalString("session_id"), sessionB)
        }
        for publication in try scenario.records("publications")
            where (publication.optionalInteger("sequence") ?? 0) >= startBSequence
                && publication.optionalString("state") != "inactive" {
            XCTAssertEqual(publication.optionalString("session_id"), sessionB)
        }
        XCTAssertTrue(try scenario.records("publications").contains {
            $0.optionalString("session_id") == sessionB
                && $0.optionalString("state") == "connected_via_configured_hotspot"
        })
        try assertRealProbePrecedesConnection(in: scenario, sessionID: sessionB)
    }
}

private let requiredScenarioNames = [
    "app_state_open_close_idempotent",
    "initially_closed_healthy_target",
    "partial_ssid_only",
    "partial_address_only",
    "partial_wrong_route",
    "partial_http_rejected",
    "provider_failure_is_not_disconnection",
    "wifi_power_enable_failure",
    "retry_exhaustion_explicit_retry",
    "closed_healthy_path_loss_single_recovery",
    "initial_open_disconnected_waits",
    "open_associated_to_disconnected_fallback",
    "exact_byte_ssid_identity",
    "reopen_cancels_close_episode_then_reclose",
    "stop_during_power",
    "stop_during_association",
    "stop_during_connectivity_read",
    "stop_during_probe",
    "stop_during_backoff",
    "transactional_power_order_and_restore",
    "cross_session_stop_cancellation",
    "episode_budget_exhaustion",
    "transactional_retry_reconciliation",
]

private let forbiddenKeys: Set<String> = [
    "pass", "passed", "verdict", "checks", "assertions", "expected", "matches",
    "within_budget", "no_churn",
]

private struct HandoffArtifact {
    let root: JSONObject
    let rawText: String

    static func load() throws -> HandoffArtifact {
        guard let path = ProcessInfo.processInfo.environment["PROOF_ARTIFACT_PATH"], !path.isEmpty else {
            throw XCTSkip("PROOF_ARTIFACT_PATH is not set")
        }
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let root = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? JSONObject)
        return HandoffArtifact(
            root: root,
            rawText: try XCTUnwrap(String(data: data, encoding: .utf8))
        )
    }

    var scenarios: [JSONObject] {
        (root["scenarios"] as? [JSONObject]) ?? []
    }

    var scenarioNames: [String] {
        scenarios.compactMap { $0.optionalString("name") }
    }

    func scenario(_ name: String) throws -> JSONObject {
        try XCTUnwrap(scenarios.first { $0.optionalString("name") == name }, "Missing scenario \(name)")
    }
}

private typealias JSONObject = [String: Any]

private extension Dictionary where Key == String, Value == Any {
    func string(_ key: String) throws -> String {
        try XCTUnwrap(self[key] as? String, "Missing string key \(key)")
    }

    func optionalString(_ key: String) -> String? {
        self[key] as? String
    }

    func integer(_ key: String) throws -> Int {
        try XCTUnwrap(optionalInteger(key), "Missing integer key \(key)")
    }

    func optionalInteger(_ key: String) -> Int? {
        (self[key] as? NSNumber)?.intValue
    }

    func optionalBool(_ key: String) -> Bool? {
        (self[key] as? NSNumber)?.boolValue
    }

    func records(_ key: String) throws -> [JSONObject] {
        try XCTUnwrap(self[key] as? [JSONObject], "Missing record array \(key)")
    }
}

private extension Array {
    var only: Element? { count == 1 ? first : nil }
}

private func dispatchCommands(_ operation: String, in scenario: JSONObject) -> [JSONObject] {
    ((try? scenario.records("commands")) ?? []).filter {
        $0.optionalString("phase") == "dispatch" && $0.optionalString("operation") == operation
    }
}

private func episodeMutationCommands(in scenario: JSONObject) -> [JSONObject] {
    ((try? scenario.records("commands")) ?? []).filter {
        ["session_manager_fake", "session_manager_real_proxy"].contains($0.optionalString("source") ?? "")
            && ["wifi_power", "associate"].contains($0.optionalString("operation") ?? "")
    }
}

private func events(_ kind: String, in scenario: JSONObject) -> [JSONObject] {
    ((try? scenario.records("events")) ?? []).filter { $0.optionalString("kind") == kind }
}

private func states(in scenario: JSONObject) -> [String] {
    ((try? scenario.records("publications")) ?? []).compactMap { $0.optionalString("state") }
}

private func failureKinds(in scenario: JSONObject) -> Set<String> {
    Set(((try? scenario.records("publications")) ?? []).compactMap { $0.optionalString("failure_kind") })
}

private func episodeIDs(in scenario: JSONObject) -> Set<String> {
    Set(((try? scenario.records("publications")) ?? []).compactMap { $0.optionalString("episode_id") })
}

private func episodeTriggers(in scenario: JSONObject) -> Set<String> {
    Set(((try? scenario.records("publications")) ?? []).compactMap { $0.optionalString("trigger") })
}

private func assertRealProbePrecedesConnection(
    in scenario: JSONObject,
    sessionID: String? = nil,
    file: StaticString = #filePath,
    line: UInt = #line
) throws {
    let receipts = try scenario.records("http_receipts")
    let reachability = try scenario.records("reachability_calls")
    let publications = try scenario.records("publications")
    XCTAssertFalse(receipts.isEmpty, file: file, line: line)
    for receipt in receipts {
        XCTAssertEqual(receipt.optionalString("method"), "GET", file: file, line: line)
        XCTAssertEqual(receipt.optionalString("body_utf8_hex"), "", file: file, line: line)
        let headers = Set((receipt["header_names"] as? [String]) ?? [])
        XCTAssertFalse(headers.contains("authorization"), file: file, line: line)
        XCTAssertFalse(headers.contains("cookie"), file: file, line: line)
        XCTAssertNotNil(receipt.optionalString("nonce"), file: file, line: line)
    }
    for call in reachability where call.optionalString("phase") == "return" {
        guard let nonce = call.optionalString("nonce") else {
            XCTFail("Reachability result has no nonce", file: file, line: line)
            continue
        }
        if ["reachable", "rejected_status"].contains(call.optionalString("outcome") ?? "") {
            let receiptID = try XCTUnwrap(
                call.optionalString("receipt_id"),
                "Reachability result has no receipt identity",
                file: file,
                line: line
            )
            let receipt = try XCTUnwrap(
                receipts.first { $0.optionalString("receipt_id") == receiptID },
                "No loopback receipt for reachability receipt identity",
                file: file,
                line: line
            )
            XCTAssertEqual(receipt.optionalString("nonce"), nonce, file: file, line: line)
            XCTAssertLessThan(
                try receipt.integer("sequence"),
                try call.integer("sequence"),
                file: file,
                line: line
            )
        }
    }
    let connected = try XCTUnwrap(publications.first {
        $0.optionalString("state") == "connected_via_configured_hotspot"
            && (sessionID == nil || $0.optionalString("session_id") == sessionID)
    }, file: file, line: line)
    let connectedSequence = try connected.integer("sequence")
    XCTAssertTrue(reachability.contains {
        $0.optionalString("phase") == "return"
            && $0.optionalString("outcome") == "reachable"
            && ($0.optionalInteger("sequence") ?? Int.max) < connectedSequence
    }, file: file, line: line)
}

private func forbiddenKeyPaths(in value: Any, path: String = "$") -> [String] {
    if let object = value as? JSONObject {
        return object.flatMap { key, nested -> [String] in
            let next = "\(path).\(key)"
            return (forbiddenKeys.contains(key) ? [next] : []) + forbiddenKeyPaths(in: nested, path: next)
        }
    }
    if let array = value as? [Any] {
        return array.enumerated().flatMap { forbiddenKeyPaths(in: $0.element, path: "\(path)[\($0.offset)]") }
    }
    return []
}

private func utf8Hex(_ value: String) -> String {
    Data(value.utf8).map { String(format: "%02x", $0) }.joined()
}
