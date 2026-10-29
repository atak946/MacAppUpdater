# D1 — Managed preferences (MDM): integration note

New files only; nothing existing was edited.

- Core: `Sources/AppUpdaterCore/Managed/`
  - `ManagedPreferencesReader.swift` — `ManagedPreferencesReading`, `CFPreferencesManagedReader` (domain `com.macappupdater.app`, forced values only), `UnmanagedPreferencesReader`
  - `ManagedKey.swift` — every supported key
  - `ManagedConfiguration.swift` / `ManagedConfiguration+Parsing.swift` — validated snapshot
  - `ManagedExclusionRulesStore.swift`, `ManagedUpdatePoliciesStore.swift` — store decorators
  - `ManagedPolicyGate.swift` — feature gate helpers
- UI: `Sources/AppUpdater/UI/Managed/ManagedLockBadge.swift` (+ `.managedLock(_:)` modifier), `ManagedByOrganizationBanner.swift`
- Docs: `docs/mdm/README.md`, `docs/mdm/keys.md`, `docs/mdm/AppUpdater.mobileconfig`
- Tests: `Tests/AppUpdaterCoreTests/Managed{Configuration,Stores,PolicyGate,Support}Tests.swift`

## Public API

```swift
public protocol ManagedPreferencesReading: Sendable { func forcedValue(forKey: String) -> Any? }
public struct CFPreferencesManagedReader: ManagedPreferencesReading { init(domain: String = "com.macappupdater.app") }
public struct UnmanagedPreferencesReader: ManagedPreferencesReading

public enum ManagedKey: String, CaseIterable   // CheckIntervalHours, AutoInstallEnabled, ...

public struct ManagedConfiguration: Sendable, Equatable {
    static let unmanaged: ManagedConfiguration
    init(reader: any ManagedPreferencesReading)        // validates, logs, never throws
    let checkIntervalHours: Double?; autoInstallEnabled: Bool?; defaultPolicy: UpdatePolicy?
    let perAppPolicies: [String: UpdatePolicy]; ignoredBundleIdentifiers: Set<String>
    let deferralDays: Int?; requireACPower: Bool?; avoidExpensiveNetwork: Bool?
    let disableUninstaller: Bool?; disableBetaChannels: Bool?
    let allowedSources: Set<UpdateSourceKind>?; hideMenuBarIcon: Bool?; reportWebhookURL: URL?
    var isManaged: Bool                                 // any valid managed key → show banner
    func isManaged(_ key: ManagedKey) -> Bool
    var effectiveDefaultPolicy: UpdatePolicy?; var isDefaultPolicyLocked: Bool
    var isAutoInstallDisabled: Bool
    func isPolicyLocked(for bundleID: String) -> Bool
    func isIgnoreLocked(_ bundleID: String) -> Bool
}

public struct ManagedExclusionRulesStore: ExclusionRulesStoring {
    init(base: any ExclusionRulesStoring, configuration: ManagedConfiguration)
    var forcedIgnoredBundleIdentifiers: Set<String>; func isForced(_ bundleID: String) -> Bool
}
public struct ManagedUpdatePoliciesStore: UpdatePoliciesStoring {
    init(base: any UpdatePoliciesStoring, configuration: ManagedConfiguration)
    var isDeferralLocked: Bool
}
public struct ManagedPolicyGate: Sendable, Equatable {
    init(configuration: ManagedConfiguration)
    func isSourceAllowed(_ kind: UpdateSourceKind) -> Bool
    func allowedSources(_ sources: [any UpdateSource]) -> [any UpdateSource]
    var isUninstallerAllowed: Bool; var areBetaChannelsAllowed: Bool; var isMenuBarIconHidden: Bool
    func effectiveCheckInterval(userValue: Double) -> Double; var isCheckIntervalLocked: Bool
    func effectiveDeferralDays(userValue: Int) -> Int
    func effectiveRequireACPower(userValue: Bool) -> Bool
    func effectiveAvoidExpensiveNetwork(userValue: Bool) -> Bool
}
```

UI (AppUpdater target, internal): `ManagedLockBadge(help:)`, `View.managedLock(_ isLocked: Bool)`
(disables the control and appends the badge), `ManagedByOrganizationBanner(message:)`.

## Merge semantics

| Field | `load()` | `save()` |
|---|---|---|
| ignored ids | user ∪ forced | user ids only; a forced id is kept in storage only if the user had ignored it before |
| skipped / versionCeilings | user | user (passed through) |
| defaultPolicy | `DefaultPolicy` ?? `AutoInstallEnabled` ?? user | stored user value when locked |
| overrides | user (minus masked) merged with forced (forced wins) | incoming for unlocked apps; stored for forced apps and masked overrides |
| `AutoInstallEnabled=false` | masks user per-app `autoInstall` (forced per-app still applies) | masked stored overrides preserved |
| deferralDays / deferralOverrides | forced global, per-app user deferrals hidden | stored values when locked |
| conditions.requireACPower / avoidExpensiveNetwork | forced field wins | stored value for forced fields, incoming for the rest (quiet hours, skipRunningApps, constrained) |

Extension point when `ExclusionRules` / `UpdatePolicies` gain fields: pass them through in
`ManagedExclusionRulesStore.replacingIgnored(in:with:)` and the `UpdatePolicies(...)`
initialisers in `ManagedUpdatePoliciesStore.load()/save()`.

## 1. AppEnvironment — wrap stores

```swift
// new stored properties
let managed: ManagedConfiguration
let managedGate: ManagedPolicyGate
let exclusionStore: any ExclusionRulesStoring

// init(defaults:), first lines
let managed = ManagedConfiguration(reader: CFPreferencesManagedReader())
let gate = ManagedPolicyGate(configuration: managed)
let policyStore = ManagedUpdatePoliciesStore(
    base: UserDefaultsUpdatePoliciesStore(defaults: defaults), configuration: managed
)
let exclusionStore = ManagedExclusionRulesStore(
    base: UserDefaultsExclusionRulesStore(defaults: defaults), configuration: managed
)
self.managed = managed
self.managedGate = gate
self.exclusionStore = exclusionStore

// UpdatesViewModel(...): add `exclusionStore: exclusionStore`

// scheduler interval
self.scheduler = UpdateScheduler(
    interval: gate.effectiveCheckInterval(userValue: Self.storedIntervalHours(defaults)) * 3600
) { ... }

// reschedule(hours:)
scheduler.updateInterval(managedGate.effectiveCheckInterval(userValue: hours) * 3600)

// makeChecker(mappings:)
UpdateChecker(sources: managedGate.allowedSources([ ...existing sources... ]))
```

Beta channels: when `!managedGate.areBetaChannelsAllowed`, pass a provider that returns no
extra channels to `SparkleSource(allowedChannels:)` (e.g. `{ _ in [] }`, match the
existing `betaStore.channelProvider` signature).

Uninstaller: gate `UpdatesViewModel.canUninstall(_:)` with `managedGate.isUninstallerAllowed`
(inject a `Bool` / the gate into `UpdateServices` or the view model).

Menu bar: in the `App` scene, `MenuBarExtra(..., isInserted: .constant(!environment.managedGate.isMenuBarIconHidden))`.

## 2. UpdatesViewModel — reload after saving exclusions

Forced ignores are re-added by the store, so the in-memory value must come from `load()`:

```swift
private func applyExclusions(_ rules: ExclusionRules) {
    do {
        try exclusionStore.save(rules)
    } catch {
        logger.error("Saving exclusions failed: \(error.localizedDescription, privacy: .public)")
    }
    exclusions = exclusionStore.load()
}
```

Same for `PoliciesSettingsTab.save(_:)` in `SettingsTabs.swift`: after `store.save(updated)`
set `policies = store.load()` so forced values snap back.

## 3. SettingsTabs / SettingsView (General) — banner + interval lock

```swift
// SettingsTabs: pass to SettingsView
SettingsView(..., managed: environment.managed)

// SettingsView body, top of the Form
if managed.isManaged {
    Section { ManagedByOrganizationBanner() }
}
// interval picker
Picker("Check for updates", selection: ...) { ... }
    .managedLock(managed.isManaged(.checkIntervalHours))
// show the forced value instead of @AppStorage when locked:
// ManagedPolicyGate(configuration: managed).effectiveCheckInterval(userValue: intervalHours)
```

Also pass `managed` to `PoliciesSettingsTab` → `UpdatePoliciesView`.

## 4. UpdatePoliciesView

```swift
let managed: ManagedConfiguration   // new property, default `.unmanaged` at call sites/previews

Toggle("Install updates automatically", isOn: globalBinding)
    .managedLock(managed.isDefaultPolicyLocked)

PolicyOverrideRow(...)
    .managedLock(managed.isPolicyLocked(for: app.bundleIdentifier))
// when managed.isAutoInstallDisabled, remove `.autoInstall` from the per-app picker
// unless the app is policy-locked.

// deferral stepper / pickers (B2):
    .managedLock(managed.isManaged(.deferralDays))
// condition toggles (C3):
Toggle("Only on AC power", ...).managedLock(managed.isManaged(.requireACPower))
Toggle("Avoid expensive networks", ...).managedLock(managed.isManaged(.avoidExpensiveNetwork))
```

## 5. ExcludedView

```swift
// row(bundleID:detail:) trailing button
if viewModel.managed.isIgnoreLocked(bundleID) {   // expose `managed` on the view model or pass it in
    ManagedLockBadge(help: "Ignored by your organization")
} else {
    Button("Include Again") { viewModel.include(bundleID) }.controlSize(.small)
}
```

Skipped-version rows are never locked.

## 6. AppDetailView footer

```swift
if managed.isIgnoreLocked(app.bundleIdentifier) {
    Label("Ignored by your organization", systemImage: "lock.fill")
        .foregroundStyle(.secondary)
} else if viewModel.exclusions.isIgnored(app.bundleIdentifier) {
    Button("Stop Ignoring", systemImage: "eye") { viewModel.include(app.bundleIdentifier) }
} else {
    Button("Ignore Updates", systemImage: "eye.slash") { viewModel.ignore(app) }
}
// beta toggle: `.managedLock(!managedGate.areBetaChannelsAllowed)`
// uninstall button: also require `managedGate.isUninstallerAllowed`
```

Context menus on update rows ("Ignore", "Skip version") need the same check for "Include".

## Caveats

- Managed values are read once at launch (`ManagedConfiguration` is a value snapshot). Profile
  changes need a relaunch. If live updates are wanted later, observe
  `UserDefaults.didChangeNotification` / re-create the configuration and rebuild stores.
- `defaults write com.macappupdater.app …` does **not** simulate MDM: only forced values count.
  Tests use the in-memory `FakeManagedReader`; manual testing requires installing the profile
  (`docs/mdm/README.md`).
- The app's preferences domain is assumed to be `com.macappupdater.app` (the bundle id). If the
  bundle id differs, pass it to `CFPreferencesManagedReader(domain:)` and update the docs.
- `AllowedSources` fails open on an all-invalid list; every other invalid value is ignored and logged
  under subsystem `com.macappupdater`, category `Managed`.
- `ReportWebhookURL` is only parsed/validated (https, host, no credentials); D2 will consume
  `managed.reportWebhookURL`.
- `DeferralDays` range is `0…UpdatePolicies.maxDeferralDays` (30).
