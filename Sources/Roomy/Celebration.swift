import RoomyCore
import SwiftUI

/// The ring shown while items move to the Trash: it fills as they go, with the bytes moved so far in the middle.
struct CleaningProgressRing: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let fraction: Double
    let bytes: Int64
    let done: Int
    let total: Int
    let gradient: LinearGradient
    var size: CGFloat = 190

    var body: some View {
        let lineWidth: CGFloat = size >= 180 ? 12 : 10
        VStack(spacing: 20) {
            ZStack {
                Circle().stroke(Color.primary.opacity(0.08), lineWidth: lineWidth)
                Circle()
                    .trim(from: 0, to: max(0.02, fraction))
                    .stroke(gradient, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(Motion.smooth.unless(reduceMotion), value: fraction)
                VStack(spacing: 2) {
                    Text(bytes.bytes)
                        .font(.system(size: size >= 180 ? 28 : 24, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .contentTransition(.numericText(value: Double(bytes)))
                        .animation(Motion.quick.unless(reduceMotion), value: bytes)
                    Text("moved to the Trash").font(.caption).foregroundStyle(.secondary)
                }
            }
            .frame(width: size, height: size)
            Text("Moving \(min(done + 1, total)) of \(total)…")
                .font(.title3)
                .monospacedDigit()
                .contentTransition(.numericText())
                .animation(Motion.quick.unless(reduceMotion), value: done)
        }
    }
}

/// The "space freed" moment after a clean: a check mark that pops in, the freed bytes counting up, a burst of
/// confetti, a short summary, and what could not be moved. `extra` goes between the summary and the failures.
struct FreedSpaceCelebration<Extra: View>: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let bytes: Int64
    let message: String
    var failed: [CleanupResult] = []
    var succeeded = true
    var confetti = true
    var compact = false
    var maxWidth: CGFloat = 460
    /// Said after the big number, such as " freed".
    var suffix = " freed"
    @ViewBuilder var extra: () -> Extra
    @State private var shown = false

    var body: some View {
        ZStack {
            if shown && confetti && !reduceMotion {
                ConfettiBurst()
            }
            VStack(spacing: compact ? 10 : 14) {
                Image(systemName: succeeded ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                    .font(.system(size: compact ? 46 : 68))
                    .foregroundStyle(succeeded ? Color.green.gradient : Color.orange.gradient)
                    .scaleEffect(shown ? 1 : 0.3)
                    .opacity(shown ? 1 : 0)
                    .symbolEffect(.bounce, value: shown)
                CountingBytes(shown ? bytes : 0, suffix: suffix)
                    .font(.system(size: compact ? 32 : 44, weight: .bold, design: .rounded))
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                Text(message)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: maxWidth)
                    .opacity(shown ? 1 : 0)
                    .offset(y: shown ? 0 : 8)
                extra()
                if !failed.isEmpty {
                    FailedItemsList(failed: failed)
                        .frame(maxWidth: maxWidth)
                        .opacity(shown ? 1 : 0)
                }
            }
            .padding(compact ? 8 : 32)
        }
        .onAppear {
            guard !shown else { return }
            if reduceMotion {
                shown = true
            } else {
                withAnimation(Motion.bouncy) { shown = true }
            }
        }
    }
}

extension FreedSpaceCelebration where Extra == EmptyView {
    init(bytes: Int64, message: String, failed: [CleanupResult] = [], succeeded: Bool = true,
         confetti: Bool = true, compact: Bool = false, maxWidth: CGFloat = 460) {
        self.init(bytes: bytes, message: message, failed: failed, succeeded: succeeded, confetti: confetti,
                  compact: compact, maxWidth: maxWidth, extra: { EmptyView() })
    }
}

/// The items a clean could not move, folded away under a short title.
struct FailedItemsList: View {
    let failed: [CleanupResult]

    var body: some View {
        DisclosureGroup("\(failed.count) could not be moved") {
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(failed, id: \.path) { result in
                        VStack(alignment: .leading, spacing: 1) {
                            Text((result.path as NSString).lastPathComponent)
                            Text(result.error ?? "Unknown error").font(.caption).foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(.top, 4)
            }
            .frame(maxHeight: 160)
        }
        .foregroundStyle(.orange)
    }
}

/// A short burst of colourful pieces behind the result.
struct ConfettiBurst: View {
    struct Piece: Identifiable {
        let id: Int
        let angle: CGFloat
        let distance: CGFloat
        let size: CGFloat
        let spin: Double
        let color: Color
    }

    @State private var pieces: [Piece] = ConfettiBurst.makePieces()
    @State private var flown = false
    @State private var faded = false

    var body: some View {
        ZStack {
            ForEach(pieces) { piece in
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(piece.color)
                    .frame(width: piece.size, height: piece.size * 0.55)
                    .rotationEffect(.degrees(flown ? piece.spin : 0))
                    .offset(x: flown ? cos(piece.angle) * piece.distance : 0,
                            y: flown ? sin(piece.angle) * piece.distance + 60 : -40)
                    .opacity(faded ? 0 : 1)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .onAppear {
            withAnimation(.easeOut(duration: 0.9)) { flown = true }
            withAnimation(.easeIn(duration: 0.5).delay(0.7)) { faded = true }
        }
    }

    static func makePieces() -> [Piece] {
        let colors = JunkCategory.allCases.map(\.color) + [.yellow, .pink]
        return (0..<40).map { i in
            Piece(
                id: i,
                angle: CGFloat.random(in: 0..<(2 * .pi)),
                distance: CGFloat.random(in: 120...300),
                size: CGFloat.random(in: 6...11),
                spin: Double.random(in: -360...360),
                color: colors[i % colors.count]
            )
        }
    }
}
