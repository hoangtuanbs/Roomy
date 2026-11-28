import Foundation
import XCTest
@testable import RoomyCore

/// A cloud drive whose app is not running can make even a folder listing wait forever. These tests stand in for it
/// with a reader that blocks until the test lets it go, and check that scans and Cloud Space give up on it in time.
final class ProviderGuardTests: XCTestCase {
    private var home = ""
    private let fm = FileManager.default
    private var release = DispatchSemaphore(value: 0)

    override func setUpWithError() throws {
        let base = fm.temporaryDirectory.appendingPathComponent("RoomyGuard-\(UUID().uuidString)")
        try fm.createDirectory(at: base, withIntermediateDirectories: true)
        home = DiskScanner.standardize(base.path)
        release = DispatchSemaphore(value: 0)
    }

    override func tearDownWithError() throws {
        // Lets every blocked read finish, so no thread is left waiting.
        release.signal()
        try? fm.removeItem(atPath: home)
    }

    private func file(_ relative: String, bytes: Int = 40_000) throws {
        let path = home + "/" + relative
        try fm.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try Data(repeating: 3, count: bytes).write(to: URL(fileURLWithPath: path))
    }

    private var googleDrive: String { home + "/Library/CloudStorage/GoogleDrive-anna@example.com" }

    /// Reads from the disk, except that reading `stuck` waits until the test ends.
    private func blockingReader(_ stuck: String, timeout: TimeInterval = 0.3) -> FolderReader {
        let release = self.release
        return FolderReader(timeout: timeout, stalls: StallGuard()) { path, clones in
            if path == stuck {
                release.wait()
                release.signal()
            }
            return DirectoryReader.list(path: path, clones: clones)
        }
    }

    func testOnlyCloudStorageAndItsAccountFoldersAreGuarded() {
        XCTAssertTrue(CloudGuard.isGuarded("/Users/a/Library/CloudStorage"))
        XCTAssertTrue(CloudGuard.isGuarded("/Users/a/Library/CloudStorage/GoogleDrive-a@b.com"))
        XCTAssertFalse(CloudGuard.isGuarded("/Users/a/Library/CloudStorage/.hidden"))
        XCTAssertFalse(CloudGuard.isGuarded("/Users/a/Library/CloudStorage/Dropbox/Documents"))
        XCTAssertFalse(CloudGuard.isGuarded("/Users/a/Library/Caches"))
        XCTAssertFalse(CloudGuard.isGuarded("/Users/a/Documents"))
    }

    func testTheNoteNamesTheService() {
        XCTAssertEqual(CloudGuard.unavailableNote(for: "/u/Library/CloudStorage/GoogleDrive-anna@example.com"),
                       "Not available (Google Drive isn't running)")
        XCTAssertEqual(CloudGuard.providerName(of: "/u/Library/CloudStorage/OneDrive-Personal"), "OneDrive")
    }

    func testAStuckReadTimesOutAndLaterCallsDoNotStartAnother() {
        let stalls = StallGuard()
        let release = self.release
        let started = DispatchSemaphore(value: 0)
        let calls = Counter()
        let start = Date()
        let first = stalls.run(key: "k", timeout: 0.2) { () -> Int in
            calls.add()
            started.signal()
            release.wait()
            release.signal()
            return 1
        }
        guard case .timedOut = first else { return XCTFail("the stuck call did not time out") }
        XCTAssertLessThan(Date().timeIntervalSince(start), 2)
        XCTAssertEqual(started.wait(timeout: .now() + 1), .success)
        XCTAssertTrue(stalls.isStuck("k"))

        let second = stalls.run(key: "k", timeout: 5) { () -> Int in calls.add(); return 2 }
        guard case .timedOut = second else { return XCTFail("a second call waited for a stuck key") }
        XCTAssertEqual(calls.value, 1, "a second thread was started for a stuck key")

        // Once the stuck read returns, the key reads normally again.
        release.signal()
        let deadline = Date().addingTimeInterval(3)
        while stalls.isStuck("k") && Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
        guard case .finished(let value) = stalls.run(key: "k", timeout: 2, { 3 }) else { return XCTFail("did not finish") }
        XCTAssertEqual(value, 3)
    }

    func testAQuickReadFinishes() {
        guard case .finished(let value) = StallGuard().run(key: "fast", timeout: 2, { 42 }) else {
            return XCTFail("a quick call timed out")
        }
        XCTAssertEqual(value, 42)
    }

    func testAScanDoesNotWaitForAStuckCloudDrive() async throws {
        try file("Documents/report.pdf", bytes: 200_000)
        try file("Library/CloudStorage/GoogleDrive-anna@example.com/My Drive/big.mov", bytes: 300_000)
        try file("Library/CloudStorage/Dropbox/notes.txt", bytes: 50_000)

        let options = ScanOptions(detectClones: false, reader: blockingReader(googleDrive))
        let start = Date()
        let tree = try await DiskScanner(options: options).scan(root: home)
        XCTAssertLessThan(Date().timeIntervalSince(start), 5, "the scan waited for the stuck cloud drive")

        guard let drive = tree.index(ofPath: googleDrive) else { return XCTFail("the cloud drive is not listed") }
        XCTAssertTrue(tree.flags(drive).contains(.unavailable))
        XCTAssertFalse(tree.flags(drive).contains(.inaccessible))
        XCTAssertLessThanOrEqual(tree.size(drive), 4096, "the stuck drive should count no local bytes")
        XCTAssertTrue(tree.children(drive).isEmpty)
        XCTAssertNotNil(tree.index(ofPath: home + "/Library/CloudStorage/Dropbox/notes.txt"), "the working drive was read")
        XCTAssertNotNil(tree.index(ofPath: home + "/Documents/report.pdf"))
        XCTAssertGreaterThanOrEqual(tree.size(ScanTree.root), 250_000)
    }

    func testAScanOfTheStuckDriveItselfFinishes() async throws {
        try file("Library/CloudStorage/GoogleDrive-anna@example.com/a.bin")
        let options = ScanOptions(detectClones: false, reader: blockingReader(googleDrive))
        let tree = try await DiskScanner(options: options).scan(root: googleDrive)
        XCTAssertTrue(tree.flags(ScanTree.root).contains(.unavailable))
    }

    func testCloudSpaceSkipsAStuckDrive() throws {
        try file("Library/CloudStorage/GoogleDrive-anna@example.com/My Drive/big.mov")
        try file("Library/CloudStorage/Dropbox/notes.txt")
        let locations = CloudLocations(homePath: home)
        let providers = locations.providers()
        XCTAssertEqual(Set(providers.map(\.name)), ["Google Drive", "Dropbox"])

        let start = Date()
        let found = CloudSpaceFinder(providers: providers, reader: blockingReader(googleDrive)).find()
        XCTAssertLessThan(Date().timeIntervalSince(start), 5)
        XCTAssertEqual(found.unavailable.map(\.rootPath), [googleDrive])
    }

    func testAQuickRescanDoesNotWaitForAStuckCloudDrive() async throws {
        try file("Library/CloudStorage/GoogleDrive-anna@example.com/a.bin")
        try file("Documents/a.bin")
        let tree = try await DiskScanner(options: ScanOptions(detectClones: false)).scan(root: home)
        let options = ScanOptions(detectClones: false, reader: blockingReader(googleDrive))
        let start = Date()
        _ = try await QuickRescan.apply(folders: [googleDrive], subtrees: [], to: tree, options: options)
        XCTAssertLessThan(Date().timeIntervalSince(start), 5)
        guard let drive = tree.index(ofPath: googleDrive) else { return XCTFail("the drive is gone") }
        XCTAssertTrue(tree.flags(drive).contains(.unavailable))
    }

    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        var value: Int { lock.withLock { count } }
        func add() { lock.withLock { count += 1 } }
    }
}
