import Foundation

/// Where the space of a disk goes: what a scan found, what macOS can free on its own (purgeable),
/// what is used but was not found (hidden), and what is free.
///
/// The four parts `scanned + hidden + purgeable + free` always add up to `total`.
public struct DiskSpace: Sendable, Equatable {
    public let total: Int64
    /// Free right now.
    public let available: Int64
    /// Free plus what macOS can free when an app needs room. Finder shows this as "available".
    public let availableForImportantUsage: Int64
    /// What the scan found, as the scan counted it.
    public let scannedBytes: Int64

    public init(total: Int64, available: Int64, availableForImportantUsage: Int64, scanned: Int64) {
        self.total = max(0, total)
        self.available = min(max(0, available), self.total)
        self.availableForImportantUsage = min(max(self.available, availableForImportantUsage), self.total)
        self.scannedBytes = max(0, scanned)
    }

    /// Used according to the disk, purgeable space included.
    public var used: Int64 { total - available }

    /// Space macOS frees by itself when it needs room, such as local snapshots and iCloud files that are also online.
    public var purgeable: Int64 { availableForImportantUsage - available }

    /// The part of the used space the scan found. A scan can count a little more than the disk reports
    /// (for example compressed files), so it is capped at what is used.
    public var scanned: Int64 { min(scannedBytes, used) }

    /// Purgeable space that is not already part of what the scan found.
    public var purgeableShown: Int64 { min(purgeable, used - scanned) }

    /// Used space that is neither found by the scan nor purgeable: files Roomy cannot read,
    /// system files in hidden volumes, and snapshots.
    public var hidden: Int64 { max(0, used - scanned - purgeableShown) }

    public var free: Int64 { available }

    /// Fractions of `total` for the scanned, hidden, purgeable and free parts, in that order.
    public var fractions: [Double] {
        guard total > 0 else { return [0, 0, 0, 0] }
        return [scanned, hidden, purgeableShown, free].map { Double($0) / Double(total) }
    }
}

extension DiskSpace {
    /// The capacity of the disk that holds `path`, with `scanned` as what a scan found. Nil when macOS does not say.
    public static func read(forPath path: String, scanned: Int64) -> DiskSpace? {
        let url = URL(fileURLWithPath: path)
        #if os(macOS)
        let keys: Set<URLResourceKey> = [.volumeTotalCapacityKey, .volumeAvailableCapacityKey,
                                         .volumeAvailableCapacityForImportantUsageKey]
        guard let values = try? url.resourceValues(forKeys: keys),
              let total = values.volumeTotalCapacity, let available = values.volumeAvailableCapacity
        else { return nil }
        let important = values.volumeAvailableCapacityForImportantUsage ?? Int64(available)
        return DiskSpace(total: Int64(total), available: Int64(available),
                         availableForImportantUsage: important, scanned: scanned)
        #else
        let keys: Set<URLResourceKey> = [.volumeTotalCapacityKey, .volumeAvailableCapacityKey]
        guard let values = try? url.resourceValues(forKeys: keys),
              let total = values.volumeTotalCapacity, let available = values.volumeAvailableCapacity
        else { return nil }
        return DiskSpace(total: Int64(total), available: Int64(available),
                         availableForImportantUsage: Int64(available), scanned: scanned)
        #endif
    }

    /// The mount point of the disk that holds `path`, such as `/` or `/Volumes/Backup`.
    public static func volumePath(forPath path: String) -> String? {
        guard let values = try? URL(fileURLWithPath: path).resourceValues(forKeys: [.volumeURLKey]),
              let volume = values.volume
        else { return nil }
        return DiskScanner.standardize(volume.path)
    }

    /// True when a scan of `scanRoot` covers a whole disk, so the parts it did not find are really hidden.
    /// `/` and the data volume of the startup disk both count as the startup disk.
    public static func isWholeDisk(scanRoot: String, volumePath: String?) -> Bool {
        let root = DiskScanner.standardize(scanRoot)
        if root == "/" || root == "/System/Volumes/Data" { return true }
        guard let volumePath else { return false }
        return root == DiskScanner.standardize(volumePath)
    }

    /// The mount point to pass to `tmutil` for a disk. Time Machine lists the startup disk's snapshots under `/`.
    public static func snapshotMountPoint(forVolume volumePath: String) -> String {
        let volume = DiskScanner.standardize(volumePath)
        return volume == "/System/Volumes/Data" ? "/" : volume
    }
}
