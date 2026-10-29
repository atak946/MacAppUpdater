# Uninstaller integration

Files (all new, nothing existing was modified):

- `Sources/AppUpdaterCore/Uninstall/LeftoverScanner.swift` — `LeftoverItem`, `LeftoverScanner`
- `Sources/AppUpdaterCore/Uninstall/LeftoverRules.swift` — the allowlist (internal)
- `Sources/AppUpdaterCore/Uninstall/AppUninstaller.swift` — `AppUninstaller`
- `Sources/AppUpdaterCore/Uninstall/UninstallModels.swift` — `UninstallPlan`, `UninstallReport`, `RunningAppChecking`, `Trashing`
- `Sources/AppUpdaterCore/Uninstall/UninstallError.swift` — `UninstallError`
- `Sources/AppUpdater/UI/Uninstall/UninstallSheet.swift` (+ `UninstallSheetComponents.swift`)
- Tests: `LeftoverScannerTests.swift`, `AppUninstallerTests.swift`, `UninstallTestSupport.swift`

## Public API

```swift
let uninstaller = AppUninstaller()                       // real home, NSRunningApplication, FileManager.trashItem
uninstaller.refusal(for: app) -> UninstallError?          // sync: system app / updater itself / bad id → hide or disable the button
await uninstaller.isRunning(app) -> Bool
try await uninstaller.scan(app) -> UninstallPlan          // dry run, never modifies anything
try await uninstaller.uninstall(plan, selected: Set<URL>) -> UninstallReport

UninstallPlan:  app, bundle (LeftoverItem .appBundle), leftovers, items, defaultSelection, totalSize(of:)
UninstallReport: trashed [(item, trashURL?)], failures [(url, error, reason)], reclaimedBytes, removedAppBundle, succeeded
LeftoverItem:   url, kind (Kind.displayName), sizeInBytes, confidence (.exact / .possible)
```

`scan`/`uninstall` use typed throws (`throws(UninstallError)`). `uninstall` throws for whole-operation
refusals (`systemApp`, `protectedApp`, `appIsRunning`, `nothingSelected`); per-item problems end up in
`report.failures`.

## 1. ViewModel helper (UpdatesViewModel.swift)

```swift
// stored property
private let uninstaller = AppUninstaller()

func canUninstall(_ app: InstalledApp) -> Bool { uninstaller.refusal(for: app) == nil }
func uninstallPlan(for app: InstalledApp) async throws -> UninstallPlan { try await uninstaller.scan(app) }
func uninstall(_ plan: UninstallPlan, selected: Set<URL>) async throws -> UninstallReport {
    try await uninstaller.uninstall(plan, selected: selected)
}
func quit(_ app: InstalledApp) async throws {
    try await RunningAppTerminator().terminateRunningInstances(of: app.bundleIdentifier)
}
/// Call after the sheet reports a finished uninstall.
func didUninstall(_ report: UninstallReport) {
    guard report.removedAppBundle else { return }
    Task { await refresh() }   // rescans installedApps; the removed app disappears
}
```

## 2. AppDetailView footer

```swift
@State private var isUninstalling = false

// in `footer`, after the Ignore button:
if viewModel.canUninstall(app) {
    Button("Uninstall…", systemImage: "trash") { isUninstalling = true }
}

// on the root VStack:
.sheet(isPresented: $isUninstalling) {
    uninstallSheet(for: app)
}
```

Shared builder (put it in an extension of the view, or a small helper both views use):

```swift
@MainActor
func uninstallSheet(for app: InstalledApp) -> some View {
    let vm = viewModel
    return UninstallSheet(
        app: app,
        icon: vm.icon(for: app),
        scan: { try await vm.uninstallPlan(for: app) },
        uninstall: { plan, selected in try await vm.uninstall(plan, selected: selected) },
        quitApp: { try await vm.quit(app) },
        onFinished: { report in vm.didUninstall(report) }
    )
}
```

After a successful uninstall, close the detail sheet too (the app no longer exists), e.g. in
`onFinished` set a flag and `dismiss()` the detail view once the uninstall sheet is dismissed.

## 3. All Apps context menu (UpdatesListView.swift `menu(for:)`)

```swift
@State private var uninstallApp: InstalledApp?

// in menu(for:), after the Ignore section:
if viewModel.canUninstall(app) {
    Divider()
    Button("Uninstall…", systemImage: "trash", role: .destructive) { uninstallApp = app }
}

// on the Table:
.sheet(item: $uninstallApp) { app in uninstallSheet(for: app) }
```

## Running apps

`uninstall` re-checks `NSRunningApplication` and throws `.appIsRunning` without touching anything.
The sheet shows an orange banner; if `quitApp` is supplied it offers "Quit <App>", after which the user
presses "Move to Trash…" again. Do not quit apps silently.

## Safety model / caveats

- Only `FileManager.trashItem` is used (via `Trashing`); nothing is deleted permanently.
- Matching is exact: `<id>`, `<id>.plist`, `<id>.<HOST-UUID>.plist` (ByHost), `<id>.savedState`,
  `<id>.binarycookies`, LaunchAgents `<id>[.*].plist` only when the plist `Label == id`.
  `Application Support/<Name>`, `Caches/<Name>`, `Logs/<Name>` and `Group Containers/<TEAMID>.<id>`
  are `.possible` and unchecked by default. No substring or prefix matches.
- Allowlist (direct children only): `~/Library/{Application Support, Caches, Preferences, Preferences/ByHost,
  Containers, Group Containers, Saved Application State, Logs, HTTPStorages, WebKit, Cookies, LaunchAgents}`.
- Before trashing, every selected URL must be in the plan and is re-validated (still in the allowlist,
  not a symlink, parent does not resolve outside `~/Library`); the app bundle must still be the same
  bundle id. If the app bundle fails to trash, leftovers are kept.
- Refused: bundle ids starting with `com.apple.`, apps under `/System/`, `com.macappupdater.app` and
  `Bundle.main.bundleIdentifier`.
- App Store apps: allowed; Trash works for them (Launchpad-style deletion isn't needed).
- `~/Library/Containers` and `Group Containers` are TCC-protected on macOS 14+: trashing them may
  fail (or prompt for "App Management"/"access data from other apps"); the failure shows in the report.
- Apps in `/Applications` owned by root may fail with a permission error; the report shows it. No
  privileged helper is used for uninstall.
- A trashed LaunchAgent stays loaded until logout; we do not call `launchctl`.
- System-wide leftovers (`/Library/...`, receipts, kernel/system extensions) are deliberately out of scope.
