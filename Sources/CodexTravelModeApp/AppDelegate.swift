import AppKit
import CodexTravelModeCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    enum TerminationCoordinatorState: String {
        case idle
        case awaitingCleanup
        case approved
    }

    enum TerminationObservation {
        case initialDecision(NSApplication.TerminateReply)
        case deferredReply(Bool)
    }

    let appState: TravelModeAppState
    private(set) var statusBarController: StatusBarController?
    private(set) var terminationCoordinatorState = TerminationCoordinatorState.idle
    private var deferredTerminationSender: NSApplication?
    private let terminationObserver: ((TerminationObservation) -> Void)?

    override init() {
        appState = AppRuntime.shared.appState
        terminationObserver = nil
        super.init()
    }

    init(
        appState: TravelModeAppState,
        terminationObserver: ((TerminationObservation) -> Void)? = nil
    ) {
        self.appState = appState
        self.terminationObserver = terminationObserver
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        statusBarController = StatusBarController(
            appState: appState,
            onRetryCleanupAndQuit: { [weak self] in
                self?.retryCleanupAndQuit()
            }
        )
        Task {
            await appState.recoverPreviousSessionIfNeeded()
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        switch terminationCoordinatorState {
        case .approved:
            return observeInitialDecision(.terminateNow)
        case .awaitingCleanup:
            deferredTerminationSender = sender
            return observeInitialDecision(.terminateLater)
        case .idle:
            guard !(appState.hasPendingQuitIntent
                    && appState.lifecyclePresentation == .cleanupRequired) else {
                return observeInitialDecision(.terminateCancel)
            }
            guard !appState.isCleanlyOffForTermination else {
                return observeInitialDecision(.terminateNow)
            }
            terminationCoordinatorState = .awaitingCleanup
            deferredTerminationSender = sender
            Task {
                let canTerminate = await appState.requestQuit()
                completeCleanup(canTerminate: canTerminate, requestTerminationIfNeeded: false)
            }
            return observeInitialDecision(.terminateLater)
        }
    }

    func retryCleanupAndQuit() {
        guard terminationCoordinatorState == .idle,
              appState.hasPendingQuitIntent,
              appState.lifecyclePresentation == .cleanupRequired else { return }
        terminationCoordinatorState = .awaitingCleanup
        deferredTerminationSender = nil
        Task {
            let canTerminate = await appState.retryCleanup()
            completeCleanup(canTerminate: canTerminate, requestTerminationIfNeeded: true)
        }
    }

    private func completeCleanup(
        canTerminate: Bool,
        requestTerminationIfNeeded: Bool
    ) {
        terminationCoordinatorState = canTerminate ? .approved : .idle
        if let sender = deferredTerminationSender {
            deferredTerminationSender = nil
            terminationObserver?(.deferredReply(canTerminate))
            sender.reply(toApplicationShouldTerminate: canTerminate)
        } else if canTerminate, requestTerminationIfNeeded {
            NSApp.terminate(nil)
        }
    }

    private func observeInitialDecision(
        _ decision: NSApplication.TerminateReply
    ) -> NSApplication.TerminateReply {
        terminationObserver?(.initialDecision(decision))
        return decision
    }
}
