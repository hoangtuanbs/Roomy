import SwiftUI

/// The Settings window: the menu bar icon and the low-space alert.
struct AlertSettingsView: View {
    @AppStorage(MenuBarSettings.key) private var showInMenuBar = true
    @AppStorage(LowSpaceNotifier.enabledKey) private var alertEnabled = true
    @AppStorage(LowSpaceNotifier.thresholdKey) private var thresholdGB = 10
    @State private var permissionDenied = false

    var body: some View {
        Form {
            Section {
                Toggle("Show in menu bar", isOn: $showInMenuBar)
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
