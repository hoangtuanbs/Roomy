import AppKit
import RoomyCore
import SwiftUI

/// The Settings window, in tabs: the menu bar icon, the background junk check with the alerts, and updates.
/// Each tab has its own height, so the window fits it, and its form scrolls when a translation runs long.
struct AlertSettingsView: View {
    enum Tab: String {
        case general, checks, updates
    }

    /// The chosen tab, kept between openings. The screenshot tour sets it to show each tab.
    static let tabKey = "settingsTab"
    @AppStorage(tabKey) private var tab = Tab.general

    var body: some View {
        TabView(selection: $tab) {
            GeneralSettings()
                .frame(width: 480, height: 160)
                .tabItem { Label("General", systemImage: "gearshape") }
                .tag(Tab.general)
            CheckSettings()
                .frame(width: 480, height: 370)
                .tabItem { Label("Checks & Alerts", systemImage: "bell.badge") }
                .tag(Tab.checks)
            UpdateSettings()
                .frame(width: 480, height: 160)
                .tabItem { Label("Updates", systemImage: "arrow.triangle.2.circlepath") }
                .tag(Tab.updates)
        }
    }
}

/// The menu bar icon and what it shows.
private struct GeneralSettings: View {
    @AppStorage(MenuBarSettings.key) private var showInMenuBar = true
    @AppStorage(AutoCheckSettings.showAmountKey) private var showAmount = true
    @AppStorage(AutoCheckSettings.amountThresholdKey) private var amountThresholdGB = 1

    var body: some View {
        Form {
            Section {
                Toggle("Show in menu bar", isOn: $showInMenuBar)
                Toggle("Show what can be freed next to the icon", isOn: $showAmount)
                    .disabled(!showInMenuBar)
                Picker("Show it from", selection: $amountThresholdGB) {
                    ForEach([1, 2, 5, 10], id: \.self) { Text("\($0) GB").tag($0) }
                }
                .disabled(!showInMenuBar || !showAmount)
            }
        }
        .formStyle(.grouped)
    }
}

/// The background junk check, its notice, and the low-space warning.
private struct CheckSettings: View {
    @Environment(AppModel.self) private var model
    @AppStorage(AutoCheckSettings.intervalKey) private var interval = AutoCheckInterval.sixHours
    @AppStorage(AutoCheckSettings.notifyKey) private var notifyReclaimable = true
    @AppStorage(AutoCheckSettings.notifyThresholdKey) private var notifyThresholdGB = 5
    @AppStorage(LowSpaceNotifier.enabledKey) private var alertEnabled = true
    @AppStorage(LowSpaceNotifier.thresholdKey) private var thresholdGB = 10
    @State private var permissionDenied = false

    var body: some View {
        Form {
            Section {
                Picker("Check for junk", selection: $interval) {
                    ForEach(AutoCheckInterval.allCases) { Text($0.title).tag($0) }
                }
                .onChange(of: interval) { _, _ in model.autoCheck.reschedule() }
                Toggle("Tell me when junk can be freed", isOn: $notifyReclaimable)
                    .disabled(interval == .off)
                    .onChange(of: notifyReclaimable) { _, on in
                        guard on else { return }
                        Task { permissionDenied = !(await LowSpaceNotifier.requestPermission()) }
                    }
                Picker("Tell me above", selection: $notifyThresholdGB) {
                    ForEach([2, 5, 10, 20], id: \.self) { Text("\($0) GB").tag($0) }
                }
                .disabled(interval == .off || !notifyReclaimable)
            } footer: {
                Text("RoomyDisk looks at caches and logs now and then while it runs, not on a low battery or in Low Power Mode. Nothing is removed until you press Quick Clean in the menu bar. Notices come at most every 3 days.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Section {
                Toggle("Warn when the startup disk is almost full", isOn: $alertEnabled)
                    .onChange(of: alertEnabled) { _, on in
                        guard on else { return }
                        Task { permissionDenied = !(await LowSpaceNotifier.requestPermission()) }
                    }
                Picker("Warn below", selection: $thresholdGB) {
                    ForEach([5, 10, 20, 50, 100], id: \.self) { Text("\($0) GB free").tag($0) }
                }
                .disabled(!alertEnabled)
                if permissionDenied {
                    Text("Notifications for RoomyDisk are off. Turn them on in System Settings, under Notifications.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .transition(.opacity)
                }
            }
        }
        .formStyle(.grouped)
        .motion(Motion.quick, value: permissionDenied)
    }
}

/// Automatic updates, which only a signed release build has.
private struct UpdateSettings: View {
    @ObservedObject private var updater = AppUpdater.shared

    var body: some View {
        Form {
            if updater.isAvailable {
                Section {
                    Toggle("Check for updates automatically", isOn: $updater.automaticallyChecks)
                    Button("Check Now") { updater.checkForUpdates() }
                        .disabled(!updater.canCheck)
                } footer: {
                    Text("Updates are signed and checked before they are installed.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            } else {
                Section {
                    Text("This copy of RoomyDisk doesn't look for updates. New versions are on GitHub.")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("RoomyDisk on GitHub") { NSWorkspace.shared.open(About.projectURL) }
                }
            }
        }
        .formStyle(.grouped)
    }
}
