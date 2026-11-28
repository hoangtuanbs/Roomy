import Foundation

/// The plain text the Shortcuts actions return, worked out here so it can be tested.
public enum ShortcutText {
    /// "Projects: 1.2 GB" and then one line for each of the biggest items, "800 MB  app".
    public static func scan(_ tree: ScanTree, top: Int) -> String {
        let name = (tree.rootPath as NSString).lastPathComponent
        var lines = ["\(name.isEmpty ? tree.rootPath : name): \(ByteFormat.string(tree.size(ScanTree.root)))"]
        for child in tree.children(ScanTree.root).prefix(max(0, top)) {
            lines.append("\(ByteFormat.string(tree.size(child)))  \(tree.name(child))")
        }
        return lines.joined(separator: "\n")
    }

    /// "120 GB free of 500 GB".
    public static func freeSpace(_ space: DiskSpace) -> String {
        String(format: NSLocalizedString("%@ free of %@", comment: ""), ByteFormat.string(space.free),
               ByteFormat.string(space.total))
    }

    /// The total of the junk a clean would move, and how many items.
    public static func junk(_ items: [JunkItem]) -> String {
        let bytes = items.reduce(0) { $0 + $1.bytes }
        guard !items.isEmpty else { return NSLocalizedString("No junk found.", comment: "") }
        return String(format: NSLocalizedString("%@ of junk can be moved to the Trash. Items: %lld.", comment: ""),
                      ByteFormat.string(bytes), items.count)
    }

    /// What a clean did.
    public static func cleaned(_ report: CleanupReport) -> String {
        var text = String(format: NSLocalizedString("Moved to the Trash: %lld. Freed: %@.", comment: ""),
                          report.succeeded.count, ByteFormat.string(report.freedBytes))
        if !report.failed.isEmpty {
            text += " " + String(format: NSLocalizedString("%lld could not be moved", comment: ""), report.failed.count) + "."
        }
        return text
    }
}
