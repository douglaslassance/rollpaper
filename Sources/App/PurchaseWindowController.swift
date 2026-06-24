import AppKit
import SwiftUI

@MainActor
final class PurchaseWindowController {
    static let shared = PurchaseWindowController()

    private var window: NSWindow?

    private init() {}

    func show(entitlementManager: EntitlementManager) {
        if let window = window {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }

        let view = PurchaseView(entitlementManager: entitlementManager)
        let hosting = NSHostingController(rootView: view)
        let window = NSWindow(contentViewController: hosting)
        window.styleMask = [.titled, .closable]
        window.title = "Upgrade to Rollpaper Pro"
        window.isReleasedWhenClosed = false
        window.center()

        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.window = nil
            }
        }

        self.window = window
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }
}
