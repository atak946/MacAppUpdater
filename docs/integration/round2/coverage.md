# Round 2 — Coverage (A4) + Vendor-managed apps (A5) + security warning cases (B1/B3)

Nothing outside the owned files was edited. `InstallMethod` is **unchanged**; vendor
management lives in a new `ResolvedInstallMethod` so existing exhaustive switches in
`UpdatesViewModel`, `UpdateRowView`, `AppDetailBanner`, `UpdatesViewModel+Install` and
`UpdatePolicy` keep compiling. Migrate them when convenient (snippets below).

## New / changed files

| File | Purpose |
|---|---|
| `Sources/AppUpdaterCore/Coverage/CoverageReport.swift` | `CoverageReport`, `SourceCoverage`, `FailedCoverageCheck`, `CoverageConstants`, `PercentEncoding` |
| `Sources/AppUpdaterCore/Coverage/MissingAppReport.swift` | Prefilled, PII-free GitHub issue URL |
| `Sources/AppUpdaterCore/Coverage/VendorManagement.swift` | `VendorManagement { vendor, updaterName, openTarget }` |
| `Sources/AppUpdaterCore/Coverage/VendorManagementDetector.swift` | Setapp / Adobe CC / MAU / Keystone / JetBrains Toolbox detection |
| `Sources/AppUpdaterCore/Preferences/InstallMethod.swift` | + `ResolvedInstallMethod`, `InstallMethod.resolve(update:vendorManagement:)` |
| `Sources/AppUpdaterCore/Insights/AppWarning.swift` | + `.notNotarized(reason:scope:)`, `.downloadHostChanged(previous:current:)`, `.managedByVendor(updaterName:)` |
| `Sources/AppUpdaterCore/Insights/SecurityAnalysisInputs.swift` | `GatekeeperScope`; verdict → warning mapping |
| `Sources/AppUpdaterCore/Insights/CompatibilityAnalyzer.swift` | new optional inputs + `notarizationWarning(for:scope:)`, `downloadHostWarning(for:)` |
| `Sources/AppUpdater/UI/Coverage/CoverageView.swift`, `CoverageHeadline.swift`, `CoverageLists.swift` | Coverage page |
| Tests: `Tests/AppUpdaterCoreTests/Coverage/*`, `SecurityWarningsAnalyzerTests.swift` | |

## Public API

```swift
// A4
CoverageReport(results: [UpdateCheckResult], ignoredBundleIdentifiers: Set<String> = [])
  .totalApps, .bySource: [SourceCoverage], .untracked: [InstalledApp],
  .failed: [FailedCoverageCheck], .appStoreApps, .ignoredCount,
  .trackedCount, .trackedFraction (0...1), .trackedPercentage (0...100)
CoverageConstants.issueRepository          // "OWNER/MacAppUpdater" — CHANGE before shipping
CoverageConstants.homebrewSearchURL(for: app.name) -> URL?   // https://formulae.brew.sh/?search=…
MissingAppReport(app:, hasElectronUpdateConfig: Bool? = nil /* nil = check disk */, teamIdentifier: String?)
  .issueURL(repository: = CoverageConstants.issueRepository) -> URL?

// A5
VendorManagementDetector(rootDirectory: = "/", homeDirectory: = ~).detect(_ app) -> VendorManagement?
VendorManagement.openTarget: .application(URL) | .url(URL)
ResolvedInstallMethod(update:, vendorManagement:)   // .standard(InstallMethod) | .vendorManaged(VendorManagement)
  .standardMethod, .vendorManagement, .isAutomatic

// B1 / B3 (consumes the security agent's GatekeeperVerdict and HostChange directly)
AppAnalysisInput(..., installedGatekeeperVerdict: GatekeeperVerdict? = nil,
                 updateGatekeeperVerdict: GatekeeperVerdict? = nil,
                 downloadHostChange: HostChange? = nil, vendorManagement: VendorManagement? = nil)
CompatibilityAnalyzer.notarizationWarning(for: GatekeeperVerdict, scope: .update | .installedApp) -> AppWarning?
CompatibilityAnalyzer.downloadHostWarning(for: HostChange) -> AppWarning
```

Severity: `.notNotarized` = critical for `.update`, info for `.installedApp` (both for
`.rejected` and `.developerIDNotNotarized`; `.notarized`/`.unknown` → none).
`.downloadHostChanged` = info. `.managedByVendor` = info.

Definitions in `CoverageReport`: *tracked* = `matchedSource != nil`; *untracked* = no match
**and** no errors; *failed* = any errors (may also be tracked via `fallbackSource`).

## Integration snippets

### 1. View model (UpdatesViewModel — owner of `checkResults`)

```swift
// Stored dependency (AppEnvironment): let vendorDetector = VendorManagementDetector()
var coverageReport: CoverageReport? {
    checkResults.isEmpty ? nil : CoverageReport(
        results: Array(checkResults.values),
        ignoredBundleIdentifiers: Set(ignoredApps.map(\.bundleIdentifier)) // whatever `ignore(_:)` persists
    )
}

func vendorManagement(for app: InstalledApp) -> VendorManagement? {
    vendorManagementCache[app.bundleIdentifier]   // fill once per scan: detector.detect(app) (does file I/O)
}

func resolvedInstallMethod(for update: AvailableUpdate) -> ResolvedInstallMethod {
    ResolvedInstallMethod(update: update, vendorManagement: vendorManagement(for: update.app))
}

func openVendorUpdater(_ management: VendorManagement) {
    switch management.openTarget {
    case .application(let url): NSWorkspace.shared.openApplication(at: url, configuration: .init())
    case .url(let url): NSWorkspace.shared.open(url)
    }
}

func reportMissingApp(_ app: InstalledApp) async {
    let team: String? = if case .signed(let id) = await services.detailsReader.details(for: app).signature { id } else { nil }
    if let url = MissingAppReport(app: app, teamIdentifier: team).issueURL() { NSWorkspace.shared.open(url) }
}
```

### 2. Install routing (`UpdatesViewModel+Install.swift`)

```swift
enum InstallRoute: Equatable { …; case vendorUpdater(VendorManagement) }

func installRoute(for update: AvailableUpdate) async -> InstallRoute {
    switch resolvedInstallMethod(for: update) {
    case .vendorManaged(let management): return .vendorUpdater(management)
    case .standard(.appStore): return .appStore
    case .standard(.automatic): return .inPlace
    case .standard(.installerPackage):
        let status = await refreshHelperStatus()
        return status == .enabled && services.packageInstaller != nil ? .helperPackage : .installerApp
    }
}
// in install(_:): case .vendorUpdater(let m): openVendorUpdater(m); return
```

`UpdatesViewModel.installableUpdates` / `isUnattended`: exclude vendor-managed updates
(`resolvedInstallMethod(for:).vendorManagement == nil`). `UpdatePolicy.swift:40` should
likewise refuse auto-install when vendor-managed (pass `ResolvedInstallMethod` or check
`isAutomatic`).

### 3. UpdateRowView / AppDetailBanner

```swift
switch viewModel.resolvedInstallMethod(for: update) {
case .vendorManaged(let m): "Open \(m.updaterName)"          // title
case .standard(.automatic): …                                  // existing cases unchanged
}
// help: "\(m.updaterName) manages updates for this app"
// action: viewModel.openVendorUpdater(m)
```

AppDetailView / All Apps row: when `vendorManagement(for: app) != nil`, show a small
badge `Label("Managed by \(m.updaterName)", systemImage: "arrow.triangle.2.circlepath.circle")`
and route the primary button to `openVendorUpdater`. Add `.managedByVendor` to the app's
warnings by passing `vendorManagement:` into `AppAnalysisInput` in `InsightsCollector`
(I did not edit it; it currently builds inputs without the new fields).

### 4. Sidebar (`MainWindowView.swift`)

```swift
enum SidebarItem { …; case coverage }        // title: "Coverage"
// Sidebar, next to Insights:
Label("Coverage", systemImage: "scope")
    .badge(viewModel.coverageReport?.untracked.count ?? 0)
    .tag(SidebarItem.coverage)
// detail:
case .coverage:
    CoverageView(
        report: viewModel.coverageReport,
        isLoading: viewModel.state == .checking,
        actions: CoverageActions(
            mapGitHubRepo: { app in openSettingsGitHubMappings(prefill: app.bundleIdentifier) },
            searchHomebrew: { app in CoverageConstants.homebrewSearchURL(for: app.name).map { NSWorkspace.shared.open($0) } },
            reportMissing: { app in Task { await viewModel.reportMissingApp(app) } },
            ignore: { app in viewModel.ignore(app) },
            selectApp: { detailApp = $0 }
        ),
        onRefresh: { Task { await viewModel.refresh() } }
    )
```

### 5. Security agent (GatekeeperAssessor / DownloadHostStore)

```swift
if let w = services.compatibility.notarizationWarning(for: verdict, scope: .update) { /* surface; NotarizationGate decides blocking */ }
if let change = hostStore.check(update) { let w = services.compatibility.downloadHostWarning(for: change) }
```

## Caveats

- `CoverageConstants.issueRepository` is a placeholder; change it to the real `owner/repo`.
- `MissingAppReport` never includes paths or the feed URL (only "SUFeedURL: yes/no"); it
  also redacts `$HOME`, `/Users/<x>` and the user name (word-boundary) from every field,
  strips control characters, caps fields at 120 chars and the URL at 4 000 chars.
- Detector heuristics: Adobe requires a Creative Cloud install marker; MAU requires
  `/Library/Application Support/Microsoft/MAU2.0` (VS Code excluded); Keystone only for
  Chrome / Drive / Earth bundle prefixes; Setapp also matches bundle ids ending `-setapp`
  and Info.plist keys starting with `Setapp`. App Store apps are never vendor-managed.
  `detect` does file I/O — call it once per scan off the main actor and cache.
- `.notNotarized` / `.downloadHostChanged` reuse the security agent's
  `GatekeeperVerdict` and `HostChange` types; if those are renamed, update
  `SecurityAnalysisInputs.swift` and `CompatibilityAnalyzer.swift`.
- `InsightsWarningsSection` needs no change (it colors by severity only); the new kinds
  have `symbolName`s.
