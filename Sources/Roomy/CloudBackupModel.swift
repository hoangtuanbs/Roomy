import AppKit
import Observation
import RoomyCore

/// State for Cloud Backup: finds big files that have not been used for months, lists them for review, moves the
/// ticked ones into a `RoomyDisk Backup` folder in a cloud folder (leaving an alias behind), and later restores them
/// or frees their local copies once they are uploaded. Nothing moves without the review and a confirmation.
@MainActor
@Observable
final class CloudBackupModel {
    enum Phase: Equatable {
        case idle
        case finding
        case ready
        case moving
        case done
    }

    /// Removing the local copies of uploaded files, in the Backed Up tab.
    enum FreePhase: Equatable {
        case list
        case freeing
        case freed
    }

    enum Tab: String, CaseIterable, Identifiable {
        case review, backedUp
        var id: String { rawValue }
    }

    enum Keys {
        static let minimumBytes = "cloudBackup.minimumBytes"
        static let unusedMonths = "cloudBackup.unusedMonths"
        static let destination = "cloudBackup.destination"
        static let leavesAlias = "cloudBackup.leavesAlias"
    }

    var phase: Phase = .idle
    var freePhase: FreePhase = .list
    var tab: Tab = .review
    private(set) var findings = CloudBackupFinder.Findings()
    private(set) var filesChecked = 0
    var selected: Set<String> = []
    /// True while the confirmation is shown. Nothing moves until it is answered with Back Up.
    var isConfirming = false

    // MARK: Settings, kept in the app's settings

    var minimumSize: BackupMinimumSize = BackupMinimumSize(rawValue: Int64(AppEnvironment.defaults.integer(forKey: Keys.minimumBytes))) ?? .standard {
        didSet {
            guard minimumSize != oldValue else { return }
            AppEnvironment.defaults.set(Int(minimumSize.rawValue), forKey: Keys.minimumBytes)
            refreshIfShown()
        }
    }

    var unusedFor: BackupUnusedFor = BackupUnusedFor(rawValue: AppEnvironment.defaults.integer(forKey: Keys.unusedMonths)) ?? .standard {
        didSet {
            guard unusedFor != oldValue else { return }
            AppEnvironment.defaults.set(unusedFor.rawValue, forKey: Keys.unusedMonths)
            refreshIfShown()
        }
    }

    var leavesAlias: Bool = AppEnvironment.defaults.object(forKey: Keys.leavesAlias) as? Bool ?? true {
        didSet { AppEnvironment.defaults.set(leavesAlias, forKey: Keys.leavesAlias) }
    }

    /// The cloud folders found on this Mac, iCloud Drive first.
    private(set) var destinations: [BackupDestination] = []
    /// A folder the person chose inside a cloud folder.
    private(set) var chosenDestination: BackupDestination?
    private(set) var destinationPath: String? = AppEnvironment.defaults.string(forKey: Keys.destination)
    /// Said when a chosen folder would not sync.
    private(set) var destinationWarning: String?

    // MARK: Moving

    private(set) var moveTotal = 0
    private(set) var movedCount = 0
    private(set) var movedBytes: Int64 = 0
    private(set) var report: CloudBackupReport?
    private(set) var movedTo: BackupDestination?

    // MARK: Backed up

    private(set) var records: [BackupRecord] = []
    private(set) var states: [UUID: BackupUploadState] = [:]
    private(set) var restoring: Set<UUID> = []
    /// The last thing worth saying in the Backed Up tab, such as why a restore failed.
    private(set) var notice: String?
    private(set) var freeTotal = 0
    private(set) var freedCount = 0
    private(set) var freeReport: CloudEvictionReport?

    @ObservationIgnored private var task: Task<Void, Never>?
    let home = AppEnvironment.home
    let locations = CloudLocations(homePath: AppEnvironment.home)
    /// The time ages count from. The flow test and the screen tour move it ahead, so files just made count as old.
    @ObservationIgnored var now: () -> Date = { Date() }
    /// Where to look instead of the home folders. The screen tour points it at its sample folder.
    @ObservationIgnored var rootsOverride: [String]?
    /// A smaller minimum than any choice, for the screen tour's small sample files.
    @ObservationIgnored var minimumBytesOverride: Int64?

    var isBusy: Bool { phase == .finding || phase == .moving || freePhase == .freeing }

    var allDestinations: [BackupDestination] {
        destinations + [chosenDestination].compactMap { $0 }.filter { chosen in !destinations.contains(chosen) }
    }

    /// Where files go: the saved choice when it is still there, otherwise the first cloud folder.
    var destination: BackupDestination? {
        allDestinations.first { $0.folderPath == destinationPath } ?? destinations.first
    }

    var destinationTitle: String { destination?.title(locations) ?? String(localized: "the cloud") }

    var items: [BackupCandidate] { findings.items }
    var selectedItems: [BackupCandidate] { items.filter { selected.contains($0.path) } }
    var selectedBytes: Int64 { selectedItems.reduce(0) { $0 + $1.bytes } }
    var moveFraction: Double { moveTotal == 0 ? 0 : Double(movedCount) / Double(moveTotal) }
    var canBackUp: Bool { phase == .ready && !selected.isEmpty && destination != nil }

    var recordsBytes: Int64 { records.reduce(0) { $0 + $1.bytes } }
    var freeable: [BackupRecord] { records.filter { states[$0.id]?.canFree == true } }
    var freeableBytes: Int64 { freeable.reduce(0) { $0 + $1.bytes } }

    // MARK: Finding

    func find() {
        guard phase != .moving else { return }
        task?.cancel()
        refreshDestinations()
        loadRecords()
        findings = CloudBackupFinder.Findings()
        filesChecked = 0
        selected = []
        report = nil
        phase = .finding

        let finder = CloudBackupFinder(homePath: home, roots: rootsOverride, includeHomeFiles: rootsOverride == nil,
                                       minimumBytes: minimumBytesOverride ?? minimumSize.rawValue,
                                       unusedMonths: unusedFor.rawValue, now: now(), policy: AppEnvironment.policy,
                                       providers: locations.providers())
        // Detached, so the walk runs off the main thread and stops when cancelled.
        task = Task.detached(priority: .userInitiated) {
            let found = finder.find { progress in
                Task { @MainActor in self.setProgress(progress) }
            }
            guard !Task.isCancelled else { return }
            // Let the ring settle before the results appear.
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            await self.finishFind(found)
        }
    }

    private func setProgress(_ progress: CloudBackupFinder.Progress) {
        guard phase == .finding else { return }
        filesChecked = progress.filesChecked
    }

    private func finishFind(_ found: CloudBackupFinder.Findings) {
        guard phase == .finding else { return }
        findings = found
        filesChecked = found.filesChecked
        // Everything is ticked; the list is the review, and the button asks again before anything moves.
        selected = Set(found.items.map(\.path))
        phase = .ready
    }

    /// A changed threshold looks again, unless the tool has not been opened.
    private func refreshIfShown() {
        if phase == .ready || phase == .finding || phase == .done { find() }
    }

    func cancel() {
        task?.cancel()
        task = nil
        if phase == .finding { phase = .idle }
    }

    // MARK: Ticking

    func toggle(_ item: BackupCandidate) {
        guard phase == .ready else { return }
        if selected.contains(item.path) { selected.remove(item.path) } else { selected.insert(item.path) }
    }

    func state(of group: BackupFolderGroup) -> JunkSelection.State {
        let count = group.items.filter { selected.contains($0.path) }.count
        if count == 0 { return .none }
        return count == group.items.count ? .all : .some
    }

    func setAll(_ group: BackupFolderGroup, selected on: Bool) {
        guard phase == .ready else { return }
        let paths = group.items.map(\.path)
        if on { selected.formUnion(paths) } else { selected.subtract(paths) }
    }

    func selectAll(_ on: Bool) {
        guard phase == .ready else { return }
        selected = on ? Set(items.map(\.path)) : []
    }

    // MARK: Destination

    func refreshDestinations() {
        let providers = locations.providers()
        destinations = CloudBackupPlaces.destinations(providers, locations: locations)
        if let saved = destinationPath, !destinations.contains(where: { $0.folderPath == saved }) {
            chosenDestination = CloudBackupPlaces.destination(forChosen: saved, providers: providers, locations: locations)
                .flatMap { isFolder($0.folderPath) ? $0 : nil }
        }
    }

    func choose(_ destination: BackupDestination) {
        destinationPath = destination.folderPath
        destinationWarning = nil
        AppEnvironment.defaults.set(destination.folderPath, forKey: Keys.destination)
    }

    /// Asks for a folder inside a cloud folder.
    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = String(localized: "Back Up Here")
        panel.message = String(localized: "Choose a folder inside iCloud Drive, Dropbox, OneDrive or Google Drive.")
        panel.directoryURL = URL(fileURLWithPath: destination?.folderPath ?? locations.cloudStorage)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        use(folder: url.path)
    }

    /// Uses a chosen folder when it is inside a cloud folder, and warns otherwise.
    func use(folder path: String) {
        refreshDestinations()
        guard let chosen = CloudBackupPlaces.destination(forChosen: path, providers: locations.providers(), locations: locations) else {
            destinationWarning = String(localized: "That folder is not inside iCloud Drive, Dropbox, OneDrive or Google Drive, so files there would not sync. Choose a folder inside one of them.")
            return
        }
        if !destinations.contains(chosen) { chosenDestination = chosen }
        choose(chosen)
    }

    // MARK: Moving

    func askToBackUp() {
        guard canBackUp else { return }
        isConfirming = true
    }

    private func service() -> CloudBackupService {
        CloudBackupService(homePath: home, policy: AppEnvironment.policy, providers: locations.providers(),
                           manifest: AppEnvironment.cloudBackupManifest, leavesAlias: leavesAlias)
    }

    /// Moves the ticked files, one at a time so each can be seen leaving the list. Each is checked again first.
    func backUp() {
        isConfirming = false
        guard canBackUp, let destination else { return }
        let items = selectedItems
        movedTo = destination
        moveTotal = items.count
        movedCount = 0
        movedBytes = 0
        report = nil
        phase = .moving

        let service = self.service()
        let pause = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 20 : 220
        task = Task {
            var results: [CloudBackupResult] = []
            for item in items {
                let result = await Task.detached { service.backUp(item, to: destination) }.value
                results.append(result)
                self.advance(result)
                try? await Task.sleep(for: .milliseconds(pause))
            }
            try? await Task.sleep(for: .milliseconds(400))
            self.finishMove(CloudBackupReport(results: results))
        }
    }

    private func advance(_ result: CloudBackupResult) {
        movedCount += 1
        guard result.succeeded else { return }
        movedBytes += result.bytes
        findings = findings.removing([result.path])
        selected.remove(result.path)
    }

    private func finishMove(_ report: CloudBackupReport) {
        self.report = report
        movedCount = moveTotal
        loadRecords()
        phase = .done
    }

    /// Back to the list after a move, with what is left.
    func showRemaining() {
        guard phase == .done else { return }
        phase = .ready
    }

    func showBackedUp() {
        if phase == .done { phase = .ready }
        loadRecords()
        tab = .backedUp
    }

    // MARK: Backed up

    func loadRecords() {
        records = AppEnvironment.cloudBackupManifest.load().sorted { $0.date > $1.date }
        refreshStates()
    }

    func refreshStates() {
        let service = self.service()
        states = Dictionary(uniqueKeysWithValues: records.map { ($0.id, service.state(of: $0)) })
    }

    /// Moves a file back to its old place, replacing the alias left there.
    func restore(_ record: BackupRecord) {
        guard !restoring.contains(record.id) else { return }
        restoring.insert(record.id)
        notice = nil
        let service = self.service()
        Task {
            let result = await Task.detached { service.restore(record) }.value
            self.restoring.remove(record.id)
            if let error = result.error {
                self.notice = String(format: String(localized: "%@ was not restored: %@"), record.name, error)
            } else if let place = result.restoredTo, place != record.originalPath {
                self.notice = String(format: String(localized: "%@ was put back as %@, because a file with its name is there now."),
                                     record.name, (place as NSString).lastPathComponent)
            }
            self.loadRecords()
        }
    }

    /// Drops a record whose file is no longer in the cloud folder.
    func forget(_ record: BackupRecord) {
        service().forget(record)
        loadRecords()
    }

    /// Removes the local copies of the uploaded backed-up files. They stay in the cloud.
    func freeLocalCopies() {
        let records = freeable
        guard !records.isEmpty, freePhase == .list else { return }
        freeTotal = records.count
        freedCount = 0
        freeReport = nil
        freePhase = .freeing
        let service = self.service()
        Task.detached {
            let report = service.freeLocalCopies(records) { _ in
                Task { @MainActor in self.freedCount += 1 }
            }
            try? await Task.sleep(for: .milliseconds(450))
            await self.finishFree(report)
        }
    }

    private func finishFree(_ report: CloudEvictionReport) {
        freeReport = report
        freedCount = freeTotal
        refreshStates()
        freePhase = .freed
    }

    func showList() {
        freePhase = .list
        refreshStates()
    }

    // MARK: Finder

    func reveal(_ path: String) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    func quickLook(_ path: String) {
        QuickLook.shared.show(URL(fileURLWithPath: path))
    }

    /// "Last used 14 months ago", "Last used 2 years ago".
    func lastUsedText(_ date: Date) -> String {
        let months = BackupRule.monthsSince(date, now: now())
        let format = String(localized: "Last used %lld %@ ago")
        if months >= 24 { return String(format: format, months / 12, Plural.word(months / 12, "year", "years")) }
        if months >= 1 { return String(format: format, months, Plural.word(months, "month", "months")) }
        let days = max(1, Int(now().timeIntervalSince(date) / 86_400))
        return String(format: format, days, Plural.word(days, "day", "days"))
    }
}

private func isFolder(_ path: String) -> Bool {
    var isDirectory: ObjCBool = false
    return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
}
