import XCTest
@testable import RoomyCore

/// APFS clones made with clonefile() in a temporary folder: their shared blocks count once.
final class CloneTests: XCTestCase {
    private var root = ""
    private let fm = FileManager.default

    override func setUpWithError() throws {
        let base = fm.temporaryDirectory.appendingPathComponent("RoomyClones-\(UUID().uuidString)")
        try fm.createDirectory(at: base, withIntermediateDirectories: true)
        root = DiskScanner.standardize(base.path)
    }

    override func tearDownWithError() throws {
        try? fm.removeItem(atPath: root)
    }

    @discardableResult
    private func file(_ relative: String, bytes: Int, byte: UInt8 = 7) throws -> String {
        let path = root + "/" + relative
        try fm.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try Data(repeating: byte, count: bytes).write(to: URL(fileURLWithPath: path))
        return path
    }

    /// Clones `source` to `relative`, or skips the test where the disk has no clones.
    private func clone(_ source: String, to relative: String) throws -> String {
        let path = root + "/" + relative
        try fm.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        #if canImport(Darwin)
        guard clonefile(source, path, 0) == 0 else { throw XCTSkip("This disk cannot clone files (errno \(errno))") }
        #else
        throw XCTSkip("Clones need APFS")
        #endif
        return path
    }

    private func allocated(_ path: String) -> Int64 { DirectoryReader.entry(atPath: path)?.allocated ?? -1 }

    private func node(_ tree: ScanTree, _ relative: String) throws -> ScanTree.Index {
        try XCTUnwrap(tree.index(ofPath: root + "/" + relative), relative)
    }

    /// What the reader says about each file of a folder, printed so a failing run shows what APFS answered.
    private func describe(_ folder: String) -> String {
        (DirectoryReader.list(path: folder, clones: true) ?? []).map { entry in
            "\(entry.name): allocated \(entry.allocated), clone \(entry.clone.map { "id \($0.id) private \($0.privateBytes)" } ?? "none")"
        }.joined(separator: "; ")
    }

    func testPureClonesAreCountedOnce() async throws {
        let original = try file("a/original.bin", bytes: 1_048_576)
        _ = try clone(original, to: "a/copy.bin")
        _ = try clone(original, to: "b/second copy.bin")
        print("clones: \(describe(root + "/a")) | \(describe(root + "/b"))")

        let tree = try await DiskScanner().scan(root: root)

        let files = try ["a/original.bin", "a/copy.bin", "b/second copy.bin"].map { try node(tree, $0) }
        let one = allocated(original)
        XCTAssertGreaterThanOrEqual(one, 1_048_576)
        for file in files {
            XCTAssertTrue(tree.flags(file).contains(.clone), tree.path(of: file))
            XCTAssertEqual(tree.clones[file]?.sharedBytes, one, tree.path(of: file))
            XCTAssertEqual(tree.cloneSiblingCount(file), 2, tree.path(of: file))
        }
        let sizes = files.map { tree.size($0) }
        XCTAssertEqual(sizes.reduce(0, +), one, "The shared blocks count once: \(sizes)")
        XCTAssertEqual(sizes.filter { $0 == one }.count, 1, "The first one found carries them: \(sizes)")
        XCTAssertEqual(tree.fileCount(ScanTree.root), 3, "Every clone is still listed")
        let folders = try ["a", "b"].map { tree.size(try node(tree, $0)) }.reduce(0, +)
        XCTAssertEqual(folders, one, "Folder totals add up to one copy")
    }

    func testCloneDetectionCanBeTurnedOff() async throws {
        let original = try file("original.bin", bytes: 524_288)
        _ = try clone(original, to: "copy.bin")
        let tree = try await DiskScanner(options: ScanOptions(detectClones: false)).scan(root: root)
        let copy = try node(tree, "copy.bin")
        XCTAssertFalse(tree.flags(copy).contains(.clone))
        XCTAssertEqual(tree.size(copy), allocated(root + "/copy.bin"))
    }

    func testAChangedCloneOwnsOnlyWhatChanged() async throws {
        let original = try file("original.bin", bytes: 2_097_152)
        let copy = try clone(original, to: "copy.bin")
        let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: copy))
        try handle.write(contentsOf: Data(repeating: 9, count: 131_072))
        try handle.synchronize()
        try handle.close()
        print("changed clone: \(describe(root))")

        let entry = try XCTUnwrap(DirectoryReader.list(path: root, clones: true)?.first { $0.name == "copy.bin" })
        let info = try XCTUnwrap(entry.clone, "The changed copy still shares blocks")
        XCTAssertGreaterThanOrEqual(info.privateBytes, 131_072)
        XCTAssertLessThan(info.privateBytes, entry.allocated)

        let tree = try await DiskScanner().scan(root: root)
        XCTAssertTrue(tree.flags(try node(tree, "copy.bin")).contains(.clone))
        XCTAssertLessThanOrEqual(tree.size(ScanTree.root), allocated(original) + entry.allocated + allocated(root))
    }

    func testFilesThatWereNeverClonedAreNotClones() async throws {
        try file("plain.bin", bytes: 300_000)
        try file("other.bin", bytes: 300_000)
        XCTAssertTrue((DirectoryReader.list(path: root, clones: true) ?? []).allSatisfy { $0.clone == nil })
        let tree = try await DiskScanner().scan(root: root)
        XCTAssertTrue(tree.clones.isEmpty)
        XCTAssertEqual(tree.size(try node(tree, "plain.bin")), allocated(root + "/plain.bin"))
    }

    func testAnOriginalWhoseCloneIsGoneIsNoLongerAClone() async throws {
        let original = try file("original.bin", bytes: 524_288)
        let copy = try clone(original, to: "copy.bin")
        try fm.removeItem(atPath: copy)
        let tree = try await DiskScanner().scan(root: root)
        let node = try node(tree, "original.bin")
        XCTAssertFalse(tree.flags(node).contains(.clone), describe(root))
        XCTAssertEqual(tree.size(node), allocated(original))
    }

    func testClonesSurviveTheCacheAndSubtreeRescans() async throws {
        let original = try file("a/original.bin", bytes: 524_288)
        _ = try clone(original, to: "b/copy.bin")
        let tree = try await DiskScanner().scan(root: root)
        let restored = ScanTree(snapshot: try ScanSnapshot(decoding: tree.snapshot(scannedAt: Date()).encoded()))
        for name in ["a/original.bin", "b/copy.bin"] {
            let before = try node(tree, name), after = try node(restored, name)
            XCTAssertEqual(restored.clones[after], tree.clones[before], name)
            XCTAssertTrue(restored.flags(after).contains(.clone), name)
        }
        XCTAssertEqual(restored.cloneSiblingCount(try node(restored, "b/copy.bin")), 1)

        let total = restored.size(ScanTree.root)
        for folder in ["a", "b"] {
            let index = try node(restored, folder)
            let fresh = try await DiskScanner().scan(root: root + "/" + folder,
                                                     cloneFamilies: restored.cloneFamilies(carriedOutside: index))
            restored.replaceSubtree(index, with: fresh)
            XCTAssertEqual(restored.size(ScanTree.root), total, "Rescanning \(folder) keeps the shared space counted once")
        }
        XCTAssertNotNil(restored.clones[try node(restored, "b/copy.bin")])
        XCTAssertEqual(restored.cloneSiblingCount(try node(restored, "a/original.bin")), 1)
    }

    func testTrashingTheCloneThatCarriesTheSpaceMovesItToTheOther() async throws {
        let original = try file("a/original.bin", bytes: 524_288)
        _ = try clone(original, to: "b/copy.bin")
        let tree = try await DiskScanner().scan(root: root)
        let total = tree.size(ScanTree.root)
        let files = try ["a/original.bin", "b/copy.bin"].map { try node(tree, $0) }
        let carrier = try XCTUnwrap(files.first { tree.clones[$0]?.carriesShared == true })
        let other = try XCTUnwrap(files.first { $0 != carrier })
        let otherBefore = tree.size(other)
        tree.detach(carrier)
        XCTAssertEqual(tree.clones[other]?.carriesShared, true)
        let shared = try XCTUnwrap(tree.clones[other]?.sharedBytes)
        XCTAssertEqual(tree.size(other), otherBefore + shared)
        XCTAssertEqual(tree.size(ScanTree.root), total, "Pure clones: the carrier had no space of its own")
    }
}
