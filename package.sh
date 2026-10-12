#!/usr/bin/env bash
# Package a release build: dist/beemodel-<version>-linux-x86_64.tar.gz + SHA256SUMS
set -euo pipefail
cd "$(dirname "$0")"
VERSION="$(tr -d '[:space:]' < VERSION)"
NAME="beemodel-${VERSION}-linux-x86_64"
./build.sh release
rm -rf dist && mkdir -p "dist/$NAME"
cp build/beemodel README.md CHANGELOG.md "dist/$NAME/"
tar -C dist --owner=0 --group=0 --sort=name --mtime='2026-01-01 00:00Z' \
    -czf "dist/$NAME.tar.gz" "$NAME"
cp build/beemodel "dist/$NAME.bin"
(cd dist && sha256sum "$NAME.tar.gz" "$NAME.bin" > SHA256SUMS)
rm -rf "dist/$NAME"
ls -l dist
