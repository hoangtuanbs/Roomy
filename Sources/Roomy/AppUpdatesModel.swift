import AppKit
import Observation
import RoomyCore

/// State for the Updates tab of the Uninstaller: which apps have a newer version. Checking asks each app's own
/// update feed only when you press Check, and nothing is ever downloaded or installed by RoomyDisk.
@MainActor
@Observable
final class AppUpdatesModel {
    /// Apps with an update feed or from the App Store, by name.
    private(set) var apps: [InstalledApp] = []
    private(set) var statuses: [String: UpdateStatus] = [:]
    private(set) var isChecking = false
    private(set) var checkedAt: Date?

    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored let checker = UpdateChecker(fetcher: AppEnvironment.appcastFetcher)

    var checkedCount: Int { apps.filter { statuses[$0.path] != nil }.count }
    var checkFraction: Double { apps.isEmpty ? 0 : Double(checkedCount) / Double(apps.count) }

    var available: [(app: InstalledApp, item: AppcastItem)] {
        apps.compactMap { app in
            if case .available(let item)? = statuses[app.path] { return (app, item) }
            return nil
        }
    }
    var appStoreApps: [InstalledApp] { apps.filter(\.isFromAppStore) }
    var upToDateCount: Int { apps.filter { statuses[$0.path] == .upToDate }.count }
    var failed: [(app: InstalledApp, reason: String)] {
        apps.compactMap { app in
            if case .failed(let reason)? = statuses[app.path] { return (app, reason) }
            return nil
        }
    }
    /// Apps with a feed that were not checked yet.
    var unchecked: [InstalledApp] { apps.filter { !$0.isFromAppStore && statuses[$0.path] == nil } }

    /// Takes the installed apps; keeps what was checked for apps that are still there.
    func prepare(installed: [InstalledApp]) {
        apps = UpdateChecker.checkable(installed).sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        let paths = Set(apps.map(\.path))
        statuses = statuses.filter { paths.contains($0.key) }
        for app in apps where app.isFromAppStore { statuses[app.path] = .appStore }
    }

    /// Asks each app's update feed for its newest version.
    func check() {
        guard !isChecking else { return }
        isChecking = true
        for app in apps where !app.isFromAppStore { statuses[app.path] = nil }
        let targets = apps.filter { !$0.isFromAppStore }
        let checker = checker
        task = Task {
            await checker.checkAll(targets) { path, status in
                await MainActor.run { self.statuses[path] = status }
            }
            self.isChecking = false
            self.checkedAt = Date()
        }
    }

    func cancel() {
        task?.cancel()
        isChecking = false
    }

    /// Opens the app, so its own updater can install the update.
    func open(_ app: InstalledApp) {
        NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: app.path), configuration: NSWorkspace.OpenConfiguration())
    }

    /// Opens the update's download (or its page) in the browser.
    func openDownload(_ item: AppcastItem) {
        guard let url = item.downloadURL ?? item.releaseNotesURL, ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return }
        NSWorkspace.shared.open(url)
    }

    func openReleaseNotes(_ item: AppcastItem) {
        guard let url = item.releaseNotesURL, ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return }
        NSWorkspace.shared.open(url)
    }

    /// The App Store's Updates page, where App Store apps are updated.
    func openAppStore() {
        if let url = URL(string: "macappstore://showUpdatesPage") { NSWorkspace.shared.open(url) }
    }
}
