import CodexTravelModeSleepLease
import Foundation
import ServiceManagement

public enum SleepOverrideLeaseServiceRegistrationStatus: String, Equatable, Sendable {
    case notRegistered = "not_registered"
    case enabled
    case requiresApproval = "requires_approval"
    case notFound = "not_found"
}

@available(macOS 13.0, *)
public enum SleepOverrideLeaseServiceRegistration {
    private static var service: SMAppService {
        SMAppService.daemon(
            plistName: SleepOverrideLeaseProductionIdentifiers.launchDaemonPlistName
        )
    }

    public static var status: SleepOverrideLeaseServiceRegistrationStatus {
        switch service.status {
        case .notRegistered:
            .notRegistered
        case .enabled:
            .enabled
        case .requiresApproval:
            .requiresApproval
        case .notFound:
            .notFound
        @unknown default:
            .notFound
        }
    }

    public static func register() throws {
        try service.register()
    }

    public static func unregister() async throws {
        try await service.unregister()
    }
}

@available(macOS 13.0, *)
public final class MachServiceSleepOverrideLeaseTransport: SleepOverrideLeaseTransport,
    @unchecked Sendable {
    private let lock = NSLock()
    private let eventBroadcaster = SleepOverrideLeaseProtectionEventBroadcaster()
    private var activeConnection: MachServiceSleepOverrideLeaseConnection?

    public init() {}

    public var registrationStatus: SleepOverrideLeaseServiceRegistrationStatus {
        SleepOverrideLeaseServiceRegistration.status
    }

    public func acquire(
        _ request: SleepOverrideLeaseAcquireRequest
    ) async throws -> SleepOverrideLeaseTransportReply {
        let connection = try connectionForRequest()
        return try await connection.acquire(request)
    }

    public func resolve(
        _ request: SleepOverrideLeaseAcquireRequest
    ) async throws -> SleepOverrideLeaseTransportReply {
        let connection = try connectionForRequest()
        return try await connection.resolve(request)
    }

    public func status(
        _ request: SleepOverrideLeaseBindingRequest
    ) async throws -> SleepOverrideLeaseTransportReply {
        let connection = try connectionForRequest()
        return try await connection.status(request)
    }

    public func release(
        _ request: SleepOverrideLeaseBindingRequest
    ) async throws -> SleepOverrideLeaseTransportReply {
        let connection = try connectionForRequest()
        return try await connection.release(request)
    }

    public func acknowledgeRelease(
        _ request: SleepOverrideLeaseBindingRequest
    ) async throws -> SleepOverrideLeaseTransportReply {
        let connection = try connectionForRequest()
        return try await connection.acknowledgeRelease(request)
    }

    public func retryCleanup(
        _ request: SleepOverrideLeaseBindingRequest
    ) async throws -> SleepOverrideLeaseTransportReply {
        let connection = try connectionForRequest()
        return try await connection.retryCleanup(request)
    }

    public func protectionEvents() -> AsyncStream<SleepOverrideLeaseProtectionEvent> {
        eventBroadcaster.stream()
    }
}

@available(macOS 13.0, *)
private extension MachServiceSleepOverrideLeaseTransport {
    func connectionForRequest() throws -> MachServiceSleepOverrideLeaseConnection {
        try lock.withLock {
            if let activeConnection, !activeConnection.isInvalidated {
                return activeConnection
            }
            if SleepOverrideLeaseServiceRegistration.status == .notRegistered {
                do {
                    try SleepOverrideLeaseServiceRegistration.register()
                } catch {
                    throw SleepOverrideLeaseTransportError.helperUnavailable(.definitelyNotSent)
                }
            }
            guard SleepOverrideLeaseServiceRegistration.status == .enabled else {
                throw SleepOverrideLeaseTransportError.helperUnavailable(.definitelyNotSent)
            }
            let connection = try MachServiceSleepOverrideLeaseConnection()
            activeConnection = connection
            observe(connection)
            return connection
        }
    }

    func observe(_ connection: MachServiceSleepOverrideLeaseConnection) {
        Task { [weak self, weak connection] in
            guard let connection else { return }
            for await event in connection.protectionEvents() {
                self?.eventBroadcaster.emit(event)
                if event == .connectionInvalidated {
                    self?.forget(connection)
                }
            }
        }
    }

    func forget(_ connection: MachServiceSleepOverrideLeaseConnection) {
        lock.withLock {
            if activeConnection === connection {
                activeConnection = nil
            }
        }
    }
}

@available(macOS 13.0, *)
private final class MachServiceSleepOverrideLeaseConnection: SleepOverrideLeaseTransport,
    @unchecked Sendable {
    private let connection: NSXPCConnection
    private let connectionState: SleepOverrideLeaseXPCConnectionState
    private let eventHub: SleepOverrideLeaseProtectionEventHub

    init() throws {
        let identity: SleepOverrideLeaseCodeSigningIdentity
        do {
            identity = try SleepOverrideLeaseCodeSigningIdentity.current(
                expectedIdentifier: SleepOverrideLeaseProductionIdentifiers.appBundleIdentifier
            )
        } catch {
            throw SleepOverrideLeaseTransportError.unauthenticated(.definitelyNotSent)
        }
        let helperRequirement: String
        do {
            helperRequirement = try SleepOverrideLeaseCodeSigningRequirements.helperRequirement(
                teamIdentifier: identity.teamIdentifier
            )
        } catch {
            throw SleepOverrideLeaseTransportError.unauthenticated(.definitelyNotSent)
        }

        let state = SleepOverrideLeaseXPCConnectionState()
        let events = SleepOverrideLeaseProtectionEventHub()
        let connection = NSXPCConnection(
            machServiceName: SleepOverrideLeaseProductionIdentifiers.machServiceName,
            options: .privileged
        )
        connection.remoteObjectInterface = SleepOverrideLeaseXPCInterface.make()
        connection.setCodeSigningRequirement(helperRequirement)
        connection.interruptionHandler = {
            events.emit(.helperInterrupted)
        }
        connection.invalidationHandler = {
            state.markInvalidated()
            events.finish(with: .connectionInvalidated)
        }
        connection.activate()

        self.connection = connection
        connectionState = state
        eventHub = events
    }

    deinit {
        connection.invalidate()
    }

    var isInvalidated: Bool {
        connectionState.isInvalidated
    }

    func acquire(
        _ request: SleepOverrideLeaseAcquireRequest
    ) async throws -> SleepOverrideLeaseTransportReply {
        try await invoke { service, reply in
            service.acquire(
                sessionID: request.sessionID,
                requestID: request.requestID,
                reply: reply
            )
        }
    }

    func resolve(
        _ request: SleepOverrideLeaseAcquireRequest
    ) async throws -> SleepOverrideLeaseTransportReply {
        try await invoke { service, reply in
            service.resolve(
                sessionID: request.sessionID,
                requestID: request.requestID,
                reply: reply
            )
        }
    }

    func status(
        _ request: SleepOverrideLeaseBindingRequest
    ) async throws -> SleepOverrideLeaseTransportReply {
        try await invoke { service, reply in
            service.status(
                binding: SleepOverrideLeaseXPCBinding(binding: request.binding),
                reply: reply
            )
        }
    }

    func release(
        _ request: SleepOverrideLeaseBindingRequest
    ) async throws -> SleepOverrideLeaseTransportReply {
        try await invoke { service, reply in
            service.release(
                binding: SleepOverrideLeaseXPCBinding(binding: request.binding),
                reply: reply
            )
        }
    }

    func acknowledgeRelease(
        _ request: SleepOverrideLeaseBindingRequest
    ) async throws -> SleepOverrideLeaseTransportReply {
        try await invoke { service, reply in
            service.acknowledgeRelease(
                binding: SleepOverrideLeaseXPCBinding(binding: request.binding),
                reply: reply
            )
        }
    }

    func retryCleanup(
        _ request: SleepOverrideLeaseBindingRequest
    ) async throws -> SleepOverrideLeaseTransportReply {
        try await invoke { service, reply in
            service.retryCleanup(
                binding: SleepOverrideLeaseXPCBinding(binding: request.binding),
                reply: reply
            )
        }
    }

    func protectionEvents() -> AsyncStream<SleepOverrideLeaseProtectionEvent> {
        eventHub.stream()
    }
}

@available(macOS 13.0, *)
private extension MachServiceSleepOverrideLeaseConnection {
    func invoke(
        _ operation: @escaping (
            any SleepOverrideLeaseXPCProtocol,
            @escaping (SleepOverrideLeaseXPCReply) -> Void
        ) -> Void
    ) async throws -> SleepOverrideLeaseTransportReply {
        guard !connectionState.isInvalidated else {
            throw SleepOverrideLeaseTransportError.helperUnavailable(.definitelyNotSent)
        }
        return try await withCheckedThrowingContinuation { continuation in
            let gate = SleepOverrideLeaseXPCReplyGate(continuation: continuation)
            let proxy = connection.remoteObjectProxyWithErrorHandler { [connection] _ in
                gate.resume(throwing: .interruptedAfterPossibleDispatch)
                connection.invalidate()
            }
            guard let service = proxy as? any SleepOverrideLeaseXPCProtocol else {
                gate.resume(
                    throwing: .invalidResponse("The helper proxy does not implement the lease interface.")
                )
                return
            }
            operation(service) { [eventHub] reply in
                do {
                    let value = try reply.transportValue()
                    eventHub.markRequestRoundTripCompleted()
                    gate.resume(returning: value)
                } catch let error as SleepOverrideLeaseTransportError {
                    gate.resume(throwing: error)
                } catch {
                    gate.resume(throwing: .invalidResponse(error.localizedDescription))
                }
            }
        }
    }
}

private final class SleepOverrideLeaseXPCConnectionState: @unchecked Sendable {
    private let lock = NSLock()
    private var invalidated = false

    var isInvalidated: Bool {
        lock.withLock { invalidated }
    }

    func markInvalidated() {
        lock.withLock { invalidated = true }
    }
}

private final class SleepOverrideLeaseXPCReplyGate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<SleepOverrideLeaseTransportReply, Error>?

    init(continuation: CheckedContinuation<SleepOverrideLeaseTransportReply, Error>) {
        self.continuation = continuation
    }

    func resume(returning reply: SleepOverrideLeaseTransportReply) {
        take()?.resume(returning: reply)
    }

    func resume(throwing error: SleepOverrideLeaseTransportError) {
        take()?.resume(throwing: error)
    }

    private func take() -> CheckedContinuation<SleepOverrideLeaseTransportReply, Error>? {
        lock.withLock {
            defer { continuation = nil }
            return continuation
        }
    }
}

final class SleepOverrideLeaseProtectionEventHub: @unchecked Sendable {
    private let lock = NSLock()
    private var continuations: [UUID: AsyncStream<SleepOverrideLeaseProtectionEvent>.Continuation] = [:]
    private var terminalEvent: SleepOverrideLeaseProtectionEvent?
    private var emittedInterruption = false

    func stream() -> AsyncStream<SleepOverrideLeaseProtectionEvent> {
        AsyncStream { continuation in
            let id = UUID()
            let snapshot = lock.withLock { () -> (
                terminal: SleepOverrideLeaseProtectionEvent?,
                interrupted: Bool
            ) in
                if terminalEvent == nil {
                    continuations[id] = continuation
                }
                return (terminalEvent, emittedInterruption)
            }
            if let terminal = snapshot.terminal {
                continuation.yield(terminal)
                continuation.finish()
                return
            }
            if snapshot.interrupted {
                continuation.yield(.helperInterrupted)
            }
            continuation.onTermination = { [weak self] _ in
                self?.remove(id: id)
            }
        }
    }

    func emit(_ event: SleepOverrideLeaseProtectionEvent) {
        let active = lock.withLock { () -> [AsyncStream<SleepOverrideLeaseProtectionEvent>.Continuation] in
            guard terminalEvent == nil else { return [] }
            if event == .helperInterrupted {
                guard !emittedInterruption else { return [] }
                emittedInterruption = true
            }
            return Array(continuations.values)
        }
        for continuation in active {
            continuation.yield(event)
        }
    }

    func markRequestRoundTripCompleted() {
        lock.withLock {
            guard terminalEvent == nil else { return }
            emittedInterruption = false
        }
    }

    func finish(with event: SleepOverrideLeaseProtectionEvent) {
        let active = lock.withLock { () -> [AsyncStream<SleepOverrideLeaseProtectionEvent>.Continuation] in
            guard terminalEvent == nil else { return [] }
            terminalEvent = event
            let values = Array(continuations.values)
            continuations.removeAll()
            return values
        }
        for continuation in active {
            continuation.yield(event)
            continuation.finish()
        }
    }

    private func remove(id: UUID) {
        _ = lock.withLock { continuations.removeValue(forKey: id) }
    }
}

private final class SleepOverrideLeaseProtectionEventBroadcaster: @unchecked Sendable {
    private let lock = NSLock()
    private var continuations: [UUID: AsyncStream<SleepOverrideLeaseProtectionEvent>.Continuation] = [:]

    func stream() -> AsyncStream<SleepOverrideLeaseProtectionEvent> {
        AsyncStream { continuation in
            let id = UUID()
            lock.withLock { continuations[id] = continuation }
            continuation.onTermination = { [weak self] _ in
                self?.remove(id: id)
            }
        }
    }

    func emit(_ event: SleepOverrideLeaseProtectionEvent) {
        let active = lock.withLock { Array(continuations.values) }
        for continuation in active {
            continuation.yield(event)
        }
    }

    private func remove(id: UUID) {
        _ = lock.withLock { continuations.removeValue(forKey: id) }
    }
}
