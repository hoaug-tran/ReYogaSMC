import SwiftUI
import AppKit

struct PersistentColorWell: NSViewRepresentable {
    @Binding var hex: String
    final class Well: NSColorWell {
        override func mouseDown(with event: NSEvent) {
            ReYogaColorPanel.shared.present(from: self)
        }
    }
    final class Coordinator: NSObject {
        var binding: Binding<String>
        init(_ binding: Binding<String>) { self.binding = binding }
        @objc func changed(_ sender: NSColorWell) { binding.wrappedValue = SavedRGBSettings.hex(sender.color) }
    }
    func makeCoordinator() -> Coordinator { Coordinator($hex) }
    func makeNSView(context: Context) -> Well {
        let view = Well(frame: .zero)
        view.target = context.coordinator; view.action = #selector(Coordinator.changed(_:))
        view.isBordered = true
        return view
    }
    func updateNSView(_ view: Well, context: Context) {
        context.coordinator.binding = $hex
        if SavedRGBSettings.hex(view.color) != hex { view.color = SavedRGBSettings.color(hex) }
    }
    static func dismantleNSView(_ view: Well, coordinator: Coordinator) {
        ReYogaColorPanel.shared.dismiss(ifEditing: view)
        view.deactivate()
    }
}

final class ReYogaColorPanel: NSObject, NSWindowDelegate {
    static let shared = ReYogaColorPanel()
    private weak var activeWell: NSColorWell?
    private weak var owner: NSWindow?
    private var isDismissing = false

    private override init() {
        super.init()
        NotificationCenter.default.addObserver(self, selector: #selector(applicationResigned),
                                               name: NSApplication.didResignActiveNotification, object: nil)
    }

    func present(from well: NSColorWell) {
        guard let window = well.window, let screen = window.screen else { return }
        owner = window
        activeWell = well
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSColorPanel.shared
        panel.delegate = self
        panel.showsAlpha = false
        panel.isContinuous = true
        panel.level = NSWindow.Level(rawValue: max(NSWindow.Level.floating.rawValue, window.level.rawValue + 1))
        well.activate(true)
        let anchor = window.convertToScreen(well.convert(well.bounds, to: nil))
        panel.setFrameOrigin(ColorPanelPlacement.origin(panelSize: panel.frame.size, anchor: anchor,
                                                       owner: window.frame, visible: screen.visibleFrame))
        panel.makeKeyAndOrderFront(nil)
    }

    func dismiss(ifEditing well: NSColorWell) {
        if activeWell === well { dismiss() }
    }

    func dismiss(closeControls: Bool = false) {
        guard !isDismissing else { return }
        isDismissing = true
        let window = owner
        activeWell?.deactivate()
        activeWell = nil
        NSColorPanel.shared.orderOut(nil)
        if !closeControls, window?.isVisible == true { window?.makeKey() }
        owner = nil
        isDismissing = false
    }

    func windowWillClose(_ notification: Notification) { dismiss() }
    @objc private func applicationResigned() { dismiss(closeControls: true) }
}
