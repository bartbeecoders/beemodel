#!/usr/bin/env bash
# Package a release build: dist/beemodel-<version>-linux-x86_64.tar.gz, the
# optional GPU helper as dist/beemodel-gpu-<version>-linux-x86_64.tar.gz, the
# Windows build (beemodel.exe and beemodel-gpu.exe) as
# dist/beemodel-<version>-windows-x86_64.zip, SHA256SUMS
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION="$(tr -d '[:space:]' < VERSION)"
NAME="beemodel-${VERSION}-linux-x86_64"
scripts/build.sh release
rm -rf dist && mkdir -p "dist/$NAME"
cp build/beemodel README.md CHANGELOG.md LICENSE docs/mcp-tools.json "dist/$NAME/"
mkdir -p "dist/$NAME/addons/hi3d"           # Image to 3D: installed by the user (docs/HI3D.md)
cp addons/hi3d/install.sh addons/hi3d/bee_hi3d.py docs/HI3D.md "dist/$NAME/addons/hi3d/"
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
# Windows: one zip, the GPU helper inside (it loads vulkan-1.dll only when it runs)
WNAME="beemodel-${VERSION}-windows-x86_64"
[[ -f build/beemodel.exe && -f build/beemodel-gpu.exe ]] ||
    { echo "build/beemodel.exe was not built (needs ld with the i386pep emulation)" >&2; exit 1; }
mkdir -p "dist/$WNAME"
cp build/beemodel.exe build/beemodel-gpu.exe README.md CHANGELOG.md LICENSE docs/mcp-tools.json \
    docs/WINDOWS.md "dist/$WNAME/"
touch -d '2026-01-01 00:00Z' "dist/$WNAME" "dist/$WNAME"/*
(cd dist && TZ=UTC zip -qX -r "$WNAME.zip" "$WNAME")
(cd dist && sha256sum "$NAME.tar.gz" "$NAME.bin" "$GNAME.tar.gz" "$WNAME.zip" > SHA256SUMS)
rm -rf "dist/$NAME" "dist/$GNAME" "dist/$WNAME"
ls -l dist
