import AppKit
import Observation
import RoomyCore
import SwiftUI

enum ContentTab: String, CaseIterable, Identifiable {
    case folders = "Folders"
    case files = "Biggest Files"
    var id: Self { self }
    var label: String { NSLocalizedString(rawValue, comment: "") }
}

enum MapStyle: String, CaseIterable, Identifiable {
    case treemap = "Treemap"
    case rings = "Rings"
    var id: Self { self }
    var label: String { NSLocalizedString(rawValue, comment: "") }

    var symbol: String { self == .treemap ? "square.grid.2x2" : "circle.circle" }
}

enum ScanState {
    case idle
    case scanning(ScanProgress)
    case ready
    case failed(String)

    var isScanning: Bool {
        if case .scanning = self { return true }
        return false
    }

    /// Which kind of state this is, without the progress, so a view can animate between them.
    var phase: Int {
        switch self {
        case .idle: return 0
        case .scanning: return 1
        case .ready: return 2
        case .failed: return 3
        }
    }
}

enum AgeFilter: String, CaseIterable, Identifiable {
    case any = "Any age"
    case month = "Older than 30 days"
    case halfYear = "Older than 6 months"
    case year = "Older than 1 year"
    var id: Self { self }
    var label: String { NSLocalizedString(rawValue, comment: "") }

    var cutoff: Date? {
        let day: TimeInterval = 86_400
        switch self {
        case .any: return nil
        case .month: return Date().addingTimeInterval(-30 * day)
        case .halfYear: return Date().addingTimeInterval(-182 * day)
        case .year: return Date().addingTimeInterval(-365 * day)
        }
    }
}

struct Location: Identifiable, Hashable {
    var id: String { path }
    let path: String
    let name: String
    let symbol: String
    var total: Int64? = nil
    var available: Int64? = nil
}

@MainActor
@Observable
final class AppModel {
    var volumes: [Location] = []
    var folders: [Location] = []
    var selectedPath: String?

    var state: ScanState = .idle
    private(set) var tree: ScanTree?
    private(set) var treeVersion = 0
    private var scanTask: Task<Void, Never>?

    var currentFolder: ScanTree.Index = ScanTree.root
    /// The item chosen in a list, the treemap or the rings. Space shows it in Quick Look.
    var selection: ScanTree.Index? {
        didSet { if selection != oldValue { updateQuickLook() } }
    }
    /// True while the last move went to an enclosing folder, so the map zooms out instead of in.
    private(set) var zoomingOut = false
    var mapStyle: MapStyle = MapStyle(rawValue: AppEnvironment.defaults.string(forKey: "mapStyle") ?? "") ?? .treemap {
        didSet { AppEnvironment.defaults.set(mapStyle.rawValue, forKey: "mapStyle") }
    }
    var tab: ContentTab = .folders
    var searchText = ""
    var hovered: ScanTree.Index?
    var categoryFilter: FileCategory?
    var ageFilter: AgeFilter = .any
    private(set) var biggestFiles: [ScanTree.Index] = []

    /// The tray: items collected for cleaning, by dragging, the context menu or the tick boxes.
    var basket: Set<ScanTree.Index> = []
    /// A short note shown in the tray, such as why an item could not be added.
    var trayNotice: String?
    private var trayNoticeTask: Task<Void, Never>?
    var showReview = false
    var lastReport: CleanupReport?
    var isCleaning = false

    var compressTargets: [ScanTree.Index] = []
    var showCompress = false
    var isCompressing = false
    var compressStatus: String?
    /// The items a running compression works through, fixed when it starts.
    private(set) var compressQueue: [ScanTree.Index] = []
    var compressResults: [CompressionResult]?
    private var compressTask: Task<Void, Never>?

    let smartClean = SmartCleanModel()
    let diskOverview = DiskOverviewModel()
    var showSmartClean = false
    let duplicates = DuplicatesModel()
    var showDuplicates = false
    let uninstaller = UninstallerModel()
    var showUninstaller = false
    let spaceHunters = SpaceHuntersModel()
    var showSpaceHunters = false
    let cloudSpace = CloudSpaceModel()
    var showCloudSpace = false
    /// What each disk reports about its own health, shown in Disk Health and as dots in the menu bar.
    let diskHealth = DiskHealthModel()
    var showDiskHealth = false
    /// The background junk check behind the menu bar's Quick Clean.
    let autoCheck = AutoCheckModel()

    /// When the shown results were scanned. Older than now when they came from the cache.
    private(set) var scannedAt: Date?
    /// True while a fresh scan runs behind results that are already shown.
    private(set) var isRefreshing = false
    private(set) var refreshProgress: ScanProgress?
    private(set) var refreshError: String?
    /// Paths removed while a fresh scan ran; they are dropped from its result too.
    private var removedDuringRefresh: [String] = []
    /// The folder being scanned again on its own.
    private(set) var rescanningNode: ScanTree.Index?
    private var subtreeTask: Task<Void, Never>?
    let scanCache = AppEnvironment.scanCache
    private var keyMonitor: Any?

    var hasFullDiskAccess = FullDiskAccess.isGranted()
    var showOnboarding = false

    let policy = AppEnvironment.policy
    let home = AppEnvironment.home

    init() {
        MainWindow.model = self
        refreshLocations()
        smartClean.onRemoved = { [weak self] paths in self?.applyRemoved(paths) }
        duplicates.onRemoved = { [weak self] paths in self?.applyRemoved(paths) }
        uninstaller.onRemoved = { [weak self] paths in self?.applyRemoved(paths) }
        spaceHunters.onRemoved = { [weak self] paths in self?.applyRemoved(paths) }
        spaceHunters.onShowAccessHelp = { [weak self] in self?.showAccessHelpFromHunters() }
        autoCheck.onRemoved = { [weak self] paths in self?.applyRemoved(paths) }
        let dismissed = AppEnvironment.defaults.bool(forKey: "onboardingDismissed")
        showOnboarding = !hasFullDiskAccess && !dismissed && !AppEnvironment.isFlowTest

        installKeyMonitor()
        QuickLook.shared.onMove = { [weak self] delta in self?.moveSelection(by: delta) }

        // `RoomyDisk --scan <folder>` starts scanning that folder right away.
        let args = CommandLine.arguments
        if AppEnvironment.isFlowTest {
            // `--flow-test <sandbox>` drives the app's flows itself, starting from an empty window.
            FlowTest.start(model: self)
            return
        }
        if let i = args.firstIndex(of: "--scan"), i + 1 < args.count {
            showOnboarding = false
            scan(path: (args[i + 1] as NSString).expandingTildeInPath, useCache: false)
        } else if let last = AppEnvironment.defaults.string(forKey: "lastScanPath"),
                  FileManager.default.fileExists(atPath: scanCache.filePath(forRoot: last)) {
            // Show the last scan at once from the cache while a fresh one runs.
            scan(path: last)
        }
        // Developer option for the README screenshot: `--snapshot <file.png>` (with --scan) waits for the
        // scan, ticks the two largest items, saves the window as a PNG and quits. Nothing is moved or changed.
        // `--snapshot-about <file.png>` does the same for the About panel.
        if let i = args.firstIndex(of: "--snapshot-about"), i + 1 < args.count {
            let output = (args[i + 1] as NSString).expandingTildeInPath
            Task {
                try? await Task.sleep(for: .seconds(1))
                About.show()
                try? await Task.sleep(for: .seconds(1))
                if let panel = NSApplication.shared.windows.first(where: { $0.isVisible && $0 is NSPanel }) {
                    Self.saveSnapshot(of: panel, to: output)
                }
                NSApplication.shared.terminate(nil)
            }
        }
        // `--snapshot-donate <file.png>` does the same for the Donate window.
        if let i = args.firstIndex(of: "--snapshot-donate"), i + 1 < args.count {
            let output = (args[i + 1] as NSString).expandingTildeInPath
            Task {
                try? await Task.sleep(for: .seconds(1))
                let window = NSWindow(contentViewController: NSHostingController(rootView: DonateView()))
                window.title = String(localized: "Donate")
                window.makeKeyAndOrderFront(nil)
                try? await Task.sleep(for: .seconds(1))
                Self.saveSnapshot(of: window, to: output)
                NSApplication.shared.terminate(nil)
            }
        }
        if let i = args.firstIndex(of: "--tour"), i + 1 < args.count {
            ScreenTour.run(model: self, into: (args[i + 1] as NSString).expandingTildeInPath)
        } else if !args.contains("--snapshot") {
            // The tour runs its own check; snapshots don't need one.
            autoCheck.start()
        }
        if let i = args.firstIndex(of: "--snapshot"), i + 1 < args.count {
            let output = (args[i + 1] as NSString).expandingTildeInPath
            Task { [weak self] in
                while let self, self.state.isScanning || self.isRefreshing { try? await Task.sleep(for: .milliseconds(200)) }
                guard let self, let tree = self.tree else { return }
                NSApplication.shared.appearance = NSAppearance(named: .aqua)
                for node in tree.children(ScanTree.root).prefix(2) { self.toggleBasket(node) }
                try? await Task.sleep(for: .seconds(2))
                if let window = NSApplication.shared.windows.first(where: { $0.isVisible && $0.contentView != nil }) {
                    Self.saveSnapshot(of: window, to: output)
                }
                NSApplication.shared.terminate(nil)
            }
        }
    }

    private static func saveSnapshot(of window: NSWindow, to path: String) {
        let rep: NSBitmapImageRep
        // CGWindowListCreateImage is hidden from Swift in newer SDKs but still works for the app's own window,
        // and unlike cacheDisplay it includes the sidebar and toolbar materials.
        typealias CreateImage = @convention(c) (CGRect, CGWindowListOption, CGWindowID, CGWindowImageOption) -> Unmanaged<CGImage>?
        if let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImage"),
           let image = unsafeBitCast(symbol, to: CreateImage.self)(
               .null, .optionIncludingWindow, CGWindowID(window.windowNumber), [.boundsIgnoreFraming, .bestResolution]
           )?.takeRetainedValue() {
            rep = NSBitmapImageRep(cgImage: image)
        } else {
            guard let frameView = window.contentView?.superview,
                  let cached = frameView.bitmapImageRepForCachingDisplay(in: frameView.bounds) else { return }
            frameView.cacheDisplay(in: frameView.bounds, to: cached)
            rep = cached
        }
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }

    func refreshLocations() {
        let keys: [URLResourceKey] = [.volumeNameKey, .volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey]
        let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? []
        volumes = urls.compactMap { url in
            guard let values = try? url.resourceValues(forKeys: Set(keys)) else { return nil }
            let isRoot = url.path == "/"
            return Location(
                path: url.path,
                name: values.volumeName ?? url.lastPathComponent,
                symbol: isRoot ? "internaldrive" : "externaldrive",
                total: values.volumeTotalCapacity.map { Int64($0) },
                available: values.volumeAvailableCapacityForImportantUsage
            )
        }
        let fm = FileManager.default
        let standard: [(String, String)] = [
            ("Desktop", "menubar.dock.rectangle"), ("Documents", "doc"), ("Downloads", "arrow.down.circle"),
            ("Pictures", "photo"), ("Movies", "film"), ("Developer", "hammer"), ("Development", "hammer"),
        ]
        var list = [Location(path: home, name: NSUserName(), symbol: "house")]
        for (name, symbol) in standard where fm.fileExists(atPath: home + "/" + name) {
            list.append(Location(path: home + "/" + name, name: name, symbol: symbol))
        }
        for path in pinnedPaths where !list.contains(where: { $0.path == path }) {
            list.append(Location(path: path, name: (path as NSString).lastPathComponent, symbol: "folder"))
        }
        folders = list
    }

    private var pinnedPaths: [String] {
        get { AppEnvironment.defaults.stringArray(forKey: "pinnedFolders") ?? [] }
        set { AppEnvironment.defaults.set(newValue, forKey: "pinnedFolders") }
    }

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = String(localized: "Scan")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        pin(url.path)
        scan(path: url.path)
    }

    func pin(_ path: String) {
        var pins = pinnedPaths
        if !pins.contains(path) {
            pins.append(path)
            pinnedPaths = pins
            refreshLocations()
        }
    }

    func unpin(_ path: String) {
        pinnedPaths = pinnedPaths.filter { $0 != path }
        refreshLocations()
    }

    func isPinned(_ path: String) -> Bool { pinnedPaths.contains(path) }

    /// Shows `path`: its cached scan at once when there is one, while a fresh scan runs.
    func scan(path: String, useCache: Bool = true) {
        scanTask?.cancel()
        subtreeTask?.cancel()
        rescanningNode = nil
        selectedPath = path
        state = .scanning(ScanProgress())
        tree = nil
        basket = []
        biggestFiles = []
        currentFolder = ScanTree.root
        selection = nil
        hovered = nil
        lastReport = nil
        scannedAt = nil
        isRefreshing = false
        refreshProgress = nil
        refreshError = nil
        removedDuringRefresh = []
        AppEnvironment.defaults.set(path, forKey: "lastScanPath")

        let cache = scanCache
        scanTask = Task { [weak self] in
            if useCache {
                let cached = await Task.detached(priority: .userInitiated) { () -> (tree: ScanTree, date: Date)? in
                    cache.load(root: path).map { (tree: ScanTree(snapshot: $0), date: $0.scannedAt) }
                }.value
                guard let self, !Task.isCancelled, self.selectedPath == path else { return }
                if let cached {
                    self.install(cached.tree, scannedAt: cached.date, keepPlace: false)
                    self.isRefreshing = true
                }
            }
            await self?.runScan(path: path)
        }
    }

    /// Scans `path` and shows the result. When results are shown already, they stay until the new ones are in.
    private func runScan(path: String) async {
        do {
            let result = try await DiskScanner().scan(root: path) { [weak self] progress in
                Task { @MainActor in
                    guard let self, self.selectedPath == path else { return }
                    if self.isRefreshing {
                        self.refreshProgress = progress
                    } else if self.state.isScanning {
                        self.state = .scanning(progress)
                    }
                }
            }
            guard !Task.isCancelled, selectedPath == path else { return }
            for removed in removedDuringRefresh {
                if let node = result.index(ofPath: removed) { result.detach(node) }
            }
            let keep = isRefreshing
            install(result, scannedAt: Date(), keepPlace: keep)
            saveCache()
        } catch is CancellationError {
        } catch {
            guard selectedPath == path else { return }
            if isRefreshing {
                refreshError = error.localizedDescription
                isRefreshing = false
                refreshProgress = nil
            } else {
                state = .failed(error.localizedDescription)
            }
        }
    }

    /// Shows a new tree. With `keepPlace`, the open folder, the selection and the tray carry over by path.
    private func install(_ new: ScanTree, scannedAt date: Date, keepPlace: Bool) {
        subtreeTask?.cancel()
        rescanningNode = nil
        var folderPath: String?
        var selectionPath: String?
        var trayPaths: [String] = []
        if keepPlace, let old = tree {
            folderPath = old.path(of: currentFolder)
            selectionPath = selection.map { old.path(of: $0) }
            trayPaths = basket.map { old.path(of: $0) }
        }
        tree = new
        biggestFiles = new.largestFiles(limit: 500)
        currentFolder = folderPath.flatMap { new.index(ofPath: $0) } ?? ScanTree.root
        selection = selectionPath.flatMap { new.index(ofPath: $0) }
        basket = Set(trayPaths.compactMap { new.index(ofPath: $0) })
        hovered = nil
        scannedAt = date
        isRefreshing = false
        refreshProgress = nil
        refreshError = nil
        removedDuringRefresh = []
        treeVersion += 1
        state = .ready
    }

    /// Saves the shown tree for next time, off the main thread.
    private func saveCache() {
        guard let tree, let scannedAt else { return }
        let snapshot = tree.snapshot(scannedAt: scannedAt)
        let cache = scanCache
        Task.detached(priority: .utility) { try? cache.save(snapshot) }
    }

    /// Notes paths that were moved to the Trash, so a fresh scan that is running leaves them out.
    private func noteRemoved(_ paths: [String]) {
        if isRefreshing { removedDuringRefresh.append(contentsOf: paths) }
        saveCache()
    }

    var canRescanSubtree: Bool {
        guard case .ready = state else { return false }
        return !isRefreshing && rescanningNode == nil
    }

    /// Scans one folder again and puts the result in place of what the tree had for it.
    func rescanSubtree(_ node: ScanTree.Index) {
        guard let tree, canRescanSubtree, tree.kind(node).isContainer else { return }
        if node == ScanTree.root {
            rescan()
            return
        }
        let path = tree.path(of: node)
        let families = tree.cloneFamilies(carriedOutside: node)
        rescanningNode = node
        subtreeTask = Task { [weak self] in
            let fresh = try? await DiskScanner().scan(root: path, cloneFamilies: families)
            guard let self, !Task.isCancelled else { return }
            self.rescanningNode = nil
            // Skip it if a new scan replaced the tree meanwhile, or the folder went to the Trash.
            guard let fresh, let current = self.tree, current === tree, !current.flags(node).contains(.removed) else { return }
            current.replaceSubtree(node, with: fresh)
            self.basket = self.basket.filter { !current.flags($0).contains(.removed) }
            if let selection = self.selection, current.flags(selection).contains(.removed) { self.selection = nil }
            if current.flags(self.currentFolder).contains(.removed) { self.currentFolder = node }
            self.biggestFiles = current.largestFiles(limit: 500)
            self.treeVersion += 1
            self.saveCache()
        }
    }

    /// What the current scan found, minus what was removed since.
    var scannedBytes: Int64 { tree?.size(ScanTree.root) ?? 0 }

    /// Reads the space of the scanned disk again, for the disk overview.
    func refreshDiskOverview() {
        guard let tree else { return }
        diskOverview.refresh(scanRoot: tree.rootPath, scanned: tree.size(ScanTree.root))
    }

    func cancelScan() {
        if isRefreshing {
            // Keep the results that are shown.
            scanTask?.cancel()
            scanTask = nil
            isRefreshing = false
            refreshProgress = nil
            return
        }
        scanTask?.cancel()
        scanTask = nil
        state = .idle
        selectedPath = nil
    }

    /// Scans the shown folder again. The current results stay on screen until the new ones are in.
    func rescan() {
        guard let path = tree?.rootPath ?? selectedPath else { return }
        guard tree != nil, case .ready = state else {
            scan(path: path, useCache: false)
            return
        }
        guard !isRefreshing else { return }
        scanTask?.cancel()
        subtreeTask?.cancel()
        rescanningNode = nil
        isRefreshing = true
        refreshError = nil
        removedDuringRefresh = []
        scanTask = Task { [weak self] in await self?.runScan(path: path) }
    }

    func open(_ node: ScanTree.Index) {
        guard let tree, tree.kind(node) == .directory else { return }
        zoomingOut = false
        currentFolder = node
        hovered = nil
    }

    func goUp() {
        guard let tree, let parent = tree.parent(currentFolder) else { return }
        zoomingOut = true
        currentFolder = parent
        hovered = nil
    }

    /// Shows `node`, from the path bar.
    func go(to node: ScanTree.Index) {
        guard let tree, node != currentFolder else { return }
        zoomingOut = tree.isAncestor(node, of: currentFolder)
        currentFolder = node
        hovered = nil
    }

    /// Opens a folder, or opens a file in its app. Double-click and Return do this.
    func activate(_ node: ScanTree.Index) {
        guard let tree else { return }
        if tree.kind(node) == .directory { open(node) } else { openItem(node) }
    }

    var breadcrumb: [ScanTree.Index] {
        tree?.lineage(of: currentFolder) ?? []
    }

    var visibleChildren: [ScanTree.Index] {
        _ = treeVersion
        guard let tree else { return [] }
        let kids = tree.children(currentFolder)
        let query = searchText.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return kids }
        return kids.filter { tree.name($0).localizedCaseInsensitiveContains(query) }
    }

    var filteredBiggestFiles: [ScanTree.Index] {
        _ = treeVersion
        guard let tree else { return [] }
        let query = searchText.trimmingCharacters(in: .whitespaces)
        let cutoff = ageFilter.cutoff
        return biggestFiles.filter { node in
            if tree.flags(node).contains(.removed) { return false }
            if let categoryFilter, category(of: node) != categoryFilter { return false }
            if let cutoff, tree.modifiedDate(node) > cutoff { return false }
            if !query.isEmpty, !tree.name(node).localizedCaseInsensitiveContains(query) { return false }
            return true
        }
    }

    func category(of node: ScanTree.Index) -> FileCategory {
        guard let tree else { return .other }
        return FileCategory.classify(name: tree.name(node), kind: tree.kind(node))
    }

    func path(of node: ScanTree.Index) -> String {
        tree?.path(of: node) ?? ""
    }

    func verdict(for node: ScanTree.Index) -> SafetyVerdict {
        guard let tree else { return .blocked(String(localized: "No scan")) }
        let flags = tree.flags(node)
        if flags.contains(.otherVolume) { return .blocked(String(localized: "This is another disk.")) }
        if flags.contains(.removed) { return .blocked(String(localized: "Already moved to the Trash.")) }
        return policy.verdict(for: tree.path(of: node))
    }

    func reveal(_ node: ScanTree.Index) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path(of: node))])
    }

    func openItem(_ node: ScanTree.Index) {
        NSWorkspace.shared.open(URL(fileURLWithPath: path(of: node)))
    }

    func copyPath(_ node: ScanTree.Index) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(path(of: node), forType: .string)
    }

    // MARK: Quick Look

    /// The items the arrow keys move through: the list on screen when it holds the selection, otherwise its siblings.
    private var selectionContext: [ScanTree.Index] {
        guard let tree, let selection else { return [] }
        let list = tab == .folders ? visibleChildren : filteredBiggestFiles
        if list.contains(selection) { return list }
        if let parent = tree.parent(selection) { return tree.children(parent) }
        return [selection]
    }

    func moveSelection(by delta: Int) {
        let list = selectionContext
        guard let selection, let i = list.firstIndex(of: selection) else { return }
        let next = min(max(0, i + delta), list.count - 1)
        if next != i { self.selection = list[next] }
    }

    func quickLook(_ node: ScanTree.Index) {
        selection = node
        QuickLook.shared.show(URL(fileURLWithPath: path(of: node)))
    }

    func toggleQuickLook() {
        if QuickLook.shared.isVisible {
            QuickLook.shared.close()
        } else if let selection {
            quickLook(selection)
        }
    }

    private func updateQuickLook() {
        guard QuickLook.shared.isVisible, let selection, tree != nil else { return }
        QuickLook.shared.show(URL(fileURLWithPath: path(of: selection)))
    }

    private var anySheetOpen: Bool {
        showReview || showCompress || showSmartClean || showDuplicates || showUninstaller || showSpaceHunters
            || showCloudSpace || showDiskHealth || showOnboarding
    }

    /// Space opens and closes Quick Look for the selection, unless a text field is being edited.
    private func installKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let handled = MainActor.assumeIsolated { () -> Bool in
                guard let self, event.keyCode == 49,
                      event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty,
                      let window = event.window, !(window is NSPanel), window.attachedSheet == nil,
                      !(window.firstResponder is NSText), !self.anySheetOpen,
                      self.selection != nil, case .ready = self.state else { return false }
                self.toggleQuickLook()
                return true
            }
            return handled ? nil : event
        }
    }

    // MARK: Tray

    func isInBasket(_ node: ScanTree.Index) -> Bool {
        guard let tree else { return false }
        if basket.contains(node) { return true }
        return basket.contains { tree.isAncestor($0, of: node) }
    }

    func toggleBasket(_ node: ScanTree.Index) {
        guard let tree else { return }
        if basket.contains(node) {
            basket.remove(node)
            return
        }
        if basket.contains(where: { tree.isAncestor($0, of: node) }) { return }
        guard !verdict(for: node).isBlocked else { return }
        basket = basket.filter { !tree.isAncestor(node, of: $0) }
        basket.insert(node)
    }

    /// Adds an item to the tray. Returns false when it is there already or may not be removed.
    @discardableResult
    func addToTray(_ node: ScanTree.Index) -> Bool {
        guard let tree, !isInBasket(node) else { return false }
        let verdict = verdict(for: node)
        if verdict.isBlocked {
            showTrayNotice(String(format: String(localized: "%@ can’t be added. %@"), tree.name(node), verdict.message ?? ""))
            return false
        }
        basket = basket.filter { !tree.isAncestor(node, of: $0) }
        basket.insert(node)
        return true
    }

    /// Adds dropped items to the tray by path. Returns how many were added.
    func addToTray(paths: [String]) -> Int {
        guard let tree else { return 0 }
        return paths.compactMap { tree.index(ofPath: $0) }.filter { addToTray($0) }.count
    }

    private func showTrayNotice(_ text: String) {
        trayNotice = text
        trayNoticeTask?.cancel()
        trayNoticeTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            self?.trayNotice = nil
        }
    }

    var basketBytes: Int64 {
        guard let tree else { return 0 }
        return basket.reduce(0) { $0 + tree.size($1) }
    }

    var basketItems: [ScanTree.Index] {
        guard let tree else { return [] }
        return basket.sorted { tree.size($0) > tree.size($1) }
    }

    func warnings(for node: ScanTree.Index) -> [String] {
        guard let tree else { return [] }
        var out: [String] = []
        if let message = verdict(for: node).message { out.append(message) }
        if tree.flags(node).contains(.clone) {
            out.append(String(localized: "This is a clone that shares space with other files. Moving it to the Trash frees only the space that is its own."))
        }
        if tree.kind(node).isContainer && tree.containsDescendant(named: ".git", under: node) {
            out.append(String(localized: "Contains a Git repository. Check for work you have not pushed."))
        }
        let path = tree.path(of: node)
        let running = NSWorkspace.shared.runningApplications.contains { app in
            guard let bundle = app.bundleURL?.path else { return false }
            return bundle == path || bundle.hasPrefix(path + "/")
        }
        if running { out.append(String(localized: "This app is running. Quit it first.")) }
        return out
    }

    func performCleanup() {
        guard let tree, !basket.isEmpty, !isCleaning else { return }
        isCleaning = true
        let nodes = basketItems
        let paths = nodes.map { tree.path(of: $0) }
        let sizes = Dictionary(uniqueKeysWithValues: nodes.map { (tree.path(of: $0), tree.size($0)) })
        let policy = self.policy

        Task.detached {
            let service = CleanupService(policy: policy, history: AppEnvironment.history)
            let plan = service.plan(paths: paths, sizeOf: { sizes[$0] ?? 0 })
            let report = service.execute(plan)
            await MainActor.run { [weak self] in
                self?.finishCleanup(report)
            }
        }
    }

    private func finishCleanup(_ report: CleanupReport) {
        if let tree {
            for result in report.succeeded {
                if let node = tree.index(ofPath: result.path) { tree.detach(node) }
            }
        }
        basket = []
        lastReport = report
        isCleaning = false
        if let selection, tree?.flags(selection).contains(.removed) == true { self.selection = nil }
        biggestFiles = tree?.largestFiles(limit: 500) ?? []
        treeVersion += 1
        noteRemoved(report.succeeded.map(\.path))
        refreshLocations()
    }

    /// Opens Smart Clean and looks for junk again, unless it is busy.
    /// Saves the current folder as CSV. Depth 1 lists its children; larger depths add the folders inside them.
    func exportCSV(depth: Int) {
        guard let tree else { return }
        CSVExporter.save(tree: tree, folder: currentFolder, depth: depth)
    }

    func openSmartClean() {
        showSmartClean = true
        if !smartClean.isBusy { smartClean.scan(tree: state.isScanning ? nil : tree) }
    }

    /// Opens Duplicates and looks in the current scan again, unless it is busy.
    func openDuplicates() {
        showDuplicates = true
        if !duplicates.isBusy { findDuplicates() }
    }

    /// Looks for duplicates in the current scan. Without a finished scan, Duplicates asks for a folder.
    func findDuplicates() {
        duplicates.scan(tree: state.isScanning ? nil : tree, folder: nil)
    }

    /// Opens the Uninstaller and reads the installed apps again, unless it is busy.
    func openUninstaller() {
        showUninstaller = true
        if !uninstaller.isBusy && uninstaller.phase != .done { uninstaller.load() }
    }

    /// Opens Space Hunters and hunts again, unless it is busy.
    func openSpaceHunters() {
        showSpaceHunters = true
        if !spaceHunters.isBusy { huntSpace() }
    }

    /// Hunts for old backups, downloads, Mail attachments and similar photos. Photos are looked for in the
    /// finished scan, or in ~/Pictures without one.
    func huntSpace() {
        spaceHunters.hunt(tree: state.isScanning ? nil : tree)
    }

    /// Opens Cloud Space and looks for downloaded cloud files again, unless it is busy.
    func openCloudSpace() {
        showCloudSpace = true
        if !cloudSpace.isBusy { cloudSpace.find() }
    }

    /// Opens Disk Health and reads the disks again, unless a read is already running.
    func openDiskHealth() {
        showDiskHealth = true
        diskHealth.refresh()
    }

    /// Closes Space Hunters and shows the Full Disk Access guide; only one sheet can be open at a time.
    private func showAccessHelpFromHunters() {
        showSpaceHunters = false
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(450))
            showOnboarding = true
        }
    }

    /// Drops items that Smart Clean, Duplicates or the Uninstaller removed from the current scan.
    private func applyRemoved(_ paths: [String]) {
        autoCheck.drop(paths)
        if let tree, !paths.isEmpty {
            for path in paths {
                if let node = tree.index(ofPath: path) { tree.detach(node) }
            }
            basket = basket.filter { !tree.flags($0).contains(.removed) }
            if let selection, tree.flags(selection).contains(.removed) { self.selection = nil }
            biggestFiles = tree.largestFiles(limit: 500)
            treeVersion += 1
            noteRemoved(paths)
        }
        refreshLocations()
    }

    func canCompress(_ node: ScanTree.Index) -> Bool {
        guard let tree, node != ScanTree.root, !isCompressing else { return false }
        let kind = tree.kind(node)
        guard kind == .file || kind.isContainer else { return false }
        let flags = tree.flags(node)
        if flags.contains(.inaccessible) || flags.contains(.removed) || flags.contains(.otherVolume) { return false }
        return tree.size(node) > 0 && !verdict(for: node).isBlocked
    }

    var canCompressBasket: Bool { basketItems.contains { canCompress($0) } }

    func startCompress(_ node: ScanTree.Index) {
        guard canCompress(node) else { return }
        openCompress([node])
    }

    /// Compresses everything in the cleanup list.
    func startCompressBasket() {
        guard canCompressBasket else { return }
        openCompress(basketItems)
    }

    func dropCompressTarget(_ node: ScanTree.Index) {
        guard !isCompressing else { return }
        compressTargets.removeAll { $0 == node }
    }

    private func openCompress(_ nodes: [ScanTree.Index]) {
        compressTargets = nodes
        compressResults = nil
        compressStatus = nil
        showCompress = true
    }

    func performCompress() {
        guard let tree, !isCompressing else { return }
        let items = compressTargets.filter { canCompress($0) }.map { (node: $0, path: tree.path(of: $0), size: tree.size($0)) }
        guard !items.isEmpty else { return }
        compressQueue = items.map(\.node)
        isCompressing = true
        let policy = self.policy

        compressTask = Task { [weak self] in
            let service = CompressionService(policy: policy, history: AppEnvironment.history)
            var results: [CompressionResult] = []
            for (i, item) in items.enumerated() {
                if Task.isCancelled { break }
                self?.compressStatus = String(format: String(localized: "Compressing %@ (%lld of %lld)…"), (item.path as NSString).lastPathComponent, i + 1, items.count)
                let result = await service.compressAndTrash(path: item.path, originalBytes: item.size)
                results.append(result)
                self?.applyCompression(result, node: item.node, in: tree)
            }
            self?.finishCompress(results)
        }
    }

    func cancelCompress() {
        compressTask?.cancel()
    }

    private func applyCompression(_ result: CompressionResult, node: ScanTree.Index, in scanned: ScanTree) {
        // Skip the tree update if a new scan replaced the tree meanwhile.
        guard let tree, tree === scanned, let archive = result.archivePath, let parent = tree.parent(node) else { return }
        if result.succeeded { tree.detach(node) }
        // On failure the archive is only kept when the original could not be moved to the Trash.
        tree.insertFile(named: (archive as NSString).lastPathComponent, in: parent,
                        size: result.archiveBytes, modified: Date())
        basket = basket.filter { !tree.flags($0).contains(.removed) }
        if let selection, tree.flags(selection).contains(.removed) { self.selection = nil }
        biggestFiles = tree.largestFiles(limit: 500)
        treeVersion += 1
        noteRemoved(result.succeeded ? [tree.path(of: node)] : [])
    }

    private func finishCompress(_ results: [CompressionResult]) {
        compressTask = nil
        isCompressing = false
        compressStatus = nil
        compressResults = results
        refreshLocations()
    }

    func closeCompress() {
        guard !isCompressing else { return }
        showCompress = false
        compressTargets = []
        compressResults = nil
    }

    func revealPath(_ path: String) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    func openTrash() {
        NSWorkspace.shared.open(URL(fileURLWithPath: home + "/.Trash"))
    }

    func refreshAccess() {
        let granted = FullDiskAccess.isGranted()
        if granted != hasFullDiskAccess {
            hasFullDiskAccess = granted
            if granted { showOnboarding = false }
        }
    }

    func openFullDiskAccessSettings() {
        NSWorkspace.shared.open(FullDiskAccess.settingsURL)
    }

    func dismissOnboarding() {
        AppEnvironment.defaults.set(true, forKey: "onboardingDismissed")
        showOnboarding = false
    }
}
