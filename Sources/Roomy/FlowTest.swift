import AppKit
import RoomyCore
import SwiftUI

/// Developer option for CI: `RoomyDisk --flow-test <sandbox>` runs the app's main flows end to end on the real
/// models and sheets, the way the buttons do, and prints `flow: PASS <name>` or `flow: FAIL <name>: <reason>` for
/// each. It quits with status 1 when any failed. `--flow-only <name>,<name>` runs only those scenarios.
///
/// Everything it changes is inside the sandbox, which must lie inside $TMPDIR or $RUNNER_TEMP (see
/// `AppEnvironment`): the features look in `<sandbox>/home` instead of the home folder, the safety rules block
/// everything outside the sandbox, settings go to a separate defaults suite, and the scan cache and cleanup history
/// to `<sandbox>/state`. What it moves to the Trash goes there through `CleanupService`; at the end each item is
/// moved back into `<sandbox>/put-back`. The Trash is never emptied.
@MainActor
final class FlowTest {
    struct Failure: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }

    let model: AppModel
    let sandbox: String
    let home: String
    let state: String
    let only: Set<String>?
    private var trashed: [(original: String, trash: String)] = []
    private var passed = 0
    private var failed = 0

    private static var current: FlowTest?
    nonisolated static let timeLimit: TimeInterval = 280

    static func start(model: AppModel) {
        guard let sandbox = AppEnvironment.flowSandbox else { return }
        setvbuf(stdout, nil, _IOLBF, 0)
        let test = FlowTest(model: model, sandbox: sandbox)
        current = test
        watchClock()
        Task { @MainActor in await test.runAll() }
    }

    init(model: AppModel, sandbox: String) {
        self.model = model
        self.sandbox = sandbox
        home = AppEnvironment.home
        state = sandbox + "/state"
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--flow-only"), i + 1 < args.count {
            only = Set(args[i + 1].split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) })
        } else {
            only = nil
        }
    }

    // MARK: Running

    private func runAll() async {
        say("flow: sandbox \(sandbox), home \(home), language \(Bundle.main.preferredLocalizations.first ?? "?")")
        do {
            try prepare()
        } catch {
            say("flow: FAIL setup: \(error)")
            finish()
            return
        }
        try? await Task.sleep(for: .seconds(1.5))
        NSApplication.shared.activate(ignoringOtherApps: true)

        await run("scan") { try await self.scanScenario() }
        await run("stuck-cloud-drive") { try await self.stuckCloudScenario() }
        await run("scan-cache") { try await self.scanCacheScenario() }
        await run("clones") { try await self.clonesScenario() }
        await run("quick-rescan") { try await self.quickRescanScenario() }
        await run("blocked-path") { try self.blockedPathScenario() }
        await run("review-and-clean") { try await self.reviewScenario() }
        await run("compress-and-clean") { try await self.compressScenario() }
        await run("space-hunters") { try await self.spaceHuntersScenario() }
        await run("duplicates") { try await self.duplicatesScenario() }
        await run("uninstaller") { try await self.uninstallerScenario() }
        await run("removed-app-leftovers") { try await self.orphansScenario() }
        await run("login-items") { try await self.loginItemsScenario() }
        await run("installers") { try await self.installersScenario() }
        await run("unused-languages") { try await self.languagesScenario() }
        await run("finder-service") { try await self.finderServiceScenario() }
        await run("app-updates") { try await self.appUpdatesScenario() }
        await run("smart-clean") { try await self.smartCleanScenario() }
        await run("cloud-space") { try await self.cloudSpaceScenario() }
        await run("automatic-check") { try await self.automaticCheckScenario() }
        await run("quick-clean") { try await self.quickCleanScenario() }
        await run("disk-health") { try await self.diskHealthScenario() }
        await run("free-purgeable") { try await self.freePurgeableScenario() }
        await run("csv-export") { try await self.csvScenario() }
        await run("notification-route") { try await self.notificationScenario() }
        await run("settings") { try await self.settingsScenario() }
        await run("localization") { try await self.localizationScenario() }
        finish()
    }

    private func run(_ name: String, _ body: () async throws -> Void) async {
        if let only, !only.contains(name) { return }
        let start = Date()
        do {
            try await body()
            passed += 1
            say(String(format: "flow: PASS %@ (%.1f s)", name, Date().timeIntervalSince(start)))
        } catch {
            failed += 1
            say("flow: FAIL \(name): \(error)")
        }
        await closeSheets()
    }

    /// Moves what went to the Trash back into the sandbox, drops the test's settings, and quits.
    private func finish() {
        let back = sandbox + "/put-back"
        try? FileManager.default.createDirectory(atPath: back, withIntermediateDirectories: true)
        var returned = 0
        for (i, item) in trashed.enumerated() where FileManager.default.fileExists(atPath: item.trash) {
            let name = "\(i + 1)-" + (item.original as NSString).lastPathComponent
            if (try? FileManager.default.moveItem(atPath: item.trash, toPath: back + "/" + name)) != nil { returned += 1 }
        }
        stuckRelease.signal()
        say("flow: moved \(returned) of \(trashed.count) trashed items back into the sandbox")
        AppEnvironment.defaults.removePersistentDomain(forName: AppEnvironment.flowDefaultsSuite)
        say("flow: \(passed) passed, \(failed) failed")
        exit(failed > 0 ? 1 : 0)
    }

    /// Stops a run that hangs, from a thread of its own so a blocked main thread is caught too.
    private static func watchClock() {
        let thread = Thread {
            Thread.sleep(forTimeInterval: timeLimit)
            print("flow: FAIL time-limit: the flow test did not finish within \(Int(timeLimit)) s")
            fflush(stdout)
            exit(1)
        }
        thread.start()
    }

    // MARK: The sandbox

    /// Checks the files the workflow made and adds the fake home's Library: junk, a keychain, an app with leftovers,
    /// an iPhone backup and cloud folders. Only inside the sandbox.
    private func prepare() throws {
        let fm = FileManager.default
        // The workflow's files are needed by the full run; a run of a few scenarios (such as the language check) may
        // come after one that moved them.
        for file in ["Movies/holiday.mov", "Downloads/holiday copy.mov", "Projects/app/build.dmg", "Projects/app/notes.txt",
                     "Pictures/beach.jpg", "Pictures/beach small.jpg"] where only == nil && !fm.fileExists(atPath: home + "/" + file) {
            throw Failure("the workflow did not make \(home)/\(file)")
        }
        try fm.createDirectory(atPath: state, withIntermediateDirectories: true)
        let defaults = AppEnvironment.defaults
        defaults.removePersistentDomain(forName: AppEnvironment.flowDefaultsSuite)
        // No notices or permission prompts during the run.
        defaults.set(false, forKey: AutoCheckSettings.notifyKey)
        defaults.set(false, forKey: LowSpaceNotifier.enabledKey)

        try makeJunk()
        try write("Library/Developer/Xcode/Archives/2026-01-01/Flow.xcarchive/Info.plist", bytes: 150_000, fill: 3)
        try write("Library/Keychains/login.keychain-db", bytes: 12_000, fill: 4)

        let app = "Applications/Flow Sample.app/Contents"
        try writePlist(app + "/Info.plist", ["CFBundleIdentifier": Self.appID, "CFBundleName": "Flow Sample",
                                             "CFBundleExecutable": "FlowSample", "CFBundlePackageType": "APPL",
                                             "CFBundleShortVersionString": "1.0"])
        try write(app + "/MacOS/FlowSample", bytes: 60_000, fill: 5)
        try write("Library/Application Support/\(Self.appID)/data.bin", bytes: 90_000, fill: 6)
        try writePlist("Library/Preferences/\(Self.appID).plist", ["flow": true])
        try write("Library/Saved Application State/\(Self.appID).savedState/windows.plist", bytes: 3_000, fill: 7)

        // An app that was dragged to the Trash, and what it left: one item named by its identifier, one by its name,
        // and an item of some other app that is not installed.
        try writePlist(".Trash/Gone App.app/Contents/Info.plist", ["CFBundleIdentifier": Self.goneID, "CFBundleName": "Gone App",
                                                                   "CFBundlePackageType": "APPL"])
        try write("Library/Application Support/\(Self.goneID)/data.bin", bytes: 70_000, fill: 12)
        try write("Library/Application Support/Gone App/cache.bin", bytes: 30_000, fill: 13)
        try writePlist("Library/Preferences/io.github.roomy.unknowntool.plist", ["flow": true])

        // Launch agents: one of yours that can be turned off, one that claims to be Apple's, and a daemon for all users.
        try writePlist("Library/LaunchAgents/\(Self.agentLabel).plist", ["Label": Self.agentLabel,
                                                                        "ProgramArguments": ["/usr/bin/true"], "RunAtLoad": true])
        try writePlist("Library/LaunchAgents/com.apple.flowtest.plist", ["Label": "com.apple.flowtest", "Program": "/usr/bin/true"])
        try writeSandbox("system/Library/LaunchDaemons/io.github.roomy.flowdaemon.plist",
                         ["Label": "io.github.roomy.flowdaemon", "Program": "/usr/bin/true", "KeepAlive": true])

        // What the made-up installer package of the removed "Flow Tool" left (see AppEnvironment.packageDatabase).
        try writeSandboxFile("system/Library/Application Support/FlowTool/engine.bin", bytes: 50_000)
        try writeSandboxFile("system/usr/local/bin/flowtool", bytes: 25_000)
        // An app with translations for languages nobody here uses.
        let poly = "Applications/Polyglot.app/Contents"
        try writePlist(poly + "/Info.plist", ["CFBundleIdentifier": "io.github.roomy.polyglot", "CFBundleName": "Polyglot",
                                              "CFBundlePackageType": "APPL", "CFBundleDevelopmentRegion": "en"])
        for language in ["en", "Base", "de", "ja"] {
            try write(poly + "/Resources/\(language).lproj/Localizable.strings", bytes: 8_000, fill: 14)
        }

        // Apps for Updates: one with a newer version in its feed, one already up to date, one whose feed cannot be
        // reached, and one from the App Store.
        for (name, build, feed) in [("Feedy", "100", AppEnvironment.flowFeedURL), ("Fresh", "120", AppEnvironment.flowFeedURL),
                                    ("Lost", "1", "https://updates.example.invalid/lost/appcast.xml")] {
            try writePlist("Applications/\(name).app/Contents/Info.plist", [
                "CFBundleIdentifier": "io.github.roomy.\(name.lowercased())", "CFBundleName": name, "CFBundlePackageType": "APPL",
                "CFBundleShortVersionString": "1.0", "CFBundleVersion": build, "SUFeedURL": feed,
            ])
        }
        try writePlist("Applications/Storey.app/Contents/Info.plist", ["CFBundleIdentifier": "io.github.roomy.storey",
                                                                       "CFBundleName": "Storey", "CFBundlePackageType": "APPL"])
        try write("Applications/Storey.app/Contents/_MASReceipt/receipt", bytes: 2_000, fill: 16)

        let backup = "Library/Application Support/MobileSync/Backup/00008110-00FLOWTEST0001"
        try writePlist(backup + "/Info.plist", ["Device Name": "Flow iPhone", "Product Type": "iPhone15,2",
                                                "Product Version": "17.5",
                                                "Last Backup Date": Date().addingTimeInterval(-200 * 86_400)])
        try writePlist(backup + "/Manifest.plist", ["IsEncrypted": false])
        try write(backup + "/00/0011223344", bytes: 400_000, fill: 8)

        try write("Library/CloudStorage/Dropbox/Documents/report.pdf", bytes: 40_000, fill: 9)
        // A Google Drive folder whose app "is not running": reading it waits until the test ends.
        try write("Library/CloudStorage/\(Self.stuckDrive)/My Drive/plan.txt", bytes: 20_000, fill: 11)
        FolderReader.standard = .withStuckFolders([stuckDrivePath], timeout: 1.5, release: stuckRelease)
        try write("Library/Mobile Documents/com~apple~CloudDocs/Notes/note.txt", bytes: 20_000, fill: 10)
    }

    static let appID = "io.github.roomy.flowsample"
    static let goneID = "io.github.roomy.goneapp"
    static let agentLabel = "io.github.roomy.flowagent"
    static let stuckDrive = "GoogleDrive-flow@example.com"
    private var stuckDrivePath: String { home + "/Library/CloudStorage/" + Self.stuckDrive }
    /// Lets the stuck Google Drive reads finish when the test ends.
    private let stuckRelease = DispatchSemaphore(value: 0)
    private var cachePath: String { home + "/Library/Caches/com.example.flowcache" }
    private var logPath: String { home + "/Library/Logs/FlowExample" }
    private var archivePath: String { home + "/Library/Developer/Xcode/Archives/2026-01-01/Flow.xcarchive" }
    private var keychainPath: String { home + "/Library/Keychains" }

    /// App caches and logs, made again before each scenario that cleans them.
    private func makeJunk() throws {
        try write("Library/Caches/com.example.flowcache/cache.db", bytes: 300_000, fill: 1)
        try write("Library/Logs/FlowExample/flow.log", bytes: 200_000, fill: 2)
    }

    private func write(_ relative: String, bytes: Int, fill: UInt8) throws {
        let path = try sandboxed(home + "/" + relative)
        try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent,
                                                withIntermediateDirectories: true)
        try Data(repeating: fill, count: bytes).write(to: URL(fileURLWithPath: path))
    }

    private func writePlist(_ relative: String, _ values: [String: Any]) throws {
        let path = try sandboxed(home + "/" + relative)
        try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent,
                                                withIntermediateDirectories: true)
        let data = try PropertyListSerialization.data(fromPropertyList: values, format: .xml, options: 0)
        try data.write(to: URL(fileURLWithPath: path))
    }

    /// A plist at a path inside the sandbox but outside its home.
    private func writeSandbox(_ relative: String, _ values: [String: Any]) throws {
        let path = try sandboxed(sandbox + "/" + relative)
        try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent,
                                                withIntermediateDirectories: true)
        let data = try PropertyListSerialization.data(fromPropertyList: values, format: .xml, options: 0)
        try data.write(to: URL(fileURLWithPath: path))
    }

    private func writeSandboxFile(_ relative: String, bytes: Int) throws {
        let path = try sandboxed(sandbox + "/" + relative)
        try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent,
                                                withIntermediateDirectories: true)
        try Data(repeating: 15, count: bytes).write(to: URL(fileURLWithPath: path))
    }

    private func sandboxed(_ path: String) throws -> String {
        guard isInSandbox(path) else { throw Failure("\(path) is outside the sandbox") }
        return path
    }

    private func isInSandbox(_ path: String) -> Bool {
        (path as NSString).standardizingPath.hasPrefix(sandbox + "/")
    }

    private func exists(_ path: String) -> Bool { FileManager.default.fileExists(atPath: path) }

    // MARK: Checks

    private func expect(_ condition: Bool, _ message: @autoclosure () -> String) throws {
        if !condition { throw Failure(message()) }
    }

    private func waitUntil(_ what: String, limit: Double = 60, _ done: () -> Bool) async throws {
        let start = Date()
        while !done() {
            if Date().timeIntervalSince(start) > limit { throw Failure("timed out after \(Int(limit)) s waiting for \(what)") }
            try? await Task.sleep(for: .milliseconds(50))
        }
    }

    /// Checks that each moved item left the sandbox for the Trash, and notes it to be put back at the end.
    private func checkTrashed(_ results: [CleanupResult]) throws {
        for result in results {
            try expect(result.succeeded, "\(result.path) was not moved: \(result.error ?? "?")")
            try checkTrashed(result.path, trash: result.trashedTo)
        }
    }

    private func checkTrashed(_ path: String, trash: String?) throws {
        try expect(isInSandbox(path), "\(path) is outside the sandbox")
        try expect(!exists(path), "\(path) is still there")
        guard let trash else { throw Failure("no Trash location for \(path)") }
        try expect(!isInSandbox(trash) && exists(trash), "\(path) is not in the Trash (\(trash))")
        trashed.append((path, trash))
    }

    private var tree: ScanTree {
        get throws {
            guard let tree = model.tree else { throw Failure("there is no scan") }
            return tree
        }
    }

    private func node(_ path: String) throws -> ScanTree.Index {
        guard let node = try tree.index(ofPath: path) else { throw Failure("\(path) is not in the scan") }
        return node
    }

    private func isRemoved(_ path: String) throws -> Bool {
        guard let node = try tree.index(ofPath: path) else { return true }
        return try tree.flags(node).contains(.removed)
    }

    // MARK: Windows and sheets

    /// The main window: SwiftUI names the windows of the "main" group "main-…".
    private var mainWindow: NSWindow? {
        NSApp.windows.first { $0.isVisible && $0.canBecomeMain && $0.identifier?.rawValue.hasPrefix("main") == true }
    }

    private func expectSheet(_ name: String) async throws {
        try await waitUntil("the \(name) sheet to open", limit: 10) { mainWindow?.attachedSheet != nil }
    }

    private func closeSheets() async {
        model.showReview = false
        if model.showCompress { model.closeCompress() }
        model.showSmartClean = false
        model.showDuplicates = false
        model.showUninstaller = false
        model.showSpaceHunters = false
        model.showCloudSpace = false
        model.showDiskHealth = false
        model.showOnboarding = false
        let start = Date()
        while mainWindow?.attachedSheet != nil && Date().timeIntervalSince(start) < 5 {
            try? await Task.sleep(for: .milliseconds(100))
        }
        try? await Task.sleep(for: .milliseconds(400))
    }

    // MARK: Scenarios

    /// Scans the fake home and checks the totals against the disk and the biggest files.
    private func scanScenario() async throws {
        model.scan(path: home, useCache: false)
        try await waitUntil("the scan", limit: 60) { if case .ready = model.state { return !model.isRefreshing }; return false }
        let tree = try self.tree
        try expect(tree.rootPath == home, "the scan is of \(tree.rootPath)")
        let measured = Self.allocatedBytes(under: home)
        let scanned = tree.size(ScanTree.root)
        try expect(abs(scanned - measured) <= 2 * 1_048_576, "the scan found \(scanned) bytes, the disk says \(measured)")
        try expect(scanned >= 76 * 1_048_576, "the scan found only \(scanned) bytes")
        let names = model.biggestFiles.prefix(3).map { tree.name($0) }
        try expect(Set(names.prefix(2)) == ["holiday.mov", "holiday copy.mov"] && names.last == "build.dmg",
                   "the biggest files are \(names)")
        model.tab = .files
        try expect(model.filteredBiggestFiles.first.map { tree.name($0) }?.hasPrefix("holiday") == true,
                   "the Biggest Files list starts with \(model.filteredBiggestFiles.first.map { tree.name($0) } ?? "nothing")")
        model.tab = .folders
        let folders = Set(model.visibleChildren.map { tree.name($0) })
        try expect(folders.isSuperset(of: ["Movies", "Downloads", "Projects", "Pictures", "Library", "Applications"]),
                   "the folder list is \(folders.sorted())")
    }

    /// A cloud drive whose app does not answer is shown as not available, and neither a scan nor Cloud Space waits
    /// for it.
    private func stuckCloudScenario() async throws {
        if model.tree?.rootPath != home {
            model.scan(path: home, useCache: false)
            try await waitUntil("the scan", limit: 30) { if case .ready = model.state { return !model.isRefreshing }; return false }
        }
        let drive = try node(stuckDrivePath)
        let scan = try tree
        try expect(scan.flags(drive).contains(.unavailable), "the stuck drive has flags \(scan.flags(drive).rawValue)")
        try expect(scan.children(drive).isEmpty && scan.size(drive) <= 4096, "the stuck drive was counted")
        let note = CloudGuard.unavailableNote(for: stuckDrivePath)
        try expect(note.contains("Google Drive"), "the note reads \(note)")
        let start = Date()
        model.scan(path: home, useCache: false)
        try await waitUntil("the second scan", limit: 20) { if case .ready = model.state { return !model.isRefreshing }; return false }
        try expect(Date().timeIntervalSince(start) < 15, "the second scan took \(Int(Date().timeIntervalSince(start))) s")
    }

    /// The scan is cached in the sandbox, read back the same, and shown from the cache on the next scan.
    private func scanCacheScenario() async throws {
        let cache = model.scanCache
        try expect(isInSandbox(cache.directory), "the scan cache is at \(cache.directory)")
        let file = cache.filePath(forRoot: home)
        try await waitUntil("the scan cache file", limit: 10) { exists(file) }
        guard let snapshot = cache.load(root: home) else { throw Failure("the cached scan could not be read") }
        let size = try tree.size(ScanTree.root)
        try expect(snapshot.sizes.first == size, "the cache says \(snapshot.sizes.first ?? 0) bytes, the scan \(size)")
        try expect(AppEnvironment.defaults.string(forKey: "lastScanPath") == home, "the last scanned folder was not kept")
        try expect(UserDefaults.standard.string(forKey: "lastScanPath") != home, "the real settings were changed")

        model.scan(path: home)
        var shownFromCache = false
        try await waitUntil("the scan from the cache", limit: 60) {
            if model.tree != nil && model.isRefreshing { shownFromCache = true }
            if case .ready = model.state { return !model.isRefreshing }
            return false
        }
        say("flow: note scan-cache: cached results were \(shownFromCache ? "" : "not ")seen before the fresh scan finished")
        let rescanned = try tree.size(ScanTree.root)
        try expect(rescanned == size, "the new scan found \(rescanned) bytes, not \(size)")
    }

    /// A clone of the film made with clonefile() counts once: rescanning its folder adds only the clone's own space,
    /// the clone is marked and says what it shares, and the review warns about it. The clone is removed again after.
    private func clonesScenario() async throws {
        let original = home + "/Movies/holiday.mov"
        let clone = try sandboxed(home + "/Movies/holiday clone.mov")
        defer { try? FileManager.default.removeItem(atPath: clone) }
        guard Darwin.clonefile(original, clone, 0) == 0 else {
            say("flow: note clones: this disk cannot clone files (errno \(errno)), skipped")
            return
        }
        let movies = try node(home + "/Movies")
        let before = try tree.size(ScanTree.root)
        model.rescanSubtree(movies)
        try await waitUntil("the rescan of Movies", limit: 30) { model.rescanningNode == nil }
        let tree = try self.tree
        let copy = try node(clone)
        let film = try node(original)
        try expect(tree.flags(copy).contains(.clone) && tree.flags(film).contains(.clone),
                   "the clones are not marked: \(tree.flags(copy)) \(tree.flags(film))")
        let after = tree.size(ScanTree.root)
        try expect(after - before < 1_048_576, "the clone added \(after - before) bytes to the total")
        try expect(tree.cloneSiblingCount(copy) == 1, "the clone has \(tree.cloneSiblingCount(copy)) siblings")
        let note = SpaceNotes.clone(copy, in: tree)
        try expect(note.contains("1"), "the clone says \(note)")
        try expect(model.warnings(for: copy).contains { $0.contains("clone") }, "the review gives no clone warning")

        try FileManager.default.removeItem(atPath: clone)
        model.rescanSubtree(movies)
        try await waitUntil("the second rescan of Movies", limit: 30) { model.rescanningNode == nil }
        let film2 = try node(original)
        let last = try self.tree
        try expect(!last.flags(film2).contains(.clone), "the film is still a clone after its clone went")
        let total = last.size(ScanTree.root)
        try expect(total == before, "the total is \(total), not \(before)")
    }

    /// Rescan after files were added, changed and removed reads only what changed (FSEvents), and comes out the same
    /// as a full scan each time. Everything it makes is in the sandbox and removed again.
    private func quickRescanScenario() async throws {
        let fm = FileManager.default
        let folder = try sandboxed(home + "/Quick")
        let note = try sandboxed(home + "/Movies/notes.txt")
        defer {
            try? fm.removeItem(atPath: folder)
            try? fm.removeItem(atPath: note)
        }
        try write("Quick/a.bin", bytes: 2_000_000, fill: 21)
        try write("Quick/sub/b.bin", bytes: 1_200_000, fill: 22)
        try write("Movies/notes.txt", bytes: 50_000, fill: 23)
        try await quickRescan("new files")
        try await expectSameAsFullScan()

        try Data(repeating: 24, count: 3_000_000).write(to: URL(fileURLWithPath: folder + "/a.bin"))
        try fm.removeItem(atPath: folder + "/sub/b.bin")
        try write("Quick/sub/deeper/c.bin", bytes: 700_000, fill: 25)
        try fm.removeItem(atPath: note)
        try await quickRescan("changed files")
        try await expectSameAsFullScan()

        try fm.removeItem(atPath: folder)
        try await quickRescan("a removed folder")
        try await expectSameAsFullScan()
        try expect(try tree.index(ofPath: folder) == nil, "the removed folder is still in the scan")
    }

    /// Presses Rescan and checks that it was a quick one.
    private func quickRescan(_ what: String) async throws {
        // FSEvents writes its history a moment after the change.
        try? await Task.sleep(for: .seconds(1.5))
        let start = Date()
        model.rescan()
        try await waitUntil("the rescan after \(what)", limit: 60) {
            if case .ready = model.state { return !model.isRefreshing }
            return false
        }
        guard case .quick(let report)? = model.lastRefresh else {
            throw Failure("the rescan after \(what) was not quick: \(String(describing: model.lastRefresh))")
        }
        say(String(format: "flow: note quick-rescan: %@ took %.2f s, %ld folders listed, %ld scanned", what,
                   Date().timeIntervalSince(start), report.listedFolders, report.scannedFolders))
    }

    /// The shown scan has the same items, sizes and totals as a full scan of the home folder now.
    private func expectSameAsFullScan() async throws {
        let quick = try tree
        let full = try await DiskScanner().scan(root: home)
        try expect(quick.size(ScanTree.root) == full.size(ScanTree.root),
                   "the quick rescan found \(quick.size(ScanTree.root)) bytes, a full scan \(full.size(ScanTree.root))")
        try expect(quick.fileCount(ScanTree.root) == full.fileCount(ScanTree.root),
                   "the quick rescan counts \(quick.fileCount(ScanTree.root)) files, a full scan \(full.fileCount(ScanTree.root))")
        var fullPaths = Set<String>()
        for i in 0..<ScanTree.Index(full.count) where !full.flags(i).contains(.removed) {
            let path = full.path(of: i)
            fullPaths.insert(path)
            guard let j = quick.index(ofPath: path) else { throw Failure("\(path) is missing after the quick rescan") }
            try expect(quick.size(j) == full.size(i) && quick.kind(j) == full.kind(i),
                       "\(path) is \(quick.size(j)) bytes after the quick rescan, \(full.size(i)) in a full scan")
        }
        var stack: [ScanTree.Index] = [ScanTree.root]
        while let n = stack.popLast() {
            let path = quick.path(of: n)
            try expect(fullPaths.contains(path), "\(path) is in the quick rescan but not on disk")
            stack.append(contentsOf: quick.children(n))
        }
    }

    /// "Free Purgeable Space" with the pretend releaser the flow test always gets: free space before and after are
    /// measured and the result is shown. macOS is never asked to free anything here.
    private func freePurgeableScenario() async throws {
        let disk = model.diskOverview
        guard let rehearsal = disk.releaser as? RehearsalReleaser else {
            throw Failure("the flow test is not using the pretend releaser: \(type(of: disk.releaser))")
        }
        model.refreshDiskOverview()
        try await waitUntil("the disk overview", limit: 10) { disk.space != nil }
        disk.freePurgeable(scanned: model.scannedBytes)
        try expect(disk.purge.isRunning, "it did not start: \(disk.purge)")
        try await waitUntil("free purgeable space", limit: 30) { !disk.purge.isRunning }
        guard case .done(let outcome) = disk.purge else { throw Failure("it ended as \(disk.purge)") }
        try expect(rehearsal.requests == 1, "the releaser was asked \(rehearsal.requests) times")
        let freed = outcome.freedBytes
        try expect(abs(freed - rehearsal.amount) < 200_000_000, "it measured \(freed) bytes freed, not about \(rehearsal.amount)")
        disk.dismissPurgeResult()
        try expect(disk.purge == .idle, "the result did not close")
    }

    /// The home folder and a keychain cannot go to the tray or the Trash, and the reason is said.
    private func blockedPathScenario() throws {
        let keychains = try node(keychainPath)
        let reason = String(localized: "Keychains hold your passwords.")
        try expect(model.verdict(for: keychains) == .blocked(reason), "the keychain verdict is \(model.verdict(for: keychains))")
        try expect(!model.addToTray(keychains), "the keychains folder went into the tray")
        try expect(model.trayNotice?.contains(reason) == true, "the tray says \(model.trayNotice ?? "nothing")")
        model.toggleBasket(keychains)
        try expect(model.basket.isEmpty, "the tick box added the keychains folder")
        let rootVerdict = model.verdict(for: ScanTree.root)
        try expect(rootVerdict == .blocked(String(localized: "This is your home folder.")), "the home folder verdict is \(rootVerdict)")

        let service = AppEnvironment.cleanupService()
        let report = service.execute(service.plan(paths: [keychainPath], sizeOf: { _ in 0 }))
        try expect(report.failed.first?.error == reason, "CleanupService said \(report.results)")
        try expect(exists(keychainPath + "/login.keychain-db"), "the keychain is gone")
        // The flow test's rules block anything outside the sandbox. The file does not exist; nothing is touched.
        let outside = NSHomeDirectory() + "/RoomyDisk flow test \(UUID().uuidString)"
        let refused = service.execute(service.plan(paths: [outside], sizeOf: { _ in 0 }))
        try expect(refused.failed.first?.error == SafetyPolicy.outsideConfinement, "a path outside the sandbox got \(refused.results)")
    }

    /// Tick a file, open Review and Clean, and move it: it goes to the Trash and leaves the scan.
    private func reviewScenario() async throws {
        let path = home + "/Projects/app/build.dmg"
        let item = try node(path)
        let tree = try self.tree
        let bytes = tree.size(item)
        let before = tree.size(ScanTree.root)
        model.toggleBasket(item)
        try expect(model.basket == [item] && model.basketBytes == bytes, "the tray holds \(model.basket.count) items")
        model.showReview = true
        try await expectSheet("Review and Clean")
        model.performCleanup()
        try await waitUntil("the clean", limit: 30) { !model.isCleaning }
        guard let report = model.lastReport else { throw Failure("no report") }
        try expect(report.results.map(\.path) == [path], "the clean moved \(report.results.map(\.path))")
        try checkTrashed(report.results)
        try expect(try isRemoved(path), "build.dmg is still in the scan")
        try expect(tree.size(ScanTree.root) == before - bytes, "the scan total is \(tree.size(ScanTree.root)), expected \(before - bytes)")
        try expect(!model.biggestFiles.contains(item), "build.dmg is still among the biggest files")
        try expect(model.basket.isEmpty, "the tray was not emptied")
        let history = AppEnvironment.history?.load() ?? []
        try expect(history.last?.results.map(\.path) == [path], "the cleanup history in the sandbox does not have the clean")
    }

    /// Compress a file from the sheet: the zip is made next to it and the original goes to the Trash.
    private func compressScenario() async throws {
        let path = home + "/Projects/app/notes.txt"
        let item = try node(path)
        try expect(model.canCompress(item), "notes.txt cannot be compressed")
        model.startCompress(item)
        try expect(model.showCompress && model.compressTargets == [item], "the Compress sheet was not set up")
        try await expectSheet("Compress")
        model.performCompress()
        try await waitUntil("the compression", limit: 60) { !model.isCompressing && model.compressResults != nil }
        guard let result = model.compressResults?.first, model.compressResults?.count == 1 else { throw Failure("no result") }
        try expect(result.succeeded, "compressing failed: \(result.error ?? "?")")
        guard let archive = result.archivePath else { throw Failure("no archive") }
        try expect(archive == path + ".zip" && exists(archive), "the archive is at \(archive)")
        try expect(result.archiveBytes < result.originalBytes, "the archive is not smaller")
        try checkTrashed(path, trash: result.trashedTo)
        try expect(try isRemoved(path), "notes.txt is still in the scan")
        try expect(try tree.index(ofPath: archive) != nil, "the archive is not in the scan")
        model.closeCompress()
    }

    /// Old downloads, an old iPhone backup and two sizes of one picture. Nothing is removed.
    private func spaceHuntersScenario() async throws {
        let hunters = model.spaceHunters
        hunters.now = { Date().addingTimeInterval(120 * 86_400) }
        model.openSpaceHunters()
        try await expectSheet("Space Hunters")
        try await waitUntil("the hunt", limit: 150) { hunters.phase == .ready }
        try expect(hunters.backups.map(\.deviceName) == ["Flow iPhone"], "backups found: \(hunters.backups.map(\.deviceName))")
        try expect(hunters.downloads.contains { $0.path == home + "/Downloads/holiday copy.mov" },
                   "old downloads found: \(hunters.downloads.map(\.name))")
        let pictures = Set(["beach.jpg", "beach small.jpg"].map { home + "/Pictures/" + $0 })
        try expect(hunters.photoGroups.contains { Set($0.photos.map(\.path)) == pictures },
                   "similar photo groups: \(hunters.photoGroups.map { $0.photos.map(\.path) })")
        try expect(!hunters.selected.contains(home + "/Downloads/holiday copy.mov"), "an old download was ticked by itself")
        try expect(hunters.foundBytes > 0, "the hunt found nothing")
        hunters.now = { Date() }
    }

    /// Duplicates finds the two copies of the film, keeps one and moves the other.
    private func duplicatesScenario() async throws {
        let copies = Set([home + "/Movies/holiday.mov", home + "/Downloads/holiday copy.mov"])
        let duplicates = model.duplicates
        model.openDuplicates()
        try await expectSheet("Duplicates")
        try await waitUntil("the duplicate search", limit: 60) { duplicates.phase == .ready }
        try expect(duplicates.errorMessage == nil, "Duplicates failed: \(duplicates.errorMessage ?? "")")
        try expect(duplicates.groups.contains { Set($0.files.map(\.path)) == copies },
                   "groups: \(duplicates.groups.map { $0.files.map(\.path) })")
        let ticked = duplicates.selectedFiles.map(\.path)
        try expect(ticked.count == 1 && copies.contains(ticked[0]), "ticked: \(ticked)")
        duplicates.clean()
        try await waitUntil("the clean", limit: 30) { duplicates.phase == .done }
        guard let report = duplicates.report else { throw Failure("no report") }
        try expect(report.results.map(\.path) == ticked, "moved: \(report.results.map(\.path))")
        try checkTrashed(report.results)
        try expect(copies.filter(exists).count == 1, "\(copies.filter(exists).count) copies are left")
        try expect(try isRemoved(ticked[0]), "the moved copy is still in the scan")
    }

    /// The Uninstaller lists the fake app, finds its leftovers and moves them with the app.
    private func uninstallerScenario() async throws {
        let uninstaller = model.uninstaller
        let appPath = home + "/Applications/Flow Sample.app"
        model.openUninstaller()
        try await expectSheet("Uninstaller")
        try await waitUntil("the app list", limit: 60) { uninstaller.phase == .ready && uninstaller.measured.contains(appPath) }
        guard let app = uninstaller.apps.first(where: { $0.path == appPath }) else {
            throw Failure("the app list is \(uninstaller.apps.map(\.name))")
        }
        try expect(app.name == "Flow Sample" && app.bundleID == Self.appID, "the app reads as \(app.name), \(app.bundleID ?? "-")")
        uninstaller.select(app)
        try await waitUntil("the leftovers", limit: 30) { !uninstaller.isFindingLeftovers }
        let library = home + "/Library/"
        let expected = Set(["Application Support/\(Self.appID)", "Preferences/\(Self.appID).plist",
                            "Saved Application State/\(Self.appID).savedState"].map { library + $0 })
        let found = Set(uninstaller.leftovers.map(\.path))
        try expect(found == expected, "leftovers found: \(found.sorted())")
        try expect(uninstaller.ticked == expected.union([appPath]), "ticked: \(uninstaller.ticked.sorted())")
        uninstaller.uninstall()
        try await waitUntil("the uninstall", limit: 30) { uninstaller.phase == .done }
        guard let report = uninstaller.report else { throw Failure("no report") }
        try expect(uninstaller.appFailure == nil && uninstaller.errorMessage == nil,
                   "the uninstall failed: \(uninstaller.appFailure ?? uninstaller.errorMessage ?? "")")
        try expect(report.results.last?.path == appPath, "the app was not moved last")
        try checkTrashed(report.results)
        try expect(Set(report.results.map(\.path)) == expected.union([appPath]), "moved: \(report.results.map(\.path))")
        try expect(!uninstaller.apps.contains { $0.path == appPath }, "the app is still listed")
        uninstaller.showList()
    }

    /// Leftovers of removed apps: only the item named exactly by the app in the Trash starts ticked, and only it moves.
    private func orphansScenario() async throws {
        let uninstaller = model.uninstaller
        model.openUninstaller()
        try await expectSheet("Uninstaller")
        try await waitUntil("the app list", limit: 60) { uninstaller.phase == .ready }
        uninstaller.showOrphans()
        try await waitUntil("the leftovers of removed apps", limit: 60) { uninstaller.orphansLoaded && !uninstaller.isFindingOrphans }
        let library = home + "/Library/"
        let sure = library + "Application Support/\(Self.goneID)"
        let byName = library + "Application Support/Gone App"
        let unknown = library + "Preferences/io.github.roomy.unknowntool.plist"
        guard let gone = uninstaller.orphans.first(where: { $0.bundleID == Self.goneID }) else {
            throw Failure("groups: \(uninstaller.orphans.map(\.bundleID))")
        }
        try expect(gone.appName == "Gone App", "the app is named \(gone.appName ?? "nil")")
        let levels = Dictionary(gone.items.map { ($0.path, $0.confidence) }, uniquingKeysWith: { a, _ in a })
        try expect(levels == [sure: .high, byName: .medium], "its items: \(levels)")
        let all = uninstaller.orphans.flatMap(\.items)
        try expect(all.first { $0.path == unknown }?.confidence == .low, "the unknown tool's item: \(all.map(\.path))")
        try expect(!all.contains { $0.path.contains("/com.apple.") }, "an item of macOS was offered")
        try expect(uninstaller.orphanTicked == [sure], "ticked: \(uninstaller.orphanTicked.sorted())")
        try expect(uninstaller.orphans.first?.confidence == .high, "the surest group is not first")

        uninstaller.removeOrphans()
        try await waitUntil("the removal", limit: 30) { uninstaller.phase == .done }
        guard let report = uninstaller.report else { throw Failure("no report") }
        try expect(report.results.map(\.path) == [sure], "moved: \(report.results.map(\.path))")
        try checkTrashed(report.results)
        try expect(exists(byName) && exists(unknown), "an unticked item was moved")
        uninstaller.showList()
        // The made-up Trash would show up in Smart Clean; it moves out of the home, still inside the sandbox.
        try FileManager.default.moveItem(atPath: try sandboxed(home + "/.Trash"), toPath: try sandboxed(state + "/old-trash"))
    }

    /// Login Items lists the sandbox's launch agents and daemon, refuses Apple's and the daemon, and turns off your
    /// own agent: launchd (a stand-in here) is asked to stop it and its plist goes to the Trash.
    private func loginItemsScenario() async throws {
        let login = model.loginItems
        guard let control = AppEnvironment.launchControl as? RecordingLaunchControl else { throw Failure("launchctl is not stood in for") }
        model.openUninstaller(section: .loginItems)
        defer { model.uninstaller.section = .apps }
        try await expectSheet("Uninstaller")
        try await waitUntil("the login items", limit: 60) { login.loaded && !login.isLoading }
        let byLabel = Dictionary(login.items.map { ($0.label, $0) }, uniquingKeysWith: { a, _ in a })
        guard let agent = byLabel[Self.agentLabel] else { throw Failure("items: \(login.items.map(\.label))") }
        try expect(agent.domain == .userAgent && agent.isLoaded == true && agent.program == "/usr/bin/true",
                   "the agent reads as \(agent)")
        guard let daemon = byLabel["io.github.roomy.flowdaemon"] else { throw Failure("no daemon in \(login.items.map(\.label))") }
        try expect(daemon.domain == .systemDaemon && login.refusal(for: daemon) != nil, "the daemon could be turned off")
        guard let apple = byLabel["com.apple.flowtest"] else { throw Failure("no Apple agent") }
        try expect(login.refusal(for: apple) != nil, "Apple's agent could be turned off")
        try expect(login.refusal(for: agent) == nil, "the agent is refused: \(login.refusal(for: agent) ?? "")")

        login.turnOff(agent)
        try await waitUntil("turning off", limit: 30) { login.turningOff == nil && login.lastResult != nil }
        guard let result = login.lastResult else { throw Failure("no result") }
        try checkTrashed([result])
        try expect(control.bootedOut == [Self.agentLabel], "launchd was asked to stop \(control.bootedOut)")
        try expect(!login.items.contains { $0.label == Self.agentLabel }, "the agent is still listed")
        try expect(exists(home + "/Library/LaunchAgents/com.apple.flowtest.plist"), "Apple's agent was moved")
    }

    /// Installers finds the made-up package whose app is gone, offers what it left unticked, and moves only what
    /// is ticked.
    private func installersScenario() async throws {
        let receipts = model.receipts
        let uninstaller = model.uninstaller
        model.openUninstaller(section: .installers)
        defer { uninstaller.section = .apps }
        try await expectSheet("Uninstaller")
        try await waitUntil("the receipts", limit: 60) { receipts.loaded && !receipts.isLoading }
        guard let finding = receipts.findings.first(where: { $0.package.id == "io.github.roomy.flowpkg" }) else {
            throw Failure("findings: \(receipts.findings.map(\.package.id))")
        }
        let system = sandbox + "/system"
        let engine = system + "/Library/Application Support/FlowTool"
        let tool = system + "/usr/local/bin/flowtool"
        try expect(finding.appName == "Flow Tool", "the app is named \(finding.appName)")
        try expect(Set(finding.leftovers.map(\.path)) == [engine, tool], "leftovers: \(finding.leftovers.map(\.path))")
        try expect(receipts.ticked.isEmpty, "something was ticked by itself: \(receipts.ticked.sorted())")
        try expect(uninstaller.removedByReceipts.contains { $0.name == "Flow Tool" }, "the removed app was not passed on")
        try await waitUntil("the app list", limit: 30) { uninstaller.phase == .ready }

        receipts.toggle(tool)
        let items = receipts.tickedItems
        uninstaller.removeFiles(items.map(\.path), sizes: Dictionary(items.map { ($0.path, $0.bytes) }, uniquingKeysWith: { a, _ in a }))
        try await waitUntil("the removal", limit: 30) { uninstaller.phase == .done }
        guard let report = uninstaller.report else { throw Failure("no report") }
        try expect(report.results.map(\.path) == [tool], "moved: \(report.results.map(\.path))")
        try checkTrashed(report.results)
        try expect(exists(engine), "an unticked leftover was moved")
        try expect(receipts.findings.first?.leftovers.map(\.path) == [engine], "the moved file is still listed")
        uninstaller.showList()
    }

    /// The unused languages of an unsigned app are offered unticked; a ticked one goes to the Trash and the app stays.
    private func languagesScenario() async throws {
        let uninstaller = model.uninstaller
        let appPath = home + "/Applications/Polyglot.app"
        model.openUninstaller(section: .apps)
        try await expectSheet("Uninstaller")
        try await waitUntil("the app list", limit: 60) { uninstaller.phase == .ready && uninstaller.measured.contains(appPath) }
        guard let app = uninstaller.apps.first(where: { $0.path == appPath }) else { throw Failure("Polyglot is not listed") }
        uninstaller.select(app)
        try await waitUntil("the languages", limit: 30) { !uninstaller.isFindingLeftovers && uninstaller.languages != nil }
        let resources = appPath + "/Contents/Resources/"
        let folders = Set(uninstaller.removableLanguages.map(\.path))
        try expect(folders.isSuperset(of: [resources + "de.lproj", resources + "ja.lproj"]) &&
                   !folders.contains(resources + "en.lproj") && !folders.contains(resources + "Base.lproj"),
                   "offered: \(folders.sorted())")
        try expect(uninstaller.ticked.isDisjoint(with: folders), "a language was ticked by itself")

        uninstaller.toggle(appPath)
        uninstaller.toggle(resources + "de.lproj")
        uninstaller.uninstall()
        try await waitUntil("the removal", limit: 30) { uninstaller.phase == .done }
        guard let report = uninstaller.report else { throw Failure("no report") }
        try expect(report.results.map(\.path) == [resources + "de.lproj"], "moved: \(report.results.map(\.path))")
        try checkTrashed(report.results)
        try expect(exists(appPath) && exists(resources + "ja.lproj"), "the app or another language was moved")
        uninstaller.showList()
    }

    /// "Uninstall with RoomyDisk" in Finder's Services menu: the Info.plist offers it for apps, and handing the service
    /// an app opens the Uninstaller with it chosen, also for an app outside the app folders. Nothing is removed.
    private func finderServiceScenario() async throws {
        let services = Bundle.main.object(forInfoDictionaryKey: "NSServices") as? [[String: Any]] ?? []
        guard let entry = services.first(where: { $0["NSMessage"] as? String == "uninstallApp" }) else {
            throw Failure("the Info.plist offers no uninstall service: \(services)")
        }
        try expect((entry["NSSendFileTypes"] as? [String])?.contains("com.apple.application-bundle") == true,
                   "the service is not offered for apps: \(entry)")
        try expect(UninstallService.shared.responds(to: Selector(("uninstallApp:userData:error:"))), "the service method is missing")

        func send(_ paths: [String]) -> String? {
            let board = NSPasteboard(name: NSPasteboard.Name("io.github.roomy.flow-service"))
            board.clearContents()
            board.writeObjects(paths.map { URL(fileURLWithPath: $0) as NSURL })
            var error: NSString?
            UninstallService.shared.uninstallApp(board, userData: nil, error: &error)
            board.releaseGlobally()
            return error as String?
        }
        let uninstaller = model.uninstaller
        try expect(send([home + "/Movies/holiday.mov"]) != nil, "a film was accepted as an app")
        try expect(!model.showUninstaller, "the Uninstaller opened for a film")

        let polyglot = home + "/Applications/Polyglot.app"
        try expect(send([home + "/Movies/holiday.mov", polyglot]) == nil, "the app was refused")
        try await expectSheet("Uninstaller")
        try await waitUntil("Polyglot to be chosen", limit: 30) { uninstaller.selectedApp?.path == polyglot }
        try expect(uninstaller.section == .apps, "the Uninstaller shows \(uninstaller.section)")
        try await waitUntil("its leftovers", limit: 30) { !uninstaller.isFindingLeftovers }
        await closeSheets()

        // An app somewhere else, as when it is run from Downloads.
        let elsewhere = "Downloads/Elsewhere.app/Contents"
        try writePlist(elsewhere + "/Info.plist", ["CFBundleIdentifier": "io.github.roomy.elsewhere", "CFBundleName": "Elsewhere",
                                                   "CFBundlePackageType": "APPL"])
        let path = home + "/Downloads/Elsewhere.app"
        try expect(send([path]) == nil, "the app outside Applications was refused")
        try await expectSheet("Uninstaller")
        try await waitUntil("Elsewhere to be chosen", limit: 30) { uninstaller.selectedApp?.path == path }
        try expect(uninstaller.ticked.contains(path), "the chosen app is not ticked for review")
        try expect(exists(path), "the app was moved")
    }

    /// Updates lists the apps with feeds and from the App Store, asks nothing until Check, then finds Feedy's newer
    /// version from the made-up feed. Nothing is opened or downloaded.
    private func appUpdatesScenario() async throws {
        let updates = model.appUpdates
        let uninstaller = model.uninstaller
        model.openUninstaller(section: .updates)
        defer { uninstaller.section = .apps }
        try await expectSheet("Uninstaller")
        try await waitUntil("the apps to check", limit: 60) { uninstaller.phase == .ready && !updates.apps.isEmpty }
        let names = Set(updates.apps.map(\.name))
        try expect(names == ["Feedy", "Fresh", "Lost", "Storey"], "apps to check: \(names.sorted())")
        try expect(updates.available.isEmpty && updates.checkedAt == nil && !updates.isChecking, "it checked before being asked")
        try expect(updates.appStoreApps.map(\.name) == ["Storey"], "App Store apps: \(updates.appStoreApps.map(\.name))")

        updates.check()
        try await waitUntil("the check", limit: 30) { !updates.isChecking }
        try expect(updates.available.map(\.app.name) == ["Feedy"], "updates: \(updates.available.map(\.app.name))")
        let item = updates.available[0].item
        try expect(item.displayVersion == "1.2" && item.downloadURL?.absoluteString == "https://updates.example.invalid/feedy/Feedy-1.2.zip",
                   "the update reads as \(item)")
        try expect(updates.upToDateCount == 1, "\(updates.upToDateCount) up to date")
        try expect(updates.failed.map(\.app.name) == ["Lost"], "failed: \(updates.failed.map(\.app.name))")
    }

    /// Smart Clean finds the caches, logs and an Xcode archive, and moves only what it ticks by itself.
    private func smartCleanScenario() async throws {
        try makeJunk()
        let smart = model.smartClean
        model.openSmartClean()
        try expect(model.showSmartClean, "the Smart Clean sheet was not asked for")
        try await expectSheet("Smart Clean")
        try await waitUntil("the junk search", limit: 60) { smart.phase == .ready }
        let byID = Dictionary(smart.findings.map { ($0.id, Set($0.paths)) }, uniquingKeysWith: { a, _ in a })
        try expect(byID["caches"] == [cachePath] && byID["logs"] == [logPath] && byID["archives"] == [archivePath],
                   "findings: \(byID)")
        try expect(Set(smart.selectedItems.map(\.path)) == [cachePath, logPath],
                   "ticked: \(smart.selectedItems.map(\.path))")
        smart.clean()
        try await waitUntil("the clean", limit: 30) { smart.phase == .done }
        guard let report = smart.report else { throw Failure("no report") }
        try expect(Set(report.results.map(\.path)) == [cachePath, logPath], "moved: \(report.results.map(\.path))")
        try checkTrashed(report.results)
        try expect(exists(archivePath), "the Xcode archive, which needs a review first, was moved")
        try expect(smart.findings.map(\.id) == ["archives"], "left in Smart Clean: \(smart.findings.map(\.id))")
        let cacheGone = try isRemoved(cachePath), logGone = try isRemoved(logPath)
        try expect(cacheGone && logGone, "the main scan still has the cleaned junk")
    }

    /// Cloud Space finds the fake iCloud Drive and Dropbox folders and offers nothing that is not safely in the cloud.
    private func cloudSpaceScenario() async throws {
        let cloud = model.cloudSpace
        model.openCloudSpace()
        try await expectSheet("Cloud Space")
        try await waitUntil("the cloud search", limit: 60) { cloud.phase == .ready }
        let names = Set(cloud.providers.map(\.name))
        try expect(names == ["iCloud Drive", "Dropbox", "Google Drive"], "providers: \(names.sorted())")
        try expect(cloud.findings.unavailable.map(\.rootPath) == [stuckDrivePath],
                   "not available: \(cloud.findings.unavailable.map(\.rootPath))")
        try expect(cloud.findings.evictableBytes == 0 && cloud.selectedItems.isEmpty,
                   "files that are not in the cloud were offered: \(cloud.selectedItems.map(\.path))")
        cloud.removeDownloads()
        try expect(cloud.phase == .ready, "removing with nothing ticked started")
        try expect(exists(home + "/Library/CloudStorage/Dropbox/Documents/report.pdf"), "a Dropbox file is gone")
    }

    /// The background check measures the junk and keeps its summary in the test's settings.
    private func automaticCheckScenario() async throws {
        try makeJunk()
        let check = model.autoCheck
        check.check()
        try expect(check.isChecking, "the check did not start")
        try await waitUntil("the check", limit: 60) { !check.isChecking }
        guard let summary = check.summary else { throw Failure("there is no summary") }
        let safe = JunkSummary.safeItems(check.findings)
        try expect(Set(safe.map(\.path)) == [cachePath, logPath], "Quick Clean would move \(safe.map(\.path))")
        try expect(summary.totalBytes == safe.reduce(0) { $0 + $1.bytes } && summary.totalBytes > 0,
                   "the summary says \(summary.totalBytes) bytes")
        try expect(Set(summary.parts.map(\.category)) == [.caches, .logs], "the summary has \(summary.parts.map(\.category))")
        try expect(check.reclaimable == summary.totalBytes, "the menu bar would show \(check.reclaimable)")
        guard let data = AppEnvironment.defaults.data(forKey: AutoCheckSettings.summaryKey),
              let saved = try? JSONDecoder().decode(JunkSummary.self, from: data) else { throw Failure("the summary was not saved") }
        try expect(saved == summary, "the saved summary differs")
    }

    /// Quick Clean in the menu bar popover: confirm, then move only the safe junk.
    private func quickCleanScenario() async throws {
        let check = model.autoCheck
        if check.findings.isEmpty {
            try makeJunk()
            check.check()
            try await waitUntil("the check", limit: 60) { !check.isChecking }
        }
        let items = Set(check.quickCleanItems.map(\.path))
        try expect(items == [cachePath, logPath], "Quick Clean would move \(items.sorted())")
        let popover = NSWindow(contentViewController: NSHostingController(
            rootView: MenuBarView().environment(model).environment(MenuBarDiskModel())))
        popover.isReleasedWhenClosed = false
        popover.makeKeyAndOrderFront(nil)
        defer { popover.close() }
        try? await Task.sleep(for: .milliseconds(500))

        check.askToClean()
        try expect(check.phase == .confirming, "Quick Clean did not ask first")
        check.cancelClean()
        try expect(check.phase == .idle && exists(cachePath), "Cancel did not cancel")
        check.askToClean()
        check.clean()
        try await waitUntil("Quick Clean", limit: 30) { check.phase == .done }
        guard let report = check.report else { throw Failure("no report") }
        try expect(Set(report.results.map(\.path)) == items, "moved: \(report.results.map(\.path))")
        try checkTrashed(report.results)
        try expect(exists(archivePath), "Quick Clean moved the Xcode archive")
        try expect(check.reclaimable == 0, "the menu bar still shows \(check.reclaimable) bytes")
        check.dismissResult()
        try expect(check.phase == .idle, "Done did not go back to the summary")
    }

    /// Disk Health reads the disks of this Mac. It only looks.
    private func diskHealthScenario() async throws {
        let health = model.diskHealth
        model.openDiskHealth()
        try await expectSheet("Disk Health")
        try await waitUntil("the disk reports", limit: 90) { health.phase == .ready }
        try expect(!health.reports.isEmpty, "no disks were read")
        try expect(health.overall != nil, "no overall verdict")
    }

    /// Export as CSV writes a header and a row for each item of the open folder, and with depth 2 the items inside.
    private func csvScenario() async throws {
        let tree = try self.tree
        model.go(to: ScanTree.root)
        let url = URL(fileURLWithPath: state + "/export.csv")
        try await CSVExporter.write(tree: tree, folder: model.currentFolder, depth: 1, to: url)
        let lines = try String(contentsOf: url, encoding: .utf8).split(separator: "\n").map(String.init)
        let children = tree.children(ScanTree.root).filter { !tree.flags($0).contains(.removed) }
        try expect(lines.first == CSV.line(TreeCSV.header), "the header is \(lines.first ?? "missing")")
        try expect(lines.count == children.count + 1, "\(lines.count - 1) rows for \(children.count) items")
        let movies = try node(home + "/Movies")
        let row = lines.first { $0.hasPrefix(home + "/Movies,") }?.split(separator: ",").map(String.init) ?? []
        try expect(row.count >= 5 && row[1] == "Movies" && row[2] == "folder" && row[4] == String(tree.size(movies)),
                   "the Movies row is \(row)")

        try await CSVExporter.write(tree: tree, folder: ScanTree.root, depth: 2, to: url)
        let deeper = try String(contentsOf: url, encoding: .utf8).split(separator: "\n").count
        let inside = children.filter { tree.kind($0) == .directory }
            .reduce(0) { $0 + tree.children($1).filter { !tree.flags($0).contains(.removed) }.count }
        try expect(deeper == children.count + inside + 1, "depth 2 wrote \(deeper - 1) rows, expected \(children.count + inside)")
    }

    /// A click on the "can be freed" notice opens the main window with Smart Clean, with the menu bar icon hidden and
    /// the window closed; one on the failing disk notice opens Disk Health on a minimized window.
    private func notificationScenario() async throws {
        try expect(AppDelegate.route(forNotification: LowSpaceNotifier.reclaimableIdentifier) == .smartClean, "wrong route")
        try expect(AppDelegate.route(forNotification: DiskHealthNotifier.identifier) == .diskHealth, "wrong route")
        try expect(AppDelegate.route(forNotification: LowSpaceNotifier.requestIdentifier) == .main, "wrong route")
        AppEnvironment.defaults.set(false, forKey: MenuBarSettings.key)
        defer { AppEnvironment.defaults.set(true, forKey: MenuBarSettings.key) }
        try expect(!MenuBarSettings.isShown, "the menu bar icon is still on")
        try? await Task.sleep(for: .milliseconds(500))

        guard let window = mainWindow else { throw Failure("there is no main window") }
        window.close()
        try await waitUntil("the main window to close", limit: 5) { mainWindow == nil }
        MainWindow.show(AppDelegate.route(forNotification: LowSpaceNotifier.reclaimableIdentifier))
        try await waitUntil("a new main window", limit: 10) { mainWindow != nil }
        try expect(model.showSmartClean, "Smart Clean was not opened")
        try await expectSheet("Smart Clean")
        say("flow: note notification-route: window \(mainWindow?.identifier?.rawValue ?? "?")")
        try await waitUntil("Smart Clean to settle", limit: 60) { !model.smartClean.isBusy }
        await closeSheets()

        guard let reopened = mainWindow else { throw Failure("the main window went away") }
        reopened.miniaturize(nil)
        try await waitUntil("the window to minimize", limit: 10) { reopened.isMiniaturized }
        MainWindow.show(AppDelegate.route(forNotification: DiskHealthNotifier.identifier))
        do {
            try await waitUntil("the window to come back", limit: 10) { !reopened.isMiniaturized && reopened.isVisible }
        } catch {
            let windows = NSApp.windows.map { "\($0.identifier?.rawValue ?? "-") visible \($0.isVisible) mini \($0.isMiniaturized)" }
            throw Failure("\(error); active \(NSApp.isActive), hidden \(NSApp.isHidden), Disk Health asked \(model.showDiskHealth), windows \(windows)")
        }
        try expect(model.showDiskHealth, "Disk Health was not opened")
        try await expectSheet("Disk Health")
        try expect(NSApp.windows.filter { $0.isVisible && $0.identifier?.rawValue.hasPrefix("main") == true }.count == 1,
                   "a second main window opened")
        try await waitUntil("Disk Health to settle", limit: 60) { !model.diskHealth.isBusy }
    }

    /// A Settings toggle, pressed in the real Settings window, is kept in the test's settings and read by the app;
    /// the real settings stay as they were.
    private func settingsScenario() async throws {
        let defaults = AppEnvironment.defaults
        let key = AutoCheckSettings.showAmountKey
        let realBefore = UserDefaults.standard.object(forKey: key) as? Bool
        let realIntervalBefore = UserDefaults.standard.string(forKey: AutoCheckSettings.intervalKey)
        let before = defaults.object(forKey: key) as? Bool ?? true

        AppEnvironment.defaults.set(AlertSettingsView.Tab.general.rawValue, forKey: AlertSettingsView.tabKey)
        let settings = try await openSettings()
        defer { settings.close() }
        try? await Task.sleep(for: .seconds(1))
        let title = String(localized: "Show what can be freed next to the icon")
        let controls = Self.controls(in: settings.contentView)
        say("flow: note settings: controls \(controls.map { "\(type(of: $0))\(($0 as? NSButton).map { " '\($0.title)'" } ?? "")" })")
        if let toggle = Self.findElement(role: .checkBox, title: title, in: settings) {
            _ = (toggle as AnyObject).accessibilityPerformPress?()
            try await waitUntil("the toggle to be kept", limit: 5) { defaults.object(forKey: key) as? Bool == !before }
            say("flow: note settings: pressed the toggle in the Settings window")
        } else if let button = controls.compactMap({ $0 as? NSButton }).first(where: { $0.title == title }) {
            button.performClick(nil)
            try await waitUntil("the toggle to be kept", limit: 5) { defaults.object(forKey: key) as? Bool == !before }
            say("flow: note settings: clicked the toggle in the Settings window")
        } else if let toggle = Self.switches(in: controls).dropFirst().first {
            // The General tab's switches, top to bottom: the menu bar icon, then what can be freed next to it.
            toggle.state = toggle.state == .on ? .off : .on
            toggle.sendAction(toggle.action, to: toggle.target)
            try await waitUntil("the switch to be kept", limit: 5) { defaults.object(forKey: key) as? Bool == !before }
            say("flow: note settings: flipped the switch in the Settings window")
        } else {
            defaults.set(!before, forKey: key)
            say("flow: note settings: the toggle was not reachable through accessibility; set through the settings store")
        }
        let reread = UserDefaults(suiteName: AppEnvironment.flowDefaultsSuite)?.object(forKey: key) as? Bool
        try expect(reread == !before, "a fresh read of the settings says \(String(describing: reread))")

        defaults.set(AutoCheckInterval.daily.rawValue, forKey: AutoCheckSettings.intervalKey)
        try expect(AutoCheckSettings.interval == .daily, "the check interval reads as \(AutoCheckSettings.interval)")
        AppEnvironment.defaults.set(AlertSettingsView.Tab.checks.rawValue, forKey: AlertSettingsView.tabKey)
        try? await Task.sleep(for: .seconds(1))
        try expect(settings.isVisible, "the Settings window closed on the Checks tab")
        try expect(UserDefaults.standard.object(forKey: key) as? Bool == realBefore, "the real settings were changed")
        try expect(UserDefaults.standard.string(forKey: AutoCheckSettings.intervalKey) == realIntervalBefore,
                   "the real check interval was changed")
    }

    /// Opens Settings through the RoomyDisk menu, as a click on Settings… does.
    private func openSettings() async throws -> NSWindow {
        let before = Set(NSApp.windows.map(ObjectIdentifier.init))
        guard let menu = NSApp.mainMenu?.items.first?.submenu,
              let index = menu.items.firstIndex(where: { $0.keyEquivalent == "," }) else { throw Failure("no Settings menu item") }
        menu.performActionForItem(at: index)
        var found: NSWindow?
        try await waitUntil("the Settings window", limit: 10) {
            found = NSApp.windows.first {
                $0.isVisible && (!before.contains(ObjectIdentifier($0)) || $0.identifier?.rawValue.contains("Settings") == true)
            }
            return found != nil
        }
        return found!
    }

    /// Every control in a view, depth first.
    private static func controls(in view: NSView?) -> [NSControl] {
        guard let view else { return [] }
        var found: [NSControl] = []
        if let control = view as? NSControl { found.append(control) }
        for child in view.subviews { found += controls(in: child) }
        return found
    }

    /// The switches among `controls`, top to bottom in their window.
    private static func switches(in controls: [NSControl]) -> [NSSwitch] {
        let switches = controls.compactMap { $0 as? NSSwitch }
        return switches.sorted { $0.convert($0.bounds, to: nil).maxY > $1.convert($1.bounds, to: nil).maxY }
    }

    /// Looks through a window's accessibility elements for a control with this role and title.
    private static func findElement(role: NSAccessibility.Role, title: String, in window: NSWindow) -> Any? {
        var queue: [Any] = [window]
        var seen = 0
        while !queue.isEmpty && seen < 5_000 {
            let element = queue.removeFirst() as AnyObject
            seen += 1
            let elementRole = element.accessibilityRole?() ?? nil
            let label = (element.accessibilityLabel?() ?? nil) ?? (element.accessibilityTitle?() ?? nil)
            if elementRole == role && label == title { return element }
            queue.append(contentsOf: (element.accessibilityChildren?() ?? nil) ?? [])
        }
        return nil
    }

    /// The app is translated: in Vietnamese (`-AppleLanguages (vi)`) known strings come out in Vietnamese; in
    /// English every language has them.
    private func localizationScenario() async throws {
        let language = Bundle.main.preferredLocalizations.first ?? ""
        say("flow: note localization: running in \(language)")
        let keychainReason = AppEnvironment.policy.verdict(for: keychainPath + "/login.keychain-db").message
        let caches = await JunkFinder(homePath: home).find().first { $0.id == "caches" }?.title
        if language == "vi" {
            let checks: [(String?, String)] = [
                (ContentTab.files.label, "Tệp lớn nhất"),
                (String(localized: "Move to Trash"), "Chuyển vào Thùng rác"),
                (String(localized: "Smart Clean"), "Dọn dẹp thông minh"),
                (AgeFilter.month.label, "Cũ hơn 30 ngày"),
                (keychainReason, "Chuỗi khóa lưu mật khẩu của bạn."),
                (caches, "Bộ nhớ đệm ứng dụng"),
            ]
            for (shown, wanted) in checks {
                try expect(shown == wanted, "\"\(shown ?? "nil")\" should be \"\(wanted)\"")
            }
        } else {
            try expect(ContentTab.files.label == "Biggest Files", "English shows \(ContentTab.files.label)")
            try expect(keychainReason == "Keychains hold your passwords.", "English shows \(keychainReason ?? "nil")")
            let keys = ["Biggest Files", "Move to Trash", "Smart Clean", "Keychains hold your passwords.", "App caches", "Can be freed"]
            for code in ["vi", "es", "de", "fr", "ja", "zh-Hans"] {
                guard let path = Bundle.main.path(forResource: code, ofType: "lproj"), let bundle = Bundle(path: path) else {
                    throw Failure("there is no \(code).lproj in the app")
                }
                for key in keys where bundle.localizedString(forKey: key, value: "\u{1}", table: nil) == "\u{1}" {
                    throw Failure("\(code) has no translation of \"\(key)\"")
                }
            }
        }
    }

    // MARK: Helpers

    private func say(_ line: String) {
        print(line)
        fflush(stdout)
    }

    /// The space the files under `path` take, added up directly from the disk.
    private static func allocatedBytes(under path: String) -> Int64 {
        let keys: [URLResourceKey] = [.totalFileAllocatedSizeKey, .isRegularFileKey]
        guard let walker = FileManager.default.enumerator(at: URL(fileURLWithPath: path), includingPropertiesForKeys: keys)
        else { return 0 }
        var total: Int64 = 0
        for case let url as URL in walker {
            guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else { continue }
            total += Int64(values.totalFileAllocatedSize ?? 0)
        }
        return total
    }
}
