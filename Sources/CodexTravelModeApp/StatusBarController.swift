import AppKit
import Combine
import CodexTravelModeCore
import SwiftUI

@MainActor
final class StatusBarController: NSObject {
    private let appState: TravelModeAppState
    private let onRetryCleanupAndQuit: () -> Void
    private let statusItem: NSStatusItem
    private let popover: NSPopover
    private var appStateObservation: AnyCancellable?

    var statusButton: NSStatusBarButton? {
        statusItem.button
    }

    var popoverContentView: NSView? {
        popover.contentViewController?.view
    }

    var isPopoverShown: Bool {
        popover.isShown && popoverContentView?.window?.isVisible == true
    }

    init(
        appState: TravelModeAppState,
        onRetryCleanupAndQuit: @escaping () -> Void
    ) {
        self.appState = appState
        self.onRetryCleanupAndQuit = onRetryCleanupAndQuit
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        self.popover = NSPopover()
        super.init()
        configureStatusItem()
        configurePopover()
        observeAppState()
    }

    private func configureStatusItem() {
        guard let button = statusItem.button else {
            return
        }

        button.action = #selector(handleStatusItemClick(_:))
        button.target = self
        updateStatusItem()
    }

    private func configurePopover() {
        popover.behavior = .transient
        popover.animates = true
        popover.contentSize = currentLifecycleContent.preferredPopoverSize
        popover.contentViewController = NSHostingController(
            rootView: MenuBarContentView(
                appState: appState,
                onQuit: {
                    NSApplication.shared.terminate(nil)
                },
                onRetryCleanupAndQuit: onRetryCleanupAndQuit
            )
        )
    }

    private func observeAppState() {
        appStateObservation = appState.objectWillChange.sink { [weak self] _ in
            Task { @MainActor [weak self] in
                await Task.yield()
                self?.updatePresentation()
            }
        }
    }

    private var currentLifecycleContent: MenuBarLifecycleContent {
        MenuBarLifecycleContent(
            presentation: appState.lifecyclePresentation,
            hasPendingQuitIntent: appState.hasPendingQuitIntent
        )
    }

    private func updatePresentation() {
        updateStatusItem()
        let preferredSize = currentLifecycleContent.preferredPopoverSize
        if popover.contentSize != preferredSize {
            popover.contentSize = preferredSize
        }
    }

    private func updateStatusItem() {
        guard let button = statusItem.button else { return }
        let content = currentLifecycleContent
        let image = NSImage(
            systemSymbolName: content.symbolName,
            accessibilityDescription: content.symbolName
        )
        image?.isTemplate = true
        button.image = image
        button.contentTintColor = content.tint
        button.setAccessibilityLabel(content.accessibilityLabel)
        button.toolTip = content.accessibilityLabel
    }

    @objc
    private func handleStatusItemClick(_ sender: AnyObject?) {
        togglePopover()
    }

    func togglePopover() {
        guard let button = statusItem.button else {
            return
        }

        if isPopoverShown {
            dismissPopover()
            return
        }

        updatePresentation()
        NSApplication.shared.activate(ignoringOtherApps: true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()

        Task {
            if case .off = appState.lifecyclePresentation {
                await appState.refreshConfiguration()
            }
            await appState.refreshStatus()
        }
    }

    func dismissPopover() {
        popover.close()
        popover.contentViewController?.view.window?.orderOut(nil)
    }
}
