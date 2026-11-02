import CodexTravelModeSleepLease
import Foundation

public struct SleepOverrideLeaseTransportBinding: Codable, Equatable, Hashable, Sendable {
    public var sessionID: String
    public var requestID: String
    public var leaseID: String
    public var generation: String

    public init(sessionID: String, requestID: String, leaseID: String, generation: String) {
        self.sessionID = sessionID
        self.requestID = requestID
        self.leaseID = leaseID
        self.generation = generation
    }

    public init(_ binding: SleepOverrideLeaseBinding) {
        self.init(
            sessionID: binding.sessionID,
            requestID: binding.requestID,
            leaseID: binding.leaseID,
            generation: binding.generation
        )
    }

    public var domainValue: SleepOverrideLeaseBinding {
        SleepOverrideLeaseBinding(
            sessionID: sessionID,
            requestID: requestID,
            leaseID: leaseID,
            generation: generation
        )
    }
}

public struct SleepOverrideLeaseAcquireRequest: Codable, Equatable, Sendable {
    public var sessionID: String
    public var requestID: String

    public init(sessionID: String, requestID: String) {
        self.sessionID = sessionID
        self.requestID = requestID
    }
}

public struct SleepOverrideLeaseBindingRequest: Codable, Equatable, Sendable {
    public var binding: SleepOverrideLeaseTransportBinding

    public init(binding: SleepOverrideLeaseTransportBinding) {
        self.binding = binding
    }

    public init(binding: SleepOverrideLeaseBinding) {
        self.binding = SleepOverrideLeaseTransportBinding(binding)
    }
}

public enum SleepOverrideLeaseTransportOutcome: String, Codable, Equatable, Sendable {
    case receipt
    case authoritativeNotFound = "authoritative_not_found"
    case acknowledged
    case failure
}

public enum SleepOverrideLeaseTransportFailureCode: String, Codable, Equatable, Sendable {
    case helperUnavailable = "helper_unavailable"
    case unauthenticated
    case interrupted
    case cleanupRequired = "cleanup_required"
    case invalidReceipt = "invalid_receipt"
    case rejected
    case invalidResponse = "invalid_response"
}

public struct SleepOverrideLeaseTransportReply: Codable, Equatable, Sendable {
    public var outcome: SleepOverrideLeaseTransportOutcome
    public var phase: SleepOverrideLeasePhase?
    public var binding: SleepOverrideLeaseTransportBinding?
    public var failureCode: SleepOverrideLeaseTransportFailureCode?
    public var detail: String?

    public init(
        outcome: SleepOverrideLeaseTransportOutcome,
        phase: SleepOverrideLeasePhase? = nil,
        binding: SleepOverrideLeaseTransportBinding? = nil,
        failureCode: SleepOverrideLeaseTransportFailureCode? = nil,
        detail: String? = nil
    ) {
        self.outcome = outcome
        self.phase = phase
        self.binding = binding
        self.failureCode = failureCode
        self.detail = detail
    }

    public static func receipt(_ receipt: SleepOverrideLeaseReceipt) -> Self {
        Self(
            outcome: .receipt,
            phase: receipt.phase,
            binding: SleepOverrideLeaseTransportBinding(receipt.binding)
        )
    }

    public static let authoritativeNotFound = Self(outcome: .authoritativeNotFound)
    public static let acknowledged = Self(outcome: .acknowledged)

    public static func failure(
        _ code: SleepOverrideLeaseTransportFailureCode,
        detail: String? = nil
    ) -> Self {
        Self(outcome: .failure, failureCode: code, detail: detail)
    }
}

public enum SleepOverrideLeaseTransportError: Error, Equatable, Sendable {
    case helperUnavailable(LeaseDispatchCertainty)
    case unauthenticated(LeaseDispatchCertainty)
    case interruptedAfterPossibleDispatch
    case invalidResponse(String)
}

public protocol SleepOverrideLeaseTransport: Sendable {
    func acquire(_ request: SleepOverrideLeaseAcquireRequest) async throws -> SleepOverrideLeaseTransportReply
    func resolve(_ request: SleepOverrideLeaseAcquireRequest) async throws -> SleepOverrideLeaseTransportReply
    func status(_ request: SleepOverrideLeaseBindingRequest) async throws -> SleepOverrideLeaseTransportReply
    func release(_ request: SleepOverrideLeaseBindingRequest) async throws -> SleepOverrideLeaseTransportReply
    func acknowledgeRelease(_ request: SleepOverrideLeaseBindingRequest) async throws -> SleepOverrideLeaseTransportReply
    func retryCleanup(_ request: SleepOverrideLeaseBindingRequest) async throws -> SleepOverrideLeaseTransportReply
    func protectionEvents() -> AsyncStream<SleepOverrideLeaseProtectionEvent>
}

public struct TransportSleepOverrideLeaseClient: SleepOverrideLeaseClient, Sendable {
    private let transport: any SleepOverrideLeaseTransport

    public init(transport: any SleepOverrideLeaseTransport) {
        self.transport = transport
    }

    public func acquire(
        sessionID: String,
        requestID: String
    ) async throws -> SleepOverrideLeaseReceipt {
        let request = SleepOverrideLeaseAcquireRequest(sessionID: sessionID, requestID: requestID)
        let reply = try await perform { try await transport.acquire(request) }
        let receipt = try requireReceipt(reply)
        guard receipt.phase == .active,
              receipt.binding.sessionID == sessionID,
              receipt.binding.requestID == requestID else {
            throw SleepOverrideLeaseError.invalidReceipt
        }
        return receipt
    }

    public func resolve(
        sessionID: String,
        requestID: String
    ) async throws -> SleepOverrideLeaseResolution {
        let request = SleepOverrideLeaseAcquireRequest(sessionID: sessionID, requestID: requestID)
        let reply = try await perform { try await transport.resolve(request) }
        if reply.outcome == .authoritativeNotFound {
            guard reply.phase == nil,
                  reply.binding == nil,
                  reply.failureCode == nil else {
                throw SleepOverrideLeaseError.invalidResponse(
                    "Authoritative not-found included incompatible receipt or failure fields."
                )
            }
            return .authoritativeNotFound
        }
        let receipt = try requireReceipt(reply)
        guard receipt.binding.sessionID == sessionID,
              receipt.binding.requestID == requestID else {
            throw SleepOverrideLeaseError.invalidReceipt
        }
        return .found(receipt)
    }

    public func status(
        binding: SleepOverrideLeaseBinding
    ) async throws -> SleepOverrideLeaseReceipt {
        try await exactReceipt(
            binding: binding,
            operation: { try await transport.status(SleepOverrideLeaseBindingRequest(binding: binding)) }
        )
    }

    public func release(
        binding: SleepOverrideLeaseBinding
    ) async throws -> SleepOverrideLeaseReceipt {
        let receipt = try await exactReceipt(
            binding: binding,
            operation: { try await transport.release(SleepOverrideLeaseBindingRequest(binding: binding)) }
        )
        guard receipt.phase == .released else {
            throw SleepOverrideLeaseError.invalidResponse(
                "Release did not return a released receipt."
            )
        }
        return receipt
    }

    public func acknowledgeRelease(binding: SleepOverrideLeaseBinding) async throws {
        let reply = try await perform {
            try await transport.acknowledgeRelease(SleepOverrideLeaseBindingRequest(binding: binding))
        }
        guard reply.outcome == .acknowledged,
              reply.phase == nil,
              reply.binding == nil,
              reply.failureCode == nil else {
            throw SleepOverrideLeaseError.invalidResponse(
                "Release acknowledgement returned an incompatible response."
            )
        }
    }

    public func retryCleanup(
        binding: SleepOverrideLeaseBinding
    ) async throws -> SleepOverrideLeaseReceipt {
        try await exactReceipt(
            binding: binding,
            operation: { try await transport.retryCleanup(SleepOverrideLeaseBindingRequest(binding: binding)) }
        )
    }

    public func protectionEvents() -> AsyncStream<SleepOverrideLeaseProtectionEvent> {
        transport.protectionEvents()
    }
}

private extension TransportSleepOverrideLeaseClient {
    func exactReceipt(
        binding: SleepOverrideLeaseBinding,
        operation: () async throws -> SleepOverrideLeaseTransportReply
    ) async throws -> SleepOverrideLeaseReceipt {
        let reply = try await perform(operation)
        let receipt = try requireReceipt(reply)
        guard receipt.binding == binding else {
            throw SleepOverrideLeaseError.invalidReceipt
        }
        return receipt
    }

    func perform(
        _ operation: () async throws -> SleepOverrideLeaseTransportReply
    ) async throws -> SleepOverrideLeaseTransportReply {
        do {
            let reply = try await operation()
            if reply.outcome == .failure {
                throw try mappedFailure(reply)
            }
            guard reply.failureCode == nil else {
                throw SleepOverrideLeaseError.invalidResponse(
                    "A successful transport response included a failure code."
                )
            }
            return reply
        } catch let error as SleepOverrideLeaseError {
            throw error
        } catch let error as SleepOverrideLeaseTransportError {
            throw mapTransportError(error)
        } catch {
            throw SleepOverrideLeaseError.invalidResponse(error.localizedDescription)
        }
    }

    func requireReceipt(
        _ reply: SleepOverrideLeaseTransportReply
    ) throws -> SleepOverrideLeaseReceipt {
        guard reply.outcome == .receipt,
              let phase = reply.phase,
              let wireBinding = reply.binding,
              reply.failureCode == nil,
              !wireBinding.sessionID.isEmpty,
              !wireBinding.requestID.isEmpty,
              !wireBinding.leaseID.isEmpty,
              !wireBinding.generation.isEmpty else {
            throw SleepOverrideLeaseError.invalidResponse(
                "The helper did not return a complete receipt."
            )
        }
        return SleepOverrideLeaseReceipt(phase: phase, binding: wireBinding.domainValue)
    }

    func mappedFailure(
        _ reply: SleepOverrideLeaseTransportReply
    ) throws -> SleepOverrideLeaseError {
        guard let code = reply.failureCode,
              reply.phase == nil,
              reply.binding == nil else {
            throw SleepOverrideLeaseError.invalidResponse(
                "The helper returned an incomplete failure response."
            )
        }
        let detail = reply.detail ?? ""
        switch code {
        case .helperUnavailable:
            return .helperUnavailable(.mayHaveReachedHelper)
        case .unauthenticated:
            return .unauthenticated(.mayHaveReachedHelper)
        case .interrupted:
            return .interruptedAfterPossibleDispatch
        case .cleanupRequired:
            return .cleanupRequired(detail)
        case .invalidReceipt:
            return .invalidReceipt
        case .rejected:
            return .rejected(detail)
        case .invalidResponse:
            return .invalidResponse(detail)
        }
    }

    func mapTransportError(
        _ error: SleepOverrideLeaseTransportError
    ) -> SleepOverrideLeaseError {
        switch error {
        case .helperUnavailable(let certainty):
            .helperUnavailable(certainty)
        case .unauthenticated(let certainty):
            .unauthenticated(certainty)
        case .interruptedAfterPossibleDispatch:
            .interruptedAfterPossibleDispatch
        case .invalidResponse(let detail):
            .invalidResponse(detail)
        }
    }
}
