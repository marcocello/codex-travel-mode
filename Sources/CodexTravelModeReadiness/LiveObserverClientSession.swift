import Darwin
import Foundation

public final class LiveObserverClientSession: @unchecked Sendable {
    public let runID: String
    public let observerPID: Int32
    public let observerStartIdentity: String
    public let observerExecutableSHA256: String
    public let observerPublicKey: String

    private let descriptor: Int32
    private let lock = NSLock()
    private var finished = false
    private var nextRequestSequence: Int

    init(
        descriptor: Int32,
        runID: String,
        observer: LiveProofProcessIdentity,
        observerPublicKey: String,
        requestSequenceStart: Int
    ) {
        self.descriptor = descriptor
        self.runID = runID
        observerPID = observer.pid
        observerStartIdentity = observer.startIdentity
        observerExecutableSHA256 = observer.executableSHA256
        self.observerPublicKey = observerPublicKey
        nextRequestSequence = requestSequenceStart
    }

    deinit {
        lock.lock()
        if !finished { _ = Darwin.close(descriptor) }
        finished = true
        lock.unlock()
    }

    public func requestCapability() throws {
        try request(
            action: .capability,
            submit: nil,
            runID: nil,
            scenario: nil
        )
    }

    public func submitHeartbeat(_ submit: LiveProviderHeartbeatSubmit) throws {
        try request(
            action: .submit,
            submit: submit,
            runID: nil,
            scenario: nil
        )
    }

    public func requestReadback(runID: String, scenario: ReadinessScenario) throws {
        try request(
            action: .readback,
            submit: nil,
            runID: runID,
            scenario: scenario
        )
    }

    public func requestObservation(
        scenario: ReadinessScenario,
        kind: LiveOracleObserverEventKind,
        process: LiveProofProcessIdentity? = nil
    ) throws {
        try lock.withLock {
            try requireOpen()
            let sequence = nextRequestSequence
            try LiveObserverSocket.writeJSON(
                LiveObserverObservationRequest(
                    schema: "codex-travel-mode-observer-observation-request/v1",
                    requestSequence: sequence,
                    scenario: scenario,
                    kind: kind,
                    process: process
                ),
                to: descriptor
            )
            let response = try LiveObserverSocket.readJSON(
                LiveObserverAcknowledgement.self,
                from: descriptor
            )
            guard response.schema == "codex-travel-mode-observer-acknowledgement/v1",
                  response.requestSequence == sequence,
                  response.action == kind.rawValue,
                  response.disposition == "observed" else {
                throw ReadinessHarnessError.liveInterrupted(
                    "observer acknowledgement did not bind the observation"
                )
            }
            nextRequestSequence += 1
        }
    }

    public func validateProductionUI(scenario: ReadinessScenario) throws {
        try lock.withLock {
            try requireOpen()
            let sequence = nextRequestSequence
            try LiveObserverSocket.writeJSON(
                LiveObserverUIValidationRequest(
                    schema: "codex-travel-mode-observer-ui-validation-request/v1",
                    requestSequence: sequence,
                    scenario: scenario
                ),
                to: descriptor
            )
            let response = try LiveObserverSocket.readJSON(
                LiveObserverAcknowledgement.self,
                from: descriptor
            )
            guard response.schema == "codex-travel-mode-observer-acknowledgement/v1",
                  response.requestSequence == sequence,
                  response.action == "production_ui",
                  response.disposition == "observed" else {
                throw ReadinessHarnessError.liveInterrupted(
                    "observer did not validate the production UI"
                )
            }
            nextRequestSequence += 1
        }
    }

    func finish(disposition: String, detailCode: String) throws {
        try lock.withLock {
            try requireOpen()
            let request = LiveObserverFinishRequest(
                schema: "codex-travel-mode-observer-finish/v1",
                requestSequence: nextRequestSequence,
                disposition: disposition,
                detailCode: detailCode
            )
            try LiveObserverSocket.writeJSON(request, to: descriptor)
            _ = Darwin.close(descriptor)
            finished = true
        }
    }

    private func request(
        action: LiveObserverProviderAction,
        submit: LiveProviderHeartbeatSubmit?,
        runID: String?,
        scenario: ReadinessScenario?
    ) throws {
        try lock.withLock {
            try requireOpen()
            let sequence = nextRequestSequence
            try LiveObserverSocket.writeJSON(
                LiveObserverProviderRequest(
                    schema: "codex-travel-mode-observer-provider-request/v1",
                    requestSequence: sequence,
                    action: action,
                    submit: submit,
                    runID: runID,
                    scenario: scenario
                ),
                to: descriptor
            )
            let response = try LiveObserverSocket.readJSON(
                LiveObserverAcknowledgement.self,
                from: descriptor
            )
            guard response.schema == "codex-travel-mode-observer-acknowledgement/v1",
                  response.requestSequence == sequence,
                  response.action == action.rawValue,
                  response.disposition == "observed" else {
                throw ReadinessHarnessError.liveInterrupted(
                    "observer acknowledgement did not bind the provider request"
                )
            }
            nextRequestSequence += 1
        }
    }

    private func requireOpen() throws {
        guard !finished else {
            throw ReadinessHarnessError.liveInterrupted(
                "observer session is already finalized"
            )
        }
    }
}

private extension NSLock {
    func withLock<Value>(_ operation: () throws -> Value) rethrows -> Value {
        lock()
        defer { unlock() }
        return try operation()
    }
}
