#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

struct RawEntry: Sendable {
    var name: String
    var kind: NodeKind
    var allocated: Int64
    var device: UInt64
    var inode: UInt64
    var linkCount: UInt64
    var modified: Int64
}

/// POSIX directory reads. Never follows symlinks.
enum DirectoryReader {
    static func list(path: String) -> [RawEntry]? {
        let fd = open(path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        guard let dir = fdopendir(fd) else {
            close(fd)
            return nil
        }
        defer { closedir(dir) }

        var entries: [RawEntry] = []
        while let ent = readdir(dir) {
            let name = withUnsafeBytes(of: ent.pointee.d_name) { raw in
                String(cString: raw.bindMemory(to: CChar.self).baseAddress!)
            }
            if name == "." || name == ".." { continue }
            var st = stat()
            guard fstatat(fd, name, &st, AT_SYMLINK_NOFOLLOW) == 0 else { continue }
            entries.append(makeEntry(name: name, st))
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
        #else
        let mtime = Int64(st.st_mtim.tv_sec)
        #endif
        return RawEntry(
            name: name,
            kind: kind,
            allocated: Int64(st.st_blocks) * 512,
            device: UInt64(truncatingIfNeeded: st.st_dev),
            inode: UInt64(truncatingIfNeeded: st.st_ino),
            linkCount: UInt64(truncatingIfNeeded: st.st_nlink),
            modified: mtime
        )
    }
}
