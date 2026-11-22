import Foundation

/// One segment of a ring chart. Angles are fractions of a full turn, starting at the top and going clockwise.
public struct SunburstArc: Sendable, Equatable {
    public let node: ScanTree.Index
    /// 1 for the ring around the centre, 2 for the next, and so on.
    public let depth: Int
    public let start: Double
    public let end: Double

    public init(node: ScanTree.Index, depth: Int, start: Double, end: Double) {
        self.node = node
        self.depth = depth
        self.start = start
        self.end = end
    }

    public var span: Double { end - start }
}

/// Ring (sunburst) layout: each ring is one level deeper, and each item's angle is its share of its parent's.
public enum Sunburst {
    /// Arcs for the items inside `center`, down to `maxDepth` rings. Items narrower than `minSpan` (a fraction of a
    /// turn) are left out, together with what is inside them.
    public static func layout(tree: ScanTree, center: ScanTree.Index, maxDepth: Int = 4,
                              minSpan: Double = 0.002) -> [SunburstArc] {
        var arcs: [SunburstArc] = []
        guard maxDepth > 0 else { return arcs }
        var stack: [(node: ScanTree.Index, depth: Int, start: Double, end: Double)] = [(center, 0, 0, 1)]
        while let item = stack.popLast() {
            let total = tree.size(item.node)
            guard total > 0 else { continue }
            let scale = (item.end - item.start) / Double(total)
            var cursor = item.start
            for child in tree.children(item.node) {
                let size = tree.size(child)
                guard size > 0 else { continue }
                let span = Double(size) * scale
                let start = cursor
                cursor += span
                guard span >= minSpan else { continue }
                let arc = SunburstArc(node: child, depth: item.depth + 1, start: start, end: min(item.end, cursor))
                arcs.append(arc)
                if arc.depth < maxDepth && tree.kind(child).isContainer {
                    stack.append((child, arc.depth, arc.start, arc.end))
                }
            }
        }
        return arcs.sorted { $0.depth != $1.depth ? $0.depth < $1.depth : $0.start < $1.start }
    }

    /// The arc in ring `depth` that covers `fraction` of the turn.
    public static func arc(at fraction: Double, depth: Int, in arcs: [SunburstArc]) -> SunburstArc? {
        arcs.first { $0.depth == depth && fraction >= $0.start && fraction < $0.end }
    }

    /// Converts a point to a ring and a fraction of the turn. `centerRadius` is the hole in the middle and
    /// `ringWidth` the width of each ring. Returns depth 0 inside the hole, and nil outside the chart.
    public static func locate(x: Double, y: Double, centerRadius: Double, ringWidth: Double,
                              maxDepth: Int) -> (depth: Int, fraction: Double)? {
        let r = (x * x + y * y).squareRoot()
        // Screen coordinates: y grows downwards, so atan2 grows clockwise. Zero is at the top.
        var fraction = (atan2(y, x) + Double.pi / 2) / (2 * Double.pi)
        if fraction < 0 { fraction += 1 }
        if fraction >= 1 { fraction -= 1 }
        if r < centerRadius { return (0, fraction) }
        guard ringWidth > 0 else { return nil }
        let depth = Int((r - centerRadius) / ringWidth) + 1
        return depth <= maxDepth ? (depth, fraction) : nil
    }
}
