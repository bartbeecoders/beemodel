#!/usr/bin/env bash
# =============================================================================
#  BeeModel addon "Image to 3D" (Hi3D v1.0 + TripoSR): installer
#
#  BeeModel itself stays one assembly program. The models run in a Python
#  helper, bee-hi3d, that BeeModel starts when you ask for a model from an
#  image (docs/HI3D.md). This script puts that helper and everything it
#  needs in one folder:
#
#    ~/.local/share/beemodel/hi3d/          (or $BEEMODEL_HI3D_HOME)
#      bee-hi3d          the launcher BeeModel runs
#      bee_hi3d.py       the bridge (copied from this folder)
#      venv/             Python 3.10, torch 2.5.0+cu124, flash-attn, spconv
#      src/Hi3Dv1.0      github.com/hi3d-official/Hi3Dv1.0 at a pinned commit
#      src/TripoSR       github.com/VAST-AI-Research/TripoSR at a pinned commit
#      models/Hi3Dv1.0   the Hi3D v1.0 weights (7.7 GB, real files)
#      hf/               Hugging Face cache: DINOv2, CLIP, TripoSR weights
#      u2net/            the background-removal model (rembg)
#
#  Needs: Linux, an NVIDIA GPU (compute capability 8.0+, driver for CUDA
#  12.4), git, curl and uv (https://docs.astral.sh/uv/). About 20 GB.
#  No CUDA toolkit: every GPU package comes as a prebuilt wheel.
#
#  Usage: addons/hi3d/install.sh [--no-weights]
#  Remove: rm -rf ~/.local/share/beemodel/hi3d
# =============================================================================
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOME_DIR="${BEEMODEL_HI3D_HOME:-$HOME/.local/share/beemodel/hi3d}"
HI3D_REPO=https://github.com/hi3d-official/Hi3Dv1.0
HI3D_REV=13657ad09afaa92e350b461a1cd66399e44a59c4
TSR_REPO=https://github.com/VAST-AI-Research/TripoSR
TSR_REV=107cefdc244c39106fa830359024f6a2f1c78871
TORCH_INDEX=https://download.pytorch.org/whl/cu124
FLASH_WHL=https://github.com/Dao-AILab/flash-attention/releases/download/v2.7.4.post1/flash_attn-2.7.4.post1+cu12torch2.5cxx11abiFALSE-cp310-cp310-linux_x86_64.whl

step() { printf '\n== %s\n' "$*"; }
die() { printf 'install: %s\n' "$*" >&2; exit 1; }

command -v git >/dev/null || die "git is needed"
command -v uv >/dev/null || die "uv is needed: https://docs.astral.sh/uv/getting-started/installation/"
command -v nvidia-smi >/dev/null || die "no NVIDIA driver found (nvidia-smi): Hi3D runs on NVIDIA GPUs only"
cap=$(nvidia-smi --query-gpu=compute_cap --format=csv,noheader | head -1)
[ "${cap%%.*}" -ge 8 ] || die "the GPU's compute capability is $cap; Hi3D needs 8.0 or newer"

mkdir -p "$HOME_DIR/src" "$HOME_DIR/hf" "$HOME_DIR/u2net"

fetch_repo() {   # fetch_repo url rev dir
    if [ ! -d "$3/.git" ]; then
        git init -q "$3"
        git -C "$3" remote add origin "$1"
    fi
    git -C "$3" fetch -q --depth 1 origin "$2"
    git -C "$3" checkout -q --force FETCH_HEAD
}

step "sources (Hi3D $HI3D_REV, TripoSR $TSR_REV)"
fetch_repo "$HI3D_REPO" "$HI3D_REV" "$HOME_DIR/src/Hi3Dv1.0"
fetch_repo "$TSR_REPO" "$TSR_REV" "$HOME_DIR/src/TripoSR"

step "Python 3.10 environment"
[ -x "$HOME_DIR/venv/bin/python" ] || uv venv -q --python 3.10 "$HOME_DIR/venv"
PY="$HOME_DIR/venv/bin/python"
pipi() { VIRTUAL_ENV="$HOME_DIR/venv" uv pip install --python "$PY" "$@"; }
CONS="$HOME_DIR/src/Hi3Dv1.0/docker/constraints.txt"

step "torch 2.5.0+cu124"
pipi --index-url "$TORCH_INDEX" torch==2.5.0+cu124 torchvision==0.20.0+cu124
step "flash-attn 2.7.4.post1 (prebuilt wheel)"
pipi "$FLASH_WHL"
step "Hi3D v1.0 and its kernels"
pipi --index-strategy unsafe-best-match --extra-index-url "$TORCH_INDEX" \
    -c "$CONS" -e "$HOME_DIR/src/Hi3Dv1.0[inference]"
step "TripoSR's needs and background removal"
# TripoSR's own requirements pin old transformers/trimesh and want torchmcubes
# (a CUDA source build); the bridge does its marching cubes with scikit-image.
pipi --index-strategy unsafe-best-match --extra-index-url "$TORCH_INDEX" -c "$CONS" \
    omegaconf einops scikit-image "rembg[cpu]<2.0.70" "onnxruntime<1.21" \
    "setuptools<81"     # (Triton 3.1 imports it to build its kernels' launchers; uv venvs have none)

step "the bridge"
install -m 0644 "$HERE/bee_hi3d.py" "$HOME_DIR/bee_hi3d.py"
cat > "$HOME_DIR/bee-hi3d" <<EOF
#!/bin/sh
# BeeModel's Image to 3D helper (written by addons/hi3d/install.sh)
D="\$(dirname "\$(readlink -f "\$0")")"
export HF_HOME="\$D/hf" U2NET_HOME="\$D/u2net" PYTHONNOUSERSITE=1
export PYTORCH_CUDA_ALLOC_CONF="\${PYTORCH_CUDA_ALLOC_CONF:-expandable_segments:True}"
exec "\$D/venv/bin/python" -u "\$D/bee_hi3d.py" "\$@"
EOF
chmod 0755 "$HOME_DIR/bee-hi3d"

if [ "${1:-}" != "--no-weights" ]; then
    step "weights (Hi3D 7.7 GB, DINOv2, CLIP, TripoSR, u2net)"
    "$HOME_DIR/bee-hi3d" fetch
fi

step "check"
"$HOME_DIR/bee-hi3d" doctor
printf '\nInstalled in %s\n' "$HOME_DIR"
