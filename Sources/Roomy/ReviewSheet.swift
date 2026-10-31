import RoomyCore
import SwiftUI

struct ReviewSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Group {
            if let report = model.lastReport, model.basket.isEmpty {
                ResultView(report: report, done: close)
            } else {
                review
            }
        }
        .padding(22)
        .frame(width: 600, height: 500)
    }

    private func close() {
        model.lastReport = nil
        dismiss()
    }

    private var review: some View {
        let items = model.basketItems

        return VStack(alignment: .leading, spacing: 14) {
            Text("Move \(items.count) \(items.count == 1 ? "item" : "items") to the Trash?")
                .font(.title2.weight(.semibold))
            Text("This frees up to \(model.basketBytes.bytes). Nothing is deleted yet: you can restore items from the Trash with Put Back until you empty it.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if let tree = model.tree {
                List(items, id: \.self) { node in
                    let warnings = model.warnings(for: node)
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: model.category(of: node).symbol)
                            .foregroundStyle(model.category(of: node).color)
                            .frame(width: 18)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(tree.name(node)).lineLimit(1)
                            Text(tree.path(of: node))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            ForEach(warnings, id: \.self) { warning in
                                Label(warning, systemImage: "exclamationmark.triangle.fill")
                                    .font(.caption)
                                    .foregroundStyle(.orange)
                            }
                        }
                        Spacer()
                        Text(tree.size(node).bytes).monospacedDigit()
                        Button {
                            model.toggleBasket(node)
                        } label: {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                        }
                        .buttonStyle(.borderless)
                    }
                    .padding(.vertical, 2)
                }
                .listStyle(.bordered)
            }

            Text("The space freed can be less than shown when files are APFS clones, still open in an app, or kept in a local Time Machine snapshot.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(role: .destructive) {
                    model.performCleanup()
                } label: {
                    if model.isCleaning {
                        ProgressView().controlSize(.small)
                    } else {
                        Text("Move to Trash")
                    }
                }
                .disabled(items.isEmpty || model.isCleaning)
                // Not the default button, so Return alone never trashes anything.
            }
        }
    }
}

private struct ResultView: View {
    @Environment(AppModel.self) private var model
    let report: CleanupReport
    let done: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Moved \(report.succeeded.count) \(report.succeeded.count == 1 ? "item" : "items") to the Trash", systemImage: "checkmark.circle.fill")
                .font(.title2.weight(.semibold))
                .foregroundStyle(.green)
            Text("About \(report.freedBytes.bytes) will be freed when you empty the Trash.")
                .foregroundStyle(.secondary)
            if !report.failed.isEmpty {
                Text("\(report.failed.count) could not be moved").font(.headline)
                List(report.failed, id: \.path) { result in
                    VStack(alignment: .leading, spacing: 2) {
                        Text((result.path as NSString).lastPathComponent)
                        Text(result.error ?? "Unknown error").font(.caption).foregroundStyle(.secondary)
                    }
                }
                .listStyle(.bordered)
            } else {
                Spacer()
            }
            HStack {
                Button("Open Trash") { model.openTrash() }
                Spacer()
                Button("Done", action: done).keyboardShortcut(.defaultAction)
            }
        }
    }
}
