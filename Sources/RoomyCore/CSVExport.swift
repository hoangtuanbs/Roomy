import Foundation

/// CSV text with RFC 4180 quoting.
public enum CSV {
    /// One field, quoted when it holds a comma, a double quote or a line break.
    public static func field(_ text: String) -> String {
        let needsQuotes = text.contains { $0 == "," || $0 == "\"" || $0 == "\n" || $0 == "\r" || $0 == "\r\n" }
        guard needsQuotes else { return text }
        return "\"" + text.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    /// Joins fields into one line, without a line break.
    public static func line(_ fields: [String]) -> String {
        fields.map(field).joined(separator: ",")
    }
}

/// Lists a folder of a scan as CSV: one row per item.
public enum TreeCSV {
    public static let header = ["path", "name", "kind", "category", "size_bytes", "size_human", "modified", "items"]

    /// The rows of `folder` and, when `depth` is above 1, of the folders inside it down to `depth` levels.
    /// `depth` 1 lists the children only. Removed items are left out.
    public static func export(tree: ScanTree, folder: ScanTree.Index, depth: Int = 1) -> String {
        let dates = ISO8601DateFormatter()
        var lines = [CSV.line(header)]

        func visit(_ parent: ScanTree.Index, level: Int) {
            for node in tree.children(parent) where !tree.flags(node).contains(.removed) {
                let kind = tree.kind(node)
                let name = tree.name(node)
                let size = tree.size(node)
                let items = kind.isContainer ? String(tree.fileCount(node)) : ""
                lines.append(CSV.line([
                    tree.path(of: node),
                    name,
                    kindName(kind),
                    FileCategory.classify(name: name, kind: kind).rawValue,
                    String(size),
                    ByteFormat.string(size),
                    dates.string(from: tree.modifiedDate(node)),
                    items,
                ]))
                if kind == .directory, level < depth { visit(node, level: level + 1) }
            }
        }

        visit(folder, level: 1)
        return lines.joined(separator: "\n") + "\n"
    }

    static func kindName(_ kind: NodeKind) -> String {
        switch kind {
        case .file: return "file"
        case .directory: return "folder"
        case .package: return "package"
        case .symlink: return "symlink"
        case .other: return "other"
        }
    }
}
