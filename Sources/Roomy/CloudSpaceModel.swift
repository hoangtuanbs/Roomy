import AppKit
import Observation
import RoomyCore

/// State for Cloud Space: finds the local copies of files kept in iCloud Drive, Dropbox, OneDrive, Google Drive
/// and Box, and removes the ticked local copies. Files stay in the cloud; nothing is moved or deleted.
@MainActor
@Observable
final class CloudSpaceModel {
    enum Phase: Equatable {
        case idle
        case finding
        case ready
        case evicting
        case done
    }

    var phase: Phase = .idle
    private(set) var providers: [CloudProvider] = []
    private(set) var findings = CloudSpaceFinder.Findings()
    private(set) var progress: CloudSpaceFinder.Progress?
    var selection = CloudSelection()
    var expanded: Set<String> = []

    private(set) var evictTotal = 0
    private(set) var evictedCount = 0
    private(set) var evictedBytes: Int64 = 0
    /// The ticked bytes when removing started, so the number left can count down.
    private(set) var evictStartBytes: Int64 = 0
    private(set) var report: CloudEvictionReport?
    /// The providers the last removal was for, for the "still in …" wording.
    private(set) var evictedProviders: [CloudProvider] = []

    @ObservationIgnored private var task: Task<Void, Never>?
    let locations = CloudLocations(homePath: AppEnvironment.home)

    var isBusy: Bool { phase == .finding || phase == .evicting }
    var hasProviders: Bool { !providers.isEmpty }
    var evictFraction: Double { evictTotal == 0 ? 0 : Double(evictedCount) / Double(evictTotal) }
    var bytesLeft: Int64 { max(0, evictStartBytes - evictedBytes) }

    var selectedItems: [CloudItem] { selection.selectedItems(in: findings) }
    var selectedBytes: Int64 { selection.selectedBytes(in: findings) }
    var selectedProviders: [CloudProvider] { selection.selectedProviders(in: findings) }

    /// "iCloud Drive", "iCloud Drive and Dropbox", or "the cloud" when nothing is ticked.
    static func names(_ providers: [CloudProvider]) -> String {
        let names = providers.map(\.name).reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
        switch names.count {
        case 0: return String(localized: "the cloud")
        case 1: return names[0]
        default: return names.dropLast().joined(separator: ", ") + String(localized: " and ") + names.last!
        }
    }

    // MARK: Finding

    func find() {
        guard phase != .evicting else { return }
        task?.cancel()
        providers = locations.providers()
        findings = CloudSpaceFinder.Findings()
        progress = nil
        selection = CloudSelection()
        report = nil
        phase = .finding

        let providers = self.providers
        // Detached, so the walk runs off the main thread and stops when cancelled.
        task = Task.detached(priority: .userInitiated) {
            let found = CloudSpaceFinder(providers: providers).find { progress in
                Task { @MainActor in self.setProgress(progress) }
            }
            guard !Task.isCancelled else { return }
            // Let the ring settle before the results appear.
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            await self.finishFind(found)
        }
    }

    private func finishFind(_ found: CloudSpaceFinder.Findings) {
        guard phase == .finding else { return }
        findings = found
        expanded = Set(found.providers.map(\.id))
        phase = .ready
    }

    private func setProgress(_ progress: CloudSpaceFinder.Progress) {
        guard phase == .finding else { return }
        self.progress = progress
    }

    func cancel() {
        task?.cancel()
        task = nil
        if phase == .finding { phase = .idle }
    }

    // MARK: Ticking

    func toggle(_ group: CloudFolderGroup) {
        selection.toggle(group)
    }

    func setAll(_ provider: CloudProviderFindings, selected: Bool) {
        selection.setAll(provider, selected: selected)
    }

    func toggleExpanded(_ provider: CloudProviderFindings) {
        if expanded.contains(provider.id) { expanded.remove(provider.id) } else { expanded.insert(provider.id) }
    }

    // MARK: Removing local copies

    /// Removes the local copies of the ticked folders' uploaded files. Each file's status is read again first.
    func removeDownloads() {
        guard phase == .ready else { return }
        let items = selectedItems
        guard !items.isEmpty else { return }
        evictedProviders = selectedProviders
        evictTotal = items.count
        evictedCount = 0
        evictedBytes = 0
        evictStartBytes = items.reduce(0) { $0 + $1.bytes }
        phase = .evicting

        let providers = self.providers
        Task.detached {
            let service = CloudEvictionService(providers: providers)
            let report = service.evict(items) { result in
                Task { @MainActor in self.advance(result) }
            }
            try? await Task.sleep(for: .milliseconds(450))
            await self.finish(report)
        }
    }

    private func advance(_ result: CloudEvictionResult) {
        evictedCount += 1
        if result.succeeded { evictedBytes += result.bytes }
    }

    private func finish(_ report: CloudEvictionReport) {
        self.report = report
        evictedCount = evictTotal
        evictedBytes = report.freedBytes
        let removed = Set(report.succeeded.map(\.path))
        var updated = findings
        for p in updated.providers.indices {
            for g in updated.providers[p].groups.indices {
                updated.providers[p].groups[g].items.removeAll { removed.contains($0.path) }
            }
            updated.providers[p].groups.removeAll { $0.items.isEmpty }
        }
        updated.providers.removeAll { $0.groups.isEmpty }
        findings = updated
        selection.keep(only: updated)
        phase = .done
    }

    func showRemaining() {
        guard phase == .done else { return }
        phase = .ready
    }

    // MARK: Finder

    func reveal(_ path: String) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }
}
