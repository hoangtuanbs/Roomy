#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

struct RawEntry: Sendable {
    var name: String
    var kind: NodeKind
    var allocated: Int64
    /// The file's length in bytes, as opposed to the space it takes on disk.
    var length: Int64 = 0
    var device: UInt64
    var inode: UInt64
    var linkCount: UInt64
    var modified: Int64
    /// The BSD file flags (`st_flags`), such as `SF_DATALESS`.
    var fileFlags: UInt32 = 0
    /// Set for an APFS file that shares blocks with a clone of it; nil when it shares none or it was not asked.
    var clone: CloneAttributes? = nil
}

/// What APFS says about a file that may share its blocks with clones of it (`clonefile`, Finder's Duplicate).
struct CloneAttributes: Sendable, Equatable {
    /// Pure clones of each other have the same id.
    var id: UInt64
    /// The space only this file uses: what deleting it would free.
    var privateBytes: Int64
}

/// POSIX directory reads. Never follows symlinks.
enum DirectoryReader {
    /// Files smaller than this are not asked whether they are clones: the extra call costs more than the little space
    /// a small clone could share. On /Applications this keeps the scan within a few percent of a scan without checks.
    static let cloneCheckMinimum: Int64 = 32_768

    /// The entries of a folder. With `clones`, files on APFS of `cloneCheckMinimum` or more are asked whether they
    /// share blocks (one more call), and only those that may are asked for their private size (a second).
    static func list(path: String, clones: Bool = false) -> [RawEntry]? {
        let fd = open(path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        guard let dir = fdopendir(fd) else {
            close(fd)
            return nil
        }
        defer { closedir(dir) }
        let askClones = clones && isAPFS(fd)

        var entries: [RawEntry] = []
        while let ent = readdir(dir) {
            let name = withUnsafeBytes(of: ent.pointee.d_name) { raw in
                String(cString: raw.bindMemory(to: CChar.self).baseAddress!)
            }
            if name == "." || name == ".." { continue }
            var st = stat()
            guard fstatat(fd, name, &st, AT_SYMLINK_NOFOLLOW) == 0 else { continue }
            var entry = makeEntry(name: name, st)
            if askClones && entry.kind == .file && entry.allocated >= cloneCheckMinimum {
                entry.clone = cloneAttributes(fd: fd, name: name, allocated: entry.allocated)
            }
            entries.append(entry)
        }
        return entries
    }

    static func entry(atPath path: String) -> RawEntry? {
        var st = stat()
        guard lstat(path, &st) == 0 else { return nil }
        let name = path.split(separator: "/").last.map(String.init) ?? path
        return makeEntry(name: name, st)
    }

    private static func makeEntry(name: String, _ st: stat) -> RawEntry {
        let kind: NodeKind
        switch st.st_mode & S_IFMT {
        case S_IFDIR: kind = .directory
        case S_IFREG: kind = .file
        case S_IFLNK: kind = .symlink
        default: kind = .other
        }
        #if canImport(Darwin)
        let mtime = Int64(st.st_mtimespec.tv_sec)
        let fileFlags = UInt32(st.st_flags)
        #else
        let mtime = Int64(st.st_mtim.tv_sec)
        let fileFlags: UInt32 = 0
        #endif
        return RawEntry(
            name: name,
            kind: kind,
            allocated: Int64(st.st_blocks) * 512,
            length: Int64(st.st_size),
            device: UInt64(truncatingIfNeeded: st.st_dev),
            inode: UInt64(truncatingIfNeeded: st.st_ino),
            linkCount: UInt64(truncatingIfNeeded: st.st_nlink),
            modified: mtime,
            fileFlags: fileFlags
        )
    }

    // MARK: APFS clones

    // From <sys/attr.h>, written out so an older SDK still builds.
    static let returnedAttributes: UInt32 = 0x8000_0000   // ATTR_CMN_RETURNED_ATTRS
    static let privateSizeAttribute: UInt32 = 0x0000_0008 // ATTR_CMNEXT_PRIVATESIZE
    static let cloneIDAttribute: UInt32 = 0x0000_0100     // ATTR_CMNEXT_CLONEID
    static let extendedFlagsAttribute: UInt32 = 0x0000_0200 // ATTR_CMNEXT_EXT_FLAGS
    static let mayShareBlocks: UInt64 = 0x01               // EF_MAY_SHARE_BLOCKS
    static let sharesAllBlocks: UInt64 = 0x40              // EF_SHARES_ALL_BLOCKS
    /// FSOPT_NOFOLLOW | FSOPT_PACK_INVAL_ATTRS | FSOPT_ATTR_CMN_EXTENDED
    static let attributeOptions: UInt = 0x01 | 0x08 | 0x20

    /// True when the folder open as `fd` is on APFS, the only file system with clones.
    static func isAPFS(_ fd: Int32) -> Bool {
        #if canImport(Darwin)
        var fs = statfs()
        guard fstatfs(fd, &fs) == 0 else { return false }
        let type = withUnsafeBytes(of: fs.f_fstypename) { raw in
            String(cString: raw.bindMemory(to: CChar.self).baseAddress!)
        }
        return type == "apfs"
        #else
        return false
        #endif
    }

    /// The clone id and private size of a file that shares blocks, or nil when it shares none.
    /// Asks for the cheap flags first; the private size, which APFS has to work out, only when they say it may share.
    static func cloneAttributes(fd: Int32, name: String, allocated: Int64) -> CloneAttributes? {
        #if canImport(Darwin)
        guard let first = readAttributes(fd: fd, name: name, fork: cloneIDAttribute | extendedFlagsAttribute),
              first.returned & cloneIDAttribute != 0, first.returned & extendedFlagsAttribute != 0 else { return nil }
        let id = first.values[0], extFlags = first.values[1]
        guard extFlags & mayShareBlocks != 0 else { return nil }
        if extFlags & sharesAllBlocks != 0 { return CloneAttributes(id: id, privateBytes: 0) }
        guard let second = readAttributes(fd: fd, name: name, fork: privateSizeAttribute),
              second.returned & privateSizeAttribute != 0 else { return nil }
        let privateBytes = min(allocated, max(0, Int64(bitPattern: second.values[0])))
        guard privateBytes < allocated else { return nil }
        return CloneAttributes(id: id, privateBytes: privateBytes)
        #else
        return nil
        #endif
    }

    #if canImport(Darwin)
    /// Reads 64-bit extended common attributes, in the order of their bits. `returned` is the fork group of
    /// what the file system returned.
    private static func readAttributes(fd: Int32, name: String, fork: UInt32) -> (returned: UInt32, values: [UInt64])? {
        var request = attrlist()
        request.bitmapcount = 5 // ATTR_BIT_MAP_COUNT
        request.commonattr = returnedAttributes
        request.forkattr = fork
        let count = fork.nonzeroBitCount
        // u_int32_t length, attribute_set_t (five groups), then the values.
        let size = 4 + 20 + 8 * count
        var buffer = [UInt8](repeating: 0, count: size + 8)
        let status = buffer.withUnsafeMutableBytes { raw in
            name.withCString { cName in
                getattrlistat(fd, cName, &request, raw.baseAddress, raw.count, attributeOptions)
            }
        }
        guard status == 0 else { return nil }
        return buffer.withUnsafeBytes { raw in
            let returned = raw.loadUnaligned(fromByteOffset: 4 + 16, as: UInt32.self)
            let values = (0..<count).map { raw.loadUnaligned(fromByteOffset: 24 + 8 * $0, as: UInt64.self) }
            return (returned, values)
        }
    }
    #endif
}
