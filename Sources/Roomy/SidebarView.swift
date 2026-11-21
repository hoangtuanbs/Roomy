import RoomyCore
import SwiftUI

struct SidebarView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let selection = Binding<String?>(
            get: { model.selectedPath },
            set: { path in
                if let path, path != model.selectedPath { model.scan(path: path) }
            }
        )

        VStack(spacing: 0) {
            SmartCleanButton()
                .padding(.horizontal, 10)
                .padding(.top, 8)
            ToolButton(title: "Duplicates", symbol: "doc.on.doc.fill", gradient: .duplicates,
                       stroke: Color(red: 0.20, green: 0.66, blue: 0.75),
                       help: "Find identical files that take up space more than once") {
                model.openDuplicates()
            }
            .padding(.horizontal, 10)
            .padding(.top, 6)
            ToolButton(title: "Uninstaller", symbol: "xmark.bin.fill", gradient: .uninstaller,
                       stroke: Color(red: 0.92, green: 0.45, blue: 0.40),
                       help: "Remove apps together with the files they leave behind") {
                model.openUninstaller()
            }
            .padding(.horizontal, 10)
            .padding(.top, 6)
            .padding(.bottom, 4)

            List(selection: selection) {
                Section("Disks") {
                    ForEach(model.volumes) { volume in
                        VolumeRow(location: volume).tag(volume.path)
                    }
                }
                Section("Folders") {
                    ForEach(model.folders) { folder in
                        Label(folder.name, systemImage: folder.symbol)
                            .tag(folder.path)
                            .contextMenu {
                                if model.isPinned(folder.path) {
                                    Button("Remove from Sidebar") { model.unpin(folder.path) }
                                }
                            }
                    }
                }
            }
            .listStyle(.sidebar)

            VStack(alignment: .leading, spacing: 10) {
                Button {
                    model.chooseFolder()
                } label: {
                    Label("Choose Folder…", systemImage: "plus.circle")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.borderless)

                if !model.hasFullDiskAccess {
                    Button {
                        model.showOnboarding = true
                    } label: {
                        Label("Full Disk Access is off", systemImage: "lock.trianglebadge.exclamationmark")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                    .buttonStyle(.borderless)
                }
            }
            .padding(12)
        }
    }
}

/// The prominent Smart Clean entry at the top of the sidebar.
private struct SmartCleanButton: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovering = false

    var body: some View {
        Button {
            model.openSmartClean()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "sparkles")
                    .symbolEffect(.bounce, value: hovering)
                Text("Smart Clean").fontWeight(.semibold)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .opacity(hovering ? 1 : 0.6)
                    .offset(x: hovering && !reduceMotion ? 2 : 0)
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(LinearGradient.smartClean))
            .shadow(color: Color(red: 0.45, green: 0.45, blue: 0.9).opacity(hovering ? 0.35 : 0.15), radius: hovering ? 6 : 3, y: 2)
            .scaleEffect(hovering && !reduceMotion ? 1.02 : 1)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Find caches, logs and leftovers that are safe to remove")
        .onHover { inside in
            withAnimation(reduceMotion ? nil : .snappy(duration: 0.2)) { hovering = inside }
        }
    }
}

/// A lighter entry below Smart Clean, such as Duplicates or the Uninstaller, with the same hover motion.
private struct ToolButton: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let title: String
    let symbol: String
    let gradient: LinearGradient
    let stroke: Color
    let help: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: symbol)
                    .foregroundStyle(gradient)
                    .symbolEffect(.bounce, value: hovering)
                Text(title).fontWeight(.semibold)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .opacity(hovering ? 1 : 0.6)
                    .offset(x: hovering && !reduceMotion ? 2 : 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(Color.primary.opacity(hovering ? 0.09 : 0.05))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(stroke.opacity(hovering ? 0.8 : 0.4), lineWidth: 1)
            )
            .scaleEffect(hovering && !reduceMotion ? 1.02 : 1)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .onHover { inside in
            withAnimation(reduceMotion ? nil : .snappy(duration: 0.2)) { hovering = inside }
        }
    }
}

private struct VolumeRow: View {
    let location: Location

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(location.name, systemImage: location.symbol)
            if let total = location.total, let available = location.available, total > 0 {
                let used = Double(total - available) / Double(total)
                SizeBar(fraction: used, color: used > 0.9 ? .red : .accentColor)
                    .padding(.leading, 26)
                Text("\(available.bytes) free of \(total.bytes)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 26)
            }
        }
        .padding(.vertical, 2)
    }
}
