import Foundation

public struct TrashEraseResult: Sendable, Equatable {
    public let erased: [String]
    public let freedBytes: Int64
    /// Path and reason for each item that was not erased.
    public let failed: [String: String]
}

/// Erases items in the user's Trash for good. This is the only thing in RoomyDisk that cannot be undone,
/// so it only ever touches items directly inside `~/.Trash`, one by one, never the Trash folder itself.
public struct TrashEmptier: Sendable {
    public let trashPath: String

    public init(homePath: String = NSHomeDirectory()) {
        trashPath = DiskScanner.standardize(homePath) + "/.Trash"
    }

    /// True only for an item directly inside the Trash folder.
    public func canErase(_ rawPath: String) -> Bool {
        let path = DiskScanner.standardize(rawPath)
        let name = (path as NSString).lastPathComponent
        guard !name.isEmpty, name != ".", name != ".." else { return false }
        guard (path as NSString).deletingLastPathComponent == trashPath else { return false }
        return DirectoryReader.entry(atPath: trashPath)?.kind == .directory
    }

    public func erase(_ items: [JunkItem]) -> TrashEraseResult {
        var erased: [String] = []
        var freed: Int64 = 0
        var failed: [String: String] = [:]
        for item in items {
            guard canErase(item.path) else {
                failed[item.path] = "This is not in the Trash."
                continue
            }
            do {
                // removeItem deletes a symbolic link itself, never what it points to.
                try FileManager.default.removeItem(atPath: DiskScanner.standardize(item.path))
                erased.append(item.path)
                freed += item.bytes
            } catch {
                failed[item.path] = error.localizedDescription
            }
        }
        return TrashEraseResult(erased: erased, freedBytes: freed, failed: failed)
    }
}
