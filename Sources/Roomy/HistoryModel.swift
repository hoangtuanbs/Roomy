import AppKit
import Observation
import RoomyCore
import SwiftUI

/// State for the Space Freed history: the cleanup history read and summed up, how it is listed, and which cleans
/// are opened up.
@MainActor
@Observable
final class HistoryModel {
    enum Grouping: String, CaseIterable, Identifiable {
        case date, tool
        var id: String { rawValue }

        var label: String {
            switch self {
            case .date: return String(localized: "By Date")
            case .tool: return String(localized: "By Tool")
            }
        }
    }

    private(set) var history = SpaceFreedHistory(reports: [])
    private(set) var loaded = false
    private(set) var isLoading = false
    var grouping: Grouping = .date
    var expanded: Set<String> = []
    /// The Trash locations that were still there when the history was read.
    private(set) var stillInTrash: Set<String> = []

    /// Reads the history file again, off the main thread.
    func load() {
        guard !isLoading else { return }
        isLoading = true
        let file = AppEnvironment.history
        Task.detached {
            let reports = file?.load() ?? []
            let history = SpaceFreedHistory(reports: reports)
            let inTrash = Set(history.entries.flatMap(\.items).compactMap(\.trashedTo)
                .filter { FileManager.default.fileExists(atPath: $0) })
            await self.finish(history, inTrash: inTrash)
        }
    }

    /// Shows these cleans instead of the history file. The screenshot tour uses it, so it never needs real cleans.
    func show(_ reports: [CleanupReport]) {
        finish(SpaceFreedHistory(reports: reports), inTrash: [])
    }

    private func finish(_ history: SpaceFreedHistory, inTrash: Set<String>) {
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        withAnimation(Motion.smooth.unless(reduceMotion)) {
            self.history = history
            stillInTrash = inTrash
            loaded = true
            isLoading = false
        }
    }

    func toggle(_ id: String) {
        if expanded.contains(id) { expanded.remove(id) } else { expanded.insert(id) }
    }

    /// True when the item is still in the Trash where the clean put it.
    func isInTrash(_ item: CleanupResult) -> Bool {
        item.trashedTo.map(stillInTrash.contains) ?? false
    }

    /// Shows the item in the Trash in Finder, where Put Back brings it home.
    func showInTrash(_ item: CleanupResult) {
        guard let trash = item.trashedTo, FileManager.default.fileExists(atPath: trash) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: trash)])
    }

    struct Day: Identifiable {
        var id: Date { day }
        let day: Date
        var entries: [SpaceFreedHistory.Entry]
    }

    /// The cleans grouped by day, newest first.
    var days: [Day] {
        let calendar = Calendar.current
        var result: [Day] = []
        for entry in history.entries {
            let day = calendar.startOfDay(for: entry.date)
            if result.last?.day == day {
                result[result.count - 1].entries.append(entry)
            } else {
                result.append(Day(day: day, entries: [entry]))
            }
        }
        return result
    }

    static func dayTitle(_ day: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(day) { return String(localized: "Today") }
        if calendar.isDateInYesterday(day) { return String(localized: "Yesterday") }
        return day.formatted(date: .complete, time: .omitted)
    }
}

/// The name, symbol and colours of each tool in the history.
extension Optional where Wrapped == CleanupTool {
    var title: String {
        switch self {
        case .smartClean?: return String(localized: "Smart Clean")
        case .duplicates?: return String(localized: "Duplicates")
        case .uninstaller?: return String(localized: "Uninstaller")
        case .spaceHunters?: return String(localized: "Space Hunters")
        case .review?: return String(localized: "Review and Clean")
        case .quickClean?: return String(localized: "Quick Clean")
        case .compress?: return String(localized: "Compress")
        case .loginItems?: return String(localized: "Login Items")
        case .shortcuts?: return String(localized: "Shortcuts")
        case .commandLine?: return String(localized: "Command Line")
        case nil: return String(localized: "Earlier cleans")
        }
    }

    var symbol: String {
        switch self {
        case .smartClean?: return "sparkles"
        case .duplicates?: return "doc.on.doc.fill"
        case .uninstaller?: return "xmark.bin.fill"
        case .spaceHunters?: return "scope"
        case .review?: return "tray.full.fill"
        case .quickClean?: return "bolt.fill"
        case .compress?: return "archivebox.fill"
        case .loginItems?: return "power"
        case .shortcuts?: return "square.2.layers.3d.fill"
        case .commandLine?: return "terminal.fill"
        case nil: return "clock.fill"
        }
    }

    var gradient: LinearGradient {
        switch self {
        case .smartClean?, .quickClean?: return .smartClean
        case .duplicates?: return .duplicates
        case .uninstaller?, .loginItems?: return .uninstaller
        case .spaceHunters?: return .spaceHunters
        case .review?: return .scan
        case .compress?: return .tile(FileCategory.archive.color)
        case .shortcuts?: return .tile(FileCategory.video.color)
        case .commandLine?: return .tile(Color(red: 0.36, green: 0.40, blue: 0.48))
        case nil: return .tile(FileCategory.other.color)
        }
    }

    var color: Color {
        switch self {
        case .smartClean?, .quickClean?: return Color(red: 0.42, green: 0.48, blue: 0.86)
        case .duplicates?: return Color(red: 0.20, green: 0.62, blue: 0.78)
        case .uninstaller?, .loginItems?: return Color(red: 0.93, green: 0.46, blue: 0.38)
        case .spaceHunters?: return Color(red: 0.95, green: 0.62, blue: 0.25)
        case .review?: return FileCategory.folder.color
        case .compress?: return FileCategory.archive.color
        case .shortcuts?: return FileCategory.video.color
        case .commandLine?: return Color(red: 0.36, green: 0.40, blue: 0.48)
        case nil: return FileCategory.other.color
        }
    }
}

/// The green-to-blue gradient used for the Space Freed history.
extension LinearGradient {
    static let history = LinearGradient(
        colors: [Color(red: 0.26, green: 0.75, blue: 0.56), Color(red: 0.22, green: 0.58, blue: 0.86)],
        startPoint: .topLeading, endPoint: .bottomTrailing
    )
}
