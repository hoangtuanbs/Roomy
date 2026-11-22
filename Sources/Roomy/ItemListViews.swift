import RoomyCore
import SwiftUI

/// The actions for one item, shared by the lists, the treemap, the rings and the tray.
struct NodeMenu: View {
    @Environment(AppModel.self) private var model
    let node: ScanTree.Index

    var body: some View {
        if let tree = model.tree {
            let kind = tree.kind(node)
            if kind == .directory {
                Button("Open Folder") { model.open(node) }
            }
            Button("Quick Look") { model.quickLook(node) }
            Button("Reveal in Finder") { model.reveal(node) }
            Button("Copy Path") { model.copyPath(node) }
            if kind.isContainer {
                Button("Rescan This Folder") { model.rescanSubtree(node) }
                    .disabled(!model.canRescanSubtree)
            }
            Divider()
            Button(model.isInBasket(node) ? "Remove from Tray" : "Add to Tray") {
                if model.isInBasket(node) { model.toggleBasket(node) } else { model.addToTray(node) }
            }
            .disabled(model.verdict(for: node).isBlocked)
            Button("Compress and Move Original to Trash…") { model.startCompress(node) }
                .disabled(!model.canCompress(node))
        }
    }
}

extension View {
    /// Selection, double-click and the context menu for a list of scan items.
    @MainActor
    func itemListActions(_ model: AppModel) -> some View {
        contextMenu(forSelectionType: ScanTree.Index.self) { nodes in
            if let node = nodes.first { NodeMenu(node: node) }
        } primaryAction: { nodes in
            if let node = nodes.first { model.activate(node) }
        }
    }
}

struct FolderListView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        @Bindable var model = model
        let children = model.visibleChildren
        if let tree = model.tree {
            if children.isEmpty {
                ContentUnavailableView(model.searchText.isEmpty ? "This folder is empty" : "No matches", systemImage: "folder")
            } else {
                let parentSize = max(1, tree.size(model.currentFolder))
                List(children, id: \.self, selection: $model.selection) { node in
                    ItemRow(node: node, fraction: Double(tree.size(node)) / Double(parentSize), showsPath: false)
                }
                .listStyle(.inset)
                .itemListActions(model)
                // Only short lists animate their rows, so a folder with thousands of items stays quick.
                .animation(Motion.list(children.count, reduceMotion), value: children)
            }
        }
    }
}

struct BiggestFilesView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        @Bindable var model = model
        let files = model.filteredBiggestFiles

        VStack(spacing: 0) {
            HStack {
                Picker("Kind", selection: $model.categoryFilter) {
                    Text("All kinds").tag(FileCategory?.none)
                    ForEach(FileCategory.allCases.filter { $0 != .folder }, id: \.self) { category in
                        Label(category.title, systemImage: category.symbol).tag(Optional(category))
                    }
                }
                .fixedSize()
                Picker("Age", selection: $model.ageFilter) {
                    ForEach(AgeFilter.allCases) { Text($0.label).tag($0) }
                }
                .fixedSize()
                Spacer()
            }
            .labelsHidden()
            .padding(.horizontal, 12)
            .padding(.vertical, 6)

            if let tree = model.tree {
                if files.isEmpty {
                    ContentUnavailableView("No files match", systemImage: "doc.text.magnifyingglass")
                } else {
                    let largest = max(1, tree.size(files[0]))
                    List(files, id: \.self, selection: $model.selection) { node in
                        ItemRow(node: node, fraction: Double(tree.size(node)) / Double(largest), showsPath: true)
                    }
                    .listStyle(.inset)
                    .itemListActions(model)
                    .animation(Motion.list(files.count, reduceMotion), value: files)
                }
            }
        }
    }
}

struct ItemRow: View {
    @Environment(AppModel.self) private var model
    let node: ScanTree.Index
    let fraction: Double
    let showsPath: Bool

    var body: some View {
        if let tree = model.tree {
            let kind = tree.kind(node)
            let category = model.category(of: node)
            let verdict = model.verdict(for: node)
            let flags = tree.flags(node)

            HStack(spacing: 10) {
                Toggle("Select", isOn: Binding(
                    get: { model.isInBasket(node) },
                    set: { _ in model.toggleBasket(node) }
                ))
                .toggleStyle(.checkbox)
                .labelsHidden()
                .disabled(verdict.isBlocked)
                .help(verdict.message ?? String(localized: "Collect in the tray for cleaning"))

                Image(systemName: category.symbol)
                    .foregroundStyle(category.color)
                    .frame(width: 18)

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 4) {
                        Text(tree.name(node)).lineLimit(1).truncationMode(.middle)
                        if flags.contains(.inaccessible) {
                            Image(systemName: "lock.fill")
                                .font(.caption2)
                                .foregroundStyle(.orange)
                                .help("Not accessible. Grant Full Disk Access to measure it.")
                        }
                        if flags.contains(.otherVolume) {
                            Text("other disk").font(.caption2).foregroundStyle(.tertiary)
                        }
                    }
                    if showsPath, let parent = tree.parent(node) {
                        Text(tree.path(of: parent))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.head)
                    }
                    SizeBar(fraction: fraction, color: category.color.opacity(0.8))
                        .frame(maxWidth: 160)
                }

                Spacer(minLength: 8)

                if model.rescanningNode == node {
                    ProgressView()
                        .controlSize(.small)
                        .help("Scanning this folder again")
                        .transition(.scale.combined(with: .opacity))
                }

                VStack(alignment: .trailing, spacing: 2) {
                    Text(tree.size(node).bytes)
                        .monospacedDigit()
                        .contentTransition(.numericText(value: Double(tree.size(node))))
                        .foregroundStyle(sizeColor(tree.size(node)))
                    if kind.isContainer {
                        Text("\(Int(tree.fileCount(node)).formatted()) files")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    } else {
                        Text(tree.modifiedDate(node), format: .dateTime.year().month(.abbreviated).day())
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }

                if kind == .directory {
                    Button {
                        model.open(node)
                    } label: {
                        Image(systemName: "chevron.right")
                    }
                    .buttonStyle(.borderless)
                }
            }
            .padding(.vertical, 3)
            .contentShape(Rectangle())
            .onHover { inside in
                if inside { model.hovered = node } else if model.hovered == node { model.hovered = nil }
            }
            .trayDraggable(node, model: model)
            .motion(Motion.quick, value: model.rescanningNode == node)
        }
    }

    private func sizeColor(_ size: Int64) -> Color {
        if size >= 1_000_000_000 { return .red }
        if size >= 100_000_000 { return .orange }
        return .primary
    }
}
