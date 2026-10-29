# Managing App Updater with MDM

App Updater reads **forced managed preferences** for the domain `com.macappupdater.app`.
Any setting delivered this way is enforced, shown with a lock icon, and cannot be changed
by the user. Settings that are not in the profile stay under user control.

- Key reference: [keys.md](keys.md)
- Sample profile: [AppUpdater.mobileconfig](AppUpdater.mobileconfig)

## Deploying

The payload is a plain preferences payload, so every MDM supports it.

**Jamf Pro** — Computers → Configuration Profiles → New → *Application & Custom Settings* →
*Upload* (or *External Applications* → *Custom Schema*). Preference domain
`com.macappupdater.app`, then paste the inner `mcx_preference_settings` dictionary (or
upload the plist). Scope to the target computers.

**Kandji** — Library → Add new → *Custom Profile* → upload `AppUpdater.mobileconfig`
(edit the values first). Assign to a Blueprint.

**Microsoft Intune** — Devices → macOS → Configuration → Create → *Templates* →
*Preference file*. Domain `com.macappupdater.app`, upload a plist containing only the
keys (the `mcx_preference_settings` dictionary contents). Intune delivers these as
forced managed preferences.

**Other MDMs (Mosyle, Workspace ONE, SimpleMDM, Addigy)** — upload the `.mobileconfig`
as a custom profile.

Before uploading the sample, replace `PayloadIdentifier`, `PayloadOrganization` and both
`PayloadUUID` values (`uuidgen`), and drop keys you do not want to enforce.

## Testing locally

Forced preferences **cannot** be simulated with `defaults write`: those values are user
level and App Updater ignores them on purpose (`CFPreferencesAppValueIsForced` is false).
Install the profile instead:

```sh
# Validate the file
plutil -lint docs/mdm/AppUpdater.mobileconfig

# macOS 11+: `profiles install` is no longer allowed from the CLI. Open the file and
# approve it in System Settings → General → Device Management (Profiles).
open docs/mdm/AppUpdater.mobileconfig

# Inspect what is installed / what the app sees
sudo profiles show -type configuration
ls "/Library/Managed Preferences/"
defaults read "/Library/Managed Preferences/com.macappupdater.app"

# Watch validation warnings while launching the app
log stream --predicate 'subsystem == "com.macappupdater" AND category == "Managed"'

# Remove it again
sudo profiles remove -identifier com.example.mdm.macappupdater
```

Relaunch App Updater after installing or removing a profile; managed values are read
at launch.

## Behaviour notes

- Removing the profile restores the user's own previous choices; forced values are never
  written into the user's preferences.
- Invalid values are ignored and logged, never fatal. `AllowedSources` with no recognised
  entry is ignored so a typo cannot silently disable all updates.
- `ReportWebhookURL` must be `https://` and is reserved for upcoming inventory reporting.
