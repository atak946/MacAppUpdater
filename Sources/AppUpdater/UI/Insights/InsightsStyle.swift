import AppKit
import AppUpdaterCore
import SwiftUI

/// Insights-specific helpers layered on the shared `Theme` tokens so every dashboard subview
/// (and the screens that borrow from it) speaks the same visual language.
enum InsightsStyle {
    static let accent = Theme.Palette.brand
    static let pagePadding: CGFloat = Theme.Spacing.page
    static let sectionSpacing: CGFloat = Theme.Spacing.xxl
    static let cornerRadius: CGFloat = Theme.Radius.l

    static func color(for severity: WarningSeverity) -> Color {
        switch severity {
        case .critical: Theme.Palette.danger
        case .warning: Theme.Palette.warning
        case .info: Theme.Palette.info
        }
    }

    static func symbol(for severity: WarningSeverity) -> String {
        switch severity {
        case .critical: "exclamationmark.octagon.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .info: "info.circle.fill"
        }
    }

    static func bytes(_ value: Int64?) -> String {
        value.map { $0.formatted(.byteCount(style: .file)) } ?? "—"
    }

    static func icon(for app: InstalledApp) -> NSImage {
        NSWorkspace.shared.icon(forFile: app.url.path)
    }
}

/// Section header (eyebrow + title) with an optional count shown as a glass pill.
struct InsightsSectionHeader: View {
    let eyebrow: String
    let title: String
    var trailing: String?

    var body: some View {
        SectionHeader(eyebrow: eyebrow, title: title) {
            if let trailing {
                Text(trailing)
                    .font(Theme.Typography.numeral(13))
                    .foregroundStyle(Theme.Palette.textSecondary)
                    .padding(.horizontal, Theme.Spacing.s + 2)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(Color.white.opacity(0.06)))
                    .overlay(Capsule().strokeBorder(Theme.Palette.hairline, lineWidth: 1))
            }
        }
    }
}

/// A dashboard section: header above a raised surface card holding the content.
struct InsightsCard<Content: View>: View {
    let eyebrow: String
    let title: String
    var trailing: String?
    var contentPadding: CGFloat = Theme.Spacing.l
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.m) {
            InsightsSectionHeader(eyebrow: eyebrow, title: title, trailing: trailing)
            content
                .padding(contentPadding)
                .frame(maxWidth: .infinity, alignment: .leading)
                .surface(.raised)
        }
    }
}

/// Quiet "all clear" line used inside a card when a list has nothing to show.
struct InsightsAllClear: View {
    let message: String

    var body: some View {
        HStack(spacing: Theme.Spacing.s) {
            IconTile(symbol: "checkmark", tint: Theme.Palette.success, size: 22)
            Text(message)
                .foregroundStyle(Theme.Palette.textSecondary)
        }
        .font(.system(size: 13))
        .padding(.vertical, Theme.Spacing.s)
    }
}

/// Tappable app row with icon, name and a trailing detail string.
struct InsightsAppRow: View {
    let app: InstalledApp
    let detail: String
    let onSelect: (InstalledApp) -> Void

    @State private var isHovered = false

    var body: some View {
        Button { onSelect(app) } label: {
            HStack(spacing: Theme.Spacing.m) {
                Image(nsImage: InsightsStyle.icon(for: app))
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 24, height: 24)
                    .shadow(color: .black.opacity(0.3), radius: 3, y: 1)
                Text(app.name)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Theme.Palette.textPrimary)
                    .lineLimit(1)
                Spacer(minLength: Theme.Spacing.s)
                Text(detail)
                    .font(Theme.Typography.numeral(12))
                    .foregroundStyle(Theme.Palette.textSecondary)
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Theme.Palette.textTertiary)
                    .opacity(isHovered ? 1 : 0)
                    .offset(x: isHovered ? 0 : -3)
            }
            .padding(.vertical, Theme.Spacing.s)
            .padding(.horizontal, Theme.Spacing.s)
            .contentShape(Rectangle())
            .hoverHighlight(isHovered, radius: Theme.Radius.s + 2)
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .animation(Theme.Motion.hover, value: isHovered)
    }
}
