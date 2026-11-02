import CodexTravelModeSleepLease
import Foundation

public enum ProofLeaseOperation: String, Codable, Sendable {
    case authenticate
    case monitor
    case acquire
    case resolve
    case status
    case release
    case acknowledgeRelease = "acknowledge_release"
    case retryCleanup = "retry_cleanup"
    case advanceClock = "advance_clock"
    case shutdown
}

public struct ProofLeaseRequest: Codable, Sendable {
    public var correlationID: String
    public var operation: ProofLeaseOperation
    public var credential: String?
    public var sessionID: String?
    public var leaseRequestID: String?
    public var binding: SleepOverrideLeaseBinding?
    public var milliseconds: Int?

    public init(
        correlationID: String = UUID().uuidString,
        operation: ProofLeaseOperation,
        credential: String? = nil,
        sessionID: String? = nil,
        leaseRequestID: String? = nil,
        binding: SleepOverrideLeaseBinding? = nil,
        milliseconds: Int? = nil
    ) {
        self.correlationID = correlationID
        self.operation = operation
        self.credential = credential
        self.sessionID = sessionID
        self.leaseRequestID = leaseRequestID
        self.binding = binding
        self.milliseconds = milliseconds
    }

    enum CodingKeys: String, CodingKey {
        case correlationID = "correlation_id"
        case operation
        case credential
        case sessionID = "session_id"
        case leaseRequestID = "lease_request_id"
        case binding
        case milliseconds
    }
}

public enum ProofLeaseResponseOutcome: String, Codable, Sendable {
    case acknowledged
    case receipt
    case authoritativeNotFound = "authoritative_not_found"
    case error
}

public enum ProofLeaseErrorCode: String, Codable, Sendable {
    case unavailable
    case unauthenticated
    case interrupted
    case cleanupRequired = "cleanup_required"
    case invalidReceipt = "invalid_receipt"
    case rejected
    case invalidResponse = "invalid_response"
    case malformedEnvelope = "malformed_envelope"
    case unsupportedOperation = "unsupported_operation"
}

public struct ProofLeaseWireError: Codable, Error, Equatable, Sendable {
    public var code: ProofLeaseErrorCode
    public var dispatchCertainty: LeaseDispatchCertainty?
    public var detail: String

    public init(
        code: ProofLeaseErrorCode,
        dispatchCertainty: LeaseDispatchCertainty? = nil,
        detail: String
    ) {
        self.code = code
        self.dispatchCertainty = dispatchCertainty
        self.detail = detail
    }

    enum CodingKeys: String, CodingKey {
        case code
        case dispatchCertainty = "dispatch_certainty"
        case detail
    }
}

public struct ProofLeaseResponse: Codable, Sendable {
    public var correlationID: String
    public var outcome: ProofLeaseResponseOutcome
    public var receipt: SleepOverrideLeaseReceipt?
    public var error: ProofLeaseWireError?

    public init(
        correlationID: String,
        outcome: ProofLeaseResponseOutcome,
        receipt: SleepOverrideLeaseReceipt? = nil,
        error: ProofLeaseWireError? = nil
    ) {
        self.correlationID = correlationID
        self.outcome = outcome
        self.receipt = receipt
        self.error = error
    }

    enum CodingKeys: String, CodingKey {
        case correlationID = "correlation_id"
        case outcome
        case receipt
        case error
    }
}

public struct ProofOwnerArtifact: Codable, Sendable {
    public var receipt: SleepOverrideLeaseReceipt?
    public var secondReceipt: SleepOverrideLeaseReceipt?
    public var resolution: String?
    public var errorCode: String?
    public var isRunning: Bool?
    public var latestStatus: String?
    public var loopStopped: Bool?
    public var keepAwakeStopped: Bool?
    public var lifecycle: String?

    public init(
        receipt: SleepOverrideLeaseReceipt? = nil,
        secondReceipt: SleepOverrideLeaseReceipt? = nil,
        resolution: String? = nil,
        errorCode: String? = nil,
        isRunning: Bool? = nil,
        latestStatus: String? = nil,
        loopStopped: Bool? = nil,
        keepAwakeStopped: Bool? = nil,
        lifecycle: String? = nil
    ) {
        self.receipt = receipt
        self.secondReceipt = secondReceipt
        self.resolution = resolution
        self.errorCode = errorCode
        self.isRunning = isRunning
        self.latestStatus = latestStatus
        self.loopStopped = loopStopped
        self.keepAwakeStopped = keepAwakeStopped
        self.lifecycle = lifecycle
    }

    enum CodingKeys: String, CodingKey {
        case receipt
        case secondReceipt = "second_receipt"
        case resolution
        case errorCode = "error_code"
        case isRunning = "is_running"
        case latestStatus = "latest_status"
        case loopStopped = "loop_stopped"
        case keepAwakeStopped = "keep_awake_stopped"
        case lifecycle
    }
}

public struct ProofPowerState: Codable, Equatable, Sendable {
    public var sleepDisabled: Bool

    public init(sleepDisabled: Bool) {
        self.sleepDisabled = sleepDisabled
    }

    enum CodingKeys: String, CodingKey {
        case sleepDisabled = "sleep_disabled"
    }
}

public struct ProofPowerControl: Codable, Equatable, Sendable {
    public var failReadsRemaining: Int
    public var failWritesRemaining: Int
    public var ignoreWritesRemaining: Int

    public init(
        failReadsRemaining: Int = 0,
        failWritesRemaining: Int = 0,
        ignoreWritesRemaining: Int = 0
    ) {
        self.failReadsRemaining = failReadsRemaining
        self.failWritesRemaining = failWritesRemaining
        self.ignoreWritesRemaining = ignoreWritesRemaining
    }

    enum CodingKeys: String, CodingKey {
        case failReadsRemaining = "fail_reads_remaining"
        case failWritesRemaining = "fail_writes_remaining"
        case ignoreWritesRemaining = "ignore_writes_remaining"
    }
}

public struct ProofPowerTraceEntry: Codable, Equatable, Sendable {
    public var sequence: Int
    public var operation: String
    public var arguments: [String]
    public var requestedValue: Bool?
    public var observedValue: Bool?
    public var succeeded: Bool

    public init(
        sequence: Int,
        operation: String,
        arguments: [String],
        requestedValue: Bool?,
        observedValue: Bool?,
        succeeded: Bool
    ) {
        self.sequence = sequence
        self.operation = operation
        self.arguments = arguments
        self.requestedValue = requestedValue
        self.observedValue = observedValue
        self.succeeded = succeeded
    }

    enum CodingKeys: String, CodingKey {
        case sequence
        case operation
        case arguments
        case requestedValue = "requested_value"
        case observedValue = "observed_value"
        case succeeded
    }
}

public enum ProofLeaseSupportError: LocalizedError, Sendable {
    case invalidArguments(String)
    case socket(String)
    case connectionClosed
    case malformedResponse(String)
    case remote(ProofLeaseWireError)

    public var errorDescription: String? {
        switch self {
        case .invalidArguments(let detail): detail
        case .socket(let detail): detail
        case .connectionClosed: "The proof-helper connection closed."
        case .malformedResponse(let detail): detail
        case .remote(let error): error.detail
        }
    }
}

public func mappedLeaseError(_ error: ProofLeaseWireError) -> SleepOverrideLeaseError {
    switch error.code {
    case .unavailable:
        .helperUnavailable(error.dispatchCertainty ?? .mayHaveReachedHelper)
    case .unauthenticated:
        .unauthenticated(error.dispatchCertainty ?? .definitelyNotSent)
    case .interrupted:
        .interruptedAfterPossibleDispatch
    case .cleanupRequired:
        .cleanupRequired(error.detail)
    case .invalidReceipt:
        .invalidReceipt
    case .rejected, .malformedEnvelope, .unsupportedOperation:
        .rejected(error.detail)
    case .invalidResponse:
        .invalidResponse(error.detail)
    }
}
