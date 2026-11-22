import Foundation

/// How often RoomyDisk looks for junk on its own while it runs.
public enum AutoCheckInterval: String, CaseIterable, Sendable, Identifiable {
    case off, hourly, sixHours, daily

    public var id: String { rawValue }

    /// Seconds between checks, or nil when checks are off.
    public var seconds: TimeInterval? {
        switch self {
        case .off: return nil
        case .hourly: return 3600
        case .sixHours: return 6 * 3600
        case .daily: return 24 * 3600
        }
    }

    public var title: String {
        switch self {
        case .off: return String(localized: "Off")
        case .hourly: return String(localized: "Every hour")
        case .sixHours: return String(localized: "Every 6 hours")
        case .daily: return String(localized: "Once a day")
        }
    }
}

/// What the computer runs on, for deciding whether a background check may run now.
public struct PowerState: Sendable, Equatable {
    public var isOnBattery: Bool
    /// 0 to 100, or nil when there is no battery or it cannot be read.
    public var batteryPercent: Int?
    public var isLowPowerMode: Bool

    public init(isOnBattery: Bool, batteryPercent: Int?, isLowPowerMode: Bool) {
        self.isOnBattery = isOnBattery
        self.batteryPercent = batteryPercent
        self.isLowPowerMode = isLowPowerMode
    }
}

/// When the background junk check runs. Every rule here is a plain function so it can be tested.
public enum AutoCheckSchedule {
    /// Wait this long after launch or wake before checking, so RoomyDisk doesn't add to the busy moment.
    public static let settleDelay: TimeInterval = 60
    /// After launch or wake, skip the check when one finished this recently.
    public static let recentWindow: TimeInterval = 30 * 60
    /// Below this battery level (on battery), background checks wait.
    public static let minimumBatteryPercent = 20

    /// When the next periodic check is due, or nil when checks are off. Never earlier than `now`. A last check in
    /// the future (the clock went back) counts as no check.
    public static func nextCheck(after lastCheck: Date?, interval: AutoCheckInterval, now: Date) -> Date? {
        guard let seconds = interval.seconds else { return nil }
        guard let lastCheck, lastCheck <= now else { return now }
        return max(now, lastCheck.addingTimeInterval(seconds))
    }

    /// True when a check should run shortly after launch or wake: checks are on and none ran in the last half hour.
    public static func shouldCheckAfterWake(lastCheck: Date?, interval: AutoCheckInterval, now: Date) -> Bool {
        guard interval.seconds != nil else { return false }
        guard let lastCheck, lastCheck <= now else { return true }
        return now.timeIntervalSince(lastCheck) >= recentWindow
    }

    /// True when the power state allows a background check: not in Low Power Mode, and not on a battery below 20%.
    /// A battery whose level cannot be read does not block the check.
    public static func powerAllows(_ power: PowerState) -> Bool {
        if power.isLowPowerMode { return false }
        if power.isOnBattery, let percent = power.batteryPercent, percent < minimumBatteryPercent { return false }
        return true
    }
}

extension JunkCategory: Codable {
    /// A short plural name for sentences such as "caches and logs".
    public var plainName: String {
        switch self {
        case .caches: return String(localized: "caches")
        case .logs: return String(localized: "logs")
        case .developer: return String(localized: "build data")
        case .packages: return String(localized: "package caches")
        case .installers: return String(localized: "installers")
        case .trash: return String(localized: "Trash")
        }
    }
}

/// What the last background check found that Quick Clean can move to the Trash: only the junk Smart Clean ticks
/// by itself, never the Trash or anything marked "Review first".
public struct JunkSummary: Codable, Sendable, Equatable {
    public struct Part: Codable, Sendable, Equatable {
        public let category: JunkCategory
        public let bytes: Int64

        public init(category: JunkCategory, bytes: Int64) {
            self.category = category
            self.bytes = bytes
        }
    }

    public let date: Date
    /// Largest first.
    public let parts: [Part]

    public init(date: Date, parts: [Part]) {
        self.date = date
        self.parts = parts.filter { $0.bytes > 0 }
            .sorted { $0.bytes != $1.bytes ? $0.bytes > $1.bytes : $0.category.rawValue < $1.category.rawValue }
    }

    /// The safe part of `findings`, added up per category.
    public init(findings: [JunkFinding], date: Date) {
        var totals: [JunkCategory: Int64] = [:]
        for finding in Self.safe(findings) { totals[finding.category, default: 0] += finding.bytes }
        self.init(date: date, parts: totals.map { Part(category: $0.key, bytes: $0.value) })
    }

    public var totalBytes: Int64 { parts.reduce(0) { $0 + $1.bytes } }

    /// The findings Quick Clean may move: ticked by default and not the Trash.
    public static func safe(_ findings: [JunkFinding]) -> [JunkFinding] {
        findings.filter { $0.preselected && !$0.isPermanent }
    }

    /// The items Quick Clean moves to the Trash, largest first.
    public static func safeItems(_ findings: [JunkFinding]) -> [JunkItem] {
        safe(findings).flatMap(\.items).sorted { $0.bytes > $1.bytes }
    }

    /// The bytes per category of the items in `paths`, for taking a clean off the summary.
    public static func bytesByCategory(of paths: Set<String>, in findings: [JunkFinding]) -> [JunkCategory: Int64] {
        var result: [JunkCategory: Int64] = [:]
        for finding in findings {
            for item in finding.items where paths.contains(item.path) { result[finding.category, default: 0] += item.bytes }
        }
        return result
    }

    /// Names the kinds of junk, largest first, such as "caches and logs" or "caches, logs and build data".
    /// More than three kinds end in "and more".
    public var phrase: String {
        let names = parts.map(\.category.plainName)
        switch names.count {
        case 0: return String(localized: "junk")
        case 1: return names[0]
        case 2, 3: return names.dropLast().joined(separator: ", ") + String(localized: " and ") + names[names.count - 1]
        default: return names.prefix(3).joined(separator: ", ") + String(localized: " and more")
        }
    }

    /// The same summary without the bytes of `removed` items, after a clean.
    public func subtracting(_ removed: [JunkCategory: Int64]) -> JunkSummary {
        JunkSummary(date: date, parts: parts.map { Part(category: $0.category, bytes: max(0, $0.bytes - (removed[$0.category] ?? 0))) })
    }
}

/// When RoomyDisk should say how much junk it can free.
public enum ReclaimableNotice {
    /// At most one notice per this interval.
    public static let repeatInterval: TimeInterval = 3 * 24 * 60 * 60

    /// True when `reclaimable` is above `threshold` and no notice was sent in the last three days. A last notice in
    /// the future (the clock went back) does not block the notice.
    public static func shouldNotify(reclaimable: Int64, threshold: Int64, lastNotified: Date?, now: Date) -> Bool {
        guard threshold > 0, reclaimable > threshold else { return false }
        guard let lastNotified else { return true }
        let elapsed = now.timeIntervalSince(lastNotified)
        return elapsed < 0 || elapsed >= repeatInterval
    }
}

public extension ByteFormat {
    /// A short size for the menu bar, such as "3.2G", "870M" or "12G".
    static func short(_ bytes: Int64) -> String {
        let units = ["B", "K", "M", "G", "T", "P"]
        var value = Double(max(0, bytes))
        var unit = 0
        while value >= 999.5 && unit < units.count - 1 {
            value /= 1000
            unit += 1
        }
        let text = value < 9.95 && unit > 0 ? String(format: "%.1f", value) : String(format: "%.0f", value)
        return text + units[unit]
    }
}
