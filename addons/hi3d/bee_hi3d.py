#!/usr/bin/env python3
"""BeeModel's Image to 3D helper: TripoSR (rough shape) + Hi3D v1.0 (detail).

BeeModel starts this through the `bee-hi3d` launcher that addons/hi3d/install.sh
writes, and reads its standard output. Lines meant for BeeModel start with
"@bee "; everything else (library warnings, tracebacks) is log text:

    @bee progress <0..1> <what it is doing>
    @bee done <obj path> <faces>
    @bee error <one line>
    @bee ok <one line>                  (doctor)

Commands:
    bee-hi3d doctor
    bee-hi3d fetch                      download every model's weights
    bee-hi3d run --image IMG --out OUT.obj [--coarse MESH] [--resolution 512]
                 [--steps 25] [--seed 0] [--faces 300000] [--[no-]offload]
                 [--coarse-only] [--keep-background]

Without --coarse, TripoSR makes the rough shape from the image. With it (an OBJ,
PLY, STL or glTF file BeeModel exported), Hi3D refines that mesh instead. The
result is Y-up, front towards +Z, centred, with a radius of one; BeeModel scales
and places it.
"""

from __future__ import annotations

import argparse
import os
import sys
import time
import traceback
from pathlib import Path

HERE = Path(__file__).resolve().parent
SRC = HERE / "src"
HI3D_MODEL = "hi3d-official/Hi3Dv1.0"
HI3D_DIR = HERE / "models" / "Hi3Dv1.0"   # real files: Hi3D's loader refuses the Hub cache's
                                          #  symlinks once it defers transformer_1024
TSR_MODEL = "stabilityai/TripoSR"
ENCODERS = ("facebook/dinov2-large", "openai/clip-vit-large-patch14", "facebook/dino-vitb16")

_out = sys.stdout
sys.stdout = sys.stderr          # libraries print; only say() reaches BeeModel's parser cleanly


def say(kind: str, text: str = "") -> None:
    _out.write(f"@bee {kind} {' '.join(str(text).split())}\n")
    _out.flush()


def progress(frac: float, text: str) -> None:
    say("progress", f"{max(0.0, min(1.0, frac)):.3f} {text}")


def add_paths() -> None:
    for d in ("TripoSR", "Hi3Dv1.0"):
        p = str(SRC / d)
        if p not in sys.path:
            sys.path.insert(0, p)


# --------------------------------------------------------------------------- doctor
def cmd_doctor(_args) -> int:
    add_paths()
    try:
        import torch
        import sparc3d  # noqa: F401
        import flash_attn  # noqa: F401
        import spconv  # noqa: F401
    except Exception as e:  # noqa: BLE001
        say("error", f"the Python environment is incomplete: {e}")
        return 1
    if not torch.cuda.is_available():
        say("error", "PyTorch sees no CUDA GPU")
        return 1
    name = torch.cuda.get_device_name(0)
    gb = torch.cuda.get_device_properties(0).total_memory / 2**30
    missing = [m for m in (TSR_MODEL, *ENCODERS) if not _cached(m)]
    if not (HI3D_DIR / "transformer_1024" / "model.safetensors").is_file():
        missing.insert(0, HI3D_MODEL)
    if missing:
        say("error", f"weights not downloaded: {', '.join(missing)} (run: bee-hi3d fetch)")
        return 1
    say("ok", f"Hi3D {sparc3d.__version__}, torch {torch.__version__}, {name} {gb:.0f} GB")
    return 0


def _cached(repo: str) -> bool:
    from huggingface_hub import scan_cache_dir
    try:
        return any(r.repo_id == repo for r in scan_cache_dir().repos)
    except Exception:  # noqa: BLE001
        return False


# --------------------------------------------------------------------------- fetch
def cmd_fetch(_args) -> int:
    from huggingface_hub import snapshot_download
    progress(0.0, f"Downloading {HI3D_MODEL}")
    snapshot_download(HI3D_MODEL, local_dir=HI3D_DIR, allow_patterns=["*.json", "*.safetensors"])
    jobs = [
        ("facebook/dinov2-large", ["*.json", "*.safetensors", "*.txt"]),
        ("openai/clip-vit-large-patch14", ["*.json", "*.safetensors", "*.txt"]),
        (TSR_MODEL, ["config.yaml", "model.ckpt"]),
        ("facebook/dino-vitb16", ["config.json"]),     # (TripoSR builds its tokenizer from it)
    ]
    for i, (repo, allow) in enumerate(jobs):
        progress(i / (len(jobs) + 1), f"Downloading {repo}")
        snapshot_download(repo, allow_patterns=allow)
    progress(len(jobs) / (len(jobs) + 1), "Downloading the background-removal model")
    import rembg
    rembg.new_session("u2net")
    say("ok", "all weights downloaded")
    return 0


# --------------------------------------------------------------------------- run
def _cutout(image, keep_background: bool):
    """RGBA with the subject's alpha: an image that already has one keeps it."""
    from PIL import Image
    if image.mode in ("RGBA", "LA") and image.getchannel("A").getextrema()[0] < 250:
        return image.convert("RGBA")
    if keep_background:
        return image.convert("RGBA")
    import rembg
    return rembg.remove(image.convert("RGB"), session=rembg.new_session("u2net")).convert("RGBA")


def _marching_cubes_shim() -> None:
    """TripoSR imports torchmcubes (a CUDA source build); give it scikit-image's."""
    import types
    import numpy as np
    import torch
    from skimage import measure

    def marching_cubes(vol, thresh):
        v = vol.detach().float().cpu().numpy()
        verts, faces, _n, _v = measure.marching_cubes(v, float(thresh))
        verts = verts[:, ::-1].copy()              # torchmcubes gives (w, h, d)
        return torch.from_numpy(verts.astype(np.float32)), torch.from_numpy(faces.astype(np.int64))

    mod = types.ModuleType("torchmcubes")
    mod.marching_cubes = marching_cubes
    sys.modules.setdefault("torchmcubes", mod)


def coarse_from_image(rgba, device: str):
    """TripoSR: the rough shape, turned to Y-up with the photo's side at +Z, as Hi3D's
    training meshes (Hunyuan3D-2) are; seen from +Z it is the photo, not its mirror."""
    import numpy as np
    import torch
    import trimesh
    from PIL import Image
    _marching_cubes_shim()
    from tsr.system import TSR
    from tsr.utils import resize_foreground

    img = resize_foreground(rgba, 0.85)
    a = np.asarray(img).astype(np.float32) / 255.0
    a = a[:, :, :3] * a[:, :, 3:4] + (1 - a[:, :, 3:4]) * 0.5
    img = Image.fromarray((a * 255.0).astype(np.uint8))

    model = TSR.from_pretrained(TSR_MODEL, config_name="config.yaml", weight_name="model.ckpt")
    model.renderer.set_chunk_size(8192)
    model.to(device)
    with torch.no_grad():
        codes = model([img], device=device)
        mesh = model.extract_mesh(codes, False, resolution=256)[0]
    del model, codes
    torch.cuda.empty_cache()
    mesh.apply_transform(trimesh.transformations.rotation_matrix(-np.pi / 2, [1, 0, 0]))
    mesh.apply_transform(trimesh.transformations.rotation_matrix(-np.pi / 2, [0, 1, 0]))
    trimesh.repair.fix_normals(mesh)
    return mesh


def decimate(mesh, faces: int):
    if faces <= 0 or len(mesh.faces) <= faces:
        return mesh
    import pyfqmr
    import trimesh
    s = pyfqmr.Simplify()
    s.setMesh(mesh.vertices, mesh.faces)
    s.simplify_mesh(target_count=faces, aggressiveness=7, preserve_border=True, verbose=False)
    v, f, _n = s.getMesh()
    return trimesh.Trimesh(v, f, process=False)


def write_obj(mesh, path: Path) -> None:
    """A plain OBJ (v / f only): BeeModel's importer reads it fastest."""
    import numpy as np
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(path.suffix + ".part")
    with open(tmp, "w") as f:
        f.write("# BeeModel Image to 3D (Powered by Hi3D 1.0, http://hi3d.ai/)\n")
        np.savetxt(f, np.asarray(mesh.vertices, dtype=np.float64), fmt="v %.6f %.6f %.6f")
        np.savetxt(f, np.asarray(mesh.faces, dtype=np.int64) + 1, fmt="f %d %d %d")
    os.replace(tmp, path)


def normalise(mesh):
    """Centred on its bounding box, radius one (Hi3D's output is like this)."""
    import numpy as np
    lo, hi = mesh.bounds
    mesh.apply_translation(-(lo + hi) / 2)
    r = float(np.linalg.norm(mesh.vertices, axis=1).max()) or 1.0
    mesh.apply_scale(1.0 / r)
    return mesh


def place(mesh, box=None):
    """Into BeeModel's space: into box (the rough mesh's bounds: refined in its
    place, its largest side kept), or standing on y = 0, two units at its
    largest, centred on x and z (a new model, put at the 3D cursor)."""
    import numpy as np
    lo, hi = mesh.bounds
    size = float((hi - lo).max()) or 1.0
    if box is None:
        mesh.apply_translation(-np.array([(lo[0] + hi[0]) / 2, lo[1], (lo[2] + hi[2]) / 2]))
        mesh.apply_scale(2.0 / size)
    else:
        blo, bhi = box
        mesh.apply_translation(-(lo + hi) / 2)
        mesh.apply_scale(float((bhi - blo).max()) / size)
        mesh.apply_translation((blo + bhi) / 2)
    return mesh


def cmd_run(args) -> int:
    add_paths()
    if not args.online:
        os.environ.setdefault("HF_HUB_OFFLINE", "1")
    t0 = time.time()
    import torch
    import trimesh
    from PIL import Image
    if not torch.cuda.is_available():
        say("error", "PyTorch sees no CUDA GPU")
        return 1
    device = "cuda"
    gb = torch.cuda.get_device_properties(0).total_memory / 2**30
    if args.resolution == 1536 and gb < 20 and not args.force:
        # (measured: a 16 GB RTX 4080 SUPER runs out decoding the third pass, offloaded, after 12 min)
        say("error", f"detail 1536 needs more than {gb:.0f} GB of GPU memory: use 1024")
        return 1

    progress(0.01, "Reading the image")
    image = Image.open(args.image)
    image.load()
    rgba = _cutout(image, args.keep_background)

    if args.coarse:
        progress(0.04, "Reading the rough mesh")
        coarse = trimesh.load(args.coarse, force="mesh", process=False)
        box = coarse.bounds.copy()
    else:
        box = None
        progress(0.04, "Rough shape (TripoSR)")
        coarse = coarse_from_image(rgba, device)
    coarse = normalise(coarse)
    if args.coarse_only:
        write_obj(place(coarse.copy(), box), Path(args.out))
        say("done", f"{args.out} {len(coarse.faces)}")
        return 0

    passes = {512: 1, 1024: 2, 1536: 3}[args.resolution]
    base, span = 0.12, 0.8

    def report(ev):
        done = (ev.pass_index + ev.step / ev.num_inference_steps) / ev.num_passes
        progress(base + span * done,
                 f"Detail pass {ev.pass_index + 1}/{ev.num_passes}, step {ev.step}/{ev.num_inference_steps}")

    progress(0.08, "Loading Hi3D")
    from sparc3d import Sparc3DPipeline
    pipe = Sparc3DPipeline.from_pretrained(str(HI3D_DIR), progress_callback=report,
                                           local_files_only=not args.online)
    offload = args.offload
    if offload is None:     # (16 GB runs out decoding 1024's second pass with both transformers in)
        offload = args.resolution > 512 and gb < 24
    args.offloaded = offload
    if offload:
        pipe.enable_sequential_cpu_offload(device)
    else:
        pipe.to(device)
    progress(base, f"Detail pass 1/{passes}")
    out = pipe(rgba, coarse, resolution=args.resolution,
               num_inference_steps=args.steps, seed=args.seed)
    mesh = out.mesh
    del pipe
    torch.cuda.empty_cache()

    progress(0.93, f"Simplifying {len(mesh.faces)} faces")
    mesh = place(decimate(mesh, args.faces), box)
    progress(0.97, "Writing the mesh")
    write_obj(mesh, Path(args.out))
    print(f"bee-hi3d: {len(mesh.faces)} faces in {time.time() - t0:.0f} s, "
          f"peak {torch.cuda.max_memory_allocated() / 2**30:.1f} GB", file=sys.stderr)
    say("done", f"{args.out} {len(mesh.faces)}")
    return 0


def main(argv=None) -> int:
    p = argparse.ArgumentParser(prog="bee-hi3d", description=__doc__,
                                formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = p.add_subparsers(dest="cmd", required=True)
    sub.add_parser("doctor")
    sub.add_parser("fetch")
    r = sub.add_parser("run")
    r.add_argument("--image", required=True)
    r.add_argument("--out", required=True)
    r.add_argument("--coarse")
    r.add_argument("--resolution", type=int, choices=(512, 1024, 1536), default=512)
    r.add_argument("--steps", type=int, default=25)
    r.add_argument("--seed", type=int, default=0)
    r.add_argument("--faces", type=int, default=300000)
    r.add_argument("--offload", action=argparse.BooleanOptionalAction, default=None,
                   help="keep the models in system memory between uses (default: above 512 on GPUs under 24 GB)")
    r.add_argument("--coarse-only", action="store_true")
    r.add_argument("--keep-background", action="store_true")
    r.add_argument("--online", action="store_true")
    r.add_argument("--force", action="store_true", help="try a detail this GPU is known to be too small for")
    args = p.parse_args(argv)
    try:
        return {"doctor": cmd_doctor, "fetch": cmd_fetch, "run": cmd_run}[args.cmd](args)
    except Exception as e:  # noqa: BLE001
        traceback.print_exc()
        msg = str(e).splitlines()[0] if str(e) else type(e).__name__
        if isinstance(e, MemoryError) or "out of memory" in msg.lower():
            msg = ("the GPU ran out of memory: try a lower detail" if getattr(args, "offloaded", False)
                   else "the GPU ran out of memory: try a lower detail or --offload")
        say("error", msg)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
