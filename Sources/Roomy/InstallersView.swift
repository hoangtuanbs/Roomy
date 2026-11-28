import AppKit
import RoomyCore
import SwiftUI

/// The Installers tab of the Uninstaller: packages installed with Installer whose app is gone, and the files they
/// left where you can change them. Nothing is ticked until you review it.
struct InstallersPanel: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var confirm = false

    var body: some View {
        let receipts = model.receipts
        VStack(spacing: 0) {
            ZStack {
                if receipts.isLoading || !receipts.loaded {
                    VStack(spacing: 10) {
                        ProgressView()
                        Text("Reading installer receipts…").foregroundStyle(.secondary)
                    }
                    .transition(.opacity)
                } else if receipts.findings.isEmpty {
                    ContentUnavailableView("No leftovers of installers", systemImage: "checkmark.seal",
                                           description: Text("Every app installed with an installer is still here, or its installer left nothing behind."))
                        .transition(.opacity)
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Apps installed with an installer package that are no longer on this Mac. Their receipts stay in /var/db/receipts, which only an administrator can change.")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                            ForEach(Array(receipts.findings.enumerated()), id: \.element.id) { index, finding in
                                ReceiptCard(finding: finding)
                                    .entrance(index: min(index, 12), offset: 8)
                            }
                        }
                        .padding(16)
                        .animation(Motion.spring.unless(reduceMotion), value: receipts.findings.map { $0.leftovers.count })
                    }
                    .transition(.opacity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .animation(Motion.smooth.unless(reduceMotion), value: receipts.loaded)

            if receipts.loaded && !receipts.findings.isEmpty {
                Divider()
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 1) {
                        CountingBytes(receipts.tickedBytes)
                            .font(.title3.weight(.bold))
                            .animation(Motion.quick.unless(reduceMotion), value: receipts.tickedBytes)
                        Text("\(receipts.tickedItems.count) ticked")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .contentTransition(.numericText())
                    }
                    Spacer()
                    Button {
                        confirm = true
                    } label: {
                        Label("Move to Trash", systemImage: "trash").padding(.horizontal, 6)
                    }
                    .buttonStyle(.primaryAction(.uninstaller))
                    .disabled(receipts.tickedItems.isEmpty)
                }
                .padding(14)
            }
        }
        .alert("Move \(receipts.tickedItems.count) \(Plural.word(receipts.tickedItems.count, "item", "items")) to the Trash?",
               isPresented: $confirm) {
            Button("Move to Trash", role: .destructive) {
                let items = receipts.tickedItems
                model.uninstaller.removeFiles(items.map(\.path),
                                              sizes: Dictionary(items.map { ($0.path, $0.bytes) }, uniquingKeysWith: { a, _ in a }))
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("\(receipts.tickedBytes.bytes) of files that installers of removed apps left behind. If something still uses them, put them back from the Trash.")
        }
    }
}

private struct ReceiptCard: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let finding: ReceiptFinding

    private static let color = Color(red: 0.62, green: 0.45, blue: 0.85)

    var body: some View {
        let receipts = model.receipts
        let count = finding.leftovers.filter { receipts.ticked.contains($0.path) }.count
        let state: JunkSelection.State = count == 0 ? .none : (count == finding.leftovers.count ? .all : .some)

        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                if !finding.leftovers.isEmpty {
                    SelectionBox(state: state, color: Self.color) {
                        withAnimation(Motion.quick.unless(reduceMotion)) { receipts.setAll(finding, ticked: state != .all) }
                    }
                }
                IconTile(symbol: "shippingbox.fill", gradient: .tile(Self.color), size: 28)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        Text(finding.appName).font(.callout.weight(.medium)).lineLimit(1)
                        Badge(text: "App removed", color: .orange)
                    }
                    Text([finding.package.id, finding.package.version.map { String(format: String(localized: "version %@"), $0) },
                          finding.package.installDate.map { $0.formatted(date: .abbreviated, time: .omitted) }]
                        .compactMap { $0 }.joined(separator: " · "))
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 6)
                CountingBytes(finding.bytes)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            ForEach(finding.leftovers) { item in
                HStack(spacing: 8) {
                    SelectionBox(state: receipts.ticked.contains(item.path) ? .all : .none, color: Self.color) {
                        withAnimation(Motion.quick.unless(reduceMotion)) { receipts.toggle(item.path) }
                    }
                    Text(item.path)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .foregroundStyle(receipts.ticked.contains(item.path) ? Color.primary : Color.secondary)
                    Spacer(minLength: 6)
                    Text(item.bytes.bytes).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    Button {
                        receipts.reveal(item.path)
                    } label: {
                        Image(systemName: "magnifyingglass")
                    }
                    .buttonStyle(.borderless)
                    .help("Show in Finder")
                }
                .font(.callout)
                .padding(.leading, 26)
                .transition(.opacity.combined(with: .move(edge: .trailing)))
            }
            if !finding.adminOnly.isEmpty {
                Label(String(format: String(localized: "%lld more %@ need an administrator. RoomyDisk leaves them alone."),
                             finding.adminOnly.count, Plural.word(finding.adminOnly.count, "item", "items")),
                      systemImage: "lock")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 26)
                    .help(finding.adminOnly.joined(separator: "\n"))
            }
            if finding.leftovers.isEmpty && finding.adminOnly.isEmpty {
                Text("It left nothing else behind.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 26)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Palette.card))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(state == .none ? Color.primary.opacity(0.06) : Self.color.opacity(0.5), lineWidth: 1)
        )
    }
}
