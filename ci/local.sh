#!/usr/bin/env bash
# Run the same checks as CI (.github/workflows/ci.yml) on this machine.
set -euo pipefail
cd "$(dirname "$0")/.."
scripts/build.sh
ci/check-binary.sh build/beemodel
./build/beemodel --selftest
BEEMODEL_THREADS=0 ./build/beemodel --selftest
BEEMODEL_THREADS=3 ./build/beemodel --selftest
scripts/build.sh debug >/dev/null && scripts/build.sh >/dev/null
timeout 300 python3 tests/beescript.py build/beemodel
timeout 300 python3 tests/compat.py build/beemodel
timeout 300 python3 tests/bool_stress.py build/beemodel --cases 300
timeout 300 python3 tests/image_io.py build/beemodel
timeout 600 python3 tests/enclosure.py build/beemodel
timeout 300 python3 tests/sculpt_paint.py build/beemodel build/shots
timeout 300 python3 tests/procedural.py build/beemodel build/shots
timeout 300 python3 tests/animation.py build/beemodel build/shots
timeout 900 python3 tests/sculpt20m.py build/beemodel
timeout 900 python3 tests/billion.py build/beemodel build/shots
timeout 300 python3 tests/world.py build/beemodel build/shots
timeout 300 python3 tests/library.py build/beemodel build/shots
timeout 300 python3 tests/play.py build/beemodel build/shots
timeout 300 python3 tests/logic.py build/beemodel build/shots
timeout 600 python3 tests/solver.py build/beemodel
timeout 600 python3 tests/landscape.py build/beemodel
timeout 600 python3 tests/shatter.py build/beemodel
timeout 600 python3 tests/fields.py build/beemodel
timeout 1200 python3 tests/particles.py build/beemodel
timeout 600 python3 tests/viewport.py build/beemodel
timeout 600 python3 tests/lighting.py build/beemodel build/shots
timeout 600 python3 tests/materials.py build/beemodel build/shots
timeout 300 python3 tests/ai.py build/beemodel build/shots
timeout 300 python3 tests/askai.py build/beemodel build/shots
timeout 300 python3 tests/mcp_schema.py build/beemodel
timeout 600 python3 tests/blend.py build/beemodel build/shots   # the export round trip when Blender is installed
timeout 300 python3 tests/livelink.py build/beemodel build/shots
timeout 300 python3 tests/versions.py build/beemodel build/shots
timeout 900 python3 tests/coedit.py build/beemodel build/shots
timeout 600 python3 tests/brep.py build/beemodel
timeout 300 python3 tests/assembly.py build/beemodel
timeout 300 python3 tests/text.py build/beemodel
timeout 300 python3 tests/video.py build/beemodel build/shots   # videos when ffmpeg is installed
timeout 900 python3 tests/step.py build/beemodel   # FreeCAD or OCP when installed
timeout 900 python3 tests/gpu.py build/beemodel build/shots   # a Vulkan device when there is one
timeout 1200 python3 tools/fakewl.py build/shots
BEEMODEL_FONT=none BEEMODEL_MONO_FONT=none BEEMODEL_GOLDEN=check \
    timeout 1200 python3 tools/fakewl.py build/shots-bitmap
echo "local CI: all green"
