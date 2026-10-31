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

        if path == "/" { return .blocked("This is the whole disk.") }
        if Self.isVolumeRoot(path) { return .blocked("This is the root of a disk.") }
        if path == homePath { return .blocked("This is your home folder.") }
        if homePath.hasPrefix(path + "/") { return .blocked("This folder contains your home folder.") }

        let inException = Self.systemExceptions.contains { Self.isSameOrInside(path, $0) }
        if !inException, Self.systemPrefixes.contains(where: { Self.isSameOrInside(path, $0) }) {
            return .blocked("macOS needs this to run.")
        }

        let home = homePath
        if Self.isSameOrInside(path, home + "/Library/Keychains") {
            return .blocked("Keychains hold your passwords.")
        }
        if Self.isSameOrInside(path, home + "/Library/Mobile Documents") {
            return .blocked("This is iCloud Drive. Removing it here removes it from all your devices.")
        }
        if Self.isSameOrInside(path, home + "/Library/CloudStorage") {
            return .blocked("This is a cloud drive. Removing it here can remove it from the cloud too.")
        }
        if path.contains(".photoslibrary/") {
            return .blocked("This is inside a Photos library. Delete photos in the Photos app instead.")
        }
        for folder in Self.standardHomeFolders where path == home + "/" + folder {
            return .blocked("macOS expects this folder to exist. Clean up what is inside it instead.")
        }

        if path.hasSuffix(".photoslibrary") {
            return .caution("This is a whole Photos library.")
        }
        if Self.isSameOrInside(path, home + "/Library") {
            return .caution("Apps keep settings and data in Library. Only remove this if you know what it is.")
        }
        if Self.isSameOrInside(path, "/Library") || Self.isSameOrInside(path, "/Applications") {
            return .caution("This is shared by all users and may need an administrator password.")
        }
        if path.hasSuffix("/.git") {
            return .caution("This is a Git repository's history.")
        }
        return .allowed
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
