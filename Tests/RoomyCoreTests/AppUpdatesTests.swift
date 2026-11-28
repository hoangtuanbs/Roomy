import Foundation
import XCTest
@testable import RoomyCore

/// Update feeds are read from strings and a fixed fetcher; nothing goes to the network.
final class AppUpdatesTests: XCTestCase {
    private let feed = """
    <?xml version="1.0" encoding="utf-8"?>
    <rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
      <channel>
        <item>
          <title>3.0 beta</title>
          <sparkle:channel>beta</sparkle:channel>
          <enclosure url="https://example.com/App-3.0b1.zip" sparkle:version="300" sparkle:shortVersionString="3.0b1"/>
        </item>
        <item>
          <title>2.5 needs a newer Mac</title>
          <sparkle:minimumSystemVersion>99.0</sparkle:minimumSystemVersion>
          <enclosure url="https://example.com/App-2.5.zip" sparkle:version="250" sparkle:shortVersionString="2.5"/>
        </item>
        <item>
          <title>2.1</title>
          <sparkle:version>210</sparkle:version>
          <sparkle:shortVersionString>2.1</sparkle:shortVersionString>
          <sparkle:releaseNotesLink>https://example.com/2.1.html</sparkle:releaseNotesLink>
          <enclosure url="https://example.com/App-2.1.zip"/>
          <sparkle:deltas>
            <enclosure url="https://example.com/delta.zip" sparkle:version="999" sparkle:deltaFrom="200"/>
          </sparkle:deltas>
        </item>
        <item>
          <title>2.0</title>
          <enclosure url="https://example.com/App-2.0.zip" sparkle:version="200" sparkle:shortVersionString="2.0"/>
        </item>
      </channel>
    </rss>
    """

    private func app(version: String = "2.0", build: String? = "200", feed: String? = "https://example.com/appcast.xml",
                     store: Bool = false) -> InstalledApp {
        InstalledApp(path: "/Applications/App.app", name: "App", bundleID: "com.example.app", version: version, iconPath: nil,
                     buildVersion: build, feedURL: feed, isFromAppStore: store)
    }

    func testParsesReleasesAndSkipsBetasAndDeltas() {
        let items = Appcast.parse(Data(feed.utf8))
        XCTAssertEqual(items.map(\.version), ["250", "210", "200"])
        XCTAssertEqual(items[1].shortVersion, "2.1")
        XCTAssertEqual(items[1].downloadURL?.absoluteString, "https://example.com/App-2.1.zip", "a delta is not the download")
        XCTAssertEqual(items[1].releaseNotesURL?.absoluteString, "https://example.com/2.1.html")
        XCTAssertEqual(items[0].minimumSystemVersion, "99.0")
    }

    func testTheNewestReleaseThatRunsHere() {
        let items = Appcast.parse(Data(feed.utf8))
        XCTAssertEqual(Appcast.newest(items, systemVersion: "14.5.0")?.version, "210")
        XCTAssertEqual(Appcast.newest(items, systemVersion: "99.1")?.version, "250")
        XCTAssertNil(Appcast.newest([], systemVersion: "14.0"))
    }

    func testComparesVersionsLikeSparkle() {
        XCTAssertEqual(VersionCompare.compare("1.2", "1.10"), .orderedAscending)
        XCTAssertEqual(VersionCompare.compare("2.0", "2.0.0"), .orderedSame)
        XCTAssertEqual(VersionCompare.compare("2.0b1", "2.0"), .orderedAscending)
        XCTAssertEqual(VersionCompare.compare("2.0.1", "2.0b1"), .orderedDescending)
        XCTAssertEqual(VersionCompare.compare("120", "100"), .orderedDescending)
        XCTAssertEqual(VersionCompare.compare("1.0 (45)", "1.0 (46)"), .orderedAscending)
        XCTAssertEqual(VersionCompare.compare("2.0a", "2.0b"), .orderedAscending)
    }

    func testComparesTheBuildVersionFirst() {
        let newer = AppcastItem(version: "210", shortVersion: "2.1", downloadURL: nil)
        XCTAssertEqual(UpdateChecker.status(of: app(), newest: newer), .available(newer))
        XCTAssertEqual(UpdateChecker.status(of: app(version: "2.1", build: "210"), newest: newer), .upToDate)
        XCTAssertEqual(UpdateChecker.status(of: app(version: "2.2", build: "220"), newest: newer), .upToDate)
        // Without a build number the short versions are compared.
        XCTAssertEqual(UpdateChecker.status(of: app(version: "2.0", build: nil), newest: newer), .available(newer))
    }

    func testChecksThroughTheFetcher() async {
        let checker = UpdateChecker(fetcher: FixedAppcastFetcher(["https://example.com/appcast.xml": Data(feed.utf8)]),
                                    systemVersion: "14.5")
        guard case .available(let item) = await checker.check(app()) else { return XCTFail("no update found") }
        XCTAssertEqual(item.displayVersion, "2.1")
        XCTAssertEqual(await checker.check(app(version: "2.1", build: "210")), .upToDate)
        XCTAssertEqual(await checker.check(app(store: true)), .appStore)
        guard case .failed = await checker.check(app(feed: "https://example.com/missing.xml")) else { return XCTFail("a missing feed passed") }
        let empty = UpdateChecker(fetcher: FixedAppcastFetcher(["https://example.com/appcast.xml": Data("<rss/>".utf8)]))
        guard case .failed = await empty.check(app()) else { return XCTFail("an empty feed passed") }
    }

    func testOnlyAppsWithAFeedOrFromTheAppStoreAreChecked() {
        let apple = InstalledApp(path: "/Applications/Pages.app", name: "Pages", bundleID: "com.apple.iWork.Pages", version: "1",
                                 iconPath: nil, isFromAppStore: true)
        let plain = app(feed: nil)
        let apps = UpdateChecker.checkable([app(), app(feed: nil, store: true), plain, apple])
        XCTAssertEqual(apps.count, 2)
    }

    func testReadsTheFeedAndAppStoreReceiptOfAnApp() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("RoomyUpdates-\(UUID().uuidString)").path
        defer { try? fm.removeItem(atPath: root) }
        let path = root + "/Feedy.app"
        try fm.createDirectory(atPath: path + "/Contents/_MASReceipt", withIntermediateDirectories: true)
        let info: [String: Any] = ["CFBundleIdentifier": "com.example.feedy", "CFBundleShortVersionString": "1.0",
                                   "CFBundleVersion": "100", "SUFeedURL": "https://example.com/feedy.xml"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: URL(fileURLWithPath: path + "/Contents/Info.plist"))
        var app = try XCTUnwrap(AppUninstaller.readApp(at: path))
        XCTAssertEqual(app.feedURL, "https://example.com/feedy.xml")
        XCTAssertEqual(app.buildVersion, "100")
        XCTAssertFalse(app.isFromAppStore)
        try Data(count: 10).write(to: URL(fileURLWithPath: path + "/Contents/_MASReceipt/receipt"))
        app = try XCTUnwrap(AppUninstaller.readApp(at: path))
        XCTAssertTrue(app.isFromAppStore)
    }
}
