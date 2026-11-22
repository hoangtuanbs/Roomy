import XCTest
@testable import RoomyCore

/// Builds small trees by hand: /scan with docs (a.txt 100, b.txt 300) and movie.mov 600.
private func sampleTree() -> ScanTree {
    let tree = ScanTree(rootPath: "/scan", size: 0, modified: 1000)
    let docs = tree.append(name: "docs", parent: ScanTree.root, kind: .directory, size: 0, modified: 2000, flags: [])
    tree.append(name: "a.txt", parent: docs, kind: .file, size: 100, modified: 3000, flags: [])
    tree.append(name: "b.txt", parent: docs, kind: .file, size: 300, modified: 4000, flags: [.hardLinkDuplicate])
    tree.append(name: "movie.mov", parent: ScanTree.root, kind: .file, size: 600, modified: 5000, flags: [])
    tree.append(name: "Locked", parent: ScanTree.root, kind: .directory, size: 0, modified: 6000, flags: [.inaccessible])
    tree.finalize()
    return tree
}

final class ScanCacheTests: XCTestCase {
    private var folder = ""

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("RoomyCacheTests-\(UUID().uuidString)").path
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(atPath: folder)
    }

    func testSnapshotRoundTripsThroughBytes() throws {
        let tree = sampleTree()
        let date = Date(timeIntervalSince1970: 1_700_000_123.5)
        let snapshot = tree.snapshot(scannedAt: date)
        let decoded = try ScanSnapshot(decoding: snapshot.encoded())
        XCTAssertEqual(decoded, snapshot)

        let restored = ScanTree(snapshot: decoded)
        XCTAssertEqual(restored.rootPath, "/scan")
        XCTAssertEqual(restored.count, tree.count)
        XCTAssertEqual(restored.size(ScanTree.root), 1000)
        XCTAssertEqual(restored.fileCount(ScanTree.root), 3)
        let docs = try XCTUnwrap(restored.index(ofPath: "/scan/docs"))
        XCTAssertEqual(restored.size(docs), 400)
        XCTAssertEqual(restored.children(docs).map { restored.name($0) }, ["b.txt", "a.txt"])
        XCTAssertEqual(restored.children(ScanTree.root).map { restored.name($0) }, ["movie.mov", "docs", "Locked"])
        let b = try XCTUnwrap(restored.index(ofPath: "/scan/docs/b.txt"))
        XCTAssertEqual(restored.flags(b), [.hardLinkDuplicate])
        XCTAssertEqual(restored.modifiedDate(b), Date(timeIntervalSince1970: 4000))
        XCTAssertEqual(restored.flags(try XCTUnwrap(restored.index(ofPath: "/scan/Locked"))), [.inaccessible])
    }

    func testRemovedItemsAreLeftOutOfTheFile() throws {
        let tree = sampleTree()
        tree.detach(try XCTUnwrap(tree.index(ofPath: "/scan/docs")))
        let restored = ScanTree(snapshot: try ScanSnapshot(decoding: tree.snapshot(scannedAt: Date()).encoded()))
        XCTAssertEqual(restored.count, 3)
        XCTAssertNil(restored.index(ofPath: "/scan/docs/a.txt"))
        XCTAssertEqual(restored.size(ScanTree.root), 600)
        XCTAssertNotNil(restored.index(ofPath: "/scan/movie.mov"))
    }

    func testCacheSavesAndLoadsByRoot() throws {
        let cache = ScanCache(directory: folder)
        XCTAssertNil(cache.load(root: "/scan"))
        let snapshot = sampleTree().snapshot(scannedAt: Date(timeIntervalSince1970: 42))
        try cache.save(snapshot)
        XCTAssertEqual(cache.load(root: "/scan"), snapshot)
        XCTAssertEqual(cache.load(root: "/scan/"), snapshot)
        XCTAssertNil(cache.load(root: "/other"))
        XCTAssertNotEqual(cache.filePath(forRoot: "/scan"), cache.filePath(forRoot: "/other"))
        cache.remove(root: "/scan")
        XCTAssertNil(cache.load(root: "/scan"))
    }

    func testRejectsOtherVersionsAndDamagedFiles() throws {
        var bytes = [UInt8](sampleTree().snapshot(scannedAt: Date()).encoded())
        XCTAssertThrowsError(try ScanSnapshot(decoding: Data(bytes.prefix(bytes.count - 3)))) { error in
            XCTAssertEqual(error as? ScanCacheError, .damaged)
        }
        bytes[4] = 99
        XCTAssertThrowsError(try ScanSnapshot(decoding: Data(bytes))) { error in
            XCTAssertEqual(error as? ScanCacheError, .otherVersion)
        }
        XCTAssertThrowsError(try ScanSnapshot(decoding: Data("hello".utf8))) { error in
            XCTAssertEqual(error as? ScanCacheError, .notACacheFile)
        }

        let cache = ScanCache(directory: folder)
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        try Data("junk".utf8).write(to: URL(fileURLWithPath: cache.filePath(forRoot: "/scan")))
        XCTAssertNil(cache.load(root: "/scan"))
    }

    func testReplaceSubtreeSplicesAFreshScanAndUpdatesTotals() throws {
        let tree = sampleTree()
        let docs = try XCTUnwrap(tree.index(ofPath: "/scan/docs"))
        let oldA = try XCTUnwrap(tree.index(ofPath: "/scan/docs/a.txt"))

        // The folder now holds b.txt (50), a new folder with c.bin (2000) and nothing else.
        let fresh = ScanTree(rootPath: "/scan/docs", size: 0, modified: 9000)
        fresh.append(name: "b.txt", parent: ScanTree.root, kind: .file, size: 50, modified: 9100, flags: [])
        let sub = fresh.append(name: "sub", parent: ScanTree.root, kind: .directory, size: 0, modified: 9200, flags: [])
        fresh.append(name: "c.bin", parent: sub, kind: .file, size: 2000, modified: 9300, flags: [])
        fresh.finalize()

        tree.replaceSubtree(docs, with: fresh)

        XCTAssertEqual(tree.size(docs), 2050)
        XCTAssertEqual(tree.fileCount(docs), 2)
        XCTAssertEqual(tree.size(ScanTree.root), 2650)
        XCTAssertEqual(tree.fileCount(ScanTree.root), 3)
        XCTAssertEqual(tree.modifiedDate(docs), Date(timeIntervalSince1970: 9000))
        XCTAssertEqual(tree.name(docs), "docs")
        XCTAssertNil(tree.index(ofPath: "/scan/docs/a.txt"))
        XCTAssertTrue(tree.flags(oldA).contains(.removed))
        let c = try XCTUnwrap(tree.index(ofPath: "/scan/docs/sub/c.bin"))
        XCTAssertEqual(tree.size(c), 2000)
        XCTAssertEqual(tree.size(try XCTUnwrap(tree.index(ofPath: "/scan/docs/sub"))), 2000)
        XCTAssertEqual(tree.path(of: c), "/scan/docs/sub/c.bin")
        // Children stay sorted largest first, here and in the parent.
        XCTAssertEqual(tree.children(docs).map { tree.name($0) }, ["sub", "b.txt"])
        XCTAssertEqual(tree.children(ScanTree.root).map { tree.name($0) }, ["docs", "movie.mov", "Locked"])
        XCTAssertEqual(tree.largestFiles(limit: 10).map { tree.name($0) }, ["c.bin", "movie.mov", "b.txt"])

        // The spliced tree saves and loads like any other.
        let restored = ScanTree(snapshot: try ScanSnapshot(decoding: tree.snapshot(scannedAt: Date()).encoded()))
        XCTAssertEqual(restored.size(ScanTree.root), 2650)
        XCTAssertNotNil(restored.index(ofPath: "/scan/docs/sub/c.bin"))
        XCTAssertNil(restored.index(ofPath: "/scan/docs/a.txt"))
    }

    func testReplaceSubtreeWithARealRescan() async throws {
        let fm = FileManager.default
        let root = DiskScanner.standardize(folder)
        try fm.createDirectory(atPath: root + "/inner", withIntermediateDirectories: true)
        try Data(count: 10_000).write(to: URL(fileURLWithPath: root + "/inner/one"))
        try Data(count: 10_000).write(to: URL(fileURLWithPath: root + "/top"))
        let tree = try await DiskScanner().scan(root: root)
        let inner = try XCTUnwrap(tree.index(ofPath: root + "/inner"))
        let before = tree.size(ScanTree.root)
        let oldInner = tree.size(inner)

        try Data(count: 200_000).write(to: URL(fileURLWithPath: root + "/inner/two"))
        let fresh = try await DiskScanner().scan(root: root + "/inner")
        tree.replaceSubtree(inner, with: fresh)

        XCTAssertNotNil(tree.index(ofPath: root + "/inner/two"))
        XCTAssertEqual(tree.size(inner), fresh.size(ScanTree.root))
        XCTAssertEqual(tree.size(ScanTree.root) - before, fresh.size(ScanTree.root) - oldInner)
        XCTAssertGreaterThan(tree.size(ScanTree.root), before)
        XCTAssertEqual(tree.fileCount(ScanTree.root), 3)
    }
}
