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
