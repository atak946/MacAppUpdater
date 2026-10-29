import AppUpdaterCore
import Charts
import SwiftUI

/// Horizontal bar chart of the largest bundles: glowing brand-gradient capsule bars on white-alpha
/// grid lines, direct value labels. The leader carries full intensity; the rest fade slightly.
struct LargestAppsChart: View {
    let apps: [AppInsight]
    let onSelectApp: (InstalledApp) -> Void

    private static let rowHeight: CGFloat = 34
    private static let axisHeight: CGFloat = 22

    var body: some View {
        Chart(apps) { insight in
            BarMark(
                x: .value("Size", Double(insight.sizeInBytes ?? 0)),
                y: .value("App", insight.app.name),
                height: .fixed(14)
            )
            .foregroundStyle(
                LinearGradient(
                    colors: [Theme.Palette.brand, Theme.Palette.brandSecondary],
                    startPoint: .leading,
                    endPoint: .trailing
                )
            )
            .opacity(insight.id == apps.first?.id ? 1 : 0.7)
            .clipShape(Capsule())
            .annotation(position: .trailing, alignment: .leading, spacing: 8) {
                Text(InsightsStyle.bytes(insight.sizeInBytes))
                    .font(Theme.Typography.numeral(11.5))
                    .foregroundStyle(insight.id == apps.first?.id ? Theme.Palette.textPrimary : Theme.Palette.textSecondary)
            }
        }
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 4)) { value in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 1, dash: [2, 4]))
                    .foregroundStyle(Color.white.opacity(0.08))
                AxisValueLabel {
                    if let bytes = value.as(Double.self) {
                        Text(Int64(bytes).formatted(.byteCount(style: .file)))
                            .font(.system(size: 10, weight: .medium).monospacedDigit())
                            .foregroundStyle(Theme.Palette.textTertiary)
                    }
                }
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading) { _ in
                AxisValueLabel()
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(Theme.Palette.textSecondary)
            }
        }
        .chartXScale(domain: 0...(maxSize * 1.2))
        .chartOverlay { proxy in tapOverlay(proxy) }
        .shadow(color: Theme.Palette.brand.opacity(0.45), radius: 10)
        .frame(height: CGFloat(max(apps.count, 1)) * Self.rowHeight + Self.axisHeight)
        .accessibilityLabel("Largest apps by size")
    }

    private var maxSize: Double {
        Double(apps.compactMap(\.sizeInBytes).max() ?? 1)
    }

    private func tapOverlay(_ proxy: ChartProxy) -> some View {
        Rectangle()
            .fill(.clear)
            .contentShape(Rectangle())
            .onTapGesture { location in
                guard let name: String = proxy.value(atY: location.y),
                      let match = apps.first(where: { $0.app.name == name }) else { return }
                onSelectApp(match.app)
            }
    }
}
