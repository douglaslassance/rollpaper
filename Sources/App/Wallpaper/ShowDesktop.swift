import AppKit

enum ShowDesktop {
    /// Triggers macOS "Show Desktop" by sending F11 to System Events.
    /// Requires the `com.apple.security.automation.apple-events` entitlement
    /// and an `NSAppleEventsUsageDescription` in Info.plist; the user is
    /// prompted to allow control of System Events on first run.
    static func trigger() {
        let source = #"tell application "System Events" to key code 103"#
        guard let script = NSAppleScript(source: source) else { return }
        var error: NSDictionary?
        script.executeAndReturnError(&error)
    }
}
