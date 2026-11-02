import AppKit
import ApplicationServices
import CodexTravelModeCore
import Foundation
import SwiftUI

private struct ProofOperation: Codable, Sendable {
    let sequence: Int
    let name: String
    let value: String?
}

private struct ProofRevision: Codable, Sendable {
    let revisionID: String
    let ssid: String
    let wifiDevice: String?
    let credentialReference: String

    init(_ revision: HotspotConfigurationRevision) {
        revisionID = revision.revisionID
        ssid = revision.ssid
        wifiDevice = revision.wifiDevice
        credentialReference = revision.credentialReference
    }
}

private struct ProofScreenshot: Codable, Sendable {
    let path: String
    let renderedViewIdentifier: String
    let width: Int
    let height: Int
    let sourcePID: Int32
}

private struct ProofOption: Codable, Sendable {
    let displayName: String
    let utf8Hex: String

    init(_ ssid: WiFiSSID) {
        displayName = ssid.displayName
        utf8Hex = ssid.utf8Bytes.map { String(format: "%02x", $0) }.joined()
    }
}

private struct RenderedFrame: Codable, Sendable {
    let x: Int
    let y: Int
    let width: Int
    let height: Int

    init(_ frame: NSRect) {
        x = Int(frame.origin.x.rounded())
        y = Int(frame.origin.y.rounded())
        width = Int(frame.width.rounded())
        height = Int(frame.height.rounded())
    }
}

private struct RenderedElementSnapshot: Codable, Sendable {
    let identifier: String?
    let role: String
    let label: String?
    let value: String?
    let enabled: Bool
    let protectedContent: Bool
    let frame: RenderedFrame
    let sourceClass: String
}

private struct UIProofObservation: Codable, Sendable {
    let name: String
    let variant: String?
    let launchID: String
    let pid: Int32
    let discoveryState: String
    let options: [ProofOption]
    let draftSSID: String
    let committedSSID: String?
    let wifiDevice: String
    let controlEnabledStates: [String: Bool]
    let renderedElements: [RenderedElementSnapshot]
    let renderedMessages: [String]
    let controlStateSource: String
    let startEligibility: Bool
    let configurationLocked: Bool
    let lifecycle: String
    let secretReadCounts: [String: Int]
    let beforeRevision: ProofRevision?
    let afterRevision: ProofRevision?
    let credentialInventory: [String]
    let operations: [ProofOperation]
    let screenshot: ProofScreenshot?
}

private final class ProofBlockingGate: @unchecked Sendable {
    private let condition = NSCondition()
    private var entered = false
    private var released = false

    func enterAndWait() {
        condition.lock()
        entered = true
        condition.broadcast()
        while !released {
            condition.wait()
        }
        condition.unlock()
    }

    func waitUntilEntered() async -> Bool {
        for _ in 0..<400 {
            if hasEntered { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return false
    }

    private var hasEntered: Bool {
        condition.lock()
        defer { condition.unlock() }
        return entered
    }

    func release() {
        condition.lock()
        released = true
        condition.broadcast()
        condition.unlock()
    }
}

private actor ProofAsyncGate {
    private var entered = false
    private var released = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func enterAndWait() async {
        entered = true
        guard !released else { return }
        await withCheckedContinuation { continuation in
            if released {
                continuation.resume()
            } else {
                waiters.append(continuation)
            }
        }
    }

    func waitUntilEntered() async -> Bool {
        for _ in 0..<400 {
            if entered { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return false
    }

    func release() {
        released = true
        let pending = waiters
        waiters.removeAll()
        for waiter in pending {
            waiter.resume()
        }
    }
}

private struct Arguments {
    let scenario: String
    let variant: String?
    let launchID: String
    let observationURL: URL
    let screenshotURL: URL?

    static func parse(_ arguments: [String]) throws -> Arguments {
        func value(after flag: String) -> String? {
            guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else {
                return nil
            }
            return arguments[index + 1]
        }

        guard let scenario = value(after: "--scenario"),
              let launchID = value(after: "--launch-id"),
              let observationPath = value(after: "--observation") else {
            throw ProofAppError.invalidArguments
        }
        return Arguments(
            scenario: scenario,
            variant: value(after: "--variant"),
            launchID: launchID,
            observationURL: URL(fileURLWithPath: observationPath),
            screenshotURL: value(after: "--screenshot").map(URL.init(fileURLWithPath:))
        )
    }
}

private enum ProofAppError: LocalizedError {
    case invalidArguments
    case unknownScenario(String)
    case invalidVariant(String)
    case renderingFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidArguments:
            "Required arguments: --scenario NAME --launch-id ID --observation PATH"
        case .unknownScenario(let scenario):
            "Unknown UI proof scenario: \(scenario)"
        case .invalidVariant(let variant):
            "Unknown UI proof variant: \(variant)"
        case .renderingFailed(let detail):
            "Native SwiftUI rendering failed: \(detail)"
        }
    }
}

private final class ProofSettingsStore: TravelSettingsStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var settings: TravelModeSettings
    private var password: String?
    private var revision: HotspotConfigurationRevision?
    private var passwordReads = 0
    private var saves = 0
    private let saveGate: ProofBlockingGate?

    init(
        settings: TravelModeSettings = TravelModeSettings(),
        password: String? = nil,
        saveGate: ProofBlockingGate? = nil
    ) {
        self.settings = TravelModeSettings(
            hotspotSSID: settings.hotspotSSID,
            wifiDevice: settings.wifiDevice
        )
        self.password = password
        self.saveGate = saveGate
        if let password, !password.isEmpty, !settings.hotspotSSID.isEmpty {
            revision = try? HotspotConfigurationRevision(
                revisionID: "ui-proof-revision",
                ssid: settings.hotspotSSID,
                wifiDevice: settings.wifiDevice.isEmpty ? nil : settings.wifiDevice,
                credentialReference: "ui-proof-credential"
            )
        }
    }

    func load() -> TravelModeSettings {
        locked { settings }
    }

    func hasSavedHotspotPassword() -> Bool {
        locked { revision != nil && password?.isEmpty == false }
    }

    func loadHotspotPassword() throws -> String {
        try locked {
            passwordReads += 1
            guard revision != nil, let password, !password.isEmpty else {
                throw HotspotConfigurationError.noActiveConfiguration
            }
            return password
        }
    }

    func loadHotspotPassword(credentialReference: String) throws -> String {
        try locked {
            passwordReads += 1
            guard revision?.credentialReference == credentialReference,
                  let password,
                  !password.isEmpty else {
                throw HotspotConfigurationError.credentialMissing(credentialReference)
            }
            return password
        }
    }

    func save(_ settings: TravelModeSettings) throws {
        locked { saves += 1 }
        saveGate?.enterAndWait()
        try locked {
            let savedPassword: String
            let reference: String
            if settings.hotspotPassword.isEmpty {
                guard settings.hotspotSSID.hasExactUTF8Representation(
                    as: self.settings.hotspotSSID
                ),
                      let password,
                      let revision else {
                    throw HotspotConfigurationError.passwordRequired
                }
                savedPassword = password
                reference = revision.credentialReference
            } else {
                savedPassword = settings.hotspotPassword
                reference = "ui-proof-credential-saved"
            }
            let candidate = try HotspotConfigurationRevision(
                revisionID: "ui-proof-revision-saved",
                ssid: settings.hotspotSSID,
                wifiDevice: settings.wifiDevice.isEmpty ? nil : settings.wifiDevice,
                credentialReference: reference
            )
            self.settings = TravelModeSettings(
                hotspotSSID: candidate.ssid,
                wifiDevice: candidate.wifiDevice ?? ""
            )
            password = savedPassword
            revision = candidate
        }
    }

    func recoverHotspotConfiguration() throws {}

    func activeHotspotConfiguration() throws -> HotspotConfigurationRevision? {
        locked { revision }
    }

    var passwordReadCount: Int {
        locked { passwordReads }
    }

    var saveCount: Int {
        locked { saves }
    }

    private func locked<Value>(_ operation: () throws -> Value) rethrows -> Value {
        lock.lock()
        defer { lock.unlock() }
        return try operation()
    }
}

private actor ProofWiFiDiscovery: WiFiDiscoveryProviding {
    struct Response: Sendable {
        let snapshot: WiFiDiscoverySnapshot
        let delay: Duration
        let blocksUntilProcessExit: Bool
    }

    private var responses: [Response]
    private var requestIndex = 0

    init(responses: [Response]) {
        self.responses = responses
    }

    func snapshot() async -> WiFiDiscoverySnapshot {
        let index = min(requestIndex, responses.count - 1)
        requestIndex += 1
        let response = responses[index]
        if response.blocksUntilProcessExit {
            await withUnsafeContinuation { (_: UnsafeContinuation<Void, Never>) in }
        }
        try? await Task.sleep(for: response.delay)
        return response.snapshot
    }

    func requestLocationAuthorization() async {}

    func requestCount() -> Int {
        requestIndex
    }
}

private final class ProofGateway: TravelCommandGateway, @unchecked Sendable {
    private let lock = NSLock()
    private let stopGate: ProofAsyncGate?
    private var keepAwakeStarts = 0
    private var joins = 0

    init(stopGate: ProofAsyncGate? = nil) {
        self.stopGate = stopGate
    }

    func startKeepAwake() async throws {
        locked { keepAwakeStarts += 1 }
    }
    func stopKeepAwake() async {
        await stopGate?.enterAndWait()
    }
    func currentLidClosed() async -> Bool? { false }
    func discoverWiFiDevice() async -> String? { "en0" }
    func currentWiFiStatus(device: String) async -> WiFiStatus {
        WiFiStatus(device: device, networkName: "Office", rawOutput: "")
    }
    func currentWiFiPower(device: String) async -> Bool? { true }
    func setWiFiPower(device: String, enabled: Bool) async -> CommandResult {
        CommandResult(exitCode: 0)
    }
    func joinWiFi(device: String, ssid: String, password: String?) async -> CommandResult {
        locked { joins += 1 }
        return CommandResult(exitCode: 0)
    }
    func openWiFiSettings() async {}
    func isCodexRunning() async -> Bool { true }

    var keepAwakeStartCount: Int {
        locked { keepAwakeStarts }
    }

    var joinCount: Int {
        locked { joins }
    }

    private func locked<Value>(_ operation: () -> Value) -> Value {
        lock.lock()
        defer { lock.unlock() }
        return operation()
    }
}

private final class ProofSessionManager: TravelSessionManaging, @unchecked Sendable {
    private let lock = NSLock()
    private var currentLifecycle: TravelSessionLifecycle
    private var starts = 0
    private var quits = 0

    init(lifecycle: TravelSessionLifecycle = .off) {
        currentLifecycle = lifecycle
    }

    func start(configuration: TravelSessionConfiguration) async -> TravelSessionTransitionResult {
        locked {
            starts += 1
            currentLifecycle = .active
        }
        return TravelSessionTransitionResult(lifecycle: .active, canTerminate: false)
    }

    func stop() async -> TravelSessionTransitionResult {
        locked { currentLifecycle = .off }
        return TravelSessionTransitionResult(lifecycle: .off)
    }

    func requestQuit() async -> TravelSessionTransitionResult {
        locked {
            quits += 1
            currentLifecycle = .off
        }
        return TravelSessionTransitionResult(lifecycle: .off)
    }

    func recover() async -> TravelSessionTransitionResult {
        TravelSessionTransitionResult(lifecycle: locked { currentLifecycle })
    }

    func lifecycle() async -> TravelSessionLifecycle {
        locked { currentLifecycle }
    }

    func setWiFiPower(device: String, enabled: Bool) async -> CommandResult {
        CommandResult(exitCode: 0)
    }

    func associate(device: String, ssid: String, password: String?) async -> CommandResult {
        CommandResult(exitCode: 0)
    }

    var startCount: Int {
        locked { starts }
    }

    var quitCount: Int {
        locked { quits }
    }

    private func locked<Value>(_ operation: () -> Value) -> Value {
        lock.lock()
        defer { lock.unlock() }
        return operation()
    }
}

private struct ScenarioContext {
    let state: TravelModeAppState
    let store: ProofSettingsStore
    let gateway: ProofGateway
    let discovery: ProofWiFiDiscovery
    let sessionManager: ProofSessionManager
    let beforeRevision: ProofRevision?
    let secretReadsAfterInitialization: Int
    var operations: [ProofOperation]
}

@MainActor
private final class ProofAppDelegate: NSObject, NSApplicationDelegate {
    private let arguments: Arguments
    private var window: NSWindow?

    init(arguments: Arguments) {
        self.arguments = arguments
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        Task { @MainActor in
            do {
                try await run()
                NSApplication.shared.terminate(nil)
            } catch {
                FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8))
                Darwin.exit(1)
            }
        }
    }

    private func run() async throws {
        let context = try await prepareScenario()
        let secretReadsAfterActions = context.store.passwordReadCount
        let view = MenuBarContentView(
            appState: context.state,
            onQuit: {},
            onRetryCleanupAndQuit: {}
        )
            .background(Color(nsColor: .windowBackgroundColor))
        let hostingController = NSHostingController(rootView: view)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 340, height: 560),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Codex Travel Mode Proof — \(arguments.scenario)"
        window.contentViewController = hostingController
        window.center()
        window.makeKeyAndOrderFront(nil)
        self.window = window
        NSApplication.shared.activate(ignoringOtherApps: true)
        try? await Task.sleep(for: .milliseconds(180))
        hostingController.view.layoutSubtreeIfNeeded()
        try primeSelfAccessibilityHierarchy()

        if ProcessInfo.processInfo.environment["HOTSPOT_PROOF_DUMP_AX_ROOT"] == "1" {
            let children = hostingController.view.accessibilityChildren() ?? []
            let navigation = hostingController.view.accessibilityChildrenInNavigationOrder() ?? []
            let dump = [
                "children=\(children.map { String(describing: type(of: $0)) })",
                "navigation=\(navigation.map { String(describing: type(of: $0)) })",
                "root=\(String(describing: type(of: hostingController.view)))",
                "subviews=\(hostingController.view.subviews.map { String(describing: type(of: $0)) })"
            ].joined(separator: "\n")
            FileHandle.standardError.write(Data("\(dump)\n".utf8))
        }

        let renderedElements = renderedSnapshot(from: hostingController.view)
        let controlStates = try renderedControlStates(from: renderedElements)
        let renderedMessages = renderedElements.compactMap { element -> String? in
            guard element.role == NSAccessibility.Role.staticText.rawValue else { return nil }
            return element.value ?? element.label
        }

        let screenshot = try arguments.screenshotURL.map {
            try capture(hostingController.view, to: $0, identifier: "menu-bar-content-view")
        }
        let after = try context.store.activeHotspotConfiguration().map(ProofRevision.init)
        let observation = UIProofObservation(
            name: arguments.scenario,
            variant: arguments.variant,
            launchID: arguments.launchID,
            pid: ProcessInfo.processInfo.processIdentifier,
            discoveryState: discoveryState(context.state.discoveryState),
            options: context.state.availableHotspots.map(ProofOption.init),
            draftSSID: context.state.settings.hotspotSSID,
            committedSSID: context.state.committedHotspotSSID,
            wifiDevice: context.state.settings.wifiDevice,
            controlEnabledStates: controlStates,
            renderedElements: renderedElements,
            renderedMessages: renderedMessages,
            controlStateSource: "in_process_accessibility_hierarchy",
            startEligibility: context.state.canStart,
            configurationLocked: context.state.isConfigurationLocked,
            lifecycle: context.state.sessionLifecycle.rawValue,
            secretReadCounts: [
                "after_initialization": context.secretReadsAfterInitialization,
                "after_scenario_actions": secretReadsAfterActions,
                "after_render": context.store.passwordReadCount
            ],
            beforeRevision: context.beforeRevision,
            afterRevision: after,
            credentialInventory: after.map { [$0.credentialReference] } ?? [],
            operations: context.operations,
            screenshot: screenshot
        )
        try write(observation, to: arguments.observationURL)
    }

    private func prepareScenario() async throws -> ScenarioContext {
        switch arguments.scenario {
        case "fresh-loading":
            return await freshLoadingScenario()

        case "exact-discovery-order":
            return await exactDiscoveryOrderScenario()

        case "discovery-status-matrix":
            return try await discoveryStatusScenario()

        case "stale-refresh":
            return await staleRefreshScenario()

        case "manual-selection", "manual-save-after-denial":
            return await manualSelectionScenario()

        case "saved-selection-after-failure":
            return await savedSelectionAfterFailureScenario()

        case "unsaved-draft-start":
            return await unsavedDraftScenario()

        case "lifecycle-lock-matrix":
            return try await lifecycleLockScenario()

        case "double-save-race":
            return try await doubleSaveRaceScenario()

        case "save-start-race":
            return try await saveStartRaceScenario()

        case "quit-save-race":
            return try await quitSaveRaceScenario()

        default:
            throw ProofAppError.unknownScenario(arguments.scenario)
        }
    }

    private func freshLoadingScenario() async -> ScenarioContext {
        let context = makeContext(
            snapshotResponses: [response(snapshot(status: .completed), blocksUntilProcessExit: true)]
        )
        Task { await context.state.refreshConfiguration() }
        try? await Task.sleep(for: .milliseconds(80))
        return context
            .appending(operation(2, "refresh_dispatched"))
            .appending(operation(3, "loading_observed"))
    }

    private func exactDiscoveryOrderScenario() async -> ScenarioContext {
        let exactSnapshot = WiFiDiscoverySnapshot(
            interfaceName: "en0",
            rememberedNetworks: ssids(["Office", "Caf\u{00E9}", "Example iPhone"]),
            visibleNetworks: ssids(["office", "Office", "Airport", "Cafe\u{0301}"]),
            visibleScanStatus: .completed
        )
        let context = makeContext(snapshotResponses: [response(exactSnapshot)])
        await context.state.refreshConfiguration()
        return context.appending(operation(2, "refresh_completed", "completed"))
    }

    private func discoveryStatusScenario() async throws -> ScenarioContext {
        let status = try statusVariant(arguments.variant)
        let partialRemembered = status == .completed ? [] : ssids(["Office"])
        let context = makeContext(
            snapshotResponses: [
                response(
                    WiFiDiscoverySnapshot(
                        interfaceName: status == .noWiFiInterface ? nil : "en0",
                        rememberedNetworks: partialRemembered,
                        visibleNetworks: [],
                        visibleScanStatus: status
                    )
                )
            ]
        )
        await context.state.refreshConfiguration(requestAuthorization: true)
        return context.appending(operation(2, "refresh_completed", status.rawValue))
    }

    private func staleRefreshScenario() async -> ScenarioContext {
        let stale = WiFiDiscoverySnapshot(
            interfaceName: "en0",
            rememberedNetworks: ssids(["Stale Network"]),
            visibleNetworks: [],
            visibleScanStatus: .completed
        )
        let latest = WiFiDiscoverySnapshot(
            interfaceName: "en0",
            rememberedNetworks: ssids(["Latest Network"]),
            visibleNetworks: [],
            visibleScanStatus: .completed
        )
        let context = makeContext(
            snapshotResponses: [
                response(stale, delay: .milliseconds(300)),
                response(latest, delay: .milliseconds(20))
            ]
        )
        let first = Task { await context.state.refreshConfiguration() }
        try? await Task.sleep(for: .milliseconds(40))
        context.state.settings.hotspotSSID = "Manual Draft"
        let second = Task { await context.state.refreshConfiguration() }
        await second.value
        await first.value
        return context
            .appending(operation(2, "older_refresh_dispatched"))
            .appending(operation(3, "manual_edit", "Manual Draft"))
            .appending(operation(4, "newer_refresh_completed"))
            .appending(operation(5, "older_refresh_completed"))
    }

    private func manualSelectionScenario() async -> ScenarioContext {
        let context = makeContext(
            snapshotResponses: [response(snapshot(status: .denied))]
        )
        await context.state.refreshConfiguration(requestAuthorization: true)
        context.state.settings.hotspotSSID = "Example iPhone"
        context.state.settings.hotspotPassword =
            ProcessInfo.processInfo.environment["HOTSPOT_PROOF_PASSWORD_SENTINEL"] ?? ""
        try? await context.state.saveSettings()
        await context.state.refreshStatus()
        return context
            .appending(operation(2, "refresh_completed", "denied"))
            .appending(operation(3, "manual_ssid_entered", "Example iPhone"))
            .appending(operation(4, "password_entered_securely"))
            .appending(operation(5, "save_requested"))
            .appending(operation(6, "store_save_count", "\(context.store.saveCount)"))
            .appending(operation(7, "status_refreshed"))
    }

    private func savedSelectionAfterFailureScenario() async -> ScenarioContext {
        let context = makeCommittedContext(status: .providerFailed)
        await context.state.refreshStatus()
        await context.state.refreshConfiguration()
        return context
            .appending(operation(2, "status_refreshed"))
            .appending(operation(3, "refresh_completed", "provider_failed"))
    }

    private func unsavedDraftScenario() async -> ScenarioContext {
        let context = makeCommittedContext(status: .completed)
        await context.state.refreshStatus()
        context.state.settings.hotspotSSID = "Draft iPhone"
        await context.state.start()
        return context
            .appending(operation(2, "status_refreshed"))
            .appending(operation(3, "draft_ssid_changed", "Draft iPhone"))
            .appending(operation(4, "start_requested"))
            .appending(operation(5, "session_start_count", "\(context.sessionManager.startCount)"))
            .appending(operation(6, "keep_awake_start_count", "\(context.gateway.keepAwakeStartCount)"))
            .appending(operation(7, "association_count", "\(context.gateway.joinCount)"))
    }

    private func lifecycleLockScenario() async throws -> ScenarioContext {
        let lifecycle = try lifecycleVariant(arguments.variant)
        let context = makeCommittedContext(status: .completed, lifecycle: lifecycle)
        await context.state.recoverPreviousSessionIfNeeded()
        await context.state.refreshConfiguration()
        let refreshCount = await context.discovery.requestCount()
        do {
            try await context.state.saveSettings()
        } catch {
            // The typed action error is independently asserted from the raw counts below.
        }
        await context.state.start()
        return context
            .appending(operation(2, "lifecycle_loaded", lifecycle.rawValue))
            .appending(operation(3, "refresh_requested"))
            .appending(operation(4, "discovery_request_count", "\(refreshCount)"))
            .appending(operation(5, "save_requested"))
            .appending(operation(6, "store_save_count", "\(context.store.saveCount)"))
            .appending(operation(7, "start_requested"))
            .appending(operation(8, "session_start_count", "\(context.sessionManager.startCount)"))
    }

    private func doubleSaveRaceScenario() async throws -> ScenarioContext {
        let gate = ProofBlockingGate()
        let context = makeCommittedContext(status: .completed, saveGate: gate)
        await context.state.refreshStatus()
        context.state.settings.wifiDevice = "en1"

        let firstSave = Task { try await context.state.saveSettings() }
        guard await gate.waitUntilEntered() else {
            throw ProofAppError.renderingFailed("first Save did not reach the store gate")
        }
        let secondError: String
        do {
            try await context.state.saveSettings()
            secondError = "none"
        } catch {
            secondError = proofErrorCategory(error)
        }
        gate.release()
        let firstResult = await saveTaskResult(firstSave)

        return context
            .appending(operation(2, "first_save_dispatched"))
            .appending(operation(3, "save_gate_entered", "true"))
            .appending(operation(4, "second_save_requested"))
            .appending(operation(5, "second_save_error", secondError))
            .appending(operation(6, "save_gate_released"))
            .appending(operation(7, "first_save_result", firstResult))
            .appending(operation(8, "store_save_count", "\(context.store.saveCount)"))
    }

    private func saveStartRaceScenario() async throws -> ScenarioContext {
        let gate = ProofBlockingGate()
        let context = makeCommittedContext(status: .completed, saveGate: gate)
        await context.state.refreshStatus()
        context.state.settings.wifiDevice = "en1"

        let save = Task { try await context.state.saveSettings() }
        guard await gate.waitUntilEntered() else {
            throw ProofAppError.renderingFailed("Save did not reach the store gate")
        }
        await context.state.start()
        let countDuringSave = context.sessionManager.startCount
        gate.release()
        let saveResult = await saveTaskResult(save)

        return context
            .appending(operation(2, "save_dispatched"))
            .appending(operation(3, "save_gate_entered", "true"))
            .appending(operation(4, "start_requested_during_save"))
            .appending(operation(5, "session_start_count_during_save", "\(countDuringSave)"))
            .appending(operation(6, "save_gate_released"))
            .appending(operation(7, "save_result", saveResult))
            .appending(operation(8, "store_save_count", "\(context.store.saveCount)"))
            .appending(
                operation(9, "session_start_count_final", "\(context.sessionManager.startCount)")
            )
    }

    private func quitSaveRaceScenario() async throws -> ScenarioContext {
        switch arguments.variant {
        case "save-first":
            try await saveFirstQuitRaceScenario()
        case "quit-first":
            try await quitFirstSaveRaceScenario()
        default:
            throw ProofAppError.invalidVariant(arguments.variant ?? "missing")
        }
    }

    private func saveFirstQuitRaceScenario() async throws -> ScenarioContext {
        let saveGate = ProofBlockingGate()
        let context = makeCommittedContext(status: .completed, saveGate: saveGate)
        await context.state.refreshStatus()
        context.state.settings.wifiDevice = "en1"

        let save = Task { try await context.state.saveSettings() }
        guard await saveGate.waitUntilEntered() else {
            throw ProofAppError.renderingFailed("Save did not reach the store gate")
        }
        let quit = Task { await context.state.requestQuit() }
        try? await Task.sleep(for: .milliseconds(40))
        let quitCountBeforeRelease = context.sessionManager.quitCount
        let secondSaveError: String
        do {
            try await context.state.saveSettings()
            secondSaveError = "none"
        } catch {
            secondSaveError = proofErrorCategory(error)
        }
        saveGate.release()
        let saveResult = await saveTaskResult(save)
        let quitResult = await quit.value

        return context
            .appending(operation(2, "save_dispatched"))
            .appending(operation(3, "save_gate_entered", "true"))
            .appending(operation(4, "quit_requested_during_save"))
            .appending(operation(5, "quit_count_before_release", "\(quitCountBeforeRelease)"))
            .appending(operation(6, "second_save_requested_during_quit"))
            .appending(operation(7, "second_save_error", secondSaveError))
            .appending(operation(8, "save_gate_released"))
            .appending(operation(9, "save_result", saveResult))
            .appending(operation(10, "quit_result", "\(quitResult)"))
            .appending(operation(11, "quit_count_final", "\(context.sessionManager.quitCount)"))
            .appending(operation(12, "store_save_count", "\(context.store.saveCount)"))
            .appending(
                operation(13, "session_start_count", "\(context.sessionManager.startCount)")
            )
    }

    private func quitFirstSaveRaceScenario() async throws -> ScenarioContext {
        let quitGate = ProofAsyncGate()
        let context = makeCommittedContext(status: .completed, stopGate: quitGate)
        await context.state.refreshStatus()
        context.state.settings.wifiDevice = "en1"

        let quit = Task { await context.state.requestQuit() }
        guard await quitGate.waitUntilEntered() else {
            throw ProofAppError.renderingFailed("Quit did not reach the stop gate")
        }
        let saveError: String
        do {
            try await context.state.saveSettings()
            saveError = "none"
        } catch {
            saveError = proofErrorCategory(error)
        }
        await context.state.start()
        await context.state.refreshConfiguration()
        let saveCountBeforeRelease = context.store.saveCount
        let startCountBeforeRelease = context.sessionManager.startCount
        let discoveryCountBeforeRelease = await context.discovery.requestCount()
        await quitGate.release()
        let quitResult = await quit.value

        return context
            .appending(operation(2, "quit_requested"))
            .appending(operation(3, "quit_stop_gate_entered", "true"))
            .appending(operation(4, "save_requested_during_quit"))
            .appending(operation(5, "save_error", saveError))
            .appending(operation(6, "start_requested_during_quit"))
            .appending(operation(7, "refresh_requested_during_quit"))
            .appending(
                operation(8, "store_save_count_before_release", "\(saveCountBeforeRelease)")
            )
            .appending(
                operation(9, "session_start_count_before_release", "\(startCountBeforeRelease)")
            )
            .appending(
                operation(
                    10,
                    "discovery_request_count_before_release",
                    "\(discoveryCountBeforeRelease)"
                )
            )
            .appending(operation(11, "quit_stop_gate_released"))
            .appending(operation(12, "quit_result", "\(quitResult)"))
            .appending(operation(13, "quit_count_final", "\(context.sessionManager.quitCount)"))
    }

    private func saveTaskResult(_ task: Task<Void, Error>) async -> String {
        do {
            try await task.value
            return "success"
        } catch {
            return proofErrorCategory(error)
        }
    }

    private func proofErrorCategory(_ error: Error) -> String {
        guard let configurationError = error as? HotspotConfigurationError else {
            return "unexpected_error"
        }
        if case .cleanupPending = configurationError {
            return "cleanup_pending"
        }
        return "unexpected_hotspot_error"
    }

    private func makeContext(
        snapshotResponses: [ProofWiFiDiscovery.Response],
        settings: TravelModeSettings = TravelModeSettings(),
        password: String? = nil,
        lifecycle: TravelSessionLifecycle = .off,
        saveGate: ProofBlockingGate? = nil,
        stopGate: ProofAsyncGate? = nil
    ) -> ScenarioContext {
        let store = ProofSettingsStore(
            settings: settings,
            password: password,
            saveGate: saveGate
        )
        let gateway = ProofGateway(stopGate: stopGate)
        let discovery = ProofWiFiDiscovery(responses: snapshotResponses)
        let sessionManager = ProofSessionManager(lifecycle: lifecycle)
        let state = TravelModeAppState(
            gateway: gateway,
            settingsStore: store,
            wifiDiscovery: discovery,
            sessionManager: sessionManager
        )
        let beforeRevision = try? store.activeHotspotConfiguration().map(ProofRevision.init)
        return ScenarioContext(
            state: state,
            store: store,
            gateway: gateway,
            discovery: discovery,
            sessionManager: sessionManager,
            beforeRevision: beforeRevision,
            secretReadsAfterInitialization: store.passwordReadCount,
            operations: [operation(1, "proof_app_launched", arguments.launchID)]
        )
    }

    private func makeCommittedContext(
        status: WiFiVisibleScanStatus,
        lifecycle: TravelSessionLifecycle = .off,
        saveGate: ProofBlockingGate? = nil,
        stopGate: ProofAsyncGate? = nil
    ) -> ScenarioContext {
        makeContext(
            snapshotResponses: [response(snapshot(status: status))],
            settings: TravelModeSettings(
                hotspotSSID: "Example iPhone",
                wifiDevice: "en0"
            ),
            password: "credential-confined-to-proof-process",
            lifecycle: lifecycle,
            saveGate: saveGate,
            stopGate: stopGate
        )
    }

    private func response(
        _ snapshot: WiFiDiscoverySnapshot,
        delay: Duration = .zero,
        blocksUntilProcessExit: Bool = false
    ) -> ProofWiFiDiscovery.Response {
        ProofWiFiDiscovery.Response(
            snapshot: snapshot,
            delay: delay,
            blocksUntilProcessExit: blocksUntilProcessExit
        )
    }

    private func snapshot(status: WiFiVisibleScanStatus) -> WiFiDiscoverySnapshot {
        WiFiDiscoverySnapshot(
            interfaceName: status == .noWiFiInterface ? nil : "en0",
            rememberedNetworks: [],
            visibleNetworks: [],
            visibleScanStatus: status
        )
    }

    private func ssids(_ names: [String]) -> [WiFiSSID] {
        names.compactMap(WiFiSSID.init(displayName:))
    }

    private func statusVariant(_ raw: String?) throws -> WiFiVisibleScanStatus {
        guard let raw, let status = WiFiVisibleScanStatus(rawValue: raw) else {
            throw ProofAppError.invalidVariant(raw ?? "missing")
        }
        return status
    }

    private func lifecycleVariant(_ raw: String?) throws -> TravelSessionLifecycle {
        guard let raw, let lifecycle = TravelSessionLifecycle(rawValue: raw) else {
            throw ProofAppError.invalidVariant(raw ?? "missing")
        }
        return lifecycle
    }

    private func operation(_ sequence: Int, _ name: String, _ value: String? = nil) -> ProofOperation {
        ProofOperation(sequence: sequence, name: name, value: value)
    }

    private func discoveryState(_ state: HotspotDiscoveryViewState) -> String {
        switch state {
        case .idle:
            "idle"
        case .loading:
            "loading"
        case .loaded(let snapshot):
            snapshot.visibleScanStatus.rawValue
        }
    }

    private func capture(
        _ view: NSView,
        to url: URL,
        identifier: String
    ) throws -> ProofScreenshot {
        view.layoutSubtreeIfNeeded()
        guard view.bounds.width >= 280, view.bounds.height >= 180,
              let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            throw ProofAppError.renderingFailed("the production view has no renderable bitmap")
        }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else {
            throw ProofAppError.renderingFailed("AppKit did not encode the rendered view as PNG")
        }
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try png.write(to: url, options: .atomic)
        return ProofScreenshot(
            path: url.path,
            renderedViewIdentifier: identifier,
            width: bitmap.pixelsWide,
            height: bitmap.pixelsHigh,
            sourcePID: ProcessInfo.processInfo.processIdentifier
        )
    }

    private func renderedSnapshot(from root: NSView) -> [RenderedElementSnapshot] {
        var result: [RenderedElementSnapshot] = []
        var visited: Set<ObjectIdentifier> = []

        func visit(_ value: Any) {
            guard let object = value as? NSObject,
                  visited.insert(ObjectIdentifier(object)).inserted else { return }
            appendSnapshot(of: object, to: &result)

            let rawChildren = accessibilityArray("accessibilityChildren", of: object)
                + (accessibilityAttribute("AXChildren", of: object) as? [Any] ?? [])
            for child in rawChildren {
                visit(child)
            }
            for child in NSAccessibility.unignoredChildren(from: rawChildren) {
                visit(child)
            }
            for child in accessibilityArray(
                "accessibilityChildrenInNavigationOrder",
                of: object
            ) {
                visit(child)
            }
            for child in accessibilityArray("accessibilityContents", of: object) {
                visit(child)
            }
            if let view = object as? NSView {
                for subview in view.subviews {
                    visit(subview)
                }
            }
        }

        visit(root)
        return result
    }

    private func primeSelfAccessibilityHierarchy() throws {
        let applicationElement = AXUIElementCreateApplication(
            ProcessInfo.processInfo.processIdentifier
        )
        var windows: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(
            applicationElement,
            kAXWindowsAttribute as CFString,
            &windows
        )
        guard status == .success,
              let windowElements = windows as? [AXUIElement],
              !windowElements.isEmpty else {
            throw ProofAppError.renderingFailed(
                "self accessibility activation failed with status \(status.rawValue)"
            )
        }
    }

    private func appendSnapshot(
        of element: NSObject,
        to result: inout [RenderedElementSnapshot]
    ) {
        let role = renderedString(accessibilityValue("accessibilityRole", of: element))
            ?? renderedString(accessibilityAttribute("AXRole", of: element))
            ?? NSAccessibility.Role.unknown.rawValue
        let identifier = nonempty(
            renderedString(accessibilityValue("accessibilityIdentifier", of: element))
                ?? renderedString(accessibilityAttribute("AXIdentifier", of: element))
        )
        let label = nonempty(
            renderedString(accessibilityValue("accessibilityLabel", of: element))
                ?? renderedString(accessibilityAttribute("AXDescription", of: element))
        )
        let sourceClass = String(describing: type(of: element))
        let isProtected = accessibilityBool("accessibilityProtectedContent", of: element)
            || identifier == "hotspot.password"
            || sourceClass.localizedCaseInsensitiveContains("secure")
        let rawValue = isProtected
            ? nil
            : nonempty(
                renderedString(accessibilityValue("accessibilityValue", of: element))
                    ?? renderedString(accessibilityAttribute("AXValue", of: element))
            )
        guard identifier != nil
            || label != nil
            || rawValue != nil
            || role != NSAccessibility.Role.unknown.rawValue else { return }
        result.append(
            RenderedElementSnapshot(
                identifier: identifier,
                role: role,
                label: label,
                value: rawValue,
                enabled: accessibilityBool("accessibilityEnabled", of: element),
                protectedContent: isProtected,
                frame: RenderedFrame(accessibilityFrame(of: element)),
                sourceClass: sourceClass
            )
        )
    }

    private func accessibilityArray(_ name: String, of object: NSObject) -> [Any] {
        accessibilityValue(name, of: object) as? [Any] ?? []
    }

    private func accessibilityValue(_ name: String, of object: NSObject) -> Any? {
        let selector = NSSelectorFromString(name)
        guard object.responds(to: selector) else { return nil }
        return object.perform(selector)?.takeUnretainedValue()
    }

    private func accessibilityAttribute(_ name: String, of object: NSObject) -> Any? {
        let selector = NSSelectorFromString("accessibilityAttributeValue:")
        guard object.responds(to: selector) else { return nil }
        return object.perform(selector, with: name)?.takeUnretainedValue()
    }

    private func accessibilityBool(_ key: String, of object: NSObject) -> Bool {
        let getter = key == "accessibilityEnabled"
            ? "isAccessibilityEnabled"
            : "isAccessibilityProtectedContent"
        guard object.responds(to: NSSelectorFromString(getter)) else { return false }
        return (object.value(forKey: key) as? NSNumber)?.boolValue
            ?? (accessibilityAttribute("AXEnabled", of: object) as? NSNumber)?.boolValue
            ?? false
    }

    private func accessibilityFrame(of object: NSObject) -> NSRect {
        if let view = object as? NSView {
            return view.accessibilityFrame()
        }
        if let element = object as? NSAccessibilityElement {
            return element.accessibilityFrame()
        }
        guard object.responds(to: NSSelectorFromString("accessibilityFrame")),
              let value = object.value(forKey: "accessibilityFrame") as? NSValue else {
            return .zero
        }
        return value.rectValue
    }

    private func nonempty(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return value
    }

    private func renderedString(_ value: Any?) -> String? {
        switch value {
        case let string as String:
            string
        case let attributed as NSAttributedString:
            attributed.string
        case let number as NSNumber:
            number.stringValue
        default:
            nil
        }
    }

    private func renderedControlStates(
        from elements: [RenderedElementSnapshot]
    ) throws -> [String: Bool] {
        let identifiers = [
            "discovered_network": "hotspot.discovered-network",
            "manual_ssid": "hotspot.manual-ssid",
            "password": "hotspot.password",
            "refresh_networks": "hotspot.refresh-networks",
            "save_hotspot": "hotspot.save",
            "primary_action": "travel.primary-action"
        ]
        var states: [String: Bool] = [:]
        for (name, identifier) in identifiers {
            guard let element = elements.first(where: { $0.identifier == identifier }) else {
                let observed = elements.map {
                    "identifier=\($0.identifier ?? "nil") role=\($0.role) "
                        + "label=\($0.label ?? "nil") value=\($0.value ?? "nil")"
                }.joined(separator: "; ")
                throw ProofAppError.renderingFailed(
                    "rendered accessibility hierarchy omitted \(identifier); observed \(observed)"
                )
            }
            states[name] = element.enabled
        }
        guard let primary = elements.first(where: {
            $0.identifier == "travel.primary-action"
        }) else {
            throw ProofAppError.renderingFailed(
                "rendered accessibility hierarchy omitted travel.primary-action"
            )
        }
        let primaryName = primary.label ?? primary.value
        states["start"] = primaryName == "Start" ? primary.enabled : false
        states["stop"] = primaryName == "Stop & Restore" ? primary.enabled : false
        return states
    }

    private func write(_ observation: UIProofObservation, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.keyEncodingStrategy = .convertToSnakeCase
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try encoder.encode(observation).write(to: url, options: .atomic)
    }
}

private extension ScenarioContext {
    func appending(_ operation: ProofOperation) -> ScenarioContext {
        var copy = self
        copy.operations.append(operation)
        return copy
    }
}

@main
private enum HotspotConfigurationProofAppMain {
    @MainActor
    static func main() {
        do {
            let arguments = try Arguments.parse(Array(CommandLine.arguments.dropFirst()))
            let app = NSApplication.shared
            app.setActivationPolicy(.accessory)
            let delegate = ProofAppDelegate(arguments: arguments)
            app.delegate = delegate
            app.run()
            withExtendedLifetime(delegate) {}
        } catch {
            FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8))
            Darwin.exit(2)
        }
    }
}
