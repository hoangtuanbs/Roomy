// Draws Roomy's app icon and writes Resources/AppIcon.icns.
// Usage: swift scripts/make-icon.swift   (run from the package root)
import AppKit

let canvas: CGFloat = 1024

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

func lighter(_ c: NSColor, _ amount: CGFloat) -> NSColor {
    c.blended(withFraction: amount, of: .white) ?? c
}

func drawIcon() -> NSImage {
    let image = NSImage(size: NSSize(width: canvas, height: canvas))
    image.lockFocus()
    defer { image.unlockFocus() }

    // macOS icon grid: an 824 pt rounded square centred on the 1024 canvas.
    let body = NSRect(x: 100, y: 100, width: 824, height: 824)
    let squircle = NSBezierPath(roundedRect: body, xRadius: 185, yRadius: 185)

    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
    shadow.shadowOffset = NSSize(width: 0, height: -14)
    shadow.shadowBlurRadius = 28
    shadow.set()
    color(0x2B2F8F).setFill()
    squircle.fill()
    NSGraphicsContext.restoreGraphicsState()

    NSGraphicsContext.saveGraphicsState()
    squircle.addClip()
    NSGradient(colors: [color(0x6A7BFF), color(0x4B4FD8), color(0x2A2C8A)],
               atLocations: [0, 0.5, 1], colorSpace: .sRGB)!
        .draw(in: body, angle: -90)
    // Soft glow in the top-left corner.
    NSGradient(colors: [NSColor.white.withAlphaComponent(0.28), NSColor.white.withAlphaComponent(0)])!
        .draw(fromCenter: NSPoint(x: 300, y: 860), radius: 0, toCenter: NSPoint(x: 300, y: 860), radius: 560, options: [])
    NSGraphicsContext.restoreGraphicsState()

    // A few treemap tiles above the drive: what fills the disk.
    let tiles: [(CGFloat, CGFloat, UInt32)] = [(232, 248, 0xFF6B7A), (500, 164, 0xFFB547), (684, 108, 0x3FD6A6)]
    for (x, width, hex) in tiles {
        drawTile(NSRect(x: x, y: 640, width: width, height: 150), color(hex), radius: 30)
    }

    drawHardDisk(in: NSRect(x: 192, y: 262, width: 640, height: 300))

    // Gloss along the top edge of the icon.
    NSGraphicsContext.saveGraphicsState()
    squircle.addClip()
    NSGradient(colors: [NSColor.white.withAlphaComponent(0.18), NSColor.white.withAlphaComponent(0)])!
        .draw(in: NSRect(x: body.minX, y: body.maxY - 180, width: body.width, height: 180), angle: -90)
    NSGraphicsContext.restoreGraphicsState()

    return image
}

func drawTile(_ rect: NSRect, _ base: NSColor, radius: CGFloat) {
    let path = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.22)
    shadow.shadowOffset = NSSize(width: 0, height: -5)
    shadow.shadowBlurRadius = 10
    shadow.set()
    base.setFill()
    path.fill()
    NSGraphicsContext.restoreGraphicsState()

    NSGraphicsContext.saveGraphicsState()
    path.addClip()
    NSGradient(starting: lighter(base, 0.25), ending: base)!.draw(in: rect, angle: -90)
    NSGraphicsContext.restoreGraphicsState()
}

/// A silver drive seen slightly from the front, with a disk-space bar and an activity light.
func drawHardDisk(in rect: NSRect) {
    let radius: CGFloat = 54
    let depth: CGFloat = 30

    // Underside, visible below the front face, with the drop shadow.
    let under = NSBezierPath(roundedRect: rect.offsetBy(dx: 0, dy: -depth), xRadius: radius, yRadius: radius)
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.45)
    shadow.shadowOffset = NSSize(width: 0, height: -16)
    shadow.shadowBlurRadius = 30
    shadow.set()
    color(0x6E7789).setFill()
    under.fill()
    NSGraphicsContext.restoreGraphicsState()
    NSGraphicsContext.saveGraphicsState()
    under.addClip()
    NSGradient(starting: color(0x8A93A6), ending: color(0x555D6E))!.draw(in: rect.offsetBy(dx: 0, dy: -depth), angle: -90)
    NSGraphicsContext.restoreGraphicsState()

    // Brushed aluminium front face.
    let face = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
    NSGraphicsContext.saveGraphicsState()
    face.addClip()
    NSGradient(colors: [color(0xFBFCFE), color(0xE1E6EE), color(0xC3CAD7)],
               atLocations: [0, 0.5, 1], colorSpace: .sRGB)!.draw(in: rect, angle: -90)
    for i in stride(from: 0, to: Int(rect.height), by: 5) {
        NSColor.white.withAlphaComponent(i % 10 == 0 ? 0.07 : 0.03).setFill()
        NSRect(x: rect.minX, y: rect.minY + CGFloat(i), width: rect.width, height: 2).fill()
    }
    NSGraphicsContext.restoreGraphicsState()
    let bevel = NSBezierPath(roundedRect: rect.insetBy(dx: 2, dy: 2), xRadius: radius - 2, yRadius: radius - 2)
    NSColor.white.setStroke()
    bevel.lineWidth = 4
    bevel.stroke()

    // Disk-space bar: used space in the category colours, then free space.
    let bar = NSRect(x: rect.minX + 56, y: rect.midY - 44, width: rect.width - 188, height: 88)
    let track = NSBezierPath(roundedRect: bar, xRadius: 44, yRadius: 44)
    NSGraphicsContext.saveGraphicsState()
    let inset = NSShadow()
    inset.shadowColor = NSColor.white.withAlphaComponent(0.9)
    inset.shadowOffset = NSSize(width: 0, height: -3)
    inset.shadowBlurRadius = 0
    inset.set()
    color(0x262A40).setFill()
    track.fill()
    NSGraphicsContext.restoreGraphicsState()

    NSGraphicsContext.saveGraphicsState()
    track.addClip()
    let segments: [(CGFloat, UInt32)] = [
        (0.24, 0xFF6B7A), (0.14, 0xFFB547), (0.12, 0x3FD6A6), (0.11, 0x4DB8FF), (0.09, 0xA88BFF),
    ]
    var x = bar.minX
    for (fraction, hex) in segments {
        let segment = NSRect(x: x, y: bar.minY, width: bar.width * fraction, height: bar.height)
        NSGradient(starting: lighter(color(hex), 0.3), ending: color(hex))!.draw(in: segment, angle: -90)
        x += segment.width
    }
    // Glass highlight on the bar.
    NSGradient(colors: [NSColor.white.withAlphaComponent(0.35), NSColor.white.withAlphaComponent(0)])!
        .draw(in: NSRect(x: bar.minX, y: bar.midY, width: bar.width, height: bar.height / 2), angle: -90)
    NSGraphicsContext.restoreGraphicsState()

    // The space you get back.
    drawSparkle(center: NSPoint(x: x + 50, y: bar.midY), radius: 34)

    // Activity light.
    let led = NSRect(x: rect.maxX - 98, y: bar.midY - 20, width: 40, height: 40)
    NSGraphicsContext.saveGraphicsState()
    let glow = NSShadow()
    glow.shadowColor = color(0x3DFF9A, 0.9)
    glow.shadowBlurRadius = 20
    glow.set()
    color(0x2EE88A).setFill()
    NSBezierPath(ovalIn: led).fill()
    NSGraphicsContext.restoreGraphicsState()
    NSColor.white.withAlphaComponent(0.75).setFill()
    NSBezierPath(ovalIn: NSRect(x: led.minX + 10, y: led.midY + 3, width: 13, height: 10)).fill()

    // Screws in the corners of the face.
    for (sx, sy) in [(rect.minX + 32, rect.maxY - 32), (rect.maxX - 32, rect.maxY - 32),
                     (rect.minX + 32, rect.minY + 32), (rect.maxX - 32, rect.minY + 32)] {
        let screw = NSRect(x: sx - 9, y: sy - 9, width: 18, height: 18)
        NSGradient(starting: color(0x9AA3B4), ending: color(0xF2F4F8))!.draw(in: NSBezierPath(ovalIn: screw), angle: 90)
    }
}

func drawSparkle(center: NSPoint, radius r: CGFloat) {
    let path = NSBezierPath()
    let waist = r * 0.22
    path.move(to: NSPoint(x: center.x, y: center.y + r))
    path.curve(to: NSPoint(x: center.x + r, y: center.y),
               controlPoint1: NSPoint(x: center.x + waist, y: center.y + waist),
               controlPoint2: NSPoint(x: center.x + waist, y: center.y + waist))
    path.curve(to: NSPoint(x: center.x, y: center.y - r),
               controlPoint1: NSPoint(x: center.x + waist, y: center.y - waist),
               controlPoint2: NSPoint(x: center.x + waist, y: center.y - waist))
    path.curve(to: NSPoint(x: center.x - r, y: center.y),
               controlPoint1: NSPoint(x: center.x - waist, y: center.y - waist),
               controlPoint2: NSPoint(x: center.x - waist, y: center.y - waist))
    path.curve(to: NSPoint(x: center.x, y: center.y + r),
               controlPoint1: NSPoint(x: center.x - waist, y: center.y + waist),
               controlPoint2: NSPoint(x: center.x - waist, y: center.y + waist))
    path.close()
    NSGraphicsContext.saveGraphicsState()
    let glow = NSShadow()
    glow.shadowColor = NSColor.white.withAlphaComponent(0.8)
    glow.shadowBlurRadius = r * 0.35
    glow.set()
    NSColor.white.setFill()
    path.fill()
    NSGraphicsContext.restoreGraphicsState()
}

func png(_ image: NSImage, size: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: size, height: size)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current?.imageInterpolation = .high
    image.draw(in: NSRect(x: 0, y: 0, width: size, height: size))
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let fm = FileManager.default
let iconset = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("Roomy-\(UUID().uuidString).iconset")
try fm.createDirectory(at: iconset, withIntermediateDirectories: true)
defer { try? fm.removeItem(at: iconset) }

let icon = drawIcon()
for base in [16, 32, 128, 256, 512] {
    try png(icon, size: base).write(to: iconset.appendingPathComponent("icon_\(base)x\(base).png"))
    try png(icon, size: base * 2).write(to: iconset.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
try fm.createDirectory(atPath: "Resources", withIntermediateDirectories: true)
try png(icon, size: 1024).write(to: URL(fileURLWithPath: "Resources/AppIcon-1024.png"))

let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", "Resources/AppIcon.icns"]
try iconutil.run()
iconutil.waitUntilExit()
guard iconutil.terminationStatus == 0 else {
    FileHandle.standardError.write(Data("iconutil failed\n".utf8))
    exit(1)
}
print("Wrote Resources/AppIcon.icns")
