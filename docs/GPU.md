# The GPU helper (beemodel-gpu)

BeeModel links nothing: no libc and no Vulkan loader. The GPU is reached
through a separate, optional program, `beemodel-gpu`, which links the Vulkan
loader (`libvulkan.so.1`) and runs compute shaders for BeeModel. When it is
missing, or cannot help, everything runs on the CPU as before, with the same
images.

## Installing it

Unpack `beemodel-gpu-<version>-linux-x86_64.tar.gz` (the release's second
asset) next to the `beemodel` binary. BeeModel looks for `beemodel-gpu` in
the directory of its own executable, or at `BEEMODEL_GPU_HELPER` if that is
set. Building from source makes `build/beemodel-gpu` whenever a C linker
driver (`cc`) and `libvulkan.so.1` are present.

| Variable | Effect |
|---|---|
| `BEEMODEL_GPU=off` (or `0`) | Never start the helper |
| `BEEMODEL_GPU=any` | Also accept a CPU Vulkan implementation (llvmpipe), which the tests use. Otherwise discrete GPUs come first, then integrated and virtual ones |
| `BEEMODEL_GPU_HELPER=path` | Where the helper is |
| `BEEMODEL_GPU_RASTER=all` / `off` | Rasterize every frame's tiles on the GPU, or none. By default only frames with objects drawn through cluster DAGs use it |

The helper needs a Vulkan device with compute queues and 64-bit integers in
shaders. The console reports the device (`GPU helper: <name>`), or says the
helper is not used.

## How it works

BeeModel starts the helper on first use (`src/gpu.s`). It runs as a child
process with a `SOCK_SEQPACKET` socket on its fd 3, using the protocol in
`src/gpuipc.inc`:

1. The helper answers `MSG_HELLO` with its device, or with why it has none.
2. Bulk data goes through shared memory, one memfd per *slot*: slot 0 is the
   path tracer, slot 1 the rasterizer. The memfd is passed with `MSG_MAP`
   (`SCM_RIGHTS`).
3. A slot's memory starts with a table of bindings: where each storage
   buffer of the kernel lies, and whether to copy it to the GPU before the
   dispatch and back after it.
4. `MSG_RUN` copies the inputs through a host-visible staging buffer into
   device-local buffers, dispatches the kernel, copies the outputs back into
   the shared memory, and replies.

The helper (`src/gpu/helper.s`) is written in assembly too. It loads every
Vulkan function through `vkGetInstanceProcAddr`. Its shaders are GLSL
(`src/gpu/*.comp`), compiled to SPIR-V by `tools/genspv.py` into
`src/gpu/spv.s`, which is committed, so building needs no shader compiler.

### Path tracing (`pt.comp`)

`hive_start` hands the scene to slot 0 when the GPU can render it
(`gpu_pt_begin`). From then on the render's passes run there:

- **Data:** the triangles, normals, materials, vertex colours, the CPU's
  BVH4 nodes as they are, and the emissive-triangle CDF. The accumulators
  (`hv_accum`, `hv_aux`, `hv_m2`) live in the shared memory.
- **Batches:** progressive renders size each batch to the frame budget;
  `render.image` runs 16 samples a dispatch.
- **Algorithm:** the shader is a line-for-line port of `hive_pt.s` and
  `hive.s`: the same camera rays, the same xorshift64* streams (hashed from
  pixel, sample and seed), the same BSDF, lights, MIS and Russian roulette.
  Arithmetic that decides a path is marked `precise`. A path therefore
  takes the same decisions as on the CPU until a rounding difference
  changes one.
- **Agreement:** the test sees the default scene pixel-identical. A scene
  with glass, metal, clearcoat, emission, a point light and vertex colours
  differs by 0.01 levels on average, with 99.5% of pixels identical.

Shader graphs run on the GPU too (v0.13): a second build of the shader
(`ptg`, made the first time a scene needs it) interprets each material's
node graph per hit: texture samples (the images go up as 8-bit texels),
texture coordinates, checker, gradient and noise patterns, mix, ramp, math
and vector math, separate / combine, invert, constants and parameters,
and the bump and normal-map normals. Masked, translucent and one-sided
materials let rays through as on the CPU (by chance, as much as they do).
Scenes the shader does not cover stay on the CPU: an HDRI world, or a
graph with another node type (Voronoi, bricks, wave, functions ...) or an
HDR image in it.

On an RTX 4080 SUPER, 128 samples of that scene at 1920 x 1080 take 0.9 s,
including the scene upload and readback. The CPU path takes 9.8 s on 32
threads.

### Rasterization (`raster.comp`)

The viewport rasterizer (`raster.s`) still transforms, sets up and bins the
triangles into 16 x 16 tiles on the CPU. Its tile stage can run on the GPU
instead (`gpu_rs_tiles`):

- one workgroup per tile and one invocation per pixel;
- each pixel walks the tile's triangles in submission order with
  `raster_tri`'s arithmetic: the edge functions at the row's 4-pixel group
  plus whole steps, and 1/z from the scaled vertex weights;
- a triangle replaces the pixel only when it is strictly nearer, as on the
  CPU.

Depth, object ids, the visibility buffer and colour come back exactly as
the CPU leaves them, so the frame is pixel-identical. By default this runs
for frames that draw objects through cluster DAGs (virtualized geometry),
including both batches of the occlusion pass.

### Falling back

- **Missing or unusable:** no helper, no device, a scene `pt.comp` does not
  cover, or `BEEMODEL_GPU=off` all mean the CPU paths.
- **Failure mid-render:** if the helper fails or dies mid-way (a run times
  out, the socket closes), BeeModel stops it for the session and goes on
  on the CPU from where it was. The accumulators hold every finished
  sample, and the CPU continues the same random streams, so the image is
  still the one the CPU alone would make.

## BeeScript

`gpu(k)` returns:

| k | Value |
|---|---|
| 0 | 1 if the helper runs (starts it) |
| 1 | the device type: 1 integrated, 2 discrete, 3 virtual, 4 CPU |
| 2 | path tracer runs |
| 3 | raster batches |
| 4 | samples traced on the GPU |
| 5 | GPU-side milliseconds |
| 6 | 1 if the current render runs on the GPU |

[tests/gpu.py](../tests/gpu.py) checks:

- the fallbacks;
- the path tracer against the CPU, including the denoised render;
- the helper dying at its second run (`BEEMODEL_GPU_FAIL=2`, a test hook);
- the rasterizer's frame in the fake compositor.

CI runs it on llvmpipe.
