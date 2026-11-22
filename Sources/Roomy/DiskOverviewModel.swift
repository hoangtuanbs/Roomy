import AppKit
import Observation
import RoomyCore

/// The disk of the current scan: how its space splits up, and its local snapshots.
@MainActor
@Observable
final class DiskOverviewModel {
    enum SnapshotState: Equatable {
        case idle, loading, loaded, failed(String)
    }

    private(set) var space: DiskSpace?
    private(set) var volumeName = ""
    private(set) var volumePath: String?
    /// The scan covers the whole disk, so what it did not find is really hidden.
    private(set) var isWholeDisk = false

    private(set) var snapshots: [LocalSnapshot] = []
    private(set) var snapshotState: SnapshotState = .idle
    private(set) var deleting: Set<String> = []
    private(set) var isThinning = false
    var errorMessage: String?
    /// Space that became free after the last delete or thin, shown for a moment.
    private(set) var freedBytes: Int64?
    private var freedTask: Task<Void, Never>?

    var snapshotMountPoint: String? { volumePath.map(DiskSpace.snapshotMountPoint(forVolume:)) }
    var timeMachineSnapshots: [LocalSnapshot] { snapshots.filter(\.isTimeMachine) }

    /// Reads the disk that holds `scanRoot`. Snapshots are listed again only when the disk changes.
    func refresh(scanRoot: String, scanned: Int64) {
        let volume = DiskSpace.volumePath(forPath: scanRoot)
        let changed = volume != volumePath
        volumePath = volume
        isWholeDisk = DiskSpace.isWholeDisk(scanRoot: scanRoot, volumePath: volume)
        space = DiskSpace.read(forPath: scanRoot, scanned: scanned)
        let url = URL(fileURLWithPath: volume ?? scanRoot)
        volumeName = (try? url.resourceValues(forKeys: [.volumeNameKey]).volumeName) ?? url.lastPathComponent
        if changed || snapshotState == .idle { loadSnapshots() }
    }

    func loadSnapshots() {
        guard let mount = snapshotMountPoint else { return }
        if snapshots.isEmpty { snapshotState = .loading }
        Task {
            do {
                let list = try await LocalSnapshots.list(mountPoint: mount)
                guard mount == snapshotMountPoint else { return }
                snapshots = list
                snapshotState = .loaded
            } catch {
                guard mount == snapshotMountPoint else { return }
                snapshots = []
                snapshotState = .failed(error.localizedDescription)
            }
        }
    }

    /// Deletes one Time Machine snapshot. The view asks first, because this cannot be undone.
    func delete(_ snapshot: LocalSnapshot, scanned: Int64) {
        guard snapshot.canDelete, !deleting.contains(snapshot.id), let path = volumePath else { return }
        deleting.insert(snapshot.id)
        errorMessage = nil
        let before = space?.available ?? 0
        Task {
            do {
                try await LocalSnapshots.delete(snapshot)
                snapshots.removeAll { $0.id == snapshot.id }
                finishChange(path: path, scanned: scanned, availableBefore: before)
            } catch {
                errorMessage = String(format: String(localized: "Could not delete the snapshot. %@"), error.localizedDescription)
            }
            deleting.remove(snapshot.id)
            loadSnapshots()
        }
    }

    /// Lets Time Machine remove local snapshots until the purgeable space is free. Asks first in the view.
    func freePurgeable(scanned: Int64) {
        guard let mount = snapshotMountPoint, let path = volumePath, let space, space.purgeable > 0, !isThinning else { return }
        isThinning = true
        errorMessage = nil
        let before = space.available
        Task {
            do {
                try await LocalSnapshots.thin(mountPoint: mount, bytes: space.purgeable)
                finishChange(path: path, scanned: scanned, availableBefore: before)
            } catch {
                errorMessage = String(format: String(localized: "Could not free purgeable space. %@"), error.localizedDescription)
            }
            isThinning = false
            loadSnapshots()
        }
    }

    private func finishChange(path: String, scanned: Int64, availableBefore: Int64) {
        freedTask?.cancel()
        freedBytes = 0
        freedTask = Task {
            // APFS frees a snapshot's blocks in the background, so look a few times.
            for attempt in 0..<4 {
                if attempt > 0 { try? await Task.sleep(for: .seconds(1)) }
                guard !Task.isCancelled, path == volumePath else { return }
                space = DiskSpace.read(forPath: path, scanned: scanned)
                freedBytes = max(freedBytes ?? 0, (space?.available ?? availableBefore) - availableBefore)
            }
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            freedBytes = nil
        }
    }

    static let storageSettingsURL = URL(string: "x-apple.systempreferences:com.apple.settings.Storage")!

    func openStorageSettings() {
        NSWorkspace.shared.open(Self.storageSettingsURL)
    }
}
