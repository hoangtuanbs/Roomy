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
    /// `CFBundleVersion`, which Sparkle compares with an update feed.
    public let buildVersion: String?
    /// The Sparkle update feed (`SUFeedURL`), when the app has one.
    public let feedURL: String?
    /// Installed from the Mac App Store (it has `Contents/_MASReceipt`).
    public let isFromAppStore: Bool

    public init(path: String, name: String, bundleID: String?, version: String?, iconPath: String?,
                bytes: Int64 = 0, lastUsed: Date? = nil, embeddedIDs: [String] = [], buildVersion: String? = nil,
                feedURL: String? = nil, isFromAppStore: Bool = false) {
        self.path = path
        self.name = name
        self.bundleID = bundleID
        self.version = version
        self.iconPath = iconPath
        self.bytes = bytes
        self.lastUsed = lastUsed
        self.embeddedIDs = embeddedIDs
        self.buildVersion = buildVersion
        self.feedURL = feedURL
        self.isFromAppStore = isFromAppStore
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
        case .applicationSupport: return String(localized: "App data")
        case .caches: return String(localized: "Caches")
        case .preferences: return String(localized: "Settings")
        case .savedState: return String(localized: "Saved window state")
        case .containers: return String(localized: "Sandbox container")
        case .groupContainers: return String(localized: "Shared container")
        case .applicationScripts: return String(localized: "Scripts")
        case .httpStorages: return String(localized: "Web storage")
        case .webKit: return String(localized: "WebKit data")
        case .logs: return "Logs"
        case .launchAgents: return String(localized: "Launch agents")
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
    /// For leftovers of removed apps: how sure RoomyDisk is that the item belonged to an app that is gone.
    public let confidence: OrphanConfidence?

    public init(path: String, name: String, kind: LeftoverKind, bytes: Int64 = 0, needsReview: Bool = false,
                confidence: OrphanConfidence? = nil) {
        self.path = path
        self.name = name
        self.kind = kind
        self.bytes = bytes
        self.needsReview = needsReview
        self.confidence = confidence
    }
}

/// How sure RoomyDisk is that a Library item belonged to an app that was removed.
public enum OrphanConfidence: Int, Sendable, Hashable, Comparable, CaseIterable {
    /// Named by some bundle identifier that no installed app owns, with nothing to say it was an app.
    case low
    /// Named like a removed app (its name, or a related identifier), or a shared container of one.
    case medium
    /// Named exactly by the bundle identifier of an app that is known to be gone.
    case high

    public static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }

    public var title: String {
        switch self {
        case .high: return String(localized: "Sure")
        case .medium: return String(localized: "Likely")
        case .low: return String(localized: "Unsure")
        }
    }

    public var explanation: String {
        switch self {
        case .high: return String(localized: "Named exactly by an app that was removed.")
        case .medium: return String(localized: "Named like an app that was removed. It may be shared with another app.")
        case .low: return String(localized: "Named like an app that is not installed. It may belong to a tool or helper kept elsewhere.")
        }
    }
}

/// An app known to be gone: one in the Trash, one that left saved windows, or one whose installer receipt
/// remains. Its identifier and name tell its leftovers.
public struct RemovedApp: Sendable, Hashable {
    public let bundleID: String
    public let name: String?

    public init(bundleID: String, name: String?) {
        self.bundleID = bundleID
        self.name = name
    }
}

/// Library items of one app that is no longer installed.
public struct OrphanGroup: Sendable, Hashable, Identifiable {
    public var id: String { bundleID }
    public let bundleID: String
    /// The app's name, when it is known (from the Trash or an installer receipt).
    public let appName: String?
    public let items: [Leftover]

    public init(bundleID: String, appName: String? = nil, items: [Leftover]) {
        self.bundleID = bundleID
        self.appName = appName
        self.items = items
    }

    public var bytes: Int64 { items.reduce(0) { $0 + $1.bytes } }
    public var title: String { appName ?? bundleID }
    /// The most certain of its items.
    public var confidence: OrphanConfidence { items.compactMap(\.confidence).max() ?? .low }
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

    /// More places whose apps count as installed, but are not listed: the apps of macOS.
    public let ownerFolders: [String]

    public init(homePath: String = NSHomeDirectory(), appFolders: [String]? = nil, ownerFolders: [String]? = nil) {
        let home = DiskScanner.standardize(homePath)
        self.homePath = home
        self.appFolders = appFolders ?? ["/Applications", home + "/Applications"]
        self.ownerFolders = ownerFolders ?? (appFolders == nil ? ["/System/Applications"] : [])
        self.policy = SafetyPolicy(homePath: home)
    }

    public var libraryPath: String { homePath + "/Library" }

    // MARK: Apps

    /// The apps in the app folders, and in folders one level down (such as `/Applications/Utilities`), by name.
    /// Sizes are not measured yet.
    public func listApps() -> [InstalledApp] {
        listApps(in: appFolders)
    }

    /// The apps of `ownerFolders`, such as macOS's own in /System/Applications. They are never offered, but their
    /// files are theirs.
    public func listOwnerApps() -> [InstalledApp] {
        listApps(in: ownerFolders)
    }

    func listApps(in folders: [String]) -> [InstalledApp] {
        var seen = Set<String>()
        var apps: [InstalledApp] = []
        for folder in folders {
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

    /// The first app bundle among paths handed over by Finder (the "Uninstall with RoomyDisk" service), or nil.
    public static func appBundle(among paths: [String]) -> String? {
        paths.map(DiskScanner.standardize).first { path in
            path.lowercased().hasSuffix(".app") && DirectoryReader.entry(atPath: path)?.kind == .directory
                && DirectoryReader.entry(atPath: path + "/Contents")?.kind == .directory
        }
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
        let feed = (info["SUFeedURL"] as? String).flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 }
        let fromStore = DirectoryReader.entry(atPath: contents + "/_MASReceipt/receipt") != nil
        return InstalledApp(path: path, name: name, bundleID: bundleID, version: version, iconPath: iconPath,
                            lastUsed: lastUsedDate(path), embeddedIDs: embeddedIDs(in: contents),
                            buildVersion: info["CFBundleVersion"] as? String, feedURL: feed, isFromAppStore: fromStore)
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
        if app.isApple { return String(localized: "This app comes with macOS.") }
        if SafetyPolicy.isSameOrInside(app.path, "/System") { return String(localized: "This app is part of macOS.") }
        if runningPaths.contains(app.path) { return String(localized: "This app is open. Quit it first.") }
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

    /// Apps known to be gone: apps in the Trash (with their names), and apps that left saved windows in
    /// `Saved Application State` (only apps have windows). Those still installed are left out by `orphans`.
    public func removedApps() -> [RemovedApp] {
        var found: [String: RemovedApp] = [:]
        let trash = homePath + "/.Trash"
        for app in listApps(in: [trash]) {
            if let id = app.bundleID { found[id.lowercased()] = RemovedApp(bundleID: id, name: app.name) }
        }
        let saved = libraryPath + "/" + LeftoverKind.savedState.folder
        for entry in JunkFinder.entries(in: saved) where entry.name.hasSuffix(".savedState") {
            let id = Self.identifier(fromItemName: entry.name, kind: .savedState)
            if Self.looksLikeBundleID(id), found[id.lowercased()] == nil { found[id.lowercased()] = RemovedApp(bundleID: id, name: nil) }
        }
        return found.values.sorted { $0.bundleID < $1.bundleID }
    }

    /// Library items that look like they belong to apps that are no longer installed, each with a confidence:
    /// high when named exactly by the identifier of a removed app (`removed`, which `removedApps()` makes), medium
    /// when named like one (its name, a related identifier, or a shared container), low for any other identifier no
    /// installed app owns. `knownIDs` are treated as installed (running apps), and `isRegistered` asks Launch
    /// Services whether an app with that identifier is still somewhere on the Mac. Items of macOS, shared names,
    /// launch agents whose program is still there and anything the safety rules block are left out.
    public func orphans(installed: [InstalledApp], knownIDs: Set<String> = [], removed: [RemovedApp]? = nil,
                        isRegistered: @Sendable (String) -> Bool = { _ in false }) -> [OrphanGroup] {
        var ids = Set(knownIDs.map { $0.lowercased() })
        var installedNames = Set<String>()
        for app in installed {
            if let id = app.bundleID { ids.insert(id.lowercased()) }
            ids.formUnion(app.embeddedIDs.map { $0.lowercased() })
            installedNames.insert(app.name.lowercased())
        }
        var registered: [String: Bool] = [:]
        func isInstalled(_ lower: String, _ id: String) -> Bool {
            if Self.isOwned(lower, by: ids) { return true }
            if let known = registered[lower] { return known }
            let answer = isRegistered(id)
            registered[lower] = answer
            return answer
        }

        var gone: [String: RemovedApp] = [:]
        for app in removed ?? removedApps() {
            let lower = app.bundleID.lowercased()
            if !Self.isSystemID(lower) && !isInstalled(lower, app.bundleID) { gone[lower] = app }
        }
        var goneByName: [String: RemovedApp] = [:]
        for app in gone.values {
            guard let name = app.name?.trimmingCharacters(in: .whitespaces).lowercased(), name.count >= 3,
                  !Self.sharedNames.contains(name), !installedNames.contains(name) else { continue }
            goneByName[name] = app
        }

        var groups: [String: [Leftover]] = [:]
        var display: [String: String] = [:]
        func add(_ key: String, _ shown: String, _ item: Leftover) {
            groups[key, default: []].append(item)
            if display[key] == nil { display[key] = shown }
        }

        for kind in LeftoverKind.allCases {
            let folder = libraryPath + "/" + kind.folder
            for entry in JunkFinder.entries(in: folder) {
                let path = folder + "/" + entry.name
                let id = Self.identifier(fromItemName: entry.name, kind: kind)
                let lower = id.lowercased()

                if !Self.looksLikeBundleID(id) {
                    // A plain name counts only when it is exactly the name of an app that is gone.
                    guard [.applicationSupport, .caches, .logs].contains(kind),
                          let app = goneByName[entry.name.lowercased()],
                          !policy.verdict(for: path).isBlocked else { continue }
                    add(app.bundleID.lowercased(), app.bundleID,
                        Leftover(path: path, name: entry.name, kind: kind, confidence: .medium))
                    continue
                }
                if Self.isSystemID(lower) || isInstalled(lower, id) { continue }
                guard !policy.verdict(for: path).isBlocked else { continue }
                if kind == .launchAgents, Self.agentProgramExists(path) { continue }

                let confidence: OrphanConfidence
                var key = lower
                var shown = id
                if gone[lower] != nil {
                    // A container shared by a maker's apps may still be used by another of them.
                    confidence = kind == .groupContainers ? .medium : .high
                } else if let parent = Self.parentID(lower, in: gone) {
                    confidence = .medium
                    key = parent
                    shown = gone[parent]?.bundleID ?? parent
                } else if kind == .groupContainers {
                    continue // Shared containers are only offered for an app that is known to be gone.
                } else {
                    confidence = .low
                }
                add(key, shown, Leftover(path: path, name: entry.name, kind: kind, confidence: confidence))
            }
        }
        return groups.keys.map { key in
            OrphanGroup(bundleID: display[key] ?? key, appName: gone[key]?.name, items: groups[key] ?? [])
        }
        .sorted { a, b in
            a.confidence != b.confidence ? a.confidence > b.confidence : a.bundleID.lowercased() < b.bundleID.lowercased()
        }
    }

    /// Items of macOS and Apple's own groups.
    static func isSystemID(_ lower: String) -> Bool {
        lower.hasPrefix("com.apple.") || lower.hasPrefix("group.com.apple.") || lower.hasPrefix("systemgroup.")
            || lower.hasPrefix("apple.")
    }

    /// The removed app whose identifier `id` is a dotted child of, such as `com.maker.app` for `com.maker.app.helper`.
    static func parentID(_ id: String, in gone: [String: RemovedApp]) -> String? {
        var parts = id.split(separator: ".")
        while parts.count > 2 {
            parts.removeLast()
            let parent = parts.joined(separator: ".")
            if gone[parent] != nil { return parent }
        }
        return nil
    }

    /// True when a launch agent's program is still on the Mac, so the agent is in use even if no app is listed.
    static func agentProgramExists(_ plistPath: String) -> Bool {
        guard let program = LaunchItemReader.program(of: readPlist(plistPath) ?? [:]) else { return false }
        return DirectoryReader.entry(atPath: program) != nil
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
