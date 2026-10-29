import Charts
import SwiftUI

/// One line of an area chart.
struct ChartSeries: Identifiable {
    let id: String
    let values: [Double]
    let tint: Color
}

/// Axis-free area chart: gradient fill fading to nothing under a glowing line, newest sample on the right.
struct GlowAreaChart: View {
    let series: [ChartSeries]
    /// Slots across the x axis; short histories stay right-aligned.
    var capacity = MonitorModel.historyCapacity
    /// Nil scales to the largest value (with headroom).
    var maxValue: Double?

    var body: some View {
        Chart {
            ForEach(series) { line in
                let offset = capacity - line.values.count
                ForEach(Array(line.values.enumerated()), id: \.offset) { index, value in
                    AreaMark(
                        x: .value("Time", offset + index),
                        y: .value("Value", value),
                        series: .value("Series", line.id),
                        stacking: .unstacked
                    )
                    .foregroundStyle(
                        LinearGradient(colors: [line.tint.opacity(0.42), line.tint.opacity(0)], startPoint: .top, endPoint: .bottom)
                    )
                    .interpolationMethod(.monotone)
                    LineMark(
                        x: .value("Time", offset + index),
                        y: .value("Value", value),
                        series: .value("Series", line.id)
                    )
                    .foregroundStyle(line.tint)
                    .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                    .interpolationMethod(.monotone)
                }
            }
        }
        .chartXScale(domain: 0...max(1, capacity - 1))
        .chartYScale(domain: 0...yMax)
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .chartLegend(.hidden)
        .chartPlotStyle { plot in
            plot.background(
                // Faint baseline grid instead of axes.
                VStack(spacing: 0) {
                    ForEach(0..<3, id: \.self) { _ in
                        Spacer()
                        Rectangle().fill(Color.white.opacity(0.04)).frame(height: 1)
                    }
                }
            )
        }
        .shadow(color: (series.first?.tint ?? .clear).opacity(0.45), radius: 6)
        .accessibilityHidden(true)
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
                        .contentTransition(.numericText())
                        .animation(Theme.Motion.content, value: value)
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
            Circle().fill(tint).frame(width: 7, height: 7).glow(tint, radius: 4, opacity: 0.8)
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Theme.Palette.textTertiary)
            Text(value)
                .font(.system(size: 11.5, weight: .semibold, design: .rounded).monospacedDigit())
                .foregroundStyle(Theme.Palette.textSecondary)
                .contentTransition(.numericText())
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
                        .contentTransition(.numericText())
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
                                .contentTransition(.numericText())
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
        .animation(Theme.Motion.content, value: fraction)
        .accessibilityElement(children: .combine)
    }
}
