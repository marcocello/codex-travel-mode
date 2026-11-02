import Foundation
import Security

public enum SleepOverrideLeaseProductionIdentifiers {
    public static let appBundleIdentifier = "com.codex.travelmode"
    public static let helperBundleIdentifier = "com.codex.travelmode.sleep-helper"
    public static let machServiceName = "com.codex.travelmode.sleep-helper"
    public static let helperExecutableName = "codex-travel-mode-sleep-helper"
    public static let launchDaemonPlistName = "com.codex.travelmode.sleep-helper.plist"
    public static let productionStateDirectory =
        "/Library/Application Support/com.codex.travelmode/SleepOverrideLease"
    public static let productionJournalPath =
        "/Library/Application Support/com.codex.travelmode/SleepOverrideLease/active-lease.json"
    public static let productionReceiptsPath =
        "/Library/Application Support/com.codex.travelmode/SleepOverrideLease/released-receipts"
    public static let pmsetExecutablePath = "/usr/bin/pmset"
}

public enum SleepOverrideLeaseCodeSigningError: LocalizedError, Equatable, Sendable {
    case invalidTeamIdentifier
    case signingInformationUnavailable(Int32)
    case missingIdentifier
    case missingTeamIdentifier
    case unexpectedIdentifier(expected: String, actual: String)

    public var errorDescription: String? {
        switch self {
        case .invalidTeamIdentifier:
            "The code-signing team identifier is invalid."
        case .signingInformationUnavailable(let status):
            "Code-signing information is unavailable (OSStatus \(status))."
        case .missingIdentifier:
            "The signed executable has no code-signing identifier."
        case .missingTeamIdentifier:
            "The signed executable has no team identifier."
        case .unexpectedIdentifier(let expected, let actual):
            "The signed executable identifier is '\(actual)', expected '\(expected)'."
        }
    }
}

public enum SleepOverrideLeaseCodeSigningRequirements {
    public static func appRequirement(teamIdentifier: String) throws -> String {
        try requirement(
            bundleIdentifier: SleepOverrideLeaseProductionIdentifiers.appBundleIdentifier,
            teamIdentifier: teamIdentifier
        )
    }

    public static func helperRequirement(teamIdentifier: String) throws -> String {
        try requirement(
            bundleIdentifier: SleepOverrideLeaseProductionIdentifiers.helperBundleIdentifier,
            teamIdentifier: teamIdentifier
        )
    }

    private static func requirement(
        bundleIdentifier: String,
        teamIdentifier: String
    ) throws -> String {
        guard teamIdentifier.range(
            of: #"^[A-Z0-9]{10}$"#,
            options: .regularExpression
        ) != nil else {
            throw SleepOverrideLeaseCodeSigningError.invalidTeamIdentifier
        }
        return "anchor apple generic and identifier \"\(bundleIdentifier)\" "
            + "and certificate leaf[subject.OU] = \"\(teamIdentifier)\""
    }
}

public struct SleepOverrideLeaseCodeSigningIdentity: Equatable, Sendable {
    public var identifier: String
    public var teamIdentifier: String

    public init(identifier: String, teamIdentifier: String) {
        self.identifier = identifier
        self.teamIdentifier = teamIdentifier
    }

    public static func current(
        expectedIdentifier: String? = nil
    ) throws -> SleepOverrideLeaseCodeSigningIdentity {
        var code: SecCode?
        let copyStatus = SecCodeCopySelf([], &code)
        guard copyStatus == errSecSuccess, let code else {
            throw SleepOverrideLeaseCodeSigningError.signingInformationUnavailable(copyStatus)
        }

        var staticCode: SecStaticCode?
        let staticStatus = SecCodeCopyStaticCode(code, [], &staticCode)
        guard staticStatus == errSecSuccess, let staticCode else {
            throw SleepOverrideLeaseCodeSigningError.signingInformationUnavailable(staticStatus)
        }

        var rawInformation: CFDictionary?
        let informationStatus = SecCodeCopySigningInformation(
            staticCode,
            SecCSFlags(rawValue: UInt32(kSecCSSigningInformation)),
            &rawInformation
        )
        guard informationStatus == errSecSuccess,
              let information = rawInformation as? [CFString: Any] else {
            throw SleepOverrideLeaseCodeSigningError.signingInformationUnavailable(
                informationStatus
            )
        }
        guard let identifier = information[kSecCodeInfoIdentifier] as? String else {
            throw SleepOverrideLeaseCodeSigningError.missingIdentifier
        }
        guard let teamIdentifier = information[kSecCodeInfoTeamIdentifier] as? String else {
            throw SleepOverrideLeaseCodeSigningError.missingTeamIdentifier
        }
        if let expectedIdentifier, identifier != expectedIdentifier {
            throw SleepOverrideLeaseCodeSigningError.unexpectedIdentifier(
                expected: expectedIdentifier,
                actual: identifier
            )
        }
        _ = try SleepOverrideLeaseCodeSigningRequirements.helperRequirement(
            teamIdentifier: teamIdentifier
        )
        return SleepOverrideLeaseCodeSigningIdentity(
            identifier: identifier,
            teamIdentifier: teamIdentifier
        )
    }
}
