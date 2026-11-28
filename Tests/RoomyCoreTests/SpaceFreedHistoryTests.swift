import XCTest
@testable import RoomyCore

final class SpaceFreedHistoryTests: XCTestCase {
    private var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    private func date(_ year: Int, _ month: Int, _ day: Int) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: 12))!
    }

    private func moved(_ path: String, _ bytes: Int64) -> CleanupResult {
        CleanupResult(path: path, bytes: bytes, trashedTo: "/Trash/" + (path as NSString).lastPathComponent, error: nil)
    }

    private func failed(_ path: String, _ bytes: Int64) -> CleanupResult {
        CleanupResult(path: path, bytes: bytes, trashedTo: nil, error: "in use")
    }

    func testTotalsCountOnlyWhatWentToTheTrash() {
        let history = SpaceFreedHistory(reports: [
            CleanupReport(date: date(2026, 11, 2), results: [moved("/a", 100), failed("/b", 900)], tool: .smartClean),
            CleanupReport(date: date(2026, 11, 20), results: [moved("/c", 50)], tool: .duplicates),
            CleanupReport(date: date(2026, 11, 21), results: [failed("/d", 70)], tool: .uninstaller),
        ], now: date(2026, 11, 28), calendar: calendar)

        XCTAssertEqual(history.freedBytes, 150)
        XCTAssertEqual(history.itemCount, 2)
        XCTAssertEqual(history.entries.map(\.tool), [.duplicates, .smartClean], "newest first, and the failed clean is left out")
        XCTAssertEqual(history.entries[1].items.map(\.path), ["/a"])
    }

    func testMonthsCoverTheLastYearIncludingEmptyMonths() {
        let history = SpaceFreedHistory(reports: [
            CleanupReport(date: date(2026, 11, 2), results: [moved("/a", 100)], tool: .smartClean),
            CleanupReport(date: date(2026, 11, 3), results: [moved("/b", 20)], tool: .smartClean),
            CleanupReport(date: date(2026, 9, 30), results: [moved("/c", 7)], tool: .review),
            CleanupReport(date: date(2025, 1, 1), results: [moved("/old", 1_000)], tool: .review),
        ], now: date(2026, 11, 28), calendar: calendar)

        XCTAssertEqual(history.months.count, 12)
        XCTAssertEqual(history.months.first?.start, calendar.date(from: DateComponents(year: 2025, month: 12, day: 1)))
        XCTAssertEqual(history.months.last?.start, calendar.date(from: DateComponents(year: 2026, month: 11, day: 1)))
        XCTAssertEqual(history.months.last?.freedBytes, 120)
        XCTAssertEqual(history.months[history.months.count - 3].freedBytes, 7)
        XCTAssertEqual(history.months[history.months.count - 2].freedBytes, 0)
        XCTAssertEqual(history.freedBytes, 1_127, "the total counts cleans older than the chart too")
    }

    func testToolsAreSummedMostFirstAndOldLinesHaveNoTool() {
        let history = SpaceFreedHistory(reports: [
            CleanupReport(date: date(2026, 10, 1), results: [moved("/a", 10)]),
            CleanupReport(date: date(2026, 10, 2), results: [moved("/b", 300)], tool: .uninstaller),
            CleanupReport(date: date(2026, 10, 3), results: [moved("/c", 40), moved("/d", 5)], tool: .smartClean),
            CleanupReport(date: date(2026, 10, 4), results: [moved("/e", 60)], tool: .smartClean),
        ], now: date(2026, 11, 28), calendar: calendar)

        XCTAssertEqual(history.tools.map(\.tool), [.uninstaller, .smartClean, nil])
        XCTAssertEqual(history.tools.map(\.freedBytes), [300, 105, 10])
        XCTAssertEqual(history.tools.map(\.cleans), [1, 2, 1])
        XCTAssertEqual(history.entries(of: .smartClean).map(\.freedBytes), [60, 45])
    }

    func testTheToolIsWrittenToTheHistoryAndOldLinesStillLoad() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("RoomyHistory-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("history.jsonl")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        // A line from before tools were noted, and one from a newer version with a tool this one doesn't know.
        let old = #"{"date":"2026-01-02T10:00:00Z","results":[{"path":"/x","bytes":5,"trashedTo":"/T/x"}]}"#
        let newer = #"{"date":"2026-01-03T10:00:00Z","tool":"timeMachine","results":[{"path":"/y","bytes":6,"trashedTo":"/T/y"}]}"#
        try Data((old + "\n" + newer + "\n").utf8).write(to: url)
        let history = CleanupHistory(fileURL: url)
        try history.append(CleanupReport(date: date(2026, 1, 4), results: [moved("/z", 7)], tool: .duplicates))

        let loaded = history.load()
        XCTAssertEqual(loaded.map(\.tool), [nil, nil, .duplicates])
        XCTAssertEqual(loaded.map(\.freedBytes), [5, 6, 7])
    }

    func testTheServiceNotesItsTool() throws {
        let folder = DiskScanner.standardize(FileManager.default.temporaryDirectory
            .appendingPathComponent("RoomyHistoryTool-\(UUID().uuidString)").path)
        defer { try? FileManager.default.removeItem(atPath: folder) }
        let file = folder + "/Downloads/a.bin"
        try FileManager.default.createDirectory(atPath: folder + "/Downloads", withIntermediateDirectories: true)
        try Data(repeating: 1, count: 100).write(to: URL(fileURLWithPath: file))
        let history = CleanupHistory(fileURL: URL(fileURLWithPath: folder + "/state/history.jsonl"))
        let service = CleanupService(policy: SafetyPolicy(homePath: folder), trasher: TestTrasher(folder: folder + "/bin"),
                                     history: history, tool: .spaceHunters)
        _ = service.execute(service.plan(paths: [file], sizeOf: { _ in 100 }))
        XCTAssertEqual(history.load().map(\.tool), [.spaceHunters])
        XCTAssertEqual(SpaceFreedHistory(history: history).freedBytes, 100)
    }
}
