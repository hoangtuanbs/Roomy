import RoomyCore
import SwiftUI

/// The "Can be freed" part of the menu bar popover: what the last background check found, and Quick Clean, which
/// moves only the safe part to the Trash after a confirmation right here in the popover.
struct MenuBarQuickClean: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var check: AutoCheckModel { model.autoCheck }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            Group {
                switch check.phase {
                case .idle, .confirming:
                    summary
                case .cleaning:
                    CleaningProgressRing(fraction: check.cleanFraction, bytes: check.cleanedBytes,
                                         done: check.cleanedCount, total: check.cleanTotal,
                                         gradient: .smartClean, size: 110)
                        .frame(maxWidth: .infinity)
                        .transition(.opacity.combined(with: .scale(scale: 0.95)))
                case .done:
                    result
                        .transition(.opacity.combined(with: .scale(scale: 0.95)))
                }
            }
        }
        .motion(Motion.smooth, value: check.phase)
        .motion(Motion.quick, value: check.isChecking)
    }

    private var header: some View {
        HStack(spacing: 6) {
            Text("Can be freed")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
            Spacer()
            if check.isChecking {
                ProgressView().controlSize(.mini)
                Text("Checking…").font(.system(size: 11)).foregroundStyle(.secondary)
            } else if let date = check.summary?.date {
                TimelineView(.periodic(from: .now, by: 60)) { context in
                    Text(Self.checkedText(date, now: context.date))
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
            }
            if !check.isChecking && check.phase == .idle {
                Button { check.check() } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless)
                    .font(.system(size: 11))
                    .help("Check for junk now")
            }
        }
    }

    @ViewBuilder private var summary: some View {
        if let summary = check.summary {
            VStack(alignment: .leading, spacing: 8) {
                Text(summary.totalBytes.bytes)
                    .font(.system(size: 26, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText(value: Double(summary.totalBytes)))
                    .motion(Motion.quick, value: summary.totalBytes)
                if summary.parts.isEmpty {
                    Text("No caches or logs to clear right now.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(Array(summary.parts.prefix(4).enumerated()), id: \.element.category) { index, part in
                        CategoryBar(part: part, total: summary.totalBytes)
                            .entrance(index: index, offset: 6)
                    }
                }
                actions(summary)
            }
        } else {
            Text(check.isChecking ? "Looking at caches and logs…" : "Not checked yet.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            if !check.isChecking {
                QuickCleanButton(title: "Check Now", symbol: "magnifyingglass") { check.check() }
            }
        }
    }

    @ViewBuilder private func actions(_ summary: JunkSummary) -> some View {
        if check.phase == .confirming {
            VStack(alignment: .leading, spacing: 8) {
                Text("Move \(check.quickCleanBytes.bytes) of \(summary.phrase) to the Trash?")
                    .font(.system(size: 12, weight: .semibold))
                    .fixedSize(horizontal: false, vertical: true)
                Text("\(check.quickCleanItems.count) \(Plural.word(check.quickCleanItems.count, "item", "items")). Apps make these again when needed, and you can put them back from the Trash.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("Cancel") { check.cancelClean() }
                        .keyboardShortcut(.cancelAction)
                    Spacer()
                    Button("Move to Trash") { check.clean() }
                        .keyboardShortcut(.defaultAction)
                }
                .controlSize(.small)
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(0.06)))
            .transition(.opacity.combined(with: .move(edge: .top)))
        } else if !check.findings.isEmpty {
            QuickCleanButton(title: "Quick Clean", symbol: "sparkles") { check.askToClean() }
                .disabled(check.quickCleanItems.isEmpty)
                .opacity(check.quickCleanItems.isEmpty ? 0.5 : 1)
        } else if summary.totalBytes > 0 && check.isChecking {
            // After a relaunch only the totals are known; the check the popover started brings the list back.
            QuickCleanButton(title: "Quick Clean", symbol: "sparkles") {}
                .disabled(true)
                .opacity(0.5)
                .help("Getting the list ready…")
        } else if summary.totalBytes > 0 {
            // The check was stopped, such as by sleep; check again to know what to move.
            QuickCleanButton(title: "Check Again to Clean", symbol: "arrow.clockwise") { check.check() }
        }
    }

    private var result: some View {
        VStack(spacing: 8) {
            FreedSpaceCelebration(bytes: check.cleanedBytes,
                                  message: String(localized: "Moved to the Trash. You can put anything back from there."),
                                  failed: check.report?.failed ?? [],
                                  succeeded: (check.report?.succeeded.isEmpty == false),
                                  confetti: false, compact: true, maxWidth: 240)
            Button("Done") { check.dismissResult() }
                .controlSize(.small)
        }
        .frame(maxWidth: .infinity)
    }

    /// "Checked just now", "Checked 2 hr. ago".
    static func checkedText(_ date: Date, now: Date) -> String {
        if now.timeIntervalSince(date) < 60 { return String(localized: "Checked just now") }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return String(localized: "Checked ") + formatter.localizedString(for: date, relativeTo: now)
    }
}

/// One kind of junk: its symbol, name, a bar of its share and its size.
private struct CategoryBar: View {
    let part: JunkSummary.Part
    let total: Int64

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: part.category.symbol)
                .font(.system(size: 10))
                .foregroundStyle(part.category.color)
                .frame(width: 14)
            Text(part.category.plainName.capitalized)
                .font(.system(size: 11))
                .frame(width: 92, alignment: .leading)
                .lineLimit(1)
            SizeBar(fraction: total > 0 ? Double(part.bytes) / Double(total) : 0, color: part.category.color)
            Text(part.bytes.bytes)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .contentTransition(.numericText(value: Double(part.bytes)))
                .frame(width: 60, alignment: .trailing)
        }
    }
}

/// The wide gradient button of the popover.
private struct QuickCleanButton: View {
    let title: LocalizedStringKey
    let symbol: String
    let action: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isEnabled) private var isEnabled
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(LinearGradient.smartClean))
                .shadow(color: Color(red: 0.45, green: 0.45, blue: 0.9).opacity(hovering ? 0.35 : 0.15),
                        radius: hovering ? 5 : 2, y: 1)
                .scaleEffect(hovering && isEnabled && !reduceMotion ? 1.02 : 1)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { inside in
            withAnimation(Motion.quick.unless(reduceMotion)) { hovering = inside }
        }
    }
}
