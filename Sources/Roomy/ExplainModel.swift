import AppKit
import Observation
import RoomyCore
import SwiftUI

/// State for "What Is This?": the item, the built-in explanation, and a guess for items the list doesn't know.
@MainActor
@Observable
final class ExplainModel {
    enum GuessState: Equatable {
        case idle, thinking
        case failed(String)
    }

    struct Item: Equatable {
        let path: String
        let name: String
        let bytes: Int64
        let isFolder: Bool
        let childNames: [String]
    }

    private(set) var item: Item?
    private(set) var explanation: ItemExplanation?
    private(set) var guessState: GuessState = .idle
    @ObservationIgnored var guesser: any ItemGuessing = AppEnvironment.isFlowTest ? CarelessItemGuesser() : OnDeviceItemGuesser()
    @ObservationIgnored private let explainer = ItemExplainer(policy: AppEnvironment.policy)
    @ObservationIgnored private var guessTask: Task<Void, Never>?

    /// True when the item is not in the list and a guess can be asked for.
    var canGuess: Bool { item != nil && explanation == nil && guesser.isAvailable }

    func show(_ item: Item) {
        guessTask?.cancel()
        self.item = item
        explanation = explainer.explain(item.path)
        guessState = .idle
    }

    /// Asks the on-device model. Its answer is marked as a guess, and the safety rules are applied to it here, so
    /// it can never make a blocked item removable.
    func guess() {
        guard let item, canGuess, guessState != .thinking else { return }
        guessState = .thinking
        let facts = ItemFacts(displayPath: explainer.display(item.path), isFolder: item.isFolder, bytes: item.bytes,
                              childNames: item.childNames)
        let guesser = self.guesser
        guessTask = Task {
            do {
                let answer = try await guesser.guess(facts)
                guard !Task.isCancelled, self.item == item else { return }
                let guess = ItemExplanation(title: item.name, text: answer.text, safety: answer.safety, source: .guess)
                let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
                withAnimation(Motion.spring.unless(reduceMotion)) {
                    explanation = explainer.enforce(guess, for: item.path)
                    guessState = .idle
                }
            } catch {
                guard !Task.isCancelled else { return }
                guessState = .failed(error.localizedDescription)
            }
        }
    }

    /// The path as the explanation shows it.
    func display(_ path: String) -> String { explainer.display(path) }
}

extension RemovalSafety {
    var label: String {
        switch self {
        case .safe: return String(localized: "Safe to remove")
        case .rebuilds: return String(localized: "Removable, app will rebuild it")
        case .keep: return String(localized: "Keep")
        }
    }

    var symbol: String {
        switch self {
        case .safe: return "checkmark.circle.fill"
        case .rebuilds: return "arrow.triangle.2.circlepath.circle.fill"
        case .keep: return "hand.raised.circle.fill"
        }
    }

    var color: Color {
        switch self {
        case .safe: return Color(red: 0.20, green: 0.66, blue: 0.42)
        case .rebuilds: return Color(red: 0.25, green: 0.52, blue: 0.90)
        case .keep: return Color(red: 0.93, green: 0.55, blue: 0.18)
        }
    }
}

/// The violet-to-blue gradient used for What Is This?
extension LinearGradient {
    static let explain = LinearGradient(
        colors: [Color(red: 0.58, green: 0.42, blue: 0.92), Color(red: 0.30, green: 0.55, blue: 0.92)],
        startPoint: .topLeading, endPoint: .bottomTrailing
    )
}
