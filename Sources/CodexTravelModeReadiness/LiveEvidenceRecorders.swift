import Foundation

public final class LiveControllerEvidenceRecorder: @unchecked Sendable {
    public static let maximumEventsPerArtifact = 4_096

    public let runID: String
    public let controller: LiveProofProcessIdentity

    private let redactionSalt: Data
    private let lock = NSLock()
    private var commandEvents: [LiveOracleControllerEvent] = []
    private var operatorEvents: [LiveOracleControllerEvent] = []
    private var cleanupEvents: [LiveOracleControllerEvent] = []

    public init(
        runID: String,
        controller: LiveProofProcessIdentity,
        redactionSalt: Data
    ) throws {
        guard LiveProofValidation.isCanonicalRunID(runID) else {
            throw LiveEvidenceError.invalidBinding("run ID is not canonical")
        }
        guard redactionSalt.count >= 32 else {
            throw LiveEvidenceError.invalidBinding("redaction salt is too short")
        }
        self.runID = runID
        self.controller = controller
        self.redactionSalt = redactionSalt
    }

    public func appendCommand(
        unixMilliseconds: Int64,
        monotonicNanoseconds: UInt64,
        scenario: ReadinessScenario?,
        kind: LiveOracleControllerEventKind,
        heartbeatSequence: Int? = nil,
        nonce: String? = nil,
        process: LiveProofProcessIdentity? = nil,
        signal: Int32? = nil
    ) throws {
        guard Self.commandKinds.contains(kind) else {
            throw LiveEvidenceError.invalidEvent("kind is not controller-command evidence")
        }
        try validateCommandShape(
            scenario: scenario,
            kind: kind,
            heartbeatSequence: heartbeatSequence,
            nonce: nonce,
            process: process,
            signal: signal
        )
        try append(
            to: &commandEvents,
            unixMilliseconds: unixMilliseconds,
            monotonicNanoseconds: monotonicNanoseconds,
            scenario: scenario,
            kind: kind,
            heartbeatSequence: heartbeatSequence,
            nonce: nonce,
            process: process,
            signal: signal
        )
    }

    public func appendOperatorEvent(
        unixMilliseconds: Int64,
        monotonicNanoseconds: UInt64,
        scenario: ReadinessScenario,
        kind: LiveOracleControllerEventKind
    ) throws {
        guard Self.operatorKinds.contains(kind) else {
            throw LiveEvidenceError.invalidEvent("kind is not operator evidence")
        }
        try append(
            to: &operatorEvents,
            unixMilliseconds: unixMilliseconds,
            monotonicNanoseconds: monotonicNanoseconds,
            scenario: scenario,
            kind: kind
        )
    }

    public func appendCleanupRequest(
        unixMilliseconds: Int64,
        monotonicNanoseconds: UInt64,
        scenario: ReadinessScenario?,
        kind: LiveOracleControllerEventKind,
        process: LiveProofProcessIdentity? = nil,
        signal: Int32? = nil
    ) throws {
        guard Self.cleanupKinds.contains(kind) else {
            throw LiveEvidenceError.invalidEvent("kind is not cleanup-request evidence")
        }
        guard kind == .safetyTerminateRequested || signal == nil else {
            throw LiveEvidenceError.invalidEvent("signal is only valid for a safety termination")
        }
        try append(
            to: &cleanupEvents,
            unixMilliseconds: unixMilliseconds,
            monotonicNanoseconds: monotonicNanoseconds,
            scenario: scenario,
            kind: kind,
            process: process,
            signal: signal
        )
    }

    public func snapshotArtifacts() -> LiveEvidenceControllerArtifacts {
        lock.lock()
        defer { lock.unlock() }
        return LiveEvidenceControllerArtifacts(
            command: LiveOracleControllerArtifact(
                schema: "codex-travel-mode-command-events/v1",
                runID: runID,
                producer: controller,
                events: commandEvents
            ),
            operatorEvents: LiveOracleControllerArtifact(
                schema: "codex-travel-mode-operator-events/v1",
                runID: runID,
                producer: controller,
                events: operatorEvents
            ),
            cleanup: LiveOracleControllerArtifact(
                schema: "codex-travel-mode-cleanup-events/v1",
                runID: runID,
                producer: controller,
                events: cleanupEvents
            )
        )
    }

    private func validateCommandShape(
        scenario: ReadinessScenario?,
        kind: LiveOracleControllerEventKind,
        heartbeatSequence: Int?,
        nonce: String?,
        process: LiveProofProcessIdentity?,
        signal: Int32?
    ) throws {
        switch kind {
        case .heartbeatSubmitRequest:
            guard scenario != nil, let heartbeatSequence, heartbeatSequence > 0,
                  let nonce,
                  (try? LiveProofBase64URL.decode(nonce, exactByteCount: 32)) != nil,
                  process == nil, signal == nil else {
                throw LiveEvidenceError.invalidEvent("heartbeat submit fields are incomplete")
            }
        case .heartbeatReadbackRequest:
            guard scenario != nil, heartbeatSequence == nil, nonce == nil,
                  process == nil, signal == nil else {
                throw LiveEvidenceError.invalidEvent("heartbeat readback fields are invalid")
            }
        case .appLaunchRequest:
            guard scenario != nil, heartbeatSequence == nil, nonce == nil,
                  signal == nil else {
                throw LiveEvidenceError.invalidEvent("app launch fields are invalid")
            }
        case .ownerDeathSIGKILLRequest:
            guard scenario == .ownerDeath, heartbeatSequence == nil, nonce == nil,
                  process != nil, signal == SIGKILL else {
                throw LiveEvidenceError.invalidEvent("owner-death kill fields are incomplete")
            }
        default:
            throw LiveEvidenceError.invalidEvent("kind is not controller-command evidence")
        }
    }

    private func append(
        to events: inout [LiveOracleControllerEvent],
        unixMilliseconds: Int64,
        monotonicNanoseconds: UInt64,
        scenario: ReadinessScenario?,
        kind: LiveOracleControllerEventKind,
        heartbeatSequence: Int? = nil,
        nonce: String? = nil,
        process: LiveProofProcessIdentity? = nil,
        signal: Int32? = nil
    ) throws {
        guard unixMilliseconds >= 0 else {
            throw LiveEvidenceError.invalidEvent("wall-clock time is negative")
        }
        lock.lock()
        defer { lock.unlock() }
        guard events.count < Self.maximumEventsPerArtifact else {
            throw LiveEvidenceError.capacityExceeded
        }
        if let previous = events.last,
           monotonicNanoseconds < previous.monotonicNanoseconds {
            throw LiveEvidenceError.invalidEvent("monotonic time moved backwards")
        }
        events.append(LiveOracleControllerEvent(
            sequence: events.count + 1,
            unixMilliseconds: unixMilliseconds,
            monotonicNanoseconds: monotonicNanoseconds,
            scenario: scenario,
            kind: kind,
            heartbeatSequence: heartbeatSequence,
            nonce: nonce,
            process: process,
            signal: signal
        ))
    }

    private static let commandKinds: Set<LiveOracleControllerEventKind> = [
        .heartbeatSubmitRequest, .heartbeatReadbackRequest, .appLaunchRequest,
        .ownerDeathSIGKILLRequest,
    ]
    private static let operatorKinds: Set<LiveOracleControllerEventKind> = [
        .start, .lidClose, .lidOpen, .stopRestore, .quit, .relaunch,
    ]
    private static let cleanupKinds: Set<LiveOracleControllerEventKind> = [
        .cleanupEntered, .productionStopRequested, .productionQuitRequested,
        .startupRecoveryRequested, .helperOwnerDeathWait,
        .safetyTerminateRequested, .directRescueRequested,
    ]
}

public final class LiveObserverEvidenceRecorder: @unchecked Sendable {
    public static let maximumEvents = 4_096
    public static let maximumTransportRecords = 1_024
    public static let maximumReceipts = 1_024

    public let runID: String
    public let observer: LiveProofProcessIdentity
    public let observerPublicKey: String

    private let signer: LiveProofEphemeralSigner
    private let redactionSalt: Data
    private let lock = NSLock()
    private var preflight: LiveOraclePreflightReadback?
    private var handshakes: [LiveProofSignedPayload] = []
    private var handshakePayloads: [LiveProofHandshakePayload] = []
    private var sessionPeerUIDDigests: [String] = []
    private var rejectedAttachCount = 0
    private var events: [LiveProofSignedEventEnvelope] = []
    private var eventPayloads: [LiveOracleObserverEventPayload] = []
    private var transportRecords: [LiveOracleProviderTransportRecord] = []
    private var receiptSets: [LiveOracleProviderReceiptSet] = []

    public init(
        runID: String,
        observer: LiveProofProcessIdentity,
        signer: LiveProofEphemeralSigner,
        redactionSalt: Data
    ) throws {
        guard LiveProofValidation.isCanonicalRunID(runID) else {
            throw LiveEvidenceError.invalidBinding("run ID is not canonical")
        }
        guard redactionSalt.count >= 32 else {
            throw LiveEvidenceError.invalidBinding("redaction salt is too short")
        }
        self.runID = runID
        self.observer = observer
        self.signer = signer
        self.redactionSalt = redactionSalt
        observerPublicKey = signer.publicKeyBase64URL
    }

    @discardableResult
    public func recordPreflight(_ input: LiveEvidencePreflightInput) throws
        -> LiveOraclePreflightReadback
    {
        try validatePreflightInput(input)
        let value = LiveOraclePreflightReadback(
            runID: runID,
            producer: observer,
            observerPublicKey: observerPublicKey,
            machineDigest: try digest(input.machineIdentity),
            baselineDigest: try digest(input.baselineBytes),
            appIdentityDigest: try digest(input.appIdentityBytes),
            helperIdentityDigest: try digest(input.helperIdentityBytes),
            priorSSIDDigest: try digest(input.priorSSID),
            targetSSIDDigest: try digest(input.targetSSID),
            providerOrigin: input.providerOrigin,
            providerPublicKey: input.providerPublicKey,
            outputDirectoryDigest: try digest(input.outputDirectoryPath),
            directoryMode: input.directoryMode,
            socketMode: input.socketMode,
            observerUIDDigest: try digest(input.observerUID),
            preflightPeerUIDDigest: try digest(input.preflightPeerUID),
            capability: input.capability
        )
        guard value.priorSSIDDigest != value.targetSSIDDigest,
              value.observerUIDDigest == value.preflightPeerUIDDigest else {
            throw LiveEvidenceError.invalidBinding("preflight identities are inconsistent")
        }
        lock.lock()
        defer { lock.unlock() }
        guard preflight == nil, handshakes.isEmpty, events.isEmpty else {
            throw LiveEvidenceError.invalidEvent("preflight readback was already recorded")
        }
        preflight = value
        return value
    }

    public func appendHandshake(
        _ payload: LiveProofHandshakePayload,
        peerUID: Data
    ) throws {
        let peerDigest = try digest(peerUID)
        lock.lock()
        defer { lock.unlock() }
        guard let preflight else {
            throw LiveEvidenceError.incompleteEvidence("preflight readback is missing")
        }
        guard handshakes.count < 2 else {
            throw LiveEvidenceError.invalidEvent("observer already has both sessions")
        }
        let expectedPhase: LiveProofHandshakePhase = handshakes.isEmpty ? .preflight : .live
        let expectedStart = handshakes.isEmpty
            ? 1
            : eventPayloads.prefix { $0.phase == .preflight }.count + 1
        guard payload.runID == runID, payload.phase == expectedPhase,
              payload.requestSequenceStart == expectedStart,
              peerDigest == preflight.observerUIDDigest else {
            throw LiveEvidenceError.invalidBinding("handshake does not match recorder binding")
        }
        if let first = handshakePayloads.first {
            guard payload.controllerSHA256 == first.controllerSHA256,
                  payload.client.pid != first.client.pid,
                  payload.client.startIdentity != first.client.startIdentity,
                  eventPayloads.contains(where: { $0.phase == .preflight }),
                  !eventPayloads.contains(where: { $0.phase == .live }) else {
                throw LiveEvidenceError.invalidBinding("live session is not distinct or ordered")
            }
        } else {
            guard eventPayloads.isEmpty else {
                throw LiveEvidenceError.invalidEvent("preflight session started too late")
            }
        }
        handshakes.append(try signer.signedHandshake(payload))
        handshakePayloads.append(payload)
        sessionPeerUIDDigests.append(peerDigest)
    }

    public func recordRejectedAttach() throws {
        lock.lock()
        defer { lock.unlock() }
        guard rejectedAttachCount < Self.maximumEvents else {
            throw LiveEvidenceError.capacityExceeded
        }
        rejectedAttachCount += 1
    }

    public func appendEvent(_ input: LiveEvidenceObserverEventInput) throws {
        let baselineDigest = try input.baselineBytes.map(digest)
        let snapshot = try input.observation.map(snapshot)
        try validateEventInput(input, baselineDigest: baselineDigest, snapshot: snapshot)

        lock.lock()
        defer { lock.unlock() }
        guard events.count < Self.maximumEvents else {
            throw LiveEvidenceError.capacityExceeded
        }
        guard input.requestSequence == events.count + 1 else {
            throw LiveEvidenceError.invalidEvent("observer request sequence is not contiguous")
        }
        let handshakePhases = handshakePayloads.map(\.phase)
        guard handshakePhases.contains(input.phase) else {
            throw LiveEvidenceError.invalidEvent("observer phase has no authenticated session")
        }
        if input.phase == .preflight {
            guard !handshakePhases.contains(.live) else {
                throw LiveEvidenceError.invalidEvent("preflight event followed the live handshake")
            }
        } else {
            guard handshakePhases == [.preflight, .live] else {
                throw LiveEvidenceError.invalidEvent("live event preceded the live handshake")
            }
        }
        if let previous = eventPayloads.last,
           input.monotonicNanoseconds < previous.monotonicNanoseconds {
            throw LiveEvidenceError.invalidEvent("monotonic time moved backwards")
        }
        let payload = LiveOracleObserverEventPayload(
            runID: runID,
            eventSequence: events.count + 1,
            requestSequence: input.requestSequence,
            phase: input.phase,
            unixMilliseconds: input.unixMilliseconds,
            monotonicNanoseconds: input.monotonicNanoseconds,
            scenario: input.scenario,
            kind: input.kind,
            baselineDigest: baselineDigest,
            snapshot: snapshot,
            process: input.process,
            failureCode: input.failureCode?.rawValue
        )
        let envelope = try signer.eventEnvelope(
            payload: LiveProofCanonicalJSON.encode(payload),
            previous: events.last
        )
        eventPayloads.append(payload)
        events.append(envelope)
    }

    public func appendProviderTransport(_ input: LiveEvidenceProviderTransportInput) throws {
        guard input.sequence > 0, input.dispatchUnixMilliseconds >= 0,
              input.completionUnixMilliseconds >= input.dispatchUnixMilliseconds,
              input.beforeObserverEventSequence > 0,
              input.afterObserverEventSequence > input.beforeObserverEventSequence,
              (try? LiveProofBase64URL.decode(input.nonce, exactByteCount: 32)) != nil else {
            throw LiveEvidenceError.invalidEvent("provider transport fields are invalid")
        }
        let record = LiveOracleProviderTransportRecord(
            scenario: input.scenario,
            sequence: input.sequence,
            nonce: input.nonce,
            dispatchUnixMilliseconds: input.dispatchUnixMilliseconds,
            completionUnixMilliseconds: input.completionUnixMilliseconds,
            localAddressDigest: try digest(input.localAddress),
            remoteAddressDigest: try digest(input.remoteAddress),
            beforeObserverEventSequence: input.beforeObserverEventSequence,
            afterObserverEventSequence: input.afterObserverEventSequence
        )
        lock.lock()
        defer { lock.unlock() }
        guard transportRecords.count < Self.maximumTransportRecords else {
            throw LiveEvidenceError.capacityExceeded
        }
        let scenarioRecords = transportRecords.filter { $0.scenario == input.scenario }
        guard input.sequence == scenarioRecords.count + 1,
              !transportRecords.contains(where: { $0.nonce == input.nonce }) else {
            throw LiveEvidenceError.invalidEvent("provider transport sequence is duplicated")
        }
        transportRecords.append(record)
    }

    public func recordProviderReceipts(
        scenario: ReadinessScenario,
        receipts: [LiveProofProviderReceipt]
    ) throws {
        guard !receipts.isEmpty, receipts.count <= Self.maximumReceipts else {
            throw LiveEvidenceError.invalidEvent("provider receipt count is invalid")
        }
        do {
            try LiveProofProviderReceipt.requireExactSequence(receipts)
        } catch {
            throw LiveEvidenceError.invalidEvent("provider receipt sequence is invalid")
        }
        guard receipts.allSatisfy({ $0.runID == runID && $0.scenario == scenario }) else {
            throw LiveEvidenceError.invalidBinding("provider receipts cross run or scenario")
        }
        lock.lock()
        defer { lock.unlock() }
        guard !receiptSets.contains(where: { $0.scenario == scenario }),
              receiptSets.reduce(0, { $0 + $1.receipts.count }) + receipts.count
                <= Self.maximumReceipts else {
            throw LiveEvidenceError.capacityExceeded
        }
        receiptSets.append(LiveOracleProviderReceiptSet(
            scenario: scenario,
            receipts: receipts
        ))
    }

    public func snapshotArtifacts() throws -> LiveEvidenceObserverArtifacts {
        lock.lock()
        defer { lock.unlock() }
        guard let preflight else {
            throw LiveEvidenceError.incompleteEvidence("preflight readback is missing")
        }
        return LiveEvidenceObserverArtifacts(
            preflight: preflight,
            transport: LiveOracleProviderTransportArtifact(
                runID: runID,
                producer: observer,
                records: transportRecords
            ),
            receipts: LiveOracleProviderReceiptsArtifact(
                runID: runID,
                producer: observer,
                receiptSets: receiptSets.sorted { $0.scenario.rawValue < $1.scenario.rawValue }
            ),
            events: LiveOracleObserverEventsArtifact(
                runID: runID,
                producer: observer,
                observerPublicKey: observerPublicKey,
                handshakes: handshakes,
                sessionPeerUIDDigests: sessionPeerUIDDigests,
                sessionCount: handshakes.count,
                rejectedAttachCount: rejectedAttachCount,
                events: events
            )
        )
    }

    func signedSeal(observerOwnedFiles: [LiveOracleManifestEntry]) throws
        -> LiveProofSignedPayload
    {
        lock.lock()
        defer { lock.unlock() }
        guard let finalEnvelope = events.last else {
            throw LiveEvidenceError.incompleteEvidence("observer has no signed events")
        }
        let payload = LiveOracleObserverSealPayload(
            runID: runID,
            observer: observer,
            observerPublicKey: observerPublicKey,
            eventCount: events.count,
            finalEnvelopeSHA256: try LiveProofEphemeralSigner.envelopeSHA256(finalEnvelope),
            observerOwnedFiles: observerOwnedFiles
        )
        return try signer.signedPayload(
            LiveProofCanonicalJSON.encode(payload),
            domain: .seal
        )
    }

    private func validatePreflightInput(_ input: LiveEvidencePreflightInput) throws {
        try [
            input.machineIdentity, input.baselineBytes, input.appIdentityBytes,
            input.helperIdentityBytes, input.priorSSID, input.targetSSID,
            input.outputDirectoryPath, input.observerUID, input.preflightPeerUID,
        ].forEach(Self.requireSensitiveValue)
        guard input.priorSSID != input.targetSSID,
              input.observerUID == input.preflightPeerUID,
              input.directoryMode == 0o700, input.socketMode == 0o600,
              Self.isProviderOrigin(input.providerOrigin),
              (try? LiveProofBase64URL.decode(
                  input.providerPublicKey,
                  exactByteCount: 32
              )) != nil else {
            throw LiveEvidenceError.invalidBinding("preflight readback is not authoritative")
        }
        let capability = input.capability
        guard capability.schema == LiveOracleProviderCapability.schema,
              capability.protocolName == LiveOracleProviderCapability.protocolName,
              capability.serverUnixMilliseconds >= 0,
              (0...30).contains(capability.maximumClockSkewSeconds),
              [capability.capabilityPath, capability.submitPath, capability.readbackPath]
                .allSatisfy(Self.isProviderPath) else {
            throw LiveEvidenceError.invalidBinding("provider capability is invalid")
        }
    }

    private func validateEventInput(
        _ input: LiveEvidenceObserverEventInput,
        baselineDigest: String?,
        snapshot: LiveOracleSystemSnapshot?
    ) throws {
        guard input.unixMilliseconds >= 0 else {
            throw LiveEvidenceError.invalidEvent("wall-clock time is negative")
        }
        let snapshotKinds: Set<LiveOracleObserverEventKind> = [
            .preflightSample, .scenarioBaseline, .closedBeforeTransport,
            .closedAfterTransport, .mandatoryCleanup, .ownerDeathHelperStage,
            .ownerDeathRelaunchedCleanup, .scenarioFinal,
        ]
        let failureKinds: Set<LiveOracleObserverEventKind> = [
            .unsafeAction, .observationFailure, .attachRejected,
        ]
        guard snapshotKinds.contains(input.kind) == (snapshot != nil),
              failureKinds.contains(input.kind) == (input.failureCode != nil) else {
            throw LiveEvidenceError.invalidEvent("observer event fact shape is invalid")
        }
        if input.kind == .preflightSample {
            guard input.phase == .preflight, input.scenario == nil else {
                throw LiveEvidenceError.invalidEvent("preflight sample has an invalid phase")
            }
        } else {
            guard input.phase == .live, input.scenario != nil else {
                throw LiveEvidenceError.invalidEvent("live event has an invalid phase")
            }
        }
        guard (input.kind == .scenarioBaseline) == (baselineDigest != nil),
              (input.kind == .processExit) == (input.process != nil) else {
            throw LiveEvidenceError.invalidEvent("observer event binding fields are invalid")
        }
    }

    private func snapshot(
        _ input: LiveEvidenceSystemObservation
    ) throws -> LiveOracleSystemSnapshot {
        guard (0...100).contains(input.batteryPercent),
              input.sleepDisabled >= 0 else {
            throw LiveEvidenceError.invalidEvent("system observation is out of range")
        }
        return LiveOracleSystemSnapshot(
            powerSource: input.powerSource,
            batteryPercent: input.batteryPercent,
            lidClosed: input.lidClosed,
            sleepDisabled: input.sleepDisabled,
            wifiPower: input.wifiPower,
            selectedWiFiDeviceDigest: try digest(input.selectedWiFiDevice),
            ssidDigest: try input.ssid.map(digest),
            usableAddressDigests: try input.usableAddresses.map(digest),
            routeRemoteAddressDigest: try input.routeRemoteAddress.map(digest),
            routeDeviceDigest: try input.routeDevice.map(digest),
            appRunning: input.appRunning,
            appJournal: input.appJournal,
            helperJournal: input.helperJournal,
            helperJournalAuthorizationCode: input.helperJournalAuthorizationCode,
            appIdentityDigest: try digest(input.appIdentityBytes),
            helperIdentityDigest: try digest(input.helperIdentityBytes)
        )
    }

    private func digest(_ value: Data) throws -> String {
        try Self.requireSensitiveValue(value)
        return ReadinessDigest.salted(value, salt: redactionSalt)
    }

    private static func requireSensitiveValue(_ value: Data) throws {
        guard !value.isEmpty, value.count <= 65_536 else {
            throw LiveEvidenceError.unsafeArtifact("sensitive input has an invalid size")
        }
    }

    private static func isProviderPath(_ value: String) -> Bool {
        value.hasPrefix("/") && !value.hasPrefix("//")
            && !value.contains("?") && !value.contains("#")
    }

    private static func isProviderOrigin(_ value: String) -> Bool {
        guard let components = URLComponents(string: value),
              components.scheme == "https", components.host != nil,
              components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil else {
            return false
        }
        return components.path.isEmpty || components.path == "/"
    }
}
