import XCTest
@testable import RoomyCore

final class ItemExplainerTests: XCTestCase {
    private let home = "/Users/anna"
    private var explainer: ItemExplainer { ItemExplainer(policy: SafetyPolicy(homePath: home)) }

    func testTheListIsBigAndEveryPatternIsWellFormed() {
        let entries = ItemExplainer.builtIn
        XCTAssertGreaterThanOrEqual(entries.count, 80)
        XCTAssertEqual(Set(entries.map(\.pattern)).count, entries.count, "a pattern is listed twice")
        for entry in entries {
            XCTAssertTrue(entry.pattern.hasPrefix("~/") || entry.pattern.hasPrefix("/") || entry.pattern.hasPrefix("**/"), entry.pattern)
            XCTAssertFalse(entry.title.isEmpty || entry.text.isEmpty, entry.pattern)
        }
        for safety in RemovalSafety.allCases {
            XCTAssertTrue(entries.contains { $0.safety == safety }, "no \(safety) entries")
        }
    }

    func testCommonFoldersAreExplained() throws {
        let caches = try XCTUnwrap(explainer.explain(home + "/Library/Caches"))
        XCTAssertEqual(caches.title, "App caches")
        XCTAssertEqual(caches.safety, .rebuilds)
        XCTAssertEqual(caches.source, .builtIn)
        XCTAssertNil(caches.insideOf)

        XCTAssertEqual(explainer.explain(home + "/Library/Developer/Xcode/DerivedData")?.title, "Xcode build data")
        XCTAssertEqual(explainer.explain(home + "/.npm")?.safety, .safe)
        XCTAssertEqual(explainer.explain(home + "/Library/Application Support/MobileSync/Backup")?.safety, .keep)
        XCTAssertEqual(explainer.explain("/System")?.title, "macOS")
    }

    func testTheMostSpecificPatternWins() {
        XCTAssertEqual(explainer.explain(home + "/Library/Caches/com.apple.Safari")?.title, "Safari's cache")
        XCTAssertEqual(explainer.explain(home + "/Library/Caches/com.example.tool")?.title, "An app's cache")
        XCTAssertEqual(explainer.explain(home + "/Library/Application Support/Slack/Cache")?.title, "Slack's cache")
        XCTAssertEqual(explainer.explain(home + "/Library/Application Support/Slack")?.safety, .keep)
        XCTAssertEqual(explainer.explain(home + "/Downloads/Tool.dmg")?.safety, .safe)
        XCTAssertEqual(explainer.explain(home + "/Documents/Encrypted.dmg")?.safety, .keep, "a disk image outside Downloads may be your own")
    }

    func testNamesAreKnownAnywhereAndMatchingIgnoresCase() {
        XCTAssertEqual(explainer.explain(home + "/Projects/web/node_modules")?.safety, .rebuilds)
        XCTAssertEqual(explainer.explain(home + "/Projects/web/.git")?.safety, .keep)
        XCTAssertEqual(explainer.explain(home + "/library/caches")?.title, "App caches")
        XCTAssertEqual(explainer.explain("/Applications/Editor.app")?.title, "App")
    }

    func testItemsInsideAKnownFolderSayWhichFolder() throws {
        let inside = try XCTUnwrap(explainer.explain(home + "/Projects/web/node_modules/lodash/index.js"))
        XCTAssertEqual(inside.title, "node_modules")
        XCTAssertEqual(inside.insideOf, home + "/Projects/web/node_modules")
        XCTAssertNil(explainer.explain(home + "/Projects/web/index.js"), "nothing above the home folder explains it")
        XCTAssertNil(explainer.explain(home + "/notes.txt"))
    }

    func testTheSafetyRulesAlwaysWin() throws {
        // A list that wrongly calls the keychains safe, and a guess that does: both are kept.
        let wrong = ItemExplainer(policy: SafetyPolicy(homePath: home),
                                  entries: [.init(pattern: "~/Library/Keychains", title: "K", text: "T", safety: .safe)])
        let keychains = try XCTUnwrap(wrong.explain(home + "/Library/Keychains"))
        XCTAssertEqual(keychains.safety, .keep)
        XCTAssertNotNil(keychains.blockedReason)

        let guess = ItemExplanation(title: "System", text: "Fine to remove.", safety: .safe, source: .guess)
        let checked = explainer.enforce(guess, for: "/System/Library/Fonts")
        XCTAssertEqual(checked.safety, .keep)
        XCTAssertEqual(checked.source, .guess)
        XCTAssertNotNil(checked.blockedReason)

        let allowed = explainer.enforce(guess, for: home + "/Projects/web/tmp")
        XCTAssertEqual(allowed.safety, .safe)
        XCTAssertNil(allowed.blockedReason)
    }

    func testPathsAreShownFromTheHomeFolder() {
        XCTAssertEqual(explainer.display(home + "/Library/Caches"), "~/Library/Caches")
        XCTAssertEqual(explainer.display(home), "~")
        XCTAssertEqual(explainer.display("/Library"), "/Library")
    }
}
