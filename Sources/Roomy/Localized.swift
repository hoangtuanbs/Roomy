import Foundation

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
