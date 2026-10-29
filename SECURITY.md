# Security Policy

App Updater installs software, ships a privileged helper and can change launchd jobs
with administrator rights, so security reports are taken seriously.

## Reporting a vulnerability

Please **do not open a public issue**. Use GitHub's private
[security advisory form](https://github.com/atak946/MacAppUpdater/security/advisories/new)
instead. Include the affected version, macOS version, steps to reproduce and the impact.

You can expect an acknowledgement within a few days. Fixes are released through the
built-in updater; credit is given in the release notes unless you prefer otherwise.

## Supported versions

Only the latest release receives security fixes.

## Scope

In scope: the app, the privileged helper (`PrivilegedHelper`), update download and
verification, the uninstaller, cleanup, startup item and process management.
Out of scope: vulnerabilities in third-party apps that App Updater updates.
