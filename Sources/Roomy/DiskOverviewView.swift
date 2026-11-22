import RoomyCore
import SwiftUI

/// The four parts of a disk in the overview bar.
enum DiskPart: Int, CaseIterable, Identifiable {
    case scanned, hidden, purgeable, free
    var id: Self { self }

    func title(wholeDisk: Bool) -> String {
        switch self {
        case .scanned: return wholeDisk ? "Scanned" : "This folder"
        case .hidden: return wholeDisk ? "Hidden" : "Rest of disk"
        case .purgeable: return "Purgeable"
        case .free: return "Free"
        }
    }

    func bytes(in space: DiskSpace) -> Int64 {
        switch self {
        case .scanned: return space.scanned
        case .hidden: return space.hidden
        case .purgeable: return space.purgeableShown
        case .free: return space.free
        }
    }
}

/// A card above the results with a segmented bar of the scanned disk: what the scan found, what is hidden,
/// what macOS can purge and what is free, plus the disk's local snapshots.
struct DiskOverviewCard: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage("diskOverviewExpanded") private var expanded = true
    @State private var grown = false
    @State private var explaining: DiskPart?
    @State private var hovered: DiskPart?
    @State private var confirmDelete: LocalSnapshot?
    @State private var confirmThin = false

    var body: some View {
        let disk = model.diskOverview
        Group {
            if let space = disk.space {
                VStack(alignment: .leading, spacing: 10) {
                    header(space)
                    CapacityBar(space: space, grown: grown, hovered: $hovered) { part in explaining = part }
                    legend(space)
                    if expanded {
                        SnapshotSection(confirmDelete: $confirmDelete)
                            .transition(.opacity.combined(with: .move(edge: .top)))
                    }
                    if let message = disk.errorMessage {
                        ErrorBanner(message: message)
                            .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .top)))
                    }
                }
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.primary.opacity(0.04)))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.primary.opacity(0.06)))
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .animation(Motion.smooth.unless(reduceMotion), value: space)
                .animation(Motion.spring.unless(reduceMotion), value: expanded)
                .animation(Motion.smooth.unless(reduceMotion), value: disk.errorMessage)
                .transition(.opacity.combined(with: .move(edge: .top)))
                .onAppear(perform: grow)
            }
        }
        .confirmationDialog(
            deleteTitle,
            isPresented: Binding(get: { confirmDelete != nil }, set: { if !$0 { confirmDelete = nil } }),
            presenting: confirmDelete
        ) { snapshot in
            Button("Delete Snapshot", role: .destructive) {
                disk.delete(snapshot, scanned: model.scannedBytes)
            }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("Time Machine uses local snapshots to restore files when your backup disk is not connected. Deleting this one cannot be undone.")
        }
        .confirmationDialog("Free purgeable space?", isPresented: $confirmThin) {
            Button("Remove Snapshots", role: .destructive) {
                disk.freePurgeable(scanned: model.scannedBytes)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Time Machine removes local snapshots on this disk, oldest first, until up to \((disk.space?.purgeable ?? 0).bytes) is free. Removed snapshots cannot be brought back. macOS also does this on its own when it needs room.")
        }
    }

    private var deleteTitle: String {
        guard let date = confirmDelete?.date else { return "Delete this local snapshot?" }
        return "Delete the local snapshot from \(date.formatted(date: .abbreviated, time: .shortened))?"
    }

    private func header(_ space: DiskSpace) -> some View {
        let disk = model.diskOverview
        return HStack(spacing: 8) {
            Image(systemName: disk.isWholeDisk ? "internaldrive.fill" : "internaldrive")
                .foregroundStyle(LinearGradient.smartClean)
            Text(disk.volumeName).font(.headline).lineLimit(1)
            HStack(spacing: 0) {
                CountingBytes(grown ? space.used : 0)
                Text(" used of \(space.total.bytes)")
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            if let freed = disk.freedBytes {
                FreedPill(bytes: freed)
                    .transition(.scale(scale: 0.6).combined(with: .opacity))
            }
            Button {
                expanded.toggle()
            } label: {
                HStack(spacing: 4) {
                    if !expanded, !disk.snapshots.isEmpty {
                        Text("\(disk.snapshots.count) \(disk.snapshots.count == 1 ? "snapshot" : "snapshots")")
                            .font(.caption)
                    }
                    Image(systemName: "chevron.down")
                        .font(.caption.weight(.semibold))
                        .rotationEffect(.degrees(expanded ? 0 : -90))
                }
                .foregroundStyle(.secondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(expanded ? "Hide local snapshots" : "Show local snapshots")
        }
        .animation(Motion.bouncy.unless(reduceMotion), value: disk.freedBytes)
    }

    private func legend(_ space: DiskSpace) -> some View {
        let disk = model.diskOverview
        return HStack(alignment: .top, spacing: 16) {
            ForEach(DiskPart.allCases) { part in
                Button {
                    explaining = part
                } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Circle().fill(part.color).frame(width: 8, height: 8)
                        VStack(alignment: .leading, spacing: 1) {
                            HStack(spacing: 3) {
                                Text(part.title(wholeDisk: disk.isWholeDisk))
                                if part == .hidden && disk.isWholeDisk && !model.hasFullDiskAccess {
                                    Image(systemName: "lock.fill").foregroundStyle(.orange)
                                }
                                if part == .hidden || part == .purgeable {
                                    Image(systemName: "info.circle").foregroundStyle(.tertiary)
                                }
                            }
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            CountingBytes(grown ? part.bytes(in: space) : 0)
                                .font(.callout.weight(.semibold))
                        }
                    }
                    .padding(.horizontal, 4)
                    .padding(.vertical, 2)
                    .background(RoundedRectangle(cornerRadius: 6).fill(hovered == part ? part.color.opacity(0.12) : .clear))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .onHover { inside in
                    withAnimation(Motion.quick.unless(reduceMotion)) {
                        if inside { hovered = part } else if hovered == part { hovered = nil }
                    }
                }
                .help(part == .hidden && disk.isWholeDisk && !model.hasFullDiskAccess
                      ? "Full Disk Access is off, so some files could not be read. Click to learn more."
                      : "Click to learn what this is")
                .popover(isPresented: Binding(get: { explaining == part }, set: { if !$0 { explaining = nil } }),
                         arrowEdge: .bottom) {
                    PartExplanation(part: part, close: { explaining = nil }, freePurgeable: {
                        explaining = nil
                        confirmThin = true
                    })
                    .environment(model)
                }
            }
            Spacer(minLength: 0)
        }
    }

    private func grow() {
        guard !grown else { return }
        withAnimation(Motion.stagger(1).unless(reduceMotion)) { grown = true }
    }

}

/// The segmented capacity bar. The track is the free space; the used parts grow in from the left.
private struct CapacityBar: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let space: DiskSpace
    let grown: Bool
    @Binding var hovered: DiskPart?
    let onTap: (DiskPart) -> Void

    private let gap: CGFloat = 2

    var body: some View {
        GeometryReader { geo in
            let fractions = space.fractions
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(DiskPart.free.color.opacity(hovered == .free ? 1 : 0.7))
                    .contentShape(Rectangle())
                    .onTapGesture { onTap(.free) }
                    .onHover { hover(.free, $0) }
                HStack(spacing: gap) {
                    ForEach([DiskPart.scanned, .hidden, .purgeable]) { part in
                        let fraction = fractions[part.rawValue]
                        if fraction > 0 {
                            Rectangle()
                                .fill(part.color.gradient)
                                .brightness(hovered == part ? 0.08 : 0)
                                .frame(width: grown ? max(2, geo.size.width * fraction - gap) : 0)
                                .animation(Motion.stagger(part.rawValue + 1).unless(reduceMotion), value: grown)
                                .contentShape(Rectangle())
                                .onTapGesture { onTap(part) }
                                .onHover { hover(part, $0) }
                        }
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
            }
            .scaleEffect(y: hovered == nil || reduceMotion ? 1 : 1.12)
        }
        .frame(height: 14)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Disk use")
        .accessibilityValue("\(space.scanned.bytes) scanned, \(space.hidden.bytes) hidden, \(space.purgeableShown.bytes) purgeable, \(space.free.bytes) free")
    }

    private func hover(_ part: DiskPart, _ inside: Bool) {
        withAnimation(Motion.quick.unless(reduceMotion)) {
            if inside { hovered = part } else if hovered == part { hovered = nil }
        }
    }
}

/// What a part of the bar is, shown when it is clicked.
private struct PartExplanation: View {
    @Environment(AppModel.self) private var model
    let part: DiskPart
    let close: () -> Void
    let freePurgeable: () -> Void

    var body: some View {
        let disk = model.diskOverview
        let whole = disk.isWholeDisk
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Circle().fill(part.color).frame(width: 10, height: 10)
                Text(part.title(wholeDisk: whole)).font(.headline)
                Spacer()
                if let space = disk.space {
                    Text(part.bytes(in: space).bytes).font(.headline.monospacedDigit()).foregroundStyle(.secondary)
                }
            }
            switch part {
            case .scanned:
                Text(whole ? "Files and folders this scan found on the disk. They are listed below."
                           : "Files and folders this scan found in \(model.tree?.rootPath ?? "the folder"). They are listed below.")
                    .fixedSize(horizontal: false, vertical: true)
            case .hidden:
                if whole {
                    Text("Space the disk counts as used that the scan could not find. It is usually:")
                        .fixedSize(horizontal: false, vertical: true)
                    VStack(alignment: .leading, spacing: 4) {
                        bullet("Files Roomy cannot read without Full Disk Access, such as Mail, Messages and other apps' data.")
                        bullet("macOS system files in hidden volumes: the swap file, sleep image, updates and the recovery system.")
                        bullet("Local snapshots, the part macOS cannot free on its own.")
                    }
                    if !model.hasFullDiskAccess {
                        HStack(spacing: 6) {
                            Image(systemName: "lock.trianglebadge.exclamationmark").foregroundStyle(.orange)
                            Text("Full Disk Access is off, so some of this is files Roomy could not read.")
                                .font(.callout)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Button("Turn On Full Disk Access…") {
                            close()
                            Task { @MainActor in
                                try? await Task.sleep(for: .milliseconds(250))
                                model.showOnboarding = true
                            }
                        }
                        .buttonStyle(.borderedProminent)
                    }
                } else {
                    Text("Everything on this disk outside the scanned folder, plus files Roomy cannot see. Scan the whole disk to see where it goes.")
                        .fixedSize(horizontal: false, vertical: true)
                    if let volume = disk.volumePath {
                        Button("Scan \(disk.volumeName)") {
                            close()
                            model.scan(path: DiskSpace.snapshotMountPoint(forVolume: volume))
                        }
                    }
                }
            case .purgeable:
                Text("Space macOS can free on its own when it needs room: local Time Machine snapshots, iCloud files that are also stored online, and some caches. Apps can already use it, so you rarely need to do anything.")
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("Open Storage Settings") {
                        close()
                        disk.openStorageSettings()
                    }
                    if !disk.timeMachineSnapshots.isEmpty, (disk.space?.purgeable ?? 0) > 0 {
                        Button("Free Purgeable Space…", action: freePurgeable)
                            .disabled(disk.isThinning)
                    }
                }
            case .free:
                Text("Space nothing uses yet.")
            }
        }
        .font(.callout)
        .padding(16)
        .frame(width: 320)
    }

    private func bullet(_ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text("•").foregroundStyle(.secondary)
            Text(text).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// The disk's local snapshots, with a delete button for Time Machine ones.
private struct SnapshotSection: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Binding var confirmDelete: LocalSnapshot?

    var body: some View {
        let disk = model.diskOverview
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text("Local snapshots").font(.subheadline.weight(.semibold))
                if !disk.snapshots.isEmpty {
                    Text("\(disk.snapshots.count)")
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(Color.secondary.opacity(0.15)))
                        .contentTransition(.numericText())
                }
                if disk.snapshotState == .loading || disk.isThinning {
                    ProgressView().controlSize(.mini)
                }
                Spacer()
                Button {
                    disk.loadSnapshots()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help("List the snapshots again")
            }

            switch disk.snapshotState {
            case .failed(let message):
                Text("Could not list local snapshots. \(message)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            case .loaded where disk.snapshots.isEmpty:
                Text("No local snapshots on this disk.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            default:
                if disk.snapshots.isEmpty {
                    Text("Looking for local snapshots…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    snapshotList
                }
            }
        }
        .animation(Motion.spring.unless(reduceMotion), value: disk.snapshots)
    }

    private var snapshotList: some View {
        let disk = model.diskOverview
        return ScrollView {
            VStack(spacing: 2) {
                ForEach(Array(disk.snapshots.reversed())) { snapshot in
                    SnapshotRow(snapshot: snapshot, isDeleting: disk.deleting.contains(snapshot.id)) {
                        confirmDelete = snapshot
                    }
                    .transition(.asymmetric(
                        insertion: .opacity.combined(with: .move(edge: .top)),
                        removal: .opacity.combined(with: .scale(scale: 0.9, anchor: .leading))
                    ))
                }
            }
        }
        .frame(height: min(132, CGFloat(disk.snapshots.count) * 40))
    }
}

private struct SnapshotRow: View {
    let snapshot: LocalSnapshot
    let isDeleting: Bool
    let delete: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: snapshot.isTimeMachine ? "clock.arrow.circlepath" : "gearshape")
                .foregroundStyle(DiskPart.purgeable.color)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 0) {
                if let date = snapshot.date {
                    Text(date.formatted(date: .abbreviated, time: .shortened))
                } else {
                    Text(snapshot.name).lineLimit(1).truncationMode(.middle)
                }
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if isDeleting {
                ProgressView().controlSize(.small)
            } else if snapshot.canDelete {
                Button(role: .destructive, action: delete) {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .opacity(hovering ? 1 : 0.55)
                .help("Delete this snapshot…")
            }
        }
        .font(.callout)
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 6).fill(hovering ? Color.primary.opacity(0.05) : .clear))
        .opacity(isDeleting ? 0.6 : 1)
        .onHover { hovering = $0 }
    }

    private var subtitle: String {
        guard snapshot.isTimeMachine else { return "Made by macOS, which removes it on its own" }
        guard let date = snapshot.date else { return "Time Machine" }
        return "Time Machine · " + date.formatted(.relative(presentation: .named))
    }
}

private struct ErrorBanner: View {
    @Environment(AppModel.self) private var model
    let message: String

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 6) {
                Text(message)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                Text("If macOS refused, turn on Full Disk Access for Roomy and try again.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack {
                    Button("Open Full Disk Access Settings") { model.openFullDiskAccessSettings() }
                    Button("Open Storage Settings") { model.diskOverview.openStorageSettings() }
                }
                .controlSize(.small)
            }
            Spacer(minLength: 0)
            Button {
                model.diskOverview.errorMessage = nil
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.orange.opacity(0.1)))
    }
}

/// A short "space freed" moment after a snapshot is removed.
private struct FreedPill: View {
    let bytes: Int64

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "checkmark.circle.fill")
                .symbolEffect(.bounce, value: bytes)
            if bytes > 0 {
                CountingBytes(bytes, suffix: " freed")
            } else {
                Text("Done")
            }
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(.white)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(Capsule().fill(Color.green.gradient))
    }
}
