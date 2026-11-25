import AppKit
import RoomyCore
import UniformTypeIdentifiers

/// Saves a folder of the scan as a CSV file, with the path chosen in a save panel.
@MainActor
enum CSVExporter {
    static func save(tree: ScanTree, folder: ScanTree.Index, depth: Int) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = fileName(for: tree, folder: folder)
        guard panel.runModal() == .OK, let url = panel.url else { return }

        Task {
            do {
                try await write(tree: tree, folder: folder, depth: depth, to: url)
            } catch {
                NSAlert(error: error).runModal()
            }
        }
    }

    /// Writes the CSV to `url`, off the main thread. The save panel's choice ends here; so does the flow test.
    static func write(tree: ScanTree, folder: ScanTree.Index, depth: Int, to url: URL) async throws {
        let csv = await Task.detached(priority: .userInitiated) {
            TreeCSV.export(tree: tree, folder: folder, depth: depth)
        }.value
        try csv.write(to: url, atomically: true, encoding: .utf8)
    }

    private static func fileName(for tree: ScanTree, folder: ScanTree.Index) -> String {
        let base = (tree.name(folder) as NSString).lastPathComponent
        return (base.isEmpty || base == "/" ? "RoomyDisk" : base) + ".csv"
    }
}
