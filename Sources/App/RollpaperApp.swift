import SwiftUI
import AppKit

@main
struct RollpaperApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var appState = AppState()
    @StateObject private var launchAtLogin = LaunchAtLoginController()

    var body: some Scene {
        MenuBarExtra("Rollpaper", systemImage: "photo.on.rectangle.angled") {
            MenuContent()
                .environmentObject(appState)
                .environmentObject(launchAtLogin)
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
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Button("Next Wallpaper") {
            Task { await appState.rotateNow() }
        }
        .disabled(appState.feeds.isEmpty || appState.isRefreshing)

        Divider()

        Button("Download current wallpaper…") {
            appState.downloadCurrentWallpaper()
        }
        .disabled(appState.currentWallpaper == nil)

        Button("Open wallpaper source") {
            appState.openCurrentWallpaperSource()
        }
        .disabled(appState.currentWallpaper?.sourceURL == nil)

        Button("Don't show this again") {
            appState.blockCurrentWallpaper()
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

        #if !APPSTORE_BUILD && !DEBUG
        CheckForUpdatesView(
            viewModel: CheckForUpdatesViewModel(updater: SparkleHost.controller.updater),
            updater: SparkleHost.controller.updater
        )
        #endif

        Divider()

        Button("Quit Rollpaper") {
            NSApplication.shared.terminate(nil)
        }
        .keyboardShortcut("q")
    }
}
