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

    static func tiles(tree: ScanTree, folder: ScanTree.Index, in bounds: CGRect) -> [TreemapTile] {
        var tiles: [TreemapTile] = []
        let top = level(tree: tree, folder: folder, limit: maxTopTiles, in: bounds, depth: 0)
        tiles.append(contentsOf: top)
        for tile in top {
            guard let node = tile.node, tree.kind(node).isContainer,
                  tile.rect.width > 48, tile.rect.height > 40 else { continue }
            let inner = CGRect(x: tile.rect.minX + 3, y: tile.rect.minY + 18,
                               width: tile.rect.width - 6, height: tile.rect.height - 21)
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
        .background(RoundedRectangle(cornerRadius: 8).fill(.quaternary.opacity(0.5)))
        .clipShape(RoundedRectangle(cornerRadius: 8))
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
        let rect = tileRect.insetBy(dx: tile.depth == 0 ? 1 : 0.5, dy: tile.depth == 0 ? 1 : 0.5)
        guard rect.width > 0, rect.height > 0 else { return }
        let shape = Path(roundedRect: rect, cornerRadius: tile.depth == 0 ? 4 : 2)

        let base: Color
        if let node = tile.node {
            base = FileCategory.classify(name: tree.name(node), kind: tree.kind(node)).color
        } else {
            base = .gray
        }
        let isContainerTile = tile.depth == 0 && tile.node.map { tree.kind($0).isContainer } == true
        context.fill(shape, with: .color(base.opacity(isContainerTile ? 0.35 : (tile.depth == 0 ? 0.85 : 0.75))))
        context.stroke(shape, with: .color(.black.opacity(0.18)), lineWidth: 0.5)

        if let node = tile.node {
            if basket.contains(node) {
                context.fill(shape, with: .color(.red.opacity(0.25)))
                context.stroke(shape, with: .color(.red), lineWidth: 1.5)
            }
            if node == selection {
                context.fill(shape, with: .color(.white.opacity(0.18)))
                context.stroke(shape, with: .color(.accentColor), lineWidth: 2.5)
            } else if node == hovered {
                context.stroke(shape, with: .color(.white), lineWidth: 2)
            }
            if tile.depth == 0, rect.width > 44, rect.height > 16 {
                let label = Text(tree.name(node)).font(.system(size: 11, weight: .semibold)).foregroundColor(.white)
                context.draw(label, in: CGRect(x: rect.minX + 5, y: rect.minY + 2, width: rect.width - 10, height: 15))
            }
        } else if tile.depth == 0, rect.width > 60, rect.height > 16 {
            let label = Text("Smaller items").font(.system(size: 11)).foregroundColor(.white.opacity(0.9))
            context.draw(label, in: CGRect(x: rect.minX + 5, y: rect.minY + 2, width: rect.width - 10, height: 15))
        }
    }
}
