#!/usr/bin/env bash
# Builds, Developer ID signs, notarizes and staples AppUpdater.app.
#
# Required environment:
#   SIGN_IDENTITY   e.g. "Developer ID Application: Jane Doe (TEAMID1234)"
#   NOTARY_PROFILE  keychain profile created with `xcrun notarytool store-credentials`
#   VERSION         CFBundleShortVersionString, e.g. 1.2.0
# Optional:
#   BUILD           CFBundleVersion (default: git commit count)
#   MAKE_DMG=1      also produce a notarized + stapled DMG
#   ALLOW_NATIVE=1  accept a non-universal (native-only) build
#   ALLOW_NO_FEED=1 build without SUFeedURL (Sparkle self-update disabled)
#
# Refuses to run while Packaging/Info.plist still has placeholder Sparkle settings
# (SUFeedURL on example.com, SUPublicEDKey = REPLACE_WITH_...).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PACKAGING="$ROOT/Packaging"
OUT_DIR="$ROOT/build"
APP="$OUT_DIR/AppUpdater.app"
SPARKLE="$APP/Contents/Frameworks/Sparkle.framework"
SPARKLE_BIN="$ROOT/.build/artifacts/sparkle/Sparkle/bin"

# shellcheck source=scripts/release-checks.sh source-path=SCRIPTDIR/..
source "$ROOT/scripts/release-checks.sh"

log() { printf '==> %s\n' "$*" >&2; }
fail() { printf 'error: %s\n' "$*" >&2; exit 1; }

require_env() {
    local missing=() name
    for name in SIGN_IDENTITY NOTARY_PROFILE VERSION; do
        [[ -n "${!name:-}" ]] || missing+=("$name")
    done
    if (( ${#missing[@]} > 0 )); then
        fail "missing required environment variable(s): ${missing[*]}
  SIGN_IDENTITY   Developer ID Application identity (see: security find-identity -v -p codesigning)
  NOTARY_PROFILE  notarytool keychain profile (see: xcrun notarytool store-credentials --help)
  VERSION         marketing version, e.g. 1.2.0"
    fi
    security find-identity -v -p codesigning | grep -Fq "$SIGN_IDENTITY" \
        || fail "signing identity not found in keychain: $SIGN_IDENTITY"
}

# Fails on any line printed by a release-checks.sh function.
refuse_on_problems() {
    local problems
    problems="$("$@")"
    [[ -z "$problems" ]] || fail "release refused:
$problems"
}

check_architectures() {
    if [[ "${ALLOW_NATIVE:-0}" == "1" ]]; then
        log "ALLOW_NATIVE=1: skipping the universal-binary check"
        return
    fi
    refuse_on_problems arch_problems "$APP/Contents/MacOS/AppUpdater" "$APP/Contents/MacOS/PrivilegedHelper"
}

sign() {
    codesign --force --timestamp --options runtime --sign "$SIGN_IDENTITY" "$@"
}

# Inside-out signing, following https://sparkle-project.org/documentation/sandboxing/#code-signing
sign_all() {
    log "Signing Sparkle components"
    sign "$SPARKLE/Versions/B/XPCServices/Installer.xpc"
    sign --preserve-metadata=entitlements "$SPARKLE/Versions/B/XPCServices/Downloader.xpc"
    sign "$SPARKLE/Versions/B/Autoupdate"
    sign "$SPARKLE/Versions/B/Updater.app"
    sign "$SPARKLE"

    log "Signing privileged helper"
    sign --identifier com.macappupdater.helper \
        --entitlements "$PACKAGING/PrivilegedHelper.entitlements" \
        "$APP/Contents/MacOS/PrivilegedHelper"

    log "Signing app"
    sign --entitlements "$PACKAGING/AppUpdater.entitlements" "$APP"
    codesign --verify --deep --strict --verbose=2 "$APP"
}

notarize() {
    local artifact="$1"
    log "Notarizing $(basename "$artifact") (this can take a few minutes)"
    xcrun notarytool submit "$artifact" --keychain-profile "$NOTARY_PROFILE" --wait
}

make_dmg() {
    local dmg="$OUT_DIR/AppUpdater-$VERSION.dmg" staging="$OUT_DIR/dmg-staging"
    log "Creating $dmg"
    rm -rf "$staging" "$dmg"
    mkdir -p "$staging"
    ditto "$APP" "$staging/AppUpdater.app"
    ln -s /Applications "$staging/Applications"
    hdiutil create -volname "App Updater" -srcfolder "$staging" -ov -format UDZO "$dmg"
    rm -rf "$staging"
    codesign --force --timestamp --sign "$SIGN_IDENTITY" "$dmg"
    notarize "$dmg"
    xcrun stapler staple "$dmg"
}

main() {
    require_env
    refuse_on_problems placeholder_problems "$PACKAGING/Info.plist"
    local strict=1
    [[ "${ALLOW_NATIVE:-0}" == "1" ]] && strict=0
    VERSION="$VERSION" BUILD="${BUILD:-}" SIGN_IDENTITY="$SIGN_IDENTITY" STRICT_ARCHS="$strict" \
        "$ROOT/scripts/build-app.sh"
    check_architectures
    sign_all

    local zip="$OUT_DIR/AppUpdater-$VERSION.zip"
    rm -f "$zip"
    ditto -c -k --keepParent "$APP" "$zip"
    notarize "$zip"
    xcrun stapler staple "$APP"
    xcrun stapler validate "$APP"
    # Re-zip so the distributed archive contains the stapled ticket.
    rm -f "$zip"
    ditto -c -k --keepParent "$APP" "$zip"

    if [[ "${MAKE_DMG:-0}" == "1" ]]; then make_dmg; fi

    log "Release artifacts in $OUT_DIR"
    log "Next: publish the appcast (signs updates with the EdDSA key from your keychain):"
    log "  mkdir -p build/updates && cp \"$zip\" build/updates/"
    log "  \"$SPARKLE_BIN/generate_appcast\" build/updates"
    log "  upload build/updates/* to the host serving SUFeedURL"
}

main "$@"
