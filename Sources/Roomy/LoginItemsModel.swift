import AppKit
import Observation
import RoomyCore

/// State for the Login Items tab of the Uninstaller: what starts with the Mac, and turning off your own launch agents.
@MainActor
@Observable
final class LoginItemsModel {
    private(set) var items: [LaunchItem] = []
    private(set) var isLoading = false
    private(set) var loaded = false
    /// The item being turned off.
    private(set) var turningOff: String?
    /// What happened to the last item turned off.
    private(set) var lastResult: CleanupResult?
    private(set) var lastTitle: String?

    @ObservationIgnored var onRemoved: (([String]) -> Void)?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored let finder = LoginItemFinder(homePath: AppEnvironment.home, sharedLibrary: AppEnvironment.sharedLibrary,
                                                     policy: AppEnvironment.policy)
    @ObservationIgnored let control: any LaunchControlling = AppEnvironment.launchControl

    var userItems: [LaunchItem] { items.filter { $0.domain == .userAgent } }
    var sharedItems: [LaunchItem] { items.filter { $0.domain == .systemAgent || $0.domain == .systemDaemon } }
    var appItems: [LaunchItem] { items.filter { $0.domain == .appManaged } }

    func refusal(for item: LaunchItem) -> String? { finder.refusal(for: item) }

    /// Forgets what was read, so the tab reads again when it is next shown.
    func reset() {
        guard turningOff == nil else { return }
        task?.cancel()
        loaded = false
        isLoading = false
        lastResult = nil
    }

    /// Reads the launch agents and daemons, and the helpers of `installed` apps.
    func load(installed: [InstalledApp]) {
        task?.cancel()
        isLoading = true
        let finder = finder, control = control
        task = Task {
            let found = await Task.detached { finder.find(installed: installed, control: control) }.value
            guard !Task.isCancelled else { return }
            self.items = found
            self.isLoading = false
            self.loaded = true
        }
    }

    /// Stops the agent and moves its plist to the Trash, after the person confirmed.
    func turnOff(_ item: LaunchItem) {
        guard turningOff == nil else { return }
        turningOff = item.id
        lastResult = nil
        let finder = finder, control = control
        Task {
            let result = await Task.detached { finder.turnOff(item, control: control, cleanup: AppEnvironment.cleanupService(.loginItems)) }.value
            // Let the row's spinner be seen before it slides away.
            try? await Task.sleep(for: .milliseconds(300))
            self.turningOff = nil
            self.lastResult = result
            self.lastTitle = item.title
            if result.succeeded {
                self.items.removeAll { $0.id == item.id }
                self.onRemoved?([result.path])
            }
        }
    }

    func dismissResult() {
        lastResult = nil
    }

    /// System Settings > General > Login Items, where items that need an administrator or that apps manage are
    /// turned off.
    func openLoginItemsSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }

    func reveal(_ path: String) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }
}
