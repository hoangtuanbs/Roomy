import XCTest
@testable import RoomyCore

/// Moves items into a folder inside the test folder instead of the real Trash, records every call,
/// and fails for the names it is told to.
private final class RecordingTrasher: Trasher, @unchecked Sendable {
    let folder: String
    let failingNames: Set<String>
    private let lock = NSLock()
    private var calls: [String] = []

    init(folder: String, failingNames: Set<String> = []) {
        self.folder = folder
        self.failingNames = failingNames
    }

    var called: [String] {
        lock.lock()
        defer { lock.unlock() }
        return calls
    }

    func moveToTrash(path: String) throws -> String? {
        lock.lock()
        calls.append(path)
        lock.unlock()
        let name = (path as NSString).lastPathComponent
        if failingNames.contains(name) {
            throw NSError(domain: "Test", code: 1, userInfo: [NSLocalizedDescriptionKey: "The item is in use."])
        }
        let destination = folder + "/" + name
        try FileManager.default.moveItem(atPath: path, toPath: destination)
        return destination
    }
}

final class CleanupTests: XCTestCase {
    private var home = ""
    private var bin = ""
    private let fm = FileManager.default

    override func setUpWithError() throws {
        let base = fm.temporaryDirectory.appendingPathComponent("RoomyCleanup-\(UUID().uuidString)")
        try fm.createDirectory(at: base, withIntermediateDirectories: true)
        home = DiskScanner.standardize(base.path)
        bin = home + "/FakeTrash"
        try fm.createDirectory(atPath: bin, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? fm.removeItem(atPath: home)
    }

    @discardableResult
    private func file(_ relative: String, bytes: Int = 1_000) throws -> String {
        let path = home + "/" + relative
        try fm.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try Data(repeating: 3, count: bytes).write(to: URL(fileURLWithPath: path))
        return path
    }

    private func service(_ trasher: Trasher, history: CleanupHistory? = nil) -> CleanupService {
        CleanupService(policy: SafetyPolicy(homePath: home), trasher: trasher, history: history)
    }

    // MARK: Planning

    func testPlanNormalizesTheSelectionAndJudgesEachItem() throws {
        let a = try file("Projects/a/data.bin")
        let folder = home + "/Projects/a"
        let other = try file("Projects/b.bin")
        var measured: [String] = []
        let plan = service(RecordingTrasher(folder: bin)).plan(
            paths: [a, folder, folder + "/", other, home + "/Documents", home + "/Library/Caches/x"],
            sizeOf: { measured.append($0); return Int64($0.count) }
        )

        XCTAssertEqual(plan.map(\.path), [home + "/Documents", home + "/Library/Caches/x", folder, other])
        XCTAssertEqual(measured.sorted(), plan.map(\.path).sorted(), "Each kept item is measured once")
        XCTAssertEqual(plan.map(\.bytes), plan.map { Int64($0.path.count) })
        XCTAssertTrue(plan[0].verdict.isBlocked)
        XCTAssertEqual(plan[1].verdict, SafetyPolicy(homePath: home).verdict(for: home + "/Library/Caches/x"))
        XCTAssertEqual(plan[2].verdict, .allowed)
    }

    // MARK: Executing

    func testMovesItemsToTheTrashAndCountsWhatWasFreed() throws {
        let a = try file("Downloads/a.dmg")
        let b = try file("Library/Caches/app/cache.db")
        let trasher = RecordingTrasher(folder: bin)
        var progress: [CleanupResult] = []
        let items = [CleanupItem(path: a, bytes: 100, verdict: .allowed),
                     CleanupItem(path: b, bytes: 250, verdict: .caution("Library"))]

        let report = service(trasher).execute(items) { progress.append($0) }

        XCTAssertEqual(report.results.map(\.path), [a, b])
        XCTAssertEqual(progress, report.results, "Progress is reported once per item, in order")
        XCTAssertEqual(report.freedBytes, 350)
        XCTAssertEqual(report.succeeded.count, 2)
        XCTAssertTrue(report.failed.isEmpty)
        XCTAssertEqual(report.results.map(\.trashedTo), [bin + "/a.dmg", bin + "/cache.db"])
        XCTAssertFalse(fm.fileExists(atPath: a))
        XCTAssertFalse(fm.fileExists(atPath: b))
        XCTAssertTrue(fm.fileExists(atPath: bin + "/a.dmg"))
        XCTAssertTrue(fm.fileExists(atPath: bin + "/cache.db"))
    }

    func testBlockedItemsAreReportedAndNeverMoved() throws {
        let doc = try file("Documents/report.pdf")
        let ok = try file("Downloads/old.zip")
        let trasher = RecordingTrasher(folder: bin)
        // A stale "allowed" verdict in the plan must not get past the policy.
        let items = [
            CleanupItem(path: home + "/Documents", bytes: 1_000, verdict: .allowed),
            CleanupItem(path: home, bytes: 9_000, verdict: .allowed),
            CleanupItem(path: "/System/Library", bytes: 5_000, verdict: .allowed),
            CleanupItem(path: home + "/Library/Keychains", bytes: 10, verdict: .allowed),
            CleanupItem(path: ok, bytes: 40, verdict: .allowed),
        ]

        let report = service(trasher).execute(items)

        XCTAssertEqual(trasher.called, [ok], "Only the allowed item reaches the Trash")
        XCTAssertEqual(report.results.count, 5)
        XCTAssertEqual(report.failed.map(\.path), [home + "/Documents", home, "/System/Library", home + "/Library/Keychains"])
        XCTAssertTrue(report.failed.allSatisfy { $0.trashedTo == nil && !($0.error ?? "").isEmpty })
        XCTAssertEqual(report.freedBytes, 40)
        XCTAssertTrue(fm.fileExists(atPath: doc))
    }

    func testPartialFailuresAreReportedAndTheRestStillMoves() throws {
        let a = try file("Downloads/a.bin")
        let busy = try file("Downloads/busy.bin")
        let c = try file("Downloads/c.bin")
        let missing = home + "/Downloads/gone.bin"
        let trasher = RecordingTrasher(folder: bin, failingNames: ["busy.bin"])
        let items = [a, busy, missing, c].map { CleanupItem(path: $0, bytes: 10, verdict: .allowed) }

        let report = service(trasher).execute(items)

        XCTAssertEqual(trasher.called, [a, busy, missing, c])
        XCTAssertEqual(report.succeeded.map(\.path), [a, c])
        XCTAssertEqual(report.failed.map(\.path), [busy, missing])
        XCTAssertEqual(report.failed.first?.error, "The item is in use.")
        XCTAssertNotNil(report.failed.last?.error)
        XCTAssertEqual(report.freedBytes, 20, "Only items that moved count as freed")
        XCTAssertTrue(fm.fileExists(atPath: busy), "A failed item stays where it was")
    }

    func testNothingIsLostWhenTheTrashRefusesEverything() throws {
        let paths = try (1...3).map { try file("Downloads/f\($0).bin") }
        let trasher = RecordingTrasher(folder: bin, failingNames: Set(paths.map { ($0 as NSString).lastPathComponent }))
        let report = service(trasher).execute(paths.map { CleanupItem(path: $0, bytes: 1, verdict: .allowed) })

        XCTAssertEqual(report.freedBytes, 0)
        XCTAssertEqual(report.failed.count, 3)
        XCTAssertTrue(paths.allSatisfy { fm.fileExists(atPath: $0) })
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: bin), [])
    }

    func testAnEmptyPlanDoesNothing() {
        let trasher = RecordingTrasher(folder: bin)
        let report = service(trasher).execute([])
        XCTAssertTrue(report.results.isEmpty)
        XCTAssertEqual(report.freedBytes, 0)
        XCTAssertTrue(trasher.called.isEmpty)
    }

    // MARK: History

    func testEachRunIsAddedToTheHistory() throws {
        let history = CleanupHistory(fileURL: URL(fileURLWithPath: home + "/State/history.jsonl"))
        XCTAssertEqual(history.load(), [])
        let a = try file("Downloads/a.bin")
        let b = try file("Downloads/b.bin")
        let cleanup = service(RecordingTrasher(folder: bin), history: history)

        let first = cleanup.execute([CleanupItem(path: a, bytes: 7, verdict: .allowed)])
        let second = cleanup.execute([CleanupItem(path: b, bytes: 9, verdict: .allowed),
                                      CleanupItem(path: home, bytes: 1, verdict: .allowed)])

        let loaded = history.load()
        XCTAssertEqual(loaded.count, 2)
        XCTAssertEqual(loaded.map(\.results), [first.results, second.results])
        XCTAssertEqual(loaded.map(\.freedBytes), [7, 9])
        XCTAssertEqual(loaded[1].failed.map(\.path), [home])
        XCTAssertEqual(loaded[0].date.timeIntervalSince1970, first.date.timeIntervalSince1970, accuracy: 1)
    }

    func testHistorySkipsDamagedLines() throws {
        let url = URL(fileURLWithPath: home + "/history.jsonl")
        let history = CleanupHistory(fileURL: url)
        try history.append(CleanupReport(date: Date(timeIntervalSince1970: 1_700_000_000), results: []))
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("not json\n".utf8))
        try handle.close()
        try history.append(CleanupReport(date: Date(timeIntervalSince1970: 1_700_000_100), results: []))

        XCTAssertEqual(history.load().map(\.date.timeIntervalSince1970), [1_700_000_000, 1_700_000_100])
    }

    func testErrorsDescribeThemselves() {
        XCTAssertEqual(CleanupError.blocked("Not this one.").errorDescription, "Not this one.")
        XCTAssertFalse((CleanupError.trashUnavailable.errorDescription ?? "").isEmpty)
    }

    // MARK: The real Trash

    func testSystemTrasherUsesTheTrashAndThePutBackWorks() throws {
        let path = try file("Downloads/roomy-test-\(UUID().uuidString).txt")
        #if os(macOS)
        let destination = try XCTUnwrap(SystemTrasher().moveToTrash(path: path))
        XCTAssertFalse(fm.fileExists(atPath: path))
        XCTAssertTrue(fm.fileExists(atPath: destination), "The item is in the Trash, not gone")
        XCTAssertTrue(destination.contains("/.Trash") || destination.contains("/.Trashes"), destination)
        // Put it back, so the test leaves the real Trash as it was.
        try fm.moveItem(atPath: destination, toPath: path)
        XCTAssertTrue(fm.fileExists(atPath: path))
        #else
        XCTAssertThrowsError(try SystemTrasher().moveToTrash(path: path))
        XCTAssertTrue(fm.fileExists(atPath: path))
        #endif
    }
}

/// TrashEmptier is the one thing that erases for good. These tests only ever use a Trash folder inside a
/// temporary home folder.
final class TrashEmptierTests: XCTestCase {
    private var home = ""
    private var trash = ""
    private let fm = FileManager.default

    override func setUpWithError() throws {
        let base = fm.temporaryDirectory.appendingPathComponent("RoomyTrash-\(UUID().uuidString)")
        try fm.createDirectory(at: base, withIntermediateDirectories: true)
        home = DiskScanner.standardize(base.path)
        trash = home + "/.Trash"
    }

    override func tearDownWithError() throws {
        try? fm.removeItem(atPath: home)
    }

    private func file(_ path: String, bytes: Int = 100) throws {
        try fm.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try Data(repeating: 9, count: bytes).write(to: URL(fileURLWithPath: path))
    }

    func testTrashPathIsInsideTheHomeFolder() {
        XCTAssertEqual(TrashEmptier(homePath: "/Users/tester/").trashPath, "/Users/tester/.Trash")
        XCTAssertEqual(TrashEmptier().trashPath, DiskScanner.standardize(NSHomeDirectory()) + "/.Trash")
    }

    func testOnlyItemsDirectlyInTheTrashCanBeErased() throws {
        try file(trash + "/a.txt")
        try file(trash + "/.hidden")
        try file(trash + "/folder/b.txt")
        let emptier = TrashEmptier(homePath: home)

        XCTAssertTrue(emptier.canErase(trash + "/a.txt"))
        XCTAssertTrue(emptier.canErase(trash + "/a.txt/"))
        XCTAssertTrue(emptier.canErase(trash + "/./a.txt"))
        XCTAssertTrue(emptier.canErase(trash + "/.hidden"))
        XCTAssertTrue(emptier.canErase(trash + "/folder"))
        XCTAssertTrue(emptier.canErase(trash + "/not-there-any-more"), "Erasing reports it as failed instead")
        XCTAssertFalse(emptier.canErase(trash))
        XCTAssertFalse(emptier.canErase(trash + "/"))
        XCTAssertFalse(emptier.canErase(trash + "/."))
        XCTAssertFalse(emptier.canErase(trash + "/.."))
        XCTAssertFalse(emptier.canErase(trash + "/folder/b.txt"))
        XCTAssertFalse(emptier.canErase(trash + "/folder/../../Documents"))
        XCTAssertFalse(emptier.canErase(home + "/.Trashy/a.txt"))
        XCTAssertFalse(emptier.canErase(home + "/a.txt"))
        XCTAssertFalse(emptier.canErase("/"))
        XCTAssertFalse(emptier.canErase(""))
    }

    func testNothingCanBeErasedWithoutATrashFolder() throws {
        let emptier = TrashEmptier(homePath: home)
        XCTAssertFalse(emptier.canErase(trash + "/a.txt"), "No Trash folder at all")

        // A Trash that is a link to somewhere else is not trusted.
        try file(home + "/Elsewhere/keep.txt")
        try fm.createSymbolicLink(atPath: trash, withDestinationPath: home + "/Elsewhere")
        XCTAssertFalse(emptier.canErase(trash + "/keep.txt"))
        let result = emptier.erase([JunkItem(path: trash + "/keep.txt", name: "keep.txt", bytes: 100)])
        XCTAssertEqual(result.erased, [])
        XCTAssertEqual(result.freedBytes, 0)
        XCTAssertEqual(Array(result.failed.keys), [trash + "/keep.txt"])
        XCTAssertTrue(fm.fileExists(atPath: home + "/Elsewhere/keep.txt"))

        // A plain file named .Trash is not a Trash either.
        try fm.removeItem(atPath: trash)
        try file(trash)
        XCTAssertFalse(emptier.canErase(trash + "/x"))
    }

    func testEraseCountsOnlyWhatWasErased() throws {
        try file(trash + "/a.txt")
        try file(trash + "/b.txt")
        try file(home + "/Documents/c.txt")
        let emptier = TrashEmptier(homePath: home)

        let result = emptier.erase([
            JunkItem(path: trash + "/a.txt", name: "a.txt", bytes: 100),
            JunkItem(path: trash + "/gone.txt", name: "gone.txt", bytes: 1_000),
            JunkItem(path: trash + "/b.txt", name: "b.txt", bytes: 300),
            JunkItem(path: home + "/Documents/c.txt", name: "c.txt", bytes: 5_000),
        ])

        XCTAssertEqual(result.erased, [trash + "/a.txt", trash + "/b.txt"])
        XCTAssertEqual(result.freedBytes, 400)
        XCTAssertEqual(Set(result.failed.keys), [trash + "/gone.txt", home + "/Documents/c.txt"])
        XCTAssertTrue(fm.fileExists(atPath: home + "/Documents/c.txt"))
        XCTAssertTrue(fm.fileExists(atPath: trash))
        XCTAssertEqual(emptier.erase([]), TrashEraseResult(erased: [], freedBytes: 0, failed: [:]))
    }

    func testALinkedFolderInTheTrashKeepsItsTarget() throws {
        try file(home + "/Projects/app/main.swift")
        try fm.createDirectory(atPath: trash, withIntermediateDirectories: true)
        try fm.createSymbolicLink(atPath: trash + "/Projects", withDestinationPath: home + "/Projects")
        let emptier = TrashEmptier(homePath: home)

        XCTAssertFalse(emptier.canErase(trash + "/Projects/app"), "Not directly in the Trash")
        let result = emptier.erase([
            JunkItem(path: trash + "/Projects/app", name: "app", bytes: 10),
            JunkItem(path: trash + "/Projects", name: "Projects", bytes: 1),
        ])
        XCTAssertEqual(result.erased, [trash + "/Projects"])
        XCTAssertTrue(fm.fileExists(atPath: home + "/Projects/app/main.swift"))
    }
}
