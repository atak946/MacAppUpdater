import MaintenanceCore
import SwiftUI

/// Borderless hero for the start, scanning and cleaning states: a large orb beside the headline and action.
/// Orb left + copy right on wide windows, stacked and centered otherwise.
struct CleanupScanHero: View {
    enum Phase: Equatable {
        case idle
        case scanning(progress: Double, category: CleanupCategory?)
        case cleaning
    }

    let phase: Phase
    let onScan: () -> Void
    let onCancel: () -> Void

    private static let orbDiameter: CGFloat = 200
    private static let copyMaxWidth: CGFloat = 440

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: Theme.Spacing.xxxl) {
                orb
                VStack(alignment: .leading, spacing: Theme.Spacing.xl) {
                    copy(alignment: .leading)
                    actions
                    chips
                }
                .frame(width: Self.copyMaxWidth, alignment: .leading)
            }
            VStack(alignment: .center, spacing: Theme.Spacing.xl) {
                orb
                copy(alignment: .center)
                actions
                chips
            }
            .frame(maxWidth: Self.copyMaxWidth)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: Orb

    private var isActive: Bool { phase != .idle }

    private var progress: Double {
        if case .scanning(let progress, _) = phase { return progress }
        return 1
    }

    private var orb: some View {
        ScanOrb(tint: Theme.Palette.brandSecondary, isActive: isActive, diameter: Self.orbDiameter, progress: progress) {
            switch phase {
            case .idle:
                Image(systemName: "sparkles")
                    .font(.system(size: 60, weight: .semibold))
                    .foregroundStyle(LinearGradient(colors: [.white, Theme.Palette.brandSecondary], startPoint: .top, endPoint: .bottom))
                    .glow(Theme.Palette.brandSecondary, radius: 18, opacity: 0.6)
            case .scanning(let progress, _):
                HStack(alignment: .firstTextBaseline, spacing: 2) {
                    Text("\(Int((progress * 100).rounded()))")
                        .font(Theme.Typography.numeral(56))
                        .contentTransition(.numericText())
                    Text(verbatim: "%")
                        .font(Theme.Typography.numeral(22))
                        .foregroundStyle(Theme.Palette.textSecondary)
                }
                .foregroundStyle(Theme.textGradient)
                .glow(Theme.Palette.brandSecondary, radius: 18, opacity: 0.45)
                .animation(Theme.Motion.content, value: progress)
            case .cleaning:
                Image(systemName: "trash.fill")
                    .font(.system(size: 50, weight: .semibold))
                    .foregroundStyle(Theme.textGradient)
                    .glow(Theme.Palette.brandSecondary, radius: 18, opacity: 0.6)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(headline))
    }

    // MARK: Copy

    private func copy(alignment: HorizontalAlignment) -> some View {
        let textAlignment: TextAlignment = alignment == .center ? .center : .leading
        return VStack(alignment: alignment, spacing: Theme.Spacing.s) {
            Text("CLEANUP")
                .font(Theme.Typography.eyebrow)
                .tracking(1.6)
                .foregroundStyle(Theme.brandGradient)
            Text(headline)
                .font(Theme.Typography.hero)
                .tracking(Theme.Typography.displayTracking)
                .foregroundStyle(Theme.textGradient)
                .multilineTextAlignment(textAlignment)
                .lineLimit(2)
                .minimumScaleFactor(0.75)
                .fixedSize(horizontal: false, vertical: true)
                .contentTransition(.opacity)
            Text(detail)
                .font(.system(size: 14))
                .foregroundStyle(Theme.Palette.textSecondary)
                .multilineTextAlignment(textAlignment)
                .lineLimit(2)
                .contentTransition(.opacity)
        }
    }

    private var headline: String {
        switch phase {
        case .idle: String(localized: "Free up space")
        case .scanning: String(localized: "Scanning…")
        case .cleaning: String(localized: "Moving to the Trash…")
        }
    }

    private var detail: String {
        switch phase {
        case .idle:
            String(localized: "Find caches, logs and developer leftovers you can safely remove.")
        case .scanning(_, let category):
            category.map { String(localized: "Looking through \($0.title)") } ?? String(localized: "Preparing scan")
        case .cleaning:
            String(localized: "Selected items go to the Trash so you can still restore them.")
        }
    }

    // MARK: Actions

    @ViewBuilder
    private var actions: some View {
        switch phase {
        case .idle:
            Button(action: onScan) {
                Label("Scan", systemImage: "sparkle.magnifyingglass")
            }
            .buttonStyle(.primary)
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)
        case .scanning:
            Button("Cancel", action: onCancel)
                .buttonStyle(.secondary)
                .controlSize(.large)
                .keyboardShortcut(.cancelAction)
        case .cleaning:
            EmptyView()
        }
    }

    /// What a scan looks at; shown only before the first scan.
    @ViewBuilder
    private var chips: some View {
        if phase == .idle {
            CleanupChipFlow(categories: CleanupCategory.allCases)
            CleanupAccessNotice()
        }
    }
}

// MARK: - Chips

/// Small glass chips naming the scanned categories, wrapped onto as many rows as needed.
struct CleanupChipFlow: View {
    let categories: [CleanupCategory]

    var body: some View {
        CleanupFlowLayout(spacing: 6) {
            ForEach(categories, id: \.self) { category in
                HStack(spacing: 5) {
                    Image(systemName: category.symbol)
                        .font(.system(size: 9.5, weight: .bold))
                        .foregroundStyle(category.tint)
                    Text(category.title)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Theme.Palette.textSecondary)
                }
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .background(Capsule().fill(Color.white.opacity(0.05)))
                .overlay(Capsule().strokeBorder(Theme.Palette.hairline, lineWidth: 1))
            }
        }
    }
}

/// Left-aligned wrapping layout for chips.
struct CleanupFlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(subviews, width: proposal.width ?? .infinity)
        let width = rows.map(\.width).max() ?? 0
        let height = rows.map(\.height).reduce(0, +) + spacing * CGFloat(max(rows.count - 1, 0))
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(subviews, width: bounds.width) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func arrange(_ subviews: Subviews, width: CGFloat) -> [Row] {
        var rows: [Row] = []
        var current = Row()
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let needed = current.indices.isEmpty ? size.width : current.width + spacing + size.width
            if needed > width, !current.indices.isEmpty {
                rows.append(current)
                current = Row()
            }
            current.width = current.indices.isEmpty ? size.width : current.width + spacing + size.width
            current.height = max(current.height, size.height)
            current.indices.append(index)
        }
        if !current.indices.isEmpty { rows.append(current) }
        return rows
    }
}
