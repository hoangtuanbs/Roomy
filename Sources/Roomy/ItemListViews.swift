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
                List(Array(children.enumerated()), id: \.element, selection: $model.selection) { index, node in
                    let share = Double(tree.size(node)) / Double(parentSize)
                    ItemRow(node: node, fraction: share, share: share, showsPath: false, index: index)
                        .itemRowStyle()
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .itemListActions(model)
                // Only short lists animate their rows, so a folder with thousands of items stays quick.
                .animation(Motion.list(children.count, reduceMotion), value: children)
                .id(model.currentFolder)
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
            .padding(.horizontal, Space.l)
            .padding(.vertical, Space.xs)

            if let tree = model.tree {
                if files.isEmpty {
                    ContentUnavailableView("No files match", systemImage: "doc.text.magnifyingglass")
                } else {
                    let largest = max(1, tree.size(files[0]))
                    let total = max(1, tree.size(ScanTree.root))
                    List(Array(files.enumerated()), id: \.element, selection: $model.selection) { index, node in
                        ItemRow(node: node, fraction: Double(tree.size(node)) / Double(largest),
                                share: Double(tree.size(node)) / Double(total), showsPath: true, index: index)
                            .itemRowStyle()
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                    .itemListActions(model)
                    .animation(Motion.list(files.count, reduceMotion), value: files)
                }
            }
        }
    }
}

extension View {
    /// Roomy rows without separators, inset from the edges of the column.
    func itemRowStyle() -> some View {
        listRowSeparator(.hidden)
            .listRowInsets(EdgeInsets(top: 1, leading: 10, bottom: 1, trailing: 10))
    }
}

/// One item of a list: its tick box, a tinted tile for its kind, its name and file count, a gradient bar of its size,
/// and the size with its share on the right.
struct ItemRow: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let node: ScanTree.Index
    /// How long the bar is.
    let fraction: Double
    /// The item's share of the open folder (or of the scan, for Biggest Files), shown as a percentage.
    let share: Double
    let showsPath: Bool
    var index: Int = 0
    @State private var hovering = false

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

                ZStack {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(category.color.opacity(0.14))
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(category.color.opacity(0.18), lineWidth: 0.75)
                    Image(systemName: category.symbol)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(category.color)
                }
                .frame(width: 32, height: 32)
                .scaleEffect(hovering && !reduceMotion ? 1.06 : 1)

                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(tree.name(node))
                            .font(.system(size: 13, weight: .medium))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        if flags.contains(.inaccessible) {
                            Image(systemName: "lock.fill")
                                .font(.caption2)
                                .foregroundStyle(.orange)
                                .help("Not accessible. Grant Full Disk Access to measure it.")
                        }
                        if flags.contains(.otherVolume) {
                            Text("other disk").font(.caption2).foregroundStyle(.tertiary)
                        }
                        if flags.contains(.unavailable) {
                            Text(CloudGuard.unavailableNote(for: tree.path(of: node)))
                                .font(.caption2)
                                .foregroundStyle(.orange)
                                .lineLimit(1)
                        }
                        if flags.contains(.dataless) {
                            Image(systemName: "icloud")
                                .font(.caption2)
                                .foregroundStyle(.blue)
                                .help(SpaceNotes.cloudOnly(node, in: tree))
                                .accessibilityLabel(SpaceNotes.cloudOnly(node, in: tree))
                        }
                        if flags.contains(.clone) {
                            Image(systemName: "square.on.square")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .help(SpaceNotes.clone(node, in: tree))
                                .accessibilityLabel(SpaceNotes.clone(node, in: tree))
                        }
                        Spacer(minLength: 6)
                        if model.rescanningNode == node {
                            ProgressView()
                                .controlSize(.mini)
                                .help("Scanning this folder again")
                                .transition(.scale.combined(with: .opacity))
                        }
                        Text(tree.size(node).bytes)
                            .font(.system(size: 13, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                            .contentTransition(.numericText(value: Double(tree.size(node))))
                            .foregroundStyle(sizeColor(tree.size(node)))
                    }
                    HStack(spacing: 8) {
                        SizeBar(fraction: fraction, color: category.color, height: 5)
                        Text(share, format: .percent.precision(.fractionLength(share < 0.1 && share > 0 ? 1 : 0)))
                            .font(.system(size: 11, weight: .medium, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .frame(width: 42, alignment: .trailing)
                    }
                    Group {
                        if showsPath, let parent = tree.parent(node) {
                            Text(tree.path(of: parent))
                                .lineLimit(1)
                                .truncationMode(.head)
                        } else if kind.isContainer {
                            Text("\(Int(tree.fileCount(node)).formatted()) files")
                        } else {
                            Text(tree.modifiedDate(node), format: .dateTime.year().month(.abbreviated).day())
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }

                if kind == .directory {
                    Button {
                        model.open(node)
                    } label: {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(hovering ? Color.accentColor : Color.secondary.opacity(0.6))
                            .frame(width: 22, height: 22)
                            .background(Circle().fill(hovering ? Color.accentColor.opacity(0.12) : .clear))
                            .offset(x: hovering && !reduceMotion ? 1 : 0)
                    }
                    .buttonStyle(.plain)
                    .help("Open Folder")
                } else {
                    Color.clear.frame(width: 22, height: 22)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.primary.opacity(hovering ? 0.045 : 0))
            )
            .contentShape(Rectangle())
            .onHover { inside in
                withAnimation(Motion.hover.unless(reduceMotion)) { hovering = inside }
                if inside { model.hovered = node } else if model.hovered == node { model.hovered = nil }
            }
            .trayDraggable(node, model: model)
            .motion(Motion.quick, value: model.rescanningNode == node)
            .entrance(index: index, offset: 10, scale: 0.98)
        }
    }

    private func sizeColor(_ size: Int64) -> Color {
        if size >= 1_000_000_000 { return Color(red: 0.90, green: 0.30, blue: 0.40) }
        if size >= 100_000_000 { return Color(red: 0.92, green: 0.52, blue: 0.20) }
        return .primary
    }
}
