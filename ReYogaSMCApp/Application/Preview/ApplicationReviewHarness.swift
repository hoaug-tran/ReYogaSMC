#if DEBUG
import AppKit
import SwiftUI
import IOKit

// Explicit entry point; release startup never interprets review-only arguments.
enum ApplicationReviewHarness {
    static var isRendering: Bool { CommandLine.arguments.contains("--render-ui") }

    static func startIfRequested(manager: HardwareManager, hasDriverConnection: @escaping () -> Bool,
                                 setupWindows: () -> Void) -> Bool {
        if isRendering { renderUIReview(manager: manager); return true }
        guard CommandLine.arguments.contains("--check-missing-driver") else { return false }
        manager.setDriverState(.missing, message: "ReYogaSMC.kext is required. Install a compatible driver and restart macOS.")
        setupWindows()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            let clean = !hasDriverConnection() && manager.driverState == .missing
            print(clean ? "PASS missing driver: no client; independent sensors and recovery controls available" : "FAIL missing-driver startup")
            NSApp.terminate(nil)
        }
        return true
    }

    private static func renderUIReview(manager: HardwareManager) {
        if let path = ProcessInfo.processInfo.environment["REYOGA_UI_FIXTURE"],
           let data = FileManager.default.contents(atPath: path),
           let fixture = (try? JSONSerialization.jsonObject(with: data)) as? NSDictionary {
            manager.loadUIFixture(fixture)
        } else {
            let service = IOServiceGetMatchingService(kIOMasterPortDefault, IOServiceMatching("IdeaVPC"))
            if service != 0 { manager.loadReadOnlyPreview(service); IOObjectRelease(service) }
        }
        let directory = URL(fileURLWithPath: ProcessInfo.processInfo.environment["REYOGA_UI_REVIEW_DIR"] ?? NSTemporaryDirectory()).appendingPathComponent("ReYogaUIReview")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            for dark in [false, true] {
                if let path = ProcessInfo.processInfo.environment["REYOGA_UI_FIXTURE"],
                   let data = FileManager.default.contents(atPath: path),
                   let fixture = (try? JSONSerialization.jsonObject(with: data)) as? NSDictionary {
                    manager.loadUIFixture(fixture)
                }
                for (name, prompt, symbol) in [("balanced", "Power profile: Balanced", "speedometer"),
                    ("lighting", "Logo LED: Off", "lightbulb"), ("error", "Conservation: Firmware did not confirm the requested state", "battery.75")] {
                    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 64), styleMask: [.borderless], backing: .buffered, defer: false)
                    window.isOpaque = false; window.backgroundColor = .clear
                    window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                    let view = HUDContentView(frame: window.contentLayoutRect)
                    window.contentView = view
                    let size = view.configure(prompt: prompt, image: NSImage(systemSymbolName: symbol, accessibilityDescription: prompt))
                    window.setContentSize(size); view.layoutSubtreeIfNeeded()
                    if let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                        view.cacheDisplay(in: view.bounds, to: bitmap)
                        if let data = bitmap.representation(using: .png, properties: [:]) {
                            try? data.write(to: directory.appendingPathComponent("hud-\(name)-\(dark ? "dark" : "light").png"))
                        }
                    }
                }
                for mode in ["overview", "device", "cooling", "battery", "battery-wide", "lighting", "diagnostics", "rgb", "settings", "missing-driver"] {
                    if mode == "missing-driver" { manager.loadMissingDriverPreview() }
                    let controller = NSHostingController(rootView: ReYogaReviewView(mode: mode, manager: manager))
                    let size = NSSize(width: mode == "rgb" ? 420 : mode.hasSuffix("-wide") ? 1040 : AppTheme.windowWidth, height: mode == "rgb" ? 360 : mode.hasSuffix("-wide") ? 760 : AppTheme.windowHeight)
                    let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
                    window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                    window.contentViewController = controller
                    controller.view.frame = NSRect(origin: .zero, size: size)
                    controller.view.layoutSubtreeIfNeeded()
                    if let bitmap = controller.view.bitmapImageRepForCachingDisplay(in: controller.view.bounds) {
                        controller.view.cacheDisplay(in: controller.view.bounds, to: bitmap)
                        if let data = bitmap.representation(using: .png, properties: [:]) {
                            try? data.write(to: directory.appendingPathComponent("\(mode)-\(dark ? "dark" : "light").png"))
                        }
                    }
                }
            }
            NSApp.terminate(nil)
        }
    }
}
#endif
