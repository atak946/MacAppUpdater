# Round 2 — Policies: soak period (B2), install conditions (C3), version ceiling (D3)

All core types live in `AppUpdaterCore`. Existing APIs are source compatible; stored JSON
written before this round (`updatePolicies`, `exclusionRules`) still decodes (tested).

## Public API

### `UpdatePolicies` (Preferences/UpdatePolicy.swift)
New fields (all defaulted in `init`, decoded with `decodeIfPresent`):
- `deferralDays: Int` (0…30, clamped; `UpdatePolicies.maxDeferralDays == 30`)
- `deferralOverrides: [String: Int]` (bundle ID → days)
- `conditions: InstallConditions`

New methods: `deferralDays(for:)`, `hasDeferralOverride(for:)`, `settingDeferralDays(_:)`,
`settingDeferral(_ days: Int?, for:)` (`nil` removes), `settingConditions(_:)`.
`setting(_:for:)` / `settingDefault(_:)` / `shouldAutoInstall(_:)` unchanged (and preserve the new fields).

### `InstallConditions`, `QuietHours` (Preferences/InstallConditions.swift)
`InstallConditions(requireACPower = false, avoidExpensiveNetwork = false, avoidConstrainedNetwork = false, quietHours: QuietHours? = nil, skipRunningApps = true)`;
copies via `with(requireACPower:avoidExpensiveNetwork:avoidConstrainedNetwork:skipRunningApps:)` and `withQuietHours(_:)`.
`QuietHours(startHour:endHour:)` — local hours, start inclusive / end exclusive, wraps across midnight
when `start > end`, `start == end` means "never quiet". `contains(_:calendar:)`, `end(after:calendar:)`.

### `ExclusionRules` (Preferences/ExclusionRules.swift)
- `versionCeilings: [String: String]` — "5" keeps 5.x (incl. 5.0b1), "5.2" keeps 5.2.x.
- `isExcluded(_:)` is now also true when `newVersion` exceeds the ceiling.
- `exclusionReason(for:) -> String?` (English, user facing), `ceiling(for:)`,
  `capping(_ bundleID, at: String?)` (`nil`/blank removes), `static exceeds(_:ceiling:)`.
- `including(_:)` also clears the ceiling.

### `ReleaseDate`, `FirstSeenStore` (Preferences/FirstSeenStore.swift)
- `ReleaseDate { date, kind: .published | .firstSeen }`, `ReleaseDate.resolve(for:firstSeen:)`.
- `protocol FirstSeenRecording: Sendable { record(_:) async -> [String: ReleaseDate]; releaseDate(for:) async -> ReleaseDate? }`
- `actor FirstSeenStore(defaults: .standard, key: "firstSeenDates", retention: 180 days, now:)`.
  `record(_:)` stores unseen `bundleID@version` keys with "now", prunes superseded versions of
  offered apps and entries older than `retention`, and returns release dates keyed by `AvailableUpdate.id`.

### System conditions (AutoInstall/SystemConditions.swift)
- `NetworkStatus { isSatisfied, isExpensive, isConstrained }`
- `SystemConditionsSnapshot { isOnACPower, network: NetworkStatus?, runningBundleIdentifiers, now, calendar }`
- `protocol SystemConditionsProvider: Sendable { func snapshot() async -> SystemConditionsSnapshot }`
- `LiveSystemConditionsProvider(networkTimeout: .seconds(2), now:, calendar:)` — IOKit power source
  (no battery / unknown ⇒ AC), one-shot `NWPathMonitor` (timeout ⇒ `network == nil`),
  `NSWorkspace.shared.runningApplications` on the main actor.

### Planner (AutoInstall/AutoInstallPlanner.swift)
- `AutoInstallVerdict`: `.install`, `.defer(until: Date, reason: String)`, `.skip(reason: String)`; `.reason`.
- `AutoInstallDecision { update, verdict, shouldInstall }`.
- `AutoInstallInput(updates:policies:exclusions:conditions:releaseDates:isCompatible:isUrgent:)`
  (`isCompatible` default `true`, `isUrgent` default `false`).
- `AutoInstallPlanner().plan(_:) -> [AutoInstallDecision]` (same order as input),
  `verdict(for:input:)`, `eligibleDate(for:input:)`, `releaseDate(for:input:)`.
- `AutoInstallPlanner.daysRemaining(until:from:calendar:)`, `AutoInstallPlanner.hint(for:now:calendar:)`
  → `"Auto-installs in N days"` / `"Auto-installs within a day"` for `.defer`, else `nil`.

Rule order: install method (App Store / pkg ⇒ skip, never installed) → policy → exclusions
(incl. ceiling) → compatibility → soak period (skipped when `isUrgent`) → quiet hours (defer) →
AC power → network → running app. Urgent updates bypass only the soak period.

## Integration snippets

### 1. Services (UpdatesViewModel.swift, `UpdateServices`)
```swift
var conditions: any SystemConditionsProvider = LiveSystemConditionsProvider()
var firstSeen: any FirstSeenRecording = FirstSeenStore()
```
`runningApps` stays for other callers; the planner uses the snapshot's running set.

### 2. Record first-seen dates after each check (UpdatesViewModel, end of `refresh()` / wherever `allUpdates` is set)
```swift
// After a successful check:
releaseDates = await services.firstSeen.record(found)
```
with a stored property on the view model:
```swift
private(set) var releaseDates: [String: ReleaseDate] = [:]
```
Record on manual and scheduled checks so the first-seen clock starts when the update is first seen.

### 3. Replace `autoInstallCandidates` (UpdatesViewModel+History.swift)
```swift
func autoInstallDecisions(from updates: [AvailableUpdate], policies: UpdatePolicies) async -> [AutoInstallDecision] {
    let input = AutoInstallInput(
        updates: updates,
        policies: policies,
        exclusions: exclusions,
        conditions: await services.conditions.snapshot(),
        releaseDates: releaseDates,
        isCompatible: { [compatibility = services.compatibility] in
            compatibility.updateCompatibilityWarning(for: $0) == nil
        }
    )
    let decisions = AutoInstallPlanner().plan(input)
    for decision in decisions where !decision.shouldInstall {
        logger.info("Auto-install \(decision.update.app.name, privacy: .public): \(decision.verdict.reason ?? "", privacy: .public)")
    }
    lastAutoInstallDecisions = Dictionary(decisions.map { ($0.update.id, $0) }, uniquingKeysWith: { $1 })
    return decisions
}

func runScheduledCheck() async -> [AvailableUpdate] {
    let found = await refresh()          // refresh() already recorded first-seen dates
    let decisions = await autoInstallDecisions(from: found, policies: services.policies.load())
    for decision in decisions where decision.shouldInstall {
        await install(decision.update)
    }
    return found.filter { installState(for: $0) != .installed }
}
```
If `CompatibilityAnalyzer` is not `Sendable`, compute the incompatible IDs first and capture the set:
```swift
let incompatible = Set(updates.filter { compatibilityWarning(for: $0) != nil }.map(\.id))
// isCompatible: { !incompatible.contains($0.id) }
```
Add `private(set) var lastAutoInstallDecisions: [String: AutoInstallDecision] = [:]`.
Tests in `UpdatesViewModelTests` that asserted the old "app is running" skip need a stub
`SystemConditionsProvider` (e.g. `struct FixedConditions: SystemConditionsProvider { let value: SystemConditionsSnapshot; func snapshot() async -> SystemConditionsSnapshot { value } }`).

### 4. Hint in UpdateRowView / AppDetailView
Add to the view model:
```swift
func autoInstallHint(for update: AvailableUpdate) -> String? {
    let policies = services.policies.load()
    guard policies.shouldAutoInstall(update), !exclusions.isExcluded(update) else { return nil }
    let input = AutoInstallInput(
        updates: [update], policies: policies, exclusions: exclusions,
        conditions: SystemConditionsSnapshot(), releaseDates: releaseDates
    )
    let planner = AutoInstallPlanner()
    return AutoInstallPlanner.hint(for: planner.verdict(for: update, input: input), now: Date())
}

func releaseDateLabel(for update: AvailableUpdate) -> String? {
    guard let release = releaseDates[update.id] ?? ReleaseDate.resolve(for: update, firstSeen: nil) else { return nil }
    let day = release.date.formatted(date: .abbreviated, time: .omitted)
    return release.kind == .published ? "Released \(day)" : "First seen \(day)"
}
```
(`SystemConditionsSnapshot()` = permissive defaults so the hint reflects only the soak period.)
In `UpdateRowView`, under the version line:
```swift
if let hint = viewModel.autoInstallHint(for: update) {
    Label(hint, systemImage: "clock.badge.checkmark")
        .font(.caption)
        .foregroundStyle(.secondary)
}
```
Same in `AppDetailView` next to the update banner, plus `releaseDateLabel(for:)` in the info grid.

### 5. Version ceiling UI (AppDetailView context menu / toolbar menu)
View model:
```swift
func setCeiling(_ prefix: String?, for app: InstalledApp) {
    applyExclusions(exclusions.capping(app.bundleIdentifier, at: prefix))
}
```
AppDetailView (inside the existing actions `Menu`):
```swift
Menu("Stay on version") {
    let major = app.shortVersion.split(separator: ".").first.map(String.init) ?? app.shortVersion
    let minor = app.shortVersion.split(separator: ".").prefix(2).joined(separator: ".")
    Button("Stay on \(major).x") { viewModel.setCeiling(major, for: app) }
    if minor != major { Button("Stay on \(minor).x") { viewModel.setCeiling(minor, for: app) } }
    if let ceiling = viewModel.exclusions.ceiling(for: app.bundleIdentifier) {
        Divider()
        Button("Remove \(ceiling).x ceiling") { viewModel.setCeiling(nil, for: app) }
    }
}
```
`ExcludedView` / `MainWindowView` excluded count: consider adding `exclusions.versionCeilings.count`
and listing ceilings with an "Allow newer versions" button calling `setCeiling(nil, for:)`.

### 6. Per-app deferral (optional)
`UpdatePoliciesView` exposes only the global stepper. For a per-app value, e.g. in AppDetailView:
```swift
Stepper(value: Binding(
    get: { policies.deferralDays(for: app.bundleIdentifier) },
    set: { save(policies.settingDeferral($0, for: app.bundleIdentifier)) }
), in: 0...UpdatePolicies.maxDeferralDays) { Text("Wait \(policies.deferralDays(for: app.bundleIdentifier)) days") }
```

`UpdatePoliciesView` init is unchanged (`policies`, `installedApps`, `icon`, `onChange`), so
`SettingsTabs` needs no change; the new sections emit through `onChange`. The view grew taller —
consider raising `PoliciesSettingsTab`'s `.frame(height: 520)` to ~640.

## Caveats
- `isUrgent` has no data source yet; pass a predicate once a source flags security releases
  (e.g. Sparkle `sparkle:criticalUpdate`).
- Without a published date and without first-seen recording, the soak starts "now" on every
  run — always call `firstSeen.record(_:)` after checks.
- Unknown network state (monitor timeout) blocks installs only when a network condition is on.
- Quiet hours use the snapshot calendar's time zone (`Calendar.current` in production).
- First-seen dates live in UserDefaults key `firstSeenDates` (non-sensitive).
- The new UI strings are not yet in `Localizable.xcstrings` (auto-extracted on next Xcode build).
