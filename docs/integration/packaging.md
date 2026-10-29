# Packaging & self-update integration

## Files added

- `Package.swift`: Sparkle `from: "2.6.0"` (resolves to 2.10.x), linked into the `AppUpdater` target only, plus rpath `@executable_path/../Frameworks`.
- `Sources/AppUpdater/SelfUpdate/SelfUpdater.swift`, `CheckForAppUpdatesView.swift`
- `Packaging/Info.plist`, `AppUpdater.entitlements`, `PrivilegedHelper.entitlements`, `com.macappupdater.helper.plist`
- `scripts/build-app.sh`, `scripts/release.sh`, `Makefile`, `.github/workflows/ci.yml`

## Public API

```swift
@MainActor @Observable final class SelfUpdater {
    init(bundle: Bundle = .main)
    private(set) var canCheckForUpdates: Bool   // false while a check runs or when inactive
    let isActive: Bool                            // Sparkle actually started
    func checkForUpdates()                        // no-op + log when inactive
    nonisolated static func inactiveReason(for: Bundle) -> String?  // nil = OK to start
}
struct CheckForAppUpdatesView: View { let selfUpdater: SelfUpdater }
```

Sparkle only starts when `Bundle.main` is a `.app` with an `https` `SUFeedURL`. Under
`swift run` / `.build/debug/AppUpdater` it stays inactive (the menu item is disabled).

## Code the integrator must add

### 1. `Sources/AppUpdater/AppEnvironment.swift`

Add a stored property and create it in `init` (it must live for the whole app lifetime):

```swift
let selfUpdater: SelfUpdater
// in init(defaults:), before or after viewModel setup:
self.selfUpdater = SelfUpdater()
```

### 2. `Sources/AppUpdater/AppUpdaterApp.swift`

Inside the existing `.commands { ... }` of the `Window("App Updater", id: "main")` scene:

```swift
.commands {
    CommandGroup(replacing: .newItem) {}
    CommandGroup(after: .appInfo) {
        CheckForAppUpdatesView(selfUpdater: appDelegate.environment.selfUpdater)
    }
}
```

### 3. Optional: `MenuBarView.swift` / `SettingsView.swift`

Same view can be dropped into the menu bar window or settings, e.g.
`CheckForAppUpdatesView(selfUpdater: environment.selfUpdater)` (pass `selfUpdater` down as a `let`).

### 4. `.gitignore`

Add `build/` (output of `scripts/build-app.sh`; not in my scope).

### 5. Privileged helper (for the helper agent)

- The app's helper registration should use `SMAppService.daemon(plistName: "com.macappupdater.helper.plist")`.
- Plist lives at `Contents/Library/LaunchDaemons/com.macappupdater.helper.plist`, `BundleProgram` = `Contents/MacOS/PrivilegedHelper`, Mach service `com.macappupdater.helper`, `AssociatedBundleIdentifiers` = `[com.macappupdater.app]`.
- `release.sh` signs the helper with `--identifier com.macappupdater.helper`; code-signing requirement checks in the helper/XPC can rely on that identifier + the team ID.

## Caveats

- `unsafeFlags` (the rpath) is allowed because this is a root package; it would block consumption as a dependency (not a use case here). Debug builds find Sparkle via `@loader_path` (SwiftPM copies `Sparkle.framework` next to the binary), verified with `.build/debug/AppUpdater`.
- Release binaries also carry an absolute toolchain rpath (`.../swift-6.2/macosx`) added by SwiftPM; harmless at runtime (system Swift runtime is used on macOS 14+).
- Entitlement files must not contain XML comments (AMFI rejects them at signing time).
- `Packaging/Info.plist` has placeholders: `SUFeedURL` (`https://example.com/appcast.xml`) and `SUPublicEDKey` (`REPLACE_WITH_SPARKLE_PUBLIC_ED_KEY`). With the placeholder feed, a packaged build starts Sparkle and its first scheduled check will fail against example.com — set the real values before shipping.
- Ad-hoc signed builds launch locally but `SMAppService` daemon registration requires a real Developer ID signature.
- CI uses `macos-15` (Xcode 16.x default). If sources need a newer Swift than the runner ships, add a `maxim-lobanov/setup-xcode` step or bump the runner image.
- Universal build prints an x86_64 deprecation warning on Xcode 27; `ARCHS=native ./scripts/build-app.sh` builds arm64 only.
