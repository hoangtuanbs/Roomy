import RoomyCore
import SwiftUI

extension BackupUploadState {
    var label: String {
        switch self {
        case .uploaded: return String(localized: "Uploaded")
        case .uploading: return String(localized: "Uploading…")
        case .waiting: return String(localized: "Waiting to upload")
        case .cloudOnly: return String(localized: "Only in the cloud")
        case .conflicted: return String(localized: "Has conflicting versions")
        case .notSyncing: return String(localized: "Not syncing")
        case .missing: return String(localized: "Missing")
        }
    }

    var symbol: String {
        switch self {
        case .uploaded: return "checkmark.icloud.fill"
        case .uploading: return "icloud.and.arrow.up"
        case .waiting: return "clock"
        case .cloudOnly: return "icloud"
        case .conflicted: return "exclamationmark.icloud"
        case .notSyncing: return "icloud.slash"
        case .missing: return "questionmark.circle"
        }
    }

    var color: Color {
        switch self {
        case .uploaded: return .green
        case .uploading: return Color(red: 0.29, green: 0.60, blue: 0.95)
        case .waiting, .conflicted: return .orange
        case .cloudOnly: return Color(red: 0.42, green: 0.42, blue: 0.90)
        case .notSyncing: return .secondary
        case .missing: return .red
        }
    }
}

/// A row flying up and away into the cloud in the header as its file is moved.
private struct FlyToCloud: ViewModifier {
    let progress: Double

    func body(content: Content) -> some View {
        content
            .scaleEffect(1 - 0.65 * progress, anchor: .topTrailing)
            .offset(x: 240 * progress, y: -160 * progress)
            .rotationEffect(.degrees(-6 * progress))
            .blur(radius: 3 * progress)
            .opacity(1 - progress)
    }
}

extension AnyTransition {
    static func flyToCloud(_ reduceMotion: Bool) -> AnyTransition {
        reduceMotion ? .opacity : .asymmetric(insertion: .opacity,
                                              removal: .modifier(active: FlyToCloud(progress: 1), identity: FlyToCloud(progress: 0)))
    }
}

/// Cloud Backup: moves big files that have not been used for months into a cloud folder, after a review.
struct CloudBackupView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        @Bindable var backup = model.cloudBackup

        ToolSheet {
            CloudBackupHeader()
        } content: {
            VStack(spacing: 0) {
                BackupTabBar()
                if backup.tab == .review {
                    BackupOptionsBar()
                    reviewContent
                        .transition(.opacity.combined(with: .move(edge: .leading)))
                } else {
                    BackedUpContent()
                        .transition(.opacity.combined(with: .move(edge: .trailing)))
                }
            }
            .animation(Motion.smooth.unless(reduceMotion), value: backup.tab)
        } footer: {
            footer
        }
        .frame(minWidth: 820, idealWidth: 900, minHeight: 620, idealHeight: 740)
        .interactiveDismissDisabled(backup.isBusy)
        .alert(String(format: String(localized: "Back up %lld %@ to %@?"), backup.selectedItems.count,
                      Plural.word(backup.selectedItems.count, "file", "files"), backup.destinationTitle),
               isPresented: $backup.isConfirming) {
            Button("Back Up") { backup.backUp() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(confirmMessage)
        }
    }

    private var confirmMessage: String {
        let backup = model.cloudBackup
        var text = String(format: String(localized: "They move to the “RoomyDisk Backup” folder in %@ and upload from there. Once they are uploaded, free their local copies in Backed Up to get the space back."),
                          backup.destinationTitle)
        if backup.leavesAlias {
            text += " " + String(localized: "An alias stays in each file's old place, and you can restore any file later.")
        } else {
            text += " " + String(localized: "You can restore any file later.")
        }
        return text
    }

    @ViewBuilder
    private var reviewContent: some View {
        let backup = model.cloudBackup
        ZStack {
            switch backup.phase {
            case .idle:
                ContentUnavailableView {
                    Label("Ready to look", systemImage: "icloud.and.arrow.up")
                } actions: {
                    Button("Find Old Files") { backup.find() }
                        .buttonStyle(.primaryAction(.cloudBackup))
                }
                .transition(.opacity)
            case .finding:
                BackupFindingProgress()
                    .transition(.opacity)
            case .ready, .moving:
                Group {
                    if backup.findings.groups.isEmpty && backup.phase == .ready {
                        NothingOld()
                    } else {
                        BackupResults()
                    }
                }
                .transition(.opacity.combined(with: .scale(scale: 0.98)))
            case .done:
                let report = backup.report
                let count = report?.succeeded.count ?? 0
                let title = backup.movedTo?.title(backup.locations) ?? backup.destinationTitle
                FreedSpaceCelebration(
                    bytes: backup.movedBytes,
                    message: String(format: String(localized: "Moved %lld %@ to %@. They upload in the background; once they are uploaded, free their local copies in Backed Up to get the space back."),
                                    count, Plural.word(count, "file", "files"), title),
                    succeeded: count > 0 || (report?.failed.isEmpty ?? true),
                    suffix: String(localized: " moved to the cloud folder")
                ) {
                    if let failed = report?.failed, !failed.isEmpty {
                        NotMovedList(results: failed).frame(maxWidth: 460)
                    }
                }
                .transition(.opacity.combined(with: .scale(scale: 0.9)))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(Motion.smooth.unless(reduceMotion), value: backup.phase)
    }

    @ViewBuilder
    private var footer: some View {
        let backup = model.cloudBackup
        HStack(spacing: 10) {
            if backup.tab == .backedUp {
                backedUpFooter
            } else {
                switch backup.phase {
                case .idle:
                    Spacer()
                    Button("Close") { dismiss() }
                        .keyboardShortcut(.cancelAction)
                case .finding:
                    Spacer()
                    Button("Cancel") {
                        backup.cancel()
                        dismiss()
                    }
                    .keyboardShortcut(.cancelAction)
                case .ready where backup.findings.groups.isEmpty:
                    Spacer()
                    Button("Look Again") { backup.find() }
                    Button("Close") { dismiss() }
                        .keyboardShortcut(.cancelAction)
                case .ready:
                    Label(String(format: String(localized: "Files move to %@ and upload. Nothing moves until you confirm."), backup.destinationTitle),
                          systemImage: "icloud.and.arrow.up")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                    Spacer()
                    Button("Look Again") { backup.find() }
                    Button("Close") { dismiss() }
                        .keyboardShortcut(.cancelAction)
                    Button {
                        backup.askToBackUp()
                    } label: {
                        Label(String(format: String(localized: "Back Up %lld %@ (%@) to %@"), backup.selectedItems.count,
                                     Plural.word(backup.selectedItems.count, "file", "files"), backup.selectedBytes.bytes,
                                     backup.destination?.provider.title ?? String(localized: "the cloud")),
                              systemImage: "icloud.and.arrow.up.fill")
                            .padding(.horizontal, 6)
                            .contentTransition(.numericText())
                    }
                    .buttonStyle(.primaryAction(.cloudBackup))
                    .disabled(!backup.canBackUp)
                    .animation(Motion.quick.unless(reduceMotion), value: backup.selectedItems.count)
                case .moving:
                    ProgressView(value: backup.moveFraction)
                        .progressViewStyle(.linear)
                        .tint(Color(red: 0.36, green: 0.62, blue: 0.92))
                        .frame(maxWidth: 260)
                        .animation(Motion.smooth.unless(reduceMotion), value: backup.moveFraction)
                    Text("Moving \(min(backup.movedCount + 1, backup.moveTotal)) of \(backup.moveTotal)…")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .contentTransition(.numericText())
                    Spacer()
                case .done:
                    Spacer()
                    Button("Show Remaining") { backup.showRemaining() }
                    Button("Show Backed Up") { backup.showBackedUp() }
                    Button("Done") { dismiss() }
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
    }

    @ViewBuilder
    private var backedUpFooter: some View {
        let backup = model.cloudBackup
        switch backup.freePhase {
        case .list:
            if !backup.records.isEmpty {
                Text(String(format: String(localized: "%lld of %lld uploaded"), backup.records.filter { backup.states[$0.id] == .uploaded || backup.states[$0.id] == .cloudOnly }.count, backup.records.count))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Spacer()
            Button("Refresh") { backup.loadRecords() }
            Button("Close") { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button {
                backup.freeLocalCopies()
            } label: {
                Label(String(format: String(localized: "Free Local Copies (%@)"), backup.freeableBytes.bytes),
                      systemImage: "icloud.and.arrow.down")
                    .padding(.horizontal, 6)
            }
            .buttonStyle(.primaryAction(.cloudBackup))
            .disabled(backup.freeable.isEmpty)
        case .freeing:
            Spacer()
            Text("Please wait…").foregroundStyle(.secondary)
        case .freed:
            Spacer()
            Button("Back to List") { backup.showList() }
            Button("Done") { dismiss() }
                .keyboardShortcut(.defaultAction)
        }
    }
}

// MARK: Header and bars

private struct CloudBackupHeader: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let backup = model.cloudBackup
        ToolSheetHeader(title: "Cloud Backup", subtitle: Text("Move big files you haven't used in months to your cloud folder."),
                        gradient: .cloudBackup) {
            FloatingCloud(symbol: "icloud.and.arrow.up.fill", size: 21, distance: 2)
                .foregroundStyle(.white)
        } accessory: {
            if backup.tab == .review && backup.phase == .moving {
                HStack(spacing: 12) {
                    VStack(alignment: .trailing, spacing: 2) {
                        CountingBytes(backup.movedBytes)
                            .font(.system(size: 28, weight: .bold, design: .rounded))
                            .animation(Motion.smooth.unless(reduceMotion), value: backup.movedBytes)
                        Text("moved to \(backup.destinationTitle)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    // Where the rows fly to: it bounces as each file lands.
                    Image(systemName: "icloud.fill")
                        .font(.system(size: 30, weight: .semibold))
                        .foregroundStyle(LinearGradient.cloudBackup)
                        .symbolEffect(.bounce, value: reduceMotion ? 0 : backup.movedCount)
                }
                .transition(.opacity.combined(with: .move(edge: .trailing)))
            } else if backup.tab == .review && backup.phase == .ready && !backup.items.isEmpty {
                VStack(alignment: .trailing, spacing: 2) {
                    Text(backup.selectedBytes.bytes)
                        .font(.system(size: 28, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .contentTransition(.numericText(value: Double(backup.selectedBytes)))
                        .animation(Motion.quick.unless(reduceMotion), value: backup.selectedBytes)
                    Text("\(backup.selectedItems.count) \(Plural.word(backup.selectedItems.count, "file", "files")) ticked")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .contentTransition(.numericText())
                        .animation(Motion.quick.unless(reduceMotion), value: backup.selectedItems.count)
                }
                .transition(.opacity.combined(with: .move(edge: .trailing)))
            } else if backup.tab == .backedUp && !backup.records.isEmpty {
                ToolSheetTotal(value: Text(backup.recordsBytes.bytes),
                               caption: Text("\(backup.records.count) \(Plural.word(backup.records.count, "file", "files")) backed up"))
            }
        }
        .animation(Motion.smooth.unless(reduceMotion), value: backup.phase)
        .animation(Motion.smooth.unless(reduceMotion), value: backup.tab)
    }
}

/// Review and Backed Up, as a segmented control.
private struct BackupTabBar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var backup = model.cloudBackup
        HStack {
            Picker("", selection: $backup.tab) {
                Text("Review").tag(CloudBackupModel.Tab.review)
                Text(backup.records.isEmpty ? String(localized: "Backed Up")
                     : String(format: String(localized: "Backed Up (%lld)"), backup.records.count))
                    .tag(CloudBackupModel.Tab.backedUp)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 300)
            .disabled(backup.phase == .moving || backup.freePhase == .freeing)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, Space.m)
        .padding(.bottom, Space.s)
    }
}

/// The thresholds, the destination and the alias option, kept in the app's settings.
private struct BackupOptionsBar: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        @Bindable var backup = model.cloudBackup
        VStack(spacing: 6) {
            HStack(spacing: 14) {
                Picker("Bigger than", selection: $backup.minimumSize) {
                    ForEach(BackupMinimumSize.allCases) { Text($0.label).tag($0) }
                }
                .fixedSize()
                Picker("Unused for", selection: $backup.unusedFor) {
                    ForEach(BackupUnusedFor.allCases) { Text($0.label).tag($0) }
                }
                .fixedSize()
                Divider().frame(height: 18)
                Menu {
                    ForEach(backup.allDestinations) { destination in
                        Button {
                            backup.choose(destination)
                        } label: {
                            if destination == backup.destination {
                                Label(destination.title(backup.locations), systemImage: "checkmark")
                            } else {
                                Text(destination.title(backup.locations))
                            }
                        }
                    }
                    if !backup.allDestinations.isEmpty { Divider() }
                    Button("Choose Folder…") { backup.chooseFolder() }
                } label: {
                    Label(backup.destination.map { String(format: String(localized: "To %@"), $0.title(backup.locations)) }
                          ?? String(localized: "Choose a cloud folder"),
                          systemImage: backup.destination?.provider.kind.symbol ?? "icloud.slash")
                }
                .fixedSize()
                Spacer(minLength: 8)
                Toggle("Leave an alias", isOn: $backup.leavesAlias)
                    .toggleStyle(.checkbox)
                    .help("Put a Finder alias where each file was, so you can still find it there")
            }
            .controlSize(.small)
            .disabled(backup.phase == .moving)

            if let warning = backup.destinationWarning {
                Label(warning, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            } else if backup.destination == nil && backup.phase != .idle {
                Label("No cloud folder on this Mac. Turn on iCloud Drive or install Dropbox, OneDrive or Google Drive, or choose a folder inside one.",
                      systemImage: "icloud.slash")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .transition(.opacity)
            }
        }
        .padding(.horizontal, Space.l)
        .padding(.vertical, Space.s)
        .background(RoundedRectangle(cornerRadius: Radius.control, style: .continuous).fill(Palette.card))
        .overlay(RoundedRectangle(cornerRadius: Radius.control, style: .continuous).strokeBorder(Palette.border, lineWidth: 1))
        .padding(.horizontal, Space.l)
        .padding(.bottom, Space.xs)
        .animation(Motion.smooth.unless(reduceMotion), value: backup.destinationWarning)
    }
}

// MARK: Finding

private struct BackupFindingProgress: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let backup = model.cloudBackup
        VStack(spacing: 18) {
            BusyRing(gradient: .cloudBackup, size: 150, lineWidth: 9, period: 1.4) {
                FloatingCloud(symbol: "magnifyingglass", size: 38, distance: 4)
                    .foregroundStyle(LinearGradient.cloudBackup)
            }
            Text("Looking for big files you haven't used…").font(.title3)
            Text("\(backup.filesChecked.formatted()) files checked")
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .contentTransition(.numericText())
                .motion(Motion.quick, value: backup.filesChecked)
            Text("Files are only read. Nothing is changed yet.")
                .font(.callout)
                .foregroundStyle(.tertiary)
        }
        .padding(32)
    }
}

/// A big floating cloud with a soft glow, for the empty states.
private struct BackupHero: View {
    var symbol = "icloud.and.arrow.up"

    var body: some View {
        ZStack {
            Circle().fill(LinearGradient.cloudBackup).opacity(0.12).frame(width: 150, height: 150)
            Circle().fill(LinearGradient.cloudBackup).opacity(0.10).frame(width: 110, height: 110)
            FloatingCloud(symbol: symbol, size: 54, distance: 5)
                .foregroundStyle(LinearGradient.cloudBackup)
        }
        .entrance(offset: 10, scale: 0.9)
    }
}

private struct NothingOld: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let backup = model.cloudBackup
        VStack(spacing: 16) {
            BackupHero(symbol: "checkmark.icloud")
            Text("No big, forgotten files")
                .font(.title2.weight(.semibold))
                .entrance(index: 1, offset: 8)
            Text(String(format: String(localized: "Nothing bigger than %@ has gone unused for %@ in your home folders. Try a smaller size or a shorter time."),
                        backup.minimumSize.label, backup.unusedFor.label))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 480)
                .entrance(index: 2, offset: 8)
        }
        .padding(32)
    }
}

// MARK: Review

private struct BackupResults: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let backup = model.cloudBackup
        let all = backup.items.count
        let ticked = backup.selected.count
        ScrollView {
            VStack(spacing: 10) {
                HStack(spacing: 8) {
                    SelectionBox(state: ticked == 0 ? .none : (ticked == all ? .all : .some), color: .accentColor) {
                        withAnimation(Motion.quick.unless(reduceMotion)) { backup.selectAll(ticked != all) }
                    }
                    Text(String(format: String(localized: "%lld %@ bigger than %@, unused for %@ · %@"), all,
                                Plural.word(all, "file", "files"), backup.minimumSize.label, backup.unusedFor.label,
                                backup.findings.bytes.bytes))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .contentTransition(.numericText())
                    Spacer()
                    Button(ticked == all ? LocalizedStringKey("Select None") : LocalizedStringKey("Select All")) {
                        withAnimation(Motion.quick.unless(reduceMotion)) { backup.selectAll(ticked != all) }
                    }
                    .buttonStyle(.borderless)
                    .disabled(backup.phase != .ready)
                }
                .padding(.horizontal, 4)

                ForEach(Array(backup.findings.groups.enumerated()), id: \.element.id) { index, group in
                    BackupGroupCard(group: group, index: index)
                        .transition(.flyToCloud(reduceMotion))
                }
                if backup.findings.capped {
                    Text("Very large folders were only partly checked (\(CloudBackupFinder.fileLimit.formatted()) files).")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(16)
            .animation(.easeIn(duration: 0.55).unless(reduceMotion), value: backup.items.map(\.path))
        }
    }
}

/// One folder: its files, how much they take, and a tick for all of them.
private struct BackupGroupCard: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let group: BackupFolderGroup
    let index: Int

    var body: some View {
        let backup = model.cloudBackup
        let state = backup.state(of: group)
        let tint = Color(red: 0.40, green: 0.58, blue: 0.95)
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                SelectionBox(state: state, color: tint) {
                    withAnimation(Motion.quick.unless(reduceMotion)) { backup.setAll(group, selected: state != .all) }
                }
                IconTile(symbol: group.name == CloudBackupFinder.homeName ? "house.fill" : "folder.fill",
                         gradient: .cloudBackup, size: 30)
                VStack(alignment: .leading, spacing: 2) {
                    Text(group.name).font(.headline).lineLimit(1).truncationMode(.middle)
                    Text("\(group.items.count) \(Plural.word(group.items.count, "file", "files"))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .contentTransition(.numericText())
                }
                Spacer(minLength: 12)
                CountingBytes(group.bytes)
                    .font(.title3.weight(.semibold))
                    .animation(Motion.smooth.unless(reduceMotion), value: group.bytes)
                Button { backup.reveal(group.path) } label: { Image(systemName: "magnifyingglass") }
                    .buttonStyle(.borderless)
                    .help("Show in Finder")
            }
            .padding(14)

            Divider().padding(.horizontal, 14)
            VStack(spacing: 0) {
                ForEach(Array(group.items.enumerated()), id: \.element.id) { rowIndex, item in
                    BackupFileRow(item: item, tint: tint)
                        .entrance(index: index + rowIndex, offset: 8, scale: 1)
                        .transition(.flyToCloud(reduceMotion))
                }
            }
            .padding(.vertical, 6)
        }
        .card(tint: state == .none ? nil : tint, hoverable: false)
        .entrance(index: index)
    }
}

/// One file: tick, kind, name, when it was last used, size, Quick Look and Show in Finder.
private struct BackupFileRow: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let item: BackupCandidate
    let tint: Color
    @State private var hovering = false

    var body: some View {
        let backup = model.cloudBackup
        let category = FileCategory.classify(name: item.name, kind: .file)
        HStack(spacing: 10) {
            SelectionBox(state: backup.selected.contains(item.path) ? .all : .none, color: tint) {
                withAnimation(Motion.quick.unless(reduceMotion)) { backup.toggle(item) }
            }
            .disabled(backup.phase != .ready)
            IconTile(symbol: category.symbol, gradient: .tile(category.color), size: 24)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.name).lineLimit(1).truncationMode(.middle)
                Text(backup.lastUsedText(item.lastUsed))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Text(item.bytes.bytes)
                .monospacedDigit()
                .foregroundStyle(.secondary)
            Button { backup.quickLook(item.path) } label: { Image(systemName: "eye") }
                .buttonStyle(.borderless)
                .help("Quick Look")
            Button { backup.reveal(item.path) } label: { Image(systemName: "magnifyingglass") }
                .buttonStyle(.borderless)
                .help("Show in Finder")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 5)
        .background(hovering ? Color.primary.opacity(0.04) : Color.clear)
        .contentShape(Rectangle())
        .onHover { inside in withAnimation(Motion.hover.unless(reduceMotion)) { hovering = inside } }
        .onTapGesture(count: 2) { backup.quickLook(item.path) }
        .contextMenu {
            Button("Quick Look") { backup.quickLook(item.path) }
            Button("Show in Finder") { backup.reveal(item.path) }
        }
    }
}

/// Files that were not moved, folded away.
private struct NotMovedList: View {
    let results: [CloudBackupResult]

    var body: some View {
        DisclosureGroup("\(results.count) could not be moved") {
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(results, id: \.path) { result in
                        VStack(alignment: .leading, spacing: 1) {
                            Text((result.path as NSString).lastPathComponent)
                            Text(result.error ?? String(localized: "Unknown error")).font(.caption).foregroundStyle(.secondary)
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

// MARK: Backed up

private struct BackedUpContent: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let backup = model.cloudBackup
        ZStack {
            switch backup.freePhase {
            case .list:
                if backup.records.isEmpty {
                    VStack(spacing: 16) {
                        BackupHero(symbol: "icloud")
                        Text("Nothing backed up yet")
                            .font(.title2.weight(.semibold))
                            .entrance(index: 1, offset: 8)
                        Text("Files you back up are listed here, so you can restore them or free their space once they are uploaded.")
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: 460)
                            .entrance(index: 2, offset: 8)
                    }
                    .padding(32)
                    .transition(.opacity)
                } else {
                    BackedUpList()
                        .transition(.opacity)
                }
            case .freeing:
                VStack(spacing: 18) {
                    BusyRing(gradient: .cloudBackup, size: 150, lineWidth: 9, period: 1.4) {
                        FloatingCloud(symbol: "icloud.and.arrow.down", size: 38, distance: 4)
                            .foregroundStyle(LinearGradient.cloudBackup)
                    }
                    Text("Removing \(min(backup.freedCount + 1, backup.freeTotal)) of \(backup.freeTotal)…")
                        .font(.title3)
                        .monospacedDigit()
                        .contentTransition(.numericText())
                }
                .padding(32)
                    .transition(.opacity.combined(with: .scale(scale: 0.95)))
            case .freed:
                let report = backup.freeReport
                let count = report?.succeeded.count ?? 0
                FreedSpaceCelebration(
                    bytes: report?.freedBytes ?? 0,
                    message: String(format: String(localized: "Removed the local copies of %lld %@. They stay in the cloud and download again when you open them."),
                                    count, Plural.word(count, "file", "files")),
                    succeeded: count > 0 || (report?.failed.isEmpty ?? true),
                    suffix: String(localized: " freed — still in the cloud")
                ) { EmptyView() }
                .transition(.opacity.combined(with: .scale(scale: 0.9)))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(Motion.smooth.unless(reduceMotion), value: backup.freePhase)
        .onAppear { backup.loadRecords() }
    }
}

private struct BackedUpList: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let backup = model.cloudBackup
        ScrollView {
            VStack(spacing: 10) {
                Label("A file in a cloud folder still takes space here until its local copy is removed. Once a file is uploaded, Free Local Copies removes that copy; the file downloads again when you open it.",
                      systemImage: "info.circle")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 4)
                if let notice = backup.notice {
                    Label(notice, systemImage: "exclamationmark.triangle.fill")
                        .font(.callout)
                        .foregroundStyle(.orange)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 4)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
                VStack(spacing: 0) {
                    ForEach(Array(backup.records.enumerated()), id: \.element.id) { index, record in
                        if index > 0 { Divider().padding(.leading, 52) }
                        BackupRecordRow(record: record)
                            .entrance(index: index, offset: 8, scale: 1)
                            .transition(.asymmetric(insertion: .opacity, removal: .opacity.combined(with: .move(edge: .leading))))
                    }
                }
                .padding(.vertical, 6)
                .card(hoverable: false)
            }
            .padding(16)
            .animation(Motion.spring.unless(reduceMotion), value: backup.records.map(\.id))
            .animation(Motion.smooth.unless(reduceMotion), value: backup.notice)
        }
    }
}

private struct BackupRecordRow: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let record: BackupRecord
    @State private var hovering = false

    var body: some View {
        let backup = model.cloudBackup
        let state = backup.states[record.id] ?? .notSyncing
        let category = FileCategory.classify(name: record.name, kind: .file)
        let from = CloudBackupFinder.folderName((record.originalPath as NSString).deletingLastPathComponent, home: backup.home)
        HStack(spacing: 10) {
            IconTile(symbol: category.symbol, gradient: .tile(category.color), size: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(record.name).lineLimit(1).truncationMode(.middle)
                Text(String(format: String(localized: "From %@ · in %@ · %@"), from, record.provider,
                            record.date.formatted(date: .abbreviated, time: .omitted)))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 8)
            Label(state.label, systemImage: state.symbol)
                .font(.caption.weight(.semibold))
                .foregroundStyle(state.color)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Capsule().fill(state.color.opacity(0.12)))
                .symbolEffect(.pulse, isActive: state == .uploading && !reduceMotion)
                .contentTransition(.symbolEffect(.replace))
            Text(record.bytes.bytes)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(minWidth: 64, alignment: .trailing)
            if state == .missing {
                Button("Forget") { backup.forget(record) }
                    .help("Remove it from this list. Nothing on disk is changed.")
            } else {
                Button {
                    backup.restore(record)
                } label: {
                    if backup.restoring.contains(record.id) {
                        ProgressView().controlSize(.small)
                    } else {
                        Label("Restore", systemImage: "arrow.uturn.backward")
                    }
                }
                .help("Move the file back to where it was")
                .disabled(backup.restoring.contains(record.id) || backup.freePhase != .list)
                Button { backup.reveal(record.destinationPath) } label: { Image(systemName: "magnifyingglass") }
                    .buttonStyle(.borderless)
                    .help("Show in Finder")
            }
        }
        .controlSize(.small)
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .background(hovering ? Color.primary.opacity(0.04) : Color.clear)
        .onHover { inside in withAnimation(Motion.hover.unless(reduceMotion)) { hovering = inside } }
        .contextMenu {
            Button("Show in Finder") { backup.reveal(record.destinationPath) }
            Button("Restore") { backup.restore(record) }
        }
    }
}
