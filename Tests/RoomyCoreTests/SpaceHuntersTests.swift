import XCTest
@testable import RoomyCore

/// Space Hunters: backups, old downloads, Mail attachments and similar photos. Everything runs in a temporary
/// folder that stands in for the home folder.
final class SpaceHuntersTests: XCTestCase {
    private var home = ""
    private let now = Date()
    private let fm = FileManager.default
    private let day: TimeInterval = 86_400

    override func setUpWithError() throws {
        let base = fm.temporaryDirectory.appendingPathComponent("RoomyHunters-\(UUID().uuidString)")
        try fm.createDirectory(at: base, withIntermediateDirectories: true)
        home = DiskScanner.standardize(base.path)
    }

    override func tearDownWithError() throws {
        try? fm.removeItem(atPath: home)
    }

    @discardableResult
    private func file(_ relative: String, bytes: Int = 20_000) throws -> String {
        let path = home + "/" + relative
        try fm.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try Data(repeating: 7, count: bytes).write(to: URL(fileURLWithPath: path))
        return path
    }

    private func age(_ relatives: [String], days: Double) throws {
        let date = now.addingTimeInterval(-days * day)
        for relative in relatives {
            try fm.setAttributes([.modificationDate: date], ofItemAtPath: home + "/" + relative)
        }
    }

    private func plist(_ object: [String: Any]) throws -> Data {
        try PropertyListSerialization.data(fromPropertyList: object, format: .xml, options: 0)
    }

    // MARK: Backups

    func testParsesInfoAndManifest() throws {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let info = try plist([
            "Device Name": "Anna's iPhone", "Product Type": "iPhone15,2", "Product Version": "17.5",
            "Last Backup Date": date, "Target Identifier": "abc123",
        ])
        let manifest = try plist(["IsEncrypted": true, "Lockdown": ["DeviceName": "Other"]])
        let parsed = BackupInfo.parse(info: info, manifest: manifest)
        XCTAssertEqual(parsed.deviceName, "Anna's iPhone")
        XCTAssertEqual(parsed.productType, "iPhone15,2")
        XCTAssertEqual(parsed.osVersion, "17.5")
        XCTAssertEqual(parsed.lastBackup, date)
        XCTAssertEqual(parsed.isEncrypted, true)
        XCTAssertEqual(parsed.deviceID, "abc123")
    }

    func testParsingToleratesMissingAndOddValues() throws {
        XCTAssertEqual(BackupInfo.parse(info: nil, manifest: nil), BackupInfo())
        XCTAssertEqual(BackupInfo.parse(info: Data("not a plist".utf8), manifest: Data()), BackupInfo())

        let info = try plist(["Device Name": 42, "Product Version": "  ", "Last Backup Date": "2023-05-01T10:00:00Z"])
        let manifest = try plist(["IsEncrypted": "YES", "Lockdown": ["DeviceName": "iPad", "ProductType": "iPad13,1",
                                                                     "UniqueDeviceID": "u1"]])
        let parsed = BackupInfo.parse(info: info, manifest: manifest)
        XCTAssertEqual(parsed.deviceName, "iPad", "a name that is not text is skipped")
        XCTAssertNil(parsed.osVersion, "blank text is skipped")
        XCTAssertEqual(parsed.productType, "iPad13,1")
        XCTAssertEqual(parsed.lastBackup, ISO8601DateFormatter().date(from: "2023-05-01T10:00:00Z"))
        XCTAssertEqual(parsed.isEncrypted, true)
        XCTAssertEqual(parsed.deviceID, "u1")
    }

    private func backup(_ name: String, device: String, daysAgo: Double) -> DeviceBackup {
        DeviceBackup(path: "/b/" + name, info: BackupInfo(deviceName: device, lastBackup: now.addingTimeInterval(-daysAgo * day),
                                                         deviceID: device),
                     folderModified: now, bytes: 1_000)
    }

    func testOnlyOldBackupsThatAreNotTheNewestStartTicked() {
        let backups = [
            backup("phone-new", device: "phone", daysAgo: 400),
            backup("phone-old", device: "phone", daysAgo: 500),
            backup("phone-recent-old", device: "phone", daysAgo: 410),
            backup("ipad-only", device: "ipad", daysAgo: 900),
            backup("watch-new", device: "watch", daysAgo: 1),
            backup("watch-older", device: "watch", daysAgo: 30),
        ]
        XCTAssertEqual(BackupRules.newestPerDevice(backups), ["/b/phone-new", "/b/ipad-only", "/b/watch-new"])
        XCTAssertEqual(BackupRules.preselected(backups, now: now), ["/b/phone-old", "/b/phone-recent-old"],
                       "the newest backup of a device and backups younger than 90 days are never ticked")
    }

    func testBackupFinderReadsFolders() throws {
        let folder = BackupFinder.backupFolder(homePath: home)
        XCTAssertEqual(BackupFinder(homePath: home).find(), .found([]), "no backup folder means no backups")

        try file("Library/Application Support/MobileSync/Backup/00008030-AAA/Manifest.db", bytes: 50_000)
        try plist(["Device Name": "Phone", "Last Backup Date": now.addingTimeInterval(day)]).write(
            to: URL(fileURLWithPath: folder + "/00008030-AAA/Info.plist"))
        try file("Library/Application Support/MobileSync/Backup/00008030-BBB/Manifest.db")
        try file("Library/Application Support/MobileSync/Backup/.DS_Store")

        guard case .found(let backups) = BackupFinder(homePath: home).find() else { return XCTFail("expected backups") }
        XCTAssertEqual(backups.map(\.folderName), ["00008030-AAA", "00008030-BBB"])
        XCTAssertEqual(backups[0].deviceName, "Phone")
        XCTAssertEqual(backups[1].deviceName, "Unknown device")
        XCTAssertGreaterThan(backups[0].bytes, 50_000)
        XCTAssertEqual(backups[1].deviceKey, "00008030")
    }

    // MARK: Old downloads

    func testOldDownloadRule() {
        let old = now.addingTimeInterval(-100 * day)
        let recent = now.addingTimeInterval(-5 * day)
        XCTAssertTrue(OldDownloadRule.isOld(ItemDates(modified: old), now: now))
        XCTAssertFalse(OldDownloadRule.isOld(ItemDates(modified: recent), now: now))
        XCTAssertFalse(OldDownloadRule.isOld(ItemDates(lastUsed: recent, modified: old), now: now),
                       "opened recently")
        XCTAssertFalse(OldDownloadRule.isOld(ItemDates(added: recent, modified: old), now: now),
                       "downloaded recently, even though the server's date is old")
        XCTAssertFalse(OldDownloadRule.isOld(ItemDates(modified: old, accessed: recent), now: now),
                       "without Spotlight, a recent access counts")
        XCTAssertTrue(OldDownloadRule.isOld(ItemDates(lastUsed: old, modified: old, accessed: recent), now: now),
                      "with Spotlight, the access date is ignored")
        XCTAssertFalse(OldDownloadRule.isOld(ItemDates(), now: now), "no known date is not old")
        XCTAssertTrue(OldDownloadRule.isOld(ItemDates(modified: now.addingTimeInterval(-90 * day)), now: now))
    }

    func testOldDownloadsFinder() throws {
        try file("Downloads/big-old.zip", bytes: 300_000)
        try file("Downloads/small-old.pdf", bytes: 30_000)
        try file("Downloads/new.dmg", bytes: 500_000)
        try file("Downloads/used.mov", bytes: 400_000)
        try file("Downloads/project/a.txt")
        try file("Downloads/project/b.txt")
        try file("Downloads/fresh-folder/old.txt")
        try file("Downloads/fresh-folder/new.txt")
        try file("Downloads/.hidden", bytes: 900_000)
        try age(["Downloads/big-old.zip", "Downloads/small-old.pdf", "Downloads/used.mov", "Downloads/.hidden",
                 "Downloads/project/a.txt", "Downloads/project/b.txt", "Downloads/project",
                 "Downloads/fresh-folder/old.txt", "Downloads/fresh-folder"], days: 200)
        try age(["Downloads/new.dmg"], days: 10)
        let usedPath = home + "/Downloads/used.mov"
        let recent = now.addingTimeInterval(-3 * day)

        let finder = OldDownloadsFinder(downloadsPath: home + "/Downloads", now: now, policy: SafetyPolicy(homePath: home),
                                        dates: { $0 == usedPath ? ItemDates(lastUsed: recent) : ItemDates() })
        let found = finder.find()
        XCTAssertEqual(found.map(\.name), ["big-old.zip", "project", "small-old.pdf"],
                       "largest first; recent, opened and hidden items and folders with recent files are left out")
        XCTAssertEqual(found.first(where: { $0.name == "project" })?.isFolder, true)
    }

    // MARK: Mail

    func testMailPathClassification() {
        let mail = MailLocations(homePath: home)
        let downloads = home + "/Library/Containers/com.apple.mail/Data/Library/Mail Downloads"
        XCTAssertEqual(mail.classify(home + "/Library/Mail"), .store)
        XCTAssertEqual(mail.classify(home + "/Library/Mail/V10/abc/INBOX.mbox/x/Attachments/1/2/file.pdf"), .store)
        XCTAssertEqual(mail.classify(downloads), .downloadsFolder)
        XCTAssertEqual(mail.classify(downloads + "/1234-ABCD/report.pdf"), .download)
        XCTAssertEqual(mail.classify(home + "/Library/Mail Downloads/old.pdf"), .download)
        XCTAssertEqual(mail.classify(home + "/Library/Mail Downloads"), .downloadsFolder)
        XCTAssertEqual(mail.classify(home + "/Library/MailStuff/a"), .other)
        XCTAssertEqual(mail.classify(home + "/Documents/a.pdf"), .other)
    }

    func testMailFinder() throws {
        try file("Library/Mail/V10/acc/INBOX.mbox/x/Attachments/1/report.pdf", bytes: 80_000)
        try file("Library/Mail/V10/acc/INBOX.mbox/x/Messages/1.emlx", bytes: 10_000)
        try file("Library/Containers/com.apple.mail/Data/Library/Mail Downloads/AAAA/invoice.pdf", bytes: 60_000)
        try file("Library/Containers/com.apple.mail/Data/Library/Mail Downloads/BBBB/a.txt")
        try file("Library/Containers/com.apple.mail/Data/Library/Mail Downloads/BBBB/b.txt")

        let found = MailAttachmentsFinder(homePath: home).find()
        XCTAssertTrue(found.storeReadable)
        XCTAssertGreaterThanOrEqual(found.storeBytes, 80_000)
        XCTAssertLessThan(found.storeBytes, 90_000 + 20_000, "messages are not attachments")
        XCTAssertEqual(found.downloads.map(\.name), ["invoice.pdf", "BBBB"])
        XCTAssertEqual(MailAttachmentsFinder(homePath: home + "/nowhere").find(), .init())
    }

    // MARK: Safety

    func testSafetyAllowsWholeBackupsOnly() {
        let policy = SafetyPolicy(homePath: home)
        let sync = home + "/Library/Application Support/MobileSync"
        let backup = policy.verdict(for: sync + "/Backup/00008030-AAA")
        XCTAssertFalse(backup.isBlocked)
        XCTAssertTrue(backup.message?.contains("backup") ?? false)
        XCTAssertTrue(policy.verdict(for: sync + "/Backup").isBlocked)
        XCTAssertTrue(policy.verdict(for: sync).isBlocked)
        XCTAssertTrue(policy.verdict(for: sync + "/Backup/00008030-AAA/Manifest.db").isBlocked)
        XCTAssertTrue(policy.verdict(for: sync + "/Backup/00008030-AAA/0a/0abc").isBlocked)
        XCTAssertFalse(policy.verdict(for: home + "/Library/Application Support/MobileSyncOther").isBlocked)
    }

    func testSafetyKeepsMailStoreButAllowsMailDownloads() {
        let policy = SafetyPolicy(homePath: home)
        XCTAssertTrue(policy.verdict(for: home + "/Library/Mail").isBlocked)
        XCTAssertTrue(policy.verdict(for: home + "/Library/Mail/V10/acc/INBOX.mbox/x/Attachments/1").isBlocked)
        XCTAssertFalse(policy.verdict(for: home + "/Library/Mail Downloads/a.pdf").isBlocked)
        XCTAssertFalse(policy.verdict(
            for: home + "/Library/Containers/com.apple.mail/Data/Library/Mail Downloads/AAAA").isBlocked)
    }

    // MARK: Similar photos

    func testPhotoCandidates() {
        XCTAssertTrue(SimilarPhotoGrouper.isCandidate(path: "/Users/a/Pictures/IMG_1.HEIC"))
        XCTAssertTrue(SimilarPhotoGrouper.isCandidate(path: "/Users/a/Desktop/shot.png"))
        XCTAssertTrue(SimilarPhotoGrouper.isCandidate(path: "/Users/a/Pictures/trip/a.jpeg"))
        XCTAssertFalse(SimilarPhotoGrouper.isCandidate(path: "/Users/a/Pictures/Photos Library.photoslibrary/originals/A/1.heic"))
        XCTAssertFalse(SimilarPhotoGrouper.isCandidate(path: "/Users/a/Library/Caches/x/1.jpg"))
        XCTAssertFalse(SimilarPhotoGrouper.isCandidate(path: "/Users/a/.Trash/1.jpg"))
        XCTAssertFalse(SimilarPhotoGrouper.isCandidate(path: "/Users/a/Pictures/.hidden.jpg"))
        XCTAssertFalse(SimilarPhotoGrouper.isCandidate(path: "/Users/a/Pictures/movie.mov"))
        XCTAssertFalse(SimilarPhotoGrouper.isCandidate(path: "/Applications/X.app/Contents/Resources/a.png"))
    }

    func testGroupsSimilarPhotosAndSuggestsTheBest() {
        let t = Date(timeIntervalSince1970: 1_700_000_000)
        let photos = [
            PhotoCandidate(path: "/p/a.jpg", bytes: 3_000, pixelWidth: 4000, pixelHeight: 3000, taken: t),
            PhotoCandidate(path: "/p/b.jpg", bytes: 2_000, pixelWidth: 2000, pixelHeight: 1500, taken: t.addingTimeInterval(5)),
            PhotoCandidate(path: "/p/c.jpg", bytes: 2_500, pixelWidth: 4000, pixelHeight: 3000, taken: t.addingTimeInterval(9)),
            // Looks the same as a, but taken a week later: not grouped.
            PhotoCandidate(path: "/p/d.jpg", bytes: 2_000, pixelWidth: 4000, pixelHeight: 3000, taken: t.addingTimeInterval(7 * day)),
            // A different picture taken at the same time.
            PhotoCandidate(path: "/p/e.jpg", bytes: 2_000, pixelWidth: 4000, pixelHeight: 3000, taken: t.addingTimeInterval(2)),
            // Two undated screenshots: close enough only under the stricter limit.
            PhotoCandidate(path: "/p/f.png", bytes: 900, pixelWidth: 100, pixelHeight: 100),
            PhotoCandidate(path: "/p/g.png", bytes: 800, pixelWidth: 100, pixelHeight: 100),
            PhotoCandidate(path: "/p/h.png", bytes: 700, pixelWidth: 100, pixelHeight: 100),
        ]
        let look: [String: Int] = ["a": 0, "b": 0, "c": 0, "d": 0, "e": 9, "f": 20, "g": 20, "h": 21]
        let names = photos.map { String($0.name.prefix(1)) }
        var asked = Set<String>()
        let groups = SimilarPhotoGrouper.group(photos) { i, j in
            asked.insert(names[i] + names[j])
            let a = look[names[i]]!, b = look[names[j]]!
            if a == b { return 0.1 }
            if abs(a - b) == 1 { return 0.3 }
            return 1.2
        }
        XCTAssertEqual(groups.map { $0.photos.map(\.name) }, [["c.jpg", "a.jpg", "b.jpg"], ["f.png", "g.png"]])
        XCTAssertEqual(groups[0].suggestedKeep.name, "c.jpg", "most pixels, then the newest")
        XCTAssertEqual(groups[0].extraBytes, 5_000)
        XCTAssertFalse(asked.contains("ad") || asked.contains("da"), "photos far apart in time are not compared")

        XCTAssertNil(groups[1].removing(["/p/g.png"]), "a group of one is no group")
        XCTAssertEqual(groups[0].removing(["/p/c.jpg"])?.suggestedKeep.name, "a.jpg")
    }

    func testGroupingCanStop() {
        let photos = (0..<5).map { PhotoCandidate(path: "/p/\($0).jpg", bytes: 1) }
        XCTAssertTrue(SimilarPhotoGrouper.group(photos, isCancelled: { true }) { _, _ in 0 }.isEmpty)
    }
}
