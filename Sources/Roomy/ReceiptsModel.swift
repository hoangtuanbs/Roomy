import AppKit
import Observation
import RoomyCore

/// State for the Installers tab of the Uninstaller: packages whose app is gone, and the files they left that you can
/// move to the Trash. Nothing starts ticked.
@MainActor
@Observable
final class ReceiptsModel {
    private(set) var findings: [ReceiptFinding] = []
    private(set) var isLoading = false
    private(set) var loaded = false
    var ticked: Set<String> = []

    /// Called with the apps the receipts name, so Leftovers of removed apps can find their files by name.
    @ObservationIgnored var onFound: (([RemovedApp]) -> Void)?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored let finder = ReceiptFinder(database: AppEnvironment.packageDatabase, policy: AppEnvironment.policy)

    var tickedItems: [ReceiptFile] { findings.flatMap(\.leftovers).filter { ticked.contains($0.path) } }
    var tickedBytes: Int64 { tickedItems.reduce(0) { $0 + $1.bytes } }
    var totalBytes: Int64 { findings.reduce(0) { $0 + $1.bytes } }

    func reset() {
        task?.cancel()
        loaded = false
        isLoading = false
    }

    /// Reads the receipts with pkgutil (no admin rights). `installedNames` keeps apps that were moved from counting
    /// as gone.
    func load(installedNames: Set<String>) {
        task?.cancel()
        isLoading = true
        ticked = []
        let finder = finder
        task = Task {
            let found = await Task.detached { ReceiptFinder.measure(finder.find(installedNames: installedNames)) }.value
            guard !Task.isCancelled else { return }
            self.findings = found
            self.isLoading = false
            self.loaded = true
            self.onFound?(found.map(\.removedApp))
        }
    }

    func toggle(_ path: String) {
        if ticked.contains(path) { ticked.remove(path) } else { ticked.insert(path) }
    }

    func setAll(_ finding: ReceiptFinding, ticked on: Bool) {
        let paths = finding.leftovers.map(\.path)
        if on { ticked.formUnion(paths) } else { ticked.subtract(paths) }
    }

    /// Drops items that were moved to the Trash.
    func removed(_ paths: [String]) {
        let gone = Set(paths)
        ticked.subtract(gone)
        findings = findings.map { finding in
            var kept = finding
            kept.leftovers.removeAll { gone.contains($0.path) }
            return kept
        }
    }

    func reveal(_ path: String) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }
}
