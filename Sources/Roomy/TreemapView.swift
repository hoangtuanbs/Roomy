import RoomyCore
import SwiftUI

struct TreemapTile {
    let node: ScanTree.Index?
    let rect: CGRect
    let depth: Int
}

enum TreemapBuilder {
    static let maxTopTiles = 300
    static let maxInnerTiles = 80
    /// The strip at the top of a folder tile that holds its name and size.
    static let headerHeight: CGFloat = 24

    static func tiles(tree: ScanTree, folder: ScanTree.Index, in bounds: CGRect) -> [TreemapTile] {
        var tiles: [TreemapTile] = []
        let top = level(tree: tree, folder: folder, limit: maxTopTiles, in: bounds, depth: 0)
        tiles.append(contentsOf: top)
        for tile in top {
            guard let node = tile.node, tree.kind(node).isContainer,
                  tile.rect.width > 56, tile.rect.height > 52 else { continue }
            let inner = CGRect(x: tile.rect.minX + 5, y: tile.rect.minY + headerHeight,
                               width: tile.rect.width - 10, height: tile.rect.height - headerHeight - 5)
            tiles.append(contentsOf: level(tree: tree, folder: node, limit: maxInnerTiles, in: inner, depth: 1))
        }
        return tiles
    }

    private static func level(tree: ScanTree, folder: ScanTree.Index, limit: Int, in rect: CGRect, depth: Int) -> [TreemapTile] {
        let kids = tree.children(folder).filter { tree.size($0) > 0 }
        let shown = Array(kids.prefix(limit))
        var values = shown.map { Double(tree.size($0)) }
        let rest = kids.dropFirst(limit).reduce(Int64(0)) { $0 + tree.size($1) }
        if rest > 0 { values.append(Double(rest)) }
        let rects = Treemap.squarify(values: values, in: rect)
        var out: [TreemapTile] = []
        for (i, r) in rects.enumerated() where r.width >= 1 && r.height >= 1 {
            out.append(TreemapTile(node: i < shown.count ? shown[i] : nil, rect: r, depth: depth))
        }
        return out
    }
}

struct TreemapView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            TreemapCanvas(folder: model.currentFolder)
                .id(model.currentFolder)
                .transition(MapZoom.transition(zoomingOut: model.zoomingOut, reduceMotion: reduceMotion))
        }
        .animation(Motion.spring.unless(reduceMotion), value: model.currentFolder)
        .padding(4)
        .background(RoundedRectangle(cornerRadius: Radius.panel, style: .continuous).fill(Palette.well))
        .overlay(RoundedRectangle(cornerRadius: Radius.panel, style: .continuous).strokeBorder(Palette.border))
        .clipShape(RoundedRectangle(cornerRadius: Radius.panel, style: .continuous))
    }
}

/// The zoom used when the treemap or the rings open a folder or go up.
enum MapZoom {
    static func transition(zoomingOut: Bool, reduceMotion: Bool) -> AnyTransition {
        guard !reduceMotion else { return .opacity }
        return .asymmetric(
            insertion: .scale(scale: zoomingOut ? 1.25 : 0.7).combined(with: .opacity),
            removal: .opacity
        )
    }
}

/// The tiles drawn last time, so a new layout can grow out of the old one. It is a plain object, so writing to
/// it while drawing does not redraw anything.
private final class TileMemory {
    var tree: ObjectIdentifier?
    var version = -1
    var current: [TreemapTile] = []
    var previous: [TreemapTile] = []

    /// Records `tiles` as the layout for `version` and returns the layout before it.
    func remember(_ tiles: [TreemapTile], tree: ScanTree, version: Int) -> [TreemapTile] {
        let id = ObjectIdentifier(tree)
        if id != self.tree {
            self.tree = id
            previous = []
        } else if version != self.version {
            previous = current
        }
        self.version = version
        current = tiles
        return previous
    }
}

private struct TreemapCanvas: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let folder: ScanTree.Index
    @State private var memory = TileMemory()
    /// Runs from 0 to 1 as the tiles first come in.
    @State private var appear: Double = 0
    /// Follows the tree version with an animation, so tiles slide to their new places after items are removed.
    @State private var shownVersion: Double = -1

    var body: some View {
        GeometryReader { geo in
            if let tree = model.tree {
                let version = model.treeVersion
                let tiles = TreemapBuilder.tiles(tree: tree, folder: folder, in: CGRect(origin: .zero, size: geo.size))
                let previous = memory.remember(tiles, tree: tree, version: version)
                let hovered = model.hovered

                TreemapDrawing(
                    tree: tree,
                    tiles: tiles,
                    previous: shownVersion < 0 ? [] : previous,
                    target: Double(version),
                    hovered: hovered,
                    selection: model.selection,
                    basket: model.basket,
                    appear: appear,
                    morph: shownVersion < 0 ? Double(version) : shownVersion
                )
                .contentShape(Rectangle())
                .onContinuousHover { phase in
                    switch phase {
                    case .active(let point):
                        model.hovered = hit(tiles, at: point, preferInner: true)
                    case .ended:
                        model.hovered = nil
                    }
                }
                .gesture(SpatialTapGesture(count: 2).onEnded { value in
                    if let node = hit(tiles, at: value.location, preferInner: false) {
                        if tree.kind(node) == .directory { model.open(node) } else { model.reveal(node) }
                    }
                })
                .simultaneousGesture(SpatialTapGesture().onEnded { value in
                    model.selection = hit(tiles, at: value.location, preferInner: true)
                })
                .trayDraggable(hovered, model: model)
                .contextMenu {
                    if let node = model.hovered { NodeMenu(node: node) }
                }
            }
        }
        .onAppear {
            shownVersion = Double(model.treeVersion)
            if reduceMotion {
                appear = 1
            } else {
                withAnimation(.easeOut(duration: 0.45)) { appear = 1 }
            }
        }
        .onChange(of: model.treeVersion) { _, version in
            withAnimation(Motion.spring.unless(reduceMotion)) { shownVersion = Double(version) }
        }
    }

    private func hit(_ tiles: [TreemapTile], at point: CGPoint, preferInner: Bool) -> ScanTree.Index? {
        let matches = tiles.filter { $0.rect.contains(point) && $0.node != nil }
        if preferInner, let inner = matches.first(where: { $0.depth == 1 }) { return inner.node }
        return matches.first(where: { $0.depth == 0 })?.node
    }
}

/// Draws the tiles. While `appear` runs to 1 the tiles grow in, biggest first. While `morph` catches up with
/// `target` the tiles move from where they were in `previous`, new ones grow and removed ones shrink away.
private struct TreemapDrawing: View, Animatable {
    private struct Key: Hashable {
        let node: ScanTree.Index?
        let depth: Int
    }

    @Environment(\.colorScheme) private var colorScheme
    let tree: ScanTree
    let tiles: [TreemapTile]
    let previous: [TreemapTile]
    let target: Double
    let hovered: ScanTree.Index?
    let selection: ScanTree.Index?
    let basket: Set<ScanTree.Index>
    var appear: Double
    var morph: Double

    var animatableData: AnimatablePair<Double, Double> {
        get { AnimatablePair(appear, morph) }
        set {
            appear = newValue.first
            morph = newValue.second
        }
    }

    var body: some View {
        // 0 shows the old layout, 1 the new one.
        let t = min(1, max(0, 1 - (target - morph)))
        let moving = t < 1 && !previous.isEmpty
        let before: [Key: CGRect] = moving
            ? Dictionary(previous.map { (Key(node: $0.node, depth: $0.depth), $0.rect) }, uniquingKeysWith: { a, _ in a })
            : [:]
        let staggered = Double(min(tiles.count, 30))

        Canvas { context, _ in
            if moving {
                // Tiles that are gone shrink and fade where they were.
                let now = Set(tiles.map { Key(node: $0.node, depth: $0.depth) })
                for tile in previous where !now.contains(Key(node: tile.node, depth: tile.depth)) {
                    var faded = context
                    faded.opacity = 1 - t
                    draw(tile, rect: Self.scale(tile.rect, by: 1 - 0.5 * t), in: &faded)
                }
            }
            for (i, tile) in tiles.enumerated() {
                var rect = tile.rect
                var alpha = 1.0
                if moving {
                    if let old = before[Key(node: tile.node, depth: tile.depth)] {
                        rect = Self.mix(old, tile.rect, t)
                    } else {
                        rect = Self.scale(tile.rect, by: t)
                        alpha = t
                    }
                }
                if appear < 1 {
                    let delay = Double(min(i, 30)) / max(1, staggered) * 0.35
                    let local = min(1, max(0, (appear - delay) / 0.65))
                    rect = Self.scale(rect, by: 0.9 + 0.1 * local)
                    alpha *= local
                }
                guard alpha > 0.01 else { continue }
                var layer = context
                layer.opacity = alpha
                draw(tile, rect: rect, in: &layer)
            }
        }
    }

    private static func mix(_ a: CGRect, _ b: CGRect, _ t: Double) -> CGRect {
        let t = CGFloat(t)
        return CGRect(x: a.minX + (b.minX - a.minX) * t, y: a.minY + (b.minY - a.minY) * t,
                      width: a.width + (b.width - a.width) * t, height: a.height + (b.height - a.height) * t)
    }

    private static func scale(_ rect: CGRect, by factor: Double) -> CGRect {
        let f = CGFloat(max(0, factor))
        return CGRect(x: rect.midX - rect.width * f / 2, y: rect.midY - rect.height * f / 2,
                      width: rect.width * f, height: rect.height * f)
    }

    private func draw(_ tile: TreemapTile, rect tileRect: CGRect, in context: inout GraphicsContext) {
        // Half of the gap between tiles on each side.
        let gap: CGFloat = tile.depth == 0 ? 1.5 : 1.25
        let rect = tileRect.insetBy(dx: gap, dy: gap)
        guard rect.width > 0.5, rect.height > 0.5 else { return }
        let radius = min(tile.depth == 0 ? 7 : 5, min(rect.width, rect.height) / 3)
        let shape = Path(roundedRect: rect, cornerRadius: radius, style: .continuous)

        let category = tile.node.map { FileCategory.classify(name: tree.name($0), kind: tree.kind($0)) } ?? .other
        let stops = category.gradientStops
        let isContainerTile = tile.depth == 0 && tile.node.map { tree.kind($0).isContainer } == true
        let hasInner = isContainerTile && tile.rect.width > 56 && tile.rect.height > 52
        let isHovered = tile.node != nil && tile.node == hovered
        let isSelected = tile.node != nil && tile.node == selection

        if hasInner {
            // A folder with its items inside: a soft tinted panel with a header strip.
            context.fill(shape, with: .color(category.color.opacity(isHovered ? 0.22 : 0.15)))
            context.stroke(shape, with: .color(category.color.opacity(0.35)), lineWidth: 1)
        } else {
            if isHovered {
                var lifted = context
                lifted.addFilter(.shadow(color: .black.opacity(0.28), radius: 6, x: 0, y: 3))
                lifted.fill(shape, with: .color(stops.bottom))
            }
            context.fill(shape, with: .linearGradient(Gradient(colors: [stops.top, stops.bottom]),
                                                      startPoint: CGPoint(x: rect.midX, y: rect.minY),
                                                      endPoint: CGPoint(x: rect.midX, y: rect.maxY)))
            // An inner highlight along the top, and a faint darker edge, give the tile some depth.
            if rect.width > 6, rect.height > 6 {
                let inner = Path(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), cornerRadius: max(0, radius - 0.5), style: .continuous)
                context.stroke(inner, with: .linearGradient(Gradient(colors: [.white.opacity(0.38), .white.opacity(0.04)]),
                                                            startPoint: CGPoint(x: rect.midX, y: rect.minY),
                                                            endPoint: CGPoint(x: rect.midX, y: rect.minY + min(rect.height, 40))),
                               lineWidth: 1)
            }
            context.stroke(shape, with: .color(.black.opacity(0.10)), lineWidth: 0.5)
            if isHovered {
                context.fill(shape, with: .color(.white.opacity(0.16)))
            }
        }

        if let node = tile.node {
            if basket.contains(node) {
                context.fill(shape, with: .color(Color(red: 0.95, green: 0.25, blue: 0.35).opacity(0.25)))
                context.stroke(shape, with: .color(Color(red: 0.95, green: 0.25, blue: 0.35)), style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
            }
            if isSelected {
                context.stroke(Path(roundedRect: rect.insetBy(dx: 1.25, dy: 1.25), cornerRadius: max(0, radius - 1), style: .continuous),
                               with: .color(.white), lineWidth: 1.5)
                context.stroke(shape, with: .color(.accentColor), lineWidth: 2.5)
            } else if isHovered {
                context.stroke(shape, with: .color(.white.opacity(hasInner ? 0.0 : 0.9)), lineWidth: 1.5)
                if hasInner {
                    context.stroke(shape, with: .color(category.color.opacity(0.8)), lineWidth: 1.5)
                }
            }
            if hasInner {
                drawHeader(name: tree.name(node), size: tree.size(node), color: category.color, in: rect, context: &context)
            } else {
                drawLabel(name: tree.name(node), size: tree.size(node), in: rect, context: &context)
            }
        } else if rect.width > 70, rect.height > 30 {
            drawLabel(name: String(localized: "Smaller items"), size: nil, in: rect, context: &context)
        }
    }

    /// A folder's name and size in the strip at its top.
    private func drawHeader(name: String, size: Int64, color: Color, in rect: CGRect, context: inout GraphicsContext) {
        let strip = CGRect(x: rect.minX + 8, y: rect.minY + 3, width: rect.width - 16, height: TreemapBuilder.headerHeight - 6)
        guard strip.width > 24 else { return }
        let sizeText = context.resolve(Text(size.bytes).font(.system(size: 11, weight: .medium, design: .rounded)).monospacedDigit()
            .foregroundColor(.secondary))
        let sizeWidth = sizeText.measure(in: strip.size).width
        let showsSize = strip.width > sizeWidth + 60
        let nameText = context.resolve(Text(name).font(.system(size: 12, weight: .semibold)).foregroundColor(colorScheme == .dark ? color.mixed(with: .white, by: 0.45) : color.mixed(with: .black, by: 0.35)))
        let nameRect = CGRect(x: strip.minX, y: strip.minY, width: strip.width - (showsSize ? sizeWidth + 8 : 0), height: strip.height)
        context.draw(nameText, in: nameRect)
        if showsSize {
            context.draw(sizeText, at: CGPoint(x: strip.maxX, y: strip.midY), anchor: .trailing)
        }
    }

    /// The name and size inside a tile, in white with a soft shadow, when the tile is big enough to read them.
    private func drawLabel(name: String, size: Int64?, in rect: CGRect, context: inout GraphicsContext) {
        guard rect.width > 54, rect.height > 22 else { return }
        var layer = context
        layer.addFilter(.shadow(color: .black.opacity(0.35), radius: 1.5, x: 0, y: 0.5))
        let big = rect.width > 140 && rect.height > 70
        let inset: CGFloat = big ? 10 : 7
        let width = rect.width - inset * 2
        let nameText = layer.resolve(Text(name).font(.system(size: big ? 13 : 11.5, weight: .semibold)).foregroundColor(.white))
        let nameHeight: CGFloat = big ? 17 : 15
        layer.draw(nameText, in: CGRect(x: rect.minX + inset, y: rect.minY + inset - 2, width: width, height: nameHeight))
        if let size, rect.height > (big ? 52 : 38) {
            let sizeText = layer.resolve(Text(size.bytes).font(.system(size: big ? 12 : 10.5, weight: .medium, design: .rounded))
                .monospacedDigit().foregroundColor(.white.opacity(0.85)))
            layer.draw(sizeText, in: CGRect(x: rect.minX + inset, y: rect.minY + inset - 2 + nameHeight, width: width, height: 15))
        }
    }
}
