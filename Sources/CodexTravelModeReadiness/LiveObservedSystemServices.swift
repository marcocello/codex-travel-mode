import Foundation
import CodexTravelModeSleepLeaseXPC

public struct LiveObservedHelperRegistrationReader: Sendable {
    public static let serviceName =
        SleepOverrideLeaseProductionIdentifiers.machServiceName

    private let runner: any LiveObservedCommandRunning

    public init(runner: any LiveObservedCommandRunning) {
        self.runner = runner
    }

    public func runningPID() throws -> Int32 {
        let result = try runner.run(LiveObservedSystemQuery.helperRegistration.command)
        guard result.exitStatus == 0, result.standardError.isEmpty else {
            throw LiveObservedSystemError.indeterminate(
                "helper registration is unavailable"
            )
        }
        return try LiveObservedSystemParsers.runningHelperPID(
            result.standardOutput,
            serviceName: Self.serviceName
        )
    }
}

public struct LiveObservedHelperJournalReader: Sendable {
    public static let path =
        "/Library/Application Support/com.codex.travelmode/SleepOverrideLease/active-lease.json"
    public static let exactNoPasswordGrant =
        "(root) NOPASSWD: /usr/bin/test -e \(path)"
    public static let exactEscapedNoPasswordGrant =
        "(root) NOPASSWD: /usr/bin/test -e "
        + #"/Library/Application\ Support/com.codex.travelmode/SleepOverrideLease/active-lease.json"#

    private let runner: any LiveObservedCommandRunning

    public init(runner: any LiveObservedCommandRunning) {
        self.runner = runner
    }

    public func observe() throws -> LiveObservedJournalState {
        let authorization = LiveObservedCommand(
            executable: "/usr/bin/sudo",
            arguments: ["-n", "-l", "--", "/usr/bin/test", "-e", Self.path]
        )
        let authorizationResult = try runner.run(authorization)
        guard authorizationResult.exitStatus == 0,
              Self.hasExactNoPasswordGrant(
                  standardOutput: authorizationResult.standardOutput,
                  standardError: authorizationResult.standardError
              ) else {
            return .unauthorized
        }
        let query = LiveObservedCommand(
            executable: "/usr/bin/sudo",
            arguments: ["-n", "--", "/usr/bin/test", "-e", Self.path]
        )
        let result = try runner.run(query)
        let silent = result.standardOutput.isEmpty && result.standardError.isEmpty
        switch result.exitStatus {
        case 0 where silent: return .present
        case 1 where silent: return .absent
        default: return .indeterminate
        }
    }

    public static func hasExactNoPasswordGrant(
        standardOutput: String,
        standardError: String
    ) -> Bool {
        guard standardError.isEmpty else { return false }
        return standardOutput.split(whereSeparator: \.isNewline).contains { line in
            let normalized = line.trimmingCharacters(in: .whitespaces)
            return normalized == exactNoPasswordGrant
                || normalized == exactEscapedNoPasswordGrant
        }
    }
}

public struct LiveObservedProductionSigningIdentities: Equatable, Sendable {
    public let app: LiveObservedCodeIdentity
    public let helper: LiveObservedCodeIdentity

    public init(app: LiveObservedCodeIdentity, helper: LiveObservedCodeIdentity) {
        self.app = app
        self.helper = helper
    }
}

public struct LiveObservedProductionCodeSigningValidator: Sendable {
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

    public func validate(
        appBundleURL: URL,
        embeddedHelperURL: URL
    ) throws -> LiveObservedProductionSigningIdentities {
        let appExecutable = try bundleResolver.executableURL(bundleURL: appBundleURL)
        let app = try inspector.embeddedIdentity(at: appBundleURL)
        let helper = try inspector.embeddedIdentity(at: embeddedHelperURL)
        guard app.identifier == SleepOverrideLeaseProductionIdentifiers.appBundleIdentifier,
              helper.identifier
                == SleepOverrideLeaseProductionIdentifiers.helperBundleIdentifier,
              !app.teamIdentifier.isEmpty,
              app.teamIdentifier == helper.teamIdentifier,
              app.executableURL == appExecutable,
              helper.executableURL == embeddedHelperURL.standardizedFileURL else {
            throw LiveObservedSystemError.identityMismatch(
                "production app/helper signing fields do not match"
            )
        }
        let appRequirement = try SleepOverrideLeaseCodeSigningRequirements.appRequirement(
            teamIdentifier: app.teamIdentifier
        )
        let helperRequirement = try SleepOverrideLeaseCodeSigningRequirements.helperRequirement(
            teamIdentifier: app.teamIdentifier
        )
        guard try inspector.requirementMatches(
            subject: .executable(appBundleURL.standardizedFileURL),
            requirement: appRequirement
        ), try inspector.requirementMatches(
            subject: .executable(helper.executableURL),
            requirement: helperRequirement
        ) else {
            throw LiveObservedSystemError.identityMismatch(
                "production app/helper requirements do not match"
            )
        }
        return LiveObservedProductionSigningIdentities(app: app, helper: helper)
    }
}

public struct LiveObservedHelperIdentityValidator: Sendable {
    public static let identifier = "com.codex.travelmode.sleep-helper"
    private let inspector: any LiveObservedCodeIdentityInspecting

    public init(inspector: any LiveObservedCodeIdentityInspecting) {
        self.inspector = inspector
    }

    public func validate(
        runningPID: Int32,
        embeddedHelperURL: URL,
        appTeamIdentifier: String
    ) throws -> LiveObservedCodeIdentity {
        guard runningPID > 0, !appTeamIdentifier.isEmpty else {
            throw LiveObservedSystemError.identityMismatch("invalid helper validation input")
        }
        let embedded = try inspector.embeddedIdentity(at: embeddedHelperURL)
        let running = try inspector.runningIdentity(pid: runningPID)
        guard embedded.identifier == Self.identifier,
              running.identifier == Self.identifier,
              embedded.teamIdentifier == appTeamIdentifier,
              running.teamIdentifier == appTeamIdentifier,
              running.cdHash == embedded.cdHash,
              running.executableURL == embedded.executableURL,
              running.pid == runningPID,
              running.processStartIdentity?.isEmpty == false else {
            throw LiveObservedSystemError.identityMismatch("dynamic helper identity changed")
        }
        let helperRequirement = try SleepOverrideLeaseCodeSigningRequirements.helperRequirement(
            teamIdentifier: appTeamIdentifier
        )
        let runningMatches = try inspector.requirementMatches(
            subject: .runningProcess(pid: runningPID),
            requirement: helperRequirement
        )
        let embeddedMatches = try inspector.requirementMatches(
            subject: .executable(embedded.executableURL),
            requirement: helperRequirement
        )
        guard runningMatches, embeddedMatches else {
            throw LiveObservedSystemError.identityMismatch("helper requirements are not reciprocal")
        }
        return running
    }
}
