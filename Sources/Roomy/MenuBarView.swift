import AppKit
import RoomyCore
import SwiftUI

extension Notification.Name {
    /// Posted when the user clicks a RoomyDisk notification. The menu bar label opens the main window.
    static let roomyShowMain = Notification.Name("roomyShowMain")
}

/// Whether the menu bar icon is shown. On by default.
enum MenuBarSettings {
    static let key = "showInMenuBar"
    static var isShown: Bool { UserDefaults.standard.object(forKey: key) as? Bool ?? true }
}

/// The menu bar icon. It stays alive while the menu bar item is shown, so it can open the main window.
struct MenuBarLabel: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Image(systemName: "internaldrive")
            .onReceive(NotificationCenter.default.publisher(for: .roomyShowMain)) { _ in
                openWindow(id: "main")
                NSApp.activate(ignoringOtherApps: true)
            }
    }
}

/// The popover under the menu bar icon: the disks, and a few actions.
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
                MenuBarDiskRow(disk: disk)
                    .transition(.opacity.combined(with: .scale(scale: 0.96)))
            }
            Divider()
            MenuBarAction(title: "Open RoomyDisk", symbol: "macwindow") { openMain() }
            MenuBarAction(title: "Smart Clean…", symbol: "sparkles") {
                model.openSmartClean()
                openMain()
            }
            Divider()
            MenuBarAction(title: "Quit", symbol: "power") { NSApplication.shared.terminate(nil) }
        }
        .padding(14)
        .frame(width: 290)
        .onAppear { disks.refresh() }
    }

    private func openMain() {
        openWindow(id: "main")
        NSApp.activate(ignoringOtherApps: true)
    }
}

/// One disk: its name, free space, and a bar of how much is used.
struct MenuBarDiskRow: View {
    let disk: MenuBarDisk

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
