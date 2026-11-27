import XCTest
@testable import RoomyCore

/// Cloud-only (dataless) files cannot be made on a build machine, so the check and the scanner's rules are tested
/// with the flags they would have.
final class CloudPlaceholderTests: XCTestCase {
    private let dataless = CloudPlaceholder.datalessFlag

    func testTheDatalessFlagMarksFilesAndFolders() {
        XCTAssertTrue(CloudPlaceholder.isDataless(flags: dataless, allocated: 0, length: 5_000_000, isDirectory: false, inCloudFolder: false))
        XCTAssertTrue(CloudPlaceholder.isDataless(flags: dataless | 0x20, allocated: 0, length: 0, isDirectory: true, inCloudFolder: false))
        XCTAssertFalse(CloudPlaceholder.isDataless(flags: 0, allocated: 4096, length: 100, isDirectory: false, inCloudFolder: true))
        XCTAssertFalse(CloudPlaceholder.isDataless(flags: 0x8000, allocated: 0, length: 0, isDirectory: false, inCloudFolder: true),
                       "Other flags (here UF_COMPRESSED) are not cloud-only")
    }

    func testFilesWithoutBlocksCountOnlyInCloudFolders() {
        // A compressed system file can also have no blocks, so outside cloud folders that means nothing.
        XCTAssertFalse(CloudPlaceholder.isDataless(flags: 0, allocated: 0, length: 9_000, isDirectory: false, inCloudFolder: false))
        XCTAssertTrue(CloudPlaceholder.isDataless(flags: 0, allocated: 0, length: 9_000, isDirectory: false, inCloudFolder: true))
        XCTAssertFalse(CloudPlaceholder.isDataless(flags: 0, allocated: 0, length: 0, isDirectory: false, inCloudFolder: true),
                       "An empty file is just empty")
        XCTAssertFalse(CloudPlaceholder.isDataless(flags: 0, allocated: 0, length: 9_000, isDirectory: true, inCloudFolder: true))
    }

    func testCloudFolders() {
        XCTAssertTrue(CloudPlaceholder.isInCloudFolder("/Users/a/Library/Mobile Documents"))
        XCTAssertTrue(CloudPlaceholder.isInCloudFolder("/Users/a/Library/Mobile Documents/com~apple~CloudDocs/Notes"))
        XCTAssertTrue(CloudPlaceholder.isInCloudFolder("/Users/a/Library/CloudStorage/Dropbox/x"))
        XCTAssertFalse(CloudPlaceholder.isInCloudFolder("/Users/a/Library/Mobile Documents Old"))
        XCTAssertFalse(CloudPlaceholder.isInCloudFolder("/Users/a/Documents"))
        XCTAssertFalse(CloudPlaceholder.isInCloudFolder("/Users/a/Library/CloudStorageBackup/x"))
    }

    private func entry(_ name: String, kind: NodeKind, allocated: Int64, length: Int64, flags: UInt32) -> RawEntry {
        RawEntry(name: name, kind: kind, allocated: allocated, length: length, device: 1, inode: 42, linkCount: 1,
                 modified: 0, fileFlags: flags)
    }

    func testTheScannerCountsCloudOnlyFilesAsNoSpace() {
        let rules = EntryRules(root: "/scan", rootDevice: 1, options: ScanOptions())
        var counter = SpaceCounter()
        let file = rules.classify(entry("film.mov", kind: .file, allocated: 0, length: 3_000_000_000, flags: dataless),
                                  path: "/scan/film.mov", inCloudFolder: false, counter: &counter)
        XCTAssertEqual(file.size, 0)
        XCTAssertTrue(file.flags.contains(.dataless))
        XCTAssertEqual(file.onlineBytes, 3_000_000_000)
        XCTAssertFalse(file.descend)

        let folder = rules.classify(entry("Old Projects", kind: .directory, allocated: 0, length: 96, flags: dataless),
                                    path: "/scan/Old Projects", inCloudFolder: false, counter: &counter)
        XCTAssertTrue(folder.flags.contains(.dataless))
        XCTAssertFalse(folder.descend, "A cloud-only folder is not opened, which could make macOS fetch it")
        XCTAssertNil(folder.onlineBytes)

        let local = rules.classify(entry("here.mov", kind: .file, allocated: 8192, length: 8000, flags: 0),
                                   path: "/scan/here.mov", inCloudFolder: true, counter: &counter)
        XCTAssertEqual(local.size, 8192)
        XCTAssertFalse(local.flags.contains(.dataless))
    }

    func testCloudOnlySizesSurviveTheCacheAndAreNotBiggestFiles() throws {
        let tree = ScanTree(rootPath: "/scan", size: 0, modified: 0)
        let cloud = tree.append(name: "film.mov", parent: ScanTree.root, kind: .file, size: 0, modified: 0, flags: [.dataless])
        tree.setOnlineSize(3_000_000_000, at: cloud)
        let folder = tree.append(name: "docs", parent: ScanTree.root, kind: .directory, size: 0, modified: 0, flags: [])
        tree.append(name: "here.txt", parent: folder, kind: .file, size: 4096, modified: 0, flags: [])
        tree.append(name: "away.txt", parent: folder, kind: .file, size: 0, modified: 0, flags: [.dataless])
        tree.finalize()

        XCTAssertEqual(tree.size(ScanTree.root), 4096)
        XCTAssertEqual(tree.largestFiles(limit: 10).map(tree.name), ["here.txt"])
        XCTAssertEqual(tree.datalessCount(under: ScanTree.root), 2)
        XCTAssertEqual(tree.datalessCount(under: folder), 1)

        let restored = ScanTree(snapshot: try ScanSnapshot(decoding: tree.snapshot(scannedAt: Date()).encoded()))
        let film = try XCTUnwrap(restored.index(ofPath: "/scan/film.mov"))
        XCTAssertEqual(restored.onlineSizes[film], 3_000_000_000)
        XCTAssertTrue(restored.flags(film).contains(.dataless))
    }

    func testDuplicatesNeverReadCloudOnlyFiles() {
        let tree = ScanTree(rootPath: "/scan", size: 0, modified: 0)
        tree.append(name: "a.mov", parent: ScanTree.root, kind: .file, size: 5_000_000, modified: 0, flags: [.dataless])
        tree.finalize()
        XCTAssertTrue(DuplicateFinder().candidates(in: tree, under: ScanTree.root).isEmpty)
    }
}
