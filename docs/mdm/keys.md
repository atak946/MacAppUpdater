# Managed preference keys

Domain: **`com.macappupdater.app`**. Only values delivered as *forced* managed
preferences (configuration profile, `com.apple.ManagedClient.preferences` /
Custom Settings payload) are honoured. Values set with `defaults write` are ignored.

Every key is optional. An omitted or invalid key leaves the setting under user control.
Invalid values are logged (`log stream --predicate 'subsystem == "com.macappupdater" AND category == "Managed"'`)
and ignored; the app never crashes because of a bad profile.

| Key | Type | Valid values | Effect |
|---|---|---|---|
| `CheckIntervalHours` | number | 1 – 168 | Hours between background checks. Locks the interval picker. |
| `AutoInstallEnabled` | bool | | Shorthand for the default policy (`true` → `autoInstall`, `false` → `notifyOnly`). `false` is also a kill switch: user per-app `autoInstall` overrides are ignored; only apps forced to `autoInstall` in `PerAppPolicies` install unattended. |
| `DefaultPolicy` | string | `notifyOnly`, `autoInstall` | Global default policy. Wins over `AutoInstallEnabled` for the default. |
| `PerAppPolicies` | dict | bundle id → `notifyOnly` / `autoInstall` | Forced per-app policy. Invalid entries are dropped individually. |
| `IgnoredBundleIdentifiers` | array of strings | bundle ids (`A-Z a-z 0-9 . - _`, ≤ 255 chars) | Apps that are never updated. Users cannot un-ignore them. |
| `DeferralDays` | integer | 0 – 30 | Soak period: a release must be this many days old before it installs. |
| `RequireACPower` | bool | | Unattended installs only on AC power. |
| `AvoidExpensiveNetwork` | bool | | No unattended downloads on expensive networks (cellular, Personal Hotspot). |
| `DisableUninstaller` | bool | | Hides/disables the built-in uninstaller. |
| `DisableBetaChannels` | bool | | Users cannot opt apps into Sparkle beta channels. |
| `AllowedSources` | array of strings | `sparkle`, `homebrew`, `github`, `appStore`, `electron`, `vendor` | Only these update sources are queried. Unknown entries are dropped; a list with no known entry is ignored (fails open). |
| `HideMenuBarIcon` | bool | | Hides the menu bar extra. |
| `RequireNotarization` | bool | | `true` forces Gatekeeper notarization for every app update: the user's "Allow updates that aren't notarized" toggle is ignored and locked. `false` leaves the choice to the user. (`.pkg` updates always require notarization.) |
| `ReportWebhookURL` | string | `https://` URL with a host, no embedded credentials | Reserved for future inventory reporting (D2). Currently parsed and validated only. |

Notes

- Booleans must be real plist booleans (`<true/>` / `<false/>`); `<integer>1</integer>` is rejected.
- Numbers must be plist numbers; `<string>6</string>` is rejected.
- Removing the profile restores the user's previous choices (they are never overwritten by forced values).
- Managed values are read at launch; the app must be relaunched after a profile change.
