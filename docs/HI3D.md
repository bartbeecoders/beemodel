# Image to 3D (the Hi3D addon)

**Add › Generate › Model from Image (Hi3D)…** makes a 3D model from a
photo or drawing of one thing. **Object › Refine from Image (Hi3D)…**
carves a photo's detail into a rough model you made yourself. Both run on
your NVIDIA GPU while you keep working. The status bar shows how far it
is; click that chip to stop it.

Powered by [Hi3D 1.0](http://hi3d.ai/).

It is an addon: BeeModel stays one assembly program, and the models
(PyTorch, about 20 GB) are installed only if you want them.

## Install

Needs Linux, an NVIDIA GPU with compute capability 8.0 or newer (RTX 30xx
and later) and a driver for CUDA 12.4, plus `git`, `curl` and
[uv](https://docs.astral.sh/uv/). No CUDA toolkit: everything comes as
prebuilt wheels.

```
addons/hi3d/install.sh            # about 20 GB, mostly downloads
```

That fills `~/.local/share/beemodel/hi3d` (or `$BEEMODEL_HI3D_HOME`):

| | |
|---|---|
| `bee-hi3d` | the helper BeeModel runs |
| `venv/` | Python 3.10, torch 2.5.0+cu124, flash-attn 2.7.4, spconv |
| `src/Hi3Dv1.0`, `src/TripoSR` | the two projects at pinned commits |
| `models/Hi3Dv1.0` | the Hi3D v1.0 weights (7.7 GB) |
| `hf/` | the Hugging Face cache: DINOv2-large, CLIP ViT-L/14, TripoSR |
| `u2net/` | the background-removal model |

`bee-hi3d doctor` checks it. To remove it, delete the folder. Set
`BEEMODEL_HI3D` to use a helper somewhere else.

## Use

```
object.from_image ~/photos/chair.png            # detail 512
object.from_image ~/photos/chair.png 1024
object.refine_from_image ~/photos/chair.png     # the active mesh refined
object.from_image_stop
```

**Model from Image.** TripoSR makes a rough shape from the image in a few
seconds. Then Hi3D works the image's detail into it. The model comes in
named after the image, standing on the 3D cursor, two units at its
largest side. It is one undo step.

**Refine from Image.** Your active mesh is the rough shape instead: a
block-out of the same thing, facing +Z (the front view, Numpad 1, looks
at the side the photo shows). The refined object takes its location,
rotation, scale and size, and the original is hidden.

**Detail** is Hi3D's extraction grid: 512 runs one pass, 1024 two, 1536
three (more detail, more time: see below). The result is simplified to
300,000 faces at most.

**Images.** One object, the whole of it in view. A cut-out with a
transparent background is best. Otherwise the background is removed
(rembg). What the photo doesn't show is invented.

What you get is geometry only: no colours, no textures. Hi3D's own
rule is that the result is centred and scaled to a unit size, so the
true size comes from you: scale it, or refine a block-out made to size.

## Time and memory

Measured on an RTX 4080 SUPER (16 GB) with Hi3D's example image. The
models load from disk each run:

| Detail | Time | GPU memory (peak) | |
|---|---|---|---|
| rough shape only (`--coarse-only`) | 6 s | | TripoSR |
| 512 | 41 s | 9.5 GB | one pass |
| 1024 | 4 min 34 s | 7.7 GB | two passes, offloaded |
| 1536 | | | runs out of memory on 16 GB |

At 1024 and 1536 on a GPU under 24 GB, the helper keeps the models in
system memory between uses (`--offload`; `--no-offload` turns it off).
Without that, 1024 runs out of memory decoding its second pass on 16 GB.
1536 runs out even offloaded, after 12 minutes, so the helper refuses it
up front on GPUs under 20 GB. Hi3D's makers validated it only on a 96 GB
GPU. When memory runs out, the console says so; try a lower detail.

What the helper said is kept in `~/.cache/beemodel/hi3d/hi3d.log`. Its
input and result are in the same folder (`coarse.obj`, `<image>.obj`).

## How it works

```
BeeModel (hi3d.s) ──spawn──▶ bee-hi3d run --image I --out O --resolution R [--coarse C]
        ◀── "@bee progress 0.42 Detail pass 1/2, step 10/25" ──┘
        ◀── "@bee done O 298114" | "@bee error ..."
        object.from_image_place O  (obj_import, one undo step)
```

`src/hi3d.s` starts the helper like the AI connections start theirs
(`plat_spawn`, a pipe read without waiting from the main loop). It
parses only lines that start with `@bee `; everything goes to the log.
For a refine, it first writes the active mesh alone, in its own space
(its transform set aside for the export), to `coarse.obj` with the OBJ
exporter; the refined object gets that transform back.

`addons/hi3d/bee_hi3d.py` is the helper:

1. The image gets an alpha (rembg) unless it has one.
2. Rough shape: TripoSR (MIT, Stability AI and Tripo), marching cubes at
   256³ with scikit-image. It's turned Y-up with the front at +Z, as
   Hi3D's training meshes are. Or the `--coarse` mesh is used.
3. Hi3D v1.0 (`Sparc3DPipeline`): DINOv2 and CLIP image tokens condition
   a sparse flow transformer on the voxels of the rough mesh. A sparse
   VAE decodes signed distances; FlexiCubes extracts the mesh, pass by
   pass (64³ → 512³, 128³ → 1024³, 192³ → 1536³).
4. It's simplified (pyfqmr) and placed: on the floor, or into the rough
   mesh's box. It's written as a plain OBJ.

Why not Hunyuan3D-2, which Hi3D's own demo uses for the rough shape?
Its license does not cover the EU, the UK or South Korea. TripoSR is MIT.
The rough stage is one function in the helper, so another generator can
take its place.

Why not in assembly? Hi3D is two 1.8-billion-parameter transformers that
run on flash-attention and sparse-convolution CUDA kernels. BeeModel keeps
to what it does well: the scene, the UI and the mesh. The model runs where
its kernels are.

## Licenses

Hi3D v1.0's code and weights are under the Hi3D Open License Agreement
1.0. Commercial use is allowed. A commercial product that integrates it
must show "Powered by Hi3D 1.0" with a link to http://hi3d.ai/. BeeModel
shows it in the console when a run starts, in this page and in the
README. Meshes you make are yours. An output that contains no Hi3D
materials carries no branding duty (Section 8 of that agreement).
TripoSR is MIT; DINOv2 is Apache 2.0; CLIP is MIT. None of them is
shipped with BeeModel: `install.sh` downloads them from their makers.
