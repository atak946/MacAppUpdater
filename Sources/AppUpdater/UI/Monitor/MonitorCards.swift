import MonitorCore
import SwiftUI

/// One glowing bar per logical core, filled from the bottom.
struct CoreBarsCard: View {
    let usage: [Double]

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.m) {
            SectionHeader(eyebrow: String(localized: "Per core"), title: String(localized: "\(usage.count) cores"))
            if usage.isEmpty {
                Text("Waiting for the first sample…")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.Palette.textTertiary)
                    .frame(maxWidth: .infinity, minHeight: 72)
            } else {
                HStack(alignment: .bottom, spacing: usage.count > 16 ? 3 : 5) {
                    ForEach(Array(usage.enumerated()), id: \.offset) { _, value in
                        bar(value)
                    }
                }
                .frame(height: 72)
            }
        }
        .padding(Theme.Spacing.l)
        .frame(maxWidth: .infinity, alignment: .leading)
        .surface(.raised)
    }

    private func bar(_ value: Double) -> some View {
        let tint = cpuTint(value)
        return ZStack(alignment: .bottom) {
            Capsule().fill(Color.white.opacity(0.06))
            Capsule()
                .fill(Theme.gradient(for: tint))
                .scaleEffect(x: 1, y: max(0.04, min(value, 1)), anchor: .bottom)
                .glow(tint, radius: 4, opacity: 0.5)
        }
        .frame(maxWidth: 14)
        .animation(Theme.Motion.content, value: value)
    }
}

/// Battery level ring with charging state, cycle count, health and time remaining.
struct BatteryCard: View {
    let battery: BatteryStats

    private var tint: Color {
        if battery.isCharging { return Theme.Palette.success }
        if battery.level < 0.2 { return Theme.Palette.danger }
        return battery.level < 0.4 ? Theme.Palette.warning : Theme.Palette.success
    }

    var body: some View {
        HStack(spacing: Theme.Spacing.l) {
            ProgressRing(value: battery.level, tint: tint, lineWidth: 8) {
                VStack(spacing: 0) {
                    Text(MonitorFormat.percent(battery.level))
                        .font(Theme.Typography.numeral(18))
                        .foregroundStyle(Theme.textGradient)
                        .contentTransition(.numericText())
                    Image(systemName: battery.isCharging ? "bolt.fill" : "battery.75percent")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(tint)
                }
            }
            .frame(width: 76, height: 76)
            VStack(alignment: .leading, spacing: Theme.Spacing.s) {
                SectionHeader(eyebrow: String(localized: "Battery"), title: state)
                HStack(spacing: Theme.Spacing.l) {
                    if let cycles = battery.cycleCount { fact(String(localized: "Cycles"), "\(cycles)") }
                    if let health = battery.health { fact(String(localized: "Health"), MonitorFormat.percent(health)) }
                    if let minutes = battery.minutesRemaining, minutes > 0 {
                        fact(battery.isCharging ? String(localized: "Until full") : String(localized: "Remaining"),
                             MonitorFormat.minutes(minutes))
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(Theme.Spacing.l)
        .frame(maxWidth: .infinity, alignment: .leading)
        .surface(.raised)
    }

    private var state: String {
        if battery.isCharging { return String(localized: "Charging") }
        return battery.isPluggedIn ? String(localized: "Plugged in") : String(localized: "On battery")
    }

    private func fact(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value)
                .font(Theme.Typography.numeral(15))
                .foregroundStyle(Theme.Palette.textPrimary)
                .contentTransition(.numericText())
            Text(label)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(Theme.Palette.textTertiary)
        }
    }
}

/// The five groups using the most CPU right now.
struct TopConsumersCard: View {
    let model: MonitorModel

    var body: some View {
        let top = model.topGroups(5)
        let peak = max(top.first?.cpuPercent ?? 0, 1)
        VStack(alignment: .leading, spacing: Theme.Spacing.m) {
            SectionHeader(eyebrow: String(localized: "Right now"), title: String(localized: "Top consumers"))
            if top.isEmpty {
                Text(model.hasProcessSample ? String(localized: "No processes reported.") : String(localized: "Reading processes…"))
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.Palette.textTertiary)
                    .frame(maxWidth: .infinity, minHeight: 60)
            } else {
                VStack(spacing: Theme.Spacing.s) {
                    ForEach(top) { group in
                        row(group, peak: peak)
                    }
                }
                .animation(Theme.Motion.content, value: top.map(\.id))
            }
        }
        .padding(Theme.Spacing.l)
        .frame(maxWidth: .infinity, alignment: .leading)
        .surface(.raised)
    }

    private func row(_ group: ProcessGroup, peak: Double) -> some View {
        HStack(spacing: Theme.Spacing.m) {
            ProcessIcon(image: model.icon(for: group), kind: group.kind, size: 24)
            Text(group.name)
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(Theme.Palette.textPrimary)
                .lineLimit(1)
                .frame(width: 150, alignment: .leading)
            UsageBar(fraction: group.cpuPercent / peak, tint: cpuTint(min(1, group.cpuPercent / 100)))
            Text(MonitorFormat.cpu(group.cpuPercent))
                .font(.system(size: 12, weight: .semibold, design: .rounded).monospacedDigit())
                .foregroundStyle(Theme.Palette.textPrimary)
                .frame(width: 56, alignment: .trailing)
                .contentTransition(.numericText())
            Text(MonitorFormat.bytes(group.memoryBytes))
                .font(.system(size: 11.5).monospacedDigit())
                .foregroundStyle(Theme.Palette.textTertiary)
                .frame(width: 72, alignment: .trailing)
                .contentTransition(.numericText())
        }
        .accessibilityElement(children: .combine)
    }
}

/// Thin glowing horizontal meter.
struct UsageBar: View {
    /// 0...1
    let fraction: Double
    let tint: Color
    var height: CGFloat = 5

    var body: some View {
        ZStack(alignment: .leading) {
            Capsule().fill(Color.white.opacity(0.07))
            Capsule()
                .fill(LinearGradient(colors: [tint.opacity(0.6), tint], startPoint: .leading, endPoint: .trailing))
                .scaleEffect(x: max(0.02, min(fraction, 1)), y: 1, anchor: .leading)
                .glow(tint, radius: 3, opacity: 0.5)
        }
        .frame(height: height)
        .animation(Theme.Motion.content, value: fraction)
        .accessibilityHidden(true)
    }
}

/// App icon when the group has a bundle, otherwise a tinted symbol tile.
struct ProcessIcon: View {
    let image: NSImage?
    let kind: ProcessKind
    var size: CGFloat = 26

    var body: some View {
        if let image {
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .frame(width: size, height: size)
                .shadow(color: .black.opacity(0.35), radius: 3, y: 1.5)
        } else {
            switch kind {
            case .critical: IconTile(symbol: "lock.shield.fill", tint: Theme.Palette.warning, size: size * 0.9)
                .frame(width: size, height: size)
            case .system: IconTile(symbol: "gearshape.2.fill", tint: Theme.Palette.info, size: size * 0.9)
                .frame(width: size, height: size)
            case .user: IconTile(symbol: "terminal.fill", tint: Theme.Palette.textTertiary, size: size * 0.9)
                .frame(width: size, height: size)
            }
        }
    }
}
