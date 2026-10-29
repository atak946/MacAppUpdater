# Round 2 — Security (B1 notarization check, B3 download host change)

Owner: security agent. Files:

- `Sources/AppUpdaterCore/Security/GatekeeperVerdict.swift` — `GatekeeperVerdict`, `NotarizationPolicy`
- `Sources/AppUpdaterCore/Security/GatekeeperOutputParser.swift` — pure `spctl` / `stapler` output parser
- `Sources/AppUpdaterCore/Security/GatekeeperAssessor.swift` — `GatekeeperAssessing`, `SpctlGatekeeperAssessor`, `FixedGatekeeperAssessor`
- `Sources/AppUpdaterCore/Security/NotarizationGate.swift` — policy enforcement + `UpdaterError.isNotarizationBlock`
- `Sources/AppUpdaterCore/Security/RegistrableDomain.swift` — eTLD+1 heuristic + CDN families
- `Sources/AppUpdaterCore/Security/DownloadHostStore.swift` — `HostChange`, `DownloadHostStoring`, `UserDefaultsDownloadHostStore`
- `Sources/AppUpdaterCore/Install/AppInstaller.swift` — new pipeline step + init params (source compatible)
- Tests: `GatekeeperAssessorTests.swift`, `DownloadHostStoreTests.swift`, `AppInstallerTests.swift` (extended)

## Public API

```swift
public enum GatekeeperVerdict: Sendable, Hashable {
    case notarized                    // also Apple System / Mac App Store
    case developerIDNotNotarized
    case rejected(reason: String)
    case unknown(reason: String)      // never blocks
    public var summary: String
}

public enum NotarizationPolicy: String, Sendable, Codable, CaseIterable {
    case require, warnOnly, off
    public static let allowUnnotarizedDefaultsKey = "security.allowUnnotarizedUpdates"
    public static func fromSetting(allowUnnotarized: Bool) -> NotarizationPolicy   // true -> .warnOnly
}

public protocol GatekeeperAssessing: Sendable {
    func assess(_ bundleURL: URL) async -> GatekeeperVerdict
}
public struct SpctlGatekeeperAssessor: GatekeeperAssessing {
    public init(commandRunner: any CommandRunner = ProcessCommandRunner(),
                staplerPath: String? = SpctlGatekeeperAssessor.locateStapler())
}
public struct FixedGatekeeperAssessor: GatekeeperAssessing { public init(_ verdict: GatekeeperVerdict) }

public struct HostChange: Sendable, Hashable { bundleIdentifier, previous, current }
public protocol DownloadHostStoring: Sendable {
    func lastKnownHost(for bundleIdentifier: String) -> String?
    func check(_ update: AvailableUpdate) -> HostChange?
    func record(_ update: AvailableUpdate)
    func forget(_ bundleIdentifier: String)
}
public final class UserDefaultsDownloadHostStore: DownloadHostStoring {
    public init(defaults: UserDefaults = .standard, key: String = "security.lastKnownDownloadHosts")
}

extension UpdaterError {
    public static let notNotarizedPrefix = "Not notarized: "
    public var isNotarizationBlock: Bool
}
```

`AppInstaller.init` gained three trailing, defaulted params:

```swift
gatekeeperAssessor: any GatekeeperAssessing = SpctlGatekeeperAssessor(),
notarizationPolicy: @escaping @autoclosure @Sendable () -> NotarizationPolicy = .require,
downloadHostStore: (any DownloadHostStoring)? = nil
```

`notarizationPolicy` is an autoclosure, re-evaluated on every install, so a Settings
toggle takes effect without rebuilding the installer.

Pipeline: stage → bundle id → team id → **Gatekeeper/notarization** → backup → quit → swap →
relaunch → **record download host**. A block throws
`UpdaterError.signatureInvalid("Not notarized: <summary>")` before the running app is touched.

## Integration snippets

### 1. AppEnvironment wiring

```swift
let downloadHostStore = UserDefaultsDownloadHostStore(defaults: defaults)
let gatekeeper = SpctlGatekeeperAssessor()
// UserDefaults is thread-safe; capture the key, not a view-model property.
nonisolated(unsafe) let policyDefaults = defaults

let viewModel = UpdatesViewModel(
    scanner: AppScanner(),
    checker: UpdateChecker(sources: []),
    downloader: ProgressDownloader(publicEDKey: Self.sparklePublicKey),
    installer: AppInstaller(
        backupStore: backupStore,
        gatekeeperAssessor: gatekeeper,
        notarizationPolicy: NotarizationPolicy.fromSetting(
            allowUnnotarized: policyDefaults.bool(forKey: NotarizationPolicy.allowUnnotarizedDefaultsKey)
        ),
        downloadHostStore: downloadHostStore
    ),
    services: services
)
```

(If `UserDefaults` is already `Sendable` in the SDK in use, drop the `nonisolated(unsafe)` line.)

### 2. Settings toggle "Allow updates that aren't notarized (warn)"

```swift
@AppStorage(NotarizationPolicy.allowUnnotarizedDefaultsKey) private var allowUnnotarized = false

Toggle("Allow updates that aren't notarized (warn)", isOn: $allowUnnotarized)
Text("Off (recommended): updates Apple hasn't notarized are blocked. On: they install with a warning.")
    .font(.caption).foregroundStyle(.secondary)
```

Add the localizable keys for both strings.

### 3. Record download hosts after successful installs

In-place installs record automatically when `downloadHostStore` is passed to `AppInstaller`.
The helper `.pkg` path does not go through `AppInstaller`, so record it in
`UpdatesViewModel.completeInstall(_:)` (idempotent, safe to call for both paths):

```swift
private func completeInstall(_ update: AvailableUpdate) async {
    setInstallState(.installed, for: update)
    services.downloadHosts?.record(update)   // new UpdateServices field: (any DownloadHostStoring)?
    ...
}
```

Never call `record` on a failed install, otherwise a hijacked host would become the baseline.

### 4. Feed into CompatibilityAnalyzer

`AppAnalysisInput` (Insights agent) already uses these types directly:
`installedGatekeeperVerdict`, `updateGatekeeperVerdict: GatekeeperVerdict?`,
`downloadHostChange: HostChange?`. Mapping (done by the analyzer):
`.developerIDNotNotarized` / `.rejected` → `.notNotarized(reason:scope:)`; `.notarized` / `.unknown`
→ no warning; `HostChange` → `.downloadHostChanged(previous:current:)`.

In `InsightsCollector.insight(for:update:)` (add `hostStore` + `gatekeeper` to the collector init):

```swift
let input = AppAnalysisInput(
    app: app, details: details, update: update,
    lastUsedDate: lastUsed, previousTeamIdentifier: previous,
    installedGatekeeperVerdict: await gatekeeper?.assess(app.url),
    downloadHostChange: update.flatMap { hostStore?.check($0) }
)
```

`updateGatekeeperVerdict` is only known after download + staging (inside `AppInstaller`); leave
it `nil` in scans. If a pre-install warning is ever needed, assess the staged bundle in a
separate "verify download" step. Assessing every installed app runs one `spctl` per app
(~50–300 ms each, may hit the network): do it lazily for the detail view or cache per
`(bundleId, version)`, not on every scan of 200 apps.

### 5. Show error text when install is blocked

`handleInstallError` already shows `error.localizedDescription`
("Code signature invalid: Not notarized: Developer ID signed but not notarized"). For a clearer
message and a pointer to the toggle:

```swift
if let updaterError = error as? UpdaterError, updaterError.isNotarizationBlock {
    let message = "Blocked: Apple has not notarized this update. "
        + "You can allow it in Settings › Security (not recommended)."
    setInstallState(.failed(message), for: update)
    await recordHistory(UpdateHistoryEntry(update: update, outcome: .failed(message: message)))
    return
}
```

## Behaviour and caveats

- **spctl output** goes to stderr; `ProcessCommandRunner` merges stderr into stdout. A rejection
  exits with status 3, so the assessor parses the output carried by `UpdaterError.commandFailed`.
- **Source lines**: `Notarized Developer ID` → notarized; `Developer ID` / `Unnotarized Developer ID`
  → not notarized; `Apple System` / `Mac App Store` → notarized; `rejected` (any source) → rejected;
  anything else → unknown (logged, never blocks).
- **stapler**: `/usr/bin/stapler` and `/usr/bin/xcrun` are developer-tool shims that show a
  "install Command Line Tools" dialog on Macs without CLT. The assessor only uses the real binary in
  `/Library/Developer/CommandLineTools/usr/bin` or `Xcode.app/Contents/Developer/usr/bin`, and only
  when spctl did not already say notarized/rejected. A stapled ticket upgrades
  `.developerIDNotNotarized` / `.unknown` to `.notarized`; it never overrides `.rejected`. Many
  notarized apps are not stapled (online ticket), so "no ticket" is not treated as negative.
- **Quarantine**: `spctl --assess --type execute` evaluates the signature + notarization ticket
  regardless of the `com.apple.quarantine` xattr, so quarantined and non-quarantined copies give the
  same verdict. What differs is runtime: Gatekeeper only enforces at first launch of a quarantined
  bundle. Our downloads (URLSession) are not quarantined, so this pre-install check is the only
  Gatekeeper-equivalent gate — keep it on (`.require`) by default. Do not strip quarantine.
- **Network**: spctl may query Apple's notarization service for non-stapled tickets. Offline it
  can report a notarized app as `Developer ID` (not notarized); with `.require` that blocks the
  install with a clear message. Users can retry online or enable the toggle. `ProcessCommandRunner`
  has no timeout; spctl's own network timeout applies.
- **Gatekeeper disabled** (`spctl --master-disable`): spctl still prints its assessment; any
  unrecognised output becomes `.unknown` and does not block.
- `.warnOnly` installs even `.rejected` bundles (logged). The team-id check before it still
  rejects unsigned/ad-hoc and signer changes, so warnOnly only relaxes the notarization layer.
- **Host heuristic**: last two labels, three for known multi-part suffixes (`co.uk`, `com.au`,
  `co.jp`, …); IPv4 kept as is. `github.com`, `githubusercontent.com`, `github.io`,
  `githubassets.com` are one family. Not a full Public Suffix List: unknown ccTLD second levels
  may compare too coarsely (e.g. `a.gen.xx` vs `b.gen.xx` look equal). The warning is
  informational only; never block on it.
- `check(_:)` returns `nil` until a first successful install was recorded (no baseline).
