import AppUpdaterCore
import SwiftUI

/// The app's "Check-up" home: a borderless health hero, key stats and previews of pending and recent updates.
struct OverviewView: View {
    let viewModel: UpdatesViewModel
    let formulaeModel: FormulaeModel
    /// Switches the sidebar selection.
    let onNavigate: (SidebarItem) -> Void
    /// Opens the detail sheet for a history entry's app.
    let onSelectHistory: (UpdateHistoryEntry) -> Void

    @State private var hasAppeared = false

    var body: some View {
        ScrollView {
            VStack(spacing: Theme.Spacing.xl) {
                // Sized by its content so the stats and cards stay above the fold.
                OverviewHero(viewModel: viewModel, health: health)
                    .padding(.vertical, Theme.Spacing.s)
                    .overviewEntrance(order: 0, isVisible: hasAppeared)
                OverviewStatsRow(
                    viewModel: viewModel, formulaeModel: formulaeModel, health: health, onNavigate: onNavigate
                )
                .overviewEntrance(order: 1, isVisible: hasAppeared)
                cards
                    .overviewEntrance(order: 2, isVisible: hasAppeared)
            }
            .padding(.horizontal, Theme.Spacing.page)
            .padding(.bottom, Theme.Spacing.page)
            .frame(maxWidth: Theme.Spacing.contentWidth)
            .frame(maxWidth: .infinity)
            .animation(Theme.Motion.content, value: health)
        }
        .scrollIndicators(.automatic)
        .pageBackground()
        .onAppear { hasAppeared = true }
        .task(id: viewModel.installedApps.count) { if viewModel.insights == nil { await viewModel.refreshInsights() } }
    }

    // MARK: Cards

    /// Side by side on wide windows, stacked otherwise.
    private var cards: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: Theme.Spacing.l) {
                readyCard.frame(minWidth: 460)
                recentCard.frame(minWidth: 300, maxWidth: 380)
            }
            VStack(spacing: Theme.Spacing.l) {
                readyCard
                recentCard
            }
        }
    }

    private var readyCard: some View {
        OverviewReadyCard(viewModel: viewModel) { onNavigate(.updates) }
    }

    private var recentCard: some View {
        OverviewRecentCard(viewModel: viewModel, onSeeAll: { onNavigate(.history) }, onSelect: onSelectHistory)
    }

    // MARK: Health

    private var health: OverviewHealth {
        OverviewHealth(
            pendingUpdates: viewModel.pendingUpdates.count,
            warnings: viewModel.insights?.totalWarnings ?? 0,
            untrackedApps: viewModel.coverageReport?.untracked.count ?? 0
        )
    }
}

// MARK: - Entrance

/// Staggered fade + rise for Overview sections; a plain fade when Reduce Motion is on.
private struct OverviewEntrance: ViewModifier {
    let order: Int
    let isVisible: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let stagger = 0.08
    private static let rise: CGFloat = 18

    func body(content: Content) -> some View {
        content
            .opacity(isVisible ? 1 : 0)
            .offset(y: isVisible || reduceMotion ? 0 : Self.rise)
            .animation(
                reduceMotion
                    ? .easeOut(duration: 0.2)
                    : Theme.Motion.content.delay(Double(order) * Self.stagger),
                value: isVisible
            )
    }
}

private extension View {
    func overviewEntrance(order: Int, isVisible: Bool) -> some View {
        modifier(OverviewEntrance(order: order, isVisible: isVisible))
    }
}
