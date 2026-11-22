import Foundation

/// Where Mail keeps attachments, and which of those places RoomyDisk may clean.
///
/// Mail's own store (~/Library/Mail) holds the attachments of downloaded messages next to an index that points at
/// them. Removing files there behind Mail's back can damage that index, so the store is only shown, never cleaned:
/// attachments are removed in Mail itself. "Mail Downloads" only holds copies of attachments you opened, which Mail
/// makes again when needed, so its contents may go to the Trash.
public struct MailLocations: Sendable {
    public enum Kind: Sendable, Equatable {
        /// Inside Mail's own store. Look, don't touch.
        case store
        /// An item inside a Mail Downloads folder. May go to the Trash.
        case download
        /// A Mail Downloads folder itself. Its contents may be cleaned, but the folder stays.
        case downloadsFolder
        case other
    }

    public let homePath: String

    public init(homePath: String = NSHomeDirectory()) {
        self.homePath = DiskScanner.standardize(homePath)
    }

    public var storeFolder: String { homePath + "/Library/Mail" }

    /// The sandboxed Mail's downloads folder, and the one older versions of Mail used.
    public var downloadsFolders: [String] {
        [homePath + "/Library/Containers/com.apple.mail/Data/Library/Mail Downloads",
         homePath + "/Library/Mail Downloads"]
    }

    public func classify(_ rawPath: String) -> Kind {
        let path = DiskScanner.standardize(rawPath)
        for folder in downloadsFolders {
            if path == folder { return .downloadsFolder }
            if path.hasPrefix(folder + "/") { return .download }
        }
        if SafetyPolicy.isSameOrInside(path, storeFolder) { return .store }
        return .other
    }
}

/// An item in a Mail Downloads folder: usually a folder holding one attachment you opened from Mail.
public struct MailDownload: Sendable, Identifiable, Equatable {
    public var id: String { path }
    public let path: String
    /// The attachment's name when the folder holds just one file, otherwise the item's own name.
    public let name: String
    public let bytes: Int64
    public let modified: Date

    public init(path: String, name: String, bytes: Int64, modified: Date) {
        self.path = path
        self.name = name
        self.bytes = bytes
        self.modified = modified
    }
}

public struct MailAttachmentsFinder: Sendable {
    public struct Findings: Sendable, Equatable {
        /// Space taken by attachments inside Mail's store. Shown only.
        public var storeBytes: Int64 = 0
        /// False when Mail's store exists but could not be read (no Full Disk Access).
        public var storeReadable = true
        public var downloads: [MailDownload] = []

        public init(storeBytes: Int64 = 0, storeReadable: Bool = true, downloads: [MailDownload] = []) {
            self.storeBytes = storeBytes
            self.storeReadable = storeReadable
            self.downloads = downloads
        }

        public var downloadBytes: Int64 { downloads.reduce(0) { $0 + $1.bytes } }
    }

    public let locations: MailLocations

    public init(homePath: String = NSHomeDirectory()) {
        locations = MailLocations(homePath: homePath)
    }

    public func find() -> Findings {
        var result = Findings()
        let store = storeAttachments()
        result.storeBytes = store.bytes
        result.storeReadable = store.readable
        for folder in locations.downloadsFolders {
            guard let entries = DirectoryReader.list(path: folder) else { continue }
            for entry in entries where !entry.name.hasPrefix(".") {
                let path = DiskScanner.join(folder, entry.name)
                let bytes = DiskUsage.allocatedSize(atPath: path)
                guard bytes > 0 else { continue }
                result.downloads.append(MailDownload(
                    path: path,
                    name: Self.displayName(path: path, entry: entry),
                    bytes: bytes,
                    modified: Date(timeIntervalSince1970: TimeInterval(entry.modified))
                ))
            }
        }
        result.downloads.sort { $0.bytes != $1.bytes ? $0.bytes > $1.bytes : $0.name < $1.name }
        return result
    }

    /// Adds up the "Attachments" folders inside the store's version folders (V2 … V10).
    func storeAttachments() -> (bytes: Int64, readable: Bool) {
        let store = locations.storeFolder
        guard DirectoryReader.entry(atPath: store) != nil else { return (0, true) }
        guard let versions = DirectoryReader.list(path: store) else { return (0, false) }
        var total: Int64 = 0
        var stack = versions
            .filter { $0.kind == .directory && $0.name.hasPrefix("V") }
            .map { DiskScanner.join(store, $0.name) }
        while let dir = stack.popLast() {
            if Task.isCancelled { break }
            guard let entries = DirectoryReader.list(path: dir) else { continue }
            for entry in entries where entry.kind == .directory {
                let path = DiskScanner.join(dir, entry.name)
                if entry.name == "Attachments" {
                    total += DiskUsage.allocatedSize(atPath: path)
                } else {
                    stack.append(path)
                }
            }
        }
        return (total, true)
    }

    private static func displayName(path: String, entry: RawEntry) -> String {
        guard entry.kind == .directory, let inside = DirectoryReader.list(path: path) else { return entry.name }
        let visible = inside.filter { !$0.name.hasPrefix(".") }
        return visible.count == 1 ? visible[0].name : entry.name
    }
}
