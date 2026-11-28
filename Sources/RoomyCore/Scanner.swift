import Foundation

public struct ScanProgress: Sendable, Equatable {
    public var files: Int = 0
    public var directories: Int = 0
    public var bytes: Int64 = 0
    public var currentPath: String = ""
    public var elapsed: Duration = .zero

    public init() {}
}

public struct ScanOptions: Sendable {
    public var maxConcurrentReads: Int
    public var stayOnVolume: Bool
    public var excludedPaths: Set<String>
    public var progressInterval: Duration
    /// Asks APFS which files are clones, so their shared blocks are counted once.
    public var detectClones: Bool

    public init(
        maxConcurrentReads: Int = max(4, ProcessInfo.processInfo.activeProcessorCount * 2),
        stayOnVolume: Bool = true,
        excludedPaths: Set<String> = [],
        progressInterval: Duration = .milliseconds(100),
        detectClones: Bool = true
    ) {
        self.maxConcurrentReads = maxConcurrentReads
        self.stayOnVolume = stayOnVolume
        self.excludedPaths = excludedPaths
        self.progressInterval = progressInterval
        self.detectClones = detectClones
    }
}

public enum ScanError: Error, LocalizedError, Equatable {
    case notFound(String)
    case notADirectory(String)

    public var errorDescription: String? {
        switch self {
        case .notFound(let path): return String(format: String(localized: "%@ does not exist."), path)
        case .notADirectory(let path): return String(format: String(localized: "%@ is not a folder."), path)
        }
    }
}

/// Walks a folder tree in parallel. Only the collecting loop touches the tree.
public struct DiskScanner: Sendable {
    public var options: ScanOptions

    public init(options: ScanOptions = ScanOptions()) {
        self.options = options
    }

    /// Scans `rawRoot`. Clones of the `cloneFamilies` count only their own space, because another part of a larger
    /// tree already carries the space they share.
    public func scan(
        root rawRoot: String,
        cloneFamilies: Set<UInt64> = [],
        progress: (@Sendable (ScanProgress) -> Void)? = nil
    ) async throws -> ScanTree {
        let root = Self.standardize(rawRoot)
        guard let rootEntry = DirectoryReader.entry(atPath: root) else { throw ScanError.notFound(root) }
        guard rootEntry.kind == .directory else { throw ScanError.notADirectory(root) }

        // Taken first, so whatever changes while the scan runs is in the history a quick rescan reads.
        let journalID = ChangeJournal.currentEventID()
        let tree = ScanTree(rootPath: root, size: rootEntry.allocated, modified: rootEntry.modified)
        tree.journalID = journalID
        tree.volumeID = ChangeJournal.volumeID(forPath: root)
        let rules = EntryRules(root: root, rootDevice: rootEntry.device, options: options)

        let clock = ContinuousClock()
        let start = clock.now
        var lastReport = start
        var stats = ScanProgress()
        var counter = SpaceCounter(cloneFamilies: cloneFamilies)
        let maxReads = max(1, options.maxConcurrentReads)
        let clones = options.detectClones

        try await withThrowingTaskGroup(of: Listing.self) { group in
            var pending: [(ScanTree.Index, String)] = [(ScanTree.root, root)]
            var running = 0

            while true {
                while running < maxReads, let (node, path) = pending.popLast() {
                    group.addTask {
                        Listing(node: node, path: path, entries: DirectoryReader.list(path: path, clones: clones))
                    }
                    running += 1
                }
                guard let listing = try await group.next() else { break }
                running -= 1
                try Task.checkCancellation()

                guard let entries = listing.entries else {
                    tree.insertFlags(.inaccessible, at: listing.node)
                    continue
                }
                stats.directories += 1
                let inCloud = CloudPlaceholder.isInCloudFolder(listing.path)

                for entry in entries {
                    let childPath = Self.join(listing.path, entry.name)
                    let item = rules.classify(entry, path: childPath, inCloudFolder: inCloud, counter: &counter)
                    let index = tree.append(
                        name: entry.name,
                        parent: listing.node,
                        kind: item.kind,
                        size: item.size,
                        modified: entry.modified,
                        flags: item.flags
                    )
                    if let clone = item.clone { tree.setClone(clone, at: index) }
                    if let online = item.onlineBytes { tree.setOnlineSize(online, at: index) }
                    if item.descend {
                        pending.append((index, childPath))
                    } else if !item.kind.isContainer {
                        stats.files += 1
                    }
                    stats.bytes += item.size
                }

                if let progress, clock.now - lastReport >= options.progressInterval {
                    lastReport = clock.now
                    stats.currentPath = listing.path
                    stats.elapsed = lastReport - start
                    progress(stats)
                }
            }
        }

        tree.finalize()
        if let progress {
            stats.currentPath = root
            stats.elapsed = clock.now - start
            progress(stats)
        }
        return tree
    }

    public static func standardize(_ path: String) -> String {
        var p = (path as NSString).expandingTildeInPath
        p = (p as NSString).standardizingPath
        while p.count > 1 && p.hasSuffix("/") { p.removeLast() }
        return p
    }

    static func join(_ dir: String, _ name: String) -> String {
        dir == "/" ? "/" + name : dir + "/" + name
    }
}

private struct Listing: Sendable {
    let node: ScanTree.Index
    let path: String
    let entries: [RawEntry]?
}

struct InodeKey: Hashable {
    let device: UInt64
    let inode: UInt64
}

/// Counts each piece of disk space once while entries are added: hard links after the first add nothing, and a
/// clone after the first of its family adds only its private space.
struct SpaceCounter {
    var seenInodes = Set<InodeKey>()
    var cloneFamilies = Set<UInt64>()

    static func family(device: UInt64, id: UInt64) -> UInt64 {
        id ^ (device &* 0x9E37_79B9_7F4A_7C15)
    }
}

/// What the scanner makes of one directory entry.
struct ClassifiedEntry {
    var kind: NodeKind
    var size: Int64
    var flags: NodeFlags
    var descend: Bool
    var clone: CloneInfo?
    var onlineBytes: Int64?
}

/// The rules of one scan for an entry: its kind, the space it adds, its flags, and whether to look inside it.
/// Shared by full scans and quick rescans, so both count the same way.
struct EntryRules: Sendable {
    let allowedDevices: Set<UInt64>
    let excluded: Set<String>
    let stayOnVolume: Bool

    init(root: String, rootDevice: UInt64, options: ScanOptions) {
        var allowed: Set<UInt64> = [rootDevice]
        var excluded = options.excludedPaths
        #if os(macOS)
        if root == "/" {
            if let data = DirectoryReader.entry(atPath: "/System/Volumes/Data") {
                allowed.insert(data.device)
            }
            excluded.insert("/System/Volumes/Data")
        }
        #endif
        self.allowedDevices = allowed
        self.excluded = excluded
        self.stayOnVolume = options.stayOnVolume
    }

    func classify(_ entry: RawEntry, path: String, inCloudFolder: Bool, counter: inout SpaceCounter) -> ClassifiedEntry {
        var out = ClassifiedEntry(kind: entry.kind, size: entry.allocated, flags: [], descend: false)

        if CloudPlaceholder.isDataless(flags: entry.fileFlags, allocated: entry.allocated, length: entry.length,
                                       isDirectory: entry.kind == .directory, inCloudFolder: inCloudFolder) {
            // Its contents are in the cloud. Looking inside a cloud-only folder could make macOS fetch it.
            out.flags.insert(.dataless)
            out.size = 0
            if entry.kind == .file { out.onlineBytes = entry.length }
            if entry.kind == .directory && PackageTypes.isPackage(name: entry.name) { out.kind = .package }
            return out
        }

        if out.kind != .directory && entry.linkCount > 1 {
            if !counter.seenInodes.insert(InodeKey(device: entry.device, inode: entry.inode)).inserted {
                out.size = 0
                out.flags.insert(.hardLinkDuplicate)
                return out
            }
        }
        if let clone = entry.clone {
            let family = SpaceCounter.family(device: entry.device, id: clone.id)
            out.flags.insert(.clone)
            let first = counter.cloneFamilies.insert(family).inserted
            out.clone = CloneInfo(family: family, sharedBytes: entry.allocated - clone.privateBytes, carriesShared: first)
            if !first { out.size = clone.privateBytes }
        }
        if out.kind == .directory && PackageTypes.isPackage(name: entry.name) {
            out.kind = .package
        }

        out.descend = out.kind.isContainer
        if out.descend && stayOnVolume && !allowedDevices.contains(entry.device) {
            out.flags.insert(.otherVolume)
            out.descend = false
        }
        if out.descend && excluded.contains(path) {
            out.flags.insert(.excluded)
            out.descend = false
        }
        return out
    }
}

public enum PackageTypes {
    public static let extensions: Set<String> = [
        "app", "bundle", "framework", "plugin", "kext", "appex", "xpc",
        "photoslibrary", "musiclibrary", "tvlibrary", "imovielibrary", "fcpbundle", "logicx", "band",
        "xcarchive", "xcodeproj", "xcworkspace", "playground", "xcassets",
        "rtfd", "pages", "numbers", "key", "sparsebundle", "pkg", "mpkg",
    ]

    public static func isPackage(name: String) -> Bool {
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return false }
        return extensions.contains(name[name.index(after: dot)...].lowercased())
    }
}
