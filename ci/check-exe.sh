#!/usr/bin/env bash
# Verify the Windows build (build/beemodel.exe, Vibecoding/BeeModel-Win11-
# Port-Plan.html): a 64-bit PE that imports only Windows system DLLs, no C
# runtime; and, where Wine runs, that it prints the same version as the
# Linux binary and the platform layer's own tests (build/test-*.exe, from
# tests/win/) pass. WINE names the command (default: wine, else wine64).
# When the Windows 11 VM's job runner is up (tools/winvm-run.sh), the same
# there.
set -euo pipefail
EXE="${1:-build/beemodel.exe}"
fail() { echo "FAIL: $*" >&2; exit 1; }

[[ -f "$EXE" ]] || fail "no $EXE (scripts/build.sh skips it when ld lacks i386pep)"
objdump -f "$EXE" | grep -q 'file format pei-x86-64' || fail "not a 64-bit PE executable"
dlls=$(objdump -p "$EXE" | awk '/DLL Name:/ {print toupper($3)}' | sort -u)
[[ -n "$dlls" ]] || fail "imports nothing"
for d in $dlls; do
    case $d in
        KERNEL32.DLL|USER32.DLL|GDI32.DLL|WS2_32.DLL) ;;
        *) fail "imports $d (only Windows system DLLs)" ;;
    esac
done
echo "imports: $(tr '\n' ' ' <<<"$dlls")"

want=$(build/beemodel --version)
ran=
if [[ -n "${WINE:-}" ]]; then
    read -ra wine <<<"$WINE"
elif command -v wine >/dev/null; then
    wine=(wine)
elif command -v wine64 >/dev/null; then
    wine=(wine64)
else
    wine=()
fi
if (( ${#wine[@]} )); then
    got=$(WINEDEBUG=-all "${wine[@]}" "$EXE" --version 2>/dev/null | tr -d '\r') || fail "--version under Wine exited with $?"
    [[ "$got" == "$want" ]] || fail "--version under Wine: '$got', not '$want'"
    echo "under Wine: $got"
    for t in build/test-*.exe; do
        [[ -f "$t" ]] || continue
        WINEDEBUG=-all "${wine[@]}" "$t" 2>/dev/null | tr -d '\r' | grep -v '^  ok ' || true
        WINEDEBUG=-all "${wine[@]}" "$t" >/dev/null 2>&1 || fail "$t under Wine: $? checks failed"
        echo "under Wine: $(basename "$t") passed"
    done
    ran+=" Wine"
fi
alive="$HOME/Windows/bee-run/runner.alive"
if [[ -f "$alive" ]] && (( $(date +%s) - $(stat -c %Y "$alive") <= 10 )); then
    got=$("$(dirname "$0")/../tools/winvm-run.sh" --timeout 60 beemodel.exe --version | tr -d '\r') ||
        fail "--version in the Windows 11 VM exited with $?"
    [[ "$got" == "$want" ]] || fail "--version in the Windows 11 VM: '$got', not '$want'"
    echo "in the Windows 11 VM: $got"
    for t in build/test-*.exe; do
        [[ -f "$t" ]] || continue
        out=$("$(dirname "$0")/../tools/winvm-run.sh" --timeout 120 "$(basename "$t")" | tr -d '\r') ||
            { grep -v '^  ok ' <<<"$out"; fail "$t in the Windows 11 VM: $? checks failed"; }
        echo "in the Windows 11 VM: $(basename "$t") passed"
    done
    ran+=" VM"
fi
echo "exe checks passed (run:${ran:- nowhere: no wine, no VM runner})"
