// Renders Resources/AppIcon.icns. Run: swift scripts/make-icon.swift
import AppKit

func render(_ size: CGFloat) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size), bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = size / 1024
    let rect = NSRect(x: 100 * s, y: 100 * s, width: 824 * s, height: 824 * s)
    let bg = NSBezierPath(roundedRect: rect, xRadius: 185 * s, yRadius: 185 * s)
    NSGradient(starting: NSColor(red: 0.16, green: 0.47, blue: 0.96, alpha: 1),
               ending: NSColor(red: 0.07, green: 0.33, blue: 0.80, alpha: 1))!.draw(in: bg, angle: -90)
    // Circle + check mark
    NSColor.white.setStroke()
    let ring = NSBezierPath(ovalIn: NSRect(x: 262 * s, y: 262 * s, width: 500 * s, height: 500 * s))
    ring.lineWidth = 56 * s
    ring.stroke()
    let check = NSBezierPath()
    check.move(to: NSPoint(x: 392 * s, y: 520 * s))
    check.line(to: NSPoint(x: 478 * s, y: 430 * s))
    check.line(to: NSPoint(x: 646 * s, y: 610 * s))
    check.lineWidth = 64 * s
    check.lineCapStyle = .round
    check.lineJoinStyle = .round
    check.stroke()
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let fm = FileManager.default
let iconset = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("AppIcon.iconset")
try? fm.removeItem(at: iconset)
try! fm.createDirectory(at: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    try! render(CGFloat(base)).write(to: iconset.appendingPathComponent("icon_\(base)x\(base).png"))
    try! render(CGFloat(base * 2)).write(to: iconset.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", iconset.path, "-o", "Resources/AppIcon.icns"]
try! p.run(); p.waitUntilExit()
print(p.terminationStatus == 0 ? "Wrote Resources/AppIcon.icns" : "iconutil failed")
