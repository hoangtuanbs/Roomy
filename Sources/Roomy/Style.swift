import AppKit
import RoomyCore
import SwiftUI

extension FileCategory {
    /// The category colours, defined once: softer, more modern hues that keep each category's meaning.
    var color: Color {
        switch self {
        case .folder: return Color(red: 0.36, green: 0.52, blue: 0.96)
        case .video: return Color(red: 0.94, green: 0.42, blue: 0.56)
        case .audio: return Color(red: 0.97, green: 0.62, blue: 0.30)
        case .image: return Color(red: 0.26, green: 0.75, blue: 0.56)
        case .archive: return Color(red: 0.62, green: 0.49, blue: 0.95)
        case .application: return Color(red: 0.22, green: 0.70, blue: 0.85)
        case .developer: return Color(red: 0.91, green: 0.72, blue: 0.22)
        case .document: return Color(red: 0.50, green: 0.58, blue: 0.70)
        case .other: return Color(red: 0.60, green: 0.62, blue: 0.67)
        }
    }

    /// The top and bottom of a treemap tile or a ring segment of this category: a little lighter at the top.
    var gradientStops: (top: Color, bottom: Color) {
        Self.stops[self] ?? (color, color)
    }

    private static let stops: [FileCategory: (top: Color, bottom: Color)] = Dictionary(
        uniqueKeysWithValues: FileCategory.allCases.map { ($0, ($0.color.mixed(with: .white, by: 0.18), $0.color.mixed(with: .black, by: 0.05))) }
    )

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

/// A slim rounded bar with a gradient fill, for sizes and disk use.
struct SizeBar: View {
    let fraction: Double
    let color: Color
    var height: CGFloat = 5

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.08))
                Capsule()
                    .fill(LinearGradient(colors: [color.mixed(with: .white, by: 0.25), color],
                                         startPoint: .leading, endPoint: .trailing))
                    .frame(width: max(height, geo.size.width * min(1, max(0, fraction))))
            }
        }
        .frame(height: height)
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
        case .free: return Color.primary.opacity(0.10)
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

/// The periwinkle-to-aqua gradient used for Cloud Backup, a sibling of Cloud Space's sky-to-indigo.
extension LinearGradient {
    static let cloudBackup = LinearGradient(
        colors: [Color(red: 0.47, green: 0.50, blue: 0.97), Color(red: 0.27, green: 0.77, blue: 0.86)],
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

// MARK: Colours, type and spacing

extension Color {
    /// This colour blended toward `other` by `amount` (0...1), worked out in sRGB.
    func mixed(with other: Color, by amount: Double) -> Color {
        guard let a = NSColor(self).usingColorSpace(.sRGB), let b = NSColor(other).usingColorSpace(.sRGB) else { return self }
        let t = CGFloat(min(1, max(0, amount)))
        return Color(.sRGB,
                     red: Double(a.redComponent + (b.redComponent - a.redComponent) * t),
                     green: Double(a.greenComponent + (b.greenComponent - a.greenComponent) * t),
                     blue: Double(a.blueComponent + (b.blueComponent - a.blueComponent) * t),
                     opacity: Double(a.alphaComponent))
    }

    /// A colour with one value in Light mode and another in Dark mode.
    static func adaptive(light: NSColor, dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
        })
    }
}

/// The app's surfaces. They are solid, so screenshots taken with `cacheDisplay` show them as they look on screen.
enum Palette {
    /// The sidebar column.
    static let sidebar = Color.adaptive(light: NSColor(srgbRed: 0.945, green: 0.945, blue: 0.957, alpha: 1),
                                        dark: NSColor(srgbRed: 0.155, green: 0.155, blue: 0.170, alpha: 1))
    /// The main content behind lists and the map.
    static let content = Color.adaptive(light: NSColor(srgbRed: 0.995, green: 0.995, blue: 1.0, alpha: 1),
                                        dark: NSColor(srgbRed: 0.118, green: 0.118, blue: 0.128, alpha: 1))
    /// The well behind the treemap and the rings, and the scrolling area of a tool sheet.
    static let well = Color.adaptive(light: NSColor(srgbRed: 0.958, green: 0.960, blue: 0.970, alpha: 1),
                                     dark: NSColor(srgbRed: 0.090, green: 0.090, blue: 0.100, alpha: 1))
    /// Cards that sit on a well.
    static let card = Color.adaptive(light: NSColor.white,
                                     dark: NSColor(srgbRed: 0.170, green: 0.170, blue: 0.185, alpha: 1))
    /// The bottom bar and the footers of the sheets.
    static let bar = Color.adaptive(light: NSColor(srgbRed: 0.975, green: 0.975, blue: 0.982, alpha: 1),
                                    dark: NSColor(srgbRed: 0.140, green: 0.140, blue: 0.152, alpha: 1))
    /// Hairlines between areas.
    static let hairline = Color.primary.opacity(0.09)
    /// Card borders.
    static let border = Color.primary.opacity(0.08)
}

/// The spacing scale: 4, 8, 12, 16, 20 and 28 points.
enum Space {
    static let xs: CGFloat = 4
    static let s: CGFloat = 8
    static let m: CGFloat = 12
    static let l: CGFloat = 16
    static let xl: CGFloat = 20
    static let xxl: CGFloat = 28
}

/// Corner radii.
enum Radius {
    static let tile: CGFloat = 6
    static let control: CGFloat = 8
    static let card: CGFloat = 12
    static let panel: CGFloat = 14
}

/// The few text styles the redesign adds; everything else uses the system styles.
enum Typo {
    static let heroTitle = Font.system(size: 24, weight: .semibold, design: .rounded)
    static let heroNumber = Font.system(size: 24, weight: .bold, design: .rounded)
    static let sheetTitle = Font.system(size: 20, weight: .semibold, design: .rounded)
    static let sectionLabel = Font.system(size: 11, weight: .semibold)
}

/// A rounded square with a gradient and a white symbol, as in System Settings.
struct IconTile: View {
    let symbol: String
    let gradient: LinearGradient
    var size: CGFloat = 22
    var symbolScale: CGFloat = 0.52

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.28, style: .continuous).fill(gradient)
            RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
                .strokeBorder(LinearGradient(colors: [.white.opacity(0.35), .white.opacity(0.05)],
                                             startPoint: .top, endPoint: .bottom), lineWidth: 0.75)
            Image(systemName: symbol)
                .font(.system(size: size * symbolScale, weight: .semibold))
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.15), radius: 0.5, y: 0.5)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

extension LinearGradient {
    /// A top-to-bottom gradient made from one colour, for icon tiles.
    static func tile(_ color: Color) -> LinearGradient {
        LinearGradient(colors: [color.mixed(with: .white, by: 0.18), color.mixed(with: .black, by: 0.08)],
                       startPoint: .top, endPoint: .bottom)
    }
}

/// The one prominent action of a screen, such as Clean or Move to Trash: a gradient capsule with white text.
struct PrimaryActionStyle: ButtonStyle {
    let gradient: LinearGradient

    func makeBody(configuration: Configuration) -> some View {
        PrimaryActionLabel(configuration: configuration, gradient: gradient)
    }

    private struct PrimaryActionLabel: View {
        @Environment(\.isEnabled) private var isEnabled
        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        let configuration: Configuration
        let gradient: LinearGradient
        @State private var hovering = false

        var body: some View {
            configuration.label
                .font(.body.weight(.semibold))
                .lineLimit(1)
                .fixedSize()
                .foregroundStyle(.white)
                .padding(.horizontal, 16)
                .padding(.vertical, 7)
                .background {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(gradient)
                        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .fill(Color.white.opacity(hovering && isEnabled ? 0.10 : 0)))
                        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.22), lineWidth: 0.75))
                }
                .shadow(color: .black.opacity(isEnabled ? (hovering ? 0.22 : 0.14) : 0), radius: hovering ? 6 : 3, y: 2)
                .saturation(isEnabled ? 1 : 0)
                .opacity(isEnabled ? 1 : 0.45)
                .scaleEffect(configuration.isPressed && !reduceMotion ? 0.97 : 1)
                .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                .onHover { inside in hovering = inside }
                .animation(Motion.hover.unless(reduceMotion), value: hovering)
                .animation(Motion.quick.unless(reduceMotion), value: configuration.isPressed)
        }
    }
}

extension ButtonStyle where Self == PrimaryActionStyle {
    /// The gradient button for the main action of a screen.
    static func primaryAction(_ gradient: LinearGradient = .smartClean) -> PrimaryActionStyle {
        PrimaryActionStyle(gradient: gradient)
    }
}

/// A white (or, in Dark mode, raised) card on a well: rounded, with a hairline border and a soft shadow.
private struct CardModifier: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var radius: CGFloat
    var tint: Color?
    var hoverable: Bool
    @State private var hovering = false

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(Palette.card)
                    .shadow(color: .black.opacity(hovering ? 0.10 : 0.05), radius: hovering ? 8 : 3, y: hovering ? 3 : 1)
            )
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder((tint ?? Color.primary).opacity(tint == nil ? 0.08 : 0.45), lineWidth: 1)
            )
            .onHover { inside in
                guard hoverable else { return }
                withAnimation(Motion.hover.unless(reduceMotion)) { hovering = inside }
            }
    }
}

extension View {
    /// Draws the view as a card. `tint` colours the border, for a ticked card.
    func card(radius: CGFloat = Radius.card, tint: Color? = nil, hoverable: Bool = true) -> some View {
        modifier(CardModifier(radius: radius, tint: tint, hoverable: hoverable))
    }
}

/// A byte count that counts up from zero the first time it appears, then follows its value.
struct CountUpBytes: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let bytes: Int64
    var suffix: String = ""
    @State private var shown = false

    var body: some View {
        CountingBytes(shown ? bytes : 0, suffix: suffix)
            .animation(Motion.smooth.unless(reduceMotion), value: bytes)
            .onAppear {
                guard !shown else { return }
                if reduceMotion { shown = true } else { withAnimation(.easeOut(duration: 0.7)) { shown = true } }
            }
    }
}
