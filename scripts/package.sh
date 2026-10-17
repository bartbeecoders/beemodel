#!/usr/bin/env bash
# Package a release build: dist/beemodel-<version>-linux-x86_64.tar.gz, the
# optional GPU helper as dist/beemodel-gpu-<version>-linux-x86_64.tar.gz, SHA256SUMS
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION="$(tr -d '[:space:]' < VERSION)"
NAME="beemodel-${VERSION}-linux-x86_64"
scripts/build.sh release
rm -rf dist && mkdir -p "dist/$NAME"
cp build/beemodel README.md CHANGELOG.md LICENSE "dist/$NAME/"
tar -C dist --owner=0 --group=0 --sort=name --mtime='2026-01-01 00:00Z' \
    -czf "dist/$NAME.tar.gz" "$NAME"
cp build/beemodel "dist/$NAME.bin"
# the optional GPU helper: a second asset, unpacked next to beemodel
GNAME="beemodel-gpu-${VERSION}-linux-x86_64"
[[ -x build/beemodel-gpu ]] || { echo "build/beemodel-gpu was not built (needs cc and libvulkan.so.1)" >&2; exit 1; }
mkdir -p "dist/$GNAME"
cp build/beemodel-gpu "dist/$GNAME/"
tar -C "dist/$GNAME" --owner=0 --group=0 --sort=name --mtime='2026-01-01 00:00Z' \
    -czf "dist/$GNAME.tar.gz" beemodel-gpu
(cd dist && sha256sum "$NAME.tar.gz" "$NAME.bin" "$GNAME.tar.gz" > SHA256SUMS)
rm -rf "dist/$NAME" "dist/$GNAME"
ls -l dist
