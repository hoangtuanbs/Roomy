import AppKit
import RoomyCore
import SwiftUI

/// Lists installed apps, shows the files each one leaves in the Library, and moves an app with its leftovers to the
/// Trash.
struct UninstallerView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let un = model.uninstaller

        VStack(spacing: 0) {
            UninstallerHeader()
            Divider()
            ZStack {
                switch un.phase {
                case .idle, .loading:
                    UninstallerLoading()
                        .transition(.opacity)
                case .ready:
                    UninstallerBrowser()
                        .transition(.opacity.combined(with: .scale(scale: 0.98)))
                case .removing:
                    UninstallerRemoving()
                        .transition(.opacity.combined(with: .scale(scale: 0.95)))
                case .done:
                    UninstallerDone()
                        .transition(.opacity.combined(with: .scale(scale: 0.9)))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .animation(reduceMotion ? nil : .smooth(duration: 0.35), value: un.phase)
            Divider()
            footer
        }
        .frame(minWidth: 900, idealWidth: 980, minHeight: 600, idealHeight: 720)
        .interactiveDismissDisabled(un.isBusy)
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didTerminateApplicationNotification)) { _ in
            un.refreshRunning()
        }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didLaunchApplicationNotification)) { _ in
            un.refreshRunning()
        }
    }

    private var footer: some View {
        let un = model.uninstaller
        return HStack(spacing: 10) {
            switch un.phase {
            case .idle, .loading:
                Spacer()
                Button("Close") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            case .ready:
                Text("Apps that come with macOS are not listed. Everything goes to the Trash, so Put Back still works.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer()
                Button("Reload") { un.load() }
                Button("Close") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            case .removing:
                Spacer()
                Text("Please wait…").foregroundStyle(.secondary)
            case .done:
                Button("Open Trash") { un.openTrash() }
                Spacer()
                Button("Back to Apps") { un.showList() }
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(.horizontal, 18)
        .frame(height: 56)
    }
}

private struct UninstallerHeader: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let un = model.uninstaller
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous).fill(LinearGradient.uninstaller)
                Image(systemName: "xmark.bin.fill")
                    .font(.system(size: 21, weight: .semibold))
                    .foregroundStyle(.white)
                    .symbolEffect(.pulse, isActive: un.isBusy && !reduceMotion)
            }
            .frame(width: 46, height: 46)

            VStack(alignment: .leading, spacing: 3) {
                Text("Uninstaller").font(.title2.weight(.semibold))
                Text("Remove apps together with the files they leave in your Library.")
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if un.phase == .ready && !un.apps.isEmpty {
                VStack(alignment: .trailing, spacing: 2) {
                    CountingBytes(un.totalAppBytes)
                        .font(.system(size: 26, weight: .bold, design: .rounded))
                        .animation(reduceMotion ? nil : .snappy(duration: 0.3), value: un.totalAppBytes)
                    Text("in \(un.apps.count) \(un.apps.count == 1 ? "app" : "apps")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .contentTransition(.numericText())
                }
                .transition(.opacity.combined(with: .move(edge: .trailing)))
            }
        }
        .padding(18)
        .animation(reduceMotion ? nil : .smooth(duration: 0.3), value: un.phase)
    }
}

private struct UninstallerLoading: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var spinning = false
    @State private var bobbing = false

    var body: some View {
        VStack(spacing: 18) {
            ZStack {
                Circle().stroke(Color.primary.opacity(0.08), lineWidth: 8)
                Circle()
                    .trim(from: 0, to: 0.28)
                    .stroke(LinearGradient.uninstaller, style: StrokeStyle(lineWidth: 8, lineCap: .round))
                    .rotationEffect(.degrees(spinning ? 360 : 0))
                Image(systemName: "square.grid.2x2.fill")
                    .font(.system(size: 30, weight: .medium))
                    .foregroundStyle(LinearGradient.uninstaller)
                    .offset(y: bobbing ? -3 : 3)
            }
            .frame(width: 110, height: 110)
            Text("Reading your apps…").font(.title3.weight(.medium))
            Text("Nothing is moved yet.").font(.callout).foregroundStyle(.tertiary)
        }
        .padding(32)
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.linear(duration: 1.1).repeatForever(autoreverses: false)) { spinning = true }
            withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) { bobbing = true }
        }
    }
}

// MARK: Browser

private struct UninstallerBrowser: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let un = model.uninstaller
        HStack(spacing: 0) {
            AppGrid()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            if let focus = un.focus {
                Divider()
                Group {
                    switch focus {
                    case .app:
                        if let app = un.selectedApp {
                            AppDetail(app: app).id(app.path)
                        }
                    case .orphans:
                        OrphansDetail()
                    }
                }
                .frame(width: 380)
                .frame(maxHeight: .infinity)
                .background(Color.primary.opacity(0.025))
                .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .animation(reduceMotion ? nil : .spring(response: 0.4, dampingFraction: 0.86), value: un.focus)
    }
}

private struct AppGrid: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var selection

    var body: some View {
        @Bindable var un = model.uninstaller
        let visible = un.visibleApps

        VStack(spacing: 0) {
            HStack(spacing: 10) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Search apps", text: $un.searchText)
                        .textFieldStyle(.plain)
                    if !un.searchText.isEmpty {
                        Button {
                            un.searchText = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                        }
                        .buttonStyle(.borderless)
                        .transition(.scale.combined(with: .opacity))
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.primary.opacity(0.06)))
                .frame(maxWidth: 260)
                .animation(reduceMotion ? nil : .snappy(duration: 0.2), value: un.searchText.isEmpty)

                Spacer()
                Picker("Sort by", selection: $un.sort) {
                    ForEach(UninstallerModel.SortOrder.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .frame(width: 240)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            Divider()

            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 124, maximum: 160), spacing: 10)], spacing: 10) {
                    if un.searchText.isEmpty {
                        OrphansTile(highlight: selection)
                    }
                    ForEach(Array(visible.enumerated()), id: \.element.path) { index, app in
                        AppTile(app: app, index: index, highlight: selection)
                            .transition(.asymmetric(insertion: .opacity.combined(with: .scale(scale: 0.9)),
                                                    removal: .opacity.combined(with: .scale(scale: 0.6))))
                    }
                }
                .padding(16)
                .animation(reduceMotion ? nil : .spring(response: 0.45, dampingFraction: 0.82), value: visible.map(\.path))
            }
            .overlay {
                if visible.isEmpty && !un.searchText.isEmpty {
                    ContentUnavailableView.search(text: un.searchText)
                }
            }
        }
    }
}

private struct AppTile: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let app: InstalledApp
    let index: Int
    let highlight: Namespace.ID
    @State private var hovering = false
    @State private var appeared = false

    var body: some View {
        let un = model.uninstaller
        let isSelected = un.focus == .app(app.path)
        let isMeasured = un.measured.contains(app.path)
        let isOpen = un.runningPaths.contains(app.path)

        Button {
            un.select(app)
        } label: {
            VStack(spacing: 6) {
                FileThumbnail(path: app.path, size: 54)
                    .scaleEffect(hovering && !reduceMotion ? 1.08 : 1)
                    .shadow(color: .black.opacity(hovering ? 0.18 : 0.08), radius: hovering ? 6 : 2, y: 2)
                Text(app.name)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.tail)
                ZStack {
                    if isMeasured {
                        CountingBytes(appeared ? app.bytes : 0)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .transition(.opacity)
                    } else {
                        ProgressView().controlSize(.mini)
                            .transition(.opacity)
                    }
                }
                .frame(height: 14)
                Group {
                    if isOpen {
                        Badge(text: "Open", color: .orange)
                    } else if let used = app.lastUsed {
                        Text(used, format: .relative(presentation: .named))
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    } else {
                        Text("Never opened").font(.caption2).foregroundStyle(.tertiary)
                    }
                }
                .lineLimit(1)
            }
            .padding(.vertical, 12)
            .padding(.horizontal, 8)
            .frame(maxWidth: .infinity)
            .background {
                if isSelected {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color.accentColor.opacity(0.16))
                        .matchedGeometryEffect(id: "selected", in: highlight)
                } else {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color.primary.opacity(hovering ? 0.06 : 0.03))
                }
            }
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(isSelected ? Color.accentColor.opacity(0.7) : Color.clear, lineWidth: 1.5)
            )
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .help(app.path)
        .opacity(appeared ? 1 : 0)
        .scaleEffect(appeared ? 1 : 0.9)
        .animation(reduceMotion ? nil : .snappy(duration: 0.4), value: app.bytes)
        .onHover { inside in
            withAnimation(reduceMotion ? nil : .snappy(duration: 0.18)) { hovering = inside }
        }
        .onAppear {
            guard !appeared else { return }
            if reduceMotion {
                appeared = true
            } else {
                withAnimation(.spring(response: 0.45, dampingFraction: 0.8).delay(Double(min(index, 18)) * 0.02)) {
                    appeared = true
                }
            }
        }
        .contextMenu {
            Button("Show in Finder") { un.reveal(app.path) }
        }
    }
}

/// The first tile: files of apps that are no longer installed.
private struct OrphansTile: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let highlight: Namespace.ID
    @State private var hovering = false

    var body: some View {
        let un = model.uninstaller
        let isSelected = un.focus == .orphans

        Button {
            un.showOrphans()
        } label: {
            VStack(spacing: 6) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(LinearGradient.uninstaller)
                        .opacity(0.18)
                    Image(systemName: "questionmark.folder.fill")
                        .font(.system(size: 26))
                        .foregroundStyle(LinearGradient.uninstaller)
                        .symbolEffect(.bounce, value: hovering)
                }
                .frame(width: 54, height: 54)
                Text("Leftovers of removed apps")
                    .font(.callout.weight(.medium))
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                if un.orphansLoaded {
                    CountingBytes(un.orphanBytes)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                } else {
                    Badge(text: "Review first", color: .orange)
                }
            }
            .padding(.vertical, 12)
            .padding(.horizontal, 8)
            .frame(maxWidth: .infinity)
            .background {
                if isSelected {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color.accentColor.opacity(0.16))
                        .matchedGeometryEffect(id: "selected", in: highlight)
                } else {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                        .foregroundStyle(Color.primary.opacity(hovering ? 0.35 : 0.2))
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .scaleEffect(hovering && !reduceMotion ? 1.03 : 1)
        }
        .buttonStyle(.plain)
        .help("Library folders named after apps that are no longer installed")
        .onHover { inside in
            withAnimation(reduceMotion ? nil : .snappy(duration: 0.18)) { hovering = inside }
        }
    }
}

// MARK: App detail

private struct AppDetail: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let app: InstalledApp
    @State private var confirm = false
    @State private var appeared = false

    var body: some View {
        let un = model.uninstaller
        let blocked = un.blockReason(for: app)
        let groups = LeftoverKind.allCases.compactMap { kind -> LeftoverGroup? in
            let items = un.leftovers.filter { $0.kind == kind }
            return items.isEmpty ? nil : LeftoverGroup(kind: kind, items: items)
        }

        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 12) {
                FileThumbnail(path: app.path, size: 64)
                    .scaleEffect(appeared ? 1 : 0.6)
                    .opacity(appeared ? 1 : 0)
                VStack(alignment: .leading, spacing: 3) {
                    Text(app.name).font(.title3.weight(.semibold)).lineLimit(2)
                    if let version = app.version {
                        Text("Version \(version)").font(.callout).foregroundStyle(.secondary)
                    }
                    if let id = app.bundleID {
                        Text(id).font(.caption.monospaced()).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.middle)
                            .textSelection(.enabled)
                    }
                    if let used = app.lastUsed {
                        Text("Last used \(used.formatted(.relative(presentation: .named)))")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
                Button {
                    un.closeDetail()
                } label: {
                    Image(systemName: "xmark.circle.fill").font(.title3).foregroundStyle(.tertiary)
                }
                .buttonStyle(.borderless)
                .help("Close")
            }
            .padding(16)

            if let blocked {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text(blocked).font(.callout)
                    Spacer()
                    if un.runningPaths.contains(app.path) {
                        Button("Quit \(app.name)") { un.quit(app) }
                            .controlSize(.small)
                    }
                }
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.orange.opacity(0.10)))
                .padding(.horizontal, 16)
                .padding(.bottom, 8)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    LeftoverSection(title: "App", symbol: "app.fill", color: .accentColor,
                                    rows: [LeftoverRow(path: app.path, name: "\(app.name).app", bytes: app.bytes)],
                                    disabled: blocked != nil)
                    if un.isFindingLeftovers {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("Looking for leftovers…").foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 4)
                        .transition(.opacity)
                    } else if groups.isEmpty {
                        Label("No leftovers found in your Library.", systemImage: "checkmark.seal")
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 4)
                            .transition(.opacity)
                    } else {
                        ForEach(Array(groups.enumerated()), id: \.element.kind) { index, group in
                            LeftoverSection(title: group.kind.title, symbol: symbol(group.kind), color: color(index),
                                            rows: group.items.map { LeftoverRow(path: $0.path, name: $0.name, bytes: $0.bytes) },
                                            disabled: blocked != nil, subtitle: "~/Library/" + group.kind.folder)
                                .transition(.opacity.combined(with: .move(edge: .bottom)))
                        }
                    }
                }
                .padding(16)
                .animation(reduceMotion ? nil : .spring(response: 0.4, dampingFraction: 0.85), value: un.leftovers.map(\.path))
                .animation(reduceMotion ? nil : .easeOut(duration: 0.25), value: un.isFindingLeftovers)
            }

            Divider()

            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 1) {
                    CountingBytes(un.tickedBytes)
                        .font(.title3.weight(.bold))
                        .animation(reduceMotion ? nil : .snappy(duration: 0.3), value: un.tickedBytes)
                    Text("\(un.tickedCount) \(un.tickedCount == 1 ? "item" : "items") ticked")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .contentTransition(.numericText())
                        .animation(reduceMotion ? nil : .snappy(duration: 0.3), value: un.tickedCount)
                }
                Spacer()
                Button {
                    confirm = true
                } label: {
                    Label(un.ticked.contains(app.path) ? "Uninstall" : "Remove Leftovers", systemImage: "trash")
                        .padding(.horizontal, 6)
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .controlSize(.large)
                .disabled(blocked != nil || un.tickedCount == 0 || un.isFindingLeftovers)
            }
            .padding(14)
        }
        .animation(reduceMotion ? nil : .smooth(duration: 0.3), value: blocked)
        .alert(un.ticked.contains(app.path) ? "Uninstall \(app.name)?" : "Remove the leftovers of \(app.name)?",
               isPresented: $confirm) {
            Button("Move to Trash", role: .destructive) { un.uninstall() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("\(un.tickedCount) \(un.tickedCount == 1 ? "item" : "items") (\(un.tickedBytes.bytes)) will be moved to the Trash. You can put them back from the Trash until you empty it.")
        }
        .onAppear {
            withAnimation(reduceMotion ? nil : .spring(response: 0.45, dampingFraction: 0.7)) { appeared = true }
        }
    }

    private func symbol(_ kind: LeftoverKind) -> String {
        switch kind {
        case .applicationSupport: return "folder.fill"
        case .caches: return "bolt.horizontal.circle"
        case .preferences: return "slider.horizontal.3"
        case .savedState: return "macwindow"
        case .containers, .groupContainers: return "shippingbox"
        case .applicationScripts: return "applescript"
        case .httpStorages, .webKit, .cookies: return "globe"
        case .logs: return "text.alignleft"
        case .launchAgents: return "gearshape.2"
        }
    }

    private func color(_ index: Int) -> Color {
        let colors = JunkCategory.allCases.map(\.color)
        return colors[index % colors.count]
    }
}

private struct LeftoverGroup {
    let kind: LeftoverKind
    let items: [Leftover]
}

private struct LeftoverRow {
    let path: String
    let name: String
    let bytes: Int64
}

/// A group of tickable rows with a group tick box and a total.
private struct LeftoverSection: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let title: String
    let symbol: String
    let color: Color
    let rows: [LeftoverRow]
    var disabled = false
    var subtitle: String?

    var body: some View {
        let un = model.uninstaller
        let tickedCount = rows.filter { un.ticked.contains($0.path) }.count
        let state: JunkSelection.State = tickedCount == 0 ? .none : (tickedCount == rows.count ? .all : .some)
        let total = rows.reduce(Int64(0)) { $0 + $1.bytes }

        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                SelectionBox(state: state, color: color) {
                    withAnimation(reduceMotion ? nil : .snappy(duration: 0.2)) {
                        let paths = rows.map(\.path)
                        if state == .all { un.ticked.subtract(paths) } else { un.ticked.formUnion(paths) }
                    }
                }
                .disabled(disabled)
                Image(systemName: symbol).foregroundStyle(color).frame(width: 18)
                VStack(alignment: .leading, spacing: 0) {
                    Text(title).font(.headline)
                    if let subtitle {
                        Text(subtitle).font(.caption2).foregroundStyle(.tertiary)
                    }
                }
                Spacer()
                CountingBytes(total)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            ForEach(rows, id: \.path) { row in
                HStack(spacing: 8) {
                    SelectionBox(state: un.ticked.contains(row.path) ? .all : .none, color: color) {
                        withAnimation(reduceMotion ? nil : .snappy(duration: 0.2)) { un.toggle(row.path) }
                    }
                    .disabled(disabled)
                    Text(row.name)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .foregroundStyle(un.ticked.contains(row.path) ? Color.primary : Color.secondary)
                    Spacer(minLength: 6)
                    Text(row.bytes.bytes)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                    Button {
                        un.reveal(row.path)
                    } label: {
                        Image(systemName: "magnifyingglass")
                    }
                    .buttonStyle(.borderless)
                    .help("Show in Finder")
                }
                .padding(.leading, 26)
                .font(.callout)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.04)))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(state == .none ? Color.primary.opacity(0.06) : color.opacity(0.45), lineWidth: 1)
        )
        .opacity(disabled ? 0.6 : 1)
    }
}

// MARK: Leftovers of removed apps

private struct OrphansDetail: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var confirm = false
    @State private var expanded: Set<String> = []

    var body: some View {
        let un = model.uninstaller

        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text("Leftovers of removed apps").font(.title3.weight(.semibold))
                        Badge(text: "Review first", color: .orange)
                    }
                    Text("Library items named after apps that are not installed in Applications. Some may belong to tools, helpers or apps kept elsewhere, so nothing is ticked.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Button {
                    un.closeDetail()
                } label: {
                    Image(systemName: "xmark.circle.fill").font(.title3).foregroundStyle(.tertiary)
                }
                .buttonStyle(.borderless)
                .help("Close")
            }
            .padding(16)

            Divider()

            ZStack {
                if un.isFindingOrphans {
                    VStack(spacing: 10) {
                        ProgressView()
                        Text("Looking through your Library…").foregroundStyle(.secondary)
                    }
                    .transition(.opacity)
                } else if un.orphans.isEmpty {
                    ContentUnavailableView("Nothing left behind", systemImage: "checkmark.seal",
                                           description: Text("No Library items of removed apps were found."))
                        .transition(.opacity)
                } else {
                    ScrollView {
                        LazyVStack(spacing: 8) {
                            ForEach(un.orphans) { group in
                                OrphanCard(group: group, isExpanded: expanded.contains(group.id)) {
                                    withAnimation(reduceMotion ? nil : .spring(response: 0.35, dampingFraction: 0.85)) {
                                        if expanded.contains(group.id) { expanded.remove(group.id) } else { expanded.insert(group.id) }
                                    }
                                }
                                .transition(.opacity.combined(with: .scale(scale: 0.95)))
                            }
                        }
                        .padding(16)
                        .animation(reduceMotion ? nil : .spring(response: 0.4, dampingFraction: 0.85), value: un.orphans.map(\.id))
                    }
                    .transition(.opacity)
                }
            }
            .frame(maxHeight: .infinity)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.25), value: un.isFindingOrphans)

            Divider()

            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 1) {
                    CountingBytes(un.orphanTickedBytes)
                        .font(.title3.weight(.bold))
                        .animation(reduceMotion ? nil : .snappy(duration: 0.3), value: un.orphanTickedBytes)
                    Text("\(un.orphanTickedItems.count) ticked")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .contentTransition(.numericText())
                }
                Spacer()
                Button {
                    confirm = true
                } label: {
                    Label("Move to Trash", systemImage: "trash").padding(.horizontal, 6)
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .controlSize(.large)
                .disabled(un.orphanTickedItems.isEmpty)
            }
            .padding(14)
        }
        .alert("Move \(un.orphanTickedItems.count) \(un.orphanTickedItems.count == 1 ? "item" : "items") to the Trash?",
               isPresented: $confirm) {
            Button("Move to Trash", role: .destructive) { un.removeOrphans() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("\(un.orphanTickedBytes.bytes) of settings and data of apps that are not installed. If an app still uses them, put them back from the Trash.")
        }
    }
}

private struct OrphanCard: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let group: OrphanGroup
    let isExpanded: Bool
    let toggleExpanded: () -> Void

    private static let color = Color(red: 0.93, green: 0.50, blue: 0.35)

    var body: some View {
        let un = model.uninstaller
        let count = group.items.filter { un.orphanTicked.contains($0.path) }.count
        let state: JunkSelection.State = count == 0 ? .none : (count == group.items.count ? .all : .some)

        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                SelectionBox(state: state, color: Self.color) {
                    withAnimation(reduceMotion ? nil : .snappy(duration: 0.2)) {
                        un.setAllOrphans(group, ticked: state != .all)
                    }
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(group.bundleID).font(.callout.monospaced()).lineLimit(1).truncationMode(.middle)
                    Text(Set(group.items.map(\.kind.title)).sorted().joined(separator: ", "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 6)
                Text(group.bytes.bytes).font(.callout.weight(.semibold)).monospacedDigit()
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
            }
            .padding(10)
            .contentShape(Rectangle())
            .onTapGesture(perform: toggleExpanded)

            if isExpanded {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(group.items) { item in
                        HStack(spacing: 8) {
                            SelectionBox(state: un.orphanTicked.contains(item.path) ? .all : .none, color: Self.color) {
                                withAnimation(reduceMotion ? nil : .snappy(duration: 0.2)) { un.toggleOrphan(item.path) }
                            }
                            VStack(alignment: .leading, spacing: 0) {
                                Text(item.name).lineLimit(1).truncationMode(.middle)
                                Text("~/Library/" + item.kind.folder).font(.caption2).foregroundStyle(.tertiary)
                            }
                            Spacer(minLength: 6)
                            Text(item.bytes.bytes).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                            Button {
                                un.reveal(item.path)
                            } label: {
                                Image(systemName: "magnifyingglass")
                            }
                            .buttonStyle(.borderless)
                            .help("Show in Finder")
                        }
                        .font(.callout)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 10)
                .padding(.leading, 26)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.04)))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(state == .none ? Color.primary.opacity(0.06) : Self.color.opacity(0.5), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

// MARK: Removing and result

private struct UninstallerRemoving: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var flown = false

    var body: some View {
        let un = model.uninstaller
        VStack(spacing: 24) {
            if let app = un.removingApp {
                // The app's icon shrinks and drops into the Trash.
                ZStack {
                    Image(systemName: flown ? "trash.fill" : "trash")
                        .font(.system(size: 54, weight: .regular))
                        .foregroundStyle(LinearGradient.uninstaller)
                        .contentTransition(.symbolEffect(.replace))
                        .symbolEffect(.bounce, value: flown)
                        .offset(x: 90, y: 14)
                    FileThumbnail(path: app.path, size: 84)
                        .scaleEffect(flown ? 0.18 : 1)
                        .rotationEffect(.degrees(flown ? 24 : 0))
                        .offset(x: flown ? 90 : -90, y: flown ? 4 : -10)
                        .opacity(flown ? 0 : 1)
                }
                .frame(width: 300, height: 120)
            }
            ZStack {
                Circle().stroke(Color.primary.opacity(0.08), lineWidth: 10)
                Circle()
                    .trim(from: 0, to: max(0.02, un.cleanFraction))
                    .stroke(LinearGradient.uninstaller, style: StrokeStyle(lineWidth: 10, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(reduceMotion ? nil : .easeInOut(duration: 0.35), value: un.cleanFraction)
                VStack(spacing: 2) {
                    Text(un.cleanedBytes.bytes)
                        .font(.system(size: 24, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .contentTransition(.numericText(value: Double(un.cleanedBytes)))
                        .animation(reduceMotion ? nil : .snappy(duration: 0.25), value: un.cleanedBytes)
                    Text("moved to the Trash").font(.caption).foregroundStyle(.secondary)
                }
            }
            .frame(width: 160, height: 160)
            Text("Moving \(min(un.cleanedCount + 1, un.cleanTotal)) of \(un.cleanTotal)…")
                .font(.title3)
                .monospacedDigit()
                .contentTransition(.numericText())
                .animation(reduceMotion ? nil : .snappy(duration: 0.2), value: un.cleanedCount)
        }
        .padding(32)
        .onAppear {
            if reduceMotion {
                flown = true
            } else {
                withAnimation(.easeIn(duration: 0.6).delay(0.15)) { flown = true }
            }
        }
    }
}

private struct UninstallerDone: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shown = false

    var body: some View {
        let un = model.uninstaller
        let moved = un.report?.succeeded.count ?? 0
        let failed = un.report?.failed ?? []
        let appGone = un.removingApp.map { app in un.report?.succeeded.contains { $0.path == app.path } ?? false } ?? false

        ZStack {
            if shown && !reduceMotion && moved > 0 {
                ConfettiBurst()
            }
            VStack(spacing: 14) {
                Image(systemName: un.appFailure == nil ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                    .font(.system(size: 68))
                    .foregroundStyle(un.appFailure == nil ? Color.green.gradient : Color.orange.gradient)
                    .scaleEffect(shown ? 1 : 0.3)
                    .opacity(shown ? 1 : 0)
                    .symbolEffect(.bounce, value: shown)
                CountingBytes(shown ? un.cleanedBytes : 0, suffix: " freed")
                    .font(.system(size: 44, weight: .bold, design: .rounded))
                Text(summary(moved: moved, appGone: appGone))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 480)
                    .opacity(shown ? 1 : 0)
                if let failure = un.appFailure {
                    Text(failure)
                        .font(.callout)
                        .multilineTextAlignment(.center)
                        .padding(12)
                        .frame(maxWidth: 480)
                        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.orange.opacity(0.12)))
                        .transition(.opacity)
                }
                if !failed.isEmpty {
                    DisclosureGroup("\(failed.count) could not be moved") {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(failed, id: \.path) { result in
                                VStack(alignment: .leading, spacing: 1) {
                                    Text((result.path as NSString).lastPathComponent)
                                    Text(result.error ?? "Unknown error").font(.caption).foregroundStyle(.secondary)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                        .padding(.top, 4)
                    }
                    .frame(maxWidth: 480)
                    .foregroundStyle(.orange)
                }
            }
            .padding(32)
        }
        .onAppear {
            if reduceMotion {
                shown = true
            } else {
                withAnimation(.spring(response: 0.5, dampingFraction: 0.62)) { shown = true }
            }
        }
    }

    private func summary(moved: Int, appGone: Bool) -> String {
        let things = "\(moved) \(moved == 1 ? "item" : "items")"
        if appGone, let app = model.uninstaller.removingApp {
            return "\(app.name) and its leftovers are in the Trash (\(things)). Empty the Trash to get the space back for good, or use Put Back in Finder to restore it."
        }
        return "Moved \(things) to the Trash. Empty the Trash to get the space back for good, or use Put Back in Finder to restore anything."
    }
}
