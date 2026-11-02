import CodexTravelModeCore
import Foundation

struct ProofArtifact: Codable {
    let schemaVersion: Int
    let workerPID: Int32
    let scenarios: [ScenarioRecord]
}

struct ScenarioRecord: Codable {
    let name: String
    let entrypoint: String
    let events: [EventRecord]
    let providerReads: [ProviderReadRecord]
    let commands: [CommandRecord]
    let publications: [PublicationRecord]
    let reachabilityCalls: [ReachabilityCallRecord]
    let httpReceipts: [HTTPReceiptRecord]
    let journalSnapshots: [JournalSnapshotRecord]
    let schedulerSleeps: [SchedulerSleepRecord]
    let finalManualTimeMilliseconds: Int64
}

struct EventRecord: Codable {
    let sequence: Int
    let wallMilliseconds: Int64
    let manualTimeMilliseconds: Int64?
    let kind: String
    let sessionID: String?
    let generationID: String?
    let episodeID: String?
    let detail: String?
}

struct ProviderReadRecord: Codable {
    let sequence: Int
    let wallMilliseconds: Int64
    let manualTimeMilliseconds: Int64?
    let provider: String
    let timeoutMilliseconds: Int64
    let device: String?
    let lidState: String?
    let power: Bool?
    let ssidState: String?
    let ssidUTF8Hex: String?
    let addresses: [String]
    let routeState: String?
    let routeInterface: String?
    let failureCategory: String?
    let failureDetail: String?
}

struct CommandRecord: Codable {
    let sequence: Int
    let wallMilliseconds: Int64
    let manualTimeMilliseconds: Int64?
    let source: String
    let phase: String
    let operation: String
    let sessionID: String?
    let generationID: String?
    let episodeID: String?
    let attempt: Int?
    let device: String?
    let power: Bool?
    let ssidUTF8Hex: String?
    let timeoutMilliseconds: Int64?
    let exitCode: Int32?
    let failureCategory: String?
}

struct PublicationRecord: Codable {
    let sequence: Int
    let wallMilliseconds: Int64
    let sessionID: String?
    let generationID: String?
    let episodeID: String?
    let state: String
    let trigger: String?
    let attempt: Int?
    let nextAttempt: Int?
    let delayMilliseconds: Int64?
    let ssidUTF8Hex: String?
    let failureKind: String?
    let failureRetryable: Bool?
}

struct ReachabilityCallRecord: Codable {
    let sequence: Int
    let wallMilliseconds: Int64
    let manualTimeMilliseconds: Int64?
    let callID: String
    let phase: String
    let timeoutMilliseconds: Int64
    let nonce: String
    let receiptID: String?
    let outcome: String?
    let responseCode: Int?
}

struct HTTPReceiptRecord: Codable {
    let sequence: Int
    let wallMilliseconds: Int64
    let receiptID: String
    let method: String
    let path: String
    let nonce: String?
    let headerNames: [String]
    let bodyUTF8Hex: String
    let responseCode: Int
}

struct JournalSnapshotRecord: Codable {
    let sequence: Int
    let wallMilliseconds: Int64
    let operation: String
    let sessionID: String
    let revision: Int
    let phase: String?
    let baselineDevice: String?
    let baselinePower: Bool?
    let baselineSSIDUTF8Hex: String?
    let mutationKind: String?
    let mutationPhase: String?
    let mutationBaselineUTF8Hex: String?
    let mutationTargetUTF8Hex: String?
    let changedWiFiPower: Bool?
    let changedAssociation: Bool?
}

struct SchedulerSleepRecord: Codable {
    let sequence: Int
    let wallMilliseconds: Int64
    let durationMilliseconds: Int64
    let elapsedMilliseconds: Int64
}

final class TraceRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private let startedAt = DispatchTime.now().uptimeNanoseconds
    private var sequence = 0
    private var events: [EventRecord] = []
    private var providerReads: [ProviderReadRecord] = []
    private var commands: [CommandRecord] = []
    private var publications: [PublicationRecord] = []
    private var reachabilityCalls: [ReachabilityCallRecord] = []
    private var httpReceipts: [HTTPReceiptRecord] = []
    private var journalSnapshots: [JournalSnapshotRecord] = []
    private var schedulerSleeps: [SchedulerSleepRecord] = []

    func recordEvent(
        _ kind: String,
        sessionID: String? = nil,
        generationID: String? = nil,
        episodeID: String? = nil,
        detail: String? = nil,
        manualTime: Duration? = nil
    ) {
        withStamp { sequence, wall in
            events.append(EventRecord(
                sequence: sequence,
                wallMilliseconds: wall,
                manualTimeMilliseconds: manualTime.map(durationMilliseconds),
                kind: kind,
                sessionID: sessionID,
                generationID: generationID,
                episodeID: episodeID,
                detail: detail
            ))
        }
    }

    func recordLidRead(
        _ reading: ProviderReading<LidState>,
        timeout: Duration,
        manualTime: Duration? = nil
    ) {
        let value = reading.value
        let failure = reading.failure
        withStamp { sequence, wall in
            providerReads.append(ProviderReadRecord(
                sequence: sequence,
                wallMilliseconds: wall,
                manualTimeMilliseconds: manualTime.map(durationMilliseconds),
                provider: "lid_state",
                timeoutMilliseconds: durationMilliseconds(timeout),
                device: nil,
                lidState: value?.rawValue,
                power: nil,
                ssidState: nil,
                ssidUTF8Hex: nil,
                addresses: [],
                routeState: nil,
                routeInterface: nil,
                failureCategory: failure?.category.rawValue,
                failureDetail: failure?.detail
            ))
        }
    }

    func recordConnectivityRead(
        _ observation: WiFiConnectivityObservation,
        timeout: Duration,
        manualTime: Duration? = nil
    ) {
        let failure = observation.power.failure
            ?? observation.ssid.failure
            ?? observation.addresses.failure
            ?? observation.defaultRouteInterface.failure
        let ssidState: String
        let ssidHex: String?
        switch observation.ssid {
        case .value(let ssid):
            ssidState = ssid == nil ? "disconnected" : "associated"
            ssidHex = ssid.map { hex($0.utf8Bytes) }
        case .failure:
            ssidState = "provider_failure"
            ssidHex = nil
        }
        let routeState: String
        let route: String?
        switch observation.defaultRouteInterface {
        case .value(let interface):
            routeState = interface == nil ? "absent" : "present"
            route = interface
        case .failure:
            routeState = "provider_failure"
            route = nil
        }
        withStamp { sequence, wall in
            providerReads.append(ProviderReadRecord(
                sequence: sequence,
                wallMilliseconds: wall,
                manualTimeMilliseconds: manualTime.map(durationMilliseconds),
                provider: "wifi_connectivity",
                timeoutMilliseconds: durationMilliseconds(timeout),
                device: observation.device,
                lidState: nil,
                power: observation.power.value,
                ssidState: ssidState,
                ssidUTF8Hex: ssidHex,
                addresses: observation.addresses.value?.map(\.rawValue) ?? [],
                routeState: routeState,
                routeInterface: route,
                failureCategory: failure?.category.rawValue,
                failureDetail: failure?.detail
            ))
        }
    }

    func recordCommand(
        source: String,
        phase: String,
        operation: String,
        sessionID: String? = nil,
        episode: HandoffEpisodeToken? = nil,
        attempt: Int? = nil,
        device: String? = nil,
        power: Bool? = nil,
        ssid: String? = nil,
        timeout: Duration? = nil,
        result: CommandResult? = nil,
        manualTime: Duration? = nil
    ) {
        withStamp { sequence, wall in
            commands.append(CommandRecord(
                sequence: sequence,
                wallMilliseconds: wall,
                manualTimeMilliseconds: manualTime.map(durationMilliseconds),
                source: source,
                phase: phase,
                operation: operation,
                sessionID: episode?.sessionID ?? sessionID,
                generationID: episode?.generation.uuidString,
                episodeID: episode?.episodeID,
                attempt: attempt,
                device: device,
                power: power,
                ssidUTF8Hex: ssid.map { hex(Data($0.utf8)) },
                timeoutMilliseconds: timeout.map(durationMilliseconds),
                exitCode: result?.exitCode,
                failureCategory: result?.failureCategory?.rawValue
            ))
        }
    }

    func recordPublication(_ publication: TravelInternetStatePublication) {
        let encoded = encodeRuntimeState(publication.state)
        withStamp { sequence, wall in
            publications.append(PublicationRecord(
                sequence: sequence,
                wallMilliseconds: wall,
                sessionID: publication.sessionID,
                generationID: publication.generation?.uuidString,
                episodeID: publication.episodeID,
                state: encoded.state,
                trigger: encoded.trigger?.rawValue,
                attempt: encoded.attempt,
                nextAttempt: encoded.nextAttempt,
                delayMilliseconds: encoded.delay.map(durationMilliseconds),
                ssidUTF8Hex: encoded.ssid.map { hex($0.utf8Bytes) },
                failureKind: encoded.failure?.kind.rawValue,
                failureRetryable: encoded.failure?.retryable
            ))
        }
    }

    func recordReachabilityDispatch(
        callID: String,
        timeout: Duration,
        nonce: String,
        manualTime: Duration? = nil
    ) {
        withStamp { sequence, wall in
            reachabilityCalls.append(ReachabilityCallRecord(
                sequence: sequence,
                wallMilliseconds: wall,
                manualTimeMilliseconds: manualTime.map(durationMilliseconds),
                callID: callID,
                phase: "dispatch",
                timeoutMilliseconds: durationMilliseconds(timeout),
                nonce: nonce,
                receiptID: nil,
                outcome: nil,
                responseCode: nil
            ))
        }
    }

    func recordReachabilityReturn(
        callID: String,
        timeout: Duration,
        nonce: String,
        result: ReachabilityResult,
        manualTime: Duration? = nil
    ) {
        let receiptID = httpReceiptID(nonce: nonce)
        let outcome: String
        let code: Int?
        switch result {
        case .reachable(let statusCode):
            outcome = "reachable"
            code = statusCode
        case .failed(let failure):
            outcome = reachabilityFailureName(failure)
            if case .rejectedStatus(let statusCode) = failure {
                code = statusCode
            } else {
                code = nil
            }
        }
        withStamp { sequence, wall in
            reachabilityCalls.append(ReachabilityCallRecord(
                sequence: sequence,
                wallMilliseconds: wall,
                manualTimeMilliseconds: manualTime.map(durationMilliseconds),
                callID: callID,
                phase: "return",
                timeoutMilliseconds: durationMilliseconds(timeout),
                nonce: nonce,
                receiptID: receiptID,
                outcome: outcome,
                responseCode: code
            ))
        }
    }

    func recordHTTPReceipt(
        receiptID: String,
        method: String,
        path: String,
        nonce: String?,
        headerNames: [String],
        body: Data,
        responseCode: Int
    ) {
        withStamp { sequence, wall in
            httpReceipts.append(HTTPReceiptRecord(
                sequence: sequence,
                wallMilliseconds: wall,
                receiptID: receiptID,
                method: method,
                path: path,
                nonce: nonce,
                headerNames: headerNames.sorted(),
                bodyUTF8Hex: hex(body),
                responseCode: responseCode
            ))
        }
    }

    private func httpReceiptID(nonce: String) -> String? {
        lock.withLock {
            httpReceipts.last { $0.nonce == nonce }?.receiptID
        }
    }

    func recordJournal(operation: String, journal: TravelSessionJournal) {
        withStamp { sequence, wall in
            journalSnapshots.append(journalRecord(
                sequence: sequence,
                wall: wall,
                operation: operation,
                journal: journal
            ))
        }
    }

    func recordJournalClear(sessionID: String, revision: Int) {
        withStamp { sequence, wall in
            journalSnapshots.append(JournalSnapshotRecord(
                sequence: sequence,
                wallMilliseconds: wall,
                operation: "clear",
                sessionID: sessionID,
                revision: revision,
                phase: nil,
                baselineDevice: nil,
                baselinePower: nil,
                baselineSSIDUTF8Hex: nil,
                mutationKind: nil,
                mutationPhase: nil,
                mutationBaselineUTF8Hex: nil,
                mutationTargetUTF8Hex: nil,
                changedWiFiPower: nil,
                changedAssociation: nil
            ))
        }
    }

    func recordSchedulerSleep(duration: Duration, elapsed: Duration) {
        withStamp { sequence, wall in
            schedulerSleeps.append(SchedulerSleepRecord(
                sequence: sequence,
                wallMilliseconds: wall,
                durationMilliseconds: durationMilliseconds(duration),
                elapsedMilliseconds: durationMilliseconds(elapsed)
            ))
        }
    }

    func snapshot(name: String, entrypoint: String, finalManualTime: Duration) -> ScenarioRecord {
        lock.lock()
        defer { lock.unlock() }
        return ScenarioRecord(
            name: name,
            entrypoint: entrypoint,
            events: events,
            providerReads: providerReads,
            commands: commands,
            publications: publications,
            reachabilityCalls: reachabilityCalls,
            httpReceipts: httpReceipts,
            journalSnapshots: journalSnapshots,
            schedulerSleeps: schedulerSleeps,
            finalManualTimeMilliseconds: durationMilliseconds(finalManualTime)
        )
    }

    private func withStamp(_ body: (Int, Int64) -> Void) {
        lock.lock()
        defer { lock.unlock() }
        sequence += 1
        let now = DispatchTime.now().uptimeNanoseconds
        body(sequence, Int64((now - startedAt) / 1_000_000))
    }
}

private struct EncodedRuntimeState {
    let state: String
    let trigger: HandoffTrigger?
    let attempt: Int?
    let nextAttempt: Int?
    let delay: Duration?
    let ssid: ExactUTF8String?
    let failure: HandoffFailure?
}

private func encodeRuntimeState(_ state: TravelInternetRuntimeState) -> EncodedRuntimeState {
    switch state {
    case .inactive:
        EncodedRuntimeState(state: "inactive", trigger: nil, attempt: nil, nextAttempt: nil, delay: nil, ssid: nil, failure: nil)
    case .waitingForConnection:
        EncodedRuntimeState(state: "waiting_for_connection", trigger: nil, attempt: nil, nextAttempt: nil, delay: nil, ssid: nil, failure: nil)
    case .preservingCurrentNetwork(let ssid):
        EncodedRuntimeState(state: "preserving_current_network", trigger: nil, attempt: nil, nextAttempt: nil, delay: nil, ssid: ssid, failure: nil)
    case .handoffPending(_, let trigger):
        EncodedRuntimeState(state: "handoff_pending", trigger: trigger, attempt: nil, nextAttempt: nil, delay: nil, ssid: nil, failure: nil)
    case .associating(_, let attempt):
        EncodedRuntimeState(state: "associating", trigger: nil, attempt: attempt, nextAttempt: nil, delay: nil, ssid: nil, failure: nil)
    case .verifying(_, let attempt):
        EncodedRuntimeState(state: "verifying", trigger: nil, attempt: attempt, nextAttempt: nil, delay: nil, ssid: nil, failure: nil)
    case .connectedViaConfiguredHotspot(let ssid):
        EncodedRuntimeState(state: "connected_via_configured_hotspot", trigger: nil, attempt: nil, nextAttempt: nil, delay: nil, ssid: ssid, failure: nil)
    case .retrying(_, let nextAttempt, let delay):
        EncodedRuntimeState(state: "retrying", trigger: nil, attempt: nil, nextAttempt: nextAttempt, delay: delay, ssid: nil, failure: nil)
    case .failed(let failure):
        EncodedRuntimeState(state: "failed", trigger: nil, attempt: nil, nextAttempt: nil, delay: nil, ssid: nil, failure: failure)
    }
}

private func journalRecord(
    sequence: Int,
    wall: Int64,
    operation: String,
    journal: TravelSessionJournal
) -> JournalSnapshotRecord {
    let intent = journal.pendingMutation
    let baselineSSID = journal.wifiBaseline.associatedSSID.map { hex(Data($0.utf8)) }
    let mutationBaseline = intent.map { hex(Data($0.baseline.utf8)) }
    let mutationTarget = intent.map { hex(Data($0.target.utf8)) }
    return JournalSnapshotRecord(
        sequence: sequence,
        wallMilliseconds: wall,
        operation: operation,
        sessionID: journal.sessionID,
        revision: journal.revision,
        phase: journal.phase.rawValue,
        baselineDevice: journal.wifiBaseline.device,
        baselinePower: journal.wifiBaseline.powerEnabled,
        baselineSSIDUTF8Hex: baselineSSID,
        mutationKind: intent?.kind.rawValue,
        mutationPhase: intent?.phase.rawValue,
        mutationBaselineUTF8Hex: mutationBaseline,
        mutationTargetUTF8Hex: mutationTarget,
        changedWiFiPower: journal.changedWiFiPower,
        changedAssociation: journal.changedAssociation
    )
}

func durationMilliseconds(_ duration: Duration) -> Int64 {
    let components = duration.components
    let seconds = components.seconds.multipliedReportingOverflow(by: 1_000)
    let fractional = components.attoseconds / 1_000_000_000_000_000
    if seconds.overflow { return seconds.partialValue }
    return seconds.partialValue + Int64(fractional)
}

func hex(_ data: Data) -> String {
    data.map { String(format: "%02x", $0) }.joined()
}

private func reachabilityFailureName(_ failure: ReachabilityFailure) -> String {
    switch failure {
    case .timedOut: "timed_out"
    case .cancelled: "cancelled"
    case .transport: "transport"
    case .nonHTTPResponse: "non_http_response"
    case .rejectedStatus: "rejected_status"
    }
}
