import MonitorCore
import SwiftUI

/// Live system dashboard: CPU, memory and disk gauges, CPU and network charts, cores, battery and top consumers.
struct SystemMonitorView: View {
    let model: MonitorModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.l) {
                PageHeader(title: String(localized: "System"), subtitle: subtitle) {
                    pills
                }
                .padding(.bottom, Theme.Spacing.xs)
                gauges
                charts
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: Theme.Spacing.l) {
                        TopConsumersCard(model: model).frame(minWidth: 480)
                        sideColumn.frame(minWidth: 280, maxWidth: 360)
                    }
                    VStack(spacing: Theme.Spacing.l) {
                        TopConsumersCard(model: model)
                        sideColumn
                    }
                }
            }
            .padding(.horizontal, Theme.Spacing.page)
            .padding(.bottom, Theme.Spacing.page)
            .frame(maxWidth: Theme.Spacing.contentWidth)
            .frame(maxWidth: .infinity)
        }
        .scrollIndicators(.automatic)
        .pageBackground()
        .monitorObservation(model, demand: .processes)
    }

    private var snapshot: SystemSnapshot? { model.snapshot }

    // MARK: Header

    private var subtitle: String {
        guard let snapshot else { return String(localized: "Reading sensors…") }
        let memory = snapshot.memory
        return String(localized: "\(MonitorFormat.bytes(memory.totalBytes)) memory · \(snapshot.perCoreUsage.count) cores")
    }

    private var pills: some View {
        HStack(spacing: Theme.Spacing.s) {
            StatusPill(title: String(localized: "Live"), symbol: "circle.fill", tint: Theme.Palette.success)
                .symbolEffect(.pulse, options: .repeating, isActive: model.isSampling)
            if let snapshot {
                StatusPill(title: snapshot.thermal.title, symbol: "thermometer.medium", tint: snapshot.thermal.tint)
                StatusPill(
                    title: String(localized: "Up \(MonitorFormat.duration(snapshot.uptime))"),
                    symbol: "clock", tint: Theme.Palette.textSecondary
                )
            }
        }
    }

    // MARK: Gauges

    private var gauges: some View {
        HStack(alignment: .top, spacing: Theme.Spacing.l) {
            GaugeCard(
                title: String(localized: "CPU"),
                fraction: snapshot?.cpuUsage ?? 0,
                tint: cpuTint(snapshot?.cpuUsage ?? 0),
                symbol: "cpu",
                details: [
                    (String(localized: "Peak"), MonitorFormat.percent(model.cpuHistory.peak)),
                    (String(localized: "Processes"), "\(model.processList.count)"),
                ]
            )
            memoryGauge
            diskGauge
        }
    }

    private var memoryGauge: some View {
        let memory = snapshot?.memory
        return GaugeCard(
            title: String(localized: "Memory"),
            fraction: memory.map(MonitorModel.usedFraction) ?? 0,
            tint: memory?.pressure.tint ?? Theme.Palette.brand,
            symbol: "memorychip",
            details: [
                (String(localized: "Used"), memory.map { MonitorFormat.bytes($0.usedBytes) } ?? "—"),
                (String(localized: "Compressed"), memory.map { MonitorFormat.bytes($0.compressedBytes) } ?? "—"),
                (String(localized: "Swap"), memory.map { MonitorFormat.bytes($0.swapUsedBytes) } ?? "—"),
                (String(localized: "Pressure"), memory?.pressure.title ?? "—"),
            ]
        )
    }

    private var diskGauge: some View {
        let disk = snapshot?.disk
        let fraction: Double = {
            guard let disk, disk.totalBytes > 0 else { return 0 }
            return Double(disk.totalBytes - disk.availableBytes) / Double(disk.totalBytes)
        }()
        let tint = fraction > 0.9 ? Theme.Palette.danger : fraction > 0.8 ? Theme.Palette.warning : Theme.Palette.brandSecondary
        return GaugeCard(
            title: String(localized: "Disk"),
            fraction: fraction,
            tint: tint,
            symbol: "internaldrive",
            details: [
                (String(localized: "Available"), disk.map { MonitorFormat.diskBytes($0.availableBytes) } ?? "—"),
                (String(localized: "Capacity"), disk.map { MonitorFormat.diskBytes($0.totalBytes) } ?? "—"),
            ]
        )
    }

    // MARK: Charts

    private var charts: some View {
        HStack(alignment: .top, spacing: Theme.Spacing.l) {
            ChartCard(
                eyebrow: String(localized: "CPU load"),
                value: MonitorFormat.percent(snapshot?.cpuUsage ?? 0),
                tint: Theme.Palette.brandTertiary
            ) {
                LegendItem(
                    title: String(localized: "Memory"),
                    value: MonitorFormat.percent(model.memoryHistory.latest ?? 0),
                    tint: Theme.Palette.brand
                )
            } chart: {
                GlowAreaChart(
                    series: [
                        ChartSeries(id: "cpu", values: model.cpuHistory.values, tint: Theme.Palette.brandTertiary),
                        ChartSeries(id: "memory", values: model.memoryHistory.values, tint: Theme.Palette.brand),
                    ],
                    maxValue: 1
                )
            }
            ChartCard(
                eyebrow: String(localized: "Network"),
                value: MonitorFormat.rate((snapshot?.network.bytesInPerSecond ?? 0) + (snapshot?.network.bytesOutPerSecond ?? 0)),
                tint: Theme.Palette.brandSecondary
            ) {
                VStack(alignment: .trailing, spacing: 3) {
                    LegendItem(title: String(localized: "In"), value: MonitorFormat.rate(snapshot?.network.bytesInPerSecond ?? 0),
                               tint: Theme.Palette.brandTertiary)
                    LegendItem(title: String(localized: "Out"), value: MonitorFormat.rate(snapshot?.network.bytesOutPerSecond ?? 0),
                               tint: Theme.Palette.brandSecondary)
                }
            } chart: {
                GlowAreaChart(series: [
                    ChartSeries(id: "in", values: model.networkInHistory.values, tint: Theme.Palette.brandTertiary),
                    ChartSeries(id: "out", values: model.networkOutHistory.values, tint: Theme.Palette.brandSecondary),
                ])
            }
        }
    }

    // MARK: Side column

    private var sideColumn: some View {
        VStack(spacing: Theme.Spacing.l) {
            CoreBarsCard(usage: snapshot?.perCoreUsage ?? [])
            if let battery = snapshot?.battery {
                BatteryCard(battery: battery)
                    .transition(.opacity)
            }
        }
    }
}
