import XCTest
@testable import RoomyCore

/// Every test works in its own temporary folder that stands in for the home folder.
final class JunkFinderTests: XCTestCase {
    private var home = ""
    private let now = Date()
    private let fm = FileManager.default

    override func setUpWithError() throws {
        let base = fm.temporaryDirectory.appendingPathComponent("RoomyTests-\(UUID().uuidString)")
        try fm.createDirectory(at: base, withIntermediateDirectories: true)
        home = DiskScanner.standardize(base.path)
    }

    override func tearDownWithError() throws {
        try? fm.removeItem(atPath: home)
    }

    @discardableResult
    private func file(_ relative: String, bytes: Int = 20_000) throws -> String {
        let path = home + "/" + relative
        try fm.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try Data(repeating: 7, count: bytes).write(to: URL(fileURLWithPath: path))
        return path
    }

    /// Sets the modification date of each path, in order, to `days` ago. List children before parents.
    private func age(_ relatives: [String], days: Double) throws {
        let date = now.addingTimeInterval(-days * 86_400)
        for relative in relatives {
            try fm.setAttributes([.modificationDate: date], ofItemAtPath: home + "/" + relative)
        }
    }

    private func finder(skipping names: Set<String> = []) -> JunkFinder {
        JunkFinder(homePath: home, now: now, skippedCacheNames: names)
    }

    private func byID(_ findings: [JunkFinding]) -> [String: JunkFinding] {
        Dictionary(uniqueKeysWithValues: findings.map { ($0.id, $0) })
    }

    func testFindsKnownJunk() async throws {
        try file("Library/Caches/com.example.app/data.bin")
        try file("Library/Caches/com.apple.Safari/data.bin")
        try file("Library/Caches/com.running.app/data.bin")
        try file("Library/Caches/Homebrew/bottle.tar.gz")
        try file("Library/Logs/app.log")
        try file("Library/Developer/Xcode/DerivedData/MyApp-abcdefghijklmnopqrstuvwxyz/Build/main.o")
        try file("Library/Developer/Xcode/Archives/2024-01-01/MyApp.xcarchive/Info.plist")
        try file("Library/Developer/Xcode/iOS DeviceSupport/17.0 (21A329)/Symbols/dyld")
        try file("Library/Developer/CoreSimulator/Caches/dyld/cache")
        try file(".npm/_cacache/index-v5/aa")
        try file(".gradle/caches/modules/x.jar")
        try file("Downloads/old.dmg")
        try file("Downloads/new.dmg")
        try file("Downloads/old.pdf")
        try file("Documents/keep.txt")
        try file(".Trash/thrown.txt")
        try age(["Downloads/old.dmg", "Downloads/old.pdf"], days: 60)

        let found = byID(await finder(skipping: ["com.running.app"]).find())

        XCTAssertEqual(found["caches"]?.items.map(\.name), ["com.example.app"],
                       "macOS caches, running apps and package manager caches are not app caches")
        XCTAssertEqual(found["logs"]?.items.map(\.name), ["app.log"])
        XCTAssertEqual(found["derivedData"]?.items.map(\.name), ["MyApp"])
        XCTAssertEqual(found["archives"]?.items.map(\.name), ["MyApp.xcarchive"])
        XCTAssertEqual(found["deviceSupport"]?.items.map(\.name), ["iOS 17.0 (21A329)"])
        XCTAssertEqual(found["simulatorCaches"]?.items.map(\.name), ["dyld"])
        XCTAssertEqual(Set(found["packageCaches"]?.items.map(\.name) ?? []), ["Homebrew", "npm", "Gradle"])
        XCTAssertEqual(found["installers"]?.items.map(\.name), ["old.dmg"])
        XCTAssertNil(found["nodeModules"], "node_modules are only looked for in a scan")

        XCTAssertEqual(found["archives"]?.preselected, false)
        XCTAssertEqual(found["derivedData"]?.preselected, true)

        let trash = try XCTUnwrap(found["trash"])
        XCTAssertTrue(trash.isPermanent)
        XCTAssertEqual(trash.items.map(\.name), ["thrown.txt"])

        let policy = SafetyPolicy(homePath: home)
        for finding in found.values {
            for item in finding.items {
                XCTAssertGreaterThan(item.bytes, 0)
                XCTAssertFalse(policy.verdict(for: item.path).isBlocked, item.path)
                XCTAssertFalse(item.path.contains("/Documents/"), item.path)
                XCTAssertTrue(item.path.hasPrefix(home + "/"), item.path)
            }
        }
        // Nothing was touched.
        XCTAssertTrue(fm.fileExists(atPath: home + "/Library/Caches/com.example.app/data.bin"))
    }

    func testEmptyHomeFindsNothing() async {
        let found = await finder().find()
        XCTAssertTrue(found.isEmpty)
    }

    func testOldNodeModulesFromScan() async throws {
        try file("code/old/node_modules/left-pad/index.js")
        try file("code/old/node_modules/left-pad/node_modules/inner/index.js")
        try file("code/old/package.json")
        try file("code/new/node_modules/left-pad/index.js")
        try age([
            "code/old/node_modules/left-pad/node_modules/inner/index.js",
            "code/old/node_modules/left-pad/node_modules/inner",
            "code/old/node_modules/left-pad/node_modules",
            "code/old/node_modules/left-pad/index.js",
            "code/old/node_modules/left-pad",
            "code/old/node_modules",
        ], days: 45)

        let tree = try await DiskScanner().scan(root: home)
        let found = byID(await finder().find(tree: tree))

        let modules = try XCTUnwrap(found["nodeModules"])
        XCTAssertEqual(modules.items.map(\.name), ["old"])
        XCTAssertEqual(modules.items.first?.path, home + "/code/old/node_modules")
        XCTAssertFalse(modules.preselected)
    }

    func testUnusedSimulators() async throws {
        let devices = "Library/Developer/CoreSimulator/Devices"
        let plist: [String: Any] = ["name": "iPhone 15", "runtime": "com.apple.CoreSimulator.SimRuntime.iOS-17-0"]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        for udid in ["OLD-DEVICE", "NEW-DEVICE"] {
            try file("\(devices)/\(udid)/data/app.bin")
            try data.write(to: URL(fileURLWithPath: home + "/\(devices)/\(udid)/device.plist"))
        }
        try age([
            "\(devices)/OLD-DEVICE/data/app.bin",
            "\(devices)/OLD-DEVICE/data",
            "\(devices)/OLD-DEVICE/device.plist",
            "\(devices)/OLD-DEVICE",
        ], days: 400)

        let found = byID(await finder().find())
        let simulators = try XCTUnwrap(found["oldSimulators"])
        XCTAssertEqual(simulators.items.map(\.name), ["iPhone 15 (iOS 17.0)"])
        XCTAssertEqual(simulators.items.first?.path, home + "/\(devices)/OLD-DEVICE")
        XCTAssertFalse(simulators.preselected)
    }

    func testNames() {
        XCTAssertEqual(JunkFinder.runtimeName("com.apple.CoreSimulator.SimRuntime.iOS-17-0"), "iOS 17.0")
        XCTAssertEqual(JunkFinder.runtimeName("com.apple.CoreSimulator.SimRuntime.watchOS-10-2"), "watchOS 10.2")
        XCTAssertEqual(JunkFinder.projectName(fromDerivedData: "MyApp-abcdefghijklmnopqrstuvwxyz"), "MyApp")
        XCTAssertEqual(JunkFinder.projectName(fromDerivedData: "My-App"), "My-App")
    }

    func testDiskUsageCountsHardLinksOnce() throws {
        let original = try file("folder/a.bin", bytes: 200_000)
        try fm.linkItem(atPath: original, toPath: home + "/folder/b.bin")
        let one = DiskUsage.allocatedSize(atPath: original)
        let folder = DiskUsage.allocatedSize(atPath: home + "/folder")
        XCTAssertGreaterThan(one, 0)
        XCTAssertLessThan(folder, one * 2)
    }
}

final class JunkSelectionTests: XCTestCase {
    private let a1 = JunkItem(path: "/h/a1", name: "a1", bytes: 100)
    private let a2 = JunkItem(path: "/h/a2", name: "a2", bytes: 50)
    private let b1 = JunkItem(path: "/h/b1", name: "b1", bytes: 1_000)
    private let t1 = JunkItem(path: "/h/.Trash/t1", name: "t1", bytes: 5_000)

    private var safe: JunkFinding {
        JunkFinding(id: "a", category: .caches, title: "A", explanation: "", items: [a1, a2], preselected: true)
    }
    private var review: JunkFinding {
        JunkFinding(id: "b", category: .developer, title: "B", explanation: "", items: [b1], preselected: false)
    }
    private var trash: JunkFinding {
        JunkFinding(id: "t", category: .trash, title: "T", explanation: "", items: [t1], preselected: true, isPermanent: true)
    }

    func testStartsWithPreselectedOnly() {
        let selection = JunkSelection(findings: [safe, review, trash])
        XCTAssertEqual(selection.paths, ["/h/a1", "/h/a2"])
        XCTAssertEqual(selection.state(of: safe), .all)
        XCTAssertEqual(selection.state(of: review), .none)
        XCTAssertEqual(selection.state(of: trash), .none, "The Trash is never preselected")
        XCTAssertEqual(selection.selectedBytes(in: [safe, review, trash]), 150)
    }

    func testToggleAndSetAll() {
        let findings = [safe, review, trash]
        var selection = JunkSelection(findings: findings)

        selection.toggle(a2, in: safe)
        XCTAssertEqual(selection.state(of: safe), .some)
        XCTAssertEqual(selection.selectedBytes(in: safe), 100)

        selection.setAll(review, selected: true)
        XCTAssertEqual(selection.state(of: review), .all)
        XCTAssertEqual(selection.selectedBytes(in: findings), 1_100)

        selection.setAll(safe, selected: false)
        XCTAssertEqual(selection.state(of: safe), .none)
        XCTAssertEqual(selection.selectedItems(in: findings), [b1])

        // An item is only toggled through the finding it belongs to.
        selection.toggle(a1, in: review)
        XCTAssertFalse(selection.contains(a1))
    }

    func testTrashCanNeverBeSelected() {
        var selection = JunkSelection(findings: [safe, trash])
        selection.setAll(trash, selected: true)
        selection.toggle(t1, in: trash)
        XCTAssertFalse(selection.contains(t1))
        XCTAssertFalse(selection.selectedItems(in: [safe, trash]).contains(t1))
    }

    func testRemovingCleanedItems() {
        var selection = JunkSelection(findings: [safe, review])
        selection.remove(["/h/a1"])
        XCTAssertEqual(selection.paths, ["/h/a2"])
        XCTAssertEqual(safe.removing(["/h/a1"])?.items, [a2])
        XCTAssertNil(review.removing(["/h/b1"]))
    }
}

/// Moves items into a folder inside the test folder instead of the real Trash.
private struct FolderTrasher: Trasher {
    let folder: String

    func moveToTrash(path: String) throws -> String? {
        let destination = folder + "/" + (path as NSString).lastPathComponent
        try FileManager.default.moveItem(atPath: path, toPath: destination)
        return destination
    }
}

final class SmartCleanRemovalTests: XCTestCase {
    private var home = ""
    private let fm = FileManager.default

    override func setUpWithError() throws {
        let base = fm.temporaryDirectory.appendingPathComponent("RoomyTests-\(UUID().uuidString)")
        try fm.createDirectory(at: base, withIntermediateDirectories: true)
        home = DiskScanner.standardize(base.path)
    }

    override func tearDownWithError() throws {
        try? fm.removeItem(atPath: home)
    }

    private func file(_ path: String) throws {
        try fm.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try Data(repeating: 1, count: 5_000).write(to: URL(fileURLWithPath: path))
    }

    func testCleanGoesThroughTheSafetyPolicy() async throws {
        try file(home + "/Library/Logs/app.log")
        try file(home + "/Library/Caches/com.example.app/data.bin")
        let bin = home + "/FakeTrash"
        try fm.createDirectory(atPath: bin, withIntermediateDirectories: true)

        let findings = await JunkFinder(homePath: home).find()
        let selection = JunkSelection(findings: findings)
        let picked = selection.selectedItems(in: findings)
        XCTAssertEqual(picked.count, 2)

        let service = CleanupService(policy: SafetyPolicy(homePath: home), trasher: FolderTrasher(folder: bin), history: nil)
        // A blocked path slipped into the list must still be refused.
        let blocked = [home + "/Library/Keychains/login.keychain-db", "/System/Library"]
        let plan = service.plan(paths: picked.map(\.path) + blocked, sizeOf: { _ in 1 })
        var seen = 0
        let report = service.execute(plan) { _ in seen += 1 }

        XCTAssertEqual(seen, plan.count)
        XCTAssertEqual(report.succeeded.count, 2)
        XCTAssertEqual(Set(report.failed.map(\.path)), Set(blocked))
        XCTAssertFalse(fm.fileExists(atPath: home + "/Library/Logs/app.log"))
        XCTAssertTrue(fm.fileExists(atPath: bin + "/app.log"))
        XCTAssertTrue(fm.fileExists(atPath: bin + "/com.example.app/data.bin"))
    }

    func testTrashEmptierOnlyErasesItemsInTheTrash() throws {
        let trash = home + "/.Trash"
        try file(trash + "/old.txt")
        try file(trash + "/folder/inner.txt")
        try file(home + "/Documents/keep.txt")
        try fm.createSymbolicLink(atPath: trash + "/link", withDestinationPath: home + "/Documents/keep.txt")

        let emptier = TrashEmptier(homePath: home)
        XCTAssertTrue(emptier.canErase(trash + "/old.txt"))
        XCTAssertFalse(emptier.canErase(trash))
        XCTAssertFalse(emptier.canErase(trash + "/folder/inner.txt"))
        XCTAssertFalse(emptier.canErase(trash + "/../Documents"))
        XCTAssertFalse(emptier.canErase(home + "/Documents/keep.txt"))
        XCTAssertFalse(emptier.canErase(home))

        let result = emptier.erase([
            JunkItem(path: trash + "/old.txt", name: "old.txt", bytes: 10),
            JunkItem(path: trash + "/folder", name: "folder", bytes: 20),
            JunkItem(path: trash + "/link", name: "link", bytes: 1),
            JunkItem(path: home + "/Documents/keep.txt", name: "keep.txt", bytes: 40),
        ])

        XCTAssertEqual(result.erased.count, 3)
        XCTAssertEqual(result.freedBytes, 31)
        XCTAssertEqual(Array(result.failed.keys), [home + "/Documents/keep.txt"])
        XCTAssertFalse(fm.fileExists(atPath: trash + "/old.txt"))
        XCTAssertFalse(fm.fileExists(atPath: trash + "/folder"))
        XCTAssertTrue(fm.fileExists(atPath: home + "/Documents/keep.txt"), "A link in the Trash never takes its target with it")
        XCTAssertTrue(fm.fileExists(atPath: trash), "The Trash folder itself stays")
    }
}
