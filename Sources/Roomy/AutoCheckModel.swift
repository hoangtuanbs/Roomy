import AppKit
import IOKit.ps
import Observation
import RoomyCore
import SwiftUI

/// The settings for the background junk check, in UserDefaults under the keys the Settings window uses.
enum AutoCheckSettings {
    static let intervalKey = "autoCheckInterval"
    static let showAmountKey = "menuBarShowsReclaimable"
    static let amountThresholdKey = "menuBarReclaimableThresholdGB"
    static let notifyKey = "reclaimableNoticeEnabled"
    static let notifyThresholdKey = "reclaimableNoticeThresholdGB"
    static let lastNoticeKey = "reclaimableLastNotice"
    static let summaryKey = "autoCheckSummary"

    static var interval: AutoCheckInterval {
        UserDefaults.standard.string(forKey: intervalKey).flatMap(AutoCheckInterval.init(rawValue:)) ?? .sixHours
    }
}

/// Looks for junk now and then while RoomyDisk runs, and lets the menu bar move the safe part to the Trash.
/// It never cleans on its own: only the Quick Clean button, after a confirmation, moves anything.
@MainActor
@Observable
final class AutoCheckModel {
    enum Phase: Equatable {
        case idle
        case confirming
        case cleaning
        case done
    }

    private(set) var phase: Phase = .idle
    private(set) var isChecking = false
    /// The last check's result, kept across launches.
    private(set) var summary: JunkSummary?
    /// What the last check found in this run. Quick Clean needs it; after a relaunch it is empty until the next check.
    private(set) var findings: [JunkFinding] = []
    private(set) var cleanTotal = 0
    private(set) var cleanedCount = 0
    private(set) var cleanedBytes: Int64 = 0
    private(set) var report: CleanupReport?

    /// Called with the paths that went to the Trash, so the main scan and Smart Clean can drop them.
    @ObservationIgnored var onRemoved: (([String]) -> Void)?
    @ObservationIgnored private var checkTask: Task<Void, Never>?
    @ObservationIgnored private var timer: Task<Void, Never>?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []

    init() {
        if let data = UserDefaults.standard.data(forKey: AutoCheckSettings.summaryKey) {
            summary = try? JSONDecoder().decode(JunkSummary.self, from: data)
        }
    }

    var reclaimable: Int64 { summary?.totalBytes ?? 0 }
    var quickCleanItems: [JunkItem] { JunkSummary.safeItems(findings) }
    var quickCleanBytes: Int64 { quickCleanItems.reduce(0) { $0 + $1.bytes } }
    var cleanFraction: Double { cleanTotal == 0 ? 0 : Double(cleanedCount) / Double(cleanTotal) }

    // MARK: Schedule

    /// Starts the periodic checks, a check shortly after launch, and one after each wake from sleep.
    func start() {
        guard observers.isEmpty else { return }
        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { _ in
            Task { @MainActor in self.checkSoonIfStale() }
        })
        observers.append(center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { _ in
            Task { @MainActor in self.cancelCheck() }
        })
        checkSoonIfStale()
    }

    /// Plans the next check again, such as after the interval changed in Settings.
    func reschedule() {
        timer?.cancel()
        let interval = AutoCheckSettings.interval
        guard let next = AutoCheckSchedule.nextCheck(after: summary?.date, interval: interval, now: Date()) else { return }
        wait(until: next)
    }

    private func checkSoonIfStale() {
        timer?.cancel()
        let interval = AutoCheckSettings.interval
        if AutoCheckSchedule.shouldCheckAfterWake(lastCheck: summary?.date, interval: interval, now: Date()) {
            wait(until: Date().addingTimeInterval(AutoCheckSchedule.settleDelay))
        } else {
            reschedule()
        }
    }

    private func wait(until date: Date) {
        timer = Task {
            let seconds = max(1, date.timeIntervalSinceNow)
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            if AutoCheckSchedule.powerAllows(Self.readPower()) {
                self.check()
            } else {
                // Try again in an hour; the power may be back by then.
                self.wait(until: Date().addingTimeInterval(3600))
            }
        }
    }

    // MARK: Checking

    /// Looks for junk at low priority. Only the known junk places are measured, never the whole disk.
    func check() {
        guard !isChecking, phase != .cleaning else { return }
        isChecking = true
        let running = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        let finder = JunkFinder(skippedCacheNames: running)
        checkTask = Task.detached(priority: .background) {
            let found = await finder.find()
            let cancelled = Task.isCancelled
            await self.finishCheck(found, cancelled: cancelled)
        }
    }

    func cancelCheck() {
        checkTask?.cancel()
    }

    private func finishCheck(_ found: [JunkFinding], cancelled: Bool) {
        checkTask = nil
        isChecking = false
        guard !cancelled else { return }
        // A clean that started meanwhile works from the earlier result; keep it until it ends.
        guard phase != .cleaning else { return }
        findings = found
        let fresh = JunkSummary(findings: found, date: Date())
        withAnimation(Motion.spring.unless(NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)) { summary = fresh }
        save()
        noticeIfWorthIt(fresh)
        reschedule()
    }

    private func save() {
        guard let summary, let data = try? JSONEncoder().encode(summary) else { return }
        UserDefaults.standard.set(data, forKey: AutoCheckSettings.summaryKey)
    }

    // MARK: Quick Clean

    func askToClean() {
        guard phase == .idle || phase == .done, !quickCleanItems.isEmpty else { return }
        phase = .confirming
    }

    func cancelClean() {
        if phase == .confirming { phase = .idle }
    }

    /// Moves the safe items of the last check to the Trash through the safety policy.
    func clean() {
        guard phase == .confirming else { return }
        let items = quickCleanItems
        guard !items.isEmpty else { phase = .idle; return }
        let sizes = Dictionary(items.map { ($0.path, $0.bytes) }, uniquingKeysWith: { first, _ in first })
        let paths = items.map(\.path)
        cleanTotal = items.count
        cleanedCount = 0
        cleanedBytes = 0
        report = nil
        phase = .cleaning

        Task.detached {
            let service = CleanupService()
            let plan = service.plan(paths: paths, sizeOf: { sizes[$0] ?? 0 })
            let report = service.execute(plan) { result in
                Task { @MainActor in self.advance(result) }
            }
            try? await Task.sleep(for: .milliseconds(450))
            await self.finishClean(report)
        }
    }

    private func advance(_ result: CleanupResult) {
        cleanedCount += 1
        if result.succeeded { cleanedBytes += result.bytes }
    }

    private func finishClean(_ report: CleanupReport) {
        self.report = report
        cleanedCount = cleanTotal
        cleanedBytes = report.freedBytes
        let removed = report.succeeded.map(\.path)
        drop(removed)
        onRemoved?(removed)
        phase = .done
    }

    /// Takes paths that went to the Trash elsewhere (such as Smart Clean) off the last result.
    func drop(_ removed: [String]) {
        guard !removed.isEmpty else { return }
        let set = Set(removed)
        let bytes = JunkSummary.bytesByCategory(of: set, in: findings)
        findings = findings.compactMap { $0.removing(set) }
        guard let summary, !bytes.isEmpty else { return }
        self.summary = summary.subtracting(bytes)
        save()
    }

    /// Back to the summary after the celebration.
    func dismissResult() {
        if phase == .done { phase = .idle }
    }

    // MARK: Notice

    private func noticeIfWorthIt(_ summary: JunkSummary) {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: AutoCheckSettings.notifyKey) as? Bool ?? true else { return }
        let gigabytes = defaults.object(forKey: AutoCheckSettings.notifyThresholdKey) as? Int ?? 5
        let last = (defaults.object(forKey: AutoCheckSettings.lastNoticeKey) as? Double).map(Date.init(timeIntervalSince1970:))
        let now = Date()
        guard ReclaimableNotice.shouldNotify(reclaimable: summary.totalBytes, threshold: Int64(gigabytes) * 1_000_000_000,
                                             lastNotified: last, now: now) else { return }
        Task { await LowSpaceNotifier.postReclaimable(summary, at: now) }
    }

    // MARK: Power

    /// Whether the Mac runs on its battery, how full it is, and whether Low Power Mode is on.
    nonisolated static func readPower() -> PowerState {
        let lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
        var state = PowerState(isOnBattery: false, batteryPercent: nil, isLowPowerMode: lowPower)
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return state }
        for source in sources {
            guard let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                  description[kIOPSTypeKey] as? String == kIOPSInternalBatteryType else { continue }
            state.isOnBattery = description[kIOPSPowerSourceStateKey] as? String == kIOPSBatteryPowerValue
            if let current = description[kIOPSCurrentCapacityKey] as? Int,
               let maximum = description[kIOPSMaxCapacityKey] as? Int, maximum > 0 {
                state.batteryPercent = current * 100 / maximum
            }
        }
        return state
    }
}
