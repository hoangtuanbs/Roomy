import AppKit
import Observation
import RoomyCore

/// State for the Duplicates window: finding identical files, choosing which copy to keep, and moving the rest
/// to the Trash.
@MainActor
@Observable
final class DuplicatesModel {
    enum Phase: Equatable {
        case idle
        case scanning
        case ready
        case cleaning
        case done
    }

    var phase: Phase = .idle
    private(set) var progress = DuplicateProgress(stage: .listing)
    /// The folder the search looked in.
    private(set) var scope = ""
    private(set) var groups: [DuplicateGroup] = []
    var selection = DuplicateSelection()
    var expanded: Set<String> = []
    private(set) var errorMessage: String?

    private(set) var cleanTotal = 0
    private(set) var cleanedCount = 0
    private(set) var cleanedBytes: Int64 = 0
    private(set) var report: CleanupReport?

    /// Called with the paths that went to the Trash, so the main scan can drop them.
    @ObservationIgnored var onRemoved: (([String]) -> Void)?
    @ObservationIgnored private var scanTask: Task<Void, Never>?

    var selectedFiles: [DuplicateFile] { selection.selectedFiles(in: groups) }
    var selectedBytes: Int64 { selection.selectedBytes(in: groups) }
    var wastedBytes: Int64 { groups.reduce(0) { $0 + $1.wastedBytes } }
    var cleanFraction: Double { cleanTotal == 0 ? 0 : Double(cleanedCount) / Double(cleanTotal) }
    var isBusy: Bool { phase == .scanning || phase == .cleaning }

    /// Looks in the scan when there is one, otherwise scans `folder` first.
    func scan(tree: ScanTree?, folder: String?) {
        guard phase != .cleaning else { return }
        scanTask?.cancel()
        groups = []
        selection = DuplicateSelection()
        expanded = []
        report = nil
        errorMessage = nil
        progress = DuplicateProgress(stage: tree == nil ? .listing : .comparing)
        scope = tree?.rootPath ?? folder ?? ""
        guard tree != nil || folder != nil else {
            phase = .idle
            return
        }
        phase = .scanning

        let finder = DuplicateFinder(homePath: AppEnvironment.home)
        scanTask = Task {
            let report: @Sendable (DuplicateProgress) -> Void = { step in
                Task { @MainActor in
                    guard self.phase == .scanning else { return }
                    self.progress = step
                }
            }
            do {
                let found: [DuplicateGroup]
                if let tree {
                    found = try await finder.find(in: tree, progress: report)
                } else {
                    found = try await finder.find(folder: folder ?? "", progress: report)
                }
                guard !Task.isCancelled else { return }
                self.groups = found
                self.selection = DuplicateSelection(groups: found)
                // The biggest group starts open, so the copies are visible right away.
                if let first = found.first { self.expanded = [first.id] }
                self.phase = .ready
            } catch is CancellationError {
            } catch {
                guard !Task.isCancelled else { return }
                self.errorMessage = error.localizedDescription
                self.phase = .ready
            }
        }
    }

    /// Asks for a folder and looks for duplicates in it.
    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = String(localized: "Find Duplicates")
        panel.message = String(localized: "Choose a folder to look for duplicate files in.")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        scan(tree: nil, folder: url.path)
    }

    func cancelScan() {
        scanTask?.cancel()
        scanTask = nil
        if phase == .scanning { phase = .idle }
    }

    func toggleExpanded(_ group: DuplicateGroup) {
        if expanded.contains(group.id) { expanded.remove(group.id) } else { expanded.insert(group.id) }
    }

    /// Moves the ticked copies to the Trash through the safety policy. Groups whose kept copy is gone are skipped.
    func clean() {
        guard phase == .ready else { return }
        let files = selection.removableFiles(in: groups)
        guard !files.isEmpty else { return }
        let sizes = Dictionary(files.map { ($0.path, $0.bytes) }, uniquingKeysWith: { first, _ in first })
        let paths = files.map(\.path)
        cleanTotal = files.count
        cleanedCount = 0
        cleanedBytes = 0
        phase = .cleaning

        Task.detached {
            let service = AppEnvironment.cleanupService(.duplicates)
            let plan = service.plan(paths: paths, sizeOf: { sizes[$0] ?? 0 })
            let report = service.execute(plan) { result in
                Task { @MainActor in self.advance(result) }
            }
            // Let the progress ring finish before the result appears.
            try? await Task.sleep(for: .milliseconds(450))
            await self.finishClean(report)
        }
    }

    private func advance(_ result: CleanupResult) {
        cleanedCount += 1
        if result.succeeded { cleanedBytes += result.bytes }
    }

    private func finishClean(_ report: CleanupReport) {
        self.report = report
        cleanedCount = cleanTotal
        cleanedBytes = report.freedBytes
        let removed = report.succeeded.map(\.path)
        let set = Set(removed)
        groups = groups.compactMap { $0.removing(set) }
        selection.remove(set)
        onRemoved?(removed)
        phase = .done
    }

    /// Back to the list after a clean, with what is left.
    func showRemaining() {
        guard phase == .done else { return }
        phase = .ready
    }

    func reveal(_ path: String) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    func open(_ path: String) {
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
    }

    func openTrash() {
        NSWorkspace.shared.open(URL(fileURLWithPath: NSHomeDirectory() + "/.Trash"))
    }
}
