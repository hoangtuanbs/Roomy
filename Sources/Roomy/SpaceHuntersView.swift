import RoomyCore
import SwiftUI

/// The gold-to-green gradient used for Space Hunters.
extension LinearGradient {
    static let spaceHunters = LinearGradient(
        colors: [Color(red: 0.96, green: 0.66, blue: 0.20), Color(red: 0.36, green: 0.72, blue: 0.48)],
        startPoint: .topLeading, endPoint: .bottomTrailing
    )
}

extension SpaceHuntersModel.Hunter {
    var title: String {
        switch self {
        case .backups: return String(localized: "iPhone & iPad backups")
        case .downloads: return String(localized: "Old downloads")
        case .mail: return String(localized: "Mail attachments")
        case .photos: return String(localized: "Similar photos")
        }
    }

    var shortTitle: String {
        switch self {
        case .backups: return String(localized: "Backups")
        case .downloads: return "Downloads"
        case .mail: return String(localized: "Mail")
        case .photos: return String(localized: "Photos")
        }
    }

    var symbol: String {
        switch self {
        case .backups: return "iphone.gen3"
        case .downloads: return "arrow.down.circle.fill"
        case .mail: return "paperclip"
        case .photos: return "photo.on.rectangle.angled"
        }
    }

    var color: Color {
        switch self {
        case .backups: return Color(red: 0.29, green: 0.52, blue: 0.86)
        case .downloads: return Color(red: 0.62, green: 0.45, blue: 0.85)
        case .mail: return Color(red: 0.25, green: 0.70, blue: 0.80)
        case .photos: return Color(red: 0.36, green: 0.72, blue: 0.48)
        }
    }

    /// Said on the card when nothing was found.
    var emptyNote: String {
        switch self {
        case .backups: return String(localized: "No iPhone or iPad backups on this Mac.")
        case .downloads: return String(localized: "Everything in Downloads was used in the last 90 days.")
        case .mail: return String(localized: "Mail keeps no attachments on this Mac.")
        case .photos: return String(localized: "No look-alike pictures were found.")
        }
    }

    var explanation: String {
        switch self {
        case .backups:
            return String(localized: "Backups Finder made of your iPhone and iPad. Older backups of a device you back up again are rarely needed. The newest backup of each device is never ticked.")
        case .downloads:
            return String(localized: "Files and folders in Downloads you have not opened, added or changed for 90 days or more. Nothing is ticked: look through them first.")
        case .mail:
            return String(localized: "Attachments Mail keeps in its own folder can only be removed in Mail. Copies of attachments you opened (Mail Downloads) can go to the Trash; Mail makes them again when needed.")
        case .photos:
            return String(localized: "Pictures that look almost the same, such as several shots of one moment. The sharpest, newest one is suggested to keep. Nothing is ticked: pick what to remove.")
        }
    }
}

/// Space Hunters: finds big, forgotten things in four places and moves what you tick to the Trash.
struct SpaceHuntersView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var confirmClean = false

    var body: some View {
        let hunters = model.spaceHunters

        VStack(spacing: 0) {
            SpaceHuntersHeader()
            Divider()
            ZStack {
                switch hunters.phase {
                case .idle:
                    ContentUnavailableView {
                        Label("Ready to hunt", systemImage: "scope")
                    } actions: {
                        Button("Start Hunting") { model.huntSpace() }
                            .buttonStyle(.borderedProminent)
                    }
                    .transition(.opacity)
                case .hunting:
                    HuntingProgress()
                        .transition(.opacity)
                case .ready:
                    HuntResults()
                        .transition(.opacity.combined(with: .scale(scale: 0.98)))
                case .cleaning:
                    CleaningProgressRing(fraction: hunters.cleanFraction, bytes: hunters.cleanedBytes,
                                         done: hunters.cleanedCount, total: hunters.cleanTotal, gradient: .spaceHunters)
                        .padding(32)
                        .transition(.opacity.combined(with: .scale(scale: 0.95)))
                case .done:
                    let moved = hunters.report?.succeeded.count ?? 0
                    FreedSpaceCelebration(
                        bytes: hunters.cleanedBytes,
                        message: Plural.movedToTrash(moved),
                        failed: hunters.report?.failed ?? []
                    )
                    .transition(.opacity.combined(with: .scale(scale: 0.9)))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .animation(Motion.smooth.unless(reduceMotion), value: hunters.phase)
            Divider()
            footer
        }
        .frame(minWidth: 780, idealWidth: 860, minHeight: 600, idealHeight: 720)
        .interactiveDismissDisabled(hunters.isBusy)
        .alert("Move \(hunters.selectedCount) \(Plural.word(hunters.selectedCount, "item", "items")) to the Trash?",
               isPresented: $confirmClean) {
            Button("Move to Trash") { hunters.clean() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This frees about \(hunters.selectedBytes.bytes) once you empty the Trash. Until then, Put Back in Finder restores anything.")
        }
    }

    @ViewBuilder
    private var footer: some View {
        let hunters = model.spaceHunters
        HStack(spacing: 10) {
            switch hunters.phase {
            case .idle:
                Spacer()
                Button("Close") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            case .hunting:
                Spacer()
                Button("Cancel") {
                    hunters.cancel()
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
            case .ready:
                Text("Only what you tick is moved, and it goes to the Trash.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Hunt Again") { model.huntSpace() }
                Button("Close") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button {
                    confirmClean = true
                } label: {
                    Label("Move to Trash", systemImage: "trash").padding(.horizontal, 6)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(hunters.selectedCount == 0)
            case .cleaning:
                Spacer()
                Text("Please wait…").foregroundStyle(.secondary)
            case .done:
                Button("Open Trash") { hunters.openTrash() }
                Spacer()
                Button("Show Remaining") { hunters.showRemaining() }
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(.horizontal, 18)
        .frame(height: 56)
    }
}

private struct SpaceHuntersHeader: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let hunters = model.spaceHunters
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous).fill(LinearGradient.spaceHunters)
                Image(systemName: "scope")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(.white)
                    .symbolEffect(.pulse, isActive: hunters.isBusy && !reduceMotion)
            }
            .frame(width: 46, height: 46)

            VStack(alignment: .leading, spacing: 3) {
                Text("Space Hunters").font(.title2.weight(.semibold))
                Text("Big things you may have forgotten about.")
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer()
            if hunters.phase == .ready {
                VStack(alignment: .trailing, spacing: 2) {
                    Text(hunters.selectedBytes.bytes)
                        .font(.system(size: 26, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .contentTransition(.numericText(value: Double(hunters.selectedBytes)))
                        .animation(Motion.quick.unless(reduceMotion), value: hunters.selectedBytes)
                    Text("\(hunters.selectedCount) \(Plural.word(hunters.selectedCount, "item", "items")) selected")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .contentTransition(.numericText())
                        .animation(Motion.quick.unless(reduceMotion), value: hunters.selectedCount)
                }
                .transition(.opacity.combined(with: .move(edge: .trailing)))
            }
        }
        .padding(18)
        .animation(Motion.smooth.unless(reduceMotion), value: hunters.phase)
    }
}

/// One ring for the whole hunt, and a line for each hunter that ticks off as it finishes.
private struct HuntingProgress: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let hunters = model.spaceHunters
        VStack(spacing: 22) {
            ZStack {
                BusyRing(gradient: .spaceHunters, size: 150, lineWidth: 4) { EmptyView() }
                Circle()
                    .trim(from: 0, to: max(0.02, hunters.huntFraction))
                    .stroke(LinearGradient.spaceHunters, style: StrokeStyle(lineWidth: 10, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .padding(16)
                    .animation(Motion.smooth.unless(reduceMotion), value: hunters.huntFraction)
                Text("\(Int((hunters.huntFraction * 100).rounded()))%")
                    .font(.system(size: 26, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                    .animation(Motion.quick.unless(reduceMotion), value: Int(hunters.huntFraction * 100))
            }
            .frame(width: 150, height: 150)

            VStack(spacing: 8) {
                ForEach(Array(SpaceHuntersModel.Hunter.allCases.enumerated()), id: \.element) { index, hunter in
                    HuntingLine(hunter: hunter)
                        .entrance(index: index, offset: 10)
                }
            }
            .frame(width: 380)
            Text("Files are only read. Nothing is moved yet.")
                .font(.callout)
                .foregroundStyle(.tertiary)
        }
        .padding(32)
    }
}

private struct HuntingLine: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let hunter: SpaceHuntersModel.Hunter

    var body: some View {
        let hunters = model.spaceHunters
        let done = hunters.finished.contains(hunter)
        HStack(spacing: 10) {
            Image(systemName: hunter.symbol)
                .foregroundStyle(hunter.color)
                .frame(width: 22)
            Text(hunter.title)
            Spacer()
            if done {
                Text(hunter == .backups && hunters.backupsNeedAccess ? String(localized: "Needs access") : hunters.foundBytes(hunter).bytes)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .transition(.opacity.combined(with: .move(edge: .trailing)))
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .transition(.scale.combined(with: .opacity))
            } else {
                if hunter == .photos && hunters.photosToCheck > 0 {
                    Text("\(hunters.photosChecked) of \(hunters.photosToCheck)")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .contentTransition(.numericText())
                }
                ProgressView().controlSize(.small)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.primary.opacity(0.04)))
        .animation(Motion.bouncy.unless(reduceMotion), value: done)
    }
}

private struct HuntResults: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let hunters = model.spaceHunters
        ScrollView {
            VStack(spacing: 10) {
                HuntSummary()
                ForEach(Array(SpaceHuntersModel.Hunter.allCases.enumerated()), id: \.element) { index, hunter in
                    HunterCard(hunter: hunter, index: index + 1)
                }
                if hunters.photosCapped {
                    Text("Similar photos compared the \(PhotoSource.limit.formatted()) largest pictures only.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(16)
        }
    }
}

/// The total each hunter found, counting up as the results appear.
private struct HuntSummary: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var appeared = false

    var body: some View {
        let hunters = model.spaceHunters
        HStack(spacing: 10) {
            ForEach(Array(SpaceHuntersModel.Hunter.allCases.enumerated()), id: \.element) { index, hunter in
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Image(systemName: hunter.symbol)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(hunter.color)
                        Text(hunter.shortTitle).font(.caption).foregroundStyle(.secondary)
                    }
                    if hunter == .backups && hunters.backupsNeedAccess {
                        Text("Needs access").font(.title3.weight(.semibold)).foregroundStyle(.orange)
                    } else {
                        CountingBytes(appeared ? hunters.foundBytes(hunter) : 0)
                            .font(.title3.weight(.semibold))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(hunter.color.opacity(0.08)))
                .entrance(index: index, offset: 10)
            }
        }
        .onAppear {
            guard !appeared else { return }
            withAnimation(Motion.smooth.delay(0.15).unless(reduceMotion)) { appeared = true }
        }
    }
}
