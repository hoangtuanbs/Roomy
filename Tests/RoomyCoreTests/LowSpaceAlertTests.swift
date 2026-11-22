import XCTest
@testable import RoomyCore

final class LowSpaceAlertTests: XCTestCase {
    private let gb: Int64 = 1_000_000_000
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testAlertsBelowThresholdWithoutEarlierAlert() {
        XCTAssertTrue(LowSpaceAlert.shouldAlert(free: 9 * gb, threshold: 10 * gb, lastAlert: nil, now: now))
        XCTAssertTrue(LowSpaceAlert.shouldAlert(free: 0, threshold: 10 * gb, lastAlert: nil, now: now))
    }

    func testNoAlertAtOrAboveThreshold() {
        XCTAssertFalse(LowSpaceAlert.shouldAlert(free: 10 * gb, threshold: 10 * gb, lastAlert: nil, now: now))
        XCTAssertFalse(LowSpaceAlert.shouldAlert(free: 50 * gb, threshold: 10 * gb, lastAlert: nil, now: now))
    }

    func testNoAlertWhenThresholdIsZero() {
        XCTAssertFalse(LowSpaceAlert.shouldAlert(free: 0, threshold: 0, lastAlert: nil, now: now))
    }

    func testAtMostOneAlertPerDay() {
        let almostADayAgo = now.addingTimeInterval(-LowSpaceAlert.repeatInterval + 60)
        XCTAssertFalse(LowSpaceAlert.shouldAlert(free: gb, threshold: 10 * gb, lastAlert: almostADayAgo, now: now))
        let aDayAgo = now.addingTimeInterval(-LowSpaceAlert.repeatInterval)
        XCTAssertTrue(LowSpaceAlert.shouldAlert(free: gb, threshold: 10 * gb, lastAlert: aDayAgo, now: now))
    }

    func testAlertLastSetInTheFutureDoesNotBlockForever() {
        let future = now.addingTimeInterval(3600)
        XCTAssertTrue(LowSpaceAlert.shouldAlert(free: gb, threshold: 10 * gb, lastAlert: future, now: now))
    }
}
