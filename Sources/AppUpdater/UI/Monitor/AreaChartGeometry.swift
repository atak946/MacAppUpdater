import CoreGraphics

/// Pure geometry behind `GlowAreaChart`: maps samples to points and builds a monotone curve.
/// Kept free of SwiftUI so it can be unit-tested and stays cheap to run on every sample.
enum AreaChartGeometry {
    /// Plots `values` right-aligned in `capacity` slots across `size`, with 0 at the bottom and `yMax` at the top.
    /// Values are clamped to the domain so a spike never draws outside the card.
    static func points(values: [Double], capacity: Int, yMax: Double, in size: CGSize) -> [CGPoint] {
        guard !values.isEmpty, yMax > 0 else { return [] }
        let slots = max(capacity, values.count)
        let step = size.width / CGFloat(max(1, slots - 1))
        let offset = slots - values.count
        return values.enumerated().map { index, value in
            let fraction = min(max(value / yMax, 0), 1)
            return CGPoint(x: CGFloat(offset + index) * step, y: size.height * (1 - CGFloat(fraction)))
        }
    }

    /// Monotone cubic curve through `points` (same as Swift Charts' `.monotone`, d3's `curveMonotoneX`):
    /// smooth, but never overshoots, so a flat 0% stretch stays flat instead of dipping below the baseline.
    static func monotonePath(through points: [CGPoint]) -> CGMutablePath {
        let path = CGMutablePath()
        guard let first = points.first else { return path }
        path.move(to: first)
        guard points.count > 1 else { return path }
        let tangents = monotoneTangents(points)
        for index in 1..<points.count {
            let p0 = points[index - 1], p1 = points[index]
            let third = (p1.x - p0.x) / 3
            path.addCurve(
                to: p1,
                control1: CGPoint(x: p0.x + third, y: p0.y + third * tangents[index - 1]),
                control2: CGPoint(x: p1.x - third, y: p1.y - third * tangents[index])
            )
        }
        return path
    }

    /// Closes the line down to `baseline` so it can be filled as an area.
    static func areaPath(line: CGPath, from points: [CGPoint], baseline: CGFloat) -> CGMutablePath {
        let area = CGMutablePath()
        guard let first = points.first, let last = points.last else { return area }
        area.addPath(line)
        area.addLine(to: CGPoint(x: last.x, y: baseline))
        area.addLine(to: CGPoint(x: first.x, y: baseline))
        area.closeSubpath()
        return area
    }

    /// Fritsch–Carlson style tangents (d3 `slope3` inside, `slope2` at the ends).
    private static func monotoneTangents(_ points: [CGPoint]) -> [CGFloat] {
        let count = points.count
        let secants = (0..<(count - 1)).map { index -> CGFloat in
            let dx = points[index + 1].x - points[index].x
            return dx == 0 ? 0 : (points[index + 1].y - points[index].y) / dx
        }
        var tangents = [CGFloat](repeating: 0, count: count)
        if count > 2 {
            for index in 1..<(count - 1) {
                let s0 = secants[index - 1], s1 = secants[index]
                let h0 = points[index].x - points[index - 1].x
                let h1 = points[index + 1].x - points[index].x
                let blended = h0 + h1 == 0 ? 0 : (s0 * h1 + s1 * h0) / (h0 + h1)
                let signs = (s0 < 0 ? -1 : s0 > 0 ? 1 : 0) + (s1 < 0 ? -1 : s1 > 0 ? 1 : 0)
                tangents[index] = CGFloat(signs) * min(abs(s0), abs(s1), 0.5 * abs(blended))
            }
            tangents[0] = (3 * secants[0] - tangents[1]) / 2
            tangents[count - 1] = (3 * secants[count - 2] - tangents[count - 2]) / 2
        } else {
            tangents[0] = secants[0]
            tangents[1] = secants[0]
        }
        return tangents
    }
}
