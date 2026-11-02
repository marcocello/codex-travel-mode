import CryptoKit
import Darwin
import Foundation
import XCTest
@testable import CodexTravelModeReadiness

final class LiveTravelModeProofHarnessTests: XCTestCase {
    func testArmingReceiptRejectsTamperExpiryAndConcurrentReplay() throws {
        let directory = try temporaryPrivateDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let binding = try makeBinding()
        let material = try LiveProofArming.issue(
            binding: binding,
            confirmedChallenge: Data("operator-confirmed".utf8),
            nowUnixMilliseconds: 1_000
        )
        XCTAssertEqual(material.sidecarSecret.count, 32)
        XCTAssertTrue(LiveProofArming.challengeMatches(
            Data("operator-confirmed".utf8),
            receipt: material.receipt
        ))
        XCTAssertNoThrow(try LiveProofArming.verify(
            receipt: material.receipt,
            sidecarSecret: material.sidecarSecret,
            nowUnixMilliseconds: 301_000
        ))
        XCTAssertThrowsError(try LiveProofArming.verify(
            receipt: material.receipt,
            sidecarSecret: material.sidecarSecret,
            nowUnixMilliseconds: 301_001
        )) { XCTAssertEqual($0 as? LiveProofError, .expiredReceipt) }

        let tampered = LiveProofArmingReceipt(
            issuedAtUnixMilliseconds: material.receipt.issuedAtUnixMilliseconds,
            expiresAtUnixMilliseconds: material.receipt.expiresAtUnixMilliseconds,
            challengeSHA256: String(repeating: "a", count: 64),
            binding: material.receipt.binding,
            authenticationCode: material.receipt.authenticationCode
        )
        XCTAssertThrowsError(try LiveProofArming.verify(
            receipt: tampered,
            sidecarSecret: material.sidecarSecret,
            nowUnixMilliseconds: 1_001
        )) { XCTAssertEqual($0 as? LiveProofError, .authenticationFailed) }

        let sidecar = directory.appendingPathComponent("arming.secret")
        let marker = directory.appendingPathComponent("arming.consumed")
        try LiveProofArming.writeSidecar(material.sidecarSecret, to: sidecar)
        XCTAssertEqual(try permissions(sidecar), 0o600)
        let outcomes = concurrentConsume(
            receipt: material.receipt,
            sidecar: sidecar,
            marker: marker,
            now: 2_000
        )
        XCTAssertEqual(outcomes.filter(\.isSuccess).count, 1)
        XCTAssertEqual(outcomes.filter { $0.error == .receiptAlreadyConsumed }.count, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: sidecar.path))
        XCTAssertEqual(try permissions(marker), 0o600)
        XCTAssertThrowsError(try LiveProofArming.consume(
            receipt: material.receipt,
            sidecarURL: sidecar,
            markerURL: marker,
            nowUnixMilliseconds: 2_001
        )) { XCTAssertEqual($0 as? LiveProofError, .receiptAlreadyConsumed) }
    }

    func testObserverUsesExactBytesDomainsChainAndEphemeralRestartKey() throws {
        let signer = LiveProofEphemeralSigner()
        let restartedSigner = LiveProofEphemeralSigner()
        XCTAssertNotEqual(signer.publicKeyBase64URL, restartedSigner.publicKeyBase64URL)
        XCTAssertEqual(try LiveProofBase64URL.decode(
            signer.publicKeyBase64URL,
            exactByteCount: 32
        ).count, 32)

        let handshake = try LiveProofHandshakePayload(
            runID: runID,
            phase: .preflight,
            client: try processIdentity(pid: 42),
            controllerSHA256: digest("controller"),
            requestSequenceStart: 1
        )
        let signedHandshake = try signer.signedHandshake(handshake)
        let exactHandshake = try LiveProofCanonicalJSON.encode(handshake)
        XCTAssertEqual(
            try LiveProofSignatureVerifier.verify(
                signedHandshake,
                domain: .handshake,
                publicKeyBase64URL: signer.publicKeyBase64URL
            ),
            exactHandshake
        )
        XCTAssertThrowsError(try LiveProofSignatureVerifier.verify(
            signedHandshake,
            domain: .event,
            publicKeyBase64URL: signer.publicKeyBase64URL
        ))

        let payloadOne = Data(#"{"sequence":1,"text":"café"}"#.utf8)
        let payloadTwo = Data(#"{"sequence":2}"#.utf8)
        let first = try signer.eventEnvelope(payload: payloadOne, previous: nil)
        let second = try signer.eventEnvelope(payload: payloadTwo, previous: first)
        XCTAssertEqual(
            try LiveProofSignatureVerifier.verifyEventEnvelope(
                first,
                previous: nil,
                publicKeyBase64URL: signer.publicKeyBase64URL
            ),
            payloadOne
        )
        XCTAssertEqual(
            try LiveProofSignatureVerifier.verifyEventEnvelope(
                second,
                previous: first,
                publicKeyBase64URL: signer.publicKeyBase64URL
            ),
            payloadTwo
        )
        XCTAssertThrowsError(try LiveProofSignatureVerifier.verifyEventEnvelope(
            second,
            previous: nil,
            publicKeyBase64URL: signer.publicKeyBase64URL
        ))

        let seal = try LiveProofObserverSealPayload(
            runID: runID,
            observer: try processIdentity(pid: 41),
            observerPublicKey: signer.publicKeyBase64URL,
            eventCount: 2,
            finalEnvelopeSHA256: try LiveProofEphemeralSigner.envelopeSHA256(second),
            observerOwnedFiles: [
                try LiveProofArtifactManifestEntry(
                    name: "observer-events.json",
                    byteCount: 1,
                    sha256: digest("observer-events")
                ),
            ]
        )
        let signedSeal = try signer.signedSeal(seal)
        XCTAssertEqual(
            try LiveProofSignatureVerifier.verify(
                signedSeal,
                domain: .seal,
                publicKeyBase64URL: signer.publicKeyBase64URL
            ),
            try LiveProofCanonicalJSON.encode(seal)
        )
    }

    func testProviderConfigReceiptCanonicalBytesSignatureAndSequence() throws {
        let privateKey = Curve25519.Signing.PrivateKey()
        let publicKey = LiveProofBase64URL.encode(privateKey.publicKey.rawRepresentation)
        let config = try LiveProofProviderConfiguration(
            origin: "https://proof.example",
            capabilityPath: "/v1/capability",
            submitPath: "/v1/submit",
            readbackPath: "/v1/readback",
            publicKey: publicKey,
            keychain: try LiveProofProviderKeychainReference(
                service: "travel-proof",
                account: "operator"
            )
        )
        let canonicalConfig = try config.canonicalBytes
        XCTAssertEqual(
            try LiveProofProviderConfiguration.decodeCanonical(canonicalConfig),
            config
        )
        var noncanonicalConfig = canonicalConfig
        noncanonicalConfig.append(0x0a)
        XCTAssertThrowsError(
            try LiveProofProviderConfiguration.decodeCanonical(noncanonicalConfig)
        )

        let nonces = [
            LiveProofBase64URL.encode(Data(repeating: 1, count: 32)),
            LiveProofBase64URL.encode(Data(repeating: 2, count: 32)),
            LiveProofBase64URL.encode(Data(repeating: 3, count: 32)),
        ]
        let receipts = try nonces.enumerated().map { offset, nonce in
            try signedReceipt(
                sequence: offset + 1,
                nonce: nonce,
                privateKey: privateKey
            )
        }
        try LiveProofProviderReceipt.requireExactSequence(
            receipts,
            runID: runID,
            scenario: .stop,
            expectedNonces: nonces
        )
        for receipt in receipts {
            try receipt.verify(publicKeyBase64URL: publicKey)
            let encoded = try LiveProofCanonicalJSON.encode(receipt)
            XCTAssertEqual(try LiveProofProviderReceipt.decodeStrict(encoded), receipt)
        }

        let reordered = [receipts[1], receipts[0], receipts[2]]
        XCTAssertThrowsError(try LiveProofProviderReceipt.requireExactSequence(reordered))
        let changed = try LiveProofProviderReceipt(
            runID: runID,
            scenario: .stop,
            sequence: 4,
            nonce: receipts[0].nonce,
            serverReceiveUnixMilliseconds: receipts[0].serverReceiveUnixMilliseconds,
            sourceFamily: receipts[0].sourceFamily,
            sourceAddress: receipts[0].sourceAddress,
            signature: receipts[0].signature
        )
        XCTAssertThrowsError(try changed.verify(publicKeyBase64URL: publicKey))
    }

    func testSealingEnforcesModesAndDetectsPostSealTamper() throws {
        let directory = try temporaryPrivateDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let eventURL = directory.appendingPathComponent("observer-events.json")
        try Data(#"{"events":[]}"#.utf8).write(to: eventURL, options: .withoutOverwriting)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o600)],
            ofItemAtPath: eventURL.path
        )

        let manifest = try LiveProofArtifactSealer.seal(
            directory: directory,
            names: ["observer-events.json"]
        )
        XCTAssertEqual(manifest.entries.map(\.name), ["observer-events.json"])
        XCTAssertEqual(try permissions(eventURL), 0o400)
        XCTAssertNoThrow(try LiveProofArtifactSealer.verify(manifest, directory: directory))

        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o600)],
            ofItemAtPath: eventURL.path
        )
        try Data(#"{"events":[{"tampered":true}]}"#.utf8).write(
            to: eventURL,
            options: .atomic
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o400)],
            ofItemAtPath: eventURL.path
        )
        XCTAssertThrowsError(
            try LiveProofArtifactSealer.verify(manifest, directory: directory)
        ) { XCTAssertEqual($0 as? LiveProofError, .authenticationFailed) }
    }

    func testObservedSystemParsersRejectAmbiguityAndPreserveExactValues() throws {
        XCTAssertFalse(try LiveObservedSystemParsers.sleepDisabled("""
        System-wide power settings:
         SleepDisabled        0
        """))
        XCTAssertThrowsError(try LiveObservedSystemParsers.sleepDisabled("""
        SleepDisabled 0
        SleepDisabled 1
        """))
        XCTAssertEqual(
            try LiveObservedSystemParsers.battery("""
            Now drawing from 'Battery Power'
             -InternalBattery-0 87%; discharging
            """),
            try LiveObservedBattery(source: .battery, percent: 87)
        )
        XCTAssertTrue(try LiveObservedSystemParsers.lidClosed(
            #""AppleClamshellState" = Yes"#
        ))
        XCTAssertTrue(try LiveObservedSystemParsers.wifiPower(
            "Wi-Fi Power (en0): On",
            device: "en0"
        ))
        XCTAssertEqual(
            try LiveObservedSystemParsers.ssid(
                "Current Wi-Fi Network: Example’s iPhone 📱"
            ),
            "Example’s iPhone 📱"
        )
        let addresses = try LiveObservedSystemParsers.usableInterfaceAddresses("""
        en0: flags=8863<UP,BROADCAST,SMART,RUNNING,SIMPLEX,MULTICAST>
            inet 192.168.20.4 netmask 0xffffff00 broadcast 192.168.20.255
            inet6 fe80::1%en0 prefixlen 64 secured scopeid 0x7
            inet6 2606:4700::1111 prefixlen 64 autoconf secured
            status: active
        """, device: "en0")
        XCTAssertEqual(
            addresses.map(\.canonicalText),
            ["192.168.20.4", "2606:4700::1111"]
        )
        XCTAssertEqual(try LiveObservedSystemParsers.routeDevice("""
           route to: 93.184.216.34
        interface: en0
        """), "en0")
        XCTAssertEqual(
            try LiveObservedSystemParsers.processStartIdentity(
                "Wed Jul 23 14:05:06 2026\n"
            ),
            "Wed Jul 23 14:05:06 2026"
        )
    }

    func testHelperJournalUsesExactNoninteractiveAuthorizationAndPresenceQuery() throws {
        let runner = FakeObservedCommandRunner(results: [
            LiveObservedCommandResult(
                exitStatus: 0,
                standardOutput: """
                Matching Defaults entries for operator on this host:
                    env_reset

                User operator may run the following commands on this host:
                    \(LiveObservedHelperJournalReader.exactEscapedNoPasswordGrant)
                """
            ),
            LiveObservedCommandResult(exitStatus: 1),
        ])
        XCTAssertEqual(
            try LiveObservedHelperJournalReader(runner: runner).observe(),
            .absent
        )
        XCTAssertEqual(runner.commands, [
            LiveObservedCommand(
                executable: "/usr/bin/sudo",
                arguments: [
                    "-n", "-l", "--", "/usr/bin/test", "-e",
                    LiveObservedHelperJournalReader.path,
                ]
            ),
            LiveObservedCommand(
                executable: "/usr/bin/sudo",
                arguments: [
                    "-n", "--", "/usr/bin/test", "-e",
                    LiveObservedHelperJournalReader.path,
                ]
            ),
        ])

        let unauthorized = FakeObservedCommandRunner(
            results: [LiveObservedCommandResult(exitStatus: 1)]
        )
        XCTAssertEqual(
            try LiveObservedHelperJournalReader(runner: unauthorized).observe(),
            .unauthorized
        )
        XCTAssertEqual(unauthorized.commands.count, 1)

        for output in [
            "(root) PASSWD: /usr/bin/test -e \(LiveObservedHelperJournalReader.path)\n",
            "(root) NOPASSWD: ALL\n",
            "(root) NOPASSWD: /usr/bin/test -e /tmp/active-lease.json\n",
        ] {
            let rejected = FakeObservedCommandRunner(results: [
                LiveObservedCommandResult(exitStatus: 0, standardOutput: output)
            ])
            XCTAssertEqual(
                try LiveObservedHelperJournalReader(runner: rejected).observe(),
                .unauthorized
            )
            XCTAssertEqual(rejected.commands.count, 1)
        }
    }

    func testObservedSystemProbeComposesOnlyFixedReadOnlyQueries() throws {
        let runner = FakeObservedCommandRunner(results: [
            LiveObservedCommandResult(
                exitStatus: 0,
                standardOutput: "SleepDisabled 0\n"
            ),
            LiveObservedCommandResult(
                exitStatus: 0,
                standardOutput: "Now drawing from 'Battery Power'\n -Battery 90%; discharging\n"
            ),
            LiveObservedCommandResult(
                exitStatus: 0,
                standardOutput: #""AppleClamshellState" = No"#
            ),
            LiveObservedCommandResult(
                exitStatus: 0,
                standardOutput: "Wi-Fi Power (en0): On\n"
            ),
            LiveObservedCommandResult(
                exitStatus: 0,
                standardOutput: "Current Wi-Fi Network: Previous Network\n"
            ),
            LiveObservedCommandResult(
                exitStatus: 0,
                standardOutput: """
                en0: flags=8863<UP,RUNNING>
                    inet 192.168.20.4 netmask 0xffffff00
                    status: active
                """
            ),
            LiveObservedCommandResult(
                exitStatus: 0,
                standardOutput: "interface: en0\n"
            ),
        ])
        let facts = try LiveObservedSystemProbe(
            runner: runner,
            redactionSalt: Data("salt".utf8),
            clock: SequenceProviderClock([123])
        ).preflight(wifiDevice: "en0", appProcessAbsent: true)
        XCTAssertFalse(facts.sleepDisabled)
        XCTAssertEqual(facts.battery.source, .battery)
        XCTAssertFalse(facts.lidClosed)
        XCTAssertEqual(facts.defaultRouteDevice, "en0")
        XCTAssertTrue(facts.appProcessAbsent)
        XCTAssertEqual(runner.commands, [
            LiveObservedSystemQuery.pmset.command,
            LiveObservedSystemQuery.battery.command,
            LiveObservedSystemQuery.lid.command,
            LiveObservedSystemQuery.wifiPower(device: "en0").command,
            LiveObservedSystemQuery.wifiSSID(device: "en0").command,
            LiveObservedSystemQuery.interface(device: "en0").command,
            LiveObservedSystemQuery.defaultRoute.command,
        ])
        XCTAssertTrue(LiveObservedFixedCommandRunner.isAllowed(
            LiveObservedSystemQuery.helperJournalAuthorization.command
        ))
        XCTAssertFalse(LiveObservedFixedCommandRunner.isAllowed(
            LiveObservedCommand(
                executable: "/usr/sbin/networksetup",
                arguments: ["-setairportpower", "en0", "off"]
            )
        ))
    }

    func testDynamicHelperIdentityRequiresExactFieldsAndReciprocalRequirements() throws {
        let helperURL = URL(
            fileURLWithPath: "/Applications/Codex Travel Mode.app/Contents/Library/"
                + "LaunchServices/codex-travel-mode-sleep-helper"
        )
        let embedded = try LiveObservedCodeIdentity(
            pid: nil,
            processStartIdentity: nil,
            identifier: LiveObservedHelperIdentityValidator.identifier,
            teamIdentifier: "TEAM123456",
            cdHash: "abcd",
            executableURL: helperURL,
            designatedRequirement: "embedded-requirement"
        )
        let running = try LiveObservedCodeIdentity(
            pid: 800,
            processStartIdentity: "start-800",
            identifier: LiveObservedHelperIdentityValidator.identifier,
            teamIdentifier: "TEAM123456",
            cdHash: "abcd",
            executableURL: helperURL,
            designatedRequirement: "running-requirement"
        )
        let inspector = FakeCodeIdentityInspector(embedded: embedded, running: running)
        XCTAssertEqual(
            try LiveObservedHelperIdentityValidator(inspector: inspector).validate(
                runningPID: 800,
                embeddedHelperURL: helperURL,
                appTeamIdentifier: "TEAM123456"
            ),
            running
        )
        XCTAssertEqual(inspector.requirementSubjects, [
            .runningProcess(pid: 800),
            .executable(helperURL.standardizedFileURL),
        ])

        inspector.matchesRequirements = false
        XCTAssertThrowsError(
            try LiveObservedHelperIdentityValidator(inspector: inspector).validate(
                runningPID: 800,
                embeddedHelperURL: helperURL,
                appTeamIdentifier: "TEAM123456"
            )
        )
    }

    func testPlatformIdentityRegistrationAndProcessChecksUseExactBinaries() throws {
        let appBundle = URL(fileURLWithPath: "/Applications/Codex Travel Mode.app")
        let appExecutable = appBundle.appendingPathComponent(
            "Contents/MacOS/codex-travel-mode"
        )
        let appIdentity = try LiveObservedCodeIdentity(
            pid: nil,
            processStartIdentity: nil,
            identifier: LivePlatformApplicationIdentityValidator.identifier,
            teamIdentifier: "TEAM123",
            cdHash: "app-cdhash",
            executableURL: appExecutable,
            designatedRequirement: "app-requirement"
        )
        let identityInspector = FakeCodeIdentityInspector(
            embedded: appIdentity,
            running: appIdentity
        )
        XCTAssertEqual(
            try LivePlatformApplicationIdentityValidator(
                inspector: identityInspector,
                bundleResolver: FixedBundleExecutableResolver(appExecutable)
            ).validate(appBundleURL: appBundle),
            appIdentity
        )
        XCTAssertEqual(identityInspector.requirementSubjects, [
            .executable(appBundle.standardizedFileURL),
        ])

        let helperExecutable = appBundle.appendingPathComponent(
            "Contents/Resources/codex-travel-mode-sleep-helper"
        )
        let helper = try LivePlatformResolvedProcess(
            pid: 901,
            startIdentity: "start-901",
            executableURL: helperExecutable
        )
        let processResolver = FakePlatformProcessResolver(
            processesByPath: [helperExecutable.standardizedFileURL.path: [helper]]
        )
        let registration = try LivePlatformHelperRegistrationInspector(
            statusReader: FixedServiceStatusReader(.enabled),
            processResolver: processResolver
        ).inspect(embeddedHelperExecutableURL: helperExecutable)
        XCTAssertEqual(registration.status, .enabled)
        XCTAssertEqual(registration.process, helper)

        processResolver.processesByPath[helperExecutable.standardizedFileURL.path] = [
            helper,
            try LivePlatformResolvedProcess(
                pid: 902,
                startIdentity: "start-902",
                executableURL: helperExecutable
            ),
        ]
        XCTAssertThrowsError(try LivePlatformHelperRegistrationInspector(
            statusReader: FixedServiceStatusReader(.enabled),
            processResolver: processResolver
        ).inspect(embeddedHelperExecutableURL: helperExecutable)) {
            guard let error = $0 as? LivePlatformReadinessError,
                  case .processAmbiguous(_, 2) = error else {
                return XCTFail("Expected exact-path ambiguity rejection")
            }
        }
    }

    func testPlatformJournalAXAndProductionUIReadbackStayReadOnly() async throws {
        let journalInspector = FixedFilePresenceInspector(.present)
        let journalURL = URL(
            fileURLWithPath: "/Users/operator/Library/Application Support/"
                + "CodexTravelMode/travel-session-journal.json"
        )
        XCTAssertEqual(
            LivePlatformAppJournalReader(
                inspector: journalInspector,
                journalURL: journalURL
            ).presence(),
            .present
        )
        XCTAssertEqual(journalInspector.observedURLs, [journalURL.standardizedFileURL])
        XCTAssertNoThrow(try LivePlatformAccessibilityReadiness(
            reader: FixedAccessibilityReader(true)
        ).requireTrusted())
        XCTAssertThrowsError(try LivePlatformAccessibilityReadiness(
            reader: FixedAccessibilityReader(false)
        ).requireTrusted())

        let app = try LivePlatformResolvedProcess(
            pid: 501,
            startIdentity: "start-501",
            executableURL: URL(
                fileURLWithPath: "/Applications/Codex Travel Mode.app/Contents/MacOS/"
                    + "codex-travel-mode"
            )
        )
        let readback = try LivePlatformProductionUIReadback(
            observedAtUnixMilliseconds: 1_000,
            appPID: app.pid,
            appStartIdentity: app.startIdentity,
            locationAuthorization: .authorized,
            committedTargetSSID: "Example’s iPhone",
            wifiDevice: "en0",
            targetVisible: true,
            savedCredentialPresent: true,
            codexRunning: true
        )
        let validator = LivePlatformProductionUIValidator(
            reader: FixedProductionUIReader(readback)
        )
        let accepted = try await validator.validate(
            app: app,
            expectedTargetSSID: "Example’s iPhone",
            expectedWiFiDevice: "en0"
        )
        XCTAssertEqual(accepted, readback)
        await XCTAssertThrowsErrorAsync {
            _ = try await validator.validate(
                app: app,
                expectedTargetSSID: "Different iPhone",
                expectedWiFiDevice: "en0"
            )
        }
    }

    func testProviderClientUsesStrictCapabilityBearerAndExactReadbackQuery() async throws {
        let providerKey = Curve25519.Signing.PrivateKey()
        let configuration = try providerConfiguration(publicKey: providerKey.publicKey)
        let capability = try LiveProviderCapability(
            capabilityPath: configuration.capabilityPath,
            submitPath: configuration.submitPath,
            readbackPath: configuration.readbackPath,
            serverUnixMilliseconds: 1_050,
            maximumClockSkewSeconds: 1
        )
        let receipt = try signedReceipt(
            sequence: 1,
            nonce: LiveProofBase64URL.encode(Data(repeating: 7, count: 32)),
            serverReceiveUnixMilliseconds: 2_000,
            privateKey: providerKey
        )
        let receiptObject = try JSONSerialization.jsonObject(
            with: LiveProofCanonicalJSON.encode(receipt)
        )
        let readback = try JSONSerialization.data(withJSONObject: [
            "schema": LiveProviderHeartbeatReadback.schema,
            "receipts": [receiptObject],
        ], options: [.sortedKeys])
        let transport = FakeLiveProviderTransport(responses: [
            (try LiveProofCanonicalJSON.encode(capability), []),
            (readback, []),
        ])
        let client = LiveProviderClient(
            configuration: configuration,
            transport: transport,
            bearerReader: FixedBearerReader(Data("secret-token".utf8)),
            clock: SequenceProviderClock([1_000, 1_100])
        )
        let observation = try await client.capability()
        XCTAssertEqual(observation.serverMinusLocalMilliseconds, 0)
        let readbackReceipts = try await client.readback(
            runID: runID,
            scenario: .ownerDeath
        ).receipts
        XCTAssertEqual(readbackReceipts, [receipt])

        let requests = await transport.capturedRequests()
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(
            requests.map { $0.value(forHTTPHeaderField: "Authorization") },
            ["Bearer secret-token", "Bearer secret-token"]
        )
        let queryItems = try XCTUnwrap(URLComponents(
            url: try XCTUnwrap(requests[1].url),
            resolvingAgainstBaseURL: false
        )?.queryItems)
        XCTAssertEqual(queryItems, [
            URLQueryItem(name: "run_id", value: runID),
            URLQueryItem(name: "scenario", value: ReadinessScenario.ownerDeath.rawValue),
        ])

        let policy = LiveProviderURLSessionPolicy.makeConfiguration()
        XCTAssertNil(policy.urlCache)
        XCTAssertNil(policy.httpCookieStorage)
        XCTAssertNil(policy.urlCredentialStorage)
        XCTAssertFalse(policy.httpShouldSetCookies)
        XCTAssertEqual(policy.timeoutIntervalForRequest, 5)
        XCTAssertEqual(policy.timeoutIntervalForResource, 5)
        XCTAssertEqual(policy.connectionProxyDictionary?.count, 0)
    }

    func testProviderAcceptanceBindsSignedReceiptsToMetricsAndAdjacentSnapshots() throws {
        let providerKey = Curve25519.Signing.PrivateKey()
        let nonces = (1...3).map {
            LiveProofBase64URL.encode(Data(repeating: UInt8($0), count: 32))
        }
        let times: [Int64] = [1_000, 11_000, 21_000]
        let receipts = try zip(nonces.indices, nonces).map { index, nonce in
            try signedReceipt(
                sequence: index + 1,
                nonce: nonce,
                serverReceiveUnixMilliseconds: times[index],
                privateKey: providerKey
            )
        }
        let metric = LiveProviderTaskMetric(
            localAddress: "192.168.20.4",
            remoteAddress: "93.184.216.34",
            fetchStartedUnixMilliseconds: nil,
            responseEndedUnixMilliseconds: nil
        )
        let submits = try zip(nonces.indices, nonces).map { index, nonce in
            LiveProviderSubmitObservation(
                submit: try LiveProviderHeartbeatSubmit(
                    runID: runID,
                    scenario: .stop,
                    sequence: index + 1,
                    nonce: nonce,
                    unixMilliseconds: times[index]
                ),
                dispatchedAtUnixMilliseconds: times[index],
                completedAtUnixMilliseconds: times[index] + 100,
                taskMetrics: [metric]
            )
        }
        let targetDigest = digest("target")
        let snapshots = try times.flatMap { time in
            [
                try networkSnapshot(at: time - 100, targetDigest: targetDigest),
                try networkSnapshot(at: time + 200, targetDigest: targetDigest),
            ]
        }
        let capability = try LiveProviderCapabilityObservation(
            capability: LiveProviderCapability(
                capabilityPath: "/v1/capability",
                submitPath: "/v1/submit",
                readbackPath: "/v1/readback",
                serverUnixMilliseconds: 0,
                maximumClockSkewSeconds: 0
            ),
            requestStartedUnixMilliseconds: 0,
            responseEndedUnixMilliseconds: 0
        )
        XCTAssertNoThrow(try LiveProviderAcceptanceValidator.validate(
            receipts: receipts,
            submits: submits,
            snapshots: snapshots,
            capability: capability,
            providerPublicKey: LiveProofBase64URL.encode(
                providerKey.publicKey.rawRepresentation
            ),
            expectedTargetSSIDDigest: targetDigest,
            closedWindow: 0...30_000
        ))
        XCTAssertThrowsError(try LiveProviderAcceptanceValidator.validate(
            receipts: receipts,
            submits: submits,
            snapshots: Array(snapshots.dropFirst()),
            capability: capability,
            providerPublicKey: LiveProofBase64URL.encode(
                providerKey.publicKey.rawRepresentation
            ),
            expectedTargetSSIDDigest: targetDigest,
            closedWindow: 0...30_000
        ))

        let privateMetric = LiveProviderTaskMetric(
            localAddress: "192.168.20.4",
            remoteAddress: "10.0.0.8",
            fetchStartedUnixMilliseconds: nil,
            responseEndedUnixMilliseconds: nil
        )
        let privateSubmits = submits.map {
            LiveProviderSubmitObservation(
                submit: $0.submit,
                dispatchedAtUnixMilliseconds: $0.dispatchedAtUnixMilliseconds,
                completedAtUnixMilliseconds: $0.completedAtUnixMilliseconds,
                taskMetrics: [privateMetric]
            )
        }
        XCTAssertThrowsError(try LiveProviderAcceptanceValidator.validate(
            receipts: receipts,
            submits: privateSubmits,
            snapshots: snapshots,
            capability: capability,
            providerPublicKey: LiveProofBase64URL.encode(
                providerKey.publicKey.rawRepresentation
            ),
            expectedTargetSSIDDigest: targetDigest,
            closedWindow: 0...30_000
        )) {
            guard let error = $0 as? LiveProviderTransportError,
                  case .observationMismatch(let detail) = error else {
                return XCTFail("Expected non-public remote rejection")
            }
            XCTAssertTrue(detail.contains("not public"))
        }
    }

    func testObserverSubprocessKeepsOneSequenceAcrossPreflightAndTypedLiveRequests() throws {
        let fixture = try makeObserverRPCFixture()
        defer { cleanupObserverFixture(fixture) }
        let observerPID = try startObserver(fixture)
        defer { terminateProcessIfNeeded(observerPID) }
        let preflightPID = try forkOperation {
            try self.performObserverPreflight(fixture)
        }
        XCTAssertEqual(waitForExit(preflightPID), 0)
        let receipt = try readObserverReceipt(fixture)
        let livePID = try forkOperation {
            let session = try LiveObserverClient.beginLive(
                socketURL: fixture.socketURL,
                receipt: receipt
            )
            try session.requestCapability()
            try session.submitHeartbeat(
                LiveProviderHeartbeatSubmit.fresh(
                    runID: fixture.runID,
                    scenario: .stop,
                    sequence: 1,
                    unixMilliseconds: fixture.issuedAtMilliseconds + 1_000
                )
            )
            try session.requestReadback(runID: fixture.runID, scenario: .stop)
            try session.finish(disposition: "completed", detailCode: "test_complete")
        }
        XCTAssertEqual(waitForExit(livePID), 0)
        XCTAssertEqual(waitForExit(observerPID), 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.sidecarURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.markerURL.path))

        let artifact = try readObserverArtifact(fixture)
        XCTAssertEqual(artifact.signedHandshakes.count, 2)
        let handshakes = try artifact.signedHandshakes.map {
            let bytes = try LiveProofSignatureVerifier.verify(
                $0,
                domain: .handshake,
                publicKeyBase64URL: artifact.observerPublicKey
            )
            return try LiveProofCanonicalJSON.decode(
                LiveProofHandshakePayload.self,
                from: bytes
            )
        }
        XCTAssertEqual(handshakes.map(\.phase), [.preflight, .live])
        XCTAssertEqual(handshakes.map(\.requestSequenceStart), [1, 2])
        XCTAssertNotEqual(handshakes[0].client.pid, handshakes[1].client.pid)
        XCTAssertNotEqual(
            handshakes[0].client.startIdentity,
            handshakes[1].client.startIdentity
        )
        let facts = try observerFacts(artifact)
        XCTAssertTrue(facts.contains { $0.kind == "arming_consumed" })
        XCTAssertEqual(
            facts.filter { $0.kind == "provider_action" }.map(\.detailCode),
            ["capability", "submit", "readback"]
        )
    }

    func testObserverSubprocessRejectsTamperedLiveReceiptBeforeConsumption() throws {
        let fixture = try makeObserverRPCFixture()
        defer { cleanupObserverFixture(fixture) }
        let observerPID = try startObserver(fixture)
        defer { terminateProcessIfNeeded(observerPID) }
        let preflightPID = try forkOperation {
            try self.performObserverPreflight(fixture)
        }
        XCTAssertEqual(waitForExit(preflightPID), 0)
        let receipt = try readObserverReceipt(fixture)
        let replacement = receipt.authenticationCode.first == "A" ? "B" : "A"
        let tampered = LiveProofArmingReceipt(
            issuedAtUnixMilliseconds: receipt.issuedAtUnixMilliseconds,
            expiresAtUnixMilliseconds: receipt.expiresAtUnixMilliseconds,
            challengeSHA256: receipt.challengeSHA256,
            binding: receipt.binding,
            authenticationCode: replacement + String(receipt.authenticationCode.dropFirst())
        )
        let livePID = try forkOperation {
            do {
                let session = try LiveObserverClient.beginLive(
                    socketURL: fixture.socketURL,
                    receipt: tampered
                )
                try session.finish(disposition: "completed", detailCode: "unexpected")
                throw ObserverRPCTestError.unexpectedSuccess
            } catch ObserverRPCTestError.unexpectedSuccess {
                throw ObserverRPCTestError.unexpectedSuccess
            } catch {
                return
            }
        }
        XCTAssertEqual(waitForExit(livePID), 0)
        XCTAssertNotEqual(waitForExit(observerPID), 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.sidecarURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.markerURL.path))
    }

    func testObserverSubprocessRejectsThirdConcurrentAttach() throws {
        let fixture = try makeObserverRPCFixture()
        defer { cleanupObserverFixture(fixture) }
        let observerPID = try startObserver(fixture)
        defer { terminateProcessIfNeeded(observerPID) }
        let preflightPID = try forkOperation {
            try self.performObserverPreflight(fixture)
        }
        XCTAssertEqual(waitForExit(preflightPID), 0)
        XCTAssertEqual(Darwin.kill(observerPID, SIGSTOP), 0)
        var stoppedStatus: Int32 = 0
        XCTAssertEqual(Darwin.waitpid(observerPID, &stoppedStatus, WUNTRACED), observerPID)
        let first = try LiveObserverSocket.connect(at: fixture.socketURL)
        let third = try LiveObserverSocket.connect(at: fixture.socketURL)
        XCTAssertEqual(Darwin.kill(observerPID, SIGCONT), 0)
        _ = Darwin.close(first)
        _ = Darwin.close(third)
        XCTAssertNotEqual(waitForExit(observerPID), 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.sidecarURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.markerURL.path))
    }

    func testObserverSubprocessRejectsLiveRequestSequenceReset() throws {
        let fixture = try makeObserverRPCFixture()
        defer { cleanupObserverFixture(fixture) }
        let observerPID = try startObserver(fixture)
        defer { terminateProcessIfNeeded(observerPID) }
        let preflightPID = try forkOperation {
            try self.performObserverPreflight(fixture)
        }
        XCTAssertEqual(waitForExit(preflightPID), 0)
        let receipt = try readObserverReceipt(fixture)
        let livePID = try forkOperation {
            try self.performSequenceReset(fixture: fixture, receipt: receipt)
        }
        XCTAssertEqual(waitForExit(livePID), 0)
        XCTAssertNotEqual(waitForExit(observerPID), 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.sidecarURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.markerURL.path))
    }

    private var runID: String { "123e4567-e89b-12d3-a456-426614174000" }

    private func makeObserverRPCFixture() throws -> ObserverRPCFixture {
        let directory = URL(
            fileURLWithPath: "/private/tmp/ctm-rpc-\(UUID().uuidString.prefix(12))",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: false
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o700)],
            ofItemAtPath: directory.path
        )
        let issuedAt = LiveControllerSystem.millisecondsSinceEpoch()
        return ObserverRPCFixture(
            directory: directory,
            runID: UUID().uuidString.lowercased(),
            controllerHash: try LiveControllerSystem.sha256File(
                LiveControllerSystem.executableURL()
            ),
            issuedAtMilliseconds: issuedAt,
            expiresAtMilliseconds: issuedAt + LiveProofArming.lifetimeMilliseconds
        )
    }

    private func startObserver(_ fixture: ObserverRPCFixture) throws -> pid_t {
        try forkOperation {
            let arguments = LiveControllerObserverArguments(
                outputURL: fixture.directory,
                runID: fixture.runID,
                controllerHash: fixture.controllerHash,
                expiresAtMilliseconds: fixture.expiresAtMilliseconds
            )
            try LiveObserverService(
                arguments: arguments,
                providerPerformer: ObserverRPCNoOpProvider()
            ).run()
        }
    }

    private func performObserverPreflight(_ fixture: ObserverRPCFixture) throws {
        let session = try LiveObserverClient.beginPreflight(
            socketURL: fixture.socketURL,
            runID: fixture.runID,
            controllerHash: fixture.controllerHash,
            expiresAtMilliseconds: fixture.expiresAtMilliseconds
        )
        let salt = Data(fixture.runID.utf8)
        let binding = try LiveProofArmingBinding(
            runID: fixture.runID,
            machineDigest: digest("machine"),
            baselineDigest: digest("baseline"),
            controllerSHA256: fixture.controllerHash,
            observer: session.observer,
            observerPublicKey: session.observerPublicKey,
            appIdentityDigest: digest("app"),
            helperIdentityDigest: digest("helper"),
            providerOrigin: "https://proof.example",
            outputDirectoryDigest: ReadinessDigest.salted(
                Data(fixture.directory.path.utf8),
                salt: salt
            )
        )
        let material = try LiveProofArming.issue(
            binding: binding,
            confirmedChallenge: Data("operator challenge".utf8),
            nowUnixMilliseconds: fixture.issuedAtMilliseconds
        )
        try LiveProofArming.writeSidecar(material.sidecarSecret, to: fixture.sidecarURL)
        try LiveControllerSystem.writeExclusive(
            LiveProofCanonicalJSON.encode(material.receipt),
            to: fixture.receiptURL
        )
        try session.arm(receipt: material.receipt)
    }

    private func performSequenceReset(
        fixture: ObserverRPCFixture,
        receipt: LiveProofArmingReceipt
    ) throws {
        let descriptor = try LiveObserverSocket.connect(at: fixture.socketURL)
        defer { _ = Darwin.close(descriptor) }
        let client = try LiveProofProcessIdentity(
            pid: getpid(),
            startIdentity: LiveControllerSystem.processStartIdentity(pid: getpid()),
            executableSHA256: fixture.controllerHash
        )
        let handshake = try LiveProofHandshakePayload(
            runID: fixture.runID,
            phase: .live,
            client: client,
            controllerSHA256: fixture.controllerHash,
            requestSequenceStart: 2
        )
        try LiveObserverSocket.writeJSON(
            LiveObserverHandshakeRequest(
                schema: "codex-travel-mode-observer-handshake/v1",
                handshake: handshake,
                expiresAtMilliseconds: nil,
                receipt: receipt
            ),
            to: descriptor
        )
        _ = try LiveObserverSocket.readJSON(
            LiveObserverHandshakeResponse.self,
            from: descriptor
        )
        try LiveObserverSocket.writeJSON(
            LiveObserverProviderRequest(
                schema: "codex-travel-mode-observer-provider-request/v1",
                requestSequence: 1,
                action: .capability,
                submit: nil,
                runID: nil,
                scenario: nil
            ),
            to: descriptor
        )
        do {
            _ = try LiveObserverSocket.readJSON(
                LiveObserverAcknowledgement.self,
                from: descriptor
            )
            throw ObserverRPCTestError.unexpectedSuccess
        } catch ObserverRPCTestError.unexpectedSuccess {
            throw ObserverRPCTestError.unexpectedSuccess
        } catch {
            return
        }
    }

    private func readObserverReceipt(_ fixture: ObserverRPCFixture) throws
        -> LiveProofArmingReceipt {
        try LiveProofCanonicalJSON.decode(
            LiveProofArmingReceipt.self,
            from: Data(contentsOf: fixture.receiptURL)
        )
    }

    private func readObserverArtifact(_ fixture: ObserverRPCFixture) throws
        -> ObserverRPCTestArtifact {
        try LiveProofCanonicalJSON.decode(
            ObserverRPCTestArtifact.self,
            from: Data(
                contentsOf: fixture.directory.appendingPathComponent(
                    "observer-events.json"
                )
            )
        )
    }

    private func observerFacts(_ artifact: ObserverRPCTestArtifact) throws
        -> [ObserverRPCTestFact] {
        try artifact.events.map {
            let bytes = try LiveProofSignatureVerifier.verify(
                LiveProofSignedPayload(
                    payloadBase64URL: $0.payloadBase64URL,
                    signatureBase64URL: $0.signatureBase64URL
                ),
                domain: .event,
                publicKeyBase64URL: artifact.observerPublicKey
            )
            return try LiveProofCanonicalJSON.decode(ObserverRPCTestFact.self, from: bytes)
        }
    }

    private func forkOperation(_ operation: @escaping () throws -> Void) throws -> pid_t {
        let pid = observerRPCTestFork()
        guard pid >= 0 else { throw ObserverRPCTestError.forkFailed }
        if pid == 0 {
            do {
                try operation()
                Darwin._exit(0)
            } catch {
                Darwin._exit(71)
            }
        }
        return pid
    }

    private func waitForExit(_ pid: pid_t) -> Int32 {
        var status: Int32 = 0
        guard Darwin.waitpid(pid, &status, 0) == pid else { return -1 }
        guard status & 0x7f == 0 else { return 128 + (status & 0x7f) }
        return (status >> 8) & 0xff
    }

    private func cleanupObserverFixture(_ fixture: ObserverRPCFixture) {
        try? FileManager.default.removeItem(at: fixture.directory)
    }

    private func terminateProcessIfNeeded(_ pid: pid_t) {
        var status: Int32 = 0
        let result = Darwin.waitpid(pid, &status, WNOHANG)
        guard result == 0 else { return }
        _ = Darwin.kill(pid, SIGKILL)
        _ = Darwin.waitpid(pid, &status, 0)
    }

    private func digest(_ value: String) -> String {
        ReadinessDigest.sha256Hex(Data(value.utf8))
    }

    private func processIdentity(pid: Int32) throws -> LiveProofProcessIdentity {
        try LiveProofProcessIdentity(
            pid: pid,
            startIdentity: "start-\(pid)",
            executableSHA256: digest("executable-\(pid)")
        )
    }

    private func makeBinding() throws -> LiveProofArmingBinding {
        let signer = LiveProofEphemeralSigner()
        return try LiveProofArmingBinding(
            runID: runID,
            machineDigest: digest("machine"),
            baselineDigest: digest("baseline"),
            controllerSHA256: digest("controller"),
            observer: processIdentity(pid: 41),
            observerPublicKey: signer.publicKeyBase64URL,
            appIdentityDigest: digest("app"),
            helperIdentityDigest: digest("helper"),
            providerOrigin: "https://proof.example",
            outputDirectoryDigest: digest("output")
        )
    }

    private func signedReceipt(
        sequence: Int,
        nonce: String,
        serverReceiveUnixMilliseconds: Int64? = nil,
        privateKey: Curve25519.Signing.PrivateKey
    ) throws -> LiveProofProviderReceipt {
        let source = LiveProofBase64URL.encode(Data([93, 184, 216, 34]))
        let placeholder = LiveProofBase64URL.encode(Data(repeating: 0, count: 64))
        let unsigned = try LiveProofProviderReceipt(
            runID: runID,
            scenario: .stop,
            sequence: sequence,
            nonce: nonce,
            serverReceiveUnixMilliseconds:
                serverReceiveUnixMilliseconds ?? 10_000 + Int64(sequence),
            sourceFamily: .ipv4,
            sourceAddress: source,
            signature: placeholder
        )
        let signature = try privateKey.signature(for: unsigned.canonicalSignedBytes)
        return try LiveProofProviderReceipt(
            runID: unsigned.runID,
            scenario: unsigned.scenario,
            sequence: unsigned.sequence,
            nonce: unsigned.nonce,
            serverReceiveUnixMilliseconds: unsigned.serverReceiveUnixMilliseconds,
            sourceFamily: unsigned.sourceFamily,
            sourceAddress: unsigned.sourceAddress,
            signature: LiveProofBase64URL.encode(signature)
        )
    }

    private func providerConfiguration(
        publicKey: Curve25519.Signing.PublicKey
    ) throws -> LiveProofProviderConfiguration {
        try LiveProofProviderConfiguration(
            origin: "https://proof.example",
            capabilityPath: "/v1/capability",
            submitPath: "/v1/submit",
            readbackPath: "/v1/readback",
            publicKey: LiveProofBase64URL.encode(publicKey.rawRepresentation),
            keychain: LiveProofProviderKeychainReference(
                service: "proof-service",
                account: "proof-account"
            )
        )
    }

    private func networkSnapshot(
        at time: Int64,
        targetDigest: String
    ) throws -> LiveObservedRuntimeNetworkSnapshot {
        try LiveObservedRuntimeNetworkSnapshot(
            capturedAtUnixMilliseconds: time,
            sleepDisabled: true,
            lidClosed: true,
            battery: LiveObservedBattery(source: .battery, percent: 80),
            ssidDigest: targetDigest,
            wifiDevice: "en0",
            wifiPowered: true,
            interfaceAddresses: [LiveObservedIPAddress("192.168.20.4")],
            routedRemoteAddress: LiveObservedIPAddress("93.184.216.34"),
            routeDevice: "en0"
        )
    }

    private func temporaryPrivateDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("live-proof-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o700)],
            ofItemAtPath: directory.path
        )
        return directory
    }

    private func permissions(_ url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return try XCTUnwrap(attributes[.posixPermissions] as? NSNumber).intValue & 0o777
    }

    private func concurrentConsume(
        receipt: LiveProofArmingReceipt,
        sidecar: URL,
        marker: URL,
        now: Int64
    ) -> [ConsumeOutcome] {
        let lock = NSLock()
        let group = DispatchGroup()
        let queue = DispatchQueue(label: "arming-race", attributes: .concurrent)
        nonisolated(unsafe) var outcomes: [ConsumeOutcome] = []
        for _ in 0..<2 {
            group.enter()
            queue.async {
                let outcome: ConsumeOutcome
                do {
                    try LiveProofArming.consume(
                        receipt: receipt,
                        sidecarURL: sidecar,
                        markerURL: marker,
                        nowUnixMilliseconds: now
                    )
                    outcome = ConsumeOutcome(error: nil)
                } catch {
                    outcome = ConsumeOutcome(error: error as? LiveProofError)
                }
                lock.lock()
                outcomes.append(outcome)
                lock.unlock()
                group.leave()
            }
        }
        group.wait()
        return outcomes
    }
}

private struct ObserverRPCFixture: Sendable {
    let directory: URL
    let runID: String
    let controllerHash: String
    let issuedAtMilliseconds: Int64
    let expiresAtMilliseconds: Int64

    var socketURL: URL {
        directory.appendingPathComponent(LiveControllerSystem.socketName)
    }

    var sidecarURL: URL {
        directory.appendingPathComponent(LiveControllerSystem.sidecarName)
    }

    var markerURL: URL {
        directory.appendingPathComponent(LiveControllerSystem.consumedName)
    }

    var receiptURL: URL {
        directory.appendingPathComponent(".test-receipt.json")
    }
}

private struct ObserverRPCNoOpProvider: LiveObserverProviderCommandPerforming {
    func perform(_ command: LiveObserverProviderCommand) throws {}
}

private struct ObserverRPCTestArtifact: Codable {
    let observerPublicKey: String
    let signedHandshakes: [LiveProofSignedPayload]
    let events: [LiveProofSignedEventEnvelope]

    enum CodingKeys: String, CodingKey {
        case observerPublicKey = "observer_public_key"
        case signedHandshakes = "signed_handshakes"
        case events
    }
}

private struct ObserverRPCTestFact: Codable {
    let kind: String
    let detailCode: String

    enum CodingKeys: String, CodingKey {
        case kind
        case detailCode = "detail_code"
    }
}

private enum ObserverRPCTestError: Error {
    case forkFailed
    case unexpectedSuccess
}

extension LiveTravelModeProofHarnessTests {
    func testPreflightAndLiveUseOneBoundExecutableDigestConvention() throws {
        let url = URL(
            fileURLWithPath: "/private/tmp/ctm-bound-digest-\(UUID().uuidString)"
        )
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("signed executable fixture".utf8).write(to: url, options: .withoutOverwriting)
        let runID = "123e4567-e89b-12d3-a456-426614174000"
        let expected = ReadinessDigest.salted(
            Data(try LiveControllerSystem.sha256File(url).utf8),
            salt: Data(runID.utf8)
        )

        let observerPreflightDigest = try LiveControllerSystem.boundExecutableDigest(
            url,
            runID: runID
        )
        let liveControllerDigest = try LiveControllerSystem.boundExecutableDigest(
            url,
            runID: runID
        )
        XCTAssertEqual(observerPreflightDigest, expected)
        XCTAssertEqual(liveControllerDigest, observerPreflightDigest)
    }

    func testLiveFailureCleanupIsBoundedProductionOnlyAndStopsWithoutRescue() throws {
        let runID = "123e4567-e89b-12d3-a456-426614174000"
        let controller = try LiveProofProcessIdentity(
            pid: getpid(),
            startIdentity: LiveControllerSystem.processStartIdentity(pid: getpid()),
            executableSHA256: LiveControllerSystem.sha256File(
                LiveControllerSystem.executableURL()
            )
        )
        let recorder = try LiveControllerEvidenceRecorder(
            runID: runID,
            controller: controller,
            redactionSalt: Data(runID.utf8)
        )
        let operatorIO = FailureCleanupOperatorIO()

        try LiveScenarioFailureCleanup.run(
            scenario: .stop,
            recorder: recorder,
            operatorIO: operatorIO
        )

        let artifacts = recorder.snapshotArtifacts()
        XCTAssertEqual(
            artifacts.cleanup.events.map(\.kind),
            [.cleanupEntered, .productionStopRequested, .productionQuitRequested]
        )
        XCTAssertFalse(
            artifacts.cleanup.events.contains {
                [.safetyTerminateRequested, .directRescueRequested].contains($0.kind)
            }
        )
        XCTAssertEqual(operatorIO.timeouts, [30, 30, 30])
        XCTAssertTrue(artifacts.command.events.isEmpty)
        XCTAssertTrue(artifacts.operatorEvents.events.isEmpty)
    }
}

private final class FailureCleanupOperatorIO:
    LiveScenarioOperatorIO, @unchecked Sendable {
    private let lock = NSLock()
    private var recordedTimeouts: [Int] = []

    var timeouts: [Int] {
        lock.withLock { recordedTimeouts }
    }

    func confirm(_ instruction: String) throws {
        XCTFail("failure cleanup must always use a bounded confirmation")
    }

    func confirm(_ instruction: String, timeoutSeconds: Int) throws {
        lock.withLock { recordedTimeouts.append(timeoutSeconds) }
    }
}

@_silgen_name("fork")
private func observerRPCTestFork() -> pid_t

private struct ConsumeOutcome: Sendable {
    let error: LiveProofError?
    var isSuccess: Bool { error == nil }
}

private final class FakeObservedCommandRunner: LiveObservedCommandRunning, @unchecked Sendable {
    private let lock = NSLock()
    private var results: [LiveObservedCommandResult]
    private var recorded: [LiveObservedCommand] = []

    init(results: [LiveObservedCommandResult]) {
        self.results = results
    }

    var commands: [LiveObservedCommand] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    func run(_ command: LiveObservedCommand) throws -> LiveObservedCommandResult {
        lock.lock()
        defer { lock.unlock() }
        recorded.append(command)
        return results.removeFirst()
    }
}

private final class FakeCodeIdentityInspector:
    LiveObservedCodeIdentityInspecting, @unchecked Sendable {
    let embedded: LiveObservedCodeIdentity
    let running: LiveObservedCodeIdentity
    var matchesRequirements = true
    private(set) var requirementSubjects: [LiveObservedCodeSubject] = []

    init(embedded: LiveObservedCodeIdentity, running: LiveObservedCodeIdentity) {
        self.embedded = embedded
        self.running = running
    }

    func runningIdentity(pid: Int32) throws -> LiveObservedCodeIdentity { running }

    func embeddedIdentity(at url: URL) throws -> LiveObservedCodeIdentity { embedded }

    func requirementMatches(
        subject: LiveObservedCodeSubject,
        requirement: String
    ) throws -> Bool {
        requirementSubjects.append(subject)
        return matchesRequirements
    }
}

private actor FakeLiveProviderTransport: LiveProviderHTTPTransporting {
    private var responses: [(Data, [LiveProviderTaskMetric])]
    private var requests: [URLRequest] = []

    init(responses: [(Data, [LiveProviderTaskMetric])]) {
        self.responses = responses
    }

    func send(_ request: URLRequest) async throws -> LiveProviderHTTPResponse {
        requests.append(request)
        let response = responses.removeFirst()
        return LiveProviderHTTPResponse(
            data: response.0,
            statusCode: 200,
            finalURL: request.url!,
            taskMetrics: response.1
        )
    }

    func capturedRequests() -> [URLRequest] { requests }
}

private struct FixedBearerReader: LiveProviderBearerTokenReading {
    let token: Data?

    init(_ token: Data?) {
        self.token = token
    }

    func readToken(service: String, account: String) throws -> Data? { token }
}

private final class SequenceProviderClock: LiveProviderClock, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Int64]

    init(_ values: [Int64]) {
        self.values = values
    }

    func nowUnixMilliseconds() -> Int64 {
        lock.lock()
        defer { lock.unlock() }
        return values.removeFirst()
    }
}

private struct FixedBundleExecutableResolver: LivePlatformBundleExecutableResolving {
    let executable: URL

    init(_ executable: URL) {
        self.executable = executable.standardizedFileURL
    }

    func executableURL(bundleURL: URL) throws -> URL { executable }
}

private final class FakePlatformProcessResolver:
    LivePlatformProcessResolving, @unchecked Sendable {
    var processesByPath: [String: [LivePlatformResolvedProcess]]

    init(processesByPath: [String: [LivePlatformResolvedProcess]]) {
        self.processesByPath = processesByPath
    }

    func process(pid: Int32) throws -> LivePlatformResolvedProcess {
        guard let process = processesByPath.values.flatMap({ $0 })
            .first(where: { $0.pid == pid }) else {
            throw LivePlatformReadinessError.processNotFound("PID \(pid)")
        }
        return process
    }

    func processes(executableURL: URL) throws -> [LivePlatformResolvedProcess] {
        processesByPath[executableURL.standardizedFileURL.path] ?? []
    }
}

private struct FixedServiceStatusReader: LivePlatformServiceStatusReading {
    let status: LivePlatformServiceStatus

    init(_ status: LivePlatformServiceStatus) {
        self.status = status
    }

    func helperStatus(plistName: String) -> LivePlatformServiceStatus { status }
}

private final class FixedFilePresenceInspector:
    LivePlatformFilePresenceInspecting, @unchecked Sendable {
    let presence: LivePlatformJournalPresence
    private(set) var observedURLs: [URL] = []

    init(_ presence: LivePlatformJournalPresence) {
        self.presence = presence
    }

    func ownedRegularFilePresence(at url: URL) -> LivePlatformJournalPresence {
        observedURLs.append(url)
        return presence
    }
}

private struct FixedAccessibilityReader: LivePlatformAccessibilityTrustReading {
    let trusted: Bool

    init(_ trusted: Bool) {
        self.trusted = trusted
    }

    func isProcessTrusted() -> Bool { trusted }
}

private struct FixedProductionUIReader: LivePlatformProductionUIReading {
    let value: LivePlatformProductionUIReadback

    init(_ value: LivePlatformProductionUIReadback) {
        self.value = value
    }

    func readback(
        app: LivePlatformResolvedProcess
    ) async throws -> LivePlatformProductionUIReadback {
        value
    }
}

private func XCTAssertThrowsErrorAsync(
    _ expression: () async throws -> Void,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        try await expression()
        XCTFail("Expected async expression to throw", file: file, line: line)
    } catch {}
}

extension LiveTravelModeProofHarnessTests {
    func testIndependentOracleAcceptsCompleteSealedFixtureAndWritesReport() throws {
        let fixture = try OracleFixture()
        let files = OracleMemoryFileAccess(files: fixture.files)
        let report = try LiveTravelModeOracle.run(
            request: fixture.request,
            fileAccess: files,
            identityProvider: OracleFixedIdentityProvider(fixture.request.oracle)
        )

        XCTAssertEqual(report.verdict, .accept)
        XCTAssertTrue(report.issueCodes.isEmpty)
        XCTAssertEqual(files.reportCount, 1)
        XCTAssertNotNil(files.file(named: "oracle-report.json"))
    }

    func testIndependentOracleRejectsSensitiveSentinelInsideSealedEvidence() throws {
        let sentinel = Data("controller-secret-sentinel".utf8)
        let fixture = try OracleFixture(
            controllerStartIdentity: String(decoding: sentinel, as: UTF8.self),
            forbiddenSentinels: [sentinel]
        )
        let report = try LiveTravelModeOracle.run(
            request: fixture.request,
            fileAccess: OracleMemoryFileAccess(files: fixture.files),
            identityProvider: OracleFixedIdentityProvider(fixture.request.oracle)
        )

        XCTAssertEqual(report.verdict, .reject)
        XCTAssertEqual(report.issueCodes, ["sensitive_sentinel_present"])
    }

    func testIndependentOracleKeepsPriorSSIDSeparateFromMandatoryCleanup() throws {
        let fixture = try OracleFixture(priorSSIDMismatch: .stop)
        let report = try LiveTravelModeOracle.run(
            request: fixture.request,
            fileAccess: OracleMemoryFileAccess(files: fixture.files),
            identityProvider: OracleFixedIdentityProvider(fixture.request.oracle)
        )

        XCTAssertEqual(report.verdict, .reject)
        XCTAssertEqual(report.issueCodes, ["prior_ssid_mismatch"])
        XCTAssertFalse(report.issueCodes.contains("mandatory_cleanup_failed"))
    }

    func testIndependentOracleRejectsReceiptTargetAndDeviceDrift() throws {
        let fixtures = [
            try OracleFixture(receiptTargetMismatch: true),
            try OracleFixture(receiptDeviceMismatch: true),
        ]
        let expectedIssues = [
            "preflight_binding_mismatch",
            "authoritative_wifi_device_mismatch",
        ]

        for (fixture, issue) in zip(fixtures, expectedIssues) {
            let report = try LiveTravelModeOracle.run(
                request: fixture.request,
                fileAccess: OracleMemoryFileAccess(files: fixture.files),
                identityProvider: OracleFixedIdentityProvider(fixture.request.oracle)
            )

            XCTAssertEqual(report.verdict, .reject)
            XCTAssertEqual(report.issueCodes, [issue])
        }
    }

    func testIndependentOracleDetectsMutationAcrossEvaluation() throws {
        let fixture = try OracleFixture()
        let files = OracleMemoryFileAccess(
            files: fixture.files,
            mutateBeforeSecondSnapshot: "command-events.json"
        )
        let report = try LiveTravelModeOracle.run(
            request: fixture.request,
            fileAccess: files,
            identityProvider: OracleFixedIdentityProvider(fixture.request.oracle)
        )

        XCTAssertEqual(report.verdict, .reject)
        XCTAssertEqual(report.issueCodes, ["artifact_changed_during_evaluation"])
    }
}

extension LiveTravelModeProofHarnessTests {
    func testEvidenceRecordersEnforceControllerRoleOwnership() throws {
        let controller = try evidenceIdentity(
            pid: 801,
            start: "live-controller",
            executable: evidenceDigest("controller")
        )
        let recorder = try LiveControllerEvidenceRecorder(
            runID: runID,
            controller: controller,
            redactionSalt: Data(repeating: 0x51, count: 32)
        )

        XCTAssertThrowsError(try recorder.appendCommand(
            unixMilliseconds: 1,
            monotonicNanoseconds: 1,
            scenario: .stop,
            kind: .start
        )) {
            XCTAssertEqual(
                $0 as? LiveEvidenceError,
                .invalidEvent("kind is not controller-command evidence")
            )
        }
        XCTAssertThrowsError(try recorder.appendOperatorEvent(
            unixMilliseconds: 1,
            monotonicNanoseconds: 1,
            scenario: .stop,
            kind: .heartbeatReadbackRequest
        ))
        XCTAssertThrowsError(try recorder.appendCleanupRequest(
            unixMilliseconds: 1,
            monotonicNanoseconds: 1,
            scenario: .stop,
            kind: .quit
        ))

        try recorder.appendOperatorEvent(
            unixMilliseconds: 2,
            monotonicNanoseconds: 2,
            scenario: .stop,
            kind: .start
        )
        let artifacts = recorder.snapshotArtifacts()
        XCTAssertEqual(artifacts.command.schema, "codex-travel-mode-command-events/v1")
        XCTAssertEqual(
            artifacts.operatorEvents.schema,
            "codex-travel-mode-operator-events/v1"
        )
        XCTAssertEqual(artifacts.cleanup.schema, "codex-travel-mode-cleanup-events/v1")
        XCTAssertEqual(artifacts.operatorEvents.producer, controller)
        XCTAssertEqual(artifacts.operatorEvents.events.map(\.kind), [.start])
        XCTAssertEqual(artifacts.operatorEvents.events.map(\.sequence), [1])
    }

    func testEvidenceObserverRedactsSensitiveInputsBeforeEncoding() throws {
        let salt = Data(repeating: 0xa7, count: 32)
        let signer = LiveProofEphemeralSigner()
        let providerSigner = LiveProofEphemeralSigner()
        let observer = try evidenceIdentity(
            pid: 803,
            start: "observer",
            executable: evidenceDigest("observer")
        )
        let controller = try evidenceIdentity(
            pid: 801,
            start: "preflight-controller",
            executable: evidenceDigest("controller")
        )
        let recorder = try LiveObserverEvidenceRecorder(
            runID: runID,
            observer: observer,
            signer: signer,
            redactionSalt: salt
        )
        let secretPath = Data("/Applications/Secret.app".utf8)
        let secretSSID = Data("Example Personal Hotspot".utf8)
        let secretLocalAddress = Data("192.168.44.9".utf8)
        let secretRemoteAddress = Data("93.184.216.34".utf8)
        let peerUID = Data("501".utf8)
        let preflight = try recorder.recordPreflight(LiveEvidencePreflightInput(
            machineIdentity: Data("machine-serial".utf8),
            baselineBytes: Data("baseline".utf8),
            appIdentityBytes: secretPath,
            helperIdentityBytes: Data("/Library/PrivilegedHelperTools/helper".utf8),
            priorSSID: Data("Office WiFi".utf8),
            targetSSID: secretSSID,
            providerOrigin: "https://proof.example",
            providerPublicKey: providerSigner.publicKeyBase64URL,
            outputDirectoryPath: Data("/private/tmp/live-evidence".utf8),
            observerUID: peerUID,
            preflightPeerUID: peerUID,
            capability: evidenceCapability()
        ))
        try recorder.appendHandshake(
            LiveProofHandshakePayload(
                runID: runID,
                phase: .preflight,
                client: controller,
                controllerSHA256: controller.executableSHA256,
                requestSequenceStart: 1
            ),
            peerUID: peerUID
        )
        try recorder.appendEvent(LiveEvidenceObserverEventInput(
            requestSequence: 1,
            phase: .preflight,
            unixMilliseconds: 1_000,
            monotonicNanoseconds: 1_000,
            scenario: nil,
            kind: .preflightSample,
            observation: evidenceObservation(
                ssid: secretSSID,
                appIdentity: secretPath,
                localAddress: secretLocalAddress,
                remoteAddress: secretRemoteAddress
            )
        ))
        try recorder.appendProviderTransport(LiveEvidenceProviderTransportInput(
            scenario: .stop,
            sequence: 1,
            nonce: LiveProofBase64URL.encode(Data(repeating: 0x11, count: 32)),
            dispatchUnixMilliseconds: 1_100,
            completionUnixMilliseconds: 1_200,
            localAddress: secretLocalAddress,
            remoteAddress: secretRemoteAddress,
            beforeObserverEventSequence: 1,
            afterObserverEventSequence: 2
        ))

        let artifacts = try recorder.snapshotArtifacts()
        let eventPayload = try LiveProofBase64URL.decode(
            try XCTUnwrap(artifacts.events.events.first).payloadBase64URL
        )
        let encoded = [
            try LiveProofCanonicalJSON.encode(artifacts.preflight),
            try LiveProofCanonicalJSON.encode(artifacts.transport),
            eventPayload,
        ].reduce(into: Data()) { $0.append($1) }
        for plaintext in [
            secretPath, secretSSID, secretLocalAddress, secretRemoteAddress,
            Data("/private/tmp/live-evidence".utf8),
        ] {
            XCTAssertNil(encoded.range(of: plaintext))
        }
        XCTAssertEqual(
            preflight.targetSSIDDigest,
            ReadinessDigest.salted(secretSSID, salt: salt)
        )
        XCTAssertEqual(
            artifacts.transport.records[0].localAddressDigest,
            ReadinessDigest.salted(secretLocalAddress, salt: salt)
        )
        let decodedEvent = try LiveProofCanonicalJSON.decode(
            LiveOracleObserverEventPayload.self,
            from: eventPayload
        )
        XCTAssertEqual(
            decodedEvent.snapshot?.routeRemoteAddressDigest,
            ReadinessDigest.salted(secretRemoteAddress, salt: salt)
        )
    }

    func testEvidenceFinalizerSealsExactRoleAuthoredManifestAndReadback() throws {
        let directory = URL(fileURLWithPath: "/tmp/ctm-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: NSNumber(value: 0o700)]
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let salt = Data(repeating: 0x6d, count: 32)
        let providerSigner = LiveProofEphemeralSigner()
        let observerSigner = LiveProofEphemeralSigner()
        let controllerHash = evidenceDigest("controller-executable")
        let preflightController = try evidenceIdentity(
            pid: 811,
            start: "preflight-controller",
            executable: controllerHash
        )
        let liveController = try evidenceIdentity(
            pid: 812,
            start: "live-controller",
            executable: controllerHash
        )
        let observer = try evidenceIdentity(
            pid: 813,
            start: "observer",
            executable: evidenceDigest("observer-executable")
        )
        let controllerRecorder = try LiveControllerEvidenceRecorder(
            runID: runID,
            controller: liveController,
            redactionSalt: salt
        )
        let observerRecorder = try LiveObserverEvidenceRecorder(
            runID: runID,
            observer: observer,
            signer: observerSigner,
            redactionSalt: salt
        )
        let machine = Data("machine".utf8)
        let baseline = Data("baseline".utf8)
        let appIdentity = Data("/Applications/Codex Travel Mode.app".utf8)
        let helperIdentity = Data("/Library/PrivilegedHelperTools/travel-helper".utf8)
        let priorSSID = Data("Office".utf8)
        let targetSSID = Data("Personal Hotspot".utf8)
        let outputPath = Data(directory.path.utf8)
        let peerUID = Data(String(geteuid()).utf8)
        _ = try observerRecorder.recordPreflight(LiveEvidencePreflightInput(
            machineIdentity: machine,
            baselineBytes: baseline,
            appIdentityBytes: appIdentity,
            helperIdentityBytes: helperIdentity,
            priorSSID: priorSSID,
            targetSSID: targetSSID,
            providerOrigin: "https://proof.example",
            providerPublicKey: providerSigner.publicKeyBase64URL,
            outputDirectoryPath: outputPath,
            observerUID: peerUID,
            preflightPeerUID: peerUID,
            capability: evidenceCapability()
        ))
        let binding = try LiveProofArmingBinding(
            runID: runID,
            machineDigest: ReadinessDigest.salted(machine, salt: salt),
            baselineDigest: ReadinessDigest.salted(baseline, salt: salt),
            controllerSHA256: controllerHash,
            observer: observer,
            observerPublicKey: observerSigner.publicKeyBase64URL,
            appIdentityDigest: ReadinessDigest.salted(appIdentity, salt: salt),
            helperIdentityDigest: ReadinessDigest.salted(helperIdentity, salt: salt),
            providerOrigin: "https://proof.example",
            outputDirectoryDigest: ReadinessDigest.salted(outputPath, salt: salt),
            targetSSIDDigest: ReadinessDigest.salted(targetSSID, salt: salt),
            wifiDeviceDigest: ReadinessDigest.salted(Data("en0".utf8), salt: salt)
        )
        let receipt = try LiveProofArming.issue(
            binding: binding,
            confirmedChallenge: Data("operator-confirmed".utf8),
            nowUnixMilliseconds: 1_000
        ).receipt
        let receiptBytes = try LiveProofCanonicalJSON.encode(receipt)
        let writer = try ReadinessSecureArtifactWriter(
            outputURL: directory,
            allowExistingEmptyDirectory: true
        )
        try writer.writeNew(data: receiptBytes, named: "arming-receipt.json")
        try writer.writeNew(
            data: Data(ReadinessDigest.sha256Hex(receiptBytes).utf8),
            named: ".arming-consumed"
        )

        try observerRecorder.appendHandshake(
            LiveProofHandshakePayload(
                runID: runID,
                phase: .preflight,
                client: preflightController,
                controllerSHA256: controllerHash,
                requestSequenceStart: 1
            ),
            peerUID: peerUID
        )
        try observerRecorder.appendEvent(LiveEvidenceObserverEventInput(
            requestSequence: 1,
            phase: .preflight,
            unixMilliseconds: 1_001,
            monotonicNanoseconds: 1_001,
            scenario: nil,
            kind: .preflightSample,
            observation: evidenceObservation(
                ssid: priorSSID,
                appIdentity: appIdentity,
                localAddress: Data("192.168.1.2".utf8),
                remoteAddress: Data("93.184.216.34".utf8),
                helperIdentity: helperIdentity
            )
        ))
        try observerRecorder.appendHandshake(
            LiveProofHandshakePayload(
                runID: runID,
                phase: .live,
                client: liveController,
                controllerSHA256: controllerHash,
                requestSequenceStart: 2
            ),
            peerUID: peerUID
        )

        let socketURL = directory.appendingPathComponent(
            LiveEvidenceFinalizer.defaultLiveSocketName
        )
        var listener: Int32? = try LiveObserverSocket.makeListener(at: socketURL)
        defer {
            if let listener { _ = Darwin.close(listener) }
            _ = Darwin.unlink(socketURL.path)
        }
        let observerResult = try LiveEvidenceFinalizer.finalizeObserver(
            directory: directory,
            recorder: observerRecorder
        )
        XCTAssertEqual(observerResult.observerOwnedEntries.count, 4)
        XCTAssertThrowsError(try LiveEvidenceFinalizer.finalizeController(
            directory: directory,
            receipt: receipt,
            recorder: controllerRecorder
        ))
        if let descriptor = listener {
            _ = Darwin.close(descriptor)
            listener = nil
        }
        XCTAssertEqual(Darwin.unlink(socketURL.path), 0)
        let result = try LiveEvidenceFinalizer.finalizeController(
            directory: directory,
            receipt: receipt,
            recorder: controllerRecorder
        )

        XCTAssertEqual(
            Set(result.manifest.entries.map(\.name)),
            LiveTravelModeOracle.rawArtifactNames.subtracting(["seal-manifest.json"])
        )
        XCTAssertEqual(result.manifest.author, liveController)
        let byName = Dictionary(uniqueKeysWithValues: result.manifest.entries.map {
            ($0.name, $0)
        })
        XCTAssertEqual(byName["arming-receipt.json"]?.author, preflightController)
        XCTAssertEqual(byName["arming-receipt.json"]?.role, .controller)
        for name in [
            "preflight-readback.json", "provider-transport-events.json",
            "provider-receipts.json", "observer-events.json", "observer-seal.json",
        ] {
            XCTAssertEqual(byName[name]?.author, observer)
            XCTAssertEqual(byName[name]?.role, .observer)
        }
        for name in [
            "command-events.json", "operator-events.json", "cleanup-events.json",
        ] {
            XCTAssertEqual(byName[name]?.author, liveController)
            XCTAssertEqual(byName[name]?.role, .controller)
        }
        for name in LiveTravelModeOracle.rawArtifactNames {
            let url = directory.appendingPathComponent(name)
            XCTAssertEqual(try permissions(url), 0o400)
            if let entry = byName[name] {
                let bytes = try Data(contentsOf: url)
                XCTAssertEqual(entry.byteCount, Int64(bytes.count))
                XCTAssertEqual(entry.sha256, ReadinessDigest.sha256Hex(bytes))
            }
        }
        XCTAssertEqual(
            try permissions(directory.appendingPathComponent(".arming-consumed")),
            0o600
        )
        let sealBytes = try LiveProofSignatureVerifier.verify(
            result.signedObserverSeal,
            domain: .seal,
            publicKeyBase64URL: observerSigner.publicKeyBase64URL
        )
        let seal = try LiveProofCanonicalJSON.decode(
            LiveOracleObserverSealPayload.self,
            from: sealBytes
        )
        XCTAssertEqual(seal.observer, observer)
        XCTAssertEqual(seal.eventCount, 1)
        XCTAssertEqual(
            Set(seal.observerOwnedFiles.map(\.name)),
            [
                "preflight-readback.json", "provider-transport-events.json",
                "provider-receipts.json", "observer-events.json",
            ]
        )
    }

    private func evidenceIdentity(
        pid: Int32,
        start: String,
        executable: String
    ) throws -> LiveProofProcessIdentity {
        try LiveProofProcessIdentity(
            pid: pid,
            startIdentity: start,
            executableSHA256: executable
        )
    }

    private func evidenceCapability() -> LiveOracleProviderCapability {
        LiveOracleProviderCapability(
            capabilityPath: "/v1/capability",
            submitPath: "/v1/submit",
            readbackPath: "/v1/readback",
            serverUnixMilliseconds: 1_000,
            clockOffsetMilliseconds: 0,
            maximumClockSkewSeconds: 5
        )
    }

    private func evidenceObservation(
        ssid: Data,
        appIdentity: Data,
        localAddress: Data,
        remoteAddress: Data,
        helperIdentity: Data = Data("/Library/PrivilegedHelperTools/helper".utf8)
    ) -> LiveEvidenceSystemObservation {
        LiveEvidenceSystemObservation(
            powerSource: .battery,
            batteryPercent: 80,
            lidClosed: false,
            sleepDisabled: 0,
            wifiPower: true,
            selectedWiFiDevice: Data("en0".utf8),
            ssid: ssid,
            usableAddresses: [localAddress],
            routeRemoteAddress: remoteAddress,
            routeDevice: Data("en0".utf8),
            appRunning: false,
            appJournal: .absent,
            helperJournal: .absent,
            helperJournalAuthorizationCode: 0,
            appIdentityBytes: appIdentity,
            helperIdentityBytes: helperIdentity
        )
    }

    private func evidenceDigest(_ value: String) -> String {
        ReadinessDigest.sha256Hex(Data(value.utf8))
    }
}

private struct OracleFixture {
    let files: [String: LiveOracleFile]
    let request: LiveOracleRequest

    private let runID = "123e4567-e89b-12d3-a456-426614174000"
    private let ownerUID: UInt32 = 501
    private let appDigest = oracleDigest("app")
    private let helperDigest = oracleDigest("helper")
    private let baselineDigest = oracleDigest("baseline")
    private let priorDigest = oracleDigest("prior-ssid")
    private let targetDigest = oracleDigest("target-ssid")
    private let wifiDeviceDigest = oracleDigest("en0")
    private let localAddressDigest = oracleDigest("192.168.20.4")
    private let remoteAddressDigest = oracleDigest("93.184.216.34")

    init(
        controllerStartIdentity: String = "controller-preflight-start",
        forbiddenSentinels: [Data] = [],
        priorSSIDMismatch: ReadinessScenario? = nil,
        receiptTargetMismatch: Bool = false,
        receiptDeviceMismatch: Bool = false
    ) throws {
        let observerSigner = LiveProofEphemeralSigner()
        let providerKey = Curve25519.Signing.PrivateKey()
        let controllerHash = oracleDigest("controller-executable")
        let preflightController = try LiveProofProcessIdentity(
            pid: 100,
            startIdentity: controllerStartIdentity,
            executableSHA256: controllerHash
        )
        let liveController = try LiveProofProcessIdentity(
            pid: 101,
            startIdentity: "controller-live-start",
            executableSHA256: controllerHash
        )
        let observer = try LiveProofProcessIdentity(
            pid: 200,
            startIdentity: "observer-start",
            executableSHA256: oracleDigest("observer-executable")
        )
        let oracle = try LiveProofProcessIdentity(
            pid: 300,
            startIdentity: "oracle-start",
            executableSHA256: oracleDigest("oracle-executable")
        )
        let binding = try LiveProofArmingBinding(
            runID: runID,
            machineDigest: oracleDigest("machine"),
            baselineDigest: baselineDigest,
            controllerSHA256: controllerHash,
            observer: observer,
            observerPublicKey: observerSigner.publicKeyBase64URL,
            appIdentityDigest: appDigest,
            helperIdentityDigest: helperDigest,
            providerOrigin: "https://proof.example",
            outputDirectoryDigest: oracleDigest("output"),
            targetSSIDDigest: receiptTargetMismatch
                ? oracleDigest("other-target-ssid") : targetDigest,
            wifiDeviceDigest: receiptDeviceMismatch
                ? oracleDigest("other-wifi-device") : wifiDeviceDigest
        )
        let receipt = LiveProofArmingReceipt(
            issuedAtUnixMilliseconds: 1_000,
            expiresAtUnixMilliseconds: 1_000 + LiveProofArming.lifetimeMilliseconds,
            challengeSHA256: oracleDigest("challenge"),
            binding: binding,
            authenticationCode: LiveProofBase64URL.encode(Data(repeating: 7, count: 32))
        )
        let capability = LiveOracleProviderCapability(
            capabilityPath: "/v1/capability",
            submitPath: "/v1/submit",
            readbackPath: "/v1/readback",
            serverUnixMilliseconds: 50_000,
            clockOffsetMilliseconds: 0,
            maximumClockSkewSeconds: 1
        )
        let preflight = LiveOraclePreflightReadback(
            runID: runID,
            producer: observer,
            observerPublicKey: observerSigner.publicKeyBase64URL,
            machineDigest: binding.machineDigest,
            baselineDigest: baselineDigest,
            appIdentityDigest: appDigest,
            helperIdentityDigest: helperDigest,
            priorSSIDDigest: priorDigest,
            targetSSIDDigest: targetDigest,
            providerOrigin: binding.providerOrigin,
            providerPublicKey: LiveProofBase64URL.encode(
                providerKey.publicKey.rawRepresentation
            ),
            outputDirectoryDigest: binding.outputDirectoryDigest,
            observerUIDDigest: oracleDigest("uid"),
            preflightPeerUIDDigest: oracleDigest("uid"),
            capability: capability
        )
        let evidence = try OracleFixtureEvidence(
            runID: runID,
            observerSigner: observerSigner,
            providerKey: providerKey,
            preflightController: preflightController,
            liveController: liveController,
            observer: observer,
            preflight: preflight,
            baselineDigest: baselineDigest,
            priorDigest: priorDigest,
            targetDigest: targetDigest,
            wifiDeviceDigest: wifiDeviceDigest,
            localAddressDigest: localAddressDigest,
            remoteAddressDigest: remoteAddressDigest,
            appDigest: appDigest,
            helperDigest: helperDigest,
            priorSSIDMismatch: priorSSIDMismatch
        )
        var bytes: [String: Data] = [
            "arming-receipt.json": try LiveProofCanonicalJSON.encode(receipt),
            "preflight-readback.json": try LiveProofCanonicalJSON.encode(preflight),
            "command-events.json": try LiveProofCanonicalJSON.encode(evidence.command),
            "operator-events.json": try LiveProofCanonicalJSON.encode(evidence.operatorEvents),
            "cleanup-events.json": try LiveProofCanonicalJSON.encode(evidence.cleanup),
            "provider-transport-events.json":
                try LiveProofCanonicalJSON.encode(evidence.transport),
            "provider-receipts.json": try LiveProofCanonicalJSON.encode(evidence.receipts),
            "observer-events.json": try LiveProofCanonicalJSON.encode(evidence.observerEvents),
        ]
        let observerEntries = try OracleFixture.observerEntries(
            bytes: bytes,
            observer: observer
        )
        let sealPayload = LiveOracleObserverSealPayload(
            runID: runID,
            observer: observer,
            observerPublicKey: observerSigner.publicKeyBase64URL,
            eventCount: evidence.observerEvents.events.count,
            finalEnvelopeSHA256: try LiveProofEphemeralSigner.envelopeSHA256(
                evidence.observerEvents.events.last!
            ),
            observerOwnedFiles: observerEntries
        )
        bytes["observer-seal.json"] = try LiveProofCanonicalJSON.encode(
            observerSigner.signedPayload(
                LiveProofCanonicalJSON.encode(sealPayload),
                domain: .seal
            )
        )
        let manifestEntries = OracleFixture.manifestEntries(
            bytes: bytes,
            preflightController: preflightController,
            liveController: liveController,
            observer: observer
        )
        bytes["seal-manifest.json"] = try LiveProofCanonicalJSON.encode(
            LiveOracleSealManifest(
                runID: runID,
                author: liveController,
                entries: manifestEntries
            )
        )
        let marker = Data(ReadinessDigest.sha256Hex(
            try LiveProofCanonicalJSON.encode(receipt)
        ).utf8)
        let preparedOwnerUID: UInt32 = 501
        var prepared = bytes.mapValues {
            LiveOracleFile(
                data: $0,
                metadata: LiveOracleFileMetadata(
                    byteCount: Int64($0.count),
                    mode: 0o400,
                    ownerUID: preparedOwnerUID,
                    isRegularFile: true
                )
            )
        }
        prepared[".arming-consumed"] = LiveOracleFile(
            data: marker,
            metadata: LiveOracleFileMetadata(
                byteCount: Int64(marker.count),
                mode: 0o600,
                ownerUID: preparedOwnerUID,
                isRegularFile: true
            )
        )
        files = prepared
        request = LiveOracleRequest(
            evidenceDirectory: URL(fileURLWithPath: "/oracle-fixture"),
            oracle: oracle,
            expectedOwnerUID: ownerUID,
            forbiddenSentinels: forbiddenSentinels
        )
    }

    private static func observerEntries(
        bytes: [String: Data],
        observer: LiveProofProcessIdentity
    ) throws -> [LiveOracleManifestEntry] {
        try [
            "preflight-readback.json", "provider-transport-events.json",
            "provider-receipts.json", "observer-events.json",
        ].map {
            let data = try XCTUnwrap(bytes[$0])
            return LiveOracleManifestEntry(
                name: $0,
                role: .observer,
                author: observer,
                byteCount: Int64(data.count),
                sha256: ReadinessDigest.sha256Hex(data)
            )
        }.sorted { $0.name < $1.name }
    }

    private static func manifestEntries(
        bytes: [String: Data],
        preflightController: LiveProofProcessIdentity,
        liveController: LiveProofProcessIdentity,
        observer: LiveProofProcessIdentity
    ) -> [LiveOracleManifestEntry] {
        bytes.map { name, data in
            let observerNames: Set<String> = [
                "preflight-readback.json", "provider-transport-events.json",
                "provider-receipts.json", "observer-events.json", "observer-seal.json",
            ]
            let author = name == "arming-receipt.json"
                ? preflightController
                : (observerNames.contains(name) ? observer : liveController)
            return LiveOracleManifestEntry(
                name: name,
                role: observerNames.contains(name) ? .observer : .controller,
                author: author,
                byteCount: Int64(data.count),
                sha256: ReadinessDigest.sha256Hex(data)
            )
        }.sorted { $0.name < $1.name }
    }
}

private struct OracleFixtureEvidence {
    let command: LiveOracleControllerArtifact
    let operatorEvents: LiveOracleControllerArtifact
    let cleanup: LiveOracleControllerArtifact
    let transport: LiveOracleProviderTransportArtifact
    let receipts: LiveOracleProviderReceiptsArtifact
    let observerEvents: LiveOracleObserverEventsArtifact

    init(
        runID: String,
        observerSigner: LiveProofEphemeralSigner,
        providerKey: Curve25519.Signing.PrivateKey,
        preflightController: LiveProofProcessIdentity,
        liveController: LiveProofProcessIdentity,
        observer: LiveProofProcessIdentity,
        preflight: LiveOraclePreflightReadback,
        baselineDigest: String,
        priorDigest: String,
        targetDigest: String,
        wifiDeviceDigest: String,
        localAddressDigest: String,
        remoteAddressDigest: String,
        appDigest: String,
        helperDigest: String,
        priorSSIDMismatch: ReadinessScenario?
    ) throws {
        var builder = OracleEventBuilder(
            runID: runID,
            signer: observerSigner,
            preflight: preflight,
            baselineDigest: baselineDigest,
            priorDigest: priorDigest,
            targetDigest: targetDigest,
            wifiDeviceDigest: wifiDeviceDigest,
            localAddressDigest: localAddressDigest,
            remoteAddressDigest: remoteAddressDigest,
            appDigest: appDigest,
            helperDigest: helperDigest
        )
        try builder.appendPreflight()
        var commandEvents: [LiveOracleControllerEvent] = []
        var operatorRecords: [LiveOracleControllerEvent] = []
        var transportRecords: [LiveOracleProviderTransportRecord] = []
        var receiptSets: [LiveOracleProviderReceiptSet] = []
        var nonceValue: UInt8 = 1
        for (offset, scenario) in ReadinessScenario.allCases.enumerated() {
            let base = Int64((offset + 1) * 100_000)
            let process = try LiveProofProcessIdentity(
                pid: Int32(400 + offset),
                startIdentity: "app-\(scenario.rawValue)-start",
                executableSHA256: appDigest
            )
            commandEvents.append(oracleControllerEvent(
                commandEvents.count + 1, base, scenario, .appLaunchRequest
            ))
            operatorRecords += oracleOperatorEvents(
                scenario: scenario,
                base: base,
                startingSequence: operatorRecords.count + 1
            )
            try builder.appendBaseline(scenario: scenario, at: base)
            var scenarioReceipts: [LiveProofProviderReceipt] = []
            for sequence in 1...3 {
                let dispatch = base + 2_000 + Int64(sequence - 1) * 5_500
                let before = try builder.appendClosed(
                    scenario: scenario,
                    kind: .closedBeforeTransport,
                    at: dispatch - 100
                )
                let after = try builder.appendClosed(
                    scenario: scenario,
                    kind: .closedAfterTransport,
                    at: dispatch + 200
                )
                let nonce = LiveProofBase64URL.encode(
                    Data(repeating: nonceValue, count: 32)
                )
                nonceValue += 1
                transportRecords.append(LiveOracleProviderTransportRecord(
                    scenario: scenario,
                    sequence: sequence,
                    nonce: nonce,
                    dispatchUnixMilliseconds: dispatch,
                    completionUnixMilliseconds: dispatch + 100,
                    localAddressDigest: localAddressDigest,
                    remoteAddressDigest: remoteAddressDigest,
                    beforeObserverEventSequence: before,
                    afterObserverEventSequence: after
                ))
                commandEvents.append(LiveOracleControllerEvent(
                    sequence: commandEvents.count + 1,
                    unixMilliseconds: dispatch,
                    monotonicNanoseconds: oracleMonotonic(dispatch),
                    scenario: scenario,
                    kind: .heartbeatSubmitRequest,
                    heartbeatSequence: sequence,
                    nonce: nonce
                ))
                scenarioReceipts.append(try oracleSignedReceipt(
                    runID: runID,
                    scenario: scenario,
                    sequence: sequence,
                    nonce: nonce,
                    receiveTime: dispatch + 50,
                    privateKey: providerKey
                ))
            }
            commandEvents.append(oracleControllerEvent(
                commandEvents.count + 1, base + 15_500, scenario,
                .heartbeatReadbackRequest
            ))
            try builder.appendScenarioEnding(
                scenario: scenario,
                base: base,
                process: process,
                priorSSIDMismatch: priorSSIDMismatch == scenario
            )
            if scenario == .ownerDeath {
                commandEvents.append(LiveOracleControllerEvent(
                    sequence: commandEvents.count + 1,
                    unixMilliseconds: base + 16_000,
                    monotonicNanoseconds: oracleMonotonic(base + 16_000),
                    scenario: scenario,
                    kind: .ownerDeathSIGKILLRequest,
                    process: process,
                    signal: SIGKILL
                ))
            }
            receiptSets.append(LiveOracleProviderReceiptSet(
                scenario: scenario,
                receipts: scenarioReceipts
            ))
        }
        command = LiveOracleControllerArtifact(
            schema: "codex-travel-mode-command-events/v1",
            runID: runID,
            producer: liveController,
            events: commandEvents
        )
        operatorEvents = LiveOracleControllerArtifact(
            schema: "codex-travel-mode-operator-events/v1",
            runID: runID,
            producer: liveController,
            events: operatorRecords
        )
        cleanup = LiveOracleControllerArtifact(
            schema: "codex-travel-mode-cleanup-events/v1",
            runID: runID,
            producer: liveController,
            events: []
        )
        transport = LiveOracleProviderTransportArtifact(
            runID: runID,
            producer: observer,
            records: transportRecords
        )
        receipts = LiveOracleProviderReceiptsArtifact(
            runID: runID,
            producer: observer,
            receiptSets: receiptSets
        )
        let preflightHandshake = try LiveProofHandshakePayload(
            runID: runID,
            phase: .preflight,
            client: preflightController,
            controllerSHA256: preflightController.executableSHA256,
            requestSequenceStart: 1
        )
        let liveHandshake = try LiveProofHandshakePayload(
            runID: runID,
            phase: .live,
            client: liveController,
            controllerSHA256: liveController.executableSHA256,
            requestSequenceStart: 2
        )
        observerEvents = LiveOracleObserverEventsArtifact(
            runID: runID,
            producer: observer,
            observerPublicKey: observerSigner.publicKeyBase64URL,
            handshakes: [
                try observerSigner.signedHandshake(preflightHandshake),
                try observerSigner.signedHandshake(liveHandshake),
            ],
            sessionPeerUIDDigests: [
                preflight.observerUIDDigest, preflight.observerUIDDigest,
            ],
            sessionCount: 2,
            rejectedAttachCount: 0,
            events: builder.envelopes
        )
    }
}

private struct OracleEventBuilder {
    let runID: String
    let signer: LiveProofEphemeralSigner
    let preflight: LiveOraclePreflightReadback
    let baselineDigest: String
    let priorDigest: String
    let targetDigest: String
    let wifiDeviceDigest: String
    let localAddressDigest: String
    let remoteAddressDigest: String
    let appDigest: String
    let helperDigest: String
    private(set) var envelopes: [LiveProofSignedEventEnvelope] = []

    mutating func appendPreflight() throws {
        _ = try append(
            scenario: nil,
            kind: .preflightSample,
            at: 50_000,
            snapshot: baselineSnapshot()
        )
    }

    mutating func appendBaseline(scenario: ReadinessScenario, at time: Int64) throws {
        _ = try append(
            scenario: scenario,
            kind: .scenarioBaseline,
            at: time,
            baselineDigest: baselineDigest,
            snapshot: baselineSnapshot()
        )
    }

    mutating func appendClosed(
        scenario: ReadinessScenario,
        kind: LiveOracleObserverEventKind,
        at time: Int64
    ) throws -> Int {
        try append(
            scenario: scenario,
            kind: kind,
            at: time,
            snapshot: closedSnapshot()
        )
    }

    mutating func appendScenarioEnding(
        scenario: ReadinessScenario,
        base: Int64,
        process: LiveProofProcessIdentity,
        priorSSIDMismatch: Bool
    ) throws {
        switch scenario {
        case .stop:
            _ = try append(
                scenario: scenario,
                kind: .mandatoryCleanup,
                at: base + 16_500,
                snapshot: restoredSnapshot(appRunning: true)
            )
            _ = try appendFinal(scenario, at: base + 18_000, mismatch: priorSSIDMismatch)
        case .quit:
            _ = try append(
                scenario: scenario,
                kind: .mandatoryCleanup,
                at: base + 16_500,
                snapshot: restoredSnapshot(appRunning: true)
            )
            _ = try append(
                scenario: scenario,
                kind: .processExit,
                at: base + 17_000,
                process: process
            )
            _ = try appendFinal(scenario, at: base + 18_000, mismatch: priorSSIDMismatch)
        case .ownerDeath:
            _ = try append(
                scenario: scenario,
                kind: .processExit,
                at: base + 16_500,
                process: process
            )
            _ = try append(
                scenario: scenario,
                kind: .ownerDeathHelperStage,
                at: base + 17_000,
                snapshot: ownerDeathHelperSnapshot()
            )
            _ = try append(
                scenario: scenario,
                kind: .ownerDeathRelaunchedCleanup,
                at: base + 18_000,
                snapshot: restoredSnapshot(appRunning: true)
            )
            _ = try appendFinal(scenario, at: base + 19_000, mismatch: priorSSIDMismatch)
        }
    }

    private mutating func appendFinal(
        _ scenario: ReadinessScenario,
        at time: Int64,
        mismatch: Bool
    ) throws -> Int {
        try append(
            scenario: scenario,
            kind: .scenarioFinal,
            at: time,
            snapshot: restoredSnapshot(
                appRunning: false,
                ssidDigest: mismatch ? targetDigest : priorDigest
            )
        )
    }

    private mutating func append(
        scenario: ReadinessScenario?,
        kind: LiveOracleObserverEventKind,
        at time: Int64,
        baselineDigest: String? = nil,
        snapshot: LiveOracleSystemSnapshot? = nil,
        process: LiveProofProcessIdentity? = nil
    ) throws -> Int {
        let sequence = envelopes.count + 1
        let payload = LiveOracleObserverEventPayload(
            runID: runID,
            eventSequence: sequence,
            requestSequence: sequence,
            phase: scenario == nil ? .preflight : .live,
            unixMilliseconds: time,
            monotonicNanoseconds: oracleMonotonic(time),
            scenario: scenario,
            kind: kind,
            baselineDigest: baselineDigest,
            snapshot: snapshot,
            process: process
        )
        envelopes.append(try signer.eventEnvelope(
            payload: LiveProofCanonicalJSON.encode(payload),
            previous: envelopes.last
        ))
        return sequence
    }

    private func baselineSnapshot() -> LiveOracleSystemSnapshot {
        snapshot(
            lidClosed: false,
            sleepDisabled: 0,
            ssidDigest: priorDigest,
            addresses: [],
            routeRemote: nil,
            routeDevice: nil,
            appRunning: false,
            appJournal: .absent,
            helperJournal: .absent
        )
    }

    private func closedSnapshot() -> LiveOracleSystemSnapshot {
        snapshot(
            lidClosed: true,
            sleepDisabled: 1,
            ssidDigest: targetDigest,
            addresses: [localAddressDigest],
            routeRemote: remoteAddressDigest,
            routeDevice: wifiDeviceDigest,
            appRunning: true,
            appJournal: .present,
            helperJournal: .present
        )
    }

    private func restoredSnapshot(
        appRunning: Bool,
        ssidDigest: String? = nil
    ) -> LiveOracleSystemSnapshot {
        snapshot(
            lidClosed: false,
            sleepDisabled: 0,
            ssidDigest: ssidDigest ?? priorDigest,
            addresses: [],
            routeRemote: nil,
            routeDevice: nil,
            appRunning: appRunning,
            appJournal: .absent,
            helperJournal: .absent
        )
    }

    private func ownerDeathHelperSnapshot() -> LiveOracleSystemSnapshot {
        snapshot(
            lidClosed: false,
            sleepDisabled: 0,
            ssidDigest: targetDigest,
            addresses: [],
            routeRemote: nil,
            routeDevice: nil,
            appRunning: false,
            appJournal: .present,
            helperJournal: .absent
        )
    }

    private func snapshot(
        lidClosed: Bool,
        sleepDisabled: Int,
        ssidDigest: String?,
        addresses: [String],
        routeRemote: String?,
        routeDevice: String?,
        appRunning: Bool,
        appJournal: LiveOracleJournalState,
        helperJournal: LiveOracleJournalState
    ) -> LiveOracleSystemSnapshot {
        LiveOracleSystemSnapshot(
            powerSource: .battery,
            batteryPercent: 80,
            lidClosed: lidClosed,
            sleepDisabled: sleepDisabled,
            wifiPower: true,
            selectedWiFiDeviceDigest: wifiDeviceDigest,
            ssidDigest: ssidDigest,
            usableAddressDigests: addresses,
            routeRemoteAddressDigest: routeRemote,
            routeDeviceDigest: routeDevice,
            appRunning: appRunning,
            appJournal: appJournal,
            helperJournal: helperJournal,
            helperJournalAuthorizationCode: 0,
            appIdentityDigest: appDigest,
            helperIdentityDigest: helperDigest
        )
    }
}

private final class OracleMemoryFileAccess: LiveOracleFileAccess, @unchecked Sendable {
    private let lock = NSLock()
    private var files: [String: LiveOracleFile]
    private let mutateBeforeSecondSnapshot: String?
    private var namesCallCount = 0
    private(set) var reportCount = 0

    init(
        files: [String: LiveOracleFile],
        mutateBeforeSecondSnapshot: String? = nil
    ) {
        self.files = files
        self.mutateBeforeSecondSnapshot = mutateBeforeSecondSnapshot
    }

    func directoryMetadata(at directory: URL) throws -> LiveOracleFileMetadata {
        LiveOracleFileMetadata(
            byteCount: 0,
            mode: 0o700,
            ownerUID: 501,
            isRegularFile: false
        )
    }

    func names(in directory: URL) throws -> Set<String> {
        lock.lock()
        defer { lock.unlock() }
        namesCallCount += 1
        if namesCallCount == 2, let name = mutateBeforeSecondSnapshot,
           let original = files[name] {
            var changed = original.data
            changed.append(0x20)
            files[name] = LiveOracleFile(
                data: changed,
                metadata: LiveOracleFileMetadata(
                    byteCount: Int64(changed.count),
                    mode: original.metadata.mode,
                    ownerUID: original.metadata.ownerUID,
                    isRegularFile: true
                )
            )
        }
        return Set(files.keys)
    }

    func read(name: String, in directory: URL) throws -> LiveOracleFile {
        lock.lock()
        defer { lock.unlock() }
        return try XCTUnwrap(files[name])
    }

    func writeOracleReport(_ data: Data, in directory: URL) throws {
        lock.lock()
        defer { lock.unlock() }
        guard files["oracle-report.json"] == nil else {
            throw LiveOracleViolation("oracle_report_already_exists")
        }
        files["oracle-report.json"] = LiveOracleFile(
            data: data,
            metadata: LiveOracleFileMetadata(
                byteCount: Int64(data.count),
                mode: 0o400,
                ownerUID: 501,
                isRegularFile: true
            )
        )
        reportCount += 1
    }

    func file(named name: String) -> LiveOracleFile? {
        lock.lock()
        defer { lock.unlock() }
        return files[name]
    }
}

private struct OracleFixedIdentityProvider: LiveOracleIdentityProviding {
    let identity: LiveProofProcessIdentity

    init(_ identity: LiveProofProcessIdentity) {
        self.identity = identity
    }

    func currentIdentity() throws -> LiveProofProcessIdentity { identity }
}

private func oracleOperatorEvents(
    scenario: ReadinessScenario,
    base: Int64,
    startingSequence: Int
) -> [LiveOracleControllerEvent] {
    let values: [(LiveOracleControllerEventKind, Int64)]
    switch scenario {
    case .stop:
        values = [
            (.start, 100), (.lidClose, 500), (.lidOpen, 15_500),
            (.stopRestore, 16_000), (.quit, 17_500),
        ]
    case .quit:
        values = [
            (.start, 100), (.lidClose, 500), (.lidOpen, 15_500), (.quit, 16_000),
        ]
    case .ownerDeath:
        values = [
            (.start, 100), (.lidClose, 500), (.lidOpen, 17_100),
            (.relaunch, 17_500), (.quit, 18_500),
        ]
    }
    return values.enumerated().map { offset, value in
        oracleControllerEvent(
            startingSequence + offset,
            base + value.1,
            scenario,
            value.0
        )
    }
}

private func oracleControllerEvent(
    _ sequence: Int,
    _ time: Int64,
    _ scenario: ReadinessScenario,
    _ kind: LiveOracleControllerEventKind
) -> LiveOracleControllerEvent {
    LiveOracleControllerEvent(
        sequence: sequence,
        unixMilliseconds: time,
        monotonicNanoseconds: oracleMonotonic(time),
        scenario: scenario,
        kind: kind
    )
}

private func oracleSignedReceipt(
    runID: String,
    scenario: ReadinessScenario,
    sequence: Int,
    nonce: String,
    receiveTime: Int64,
    privateKey: Curve25519.Signing.PrivateKey
) throws -> LiveProofProviderReceipt {
    let source = LiveProofBase64URL.encode(Data([93, 184, 216, 34]))
    let placeholder = LiveProofBase64URL.encode(Data(repeating: 0, count: 64))
    let unsigned = try LiveProofProviderReceipt(
        runID: runID,
        scenario: scenario,
        sequence: sequence,
        nonce: nonce,
        serverReceiveUnixMilliseconds: receiveTime,
        sourceFamily: .ipv4,
        sourceAddress: source,
        signature: placeholder
    )
    return try LiveProofProviderReceipt(
        runID: runID,
        scenario: scenario,
        sequence: sequence,
        nonce: nonce,
        serverReceiveUnixMilliseconds: receiveTime,
        sourceFamily: .ipv4,
        sourceAddress: source,
        signature: LiveProofBase64URL.encode(
            try privateKey.signature(for: unsigned.canonicalSignedBytes)
        )
    )
}

private func oracleMonotonic(_ milliseconds: Int64) -> UInt64 {
    UInt64(milliseconds) * 1_000_000
}

private func oracleDigest(_ value: String) -> String {
    ReadinessDigest.sha256Hex(Data(value.utf8))
}
