import RoomyCore
import SwiftUI

/// The sky-blue-to-indigo gradient used for Cloud Space.
extension LinearGradient {
    static let cloudSpace = LinearGradient(
        colors: [Color(red: 0.35, green: 0.73, blue: 0.96), Color(red: 0.42, green: 0.42, blue: 0.90)],
        startPoint: .topLeading, endPoint: .bottomTrailing
    )
}

extension CloudProvider.Kind {
    var symbol: String { self == .iCloudDrive ? "icloud.fill" : "cloud.fill" }

    var color: Color {
        switch self {
        case .iCloudDrive: return Color(red: 0.29, green: 0.60, blue: 0.95)
        case .dropbox: return Color(red: 0.20, green: 0.45, blue: 0.90)
        case .oneDrive: return Color(red: 0.20, green: 0.62, blue: 0.85)
        case .googleDrive: return Color(red: 0.30, green: 0.68, blue: 0.45)
        case .box: return Color(red: 0.25, green: 0.50, blue: 0.80)
        case .other: return Color(red: 0.50, green: 0.50, blue: 0.75)
        }
    }
}

/// A cloud symbol that floats gently up and down. Still with Reduce Motion.
struct FloatingCloud: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var symbol = "icloud.fill"
    var size: CGFloat = 22
    var distance: CGFloat = 3
    @State private var up = false

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size, weight: .semibold))
            .offset(y: up && !reduceMotion ? -distance : distance * 0.3)
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.easeInOut(duration: 1.8).repeatForever(autoreverses: true)) { up = true }
            }
            .accessibilityHidden(true)
    }
}

/// Cloud Space: removes the downloaded copies of cloud files to free space. The files stay in the cloud.
struct CloudSpaceView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var confirm = false

    var body: some View {
        let cloud = model.cloudSpace

        VStack(spacing: 0) {
            CloudSpaceHeader()
            Divider()
            ZStack {
                switch cloud.phase {
                case .idle:
                    ContentUnavailableView {
                        Label("Ready to look", systemImage: "icloud")
                    } actions: {
                        Button("Find Downloaded Files") { cloud.find() }
                            .buttonStyle(.borderedProminent)
                    }
                    .transition(.opacity)
                case .finding:
                    CloudFindingProgress()
                        .transition(.opacity)
                case .ready:
                    Group {
                        if !cloud.hasProviders {
                            NoCloudFolders()
                        } else if cloud.findings.providers.isEmpty {
                            NothingDownloaded()
                        } else {
                            CloudResults()
                        }
                    }
                    .transition(.opacity.combined(with: .scale(scale: 0.98)))
                case .evicting:
                    EvictingRing()
                        .padding(32)
                        .transition(.opacity.combined(with: .scale(scale: 0.95)))
                case .done:
                    let report = cloud.report
                    let count = report?.succeeded.count ?? 0
                    let names = CloudSpaceModel.names(cloud.evictedProviders)
                    FreedSpaceCelebration(
                        bytes: cloud.evictedBytes,
                        message: "Removed the local copies of \(count) \(count == 1 ? "file" : "files"). They stay in \(names) and download again when you open them.",
                        succeeded: count > 0 || (report?.failed.isEmpty ?? true),
                        suffix: " freed — still in the cloud"
                    ) {
                        if let failed = report?.failed, !failed.isEmpty {
                            KeptFilesList(results: failed).frame(maxWidth: 460)
                        }
                    }
                    .transition(.opacity.combined(with: .scale(scale: 0.9)))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .animation(Motion.smooth.unless(reduceMotion), value: cloud.phase)
            Divider()
            footer
        }
        .frame(minWidth: 780, idealWidth: 860, minHeight: 600, idealHeight: 720)
        .interactiveDismissDisabled(cloud.isBusy)
        .alert("Remove the downloaded copies of \(cloud.selectedItems.count) \(cloud.selectedItems.count == 1 ? "file" : "files")?",
               isPresented: $confirm) {
            Button("Remove Downloads") { cloud.removeDownloads() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This frees about \(cloud.selectedBytes.bytes) on this Mac. Nothing is deleted: the files stay in \(CloudSpaceModel.names(cloud.selectedProviders)) and download again when you open them.")
        }
    }

    @ViewBuilder
    private var footer: some View {
        let cloud = model.cloudSpace
        HStack(spacing: 10) {
            switch cloud.phase {
            case .idle:
                Spacer()
                Button("Close") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            case .finding:
                Spacer()
                Button("Cancel") {
                    cloud.cancel()
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
            case .ready:
                Label("Files stay in \(CloudSpaceModel.names(cloud.selectedProviders)) and download again when you open them.",
                      systemImage: "icloud.and.arrow.down")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .contentTransition(.opacity)
                    .animation(Motion.quick.unless(reduceMotion), value: cloud.selectedProviders)
                Spacer()
                if cloud.hasProviders {
                    Button("Look Again") { cloud.find() }
                }
                Button("Close") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                if cloud.hasProviders {
                    Button {
                        confirm = true
                    } label: {
                        Label("Remove Downloads", systemImage: "icloud.and.arrow.up").padding(.horizontal, 6)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(cloud.selectedItems.isEmpty)
                }
            case .evicting:
                Spacer()
                Text("Please wait…").foregroundStyle(.secondary)
            case .done:
                Spacer()
                Button("Show Remaining") { cloud.showRemaining() }
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(.horizontal, 18)
        .frame(height: 56)
    }
}

private struct CloudSpaceHeader: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let cloud = model.cloudSpace
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous).fill(LinearGradient.cloudSpace)
                FloatingCloud(size: 21, distance: 2)
                    .foregroundStyle(.white)
            }
            .frame(width: 46, height: 46)

            VStack(alignment: .leading, spacing: 3) {
                Text("Cloud Space").font(.title2.weight(.semibold))
                Text("Free space without deleting: remove local copies of files that are safe in the cloud.")
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer()
            if cloud.phase == .ready && !cloud.findings.providers.isEmpty {
                VStack(alignment: .trailing, spacing: 2) {
                    Text(cloud.selectedBytes.bytes)
                        .font(.system(size: 26, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .contentTransition(.numericText(value: Double(cloud.selectedBytes)))
                        .animation(Motion.quick.unless(reduceMotion), value: cloud.selectedBytes)
                    Text("\(cloud.selectedItems.count) \(cloud.selectedItems.count == 1 ? "file" : "files") ticked")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .contentTransition(.numericText())
                        .animation(Motion.quick.unless(reduceMotion), value: cloud.selectedItems.count)
                }
                .transition(.opacity.combined(with: .move(edge: .trailing)))
            }
        }
        .padding(18)
        .animation(Motion.smooth.unless(reduceMotion), value: cloud.phase)
    }
}

/// The turning ring while cloud folders are read, with the provider and files checked so far.
private struct CloudFindingProgress: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let cloud = model.cloudSpace
        VStack(spacing: 18) {
            BusyRing(gradient: .cloudSpace, size: 150, lineWidth: 9, period: 1.4) {
                FloatingCloud(size: 40, distance: 4)
                    .foregroundStyle(LinearGradient.cloudSpace)
            }
            if let progress = cloud.progress {
                Text("Checking \(progress.provider)…").font(.title3)
                Text("\(progress.filesChecked.formatted()) files checked")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .contentTransition(.numericText())
            } else {
                Text("Looking for cloud folders…").font(.title3)
            }
            Text("Files are only read. Nothing is changed yet.")
                .font(.callout)
                .foregroundStyle(.tertiary)
        }
        .padding(32)
    }
}

/// The ring while local copies are removed: it fills as files go, and the space still to free counts down.
private struct EvictingRing: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let cloud = model.cloudSpace
        VStack(spacing: 20) {
            ZStack {
                Circle().stroke(Color.primary.opacity(0.08), lineWidth: 12)
                Circle()
                    .trim(from: 0, to: max(0.02, cloud.evictFraction))
                    .stroke(LinearGradient.cloudSpace, style: StrokeStyle(lineWidth: 12, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(Motion.smooth.unless(reduceMotion), value: cloud.evictFraction)
                VStack(spacing: 4) {
                    FloatingCloud(symbol: "icloud.and.arrow.up", size: 22, distance: 3)
                        .foregroundStyle(LinearGradient.cloudSpace)
                    Text(cloud.bytesLeft.bytes)
                        .font(.system(size: 26, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .contentTransition(.numericText(value: Double(cloud.bytesLeft)))
                        .animation(Motion.quick.unless(reduceMotion), value: cloud.bytesLeft)
                    Text("left on this Mac").font(.caption).foregroundStyle(.secondary)
                }
            }
            .frame(width: 190, height: 190)
            Text("Removing \(min(cloud.evictedCount + 1, cloud.evictTotal)) of \(cloud.evictTotal)…")
                .font(.title3)
                .monospacedDigit()
                .contentTransition(.numericText())
                .animation(Motion.quick.unless(reduceMotion), value: cloud.evictedCount)
        }
    }
}

// MARK: Empty states

/// The services Cloud Space knows, shown as small chips.
private struct ProviderChips: View {
    let kinds: [(CloudProvider.Kind, String)]

    var body: some View {
        HStack(spacing: 8) {
            ForEach(Array(kinds.enumerated()), id: \.offset) { index, entry in
                HStack(spacing: 5) {
                    Image(systemName: entry.0.symbol).foregroundStyle(entry.0.color)
                    Text(entry.1)
                }
                .font(.callout)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Capsule().fill(entry.0.color.opacity(0.10)))
                .overlay(Capsule().strokeBorder(entry.0.color.opacity(0.25), lineWidth: 1))
                .entrance(index: index + 2, offset: 8)
            }
        }
    }
}

/// A big floating cloud with a soft glow, for the empty states.
private struct CloudHero: View {
    var symbol = "icloud"

    var body: some View {
        ZStack {
            Circle()
                .fill(LinearGradient.cloudSpace)
                .opacity(0.12)
                .frame(width: 150, height: 150)
            Circle()
                .fill(LinearGradient.cloudSpace)
                .opacity(0.10)
                .frame(width: 110, height: 110)
            FloatingCloud(symbol: symbol, size: 56, distance: 5)
                .foregroundStyle(LinearGradient.cloudSpace)
        }
        .entrance(offset: 10, scale: 0.9)
    }
}

/// Shown when this Mac has no iCloud Drive and no File Provider clouds.
private struct NoCloudFolders: View {
    var body: some View {
        VStack(spacing: 16) {
            CloudHero(symbol: "icloud.slash")
            Text("No cloud folders on this Mac")
                .font(.title2.weight(.semibold))
                .entrance(index: 1, offset: 8)
            Text("When iCloud Drive, Dropbox, OneDrive, Google Drive or Box keeps files here, RoomyDisk can remove their downloaded copies to free space. The files stay in the cloud and download again when you open them.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 480)
                .entrance(index: 1, offset: 8)
            ProviderChips(kinds: [
                (.iCloudDrive, "iCloud Drive"), (.dropbox, "Dropbox"), (.oneDrive, "OneDrive"),
                (.googleDrive, "Google Drive"), (.box, "Box"),
            ])
            .padding(.top, 4)
        }
        .padding(32)
    }
}

/// Shown when cloud folders exist but every file is already only in the cloud.
private struct NothingDownloaded: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let cloud = model.cloudSpace
        VStack(spacing: 16) {
            CloudHero(symbol: "checkmark.icloud")
            Text("Nothing to free")
                .font(.title2.weight(.semibold))
                .entrance(index: 1, offset: 8)
            Text("No files in your cloud folders have a local copy that is safe to remove.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 480)
                .entrance(index: 1, offset: 8)
            ProviderChips(kinds: cloud.providers.map { ($0.kind, $0.title) })
                .padding(.top, 4)
        }
        .padding(32)
    }
}

// MARK: Results

private struct CloudResults: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let cloud = model.cloudSpace
        ScrollView {
            VStack(spacing: 10) {
                ForEach(Array(cloud.findings.providers.enumerated()), id: \.element.id) { index, provider in
                    ProviderCard(provider: provider, index: index)
                }
                if cloud.findings.capped {
                    Text("Very large cloud folders were only partly checked (\(CloudSpaceFinder.fileLimit.formatted()) files each).")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(16)
        }
    }
}

/// One provider: how much of it is on this Mac, and its folders when opened.
private struct ProviderCard: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let provider: CloudProviderFindings
    let index: Int

    var body: some View {
        let cloud = model.cloudSpace
        let state = cloud.selection.state(of: provider)
        let isExpanded = cloud.expanded.contains(provider.id)
        let kind = provider.provider.kind
        let canTick = provider.evictableBytes > 0

        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 12) {
                SelectionBox(state: state, color: kind.color) {
                    withAnimation(Motion.quick.unless(reduceMotion)) {
                        cloud.setAll(provider, selected: state != .all)
                    }
                }
                .padding(.top, 8)
                .opacity(canTick ? 1 : 0)
                .disabled(!canTick)

                ZStack {
                    Circle().fill(kind.color.gradient)
                    FloatingCloud(symbol: kind.symbol, size: 15, distance: 1.5)
                        .foregroundStyle(.white)
                }
                .frame(width: 34, height: 34)

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(provider.provider.title).font(.headline)
                        if provider.keptCount > 0 {
                            Badge(text: "\(provider.keptCount) not uploaded yet", color: .orange)
                        }
                    }
                    Text(note)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 12)

                VStack(alignment: .trailing, spacing: 3) {
                    CountingBytes(provider.evictableBytes)
                        .font(.title3.weight(.semibold))
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .contentTransition(.numericText())
                }
                .animation(Motion.quick.unless(reduceMotion), value: cloud.selectedBytes)

                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    .padding(.top, 8)
            }
            .padding(14)
            .contentShape(Rectangle())
            .onTapGesture {
                withAnimation(Motion.spring.unless(reduceMotion)) { cloud.toggleExpanded(provider) }
            }

            if isExpanded {
                Divider().padding(.horizontal, 14)
                VStack(spacing: 0) {
                    ForEach(Array(provider.groups.enumerated()), id: \.element.id) { rowIndex, group in
                        FolderRow(group: group, color: kind.color)
                            .entrance(index: rowIndex, offset: 8, scale: 1)
                    }
                }
                .padding(.vertical, 6)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.primary.opacity(0.04)))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(state == .none ? Color.primary.opacity(0.08) : kind.color.opacity(0.55), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .entrance(index: index)
    }

    private var note: String {
        let base = "Files stay in \(provider.provider.name) and download again when you open them."
        if provider.provider.kind == .iCloudDrive {
            return base + " If Optimize Mac Storage is off in iCloud settings, macOS may download them again on its own."
        }
        return base
    }

    private var subtitle: String {
        let selected = model.cloudSpace.selection.selectedBytes(in: CloudSpaceFinder.Findings(providers: [provider]))
        if selected > 0 { return "\(selected.bytes) ticked" }
        if provider.keptBytes > 0 { return "on this Mac · \(provider.keptBytes.bytes) kept" }
        return "on this Mac"
    }
}

/// One folder of a provider: its local copies, how many are kept, and a tick.
private struct FolderRow: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let group: CloudFolderGroup
    let color: Color
    @State private var hovering = false

    var body: some View {
        let cloud = model.cloudSpace
        let ticked = cloud.selection.contains(group)
        let canTick = !group.evictable.isEmpty
        HStack(spacing: 10) {
            SelectionBox(state: ticked ? .all : .none, color: color) {
                withAnimation(Motion.quick.unless(reduceMotion)) { cloud.toggle(group) }
            }
            .opacity(canTick ? 1 : 0.3)
            .disabled(!canTick)
            Image(systemName: group.name == CloudLocations.topLevel ? "tray.full.fill" : "folder.fill")
                .foregroundStyle(color)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 1) {
                Text(group.name).lineLimit(1).truncationMode(.middle)
                HStack(spacing: 6) {
                    Text("\(group.evictable.count) \(group.evictable.count == 1 ? "file" : "files") downloaded")
                    if !group.kept.isEmpty {
                        Text("·")
                        Label("\(group.kept.count) not uploaded yet — kept", systemImage: "icloud.and.arrow.up")
                            .foregroundStyle(.orange)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
            Spacer(minLength: 8)
            Text(group.evictableBytes.bytes)
                .monospacedDigit()
                .foregroundStyle(.secondary)
            Button { cloud.reveal(group.path) } label: { Image(systemName: "magnifyingglass") }
                .buttonStyle(.borderless)
                .help("Show in Finder")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 5)
        .background(hovering ? Color.primary.opacity(0.04) : Color.clear)
        .contentShape(Rectangle())
        .onHover { inside in withAnimation(Motion.hover.unless(reduceMotion)) { hovering = inside } }
        .contextMenu {
            Button("Show in Finder") { cloud.reveal(group.path) }
        }
    }
}

/// Files whose local copies were kept or could not be removed, folded away.
private struct KeptFilesList: View {
    let results: [CloudEvictionResult]

    var body: some View {
        DisclosureGroup("\(results.count) kept on this Mac") {
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(results, id: \.path) { result in
                        VStack(alignment: .leading, spacing: 1) {
                            Text((result.path as NSString).lastPathComponent)
                            Text(result.error ?? "Unknown error").font(.caption).foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(.top, 4)
            }
            .frame(maxHeight: 160)
        }
        .foregroundStyle(.orange)
    }
}
