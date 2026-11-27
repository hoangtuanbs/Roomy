import Foundation

public enum NodeKind: UInt8, Sendable {
    case file
    case directory
    /// A directory that macOS shows as a single item, such as an `.app` bundle.
    case package
    case symlink
    case other

    public var isContainer: Bool { self == .directory || self == .package }
}

public struct NodeFlags: OptionSet, Sendable, Hashable {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }

    public static let inaccessible = NodeFlags(rawValue: 1 << 0)
    public static let otherVolume = NodeFlags(rawValue: 1 << 1)
    public static let hardLinkDuplicate = NodeFlags(rawValue: 1 << 2)
    public static let excluded = NodeFlags(rawValue: 1 << 3)
    public static let removed = NodeFlags(rawValue: 1 << 4)
    /// An APFS clone that shares its blocks with other files. Only the first of its family found carries the shared
    /// space; the others count just what is their own.
    public static let clone = NodeFlags(rawValue: 1 << 5)
    /// Stored in the cloud only (iCloud Drive, Dropbox and the like): it takes no space on this Mac.
    public static let dataless = NodeFlags(rawValue: 1 << 6)
}

/// How a clone shares its space.
public struct CloneInfo: Sendable, Equatable {
    /// The same for every file of a family of pure clones (and their disk).
    public let family: UInt64
    /// The space this file shares with its clones.
    public let sharedBytes: Int64
    /// This file's size includes the shared space. One file of each family in a scan carries it.
    public var carriesShared: Bool

    public init(family: UInt64, sharedBytes: Int64, carriesShared: Bool) {
        self.family = family
        self.sharedBytes = sharedBytes
        self.carriesShared = carriesShared
    }
}

/// Scan result as parallel arrays. Node 0 is the root; a child always has a larger index than its parent.
public final class ScanTree: @unchecked Sendable {
    public typealias Index = Int32
    public static let root: Index = 0

    public let rootPath: String
    public private(set) var names: [String] = []
    public private(set) var parents: [Index] = []
    public private(set) var kinds: [NodeKind] = []
    public private(set) var flags: [NodeFlags] = []
    public private(set) var sizes: [Int64] = []
    public private(set) var fileCounts: [Int32] = []
    public private(set) var modified: [Int64] = []
    public private(set) var children: [[Index]] = []
    /// Only for nodes flagged `.clone`.
    public private(set) var clones: [Index: CloneInfo] = [:]
    /// The size in the cloud of files flagged `.dataless`.
    public private(set) var onlineSizes: [Index: Int64] = [:]

    public var count: Int { names.count }

    init(rootPath: String, size: Int64, modified: Int64) {
        self.rootPath = rootPath
        append(name: rootPath, parent: -1, kind: .directory, size: size, modified: modified, flags: [])
    }

    @discardableResult
    func append(name: String, parent: Index, kind: NodeKind, size: Int64, modified: Int64, flags: NodeFlags) -> Index {
        let index = Index(names.count)
        names.append(name)
        parents.append(parent)
        kinds.append(kind)
        self.flags.append(flags)
        sizes.append(size)
        fileCounts.append(kind.isContainer ? 0 : 1)
        self.modified.append(modified)
        children.append([])
        if parent >= 0 { children[Int(parent)].append(index) }
        return index
    }

    func insertFlags(_ newFlags: NodeFlags, at index: Index) {
        flags[Int(index)].formUnion(newFlags)
    }

    func setClone(_ info: CloneInfo?, at index: Index) {
        clones[index] = info
    }

    func setOnlineSize(_ bytes: Int64?, at index: Index) {
        onlineSizes[index] = bytes
    }

    /// How many other files in the scan share their blocks with the clone `i`.
    public func cloneSiblingCount(_ i: Index) -> Int {
        guard let family = clones[i]?.family else { return 0 }
        return clones.reduce(0) { count, item in
            item.key != i && item.value.family == family && !flags[Int(item.key)].contains(.removed) ? count + 1 : count
        }
    }

    /// The families whose shared space is carried by a file outside `i`, so a fresh scan of `i` counts its
    /// members of those families by their own space only.
    public func cloneFamilies(carriedOutside i: Index) -> Set<UInt64> {
        var out = Set<UInt64>()
        for (node, info) in clones where info.carriesShared && !flags[Int(node)].contains(.removed) {
            if node != i && !isAncestor(i, of: node) { out.insert(info.family) }
        }
        return out
    }

    /// Gives each family of clones whose carrier left the tree (moved to the Trash or rescanned away) a new carrier,
    /// since the shared space is still used by the files that are left.
    func repairCloneCarriers() {
        guard !clones.isEmpty else { return }
        var carried = Set<UInt64>()
        for (node, info) in clones where info.carriesShared && !flags[Int(node)].contains(.removed) {
            carried.insert(info.family)
        }
        for node in clones.keys.sorted() {
            guard var info = clones[node], !info.carriesShared, !flags[Int(node)].contains(.removed),
                  carried.insert(info.family).inserted else { continue }
            info.carriesShared = true
            clones[node] = info
            sizes[Int(node)] += info.sharedBytes
            var n = node
            while let p = parent(n) {
                sizes[Int(p)] += info.sharedBytes
                n = p
            }
        }
    }

    func finalize() {
        var i = count - 1
        while i > 0 {
            let p = Int(parents[i])
            sizes[p] += sizes[i]
            fileCounts[p] += fileCounts[i]
            i -= 1
        }
        let sizes = self.sizes
        for n in 0..<children.count where children[n].count > 1 {
            children[n].sort { sizes[Int($0)] > sizes[Int($1)] }
        }
    }

    public func name(_ i: Index) -> String { names[Int(i)] }
    public func size(_ i: Index) -> Int64 { sizes[Int(i)] }
    public func kind(_ i: Index) -> NodeKind { kinds[Int(i)] }
    public func flags(_ i: Index) -> NodeFlags { flags[Int(i)] }
    public func parent(_ i: Index) -> Index? { i == Self.root ? nil : parents[Int(i)] }
    public func children(_ i: Index) -> [Index] { children[Int(i)] }
    public func fileCount(_ i: Index) -> Int32 { fileCounts[Int(i)] }
    public func modifiedDate(_ i: Index) -> Date { Date(timeIntervalSince1970: TimeInterval(modified[Int(i)])) }

    public func path(of i: Index) -> String {
        if i == Self.root { return rootPath }
        var parts: [String] = []
        var n = i
        while n != Self.root {
            parts.append(names[Int(n)])
            n = parents[Int(n)]
        }
        let prefix = rootPath == "/" ? "" : rootPath
        return prefix + "/" + parts.reversed().joined(separator: "/")
    }

    public func lineage(of i: Index) -> [Index] {
        var out: [Index] = [i]
        var n = i
        while let p = parent(n) {
            out.append(p)
            n = p
        }
        return out.reversed()
    }

    public func isAncestor(_ a: Index, of b: Index) -> Bool {
        var n = b
        while let p = parent(n) {
            if p == a { return true }
            n = p
        }
        return false
    }

    public func index(ofPath path: String) -> Index? {
        if path == rootPath { return Self.root }
        let prefix = rootPath == "/" ? "/" : rootPath + "/"
        guard path.hasPrefix(prefix) else { return nil }
        var n = Self.root
        for component in path.dropFirst(prefix.count).split(separator: "/") {
            guard let next = children[Int(n)].first(where: { names[Int($0)] == component }) else { return nil }
            n = next
        }
        return n
    }

    public func largestFiles(limit: Int) -> [Index] {
        var candidates: [Index] = []
        candidates.reserveCapacity(count / 2)
        for i in 0..<count where kinds[i] == .file && sizes[i] > 0 && !flags[i].contains(.removed) {
            candidates.append(Index(i))
        }
        let sizes = self.sizes
        candidates.sort { sizes[Int($0)] > sizes[Int($1)] }
        return Array(candidates.prefix(limit))
    }

    public func containsDescendant(named target: String, under i: Index) -> Bool {
        var stack = children[Int(i)]
        while let n = stack.popLast() {
            if names[Int(n)] == target { return true }
            stack.append(contentsOf: children[Int(n)])
        }
        return false
    }

    /// Adds a file created after the scan, such as an archive, and adds its size to every ancestor.
    @discardableResult
    public func insertFile(named name: String, in parent: Index, size: Int64, modified: Date) -> Index {
        let index = append(name: name, parent: parent, kind: .file, size: size,
                           modified: Int64(modified.timeIntervalSince1970), flags: [])
        var n = index
        while let p = self.parent(n) {
            sizes[Int(p)] += size
            fileCounts[Int(p)] += 1
            n = p
        }
        let sizes = self.sizes
        children[Int(parent)].sort { sizes[Int($0)] > sizes[Int($1)] }
        return index
    }

    /// Removes a trashed node and subtracts its size from every ancestor.
    public func detach(_ i: Index) {
        guard i != Self.root, !flags[Int(i)].contains(.removed) else { return }
        let size = sizes[Int(i)]
        let files = fileCounts[Int(i)]
        var n = i
        while let p = parent(n) {
            sizes[Int(p)] -= size
            fileCounts[Int(p)] -= files
            n = p
        }
        let p = Int(parents[Int(i)])
        children[p].removeAll { $0 == i }
        var stack = [i]
        while let m = stack.popLast() {
            flags[Int(m)].insert(.removed)
            stack.append(contentsOf: children[Int(m)])
        }
        repairCloneCarriers()
    }

    /// Sets totals read from a saved snapshot and sorts children largest first.
    func restoreTotals(sizes newSizes: [Int64], fileCounts newCounts: [Int32]) {
        guard newSizes.count == count, newCounts.count == count else { return }
        sizes = newSizes
        fileCounts = newCounts
        let sizes = self.sizes
        for n in 0..<children.count where children[n].count > 1 {
            children[n].sort { sizes[Int($0)] > sizes[Int($1)] }
        }
    }

    /// Replaces what is inside the folder `i` with a fresh scan of that folder, and updates the totals of `i` and every
    /// ancestor. The old nodes stay in the arrays, marked removed, so other indexes keep pointing at the same items.
    public func replaceSubtree(_ i: Index, with fresh: ScanTree) {
        guard !flags[Int(i)].contains(.removed), kinds[Int(i)].isContainer else { return }
        var stack = children[Int(i)]
        while let m = stack.popLast() {
            flags[Int(m)].insert(.removed)
            stack.append(contentsOf: children[Int(m)])
        }
        children[Int(i)] = []

        var map = [Index](repeating: -1, count: fresh.count)
        map[0] = i
        for n in 1..<max(1, fresh.count) where !fresh.flags[n].contains(.removed) {
            let parent = map[Int(fresh.parents[n])]
            guard parent >= 0 else { continue }
            map[n] = append(name: fresh.names[n], parent: parent, kind: fresh.kinds[n], size: fresh.sizes[n],
                            modified: fresh.modified[n], flags: fresh.flags[n])
            fileCounts[Int(map[n])] = fresh.fileCounts[n]
            if let clone = fresh.clones[Index(n)] { clones[map[n]] = clone }
            if let online = fresh.onlineSizes[Index(n)] { onlineSizes[map[n]] = online }
        }

        let sizeDelta = fresh.size(Self.root) - sizes[Int(i)]
        let fileDelta = fresh.fileCount(Self.root) - fileCounts[Int(i)]
        sizes[Int(i)] = fresh.size(Self.root)
        fileCounts[Int(i)] = fresh.fileCount(Self.root)
        modified[Int(i)] = fresh.modified[0]
        flags[Int(i)] = fresh.flags[0]
        var n = i
        while let p = parent(n) {
            sizes[Int(p)] += sizeDelta
            fileCounts[Int(p)] += fileDelta
            n = p
        }
        repairCloneCarriers()
        let sizes = self.sizes
        for node in map + lineage(of: i).dropLast() where node >= 0 && children[Int(node)].count > 1 {
            children[Int(node)].sort { sizes[Int($0)] > sizes[Int($1)] }
        }
    }
}
