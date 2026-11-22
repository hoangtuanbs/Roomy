import AppKit

/// Developer option for CI: `RoomyDisk --scan <folder> --tour <dir>` waits for the scan, then saves a PNG of each
/// main screen into <dir> (treemap, rings, Smart Clean, Duplicates, Uninstaller, Space Hunters, Disk overview) and quits.
/// It only opens screens; nothing is ticked, moved or removed.
@MainActor
enum ScreenTour {
    static func run(model: AppModel, into directory: String) {
        watchMainThread()
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

            try? await Task.sleep(for: .seconds(1))
            model.openSpaceHunters()
            await waitWhile({ model.spaceHunters.isBusy }, limit: 40)
            await shot("7-space-hunters", wait: 2.5)
            model.showSpaceHunters = false

            await shot("6-main-after-sheets", wait: 1.5)
            NSApplication.shared.terminate(nil)
        }
    }

    /// Logs when the main thread stops answering for 5 seconds, so a hang on a build machine shows in the log.
    private static func watchMainThread() {
        let thread = Thread {
            while true {
                Thread.sleep(forTimeInterval: 10)
                let answered = DispatchSemaphore(value: 0)
                DispatchQueue.main.async { answered.signal() }
                if answered.wait(timeout: .now() + 5) == .timedOut {
                    FileHandle.standardError.write(Data("tour: the main thread has not answered for 5 seconds\n".utf8))
                }
            }
        }
        thread.start()
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

    /// Draws the window's views into a bitmap. This doesn't go through the window server, so it works on
    /// build machines where screen capture returns blank images.
    private static func capture(_ window: NSWindow) -> CGImage? {
        guard let frameView = window.contentView?.superview,
              let rep = frameView.bitmapImageRepForCachingDisplay(in: frameView.bounds) else { return nil }
        frameView.cacheDisplay(in: frameView.bounds, to: rep)
        return rep.cgImage
    }
}
