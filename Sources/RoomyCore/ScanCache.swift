import Foundation

/// A copy of a scan tree's arrays, cheap to take (the arrays are copied on write) and safe to encode off the main thread.
public struct ScanSnapshot: Sendable, Equatable {
    public let rootPath: String
    public let scannedAt: Date
    public let names: [String]
    public let parents: [Int32]
    public let kinds: [NodeKind]
    public let flags: [NodeFlags]
    public let sizes: [Int64]
    public let fileCounts: [Int32]
    public let modified: [Int64]

    public var count: Int { names.count }

    /// Bumped whenever the file layout changes; older files are ignored.
    public static let formatVersion: UInt32 = 1
    static let magic: [UInt8] = Array("RMYS".utf8)

    /// A compact little-endian file: a header, then one record per node. Removed nodes are left out.
    public func encoded() -> Data {
        var out = ByteWriter()
        out.bytes.reserveCapacity(count * 40 + rootPath.utf8.count + 32)
        out.bytes.append(contentsOf: Self.magic)
        out.write(Self.formatVersion)
        out.write(scannedAt.timeIntervalSince1970.bitPattern)
        out.write(string: rootPath)

        var newIndex = [Int32](repeating: -1, count: count)
        var kept: [Int] = []
        kept.reserveCapacity(count)
        for i in 0..<count {
            if i > 0 && (flags[i].contains(.removed) || newIndex[Int(parents[i])] < 0) { continue }
            newIndex[i] = Int32(kept.count)
            kept.append(i)
        }
        out.write(UInt32(kept.count))
        for i in kept {
            out.write(i == 0 ? Int32(-1) : newIndex[Int(parents[i])])
            out.write(kinds[i].rawValue)
            out.write(flags[i].rawValue)
            out.write(sizes[i])
            out.write(fileCounts[i])
            out.write(modified[i])
            out.write(string: i == 0 ? "" : names[i])
        }
        return Data(out.bytes)
    }

    public init(decoding data: Data) throws {
        var reader = ByteReader(Array(data))
        guard try reader.bytes(4) == Self.magic else { throw ScanCacheError.notACacheFile }
        guard try reader.read(UInt32.self) == Self.formatVersion else { throw ScanCacheError.otherVersion }
        let scannedAt = Date(timeIntervalSince1970: Double(bitPattern: try reader.read(UInt64.self)))
        let rootPath = try reader.string()
        let count = Int(try reader.read(UInt32.self))
        guard count > 0, count <= reader.remaining / 27 + 1 else { throw ScanCacheError.damaged }

        var names = [String](), parents = [Int32](), kinds = [NodeKind](), flags = [NodeFlags]()
        var sizes = [Int64](), fileCounts = [Int32](), modified = [Int64]()
        names.reserveCapacity(count); parents.reserveCapacity(count); kinds.reserveCapacity(count)
        flags.reserveCapacity(count); sizes.reserveCapacity(count); fileCounts.reserveCapacity(count)
        modified.reserveCapacity(count)
        for i in 0..<count {
            let parent = try reader.read(Int32.self)
            guard i == 0 ? parent == -1 : (parent >= 0 && Int(parent) < i) else { throw ScanCacheError.damaged }
            guard let kind = NodeKind(rawValue: try reader.read(UInt8.self)) else { throw ScanCacheError.damaged }
            parents.append(parent)
            kinds.append(kind)
            flags.append(NodeFlags(rawValue: try reader.read(UInt8.self)))
            sizes.append(try reader.read(Int64.self))
            fileCounts.append(try reader.read(Int32.self))
            modified.append(try reader.read(Int64.self))
            let name = try reader.string()
            names.append(i == 0 ? rootPath : name)
        }
        self.init(rootPath: rootPath, scannedAt: scannedAt, names: names, parents: parents, kinds: kinds,
                  flags: flags, sizes: sizes, fileCounts: fileCounts, modified: modified)
    }

    init(rootPath: String, scannedAt: Date, names: [String], parents: [Int32], kinds: [NodeKind], flags: [NodeFlags],
         sizes: [Int64], fileCounts: [Int32], modified: [Int64]) {
        self.rootPath = rootPath
        self.scannedAt = scannedAt
        self.names = names
        self.parents = parents
        self.kinds = kinds
        self.flags = flags
        self.sizes = sizes
        self.fileCounts = fileCounts
        self.modified = modified
    }
}

public enum ScanCacheError: Error, Equatable {
    case notACacheFile
    case otherVersion
    case damaged
}

extension ScanTree {
    /// The tree as it is now, for saving.
    public func snapshot(scannedAt: Date) -> ScanSnapshot {
        ScanSnapshot(rootPath: rootPath, scannedAt: scannedAt, names: names, parents: parents, kinds: kinds,
                     flags: flags, sizes: sizes, fileCounts: fileCounts, modified: modified)
    }

    /// Rebuilds a tree from a saved snapshot. Sizes and file counts are already totals.
    public convenience init(snapshot s: ScanSnapshot) {
        self.init(rootPath: s.rootPath, size: s.sizes.first ?? 0, modified: s.modified.first ?? 0)
        if let rootFlags = s.flags.first { insertFlags(rootFlags, at: ScanTree.root) }
        for i in 1..<max(1, s.count) {
            append(name: s.names[i], parent: s.parents[i], kind: s.kinds[i], size: s.sizes[i],
                   modified: s.modified[i], flags: s.flags[i])
        }
        restoreTotals(sizes: s.sizes, fileCounts: s.fileCounts)
    }
}

/// Keeps the last scan of each folder in `~/Library/Caches/<bundle id>/Scans`, so it can be shown at once next time.
public struct ScanCache: Sendable {
    public let directory: String

    public init(directory: String) {
        self.directory = directory
    }

    public static func standard(bundleID: String) -> ScanCache {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?.path
            ?? NSHomeDirectory() + "/Library/Caches"
        return ScanCache(directory: caches + "/" + bundleID + "/Scans")
    }

    /// One file per scanned folder, named by a hash of its path.
    public func filePath(forRoot root: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in DiskScanner.standardize(root).utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100_0000_01b3
        }
        return directory + "/" + String(hash, radix: 16) + ".roomyscan"
    }

    public func save(_ snapshot: ScanSnapshot) throws {
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        try snapshot.encoded().write(to: URL(fileURLWithPath: filePath(forRoot: snapshot.rootPath)), options: .atomic)
    }

    /// The saved scan of `root`, or nil when there is none or it cannot be read.
    public func load(root: String) -> ScanSnapshot? {
        let root = DiskScanner.standardize(root)
        guard let data = FileManager.default.contents(atPath: filePath(forRoot: root)),
              let snapshot = try? ScanSnapshot(decoding: data),
              snapshot.rootPath == root else { return nil }
        return snapshot
    }

    public func remove(root: String) {
        try? FileManager.default.removeItem(atPath: filePath(forRoot: root))
    }
}

struct ByteWriter {
    var bytes: [UInt8] = []

    mutating func write<T: FixedWidthInteger>(_ value: T) {
        withUnsafeBytes(of: value.littleEndian) { bytes.append(contentsOf: $0) }
    }

    mutating func write(string: String) {
        let utf8 = Array(string.utf8)
        write(UInt32(utf8.count))
        bytes.append(contentsOf: utf8)
    }
}

struct ByteReader {
    let bytes: [UInt8]
    var offset = 0

    init(_ bytes: [UInt8]) { self.bytes = bytes }

    var remaining: Int { bytes.count - offset }

    mutating func read<T: FixedWidthInteger>(_ type: T.Type) throws -> T {
        let size = MemoryLayout<T>.size
        guard remaining >= size else { throw ScanCacheError.damaged }
        let value = bytes.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: T.self) }
        offset += size
        return T(littleEndian: value)
    }

    mutating func bytes(_ n: Int) throws -> [UInt8] {
        guard n >= 0, remaining >= n else { throw ScanCacheError.damaged }
        defer { offset += n }
        return Array(bytes[offset..<offset + n])
    }

    mutating func string() throws -> String {
        let length = Int(try read(UInt32.self))
        return String(decoding: try bytes(length), as: UTF8.self)
    }
}
