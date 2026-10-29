#!/usr/bin/env bash
# Builds build/AppUpdater.app from the Swift package.
#
# Environment:
#   VERSION        CFBundleShortVersionString (default: 0.1.0)
#   BUILD          CFBundleVersion            (default: git commit count, else 1)
#   SIGN_IDENTITY  codesign identity; when unset the bundle is ad-hoc signed (local use only)
#   ARCHS          "universal" (default) or "native"
#   STRICT_ARCHS=1 fail instead of falling back to a native build when the universal build fails
#                  (release.sh sets this unless ALLOW_NATIVE=1)
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PACKAGING="$ROOT/Packaging"
OUT_DIR="$ROOT/build"
APP="$OUT_DIR/AppUpdater.app"
CONTENTS="$APP/Contents"

# shellcheck source=scripts/release-checks.sh source-path=SCRIPTDIR/..
source "$ROOT/scripts/release-checks.sh"

VERSION="${VERSION:-0.1.0}"
BUILD="${BUILD:-$(git -C "$ROOT" rev-list --count HEAD 2>/dev/null || echo 1)}"
ARCHS="${ARCHS:-universal}"

log() { printf '==> %s\n' "$*" >&2; }
fail() { printf 'error: %s\n' "$*" >&2; exit 1; }
warn() { printf '\n!!! WARNING: %s\n\n' "$*" >&2; }

# Prints the release bin directory after a successful build.
build_products() {
    local -a arch_flags=()
    if [[ "$ARCHS" == "universal" ]]; then
        arch_flags=(--arch arm64 --arch x86_64)
        log "Building universal release (arm64 + x86_64)"
        if swift build --package-path "$ROOT" -c release "${arch_flags[@]}" >&2; then
            swift build --package-path "$ROOT" -c release "${arch_flags[@]}" --show-bin-path
            return
        fi
        [[ "${STRICT_ARCHS:-0}" != "1" ]] || fail "universal build failed (STRICT_ARCHS=1)"
        warn "Universal build failed; falling back to the NATIVE architecture only. Not for distribution."
    fi
    swift build --package-path "$ROOT" -c release >&2
    swift build --package-path "$ROOT" -c release --show-bin-path
}

assemble_bundle() {
    local bin="$1"
    log "Assembling $APP"
    rm -rf "$APP"
    mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Frameworks" "$CONTENTS/Resources" "$CONTENTS/Library/LaunchDaemons"

    cp "$bin/AppUpdater" "$CONTENTS/MacOS/AppUpdater"
    cp "$bin/PrivilegedHelper" "$CONTENTS/MacOS/PrivilegedHelper"
    cp "$PACKAGING/com.macappupdater.helper.plist" "$CONTENTS/Library/LaunchDaemons/"

    [[ -d "$bin/Sparkle.framework" ]] || fail "Sparkle.framework not found in $bin"
    ditto "$bin/Sparkle.framework" "$CONTENTS/Frameworks/Sparkle.framework"

    local bundle
    for bundle in "$bin"/*.bundle; do
        [[ -e "$bundle" ]] || continue
        ditto "$bundle" "$CONTENTS/Resources/$(basename "$bundle")"
    done
    # SwiftUI looks up Text/String(localized:) in Bundle.main, so the app target's compiled
    # catalog (en.lproj, tr.lproj, ...) must also sit directly in Contents/Resources.
    local lproj
    for lproj in "$bin/MacAppUpdater_AppUpdater.bundle/Contents/Resources/"*.lproj; do
        [[ -d "$lproj" ]] || continue
        ditto "$lproj" "$CONTENTS/Resources/$(basename "$lproj")"
    done
    if [[ -f "$PACKAGING/AppIcon.icns" ]]; then
        cp "$PACKAGING/AppIcon.icns" "$CONTENTS/Resources/AppIcon.icns"
    fi

    sed -e "s/__VERSION__/$VERSION/g" -e "s/__BUILD__/$BUILD/g" \
        "$PACKAGING/Info.plist" > "$CONTENTS/Info.plist"
    plutil -lint "$CONTENTS/Info.plist" >/dev/null
    printf 'APPL????' > "$CONTENTS/PkgInfo"
}

# Shortcuts and Spotlight only see App Intents listed in Contents/Resources/Metadata.appintents.
# Xcode runs appintentsmetadataprocessor for that; SwiftPM doesn't, so we run it the same way on
# the .swiftconstvalues files the compiler already emits next to the app target's objects.
extract_app_intents_metadata() {
    local bin="$1"
    local tool target_dir arch_dir arch const_list min_os xcode_build
    tool="$(xcrun --find appintentsmetadataprocessor 2>/dev/null)" \
        || fail "appintentsmetadataprocessor not found (needs Xcode, not only the Command Line Tools)"
    # $bin is .../Products/<Config>; the module's intermediates sit beside it.
    target_dir="$(dirname "$(dirname "$bin")")/Intermediates.noindex/MacAppUpdater.build/$(basename "$bin")/AppUpdater-p.build"
    # Metadata is architecture neutral: one architecture's const values describe all of them.
    for arch_dir in "$target_dir"/Objects-normal/*; do
        [[ -f "$arch_dir/AppUpdater.SwiftFileList" ]] && break
    done
    [[ -f "${arch_dir:-}/AppUpdater.SwiftFileList" ]] || fail "AppUpdater build intermediates not found in $target_dir"
    arch="$(basename "$arch_dir")"
    const_list="$arch_dir/AppUpdater.SwiftConstValuesFileList"
    find "$arch_dir" -maxdepth 1 -name '*.swiftconstvalues' > "$const_list"
    [[ -s "$const_list" ]] || fail "no .swiftconstvalues in $arch_dir; App Intents metadata can't be extracted"
    min_os="$(plist_value "$CONTENTS/Info.plist" LSMinimumSystemVersion)"
    xcode_build="$(xcodebuild -version | awk '/Build version/ { print $3 }')"

    log "Extracting App Intents metadata ($arch)"
    "$tool" \
        --output "$CONTENTS/Resources" \
        --toolchain-dir "$(dirname "$(dirname "$(dirname "$tool")")")" \
        --module-name AppUpdater \
        --sdk-root "$(xcrun --sdk macosx --show-sdk-path)" \
        --xcode-version "$xcode_build" \
        --platform-family macOS \
        --deployment-target "$min_os" \
        --bundle-identifier "$(plist_value "$CONTENTS/Info.plist" CFBundleIdentifier)" \
        --target-triple "$arch-apple-macos$min_os" \
        --binary-file "$CONTENTS/MacOS/AppUpdater" \
        --source-file-list "$arch_dir/AppUpdater.SwiftFileList" \
        --swift-const-vals-list "$const_list" \
        --compile-time-extraction \
        --deployment-aware-processing \
        --no-app-shortcuts-localization \
        --force >&2
    grep -q '"CheckForUpdatesIntent"' "$CONTENTS/Resources/Metadata.appintents/extract.actionsdata" 2>/dev/null \
        || fail "Metadata.appintents is missing the app's intents"
}

# Ad-hoc signature so the bundle launches locally. Release signing lives in release.sh.
sign_bundle() {
    if [[ -n "${SIGN_IDENTITY:-}" ]]; then
        log "SIGN_IDENTITY set; skipping ad-hoc signing (run scripts/release.sh to sign)"
        return
    fi
    log "Ad-hoc signing"
    codesign --force --sign - --identifier com.macappupdater.helper \
        --entitlements "$PACKAGING/PrivilegedHelper.entitlements" \
        "$CONTENTS/MacOS/PrivilegedHelper"
    codesign --force --sign - --entitlements "$PACKAGING/AppUpdater.entitlements" "$APP"
    codesign --verify --deep --strict "$APP"
    log "NOTE: ad-hoc builds have no Team ID, so the privileged helper rejects every connection"
    log "      (fail-closed). .pkg updates need a Developer ID-signed build (scripts/release.sh)."
}

# Loud, non-fatal warnings; release.sh turns the same checks into hard failures.
warn_release_readiness() {
    local problem
    while IFS= read -r problem; do
        if [[ -n "$problem" ]]; then warn "$problem (release.sh will refuse this build)"; fi
    done < <(placeholder_problems "$CONTENTS/Info.plist"; \
             arch_problems "$CONTENTS/MacOS/AppUpdater" "$CONTENTS/MacOS/PrivilegedHelper")
}

main() {
    [[ "$VERSION" =~ ^[0-9A-Za-z.+-]+$ ]] || fail "invalid VERSION: $VERSION"
    [[ "$BUILD" =~ ^[0-9.]+$ ]] || fail "invalid BUILD: $BUILD"
    local bin
    bin="$(build_products | tail -n 1)"
    [[ -x "$bin/AppUpdater" ]] || fail "AppUpdater binary missing in $bin"
    assemble_bundle "$bin"
    extract_app_intents_metadata "$bin"
    sign_bundle
    warn_release_readiness
    log "Done: $APP ($VERSION build $BUILD)"
}

main "$@"
