import AppKit
import IOKit

enum SystemHotkeyActions {
    static func perform(_ action: String, service: io_service_t, toggleTouchpad: () -> Void, openControls: () -> Void) {
        ReYogaDiagnostics.shared.record("hotkey_action", ["action": action])
        switch action {
        case "mute": postMediaKey(Int(NX_KEYTYPE_MUTE))
        case "volumeDown": postMediaKey(Int(NX_KEYTYPE_SOUND_DOWN))
        case "volumeUp": postMediaKey(Int(NX_KEYTYPE_SOUND_UP))
        case "brightnessDown": postMediaKey(Int(NX_KEYTYPE_BRIGHTNESS_DOWN))
        case "brightnessUp": postMediaKey(Int(NX_KEYTYPE_BRIGHTNESS_UP))
        case "micMute": micMuteHelper(service, "Microphone")
        case "touchpad": toggleTouchpad()
        case "airplane": airplaneModeHelper("Airplane Mode", true)
        case "controlCenter":
            openControls()
            showOSDRaw("ReYogaSMC Controls")
        case "displays":
            performDesktopAction(.displaysettings, title: "Display Settings")
        case "mission":
            performDesktopAction(.mission, title: "Mission Control")
        case "calculator": launchHotkeyApp("com.apple.calculator", title: "Calculator")
        case "screenshot": launchHotkeyApp("com.apple.Screenshot", title: "Screenshot")
        default:
            ReYogaDiagnostics.shared.record("hotkey_unimplemented", ["action": action])
            showOSDRaw(localizedMessage("Hotkey mapping needs support: %@", action))
        }
    }
    private static func launchHotkeyApp(_ bundle: String, title: String) {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle) else {
            showOSDRaw(localizedMessage("%@: application unavailable", localizedMessage(title))); return
        }
        launchApplication(at: url, title: title, display: true)
    }
    private static func postMediaKey(_ code: Int) {
        for state in [0xA, 0xB] {
            guard let event = NSEvent.otherEvent(with: .systemDefined, location: .zero,
                modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
                subtype: 8, data1: code << 16 | state << 8, data2: -1)?.cgEvent else { continue }
            event.setIntegerValueField(.eventSourceUserData, value: LegionHotkeys.syntheticEventTag)
            event.post(tap: .cghidEventTap)
        }
    }
}
