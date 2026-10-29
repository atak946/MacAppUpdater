import MonitorCore
import SwiftUI

/// The apps that used the most CPU over the last hour, 6 hours or day, with a warning row for sustained hogs.
/// Redraws only when a minute is recorded or the window changes.
struct UsageHistoryCard: View {
    let model: UsageHistoryModel

    @State private var window: UsageWindow = .day

    var body: some View {
        let apps = model.topApps(window)
        let hogs = model.sustainedHogs(window)
        let peak = max(apps.first?.averageCPUPercent ?? 0, 1)
        VStack(alignment: .leading, spacing: Theme.Spacing.m) {
            SectionHeader(eyebrow: String(localized: "History"), title: window.heading) {
                windowPicker
            }
            ForEach(hogs.prefix(2)) { hog in
                hogRow(hog)
            }
            if apps.isEmpty {
                Text(emptyMessage)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.Palette.textTertiary)
                    .frame(maxWidth: .infinity, minHeight: 60)
            } else {
                VStack(spacing: Theme.Spacing.s) {
                    ForEach(apps) { app in
                        row(app, peak: peak)
                    }
                }
            }
        }
        .padding(Theme.Spacing.l)
        .frame(maxWidth: .infinity, alignment: .leading)
        .surface(.raised)
    }

    private var emptyMessage: String {
        model.isRecording
            ? String(localized: "Recording… the first entries appear after a couple of minutes.")
            : String(localized: "Usage history recording is off.")
    }

    private var windowPicker: some View {
        Picker(String(localized: "Time range"), selection: $window) {
            ForEach(UsageWindow.allCases) { option in
                Text(option.title).tag(option)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .controlSize(.small)
        .fixedSize()
    }

    private func hogRow(_ hog: SustainedHog) -> some View {
        HStack(spacing: Theme.Spacing.s) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(Theme.Palette.warning)
            Text(String(localized: "\(hog.name) averaged \(MonitorFormat.cpu(hog.averageCPUPercent)) CPU for \(MonitorFormat.duration(hog.duration))"))
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.Palette.textPrimary)
                .lineLimit(1)
            Spacer(minLength: Theme.Spacing.s)
            // A static string: `Text(_:style: .relative)` would redraw every second.
            Text(hog.endedAt.formatted(.relative(presentation: .named)))
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(Theme.Palette.textTertiary)
        }
        .padding(.horizontal, Theme.Spacing.m)
        .padding(.vertical, Theme.Spacing.s)
        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.Palette.warning.opacity(0.12)))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.Palette.warning.opacity(0.28), lineWidth: 0.5))
        .accessibilityElement(children: .combine)
    }

    private func row(_ app: AppUsageSummary, peak: Double) -> some View {
        HStack(spacing: Theme.Spacing.m) {
            ProcessIcon(image: model.icon(forBundlePath: app.bundlePath), kind: .user, size: 24)
            Text(app.name)
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(Theme.Palette.textPrimary)
                .lineLimit(1)
                .frame(width: 150, alignment: .leading)
            UsageBar(fraction: app.averageCPUPercent / peak, tint: cpuTint(min(1, app.averageCPUPercent / 100)))
            Text(MonitorFormat.cpu(app.averageCPUPercent))
                .font(.system(size: 12, weight: .semibold, design: .rounded).monospacedDigit())
                .foregroundStyle(Theme.Palette.textPrimary)
                .frame(width: 56, alignment: .trailing)
                .help(String(localized: "Average CPU"))
            Text(MonitorFormat.bytes(app.peakMemoryBytes))
                .font(.system(size: 11.5).monospacedDigit())
                .foregroundStyle(Theme.Palette.textTertiary)
                .frame(width: 72, alignment: .trailing)
                .help(String(localized: "Peak memory"))
        }
        .accessibilityElement(children: .combine)
    }
}

extension UsageWindow {
    var title: String {
        switch self {
        case .hour: String(localized: "1h")
        case .sixHours: String(localized: "6h")
        case .day: String(localized: "24h")
        }
    }

    var heading: String {
        switch self {
        case .hour: String(localized: "Last hour")
        case .sixHours: String(localized: "Last 6 hours")
        case .day: String(localized: "Last 24 hours")
        }
    }
}
