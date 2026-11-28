import Foundation

/// What RoomyDisk freed over time, worked out from the cleanup history: the total, a total for each month, and the
/// cleans newest first. Only items that went to the Trash count; failed ones are left out.
public struct SpaceFreedHistory: Sendable, Equatable {
    /// One clean: when, by which tool, and what went to the Trash.
    public struct Entry: Sendable, Equatable, Identifiable {
        public let id: Int
        public let date: Date
        public let tool: CleanupTool?
        public let items: [CleanupResult]

        public var freedBytes: Int64 { items.reduce(0) { $0 + $1.bytes } }
    }

    /// The space freed in one calendar month.
    public struct Month: Sendable, Equatable, Identifiable {
        public var id: Date { start }
        public let start: Date
        public let freedBytes: Int64
    }

    /// The space one tool freed, over all cleans.
    public struct ToolTotal: Sendable, Equatable, Identifiable {
        public var id: String { tool?.rawValue ?? "" }
        public let tool: CleanupTool?
        public let freedBytes: Int64
        public let cleans: Int
    }

    /// Newest first.
    public let entries: [Entry]
    /// The last `monthCount` months, oldest first, including months where nothing was freed.
    public let months: [Month]

    public var freedBytes: Int64 { entries.reduce(0) { $0 + $1.freedBytes } }
    public var itemCount: Int { entries.reduce(0) { $0 + $1.items.count } }

    /// The tools that freed something, most first.
    public var tools: [ToolTotal] {
        var byTool: [String: ToolTotal] = [:]
        for entry in entries {
            let key = entry.tool?.rawValue ?? ""
            let old = byTool[key]
            byTool[key] = ToolTotal(tool: entry.tool, freedBytes: (old?.freedBytes ?? 0) + entry.freedBytes, cleans: (old?.cleans ?? 0) + 1)
        }
        return byTool.values.sorted { $0.freedBytes != $1.freedBytes ? $0.freedBytes > $1.freedBytes : $0.id < $1.id }
    }

    /// The cleans of one tool, newest first.
    public func entries(of tool: CleanupTool?) -> [Entry] {
        entries.filter { $0.tool == tool }
    }

    public init(reports: [CleanupReport], now: Date = Date(), monthCount: Int = 12, calendar: Calendar = .current) {
        var entries: [Entry] = []
        for (index, report) in reports.enumerated() {
            let items = report.succeeded.filter { $0.bytes > 0 || $0.trashedTo != nil }
            guard !items.isEmpty else { continue }
            entries.append(Entry(id: index, date: report.date, tool: report.tool, items: items))
        }
        entries.sort { $0.date != $1.date ? $0.date > $1.date : $0.id > $1.id }
        self.entries = entries

        var months: [Month] = []
        let thisMonth = calendar.dateInterval(of: .month, for: now)?.start ?? now
        for back in stride(from: monthCount - 1, through: 0, by: -1) {
            guard let start = calendar.date(byAdding: .month, value: -back, to: thisMonth),
                  let end = calendar.date(byAdding: .month, value: 1, to: start) else { continue }
            let bytes = entries.filter { $0.date >= start && $0.date < end }.reduce(0) { $0 + $1.freedBytes }
            months.append(Month(start: start, freedBytes: bytes))
        }
        self.months = months
    }

    /// The history file read and summed up.
    public init(history: CleanupHistory, now: Date = Date()) {
        self.init(reports: history.load(), now: now)
    }
}
