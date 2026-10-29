#!/usr/bin/env bash
# Renders the README screenshots from built-in demo data (nothing is read from this Mac) into
# docs/images/<lang>/*.png, in English and Turkish, and exports the app icon to docs/images/icon.png.
#
# The app binary runs headless in screenshot mode (`--render-screenshots <dir>`): it shows no
# window, starts no scan, update check, Sparkle or usage recorder, renders the PNGs and exits.
#
# Usage: scripts/render-screenshots.sh [--skip-build]
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_BINARY="$ROOT/build/AppUpdater.app/Contents/MacOS/AppUpdater"
ICON="$ROOT/Packaging/AppIcon.icns"
IMAGES="$ROOT/docs/images"
LANGUAGES=(en tr)
TIMEOUT_SECONDS=180

log() { printf '==> %s\n' "$*" >&2; }
fail() { printf 'error: %s\n' "$*" >&2; exit 1; }

locale_for() {
    case "$1" in
        tr) echo tr_TR ;;
        *) echo en_US ;;
    esac
}

# Runs the renderer for one language with a timeout, so a hang never blocks the script.
render() {
    local lang="$1" out="$2" pid waited=0
    rm -rf "$out"
    mkdir -p "$out"
    "$APP_BINARY" --render-screenshots "$out" -AppleLanguages "($lang)" -AppleLocale "$(locale_for "$lang")" &
    pid=$!
    while kill -0 "$pid" 2>/dev/null; do
        if (( waited >= TIMEOUT_SECONDS )); then
            kill "$pid" 2>/dev/null || true
            fail "rendering ($lang) timed out"
        fi
        sleep 1
        (( waited += 1 ))
    done
    wait "$pid" || fail "rendering ($lang) failed"
}

main() {
    if [[ "${1:-}" != "--skip-build" ]]; then
        ARCHS=native "$ROOT/scripts/build-app.sh"
    fi
    [[ -x "$APP_BINARY" ]] || fail "$APP_BINARY not found; build first (scripts/build-app.sh)"

    local lang
    for lang in "${LANGUAGES[@]}"; do
        log "Rendering $lang"
        render "$lang" "$IMAGES/$lang"
    done

    log "Exporting icon"
    sips -s format png -z 256 256 "$ICON" --out "$IMAGES/icon.png" >/dev/null

    log "Screenshots:"
    ls -lh "$IMAGES"/icon.png "$IMAGES"/*/*.png | awk '{ print $5, $9 }'
}

main "$@"
