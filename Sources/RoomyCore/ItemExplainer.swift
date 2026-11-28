import Foundation

/// Whether an item can be removed, in plain words.
public enum RemovalSafety: String, Sendable, Equatable, CaseIterable {
    /// Nothing is lost by removing it.
    case safe
    /// Can be removed; the app or tool that made it makes it again when needed.
    case rebuilds
    /// Keep it: it holds your data or something macOS or an app needs.
    case keep
}

/// What a file or folder is and whether it is safe to remove.
public struct ItemExplanation: Sendable, Equatable {
    public enum Source: Sendable, Equatable {
        /// RoomyDisk's own list.
        case builtIn
        /// A guess made on this Mac, for items the list does not know.
        case guess
    }

    public let title: String
    public let text: String
    public let safety: RemovalSafety
    public let source: Source
    /// The folder the explanation is about, when the item lies inside it rather than being it.
    public let insideOf: String?
    /// Why the safety rules keep this item, when they block it. A blocked item is always `.keep`.
    public let blockedReason: String?

    public init(title: String, text: String, safety: RemovalSafety, source: Source,
                insideOf: String? = nil, blockedReason: String? = nil) {
        self.title = title
        self.text = text
        self.safety = safety
        self.source = source
        self.insideOf = insideOf
        self.blockedReason = blockedReason
    }
}

/// Explains common folders and files from a built-in list: the Library folders, developer caches, app data of
/// well-known apps, system folders and files known by name anywhere. Patterns start with `~/` (the home folder) or
/// `/`; a `*` part matches one name, and `*.ext` matches by extension. `**/name` matches that name anywhere. The
/// most specific pattern wins. The safety rules always have the last word: a blocked path is never removable.
public struct ItemExplainer: Sendable {
    public struct Entry: Sendable {
        public let pattern: String
        public let title: String
        public let text: String
        public let safety: RemovalSafety
    }

    public let policy: SafetyPolicy
    public let entries: [Entry]

    public init(policy: SafetyPolicy = SafetyPolicy(), entries: [Entry] = ItemExplainer.builtIn) {
        self.policy = policy
        self.entries = entries
    }

    /// The explanation for `path`: its own entry, or the nearest enclosing folder's. Nil when nothing in the list
    /// covers it.
    public func explain(_ rawPath: String) -> ItemExplanation? {
        let path = DiskScanner.standardize(rawPath)
        var current = path
        while !current.isEmpty {
            // Nothing above the home folder explains what is in it.
            if current != path && (current == policy.homePath || current == "/Users" || current == "/") { break }
            if let entry = bestEntry(for: current) {
                let inside = current == path ? nil : current
                return enforce(ItemExplanation(title: Self.localized(entry.title), text: Self.localized(entry.text),
                                               safety: entry.safety, source: .builtIn, insideOf: inside), for: path)
            }
            if current == "/" { break }
            let parent = (current as NSString).deletingLastPathComponent
            if parent == current { break }
            current = parent
        }
        return nil
    }

    /// The explanation with the safety rules applied: when they block `path`, it is `.keep` with their reason,
    /// whatever the explanation said. Guesses go through here too.
    public func enforce(_ explanation: ItemExplanation, for path: String) -> ItemExplanation {
        guard case .blocked(let reason) = policy.verdict(for: path) else { return explanation }
        return ItemExplanation(title: explanation.title, text: explanation.text, safety: .keep, source: explanation.source,
                               insideOf: explanation.insideOf, blockedReason: reason)
    }

    /// The path as the built-in list writes it: `~/…` inside the home folder.
    public func display(_ path: String) -> String {
        let path = DiskScanner.standardize(path)
        if path == policy.homePath { return "~" }
        if path.lowercased().hasPrefix(policy.homePath.lowercased() + "/") {
            return "~" + path.dropFirst(policy.homePath.count)
        }
        return path
    }

    // MARK: Matching

    func bestEntry(for path: String) -> Entry? {
        let parts = Self.components(display(path))
        var best: (entry: Entry, score: Int)?
        for entry in entries {
            guard let score = Self.score(entry.pattern, parts) else { continue }
            if best == nil || score > best!.score { best = (entry, score) }
        }
        return best?.entry
    }

    /// How well `pattern` fits the path's parts, or nil when it does not. Longer patterns with fewer wildcards fit
    /// better; a name matched anywhere fits least.
    static func score(_ pattern: String, _ parts: [String]) -> Int? {
        if pattern.hasPrefix("**/") {
            let name = String(pattern.dropFirst(3))
            guard let last = parts.last, matches(name, last) else { return nil }
            return name.hasPrefix("*") ? 1 : 2
        }
        let wanted = components(pattern)
        guard wanted.count == parts.count else { return nil }
        var score = wanted.count * 10
        for (want, part) in zip(wanted, parts) {
            guard matches(want, part) else { return nil }
            if want.contains("*") { score -= 6 }
        }
        return score
    }

    static func matches(_ want: String, _ part: String) -> Bool {
        if want == "*" { return true }
        if want.hasPrefix("*") { return part.lowercased().hasSuffix(want.dropFirst().lowercased()) }
        return want.caseInsensitiveCompare(part) == .orderedSame
    }

    static func components(_ path: String) -> [String] {
        if path == "/" { return ["/"] }
        var parts = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        if path.hasPrefix("/") { parts.insert("/", at: 0) }
        return parts
    }

    static func localized(_ text: String) -> String {
        NSLocalizedString(text, comment: "")
    }
}
