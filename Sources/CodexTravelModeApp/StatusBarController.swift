import AppKit
import CodexTravelModeCore
import SwiftUI

@MainActor
final class StatusBarController: NSObject {
    private let appState: TravelModeAppState
    private let statusItem: NSStatusItem
    private let popover: NSPopover

    init(appState: TravelModeAppState) {
        self.appState = appState
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        self.popover = NSPopover()
        super.init()
        configureStatusItem()
        configurePopover()
    }

    private func configureStatusItem() {
        guard let button = statusItem.button else {
            return
        }

        button.image = NSImage(
            systemSymbolName: "wifi.router",
            accessibilityDescription: "Codex Travel Mode"
        )
        button.action = #selector(togglePopover(_:))
        button.target = self
    }

    private func configurePopover() {
        popover.behavior = .transient
        popover.animates = true
        popover.contentSize = NSSize(width: 300, height: 360)
        popover.contentViewController = NSHostingController(
            rootView: MenuBarContentView(
                appState: appState,
                onQuit: {
                    NSApplication.shared.terminate(nil)
                }
            )
        )
    }

    @objc
    private func togglePopover(_ sender: AnyObject?) {
        guard let button = statusItem.button else {
            return
        }

        if popover.isShown {
            popover.performClose(nil)
            return
        }

        NSApplication.shared.activate(ignoringOtherApps: true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()

        Task {
            if !appState.isRunning {
                await appState.refreshConfiguration()
            }
            await appState.refreshStatus()
        }
    }
}
