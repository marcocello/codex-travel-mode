import Foundation
import XCTest
@testable import CodexTravelModeReadiness
import CodexTravelModeSleepLeaseXPC

final class ReadinessCoreHardeningTests: XCTestCase {
    func testSudoAuthorizationRequiresExactNoPasswordGrantAndSilentDiagnostics() {
        let raw = LiveObservedHelperJournalReader.exactNoPasswordGrant
        let escaped = LiveObservedHelperJournalReader.exactEscapedNoPasswordGrant
        XCTAssertTrue(LiveObservedHelperJournalReader.hasExactNoPasswordGrant(
            standardOutput: "sudo heading\n    \(raw)\n",
            standardError: ""
        ))
        XCTAssertTrue(LiveObservedHelperJournalReader.hasExactNoPasswordGrant(
            standardOutput: "sudo heading\n    \(escaped)\n",
            standardError: ""
        ))
        XCTAssertFalse(LiveObservedHelperJournalReader.hasExactNoPasswordGrant(
            standardOutput: raw,
            standardError: "sudo: warning"
        ))
        XCTAssertFalse(LiveObservedHelperJournalReader.hasExactNoPasswordGrant(
            standardOutput: "(root) NOPASSWD: ALL\n",
            standardError: ""
        ))
        XCTAssertFalse(LiveObservedHelperJournalReader.hasExactNoPasswordGrant(
            standardOutput: "(root) PASSWD: /usr/bin/test -e "
                + LiveObservedHelperJournalReader.path,
            standardError: ""
        ))
    }

    func testProductionSigningRequiresExactReciprocalAppAndHelperRequirements() throws {
        let appURL = URL(fileURLWithPath: "/Applications/Codex Travel Mode.app")
        let helperURL = appURL.appendingPathComponent(
            "Contents/Resources/codex-travel-mode-sleep-helper"
        )
        let app = try identity(
            identifier: SleepOverrideLeaseProductionIdentifiers.appBundleIdentifier,
            team: "TEAM123456",
            url: appURL.appendingPathComponent("Contents/MacOS/codex-travel-mode")
        )
        let helper = try identity(
            identifier: SleepOverrideLeaseProductionIdentifiers.helperBundleIdentifier,
            team: "TEAM123456",
            url: helperURL
        )
        let inspector = HardeningIdentityInspector(identities: [
            appURL.standardizedFileURL.path: app,
            helperURL.standardizedFileURL.path: helper,
        ])
        let result = try LiveObservedProductionCodeSigningValidator(
            inspector: inspector,
            bundleResolver: HardeningBundleResolver(executableURL: app.executableURL)
        ).validate(appBundleURL: appURL, embeddedHelperURL: helperURL)

        XCTAssertEqual(result, LiveObservedProductionSigningIdentities(app: app, helper: helper))
        XCTAssertEqual(inspector.requirements, [
            HardeningRequirementCheck(
                subject: .executable(appURL.standardizedFileURL),
                requirement: try SleepOverrideLeaseCodeSigningRequirements.appRequirement(
                    teamIdentifier: "TEAM123456"
                )
            ),
            HardeningRequirementCheck(
                subject: .executable(helperURL.standardizedFileURL),
                requirement: try SleepOverrideLeaseCodeSigningRequirements.helperRequirement(
                    teamIdentifier: "TEAM123456"
                )
            ),
        ])
        XCTAssertFalse(inspector.requirements[0].requirement.contains("designated"))
        XCTAssertNotEqual(
            inspector.requirements[0].requirement,
            inspector.requirements[1].requirement
        )
    }

    func testProductionSigningRejectsWrongIdentifierTeamAndRequirement() throws {
        let appURL = URL(fileURLWithPath: "/Applications/Codex Travel Mode.app")
        let helperURL = appURL.appendingPathComponent("Contents/Resources/helper")
        let validApp = try identity(
            identifier: SleepOverrideLeaseProductionIdentifiers.appBundleIdentifier,
            team: "TEAM123456",
            url: appURL.appendingPathComponent("Contents/MacOS/codex-travel-mode")
        )

        for helper in [
            try identity(identifier: "wrong.helper", team: "TEAM123456", url: helperURL),
            try identity(
                identifier: SleepOverrideLeaseProductionIdentifiers.helperBundleIdentifier,
                team: "OTHER12345",
                url: helperURL
            ),
        ] {
            let inspector = HardeningIdentityInspector(identities: [
                appURL.standardizedFileURL.path: validApp,
                helperURL.standardizedFileURL.path: helper,
            ])
            XCTAssertThrowsError(try LiveObservedProductionCodeSigningValidator(
                inspector: inspector,
                bundleResolver: HardeningBundleResolver(
                    executableURL: validApp.executableURL
                )
            ).validate(appBundleURL: appURL, embeddedHelperURL: helperURL))
            XCTAssertTrue(inspector.requirements.isEmpty)
        }

        let validHelper = try identity(
            identifier: SleepOverrideLeaseProductionIdentifiers.helperBundleIdentifier,
            team: "TEAM123456",
            url: helperURL
        )
        let requirementFailure = HardeningIdentityInspector(
            identities: [
                appURL.standardizedFileURL.path: validApp,
                helperURL.standardizedFileURL.path: validHelper,
            ],
            matchingRequirements: false
        )
        XCTAssertThrowsError(try LiveObservedProductionCodeSigningValidator(
            inspector: requirementFailure,
            bundleResolver: HardeningBundleResolver(executableURL: validApp.executableURL)
        ).validate(appBundleURL: appURL, embeddedHelperURL: helperURL))
    }

    func testFixedPlatformParsersRejectAmbiguityAndNoncanonicalValues() throws {
        let uuid = "6F9619FF-8B86-D011-B42D-00C04FC964FF"
        XCTAssertEqual(try LiveObservedSystemParsers.platformUUID(
            #""IOPlatformUUID" = "\#(uuid)""#
        ), uuid.lowercased())
        XCTAssertThrowsError(try LiveObservedSystemParsers.platformUUID(
            #"""
            "IOPlatformUUID" = "6F9619FF-8B86-D011-B42D-00C04FC964FF"
            "IOPlatformUUID" = "7F9619FF-8B86-D011-B42D-00C04FC964FF"
            """#
        ))
        XCTAssertEqual(
            try LiveObservedSystemParsers.hardwareModel("Mac14,7\n"),
            "Mac14,7"
        )
        XCTAssertThrowsError(try LiveObservedSystemParsers.hardwareModel("Mac14,7 extra\n"))
        XCTAssertEqual(try LiveObservedSystemParsers.processPIDs("41\n502\n"), [41, 502])
        XCTAssertThrowsError(try LiveObservedSystemParsers.processPIDs("041\n"))
        XCTAssertThrowsError(try LiveObservedSystemParsers.processPIDs("41\n41\n"))
    }

    func testPortableIdentityAndCodexQueriesAreFixedAndReadOnly() throws {
        let uuid = "6F9619FF-8B86-D011-B42D-00C04FC964FF"
        let platformRunner = HardeningCommandRunner(results: [
            .init(
                exitStatus: 0,
                standardOutput: #""IOPlatformUUID" = "\#(uuid)""#
            ),
            .init(exitStatus: 0, standardOutput: "Mac14,7\n"),
            .init(
                exitStatus: 0,
                standardOutput: "Now drawing from 'Battery Power'\n -Battery 80%; discharging\n"
            ),
            .init(exitStatus: 0, standardOutput: #""AppleClamshellState" = No"#),
        ])
        let identity = try LiveObservedReadinessPrerequisiteProbe(
            runner: platformRunner
        ).portableMacIdentity()
        XCTAssertEqual(
            identity,
            LiveObservedPortableMacIdentity(
                platformUUID: uuid.lowercased(),
                hardwareModel: "Mac14,7"
            )
        )
        XCTAssertEqual(platformRunner.commands, [
            LiveObservedSystemQuery.platformIdentity.command,
            LiveObservedSystemQuery.hardwareModel.command,
            LiveObservedSystemQuery.battery.command,
            LiveObservedSystemQuery.lid.command,
        ])

        let codexRunner = HardeningCommandRunner(results: [
            .init(exitStatus: 0, standardOutput: "91\n92\n")
        ])
        XCTAssertEqual(
            try LiveObservedReadinessPrerequisiteProbe(
                runner: codexRunner
            ).codexProcessPIDs(),
            [91, 92]
        )
        XCTAssertEqual(codexRunner.commands, [LiveObservedSystemQuery.codexProcesses.command])

        let absent = HardeningCommandRunner(results: [.init(exitStatus: 1)])
        XCTAssertFalse(try LiveObservedReadinessPrerequisiteProbe(
            runner: absent
        ).isCodexRunning())
        XCTAssertTrue(LiveObservedFixedCommandRunner.isAllowed(
            LiveObservedSystemQuery.platformIdentity.command
        ))
        XCTAssertTrue(LiveObservedFixedCommandRunner.isAllowed(
            LiveObservedSystemQuery.hardwareModel.command
        ))
        XCTAssertTrue(LiveObservedFixedCommandRunner.isAllowed(
            LiveObservedSystemQuery.codexProcesses.command
        ))
        XCTAssertFalse(LiveObservedFixedCommandRunner.isAllowed(
            LiveObservedCommand(executable: "/usr/bin/pgrep", arguments: ["-f", "Codex"])
        ))
    }

    func testHelperRegistrationUsesExactSystemLaunchctlReadback() throws {
        let output = """
        system/com.codex.travelmode.sleep-helper = {
            active count = 1
            state = running
            pid = 912
        }
        """
        let runner = HardeningCommandRunner(results: [
            .init(exitStatus: 0, standardOutput: output)
        ])
        XCTAssertEqual(
            try LiveObservedHelperRegistrationReader(runner: runner).runningPID(),
            912
        )
        XCTAssertEqual(runner.commands, [LiveObservedSystemQuery.helperRegistration.command])
        XCTAssertTrue(LiveObservedFixedCommandRunner.isAllowed(
            LiveObservedSystemQuery.helperRegistration.command
        ))
        XCTAssertThrowsError(try LiveObservedSystemParsers.runningHelperPID(
            output.replacingOccurrences(of: "state = running", with: "state = waiting"),
            serviceName: LiveObservedHelperRegistrationReader.serviceName
        ))
        XCTAssertThrowsError(try LiveObservedSystemParsers.runningHelperPID(
            output.replacingOccurrences(
                of: "com.codex.travelmode.sleep-helper",
                with: "com.codex.travelmode.other-helper"
            ),
            serviceName: LiveObservedHelperRegistrationReader.serviceName
        ))
    }

    func testAccessibilityUIReaderUsesExactPIDAndSemanticStatusValues() async throws {
        let app = try LivePlatformResolvedProcess(
            pid: 712,
            startIdentity: "start-712",
            executableURL: URL(
                fileURLWithPath: "/Applications/Codex Travel Mode.app/Contents/MacOS/"
                    + "codex-travel-mode"
            )
        )
        let semanticReader = HardeningAXSemanticReader(values: [
            "travel.status.committed-hotspot": "Example’s iPhone",
            "travel.status.wifi-device": "en0",
            "travel.status.location-authorization": "completed",
            "travel.status.target-visible": "true",
            "travel.status.saved-credential": "true",
            "travel.status.codex-running": "true",
        ])
        let processResolver = HardeningProcessResolver(app)
        let reader = LivePlatformProductionUIAXReader(
            semanticReader: semanticReader,
            processResolver: processResolver,
            clock: HardeningClock(now: 4_000)
        )
        let readback = try await reader.readback(app: app)
        XCTAssertEqual(semanticReader.pids, [712])
        XCTAssertEqual(processResolver.pids, [712, 712])
        XCTAssertEqual(readback.appPID, 712)
        XCTAssertEqual(readback.appStartIdentity, "start-712")
        XCTAssertEqual(readback.observedAtUnixMilliseconds, 4_000)
        XCTAssertEqual(readback.locationAuthorization, .authorized)
        XCTAssertEqual(readback.committedTargetSSID, "Example’s iPhone")
        XCTAssertEqual(readback.wifiDevice, "en0")
        XCTAssertTrue(readback.targetVisible)
        XCTAssertTrue(readback.savedCredentialPresent)
        XCTAssertTrue(readback.codexRunning)

        let validator = LivePlatformProductionUIValidator(reader: reader)
        let validated = try await validator.validate(
            app: app,
            expectedTargetSSID: "Example’s iPhone",
            expectedWiFiDevice: "en0"
        )
        XCTAssertEqual(validated, readback)
    }

    func testAccessibilityUIReaderAndValidatorRejectUnavailableOrFalseState() async throws {
        let app = try LivePlatformResolvedProcess(
            pid: 713,
            startIdentity: "start-713",
            executableURL: URL(fileURLWithPath: "/Applications/App.app/Contents/MacOS/App")
        )
        let unavailable = LivePlatformProductionUIAXReader(
            semanticReader: HardeningAXSemanticReader(values: [
                "travel.status.committed-hotspot": "Target",
                "travel.status.wifi-device": "en0",
                "travel.status.location-authorization": "provider_failed",
                "travel.status.target-visible": "true",
                "travel.status.saved-credential": "true",
                "travel.status.codex-running": "true",
            ]),
            processResolver: HardeningProcessResolver(app)
        )
        await XCTAssertThrowsErrorAsyncHardening {
            _ = try await unavailable.readback(app: app)
        }

        let falseCodex = LivePlatformProductionUIAXReader(
            semanticReader: HardeningAXSemanticReader(values: [
                "travel.status.committed-hotspot": "Target",
                "travel.status.wifi-device": "en0",
                "travel.status.location-authorization": "completed",
                "travel.status.target-visible": "true",
                "travel.status.saved-credential": "true",
                "travel.status.codex-running": "false",
            ]),
            processResolver: HardeningProcessResolver(app)
        )
        await XCTAssertThrowsErrorAsyncHardening {
            _ = try await LivePlatformProductionUIValidator(
                reader: falseCodex
            ).validate(
                app: app,
                expectedTargetSSID: "Target",
                expectedWiFiDevice: "en0"
            )
        }
    }

    private func identity(
        identifier: String,
        team: String,
        url: URL
    ) throws -> LiveObservedCodeIdentity {
        try LiveObservedCodeIdentity(
            pid: nil,
            processStartIdentity: nil,
            identifier: identifier,
            teamIdentifier: team,
            cdHash: "abcd",
            executableURL: url,
            designatedRequirement: "unused-designated-requirement"
        )
    }
}

private struct HardeningRequirementCheck: Equatable {
    let subject: LiveObservedCodeSubject
    let requirement: String
}

private struct HardeningBundleResolver: LivePlatformBundleExecutableResolving {
    let executableURL: URL

    func executableURL(bundleURL: URL) throws -> URL { executableURL }
}

private final class HardeningIdentityInspector:
    LiveObservedCodeIdentityInspecting, @unchecked Sendable {
    private let identities: [String: LiveObservedCodeIdentity]
    private let matchingRequirements: Bool
    private(set) var requirements: [HardeningRequirementCheck] = []

    init(
        identities: [String: LiveObservedCodeIdentity],
        matchingRequirements: Bool = true
    ) {
        self.identities = identities
        self.matchingRequirements = matchingRequirements
    }

    func runningIdentity(pid: Int32) throws -> LiveObservedCodeIdentity {
        throw LiveObservedSystemError.identityMismatch("unused running identity")
    }

    func embeddedIdentity(at url: URL) throws -> LiveObservedCodeIdentity {
        guard let identity = identities[url.standardizedFileURL.path] else {
            throw LiveObservedSystemError.identityMismatch("missing embedded identity")
        }
        return identity
    }

    func requirementMatches(
        subject: LiveObservedCodeSubject,
        requirement: String
    ) throws -> Bool {
        requirements.append(HardeningRequirementCheck(
            subject: subject,
            requirement: requirement
        ))
        return matchingRequirements
    }
}

private final class HardeningCommandRunner:
    LiveObservedCommandRunning, @unchecked Sendable {
    private var results: [LiveObservedCommandResult]
    private(set) var commands: [LiveObservedCommand] = []

    init(results: [LiveObservedCommandResult]) {
        self.results = results
    }

    func run(_ command: LiveObservedCommand) throws -> LiveObservedCommandResult {
        commands.append(command)
        return results.removeFirst()
    }
}

private final class HardeningAXSemanticReader:
    LivePlatformAXSemanticReading, @unchecked Sendable {
    let values: [String: String]
    private(set) var pids: [Int32] = []

    init(values: [String: String]) {
        self.values = values
    }

    func semanticValues(appPID: Int32) throws -> [String: String] {
        pids.append(appPID)
        return values
    }
}

private final class HardeningProcessResolver:
    LivePlatformProcessResolving, @unchecked Sendable {
    let processValue: LivePlatformResolvedProcess
    private(set) var pids: [Int32] = []

    init(_ processValue: LivePlatformResolvedProcess) {
        self.processValue = processValue
    }

    func process(pid: Int32) throws -> LivePlatformResolvedProcess {
        pids.append(pid)
        return processValue
    }

    func processes(executableURL: URL) throws -> [LivePlatformResolvedProcess] {
        [processValue]
    }
}

private struct HardeningClock: LiveProviderClock {
    let now: Int64

    func nowUnixMilliseconds() -> Int64 { now }
}

private func XCTAssertThrowsErrorAsyncHardening(
    _ expression: () async throws -> Void,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        try await expression()
        XCTFail("Expected async expression to throw", file: file, line: line)
    } catch {}
}
