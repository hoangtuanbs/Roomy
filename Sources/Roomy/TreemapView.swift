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

    var body: some View {
        GeometryReader { geo in
            if let tree = model.tree {
                let _ = model.treeVersion
                let tiles = TreemapBuilder.tiles(tree: tree, folder: model.currentFolder, in: CGRect(origin: .zero, size: geo.size))
                let hovered = model.hovered
                let basket = model.basket

                Canvas { context, _ in
                    for tile in tiles {
                        draw(tile, tree: tree, hovered: hovered, basket: basket, in: &context)
                    }
                }
                .contentShape(Rectangle())
                .onContinuousHover { phase in
                    switch phase {
                    case .active(let point):
                        model.hovered = hit(tiles, at: point, preferInner: true)
                    case .ended:
                        model.hovered = nil
                    }
                }
                .gesture(SpatialTapGesture().onEnded { value in
                    if let node = hit(tiles, at: value.location, preferInner: false) {
                        if tree.kind(node) == .directory { model.open(node) } else { model.reveal(node) }
                    }
                })
                .contextMenu {
                    if let node = model.hovered {
                        Button("Reveal in Finder") { model.reveal(node) }
                        Button(model.isInBasket(node) ? "Remove from Cleanup List" : "Add to Cleanup List") {
                            model.toggleBasket(node)
                        }
                        .disabled(model.verdict(for: node).isBlocked)
                        Button("Compress and Move Original to Trash…") { model.startCompress(node) }
                            .disabled(!model.canCompress(node))
                    }
                }
            }
        }
        .background(RoundedRectangle(cornerRadius: 8).fill(.quaternary.opacity(0.5)))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func draw(_ tile: TreemapTile, tree: ScanTree, hovered: ScanTree.Index?, basket: Set<ScanTree.Index>, in context: inout GraphicsContext) {
        let rect = tile.rect.insetBy(dx: tile.depth == 0 ? 1 : 0.5, dy: tile.depth == 0 ? 1 : 0.5)
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
            if node == hovered {
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

    private func hit(_ tiles: [TreemapTile], at point: CGPoint, preferInner: Bool) -> ScanTree.Index? {
        let matches = tiles.filter { $0.rect.contains(point) && $0.node != nil }
        if preferInner, let inner = matches.first(where: { $0.depth == 1 }) { return inner.node }
        return matches.first(where: { $0.depth == 0 })?.node
    }
}
