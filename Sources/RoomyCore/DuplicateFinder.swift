import Foundation
#if canImport(CryptoKit)
import CryptoKit
#endif

/// One copy of a file that has identical twins.
public struct DuplicateFile: Sendable, Hashable, Identifiable {
    public var id: String { path }
    public let path: String
    /// Space the copy takes on disk.
    public let bytes: Int64
    public let modified: Date

    public init(path: String, bytes: Int64, modified: Date) {
        self.path = path
        self.bytes = bytes
        self.modified = modified
    }

    public var name: String { (path as NSString).lastPathComponent }
}

/// Files with exactly the same content. The copy the keep rule prefers comes first.
public struct DuplicateGroup: Sendable, Identifiable, Equatable {
    public let id: String
    /// Length of each copy in bytes.
    public let length: Int64
    public let files: [DuplicateFile]

    public init(id: String, length: Int64, files: [DuplicateFile]) {
        self.id = id
        self.length = length
        self.files = KeepRule.sorted(files)
    }

    /// Space one copy takes on disk.
    public var bytes: Int64 { files.map(\.bytes).max() ?? 0 }
    /// Space that removing every copy but one would free: size × (count − 1).
    public var wastedBytes: Int64 { bytes * Int64(max(0, files.count - 1)) }
    /// The copy to keep when the results first appear.
    public var suggestedKeep: DuplicateFile { files[0] }

    /// The same group without the given paths, or nil when fewer than two copies are left.
    public func removing(_ removed: Set<String>) -> DuplicateGroup? {
        let left = files.filter { !removed.contains($0.path) }
        guard left.count > 1 else { return nil }
        return DuplicateGroup(id: id, length: length, files: left)
    }
}

/// Picks the copy that looks most like the original: not in Downloads, the Trash or a cache, not named
/// like a copy ("photo copy.jpg", "photo (1).jpg"), then the oldest, then the one with the shortest path.
public enum KeepRule {
    public static func sorted(_ files: [DuplicateFile]) -> [DuplicateFile] {
        files.sorted(by: prefers)
    }

    /// True when `a` is a better copy to keep than `b`.
    public static func prefers(_ a: DuplicateFile, _ b: DuplicateFile) -> Bool {
        let pa = penalty(a.path), pb = penalty(b.path)
        if pa != pb { return pa < pb }
        let ta = Int64(a.modified.timeIntervalSince1970), tb = Int64(b.modified.timeIntervalSince1970)
        if ta != tb { return ta < tb }
        let da = a.path.split(separator: "/").count, db = b.path.split(separator: "/").count
        if da != db { return da < db }
        if a.path.count != b.path.count { return a.path.count < b.path.count }
        return a.path < b.path
    }

    static let throwawayFolders = ["/Downloads/", "/.Trash/", "/.Trashes/", "/Library/Caches/"]

    static func penalty(_ path: String) -> Int {
        var score = 0
        if throwawayFolders.contains(where: { path.contains($0) }) { score += 2 }
        if looksLikeCopy((path as NSString).lastPathComponent) { score += 1 }
        return score
    }

    /// "report copy.pdf", "report copy 2.pdf", "report (1).pdf", "report-copy.pdf".
    public static func looksLikeCopy(_ name: String) -> Bool {
        let stem = (name as NSString).deletingPathExtension.lowercased()
        return stem.range(of: #"([ _-]copy( \d+)?| \(\d+\))$"#, options: .regularExpression) != nil
    }
}

public struct DuplicateProgress: Sendable, Equatable {
    public enum Stage: Sendable, Equatable {
        /// Reading the folder, when no scan was given.
        case listing
        /// Comparing the start and end of files with the same size.
        case comparing
        /// Reading whole files that still look the same.
        case hashing
    }

    public var stage: Stage
    /// Files for `comparing`, bytes for `hashing`, files found for `listing`.
    public var done: Int64
    public var total: Int64

    public init(stage: Stage, done: Int64 = 0, total: Int64 = 0) {
        self.stage = stage
        self.done = done
        self.total = total
    }

    /// How far the whole search is, from 0 to 1.
    public var fraction: Double {
        let part = total > 0 ? min(1, Double(done) / Double(total)) : 0
        switch stage {
        case .listing: return 0
        case .comparing: return 0.05 + 0.25 * part
        case .hashing: return 0.3 + 0.7 * part
        }
    }
}

/// Finds files with identical content. Files are grouped by size, then by a hash of their first and last
/// 64 KB, and only then hashed in full. It only looks; removing goes through `CleanupService`.
public struct DuplicateFinder: Sendable {
    public let policy: SafetyPolicy
    /// Smaller files are left out. Zero-byte files always are.
    public var minimumSize: Int64
    public var maxConcurrentReads: Int

    static let edgeSize = 64 * 1024
    /// Folders whose files belong together and are never offered.
    static let skippedFolderNames: Set<String> = [
        ".git", ".hg", ".svn", ".Trash", ".Trashes", ".Spotlight-V100", ".fseventsd",
        ".DocumentRevisions-V100", ".MobileBackups", ".TemporaryItems",
    ]

    public init(homePath: String = NSHomeDirectory(), minimumSize: Int64 = 1_048_576,
                maxConcurrentReads: Int = max(2, min(8, ProcessInfo.processInfo.activeProcessorCount))) {
        self.policy = SafetyPolicy(homePath: homePath)
        self.minimumSize = minimumSize
        self.maxConcurrentReads = maxConcurrentReads
    }

    /// Scans `folder` and looks for duplicates in it.
    public func find(folder: String, progress: (@Sendable (DuplicateProgress) -> Void)? = nil) async throws -> [DuplicateGroup] {
        let tree = try await DiskScanner().scan(root: folder) { scan in
            progress?(DuplicateProgress(stage: .listing, done: Int64(scan.files)))
        }
        return try await find(in: tree, progress: progress)
    }

    /// Looks for duplicates among the files of a scan, below `start`. Largest waste first.
    public func find(in tree: ScanTree, under start: ScanTree.Index = ScanTree.root,
                     progress: (@Sendable (DuplicateProgress) -> Void)? = nil) async throws -> [DuplicateGroup] {
        let found = candidates(in: tree, under: start)
        let reporter = ProgressThrottle(progress)

        // 1. Same length.
        let sameSize = Dictionary(grouping: found, by: \.length).values.filter { $0.count > 1 }
        let toCompare = sameSize.flatMap { $0 }
        try Task.checkCancellation()

        // 2. Same first and last 64 KB.
        var compared: Int64 = 0
        let compareTotal = Int64(toCompare.count)
        reporter.send(DuplicateProgress(stage: .comparing, done: 0, total: compareTotal), force: true)
        let edges = try await hashEach(toCompare, full: false) { _ in
            compared += 1
            reporter.send(DuplicateProgress(stage: .comparing, done: compared, total: compareTotal))
        }
        let sameEdges = Dictionary(grouping: edges, by: { HashKey(length: $0.0.length, hash: $0.1) })
            .values.filter { $0.count > 1 }

        // 3. Same full content. Files no longer than both edges were already read whole.
        var groups: [(HashKey, [Candidate])] = []
        var toHash: [Candidate] = []
        for group in sameEdges {
            if group[0].0.length <= Int64(2 * Self.edgeSize) {
                groups.append((HashKey(length: group[0].0.length, hash: group[0].1), group.map(\.0)))
            } else {
                toHash.append(contentsOf: group.map(\.0))
            }
        }
        var hashed: Int64 = 0
        let hashTotal = toHash.reduce(Int64(0)) { $0 + $1.length }
        reporter.send(DuplicateProgress(stage: .hashing, done: 0, total: hashTotal), force: true)
        let full = try await hashEach(toHash, full: true) { candidate in
            hashed += candidate.length
            reporter.send(DuplicateProgress(stage: .hashing, done: hashed, total: hashTotal))
        }
        for (key, group) in Dictionary(grouping: full, by: { HashKey(length: $0.0.length, hash: $0.1) }) where group.count > 1 {
            groups.append((key, group.map(\.0)))
        }
        reporter.send(DuplicateProgress(stage: .hashing, done: hashTotal, total: hashTotal), force: true)

        return groups.map { key, members in
            DuplicateGroup(id: "\(key.length)-\(key.hash.prefix(24))", length: key.length,
                           files: members.map { DuplicateFile(path: $0.path, bytes: $0.bytes, modified: $0.modified) })
        }
        .sorted { $0.wastedBytes != $1.wastedBytes ? $0.wastedBytes > $1.wastedBytes : $0.id < $1.id }
    }

    struct Candidate: Sendable {
        let path: String
        let bytes: Int64
        let length: Int64
        let modified: Date
    }

    private struct HashKey: Hashable {
        let length: Int64
        let hash: String
    }

    private struct FileID: Hashable {
        let device: UInt64
        let inode: UInt64
    }

    /// Regular files big enough to matter, outside packages, version control folders and anything the safety
    /// rules do not allow. Each file on disk is listed once, however many hard links it has.
    func candidates(in tree: ScanTree, under start: ScanTree.Index) -> [Candidate] {
        var out: [Candidate] = []
        var seen = Set<FileID>()
        var stack: [ScanTree.Index] = [start]
        while let node = stack.popLast() {
            for child in tree.children(node) {
                let flags = tree.flags(child)
                if flags.contains(.removed) || flags.contains(.hardLinkDuplicate) { continue }
                switch tree.kind(child) {
                case .directory:
                    if !Self.skippedFolderNames.contains(tree.name(child)) { stack.append(child) }
                case .file:
                    guard tree.size(child) >= minimumSize else { continue }
                    let path = tree.path(of: child)
                    // Look again: the file may have changed since the scan.
                    guard let entry = DirectoryReader.entry(atPath: path), entry.kind == .file,
                          entry.length > 0, entry.length >= minimumSize else { continue }
                    if entry.linkCount > 1, !seen.insert(FileID(device: entry.device, inode: entry.inode)).inserted { continue }
                    guard policy.verdict(for: path) == .allowed else { continue }
                    out.append(Candidate(path: path, bytes: entry.allocated, length: entry.length,
                                         modified: Date(timeIntervalSince1970: TimeInterval(entry.modified))))
                case .package, .symlink, .other:
                    continue
                }
            }
        }
        return out
    }

    /// Hashes the files a few at a time. Files that cannot be read are left out.
    private func hashEach(_ items: [Candidate], full: Bool,
                          onEach: (Candidate) -> Void) async throws -> [(Candidate, String)] {
        guard !items.isEmpty else { return [] }
        let limit = max(1, maxConcurrentReads)
        return try await withThrowingTaskGroup(of: (Candidate, String?).self) { group in
            var next = 0
            var out: [(Candidate, String)] = []
            while next < min(limit, items.count) {
                let item = items[next]
                group.addTask { (item, full ? FileHasher.full(item.path, length: item.length) : FileHasher.edges(item.path, length: item.length)) }
                next += 1
            }
            while let result = try await group.next() {
                try Task.checkCancellation()
                let (item, hash) = result
                onEach(item)
                if let hash { out.append((item, hash)) }
                if next < items.count {
                    let item = items[next]
                    group.addTask { (item, full ? FileHasher.full(item.path, length: item.length) : FileHasher.edges(item.path, length: item.length)) }
                    next += 1
                }
            }
            return out
        }
    }
}

/// Calls the progress handler at most every 100 ms, unless forced.
private final class ProgressThrottle {
    private let handler: (@Sendable (DuplicateProgress) -> Void)?
    private let clock = ContinuousClock()
    private var last: ContinuousClock.Instant?

    init(_ handler: (@Sendable (DuplicateProgress) -> Void)?) {
        self.handler = handler
    }

    func send(_ progress: DuplicateProgress, force: Bool = false) {
        guard let handler else { return }
        let now = clock.now
        if !force, let last, now - last < .milliseconds(100) { return }
        last = now
        handler(progress)
    }
}

enum FileHasher {
    static let chunkSize = 1 << 20

    /// A hash of the first and last 64 KB, and the length.
    static func edges(_ path: String, length: Int64) -> String? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        var digest = ContentDigest()
        let edge = DuplicateFinder.edgeSize
        do {
            digest.update(try handle.read(upToCount: edge) ?? Data())
            if length > Int64(edge) {
                try handle.seek(toOffset: UInt64(max(Int64(edge), length - Int64(edge))))
                digest.update(try handle.read(upToCount: edge) ?? Data())
            }
        } catch {
            return nil
        }
        return digest.finish()
    }

    /// A hash of the whole file, read in 1 MB pieces. Nil when cancelled or when the length changed.
    static func full(_ path: String, length: Int64) -> String? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        var digest = ContentDigest()
        var read: Int64 = 0
        do {
            while true {
                if Task.isCancelled { return nil }
                let done: Bool = try autoreleasepool {
                    guard let data = try handle.read(upToCount: chunkSize), !data.isEmpty else { return true }
                    read += Int64(data.count)
                    digest.update(data)
                    return false
                }
                if done { break }
            }
        } catch {
            return nil
        }
        return read == length ? digest.finish() : nil
    }
}

#if !canImport(ObjectiveC)
private func autoreleasepool<T>(invoking body: () throws -> T) rethrows -> T { try body() }
#endif

/// SHA-256 where CryptoKit is available, otherwise two 64-bit FNV-1a hashes.
struct ContentDigest {
    #if canImport(CryptoKit)
    private var sha = SHA256()

    mutating func update(_ data: Data) { sha.update(data: data) }

    func finish() -> String { sha.finalize().map { String(format: "%02x", $0) }.joined() }
    #else
    private var a: UInt64 = 0xcbf2_9ce4_8422_2325
    private var b: UInt64 = 0x8422_2325_cbf2_9ce4

    mutating func update(_ data: Data) {
        for byte in data {
            a = (a ^ UInt64(byte)) &* 0x100_0000_01b3
            b = (b ^ UInt64(byte ^ 0x5a)) &* 0x100_0000_01b3
        }
    }

    func finish() -> String { String(format: "%016llx%016llx", a, b) }
    #endif
}

/// Which copies are ticked for the Trash, and which copy of each group is kept.
/// The kept copy can never be ticked, so every group always keeps at least one copy.
public struct DuplicateSelection: Sendable, Equatable {
    public private(set) var kept: [String: String] = [:]
    public private(set) var ticked: Set<String> = []

    public init() {}

    /// Keeps the suggested copy of each group and ticks the rest.
    public init(groups: [DuplicateGroup]) {
        for group in groups {
            kept[group.id] = group.suggestedKeep.path
            ticked.formUnion(group.files.dropFirst().map(\.path))
        }
    }

    public func keptPath(in group: DuplicateGroup) -> String {
        if let path = kept[group.id], group.files.contains(where: { $0.path == path }) { return path }
        return group.suggestedKeep.path
    }

    public func isKept(_ file: DuplicateFile, in group: DuplicateGroup) -> Bool {
        keptPath(in: group) == file.path
    }

    public func isTicked(_ file: DuplicateFile, in group: DuplicateGroup) -> Bool {
        !isKept(file, in: group) && ticked.contains(file.path)
    }

    /// Keeps `file` instead. The copy that was kept before is ticked in its place.
    public mutating func keep(_ file: DuplicateFile, in group: DuplicateGroup) {
        guard group.files.contains(file) else { return }
        let previous = keptPath(in: group)
        kept[group.id] = file.path
        ticked.remove(file.path)
        if previous != file.path { ticked.insert(previous) }
    }

    public mutating func toggle(_ file: DuplicateFile, in group: DuplicateGroup) {
        guard group.files.contains(file), !isKept(file, in: group) else { return }
        if ticked.contains(file.path) { ticked.remove(file.path) } else { ticked.insert(file.path) }
    }

    /// Ticks or unticks every copy of the group except the kept one.
    public mutating func setAll(_ group: DuplicateGroup, selected: Bool) {
        let others = group.files.map(\.path).filter { $0 != keptPath(in: group) }
        if selected { ticked.formUnion(others) } else { ticked.subtract(others) }
    }

    public mutating func remove(_ removed: Set<String>) {
        ticked.subtract(removed)
    }

    public func state(of group: DuplicateGroup) -> JunkSelection.State {
        let count = selectedFiles(in: group).count
        if count == 0 { return .none }
        return count == group.files.count - 1 ? .all : .some
    }

    /// The ticked copies of a group. Never every copy.
    public func selectedFiles(in group: DuplicateGroup) -> [DuplicateFile] {
        let keep = keptPath(in: group)
        let out = group.files.filter { $0.path != keep && ticked.contains($0.path) }
        return out.count < group.files.count ? out : []
    }

    public func selectedFiles(in groups: [DuplicateGroup]) -> [DuplicateFile] {
        groups.flatMap { selectedFiles(in: $0) }
    }

    public func selectedBytes(in groups: [DuplicateGroup]) -> Int64 {
        selectedFiles(in: groups).reduce(0) { $0 + $1.bytes }
    }

    /// What a clean may move to the Trash: the ticked copies of groups whose kept copy is still there.
    public func removableFiles(in groups: [DuplicateGroup],
                               fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) -> [DuplicateFile] {
        groups.filter { fileExists(keptPath(in: $0)) }.flatMap { selectedFiles(in: $0) }
    }
}
