import XCTest
@testable import RoomyCore

/// The flow test may only change files in a sandbox inside a temporary folder, and its safety policy blocks
/// everything outside that sandbox.
final class FlowSandboxTests: XCTestCase {
    private let fm = FileManager.default
    private var temp = ""

    override func setUpWithError() throws {
        let base = fm.temporaryDirectory.appendingPathComponent("RoomyFlow-\(UUID().uuidString)")
        try fm.createDirectory(at: base, withIntermediateDirectories: true)
        temp = SafetyPolicy.realPath(base.path) ?? base.path
    }

    override func tearDownWithError() throws {
        try? fm.removeItem(atPath: temp)
    }

    private func makeFolder(_ relative: String) throws -> String {
        let path = temp + "/" + relative
        try fm.createDirectory(atPath: path, withIntermediateDirectories: true)
        return path
    }

    // MARK: Choosing the sandbox

    func testAcceptsAFolderInsideATemporaryFolder() throws {
        let sandbox = try makeFolder("runner/flow")
        let checked = try FlowSandbox.check(sandbox, temporaryFolders: [temp + "/runner"], homePath: "/Users/nobody")
        XCTAssertEqual(checked, sandbox)
    }

    func testAcceptsAnyOfTheTemporaryFolders() throws {
        let sandbox = try makeFolder("b/flow")
        _ = try makeFolder("a")
        XCTAssertNoThrow(try FlowSandbox.check(sandbox, temporaryFolders: [temp + "/a", temp + "/b"], homePath: "/Users/nobody"))
    }

    func testRefusesTheTemporaryFolderItself() throws {
        let root = try makeFolder("runner")
        XCTAssertThrowsError(try FlowSandbox.check(root, temporaryFolders: [root], homePath: "/Users/nobody")) { error in
            XCTAssertEqual(error as? FlowSandbox.Problem, .outsideTemporaryFolders(root))
        }
    }

    func testRefusesAFolderOutsideTheTemporaryFolders() throws {
        let other = try makeFolder("elsewhere/flow")
        _ = try makeFolder("runner")
        XCTAssertThrowsError(try FlowSandbox.check(other, temporaryFolders: [temp + "/runner"], homePath: "/Users/nobody"))
    }

    func testRefusesALinkThatLeadsOutOfTheTemporaryFolder() throws {
        let outside = try makeFolder("elsewhere/flow")
        let runner = try makeFolder("runner")
        try fm.createSymbolicLink(atPath: runner + "/sneaky", withDestinationPath: outside)
        XCTAssertThrowsError(try FlowSandbox.check(runner + "/sneaky/.", temporaryFolders: [runner], homePath: "/Users/nobody"))
        XCTAssertThrowsError(try FlowSandbox.check(runner + "/../elsewhere/flow", temporaryFolders: [runner], homePath: "/Users/nobody"))
    }

    func testRefusesAMissingFolder() throws {
        let runner = try makeFolder("runner")
        XCTAssertThrowsError(try FlowSandbox.check(runner + "/nothing", temporaryFolders: [runner], homePath: "/Users/nobody")) { error in
            XCTAssertEqual(error as? FlowSandbox.Problem, .missing(runner + "/nothing"))
        }
    }

    func testRefusesTemporaryFoldersThatAreTheDiskOrHoldTheHomeFolder() throws {
        let sandbox = try makeFolder("home/me/flow")
        XCTAssertThrowsError(try FlowSandbox.check(sandbox, temporaryFolders: ["/"], homePath: "/Users/nobody")) { error in
            XCTAssertEqual(error as? FlowSandbox.Problem, .noTemporaryFolder)
        }
        XCTAssertThrowsError(try FlowSandbox.check(sandbox, temporaryFolders: [temp + "/home"], homePath: temp + "/home/me"))
        XCTAssertThrowsError(try FlowSandbox.check(sandbox, temporaryFolders: [], homePath: "/Users/nobody"))
    }

    func testReadsTheTemporaryFoldersFromTheEnvironment() {
        XCTAssertEqual(FlowSandbox.temporaryFolders(environment: ["TMPDIR": "/tmp/a/", "RUNNER_TEMP": "/r", "HOME": "/h"]),
                       ["/tmp/a/", "/r"])
        XCTAssertEqual(FlowSandbox.temporaryFolders(environment: ["TMPDIR": ""]), [])
    }

    // MARK: Confined safety policy

    func testConfinedPolicyBlocksEverythingOutsideTheSandbox() throws {
        let sandbox = try makeFolder("flow")
        let home = try makeFolder("flow/home")
        let policy = SafetyPolicy(homePath: home, confinedTo: sandbox)
        XCTAssertEqual(policy.verdict(for: "/Users/someone/Documents/report.pdf"), .blocked(SafetyPolicy.outsideConfinement))
        XCTAssertEqual(policy.verdict(for: temp + "/other.txt"), .blocked(SafetyPolicy.outsideConfinement))
        XCTAssertEqual(policy.verdict(for: sandbox), .blocked(SafetyPolicy.outsideConfinement))
        XCTAssertEqual(policy.verdict(for: sandbox + "/../other.txt"), .blocked(SafetyPolicy.outsideConfinement))
        XCTAssertEqual(policy.verdict(for: sandbox + "x/file"), .blocked(SafetyPolicy.outsideConfinement))
    }

    func testConfinedPolicyStillAppliesTheUsualRulesInside() throws {
        let sandbox = try makeFolder("flow")
        let home = try makeFolder("flow/home")
        // Real folders, as the app only judges what it found on disk.
        let keychains = try makeFolder("flow/home/Library/Keychains")
        fm.createFile(atPath: keychains + "/login.keychain-db", contents: Data("k".utf8))
        let policy = SafetyPolicy(homePath: home, confinedTo: sandbox)
        XCTAssertEqual(policy.verdict(for: home + "/Movies/holiday.mov"), .allowed)
        XCTAssertTrue(policy.verdict(for: home).isBlocked)
        XCTAssertTrue(policy.verdict(for: home + "/Library/Keychains/login.keychain-db").isBlocked)
        XCTAssertFalse(policy.verdict(for: home + "/Library/Caches/com.example").isBlocked)
    }

    func testConfinedPolicyFollowsLinksOutOfTheSandbox() throws {
        let sandbox = try makeFolder("flow")
        let outside = try makeFolder("outside")
        fm.createFile(atPath: outside + "/precious.txt", contents: Data("keep".utf8))
        try fm.createSymbolicLink(atPath: sandbox + "/link", withDestinationPath: outside)
        let policy = SafetyPolicy(homePath: sandbox + "/home", confinedTo: sandbox)
        XCTAssertEqual(policy.verdict(for: sandbox + "/link/precious.txt"), .blocked(SafetyPolicy.outsideConfinement))
        // The link itself is inside; the Trash would move only the link.
        XCTAssertFalse(policy.verdict(for: sandbox + "/link").isBlocked)
    }

    func testUnconfinedPolicyIsUnchanged() {
        let policy = SafetyPolicy(homePath: "/Users/tester")
        XCTAssertNil(policy.confinedTo)
        XCTAssertEqual(policy.verdict(for: "/Users/tester/Movies/holiday.mov"), .allowed)
    }

    func testCleanupServiceRefusesPathsOutsideTheSandbox() throws {
        let sandbox = try makeFolder("flow")
        let outside = try makeFolder("outside")
        let file = outside + "/precious.txt"
        fm.createFile(atPath: file, contents: Data("keep".utf8))
        let service = CleanupService(policy: SafetyPolicy(homePath: sandbox + "/home", confinedTo: sandbox),
                                     trasher: RefusingTrasher(), history: nil)
        let report = service.execute(service.plan(paths: [file], sizeOf: { _ in 4 }))
        XCTAssertEqual(report.failed.first?.error, SafetyPolicy.outsideConfinement)
        XCTAssertTrue(fm.fileExists(atPath: file))
    }
}

/// Fails the test if anything reaches the Trash.
private struct RefusingTrasher: Trasher {
    func moveToTrash(path: String) throws -> String? {
        XCTFail("\(path) should never reach the Trash")
        return nil
    }
}
