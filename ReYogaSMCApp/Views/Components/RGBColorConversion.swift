import AppKit
import Foundation

extension SavedRGBSettings {
    static func hex(_ color: NSColor) -> String {
        guard let c = color.usingColorSpace(.deviceRGB) else { return "#000000" }
        return String(format: "#%02X%02X%02X", Int(max(0, min(255, (c.redComponent * 255).rounded()))),
                      Int(max(0, min(255, (c.greenComponent * 255).rounded()))), Int(max(0, min(255, (c.blueComponent * 255).rounded()))))
    }
    static func color(_ hex: String) -> NSColor {
        let value = bytes(hex) ?? (0, 0, 0)
        return NSColor(deviceRed: CGFloat(value.0)/255, green: CGFloat(value.1)/255, blue: CGFloat(value.2)/255, alpha: 1)
    }
}
