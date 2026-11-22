import RoomyCore
import SwiftUI

/// One hunter's card: what it looks for, how much it found, and its items when opened.
struct HunterCard: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let hunter: SpaceHuntersModel.Hunter
    let index: Int

    var body: some View {
        let hunters = model.spaceHunters
        let state = hunters.state(hunter)
        let isEmpty = hunters.isEmpty(hunter)
        let isExpanded = hunters.expanded.contains(hunter) && !isEmpty
        let canTick = !hunters.removable(hunter).isEmpty

        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 12) {
                SelectionBox(state: state, color: hunter.color) {
                    withAnimation(Motion.quick.unless(reduceMotion)) {
                        hunters.setAll(hunter, selected: state != .all)
                    }
                }
                .padding(.top, 8)
                .opacity(canTick ? 1 : 0)
                .disabled(!canTick)

                ZStack {
                    Circle().fill(hunter.color.gradient)
                    Image(systemName: hunter.symbol)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white)
                }
                .frame(width: 34, height: 34)

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(hunter.title).font(.headline)
                        if (hunter == .downloads || hunter == .photos) && !isEmpty {
                            Badge(text: "Review first", color: .orange)
                        }
                        if hunter == .backups && hunters.backupsNeedAccess {
                            Badge(text: "Needs Full Disk Access", color: .orange)
                        }
                    }
                    // An empty card stays short, so the cards that found something stand out.
                    Text(isEmpty ? hunter.emptyNote : hunter.explanation)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 12)

                VStack(alignment: .trailing, spacing: 3) {
                    CountingBytes(hunters.foundBytes(hunter))
                        .font(.title3.weight(.semibold))
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .contentTransition(.numericText())
                }
                .animation(Motion.quick.unless(reduceMotion), value: hunters.selectedBytes(hunter))

                Image(systemName: isEmpty ? "checkmark.circle" : "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    .padding(.top, 8)
            }
            .padding(isEmpty ? 10 : 14)
            .contentShape(Rectangle())
            .onTapGesture {
                guard !isEmpty else { return }
                withAnimation(Motion.spring.unless(reduceMotion)) { hunters.toggleExpanded(hunter) }
            }

            if isExpanded {
                Divider().padding(.horizontal, 14)
                Group {
                    switch hunter {
                    case .backups: BackupsList()
                    case .downloads: DownloadsList()
                    case .mail: MailList()
                    case .photos: PhotoGroupsList()
                    }
                }
                .padding(.vertical, 6)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.primary.opacity(0.04)))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(state == .none ? Color.primary.opacity(0.08) : hunter.color.opacity(0.55), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .entrance(index: index)
    }

    private var subtitle: String {
        let hunters = model.spaceHunters
        if hunters.isEmpty(hunter) { return "Nothing found" }
        let selected = hunters.selectedBytes(hunter)
        switch hunter {
        case .backups:
            if hunters.backupsNeedAccess { return "Could not look" }
            return selected > 0 ? "\(selected.bytes) ticked" : "\(hunters.backups.count) \(hunters.backups.count == 1 ? "backup" : "backups")"
        case .downloads:
            return selected > 0 ? "\(selected.bytes) ticked" : "\(hunters.downloads.count) unused \(hunters.downloads.count == 1 ? "item" : "items")"
        case .mail:
            return selected > 0 ? "\(selected.bytes) ticked" : "\(hunters.mail.storeBytes.bytes) only in Mail"
        case .photos:
            return selected > 0 ? "\(selected.bytes) ticked" : "\(hunters.photoGroups.count) \(hunters.photoGroups.count == 1 ? "group" : "groups") · can be freed"
        }
    }
}

/// How many rows a card shows before "and N more".
private let shownRows = 100

/// A row with a tick box, an icon, a name and details, badges, the size and buttons to look at the item.
private struct HunterRow<Icon: View, Badges: View>: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let path: String
    let title: String
    let detail: String
    let bytes: Int64
    var color: Color = .accentColor
    var tickable = true
    var quickLook = true
    @ViewBuilder var icon: () -> Icon
    @ViewBuilder var badges: () -> Badges
    @State private var hovering = false

    var body: some View {
        let hunters = model.spaceHunters
        let ticked = hunters.selected.contains(path)
        HStack(spacing: 10) {
            if tickable {
                SelectionBox(state: ticked ? .all : .none, color: color) {
                    withAnimation(Motion.quick.unless(reduceMotion)) { hunters.toggle(path) }
                }
            }
            icon()
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(title).lineLimit(1).truncationMode(.middle)
                    badges()
                }
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 8)
            Text(bytes.bytes)
                .monospacedDigit()
                .foregroundStyle(.secondary)
            if quickLook {
                Button { hunters.quickLook(path) } label: { Image(systemName: "eye") }
                    .buttonStyle(.borderless)
                    .help("Quick Look")
            }
            Button { hunters.reveal(path) } label: { Image(systemName: "magnifyingglass") }
                .buttonStyle(.borderless)
                .help("Show in Finder")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 5)
        .background(hovering ? Color.primary.opacity(0.04) : Color.clear)
        .contentShape(Rectangle())
        .onHover { inside in withAnimation(Motion.hover.unless(reduceMotion)) { hovering = inside } }
        .contextMenu {
            if quickLook { Button("Quick Look") { hunters.quickLook(path) } }
            Button("Show in Finder") { hunters.reveal(path) }
        }
    }
}

private struct MoreRows: View {
    let count: Int

    var body: some View {
        if count > shownRows {
            Text("and \(count - shownRows) more")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(8)
        }
    }
}

// MARK: Backups

private struct BackupsList: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let hunters = model.spaceHunters
        if hunters.backupsNeedAccess {
            AccessPrompt()
        } else {
            let newest = BackupRules.newestPerDevice(hunters.backups)
            let suggested = BackupRules.preselected(hunters.backups)
            VStack(spacing: 0) {
                ForEach(hunters.backups.prefix(shownRows)) { backup in
                    HunterRow(path: backup.path, title: backup.deviceName, detail: detail(backup), bytes: backup.bytes,
                              color: SpaceHuntersModel.Hunter.backups.color, quickLook: false) {
                        Image(systemName: backup.isIPad ? "ipad" : "iphone")
                            .font(.system(size: 18))
                            .foregroundStyle(SpaceHuntersModel.Hunter.backups.color)
                            .frame(width: 28)
                    } badges: {
                        if newest.contains(backup.path) {
                            Badge(text: "Latest", color: .green)
                        } else if !suggested.contains(backup.path) {
                            Badge(text: "Review first", color: .orange)
                        }
                        if backup.info.isEncrypted == true {
                            Badge(text: "Encrypted", color: .blue)
                        }
                    }
                }
                MoreRows(count: hunters.backups.count)
            }
        }
    }

    private func detail(_ backup: DeviceBackup) -> String {
        var parts: [String] = []
        if let type = backup.info.productType { parts.append(type) }
        if let version = backup.info.osVersion { parts.append((backup.isIPad ? "iPadOS " : "iOS ") + version) }
        parts.append("backed up " + backup.date.formatted(.relative(presentation: .named)))
        return parts.joined(separator: " · ")
    }
}

/// Shown when the backups folder could not be read.
private struct AccessPrompt: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let hunters = model.spaceHunters
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "lock.trianglebadge.exclamationmark")
                .font(.system(size: 22))
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 8) {
                Text("RoomyDisk needs Full Disk Access to see device backups")
                    .font(.callout.weight(.semibold))
                Text("macOS protects the folder Finder keeps backups in. Turn on Full Disk Access for RoomyDisk, then hunt again.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("Show Me How…") { hunters.onShowAccessHelp?() }
                    Button("Open Privacy Settings") { hunters.openFullDiskAccessSettings() }
                }
            }
            Spacer()
        }
        .padding(14)
    }
}

// MARK: Downloads

private struct DownloadsList: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let hunters = model.spaceHunters
        VStack(spacing: 0) {
            ForEach(hunters.downloads.prefix(shownRows)) { item in
                HunterRow(path: item.path, title: item.name,
                          detail: "Last used " + item.lastActivity.formatted(.relative(presentation: .named)),
                          bytes: item.bytes, color: SpaceHuntersModel.Hunter.downloads.color) {
                    FileThumbnail(path: item.path, size: 28)
                } badges: {
                    EmptyView()
                }
            }
            MoreRows(count: hunters.downloads.count)
        }
    }
}

// MARK: Mail

private struct MailList: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let hunters = model.spaceHunters
        let places = MailLocations(homePath: hunters.home)
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "tray.full.fill")
                    .font(.system(size: 18))
                    .foregroundStyle(SpaceHuntersModel.Hunter.mail.color)
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text("Attachments in Mail")
                        Badge(text: "Look only", color: .secondary)
                    }
                    Text(hunters.mail.storeReadable
                         ? "Mail keeps these next to its index, so removing them in Finder could damage Mail. In Mail, select messages and choose Message > Remove Attachments, or delete the messages you don't need."
                         : "RoomyDisk needs Full Disk Access to measure Mail's attachments.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack {
                        Button("Open Mail") { hunters.openMail() }
                        Button("Open in Finder") { hunters.openFolder(places.storeFolder) }
                    }
                    .controlSize(.small)
                    .padding(.top, 2)
                }
                Spacer(minLength: 8)
                Text(hunters.mail.storeReadable ? hunters.mail.storeBytes.bytes : "–")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)

            if !hunters.mail.downloads.isEmpty {
                Text("Opened attachments (Mail Downloads)")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 14)
                    .padding(.top, 6)
                ForEach(hunters.mail.downloads.prefix(shownRows)) { item in
                    HunterRow(path: item.path, title: item.name,
                              detail: "Opened " + item.modified.formatted(.relative(presentation: .named)),
                              bytes: item.bytes, color: SpaceHuntersModel.Hunter.mail.color) {
                        FileThumbnail(path: item.path, size: 28)
                    } badges: {
                        Badge(text: "Review first", color: .orange)
                    }
                }
                MoreRows(count: hunters.mail.downloads.count)
            }
        }
    }
}

// MARK: Similar photos

private struct PhotoGroupsList: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let hunters = model.spaceHunters
        VStack(alignment: .leading, spacing: 4) {
            Text("Looked in \((hunters.photoScope as NSString).abbreviatingWithTildeInPath). Photos libraries are left alone; remove those pictures in Photos.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 14)
                .padding(.vertical, 4)
            ForEach(Array(hunters.photoGroups.prefix(shownRows).enumerated()), id: \.element.id) { index, group in
                PhotoGroupRow(group: group)
                    .entrance(index: index, offset: 8)
            }
            MoreRows(count: hunters.photoGroups.count)
        }
    }
}

private struct PhotoGroupRow: View {
    @Environment(AppModel.self) private var model
    let group: SimilarPhotoGroup

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("\(group.photos.count) similar · up to \(group.extraBytes.bytes) can be freed")
                .font(.caption)
                .foregroundStyle(.secondary)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(group.photos) { photo in
                        PhotoTile(photo: photo, isSuggested: photo.path == group.suggestedKeep.path)
                    }
                }
                .padding(.vertical, 2)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
    }
}

private struct PhotoTile: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let photo: PhotoCandidate
    let isSuggested: Bool
    @State private var hovering = false

    var body: some View {
        let hunters = model.spaceHunters
        let ticked = hunters.selected.contains(photo.path)
        VStack(alignment: .leading, spacing: 3) {
            ZStack(alignment: .topLeading) {
                FileThumbnail(path: photo.path, size: 96)
                    .overlay(
                        RoundedRectangle(cornerRadius: 96 * 0.18, style: .continuous)
                            .strokeBorder(ticked ? Color.red.opacity(0.8) : (isSuggested ? Color.green : Color.clear), lineWidth: 2)
                    )
                    .opacity(ticked ? 0.6 : 1)
                    .scaleEffect(hovering && !reduceMotion ? 1.03 : 1)
                SelectionBox(state: ticked ? .all : .none, color: .red) {
                    withAnimation(Motion.quick.unless(reduceMotion)) { hunters.toggle(photo.path) }
                }
                .padding(4)
                .background(Circle().fill(.regularMaterial).padding(4))
                .disabled(!ticked && !hunters.canTick(photo.path))
            }
            HStack(spacing: 4) {
                if isSuggested { Badge(text: "Keep", color: .green) }
                Text(photo.bytes.bytes).font(.caption2).foregroundStyle(.secondary).monospacedDigit()
            }
            Text(photo.name)
                .font(.caption2)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(width: 96, alignment: .leading)
        }
        .onHover { inside in withAnimation(Motion.hover.unless(reduceMotion)) { hovering = inside } }
        .onTapGesture(count: 2) { hunters.quickLook(photo.path) }
        .help(photo.pixelWidth > 0 ? "\(photo.pixelWidth) × \(photo.pixelHeight) · double-click to preview" : "Double-click to preview")
        .contextMenu {
            Button("Quick Look") { hunters.quickLook(photo.path) }
            Button("Show in Finder") { hunters.reveal(photo.path) }
        }
    }
}
