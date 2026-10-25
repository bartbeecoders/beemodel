#!/usr/bin/env bash
# Run a command in the Windows 11 VM (omarchy-windows-vm) and give back its
# output and exit code, through the folder the VM shares (~/Windows; the VM
# forwards only RDP, no SSH). The guest's side is tools/winvm/runner.ps1,
# set up once with tools/winvm/setup.ps1 (see there). build/beemodel.exe
# and build/test-*.exe go along and run from the job's folder:
#   tools/winvm-run.sh beemodel.exe --version
#   tools/winvm-run.sh --timeout 600 beemodel.exe --eval "print(1)"
# The command is a cmd.exe line (several: separated by \r\n). Exit codes
# outside 0..255 (0xC0000005: a crash) are printed and give 1. Exits 3 when
# the runner is not running. BEE_WINVM_SHARE overrides ~/Windows.
set -euo pipefail
cd "$(dirname "$0")/.."
TIMEOUT=120
if [[ "${1:-}" == --timeout ]]; then TIMEOUT=$2; shift 2; fi
[[ $# -gt 0 ]] || { echo "usage: tools/winvm-run.sh [--timeout s] <command line>" >&2; exit 2; }
SHARE="${BEE_WINVM_SHARE:-$HOME/Windows}/bee-run"
# Writable for all: the guest reaches the share as another user, and a file
# it may only read (0644) it cannot delete either.
umask 000
mkdir -p "$SHARE/bin"
chmod -R a+rwX "$SHARE"
# Each file goes out under a name of its own content: the guest's network-file
# cache can keep serving a file overwritten here.
publish() {                             # publish <file> <prefix>
    local h; h=$(sha256sum "$1" | cut -c1-8)
    if [[ ! -f "$SHARE/$2-$h.ps1" ]]; then
        rm -f "$SHARE/$2"-*.ps1
        cp "$1" "$SHARE/$2-$h.ps1"
    fi
}
publish tools/winvm/runner.ps1 runner
publish tools/winvm/setup.ps1 setup
cp tools/winvm/boot.ps1 "$SHARE/boot.ps1"   # (read once, by a fresh setup)
alive="$SHARE/runner.alive"
fresh() { [[ -f "$alive" ]] && (( $(date +%s) - $(stat -c %Y "$alive") <= 10 )); }
for _ in $(seq 60); do                  # (no heartbeat while a job runs)
    fresh && break
    sleep 0.5
done
if ! fresh; then
    echo "winvm-run: the runner in the VM is not running; set it up once (tools/winvm/setup.ps1):" >&2
    echo "  powershell -ExecutionPolicy Bypass -File \\\\host.lan\\Data\\bee-run\\$(basename "$SHARE"/setup-*.ps1)" >&2
    exit 3
fi
for f in build/beemodel.exe build/test-*.exe; do
    [[ -f "$f" ]] && cp "$f" "$SHARE/bin/"
done
id="job$(date +%s%N)"
echo "$TIMEOUT" > "$SHARE/$id.limit"
printf '@echo off\r\n%s\r\nexit /b %%errorlevel%%\r\n' "$*" > "$SHARE/$id.tmp"
mv "$SHARE/$id.tmp" "$SHARE/$id.cmd"
end=$((SECONDS + TIMEOUT + 30))
until [[ -f "$SHARE/$id.rc" ]]; do
    if (( SECONDS >= end )); then
        echo "winvm-run: no answer in ${TIMEOUT} s (see $SHARE/runner.log)" >&2
        rm -f "$SHARE/$id.cmd" "$SHARE/$id.limit"
        exit 124
    fi
    sleep 0.3
done
sleep 0.2
cat "$SHARE/$id.out" 2>/dev/null || true
rc=$(tr -dc '0-9-' < "$SHARE/$id.rc")
rm -f "$SHARE/$id.out" "$SHARE/$id.rc"
rc=${rc:-1}
if (( rc < 0 || rc > 255 )); then               # (an exit code is 0..255 here)
    printf 'winvm-run: exit code %d (0x%08X)\n' "$rc" $(( rc & 0xFFFFFFFF )) >&2
    exit 1
fi
exit "$rc"
