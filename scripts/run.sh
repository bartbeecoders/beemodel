#!/usr/bin/env bash
# Start the latest BeeModel.
#
# On main, it first fast-forwards to origin/main (skipped offline, or when
# local commits or changes are in the way). It then rebuilds whenever the
# sources differ from those of the last build: src/, VERSION or scripts/build.sh,
# by content, so a pull, a branch switch or a version bump all count.
set -euo pipefail
cd "$(dirname "$0")/.."

if [[ "$(git branch --show-current 2>/dev/null)" == main ]]; then
    if timeout 10 git fetch -q origin main 2>/dev/null; then
        if ! git merge-base --is-ancestor origin/main HEAD; then
            git merge -q --ff-only origin/main 2>/dev/null \
                && echo "run.sh: updated to $(git log -1 --format='%h %s')" \
                || echo "run.sh: origin/main has new commits, but local work is in the way; not updating" >&2
        fi
    else
        echo "run.sh: could not reach origin; building what is here" >&2
    fi
fi

stamp=$( (find src -type f -print0 | LC_ALL=C sort -z | xargs -0 sha256sum; sha256sum VERSION scripts/build.sh) | sha256sum | cut -d' ' -f1)
if [[ ! -x build/beemodel ]] || [[ "$(cat build/.run-stamp 2>/dev/null)" != "$stamp" ]]; then
    scripts/build.sh
    echo "$stamp" > build/.run-stamp
fi
if [[ -z "${WAYLAND_DISPLAY:-}" ]]; then
    echo "BeeModel needs a Wayland session (WAYLAND_DISPLAY is not set)." >&2
    exit 1
fi
exec ./build/beemodel "$@"
