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

    public init(
        maxConcurrentReads: Int = max(4, ProcessInfo.processInfo.activeProcessorCount * 2),
        stayOnVolume: Bool = true,
        excludedPaths: Set<String> = [],
        progressInterval: Duration = .milliseconds(100)
    ) {
        self.maxConcurrentReads = maxConcurrentReads
        self.stayOnVolume = stayOnVolume
        self.excludedPaths = excludedPaths
        self.progressInterval = progressInterval
    }
}

public enum ScanError: Error, LocalizedError, Equatable {
    case notFound(String)
    case notADirectory(String)

    public var errorDescription: String? {
        switch self {
        case .notFound(let path): return "\(path) does not exist."
        case .notADirectory(let path): return "\(path) is not a folder."
        }
    }
}

/// Walks a folder tree in parallel. Only the collecting loop touches the tree.
public struct DiskScanner: Sendable {
    public var options: ScanOptions

    public init(options: ScanOptions = ScanOptions()) {
        self.options = options
    }

    public func scan(
        root rawRoot: String,
        progress: (@Sendable (ScanProgress) -> Void)? = nil
    ) async throws -> ScanTree {
        let root = Self.standardize(rawRoot)
        guard let rootEntry = DirectoryReader.entry(atPath: root) else { throw ScanError.notFound(root) }
        guard rootEntry.kind == .directory else { throw ScanError.notADirectory(root) }

        let tree = ScanTree(rootPath: root, size: rootEntry.allocated, modified: rootEntry.modified)
        var allowedDevices: Set<UInt64> = [rootEntry.device]
        var excluded = options.excludedPaths
        #if os(macOS)
        if root == "/" {
            if let data = DirectoryReader.entry(atPath: "/System/Volumes/Data") {
                allowedDevices.insert(data.device)
            }
            excluded.insert("/System/Volumes/Data")
        }
        #endif

        let clock = ContinuousClock()
        let start = clock.now
        var lastReport = start
        var stats = ScanProgress()
        var seenInodes = Set<InodeKey>()
        let maxReads = max(1, options.maxConcurrentReads)
        let stayOnVolume = options.stayOnVolume

        try await withThrowingTaskGroup(of: Listing.self) { group in
            var pending: [(ScanTree.Index, String)] = [(ScanTree.root, root)]
            var running = 0

            while true {
                while running < maxReads, let (node, path) = pending.popLast() {
                    group.addTask {
                        Listing(node: node, path: path, entries: DirectoryReader.list(path: path))
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

                for entry in entries {
                    var size = entry.allocated
                    var flags: NodeFlags = []
                    var kind = entry.kind

                    if kind != .directory && entry.linkCount > 1 {
                        if !seenInodes.insert(InodeKey(device: entry.device, inode: entry.inode)).inserted {
                            size = 0
                            flags.insert(.hardLinkDuplicate)
                        }
                    }
                    if kind == .directory && PackageTypes.isPackage(name: entry.name) {
                        kind = .package
                    }

                    let childPath = Self.join(listing.path, entry.name)
                    var descend = kind.isContainer
                    if descend && stayOnVolume && !allowedDevices.contains(entry.device) {
                        flags.insert(.otherVolume)
                        descend = false
                    }
                    if descend && excluded.contains(childPath) {
                        flags.insert(.excluded)
                        descend = false
                    }

                    let index = tree.append(
                        name: entry.name,
                        parent: listing.node,
                        kind: kind,
                        size: size,
                        modified: entry.modified,
                        flags: flags
                    )
                    if descend {
                        pending.append((index, childPath))
                    } else if !kind.isContainer {
                        stats.files += 1
                    }
                    stats.bytes += size
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

    static func standardize(_ path: String) -> String {
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

private struct InodeKey: Hashable {
    let device: UInt64
    let inode: UInt64
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
