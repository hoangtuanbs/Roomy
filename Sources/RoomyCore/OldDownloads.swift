import Foundation

/// The dates that tell when an item in Downloads was last used. Any of them may be unknown.
public struct ItemDates: Sendable, Equatable {
    /// When the item was last opened, from Spotlight (kMDItemLastUsedDate).
    public var lastUsed: Date?
    /// When the item arrived in its folder. A downloaded file often keeps the server's old modification date, so
    /// this is what keeps a file downloaded yesterday from looking years old.
    public var added: Date?
    /// The newest modification date of the item, or of anything inside it for a folder.
    public var modified: Date?
    /// The last access date. Only used when Spotlight has no last-used date.
    public var accessed: Date?

    public init(lastUsed: Date? = nil, added: Date? = nil, modified: Date? = nil, accessed: Date? = nil) {
        self.lastUsed = lastUsed
        self.added = added
        self.modified = modified
        self.accessed = accessed
    }
}

public enum OldDownloadRule {
    /// Items untouched for this long are listed.
    public static let age: TimeInterval = 90 * 86_400

    /// The last time anything happened to the item: the newest of the known dates.
    public static func lastActivity(_ dates: ItemDates) -> Date? {
        var known = [dates.lastUsed, dates.added, dates.modified].compactMap { $0 }
        if dates.lastUsed == nil, let accessed = dates.accessed { known.append(accessed) }
        return known.max()
    }

    /// True when the item has not been opened, added or changed for `age`. Items with no known date are not old.
    public static func isOld(_ dates: ItemDates, now: Date = Date(), age: TimeInterval = age) -> Bool {
        guard let last = lastActivity(dates) else { return false }
        return now.timeIntervalSince(last) >= age
    }
}

/// A file or folder in Downloads that has not been used for a long time.
public struct OldDownload: Sendable, Identifiable, Equatable {
    public var id: String { path }
    public let path: String
    public let name: String
    public let bytes: Int64
    public let lastActivity: Date
    public let isFolder: Bool

    public init(path: String, name: String, bytes: Int64, lastActivity: Date, isFolder: Bool) {
        self.path = path
        self.name = name
        self.bytes = bytes
        self.lastActivity = lastActivity
        self.isFolder = isFolder
    }
}

/// Lists the items directly inside Downloads that are old by `OldDownloadRule`, largest first.
public struct OldDownloadsFinder: Sendable {
    public let downloadsPath: String
    public var now: Date
    public var age: TimeInterval
    /// The dates of a path other than its modification date, which is read here. The app adds Spotlight's
    /// last-used date to `systemDates`; tests pass their own.
    public var dates: @Sendable (String) -> ItemDates
    public var policy: SafetyPolicy

    public init(downloadsPath: String = NSHomeDirectory() + "/Downloads", now: Date = Date(),
                age: TimeInterval = OldDownloadRule.age, policy: SafetyPolicy = SafetyPolicy(),
                dates: @escaping @Sendable (String) -> ItemDates = { OldDownloadsFinder.systemDates($0) }) {
        self.downloadsPath = DiskScanner.standardize(downloadsPath)
        self.now = now
        self.age = age
        self.policy = policy
        self.dates = dates
    }

    /// The date the item was added to its folder and its last access date, as the file system knows them.
    public static func systemDates(_ path: String) -> ItemDates {
        #if canImport(Darwin)
        let values = try? URL(fileURLWithPath: path).resourceValues(forKeys: [.addedToDirectoryDateKey, .contentAccessDateKey])
        return ItemDates(added: values?.addedToDirectoryDate, accessed: values?.contentAccessDate)
        #else
        return ItemDates()
        #endif
    }

    public func find() -> [OldDownload] {
        guard let entries = DirectoryReader.list(path: downloadsPath) else { return [] }
        var found: [OldDownload] = []
        for entry in entries where !entry.name.hasPrefix(".") {
            if Task.isCancelled { break }
            guard entry.kind == .file || entry.kind == .directory else { continue }
            let path = DiskScanner.join(downloadsPath, entry.name)
            if policy.verdict(for: path).isBlocked { continue }
            let walked = entry.kind == .directory ? Self.walk(path) : (entry.allocated, entry.modified)
            var dates = self.dates(path)
            dates.modified = Date(timeIntervalSince1970: TimeInterval(walked.newest))
            guard OldDownloadRule.isOld(dates, now: now, age: age),
                  let last = OldDownloadRule.lastActivity(dates), walked.bytes > 0 else { continue }
            found.append(OldDownload(path: path, name: entry.name, bytes: walked.bytes,
                                     lastActivity: last, isFolder: entry.kind == .directory))
        }
        return found.sorted { $0.bytes != $1.bytes ? $0.bytes > $1.bytes : $0.name < $1.name }
    }

    /// The size of a folder and the newest modification date of anything in it.
    static func walk(_ path: String) -> (bytes: Int64, newest: Int64) {
        guard let root = DirectoryReader.entry(atPath: path) else { return (0, 0) }
        var bytes = root.allocated
        var newest = root.modified
        var stack = [path]
        while let dir = stack.popLast() {
            if Task.isCancelled { break }
            guard let entries = DirectoryReader.list(path: dir) else { continue }
            for entry in entries {
                bytes += entry.allocated
                newest = max(newest, entry.modified)
                if entry.kind == .directory { stack.append(DiskScanner.join(dir, entry.name)) }
            }
        }
        return (bytes, newest)
    }
}
