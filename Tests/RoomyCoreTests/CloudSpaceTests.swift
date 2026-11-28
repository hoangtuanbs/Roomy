import Foundation
import XCTest
@testable import RoomyCore

/// Cloud Space: provider names, the evict rule, grouping, selection and evicting, with made-up cloud status in a
/// temporary folder that stands in for the home folder. Real cloud services are never touched.
final class CloudSpaceTests: XCTestCase {
    private var home = ""
    private let fm = FileManager.default

    override func setUpWithError() throws {
        let base = fm.temporaryDirectory.appendingPathComponent("RoomyCloud-\(UUID().uuidString)")
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

    private struct FakeStatus: CloudStatusReading {
        var byPath: [String: CloudStatus]
        var fallback = CloudStatus()
        func status(of path: String) -> CloudStatus { byPath[path] ?? fallback }
    }

    private final class FakeEvictor: CloudEvicting, @unchecked Sendable {
        private let lock = NSLock()
        private var paths: [String] = []
        var failing: Set<String> = []

        var evicted: [String] { lock.withLock { paths } }

        func evict(_ path: String) throws {
            if failing.contains(path) { throw CocoaError(.fileWriteNoPermission) }
            lock.withLock { paths.append(path) }
        }
    }

    private let safe = CloudStatus(isCloudItem: true, download: .current, isUploaded: true, isUploading: false, hasConflicts: false)

    // MARK: Providers

    func testNamesProvidersFromFolderNames() {
        let root = "/x"
        XCTAssertEqual(CloudLocations.provider(folderName: "Dropbox", rootPath: root)?.kind, .dropbox)
        XCTAssertNil(CloudLocations.provider(folderName: "Dropbox", rootPath: root)?.account)
        let oneDrive = CloudLocations.provider(folderName: "OneDrive-Personal", rootPath: root)
        XCTAssertEqual(oneDrive?.kind, .oneDrive)
        XCTAssertEqual(oneDrive?.account, "Personal")
        XCTAssertEqual(oneDrive?.title, "OneDrive (Personal)")
        let google = CloudLocations.provider(folderName: "GoogleDrive-anna@example.com", rootPath: root)
        XCTAssertEqual(google?.kind, .googleDrive)
        XCTAssertEqual(google?.name, "Google Drive")
        XCTAssertEqual(google?.account, "anna@example.com")
        let box = CloudLocations.provider(folderName: "Box-Box", rootPath: root)
        XCTAssertEqual(box?.kind, .box)
        XCTAssertNil(box?.account)
        XCTAssertEqual(CloudLocations.provider(folderName: "OneDrive-Contoso Ltd", rootPath: root)?.account, "Contoso Ltd")
        XCTAssertEqual(CloudLocations.provider(folderName: "pCloud", rootPath: root)?.kind, .other)
        XCTAssertNil(CloudLocations.provider(folderName: ".hidden", rootPath: root))
    }

    func testFindsProviderFoldersAndIgnoresMissingOnes() throws {
        let places = CloudLocations(homePath: home)
        XCTAssertTrue(places.providers().isEmpty)
        try fm.createDirectory(atPath: places.cloudStorage + "/Dropbox", withIntermediateDirectories: true)
        try fm.createDirectory(atPath: places.cloudStorage + "/OneDrive-Personal", withIntermediateDirectories: true)
        try file("Library/CloudStorage/.DS_Store")
        // A Mobile Documents folder without iCloud Drive in it is not iCloud Drive.
        try fm.createDirectory(atPath: places.mobileDocuments + "/com~apple~Other", withIntermediateDirectories: true)
        XCTAssertEqual(places.providers().map(\.kind), [.dropbox, .oneDrive])
        try fm.createDirectory(atPath: places.mobileDocuments + "/com~apple~CloudDocs", withIntermediateDirectories: true)
        XCTAssertEqual(places.providers().map(\.kind), [.iCloudDrive, .dropbox, .oneDrive])
    }

    func testProviderContainingPath() {
        let dropbox = CloudProvider(kind: .dropbox, name: "Dropbox", account: nil, rootPath: "/u/Library/CloudStorage/Dropbox")
        let providers = [dropbox]
        XCTAssertEqual(CloudLocations.provider(containing: "/u/Library/CloudStorage/Dropbox/a.txt", in: providers), dropbox)
        XCTAssertNil(CloudLocations.provider(containing: "/u/Library/CloudStorage/Dropbox", in: providers))
        XCTAssertNil(CloudLocations.provider(containing: "/u/Library/CloudStorage/DropboxOld/a.txt", in: providers))
        XCTAssertNil(CloudLocations.provider(containing: "/u/Library/CloudStorage/Dropbox/../../x", in: providers))
    }

    func testGroupsByTopFolder() {
        let places = CloudLocations(homePath: "/u")
        let iCloud = places.iCloud
        let drive = "/u/Library/Mobile Documents/com~apple~CloudDocs"
        XCTAssertEqual(CloudLocations.group(of: drive + "/Documents/a/b.pdf", in: iCloud).name, "Documents")
        XCTAssertEqual(CloudLocations.group(of: drive + "/Documents/a/b.pdf", in: iCloud).path, drive + "/Documents")
        XCTAssertEqual(CloudLocations.group(of: drive + "/b.pdf", in: iCloud).name, CloudLocations.topLevel)
        XCTAssertEqual(CloudLocations.group(of: "/u/Library/Mobile Documents/iCloud~com~apple~Pages/Documents/x.pages", in: iCloud).name, "Pages")
        let dropbox = CloudProvider(kind: .dropbox, name: "Dropbox", account: nil, rootPath: "/u/Library/CloudStorage/Dropbox")
        XCTAssertEqual(CloudLocations.group(of: dropbox.rootPath + "/Photos/2024/a.jpg", in: dropbox).name, "Photos")
        XCTAssertEqual(CloudLocations.group(of: dropbox.rootPath + "/a.jpg", in: dropbox).name, CloudLocations.topLevel)
        XCTAssertEqual(CloudLocations.appName(container: "com~apple~TextEdit"), "TextEdit")
    }

    // MARK: The rule

    func testOnlyUploadedLocalCopiesAreEvictable() {
        XCTAssertEqual(CloudRule.verdict(safe), .evictable)
        var downloaded = safe
        downloaded.download = .downloaded
        XCTAssertEqual(CloudRule.verdict(downloaded), .evictable)

        var status = safe
        status.isUploaded = false
        XCTAssertEqual(CloudRule.verdict(status), .notUploaded)
        XCTAssertEqual(CloudRule.verdict(status).note, "Not uploaded yet — kept")
        status = safe
        status.isUploading = true
        XCTAssertEqual(CloudRule.verdict(status), .notUploaded)
        status = safe
        status.isUploaded = nil
        XCTAssertEqual(CloudRule.verdict(status), .notUploaded, "an unknown upload state keeps the file")
        status = safe
        status.hasConflicts = true
        XCTAssertEqual(CloudRule.verdict(status), .conflicted)

        status = safe
        status.download = .notDownloaded
        XCTAssertEqual(CloudRule.verdict(status), .notLocal)
        status = safe
        status.download = .unknown
        XCTAssertEqual(CloudRule.verdict(status), .notCloud)
        status = safe
        status.isCloudItem = false
        XCTAssertEqual(CloudRule.verdict(status), .notCloud)
        XCTAssertEqual(CloudRule.verdict(CloudStatus()), .notCloud)
    }

    // MARK: Finding

    private func dropboxSetup() throws -> (CloudProvider, big: String, small: String, pending: String, cloudOnly: String, top: String) {
        let root = home + "/Library/CloudStorage/Dropbox"
        let big = try file("Library/CloudStorage/Dropbox/Videos/trip.mov", bytes: 300_000)
        let small = try file("Library/CloudStorage/Dropbox/Docs/a.pdf", bytes: 10_000)
        let pending = try file("Library/CloudStorage/Dropbox/Docs/new.pdf", bytes: 50_000)
        let cloudOnly = try file("Library/CloudStorage/Dropbox/Docs/old.pdf", bytes: 10_000)
        let top = try file("Library/CloudStorage/Dropbox/notes.txt", bytes: 5_000)
        try file("Library/CloudStorage/Dropbox/.dropbox.cache/x", bytes: 90_000)
        let provider = CloudProvider(kind: .dropbox, name: "Dropbox", account: nil, rootPath: root)
        return (provider, big, small, pending, cloudOnly, top)
    }

    func testFindsLocalCopiesGroupedLargestFirst() throws {
        let setup = try dropboxSetup()
        var notUploaded = safe
        notUploaded.isUploaded = false
        var remote = safe
        remote.download = .notDownloaded
        let status = FakeStatus(byPath: [setup.big: safe, setup.small: safe, setup.pending: notUploaded,
                                         setup.cloudOnly: remote, setup.top: safe])
        let findings = CloudSpaceFinder(providers: [setup.0], status: status).find()

        XCTAssertFalse(findings.capped)
        XCTAssertEqual(findings.providers.count, 1)
        let groups = findings.providers[0].groups
        XCTAssertEqual(groups.map(\.name), ["Videos", "Docs", CloudLocations.topLevel])
        let docs = groups[1]
        XCTAssertEqual(docs.items.map(\.path), [setup.pending, setup.small], "the cloud-only file is not listed")
        XCTAssertEqual(docs.evictable.map(\.path), [setup.small])
        XCTAssertEqual(docs.kept.map(\.path), [setup.pending])
        XCTAssertGreaterThan(docs.keptBytes, 0)
        XCTAssertFalse(findings.groups.flatMap(\.items).contains { $0.path.contains(".dropbox.cache") }, "hidden folders are skipped")
        XCTAssertEqual(findings.evictableBytes, groups.reduce(0) { $0 + $1.evictableBytes })
    }

    func testNonCloudFilesAndEmptyProvidersAreLeftOut() throws {
        let setup = try dropboxSetup()
        let findings = CloudSpaceFinder(providers: [setup.0], status: FakeStatus(byPath: [:])).find()
        XCTAssertTrue(findings.providers.isEmpty)
    }

    func testStopsAtTheFileLimit() throws {
        let setup = try dropboxSetup()
        let findings = CloudSpaceFinder(providers: [setup.0], status: FakeStatus(byPath: [:], fallback: safe), fileLimit: 2).find()
        XCTAssertTrue(findings.capped)
        XCTAssertLessThanOrEqual(findings.groups.flatMap(\.items).count, 2)
    }

    func testDocumentPackagesAreOneItem() throws {
        let root = home + "/Library/Mobile Documents"
        try file("Library/Mobile Documents/com~apple~CloudDocs/Work/Plan.pages/Index.zip", bytes: 40_000)
        try file("Library/Mobile Documents/com~apple~CloudDocs/Work/Plan.pages/Data/pic.jpg", bytes: 40_000)
        let package = root + "/com~apple~CloudDocs/Work/Plan.pages"
        let provider = CloudLocations(homePath: home).iCloud
        let findings = CloudSpaceFinder(providers: [provider], status: FakeStatus(byPath: [package: safe])).find()
        XCTAssertEqual(findings.groups.map(\.name), ["Work"])
        XCTAssertEqual(findings.groups[0].items.map(\.path), [package])
        XCTAssertGreaterThanOrEqual(findings.groups[0].items[0].bytes, 80_000)
    }

    // MARK: Selection

    func testSelectionTicksOnlyGroupsWithSomethingToRemove() throws {
        let setup = try dropboxSetup()
        var notUploaded = safe
        notUploaded.isUploaded = false
        let status = FakeStatus(byPath: [setup.big: notUploaded, setup.small: safe, setup.pending: notUploaded, setup.top: safe])
        let findings = CloudSpaceFinder(providers: [setup.0], status: status).find()
        let provider = findings.providers[0]
        let videos = provider.groups.first { $0.name == "Videos" }!
        let docs = provider.groups.first { $0.name == "Docs" }!

        var selection = CloudSelection()
        XCTAssertEqual(selection.state(of: provider), .none)
        selection.toggle(videos)
        XCTAssertFalse(selection.contains(videos), "a group with only kept files cannot be ticked")
        selection.toggle(docs)
        XCTAssertEqual(selection.state(of: provider), .some)
        XCTAssertEqual(selection.selectedItems(in: findings).map(\.path), [setup.small], "kept files are never selected")
        selection.setAll(provider, selected: true)
        XCTAssertEqual(selection.state(of: provider), .all)
        XCTAssertEqual(Set(selection.selectedItems(in: findings).map(\.path)), [setup.small, setup.top])
        XCTAssertEqual(selection.selectedProviders(in: findings), [setup.0])
        selection.setAll(provider, selected: false)
        XCTAssertEqual(selection.selectedBytes(in: findings), 0)
        XCTAssertTrue(selection.selectedProviders(in: findings).isEmpty)
    }

    // MARK: Evicting

    func testEvictsOnlyWhatIsStillSafe() throws {
        let setup = try dropboxSetup()
        let outside = try file("Documents/mine.txt")
        var uploading = safe
        uploading.isUploading = true
        // Between finding and evicting, the small file started uploading again.
        let status = FakeStatus(byPath: [setup.big: safe, setup.small: uploading, setup.top: safe, outside: safe])
        let evictor = FakeEvictor()
        evictor.failing = [setup.top]
        let service = CloudEvictionService(providers: [setup.0], status: status, evictor: evictor)
        let items = [setup.big, setup.small, setup.top, outside].map { CloudItem(path: $0, bytes: 1_000, verdict: .evictable) }
        var seen = 0
        let report = service.evict(items) { _ in seen += 1 }

        XCTAssertEqual(seen, 4)
        XCTAssertEqual(evictor.evicted, [setup.big], "only the safe file inside a cloud folder is evicted")
        XCTAssertEqual(report.succeeded.map(\.path), [setup.big])
        XCTAssertEqual(report.freedBytes, 1_000)
        XCTAssertEqual(report.failed.first { $0.path == setup.small }?.error, "Not uploaded yet — kept")
        XCTAssertEqual(report.failed.first { $0.path == outside }?.error, "Not in a cloud folder")
        XCTAssertNotNil(report.failed.first { $0.path == setup.top }?.error)
        // Nothing was moved or deleted.
        for path in [setup.big, setup.small, setup.top, outside] {
            XCTAssertTrue(fm.fileExists(atPath: path))
        }
    }

    // MARK: Google Drive

    func testGoogleDriveIsFoundWithItsAccountAndGroupedInsideMyDrive() throws {
        let root = home + "/Library/CloudStorage/GoogleDrive-anna@example.com"
        let report = try file("Library/CloudStorage/GoogleDrive-anna@example.com/My Drive/Reports/q3.pdf", bytes: 80_000)
        let loose = try file("Library/CloudStorage/GoogleDrive-anna@example.com/My Drive/notes.txt", bytes: 30_000)
        let shared = try file("Library/CloudStorage/GoogleDrive-anna@example.com/Shared drives/Team/plan.key", bytes: 50_000)
        let providers = CloudLocations(homePath: home).providers()
        let drive = try XCTUnwrap(providers.first { $0.kind == .googleDrive })
        XCTAssertEqual(drive.title, "Google Drive (anna@example.com)")
        XCTAssertEqual(drive.rootPath, root)

        XCTAssertEqual(CloudLocations.group(of: report, in: drive).name, "My Drive › Reports")
        XCTAssertEqual(CloudLocations.group(of: report, in: drive).path, root + "/My Drive/Reports")
        XCTAssertEqual(CloudLocations.group(of: loose, in: drive).name, "My Drive")
        XCTAssertEqual(CloudLocations.group(of: shared, in: drive).name, "Shared drives › Team")

        let findings = CloudSpaceFinder(providers: [drive], status: FakeStatus(byPath: [report: safe, loose: safe, shared: safe])).find()
        XCTAssertEqual(findings.providers.first?.groups.map(\.name), ["My Drive › Reports", "Shared drives › Team", "My Drive"])
        XCTAssertEqual(findings.evictableBytes, findings.groups.flatMap(\.items).reduce(0) { $0 + $1.bytes })

        let evictor = FakeEvictor()
        let removed = CloudEvictionService(providers: [drive], status: FakeStatus(byPath: [report: safe]), evictor: evictor)
            .evict(findings.groups.flatMap(\.evictable))
        XCTAssertEqual(evictor.evicted, [report], "only files that are still safely uploaded lose their local copy")
        XCTAssertEqual(removed.succeeded.map(\.path), [report])
        XCTAssertTrue(fm.fileExists(atPath: report) && fm.fileExists(atPath: loose) && fm.fileExists(atPath: shared))
    }

    func testAGoogleDriveThatDoesNotAnswerIsSkipped() throws {
        let root = home + "/Library/CloudStorage/GoogleDrive-anna@example.com"
        try file("Library/CloudStorage/GoogleDrive-anna@example.com/My Drive/a.txt")
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let drive = CloudProvider(kind: .googleDrive, name: "Google Drive", account: "anna@example.com", rootPath: root)
        let start = Date()
        let findings = CloudSpaceFinder(providers: [drive], status: FakeStatus(byPath: [:], fallback: safe),
                                        reader: .withStuckFolders([root], timeout: 0.3, release: release)).find()
        XCTAssertEqual(findings.unavailable, [drive])
        XCTAssertTrue(findings.providers.isEmpty)
        XCTAssertLessThan(Date().timeIntervalSince(start), 5, "the stuck drive was waited for")
        XCTAssertEqual(CloudGuard.unavailableNote(for: root), "Not available (Google Drive isn't running)")
    }
}
