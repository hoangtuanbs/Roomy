import Foundation
import RoomyCore

/// Picks the singular or plural English word for a count, translated, so a sentence such as "3 items selected" can be
/// translated as a whole: `Text("\(count) \(Plural.word(count, "item", "items")) selected")`.
enum Plural {
    static func word(_ count: Int, _ one: String, _ many: String) -> String {
        NSLocalizedString(count == 1 ? one : many, comment: "")
    }
}

extension Plural {
    /// The result line after items went to the Trash. One sentence, so each language can reorder it.
    static func movedToTrash(_ count: Int) -> String {
        String(format: NSLocalizedString("Moved %lld %@ to the Trash. Empty the Trash to get the space back for good, or use Put Back in Finder to restore anything.", comment: ""),
               count, word(count, "item", "items"))
    }
}

/// Short notes about how an item's space is counted, for the lists, the caption and the tray.
enum SpaceNotes {
    /// "Shares 1.2 GB with 2 clones", or with other files when the clones are outside the scan.
    static func clone(_ node: ScanTree.Index, in tree: ScanTree) -> String {
        let shared = (tree.clones[node]?.sharedBytes ?? 0).bytes
        let others = tree.cloneSiblingCount(node)
        if others == 0 {
            return String(format: NSLocalizedString("Shares %@ with other files", comment: ""), shared)
        }
        return String(format: NSLocalizedString("Shares %@ with %lld %@", comment: ""), shared, others,
                      Plural.word(others, "clone", "clones"))
    }

    /// For the icon's help: "Stored only in the cloud (1.2 GB). It takes no space on this Mac."
    static func cloudOnly(_ node: ScanTree.Index, in tree: ScanTree) -> String {
        if let online = tree.onlineSizes[node] {
            return String(format: NSLocalizedString("Stored only in the cloud (%@). It takes no space on this Mac.", comment: ""), online.bytes)
        }
        return String(localized: "Stored only in the cloud. It takes no space on this Mac.")
    }

    /// For the caption: "1.2 GB in the cloud".
    static func cloudCaption(_ node: ScanTree.Index, in tree: ScanTree) -> String {
        guard let online = tree.onlineSizes[node] else { return String(localized: "In the cloud only") }
        return String(format: NSLocalizedString("%@ in the cloud", comment: ""), online.bytes)
    }
}
