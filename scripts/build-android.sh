#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export JAVA_HOME="${TABD_JAVA_HOME:-$(/usr/libexec/java_home -v 17)}"
export ANDROID_HOME="${ANDROID_HOME:-$HOME/Library/Android/sdk}"
GRADLE="${TABD_GRADLE:-}"
if [[ -z "$GRADLE" ]]; then
    for candidate in "$HOME"/.gradle/wrapper/dists/gradle-8.13-bin/*/gradle-8.13/bin/gradle; do
        if [[ -x "$candidate" ]]; then GRADLE="$candidate"; break; fi
    done
fi
if [[ -z "$GRADLE" ]]; then GRADLE="$(command -v gradle || true)"; fi
if [[ -z "$GRADLE" || ! -x "$GRADLE" ]]; then
    echo 'Gradle 8.13 is required. Set TABD_GRADLE to its bin/gradle executable.' >&2
    exit 1
fi
if [[ "${TABD_ONLINE:-0}" == "1" ]]; then
    "$GRADLE" -p "$ROOT/android" --no-daemon assembleDebug "$@"
else
    "$GRADLE" -p "$ROOT/android" --offline --no-daemon assembleDebug "$@"
fi
