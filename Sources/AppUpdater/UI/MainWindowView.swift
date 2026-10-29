import AppKit
import AppUpdaterCore
import SwiftUI

/// The regular app window: Overview home, sidebar filters, updates list and installed apps table.
struct MainWindowView: View {
    let viewModel: UpdatesViewModel
    let formulaeModel: FormulaeModel
    let cleanupModel: CleanupModel
    let startupModel: StartupModel
    let securityModel: SecurityModel
    let monitorModel: MonitorModel
    /// Lets Coverage map an app to a GitHub repository in place.
    var githubMappings: GitHubMappingDependencies?
    /// Export/import of the app list on All Apps.
    var migrationModel: MigrationModel?

    @State private var selection: SidebarItem?
    @State private var searchText = ""
    @State private var detailApp: InstalledApp?
    @State private var mappingApp: InstalledApp?

    /// `initialSelection` opens a page other than Overview (README screenshots); nil honours `-UIInitialPage`.
    init(
        viewModel: UpdatesViewModel,
        formulaeModel: FormulaeModel,
        cleanupModel: CleanupModel,
        startupModel: StartupModel,
        securityModel: SecurityModel,
        monitorModel: MonitorModel,
        githubMappings: GitHubMappingDependencies? = nil,
        migrationModel: MigrationModel? = nil,
        initialSelection: SidebarItem? = nil
    ) {
        self.viewModel = viewModel
        self.formulaeModel = formulaeModel
        self.cleanupModel = cleanupModel
        self.startupModel = startupModel
        self.securityModel = securityModel
        self.monitorModel = monitorModel
        self.githubMappings = githubMappings
        self.migrationModel = migrationModel
        _selection = State(initialValue: initialSelection ?? SidebarItem.launchArgument ?? .overview)
    }

    var body: some View {
        // GeometryReader takes the proposed size without measuring its content, so AppKit's
        // per-update minimum-size query stops laying out the whole page a second time.
        GeometryReader { _ in
            windowContent
        }
        .frame(minWidth: 900, minHeight: 600)
        .background(shortcuts)
        .sheet(item: $detailApp) { app in
            AppDetailView(app: app, viewModel: viewModel)
        }
        .sheet(item: $mappingApp) { app in
            if let githubMappings {
                GitHubMappingSheet(app: app, installedApps: viewModel.installedApps, dependencies: githubMappings)
            }
        }
        .actionErrorAlert(viewModel)
        .task {
            if viewModel.state == .idle { await viewModel.refresh() }
        }
    }

    private var windowContent: some View {
        HStack(spacing: 0) {
            GlassSidebar(
                viewModel: viewModel,
                formulaeModel: formulaeModel,
                selection: $selection,
                searchText: $searchText
            )
            .frame(width: 236)
            // The top bar sits outside the transitioning page so it never doubles during a switch.
            // A plain stack, not `safeAreaInset`: the inset re-measures the whole page on every
            // update, which made each Monitor sample cost ~0.7 s of main-thread layout.
            VStack(spacing: 0) {
                topBar
                ZStack {
                    detail
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .id(selection)
                        .transition(.opacity)
                }
                .animation(.easeOut(duration: 0.16), value: selection)
            }
        }
        .scrollContentBackground(.hidden)
        // Static: an animated backdrop forces every glass surface to re-blur each frame.
        .background { AppBackdrop(isAnimated: false).ignoresSafeArea() }
        .environment(\.isOnBackdrop, true)
        .preferredColorScheme(.dark)
        .ignoresSafeArea(.container, edges: .top)
    }

    // MARK: Detail

    @ViewBuilder
    private var detail: some View {
        switch selection ?? .overview {
        case .overview:
            OverviewView(
                viewModel: viewModel,
                formulaeModel: formulaeModel,
                onNavigate: { selection = $0 },
                onSelectHistory: showDetail(for:)
            )
        case .allApps:
            InstalledAppsTable(viewModel: viewModel, apps: filteredApps, migrationModel: migrationModel)
        case .updates:
            UpdatesListView(viewModel: viewModel, updates: filteredUpdates(nil))
        case .source(let kind):
            UpdatesListView(viewModel: viewModel, updates: filteredUpdates(kind))
        case .commandLineTools:
            FormulaeView(model: formulaeModel)
        case .insights:
            InsightsView(
                report: viewModel.insights,
                isLoading: viewModel.isLoadingInsights,
                onSelectApp: { detailApp = $0 },
                onRefresh: { Task { await viewModel.refreshInsights() } }
            )
            .task(id: viewModel.installedApps.count) { if viewModel.insights == nil { await viewModel.refreshInsights() } }
        case .coverage:
            CoverageView(
                report: viewModel.coverageReport,
                isLoading: viewModel.isBusy,
                actions: coverageActions,
                onRefresh: { Task { await viewModel.refresh() } }
            )
        case .history:
            UpdateHistoryView(
                entries: viewModel.history,
                onClear: { Task { await viewModel.clearHistory() } },
                onSelect: showDetail(for:),
                externalSearchText: searchText
            )
        case .excluded:
            ExcludedView(viewModel: viewModel)
        case .cleanup:
            CleanupView(model: cleanupModel)
        case .system:
            SystemMonitorView(model: monitorModel)
        case .processes:
            ProcessesView(model: monitorModel, searchText: searchText)
        case .startup:
            StartupItemsView(model: startupModel, searchText: searchText)
        case .security:
            SecurityView(model: securityModel, searchText: searchText)
        }
    }

    private func showDetail(for entry: UpdateHistoryEntry) {
        detailApp = viewModel.installedApps.first { $0.bundleIdentifier == entry.bundleID }
    }

    private var coverageActions: CoverageActions {
        CoverageActions(
            mapGitHubRepo: { mappingApp = $0 },
            searchHomebrew: { viewModel.searchHomebrew(for: $0) },
            reportMissing: { app in Task { await viewModel.reportMissingApp(app) } },
            ignore: { viewModel.ignore($0) },
            selectApp: { detailApp = $0 }
        )
    }

    private var filteredApps: [InstalledApp] {
        guard !searchText.isEmpty else { return viewModel.installedApps }
        return viewModel.installedApps.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
    }

    private func filteredUpdates(_ kind: UpdateSourceKind?) -> [AvailableUpdate] {
        viewModel.updates.filter { update in
            let matchesSource = kind.map { update.source == $0 } ?? true
            let matchesSearch = searchText.isEmpty || update.app.name.localizedCaseInsensitiveContains(searchText)
            return matchesSource && matchesSearch
        }
    }

    private var subtitle: String {
        switch viewModel.state {
        case .scanning: String(localized: "Scanning applications…")
        case .checking: String(localized: "Checking \(viewModel.installedApps.count) apps for updates…")
        case .failed: String(localized: "Last check failed")
        default:
            if let lastChecked = viewModel.lastChecked {
                String(localized: "Checked \(lastChecked.formatted(.relative(presentation: .named)))")
            } else {
                String(localized: "Not checked yet")
            }
        }
    }

    // MARK: Top bar

    /// Floating status capsule in the (hidden) title bar area: last check, refresh and Update All.
    private var topBar: some View {
        HStack(spacing: Theme.Spacing.s) {
            Spacer()
            HStack(spacing: Theme.Spacing.s) {
                if viewModel.isBusy {
                    ProgressView().controlSize(.mini).tint(.white)
                }
                Text(subtitle)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(Theme.Palette.textSecondary)
                    .contentTransition(.opacity)
                Button {
                    Task { await viewModel.refresh() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .symbolEffect(.pulse, options: .repeating, isActive: viewModel.isBusy)
                }
                .buttonStyle(IconButtonStyle())
                .disabled(viewModel.isBusy)
                .help("Check for updates (⌘R)")
            }
            .padding(.leading, Theme.Spacing.m)
            .padding(.trailing, Theme.Spacing.xs)
            .padding(.vertical, 2)
            .surface(.raised, radius: 18)
            // Overview and the updates lists carry their own Update All in the page header.
            if !pageHasOwnUpdateAll {
                Button {
                    Task { await viewModel.installAll() }
                } label: {
                    Label("Update All", systemImage: "arrow.down.circle.fill")
                }
                .buttonStyle(.primary)
                .controlSize(.small)
                .disabled(viewModel.installableUpdates.isEmpty)
                .help("Install all available updates")
            }
        }
        .padding(.horizontal, Theme.Spacing.l)
        .padding(.top, 10)
        .padding(.bottom, Theme.Spacing.xs)
        .frame(height: 52)
    }

    /// Window-wide keyboard shortcuts that used to live on toolbar buttons.
    private var shortcuts: some View {
        Button("Check for Updates") { Task { await viewModel.refresh() } }
            .keyboardShortcut("r")
            .disabled(viewModel.isBusy)
            .hidden()
            .accessibilityHidden(true)
    }

    private var pageHasOwnUpdateAll: Bool {
        switch selection ?? .overview {
        case .overview, .updates, .source: true
        // Maintenance and monitor pages are unrelated to app updates.
        case .cleanup, .system, .processes, .startup, .security: true
        default: false
        }
    }
}

// MARK: - Sidebar

enum SidebarItem: Hashable {
    case overview
    case updates
    case allApps
    case commandLineTools
    case insights
    case coverage
    case history
    case source(UpdateSourceKind)
    case excluded
    case cleanup
    case system
    case processes
    case startup
    case security

    var title: String {
        switch self {
        case .overview: String(localized: "Overview")
        case .updates: String(localized: "Updates")
        case .allApps: String(localized: "All Apps")
        case .commandLineTools: String(localized: "Command Line Tools")
        case .insights: String(localized: "Insights")
        case .coverage: String(localized: "Coverage")
        case .history: String(localized: "History")
        case .source(let kind): kind.displayName
        case .excluded: String(localized: "Excluded")
        case .cleanup: String(localized: "Cleanup")
        case .system: String(localized: "System")
        case .processes: String(localized: "Processes")
        case .startup: String(localized: "Startup Items")
        case .security: String(localized: "Security")
        }
    }

    /// `-UIInitialPage history` on the command line opens that page (screenshots, UI tests).
    static var launchArgument: SidebarItem? {
        switch UserDefaults.standard.string(forKey: "UIInitialPage") {
        case "updates": .updates
        case "allApps": .allApps
        case "commandLineTools": .commandLineTools
        case "insights": .insights
        case "coverage": .coverage
        case "history": .history
        case "excluded": .excluded
        case "cleanup": .cleanup
        case "system": .system
        case "processes": .processes
        case "startup": .startup
        case "security": .security
        default: nil
        }
    }

    /// Glyph shown in the sidebar icon tile.
    var symbol: String {
        switch self {
        case .overview: "heart.text.square.fill"
        case .updates: "arrow.down.app.fill"
        case .allApps: "square.grid.2x2.fill"
        case .commandLineTools: "terminal.fill"
        case .insights: "chart.bar.xaxis"
        case .coverage: "scope"
        case .history: "clock.arrow.circlepath"
        case .source(let kind): kind.symbol
        case .excluded: "eye.slash.fill"
        case .cleanup: "sparkles"
        case .system: "gauge.with.dots.needle.67percent"
        case .processes: "list.bullet.rectangle.portrait.fill"
        case .startup: "power.circle.fill"
        case .security: "lock.shield.fill"
        }
    }

    /// System Settings style tile color; every destination gets its own.
    var tint: Color {
        switch self {
        case .overview: Theme.Palette.brand
        case .updates: Theme.Palette.info
        case .allApps: .teal
        case .commandLineTools: Color(white: 0.42)
        case .insights: .purple
        case .coverage: .mint
        case .history: Theme.Palette.warning
        case .source(let kind): kind.tint
        case .excluded: Color(white: 0.5)
        case .cleanup: Theme.Palette.brandSecondary
        case .system: Theme.Palette.brandTertiary
        case .processes: Theme.Palette.success
        case .startup: Theme.Palette.warning
        case .security: Theme.Palette.info
        }
    }
}

extension UpdateSourceKind {
    var displayName: String {
        switch self {
        case .sparkle: "Sparkle"
        case .homebrew: "Homebrew"
        case .github: "GitHub"
        case .appStore: "App Store"
        case .electron: "Electron"
        case .vendor: String(localized: "Vendor")
        }
    }

    var symbol: String {
        switch self {
        case .sparkle: "sparkles"
        case .homebrew: "mug"
        case .github: "chevron.left.forwardslash.chevron.right"
        case .appStore: "bag"
        case .electron: "atom"
        case .vendor: "building.2"
        }
    }

    /// Sidebar tile color for the source.
    var tint: Color {
        switch self {
        case .sparkle: .pink
        case .homebrew: .brown
        case .github: Color(white: 0.4)
        case .appStore: .blue
        case .electron: .cyan
        case .vendor: .indigo
        }
    }
}
