import Combine
import Foundation

public enum HotspotDiscoveryViewState: Equatable, Sendable {
    case idle
    case loading
    case loaded(WiFiDiscoverySnapshot)
}

public enum TravelModeLifecyclePresentation: Equatable, Sendable {
    case off
    case preparing
    case active
    case restoring
    case recovering
    case cleanupRequired
}

private struct HotspotRuntimeSnapshot: Sendable {
    let revision: HotspotConfigurationRevision
    let settings: TravelModeSettings
    let password: String
}

private enum TravelInternetActivationError: LocalizedError {
    case missingSessionIdentity

    var errorDescription: String? {
        "Travel Mode could not bind internet handoff to the active session."
    }
}

@MainActor
private final class TravelModeActivationFence {
    private var isComplete = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !isComplete else { return }
        await withCheckedContinuation { continuation in
            if isComplete {
                continuation.resume()
            } else {
                waiters.append(continuation)
            }
        }
    }

    func complete() {
        guard !isComplete else { return }
        isComplete = true
        let currentWaiters = waiters
        waiters.removeAll()
        currentWaiters.forEach { $0.resume() }
    }
}

private enum TravelModeCleanupOrigin: Equatable, Sendable {
    case stop
    case quit
    case retry
    case startupRecovery
    case protectionRecovery
    case activationFailure
}

private struct TravelModeCleanupOperation {
    let id: UUID
    let task: Task<TravelSessionTransitionResult, Never>
}

private struct TravelModeActivationOperation {
    let id: UUID
    let fence: TravelModeActivationFence
}

private enum TravelModeActivationCompletion {
    case finished
    case cleanup(TravelModeCleanupOrigin)
}

@MainActor
public final class TravelModeAppState: ObservableObject {
    @Published public var settings = TravelModeSettings()
    @Published public private(set) var isRunning = false
    @Published public private(set) var sessionLifecycle = TravelSessionLifecycle.off
    @Published public private(set) var isSessionLifecycleKnown = false
    @Published public private(set) var isSavingConfiguration = false
    @Published public private(set) var discoveryState = HotspotDiscoveryViewState.idle
    @Published public private(set) var latestStatus = "Stopped"
    @Published public private(set) var latestWiFiNetwork = "Unknown"
    @Published public private(set) var availableHotspots: [WiFiSSID] = []
    @Published public private(set) var isCodexRunning = false
    @Published public private(set) var hasSavedHotspotPassword = false
    @Published public private(set) var internetRuntimeState = TravelInternetRuntimeState.inactive
    @Published public private(set) var logs: [String] = []
    @Published public var lastErrorMessage: String?
    @Published public private(set) var hasPendingQuitIntent = false
    @Published public private(set) var lifecyclePresentation = TravelModeLifecyclePresentation.recovering
    @Published public private(set) var activationTaskInFlight = false

    private let gateway: TravelCommandGateway
    private let engine: TravelModeEngine
    private let settingsStore: TravelSettingsStoring
    private let wifiDiscovery: any WiFiDiscoveryProviding
    private let sessionManager: any TravelSessionManaging
    private let internetHandoffCoordinator: TravelInternetHandoffCoordinator?
    private var committedRevision: HotspotConfigurationRevision?
    private var committedSettings = TravelModeSettings()
    private var activeRuntimeSettings: TravelModeSettings?
    private var activeRuntimePassword: String?
    private var discoveryGeneration = 0
    private var saveTask: Task<Void, Error>?
    private var saveCompletionWaiters: [CheckedContinuation<Void, Never>] = []
    private var loopTask: Task<Void, Never>?
    private var protectionTask: Task<Void, Never>?
    private var activationInProgress = false
    private var activationOperation: TravelModeActivationOperation?
    private var cleanupOperation: TravelModeCleanupOperation?
    private var startupRecoveryInProgress = false
    private var pendingProtectionLoss: SleepOverrideLeaseProtectionEvent?
    private var lastPreservedNetwork: String?
    private var fallbackArmed = false
    private var activeHandoffGeneration: UUID?
    private var retryableHandoffEpisodeID: String?

    public init(
        gateway: TravelCommandGateway,
        engine: TravelModeEngine = TravelModeEngine(),
        settingsStore: TravelSettingsStoring = UserDefaultsTravelSettingsStore(),
        wifiDiscovery: any WiFiDiscoveryProviding = CoreWLANWiFiDiscoveryProvider(),
        sessionManager: any TravelSessionManaging,
        internetHandoffCoordinator: TravelInternetHandoffCoordinator? = nil
    ) {
        self.gateway = gateway
        self.engine = engine
        self.settingsStore = settingsStore
        self.wifiDiscovery = wifiDiscovery
        self.sessionManager = sessionManager
        self.internetHandoffCoordinator = internetHandoffCoordinator
        try? settingsStore.recoverHotspotConfiguration()
        if let active = try? settingsStore.activeHotspotConfiguration() {
            let committedSettings = Self.settings(from: active)
            self.committedRevision = active
            self.committedSettings = committedSettings
            self.settings = committedSettings
            self.hasSavedHotspotPassword = Self.hasValidCredential(
                in: settingsStore,
                revision: active
            )
        } else {
            self.settings = settingsStore.legacyHotspotDraft() ?? TravelModeSettings()
        }
    }

    public var canStart: Bool {
        !isRunning
            && !isConfigurationLocked
            && isCodexRunning
            && !hasUnsavedHotspotDraft
            && committedRevision != nil
            && (try? HotspotConfigurationRevision.validateSSID(committedSettings.hotspotSSID)) != nil
            && (try? HotspotConfigurationRevision.validateWiFiDevice(
                committedSettings.wifiDevice.isEmpty ? nil : committedSettings.wifiDevice
            )) != nil
            && !committedSettings.wifiDevice.isEmpty
            && hasSavedHotspotPassword
    }

    public var committedHotspotSSID: String? {
        committedSettings.hotspotSSID.isEmpty ? nil : committedSettings.hotspotSSID
    }

    public var committedWiFiDevice: String? {
        committedSettings.wifiDevice.isEmpty ? nil : committedSettings.wifiDevice
    }

    public var locationAuthorizationStatus: WiFiVisibleScanStatus? {
        guard case .loaded(let snapshot) = discoveryState else { return nil }
        return snapshot.visibleScanStatus
    }

    public var isCommittedHotspotVisible: Bool {
        guard let hotspot = committedHotspotSSID,
              case .loaded(let snapshot) = discoveryState,
              snapshot.visibleScanStatus == .completed,
              let exactSSID = WiFiSSID(displayName: hotspot) else {
            return false
        }
        return snapshot.visibleNetworks.contains(exactSSID)
    }

    public var hasUnsavedHotspotDraft: Bool {
        !settings.hotspotSSID.hasExactUTF8Representation(as: committedSettings.hotspotSSID)
            || settings.wifiDevice != committedSettings.wifiDevice
            || !settings.hotspotPassword.isEmpty
    }

    public var isCleanlyOffForTermination: Bool {
        isSessionLifecycleKnown
            && sessionLifecycle == .off
            && !activationInProgress
            && activationOperation == nil
            && cleanupOperation == nil
            && !startupRecoveryInProgress
            && !isSavingConfiguration
            && saveTask == nil
    }

    public var isConfigurationLocked: Bool {
        !isSessionLifecycleKnown
            || isSavingConfiguration
            || activationInProgress
            || cleanupOperation != nil
            || hasPendingQuitIntent
            || sessionLifecycle != .off
    }

    public var canRetryInternetHandoff: Bool {
        isRunning
            && activeHandoffGeneration != nil
            && retryableHandoffEpisodeID != nil
    }

    public func refreshConfiguration(requestAuthorization: Bool = false) async {
        await synchronizeSessionLifecycleIfNeeded()
        guard !isConfigurationLocked else { return }
        discoveryGeneration += 1
        let generation = discoveryGeneration
        discoveryState = .loading
        if requestAuthorization {
            await wifiDiscovery.requestLocationAuthorization()
        }
        let snapshot = await wifiDiscovery.snapshot()
        guard generation == discoveryGeneration, !isConfigurationLocked else { return }
        discoveryState = .loaded(snapshot)
        if settings.wifiDevice.isEmpty, let interfaceName = snapshot.interfaceName {
            settings.wifiDevice = interfaceName
        }
        availableHotspots = hotspotChoices(from: snapshot)
    }

    public func start() async {
        guard !isRunning,
              !activationInProgress,
              activationOperation == nil,
              cleanupOperation == nil,
              !isSavingConfiguration,
              !hasPendingQuitIntent,
              (!isSessionLifecycleKnown || sessionLifecycle == .off) else { return }
        let operation = TravelModeActivationOperation(
            id: UUID(),
            fence: TravelModeActivationFence()
        )
        activationOperation = operation
        activationTaskInFlight = true
        activationInProgress = true
        updateLifecyclePresentation()
        let completion = await performActivation()
        finishActivation(operation)
        if case .cleanup(let origin) = completion {
            _ = await requestCleanup(origin: origin)
        }
    }

    public func stop() async {
        _ = await requestCleanup(origin: .stop)
    }

    public func recoverPreviousSessionIfNeeded() async {
        if isSessionLifecycleKnown, sessionLifecycle == .off, cleanupOperation == nil {
            return
        }
        _ = await requestCleanup(origin: .startupRecovery)
    }

    public func requestQuit() async -> Bool {
        if isCleanlyOffForTermination {
            return true
        }
        hasPendingQuitIntent = true
        if isSavingConfiguration {
            await withCheckedContinuation { continuation in
                if isSavingConfiguration {
                    saveCompletionWaiters.append(continuation)
                } else {
                    continuation.resume()
                }
            }
        }
        if let saveTask {
            _ = try? await saveTask.value
        }
        if isCleanlyOffForTermination {
            return true
        }
        let result = await requestCleanup(origin: .quit)
        return result.lifecycle == .off && isCleanlyOffForTermination
    }

    @discardableResult
    public func retryCleanup() async -> Bool {
        let shouldTerminate = hasPendingQuitIntent
        guard cleanupOperation != nil || sessionLifecycle == .cleanupRequired else {
            return shouldTerminate && isCleanlyOffForTermination
        }
        let result = await requestCleanup(origin: shouldTerminate ? .quit : .retry)
        return shouldTerminate && result.lifecycle == .off && isCleanlyOffForTermination
    }

    private func performActivation() async -> TravelModeActivationCompletion {
        let lifecycle = await sessionManager.lifecycle()
        sessionLifecycle = lifecycle
        isSessionLifecycleKnown = true
        guard activationInProgress, lifecycle == .off else {
            updateLifecyclePresentation()
            return .finished
        }
        guard let runtime = await runtimeSnapshotForStart(), activationInProgress else {
            return .finished
        }
        sessionLifecycle = .preparing
        updateLifecyclePresentation()
        activeRuntimeSettings = runtime.settings
        activeRuntimePassword = runtime.password
        pendingProtectionLoss = nil
        await beginProtectionWatch()
        guard activationInProgress else { return .finished }
        let result = await sessionManager.start(
            configuration: TravelSessionConfiguration(wifiDevice: runtime.settings.wifiDevice)
        )
        guard activationInProgress else { return .finished }
        applySessionResult(result)
        guard result.lifecycle == .active else {
            pendingProtectionLoss = nil
            activeRuntimeSettings = nil
            activeRuntimePassword = nil
            cancelProtectionWatch()
            return .finished
        }
        if let event = consumePendingProtectionLoss() {
            prepareForProtectionRecovery(event)
            return .cleanup(.protectionRecovery)
        }
        do {
            try await gateway.startKeepAwake()
            guard activationInProgress, sessionLifecycle == .active else {
                await gateway.stopKeepAwake()
                return .finished
            }
            if let event = consumePendingProtectionLoss() {
                await gateway.stopKeepAwake()
                prepareForProtectionRecovery(event)
                return .cleanup(.protectionRecovery)
            }
            isRunning = true
            updateLifecyclePresentation()
            latestStatus = "Travel Mode active"
            appendLog("Travel Mode started")
            lastErrorMessage = nil
            if let internetHandoffCoordinator {
                guard let sessionID = result.sessionID,
                      let targetSSID = ExactUTF8String(runtime.settings.hotspotSSID) else {
                    throw TravelInternetActivationError.missingSessionIdentity
                }
                let generation = UUID()
                activeHandoffGeneration = generation
                let publication = await internetHandoffCoordinator.activate(
                    HandoffSessionContext(
                        sessionID: sessionID,
                        generation: generation,
                        device: runtime.settings.wifiDevice,
                        targetSSID: targetSSID,
                        password: runtime.password
                    )
                )
                guard activeHandoffGeneration == generation else { return .finished }
                apply(publication)
            } else {
                _ = await ensureFallbackIsArmedIfPossible()
            }
            if let event = consumePendingProtectionLoss() {
                prepareForProtectionRecovery(event)
                return .cleanup(.protectionRecovery)
            }
            guard isRunning else { return .finished }
            beginLoop()
            return .finished
        } catch {
            pendingProtectionLoss = nil
            lastErrorMessage = "Travel Mode could not start safely."
            latestStatus = lastErrorMessage ?? "Travel Mode could not start safely."
            appendLog(latestStatus)
            await gateway.stopKeepAwake()
            return .cleanup(.activationFailure)
        }
    }

    public func refreshStatus() async {
        await synchronizeSessionLifecycleIfNeeded()
        let preferredDevice = (activeRuntimeSettings ?? committedSettings).wifiDevice
        if preferredDevice.isEmpty, settings.wifiDevice.isEmpty {
            await refreshConfiguration()
        }

        let device = preferredDevice.isEmpty ? settings.wifiDevice : preferredDevice
        guard !device.isEmpty else {
            latestWiFiNetwork = "Missing Wi-Fi device"
            return
        }

        let status = await gateway.currentWiFiStatus(device: device)
        latestWiFiNetwork = status.networkName ?? "Not associated"
        isCodexRunning = await gateway.isCodexRunning()
    }

    private func hotspotChoices(from snapshot: WiFiDiscoverySnapshot) -> [WiFiSSID] {
        var choices: [WiFiSSID] = []
        var seen: Set<Data> = []
        if let committedSSID = WiFiSSID(displayName: committedSettings.hotspotSSID),
           seen.insert(committedSSID.utf8Bytes).inserted {
            choices.append(committedSSID)
        }
        for ssid in snapshot.selectableNetworks where seen.insert(ssid.utf8Bytes).inserted {
            choices.append(ssid)
        }
        return choices
    }

    private func availableHotspotsIncludingCommitted() -> [WiFiSSID] {
        guard let committedSSID = WiFiSSID(displayName: committedSettings.hotspotSSID) else {
            return availableHotspots
        }
        return [committedSSID] + availableHotspots.filter { $0 != committedSSID }
    }

    private static func settings(from revision: HotspotConfigurationRevision) -> TravelModeSettings {
        TravelModeSettings(
            hotspotSSID: revision.ssid,
            hotspotPassword: "",
            wifiDevice: revision.wifiDevice ?? ""
        )
    }

    @discardableResult
    private func reloadCommittedConfiguration() -> HotspotConfigurationRevision? {
        do {
            let active = try settingsStore.activeHotspotConfiguration()
            committedRevision = active
            if let active {
                committedSettings = Self.settings(from: active)
                hasSavedHotspotPassword = Self.hasValidCredential(
                    in: settingsStore,
                    revision: active
                )
            } else {
                committedSettings = TravelModeSettings()
                hasSavedHotspotPassword = false
            }
            return active
        } catch {
            return committedRevision
        }
    }

    private static func hasValidCredential(
        in store: TravelSettingsStoring,
        revision: HotspotConfigurationRevision
    ) -> Bool {
        guard let password = try? store.loadHotspotPassword(
            credentialReference: revision.credentialReference
        ) else { return false }
        return !password.isEmpty
    }

    public func syncOnce() async {
        if let internetHandoffCoordinator {
            guard isRunning, let generation = activeHandoffGeneration else { return }
            let codexIsRunning = await gateway.isCodexRunning()
            guard isRunning, generation == activeHandoffGeneration else { return }
            isCodexRunning = codexIsRunning
            let publication = await internetHandoffCoordinator.tick(generation: generation)
            guard isRunning,
                  generation == activeHandoffGeneration,
                  publication.generation == generation else { return }
            apply(publication)
            return
        }
        isCodexRunning = await gateway.isCodexRunning()
        guard await ensureFallbackIsArmedIfPossible() else {
            return
        }
        let forceFallback = await shouldForceFallbackForClosedLid()
        let runtimePassword = activeRuntimePassword
        let event = await engine.sync(
            settings: activeRuntimeSettings ?? committedSettings,
            gateway: gateway,
            passwordProvider: { runtimePassword },
            forceFallback: forceFallback
        )
        apply(event)
    }

    public func retryInternetHandoff() async {
        guard let internetHandoffCoordinator,
              isRunning,
              retryableHandoffEpisodeID != nil,
              let generation = activeHandoffGeneration else { return }
        let publication = await internetHandoffCoordinator.retry(generation: generation)
        guard isRunning,
              generation == activeHandoffGeneration,
              publication.generation == generation else { return }
        apply(publication)
    }

    public func openWiFiSettings() async {
        await gateway.openWiFiSettings()
    }

    public func saveSettings() async throws {
        guard !isSavingConfiguration,
              saveTask == nil,
              !activationInProgress,
              activationOperation == nil,
              cleanupOperation == nil,
              !hasPendingQuitIntent else {
            throw HotspotConfigurationError.cleanupPending("another Save is already in progress")
        }
        isSavingConfiguration = true
        defer { finishConfigurationSave() }
        let lifecycle = await sessionManager.lifecycle()
        sessionLifecycle = lifecycle
        isSessionLifecycleKnown = true
        updateLifecyclePresentation()
        guard lifecycle == .off, !activationInProgress else {
            throw HotspotConfigurationError.cleanupPending(
                "Travel Mode configuration is locked while the session is \(lifecycle.rawValue)"
            )
        }

        let draft = settings
        let previousRevision = committedRevision
        let store = settingsStore
        let task = Task.detached { try store.save(draft) }
        saveTask = task
        defer { saveTask = nil }
        do {
            try await task.value
            try settingsStore.recoverHotspotConfiguration()
        } catch {
            let activeChanged = reloadCommittedConfiguration() != previousRevision
            if activeChanged {
                settings = committedSettings
            }
            availableHotspots = availableHotspotsIncludingCommitted()
            throw error
        }
        _ = reloadCommittedConfiguration()
        settings = committedSettings
        availableHotspots = availableHotspotsIncludingCommitted()
        latestStatus = "Saved fallback hotspot '\(committedSettings.hotspotSSID)'"
        lastErrorMessage = nil
        appendLog(latestStatus)
    }

    private func beginLoop() {
        loopTask?.cancel()
        loopTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled else { break }
                await self?.syncOnce()
            }
        }
    }

    private func synchronizeSessionLifecycleIfNeeded() async {
        guard !isSessionLifecycleKnown else { return }
        sessionLifecycle = await sessionManager.lifecycle()
        isSessionLifecycleKnown = true
        updateLifecyclePresentation()
    }

    private func cancelLoop() -> Task<Void, Never>? {
        let runningLoop = loopTask
        loopTask = nil
        runningLoop?.cancel()
        return runningLoop
    }

    private func finishActivation(_ operation: TravelModeActivationOperation) {
        if activationOperation?.id == operation.id {
            activationOperation = nil
            activationTaskInFlight = false
            activationInProgress = false
        }
        operation.fence.complete()
        updateLifecyclePresentation()
    }

    private func requestCleanup(
        origin: TravelModeCleanupOrigin
    ) async -> TravelSessionTransitionResult {
        if let existing = cleanupOperation {
            let result = await existing.task.value
            finishCleanupOperation(id: existing.id)
            return result
        }

        activationInProgress = false
        pendingProtectionLoss = nil
        if origin == .startupRecovery {
            startupRecoveryInProgress = true
        } else {
            sessionLifecycle = .restoring
            isSessionLifecycleKnown = true
            isRunning = false
        }
        updateLifecyclePresentation()

        let id = UUID()
        let activationFence = activationOperation?.fence
        let task = Task { @MainActor [weak self] in
            guard let self else {
                return TravelSessionTransitionResult(
                    lifecycle: .cleanupRequired,
                    error: "Travel Mode cleanup was interrupted.",
                    canTerminate: false
                )
            }
            return await self.performCleanup(
                origin: origin,
                activationFence: activationFence
            )
        }
        cleanupOperation = TravelModeCleanupOperation(id: id, task: task)
        let result = await task.value
        finishCleanupOperation(id: id)
        return result
    }

    private func finishCleanupOperation(id: UUID) {
        guard cleanupOperation?.id == id else { return }
        cleanupOperation = nil
        startupRecoveryInProgress = false
        updateLifecyclePresentation()
    }

    private func performCleanup(
        origin: TravelModeCleanupOrigin,
        activationFence: TravelModeActivationFence?
    ) async -> TravelSessionTransitionResult {
        if origin == .startupRecovery {
            let lifecycle = await sessionManager.lifecycle()
            sessionLifecycle = lifecycle
            isSessionLifecycleKnown = true
            updateLifecyclePresentation()
            guard lifecycle != .off else {
                return TravelSessionTransitionResult(lifecycle: .off)
            }
            appendLog("Recovering previous Travel Mode session")
        }

        let transitionTask = Task { [sessionManager] in
            switch origin {
            case .quit:
                return await sessionManager.requestQuit()
            case .retry, .startupRecovery, .protectionRecovery:
                return await sessionManager.recover()
            case .stop, .activationFailure:
                return await sessionManager.stop()
            }
        }

        cancelProtectionWatch()
        let runningLoop = cancelLoop()
        let handoffTask = await invalidateInternetHandoff()
        await gateway.stopKeepAwake()
        let result = await transitionTask.value
        if let activationFence {
            await activationFence.wait()
        }
        if let handoffTask {
            await handoffTask.value
        }
        if let runningLoop {
            await runningLoop.value
        }

        applySessionResult(result)
        clearRuntimeStateAfterCleanup()
        applyCleanupCompletionStatus(result: result, origin: origin)
        return result
    }

    private func clearRuntimeStateAfterCleanup() {
        activeRuntimeSettings = nil
        activeRuntimePassword = nil
        lastPreservedNetwork = nil
        fallbackArmed = false
        internetRuntimeState = .inactive
        retryableHandoffEpisodeID = nil
    }

    private func applyCleanupCompletionStatus(
        result: TravelSessionTransitionResult,
        origin: TravelModeCleanupOrigin
    ) {
        guard result.lifecycle == .off else { return }
        switch origin {
        case .startupRecovery:
            latestStatus = result.warning == nil
                ? "Recovered previous Travel Mode settings"
                : "Recovered previous Travel Mode settings with a warning."
        case .protectionRecovery:
            latestStatus = result.warning == nil
                ? "Travel Mode stopped after helper protection was lost."
                : "Travel Mode stopped after helper protection was lost, with a warning."
        case .activationFailure:
            latestStatus = "Travel Mode is off after a failed Start."
            lastErrorMessage = "Travel Mode could not start safely."
        case .quit:
            latestStatus = result.warning == nil
                ? "Travel Mode restored; ready to quit."
                : "Travel Mode restored with a warning; ready to quit."
        case .stop, .retry:
            latestStatus = result.warning == nil
                ? "Stopped"
                : "Travel Mode restored with a warning."
        }
        if origin == .stop, result.warning == nil {
            appendLog("Travel Mode stopped")
        } else {
            appendLog(latestStatus)
        }
    }

    private func invalidateInternetHandoff() async -> Task<Void, Never>? {
        guard let internetHandoffCoordinator,
              let generation = activeHandoffGeneration else { return nil }
        activeHandoffGeneration = nil
        internetRuntimeState = .inactive
        retryableHandoffEpisodeID = nil
        return await internetHandoffCoordinator.invalidate(generation: generation)
    }

    private func beginProtectionWatch() async {
        guard protectionTask == nil else { return }
        let events = await sessionManager.protectionEvents()
        protectionTask = Task { [weak self] in
            guard let self else { return }
            for await event in events {
                guard !Task.isCancelled else { break }
                await self.handleProtectionLoss(event)
            }
        }
    }

    private func cancelProtectionWatch() {
        protectionTask?.cancel()
        protectionTask = nil
    }

    private func handleProtectionLoss(_ event: SleepOverrideLeaseProtectionEvent) async {
        if activationInProgress {
            pendingProtectionLoss = event
            return
        }
        guard isRunning else { return }
        prepareForProtectionRecovery(event)
        _ = await requestCleanup(origin: .protectionRecovery)
    }

    private func consumePendingProtectionLoss() -> SleepOverrideLeaseProtectionEvent? {
        guard let event = pendingProtectionLoss else { return nil }
        pendingProtectionLoss = nil
        return event
    }

    private func prepareForProtectionRecovery(_ event: SleepOverrideLeaseProtectionEvent) {
        isRunning = false
        latestStatus = "Travel Mode protection was lost; restoring the saved session."
        appendLog("Sleep-helper protection lost: \(event.rawValue)")
        updateLifecyclePresentation()
    }

    private func runtimeSnapshotForStart() async -> HotspotRuntimeSnapshot? {
        isCodexRunning = await gateway.isCodexRunning()
        guard isCodexRunning else {
            latestStatus = "Cannot start: Codex is not running."
            appendLog(latestStatus)
            return nil
        }

        guard !hasUnsavedHotspotDraft else {
            latestStatus = "Cannot start: save or discard the hotspot changes first."
            appendLog(latestStatus)
            return nil
        }

        let active: HotspotConfigurationRevision
        do {
            guard let loaded = try settingsStore.activeHotspotConfiguration() else {
                throw HotspotConfigurationError.noActiveConfiguration
            }
            active = loaded
        } catch {
            latestStatus = "Cannot start: save a valid fallback hotspot."
            appendLog(latestStatus)
            return nil
        }

        guard active == committedRevision else {
            _ = reloadCommittedConfiguration()
            settings = committedSettings
            availableHotspots = availableHotspotsIncludingCommitted()
            latestStatus = "Cannot start: the committed hotspot changed; review it and start again."
            appendLog(latestStatus)
            return nil
        }

        let password: String
        do {
            password = try settingsStore.loadHotspotPassword(
                credentialReference: active.credentialReference
            )
        } catch {
            hasSavedHotspotPassword = false
            latestStatus = "Cannot start: the committed hotspot password is unavailable."
            appendLog(latestStatus)
            return nil
        }
        hasSavedHotspotPassword = !password.isEmpty
        guard !password.isEmpty else { return nil }

        guard let wifiDevice = active.wifiDevice, !wifiDevice.isEmpty else {
            latestStatus = "Cannot start: save the hotspot after a Wi-Fi device is detected."
            appendLog(latestStatus)
            return nil
        }

        return HotspotRuntimeSnapshot(
            revision: active,
            settings: TravelModeSettings(hotspotSSID: active.ssid, wifiDevice: wifiDevice),
            password: password
        )
    }

    private func shouldForceFallbackForClosedLid() async -> Bool {
        guard await gateway.currentLidClosed() == true else {
            return false
        }
        let runtimeSettings = activeRuntimeSettings ?? committedSettings
        latestStatus = "Lid closed; switching to fallback hotspot '\(runtimeSettings.hotspotSSID)'."
        appendLog(latestStatus)
        return true
    }

    private func apply(_ event: TravelModeEvent) {
        appendLog(event.message)
        switch event {
        case .preservedCurrentWiFi(let network):
            latestWiFiNetwork = network
            guard lastPreservedNetwork != network else { return }
            latestStatus = event.message
            lastPreservedNetwork = network
        default:
            latestStatus = event.message
            if case .hotspotConnected(let network) = event {
                latestWiFiNetwork = network
                lastPreservedNetwork = network
            } else {
                lastPreservedNetwork = nil
            }
        }
    }

    private func apply(_ publication: TravelInternetStatePublication) {
        internetRuntimeState = publication.state
        if case .failed = publication.state, let episodeID = publication.episodeID {
            retryableHandoffEpisodeID = episodeID
        } else {
            retryableHandoffEpisodeID = nil
        }
        switch publication.state {
        case .inactive:
            return
        case .waitingForConnection:
            latestWiFiNetwork = "Not associated"
            latestStatus = "Travel Mode active; waiting for a confirmed network transition."
            lastErrorMessage = nil
        case .preservingCurrentNetwork(let network):
            latestWiFiNetwork = network.stringValue
            latestStatus = "Preserving Wi-Fi '\(network.stringValue)'."
            lastErrorMessage = nil
        case .handoffPending(_, let trigger):
            latestStatus = handoffPendingMessage(trigger)
            lastErrorMessage = nil
        case .associating(_, let attempt):
            latestStatus = "Connecting to the configured iPhone (attempt \(attempt) of 3)."
            lastErrorMessage = nil
        case .verifying(_, let attempt):
            latestStatus = "Verifying iPhone internet (attempt \(attempt) of 3)."
            lastErrorMessage = nil
        case .connectedViaConfiguredHotspot(let network):
            latestWiFiNetwork = network.stringValue
            latestStatus = "Connected through '\(network.stringValue)' with verified internet."
            lastErrorMessage = nil
        case .retrying(_, let nextAttempt, _):
            latestStatus = "iPhone internet unavailable; retrying attempt \(nextAttempt) of 3."
            lastErrorMessage = nil
        case .failed(let failure):
            let message = safeHandoffFailureMessage(for: failure.kind)
            latestStatus = message
            lastErrorMessage = message
        }
        appendLog(latestStatus)
    }

    private func handoffPendingMessage(_ trigger: HandoffTrigger) -> String {
        switch trigger {
        case .initiallyClosed:
            return "Lid is closed; preparing the configured iPhone connection."
        case .lidClosed:
            return "Lid closed; switching to the configured iPhone."
        case .closedPathLost:
            return "The verified iPhone path was lost; starting bounded recovery."
        case .openDisconnection:
            return "Wi-Fi disconnected; starting the configured iPhone fallback."
        case .explicitRetry:
            return "Retrying the configured iPhone connection."
        }
    }

    private func ensureFallbackIsArmedIfPossible() async -> Bool {
        if fallbackArmed {
            return true
        }

        let device = (activeRuntimeSettings ?? committedSettings).wifiDevice
        guard !device.isEmpty else {
            latestStatus = "Missing Wi-Fi device"
            appendLog(latestStatus)
            return false
        }

        let status = await gateway.currentWiFiStatus(device: device)
        if status.commandFailed {
            latestStatus = "Travel Mode could not read the current Wi-Fi status."
            appendLog(latestStatus)
            return false
        }

        if let network = status.networkName, !network.isEmpty {
            fallbackArmed = true
            latestWiFiNetwork = network
            latestStatus = "Watching Wi-Fi '\(network)'; fallback will run if it disconnects."
            appendLog(latestStatus)
            return false
        }

        latestWiFiNetwork = "Not associated"
        latestStatus = "Travel Mode active; waiting for a connected Wi-Fi network to disconnect."
        appendLog(latestStatus)
        fallbackArmed = true
        return false
    }

    private func appendLog(_ message: String) {
        guard logs.last != message else {
            return
        }
        logs.append(message)
        if logs.count > 100 {
            logs.removeFirst(logs.count - 100)
        }
    }

    private func finishConfigurationSave() {
        isSavingConfiguration = false
        let waiters = saveCompletionWaiters
        saveCompletionWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
    }

    private func applySessionResult(_ result: TravelSessionTransitionResult) {
        sessionLifecycle = result.lifecycle
        isRunning = result.lifecycle == .active
        if result.error != nil {
            let safeError = safeSessionError(for: result.lifecycle)
            lastErrorMessage = safeError
            latestStatus = safeError
            appendLog(latestStatus)
        } else if result.warning != nil {
            let safeWarning = "Travel Mode completed with a warning."
            lastErrorMessage = nil
            latestStatus = safeWarning
            appendLog(safeWarning)
        } else {
            lastErrorMessage = nil
        }
        updateLifecyclePresentation()
    }

    private func safeSessionError(for lifecycle: TravelSessionLifecycle) -> String {
        switch lifecycle {
        case .cleanupRequired:
            return "Cleanup required: Travel Mode could not verify restoration. Retry Cleanup."
        case .preparing:
            return "Travel Mode could not finish preparing safely."
        case .active:
            return "Travel Mode reported an active-session problem."
        case .restoring:
            return "Travel Mode could not finish restoring safely."
        case .off:
            return "Travel Mode is off after a session operation failed."
        }
    }

    private func safeHandoffFailureMessage(for kind: HandoffFailureKind) -> String {
        switch kind {
        case .lidProviderFailed, .connectivityProviderFailed:
            return "iPhone internet handoff failed because network status is unavailable."
        case .wifiPowerCommandFailed, .associationCommandFailed:
            return "iPhone internet handoff could not complete the Wi-Fi change."
        case .reachabilityFailed, .partialConnectivity:
            return "The configured iPhone connected without verified internet access."
        case .staleSession, .cancelled:
            return "The iPhone internet handoff was cancelled safely."
        case .invalidConfiguration:
            return "The saved iPhone connection configuration is invalid."
        case .deadlineExceeded:
            return "iPhone internet handoff reached its retry time limit."
        }
    }

    private func updateLifecyclePresentation() {
        if startupRecoveryInProgress {
            lifecyclePresentation = .recovering
            return
        }
        if sessionLifecycle == .cleanupRequired {
            lifecyclePresentation = .cleanupRequired
            return
        }
        if cleanupOperation != nil || sessionLifecycle == .restoring {
            lifecyclePresentation = .restoring
            return
        }
        if activationInProgress || sessionLifecycle == .preparing {
            lifecyclePresentation = .preparing
            return
        }
        switch sessionLifecycle {
        case .off:
            lifecyclePresentation = .off
        case .preparing:
            lifecyclePresentation = .preparing
        case .active:
            lifecyclePresentation = .active
        case .restoring:
            lifecyclePresentation = .restoring
        case .cleanupRequired:
            lifecyclePresentation = .cleanupRequired
        }
    }
}
