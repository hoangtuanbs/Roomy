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

    drawPlatter(center: NSPoint(x: 494, y: 530), radius: 306)
    drawArm(pivot: NSPoint(x: 800, y: 232), head: NSPoint(x: 590, y: 452))

    // Gloss along the top edge of the icon.
    NSGraphicsContext.saveGraphicsState()
    squircle.addClip()
    NSGradient(colors: [NSColor.white.withAlphaComponent(0.18), NSColor.white.withAlphaComponent(0)])!
        .draw(in: NSRect(x: body.minX, y: body.maxY - 180, width: body.width, height: 180), angle: -90)
    NSGraphicsContext.restoreGraphicsState()

    return image
}

/// A hard-disk platter seen from above, with a disk-space ring around its rim.
func drawPlatter(center c: NSPoint, radius r: CGFloat) {
    func circle(_ radius: CGFloat) -> NSBezierPath {
        NSBezierPath(ovalIn: NSRect(x: c.x - radius, y: c.y - radius, width: radius * 2, height: radius * 2))
    }

    // Metal disc with a drop shadow.
    let disc = circle(r)
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.45)
    shadow.shadowOffset = NSSize(width: 0, height: -16)
    shadow.shadowBlurRadius = 30
    shadow.set()
    color(0xC3CAD7).setFill()
    disc.fill()
    NSGraphicsContext.restoreGraphicsState()

    NSGraphicsContext.saveGraphicsState()
    disc.addClip()
    NSGradient(colors: [color(0xF4F6FA), color(0xD3D9E3), color(0xA9B1C1)],
               atLocations: [0, 0.6, 1], colorSpace: .sRGB)!
        .draw(fromCenter: NSPoint(x: c.x - r * 0.25, y: c.y + r * 0.3), radius: 0, toCenter: c, radius: r, options: [])
    // Anisotropic sheen: soft light streaks radiating from the centre, as on a polished platter.
    for (angle, white) in [(CGFloat(40), true), (220, true), (130, false), (310, false)] {
        for step in 0..<8 {
            let spread = 30 - CGFloat(step) * 3.5
            let wedge = NSBezierPath()
            wedge.move(to: c)
            wedge.appendArc(withCenter: c, radius: r, startAngle: angle - spread, endAngle: angle + spread)
            wedge.close()
            (white ? NSColor.white.withAlphaComponent(0.07) : color(0x4A5266, 0.025)).setFill()
            wedge.fill()
        }
    }
    // Concentric tracks.
    for track in stride(from: CGFloat(96), to: r - 70, by: 9) {
        let ring = circle(track)
        NSColor.black.withAlphaComponent(0.035).setStroke()
        ring.lineWidth = 1.5
        ring.stroke()
    }
    NSGraphicsContext.restoreGraphicsState()
    let rim = circle(r - 3)
    color(0x7C8599).setStroke()
    rim.lineWidth = 6
    rim.stroke()
    let edge = circle(r - 8)
    NSColor.white.withAlphaComponent(0.7).setStroke()
    edge.lineWidth = 2
    edge.stroke()

    // Disk-space ring: used space in the category colours, clockwise from the top, then free space.
    let ringRadius = r - 42
    let ringWidth: CGFloat = 54
    let track = NSBezierPath()
    track.appendArc(withCenter: c, radius: ringRadius, startAngle: 0, endAngle: 360)
    track.lineWidth = ringWidth
    color(0x262A40).setStroke()
    track.stroke()

    let segments: [(CGFloat, UInt32)] = [
        (0.24, 0xFF6B7A), (0.15, 0xFFB547), (0.12, 0x3FD6A6), (0.11, 0x4DB8FF), (0.08, 0xA88BFF),
    ]
    let gap: CGFloat = 3
    var angle: CGFloat = 90
    for (fraction, hex) in segments {
        let end = angle - fraction * 360
        let arc = NSBezierPath()
        arc.appendArc(withCenter: c, radius: ringRadius, startAngle: angle - gap / 2, endAngle: end + gap / 2, clockwise: true)
        arc.lineWidth = ringWidth
        color(hex).setStroke()
        arc.stroke()
        // Brighter outer edge for a glassy look.
        let shine = NSBezierPath()
        shine.appendArc(withCenter: c, radius: ringRadius + ringWidth * 0.3, startAngle: angle - gap / 2, endAngle: end + gap / 2, clockwise: true)
        shine.lineWidth = ringWidth * 0.25
        lighter(color(hex), 0.35).setStroke()
        shine.stroke()
        angle = end
    }

    // The space you get back, at the start of the free arc.
    let sparkleAngle = (angle - 40) * .pi / 180
    drawSparkle(center: NSPoint(x: c.x + ringRadius * cos(sparkleAngle), y: c.y + ringRadius * sin(sparkleAngle)), radius: 38)

    // Spindle hub.
    let hub = circle(78)
    NSGraphicsContext.saveGraphicsState()
    let hubShadow = NSShadow()
    hubShadow.shadowColor = NSColor.black.withAlphaComponent(0.3)
    hubShadow.shadowOffset = NSSize(width: 0, height: -4)
    hubShadow.shadowBlurRadius = 10
    hubShadow.set()
    color(0xDCE1EA).setFill()
    hub.fill()
    NSGraphicsContext.restoreGraphicsState()
    NSGradient(starting: color(0xFFFFFF), ending: color(0xA3ABBB))!.draw(in: hub, angle: -60)
    for i in 0..<6 {
        let a = CGFloat(i) * .pi / 3 + .pi / 6
        let screw = NSRect(x: c.x + 52 * cos(a) - 7, y: c.y + 52 * sin(a) - 7, width: 14, height: 14)
        NSGradient(starting: color(0x8A93A6), ending: color(0xE9EDF3))!.draw(in: NSBezierPath(ovalIn: screw), angle: 90)
    }
    NSGradient(starting: color(0x3A4054), ending: color(0x1E2233))!.draw(in: circle(24), angle: -90)
}

/// The read/write arm, from its pivot to the head resting on the platter.
func drawArm(pivot: NSPoint, head: NSPoint) {
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.4)
    shadow.shadowOffset = NSSize(width: 6, height: -10)
    shadow.shadowBlurRadius = 14
    shadow.set()

    let arm = NSBezierPath()
    arm.move(to: pivot)
    arm.line(to: head)
    arm.lineWidth = 30
    arm.lineCapStyle = .round
    color(0xB7BFCD).setStroke()
    arm.stroke()

    let headRect = NSRect(x: head.x - 24, y: head.y - 24, width: 48, height: 48)
    color(0xC9D0DC).setFill()
    NSBezierPath(roundedRect: headRect, xRadius: 12, yRadius: 12).fill()

    let base = NSRect(x: pivot.x - 50, y: pivot.y - 50, width: 100, height: 100)
    color(0xC9D0DC).setFill()
    NSBezierPath(ovalIn: base).fill()
    NSGraphicsContext.restoreGraphicsState()

    // Metal finish on top of the shadowed shapes.
    let highlight = NSBezierPath()
    highlight.move(to: NSPoint(x: pivot.x - 4, y: pivot.y + 6))
    highlight.line(to: NSPoint(x: head.x - 4, y: head.y + 6))
    highlight.lineWidth = 10
    highlight.lineCapStyle = .round
    NSColor.white.withAlphaComponent(0.6).setStroke()
    highlight.stroke()
    NSGradient(starting: color(0xFFFFFF), ending: color(0x9EA7B8))!
        .draw(in: NSBezierPath(ovalIn: NSRect(x: pivot.x - 50, y: pivot.y - 50, width: 100, height: 100)), angle: -60)
    NSGradient(starting: color(0x3A4054), ending: color(0x1E2233))!
        .draw(in: NSBezierPath(ovalIn: NSRect(x: pivot.x - 18, y: pivot.y - 18, width: 36, height: 36)), angle: -90)
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
