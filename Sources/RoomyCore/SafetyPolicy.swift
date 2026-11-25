import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

public enum SafetyVerdict: Equatable, Sendable {
    case allowed
    case caution(String)
    case blocked(String)

    public var isBlocked: Bool {
        if case .blocked = self { return true }
        return false
    }

    public var message: String? {
        switch self {
        case .allowed: return nil
        case .caution(let m), .blocked(let m): return m
        }
    }
}

/// Decides which paths may be moved to the Trash.
public struct SafetyPolicy: Sendable {
    public let homePath: String
    /// The home folder with every link resolved, to judge where a path really leads.
    let resolvedHomePath: String

    public init(homePath: String = NSHomeDirectory()) {
        self.homePath = DiskScanner.standardize(homePath)
        resolvedHomePath = Self.realPath(self.homePath) ?? self.homePath
    }

    static let systemPrefixes = [
        "/System", "/bin", "/sbin", "/usr", "/etc", "/dev",
        "/private/etc", "/private/var/db", "/private/var/vm", "/Library/Apple",
    ]
    static let systemExceptions = ["/usr/local"]

    /// Folders at the top of the disk that macOS expects to exist.
    static let topLevelFolders = ["/Applications", "/Library", "/Users", "/Volumes", "/tmp", "/var"]

    static let standardHomeFolders = [
        "Desktop", "Documents", "Downloads", "Library", "Pictures", "Movies", "Music",
        "Applications", "Public",
    ]

    public func verdict(for rawPath: String) -> SafetyVerdict {
        let path = DiskScanner.standardize(rawPath)
        let direct = Self.verdict(path: path, home: homePath)
        // A link on the way can lead somewhere protected, such as `link/Documents` when `link` points home.
        guard !direct.isBlocked, let real = Self.resolved(rawPath), real != path || resolvedHomePath != homePath else {
            return direct
        }
        return Self.stricter(direct, Self.verdict(path: real, home: resolvedHomePath))
    }

    /// Judges the path as written. Letters are compared without case, as APFS does by default.
    static func verdict(path rawPath: String, home rawHome: String) -> SafetyVerdict {
        let path = rawPath.lowercased()
        let home = rawHome.lowercased()
        func inside(_ folder: String) -> Bool { isSameOrInside(path, folder.lowercased()) }

        if path == "/" { return .blocked(String(localized: "This is the whole disk.")) }
        if Self.isVolumeRoot(path) { return .blocked(String(localized: "This is the root of a disk.")) }
        if path == home { return .blocked(String(localized: "This is your home folder.")) }
        if home.hasPrefix(path + "/") { return .blocked(String(localized: "This folder contains your home folder.")) }

        let inException = systemExceptions.contains { inside($0) }
        if !inException, systemPrefixes.contains(where: { inside($0) }) {
            return .blocked(String(localized: "macOS needs this to run."))
        }
        // A folder that holds system files, such as /private or /Library.
        if systemPrefixes.contains(where: { $0.lowercased().hasPrefix(path + "/") }) {
            return .blocked(String(localized: "macOS needs this to run."))
        }
        if topLevelFolders.contains(where: { $0.lowercased() == path }) {
            return .blocked(String(localized: "macOS expects this folder to exist. Clean up what is inside it instead."))
        }

        if inside(home + "/Library/Keychains") {
            return .blocked(String(localized: "Keychains hold your passwords."))
        }
        if inside(home + "/Library/Mobile Documents") {
            return .blocked(String(localized: "This is iCloud Drive. Removing it here removes it from all your devices."))
        }
        if inside(home + "/Library/CloudStorage") {
            return .blocked(String(localized: "This is a cloud drive. Removing it here can remove it from the cloud too."))
        }
        if path.contains(".photoslibrary/") {
            return .blocked(String(localized: "This is inside a Photos library. Delete photos in the Photos app instead."))
        }
        if inside(home + "/Library/Mail") {
            return .blocked(String(localized: "This is Mail's own store. Removing files here can damage Mail; remove attachments in Mail instead."))
        }
        if let verdict = mobileSyncVerdict(path, home: home) { return verdict }
        for folder in standardHomeFolders where path == home + "/" + folder.lowercased() {
            return .blocked(String(localized: "macOS expects this folder to exist. Clean up what is inside it instead."))
        }

        if path.hasSuffix(".photoslibrary") {
            return .caution(String(localized: "This is a whole Photos library."))
        }
        if inside(home + "/Library") {
            return .caution(String(localized: "Apps keep settings and data in Library. Only remove this if you know what it is."))
        }
        if inside("/Library") || inside("/Applications") {
            return .caution(String(localized: "This is shared by all users and may need an administrator password."))
        }
        if path.hasSuffix("/.git") {
            return .caution(String(localized: "This is a Git repository's history."))
        }
        return .allowed
    }

    /// iPhone and iPad backups may only go to the Trash whole, one backup folder at a time.
    static func mobileSyncVerdict(_ rawPath: String, home: String) -> SafetyVerdict? {
        let path = rawPath.lowercased()
        let mobileSync = (home + "/Library/Application Support/MobileSync").lowercased()
        guard isSameOrInside(path, mobileSync) else { return nil }
        let backups = mobileSync + "/backup"
        if path.hasPrefix(backups + "/") {
            let rest = path.dropFirst(backups.count + 1)
            if !rest.contains("/") {
                return .caution(String(localized: "This is an iPhone or iPad backup. Without it you cannot restore the device to this point."))
            }
            return .blocked(String(localized: "This is part of an iPhone or iPad backup. Removing part of a backup breaks it."))
        }
        return .blocked(String(localized: "Finder keeps iPhone and iPad backups here. Remove single backups instead."))
    }

    static func isSameOrInside(_ path: String, _ folder: String) -> Bool {
        path == folder || path.hasPrefix(folder + "/")
    }

    static func isVolumeRoot(_ path: String) -> Bool {
        let parts = path.split(separator: "/")
        return parts.count == 2 && parts[0].lowercased() == "volumes"
    }

    static func stricter(_ a: SafetyVerdict, _ b: SafetyVerdict) -> SafetyVerdict {
        func rank(_ v: SafetyVerdict) -> Int {
            switch v {
            case .allowed: return 0
            case .caution: return 1
            case .blocked: return 2
            }
        }
        return rank(b) > rank(a) ? b : a
    }

    /// Where a path really leads, with links followed the way the system follows them. A link that is the
    /// item itself is kept, because the Trash moves the link and never what it points to.
    static func resolved(_ rawPath: String) -> String? {
        var path = (rawPath as NSString).expandingTildeInPath
        while path.count > 1 && path.hasSuffix("/") { path.removeLast() }
        guard !path.isEmpty else { return nil }
        if let entry = DirectoryReader.entry(atPath: path), entry.kind != .symlink {
            return realPath(path)
        }
        let name = (path as NSString).lastPathComponent
        let parent = (path as NSString).deletingLastPathComponent
        guard !name.isEmpty, name != "/", name != ".", name != ".." else { return realPath(path) }
        guard let folder = realPath(parent.isEmpty ? "." : parent) else { return nil }
        return DiskScanner.join(folder, name)
    }

    static func realPath(_ path: String) -> String? {
        guard let resolved = realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }
}

public enum Selection {
    /// Each path once, leaving out anything inside another selected path.
    public static func normalized(_ paths: [String]) -> [String] {
        // Shorter paths first, so a folder is always kept before what is inside it.
        let unique = Set(paths.map(DiskScanner.standardize)).sorted { ($0.count, $0) < ($1.count, $1) }
        var kept = Set<String>()
        for path in unique {
            var folder = path
            var nested = false
            while folder != "/", !folder.isEmpty, !nested {
                folder = (folder as NSString).deletingLastPathComponent
                nested = kept.contains(folder)
            }
            if !nested { kept.insert(path) }
        }
        return kept.sorted()
    }
}
