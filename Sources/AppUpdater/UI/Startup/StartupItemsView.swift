import MaintenanceCore
import SwiftUI

/// Startup Items: launchd agents and daemons with their owner, signature and enabled state.
struct StartupItemsView: View {
    let model: StartupModel
    /// The sidebar search field.
    let searchText: String

    @State private var filter: StartupFilter = .all
    @State private var sort: StartupSort = .name

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xl) {
            PageHeader(title: String(localized: "Startup Items"), subtitle: subtitle) {
                headerActions
            }
            statsRow
            StartupFilterCapsule(selection: $filter, count: { count(for: $0) })
            if let message = model.actionError {
                errorBanner(message)
                    .transition(.opacity)
            }
            listCard
            StartupLoginItemsCard(model: model)
        }
        .padding(Theme.Spacing.page)
        .frame(maxWidth: Theme.Spacing.contentWidth)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .pageBackground()
        .animation(Theme.Motion.hover, value: model.actionError)
        .task { await model.loadIfNeeded() }
    }

    // MARK: Header

    private var subtitle: String {
        String(localized: "Programs launchd starts at login, on a schedule or in the background.")
    }

    private var headerActions: some View {
        HStack(spacing: Theme.Spacing.s) {
            HStack(spacing: 6) {
                Text("Show Apple items")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.Palette.textSecondary)
                GlassToggle(isOn: model.showsAppleItems) { model.showsAppleItems = $0 }
            }
            .help(String(localized: "Apple's own jobs are listed read-only."))
            sortMenu
            Button {
                Task { await model.refresh() }
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.secondary)
            .disabled(model.isLoading)
        }
    }

    private var sortMenu: some View {
        Menu {
            Picker("Sort by", selection: $sort) {
                ForEach(StartupSort.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.inline)
        } label: {
            Label(sort.title, systemImage: "arrow.up.arrow.down")
        }
        .menuStyle(.button)
        .buttonStyle(.secondary)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Sort by")
    }

    private var statsRow: some View {
        let items = model.visibleItems
        return HStack(spacing: Theme.Spacing.m) {
            StatTile(
                value: "\(items.filter(\.isEnabled).count)", label: String(localized: "Enabled"),
                symbol: "power", tint: Theme.Palette.success
            ) { filter = .all }
            StatTile(
                value: "\(items.count)", label: String(localized: "Total items"),
                symbol: "list.bullet", tint: Theme.Palette.brand
            )
            StatTile(
                value: "\(items.filter(\.isUnsigned).count)", label: String(localized: "Unsigned"),
                symbol: "exclamationmark.shield.fill", tint: Theme.Palette.danger
            ) { filter = .unsigned }
        }
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(spacing: Theme.Spacing.m) {
            IconTile(symbol: "exclamationmark.triangle.fill", tint: Theme.Palette.danger, size: 24)
            Text(message)
                .font(.system(size: 12.5))
                .foregroundStyle(Theme.Palette.textPrimary)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button("Dismiss") { model.actionError = nil }
                .buttonStyle(.secondary)
                .controlSize(.small)
        }
        .padding(Theme.Spacing.m)
        .surface(.raised, radius: Theme.Radius.m)
    }

    // MARK: List

    @ViewBuilder
    private var listCard: some View {
        VStack(spacing: 0) {
            StartupColumnHeader()
            GlassDivider()
            listContent
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .surface(.raised)
    }

    @ViewBuilder
    private var listContent: some View {
        if model.isLoading && model.items.isEmpty {
            EmptyStateView(symbol: nil, title: String(localized: "Reading startup items…"))
        } else if visibleItems.isEmpty {
            EmptyStateView(
                symbol: "line.3.horizontal.decrease.circle",
                title: String(localized: "No startup items match"),
                message: String(localized: "Try another filter or search term.")
            )
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(visibleItems.enumerated()), id: \.element.id) { index, item in
                        if index > 0 {
                            GlassDivider(leadingInset: StartupListMetrics.dividerInset)
                                .padding(.trailing, Theme.Spacing.m)
                        }
                        row(for: item)
                    }
                }
                .padding(.vertical, Theme.Spacing.xs)
            }
        }
    }

    private func row(for item: StartupItem) -> some View {
        StartupItemRow(
            item: item,
            icon: model.icon(for: item),
            isPending: model.isPending(item),
            onToggle: { enabled in Task { await model.setEnabled(enabled, for: item) } },
            onReveal: { model.revealInFinder(item) }
        )
        .contextMenu { menu(for: item) }
    }

    @ViewBuilder
    private func menu(for item: StartupItem) -> some View {
        if item.isControllable {
            Button(item.isEnabled ? "Disable" : "Enable", systemImage: item.requiresAdmin ? "lock.open" : "power") {
                Task { await model.setEnabled(!item.isEnabled, for: item) }
            }
            Divider()
        }
        Button("Reveal Plist in Finder", systemImage: "doc") { model.revealInFinder(item) }
        if item.executableURL != nil {
            Button("Reveal Executable in Finder", systemImage: "terminal") { model.revealExecutable(item) }
        }
        Button("Copy Label", systemImage: "doc.on.doc") { model.copyLabel(item) }
    }

    // MARK: Data

    private var visibleItems: [StartupItem] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        return model.visibleItems
            .filter { filter.matches($0) && matchesSearch($0, query) }
            .sorted(by: sort.areInIncreasingOrder)
    }

    private func count(for filter: StartupFilter) -> Int {
        model.visibleItems.reduce(0) { $0 + (filter.matches($1) ? 1 : 0) }
    }

    private func matchesSearch(_ item: StartupItem, _ query: String) -> Bool {
        query.isEmpty || item.matchesSearchFields.contains { $0.localizedCaseInsensitiveContains(query) }
    }
}

// MARK: - Column header

private struct StartupColumnHeader: View {
    var body: some View {
        HStack(spacing: Theme.Spacing.m) {
            title("Name")
                .padding(.leading, StartupListMetrics.icon + Theme.Spacing.m)
                .frame(maxWidth: .infinity, alignment: .leading)
            title("Kind").frame(width: StartupListMetrics.kind, alignment: .leading)
            title("Signed by").frame(width: StartupListMetrics.signer, alignment: .leading)
            title("Enabled").frame(width: StartupListMetrics.toggle, alignment: .trailing)
        }
        .padding(.horizontal, StartupListMetrics.rowHorizontal)
        .padding(.vertical, Theme.Spacing.m)
        .accessibilityHidden(true)
    }

    private func title(_ key: LocalizedStringKey) -> some View {
        Text(key)
            .textCase(.uppercase)
            .font(Theme.Typography.eyebrow)
            .tracking(1.2)
            .foregroundStyle(Theme.Palette.textTertiary)
    }
}
