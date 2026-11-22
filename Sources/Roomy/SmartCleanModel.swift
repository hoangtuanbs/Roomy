import AppKit
import Observation
import RoomyCore

/// State for the Smart Clean window: finding junk, ticking it, and moving it to the Trash.
@MainActor
@Observable
final class SmartCleanModel {
    enum Phase: Equatable {
        case idle
        case scanning(String)
        case ready
        case cleaning
        case done
    }

    var phase: Phase = .idle
    private(set) var findings: [JunkFinding] = []
    var selection = JunkSelection()
    var expanded: Set<String> = []

    private(set) var cleanTotal = 0
    private(set) var cleanedCount = 0
    private(set) var cleanedBytes: Int64 = 0
    private(set) var report: CleanupReport?

    private(set) var isEmptyingTrash = false
    private(set) var trashResult: TrashEraseResult?

    /// Called with the paths that went to the Trash or were erased, so the main scan can drop them.
    @ObservationIgnored var onRemoved: (([String]) -> Void)?
    @ObservationIgnored private var scanTask: Task<Void, Never>?

    var cleanable: [JunkFinding] { findings.filter { !$0.isPermanent } }
    var trash: JunkFinding? { findings.first { $0.isPermanent } }
    var selectedItems: [JunkItem] { selection.selectedItems(in: findings) }
    var selectedBytes: Int64 { selection.selectedBytes(in: findings) }
    var cleanFraction: Double { cleanTotal == 0 ? 0 : Double(cleanedCount) / Double(cleanTotal) }

    var isBusy: Bool {
        if case .scanning = phase { return true }
        return phase == .cleaning || isEmptyingTrash
    }

    func scan(tree: ScanTree?) {
        guard phase != .cleaning, !isEmptyingTrash else { return }
        scanTask?.cancel()
        phase = .scanning(String(localized: "Looking for junk…"))
        findings = []
        selection = JunkSelection()
        expanded = []
        report = nil
        trashResult = nil

        let running = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        let finder = JunkFinder(skippedCacheNames: running)
        scanTask = Task {
            let found = await finder.find(tree: tree) { step in
                Task { @MainActor in
                    guard case .scanning = self.phase else { return }
                    self.phase = .scanning(String(format: String(localized: "Measuring %@…"), step.lowercased()))
                }
            }
            guard !Task.isCancelled else { return }
            self.findings = found
            self.selection = JunkSelection(findings: found)
            self.phase = .ready
        }
    }

    func cancelScan() {
        scanTask?.cancel()
        scanTask = nil
        if case .scanning = phase { phase = .idle }
    }

    func toggleExpanded(_ finding: JunkFinding) {
        if expanded.contains(finding.id) { expanded.remove(finding.id) } else { expanded.insert(finding.id) }
    }

    /// Moves the ticked items to the Trash through the safety policy.
    func clean() {
        guard phase == .ready else { return }
        let items = selectedItems
        guard !items.isEmpty else { return }
        let sizes = Dictionary(items.map { ($0.path, $0.bytes) }, uniquingKeysWith: { first, _ in first })
        let paths = items.map(\.path)
        cleanTotal = items.count
        cleanedCount = 0
        cleanedBytes = 0
        phase = .cleaning

        Task.detached {
            let service = CleanupService()
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
        drop(Set(removed))
        onRemoved?(removed)
        phase = .done
    }

    /// Erases everything that was in the Trash when it was measured. The view asks first.
    func emptyTrash() {
        guard let trash, !isEmptyingTrash, phase == .ready else { return }
        isEmptyingTrash = true
        let items = trash.items
        Task.detached {
            let result = TrashEmptier().erase(items)
            await self.finishTrash(result)
        }
    }

    private func finishTrash(_ result: TrashEraseResult) {
        isEmptyingTrash = false
        trashResult = result
        drop(Set(result.erased))
        onRemoved?(result.erased)
    }

    private func drop(_ removed: Set<String>) {
        findings = findings.compactMap { $0.removing(removed) }
        selection.remove(removed)
    }

    func reveal(_ path: String) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    func openTrash() {
        NSWorkspace.shared.open(URL(fileURLWithPath: NSHomeDirectory() + "/.Trash"))
    }
}
