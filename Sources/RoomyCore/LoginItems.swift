import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// Reads launchd property lists (launch agents and daemons).
public enum LaunchItemReader {
    /// The program a launchd plist runs: `Program`, or the first of `ProgramArguments`.
    public static func program(of plist: [String: Any]) -> String? {
        if let program = plist["Program"] as? String, !program.isEmpty { return program }
        if let arguments = plist["ProgramArguments"] as? [String], let first = arguments.first, !first.isEmpty { return first }
        return nil
    }
}

/// Something that starts with the Mac: a launch agent or daemon, or a helper an app registers itself.
public struct LaunchItem: Sendable, Hashable, Identifiable {
    public enum Domain: String, Sendable, CaseIterable {
        /// `~/Library/LaunchAgents`: starts when you log in, for you only. RoomyDisk can turn these off.
        case userAgent
        /// `/Library/LaunchAgents`: starts when anyone logs in. Needs an administrator to change.
        case systemAgent
        /// `/Library/LaunchDaemons`: starts with the Mac, before anyone logs in. Needs an administrator to change.
        case systemDaemon
        /// A helper inside an app that the app turns on itself (`SMAppService`). Managed in System Settings.
        case appManaged

        public var title: String {
            switch self {
            case .userAgent: return String(localized: "Starts when you log in")
            case .systemAgent: return String(localized: "Starts when anyone logs in")
            case .systemDaemon: return String(localized: "Starts with the Mac")
            case .appManaged: return String(localized: "Managed by its app")
            }
        }
    }

    public var id: String { plistPath ?? "app:" + label }
    public let label: String
    /// The launchd plist, or nil for a login item app inside an app.
    public let plistPath: String?
    public let domain: Domain
    public let program: String?
    /// The installed app it belongs to, when one is found.
    public let ownerName: String?
    public let ownerPath: String?
    /// True when the program it starts is on the Mac.
    public let programExists: Bool
    /// `RunAtLoad` or `KeepAlive`: it starts by itself, not only when asked.
    public let startsByItself: Bool
    /// Whether launchd has it loaded now; nil when that cannot be read without an administrator.
    public var isLoaded: Bool?

    public init(label: String, plistPath: String?, domain: Domain, program: String?, ownerName: String? = nil,
                ownerPath: String? = nil, programExists: Bool = true, startsByItself: Bool = true, isLoaded: Bool? = nil) {
        self.label = label
        self.plistPath = plistPath
        self.domain = domain
        self.program = program
        self.ownerName = ownerName
        self.ownerPath = ownerPath
        self.programExists = programExists
        self.startsByItself = startsByItself
        self.isLoaded = isLoaded
    }

    /// The name to show: the owning app's, or the label.
    public var title: String { ownerName ?? label }
    public var isApple: Bool { label.lowercased().hasPrefix("com.apple.") }
}

/// Asks launchd about jobs and stops them. The app uses `SystemLaunchControl`; tests and the flow test use
/// `RecordingLaunchControl`, so `launchctl` is never run there.
public protocol LaunchControlling: Sendable {
    /// The labels loaded in your login session (`gui/<uid>`), or nil when they cannot be read.
    func loadedUserLabels() -> Set<String>?
    /// Whether a daemon is loaded in the system domain, or nil when that cannot be read without an administrator.
    func isLoadedInSystem(_ label: String) -> Bool?
    /// Stops a job in your login session (`launchctl bootout gui/<uid>/<label>`). A job that is not loaded is fine.
    func bootOut(_ label: String) throws
}

public enum LaunchControlError: Error, LocalizedError, Equatable {
    case failed(String)
    public var errorDescription: String? {
        switch self {
        case .failed(let reason): return reason
        }
    }
}

/// Runs `/bin/launchctl` for your own login session only. It never asks for an administrator.
public struct SystemLaunchControl: LaunchControlling {
    public init() {}

    static let launchctl = "/bin/launchctl"

    public func loadedUserLabels() -> Set<String>? {
        guard let output = Command.run(Self.launchctl, ["list"], timeout: 10), output.status == 0 else { return nil }
        return Self.parseList(output.text)
    }

    public func isLoadedInSystem(_ label: String) -> Bool? {
        guard let output = Command.run(Self.launchctl, ["print", "system/" + label], timeout: 3) else { return nil }
        switch output.status {
        case 0: return true
        case 113: return false // "Could not find service"
        default: return nil
        }
    }

    public func bootOut(_ label: String) throws {
        let target = "gui/\(getuid())/" + label
        guard let output = Command.run(Self.launchctl, ["bootout", target], timeout: 15) else {
            throw LaunchControlError.failed(String(localized: "launchd did not answer."))
        }
        // 3 "No such process", 36 "Operation now in progress", 113 "Could not find service": not loaded or stopping.
        if [0, 3, 36, 113].contains(output.status) { return }
        throw LaunchControlError.failed(String(format: String(localized: "launchd could not stop it (error %d)."), Int(output.status)))
    }

    /// The labels in `launchctl list` output ("PID\tStatus\tLabel" lines).
    public static func parseList(_ text: String) -> Set<String> {
        var labels = Set<String>()
        for line in text.split(separator: "\n").dropFirst() {
            let parts = line.split(separator: "\t", omittingEmptySubsequences: false)
            if parts.count >= 3 {
                let label = parts[2].trimmingCharacters(in: .whitespaces)
                if !label.isEmpty { labels.insert(label) }
            }
        }
        return labels
    }
}

/// A launchd stand-in that remembers what it was asked to stop.
public final class RecordingLaunchControl: LaunchControlling, @unchecked Sendable {
    private let lock = NSLock()
    private var loaded: Set<String>
    private var stopped: [String] = []
    public var failing: Set<String>

    public init(loaded: Set<String> = [], failing: Set<String> = []) {
        self.loaded = loaded
        self.failing = failing
    }

    public var bootedOut: [String] { lock.lock(); defer { lock.unlock() }; return stopped }

    public func loadedUserLabels() -> Set<String>? { lock.lock(); defer { lock.unlock() }; return loaded }
    public func isLoadedInSystem(_ label: String) -> Bool? { nil }

    public func bootOut(_ label: String) throws {
        lock.lock()
        defer { lock.unlock() }
        if failing.contains(label) { throw LaunchControlError.failed("launchd could not stop it.") }
        stopped.append(label)
        loaded.remove(label)
    }
}

/// Lists what starts with the Mac, and turns off your own launch agents.
public struct LoginItemFinder: Sendable {
    public let homePath: String
    /// The folder that holds the shared `LaunchAgents` and `LaunchDaemons`: `/Library`, or a test's own.
    public let sharedLibrary: String
    public let policy: SafetyPolicy

    public init(homePath: String = NSHomeDirectory(), sharedLibrary: String = "/Library", policy: SafetyPolicy? = nil) {
        self.homePath = DiskScanner.standardize(homePath)
        self.sharedLibrary = DiskScanner.standardize(sharedLibrary)
        self.policy = policy ?? SafetyPolicy(homePath: homePath)
    }

    public var userAgents: String { homePath + "/Library/LaunchAgents" }

    /// Everything found, your agents first, then the shared ones, then helpers that apps manage. Apple's own jobs
    /// are left out of the shared folders, as macOS keeps its own elsewhere.
    public func find(installed: [InstalledApp], control: any LaunchControlling) -> [LaunchItem] {
        let loaded = control.loadedUserLabels()
        var items: [LaunchItem] = []
        let folders: [(String, LaunchItem.Domain)] = [
            (userAgents, .userAgent), (sharedLibrary + "/LaunchAgents", .systemAgent),
            (sharedLibrary + "/LaunchDaemons", .systemDaemon),
        ]
        for (folder, domain) in folders {
            for entry in JunkFinder.entries(in: folder) where entry.name.hasSuffix(".plist") && entry.kind != .directory {
                let path = folder + "/" + entry.name
                guard var item = Self.read(plist: path, domain: domain, installed: installed) else { continue }
                switch domain {
                case .systemDaemon: item.isLoaded = control.isLoadedInSystem(item.label)
                default: item.isLoaded = loaded.map { $0.contains(item.label) }
                }
                items.append(item)
            }
        }
        items += appManaged(installed: installed, loaded: loaded)
        return items.sorted { a, b in
            let order = LaunchItem.Domain.allCases
            let da = order.firstIndex(of: a.domain) ?? 0, db = order.firstIndex(of: b.domain) ?? 0
            if da != db { return da < db }
            return a.title.localizedStandardCompare(b.title) == .orderedAscending
        }
    }

    /// Reads one launchd plist. Nil when it is not one.
    static func read(plist path: String, domain: LaunchItem.Domain, installed: [InstalledApp]) -> LaunchItem? {
        guard let info = AppUninstaller.readPlist(path) else { return nil }
        let fileName = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
        let label = (info["Label"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? fileName
        let program = LaunchItemReader.program(of: info)
        let associated = info["AssociatedBundleIdentifiers"] as? [String]
            ?? (info["AssociatedBundleIdentifiers"] as? String).map { [$0] } ?? []
        let owner = Self.owner(label: label, program: program, associated: associated, installed: installed)
        let keepAlive = (info["KeepAlive"] as? Bool) ?? (info["KeepAlive"] is [String: Any])
        let startsByItself = (info["RunAtLoad"] as? Bool ?? false) || keepAlive
        let exists = program.map { DirectoryReader.entry(atPath: $0) != nil } ?? false
        return LaunchItem(label: label, plistPath: path, domain: domain, program: program, ownerName: owner?.name,
                          ownerPath: owner?.path, programExists: exists, startsByItself: startsByItself)
    }

    /// The installed app a job belongs to: the one whose bundle holds its program, that it names as associated, or
    /// whose identifier its label is or starts with.
    static func owner(label: String, program: String?, associated: [String], installed: [InstalledApp]) -> InstalledApp? {
        if let program, let app = installed.first(where: { program.hasPrefix($0.path + "/") }) { return app }
        let ids = Set(associated.map { $0.lowercased() })
        if let app = installed.first(where: { $0.bundleID.map { ids.contains($0.lowercased()) } ?? false }) { return app }
        let lower = label.lowercased()
        return installed
            .filter { app in app.bundleID.map { lower == $0.lowercased() || lower.hasPrefix($0.lowercased() + ".") } ?? false }
            .max { ($0.bundleID?.count ?? 0) < ($1.bundleID?.count ?? 0) }
    }

    /// Helpers that apps carry and turn on themselves: login item apps in `Contents/Library/LoginItems` and the
    /// agents and daemons in `Contents/Library/LaunchAgents` and `LaunchDaemons` (`SMAppService`). Whether one is on
    /// is shown in System Settings > General > Login Items.
    func appManaged(installed: [InstalledApp], loaded: Set<String>?) -> [LaunchItem] {
        var items: [LaunchItem] = []
        for app in installed where !app.isApple {
            let contents = app.path + "/Contents/Library"
            for entry in JunkFinder.entries(in: contents + "/LoginItems") where entry.name.hasSuffix(".app") {
                let helper = contents + "/LoginItems/" + entry.name
                let info = AppUninstaller.readPlist(helper + "/Contents/Info.plist") ?? [:]
                let label = (info["CFBundleIdentifier"] as? String) ?? (entry.name as NSString).deletingPathExtension
                items.append(LaunchItem(label: label, plistPath: nil, domain: .appManaged, program: helper,
                                        ownerName: app.name, ownerPath: app.path, startsByItself: false,
                                        isLoaded: loaded.map { $0.contains(label) }))
            }
            for folder in ["LaunchAgents", "LaunchDaemons"] {
                for entry in JunkFinder.entries(in: contents + "/" + folder) where entry.name.hasSuffix(".plist") {
                    let path = contents + "/" + folder + "/" + entry.name
                    guard let item = Self.read(plist: path, domain: .appManaged, installed: [app]) else { continue }
                    items.append(LaunchItem(label: item.label, plistPath: nil, domain: .appManaged, program: item.program,
                                            ownerName: app.name, ownerPath: app.path, programExists: item.programExists,
                                            startsByItself: item.startsByItself,
                                            isLoaded: folder == "LaunchAgents" ? loaded.map { $0.contains(item.label) } : nil))
                }
            }
        }
        return items
    }

    // MARK: Turning off

    /// Why `item` cannot be turned off here, or nil when it can. Only your own launch agents can: a plist directly in
    /// `~/Library/LaunchAgents` that is not Apple's and that the safety rules allow to move.
    public func refusal(for item: LaunchItem) -> String? {
        guard item.domain == .userAgent, let plist = item.plistPath else {
            return String(localized: "This needs an administrator or is managed by its app. Turn it off in System Settings > General > Login Items.")
        }
        if item.isApple { return String(localized: "This is part of macOS.") }
        let path = DiskScanner.standardize(plist)
        guard (path as NSString).deletingLastPathComponent == userAgents, path.hasSuffix(".plist") else {
            return String(localized: "Only launch agents in your own LaunchAgents folder can be turned off here.")
        }
        guard let entry = DirectoryReader.entry(atPath: path), entry.kind == .file else {
            return String(localized: "The launch agent's file is gone or is not a plain file.")
        }
        if item.label.isEmpty || item.label.contains("/") { return String(localized: "The launch agent has no usable label.") }
        if case .blocked(let reason) = policy.verdict(for: path) { return reason }
        return nil
    }

    /// Stops a launch agent in your login session and moves its plist to the Trash, so it does not start again. The
    /// plist stays in the Trash, so Put Back brings it back. Refused items, and ones launchd could not stop, are not
    /// moved.
    public func turnOff(_ item: LaunchItem, control: any LaunchControlling, cleanup: CleanupService) -> CleanupResult {
        let path = item.plistPath ?? item.id
        let bytes = DirectoryReader.entry(atPath: path)?.allocated ?? 0
        if let reason = refusal(for: item) {
            return CleanupResult(path: path, bytes: bytes, trashedTo: nil, error: reason)
        }
        do {
            try control.bootOut(item.label)
        } catch {
            return CleanupResult(path: path, bytes: bytes, trashedTo: nil, error: error.localizedDescription)
        }
        let report = cleanup.execute(cleanup.plan(paths: [path], sizeOf: { _ in bytes }))
        return report.results.first ?? CleanupResult(path: path, bytes: bytes, trashedTo: nil,
                                                     error: String(localized: "unknown error"))
    }
}
