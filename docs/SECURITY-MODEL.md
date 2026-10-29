# Security model

How App Updater protects downloads, installs and the privileged helper. The [README](../README.md) has the short
version.

Threats considered: a compromised update feed or host, same-user local malware, and other local
users. Vulnerability reports go through [SECURITY.md](../SECURITY.md).

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
