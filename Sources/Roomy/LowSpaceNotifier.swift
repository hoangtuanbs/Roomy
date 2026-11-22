import Foundation
import RoomyCore
import UserNotifications

/// Posts the low-space notification for the startup disk, at most once a day, and the "junk can be freed" notice.
/// The settings live in UserDefaults under the same keys the Settings window uses.
@MainActor
enum LowSpaceNotifier {
    static let enabledKey = "lowSpaceAlertEnabled"
    static let thresholdKey = "lowSpaceThresholdGB"
    static let lastAlertKey = "lowSpaceLastAlert"
    static let requestIdentifier = "lowSpace"
    /// Clicking this one opens Smart Clean.
    nonisolated static let reclaimableIdentifier = "reclaimable"

    static func checkStartupDisk(free: Int64) {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: enabledKey) as? Bool ?? true else { return }
        let gigabytes = defaults.object(forKey: thresholdKey) as? Int ?? 10
        let last = (defaults.object(forKey: lastAlertKey) as? Double).map(Date.init(timeIntervalSince1970:))
        let now = Date()
        guard LowSpaceAlert.shouldAlert(free: free, threshold: Int64(gigabytes) * 1_000_000_000,
                                        lastAlert: last, now: now) else { return }
        Task { await LowSpaceNotifier.post(free: free, at: now) }
    }

    /// Asks for permission to send notifications when it has not been asked yet.
    /// Returns whether notifications are allowed now.
    @discardableResult
    static func requestPermission() async -> Bool {
        let center = UNUserNotificationCenter.current()
        if await center.notificationSettings().authorizationStatus == .notDetermined {
            _ = try? await center.requestAuthorization(options: [.alert, .sound])
        }
        let status = await center.notificationSettings().authorizationStatus
        return status == .authorized || status == .provisional
    }

    private static func post(free: Int64, at date: Date) async {
        guard await requestPermission() else { return }
        let content = UNMutableNotificationContent()
        content.title = "Your disk is almost full"
        content.body = "\(ByteFormat.string(free)) free. Open RoomyDisk to free up space."
        content.sound = .default
        let request = UNNotificationRequest(identifier: requestIdentifier, content: content, trigger: nil)
        do {
            try await UNUserNotificationCenter.current().add(request)
            UserDefaults.standard.set(date.timeIntervalSince1970, forKey: lastAlertKey)
        } catch {
            // The next check tries again; nothing else to do.
        }
    }

    /// Says how much junk the last background check found, such as "RoomyDisk can free 7.4 GB of caches and logs".
    static func postReclaimable(_ summary: JunkSummary, at date: Date) async {
        guard await requestPermission() else { return }
        let content = UNMutableNotificationContent()
        content.title = "RoomyDisk can free \(ByteFormat.string(summary.totalBytes)) of \(summary.phrase)"
        content.body = "Click to see what Smart Clean found. Nothing is removed until you choose."
        let request = UNNotificationRequest(identifier: reclaimableIdentifier, content: content, trigger: nil)
        do {
            try await UNUserNotificationCenter.current().add(request)
            UserDefaults.standard.set(date.timeIntervalSince1970, forKey: AutoCheckSettings.lastNoticeKey)
        } catch {
            // The next check tries again.
        }
    }
}
