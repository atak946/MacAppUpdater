# Round 2 integration: Electron + vendor feed sources, SHA-512, publishedAt

Owner scope: new `Sources/AppUpdaterCore/Sources/Electron*.swift`, `Vendor*.swift`, `ReleaseDateParser.swift`,
`Sources/AppUpdaterCore/Resources/vendor-feeds.json`, `Download/DownloadVerifier.swift`,
`UpdateDownloader.swift` / `ProgressDownloader.swift` (checksum plumbing only), `Package.swift`
(`AppUpdaterCore` now has `resources: [.process("Resources")]`). Sparkle / GitHub / App Store sources only
gained `publishedAt`. Nothing in `Models/*`, UI or `AppEnvironment` was changed.

## 1. AppEnvironment wiring

`UpdateChecker.sourcePriority` already orders `.appStore, .sparkle, .electron, .vendor, .github, .homebrew`,
so list order in the array does not matter, but keep it readable:

```swift
// stored properties
private let checksumStore = ChecksumStore()
/// Built once: definitions are bundled data.
private let vendorSource: VendorFeedSource

// init, before the view model
self.vendorSource = VendorFeedSource.bundled(http: http, comparator: comparator)

// view model downloader: SHA-512 digests registered by ElectronUpdateSource are verified here.
downloader: ProgressDownloader(publicEDKey: Self.sparklePublicKey, checksum: checksumStore.lookup),

// makeChecker(mappings:)
UpdateChecker(sources: [
    AppStoreSource(http: http, comparator: comparator),
    SparkleSource(http: http, comparator: comparator, allowedChannels: betaStore.channelProvider),
    ElectronUpdateSource(http: http, comparator: comparator, checksumStore: checksumStore),
    vendorSource,
    GitHubReleasesSource(
        repositories: mappings.repositories, http: http, comparator: comparator,
        token: tokenStore.tokenProvider
    ),
    homebrewSource,
])
```

The **same** `ChecksumStore` instance must be passed to `ElectronUpdateSource` and to every downloader
(`ProgressDownloader` / `UpdateDownloader`), otherwise electron downloads are only HTTPS-checked.
Note: `self.vendorSource` must be assigned before `makeChecker` is called (it is called at the end of `init`).
`checksumStore` is a `let` with an initial value, so it is available to the `downloader:` argument only
after phase-1 init; if the compiler complains, create it as a local `let checksumStore = ChecksumStore()`
and assign `self.checksumStore = checksumStore` like `http`.

## 2. UI / install handling needed

- `.vendor` + `openVendorUpdater` (Chrome): `downloadURL` is the vendor download page
  (`https://www.google.com/chrome/`). Treat it like App Store / manual guidance — open it, never download/install:
  ```swift
  let isManual = update.source == .appStore
      || vendorSource.installStrategy(for: update) == .openVendorUpdater
  ```
  `installStrategy(for:)` returns nil for non-vendor updates. Suggested copy: "Updated by Google's own
  updater — open Chrome or the download page".
- `.electron` and `.vendor` + `inPlace` (Firefox, JetBrains): normal download → `AppInstaller` flow
  (zip/dmg). The existing Team ID continuity check applies unchanged.
- `vendorSource.expectedTeamID(for: bundleID)` exposes the vendor's Team ID (Mozilla `43AQ936H96`,
  Google `EQHXZ8M8AV`, JetBrains `2ZEFAR8TH3`). Optional extra check for the installer owner: reject when the
  downloaded bundle's Team ID differs from it (useful on first install when no Team ID is stored yet).
- Source labels/icons for `.electron` ("Electron") and `.vendor` (use `definition(for:)?.name` or "Vendor feed").
- `AvailableUpdate.publishedAt` is now set by Sparkle (`pubDate`), GitHub (`published_at`),
  App Store (`currentVersionReleaseDate`), Electron (`releaseDate`) and vendor feeds with `publishedAtPath`.

## 3. Public API

| Type | Notes |
|------|-------|
| `ElectronUpdateSource(http:comparator:checksumStore: ChecksumStore? = nil, architecture: = .current)` | `SourceMatching`, kind `.electron`. `canHandle`: not App Store and `Contents/Resources/app-update.yml` exists. |
| `VendorFeedSource(definitions:http:comparator:architecture:)` | `SourceMatching`, kind `.vendor`. Invalid / non-HTTPS definitions dropped. |
| `VendorFeedSource.bundled(http:comparator:architecture:)` | Loads `vendor-feeds.json` from `Bundle.module`; logs and yields no definitions on failure. |
| `VendorFeedSource.bundledDefinitions() throws`, `.definitions(from: Data) throws` | Catalog decoding (for a future community manifest, A6). |
| `vendorSource.installStrategy(for: AvailableUpdate) -> VendorInstallStrategy?`, `definition(for:)`, `expectedTeamID(for:)` | |
| `VendorFeedDefinition` (Codable) | `bundleIdentifier, name, feedURL, format: .json/.xml, versionPath, downloadURLPath?, downloadURLPathArm64?, downloadURLTemplate? ({version}), publishedAtPath?, releaseNotesURLTemplate?, expectedTeamID?, installStrategy: .inPlace/.openVendorUpdater` |
| `ExpectedChecksum(algorithm: .sha256/.sha512, value:)` | `value` is hex or base64; malformed → mismatch (download rejected). `init?(sha256Of:)`, `digestBytes`. |
| `typealias ChecksumLookup = @Sendable (AvailableUpdate) async -> ExpectedChecksum?` | `ExpectedChecksum.updateSHA256` = old behaviour (default). |
| `actor ChecksumStore` | `register(_:forUpdateID:)`, `checksum(forUpdateID:)`, `removeChecksum(forUpdateID:)`, `nonisolated var lookup` (store entry, else `update.sha256`). Keyed by `AvailableUpdate.id`. |
| `UpdateDownloader(httpClient:publicEDKey:checksum:)`, `ProgressDownloader(publicEDKey:checksum:configuration:)` | New `checksum:` parameter, defaulted — existing call sites compile unchanged. |

## 4. Caveats

- **Resource bundle:** `AppUpdaterCore` now produces `MacAppUpdater_AppUpdaterCore.bundle`. `scripts/build-app.sh`
  already copies every `*.bundle` into `Contents/Resources`, so nothing to do there; verify the packaged app
  contains it (`Bundle.module` traps if it is missing). `PrivilegedHelper` never touches it.
- Electron: only `github`, `generic`, `s3`, `spaces` providers; others (`custom`, `keygen`, `snap`, private
  GitHub with token, `bitbucket`) → `.notFound`. The GitHub feed uses `releases/latest/download/…`, so file
  URLs resolve to the *latest* release; a release published between check and download would fail the
  SHA-512 check (safe failure, retry on next check). Squirrel.Mac apps without `app-update.yml` are not handled.
- Electron feeds with no `sha512` still produce an update (logged); the download is then only HTTPS-checked
  plus Team ID check at install.
- Version comparison uses `CFBundleShortVersionString` (electron-builder writes the package version there).
- Vendor: Firefox downloads the `en-US` build; users on other locales get English UI (Mozilla Mac builds are
  per-locale). Chrome is never installed by us (Keystone). JetBrains `IIC`/`PCC` were discontinued in 2025.3 and
  are intentionally not listed; Toolbox-managed IDEs may also be updated by Toolbox.
- Endpoints were verified live on 2026-10-28; tests use fixtures only.
- `ChecksumStore` grows by one entry per electron update found; entries are tiny, optionally call
  `removeChecksum(forUpdateID:)` after a successful install.
