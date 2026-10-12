#!/usr/bin/env bash
# Build BeeModel: assemble with GNU as, link statically with ld. No libraries.
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p build
MODE="${1:-release}"
ASFLAGS=(--64 -I src)
[[ "$MODE" == "debug" ]] && ASFLAGS+=(-g)

as "${ASFLAGS[@]}" -o build/beemodel.o src/main.s
if [[ "$MODE" == "debug" ]]; then
    ld -static -nostdlib -o build/beemodel build/beemodel.o
else
    # -s strip symbols, -n no page-aligned sections, --gc-sections drop unused
    ld -static -nostdlib -s --gc-sections --build-id=none -z noexecstack \
       -o build/beemodel build/beemodel.o
fi
echo "built build/beemodel ($(stat -c %s build/beemodel) bytes, mode: $MODE)"
