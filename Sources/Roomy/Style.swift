import RoomyCore
import SwiftUI

extension FileCategory {
    var color: Color {
        switch self {
        case .folder: return Color(red: 0.29, green: 0.52, blue: 0.86)
        case .video: return Color(red: 0.86, green: 0.36, blue: 0.42)
        case .audio: return Color(red: 0.93, green: 0.58, blue: 0.25)
        case .image: return Color(red: 0.36, green: 0.72, blue: 0.48)
        case .archive: return Color(red: 0.62, green: 0.45, blue: 0.85)
        case .application: return Color(red: 0.25, green: 0.70, blue: 0.80)
        case .developer: return Color(red: 0.85, green: 0.72, blue: 0.25)
        case .document: return Color(red: 0.55, green: 0.62, blue: 0.70)
        case .other: return Color(red: 0.60, green: 0.60, blue: 0.62)
        }
    }

    var symbol: String {
        switch self {
        case .folder: return "folder.fill"
        case .video: return "film"
        case .audio: return "music.note"
        case .image: return "photo"
        case .archive: return "archivebox"
        case .application: return "app.dashed"
        case .developer: return "hammer"
        case .document: return "doc.text"
        case .other: return "doc"
        }
    }
}

extension Int64 {
    var bytes: String { ByteFormat.string(self) }
}

struct SizeBar: View {
    let fraction: Double
    let color: Color

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule().fill(color)
                    .frame(width: max(2, geo.size.width * min(1, max(0, fraction))))
            }
        }
        .frame(height: 5)
        .motion(Motion.spring, value: fraction)
    }
}

extension JunkCategory {
    var color: Color {
        switch self {
        case .caches: return Color(red: 0.29, green: 0.52, blue: 0.86)
        case .logs: return Color(red: 0.55, green: 0.62, blue: 0.70)
        case .developer: return Color(red: 0.85, green: 0.62, blue: 0.20)
        case .packages: return Color(red: 0.36, green: 0.72, blue: 0.48)
        case .installers: return Color(red: 0.62, green: 0.45, blue: 0.85)
        case .trash: return Color(red: 0.86, green: 0.36, blue: 0.42)
        }
    }

    var symbol: String {
        switch self {
        case .caches: return "bolt.horizontal.circle"
        case .logs: return "text.alignleft"
        case .developer: return "hammer"
        case .packages: return "shippingbox"
        case .installers: return "opticaldiscdrive"
        case .trash: return "trash"
        }
    }
}

extension DiskPart {
    var color: Color {
        switch self {
        case .scanned: return FileCategory.folder.color
        case .hidden: return FileCategory.audio.color
        case .purgeable: return FileCategory.archive.color
        case .free: return Color.secondary.opacity(0.25)
        }
    }
}

/// The blue-to-purple gradient used for Smart Clean.
extension LinearGradient {
    static let smartClean = LinearGradient(
        colors: [Color(red: 0.29, green: 0.52, blue: 0.86), Color(red: 0.62, green: 0.45, blue: 0.85)],
        startPoint: .topLeading, endPoint: .bottomTrailing
    )
}

/// The teal-to-blue gradient used for Duplicates.
extension LinearGradient {
    static let duplicates = LinearGradient(
        colors: [Color(red: 0.20, green: 0.70, blue: 0.70), Color(red: 0.29, green: 0.52, blue: 0.86)],
        startPoint: .topLeading, endPoint: .bottomTrailing
    )
}

/// The pink-to-orange gradient used for the Uninstaller.
extension LinearGradient {
    static let uninstaller = LinearGradient(
        colors: [Color(red: 0.91, green: 0.36, blue: 0.48), Color(red: 0.95, green: 0.58, blue: 0.27)],
        startPoint: .topLeading, endPoint: .bottomTrailing
    )
}

/// A byte count that counts up or down to its new value when it changes inside an animation.
struct CountingBytes: View, Animatable {
    var value: Double
    var suffix: String

    init(_ bytes: Int64, suffix: String = "") {
        value = Double(bytes)
        self.suffix = suffix
    }

    var animatableData: Double {
        get { value }
        set { value = newValue }
    }

    var body: some View {
        Text(Int64(max(0, value).rounded()).bytes + suffix).monospacedDigit()
    }
}

/// The scan's blue-to-teal gradient, used for the scanning ring.
extension LinearGradient {
    static let scan = LinearGradient(
        colors: [Color(red: 0.29, green: 0.52, blue: 0.86), Color(red: 0.25, green: 0.70, blue: 0.80)],
        startPoint: .topLeading, endPoint: .bottomTrailing
    )
}

// MARK: Motion

/// The few animations the app uses, so every screen moves the same way. They are all short. Use them through
/// `.unless(reduceMotion)`, `.motion(_:value:)` or `.entrance(index:)` so Reduce Motion turns them off.
enum Motion {
    /// Rows, cards and panels moving into place.
    static let spring = Animation.spring(response: 0.4, dampingFraction: 0.85)
    /// A livelier spring for things that pop in, such as a result or a chip landing in the tray.
    static let bouncy = Animation.spring(response: 0.45, dampingFraction: 0.66)
    /// Small state changes: toggles, ticks and counters.
    static let quick = Animation.snappy(duration: 0.25)
    /// Cross-fades between the steps of a screen, and progress.
    static let smooth = Animation.smooth(duration: 0.35)
    /// Hover highlights.
    static let hover = Animation.easeOut(duration: 0.15)

    /// The spring for the `index`th item of a list appearing. Only the first few items wait, so a long list
    /// settles at once.
    static func stagger(_ index: Int, limit: Int = 10) -> Animation {
        spring.delay(Double(min(max(0, index), limit)) * 0.04)
    }

    /// Lists longer than this update without animating their rows, so big folders stay fast.
    static let listLimit = 300

    /// `animation` for a list of `count` rows, or nil when the list is too long or Reduce Motion is on.
    static func list(_ count: Int, _ reduceMotion: Bool, _ animation: Animation = spring) -> Animation? {
        count <= listLimit ? animation.unless(reduceMotion) : nil
    }
}

extension Animation {
    /// This animation, or none when Reduce Motion is on.
    func unless(_ reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : self
    }
}

private struct MotionModifier<Value: Equatable>: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let animation: Animation
    let value: Value

    func body(content: Content) -> some View {
        content.animation(animation.unless(reduceMotion), value: value)
    }
}

/// Fades, lifts and slightly grows a view in the first time it appears.
private struct EntranceModifier: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let index: Int
    let offset: CGFloat
    let scale: CGFloat
    @State private var appeared = false

    func body(content: Content) -> some View {
        content
            .opacity(appeared ? 1 : 0)
            .offset(y: appeared ? 0 : offset)
            .scaleEffect(appeared ? 1 : scale)
            .onAppear {
                guard !appeared else { return }
                if reduceMotion {
                    appeared = true
                } else {
                    withAnimation(Motion.stagger(index)) { appeared = true }
                }
            }
    }
}

extension View {
    /// `.animation(_:value:)` that stays still when Reduce Motion is on.
    func motion<Value: Equatable>(_ animation: Animation, value: Value) -> some View {
        modifier(MotionModifier(animation: animation, value: value))
    }

    /// Brings the view in with a short rise and fade the first time it appears. `index` staggers the items of a
    /// list a little; with Reduce Motion the view just appears.
    func entrance(index: Int = 0, offset: CGFloat = 16, scale: CGFloat = 0.97) -> some View {
        modifier(EntranceModifier(index: index, offset: offset, scale: scale))
    }
}

/// A ring with an arc that turns while work is going on, a soft pulse behind it and a symbol in the middle.
/// With Reduce Motion the ring stands still.
struct BusyRing<Center: View>: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let gradient: LinearGradient
    var size: CGFloat = 92
    var lineWidth: CGFloat = 6
    /// Seconds for one turn.
    var period: Double = 1.1
    @ViewBuilder var center: () -> Center

    var body: some View {
        TimelineView(.animation(minimumInterval: nil, paused: reduceMotion)) { context in
            let time = context.date.timeIntervalSinceReferenceDate
            let turn = reduceMotion ? 0 : time.truncatingRemainder(dividingBy: period) / period
            let pulse = reduceMotion ? 0 : (sin(time * 2 * .pi / (period * 2)) + 1) / 2
            ZStack {
                Circle()
                    .fill(gradient)
                    .opacity(0.08 + 0.08 * pulse)
                    .scaleEffect(1 + 0.06 * pulse)
                Circle().stroke(Color.primary.opacity(0.08), lineWidth: lineWidth)
                Circle()
                    .trim(from: 0, to: 0.28)
                    .stroke(gradient, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                    .rotationEffect(.degrees(turn * 360))
                center()
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}
