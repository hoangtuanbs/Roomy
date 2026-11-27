import XCTest
@testable import RoomyCore

/// Quick rescans: planning from FSEvents changes, and patching a tree with what changed in a temporary folder.
final class QuickRescanTests: XCTestCase {
    private var root = ""
    private let fm = FileManager.default

    override func setUpWithError() throws {
        let base = fm.temporaryDirectory.appendingPathComponent("RoomyQuick-\(UUID().uuidString)")
        try fm.createDirectory(at: base, withIntermediateDirectories: true)
        root = DiskScanner.standardize(base.path)
    }

    override func tearDownWithError() throws {
        try? fm.removeItem(atPath: root)
    }

    @discardableResult
    private func file(_ relative: String, bytes: Int, byte: UInt8 = 1) throws -> String {
        let path = root + "/" + relative
        try fm.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try Data(repeating: byte, count: bytes).write(to: URL(fileURLWithPath: path))
        return path
    }

    /// The tree matches a fresh full scan: the same items, sizes, kinds and file counts.
    private func assertMatchesFullScan(_ tree: ScanTree, file: StaticString = #filePath, line: UInt = #line) async throws {
        let full = try await DiskScanner().scan(root: root)
        XCTAssertEqual(tree.size(ScanTree.root), full.size(ScanTree.root), "root size", file: file, line: line)
        XCTAssertEqual(tree.fileCount(ScanTree.root), full.fileCount(ScanTree.root), "file count", file: file, line: line)
        var live = 0
        var stack: [ScanTree.Index] = [ScanTree.root]
        while let n = stack.popLast() {
            live += 1
            let path = tree.path(of: n)
            guard let m = full.index(ofPath: path) else {
                XCTFail("\(path) is not on disk", file: file, line: line)
                continue
            }
            XCTAssertEqual(tree.size(n), full.size(m), path, file: file, line: line)
            XCTAssertEqual(tree.kind(n), full.kind(m), path, file: file, line: line)
            XCTAssertEqual(tree.fileCount(n), full.fileCount(m), path, file: file, line: line)
            let sizes = tree.children(n).map(tree.size)
            XCTAssertEqual(sizes, sizes.sorted(by: >), "children of \(path) largest first", file: file, line: line)
            stack.append(contentsOf: tree.children(n))
        }
        XCTAssertEqual(live, full.count, "item count", file: file, line: line)
    }

    // MARK: Patching

    func testListingChangedFoldersAgainMatchesAFullScan() async throws {
        try file("docs/a.txt", bytes: 10_000)
        try file("docs/old.txt", bytes: 20_000)
        try file("docs/keep/inner.bin", bytes: 5_000)
        try file("media/film.mov", bytes: 300_000)
        let tree = try await DiskScanner().scan(root: root)

        try file("docs/a.txt", bytes: 90_000, byte: 2)          // grew
        try fm.removeItem(atPath: root + "/docs/old.txt")         // gone
        try file("docs/new.txt", bytes: 40_000)                   // new file
        try file("docs/project/src/main.swift", bytes: 7_000)     // new folder with a folder inside
        try fm.removeItem(atPath: root + "/media")                // a whole folder gone
        try file("top.bin", bytes: 1_000)                         // new in the root

        let report = try await QuickRescan.apply(folders: [root, root + "/docs"], subtrees: [], to: tree)

        XCTAssertEqual(report.listedFolders, 2)
        XCTAssertEqual(report.scannedFolders, 1, "The new folder is scanned whole")
        XCTAssertNil(tree.index(ofPath: root + "/docs/old.txt"))
        XCTAssertNil(tree.index(ofPath: root + "/media/film.mov"))
        XCTAssertNotNil(tree.index(ofPath: root + "/docs/project/src/main.swift"))
        try await assertMatchesFullScan(tree)
    }

    func testSubtreesAreScannedWholeAndMissingFoldersAskTheirParent() async throws {
        try file("a/b/c/deep.bin", bytes: 4_000)
        try file("x/y.bin", bytes: 4_000)
        let tree = try await DiskScanner().scan(root: root)

        try file("a/b/c/deeper/more.bin", bytes: 64_000)
        try fm.removeItem(atPath: root + "/a/b/c/deep.bin")
        try file("x/z/new/n.bin", bytes: 8_000)

        // FSEvents said to rescan all of a/b, and named a folder deep inside x/z that the tree does not have yet.
        let report = try await QuickRescan.apply(folders: [root + "/x/z/new"], subtrees: [root + "/a/b"], to: tree)
        XCTAssertGreaterThanOrEqual(report.scannedFolders, 1)
        try await assertMatchesFullScan(tree)
    }

    func testAFileThatBecameAFolderAndBack() async throws {
        try file("thing", bytes: 3_000)
        try file("other/x.bin", bytes: 2_000)
        let tree = try await DiskScanner().scan(root: root)

        try fm.removeItem(atPath: root + "/thing")
        try file("thing/inside.bin", bytes: 12_000)
        try fm.removeItem(atPath: root + "/other")
        try file("other", bytes: 9_000)

        _ = try await QuickRescan.apply(folders: [root], subtrees: [], to: tree)
        try await assertMatchesFullScan(tree)
    }

    func testListingAnUnchangedFolderChangesNothing() async throws {
        try file("a/one.bin", bytes: 10_000)
        try file("b/two.bin", bytes: 20_000)
        let tree = try await DiskScanner().scan(root: root)
        let before = tree.size(ScanTree.root)
        _ = try await QuickRescan.apply(folders: [root, root + "/a", root + "/b"], subtrees: [], to: tree)
        XCTAssertEqual(tree.size(ScanTree.root), before)
        try await assertMatchesFullScan(tree)
    }

    func testHardLinksStayCountedOnce() async throws {
        let original = try file("one/movie.mov", bytes: 200_000)
        try fm.createDirectory(atPath: root + "/two", withIntermediateDirectories: true)
        try fm.linkItem(atPath: original, toPath: root + "/two/link.mov")
        let tree = try await DiskScanner().scan(root: root)
        let before = tree.size(ScanTree.root)
        _ = try await QuickRescan.apply(folders: [root + "/one", root + "/two"], subtrees: [], to: tree)
        XCTAssertEqual(tree.size(ScanTree.root), before)
    }

    func testClonesStayCountedOnce() async throws {
        let original = try file("a/original.bin", bytes: 524_288)
        #if canImport(Darwin)
        try fm.createDirectory(atPath: root + "/b", withIntermediateDirectories: true)
        guard clonefile(original, root + "/b/copy.bin", 0) == 0 else { throw XCTSkip("no clones on this disk") }
        #else
        throw XCTSkip("Clones need APFS")
        #endif
        let tree = try await DiskScanner().scan(root: root)
        let before = tree.size(ScanTree.root)
        _ = try await QuickRescan.apply(folders: [root + "/a", root + "/b"], subtrees: [], to: tree)
        XCTAssertEqual(tree.size(ScanTree.root), before)
        // A new clone in a listed folder adds only its own space.
        #if canImport(Darwin)
        XCTAssertEqual(clonefile(original, root + "/b/copy 2.bin", 0), 0)
        #endif
        _ = try await QuickRescan.apply(folders: [root + "/b"], subtrees: [], to: tree)
        XCTAssertEqual(tree.size(ScanTree.root), before)
        let carriers = tree.clones.values.filter(\.carriesShared)
        XCTAssertEqual(carriers.count, 1, "One file carries the shared space")
    }

    func testACopyOfTheTreeKeepsIndexesAndLeavesRemovedItemsOut() async throws {
        try file("a/one.bin", bytes: 10_000)
        try file("b/two.bin", bytes: 20_000)
        let tree = try await DiskScanner().scan(root: root)
        let a = try XCTUnwrap(tree.index(ofPath: root + "/a"))
        tree.detach(a)
        let copy = tree.copy()
        XCTAssertEqual(copy.count, tree.count)
        XCTAssertEqual(copy.size(ScanTree.root), tree.size(ScanTree.root))
        XCTAssertEqual(copy.children(ScanTree.root).map(copy.name), tree.children(ScanTree.root).map(tree.name))
        XCTAssertEqual(copy.journalID, tree.journalID)
        XCTAssertEqual(copy.index(ofPath: root + "/b/two.bin"), tree.index(ofPath: root + "/b/two.bin"))
        XCTAssertNil(copy.index(ofPath: root + "/a/one.bin"))
    }

    // MARK: Planning

    func testPlansFromChanges() {
        let r = "/Users/me"
        XCTAssertEqual(ChangeJournal.plan(changes: [], root: r), .upToDate)
        XCTAssertEqual(ChangeJournal.plan(changes: [FolderChange(path: "/Users/other/x", flags: 0)], root: r), .upToDate,
                       "Changes elsewhere do not matter")
        XCTAssertEqual(
            ChangeJournal.plan(changes: [FolderChange(path: "/Users/me/Documents/", flags: 0),
                                         FolderChange(path: "/Users/me", flags: 0),
                                         FolderChange(path: "/Users/me/Documents", flags: 0x10000)],
                               root: r),
            .patch(folders: ["/Users/me", "/Users/me/Documents"], subtrees: []))
        XCTAssertEqual(
            ChangeJournal.plan(changes: [FolderChange(path: "/Users/me/Projects/app/src", flags: 0),
                                         FolderChange(path: "/Users/me/Projects", flags: ChangeJournal.mustScanSubDirs),
                                         FolderChange(path: "/Users/me/Projects/app", flags: ChangeJournal.mustScanSubDirs),
                                         FolderChange(path: "/Users/me/Music", flags: 0)],
                               root: r),
            .patch(folders: ["/Users/me/Music"], subtrees: ["/Users/me/Projects"]),
            "What lies inside a folder scanned whole needs nothing more")
    }

    func testFallsBackToAFullScanWhenTheHistoryCannotBeTrusted() {
        let r = "/Users/me"
        for flag in [ChangeJournal.userDropped, ChangeJournal.kernelDropped, ChangeJournal.eventIDsWrapped,
                     ChangeJournal.rootChanged] {
            guard case .full = ChangeJournal.plan(changes: [FolderChange(path: "/Users/me/x", flags: flag)], root: r) else {
                return XCTFail("flag \(flag) should ask for a full scan")
            }
        }
        // Dropped events say so for the whole disk, wherever they are.
        guard case .full = ChangeJournal.plan(changes: [FolderChange(path: "/", flags: ChangeJournal.kernelDropped)], root: r) else {
            return XCTFail("dropped events elsewhere")
        }
        guard case .full = ChangeJournal.plan(changes: [FolderChange(path: "/Users/me", flags: ChangeJournal.mustScanSubDirs)], root: r) else {
            return XCTFail("coalesced at the root")
        }
        guard case .full = ChangeJournal.plan(changes: [FolderChange(path: "/", flags: ChangeJournal.mustScanSubDirs)], root: r) else {
            return XCTFail("coalesced above the root, as when the history was purged")
        }
        XCTAssertEqual(ChangeJournal.plan(changes: [FolderChange(path: "/Users", flags: 0)], root: r), .upToDate,
                       "A change in a folder above, without a rescan demand, is not about the scan")
    }

    func testResolvedSpellingsOfTheRootAreMapped() {
        let plan = ChangeJournal.plan(changes: [FolderChange(path: "/private/var/tmp/scan/a", flags: 0)],
                                      root: "/var/tmp/scan", aliases: ["/private/var/tmp/scan"])
        XCTAssertEqual(plan, .patch(folders: ["/var/tmp/scan/a"], subtrees: []))
    }

    func testAScanWithoutAnEventIDNeedsAFullScan() async throws {
        let tree = ScanTree(rootPath: root, size: 0, modified: 0)
        let result = try await QuickRescan.run(tree)
        guard case .needsFullScan = result else { return XCTFail("\(result)") }
    }

    func testTheCacheKeepsTheEventID() throws {
        let tree = ScanTree(rootPath: "/scan", size: 0, modified: 0)
        tree.journalID = 123_456_789
        tree.volumeID = "ABC-DEF"
        tree.finalize()
        let restored = ScanTree(snapshot: try ScanSnapshot(decoding: tree.snapshot(scannedAt: Date()).encoded()))
        XCTAssertEqual(restored.journalID, 123_456_789)
        XCTAssertEqual(restored.volumeID, "ABC-DEF")
    }

    // MARK: The real history

    /// Scans, changes files, and reads the FSEvents history: the quick rescan must match a full scan.
    func testAQuickRescanWithTheRealHistory() async throws {
        try file("a/one.bin", bytes: 10_000)
        let tree = try await DiskScanner().scan(root: root)
        XCTAssertGreaterThan(tree.journalID, 0)
        try file("a/two.bin", bytes: 30_000)
        try file("b/three.bin", bytes: 50_000)
        try fm.removeItem(atPath: root + "/a/one.bin")
        try await Task.sleep(for: .seconds(2))

        let result = try await QuickRescan.run(tree)
        guard case .patched(let report) = result else {
            throw XCTSkip("FSEvents had no usable history here: \(result)")
        }
        XCTAssertGreaterThan(report.listedFolders, 0)
        try await assertMatchesFullScan(tree)
        XCTAssertGreaterThan(tree.journalID, 0)
    }
}
