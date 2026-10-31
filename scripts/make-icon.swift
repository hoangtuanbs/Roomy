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

    // Frosted panel that holds the treemap.
    let panel = NSRect(x: 190, y: 190, width: 644, height: 644)
    let panelPath = NSBezierPath(roundedRect: panel, xRadius: 74, yRadius: 74)
    NSColor.white.withAlphaComponent(0.13).setFill()
    panelPath.fill()
    NSColor.white.withAlphaComponent(0.22).setStroke()
    panelPath.lineWidth = 3
    panelPath.stroke()

    // Treemap tiles in unit coordinates (origin bottom-left), in the app's category colours.
    let tiles: [(CGFloat, CGFloat, CGFloat, CGFloat, UInt32)] = [
        (0.00, 0.40, 0.60, 0.60, 0xFF6B7A), // video
        (0.60, 0.64, 0.40, 0.36, 0xFFB547), // audio
        (0.60, 0.40, 0.40, 0.24, 0x3FD6A6), // images
        (0.00, 0.00, 0.34, 0.40, 0x4DB8FF), // folders
        (0.34, 0.00, 0.36, 0.40, 0xA88BFF), // archives
        (0.70, 0.20, 0.30, 0.20, 0xFFD84D), // developer
        (0.70, 0.00, 0.30, 0.20, 0x5EE0F0), // apps
    ]
    let inner = panel.insetBy(dx: 34, dy: 34)
    let gap: CGFloat = 20
    for (x, y, w, h, hex) in tiles {
        let rect = NSRect(x: inner.minX + x * inner.width + gap / 2,
                          y: inner.minY + y * inner.height + gap / 2,
                          width: w * inner.width - gap,
                          height: h * inner.height - gap)
        let path = NSBezierPath(roundedRect: rect, xRadius: 30, yRadius: 30)

        NSGraphicsContext.saveGraphicsState()
        let tileShadow = NSShadow()
        tileShadow.shadowColor = NSColor.black.withAlphaComponent(0.22)
        tileShadow.shadowOffset = NSSize(width: 0, height: -5)
        tileShadow.shadowBlurRadius = 10
        tileShadow.set()
        color(hex).setFill()
        path.fill()
        NSGraphicsContext.restoreGraphicsState()

        NSGraphicsContext.saveGraphicsState()
        path.addClip()
        let base = color(hex)
        NSGradient(starting: lighter(base, 0.25), ending: base)!.draw(in: rect, angle: -90)
        NSGraphicsContext.restoreGraphicsState()
    }

    // A sparkle on the biggest tile: the space you get back.
    let big = NSRect(x: inner.minX + gap / 2, y: inner.minY + 0.40 * inner.height + gap / 2,
                     width: 0.60 * inner.width - gap, height: 0.60 * inner.height - gap)
    drawSparkle(center: NSPoint(x: big.midX, y: big.midY), radius: 92)
    drawSparkle(center: NSPoint(x: big.midX + 92, y: big.midY + 78), radius: 34)

    // Gloss along the top edge of the icon.
    NSGraphicsContext.saveGraphicsState()
    squircle.addClip()
    NSGradient(colors: [NSColor.white.withAlphaComponent(0.18), NSColor.white.withAlphaComponent(0)])!
        .draw(in: NSRect(x: body.minX, y: body.maxY - 180, width: body.width, height: 180), angle: -90)
    NSGraphicsContext.restoreGraphicsState()

    return image
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
