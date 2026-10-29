import SwiftUI

/// One line of an area chart.
struct ChartSeries: Identifiable, Equatable {
    let id: String
    let values: [Double]
    let tint: Color
}

/// Axis-free area chart: gradient fill fading to nothing under a line, newest sample on the right.
/// Drawn with a single `Canvas` instead of Swift Charts: Charts re-laid out and redrew every mark on each
/// sample, which was most of the monitor page's CPU. Equatable so parent refreshes with unchanged data skip it.
struct GlowAreaChart: View, Equatable {
    let series: [ChartSeries]
    /// Slots across the x axis; short histories stay right-aligned.
    var capacity = MonitorModel.historyCapacity
    /// Nil scales to the largest value (with headroom).
    var maxValue: Double?

    /// Faint baseline grid lines standing in for axes.
    private static let gridLines = 3
    private static let gridColor = Color.white.opacity(0.04)
    private static let lineStyle = StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round)

    var body: some View {
        Canvas { context, size in
            drawGrid(in: &context, size: size)
            let top = yMax
            for line in series where line.values.count > 1 {
                let points = AreaChartGeometry.points(values: line.values, capacity: capacity, yMax: top, in: size)
                let curve = AreaChartGeometry.monotonePath(through: points)
                let area = AreaChartGeometry.areaPath(line: curve, from: points, baseline: size.height)
                context.fill(
                    Path(area),
                    with: .linearGradient(
                        Gradient(colors: [line.tint.opacity(0.42), line.tint.opacity(0)]),
                        startPoint: .zero,
                        endPoint: CGPoint(x: 0, y: size.height)
                    )
                )
                context.stroke(Path(curve), with: .color(line.tint), style: Self.lineStyle)
            }
        }
        .accessibilityHidden(true)
    }

    /// Evenly spaced 1pt lines, the last one on the baseline (matches the old plot background).
    private func drawGrid(in context: inout GraphicsContext, size: CGSize) {
        let lines = CGFloat(Self.gridLines)
        let gap = (size.height - lines) / lines
        for index in 0..<Self.gridLines {
            let y = CGFloat(index + 1) * gap + CGFloat(index)
            context.fill(Path(CGRect(x: 0, y: y, width: size.width, height: 1)), with: .color(Self.gridColor))
        }
    }

    private var yMax: Double {
        if let maxValue { return maxValue }
        let peak = series.flatMap(\.values).max() ?? 0
        return max(peak * 1.2, 1)
    }
}

/// Glass card holding a chart with a title, a live value and an optional legend.
struct ChartCard<Chart: View, Legend: View>: View {
    let eyebrow: String
    let value: String
    var tint: Color = Theme.Palette.brandTertiary
    @ViewBuilder var legend: Legend
    @ViewBuilder var chart: Chart

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.m) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                    Text(eyebrow.uppercased())
                        .font(Theme.Typography.eyebrow)
                        .tracking(1.4)
                        .foregroundStyle(Theme.Palette.textTertiary)
                    Text(value)
                        .font(Theme.Typography.numeral(24))
                        .foregroundStyle(Theme.textGradient)
                }
                Spacer(minLength: Theme.Spacing.s)
                legend
            }
            chart.frame(height: 92)
        }
        .padding(Theme.Spacing.l)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RadialGradient(colors: [tint.opacity(0.14), .clear], center: .topTrailing, startRadius: 0, endRadius: 220)
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.l, style: .continuous))
        )
        .surface(.raised)
    }
}

/// Dot + label + value for a chart legend.
struct LegendItem: View {
    let title: String
    let value: String
    let tint: Color

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(tint).frame(width: 7, height: 7)
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Theme.Palette.textTertiary)
            Text(value)
                .font(.system(size: 11.5, weight: .semibold, design: .rounded).monospacedDigit())
                .foregroundStyle(Theme.Palette.textSecondary)
        }
    }
}

/// Glass card with a big glowing ring gauge over a title and detail lines.
struct GaugeCard: View {
    let title: String
    /// 0...1
    let fraction: Double
    let tint: Color
    let symbol: String
    let details: [(label: String, value: String)]

    var body: some View {
        VStack(spacing: Theme.Spacing.l) {
            ProgressRing(value: fraction, tint: tint, lineWidth: 10) {
                VStack(spacing: 0) {
                    Text(MonitorFormat.percent(fraction))
                        .font(Theme.Typography.numeral(28))
                        .foregroundStyle(Theme.textGradient)
                    Image(systemName: symbol)
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(tint)
                }
            }
            .frame(width: 112, height: 112)
            .padding(.top, Theme.Spacing.xs)
            VStack(spacing: Theme.Spacing.s) {
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.Palette.textPrimary)
                VStack(spacing: Theme.Spacing.xs) {
                    ForEach(details, id: \.label) { detail in
                        HStack {
                            Text(detail.label).foregroundStyle(Theme.Palette.textTertiary)
                            Spacer(minLength: Theme.Spacing.s)
                            Text(detail.value)
                                .foregroundStyle(Theme.Palette.textSecondary)
                                .monospacedDigit()
                        }
                        .font(.system(size: 11.5, weight: .medium))
                        .lineLimit(1)
                    }
                }
            }
        }
        .padding(Theme.Spacing.l + 2)
        .frame(maxWidth: .infinity)
        .background(
            RadialGradient(colors: [tint.opacity(0.22), .clear], center: .top, startRadius: 0, endRadius: 180)
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.l, style: .continuous))
        )
        .surface(.raised)
        .accessibilityElement(children: .combine)
    }
}
