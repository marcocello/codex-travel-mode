import CodexTravelModeCore
import Foundation

struct FakeCoordinatorHarness {
    let trace: TraceRecorder
    let server: LoopbackProbeServer
    let scheduler: ManualHandoffScheduler
    let lid: RecordingLidProvider
    let connectivity: RecordingConnectivityProvider
    let session: RecordingSessionManager
    let reachability: RecordingReachabilityChecker
    let coordinator: TravelInternetHandoffCoordinator
    let context: HandoffSessionContext
}

func runAllScenarios() async throws -> [ScenarioRecord] {
    var scenarios: [ScenarioRecord] = []
    scenarios.append(try await runAppStateOpenCloseIdempotency())
    scenarios.append(try await runInitiallyClosedHealthyTarget())
    scenarios.append(try await runPartialScenario(
        name: "partial_ssid_only",
        observation: WiFiConnectivityObservation(
            device: proofDevice,
            power: .value(true),
            ssid: .value(ExactUTF8String(proofTargetSSID)),
            addresses: .value([]),
            defaultRouteInterface: .value(proofDevice)
        )
    ))
    scenarios.append(try await runPartialScenario(
        name: "partial_address_only",
        observation: WiFiConnectivityObservation(
            device: proofDevice,
            power: .value(true),
            ssid: .value(nil),
            addresses: .value([IPAddress("10.23.45.67")!]),
            defaultRouteInterface: .value(proofDevice)
        )
    ))
    scenarios.append(try await runPartialScenario(
        name: "partial_wrong_route",
        observation: WiFiConnectivityObservation(
            device: proofDevice,
            power: .value(true),
            ssid: .value(ExactUTF8String(proofTargetSSID)),
            addresses: .value([IPAddress("10.23.45.67")!]),
            defaultRouteInterface: .value("en9")
        )
    ))
    scenarios.append(try await runPartialScenario(
        name: "partial_http_rejected",
        observation: healthyObservation(ssid: proofTargetSSID),
        endpointPath: "/reject"
    ))
    scenarios.append(try await runProviderFailure())
    scenarios.append(try await runWiFiPowerFailure())
    scenarios.append(try await runRetryExhaustionAndExplicitRetry())
    scenarios.append(try await runClosedPathLossRecovery())
    scenarios.append(try await runInitialOpenDisconnection())
    scenarios.append(try await runOpenDisconnectionFallback())
    scenarios.append(try await runExactByteSSID())
    scenarios.append(try await runReopenCancellation())
    scenarios.append(try await runStopDuringPower())
    scenarios.append(try await runStopDuringAssociation())
    scenarios.append(try await runStopDuringConnectivityRead())
    scenarios.append(try await runStopDuringProbe())
    scenarios.append(try await runStopDuringBackoff())
    scenarios.append(try await runEpisodeBudgetExhaustion())
    scenarios.append(try await runPowerOrderAndRestoration())
    scenarios.append(try await runTransactionalRetryReconciliation())
    scenarios.append(try await runCrossSessionCancellation())
    return scenarios
}

@MainActor
private func runAppStateOpenCloseIdempotency() async throws -> ScenarioRecord {
    let harness = try makeFakeHarness(
        sessionID: "app-session-A",
        lid: .open,
        observation: healthyObservation(ssid: "Office WiFi")
    )
    let settingsStore = try ProofSettingsStore()
    let appState = TravelModeAppState(
        gateway: ProofGateway(trace: harness.trace),
        settingsStore: settingsStore,
        wifiDiscovery: ProofDiscoveryProvider(),
        sessionManager: harness.session,
        internetHandoffCoordinator: harness.coordinator
    )
    harness.trace.recordEvent("app_start_called", sessionID: harness.context.sessionID)
    await appState.start()
    await recordCurrentPublication(harness)
    await harness.lid.set(.closed)
    harness.trace.recordEvent("app_sync_called", sessionID: harness.context.sessionID, detail: "open_to_closed")
    await appState.syncOnce()
    _ = try await waitForState(harness) { $0.stateName == "connected_via_configured_hotspot" }
    await appState.syncOnce()
    for index in 1...10 {
        harness.trace.recordEvent("app_sync_called", sessionID: harness.context.sessionID, detail: "stable_closed_tick_\(index)")
        await appState.syncOnce()
        await recordCurrentPublication(harness)
    }
    harness.trace.recordEvent("app_stop_called", sessionID: harness.context.sessionID)
    await appState.stop()
    await recordCurrentPublication(harness)
    harness.server.stop()
    return await snapshot(
        harness,
        name: "app_state_open_close_idempotent",
        entrypoint: "TravelModeAppState.start/syncOnce/stop"
    )
}

private func runInitiallyClosedHealthyTarget() async throws -> ScenarioRecord {
    let harness = try makeFakeHarness(
        sessionID: "initially-closed-session",
        lid: .closed,
        observation: healthyObservation(ssid: proofTargetSSID)
    )
    try await activate(harness)
    _ = try await waitForState(harness) { $0.stateName == "connected_via_configured_hotspot" }
    for index in 1...10 {
        harness.trace.recordEvent("coordinator_tick", sessionID: harness.context.sessionID, detail: "stable_closed_tick_\(index)")
        let publication = await harness.coordinator.tick(generation: harness.context.generation)
        harness.trace.recordPublication(publication)
    }
    await invalidate(harness)
    harness.server.stop()
    return await snapshot(
        harness,
        name: "initially_closed_healthy_target",
        entrypoint: "TravelInternetHandoffCoordinator.activate/tick"
    )
}

private func runPartialScenario(
    name: String,
    observation: WiFiConnectivityObservation,
    endpointPath: String = "/probe"
) async throws -> ScenarioRecord {
    let harness = try makeFakeHarness(
        sessionID: "\(name)-session",
        lid: .closed,
        observation: observation,
        endpointPath: endpointPath,
        joinBehavior: .leaveUnchanged
    )
    try await activate(harness)
    _ = try await waitForState(harness) { $0.stateName == "failed" && $0.episodeID != nil }
    await invalidate(harness)
    harness.server.stop()
    return await snapshot(
        harness,
        name: name,
        entrypoint: "TravelInternetHandoffCoordinator.activate"
    )
}

private func runProviderFailure() async throws -> ScenarioRecord {
    let harness = try makeFakeHarness(
        sessionID: "provider-failure-session",
        lid: .closed,
        observation: providerFailureObservation(),
        joinBehavior: .leaveUnchanged
    )
    try await activate(harness)
    _ = try await waitForState(harness) {
        $0.stateName == "failed" && $0.failureKind == HandoffFailureKind.connectivityProviderFailed.rawValue
    }
    await invalidate(harness)
    harness.server.stop()
    return await snapshot(
        harness,
        name: "provider_failure_is_not_disconnection",
        entrypoint: "TravelInternetHandoffCoordinator.activate"
    )
}

private func runWiFiPowerFailure() async throws -> ScenarioRecord {
    let harness = try makeFakeHarness(
        sessionID: "power-failure-session",
        lid: .closed,
        observation: disconnectedObservation(power: false),
        joinBehavior: .leaveUnchanged
    )
    await harness.session.setPowerCommandFails(true)
    try await activate(harness)
    _ = try await waitForState(harness) {
        $0.stateName == "failed" && $0.failureKind == HandoffFailureKind.wifiPowerCommandFailed.rawValue
    }
    await invalidate(harness)
    harness.server.stop()
    return await snapshot(
        harness,
        name: "wifi_power_enable_failure",
        entrypoint: "TravelInternetHandoffCoordinator.activate"
    )
}

private func runRetryExhaustionAndExplicitRetry() async throws -> ScenarioRecord {
    let harness = try makeFakeHarness(
        sessionID: "retry-session",
        lid: .closed,
        observation: disconnectedObservation(power: true),
        joinBehavior: .leaveUnchanged
    )
    try await activate(harness)
    let failure = try await waitForState(harness) { $0.stateName == "failed" && $0.episodeID != nil }
    harness.trace.recordEvent(
        "retry_exhausted_idle_window_started",
        sessionID: failure.sessionID,
        generationID: failure.generationID,
        episodeID: failure.episodeID
    )
    for index in 1...10 {
        let publication = await harness.coordinator.tick(generation: harness.context.generation)
        harness.trace.recordPublication(publication)
        harness.trace.recordEvent("post_exhaustion_tick", sessionID: harness.context.sessionID, detail: String(index))
    }
    harness.trace.recordEvent("explicit_retry_called", sessionID: harness.context.sessionID)
    await harness.session.setJoinBehavior(.connectTarget)
    let retryPublication = await harness.coordinator.retry(generation: harness.context.generation)
    harness.trace.recordPublication(retryPublication)
    _ = try await waitForState(harness) { $0.stateName == "connected_via_configured_hotspot" }
    await invalidate(harness)
    harness.server.stop()
    return await snapshot(
        harness,
        name: "retry_exhaustion_explicit_retry",
        entrypoint: "TravelInternetHandoffCoordinator.activate/tick/retry"
    )
}

private func runInitialOpenDisconnection() async throws -> ScenarioRecord {
    let harness = try makeFakeHarness(
        sessionID: "initial-open-disconnected-session",
        lid: .open,
        observation: disconnectedObservation(power: true)
    )
    try await activate(harness)
    for index in 1...10 {
        let publication = await harness.coordinator.tick(generation: harness.context.generation)
        harness.trace.recordPublication(publication)
        harness.trace.recordEvent("open_disconnected_tick", sessionID: harness.context.sessionID, detail: String(index))
    }
    await invalidate(harness)
    harness.server.stop()
    return await snapshot(
        harness,
        name: "initial_open_disconnected_waits",
        entrypoint: "TravelInternetHandoffCoordinator.activate/tick"
    )
}

private func runClosedPathLossRecovery() async throws -> ScenarioRecord {
    let harness = try makeFakeHarness(
        sessionID: "closed-recovery-session",
        lid: .closed,
        observation: healthyObservation(ssid: proofTargetSSID)
    )
    try await activate(harness)
    _ = try await waitForState(harness) { $0.stateName == "connected_via_configured_hotspot" }
    await harness.connectivity.set(disconnectedObservation(power: true), event: "healthy_target_path_lost")
    var publication = await harness.coordinator.tick(generation: harness.context.generation)
    harness.trace.recordPublication(publication)
    await harness.scheduler.advance(by: HandoffRetryPolicy.production.recoveryCooldown)
    publication = await harness.coordinator.tick(generation: harness.context.generation)
    harness.trace.recordPublication(publication)
    _ = try await waitForState(harness) { $0.stateName == "connected_via_configured_hotspot" }
    for index in 1...10 {
        publication = await harness.coordinator.tick(generation: harness.context.generation)
        harness.trace.recordPublication(publication)
        harness.trace.recordEvent("post_recovery_closed_tick", sessionID: harness.context.sessionID, detail: String(index))
    }
    await invalidate(harness)
    harness.server.stop()
    return await snapshot(
        harness,
        name: "closed_healthy_path_loss_single_recovery",
        entrypoint: "TravelInternetHandoffCoordinator.activate/tick with recovery cooldown"
    )
}

private func runOpenDisconnectionFallback() async throws -> ScenarioRecord {
    let harness = try makeFakeHarness(
        sessionID: "open-disconnection-session",
        lid: .open,
        observation: healthyObservation(ssid: "Office WiFi")
    )
    try await activate(harness)
    _ = try await waitForState(harness) { $0.stateName == "preserving_current_network" }
    await harness.connectivity.set(disconnectedObservation(power: true), event: "associated_path_disconnected")
    let publication = await harness.coordinator.tick(generation: harness.context.generation)
    harness.trace.recordPublication(publication)
    _ = try await waitForState(harness) { $0.stateName == "connected_via_configured_hotspot" }
    await invalidate(harness)
    harness.server.stop()
    return await snapshot(
        harness,
        name: "open_associated_to_disconnected_fallback",
        entrypoint: "TravelInternetHandoffCoordinator.activate/tick"
    )
}

private func runExactByteSSID() async throws -> ScenarioRecord {
    let composed = "Caf\u{00e9} iPhone"
    let decomposed = "Cafe\u{0301} iPhone"
    let harness = try makeFakeHarness(
        sessionID: "exact-byte-session",
        lid: .closed,
        observation: healthyObservation(ssid: decomposed),
        targetSSID: composed
    )
    harness.trace.recordEvent("ssid_fixture_composed", detail: hex(Data(composed.utf8)))
    harness.trace.recordEvent("ssid_fixture_decomposed", detail: hex(Data(decomposed.utf8)))
    try await activate(harness)
    _ = try await waitForState(harness) { $0.stateName == "connected_via_configured_hotspot" }
    await invalidate(harness)
    harness.server.stop()
    return await snapshot(
        harness,
        name: "exact_byte_ssid_identity",
        entrypoint: "TravelInternetHandoffCoordinator.activate"
    )
}

private func runReopenCancellation() async throws -> ScenarioRecord {
    let harness = try makeFakeHarness(
        sessionID: "reopen-session",
        lid: .open,
        observation: healthyObservation(ssid: "Office WiFi"),
        joinBehavior: .blockUntilCancelled
    )
    try await activate(harness)
    _ = try await waitForState(harness) { $0.stateName == "preserving_current_network" }
    await harness.lid.set(.closed)
    var publication = await harness.coordinator.tick(generation: harness.context.generation)
    harness.trace.recordPublication(publication)
    _ = try await waitForState(harness) { $0.stateName == "associating" }
    await harness.lid.set(.open)
    publication = await harness.coordinator.tick(generation: harness.context.generation)
    harness.trace.recordPublication(publication)
    _ = try await waitForState(harness) { $0.stateName == "waiting_for_connection" && $0.episodeID == nil }
    await harness.session.setJoinBehavior(.connectTarget)
    await harness.lid.set(.closed)
    publication = await harness.coordinator.tick(generation: harness.context.generation)
    harness.trace.recordPublication(publication)
    _ = try await waitForState(harness) { $0.stateName == "connected_via_configured_hotspot" }
    await invalidate(harness)
    harness.server.stop()
    return await snapshot(
        harness,
        name: "reopen_cancels_close_episode_then_reclose",
        entrypoint: "TravelInternetHandoffCoordinator.activate/tick/invalidate"
    )
}

private func runStopDuringPower() async throws -> ScenarioRecord {
    let harness = try makeFakeHarness(
        sessionID: "stop-power-session",
        lid: .closed,
        observation: disconnectedObservation(power: false)
    )
    await harness.session.setPowerBlocksUntilCancelled(true)
    try await activate(harness)
    try await waitUntil { await harness.session.powerDispatchCount() >= 1 }
    return try await finishCancellationScenario(harness, name: "stop_during_power")
}

private func runStopDuringConnectivityRead() async throws -> ScenarioRecord {
    let harness = try makeFakeHarness(
        sessionID: "stop-connectivity-session",
        lid: .closed,
        observation: disconnectedObservation(power: true)
    )
    await harness.connectivity.setBlocksReadsUntilCancelled(true)
    try await activate(harness)
    try await waitUntil { await harness.connectivity.readDispatchCount() >= 1 }
    return try await finishCancellationScenario(harness, name: "stop_during_connectivity_read")
}

private func runStopDuringAssociation() async throws -> ScenarioRecord {
    let harness = try makeFakeHarness(
        sessionID: "stop-association-session",
        lid: .closed,
        observation: disconnectedObservation(power: true),
        joinBehavior: .blockUntilCancelled
    )
    try await activate(harness)
    _ = try await waitForState(harness) { $0.stateName == "associating" }
    return try await finishCancellationScenario(harness, name: "stop_during_association")
}

private func runStopDuringProbe() async throws -> ScenarioRecord {
    let harness = try makeFakeHarness(
        sessionID: "stop-probe-session",
        lid: .closed,
        observation: healthyObservation(ssid: proofTargetSSID),
        endpointPath: "/slow"
    )
    try await activate(harness)
    try await waitUntil { harness.reachability.dispatchCount() >= 1 }
    return try await finishCancellationScenario(harness, name: "stop_during_probe")
}

private func runStopDuringBackoff() async throws -> ScenarioRecord {
    let harness = try makeFakeHarness(
        sessionID: "stop-backoff-session",
        lid: .closed,
        observation: disconnectedObservation(power: true),
        joinBehavior: .leaveUnchanged,
        schedulerBlocksSleeps: true
    )
    try await activate(harness)
    _ = try await waitForState(harness) { $0.stateName == "retrying" }
    return try await finishCancellationScenario(harness, name: "stop_during_backoff")
}

private func finishCancellationScenario(
    _ harness: FakeCoordinatorHarness,
    name: String
) async throws -> ScenarioRecord {
    harness.trace.recordEvent(
        "invalidation_requested",
        sessionID: harness.context.sessionID,
        generationID: harness.context.generation.uuidString
    )
    let task = await harness.coordinator.invalidate(generation: harness.context.generation)
    if let task { await task.value }
    try await Task.sleep(for: .milliseconds(20))
    harness.trace.recordEvent("post_invalidation_observation_window", sessionID: harness.context.sessionID)
    await recordCurrentPublication(harness)
    harness.server.stop()
    return await snapshot(
        harness,
        name: name,
        entrypoint: "TravelInternetHandoffCoordinator.activate/invalidate"
    )
}

private func runEpisodeBudgetExhaustion() async throws -> ScenarioRecord {
    let harness = try makeFakeHarness(
        sessionID: "episode-budget-session",
        lid: .closed,
        observation: healthyObservation(ssid: "Office WiFi"),
        joinBehavior: .leaveUnchanged,
        consumeOperationTimeouts: true
    )
    try await activate(harness)
    _ = try await waitForState(harness) { $0.stateName == "failed" && $0.episodeID != nil }
    await invalidate(harness)
    harness.server.stop()
    return await snapshot(
        harness,
        name: "episode_budget_exhaustion",
        entrypoint: "TravelInternetHandoffCoordinator production budget with manual monotonic operation time"
    )
}

private func runPowerOrderAndRestoration() async throws -> ScenarioRecord {
    let trace = TraceRecorder()
    let server = try LoopbackProbeServer(trace: trace)
    let scheduler = ManualHandoffScheduler(trace: trace)
    let lid = RecordingLidProvider(.closed, trace: trace, scheduler: scheduler)
    let store = RecordingJournalStore(trace: trace)
    let system = RecordingSessionSystem(power: false, ssid: "Office WiFi", trace: trace)
    let session = TravelSessionCoordinator(
        journalStore: store,
        system: system,
        leaseClient: ProofLeaseClient()
    )
    let sessionProxy = IdentityRecordingSessionManager(
        base: session,
        trace: trace,
        scheduler: scheduler
    )
    let start = await session.start(configuration: TravelSessionConfiguration(wifiDevice: proofDevice))
    guard let sessionID = start.sessionID else { throw ScenarioError.missingSessionID("power_order_and_restore") }
    trace.recordEvent("transactional_session_started", sessionID: sessionID, detail: start.lifecycle.rawValue)
    let engine = TravelInternetHandoffEngine(
        connectivityProvider: system,
        reachabilityChecker: RecordingReachabilityChecker(
            endpoint: server.url(),
            trace: trace,
            scheduler: scheduler
        ),
        sessionManager: sessionProxy,
        policy: .production
    )
    let coordinator = TravelInternetHandoffCoordinator(
        lidProvider: lid,
        engine: engine,
        scheduler: scheduler,
        policy: .production
    )
    let context = HandoffSessionContext(
        sessionID: sessionID,
        generation: UUID(),
        device: proofDevice,
        targetSSID: ExactUTF8String(proofTargetSSID)!,
        password: proofPassword
    )
    trace.recordEvent("handoff_activate", sessionID: sessionID, generationID: context.generation.uuidString)
    let activation = await coordinator.activate(context)
    trace.recordPublication(activation)
    _ = try await waitForState(coordinator: coordinator, trace: trace) { $0.stateName == "connected_via_configured_hotspot" }
    let handoffTask = await coordinator.invalidate(generation: context.generation)
    if let handoffTask { await handoffTask.value }
    trace.recordPublication(await coordinator.currentPublication())
    let stop = await session.stop()
    trace.recordEvent("transactional_session_stopped", sessionID: sessionID, detail: stop.lifecycle.rawValue)
    _ = await system.readConnectivity(device: proofDevice, timeout: .productionProviderTimeout)
    server.stop()
    return trace.snapshot(
        name: "transactional_power_order_and_restore",
        entrypoint: "TravelSessionCoordinator.start + TravelInternetHandoffCoordinator.activate + TravelSessionCoordinator.stop",
        finalManualTime: await scheduler.now()
    )
}

private func runTransactionalRetryReconciliation() async throws -> ScenarioRecord {
    let trace = TraceRecorder()
    let server = try LoopbackProbeServer(trace: trace)
    let scheduler = ManualHandoffScheduler(trace: trace)
    let lid = RecordingLidProvider(.closed, trace: trace, scheduler: scheduler)
    let store = RecordingJournalStore(trace: trace)
    let system = RecordingSessionSystem(
        power: true,
        ssid: "Office WiFi",
        trace: trace,
        associationBehavior: .failFirstThenConnect
    )
    let session = TravelSessionCoordinator(
        journalStore: store,
        system: system,
        leaseClient: ProofLeaseClient()
    )
    let sessionProxy = IdentityRecordingSessionManager(
        base: session,
        trace: trace,
        scheduler: scheduler
    )
    let start = await session.start(configuration: TravelSessionConfiguration(wifiDevice: proofDevice))
    guard let sessionID = start.sessionID else {
        throw ScenarioError.missingSessionID("transactional_retry_reconciliation")
    }
    trace.recordEvent("transactional_session_started", sessionID: sessionID, detail: start.lifecycle.rawValue)
    let engine = TravelInternetHandoffEngine(
        connectivityProvider: system,
        reachabilityChecker: RecordingReachabilityChecker(
            endpoint: server.url(),
            trace: trace,
            scheduler: scheduler
        ),
        sessionManager: sessionProxy,
        policy: .production
    )
    let coordinator = TravelInternetHandoffCoordinator(
        lidProvider: lid,
        engine: engine,
        scheduler: scheduler,
        policy: .production
    )
    let context = HandoffSessionContext(
        sessionID: sessionID,
        generation: UUID(),
        device: proofDevice,
        targetSSID: ExactUTF8String(proofTargetSSID)!,
        password: proofPassword
    )
    trace.recordEvent("handoff_activate", sessionID: sessionID, generationID: context.generation.uuidString)
    trace.recordPublication(await coordinator.activate(context))
    _ = try await waitForState(coordinator: coordinator, trace: trace) {
        $0.stateName == "connected_via_configured_hotspot"
    }
    let handoffTask = await coordinator.invalidate(generation: context.generation)
    if let handoffTask { await handoffTask.value }
    trace.recordPublication(await coordinator.currentPublication())
    let stop = await session.stop()
    trace.recordEvent("transactional_session_stopped", sessionID: sessionID, detail: stop.lifecycle.rawValue)
    _ = await system.readConnectivity(
        device: proofDevice,
        timeout: HandoffRetryPolicy.production.providerTimeout
    )
    server.stop()
    return trace.snapshot(
        name: "transactional_retry_reconciliation",
        entrypoint: "TravelSessionCoordinator authoritative failed-attempt reconciliation and retry",
        finalManualTime: await scheduler.now()
    )
}

private func runCrossSessionCancellation() async throws -> ScenarioRecord {
    let trace = TraceRecorder()
    let server = try LoopbackProbeServer(trace: trace)
    let scheduler = ManualHandoffScheduler(trace: trace)
    let lid = RecordingLidProvider(.closed, trace: trace, scheduler: scheduler)
    let store = RecordingJournalStore(trace: trace)
    let system = RecordingSessionSystem(
        power: true,
        ssid: "Office WiFi",
        trace: trace,
        associationBehavior: .blockUntilCancelled
    )
    let session = TravelSessionCoordinator(
        journalStore: store,
        system: system,
        leaseClient: ProofLeaseClient()
    )
    let sessionProxy = IdentityRecordingSessionManager(
        base: session,
        trace: trace,
        scheduler: scheduler
    )
    let engine = TravelInternetHandoffEngine(
        connectivityProvider: system,
        reachabilityChecker: RecordingReachabilityChecker(
            endpoint: server.url(),
            trace: trace,
            scheduler: scheduler
        ),
        sessionManager: sessionProxy,
        policy: .production
    )
    let coordinator = TravelInternetHandoffCoordinator(
        lidProvider: lid,
        engine: engine,
        scheduler: scheduler,
        policy: .production
    )

    let startA = await session.start(configuration: TravelSessionConfiguration(wifiDevice: proofDevice))
    guard let sessionA = startA.sessionID else { throw ScenarioError.missingSessionID("cross_session_A") }
    let contextA = HandoffSessionContext(
        sessionID: sessionA,
        generation: UUID(),
        device: proofDevice,
        targetSSID: ExactUTF8String(proofTargetSSID)!,
        password: proofPassword
    )
    trace.recordEvent("session_A_started", sessionID: sessionA, generationID: contextA.generation.uuidString)
    trace.recordPublication(await coordinator.activate(contextA))
    _ = try await waitForState(coordinator: coordinator, trace: trace) { $0.stateName == "associating" }

    trace.recordEvent("session_A_invalidate_requested", sessionID: sessionA)
    let handoffA = await coordinator.invalidate(generation: contextA.generation)
    let stopA = await session.stop()
    if let handoffA { await handoffA.value }
    trace.recordEvent("session_A_stopped", sessionID: sessionA, detail: stopA.lifecycle.rawValue)
    trace.recordPublication(await coordinator.currentPublication())

    await system.setAssociationBehavior(.connect)
    let startB = await session.start(configuration: TravelSessionConfiguration(wifiDevice: proofDevice))
    guard let sessionB = startB.sessionID else { throw ScenarioError.missingSessionID("cross_session_B") }
    let contextB = HandoffSessionContext(
        sessionID: sessionB,
        generation: UUID(),
        device: proofDevice,
        targetSSID: ExactUTF8String(proofTargetSSID)!,
        password: proofPassword
    )
    trace.recordEvent("session_B_started", sessionID: sessionB, generationID: contextB.generation.uuidString)
    trace.recordPublication(await coordinator.activate(contextB))
    _ = try await waitForState(coordinator: coordinator, trace: trace) { $0.stateName == "connected_via_configured_hotspot" }
    let handoffB = await coordinator.invalidate(generation: contextB.generation)
    if let handoffB { await handoffB.value }
    let stopB = await session.stop()
    trace.recordEvent("session_B_stopped", sessionID: sessionB, detail: stopB.lifecycle.rawValue)
    trace.recordPublication(await coordinator.currentPublication())
    server.stop()
    return trace.snapshot(
        name: "cross_session_stop_cancellation",
        entrypoint: "TravelSessionCoordinator start/stop/start with TravelInternetHandoffCoordinator invalidate",
        finalManualTime: await scheduler.now()
    )
}

private func makeFakeHarness(
    sessionID: String,
    lid: LidState,
    observation: WiFiConnectivityObservation,
    endpointPath: String = "/probe",
    joinBehavior: FakeJoinBehavior = .connectTarget,
    targetSSID: String = proofTargetSSID,
    schedulerBlocksSleeps: Bool = false,
    consumeOperationTimeouts: Bool = false
) throws -> FakeCoordinatorHarness {
    let trace = TraceRecorder()
    let server = try LoopbackProbeServer(trace: trace)
    let scheduler = ManualHandoffScheduler(
        trace: trace,
        blocksSleepsUntilCancelled: schedulerBlocksSleeps
    )
    let lidProvider = RecordingLidProvider(lid, trace: trace, scheduler: scheduler)
    let connectivity = RecordingConnectivityProvider(
        observation,
        trace: trace,
        scheduler: scheduler,
        advancesByTimeout: consumeOperationTimeouts
    )
    let session = RecordingSessionManager(
        sessionID: sessionID,
        connectivity: connectivity,
        trace: trace,
        scheduler: scheduler,
        joinBehavior: joinBehavior,
        advancesAssociationByTimeout: consumeOperationTimeouts
    )
    let reachability = RecordingReachabilityChecker(
        endpoint: server.url(path: endpointPath),
        trace: trace,
        scheduler: scheduler,
        advancesByTimeout: consumeOperationTimeouts
    )
    let engine = TravelInternetHandoffEngine(
        connectivityProvider: connectivity,
        reachabilityChecker: reachability,
        sessionManager: session,
        policy: .production
    )
    let coordinator = TravelInternetHandoffCoordinator(
        lidProvider: lidProvider,
        engine: engine,
        scheduler: scheduler,
        policy: .production
    )
    let context = HandoffSessionContext(
        sessionID: sessionID,
        generation: UUID(),
        device: proofDevice,
        targetSSID: ExactUTF8String(targetSSID)!,
        password: proofPassword
    )
    return FakeCoordinatorHarness(
        trace: trace,
        server: server,
        scheduler: scheduler,
        lid: lidProvider,
        connectivity: connectivity,
        session: session,
        reachability: reachability,
        coordinator: coordinator,
        context: context
    )
}

private func waitUntil(
    _ predicate: @escaping @Sendable () async -> Bool
) async throws {
    for _ in 0..<3_000 {
        if await predicate() { return }
        try await Task.sleep(for: .milliseconds(2))
    }
    throw ScenarioError.timedOut
}

private func activate(_ harness: FakeCoordinatorHarness) async throws {
    harness.trace.recordEvent(
        "handoff_activate",
        sessionID: harness.context.sessionID,
        generationID: harness.context.generation.uuidString
    )
    let publication = await harness.coordinator.activate(harness.context)
    harness.trace.recordPublication(publication)
}

private func invalidate(_ harness: FakeCoordinatorHarness) async {
    harness.trace.recordEvent(
        "handoff_invalidate",
        sessionID: harness.context.sessionID,
        generationID: harness.context.generation.uuidString
    )
    let task = await harness.coordinator.invalidate(generation: harness.context.generation)
    if let task { await task.value }
    await recordCurrentPublication(harness)
}

private func recordCurrentPublication(_ harness: FakeCoordinatorHarness) async {
    harness.trace.recordPublication(await harness.coordinator.currentPublication())
}

private func snapshot(
    _ harness: FakeCoordinatorHarness,
    name: String,
    entrypoint: String
) async -> ScenarioRecord {
    harness.trace.snapshot(
        name: name,
        entrypoint: entrypoint,
        finalManualTime: await harness.scheduler.now()
    )
}

private func waitForState(
    _ harness: FakeCoordinatorHarness,
    predicate: @escaping @Sendable (ObservedPublication) -> Bool
) async throws -> ObservedPublication {
    try await waitForState(coordinator: harness.coordinator, trace: harness.trace, predicate: predicate)
}

private func waitForState(
    coordinator: TravelInternetHandoffCoordinator,
    trace: TraceRecorder,
    predicate: @escaping @Sendable (ObservedPublication) -> Bool
) async throws -> ObservedPublication {
    var previous: TravelInternetStatePublication?
    for _ in 0..<3_000 {
        let publication = await coordinator.currentPublication()
        if publication != previous {
            trace.recordPublication(publication)
            previous = publication
        }
        let observed = ObservedPublication(publication)
        if predicate(observed) { return observed }
        try await Task.sleep(for: .milliseconds(2))
    }
    throw ScenarioError.timedOut
}

struct ObservedPublication: Sendable {
    let sessionID: String?
    let generationID: String?
    let episodeID: String?
    let stateName: String
    let failureKind: String?

    init(_ publication: TravelInternetStatePublication) {
        sessionID = publication.sessionID
        generationID = publication.generation?.uuidString
        episodeID = publication.episodeID
        switch publication.state {
        case .inactive: stateName = "inactive"
        case .waitingForConnection: stateName = "waiting_for_connection"
        case .preservingCurrentNetwork: stateName = "preserving_current_network"
        case .handoffPending: stateName = "handoff_pending"
        case .associating: stateName = "associating"
        case .verifying: stateName = "verifying"
        case .connectedViaConfiguredHotspot: stateName = "connected_via_configured_hotspot"
        case .retrying: stateName = "retrying"
        case .failed(let failure):
            stateName = "failed"
            failureKind = failure.kind.rawValue
            return
        }
        failureKind = nil
    }
}

private enum ScenarioError: Error {
    case timedOut
    case missingSessionID(String)
}

private extension Duration {
    static var productionProviderTimeout: Duration {
        HandoffRetryPolicy.production.providerTimeout
    }
}
