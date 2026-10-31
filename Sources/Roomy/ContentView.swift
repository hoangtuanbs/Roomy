import AppKit
import RoomyCore
import SwiftUI

struct ContentView: View {
    @Environment(AppModel.self) private var model

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
            Divider()
            BottomBar()
        }
        .sheet(isPresented: $model.showReview) {
            ReviewSheet().environment(model)
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

            switch model.state {
            case .idle:
                ContentUnavailableView(
                    "Choose a location",
                    systemImage: "internaldrive",
                    description: Text("Pick your home folder or a disk in the sidebar, or drop a folder here, to see what is using space.")
                )
            case .scanning(let progress):
                ScanProgressView(progress: progress)
            case .failed(let message):
                ContentUnavailableView("Scan failed", systemImage: "exclamationmark.triangle", description: Text(message))
            case .ready:
                switch model.tab {
                case .folders: FolderListView()
                case .files: BiggestFilesView()
                }
            }
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
                    model.rescan()
                } label: {
                    Label("Rescan", systemImage: "arrow.clockwise")
                }
                .disabled(model.tree == nil && !model.state.isScanning)
            }
        }
    }
}

struct ScanProgressView: View {
    @Environment(AppModel.self) private var model
    let progress: ScanProgress

    var body: some View {
        VStack(spacing: 14) {
            ProgressView().controlSize(.large)
            Text("Scanning…").font(.title3.weight(.semibold))
            Text("\(progress.files.formatted()) files · \(progress.bytes.bytes)")
                .font(.body.monospacedDigit())
                .foregroundStyle(.secondary)
            Text(progress.currentPath)
                .font(.caption)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 360)
            Button("Cancel") { model.cancelScan() }
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct DetailColumn: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let tree = model.tree, case .ready = model.state {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .firstTextBaseline) {
                    Text(model.currentFolder == ScanTree.root ? tree.rootPath : tree.name(model.currentFolder))
                        .font(.headline)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Text(tree.size(model.currentFolder).bytes)
                        .font(.headline.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)

                TreemapView()
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
                    Text("Click to open").foregroundStyle(.tertiary)
                }
            }
            .font(.callout)
        } else {
            Text("Hover a tile to see what it is. Click a folder to open it.")
                .font(.callout)
                .foregroundStyle(.tertiary)
        }
    }
}

struct BottomBar: View {
    @Environment(AppModel.self) private var model

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
                                model.currentFolder = node
                            }
                            .buttonStyle(.borderless)
                            .foregroundStyle(node == model.currentFolder ? Color.primary : Color.secondary)
                        }
                    }
                }
            } else {
                Spacer()
            }

            Spacer(minLength: 12)

            if !model.basket.isEmpty {
                Text("\(model.basket.count) \(model.basket.count == 1 ? "item" : "items"), \(model.basketBytes.bytes) selected")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                Button("Clear") { model.basket = [] }
            }
            Button("Review and Clean…") { model.showReview = true }
                .buttonStyle(.borderedProminent)
                .disabled(model.basket.isEmpty)
        }
        .padding(.horizontal, 14)
        .frame(height: 46)
        .background(.bar)
    }
}
