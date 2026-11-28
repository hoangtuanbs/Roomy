import RoomyCore
import SwiftUI

/// What Is This?: what the chosen item is and whether it can go, from RoomyDisk's own list, or as a clearly labelled
/// guess made on this Mac for items the list doesn't know. Only explains; removing still goes through the tray.
struct ExplainView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let explain = model.explain
        ToolSheet {
            ToolSheetHeader(title: "What Is This?", subtitle: Text(verbatim: explain.item.map { explain.display($0.path) } ?? ""),
                            gradient: .explain) {
                Image(systemName: "questionmark.bubble.fill")
            } accessory: {
                if let item = explain.item {
                    ToolSheetTotal(value: Text(item.bytes.bytes), caption: Text(item.name).font(.caption))
                }
            }
        } content: {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if let explanation = explain.explanation {
                        ExplanationCard(explanation: explanation)
                            .entrance()
                            .id(explanation.source == .guess ? "guess" : "list")
                            .transition(.opacity.combined(with: .scale(scale: 0.96)))
                    } else {
                        UnknownItemCard()
                            .entrance()
                            .transition(.opacity)
                    }
                    Label("Explanations come from RoomyDisk's own list, checked against its safety rules. Nothing about your files leaves this Mac.",
                          systemImage: "lock.shield")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .entrance(index: 1)
                }
                .padding(20)
            }
            .animation(Motion.spring.unless(reduceMotion), value: explain.explanation)
        } footer: {
            HStack(spacing: 10) {
                if let item = explain.item {
                    Button("Reveal in Finder") { model.revealPath(item.path) }
                }
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .frame(minWidth: 600, idealWidth: 640, minHeight: 420, idealHeight: 460)
    }
}

/// The verdict as a big coloured badge, the explanation, and where it came from.
private struct ExplanationCard: View {
    @Environment(AppModel.self) private var model
    let explanation: ItemExplanation

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: explanation.safety.symbol)
                    .font(.system(size: 26))
                    .foregroundStyle(explanation.safety.color)
                    .symbolEffect(.bounce, value: explanation.safety)
                VStack(alignment: .leading, spacing: 2) {
                    Text(explanation.safety.label)
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(explanation.safety.color)
                    Text(explanation.title)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if explanation.source == .guess {
                    Label("Guess", systemImage: "sparkles")
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(Color.purple.opacity(0.14)))
                        .foregroundStyle(.purple)
                }
            }
            Text(explanation.text)
                .font(.body)
                .fixedSize(horizontal: false, vertical: true)
            if let inside = explanation.insideOf {
                Label(String(format: String(localized: "This item is inside %@."), model.explain.display(inside)),
                      systemImage: "folder")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            if let reason = explanation.blockedReason {
                Label(String(format: String(localized: "RoomyDisk's safety rules keep it: %@"), reason),
                      systemImage: "lock.fill")
                    .font(.callout)
                    .foregroundStyle(.orange)
            }
            if explanation.source == .guess {
                Text("This is a guess by Apple Intelligence on this Mac, made from the item's name and size. Check before removing anything.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .card(tint: explanation.safety.color, hoverable: false)
    }
}

/// For items the list doesn't know: an offer to guess on this Mac, or a plain "not known".
private struct UnknownItemCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let explain = model.explain
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: "questionmark.circle.fill")
                    .font(.system(size: 26))
                    .foregroundStyle(.secondary)
                Text("Not in RoomyDisk's list")
                    .font(.title3.weight(.semibold))
            }
            Text("RoomyDisk doesn't know this item. If you didn't make it yourself, look at what is inside, or search for its name, before you remove it.")
                .fixedSize(horizontal: false, vertical: true)
            if explain.canGuess {
                HStack(spacing: 10) {
                    Button {
                        explain.guess()
                    } label: {
                        Label("Ask Apple Intelligence", systemImage: "sparkles")
                    }
                    .buttonStyle(.primaryAction(.explain))
                    .disabled(explain.guessState == .thinking)
                    if explain.guessState == .thinking {
                        ProgressView().controlSize(.small)
                        Text("Thinking on this Mac…").foregroundStyle(.secondary)
                    }
                }
                Text("Runs on this Mac only. The answer is a guess; RoomyDisk's safety rules still apply.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if case .failed(let message) = explain.guessState {
                Label(message, systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(.orange)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .card(hoverable: false)
    }
}
