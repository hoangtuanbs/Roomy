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

    drawDisk(center: NSPoint(x: 500, y: 548), radius: 318, tilt: 0.6, thickness: 40)

    // Gloss along the top edge of the icon.
    NSGraphicsContext.saveGraphicsState()
    squircle.addClip()
    NSGradient(colors: [NSColor.white.withAlphaComponent(0.18), NSColor.white.withAlphaComponent(0)])!
        .draw(in: NSRect(x: body.minX, y: body.maxY - 180, width: body.width, height: 180), angle: -90)
    NSGraphicsContext.restoreGraphicsState()

    return image
}

/// A hard-disk platter tilted back in perspective, with a raised disk-space ring and a read arm.
func drawDisk(center c: NSPoint, radius r: CGFloat, tilt: CGFloat, thickness t: CGFloat) {
    // Maps a point on the flat platter to the tilted view.
    func project(_ p: NSPoint, lift: CGFloat = 0) -> NSPoint {
        NSPoint(x: p.x, y: c.y + (p.y - c.y) * tilt + lift)
    }
    func ellipse(_ center: NSPoint, _ radius: CGFloat) -> NSBezierPath {
        NSBezierPath(ovalIn: NSRect(x: center.x - radius, y: center.y - radius * tilt,
                                    width: radius * 2, height: radius * 2 * tilt))
    }
    func circle(_ radius: CGFloat) -> NSBezierPath {
        NSBezierPath(ovalIn: NSRect(x: c.x - radius, y: c.y - radius, width: radius * 2, height: radius * 2))
    }
    /// A short metal cylinder seen from the same angle: side wall from `base` up by `height`.
    func cylinderSide(_ base: NSPoint, radius: CGFloat, height: CGFloat) -> NSBezierPath {
        let side = ellipse(base, radius)
        side.append(NSBezierPath(rect: NSRect(x: base.x - radius, y: base.y, width: radius * 2, height: height)))
        return side
    }
    let metalSide = NSGradient(colors: [color(0x4B5265), color(0xA7AFBF), color(0xF3F5F9), color(0xB9C0CD), color(0x596074)],
                               atLocations: [0, 0.25, 0.45, 0.7, 1], colorSpace: .sRGB)!

    // Platter edge, which also casts the shadow onto the background.
    let edge = cylinderSide(NSPoint(x: c.x, y: c.y - t), radius: r, height: t)
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.5)
    shadow.shadowOffset = NSSize(width: 0, height: -34)
    shadow.shadowBlurRadius = 40
    shadow.set()
    color(0x6E7789).setFill()
    edge.fill()
    NSGraphicsContext.restoreGraphicsState()
    metalSide.draw(in: edge, angle: 0)

    // Top face, drawn flat and squashed into perspective.
    NSGraphicsContext.saveGraphicsState()
    let transform = NSAffineTransform()
    transform.translateX(by: c.x, yBy: c.y)
    transform.scaleX(by: 1, yBy: tilt)
    transform.translateX(by: -c.x, yBy: -c.y)
    transform.concat()

    let disc = circle(r)
    NSGraphicsContext.saveGraphicsState()
    disc.addClip()
    NSGradient(colors: [color(0xFAFBFD), color(0xD5DBE5), color(0xA2AABB)],
               atLocations: [0, 0.55, 1], colorSpace: .sRGB)!
        .draw(fromCenter: NSPoint(x: c.x - r * 0.3, y: c.y + r * 0.45), radius: 0, toCenter: c, radius: r * 1.05, options: [])
    // Soft light streaks radiating from the centre, as on a polished platter.
    for (angle, white) in [(CGFloat(40), true), (220, true), (130, false), (310, false)] {
        for step in 0..<8 {
            let spread = 30 - CGFloat(step) * 3.5
            let wedge = NSBezierPath()
            wedge.move(to: c)
            wedge.appendArc(withCenter: c, radius: r, startAngle: angle - spread, endAngle: angle + spread)
            wedge.close()
            (white ? NSColor.white.withAlphaComponent(0.08) : color(0x4A5266, 0.03)).setFill()
            wedge.fill()
        }
    }
    for track in stride(from: CGFloat(100), to: r - 76, by: 9) {
        let ring = circle(track)
        NSColor.black.withAlphaComponent(0.035).setStroke()
        ring.lineWidth = 1.5
        ring.stroke()
    }
    NSGraphicsContext.restoreGraphicsState()
    let lip = circle(r - 2)
    NSColor.white.withAlphaComponent(0.9).setStroke()
    lip.lineWidth = 4
    lip.stroke()

    // Disk-space ring in three segments (red used, grey system, green free), raised off the platter:
    // a darker wall first, then the top.
    let ringRadius = r - 46
    let ringWidth: CGFloat = 58
    let wall = 14 / tilt
    let segments: [(CGFloat, UInt32)] = [
        (0.08, 0xFF4D5E), // red: a small slice of used space
        (0.62, 0x5E6579), // grey: system and other (deep slate, so it stands out from the silver)
        (0.30, 0x34D399), // green: free space
    ]
    let used: CGFloat = 0.70 // where the free (green) segment starts
    func arc(_ from: CGFloat, _ to: CGFloat, dy: CGFloat = 0, radius: CGFloat? = nil, width: CGFloat = ringWidth) -> NSBezierPath {
        let path = NSBezierPath()
        path.appendArc(withCenter: NSPoint(x: c.x, y: c.y + dy), radius: radius ?? ringRadius,
                       startAngle: from, endAngle: to, clockwise: true)
        path.lineWidth = width
        return path
    }
    let gap: CGFloat = 3
    for dy in Array(stride(from: -wall, to: 0, by: 2)) + [0] {
        let top = dy == 0
        var angle: CGFloat = 90
        for (fraction, hex) in segments {
            let end = angle - fraction * 360
            (top ? color(hex) : color(hex).blended(withFraction: 0.4, of: .black)!).setStroke()
            arc(angle - gap / 2, end + gap / 2, dy: dy).stroke()
            angle = end
        }
    }
    var angle: CGFloat = 90
    for (fraction, hex) in segments {
        let end = angle - fraction * 360
        lighter(color(hex), 0.4).setStroke()
        arc(angle - gap / 2, end + gap / 2, radius: ringRadius + ringWidth * 0.32, width: ringWidth * 0.22).stroke()
        angle = end
    }
    NSGraphicsContext.restoreGraphicsState()

    // The space you get back, in the free part of the ring (drawn upright, not squashed).
    let sparkleAngle = (90 - used * 360 - 40) * .pi / 180
    drawSparkle(center: project(NSPoint(x: c.x + ringRadius * cos(sparkleAngle), y: c.y + ringRadius * sin(sparkleAngle))),
                radius: 40)

    // Raised spindle hub.
    let hubHeight: CGFloat = 26
    metalSide.draw(in: cylinderSide(c, radius: 82, height: hubHeight), angle: 0)
    let hubTop = NSPoint(x: c.x, y: c.y + hubHeight)
    NSGradient(starting: color(0xFFFFFF), ending: color(0xAEB6C5))!.draw(in: ellipse(hubTop, 82), angle: -70)
    for i in 0..<6 {
        let a = CGFloat(i) * .pi / 3 + .pi / 6
        let dot = NSPoint(x: hubTop.x + 56 * cos(a), y: hubTop.y + 56 * sin(a) * tilt)
        NSGradient(starting: color(0x7D869A), ending: color(0xE9EDF3))!
            .draw(in: NSBezierPath(ovalIn: NSRect(x: dot.x - 8, y: dot.y - 6, width: 16, height: 12)), angle: 90)
    }
    NSGradient(starting: color(0x3A4054), ending: color(0x14172A))!.draw(in: ellipse(hubTop, 26), angle: -90)

    // Read/write arm on a bearing at the bottom right, floating above the platter.
    let bearing = NSPoint(x: 812, y: 236)
    let bearingHeight: CGFloat = 56
    let armLift: CGFloat = 50
    let pivot = NSPoint(x: bearing.x, y: bearing.y + bearingHeight)
    let headOnDisk = project(NSPoint(x: c.x + 118, y: c.y - 140))
    let head = NSPoint(x: headOnDisk.x, y: headOnDisk.y + armLift)

    // Shadow of the arm on the platter.
    NSGraphicsContext.saveGraphicsState()
    let armShadow = NSShadow()
    armShadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
    armShadow.shadowBlurRadius = 14
    armShadow.shadowOffset = .zero
    armShadow.set()
    let shadowPath = NSBezierPath()
    shadowPath.move(to: NSPoint(x: bearing.x - 10, y: bearing.y + 6))
    shadowPath.line(to: NSPoint(x: headOnDisk.x + 18, y: headOnDisk.y - 20))
    shadowPath.lineWidth = 24
    shadowPath.lineCapStyle = .round
    NSColor.black.withAlphaComponent(0.22).setStroke()
    shadowPath.stroke()
    NSGraphicsContext.restoreGraphicsState()

    // Bearing: a short cylinder.
    NSGraphicsContext.saveGraphicsState()
    let bearingShadow = NSShadow()
    bearingShadow.shadowColor = NSColor.black.withAlphaComponent(0.45)
    bearingShadow.shadowOffset = NSSize(width: 0, height: -14)
    bearingShadow.shadowBlurRadius = 18
    bearingShadow.set()
    color(0x7D869A).setFill()
    cylinderSide(bearing, radius: 58, height: bearingHeight).fill()
    NSGraphicsContext.restoreGraphicsState()
    metalSide.draw(in: cylinderSide(bearing, radius: 58, height: bearingHeight), angle: 0)
    NSGradient(starting: color(0xFFFFFF), ending: color(0xA3ABBB))!.draw(in: ellipse(pivot, 58), angle: -70)

    // Arm: a dark underside and a bright top give it a rounded, metal look.
    for (width, hex, dy) in [(CGFloat(34), UInt32(0x5D6578), CGFloat(-6)), (30, 0xC4CBD8, 0), (12, 0xFFFFFF, 6)] {
        let arm = NSBezierPath()
        arm.move(to: NSPoint(x: pivot.x, y: pivot.y + dy))
        arm.line(to: NSPoint(x: head.x, y: head.y + dy))
        arm.lineWidth = width
        arm.lineCapStyle = .round
        (hex == 0xFFFFFF ? NSColor.white.withAlphaComponent(0.75) : color(hex)).setStroke()
        arm.stroke()
    }
    let headRect = NSRect(x: head.x - 28, y: head.y - 20, width: 56, height: 40)
    NSGradient(starting: color(0xEEF1F6), ending: color(0x8C95A8))!
        .draw(in: NSBezierPath(roundedRect: headRect, xRadius: 12, yRadius: 12), angle: -90)
    NSGradient(starting: color(0x3A4054), ending: color(0x14172A))!.draw(in: ellipse(pivot, 22), angle: -90)
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
