import AppKit
import Observation
import RoomyCore
import SwiftUI

enum ContentTab: String, CaseIterable, Identifiable {
    case folders = "Folders"
    case files = "Biggest Files"
    var id: Self { self }
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
}

enum AgeFilter: String, CaseIterable, Identifiable {
    case any = "Any age"
    case month = "Older than 30 days"
    case halfYear = "Older than 6 months"
    case year = "Older than 1 year"
    var id: Self { self }

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
    var tab: ContentTab = .folders
    var searchText = ""
    var hovered: ScanTree.Index?
    var categoryFilter: FileCategory?
    var ageFilter: AgeFilter = .any
    private(set) var biggestFiles: [ScanTree.Index] = []

    var basket: Set<ScanTree.Index> = []
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

    var hasFullDiskAccess = FullDiskAccess.isGranted()
    var showOnboarding = false

    let policy = SafetyPolicy()
    let home = NSHomeDirectory()

    init() {
        refreshLocations()
        let dismissed = UserDefaults.standard.bool(forKey: "onboardingDismissed")
        showOnboarding = !hasFullDiskAccess && !dismissed

        // `Roomy --scan <folder>` starts scanning that folder right away.
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--scan"), i + 1 < args.count {
            showOnboarding = false
            scan(path: (args[i + 1] as NSString).expandingTildeInPath)
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
                window.title = "Donate"
                window.makeKeyAndOrderFront(nil)
                try? await Task.sleep(for: .seconds(1))
                Self.saveSnapshot(of: window, to: output)
                NSApplication.shared.terminate(nil)
            }
        }
        if let i = args.firstIndex(of: "--snapshot"), i + 1 < args.count {
            let output = (args[i + 1] as NSString).expandingTildeInPath
            Task { [weak self] in
                while let self, self.state.isScanning { try? await Task.sleep(for: .milliseconds(200)) }
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
        get { UserDefaults.standard.stringArray(forKey: "pinnedFolders") ?? [] }
        set { UserDefaults.standard.set(newValue, forKey: "pinnedFolders") }
    }

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Scan"
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

    func scan(path: String) {
        scanTask?.cancel()
        selectedPath = path
        state = .scanning(ScanProgress())
        tree = nil
        basket = []
        biggestFiles = []
        currentFolder = ScanTree.root
        hovered = nil
        lastReport = nil

        scanTask = Task { [weak self] in
            do {
                let result = try await DiskScanner().scan(root: path) { [weak self] progress in
                    Task { @MainActor in
                        guard let self, self.selectedPath == path, self.state.isScanning else { return }
                        self.state = .scanning(progress)
                    }
                }
                guard let self, !Task.isCancelled else { return }
                self.tree = result
                self.biggestFiles = result.largestFiles(limit: 500)
                self.treeVersion += 1
                self.state = .ready
            } catch is CancellationError {
            } catch {
                self?.state = .failed(error.localizedDescription)
            }
        }
    }

    func cancelScan() {
        scanTask?.cancel()
        scanTask = nil
        state = .idle
        selectedPath = nil
    }

    func rescan() {
        guard let path = tree?.rootPath ?? selectedPath else { return }
        scan(path: path)
    }

    func open(_ node: ScanTree.Index) {
        guard let tree, tree.kind(node) == .directory else { return }
        currentFolder = node
        hovered = nil
    }

    func goUp() {
        guard let tree, let parent = tree.parent(currentFolder) else { return }
        currentFolder = parent
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
        guard let tree else { return .blocked("No scan") }
        let flags = tree.flags(node)
        if flags.contains(.otherVolume) { return .blocked("This is another disk.") }
        if flags.contains(.removed) { return .blocked("Already moved to the Trash.") }
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
        if tree.kind(node).isContainer && tree.containsDescendant(named: ".git", under: node) {
            out.append("Contains a Git repository. Check for work you have not pushed.")
        }
        let path = tree.path(of: node)
        let running = NSWorkspace.shared.runningApplications.contains { app in
            guard let bundle = app.bundleURL?.path else { return false }
            return bundle == path || bundle.hasPrefix(path + "/")
        }
        if running { out.append("This app is running. Quit it first.") }
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
            let service = CleanupService(policy: policy)
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
        treeVersion += 1
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
            let service = CompressionService(policy: policy)
            var results: [CompressionResult] = []
            for (i, item) in items.enumerated() {
                if Task.isCancelled { break }
                self?.compressStatus = "Compressing \((item.path as NSString).lastPathComponent) (\(i + 1) of \(items.count))…"
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
        biggestFiles = tree.largestFiles(limit: 500)
        treeVersion += 1
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
        UserDefaults.standard.set(true, forKey: "onboardingDismissed")
        showOnboarding = false
    }
}
