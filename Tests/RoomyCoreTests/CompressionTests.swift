import XCTest
@testable import RoomyCore

/// Moves items into a folder inside the test folder instead of the real Trash, and records the calls.
private final class FolderBin: Trasher, @unchecked Sendable {
    let folder: String
    let fails: Bool
    private let lock = NSLock()
    private var calls: [String] = []

    init(folder: String, fails: Bool = false) {
        self.folder = folder
        self.fails = fails
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
        if fails { throw CleanupError.trashUnavailable }
        let destination = folder + "/" + (path as NSString).lastPathComponent
        try FileManager.default.moveItem(atPath: path, toPath: destination)
        return destination
    }
}

/// Compress and Clean: zip, check the zip, and only then move the original to the Trash.
final class CompressionTests: XCTestCase {
    private var home = ""
    private var bin = ""
    private let fm = FileManager.default

    override func setUpWithError() throws {
        let base = fm.temporaryDirectory.appendingPathComponent("RoomyZip-\(UUID().uuidString)")
        try fm.createDirectory(at: base, withIntermediateDirectories: true)
        home = DiskScanner.standardize(base.path)
        bin = home + "/FakeTrash"
        try fm.createDirectory(atPath: bin, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? fm.removeItem(atPath: home)
    }

    @discardableResult
    private func file(_ relative: String, data: Data) throws -> String {
        let path = home + "/" + relative
        try fm.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try data.write(to: URL(fileURLWithPath: path))
        return path
    }

    private func zeros(_ count: Int) -> Data { Data(repeating: 0, count: count) }

    private func noise(_ count: Int) -> Data {
        var generator = SystemRandomNumberGenerator()
        return Data((0..<count).map { _ in UInt8.random(in: 0...255, using: &generator) })
    }

    private func size(_ path: String) -> Int64 {
        DirectoryReader.entry(atPath: path)?.allocated ?? 0
    }

    private func service(_ trasher: Trasher, history: CleanupHistory? = nil) -> CompressionService {
        CompressionService(policy: SafetyPolicy(homePath: home), trasher: trasher, history: history)
    }

    private func zips(in folder: String) -> [String] {
        ((try? fm.contentsOfDirectory(atPath: folder)) ?? []).filter { $0.hasSuffix(".zip") }.sorted()
    }

    // MARK: Archive names

    func testArchiveNamesNeverReplaceAnExistingFile() throws {
        let log = try file("Logs/app.log", data: zeros(10))
        XCTAssertEqual(CompressionService.archivePath(for: log), log + ".zip")
        XCTAssertEqual(CompressionService.archivePath(for: home + "/Logs/"), home + "/Logs.zip")
        try file("Logs/app.log.zip", data: zeros(1))
        XCTAssertEqual(CompressionService.archivePath(for: log), log + " 2.zip")
        try file("Logs/app.log 2.zip", data: zeros(1))
        XCTAssertEqual(CompressionService.archivePath(for: log), log + " 3.zip")
    }

    func testResultSavings() {
        let ok = CompressionResult(sourcePath: "/a", archivePath: "/a.zip", originalBytes: 100, archiveBytes: 30, trashedTo: "/t", error: nil)
        XCTAssertTrue(ok.succeeded)
        XCTAssertEqual(ok.savedBytes, 70)
        let bigger = CompressionResult(sourcePath: "/a", archivePath: "/a.zip", originalBytes: 100, archiveBytes: 130, trashedTo: "/t", error: nil)
        XCTAssertEqual(bigger.savedBytes, 0)
        let failed = CompressionResult(sourcePath: "/a", archivePath: nil, originalBytes: 100, archiveBytes: 0, trashedTo: nil, error: "no")
        XCTAssertFalse(failed.succeeded)
        XCTAssertEqual(failed.savedBytes, 0)
    }

    // MARK: Refusals that never start

    func testRefusesWithoutTouchingAnything() async throws {
        let trash = FolderBin(folder: bin)
        let zipper = service(trash)
        let link = home + "/Downloads/link"
        try file("Downloads/real.log", data: zeros(50_000))
        try fm.createSymbolicLink(atPath: link, withDestinationPath: home + "/Downloads/real.log")
        try file("Downloads/empty.log", data: Data())

        let blocked = await zipper.compressAndTrash(path: home + "/Documents", originalBytes: 1_000)
        let missing = await zipper.compressAndTrash(path: home + "/Downloads/gone.log", originalBytes: 1_000)
        let linked = await zipper.compressAndTrash(path: link, originalBytes: 1_000)
        let empty = await zipper.compressAndTrash(path: home + "/Downloads/empty.log", originalBytes: 0)

        for result in [blocked, missing, linked, empty] {
            XCTAssertFalse(result.succeeded)
            XCTAssertFalse((result.error ?? "").isEmpty)
            XCTAssertNil(result.archivePath)
            XCTAssertNil(result.trashedTo)
        }
        XCTAssertEqual(blocked.sourcePath, home + "/Documents")
        XCTAssertTrue(trash.called.isEmpty)
        XCTAssertEqual(zips(in: home), [])
        XCTAssertEqual(zips(in: home + "/Downloads"), [])
        XCTAssertTrue(fm.fileExists(atPath: home + "/Downloads/real.log"))
    }

    #if os(macOS)
    // MARK: The full run

    func testZipsChecksAndThenTrashesAFile() async throws {
        let path = try file("Logs/server.log", data: zeros(2_000_000))
        let original = size(path)
        let trash = FolderBin(folder: bin)
        let history = CleanupHistory(fileURL: URL(fileURLWithPath: home + "/history.jsonl"))

        let result = await service(trash, history: history).compressAndTrash(path: path, originalBytes: original)

        XCTAssertTrue(result.succeeded, result.error ?? "")
        XCTAssertEqual(result.archivePath, path + ".zip")
        XCTAssertEqual(result.trashedTo, bin + "/server.log")
        XCTAssertEqual(trash.called, [path])
        XCTAssertFalse(fm.fileExists(atPath: path))
        XCTAssertTrue(fm.fileExists(atPath: bin + "/server.log"), "The original is in the Trash, not gone")
        XCTAssertEqual(result.archiveBytes, size(path + ".zip"))
        XCTAssertGreaterThan(result.savedBytes, original / 2)
        XCTAssertEqual(try runTool("/usr/bin/unzip", ["-tqq", path + ".zip"]).status, 0)
        let names = try runTool("/usr/bin/unzip", ["-Z1", path + ".zip"]).output.split(separator: "\n").map(String.init)
        // ditto --keepParent keeps the folder that holds a single file too.
        XCTAssertTrue(names.contains("Logs/server.log"), "\(names)")

        let records = history.load()
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records.first?.results.first?.bytes, result.savedBytes)
        XCTAssertEqual(records.first?.results.first?.path, path)
    }

    func testZipsAFolderWithItsName() async throws {
        try file("Old Project/a.txt", data: zeros(300_000))
        try file("Old Project/sub/b.txt", data: zeros(300_000))
        let folder = home + "/Old Project"
        let trash = FolderBin(folder: bin)

        let result = await service(trash).compressAndTrash(path: folder + "/", originalBytes: 600_000)

        XCTAssertTrue(result.succeeded, result.error ?? "")
        XCTAssertEqual(result.archivePath, folder + ".zip")
        XCTAssertFalse(fm.fileExists(atPath: folder))
        XCTAssertTrue(fm.fileExists(atPath: bin + "/Old Project/sub/b.txt"))
        let names = try runTool("/usr/bin/unzip", ["-Z1", folder + ".zip"]).output.split(separator: "\n").map(String.init)
        XCTAssertTrue(names.contains("Old Project/a.txt"), "\(names)")
        XCTAssertTrue(names.contains("Old Project/sub/b.txt"), "\(names)")
    }

    // MARK: Failures keep the original

    func testAFailedCheckKeepsTheOriginalAndRemovesTheArchive() async throws {
        let path = try file("Logs/server.log", data: zeros(500_000))
        let trash = FolderBin(folder: bin)
        let history = CleanupHistory(fileURL: URL(fileURLWithPath: home + "/history.jsonl"))
        var zipper = service(trash, history: history)
        zipper.checkTool = "/usr/bin/false"

        let result = await zipper.compressAndTrash(path: path, originalBytes: size(path))

        XCTAssertFalse(result.succeeded)
        XCTAssertNotNil(result.error)
        XCTAssertNil(result.trashedTo)
        XCTAssertTrue(trash.called.isEmpty, "The original is never trashed without a checked archive")
        XCTAssertTrue(fm.fileExists(atPath: path))
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: path)).count, 500_000, "The original is unchanged")
        XCTAssertEqual(zips(in: home + "/Logs"), [], "The unchecked archive is removed")
        XCTAssertEqual(history.load(), [])
    }

    func testAFailedArchiveKeepsTheOriginal() async throws {
        let path = try file("Logs/server.log", data: zeros(500_000))
        let trash = FolderBin(folder: bin)
        var zipper = service(trash)
        zipper.zipTool = "/usr/bin/false"

        let result = await zipper.compressAndTrash(path: path, originalBytes: size(path))

        XCTAssertFalse(result.succeeded)
        XCTAssertTrue(trash.called.isEmpty)
        XCTAssertTrue(fm.fileExists(atPath: path))
        XCTAssertEqual(zips(in: home + "/Logs"), [])
    }

    func testAMissingToolKeepsTheOriginal() async throws {
        let path = try file("Logs/server.log", data: zeros(500_000))
        let trash = FolderBin(folder: bin)
        var zipper = service(trash)
        zipper.checkTool = home + "/no-such-tool"

        let result = await zipper.compressAndTrash(path: path, originalBytes: size(path))

        XCTAssertFalse(result.succeeded)
        XCTAssertTrue(trash.called.isEmpty)
        XCTAssertTrue(fm.fileExists(atPath: path))
        XCTAssertEqual(zips(in: home + "/Logs"), [])
    }

    func testTooLittleSavingKeepsTheOriginal() async throws {
        let path = try file("Movies/random.bin", data: noise(400_000))
        let trash = FolderBin(folder: bin)

        let result = await service(trash).compressAndTrash(path: path, originalBytes: size(path))

        XCTAssertFalse(result.succeeded)
        XCTAssertTrue(trash.called.isEmpty)
        XCTAssertTrue(fm.fileExists(atPath: path))
        XCTAssertEqual(zips(in: home + "/Movies"), [], "The archive that saves too little is removed")
    }

    func testWhenTheTrashFailsBothCopiesStay() async throws {
        let path = try file("Logs/server.log", data: zeros(500_000))
        let trash = FolderBin(folder: bin, fails: true)

        let result = await service(trash).compressAndTrash(path: path, originalBytes: size(path))

        XCTAssertFalse(result.succeeded)
        XCTAssertEqual(trash.called, [path])
        XCTAssertEqual(result.archivePath, path + ".zip")
        XCTAssertTrue(fm.fileExists(atPath: path))
        XCTAssertTrue(fm.fileExists(atPath: path + ".zip"), "The checked archive is kept")
        XCTAssertEqual(result.savedBytes, 0)
    }

    func testCancellingKeepsTheOriginal() async throws {
        let path = try file("Logs/server.log", data: zeros(500_000))
        let trash = FolderBin(folder: bin)
        let zipper = service(trash)
        let bytes = size(path)
        let task = Task { () async -> CompressionResult in
            withUnsafeCurrentTask { $0?.cancel() }
            return await zipper.compressAndTrash(path: path, originalBytes: bytes)
        }

        let result = await task.value

        XCTAssertFalse(result.succeeded)
        XCTAssertTrue(trash.called.isEmpty)
        XCTAssertTrue(fm.fileExists(atPath: path))
        XCTAssertEqual(zips(in: home + "/Logs"), [])
    }

    private func runTool(_ tool: String, _ arguments: [String]) throws -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }
    #endif
}
