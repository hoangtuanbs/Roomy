import Foundation
import RoomyCore
#if canImport(FoundationModels)
import FoundationModels
#endif

/// What is known about an item when the built-in list doesn't explain it: only names and sizes, never the
/// contents of files.
struct ItemFacts: Sendable, Equatable {
    /// The path from the home folder, as `~/…`.
    let displayPath: String
    let isFolder: Bool
    let bytes: Int64
    /// A few names inside a folder, largest first.
    let childNames: [String]
}

/// Makes a guess about what an item is. Its answer is always labelled as a guess, and the safety rules are applied
/// to it afterwards, outside the guesser.
protocol ItemGuessing: Sendable {
    /// True when guesses can be made on this Mac now.
    var isAvailable: Bool { get }
    func guess(_ facts: ItemFacts) async throws -> (text: String, safety: RemovalSafety)
}

/// Guesses with Apple's on-device language model (Apple Intelligence, macOS 26 and later). Nothing leaves the Mac.
/// On older systems, or when Apple Intelligence is off or not ready, it is not available.
struct OnDeviceItemGuesser: ItemGuessing {
    var isAvailable: Bool {
        #if canImport(FoundationModels)
        if #available(macOS 26, *) { return SystemLanguageModel.default.isAvailable }
        #endif
        return false
    }

    func guess(_ facts: ItemFacts) async throws -> (text: String, safety: RemovalSafety) {
        #if canImport(FoundationModels)
        if #available(macOS 26, *) {
            let session = LanguageModelSession(instructions: Self.instructions)
            let answer = try await session.respond(to: Self.prompt(facts), generating: ItemGuessAnswer.self).content
            let safety: RemovalSafety
            switch answer.verdict {
            case .safe: safety = .safe
            case .rebuilds: safety = .rebuilds
            case .keep: safety = .keep
            }
            return (answer.explanation.trimmingCharacters(in: .whitespacesAndNewlines), safety)
        }
        #endif
        throw CocoaError(.featureUnsupported)
    }

    static var instructions: String {
        let code = Bundle.main.preferredLocalizations.first ?? "en"
        let language = Locale(identifier: "en").localizedString(forIdentifier: code) ?? "English"
        return """
            You explain files and folders on a Mac to someone who is not technical. From the path, the size and the \
            names inside, say in one or two short sentences what the item most likely is and what removing it would do. \
            Then judge it: safe (nothing is lost), rebuilds (an app or tool makes it again when needed) or keep (it may \
            hold the person's own data or something an app or macOS needs). When you are not sure, choose keep. \
            Answer in \(language).
            """
    }

    static func prompt(_ facts: ItemFacts) -> String {
        var lines = ["Path: \(facts.displayPath)",
                     "Kind: \(facts.isFolder ? "folder" : "file")",
                     "Size: \(ByteFormat.string(facts.bytes))"]
        if !facts.childNames.isEmpty {
            lines.append("Inside: " + facts.childNames.prefix(12).joined(separator: ", "))
        }
        return lines.joined(separator: "\n")
    }
}

#if canImport(FoundationModels)
@available(macOS 26, *)
@Generable
enum ItemGuessVerdict {
    case safe, rebuilds, keep
}

@available(macOS 26, *)
@Generable
struct ItemGuessAnswer {
    @Guide(description: "What the item most likely is and what removing it would do, in one or two short sentences.")
    var explanation: String
    @Guide(description: "safe if nothing is lost, rebuilds if an app makes it again, keep if unsure or it holds data.")
    var verdict: ItemGuessVerdict
}
#endif

/// A stand-in for the flow test: answers "safe" for everything, so the test can check that the safety rules still
/// keep blocked items.
struct CarelessItemGuesser: ItemGuessing {
    var isAvailable: Bool { true }

    func guess(_ facts: ItemFacts) async throws -> (text: String, safety: RemovalSafety) {
        ("A made-up guess for \(facts.displayPath). Remove it freely.", .safe)
    }
}
