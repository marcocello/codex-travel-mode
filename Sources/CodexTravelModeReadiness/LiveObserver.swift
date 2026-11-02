import Darwin
import Foundation

final class LiveObserverService {
    private let arguments: LiveControllerObserverArguments
    private let signer = LiveProofEphemeralSigner()
    private let identity: LiveProofProcessIdentity
    private var providerPerformer: any LiveObserverProviderCommandPerforming
    private let preflightInspector: any LiveObserverPreflightInspecting
    private let permitsInjectedLegacyBinding: Bool
    private let uiValidator: any LiveObserverProductionUIValidating
    private var preparedPreflight: LiveObserverPreparedPreflight?
    private var preparedFacts: LiveObserverPreflightBindingFacts?
    private let evidenceRecorder: LiveObserverEvidenceRecorder?
    private var events: [LiveProofSignedEventEnvelope] = []
    private var signedHandshakes: [LiveProofSignedPayload] = []
    private var armedReceipt: LiveProofArmingReceipt?
    private var preflightClient: LiveProofProcessIdentity?
    private var nextRequestSequence = 1
    private var nextEvidenceSequence = 2
    private var closedIntervalStart: [ReadinessScenario: UInt64] = [:]
    private var pendingTransportBefore:
        [ReadinessScenario: [String: Int]] = [:]
    private var activeScenario: ReadinessScenario?
    private var factsSealed = false

    init(
        arguments: LiveControllerObserverArguments,
        providerPerformer: (any LiveObserverProviderCommandPerforming)? = nil,
        preflightInspector: any LiveObserverPreflightInspecting =
            ProductionLiveObserverPreflightInspector(),
        uiValidator: any LiveObserverProductionUIValidating =
            ProductionLiveObserverUIValidator()
    ) throws {
        self.arguments = arguments
        self.providerPerformer = providerPerformer
            ?? UnavailableLiveObserverProviderCommandPerformer()
        self.preflightInspector = preflightInspector
        self.uiValidator = uiValidator
        permitsInjectedLegacyBinding = providerPerformer != nil
        identity = try LiveProofProcessIdentity(
            pid: getpid(),
            startIdentity: LiveControllerSystem.processStartIdentity(pid: getpid()),
            executableSHA256: LiveControllerSystem.sha256File(
                LiveControllerSystem.executableURL()
            )
        )
        evidenceRecorder = providerPerformer == nil
            ? try LiveObserverEvidenceRecorder(
                runID: arguments.runID,
                observer: identity,
                signer: signer,
                redactionSalt: Data(arguments.runID.utf8)
            )
            : nil
    }

    func run() throws {
        try LiveControllerSystem.requireOwnedPrivateDirectory(arguments.outputURL)
        let socketURL = arguments.outputURL.appendingPathComponent(
            LiveControllerSystem.socketName
        )
        let listener = try LiveObserverSocket.makeListener(at: socketURL)
        var listenerIsOpen = true
        defer {
            if listenerIsOpen { _ = Darwin.close(listener) }
            _ = Darwin.unlink(socketURL.path)
        }
        do {
            try handlePreflight(listener: listener)
            let liveDescriptor = try LiveObserverSocket.accept(
                listener: listener,
                deadlineMilliseconds: arguments.expiresAtMilliseconds
            )
            try enterLiveSession(
                descriptor: liveDescriptor,
                listener: listener,
                listenerIsOpen: &listenerIsOpen
            )
        } catch {
            if let evidenceRecorder, !factsSealed,
               armedReceipt != nil, let scenario = activeScenario {
                try? evidenceRecorder.appendEvent(
                    LiveEvidenceObserverEventInput(
                        requestSequence: nextEvidenceSequence,
                        phase: .live,
                        unixMilliseconds: LiveControllerSystem.millisecondsSinceEpoch(),
                        monotonicNanoseconds: ReadinessClock.monotonicNanoseconds(),
                        scenario: scenario,
                        kind: .observationFailure,
                        failureCode: .observerInterrupted
                    )
                )
                if (try? LiveEvidenceFinalizer.finalizeObserver(
                    directory: arguments.outputURL,
                    recorder: evidenceRecorder,
                    liveSocketName: LiveControllerSystem.socketName
                )) != nil {
                    factsSealed = true
                }
            }
            if !events.isEmpty, !factsSealed {
                try? appendEvent(kind: "observer_failure", detailCode: "session_error")
                try? sealObserverFacts()
            }
            throw error
        }
    }

    private func enterLiveSession(
        descriptor liveDescriptor: Int32,
        listener: Int32,
        listenerIsOpen: inout Bool
    ) throws {
        let pending: Int32?
        do {
            pending = try LiveObserverSocket.acceptPending(listener: listener)
        } catch {
            _ = Darwin.close(liveDescriptor)
            throw error
        }
        if let unauthorized = pending {
            _ = Darwin.close(unauthorized)
            _ = Darwin.close(liveDescriptor)
            _ = Darwin.close(listener)
            listenerIsOpen = false
            if let evidenceRecorder {
                try evidenceRecorder.recordRejectedAttach()
            } else {
                try appendEvent(kind: "unauthorized_session", detailCode: "concurrent_attach")
                try sealObserverFacts()
            }
            throw ReadinessHarnessError.receiptRejected(
                "concurrent observer attach permanently invalidated the run"
            )
        }
        _ = Darwin.close(listener)
        listenerIsOpen = false
        try handleLive(descriptor: liveDescriptor)
    }

    private func handlePreflight(listener: Int32) throws {
        let descriptor = try LiveObserverSocket.accept(
            listener: listener,
            deadlineMilliseconds: arguments.expiresAtMilliseconds
        )
        defer { _ = Darwin.close(descriptor) }
        let request = try readHandshake(
            descriptor: descriptor,
            required: ["schema", "handshake", "expires_at_milliseconds"],
            optional: []
        )
        try validateHandshake(
            request,
            phase: .preflight,
            sequence: nextRequestSequence,
            descriptor: descriptor
        )
        try respond(to: request.handshake, descriptor: descriptor)
        preflightClient = request.handshake.client
        var bindingData = try LiveObserverSocket.readMessageData(from: descriptor)
        if try messageSchema(bindingData)
            == "codex-travel-mode-observer-preflight-context/v1" {
            try LiveProofCanonicalJSON.requireObjectKeys(
                bindingData,
                required: [
                    "schema", "request_sequence", "provider_configuration",
                    "app_bundle_path", "helper_executable_path",
                ]
            )
            let context = try LiveProofCanonicalJSON.decode(
                LiveObserverPreflightContext.self,
                from: bindingData
            )
            let prepared = try preflightInspector.inspect(
                context: context,
                runID: arguments.runID,
                outputURL: arguments.outputURL
            )
            preparedPreflight = prepared
            var responseFacts = prepared.facts
            if let evidenceRecorder {
                let readback = try evidenceRecorder.recordPreflight(
                    prepared.evidenceInput
                )
                let peer = try LiveObserverSocket.peerIdentity(descriptor: descriptor)
                try evidenceRecorder.appendHandshake(
                    request.handshake,
                    peerUID: Data(String(peer.uid).utf8)
                )
                try evidenceRecorder.appendEvent(
                    LiveEvidenceObserverEventInput(
                        requestSequence: 1,
                        phase: .preflight,
                        unixMilliseconds: LiveControllerSystem.millisecondsSinceEpoch(),
                        monotonicNanoseconds: ReadinessClock.monotonicNanoseconds(),
                        scenario: nil,
                        kind: .preflightSample,
                        observation: prepared.evidenceObservation
                    )
                )
                responseFacts = LiveObserverPreflightBindingFacts(
                    schema: prepared.facts.schema,
                    requestSequence: prepared.facts.requestSequence,
                    machineDigest: readback.machineDigest,
                    baselineDigest: readback.baselineDigest,
                    appIdentityDigest: readback.appIdentityDigest,
                    helperIdentityDigest: readback.helperIdentityDigest,
                    providerOrigin: readback.providerOrigin,
                    targetSSIDDigest: readback.targetSSIDDigest,
                    wifiDeviceDigest: prepared.facts.wifiDeviceDigest
                )
            }
            preparedFacts = responseFacts
            providerPerformer = ProductionLiveObserverProviderCommandPerformer(
                configuration: prepared.configuration
            )
            try LiveObserverSocket.writeJSON(responseFacts, to: descriptor)
            bindingData = try LiveObserverSocket.readMessageData(from: descriptor)
        } else if !permitsInjectedLegacyBinding {
            throw ReadinessHarnessError.receiptRejected(
                "observer-owned preflight context is required"
            )
        }
        try LiveProofCanonicalJSON.requireObjectKeys(
            bindingData,
            required: ["schema", "request_sequence", "receipt"]
        )
        let binding = try LiveProofCanonicalJSON.decode(
            LiveObserverBindingRequest.self,
            from: bindingData
        )
        try validateBindingRequest(binding)
        armedReceipt = binding.receipt
        nextRequestSequence += 1
        try LiveObserverSocket.writeJSON(
            LiveObserverAcknowledgement(
                schema: "codex-travel-mode-observer-acknowledgement/v1",
                requestSequence: binding.requestSequence,
                action: "binding",
                disposition: "armed"
            ),
            to: descriptor
        )
        if evidenceRecorder == nil {
            try appendEvent(kind: "preflight_session", detailCode: "armed")
        }
    }

    private func handleLive(descriptor: Int32) throws {
        defer { _ = Darwin.close(descriptor) }
        let request = try readHandshake(
            descriptor: descriptor,
            required: ["schema", "handshake", "receipt"],
            optional: []
        )
        try validateHandshake(
            request,
            phase: .live,
            sequence: nextRequestSequence,
            descriptor: descriptor
        )
        if let evidenceRecorder {
            let peer = try LiveObserverSocket.peerIdentity(descriptor: descriptor)
            try evidenceRecorder.appendHandshake(
                request.handshake,
                peerUID: Data(String(peer.uid).utf8)
            )
        }
        try consumeArmingReceipt(request.receipt)
        if evidenceRecorder == nil {
            try appendEvent(kind: "arming_consumed", detailCode: "one_time_marker_created")
        }
        try respond(to: request.handshake, descriptor: descriptor)
        if evidenceRecorder == nil {
            try appendEvent(kind: "live_session", detailCode: "attached")
        }
        try handleLiveRequests(descriptor: descriptor)
    }

    private func validateHandshake(
        _ request: LiveObserverHandshakeRequest,
        phase: LiveProofHandshakePhase,
        sequence: Int,
        descriptor: Int32
    ) throws {
        let handshake = request.handshake
        let peer = try LiveObserverSocket.peerIdentity(descriptor: descriptor)
        let peerExecutable = try LiveControllerSystem.executableURL(pid: peer.pid)
        let peerHash = try LiveControllerSystem.sha256File(peerExecutable)
        let peerStartIdentity = try LiveControllerSystem.processStartIdentity(pid: peer.pid)
        guard request.schema == "codex-travel-mode-observer-handshake/v1",
              handshake.schema == LiveProofHandshakePayload.schema,
              handshake.runID == arguments.runID,
              handshake.phase == phase,
              handshake.requestSequenceStart == sequence,
              handshake.controllerSHA256 == arguments.controllerHash,
              handshake.client.pid == peer.pid,
              handshake.client.startIdentity == peerStartIdentity,
              handshake.client.executableSHA256 == peerHash,
              peer.uid == geteuid(), peerHash == arguments.controllerHash else {
            throw ReadinessHarnessError.receiptRejected("observer peer identity rejected")
        }
        if phase == .preflight {
            guard request.expiresAtMilliseconds == arguments.expiresAtMilliseconds,
                  request.receipt == nil else {
                throw ReadinessHarnessError.receiptRejected("invalid preflight attach")
            }
        } else {
            guard request.expiresAtMilliseconds == nil,
                  request.receipt != nil,
                  handshake.client.pid != preflightClient?.pid,
                  handshake.client.startIdentity != preflightClient?.startIdentity else {
                throw ReadinessHarnessError.receiptRejected("invalid live attach")
            }
        }
    }

    private func respond(
        to handshake: LiveProofHandshakePayload,
        descriptor: Int32
    ) throws {
        let signed = try signer.signedHandshake(handshake)
        signedHandshakes.append(signed)
        let response = LiveObserverHandshakeResponse(
            observer: identity,
            observerPublicKey: signer.publicKeyBase64URL,
            signedHandshake: signed
        )
        try LiveObserverSocket.writeJSON(response, to: descriptor)
    }

    private func readHandshake(
        descriptor: Int32,
        required: Set<String>,
        optional: Set<String>
    ) throws -> LiveObserverHandshakeRequest {
        let data = try LiveObserverSocket.readMessageData(from: descriptor)
        try LiveProofCanonicalJSON.requireObjectKeys(
            data,
            required: required,
            optional: optional
        )
        return try LiveProofCanonicalJSON.decode(
            LiveObserverHandshakeRequest.self,
            from: data
        )
    }

    private func validateBindingRequest(_ request: LiveObserverBindingRequest) throws {
        let receipt = request.receipt
        let binding = receipt.binding
        let outputDigest = ReadinessDigest.salted(
            Data(arguments.outputURL.path.utf8),
            salt: Data(arguments.runID.utf8)
        )
        guard request.schema == "codex-travel-mode-observer-binding/v1",
              request.requestSequence == nextRequestSequence,
              receipt.expiresAtUnixMilliseconds == arguments.expiresAtMilliseconds,
              binding.runID == arguments.runID,
              binding.controllerSHA256 == arguments.controllerHash,
              binding.observer == identity,
              binding.observerPublicKey == signer.publicKeyBase64URL,
              binding.outputDirectoryDigest == outputDigest else {
            throw ReadinessHarnessError.receiptRejected("observer binding request is invalid")
        }
        if let facts = preparedFacts {
            guard binding.machineDigest == facts.machineDigest,
                  binding.baselineDigest == facts.baselineDigest,
                  binding.appIdentityDigest == facts.appIdentityDigest,
                  binding.helperIdentityDigest == facts.helperIdentityDigest,
                  binding.providerOrigin == facts.providerOrigin,
                  binding.targetSSIDDigest == facts.targetSSIDDigest,
                  binding.wifiDeviceDigest == facts.wifiDeviceDigest else {
                throw ReadinessHarnessError.receiptRejected(
                    "controller receipt changed observer-owned preflight facts"
                )
            }
        }
        try requireUnconsumedSidecar()
    }

    private func requireUnconsumedSidecar() throws {
        let sidecar = arguments.outputURL.appendingPathComponent(
            LiveControllerSystem.sidecarName
        )
        var info = stat()
        guard Darwin.lstat(sidecar.path, &info) == 0,
              info.st_mode & S_IFMT == S_IFREG,
              info.st_mode & 0o777 == 0o600,
              info.st_uid == geteuid(),
              info.st_size == LiveProofArming.sidecarByteCount else {
            throw ReadinessHarnessError.receiptRejected(
                "observer arming sidecar is unavailable or unsafe"
            )
        }
    }

    private func consumeArmingReceipt(_ receipt: LiveProofArmingReceipt?) throws {
        guard let receipt, receipt == armedReceipt else {
            throw ReadinessHarnessError.receiptRejected("live receipt changed after preflight")
        }
        try LiveProofArming.consume(
            receipt: receipt,
            sidecarURL: arguments.outputURL.appendingPathComponent(
                LiveControllerSystem.sidecarName
            ),
            markerURL: arguments.outputURL.appendingPathComponent(
                LiveControllerSystem.consumedName
            ),
            nowUnixMilliseconds: LiveControllerSystem.millisecondsSinceEpoch()
        )
        try LiveControllerSystem.syncDirectory(arguments.outputURL)
    }

    private func handleLiveRequests(descriptor: Int32) throws {
        while true {
            let data = try LiveObserverSocket.readMessageData(from: descriptor)
            let schema = try messageSchema(data)
            switch schema {
            case "codex-travel-mode-observer-provider-request/v1":
                try handleProviderRequest(data, descriptor: descriptor)
            case "codex-travel-mode-observer-observation-request/v1":
                try handleObservationRequest(data, descriptor: descriptor)
            case "codex-travel-mode-observer-ui-validation-request/v1":
                try handleUIValidationRequest(data, descriptor: descriptor)
            case "codex-travel-mode-observer-finish/v1":
                try handleFinish(data)
                return
            default:
                throw ReadinessHarnessError.liveInterrupted(
                    "unknown observer request action"
                )
            }
        }
    }

    private func handleUIValidationRequest(
        _ data: Data,
        descriptor: Int32
    ) throws {
        try LiveProofCanonicalJSON.requireObjectKeys(
            data,
            required: ["schema", "request_sequence", "scenario"]
        )
        let request = try LiveProofCanonicalJSON.decode(
            LiveObserverUIValidationRequest.self,
            from: data
        )
        guard request.requestSequence == nextRequestSequence,
              let prepared = preparedPreflight,
              let target = String(
                  data: prepared.evidenceInput.targetSSID,
                  encoding: .utf8
              ) else {
            throw ReadinessHarnessError.liveInterrupted(
                "production UI validation request is invalid"
            )
        }
        let app = try LivePlatformExactProcessInspector(
            resolver: LivePlatformProcessResolver()
        ).requireOneAppProcess(bundleURL: prepared.appBundleURL)
        try uiValidator.validate(
            app: app,
            expectedTargetSSID: target,
            expectedWiFiDevice: prepared.wifiDevice
        )
        try LiveObserverSocket.writeJSON(
            LiveObserverAcknowledgement(
                schema: "codex-travel-mode-observer-acknowledgement/v1",
                requestSequence: request.requestSequence,
                action: "production_ui",
                disposition: "observed"
            ),
            to: descriptor
        )
        nextRequestSequence += 1
    }

    private func handleProviderRequest(_ data: Data, descriptor: Int32) throws {
        try LiveProofCanonicalJSON.requireObjectKeys(
            data,
            required: ["schema", "request_sequence", "action"],
            optional: ["submit", "run_id", "scenario"]
        )
        let request = try LiveProofCanonicalJSON.decode(
            LiveObserverProviderRequest.self,
            from: data
        )
        guard request.requestSequence == nextRequestSequence else {
            throw ReadinessHarnessError.liveInterrupted("observer request sequence reset")
        }
        let command = try providerCommand(request)
        if case .submit(let submit) = command, evidenceRecorder != nil {
            guard let production = providerPerformer
                as? ProductionLiveObserverProviderCommandPerformer else {
                throw ReadinessHarnessError.providerFailed(
                    "production provider performer is unavailable"
                )
            }
            let address = try production.pinCapabilityRemoteAddress()
            pendingTransportBefore[submit.scenario] = [
                address: nextEvidenceSequence,
            ]
            try appendSystemEvidence(
                scenario: submit.scenario,
                kind: .closedBeforeTransport,
                providerRemoteAddress: address
            )
        }
        if let observed = providerPerformer as? any LiveObserverProviderObservationPerforming {
            let observation = try observed.performObserved(command)
            try recordProviderObservation(
                observation
            )
        } else {
            try providerPerformer.perform(command)
        }
        if evidenceRecorder == nil {
            try appendEvent(kind: "provider_action", detailCode: request.action.rawValue)
        }
        try LiveObserverSocket.writeJSON(
            LiveObserverAcknowledgement(
                schema: "codex-travel-mode-observer-acknowledgement/v1",
                requestSequence: request.requestSequence,
                action: request.action.rawValue,
                disposition: "observed"
            ),
            to: descriptor
        )
        nextRequestSequence += 1
    }

    private func handleObservationRequest(
        _ data: Data,
        descriptor: Int32
    ) throws {
        try LiveProofCanonicalJSON.requireObjectKeys(
            data,
            required: ["schema", "request_sequence", "scenario", "kind"],
            optional: ["process"]
        )
        let request = try LiveProofCanonicalJSON.decode(
            LiveObserverObservationRequest.self,
            from: data
        )
        guard request.requestSequence == nextRequestSequence else {
            throw ReadinessHarnessError.liveInterrupted("observer request sequence reset")
        }
        if request.kind == .processExit {
            guard let process = request.process else {
                throw ReadinessHarnessError.liveInterrupted(
                    "process-exit observation requires the exact process"
                )
            }
            try evidenceRecorder?.appendEvent(
                LiveEvidenceObserverEventInput(
                    requestSequence: nextEvidenceSequence,
                    phase: .live,
                    unixMilliseconds: LiveControllerSystem.millisecondsSinceEpoch(),
                    monotonicNanoseconds: ReadinessClock.monotonicNanoseconds(),
                    scenario: request.scenario,
                    kind: .processExit,
                    process: process
                )
            )
            nextEvidenceSequence += 1
        } else {
            if request.kind == .scenarioBaseline {
                guard activeScenario == nil else {
                    throw ReadinessHarnessError.liveInterrupted(
                        "a prior scenario did not reach its final observation"
                    )
                }
                activeScenario = request.scenario
            }
            try appendSystemEvidence(
                scenario: request.scenario,
                kind: request.kind
            )
            if request.kind == .scenarioFinal {
                activeScenario = nil
            }
        }
        try LiveObserverSocket.writeJSON(
            LiveObserverAcknowledgement(
                schema: "codex-travel-mode-observer-acknowledgement/v1",
                requestSequence: request.requestSequence,
                action: request.kind.rawValue,
                disposition: "observed"
            ),
            to: descriptor
        )
        nextRequestSequence += 1
    }

    private func providerCommand(
        _ request: LiveObserverProviderRequest
    ) throws -> LiveObserverProviderCommand {
        switch request.action {
        case .capability:
            guard request.submit == nil, request.runID == nil, request.scenario == nil else {
                throw ReadinessHarnessError.liveInterrupted("invalid capability request")
            }
            return .capability
        case .submit:
            guard let submit = request.submit,
                  submit.runID == arguments.runID,
                  request.runID == nil, request.scenario == nil else {
                throw ReadinessHarnessError.liveInterrupted("invalid submit request")
            }
            return .submit(submit)
        case .readback:
            guard request.submit == nil,
                  request.runID == arguments.runID,
                  let scenario = request.scenario else {
                throw ReadinessHarnessError.liveInterrupted("invalid readback request")
            }
            return .readback(runID: arguments.runID, scenario: scenario)
        }
    }

    private func handleFinish(_ data: Data) throws {
        try LiveProofCanonicalJSON.requireObjectKeys(
            data,
            required: ["schema", "request_sequence", "disposition", "detail_code"]
        )
        let finish = try LiveProofCanonicalJSON.decode(
            LiveObserverFinishRequest.self,
            from: data
        )
        guard finish.requestSequence == nextRequestSequence,
              !finish.disposition.isEmpty, !finish.detailCode.isEmpty else {
            throw ReadinessHarnessError.liveInterrupted("invalid observer finalization")
        }
        if let evidenceRecorder {
            if finish.disposition == "aborted" {
                guard let scenario = activeScenario else {
                    throw ReadinessHarnessError.liveInterrupted(
                        "aborted finalization has no active scenario"
                    )
                }
                try evidenceRecorder.appendEvent(
                    LiveEvidenceObserverEventInput(
                        requestSequence: nextEvidenceSequence,
                        phase: .live,
                        unixMilliseconds: LiveControllerSystem.millisecondsSinceEpoch(),
                        monotonicNanoseconds: ReadinessClock.monotonicNanoseconds(),
                        scenario: scenario,
                        kind: .observationFailure,
                        failureCode: .controllerInterrupted
                    )
                )
                nextEvidenceSequence += 1
            } else if finish.disposition != "completed" {
                throw ReadinessHarnessError.liveInterrupted(
                    "production finalization disposition is invalid"
                )
            }
            _ = try LiveEvidenceFinalizer.finalizeObserver(
                directory: arguments.outputURL,
                recorder: evidenceRecorder,
                liveSocketName: LiveControllerSystem.socketName
            )
            factsSealed = true
        } else {
            try appendEvent(kind: "live_session_finalized", detailCode: finish.detailCode)
            try sealObserverFacts()
        }
    }

    private func messageSchema(_ data: Data) throws -> String {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let schema = object["schema"] as? String else {
            throw ReadinessHarnessError.liveInterrupted("observer request has no schema")
        }
        return schema
    }

    private func recordProviderObservation(
        _ observation: LiveObserverProviderObservation
    ) throws {
        switch observation {
        case .capability:
            break
        case .submit(let submit):
            guard !submit.taskMetrics.isEmpty else {
                throw ReadinessHarnessError.providerFailed(
                    "provider submit has no observer-owned task metrics"
                )
            }
            guard let metric = submit.taskMetrics.first(where: {
                      $0.localAddress != nil && $0.remoteAddress != nil
                  }),
                  let local = metric.localAddress,
                  let remote = metric.remoteAddress,
                  let localAddress = try? LiveObservedIPAddress(local),
                  let remoteAddress = try? LiveObservedIPAddress(remote),
                  let beforeEventSequence =
                    pendingTransportBefore[submit.submit.scenario]?[
                        remoteAddress.canonicalText
                    ] else {
                throw ReadinessHarnessError.providerFailed(
                    "provider task metrics did not match a pre-transport route sample"
                )
            }
            try appendSystemEvidence(
                scenario: submit.submit.scenario,
                kind: .closedAfterTransport,
                providerRemoteAddress: remoteAddress.canonicalText
            )
            pendingTransportBefore[submit.submit.scenario] = nil
            try evidenceRecorder?.appendProviderTransport(
                LiveEvidenceProviderTransportInput(
                    scenario: submit.submit.scenario,
                    sequence: submit.submit.sequence,
                    nonce: submit.submit.nonce,
                    dispatchUnixMilliseconds: submit.dispatchedAtUnixMilliseconds,
                    completionUnixMilliseconds: submit.completedAtUnixMilliseconds,
                    localAddress: localAddress.rawBytes,
                    remoteAddress: remoteAddress.rawBytes,
                    beforeObserverEventSequence: beforeEventSequence,
                    afterObserverEventSequence: nextEvidenceSequence - 1
                )
            )
        case .readback(let readback):
            guard !readback.receipts.isEmpty else {
                throw ReadinessHarnessError.providerFailed(
                    "provider readback has no signed receipts"
                )
            }
            guard let scenario = readback.receipts.first?.scenario else {
                throw ReadinessHarnessError.providerFailed(
                    "provider readback scenario is unavailable"
                )
            }
            try evidenceRecorder?.recordProviderReceipts(
                scenario: scenario,
                receipts: readback.receipts
            )
        }
    }

    private func appendSystemEvidence(
        scenario: ReadinessScenario,
        kind: LiveOracleObserverEventKind,
        providerRemoteAddress: String? = nil
    ) throws {
        guard let evidenceRecorder else { return }
        let observation = try currentSystemObservation(
            providerRemoteAddress: providerRemoteAddress
        )
        try validateObservationAuthority(
            observation,
            scenario: scenario,
            kind: kind
        )
        let baseline: Data? = kind == .scenarioBaseline
            ? preparedPreflight?.evidenceInput.baselineBytes
            : nil
        try evidenceRecorder.appendEvent(
            LiveEvidenceObserverEventInput(
                requestSequence: nextEvidenceSequence,
                phase: .live,
                unixMilliseconds: LiveControllerSystem.millisecondsSinceEpoch(),
                monotonicNanoseconds: ReadinessClock.monotonicNanoseconds(),
                scenario: scenario,
                kind: kind,
                baselineBytes: baseline,
                observation: observation
            )
        )
        nextEvidenceSequence += 1
    }

    private func validateObservationAuthority(
        _ observation: LiveEvidenceSystemObservation,
        scenario: ReadinessScenario,
        kind: LiveOracleObserverEventKind
    ) throws {
        guard let prepared = preparedPreflight else {
            throw ReadinessHarnessError.liveInterrupted(
                "observer preflight authority is unavailable"
            )
        }
        let selectedDevice = Data(prepared.wifiDevice.utf8)
        let priorSSID = prepared.evidenceInput.priorSSID
        let targetSSID = prepared.evidenceInput.targetSSID
        guard observation.powerSource == .battery,
              observation.batteryPercent >= 20,
              observation.helperJournalAuthorizationCode == 0,
              observation.selectedWiFiDevice == selectedDevice else {
            throw ReadinessHarnessError.liveInterrupted(
                "observer authority preconditions changed during the run"
            )
        }
        switch kind {
        case .scenarioBaseline:
            guard !observation.lidClosed, !observation.appRunning,
                  observation.ssid == priorSSID,
                  observation.appJournal == .absent,
                  observation.helperJournal == .absent else {
                throw ReadinessHarnessError.liveInterrupted(
                    "scenario baseline is not clean"
                )
            }
        case .closedBeforeTransport:
            guard observation.lidClosed, observation.appRunning,
                  observation.ssid == targetSSID,
                  !observation.usableAddresses.isEmpty,
                  observation.routeDevice == selectedDevice else {
                throw ReadinessHarnessError.liveInterrupted(
                    "heartbeat transport did not begin while the lid was closed"
                )
            }
            closedIntervalStart[scenario] = closedIntervalStart[scenario]
                ?? ReadinessClock.monotonicNanoseconds()
        case .closedAfterTransport:
            guard observation.lidClosed, observation.appRunning,
                  observation.ssid == targetSSID,
                  !observation.usableAddresses.isEmpty,
                  observation.routeDevice == selectedDevice,
                  let start = closedIntervalStart[scenario],
                  ReadinessClock.monotonicNanoseconds() - start
                    <= 90 * 1_000_000_000 else {
                throw ReadinessHarnessError.liveInterrupted(
                    "closed-lid transport exceeded its 90-second observer deadline"
                )
            }
        case .mandatoryCleanup, .ownerDeathRelaunchedCleanup, .scenarioFinal:
            guard !observation.lidClosed,
                  observation.ssid == priorSSID,
                  observation.sleepDisabled
                    == prepared.evidenceObservation.sleepDisabled,
                  observation.wifiPower
                    == prepared.evidenceObservation.wifiPower,
                  observation.appJournal == .absent,
                  observation.helperJournal == .absent,
                  kind != .scenarioFinal || !observation.appRunning else {
                throw ReadinessHarnessError.liveInterrupted(
                    "mandatory restoration was not observer-confirmed"
                )
            }
        case .ownerDeathHelperStage:
            guard !observation.appRunning,
                  observation.sleepDisabled
                    == prepared.evidenceObservation.sleepDisabled,
                  observation.appJournal == .present,
                  observation.helperJournal == .absent else {
                throw ReadinessHarnessError.liveInterrupted(
                    "owner-death helper stage was not observer-confirmed"
                )
            }
        default:
            break
        }
    }

    private func currentSystemObservation(
        providerRemoteAddress: String? = nil
    ) throws -> LiveEvidenceSystemObservation {
        guard let prepared = preparedPreflight else {
            throw ReadinessHarnessError.liveInterrupted(
                "observer preflight state is unavailable"
            )
        }
        let remote: String
        if let providerRemoteAddress {
            remote = providerRemoteAddress
        } else if let resolved = try providerRemoteAddresses(
            prepared.configuration.origin
        ).first {
            remote = resolved
        } else {
            throw ReadinessHarnessError.providerFailed(
                "provider address resolution returned no public address"
            )
        }
        let runtime = try LiveObservedSystemProbe(
            redactionSalt: Data(arguments.runID.utf8)
        ).runtime(
            wifiDevice: prepared.wifiDevice,
            providerRemoteAddress: remote
        )
        let appExecutable = try LivePlatformBundleExecutableResolver()
            .executableURL(bundleURL: prepared.appBundleURL)
        let appProcesses = try LivePlatformProcessResolver().processes(
            executableURL: appExecutable
        )
        let helperJournal = try LiveObservedHelperJournalReader(
            runner: LiveObservedFixedCommandRunner()
        ).observe()
        guard helperJournal != .unauthorized, helperJournal != .indeterminate else {
            throw ReadinessHarnessError.liveInterrupted(
                "helper journal observation is indeterminate"
            )
        }
        return LiveEvidenceSystemObservation(
            powerSource: runtime.battery.source == .battery ? .battery : .ac,
            batteryPercent: runtime.battery.percent,
            lidClosed: runtime.lidClosed,
            sleepDisabled: runtime.sleepDisabled ? 1 : 0,
            wifiPower: runtime.wifiPowered,
            selectedWiFiDevice: Data(runtime.wifiDevice.utf8),
            ssid: try currentSSID(device: runtime.wifiDevice),
            usableAddresses: runtime.interfaceAddresses.map(\.rawBytes),
            routeRemoteAddress: runtime.routedRemoteAddress.rawBytes,
            routeDevice: Data(runtime.routeDevice.utf8),
            appRunning: !appProcesses.isEmpty,
            appJournal: oracleJournalState(LivePlatformAppJournalReader().presence()),
            helperJournal: helperJournal == .present ? .present : .absent,
            helperJournalAuthorizationCode: 0,
            appIdentityBytes: Data(
                try LiveControllerSystem.sha256File(appExecutable).utf8
            ),
            helperIdentityBytes: Data(
                try LiveControllerSystem.sha256File(
                    prepared.helperExecutableURL
                ).utf8
            )
        )
    }

    private func currentSSID(device: String) throws -> Data {
        let result = try LiveObservedFixedCommandRunner().run(
            LiveObservedSystemQuery.wifiSSID(device: device).command
        )
        guard result.exitStatus == 0 else {
            throw ReadinessHarnessError.liveInterrupted("SSID observation failed")
        }
        return Data(try LiveObservedSystemParsers.ssid(result.standardOutput).utf8)
    }

    private func providerRemoteAddresses(_ origin: String?) throws -> [String] {
        guard let origin, let host = URLComponents(string: origin)?.host else {
            throw ReadinessHarnessError.providerFailed("provider host is unavailable")
        }
        var hints = addrinfo(
            ai_flags: AI_ADDRCONFIG,
            ai_family: AF_UNSPEC,
            ai_socktype: SOCK_STREAM,
            ai_protocol: IPPROTO_TCP,
            ai_addrlen: 0,
            ai_canonname: nil,
            ai_addr: nil,
            ai_next: nil
        )
        var result: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &result) == 0, let first = result else {
            throw ReadinessHarnessError.providerFailed(
                "provider address resolution failed"
            )
        }
        defer { freeaddrinfo(result) }
        var addresses: [String] = []
        var cursor: UnsafeMutablePointer<addrinfo>? = first
        while let current = cursor {
            var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(
                current.pointee.ai_addr,
                current.pointee.ai_addrlen,
                &buffer,
                socklen_t(buffer.count),
                nil,
                0,
                NI_NUMERICHOST
            ) == 0, let end = buffer.firstIndex(of: 0) {
                let value = String(decoding: buffer[..<end].map(UInt8.init), as: UTF8.self)
                if let canonical = try? LiveObservedIPAddress(value).canonicalText,
                   !addresses.contains(canonical) {
                    addresses.append(canonical)
                }
            }
            cursor = current.pointee.ai_next
        }
        guard !addresses.isEmpty else {
            throw ReadinessHarnessError.providerFailed(
                "provider numeric address is unavailable"
            )
        }
        return addresses
    }

    private func oracleJournalState(
        _ value: LivePlatformJournalPresence
    ) -> LiveOracleJournalState {
        switch value {
        case .present: .present
        case .absent: .absent
        case .indeterminate: .indeterminate
        }
    }

    private func appendEvent(kind: String, detailCode: String) throws {
        let payload = LiveObserverOwnedFact(
            schema: "codex-travel-mode-observer-fact/v1",
            runID: arguments.runID,
            sequence: events.count + 1,
            wallTime: ReadinessClock.wallTime(),
            monotonicNanoseconds: ReadinessClock.monotonicNanoseconds(),
            kind: kind,
            detailCode: detailCode
        )
        let envelope = try signer.eventEnvelope(
            payload: LiveProofCanonicalJSON.encode(payload),
            previous: events.last
        )
        events.append(envelope)
    }

    private func sealObserverFacts() throws {
        let artifact = LiveObserverOwnedArtifact(
            schema: "codex-travel-mode-observer-events/v1",
            runID: arguments.runID,
            producer: identity,
            observerPublicKey: signer.publicKeyBase64URL,
            signedHandshakes: signedHandshakes,
            events: events
        )
        let eventsURL = arguments.outputURL.appendingPathComponent("observer-events.json")
        try LiveControllerSystem.writeExclusive(
            LiveProofCanonicalJSON.encode(artifact),
            to: eventsURL
        )
        let manifest = try LiveProofArtifactSealer.seal(
            directory: arguments.outputURL,
            names: ["observer-events.json"]
        )
        let finalHash = try events.last.map(LiveProofEphemeralSigner.envelopeSHA256)
            ?? LiveProofSignedEventEnvelope.genesisPreviousSHA256
        let payload = try LiveProofObserverSealPayload(
            runID: arguments.runID,
            observer: identity,
            observerPublicKey: signer.publicKeyBase64URL,
            eventCount: events.count,
            finalEnvelopeSHA256: finalHash,
            observerOwnedFiles: manifest.entries
        )
        let signed = try signer.signedSeal(payload)
        try LiveControllerSystem.writeExclusive(
            LiveProofCanonicalJSON.encode(signed),
            to: arguments.outputURL.appendingPathComponent("observer-seal.json"),
            finalMode: 0o400
        )
        factsSealed = true
    }
}

private struct LiveObserverOwnedFact: Codable {
    let schema: String
    let runID: String
    let sequence: Int
    let wallTime: String
    let monotonicNanoseconds: UInt64
    let kind: String
    let detailCode: String

    enum CodingKeys: String, CodingKey {
        case schema
        case runID = "run_id"
        case sequence
        case wallTime = "wall_time"
        case monotonicNanoseconds = "monotonic_nanoseconds"
        case kind
        case detailCode = "detail_code"
    }
}

private struct LiveObserverOwnedArtifact: Codable {
    let schema: String
    let runID: String
    let producer: LiveProofProcessIdentity
    let observerPublicKey: String
    let signedHandshakes: [LiveProofSignedPayload]
    let events: [LiveProofSignedEventEnvelope]

    enum CodingKeys: String, CodingKey {
        case schema
        case runID = "run_id"
        case producer
        case observerPublicKey = "observer_public_key"
        case signedHandshakes = "signed_handshakes"
        case events
    }
}

enum LiveObserverClient {
    static func beginPreflight(
        socketURL: URL,
        runID: String,
        controllerHash: String,
        expiresAtMilliseconds: Int64
    ) throws -> LiveObserverPreflightSession {
        let descriptor = try LiveObserverSocket.connect(at: socketURL)
        do {
            let handshake = try makeHandshake(
                runID: runID,
                phase: .preflight,
                controllerHash: controllerHash,
                sequence: 1
            )
            try LiveObserverSocket.writeJSON(
                LiveObserverHandshakeRequest(
                    schema: "codex-travel-mode-observer-handshake/v1",
                    handshake: handshake,
                    expiresAtMilliseconds: expiresAtMilliseconds,
                    receipt: nil
                ),
                to: descriptor
            )
            let response = try receiveVerified(
                descriptor: descriptor,
                handshake: handshake,
                expectedObserver: nil
            )
            return LiveObserverPreflightSession(
                descriptor: descriptor,
                observer: response.observer,
                observerPublicKey: response.observerPublicKey
            )
        } catch {
            _ = Darwin.close(descriptor)
            throw error
        }
    }

    static func beginLive(
        socketURL: URL,
        receipt: LiveProofArmingReceipt
    ) throws -> LiveObserverClientSession {
        let binding = receipt.binding
        let descriptor = try LiveObserverSocket.connect(at: socketURL)
        do {
            let handshake = try makeHandshake(
                runID: binding.runID,
                phase: .live,
                controllerHash: binding.controllerSHA256,
                sequence: 2
            )
            try LiveObserverSocket.writeJSON(
                LiveObserverHandshakeRequest(
                    schema: "codex-travel-mode-observer-handshake/v1",
                    handshake: handshake,
                    expiresAtMilliseconds: nil,
                    receipt: receipt
                ),
                to: descriptor
            )
            let response = try receiveVerified(
                descriptor: descriptor,
                handshake: handshake,
                expectedObserver: binding.observer
            )
            guard response.observerPublicKey == binding.observerPublicKey else {
                throw ReadinessHarnessError.receiptRejected("observer public key changed")
            }
            return LiveObserverClientSession(
                descriptor: descriptor,
                runID: binding.runID,
                observer: response.observer,
                observerPublicKey: response.observerPublicKey,
                requestSequenceStart: handshake.requestSequenceStart
            )
        } catch {
            _ = Darwin.close(descriptor)
            throw error
        }
    }

    private static func makeHandshake(
        runID: String,
        phase: LiveProofHandshakePhase,
        controllerHash: String,
        sequence: Int
    ) throws -> LiveProofHandshakePayload {
        let identity = try LiveProofProcessIdentity(
            pid: getpid(),
            startIdentity: LiveControllerSystem.processStartIdentity(pid: getpid()),
            executableSHA256: controllerHash
        )
        return try LiveProofHandshakePayload(
            runID: runID,
            phase: phase,
            client: identity,
            controllerSHA256: controllerHash,
            requestSequenceStart: sequence
        )
    }

    private static func receiveVerified(
        descriptor: Int32,
        handshake: LiveProofHandshakePayload,
        expectedObserver: LiveProofProcessIdentity?
    ) throws -> LiveObserverHandshakeResponse {
        let response = try LiveObserverSocket.readJSON(
            LiveObserverHandshakeResponse.self,
            from: descriptor
        )
        guard expectedObserver.map({ $0 == response.observer }) ?? true else {
            throw ReadinessHarnessError.receiptRejected("observer process identity changed")
        }
        let bytes = try LiveProofSignatureVerifier.verify(
            response.signedHandshake,
            domain: .handshake,
            publicKeyBase64URL: response.observerPublicKey
        )
        let signedHandshake = try LiveProofCanonicalJSON.decode(
            LiveProofHandshakePayload.self,
            from: bytes
        )
        guard signedHandshake == handshake else {
            throw ReadinessHarnessError.receiptRejected("observer handshake did not bind request")
        }
        return response
    }
}

struct LiveObserverPreflightSession {
    let descriptor: Int32
    let observer: LiveProofProcessIdentity
    let observerPublicKey: String

    func prepare(
        providerConfiguration: Data,
        appBundleURL: URL,
        helperExecutableURL: URL
    ) throws -> LiveObserverPreflightBindingFacts {
        try LiveObserverSocket.writeJSON(
            LiveObserverPreflightContext(
                schema: "codex-travel-mode-observer-preflight-context/v1",
                requestSequence: 1,
                providerConfiguration: providerConfiguration,
                appBundlePath: appBundleURL.standardizedFileURL.path,
                helperExecutablePath: helperExecutableURL.standardizedFileURL.path
            ),
            to: descriptor
        )
        let facts = try LiveObserverSocket.readJSON(
            LiveObserverPreflightBindingFacts.self,
            from: descriptor
        )
        guard facts.schema == "codex-travel-mode-observer-preflight-binding-facts/v1",
              facts.requestSequence == 1,
              LiveProofValidation.isSHA256Hex(facts.machineDigest),
              LiveProofValidation.isSHA256Hex(facts.baselineDigest),
              LiveProofValidation.isSHA256Hex(facts.appIdentityDigest),
              LiveProofValidation.isSHA256Hex(facts.helperIdentityDigest),
              LiveProofValidation.isSHA256Hex(facts.targetSSIDDigest),
              LiveProofValidation.isSHA256Hex(facts.wifiDeviceDigest) else {
            throw ReadinessHarnessError.receiptRejected(
                "observer returned invalid preflight binding facts"
            )
        }
        return facts
    }

    func arm(receipt: LiveProofArmingReceipt) throws {
        defer { _ = Darwin.close(descriptor) }
        try LiveObserverSocket.writeJSON(
            LiveObserverBindingRequest(
                schema: "codex-travel-mode-observer-binding/v1",
                requestSequence: 1,
                receipt: receipt
            ),
            to: descriptor
        )
        let response = try LiveObserverSocket.readJSON(
            LiveObserverAcknowledgement.self,
            from: descriptor
        )
        guard response.schema == "codex-travel-mode-observer-acknowledgement/v1",
              response.requestSequence == 1,
              response.action == "binding",
              response.disposition == "armed" else {
            throw ReadinessHarnessError.receiptRejected("observer did not arm")
        }
    }
}
