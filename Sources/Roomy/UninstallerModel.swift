import AppKit
import Observation
import RoomyCore

/// State for the Uninstaller window: the installed apps, the leftovers of the chosen app, the leftovers of apps that
/// are gone, and moving what is ticked to the Trash.
@MainActor
@Observable
final class UninstallerModel {
    enum Phase: Equatable {
        case idle
        case loading
        case ready
        case removing
        case done
    }

    enum SortOrder: String, CaseIterable, Identifiable {
        case size = "Size"
        case name = "Name"
        case lastUsed = "Last Used"
        var id: String { rawValue }
        var label: String { NSLocalizedString(rawValue, comment: "") }
    }

    /// What the detail panel shows.
    enum Focus: Equatable {
        case app(String)
        case orphans
    }

    var phase: Phase = .idle
    /// Apps that can be listed: everything but the apps that come with macOS.
    private(set) var apps: [InstalledApp] = []
    /// Every bundle found, Apple's too, so their files never count as leftovers.
    @ObservationIgnored private var allApps: [InstalledApp] = []
    private(set) var measured: Set<String> = []
    var searchText = ""
    var sort: SortOrder = .size
    var focus: Focus?

    private(set) var leftovers: [Leftover] = []
    private(set) var isFindingLeftovers = false
    var ticked: Set<String> = []

    private(set) var orphans: [OrphanGroup] = []
    private(set) var isFindingOrphans = false
    private(set) var orphansLoaded = false
    var orphanTicked: Set<String> = []

    private(set) var runningPaths: Set<String> = []
    private(set) var errorMessage: String?

    private(set) var cleanTotal = 0
    private(set) var cleanedCount = 0
    private(set) var cleanedBytes: Int64 = 0
    private(set) var report: CleanupReport?
    /// The app that is being removed, for the flying icon and the result.
    private(set) var removingApp: InstalledApp?
    /// Set when the app bundle itself could not be moved.
    private(set) var appFailure: String?

    @ObservationIgnored var onRemoved: (([String]) -> Void)?
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private var detailTask: Task<Void, Never>?
    @ObservationIgnored private let uninstaller = AppUninstaller(homePath: AppEnvironment.home, appFolders: AppEnvironment.appFolders)

    var isBusy: Bool { phase == .loading || phase == .removing }

    var selectedApp: InstalledApp? {
        guard case .app(let path) = focus else { return nil }
        return apps.first { $0.path == path }
    }

    /// The apps that match the search, in the chosen order.
    var visibleApps: [InstalledApp] {
        let query = searchText.trimmingCharacters(in: .whitespaces)
        let filtered = query.isEmpty ? apps : apps.filter {
            $0.name.localizedCaseInsensitiveContains(query) || ($0.bundleID?.localizedCaseInsensitiveContains(query) ?? false)
        }
        switch sort {
        case .size:
            return filtered.sorted { $0.bytes != $1.bytes ? $0.bytes > $1.bytes : Self.byName($0, $1) }
        case .name:
            return filtered.sorted(by: Self.byName)
        case .lastUsed:
            // Longest unused first, so apps you forgot about come to the top. Unknown dates go last.
            return filtered.sorted { a, b in
                switch (a.lastUsed, b.lastUsed) {
                case let (x?, y?): return x != y ? x < y : Self.byName(a, b)
                case (nil, nil): return Self.byName(a, b)
                case (_?, nil): return true
                case (nil, _?): return false
                }
            }
        }
    }

    nonisolated private static func byName(_ a: InstalledApp, _ b: InstalledApp) -> Bool {
        a.name.localizedStandardCompare(b.name) == .orderedAscending
    }

    var totalAppBytes: Int64 { apps.reduce(0) { $0 + $1.bytes } }
    var leftoverBytes: Int64 { leftovers.reduce(0) { $0 + $1.bytes } }

    /// What Uninstall would move to the Trash, with sizes.
    var tickedBytes: Int64 {
        guard let app = selectedApp else { return 0 }
        let bundle = ticked.contains(app.path) ? app.bytes : 0
        return bundle + leftovers.filter { ticked.contains($0.path) }.reduce(0) { $0 + $1.bytes }
    }

    var tickedCount: Int {
        guard let app = selectedApp else { return 0 }
        return (ticked.contains(app.path) ? 1 : 0) + leftovers.filter { ticked.contains($0.path) }.count
    }

    var orphanBytes: Int64 { orphans.reduce(0) { $0 + $1.bytes } }
    var orphanTickedItems: [Leftover] { orphans.flatMap(\.items).filter { orphanTicked.contains($0.path) } }
    var orphanTickedBytes: Int64 { orphanTickedItems.reduce(0) { $0 + $1.bytes } }

    var cleanFraction: Double { cleanTotal == 0 ? 0 : Double(cleanedCount) / Double(cleanTotal) }

    func blockReason(for app: InstalledApp) -> String? {
        uninstaller.blockReason(for: app, runningPaths: runningPaths)
    }

    // MARK: Loading

    /// Lists the apps, then measures them one by one so their sizes fill in.
    func load() {
        guard phase != .removing else { return }
        loadTask?.cancel()
        detailTask?.cancel()
        phase = .loading
        errorMessage = nil
        report = nil
        focus = nil
        leftovers = []
        orphans = []
        orphansLoaded = false
        orphanTicked = []
        refreshRunning()

        let uninstaller = uninstaller
        loadTask = Task {
            let list = await Task.detached { uninstaller.listApps() }.value
            guard !Task.isCancelled else { return }
            self.allApps = list
            self.apps = list.filter { !$0.isApple && !$0.path.hasPrefix("/System/") }
            self.measured = []
            self.phase = .ready
            await self.measureApps()
        }
    }

    private func measureApps() async {
        let paths = apps.map(\.path)
        await withTaskGroup(of: (String, Int64).self) { group in
            for path in paths {
                group.addTask { (path, await Self.size(of: path)) }
            }
            for await (path, bytes) in group {
                if Task.isCancelled { break }
                if let i = apps.firstIndex(where: { $0.path == path }) { apps[i].bytes = bytes }
                if let i = allApps.firstIndex(where: { $0.path == path }) { allApps[i].bytes = bytes }
                measured.insert(path)
            }
        }
    }

    nonisolated private static func size(of path: String) async -> Int64 {
        DiskUsage.allocatedSize(atPath: path)
    }

    nonisolated private static func standardize(_ path: String) -> String {
        var p = (path as NSString).standardizingPath
        while p.count > 1 && p.hasSuffix("/") { p.removeLast() }
        return p
    }

    /// Reads which apps are open. When the chosen app was open and has quit, its items are ticked again.
    func refreshRunning() {
        let wasBlocked = selectedApp.map { blockReason(for: $0) != nil } ?? false
        runningPaths = Set(NSWorkspace.shared.runningApplications.compactMap { $0.bundleURL.map { Self.standardize($0.path) } })
        if wasBlocked, let app = selectedApp, blockReason(for: app) == nil, ticked.isEmpty {
            ticked = Set([app.path] + leftovers.filter { !$0.needsReview }.map(\.path))
        }
    }

    // MARK: Choosing

    /// Shows an app in the detail panel and looks for its leftovers.
    func select(_ app: InstalledApp) {
        guard phase == .ready else { return }
        if focus == .app(app.path) { return }
        detailTask?.cancel()
        focus = .app(app.path)
        isFindingOrphans = false
        leftovers = []
        refreshRunning()
        ticked = blockReason(for: app) == nil ? [app.path] : []
        isFindingLeftovers = true

        let uninstaller = uninstaller
        let installed = allApps
        detailTask = Task {
            let found = await Task.detached {
                await AppUninstaller.measure(uninstaller.leftovers(for: app, installed: installed))
            }.value
            guard !Task.isCancelled, self.focus == .app(app.path) else { return }
            self.leftovers = found
            // Items matched only through a dotted child id may belong to another app, so they start unticked.
            if self.blockReason(for: app) == nil { self.ticked.formUnion(found.filter { !$0.needsReview }.map(\.path)) }
            self.isFindingLeftovers = false
        }
    }

    /// Shows the leftovers of apps that are gone. Nothing is ticked: they are guesses to review.
    func showOrphans() {
        guard phase == .ready else { return }
        detailTask?.cancel()
        isFindingLeftovers = false
        focus = .orphans
        guard !orphansLoaded else { return }
        isFindingOrphans = true
        refreshRunning()
        let running = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        let uninstaller = uninstaller
        let installed = allApps
        detailTask = Task {
            let groups = await Task.detached { () -> [OrphanGroup] in
                let found = uninstaller.orphans(installed: installed, knownIDs: running)
                let measured = await AppUninstaller.measure(found.flatMap(\.items))
                let byPath = Dictionary(measured.map { ($0.path, $0) }, uniquingKeysWith: { a, _ in a })
                return found.map { group in
                    OrphanGroup(bundleID: group.bundleID,
                                items: group.items.compactMap { byPath[$0.path] }.sorted { $0.bytes > $1.bytes })
                }
                .sorted { $0.bytes != $1.bytes ? $0.bytes > $1.bytes : $0.bundleID < $1.bundleID }
            }.value
            guard !Task.isCancelled else { return }
            self.orphans = groups
            self.orphansLoaded = true
            self.isFindingOrphans = false
        }
    }

    func closeDetail() {
        detailTask?.cancel()
        isFindingLeftovers = false
        isFindingOrphans = false
        focus = nil
    }

    func toggle(_ path: String) {
        if ticked.contains(path) { ticked.remove(path) } else { ticked.insert(path) }
    }

    func setAll(_ items: [Leftover], ticked on: Bool) {
        if on { ticked.formUnion(items.map(\.path)) } else { ticked.subtract(items.map(\.path)) }
    }

    func toggleOrphan(_ path: String) {
        if orphanTicked.contains(path) { orphanTicked.remove(path) } else { orphanTicked.insert(path) }
    }

    func setAllOrphans(_ group: OrphanGroup, ticked on: Bool) {
        if on { orphanTicked.formUnion(group.items.map(\.path)) } else { orphanTicked.subtract(group.items.map(\.path)) }
    }

    /// Asks the chosen app to quit, the same as choosing Quit in it.
    func quit(_ app: InstalledApp) {
        for running in NSWorkspace.shared.runningApplications where running.bundleURL.map({ Self.standardize($0.path) }) == app.path {
            running.terminate()
        }
    }

    // MARK: Removing

    /// Moves the ticked bundle and leftovers of the chosen app to the Trash.
    func uninstall() {
        guard phase == .ready, let app = selectedApp else { return }
        refreshRunning()
        if ticked.contains(app.path), let reason = blockReason(for: app) {
            errorMessage = reason
            return
        }
        var sizes: [String: Int64] = [app.path: app.bytes]
        for item in leftovers { sizes[item.path] = item.bytes }
        // Leftovers first, so the app is still there if something goes wrong on the way.
        let paths = leftovers.map(\.path).filter { ticked.contains($0) } + (ticked.contains(app.path) ? [app.path] : [])
        start(paths: paths, sizes: sizes, app: app)
    }

    /// Moves the ticked leftovers of removed apps to the Trash.
    func removeOrphans() {
        guard phase == .ready else { return }
        let items = orphanTickedItems
        start(paths: items.map(\.path), sizes: Dictionary(items.map { ($0.path, $0.bytes) }, uniquingKeysWith: { a, _ in a }), app: nil)
    }

    private func start(paths: [String], sizes: [String: Int64], app: InstalledApp?) {
        guard !paths.isEmpty else { return }
        errorMessage = nil
        appFailure = nil
        removingApp = app
        cleanTotal = paths.count
        cleanedCount = 0
        cleanedBytes = 0
        phase = .removing

        Task.detached {
            let service = AppEnvironment.cleanupService()
            // Leftovers go first and the app last, so if something fails the app is still there to try again.
            let appPath = app?.path
            let rest = paths.filter { $0 != appPath }
            var results: [CleanupResult] = []
            let leftoverReport = service.execute(service.plan(paths: rest, sizeOf: { sizes[$0] ?? 0 })) { result in
                Task { @MainActor in self.advance(result) }
            }
            results += leftoverReport.results
            if let appPath, paths.contains(appPath) {
                let appReport = service.execute(service.plan(paths: [appPath], sizeOf: { sizes[$0] ?? 0 })) { result in
                    Task { @MainActor in self.advance(result) }
                }
                results += appReport.results
            }
            // Let the icon land in the Trash and the ring finish before the result appears.
            try? await Task.sleep(for: .milliseconds(700))
            await self.finish(CleanupReport(date: Date(), results: results))
        }
    }

    private func advance(_ result: CleanupResult) {
        cleanedCount += 1
        if result.succeeded { cleanedBytes += result.bytes }
    }

    private func finish(_ report: CleanupReport) {
        self.report = report
        cleanedCount = cleanTotal
        cleanedBytes = report.freedBytes
        let removed = Set(report.succeeded.map(\.path))

        if let app = removingApp, let failure = report.failed.first(where: { $0.path == app.path }) {
            appFailure = String(format: String(localized: "%@ could not be moved to the Trash: %@. Apps from the App Store or installed for all users can need an administrator: drag the app to the Trash in Finder, which asks for your password."), app.name, failure.error ?? String(localized: "unknown error"))
        }
        apps.removeAll { removed.contains($0.path) }
        allApps.removeAll { removed.contains($0.path) }
        leftovers.removeAll { removed.contains($0.path) }
        ticked.subtract(removed)
        orphans = orphans.compactMap { group in
            let left = group.items.filter { !removed.contains($0.path) }
            return left.isEmpty ? nil : OrphanGroup(bundleID: group.bundleID, items: left)
        }
        orphanTicked.subtract(removed)
        if let app = removingApp, removed.contains(app.path) {
            focus = nil
            // The app is gone, so its leftovers left behind now count as leftovers of a removed app.
            orphansLoaded = false
        }
        onRemoved?(Array(removed))
        phase = .done
    }

    /// Back to the list after removing.
    func showList() {
        guard phase == .done else { return }
        removingApp = nil
        phase = .ready
    }

    func reveal(_ path: String) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    func openTrash() {
        NSWorkspace.shared.open(URL(fileURLWithPath: NSHomeDirectory() + "/.Trash"))
    }
}
