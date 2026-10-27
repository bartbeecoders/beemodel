#!/usr/bin/env bash
# What ci/check-windows.ps1 needs on GitHub's windows-latest, gathered on
# Linux after scripts/package.sh: build/winkit/ with the Windows zip, the
# platform layer's tests (build/test-*.exe) and smoke-linux.png, the Linux
# build's render of tests/win/smoke.bees, which the Windows one must match.
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION="$(tr -d '[:space:]' < VERSION)"
ZIP="dist/beemodel-${VERSION}-windows-x86_64.zip"
[[ -f "$ZIP" ]] || { echo "no $ZIP (scripts/package.sh)" >&2; exit 1; }
rm -rf build/winkit && mkdir -p build/winkit
cp "$ZIP" build/test-*.exe build/winkit/
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
cp tests/win/smoke.bees "$tmp/"
(cd "$tmp" && HOME="$tmp" BEEMODEL_GPU=off "$OLDPWD/build/beemodel" --run smoke.bees)
cp "$tmp/smoke.png" build/winkit/smoke-linux.png
echo "$VERSION" > build/winkit/VERSION
ls -l build/winkit
