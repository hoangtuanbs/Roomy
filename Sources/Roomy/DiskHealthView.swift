import RoomyCore
import SwiftUI

/// Disk Health: a card for every disk with what it says about its own health. Read-only.
struct DiskHealthView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let health = model.diskHealth

        ToolSheet {
            DiskHealthHeader()
        } content: {
            ZStack {
                if health.phase != .ready && health.reports.isEmpty {
                    DiskHealthProgress()
                        .transition(.opacity)
                } else if health.reports.isEmpty {
                    ContentUnavailableView("No disks found", systemImage: "internaldrive",
                                           description: Text("macOS didn't list any physical disks."))
                        .transition(.opacity)
                } else {
                    ScrollView {
                        VStack(spacing: 14) {
                            ForEach(Array(health.reports.enumerated()), id: \.element.id) { index, report in
                                DiskHealthCard(report: report, index: index)
                                    .entrance(index: index)
                            }
                        }
                        .padding(18)
                    }
                    .transition(.opacity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .animation(Motion.smooth.unless(reduceMotion), value: health.reports.isEmpty)
        } footer: {
            HStack(spacing: 10) {
                Label("Read-only: RoomyDisk only looks at what your disks report and never changes them.",
                      systemImage: "lock.shield")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer()
                Button {
                    health.refresh()
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .disabled(health.isBusy)
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .frame(minWidth: 780, idealWidth: 860, minHeight: 600, idealHeight: 720)
    }
}

private struct DiskHealthHeader: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let health = model.diskHealth
        ToolSheetHeader(title: "Disk Health", subtitle: Text("What each disk reports about itself, in plain words."),
                        gradient: .diskHealth) {
                Image(systemName: "stethoscope")
                    .font(.system(size: 21, weight: .semibold))
                    .foregroundStyle(.white)
                    .symbolEffect(.pulse, isActive: health.isBusy && !reduceMotion)
        } accessory: {
            if let overall = health.overall {
                VStack(alignment: .trailing, spacing: 2) {
                    Text(summary(overall, count: health.reports.count))
                        .font(.system(size: 20, weight: .bold, design: .rounded))
                        .foregroundStyle(overall.color)
                        .contentTransition(.opacity)
                    Text(checked(health))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .transition(.opacity.combined(with: .move(edge: .trailing)))
            }
        }
        .animation(Motion.smooth.unless(reduceMotion), value: health.overall)
    }

    private func summary(_ overall: DiskHealthVerdict, count: Int) -> String {
        switch overall {
        case .good: return count == 1 ? String(localized: "Looks good") : String(localized: "All look good")
        case .warning: return String(localized: "Worth a look")
        case .failing: return String(localized: "Back up now")
        case .unknown: return String(localized: "Can't tell")
        }
    }

    private func checked(_ health: DiskHealthModel) -> String {
        let disks = "\(health.reports.count) \(Plural.word(health.reports.count, "disk", "disks"))"
        if health.isBusy { return String(format: String(localized: "%@ · checking…"), disks) }
        guard let readAt = health.readAt else { return disks }
        return String(format: String(localized: "%@ · checked %@"), disks, readAt.formatted(date: .omitted, time: .shortened))
    }
}

/// The turning ring before the first read finishes.
private struct DiskHealthProgress: View {
    var body: some View {
        VStack(spacing: 18) {
            BusyRing(gradient: .diskHealth, size: 150, lineWidth: 9, period: 1.4) {
                Image(systemName: "stethoscope")
                    .font(.system(size: 40, weight: .semibold))
                    .foregroundStyle(LinearGradient.diskHealth)
            }
            Text("Asking your disks how they are…").font(.title3)
            Text("Only reading. Nothing is changed.")
                .font(.callout)
                .foregroundStyle(.tertiary)
        }
        .padding(32)
    }
}

/// One disk: its icon, name, connection and space, a big health badge, the explanation, and the details.
private struct DiskHealthCard: View {
    let report: DiskHealthReport
    let index: Int

    private static let adminOnly = String(localized: "Not available without admin rights")

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(report.verdict.color.opacity(0.14))
                    Image(systemName: report.isInternal == false ? "externaldrive.fill" : "internaldrive.fill")
                        .font(.system(size: 24))
                        .foregroundStyle(report.verdict.color)
                }
                .frame(width: 52, height: 52)

                VStack(alignment: .leading, spacing: 5) {
                    Text(report.name)
                        .font(.title3.weight(.semibold))
                        .lineLimit(1)
                    Text(subtitle)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    space
                }
                Spacer(minLength: 12)
                HealthBadge(verdict: report.verdict, delay: Double(min(index, 6)) * 0.06)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(report.explanation)
                    .fixedSize(horizontal: false, vertical: true)
                Text(report.advice)
                    .fontWeight(.semibold)
                    .foregroundStyle(report.verdict == .failing ? report.verdict.color : .primary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(report.verdict.color.opacity(0.08)))

            Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 7) {
                ForEach(Array(details.enumerated()), id: \.offset) { row, detail in
                    GridRow {
                        Text(detail.0)
                            .foregroundStyle(.secondary)
                            .gridColumnAlignment(.trailing)
                            .entrance(index: index * 2 + row, offset: 6, scale: 1)
                        Text(detail.1)
                            .foregroundStyle(detail.1 == Self.adminOnly ? HierarchicalShapeStyle.tertiary : .primary)
                            .textSelection(.enabled)
                            .lineLimit(1)
                            .entrance(index: index * 2 + row, offset: 6, scale: 1)
                    }
                }
            }
            .font(.callout)
        }
        .padding(18)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Palette.card))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
            .strokeBorder(report.verdict.color.opacity(0.25), lineWidth: 1))
    }

    private var subtitle: String {
        var parts: [String] = []
        if !report.volumeNames.isEmpty { parts.append(report.volumeNames.joined(separator: ", ")) }
        if let isInternal = report.isInternal { parts.append(isInternal ? String(localized: "Internal") : String(localized: "External")) }
        if let interconnect = report.interconnect { parts.append(interconnect) }
        if let solid = report.isSolidState { parts.append(solid ? String(localized: "SSD") : String(localized: "Hard disk")) }
        return parts.isEmpty ? report.id : parts.joined(separator: " · ")
    }

    @ViewBuilder
    private var space: some View {
        if let capacity = report.capacity, capacity > 0 {
            if let used = report.used {
                let fraction = Double(used) / Double(capacity)
                SizeBar(fraction: fraction, color: fraction > 0.9 ? FileCategory.video.color : FileCategory.folder.color)
                    .frame(maxWidth: 320)
                Text("\(used.bytes) used of \(capacity.bytes)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .contentTransition(.numericText(value: Double(used)))
            } else {
                Text("\(capacity.bytes) · no volume mounted")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// Such as "Apple Fabric, internal", or "Internal" when the bus isn't reported.
    private var connection: String {
        let place = report.isInternal.map { $0 ? "internal" : "external" }
        switch (report.interconnect, place) {
        case let (bus?, place?): return "\(bus), \(place)"
        case let (bus?, nil): return bus
        case let (nil, place?): return place.prefix(1).uppercased() + place.dropFirst()
        case (nil, nil): return String(localized: "Not reported")
        }
    }

    private var details: [(String, String)] {
        [
            (String(localized: "Model"), report.model ?? String(localized: "Not reported")),
            (String(localized: "Serial number"), report.maskedSerial ?? String(localized: "Not reported")),
            (String(localized: "Firmware"), report.revision ?? String(localized: "Not reported")),
            (String(localized: "Connection"), connection),
            (String(localized: "Type"), report.mediumTitle ?? String(localized: "Not reported")),
            (String(localized: "S.M.A.R.T. status"), report.smart.title),
            (String(localized: "Life used"), report.percentageUsed.map { "\($0)%" } ?? Self.adminOnly),
            (String(localized: "Power-on hours"), report.powerOnHours.map { $0.formatted() } ?? Self.adminOnly),
            (String(localized: "Temperature"), report.temperatureCelsius.map { "\($0) °C" } ?? Self.adminOnly),
            (String(localized: "Device"), report.id),
        ]
    }
}

/// The verdict in a coloured capsule that springs in when the card appears.
private struct HealthBadge: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let verdict: DiskHealthVerdict
    var delay: Double = 0
    @State private var shown = false

    var body: some View {
        VStack(spacing: 6) {
            ZStack {
                Circle().fill(verdict.color.opacity(0.15))
                Circle().strokeBorder(verdict.color.opacity(0.5), lineWidth: 2)
                Image(systemName: verdict.symbol)
                    .font(.system(size: 30, weight: .semibold))
                    .foregroundStyle(verdict.color)
                    .contentTransition(.symbolEffect(.replace))
            }
            .frame(width: 64, height: 64)
            Text(verdict.title)
                .font(.headline)
                .foregroundStyle(verdict.color)
                .contentTransition(.opacity)
        }
        .frame(minWidth: 84)
        .scaleEffect(shown ? 1 : 0.3)
        .opacity(shown ? 1 : 0)
        .animation(Motion.quick.unless(reduceMotion), value: verdict)
        .onAppear {
            guard !shown else { return }
            if reduceMotion {
                shown = true
            } else {
                withAnimation(Motion.bouncy.delay(0.1 + delay)) { shown = true }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Health: \(verdict.title)")
    }
}
