import AppKit
import RoomyCore
import SwiftUI

extension Notification.Name {
    /// Posted when the user clicks a RoomyDisk notification. The menu bar label opens the main window.
    static let roomyShowMain = Notification.Name("roomyShowMain")
    /// Posted when the user clicks the "can free" notification. The menu bar label opens Smart Clean.
    static let roomyShowSmartClean = Notification.Name("roomyShowSmartClean")
    /// Posted when the user clicks the failing disk notification. The menu bar label opens Disk Health.
    static let roomyShowDiskHealth = Notification.Name("roomyShowDiskHealth")
}

/// Whether the menu bar icon is shown. On by default.
enum MenuBarSettings {
    static let key = "showInMenuBar"
    static var isShown: Bool { UserDefaults.standard.object(forKey: key) as? Bool ?? true }
}

/// The menu bar icon, with how much junk can be freed next to it when that is worth saying. It stays alive while
/// the menu bar item is shown, so it can open the main window.
struct MenuBarLabel: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @AppStorage(AutoCheckSettings.showAmountKey) private var showAmount = true
    @AppStorage(AutoCheckSettings.amountThresholdKey) private var thresholdGB = 1

    private var amount: String? {
        let bytes = model.autoCheck.reclaimable
        guard showAmount, bytes > 0, bytes >= Int64(thresholdGB) * 1_000_000_000 else { return nil }
        return ByteFormat.short(bytes)
    }

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: "internaldrive")
            if let amount {
                Text(amount).monospacedDigit()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .roomyShowMain)) { _ in
            openWindow(id: "main")
            NSApp.activate(ignoringOtherApps: true)
        }
        .onReceive(NotificationCenter.default.publisher(for: .roomyShowSmartClean)) { _ in
            openWindow(id: "main")
            NSApp.activate(ignoringOtherApps: true)
            model.openSmartClean()
        }
        .onReceive(NotificationCenter.default.publisher(for: .roomyShowDiskHealth)) { _ in
            openWindow(id: "main")
            NSApp.activate(ignoringOtherApps: true)
            model.openDiskHealth()
        }
    }
}

/// The popover under the menu bar icon: the disks, what can be freed, and a few actions.
struct MenuBarView: View {
    @Environment(AppModel.self) private var model
    @Environment(MenuBarDiskModel.self) private var disks
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if disks.disks.isEmpty {
                Text("No disks found").foregroundStyle(.secondary)
            }
            ForEach(disks.disks) { disk in
                MenuBarDiskRow(disk: disk, health: model.diskHealth.verdict(forVolume: disk.path))
                    .transition(.opacity.combined(with: .scale(scale: 0.96)))
            }
            Divider()
            MenuBarQuickClean()
            Divider()
            MenuBarAction(title: "Open RoomyDisk", symbol: "macwindow") { openMain() }
            MenuBarAction(title: "Smart Clean…", symbol: "sparkles") {
                model.openSmartClean()
                openMain()
            }
            MenuBarAction(title: "Disk Health…", symbol: "stethoscope") {
                model.openDiskHealth()
                openMain()
            }
            Divider()
            MenuBarAction(title: "Quit", symbol: "power") { NSApplication.shared.terminate(nil) }
        }
        .padding(14)
        .frame(width: 290)
        .onAppear {
            disks.refresh()
            model.diskHealth.refreshIfStale()
            if model.autoCheck.summary == nil && AutoCheckSettings.interval != .off { model.autoCheck.check() }
        }
    }

    private func openMain() {
        openWindow(id: "main")
        NSApp.activate(ignoringOtherApps: true)
    }
}

/// One disk: its name, a dot for its health, free space, and a bar of how much is used.
struct MenuBarDiskRow: View {
    let disk: MenuBarDisk
    /// The health of the physical disk under this volume, nil before it has been read.
    var health: DiskHealthVerdict?

    private var usedFraction: Double {
        guard disk.space.total > 0 else { return 0 }
        return Double(disk.space.used) / Double(disk.space.total)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label(disk.name, systemImage: disk.isStartup ? "internaldrive" : "externaldrive")
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                if let health {
                    HealthDot(verdict: health)
                }
                Spacer()
                Text("\(disk.space.available.bytes) free")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .contentTransition(.numericText(value: Double(disk.space.available)))
            }
            SizeBar(fraction: usedFraction, color: usedFraction > 0.9 ? FileCategory.video.color : FileCategory.folder.color)
            Text("\(disk.space.used.bytes) used of \(disk.space.total.bytes)")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .monospacedDigit()
                .contentTransition(.numericText(value: Double(disk.space.used)))
        }
    }
}

/// A plain menu row that highlights when hovered.
struct MenuBarAction: View {
    let title: String
    let symbol: String
    let action: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 3)
                .padding(.horizontal, 6)
                .background(RoundedRectangle(cornerRadius: 6).fill(hovered ? Color.primary.opacity(0.08) : .clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { inside in
            withAnimation(Motion.hover.unless(reduceMotion)) { hovered = inside }
        }
    }
}

/// A small dot in the colour of a disk's health, which pops in when the health is first known.
struct HealthDot: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let verdict: DiskHealthVerdict
    @State private var shown = false

    var body: some View {
        Circle()
            .fill(verdict.color)
            .frame(width: 7, height: 7)
            .scaleEffect(shown ? 1 : 0.2)
            .animation(Motion.quick.unless(reduceMotion), value: verdict)
            .onAppear {
                if reduceMotion { shown = true } else { withAnimation(Motion.bouncy) { shown = true } }
            }
            .help("Disk health: \(verdict.title)")
            .accessibilityLabel("Disk health: \(verdict.title)")
    }
}
