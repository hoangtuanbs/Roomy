import RoomyCore
import SwiftUI

/// The four parts of a disk in the overview bar.
enum DiskPart: Int, CaseIterable, Identifiable {
    case scanned, hidden, purgeable, free
    var id: Self { self }

    func title(wholeDisk: Bool) -> String {
        switch self {
        case .scanned: return wholeDisk ? String(localized: "Scanned") : String(localized: "This folder")
        case .hidden: return wholeDisk ? String(localized: "Hidden") : String(localized: "Rest of disk")
        case .purgeable: return String(localized: "Purgeable")
        case .free: return String(localized: "Free")
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
    @AppStorage("diskOverviewExpanded", store: AppEnvironment.defaults) private var expanded = true
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
                    if space.purgeable > 0 || disk.purge != .idle {
                        PurgeSection(confirm: $confirmThin)
                            .transition(.opacity.combined(with: .move(edge: .top)))
                    }
                    if expanded {
                        SnapshotSection(confirmDelete: $confirmDelete)
                            .transition(.opacity.combined(with: .move(edge: .top)))
                    }
                    if let message = disk.errorMessage {
                        ErrorBanner(message: message)
                            .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .top)))
                    }
                }
                .padding(14)
                .background(
                    RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                        .fill(LinearGradient(colors: [Palette.well, Palette.well.opacity(0.6)], startPoint: .top, endPoint: .bottom))
                )
                .overlay(RoundedRectangle(cornerRadius: Radius.card, style: .continuous).strokeBorder(Palette.border))
                .padding(.horizontal, Space.l)
                .padding(.vertical, Space.s)
                .animation(Motion.smooth.unless(reduceMotion), value: space)
                .animation(Motion.spring.unless(reduceMotion), value: expanded)
                .animation(Motion.smooth.unless(reduceMotion), value: disk.errorMessage)
                .animation(Motion.spring.unless(reduceMotion), value: disk.purge)
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
        guard let date = confirmDelete?.date else { return String(localized: "Delete this local snapshot?") }
        return String(format: String(localized: "Delete the local snapshot from %@?"), date.formatted(date: .abbreviated, time: .shortened))
    }

    private func header(_ space: DiskSpace) -> some View {
        let disk = model.diskOverview
        return HStack(spacing: 8) {
            IconTile(symbol: disk.isWholeDisk ? "internaldrive.fill" : "internaldrive",
                     gradient: .tile(Color(red: 0.52, green: 0.56, blue: 0.64)), size: 22)
            Text(disk.volumeName).font(.system(size: 13, weight: .semibold)).lineLimit(1)
            HStack(spacing: 0) {
                CountingBytes(grown ? space.used : 0)
                Text(" used of \(space.total.bytes)")
            }
            .font(.caption)
            .monospacedDigit()
            .foregroundStyle(.secondary)
            .lineLimit(1)
            Spacer(minLength: 8)
            if let freed = disk.freedBytes {
                FreedPill(bytes: freed)
                    .transition(.scale(scale: 0.6).combined(with: .opacity))
            }
            if !disk.snapshots.isEmpty {
            Button {
                expanded.toggle()
            } label: {
                HStack(spacing: 4) {
                    if !expanded, !disk.snapshots.isEmpty {
                        Text("\(disk.snapshots.count) \(Plural.word(disk.snapshots.count, "snapshot", "snapshots"))")
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
        }
        .animation(Motion.bouncy.unless(reduceMotion), value: disk.freedBytes)
    }

    private func legend(_ space: DiskSpace) -> some View {
        let disk = model.diskOverview
        return HStack(alignment: .top, spacing: 6) {
            ForEach(DiskPart.allCases) { part in
                Button {
                    explaining = part
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 4) {
                            Circle()
                                .fill(part == .free ? Color.secondary.opacity(0.35) : part.color)
                                .frame(width: 7, height: 7)
                            Text(part.title(wholeDisk: disk.isWholeDisk))
                                .lineLimit(1)
                                .minimumScaleFactor(0.75)
                            if part == .hidden && disk.isWholeDisk && !model.hasFullDiskAccess {
                                Image(systemName: "lock.fill").foregroundStyle(.orange)
                            }
                        }
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(.secondary)
                        CountingBytes(grown ? part.bytes(in: space) : 0)
                            .font(.system(size: 12.5, weight: .semibold, design: .rounded))
                            .lineLimit(1)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(hovered == part ? (part == .free ? Color.primary.opacity(0.06) : part.color.opacity(0.14)) : Palette.card.opacity(0.7))
                    )
                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Palette.border))
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

    private let gap: CGFloat = 3

    var body: some View {
        GeometryReader { geo in
            let fractions = space.fractions
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.primary.opacity(hovered == .free ? 0.14 : 0.08))
                    .contentShape(Rectangle())
                    .onTapGesture { onTap(.free) }
                    .onHover { hover(.free, $0) }
                HStack(spacing: gap) {
                    ForEach([DiskPart.scanned, .hidden, .purgeable]) { part in
                        let fraction = fractions[part.rawValue]
                        if fraction > 0 {
                            Capsule()
                                .fill(LinearGradient(colors: [part.color.mixed(with: .white, by: 0.22), part.color],
                                                     startPoint: .leading, endPoint: .trailing))
                                .overlay(Capsule().fill(LinearGradient(colors: [.white.opacity(0.28), .clear],
                                                                       startPoint: .top, endPoint: .bottom)))
                                .brightness(hovered == part ? 0.06 : 0)
                                .frame(width: grown ? max(6, geo.size.width * fraction - gap) : 0)
                                .animation(Motion.stagger(part.rawValue + 1).unless(reduceMotion), value: grown)
                                .contentShape(Rectangle())
                                .onTapGesture { onTap(part) }
                                .onHover { hover(part, $0) }
                        }
                    }
                }
            }
            .scaleEffect(y: hovered == nil || reduceMotion ? 1 : 1.15)
        }
        .frame(height: 12)
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
                           : "Files and folders this scan found in \(model.tree?.rootPath ?? String(localized: "the folder")). They are listed below.")
                    .fixedSize(horizontal: false, vertical: true)
            case .hidden:
                if whole {
                    Text("Space the disk counts as used that the scan could not find. It is usually:")
                        .fixedSize(horizontal: false, vertical: true)
                    VStack(alignment: .leading, spacing: 4) {
                        bullet(String(localized: "Files RoomyDisk cannot read without Full Disk Access, such as Mail, Messages and other apps' data."))
                        bullet(String(localized: "macOS system files in hidden volumes: the swap file, sleep image, updates and the recovery system."))
                        bullet(String(localized: "Local snapshots, the part macOS cannot free on its own."))
                    }
                    if !model.hasFullDiskAccess {
                        HStack(spacing: 6) {
                            Image(systemName: "lock.trianglebadge.exclamationmark").foregroundStyle(.orange)
                            Text("Full Disk Access is off, so some of this is files RoomyDisk could not read.")
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
                    Text("Everything on this disk outside the scanned folder, plus files RoomyDisk cannot see. Scan the whole disk to see where it goes.")
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
                    if (disk.space?.purgeable ?? 0) > 0 {
                        Button("Free Purgeable Space…", action: freePurgeable)
                            .disabled(disk.purge.isRunning)
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

/// The purgeable space with its "Free Purgeable Space…" button, and what the last try did: free space before and
/// after with the "space freed" moment, or a plain note when macOS freed nothing.
private struct PurgeSection: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Binding var confirm: Bool

    var body: some View {
        let disk = model.diskOverview
        Group {
            switch disk.purge {
            case .idle:
                HStack(spacing: 8) {
                    Image(systemName: "wand.and.sparkles")
                        .foregroundStyle(DiskPart.purgeable.color)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(String(format: String(localized: "%@ purgeable"), (disk.space?.purgeable ?? 0).bytes))
                            .font(.callout.weight(.medium))
                            .monospacedDigit()
                            .contentTransition(.numericText())
                        Text("macOS frees this by itself when it needs room.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                    Spacer(minLength: 8)
                    Button("Free Purgeable Space…") { confirm = true }
                        .controlSize(.small)
                        .fixedSize()
                        .layoutPriority(1)
                }
            case .running(let before):
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Asking macOS to free purgeable space…").font(.callout)
                    Spacer(minLength: 8)
                    Text(String(format: String(localized: "Free: %@"), before.bytes))
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            case .done(let outcome):
                result(outcome)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Palette.card.opacity(0.7)))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Palette.border))
    }

    @ViewBuilder
    private func result(_ outcome: PurgeOutcome) -> some View {
        let disk = model.diskOverview
        switch outcome {
        case .freed(let before, let after):
            VStack(spacing: 6) {
                FreedSpaceCelebration(bytes: after - before,
                                      message: String(localized: "macOS released purgeable space on this disk."),
                                      compact: true, maxWidth: 360) {
                    BeforeAfter(before: before, after: after)
                }
                Button("Done") { disk.dismissPurgeResult() }
                    .controlSize(.small)
            }
            .frame(maxWidth: .infinity)
        case .nothingFreed, .nothingToFree, .failed:
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: isFailure(outcome) ? "exclamationmark.triangle.fill" : "info.circle")
                    .foregroundStyle(isFailure(outcome) ? Color.orange : Color.secondary)
                VStack(alignment: .leading, spacing: 6) {
                    Text(message(outcome))
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack {
                        Button("Open Storage Settings") { disk.openStorageSettings() }
                        Button("OK") { disk.dismissPurgeResult() }
                    }
                    .controlSize(.small)
                }
                Spacer(minLength: 0)
            }
        }
    }

    private func isFailure(_ outcome: PurgeOutcome) -> Bool {
        if case .failed = outcome { return true }
        return false
    }

    private func message(_ outcome: PurgeOutcome) -> String {
        switch outcome {
        case .failed(let reason):
            return String(format: String(localized: "Could not free purgeable space. %@"), reason)
        case .nothingToFree:
            return String(localized: "There is no purgeable space to free on this disk right now.")
        default:
            return String(localized: "macOS did not free any purgeable space this time. It frees it by itself when an app needs room.")
        }
    }
}

/// Free space before and after, the new number rolling up from the old one.
private struct BeforeAfter: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let before: Int64
    let after: Int64
    @State private var shown: Int64?

    var body: some View {
        HStack(spacing: 10) {
            column(String(localized: "Free before"), before)
            Image(systemName: "arrow.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            column(String(localized: "Free now"), shown ?? before)
                .foregroundStyle(.green)
        }
        .onAppear {
            guard shown == nil else { return }
            if reduceMotion {
                shown = after
            } else {
                withAnimation(Motion.smooth.delay(0.3)) { shown = after }
            }
        }
    }

    private func column(_ title: String, _ bytes: Int64) -> some View {
        VStack(spacing: 1) {
            Text(title).font(.caption2).foregroundStyle(.secondary)
            Text(bytes.bytes)
                .font(.system(size: 14, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .contentTransition(.numericText(value: Double(bytes)))
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
        if disk.snapshotState == .loaded && disk.snapshots.isEmpty {
            HStack(spacing: 5) {
                Image(systemName: "clock.arrow.circlepath")
                Text("No local snapshots on this disk.")
                Spacer(minLength: 0)
            }
            .font(.caption)
            .foregroundStyle(.tertiary)
        } else {
            fullSection
        }
    }

    private var fullSection: some View {
        let disk = model.diskOverview
        return VStack(alignment: .leading, spacing: 6) {
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
                if disk.snapshotState == .loading || disk.purge.isRunning {
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
        guard snapshot.isTimeMachine else { return String(localized: "Made by macOS, which removes it on its own") }
        guard let date = snapshot.date else { return String(localized: "Time Machine") }
        return String(format: String(localized: "Time Machine · %@"), date.formatted(.relative(presentation: .named)))
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
                Text("If macOS refused, turn on Full Disk Access for RoomyDisk and try again.")
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
                CountingBytes(bytes, suffix: String(localized: " freed"))
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
