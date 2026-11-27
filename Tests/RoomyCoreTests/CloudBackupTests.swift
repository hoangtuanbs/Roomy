import Foundation
import XCTest
@testable import RoomyCore

/// Cloud Backup: thresholds, the last-used rule, the places it never looks, destinations and name clashes, moving
/// with an alias and a manifest, the checks made again just before a move, and restoring. Everything happens in a
/// temporary folder that stands in for the home folder, with made-up dates and cloud status.
final class CloudBackupTests: XCTestCase {
    private var home = ""
    private let fm = FileManager.default
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let big = 200_000
    private let minimum: Int64 = 100_000

    override func setUpWithError() throws {
        let base = fm.temporaryDirectory.appendingPathComponent("RoomyBackup-\(UUID().uuidString)")
        try fm.createDirectory(at: base, withIntermediateDirectories: true)
        home = DiskScanner.standardize(base.path)
        try fm.createDirectory(atPath: drive, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? fm.removeItem(atPath: home)
    }

    private var locations: CloudLocations { CloudLocations(homePath: home) }
    private var drive: String { home + "/Library/Mobile Documents/com~apple~CloudDocs" }
    private var manifest: BackupManifest { BackupManifest(fileURL: URL(fileURLWithPath: home + "/state/cloud-backup.json")) }

    @discardableResult
    private func file(_ relative: String, bytes: Int? = nil) throws -> String {
        let path = home + "/" + relative
        try fm.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try Data(repeating: 7, count: bytes ?? big).write(to: URL(fileURLWithPath: path))
        return path
    }

    private func monthsAgo(_ months: Int) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar.date(byAdding: .month, value: -months, to: now)!
    }

    private struct FakeDates: BackupDateReading {
        var byName: [String: BackupFileDates] = [:]
        var fallback: BackupFileDates
        func dates(of path: String) -> BackupFileDates { byName[(path as NSString).lastPathComponent] ?? fallback }
    }

    private struct FakeStatus: CloudStatusReading {
        var status = CloudStatus()
        func status(of path: String) -> CloudStatus { status }
    }

    private struct FailingAliases: BackupAliasMaking {
        func makeAlias(at path: String, to target: String) throws { throw CocoaError(.fileWriteNoPermission) }
        func isAlias(_ path: String) -> Bool { false }
    }

    private func finder(dates: [String: BackupFileDates] = [:], fallbackMonths: Int = 12,
                        policy: SafetyPolicy? = nil, months: Int = 6) -> CloudBackupFinder {
        CloudBackupFinder(homePath: home, minimumBytes: minimum, unusedMonths: months, now: now, policy: policy,
                          dates: FakeDates(byName: dates, fallback: BackupFileDates(modified: monthsAgo(fallbackMonths))))
    }

    private func service(alias: Bool = true, aliases: any BackupAliasMaking = FinderAliases(),
                         policy: SafetyPolicy? = nil) -> CloudBackupService {
        CloudBackupService(homePath: home, policy: policy ?? SafetyPolicy(homePath: home), providers: locations.providers(),
                           manifest: manifest, leavesAlias: alias, aliases: aliases, now: { [now] in now })
    }

    private var iCloud: BackupDestination {
        CloudBackupPlaces.destinations(locations.providers(), locations: locations)[0]
    }

    private func candidate(_ path: String) throws -> BackupCandidate {
        let entry = try XCTUnwrap(DirectoryReader.entry(atPath: path))
        return BackupCandidate(path: path, name: entry.name, bytes: entry.allocated, length: entry.length, lastUsed: monthsAgo(12))
    }

    // MARK: Thresholds and the rule

    func testThresholdChoices() {
        XCTAssertEqual(BackupMinimumSize.allCases.map(\.rawValue), [100_000_000, 250_000_000, 500_000_000, 1_000_000_000, 5_000_000_000])
        XCTAssertEqual(BackupMinimumSize.standard, .mb500)
        XCTAssertEqual(BackupMinimumSize.gb1.label, "1 GB")
        XCTAssertEqual(BackupMinimumSize.mb250.label, "250 MB")
        XCTAssertEqual(BackupUnusedFor.allCases.map(\.rawValue), [3, 6, 12, 24])
        XCTAssertEqual(BackupUnusedFor.standard, .months6)
    }

    func testLastUsedIsTheLatestKnownDate() {
        let dates = BackupFileDates(lastUsed: monthsAgo(20), accessed: monthsAgo(9), modified: monthsAgo(30), created: monthsAgo(40))
        XCTAssertEqual(BackupRule.lastUsed(dates), monthsAgo(9))
        XCTAssertTrue(BackupRule.isUnused(dates, now: now, months: 6))
        XCTAssertFalse(BackupRule.isUnused(dates, now: now, months: 12))
        XCTAssertNil(BackupRule.lastUsed(BackupFileDates()))
        XCTAssertFalse(BackupRule.isUnused(BackupFileDates(), now: now, months: 3), "a file with no dates is never old")
    }

    func testAnyRecentDateKeepsAFileInUse() {
        let old = monthsAgo(24)
        // An old access date alone does not make a recently opened file old, and the other way round.
        XCTAssertFalse(BackupRule.isUnused(BackupFileDates(lastUsed: monthsAgo(1), accessed: old, modified: old, created: old), now: now, months: 6))
        XCTAssertFalse(BackupRule.isUnused(BackupFileDates(lastUsed: old, accessed: monthsAgo(1), modified: old, created: old), now: now, months: 6))
        XCTAssertFalse(BackupRule.isUnused(BackupFileDates(lastUsed: old, accessed: old, modified: monthsAgo(2), created: old), now: now, months: 6))
        XCTAssertFalse(BackupRule.isUnused(BackupFileDates(lastUsed: old, accessed: old, modified: old, created: monthsAgo(2)), now: now, months: 6))
        XCTAssertTrue(BackupRule.isUnused(BackupFileDates(lastUsed: old, accessed: old, modified: old, created: old), now: now, months: 6))
        XCTAssertEqual(BackupRule.monthsSince(monthsAgo(14), now: now), 14)
    }

    // MARK: Finding

    func testFindsOnlyBigFilesUnusedForLongEnough() throws {
        let old = try file("Movies/old.mov")
        try file("Movies/small.mov", bytes: 10_000)
        try file("Movies/recent.mov")
        let top = try file("archive.zip")
        let found = finder(dates: ["recent.mov": BackupFileDates(modified: monthsAgo(2))]).find()
        XCTAssertEqual(Set(found.items.map(\.path)), [old, top])
        XCTAssertEqual(found.items.first { $0.path == old }?.lastUsed, monthsAgo(12))

        // A longer threshold leaves out files that are only a year old.
        XCTAssertTrue(finder(months: 24).find().items.isEmpty)
        // A bigger minimum leaves out everything.
        var bigger = finder()
        bigger.minimumBytes = 10_000_000
        XCTAssertTrue(bigger.find().items.isEmpty)
    }

    func testGroupsByFolderLargestFirst() throws {
        try file("Documents/Renders/a.mov", bytes: 300_000)
        try file("Documents/Renders/b.mov", bytes: 200_000)
        try file("Downloads/c.dmg", bytes: 150_000)
        try file("top.iso", bytes: 120_000)
        let groups = finder().find().groups
        XCTAssertEqual(groups.map(\.name), ["Documents/Renders", "Downloads", CloudBackupFinder.homeName])
        XCTAssertEqual(groups[0].items.map(\.name), ["a.mov", "b.mov"])
        XCTAssertEqual(groups[2].path, home)
    }

    func testSkipsLibraryHiddenPackagesCloudFoldersAndLinks() throws {
        let kept = try file("Documents/keep.mov")
        try file("Library/Caches/huge.bin")
        try file("Documents/.hidden.mov")
        try file("Documents/.secret/inside.mov")
        try file("Pictures/Photos Library.photoslibrary/originals/a.heic")
        try file("Downloads/Tool.app/Contents/Resources/big.dat")
        try file("Movies/Project.fcpbundle/media.mov")
        try file("Documents/Report.pages/Data/movie.mov")
        try file("Library/Mobile Documents/com~apple~CloudDocs/Docs/cloud.mov")
        try file("Library/CloudStorage/Dropbox/drop.mov")
        // Links to files and folders, and a file with two hard links.
        try fm.createSymbolicLink(atPath: home + "/Documents/link.mov", withDestinationPath: kept)
        try fm.createSymbolicLink(atPath: home + "/Documents/Linked", withDestinationPath: home + "/Library/Caches")
        try file("Downloads/linked-twice.mov")
        try fm.linkItem(atPath: home + "/Downloads/linked-twice.mov", toPath: home + "/Downloads/other-name.mov")

        XCTAssertEqual(finder().find().items.map(\.path), [kept])
    }

    func testSkipsWhatTheSafetyRulesProtect() throws {
        let inside = try file("Documents/inside.mov")
        try file("Downloads/outside.mov")
        // A confined policy blocks everything outside its folder, as in the flow test.
        let confined = SafetyPolicy(homePath: home, confinedTo: home + "/Documents")
        XCTAssertEqual(finder(policy: confined).find().items.map(\.path), [inside])
    }

    func testStopsAtTheFileLimit() throws {
        for i in 0..<5 { try file("Documents/f\(i).mov") }
        var limited = finder()
        limited.fileLimit = 3
        let found = limited.find()
        XCTAssertTrue(found.capped)
        XCTAssertLessThanOrEqual(found.items.count, 3)
    }

    // MARK: Destinations

    func testDestinationsPutICloudDriveFirst() throws {
        try fm.createDirectory(atPath: home + "/Library/CloudStorage/Dropbox", withIntermediateDirectories: true)
        try fm.createDirectory(atPath: home + "/Library/CloudStorage/GoogleDrive-anna@example.com", withIntermediateDirectories: true)
        let destinations = CloudBackupPlaces.destinations(locations.providers(), locations: locations)
        XCTAssertEqual(destinations.map(\.provider.kind), [.iCloudDrive, .dropbox, .googleDrive])
        XCTAssertEqual(destinations[0].folderPath, drive)
        XCTAssertEqual(destinations[0].backupFolder, drive + "/RoomyDisk Backup")
        XCTAssertEqual(destinations[1].folderPath, home + "/Library/CloudStorage/Dropbox")
        XCTAssertEqual(destinations[0].title(locations), "iCloud Drive")
    }

    func testAChosenFolderMustBeInsideACloudFolder() throws {
        try fm.createDirectory(atPath: home + "/Library/CloudStorage/Dropbox/Archive", withIntermediateDirectories: true)
        let providers = locations.providers()
        let chosen = CloudBackupPlaces.destination(forChosen: home + "/Library/CloudStorage/Dropbox/Archive", providers: providers, locations: locations)
        XCTAssertEqual(chosen?.provider.kind, .dropbox)
        XCTAssertEqual(chosen?.folderPath, home + "/Library/CloudStorage/Dropbox/Archive")
        XCTAssertEqual(chosen?.title(locations), "Dropbox › Archive")
        XCTAssertEqual(CloudBackupPlaces.destination(forChosen: home + "/Library/CloudStorage/Dropbox", providers: providers, locations: locations)?.provider.kind, .dropbox)
        XCTAssertEqual(CloudBackupPlaces.destination(forChosen: home + "/Library/Mobile Documents", providers: providers, locations: locations)?.folderPath, drive)
        XCTAssertEqual(CloudBackupPlaces.destination(forChosen: drive + "/RoomyDisk Backup/Movies", providers: providers, locations: locations)?.folderPath, drive)
        XCTAssertNil(CloudBackupPlaces.destination(forChosen: home + "/Documents", providers: providers, locations: locations))
        XCTAssertNil(CloudBackupPlaces.destination(forChosen: home + "/Library/CloudStorage/DropboxOld", providers: providers, locations: locations))
    }

    func testTargetKeepsThePathFromHomeAndNeverClashes() throws {
        let target = CloudBackupPlaces.target(for: home + "/Movies/Trips/a.mov", homePath: home, in: iCloud)
        XCTAssertEqual(target, drive + "/RoomyDisk Backup/Movies/Trips/a.mov")
        XCTAssertEqual(CloudBackupPlaces.unclashed(target), target)
        let taken: Set<String> = ["/x/a.mov", "/x/a 2.mov", "/x/notes"]
        XCTAssertEqual(CloudBackupPlaces.unclashed("/x/a.mov", exists: taken.contains), "/x/a 3.mov")
        XCTAssertEqual(CloudBackupPlaces.unclashed("/x/notes", exists: taken.contains), "/x/notes 2")
    }

    // MARK: Moving

    func testBackUpMovesTheFileLeavesAnAliasAndRecordsIt() throws {
        let path = try file("Movies/Trips/a.mov")
        let item = try candidate(path)
        let result = service().backUp(item, to: iCloud)
        XCTAssertNil(result.error)
        let target = drive + "/RoomyDisk Backup/Movies/Trips/a.mov"
        XCTAssertEqual(DirectoryReader.entry(atPath: target)?.length, Int64(big))
        XCTAssertTrue(FinderAliases().isAlias(path), "an alias is left in the old place")
        XCTAssertEqual(try URL(resolvingAliasFileAt: URL(fileURLWithPath: path)).standardizedFileURL.resolvingSymlinksInPath().path,
                       URL(fileURLWithPath: target).resolvingSymlinksInPath().path)

        let records = manifest.load()
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records[0].originalPath, path)
        XCTAssertEqual(records[0].destinationPath, target)
        XCTAssertEqual(records[0].bytes, item.bytes)
        XCTAssertEqual(records[0].date, now)
        XCTAssertEqual(records[0].provider, "iCloud Drive")
        XCTAssertEqual(records[0].aliasPath, path)
        XCTAssertEqual(result.record, records[0])
    }

    func testBackUpWithoutAliasAndWithANameClash() throws {
        let path = try file("Movies/a.mov")
        let existing = try file("Library/Mobile Documents/com~apple~CloudDocs/RoomyDisk Backup/Movies/a.mov", bytes: 5)
        let result = service(alias: false).backUp(try candidate(path), to: iCloud)
        XCTAssertNil(result.error)
        XCTAssertNil(DirectoryReader.entry(atPath: path), "no alias when it is turned off")
        XCTAssertEqual(DirectoryReader.entry(atPath: existing)?.length, 5, "the file already there was not overwritten")
        XCTAssertEqual(result.record?.destinationPath, drive + "/RoomyDisk Backup/Movies/a 2.mov")
        XCTAssertNil(result.record?.aliasPath)
    }

    func testAFailedAliasStillMovesTheFile() throws {
        let path = try file("Movies/a.mov")
        let result = service(aliases: FailingAliases()).backUp(try candidate(path), to: iCloud)
        XCTAssertNil(result.error)
        XCTAssertNotNil(result.note)
        XCTAssertNil(manifest.load().first?.aliasPath)
    }

    func testChecksEachFileAgainJustBeforeMoving() throws {
        let path = try file("Movies/a.mov")
        let item = try candidate(path)

        // Changed since it was found.
        try Data(repeating: 1, count: big + 10).write(to: URL(fileURLWithPath: path))
        XCTAssertNotNil(service().backUp(item, to: iCloud).error)
        XCTAssertEqual(DirectoryReader.entry(atPath: path)?.length, Int64(big + 10))

        // Gone.
        try fm.removeItem(atPath: path)
        XCTAssertNotNil(service().backUp(item, to: iCloud).error)

        // Blocked by the safety rules.
        try file("Movies/a.mov")
        let blocked = SafetyPolicy(homePath: home, confinedTo: home + "/Documents")
        XCTAssertEqual(service(policy: blocked).backUp(item, to: iCloud).error, SafetyPolicy.outsideConfinement)
        XCTAssertNotNil(DirectoryReader.entry(atPath: path))

        // A destination that is not a cloud folder.
        try fm.createDirectory(atPath: home + "/NotCloud", withIntermediateDirectories: true)
        let fake = BackupDestination(provider: iCloud.provider, folderPath: home + "/NotCloud")
        XCTAssertNotNil(service().backUp(item, to: fake).error)

        // Replaced by a link.
        try fm.removeItem(atPath: path)
        try fm.createSymbolicLink(atPath: path, withDestinationPath: try file("Documents/real.mov"))
        XCTAssertNotNil(service().backUp(item, to: iCloud).error)
        XCTAssertTrue(manifest.load().isEmpty, "nothing was recorded")
        XCTAssertNil(DirectoryReader.entry(atPath: drive + "/RoomyDisk Backup/Movies/a.mov"))
    }

    func testDoesNotMoveFilesAlreadyInACloudFolder() throws {
        let path = try file("Library/Mobile Documents/com~apple~CloudDocs/Docs/a.mov")
        let policy = SafetyPolicy(homePath: home + "/elsewhere")
        XCTAssertNotNil(service(policy: policy).backUp(try candidate(path), to: iCloud).error)
        XCTAssertNotNil(DirectoryReader.entry(atPath: path))
    }

    // MARK: Manifest

    func testManifestRoundTrip() throws {
        XCTAssertTrue(manifest.load().isEmpty)
        let record = BackupRecord(originalPath: "/a", destinationPath: "/b", bytes: 3, length: 2, date: now,
                                  provider: "Dropbox", aliasPath: "/a")
        try manifest.save([record])
        XCTAssertEqual(manifest.load(), [record])
        let text = try String(contentsOf: manifest.fileURL, encoding: .utf8)
        XCTAssertTrue(text.contains("\"originalPath\""))
    }

    // MARK: Restoring

    func testRestoreMovesTheFileBackAndRemovesTheAlias() throws {
        let path = try file("Movies/Trips/a.mov")
        let backup = service()
        let record = try XCTUnwrap(backup.backUp(try candidate(path), to: iCloud).record)
        let restored = backup.restore(record)
        XCTAssertNil(restored.error)
        XCTAssertEqual(restored.restoredTo, path)
        XCTAssertFalse(FinderAliases().isAlias(path))
        XCTAssertEqual(DirectoryReader.entry(atPath: path)?.length, Int64(big))
        XCTAssertNil(DirectoryReader.entry(atPath: record.destinationPath))
        XCTAssertTrue(manifest.load().isEmpty)
    }

    func testRestoreNextToARealFileThatTookItsPlace() throws {
        let path = try file("Movies/a.mov")
        let backup = service(alias: false)
        let record = try XCTUnwrap(backup.backUp(try candidate(path), to: iCloud).record)
        try file("Movies/a.mov", bytes: 9)
        let restored = backup.restore(record)
        XCTAssertEqual(restored.restoredTo, home + "/Movies/a 2.mov")
        XCTAssertEqual(DirectoryReader.entry(atPath: path)?.length, 9, "the new file was not touched")
    }

    func testRestoreRefusesMissingFilesAndPathsOutsideCloudFolders() throws {
        let gone = BackupRecord(originalPath: home + "/Movies/a.mov", destinationPath: drive + "/RoomyDisk Backup/Movies/a.mov",
                                bytes: 1, length: 1, date: now, provider: "iCloud Drive")
        XCTAssertNotNil(service().restore(gone).error)
        let elsewhere = try file("Documents/b.mov")
        let outside = BackupRecord(originalPath: home + "/Movies/b.mov", destinationPath: elsewhere, bytes: 1, length: 1,
                                   date: now, provider: "iCloud Drive")
        XCTAssertNotNil(service().restore(outside).error)
        XCTAssertNotNil(DirectoryReader.entry(atPath: elsewhere), "a file outside the cloud folders is never moved")
    }

    // MARK: Upload state

    func testUploadStates() throws {
        XCTAssertEqual(BackupUploadState.of(CloudStatus()), .notSyncing)
        let uploaded = CloudStatus(isCloudItem: true, download: .current, isUploaded: true, isUploading: false, hasConflicts: false)
        XCTAssertEqual(BackupUploadState.of(uploaded), .uploaded)
        XCTAssertTrue(BackupUploadState.uploaded.canFree)
        var status = uploaded
        status.isUploading = true
        status.isUploaded = false
        XCTAssertEqual(BackupUploadState.of(status), .uploading)
        status.isUploading = false
        XCTAssertEqual(BackupUploadState.of(status), .waiting)
        status.hasConflicts = true
        XCTAssertEqual(BackupUploadState.of(status), .conflicted)
        status.download = .notDownloaded
        XCTAssertEqual(BackupUploadState.of(status), .cloudOnly)

        let path = try file("Movies/a.mov")
        let record = try XCTUnwrap(service().backUp(try candidate(path), to: iCloud).record)
        XCTAssertEqual(service().state(of: record), .notSyncing)
        try fm.removeItem(atPath: record.destinationPath)
        XCTAssertEqual(service().state(of: record), .missing)
    }

    func testFreeingLocalCopiesOnlyEvictsUploadedFiles() throws {
        final class Evictor: CloudEvicting, @unchecked Sendable {
            var paths: [String] = []
            func evict(_ path: String) throws { paths.append(path) }
        }
        let path = try file("Movies/a.mov")
        let record = try XCTUnwrap(service().backUp(try candidate(path), to: iCloud).record)
        let evictor = Evictor()
        var backup = service()
        backup.status = FakeStatus(status: CloudStatus(isCloudItem: true, download: .current, isUploaded: false, isUploading: true))
        XCTAssertEqual(backup.freeLocalCopies([record], evictor: evictor).freedBytes, 0)
        XCTAssertTrue(evictor.paths.isEmpty)
        backup.status = FakeStatus(status: CloudStatus(isCloudItem: true, download: .current, isUploaded: true, isUploading: false, hasConflicts: false))
        XCTAssertEqual(backup.freeLocalCopies([record], evictor: evictor).freedBytes, record.bytes)
        XCTAssertEqual(evictor.paths, [record.destinationPath])
    }
}
