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

    /// Captures the screen area of the main window, so sheets attached to it are included.
    private static func save(to path: String) {
        guard let window = NSApplication.shared.windows.first(where: { $0.isVisible && $0.canBecomeMain }) else {
            FileHandle.standardError.write(Data("tour: no visible window for \(path)\n".utf8))
            return
        }
        typealias CreateImage = @convention(c) (CGRect, CGWindowListOption, CGWindowID, CGWindowImageOption) -> Unmanaged<CGImage>?
        let screenHeight = NSScreen.screens.first?.frame.height ?? window.frame.maxY
        let frame = window.frame
        let rect = CGRect(x: frame.minX, y: screenHeight - frame.maxY, width: frame.width, height: frame.height)
        var rep: NSBitmapImageRep?
        if let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImage"),
           let image = unsafeBitCast(symbol, to: CreateImage.self)(rect, .optionOnScreenOnly, kCGNullWindowID, [.bestResolution])?
            .takeRetainedValue() {
            rep = NSBitmapImageRep(cgImage: image)
        } else if let frameView = window.contentView?.superview,
                  let cached = frameView.bitmapImageRepForCachingDisplay(in: frameView.bounds) {
            frameView.cacheDisplay(in: frameView.bounds, to: cached)
            rep = cached
        }
        guard let data = rep?.representation(using: .png, properties: [:]) else {
            FileHandle.standardError.write(Data("tour: could not capture \(path)\n".utf8))
            return
        }
        try? data.write(to: URL(fileURLWithPath: path))
        print("tour: saved \(path)")
    }
}
