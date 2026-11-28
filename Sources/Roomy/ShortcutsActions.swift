import AppIntents
import AppKit
import Foundation
import RoomyCore

// Actions for the Shortcuts app. Each runs inside RoomyDisk without opening its window. Clean Junk only moves what
// Smart Clean ticks by itself, asks first, and goes through CleanupService and the safety rules like the app does.

/// Measures a folder and returns its total and biggest items as text.
struct ScanFolderIntent: AppIntent {
    static var title: LocalizedStringResource = "Scan Folder"
    static var description = IntentDescription("Measures a folder and lists the items that take the most space.")
    static var openAppWhenRun = false

    @Parameter(title: "Folder")
    var folder: IntentFile

    @Parameter(title: "Number of Items", default: 10, inclusiveRange: (1, 100))
    var count: Int

    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        var isFolder: ObjCBool = false
        guard let url = folder.fileURL, FileManager.default.fileExists(atPath: url.path, isDirectory: &isFolder),
              isFolder.boolValue else { throw ShortcutError.noFolder }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let tree = try await DiskScanner().scan(root: url.path)
        return .result(value: ShortcutText.scan(tree, top: count))
    }
}

/// The free space of the startup disk, as text.
struct GetFreeSpaceIntent: AppIntent {
    static var title: LocalizedStringResource = "Get Free Space"
    static var description = IntentDescription("Tells how much space is free on the startup disk.")
    static var openAppWhenRun = false

    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        guard let space = DiskSpace.read(forPath: AppEnvironment.home, scanned: 0) else { throw ShortcutError.noDisk }
        return .result(value: ShortcutText.freeSpace(space))
    }
}

/// How much Smart Clean's safe junk takes. Only looks.
struct FindJunkIntent: AppIntent {
    static var title: LocalizedStringResource = "Find Junk"
    static var description = IntentDescription("Measures the caches, logs and other junk Smart Clean can move to the Trash. Nothing is moved.")
    static var openAppWhenRun = false

    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let items = await ShortcutsJunk.clean(for: .shortcuts).items()
        return .result(value: ShortcutText.junk(items))
    }
}

/// Moves Smart Clean's default-ticked safe items to the Trash, after asking.
struct CleanJunkIntent: AppIntent {
    static var title: LocalizedStringResource = "Clean Junk"
    static var description = IntentDescription("Moves the caches, logs and other junk Smart Clean ticks by itself to the Trash, after you confirm. Nothing is deleted; Put Back works.")
    static var openAppWhenRun = false

    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let clean = ShortcutsJunk.clean(for: .shortcuts)
        let items = await clean.items()
        guard !items.isEmpty else { return .result(value: ShortcutText.junk([])) }
        let bytes = items.reduce(0) { $0 + $1.bytes }
        let question = String(format: String(localized: "Move %@ of caches, logs and other junk (%lld items) to the Trash?"),
                              ByteFormat.string(bytes), items.count)
        try await requestConfirmation(result: .result(dialog: IntentDialog(stringLiteral: question)))
        let report = clean.clean(items)
        return .result(value: ShortcutText.cleaned(report))
    }
}

/// Puts the actions in Shortcuts and Spotlight without setting anything up.
struct RoomyShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: FindJunkIntent(), phrases: ["Find junk with \(.applicationName)"],
                    shortTitle: "Find Junk", systemImageName: "sparkles")
        AppShortcut(intent: CleanJunkIntent(), phrases: ["Clean junk with \(.applicationName)"],
                    shortTitle: "Clean Junk", systemImageName: "trash")
        AppShortcut(intent: GetFreeSpaceIntent(), phrases: ["Get free space with \(.applicationName)"],
                    shortTitle: "Get Free Space", systemImageName: "internaldrive")
    }
}

enum ShortcutsJunk {
    /// Smart Clean's default clean, under the app's safety rules, noting `tool` in the history. Caches of open apps
    /// are left alone, as in the app.
    static func clean(for tool: CleanupTool) -> JunkClean {
        let running = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        return JunkClean(finder: JunkFinder(homePath: AppEnvironment.home, skippedCacheNames: running),
                         service: AppEnvironment.cleanupService(tool))
    }
}

enum ShortcutError: Error, CustomLocalizedStringResourceConvertible {
    case noFolder, noDisk

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .noFolder: return "Choose a folder on this Mac."
        case .noDisk: return "macOS did not say how much space is free."
        }
    }
}
