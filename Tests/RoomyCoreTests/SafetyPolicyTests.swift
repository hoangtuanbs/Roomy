import XCTest
@testable import RoomyCore

/// SafetyPolicy decides what may go to the Trash. Most cases are plain paths that never touch the disk;
/// the ones with links use a temporary folder that stands in for the home folder.
final class SafetyPolicyTests: XCTestCase {
    private enum Outcome: String { case allowed, caution, blocked }

    private let fakeHome = "/Users/tester"
    private let fm = FileManager.default
    private var temp = ""

    override func setUpWithError() throws {
        let base = fm.temporaryDirectory.appendingPathComponent("RoomySafety-\(UUID().uuidString)")
        try fm.createDirectory(at: base, withIntermediateDirectories: true)
        temp = DiskScanner.standardize(base.path)
    }

    override func tearDownWithError() throws {
        try? fm.removeItem(atPath: temp)
    }

    private func outcome(_ verdict: SafetyVerdict) -> Outcome {
        switch verdict {
        case .allowed: return .allowed
        case .caution: return .caution
        case .blocked: return .blocked
        }
    }

    private func check(_ policy: SafetyPolicy, _ cases: [(String, Outcome)], file: StaticString = #filePath, line: UInt = #line) {
        for (path, expected) in cases {
            let verdict = policy.verdict(for: path)
            XCTAssertEqual(outcome(verdict), expected, path, file: file, line: line)
            if expected != .allowed {
                XCTAssertFalse(verdict.message?.isEmpty ?? true, "\(path) needs a reason", file: file, line: line)
            }
        }
    }

    // MARK: Verdict basics

    func testVerdictHelpers() {
        XCTAssertFalse(SafetyVerdict.allowed.isBlocked)
        XCTAssertNil(SafetyVerdict.allowed.message)
        XCTAssertFalse(SafetyVerdict.caution("c").isBlocked)
        XCTAssertEqual(SafetyVerdict.caution("c").message, "c")
        XCTAssertTrue(SafetyVerdict.blocked("b").isBlocked)
        XCTAssertEqual(SafetyVerdict.blocked("b").message, "b")
    }

    func testHomePathIsStandardized() {
        XCTAssertEqual(SafetyPolicy(homePath: "/Users/tester/").homePath, "/Users/tester")
        XCTAssertEqual(SafetyPolicy(homePath: "/Users/./tester//").homePath, "/Users/tester")
        XCTAssertEqual(SafetyPolicy().homePath, DiskScanner.standardize(NSHomeDirectory()))
    }

    // MARK: System locations

    func testSystemLocationsAreBlocked() {
        check(SafetyPolicy(homePath: fakeHome), [
            ("/", .blocked),
            ("/System", .blocked),
            ("/System/Library/CoreServices/Finder.app", .blocked),
            ("/System/Volumes/Data", .blocked),
            ("/bin", .blocked),
            ("/bin/ls", .blocked),
            ("/sbin/mount", .blocked),
            ("/usr", .blocked),
            ("/usr/bin/zip", .blocked),
            ("/usr/lib/libSystem.B.dylib", .blocked),
            ("/etc/hosts", .blocked),
            ("/dev/disk0", .blocked),
            ("/private/etc/hosts", .blocked),
            ("/private/var/db/receipts", .blocked),
            ("/private/var/vm/sleepimage", .blocked),
            ("/Library/Apple", .blocked),
            ("/Library/Apple/System/Library/Receipts", .blocked),
        ])
    }

    func testUsrLocalIsNotASystemLocation() {
        check(SafetyPolicy(homePath: fakeHome), [
            ("/usr/local", .allowed),
            ("/usr/local/bin/tool", .allowed),
            ("/usr/localextra", .blocked),
        ])
    }

    func testNamesThatOnlyStartLikeSystemFoldersAreNotSystemFolders() {
        check(SafetyPolicy(homePath: fakeHome), [
            ("/Systemic/file", .allowed),
            ("/binary/file", .allowed),
            ("/etcetera", .allowed),
            ("/Library/AppleMusicStuff", .caution),
        ])
    }

    func testSharedLibraryAndApplicationsNeedCaution() {
        check(SafetyPolicy(homePath: fakeHome), [
            ("/Library/Caches/com.example", .caution),
            ("/Library/Application Support/Example", .caution),
            ("/Applications/Example.app", .caution),
            ("/Applications/Utilities/Example.app", .caution),
        ])
    }

    // MARK: Disks

    func testDiskRootsAreBlocked() {
        check(SafetyPolicy(homePath: fakeHome), [
            ("/Volumes/External", .blocked),
            ("/Volumes/External/", .blocked),
            ("/Volumes/My Passport", .blocked),
            ("/Volumes/External/Movies", .allowed),
            ("/Volumes/External/Movies/big.mov", .allowed),
        ])
    }

    // MARK: Home folder

    func testHomeAndWhatHoldsItAreBlocked() {
        check(SafetyPolicy(homePath: fakeHome), [
            (fakeHome, .blocked),
            (fakeHome + "/", .blocked),
            (fakeHome + "//", .blocked),
            (fakeHome + "/.", .blocked),
            ("/Users", .blocked),
            ("/Users/", .blocked),
            ("/Users/test", .allowed),
        ])
    }

    func testStandardHomeFoldersAreBlockedButTheirContentsAreNot() {
        let policy = SafetyPolicy(homePath: fakeHome)
        for folder in ["Desktop", "Documents", "Downloads", "Library", "Pictures", "Movies", "Music", "Applications", "Public"] {
            check(policy, [
                (fakeHome + "/" + folder, .blocked),
                (fakeHome + "/" + folder + "/", .blocked),
            ])
        }
        check(policy, [
            (fakeHome + "/Desktop/screenshot.png", .allowed),
            (fakeHome + "/Documents/report.pdf", .allowed),
            (fakeHome + "/Downloads/installer.dmg", .allowed),
            (fakeHome + "/Movies/clip.mov", .allowed),
            (fakeHome + "/Music/old", .allowed),
            (fakeHome + "/Applications/Tool.app", .allowed),
            (fakeHome + "/Projects", .allowed),
            (fakeHome + "/.Trash/old.zip", .allowed),
            (fakeHome + "/Documentsold", .allowed),
        ])
    }

    func testTildeMeansTheRealHomeFolder() {
        check(SafetyPolicy(), [
            ("~", .blocked),
            ("~/", .blocked),
            ("~/Documents", .blocked),
            ("~/Library/Keychains", .blocked),
        ])
    }

    // MARK: ~/Library

    func testUserLibraryNeedsCautionAndItsKeyStoresAreBlocked() {
        let lib = fakeHome + "/Library"
        check(SafetyPolicy(homePath: fakeHome), [
            (lib + "/Caches", .caution),
            (lib + "/Caches/com.example.app", .caution),
            (lib + "/Preferences/com.example.plist", .caution),
            (lib + "/Application Support/Example", .caution),
            (lib + "/Keychains", .blocked),
            (lib + "/Keychains/login.keychain-db", .blocked),
            (lib + "/Mobile Documents", .blocked),
            (lib + "/Mobile Documents/com~apple~CloudDocs/notes.txt", .blocked),
            (lib + "/CloudStorage", .blocked),
            (lib + "/CloudStorage/Dropbox/file.pdf", .blocked),
            (lib + "/Mail", .blocked),
            (lib + "/Mail/V10/MailData/Envelope Index", .blocked),
            (lib + "/Mail Downloads", .caution),
            (lib + "/KeychainsBackup", .caution),
            (fakeHome + "/Library2", .allowed),
        ])
    }

    func testDeviceBackupsGoOnlyWhole() {
        let sync = fakeHome + "/Library/Application Support/MobileSync"
        check(SafetyPolicy(homePath: fakeHome), [
            (sync, .blocked),
            (sync + "/", .blocked),
            (sync + "/Backup", .blocked),
            (sync + "/Backup/", .blocked),
            (sync + "/Backup/00008030-0012345", .caution),
            (sync + "/Backup/00008030-0012345/", .caution),
            (sync + "/Backup/00008030-0012345/Manifest.db", .blocked),
            (sync + "/Backup/00008030-0012345/ab/abcdef", .blocked),
            (sync + "/Backup/00008030-0012345/../00008030-0099999", .caution),
            (sync + "/Other", .blocked),
        ])
    }

    // MARK: Photos

    func testPhotosLibrariesGoOnlyWhole() {
        let pictures = fakeHome + "/Pictures"
        check(SafetyPolicy(homePath: fakeHome), [
            (pictures + "/Photos Library.photoslibrary", .caution),
            (pictures + "/Photos Library.photoslibrary/", .caution),
            (pictures + "/Photos Library.photoslibrary/originals", .blocked),
            (pictures + "/Photos Library.photoslibrary/originals/A/IMG_1.heic", .blocked),
            ("/Volumes/External/Old.photoslibrary", .caution),
            ("/Volumes/External/Old.photoslibrary/database/Photos.sqlite", .blocked),
            (pictures + "/photoslibrary notes.txt", .allowed),
        ])
    }

    // MARK: Git

    func testGitHistoryNeedsCaution() {
        check(SafetyPolicy(homePath: fakeHome), [
            (fakeHome + "/Projects/app/.git", .caution),
            (fakeHome + "/Projects/app/.git/", .caution),
            (fakeHome + "/Projects/app/.github", .allowed),
            (fakeHome + "/Projects/app", .allowed),
        ])
    }

    // MARK: Path tricks

    func testDotDotCannotClimbIntoProtectedPlaces() {
        check(SafetyPolicy(homePath: fakeHome), [
            (fakeHome + "/Downloads/../Documents", .blocked),
            (fakeHome + "/Downloads/a/b/../../../Library/Keychains", .blocked),
            (fakeHome + "/Downloads/..", .blocked),
            (fakeHome + "/Projects/../../tester", .blocked),
            ("/Volumes/External/../../System", .blocked),
            (fakeHome + "/Downloads/./installer.dmg", .allowed),
        ])
    }

    func testTheItemsOwnLinkIsJudgedNotItsTarget() throws {
        // The Trash moves a link itself, never what it points to, so a link to the home folder may go.
        let home = temp + "/home"
        try fm.createDirectory(atPath: home + "/Documents", withIntermediateDirectories: true)
        try fm.createSymbolicLink(atPath: home + "/Desktop-link", withDestinationPath: home + "/Documents")
        try fm.createSymbolicLink(atPath: home + "/system-link", withDestinationPath: "/System")
        check(SafetyPolicy(homePath: home), [
            (home + "/Desktop-link", .allowed),
            (home + "/system-link", .allowed),
        ])
    }

    // MARK: Selection

    func testSelectionDropsDuplicatesAndItemsInsideOtherItems() {
        XCTAssertEqual(Selection.normalized([]), [])
        XCTAssertEqual(Selection.normalized(["/a/b", "/a/b/", "/a/./b"]), ["/a/b"])
        XCTAssertEqual(Selection.normalized(["/a/b/c", "/a/b", "/a/b/c/d"]), ["/a/b"])
        XCTAssertEqual(Selection.normalized(["/a/bc", "/a/b"]), ["/a/b", "/a/bc"])
        XCTAssertEqual(Selection.normalized(["/z", "/a"]), ["/a", "/z"])
    }
}
