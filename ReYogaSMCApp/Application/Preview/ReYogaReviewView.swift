import SwiftUI
import AppKit

#if DEBUG
struct ReYogaReviewView: View {
    let mode: String
    private var actions: HardwareControlsActions { HardwareControlsActions(showAbout: {}, retryDriverConnection: {}, resetShortcuts: {}) }
    @ObservedObject var manager: HardwareManager
    private var pageMode: String { mode.replacingOccurrences(of: "-full", with: "") }
    var body: some View {
        if pageMode == "missing-driver" { HardwareControlsView(manager: manager, actions: actions) }
        else if pageMode == "rgb" { RGBControls(manager: manager).padding(16).frame(width: 420, height: 480, alignment: .top).background(Color(NSColor.windowBackgroundColor)) }
        else if pageMode == "settings" { HardwareControlsView(manager: manager, page: -1, actions: actions) }
        else { HardwareControlsView(manager: manager, page: pageMode == "device" ? 1 : pageMode == "cooling" ? 2 : pageMode.hasPrefix("battery") ? 3 : pageMode == "lighting" ? 4 : pageMode == "diagnostics" ? 5 : 0, actions: actions) }
    }
}

#endif
