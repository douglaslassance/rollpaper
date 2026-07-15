import SwiftUI
import AppKit
#if !APPSTORE_BUILD
import Sparkle
#endif

@main
struct RollpaperApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var appState = AppState()
    @StateObject private var launchAtLogin = LaunchAtLoginController()
    #if !APPSTORE_BUILD
    private let updaterController = SPUStandardUpdaterController(
        startingUpdater: {
            #if DEBUG
            return false  // Don't auto-start in debug — keys aren't set in Info.plist
            #else
            return true
            #endif
        }(),
        updaterDelegate: nil,
        userDriverDelegate: nil
    )
    #endif

    var body: some Scene {
        MenuBarExtra("Rollpaper", systemImage: "photo.on.rectangle.angled") {
            #if !APPSTORE_BUILD
            MenuContent(updater: updaterController.updater)
                .environmentObject(appState)
                .environmentObject(launchAtLogin)
            #else
            MenuContent()
                .environmentObject(appState)
                .environmentObject(launchAtLogin)
            #endif
        }
        .menuBarExtraStyle(.menu)

        Settings {
            SettingsView()
                .environmentObject(appState)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }

    func applicationDidResignActive(_ notification: Notification) {
        if NSApp.activationPolicy() == .regular {
            NSApp.setActivationPolicy(.accessory)
        }
    }
}

struct MenuContent: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var launchAtLogin: LaunchAtLoginController
    @ObservedObject private var entitlements = EntitlementManager.shared
    @Environment(\.openSettings) private var openSettings
    #if !APPSTORE_BUILD
    let updater: SPUUpdater
    #endif

    var body: some View {
        Button("Next Wallpaper") {
            Task { await appState.rotateNow() }
        }
        .disabled(appState.feeds.isEmpty || appState.isRefreshing)

        Button("Previous Wallpaper") {
            appState.showPreviousWallpaper()
        }
        .disabled(!appState.canGoToPreviousWallpaper || appState.isRefreshing)

        Divider()

        Button("Save Current Wallpaper As...") {
            appState.saveCurrentWallpaperAs()
        }
        .disabled(appState.currentWallpaper == nil)

        Button("Open wallpaper source") {
            appState.openCurrentWallpaperSource()
        }
        .disabled(appState.currentWallpaper?.sourceURL == nil)

        Button("Don't show this again") {
            if entitlements.hasProAccess {
                appState.filterCurrentWallpaper()
            } else {
                PurchaseWindowController.shared.show(entitlementManager: entitlements)
            }
        }
        .disabled(appState.currentWallpaper == nil)

        Divider()

        Toggle("Launch at Login", isOn: Binding(
            get: { launchAtLogin.isEnabled },
            set: { launchAtLogin.setEnabled($0) }
        ))
        .disabled(!launchAtLogin.isAvailable)

        Button("Settings…") {
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
            openSettings()
        }
        .keyboardShortcut(",")

        if !entitlements.hasProAccess {
            Button("Upgrade to Pro…") {
                PurchaseWindowController.shared.show(entitlementManager: entitlements)
            }
        }

        #if DEBUG
        Divider()
        Menu("Debug") {
            Toggle("Rollpaper Pro", isOn: Binding(
                get: { entitlements.hasProAccess },
                set: { _ in entitlements.toggleProForTesting() }
            ))
            .keyboardShortcut("p", modifiers: [.command, .shift, .option])
            .disabled(entitlements.hasRealLicenseKey)

            Button("Clear License Key") {
                entitlements.resetForTesting()
            }
        }
        #endif

        #if !APPSTORE_BUILD && !DEBUG
        CheckForUpdatesView(
            viewModel: CheckForUpdatesViewModel(updater: updater),
            updater: updater
        )
        #endif

        Divider()

        Button("About Rollpaper") {
            NSApp.setActivationPolicy(.regular)
            AboutWindowController.shared.show(entitlementManager: entitlements)
        }

        Button("Quit Rollpaper") {
            NSApplication.shared.terminate(nil)
        }
        .keyboardShortcut("q")
    }
}
