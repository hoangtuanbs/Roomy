import Foundation

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

    public init(homePath: String = NSHomeDirectory()) {
        self.homePath = DiskScanner.standardize(homePath)
    }

    static let systemPrefixes = [
        "/System", "/bin", "/sbin", "/usr", "/etc", "/dev",
        "/private/etc", "/private/var/db", "/private/var/vm", "/Library/Apple",
    ]
    static let systemExceptions = ["/usr/local"]

    static let standardHomeFolders = [
        "Desktop", "Documents", "Downloads", "Library", "Pictures", "Movies", "Music",
        "Applications", "Public",
    ]

    public func verdict(for rawPath: String) -> SafetyVerdict {
        let path = DiskScanner.standardize(rawPath)

        if path == "/" { return .blocked(String(localized: "This is the whole disk.")) }
        if Self.isVolumeRoot(path) { return .blocked(String(localized: "This is the root of a disk.")) }
        if path == homePath { return .blocked(String(localized: "This is your home folder.")) }
        if homePath.hasPrefix(path + "/") { return .blocked(String(localized: "This folder contains your home folder.")) }

        let inException = Self.systemExceptions.contains { Self.isSameOrInside(path, $0) }
        if !inException, Self.systemPrefixes.contains(where: { Self.isSameOrInside(path, $0) }) {
            return .blocked(String(localized: "macOS needs this to run."))
        }

        let home = homePath
        if Self.isSameOrInside(path, home + "/Library/Keychains") {
            return .blocked(String(localized: "Keychains hold your passwords."))
        }
        if Self.isSameOrInside(path, home + "/Library/Mobile Documents") {
            return .blocked(String(localized: "This is iCloud Drive. Removing it here removes it from all your devices."))
        }
        if Self.isSameOrInside(path, home + "/Library/CloudStorage") {
            return .blocked(String(localized: "This is a cloud drive. Removing it here can remove it from the cloud too."))
        }
        if path.contains(".photoslibrary/") {
            return .blocked(String(localized: "This is inside a Photos library. Delete photos in the Photos app instead."))
        }
        if Self.isSameOrInside(path, home + "/Library/Mail") {
            return .blocked(String(localized: "This is Mail's own store. Removing files here can damage Mail; remove attachments in Mail instead."))
        }
        if let verdict = Self.mobileSyncVerdict(path, home: home) { return verdict }
        for folder in Self.standardHomeFolders where path == home + "/" + folder {
            return .blocked(String(localized: "macOS expects this folder to exist. Clean up what is inside it instead."))
        }

        if path.hasSuffix(".photoslibrary") {
            return .caution(String(localized: "This is a whole Photos library."))
        }
        if Self.isSameOrInside(path, home + "/Library") {
            return .caution(String(localized: "Apps keep settings and data in Library. Only remove this if you know what it is."))
        }
        if Self.isSameOrInside(path, "/Library") || Self.isSameOrInside(path, "/Applications") {
            return .caution(String(localized: "This is shared by all users and may need an administrator password."))
        }
        if path.hasSuffix("/.git") {
            return .caution(String(localized: "This is a Git repository's history."))
        }
        return .allowed
    }

    /// iPhone and iPad backups may only go to the Trash whole, one backup folder at a time.
    static func mobileSyncVerdict(_ path: String, home: String) -> SafetyVerdict? {
        let mobileSync = home + "/Library/Application Support/MobileSync"
        guard isSameOrInside(path, mobileSync) else { return nil }
        let backups = mobileSync + "/Backup"
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
        return parts.count == 2 && parts[0] == "Volumes"
    }
}

public enum Selection {
    public static func normalized(_ paths: [String]) -> [String] {
        let unique = Array(Set(paths.map(DiskScanner.standardize))).sorted()
        var result: [String] = []
        for path in unique {
            if let last = result.last, SafetyPolicy.isSameOrInside(path, last) { continue }
            result.append(path)
        }
        return result
    }
}
