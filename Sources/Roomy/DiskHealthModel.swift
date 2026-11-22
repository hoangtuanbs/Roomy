import AppKit
import Observation
import RoomyCore
import SwiftUI
import UserNotifications

/// Reads the health of every disk: when Disk Health opens, when the menu bar popover opens and the last read is
/// old, and every few hours while RoomyDisk runs. Reading only looks; it never changes a disk.
@MainActor
@Observable
final class DiskHealthModel {
    enum Phase: Equatable { case idle, reading, ready }

    private(set) var phase: Phase = .idle
    private(set) var reports: [DiskHealthReport] = []
    private(set) var readAt: Date?
    private var loop: Task<Void, Never>?

    var isBusy: Bool { phase == .reading }

    init() {
        loop = Task { [weak self] in
            try? await Task.sleep(for: .seconds(15))
            while !Task.isCancelled {
                self?.refresh()
                try? await Task.sleep(for: .seconds(6 * 3600))
            }
        }
    }

    /// Reads every disk again, off the main thread. Each command gets 10 seconds.
    func refresh() {
        guard !isBusy else { return }
        phase = .reading
        Task {
            let fresh = await DiskHealthReader.readAll(timeout: 10)
            let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            withAnimation(Motion.smooth.unless(reduceMotion)) {
                reports = fresh
                readAt = Date()
                phase = .ready
            }
            DiskHealthNotifier.check(fresh)
        }
    }

    /// Reads again when the last read is more than an hour old.
    func refreshIfStale() {
        guard let readAt else { return refresh() }
        if Date().timeIntervalSince(readAt) > 3600 { refresh() }
    }

    /// The verdict for the disk that holds the volume mounted at `path`, nil before the first read.
    func verdict(forVolume path: String) -> DiskHealthVerdict? {
        reports.first { $0.volumePaths.contains(path) }?.verdict
    }

    /// The worst verdict of all disks, for the summary: failing, then warning, then good, then unknown.
    var overall: DiskHealthVerdict? {
        let verdicts = reports.map(\.verdict)
        for verdict in [DiskHealthVerdict.failing, .warning, .good, .unknown] where verdicts.contains(verdict) {
            return verdict
        }
        return nil
    }
}

/// Posts "a disk is failing" once for each disk that turns Failing.
@MainActor
enum DiskHealthNotifier {
    static let announcedKey = "diskHealthAnnounced"
    nonisolated static let identifier = "diskFailing"

    static func check(_ reports: [DiskHealthReport]) {
        let defaults = UserDefaults.standard
        let before = Set(defaults.stringArray(forKey: announcedKey) ?? [])
        let decision = DiskHealthAlert.decide(reports, alreadyAnnounced: before)
        defaults.set(Array(decision.announced).sorted(), forKey: announcedKey)
        guard let disk = decision.announce.first else { return }
        Task {
            guard await LowSpaceNotifier.requestPermission() else { return }
            let content = UNMutableNotificationContent()
            content.title = String(format: String(localized: "%@ is failing"), disk.name)
            content.body = String(localized: "The disk reports that it is failing. Back up now with Time Machine. Click for details.")
            content.sound = .default
            try? await UNUserNotificationCenter.current().add(
                UNNotificationRequest(identifier: identifier, content: content, trigger: nil))
        }
    }
}

extension DiskHealthVerdict {
    var color: Color {
        switch self {
        case .good: return Color(red: 0.24, green: 0.70, blue: 0.42)
        case .warning: return Color(red: 0.95, green: 0.62, blue: 0.18)
        case .failing: return Color(red: 0.88, green: 0.27, blue: 0.30)
        case .unknown: return Color(red: 0.56, green: 0.58, blue: 0.64)
        }
    }

    var symbol: String {
        switch self {
        case .good: return "checkmark.seal.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .failing: return "xmark.octagon.fill"
        case .unknown: return "questionmark.circle.fill"
        }
    }
}

/// The green-to-teal gradient used for Disk Health.
extension LinearGradient {
    static let diskHealth = LinearGradient(
        colors: [Color(red: 0.24, green: 0.72, blue: 0.45), Color(red: 0.20, green: 0.62, blue: 0.75)],
        startPoint: .topLeading, endPoint: .bottomTrailing
    )
}
