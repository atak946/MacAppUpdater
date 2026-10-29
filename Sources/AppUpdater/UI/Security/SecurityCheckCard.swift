import MaintenanceCore
import SwiftUI

/// Grid of system check cards.
struct SecurityChecksGrid: View {
    let results: [SecurityCheckResult]

    private let columns = [GridItem(.adaptive(minimum: 270), spacing: Theme.Spacing.m, alignment: .top)]

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.m) {
            SectionHeader(eyebrow: String(localized: "SYSTEM"), title: String(localized: "Protection checks"))
            LazyVGrid(columns: columns, alignment: .leading, spacing: Theme.Spacing.m) {
                ForEach(results) { SecurityCheckCard(result: $0) }
            }
        }
    }
}

/// One check: icon, title, status pill, explanation and a System Settings deep link.
struct SecurityCheckCard: View {
    let result: SecurityCheckResult

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.s) {
            HStack(spacing: Theme.Spacing.s) {
                IconTile(symbol: result.kind.symbol, tint: result.kind.tint, size: 28)
                Text(result.kind.title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.Palette.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                Spacer(minLength: Theme.Spacing.xs)
                StatusPill(title: result.statusTitle, symbol: pillSymbol, tint: result.statusTint)
            }
            Text(result.explanation)
                .font(.system(size: 12))
                .foregroundStyle(Theme.Palette.textSecondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                if let detail = detailText {
                    Text(detail)
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.Palette.textTertiary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                if let url = result.kind.settingsURL {
                    Button("Open Settings") { SecurityModel.open(url) }
                        .buttonStyle(.secondary)
                        .controlSize(.small)
                }
            }
        }
        .padding(Theme.Spacing.m)
        .frame(maxWidth: .infinity, minHeight: 124, alignment: .topLeading)
        .surface(.raised, radius: Theme.Radius.m)
    }

    private var pillSymbol: String {
        switch result.isSecure {
        case true?: "checkmark"
        case false?: "exclamationmark"
        case nil: "questionmark"
        }
    }

    /// Small fact under the explanation (XProtect version, screen lock delay).
    private var detailText: String? {
        switch result.kind {
        case .xprotect:
            guard let date = result.date else { return nil }
            let updated = date.formatted(date: .abbreviated, time: .omitted)
            return result.detail.map { String(localized: "Version \($0) · \(updated)") } ?? updated
        case .screenLock:
            guard let seconds = result.detail.flatMap(Int.init), result.status == .on else { return nil }
            return seconds == 0
                ? String(localized: "Immediately")
                : String(localized: "After \(Duration.seconds(seconds).formatted(.units(allowed: [.minutes, .seconds], width: .wide)))")
        default:
            return nil
        }
    }
}
