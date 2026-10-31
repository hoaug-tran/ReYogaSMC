//
//  StatusHUD.swift
//  ReYogaSMC
//
//  Created by Zhen on 10/14/20.
//  Copyright © 2020 Zhen. All rights reserved.
//

import Foundation
import AppKit
import os.log

// The effect mask clips the material itself, including its compositor backdrop.
final class HUDContentView: NSView {
    let title = NSTextField(labelWithString: "")
    let detail = NSTextField(wrappingLabelWithString: "")
    let icon = NSImageView()
    private let surface: NSView
    private let material: NSVisualEffectView?

    override var isOpaque: Bool { false }
    override init(frame: NSRect) {
        let effect = NSVisualEffectView(frame: frame)
        effect.material = .popover
        effect.blendingMode = .behindWindow
        effect.state = .active
        if #available(macOS 26.0, *),
           let glassType = NSClassFromString("NSGlassEffectView") as? NSView.Type {
            let glass = glassType.init(frame: frame)
            glass.setValue(18.0, forKey: "cornerRadius")
            surface = glass; material = nil
        } else {
            surface = effect; material = effect
        }
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        addSubview(surface)
        let content = NSView(frame: bounds)
        if material == nil { surface.setValue(content, forKey: "contentView") }
        else { surface.addSubview(content) }
        content.autoresizingMask = [.width, .height]
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        title.textColor = .labelColor
        title.lineBreakMode = .byTruncatingTail
        detail.font = .systemFont(ofSize: 12)
        detail.textColor = .secondaryLabelColor
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.contentTintColor = .labelColor
        content.addSubview(title); content.addSubview(detail); content.addSubview(icon)
    }
    required init?(coder: NSCoder) { nil }
    func configure(prompt: String, image: NSImage?) -> NSSize {
        let prompt = localizedMessage(prompt)
        let pieces = prompt.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        let twoLines = pieces.count == 2 && pieces[0].count <= 40
        let longMessage = !twoLines && prompt.count > 42
        let hasDetail = twoLines || longMessage
        title.stringValue = twoLines ? pieces[0] : longMessage ? "ReYogaSMC" : prompt
        detail.stringValue = twoLines ? pieces[1] : longMessage ? prompt : ""
        detail.isHidden = !hasDetail
        icon.image = image
        icon.isHidden = image == nil
        let leading: CGFloat = image == nil ? 16 : 56
        let preferred = max(title.attributedStringValue.size().width, detail.attributedStringValue.size().width)
        let width = min(360, max(240, preferred + leading + 20))
        let textWidth = width-leading-16
        let secondaryHeight = hasDetail ? min(76, ceil((detail.stringValue as NSString).boundingRect(
            with: NSSize(width: textWidth, height: 1000), options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: detail.font!]).height)) : 0
        let textHeight: CGFloat = 18 + (hasDetail ? secondaryHeight+3 : 0)
        let size = NSSize(width: width, height: max(56, textHeight+28))
        frame.size = size; surface.frame = bounds
        let y = (size.height-textHeight)/2
        title.frame = NSRect(x: leading, y: y+textHeight-18, width: textWidth, height: 18)
        detail.frame = NSRect(x: leading, y: y, width: textWidth, height: secondaryHeight)
        icon.frame = NSRect(x: 16, y: (size.height-28)/2, width: 28, height: 28)
        if let material = material {
            material.maskImage = NSImage(size: size, flipped: false) { rect in
                NSColor.white.setFill()
                NSBezierPath(roundedRect: rect, xRadius: 18, yRadius: 18).fill()
                return true
            }
        }
        setAccessibilityLabel(prompt)
        return size
    }
}

private final class StatusHUD {
    static let shared = StatusHUD()
    private var panel: NSPanel?
    private var content: HUDContentView?
    private var dismiss: DispatchWorkItem?
    private var generation = 0

    func show(_ prompt: String, imagePath: NSString?, duration: UInt32, symbol: String?) {
        dismiss?.cancel(); generation += 1
        let current = generation
        if panel == nil {
            let frame = NSRect(x: 0, y: 0, width: 280, height: 64)
            let window = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.level = .statusBar
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            window.ignoresMouseEvents = true
            window.isOpaque = false; window.backgroundColor = .clear; window.hasShadow = true
            let view = HUDContentView(frame: frame)
            window.contentView = view
            content = view; panel = window
        }
        guard let window = panel, let content = content else { return }
        let resource = imagePath.map { URL(fileURLWithPath: $0 as String) }
        let bundled = resource?.path.hasPrefix(Bundle.main.resourceURL?.path ?? "\u{0}") == true
        let semantic = symbol ?? (bundled ? ReYogaBrand.eventSymbol(resource!.deletingPathExtension().lastPathComponent) : nil)
        var image: NSImage?
        if let symbol = symbol { image = NSImage(systemSymbolName: symbol, accessibilityDescription: prompt) }
        if image == nil, let resource = resource {
            image = NSImage(contentsOf: resource)
            if bundled { image?.isTemplate = true }
        }
        if image == nil, let semantic = semantic { image = NSImage(systemSymbolName: semantic, accessibilityDescription: prompt) }
        if image == nil { image = ReYogaBrand.menuImage(size: 28) }
        let size = content.configure(prompt: prompt, image: image)
        window.setContentSize(size)
        window.invalidateShadow()
        if let screen = NSScreen.main {
            window.setFrameOrigin(NSPoint(x: screen.visibleFrame.midX-size.width/2, y: screen.visibleFrame.minY+80))
        }
        window.alphaValue = 1; window.orderFrontRegardless()
        let work = DispatchWorkItem { [weak self] in
            guard let self = self, self.generation == current else { return }
            if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion { window.orderOut(nil); return }
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.18; window.animator().alphaValue = 0
            }, completionHandler: { [weak self] in
                if self?.generation == current { window.orderOut(nil) }
            })
        }
        dismiss = work
        DispatchQueue.main.asyncAfter(deadline: .now()+Double(duration)/1000, execute: work)
    }
}

func showOSDRaw(_ prompt: String, _ img: NSString? = nil, duration: UInt32 = 1000, symbol: String? = nil) {
    let prompt = localizedMessage(prompt)
    if Thread.isMainThread {
        StatusHUD.shared.show(prompt, imagePath: img, duration: duration, symbol: symbol)
    } else {
        DispatchQueue.main.async { StatusHUD.shared.show(prompt, imagePath: img, duration: duration, symbol: symbol) }
    }
}

func showOSD(_ prompt: String, _ img: NSString? = nil, duration: UInt32 = 1000) {
    showOSDRaw(NSLocalizedString(prompt, comment: "LocalizedString"), img, duration: duration)
}

func showOSDRes(_ prompt: String, _ image: EventImage, duration: UInt32 = 1000) {
    var img: NSString?
    if let path = Bundle.main.pathForImageResource(String(image.rawValue.dropFirst(1))) {
        img = path as NSString
    }
    showOSDRaw(NSLocalizedString(prompt, comment: "LocalizedString"), img, duration: duration)
}

func showOSDRes(
    _ prompt: String,
    _ status: String,
    _ image: EventImage,
    duration: UInt32 = 1000
) {
    var img: NSString?
    if let path = Bundle.main.pathForImageResource(String(image.rawValue.dropFirst(1))) {
        img = path as NSString
    }
    var alias = localizedMessage(prompt)
    if alias.isEmpty {
        showOSDRaw(alias, img, duration: duration)
    } else {
        alias += " " + localizedMessage(status)
        showOSDRaw(alias, img, duration: duration)
    }
}
