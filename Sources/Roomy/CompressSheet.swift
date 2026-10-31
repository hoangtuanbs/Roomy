import RoomyCore
import SwiftUI

struct CompressSheet: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Group {
            if let results = model.compressResults {
                CompressResultView(results: results)
            } else if let tree = model.tree {
                confirm(tree: tree)
            } else {
                Button("Close") { model.closeCompress() }
            }
        }
        .padding(22)
        .frame(width: 620, height: 540)
        .interactiveDismissDisabled(model.isCompressing)
    }

    private func confirm(tree: ScanTree) -> some View {
        let targets = model.compressTargets
        // While compressing, canCompress is false for everything, so use the queue fixed at the start.
        let compressible = model.isCompressing ? model.compressQueue : targets.filter { model.canCompress($0) }
        let count = compressible.count
        let noun = count == 1 ? "item" : "items"

        return VStack(alignment: .leading, spacing: 14) {
            Text(count == 1 && targets.count == 1
                 ? "Compress “\(tree.name(targets[0]))” and move the original to the Trash?"
                 : "Compress \(count) \(noun) and move the originals to the Trash?")
                .font(.title2.weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)

            Text("Roomy makes a .zip next to each item and checks that it reads back correctly. Only then is the original moved to the Trash. If a zip saves less than 10%, Roomy keeps that original and removes the zip. The space is freed when you empty the Trash.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            List(targets, id: \.self) { node in
                CompressTargetRow(tree: tree, node: node, skipped: !compressible.contains(node))
            }
            .listStyle(.bordered)

            HStack {
                if let status = model.compressStatus {
                    ProgressView().controlSize(.small)
                    Text(status).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
                Spacer()
                if model.isCompressing {
                    Button("Stop") { model.cancelCompress() }
                        .help("Stop the current item and skip the rest")
                } else {
                    Button("Cancel", role: .cancel) { model.closeCompress() }
                        .keyboardShortcut(.cancelAction)
                    Button("Compress") { model.performCompress() }
                        .disabled(count == 0)
                    // Not the default button, so Return alone never moves anything to the Trash.
                }
            }
        }
    }
}

private struct CompressTargetRow: View {
    @Environment(AppModel.self) private var model
    let tree: ScanTree
    let node: ScanTree.Index
    let skipped: Bool

    var body: some View {
        let category = model.category(of: node)
        let path = tree.path(of: node)

        HStack(alignment: .top, spacing: 10) {
            Image(systemName: category.symbol)
                .foregroundStyle(category.color)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(tree.name(node)).lineLimit(1)
                Text(path)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if skipped {
                    Label(model.verdict(for: node).message ?? "This item cannot be compressed. It will be skipped.", systemImage: "minus.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Saved as “\((CompressionService.archivePath(for: path) as NSString).lastPathComponent)” in the same folder.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                    if [.video, .audio, .image, .archive].contains(category) {
                        Label("Usually already compressed, so it may not get much smaller.", systemImage: "info.circle")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    ForEach(model.warnings(for: node), id: \.self) { warning in
                        Label(warning, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }
            }
            Spacer()
            Text(tree.size(node).bytes).monospacedDigit()
            Button {
                model.dropCompressTarget(node)
            } label: {
                Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
            }
            .buttonStyle(.borderless)
            .disabled(model.isCompressing)
            .help("Leave this item out")
        }
        .padding(.vertical, 2)
    }
}

private struct CompressResultView: View {
    @Environment(AppModel.self) private var model
    let results: [CompressionResult]

    var body: some View {
        let succeeded = results.filter(\.succeeded)
        let saved = succeeded.reduce(Int64(0)) { $0 + $1.savedBytes }
        let skipped = max(0, model.compressTargets.count - results.count)

        VStack(alignment: .leading, spacing: 14) {
            Label(succeeded.isEmpty ? "Nothing was compressed"
                  : "Compressed \(succeeded.count) \(succeeded.count == 1 ? "item" : "items") and moved the originals to the Trash",
                  systemImage: succeeded.isEmpty ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .font(.title2.weight(.semibold))
                .foregroundStyle(succeeded.isEmpty ? Color.orange : Color.green)
                .fixedSize(horizontal: false, vertical: true)
            if !succeeded.isEmpty {
                Text("About \(saved.bytes) in total will be freed when you empty the Trash.")
                    .foregroundStyle(.secondary)
            }
            if skipped > 0 {
                Text("\(skipped) \(skipped == 1 ? "item was" : "items were") skipped and left as they were.")
                    .foregroundStyle(.secondary)
            }

            List(results, id: \.sourcePath) { result in
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: result.succeeded ? "checkmark.circle" : "minus.circle")
                        .foregroundStyle(result.succeeded ? Color.green : Color.secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text((result.sourcePath as NSString).lastPathComponent).lineLimit(1)
                        if result.succeeded {
                            Text("\(result.originalBytes.bytes) became \(result.archiveBytes.bytes)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else {
                            Text(result.error ?? "Unknown error")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    Spacer()
                    if result.succeeded {
                        Text("−\(result.savedBytes.bytes)").monospacedDigit().foregroundStyle(.green)
                    }
                    if let archive = result.archivePath {
                        Button {
                            model.revealPath(archive)
                        } label: {
                            Image(systemName: "magnifyingglass")
                        }
                        .buttonStyle(.borderless)
                        .help("Show the zip in Finder")
                    }
                }
                .padding(.vertical, 2)
            }
            .listStyle(.bordered)

            HStack {
                if !succeeded.isEmpty {
                    Button("Open Trash") { model.openTrash() }
                }
                Spacer()
                Button("Done") { model.closeCompress() }.keyboardShortcut(.defaultAction)
            }
        }
    }
}
