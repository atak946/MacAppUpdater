#!/usr/bin/env bash
# Shared release-readiness checks. Source it; each function prints one line per problem
# (nothing when the check passes) so callers decide whether to warn or fail.
#
#   placeholder_problems <Info.plist>   placeholder Sparkle SUFeedURL / SUPublicEDKey (ALLOW_NO_FEED=1 permits no feed)
#   arch_problems <binary>...           binaries that are not universal (arm64 + x86_64)

# Prints the raw string value of <key> in <plist>, or nothing when missing.
plist_value() {
    plutil -extract "$2" raw -o - "$1" 2>/dev/null || true
}

placeholder_problems() {
    local plist="$1" feed key
    feed="$(plist_value "$plist" SUFeedURL)"
    key="$(plist_value "$plist" SUPublicEDKey)"
    if [[ -z "$feed" && "${ALLOW_NO_FEED:-0}" == "1" ]]; then
        : # Self-update intentionally disabled until a feed is published.
    elif [[ -z "$feed" || "$feed" == *example.com* ]]; then
        printf 'SUFeedURL is a placeholder (%s); set your real https appcast URL in %s\n' "${feed:-missing}" "$plist"
    elif [[ "$feed" != https://* ]]; then
        printf 'SUFeedURL must be https (%s)\n' "$feed"
    fi
    if [[ -z "$key" || "$key" == *REPLACE_WITH* ]]; then
        printf 'SUPublicEDKey is a placeholder; paste the key printed by Sparkle generate_keys into %s\n' "$plist"
    fi
}

arch_problems() {
    local binary archs
    for binary in "$@"; do
        if [[ ! -f "$binary" ]]; then
            printf '%s: missing\n' "$binary"
            continue
        fi
        archs="$(lipo -archs "$binary" 2>/dev/null || true)"
        if [[ " $archs " != *" arm64"[\ e]* || " $archs " != *" x86_64 "* ]]; then
            printf '%s is not universal (archs: %s)\n' "$(basename "$binary")" "${archs:-unknown}"
        fi
    done
}
