import AppKit
import RoomyCore
import SwiftUI

/// Developer option for CI: `RoomyDisk --scan <folder> --tour <dir>` waits for the scan, then saves a PNG of each
/// main screen into <dir> (treemap, rings, Smart Clean, Duplicates, Uninstaller, Space Hunters, Cloud Space, Disk Health, Disk overview,
/// the menu bar popover with Quick Clean, and each Settings tab) and quits.
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
            model.uninstaller.section = .loginItems
            await waitWhile({ !model.loginItems.loaded }, limit: 30)
            await shot("17-login-items", wait: 2)
            model.uninstaller.section = .installers
            await waitWhile({ !model.receipts.loaded }, limit: 60)
            await shot("18-installers", wait: 2)
            model.uninstaller.section = .updates
            await shot("19-updates", wait: 2)
            model.uninstaller.section = .apps
            model.showUninstaller = false

            try? await Task.sleep(for: .seconds(1))
            model.openSpaceHunters()
            await waitWhile({ model.spaceHunters.isBusy }, limit: 40)
            await shot("7-space-hunters", wait: 2.5)
            model.showSpaceHunters = false

            try? await Task.sleep(for: .seconds(1))
            model.openCloudSpace()
            await waitWhile({ model.cloudSpace.isBusy }, limit: 40)
            await shot("8-cloud-space", wait: 2)
            model.showCloudSpace = false

            try? await Task.sleep(for: .seconds(1))
            model.openDiskHealth()
            await waitWhile({ model.diskHealth.isBusy }, limit: 40)
            for report in model.diskHealth.reports {
                print("tour: disk health \(report.id) \(report.name): \(report.verdict.title), SMART \(report.smart.title), "
                      + "\(report.interconnect ?? "?"), internal \(report.isInternal.map { $0 ? "yes" : "no" } ?? "?"), volumes \(report.volumeNames)")
            }
            await shot("12-disk-health", wait: 2.5)
            model.showDiskHealth = false

            await accuracyShots(model: model, shot: shot)

            await menuBarShots(model: model, directory: directory)

            await shot("6-main-after-sheets", wait: 1.5)
            NSApplication.shared.terminate(nil)
        }
    }

    /// A clone selected in the list, with what it shares in the caption, and the disk overview after "Free Purgeable
    /// Space", run with a pretend releaser so macOS is never asked to free anything.
    private static func accuracyShots(model: AppModel, shot: @MainActor (String, Double) async -> Void) async {
        if let tree = model.tree,
           let clone = (0..<ScanTree.Index(tree.count)).first(where: { tree.flags($0).contains(.clone) && tree.clones[$0]?.carriesShared == false }) {
            if let folder = tree.parent(clone) { model.open(folder) }
            try? await Task.sleep(for: .seconds(0.5))
            model.selection = clone
            print("tour: clone \(tree.path(of: clone)): \(SpaceNotes.clone(clone, in: tree))")
            await shot("15-clone-detail", 1.5)
            model.selection = nil
            model.goUp()
        } else {
            print("tour: no clone in the scan")
            await shot("15-clone-detail", 0.5)
        }

        let disk = model.diskOverview
        disk.releaser = RehearsalReleaser()
        model.refreshDiskOverview()
        try? await Task.sleep(for: .seconds(1))
        disk.freePurgeable(scanned: model.scannedBytes)
        let start = Date()
        while !(disk.purge != .idle && !disk.purge.isRunning) && Date().timeIntervalSince(start) < 20 {
            try? await Task.sleep(for: .milliseconds(250))
        }
        print("tour: free purgeable space: \(disk.purge)")
        await shot("16-purgeable-freed", 2)
        disk.dismissPurgeResult()
        disk.releaser = TimeMachineThinner()
    }

    /// The menu bar popover after one background check and its Quick Clean confirmation, each shown in a
    /// plain window because the menu bar can't be captured, then Settings. The confirmation is only shown and then
    /// cancelled.
    private static func menuBarShots(model: AppModel, directory: String) async {
        try? await Task.sleep(for: .seconds(1))
        model.autoCheck.check()
        let start = Date()
        while model.autoCheck.isChecking && Date().timeIntervalSince(start) < 40 {
            try? await Task.sleep(for: .milliseconds(250))
        }
        print("tour: background check found \(model.autoCheck.reclaimable) bytes in \(model.autoCheck.quickCleanItems.count) items")
        func path(_ name: String) -> String { (directory as NSString).appendingPathComponent(name + ".png") }

        let popover = hostingWindow(MenuBarView().environment(model).environment(MenuBarDiskModel()), title: "RoomyDisk menu bar")
        try? await Task.sleep(for: .seconds(2))
        save(to: path("9-menu-bar"), window: popover)
        if !model.autoCheck.quickCleanItems.isEmpty {
            model.autoCheck.askToClean()
            try? await Task.sleep(for: .seconds(1.5))
            save(to: path("10-menu-bar-confirm"), window: popover)
            model.autoCheck.cancelClean()
        }
        popover.close()

        await settingsShots(path: path)
    }

    /// The real Settings window, opened through the RoomyDisk menu as a click on Settings… would, on each tab.
    private static func settingsShots(path: (String) -> String) async {
        let defaults = AppEnvironment.defaults
        let tabs: [(AlertSettingsView.Tab, String)] = [(.general, "11-settings"), (.checks, "13-settings-checks"),
                                                       (.updates, "14-settings-updates")]
        defaults.set(AlertSettingsView.Tab.general.rawValue, forKey: AlertSettingsView.tabKey)
        let before = Set(NSApplication.shared.windows.map(ObjectIdentifier.init))
        if let menu = NSApplication.shared.mainMenu?.items.first?.submenu,
           let index = menu.items.firstIndex(where: { $0.keyEquivalent == "," }) {
            menu.performActionForItem(at: index)
        }
        try? await Task.sleep(for: .seconds(1.5))
        let windows = NSApplication.shared.windows
        print("tour: windows \(windows.map { "\($0.identifier?.rawValue ?? "-") \($0.isVisible ? "visible" : "hidden")" })")
        guard let settings = windows.first(where: {
            $0.isVisible && (!before.contains(ObjectIdentifier($0)) || $0.identifier?.rawValue.contains("Settings") == true)
        }) else {
            FileHandle.standardError.write(Data("tour: the Settings window did not open\n".utf8))
            return
        }
        for (tab, name) in tabs {
            defaults.set(tab.rawValue, forKey: AlertSettingsView.tabKey)
            try? await Task.sleep(for: .seconds(1.5))
            print("tour: settings \(tab.rawValue) is \(Int(settings.frame.width))x\(Int(settings.frame.height))")
            save(to: path(name), window: settings)
        }
        defaults.set(AlertSettingsView.Tab.general.rawValue, forKey: AlertSettingsView.tabKey)
        settings.close()
        try? await Task.sleep(for: .seconds(0.5))
    }

    private static func hostingWindow<Content: View>(_ view: Content, title: String) -> NSWindow {
        let window = NSWindow(contentViewController: NSHostingController(rootView: view))
        window.title = title
        window.isReleasedWhenClosed = false
        window.styleMask.remove(.resizable)
        window.center()
        window.makeKeyAndOrderFront(nil)
        return window
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
    private static func save(to path: String, window chosen: NSWindow? = nil) {
        guard let window = chosen ?? NSApplication.shared.windows.first(where: { $0.isVisible && $0.canBecomeMain }),
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
