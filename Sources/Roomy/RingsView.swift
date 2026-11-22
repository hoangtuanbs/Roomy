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
        .background(RoundedRectangle(cornerRadius: 8).fill(.quaternary.opacity(0.5)))
        .clipShape(RoundedRectangle(cornerRadius: 8))
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
        hole = radius * 0.26
        ring = (radius - hole) / CGFloat(Self.depth)
    }

    func radii(_ depth: Int) -> (inner: CGFloat, outer: CGFloat) {
        let inner = hole + CGFloat(depth - 1) * ring + 1
        return (inner, inner + ring - 2)
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
                var path = Path()
                path.addArc(center: geometry.center, radius: outer, startAngle: .radians(start), endAngle: .radians(end),
                            clockwise: false)
                path.addArc(center: geometry.center, radius: inner, startAngle: .radians(end), endAngle: .radians(start),
                            clockwise: true)
                path.closeSubpath()

                let node = arc.node
                let category = FileCategory.classify(name: tree.name(node), kind: tree.kind(node))
                let isHovered = node == hovered
                let related = isHovered || hovered.map { tree.isAncestor(node, of: $0) || tree.isAncestor($0, of: node) } == true
                var opacity = 0.92 - 0.1 * Double(arc.depth - 1)
                if dimmed && !related { opacity *= 0.55 }
                if isHovered { opacity = 1 }
                context.fill(path, with: .color(category.color.opacity(opacity)))
                if basket.contains(node) {
                    context.fill(path, with: .color(.red.opacity(0.28)))
                    context.stroke(path, with: .color(.red), lineWidth: 1.5)
                }
                if node == selection {
                    context.stroke(path, with: .color(.accentColor), lineWidth: 2.5)
                } else if isHovered {
                    context.stroke(path, with: .color(.white), lineWidth: 2)
                }
            }
        }
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
                .fill(.background.opacity(highlighted && canGoUp ? 0.95 : 0.8))
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
                    .font(.callout.weight(.semibold))
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .minimumScaleFactor(0.7)
                CountingBytes(tree.size(folder))
                    .font(.headline)
                    .foregroundStyle(.secondary)
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
