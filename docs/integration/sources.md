# Integration: update sources (precise source, GitHub mappings, beta channel, release notes)

Owner scope: `Sources/AppUpdaterCore/Sources/*`, `Sources/AppUpdater/UI/Settings/GitHubMappingsView.swift`.
Nothing in `Models/*`, `Protocols.swift`, `Package.swift` or existing UI files was changed.

## Public API summary (AppUpdaterCore)

| Type | Purpose |
|------|---------|
| `enum SourceLookup { notFound, upToDate(latestVersion:), update(AvailableUpdate) }` | `.update` / `.isMatch` helpers |
| `protocol SourceMatching: UpdateSource { func lookup(_:) async throws -> SourceLookup }` | Implemented by `AppStoreSource`, `SparkleSource`, `GitHubReleasesSource`, `HomebrewCaskSource`. `checkForUpdate` delegates to `lookup`. |
| `struct UpdateCheckResult { app, matchedSource: UpdateSourceKind?, latestVersion: String?, update: AvailableUpdate?, errors: [String]; isUpToDate }` | `Identifiable` by bundle id |
| `UpdateChecker.checkAllDetailed(_:) async -> [UpdateCheckResult]` | One result per app, input order. `checkAll` unchanged (= `checkAllDetailed(...).compactMap(\.update)`). `checkDetailed(_:)` for a single app. |
| `GitHubRepositoryMappings` | Immutable `[bundleID: "owner/repo"]`; `adding(repository:for:) throws(GitHubMappingError)`, `removing(bundleIdentifier:)`, `normalizedRepository(_:)` (accepts `owner/repo`, `github.com/owner/repo`, `https://github.com/owner/repo.git`), `suggestions`, `suggestion(for:)` |
| `GitHubRepositoryStore(defaults:)` | `load()` / `save(_:) throws`, key `githubRepositoryMappings` |
| `protocol TokenStoring` + `KeychainTokenStore(service: "com.macappupdater.github", account: "api-token")` | `readToken/saveToken/deleteToken`; `tokenProvider` extension → `GitHubReleasesSource.TokenProvider` |
| `protocol HTTPRequestClient` | `data(from:headers:)`; `URLSessionHTTPClient` conforms |
| `GitHubReleasesSource(..., token: TokenProvider = { nil })` | Sends `Authorization: Bearer` only if token is non-empty and the client is an `HTTPRequestClient` |
| `SparkleSource(..., allowedChannels: ChannelProvider = SparkleSource.defaultChannelsOnly)` | `(InstalledApp) -> Set<String>`; default channel is always included |
| `BetaChannelStore(defaults:)` | `load`, `save`, `isOptedIn`, `setOptedIn(_:for:)`, `channelProvider` (reads live) |

Release notes populated on `AvailableUpdate`:
- Sparkle: `<description>` (CDATA HTML) → `.html`, else `sparkle:releaseNotesLink` → `.remote`; `sparkle:minimumSystemVersion` → `minimumSystemVersion`. `releaseNotesURL` remains the link.
- GitHub: release `body` → `.markdown` (blank → nil); `html_url` → `releaseNotesURL`.
- App Store: `releaseNotes` → `.markdown` (plain text), `minimumOsVersion` → `minimumSystemVersion`.
- Homebrew: none.

## 1. AppEnvironment: build sources from stores

```swift
let githubStore = GitHubRepositoryStore(defaults: defaults)
let tokenStore = KeychainTokenStore()
let betaStore = BetaChannelStore(defaults: defaults)

static func makeChecker(
    http: URLSessionHTTPClient, comparator: VersionComparator,
    mappings: GitHubRepositoryMappings, tokenStore: any TokenStoring, betaStore: BetaChannelStore
) -> UpdateChecker {
    UpdateChecker(sources: [
        AppStoreSource(http: http, comparator: comparator),
        SparkleSource(http: http, comparator: comparator, allowedChannels: betaStore.channelProvider),
        GitHubReleasesSource(
            repositories: mappings.repositories, http: http, comparator: comparator,
            token: tokenStore.tokenProvider
        ),
        HomebrewCaskSource(http: http, comparator: comparator),
    ])
}
```

Rebuilding when mappings change: `GitHubReleasesSource` captures the repository dictionary at init,
so the checker must be rebuilt. `UpdatesViewModel.checker` is currently a `let`; make it
`private(set) var` and add:

```swift
func replaceChecker(_ checker: any UpdateChecking) { self.checker = checker }
```

and in `AppEnvironment`:

```swift
func githubMappingsChanged(_ mappings: GitHubRepositoryMappings) {
    viewModel.replaceChecker(Self.makeChecker(http: http, comparator: comparator,
        mappings: mappings, tokenStore: tokenStore, betaStore: betaStore))
    Task { await viewModel.refresh() }
}
```

Token and beta opt-ins are read on every check, so they do **not** require a rebuild.
Note: `HomebrewCaskSource` keeps a per-instance cask index cache; rebuilding re-downloads
it once. To avoid that, keep one `HomebrewCaskSource` instance in `AppEnvironment` and reuse it
in `makeChecker`.

## 2. UpdatesViewModel: precise source per app

Extend the protocol (in `UpdatesViewModel.swift`):

```swift
protocol UpdateChecking: Sendable {
    func checkAll(_ apps: [InstalledApp]) async -> [AvailableUpdate]
    func checkAllDetailed(_ apps: [InstalledApp]) async -> [UpdateCheckResult]
}
```

`extension UpdateChecker: UpdateChecking {}` in `AppEnvironment` keeps working. Update test fakes
(e.g. in `Tests/AppUpdaterTests`) to implement `checkAllDetailed`.

In `refresh()` replace `checker.checkAll(apps)` with:

```swift
let results = await checker.checkAllDetailed(apps)
checkResults = Dictionary(uniqueKeysWithValues: results.map { ($0.app.bundleIdentifier, $0) })
let found = results.compactMap(\.update)
    .sorted { $0.app.name.localizedCaseInsensitiveCompare($1.app.name) == .orderedAscending }
```

with `private(set) var checkResults: [String: UpdateCheckResult] = [:]` and

```swift
func checkResult(for app: InstalledApp) -> UpdateCheckResult? { checkResults[app.bundleIdentifier] }
```

### AppDetailView "Update source" row

Pass `viewModel.checkResult(for: app)` into `AppInfoGrid` (new `let result: UpdateCheckResult?`) and
replace `sourceText`:

```swift
private var sourceText: String {
    guard let result else { return fallbackSourceText }      // not checked yet → old heuristic
    guard let kind = result.matchedSource else {
        return result.errors.isEmpty ? "No known source" : "Check failed (\(result.errors.count) error(s))"
    }
    let latest = result.latestVersion.map { " — latest \($0)" } ?? ""
    switch kind {
    case .sparkle: return "Sparkle — \(app.sparkleFeedURL?.host() ?? "feed")\(latest)"
    default: return "\(kind.displayName)\(latest)"
    }
}
```

(`fallbackSourceText` = the current implementation.) The detail `message` can also use
`result?.isUpToDate == true` to say "You're on the latest version (via X)" instead of guessing from
`sparkleFeedURL`. `result.errors` can be shown as a `.help(...)` tooltip.

### All Apps table

Add a "Source" column: `viewModel.checkResult(for: app)?.matchedSource?.displayName ?? "—"`
(sort key: `matchedSource?.rawValue ?? "~"`). Excluded apps have no result unless the view model
checks them; keep `—`.

## 3. Settings tab: GitHubMappingsView

`SettingsView` is a `Form`; wrap it in a `TabView` in `AppUpdaterApp`'s `Settings { }` scene (or
inside `SettingsView`):

```swift
Settings {
    TabView {
        SettingsView(onIntervalChange: environment.reschedule)
            .tabItem { Label("General", systemImage: "gearshape") }
        GitHubMappingsView(
            store: environment.githubStore,
            tokenStore: environment.tokenStore,
            installedApps: environment.viewModel.installedApps,
            onMappingsChange: environment.githubMappingsChanged
        )
        .tabItem { Label("GitHub", systemImage: "shippingbox") }
    }
}
```

`SettingsView` sets `.frame(width: 420)`; the GitHub tab uses width 520. The view loads mappings
from the store on appear, persists on every add/remove, and then calls `onMappingsChange`.
Installed apps list comes from the last scan (empty before the first refresh; App Store apps and
already-mapped apps are hidden). Picking an app with a known suggestion pre-fills owner/repo.

## 4. Beta channel per-app toggle

Place it in `AppDetailView` (actions / info area), only for Sparkle apps
(`app.sparkleFeedURL != nil && !app.isFromAppStore`):

```swift
Toggle("Include beta versions", isOn: Binding(
    get: { viewModel.isBetaOptedIn(app) },
    set: { viewModel.setBeta($0, for: app) }
))
.help("Uses the app's Sparkle \"beta\" channel when it publishes one.")
```

View model (inject `BetaChannelStore`):

```swift
private(set) var betaOptIns: Set<String>   // init: betaStore.load()
func isBetaOptedIn(_ app: InstalledApp) -> Bool { betaOptIns.contains(app.bundleIdentifier) }
func setBeta(_ enabled: Bool, for app: InstalledApp) {
    betaOptIns = betaStore.setOptedIn(enabled, for: app.bundleIdentifier)
    Task { await refresh() }
}
```

No checker rebuild needed: `betaStore.channelProvider` reads UserDefaults on every check.

## Caveats

- `matchedSource` semantics: the source that returned the update; otherwise the highest-priority
  source that recognised the app. A lower-priority source with a newer version still wins
  (unchanged fallthrough behaviour of `check`).
- Sparkle: a feed that downloads and parses is a match even with no eligible items
  (`latestVersion` = installed version then). A failing feed is an error, not a match.
- Homebrew: a cask with `version :latest` is a match with `latestVersion == "latest"`.
- GitHub: HTTP 404 / rate limiting (403) surface as `errors`, not `notFound`. Anonymous API limit is
  60 requests/hour per IP; the token raises it to 5000.
- Sources not conforming to `SourceMatching` (e.g. test fakes) only report update / no match.
- Token is never stored in UserDefaults; Keychain item uses
  `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`. Tokens with whitespace/control chars are
  rejected (header injection). Unsigned/ad-hoc builds may prompt for Keychain access after rebuilds.
- `.html` notes come from third-party feeds: render them sandboxed (no JavaScript) in the notes view.
- `GitHubRepositoryMappings.suggestions` is deliberately short (Rectangle, IINA, Alacritty, kitty,
  AltTab, KeePassXC, OBS, UTM, Obsidian); suggestions are only pre-filled, never auto-applied.
