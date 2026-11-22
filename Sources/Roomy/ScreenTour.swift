import AppKit

/// Developer option for CI: `Roomy --scan <folder> --tour <dir>` waits for the scan, then saves a PNG of each
/// main screen into <dir> (treemap, rings, Smart Clean, Duplicates, Uninstaller, Disk overview) and quits.
/// It only opens screens; nothing is ticked, moved or removed.
@MainActor
enum ScreenTour {
    static func run(model: AppModel, into directory: String) {
        Task { @MainActor in
            try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
            @MainActor func shot(_ name: String, wait seconds: Double = 2) async {
                try? await Task.sleep(for: .seconds(seconds))
                save(to: (directory as NSString).appendingPathComponent(name + ".png"))
            }
            @MainActor func waitWhile(_ busy: () -> Bool, limit: Double = 60) async {
                let start = Date()
                while busy() && Date().timeIntervalSince(start) < limit {
                    try? await Task.sleep(for: .milliseconds(250))
                }
            }

            try? await Task.sleep(for: .seconds(1))
            await waitWhile { model.state.isScanning || model.isRefreshing }
            NSApplication.shared.activate(ignoringOtherApps: true)

            model.mapStyle = .treemap
            await shot("1-main-treemap")
            model.mapStyle = .rings
            await shot("2-main-rings")
            model.mapStyle = .treemap

            model.openSmartClean()
            await waitWhile { model.smartClean.isBusy }
            await shot("3-smart-clean")
            model.showSmartClean = false

            try? await Task.sleep(for: .seconds(1))
            model.openDuplicates()
            await waitWhile { model.duplicates.isBusy }
            await shot("4-duplicates")
            model.showDuplicates = false

            try? await Task.sleep(for: .seconds(1))
            model.openUninstaller()
            await waitWhile { model.uninstaller.isBusy }
            await shot("5-uninstaller", wait: 3)
            model.showUninstaller = false

            await shot("6-main-after-sheets", wait: 1.5)
            NSApplication.shared.terminate(nil)
        }
    }

    /// Captures the main window by its window number (no screen recording permission is needed for the app's own
    /// windows), and draws an attached sheet on top of it where it sits on screen.
    private static func save(to path: String) {
        guard let window = NSApplication.shared.windows.first(where: { $0.isVisible && $0.canBecomeMain }),
              let base = capture(window) else {
            FileHandle.standardError.write(Data("tour: could not capture \(path)\n".utf8))
            return
        }
        var image = base
        if let sheet = window.attachedSheet, let sheetImage = capture(sheet) {
            let scale = CGFloat(base.width) / window.frame.width
            let size = CGSize(width: base.width, height: base.height)
            if let context = CGContext(data: nil, width: base.width, height: base.height, bitsPerComponent: 8,
                                       bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                       bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) {
                context.draw(base, in: CGRect(origin: .zero, size: size))
                let x = (sheet.frame.minX - window.frame.minX) * scale
                let y = (sheet.frame.minY - window.frame.minY) * scale
                context.draw(sheetImage, in: CGRect(x: x, y: y, width: CGFloat(sheetImage.width), height: CGFloat(sheetImage.height)))
                if let combined = context.makeImage() { image = combined }
            }
        }
        guard let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { return }
        try? data.write(to: URL(fileURLWithPath: path))
        print("tour: saved \(path) (\(image.width)x\(image.height)\(window.attachedSheet == nil ? "" : ", with sheet"))")
    }

    private static func capture(_ window: NSWindow) -> CGImage? {
        typealias CreateImage = @convention(c) (CGRect, CGWindowListOption, CGWindowID, CGWindowImageOption) -> Unmanaged<CGImage>?
        if let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImage"),
           let image = unsafeBitCast(symbol, to: CreateImage.self)(
               .null, .optionIncludingWindow, CGWindowID(window.windowNumber), [.boundsIgnoreFraming, .bestResolution]
           )?.takeRetainedValue() {
            return image
        }
        guard let frameView = window.contentView?.superview,
              let rep = frameView.bitmapImageRepForCachingDisplay(in: frameView.bounds) else { return nil }
        frameView.cacheDisplay(in: frameView.bounds, to: rep)
        return rep.cgImage
    }
}
