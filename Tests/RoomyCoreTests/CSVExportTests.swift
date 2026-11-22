import XCTest
@testable import RoomyCore

final class CSVExportTests: XCTestCase {
    func testFieldQuoting() {
        XCTAssertEqual(CSV.field("plain"), "plain")
        XCTAssertEqual(CSV.field("a,b"), "\"a,b\"")
        XCTAssertEqual(CSV.field("say \"hi\""), "\"say \"\"hi\"\"\"")
        XCTAssertEqual(CSV.field("two\nlines"), "\"two\nlines\"")
        XCTAssertEqual(CSV.field("cr\rhere"), "\"cr\rhere\"")
        XCTAssertEqual(CSV.field(""), "")
        XCTAssertEqual(CSV.line(["a", "b,c", ""]), "a,\"b,c\",")
    }

    func testChildrenOnlyByDefault() throws {
        let tree = ScanTree(rootPath: "/scan", size: 0, modified: 1000)
        let docs = tree.append(name: "docs", parent: ScanTree.root, kind: .directory, size: 0, modified: 2000, flags: [])
        tree.append(name: "a, \"notes\".txt", parent: docs, kind: .file, size: 100, modified: 3000, flags: [])
        tree.append(name: "movie.mov", parent: ScanTree.root, kind: .file, size: 600, modified: 4000, flags: [])
        tree.append(name: "old", parent: ScanTree.root, kind: .file, size: 5, modified: 4000, flags: [.removed])
        tree.finalize()

        let csv = TreeCSV.export(tree: tree, folder: ScanTree.root)
        let lines = csv.split(separator: "\n", omittingEmptySubsequences: false)
        XCTAssertEqual(lines.count, 4, csv)
        XCTAssertEqual(String(lines[0]), "path,name,kind,category,size_bytes,size_human,modified,items")
        // Largest first, so movie.mov comes before docs.
        XCTAssertEqual(String(lines[1]), "/scan/movie.mov,movie.mov,file,video,600,600 bytes,1970-01-01T01:06:40Z,")
        XCTAssertEqual(String(lines[2]), "/scan/docs,docs,folder,folder,100,100 bytes,1970-01-01T00:33:20Z,1")
        XCTAssertEqual(lines[3], "")
        XCTAssertFalse(csv.contains("/scan/old"))
    }

    func testDescendantsUpToDepthAndQuotedNames() {
        let tree = ScanTree(rootPath: "/scan", size: 0, modified: 1000)
        let a = tree.append(name: "a", parent: ScanTree.root, kind: .directory, size: 0, modified: 1000, flags: [])
        let b = tree.append(name: "b", parent: a, kind: .directory, size: 0, modified: 1000, flags: [])
        tree.append(name: "deep \"one\".txt", parent: b, kind: .file, size: 1, modified: 1000, flags: [])
        tree.finalize()

        let oneLevel = TreeCSV.export(tree: tree, folder: ScanTree.root, depth: 1)
        XCTAssertEqual(oneLevel.split(separator: "\n").count, 2)

        let twoLevels = TreeCSV.export(tree: tree, folder: ScanTree.root, depth: 2)
        XCTAssertEqual(twoLevels.split(separator: "\n").count, 3)
        XCTAssertFalse(twoLevels.contains("deep \"one\".txt"))

        let all = TreeCSV.export(tree: tree, folder: ScanTree.root, depth: 3)
        XCTAssertTrue(all.contains("\"/scan/a/b/deep \"\"one\"\".txt\""), all)
    }
}
