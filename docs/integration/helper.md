# Privileged helper integration (.pkg installs)

## Public API (AppUpdaterCore/Helper)

| Type | Purpose |
|---|---|
| `PrivilegedHelperProtocol` (`@objc`) | XPC contract: `installPackage(atPath:withReply:(Bool, String?))`, `version(withReply:(String))` |
| `HelperConstants` | `machServiceName` / label `com.macappupdater.helper`, `launchdPlistName` `com.macappupdater.helper.plist`, `helperCodeSigningIdentifier`, `appCodeSigningIdentifier` `com.macappupdater.app`, `helperVersion` |
| `HelperCodeSigning` | `currentTeamIdentifier()`, `requirement(identifier:teamIdentifier:)` |
| `HelperStatus` | `.notRegistered`, `.enabled`, `.requiresApproval`, `.notFound` |
| `HelperClientError` | typed client errors (`helperNotEnabled(HelperStatus)`, `timedOut`, `installFailed`, ...) |
| `PackageInstallService` | seam: `installPackage(at:) async throws` |
| `actor HelperClient: PackageInstallService` | `status`, `register() -> HelperStatus`, `unregister()`, `openApprovalSettings()`, `helperVersion()`, `isHelperUpToDate()`, `installPackage(at:)` |
| `PackageSignatureChecker` / `PackageSignature` | `pkgutil --check-signature` wrapper + pure `parse(_:)` |
| `HelperInstallRequestValidator` / `HelperInstallRequestError` | helper-side path validation (absolute, no `..`, `.pkg`, regular file, no symlink, owned by caller uid, under `/private/var/folders/` or `/private/tmp/MacAppUpdater/`) |
| `PackageInstaller: UpdateInstalling` | verifies pkg signature + team id vs. installed app, quits running app, calls the helper |

`PackageInstaller` throws `UpdaterError`: `.unsupportedFormat` (not pkg / App Store), `.signatureInvalid`, `.teamIdentifierMismatch`, `.installFailed` (all helper/XPC failures, including "helper not enabled").

## 1. AppEnvironment wiring

```swift
let helperClient = HelperClient()
let viewModel = UpdatesViewModel(
    scanner: AppScanner(),
    checker: checker,
    downloader: UpdateDownloader(httpClient: http, publicEDKey: Self.sparklePublicKey),
    installer: AppInstaller(),
    packageInstaller: PackageInstaller(installService: helperClient),
    helperClient: helperClient
)
```

Expose `helperClient` to Settings (e.g. `let helperClient: HelperClient` on `AppEnvironment`).

## 2. UpdatesViewModel routing

Add `private let packageInstaller: any UpdateInstalling` and `private let helperClient: HelperClient` (init params), then replace the `.installerPackage` branch:

```swift
case .installerPackage:
    if await helperClient.status == .enabled {
        await installPackage(update)
    } else {
        await downloadAndOpenInstaller(update)   // existing Installer.app fallback
    }
```

```swift
private func installPackage(_ update: AvailableUpdate) async {
    do {
        setInstallState(.downloading, for: update)
        let packageURL = try await downloader.download(update)
        defer { try? FileManager.default.removeItem(at: packageURL.deletingLastPathComponent()) }
        setInstallState(.installing, for: update)
        try await packageInstaller.install(update, from: packageURL)
        setInstallState(.installed, for: update)
    } catch {
        logger.error("Package install of \(update.app.name, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
        setInstallState(.failed(error.localizedDescription), for: update)
    }
}
```

Optionally include `.installerPackage` in `installableUpdates` when the helper is enabled (cache the status in a published property refreshed on launch / Settings appear).

## 3. Settings / onboarding hook

```swift
@State private var helperStatus: HelperStatus = .notRegistered

Section("Installer packages") {
    LabeledContent("Privileged helper", value: String(describing: helperStatus))  // localize as needed
    switch helperStatus {
    case .enabled:
        Button("Disable helper") { Task { try? await helperClient.unregister(); await refresh() } }
    case .requiresApproval:
        Text("Allow “MacAppUpdater” in System Settings → General → Login Items.")
        Button("Open Login Items") { helperClient.openApprovalSettings() }
    case .notRegistered:
        Button("Enable helper") {
            Task {
                helperStatus = (try? await helperClient.register()) ?? .notRegistered
                if helperStatus == .requiresApproval { helperClient.openApprovalSettings() }
            }
        }
    case .notFound:
        Text("Helper is missing from the app bundle (run from a packaged .app).")
    }
}
.task { await refresh() }
// Re-check when returning from System Settings:
.onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
    Task { await refresh() }
}

private func refresh() async { helperStatus = await helperClient.status }
```

On launch, if `status == .enabled` and `!(await helperClient.isHelperUpToDate())`, call `unregister()` then `register()` so launchd picks up the new helper binary after an app update.

## 4. Packaging requirements (packaging agent)

- `Contents/MacOS/PrivilegedHelper` signed with **`--identifier com.macappupdater.helper`** (otherwise the identifier defaults to `PrivilegedHelper` and the app's XPC requirement fails), hardened runtime, same Team as the app.
- App signed with bundle id `com.macappupdater.app`.
- `Contents/Library/LaunchDaemons/com.macappupdater.helper.plist`:

```xml
<dict>
    <key>Label</key><string>com.macappupdater.helper</string>
    <key>BundleProgram</key><string>Contents/MacOS/PrivilegedHelper</string>
    <key>MachServices</key><dict><key>com.macappupdater.helper</key><true/></dict>
    <key>AssociatedBundleIdentifiers</key><array><string>com.macappupdater.app</string></array>
</dict>
```

## Security model

- App → helper: `NSXPCConnection(machServiceName:options: .privileged)` with `setCodeSigningRequirement` pinning identifier `com.macappupdater.helper` + the app's team.
- Helper → app: `setCodeSigningRequirement("anchor apple generic and identifier \"com.macappupdater.app\" and certificate leaf[subject.OU] = \"<helper team>\"")`. Ad-hoc helper (local dev) → identifier-only requirement + logged warning (not a security boundary).
- Helper validates the path, **copies the pkg into a root-only (0700) staging dir**, re-runs `pkgutil --check-signature` on the copy (Developer ID or Apple), then runs `/usr/sbin/installer -pkg <copy> -target /`. Copying defeats swap-after-validation (TOCTOU) attacks.
- Team-id match against the installed app is enforced app-side (`PackageInstaller`); the helper only knows "validly signed".

## Caveats

- Not verifiable without a signed, packaged `.app`: `SMAppService` registration/approval, XPC connection, both code-signing requirements, actual `installer` run, and `pkgutil` on real packages (parser is tested against fixture outputs only).
- Only flat `.pkg` files are supported (bundle/directory `.mpkg` are rejected by the validator).
- Any user able to launch the signed app can install validly signed packages as root once an admin approved the helper. Consider restricting to `admin` group members in `CallerValidator` if standard users are a concern.
- A Developer ID pkg can install arbitrary payloads/scripts as root; trust is anchored in the vendor's team id matching the installed app.
- `UpdateDownloader` stores downloads under `FileManager.temporaryDirectory` (`/private/var/folders/...`); if that location changes, update `HelperInstallRequestValidator.defaultAllowedRoots` and bump `HelperConstants.helperVersion`.
- Install timeout defaults to 15 min (`HelperClient(installTimeout:)`).
