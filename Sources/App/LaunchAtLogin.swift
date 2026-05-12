import Foundation
import ServiceManagement

@MainActor
final class LaunchAtLoginController: ObservableObject {
    @Published private(set) var isEnabled: Bool = false
    @Published private(set) var lastError: String?

    var isAvailable: Bool {
        Bundle.main.bundleIdentifier != nil
    }

    init() {
        refresh()
    }

    func refresh() {
        guard isAvailable else {
            isEnabled = false
            return
        }
        isEnabled = SMAppService.mainApp.status == .enabled
    }

    func setEnabled(_ enabled: Bool) {
        guard isAvailable else {
            lastError = "Launch at Login requires Rollpaper to be installed in Applications."
            return
        }
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
        refresh()
    }
}
