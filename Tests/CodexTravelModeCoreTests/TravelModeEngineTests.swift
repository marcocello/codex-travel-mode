import CodexTravelModeCore
import XCTest

final class TravelModeEngineTests: XCTestCase {
    func testPreservesCurrentWiFiAndDoesNotJoinHotspot() async {
        let gateway = StubGateway(
            statuses: [
                WiFiStatus(device: "en0", networkName: "Office", rawOutput: "Current Wi-Fi Network: Office")
            ]
        )
        let settings = TravelModeSettings(hotspotSSID: "iPhone", wifiDevice: "en0")

        let event = await TravelModeEngine().sync(settings: settings, gateway: gateway)

        XCTAssertEqual(event, .preservedCurrentWiFi("Office"))
        XCTAssertEqual(gateway.joinAttempts, [])
        XCTAssertEqual(gateway.wifiPowerChanges, [])
    }

    func testPreservedCurrentWiFiDoesNotLoadFallbackPassword() async {
        let gateway = StubGateway(
            statuses: [
                WiFiStatus(device: "en0", networkName: "Office", rawOutput: "Current Wi-Fi Network: Office")
            ]
        )
        let settings = TravelModeSettings(hotspotSSID: "iPhone", wifiDevice: "en0")
        let passwordProvider = PasswordProviderSpy(password: "secret")

        let event = await TravelModeEngine().sync(
            settings: settings,
            gateway: gateway,
            passwordProvider: {
                passwordProvider.password()
            }
        )

        XCTAssertEqual(event, .preservedCurrentWiFi("Office"))
        XCTAssertEqual(passwordProvider.readCount, 0)
    }

    func testDisconnectedWiFiJoinsHotspotAndVerifiesConnection() async {
        let gateway = StubGateway(
            statuses: [
                WiFiStatus(
                    device: "en0",
                    networkName: nil,
                    rawOutput: "You are not associated with an AirPort network."
                ),
                WiFiStatus(device: "en0", networkName: "iPhone", rawOutput: "Current Wi-Fi Network: iPhone")
            ]
        )
        let settings = TravelModeSettings(
            hotspotSSID: "iPhone",
            hotspotPassword: "secret",
            wifiDevice: "en0"
        )

        let event = await TravelModeEngine().sync(settings: settings, gateway: gateway)

        XCTAssertEqual(event, .hotspotConnected("iPhone"))
        XCTAssertEqual(gateway.wifiPowerChanges, [true])
        XCTAssertEqual(gateway.joinAttempts, [JoinAttempt(device: "en0", ssid: "iPhone", password: "secret")])
    }

    func testDisconnectedWiFiWaitsForDelayedHotspotAssociation() async {
        let gateway = StubGateway(
            statuses: [
                WiFiStatus(
                    device: "en0",
                    networkName: nil,
                    rawOutput: "You are not associated with an AirPort network."
                ),
                WiFiStatus(
                    device: "en0",
                    networkName: nil,
                    rawOutput: "You are not associated with an AirPort network."
                ),
                WiFiStatus(device: "en0", networkName: "iPhone", rawOutput: "Current Wi-Fi Network: iPhone")
            ]
        )
        let settings = TravelModeSettings(
            hotspotSSID: "iPhone",
            hotspotPassword: "secret",
            wifiDevice: "en0"
        )
        let engine = TravelModeEngine(verificationAttempts: 2, verificationDelay: .zero)

        let event = await engine.sync(settings: settings, gateway: gateway)

        XCTAssertEqual(event, .hotspotConnected("iPhone"))
        XCTAssertEqual(gateway.joinAttempts, [JoinAttempt(device: "en0", ssid: "iPhone", password: "secret")])
    }

    func testDisconnectedWiFiFailureReportsPasswordWasProvided() async {
        let gateway = StubGateway(
            statuses: [
                WiFiStatus(
                    device: "en0",
                    networkName: nil,
                    rawOutput: "You are not associated with an AirPort network."
                ),
                WiFiStatus(
                    device: "en0",
                    networkName: nil,
                    rawOutput: "You are not associated with an AirPort network."
                )
            ]
        )
        let settings = TravelModeSettings(
            hotspotSSID: "iPhone",
            hotspotPassword: "secret",
            wifiDevice: "en0"
        )

        let event = await TravelModeEngine().sync(settings: settings, gateway: gateway)

        XCTAssertEqual(
            event,
            .hotspotFailed(
                "You are not associated with an AirPort network.\n\nPassword was provided to the password-based join backends, but macOS did not associate to 'iPhone'."
            )
        )
        XCTAssertEqual(gateway.joinAttempts, [JoinAttempt(device: "en0", ssid: "iPhone", password: "secret")])
    }

    func testDisconnectedWiFiLoadsSavedFallbackPasswordWhenNeeded() async {
        let gateway = StubGateway(
            statuses: [
                WiFiStatus(
                    device: "en0",
                    networkName: nil,
                    rawOutput: "You are not associated with an AirPort network."
                ),
                WiFiStatus(device: "en0", networkName: "iPhone", rawOutput: "Current Wi-Fi Network: iPhone")
            ]
        )
        let settings = TravelModeSettings(hotspotSSID: "iPhone", wifiDevice: "en0")

        let event = await TravelModeEngine().sync(
            settings: settings,
            gateway: gateway,
            passwordProvider: { "secret" }
        )

        XCTAssertEqual(event, .hotspotConnected("iPhone"))
        XCTAssertEqual(gateway.joinAttempts, [JoinAttempt(device: "en0", ssid: "iPhone", password: "secret")])
    }

    func testDisconnectedWiFiDoesNotJoinWithoutPassword() async {
        let gateway = StubGateway(
            statuses: [
                WiFiStatus(
                    device: "en0",
                    networkName: nil,
                    rawOutput: "You are not associated with an AirPort network."
                )
            ]
        )
        let settings = TravelModeSettings(hotspotSSID: "iPhone", wifiDevice: "en0")

        let event = await TravelModeEngine().sync(settings: settings, gateway: gateway)

        XCTAssertEqual(
            event.message,
            "Could not join the fallback hotspot.\n\nmacOS still reports: No hotspot password was available. Save the hotspot password again.\n\nThe app uses the saved hotspot password with networksetup. If this repeats, macOS is refusing to associate to that SSID; check that Personal Hotspot is discoverable and the saved password is correct."
        )
        XCTAssertEqual(gateway.joinAttempts, [])
    }

    func testMissingSettingsAreReportedWithoutCommands() async {
        let gateway = StubGateway(statuses: [])

        let event = await TravelModeEngine().sync(
            settings: TravelModeSettings(hotspotSSID: "", wifiDevice: "en0"),
            gateway: gateway
        )

        XCTAssertEqual(event, .missingHotspotSSID)
        XCTAssertEqual(gateway.commandsStarted, false)
    }
}

@MainActor
final class TravelModeAppStateTests: XCTestCase {
    private func makeAppState(
        gateway: StubGateway,
        settings: TravelModeSettings = TravelModeSettings(),
        settingsStore: InMemorySettingsStore? = nil,
        wifiDiscovery: any WiFiDiscoveryProviding = StubWiFiDiscoveryProvider(),
        sessionManager: StubSessionManager = StubSessionManager()
    ) -> TravelModeAppState {
        TravelModeAppState(
            gateway: gateway,
            settingsStore: settingsStore ?? InMemorySettingsStore(settings: settings),
            wifiDiscovery: wifiDiscovery,
            sessionManager: sessionManager
        )
    }

    func testRefreshConfigurationDiscoversWiFiDeviceAndSelectableNetworks() async {
        let discovery = StubWiFiDiscoveryProvider(
            snapshots: [
                wifiSnapshot(
                    interfaceName: "en0",
                    remembered: ["Office", "iPhone", "Office"],
                    visible: ["Zoo", "iPhone", "Alpha", "Zoo"]
                )
            ]
        )
        let appState = makeAppState(
            gateway: StubGateway(),
            wifiDiscovery: discovery
        )

        await appState.refreshConfiguration()

        XCTAssertEqual(appState.settings.wifiDevice, "en0")
        XCTAssertEqual(
            appState.availableHotspots.map(\.displayName),
            ["Office", "iPhone", "Alpha", "Zoo"]
        )
        XCTAssertEqual(appState.settings.hotspotSSID, "")
    }

    func testRefreshKeepsCanonicallyEquivalentSSIDsAsExactByteDistinctOptions() async {
        let composed = "\u{00E9}"
        let decomposed = "e\u{0301}"
        let discovery = StubWiFiDiscoveryProvider(
            snapshots: [wifiSnapshot(remembered: [composed, decomposed])]
        )
        let appState = makeAppState(
            gateway: StubGateway(),
            wifiDiscovery: discovery
        )

        await appState.refreshConfiguration()

        XCTAssertEqual(
            appState.availableHotspots.map(\.utf8Bytes),
            [Data(composed.utf8), Data(decomposed.utf8)]
        )
    }

    func testRefreshConfigurationKeepsExistingHotspotSelection() async {
        let discovery = StubWiFiDiscoveryProvider(
            snapshots: [wifiSnapshot(interfaceName: "en0", remembered: ["Office", "iPhone"])]
        )
        let appState = makeAppState(
            gateway: StubGateway(),
            wifiDiscovery: discovery
        )
        appState.settings.hotspotSSID = "Office"

        await appState.refreshConfiguration()

        XCTAssertEqual(appState.settings.hotspotSSID, "Office")
    }

    func testRefreshConfigurationKeepsSelectedHotspotWhenItIsNotCurrentlyVisible() async {
        let discovery = StubWiFiDiscoveryProvider(
            snapshots: [wifiSnapshot(interfaceName: "en0", remembered: ["CIC"])]
        )
        let appState = makeAppState(
            gateway: StubGateway(),
            settings: TravelModeSettings(
                hotspotSSID: "iPhone",
                hotspotPassword: "secret",
                wifiDevice: ""
            ),
            wifiDiscovery: discovery
        )

        await appState.refreshConfiguration()

        XCTAssertEqual(appState.settings.hotspotSSID, "iPhone")
        XCTAssertEqual(appState.availableHotspots.map(\.displayName), ["iPhone", "CIC"])
    }

    func testLoadsSavedSettingsOnInitAndCanSaveSelection() async throws {
        let store = InMemorySettingsStore(
            settings: TravelModeSettings(
                hotspotSSID: "iPhone",
                hotspotPassword: "secret",
                wifiDevice: "en0"
            )
        )
        let appState = TravelModeAppState(
            gateway: StubGateway(),
            settingsStore: store,
            wifiDiscovery: StubWiFiDiscoveryProvider(),
            sessionManager: StubSessionManager()
        )

        XCTAssertEqual(appState.settings.hotspotSSID, "iPhone")
        XCTAssertEqual(appState.settings.hotspotPassword, "")
        XCTAssertEqual(appState.settings.wifiDevice, "en0")
        XCTAssertTrue(appState.hasSavedHotspotPassword)

        appState.settings.hotspotSSID = "Office"
        appState.settings.hotspotPassword = "next-secret"
        try await appState.saveSettings()

        XCTAssertEqual(store.savedSettings?.hotspotSSID, "Office")
        XCTAssertEqual(store.savedSettings?.hotspotPassword, "next-secret")
        XCTAssertEqual(appState.settings.hotspotPassword, "")
    }

    func testDiscoveryFailureRetainsCommittedSelectionAndStartEligibilityWithoutReadingSecret() async {
        let store = InMemorySettingsStore(
            settings: TravelModeSettings(
                hotspotSSID: "Example's iPhone",
                hotspotPassword: "secret",
                wifiDevice: "en0"
            )
        )
        let failedSnapshot = wifiSnapshot(visibleScanStatus: .providerFailed)
        let discovery = StubWiFiDiscoveryProvider(snapshots: [failedSnapshot])
        let appState = makeAppState(
            gateway: StubGateway(codexRunning: true),
            settingsStore: store,
            wifiDiscovery: discovery
        )
        await appState.refreshStatus()
        let passwordReadsBeforeRefresh = store.passwordReadCount

        await appState.refreshConfiguration()

        XCTAssertEqual(appState.discoveryState, .loaded(failedSnapshot))
        XCTAssertEqual(appState.settings.hotspotSSID, "Example's iPhone")
        XCTAssertEqual(appState.availableHotspots.map(\.displayName), ["Example's iPhone"])
        XCTAssertTrue(appState.canStart)
        XCTAssertEqual(store.passwordReadCount, passwordReadsBeforeRefresh)
    }

    func testUnsavedManualDraftDisablesStartAndCannotEnterRuntime() async {
        let sessionManager = StubSessionManager()
        let appState = makeAppState(
            gateway: StubGateway(codexRunning: true),
            settings: TravelModeSettings(
                hotspotSSID: "Example's iPhone",
                hotspotPassword: "secret",
                wifiDevice: "en0"
            ),
            sessionManager: sessionManager
        )
        await appState.refreshStatus()
        appState.settings.hotspotSSID = "Unsaved manual hotspot"

        XCTAssertTrue(appState.hasUnsavedHotspotDraft)
        XCTAssertFalse(appState.canStart)

        await appState.start()

        XCTAssertFalse(appState.isRunning)
        XCTAssertEqual(appState.sessionLifecycle, .off)
        XCTAssertTrue(sessionManager.startedConfigurations.isEmpty)
        XCTAssertEqual(appState.latestStatus, "Cannot start: save or discard the hotspot changes first.")
    }

    func testStaleFirstRefreshCompletionCannotOverwriteNewerDiscovery() async {
        let staleSnapshot = wifiSnapshot(interfaceName: "en0", remembered: ["Old hotspot"])
        let currentSnapshot = wifiSnapshot(interfaceName: "en1", remembered: ["Current hotspot"])
        let discovery = StubWiFiDiscoveryProvider(
            snapshots: [staleSnapshot, currentSnapshot],
            suspendedRequestIndexes: [0]
        )
        let appState = makeAppState(
            gateway: StubGateway(),
            wifiDiscovery: discovery
        )

        let staleRefresh = Task { @MainActor in
            await appState.refreshConfiguration()
        }
        await discovery.waitForSnapshotRequestCount(1)
        await appState.refreshConfiguration()

        XCTAssertEqual(appState.settings.wifiDevice, "en1")
        XCTAssertEqual(appState.availableHotspots.map(\.displayName), ["Current hotspot"])

        await discovery.resumeSnapshotRequest(at: 0)
        await staleRefresh.value

        XCTAssertEqual(appState.discoveryState, .loaded(currentSnapshot))
        XCTAssertEqual(appState.settings.wifiDevice, "en1")
        XCTAssertEqual(appState.availableHotspots.map(\.displayName), ["Current hotspot"])
    }

    func testSaveAndRefreshAreBlockedForEveryNonOffLifecycle() async {
        let lockedLifecycles: [TravelSessionLifecycle] = [
            .preparing,
            .active,
            .restoring,
            .cleanupRequired,
        ]

        for lifecycle in lockedLifecycles {
            let store = InMemorySettingsStore(
                settings: TravelModeSettings(
                    hotspotSSID: "Example's iPhone",
                    hotspotPassword: "secret",
                    wifiDevice: "en0"
                )
            )
            let discovery = StubWiFiDiscoveryProvider(
                snapshots: [wifiSnapshot(interfaceName: "en1", remembered: ["Office"])]
            )
            let appState = makeAppState(
                gateway: StubGateway(),
                settingsStore: store,
                wifiDiscovery: discovery,
                sessionManager: StubSessionManager(lifecycle: lifecycle)
            )
            appState.settings.hotspotPassword = "replacement"

            do {
                try await appState.saveSettings()
                XCTFail("Save unexpectedly succeeded while lifecycle was \(lifecycle.rawValue)")
            } catch {}

            await appState.refreshConfiguration()

            XCTAssertEqual(appState.sessionLifecycle, lifecycle)
            XCTAssertEqual(store.saveCount, 0)
            let discoveryRequestCount = await discovery.snapshotRequestCount()
            XCTAssertEqual(
                discoveryRequestCount,
                0,
                "Refresh should be blocked while lifecycle is \(lifecycle.rawValue)"
            )
        }
    }

    func testSuccessfulSaveClearsPasswordDraftAndCommitsReplacement() async throws {
        let store = InMemorySettingsStore(
            settings: TravelModeSettings(
                hotspotSSID: "Example's iPhone",
                hotspotPassword: "old-secret",
                wifiDevice: "en0"
            )
        )
        let appState = makeAppState(
            gateway: StubGateway(),
            settingsStore: store
        )
        appState.settings.hotspotPassword = "new-secret"

        try await appState.saveSettings()

        XCTAssertEqual(appState.settings.hotspotPassword, "")
        XCTAssertFalse(appState.hasUnsavedHotspotDraft)
        XCTAssertEqual(try store.loadHotspotPassword(), "new-secret")
    }

    func testSecondSaveIsRejectedWhileFirstAwaitsLifecycleCheck() async throws {
        let store = InMemorySettingsStore(
            settings: TravelModeSettings(
                hotspotSSID: "Example's iPhone",
                hotspotPassword: "old-secret",
                wifiDevice: "en0"
            )
        )
        let sessionManager = StubSessionManager(suspendLifecycleReads: true)
        let appState = makeAppState(
            gateway: StubGateway(),
            settingsStore: store,
            sessionManager: sessionManager
        )
        appState.settings.hotspotPassword = "new-secret"

        let firstSave = Task { @MainActor in
            try await appState.saveSettings()
        }
        await sessionManager.waitForLifecycleReadCount(1)

        let secondSave = Task { @MainActor () -> Error? in
            do {
                try await appState.saveSettings()
                return nil
            } catch {
                return error
            }
        }
        try await Task.sleep(for: .milliseconds(10))

        XCTAssertEqual(sessionManager.lifecycleReadCount, 1)
        sessionManager.resumeLifecycleReads()
        try await firstSave.value

        let secondError = await secondSave.value
        XCTAssertNotNil(secondError)
        XCTAssertEqual(store.saveCount, 1)
    }

    func testStartReservationRejectsSaveBeforeStartValidationCompletes() async throws {
        let store = InMemorySettingsStore(
            settings: TravelModeSettings(
                hotspotSSID: "Example's iPhone",
                hotspotPassword: "secret",
                wifiDevice: "en0"
            )
        )
        let sessionManager = StubSessionManager(suspendLifecycleReads: true)
        let appState = makeAppState(
            gateway: StubGateway(codexRunning: true),
            settingsStore: store,
            sessionManager: sessionManager
        )

        let start = Task { @MainActor in await appState.start() }
        await sessionManager.waitForLifecycleReadCount(1)
        appState.settings.hotspotPassword = "replacement"

        await XCTAssertThrowsErrorAsync {
            try await appState.saveSettings()
        }
        XCTAssertEqual(store.saveCount, 0)

        appState.settings.hotspotPassword = ""
        sessionManager.resumeLifecycleReads()
        await start.value
        XCTAssertEqual(sessionManager.startedConfigurations.count, 1)
    }

    func testSaveFirstQuitWaitsForCoherentSaveBoundary() async throws {
        let store = InMemorySettingsStore(
            settings: TravelModeSettings(
                hotspotSSID: "Example's iPhone",
                hotspotPassword: "secret",
                wifiDevice: "en0"
            )
        )
        let sessionManager = StubSessionManager(suspendLifecycleReads: true)
        let appState = makeAppState(
            gateway: StubGateway(),
            settingsStore: store,
            sessionManager: sessionManager
        )
        appState.settings.hotspotPassword = "replacement"

        let save = Task { @MainActor in try await appState.saveSettings() }
        await sessionManager.waitForLifecycleReadCount(1)
        let quit = Task { @MainActor in await appState.requestQuit() }
        await Task.yield()

        XCTAssertEqual(sessionManager.quitCount, 0)
        sessionManager.resumeLifecycleReads()
        try await save.value
        let canQuit = await quit.value
        XCTAssertTrue(canQuit)
        XCTAssertEqual(store.saveCount, 1)
        XCTAssertEqual(
            sessionManager.quitCount,
            0,
            "Quit from verified clean Off must not dispatch session cleanup"
        )
    }

    func testQuitFirstBlocksSaveStartAndRefreshUntilTerminationReply() async throws {
        let store = InMemorySettingsStore(
            settings: TravelModeSettings(
                hotspotSSID: "Example's iPhone",
                hotspotPassword: "secret",
                wifiDevice: "en0"
            )
        )
        let discovery = StubWiFiDiscoveryProvider(
            snapshots: [wifiSnapshot(remembered: ["Office"])]
        )
        let sessionManager = StubSessionManager(suspendQuitRequests: true)
        let appState = makeAppState(
            gateway: StubGateway(codexRunning: true),
            settingsStore: store,
            wifiDiscovery: discovery,
            sessionManager: sessionManager
        )

        let quit = Task { @MainActor in await appState.requestQuit() }
        await sessionManager.waitForQuitCount(1)
        appState.settings.hotspotPassword = "replacement"
        await XCTAssertThrowsErrorAsync { try await appState.saveSettings() }
        await appState.start()
        await appState.refreshConfiguration()

        XCTAssertEqual(store.saveCount, 0)
        XCTAssertTrue(sessionManager.startedConfigurations.isEmpty)
        let discoveryCount = await discovery.snapshotRequestCount()
        XCTAssertEqual(discoveryCount, 0)

        sessionManager.resumeQuitRequests()
        let canQuit = await quit.value
        XCTAssertTrue(canQuit)
    }

    func testRuntimeUsesFrozenSSIDAndPasswordAfterExternalPointerChange() async throws {
        let gateway = StubGateway(
            statuses: [
                WiFiStatus(device: "en0", networkName: "Office", rawOutput: "Office"),
                WiFiStatus(device: "en0", networkName: nil, rawOutput: "not associated"),
                WiFiStatus(device: "en0", networkName: "Old iPhone", rawOutput: "Old iPhone")
            ],
            codexRunning: true
        )
        let store = InMemorySettingsStore(
            settings: TravelModeSettings(
                hotspotSSID: "Old iPhone",
                hotspotPassword: "old secret",
                wifiDevice: "en0"
            )
        )
        let appState = makeAppState(gateway: gateway, settingsStore: store)

        await appState.start()
        try store.replaceCommittedConfiguration(
            TravelModeSettings(
                hotspotSSID: "New iPhone",
                hotspotPassword: "new secret",
                wifiDevice: "en0"
            )
        )
        await appState.syncOnce()

        XCTAssertEqual(
            gateway.joinAttempts,
            [JoinAttempt(device: "en0", ssid: "Old iPhone", password: "old secret")]
        )
    }

    func testCleanupFailureReloadsCommittedCandidateAndKeepsStartEligible() async throws {
        let store = InMemorySettingsStore(
            settings: TravelModeSettings(
                hotspotSSID: "Old iPhone",
                hotspotPassword: "old secret",
                wifiDevice: "en0"
            )
        )
        let appState = makeAppState(
            gateway: StubGateway(codexRunning: true),
            settingsStore: store
        )
        await appState.refreshStatus()
        appState.settings.hotspotSSID = "New iPhone"
        appState.settings.hotspotPassword = "new secret"
        store.failNextSaveAfterCommit(with: .cleanupFailed("injected cleanup failure"))

        await XCTAssertThrowsErrorAsync { try await appState.saveSettings() }

        XCTAssertEqual(appState.committedHotspotSSID, "New iPhone")
        XCTAssertEqual(appState.settings.hotspotSSID, "New iPhone")
        XCTAssertEqual(appState.settings.hotspotPassword, "")
        XCTAssertFalse(appState.hasUnsavedHotspotDraft)
        XCTAssertTrue(appState.canStart)
    }

    func testStartAndStopDelegateOwnedCleanupToSessionManager() async {
        let gateway = StubGateway(
            statuses: [
                WiFiStatus(device: "en0", networkName: "Office", rawOutput: "Current Wi-Fi Network: Office")
            ],
            discoveredDevice: "en0",
            knownNetworks: ["Office", "iPhone"],
            codexRunning: true,
            wifiPower: true
        )
        let sessionManager = StubSessionManager()
        let appState = makeAppState(
            gateway: gateway,
            settings: TravelModeSettings(hotspotSSID: "iPhone", hotspotPassword: "secret", wifiDevice: "en0"),
            sessionManager: sessionManager
        )

        await appState.start()
        await appState.stop()

        XCTAssertEqual(
            sessionManager.startedConfigurations,
            [TravelSessionConfiguration(wifiDevice: "en0")]
        )
        XCTAssertEqual(sessionManager.stopCount, 1)
    }

    func testHelperProtectionLossRevokesActiveAndRunsRecovery() async throws {
        let gateway = StubGateway(
            statuses: [
                WiFiStatus(device: "en0", networkName: "Office", rawOutput: "Current Wi-Fi Network: Office")
            ],
            codexRunning: true,
            wifiPower: true
        )
        let sessionManager = StubSessionManager(
            recoverResult: TravelSessionTransitionResult(
                lifecycle: .cleanupRequired,
                error: "Helper unavailable",
                canTerminate: false
            )
        )
        let appState = makeAppState(
            gateway: gateway,
            settings: TravelModeSettings(
                hotspotSSID: "iPhone",
                hotspotPassword: "secret",
                wifiDevice: "en0"
            ),
            sessionManager: sessionManager
        )

        await appState.start()
        XCTAssertTrue(appState.isRunning)

        sessionManager.sendProtectionEvent(.connectionInvalidated)
        for _ in 0..<100 where sessionManager.recoverCount == 0 {
            try await Task.sleep(for: .milliseconds(10))
        }

        XCTAssertFalse(appState.isRunning)
        XCTAssertEqual(sessionManager.recoverCount, 1)
        XCTAssertEqual(gateway.keepAwakeStopCount, 1)
        XCTAssertEqual(
            appState.latestStatus,
            "Cleanup required: Travel Mode could not verify restoration. Retry Cleanup."
        )
    }

    func testHelperProtectionLossDuringStartCannotLaterReportActive() async {
        let gateway = StubGateway(codexRunning: true, wifiPower: true)
        let sessionManager = StubSessionManager(
            recoverResult: TravelSessionTransitionResult(lifecycle: .off),
            protectionEventDuringStart: .connectionInvalidated
        )
        let appState = makeAppState(
            gateway: gateway,
            settings: TravelModeSettings(
                hotspotSSID: "iPhone",
                hotspotPassword: "secret",
                wifiDevice: "en0"
            ),
            sessionManager: sessionManager
        )

        await appState.start()

        XCTAssertFalse(appState.isRunning)
        XCTAssertEqual(sessionManager.recoverCount, 1)
        XCTAssertFalse(gateway.commandsStarted)
        XCTAssertEqual(appState.latestStatus, "Travel Mode stopped after helper protection was lost.")
    }

    func testRecoverPreviousSessionDelegatesToTransactionalCoordinator() async {
        let store = InMemorySettingsStore(
            settings: TravelModeSettings(hotspotSSID: "iPhone", hotspotPassword: "secret", wifiDevice: "en0")
        )
        let gateway = StubGateway()
        let sessionManager = StubSessionManager(lifecycle: .cleanupRequired)
        let appState = TravelModeAppState(
            gateway: gateway,
            settingsStore: store,
            wifiDiscovery: StubWiFiDiscoveryProvider(),
            sessionManager: sessionManager
        )

        await appState.recoverPreviousSessionIfNeeded()

        XCTAssertEqual(sessionManager.recoverCount, 1)
        XCTAssertTrue(gateway.wifiPowerChanges.isEmpty)
        XCTAssertEqual(appState.latestStatus, "Recovered previous Travel Mode settings")
    }

    func testStopLeavesWiFiRestorationToSessionManager() async {
        let gateway = StubGateway(
            statuses: [
                WiFiStatus(device: "en0", networkName: "Office", rawOutput: "Current Wi-Fi Network: Office")
            ],
            codexRunning: true,
            wifiPower: false
        )
        let sessionManager = StubSessionManager()
        let appState = makeAppState(
            gateway: gateway,
            settings: TravelModeSettings(hotspotSSID: "iPhone", hotspotPassword: "secret", wifiDevice: "en0"),
            sessionManager: sessionManager
        )

        await appState.start()
        await appState.stop()

        XCTAssertEqual(sessionManager.stopCount, 1)
        XCTAssertTrue(gateway.wifiPowerChanges.isEmpty)
    }

    func testOpenWiFiSettingsDelegatesToGateway() async {
        let gateway = StubGateway()
        let appState = makeAppState(gateway: gateway)

        await appState.openWiFiSettings()

        XCTAssertEqual(gateway.didOpenWiFiSettings, true)
    }

    func testRefreshStatusTracksCodexRunning() async {
        let gateway = StubGateway(
            statuses: [
                WiFiStatus(device: "en0", networkName: "Office", rawOutput: "Current Wi-Fi Network: Office")
            ],
            codexRunning: true
        )
        let appState = makeAppState(gateway: gateway)
        appState.settings.wifiDevice = "en0"

        await appState.refreshStatus()

        XCTAssertEqual(appState.isCodexRunning, true)
    }

    func testStartRequiresCodexRunning() async {
        let gateway = StubGateway(codexRunning: false)
        let appState = makeAppState(
            gateway: gateway,
            settings: TravelModeSettings(hotspotSSID: "iPhone", hotspotPassword: "secret", wifiDevice: "en0")
        )

        await appState.start()

        XCTAssertEqual(appState.isRunning, false)
        XCTAssertEqual(appState.latestStatus, "Cannot start: Codex is not running.")
    }

    func testStartRequiresSavedHotspotPassword() async {
        let gateway = StubGateway(codexRunning: true)
        let appState = makeAppState(
            gateway: gateway,
            settings: TravelModeSettings(hotspotSSID: "iPhone", hotspotPassword: "", wifiDevice: "en0")
        )

        await appState.start()

        XCTAssertEqual(appState.isRunning, false)
        XCTAssertEqual(
            appState.latestStatus,
            "Cannot start: the committed hotspot password is unavailable."
        )
    }

    func testStartWhileDisconnectedDoesNotImmediatelyJoinFallback() async {
        let gateway = StubGateway(
            statuses: [
                WiFiStatus(
                    device: "en0",
                    networkName: nil,
                    rawOutput: "You are not associated with an AirPort network."
                )
            ],
            codexRunning: true
        )
        let appState = makeAppState(
            gateway: gateway,
            settings: TravelModeSettings(
                hotspotSSID: "iPhone",
                hotspotPassword: "secret",
                wifiDevice: "en0"
            )
        )

        await appState.syncOnce()

        XCTAssertEqual(gateway.joinAttempts, [])
        XCTAssertEqual(
            appState.latestStatus,
            "Travel Mode active; waiting for a connected Wi-Fi network to disconnect."
        )
    }

    func testRunningTravelModeJoinsFallbackAfterInitialDisconnectedState() async {
        let gateway = StubGateway(
            statuses: [
                WiFiStatus(
                    device: "en0",
                    networkName: nil,
                    rawOutput: "You are not associated with an AirPort network."
                ),
                WiFiStatus(
                    device: "en0",
                    networkName: nil,
                    rawOutput: "Wi-Fi power is currently off."
                ),
                WiFiStatus(device: "en0", networkName: "iPhone", rawOutput: "Current Wi-Fi Network: iPhone")
            ],
            codexRunning: true
        )
        let appState = makeAppState(
            gateway: gateway,
            settings: TravelModeSettings(
                hotspotSSID: "iPhone",
                hotspotPassword: "secret",
                wifiDevice: "en0"
            )
        )

        await appState.start()
        await appState.syncOnce()
        await appState.stop()

        XCTAssertEqual(gateway.joinAttempts, [JoinAttempt(device: "en0", ssid: "iPhone", password: "secret")])
    }

    func testWiFiStatusCommandFailureIsShownInsteadOfWaitingForDisconnect() async {
        let gateway = StubGateway(
            statuses: [
                WiFiStatus(
                    device: "en0",
                    networkName: nil,
                    rawOutput: "AuthorizationCreate() failed: -60008"
                )
            ]
        )
        let appState = makeAppState(
            gateway: gateway,
            settings: TravelModeSettings(hotspotSSID: "iPhone", wifiDevice: "en0")
        )

        await appState.syncOnce()

        XCTAssertEqual(gateway.joinAttempts, [])
        XCTAssertEqual(
            appState.latestStatus,
            "Travel Mode could not read the current Wi-Fi status."
        )
    }

    func testStartWhileConnectedArmsFallbackWithoutJoiningHotspot() async {
        let gateway = StubGateway(
            statuses: [
                WiFiStatus(device: "en0", networkName: "CIC", rawOutput: "Current Wi-Fi Network: CIC")
            ],
            codexRunning: true
        )
        let appState = makeAppState(
            gateway: gateway,
            settings: TravelModeSettings(
                hotspotSSID: "iPhone",
                hotspotPassword: "secret",
                wifiDevice: "en0"
            )
        )

        await appState.start()
        await appState.stop()

        XCTAssertEqual(
            appState.logs,
            [
                "Travel Mode started",
                "Watching Wi-Fi 'CIC'; fallback will run if it disconnects.",
                "Travel Mode stopped"
            ]
        )
        XCTAssertEqual(gateway.joinAttempts, [])
    }

    func testStartConnectedThenManualDisconnectJoinsFallbackHotspot() async {
        let gateway = StubGateway(
            statuses: [
                WiFiStatus(device: "en0", networkName: "CIC", rawOutput: "Current Wi-Fi Network: CIC"),
                WiFiStatus(
                    device: "en0",
                    networkName: nil,
                    rawOutput: "You are not associated with an AirPort network."
                ),
                WiFiStatus(device: "en0", networkName: "iPhone", rawOutput: "Current Wi-Fi Network: iPhone")
            ],
            codexRunning: true
        )
        let appState = makeAppState(
            gateway: gateway,
            settings: TravelModeSettings(
                hotspotSSID: "iPhone",
                hotspotPassword: "secret",
                wifiDevice: "en0"
            )
        )

        await appState.start()
        await appState.syncOnce()
        await appState.stop()

        XCTAssertEqual(gateway.joinAttempts, [JoinAttempt(device: "en0", ssid: "iPhone", password: "secret")])
    }

    func testClosedLidForcesFallbackEvenWhileWiFiIsConnected() async {
        let gateway = StubGateway(
            statuses: [
                WiFiStatus(device: "en0", networkName: "CIC", rawOutput: "Current Wi-Fi Network: CIC"),
                WiFiStatus(device: "en0", networkName: "CIC", rawOutput: "Current Wi-Fi Network: CIC"),
                WiFiStatus(device: "en0", networkName: "iPhone", rawOutput: "Current Wi-Fi Network: iPhone")
            ],
            codexRunning: true,
            lidClosed: true
        )
        let appState = makeAppState(
            gateway: gateway,
            settings: TravelModeSettings(
                hotspotSSID: "iPhone",
                hotspotPassword: "secret",
                wifiDevice: "en0"
            )
        )

        await appState.start()
        await appState.syncOnce()

        XCTAssertEqual(gateway.joinAttempts, [JoinAttempt(device: "en0", ssid: "iPhone", password: "secret")])
        XCTAssertEqual(appState.latestStatus, "Connected to hotspot 'iPhone'")
    }

    func testFallbackJoinsOnlyAfterConnectedNetworkIsLost() async {
        let gateway = StubGateway(
            statuses: [
                WiFiStatus(device: "en0", networkName: "CIC", rawOutput: "Current Wi-Fi Network: CIC"),
                WiFiStatus(
                    device: "en0",
                    networkName: nil,
                    rawOutput: "You are not associated with an AirPort network."
                ),
                WiFiStatus(device: "en0", networkName: "iPhone", rawOutput: "Current Wi-Fi Network: iPhone")
            ],
            codexRunning: true
        )
        let appState = makeAppState(
            gateway: gateway,
            settings: TravelModeSettings(
                hotspotSSID: "iPhone",
                hotspotPassword: "secret",
                wifiDevice: "en0"
            )
        )

        await appState.start()
        await appState.syncOnce()

        XCTAssertEqual(gateway.joinAttempts, [JoinAttempt(device: "en0", ssid: "iPhone", password: "secret")])
    }

    func testConnectedNetworkStatusSaysFallbackRunsIfItDisconnects() async {
        let gateway = StubGateway(
            statuses: [
                WiFiStatus(device: "en0", networkName: "CIC", rawOutput: "Current Wi-Fi Network: CIC")
            ]
        )
        let appState = makeAppState(
            gateway: gateway,
            settings: TravelModeSettings(
                hotspotSSID: "iPhone",
                hotspotPassword: "secret",
                wifiDevice: "en0"
            )
        )

        await appState.syncOnce()

        XCTAssertEqual(
            appState.latestStatus,
            "Watching Wi-Fi 'CIC'; fallback will run if it disconnects."
        )
        XCTAssertEqual(gateway.joinAttempts, [])
    }
}

@MainActor
private func XCTAssertThrowsErrorAsync(
    _ operation: () async throws -> Void,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        try await operation()
        XCTFail("Expected operation to throw", file: file, line: line)
    } catch {}
}

private func wifiSnapshot(
    interfaceName: String? = nil,
    remembered: [String] = [],
    visible: [String] = [],
    visibleScanStatus: WiFiVisibleScanStatus = .completed
) -> WiFiDiscoverySnapshot {
    WiFiDiscoverySnapshot(
        interfaceName: interfaceName,
        rememberedNetworks: remembered.compactMap(WiFiSSID.init(displayName:)),
        visibleNetworks: visible.compactMap(WiFiSSID.init(displayName:)),
        visibleScanStatus: visibleScanStatus
    )
}

private actor StubWiFiDiscoveryProvider: WiFiDiscoveryProviding {
    private let snapshots: [WiFiDiscoverySnapshot]
    private let suspendedRequestIndexes: Set<Int>
    private var requestCount = 0
    private var suspendedRequests: [Int: CheckedContinuation<Void, Never>] = [:]

    init(
        snapshots: [WiFiDiscoverySnapshot] = [wifiSnapshot()],
        suspendedRequestIndexes: Set<Int> = []
    ) {
        self.snapshots = snapshots.isEmpty ? [wifiSnapshot()] : snapshots
        self.suspendedRequestIndexes = suspendedRequestIndexes
    }

    func snapshot() async -> WiFiDiscoverySnapshot {
        let requestIndex = requestCount
        requestCount += 1
        if suspendedRequestIndexes.contains(requestIndex) {
            await withCheckedContinuation { continuation in
                suspendedRequests[requestIndex] = continuation
            }
        }
        return snapshots[min(requestIndex, snapshots.count - 1)]
    }

    func requestLocationAuthorization() async {}

    func waitForSnapshotRequestCount(_ expectedCount: Int) async {
        while requestCount < expectedCount {
            await Task.yield()
        }
    }

    func resumeSnapshotRequest(at index: Int) {
        suspendedRequests.removeValue(forKey: index)?.resume()
    }

    func snapshotRequestCount() -> Int {
        requestCount
    }
}

private final class InMemorySettingsStore: TravelSettingsStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var committedSettings: TravelModeSettings
    private var committedPassword: String?
    private var committedRevision: HotspotConfigurationRevision?
    private var recordedSavedSettings: TravelModeSettings?
    private var recordedPasswordReadCount = 0
    private var recordedSaveCount = 0
    private var nextSaveErrorAfterCommit: HotspotConfigurationError?

    init(settings: TravelModeSettings) {
        self.committedSettings = TravelModeSettings(
            hotspotSSID: settings.hotspotSSID,
            wifiDevice: settings.wifiDevice
        )
        self.committedPassword = settings.hotspotPassword.isEmpty
            ? nil
            : settings.hotspotPassword
        self.committedRevision = Self.makeRevision(
            settings: settings,
            credentialReference: settings.hotspotSSID.isEmpty
                ? nil
                : "in-memory-credential-0"
        )
    }

    var savedSettings: TravelModeSettings? {
        locked { recordedSavedSettings }
    }

    var passwordReadCount: Int {
        locked { recordedPasswordReadCount }
    }

    var saveCount: Int {
        locked { recordedSaveCount }
    }

    func load() -> TravelModeSettings {
        locked { committedSettings }
    }

    func hasSavedHotspotPassword() -> Bool {
        locked { committedRevision != nil && committedPassword?.isEmpty == false }
    }

    func loadHotspotPassword() throws -> String {
        try locked {
            recordedPasswordReadCount += 1
            guard committedRevision != nil, let committedPassword else {
                throw HotspotConfigurationError.noActiveConfiguration
            }
            return committedPassword
        }
    }

    func loadHotspotPassword(credentialReference: String) throws -> String {
        try locked {
            recordedPasswordReadCount += 1
            guard committedRevision?.credentialReference == credentialReference,
                  let committedPassword else {
                throw HotspotConfigurationError.credentialMissing(credentialReference)
            }
            return committedPassword
        }
    }

    func save(_ settings: TravelModeSettings) throws {
        try locked {
            recordedSaveCount += 1
            let password: String
            let credentialReference: String
            if settings.hotspotPassword.isEmpty {
                guard settings.hotspotSSID == committedSettings.hotspotSSID,
                      let existingPassword = committedPassword,
                      let existingReference = committedRevision?.credentialReference else {
                    throw HotspotConfigurationError.passwordRequired
                }
                password = existingPassword
                credentialReference = existingReference
            } else {
                password = settings.hotspotPassword
                credentialReference = "in-memory-credential-\(recordedSaveCount)"
            }
            let revision = try HotspotConfigurationRevision(
                revisionID: "in-memory-revision-\(recordedSaveCount)",
                ssid: settings.hotspotSSID,
                wifiDevice: settings.wifiDevice.isEmpty ? nil : settings.wifiDevice,
                credentialReference: credentialReference
            )
            recordedSavedSettings = settings
            committedPassword = password
            committedRevision = revision
            committedSettings = TravelModeSettings(
                hotspotSSID: revision.ssid,
                wifiDevice: revision.wifiDevice ?? ""
            )
            if let error = nextSaveErrorAfterCommit {
                nextSaveErrorAfterCommit = nil
                throw error
            }
        }
    }

    func failNextSaveAfterCommit(with error: HotspotConfigurationError) {
        locked { nextSaveErrorAfterCommit = error }
    }

    func replaceCommittedConfiguration(_ settings: TravelModeSettings) throws {
        try locked {
            recordedSaveCount += 1
            let reference = "external-credential-\(recordedSaveCount)"
            committedRevision = try HotspotConfigurationRevision(
                revisionID: "external-revision-\(recordedSaveCount)",
                ssid: settings.hotspotSSID,
                wifiDevice: settings.wifiDevice.isEmpty ? nil : settings.wifiDevice,
                credentialReference: reference
            )
            committedPassword = settings.hotspotPassword
            committedSettings = TravelModeSettings(
                hotspotSSID: settings.hotspotSSID,
                wifiDevice: settings.wifiDevice
            )
        }
    }

    func recoverHotspotConfiguration() throws {}

    func activeHotspotConfiguration() throws -> HotspotConfigurationRevision? {
        locked { committedRevision }
    }

    private static func makeRevision(
        settings: TravelModeSettings,
        credentialReference: String?
    ) -> HotspotConfigurationRevision? {
        guard let credentialReference else { return nil }
        return try? HotspotConfigurationRevision(
            revisionID: "in-memory-revision-0",
            ssid: settings.hotspotSSID,
            wifiDevice: settings.wifiDevice.isEmpty ? nil : settings.wifiDevice,
            credentialReference: credentialReference
        )
    }

    private func locked<Value>(_ operation: () throws -> Value) rethrows -> Value {
        lock.lock()
        defer { lock.unlock() }
        return try operation()
    }
}

private struct JoinAttempt: Equatable, Sendable {
    var device: String
    var ssid: String
    var password: String?
}

private final class PasswordProviderSpy: @unchecked Sendable {
    private let storedPassword: String
    var readCount = 0

    init(password: String) {
        self.storedPassword = password
    }

    func password() -> String {
        readCount += 1
        return storedPassword
    }
}

private final class StubSessionManager: TravelSessionManaging, @unchecked Sendable {
    var currentLifecycle: TravelSessionLifecycle
    var startResult: TravelSessionTransitionResult
    var stopResult: TravelSessionTransitionResult
    var quitResult: TravelSessionTransitionResult
    var recoverResult: TravelSessionTransitionResult
    var startedConfigurations: [TravelSessionConfiguration] = []
    var stopCount = 0
    var quitCount = 0
    var recoverCount = 0
    private let protectionStream: AsyncStream<SleepOverrideLeaseProtectionEvent>
    private let protectionContinuation: AsyncStream<SleepOverrideLeaseProtectionEvent>.Continuation
    private let protectionEventDuringStart: SleepOverrideLeaseProtectionEvent?
    private let suspendLifecycleReads: Bool
    private var lifecycleContinuations: [CheckedContinuation<TravelSessionLifecycle, Never>] = []
    private(set) var lifecycleReadCount = 0
    private let suspendQuitRequests: Bool
    private var quitContinuations: [CheckedContinuation<Void, Never>] = []

    init(
        lifecycle: TravelSessionLifecycle = .off,
        startResult: TravelSessionTransitionResult = TravelSessionTransitionResult(
            lifecycle: .active,
            canTerminate: false
        ),
        stopResult: TravelSessionTransitionResult = TravelSessionTransitionResult(lifecycle: .off),
        quitResult: TravelSessionTransitionResult = TravelSessionTransitionResult(lifecycle: .off),
        recoverResult: TravelSessionTransitionResult = TravelSessionTransitionResult(lifecycle: .off),
        protectionEventDuringStart: SleepOverrideLeaseProtectionEvent? = nil,
        suspendLifecycleReads: Bool = false,
        suspendQuitRequests: Bool = false
    ) {
        let protectionEvents = AsyncStream<SleepOverrideLeaseProtectionEvent>.makeStream()
        self.protectionStream = protectionEvents.stream
        self.protectionContinuation = protectionEvents.continuation
        self.currentLifecycle = lifecycle
        self.startResult = startResult
        self.stopResult = stopResult
        self.quitResult = quitResult
        self.recoverResult = recoverResult
        self.protectionEventDuringStart = protectionEventDuringStart
        self.suspendLifecycleReads = suspendLifecycleReads
        self.suspendQuitRequests = suspendQuitRequests
    }

    func start(configuration: TravelSessionConfiguration) async -> TravelSessionTransitionResult {
        startedConfigurations.append(configuration)
        if let protectionEventDuringStart {
            protectionContinuation.yield(protectionEventDuringStart)
            try? await Task.sleep(for: .milliseconds(25))
        }
        currentLifecycle = startResult.lifecycle
        return startResult
    }

    func stop() async -> TravelSessionTransitionResult {
        stopCount += 1
        currentLifecycle = stopResult.lifecycle
        return stopResult
    }

    func requestQuit() async -> TravelSessionTransitionResult {
        quitCount += 1
        if suspendQuitRequests {
            await withCheckedContinuation { continuation in
                quitContinuations.append(continuation)
            }
        }
        currentLifecycle = quitResult.lifecycle
        return quitResult
    }

    func recover() async -> TravelSessionTransitionResult {
        recoverCount += 1
        currentLifecycle = recoverResult.lifecycle
        return recoverResult
    }

    func lifecycle() async -> TravelSessionLifecycle {
        lifecycleReadCount += 1
        if suspendLifecycleReads {
            return await withCheckedContinuation { continuation in
                lifecycleContinuations.append(continuation)
            }
        }
        return currentLifecycle
    }

    func waitForLifecycleReadCount(_ expectedCount: Int) async {
        while lifecycleReadCount < expectedCount {
            await Task.yield()
        }
    }

    func resumeLifecycleReads() {
        let continuations = lifecycleContinuations
        lifecycleContinuations.removeAll()
        for continuation in continuations {
            continuation.resume(returning: currentLifecycle)
        }
    }

    func waitForQuitCount(_ expectedCount: Int) async {
        while quitCount < expectedCount {
            await Task.yield()
        }
    }

    func resumeQuitRequests() {
        let continuations = quitContinuations
        quitContinuations.removeAll()
        for continuation in continuations {
            continuation.resume()
        }
    }

    func protectionEvents() async -> AsyncStream<SleepOverrideLeaseProtectionEvent> {
        protectionStream
    }

    func sendProtectionEvent(_ event: SleepOverrideLeaseProtectionEvent) {
        protectionContinuation.yield(event)
    }

    func setWiFiPower(device: String, enabled: Bool) async -> CommandResult {
        CommandResult(exitCode: 0)
    }

    func associate(device: String, ssid: String, password: String?) async -> CommandResult {
        CommandResult(exitCode: 0)
    }
}

private final class StubGateway: TravelCommandGateway, @unchecked Sendable {
    private var statuses: [WiFiStatus]
    private let discoveredDevice: String?
    private let knownNetworks: [String]
    private let scannedNetworks: [String]
    private let codexRunning: Bool
    private let lidClosed: Bool?
    private let wifiPower: Bool?
    var joinAttempts: [JoinAttempt] = []
    var wifiPowerChanges: [Bool] = []
    var didOpenWiFiSettings = false
    var commandsStarted = false
    var keepAwakeStopCount = 0

    init(
        statuses: [WiFiStatus] = [],
        discoveredDevice: String? = nil,
        knownNetworks: [String] = [],
        scannedNetworks: [String] = [],
        codexRunning: Bool = false,
        lidClosed: Bool? = false,
        wifiPower: Bool? = nil
    ) {
        self.statuses = statuses
        self.discoveredDevice = discoveredDevice
        self.knownNetworks = knownNetworks
        self.scannedNetworks = scannedNetworks
        self.codexRunning = codexRunning
        self.lidClosed = lidClosed
        self.wifiPower = wifiPower
    }

    func discoverWiFiDevice() async -> String? {
        discoveredDevice
    }

    func knownWiFiNetworks(device: String) async -> [String] {
        knownNetworks
    }

    func scanWiFiNetworks(device: String) async -> [String] {
        scannedNetworks
    }

    func startKeepAwake() async throws {
        commandsStarted = true
    }

    func stopKeepAwake() async {
        keepAwakeStopCount += 1
    }

    func currentLidClosed() async -> Bool? {
        lidClosed
    }

    func currentWiFiStatus(device: String) async -> WiFiStatus {
        if statuses.isEmpty {
            return WiFiStatus(device: device, networkName: nil, rawOutput: "")
        }
        return statuses.removeFirst()
    }

    func currentWiFiPower(device: String) async -> Bool? {
        wifiPower
    }

    func setWiFiPower(device: String, enabled: Bool) async -> CommandResult {
        wifiPowerChanges.append(enabled)
        return CommandResult(exitCode: 0)
    }

    func joinWiFi(device: String, ssid: String, password: String?) async -> CommandResult {
        joinAttempts.append(JoinAttempt(device: device, ssid: ssid, password: password))
        return CommandResult(exitCode: 0)
    }

    func openWiFiSettings() async {
        didOpenWiFiSettings = true
    }

    func isCodexRunning() async -> Bool {
        codexRunning
    }
}
