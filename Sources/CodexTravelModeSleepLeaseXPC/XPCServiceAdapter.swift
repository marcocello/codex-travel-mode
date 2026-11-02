import CodexTravelModeSleepLease
import Dispatch
import Foundation

public protocol SleepOverrideLeaseXPCServiceHandling: Sendable {
    func acquire(
        sessionID: String,
        requestID: String,
        context: SleepOverrideLeaseCallContext
    ) async throws -> SleepOverrideLeaseReceipt
    func resolve(
        sessionID: String,
        requestID: String,
        context: SleepOverrideLeaseCallContext
    ) async throws -> SleepOverrideLeaseResolution
    func status(
        binding: SleepOverrideLeaseBinding,
        context: SleepOverrideLeaseCallContext
    ) async throws -> SleepOverrideLeaseReceipt
    func release(
        binding: SleepOverrideLeaseBinding,
        context: SleepOverrideLeaseCallContext
    ) async throws -> SleepOverrideLeaseReceipt
    func acknowledgeRelease(
        binding: SleepOverrideLeaseBinding,
        context: SleepOverrideLeaseCallContext
    ) async throws
    func retryCleanup(
        binding: SleepOverrideLeaseBinding,
        context: SleepOverrideLeaseCallContext
    ) async throws -> SleepOverrideLeaseReceipt
    func connectionEnded(id: SleepOverrideLeaseConnectionID) async
}

public protocol SleepOverrideLeaseXPCConnectionContextProviding: Sendable {
    func context(for connection: NSXPCConnection) throws -> SleepOverrideLeaseCallContext
}

/// Used only after the listener's identifier-and-team requirement has accepted the connection.
struct RequirementAuthenticatedSleepOverrideLeaseContextProvider:
    SleepOverrideLeaseXPCConnectionContextProviding,
    Sendable {
    let expectedBundleIdentifier: String
    let expectedTeamIdentifier: String

    init(expectedBundleIdentifier: String, expectedTeamIdentifier: String) {
        self.expectedBundleIdentifier = expectedBundleIdentifier
        self.expectedTeamIdentifier = expectedTeamIdentifier
    }

    func context(
        for connection: NSXPCConnection
    ) throws -> SleepOverrideLeaseCallContext {
        _ = try SleepOverrideLeaseCodeSigningRequirements.appRequirement(
            teamIdentifier: expectedTeamIdentifier
        )
        return SleepOverrideLeaseCallContext(
            principal: SleepOverrideLeaseCallerPrincipal(
                bundleIdentifier: expectedBundleIdentifier,
                teamIdentifier: expectedTeamIdentifier,
                effectiveUserID: connection.effectiveUserIdentifier
            ),
            connectionID: SleepOverrideLeaseConnectionID()
        )
    }
}

public final class SleepOverrideLeaseXPCListenerDelegate: NSObject,
    NSXPCListenerDelegate,
    @unchecked Sendable {
    private let service: any SleepOverrideLeaseXPCServiceHandling
    private let contextProvider: any SleepOverrideLeaseXPCConnectionContextProviding

    public init(
        service: any SleepOverrideLeaseXPCServiceHandling,
        contextProvider: any SleepOverrideLeaseXPCConnectionContextProviding
    ) {
        self.service = service
        self.contextProvider = contextProvider
    }

    public func listener(
        _ listener: NSXPCListener,
        shouldAcceptNewConnection connection: NSXPCConnection
    ) -> Bool {
        let context: SleepOverrideLeaseCallContext
        do {
            context = try contextProvider.context(for: connection)
        } catch {
            return false
        }

        let exported = SleepOverrideLeaseXPCExportedObject(service: service, context: context)
        let lifetime = SleepOverrideLeaseXPCConnectionLifetime()
        connection.exportedInterface = SleepOverrideLeaseXPCInterface.make()
        connection.exportedObject = exported
        connection.invalidationHandler = { [service] in
            lifetime.endOnce {
                Task {
                    await service.connectionEnded(id: context.connectionID)
                }
            }
        }
        connection.activate()
        return true
    }
}

@available(macOS 13.0, *)
public final class SleepOverrideLeaseMachServiceHost: @unchecked Sendable {
    private let listener: NSXPCListener
    private let listenerDelegate: SleepOverrideLeaseXPCListenerDelegate

    public init(service: any SleepOverrideLeaseXPCServiceHandling) throws {
        let identity = try SleepOverrideLeaseCodeSigningIdentity.current(
            expectedIdentifier: SleepOverrideLeaseProductionIdentifiers.helperBundleIdentifier
        )
        let appRequirement = try SleepOverrideLeaseCodeSigningRequirements.appRequirement(
            teamIdentifier: identity.teamIdentifier
        )
        let listener = NSXPCListener(
            machServiceName: SleepOverrideLeaseProductionIdentifiers.machServiceName
        )
        listener.setConnectionCodeSigningRequirement(appRequirement)
        let provider = RequirementAuthenticatedSleepOverrideLeaseContextProvider(
            expectedBundleIdentifier: SleepOverrideLeaseProductionIdentifiers.appBundleIdentifier,
            expectedTeamIdentifier: identity.teamIdentifier
        )
        let delegate = SleepOverrideLeaseXPCListenerDelegate(
            service: service,
            contextProvider: provider
        )
        listener.delegate = delegate
        self.listener = listener
        listenerDelegate = delegate
    }

    public func run() -> Never {
        _ = listenerDelegate
        listener.activate()
        dispatchMain()
    }
}

private final class SleepOverrideLeaseXPCExportedObject: NSObject,
    SleepOverrideLeaseXPCProtocol,
    @unchecked Sendable {
    private let service: any SleepOverrideLeaseXPCServiceHandling
    private let context: SleepOverrideLeaseCallContext

    init(
        service: any SleepOverrideLeaseXPCServiceHandling,
        context: SleepOverrideLeaseCallContext
    ) {
        self.service = service
        self.context = context
    }

    func acquire(
        sessionID: String,
        requestID: String,
        reply: @escaping (SleepOverrideLeaseXPCReply) -> Void
    ) {
        guard validIdentifier(sessionID), validIdentifier(requestID) else {
            reply(rejection("Session and request IDs must contain 1 through 256 characters."))
            return
        }
        dispatch(reply) { [service, context] in
            .receipt(
                try await service.acquire(
                    sessionID: sessionID,
                    requestID: requestID,
                    context: context
                )
            )
        }
    }

    func resolve(
        sessionID: String,
        requestID: String,
        reply: @escaping (SleepOverrideLeaseXPCReply) -> Void
    ) {
        guard validIdentifier(sessionID), validIdentifier(requestID) else {
            reply(rejection("Session and request IDs must contain 1 through 256 characters."))
            return
        }
        dispatch(reply) { [service, context] in
            let resolution = try await service.resolve(
                sessionID: sessionID,
                requestID: requestID,
                context: context
            )
            switch resolution {
            case .found(let receipt):
                return .receipt(receipt)
            case .authoritativeNotFound:
                return .authoritativeNotFound
            }
        }
    }

    func status(
        binding: SleepOverrideLeaseXPCBinding,
        reply: @escaping (SleepOverrideLeaseXPCReply) -> Void
    ) {
        bindingOperation(binding, reply: reply) { [service, context] binding in
            .receipt(try await service.status(binding: binding, context: context))
        }
    }

    func release(
        binding: SleepOverrideLeaseXPCBinding,
        reply: @escaping (SleepOverrideLeaseXPCReply) -> Void
    ) {
        bindingOperation(binding, reply: reply) { [service, context] binding in
            .receipt(try await service.release(binding: binding, context: context))
        }
    }

    func acknowledgeRelease(
        binding: SleepOverrideLeaseXPCBinding,
        reply: @escaping (SleepOverrideLeaseXPCReply) -> Void
    ) {
        bindingOperation(binding, reply: reply) { [service, context] binding in
            try await service.acknowledgeRelease(binding: binding, context: context)
            return .acknowledged
        }
    }

    func retryCleanup(
        binding: SleepOverrideLeaseXPCBinding,
        reply: @escaping (SleepOverrideLeaseXPCReply) -> Void
    ) {
        bindingOperation(binding, reply: reply) { [service, context] binding in
            .receipt(try await service.retryCleanup(binding: binding, context: context))
        }
    }
}

private extension SleepOverrideLeaseXPCExportedObject {
    func bindingOperation(
        _ wireBinding: SleepOverrideLeaseXPCBinding,
        reply: @escaping (SleepOverrideLeaseXPCReply) -> Void,
        operation: @escaping @Sendable (
            SleepOverrideLeaseBinding
        ) async throws -> SleepOverrideLeaseTransportReply
    ) {
        let binding = wireBinding.transportValue
        guard validIdentifier(binding.sessionID),
              validIdentifier(binding.requestID),
              validIdentifier(binding.leaseID),
              validIdentifier(binding.generation) else {
            reply(rejection("Lease binding fields must contain 1 through 256 characters."))
            return
        }
        dispatch(reply) {
            try await operation(binding.domainValue)
        }
    }

    func dispatch(
        _ reply: @escaping (SleepOverrideLeaseXPCReply) -> Void,
        operation: @escaping @Sendable () async throws -> SleepOverrideLeaseTransportReply
    ) {
        let replyBox = SleepOverrideLeaseXPCReplyHandler(reply)
        Task {
            do {
                replyBox.call(SleepOverrideLeaseXPCReply(reply: try await operation()))
            } catch {
                replyBox.call(
                    SleepOverrideLeaseXPCReply(
                        reply: SleepOverrideLeaseTransportReply.serverFailure(error)
                    )
                )
            }
        }
    }

    func validIdentifier(_ value: String) -> Bool {
        !value.isEmpty && value.count <= 256
    }

    func rejection(_ detail: String) -> SleepOverrideLeaseXPCReply {
        SleepOverrideLeaseXPCReply(reply: .failure(.rejected, detail: detail))
    }
}

private final class SleepOverrideLeaseXPCReplyHandler: @unchecked Sendable {
    private let handler: (SleepOverrideLeaseXPCReply) -> Void

    init(_ handler: @escaping (SleepOverrideLeaseXPCReply) -> Void) {
        self.handler = handler
    }

    func call(_ reply: SleepOverrideLeaseXPCReply) {
        handler(reply)
    }
}

private final class SleepOverrideLeaseXPCConnectionLifetime: @unchecked Sendable {
    private let lock = NSLock()
    private var ended = false

    func endOnce(_ operation: () -> Void) {
        let shouldEnd = lock.withLock { () -> Bool in
            guard !ended else { return false }
            ended = true
            return true
        }
        if shouldEnd {
            operation()
        }
    }
}
