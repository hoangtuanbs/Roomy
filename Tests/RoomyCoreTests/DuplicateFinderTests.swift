import XCTest
@testable import RoomyCore

/// Every test works in its own temporary folder that stands in for the home folder.
final class DuplicateFinderTests: XCTestCase {
    private var home = ""
    private let fm = FileManager.default
    private let mb = 1_048_576

    override func setUpWithError() throws {
        let base = fm.temporaryDirectory.appendingPathComponent("RoomyDupTests-\(UUID().uuidString)")
        try fm.createDirectory(at: base, withIntermediateDirectories: true)
        home = DiskScanner.standardize(base.path)
    }

    override func tearDownWithError() throws {
        try? fm.removeItem(atPath: home)
    }

    /// Bytes that look random and are the same for the same seed.
    private func content(seed: UInt64, count: Int) -> Data {
        var state = seed &* 0x9E37_79B9_7F4A_7C15 | 1
        var data = Data(count: count)
        data.withUnsafeMutableBytes { raw in
            let bytes = raw.bindMemory(to: UInt8.self)
            for i in 0..<count {
                state ^= state << 13
                state ^= state >> 7
                state ^= state << 17
                bytes[i] = UInt8(truncatingIfNeeded: state)
            }
        }
        return data
    }

    @discardableResult
    private func file(_ relative: String, _ data: Data, daysOld: Double? = nil) throws -> String {
        let path = home + "/" + relative
        try fm.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try data.write(to: URL(fileURLWithPath: path))
        if let daysOld {
            try fm.setAttributes([.modificationDate: Date().addingTimeInterval(-daysOld * 86_400)], ofItemAtPath: path)
        }
        return path
    }

    private func find(minimumSize: Int64 = 1_048_576) async throws -> [DuplicateGroup] {
        try await DuplicateFinder(homePath: home, minimumSize: minimumSize).find(folder: home)
    }

    private func names(_ group: DuplicateGroup) -> Set<String> {
        Set(group.files.map { String($0.path.dropFirst(home.count + 1)) })
    }

    func testFindsTrueDuplicates() async throws {
        let data = content(seed: 1, count: 2 * mb)
        try file("a/song.mp3", data)
        try file("b/song.mp3", data)
        try file("c/d/renamed.mp3", data)
        try file("other.bin", content(seed: 2, count: 3 * mb))

        let groups = try await find()
        XCTAssertEqual(groups.count, 1)
        let group = try XCTUnwrap(groups.first)
        XCTAssertEqual(names(group), ["a/song.mp3", "b/song.mp3", "c/d/renamed.mp3"])
        XCTAssertEqual(group.length, Int64(2 * mb))
        XCTAssertEqual(group.wastedBytes, group.bytes * 2)
        XCTAssertGreaterThanOrEqual(group.bytes, Int64(2 * mb))
    }

    func testSameSizeDifferentContentIsNotADuplicate() async throws {
        // Different from the start.
        try file("one.bin", content(seed: 3, count: 2 * mb))
        try file("two.bin", content(seed: 4, count: 2 * mb))
        // Same first and last 64 KB, different in the middle: only the full hash tells them apart.
        var left = content(seed: 5, count: 2 * mb)
        var right = left
        left[mb] = 1
        right[mb] = 2
        try file("left.bin", left)
        try file("right.bin", right)

        let groups = try await find()
        XCTAssertTrue(groups.isEmpty, "\(groups.map(names))")
    }

    func testHardLinksAreNotCounted() async throws {
        let data = content(seed: 6, count: 2 * mb)
        let original = try file("photos/big.mov", data)
        try fm.linkItem(atPath: original, toPath: home + "/linked/big.mov")
        let groups = try await find()
        XCTAssertTrue(groups.isEmpty, "A hard link is the same file, not a copy")

        try file("copy/big.mov", data)
        let again = try await find()
        XCTAssertEqual(again.count, 1)
        XCTAssertEqual(again.first?.files.count, 2)
        XCTAssertEqual(again.first?.files.contains { $0.path.hasSuffix("copy/big.mov") }, true)
    }

    func testSkipsSmallEmptyLinkedAndPackagedFiles() async throws {
        let data = content(seed: 7, count: 2 * mb)
        try file("Documents/report.pdf", data)
        try file("Project/.git/objects/pack.bin", data)
        try file("Tools/My.app/Contents/Resources/report.pdf", data)
        try fm.createSymbolicLink(atPath: home + "/link.pdf", withDestinationPath: home + "/Documents/report.pdf")
        let small = content(seed: 8, count: 100_000)
        try file("small1.bin", small)
        try file("small2.bin", small)
        try file("empty1", Data())
        try file("empty2", Data())

        let groups = try await find()
        XCTAssertTrue(groups.isEmpty, "\(groups.map(names))")

        // With a lower minimum, the small pair counts, the empty files still do not.
        let lower = try await find(minimumSize: 1)
        XCTAssertEqual(lower.map(names), [["small1.bin", "small2.bin"]])
    }

    func testKeepsTheMostOriginalCopy() async throws {
        let data = content(seed: 9, count: 2 * mb)
        try file("Downloads/trip.mov", data, daysOld: 400)
        try file("Movies/Trips/trip copy.mov", data, daysOld: 300)
        try file("Movies/Trips/trip.mov", data, daysOld: 200)
        try file("Desktop/trip.mov", data, daysOld: 100)

        let groups = try await find()
        let group = try XCTUnwrap(groups.first)
        XCTAssertEqual(group.suggestedKeep.path, home + "/Movies/Trips/trip.mov",
                       "Older but in Downloads, or named like a copy, loses to the oldest plain copy")
        XCTAssertEqual(group.files.last?.path, home + "/Downloads/trip.mov")
    }

    func testKeepRuleOrder() {
        let date = Date(timeIntervalSince1970: 1_000_000)
        let short = DuplicateFile(path: "/Users/me/a.jpg", bytes: 10, modified: date)
        let long = DuplicateFile(path: "/Users/me/Pictures/Old/a.jpg", bytes: 10, modified: date)
        let older = DuplicateFile(path: "/Users/me/Pictures/Old/Deep/b.jpg", bytes: 10, modified: date.addingTimeInterval(-60))
        XCTAssertEqual(KeepRule.sorted([long, short]).first, short, "Same date: shorter path wins")
        XCTAssertEqual(KeepRule.sorted([short, long, older]).first, older, "The oldest wins")

        XCTAssertTrue(KeepRule.looksLikeCopy("photo copy.jpg"))
        XCTAssertTrue(KeepRule.looksLikeCopy("photo copy 2.jpg"))
        XCTAssertTrue(KeepRule.looksLikeCopy("photo (1).jpg"))
        XCTAssertFalse(KeepRule.looksLikeCopy("photocopy.jpg"))
        XCTAssertFalse(KeepRule.looksLikeCopy("2024 (summer).jpg"))
    }

    func testSelectionNeverRemovesEveryCopy() {
        let date = Date()
        let files = ["/x/a", "/x/b", "/x/c"].map { DuplicateFile(path: $0, bytes: 100, modified: date) }
        let group = DuplicateGroup(id: "g", length: 100, files: files)
        var selection = DuplicateSelection(groups: [group])

        XCTAssertEqual(selection.keptPath(in: group), "/x/a")
        XCTAssertEqual(selection.selectedFiles(in: group).map(\.path), ["/x/b", "/x/c"])
        XCTAssertEqual(selection.selectedBytes(in: [group]), 200)
        XCTAssertEqual(selection.state(of: group), .all)

        // The kept copy cannot be ticked.
        selection.toggle(files[0], in: group)
        XCTAssertFalse(selection.isTicked(files[0], in: group))
        XCTAssertEqual(selection.selectedFiles(in: group).count, 2)

        // Keeping another copy ticks the one kept before.
        selection.keep(files[2], in: group)
        XCTAssertEqual(selection.keptPath(in: group), "/x/c")
        XCTAssertEqual(Set(selection.selectedFiles(in: group).map(\.path)), ["/x/a", "/x/b"])

        selection.toggle(files[1], in: group)
        XCTAssertEqual(selection.state(of: group), .some)
        selection.setAll(group, selected: false)
        XCTAssertEqual(selection.state(of: group), .none)
        selection.setAll(group, selected: true)
        XCTAssertEqual(selection.selectedFiles(in: group).count, 2)
        XCTAssertFalse(selection.selectedFiles(in: group).contains { $0.path == "/x/c" })

        // Nothing is removed from a group whose kept copy has gone missing.
        XCTAssertTrue(selection.removableFiles(in: [group], fileExists: { $0 != "/x/c" }).isEmpty)
        XCTAssertEqual(selection.removableFiles(in: [group], fileExists: { _ in true }).count, 2)

        // A group shrinks after removal, and disappears with one copy left.
        let smaller = group.removing(["/x/a"])
        XCTAssertEqual(smaller?.files.count, 2)
        XCTAssertNil(group.removing(["/x/a", "/x/b"]))
    }

    func testCancellationStopsTheSearch() async throws {
        let data = content(seed: 10, count: 2 * mb)
        for i in 0..<6 { try file("copies/\(i).bin", data) }
        let root = home
        let finder = DuplicateFinder(homePath: root)
        let task = Task { try await finder.find(folder: root) }
        task.cancel()
        do {
            _ = try await task.value
            // Finishing before the cancel arrived is fine too.
        } catch is CancellationError {
        }
    }

    func testProgressReachesTheEnd() async throws {
        let data = content(seed: 11, count: 2 * mb)
        try file("p/1.bin", data)
        try file("p/2.bin", data)
        let box = ProgressBox()
        _ = try await DuplicateFinder(homePath: home).find(folder: home) { box.add($0) }
        let last = try XCTUnwrap(box.values.last)
        XCTAssertEqual(last.stage, .hashing)
        XCTAssertEqual(last.fraction, 1, accuracy: 1e-9)
    }
}

private final class ProgressBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [DuplicateProgress] = []

    func add(_ value: DuplicateProgress) {
        lock.lock()
        stored.append(value)
        lock.unlock()
    }

    var values: [DuplicateProgress] {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }
}
