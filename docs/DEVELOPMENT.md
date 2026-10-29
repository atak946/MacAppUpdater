# Development

Technical details that do not fit in the [README](../README.md): building, the app bundle, releases and the
README screenshots.

## Requirements

- macOS 14+, Xcode 16+ (Swift 6)
- Not sandboxed — distribute with Developer ID + notarization (not via the App Store).
- Users must grant **Privacy & Security → App Management** to modify other apps.
- `.pkg` installs run through a privileged helper (`SMAppService` launch daemon). Enable it in Settings → General; it requires a Developer ID–signed build and admin approval in Login Items. Without it, packages open in Installer.app.

## Build and run

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

## Releases

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

## README screenshots

The images in `docs/images/<lang>/` are rendered by the app itself from built-in demo data, so they never show
a real Mac's apps, processes or files:

```bash
scripts/render-screenshots.sh              # builds the app, renders English and Turkish
scripts/render-screenshots.sh --skip-build
```

The script runs the app binary with `--render-screenshots <dir>`. In that mode the app uses throwaway defaults
and demo data, starts no scans, update checks or network calls, renders each PNG and quits.

## MDM

Configuration-profile keys and a sample profile are in [docs/mdm](mdm/README.md).
