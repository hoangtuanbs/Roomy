import XCTest
@testable import RoomyCore

/// Every test works in its own temporary folder that stands in for the home folder and the Applications folder.
final class AppUninstallerTests: XCTestCase {
    private var home = ""
    private var apps = ""
    private let fm = FileManager.default

    override func setUpWithError() throws {
        let base = fm.temporaryDirectory.appendingPathComponent("RoomyAppTests-\(UUID().uuidString)")
        try fm.createDirectory(at: base, withIntermediateDirectories: true)
        let root = DiskScanner.standardize(base.path)
        home = root + "/home"
        apps = root + "/Applications"
        try fm.createDirectory(atPath: home + "/Library", withIntermediateDirectories: true)
        try fm.createDirectory(atPath: apps, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? fm.removeItem(atPath: (home as NSString).deletingLastPathComponent)
    }

    private var uninstaller: AppUninstaller { AppUninstaller(homePath: home, appFolders: [apps]) }

    @discardableResult
    private func makeApp(_ name: String, id: String?, folder: String? = nil, version: String = "1.0",
                         helpers: [String] = []) throws -> String {
        let path = (folder ?? apps) + "/\(name).app"
        try fm.createDirectory(atPath: path + "/Contents/MacOS", withIntermediateDirectories: true)
        var info: [String: Any] = ["CFBundleName": name, "CFBundleShortVersionString": version]
        if let id { info["CFBundleIdentifier"] = id }
        let data = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        try data.write(to: URL(fileURLWithPath: path + "/Contents/Info.plist"))
        try Data(count: 4096).write(to: URL(fileURLWithPath: path + "/Contents/MacOS/\(name)"))
        for helper in helpers {
            let helperPath = path + "/Contents/Library/LoginItems/\(helper).app/Contents"
            try fm.createDirectory(atPath: helperPath, withIntermediateDirectories: true)
            let helperInfo = try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": helper],
                                                                 format: .xml, options: 0)
            try helperInfo.write(to: URL(fileURLWithPath: helperPath + "/Info.plist"))
        }
        return path
    }

    /// Makes a file or, when the name has no extension, a folder with a file in it, under `~/Library`.
    @discardableResult
    private func library(_ relative: String) throws -> String {
        let path = home + "/Library/" + relative
        if (relative as NSString).pathExtension.isEmpty || relative.hasSuffix(".savedState") {
            try fm.createDirectory(atPath: path, withIntermediateDirectories: true)
            try Data(count: 1000).write(to: URL(fileURLWithPath: path + "/data"))
        } else {
            try fm.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            try Data(count: 100).write(to: URL(fileURLWithPath: path))
        }
        return path
    }

    private func names(_ leftovers: [Leftover]) -> Set<String> {
        Set(leftovers.map { String($0.path.dropFirst(home.count + "/Library/".count)) })
    }

    private func leftovers(of name: String) throws -> [Leftover] {
        let installed = uninstaller.listApps()
        let app = try XCTUnwrap(installed.first { $0.name == name })
        return uninstaller.leftovers(for: app, installed: installed)
    }

    func testListsAppsWithInfo() throws {
        try makeApp("Zebra", id: "com.example.zebra", version: "2.3")
        try makeApp("Alpha", id: "com.example.alpha")
        let utilities = apps + "/Utilities"
        try fm.createDirectory(atPath: utilities, withIntermediateDirectories: true)
        try makeApp("Tool", id: "com.example.tool", folder: utilities)
        try fm.createDirectory(atPath: apps + "/Not an app", withIntermediateDirectories: true)

        let list = uninstaller.listApps()
        XCTAssertEqual(list.map(\.name), ["Alpha", "Tool", "Zebra"])
        let zebra = try XCTUnwrap(list.last)
        XCTAssertEqual(zebra.bundleID, "com.example.zebra")
        XCTAssertEqual(zebra.version, "2.3")
        XCTAssertEqual(zebra.path, apps + "/Zebra.app")
    }

    func testFindsLeftoversByBundleIDAndName() throws {
        try makeApp("Sketchy", id: "com.maker.sketchy")
        try library("Application Support/Sketchy")
        try library("Application Support/com.maker.sketchy")
        try library("Caches/com.maker.sketchy")
        try library("Caches/com.maker.sketchy.ShipIt")
        try library("Preferences/com.maker.sketchy.plist")
        try library("Preferences/ByHost/com.maker.sketchy.0A1B2C3D-0000-1111-2222-333344445555.plist")
        try library("Saved Application State/com.maker.sketchy.savedState")
        try library("Containers/com.maker.sketchy")
        try library("Group Containers/ABCDE12345.com.maker.sketchy")
        try library("HTTPStorages/com.maker.sketchy")
        try library("HTTPStorages/com.maker.sketchy.binarycookies")
        try library("WebKit/com.maker.sketchy")
        try library("Logs/Sketchy")
        try library("LaunchAgents/com.maker.sketchy.updater.plist")
        try library("Cookies/com.maker.sketchy.binarycookies")

        let found = try leftovers(of: "Sketchy")
        XCTAssertEqual(names(found), [
            "Application Support/Sketchy", "Application Support/com.maker.sketchy", "Caches/com.maker.sketchy",
            "Caches/com.maker.sketchy.ShipIt", "Preferences/com.maker.sketchy.plist",
            "Preferences/ByHost/com.maker.sketchy.0A1B2C3D-0000-1111-2222-333344445555.plist",
            "Saved Application State/com.maker.sketchy.savedState", "Containers/com.maker.sketchy",
            "Group Containers/ABCDE12345.com.maker.sketchy", "HTTPStorages/com.maker.sketchy",
            "HTTPStorages/com.maker.sketchy.binarycookies", "WebKit/com.maker.sketchy", "Logs/Sketchy",
            "LaunchAgents/com.maker.sketchy.updater.plist", "Cookies/com.maker.sketchy.binarycookies",
        ])
        XCTAssertEqual(found.first { $0.name == "com.maker.sketchy.plist" }?.kind, .preferences)

        // Items named by a dotted child of the bundle id may belong to another app, so they are left to review.
        let review = Set(found.filter(\.needsReview).map(\.name))
        XCTAssertEqual(review, ["com.maker.sketchy.ShipIt", "com.maker.sketchy.updater.plist"])
        XCTAssertFalse(try XCTUnwrap(found.first { $0.path.hasSuffix("Caches/com.maker.sketchy") }).needsReview)
        XCTAssertFalse(try XCTUnwrap(found.first { $0.name == "Sketchy" }).needsReview)
    }

    func testDoesNotMatchADifferentAppWithASimilarName() throws {
        try makeApp("Notes Pro", id: "com.maker.notes")
        try makeApp("Notes Pro Max", id: "com.maker.notesmax")
        try makeApp("Notes Pro Helper", id: "com.maker.notes.pro")
        try library("Application Support/Notes Pro")
        try library("Application Support/Notes Pro Max")
        try library("Application Support/Notes")
        try library("Caches/com.maker.notes")
        try library("Caches/com.maker.notesmax")
        try library("Caches/com.maker.notes.pro")
        try library("Caches/com.maker.notes.pro.cache")
        try library("Caches/com.maker.notes2")
        try library("Caches/com.maker")
        try library("Preferences/com.maker.notesmax.plist")
        try library("Preferences/com.maker.notes.plist")
        try library("Containers/xcom.maker.notes")
        try library("Group Containers/ABCDE12345.com.maker")
        try library("Group Containers/group.com.maker.shared")

        XCTAssertEqual(names(try leftovers(of: "Notes Pro")), [
            "Application Support/Notes Pro", "Caches/com.maker.notes", "Preferences/com.maker.notes.plist",
        ])
        XCTAssertEqual(names(try leftovers(of: "Notes Pro Max")), [
            "Application Support/Notes Pro Max", "Caches/com.maker.notesmax", "Preferences/com.maker.notesmax.plist",
        ])
        XCTAssertEqual(names(try leftovers(of: "Notes Pro Helper")), [
            "Caches/com.maker.notes.pro", "Caches/com.maker.notes.pro.cache",
        ])
    }

    func testSharedVendorNamesAreNotMatchedByName() throws {
        try makeApp("Google", id: "com.example.google")
        try library("Application Support/Google")
        XCTAssertTrue(try leftovers(of: "Google").isEmpty)
    }

    func testEmbeddedHelpersOfOtherAppsAreNotClaimed() throws {
        try makeApp("Writer", id: "com.office.writer", helpers: ["com.office.writer.autoupdate"])
        try makeApp("Office Updater", id: "com.office")
        try library("Caches/com.office.writer.autoupdate")
        try library("Caches/com.office.sheets")
        // The updater's bundle ID is a prefix of the writer's, but the writer's files are its own.
        XCTAssertEqual(names(try leftovers(of: "Office Updater")), ["Caches/com.office.sheets"])
    }

    func testAnotherCopyOfTheSameAppKeepsItsFiles() throws {
        try makeApp("Twin", id: "com.example.twin")
        let second = home + "/Applications"
        try fm.createDirectory(atPath: second, withIntermediateDirectories: true)
        try makeApp("Twin", id: "com.example.twin", folder: second)
        try library("Caches/com.example.twin")
        let both = AppUninstaller(homePath: home, appFolders: [apps, second])
        let installed = both.listApps()
        XCTAssertEqual(installed.count, 2)
        XCTAssertTrue(both.leftovers(for: installed[0], installed: installed).isEmpty)
    }

    func testAppleAndRunningAppsAreBlocked() throws {
        let finder = uninstaller
        let apple = InstalledApp(path: apps + "/Safari.app", name: "Safari", bundleID: "com.apple.Safari",
                                 version: nil, iconPath: nil)
        XCTAssertNotNil(finder.blockReason(for: apple))
        XCTAssertTrue(finder.leftovers(for: apple, installed: [apple]).isEmpty)
        let system = InstalledApp(path: "/System/Applications/Thing.app", name: "Thing", bundleID: "com.example.thing",
                                  version: nil, iconPath: nil)
        XCTAssertNotNil(finder.blockReason(for: system))
        let open = InstalledApp(path: apps + "/Open.app", name: "Open", bundleID: "com.example.open",
                                version: nil, iconPath: nil)
        XCTAssertNotNil(finder.blockReason(for: open, runningPaths: [open.path]))
        XCTAssertNil(finder.blockReason(for: open))
    }

    func testOrphansAreLibraryItemsOfAppsNoLongerInstalled() throws {
        try makeApp("Kept", id: "com.example.kept", helpers: ["com.example.kepthelper"])
        try library("Caches/com.example.kept")
        try library("Caches/com.example.kept.sub")
        try library("Caches/com.example.kepthelper")
        try library("Caches/com.apple.Safari")
        try library("Caches/com.example.gone")
        try library("Preferences/com.example.gone.plist")
        try library("Saved Application State/com.example.gone.savedState")
        try library("Application Support/Some Folder")
        try library("Caches/com.example.running")
        try library("Caches/notabundle")
        try library("Group Containers/ABCDE12345.com.example.gone")

        let orphans = uninstaller.orphans(installed: uninstaller.listApps(), knownIDs: ["com.example.running"])
        XCTAssertEqual(orphans.map(\.bundleID), ["com.example.gone"])
        XCTAssertEqual(names(orphans[0].items), [
            "Caches/com.example.gone", "Preferences/com.example.gone.plist",
            "Saved Application State/com.example.gone.savedState",
        ])
    }

    func testBundleIDShapes() {
        XCTAssertTrue(AppUninstaller.looksLikeBundleID("com.maker.app"))
        XCTAssertTrue(AppUninstaller.looksLikeBundleID("org.some-thing.App_2"))
        XCTAssertFalse(AppUninstaller.looksLikeBundleID("com.maker"))
        XCTAssertFalse(AppUninstaller.looksLikeBundleID("My App.data.x"))
        XCTAssertFalse(AppUninstaller.looksLikeBundleID("1com.maker.app"))
        XCTAssertFalse(AppUninstaller.looksLikeBundleID("com..app"))
        XCTAssertTrue(AppUninstaller.isTeamID("UBF8T346G9"))
        XCTAssertFalse(AppUninstaller.isTeamID("group"))
    }

    func testMeasureSortsLargestFirst() async throws {
        let small = try library("Caches/com.example.small/sub.bin")
        let big = home + "/Library/Caches/com.example.big"
        try fm.createDirectory(atPath: big, withIntermediateDirectories: true)
        try Data(count: 500_000).write(to: URL(fileURLWithPath: big + "/blob"))
        let measured = await AppUninstaller.measure([
            Leftover(path: small, name: "small", kind: .caches),
            Leftover(path: big, name: "big", kind: .caches),
        ])
        XCTAssertEqual(measured.map(\.name), ["big", "small"])
        XCTAssertGreaterThan(measured[0].bytes, measured[1].bytes)
    }
}
