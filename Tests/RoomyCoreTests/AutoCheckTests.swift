import XCTest
@testable import RoomyCore

final class AutoCheckTests: XCTestCase {
    private let gb: Int64 = 1_000_000_000
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    // MARK: Schedule

    func testNoNextCheckWhenOff() {
        XCTAssertNil(AutoCheckSchedule.nextCheck(after: nil, interval: .off, now: now))
        XCTAssertNil(AutoCheckSchedule.nextCheck(after: now.addingTimeInterval(-100_000), interval: .off, now: now))
    }

    func testNeverCheckedIsDueNow() {
        XCTAssertEqual(AutoCheckSchedule.nextCheck(after: nil, interval: .sixHours, now: now), now)
    }

    func testNextCheckFollowsTheInterval() {
        let hourAgo = now.addingTimeInterval(-3600)
        XCTAssertEqual(AutoCheckSchedule.nextCheck(after: hourAgo, interval: .sixHours, now: now),
                       hourAgo.addingTimeInterval(6 * 3600))
        XCTAssertEqual(AutoCheckSchedule.nextCheck(after: hourAgo, interval: .daily, now: now),
                       hourAgo.addingTimeInterval(24 * 3600))
        XCTAssertEqual(AutoCheckSchedule.nextCheck(after: hourAgo, interval: .hourly, now: now), now)
    }

    func testOverdueCheckIsDueNowNotInThePast() {
        let longAgo = now.addingTimeInterval(-10 * 24 * 3600)
        XCTAssertEqual(AutoCheckSchedule.nextCheck(after: longAgo, interval: .daily, now: now), now)
    }

    func testLastCheckInTheFutureIsDueNow() {
        XCTAssertEqual(AutoCheckSchedule.nextCheck(after: now.addingTimeInterval(3600), interval: .sixHours, now: now), now)
    }

    func testCheckAfterWakeUnlessRecent() {
        XCTAssertTrue(AutoCheckSchedule.shouldCheckAfterWake(lastCheck: nil, interval: .sixHours, now: now))
        XCTAssertFalse(AutoCheckSchedule.shouldCheckAfterWake(lastCheck: now.addingTimeInterval(-60), interval: .sixHours, now: now))
        XCTAssertTrue(AutoCheckSchedule.shouldCheckAfterWake(
            lastCheck: now.addingTimeInterval(-AutoCheckSchedule.recentWindow), interval: .sixHours, now: now))
        XCTAssertTrue(AutoCheckSchedule.shouldCheckAfterWake(lastCheck: now.addingTimeInterval(600), interval: .daily, now: now))
        XCTAssertFalse(AutoCheckSchedule.shouldCheckAfterWake(lastCheck: nil, interval: .off, now: now))
    }

    // MARK: Power

    func testPowerAllowsOnMainsAndHealthyBattery() {
        XCTAssertTrue(AutoCheckSchedule.powerAllows(PowerState(isOnBattery: false, batteryPercent: nil, isLowPowerMode: false)))
        XCTAssertTrue(AutoCheckSchedule.powerAllows(PowerState(isOnBattery: false, batteryPercent: 5, isLowPowerMode: false)))
        XCTAssertTrue(AutoCheckSchedule.powerAllows(PowerState(isOnBattery: true, batteryPercent: 20, isLowPowerMode: false)))
        XCTAssertTrue(AutoCheckSchedule.powerAllows(PowerState(isOnBattery: true, batteryPercent: nil, isLowPowerMode: false)))
    }

    func testPowerBlocksLowBatteryAndLowPowerMode() {
        XCTAssertFalse(AutoCheckSchedule.powerAllows(PowerState(isOnBattery: true, batteryPercent: 19, isLowPowerMode: false)))
        XCTAssertFalse(AutoCheckSchedule.powerAllows(PowerState(isOnBattery: false, batteryPercent: 90, isLowPowerMode: true)))
        XCTAssertFalse(AutoCheckSchedule.powerAllows(PowerState(isOnBattery: true, batteryPercent: 80, isLowPowerMode: true)))
    }

    // MARK: Notice

    func testNoticeAboveThresholdWithoutEarlierNotice() {
        XCTAssertTrue(ReclaimableNotice.shouldNotify(reclaimable: 6 * gb, threshold: 5 * gb, lastNotified: nil, now: now))
    }

    func testNoNoticeAtOrBelowThreshold() {
        XCTAssertFalse(ReclaimableNotice.shouldNotify(reclaimable: 5 * gb, threshold: 5 * gb, lastNotified: nil, now: now))
        XCTAssertFalse(ReclaimableNotice.shouldNotify(reclaimable: gb, threshold: 5 * gb, lastNotified: nil, now: now))
        XCTAssertFalse(ReclaimableNotice.shouldNotify(reclaimable: 50 * gb, threshold: 0, lastNotified: nil, now: now))
    }

    func testAtMostOneNoticeEveryThreeDays() {
        let almost = now.addingTimeInterval(-ReclaimableNotice.repeatInterval + 60)
        XCTAssertFalse(ReclaimableNotice.shouldNotify(reclaimable: 9 * gb, threshold: 5 * gb, lastNotified: almost, now: now))
        let exactly = now.addingTimeInterval(-ReclaimableNotice.repeatInterval)
        XCTAssertTrue(ReclaimableNotice.shouldNotify(reclaimable: 9 * gb, threshold: 5 * gb, lastNotified: exactly, now: now))
    }

    func testNoticeInTheFutureDoesNotBlockForever() {
        XCTAssertTrue(ReclaimableNotice.shouldNotify(reclaimable: 9 * gb, threshold: 5 * gb,
                                                     lastNotified: now.addingTimeInterval(3600), now: now))
    }

    // MARK: Summary

    private func finding(_ id: String, _ category: JunkCategory, _ sizes: [Int64], preselected: Bool = true,
                         permanent: Bool = false) -> JunkFinding {
        JunkFinding(id: id, category: category, title: id, explanation: "",
                    items: sizes.enumerated().map { JunkItem(path: "/tmp/\(id)/\($0.offset)", name: "\($0.offset)", bytes: $0.element) },
                    preselected: preselected, isPermanent: permanent)
    }

    func testSummaryCountsOnlySafeFindings() {
        let findings = [
            finding("caches", .caches, [3 * gb, gb]),
            finding("logs", .logs, [gb / 2]),
            finding("archives", .developer, [9 * gb], preselected: false),
            finding("trash", .trash, [7 * gb], preselected: true, permanent: true),
        ]
        let summary = JunkSummary(findings: findings, date: now)
        XCTAssertEqual(summary.totalBytes, 4 * gb + gb / 2)
        XCTAssertEqual(summary.parts.map(\.category), [.caches, .logs])
        XCTAssertEqual(summary.phrase, "caches and logs")
        XCTAssertEqual(JunkSummary.safeItems(findings).map(\.bytes), [3 * gb, gb, gb / 2])
    }

    func testSummaryPhrases() {
        XCTAssertEqual(JunkSummary(date: now, parts: []).phrase, "junk")
        XCTAssertEqual(JunkSummary(date: now, parts: [.init(category: .logs, bytes: 1)]).phrase, "logs")
        let three = JunkSummary(date: now, parts: [.init(category: .caches, bytes: 3), .init(category: .logs, bytes: 2),
                                                   .init(category: .developer, bytes: 1)])
        XCTAssertEqual(three.phrase, "caches, logs and build data")
        let four = JunkSummary(date: now, parts: three.parts + [.init(category: .packages, bytes: 1)])
        XCTAssertEqual(four.phrase, "caches, logs, build data and more")
    }

    func testSubtractingRemovedBytes() {
        let findings = [finding("caches", .caches, [3 * gb, gb]), finding("logs", .logs, [gb / 2])]
        let summary = JunkSummary(findings: findings, date: now)
        let removed = JunkSummary.bytesByCategory(of: ["/tmp/caches/0", "/tmp/logs/0"], in: findings)
        XCTAssertEqual(removed, [.caches: 3 * gb, .logs: gb / 2])
        let left = summary.subtracting(removed)
        XCTAssertEqual(left.totalBytes, gb)
        XCTAssertEqual(left.parts.map(\.category), [.caches])
        XCTAssertEqual(left.date, now)
    }

    func testSummaryRoundTripsThroughJSON() throws {
        let summary = JunkSummary(date: now, parts: [.init(category: .caches, bytes: 5), .init(category: .logs, bytes: 2)])
        let data = try JSONEncoder().encode(summary)
        XCTAssertEqual(try JSONDecoder().decode(JunkSummary.self, from: data), summary)
    }

    /// The finder on a temporary home folder: Quick Clean picks caches and logs, never what needs review.
    func testSafeItemsFromARealFind() async throws {
        let fm = FileManager.default
        let home = DiskScanner.standardize(fm.temporaryDirectory.appendingPathComponent("RoomyTests-\(UUID().uuidString)").path)
        defer { try? fm.removeItem(atPath: home) }
        for relative in ["Library/Caches/com.example.app/blob", "Library/Logs/Example/log.txt",
                         "Library/Developer/Xcode/Archives/2026-01-01/App.xcarchive/Info.plist"] {
            let path = home + "/" + relative
            try fm.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            try Data(repeating: 1, count: 50_000).write(to: URL(fileURLWithPath: path))
        }
        let findings = await JunkFinder(homePath: home).find()
        let safe = Set(JunkSummary.safeItems(findings).map(\.path))
        XCTAssertTrue(safe.contains(home + "/Library/Caches/com.example.app"))
        XCTAssertTrue(safe.contains(home + "/Library/Logs/Example"))
        XCTAssertFalse(safe.contains { $0.contains("Archives") })
        XCTAssertEqual(Set(JunkSummary(findings: findings, date: now).parts.map(\.category)), [.caches, .logs])
    }

    // MARK: Short sizes

    func testShortSizes() {
        XCTAssertEqual(ByteFormat.short(0), "0B")
        XCTAssertEqual(ByteFormat.short(870_000_000), "870M")
        XCTAssertEqual(ByteFormat.short(3_240_000_000), "3.2G")
        XCTAssertEqual(ByteFormat.short(12_400_000_000), "12G")
        XCTAssertEqual(ByteFormat.short(999_000_000_000), "999G")
        XCTAssertEqual(ByteFormat.short(1_500_000_000_000), "1.5T")
    }
}
