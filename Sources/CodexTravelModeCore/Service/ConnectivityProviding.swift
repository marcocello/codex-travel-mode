import Foundation

public protocol LidStateProviding: Sendable {
    func readLidState(timeout: Duration) async -> ProviderReading<LidState>
}

public protocol WiFiConnectivityProviding: Sendable {
    func readConnectivity(device: String, timeout: Duration) async -> WiFiConnectivityObservation
}

public protocol OutboundReachabilityChecking: Sendable {
    func check(timeout: Duration, nonce: String) async -> ReachabilityResult
}

public enum ReachabilityFailure: Equatable, Sendable {
    case timedOut
    case cancelled
    case transport
    case nonHTTPResponse
    case rejectedStatus(Int)
}

public enum ReachabilityResult: Equatable, Sendable {
    case reachable(statusCode: Int)
    case failed(ReachabilityFailure)
}
