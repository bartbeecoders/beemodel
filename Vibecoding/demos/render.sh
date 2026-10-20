#!/usr/bin/env bash
# Renders a demo to an MP4, headless: the script runs in a throwaway HOME,
# every frame is path-traced through the demo's camera (render_frames: the
# next frame is built while the GPU traces one), then ffmpeg joins them.
#   ./render.sh wrecking-ball [width height samples]    -> out/wrecking-ball.mp4
set -euo pipefail
cd "$(dirname "$0")"
demo=${1%.bees}; w=${2:-1280}; h=${3:-720}; spp=${4:-48}
bin=../../build/beemodel
[[ -x $bin ]] || { echo "build BeeModel first (scripts/build.sh)" >&2; exit 1; }
tmp=$(mktemp -d /tmp/bee-demo-XXXXXX); trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/BeeModel" "$tmp/frames" out
end=$(grep -o 'anim.range", "1 [0-9]*' "$demo.bees" | grep -o '[0-9]*$')
fps=$(grep -o 'anim.range", "1 [0-9]* [0-9]*' "$demo.bees" | grep -o '[0-9]*$')
{ cat "$demo.bees"; cat <<BEES
f = 1
while f <= $end { last = min(f + 29, $end)
  render_frames("$tmp/frames", f, last, $w, $h, $spp, 1)
  print("frame", last, "of $end")
  f = last + 1 }
BEES
} > "$tmp/run.bees"
HOME=$tmp XDG_CACHE_HOME= "$bin" --run "$tmp/run.bees" 2>&1 | grep -v -i 'shader cache'
ffmpeg -loglevel error -y -framerate "$fps" -pattern_type glob -i "$tmp/frames/*.png" \
    -c:v libx264 -pix_fmt yuv420p -crf 18 "out/$demo.mp4"
echo "out/$demo.mp4"
