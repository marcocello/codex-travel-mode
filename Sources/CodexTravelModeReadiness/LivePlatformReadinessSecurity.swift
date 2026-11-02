import Foundation
import Security

public final class LivePlatformSecCodeIdentityInspector:
    LiveObservedCodeIdentityInspecting, @unchecked Sendable {
    private let processResolver: any LivePlatformProcessResolving

    public init(
        processResolver: any LivePlatformProcessResolving = LivePlatformProcessResolver()
    ) {
        self.processResolver = processResolver
    }

    public func runningIdentity(pid: Int32) throws -> LiveObservedCodeIdentity {
        var code: SecCode?
        let attributes = [kSecGuestAttributePid: pid] as CFDictionary
        let status = SecCodeCopyGuestWithAttributes(nil, attributes, [], &code)
        guard status == errSecSuccess, let code else {
            throw statusError("SecCodeCopyGuestWithAttributes", status)
        }
        let process = try processResolver.process(pid: pid)
        let identity = try makeIdentity(
            code: staticCode(from: code),
            pid: pid,
            start: process.startIdentity
        )
        guard identity.executableURL == process.executableURL else {
            throw LivePlatformReadinessError.identityMismatch(
                "SecCode and proc executable paths differ"
            )
        }
        return identity
    }

    public func embeddedIdentity(at url: URL) throws -> LiveObservedCodeIdentity {
        let code = try staticCode(at: url)
        let validity = SecStaticCodeCheckValidity(code, [], nil)
        guard validity == errSecSuccess else {
            throw statusError("SecStaticCodeCheckValidity", validity)
        }
        return try makeIdentity(code: code, pid: nil, start: nil)
    }

    public func requirementMatches(
        subject: LiveObservedCodeSubject,
        requirement: String
    ) throws -> Bool {
        var parsed: SecRequirement?
        let parseStatus = SecRequirementCreateWithString(
            requirement as CFString,
            [],
            &parsed
        )
        guard parseStatus == errSecSuccess, let parsed else {
            throw statusError("SecRequirementCreateWithString", parseStatus)
        }
        switch subject {
        case .runningProcess(let pid):
            var code: SecCode?
            let attributes = [kSecGuestAttributePid: pid] as CFDictionary
            let status = SecCodeCopyGuestWithAttributes(nil, attributes, [], &code)
            guard status == errSecSuccess, let code else {
                throw statusError("SecCodeCopyGuestWithAttributes", status)
            }
            return SecCodeCheckValidity(code, [], parsed) == errSecSuccess
        case .executable(let url):
            return SecStaticCodeCheckValidity(
                try staticCode(at: url),
                [],
                parsed
            ) == errSecSuccess
        }
    }

    private func staticCode(at url: URL) throws -> SecStaticCode {
        var code: SecStaticCode?
        let status = SecStaticCodeCreateWithPath(url as CFURL, [], &code)
        guard status == errSecSuccess, let code else {
            throw statusError("SecStaticCodeCreateWithPath", status)
        }
        return code
    }

    private func staticCode(from runningCode: SecCode) throws -> SecStaticCode {
        var code: SecStaticCode?
        let status = SecCodeCopyStaticCode(runningCode, [], &code)
        guard status == errSecSuccess, let code else {
            throw statusError("SecCodeCopyStaticCode", status)
        }
        return code
    }

    private func makeIdentity(
        code: SecStaticCode,
        pid: Int32?,
        start: String?
    ) throws -> LiveObservedCodeIdentity {
        var rawInformation: CFDictionary?
        let status = SecCodeCopySigningInformation(
            code,
            SecCSFlags(rawValue: UInt32(kSecCSSigningInformation)),
            &rawInformation
        )
        guard status == errSecSuccess,
              let information = rawInformation as? [CFString: Any],
              let identifier = information[kSecCodeInfoIdentifier] as? String,
              let team = information[kSecCodeInfoTeamIdentifier] as? String,
              let cdHash = information[kSecCodeInfoUnique] as? Data,
              let executable = information[kSecCodeInfoMainExecutable] as? URL else {
            throw LivePlatformReadinessError.incompleteIdentity(
                "Security signing information is incomplete"
            )
        }
        return try LiveObservedCodeIdentity(
            pid: pid,
            processStartIdentity: start,
            identifier: identifier,
            teamIdentifier: team,
            cdHash: cdHash.map { String(format: "%02x", $0) }.joined(),
            executableURL: executable,
            designatedRequirement: try designatedRequirement(code)
        )
    }

    private func designatedRequirement(_ code: SecStaticCode) throws -> String {
        var requirement: SecRequirement?
        let status = SecCodeCopyDesignatedRequirement(code, [], &requirement)
        guard status == errSecSuccess, let requirement else {
            throw statusError("SecCodeCopyDesignatedRequirement", status)
        }
        var text: CFString?
        let textStatus = SecRequirementCopyString(requirement, [], &text)
        guard textStatus == errSecSuccess, let text else {
            throw statusError("SecRequirementCopyString", textStatus)
        }
        return text as String
    }

    private func statusError(_ operation: String, _ status: OSStatus)
        -> LivePlatformReadinessError {
        .securityStatus(operation: operation, status: status)
    }
}

public struct LivePlatformApplicationIdentityValidator: Sendable {
    public static let identifier = "com.codex.travelmode"
    private let inspector: any LiveObservedCodeIdentityInspecting
    private let bundleResolver: any LivePlatformBundleExecutableResolving

    public init(
        inspector: any LiveObservedCodeIdentityInspecting,
        bundleResolver: any LivePlatformBundleExecutableResolving =
            LivePlatformBundleExecutableResolver()
    ) {
        self.inspector = inspector
        self.bundleResolver = bundleResolver
    }

    public func validate(appBundleURL: URL) throws -> LiveObservedCodeIdentity {
        let expectedExecutable = try bundleResolver.executableURL(bundleURL: appBundleURL)
        let identity = try inspector.embeddedIdentity(at: appBundleURL)
        guard identity.identifier == Self.identifier,
              !identity.teamIdentifier.isEmpty,
              identity.executableURL == expectedExecutable,
              try inspector.requirementMatches(
                  subject: .executable(appBundleURL.standardizedFileURL),
                  requirement: identity.designatedRequirement
              ) else {
            throw LivePlatformReadinessError.identityMismatch(
                "production app signing identity is invalid"
            )
        }
        return identity
    }
}
