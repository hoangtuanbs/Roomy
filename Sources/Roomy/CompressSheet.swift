import RoomyCore
import SwiftUI

struct CompressSheet: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Group {
            if let result = model.compressResult {
                CompressResultView(result: result)
            } else if let tree = model.tree, let node = model.compressTarget {
                confirm(tree: tree, node: node)
            } else {
                Button("Close") { model.closeCompress() }
            }
        }
        .padding(22)
        .frame(width: 560)
        .interactiveDismissDisabled(model.isCompressing)
    }

    private func confirm(tree: ScanTree, node: ScanTree.Index) -> some View {
        let path = tree.path(of: node)
        let category = model.category(of: node)
        let warnings = model.warnings(for: node)
        let archiveName = (CompressionService.archivePath(for: path) as NSString).lastPathComponent

        return VStack(alignment: .leading, spacing: 14) {
            Text("Compress “\(tree.name(node))” and move the original to the Trash?")
                .font(.title2.weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)

            HStack(alignment: .top, spacing: 10) {
                Image(systemName: category.symbol)
                    .foregroundStyle(category.color)
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 2) {
                    Text(path)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .truncationMode(.middle)
                    Text("\(tree.size(node).bytes) now. The archive “\(archiveName)” is saved in the same folder.")
                        .font(.callout)
                }
            }

            Text("Roomy makes a .zip archive, checks that it reads back correctly, then moves the original to the Trash. If the archive saves less than 10%, Roomy keeps the original and removes the archive. The space is freed when you empty the Trash.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if [.video, .audio, .image, .archive].contains(category) {
                Label("This kind of file is usually already compressed, so it may not get much smaller.", systemImage: "info.circle")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            ForEach(warnings, id: \.self) { warning in
                Label(warning, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.orange)
            }

            HStack {
                if model.isCompressing {
                    ProgressView().controlSize(.small)
                    Text("Compressing… Large folders can take a while.")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if model.isCompressing {
                    Button("Stop") { model.cancelCompress() }
                } else {
                    Button("Cancel", role: .cancel) { model.closeCompress() }
                        .keyboardShortcut(.cancelAction)
                    Button("Compress") { model.performCompress() }
                    // Not the default button, so Return alone never moves anything to the Trash.
                }
            }
        }
    }
}

private struct CompressResultView: View {
    @Environment(AppModel.self) private var model
    let result: CompressionResult

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if result.succeeded {
                Label("Compressed and moved the original to the Trash", systemImage: "checkmark.circle.fill")
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(.green)
                Text("\(result.originalBytes.bytes) became \(result.archiveBytes.bytes). About \(result.savedBytes.bytes) will be freed when you empty the Trash.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Label("The original was kept", systemImage: "exclamationmark.triangle.fill")
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(.orange)
                Text(result.error ?? "Unknown error")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                if let archive = result.archivePath {
                    Button("Show Archive in Finder") { model.revealPath(archive) }
                }
                if result.succeeded {
                    Button("Open Trash") { model.openTrash() }
                }
                Spacer()
                Button("Done") { model.closeCompress() }.keyboardShortcut(.defaultAction)
            }
        }
    }
}
