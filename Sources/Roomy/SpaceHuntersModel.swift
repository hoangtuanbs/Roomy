import AppKit
import Observation
import RoomyCore

/// State for Space Hunters: four hunts for big, forgotten things (old device backups, old downloads, Mail
/// attachments and similar photos), what is ticked, and moving the ticked items to the Trash.
@MainActor
@Observable
final class SpaceHuntersModel {
    enum Phase: Equatable {
        case idle
        case hunting
        case ready
        case cleaning
        case done
    }

    enum Hunter: String, CaseIterable, Identifiable, Sendable {
        case backups, downloads, mail, photos
        var id: String { rawValue }
    }

    var phase: Phase = .idle
    private(set) var finished: Set<Hunter> = []
    private(set) var backups: [DeviceBackup] = []
    private(set) var backupsNeedAccess = false
    private(set) var downloads: [OldDownload] = []
    private(set) var mail = MailAttachmentsFinder.Findings()
    private(set) var photoGroups: [SimilarPhotoGroup] = []
    /// Where Similar photos looked.
    private(set) var photoScope = ""
    private(set) var photosChecked = 0
    private(set) var photosToCheck = 0
    /// True when there were more pictures than Similar photos compares.
    private(set) var photosCapped = false
    var selected: Set<String> = []
    var expanded: Set<Hunter> = []

    private(set) var cleanTotal = 0
    private(set) var cleanedCount = 0
    private(set) var cleanedBytes: Int64 = 0
    private(set) var report: CleanupReport?

    /// Called with the paths that went to the Trash, so the main scan can drop them.
    @ObservationIgnored var onRemoved: (([String]) -> Void)?
    /// Opens the Full Disk Access guide.
    @ObservationIgnored var onShowAccessHelp: (() -> Void)?
    @ObservationIgnored private var huntTask: Task<Void, Never>?
    let home = NSHomeDirectory()

    var isBusy: Bool { phase == .hunting || phase == .cleaning }

    /// The screen tour logs how long each hunt takes, so slow build machines can be told apart from hangs.
    @ObservationIgnored private let logs = CommandLine.arguments.contains("--tour")
    @ObservationIgnored private var huntStart = Date()

    private func log(_ text: String) {
        guard logs else { return }
        let line = String(format: "hunters: %.1fs ", Date().timeIntervalSince(huntStart)) + text + "\n"
        FileHandle.standardError.write(Data(line.utf8))
    }
    var cleanFraction: Double { cleanTotal == 0 ? 0 : Double(cleanedCount) / Double(cleanTotal) }

    /// How far the hunt has got, from 0 to 1. Similar photos counts by the pictures it has checked.
    var huntFraction: Double {
        var done = Double(finished.count)
        if !finished.contains(.photos) && photosToCheck > 0 {
            done += 0.9 * Double(photosChecked) / Double(photosToCheck)
        }
        return done / Double(Hunter.allCases.count)
    }

    // MARK: Hunting

    func hunt(tree: ScanTree?) {
        guard phase != .cleaning else { return }
        huntTask?.cancel()
        finished = []
        backups = []
        backupsNeedAccess = false
        downloads = []
        mail = MailAttachmentsFinder.Findings()
        photoGroups = []
        photosChecked = 0
        photosToCheck = 0
        photosCapped = false
        selected = []
        report = nil
        phase = .hunting
        huntStart = Date()

        let home = self.home
        let pictures = home + "/Pictures"
        var scanned: [PhotoSource.File]?
        if let tree { scanned = PhotoSource.files(in: tree) }
        let fromScan = scanned
        photoScope = tree?.rootPath ?? pictures

        huntTask = Task {
            await withTaskGroup(of: Void.self) { group in
                group.addTask {
                    let outcome = BackupFinder(homePath: home).find()
                    await self.finishBackups(outcome)
                }
                group.addTask {
                    let found = OldDownloadsFinder(downloadsPath: home + "/Downloads", dates: { SpotlightDates.itemDates($0) }).find()
                    await self.finishDownloads(found)
                }
                group.addTask {
                    let found = MailAttachmentsFinder(homePath: home).find()
                    await self.finishMail(found)
                }
                group.addTask {
                    let groups = await self.findSimilarPhotos(fromScan ?? PhotoSource.files(inFolder: pictures))
                    await self.finishPhotos(groups)
                }
            }
            guard !Task.isCancelled else { return }
            // Let the ring fill before the results appear.
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            expanded = Set(Hunter.allCases.filter { !isEmpty($0) })
            phase = .ready
        }
    }

    func cancel() {
        huntTask?.cancel()
        huntTask = nil
        if phase == .hunting { phase = .idle }
    }

    private func finishBackups(_ outcome: BackupFinder.Outcome) {
        guard phase == .hunting else { return }
        switch outcome {
        case .found(let found):
            backups = found
            selected.formUnion(BackupRules.preselected(found))
        case .noAccess:
            backupsNeedAccess = true
        }
        finished.insert(.backups)
        log("backups done")
    }

    private func finishDownloads(_ found: [OldDownload]) {
        guard phase == .hunting else { return }
        downloads = found
        finished.insert(.downloads)
        log("downloads done, \(found.count) found")
    }

    private func finishMail(_ found: MailAttachmentsFinder.Findings) {
        guard phase == .hunting else { return }
        mail = found
        finished.insert(.mail)
        log("mail done")
    }

    private func finishPhotos(_ groups: [SimilarPhotoGroup]) {
        guard phase == .hunting else { return }
        photoGroups = groups
        finished.insert(.photos)
        log("photos done, \(groups.count) groups")
    }

    private func setPhotoProgress(checked: Int, total: Int) {
        guard phase == .hunting else { return }
        photosChecked = checked
        photosToCheck = total
        log("photos \(checked) of \(total)")
    }

    private func setPhotosCapped(_ capped: Bool) {
        photosCapped = capped
    }

    /// Makes a feature print of each picture, four at a time, and groups the ones that look alike.
    nonisolated private func findSimilarPhotos(_ files: [PhotoSource.File]) async -> [SimilarPhotoGroup] {
        let (chosen, capped) = PhotoSource.capped(files)
        await setPhotosCapped(capped)
        await setPhotoProgress(checked: 0, total: chosen.count)
        guard chosen.count > 1 else { return [] }

        let prints = await withTaskGroup(of: PhotoPrint?.self, returning: [PhotoPrint].self) { group in
            var made: [PhotoPrint] = []
            var next = 0
            while next < min(4, chosen.count) {
                let file = chosen[next]
                next += 1
                group.addTask { await PhotoPrint.makeOffPool(file) }
            }
            var checked = 0
            while let result = await group.next() {
                if Task.isCancelled {
                    group.cancelAll()
                    break
                }
                if let result { made.append(result) }
                checked += 1
                if checked % 10 == 0 || checked == chosen.count {
                    await setPhotoProgress(checked: checked, total: chosen.count)
                }
                if next < chosen.count {
                    let file = chosen[next]
                    next += 1
                    group.addTask { await PhotoPrint.makeOffPool(file) }
                }
            }
            return made
        }
        guard !Task.isCancelled else { return [] }
        let candidates = prints.map(\.candidate)
        return SimilarPhotoGrouper.group(candidates, isCancelled: { Task.isCancelled }) { i, j in
            prints[i].distance(to: prints[j])
        }
    }

    // MARK: What was found

    func isEmpty(_ hunter: Hunter) -> Bool {
        switch hunter {
        case .backups: return backups.isEmpty && !backupsNeedAccess
        case .downloads: return downloads.isEmpty
        case .mail: return mail.storeBytes == 0 && mail.downloads.isEmpty && mail.storeReadable
        case .photos: return photoGroups.isEmpty
        }
    }

    /// The space each hunter found. For Mail this includes the attachments in Mail's store, which are only shown.
    func foundBytes(_ hunter: Hunter) -> Int64 {
        switch hunter {
        case .backups: return backups.reduce(0) { $0 + $1.bytes }
        case .downloads: return downloads.reduce(0) { $0 + $1.bytes }
        case .mail: return mail.storeBytes + mail.downloadBytes
        case .photos: return photoGroups.reduce(0) { $0 + $1.extraBytes }
        }
    }

    var foundBytes: Int64 { Hunter.allCases.reduce(0) { $0 + foundBytes($1) } }

    /// Paths and sizes a hunter may move to the Trash. Mail's store is never here.
    func removable(_ hunter: Hunter) -> [(path: String, bytes: Int64)] {
        switch hunter {
        case .backups: return backups.map { (path: $0.path, bytes: $0.bytes) }
        case .downloads: return downloads.map { (path: $0.path, bytes: $0.bytes) }
        case .mail: return mail.downloads.map { (path: $0.path, bytes: $0.bytes) }
        case .photos: return photoGroups.flatMap { group in group.photos.map { (path: $0.path, bytes: $0.bytes) } }
        }
    }

    func selectedBytes(_ hunter: Hunter) -> Int64 {
        removable(hunter).filter { selected.contains($0.path) }.reduce(0) { $0 + $1.bytes }
    }

    var selectedBytes: Int64 { Hunter.allCases.reduce(0) { $0 + selectedBytes($1) } }
    var selectedCount: Int { Hunter.allCases.reduce(0) { $0 + removable($1).filter { selected.contains($0.path) }.count } }

    func state(_ hunter: Hunter) -> JunkSelection.State {
        let paths = tickable(hunter)
        let count = paths.filter(selected.contains).count
        if count == 0 { return .none }
        return count == paths.count ? .all : .some
    }

    /// What ticking a whole card ticks. For photos that is every picture but the one suggested to keep.
    private func tickable(_ hunter: Hunter) -> [String] {
        if hunter == .photos { return photoGroups.flatMap { $0.others.map(\.path) } }
        return removable(hunter).map(\.path)
    }

    func setAll(_ hunter: Hunter, selected on: Bool) {
        if hunter == .photos {
            // Clear the whole card first, so a picture ticked instead of the suggested one is unticked too.
            selected.subtract(removable(.photos).map(\.path))
        }
        let paths = tickable(hunter)
        if on { selected.formUnion(paths) } else { selected.subtract(paths) }
    }

    /// Ticks or unticks one item. A photo can only be ticked while another picture of its group stays unticked.
    func toggle(_ path: String) {
        if selected.contains(path) {
            selected.remove(path)
        } else if canTick(path) {
            selected.insert(path)
        }
    }

    func canTick(_ path: String) -> Bool {
        guard let group = photoGroups.first(where: { $0.photos.contains { $0.path == path } }) else { return true }
        let left = group.photos.filter { $0.path != path && !selected.contains($0.path) }
        return !left.isEmpty
    }

    func toggleExpanded(_ hunter: Hunter) {
        if expanded.contains(hunter) { expanded.remove(hunter) } else { expanded.insert(hunter) }
    }

    // MARK: Cleaning

    /// Moves the ticked items to the Trash through the safety policy. Items in Mail's store are never included.
    func clean() {
        guard phase == .ready else { return }
        let mailPlaces = MailLocations(homePath: home)
        var sizes: [String: Int64] = [:]
        for hunter in Hunter.allCases {
            for item in removable(hunter) where selected.contains(item.path) {
                guard mailPlaces.classify(item.path) != .store, mailPlaces.classify(item.path) != .downloadsFolder else { continue }
                sizes[item.path] = item.bytes
            }
        }
        // Never every picture of a group.
        for group in photoGroups where group.photos.allSatisfy({ sizes[$0.path] != nil }) {
            sizes[group.suggestedKeep.path] = nil
        }
        guard !sizes.isEmpty else { return }
        let paths = Array(sizes.keys)
        cleanTotal = paths.count
        cleanedCount = 0
        cleanedBytes = 0
        phase = .cleaning

        Task.detached {
            let service = CleanupService()
            let plan = service.plan(paths: paths, sizeOf: { sizes[$0] ?? 0 })
            let report = service.execute(plan) { result in
                Task { @MainActor in self.advance(result) }
            }
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
        let removed = Set(report.succeeded.map(\.path))
        backups.removeAll { removed.contains($0.path) }
        downloads.removeAll { removed.contains($0.path) }
        mail.downloads.removeAll { removed.contains($0.path) }
        photoGroups = photoGroups.compactMap { $0.removing(removed) }
        selected.subtract(removed)
        onRemoved?(Array(removed))
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

    func openFolder(_ path: String) {
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
    }

    func quickLook(_ path: String) {
        QuickLook.shared.show(URL(fileURLWithPath: path))
    }

    func openTrash() {
        NSWorkspace.shared.open(URL(fileURLWithPath: home + "/.Trash"))
    }

    func openFullDiskAccessSettings() {
        NSWorkspace.shared.open(FullDiskAccess.settingsURL)
    }

    func openMail() {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.mail") {
            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
        }
    }
}
