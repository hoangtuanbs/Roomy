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
    }
}
