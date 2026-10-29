import SwiftUI

/// Row of clickable stat tiles, each jumping to the matching sidebar destination.
struct OverviewStatsRow: View {
    let viewModel: UpdatesViewModel
    let formulaeModel: FormulaeModel
    let health: OverviewHealth
    let onNavigate: (SidebarItem) -> Void

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: Theme.Spacing.m) { tiles }
                .frame(minWidth: 640)
            Grid(horizontalSpacing: Theme.Spacing.m, verticalSpacing: Theme.Spacing.m) {
                GridRow { updatesTile; appsTile }
                GridRow { warningsTile; toolsTile }
            }
        }
    }

    @ViewBuilder
    private var tiles: some View {
        updatesTile
        appsTile
        warningsTile
        toolsTile
    }

    // MARK: Tiles

    private var updatesTile: some View {
        StatTile(
            value: "\(health.pendingUpdates)",
            label: String(localized: "Updates"),
            symbol: SidebarItem.updates.symbol,
            tint: SidebarItem.updates.tint
        ) { onNavigate(.updates) }
    }

    private var appsTile: some View {
        StatTile(
            value: "\(viewModel.installedApps.count)",
            label: String(localized: "Apps installed"),
            symbol: SidebarItem.allApps.symbol,
            tint: SidebarItem.allApps.tint
        ) { onNavigate(.allApps) }
    }

    private var warningsTile: some View {
        StatTile(
            value: viewModel.insights == nil ? "–" : "\(health.warnings)",
            label: String(localized: "Warnings"),
            symbol: "exclamationmark.triangle.fill",
            tint: health.warnings > 0 ? Theme.Palette.warning : SidebarItem.insights.tint
        ) { onNavigate(.insights) }
    }

    private var toolsTile: some View {
        StatTile(
            value: "\(formulaeModel.upgradable.count)",
            label: String(localized: "Tools upgradable"),
            symbol: SidebarItem.commandLineTools.symbol,
            tint: SidebarItem.commandLineTools.tint
        ) { onNavigate(.commandLineTools) }
    }
}
