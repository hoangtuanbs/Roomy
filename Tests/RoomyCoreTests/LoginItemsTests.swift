import Foundation
import XCTest
@testable import RoomyCore

/// Login items in a temporary home and a temporary stand-in for /Library. launchctl is never run: a recording
/// stand-in takes its place.
final class LoginItemsTests: XCTestCase {
    private var root = ""
    private var home = ""
    private var shared = ""
    private let fm = FileManager.default

    override func setUpWithError() throws {
        let base = fm.temporaryDirectory.appendingPathComponent("RoomyLogin-\(UUID().uuidString)")
        root = DiskScanner.standardize(base.path)
        home = root + "/home"
        shared = root + "/Library"
        try fm.createDirectory(atPath: home + "/Library/LaunchAgents", withIntermediateDirectories: true)
        try fm.createDirectory(atPath: shared, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? fm.removeItem(atPath: root)
    }

    private var finder: LoginItemFinder { LoginItemFinder(homePath: home, sharedLibrary: shared) }

    @discardableResult
    private func plist(_ path: String, _ values: [String: Any]) throws -> String {
        try fm.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        let data = try PropertyListSerialization.data(fromPropertyList: values, format: .xml, options: 0)
        try data.write(to: URL(fileURLWithPath: path))
        return path
    }

    @discardableResult
    private func agent(_ label: String, program: String = "/usr/bin/true") throws -> String {
        try plist(home + "/Library/LaunchAgents/\(label).plist", ["Label": label, "ProgramArguments": [program, "--x"],
                                                                  "RunAtLoad": true])
    }

    private func app(_ name: String, id: String) throws -> InstalledApp {
        let path = root + "/Applications/\(name).app"
        try plist(path + "/Contents/Info.plist", ["CFBundleIdentifier": id, "CFBundleName": name])
        return try XCTUnwrap(AppUninstaller.readApp(at: path))
    }

    func testParsesLaunchctlList() {
        let text = "PID\tStatus\tLabel\n123\t0\tcom.example.a\n-\t78\tcom.example.b\n"
        XCTAssertEqual(SystemLaunchControl.parseList(text), ["com.example.a", "com.example.b"])
    }

    func testFindsAgentsDaemonsAndAppHelpersWithTheirApps() throws {
        let maker = try app("Maker", id: "com.maker.app")
        try plist(maker.path + "/Contents/Library/LoginItems/Maker Helper.app/Contents/Info.plist",
                  ["CFBundleIdentifier": "com.maker.app.helper"])
        try plist(maker.path + "/Contents/Library/LaunchAgents/com.maker.app.agent.plist",
                  ["Label": "com.maker.app.agent", "BundleProgram": "Contents/MacOS/agent"])
        try agent("com.maker.app.updater", program: maker.path + "/Contents/MacOS/updater")
        try agent("org.lonely.tool", program: "/nonexistent/tool")
        try plist(shared + "/LaunchAgents/com.vendor.shared.plist", ["Label": "com.vendor.shared", "Program": "/usr/bin/true",
                                                                     "AssociatedBundleIdentifiers": ["com.maker.app"]])
        try plist(shared + "/LaunchDaemons/com.vendor.daemon.plist", ["Label": "com.vendor.daemon", "Program": "/usr/bin/true",
                                                                      "KeepAlive": true])
        try Data("not a plist".utf8).write(to: URL(fileURLWithPath: shared + "/LaunchAgents/broken.plist"))

        let control = RecordingLaunchControl(loaded: ["com.maker.app.updater", "com.maker.app.helper"])
        let items = finder.find(installed: [maker], control: control)
        XCTAssertEqual(items.map(\.domain), [.userAgent, .userAgent, .systemAgent, .systemDaemon, .appManaged, .appManaged])

        let byLabel = Dictionary(items.map { ($0.label, $0) }, uniquingKeysWith: { a, _ in a })
        let updater = try XCTUnwrap(byLabel["com.maker.app.updater"])
        XCTAssertEqual(updater.ownerName, "Maker")
        XCTAssertEqual(updater.isLoaded, true)
        XCTAssertFalse(updater.programExists)
        let lonely = try XCTUnwrap(byLabel["org.lonely.tool"])
        XCTAssertNil(lonely.ownerName)
        XCTAssertEqual(lonely.isLoaded, false)
        XCTAssertEqual(lonely.program, "/nonexistent/tool")
        XCTAssertEqual(byLabel["com.vendor.shared"]?.ownerName, "Maker", "named by AssociatedBundleIdentifiers")
        XCTAssertNil(byLabel["com.vendor.daemon"]?.isLoaded, "the stand-in cannot read the system domain")
        XCTAssertEqual(byLabel["com.vendor.daemon"]?.startsByItself, true)
        XCTAssertEqual(byLabel["com.maker.app.helper"]?.isLoaded, true)
        XCTAssertEqual(byLabel["com.maker.app.helper"]?.domain, .appManaged)
        XCTAssertNil(byLabel["com.maker.app.agent"]?.plistPath, "an app's own agent is not offered as a file to move")
    }

    func testTurningOffStopsTheAgentAndMovesItsFileToTheTrash() throws {
        let path = try agent("com.example.agent")
        let item = try XCTUnwrap(finder.find(installed: [], control: RecordingLaunchControl()).first)
        let control = RecordingLaunchControl(loaded: ["com.example.agent"])
        let trasher = TestTrasher(folder: root + "/Trash")
        let cleanup = CleanupService(policy: SafetyPolicy(homePath: home), trasher: trasher, history: nil)

        XCTAssertNil(finder.refusal(for: item))
        let result = finder.turnOff(item, control: control, cleanup: cleanup)
        XCTAssertTrue(result.succeeded, result.error ?? "")
        XCTAssertEqual(control.bootedOut, ["com.example.agent"])
        XCTAssertEqual(trasher.moved, [path])
        XCTAssertFalse(fm.fileExists(atPath: path))
    }

    func testAnAgentLaunchdCannotStopIsNotMoved() throws {
        let path = try agent("com.example.stubborn")
        let item = try XCTUnwrap(finder.find(installed: [], control: RecordingLaunchControl()).first)
        let control = RecordingLaunchControl(failing: ["com.example.stubborn"])
        let trasher = TestTrasher(folder: root + "/Trash")
        let result = finder.turnOff(item, control: control,
                                    cleanup: CleanupService(policy: SafetyPolicy(homePath: home), trasher: trasher, history: nil))
        XCTAssertFalse(result.succeeded)
        XCTAssertTrue(trasher.moved.isEmpty)
        XCTAssertTrue(fm.fileExists(atPath: path))
    }

    func testRefusesWhatIsNotYourOwnAgent() throws {
        let control = RecordingLaunchControl()
        let trasher = TestTrasher(folder: root + "/Trash")
        let cleanup = CleanupService(policy: SafetyPolicy(homePath: home), trasher: trasher, history: nil)

        let daemonPath = try plist(shared + "/LaunchDaemons/com.vendor.d.plist", ["Label": "com.vendor.d", "Program": "/x"])
        let daemon = LaunchItem(label: "com.vendor.d", plistPath: daemonPath, domain: .systemDaemon, program: "/x")
        let sharedAgent = LaunchItem(label: "com.vendor.a", plistPath: daemonPath, domain: .systemAgent, program: "/x")
        let helper = LaunchItem(label: "com.maker.helper", plistPath: nil, domain: .appManaged, program: "/x")
        let applePath = try agent("com.apple.something")
        let apple = LaunchItem(label: "com.apple.something", plistPath: applePath, domain: .userAgent, program: "/x")
        // Claims to be a user agent but its file is somewhere else.
        let elsewherePath = try plist(home + "/Documents/com.example.x.plist", ["Label": "com.example.x"])
        let elsewhere = LaunchItem(label: "com.example.x", plistPath: elsewherePath, domain: .userAgent, program: "/x")
        let nested = LaunchItem(label: "com.example.n", plistPath: try plist(home + "/Library/LaunchAgents/sub/n.plist", [:]),
                                domain: .userAgent, program: "/x")
        let gone = LaunchItem(label: "com.example.gone", plistPath: home + "/Library/LaunchAgents/com.example.gone.plist",
                              domain: .userAgent, program: "/x")
        let slashPath = try agent("com.example.slash")
        let slash = LaunchItem(label: "a/b", plistPath: slashPath, domain: .userAgent, program: "/x")

        for item in [daemon, sharedAgent, helper, apple, elsewhere, nested, gone, slash] {
            XCTAssertNotNil(finder.refusal(for: item), item.label)
            let result = finder.turnOff(item, control: control, cleanup: cleanup)
            XCTAssertFalse(result.succeeded, item.label)
        }
        XCTAssertTrue(control.bootedOut.isEmpty, "launchd was asked to stop \(control.bootedOut)")
        XCTAssertTrue(trasher.moved.isEmpty)
    }

    func testTheSafetyRulesCanRefuseToo() throws {
        let path = try agent("com.example.agent")
        // A policy confined to another folder blocks everything in this home, as in the app's flow test.
        let confined = LoginItemFinder(homePath: home, sharedLibrary: shared,
                                       policy: SafetyPolicy(homePath: home, confinedTo: root + "/elsewhere"))
        let item = LaunchItem(label: "com.example.agent", plistPath: path, domain: .userAgent, program: "/usr/bin/true")
        XCTAssertEqual(confined.refusal(for: item), SafetyPolicy.outsideConfinement)
    }
}
