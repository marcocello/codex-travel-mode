import Foundation

public struct HandoffRetryPolicy: Equatable, Sendable {
    public let maxAttempts: Int
    public let episodeBudget: Duration
    public let providerTimeout: Duration
    public let powerTimeout: Duration
    public let associationTimeout: Duration
    public let probeTimeout: Duration
    public let backoffs: [Duration]
    public let recoveryCooldown: Duration

    public init(
        maxAttempts: Int = 3,
        episodeBudget: Duration = .seconds(30),
        providerTimeout: Duration = .seconds(2),
        powerTimeout: Duration = .seconds(3),
        associationTimeout: Duration = .seconds(5),
        probeTimeout: Duration = .seconds(2),
        backoffs: [Duration] = [.seconds(1), .seconds(2)],
        recoveryCooldown: Duration = .seconds(5)
    ) {
        self.maxAttempts = max(1, maxAttempts)
        self.episodeBudget = episodeBudget
        self.providerTimeout = providerTimeout
        self.powerTimeout = powerTimeout
        self.associationTimeout = associationTimeout
        self.probeTimeout = probeTimeout
        self.backoffs = backoffs
        self.recoveryCooldown = recoveryCooldown
    }

    public static let production = HandoffRetryPolicy()
}

public struct HandoffSessionContext: Sendable {
    public let sessionID: String
    public let generation: UUID
    public let device: String
    public let targetSSID: ExactUTF8String
    public let password: String

    public init(
        sessionID: String,
        generation: UUID = UUID(),
        device: String,
        targetSSID: ExactUTF8String,
        password: String
    ) {
        self.sessionID = sessionID
        self.generation = generation
        self.device = device
        self.targetSSID = targetSSID
        self.password = password
    }
}

/// Exact ownership identity for one internet-handoff episode.
///
/// The durable Travel Mode session identifier alone is not sufficient because
/// multiple UI generations and multiple handoff episodes can run inside the
/// same session. The real session owner uses the complete token as a mutation
/// capability and rejects older generations or episodes.
public struct HandoffEpisodeToken: Codable, Equatable, Hashable, Sendable {
    public let sessionID: String
    public let generation: UUID
    public let episodeID: String

    public init(sessionID: String, generation: UUID, episodeID: String) {
        self.sessionID = sessionID
        self.generation = generation
        self.episodeID = episodeID
    }

    public init(context: HandoffSessionContext, episodeID: String) {
        self.init(
            sessionID: context.sessionID,
            generation: context.generation,
            episodeID: episodeID
        )
    }
}

/// Identifies one concrete mutation attempt inside an authorized episode.
public struct HandoffOperationIdentity: Codable, Equatable, Hashable, Sendable {
    public let episode: HandoffEpisodeToken
    public let attempt: Int

    public init(episode: HandoffEpisodeToken, attempt: Int) {
        self.episode = episode
        self.attempt = attempt
    }
}

public enum HandoffTrigger: String, Codable, Equatable, Sendable {
    case initiallyClosed = "initially_closed"
    case lidClosed = "lid_closed"
    case closedPathLost = "closed_path_lost"
    case openDisconnection = "open_disconnection"
    case explicitRetry = "explicit_retry"

    public var isClosedOwned: Bool {
        switch self {
        case .initiallyClosed, .lidClosed, .closedPathLost:
            return true
        case .openDisconnection, .explicitRetry:
            return false
        }
    }
}

public enum HandoffFailureKind: String, Codable, Equatable, Sendable {
    case lidProviderFailed = "lid_provider_failed"
    case connectivityProviderFailed = "connectivity_provider_failed"
    case wifiPowerCommandFailed = "wifi_power_command_failed"
    case associationCommandFailed = "association_command_failed"
    case reachabilityFailed = "reachability_failed"
    case partialConnectivity = "partial_connectivity"
    case staleSession = "stale_session"
    case invalidConfiguration = "invalid_configuration"
    case deadlineExceeded = "deadline_exceeded"
    case cancelled
}

public struct HandoffFailure: Equatable, Sendable {
    public let kind: HandoffFailureKind
    public let detail: String
    public let retryable: Bool

    public init(kind: HandoffFailureKind, detail: String, retryable: Bool) {
        self.kind = kind
        self.detail = detail
        self.retryable = retryable
    }
}

public enum TravelInternetRuntimeState: Equatable, Sendable {
    case inactive
    case waitingForConnection
    case preservingCurrentNetwork(ExactUTF8String)
    case handoffPending(episodeID: String, trigger: HandoffTrigger)
    case associating(episodeID: String, attempt: Int)
    case verifying(episodeID: String, attempt: Int)
    case connectedViaConfiguredHotspot(ExactUTF8String)
    case retrying(episodeID: String, nextAttempt: Int, delay: Duration)
    case failed(HandoffFailure)
}

public struct TravelInternetStatePublication: Equatable, Sendable {
    public let sessionID: String?
    public let generation: UUID?
    public let episodeID: String?
    public let state: TravelInternetRuntimeState

    public init(
        sessionID: String?,
        generation: UUID?,
        episodeID: String?,
        state: TravelInternetRuntimeState
    ) {
        self.sessionID = sessionID
        self.generation = generation
        self.episodeID = episodeID
        self.state = state
    }
}

public enum HandoffPathClassification: Equatable, Sendable {
    case healthyTarget(ExactUTF8String)
    case healthyOther(ExactUTF8String)
    case ordinaryDisconnected
    case partial(HandoffFailure)
    case providerFailure(HandoffFailure)

    public var isHealthyTarget: Bool {
        if case .healthyTarget = self { return true }
        return false
    }

    public var isAuthoritativelyHealthy: Bool {
        switch self {
        case .healthyTarget, .healthyOther:
            return true
        case .ordinaryDisconnected, .partial, .providerFailure:
            return false
        }
    }
}

public struct HandoffPathEvaluation: Equatable, Sendable {
    public let observation: WiFiConnectivityObservation
    public let reachability: ReachabilityResult?
    public let classification: HandoffPathClassification

    public init(
        observation: WiFiConnectivityObservation,
        reachability: ReachabilityResult?,
        classification: HandoffPathClassification
    ) {
        self.observation = observation
        self.reachability = reachability
        self.classification = classification
    }
}

public protocol HandoffScheduling: Sendable {
    func now() async -> Duration
    func sleep(for duration: Duration) async throws
}

public final class ContinuousHandoffScheduler: HandoffScheduling, @unchecked Sendable {
    private let clock = ContinuousClock()
    private let origin: ContinuousClock.Instant

    public init() {
        origin = clock.now
    }

    public func now() async -> Duration {
        origin.duration(to: clock.now)
    }

    public func sleep(for duration: Duration) async throws {
        try await clock.sleep(for: duration)
    }
}

func handoffBoundedTimeout(
    _ desired: Duration,
    deadline: Duration,
    now: Duration
) -> Duration? {
    let remaining = deadline - now
    guard remaining > .zero else { return nil }
    return min(desired, remaining)
}
