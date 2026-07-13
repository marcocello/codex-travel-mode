import AppKit
import CodexTravelModeCore
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let appState = AppRuntime.shared.appState
    private var statusBarController: StatusBarController?
    private var isTerminatingAfterCleanup = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        statusBarController = StatusBarController(appState: appState)
        Task {
            await appState.recoverPreviousSessionIfNeeded()
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !isTerminatingAfterCleanup else {
            return .terminateNow
        }
        isTerminatingAfterCleanup = true
        Task {
            await appState.stop()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}

@MainActor
final class AppRuntime {
    static let shared = AppRuntime()
    let appState: TravelModeAppState

    private init() {
        appState = TravelModeAppState(
            gateway: LocalTravelCommandGateway(
                associationManager: CoreWLANAssociationManager()
            ),
            engine: .production()
        )
    }
}

@main
struct CodexTravelModeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}
