import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// Squarified treemap layout.
public enum Treemap {
    public static func squarify(values: [Double], in bounds: CGRect) -> [CGRect] {
        var result = [CGRect](repeating: .zero, count: values.count)
        let order = values.indices.filter { values[$0] > 0 }.sorted { values[$0] > values[$1] }
        let total = order.reduce(0) { $0 + values[$1] }
        guard total > 0, bounds.width > 0, bounds.height > 0 else { return result }

        let scale = Double(bounds.width * bounds.height) / total
        var remaining = bounds
        var row: [Int] = []
        var rowAreas: [Double] = []
        var i = 0

        func worst(_ areas: [Double], side: Double) -> Double {
            guard let maxA = areas.max(), let minA = areas.min(), minA > 0 else { return .infinity }
            let s = areas.reduce(0, +)
            let side2 = side * side
            return max(side2 * maxA / (s * s), (s * s) / (side2 * minA))
        }

        func layoutRow() {
            let s = rowAreas.reduce(0, +)
            if remaining.width >= remaining.height {
                let w = remaining.height > 0 ? s / Double(remaining.height) : 0
                var y = Double(remaining.minY)
                for (k, index) in row.enumerated() {
                    let h = w > 0 ? rowAreas[k] / w : 0
                    result[index] = CGRect(x: Double(remaining.minX), y: y, width: w, height: h)
                    y += h
                }
                remaining = CGRect(x: Double(remaining.minX) + w, y: Double(remaining.minY),
                                   width: max(0, Double(remaining.width) - w), height: Double(remaining.height))
            } else {
                let h = remaining.width > 0 ? s / Double(remaining.width) : 0
                var x = Double(remaining.minX)
                for (k, index) in row.enumerated() {
                    let w = h > 0 ? rowAreas[k] / h : 0
                    result[index] = CGRect(x: x, y: Double(remaining.minY), width: w, height: h)
                    x += w
                }
                remaining = CGRect(x: Double(remaining.minX), y: Double(remaining.minY) + h,
                                   width: Double(remaining.width), height: max(0, Double(remaining.height) - h))
            }
            row.removeAll()
            rowAreas.removeAll()
        }

        while i < order.count {
            let side = Double(min(remaining.width, remaining.height))
            let area = values[order[i]] * scale
            if row.isEmpty || worst(rowAreas + [area], side: side) <= worst(rowAreas, side: side) {
                row.append(order[i])
                rowAreas.append(area)
                i += 1
            } else {
                layoutRow()
            }
        }
        if !row.isEmpty { layoutRow() }
        return result
    }
}
