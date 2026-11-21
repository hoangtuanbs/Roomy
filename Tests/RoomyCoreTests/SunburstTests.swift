import XCTest
@testable import RoomyCore

final class SunburstTests: XCTestCase {
    /// /r: big (600 bytes: x 400, deep/y 200), file 399, tiny 1, empty folder.
    private func tree() -> ScanTree {
        let tree = ScanTree(rootPath: "/r", size: 0, modified: 0)
        let big = tree.append(name: "big", parent: ScanTree.root, kind: .directory, size: 0, modified: 0, flags: [])
        tree.append(name: "x", parent: big, kind: .file, size: 400, modified: 0, flags: [])
        let deep = tree.append(name: "deep", parent: big, kind: .directory, size: 0, modified: 0, flags: [])
        tree.append(name: "y", parent: deep, kind: .file, size: 200, modified: 0, flags: [])
        tree.append(name: "file", parent: ScanTree.root, kind: .file, size: 399, modified: 0, flags: [])
        tree.append(name: "tiny", parent: ScanTree.root, kind: .file, size: 1, modified: 0, flags: [])
        tree.append(name: "empty", parent: ScanTree.root, kind: .directory, size: 0, modified: 0, flags: [])
        tree.finalize()
        return tree
    }

    private func names(_ arcs: [SunburstArc], _ tree: ScanTree) -> [String] { arcs.map { tree.name($0.node) } }

    func testAnglesFollowSizesAndRingsFollowDepth() {
        let t = tree()
        let arcs = Sunburst.layout(tree: t, center: ScanTree.root, maxDepth: 4, minSpan: 0)
        XCTAssertEqual(names(arcs, t), ["big", "file", "tiny", "x", "deep", "y"])
        XCTAssertEqual(arcs.map(\.depth), [1, 1, 1, 2, 2, 3])
        let big = arcs[0], file = arcs[1], x = arcs[3], deep = arcs[4], y = arcs[5]
        XCTAssertEqual(big.start, 0, accuracy: 1e-12)
        XCTAssertEqual(big.end, 0.6, accuracy: 1e-12)
        XCTAssertEqual(file.start, 0.6, accuracy: 1e-12)
        XCTAssertEqual(file.span, 0.399, accuracy: 1e-12)
        XCTAssertEqual(arcs[2].end, 1, accuracy: 1e-12)
        // Children share their parent's angle, in proportion to their size.
        XCTAssertEqual(x.start, 0, accuracy: 1e-12)
        XCTAssertEqual(x.end, 0.4, accuracy: 1e-12)
        XCTAssertEqual(deep.start, 0.4, accuracy: 1e-12)
        XCTAssertEqual(deep.end, 0.6, accuracy: 1e-12)
        XCTAssertEqual(y.start, deep.start, accuracy: 1e-12)
        XCTAssertEqual(y.end, deep.end, accuracy: 1e-12)
    }

    func testDepthLimitAndSmallItems() {
        let t = tree()
        let shallow = Sunburst.layout(tree: t, center: ScanTree.root, maxDepth: 2, minSpan: 0)
        XCTAssertEqual(shallow.map(\.depth).max(), 2)
        XCTAssertFalse(names(shallow, t).contains("y"))
        let filtered = Sunburst.layout(tree: t, center: ScanTree.root, maxDepth: 4, minSpan: 0.01)
        XCTAssertFalse(names(filtered, t).contains("tiny"))
        XCTAssertTrue(Sunburst.layout(tree: t, center: ScanTree.root, maxDepth: 0).isEmpty)
    }

    func testZoomedIntoAFolder() throws {
        let t = tree()
        let big = try XCTUnwrap(t.index(ofPath: "/r/big"))
        let arcs = Sunburst.layout(tree: t, center: big, maxDepth: 3, minSpan: 0)
        XCTAssertEqual(names(arcs, t), ["x", "deep", "y"])
        XCTAssertEqual(arcs[0].span, 400.0 / 600.0, accuracy: 1e-12)
        XCTAssertEqual(arcs.map(\.depth), [1, 1, 2])
    }

    func testHitTesting() throws {
        let t = tree()
        let arcs = Sunburst.layout(tree: t, center: ScanTree.root, maxDepth: 4, minSpan: 0)
        XCTAssertEqual(Sunburst.arc(at: 0.3, depth: 1, in: arcs).map { t.name($0.node) }, "big")
        XCTAssertEqual(Sunburst.arc(at: 0.7, depth: 1, in: arcs).map { t.name($0.node) }, "file")
        XCTAssertEqual(Sunburst.arc(at: 0.5, depth: 3, in: arcs).map { t.name($0.node) }, "y")
        XCTAssertNil(Sunburst.arc(at: 0.7, depth: 2, in: arcs))

        // Top of the chart is fraction 0, the right side a quarter turn, the bottom half a turn.
        let top = try XCTUnwrap(Sunburst.locate(x: 0, y: -50, centerRadius: 20, ringWidth: 10, maxDepth: 4))
        XCTAssertEqual(top.depth, 4)
        XCTAssertEqual(top.fraction, 0, accuracy: 1e-9)
        let right = try XCTUnwrap(Sunburst.locate(x: 25, y: 0, centerRadius: 20, ringWidth: 10, maxDepth: 4))
        XCTAssertEqual(right.depth, 1)
        XCTAssertEqual(right.fraction, 0.25, accuracy: 1e-9)
        let bottom = try XCTUnwrap(Sunburst.locate(x: 0, y: 35, centerRadius: 20, ringWidth: 10, maxDepth: 4))
        XCTAssertEqual(bottom.depth, 2)
        XCTAssertEqual(bottom.fraction, 0.5, accuracy: 1e-9)
        let left = try XCTUnwrap(Sunburst.locate(x: -25, y: 0, centerRadius: 20, ringWidth: 10, maxDepth: 4))
        XCTAssertEqual(left.fraction, 0.75, accuracy: 1e-9)
        XCTAssertEqual(Sunburst.locate(x: 5, y: 5, centerRadius: 20, ringWidth: 10, maxDepth: 4)?.depth, 0)
        XCTAssertNil(Sunburst.locate(x: 100, y: 0, centerRadius: 20, ringWidth: 10, maxDepth: 4))
    }
}
