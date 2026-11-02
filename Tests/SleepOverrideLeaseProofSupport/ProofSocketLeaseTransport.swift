import CodexTravelModeSleepLease
import CodexTravelModeSleepLeaseXPC
import Foundation

public final class ProofSocketLeaseTransport: SleepOverrideLeaseTransport, @unchecked Sendable {
    private let commandSocket: ProofUnixSocket
    private let monitorSocket: ProofUnixSocket
    private let eventStream: AsyncStream<SleepOverrideLeaseProtectionEvent>
    private let eventContinuation: AsyncStream<SleepOverrideLeaseProtectionEvent>.Continuation
    private var eofMonitor: ProofSocketEOFMonitor?

    public init(socketPath: String, credential: String) async throws {
        do {
            commandSocket = try ProofUnixSocket(connectingTo: socketPath)
            monitorSocket = try ProofUnixSocket(connectingTo: socketPath)
            try commandSocket.configureRequestTimeout(seconds: 5)
        } catch {
            throw SleepOverrideLeaseTransportError.helperUnavailable(.definitelyNotSent)
        }
        let events = AsyncStream<SleepOverrideLeaseProtectionEvent>.makeStream()
        eventStream = events.stream
        eventContinuation = events.continuation
        do {
            try await authenticate(commandSocket, credential: credential, monitor: false)
            try await authenticate(monitorSocket, credential: credential, monitor: true)
            eofMonitor = try ProofSocketEOFMonitor(socket: monitorSocket) { [eventContinuation] in
                eventContinuation.yield(.helperInterrupted)
                eventContinuation.finish()
            }
        } catch {
            commandSocket.close()
            monitorSocket.close()
            eventContinuation.finish()
            throw error
        }
    }

    deinit {
        eventContinuation.finish()
        eofMonitor?.cancel()
        commandSocket.close()
    }

    public func acquire(
        _ request: SleepOverrideLeaseAcquireRequest
    ) async throws -> SleepOverrideLeaseTransportReply {
        try await send(
            ProofLeaseRequest(
                operation: .acquire,
                sessionID: request.sessionID,
                leaseRequestID: request.requestID
            )
        )
    }

    public func resolve(
        _ request: SleepOverrideLeaseAcquireRequest
    ) async throws -> SleepOverrideLeaseTransportReply {
        try await send(
            ProofLeaseRequest(
                operation: .resolve,
                sessionID: request.sessionID,
                leaseRequestID: request.requestID
            )
        )
    }

    public func status(
        _ request: SleepOverrideLeaseBindingRequest
    ) async throws -> SleepOverrideLeaseTransportReply {
        try await send(ProofLeaseRequest(operation: .status, binding: request.binding.domainValue))
    }

    public func release(
        _ request: SleepOverrideLeaseBindingRequest
    ) async throws -> SleepOverrideLeaseTransportReply {
        try await send(ProofLeaseRequest(operation: .release, binding: request.binding.domainValue))
    }

    public func acknowledgeRelease(
        _ request: SleepOverrideLeaseBindingRequest
    ) async throws -> SleepOverrideLeaseTransportReply {
        try await send(
            ProofLeaseRequest(operation: .acknowledgeRelease, binding: request.binding.domainValue)
        )
    }

    public func retryCleanup(
        _ request: SleepOverrideLeaseBindingRequest
    ) async throws -> SleepOverrideLeaseTransportReply {
        try await send(
            ProofLeaseRequest(operation: .retryCleanup, binding: request.binding.domainValue)
        )
    }

    public func protectionEvents() -> AsyncStream<SleepOverrideLeaseProtectionEvent> {
        eventStream
    }

    public func advanceClock(milliseconds: Int) async throws {
        let reply = try await commandSocket.request(
            ProofLeaseRequest(operation: .advanceClock, milliseconds: milliseconds)
        )
        guard reply.outcome == .acknowledged else {
            throw try mappedRemoteError(reply)
        }
    }

    public func closeOwnerConnection() {
        commandSocket.close()
    }

    private func send(
        _ request: ProofLeaseRequest
    ) async throws -> SleepOverrideLeaseTransportReply {
        do {
            return try mapResponse(try await commandSocket.request(request))
        } catch let error as SleepOverrideLeaseTransportError {
            throw error
        } catch let error as ProofLeaseSupportError {
            switch error {
            case .connectionClosed, .socket:
                throw SleepOverrideLeaseTransportError.interruptedAfterPossibleDispatch
            default:
                throw SleepOverrideLeaseTransportError.invalidResponse(error.localizedDescription)
            }
        } catch {
            throw SleepOverrideLeaseTransportError.invalidResponse(error.localizedDescription)
        }
    }

    private func mapResponse(
        _ response: ProofLeaseResponse
    ) throws -> SleepOverrideLeaseTransportReply {
        switch response.outcome {
        case .acknowledged:
            return .acknowledged
        case .authoritativeNotFound:
            return .authoritativeNotFound
        case .receipt:
            guard let receipt = response.receipt else {
                throw SleepOverrideLeaseTransportError.invalidResponse(
                    "The proof helper omitted its receipt."
                )
            }
            return .receipt(receipt)
        case .error:
            let error = try mappedRemoteError(response)
            return .failure(error.code.transportCode, detail: error.detail)
        }
    }

    private func mappedRemoteError(
        _ response: ProofLeaseResponse
    ) throws -> ProofLeaseWireError {
        guard let error = response.error else {
            throw SleepOverrideLeaseTransportError.invalidResponse(
                "The proof helper omitted its structured failure."
            )
        }
        return error
    }
}

private func authenticate(
    _ socket: ProofUnixSocket,
    credential: String,
    monitor: Bool
) async throws {
    let operation: ProofLeaseOperation = monitor ? .monitor : .authenticate
    let response = try await socket.request(
        ProofLeaseRequest(operation: operation, credential: credential)
    )
    guard response.outcome == .acknowledged else {
        throw SleepOverrideLeaseTransportError.unauthenticated(.definitelyNotSent)
    }
}

private extension ProofLeaseErrorCode {
    var transportCode: SleepOverrideLeaseTransportFailureCode {
        switch self {
        case .unavailable: .helperUnavailable
        case .unauthenticated: .unauthenticated
        case .interrupted: .interrupted
        case .cleanupRequired: .cleanupRequired
        case .invalidReceipt: .invalidReceipt
        case .rejected, .malformedEnvelope, .unsupportedOperation: .rejected
        case .invalidResponse: .invalidResponse
        }
    }
}
