#!/usr/bin/env bash
# Start BeeModel (builds first if the binary is missing or out of date).
set -euo pipefail
cd "$(dirname "$0")"
if [[ ! -x build/beemodel ]] || [[ -n "$(find src -newer build/beemodel -print -quit)" ]]; then
    ./build.sh
fi
if [[ -z "${WAYLAND_DISPLAY:-}" ]]; then
    echo "BeeModel needs a Wayland session (WAYLAND_DISPLAY is not set)." >&2
    exit 1
fi
exec ./build/beemodel "$@"
