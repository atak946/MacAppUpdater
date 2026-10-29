import MaintenanceCore
import SwiftUI

/// Celebratory result after cleaning: reclaimed space, any failures and "Done".
struct CleanupFinishedView: View {
    let result: CleanupResult
    let onDone: () -> Void

    private var tint: Color { result.removed.isEmpty ? Theme.Palette.warning : Theme.Palette.success }

    var body: some View {
        VStack(spacing: Theme.Spacing.xl) {
            badge
            VStack(spacing: Theme.Spacing.s) {
                Text("FREED")
                    .font(Theme.Typography.eyebrow)
                    .tracking(1.6)
                    .foregroundStyle(tint)
                let parts = CleanupFormat.splitBytes(result.reclaimedBytes)
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(parts.number).font(Theme.Typography.numeral(64))
                    Text(parts.unit)
                        .font(Theme.Typography.numeral(26))
                        .foregroundStyle(Theme.Palette.textSecondary)
                }
                .foregroundStyle(Theme.textGradient)
                .glow(tint, radius: 20, opacity: 0.4)
                Text(message)
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.Palette.textSecondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
            }
            if !result.failed.isEmpty { failures }
            Button("Done", action: onDone)
                .buttonStyle(.primary)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
        }
        .padding(Theme.Spacing.xxl)
        .frame(maxWidth: .infinity)
    }

    private var badge: some View {
        ZStack {
            Circle()
                .fill(RadialGradient(colors: [tint.opacity(0.5), .clear], center: .center, startRadius: 0, endRadius: 80))
                .frame(width: 160, height: 160)
                .blur(radius: 10)
            Circle()
                .fill(Theme.Palette.glass)
                .overlay(Circle().fill(tint.opacity(0.16)))
                .overlay(Circle().strokeBorder(LinearGradient(colors: [.white.opacity(0.4), .white.opacity(0.03)], startPoint: .top, endPoint: .bottom), lineWidth: 1))
                .frame(width: 92, height: 92)
            Image(systemName: result.removed.isEmpty ? "exclamationmark.triangle.fill" : "checkmark.seal.fill")
                .font(.system(size: 38, weight: .semibold))
                .foregroundStyle(LinearGradient(colors: [.white, tint], startPoint: .top, endPoint: .bottom))
                .glow(tint, radius: 12, opacity: 0.8)
        }
        .accessibilityHidden(true)
    }

    private var message: String {
        let removed = result.removed.count
        if result.failed.isEmpty {
            return String(localized: "\(removed) items moved to the Trash. Empty the Trash to reclaim the space for good.")
        }
        return String(localized: "\(removed) items moved to the Trash, \(result.failed.count) couldn't be removed.")
    }

    // MARK: Failures

    private static let failureLimit = 8

    private var failures: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionHeader(eyebrow: String(localized: "Not removed"), title: String(localized: "\(result.failed.count) items"))
                .padding(.bottom, Theme.Spacing.s)
            ForEach(Array(result.failed.prefix(Self.failureLimit).enumerated()), id: \.offset) { index, failure in
                if index > 0 { GlassDivider() }
                HStack(spacing: Theme.Spacing.m) {
                    IconTile(symbol: failure.item.category.symbol, tint: failure.item.category.tint, size: 22)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(failure.item.displayName)
                            .font(.system(size: 12.5, weight: .medium))
                            .foregroundStyle(Theme.Palette.textPrimary)
                            .lineLimit(1)
                        Text(failure.reason)
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.Palette.textTertiary)
                            .lineLimit(2)
                    }
                    Spacer(minLength: Theme.Spacing.m)
                    Text(CleanupFormat.bytes(failure.item.sizeInBytes))
                        .font(.system(size: 12, weight: .semibold).monospacedDigit())
                        .foregroundStyle(Theme.Palette.textSecondary)
                }
                .padding(.vertical, Theme.Spacing.s)
            }
            if result.failed.count > Self.failureLimit {
                Text("and \(result.failed.count - Self.failureLimit) more")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.Palette.textTertiary)
                    .padding(.top, Theme.Spacing.xs)
            }
        }
        .padding(Theme.Spacing.l)
        .frame(maxWidth: 520)
        .surface(.raised)
    }
}
