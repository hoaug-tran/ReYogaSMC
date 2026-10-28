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
        let suite = "org.reyoga.UIReview." + UUID().uuidString
        let reviewDefaults = UserDefaults(suiteName: suite)!
        reviewDefaults.set(3200.0, forKey: "FanDraft1")
        reviewDefaults.set(3000.0, forKey: "FanDraft2")
        let modes = ["overview", "device", "cooling", "battery", "battery-wide", "lighting", "diagnostics", "rgb", "settings", "missing-driver",
                     "device-full", "cooling-full", "battery-full", "lighting-full", "diagnostics-full", "settings-full"]
        var jobs = [() -> Void]()
        for dark in [false, true] {
            let theme = dark ? "dark" : "light"
            let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            for (name, prompt, symbol) in [
                ("profile-success", "Power Profile: Balanced", "speedometer"),
                ("fan-success", "Fan 1: 3200 RPM minimum", "wind"),
                ("fan-error", "Fan 1: requested 3200 RPM, measured 2900. The minimum has not been reached.", "exclamationmark.triangle"),
                ("cpu-success", "CPU Boost Power: 65 W", "bolt.fill"),
                ("cpu-error", "CPU Boost Power: Firmware did not confirm the requested state", "exclamationmark.triangle"),
                ("transport-error", "IOKit transport failed (0xe00002c7)", "exclamationmark.triangle"),
                ("battery-error", "Conservation: Firmware did not confirm the requested state", "battery.75"),
                ("rgb-success", "Static: sent to controller", "lightbulb"),
                ("rgb-error", "RGB: macOS denied HID access. Enable Input Monitoring for ReYogaSMC, then retry discovery.", "exclamationmark.triangle"),
                ("export-success", "SSDT compiled — review it and add it to OpenCore before rebooting", "checkmark.circle"),
                ("export-error", "No unique reviewed AML fingerprint matches. Export diagnostics for firmware review.", "exclamationmark.triangle")
            ] {
                jobs.append {
                    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 64), styleMask: [.borderless], backing: .buffered, defer: false)
                    window.isOpaque = false; window.backgroundColor = .clear; window.appearance = appearance
                    let view = HUDContentView(frame: window.contentLayoutRect)
                    window.contentView = view
                    window.setContentSize(view.configure(prompt: localizedMessage(prompt), image: NSImage(systemSymbolName: symbol, accessibilityDescription: prompt)))
                    view.layoutSubtreeIfNeeded()
                    save(view, to: directory.appendingPathComponent("hud-\(name)-\(theme).png"))
                }
            }
            jobs.append {
                let alert = NSAlert()
                alert.alertStyle = .warning
                alert.messageText = localizedMessage("Change fan minimum?")
                alert.informativeText = localizedMessage("This raises the minimum over the factory cooling curve; it does not set an unrestricted fixed speed. Higher minima increase fan noise and power use. Restore Auto returns control to the factory curve.")
                alert.addButton(withTitle: localizedMessage("Continue"))
                alert.addButton(withTitle: localizedMessage("Cancel"))
                alert.showsSuppressionButton = true
                alert.suppressionButton?.title = localizedMessage("Don’t show this explanation again")
                alert.window.appearance = appearance
                alert.layout()
                alert.window.orderFront(nil)
                alert.window.displayIfNeeded()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                    defer { alert.window.orderOut(nil) }
                    if let screenshot = CGWindowListCreateImage(.null, .optionIncludingWindow, CGWindowID(alert.window.windowNumber), [.boundsIgnoreFraming, .bestResolution]) {
                        let bitmap = NSBitmapImageRep(cgImage: screenshot)
                        if let data = bitmap.representation(using: .png, properties: [:]) {
                            try? data.write(to: directory.appendingPathComponent("confirm-fan-minimum-\(theme).png"))
                        }
                    }
                }
            }
            jobs.append {
                let alert = NSAlert()
                alert.alertStyle = .warning
                alert.messageText = localizedMessage("Change CPU power limits?")
                alert.informativeText = localizedMessage("Higher limits can increase heat, fan noise and battery drain. Lower limits can reduce performance. Only firmware-supported values are accepted. Reset restores the values saved before your edits in this power profile.")
                alert.addButton(withTitle: localizedMessage("Continue"))
                alert.addButton(withTitle: localizedMessage("Cancel"))
                alert.showsSuppressionButton = true
                alert.suppressionButton?.title = localizedMessage("Don’t show this explanation again")
                alert.window.appearance = appearance
                alert.layout()
                alert.window.orderFront(nil)
                alert.window.displayIfNeeded()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                    defer { alert.window.orderOut(nil) }
                    if let screenshot = CGWindowListCreateImage(.null, .optionIncludingWindow, CGWindowID(alert.window.windowNumber), [.boundsIgnoreFraming, .bestResolution]) {
                        let bitmap = NSBitmapImageRep(cgImage: screenshot)
                        if let data = bitmap.representation(using: .png, properties: [:]) {
                            try? data.write(to: directory.appendingPathComponent("confirm-cpu-power-\(theme).png"))
                        }
                    }
                }
            }
            for mode in modes {
                jobs.append {
                    if let path = ProcessInfo.processInfo.environment["REYOGA_UI_FIXTURE"],
                       let data = FileManager.default.contents(atPath: path),
                       let fixture = (try? JSONSerialization.jsonObject(with: data)) as? NSDictionary {
                        manager.loadUIFixture(fixture)
                        if let review = fixture["UIReview"] as? [String: Any], let draft = review["PowerDraft"] as? String {
                            reviewDefaults.set(draft, forKey: "PowerDraft.CPUBoostPower")
                            reviewDefaults.set(draft, forKey: "PowerDraft.CPUSustainedPower")
                        }
                    }
                    if mode == "missing-driver" { manager.loadMissingDriverPreview() }
                    let size = NSSize(width: mode == "rgb" ? 420 : mode.hasSuffix("-wide") ? 1040 : AppTheme.windowWidth,
                                      height: mode == "rgb" ? 480 : mode.hasSuffix("-full") ? (mode.hasPrefix("diagnostics") ? 3000 : 2000) : mode.hasSuffix("-wide") ? 760 : AppTheme.windowHeight)
                    let root = ReYogaReviewView(mode: mode, manager: manager)
                        .frame(width: size.width, height: size.height)
                        .defaultAppStorage(reviewDefaults)
                    let controller = NSHostingController(rootView: root)
                    let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
                    window.appearance = appearance; window.contentViewController = controller
                    window.setContentSize(size)
                    controller.view.frame = NSRect(origin: .zero, size: size)
                    controller.view.layoutSubtreeIfNeeded()
                    // Let SwiftUI onAppear and layout updates finish before caching the view.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                        _ = window
                        controller.view.layoutSubtreeIfNeeded()
                        save(controller.view, to: directory.appendingPathComponent("\(mode)-\(theme).png"))
                    }
                }
            }
        }
        func next(_ index: Int) {
            guard index < jobs.count else {
                UserDefaults.standard.removePersistentDomain(forName: suite)
                print("UI review saved: " + directory.path)
                NSApp.terminate(nil); return
            }
            jobs[index]()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { next(index + 1) }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { next(0) }
    }

    private static func save(_ view: NSView, to url: URL) {
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        guard let data = bitmap.representation(using: .png, properties: [:]) else { return }
        do { try data.write(to: url) } catch { print("UI review write failed: \(error)") }
    }
}
#endif
