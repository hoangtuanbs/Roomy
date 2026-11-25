import RoomyCore
import SwiftUI

/// Finds junk in known places, shows it as cards, and moves what is ticked to the Trash.
struct SmartCleanView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let clean = model.smartClean

        ToolSheet {
            SmartCleanHeader()
        } content: {
            ZStack {
                switch clean.phase {
                case .idle, .scanning:
                    SmartCleanScanning()
                        .transition(.opacity)
                case .ready:
                    SmartCleanResults()
                        .transition(.opacity.combined(with: .scale(scale: 0.98)))
                case .cleaning:
                    SmartCleanProgress()
                        .transition(.opacity.combined(with: .scale(scale: 0.95)))
                case .done:
                    SmartCleanDone()
                        .transition(.opacity.combined(with: .scale(scale: 0.9)))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .animation(Motion.smooth.unless(reduceMotion), value: clean.phase)
        } footer: {
            footer
        }
        .frame(minWidth: 720, idealWidth: 780, minHeight: 560, idealHeight: 680)
        .interactiveDismissDisabled(clean.isBusy)
    }

    @ViewBuilder
    private var footer: some View {
        let clean = model.smartClean
        HStack(spacing: 10) {
            switch clean.phase {
            case .idle, .scanning:
                Spacer()
                Button("Cancel") {
                    clean.cancelScan()
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
            case .ready:
                Text("Items go to the Trash, so Put Back still works.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Scan Again") { clean.scan(tree: model.tree) }
                    .disabled(clean.isBusy)
                Button("Close") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(clean.isBusy)
                Button {
                    clean.clean()
                } label: {
                    Label("Clean", systemImage: "sparkles").padding(.horizontal, 6)
                }
                .buttonStyle(.primaryAction(.smartClean))
                .disabled(clean.selectedItems.isEmpty || clean.isBusy)
                // Not the default button, so Return alone never moves anything.
            case .cleaning:
                Spacer()
                Text("Please wait…").foregroundStyle(.secondary)
            case .done:
                Button("Open Trash") { clean.openTrash() }
                Spacer()
                Button("Scan Again") { clean.scan(tree: model.tree) }
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
    }
}

private struct SmartCleanHeader: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let clean = model.smartClean
        ToolSheetHeader(title: "Smart Clean", subtitle: Text("Caches, logs and leftovers that are safe to remove."),
                        gradient: .smartClean) {
                Image(systemName: "sparkles")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(.white)
                    .symbolEffect(.pulse, isActive: clean.isBusy && !reduceMotion)
        } accessory: {
            if clean.phase == .ready {
                VStack(alignment: .trailing, spacing: 2) {
                    Text(clean.selectedBytes.bytes)
                        .font(.system(size: 28, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .contentTransition(.numericText(value: Double(clean.selectedBytes)))
                        .animation(Motion.quick.unless(reduceMotion), value: clean.selectedBytes)
                    Text("\(clean.selectedItems.count) \(Plural.word(clean.selectedItems.count, "item", "items")) selected")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .contentTransition(.numericText())
                }
                .transition(.opacity.combined(with: .move(edge: .trailing)))
            }
        }
        .animation(Motion.smooth.unless(reduceMotion), value: clean.phase)
    }
}

private struct SmartCleanScanning: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let step: String = {
            if case .scanning(let text) = model.smartClean.phase { return text }
            return String(localized: "Looking for junk…")
        }()
        VStack(spacing: 18) {
            BusyRing(gradient: .smartClean, period: 1) {
                Image(systemName: "sparkle.magnifyingglass")
                    .font(.system(size: 30, weight: .medium))
                    .foregroundStyle(LinearGradient.smartClean)
            }
            Text(step)
                .font(.title3.weight(.medium))
                .contentTransition(.opacity)
                .motion(Motion.quick, value: step)
            Text("Only places known to hold junk are checked. Nothing is moved yet.")
                .foregroundStyle(.secondary)
        }
        .padding(32)
    }
}

private struct SmartCleanResults: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let clean = model.smartClean
        if clean.findings.isEmpty {
            ContentUnavailableView(
                "Nothing to clean",
                systemImage: "checkmark.seal",
                description: Text("No caches, logs or leftovers worth removing were found.")
            )
        } else {
            ScrollView {
                VStack(spacing: 10) {
                    ForEach(Array(clean.cleanable.enumerated()), id: \.element.id) { index, finding in
                        FindingCard(finding: finding, index: index)
                            .transition(.asymmetric(insertion: .opacity, removal: .opacity.combined(with: .scale(scale: 0.95))))
                    }
                    if let trash = clean.trash {
                        HStack {
                            Text("Erased for good").font(.headline)
                            Spacer()
                        }
                        .padding(.top, 12)
                        .padding(.horizontal, 4)
                        FindingCard(finding: trash, index: clean.cleanable.count)
                    }
                    if let result = clean.trashResult {
                        TrashResultBanner(result: result)
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                }
                .padding(16)
            }
        }
    }
}

private struct FindingCard: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let finding: JunkFinding
    let index: Int
    @State private var appeared = false
    @State private var confirmEmpty = false

    private static let shownItems = 300

    var body: some View {
        let clean = model.smartClean
        let state = clean.selection.state(of: finding)
        let isExpanded = clean.expanded.contains(finding.id)
        let color = finding.category.color

        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 12) {
                if !finding.isPermanent {
                    SelectionBox(state: state, color: color) {
                        withAnimation(Motion.quick.unless(reduceMotion)) {
                            clean.selection.setAll(finding, selected: state != .all)
                        }
                    }
                    .padding(.top, 8)
                }
                ZStack {
                    Circle().fill(color.gradient)
                    Image(systemName: finding.category.symbol)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white)
                }
                .frame(width: 34, height: 34)

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(finding.title).font(.headline)
                        if !finding.preselected && !finding.isPermanent {
                            Badge(text: "Review first", color: .orange)
                        }
                        if finding.isPermanent {
                            Badge(text: "Cannot be undone", color: .red)
                        }
                    }
                    Text(finding.explanation)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 12)

                VStack(alignment: .trailing, spacing: 3) {
                    CountingBytes(appeared ? finding.bytes : 0)
                        .font(.title3.weight(.semibold))
                    Text(subtitle(state: state))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .contentTransition(.numericText())
                    if finding.isPermanent {
                        Button("Empty Trash…", role: .destructive) { confirmEmpty = true }
                            .disabled(clean.isEmptyingTrash || clean.phase != .ready)
                            .padding(.top, 4)
                    }
                }

                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    .padding(.top, 8)
            }
            .padding(14)
            .contentShape(Rectangle())
            .onTapGesture {
                withAnimation(Motion.spring.unless(reduceMotion)) { clean.toggleExpanded(finding) }
            }
            .help(isExpanded ? "Hide the items" : "Show the items")

            if isExpanded {
                Divider().padding(.horizontal, 14)
                VStack(spacing: 0) {
                    ForEach(finding.items.prefix(Self.shownItems)) { item in
                        JunkItemRow(item: item, finding: finding)
                            .transition(.opacity)
                    }
                    if finding.items.count > Self.shownItems {
                        Text("and \(finding.items.count - Self.shownItems) more")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(8)
                    }
                }
                .padding(.vertical, 6)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(finding.isPermanent ? Color.red.opacity(0.05) : Palette.card)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(state == .none ? Color.primary.opacity(0.08) : color.opacity(0.55), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .opacity(appeared ? 1 : 0)
        .offset(y: appeared ? 0 : 16)
        .scaleEffect(appeared ? 1 : 0.97)
        .onAppear {
            guard !appeared else { return }
            withAnimation(Motion.stagger(index).unless(reduceMotion)) { appeared = true }
        }
        .alert("Empty the Trash?", isPresented: $confirmEmpty) {
            Button("Empty Trash", role: .destructive) { clean.emptyTrash() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This erases \(finding.items.count) \(Plural.word(finding.items.count, "item", "items")) (\(finding.bytes.bytes)) for good. You cannot undo this or put them back.")
        }
    }

    private func subtitle(state: JunkSelection.State) -> String {
        let count = "\(finding.items.count) \(Plural.word(finding.items.count, "item", "items"))"
        guard !finding.isPermanent, state == .some else { return count }
        return String(format: String(localized: "%@ of %@"), model.smartClean.selection.selectedBytes(in: finding).bytes, count)
    }

}

private struct JunkItemRow: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let item: JunkItem
    let finding: JunkFinding

    var body: some View {
        let clean = model.smartClean
        HStack(spacing: 10) {
            if !finding.isPermanent {
                SelectionBox(state: clean.selection.contains(item) ? .all : .none, color: finding.category.color) {
                    withAnimation(Motion.quick.unless(reduceMotion)) {
                        clean.selection.toggle(item, in: finding)
                    }
                }
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(item.name).lineLimit(1)
                Text((item.path as NSString).abbreviatingWithTildeInPath)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 8)
            Text(item.bytes.bytes)
                .monospacedDigit()
                .foregroundStyle(.secondary)
            Button {
                clean.reveal(item.path)
            } label: {
                Image(systemName: "magnifyingglass")
            }
            .buttonStyle(.borderless)
            .help("Show in Finder")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 5)
    }
}

struct SelectionBox: View {
    let state: JunkSelection.State
    let color: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 17))
                .foregroundStyle(state == .none ? Color.secondary : color)
                .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(.borderless)
        .help(state == .all ? "Untick" : "Tick")
    }

    private var symbol: String {
        switch state {
        case .all: return "checkmark.circle.fill"
        case .some: return "minus.circle.fill"
        case .none: return "circle"
        }
    }
}

struct Badge: View {
    let text: LocalizedStringKey
    let color: Color

    var body: some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(color.opacity(0.16)))
            .foregroundStyle(color)
    }
}

private struct TrashResultBanner: View {
    let result: TrashEraseResult

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: result.failed.isEmpty ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(result.failed.isEmpty ? Color.green : Color.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text("Erased \(result.erased.count) \(Plural.word(result.erased.count, "item", "items")) from the Trash, \(result.freedBytes.bytes) freed.")
                if !result.failed.isEmpty {
                    Text("\(result.failed.count) could not be erased. RoomyDisk may need Full Disk Access.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.green.opacity(0.08)))
    }
}

private struct SmartCleanProgress: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let clean = model.smartClean
        CleaningProgressRing(fraction: clean.cleanFraction, bytes: clean.cleanedBytes,
                             done: clean.cleanedCount, total: clean.cleanTotal, gradient: .smartClean)
            .padding(32)
    }
}

private struct SmartCleanDone: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let clean = model.smartClean
        let moved = clean.report?.succeeded.count ?? 0
        FreedSpaceCelebration(
            bytes: clean.cleanedBytes,
            message: Plural.movedToTrash(moved),
            failed: clean.report?.failed ?? [],
            maxWidth: 440
        )
    }
}
