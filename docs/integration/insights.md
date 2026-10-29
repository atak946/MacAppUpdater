# Insights integration

Files added (no existing files touched):

- `Sources/AppUpdaterCore/Insights/AppWarning.swift`: `WarningSeverity`, `AppWarning` (+ `Kind`, canonical copy, `symbolName`)
- `Sources/AppUpdaterCore/Insights/CompatibilityAnalyzer.swift`: `AppAnalysisInput`, `CompatibilityAnalyzer` (pure)
- `Sources/AppUpdaterCore/Insights/TeamIdentifierStore.swift`: `TeamIdentifierStoring`, `UserDefaultsTeamIdentifierStore`
- `Sources/AppUpdaterCore/Insights/AppUsageReader.swift`: `AppUsageReading`, `AppUsageReader` (Spotlight `kMDItemLastUsedDate`, then `contentAccessDate`)
- `Sources/AppUpdaterCore/Insights/InsightsReport.swift`: `AppInsight`, `AppWarningEntry`, `WarningGroup`, `InsightsReport`, `InsightsBuilder` (pure)
- `Sources/AppUpdaterCore/Insights/InsightsCollector.swift`: async collector, TaskGroup with at most 6 concurrent reads
- `Sources/AppUpdater/UI/Insights/{InsightsView,InsightsHeadline,LargestAppsChart,InsightsWarningsSection,InsightsStyle}.swift`
- Tests: `CompatibilityAnalyzerTests`, `InsightsBuilderTests`, `TeamIdentifierStoreTests`

`Package.swift` needs no change. `Charts` is a system framework, imported with `import Charts`.

## Public API

```swift
// Analyzer (pure; inject the OS version in tests)
let analyzer = CompatibilityAnalyzer()                       // currentSystemVersion: running macOS
analyzer.warnings(for: AppAnalysisInput(app:details:update:lastUsedDate:previousTeamIdentifier:), now: .now) -> [AppWarning]
analyzer.updateCompatibilityWarning(for: update) -> AppWarning?   // non-nil means: block or confirm the install
analyzer.requiresNewerSystem("15.0") -> Bool
CompatibilityAnalyzer.isIntelOnly(details.executableArchitectures) -> Bool

// Warning
warning.kind / .severity (info < warning < critical) / .title / .explanation / .suggestedAction / .symbolName

// Collection (off the main actor)
let collector = InsightsCollector()                          // default readers + UserDefaults team store
let report: InsightsReport = await collector.collect(apps: installedApps, updates: updates)
report.totalApps, .totalSizeInBytes, .largestApps (top 10), .unusedApps (>90 d), .intelOnlyApps,
report.warningGroups (critical first, only non-empty groups), .totalWarnings, .warnings(for: bundleID)

// Team identifier store
store.lastKnownTeamIdentifier(for:), store.record(_:for:), store.forget(_:)
```

## 1. AppEnvironment wiring

```swift
// AppEnvironment.init
let teamStore = UserDefaultsTeamIdentifierStore(defaults: defaults)
let insightsCollector = InsightsCollector(teamStore: teamStore)
// pass into UpdatesViewModel (new init params) or keep a dedicated InsightsModel
```

Add to `UpdatesViewModel` (or a separate `@Observable @MainActor final class InsightsModel`):

```swift
private(set) var insights: InsightsReport?
private(set) var isLoadingInsights = false
let compatibility = CompatibilityAnalyzer()

func refreshInsights() async {
    guard !isLoadingInsights else { return }
    isLoadingInsights = true
    defer { isLoadingInsights = false }
    insights = await insightsCollector.collect(apps: installedApps, updates: updates)
}

func warnings(for app: InstalledApp) -> [AppWarning] {
    insights?.warnings(for: app.bundleIdentifier) ?? []
}

/// The user confirmed a developer change; stop warning about it.
func trustCurrentTeam(of app: InstalledApp, teamIdentifier: String) {
    teamStore.record(teamIdentifier, for: app.bundleIdentifier)
}
```

Call `await viewModel.refreshInsights()` at the end of `refresh()` so insights see fresh updates (for the `updateRequiresNewerMacOS` warning), or lazily when the Insights tab first appears.

## 2. Sidebar item "Insights"

```swift
// enum SidebarItem
case insights
// title
case .insights: "Insights"

// SidebarView, Section("Library")
row(.insights, symbol: "chart.bar.xaxis", count: viewModel.insights?.totalWarnings ?? 0)

// MainWindowView.detail
case .insights:
    InsightsView(
        report: viewModel.insights,
        isLoading: viewModel.isLoadingInsights,
        onSelectApp: { app in /* present AppDetailView sheet, same as the All Apps table */ },
        onRefresh: { Task { await viewModel.refreshInsights() } }
    )
    .task { if viewModel.insights == nil { await viewModel.refreshInsights() } }
```

## 3. Warning badge in the All Apps "Status" column (`UpdatesListView.swift`, `InstalledAppsTable`)

```swift
TableColumn("Status") { app in
    HStack(spacing: 6) {
        /* existing status content */
        let warnings = viewModel.warnings(for: app)
        if let top = warnings.first {   // already sorted most severe first
            Image(systemName: top.symbolName)
                .foregroundStyle(InsightsStyle.color(for: top.severity))
                .help(warnings.map(\.title).joined(separator: "\n"))
                .accessibilityLabel("\(warnings.count) warnings")
        }
    }
}
```

`InsightsStyle` is internal to the AppUpdater target, so it can be used anywhere in the UI.

## 4. Warnings section in `AppDetailView`

The detail view already loads `details`. Add a section under `AppInfoGrid` inside the `ScrollView`:

```swift
let warnings = viewModel.warnings(for: app)
if !warnings.isEmpty {
    VStack(alignment: .leading, spacing: 8) {
        Text("Warnings").font(.headline)
        ForEach(warnings) { warning in
            WarningCard(entry: AppWarningEntry(app: app, warning: warning), onSelectApp: { _ in })
        }
    }
    .padding(.horizontal, 24)
}
```

If insights have not been collected yet, compute warnings on the spot (no I/O except the store lookup):

```swift
viewModel.compatibility.warnings(for: AppAnalysisInput(
    app: app, details: details, update: viewModel.update(for: app),
    lastUsedDate: nil, previousTeamIdentifier: teamStore.lastKnownTeamIdentifier(for: app.bundleIdentifier)))
```

## 5. Gate updates that need a newer macOS

In `UpdatesViewModel.install(_:)`, before the `switch`:

```swift
if let blocker = compatibility.updateCompatibilityWarning(for: update) {
    pendingCompatibilityConfirmation = (update, blocker)   // @Observable property, shown as .confirmationDialog
    return
}
```

```swift
// The view presenting the dialog
.confirmationDialog(blocker.title, isPresented: $showsBlocker) {
    Button("Install Anyway", role: .destructive) { Task { await viewModel.install(update, ignoringCompatibility: true) } }
    Button("Cancel", role: .cancel) {}
} message: { Text("\(blocker.explanation) \(blocker.suggestedAction)") }
```

Also exclude these updates from `installAll()` (`installableUpdates.filter { compatibility.updateCompatibilityWarning(for: $0) == nil }`), and consider a "Requires macOS X" label in `UpdateRowView`.

## Caveats

- **Signed vs. invalid:** `AppDetails.Signature.unsigned(reason:)` covers both cases. The analyzer classifies by the reason text: "not signed", "unsigned", "no team identifier", "ad-hoc" map to `.unsigned`; anything else maps to `.signatureInvalid`. If `AppDetails` later gets an explicit invalid case, update `signatureKind`.
- **Team identifier policy:** `InsightsCollector` records the team id only the first time it sees a bundle. A changed signer keeps warning until the app calls `store.record(newTeam, for:)`, for example from a "Trust new developer" button, or `forget(_:)` when an app is uninstalled. `AppInstaller` may already enforce the team id at install time; this check catches changes made outside the updater.
- **Last used date:** this comes from Spotlight and can be nil when indexing is disabled. In that case `contentAccessDate` is used, which can be noisy. Apps with an unknown date are never listed as unused.
- **Cost:** collecting reads the signature and bundle size for every app, which takes seconds for big libraries. Do not run it on every scheduler tick; run it on demand or after a manual refresh.
- The "unused" threshold is `CompatibilityAnalyzer.defaultUnusedThresholdDays` (90). To change it, pass `unusedThresholdDays` to both `CompatibilityAnalyzer` and `InsightsBuilder`.
- Chart bars use the app name as their category, so two apps with the same name share one bar row. This is rare and acceptable.
