#!/usr/bin/env swift
// Renders Resources/AppIcon.icns. Run: swift scripts/generate-icon.swift
import AppKit

let fm = FileManager.default
let root = URL(fileURLWithPath: fm.currentDirectoryPath)
let iconset = root.appendingPathComponent(".build/AppIcon.iconset")
try? fm.removeItem(at: iconset)
try fm.createDirectory(at: iconset, withIntermediateDirectories: true)

func render(size: Int) -> Data {
    let s = CGFloat(size)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext

    // macOS icon grid: ~80% body with a soft shadow.
    let inset = s * 0.1
    let body = CGRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2)
    let radius = body.width * 0.225

    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -s * 0.012), blur: s * 0.03,
                  color: NSColor.black.withAlphaComponent(0.35).cgColor)
    let shape = NSBezierPath(roundedRect: body, xRadius: radius, yRadius: radius)
    let gradient = NSGradient(colors: [
        NSColor(srgbRed: 0.33, green: 0.55, blue: 1.00, alpha: 1),
        NSColor(srgbRed: 0.45, green: 0.25, blue: 0.95, alpha: 1),
    ])!
    shape.addClip()
    gradient.draw(in: body, angle: -60)
    ctx.restoreGState()

    // Subtle top highlight.
    ctx.saveGState()
    NSBezierPath(roundedRect: body, xRadius: radius, yRadius: radius).addClip()
    let highlight = NSGradient(colors: [NSColor.white.withAlphaComponent(0.22), NSColor.white.withAlphaComponent(0)])!
    highlight.draw(in: CGRect(x: body.minX, y: body.midY, width: body.width, height: body.height / 2), angle: -90)
    ctx.restoreGState()

    // Viewfinder corners.
    let frame = body.insetBy(dx: body.width * 0.2, dy: body.height * 0.2)
    let arm = frame.width * 0.28
    let stroke = max(1.5, s * 0.045)
    let corners = NSBezierPath()
    corners.lineWidth = stroke
    corners.lineCapStyle = .round
    corners.lineJoinStyle = .round
    // top-left
    corners.move(to: CGPoint(x: frame.minX, y: frame.maxY - arm))
    corners.line(to: CGPoint(x: frame.minX, y: frame.maxY))
    corners.line(to: CGPoint(x: frame.minX + arm, y: frame.maxY))
    // top-right
    corners.move(to: CGPoint(x: frame.maxX - arm, y: frame.maxY))
    corners.line(to: CGPoint(x: frame.maxX, y: frame.maxY))
    corners.line(to: CGPoint(x: frame.maxX, y: frame.maxY - arm))
    // bottom-right
    corners.move(to: CGPoint(x: frame.maxX, y: frame.minY + arm))
    corners.line(to: CGPoint(x: frame.maxX, y: frame.minY))
    corners.line(to: CGPoint(x: frame.maxX - arm, y: frame.minY))
    // bottom-left
    corners.move(to: CGPoint(x: frame.minX + arm, y: frame.minY))
    corners.line(to: CGPoint(x: frame.minX, y: frame.minY))
    corners.line(to: CGPoint(x: frame.minX, y: frame.minY + arm))
    NSColor.white.setStroke()
    corners.stroke()

    // Red annotation circle in the middle.
    let ring = frame.insetBy(dx: frame.width * 0.24, dy: frame.height * 0.3)
    let ellipse = NSBezierPath(ovalIn: ring)
    ellipse.lineWidth = stroke * 0.85
    NSColor(srgbRed: 1.0, green: 0.27, blue: 0.23, alpha: 1).setStroke()
    ctx.saveGState()
    ctx.setShadow(offset: .zero, blur: s * 0.01, color: NSColor.black.withAlphaComponent(0.3).cgColor)
    ellipse.stroke()
    ctx.restoreGState()

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let entries: [(String, Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32), ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256), ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]
for (name, size) in entries {
    try render(size: size).write(to: iconset.appendingPathComponent("\(name).png"))
}

let output = root.appendingPathComponent("Resources/AppIcon.icns")
let task = Process()
task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
task.arguments = ["-c", "icns", iconset.path, "-o", output.path]
try task.run()
task.waitUntilExit()
guard task.terminationStatus == 0 else { fatalError("iconutil failed") }
try render(size: 512).write(to: root.appendingPathComponent("docs/icon.png"))
print("Wrote \(output.path)")
