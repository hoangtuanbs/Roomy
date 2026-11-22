import Foundation
#if canImport(CoreServices)
import CoreServices
#endif

/// An app bundle found in an Applications folder.
public struct InstalledApp: Sendable, Hashable, Identifiable {
    public var id: String { path }
    public let path: String
    public let name: String
    public let bundleID: String?
    public let version: String?
    /// The bundle's .icns file, when its Info.plist names one.
    public let iconPath: String?
    /// Space the bundle takes on disk. Zero until measured.
    public var bytes: Int64
    public var lastUsed: Date?
    /// Bundle identifiers of helpers, login items and extensions inside the bundle. They count as installed, but their
    /// files are not offered as leftovers, because other apps from the same maker may share them.
    public let embeddedIDs: [String]

    public init(path: String, name: String, bundleID: String?, version: String?, iconPath: String?,
                bytes: Int64 = 0, lastUsed: Date? = nil, embeddedIDs: [String] = []) {
        self.path = path
        self.name = name
        self.bundleID = bundleID
        self.version = version
        self.iconPath = iconPath
        self.bytes = bytes
        self.lastUsed = lastUsed
        self.embeddedIDs = embeddedIDs
    }

    public var isApple: Bool { bundleID?.lowercased().hasPrefix("com.apple.") ?? false }
}

/// Where in the Library a leftover lives.
public enum LeftoverKind: String, CaseIterable, Sendable {
    case applicationSupport, caches, preferences, savedState, containers, groupContainers
    case applicationScripts, httpStorages, webKit, logs, launchAgents, cookies

    /// The folder under `~/Library`.
    public var folder: String {
        switch self {
        case .applicationSupport: return "Application Support"
        case .caches: return "Caches"
        case .preferences: return "Preferences"
        case .savedState: return "Saved Application State"
        case .containers: return "Containers"
        case .groupContainers: return "Group Containers"
        case .applicationScripts: return "Application Scripts"
        case .httpStorages: return "HTTPStorages"
        case .webKit: return "WebKit"
        case .logs: return "Logs"
        case .launchAgents: return "LaunchAgents"
        case .cookies: return "Cookies"
        }
    }

    public var title: String {
        switch self {
        case .applicationSupport: return "App data"
        case .caches: return "Caches"
        case .preferences: return "Settings"
        case .savedState: return "Saved window state"
        case .containers: return "Sandbox container"
        case .groupContainers: return "Shared container"
        case .applicationScripts: return "Scripts"
        case .httpStorages: return "Web storage"
        case .webKit: return "WebKit data"
        case .logs: return "Logs"
        case .launchAgents: return "Launch agents"
        case .cookies: return "Cookies"
        }
    }
}

/// A file or folder in the Library that belongs to an app.
public struct Leftover: Sendable, Hashable, Identifiable {
    public var id: String { path }
    public let path: String
    public let name: String
    public let kind: LeftoverKind
    public var bytes: Int64
    /// Matched only through a dotted child of the bundle identifier (`com.maker.app.beta`), so it may belong to a
    /// different app. The app shows it unticked, to review first.
    public let needsReview: Bool

    public init(path: String, name: String, kind: LeftoverKind, bytes: Int64 = 0, needsReview: Bool = false) {
        self.path = path
        self.name = name
        self.kind = kind
        self.bytes = bytes
        self.needsReview = needsReview
    }
}

/// Library items named by the bundle identifier of an app that is no longer installed.
public struct OrphanGroup: Sendable, Hashable, Identifiable {
    public var id: String { bundleID }
    public let bundleID: String
    public let items: [Leftover]

    public init(bundleID: String, items: [Leftover]) {
        self.bundleID = bundleID
        self.items = items
    }

    public var bytes: Int64 { items.reduce(0) { $0 + $1.bytes } }
}

/// Lists installed apps and finds the files they leave in the user's Library. It only looks; removing goes through
/// `CleanupService`. Matching is strict: a Library item belongs to an app only when it is named exactly by the app's
/// bundle identifier (or a dotted child of it that no other installed app owns), or exactly by the app's name.
public struct AppUninstaller: Sendable {
    public let homePath: String
    public let appFolders: [String]
    public let policy: SafetyPolicy

    /// Folder names that are shared by many apps of one maker, so a same-named app must never claim them.
    static let sharedNames: Set<String> = [
        "adobe", "apple", "google", "microsoft", "mozilla", "jetbrains", "crashreporter", "crashpad", "caches",
        "logs", "preferences", "cloudkit", "com.apple", "electron", "squirrel", "sentry", "temp", "tmp", "data",
        "default", "app", "application", "helper", "updater", "update", "backup", "backups", "plugins", "fonts",
    ]

    public init(homePath: String = NSHomeDirectory(), appFolders: [String]? = nil) {
        let home = DiskScanner.standardize(homePath)
        self.homePath = home
        self.appFolders = appFolders ?? ["/Applications", home + "/Applications"]
        self.policy = SafetyPolicy(homePath: home)
    }

    public var libraryPath: String { homePath + "/Library" }

    // MARK: Apps

    /// The apps in the app folders, and in folders one level down (such as `/Applications/Utilities`), by name.
    /// Sizes are not measured yet.
    public func listApps() -> [InstalledApp] {
        var seen = Set<String>()
        var apps: [InstalledApp] = []
        for folder in appFolders {
            for entry in JunkFinder.entries(in: folder) where entry.kind == .directory {
                let path = folder + "/" + entry.name
                if entry.name.hasSuffix(".app") {
                    if seen.insert(path).inserted, let app = Self.readApp(at: path) { apps.append(app) }
                } else {
                    for inner in JunkFinder.entries(in: path) where inner.kind == .directory && inner.name.hasSuffix(".app") {
                        let innerPath = path + "/" + inner.name
                        if seen.insert(innerPath).inserted, let app = Self.readApp(at: innerPath) { apps.append(app) }
                    }
                }
            }
        }
        return apps.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// Reads an app's Info.plist. Returns nil when the folder is not an app bundle.
    public static func readApp(at path: String) -> InstalledApp? {
        let contents = path + "/Contents"
        let plist = readPlist(contents + "/Info.plist")
        guard plist != nil || DirectoryReader.entry(atPath: contents)?.kind == .directory else { return nil }
        let info = plist ?? [:]
        let fileName = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
        let display = (info["CFBundleDisplayName"] as? String) ?? (info["CFBundleName"] as? String)
        let name = (display?.trimmingCharacters(in: .whitespaces).isEmpty == false) ? display! : fileName
        let version = (info["CFBundleShortVersionString"] as? String) ?? (info["CFBundleVersion"] as? String)

        var iconPath: String?
        if var icon = info["CFBundleIconFile"] as? String, !icon.isEmpty {
            if (icon as NSString).pathExtension.isEmpty { icon += ".icns" }
            let candidate = contents + "/Resources/" + icon
            if DirectoryReader.entry(atPath: candidate) != nil { iconPath = candidate }
        }
        let bundleID = (info["CFBundleIdentifier"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        return InstalledApp(path: path, name: name, bundleID: bundleID, version: version, iconPath: iconPath,
                            lastUsed: lastUsedDate(path), embeddedIDs: embeddedIDs(in: contents))
    }

    /// Bundle identifiers of helper apps, login items, extensions and XPC services inside an app.
    static func embeddedIDs(in contents: String) -> [String] {
        let places = ["Library/LoginItems", "Library/LaunchServices", "Helpers", "PlugIns", "XPCServices",
                      "Library/Helpers", "Frameworks"]
        var ids: Set<String> = []
        for place in places {
            let folder = contents + "/" + place
            for entry in JunkFinder.entries(in: folder) where entry.kind == .directory {
                let bundle = folder + "/" + entry.name
                let info = readPlist(bundle + "/Contents/Info.plist") ?? readPlist(bundle + "/Info.plist")
                    ?? readPlist(bundle + "/Resources/Info.plist")
                if let id = info?["CFBundleIdentifier"] as? String, !id.isEmpty { ids.insert(id) }
            }
        }
        return ids.sorted()
    }

    static func readPlist(_ path: String) -> [String: Any]? {
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        return (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any]
    }

    /// When the app was last opened: Spotlight's last-used date, or the bundle's last access date without Spotlight.
    public static func lastUsedDate(_ path: String) -> Date? {
        #if canImport(CoreServices) && os(macOS)
        if let item = MDItemCreateWithURL(kCFAllocatorDefault, URL(fileURLWithPath: path) as CFURL),
           let date = MDItemCopyAttribute(item, kMDItemLastUsedDate) as? Date {
            return date
        }
        #endif
        let values = try? URL(fileURLWithPath: path).resourceValues(forKeys: [.contentAccessDateKey])
        return values?.contentAccessDate
    }

    /// Why an app cannot be uninstalled here, or nil when it can. `running` holds the bundle paths of open apps.
    public func blockReason(for app: InstalledApp, runningPaths: Set<String> = []) -> String? {
        if app.isApple { return "This app comes with macOS." }
        if SafetyPolicy.isSameOrInside(app.path, "/System") { return "This app is part of macOS." }
        if runningPaths.contains(app.path) { return "This app is open. Quit it first." }
        if case .blocked(let reason) = policy.verdict(for: app.path) { return reason }
        return nil
    }

    // MARK: Leftovers

    /// The Library items that belong to `app`. `installed` is every app that is installed, so items that belong to
    /// another app are never offered. Largest first once measured; this does not measure.
    public func leftovers(for app: InstalledApp, installed: [InstalledApp]) -> [Leftover] {
        guard !app.isApple else { return [] }
        let others = installed.filter { $0.path != app.path }
        // Another copy of the same app still uses these files.
        if let id = app.bundleID?.lowercased(), others.contains(where: { $0.bundleID?.lowercased() == id }) { return [] }
        var otherIDs = Set<String>()
        for other in others {
            if let id = other.bundleID { otherIDs.insert(id.lowercased()) }
            otherIDs.formUnion(other.embeddedIDs.map { $0.lowercased() })
        }
        if let own = app.bundleID { otherIDs.remove(own.lowercased()) }
        let otherNames = Set(others.map { $0.name.lowercased() })

        var found: [Leftover] = []
        var claimed = Set<String>()
        func add(_ path: String, _ name: String, _ kind: LeftoverKind, review: Bool = false) {
            guard claimed.insert(path).inserted, !policy.verdict(for: path).isBlocked else { return }
            found.append(Leftover(path: path, name: name, kind: kind, needsReview: review))
        }

        for kind in LeftoverKind.allCases {
            let folder = libraryPath + "/" + kind.folder
            for entry in JunkFinder.entries(in: folder) {
                let ownerByID = app.bundleID.map {
                    Self.owns(id: $0, itemName: entry.name, kind: kind, otherIDs: otherIDs)
                } ?? false
                let ownerByName = Self.matchesName(app.name, itemName: entry.name, kind: kind, otherNames: otherNames)
                if ownerByID || ownerByName {
                    let exact = ownerByName || app.bundleID.map {
                        Self.identifier(fromItemName: entry.name, kind: kind).lowercased() == $0.lowercased()
                    } ?? false
                    add(folder + "/" + entry.name, entry.name, kind, review: !exact)
                }
            }
            if kind == .preferences, let id = app.bundleID {
                let byHost = folder + "/ByHost"
                for entry in JunkFinder.entries(in: byHost) where Self.ownsByHost(id: id, itemName: entry.name) {
                    add(byHost + "/" + entry.name, entry.name, kind)
                }
            }
        }
        return found
    }

    /// The bundle identifier an item in a Library folder is named by, with suffixes such as `.plist` removed.
    /// Group containers drop their `group.` or team ID prefix.
    static func identifier(fromItemName name: String, kind: LeftoverKind) -> String {
        var base = name
        for suffix in [".plist", ".savedState", ".binarycookies"] where base.hasSuffix(suffix) {
            base = String(base.dropLast(suffix.count))
        }
        if kind == .groupContainers {
            if base.hasPrefix("group.") {
                base = String(base.dropFirst("group.".count))
            } else if let dot = base.firstIndex(of: "."), isTeamID(String(base[..<dot])) {
                base = String(base[base.index(after: dot)...])
            }
        }
        return base
    }

    /// Ten upper-case letters and digits, like `UBF8T346G9`.
    static func isTeamID(_ text: String) -> Bool {
        text.count == 10 && text.allSatisfy { ($0.isUppercase && $0.isASCII && $0.isLetter) || ($0.isASCII && $0.isNumber) }
    }

    /// True when an item is named by `id`, or by a dotted child of `id` (`com.maker.app.helper`) that no other
    /// installed app owns more closely. Comparison ignores case, as the Mac's disk does.
    static func owns(id: String, itemName: String, kind: LeftoverKind, otherIDs: Set<String>) -> Bool {
        let wanted = id.lowercased()
        let item = identifier(fromItemName: itemName, kind: kind).lowercased()
        if kind == .groupContainers {
            // Group containers are often shared by several apps of one maker, so only an exact name counts.
            return item == wanted
        }
        if item == wanted { return true }
        guard item.hasPrefix(wanted + ".") else { return false }
        return !otherIDs.contains { other in
            other.count > wanted.count && (item == other || item.hasPrefix(other + "."))
        }
    }

    /// `ByHost/com.maker.app.0123ABCD-....plist` belongs to `com.maker.app`.
    static func ownsByHost(id: String, itemName: String) -> Bool {
        let lower = itemName.lowercased()
        let prefix = id.lowercased() + "."
        guard lower.hasPrefix(prefix), lower.hasSuffix(".plist") else { return false }
        let host = lower.dropFirst(prefix.count).dropLast(".plist".count)
        return !host.isEmpty && host.allSatisfy { $0.isHexDigit || $0 == "-" }
    }

    /// True when a folder in Application Support, Caches or Logs is named exactly like the app, and the name is not
    /// one shared by many apps or used by another installed app.
    static func matchesName(_ appName: String, itemName: String, kind: LeftoverKind, otherNames: Set<String>) -> Bool {
        guard [.applicationSupport, .caches, .logs].contains(kind) else { return false }
        let name = appName.trimmingCharacters(in: .whitespaces).lowercased()
        guard name.count >= 3, !sharedNames.contains(name), !otherNames.contains(name) else { return false }
        return itemName.lowercased() == name
    }

    // MARK: Leftovers of removed apps

    /// Library items named like a bundle identifier (`com.maker.app`) that no installed or running app owns.
    /// `knownIDs` adds identifiers to treat as installed, such as those of running apps. These are guesses, so the app
    /// offers them for review only.
    public func orphans(installed: [InstalledApp], knownIDs: Set<String> = []) -> [OrphanGroup] {
        var ids = Set(knownIDs.map { $0.lowercased() })
        for app in installed {
            if let id = app.bundleID { ids.insert(id.lowercased()) }
            ids.formUnion(app.embeddedIDs.map { $0.lowercased() })
        }
        var groups: [String: [Leftover]] = [:]
        var display: [String: String] = [:]
        let kinds: [LeftoverKind] = [.applicationSupport, .caches, .preferences, .savedState, .containers,
                                     .httpStorages, .webKit, .logs, .launchAgents, .cookies, .applicationScripts]
        for kind in kinds {
            let folder = libraryPath + "/" + kind.folder
            for entry in JunkFinder.entries(in: folder) {
                let id = Self.identifier(fromItemName: entry.name, kind: kind)
                guard Self.looksLikeBundleID(id) else { continue }
                let lower = id.lowercased()
                if lower.hasPrefix("com.apple.") || Self.isOwned(lower, by: ids) { continue }
                let path = folder + "/" + entry.name
                guard !policy.verdict(for: path).isBlocked else { continue }
                groups[lower, default: []].append(Leftover(path: path, name: entry.name, kind: kind))
                if display[lower] == nil { display[lower] = id }
            }
        }
        return groups.keys.sorted().map { OrphanGroup(bundleID: display[$0] ?? $0, items: groups[$0] ?? []) }
    }

    /// `com.maker.app`: three or more dot-separated parts of letters, digits, `-` and `_`, starting with a letter.
    static func looksLikeBundleID(_ text: String) -> Bool {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count >= 3, let first = parts.first?.first, first.isLetter, first.isASCII else { return false }
        return parts.allSatisfy { part in
            !part.isEmpty && part.allSatisfy { ($0.isASCII && ($0.isLetter || $0.isNumber)) || $0 == "-" || $0 == "_" }
        }
    }

    /// True when `id` is one of `ids` or a dotted child of one.
    static func isOwned(_ id: String, by ids: Set<String>) -> Bool {
        if ids.contains(id) { return true }
        var parts = id.split(separator: ".")
        while parts.count > 2 {
            parts.removeLast()
            if ids.contains(parts.joined(separator: ".")) { return true }
        }
        return false
    }

    /// Measures each leftover, largest first.
    public static func measure(_ items: [Leftover]) async -> [Leftover] {
        await withTaskGroup(of: Leftover.self) { group in
            for item in items {
                group.addTask {
                    var measured = item
                    measured.bytes = DiskUsage.allocatedSize(atPath: item.path)
                    return measured
                }
            }
            var out: [Leftover] = []
            for await item in group { out.append(item) }
            return out.sorted { $0.bytes != $1.bytes ? $0.bytes > $1.bytes : $0.path < $1.path }
        }
    }
}
