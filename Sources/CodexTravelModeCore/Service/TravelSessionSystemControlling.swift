import Foundation

public protocol TravelSessionSystemControlling: Sendable {
    func currentWiFiPower(device: String) async throws -> Bool
    func currentWiFiPower(device: String, timeout: Duration) async throws -> Bool
    func currentAssociatedSSID(device: String) async throws -> String?
    func currentAssociatedSSID(device: String, timeout: Duration) async throws -> String?
    func setWiFiPower(device: String, enabled: Bool) async -> CommandResult
    func setWiFiPower(
        device: String,
        enabled: Bool,
        timeout: Duration
    ) async -> CommandResult
    func associate(device: String, ssid: String, password: String?) async -> CommandResult
    func associate(
        device: String,
        ssid: String,
        password: String?,
        timeout: Duration
    ) async -> CommandResult
}

public extension TravelSessionSystemControlling {
    func currentWiFiPower(device: String, timeout: Duration) async throws -> Bool {
        try await currentWiFiPower(device: device)
    }

    func currentAssociatedSSID(device: String, timeout: Duration) async throws -> String? {
        try await currentAssociatedSSID(device: device)
    }

    func setWiFiPower(
        device: String,
        enabled: Bool,
        timeout: Duration
    ) async -> CommandResult {
        await setWiFiPower(device: device, enabled: enabled)
    }

    func associate(
        device: String,
        ssid: String,
        password: String?,
        timeout: Duration
    ) async -> CommandResult {
        await associate(device: device, ssid: ssid, password: password)
    }
}

public enum TravelSessionSystemError: LocalizedError {
    case stateUnavailable(String)
    case commandFailed(String)
    case verificationFailed(String)

    public var errorDescription: String? {
        switch self {
        case .stateUnavailable(let detail):
            "Required system state is unavailable: \(detail)"
        case .commandFailed(let detail):
            "A Travel Mode system command failed: \(detail)"
        case .verificationFailed(let detail):
            "A Travel Mode system change could not be verified: \(detail)"
        }
    }
}

public enum TravelSessionBoundary: String, Sendable {
    case leaseReceiptReturned = "lease_receipt_returned"
    case leaseAcquired = "lease_acquired"
    case sessionActive = "session_active"
    case leaseReleased = "lease_released"
    case journalCleared = "journal_cleared"
    case leaseAcknowledged = "lease_acknowledged"
    case startRejectedExistingRecovery = "start_rejected_existing_recovery"
    case afterIntentPersist = "after-intent-persist"
    case afterDispatch = "after-dispatch"
    case afterVerification = "after-verification"
    case beforeCompletionPersist = "before-completion-persist"
}

public protocol TravelSessionBoundaryObserving: Sendable {
    func reached(
        _ boundary: TravelSessionBoundary,
        sessionID: String?,
        value: String?
    ) async
}

public struct NoOpTravelSessionBoundaryObserver: TravelSessionBoundaryObserving {
    public init() {}

    public func reached(
        _ boundary: TravelSessionBoundary,
        sessionID: String?,
        value: String?
    ) async {}
}
