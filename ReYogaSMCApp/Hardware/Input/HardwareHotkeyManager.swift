import Foundation
import ApplicationServices
import Combine

final class HardwareHotkeyManager: ObservableObject {
    @Published private(set) var hotkeysEnabled = false
    @Published private(set) var hotkeyStatus = "Off - native media keys remain active."
    @Published private(set) var hasAccessibilityPermission = false
    @Published private(set) var hasInputMonitoringPermission = false
    @Published private(set) var permissionStatus = ""
    private let hotkeys = LegionHotkeys()
    private var restoreAttempted = false

    private let feedback: (HardwareFeedback) -> Void
    init(feedback: @escaping (HardwareFeedback) -> Void = { _ in }, action: @escaping (String) -> Void) {
        self.feedback = feedback
        hotkeys.action = action
    }

    func disconnect() {
        hotkeys.stop()
        hotkeysEnabled = false
        restoreAttempted = false
    }

    func stop() { hotkeys.stop() }

    func refreshPermissions(profileID: String, driverReady: Bool) {
        let accessibility = AXIsProcessTrusted()
        let input = CGPreflightListenEventAccess()
        hasAccessibilityPermission = accessibility
        hasInputMonitoringPermission = input
        permissionStatus = localizedMessage("Accessibility: %@ - Input Monitoring: %@", localizedMessage(accessibility ? "Granted" : "Required"), localizedMessage(input ? "Granted" : "Required"))
        if hotkeysEnabled && (!accessibility || !input) {
            hotkeys.stop(); hotkeysEnabled = false
            hotkeyStatus = "Hotkey privacy access is missing. Check Accessibility and Input Monitoring, then enable the mapper again."
            feedback(.message(hotkeyStatus, durationMilliseconds: 3000))
        }
        if driverReady, !CommandLine.arguments.contains("--render-ui"), !restoreAttempted && !profileID.isEmpty {
            restoreAttempted = true
            if UserDefaults.standard.bool(forKey: "LegionHotkeysEnabled") {
                if accessibility && input { setEnabled(true, profileID: profileID, driverReady: driverReady) }
                else { hotkeyStatus = "Saved mapping is paused: grant Accessibility and Input Monitoring, then enable it." }
            }
        }
    }
    func setEnabled(_ enabled: Bool, profileID: String, driverReady: Bool) {
        guard !enabled || driverReady else {
            hotkeyStatus = "Connect a compatible hardware driver before enabling keyboard mapping."
            feedback(.message(hotkeyStatus, durationMilliseconds: 3000)); return
        }
        do {
            if enabled { try hotkeys.start(profileID: profileID) } else { hotkeys.stop() }
            hotkeysEnabled = enabled
            UserDefaults.standard.set(enabled, forKey: "LegionHotkeysEnabled")
            hotkeyStatus = enabled ? "Mapper active. Native firmware/media keys are unchanged." : "Off - native media keys remain active."
            refreshPermissions(profileID: profileID, driverReady: driverReady)
            feedback(.hotkeysEnabled(enabled))
        } catch {
            hotkeysEnabled = false
            hotkeyStatus = error.localizedDescription
            ReYogaDiagnostics.shared.record("hotkeys_failed", ["error": error.localizedDescription])
            feedback(.message(error.localizedDescription, durationMilliseconds: 3000))
        }
    }
}
