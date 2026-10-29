#!/usr/bin/env bash
# Measures CPU used by an already running AppUpdater over a time window.
#
#   scripts/measure-cpu.sh [seconds]     window length (default: 20)
#
# Environment:
#   PROCESS_NAME   exact process name for pgrep -x (default: AppUpdater)
#
# Uses `ps -o time=` deltas (cumulative CPU time) rather than parsing `top`, whose output
# varies with locale and decimal separators.
set -euo pipefail

SECONDS_WINDOW="${1:-20}"
PROCESS_NAME="${PROCESS_NAME:-AppUpdater}"

if ! [[ "$SECONDS_WINDOW" =~ ^[1-9][0-9]*$ ]]; then
    echo "usage: $0 [seconds]  (positive integer, default 20)" >&2
    exit 64
fi

PID="$(pgrep -x "$PROCESS_NAME" | head -n 1 || true)"
if [[ -z "$PID" ]]; then
    echo "$PROCESS_NAME is not running; launch it first." >&2
    exit 1
fi

# Prints the process's cumulative CPU time in centiseconds. ps prints [[dd-]hh:]mm:ss.cc.
cpu_centis() {
    local raw
    raw="$(ps -o time= -p "$PID" | tr -d ' ')"
    if [[ -z "$raw" ]]; then
        echo "$PROCESS_NAME (pid $PID) exited during measurement." >&2
        exit 1
    fi
    echo "$raw" | awk -F'[-:.]' '{
        n = NF; cs = $n; s = $(n-1); m = $(n-2); h = (n >= 4) ? $(n-3) : 0; d = (n >= 5) ? $(n-4) : 0
        printf "%d\n", ((((d * 24 + h) * 60 + m) * 60 + s) * 100) + cs
    }'
}

echo "Measuring $PROCESS_NAME (pid $PID) for ${SECONDS_WINDOW}s..."
before="$(cpu_centis)"
sleep "$SECONDS_WINDOW"
after="$(cpu_centis)"

awk -v d="$((after - before))" -v w="$SECONDS_WINDOW" 'BEGIN {
    printf "CPU time: %.2fs over %ds  (average %.1f%% of one core)\n", d / 100, w, d / w
}'
