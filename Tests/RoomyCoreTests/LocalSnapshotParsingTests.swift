import XCTest
@testable import RoomyCore

/// Parsing `tmutil` output from sample text. Nothing here runs tmutil.
final class LocalSnapshotParsingTests: XCTestCase {
    private let utc = TimeZone(identifier: "UTC")!

    private func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int, _ min: Int, _ s: Int, in zone: TimeZone) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        return calendar.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min, second: s))!
    }

    func testMixedSnapshotsAreSortedOldestFirstWithUndatedOnesFirst() {
        let output = """
        Snapshots for disk /:
        com.apple.TimeMachine.2026-11-21-091500.local
        com.apple.os.update-4A3D9F7C1E2B
        com.apple.TimeMachine.2026-11-20-111500.local
        com.apple.TimeMachine.2026-11-20-101500.local
        com.apple.os.update-0B2C

        """
        let snapshots = LocalSnapshots.parseList(output, timeZone: utc)

        XCTAssertEqual(snapshots.map(\.name), [
            "com.apple.os.update-0B2C",
            "com.apple.os.update-4A3D9F7C1E2B",
            "com.apple.TimeMachine.2026-11-20-101500.local",
            "com.apple.TimeMachine.2026-11-20-111500.local",
            "com.apple.TimeMachine.2026-11-21-091500.local",
        ])
        XCTAssertEqual(snapshots.map(\.canDelete), [false, false, true, true, true])
        XCTAssertEqual(snapshots.map(\.isTimeMachine), [false, false, true, true, true])
        XCTAssertEqual(snapshots[2].dateStamp, "2026-11-20-101500")
        XCTAssertEqual(snapshots[2].date, date(2026, 11, 20, 10, 15, 0, in: utc))
        XCTAssertEqual(snapshots[4].date, date(2026, 11, 21, 9, 15, 0, in: utc))
        XCTAssertEqual(snapshots[2].id, snapshots[2].name)
    }

    func testOlderNamesWithoutLocalAndUntidyLines() {
        let output = "Snapshots for disk /:\r\n   com.apple.TimeMachine.2020-01-02-030405  \r\n\r\n\tcom.apple.TimeMachine.2020-01-01-000000.local\r\n"
        let snapshots = LocalSnapshots.parseList(output, timeZone: utc)
        XCTAssertEqual(snapshots.map(\.name), ["com.apple.TimeMachine.2020-01-01-000000.local", "com.apple.TimeMachine.2020-01-02-030405"])
        XCTAssertEqual(snapshots.map(\.dateStamp), ["2020-01-01-000000", "2020-01-02-030405"])
        XCTAssertTrue(snapshots.allSatisfy(\.canDelete))
    }

    func testMessagesAndHeadersAreNotSnapshots() {
        let output = """
        Snapshot dates for all disks:
        Error: Invalid argument
        No local snapshots found for disk /
        Usage:
        """
        XCTAssertEqual(LocalSnapshots.parseList(output), [])
    }

    func testDatesAreReadInTheGivenTimeZone() throws {
        let tokyo = try XCTUnwrap(TimeZone(identifier: "Asia/Tokyo"))
        let line = "com.apple.TimeMachine.2026-06-01-120000.local"
        let inUTC = try XCTUnwrap(LocalSnapshots.parseList(line, timeZone: utc).first?.date)
        let inTokyo = try XCTUnwrap(LocalSnapshots.parseList(line, timeZone: tokyo).first?.date)
        XCTAssertEqual(inUTC.timeIntervalSince(inTokyo), 9 * 3_600)
    }

    func testDateStampRules() {
        XCTAssertTrue(LocalSnapshots.isDateStamp("2024-02-29-235959"), "Leap day")
        XCTAssertFalse(LocalSnapshots.isDateStamp("2026-02-29-000000"), "Not a leap year")
        XCTAssertFalse(LocalSnapshots.isDateStamp("2026-11-31-000000"))
        XCTAssertFalse(LocalSnapshots.isDateStamp("2026-11-20-106000"))
        XCTAssertFalse(LocalSnapshots.isDateStamp("2026-11-20-101560"))
        XCTAssertFalse(LocalSnapshots.isDateStamp("2026_11_20_101500"))
        XCTAssertFalse(LocalSnapshots.isDateStamp("2026-1x-20-101500"))
        XCTAssertFalse(LocalSnapshots.isDateStamp("２０２６-11-20-101500"), "Only ASCII digits")
        XCTAssertFalse(LocalSnapshots.isDateStamp("2026-11-20-101500 "))
        XCTAssertFalse(LocalSnapshots.isDateStamp(""))
        XCTAssertFalse(LocalSnapshots.isDateStamp("-a"))
    }

    func testDateStampIsFoundAnywhereButNotInsideLongerNumbers() {
        XCTAssertEqual(LocalSnapshots.dateStamp(in: "2026-11-20-101500"), "2026-11-20-101500")
        XCTAssertEqual(LocalSnapshots.dateStamp(in: "x2026-11-20-101500y"), "2026-11-20-101500")
        XCTAssertNil(LocalSnapshots.dateStamp(in: "12026-11-20-101500"))
        XCTAssertNil(LocalSnapshots.dateStamp(in: "com.apple.TimeMachine.2026-13-20-101500.local"))
        XCTAssertEqual(LocalSnapshots.dateStamp(in: "a.2026-13-20-101500.b.2026-11-20-101500"), "2026-11-20-101500")
        XCTAssertNil(LocalSnapshots.dateStamp(in: "short"))
        XCTAssertNil(LocalSnapshots.dateStamp(in: ""))
    }

    func testDeletingNeverTargetsMoreThanOneSnapshot() {
        let output = """
        com.apple.TimeMachine.2026-11-20-101500.local
        com.apple.os.update-2026-11-20-101500
        com.apple.TimeMachine.local
        com.apple.TimeMachine./
        com.apple.TimeMachine.2026-11-20-101500-extra.local
        """
        for snapshot in LocalSnapshots.parseList(output, timeZone: utc) {
            guard let arguments = LocalSnapshots.deleteArguments(for: snapshot) else {
                XCTAssertFalse(snapshot.canDelete && snapshot.name == "com.apple.TimeMachine.2026-11-20-101500.local", snapshot.name)
                continue
            }
            XCTAssertEqual(arguments.count, 2, snapshot.name)
            XCTAssertEqual(arguments[0], "deletelocalsnapshots")
            XCTAssertTrue(LocalSnapshots.isDateStamp(arguments[1]), "Never a mount point: \(arguments)")
        }
        let good = LocalSnapshots.parseList("com.apple.TimeMachine.2026-11-20-101500.local", timeZone: utc)[0]
        XCTAssertEqual(LocalSnapshots.deleteArguments(for: good), ["deletelocalsnapshots", "2026-11-20-101500"])
    }

    func testListArguments() {
        XCTAssertEqual(LocalSnapshots.listArguments(mountPoint: "/"), ["listlocalsnapshots", "/"])
        XCTAssertEqual(LocalSnapshots.thinArguments(mountPoint: "/Volumes/Data", bytes: 1, urgency: 1),
                       ["thinlocalsnapshots", "/Volumes/Data", "1", "1"])
        XCTAssertNil(LocalSnapshots.thinArguments(mountPoint: "/", bytes: -1))
        XCTAssertNil(LocalSnapshots.thinArguments(mountPoint: "/", bytes: 10, urgency: 0))
    }

    func testMessagesFromTmutil() {
        XCTAssertEqual(LocalSnapshots.message(from: CommandOutput(status: 1, output: "  Failed to delete.\n")), "Failed to delete.")
        XCTAssertTrue(LocalSnapshots.message(from: CommandOutput(status: 70, output: " \n")).contains("70"))
        XCTAssertTrue(CommandOutput(status: 0, output: "").succeeded)
        XCTAssertFalse(CommandOutput(status: 3, output: "").succeeded)
        let error = LocalSnapshotError.cannotDelete("com.apple.os.update-X")
        XCTAssertTrue(error.errorDescription?.contains("com.apple.os.update-X") ?? false)
        XCTAssertEqual(LocalSnapshotError.failed("boom").errorDescription, "boom")
    }
}
