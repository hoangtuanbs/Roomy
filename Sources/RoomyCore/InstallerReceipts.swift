import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// A package installed by Installer, as its receipt describes it.
public struct PackageInfo: Sendable, Hashable {
    public let id: String
    public let version: String?
    /// The disk it was installed on, usually "/".
    public let volume: String
    /// Where on that disk its files went, such as "" or "Applications".
    public let location: String
    public let installDate: Date?

    public init(id: String, version: String? = nil, volume: String = "/", location: String = "", installDate: Date? = nil) {
        self.id = id
        self.version = version
        self.volume = volume
        self.location = location
        self.installDate = installDate
    }

    /// The folder the package's file list is relative to.
    public var base: String {
        let joined = location.isEmpty ? volume : DiskScanner.join(volume == "/" ? "" : volume, location)
        return DiskScanner.standardize(joined.hasPrefix("/") ? joined : "/" + joined)
    }
}

/// Reads installer receipts. The app uses `SystemPackageDatabase` (`pkgutil`, no admin rights); tests and the flow
/// test use `StaticPackageDatabase`.
public protocol PackageDatabase: Sendable {
    func packageIDs() -> [String]
    func info(_ id: String) -> PackageInfo?
    /// The package's files and folders, relative to its `base`.
    func files(_ id: String) -> [String]?
}

/// Asks `/usr/sbin/pkgutil`, which reads the receipts in /var/db/receipts. It only reads.
public struct SystemPackageDatabase: PackageDatabase {
    public init() {}
    static let pkgutil = "/usr/sbin/pkgutil"

    public func packageIDs() -> [String] {
        guard let output = Command.run(Self.pkgutil, ["--pkgs"], timeout: 20), output.status == 0 else { return [] }
        return output.text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    public func info(_ id: String) -> PackageInfo? {
        guard let output = Command.run(Self.pkgutil, ["--pkg-info-plist", id], timeout: 10), output.status == 0,
              let plist = (try? PropertyListSerialization.propertyList(from: output.stdout, format: nil)) as? [String: Any]
        else { return nil }
        let date = (plist["install-time"] as? Int).map { Date(timeIntervalSince1970: TimeInterval($0)) }
            ?? (plist["install-time"] as? Date)
        return PackageInfo(id: id, version: plist["pkg-version"] as? String, volume: (plist["volume"] as? String) ?? "/",
                           location: (plist["install-location"] as? String) ?? "", installDate: date)
    }

    public func files(_ id: String) -> [String]? {
        guard let output = Command.run(Self.pkgutil, ["--files", id], timeout: 30), output.status == 0 else { return nil }
        return output.text.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
    }
}

/// A fixed list of packages.
public struct StaticPackageDatabase: PackageDatabase {
    public let packages: [(info: PackageInfo, files: [String])]

    public init(_ packages: [(info: PackageInfo, files: [String])]) {
        self.packages = packages
    }

    public func packageIDs() -> [String] { packages.map(\.info.id) }
    public func info(_ id: String) -> PackageInfo? { packages.first { $0.info.id == id }?.info }
    public func files(_ id: String) -> [String]? { packages.first { $0.info.id == id }?.files }
}

/// A file or folder a removed app's package left behind.
public struct ReceiptFile: Sendable, Hashable, Identifiable {
    public var id: String { path }
    public let path: String
    public var bytes: Int64

    public init(path: String, bytes: Int64 = 0) {
        self.path = path
        self.bytes = bytes
    }
}

/// A package whose app is gone, with what it left that you can move to the Trash.
public struct ReceiptFinding: Sendable, Hashable, Identifiable {
    public var id: String { package.id }
    public let package: PackageInfo
    /// The app bundles it installed, none of which is there now.
    public let appPaths: [String]
    /// What is left in places you can change without an administrator.
    public var leftovers: [ReceiptFile]
    /// What is left in places that need an administrator. RoomyDisk leaves these alone.
    public let adminOnly: [String]

    public init(package: PackageInfo, appPaths: [String], leftovers: [ReceiptFile], adminOnly: [String]) {
        self.package = package
        self.appPaths = appPaths
        self.leftovers = leftovers
        self.adminOnly = adminOnly
    }

    /// The name of its app, such as "Flow Tool".
    public var appName: String {
        appPaths.first.map { (($0 as NSString).lastPathComponent as NSString).deletingPathExtension } ?? package.id
    }

    public var bytes: Int64 { leftovers.reduce(0) { $0 + $1.bytes } }

    /// For finding the app's leftovers in the Library by its name.
    public var removedApp: RemovedApp { RemovedApp(bundleID: package.id, name: appName) }
}

/// Finds installer packages whose app has been removed, and the files they left in places you can change.
public struct ReceiptFinder: Sendable {
    public let database: any PackageDatabase
    public let policy: SafetyPolicy

    public init(database: any PackageDatabase, policy: SafetyPolicy) {
        self.database = database
        self.policy = policy
    }

    /// Folders that many packages and macOS share. They are never offered, only what is inside them.
    static let sharedFolders: Set<String> = [
        "Applications/Utilities", "Library/Application Support", "Library/LaunchAgents", "Library/LaunchDaemons",
        "Library/PrivilegedHelperTools", "Library/Preferences", "Library/Frameworks", "Library/Extensions",
        "Library/Audio", "Library/Audio/Plug-Ins", "Library/Audio/Plug-Ins/Components", "Library/Audio/Plug-Ins/VST",
        "Library/Audio/Plug-Ins/VST3", "Library/Audio/Plug-Ins/HAL", "Library/Audio/MIDI Drivers", "Library/Fonts",
        "Library/Internet Plug-Ins", "Library/PreferencePanes", "Library/Printers", "Library/QuickLook",
        "Library/Spotlight", "Library/Services", "Library/Caches", "Library/Logs", "Library/Application Scripts",
        "Library/Input Methods", "Library/Keyboard Layouts", "Library/Screen Savers", "Library/ColorSync",
        "Library/ColorSync/Profiles", "Library/Components", "Library/Developer", "Library/Java",
        "Library/Java/JavaVirtualMachines", "Library/Python", "Library/Ruby", "Library/Perl", "Library/Filesystems",
        "Library/SystemExtensions", "Library/DriverExtensions", "Library/Image Capture", "Library/Image Capture/Devices",
        "usr/local", "usr/local/bin", "usr/local/sbin", "usr/local/lib", "usr/local/share", "usr/local/include",
        "usr/local/etc", "usr/local/libexec", "usr/local/share/man", "usr/local/share/doc", "usr/local/share/man/man1",
        "usr/local/share/man/man3", "usr/local/share/man/man5", "usr/local/share/man/man8", "usr/local/lib/pkgconfig",
        "private/etc", "private/var", "private/tmp", "opt/homebrew", "etc/paths.d", "private/etc/paths.d",
    ]

    /// True for folders no single package owns: the top level of the disk and `sharedFolders`.
    static func isShared(_ relative: String) -> Bool {
        let trimmed = trim(relative)
        if trimmed.isEmpty || !trimmed.contains("/") { return true }
        return sharedFolders.contains(trimmed)
    }

    static func trim(_ relative: String) -> String {
        var path = relative
        while path.hasPrefix("./") { path.removeFirst(2) }
        while path.hasPrefix("/") { path.removeFirst() }
        while path.hasSuffix("/") { path.removeLast() }
        return path
    }

    /// Packages of other makers (not `com.apple.`) that installed apps which are all gone, and what they left.
    /// `installedNames` are the names of apps that are installed, so an app that was moved is not counted as gone.
    /// Nothing is measured; see `measure`.
    public func find(installedNames: Set<String> = []) -> [ReceiptFinding] {
        let ids = database.packageIDs().filter { !$0.lowercased().hasPrefix("com.apple.") }
        var lists: [String: (PackageInfo, [String])] = [:]
        for id in ids {
            guard let info = database.info(id), let files = database.files(id) else { continue }
            lists[id] = (info, files.map(Self.trim).filter { !$0.isEmpty })
        }
        // Every path some package lists, with how many list it, so shared items are never offered.
        var claims: [String: Int] = [:]
        for (_, (info, files)) in lists {
            for file in files { claims[DiskScanner.join(info.base, file), default: 0] += 1 }
        }
        let lowerNames = Set(installedNames.map { $0.lowercased() })

        var findings: [ReceiptFinding] = []
        for id in lists.keys.sorted() {
            guard let (info, files) = lists[id] else { continue }
            let apps = files.filter { file in
                file.hasSuffix(".app") && !file.dropLast(4).contains(".app/")
            }
            guard !apps.isEmpty else { continue }
            let appPaths = apps.map { DiskScanner.join(info.base, $0) }
            let present = appPaths.contains { DirectoryReader.entry(atPath: $0) != nil }
            let names = apps.map { (($0 as NSString).lastPathComponent as NSString).deletingPathExtension.lowercased() }
            if present || names.contains(where: lowerNames.contains) { continue }

            let listed = Set(files)
            var roots: [String] = []
            for file in files where !Self.isShared(file) {
                if apps.contains(where: { file == $0 || file.hasPrefix($0 + "/") }) { continue }
                let parent = (file as NSString).deletingLastPathComponent
                // The topmost item of the package inside a shared folder (or one whose folder it does not list).
                guard Self.isShared(parent) || !listed.contains(parent) else { continue }
                let path = DiskScanner.join(info.base, file)
                guard DirectoryReader.entry(atPath: path) != nil, (claims[path] ?? 0) <= 1 else { continue }
                roots.append(path)
            }
            var leftovers: [ReceiptFile] = []
            var adminOnly: [String] = []
            for path in Selection.normalized(roots) {
                if Self.isUserWritable(path) && !policy.verdict(for: path).isBlocked {
                    leftovers.append(ReceiptFile(path: path))
                } else {
                    adminOnly.append(path)
                }
            }
            findings.append(ReceiptFinding(package: info, appPaths: appPaths, leftovers: leftovers, adminOnly: adminOnly))
        }
        return findings
    }

    /// True when you can move the item to the Trash without an administrator: you can write to the folder it is in,
    /// and, for a folder, to the folder itself.
    static func isUserWritable(_ path: String) -> Bool {
        let parent = (path as NSString).deletingLastPathComponent
        guard access(parent, W_OK) == 0 else { return false }
        if DirectoryReader.entry(atPath: path)?.kind == .directory { return access(path, W_OK) == 0 }
        return true
    }

    /// Measures each leftover, largest first.
    public static func measure(_ findings: [ReceiptFinding]) -> [ReceiptFinding] {
        findings.map { finding in
            var measured = finding
            measured.leftovers = finding.leftovers
                .map { ReceiptFile(path: $0.path, bytes: DiskUsage.allocatedSize(atPath: $0.path)) }
                .sorted { $0.bytes != $1.bytes ? $0.bytes > $1.bytes : $0.path < $1.path }
            return measured
        }
        .sorted { $0.bytes != $1.bytes ? $0.bytes > $1.bytes : $0.package.id < $1.package.id }
    }
}
