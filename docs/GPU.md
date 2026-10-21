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
| `BEEMODEL_GPU_VIEW=off` | Draw the 3D viewport on the CPU even with a helper that can draw it (v0.24; the window tests' default, so their images are the CPU's) |
| `BEEMODEL_GPU_LIQUID=off` | Solve liquids on the CPU even with a helper that can (v0.24) |
| `BEEMODEL_GPU_HOSTMEM=off` | Copy through the helper's own staging buffers instead of importing the shared memory |

The helper needs a Vulkan device with compute queues and 64-bit integers in
shaders. The console reports the device (`GPU helper: <name>`), or says the
helper is not used.

## Choosing the device

**Properties › Render › Device** (and **Preferences › System › Render
device**, `render.device auto|rtx|gpu|cpu`) picks where renders run:

- **Auto**: the best there is: RTX ray tracing when the GPU has it, else
  the GPU's compute path, else the CPU.
- **GPU (RTX)**: ray queries when the GPU has them, else the compute path
  (when neither can render the scene, the CPU does).
- **GPU**: the compute path (its own BVH), even on an RTX card.
- **CPU**: never the GPU.

Under it the panel says the GPU found, and after a render where it ran:
"Last render: on the GPU (RTX)", "on the GPU", or "on the CPU (an HDRI
world)" and the like.
The Render area's header says GPU or CPU next to the samples, and the
console's "rendering ..." line says where and why. `gpu(18)` gives the
reason as a number.

## How it works

The window starts the helper in the background as BeeModel opens
(`gpu_prewarm`, v0.23), and asks it (`MSG_WARM`) to make every kernel,
the shader graphs' too, so the first render finds it ready (with RTX and
Device on Auto or RTX, all but the compute path's graph kernel, which is
made if it is ever asked for); scripts
(`--eval`, `--run`) start it on first use (`src/gpu.s`). Building the
kernels is the slow part of a cold start (3.5 s on an RTX 4080 SUPER the
first time); the driver keeps the compiled pipelines in its own disk cache
(`~/.cache/nvidia`), after which the helper is up in about 0.1 s. It runs as a child
process with a `SOCK_SEQPACKET` socket on its fd 3, using the protocol in
`src/gpuipc.inc`:

1. The helper answers `MSG_HELLO` with its device, or with why it has none.
2. Bulk data goes through shared memory, one memfd per *slot*: slot 0 is the
   path tracer, slot 1 the rasterizer, slot 2 the live viewport. The memfd is passed with `MSG_MAP`
   (`SCM_RIGHTS`).
3. A slot's memory starts with a table of bindings: where each storage
   buffer of the kernel lies, and whether to copy it to the GPU before the
   dispatch and back after it.
4. `MSG_RUN` copies the inputs through a host-visible staging buffer into
   device-local buffers, dispatches the kernel, copies the outputs back into
   the shared memory, and replies. An input can instead go up in pieces:
   the ranges of it that changed, listed after the table (v0.23).

The scene stays on the GPU between renders (v0.23). Each binding of a slot
gets an eighth more room than it needs, so the next scene keeps the same
layout while it fits. The slot's memory then still holds the last scene,
and the device its copy. A new scene is compared with it in 4 KiB blocks
(256 KiB chunks across the threads), and only the blocks that differ are
written and listed (`gpu.s`'s `put_delta`). For an animation frame of the
rainstorm demo (525k triangles, 94k balls) that is 7.7 MB of the scene's
100 MB. The same scene again sends only its constants (5 KiB). A scene that
outgrows its room, or a new image size, gets a new layout and goes up whole.
A binding that grows into its room sends its new part whole (`gd_sent`):
the device never had those bytes, so a block that matches the slot's
memory there says nothing about the device's copy.
The accumulators never go up: the first pass of a render starts the sums,
which the shader keeps in registers and stores once a pass.

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
texture coordinates, the vertex colour (v0.23), checker, gradient and noise patterns, mix, ramp, math
and vector math, separate / combine, invert, constants and parameters,
and the bump and normal-map normals. Masked, translucent and one-sided
materials let rays through as on the CPU (by chance, as much as they do).
Shadow catchers (the Ground) run there too (v0.23): with one in the scene the
render's film keeps an alpha, and the shader sums the same four terms a
pixel as the CPU (seen, a catcher seen, its light unshadowed and lit); the
catcher's shadow ray is the path's own light-sample ray, told to let
catchers through. The image and its alpha match the CPU's.
An HDRI world runs there too (v0.23): its texels go up as rgb floats (8-bit
images through the sRGB curve), with env.s's importance-sampling tables
(the conditional CDF per row, the row sums, the marginal) behind a small
header (size, total, rotation, strength). The shader looks it up, samples
it and weighs it (MIS) as `env.s` does, so the image matches the CPU's.
Rendered shading draws it as well.
Motion blur (v0.23, [PARTICLES.md](PARTICLES.md)) draws a time per
sample, after the pixel's jitter (`cam[15]` says the balls move); a ball
is at `c + v t` then, `v` its movement while the shutter is open.
Particle balls are exact spheres (v0.23): a 48-byte record each (centre,
radius, material, colour; binding 19) behind the triangles in one BVH,
their own subtree under the root so a leaf holds one kind. Both tracers
intersect from the closest approach (`k = oc.d / d.d`, `l = oc - k d`,
`h = r^2 - l.l`) rather than `b^2 - ac`, which loses most of its digits
for a 5 cm ball 10 m away and made the CPU and GPU disagree; emissive
balls are lights sampled by the cone they fill.
Scenes the shader does not cover stay on the CPU: a graph with another
node type (Voronoi, bricks, wave, functions ...) or an HDR image in it.

On an RTX 4080 SUPER, 128 samples of that scene at 1920 x 1080 take 0.9 s,
including the scene upload and readback. The CPU path takes 9.8 s on 32
threads.

### RTX: ray queries (v0.23)

When the device has Vulkan 1.2 with `VK_KHR_acceleration_structure` and
`VK_KHR_ray_query`, the helper says so in its hello. Renders and Rendered
shading (Device Auto or GPU (RTX)) then use `ptr` / `ptgr`: `pt.comp` built
with `RTX`, whose `trace()` walks acceleration structures with a ray query
instead of the BVH4.

- **The structures:** each run whose triangles or balls changed (or whose
  counts did) rebuilds them on the GPU before the dispatch. `asprep.comp`
  turns the uploaded triangles (a corner and two edges) into three
  positions each, and the balls into boxes, in two more bindings of the
  slot that only the device uses. One bottom-level structure holds the
  triangles and one the balls, under a top level of two instances. The
  balls' structure is rebuilt alone when only they moved, and passes after
  a render's first reuse what is there.
- **The same hits:** every triangle is non-opaque, so each candidate the
  hardware finds comes back to the shader. `tri_hit` and `sph_hit` decide
  it with the arithmetic of the BVH path, and catchers are let through as
  before. The images match the compute path's: the test sees 100% of
  pixels identical, or within 0.0001 levels.
- **No BVH on the CPU:** for a render that will trace with RTX, Hive skips
  its BVH. Only objects the cache is about to keep get theirs, so the
  cache stays whole for CPU renders. The rest keep their order, and there
  is no top level. If the CPU has to take over (a material the GPU lacks,
  the helper failing), the scene is built again with its BVH first. The
  triangles' order then differs from the CPU's on the first render, and so
  does which emissive triangle a light sample picks. The noise differs;
  the image does not.

A rainstorm frame (960 x 540, 16 samples, an animation's third frame)
takes 96 ms from frame to PNG: the scene build 12 ms (20 with the BVH),
the GPU 60 ms. The compute path takes 165 ms (its GPU 120 ms), and 240 ms
before v0.23's scene stayed on the GPU.

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

### The viewport drawn by the GPU (v0.24)

With a graphics queue, the helper also draws the 3D viewport's objects in
Solid and Material Preview: a render pass of four images (colour, 1/z,
object ids, depth), one pipeline (`src/gpu/view.vert`, `view.frag`) and one
indirect draw call for the whole scene (`src/gview.s`; slot 3). Each mesh's
triangles stay on the GPU in object space (corners, corner normals smooth
within 30 degrees, UVs, vertex colours) and are written again only when the
mesh changes: its version, counts or a fingerprint of its vertices. A frame
sends the camera, a record per object (its matrix and normal matrix,
colour, material, id) and the materials; a moving object costs 128 bytes.

Instances and particles are drawn in the same pass (VP2). A mesh's
instances (`ME_INST`: geometry nodes, rigid bodies) and particles drawn as
objects are instanced draws: an entry each (its matrix, its draw's record)
in a buffer sorted by prototype, one indirect draw a prototype, the
prototypes' triangles kept like any mesh. Points and sprites are quads the
vertex stage makes from a record a particle (`pt_vfill`: its place, its
colour through its ramp, its sprite radius), as `pt_draw` draws them: a
square of `point_px` pixels, or a disc shaded like a ball. Particles leave
the object ids alone (the helper's second pipeline), as on the CPU, so the
outline and clicks stay the objects'. Instances are drawn from both sides
with their vertex colours, as renders show them (the CPU's viewport culled
back faces and drew far ones as dots).

The vertex stage projects as the CPU's rasterizer does, with depth near / z,
so 1/z comes back exactly as raster.s keeps it. Solid shading is the CPU's
flat headlight, pixel for pixel; Material Preview is preview.s's principled
BSDF under the studio environment or an HDRI world (its SH irradiance and
blurred copy), with the materials' shader graphs evaluated by the path
tracer's graph code (`src/gpu/graph.glsl`, shared with `pt.comp`). The
colour comes back into the window's buffer where an object is, 1/z and the
ids into the CPU's depth and id buffers, so particles, instances, wires,
the selection outline and clicks work on top as before.

The helper imports the shared memory as its staging buffer when the device
can (`VK_EXT_external_memory_host`): uploads and readbacks go between the
GPU and BeeModel's own memory with no copies on either side.

A liquid's surface is not meshed for the viewport when the GPU draws it
(VP3): raster_scene leaves the object without triangles and the helper's
third pipeline draws its field's box, whose fragment shader marches the
ray from the eye through the field (as the path tracer's `fld_hit`: a cell
a step, 8^3 bricks all on one side skipped, the crossing halved, then
interpolated) and writes the surface's depth, 1/z and the object's id;
its normal is the field's gradient. When the GPU does not draw the frame
after all, raster_scene starts again with the surfaces meshed.

The CPU draws the viewport instead without a helper (or with Device CPU),
in edit and paint modes, with virtualized geometry, with light probes in
Material Preview, a shader graph the GPU cannot evaluate, or more than
4M triangles; instances and particles over 4M (then those alone, after).
At 2560 x 1440 in Material Preview a frame of the rainstorm (94k drops)
draws in 4-7 ms instead of 46 ms, leaf-twister (18k leaves) in 4-6 ms
instead of 23 ms.

**Playback** (`tools/playbench.py`: each demo played through its camera
in the fake compositor at 2560 x 1440 for four seconds; window frames a
second and a frame's median milliseconds, Ryzen 9 7950X with an RTX 4080
SUPER, v0.23.0 -> v0.24.0):

| demo | Solid | Material Preview | Rendered |
|---|---|---|---|
| dam break | 4 -> 130 fps (4 ms) | 3 -> 135 fps (4 ms) | 4 -> 71 fps |
| rainstorm | 80 -> 185 fps (13 -> 4 ms) | 23 -> 181 fps (46 -> 4 ms) | 20 -> 27 fps (59 -> 13 ms) |
| leaf-twister | 77 -> 131 fps (11 -> 4 ms) | 45 -> 144 fps (23 -> 4 ms) | 45 -> 76 fps (29 -> 17 ms) |
| fireworks | 218 -> 218 fps (4 -> 3 ms) | 75 -> 214 fps (13 -> 3 ms) | 130 -> 169 fps (4 ms) |
| wrecking ball | 202 -> 174 fps (4 -> 6 ms) | 58 -> 172 fps (18 -> 6 ms) | 88 -> 133 fps (6 ms) |

Every demo plays its frames in real time now. A light scene in Solid pays
the helper's round trip (the wrecking ball, 2 ms). The rainstorm in
Rendered is held by its 525k still triangles, copied and compared at each
scene build (19 ms); the build could keep them in place.

### Liquids solved on the GPU (v0.24)

A liquid's substeps run in the helper's compute kernel `src/gpu/liq.comp`
(slot 4), a port of `liquid.s`'s solver phase by phase: predict, the hash
grid (counted, summed, sorted), neighbours, the density constraint's
iterations with the domain and bodies, the colliders' triangles (their BVH
uploaded), velocities, XSPH viscosity and vorticity. The particles go up
and their places, velocities, densities, neighbour counts and the impulses
on rigid bodies come back each frame. Force fields and landscapes as
colliders keep the CPU's solver, as does `BEEMODEL_GPU_LIQUID=off` and a
helper that fails (from then on). The GPU's sums run in another order, so
its liquid matches the CPU's closely at first and then diverges as any
change to a liquid does.

The dam break (200k particles) solves a frame in 6 ms on an RTX 4080 SUPER
instead of 67 ms. With its surface drawn by the viewport's march (nothing
on the CPU meshes it: the DAG scan, the instance scan and the wires skip
it), it plays in real time at 2560 x 1440 in Solid and Material Preview:
16 ms a frame that steps the simulation, 4 ms one that only redraws (2 fps
before v0.24).

### Rendered shading (the live viewport)

**Rendered** is the fourth viewport shading, next to Wireframe, Solid and
Material Preview: in the viewport header, the Z pie, **View › Rendered**
and Properties › Viewport (`view.shading_rendered`). It draws the view on
the GPU, from the scene Hive snapshots (`src/live.s`):

- **While the view or the scene changes**, one raycast a frame:
  - the sun and each point light, with hard shadows, through the same
    BSDF as the path tracer;
  - the studio sky through six occlusion rays, which look 2 m away; a
    surface they hit adds a rough first bounce (its colour, lit by half the
    sky and the unshadowed sun);
  - mirrors (metal under roughness 0.3) and glass followed, four deep;
    other surfaces reflect the sky.
- **Once the view is still**, Hive's path-traced samples accumulate on the
  GPU, a 12 ms slice a frame, up to **Preferences › Viewport › Rendered
  samples** (64; `view.rendered_samples <n>`). The raycast stays shown for
  the first 4. With 0 samples the raycast is all there is, and no frames
  are drawn while nothing changes.
- **Denoised** on the GPU every frame, unless **Preferences › Viewport ›
  Rendered denoise** is off (`view.rendered_denoise [0|1]`). It is the F12
  render's filter (`denoise.s`), ported to `pt.comp`'s `dn_` stages:
  - the samples also sum the first hit's albedo, normal and depth, and the
    luminance moments;
  - the radiance is divided by the albedo;
  - the variance is blurred 3 × 3;
  - five edge-avoiding à-trous passes (steps 1 to 16) weigh each tap by
    normals, depth and luminance;
  - the albedo is multiplied back in.

  That is six more dispatches after the frame's samples; only the last one
  reads pixels back. In the test scene, 4 denoised samples are 1.3 levels
  from a 512-sample image on average; 4 plain ones are 6.6. It takes 2 to
  7 ms on an RTX 4080 SUPER at 800 x 540. Turning it on or off starts the
  samples again (its sums ride along with them).

The selection outline, the gizmos, edit-mode edges and the other overlays
are drawn over the image, and clicks still pick through the rasterizer.

**How it runs.** The raycast is a mode of `pt.comp` (its `cam[14]` flags):
it walks `trace_path`'s own loop, and its shadow and occlusion rays go
through the path's one shadow-ray call. So the shader keeps one inlined
copy of the BVH walk and of the graph evaluator (`pt` grew from 97 to
112 KB of SPIR-V, `ptg` from 292 to 306 KB). The scene goes to slot 2 once:
after that, each frame sends only the constants (the camera) and reads
back the pixels as XRGB, 4 bytes each. The accumulators stay on the GPU,
and the shader applies ACES and the sRGB curve as the CPU's resolve does.

**When the scene goes up again.** A fingerprint is taken every frame:

- each object's place, flags (not its selection), material and modifiers;
- its evaluated mesh, with the mesh's version and size (a liquid's
  surface instead by its particles' state, without meshing it);
- each light's colour and power;
- the material records;
- the undo and redo depths;
- the edited mesh's positions (a drag in edit mode).

A camera move changes none of these. When the fingerprint changes:

- a scene that builds in under 30 ms is built again for every change (at
  most half the time);
- a slower one waits until the change is over (the fingerprint is the same
  two frames running); meanwhile the camera stays live on the last
  snapshot.
- samples begin 150 ms after the last build. Playback changes the scene
  every other frame, so it shows a raycast every frame rather than
  raycasts and samples in turn, which flickered.

A build's time leaves out a slot's memory being made or grown (a first
build's 80 ms in the dam break would otherwise keep it waiting for good).
The scene is built as a render's is (v0.24): with RTX, no BVH on the CPU,
and a liquid's surface as its field, not meshed. During playback at
2560 x 1440, a frame takes (v0.23.0 -> v0.24.0): dam break 71 -> 5 ms,
leaf-twister 25 -> 5 ms, rainstorm 52 -> 38 ms (its 525k still triangles
are copied and compared each build).

**Beside an F12 render.** The render owns Hive's scene, so the live view
keeps its snapshot. When F12 opens the Render area and narrows the viewport,
the live view sends the render's own snapshot at the new size. It builds
anew once the render is done. The Render area's image, passes and denoising
are untouched (they live in slot 0).

**More than one viewport.** One viewport has the live view: the one last
used. The others show Material Preview, and their status line says "live
in another viewport".

**Falling back.** Without the helper, or when it fails, Rendered shows
Material Preview, and the console says why once. The status line under
the viewport's label always says what is shown: `raycast`,
`n / N samples`, or the fallback. Materials whose graphs `pt.comp` does
not evaluate are drawn with their plain values. An HDRI world is drawn
as it is (v0.23).

On an RTX 4080 SUPER, at an 800 x 540 viewport, a raycast takes 2 to 3 ms,
including the readback. That holds for the 1,600-triangle test scene and
for one million triangles. 1024 samples of the small scene take 1.5 s
(3.3 s with the million triangles). Building the million-triangle scene
takes 0.55 s; the small one, 4 ms.

### Animations (v0.23)

`render_frames(folder, first, last, ...)` and `render.animation <folder>
[first last]` render a range of frames into `folder/0001.png` and so on
(`hive_render_frames`). On the GPU the frames overlap. The last batch of
a frame is sent (`gpu_pt_send`) without waiting for it. While the GPU
traces it, the CPU writes the PNG of the frame before, moves the scene to
the next frame (animation, simulations) and builds it (`hive_scene`). Then
it takes the batch's reply (`gpu_pt_wait`), resolves the image and puts
the next frame's scene up. Slot 0 is not written while a batch is in
flight: anything else that talks to the helper reads the reply first
(`g_drain`).

The images are the ones `frame()` and `render()` make frame by frame,
pixel for pixel. The rainstorm demo at 960 x 540 and 16 samples takes
78 ms a frame instead of 109 ms. If the helper dies during the overlap,
the scene goes back to that frame and the CPU renders it again.

### Sample reuse between frames (v0.23)

`render.sample_reuse <frames>` (Properties › Render › Sample reuse, saved
with the scene) makes animation renders (`render_frames`,
`render.animation`) reuse samples. The first frame traces all its samples.
Each later one traces samples / (frames + 1) new ones, then merges in the
frame before's (`rf_reuse`, on the CPU, whichever device traced, so the
same for the CPU, the GPU and RTX). For each pixel:

- Its primary hit (the depth pass along its centre) is carried through this
  frame's camera into the last one's. The four pixels round where it lands
  count, bilinearly, each only if it saw the same place (within 2% of the
  distance), the same way (normals within 37°) and the same albedo (within
  0.08), or both saw no hit.
- What they hold counts only if its brightness lies within this frame's
  own 3x3 round the pixel: the mean ± (2σ + 5%). Lights and shadows that
  moved are not reused.
- The history then counts as up to (samples − new) samples, so a pixel
  never claims more than the target. The sums are rewritten as
  target-sample sums, and the second moments so that the denoiser sees
  each pixel's variance from its own count.

Moving objects, and what comes into view, keep their own samples alone:
the reprojection follows the camera, not objects. A film with alpha (shadow
catchers) is never reused. A still scene seen by a panning camera at 16
samples and 3 frames (4 new samples a frame) comes out at 1.25 levels from
the 256-sample frames where 16 samples a frame are 1.47 and 4 are 3.04.
12 frames at 960 x 540 and 64 samples take 2.7 s on the CPU instead of
7.9 s.

### Liquid surfaces (v0.23)

A render headed for the GPU (`gpu_fld_likely`) builds a liquid's surface
as its field, not its mesh (`hv_fld_add`): its grid's values, and each 8³
brick's smallest and largest value. They go up after the balls in binding
19: a count, a 32-float record per field (origin, spacing, size, material,
the grid's corners, where its values and bricks start, the emitter's
inverse matrix for graphs), then the values and the bricks. `trace` tests
the fields after the triangles and balls (`fld_hit`): a ray marches the
grid a cell a step from its box, past bricks all on its side of the
surface, then halves the step that crosses 0 six times and interpolates.
The normal is the field's gradient. A field is opaque to `cover`, is
never sampled as a light, and has no vertex colours.

The CPU never sees a field: if a render goes to the CPU after all (the
helper fails, or a node it lacks), the scene is built again with the
surface meshed (`hv_need_bvh`, as for RTX). In the dam-break demo a frame
(`render_frames`, 960 x 540, 16 samples) takes 109 ms instead of 157 ms.

### Falling back

- **Missing or unusable:** no helper, no device, a scene `pt.comp` does not
  cover, or `BEEMODEL_GPU=off` all mean the CPU paths.
- **Failure mid-render:** if the helper fails or dies mid-way (a run times
  out, the socket closes), BeeModel stops it for the session and goes on
  on the CPU from where it was. The accumulators hold every finished
  sample, and the CPU continues the same random streams, so the image is
  still the one the CPU alone would make.

## Benchmark

`tools/renderbench.py` path-traces the four particle demos at 960 x 540, 16
samples: a render after simulating to the frame, the same again, ten frames
with `render_frames`, and ten with 64 samples and sample reuse 3 (16 new a
frame). On a Ryzen 9 7950X with an RTX 4080 SUPER, in milliseconds (v0.22.1
ran three of them on the CPU):

| Scene (frame) | v0.22.1 again | v0.23.0 again | v0.23.0 a frame | 64 samples, reuse 3 |
|---|---|---|---|---|
| rainstorm (120) | 1377 | 103 (RTX) | 74 | 102 |
| dam-break (60) | 1201 (CPU) | 63 (RTX) | 108 | 212 |
| leaf-twister (120) | 313 (CPU) | 27 (RTX) | 23 | 51 |
| fireworks (90) | 122 (CPU) | 24 (RTX) | 28 | 25 |

A frame of `render_frames` includes simulating it; the dam break's liquid
solver is most of its 108 ms. The first render of a run also starts the
helper; in the benchmark's throwaway HOME the driver's shader cache is
empty, so that takes 0.6 to 3 s (the graphs' kernels are the slow ones).

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
| 7 | Rendered shading: raycasts drawn |
| 8 | Rendered shading: samples in the image (0: the raycast) |
| 9 | Rendered shading: scene uploads |
| 10 | Rendered shading's last frame: 1 the GPU's, 2 another viewport has it, 0 Material Preview |
| 11 | The last raycast's milliseconds, with its readback |
| 12 | The last scene build's milliseconds |
| 13 | 1 when the image shown is denoised |
| 14 | The last denoise's milliseconds |
| 15 | The last scene build's milliseconds (Hive: triangles, materials, BVH) |
| 16 | Of which the BVH's |
| 17 | The last scene's triangles |
| 18 | Where the last render ran, and why: 0 the GPU; on the CPU: 1 Device is CPU, 2 no helper or device, 3 an HDRI world, 4 a shadow catcher, 5 a material node the GPU lacks, 6 the helper failed, 7 a bake |
| 19 | The last scene's spheres (particles drawn as balls) |
| 20 | Objects the last scene build took from the cache (their BVH and triangles kept) |
| 21 | KiB the last render's scene sent to the GPU (what changed; the pixels' buffers aside) |
| 22 | The same for Rendered shading's last scene |
| 23 | 1 if the last render traced with RTX (ray queries) |
| 24 | 1 if the helper has RTX |
| 25 | Liquid surfaces the last render traced as fields |
| 26 | `render.sample_reuse`: frames whose samples animation renders reuse (0: off) |
| 27 | Viewport frames the GPU drew (v0.24) |
| 28 | The last one's milliseconds |
| 29 | KiB of meshes it sent |
| 30 | 1 if the GPU's viewport is off (a failure; 2: `BEEMODEL_GPU_VIEW=off`) |
| 31 | 1 if the helper imports the shared memory (no copies) |
| 32 | 1 if the last viewport pass drew the instances and particles on the GPU too |
| 33 | Liquid frames the GPU solved |
| 34 | 1 if solving a liquid on the GPU failed (the CPU's solver since) |
| 35 | Liquids' surfaces the last viewport pass marched on the GPU |

[tests/gpu.py](../tests/gpu.py) checks:

- the fallbacks;
- the path tracer against the CPU, including the denoised render;
- the helper dying at its second run (`BEEMODEL_GPU_FAIL=2`, a test hook);
- the rasterizer's frame in the fake compositor;
- the viewport drawn by the GPU: Solid, Material Preview (shader graphs,
  textures, bump and normal maps, vertex colours) and an HDRI world against
  the CPU's image; points, sprites and particle objects against the CPU's;
  a liquid's surface marched from its field against the CPU's mesh;
  edit mode on the CPU; a click picking through its ids;
- Rendered shading: the raycast, then the samples; a camera move against a
  scene change; the selection outline; 0 samples; the denoiser against
  plain samples; an F12 render beside it;
  Material Preview without the helper, or when it dies.

CI runs it on llvmpipe.
