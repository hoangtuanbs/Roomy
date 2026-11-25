import RoomyCore
import SwiftUI

/// The ring (sunburst) chart: the open folder in the middle, and each ring one level deeper.
struct RingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            RingsChart(folder: model.currentFolder)
                .id(model.currentFolder)
                .transition(MapZoom.transition(zoomingOut: model.zoomingOut, reduceMotion: reduceMotion))
        }
        .animation(Motion.spring.unless(reduceMotion), value: model.currentFolder)
        .background(RoundedRectangle(cornerRadius: Radius.panel, style: .continuous).fill(Palette.well))
        .overlay(RoundedRectangle(cornerRadius: Radius.panel, style: .continuous).strokeBorder(Palette.border))
        .clipShape(RoundedRectangle(cornerRadius: Radius.panel, style: .continuous))
    }
}

/// Ring sizes for a chart that fits `size`.
private struct RingGeometry {
    static let depth = 4

    let center: CGPoint
    let hole: CGFloat
    let ring: CGFloat

    init(size: CGSize) {
        center = CGPoint(x: size.width / 2, y: size.height / 2)
        let radius = max(0, min(size.width, size.height) / 2 - 12)
        hole = radius * 0.30
        ring = (radius - hole) / CGFloat(Self.depth)
    }

    func radii(_ depth: Int) -> (inner: CGFloat, outer: CGFloat) {
        let inner = hole + CGFloat(depth - 1) * ring + 1.5
        return (inner, inner + ring - 3)
    }

    func locate(_ point: CGPoint) -> (depth: Int, fraction: Double)? {
        Sunburst.locate(x: Double(point.x - center.x), y: Double(point.y - center.y),
                        centerRadius: Double(hole), ringWidth: Double(ring), maxDepth: Self.depth)
    }
}

private struct RingsChart: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let folder: ScanTree.Index
    @State private var sweep: Double = 0
    @State private var pointer: CGPoint?
    @State private var overCenter = false

    var body: some View {
        GeometryReader { geo in
            if let tree = model.tree {
                let _ = model.treeVersion
                let geometry = RingGeometry(size: geo.size)
                let arcs = Sunburst.layout(tree: tree, center: folder, maxDepth: RingGeometry.depth, minSpan: 0.003)
                let hovered = model.hovered

                ZStack {
                    SweepingRings(sweep: sweep, arcs: arcs, tree: tree, geometry: geometry, hovered: hovered,
                                  selection: model.selection, basket: model.basket)
                        .contentShape(Rectangle())
                        .onContinuousHover { phase in
                            switch phase {
                            case .active(let point):
                                pointer = point
                                let spot = geometry.locate(point)
                                overCenter = spot?.depth == 0
                                if let spot, spot.depth > 0 {
                                    model.hovered = Sunburst.arc(at: spot.fraction, depth: spot.depth, in: arcs)?.node
                                } else {
                                    model.hovered = nil
                                }
                            case .ended:
                                pointer = nil
                                overCenter = false
                                model.hovered = nil
                            }
                        }
                        .gesture(SpatialTapGesture().onEnded { value in
                            guard let spot = geometry.locate(value.location) else {
                                model.selection = nil
                                return
                            }
                            if spot.depth == 0 {
                                model.goUp()
                            } else if let arc = Sunburst.arc(at: spot.fraction, depth: spot.depth, in: arcs) {
                                model.selection = arc.node
                                if tree.kind(arc.node) == .directory { model.open(arc.node) }
                            }
                        })
                        .trayDraggable(hovered, model: model)
                        .contextMenu {
                            if let node = model.hovered { NodeMenu(node: node) }
                        }

                    CenterLabel(tree: tree, folder: folder, canGoUp: folder != ScanTree.root, highlighted: overCenter)
                        .frame(width: geometry.hole * 2 - 8, height: geometry.hole * 2 - 8)
                        .position(geometry.center)
                        .allowsHitTesting(false)

                    if let node = hovered, let pointer, arcs.contains(where: { $0.node == node }) {
                        RingTooltip(tree: tree, node: node, color: model.category(of: node).color)
                            .fixedSize()
                            .position(x: min(max(pointer.x, 90), geo.size.width - 90), y: max(pointer.y - 30, 16))
                            .allowsHitTesting(false)
                            .transition(.opacity)
                    }
                }
                .animation(Motion.hover.unless(reduceMotion), value: hovered)
            }
        }
        .onAppear {
            if reduceMotion {
                sweep = 1
            } else {
                withAnimation(.spring(response: 0.5, dampingFraction: 0.9)) { sweep = 1 }
            }
        }
    }
}

/// Draws the rings, opening clockwise from the top as `sweep` goes from 0 to 1.
private struct SweepingRings: View, Animatable {
    var sweep: Double
    let arcs: [SunburstArc]
    let tree: ScanTree
    let geometry: RingGeometry
    let hovered: ScanTree.Index?
    let selection: ScanTree.Index?
    let basket: Set<ScanTree.Index>

    var animatableData: Double {
        get { sweep }
        set { sweep = newValue }
    }

    var body: some View {
        Canvas { context, _ in
            let turn = 2 * Double.pi * sweep
            let dimmed = hovered != nil
            for arc in arcs {
                let (inner, outer) = geometry.radii(arc.depth)
                guard outer > inner else { continue }
                let start = -Double.pi / 2 + arc.start * turn
                let end = -Double.pi / 2 + arc.end * turn
                guard end - start > 0.0005 else { continue }

                let node = arc.node
                let category = FileCategory.classify(name: tree.name(node), kind: tree.kind(node))
                let isHovered = node == hovered
                let related = isHovered || hovered.map { tree.isAncestor(node, of: $0) || tree.isAncestor($0, of: node) } == true
                var opacity = 1.0 - 0.12 * Double(arc.depth - 1)
                if dimmed && !related { opacity *= 0.45 }
                if isHovered { opacity = 1 }
                let stops = category.gradientStops
                let shading = GraphicsContext.Shading.radialGradient(
                    Gradient(colors: [stops.bottom.opacity(opacity), stops.top.opacity(opacity)]),
                    center: geometry.center, startRadius: inner, endRadius: outer)

                let path = Self.segment(center: geometry.center, inner: inner, outer: outer, start: start, end: end)
                if isHovered {
                    var lifted = context
                    lifted.addFilter(.shadow(color: .black.opacity(0.25), radius: 6, x: 0, y: 2))
                    lifted.fill(path, with: shading)
                }
                context.fill(path, with: shading)
                if basket.contains(node) {
                    context.fill(path, with: .color(Color(red: 0.95, green: 0.25, blue: 0.35).opacity(0.28)))
                    context.stroke(path, with: .color(Color(red: 0.95, green: 0.25, blue: 0.35)), lineWidth: 1.5)
                }
                if node == selection {
                    context.stroke(path, with: .color(.accentColor), lineWidth: 2.5)
                } else if isHovered {
                    context.stroke(path, with: .color(.white.opacity(0.9)), lineWidth: 1.5)
                }
            }
        }
    }

    /// A ring segment with a small gap on each side and softly rounded corners.
    static func segment(center: CGPoint, inner: CGFloat, outer: CGFloat, start: Double, end: Double) -> Path {
        let mid = Double((inner + outer) / 2)
        // Half a gap of 1.5 points on each side, as an angle at the middle of the ring.
        let gap = 0.75 / mid
        var a0 = start + gap, a1 = end - gap
        if a1 <= a0 {
            let m = (start + end) / 2
            a0 = m - 0.0004
            a1 = m + 0.0004
        }
        let corner = min(CGFloat(3), (outer - inner) / 3, CGFloat((a1 - a0) * Double(inner)) / 2.5)
        guard corner > 0.6 else {
            var path = Path()
            path.addArc(center: center, radius: outer, startAngle: .radians(a0), endAngle: .radians(a1), clockwise: false)
            path.addArc(center: center, radius: inner, startAngle: .radians(a1), endAngle: .radians(a0), clockwise: true)
            path.closeSubpath()
            return path
        }
        // Each corner is a quadratic curve through the sharp corner, so the segment keeps its size.
        let ci = Double(corner) / Double(inner), co = Double(corner) / Double(outer)
        func point(_ r: CGFloat, _ a: Double) -> CGPoint {
            CGPoint(x: center.x + r * CGFloat(cos(a)), y: center.y + r * CGFloat(sin(a)))
        }
        var path = Path()
        path.move(to: point(inner + corner, a0))
        path.addQuadCurve(to: point(inner, a0 + ci), control: point(inner, a0))
        path.addArc(center: center, radius: inner, startAngle: .radians(a0 + ci), endAngle: .radians(a1 - ci), clockwise: false)
        path.addQuadCurve(to: point(inner + corner, a1), control: point(inner, a1))
        path.addLine(to: point(outer - corner, a1))
        path.addQuadCurve(to: point(outer, a1 - co), control: point(outer, a1))
        path.addArc(center: center, radius: outer, startAngle: .radians(a1 - co), endAngle: .radians(a0 + co), clockwise: true)
        path.addQuadCurve(to: point(outer - corner, a0), control: point(outer, a0))
        path.closeSubpath()
        return path
    }
}

/// The open folder's name and size in the middle. Clicking it goes up a level.
private struct CenterLabel: View {
    let tree: ScanTree
    let folder: ScanTree.Index
    let canGoUp: Bool
    let highlighted: Bool

    var body: some View {
        ZStack {
            Circle()
                .fill(Palette.card)
                .overlay(Circle().strokeBorder(Color.accentColor.opacity(highlighted && canGoUp ? 0.7 : 0.15), lineWidth: 1.5))
                .shadow(color: .black.opacity(0.12), radius: 6, y: 2)
                .scaleEffect(highlighted && canGoUp ? 1.04 : 1)
            VStack(spacing: 2) {
                if canGoUp {
                    Image(systemName: "chevron.up")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(highlighted ? Color.accentColor : Color.secondary)
                }
                Text(folder == ScanTree.root ? (tree.rootPath as NSString).lastPathComponent : tree.name(folder))
                    .font(.system(.callout, design: .rounded).weight(.semibold))
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .minimumScaleFactor(0.7)
                CountUpBytes(bytes: tree.size(folder))
                    .font(.system(size: 17, weight: .bold, design: .rounded))
                    .foregroundStyle(LinearGradient.scan)
            }
            .padding(8)
        }
        .motion(Motion.quick, value: highlighted)
        .help(canGoUp ? "Go to the enclosing folder" : "")
    }
}

private struct RingTooltip: View {
    let tree: ScanTree
    let node: ScanTree.Index
    let color: Color

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(tree.name(node)).lineLimit(1)
            Text(tree.size(node).bytes).monospacedDigit().foregroundStyle(.secondary)
        }
        .font(.callout)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Capsule().fill(.regularMaterial))
        .overlay(Capsule().strokeBorder(Color.primary.opacity(0.1)))
        .shadow(color: .black.opacity(0.15), radius: 4, y: 2)
    }
}
