import Foundation

public enum LivePlatformReadinessError: Error, Equatable, Sendable {
    case securityStatus(operation: String, status: Int32)
    case incompleteIdentity(String)
    case identityMismatch(String)
    case serviceNotEnabled(String)
    case processNotFound(String)
    case processAmbiguous(path: String, count: Int)
    case unsafeJournal(String)
    case uiReadback(String)
}

public struct LivePlatformResolvedProcess: Equatable, Sendable {
    public let pid: Int32
    public let startIdentity: String
    public let executableURL: URL

    public init(pid: Int32, startIdentity: String, executableURL: URL) throws {
        guard pid > 0, !startIdentity.isEmpty, executableURL.path.hasPrefix("/") else {
            throw LivePlatformReadinessError.processNotFound("invalid process identity")
        }
        self.pid = pid
        self.startIdentity = startIdentity
        self.executableURL = executableURL.standardizedFileURL
    }
}

public protocol LivePlatformProcessResolving: Sendable {
    func process(pid: Int32) throws -> LivePlatformResolvedProcess
    func processes(executableURL: URL) throws -> [LivePlatformResolvedProcess]
}

public protocol LivePlatformBundleExecutableResolving: Sendable {
    func executableURL(bundleURL: URL) throws -> URL
}

public struct LivePlatformBundleExecutableResolver:
    LivePlatformBundleExecutableResolving, Sendable {
    public init() {}

    public func executableURL(bundleURL: URL) throws -> URL {
        guard let executable = Bundle(url: bundleURL)?.executableURL else {
            throw LivePlatformReadinessError.identityMismatch(
                "app bundle executable is unavailable"
            )
        }
        return executable.standardizedFileURL
    }
}

public enum LivePlatformServiceStatus: String, Codable, Sendable {
    case notRegistered = "not_registered"
    case enabled
    case requiresApproval = "requires_approval"
    case notFound = "not_found"
    case unknown
}

public protocol LivePlatformServiceStatusReading: Sendable {
    func helperStatus(plistName: String) -> LivePlatformServiceStatus
}

public struct LivePlatformHelperRegistration: Equatable, Sendable {
    public let status: LivePlatformServiceStatus
    public let process: LivePlatformResolvedProcess
}

public enum LivePlatformJournalPresence: String, Codable, Sendable {
    case present
    case absent
    case indeterminate
}

public protocol LivePlatformFilePresenceInspecting: Sendable {
    func ownedRegularFilePresence(at url: URL) -> LivePlatformJournalPresence
}

public protocol LivePlatformAccessibilityTrustReading: Sendable {
    func isProcessTrusted() -> Bool
}

public enum LivePlatformLocationAuthorization: String, Codable, Sendable {
    case authorized
    case denied
    case restricted
    case notDetermined = "not_determined"
    case servicesDisabled = "services_disabled"
}

public struct LivePlatformProductionUIReadback: Equatable, Sendable {
    public let observedAtUnixMilliseconds: Int64
    public let appPID: Int32
    public let appStartIdentity: String
    public let locationAuthorization: LivePlatformLocationAuthorization
    public let committedTargetSSID: String
    public let wifiDevice: String
    public let targetVisible: Bool
    public let savedCredentialPresent: Bool
    public let codexRunning: Bool

    public init(
        observedAtUnixMilliseconds: Int64,
        appPID: Int32,
        appStartIdentity: String,
        locationAuthorization: LivePlatformLocationAuthorization,
        committedTargetSSID: String,
        wifiDevice: String,
        targetVisible: Bool,
        savedCredentialPresent: Bool,
        codexRunning: Bool
    ) throws {
        guard observedAtUnixMilliseconds >= 0, appPID > 0, !appStartIdentity.isEmpty,
              !committedTargetSSID.isEmpty, !wifiDevice.isEmpty else {
            throw LivePlatformReadinessError.uiReadback("incomplete production UI readback")
        }
        self.observedAtUnixMilliseconds = observedAtUnixMilliseconds
        self.appPID = appPID
        self.appStartIdentity = appStartIdentity
        self.locationAuthorization = locationAuthorization
        self.committedTargetSSID = committedTargetSSID
        self.wifiDevice = wifiDevice
        self.targetVisible = targetVisible
        self.savedCredentialPresent = savedCredentialPresent
        self.codexRunning = codexRunning
    }
}

public protocol LivePlatformProductionUIReading: Sendable {
    func readback(
        app: LivePlatformResolvedProcess
    ) async throws -> LivePlatformProductionUIReadback
}
