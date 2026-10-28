import SwiftUI
import AppKit

#if DEBUG
struct ReYogaReviewView: View {
    let mode: String
    private var actions: HardwareControlsActions { HardwareControlsActions(showAbout: {}, retryDriverConnection: {}, resetShortcuts: {}) }
    @ObservedObject var manager: HardwareManager
    var body: some View {
        if mode == "missing-driver" { HardwareControlsView(manager: manager, actions: actions) }
        else if mode == "rgb" { RGBControls(manager: manager).padding(16).frame(width: 420, height: 360, alignment: .top).background(Color(NSColor.windowBackgroundColor)) }
        else if mode == "settings" { HardwareControlsView(manager: manager, page: -1, actions: actions) }
        else { HardwareControlsView(manager: manager, page: mode == "device" ? 1 : mode == "cooling" ? 2 : mode.hasPrefix("battery") ? 3 : mode == "lighting" ? 4 : mode == "diagnostics" ? 5 : 0, actions: actions) }
    }
}

#endif
