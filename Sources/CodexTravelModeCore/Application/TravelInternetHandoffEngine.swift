import Foundation

public enum HandoffAttemptPhase: Equatable, Sendable {
    case associating
    case verifying
}

public enum HandoffAttemptResult: Equatable, Sendable {
    case succeeded(HandoffPathEvaluation)
    case failed(HandoffFailure)
}

public final class TravelInternetHandoffEngine: Sendable {
    private let connectivityProvider: any WiFiConnectivityProviding
    private let reachabilityChecker: any OutboundReachabilityChecking
    private let sessionManager: any TravelSessionManaging
    private let policy: HandoffRetryPolicy

    public init(
        connectivityProvider: any WiFiConnectivityProviding,
        reachabilityChecker: any OutboundReachabilityChecking,
        sessionManager: any TravelSessionManaging,
        policy: HandoffRetryPolicy = .production
    ) {
        self.connectivityProvider = connectivityProvider
        self.reachabilityChecker = reachabilityChecker
        self.sessionManager = sessionManager
        self.policy = policy
    }

    public func authorizeEpisode(_ token: HandoffEpisodeToken) async -> HandoffFailure? {
        let result = await sessionManager.authorizeHandoffEpisode(token)
        if result.succeeded { return nil }
        let kind: HandoffFailureKind = result.failureCategory == .cancelled
            ? .cancelled
            : .staleSession
        return HandoffFailure(
            kind: kind,
            detail: result.detail,
            retryable: false
        )
    }

    public func finishEpisode(_ token: HandoffEpisodeToken) async {
        await sessionManager.finishHandoffEpisode(token)
    }

    public func cancelEpisode(_ token: HandoffEpisodeToken) async {
        await sessionManager.cancelHandoffEpisode(token)
    }

    public func inspect(
        context: HandoffSessionContext,
        deadline: Duration,
        scheduler: any HandoffScheduling
    ) async throws -> HandoffPathEvaluation {
        try Task.checkCancellation()
        guard let providerTimeout = await operationTimeout(
            policy.providerTimeout,
            deadline: deadline,
            scheduler: scheduler
        ) else {
            return deadlineEvaluation(device: context.device)
        }
        let first = await connectivityProvider.readConnectivity(
            device: context.device,
            timeout: providerTimeout
        )
        try Task.checkCancellation()
        let local = classifyLocal(first, context: context)
        guard case .locallyReady(let probedSSID) = local else {
            return evaluation(first, local: local, reachability: nil)
        }

        guard let probeTimeout = await operationTimeout(
            policy.probeTimeout,
            deadline: deadline,
            scheduler: scheduler
        ) else {
            return deadlineEvaluation(device: context.device, observation: first)
        }
        let nonce = UUID().uuidString
        let reachability = await reachabilityChecker.check(timeout: probeTimeout, nonce: nonce)
        try Task.checkCancellation()
        guard case .reachable = reachability else {
            return HandoffPathEvaluation(
                observation: first,
                reachability: reachability,
                classification: .partial(reachabilityFailure(reachability))
            )
        }

        guard let postTimeout = await operationTimeout(
            policy.providerTimeout,
            deadline: deadline,
            scheduler: scheduler
        ) else {
            return deadlineEvaluation(device: context.device, observation: first)
        }
        let postProbe = await connectivityProvider.readConnectivity(
            device: context.device,
            timeout: postTimeout
        )
        try Task.checkCancellation()
        let postLocal = classifyLocal(postProbe, context: context)
        guard case .locallyReady(let verifiedSSID) = postLocal else {
            return evaluation(postProbe, local: postLocal, reachability: reachability)
        }
        guard verifiedSSID == probedSSID else {
            return HandoffPathEvaluation(
                observation: postProbe,
                reachability: reachability,
                classification: .partial(HandoffFailure(
                    kind: .partialConnectivity,
                    detail: "The Wi-Fi path changed during internet verification.",
                    retryable: true
                ))
            )
        }
        return HandoffPathEvaluation(
            observation: postProbe,
            reachability: reachability,
            classification: verifiedSSID == context.targetSSID
                ? .healthyTarget(verifiedSSID)
                : .healthyOther(verifiedSSID)
        )
    }

    public func performAttempt(
        context: HandoffSessionContext,
        episode: HandoffEpisodeToken,
        attempt: Int,
        deadline: Duration,
        scheduler: any HandoffScheduling,
        phase: @escaping @Sendable (HandoffAttemptPhase) async -> Void
    ) async throws -> HandoffAttemptResult {
        guard episode.sessionID == context.sessionID,
              episode.generation == context.generation,
              !episode.episodeID.isEmpty,
              attempt > 0 else {
            return .failed(HandoffFailure(
                kind: .staleSession,
                detail: "The internet-handoff operation identity is stale.",
                retryable: false
            ))
        }
        let operation = HandoffOperationIdentity(episode: episode, attempt: attempt)
        let preflight = try await inspect(context: context, deadline: deadline, scheduler: scheduler)
        if preflight.classification.isHealthyTarget {
            return .succeeded(preflight)
        }
        if case .providerFailure(let failure) = preflight.classification {
            return .failed(failure)
        }
        guard case .value(let powered) = preflight.observation.power else {
            return .failed(providerFailure(from: preflight.observation.power.failure))
        }
        if !powered {
            let powerResult = try await enablePower(
                context: context,
                operation: operation,
                deadline: deadline,
                scheduler: scheduler
            )
            if case .failed(let failure) = powerResult {
                return .failed(failure)
            }
        }

        try Task.checkCancellation()
        await phase(.associating)
        guard let joinTimeout = await operationTimeout(
            policy.associationTimeout,
            deadline: deadline,
            scheduler: scheduler
        ) else {
            return .failed(deadlineFailure())
        }
        let joined = await sessionManager.associate(
            operation: operation,
            device: context.device,
            ssid: context.targetSSID.stringValue,
            password: context.password,
            timeout: joinTimeout
        )
        try Task.checkCancellation()
        guard joined.succeeded else {
            return .failed(commandFailure(
                .associationCommandFailed,
                result: joined,
                password: context.password
            ))
        }

        await phase(.verifying)
        let verified = try await inspect(context: context, deadline: deadline, scheduler: scheduler)
        if verified.classification.isHealthyTarget {
            return .succeeded(verified)
        }
        return .failed(failure(for: verified.classification))
    }
}

private extension TravelInternetHandoffEngine {
    enum LocalClassification {
        case locallyReady(ExactUTF8String)
        case ordinaryDisconnected
        case partial(HandoffFailure)
        case providerFailure(HandoffFailure)
    }

    func classifyLocal(
        _ observation: WiFiConnectivityObservation,
        context: HandoffSessionContext
    ) -> LocalClassification {
        if let failure = firstProviderFailure(observation) {
            return .providerFailure(providerFailure(from: failure))
        }
        guard case .value(let ssid) = observation.ssid else {
            return .providerFailure(providerFailure(from: observation.ssid.failure))
        }
        guard let ssid else { return .ordinaryDisconnected }
        guard observation.hasUsableAddress == true else {
            return .partial(HandoffFailure(
                kind: .partialConnectivity,
                detail: "The Wi-Fi device has no usable unicast address.",
                retryable: true
            ))
        }
        guard observation.defaultRouteInterface.value == context.device else {
            return .partial(HandoffFailure(
                kind: .partialConnectivity,
                detail: "The Wi-Fi device does not own the default route.",
                retryable: true
            ))
        }
        return .locallyReady(ssid)
    }

    func evaluation(
        _ observation: WiFiConnectivityObservation,
        local: LocalClassification,
        reachability: ReachabilityResult?
    ) -> HandoffPathEvaluation {
        let classification: HandoffPathClassification
        switch local {
        case .locallyReady(let ssid):
            guard case .reachable = reachability else {
                classification = .partial(reachabilityFailure(reachability))
                break
            }
            classification = .healthyOther(ssid)
        case .ordinaryDisconnected:
            classification = .ordinaryDisconnected
        case .partial(let failure):
            classification = .partial(failure)
        case .providerFailure(let failure):
            classification = .providerFailure(failure)
        }
        return HandoffPathEvaluation(
            observation: observation,
            reachability: reachability,
            classification: classification
        )
    }

    func firstProviderFailure(
        _ observation: WiFiConnectivityObservation
    ) -> ConnectivityProviderFailure? {
        observation.power.failure
            ?? observation.ssid.failure
            ?? observation.addresses.failure
            ?? observation.defaultRouteInterface.failure
    }

    enum PowerEnableResult {
        case succeeded
        case failed(HandoffFailure)
    }

    func enablePower(
        context: HandoffSessionContext,
        operation: HandoffOperationIdentity,
        deadline: Duration,
        scheduler: any HandoffScheduling
    ) async throws -> PowerEnableResult {
        guard let powerTimeout = await operationTimeout(
            policy.powerTimeout,
            deadline: deadline,
            scheduler: scheduler
        ) else {
            return .failed(deadlineFailure())
        }
        let result = await sessionManager.setWiFiPower(
            operation: operation,
            device: context.device,
            enabled: true,
            timeout: powerTimeout
        )
        try Task.checkCancellation()
        guard result.succeeded else {
            return .failed(commandFailure(
                .wifiPowerCommandFailed,
                result: result,
                password: context.password
            ))
        }
        guard let verifyTimeout = await operationTimeout(
            policy.providerTimeout,
            deadline: deadline,
            scheduler: scheduler
        ) else {
            return .failed(deadlineFailure())
        }
        let readback = await connectivityProvider.readConnectivity(
            device: context.device,
            timeout: verifyTimeout
        )
        try Task.checkCancellation()
        if let failure = readback.power.failure {
            return .failed(providerFailure(from: failure))
        }
        guard readback.power.value == true else {
            return .failed(HandoffFailure(
                kind: .wifiPowerCommandFailed,
                detail: "Wi-Fi power enablement was not verified.",
                retryable: true
            ))
        }
        return .succeeded
    }

    func operationTimeout(
        _ desired: Duration,
        deadline: Duration,
        scheduler: any HandoffScheduling
    ) async -> Duration? {
        handoffBoundedTimeout(desired, deadline: deadline, now: await scheduler.now())
    }

    func failure(for classification: HandoffPathClassification) -> HandoffFailure {
        switch classification {
        case .healthyTarget:
            return HandoffFailure(kind: .partialConnectivity, detail: "Unexpected target state.", retryable: false)
        case .healthyOther(let ssid):
            return HandoffFailure(
                kind: .partialConnectivity,
                detail: "Wi-Fi remains associated to '\(ssid.stringValue)'.",
                retryable: true
            )
        case .ordinaryDisconnected:
            return HandoffFailure(
                kind: .partialConnectivity,
                detail: "Wi-Fi is not associated.",
                retryable: true
            )
        case .partial(let failure), .providerFailure(let failure):
            return failure
        }
    }

    func providerFailure(from failure: ConnectivityProviderFailure?) -> HandoffFailure {
        HandoffFailure(
            kind: .connectivityProviderFailed,
            detail: failure?.detail ?? "Connectivity status is unavailable.",
            retryable: true
        )
    }

    func reachabilityFailure(_ result: ReachabilityResult?) -> HandoffFailure {
        HandoffFailure(
            kind: .reachabilityFailed,
            detail: "The configured Wi-Fi path did not pass the bounded internet check.",
            retryable: true
        )
    }

    func commandFailure(
        _ kind: HandoffFailureKind,
        result: CommandResult,
        password: String
    ) -> HandoffFailure {
        let safe = password.isEmpty
            ? result.detail
            : result.detail.replacingOccurrences(of: password, with: "[redacted]")
        if result.failureCategory == .staleSession {
            return HandoffFailure(kind: .staleSession, detail: safe, retryable: false)
        }
        if result.failureCategory == .cancelled {
            return HandoffFailure(kind: .cancelled, detail: safe, retryable: false)
        }
        return HandoffFailure(kind: kind, detail: safe, retryable: true)
    }

    func deadlineFailure() -> HandoffFailure {
        HandoffFailure(
            kind: .deadlineExceeded,
            detail: "The iPhone handoff did not complete within 30 seconds.",
            retryable: false
        )
    }

    func deadlineEvaluation(
        device: String,
        observation: WiFiConnectivityObservation? = nil
    ) -> HandoffPathEvaluation {
        let fallback = observation ?? WiFiConnectivityObservation(
            device: device,
            power: .failure(.init(category: .timedOut, detail: "Episode deadline expired.")),
            ssid: .failure(.init(category: .timedOut, detail: "Episode deadline expired.")),
            addresses: .failure(.init(category: .timedOut, detail: "Episode deadline expired.")),
            defaultRouteInterface: .failure(.init(category: .timedOut, detail: "Episode deadline expired."))
        )
        return HandoffPathEvaluation(
            observation: fallback,
            reachability: nil,
            classification: .providerFailure(deadlineFailure())
        )
    }
}
