import XCTest
@testable import RoomyCore

/// `roomy-scan clean` on a temporary home folder, with a test Trash.
final class CleanCommandTests: XCTestCase {
    private var home = ""
    private var bin: TestTrasher!
    private var output: [String] = []
    private let fm = FileManager.default

    override func setUpWithError() throws {
        let base = fm.temporaryDirectory.appendingPathComponent("RoomyClean-\(UUID().uuidString)")
        try fm.createDirectory(at: base, withIntermediateDirectories: true)
        home = DiskScanner.standardize(base.path)
        bin = TestTrasher(folder: home + "-bin")
        output = []
        try file("Library/Caches/com.example.app/data.bin", bytes: 300_000)
        try file("Library/Logs/app.log", bytes: 100_000)
        try file("Library/Developer/Xcode/Archives/2024-01-01/MyApp.xcarchive/Info.plist", bytes: 50_000)
        try file("Library/Keychains/login.keychain-db", bytes: 10_000)
        try file(".Trash/thrown.txt", bytes: 10_000)
        try file("Documents/keep.txt", bytes: 10_000)
    }

    override func tearDownWithError() throws {
        try? fm.removeItem(atPath: home)
        try? fm.removeItem(atPath: bin.folder)
    }

    private func file(_ relative: String, bytes: Int) throws {
        let path = home + "/" + relative
        try fm.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try Data(repeating: 7, count: bytes).write(to: URL(fileURLWithPath: path))
    }

    private func command(dryRun: Bool = false, yes: Bool = false, answer: String? = nil,
                         history: CleanupHistory? = nil) -> CleanCommand {
        let service = CleanupService(policy: SafetyPolicy(homePath: home), trasher: bin, history: history, tool: .commandLine)
        var command = CleanCommand(clean: JunkClean(finder: JunkFinder(homePath: home), service: service),
                                   dryRun: dryRun, assumeYes: yes)
        command.readAnswer = { answer }
        command.write = { self.output.append($0) }
        command.prompt = { self.output.append($0) }
        return command
    }

    private var cache: String { home + "/Library/Caches/com.example.app" }
    private var logs: String { home + "/Library/Logs/app.log" }

    func testOptionsAreRead() {
        XCTAssertEqual(CleanCommand.options([])?.dryRun, false)
        XCTAssertEqual(CleanCommand.options(["--dry-run"])?.dryRun, true)
        XCTAssertEqual(CleanCommand.options(["--yes"])?.yes, true)
        XCTAssertEqual(CleanCommand.options(["-n", "-y"]).map { [$0.dryRun, $0.yes] }, [true, true])
        XCTAssertNil(CleanCommand.options(["--force"]))
    }

    func testDryRunListsTheDefaultItemsAndMovesNothing() async throws {
        let status = await command(dryRun: true).run()
        XCTAssertEqual(status, 0)
        XCTAssertTrue(bin.moved.isEmpty)
        let listed = output.dropLast().joined(separator: "\n")
        XCTAssertTrue(listed.contains(cache), listed)
        XCTAssertTrue(listed.contains(logs), listed)
        XCTAssertFalse(listed.contains("xcarchive"), "an Xcode archive needs a review first")
        XCTAssertFalse(listed.contains("Keychains") || listed.contains(".Trash") || listed.contains("Documents"), listed)
        XCTAssertTrue(output.last?.contains("Dry run: nothing was moved.") == true, "\(output)")
        XCTAssertTrue(fm.fileExists(atPath: cache))
    }

    func testAnythingButYesMovesNothing() async throws {
        for answer in [nil, "", "n", "no", "maybe"] {
            output = []
            let status = await command(answer: answer).run()
            XCTAssertEqual(status, 0)
            XCTAssertTrue(output.contains { $0.hasSuffix("[y/N] ") }, "\(output)")
            XCTAssertEqual(output.last, "Nothing was moved.")
        }
        XCTAssertTrue(bin.moved.isEmpty)
        XCTAssertTrue(fm.fileExists(atPath: cache))
    }

    func testYesMovesTheItemsToTheTrashAndNotesTheClean() async throws {
        let history = CleanupHistory(fileURL: URL(fileURLWithPath: bin.folder + "-history.jsonl"))
        defer { try? fm.removeItem(at: history.fileURL) }
        let status = await command(answer: "y", history: history).run()
        XCTAssertEqual(status, 0)
        XCTAssertEqual(Set(bin.moved), [cache, logs])
        XCTAssertFalse(fm.fileExists(atPath: cache))
        XCTAssertTrue(fm.fileExists(atPath: home + "/Library/Developer/Xcode/Archives"))
        XCTAssertTrue(fm.fileExists(atPath: home + "/.Trash/thrown.txt"), "the Trash is never emptied")
        XCTAssertTrue(output.last?.hasPrefix("Moved 2 of 2 to the Trash") == true, "\(output)")
        XCTAssertEqual(history.load().map(\.tool), [.commandLine])
    }

    func testYesOptionSkipsTheQuestion() async throws {
        let status = await command(yes: true).run()
        XCTAssertEqual(status, 0)
        XCTAssertFalse(output.contains { $0.contains("[y/N]") })
        XCTAssertEqual(Set(bin.moved), [cache, logs])
    }

    func testNothingToClean() async throws {
        try fm.removeItem(atPath: home + "/Library/Caches")
        try fm.removeItem(atPath: home + "/Library/Logs")
        let status = await command(yes: true).run()
        XCTAssertEqual(status, 0)
        XCTAssertTrue(bin.moved.isEmpty)
        XCTAssertTrue(output.first?.hasPrefix("Nothing to clean") == true, "\(output)")
    }

    func testItemsTheRulesBlockAreNeverOffered() async throws {
        // A policy that confines everything to another folder blocks all of the junk.
        let service = CleanupService(policy: SafetyPolicy(homePath: home, confinedTo: home + "/Documents"), trasher: bin,
                                     history: nil, tool: .commandLine)
        let items = await JunkClean(finder: JunkFinder(homePath: home), service: service).items()
        XCTAssertTrue(items.isEmpty, "\(items.map(\.path))")
    }
}
