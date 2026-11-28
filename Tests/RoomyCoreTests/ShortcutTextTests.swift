import XCTest
@testable import RoomyCore

final class ShortcutTextTests: XCTestCase {
    func testScanListsTheTotalAndTheBiggestItems() async throws {
        let fm = FileManager.default
        let root = DiskScanner.standardize(fm.temporaryDirectory.appendingPathComponent("RoomyShortcut-\(UUID().uuidString)").path)
        defer { try? fm.removeItem(atPath: root) }
        try fm.createDirectory(atPath: root + "/big", withIntermediateDirectories: true)
        try Data(repeating: 1, count: 400_000).write(to: URL(fileURLWithPath: root + "/big/a.bin"))
        try Data(repeating: 1, count: 100_000).write(to: URL(fileURLWithPath: root + "/small.bin"))
        let tree = try await DiskScanner().scan(root: root)

        let lines = ShortcutText.scan(tree, top: 5).split(separator: "\n").map(String.init)
        XCTAssertEqual(lines.count, 3)
        XCTAssertTrue(lines[0].hasPrefix((root as NSString).lastPathComponent + ": "), lines[0])
        XCTAssertTrue(lines[1].hasSuffix("  big"), lines[1])
        XCTAssertTrue(lines[2].hasSuffix("  small.bin"), lines[2])
        XCTAssertEqual(ShortcutText.scan(tree, top: 1).split(separator: "\n").count, 2)
    }

    func testFreeSpaceAndJunkTexts() {
        let space = DiskSpace(total: 500_000_000_000, available: 120_000_000_000, availableForImportantUsage: 130_000_000_000, scanned: 0)
        XCTAssertEqual(ShortcutText.freeSpace(space), "\(ByteFormat.string(120_000_000_000)) free of \(ByteFormat.string(500_000_000_000))")
        XCTAssertEqual(ShortcutText.junk([]), "No junk found.")
        let junk = ShortcutText.junk([JunkItem(path: "/a", name: "a", bytes: 1_000_000), JunkItem(path: "/b", name: "b", bytes: 2_000_000)])
        XCTAssertTrue(junk.hasPrefix(ByteFormat.string(3_000_000)) && junk.hasSuffix("Items: 2."), junk)
    }

    func testCleanedSaysWhatFailed() {
        let report = CleanupReport(date: Date(), results: [
            CleanupResult(path: "/a", bytes: 10, trashedTo: "/T/a", error: nil),
            CleanupResult(path: "/b", bytes: 20, trashedTo: nil, error: "in use"),
        ])
        let text = ShortcutText.cleaned(report)
        XCTAssertTrue(text.hasPrefix("Moved to the Trash: 1. Freed: \(ByteFormat.string(10))."), text)
        XCTAssertTrue(text.hasSuffix("1 could not be moved."), text)
    }
}
