import AppKit
import SwiftUI
import UserNotifications

@main
struct RoomyApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = AppModel()
    @State private var menuDisks = MenuBarDiskModel()
    @AppStorage(MenuBarSettings.key, store: AppEnvironment.defaults) private var showInMenuBar = true

    var body: some Scene {
        WindowGroup("RoomyDisk", id: "main") {
            ContentView()
                .environment(model)
                .frame(minWidth: 960, minHeight: 600)
        }
        .defaultSize(width: 1280, height: 800)
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("About RoomyDisk") { About.show() }
                CheckForUpdatesButton()
            }
            HelpCommands()
            CommandGroup(after: .newItem) {
                Button("Choose Folder…") { model.chooseFolder() }
                    .keyboardShortcut("o")
                Button("Rescan") { model.rescan() }
                    .keyboardShortcut("r")
                    .disabled(model.tree == nil)
                Button("Export as CSV…") { model.exportCSV(depth: 1) }
                    .keyboardShortcut("e", modifiers: [.command, .shift])
                    .disabled(model.tree == nil)
                Divider()
                Button("Smart Clean…") { model.openSmartClean() }
                    .keyboardShortcut("k", modifiers: [.command, .shift])
                Button("Find Duplicates…") { model.openDuplicates() }
                    .keyboardShortcut("d", modifiers: [.command, .shift])
                Button("Uninstall Apps…") { model.openUninstaller() }
                    .keyboardShortcut("u", modifiers: [.command, .shift])
                Button("Space Hunters…") { model.openSpaceHunters() }
                    .keyboardShortcut("h", modifiers: [.command, .shift])
                Button("Free Up Cloud Space…") { model.openCloudSpace() }
                    .keyboardShortcut("l", modifiers: [.command, .shift])
                Button("Disk Health…") { model.openDiskHealth() }
                    .keyboardShortcut("i", modifiers: [.command, .shift])
            }
            CommandGroup(after: .toolbar) {
                Button("Enclosing Folder") { model.goUp() }
                    .keyboardShortcut(.upArrow, modifiers: .command)
                Button("Quick Look") { model.toggleQuickLook() }
                    .keyboardShortcut("y")
                    .disabled(model.selection == nil)
                Divider()
                Picker("Map", selection: Binding(get: { model.mapStyle }, set: { model.mapStyle = $0 })) {
                    ForEach(MapStyle.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.inline)
            }
        }

        Window("Donate", id: "donate") {
            DonateView()
        }
        .windowResizability(.contentSize)

        MenuBarExtra(isInserted: $showInMenuBar) {
            MenuBarView()
                .environment(model)
                .environment(menuDisks)
        } label: {
            MenuBarLabel()
                .environment(model)
        }
        .menuBarExtraStyle(.window)

        Settings {
            AlertSettingsView()
                .environment(model)
        }
    }
}

struct HelpCommands: Commands {
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        // Lets a notification click open the main window when no window or menu bar icon is around.
        let _ = MainWindow.openAction = openWindow
        CommandGroup(replacing: .help) {
            Button("Email Us…") { About.emailSupport() }
            Button("Donate…") { openWindow(id: "donate") }
            Divider()
            Button("RoomyDisk on GitHub") { NSWorkspace.shared.open(About.projectURL) }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)
        MainActor.assumeIsolated { _ = AppUpdater.shared }
        UNUserNotificationCenter.current().delegate = self
    }

    // Keep running with the menu bar icon after the last window closes.
    // The flow test closes the window on purpose, to check a notification click opens a new one.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        !MenuBarSettings.isShown && !AppEnvironment.isFlowTest
    }

    /// A click on the low-space notification brings RoomyDisk forward; one on the "can free" notice opens Smart Clean,
    /// and one on the failing disk notice opens Disk Health. This works with the menu bar icon hidden too.
    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let route = Self.route(forNotification: response.notification.request.identifier)
        Task { @MainActor in MainWindow.show(route) }
        completionHandler()
    }

    /// Where a click on the notification with this identifier leads.
    static func route(forNotification identifier: String) -> MainWindow.Route {
        switch identifier {
        case LowSpaceNotifier.reclaimableIdentifier: return .smartClean
        case DiskHealthNotifier.identifier: return .diskHealth
        default: return .main
        }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }
}
