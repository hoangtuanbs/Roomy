import Foundation
import XCTest
@testable import RoomyCore

/// Installer receipts and unused languages, in a temporary folder that stands in for the disk. pkgutil is never run:
/// a fixed package list takes its place.
final class InstallerReceiptsTests: XCTestCase {
    private var root = ""
    private let fm = FileManager.default
    private var lockedFolders: [String] = []

    override func setUpWithError() throws {
        let base = fm.temporaryDirectory.appendingPathComponent("RoomyReceipts-\(UUID().uuidString)")
        root = DiskScanner.standardize(base.path)
        try fm.createDirectory(atPath: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        for folder in lockedFolders { chmod(folder, 0o755) }
        try? fm.removeItem(atPath: root)
    }

    @discardableResult
    private func file(_ relative: String, bytes: Int = 5_000) throws -> String {
        let path = root + "/" + relative
        try fm.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try Data(repeating: 1, count: bytes).write(to: URL(fileURLWithPath: path))
        return path
    }

    private var policy: SafetyPolicy { SafetyPolicy(homePath: root + "/home") }

    private func finder(_ packages: [(info: PackageInfo, files: [String])]) -> ReceiptFinder {
        ReceiptFinder(database: StaticPackageDatabase(packages), policy: policy)
    }

    private func package(_ id: String, _ files: [String], location: String = "") -> (info: PackageInfo, files: [String]) {
        (PackageInfo(id: id, version: "1.0", volume: root, location: location), files)
    }

    func testThePackageBaseJoinsVolumeAndLocation() {
        XCTAssertEqual(PackageInfo(id: "a", volume: "/", location: "").base, "/")
        XCTAssertEqual(PackageInfo(id: "a", volume: "/", location: "Applications").base, "/Applications")
        XCTAssertEqual(PackageInfo(id: "a", volume: "/Volumes/Disk", location: "Applications").base, "/Volumes/Disk/Applications")
        XCTAssertEqual(PackageInfo(id: "a", volume: "/", location: "/Library/X/").base, "/Library/X")
    }

    func testFindsPackagesWhoseAppIsGoneAndWhatTheyLeft() throws {
        let engine = try file("Library/Application Support/Tool/engine.bin")
        let binary = try file("usr/local/bin/tool")
        try file("Library/Application Support/Kept/data.bin")
        try file("Applications/Kept.app/Contents/Info.plist")
        let gone = package("com.maker.tool", [
            "Applications", "Applications/Tool.app", "Applications/Tool.app/Contents", "Library",
            "Library/Application Support", "Library/Application Support/Tool", "Library/Application Support/Tool/engine.bin",
            "usr", "usr/local", "usr/local/bin", "usr/local/bin/tool", "usr/local/bin/missing",
        ])
        let kept = package("com.maker.kept", ["Applications/Kept.app", "Library/Application Support/Kept",
                                              "Library/Application Support/Kept/data.bin"])
        let noApp = package("com.maker.driver", ["Library/Application Support/Tool"])
        let apple = package("com.apple.pkg.Something", ["Applications/Gone.app", "usr/local/bin/tool"])

        let findings = finder([gone, kept, noApp, apple]).find()
        XCTAssertEqual(findings.map(\.package.id), ["com.maker.tool"])
        let tool = try XCTUnwrap(findings.first)
        XCTAssertEqual(tool.appName, "Tool")
        XCTAssertEqual(tool.appPaths, [root + "/Applications/Tool.app"])
        // Application Support/Tool is also listed by another package, so only the binary is its own.
        XCTAssertEqual(tool.leftovers.map(\.path), [binary])
        XCTAssertTrue(fm.fileExists(atPath: engine))
        XCTAssertEqual(tool.removedApp, RemovedApp(bundleID: "com.maker.tool", name: "Tool"))
    }

    func testSharedFoldersAreNeverOffered() throws {
        try file("Library/LaunchAgents/com.maker.tool.plist")
        try file("Library/Application Support/Tool/a.bin")
        let findings = finder([package("com.maker.tool", [
            "Applications/Tool.app", "Library", "Library/LaunchAgents", "Library/LaunchAgents/com.maker.tool.plist",
            "Library/Application Support", "Library/Application Support/Tool", "Library/Application Support/Tool/a.bin",
        ])]).find()
        let paths = Set(findings.flatMap(\.leftovers).map(\.path))
        XCTAssertEqual(paths, [root + "/Library/LaunchAgents/com.maker.tool.plist", root + "/Library/Application Support/Tool"])
        XCTAssertTrue(ReceiptFinder.isShared("Library/Application Support"))
        XCTAssertTrue(ReceiptFinder.isShared("./usr/local/bin/"))
        XCTAssertTrue(ReceiptFinder.isShared("Library"))
        XCTAssertFalse(ReceiptFinder.isShared("Library/Application Support/Tool"))
    }

    func testAnAppThatWasMovedIsNotGone() throws {
        try file("usr/local/bin/tool")
        let findings = finder([package("com.maker.tool", ["Applications/Tool.app", "usr/local/bin/tool"])])
            .find(installedNames: ["Tool"])
        XCTAssertTrue(findings.isEmpty)
    }

    func testFilesThatNeedAnAdministratorAreOnlyListed() throws {
        let locked = root + "/Library/Locked"
        let inside = try file("Library/Locked/Tool/data.bin")
        chmod(locked, 0o555)
        lockedFolders.append(locked)
        let findings = finder([package("com.maker.tool", ["Applications/Tool.app", "Library/Locked/Tool",
                                                          "Library/Locked/Tool/data.bin"])]).find()
        let tool = try XCTUnwrap(findings.first)
        XCTAssertTrue(tool.leftovers.isEmpty)
        XCTAssertEqual(tool.adminOnly, [(inside as NSString).deletingLastPathComponent])
    }

    func testTheSafetyRulesCanRefuseALeftover() throws {
        try file("usr/local/bin/tool")
        let confined = ReceiptFinder(database: StaticPackageDatabase([package("com.maker.tool", ["Applications/Tool.app",
                                                                                                "usr/local/bin/tool"])]),
                                     policy: SafetyPolicy(homePath: root + "/home", confinedTo: root + "/elsewhere"))
        let tool = try XCTUnwrap(confined.find().first)
        XCTAssertTrue(tool.leftovers.isEmpty, "a blocked item was offered")
        XCTAssertEqual(tool.adminOnly, [root + "/usr/local/bin/tool"])
    }

    func testMeasuresLargestFirst() throws {
        try file("opt/tool/big.bin", bytes: 400_000)
        try file("opt/tool2/small.bin", bytes: 1_000)
        let measured = ReceiptFinder.measure(finder([
            package("com.maker.a", ["Applications/A.app", "opt/tool2", "opt/tool2/small.bin"]),
            package("com.maker.b", ["Applications/B.app", "opt/tool", "opt/tool/big.bin"]),
        ]).find())
        XCTAssertEqual(measured.map(\.package.id), ["com.maker.b", "com.maker.a"])
        XCTAssertGreaterThan(measured[0].bytes, 300_000)
    }

    // MARK: Languages

    private func app(_ name: String, id: String = "com.maker.app", languages: [String], development: String? = "en") throws -> InstalledApp {
        let path = root + "/Applications/\(name).app"
        var info: [String: Any] = ["CFBundleIdentifier": id, "CFBundleName": name]
        if let development { info["CFBundleDevelopmentRegion"] = development }
        try fm.createDirectory(atPath: path + "/Contents/Resources", withIntermediateDirectories: true)
        let data = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        try data.write(to: URL(fileURLWithPath: path + "/Contents/Info.plist"))
        for language in languages { try file("Applications/\(name).app/Contents/Resources/\(language).lproj/Localizable.strings") }
        return try XCTUnwrap(AppUninstaller.readApp(at: path))
    }

    func testFindsLanguagesYouDoNotUse() throws {
        let app = try app("Poly", languages: ["en", "Base", "de", "fr_CA", "French", "vi", "zh-Hans", "zh_TW", "ja"],
                          development: "ja")
        let finder = LanguageFinder(preferredLanguages: ["vi-VN", "fr-FR"], checker: FixedSignatureChecker(.unsigned), policy: policy)
        let finding = try XCTUnwrap(finder.find(app: app))
        let names = Set(finding.folders.map { ($0.path as NSString).lastPathComponent })
        XCTAssertEqual(names, ["de.lproj", "zh-Hans.lproj", "zh_TW.lproj"])
        XCTAssertTrue(finding.canRemove)
    }

    func testSignedAppsAreOnlyShown() throws {
        let app = try app("Signed", languages: ["en", "de"])
        let signed = LanguageFinder(preferredLanguages: ["en"], checker: FixedSignatureChecker(.signed), policy: policy)
        let finding = try XCTUnwrap(signed.find(app: app))
        XCTAssertFalse(finding.canRemove, "removing files would break the signature")
        let invalid = LanguageFinder(preferredLanguages: ["en"], checker: FixedSignatureChecker(.invalid), policy: policy)
        XCTAssertEqual(invalid.find(app: app)?.canRemove, false)
    }

    func testAppsOfAppleAreLeftAlone() throws {
        let byApple = try app("Pages", id: "com.apple.iWork.Pages", languages: ["en", "de"])
        let finder = LanguageFinder(preferredLanguages: ["en"], checker: FixedSignatureChecker(.unsigned), policy: policy)
        XCTAssertNil(finder.find(app: byApple))
        let appleSigned = try app("Other", languages: ["en", "de"])
        XCTAssertNil(LanguageFinder(preferredLanguages: ["en"], checker: FixedSignatureChecker(.apple), policy: policy).find(app: appleSigned))
        let system = InstalledApp(path: "/System/Applications/Chess.app", name: "Chess", bundleID: "org.example.chess",
                                  version: nil, iconPath: nil)
        XCTAssertNil(finder.find(app: system))
    }

    func testNoFindingWhenEveryLanguageIsUsed() throws {
        let app = try app("Mono", languages: ["en", "Base"])
        XCTAssertNil(LanguageFinder(preferredLanguages: ["en-GB"], checker: FixedSignatureChecker(.unsigned), policy: policy).find(app: app))
    }

    func testLanguageCodes() {
        XCTAssertEqual(LanguageFinder.language("zh-Hans-CN"), "zh")
        XCTAssertEqual(LanguageFinder.language("pt_BR"), "pt")
        XCTAssertEqual(LanguageFinder.language("English"), "en")
        XCTAssertEqual(LanguageFinder.language("no"), "nb")
    }
}
