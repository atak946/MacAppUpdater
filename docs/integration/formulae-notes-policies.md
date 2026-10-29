# Integration: Homebrew formulae, release notes, update policies

All new types compile and are tested (`swift test --filter "HomebrewCLI|ReleaseNotes|UpdatePolic"`).
Nothing below is wired yet; these are the edits the integrator should make.

## New files

| File | Purpose |
|------|---------|
| `Sources/AppUpdaterCore/Homebrew/HomebrewCLI.swift` | `OutdatedFormula`, `HomebrewError`, `HomebrewFormulaManaging`, `HomebrewCLI` |
| `Sources/AppUpdaterCore/ReleaseNotes/ReleaseNotesLoader.swift` | `ReleaseNotesContent`, `ReleaseNotesError`, `ReleaseNotesLoading`, `ReleaseNotesLoader` |
| `Sources/AppUpdaterCore/Preferences/UpdatePolicy.swift` | `UpdatePolicy`, `UpdatePolicies`, `UpdatePoliciesStoring`, `UserDefaultsUpdatePoliciesStore` |
| `Sources/AppUpdater/UI/Formulae/FormulaeModel.swift` | `@MainActor @Observable FormulaeModel` |
| `Sources/AppUpdater/UI/Formulae/FormulaeView.swift` | `FormulaeView(model:)` |
| `Sources/AppUpdater/UI/ReleaseNotes/ReleaseNotesView.swift` | `ReleaseNotesView(notes:loader:)`, `MarkdownRenderer` |
| `Sources/AppUpdater/UI/ReleaseNotes/ReleaseNotesWebView.swift` | `ReleaseNotesWebView` (WKWebView, JS off), `ReleaseNotesHTML` (CSP + CSS) |
| `Sources/AppUpdater/UI/Settings/UpdatePoliciesView.swift` | `UpdatePoliciesView`, `UpdatePolicy.title` |
| `Tests/AppUpdaterCoreTests/{HomebrewCLI,ReleaseNotesLoader,UpdatePolicy}Tests.swift` | 33 tests |

No `Package.swift` change needed (WebKit is a system framework, auto-linked via `import WebKit`).

## Public API (AppUpdaterCore)

```swift
// Homebrew formulae (CLI tools, not casks)
public struct OutdatedFormula: Sendable, Hashable, Identifiable, Decodable {
    name: String, installedVersions: [String], currentVersion: String, pinned: Bool
    var installedVersion: String          // last installed, for display
}
public enum HomebrewError: Error { case notInstalled, invalidFormulaName(String), pinned(String) }
public protocol HomebrewFormulaManaging: Sendable {
    var isAvailable: Bool { get }
    func outdatedFormulae() async throws -> [OutdatedFormula]
    func upgrade(_ name: String) async throws
}
public struct HomebrewCLI: HomebrewFormulaManaging {
    init(runner: any CommandRunner = ProcessCommandRunner(),
         candidatePaths: [String] = ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"],
         isExecutable: @escaping @Sendable (String) -> Bool = FileManager.isExecutableFile)
    var brewPath: String?
    static func isValidFormulaName(_:) -> Bool
    static func parseOutdated(_ output: String) throws -> [OutdatedFormula]
}

// Release notes
public enum ReleaseNotesContent: Sendable, Equatable {
    case html(String, baseURL: URL?), markdown(String), plainText(String), empty
}
public enum ReleaseNotesError: Error { case insecureURL(URL), tooLarge(bytes:limit:), invalidEncoding }
public protocol ReleaseNotesLoading: Sendable { func load(_ notes: ReleaseNotes) async throws -> ReleaseNotesContent }
public struct ReleaseNotesLoader: ReleaseNotesLoading {
    init(httpClient: any HTTPClient = URLSessionHTTPClient(), maxBytes: Int = 1_048_576)
}

// Update policies
public enum UpdatePolicy: String, Sendable, Codable, CaseIterable { case notifyOnly, autoInstall }
public struct UpdatePolicies: Sendable, Codable, Equatable {
    init(defaultPolicy: UpdatePolicy = .notifyOnly, overrides: [String: UpdatePolicy] = [:])
    func policy(for bundleID: String) -> UpdatePolicy
    func hasOverride(for bundleID: String) -> Bool
    func setting(_ policy: UpdatePolicy?, for bundleID: String) -> UpdatePolicies  // nil = remove override
    func settingDefault(_ policy: UpdatePolicy) -> UpdatePolicies
    func shouldAutoInstall(_ update: AvailableUpdate) -> Bool  // false for .appStore / .installerPackage
}
public protocol UpdatePoliciesStoring: Sendable { func load() -> UpdatePolicies; func save(_:) throws }
public struct UserDefaultsUpdatePoliciesStore: UpdatePoliciesStoring  // key "updatePolicies"
```

## 1. Sidebar item "Command Line Tools" → `FormulaeView`

`MainWindowView.swift`:

```swift
enum SidebarItem: Hashable {
    case updates, allApps, source(UpdateSourceKind), excluded
    case commandLineTools                                   // NEW

    var title: String {
        switch self {
        // ...
        case .commandLineTools: "Command Line Tools"
        }
    }
}

// SidebarView.body, e.g. after the "Sources" section:
Section("Homebrew") {
    row(.commandLineTools, symbol: "terminal", count: formulaeModel.formulae.count)
}

// detail switch:
case .commandLineTools:
    FormulaeView(model: formulaeModel)
```

Own a single model in `AppEnvironment` (so state survives sidebar switches) and pass it down:

```swift
// AppEnvironment
let formulaeModel = FormulaeModel(homebrew: HomebrewCLI())
```

`FormulaeView` refreshes itself on first appearance (`state == .idle`) and has Refresh / Upgrade All
toolbar buttons; it renders its own "Homebrew not installed" state with a brew.sh link.

## 2. Release notes

### In `AppDetailView`, below the banner

```swift
UpdateBanner(app: app, viewModel: viewModel)
    .padding(.horizontal, 24)
    .padding(.bottom, 16)
if let update = viewModel.update(for: app), let notes = update.releaseNotes {
    GroupBox("What's New in \(update.newVersion)") {
        ReleaseNotesView(notes: notes, loader: releaseNotesLoader)
            .frame(height: 200)
    }
    .padding(.horizontal, 24)
    .padding(.bottom, 16)
}
Divider()
```

The sheet is a fixed 520x600, so raise the height (around 760) or shrink the info grid when notes are shown.

### Popover from `UpdateRowView`

```swift
@State private var showsNotes = false

// in the HStack, before `action`:
if update.releaseNotes != nil {
    Button { showsNotes.toggle() } label: {
        Label("Release Notes", systemImage: "doc.text").labelStyle(.iconOnly)
    }
    .buttonStyle(IconButtonStyle())
    .help("What's new in \(update.newVersion)")
    .popover(isPresented: $showsNotes, arrowEdge: .trailing) {
        ReleaseNotesView(notes: update.releaseNotes)
            .frame(width: 420, height: 360)
    }
}

// contextMenu: keep the existing releaseNotesURL entry, and add
if update.releaseNotes != nil {
    Button("What's New…", systemImage: "doc.text.magnifyingglass") { showsNotes = true }
}
```

`loader` defaults to `ReleaseNotesLoader()` (a new `URLSessionHTTPClient`). To share the app's
client, create `let releaseNotesLoader = ReleaseNotesLoader(httpClient: http)` in `AppEnvironment`
and pass it in.

## 3. Scheduler: auto-install after a background check

`AppEnvironment.init`:

```swift
let policyStore: any UpdatePoliciesStoring = UserDefaultsUpdatePoliciesStore(defaults: defaults)

self.scheduler = UpdateScheduler(interval: ...) {
    let updates = await viewModel.refresh()
    let policies = policyStore.load()            // read fresh on every run, Settings may have changed
    let (automatic, manual) = updates.partitioned(by: policies.shouldAutoInstall)
    for update in automatic {                     // sequential: avoids parallel mounts/terminations
        await viewModel.install(update)
    }
    await notifier.notifyUpdatesAvailable(manual)
    // Optional: notify "Updated X, Y" for `automatic` whose installState == .installed.
}

private extension Array {
    func partitioned(by predicate: (Element) -> Bool) -> ([Element], [Element]) {
        (filter(predicate), filter { !predicate($0) })
    }
}
```

`UserDefaultsUpdatePoliciesStore` is `@unchecked Sendable` (UserDefaults is thread-safe), so it can be
captured in the `@Sendable` work closure. `viewModel.install` is `@MainActor`; the closure awaits it.
Only run auto-install from the **scheduled** path, never from a manual "Check Now". Ignored or skipped
updates are already removed by `refresh()`, so exclusions still take precedence.

Auto-installing quits the running app (`RunningAppTerminator`). Consider skipping apps that are
currently running (`NSRunningApplication.runningApplications(withBundleIdentifier:)`) and leaving
them as notifications.

## 4. Settings tab for policies

`AppUpdaterApp.swift`, turn `Settings` into a `TabView`:

```swift
Settings {
    TabView {
        SettingsView(onIntervalChange: appDelegate.environment.reschedule(hours:))
            .tabItem { Label("General", systemImage: "gearshape") }
        PoliciesSettingsTab(environment: appDelegate.environment)
            .tabItem { Label("Automatic Updates", systemImage: "bolt.badge.automatic") }
    }
}
```

`UpdatePoliciesView` does not persist anything itself. Give it a value and save the value it returns:

```swift
struct PoliciesSettingsTab: View {
    let environment: AppEnvironment
    @State private var policies = UserDefaultsUpdatePoliciesStore().load()

    var body: some View {
        UpdatePoliciesView(
            policies: policies,
            installedApps: environment.viewModel.installedApps,
            icon: environment.viewModel.icon(for:),
            onChange: { updated in
                policies = updated
                try? UserDefaultsUpdatePoliciesStore().save(updated)   // or log the error with os.Logger
            }
        )
        .frame(width: 460, height: 520)
    }
}
```

App Store apps are filtered out of the per-app list, because they can never be auto-installed.

## Caveats

- **brew env**: `CommandRunner` can't set environment variables, so brew runs as
  `/usr/bin/env HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_INSTALL_CLEANUP=1 HOMEBREW_NO_ENV_HINTS=1 <brew> …`.
  The app's PATH is minimal under launchd. brew mostly copes with this, but formulae with
  post-install scripts may want a fuller PATH.
- **stderr is merged** by `ProcessCommandRunner`, so `parseOutdated` parses from the first `{` to the
  last `}`. Warnings that themselves contain braces could still break it; such output fails with a
  clear `.parsing` error instead of returning wrong data.
- **Name validation**: `^[A-Za-z0-9][A-Za-z0-9@+._-]*(/…){0,2}$`, max 128 chars, no `..`.
  Upgrades run `brew upgrade --formula -- <name>`, with the name as a separate argv entry and no shell.
- **Pinned formulae** are listed but not upgradable (`HomebrewError.pinned`), and Upgrade All skips them.
  Upgrades run one at a time because brew holds a global lock.
- `brew upgrade` can take minutes and has no cancellation or progress percentage. The UI shows an
  indeterminate spinner per row.
- **Release-notes size cap** is checked after `HTTPClient.data(from:)` returns, because the protocol has no
  streaming or limit. A huge response is fully downloaded and then rejected. A real streaming cap would need
  a new `HTTPClient` method.
- Remote notes are classified by extension: `.md` → markdown, `.txt` → plain, anything else → HTML,
  using the page URL as `baseURL` for relative images and links.
- **WKWebView hardening**: `allowsContentJavaScript = false` (both config and per-navigation),
  non-persistent data store, a CSP meta tag (`default-src 'none'`, https images/styles/fonts only,
  no frames/forms), and the main frame can't navigate after the initial load. Clicked http/https/mailto
  links open in the default browser, and other schemes are dropped and logged.
- The transparent background uses `setValue(false, forKey: "drawsBackground")`. This is widely used
  but not public API.
- **Markdown**: SwiftUI `Text` drops block-level presentation intents, so `MarkdownRenderer` rebuilds
  paragraph breaks, headings (bold/larger), list bullets and numbers, and monospaced code blocks from
  the `.full` parse. Tables and images are not rendered, but their text is kept.
- **Policies**: `shouldAutoInstall` is true only when `InstallMethod(update:) == .automatic`, so App Store
  and `.pkg` are never auto-installed whatever the overrides say. The default is `.notifyOnly`.
