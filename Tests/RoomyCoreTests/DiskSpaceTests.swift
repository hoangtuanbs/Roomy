import XCTest
@testable import RoomyCore

final class DiskSpaceTests: XCTestCase {
    private let gb: Int64 = 1_000_000_000

    func testBreakdownAddsUpToTotal() {
        let space = DiskSpace(total: 500 * gb, available: 100 * gb, availableForImportantUsage: 130 * gb, scanned: 320 * gb)
        XCTAssertEqual(space.used, 400 * gb)
        XCTAssertEqual(space.purgeable, 30 * gb)
        XCTAssertEqual(space.scanned, 320 * gb)
        XCTAssertEqual(space.hidden, 50 * gb)
        XCTAssertEqual(space.free, 100 * gb)
        XCTAssertEqual(space.scanned + space.hidden + space.purgeableShown + space.free, space.total)
        XCTAssertEqual(space.fractions.reduce(0, +), 1, accuracy: 1e-9)
    }

    func testHiddenIsNeverNegative() {
        // The scan found more than the disk says is used, apart from purgeable space.
        let space = DiskSpace(total: 500 * gb, available: 100 * gb, availableForImportantUsage: 150 * gb, scanned: 380 * gb)
        XCTAssertEqual(space.hidden, 0)
        XCTAssertEqual(space.purgeableShown, 20 * gb)
        XCTAssertEqual(space.scanned + space.hidden + space.purgeableShown + space.free, space.total)
    }

    func testScanLargerThanUsedIsCapped() {
        let space = DiskSpace(total: 100 * gb, available: 40 * gb, availableForImportantUsage: 40 * gb, scanned: 70 * gb)
        XCTAssertEqual(space.scanned, 60 * gb)
        XCTAssertEqual(space.hidden, 0)
        XCTAssertEqual(space.purgeable, 0)
    }

    func testOddValuesAreClamped() {
        let space = DiskSpace(total: 100 * gb, available: 120 * gb, availableForImportantUsage: 10 * gb, scanned: -5)
        XCTAssertEqual(space.available, 100 * gb)
        XCTAssertEqual(space.availableForImportantUsage, 100 * gb)
        XCTAssertEqual(space.purgeable, 0)
        XCTAssertEqual(space.used, 0)
        XCTAssertEqual(space.hidden, 0)
        XCTAssertEqual(DiskSpace(total: 0, available: 0, availableForImportantUsage: 0, scanned: 0).fractions, [0, 0, 0, 0])
    }

    func testWholeDisk() {
        XCTAssertTrue(DiskSpace.isWholeDisk(scanRoot: "/", volumePath: "/"))
        XCTAssertTrue(DiskSpace.isWholeDisk(scanRoot: "/System/Volumes/Data", volumePath: "/System/Volumes/Data"))
        XCTAssertTrue(DiskSpace.isWholeDisk(scanRoot: "/Volumes/Backup/", volumePath: "/Volumes/Backup"))
        XCTAssertFalse(DiskSpace.isWholeDisk(scanRoot: "/Users/me", volumePath: "/"))
        XCTAssertFalse(DiskSpace.isWholeDisk(scanRoot: "/Volumes/Backup/Photos", volumePath: "/Volumes/Backup"))
        XCTAssertFalse(DiskSpace.isWholeDisk(scanRoot: "/Users/me", volumePath: nil))
        XCTAssertEqual(DiskSpace.snapshotMountPoint(forVolume: "/System/Volumes/Data"), "/")
        XCTAssertEqual(DiskSpace.snapshotMountPoint(forVolume: "/Volumes/Backup"), "/Volumes/Backup")
    }

    func testReadsTheDiskOfATemporaryFolder() {
        let space = DiskSpace.read(forPath: NSTemporaryDirectory(), scanned: 0)
        XCTAssertNotNil(space)
        if let space { XCTAssertGreaterThan(space.total, 0) }
    }
}

final class LocalSnapshotsTests: XCTestCase {
    private let utc = TimeZone(identifier: "UTC")!

    private let sample = """
    Snapshots for disk /:
    com.apple.TimeMachine.2026-11-20-101500.local
    com.apple.TimeMachine.2026-11-19-091233.local

    com.apple.os.update-1A2B3C4D5E6F
    """

    func testParsesSampleOutput() throws {
        let snapshots = LocalSnapshots.parseList(sample, timeZone: utc)
        XCTAssertEqual(snapshots.map(\.name), [
            "com.apple.os.update-1A2B3C4D5E6F",
            "com.apple.TimeMachine.2026-11-19-091233.local",
            "com.apple.TimeMachine.2026-11-20-101500.local",
        ])
        let newest = try XCTUnwrap(snapshots.last)
        XCTAssertEqual(newest.dateStamp, "2026-11-20-101500")
        XCTAssertTrue(newest.isTimeMachine)
        XCTAssertTrue(newest.canDelete)
        let components = DateComponents(timeZone: utc, year: 2026, month: 11, day: 20, hour: 10, minute: 15, second: 0)
        XCTAssertEqual(newest.date, Calendar(identifier: .gregorian).date(from: components))

        let update = snapshots[0]
        XCTAssertNil(update.date)
        XCTAssertFalse(update.isTimeMachine)
        XCTAssertFalse(update.canDelete)
    }

    func testParsesOlderOutputWithoutHeader() {
        let snapshots = LocalSnapshots.parseList("com.apple.TimeMachine.2019-03-01-120000\n", timeZone: utc)
        XCTAssertEqual(snapshots.count, 1)
        XCTAssertEqual(snapshots.first?.dateStamp, "2019-03-01-120000")
    }

    func testEmptyAndMessageOutputGiveNoSnapshots() {
        XCTAssertEqual(LocalSnapshots.parseList(""), [])
        XCTAssertEqual(LocalSnapshots.parseList("Snapshots for disk /:\n"), [])
        XCTAssertEqual(LocalSnapshots.parseList("No local snapshots found for disk /"), [])
    }

    func testDateStamps() {
        XCTAssertEqual(LocalSnapshots.dateStamp(in: "com.apple.TimeMachine.2026-11-20-101500.local"), "2026-11-20-101500")
        XCTAssertNil(LocalSnapshots.dateStamp(in: "com.apple.TimeMachine.local"))
        XCTAssertNil(LocalSnapshots.dateStamp(in: "com.apple.TimeMachine.2026-11-20-1015001.local"))
        XCTAssertTrue(LocalSnapshots.isDateStamp("2026-11-20-101500"))
        XCTAssertFalse(LocalSnapshots.isDateStamp("2026-13-20-101500"))
        XCTAssertFalse(LocalSnapshots.isDateStamp("2026-11-20-251500"))
        XCTAssertFalse(LocalSnapshots.isDateStamp("/"))
        XCTAssertFalse(LocalSnapshots.isDateStamp("2026-11-20 10150"))
    }

    func testDeleteOnlyEverPassesOneDate() {
        let tm = LocalSnapshot(name: "com.apple.TimeMachine.2026-11-20-101500.local", dateStamp: "2026-11-20-101500", date: nil)
        XCTAssertEqual(LocalSnapshots.deleteArguments(for: tm), ["deletelocalsnapshots", "2026-11-20-101500"])

        // Never a mount point, which would delete every snapshot on the disk.
        let mount = LocalSnapshot(name: "com.apple.TimeMachine./", dateStamp: "/", date: nil)
        XCTAssertNil(LocalSnapshots.deleteArguments(for: mount))
        let other = LocalSnapshot(name: "com.apple.os.update-2026-11-20-101500", dateStamp: "2026-11-20-101500", date: nil)
        XCTAssertNil(LocalSnapshots.deleteArguments(for: other))
        let mismatched = LocalSnapshot(name: "com.apple.TimeMachine.2026-11-20-101500.local", dateStamp: "2026-11-19-091233", date: nil)
        XCTAssertNil(LocalSnapshots.deleteArguments(for: mismatched))
        let undated = LocalSnapshot(name: "com.apple.TimeMachine.local", dateStamp: nil, date: nil)
        XCTAssertNil(LocalSnapshots.deleteArguments(for: undated))
    }

    func testThinArguments() {
        XCTAssertEqual(LocalSnapshots.thinArguments(mountPoint: "/", bytes: 5_000_000_000),
                       ["thinlocalsnapshots", "/", "5000000000", "4"])
        XCTAssertNil(LocalSnapshots.thinArguments(mountPoint: "/", bytes: 0))
        XCTAssertNil(LocalSnapshots.thinArguments(mountPoint: "/", bytes: 10, urgency: 5))
        XCTAssertNil(LocalSnapshots.thinArguments(mountPoint: "relative", bytes: 10))
    }

    func testRunCollectsOutputAndStatus() async {
        let ok = await LocalSnapshots.run(["hello"], executable: "/bin/echo")
        XCTAssertTrue(ok.succeeded)
        XCTAssertEqual(ok.output, "hello\n")
        let missing = await LocalSnapshots.run([], executable: "/nonexistent/tool")
        XCTAssertFalse(missing.succeeded)
    }
}
