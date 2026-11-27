import AppKit
import RoomyCore
import SwiftUI

/// The sidebar column, drawn by the app itself so it looks the same on screen and in screenshots: the app's mark,
/// the tools with their coloured tiles, the disks with how full they are, the folders, and at the bottom the
/// Full Disk Access warning and Choose Folder.
struct SidebarView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var selectionSpace

    var body: some View {
        VStack(spacing: 0) {
            AppMark()
                .padding(.horizontal, Space.l)
                .padding(.top, 2)
                .padding(.bottom, Space.xs)

            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 2) {
                    SidebarSection("Tools")
                    SmartCleanRow()
                        .padding(.bottom, 2)
                    ToolRow(title: "Duplicates", symbol: "doc.on.doc.fill", gradient: .duplicates,
                            help: "Find identical files that take up space more than once") { model.openDuplicates() }
                    ToolRow(title: "Uninstaller", symbol: "xmark.bin.fill", gradient: .uninstaller,
                            help: "Remove apps together with the files they leave behind") { model.openUninstaller() }
                    ToolRow(title: "Space Hunters", symbol: "scope", gradient: .spaceHunters,
                            help: "Find old backups, downloads, Mail attachments and similar photos") { model.openSpaceHunters() }
                    ToolRow(title: "Cloud Space", symbol: "icloud.fill", gradient: .cloudSpace,
                            help: "Free space by removing downloaded copies of cloud files; they stay in the cloud") { model.openCloudSpace() }
                    ToolRow(title: "Cloud Backup", symbol: "icloud.and.arrow.up.fill", gradient: .cloudBackup,
                            help: "Move big files you haven't used for months to iCloud Drive or another cloud folder") { model.openCloudBackup() }
                    ToolRow(title: "Disk Health", symbol: "stethoscope", gradient: .diskHealth,
                            help: "See what your disks report about their own health") { model.openDiskHealth() }

                    SidebarSection("Disks")
                    ForEach(model.volumes) { volume in
                        LocationRow(location: volume, tint: Color(red: 0.52, green: 0.56, blue: 0.64),
                                    isSelected: isSelected(volume.path), isScanning: isScanning(volume.path),
                                    namespace: selectionSpace) {
                            choose(volume.path)
                        }
                    }

                    SidebarSection("Folders")
                    ForEach(model.folders) { folder in
                        LocationRow(location: folder, tint: Self.tint(for: folder.symbol),
                                    isSelected: isSelected(folder.path), isScanning: isScanning(folder.path),
                                    namespace: selectionSpace) {
                            choose(folder.path)
                        }
                        .contextMenu {
                            if model.isPinned(folder.path) {
                                Button("Remove from Sidebar") { model.unpin(folder.path) }
                            }
                        }
                        .transition(.opacity.combined(with: .move(edge: .leading)))
                    }
                    // A folder scanned from elsewhere, such as one dropped on the window, shows as the chosen row too.
                    if let path = model.selectedPath, !isListed(path) {
                        LocationRow(location: Location(path: path, name: (path as NSString).lastPathComponent, symbol: "folder"),
                                    tint: FileCategory.folder.color, isSelected: true, isScanning: isScanning(path),
                                    namespace: selectionSpace) {}
                            .transition(.opacity.combined(with: .move(edge: .leading)))
                    }
                }
                .padding(.horizontal, 10)
                .padding(.bottom, Space.m)
                .animation(Motion.spring.unless(reduceMotion), value: model.selectedPath)
                .motion(Motion.spring, value: model.folders.map(\.path))
            }

            SidebarFooter()
        }
    }

    private func choose(_ path: String) {
        if path != model.selectedPath { model.scan(path: path) }
    }

    private func isListed(_ path: String) -> Bool {
        model.volumes.contains { $0.path == path } || model.folders.contains { $0.path == path }
    }

    private func isSelected(_ path: String) -> Bool {
        model.selectedPath == path
    }

    private func isScanning(_ path: String) -> Bool {
        model.selectedPath == path && (model.state.isScanning || model.isRefreshing)
    }

    /// A colour for each kind of standard folder, as Finder's sidebar would suggest it.
    static func tint(for symbol: String) -> Color {
        switch symbol {
        case "house": return FileCategory.folder.color
        case "menubar.dock.rectangle": return FileCategory.application.color
        case "doc": return Color(red: 0.42, green: 0.55, blue: 0.85)
        case "arrow.down.circle": return FileCategory.image.color
        case "photo": return FileCategory.video.color
        case "film": return FileCategory.archive.color
        case "hammer": return FileCategory.developer.color
        default: return FileCategory.folder.color
        }
    }
}

/// The app's icon and name at the top of the sidebar.
private struct AppMark: View {
    var body: some View {
        HStack(spacing: Space.s) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .interpolation(.high)
                .frame(width: 26, height: 26)
                .shadow(color: .black.opacity(0.12), radius: 2, y: 1)
            Text(verbatim: "RoomyDisk")
                .font(.system(size: 15, weight: .bold, design: .rounded))
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }
}

private struct SidebarSection: View {
    let title: LocalizedStringKey

    init(_ title: LocalizedStringKey) {
        self.title = title
    }

    var body: some View {
        Text(title)
            .font(Typo.sectionLabel)
            .foregroundStyle(.secondary)
            .padding(.horizontal, Space.s)
            .padding(.top, Space.m)
            .padding(.bottom, 3)
            .accessibilityAddTraits(.isHeader)
    }
}

/// The hero row of the sidebar: Smart Clean on a soft gradient, with what can be freed once a check has run.
private struct SmartCleanRow: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovering = false

    var body: some View {
        let freeable = model.autoCheck.reclaimable
        Button {
            model.openSmartClean()
        } label: {
            HStack(spacing: 9) {
                IconTile(symbol: "sparkles", gradient: .smartClean, size: 24)
                    .symbolEffect(.bounce, value: hovering)
                Text("Smart Clean")
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Spacer(minLength: 4)
                if freeable > 0 {
                    Text(ByteFormat.short(freeable))
                        .font(.system(size: 11, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(.white)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(LinearGradient.smartClean))
                        .transition(.scale(scale: 0.5).combined(with: .opacity))
                } else {
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .opacity(hovering ? 1 : 0.5)
                        .offset(x: hovering && !reduceMotion ? 2 : 0)
                }
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(LinearGradient.smartClean)
                    .opacity(hovering ? 0.20 : 0.13)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(LinearGradient.smartClean.opacity(hovering ? 0.55 : 0.30), lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Find caches, logs and leftovers that are safe to remove")
        .onHover { inside in
            withAnimation(Motion.hover.unless(reduceMotion)) { hovering = inside }
        }
        .animation(Motion.bouncy.unless(reduceMotion), value: freeable)
    }
}

/// A tool in the sidebar: its coloured tile and name. It opens the tool's sheet.
private struct ToolRow: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let title: LocalizedStringKey
    let symbol: String
    let gradient: LinearGradient
    let help: LocalizedStringKey
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                IconTile(symbol: symbol, gradient: gradient, size: 22)
                    .symbolEffect(.bounce, value: hovering)
                Text(title)
                    .font(.system(size: 13))
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.primary.opacity(hovering ? 0.06 : 0))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .onHover { inside in
            withAnimation(Motion.hover.unless(reduceMotion)) { hovering = inside }
        }
    }
}

/// A disk or folder in the sidebar. The chosen one sits on a soft accent capsule that glides between rows; a disk
/// also shows how full it is.
private struct LocationRow: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let location: Location
    let tint: Color
    let isSelected: Bool
    let isScanning: Bool
    let namespace: Namespace.ID
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 9) {
                    IconTile(symbol: location.symbol, gradient: .tile(tint), size: 22)
                        .symbolEffect(.pulse, isActive: isScanning && !reduceMotion)
                    Text(location.name)
                        .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 0)
                    if isScanning {
                        ProgressView().controlSize(.mini)
                            .transition(.opacity)
                    }
                }
                if let total = location.total, let available = location.available, total > 0 {
                    let used = Double(total - available) / Double(total)
                    VStack(alignment: .leading, spacing: 3) {
                        SizeBar(fraction: used, color: used > 0.9 ? FileCategory.video.color : FileCategory.folder.color, height: 4)
                        Text("\(available.bytes) free of \(total.bytes)")
                            .font(.system(size: 10.5))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    .padding(.leading, 31)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background {
                if isSelected {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.accentColor.opacity(0.16))
                        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(Color.accentColor.opacity(0.22), lineWidth: 1))
                        .matchedGeometryEffect(id: "selection", in: namespace)
                } else if hovering {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.primary.opacity(0.06))
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(location.path)
        .onHover { inside in
            withAnimation(Motion.hover.unless(reduceMotion)) { hovering = inside }
        }
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// The bottom of the sidebar: the Full Disk Access warning when it is off, and Choose Folder.
private struct SidebarFooter: View {
    @Environment(AppModel.self) private var model
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            if !model.hasFullDiskAccess {
                Button {
                    model.showOnboarding = true
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "lock.trianglebadge.exclamationmark")
                            .foregroundStyle(.orange)
                        Text("Full Disk Access is off")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.primary)
                            .lineLimit(2)
                        Spacer(minLength: 0)
                    }
                    .padding(Space.s)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.orange.opacity(0.12)))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            Button {
                model.chooseFolder()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "plus")
                        .font(.system(size: 11, weight: .bold))
                        .frame(width: 22, height: 22)
                        .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .strokeBorder(Color.secondary.opacity(0.5), style: StrokeStyle(lineWidth: 1, dash: [3, 2])))
                    Text("Choose Folder…").font(.system(size: 13))
                    Spacer(minLength: 0)
                }
                .foregroundStyle(hovering ? Color.accentColor : Color.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, Space.m)
        .overlay(alignment: .top) { Rectangle().fill(Palette.hairline).frame(height: 1) }
    }
}
