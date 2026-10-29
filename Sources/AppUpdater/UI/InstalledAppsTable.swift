import AppKit
import AppUpdaterCore
import SwiftUI

/// Every scanned app with its version and update status, as a glass list with filters and sorting.
struct InstalledAppsTable: View {
    let viewModel: UpdatesViewModel
    let apps: [InstalledApp]
    /// Export/import of the app list for a new Mac; the menu is hidden when nil.
    var migrationModel: MigrationModel?

    @State private var filter: AppFilter = .all
    @State private var sort: AppSort = .name
    @State private var detailApp: InstalledApp?
    @State private var uninstallApp: InstalledApp?
    @State private var revertApp: InstalledApp?

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xl) {
            PageHeader(title: String(localized: "All Apps"), subtitle: subtitle) {
                HStack(spacing: Theme.Spacing.s) {
                    if let migrationModel {
                        MigrationMenu(model: migrationModel, installedApps: viewModel.installedApps)
                    }
                    sortMenu
                }
            }
            FilterCapsule(selection: $filter, count: { count(for: $0) })
            listCard
        }
        .padding(Theme.Spacing.page)
        .frame(maxWidth: Theme.Spacing.contentWidth)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .pageBackground()
        .sheet(item: $detailApp) { app in
            AppDetailView(app: app, viewModel: viewModel)
        }
        .sheet(item: $uninstallApp) { app in
            makeUninstallSheet(for: app, viewModel: viewModel)
        }
        .revertConfirmation(appName: revertApp?.name ?? "", isPresented: isConfirmingRevert) {
            if let app = revertApp { Task { await viewModel.revertToPreviousVersion(app) } }
        }
    }

    // MARK: Layout

    private var subtitle: String {
        let withUpdates = count(for: .updates)
        let total = apps.count == 1 ? String(localized: "1 app") : String(localized: "\(apps.count) apps")
        return "\(total) · " + String(localized: "\(withUpdates) with updates")
    }

    private var sortMenu: some View {
        Menu {
            Picker("Sort by", selection: $sort) {
                ForEach(AppSort.allCases) { option in
                    Text(option.title).tag(option)
                }
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

    /// Sticky column header over a scrolling list, all in one glass card.
    private var listCard: some View {
        VStack(spacing: 0) {
            ColumnHeaderRow()
            GlassDivider()
            if visibleApps.isEmpty {
                EmptyStateView(
                    symbol: "line.3.horizontal.decrease.circle",
                    title: String(localized: "No apps match"),
                    message: String(localized: "Try another filter or search term.")
                )
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(visibleApps.enumerated()), id: \.element.id) { index, app in
                            if index > 0 {
                                GlassDivider(leadingInset: AppListMetrics.dividerInset)
                                    .padding(.trailing, Theme.Spacing.m)
                            }
                            row(for: app)
                        }
                    }
                    .padding(.vertical, Theme.Spacing.xs)
                }
                .scrollIndicators(.automatic)
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .surface(.raised)
    }

    private func row(for app: InstalledApp) -> some View {
        let result = viewModel.checkResult(for: app)
        return InstalledAppRow(
            app: app,
            icon: viewModel.icon(for: app),
            onOpen: { detailApp = app },
            status: {
                HStack(spacing: 6) {
                    status(for: app)
                    WarningBadge(warnings: viewModel.warnings(for: app))
                }
            },
            source: {
                if let update = viewModel.update(for: app) {
                    SourceBadge(source: update.source)
                } else if let source = result?.matchedSource {
                    SourceBadge(source: source)
                } else {
                    Text(result?.sourceLabel ?? "—")
                        .font(.system(size: 11.5))
                        .foregroundStyle(Theme.Palette.textTertiary)
                        .lineLimit(1)
                        .help(result?.errors.joined(separator: "\n") ?? "")
                }
            }
        )
        .contextMenu { menu(for: app) }
    }

    // MARK: Data

    private var visibleApps: [InstalledApp] {
        apps.filter { matches($0, filter) }.sorted(by: areInIncreasingOrder)
    }

    private func count(for filter: AppFilter) -> Int {
        apps.reduce(0) { $0 + (matches($1, filter) ? 1 : 0) }
    }

    private func matches(_ app: InstalledApp, _ filter: AppFilter) -> Bool {
        let isIgnored = viewModel.exclusions.isIgnored(app.bundleIdentifier)
        switch filter {
        case .all:
            return true
        case .updates:
            return !isIgnored && viewModel.update(for: app) != nil
        case .upToDate:
            return !isIgnored && viewModel.checkResult(for: app)?.isUpToDate == true
        case .issues:
            let failed = !(viewModel.checkResult(for: app)?.errors.isEmpty ?? true)
            return failed || !viewModel.warnings(for: app).isEmpty
        }
    }

    private func areInIncreasingOrder(_ lhs: InstalledApp, _ rhs: InstalledApp) -> Bool {
        switch sort {
        case .name:
            break
        case .status:
            let (left, right) = (statusRank(lhs), statusRank(rhs))
            if left != right { return left < right }
        case .source:
            let (left, right) = (sourceName(lhs), sourceName(rhs))
            if left != right { return left.localizedStandardCompare(right) == .orderedAscending }
        }
        return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
    }

    /// Updates first, then problems, unknown, up to date and finally ignored apps.
    private func statusRank(_ app: InstalledApp) -> Int {
        if viewModel.exclusions.isIgnored(app.bundleIdentifier) { return 4 }
        if viewModel.update(for: app) != nil { return 0 }
        guard let result = viewModel.checkResult(for: app) else { return 2 }
        if !result.errors.isEmpty { return 1 }
        return result.isUpToDate ? 3 : 2
    }

    /// Apps without a source sort last.
    private func sourceName(_ app: InstalledApp) -> String {
        viewModel.checkResult(for: app)?.matchedSource?.displayName ?? "\u{FFFF}"
    }

    private var isConfirmingRevert: Binding<Bool> {
        Binding(get: { revertApp != nil }, set: { if !$0 { revertApp = nil } })
    }

    // MARK: Menu & status

    @ViewBuilder
    private func menu(for app: InstalledApp) -> some View {
        if let update = viewModel.update(for: app) {
            Button("Download Manually…", systemImage: "safari") { viewModel.openDownloadPage(update) }
        } else {
            Button("Search the Web for Updates…", systemImage: "magnifyingglass") { viewModel.searchWebForUpdate(app) }
        }
        Button("Show Details…", systemImage: "info.circle") { detailApp = app }
        Button("Show in Finder", systemImage: "folder") { viewModel.revealInFinder(app) }
        if viewModel.backup(for: app) != nil {
            Button("Revert to Previous Version", systemImage: "arrow.uturn.backward") { revertApp = app }
        }
        if let management = viewModel.vendorManagement(for: app) {
            Button("Open \(management.updaterName)", systemImage: "arrow.triangle.2.circlepath.circle") {
                viewModel.openVendorUpdater(management)
            }
        }
        Divider()
        if viewModel.isIgnoreLocked(app.bundleIdentifier) {
            Label("Ignored by your organization", systemImage: "lock.fill")
        } else if viewModel.exclusions.isIgnored(app.bundleIdentifier) {
            Button("Stop Ignoring", systemImage: "eye") { viewModel.include(app.bundleIdentifier) }
        } else {
            Button("Ignore Updates", systemImage: "eye.slash") { viewModel.ignore(app) }
        }
        if viewModel.canUninstall(app) {
            Divider()
            Button("Uninstall…", systemImage: "trash", role: .destructive) { uninstallApp = app }
        }
    }

    @ViewBuilder
    private func status(for app: InstalledApp) -> some View {
        if viewModel.exclusions.isIgnored(app.bundleIdentifier) {
            StatusPill(title: String(localized: "Ignored"), symbol: "eye.slash", tint: Theme.Palette.textTertiary)
        } else if let management = viewModel.vendorManagement(for: app) {
            VendorManagedBadge(management: management)
                .lineLimit(1)
        } else if let update = viewModel.update(for: app) {
            StatusPill(title: update.newVersion, symbol: "arrow.up.circle.fill", tint: Theme.Palette.brand)
                .monospacedDigit()
                .help("Update available: \(app.shortVersion) → \(update.newVersion)")
        } else if let result = viewModel.checkResult(for: app) {
            if result.isUpToDate {
                StatusPill(title: String(localized: "Up to date"), symbol: "checkmark", tint: Theme.Palette.success)
            } else if result.errors.isEmpty {
                StatusPill(title: String(localized: "Unknown"), symbol: "questionmark.circle", tint: Theme.Palette.textSecondary)
                    .help("No update source knows this app")
            } else {
                StatusPill(
                    title: String(localized: "Check failed"), symbol: "exclamationmark.circle",
                    tint: Theme.Palette.warning
                )
                .help(result.errors.joined(separator: "\n"))
            }
        } else if app.isFromAppStore {
            StatusPill(title: String(localized: "App Store"), symbol: "bag", tint: Theme.Palette.info)
        } else {
            StatusPill(title: String(localized: "Not checked"), symbol: "clock", tint: Theme.Palette.textSecondary)
        }
    }
}

// MARK: - Filter & sort

/// Local status filter of the All Apps list.
private enum AppFilter: CaseIterable, Identifiable {
    case all, updates, upToDate, issues

    var id: Self { self }

    var title: String {
        switch self {
        case .all: String(localized: "All")
        case .updates: String(localized: "Updates")
        case .upToDate: String(localized: "Up to date")
        case .issues: String(localized: "Issues")
        }
    }
}

private enum AppSort: CaseIterable, Identifiable {
    case name, status, source

    var id: Self { self }

    var title: String {
        switch self {
        case .name: String(localized: "Name")
        case .status: String(localized: "Status")
        case .source: String(localized: "Source")
        }
    }
}

/// Column widths shared by the header and the rows.
private enum AppListMetrics {
    static let icon: CGFloat = 28
    static let version: CGFloat = 96
    static let status: CGFloat = 180
    static let source: CGFloat = 104
    static let rowHorizontal: CGFloat = Theme.Spacing.l
    /// Hairlines start under the name, past the icon.
    static let dividerInset: CGFloat = rowHorizontal + icon + Theme.Spacing.m
}

/// Segmented glass capsule; the selected segment gets a lit brand fill that slides between options.
private struct FilterCapsule: View {
    @Binding var selection: AppFilter
    let count: (AppFilter) -> Int

    @Namespace private var namespace

    var body: some View {
        HStack(spacing: 2) {
            ForEach(AppFilter.allCases) { option in
                segment(option)
            }
        }
        .padding(3)
        .background(Capsule().fill(Theme.Palette.glass))
        .background(Capsule().fill(Color.white.opacity(0.04)))
        .overlay(Capsule().strokeBorder(Theme.Palette.hairline, lineWidth: 1))
        .fixedSize()
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Filter"))
    }

    private func segment(_ option: AppFilter) -> some View {
        let isSelected = selection == option
        return Button {
            withAnimation(Theme.Motion.content) { selection = option }
        } label: {
            HStack(spacing: 6) {
                Text(option.title)
                Text("\(count(option))")
                    .font(.system(size: 10.5, weight: .bold, design: .rounded).monospacedDigit())
                    .foregroundStyle(isSelected ? Theme.Palette.textPrimary : Theme.Palette.textTertiary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(Color.white.opacity(isSelected ? 0.18 : 0.06)))
                    .contentTransition(.numericText())
            }
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(isSelected ? Theme.Palette.textPrimary : Theme.Palette.textSecondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background {
                if isSelected {
                    Capsule()
                        .fill(Theme.brandGradient)
                        .overlay(Capsule().strokeBorder(Color.white.opacity(0.3), lineWidth: 0.5))
                        .glow(Theme.Palette.brand, radius: 8, opacity: 0.45)
                        .matchedGeometryEffect(id: "selection", in: namespace)
                }
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// Eyebrow-style column titles aligned with `InstalledAppRow`.
private struct ColumnHeaderRow: View {
    var body: some View {
        HStack(spacing: Theme.Spacing.m) {
            title("Name")
                .padding(.leading, AppListMetrics.icon + Theme.Spacing.m)
                .frame(maxWidth: .infinity, alignment: .leading)
            title("Version").frame(width: AppListMetrics.version, alignment: .leading)
            title("Status").frame(width: AppListMetrics.status, alignment: .leading)
            title("Source").frame(width: AppListMetrics.source, alignment: .leading)
        }
        .padding(.horizontal, AppListMetrics.rowHorizontal)
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

/// One app: icon, name over its folder, mono version, status and source; click opens details.
private struct InstalledAppRow<Status: View, Source: View>: View {
    let app: InstalledApp
    let icon: NSImage
    let onOpen: () -> Void
    @ViewBuilder var status: Status
    @ViewBuilder var source: Source

    @State private var isHovered = false

    var body: some View {
        HStack(spacing: Theme.Spacing.m) {
            Image(nsImage: icon)
                .resizable()
                .interpolation(.high)
                .frame(width: AppListMetrics.icon, height: AppListMetrics.icon)
                .shadow(color: .black.opacity(0.35), radius: 3, y: 1.5)
            VStack(alignment: .leading, spacing: 1) {
                Text(app.name)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.Palette.textPrimary)
                    .lineLimit(1)
                Text(app.url.deletingLastPathComponent().path)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.Palette.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text(app.shortVersion)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(Theme.Palette.textSecondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(width: AppListMetrics.version, alignment: .leading)
            status
                .frame(width: AppListMetrics.status, alignment: .leading)
            source
                .frame(width: AppListMetrics.source, alignment: .leading)
        }
        .padding(.horizontal, AppListMetrics.rowHorizontal - Theme.Spacing.xs)
        .padding(.vertical, Theme.Spacing.s)
        .hoverHighlight(isHovered, radius: Theme.Radius.m)
        .padding(.horizontal, Theme.Spacing.xs)
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .onTapGesture(perform: onOpen)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(named: Text("Show Details…"), onOpen)
    }
}
