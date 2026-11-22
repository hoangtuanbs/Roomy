import Foundation

/// The kinds of junk Smart Clean looks for.
public enum JunkCategory: String, CaseIterable, Sendable {
    case caches, logs, developer, packages, installers, trash
}

/// One file or folder that Smart Clean can remove.
public struct JunkItem: Sendable, Hashable, Identifiable {
    public var id: String { path }
    public let path: String
    public let name: String
    public let bytes: Int64

    public init(path: String, name: String, bytes: Int64) {
        self.path = path
        self.name = name
        self.bytes = bytes
    }
}

/// A group of junk of one kind, such as Xcode build data, with a plain explanation of what removing it does.
public struct JunkFinding: Sendable, Identifiable, Equatable {
    public let id: String
    public let category: JunkCategory
    public let title: String
    public let explanation: String
    /// Largest first.
    public let items: [JunkItem]
    /// Ticked when the results first appear. Findings that need a look first start unticked.
    public let preselected: Bool
    /// Removing this cannot be undone. Only the Trash itself is like this, and it is never part of a normal clean.
    public let isPermanent: Bool

    public init(id: String, category: JunkCategory, title: String, explanation: String,
                items: [JunkItem], preselected: Bool, isPermanent: Bool = false) {
        self.id = id
        self.category = category
        self.title = title
        self.explanation = explanation
        self.items = items
        self.preselected = preselected
        self.isPermanent = isPermanent
    }

    public var bytes: Int64 { items.reduce(0) { $0 + $1.bytes } }
    public var paths: [String] { items.map(\.path) }

    /// The same finding without the given paths, or nil when nothing is left.
    public func removing(_ removed: Set<String>) -> JunkFinding? {
        let left = items.filter { !removed.contains($0.path) }
        guard !left.isEmpty else { return nil }
        return JunkFinding(id: id, category: category, title: title, explanation: explanation,
                           items: left, preselected: preselected, isPermanent: isPermanent)
    }
}

/// Finds and measures junk in known places under the home folder that is safe to move to the Trash.
/// It only looks; removing goes through `CleanupService`.
public struct JunkFinder: Sendable {
    public let homePath: String
    public let policy: SafetyPolicy
    public var now: Date
    /// Cache folder names to leave alone, such as the bundle identifiers of running apps.
    public var skippedCacheNames: Set<String>
    public var nodeModulesAge: TimeInterval = 30 * 86_400
    public var installerAge: TimeInterval = 30 * 86_400
    public var simulatorAge: TimeInterval = 180 * 86_400

    /// Caches that belong to package managers. They are listed with the package caches instead of app caches.
    static let packageCacheNames: Set<String> = ["Homebrew", "pip", "Yarn", "CocoaPods", "pnpm"]

    static let packageCaches: [(path: String, name: String)] = [
        (".npm/_cacache", "npm"),
        ("Library/Caches/Yarn", "Yarn"),
        ("Library/pnpm/store", "pnpm store"),
        ("Library/Caches/pip", "pip"),
        ("Library/Caches/Homebrew", "Homebrew"),
        ("Library/Caches/CocoaPods", "CocoaPods"),
        (".gradle/caches", "Gradle"),
        (".cargo/registry/cache", "Cargo"),
    ]

    static let installerExtensions: Set<String> = ["dmg", "pkg", "mpkg"]

    public init(homePath: String = NSHomeDirectory(), now: Date = Date(), skippedCacheNames: Set<String> = []) {
        self.homePath = DiskScanner.standardize(homePath)
        self.policy = SafetyPolicy(homePath: homePath)
        self.now = now
        self.skippedCacheNames = skippedCacheNames
    }

    public var trashPath: String { homePath + "/.Trash" }

    /// Looks in every known place and measures what it finds. `tree`, when given, is searched for old
    /// `node_modules` folders. `progress` gets the title of each group as it is measured.
    public func find(tree: ScanTree? = nil, progress: (@Sendable (String) -> Void)? = nil) async -> [JunkFinding] {
        var groups = candidateGroups(tree: tree)

        // Each path is offered once, and never anything that the safety rules block.
        var claimed: [String] = [trashPath]
        for g in groups.indices where !groups[g].isPermanent {
            var kept: [Candidate] = []
            for candidate in groups[g].candidates {
                if policy.verdict(for: candidate.path).isBlocked { continue }
                let overlaps = claimed.contains {
                    SafetyPolicy.isSameOrInside(candidate.path, $0) || SafetyPolicy.isSameOrInside($0, candidate.path)
                }
                if overlaps { continue }
                claimed.append(candidate.path)
                kept.append(candidate)
            }
            groups[g].candidates = kept
        }

        var findings: [JunkFinding] = []
        for group in groups where !group.candidates.isEmpty {
            if Task.isCancelled { break }
            progress?(group.title)
            let items = await Self.measure(group.candidates)
                .filter { $0.bytes > 0 }
                .sorted { $0.bytes != $1.bytes ? $0.bytes > $1.bytes : $0.name < $1.name }
            guard !items.isEmpty else { continue }
            findings.append(JunkFinding(id: group.id, category: group.category, title: group.title,
                                        explanation: group.explanation, items: items,
                                        preselected: group.preselected, isPermanent: group.isPermanent))
        }
        return findings
    }

    struct Candidate: Sendable {
        let path: String
        let name: String
        var knownBytes: Int64? = nil
    }

    struct CandidateGroup: Sendable {
        let id: String
        let category: JunkCategory
        let title: String
        let explanation: String
        let preselected: Bool
        var isPermanent = false
        var candidates: [Candidate]
    }

    func candidateGroups(tree: ScanTree?) -> [CandidateGroup] {
        let library = homePath + "/Library"
        let caches = library + "/Caches"
        let xcode = library + "/Developer/Xcode"
        let simulator = library + "/Developer/CoreSimulator"
        var groups: [CandidateGroup] = []

        let appCaches = Self.entries(in: caches).filter { entry in
            !entry.name.hasPrefix("com.apple.")
                && !Self.packageCacheNames.contains(entry.name)
                && !skippedCacheNames.contains(entry.name)
        }
        groups.append(CandidateGroup(
            id: "caches", category: .caches, title: String(localized: "App caches"),
            explanation: String(localized: "Files apps keep so they load faster. Apps make them again when needed, so they can be a little slower the first time. Caches of macOS and of apps that are open now are left alone."),
            preselected: true,
            candidates: appCaches.map { Candidate(path: caches + "/" + $0.name, name: $0.name) }
        ))

        let logs = library + "/Logs"
        groups.append(CandidateGroup(
            id: "logs", category: .logs, title: String(localized: "Logs"),
            explanation: String(localized: "Records apps write about what they did, mostly for troubleshooting. Removing them does not change how apps work."),
            preselected: true,
            candidates: Self.entries(in: logs).map { Candidate(path: logs + "/" + $0.name, name: $0.name) }
        ))

        let derived = xcode + "/DerivedData"
        groups.append(CandidateGroup(
            id: "derivedData", category: .developer, title: String(localized: "Xcode build data"),
            explanation: String(localized: "Build products and indexes Xcode makes for your projects (DerivedData). Xcode makes them again on the next build, which takes longer once."),
            preselected: true,
            candidates: Self.entries(in: derived).map {
                Candidate(path: derived + "/" + $0.name, name: Self.projectName(fromDerivedData: $0.name))
            }
        ))

        let archives = xcode + "/Archives"
        var archiveItems: [Candidate] = []
        for day in Self.entries(in: archives) where day.kind == .directory {
            let dayPath = archives + "/" + day.name
            for archive in Self.entries(in: dayPath) {
                archiveItems.append(Candidate(path: dayPath + "/" + archive.name, name: archive.name))
            }
        }
        groups.append(CandidateGroup(
            id: "archives", category: .developer, title: String(localized: "Xcode archives"),
            explanation: String(localized: "Copies of apps you archived in Xcode for release. You need an archive to upload that build again or to read its crash reports, so check before removing."),
            preselected: false, candidates: archiveItems
        ))

        let simCaches = simulator + "/Caches"
        groups.append(CandidateGroup(
            id: "simulatorCaches", category: .developer, title: String(localized: "Simulator caches"),
            explanation: String(localized: "Files the iOS Simulator keeps so it starts faster. It makes them again when needed."),
            preselected: true,
            candidates: Self.entries(in: simCaches).map { Candidate(path: simCaches + "/" + $0.name, name: $0.name) }
        ))

        groups.append(CandidateGroup(
            id: "oldSimulators", category: .developer, title: String(localized: "Unused simulators"),
            explanation: String(localized: "Simulated devices you have not used for 6 months, with the apps and data in them. If Xcode still lists one afterwards, delete it in Devices and Simulators."),
            preselected: false, candidates: oldSimulators(in: simulator + "/Devices")
        ))

        var supportItems: [Candidate] = []
        for platform in ["iOS", "watchOS", "tvOS", "visionOS"] {
            let folder = xcode + "/\(platform) DeviceSupport"
            for entry in Self.entries(in: folder) where entry.kind == .directory {
                supportItems.append(Candidate(path: folder + "/" + entry.name, name: "\(platform) \(entry.name)"))
            }
        }
        groups.append(CandidateGroup(
            id: "deviceSupport", category: .developer, title: String(localized: "Device support files"),
            explanation: String(localized: "Debug files Xcode copies from each iPhone, iPad or Apple Watch you connect. Xcode copies them again the next time you connect that device, which takes a few minutes."),
            preselected: true, candidates: supportItems
        ))

        var packageItems: [Candidate] = []
        for cache in Self.packageCaches {
            let path = homePath + "/" + cache.path
            if DirectoryReader.entry(atPath: path)?.kind == .directory {
                packageItems.append(Candidate(path: path, name: cache.name))
            }
        }
        groups.append(CandidateGroup(
            id: "packageCaches", category: .packages, title: String(localized: "Package manager caches"),
            explanation: String(localized: "Downloads that npm, Yarn, pnpm, pip, Homebrew, CocoaPods, Gradle and Cargo keep so they can install packages again without downloading them. They download what they need on the next install."),
            preselected: true, candidates: packageItems
        ))

        if let tree {
            groups.append(CandidateGroup(
                id: "nodeModules", category: .packages, title: String(localized: "Old node_modules folders"),
                explanation: String(localized: "Packages installed for JavaScript projects you have not touched in 30 days. Run npm install (or yarn, pnpm) in the project to get them back."),
                preselected: false, candidates: oldNodeModules(in: tree)
            ))
        }

        let downloads = homePath + "/Downloads"
        let installerCutoff = now.addingTimeInterval(-installerAge)
        let installers = Self.entries(in: downloads).filter { entry in
            let ext = (entry.name as NSString).pathExtension.lowercased()
            return Self.installerExtensions.contains(ext) && Self.date(entry.modified) < installerCutoff
        }
        groups.append(CandidateGroup(
            id: "installers", category: .installers, title: String(localized: "Old installers"),
            explanation: String(localized: "Disk images and installer packages in Downloads that are more than 30 days old. Once an app is installed, you rarely need its installer again."),
            preselected: true,
            candidates: installers.map { Candidate(path: downloads + "/" + $0.name, name: $0.name) }
        ))

        let trashItems: [Candidate]
        if DirectoryReader.entry(atPath: trashPath)?.kind == .directory {
            trashItems = Self.entries(in: trashPath, includeLinks: true).map {
                Candidate(path: trashPath + "/" + $0.name, name: $0.name)
            }
        } else {
            trashItems = []
        }
        groups.append(CandidateGroup(
            id: "trash", category: .trash, title: String(localized: "Trash"),
            explanation: String(localized: "Items you already moved to the Trash. Emptying it erases them for good: you cannot put them back."),
            preselected: false, isPermanent: true, candidates: trashItems
        ))
        return groups
    }

    func oldSimulators(in devices: String) -> [Candidate] {
        let cutoff = now.addingTimeInterval(-simulatorAge)
        var out: [Candidate] = []
        for entry in Self.entries(in: devices) where entry.kind == .directory {
            let dir = devices + "/" + entry.name
            guard let plist = DirectoryReader.entry(atPath: dir + "/device.plist") else { continue }
            let data = DirectoryReader.entry(atPath: dir + "/data")
            let touched = max(entry.modified, plist.modified, data?.modified ?? 0)
            guard Self.date(touched) < cutoff else { continue }
            out.append(Candidate(path: dir, name: Self.simulatorName(plistPath: dir + "/device.plist") ?? entry.name))
        }
        return out
    }

    func oldNodeModules(in tree: ScanTree) -> [Candidate] {
        let cutoff = now.addingTimeInterval(-nodeModulesAge)
        var out: [Candidate] = []
        var stack: [ScanTree.Index] = [ScanTree.root]
        while let node = stack.popLast() {
            for child in tree.children(node) where tree.kind(child) == .directory {
                if tree.flags(child).contains(.removed) { continue }
                guard tree.name(child) == "node_modules" else {
                    stack.append(child)
                    continue
                }
                // A folder counts as touched when it or anything directly inside it changed.
                let touched = ([child] + tree.children(child)).map { tree.modifiedDate($0) }.max() ?? .distantPast
                guard touched < cutoff, tree.size(child) > 0 else { continue }
                let path = tree.path(of: child)
                let project = ((path as NSString).deletingLastPathComponent as NSString).lastPathComponent
                out.append(Candidate(path: path, name: project, knownBytes: tree.size(child)))
            }
        }
        return out
    }

    static func measure(_ candidates: [Candidate]) async -> [JunkItem] {
        await withTaskGroup(of: JunkItem.self) { group in
            for candidate in candidates {
                group.addTask {
                    JunkItem(path: candidate.path, name: candidate.name,
                             bytes: candidate.knownBytes ?? DiskUsage.allocatedSize(atPath: candidate.path))
                }
            }
            var out: [JunkItem] = []
            for await item in group { out.append(item) }
            return out
        }
    }

    /// Files and folders in a folder, without hidden ones. Symbolic links are left out unless asked for.
    static func entries(in folder: String, includeLinks: Bool = false) -> [RawEntry] {
        (DirectoryReader.list(path: folder) ?? []).filter { entry in
            guard entry.name != ".DS_Store", entry.name != ".localized" else { return false }
            if includeLinks { return true }
            return !entry.name.hasPrefix(".") && (entry.kind == .file || entry.kind == .directory)
        }
        .sorted { $0.name < $1.name }
    }

    static func date(_ seconds: Int64) -> Date {
        Date(timeIntervalSince1970: TimeInterval(seconds))
    }

    /// `MyApp-abcdefghijklmnopqrstuvwxyz` becomes `MyApp`.
    static func projectName(fromDerivedData name: String) -> String {
        guard let dash = name.lastIndex(of: "-"), name.distance(from: dash, to: name.endIndex) > 20 else { return name }
        return String(name[..<dash])
    }

    /// `iPhone 15 (iOS 17.0)` from a simulator's device.plist.
    static func simulatorName(plistPath: String) -> String? {
        guard let data = FileManager.default.contents(atPath: plistPath),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else { return nil }
        let name = plist["name"] as? String ?? "Simulator"
        guard let runtime = plist["runtime"] as? String, let version = runtimeName(runtime) else { return name }
        return "\(name) (\(version))"
    }

    /// `com.apple.CoreSimulator.SimRuntime.iOS-17-0` becomes `iOS 17.0`.
    static func runtimeName(_ identifier: String) -> String? {
        guard let last = identifier.split(separator: ".").last else { return nil }
        let parts = last.split(separator: "-")
        guard parts.count >= 2 else { return String(last) }
        return "\(parts[0]) \(parts.dropFirst().joined(separator: "."))"
    }
}

/// Which junk items are ticked. Items of a permanent finding (the Trash) can never be ticked.
public struct JunkSelection: Sendable, Equatable {
    public enum State: Sendable, Equatable {
        case none, some, all
    }

    public private(set) var paths: Set<String> = []

    public init() {}

    /// Ticks everything in the preselected findings.
    public init(findings: [JunkFinding]) {
        for finding in findings where finding.preselected && !finding.isPermanent {
            paths.formUnion(finding.paths)
        }
    }

    public func contains(_ item: JunkItem) -> Bool { paths.contains(item.path) }

    public mutating func toggle(_ item: JunkItem, in finding: JunkFinding) {
        guard !finding.isPermanent, finding.items.contains(item) else { return }
        if paths.contains(item.path) { paths.remove(item.path) } else { paths.insert(item.path) }
    }

    public mutating func setAll(_ finding: JunkFinding, selected: Bool) {
        guard !finding.isPermanent else { return }
        if selected { paths.formUnion(finding.paths) } else { paths.subtract(finding.paths) }
    }

    public mutating func remove(_ removed: Set<String>) {
        paths.subtract(removed)
    }

    public func state(of finding: JunkFinding) -> State {
        let ticked = finding.items.filter { paths.contains($0.path) }.count
        if ticked == 0 { return .none }
        return ticked == finding.items.count ? .all : .some
    }

    /// What a clean would move to the Trash. Never includes the Trash's own items.
    public func selectedItems(in findings: [JunkFinding]) -> [JunkItem] {
        findings.filter { !$0.isPermanent }.flatMap { finding in
            finding.items.filter { paths.contains($0.path) }
        }
    }

    public func selectedBytes(in findings: [JunkFinding]) -> Int64 {
        selectedItems(in: findings).reduce(0) { $0 + $1.bytes }
    }

    public func selectedBytes(in finding: JunkFinding) -> Int64 {
        selectedBytes(in: [finding])
    }
}

public enum DiskUsage {
    /// Space a file or folder takes on disk, counting hard links once. Never follows symbolic links.
    public static func allocatedSize(atPath path: String) -> Int64 {
        guard let root = DirectoryReader.entry(atPath: path) else { return 0 }
        var total = root.allocated
        guard root.kind == .directory else { return total }
        var seen = Set<FileID>()
        var stack = [path]
        while let dir = stack.popLast() {
            if Task.isCancelled { break }
            guard let entries = DirectoryReader.list(path: dir) else { continue }
            for entry in entries {
                if entry.kind != .directory && entry.linkCount > 1 {
                    if !seen.insert(FileID(device: entry.device, inode: entry.inode)).inserted { continue }
                }
                total += entry.allocated
                if entry.kind == .directory { stack.append(DiskScanner.join(dir, entry.name)) }
            }
        }
        return total
    }

    private struct FileID: Hashable {
        let device: UInt64
        let inode: UInt64
    }
}
