import AppKit

enum HotkeyPermissionActions {
    static func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }
    static func openInputMonitoringSettings() { openPrivacySettings() }

    static func openPrivacySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent") { NSWorkspace.shared.open(url) }
        showOSDRaw("Grant Accessibility and Input Monitoring. If macOS requests a restart, quit and reopen ReYogaSMC.", duration: 4000)
    }
}
