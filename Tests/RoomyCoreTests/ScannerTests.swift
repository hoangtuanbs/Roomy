import XCTest
@testable import RoomyCore

/// DiskScanner and ScanTree on small trees in a temporary folder.
final class ScannerTests: XCTestCase {
    private var root = ""
    private let fm = FileManager.default
    private var locked: [String] = []

    override func setUpWithError() throws {
        let base = fm.temporaryDirectory.appendingPathComponent("RoomyScan-\(UUID().uuidString)")
        try fm.createDirectory(at: base, withIntermediateDirectories: true)
        root = DiskScanner.standardize(base.path)
    }

    override func tearDownWithError() throws {
        for path in locked { try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path) }
        try? fm.removeItem(atPath: root)
    }

    @discardableResult
    private func file(_ relative: String, bytes: Int = 10_000, byte: UInt8 = 1) throws -> String {
        let path = root + "/" + relative
        try fm.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try Data(repeating: byte, count: bytes).write(to: URL(fileURLWithPath: path))
        return path
    }

    private func folder(_ relative: String) throws {
        try fm.createDirectory(atPath: root + "/" + relative, withIntermediateDirectories: true)
    }

    private func scan(_ options: ScanOptions = ScanOptions()) async throws -> ScanTree {
        try await DiskScanner(options: options).scan(root: root)
    }

    private func node(_ tree: ScanTree, _ relative: String) throws -> ScanTree.Index {
        try XCTUnwrap(tree.index(ofPath: root + "/" + relative), relative)
    }

    private func allocated(_ path: String) -> Int64 {
        DirectoryReader.entry(atPath: path)?.allocated ?? -1
    }

    // MARK: Sizes

    func testSizesAreSpaceOnDiskAndAddUpThroughFolders() async throws {
        try file("a.bin", bytes: 10_000)
        try file("sub/b.bin", bytes: 50_000)
        try file("sub/empty.txt", bytes: 0)
        try folder("sub/nothing")

        let tree = try await scan()

        XCTAssertEqual(tree.rootPath, root)
        XCTAssertEqual(tree.fileCount(ScanTree.root), 3)
        XCTAssertEqual(tree.fileCount(try node(tree, "sub")), 2)
        XCTAssertEqual(tree.fileCount(try node(tree, "sub/nothing")), 0)
        let b = try node(tree, "sub/b.bin")
        XCTAssertEqual(tree.size(b), allocated(root + "/sub/b.bin"))
        XCTAssertGreaterThanOrEqual(tree.size(b), 50_000, "Space on disk is whole blocks")
        XCTAssertEqual(tree.kind(b), .file)

        // Every folder is its own entry plus everything inside it.
        for i in 0..<ScanTree.Index(tree.count) where tree.kind(i).isContainer {
            let own = allocated(tree.path(of: i))
            let inside = tree.children(i).reduce(Int64(0)) { $0 + tree.size($1) }
            XCTAssertEqual(tree.size(i), own + inside, tree.path(of: i))
        }
    }

    func testSparseFilesCountTheSpaceTheyUseNotTheirLength() async throws {
        let path = root + "/sparse.img"
        XCTAssertTrue(fm.createFile(atPath: path, contents: nil))
        let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
        try handle.seek(toOffset: 64 * 1_024 * 1_024)
        try handle.write(contentsOf: Data([1]))
        try handle.close()
        let entry = try XCTUnwrap(DirectoryReader.entry(atPath: path))
        XCTAssertEqual(entry.length, 64 * 1_024 * 1_024 + 1)
        try XCTSkipIf(entry.allocated >= entry.length, "This file system does not keep sparse files")

        let tree = try await scan()
        let size = tree.size(try node(tree, "sparse.img"))
        XCTAssertEqual(size, entry.allocated)
        XCTAssertLessThan(size, 1_024 * 1_024)
    }

    func testHardLinksAreCountedOnce() async throws {
        let original = try file("one/movie.mov", bytes: 200_000)
        try folder("two")
        try fm.linkItem(atPath: original, toPath: root + "/two/movie link.mov")
        try fm.linkItem(atPath: original, toPath: root + "/two/third.mov")

        let tree = try await scan()
        let copies = try ["one/movie.mov", "two/movie link.mov", "two/third.mov"].map { try node(tree, $0) }
        let counted = copies.filter { !tree.flags($0).contains(.hardLinkDuplicate) }
        XCTAssertEqual(counted.count, 1, "Exactly one link carries the size")
        XCTAssertEqual(tree.size(counted[0]), allocated(original))
        for duplicate in copies where duplicate != counted[0] {
            XCTAssertEqual(tree.size(duplicate), 0)
            XCTAssertTrue(tree.flags(duplicate).contains(.hardLinkDuplicate))
        }
        let total = copies.reduce(Int64(0)) { $0 + tree.size($1) }
        XCTAssertEqual(total, allocated(original))
        XCTAssertEqual(tree.fileCount(ScanTree.root), 3, "Every name is still listed")
    }

    func testSymbolicLinksAreListedButNeverFollowed() async throws {
        try file("big/huge.bin", bytes: 300_000)
        try fm.createSymbolicLink(atPath: root + "/link-to-folder", withDestinationPath: root + "/big")
        try fm.createSymbolicLink(atPath: root + "/link-to-file", withDestinationPath: root + "/big/huge.bin")
        try fm.createSymbolicLink(atPath: root + "/link-outside", withDestinationPath: "/usr")
        try fm.createSymbolicLink(atPath: root + "/broken", withDestinationPath: root + "/nowhere")
        try fm.createSymbolicLink(atPath: root + "/loop", withDestinationPath: root + "/loop")

        let tree = try await scan()
        for name in ["link-to-folder", "link-to-file", "link-outside", "broken", "loop"] {
            let link = try node(tree, name)
            XCTAssertEqual(tree.kind(link), .symlink, name)
            XCTAssertTrue(tree.children(link).isEmpty, name)
            XCTAssertLessThan(tree.size(link), 100_000, name)
        }
        XCTAssertNil(tree.index(ofPath: root + "/link-to-folder/huge.bin"))
        XCTAssertEqual(tree.count, 8, "root, big, huge.bin and five links")
    }

    func testARootThatIsALinkIsNotFollowed() async throws {
        try folder("real")
        try fm.createSymbolicLink(atPath: root + "/link", withDestinationPath: root + "/real")
        do {
            _ = try await DiskScanner().scan(root: root + "/link")
            XCTFail("A link is not a folder")
        } catch let error as ScanError {
            XCTAssertEqual(error, .notADirectory(root + "/link"))
        }
    }

    // MARK: Problems

    func testUnreadableFoldersAreMarkedAndSkipped() async throws {
        try XCTSkipIf(getuid() == 0, "root can read every folder")
        try file("secret/inner/hidden.bin", bytes: 40_000)
        try file("open/visible.bin", bytes: 5_000)
        let secret = root + "/secret"
        locked.append(secret)
        try fm.setAttributes([.posixPermissions: 0o000], ofItemAtPath: secret)

        let tree = try await scan()

        let secretNode = try node(tree, "secret")
        XCTAssertTrue(tree.flags(secretNode).contains(.inaccessible))
        XCTAssertTrue(tree.children(secretNode).isEmpty)
        XCTAssertEqual(tree.fileCount(secretNode), 0)
        XCTAssertNotNil(tree.index(ofPath: root + "/open/visible.bin"), "The rest is still scanned")
        XCTAssertFalse(tree.flags(ScanTree.root).contains(.inaccessible))
    }

    func testMissingRootsAndFilesAreErrors() async throws {
        let notAFolder = try file("plain.txt")
        do {
            _ = try await DiskScanner().scan(root: root + "/missing")
            XCTFail("expected an error")
        } catch let error as ScanError {
            XCTAssertEqual(error, .notFound(root + "/missing"))
            XCTAssertTrue(error.errorDescription?.contains(root + "/missing") ?? false)
        }
        do {
            _ = try await DiskScanner().scan(root: notAFolder)
            XCTFail("expected an error")
        } catch let error as ScanError {
            XCTAssertEqual(error, .notADirectory(notAFolder))
        }
    }

    func testCancellingStopsTheScan() async throws {
        for i in 0..<20 { try file("f\(i)/x.bin", bytes: 100) }
        let root = self.root
        let task = Task { () async throws -> ScanTree in
            withUnsafeCurrentTask { $0?.cancel() }
            return try await DiskScanner().scan(root: root)
        }
        do {
            _ = try await task.value
            XCTFail("A cancelled scan must not return a tree")
        } catch {
            XCTAssertTrue(error is CancellationError, "\(error)")
        }
    }

    // MARK: Shape

    func testChildrenAreLargestFirstAndBiggestFilesAreFound() async throws {
        try file("medium.bin", bytes: 20_000)
        try file("small.bin", bytes: 5_000)
        try file("folder/large.bin", bytes: 80_000)
        try file("folder/tiny.bin", bytes: 1_000)
        try file("zero.bin", bytes: 0)

        let tree = try await scan()

        let names = tree.children(ScanTree.root).map(tree.name)
        XCTAssertEqual(names.first, "folder")
        let sizes = tree.children(ScanTree.root).map(tree.size)
        XCTAssertEqual(sizes, sizes.sorted(by: >))

        let largest = tree.largestFiles(limit: 3).map(tree.name)
        XCTAssertEqual(largest, ["large.bin", "medium.bin", "small.bin"])
        XCTAssertEqual(tree.largestFiles(limit: 100).count, 4, "Empty files are left out")
        XCTAssertEqual(tree.largestFiles(limit: 0), [])

        let large = try node(tree, "folder/large.bin")
        let before = tree.size(ScanTree.root)
        let folderBefore = tree.size(try node(tree, "folder"))
        tree.detach(large)
        XCTAssertEqual(tree.size(ScanTree.root), before - allocated(root + "/folder/large.bin"))
        XCTAssertEqual(tree.size(try node(tree, "folder")), folderBefore - allocated(root + "/folder/large.bin"))
        XCTAssertEqual(tree.fileCount(ScanTree.root), 4)
        XCTAssertFalse(tree.largestFiles(limit: 10).contains(large))
        XCTAssertNil(tree.index(ofPath: root + "/folder/large.bin"))
        tree.detach(large)
        XCTAssertEqual(tree.fileCount(ScanTree.root), 4, "Detaching twice changes nothing")
        tree.detach(ScanTree.root)
        XCTAssertEqual(tree.fileCount(ScanTree.root), 4, "The root cannot be detached")
    }

    func testAnEmptyFolder() async throws {
        let tree = try await scan()
        XCTAssertEqual(tree.count, 1)
        XCTAssertEqual(tree.fileCount(ScanTree.root), 0)
        XCTAssertEqual(tree.children(ScanTree.root), [])
        XCTAssertEqual(tree.size(ScanTree.root), allocated(root))
        XCTAssertEqual(tree.largestFiles(limit: 5), [])
        XCTAssertNil(tree.parent(ScanTree.root))
        XCTAssertEqual(tree.path(of: ScanTree.root), root)
        XCTAssertEqual(tree.index(ofPath: root), ScanTree.root)
    }

    func testDeepNesting() async throws {
        let depth = 100
        let relative = Array(repeating: "d", count: depth).joined(separator: "/")
        try file(relative + "/bottom.bin", bytes: 3_000)

        let tree = try await scan()

        let bottom = try node(tree, relative + "/bottom.bin")
        XCTAssertEqual(tree.path(of: bottom), root + "/" + relative + "/bottom.bin")
        XCTAssertEqual(tree.lineage(of: bottom).count, depth + 2)
        XCTAssertEqual(tree.lineage(of: bottom).first, ScanTree.root)
        XCTAssertTrue(tree.isAncestor(ScanTree.root, of: bottom))
        XCTAssertFalse(tree.isAncestor(bottom, of: ScanTree.root))
        XCTAssertEqual(tree.fileCount(ScanTree.root), 1)
        XCTAssertTrue(tree.containsDescendant(named: "bottom.bin", under: ScanTree.root))
        XCTAssertFalse(tree.containsDescendant(named: "nope", under: ScanTree.root))
        XCTAssertGreaterThan(tree.size(try node(tree, "d")), tree.size(bottom))
    }

    func testPackagesAndExcludedFolders() async throws {
        try file("Tool.app/Contents/MacOS/Tool", bytes: 30_000)
        try file("Archive.PKG/payload", bytes: 1_000)
        try file("skip/inside.bin", bytes: 30_000)
        try file("keep/inside.bin", bytes: 1_000)

        let tree = try await scan(ScanOptions(excludedPaths: [root + "/skip"]))

        let app = try node(tree, "Tool.app")
        XCTAssertEqual(tree.kind(app), .package)
        XCTAssertNotNil(tree.index(ofPath: root + "/Tool.app/Contents/MacOS/Tool"), "Packages are still measured inside")
        XCTAssertEqual(tree.kind(try node(tree, "Archive.PKG")), .package)
        let skip = try node(tree, "skip")
        XCTAssertTrue(tree.flags(skip).contains(.excluded))
        XCTAssertTrue(tree.children(skip).isEmpty)
        XCTAssertNotNil(tree.index(ofPath: root + "/keep/inside.bin"))
    }

    func testProgressEndsWithTheTotals() async throws {
        try file("a.bin", bytes: 4_000)
        try file("b/c.bin", bytes: 4_000)
        final class Box: @unchecked Sendable {
            let lock = NSLock()
            var reports: [ScanProgress] = []
        }
        let box = Box()

        let again = try await DiskScanner(options: ScanOptions(progressInterval: .zero)).scan(root: root) { progress in
            box.lock.lock()
            box.reports.append(progress)
            box.lock.unlock()
        }

        let last = try XCTUnwrap(box.reports.last)
        XCTAssertEqual(last.files, 2)
        XCTAssertEqual(last.directories, 2)
        XCTAssertEqual(last.currentPath, root)
        XCTAssertEqual(last.bytes, again.size(ScanTree.root) - allocated(root))
        let files = box.reports.map(\.files)
        XCTAssertEqual(files, files.sorted(), "Counts only grow")
    }

    func testOneReaderGivesTheSameTreeAsMany() async throws {
        for i in 0..<15 { try file("f\(i % 4)/g\(i)/x\(i).bin", bytes: 1_000 * (i + 1)) }
        let one = try await scan(ScanOptions(maxConcurrentReads: 1))
        let many = try await scan(ScanOptions(maxConcurrentReads: 16))
        XCTAssertEqual(one.count, many.count)
        XCTAssertEqual(one.size(ScanTree.root), many.size(ScanTree.root))
        XCTAssertEqual(one.fileCount(ScanTree.root), many.fileCount(ScanTree.root))
        for i in 0..<ScanTree.Index(one.count) {
            let path = one.path(of: i)
            let j = try XCTUnwrap(many.index(ofPath: path), path)
            XCTAssertEqual(one.size(i), many.size(j), path)
        }
    }

    // MARK: Tree edits

    func testInsertingAFileUpdatesEveryFolderAbove() async throws {
        try file("a/b/x.bin", bytes: 2_000)
        try file("big.bin", bytes: 50_000)
        let tree = try await scan()
        let b = try node(tree, "a/b")
        let rootSize = tree.size(ScanTree.root)
        let aSize = tree.size(try node(tree, "a"))

        let added = tree.insertFile(named: "x.zip", in: b, size: 1_000_000, modified: Date(timeIntervalSince1970: 1_700_000_000))

        XCTAssertEqual(tree.path(of: added), root + "/a/b/x.zip")
        XCTAssertEqual(tree.size(ScanTree.root), rootSize + 1_000_000)
        XCTAssertEqual(tree.size(try node(tree, "a")), aSize + 1_000_000)
        XCTAssertEqual(tree.fileCount(ScanTree.root), 3)
        XCTAssertEqual(tree.children(b).first, added, "Largest first")
        XCTAssertEqual(tree.modifiedDate(added), Date(timeIntervalSince1970: 1_700_000_000))
        XCTAssertEqual(tree.largestFiles(limit: 1), [added])
    }

    // MARK: Helpers

    func testPackageNames() {
        XCTAssertTrue(PackageTypes.isPackage(name: "Safari.app"))
        XCTAssertTrue(PackageTypes.isPackage(name: "Safari.APP"))
        XCTAssertTrue(PackageTypes.isPackage(name: "Photos Library.photoslibrary"))
        XCTAssertTrue(PackageTypes.isPackage(name: "a.b.framework"))
        XCTAssertFalse(PackageTypes.isPackage(name: ".app"))
        XCTAssertFalse(PackageTypes.isPackage(name: "app"))
        XCTAssertFalse(PackageTypes.isPackage(name: "notes.txt"))
        XCTAssertFalse(PackageTypes.isPackage(name: "Safari.app.zip"))
        XCTAssertFalse(PackageTypes.isPackage(name: "trailing."))
    }

    func testStandardizeAndJoin() {
        XCTAssertEqual(DiskScanner.standardize("/a/b/"), "/a/b")
        XCTAssertEqual(DiskScanner.standardize("/a//b///"), "/a/b")
        XCTAssertEqual(DiskScanner.standardize("/a/./b/../c"), "/a/c")
        XCTAssertEqual(DiskScanner.standardize("/"), "/")
        XCTAssertEqual(DiskScanner.standardize("~"), DiskScanner.standardize(NSHomeDirectory()))
        XCTAssertEqual(DiskScanner.join("/", "a"), "/a")
        XCTAssertEqual(DiskScanner.join("/a", "b"), "/a/b")
    }
}
