import AppKit
import Observation
import RoomyCore
import SwiftUI

/// A disk listed in the menu bar popover.
struct MenuBarDisk: Identifiable, Equatable {
    var id: String { path }
    let path: String
    let name: String
    let isStartup: Bool
    let space: DiskSpace
}

/// The disks the menu bar popover shows. Reads them every minute while the app runs.
@MainActor
@Observable
final class MenuBarDiskModel {
    private(set) var disks: [MenuBarDisk] = []
    private var loop: Task<Void, Never>?

    init() {
        start()
    }

    private func start() {
        loop = Task {
            while !Task.isCancelled {
                self.refresh()
                try? await Task.sleep(for: .seconds(60))
            }
        }
    }

    /// Reads the disks again. Bars move with a spring unless Reduce Motion is on.
    func refresh() {
        let fresh = Self.readDisks()
        withAnimation(Motion.spring.unless(NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)) { disks = fresh }
        if let startup = fresh.first(where: \.isStartup) {
            LowSpaceNotifier.checkStartupDisk(free: startup.space.availableForImportantUsage)
        }
    }

    /// The startup disk first, then the external disks mounted under /Volumes.
    static func readDisks() -> [MenuBarDisk] {
        var result: [MenuBarDisk] = []
        if let space = DiskSpace.read(forPath: "/", scanned: 0) {
            result.append(MenuBarDisk(path: "/", name: volumeName(URL(fileURLWithPath: "/")) ?? String(localized: "Startup disk"),
                                      isStartup: true, space: space))
        }
        let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: [.volumeNameKey],
                                                         options: [.skipHiddenVolumes]) ?? []
        for url in urls where url.path.hasPrefix("/Volumes/") {
            guard let space = DiskSpace.read(forPath: url.path, scanned: 0) else { continue }
            result.append(MenuBarDisk(path: url.path, name: volumeName(url) ?? url.lastPathComponent,
                                      isStartup: false, space: space))
        }
        return result
    }

    private static func volumeName(_ url: URL) -> String? {
        try? url.resourceValues(forKeys: [.volumeNameKey]).volumeName
    }
}
