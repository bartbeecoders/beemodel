#!/usr/bin/env bash
# Run the same checks as CI (.github/workflows/ci.yml) on this machine.
set -euo pipefail
cd "$(dirname "$0")/.."
./build.sh
ci/check-binary.sh build/beemodel
./build/beemodel --selftest
BEEMODEL_THREADS=0 ./build/beemodel --selftest
BEEMODEL_THREADS=3 ./build/beemodel --selftest
./build.sh debug >/dev/null && ./build.sh >/dev/null
timeout 300 python3 tests/bool_stress.py build/beemodel --cases 300
timeout 300 python3 tests/image_io.py build/beemodel
timeout 600 python3 tests/enclosure.py build/beemodel
timeout 300 python3 tests/sculpt_paint.py build/beemodel build/shots
timeout 900 python3 tests/sculpt20m.py build/beemodel
timeout 300 python3 tools/fakewl.py build/shots
BEEMODEL_FONT=none BEEMODEL_MONO_FONT=none BEEMODEL_GOLDEN=check \
    timeout 300 python3 tools/fakewl.py build/shots-bitmap
echo "local CI: all green"
