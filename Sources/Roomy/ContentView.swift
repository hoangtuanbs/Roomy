import AppKit
import RoomyCore
import SwiftUI

struct ContentView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        @Bindable var model = model

        VStack(spacing: 0) {
            NavigationSplitView {
                SidebarView()
                    .navigationSplitViewColumnWidth(min: 190, ideal: 220, max: 300)
            } content: {
                ContentColumn()
                    .navigationSplitViewColumnWidth(min: 360, ideal: 440)
            } detail: {
                DetailColumn()
            }
            if model.tree != nil {
                Divider()
                TrayView()
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            Divider()
            BottomBar()
        }
        .animation(Motion.spring.unless(reduceMotion), value: model.tree != nil)
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

struct ContentColumn: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model

        VStack(spacing: 0) {
            Picker("View", selection: $model.tab) {
                ForEach(ContentTab.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            Divider()

            ZStack {
                switch model.state {
                case .idle:
                    ContentUnavailableView(
                        "Choose a location",
                        systemImage: "internaldrive",
                        description: Text("Pick your home folder or a disk in the sidebar, or drop a folder here, to see what is using space.")
                    )
                    .transition(.opacity)
                case .scanning(let progress):
                    ScanProgressView(progress: progress)
                        .transition(.opacity.combined(with: .scale(scale: 0.96)))
                case .failed(let message):
                    ContentUnavailableView("Scan failed", systemImage: "exclamationmark.triangle", description: Text(message))
                        .transition(.opacity)
                case .ready:
                    VStack(spacing: 0) {
                        DiskOverviewCard()
                        Divider()
                        ZStack {
                            switch model.tab {
                            case .folders: FolderListView().transition(.opacity)
                            case .files: BiggestFilesView().transition(.opacity)
                            }
                        }
                        .frame(maxHeight: .infinity)
                        .motion(Motion.smooth, value: model.tab)
                    }
                    .task(id: model.treeVersion) { model.refreshDiskOverview() }
                    .transition(.opacity)
                }
            }
            .frame(maxHeight: .infinity)
            .motion(Motion.smooth, value: model.state.phase)
        }
        .searchable(text: $model.searchText, placement: .toolbar, prompt: "Filter by name")
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button {
                    model.goUp()
                } label: {
                    Label("Enclosing Folder", systemImage: "chevron.left")
                }
                .disabled(model.tree == nil || model.currentFolder == ScanTree.root)
            }
            ToolbarItem {
                Button {
                    model.openSmartClean()
                } label: {
                    Label("Smart Clean", systemImage: "sparkles")
                }
                .help("Find caches, logs and leftovers that are safe to remove")
            }
            ToolbarItem {
                Button {
                    model.openDuplicates()
                } label: {
                    Label("Duplicates", systemImage: "doc.on.doc")
                }
                .help("Find identical files that take up space more than once")
            }
            ToolbarItem {
                Button {
                    model.openUninstaller()
                } label: {
                    Label("Uninstaller", systemImage: "xmark.bin")
                }
                .help("Remove apps together with the files they leave behind")
            }
            ToolbarItem {
                Button {
                    model.openSpaceHunters()
                } label: {
                    Label("Space Hunters", systemImage: "scope")
                }
                .help("Find old backups, downloads, Mail attachments and similar photos")
            }
            ToolbarItem {
                Button {
                    model.openCloudSpace()
                } label: {
                    Label("Cloud Space", systemImage: "icloud")
                }
                .help("Free space by removing downloaded copies of cloud files; they stay in the cloud")
            }
            ToolbarItem {
                Menu {
                    Button("Items in This Folder") { model.exportCSV(depth: 1) }
                    Button("Up to 2 Levels Deep") { model.exportCSV(depth: 2) }
                    Button("Up to 3 Levels Deep") { model.exportCSV(depth: 3) }
                    Button("Up to 5 Levels Deep") { model.exportCSV(depth: 5) }
                } label: {
                    Label("Export as CSV", systemImage: "tablecells")
                }
                .disabled(model.tree == nil)
                .help("Save this folder and its items as a CSV file")
            }
            ToolbarItem {
                Button {
                    model.rescan()
                } label: {
                    Label("Rescan", systemImage: "arrow.clockwise")
                }
                .disabled(model.tree == nil && !model.state.isScanning)
            }
        }
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

struct DetailColumn: View {
    @Environment(AppModel.self) private var model

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        @Bindable var model = model

        if let tree = model.tree, case .ready = model.state {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .center, spacing: 10) {
                    Text(model.currentFolder == ScanTree.root ? tree.rootPath : tree.name(model.currentFolder))
                        .font(.headline)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    CountingBytes(tree.size(model.currentFolder))
                        .font(.headline)
                        .foregroundStyle(.secondary)
                        .animation(Motion.smooth.unless(reduceMotion), value: tree.size(model.currentFolder))
                    Picker("Map", selection: $model.mapStyle) {
                        ForEach(MapStyle.allCases) { style in
                            Label(style.rawValue, systemImage: style.symbol).tag(style)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                    .help("Show the folder as a treemap or as rings")
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)

                ZStack {
                    switch model.mapStyle {
                    case .treemap:
                        TreemapView().transition(.opacity.combined(with: .scale(scale: 0.97)))
                    case .rings:
                        RingsView().transition(.opacity.combined(with: .scale(scale: 0.97)))
                    }
                }
                .animation(Motion.smooth.unless(reduceMotion), value: model.mapStyle)
                .padding([.horizontal, .bottom], 12)

                HoverCaption()
                    .padding(.horizontal, 16)
                    .padding(.bottom, 10)
            }
        } else {
            ContentUnavailableView("No scan yet", systemImage: "square.grid.3x3.square", description: Text("The map of your folders appears here."))
        }
    }
}

struct HoverCaption: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let tree = model.tree, let node = model.hovered {
            HStack(spacing: 6) {
                Image(systemName: model.category(of: node).symbol)
                    .foregroundStyle(model.category(of: node).color)
                Text(tree.name(node)).lineLimit(1)
                Text(tree.size(node).bytes).foregroundStyle(.secondary).monospacedDigit()
                Spacer()
                if tree.kind(node) == .directory {
                    Text(model.mapStyle == .rings ? "Click to open" : "Double-click to open").foregroundStyle(.tertiary)
                }
            }
            .font(.callout)
        } else {
            Text(model.mapStyle == .rings
                 ? "Hover a ring to see what it is. Click a folder to open it, or the centre to go up. Space shows Quick Look."
                 : "Hover a tile to see what it is. Click to select, double-click a folder to open it. Space shows Quick Look.")
                .font(.callout)
                .foregroundStyle(.tertiary)
        }
    }
}

struct BottomBar: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 10) {
            if let tree = model.tree {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 2) {
                        ForEach(Array(model.breadcrumb.enumerated()), id: \.element) { position, node in
                            if position > 0 {
                                Image(systemName: "chevron.right")
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }
                            Button(node == ScanTree.root ? tree.rootPath : tree.name(node)) {
                                model.go(to: node)
                            }
                            .buttonStyle(.borderless)
                            .foregroundStyle(node == model.currentFolder ? Color.primary : Color.secondary)
                        }
                    }
                    .animation(Motion.quick.unless(reduceMotion), value: model.breadcrumb)
                }
            } else {
                Spacer()
            }

            Spacer(minLength: 12)

            ScanStatusNote()
        }
        .padding(.horizontal, 14)
        .frame(height: 34)
        .background(.bar)
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
        guard let progress = model.refreshProgress else { return "Updating…" }
        return "Updating · \(progress.files.formatted()) files…"
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
