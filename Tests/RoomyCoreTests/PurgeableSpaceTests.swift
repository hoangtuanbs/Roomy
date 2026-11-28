import XCTest
@testable import RoomyCore

/// The "Free Purgeable Space" logic with a fake disk. Nothing here asks the real disk to free anything.
final class PurgeableSpaceTests: XCTestCase {
    final class FakeDisk: PurgeableSpaceReleaser, @unchecked Sendable {
        let lock = NSLock()
        var available: Int64
        var purgeable: Int64
        /// What each read after the request adds, as APFS frees blocks in the background.
        var freedPerRead: [Int64]
        var requests: [(mount: String, bytes: Int64)] = []
        var error: Error?
        var reads = 0

        init(available: Int64, purgeable: Int64, freedPerRead: [Int64] = [], error: Error? = nil) {
            self.available = available
            self.purgeable = purgeable
            self.freedPerRead = freedPerRead
            self.error = error
        }

        func space(volume: String) -> (available: Int64, purgeable: Int64)? {
            lock.lock()
            defer { lock.unlock() }
            reads += 1
            if !requests.isEmpty, !freedPerRead.isEmpty {
                let step = freedPerRead.removeFirst()
                available += step
                purgeable -= step
            }
            return (available, purgeable)
        }

        func release(mountPoint: String, bytes: Int64) async throws {
            lock.lock()
            requests.append((mountPoint, bytes))
            lock.unlock()
            if let error { throw error }
        }
    }

    private func freer(_ disk: FakeDisk) -> PurgeableSpaceFreer {
        PurgeableSpaceFreer(releaser: disk, checks: 4, pause: {})
    }

    func testFreedSpaceIsMeasuredUntilItStopsGrowing() async {
        let disk = FakeDisk(available: 10_000_000_000, purgeable: 5_000_000_000,
                            freedPerRead: [1_000_000_000, 2_000_000_000, 500_000_000, 0])
        let outcome = await freer(disk).run(volume: "/", mountPoint: "/")
        XCTAssertEqual(outcome, .freed(before: 10_000_000_000, after: 13_500_000_000))
        XCTAssertEqual(outcome.freedBytes, 3_500_000_000)
        XCTAssertEqual(disk.requests.count, 1)
        XCTAssertEqual(disk.requests.first?.mount, "/")
        XCTAssertEqual(disk.requests.first?.bytes, 5_000_000_000, "It asks for exactly the purgeable space")
        XCTAssertEqual(disk.reads, 5, "Once before, four times after")
    }

    func testNothingFreedIsSaidPlainly() async {
        let disk = FakeDisk(available: 10_000_000_000, purgeable: 2_000_000_000, freedPerRead: [0, 1_000_000, 0, 0])
        let outcome = await freer(disk).run(volume: "/", mountPoint: "/")
        XCTAssertEqual(outcome, .nothingFreed(before: 10_000_000_000, after: 10_001_000_000), "A megabyte is noise")
        XCTAssertEqual(outcome.freedBytes, 0)
    }

    func testFreeSpaceThatShrinksMeanwhileIsNotAFailure() async {
        let disk = FakeDisk(available: 10_000_000_000, purgeable: 2_000_000_000, freedPerRead: [-50_000_000, 0, 0, 0])
        let outcome = await freer(disk).run(volume: "/", mountPoint: "/")
        XCTAssertEqual(outcome, .nothingFreed(before: 10_000_000_000, after: 10_000_000_000))
    }

    func testWithoutPurgeableSpaceNothingIsAsked() async {
        let disk = FakeDisk(available: 10_000_000_000, purgeable: 0)
        let outcome = await freer(disk).run(volume: "/", mountPoint: "/")
        XCTAssertEqual(outcome, .nothingToFree(available: 10_000_000_000))
        XCTAssertTrue(disk.requests.isEmpty)
    }

    func testAFailedRequestSaysWhy() async {
        let disk = FakeDisk(available: 1, purgeable: 100_000_000, error: LocalSnapshotError.failed("tmutil said no"))
        let outcome = await freer(disk).run(volume: "/", mountPoint: "/")
        XCTAssertEqual(outcome, .failed("tmutil said no"))
    }

    func testTheRealReleaserOnlyThinsTimeMachineSnapshots() {
        // The arguments it would pass; tmutil is never run here.
        XCTAssertEqual(LocalSnapshots.thinArguments(mountPoint: "/", bytes: 5_000_000_000),
                       ["thinlocalsnapshots", "/", "5000000000", "4"])
        XCTAssertNil(LocalSnapshots.thinArguments(mountPoint: "/", bytes: 0))
    }
}
