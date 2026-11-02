import AppKit
import ApplicationServices
import Combine
import CodexTravelModeCore
import CodexTravelModeSleepLease
import Foundation

private struct ScenarioConfiguration {
    var baselineGate = false
    var acquireGate = false
    var leaseBoundaryGate = false
    var releaseGate = false
    var releaseFailures = 0
    var releaseFailureCategory = "command_failed"
    var releaseFailureDetail = "proof-injected cleanup failure"
    var seededRecovery = false
    var recoveryOperation = false
}

@MainActor
private final class LifecycleProofTerminationRecorder {
    private let trace: LifecycleProofTrace
    private(set) var initialDecisionCount = 0
    private(set) var deferredReplyCount = 0
    private(set) var lastDeferredReplyAllowed: Bool?

    init(trace: LifecycleProofTrace) {
        self.trace = trace
    }

    func observe(_ observation: AppDelegate.TerminationObservation) {
        switch observation {
        case .initialDecision(let decision):
            initialDecisionCount += 1
            trace.record("termination_records", [
                "kind": "initial_decision",
                "decision": terminationName(decision),
            ])
        case .deferredReply(let allowed):
            deferredReplyCount += 1
            lastDeferredReplyAllowed = allowed
            trace.record("termination_records", [
                "kind": "deferred_reply",
                "outcome": allowed ? "allow" : "cancel",
            ])
        }
    }
}

@MainActor
private final class LifecycleScenarioHarness {
    let arguments: LifecycleProofArguments
    let trace: LifecycleProofTrace
    let journalStore: LifecycleProofJournalStore
    let leaseClient: LifecycleProofLeaseClient
    let appState: TravelModeAppState
    let appDelegate: AppDelegate
    let terminationRecorder: LifecycleProofTerminationRecorder
    private(set) var statusController: StatusBarController!
    let baselineGate: LifecycleProofGate?
    let acquireGate: LifecycleProofGate?
    let boundaryGate: LifecycleProofGate?
    let releaseGate: LifecycleProofGate?

    private var observations: [AnyCancellable] = []
    private var observedActivationTask = false

    static func make(
        arguments: LifecycleProofArguments,
        configuration: ScenarioConfiguration
    ) async throws -> LifecycleScenarioHarness {
        let trace = try LifecycleProofTrace(arguments: arguments)
        trace.record("input_events", [
            "kind": "app_launch", "source": "native_process_entrypoint",
        ])
        let baselineGate = configuration.baselineGate ? LifecycleProofGate() : nil
        let acquireGate = configuration.acquireGate ? LifecycleProofGate() : nil
        let boundaryGate = configuration.leaseBoundaryGate ? LifecycleProofGate() : nil
        let releaseGate = configuration.releaseGate ? LifecycleProofGate() : nil
        let journalURL = arguments.fragmentURL.deletingLastPathComponent()
            .appendingPathComponent("\(arguments.scenario)-travel-session-journal.json")
        let journalStore = LifecycleProofJournalStore(fileURL: journalURL, trace: trace)
        let system = LifecycleProofSystem(trace: trace, baselineGate: baselineGate)
        let leaseClient = LifecycleProofLeaseClient(
            trace: trace,
            acquireGate: acquireGate,
            releaseGate: releaseGate,
            releaseFailures: configuration.releaseFailures,
            releaseFailureCategory: configuration.releaseFailureCategory,
            releaseFailureDetail: configuration.releaseFailureDetail,
            cleanupOperation: configuration.recoveryOperation ? "recover" : "cleanup"
        )
        let observer = LifecycleProofBoundaryObserver(
            trace: trace,
            heldBoundary: configuration.leaseBoundaryGate ? .leaseAcquired : nil,
            gate: boundaryGate
        )
        let coordinator = TravelSessionCoordinator(
            journalStore: journalStore,
            system: system,
            leaseClient: leaseClient,
            observer: observer,
            associationRestoreTimeout: .seconds(1)
        )
        if configuration.seededRecovery {
            try await seedRecovery(journalStore: journalStore, leaseClient: leaseClient)
        }
        let gateway = LifecycleProofGateway(trace: trace)
        let appState = TravelModeAppState(
            gateway: gateway,
            engine: .production(),
            settingsStore: try LifecycleProofSettingsStore(),
            wifiDiscovery: LifecycleProofDiscovery(),
            sessionManager: coordinator
        )
        let terminationRecorder = LifecycleProofTerminationRecorder(trace: trace)
        let appDelegate = AppDelegate(
            appState: appState,
            terminationObserver: terminationRecorder.observe
        )
        let harness = LifecycleScenarioHarness(
            arguments: arguments,
            trace: trace,
            journalStore: journalStore,
            leaseClient: leaseClient,
            appState: appState,
            appDelegate: appDelegate,
            terminationRecorder: terminationRecorder,
            baselineGate: baselineGate,
            acquireGate: acquireGate,
            boundaryGate: boundaryGate,
            releaseGate: releaseGate
        )
        harness.beginObserving()
        NSApplication.shared.delegate = appDelegate
        appDelegate.applicationDidFinishLaunching(
            Notification(name: NSApplication.didFinishLaunchingNotification)
        )
        guard let statusController = appDelegate.statusBarController else {
            throw LifecycleProofError.rendering("AppDelegate omitted the production status item")
        }
        harness.statusController = statusController
        await journalStore.recordCurrent(kind: "launch_readback")
        trace.record("process_records", [
            "state": "alive", "observer_pid": Int(ProcessInfo.processInfo.processIdentifier),
            "observed_pid": Int(ProcessInfo.processInfo.processIdentifier),
        ])
        return harness
    }

    private init(
        arguments: LifecycleProofArguments,
        trace: LifecycleProofTrace,
        journalStore: LifecycleProofJournalStore,
        leaseClient: LifecycleProofLeaseClient,
        appState: TravelModeAppState,
        appDelegate: AppDelegate,
        terminationRecorder: LifecycleProofTerminationRecorder,
        baselineGate: LifecycleProofGate?,
        acquireGate: LifecycleProofGate?,
        boundaryGate: LifecycleProofGate?,
        releaseGate: LifecycleProofGate?
    ) {
        self.arguments = arguments
        self.trace = trace
        self.journalStore = journalStore
        self.leaseClient = leaseClient
        self.appState = appState
        self.appDelegate = appDelegate
        self.terminationRecorder = terminationRecorder
        self.baselineGate = baselineGate
        self.acquireGate = acquireGate
        self.boundaryGate = boundaryGate
        self.releaseGate = releaseGate
        self.statusController = nil
    }

    private func beginObserving() {
        appState.$lifecyclePresentation
            .removeDuplicates()
            .sink { [trace] presentation in
                trace.record("lifecycle_publications", ["state": stateName(presentation)])
            }
            .store(in: &observations)
        appState.$hasPendingQuitIntent
            .removeDuplicates()
            .sink { [trace] value in
                trace.record("pending_quit_publications", ["value": value])
            }
            .store(in: &observations)
        appState.$activationTaskInFlight
            .removeDuplicates()
            .sink { [weak self, trace] inFlight in
                if inFlight {
                    self?.observedActivationTask = true
                    trace.record("activation_tasks", [
                        "state": "in_flight", "source": "production_activation_task",
                    ])
                } else if self?.observedActivationTask == true {
                    trace.record("activation_tasks", [
                        "state": "resolved", "source": "production_activation_task",
                    ])
                    self?.observedActivationTask = false
                } else {
                    trace.record("activation_tasks", [
                        "state": "idle", "source": "production_activation_task",
                    ])
                }
            }
            .store(in: &observations)
    }

    func waitFor(_ description: String, _ predicate: @escaping @MainActor () -> Bool) async throws {
        for _ in 0..<500 {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw LifecycleProofError.timeout(description)
    }

    func waitForPresentation(_ presentation: TravelModeLifecyclePresentation) async throws {
        try await waitFor("lifecycle \(stateName(presentation))") {
            self.appState.lifecyclePresentation == presentation
        }
    }

    func waitForCleanOff() async throws {
        try await waitFor("verified clean Off") { self.appState.isCleanlyOffForTermination }
    }

    func openPopover() async throws {
        try await waitFor("production status button to attach") {
            guard let button = self.statusController.statusButton,
                  let window = button.window else { return false }
            return window.windowNumber > 0
        }
        try await Task.sleep(for: .milliseconds(100))
        for _ in 0..<3 where !statusController.isPopoverShown {
            statusController.togglePopover()
            for _ in 0..<100 where !statusController.isPopoverShown {
                try await Task.sleep(for: .milliseconds(10))
            }
            if !statusController.isPopoverShown {
                statusController.dismissPopover()
                try await Task.sleep(for: .milliseconds(100))
            }
        }
        guard statusController.isPopoverShown,
              statusController.popoverContentView?.window?.isVisible == true else {
            throw LifecycleProofError.timeout("production popover to open")
        }
        try await Task.sleep(for: .milliseconds(120))
        activateSelfAccessibilityHierarchy()
        try await Task.sleep(for: .milliseconds(80))
        let (root, window) = try actualPopoverSurface()
        let button = try actualStatusButton()
        trace.record("popover_records", [
            "state": "shown",
            "popover_content_view_id": objectIdentity(root),
            "popover_window_number": window.windowNumber,
            "popover_window_visible": window.isVisible,
            "status_button_object_id": objectIdentity(button),
        ])
    }

    func dismissPopover() async throws {
        let root = try actualPopoverRootView()
        let windowNumber = root.window?.windowNumber ?? 0
        let button = try actualStatusButton()
        statusController.dismissPopover()
        try await waitFor("production popover to dismiss") {
            !self.statusController.isPopoverShown
                && self.statusController.popoverContentView?.window?.isVisible != true
        }
        trace.record("popover_records", [
            "state": "hidden",
            "popover_content_view_id": objectIdentity(root),
            "popover_window_number": windowNumber,
            "popover_window_visible": root.window?.isVisible == true,
            "status_button_object_id": objectIdentity(button),
        ])
        try recordStatus(popoverState: "hidden")
    }

    func click(identifier: String, kind: String) async throws {
        try await openPopover()
        let (root, window) = try actualPopoverSurface()
        guard let element = findAccessibilityElement(
            in: root,
            identifier: identifier,
            label: nil
        ) else { throw LifecycleProofError.missingControl(identifier) }
        trace.record("input_events", [
            "kind": kind, "source": "native_accessibility_press", "identifier": identifier,
            "popover_content_view_id": objectIdentity(root),
            "control_object_id": objectIdentity(element),
            "control_window_number": window.windowNumber,
        ])
        try press(element)
        try await Task.sleep(for: .milliseconds(100))
    }

    func clickAlertButton(label: String, kind: String) async throws {
        let popoverRoot = try actualPopoverRootView()
        for _ in 0..<100 {
            for window in NSApplication.shared.windows where window.isVisible {
                if let root = window.contentView,
                   let element = findAccessibilityElement(in: root, identifier: nil, label: label) {
                    trace.record("input_events", [
                        "kind": kind, "source": "native_accessibility_press", "label": label,
                        "popover_content_view_id": objectIdentity(popoverRoot),
                        "control_object_id": objectIdentity(element),
                        "control_window_number": window.windowNumber,
                    ])
                    try press(element)
                    try await Task.sleep(for: .milliseconds(100))
                    return
                }
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw LifecycleProofError.missingControl(label)
    }

    func waitForPopoverControl(identifier: String) async throws {
        try await openPopover()
        for _ in 0..<100 {
            if let root = statusController.popoverContentView,
               findAccessibilityElement(in: root, identifier: identifier, label: nil) != nil {
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw LifecycleProofError.missingControl(identifier)
    }

    func startThroughProductionControl() async throws {
        try await click(identifier: "travel.primary-action", kind: "start")
        try await waitForPopoverControl(identifier: "travel.surface.start-confirmation")
        try await click(identifier: "travel.primary-action", kind: "continue_start")
    }

    func requestTermination(
        kind: String = "quit",
        requireDelegateCallback: Bool = true
    ) async throws {
        trace.record("input_events", ["kind": kind, "source": "appkit_termination_request"])
        trace.record("termination_records", ["kind": "request", "delivery": "external_appkit"])
        let previousDecisionCount = terminationRecorder.initialDecisionCount
        guard await requestExternalTermination() else {
            throw LifecycleProofError.rendering("AppKit rejected the external termination request")
        }
        if requireDelegateCallback {
            try await waitFor("AppDelegate initial termination decision") {
                self.terminationRecorder.initialDecisionCount > previousDecisionCount
            }
        } else {
            for _ in 0..<25 where terminationRecorder.initialDecisionCount == previousDecisionCount {
                try await Task.sleep(for: .milliseconds(10))
            }
        }
    }

    private func requestExternalTermination() async -> Bool {
        let pid = ProcessInfo.processInfo.processIdentifier
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let submitted = NSRunningApplication(processIdentifier: pid)?.terminate() ?? false
                continuation.resume(returning: submitted)
            }
        }
    }

    func snapshot(capturePNG: Bool = false, stateOverride: String? = nil) async throws {
        try await openPopover()
        try await Task.sleep(for: .milliseconds(80))
        let state = stateOverride ?? stateName(appState.lifecyclePresentation)
        let snapshotID = UUID().uuidString
        let (root, window) = try actualPopoverSurface()
        let button = try actualStatusButton()
        root.layoutSubtreeIfNeeded()
        let elements = renderedSnapshot(from: root)
        trace.record("accessibility_snapshots", [
            "snapshot_id": snapshotID, "state": state, "elements": elements,
            "content_frame": [
                "x": Int(window.frame.origin.x.rounded()),
                "y": Int(window.frame.origin.y.rounded()),
                "width": Int(window.contentLayoutRect.width.rounded()),
                "height": Int(window.contentLayoutRect.height.rounded()),
            ],
            "popover_content_view_id": objectIdentity(root),
            "popover_window_number": window.windowNumber,
            "popover_window_visible": window.isVisible,
            "status_button_object_id": objectIdentity(button),
        ])
        try recordStatus(popoverState: "shown", state: state)
        if capturePNG {
            let url = arguments.screenshotDirectory
                .appendingPathComponent(screenshotFileName(state: state))
            try capture(window, to: url)
            trace.record("screenshots", [
                "state": state, "path": url.path,
                "producer_pid": Int(ProcessInfo.processInfo.processIdentifier),
                "accessibility_snapshot_id": snapshotID,
                "popover_content_view_id": objectIdentity(root),
                "popover_window_number": window.windowNumber,
            ])
        }
        await journalStore.recordCurrent(kind: "ui_snapshot")
    }

    func recordStatus(popoverState: String, state: String? = nil) throws {
        let presentation = state ?? stateName(appState.lifecyclePresentation)
        let button = try actualStatusButton()
        guard let image = button.image,
              let label = button.accessibilityLabel(),
              let symbol = image.accessibilityDescription,
              let tint = button.contentTintColor,
              let window = button.window else {
            throw LifecycleProofError.rendering("the production status button is incomplete")
        }
        trace.record("status_item_records", [
            "state": presentation,
            "label": label,
            "symbol": symbol,
            "tint": tintName(tint),
            "tool_tip": button.toolTip ?? NSNull(),
            "popover_state": popoverState,
            "button_object_id": objectIdentity(button),
            "image_object_id": objectIdentity(image),
            "button_window_number": window.windowNumber,
        ])
    }

    func markReadyAndRemainAlive() async throws -> Never {
        try await checkpointExternalLiveness()
        while true { try await Task.sleep(for: .seconds(30)) }
    }

    func checkpointExternalLiveness() async throws {
        let checkpointSequence = trace.record("process_records", [
            "state": "awaiting_driver_liveness",
            "observer_pid": Int(getpid()),
            "observed_pid": Int(getpid()),
        ])
        try trace.writeMarker(to: arguments.markerURL)
        try await waitFor("driver liveness receipt") {
            FileManager.default.fileExists(atPath: self.arguments.livenessReceiptURL.path)
        }
        let data = try Data(contentsOf: arguments.livenessReceiptURL)
        guard let receipt = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              receipt["state"] as? String == "driver_observed_alive",
              (receipt["observed_pid"] as? NSNumber)?.int32Value == getpid(),
              let observerPID = (receipt["observer_pid"] as? NSNumber)?.intValue else {
            throw LifecycleProofError.rendering("driver liveness receipt is invalid")
        }
        trace.record("process_records", [
            "state": "driver_observed_alive",
            "observer_pid": observerPID,
            "observed_pid": Int(getpid()),
            "checkpoint_sequence": checkpointSequence,
        ])
    }

    private func actualPopoverRootView() throws -> NSView {
        guard let root = statusController.popoverContentView else {
            throw LifecycleProofError.rendering("the production popover has no content view")
        }
        return root
    }

    private func actualPopoverSurface() throws -> (NSView, NSWindow) {
        let contentView = try actualPopoverRootView()
        guard statusController.isPopoverShown,
              let window = contentView.window,
              window.isVisible else {
            throw LifecycleProofError.rendering("the production popover window is not visible")
        }
        return (window.contentView ?? contentView, window)
    }

    private func actualStatusButton() throws -> NSStatusBarButton {
        guard let button = statusController.statusButton else {
            throw LifecycleProofError.rendering("the production status item has no button")
        }
        return button
    }
}

@main
struct LifecycleProofMain {
    @MainActor
    static func main() {
        do {
            let arguments = try LifecycleProofArguments.parse(CommandLine.arguments)
            let application = NSApplication.shared
            application.setActivationPolicy(.accessory)
            let delegate = LifecycleProofBootstrapDelegate(arguments: arguments)
            application.delegate = delegate
            application.run()
            withExtendedLifetime(delegate) {}
        } catch {
            FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8))
            Darwin.exit(1)
        }
    }

    @MainActor
    static func run(_ arguments: LifecycleProofArguments) async throws {
        let configuration = configuration(for: arguments.scenario)
        let harness = try await LifecycleScenarioHarness.make(
            arguments: arguments,
            configuration: configuration
        )

        if try await runLaunchScenario(arguments, harness: harness) {
            // Handled by the launch/Preparing scenario group.
        } else if try await runActiveScenario(arguments, harness: harness) {
            // Handled by the Active/Stop/Quit scenario group.
        } else if try await runRecoveryScenario(arguments, harness: harness) {
            // Handled by the startup-recovery scenario group.
        } else {
            throw LifecycleProofError.unknownScenario(arguments.scenario)
        }

        harness.trace.record("process_records", [
            "state": "alive", "observer_pid": Int(getpid()), "observed_pid": Int(getpid()),
        ])
        try await Task.sleep(for: .milliseconds(120))
    }

    @MainActor
    private static func runLaunchScenario(
        _ arguments: LifecycleProofArguments,
        harness: LifecycleScenarioHarness
    ) async throws -> Bool {
        switch arguments.scenario {
        case "clean-off-quit":
            try await harness.waitForCleanOff()
            try await harness.snapshot(capturePNG: true)
            try await harness.requestTermination()

        case "pre-start-cancel":
            try await harness.waitForCleanOff()
            try await harness.click(identifier: "travel.primary-action", kind: "start_notice")
            try await harness.waitForPopoverControl(
                identifier: "travel.surface.start-confirmation"
            )
            try await harness.snapshot(capturePNG: true, stateOverride: "start_confirmation")
            try await harness.click(identifier: "travel.cancel-start", kind: "cancel_start_notice")
            try await harness.waitForCleanOff()
            await harness.journalStore.recordCurrent(kind: "after_notice_cancel")
            try await harness.snapshot()

        case "preparing-quit-before-journal", "preparing-quit-after-journal",
             "preparing-quit-after-lease":
            try await harness.waitForCleanOff()
            try await harness.startThroughProductionControl()
            try await harness.waitForPresentation(.preparing)
            try await harness.snapshot(
                capturePNG: arguments.scenario == "preparing-quit-before-journal"
            )
            try await harness.requestTermination()
            try await harness.waitFor("terminal preparing compensation") {
                [.off, .cleanupRequired].contains(harness.appState.lifecyclePresentation)
            }
            try await harness.waitFor("production activation task to settle") {
                !harness.appState.activationTaskInFlight
            }
            await harness.journalStore.recordCurrent(kind: "after_preparing_compensation")

        case "preparing-quit-after-lease-failure":
            try await harness.waitForCleanOff()
            try await harness.startThroughProductionControl()
            try await harness.waitForPresentation(.preparing)
            try await harness.snapshot()
            try await harness.requestTermination()
            try await harness.waitForPresentation(.cleanupRequired)
            try await harness.waitFor("failed activation task to settle") {
                !harness.appState.activationTaskInFlight
            }
            try await harness.snapshot()
            try await harness.markReadyAndRemainAlive()
        default:
            return false
        }
        return true
    }

    @MainActor
    private static func runActiveScenario(
        _ arguments: LifecycleProofArguments,
        harness: LifecycleScenarioHarness
    ) async throws -> Bool {
        switch arguments.scenario {
        case "active-dismiss-reopen":
            try await startActive(harness)
            try await harness.snapshot(capturePNG: true)
            try await harness.dismissPopover()
            await harness.journalStore.recordCurrent(kind: "dismissed_active")
            try await harness.openPopover()
            try await harness.snapshot()

        case "stop-success":
            try await startActive(harness)
            try await harness.click(identifier: "travel.primary-action", kind: "stop_restore")
            try await harness.waitForPresentation(.restoring)
            try await harness.snapshot(capturePNG: true)
            await harness.releaseGate?.release()
            try await harness.waitForCleanOff()
            await harness.journalStore.recordCurrent(kind: "after_stop_success")

        case "stop-failure-retry-success":
            try await startActive(harness)
            try await harness.click(identifier: "travel.primary-action", kind: "stop_restore")
            try await harness.waitForPresentation(.cleanupRequired)
            try await harness.snapshot(capturePNG: true)
            try await harness.click(identifier: "travel.primary-action", kind: "retry_cleanup")
            try await harness.waitForCleanOff()
            await harness.journalStore.recordCurrent(kind: "after_stop_retry")

        case "quit-failure-retry-success":
            try await startActive(harness)
            try await harness.requestTermination()
            try await harness.waitForPresentation(.cleanupRequired)
            try await harness.waitFor("failed Quit deferred cancel") {
                harness.terminationRecorder.lastDeferredReplyAllowed == false
            }
            try await harness.snapshot()
            try await harness.requestTermination(kind: "quit_after_cleanup_required")
            try await harness.checkpointExternalLiveness()
            try await harness.click(
                identifier: "travel.primary-action",
                kind: "retry_cleanup_and_quit"
            )
            try await harness.waitForCleanOff()

        case "repeated-quit-delayed-success", "repeated-quit-failure":
            try await startActive(harness)
            try await harness.snapshot()
            try await harness.requestTermination(kind: "quit_1")
            try await harness.requestTermination(
                kind: "quit_2",
                requireDelegateCallback: false
            )
            try await harness.waitForPresentation(.restoring)
            harness.trace.record("process_records", [
                "state": "alive", "observer_pid": Int(getpid()), "observed_pid": Int(getpid()),
            ])
            await harness.releaseGate?.release()
            if arguments.scenario == "repeated-quit-delayed-success" {
                try await harness.waitForCleanOff()
            } else {
                try await harness.waitForPresentation(.cleanupRequired)
                try await harness.snapshot()
                try await harness.markReadyAndRemainAlive()
            }
        default:
            return false
        }
        return true
    }

    @MainActor
    private static func runRecoveryScenario(
        _ arguments: LifecycleProofArguments,
        harness: LifecycleScenarioHarness
    ) async throws -> Bool {
        switch arguments.scenario {
        case "startup-recovery-success":
            try await harness.waitForPresentation(.recovering)
            try await harness.snapshot(capturePNG: true)
            await harness.releaseGate?.release()
            try await harness.waitForCleanOff()

        case "startup-recovery-failure":
            try await harness.waitForPresentation(.cleanupRequired)
            try await harness.snapshot()
            try await harness.markReadyAndRemainAlive()

        case "quit-during-startup-recovery":
            try await harness.waitForPresentation(.recovering)
            try await harness.snapshot()
            try await harness.requestTermination()
            await harness.releaseGate?.release()
            try await harness.waitForCleanOff()

        case "quit-during-startup-recovery-failure":
            try await harness.waitForPresentation(.recovering)
            try await harness.snapshot()
            try await harness.requestTermination()
            await harness.releaseGate?.release()
            try await harness.waitForPresentation(.cleanupRequired)
            try await harness.snapshot()
            try await harness.markReadyAndRemainAlive()
        default:
            return false
        }
        return true
    }

    @MainActor
    private static func startActive(_ harness: LifecycleScenarioHarness) async throws {
        try await harness.waitForCleanOff()
        try await harness.startThroughProductionControl()
        try await harness.waitForPresentation(.active)
        try await harness.waitFor("production activation task to settle") {
            !harness.appState.activationTaskInFlight
        }
        await harness.journalStore.recordCurrent(kind: "active_readback")
    }

    private static func configuration(for scenario: String) -> ScenarioConfiguration {
        switch scenario {
        case "preparing-quit-before-journal":
            ScenarioConfiguration(baselineGate: true)
        case "preparing-quit-after-journal":
            ScenarioConfiguration(acquireGate: true)
        case "preparing-quit-after-lease":
            ScenarioConfiguration(leaseBoundaryGate: true)
        case "preparing-quit-after-lease-failure":
            ScenarioConfiguration(leaseBoundaryGate: true, releaseFailures: 1)
        case "stop-success", "repeated-quit-delayed-success", "repeated-quit-failure",
             "startup-recovery-success", "quit-during-startup-recovery",
             "quit-during-startup-recovery-failure":
            ScenarioConfiguration(
                releaseGate: true,
                releaseFailures: [
                    "repeated-quit-failure", "quit-during-startup-recovery-failure",
                ].contains(scenario) ? 1 : 0,
                seededRecovery: scenario.hasPrefix("startup-") || scenario.hasPrefix("quit-during"),
                recoveryOperation: scenario.hasPrefix("startup-") || scenario.hasPrefix("quit-during")
            )
        case "stop-failure-retry-success":
            ScenarioConfiguration(releaseFailures: 1)
        case "quit-failure-retry-success":
            ScenarioConfiguration(
                releaseFailures: 1,
                releaseFailureCategory: "authorization_cancelled",
                releaseFailureDetail: lifecycleProofSensitiveFailure
            )
        case "startup-recovery-failure":
            ScenarioConfiguration(releaseFailures: 1, seededRecovery: true, recoveryOperation: true)
        default:
            ScenarioConfiguration()
        }
    }
}

@MainActor
private final class LifecycleProofBootstrapDelegate: NSObject, NSApplicationDelegate {
    private let arguments: LifecycleProofArguments

    init(arguments: LifecycleProofArguments) {
        self.arguments = arguments
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        Task { @MainActor in
            do {
                try await LifecycleProofMain.run(arguments)
                if !isTerminationScenario(arguments.scenario) {
                    NSApplication.shared.stop(nil)
                    NSApplication.shared.postEvent(
                        NSEvent.otherEvent(
                            with: .applicationDefined,
                            location: .zero,
                            modifierFlags: [],
                            timestamp: 0,
                            windowNumber: 0,
                            context: nil,
                            subtype: 0,
                            data1: 0,
                            data2: 0
                        )!,
                        atStart: false
                    )
                }
            } catch {
                FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8))
                Darwin.exit(1)
            }
        }
    }
}

private func isTerminationScenario(_ scenario: String) -> Bool {
    switch scenario {
    case "clean-off-quit",
         "preparing-quit-before-journal",
         "preparing-quit-after-journal",
         "preparing-quit-after-lease",
         "preparing-quit-after-lease-failure",
         "quit-failure-retry-success",
         "repeated-quit-delayed-success",
         "repeated-quit-failure",
         "quit-during-startup-recovery",
         "quit-during-startup-recovery-failure":
        true
    default:
        false
    }
}

private func seedRecovery(
    journalStore: LifecycleProofJournalStore,
    leaseClient: LifecycleProofLeaseClient
) async throws {
    var journal = TravelSessionJournal(
        sessionID: "lifecycle-proof-recovery-session",
        wifiBaseline: TravelWiFiBaseline(
            device: "en0", powerEnabled: true, associatedSSID: "Office"
        ),
        leaseRequestID: "lifecycle-proof-recovery-request"
    )
    journal = try await journalStore.create(journal)
    let binding = SleepOverrideLeaseBinding(
        sessionID: journal.sessionID,
        requestID: journal.leaseRequestID,
        leaseID: "lifecycle-proof-recovery-lease",
        generation: "lifecycle-proof-recovery-generation"
    )
    journal.leaseBinding = binding
    journal.leaseStatus = .active
    journal.phase = .active
    _ = try await journalStore.update(journal, expectedRevision: journal.revision)
    await leaseClient.seed(binding: binding)
}

private func stateName(_ presentation: TravelModeLifecyclePresentation) -> String {
    switch presentation {
    case .off: "off"
    case .preparing: "preparing"
    case .active: "active"
    case .restoring: "restoring"
    case .recovering: "recovery"
    case .cleanupRequired: "cleanup_required"
    }
}

private func terminationName(_ reply: NSApplication.TerminateReply) -> String {
    switch reply {
    case .terminateNow: "terminate_now"
    case .terminateCancel: "terminate_cancel"
    case .terminateLater: "terminate_later"
    @unknown default: "unknown"
    }
}

private func tintName(_ color: NSColor) -> String {
    if color == .systemOrange { return "orange" }
    if color == .systemGreen { return "green" }
    if color == .systemRed { return "red" }
    if color == .secondaryLabelColor { return "secondary" }
    return color.description
}

private func screenshotFileName(state: String) -> String {
    if state == "start_confirmation" { return "start-confirmation.png" }
    return state == "cleanup_required" ? "cleanup-required.png" : "\(state).png"
}

private func capture(_ window: NSWindow, to url: URL) throws {
    window.displayIfNeeded()
    guard window.windowNumber > 0,
          let contentView = window.contentView else {
        throw LifecycleProofError.rendering("the real popover window has no content view")
    }
    contentView.layoutSubtreeIfNeeded()
    let bounds = contentView.bounds
    let scale = max(window.backingScaleFactor, 1)
    guard bounds.width > 100, bounds.height > 100,
          let bitmap = NSBitmapImageRep(
              bitmapDataPlanes: nil,
              pixelsWide: Int((bounds.width * scale).rounded()),
              pixelsHigh: Int((bounds.height * scale).rounded()),
              bitsPerSample: 8,
              samplesPerPixel: 4,
              hasAlpha: true,
              isPlanar: false,
              colorSpaceName: .deviceRGB,
              bytesPerRow: 0,
              bitsPerPixel: 0
          ),
          let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
        throw LifecycleProofError.rendering("the real popover window has no renderable bitmap")
    }
    bitmap.size = bounds.size
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    context.cgContext.scaleBy(x: scale, y: scale)
    NSColor.windowBackgroundColor.setFill()
    bounds.fill()
    contentView.displayIgnoringOpacity(bounds, in: context)
    context.flushGraphics()
    NSGraphicsContext.restoreGraphicsState()
    guard bitmap.pixelsWide > 100, bitmap.pixelsHigh > 100,
          let png = bitmap.representation(using: .png, properties: [:]) else {
        throw LifecycleProofError.rendering("AppKit could not encode the popover as PNG")
    }
    try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    try png.write(to: url, options: .atomic)
}

private func objectIdentity(_ object: AnyObject) -> String {
    String(UInt(bitPattern: Unmanaged.passUnretained(object).toOpaque()))
}

private func renderedSnapshot(from root: NSView) -> [[String: Any]] {
    accessibilityObjects(from: root).compactMap { object in
        let role = renderedString(accessibilityValue("accessibilityRole", of: object))
            ?? renderedString(accessibilityAttribute("AXRole", of: object))
            ?? NSAccessibility.Role.unknown.rawValue
        let identifier = nonempty(
            renderedString(accessibilityValue("accessibilityIdentifier", of: object))
                ?? renderedString(accessibilityAttribute("AXIdentifier", of: object))
        )
        let rawLabel = nonempty(
            renderedString(accessibilityValue("accessibilityLabel", of: object))
                ?? renderedString(accessibilityAttribute("AXDescription", of: object))
        )
        let rawValue = nonempty(
            renderedString(accessibilityValue("accessibilityValue", of: object))
                ?? renderedString(accessibilityAttribute("AXValue", of: object))
        )
        guard identifier != nil || rawLabel != nil || rawValue != nil
                || role != NSAccessibility.Role.unknown.rawValue else { return nil }
        let frame = accessibilityFrame(of: object)
        let mergedLabel: Any = (rawLabel ?? rawValue).map { $0 as Any } ?? NSNull()
        return [
            "identifier": identifier ?? NSNull(),
            "role": role,
            "label": mergedLabel,
            "value": rawValue ?? NSNull(),
            "enabled": accessibilityBool("accessibilityEnabled", of: object),
            "frame": [
                "x": Int(frame.origin.x.rounded()), "y": Int(frame.origin.y.rounded()),
                "width": Int(frame.width.rounded()), "height": Int(frame.height.rounded()),
            ],
        ]
    }
}

private func findAccessibilityElement(
    in root: NSView,
    identifier: String?,
    label: String?
) -> NSObject? {
    accessibilityObjects(from: root).first { object in
        let observedIdentifier = renderedString(
            accessibilityValue("accessibilityIdentifier", of: object)
                ?? accessibilityAttribute("AXIdentifier", of: object)
        )
        let observedLabel = renderedString(
            accessibilityValue("accessibilityLabel", of: object)
                ?? accessibilityAttribute("AXDescription", of: object)
                ?? accessibilityValue("accessibilityValue", of: object)
                ?? accessibilityAttribute("AXValue", of: object)
        )
        return (identifier == nil || observedIdentifier == identifier)
            && (label == nil || observedLabel == label)
    }
}

private func press(_ object: NSObject) throws {
    if let button = object as? NSButton {
        button.performClick(nil)
        return
    }
    let selector = NSSelectorFromString("accessibilityPerformPress")
    guard object.responds(to: selector) else {
        throw LifecycleProofError.rendering("accessibility element cannot perform its press action")
    }
    _ = object.perform(selector)
}

private func accessibilityObjects(from root: NSView) -> [NSObject] {
    var result: [NSObject] = []
    var visited: Set<ObjectIdentifier> = []
    func visit(_ value: Any) {
        guard let object = value as? NSObject,
              visited.insert(ObjectIdentifier(object)).inserted else { return }
        result.append(object)
        let children = accessibilityArray("accessibilityChildren", of: object)
            + (accessibilityAttribute("AXChildren", of: object) as? [Any] ?? [])
            + accessibilityArray("accessibilityChildrenInNavigationOrder", of: object)
            + accessibilityArray("accessibilityContents", of: object)
        for child in children { visit(child) }
        for child in NSAccessibility.unignoredChildren(from: children) { visit(child) }
        if let view = object as? NSView { view.subviews.forEach(visit) }
    }
    visit(root)
    return result
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
        ? "isAccessibilityEnabled" : "isAccessibilityProtectedContent"
    guard object.responds(to: NSSelectorFromString(getter)) else { return false }
    return (object.value(forKey: key) as? NSNumber)?.boolValue
        ?? (accessibilityAttribute("AXEnabled", of: object) as? NSNumber)?.boolValue
        ?? false
}
private func accessibilityFrame(of object: NSObject) -> NSRect {
    if let view = object as? NSView { return view.accessibilityFrame() }
    if let element = object as? NSAccessibilityElement { return element.accessibilityFrame() }
    return .zero
}
private func renderedString(_ value: Any?) -> String? {
    switch value {
    case let string as String: string
    case let attributed as NSAttributedString: attributed.string
    case let number as NSNumber: number.stringValue
    default: nil
    }
}
private func nonempty(_ value: String?) -> String? {
    guard let value, !value.isEmpty else { return nil }
    return value
}

private func activateSelfAccessibilityHierarchy() {
    let applicationElement = AXUIElementCreateApplication(
        ProcessInfo.processInfo.processIdentifier
    )
    var ignored: CFTypeRef?
    _ = AXUIElementCopyAttributeValue(
        applicationElement,
        kAXChildrenAttribute as CFString,
        &ignored
    )
}
