import CodexTravelModeSleepLease
import Darwin
import Foundation
import SleepOverrideLeaseProofSupport

private struct HelperArguments {
    var socketPath: String
    var stateRootURL: URL
    var powerExecutableURL: URL
    var powerStateURL: URL
    var powerTraceURL: URL
    var powerControlURL: URL
    var transitionTraceURL: URL
    var clockTraceURL: URL
    var checkpoint: String?
    var checkpointMarkerURL: URL?
    var checkpointGateURL: URL?

    init(_ arguments: [String]) throws {
        let values = try Self.parse(arguments)
        guard let socketPath = values["--socket"],
              let stateRoot = values["--state-root"],
              let powerExecutable = values["--power-executable"],
              let powerState = values["--power-state"],
              let powerTrace = values["--power-trace"],
              let powerControl = values["--power-control"],
              let transitionTrace = values["--transition-trace"],
              let clockTrace = values["--clock-trace"] else {
            throw ProofLeaseSupportError.invalidArguments(Self.usage)
        }
        self.socketPath = socketPath
        stateRootURL = URL(fileURLWithPath: stateRoot, isDirectory: true)
        powerExecutableURL = URL(fileURLWithPath: powerExecutable)
        powerStateURL = URL(fileURLWithPath: powerState)
        powerTraceURL = URL(fileURLWithPath: powerTrace)
        powerControlURL = URL(fileURLWithPath: powerControl)
        transitionTraceURL = URL(fileURLWithPath: transitionTrace)
        clockTraceURL = URL(fileURLWithPath: clockTrace)
        checkpoint = values["--checkpoint"]
        checkpointMarkerURL = values["--checkpoint-marker"].map(URL.init(fileURLWithPath:))
        checkpointGateURL = values["--checkpoint-gate"].map(URL.init(fileURLWithPath:))
    }

    private static func parse(_ arguments: [String]) throws -> [String: String] {
        var values: [String: String] = [:]
        var index = 1
        while index < arguments.count {
            guard index + 1 < arguments.count, arguments[index].hasPrefix("--") else {
                throw ProofLeaseSupportError.invalidArguments(usage)
            }
            values[arguments[index]] = arguments[index + 1]
            index += 2
        }
        return values
    }

    private static let usage = "Usage: sleep-override-lease-proof-helper --socket PATH --state-root PATH --power-executable PATH --power-state PATH --power-trace PATH --power-control PATH --transition-trace PATH --clock-trace PATH [--checkpoint NAME --checkpoint-marker PATH --checkpoint-gate PATH]"
}

private actor ConnectorCheckpoint {
    private let enabled: Bool
    private let markerURL: URL?
    private let gateURL: URL?
    private var reached = false

    init(arguments: HelperArguments) {
        enabled = arguments.checkpoint == "before_service_dispatch"
        markerURL = arguments.checkpointMarkerURL
        gateURL = arguments.checkpointGateURL
    }

    func waitIfSelected() async {
        guard enabled, !reached, let markerURL else { return }
        reached = true
        try? Data("before_service_dispatch\n".utf8).write(to: markerURL, options: .atomic)
        guard let gateURL else {
            try? await Task.sleep(for: .seconds(30))
            return
        }
        while !FileManager.default.fileExists(atPath: gateURL.path), !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }
}

private final class ProofLeaseConnector: @unchecked Sendable {
    private let service: SleepOverrideLeaseService
    private let clock: ProofDeterministicLeaseClock
    private let checkpoint: ConnectorCheckpoint

    init(
        service: SleepOverrideLeaseService,
        clock: ProofDeterministicLeaseClock,
        checkpoint: ConnectorCheckpoint
    ) {
        self.service = service
        self.clock = clock
        self.checkpoint = checkpoint
    }

    func handle(descriptor: Int32) async {
        let socket = ProofUnixSocket(acceptedDescriptor: descriptor)
        guard let authentication = try? readProofFrame(
            ProofLeaseRequest.self,
            from: descriptor
        ) else { return }
        if authentication.operation == .monitor {
            await handleMonitor(authentication, descriptor: descriptor)
            return
        }
        guard authentication.operation == .authenticate,
              let principal = principal(for: authentication.credential) else {
            try? writeProofFrame(unauthenticated(authentication), to: descriptor)
            return
        }
        try? writeProofFrame(acknowledged(authentication), to: descriptor)
        let context = SleepOverrideLeaseCallContext(
            principal: principal,
            connectionID: SleepOverrideLeaseConnectionID()
        )
        await serveRequests(descriptor: descriptor, context: context)
        await service.connectionInvalidated(id: context.connectionID)
        _ = socket
    }

    private func handleMonitor(
        _ request: ProofLeaseRequest,
        descriptor: Int32
    ) async {
        guard principal(for: request.credential) != nil else {
            try? writeProofFrame(unauthenticated(request), to: descriptor)
            return
        }
        try? writeProofFrame(acknowledged(request), to: descriptor)
        var byte: UInt8 = 0
        while Darwin.recv(descriptor, &byte, 1, 0) > 0 {}
    }

    private func serveRequests(
        descriptor: Int32,
        context: SleepOverrideLeaseCallContext
    ) async {
        while true {
            let request: ProofLeaseRequest
            do {
                guard let decoded = try readProofFrame(
                    ProofLeaseRequest.self,
                    from: descriptor
                ) else { return }
                request = decoded
            } catch {
                return
            }
            if request.operation == .acquire {
                await checkpoint.waitIfSelected()
            }
            let response = await dispatch(request, context: context)
            do {
                try writeProofFrame(response, to: descriptor)
            } catch {
                return
            }
        }
    }

    private func dispatch(
        _ request: ProofLeaseRequest,
        context: SleepOverrideLeaseCallContext
    ) async -> ProofLeaseResponse {
        do {
            switch request.operation {
            case .acquire:
                return receiptResponse(request, try await acquire(request, context: context))
            case .resolve:
                return try await resolveResponse(request, context: context)
            case .status:
                return receiptResponse(request, try await status(request, context: context))
            case .release:
                return receiptResponse(request, try await release(request, context: context))
            case .acknowledgeRelease:
                try await acknowledge(request, context: context)
                return acknowledged(request)
            case .retryCleanup:
                return receiptResponse(request, try await retry(request, context: context))
            case .advanceClock:
                await clock.advance(milliseconds: try requireMilliseconds(request))
                return acknowledged(request)
            case .shutdown:
                return acknowledged(request)
            case .authenticate, .monitor:
                throw SleepOverrideLeaseError.rejected("Authentication is valid only as the first frame.")
            }
        } catch {
            return failureResponse(request, error: error)
        }
    }

    private func acquire(
        _ request: ProofLeaseRequest,
        context: SleepOverrideLeaseCallContext
    ) async throws -> SleepOverrideLeaseReceipt {
        let identifiers = try requireAcquireIdentifiers(request)
        return try await service.acquire(
            sessionID: identifiers.sessionID,
            requestID: identifiers.requestID,
            context: context
        )
    }

    private func resolveResponse(
        _ request: ProofLeaseRequest,
        context: SleepOverrideLeaseCallContext
    ) async throws -> ProofLeaseResponse {
        let identifiers = try requireAcquireIdentifiers(request)
        let resolution = try await service.resolve(
            sessionID: identifiers.sessionID,
            requestID: identifiers.requestID,
            context: context
        )
        switch resolution {
        case .found(let receipt): return receiptResponse(request, receipt)
        case .authoritativeNotFound:
            return ProofLeaseResponse(
                correlationID: request.correlationID,
                outcome: .authoritativeNotFound
            )
        }
    }

    private func status(
        _ request: ProofLeaseRequest,
        context: SleepOverrideLeaseCallContext
    ) async throws -> SleepOverrideLeaseReceipt {
        try await service.status(binding: try requireBinding(request), context: context)
    }

    private func release(
        _ request: ProofLeaseRequest,
        context: SleepOverrideLeaseCallContext
    ) async throws -> SleepOverrideLeaseReceipt {
        try await service.release(binding: try requireBinding(request), context: context)
    }

    private func acknowledge(
        _ request: ProofLeaseRequest,
        context: SleepOverrideLeaseCallContext
    ) async throws {
        try await service.acknowledgeRelease(
            binding: try requireBinding(request),
            context: context
        )
    }

    private func retry(
        _ request: ProofLeaseRequest,
        context: SleepOverrideLeaseCallContext
    ) async throws -> SleepOverrideLeaseReceipt {
        try await service.retryCleanup(binding: try requireBinding(request), context: context)
    }
}

private extension ProofLeaseConnector {
    func principal(for credential: String?) -> SleepOverrideLeaseCallerPrincipal? {
        switch credential {
        case "owner-a":
            SleepOverrideLeaseCallerPrincipal(
                bundleIdentifier: "com.codex.travelmode",
                teamIdentifier: "PROOFTEAM",
                effectiveUserID: geteuid()
            )
        case "owner-b":
            SleepOverrideLeaseCallerPrincipal(
                bundleIdentifier: "com.example.other",
                teamIdentifier: "OTHERTEAM",
                effectiveUserID: geteuid()
            )
        default:
            nil
        }
    }

    func requireAcquireIdentifiers(
        _ request: ProofLeaseRequest
    ) throws -> (sessionID: String, requestID: String) {
        guard let sessionID = request.sessionID,
              let requestID = request.leaseRequestID else {
            throw SleepOverrideLeaseError.rejected("The acquire envelope omitted its identifiers.")
        }
        return (sessionID, requestID)
    }

    func requireBinding(_ request: ProofLeaseRequest) throws -> SleepOverrideLeaseBinding {
        guard let binding = request.binding else {
            throw SleepOverrideLeaseError.rejected("The operation omitted its exact binding.")
        }
        return binding
    }

    func requireMilliseconds(_ request: ProofLeaseRequest) throws -> Int {
        guard let milliseconds = request.milliseconds, milliseconds >= 0 else {
            throw SleepOverrideLeaseError.rejected("Clock advancement must be non-negative.")
        }
        return milliseconds
    }

    func acknowledged(_ request: ProofLeaseRequest) -> ProofLeaseResponse {
        ProofLeaseResponse(correlationID: request.correlationID, outcome: .acknowledged)
    }

    func receiptResponse(
        _ request: ProofLeaseRequest,
        _ receipt: SleepOverrideLeaseReceipt
    ) -> ProofLeaseResponse {
        ProofLeaseResponse(
            correlationID: request.correlationID,
            outcome: .receipt,
            receipt: receipt
        )
    }

    func unauthenticated(_ request: ProofLeaseRequest) -> ProofLeaseResponse {
        ProofLeaseResponse(
            correlationID: request.correlationID,
            outcome: .error,
            error: ProofLeaseWireError(
                code: .unauthenticated,
                dispatchCertainty: .definitelyNotSent,
                detail: "The proof connector rejected the credential before service dispatch."
            )
        )
    }

    func failureResponse(
        _ request: ProofLeaseRequest,
        error: Error
    ) -> ProofLeaseResponse {
        ProofLeaseResponse(
            correlationID: request.correlationID,
            outcome: .error,
            error: wireError(error)
        )
    }

    func wireError(_ error: Error) -> ProofLeaseWireError {
        guard let leaseError = error as? SleepOverrideLeaseError else {
            return ProofLeaseWireError(code: .rejected, detail: error.localizedDescription)
        }
        switch leaseError {
        case .helperUnavailable(let certainty):
            return ProofLeaseWireError(
                code: .unavailable,
                dispatchCertainty: certainty,
                detail: leaseError.localizedDescription
            )
        case .unauthenticated(let certainty):
            return ProofLeaseWireError(
                code: .unauthenticated,
                dispatchCertainty: certainty,
                detail: leaseError.localizedDescription
            )
        case .interruptedAfterPossibleDispatch:
            return ProofLeaseWireError(code: .interrupted, detail: leaseError.localizedDescription)
        case .cleanupRequired(let detail):
            return ProofLeaseWireError(code: .cleanupRequired, detail: detail)
        case .invalidReceipt:
            return ProofLeaseWireError(code: .invalidReceipt, detail: leaseError.localizedDescription)
        case .rejected(let detail):
            return ProofLeaseWireError(code: .rejected, detail: detail)
        case .invalidResponse(let detail):
            return ProofLeaseWireError(code: .invalidResponse, detail: detail)
        }
    }
}

@main
private enum SleepOverrideLeaseProofHelperMain {
    static func main() async {
        do {
            let arguments = try HelperArguments(CommandLine.arguments)
            let store = FileSleepOverrideLeaseStateStore(
                policy: .testSafe(rootDirectory: arguments.stateRootURL)
            )
            let backend = ProofPowerBackend(
                executableURL: arguments.powerExecutableURL,
                stateURL: arguments.powerStateURL,
                traceURL: arguments.powerTraceURL,
                controlURL: arguments.powerControlURL
            )
            let clock = ProofDeterministicLeaseClock(traceURL: arguments.clockTraceURL)
            let selectedPoint = arguments.checkpoint.flatMap(
                SleepOverrideLeaseTransitionPoint.init(rawValue:)
            )
            let observer = ProofLeaseTransitionGate(
                selectedPoint: selectedPoint,
                markerURL: arguments.checkpointMarkerURL,
                gateURL: arguments.checkpointGateURL,
                traceURL: arguments.transitionTraceURL
            )
            let service = SleepOverrideLeaseService(
                store: store,
                powerBackend: backend,
                clock: clock,
                transitionObserver: observer
            )
            try await service.reconcileOnStartup()
            let connector = ProofLeaseConnector(
                service: service,
                clock: clock,
                checkpoint: ConnectorCheckpoint(arguments: arguments)
            )
            try await serve(arguments: arguments, connector: connector)
        } catch {
            FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8))
            exit(2)
        }
    }

    private static func serve(
        arguments: HelperArguments,
        connector: ProofLeaseConnector
    ) async throws {
        let listener = try ProofUnixListener(path: arguments.socketPath)
        defer { listener.close() }
        while true {
            let descriptor = try listener.acceptConnection()
            Task.detached {
                await connector.handle(descriptor: descriptor)
            }
        }
    }
}
