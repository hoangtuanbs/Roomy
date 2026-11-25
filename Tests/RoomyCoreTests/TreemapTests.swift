import XCTest
#if canImport(CoreGraphics)
import CoreGraphics
#endif
@testable import RoomyCore

final class TreemapTests: XCTestCase {
    private let tolerance = 1e-6

    private func area(_ r: CGRect) -> Double { Double(r.width * r.height) }

    private func overlap(_ a: CGRect, _ b: CGRect) -> Double {
        let w = min(Double(a.maxX), Double(b.maxX)) - max(Double(a.minX), Double(b.minX))
        let h = min(Double(a.maxY), Double(b.maxY)) - max(Double(a.minY), Double(b.minY))
        return w > 0 && h > 0 ? w * h : 0
    }

    /// Every positive value gets a rectangle inside the bounds, with an area in proportion to its value,
    /// the rectangles do not overlap, and together they fill the bounds.
    private func checkLayout(_ values: [Double], in bounds: CGRect, file: StaticString = #filePath, line: UInt = #line) {
        let rects = Treemap.squarify(values: values, in: bounds)
        XCTAssertEqual(rects.count, values.count, file: file, line: line)
        let total = values.filter { $0 > 0 }.reduce(0, +)
        let boundsArea = area(bounds)
        var covered = 0.0
        for (i, rect) in rects.enumerated() {
            guard values[i] > 0 else {
                XCTAssertEqual(rect, .zero, "value \(values[i]) gets nothing", file: file, line: line)
                continue
            }
            let slack = tolerance * Double(max(bounds.width, bounds.height))
            XCTAssertGreaterThanOrEqual(Double(rect.minX), Double(bounds.minX) - slack, file: file, line: line)
            XCTAssertGreaterThanOrEqual(Double(rect.minY), Double(bounds.minY) - slack, file: file, line: line)
            XCTAssertLessThanOrEqual(Double(rect.maxX), Double(bounds.maxX) + slack, file: file, line: line)
            XCTAssertLessThanOrEqual(Double(rect.maxY), Double(bounds.maxY) + slack, file: file, line: line)
            XCTAssertEqual(area(rect) / boundsArea, values[i] / total, accuracy: tolerance, "item \(i)", file: file, line: line)
            covered += area(rect)
        }
        XCTAssertEqual(covered, boundsArea, accuracy: boundsArea * tolerance, file: file, line: line)
        for i in rects.indices where values[i] > 0 {
            for j in rects.indices where j > i && values[j] > 0 {
                XCTAssertLessThan(overlap(rects[i], rects[j]), boundsArea * tolerance, "items \(i) and \(j)", file: file, line: line)
            }
        }
    }

    func testRectanglesFillTheBoundsInProportion() {
        checkLayout([600, 300, 100], in: CGRect(x: 0, y: 0, width: 400, height: 300))
        checkLayout([6, 6, 4, 3, 2, 2, 1], in: CGRect(x: 0, y: 0, width: 600, height: 400))
        checkLayout([1, 2, 3, 4, 5, 6, 7, 8, 9, 10], in: CGRect(x: 0, y: 0, width: 100, height: 900))
    }

    func testBoundsAwayFromTheOrigin() {
        checkLayout([5, 3, 2, 1], in: CGRect(x: 37, y: -20, width: 250, height: 120))
    }

    func testManyItemsOfVeryDifferentSizes() {
        let values = (0..<200).map { i in Double((i * 7_919) % 1_000 + 1) * (i % 10 == 0 ? 1_000 : 1) }
        checkLayout(values, in: CGRect(x: 0, y: 0, width: 1_200, height: 800))
    }

    func testATinyItemNextToAHugeOneStillGetsSpace() {
        let rects = Treemap.squarify(values: [1e12, 1], in: CGRect(x: 0, y: 0, width: 1_000, height: 1_000))
        XCTAssertGreaterThan(area(rects[1]), 0)
        XCTAssertEqual(area(rects[0]), 1e6, accuracy: 1)
    }

    func testOneItemFillsEverything() {
        let bounds = CGRect(x: 10, y: 20, width: 300, height: 200)
        let rects = Treemap.squarify(values: [42], in: bounds)
        XCTAssertEqual(rects.count, 1)
        XCTAssertEqual(Double(rects[0].minX), 10, accuracy: tolerance)
        XCTAssertEqual(Double(rects[0].minY), 20, accuracy: tolerance)
        XCTAssertEqual(Double(rects[0].width), 300, accuracy: tolerance)
        XCTAssertEqual(Double(rects[0].height), 200, accuracy: tolerance)
    }

    func testZeroAndNegativeSizesGetNoRectangle() {
        checkLayout([0, 10, -5, 30, 0], in: CGRect(x: 0, y: 0, width: 200, height: 100))
        let rects = Treemap.squarify(values: [0, 10, -5, 30, 0], in: CGRect(x: 0, y: 0, width: 200, height: 100))
        XCTAssertEqual(rects[0], .zero)
        XCTAssertEqual(rects[2], .zero)
        XCTAssertEqual(rects[4], .zero)
    }

    func testNothingToLayOut() {
        XCTAssertEqual(Treemap.squarify(values: [], in: CGRect(x: 0, y: 0, width: 10, height: 10)), [])
        XCTAssertEqual(Treemap.squarify(values: [0, 0], in: CGRect(x: 0, y: 0, width: 10, height: 10)), [.zero, .zero])
        XCTAssertEqual(Treemap.squarify(values: [1, 2], in: .zero), [.zero, .zero])
        XCTAssertEqual(Treemap.squarify(values: [1, 2], in: CGRect(x: 0, y: 0, width: 0, height: 50)), [.zero, .zero])
        XCTAssertEqual(Treemap.squarify(values: [1, 2], in: CGRect(x: 0, y: 0, width: 50, height: 0)), [.zero, .zero])
    }

    func testEqualItemsMakeSquaresInASquare() {
        let rects = Treemap.squarify(values: [1, 1, 1, 1], in: CGRect(x: 0, y: 0, width: 100, height: 100))
        for rect in rects {
            XCTAssertEqual(Double(rect.width), 50, accuracy: tolerance)
            XCTAssertEqual(Double(rect.height), 50, accuracy: tolerance)
        }
    }

    func testRectanglesStayCloseToSquare() {
        // Squarified layouts keep the worst aspect ratio of similar items low.
        let values = Array(repeating: 1.0, count: 36)
        let rects = Treemap.squarify(values: values, in: CGRect(x: 0, y: 0, width: 600, height: 600))
        for rect in rects {
            let ratio = max(rect.width / rect.height, rect.height / rect.width)
            XCTAssertLessThan(Double(ratio), 3)
        }
    }

    func testTheResultFollowsTheInputOrder() {
        let values: [Double] = [1, 9, 3]
        let rects = Treemap.squarify(values: values, in: CGRect(x: 0, y: 0, width: 130, height: 100))
        XCTAssertGreaterThan(area(rects[1]), area(rects[2]))
        XCTAssertGreaterThan(area(rects[2]), area(rects[0]))
    }
}
