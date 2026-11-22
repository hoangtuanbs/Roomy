import RoomyCore
import SwiftUI

/// The Settings window: the menu bar icon, the background junk check and the alerts.
struct AlertSettingsView: View {
    @Environment(AppModel.self) private var model
    @AppStorage(MenuBarSettings.key) private var showInMenuBar = true
    @AppStorage(AutoCheckSettings.intervalKey) private var interval = AutoCheckInterval.sixHours
    @AppStorage(AutoCheckSettings.showAmountKey) private var showAmount = true
    @AppStorage(AutoCheckSettings.amountThresholdKey) private var amountThresholdGB = 1
    @AppStorage(AutoCheckSettings.notifyKey) private var notifyReclaimable = true
    @AppStorage(AutoCheckSettings.notifyThresholdKey) private var notifyThresholdGB = 5
    @AppStorage(LowSpaceNotifier.enabledKey) private var alertEnabled = true
    @AppStorage(LowSpaceNotifier.thresholdKey) private var thresholdGB = 10
    @State private var permissionDenied = false

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
        .frame(width: 420)
        .motion(Motion.quick, value: permissionDenied)
    }
}
