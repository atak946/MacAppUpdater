# MacAppUpdater

A macOS menu bar app that discovers installed applications and keeps them up to date.

## Update sources

| Source | Detection | Install |
|---|---|---|
| Mac App Store | `Contents/_MASReceipt` | Opens App Store |
| Sparkle | `SUFeedURL` in `Info.plist` | Download + verify + replace |
| Homebrew Cask API | Matching `.app` artifact in `formulae.brew.sh` | Download + SHA-256 + replace |
| GitHub Releases | Configured `bundleId → owner/repo` mapping | Download + verify + replace |
| Electron (electron-builder) | `Contents/Resources/app-update.yml` | Download + SHA-512 + replace |
| Vendor feeds | Bundled `vendor-feeds.json` (Firefox, JetBrains IDEs, Chrome, …) | Replace, or open the vendor's updater (Chrome) |

Apps owned by a vendor updater (Setapp, Adobe Creative Cloud, Microsoft AutoUpdate, Google Keystone,
JetBrains Toolbox) are detected and routed to that updater instead of being installed.

## Features

- **Updates**: precise source per app (App Store, Sparkle incl. opt-in beta channel, GitHub Releases mappings, Homebrew Cask), release notes, download progress with cancel.
- **Safe installs**: signature + Team ID checks, a backup before each in-place update with one-click revert, and a history of every install, failure and rollback.
- **Policies**: per-app automatic installs after scheduled checks, planned by `AutoInstallPlanner`: soak period ("Auto-installs in N days", release / first-seen dates), quiet hours, AC power, network and running-app conditions, and version ceilings ("Stay on 5.x").
- **Managed (MDM)**: configuration-profile keys force check interval, policies, ignored apps, allowed sources and more; locked settings show a lock badge (`docs/mdm/`).
- **Coverage**: which apps a source tracks, which none does, and failed checks — with Map GitHub Repo, Search Homebrew, Report Missing App and Ignore actions.
- **Command Line Tools**: outdated Homebrew formulae with upgrade.
- **Insights**: largest, unused and Intel-only apps plus compatibility, signature, notarization, download-host-change and vendor-managed warnings.
- **Uninstall**: moves an app and its matching leftovers to the Trash.
- **Self-update** of App Updater via Sparkle.

## Architecture

```
Sources/
├── AppUpdaterCore/          # Testable library, no UI
│   ├── Models/              # Shared types + protocols (contract)
│   ├── Discovery/           # AppScanner, BundleInfoReader, AppDetailsReader
│   ├── Versioning/          # VersionComparator
│   ├── Sources/             # App Store, Sparkle, Electron, vendor feeds, GitHub, Homebrew, UpdateChecker
│   ├── Resources/           # vendor-feeds.json (MacAppUpdater_AppUpdaterCore.bundle)
│   ├── Download/            # ProgressDownloader, DownloadVerifier (checksums, EdDSA, quarantine), CodeSignatureVerifier
│   ├── Install/             # AppInstaller (dmg/zip), backups, process runner
│   ├── Helper/              # Privileged helper client + .pkg validation
│   ├── Security/            # Gatekeeper/notarization gate, download host tracking
│   ├── Preferences/         # Policies, exclusions, version ceilings, install conditions, first-seen dates
│   ├── AutoInstall/         # AutoInstallPlanner, system conditions (power, network, running apps)
│   ├── Managed/             # MDM configuration, managed store decorators, policy gate
│   ├── Coverage/            # Coverage report, missing-app report, vendor-management detection
│   ├── Insights/            # CompatibilityAnalyzer, InsightsCollector, warnings
│   ├── History/             # Install history
│   ├── Uninstall/           # Uninstaller + leftover rules
│   ├── Homebrew/            # brew CLI (formulae)
│   ├── ReleaseNotes/        # Release notes loader
│   └── Scheduler/           # Background checks, notifications
├── AppUpdater/              # SwiftUI app (composition root in AppEnvironment.swift)
│   └── UI/                  # Main window, menu bar, Settings, Coverage, Insights, Managed, History, …
└── PrivilegedHelper/        # launchd daemon that installs .pkg updates
```

## Security model

Threats considered: a compromised update feed or host, same-user local malware, and other local
users. The full review and the status of each finding are in
[`docs/review/review-report.md`](docs/review/review-report.md).

**Download**
- Only `https` downloads and https-only redirects are accepted; feed and API bodies are size-capped
  (8 MB feeds, 64 MB Homebrew index) and `Authorization` is dropped on cross-host redirects.
- Formats are allowlisted: `dmg`/`zip` install in place, `pkg`/`mpkg` go through the helper or
  Installer.app. Anything else (or an extension-less URL) only opens the vendor's page — the file is
  never downloaded or opened.
- SHA-256 (Homebrew) and SHA-512 (electron-builder) are verified when published. A Sparkle update for
  an app that ships `SUPublicEDKey` **must** carry a valid EdDSA signature.
- Every download gets a `com.apple.quarantine` attribute in a private (0700) folder.
- A changed download host (registrable domain) is shown as a warning. GitHub's release CDNs
  (`release-assets.` / `objects.githubusercontent.com`) count as github.com; user-content hosts
  (`raw.githubusercontent.com`, `*.github.io`, …) do not.

**In-place install (dmg/zip)**
- The update is pinned to one Developer ID team: the installed app's Apple-anchored team, and/or the
  source's curated `expectedTeamID`. They must agree; with neither (an unsigned or ad-hoc installed
  app and no pin) the update is refused and must be installed manually.
- The staged bundle must satisfy an Apple-anchored requirement for that team (Developer ID or Mac App
  Store chain, nested code), be newer than the installed version, and match the advertised version.
- Gatekeeper: `.notarized` passes; a rejection (e.g. revoked certificate) always blocks; "not
  notarized" or "could not confirm" (often offline) blocks unless Settings › General › "Allow updates
  that aren't notarized (warn)" is on. MDM `RequireNotarization` forces it off, and a toggle changed
  outside the app counts as off until confirmed in Settings. Non-notarized installs keep quarantine.
- Signed DMGs are verified before mounting; zips are size-checked before extraction.
- Staging is private (0700); the signature is re-checked right before the atomic swap and the
  installed bundle is verified afterwards, with automatic rollback.
- Rollback ("Revert") treats backups as untrusted and applies the same team, Gatekeeper and
  post-swap checks.

**Privileged helper (.pkg)**
- The app passes an open, read-only file descriptor plus the expected team over XPC; the helper copies
  it into a root-only folder and accepts only a **notarized Developer ID Installer** package from that
  team (never Apple-signed, never "any Developer ID"). Notarization is always required for packages.
- Both ends pin each other by team ID, and the helper rejects debuggable app builds; a release build without a team
  (ad-hoc) refuses every connection. Installs are serialized and the helper exits when idle.

**Known limits:** same-user malware can still substitute an *older* notarized package or backup from
the same vendor, there is a microsecond race window around the swap, zip declared sizes are not a
hard limit, the "allow unnotarized" audit is tamper evidence (not a boundary), and the helper has no
launchd `SpawnConstraint` yet.

## Requirements

- macOS 14+, Xcode 16+ (Swift 6)
- Not sandboxed — distribute with Developer ID + notarization (not via the App Store).
- Users must grant **Privacy & Security → App Management** to modify other apps.
- `.pkg` installs run through a privileged helper (`SMAppService` launch daemon). Enable it in Settings → General; it requires a Developer ID–signed build and admin approval in Login Items. Without it, packages open in Installer.app.

## Build & run

```bash
make build      # swift build
make test       # swift test --parallel
make run        # swift run AppUpdater (Sparkle self-update stays inactive outside an .app)
make app        # scripts/build-app.sh -> build/AppUpdater.app (universal, ad-hoc signed)
open build/AppUpdater.app
```

`scripts/build-app.sh` builds a universal (arm64 + x86_64) release, falling back to the native
architecture if that fails (`ARCHS=native` forces it). It assembles:

```
AppUpdater.app/Contents/
├── Info.plist                      # Packaging/Info.plist with VERSION / BUILD substituted
├── MacOS/AppUpdater, PrivilegedHelper
├── Library/LaunchDaemons/com.macappupdater.helper.plist
├── Frameworks/Sparkle.framework
└── Resources/                      # SwiftPM resource bundle (+ AppIcon.icns if Packaging/AppIcon.icns exists)
```

Without `SIGN_IDENTITY` the bundle is ad-hoc signed so it runs locally. The privileged helper
cannot be used by an ad-hoc release build (it rejects every connection, and the app reports that
this build isn't signed with a Developer ID), so test `.pkg` updates with a Developer ID build.

## Release

One-time setup:

```bash
# Developer ID Application certificate in the login keychain, then:
xcrun notarytool store-credentials <profile> --apple-id <id> --team-id <team>
# Sparkle EdDSA keys (private key stays in the keychain); paste the public key
# into Packaging/Info.plist -> SUPublicEDKey, and set SUFeedURL to your appcast.
.build/artifacts/sparkle/Sparkle/bin/generate_keys
```

Each release:

```bash
export SIGN_IDENTITY="Developer ID Application: <NAME> (<TEAMID>)"
export NOTARY_PROFILE=<profile>
export VERSION=1.2.0            # BUILD defaults to the git commit count
make release                    # MAKE_DMG=1 make release also produces a notarized DMG
```

`scripts/release.sh` signs inside-out with hardened runtime + secure timestamp (Sparkle XPC
services, Autoupdate, Updater.app, Sparkle.framework, PrivilegedHelper, app), zips with
`ditto`, notarizes with `notarytool --wait`, staples, and prints the `generate_appcast` command
for publishing the Sparkle appcast. Identities and profiles are only read from the environment.
