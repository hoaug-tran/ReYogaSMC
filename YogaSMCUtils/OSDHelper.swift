//
//  OSDHelper.swift
//  YogaSMC
//
//  Created by Zhen on 10/14/20.
//  Copyright © 2020 Zhen. All rights reserved.
//

import Foundation
import AppKit
import os.log

// Bundled resources
enum EventImage: String {
    case kAirplaneMode, kAntenna, kMic, kMicOff, kKeyboard, kKeyboardOff, kWifi, kWifiOff
    case kBacklightHigh, kBacklightLow, kBacklightOff, kCapslockOn, kCapslockOff, kDock, kUndock
    case kBluetooth, kCamera, kFunctionKey, kFunctionKeyOff, kFunctionKeyOn, kSecondDisplay, kSleep, kStar
}

enum ReYogaBrand {
    static func menuImage(size: CGFloat = 18) -> NSImage {
        let image = NSImage(size: NSSize(width: size, height: size), flipped: true) { rect in
            let scale = rect.width / 18
            let path = NSBezierPath()
            path.lineWidth = 1.8 * scale
            path.lineCapStyle = .round
            let strokes: [[(CGFloat, CGFloat)]] = [[(9,2),(9,16)],[(4,7),(9,11)],[(9,8),(14,4)]]
            for points in strokes {
                path.move(to: NSPoint(x: points[0].0 * scale, y: points[0].1 * scale))
                path.line(to: NSPoint(x: points[1].0 * scale, y: points[1].1 * scale))
            }
            NSColor.black.setStroke(); path.stroke()
            return true
        }
        image.isTemplate = true
        return image
    }
    static func eventSymbol(_ name: String) -> String? {
        let symbols = ["AirplaneMode": "airplane", "Antenna": "antenna.radiowaves.left.and.right",
            "Mic": "mic", "MicOff": "mic.slash", "Keyboard": "keyboard", "KeyboardOff": "keyboard",
            "Wifi": "wifi", "WifiOff": "wifi.slash", "BacklightHigh": "light.max", "BacklightLow": "light.min",
            "BacklightOff": "light.min", "CapslockOn": "capslock", "CapslockOff": "capslock",
            "Dock": "rectangle.connected.to.line.below", "Undock": "rectangle",
            "Bluetooth": "wave.3.right", "Camera": "camera", "FunctionKey": "fn", "FunctionKeyOff": "fn",
            "FunctionKeyOn": "fn", "SecondDisplay": "display", "Sleep": "moon"]
        return symbols[name]
    }
}

// Public AppKit HUD: no dependency on Apple's private OSD service behavior.
private final class StatusHUD {
    static let shared = StatusHUD()
    private var panel: NSPanel?
    private var label: NSTextField?
    private var icon: NSImageView?
    private var dismiss: DispatchWorkItem?
    private var generation = 0

    func show(_ prompt: String, imagePath: NSString?, duration: UInt32, symbol: String?) {
        dismiss?.cancel()
        generation += 1
        let current = generation
        if panel == nil {
            let frame = NSRect(x: 0, y: 0, width: 400, height: 112)
            let window = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.level = .statusBar
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            window.ignoresMouseEvents = true
            window.isOpaque = false
            window.backgroundColor = .clear
            window.hasShadow = true
            let background = NSVisualEffectView(frame: frame)
            background.material = .hudWindow
            background.blendingMode = .behindWindow
            background.state = .active
            background.wantsLayer = true
            background.layer?.cornerRadius = 16
            background.layer?.masksToBounds = true
            let text = NSTextField(wrappingLabelWithString: "")
            text.font = .systemFont(ofSize: 14, weight: .semibold)
            text.textColor = .labelColor
            let image = NSImageView(frame: NSRect(x: 16, y: 34, width: 44, height: 44))
            image.imageScaling = .scaleProportionallyUpOrDown
            background.addSubview(text)
            background.addSubview(image)
            window.contentView = background
            label = text; icon = image; panel = window
        }
        guard let window = panel, let label = label, let icon = icon else { return }
        label.stringValue = prompt
        let resource = imagePath.map { URL(fileURLWithPath: $0 as String) }
        let bundled = resource?.path.hasPrefix(Bundle.main.resourceURL?.path ?? "\u{0}") == true
        let semantic = symbol ?? (bundled ? ReYogaBrand.eventSymbol(resource!.deletingPathExtension().lastPathComponent) : nil)
        if let semantic = semantic {
            icon.image = NSImage(systemSymbolName: semantic, accessibilityDescription: prompt) ?? ReYogaBrand.menuImage(size: 44)
            icon.contentTintColor = .labelColor
        } else if let imagePath = imagePath, !bundled {
            icon.image = NSImage(contentsOfFile: imagePath as String)
            icon.contentTintColor = nil
        } else {
            icon.image = ReYogaBrand.menuImage(size: 44)
            icon.contentTintColor = .labelColor
        }
        icon.isHidden = icon.image == nil
        label.alignment = icon.isHidden ? .center : .left
        label.frame = NSRect(x: icon.isHidden ? 18 : 76, y: 22, width: icon.isHidden ? 364 : 306, height: 70)
        if let screen = NSScreen.main {
            window.setFrameOrigin(NSPoint(x: screen.visibleFrame.midX - 200, y: screen.visibleFrame.minY + 80))
        }
        window.alphaValue = 1
        window.orderFrontRegardless()
        let work = DispatchWorkItem { [weak self] in
            guard let self = self, self.generation == current else { return }
            if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion { window.orderOut(nil); return }
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.18
                window.animator().alphaValue = 0
            }, completionHandler: { [weak self] in
                if self?.generation == current { window.orderOut(nil) }
            })
        }
        dismiss = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Double(duration) / 1000, execute: work)
    }
}

func showOSDRaw(_ prompt: String, _ img: NSString? = nil, duration: UInt32 = 1000, priority: UInt32 = 0x1f4, symbol: String? = nil) {
    if Thread.isMainThread {
        StatusHUD.shared.show(prompt, imagePath: img, duration: duration, symbol: symbol)
    } else {
        DispatchQueue.main.async { StatusHUD.shared.show(prompt, imagePath: img, duration: duration, symbol: symbol) }
    }
}

func showOSD(_ prompt: String, _ img: NSString? = nil, duration: UInt32 = 1000, priority: UInt32 = 0x1f4) {
    showOSDRaw(NSLocalizedString(prompt, comment: "LocalizedString"), img, duration: duration, priority: priority)
}

func showOSDRes(_ prompt: String, _ image: EventImage, duration: UInt32 = 1000, priority: UInt32 = 0x1f4) {
    var img: NSString?
    if let path = Bundle.main.pathForImageResource(String(image.rawValue.dropFirst(1))) {
        img = path as NSString
    }
    showOSDRaw(NSLocalizedString(prompt, comment: "LocalizedString"), img, duration: duration, priority: priority)
}

func showOSDRes(
    _ prompt: String,
    _ status: String,
    _ image: EventImage,
    duration: UInt32 = 1000,
    priority: UInt32 = 0x1f4
) {
    var img: NSString?
    if let path = Bundle.main.pathForImageResource(String(image.rawValue.dropFirst(1))) {
        img = path as NSString
    }
    var alias = prompt
    if img != nil {
        alias = NSLocalizedString(prompt, comment: "")
    }
    if alias.isEmpty {
        showOSDRaw(alias, img, duration: duration, priority: priority)
    } else {
        alias += " " + NSLocalizedString(status, comment: "")
        showOSDRaw(alias, img, duration: duration, priority: priority)
    }
}
