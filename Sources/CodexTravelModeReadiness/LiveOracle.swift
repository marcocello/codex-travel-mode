import Darwin
import Foundation

public enum LiveTravelModeOracle {
    public static let rawArtifactNames: Set<String> = [
        "preflight-readback.json",
        "arming-receipt.json",
        "command-events.json",
        "operator-events.json",
        "cleanup-events.json",
        "provider-transport-events.json",
        "provider-receipts.json",
        "observer-events.json",
        "observer-seal.json",
        "seal-manifest.json",
    ]

    @discardableResult
    public static func run(
        request: LiveOracleRequest,
        fileAccess: any LiveOracleFileAccess = POSIXLiveOracleFileAccess(),
        identityProvider: any LiveOracleIdentityProviding =
            POSIXLiveOracleIdentityProvider()
    ) throws -> LiveOracleReport {
        guard try identityProvider.currentIdentity() == request.oracle else {
            throw LiveOracleViolation("oracle_process_identity_mismatch")
        }
        let directory = try fileAccess.directoryMetadata(at: request.evidenceDirectory)
        guard !directory.isRegularFile, directory.mode == 0o700,
              directory.ownerUID == request.expectedOwnerUID else {
            throw LiveOracleViolation("unsafe_evidence_directory")
        }
        let before = try capture(request: request, fileAccess: fileAccess)
        let candidateRunID = decodeRunID(from: before.files["arming-receipt.json"]?.data)
        let issue: String?
        do {
            try LiveOracleValidator(request: request, snapshot: before).validate()
            issue = nil
        } catch let violation as LiveOracleViolation {
            issue = violation.code
        } catch {
            issue = "oracle_internal_validation_error"
        }
        let after = try capture(request: request, fileAccess: fileAccess)
        let stabilityIssue = before == after ? nil : "artifact_changed_during_evaluation"
        let issueCodes = [stabilityIssue ?? issue].compactMap { $0 }
        let report = LiveOracleReport(
            runID: candidateRunID,
            oracle: request.oracle,
            verdict: issueCodes.isEmpty ? .accept : .reject,
            issueCodes: issueCodes
        )
        let bytes = try LiveProofCanonicalJSON.encode(report)
        try fileAccess.writeOracleReport(bytes, in: request.evidenceDirectory)
        return report
    }

    private static func capture(
        request: LiveOracleRequest,
        fileAccess: any LiveOracleFileAccess
    ) throws -> LiveOracleSnapshot {
        let names = try fileAccess.names(in: request.evidenceDirectory)
        let permitted = rawArtifactNames.union(request.allowedAuxiliaryNames)
        guard names == permitted else {
            throw LiveOracleViolation("artifact_allowlist_mismatch")
        }
        var files: [String: LiveOracleSnapshotFile] = [:]
        for name in names.sorted() {
            let file = try fileAccess.read(name: name, in: request.evidenceDirectory)
            guard file.metadata.ownerUID == request.expectedOwnerUID,
                  file.metadata.isRegularFile else {
                throw LiveOracleViolation("unsafe_artifact_file")
            }
            if rawArtifactNames.contains(name), file.metadata.mode != 0o400 {
                throw LiveOracleViolation("raw_artifact_mode_invalid")
            }
            files[name] = LiveOracleSnapshotFile(
                data: file.data,
                metadata: file.metadata,
                sha256: ReadinessDigest.sha256Hex(file.data)
            )
        }
        return LiveOracleSnapshot(files: files)
    }

    private static func decodeRunID(from data: Data?) -> String? {
        guard let data,
              let receipt = try? LiveProofCanonicalJSON.decode(
                  LiveProofArmingReceipt.self,
                  from: data
              ),
              LiveProofValidation.isCanonicalRunID(receipt.binding.runID) else {
            return nil
        }
        return receipt.binding.runID
    }
}

private struct LiveOracleSnapshot: Equatable {
    let files: [String: LiveOracleSnapshotFile]
}

private struct LiveOracleSnapshotFile: Equatable {
    let data: Data
    let metadata: LiveOracleFileMetadata
    let sha256: String
}

private struct LiveOracleArtifacts {
    let receipt: LiveProofArmingReceipt
    let preflight: LiveOraclePreflightReadback
    let command: LiveOracleControllerArtifact
    let operatorEvents: LiveOracleControllerArtifact
    let cleanup: LiveOracleControllerArtifact
    let transport: LiveOracleProviderTransportArtifact
    let receipts: LiveOracleProviderReceiptsArtifact
    let observerEvents: LiveOracleObserverEventsArtifact
    let signedObserverSeal: LiveProofSignedPayload
    let manifest: LiveOracleSealManifest
}

private struct LiveOracleVerifiedObserver {
    let handshakes: [LiveProofHandshakePayload]
    let events: [LiveOracleObserverEventPayload]
    let seal: LiveOracleObserverSealPayload
}

private struct LiveOracleValidator {
    let request: LiveOracleRequest
    let snapshot: LiveOracleSnapshot

    func validate() throws {
        try scanRawEvidence()
        let artifacts = try decodeArtifacts()
        try validateArtifactSchemas(artifacts)
        let observer = try validateObserver(artifacts)
        try validateIdentities(artifacts, observer: observer)
        try validateManifest(artifacts, observer: observer)
        try validateProvider(artifacts, observer: observer)
        try validateScenarios(artifacts, observer: observer)
    }

    private func scanRawEvidence() throws {
        for name in LiveTravelModeOracle.rawArtifactNames {
            guard let data = snapshot.files[name]?.data else {
                throw LiveOracleViolation("required_artifact_missing")
            }
            for sentinel in request.forbiddenSentinels where !sentinel.isEmpty {
                if data.range(of: sentinel) != nil {
                    throw LiveOracleViolation("sensitive_sentinel_present")
                }
            }
            if name != "observer-seal.json" {
                try LiveOracleJSONScanner.scan(data)
            }
        }
    }

    private func decodeArtifacts() throws -> LiveOracleArtifacts {
        LiveOracleArtifacts(
            receipt: try decode("arming-receipt.json", as: LiveProofArmingReceipt.self),
            preflight: try decode("preflight-readback.json", as: LiveOraclePreflightReadback.self),
            command: try decode("command-events.json", as: LiveOracleControllerArtifact.self),
            operatorEvents: try decode(
                "operator-events.json",
                as: LiveOracleControllerArtifact.self
            ),
            cleanup: try decode("cleanup-events.json", as: LiveOracleControllerArtifact.self),
            transport: try decode(
                "provider-transport-events.json",
                as: LiveOracleProviderTransportArtifact.self
            ),
            receipts: try decode(
                "provider-receipts.json",
                as: LiveOracleProviderReceiptsArtifact.self
            ),
            observerEvents: try decode(
                "observer-events.json",
                as: LiveOracleObserverEventsArtifact.self
            ),
            signedObserverSeal: try decode(
                "observer-seal.json",
                as: LiveProofSignedPayload.self
            ),
            manifest: try decode("seal-manifest.json", as: LiveOracleSealManifest.self)
        )
    }

    private func decode<Value: Codable>(_ name: String, as type: Value.Type) throws -> Value {
        guard let data = snapshot.files[name]?.data else {
            throw LiveOracleViolation("required_artifact_missing")
        }
        do {
            let value = try LiveProofCanonicalJSON.decode(type, from: data)
            guard try LiveProofCanonicalJSON.encode(value) == data else {
                throw LiveOracleViolation("artifact_not_canonical")
            }
            return value
        } catch let violation as LiveOracleViolation {
            throw violation
        } catch {
            throw LiveOracleViolation("artifact_schema_invalid")
        }
    }

    private func validateArtifactSchemas(_ value: LiveOracleArtifacts) throws {
        let runID = value.receipt.binding.runID
        guard value.receipt.schema == LiveProofArmingReceipt.schema,
              LiveProofValidation.isCanonicalRunID(runID),
              LiveProofValidation.isSHA256Hex(value.receipt.challengeSHA256),
              value.receipt.issuedAtUnixMilliseconds >= 0,
              value.receipt.issuedAtUnixMilliseconds
                <= Int64.max - LiveProofArming.lifetimeMilliseconds,
              value.receipt.expiresAtUnixMilliseconds
                == value.receipt.issuedAtUnixMilliseconds
                    + LiveProofArming.lifetimeMilliseconds,
              (try? LiveProofBase64URL.decode(
                  value.receipt.authenticationCode,
                  exactByteCount: 32
              )) != nil,
              value.preflight.schema == LiveOraclePreflightReadback.schema,
              value.command.schema == "codex-travel-mode-command-events/v1",
              value.operatorEvents.schema == "codex-travel-mode-operator-events/v1",
              value.cleanup.schema == "codex-travel-mode-cleanup-events/v1",
              value.transport.schema == LiveOracleProviderTransportArtifact.schema,
              value.receipts.schema == LiveOracleProviderReceiptsArtifact.schema,
              value.observerEvents.schema == LiveOracleObserverEventsArtifact.schema,
              value.manifest.schema == LiveOracleSealManifest.schema else {
            throw LiveOracleViolation("artifact_schema_invalid")
        }
        guard let marker = snapshot.files[".arming-consumed"],
              marker.metadata.mode == 0o600,
              marker.data == Data(ReadinessDigest.sha256Hex(
                  try LiveProofCanonicalJSON.encode(value.receipt)
              ).utf8) else {
            throw LiveOracleViolation("arming_consumption_marker_invalid")
        }
        let runIDs = [
            value.preflight.runID, value.command.runID, value.operatorEvents.runID,
            value.cleanup.runID, value.transport.runID, value.receipts.runID,
            value.observerEvents.runID, value.manifest.runID,
        ]
        guard runIDs.allSatisfy({ $0 == runID }) else {
            throw LiveOracleViolation("run_identity_mismatch")
        }
        try validatePreflight(value.preflight, binding: value.receipt.binding)
        try validateControllerArtifact(value.command, category: .command)
        try validateControllerArtifact(value.operatorEvents, category: .operatorEvents)
        try validateControllerArtifact(value.cleanup, category: .cleanup)
    }

    private func validatePreflight(
        _ preflight: LiveOraclePreflightReadback,
        binding: LiveProofArmingBinding
    ) throws {
        guard let targetSSIDDigest = binding.targetSSIDDigest,
              let wifiDeviceDigest = binding.wifiDeviceDigest,
              preflight.producer == binding.observer,
              preflight.observerPublicKey == binding.observerPublicKey,
              preflight.machineDigest == binding.machineDigest,
              preflight.baselineDigest == binding.baselineDigest,
              preflight.appIdentityDigest == binding.appIdentityDigest,
              preflight.helperIdentityDigest == binding.helperIdentityDigest,
              preflight.providerOrigin == binding.providerOrigin,
              preflight.outputDirectoryDigest == binding.outputDirectoryDigest,
              preflight.targetSSIDDigest == targetSSIDDigest,
              LiveProofValidation.isSHA256Hex(wifiDeviceDigest),
              preflight.directoryMode == 0o700, preflight.socketMode == 0o600,
              preflight.observerUIDDigest == preflight.preflightPeerUIDDigest,
              preflight.priorSSIDDigest != preflight.targetSSIDDigest else {
            throw LiveOracleViolation("preflight_binding_mismatch")
        }
        let capability = preflight.capability
        guard capability.schema == LiveOracleProviderCapability.schema,
              capability.protocolName == LiveOracleProviderCapability.protocolName,
              (0...30).contains(capability.maximumClockSkewSeconds),
              capability.serverUnixMilliseconds >= 0,
              isProviderPath(capability.capabilityPath),
              isProviderPath(capability.submitPath),
              isProviderPath(capability.readbackPath),
              LiveProofValidation.isSHA256Hex(preflight.priorSSIDDigest),
              LiveProofValidation.isSHA256Hex(preflight.targetSSIDDigest),
              (try? LiveProofBase64URL.decode(
                  preflight.providerPublicKey,
                  exactByteCount: 32
              )) != nil else {
            throw LiveOracleViolation("provider_capability_invalid")
        }
    }

    private func validateControllerArtifact(
        _ artifact: LiveOracleControllerArtifact,
        category: LiveOracleControllerCategory
    ) throws {
        for (index, event) in artifact.events.enumerated() {
            guard event.sequence == index + 1, event.unixMilliseconds >= 0 else {
                throw LiveOracleViolation("controller_event_sequence_invalid")
            }
            guard category.permittedKinds.contains(event.kind) else {
                throw LiveOracleViolation("controller_event_role_invalid")
            }
        }
    }

    private func isProviderPath(_ value: String) -> Bool {
        value.hasPrefix("/") && !value.hasPrefix("//")
            && !value.contains("?") && !value.contains("#")
    }
}

private enum LiveOracleControllerCategory {
    case command
    case operatorEvents
    case cleanup

    var permittedKinds: Set<LiveOracleControllerEventKind> {
        switch self {
        case .command:
            [
                .heartbeatSubmitRequest, .heartbeatReadbackRequest, .appLaunchRequest,
                .ownerDeathSIGKILLRequest,
            ]
        case .operatorEvents:
            [.start, .lidClose, .lidOpen, .stopRestore, .quit, .relaunch]
        case .cleanup:
            [
                .cleanupEntered, .productionStopRequested, .productionQuitRequested,
                .startupRecoveryRequested, .helperOwnerDeathWait,
                .safetyTerminateRequested, .directRescueRequested,
            ]
        }
    }
}

private enum LiveOracleJSONScanner {
    private static let forbiddenTokens: Set<String> = [
        "pass", "passed", "passing", "verdict", "check", "checks", "assertion",
        "assertions", "expected", "expectation", "expectations", "match", "matches",
        "success", "successful", "accepted", "acceptance", "compliant", "valid",
        "validity", "outcome", "result", "results",
    ]

    static func scan(_ data: Data) throws {
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw LiveOracleViolation("artifact_schema_invalid")
        }
        try visit(object)
    }

    private static func visit(_ value: Any) throws {
        if let dictionary = value as? [String: Any] {
            for (key, child) in dictionary {
                let tokens = key.lowercased().split { !$0.isLetter && !$0.isNumber }
                if tokens.contains(where: { forbiddenTokens.contains(String($0)) }) {
                    throw LiveOracleViolation("derived_success_key_present")
                }
                try visit(child)
            }
        } else if let array = value as? [Any] {
            for child in array { try visit(child) }
        } else if let string = value as? String {
            let lowered = string.lowercased()
            if lowered.contains("/users/") || lowered.contains("/home/")
                || lowered.contains("/applications/")
                || lowered.contains("/library/application support/")
                || lowered.contains("/private/") || lowered.contains("/volumes/")
                || lowered.contains("file://") || lowered.contains("bearer ")
                || lowered.contains("authorization:") || lowered.contains("password=") {
                throw LiveOracleViolation("unredacted_sensitive_value")
            }
        }
    }
}

private extension LiveOracleValidator {
    func validateObserver(_ value: LiveOracleArtifacts) throws -> LiveOracleVerifiedObserver {
        let key = value.preflight.observerPublicKey
        guard value.observerEvents.producer == value.preflight.producer,
              value.observerEvents.observerPublicKey == key,
              value.observerEvents.handshakes.count == 2,
              value.observerEvents.sessionCount == 2,
              value.observerEvents.rejectedAttachCount == 0,
              value.observerEvents.sessionPeerUIDDigests
                == [value.preflight.observerUIDDigest, value.preflight.observerUIDDigest],
              !value.observerEvents.events.isEmpty else {
            throw LiveOracleViolation("observer_identity_mismatch")
        }
        let handshakes = try value.observerEvents.handshakes.map {
            try verifiedHandshake($0, publicKey: key)
        }
        let events = try verifiedEvents(value.observerEvents.events, publicKey: key)
        guard events.allSatisfy({ $0.runID == value.receipt.binding.runID }) else {
            throw LiveOracleViolation("run_identity_mismatch")
        }
        try validateHandshakeSequence(handshakes, events: events)
        let seal = try verifiedSeal(value.signedObserverSeal, publicKey: key)
        guard let lastEnvelope = value.observerEvents.events.last else {
            throw LiveOracleViolation("observer_event_sequence_invalid")
        }
        guard seal.runID == value.receipt.binding.runID,
              seal.observer == value.preflight.producer,
              seal.observerPublicKey == key,
              seal.eventCount == events.count,
              seal.finalEnvelopeSHA256
                == (try LiveProofEphemeralSigner.envelopeSHA256(lastEnvelope)) else {
            throw LiveOracleViolation("observer_seal_mismatch")
        }
        return LiveOracleVerifiedObserver(handshakes: handshakes, events: events, seal: seal)
    }

    func verifiedHandshake(
        _ signed: LiveProofSignedPayload,
        publicKey: String
    ) throws -> LiveProofHandshakePayload {
        do {
            let bytes = try LiveProofSignatureVerifier.verify(
                signed,
                domain: .handshake,
                publicKeyBase64URL: publicKey
            )
            try scanSignedPayload(bytes)
            let payload = try LiveProofCanonicalJSON.decode(
                LiveProofHandshakePayload.self,
                from: bytes
            )
            guard try LiveProofCanonicalJSON.encode(payload) == bytes,
                  payload.schema == LiveProofHandshakePayload.schema else {
                throw LiveOracleViolation("observer_handshake_invalid")
            }
            return payload
        } catch let violation as LiveOracleViolation {
            throw violation
        } catch {
            throw LiveOracleViolation("observer_handshake_invalid")
        }
    }

    func verifiedEvents(
        _ envelopes: [LiveProofSignedEventEnvelope],
        publicKey: String
    ) throws -> [LiveOracleObserverEventPayload] {
        var previous: LiveProofSignedEventEnvelope?
        var payloads: [LiveOracleObserverEventPayload] = []
        for (index, envelope) in envelopes.enumerated() {
            let bytes: Data
            do {
                bytes = try LiveProofSignatureVerifier.verifyEventEnvelope(
                    envelope,
                    previous: previous,
                    publicKeyBase64URL: publicKey
                )
            } catch {
                throw LiveOracleViolation("observer_event_authentication_failed")
            }
            try scanSignedPayload(bytes)
            let payload: LiveOracleObserverEventPayload
            do {
                payload = try LiveProofCanonicalJSON.decode(
                    LiveOracleObserverEventPayload.self,
                    from: bytes
                )
            } catch {
                throw LiveOracleViolation("observer_event_schema_invalid")
            }
            guard try LiveProofCanonicalJSON.encode(payload) == bytes,
                  payload.schema == LiveOracleObserverEventPayload.schema,
                  payload.eventSequence == index + 1,
                  payload.requestSequence == index + 1,
                  payload.unixMilliseconds >= 0 else {
                throw LiveOracleViolation("observer_event_sequence_invalid")
            }
            if let last = payloads.last,
               payload.monotonicNanoseconds < last.monotonicNanoseconds {
                throw LiveOracleViolation("observer_event_time_invalid")
            }
            try validateObserverEventShape(payload)
            payloads.append(payload)
            previous = envelope
        }
        return payloads
    }

    func validateObserverEventShape(_ event: LiveOracleObserverEventPayload) throws {
        let snapshotKinds: Set<LiveOracleObserverEventKind> = [
            .preflightSample, .scenarioBaseline, .closedBeforeTransport,
            .closedAfterTransport, .mandatoryCleanup, .ownerDeathHelperStage,
            .ownerDeathRelaunchedCleanup, .scenarioFinal,
        ]
        if snapshotKinds.contains(event.kind), event.snapshot == nil {
            throw LiveOracleViolation("observer_event_fact_missing")
        }
        if event.kind == .preflightSample {
            guard event.phase == .preflight, event.scenario == nil else {
                throw LiveOracleViolation("observer_event_phase_invalid")
            }
        } else {
            guard event.phase == .live, event.scenario != nil else {
                throw LiveOracleViolation("observer_event_phase_invalid")
            }
        }
        if [.unsafeAction, .observationFailure, .attachRejected].contains(event.kind) {
            guard event.failureCode != nil else {
                throw LiveOracleViolation("observer_failure_fact_invalid")
            }
        } else if event.failureCode != nil {
            throw LiveOracleViolation("observer_failure_fact_invalid")
        }
    }

    func validateHandshakeSequence(
        _ handshakes: [LiveProofHandshakePayload],
        events: [LiveOracleObserverEventPayload]
    ) throws {
        let preflight = handshakes[0]
        let live = handshakes[1]
        let firstLive = events.first { $0.phase == .live }
        let preflightCount = events.prefix { $0.phase == .preflight }.count
        guard preflight.phase == .preflight, live.phase == .live,
              preflight.runID == live.runID,
              preflight.controllerSHA256 == live.controllerSHA256,
              preflight.requestSequenceStart == 1,
              live.requestSequenceStart == preflightCount + 1,
              firstLive?.requestSequence == live.requestSequenceStart,
              preflightCount > 0,
              preflight.client.pid != live.client.pid,
              preflight.client.startIdentity != live.client.startIdentity,
              events.dropFirst(preflightCount).allSatisfy({ $0.phase == .live }) else {
            throw LiveOracleViolation("observer_session_sequence_invalid")
        }
    }

    func verifiedSeal(
        _ signed: LiveProofSignedPayload,
        publicKey: String
    ) throws -> LiveOracleObserverSealPayload {
        do {
            let bytes = try LiveProofSignatureVerifier.verify(
                signed,
                domain: .seal,
                publicKeyBase64URL: publicKey
            )
            try scanSignedPayload(bytes)
            let payload = try LiveProofCanonicalJSON.decode(
                LiveOracleObserverSealPayload.self,
                from: bytes
            )
            guard try LiveProofCanonicalJSON.encode(payload) == bytes,
                  payload.schema == LiveOracleObserverSealPayload.schema else {
                throw LiveOracleViolation("observer_seal_invalid")
            }
            return payload
        } catch let violation as LiveOracleViolation {
            throw violation
        } catch {
            throw LiveOracleViolation("observer_seal_invalid")
        }
    }

    func scanSignedPayload(_ bytes: Data) throws {
        for sentinel in request.forbiddenSentinels where !sentinel.isEmpty {
            if bytes.range(of: sentinel) != nil {
                throw LiveOracleViolation("sensitive_sentinel_present")
            }
        }
        try LiveOracleJSONScanner.scan(bytes)
    }

    func validateIdentities(
        _ value: LiveOracleArtifacts,
        observer: LiveOracleVerifiedObserver
    ) throws {
        let preflightController = observer.handshakes[0].client
        let liveController = observer.handshakes[1].client
        let observerIdentity = value.preflight.producer
        let oracle = request.oracle
        let identities = [preflightController, liveController, observerIdentity, oracle]
        guard Set(identities.map(\.pid)).count == identities.count,
              preflightController.executableSHA256 == liveController.executableSHA256,
              preflightController.executableSHA256
                == value.receipt.binding.controllerSHA256,
              observerIdentity.executableSHA256
                != preflightController.executableSHA256,
              oracle.executableSHA256 != preflightController.executableSHA256,
              oracle.executableSHA256 != observerIdentity.executableSHA256,
              value.command.producer == liveController,
              value.operatorEvents.producer == liveController,
              value.cleanup.producer == liveController,
              value.transport.producer == observerIdentity,
              value.receipts.producer == observerIdentity else {
            throw LiveOracleViolation("role_identity_not_distinct")
        }
    }
}

private extension LiveOracleValidator {
    func validateProvider(
        _ value: LiveOracleArtifacts,
        observer: LiveOracleVerifiedObserver
    ) throws {
        let scenarios = Set(ReadinessScenario.allCases)
        let grouped = Dictionary(grouping: value.transport.records, by: \.scenario)
        let receiptSets = Dictionary(
            uniqueKeysWithValues: try uniqueReceiptSets(value.receipts.receiptSets)
        )
        let maximumOffset = Int64(
            value.preflight.capability.maximumClockSkewSeconds * 1_000
        )
        guard Set(grouped.keys) == scenarios, Set(receiptSets.keys) == scenarios,
              value.preflight.capability.clockOffsetMilliseconds >= -maximumOffset,
              value.preflight.capability.clockOffsetMilliseconds <= maximumOffset else {
            throw LiveOracleViolation("provider_scenario_set_invalid")
        }
        let eventBySequence = Dictionary(uniqueKeysWithValues: observer.events.map {
            ($0.eventSequence, $0)
        })
        var allNonces = Set<String>()
        for scenario in ReadinessScenario.allCases {
            let records = grouped[scenario]!.sorted { $0.sequence < $1.sequence }
            let receipts = receiptSets[scenario]!
            try validateTransportSequence(
                records,
                receipts: receipts,
                scenario: scenario,
                preflight: value.preflight,
                eventBySequence: eventBySequence,
                allNonces: &allNonces
            )
        }
        try validateSubmitRequests(value.command, records: value.transport.records)
    }

    func uniqueReceiptSets(
        _ sets: [LiveOracleProviderReceiptSet]
    ) throws -> [(ReadinessScenario, [LiveProofProviderReceipt])] {
        guard Set(sets.map(\.scenario)).count == sets.count else {
            throw LiveOracleViolation("provider_receipt_set_duplicate")
        }
        return sets.map { ($0.scenario, $0.receipts) }
    }

    func validateTransportSequence(
        _ records: [LiveOracleProviderTransportRecord],
        receipts: [LiveProofProviderReceipt],
        scenario: ReadinessScenario,
        preflight: LiveOraclePreflightReadback,
        eventBySequence: [Int: LiveOracleObserverEventPayload],
        allNonces: inout Set<String>
    ) throws {
        guard records.count >= 3, receipts.count == records.count else {
            throw LiveOracleViolation("provider_receipt_count_invalid")
        }
        let expectedNonces = records.map(\.nonce)
        do {
            try LiveProofProviderReceipt.requireExactSequence(
                receipts,
                runID: preflight.runID,
                scenario: scenario,
                expectedNonces: expectedNonces
            )
        } catch {
            throw LiveOracleViolation("provider_receipt_sequence_invalid")
        }
        for (index, pair) in zip(records, receipts).enumerated() {
            let record = pair.0
            let receipt = pair.1
            guard record.sequence == index + 1,
                  record.scenario == scenario,
                  allNonces.insert(record.nonce).inserted,
                  (try? LiveProofBase64URL.decode(
                      record.nonce,
                      exactByteCount: 32
                  )) != nil else {
                throw LiveOracleViolation("provider_transport_sequence_invalid")
            }
            try validateTransportRecord(
                record,
                receipt: receipt,
                preflight: preflight,
                eventBySequence: eventBySequence
            )
        }
        guard let first = receipts.first, let last = receipts.last,
              last.serverReceiveUnixMilliseconds
                - first.serverReceiveUnixMilliseconds >= 10_000,
              let firstRecord = records.first, let lastRecord = records.last,
              let firstEvent = eventBySequence[firstRecord.beforeObserverEventSequence],
              let lastEvent = eventBySequence[lastRecord.afterObserverEventSequence],
              lastEvent.unixMilliseconds - firstEvent.unixMilliseconds <= 90_000 else {
            throw LiveOracleViolation("provider_closed_window_invalid")
        }
    }

    func validateTransportRecord(
        _ record: LiveOracleProviderTransportRecord,
        receipt: LiveProofProviderReceipt,
        preflight: LiveOraclePreflightReadback,
        eventBySequence: [Int: LiveOracleObserverEventPayload]
    ) throws {
        guard let before = eventBySequence[record.beforeObserverEventSequence],
              let after = eventBySequence[record.afterObserverEventSequence],
              before.kind == .closedBeforeTransport,
              after.kind == .closedAfterTransport,
              before.scenario == record.scenario, after.scenario == record.scenario,
              before.unixMilliseconds <= record.dispatchUnixMilliseconds,
              record.dispatchUnixMilliseconds - before.unixMilliseconds <= 2_000,
              after.unixMilliseconds >= record.completionUnixMilliseconds,
              after.unixMilliseconds - record.completionUnixMilliseconds <= 2_000,
              record.completionUnixMilliseconds >= record.dispatchUnixMilliseconds,
              record.completionUnixMilliseconds - record.dispatchUnixMilliseconds <= 5_000,
              let beforeSnapshot = before.snapshot, let afterSnapshot = after.snapshot else {
            throw LiveOracleViolation("provider_transport_adjacency_invalid")
        }
        try validateClosedSnapshot(
            beforeSnapshot,
            transport: record,
            preflight: preflight
        )
        try validateClosedSnapshot(
            afterSnapshot,
            transport: record,
            preflight: preflight
        )
        let lower = before.unixMilliseconds + preflight.capability.clockOffsetMilliseconds
        let upper = after.unixMilliseconds + preflight.capability.clockOffsetMilliseconds
        guard receipt.runID == preflight.runID, receipt.scenario == record.scenario,
              receipt.sequence == record.sequence, receipt.nonce == record.nonce,
              receipt.serverReceiveUnixMilliseconds >= lower,
              receipt.serverReceiveUnixMilliseconds <= upper,
              (try? LiveProofBase64URL.decode(
                  receipt.nonce,
                  exactByteCount: 32
              )) != nil,
              (try? LiveProofBase64URL.decode(
                  receipt.sourceAddress,
                  exactByteCount: receipt.sourceFamily == .ipv4 ? 4 : 16
              )) != nil else {
            throw LiveOracleViolation("provider_receipt_binding_invalid")
        }
        do {
            try receipt.verify(publicKeyBase64URL: preflight.providerPublicKey)
        } catch {
            throw LiveOracleViolation("provider_receipt_signature_invalid")
        }
    }

    func validateClosedSnapshot(
        _ snapshot: LiveOracleSystemSnapshot,
        transport: LiveOracleProviderTransportRecord,
        preflight: LiveOraclePreflightReadback
    ) throws {
        guard snapshot.powerSource == .battery, snapshot.lidClosed,
              snapshot.ssidDigest == preflight.targetSSIDDigest,
              snapshot.usableAddressDigests.contains(transport.localAddressDigest),
              snapshot.routeRemoteAddressDigest == transport.remoteAddressDigest,
              snapshot.routeDeviceDigest == snapshot.selectedWiFiDeviceDigest,
              snapshot.helperJournalAuthorizationCode == 0,
              snapshot.appIdentityDigest == preflight.appIdentityDigest,
              snapshot.helperIdentityDigest == preflight.helperIdentityDigest,
              LiveProofValidation.isSHA256Hex(transport.localAddressDigest),
              LiveProofValidation.isSHA256Hex(transport.remoteAddressDigest) else {
            throw LiveOracleViolation("closed_network_snapshot_invalid")
        }
    }

    func validateSubmitRequests(
        _ command: LiveOracleControllerArtifact,
        records: [LiveOracleProviderTransportRecord]
    ) throws {
        let submitEvents = command.events.filter { $0.kind == .heartbeatSubmitRequest }
        guard submitEvents.count == records.count else {
            throw LiveOracleViolation("typed_submit_request_mismatch")
        }
        let expected = Set(records.map {
            "\($0.scenario.rawValue):\($0.sequence):\($0.nonce)"
        })
        let observed = Set(submitEvents.compactMap { event -> String? in
            guard let scenario = event.scenario, let sequence = event.heartbeatSequence,
                  let nonce = event.nonce else { return nil }
            return "\(scenario.rawValue):\(sequence):\(nonce)"
        })
        guard expected == observed else {
            throw LiveOracleViolation("typed_submit_request_mismatch")
        }
        let readbacks = command.events.filter { $0.kind == .heartbeatReadbackRequest }
        guard Set(readbacks.compactMap(\.scenario)) == Set(ReadinessScenario.allCases) else {
            throw LiveOracleViolation("typed_readback_request_missing")
        }
    }
}

private extension LiveOracleValidator {
    func validateScenarios(
        _ value: LiveOracleArtifacts,
        observer: LiveOracleVerifiedObserver
    ) throws {
        if observer.events.contains(where: {
            [.unsafeAction, .observationFailure, .attachRejected].contains($0.kind)
        }) {
            throw LiveOracleViolation("observer_recorded_nonpass_condition")
        }
        if value.cleanup.events.contains(where: {
            [.safetyTerminateRequested, .directRescueRequested].contains($0.kind)
        }) {
            throw LiveOracleViolation("safety_rescue_used")
        }
        guard value.cleanup.events.isEmpty else {
            throw LiveOracleViolation("failure_cleanup_used")
        }
        guard let wifiDeviceDigest = value.receipt.binding.wifiDeviceDigest,
              observer.events.allSatisfy({ event in
                  guard let snapshot = event.snapshot else { return true }
                  return snapshot.selectedWiFiDeviceDigest == wifiDeviceDigest
              }) else {
            throw LiveOracleViolation("authoritative_wifi_device_mismatch")
        }
        let preflightEvents = observer.events.filter { $0.kind == .preflightSample }
        guard preflightEvents.count == 1, let preflightSnapshot = preflightEvents[0].snapshot else {
            throw LiveOracleViolation("preflight_sample_missing")
        }
        try validatePreflightSnapshot(preflightSnapshot, preflight: value.preflight)
        let scenarioEvents = Dictionary(
            grouping: observer.events.compactMap { event in
                event.scenario.map { ($0, event) }
            },
            by: { $0.0 }
        ).mapValues { $0.map(\.1) }
        guard Set(scenarioEvents.keys) == Set(ReadinessScenario.allCases) else {
            throw LiveOracleViolation("scenario_observation_set_invalid")
        }
        for scenario in ReadinessScenario.allCases {
            let events = scenarioEvents[scenario]!
            try validateScenarioCommon(
                scenario,
                events: events,
                preflight: value.preflight,
                operatorEvents: value.operatorEvents,
                command: value.command
            )
            switch scenario {
            case .stop:
                try validateStop(
                    events,
                    preflight: value.preflight,
                    operatorEvents: value.operatorEvents
                )
            case .quit:
                try validateQuit(
                    events,
                    preflight: value.preflight,
                    operatorEvents: value.operatorEvents
                )
            case .ownerDeath:
                try validateOwnerDeath(
                    events,
                    preflight: value.preflight,
                    operatorEvents: value.operatorEvents,
                    command: value.command
                )
            }
        }
    }

    func validatePreflightSnapshot(
        _ snapshot: LiveOracleSystemSnapshot,
        preflight: LiveOraclePreflightReadback
    ) throws {
        guard snapshot.powerSource == .battery, snapshot.batteryPercent >= 20,
              !snapshot.lidClosed, !snapshot.appRunning,
              snapshot.ssidDigest == preflight.priorSSIDDigest,
              snapshot.appJournal == .absent, snapshot.helperJournal == .absent,
              snapshot.helperJournalAuthorizationCode == 0,
              snapshot.appIdentityDigest == preflight.appIdentityDigest,
              snapshot.helperIdentityDigest == preflight.helperIdentityDigest else {
            throw LiveOracleViolation("preflight_sample_invalid")
        }
    }

    func validateScenarioCommon(
        _ scenario: ReadinessScenario,
        events: [LiveOracleObserverEventPayload],
        preflight: LiveOraclePreflightReadback,
        operatorEvents: LiveOracleControllerArtifact,
        command: LiveOracleControllerArtifact
    ) throws {
        let baselines = events.filter { $0.kind == .scenarioBaseline }
        let finals = events.filter { $0.kind == .scenarioFinal }
        guard baselines.count == 1, finals.count == 1,
              let baseline = baselines[0].snapshot, let final = finals[0].snapshot,
              baselines[0].baselineDigest == preflight.baselineDigest,
              baselines[0].eventSequence < finals[0].eventSequence else {
            throw LiveOracleViolation("scenario_boundary_invalid")
        }
        try validateBaselineSnapshot(baseline, preflight: preflight)
        try validateMandatoryRestoration(final, baseline: baseline, preflight: preflight)
        guard !final.appRunning else {
            throw LiveOracleViolation("scenario_final_process_present")
        }
        guard final.ssidDigest == preflight.priorSSIDDigest else {
            throw LiveOracleViolation("prior_ssid_mismatch")
        }
        for event in events {
            if let snapshot = event.snapshot {
                guard snapshot.powerSource == .battery,
                      snapshot.helperJournalAuthorizationCode == 0,
                      snapshot.appIdentityDigest == preflight.appIdentityDigest,
                      snapshot.helperIdentityDigest == preflight.helperIdentityDigest else {
                    throw LiveOracleViolation("authoritative_sample_invalid")
                }
            }
        }
        let launches = command.events.filter {
            $0.scenario == scenario && $0.kind == .appLaunchRequest
        }
        guard launches.count == 1 else {
            throw LiveOracleViolation("fresh_app_launch_request_missing")
        }
        try validateOperatorSequence(for: scenario, artifact: operatorEvents)
    }

    func validateBaselineSnapshot(
        _ snapshot: LiveOracleSystemSnapshot,
        preflight: LiveOraclePreflightReadback
    ) throws {
        guard snapshot.powerSource == .battery, !snapshot.lidClosed,
              !snapshot.appRunning, snapshot.ssidDigest == preflight.priorSSIDDigest,
              snapshot.appJournal == .absent, snapshot.helperJournal == .absent,
              snapshot.helperJournalAuthorizationCode == 0 else {
            throw LiveOracleViolation("scenario_baseline_invalid")
        }
    }

    func validateMandatoryRestoration(
        _ snapshot: LiveOracleSystemSnapshot,
        baseline: LiveOracleSystemSnapshot,
        preflight: LiveOraclePreflightReadback
    ) throws {
        guard snapshot.powerSource == .battery,
              snapshot.sleepDisabled == baseline.sleepDisabled,
              snapshot.wifiPower == baseline.wifiPower,
              snapshot.appJournal == .absent,
              snapshot.helperJournal == .absent,
              snapshot.helperJournalAuthorizationCode == 0,
              snapshot.appIdentityDigest == preflight.appIdentityDigest,
              snapshot.helperIdentityDigest == preflight.helperIdentityDigest else {
            throw LiveOracleViolation("mandatory_cleanup_failed")
        }
    }

    func validateStop(
        _ events: [LiveOracleObserverEventPayload],
        preflight: LiveOraclePreflightReadback,
        operatorEvents: LiveOracleControllerArtifact
    ) throws {
        let baseline = events.first { $0.kind == .scenarioBaseline }!.snapshot!
        let cleanup = try soleEvent(.mandatoryCleanup, in: events)
        let final = try soleEvent(.scenarioFinal, in: events)
        guard let snapshot = cleanup.snapshot,
              cleanup.eventSequence < final.eventSequence else {
            throw LiveOracleViolation("stop_cleanup_order_invalid")
        }
        try validateMandatoryRestoration(snapshot, baseline: baseline, preflight: preflight)
        let stop = try soleControllerEvent(.stopRestore, scenario: .stop, in: operatorEvents)
        let quit = try soleControllerEvent(.quit, scenario: .stop, in: operatorEvents)
        guard stop.monotonicNanoseconds <= cleanup.monotonicNanoseconds,
              cleanup.monotonicNanoseconds <= quit.monotonicNanoseconds else {
            throw LiveOracleViolation("stop_cleanup_order_invalid")
        }
    }

    func validateQuit(
        _ events: [LiveOracleObserverEventPayload],
        preflight: LiveOraclePreflightReadback,
        operatorEvents: LiveOracleControllerArtifact
    ) throws {
        let baseline = events.first { $0.kind == .scenarioBaseline }!.snapshot!
        let cleanup = try soleEvent(.mandatoryCleanup, in: events)
        let exit = try soleEvent(.processExit, in: events)
        let final = try soleEvent(.scenarioFinal, in: events)
        guard let snapshot = cleanup.snapshot, exit.process != nil,
              cleanup.eventSequence < exit.eventSequence,
              exit.eventSequence <= final.eventSequence else {
            throw LiveOracleViolation("quit_cleanup_order_invalid")
        }
        try validateMandatoryRestoration(snapshot, baseline: baseline, preflight: preflight)
        let quit = try soleControllerEvent(.quit, scenario: .quit, in: operatorEvents)
        guard quit.monotonicNanoseconds <= cleanup.monotonicNanoseconds else {
            throw LiveOracleViolation("quit_cleanup_order_invalid")
        }
    }

    func validateOwnerDeath(
        _ events: [LiveOracleObserverEventPayload],
        preflight: LiveOraclePreflightReadback,
        operatorEvents: LiveOracleControllerArtifact,
        command: LiveOracleControllerArtifact
    ) throws {
        let baseline = events.first { $0.kind == .scenarioBaseline }!.snapshot!
        let exit = try soleEvent(.processExit, in: events)
        let helper = try soleEvent(.ownerDeathHelperStage, in: events)
        let recovered = try soleEvent(.ownerDeathRelaunchedCleanup, in: events)
        let final = try soleEvent(.scenarioFinal, in: events)
        guard let exitedProcess = exit.process, let helperSnapshot = helper.snapshot,
              let recoveredSnapshot = recovered.snapshot,
              exit.eventSequence < helper.eventSequence,
              helper.eventSequence < recovered.eventSequence,
              recovered.eventSequence < final.eventSequence,
              !helperSnapshot.appRunning,
              helperSnapshot.sleepDisabled == baseline.sleepDisabled,
              helperSnapshot.helperJournal == .absent,
              helperSnapshot.appJournal == .present else {
            throw LiveOracleViolation("owner_death_stage_invalid")
        }
        try validateMandatoryRestoration(
            recoveredSnapshot,
            baseline: baseline,
            preflight: preflight
        )
        guard recoveredSnapshot.ssidDigest == preflight.priorSSIDDigest else {
            throw LiveOracleViolation("prior_ssid_mismatch")
        }
        let kills = command.events.filter {
            $0.scenario == .ownerDeath && $0.kind == .ownerDeathSIGKILLRequest
        }
        guard kills.count == 1, kills[0].signal == SIGKILL,
              kills[0].process == exitedProcess,
              kills[0].monotonicNanoseconds <= exit.monotonicNanoseconds else {
            throw LiveOracleViolation("owner_death_process_identity_invalid")
        }
        let relaunch = try soleControllerEvent(
            .relaunch,
            scenario: .ownerDeath,
            in: operatorEvents
        )
        guard relaunch.monotonicNanoseconds <= recovered.monotonicNanoseconds else {
            throw LiveOracleViolation("owner_death_recovery_order_invalid")
        }
    }

    func soleEvent(
        _ kind: LiveOracleObserverEventKind,
        in events: [LiveOracleObserverEventPayload]
    ) throws -> LiveOracleObserverEventPayload {
        let selected = events.filter { $0.kind == kind }
        guard selected.count == 1 else {
            throw LiveOracleViolation("scenario_required_event_invalid")
        }
        return selected[0]
    }

    func soleControllerEvent(
        _ kind: LiveOracleControllerEventKind,
        scenario: ReadinessScenario,
        in artifact: LiveOracleControllerArtifact
    ) throws -> LiveOracleControllerEvent {
        let selected = artifact.events.filter {
            $0.kind == kind && $0.scenario == scenario
        }
        guard selected.count == 1 else {
            throw LiveOracleViolation("operator_action_sequence_invalid")
        }
        return selected[0]
    }

    func validateOperatorSequence(
        for scenario: ReadinessScenario,
        artifact: LiveOracleControllerArtifact
    ) throws {
        let required: [LiveOracleControllerEventKind]
        switch scenario {
        case .stop: required = [.start, .lidClose, .lidOpen, .stopRestore, .quit]
        case .quit: required = [.start, .lidClose, .lidOpen, .quit]
        case .ownerDeath: required = [.start, .lidClose, .lidOpen, .relaunch, .quit]
        }
        let selected = artifact.events.filter { $0.scenario == scenario }
        guard selected.map(\.kind) == required else {
            throw LiveOracleViolation("operator_action_sequence_invalid")
        }
    }
}

private extension LiveOracleValidator {
    func validateManifest(
        _ value: LiveOracleArtifacts,
        observer: LiveOracleVerifiedObserver
    ) throws {
        let expectedNames = LiveTravelModeOracle.rawArtifactNames
            .subtracting(["seal-manifest.json"])
        guard value.manifest.entries.map(\.name)
            == value.manifest.entries.map(\.name).sorted(),
              Set(value.manifest.entries.map(\.name)).count == value.manifest.entries.count,
              Set(value.manifest.entries.map(\.name)) == expectedNames,
              value.manifest.author == observer.handshakes[1].client else {
            throw LiveOracleViolation("seal_manifest_shape_invalid")
        }
        let byName = Dictionary(uniqueKeysWithValues: value.manifest.entries.map {
            ($0.name, $0)
        })
        for name in expectedNames {
            guard let entry = byName[name],
                  let file = snapshot.files[name],
                  entry.byteCount == file.metadata.byteCount,
                  entry.mode == file.metadata.mode,
                  entry.mode == 0o400,
                  entry.sha256 == file.sha256,
                  LiveProofValidation.isSHA256Hex(entry.sha256),
                  entry.role == expectedRole(for: name),
                  entry.author == expectedAuthor(
                      for: name,
                      artifacts: value,
                      observer: observer
                  ) else {
                throw LiveOracleViolation("seal_manifest_entry_mismatch")
            }
        }
        let observerNames: Set<String> = [
            "preflight-readback.json", "provider-transport-events.json",
            "provider-receipts.json", "observer-events.json",
        ]
        let sortedObserverFiles = observer.seal.observerOwnedFiles.sorted {
            $0.name < $1.name
        }
        guard Set(observer.seal.observerOwnedFiles.map(\.name)) == observerNames,
              observer.seal.observerOwnedFiles == sortedObserverFiles else {
            throw LiveOracleViolation("observer_seal_file_set_invalid")
        }
        for sealed in observer.seal.observerOwnedFiles {
            guard sealed == byName[sealed.name], sealed.role == .observer,
                  sealed.author == value.preflight.producer else {
                throw LiveOracleViolation("observer_seal_file_mismatch")
            }
        }
    }

    func expectedRole(for name: String) -> LiveOracleArtifactRole {
        switch name {
        case "preflight-readback.json", "provider-transport-events.json",
             "provider-receipts.json", "observer-events.json", "observer-seal.json":
            .observer
        default:
            .controller
        }
    }

    func expectedAuthor(
        for name: String,
        artifacts: LiveOracleArtifacts,
        observer: LiveOracleVerifiedObserver
    ) -> LiveProofProcessIdentity {
        switch name {
        case "arming-receipt.json":
            observer.handshakes[0].client
        case "preflight-readback.json", "provider-transport-events.json",
             "provider-receipts.json", "observer-events.json", "observer-seal.json":
            artifacts.preflight.producer
        default:
            observer.handshakes[1].client
        }
    }
}
