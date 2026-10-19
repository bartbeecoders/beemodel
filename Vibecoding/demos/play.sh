#!/usr/bin/env bash
# Builds a demo in a running BeeModel through its MCP socket and plays it.
# Start BeeModel first (scripts/run.sh); the demo replaces the open scene.
#   ./play.sh gallery-smash
set -euo pipefail
cd "$(dirname "$0")"
demo=${1%.bees}
mcp=mcp.py
python3 $mcp script "$demo.bees" | grep -v '^$' | tail -3
python3 $mcp op_view_shading_material > /dev/null
python3 $mcp run_operator '{"id":"anim.play"}' > /dev/null
echo "playing $demo (Space pauses; the first pass simulates, later loops replay the cache)"
