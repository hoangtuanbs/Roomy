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

    // MARK: Letter case (APFS ignores it by default)

    func testOtherLetterCaseStillMeansTheSameProtectedPlace() {
        check(SafetyPolicy(homePath: fakeHome), [
            ("/system", .blocked),
            ("/SYSTEM/Library", .blocked),
            ("/Usr/bin", .blocked),
            ("/USR/LOCAL/bin/tool", .allowed),
            ("/volumes/External", .blocked),
            ("/VOLUMES/External/", .blocked),
            ("/users/tester", .blocked),
            ("/Users/TESTER", .blocked),
            ("/users", .blocked),
            (fakeHome + "/documents", .blocked),
            (fakeHome + "/DESKTOP/", .blocked),
            (fakeHome + "/library", .blocked),
            (fakeHome + "/library/keychains/login.keychain-db", .blocked),
            (fakeHome + "/Library/mail", .blocked),
            (fakeHome + "/library/Mobile documents/x", .blocked),
            (fakeHome + "/Library/cloudstorage/Box", .blocked),
            (fakeHome + "/library/application support/mobilesync/backup", .blocked),
            (fakeHome + "/Library/Application Support/MobileSync/BACKUP/abc", .caution),
            (fakeHome + "/Library/Application Support/MobileSync/Backup/abc/MANIFEST.db", .blocked),
            (fakeHome + "/Pictures/Photos Library.PhotosLibrary/originals", .blocked),
            (fakeHome + "/library/caches", .caution),
            (fakeHome + "/Projects/app/.GIT", .caution),
            ("/library/caches/x", .caution),
        ])
    }

    // MARK: Folders that hold protected places

    func testFoldersThatHoldSystemFilesAreBlocked() {
        check(SafetyPolicy(homePath: fakeHome), [
            ("/Library", .blocked),
            ("/Library/", .blocked),
            ("/private", .blocked),
            ("/private/var", .blocked),
            ("/private/var/folders/xy/old", .allowed),
            ("/Applications", .blocked),
            ("/Volumes", .blocked),
            ("/Volumes/", .blocked),
            ("/tmp", .blocked),
            ("/tmp/old-download.dmg", .allowed),
            ("/var", .blocked),
        ])
    }

    // MARK: Links on the way

    func testLinksOnTheWayIntoTheHomeFolderAreFollowed() throws {
        let home = temp + "/home"
        let elsewhere = temp + "/elsewhere"
        for folder in ["Documents", "Library/Keychains", "Library/Caches/app", "Projects/app", "Pictures/P.photoslibrary/originals"] {
            try fm.createDirectory(atPath: home + "/" + folder, withIntermediateDirectories: true)
        }
        try fm.createDirectory(atPath: elsewhere, withIntermediateDirectories: true)
        try fm.createSymbolicLink(atPath: elsewhere + "/home-link", withDestinationPath: home)
        try fm.createSymbolicLink(atPath: elsewhere + "/projects-link", withDestinationPath: home + "/Projects")
        try fm.createSymbolicLink(atPath: elsewhere + "/photos-link", withDestinationPath: home + "/Pictures/P.photoslibrary")

        check(SafetyPolicy(homePath: home), [
            (elsewhere + "/home-link/Documents", .blocked),
            (elsewhere + "/home-link/Documents/", .blocked),
            (elsewhere + "/home-link/Library/Keychains", .blocked),
            (elsewhere + "/home-link/Library/Caches/app", .caution),
            (elsewhere + "/home-link/Projects/app", .allowed),
            (elsewhere + "/projects-link/../Documents", .blocked),
            (elsewhere + "/projects-link/..", .blocked),
            (elsewhere + "/photos-link/originals", .blocked),
            (elsewhere + "/home-link", .allowed),
        ])
    }

    func testAHomeFolderReachedThroughALinkIsStillProtected() throws {
        let real = temp + "/real-home"
        try fm.createDirectory(atPath: real + "/Documents", withIntermediateDirectories: true)
        try fm.createSymbolicLink(atPath: temp + "/home-link", withDestinationPath: real)
        let policy = SafetyPolicy(homePath: temp + "/home-link")
        check(policy, [
            (real, .blocked),
            (real + "/Documents", .blocked),
            (real + "/Documents/file.txt", .allowed),
            (temp + "/home-link/Documents", .blocked),
        ])
    }

    func testLinksOnTheWayIntoSystemFoldersAreFollowed() throws {
        try fm.createSymbolicLink(atPath: temp + "/usr-link", withDestinationPath: "/usr")
        try fm.createSymbolicLink(atPath: temp + "/root-link", withDestinationPath: "/")
        check(SafetyPolicy(homePath: fakeHome), [
            (temp + "/usr-link/bin", .blocked),
            (temp + "/usr-link/lib/", .blocked),
            (temp + "/root-link/System", .blocked),
            (temp + "/root-link/usr/bin/zip", .blocked),
            (temp + "/root-link/Library", .blocked),
            (temp + "/usr-link", .allowed),
        ])
    }

    #if os(macOS)
    func testSystemFoldersBehindMacOSLinksAreBlocked() {
        // /etc, /var and /tmp are links into /private on macOS.
        check(SafetyPolicy(homePath: fakeHome), [
            ("/var/db", .blocked),
            ("/var/db/receipts", .blocked),
            ("/var/vm", .blocked),
            ("/var", .blocked),
            ("/etc", .blocked),
        ])
    }
    #endif

    // MARK: Selection

    func testSelectionDropsDuplicatesAndItemsInsideOtherItems() {
        XCTAssertEqual(Selection.normalized([]), [])
        XCTAssertEqual(Selection.normalized(["/a/b", "/a/b/", "/a/./b"]), ["/a/b"])
        XCTAssertEqual(Selection.normalized(["/a/b/c", "/a/b", "/a/b/c/d"]), ["/a/b"])
        XCTAssertEqual(Selection.normalized(["/a/bc", "/a/b"]), ["/a/b", "/a/bc"])
        XCTAssertEqual(Selection.normalized(["/z", "/a"]), ["/a", "/z"])
        XCTAssertEqual(Selection.normalized(["/", "/a", "/b/c"]), ["/"])
    }

    func testSelectionDropsNestedItemsEvenWhenANeighbourSortsBetween() {
        // " " and "-" sort before "/", so "/a b" lands between "/a" and "/a/b".
        XCTAssertEqual(Selection.normalized(["/a", "/a b", "/a/b"]), ["/a", "/a b"])
        XCTAssertEqual(Selection.normalized(["/x/Photos", "/x/Photos-old", "/x/Photos/2019/a.jpg"]), ["/x/Photos", "/x/Photos-old"])
    }
}
