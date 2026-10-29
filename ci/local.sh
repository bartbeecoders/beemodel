#!/usr/bin/env bash
# Run the same checks as CI (.github/workflows/ci.yml) on this machine.
#
#   ci/local.sh          everything, in CI's order
#   ci/local.sh --quick  the build, one self-test, and only the suites that
#                        cover what changed against origin/main (committed or
#                        not); GitHub CI still runs everything on the PR
#   ci/local.sh --only ai,askai   the build, one self-test and those suites
#   ... --dry            only say what would run
#
# Each step is timed; the times, slowest first, are printed at the end and
# kept in build/ci-times.txt. (The two UI walkthroughs, about 13 minutes
# each, cannot run side by side: they serve the live link and host sessions
# on the same ports, and their timing checks slow each other down.)
set -euo pipefail
cd "$(dirname "$0")/.."

QUICK=0
DRY=0
ONLY=
while [ $# -gt 0 ]; do
    case $1 in
        --quick) QUICK=1 ;;
        --dry) DRY=1 ;;
        --only) ONLY=${2:-}; QUICK=1; shift ;;
        *) echo "usage: ci/local.sh [--quick | --only suite,suite...] [--dry]"; exit 2 ;;
    esac
    shift
done

TIMES=$(mktemp)
START=$SECONDS
summary() {
    local rc=$?
    if [ -s "$TIMES" ]; then
        echo
        echo "-- times (s), slowest first; total $((SECONDS - START)) s --"
        sort -t' ' -k2 -nr "$TIMES" | awk '{ printf "%6d  %s\n", $2, $1 }' | tee build/ci-times.txt
    fi
    rm -f "$TIMES"
    exit $rc
}
trap summary EXIT

step() {                                # step <name> <command...>
    local name=$1 t0=$SECONDS
    shift
    if [ $DRY = 1 ]; then
        echo "would run: $*"
        return 0
    fi
    if ! "$@"; then
        echo "$name $((SECONDS - t0))" >> "$TIMES"
        echo "local CI: FAILED in $name"
        return 1
    fi
    echo "$name $((SECONDS - t0))" >> "$TIMES"
}

# The suites: name | timeout (s) | the sources they cover (src/ globs; the
# test's own files always count) | the command. The order is CI's.
SUITES=$(cat <<'EOF'
beescript|300|script.s expr.s|python3 tests/beescript.py build/beemodel
compat|300|fileio.s formats.s scene.s|python3 tests/compat.py build/beemodel
bool_stress|300|bool.s bbool.s|python3 tests/bool_stress.py build/beemodel --cases 300
image_io|300|png.s jpeg.s exr.s imgread.s image.s inflate.s|python3 tests/image_io.py build/beemodel
enclosure|600|cad.s cadui.s sketch*.s feature.s measure.s print*.s fab.s export.s mods*.s shapes.s|python3 tests/enclosure.py build/beemodel
sculpt_paint|300|sculpt.s sculpt.inc paint.s bake.s vcol.s dyntopo.s multires.s layers.s uv*.s|python3 tests/sculpt_paint.py build/beemodel build/shots
procedural|300|geonodes.s graph.s ntree.s procgen.s inst.s nodeed.s|python3 tests/procedural.py build/beemodel build/shots
animation|300|anim*.s rig.s arm.s sdf.s shape.s viewanim.s|python3 tests/animation.py build/beemodel build/shots
sculpt20m|900|sculpt.s sculpt.inc dyntopo.s multires.s|python3 tests/sculpt20m.py build/beemodel
billion|900|vgeo.s vgeo.inc vgdraw.s|python3 tests/billion.py build/beemodel build/shots
world|300|world.s lcam.s|python3 tests/world.py build/beemodel build/shots
library|300|library.s asset.s thumb.s|python3 tests/library.py build/beemodel build/shots
play|300|play.s collide.s|python3 tests/play.py build/beemodel build/shots
logic|300|logic.s|python3 tests/logic.py build/beemodel build/shots
solver|600|rbody.s clip.s collide.s physui.s|python3 tests/solver.py build/beemodel
landscape|600|landscape.s landscape.inc land*.s lsculpt.s lshape.s ground.s|python3 tests/landscape.py build/beemodel
shatter|600|shatter*.s|python3 tests/shatter.py build/beemodel
fields|600|fields.s fieldui.s fieldvm.s fvjit.s|python3 tests/fields.py build/beemodel
particles|1200|particles.s partui.s liquid.s simcache.s simui.s cloth.s nbody.s|python3 tests/particles.py build/beemodel
viewport|600|viewport.s raster.s vpnav.s matcache.s preview.s|python3 tests/viewport.py build/beemodel
camview|300|camview.s viewport.s viewanim.s lcam.s|python3 tests/camview.py build/beemodel
lighting|600|lightmap.s probe.s env.s render.s hive.s denoise.s|python3 tests/lighting.py build/beemodel build/shots
materials|600|material.s mat*.s mtl.s texture.s mcpmat.s|python3 tests/materials.py build/beemodel build/shots
ai|300|ai.s aiproc.s aiask.s widgets.s widgets.inc textfield.s tooltip.s|python3 tests/ai.py build/beemodel build/shots
askai|300|aiask.s ai.s|python3 tests/askai.py build/beemodel build/shots
refs|300|refset.s refimg.s folder.s filebrowser.s|python3 tests/refs.py build/beemodel build/shots
hi3d|300|hi3d.s formats.s export.s|python3 tests/hi3d.py build/beemodel build/shots
mcp_schema|300|mcp.s mcpmat.s agent.s ops.s|python3 tests/mcp_schema.py build/beemodel
blend|600|blend.s blendx.s|python3 tests/blend.py build/beemodel build/shots
livelink|300|live.s link.s|python3 tests/livelink.py build/beemodel build/shots
versions|300|vc.s|python3 tests/versions.py build/beemodel build/shots
coedit|900|cosync.s cotree.s teamui.s copilot.s|python3 tests/coedit.py build/beemodel build/shots
brep|600|brep.s brep.inc bssi.s btess.s bfillet.s bfeat.s bbuild.s bdebug.s nurbs.s curve.s|python3 tests/brep.py build/beemodel
assembly|300|mech.s orient.s parent.s|python3 tests/assembly.py build/beemodel
text|300|text3d.s ttf.s textui.s|python3 tests/text.py build/beemodel
video|300|video.s render.s|python3 tests/video.py build/beemodel build/shots
step|900|step.s stepread.s|python3 tests/step.py build/beemodel
gpu|900|gpu.s gpu/* gpuipc.inc hive_pt.s render.s|python3 tests/gpu.py build/beemodel build/shots
fakewl|1200|ui.s widgets.s widgets.inc panel.s menus.s areas.s workspace.s theme.s font.s font.inc text.s tooltip.s icons.inc status.s dialog.s forms.s palette.s filebrowser.s textfield.s keyboard.s a11y.s help.s prefs.s ctxui.s colorpick.s recent.s draw.s|python3 tools/fakewl.py build/shots
fakewl_bitmap|1200|@fakewl|env BEEMODEL_FONT=none BEEMODEL_MONO_FONT=none BEEMODEL_GOLDEN=check python3 tools/fakewl.py build/shots-bitmap
EOF
)

# --quick: what changed against origin/main, and which suites that picks
ALL=0
declare -A PICK=()
if [ -n "$ONLY" ]; then
    for n in ${ONLY//,/ }; do
        PICK[$n]=1
    done
elif [ $QUICK = 1 ]; then
    base=$(git merge-base HEAD origin/main 2>/dev/null || echo HEAD)
    changed=$( { git diff --name-only "$base"; git ls-files --others --exclude-standard; } | sort -u)
    for f in $changed; do
        case $f in
            src/const.inc|src/macros.inc|src/mem.s|src/jobs.s|src/main.s|src/ops.s|src/scene.s|\
            src/mesh.s|src/undo.s|src/script.s|src/wayland.s|src/window.s|scripts/build.sh|tools/fakewl.py|\
            .github/*|ci/check-binary.sh)
                echo "quick: $f is shared by everything: the full run"
                ALL=1 ;;
            src/plat_win.s|src/plat_win_wnd.s|src/plat_win.inc|src/plat_win.ld|ci/check-exe.sh|tests/win/*|tools/winvm*)
                ;;                          # the Windows build: its check always runs
            tests/golden/*)
                PICK[fakewl_bitmap]=1 ;;
            tests/*)
                n=$(basename "$f"); n=${n%.*}
                [ "$n" = ai_standin ] && n=ai
                [ "$n" = step_ext ] && n=step
                PICK[$n]=1 ;;
            src/*)
                s=${f#src/}
                hit=0
                while IFS='|' read -r name _ globs _; do
                    for g in $globs; do
                        # shellcheck disable=SC2254
                        case $s in $g) PICK[$name]=1; hit=1 ;; esac
                    done
                done <<< "$SUITES"
                if [ $hit = 0 ]; then         # no suite of its own: the UI walkthrough
                    PICK[fakewl]=1
                fi ;;
        esac
    done
    [ -n "${PICK[fakewl]:-}" ] && PICK[fakewl_bitmap]=1
fi

step build scripts/build.sh
step check-binary ci/check-binary.sh build/beemodel
if [ -f build/beemodel.exe ] || [ $DRY = 1 ]; then
    step check-exe ci/check-exe.sh build/beemodel.exe
fi
step selftest ./build/beemodel --selftest
if [ $QUICK = 0 ] || [ $ALL = 1 ]; then
    step selftest-threads0 env BEEMODEL_THREADS=0 ./build/beemodel --selftest
    step selftest-threads3 env BEEMODEL_THREADS=3 ./build/beemodel --selftest
    step debug-build bash -c 'scripts/build.sh debug >/dev/null && scripts/build.sh >/dev/null'
fi

ran=0
while IFS='|' read -r name tmo _ cmd; do
    if [ $QUICK = 1 ] && [ $ALL = 0 ] && [ -z "${PICK[$name]:-}" ]; then
        continue
    fi
    ran=$((ran + 1))
    echo "-- $name --"
    # shellcheck disable=SC2086
    step "$name" timeout "$tmo" $cmd < /dev/null
done <<< "$SUITES"

if [ $QUICK = 1 ] && [ $ALL = 0 ]; then
    echo "local CI (quick): green, $ran suites ($(printf '%s ' "${!PICK[@]}"))"
else
    echo "local CI: all green"
fi
