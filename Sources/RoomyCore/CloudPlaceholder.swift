import Foundation

/// Files kept only in the cloud (iCloud Drive, Dropbox, OneDrive and the like): macOS shows them in Finder,
/// but their contents are not on this Mac until they are opened, so they take no space here.
public enum CloudPlaceholder {
    /// `SF_DATALESS` from <sys/stat.h>: the file's contents are held by a file provider.
    public static let datalessFlag: UInt32 = 0x4000_0000

    /// True when an item takes no local space because its contents are in the cloud: macOS marks it dataless,
    /// or it is a file in a cloud folder with a length but no blocks on disk (how older providers leave them).
    /// Folders count only when macOS marks them.
    public static func isDataless(flags: UInt32, allocated: Int64, length: Int64, isDirectory: Bool,
                                  inCloudFolder: Bool) -> Bool {
        if flags & datalessFlag != 0 { return true }
        return !isDirectory && inCloudFolder && allocated == 0 && length > 0
    }

    /// True for paths inside iCloud Drive (`~/Library/Mobile Documents`) or a cloud drive (`~/Library/CloudStorage`).
    public static func isInCloudFolder(_ path: String) -> Bool {
        let slashed = path + "/"
        return slashed.contains("/Library/Mobile Documents/") || slashed.contains("/Library/CloudStorage/")
    }

    /// Reads the flags of one item. Nil when it cannot be read.
    public static func isDataless(path: String) -> Bool? {
        guard let entry = DirectoryReader.entry(atPath: path) else { return nil }
        return isDataless(flags: entry.fileFlags, allocated: entry.allocated, length: entry.length,
                          isDirectory: entry.kind == .directory, inCloudFolder: isInCloudFolder(path))
    }
}
