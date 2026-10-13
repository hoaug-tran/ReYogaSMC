// ReYoga brand assets. Run with Swift on macOS; iconset intermediates stay in build.
import AppKit
import Foundation
let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let output = root.appendingPathComponent("Assets/Brand")
let iconset = root.appendingPathComponent("build/ReYogaSMC.iconset")
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
func mark(_ scale: CGFloat, color: NSColor) {
    let points: [(CGFloat, CGFloat)] = [(270,286),(360,286),(512,460),(664,286),(754,286),(548,522),(548,752),(476,752),(476,522)]
    let path = NSBezierPath()
    path.move(to: NSPoint(x: points[0].0 * scale, y: (1024-points[0].1) * scale))
    for p in points.dropFirst() { path.line(to: NSPoint(x: p.0 * scale, y: (1024-p.1) * scale)) }
    path.close(); color.setFill(); path.fill()
    NSColor(calibratedRed: 0.91, green: 0.18, blue: 0.22, alpha: 1).setFill()
    NSBezierPath(ovalIn: NSRect(x: 717*scale, y: (1024-257)*scale, width: 74*scale, height: 74*scale)).fill()
}
func render(_ size: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: size * 4, bitsPerPixel: 32)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current!.cgContext.clear(CGRect(x: 0, y: 0, width: size, height: size))
    let scale = CGFloat(size)/1024
    let card = NSBezierPath(roundedRect: NSRect(x: 72*scale, y: 72*scale, width: 880*scale, height: 880*scale), xRadius: 196*scale, yRadius: 196*scale)
    let shadow = NSShadow(); shadow.shadowBlurRadius = 20*scale; shadow.shadowOffset = NSSize(width: 0, height: -8*scale); shadow.shadowColor = NSColor.black.withAlphaComponent(0.2)
    NSGraphicsContext.saveGraphicsState(); shadow.set()
    NSColor(calibratedWhite: 0.10, alpha: 1).setFill(); card.fill()
    NSGraphicsContext.restoreGraphicsState()
    NSGradient(starting: NSColor(calibratedWhite: 0.19, alpha: 1), ending: NSColor(calibratedWhite: 0.08, alpha: 1))!.draw(in: card, angle: -90)
    mark(scale, color: NSColor(calibratedWhite: 0.97, alpha: 1))
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}
for size in [16,32,64,128,256,512,1024] {
    let data = render(size)
    if size <= 512 { try data.write(to: iconset.appendingPathComponent("icon_\(size)x\(size).png")) }
    if size >= 32 { try data.write(to: iconset.appendingPathComponent("icon_\(size/2)x\(size/2)@2x.png")) }
    if size == 1024 { try data.write(to: output.appendingPathComponent("app-icon.png")) }
}
let svg = """
<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" viewBox="0 0 1024 1024">
<defs><linearGradient id="plate" x2="0" y2="1"><stop stop-color="#303030"/><stop offset="1" stop-color="#151515"/></linearGradient></defs>
<rect x="72" y="72" width="880" height="880" rx="196" fill="url(#plate)"/>
<path d="M270 286h90l152 174 152-174h90L548 522v230h-72V522Z" fill="#f7f7f7"/>
<circle cx="754" cy="220" r="37" fill="#e82e38"/>
</svg>
"""
try svg.write(to: output.appendingPathComponent("app-icon.svg"), atomically: true, encoding: .utf8)
for dark in [false,true] {
    let fg = dark ? "#f5f5f5" : "#191b20"
    let muted = dark ? "#a2a7b2" : "#626976"
    let hero = """
    <svg xmlns="http://www.w3.org/2000/svg" width="1120" height="280" viewBox="0 0 1120 280">
    <g transform="translate(48 34) scale(.207)"><rect x="72" y="72" width="880" height="880" rx="196" fill="#202226"/><path d="M270 286h90l152 174 152-174h90L548 522v230h-72V522Z" fill="#f7f7f7"/><circle cx="754" cy="220" r="37" fill="#e82e38"/></g>
    <text x="306" y="131" fill="\(fg)" font-family="-apple-system,BlinkMacSystemFont,Segoe UI,Helvetica,Arial,sans-serif" font-size="64" font-weight="650" letter-spacing="-2">ReYogaSMC</text>
    <text x="309" y="177" fill="\(muted)" font-family="-apple-system,BlinkMacSystemFont,Segoe UI,Helvetica,Arial,sans-serif" font-size="23">Your hardware. Your controls.</text>
    </svg>
    """
    try hero.write(to: output.appendingPathComponent(dark ? "readme-dark.svg" : "readme-light.svg"), atomically: true, encoding: .utf8)
}
let menu = """
<svg xmlns="http://www.w3.org/2000/svg" width="18" height="18" viewBox="0 0 18 18"><path d="M9 2v14M4 7l5 4M9 8l5-4" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"/></svg>
"""
try menu.write(to: output.appendingPathComponent("menubar.svg"), atomically: true, encoding: .utf8)
