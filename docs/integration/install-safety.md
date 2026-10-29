# Install safety: rollback, relaunch, history, download progress & cancel

Core pieces live in `AppUpdaterCore` (`Install/`, `Download/`, `History/`), plus one new
standalone view `Sources/AppUpdater/UI/History/UpdateHistoryView.swift`. Nothing here is wired
into the app yet; this document gives the exact snippets.

## Public API

### Rollback (`Install/AppBackup.swift`, `Install/BackupStore.swift`)

```swift
public struct AppBackup: Sendable, Hashable, Identifiable, Codable {
    bundleIdentifier, appName, version, createdAt, bundleURL
}
public struct BackupRetentionPolicy { init(maxBackupsPerApp: Int = 1, maxAge: TimeInterval = 14 days); static let default }
public protocol AppBackupStoring: Sendable {
    @discardableResult func backUp(_ app: InstalledApp) async throws -> AppBackup
    func backups(for bundleIdentifier: String) async throws -> [AppBackup]   // newest first
    func restore(_ backup: AppBackup, over app: InstalledApp) async throws
    func delete(_ backup: AppBackup) async throws
    func pruneAll() async throws
}
public actor BackupStore: AppBackupStoring {
    init(baseDirectory: URL = BackupStore.defaultBaseDirectory,   // ~/Library/Application Support/MacAppUpdater/Backups
         retention: BackupRetentionPolicy = .default,
         commandRunner:, signatureVerifier:, terminator:, relauncher:,  // all defaulted
         relaunchAfterRestore: Bool = true, now: @Sendable () -> Date = Date())
}
```

Layout: `<base>/<bundleID>/<oldVersion>/<Name>.app` + `backup.json`. Copies use `ditto`
(signatures, xattrs preserved). Bundle id / version are sanitised before use as path components.

`restore` does: checks the backup lives inside `baseDirectory` and belongs to `app.bundleIdentifier`
→ backup team id must equal the installed app's team id (`UpdaterError.teamIdentifierMismatch`
otherwise) → stages a copy next to the app → quits the app → atomic `replaceItemAt` → **deletes the
consumed backup** → relaunches if the app was running.

### Installer (`Install/AppInstaller.swift`) — source compatible

```swift
AppInstaller(commandRunner:, signatureVerifier:, terminator:, fileManager:,
             backupStore: (any AppBackupStoring)? = BackupStore(),   // nil = no backups
             relauncher: any AppRelaunching = WorkspaceAppRelauncher(),
             relaunchAfterInstall: Bool = true)
```

Order: stage → validate (bundle id + team id) → **backup** → quit → atomic swap → relaunch.
A backup failure throws `UpdaterError.installFailed("Backup ... failed: …")` before the app is quit.
Relaunch failures are only logged (the install already succeeded).

### Relaunch (`Install/RunningAppTerminator.swift`, `Install/AppRelauncher.swift`)

```swift
protocol RunningAppTerminating {
    func terminateRunningInstances(of:) async throws            // unchanged
    func quitRunningInstances(of:) async throws -> Bool         // new; default impl returns false
}
public protocol AppRelaunching: Sendable { func relaunch(_ appURL: URL) async throws }
public struct WorkspaceAppRelauncher: AppRelaunching   // NSWorkspace.openApplication(at:configuration:), activates = false
```

### History (`History/UpdateHistoryStore.swift`)

```swift
public struct UpdateHistoryEntry: Sendable, Hashable, Identifiable, Codable {
    enum Outcome { case succeeded, failed(message: String), rolledBack }
    id, bundleID, appName, fromVersion, toVersion, source: UpdateSourceKind?, date, outcome
    init(update: AvailableUpdate, outcome: Outcome, date: Date = Date())
    init(rollbackOf app: InstalledApp, to backup: AppBackup, date: Date = Date())
}
public actor UpdateHistoryStore {
    init(fileURL: URL = UpdateHistoryStore.defaultFileURL,   // ~/Library/Application Support/MacAppUpdater/UpdateHistory.json
         maxEntries: Int = 500)
    func entries() -> [UpdateHistoryEntry]                    // newest first
    func entries(for bundleID: String) -> [UpdateHistoryEntry]
    func record(_ entry: UpdateHistoryEntry) throws
    func clear() throws
}
```

Atomic writes; a corrupt file is renamed to `UpdateHistory.json.corrupt` and history restarts empty.

### Download progress & cancel (`Download/ProgressDownloader.swift`)

```swift
public protocol ProgressReportingDownloading: UpdateDownloading {
    func download(_ update: AvailableUpdate, progress: @escaping @Sendable (Double) -> Void) async throws -> URL
}
public struct ProgressDownloader: ProgressReportingDownloading {
    init(publicEDKey: @escaping UpdateDownloader.PublicKeyLookup = { _ in nil },
         configuration: URLSessionConfiguration = .default)
}
```

HTTPS only (non-HTTPS redirects refused), non-2xx → `UpdaterError.network("HTTP <code> for <url>")`,
same SHA-256/EdDSA verification as `UpdateDownloader` (shared internal `DownloadVerifier`).
Cancelling the calling `Task` cancels the `URLSessionDownloadTask` and throws `CancellationError`.
`progress` is called on a URLSession queue with values in `0...1` (none if the server sends no
Content-Length), always ending with `1`.

## Wiring

### AppEnvironment

```swift
let backupStore = BackupStore()
let history = UpdateHistoryStore()
let viewModel = UpdatesViewModel(
    scanner: AppScanner(),
    checker: checker,
    downloader: ProgressDownloader(publicEDKey: Self.sparklePublicKey),
    installer: AppInstaller(backupStore: backupStore),
    backupStore: backupStore,
    history: history
)
// in start():
Task { try? await backupStore.pruneAll() }   // applies 14-day retention at launch
Task { await viewModel.loadHistory() }
```

`UpdateDownloader.PublicKeyLookup` and `ProgressDownloader.PublicKeyLookup` are the same type, so
`sparklePublicKey` can stay as is.

### UpdatesViewModel

```swift
// Stored properties
private(set) var downloadProgress: [AvailableUpdate.ID: Double] = [:]
private(set) var backups: [String: AppBackup] = [:]          // bundleID -> newest backup
private(set) var history: [UpdateHistoryEntry] = []
private var installTasks: [AvailableUpdate.ID: Task<Void, Never>] = [:]
private let backupStore: (any AppBackupStoring)?
private let historyStore: UpdateHistoryStore?

// init: add `backupStore: (any AppBackupStoring)? = nil, history: UpdateHistoryStore? = nil`
// and assign them to the two lets above.

func progress(for update: AvailableUpdate) -> Double? { downloadProgress[update.id] }
func backup(for app: InstalledApp) -> AppBackup? { backups[app.bundleIdentifier] }

/// Replace the `.automatic` branch of `install(_:)` with:
///     case .automatic: await runCancellable(update) { await self.installAutomatically(update) }
private func runCancellable(_ update: AvailableUpdate, _ work: @escaping @MainActor () async -> Void) async {
    let task = Task { await work() }
    installTasks = installTasks.merging([update.id: task]) { _, new in new }
    await task.value
    installTasks = installTasks.filter { $0.key != update.id }
    downloadProgress = downloadProgress.filter { $0.key != update.id }
}

func cancelInstall(_ update: AvailableUpdate) {
    installTasks[update.id]?.cancel()
}

private func download(_ update: AvailableUpdate) async throws -> URL {
    guard let progressing = downloader as? any ProgressReportingDownloading else {
        return try await downloader.download(update)
    }
    let id = update.id
    return try await progressing.download(update) { fraction in
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.downloadProgress = self.downloadProgress.merging([id: fraction]) { _, new in new }
        }
    }
}
```

In `installAutomatically` (and `downloadAndOpenInstaller`):

```swift
let downloaded = try await download(update)          // instead of downloader.download(update)
try Task.checkCancellation()                         // don't start installing after Cancel
...
try await installer.install(update, from: downloaded)
setInstallState(.installed, for: update)
await recordHistory(UpdateHistoryEntry(update: update, outcome: .succeeded))
await refreshBackup(for: update.app)

// add before the generic `catch`:
} catch is CancellationError {
    logger.info("Install of \(update.app.name, privacy: .public) cancelled")
    setInstallState(.pending, for: update)
} catch {
    ...existing failure handling...
    await recordHistory(UpdateHistoryEntry(update: update, outcome: .failed(message: error.localizedDescription)))
}
```

Rollback, history and backup helpers:

```swift
func revertToPreviousVersion(_ app: InstalledApp) async {
    guard let backupStore, let backup = backups[app.bundleIdentifier] else { return }
    do {
        try await backupStore.restore(backup, over: app)
        await recordHistory(UpdateHistoryEntry(rollbackOf: app, to: backup))
        backups = backups.filter { $0.key != app.bundleIdentifier }
        await refresh()                                  // installed version changed
    } catch {
        logger.error("Rollback of \(app.name, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
        state = .failed("Could not revert \(app.name): \(error.localizedDescription)")   // or a dedicated alert
    }
}

func refreshBackups() async {                            // call at the end of refresh()
    guard let backupStore else { return }
    var found: [String: AppBackup] = [:]
    for app in installedApps {
        if let newest = try? await backupStore.backups(for: app.bundleIdentifier).first {
            found[app.bundleIdentifier] = newest
        }
    }
    backups = found
}

private func refreshBackup(for app: InstalledApp) async {
    guard let backupStore else { return }
    let newest = try? await backupStore.backups(for: app.bundleIdentifier).first
    backups = backups.filter { $0.key != app.bundleIdentifier }.merging(newest.map { [app.bundleIdentifier: $0] } ?? [:]) { _, new in new }
}

func loadHistory() async {
    history = await historyStore?.entries() ?? []
}

func clearHistory() async {
    do { try await historyStore?.clear() } catch {
        logger.error("Clearing history failed: \(error.localizedDescription, privacy: .public)")
    }
    await loadHistory()
}

private func recordHistory(_ entry: UpdateHistoryEntry) async {
    guard let historyStore else { return }
    do { try await historyStore.record(entry) } catch {
        logger.error("Recording history failed: \(error.localizedDescription, privacy: .public)")
    }
    history = await historyStore.entries()
}
```

### UpdateRowView — progress + Cancel

Add to the row inputs `let progress: Double?` and to `UpdateRowActions` `let cancel: () -> Void`
and `let revert: (() -> Void)?` (nil when there is no backup). Replace the `.downloading, .installing` case:

```swift
case .downloading:
    HStack(spacing: 6) {
        if let progress {
            ProgressView(value: progress)
                .progressViewStyle(.linear)
                .frame(width: 70)
            Text(progress, format: .percent.precision(.fractionLength(0)))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        } else {
            Text("Downloading").font(.caption).foregroundStyle(.secondary)
            ProgressView().controlSize(.small)
        }
        Button("Cancel", systemImage: "xmark.circle.fill", action: actions.cancel)
            .labelStyle(.iconOnly)
            .buttonStyle(IconButtonStyle())
            .help("Cancel download")
    }
case .installing:
    HStack(spacing: 6) {
        Text("Installing").font(.caption).foregroundStyle(.secondary)
        ProgressView().controlSize(.small)
    }
```

Context menu (after "Show in Finder"):

```swift
if let revert = actions.revert {
    Button("Revert to Previous Version", systemImage: "arrow.uturn.backward", action: revert)
}
```

Call site (UpdatesListView):

```swift
UpdateRowView(
    update: update, icon: viewModel.icon(for: update.app),
    installState: viewModel.installState(for: update),
    progress: viewModel.progress(for: update),
    actions: UpdateRowActions(
        install: { Task { await viewModel.install(update) } },
        reveal: { viewModel.revealInFinder(update) },
        openDownloadPage: { viewModel.openDownloadPage(update) },
        skipVersion: { viewModel.skipVersion(of: update) },
        ignoreApp: { viewModel.ignore(update.app) },
        cancel: { viewModel.cancelInstall(update) },
        revert: viewModel.backup(for: update.app).map { _ in { Task { await viewModel.revertToPreviousVersion(update.app) } } }
    )
)
```

Also add the revert entry to the installed-apps table context menu (`InstalledAppsTable`), keyed by `app`.

### AppDetailView

In `UpdateBanner.actions`, replace `case .downloading, .installing:`:

```swift
case .downloading:
    HStack(spacing: 8) {
        if let progress = viewModel.progress(for: update) {
            ProgressView(value: progress).frame(width: 120)
        } else {
            ProgressView().controlSize(.small)
        }
        Button("Cancel") { viewModel.cancelInstall(update) }
    }
case .installing:
    ProgressView().controlSize(.small)
```

In `footer`, next to "Show in Finder":

```swift
if let backup = viewModel.backup(for: app) {
    Button("Revert to \(backup.version)", systemImage: "arrow.uturn.backward") {
        Task { await viewModel.revertToPreviousVersion(app) }
    }
    .help("Restore the version that was installed before the last update (backed up \(backup.createdAt.formatted(.relative(presentation: .named))))")
}
```

Consider a confirmation dialog: the app is quit during revert.

### History sidebar item (MainWindowView)

```swift
enum SidebarItem { ...; case history }          // title: "History"
// SidebarView: Label("History", systemImage: "clock.arrow.circlepath").tag(SidebarItem.history)
// detail switch:
case .history:
    UpdateHistoryView(
        entries: viewModel.history,
        onClear: { Task { await viewModel.clearHistory() } },
        onSelect: { entry in
            if let app = viewModel.installedApps.first(where: { $0.bundleIdentifier == entry.bundleID }) {
                viewModel.revealInFinder(app)
            }
        },
        externalSearchText: searchText          // reuse the window's search field
    )
```

`UpdateHistoryView` groups entries by day (newest first), shows outcome icons
(green check / red octagon / orange u-turn), the failure message, and filters by app name,
bundle id or version. Without `externalSearchText` it installs its own `.searchable`.

## Caveats

- **Disk usage**: one full bundle copy per updated app (e.g. Xcode-sized apps). Retention keeps 1
  per app and drops backups older than 14 days, but only when `pruneAll()` runs or the app is
  updated again — call `pruneAll()` at launch.
- **Restore consumes the backup** (it is deleted after a successful swap); a second revert is not possible.
- **Revert quits the running app** (same terminator as install) and relaunches it if it was running.
- **Unsigned / ad-hoc apps**: `CodeSignatureVerifier` throws for bundles without a team id, so such
  apps can neither be updated (existing behaviour) nor restored.
- **App Store / pkg** installs do not go through `AppInstaller`, so they get no backup.
- **Data migrations**: rolling back the bundle does not roll back the app's preferences/data; a newer
  app may have migrated them in a way the old version can't read. Worth a warning in the UI.
- **Cancel** only affects the download phase. Once `.installing`, `ditto`/swap run to completion
  (the swap is atomic either way). Show the Cancel button only for `.downloading`.
- **Progress callbacks** arrive off the main actor and may be frequent; the snippet hops to the main
  actor per callback. Throttle (e.g. only publish on ≥1% change) if lists get sluggish.
- **ISO-8601 dates** in the history file have one-second precision.
- `BackupStore` and `AppInstaller` must share the same `BackupStore` instance (actor serialises
  file work per store).
