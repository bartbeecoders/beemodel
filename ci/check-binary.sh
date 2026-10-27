#!/usr/bin/env bash
# Verify the release binary honours the project rules: static, no libraries,
# no interpreter, no RWX segments, and within the size budget; and that the
# source keeps every syscall in the platform layer (src/plat_linux.s).
set -euo pipefail
BIN="${1:-build/beemodel}"
MAX_BYTES="${MAX_BYTES:-2000000}"  # 2 MB from stage C (the masterplan's limit at v1.0); 1.5 MiB from phase 11, 1 MiB in phase 8
fail() { echo "FAIL: $*" >&2; exit 1; }

size=$(stat -c %s "$BIN")
echo "size: $size bytes (budget $MAX_BYTES)"
(( size <= MAX_BYTES )) || fail "binary exceeds size budget"

readelf -h "$BIN" | grep -q 'Type:.*EXEC' || fail "not a static executable"
readelf -l "$BIN" | grep -q INTERP && fail "has a program interpreter (dynamic linking)"
readelf -d "$BIN" 2>&1 | grep -q NEEDED && fail "depends on shared libraries"
readelf -lW "$BIN" | awk '$1=="LOAD" && $7 ~ /RWE/ {exit 1}' || fail "RWX LOAD segment"
"$BIN" --version | grep -Eq '^beemodel [0-9]+\.[0-9]+\.[0-9]+' || fail "--version output"
ops=$("$BIN" --list-ops)
n=$(wc -l <<<"$ops")
dups=$(awk '{print $1}' <<<"$ops" | sort | uniq -d)
(( n >= 20 )) || fail "--list-ops lists only $n operators"
[[ -z "$dups" ]] || fail "duplicate operator ids: $dups"
grep -q '^file.exit  *Ctrl+Q ' <<<"$ops" || fail "file.exit should be bound to Ctrl+Q"
echo "operators: $n registered"
# the Windows port: the OS only through plat_* (Vibecoding/BeeModel-Win11-Port-Plan.html)
cd "$(dirname "$0")/.."
raw=$(grep -nE '^[[:space:]]*([.$[:alnum:]_]+:[[:space:]]*)?syscall\b' src/*.s src/gpu/*.s | grep -v '^src/plat_linux\.s:' || true)
[[ -z "$raw" ]] || fail "syscall outside src/plat_linux.s (call a plat_* routine): $raw"
echo "binary checks passed"
