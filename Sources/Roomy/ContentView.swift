import AppKit
import RoomyCore
import SwiftUI

struct ContentView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        @Bindable var model = model

        HStack(spacing: 0) {
            SidebarView()
                .frame(width: 244)
                .frame(maxHeight: .infinity)
                .background(Palette.sidebar.ignoresSafeArea())
            Rectangle()
                .fill(Palette.hairline)
                .frame(width: 1)
                .ignoresSafeArea()
            VStack(spacing: 0) {
                MainArea()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                if model.tree != nil {
                    TrayView()
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .background(Palette.content.ignoresSafeArea())
        }
        .animation(Motion.spring.unless(reduceMotion), value: model.tree != nil)
        .navigationTitle(model.locationName)
        .modifier(MainToolbar())
        .sheet(isPresented: $model.showReview) {
            ReviewSheet().environment(model)
        }
        .sheet(isPresented: $model.showCompress, onDismiss: { model.closeCompress() }) {
            CompressSheet().environment(model)
        }
        .sheet(isPresented: $model.showSmartClean) {
            SmartCleanView().environment(model)
        }
        .sheet(isPresented: $model.showDuplicates) {
            DuplicatesView().environment(model)
        }
        .sheet(isPresented: $model.showUninstaller) {
            UninstallerView().environment(model)
        }
        .sheet(isPresented: $model.showSpaceHunters) {
            SpaceHuntersView().environment(model)
        }
        .sheet(isPresented: $model.showCloudSpace) {
            CloudSpaceView().environment(model)
        }
        .sheet(isPresented: $model.showDiskHealth) {
            DiskHealthView().environment(model)
        }
        .sheet(isPresented: $model.showOnboarding) {
            OnboardingView().environment(model)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            model.refreshAccess()
            model.refreshLocations()
        }
        .dropDestination(for: URL.self) { urls, _ in
            var isDirectory: ObjCBool = false
            guard let url = urls.first,
                  FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
                  isDirectory.boolValue
            else { return false }
            model.pin(url.path)
            model.scan(path: url.path)
            return true
        }
    }
}

extension AppModel {
    /// The name of the scanned location, as the sidebar calls it: a disk's name rather than "/", the folder's name
    /// rather than its path. "RoomyDisk" before any scan.
    var locationName: String {
        guard let root = tree?.rootPath ?? selectedPath else { return "RoomyDisk" }
        if let volume = volumes.first(where: { $0.path == root }) { return volume.name }
        if let folder = folders.first(where: { $0.path == root }) { return folder.name }
        let name = (root as NSString).lastPathComponent
        return name.isEmpty ? root : name
    }

    /// The name shown for a node in the header and the breadcrumb: the location's name for the root.
    func displayName(_ node: ScanTree.Index) -> String {
        guard let tree else { return locationName }
        return node == ScanTree.root ? locationName : tree.name(node)
    }
}

/// The window's toolbar is left clear: the tools live in the sidebar, Rescan and Export sit in the header, and the
/// filter sits above the list it filters. The traffic lights float over the sidebar.
private struct MainToolbar: ViewModifier {
    @Environment(AppModel.self) private var model

    func body(content: Content) -> some View {
        @Bindable var model = model
        content
            .toolbarBackground(.hidden, for: .windowToolbar)
            .modifier(HiddenToolbarTitle())
    }
}

/// The location's name is the big title of the header, so the toolbar does not repeat it where macOS allows.
private struct HiddenToolbarTitle: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 15.0, *) {
            content.toolbar(removing: .title)
        } else {
            content
        }
    }
}

/// Everything right of the sidebar above the bottom bar, for each state of the scan.
struct MainArea: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ZStack {
            switch model.state {
            case .idle:
                WelcomeView()
                    .transition(.opacity)
            case .scanning(let progress):
                ScanProgressView(progress: progress)
                    .transition(.opacity.combined(with: .scale(scale: 0.96)))
            case .failed(let message):
                ContentUnavailableView("Scan failed", systemImage: "exclamationmark.triangle", description: Text(message))
                    .transition(.opacity)
            case .ready:
                ResultsView()
                    .transition(.opacity)
            }
        }
        .motion(Motion.smooth, value: model.state.phase)
    }
}

/// Shown before anything is scanned: a big, friendly invitation to pick a location.
private struct WelcomeView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: Space.l) {
            ZStack {
                Circle().fill(LinearGradient.scan).opacity(0.12).frame(width: 150, height: 150)
                IconTile(symbol: "internaldrive.fill", gradient: .scan, size: 84, symbolScale: 0.46)
                    .shadow(color: .black.opacity(0.15), radius: 10, y: 5)
            }
            .entrance(offset: 0, scale: 0.85)
            VStack(spacing: Space.s) {
                Text("Choose a location").font(Typo.heroTitle)
                Text("Pick your home folder or a disk in the sidebar, or drop a folder here, to see what is using space.")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 380)
            }
            .entrance(index: 1, offset: 10)
            Button {
                model.chooseFolder()
            } label: {
                Label("Choose Folder…", systemImage: "folder.badge.plus")
            }
            .buttonStyle(.primaryAction(.scan))
            .controlSize(.large)
            .entrance(index: 2, offset: 10)
        }
        .padding(Space.xxl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// The scan's results: the header, then the lists on the left and the map on the right.
private struct ResultsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 0) {
            HeroHeader()
            HSplitView {
                ContentColumn()
                    .frame(minWidth: 340, idealWidth: 420, maxWidth: 560)
                DetailColumn()
                    .frame(minWidth: 380, maxWidth: .infinity)
            }
        }
        .task(id: model.treeVersion) { model.refreshDiskOverview() }
    }
}

/// The big header above the results: the folder's name, the path to it with clickable steps, its size counting up,
/// and the Treemap/Rings switch.
struct HeroHeader: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        @Bindable var model = model
        if let tree = model.tree {
            let folder = model.currentFolder
            HStack(alignment: .center, spacing: Space.m) {
                Button {
                    model.goUp()
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 13, weight: .semibold))
                        .frame(width: 30, height: 30)
                        .background(Circle().fill(Color.primary.opacity(0.06)))
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .disabled(folder == ScanTree.root)
                .opacity(folder == ScanTree.root ? 0.35 : 1)
                .help("Go to the enclosing folder")
                .accessibilityLabel("Enclosing Folder")

                VStack(alignment: .leading, spacing: 3) {
                    Text(model.displayName(folder))
                        .font(Typo.heroTitle)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .contentTransition(.opacity)
                        .id(folder)
                        .transition(.asymmetric(insertion: .opacity.combined(with: .offset(x: model.zoomingOut ? -12 : 12)),
                                                removal: .opacity))
                    Breadcrumb()
                }
                .motion(Motion.spring, value: folder)

                Spacer(minLength: Space.m)

                VStack(alignment: .trailing, spacing: 1) {
                    CountUpBytes(bytes: tree.size(folder))
                        .font(Typo.heroNumber)
                        .foregroundStyle(LinearGradient.scan)
                    Text("\(Int(tree.fileCount(folder)).formatted()) files")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .contentTransition(.numericText())
                }
                .fixedSize()

                HStack(spacing: 6) {
                    Menu {
                        Button("Items in This Folder") { model.exportCSV(depth: 1) }
                        Button("Up to 2 Levels Deep") { model.exportCSV(depth: 2) }
                        Button("Up to 3 Levels Deep") { model.exportCSV(depth: 3) }
                        Button("Up to 5 Levels Deep") { model.exportCSV(depth: 5) }
                    } label: {
                        HeaderIcon(symbol: "square.and.arrow.up")
                    }
                    .menuStyle(.button)
                    .buttonStyle(.plain)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .help("Save this folder and its items as a CSV file")
                    .accessibilityLabel("Export as CSV")

                    Button {
                        model.rescan()
                    } label: {
                        HeaderIcon(symbol: "arrow.clockwise")
                    }
                    .buttonStyle(.plain)
                    .help("Rescan")
                    .accessibilityLabel("Rescan")
                }

                Picker("Map", selection: $model.mapStyle) {
                    ForEach(MapStyle.allCases) { style in
                        Label(style.label, systemImage: style.symbol).tag(style)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .help("Show the folder as a treemap or as rings")
            }
            .padding(.horizontal, Space.xl)
            .padding(.top, Space.xs)
            .padding(.bottom, Space.m)
            .overlay(alignment: .bottom) { Rectangle().fill(Palette.hairline).frame(height: 1) }
        }
    }
}

/// The filter for the lists: a rounded field with a magnifying glass and a clear button.
private struct FilterField: View {
    @Binding var text: String
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
            TextField("Filter by name", text: $text)
                .textFieldStyle(.plain)
                .focused($focused)
            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .transition(.opacity.combined(with: .scale(scale: 0.6)))
            }
        }
        .background(alignment: .topLeading) {
            // Hidden button: ⌘F moves the cursor into the filter, as the toolbar search field used to.
            Button { focused = true } label: { Color.clear.frame(width: 1, height: 1) }
                .keyboardShortcut("f", modifiers: .command)
                .opacity(0)
                .accessibilityHidden(true)
        }
        .font(.callout)
        .padding(.horizontal, 9)
        .frame(height: 26)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(0.05)))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
            .strokeBorder(focused ? Color.accentColor.opacity(0.6) : Palette.border, lineWidth: focused ? 1.5 : 1))
        .motion(Motion.quick, value: text.isEmpty)
        .motion(Motion.hover, value: focused)
    }
}

/// A round icon button of the header.
private struct HeaderIcon: View {
    @Environment(\.isEnabled) private var isEnabled
    let symbol: String
    @State private var hovering = false

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(hovering && isEnabled ? Color.accentColor : Color.secondary)
            .frame(width: 30, height: 30)
            .background(Circle().fill(Color.primary.opacity(hovering ? 0.10 : 0.06)))
            .contentShape(Circle())
            .opacity(isEnabled ? 1 : 0.4)
            .onHover { hovering = $0 }
    }
}

/// The path from the scanned location to the open folder. Each step goes back up to it.
private struct Breadcrumb: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 3) {
                ForEach(Array(model.breadcrumb.enumerated()), id: \.element) { position, node in
                    if position > 0 {
                        Image(systemName: "chevron.compact.right")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                    BreadcrumbStep(title: model.displayName(node), isCurrent: node == model.currentFolder,
                                   isRoot: position == 0) {
                        model.go(to: node)
                    }
                    .transition(.opacity.combined(with: .move(edge: .leading)))
                }
                if model.currentFolder == ScanTree.root, let root = model.tree?.rootPath {
                    Text((root as NSString).abbreviatingWithTildeInPath)
                        .font(.callout)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.head)
                        .transition(.opacity)
                }
            }
            .animation(Motion.quick.unless(reduceMotion), value: model.breadcrumb)
        }
        .frame(height: 20)
    }
}

private struct BreadcrumbStep: View {
    let title: String
    let isCurrent: Bool
    let isRoot: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if isRoot {
                    Image(systemName: "internaldrive").font(.caption2)
                }
                Text(title).lineLimit(1)
            }
            .font(.callout.weight(isCurrent ? .semibold : .regular))
            .foregroundStyle(isCurrent ? Color.primary : (hovering ? Color.accentColor : Color.secondary))
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(Capsule().fill(hovering && !isCurrent ? Color.accentColor.opacity(0.10) : .clear))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// The left half of the results: Folders or Biggest Files, the disk overview and the list.
struct ContentColumn: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model

        VStack(spacing: 0) {
            HStack(spacing: Space.s) {
                Picker("View", selection: $model.tab) {
                    ForEach(ContentTab.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                FilterField(text: $model.searchText)
            }
            .padding(.horizontal, Space.l)
            .padding(.top, Space.m)
            .padding(.bottom, Space.xs)

            DiskOverviewCard()

            ZStack {
                switch model.tab {
                case .folders: FolderListView().transition(.opacity)
                case .files: BiggestFilesView().transition(.opacity)
                }
            }
            .frame(maxHeight: .infinity)
            .motion(Motion.smooth, value: model.tab)
        }
        .background(Palette.content)
    }
}

/// The scan in progress: a turning ring with the files counted so far, and the folder being read.
struct ScanProgressView: View {
    @Environment(AppModel.self) private var model
    let progress: ScanProgress

    var body: some View {
        VStack(spacing: 16) {
            BusyRing(gradient: .scan, size: 150, lineWidth: 9, period: 1.4) {
                VStack(spacing: 2) {
                    Text(progress.files.formatted())
                        .font(.system(size: 24, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .contentTransition(.numericText(value: Double(progress.files)))
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                        .padding(.horizontal, 18)
                    Text("files").font(.caption).foregroundStyle(.secondary)
                }
            }
            .entrance(offset: 0, scale: 0.85)
            VStack(spacing: 6) {
                Text("Scanning…").font(.title3.weight(.semibold))
                Text(progress.bytes.bytes)
                    .font(.body.monospacedDigit())
                    .contentTransition(.numericText(value: Double(progress.bytes)))
                    .foregroundStyle(.secondary)
                Text(progress.currentPath)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: 360)
                    .contentTransition(.opacity)
            }
            .entrance(index: 1, offset: 10)
            Button("Cancel") { model.cancelScan() }
                .entrance(index: 2, offset: 10)
        }
        .motion(Motion.quick, value: progress.files)
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// The right half of the results: the treemap or the rings, and a caption about what is under the pointer.
struct DetailColumn: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack {
                switch model.mapStyle {
                case .treemap:
                    TreemapView().transition(.opacity.combined(with: .scale(scale: 0.97)))
                case .rings:
                    RingsView().transition(.opacity.combined(with: .scale(scale: 0.97)))
                }
            }
            .animation(Motion.smooth.unless(reduceMotion), value: model.mapStyle)
            .padding([.horizontal, .top], Space.m)
            .padding(.bottom, Space.s)

            HoverCaption()
                .padding(.horizontal, Space.l)
                .padding(.bottom, Space.m)
                .frame(height: 30)
        }
        .background(Palette.content)
    }
}

struct HoverCaption: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Group {
            if let tree = model.tree, let node = model.hovered ?? model.selection, !tree.flags(node).contains(.removed) {
                let category = model.category(of: node)
                HStack(spacing: 8) {
                    IconTile(symbol: category.symbol, gradient: .tile(category.color), size: 18)
                    Text(tree.name(node)).fontWeight(.medium).lineLimit(1)
                    Text(tree.size(node).bytes).foregroundStyle(.secondary).monospacedDigit()
                    if tree.flags(node).contains(.clone) {
                        Label(SpaceNotes.clone(node, in: tree), systemImage: "square.on.square")
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .transition(.opacity)
                    }
                    Spacer()
                    if tree.kind(node) == .directory {
                        Text(model.mapStyle == .rings ? "Click to open" : "Double-click to open").foregroundStyle(.tertiary)
                    }
                }
            } else {
                Text(model.mapStyle == .rings
                     ? "Hover a ring to see what it is. Click a folder to open it, or the centre to go up. Space shows Quick Look."
                     : "Hover a tile to see what it is. Click to select, double-click a folder to open it. Space shows Quick Look.")
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
        .font(.callout)
    }
}

/// When the shown results were scanned, and whether a fresh scan is running behind them.
struct ScanStatusNote: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            if let node = model.rescanningNode, let tree = model.tree {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini)
                    Text("Rescanning \(tree.name(node))…")
                }
                .transition(.opacity.combined(with: .move(edge: .trailing)))
            } else if model.isRefreshing {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini)
                    if let date = model.scannedAt { ScannedAgo(date: date) }
                    Text("·")
                    Text(updatingText)
                        .monospacedDigit()
                        .contentTransition(.numericText())
                    Button("Stop") { model.cancelScan() }
                        .buttonStyle(.link)
                }
                .transition(.opacity.combined(with: .move(edge: .trailing)))
            } else if let date = model.scannedAt {
                HStack(spacing: 6) {
                    if let error = model.refreshError {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange).help(error)
                    } else {
                        Image(systemName: "clock")
                    }
                    ScannedAgo(date: date)
                    Text("·")
                    Button("Rescan") { model.rescan() }
                        .buttonStyle(.link)
                }
                .transition(.opacity.combined(with: .move(edge: .trailing)))
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .animation(Motion.quick.unless(reduceMotion), value: model.isRefreshing)
        .animation(Motion.quick.unless(reduceMotion), value: model.rescanningNode)
    }

    private var updatingText: String {
        guard let progress = model.refreshProgress else { return String(localized: "Updating…") }
        return String(format: String(localized: "Updating · %@ files…"), progress.files.formatted())
    }
}

private struct ScannedAgo: View {
    let date: Date

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            let seconds = context.date.timeIntervalSince(date)
            Text(seconds < 60 ? "Scanned just now" : "Scanned \(date.formatted(.relative(presentation: .named)))")
        }
    }
}
