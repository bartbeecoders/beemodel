#!/usr/bin/env bash
# Builds the Coca-Cola commercial in a running BeeModel through its MCP socket,
# then plays it. Start BeeModel first (scripts/run.sh); it replaces the open scene.
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p out && rm -f out/chunk*.bees && python3 gen.py > /dev/null
for f in out/chunk*.bees; do echo "$f: $(python3 mcp.py script "$f" | grep -v '^$' | tail -1)"; done
python3 mcp.py op_view_shading_material > /dev/null
python3 mcp.py run_operator '{"id":"anim.play"}' > /dev/null
echo "playing: 240 frames at 30 fps, looping (Space pauses)"
