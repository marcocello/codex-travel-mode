import Foundation

public struct SleepOverrideLeaseBinding: Codable, Equatable, Hashable, Sendable {
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

    enum CodingKeys: String, CodingKey {
        case sessionID = "session_id"
        case requestID = "request_id"
        case leaseID = "lease_id"
        case generation
    }
}

public struct SleepOverrideLeaseCallerPrincipal: Codable, Equatable, Hashable, Sendable {
    public var bundleIdentifier: String
    public var teamIdentifier: String
    public var effectiveUserID: UInt32

    public init(bundleIdentifier: String, teamIdentifier: String, effectiveUserID: UInt32) {
        self.bundleIdentifier = bundleIdentifier
        self.teamIdentifier = teamIdentifier
        self.effectiveUserID = effectiveUserID
    }
}

public struct SleepOverrideLeaseConnectionID: Codable, Equatable, Hashable, Sendable {
    public var rawValue: String

    public init(rawValue: String = UUID().uuidString) {
        self.rawValue = rawValue
    }
}

public struct SleepOverrideLeaseCallContext: Equatable, Hashable, Sendable {
    public var principal: SleepOverrideLeaseCallerPrincipal
    public var connectionID: SleepOverrideLeaseConnectionID

    public init(
        principal: SleepOverrideLeaseCallerPrincipal,
        connectionID: SleepOverrideLeaseConnectionID
    ) {
        self.principal = principal
        self.connectionID = connectionID
    }
}

public enum SleepOverrideLeasePhase: String, Codable, Equatable, Sendable {
    case acquiring
    case active
    case restoring
    case cleanupRequired = "cleanup_required"
    case released
}

public struct SleepOverrideLeaseReceipt: Codable, Equatable, Sendable {
    public var phase: SleepOverrideLeasePhase
    public var binding: SleepOverrideLeaseBinding

    public init(phase: SleepOverrideLeasePhase, binding: SleepOverrideLeaseBinding) {
        self.phase = phase
        self.binding = binding
    }
}

public enum SleepOverrideLeaseResolution: Equatable, Sendable {
    case found(SleepOverrideLeaseReceipt)
    case authoritativeNotFound
}

public enum LeaseDispatchCertainty: String, Codable, Equatable, Sendable {
    case definitelyNotSent = "definitely_not_sent"
    case mayHaveReachedHelper = "may_have_reached_helper"
}

public enum SleepOverrideLeaseProtectionEvent: String, Equatable, Sendable {
    case connectionInvalidated = "connection_invalidated"
    case helperInterrupted = "helper_interrupted"
}

public protocol SleepOverrideLeaseClient: Sendable {
    func acquire(sessionID: String, requestID: String) async throws -> SleepOverrideLeaseReceipt
    func resolve(sessionID: String, requestID: String) async throws -> SleepOverrideLeaseResolution
    func status(binding: SleepOverrideLeaseBinding) async throws -> SleepOverrideLeaseReceipt
    func release(binding: SleepOverrideLeaseBinding) async throws -> SleepOverrideLeaseReceipt
    func acknowledgeRelease(binding: SleepOverrideLeaseBinding) async throws
    func retryCleanup(binding: SleepOverrideLeaseBinding) async throws -> SleepOverrideLeaseReceipt
    func protectionEvents() -> AsyncStream<SleepOverrideLeaseProtectionEvent>
}

public extension SleepOverrideLeaseClient {
    func retryCleanup(
        binding: SleepOverrideLeaseBinding
    ) async throws -> SleepOverrideLeaseReceipt {
        try await status(binding: binding)
    }

    func protectionEvents() -> AsyncStream<SleepOverrideLeaseProtectionEvent> {
        AsyncStream { continuation in
            continuation.finish()
        }
    }
}

public struct UnavailableSleepOverrideLeaseClient: SleepOverrideLeaseClient {
    public init() {}

    public func acquire(
        sessionID: String,
        requestID: String
    ) async throws -> SleepOverrideLeaseReceipt {
        throw SleepOverrideLeaseError.helperUnavailable(.definitelyNotSent)
    }

    public func resolve(
        sessionID: String,
        requestID: String
    ) async throws -> SleepOverrideLeaseResolution {
        throw SleepOverrideLeaseError.helperUnavailable(.definitelyNotSent)
    }

    public func status(
        binding: SleepOverrideLeaseBinding
    ) async throws -> SleepOverrideLeaseReceipt {
        throw SleepOverrideLeaseError.helperUnavailable(.definitelyNotSent)
    }

    public func release(
        binding: SleepOverrideLeaseBinding
    ) async throws -> SleepOverrideLeaseReceipt {
        throw SleepOverrideLeaseError.helperUnavailable(.definitelyNotSent)
    }

    public func acknowledgeRelease(binding: SleepOverrideLeaseBinding) async throws {
        throw SleepOverrideLeaseError.helperUnavailable(.definitelyNotSent)
    }
}

public enum SleepOverrideLeaseError: LocalizedError, Equatable, Sendable {
    case helperUnavailable(LeaseDispatchCertainty)
    case unauthenticated(LeaseDispatchCertainty)
    case interruptedAfterPossibleDispatch
    case cleanupRequired(String)
    case invalidReceipt
    case rejected(String)
    case invalidResponse(String)

    public var dispatchCertainty: LeaseDispatchCertainty? {
        switch self {
        case .helperUnavailable(let certainty), .unauthenticated(let certainty):
            certainty
        case .interruptedAfterPossibleDispatch:
            .mayHaveReachedHelper
        case .cleanupRequired, .invalidReceipt, .rejected, .invalidResponse:
            nil
        }
    }

    public var isDefinitivePreDispatchFailure: Bool {
        dispatchCertainty == .definitelyNotSent
    }

    public var errorDescription: String? {
        switch self {
        case .helperUnavailable:
            "The privileged Travel Mode sleep helper is not installed or unavailable."
        case .unauthenticated:
            "The Travel Mode app and sleep helper could not authenticate each other."
        case .interruptedAfterPossibleDispatch:
            "The sleep-helper connection was interrupted after the request may have been accepted."
        case .cleanupRequired(let detail):
            detail.isEmpty ? "The sleep helper requires verified cleanup." : detail
        case .invalidReceipt:
            "The privileged Travel Mode sleep helper returned a receipt for another lease."
        case .rejected(let detail):
            detail.isEmpty ? "The sleep helper rejected the request." : detail
        case .invalidResponse(let detail):
            detail.isEmpty ? "The sleep helper returned an invalid response." : detail
        }
    }
}
