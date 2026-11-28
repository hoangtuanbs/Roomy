import Charts
import RoomyCore
import SwiftUI

/// Space Freed: everything RoomyDisk moved to the Trash, as a total, a bar for each month, and a list by date or by
/// tool. Items still in the Trash can be shown there, where Put Back brings them home. Read-only.
struct HistoryView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        @Bindable var history = model.history

        ToolSheet {
            HistoryHeader()
        } content: {
            ZStack {
                if !history.loaded {
                    ProgressView().controlSize(.large)
                        .transition(.opacity)
                } else if history.history.entries.isEmpty {
                    ContentUnavailableView {
                        Label("Nothing freed yet", systemImage: "clock.arrow.circlepath")
                    } description: {
                        Text("When you clean with Smart Clean, Duplicates, the Uninstaller or any other tool, what you freed shows here.")
                    }
                    .transition(.opacity)
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 16) {
                            FreedChart(months: history.history.months)
                                .entrance()
                            Picker("Show", selection: $history.grouping) {
                                ForEach(HistoryModel.Grouping.allCases) { Text($0.label).tag($0) }
                            }
                            .pickerStyle(.segmented)
                            .labelsHidden()
                            .frame(maxWidth: 260)
                            .entrance(index: 1)
                            switch history.grouping {
                            case .date: HistoryByDate()
                            case .tool: HistoryByTool()
                            }
                        }
                        .padding(18)
                    }
                    .transition(.opacity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .animation(Motion.smooth.unless(reduceMotion), value: history.loaded)
        } footer: {
            HStack(spacing: 10) {
                Label("Items stay in the Trash until you empty it. Use Put Back in Finder to restore anything.",
                      systemImage: "arrow.uturn.backward.circle")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .frame(minWidth: 780, idealWidth: 860, minHeight: 600, idealHeight: 720)
    }
}

private struct HistoryHeader: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let history = model.history.history
        ToolSheetHeader(title: "Space Freed", subtitle: Text("Everything RoomyDisk moved to the Trash for you."),
                        gradient: .history) {
            Image(systemName: "clock.arrow.circlepath")
        } accessory: {
            if model.history.loaded {
                ToolSheetTotal(value: Text(history.freedBytes.bytes),
                               caption: Text("in \(history.entries.count) \(Plural.word(history.entries.count, "clean", "cleans"))"),
                               color: FileCategory.image.color)
                    .contentTransition(.numericText())
            }
        }
    }
}

/// A bar for each of the last twelve months. The bars grow up from the axis when the chart first appears.
private struct FreedChart: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let months: [SpaceFreedHistory.Month]
    @State private var grown = false

    var body: some View {
        let thisMonth = months.last?.freedBytes ?? 0
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("Freed per month").font(.headline)
                Spacer()
                Text("\(thisMonth.bytes) this month")
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Chart(months) { month in
                BarMark(x: .value("Month", month.start, unit: .month),
                        y: .value("Freed", grown ? Double(month.freedBytes) : 0))
                    .foregroundStyle(LinearGradient.history)
                    .cornerRadius(5)
            }
            .chartYScale(domain: 0...max(1, Double(months.map(\.freedBytes).max() ?? 0)) * 1.1)
            .chartYAxis {
                AxisMarks(values: .automatic(desiredCount: 4)) { value in
                    AxisGridLine().foregroundStyle(Palette.hairline)
                    AxisValueLabel {
                        if let bytes = value.as(Double.self) { Text(Int64(bytes).bytes) }
                    }
                }
            }
            .chartXAxis {
                AxisMarks(values: .stride(by: .month)) { _ in
                    AxisValueLabel(format: .dateTime.month(.abbreviated), centered: true)
                }
            }
            .frame(height: 170)
            .accessibilityLabel(Text("Freed per month"))
        }
        .padding(16)
        .card(hoverable: false)
        .onAppear {
            guard !grown else { return }
            if reduceMotion { grown = true } else { withAnimation(Motion.bouncy.delay(0.15)) { grown = true } }
        }
    }
}

/// The cleans by day, newest first.
private struct HistoryByDate: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let days = model.history.days
        LazyVStack(alignment: .leading, spacing: 8) {
            ForEach(Array(days.enumerated()), id: \.element.id) { dayIndex, day in
                Text(HistoryModel.dayTitle(day.day))
                    .font(Typo.sectionLabel)
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                    .padding(.top, dayIndex == 0 ? 4 : 10)
                    .padding(.leading, 4)
                ForEach(Array(day.entries.enumerated()), id: \.element.id) { index, entry in
                    HistoryEntryCard(entry: entry, showsTool: true)
                        .entrance(index: dayIndex + index + 2)
                }
            }
        }
    }
}

/// A card for each tool with what it freed, opening up to its cleans.
private struct HistoryByTool: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let history = model.history
        let tools = history.history.tools
        let most = max(1, tools.first?.freedBytes ?? 1)
        LazyVStack(alignment: .leading, spacing: 10) {
            ForEach(Array(tools.enumerated()), id: \.element.id) { index, total in
                let id = "tool-" + total.id
                VStack(alignment: .leading, spacing: 10) {
                    Button {
                        withAnimation(Motion.spring.unless(reduceMotion)) { history.toggle(id) }
                    } label: {
                        HStack(spacing: 12) {
                            IconTile(symbol: total.tool.symbol, gradient: total.tool.gradient, size: 34)
                            VStack(alignment: .leading, spacing: 5) {
                                HStack {
                                    Text(total.tool.title).font(.headline)
                                    Text("\(total.cleans) \(Plural.word(total.cleans, "clean", "cleans"))")
                                        .font(.callout)
                                        .foregroundStyle(.secondary)
                                    Spacer()
                                    Text(total.freedBytes.bytes)
                                        .font(.system(.title3, design: .rounded).weight(.semibold))
                                        .monospacedDigit()
                                }
                                SizeBar(fraction: Double(total.freedBytes) / Double(most), color: total.tool.color, height: 6)
                            }
                            Image(systemName: "chevron.right")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .rotationEffect(.degrees(history.expanded.contains(id) ? 90 : 0))
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    if history.expanded.contains(id) {
                        VStack(spacing: 8) {
                            ForEach(history.history.entries(of: total.tool)) { entry in
                                HistoryEntryCard(entry: entry, showsTool: false)
                            }
                        }
                        .transition(.opacity.combined(with: .move(edge: .top)))
                    }
                }
                .padding(14)
                .card()
                .entrance(index: index + 2)
            }
        }
    }
}

/// One clean: the tool, when, how many items and how much. Opens up to the items, each with Show in Trash while
/// it is still there.
private struct HistoryEntryCard: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let entry: SpaceFreedHistory.Entry
    let showsTool: Bool

    var body: some View {
        let history = model.history
        let id = "entry-\(entry.id)"
        let open = history.expanded.contains(id)
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(Motion.spring.unless(reduceMotion)) { history.toggle(id) }
            } label: {
                HStack(spacing: 12) {
                    if showsTool {
                        IconTile(symbol: entry.tool.symbol, gradient: entry.tool.gradient, size: 28)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(showsTool ? entry.tool.title : entry.date.formatted(date: .abbreviated, time: .omitted))
                            .font(.body.weight(.medium))
                        Text("\(entry.date.formatted(date: .omitted, time: .shortened)) · \(entry.items.count) \(Plural.word(entry.items.count, "item", "items"))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(entry.freedBytes.bytes)
                        .font(.body.weight(.semibold))
                        .monospacedDigit()
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(open ? 90 : 0))
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if open {
                Divider().padding(.horizontal, 12)
                VStack(spacing: 0) {
                    ForEach(Array(entry.items.prefix(200).enumerated()), id: \.offset) { _, item in
                        HistoryItemRow(item: item)
                    }
                    if entry.items.count > 200 {
                        Text("and \(entry.items.count - 200) more")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(8)
                    }
                }
                .padding(.vertical, 4)
                .transition(.opacity)
            }
        }
        .card(radius: Radius.control + 2)
    }
}

private struct HistoryItemRow: View {
    @Environment(AppModel.self) private var model
    let item: CleanupResult

    var body: some View {
        let history = model.history
        HStack(spacing: 10) {
            Image(systemName: "doc")
                .foregroundStyle(.secondary)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text((item.path as NSString).lastPathComponent)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text((item.path as NSString).deletingLastPathComponent)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            Spacer(minLength: 8)
            Text(item.bytes.bytes)
                .font(.callout)
                .monospacedDigit()
                .foregroundStyle(.secondary)
            if history.isInTrash(item) {
                Button("Show in Trash") { history.showInTrash(item) }
                    .controlSize(.small)
            } else {
                Text("Not in the Trash")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .help("The Trash was emptied or the item was put back.")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
    }
}
