#!/usr/bin/env bash
# Verify the release binary honours the project rules: static, no libraries,
# no interpreter, no RWX segments, and within the size budget.
set -euo pipefail
BIN="${1:-build/beemodel}"
MAX_BYTES="${MAX_BYTES:-1572864}"  # 1.5 MiB from phase 11 (UI); 1 MiB in phase 8 (masterplan: < 2 MB at v1.0)
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
echo "binary checks passed"
