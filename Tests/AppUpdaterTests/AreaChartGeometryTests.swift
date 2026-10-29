import CoreGraphics
import Testing
@testable import AppUpdater

@Suite("Area chart geometry")
struct AreaChartGeometryTests {
    private let size = CGSize(width: 100, height: 50)

    @Test("Short histories are right-aligned in the slots")
    func rightAligned() {
        let points = AreaChartGeometry.points(values: [0, 1], capacity: 5, yMax: 1, in: size)
        #expect(points == [CGPoint(x: 75, y: 50), CGPoint(x: 100, y: 0)])
    }

    @Test("Values outside the domain are clamped to the plot")
    func clamped() {
        let points = AreaChartGeometry.points(values: [-3, 0.5, 9], capacity: 3, yMax: 1, in: size)
        #expect(points.map(\.y) == [50, 25, 0])
    }

    @Test("Empty input or zero domain yields no points")
    func emptyInput() {
        #expect(AreaChartGeometry.points(values: [], capacity: 5, yMax: 1, in: size).isEmpty)
        #expect(AreaChartGeometry.points(values: [1], capacity: 5, yMax: 0, in: size).isEmpty)
    }

    @Test("Monotone curve never overshoots the samples")
    func noOvershoot() {
        let points = AreaChartGeometry.points(values: [0, 0, 1, 1, 0, 0.2], capacity: 6, yMax: 1, in: size)
        let bounds = AreaChartGeometry.monotonePath(through: points).boundingBoxOfPath
        #expect(bounds.minY >= -0.001)
        #expect(bounds.maxY <= 50.001)
        #expect(bounds.minX == 0)
        #expect(bounds.maxX == 100)
    }

    @Test("Area closes down to the baseline")
    func areaReachesBaseline() {
        let points = AreaChartGeometry.points(values: [0.5, 0.8], capacity: 2, yMax: 1, in: size)
        let line = AreaChartGeometry.monotonePath(through: points)
        let area = AreaChartGeometry.areaPath(line: line, from: points, baseline: size.height)
        #expect(area.boundingBoxOfPath.maxY == 50)
    }
}
