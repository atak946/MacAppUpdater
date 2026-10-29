import SwiftUI

/// Compact live CPU / memory / network strip at the top of the menu bar popover.
struct MenuBarMonitorStrip: View {
    let model: MonitorModel

    var body: some View {
        let snapshot = model.snapshot
        HStack(spacing: 0) {
            metric(
                title: String(localized: "CPU"),
                value: MonitorFormat.percent(snapshot?.cpuUsage ?? 0),
                history: model.cpuHistory.values,
                tint: cpuTint(snapshot?.cpuUsage ?? 0),
                maxValue: 1
            )
            separator
            metric(
                title: String(localized: "Memory"),
                value: MonitorFormat.percent(model.memoryHistory.latest ?? 0),
                history: model.memoryHistory.values,
                tint: snapshot?.memory.pressure.tint ?? Theme.Palette.brand,
                maxValue: 1
            )
            separator
            network(inRate: snapshot?.network.bytesInPerSecond ?? 0, outRate: snapshot?.network.bytesOutPerSecond ?? 0)
        }
        .padding(.vertical, Theme.Spacing.s + 2)
        .padding(.horizontal, Theme.Spacing.m)
        .frame(maxWidth: .infinity)
        .surface(.raised, radius: Theme.Radius.l)
        .monitorObservation(model, demand: .system)
    }

    private var separator: some View {
        Rectangle().fill(Theme.Palette.hairline).frame(width: 1, height: 30)
            .padding(.horizontal, Theme.Spacing.s)
    }

    private func metric(title: String, value: String, history: [Double], tint: Color, maxValue: Double) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text(title.uppercased())
                    .font(.system(size: 9, weight: .bold))
                    .tracking(1)
                    .foregroundStyle(Theme.Palette.textTertiary)
                Text(value)
                    .font(Theme.Typography.numeral(13))
                    .foregroundStyle(Theme.Palette.textPrimary)
            }
            GlowAreaChart(series: [ChartSeries(id: title, values: Array(history.suffix(40)), tint: tint)],
                          capacity: 40, maxValue: maxValue)
                .frame(height: 16)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private func network(inRate: Double, outRate: Double) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            rate(symbol: "arrow.down", value: inRate, tint: Theme.Palette.brandTertiary)
            rate(symbol: "arrow.up", value: outRate, tint: Theme.Palette.brandSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("Network"))
    }

    private func rate(symbol: String, value: Double, tint: Color) -> some View {
        HStack(spacing: 4) {
            Image(systemName: symbol)
                .font(.system(size: 9, weight: .heavy))
                .foregroundStyle(tint)
            Text(MonitorFormat.rate(value))
                .font(.system(size: 11.5, weight: .semibold, design: .rounded).monospacedDigit())
                .foregroundStyle(Theme.Palette.textSecondary)
                .lineLimit(1)
        }
    }
}
