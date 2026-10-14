// ReYoga brand assets. Run with Swift on macOS; iconset intermediates stay in build.
import AppKit
import Foundation
let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let output = root.appendingPathComponent("Assets/Brand")
let iconset = root.appendingPathComponent("build/ReYogaSMC.iconset")
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
func mark(_ scale: CGFloat, color: NSColor) {
    let path = NSBezierPath()
    path.lineWidth = 96*scale
    path.lineCapStyle = .round; path.lineJoinStyle = .round
    path.move(to: NSPoint(x: 352*scale, y: (1024-300)*scale))
    path.line(to: NSPoint(x: 352*scale, y: (1024-720)*scale))
    path.line(to: NSPoint(x: 686*scale, y: (1024-720)*scale))
    color.setStroke(); path.stroke()
    NSColor(calibratedRed: 0.97, green: 0.20, blue: 0.25, alpha: 1).setFill()
    NSBezierPath(ovalIn: NSRect(x: 654*scale, y: (1024-361)*scale, width: 108*scale, height: 108*scale)).fill()
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
<path d="M352 300v420h334" fill="none" stroke="#f7f7f7" stroke-width="96" stroke-linecap="round" stroke-linejoin="round"/>
<circle cx="708" cy="307" r="54" fill="#f73340"/>
</svg>
"""
try svg.write(to: output.appendingPathComponent("app-icon.svg"), atomically: true, encoding: .utf8)
for dark in [false,true] {
    let fg = dark ? "#f5f5f5" : "#191b20"
    let muted = dark ? "#a2a7b2" : "#626976"
    let hero = """
    <svg xmlns="http://www.w3.org/2000/svg" width="1120" height="280" viewBox="0 0 1120 280">
    <g transform="translate(48 34) scale(.207)"><rect x="72" y="72" width="880" height="880" rx="196" fill="#202226"/><path d="M352 300v420h334" fill="none" stroke="#f7f7f7" stroke-width="96" stroke-linecap="round" stroke-linejoin="round"/><circle cx="708" cy="307" r="54" fill="#f73340"/></g>
    <text x="306" y="131" fill="\(fg)" font-family="-apple-system,BlinkMacSystemFont,Segoe UI,Helvetica,Arial,sans-serif" font-size="64" font-weight="650" letter-spacing="-2">ReYogaSMC</text>
    <text x="309" y="177" fill="\(muted)" font-family="-apple-system,BlinkMacSystemFont,Segoe UI,Helvetica,Arial,sans-serif" font-size="23">Your hardware. Your controls.</text>
    </svg>
    """
    try hero.write(to: output.appendingPathComponent(dark ? "readme-dark.svg" : "readme-light.svg"), atomically: true, encoding: .utf8)
}
let menu = """
<svg xmlns="http://www.w3.org/2000/svg" width="18" height="18" viewBox="0 0 18 18"><path d="M5 3v11h8" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"/><circle cx="12.5" cy="3.5" r="1.5" fill="currentColor"/></svg>
"""
try menu.write(to: output.appendingPathComponent("menubar.svg"), atomically: true, encoding: .utf8)

let catalog = root.appendingPathComponent("ReYogaSMCNC/Assets.xcassets/AppIcon.appiconset")
let manifestURL = catalog.appendingPathComponent("Contents.json")
var manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL)) as! [String: Any]
var images = manifest["images"] as! [[String: String]]
for index in images.indices {
    let size = images[index]["size"]!.components(separatedBy: "x")[0]
    let suffix = images[index]["scale"] == "2x" ? "@2x" : ""
    let name = "icon_\(size)x\(size)\(suffix).png"
    try Data(contentsOf: iconset.appendingPathComponent(name)).write(to: catalog.appendingPathComponent(name))
    images[index]["filename"] = name
}
manifest["images"] = images
try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys]).write(to: manifestURL)
