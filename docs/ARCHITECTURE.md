# BeeModel architecture

This document describes how the code is organized today. The long-term
direction is in [`Vibecoding/BeeModel-Masterplan.html`](../Vibecoding/BeeModel-Masterplan.html).

## Modules

Every `src/*.s` file is a separate translation unit, assembled into its own
object and linked statically by `ld`. A module exports what other modules use
with `.globl`, listed under `# exports` at the top of the file. Everything else
stays private to the module.

| Module | Responsibility |
|--------|----------------|
| `main.s` | `_start`, command-line flags, the event loop |
| `wayland.s` | Socket, message encoding/decoding, `SCM_RIGHTS`, shm buffers, event dispatch, frame pacing, drawing times and the input work before each frame (`frametime`), tablets (`zwp_tablet_v2` tools: pen motion and buttons as pointer input, pressure, eraser end) |
| `draw.s` | Framebuffer primitives: rects, gradients, text, lines, clip rectangle |
| `ui.s` | Layout, hit testing, pointer/keyboard handling, title bar, menus, panes, status bar |
| `ops.s` | The operator spine: application operators, `run_op`, key dispatch, shortcut text, `--list-ops` |
| `viewport.s` | Camera, projection, clipping, grid/axes/gizmo, plus the viewport's own operators |
| `keyboard.s` | XKB text-keymap parser, key → Unicode (Shift/Caps/AltGr levels, dead keys), layout-aware shortcut codes, key repeat (timerfd) |
| `textfield.s` | Single-line UTF-8 text field: caret, selection, history, Tab completion; the console command line |
| `ttf.s` | TrueType engine: cmap 4/12, loca/glyf (simple + composite), hmtx, anti-aliased rasterizer, glyph cache |
| `text.s` | Font selection, UTF-8 text drawing (alpha blended), text measurement, bitmap fallback |
| `jobs.s` | Worker threads (raw `clone`), futex sleep/wake, `parallel_for` |
| `mem.s` | Bump arenas (frame / per-thread scratch) and pools with generational handles |
| `selftest.s` | `--selftest`: allocator and job-system tests plus a benchmark (run in CI) |
| `areas.s` | Area tree (splits + leaf areas), layout, hit testing, headers, the five editors, area operators |
| `palette.s` | F3 command palette: fuzzy search over the operator table |
| `scene.s` | Objects (pool + ordered list), unique names, selection, TRS matrices, object operators |
| `mesh.s` | Polygon meshes (loops, n-gons), edge/triangle derivation, primitive generators; optional per-loop UVs and seam flags in their own mappings (copied with the mesh, freed with it) |
| `raster.s` | Viewport rasterizer: parallel setup, binning and tiles; depth, ID and visibility (triangle) buffers; selection outline; picking |
| `transform.s` | Modal grab / rotate / scale, constraints, snapping, numeric input, gizmos |
| `undo.s` | Undo / redo history of scene snapshots (shared, reference-counted meshes) |
| `fileio.s` | Paths (`~`, default dirs, mkdir -p), mmap reads, atomic writes, growable buffer, number text I/O |
| `edit.s` | Edit mode: per-vertex selection stored in the mesh; copy-on-write geometry, so undo snapshots keep old meshes; depth-tested overlays and picking; edge loops; linked; box select; component transforms |
| `meshops.s` | Mesh operators: extrude, inset, delete, merge, dissolve, fill, subdivide, duplicate, normals. Each builds a new mesh, so undo keeps the old one; modal ones use the transform value mode |
| `meshops2.s` | Loop cut (ring walk), knife and bisect (one plane-cut core), bridge, spin, bevel (offset corner points, arcs, corner patches), the 3D cursor, and the interactive edit tools the UI routes input to |
| `redo.s` | Redo panel: operators declare parameters (`OPERATOR … params=`) and report the values used; the panel and `edit.redo_last` restore the top undo snapshot and run the operator again without a new step |
| `mods.s` | Modifier stacks: reference-counted, copy-on-write blocks shared with undo; an evaluation cache per object keyed weakly on mesh and stack versions (freeing a mesh notifies the caches); Mirror, Array, Solidify; the properties UI; save / load |
| `mods2.s` | Bevel (by angle), Decimate (vertex clustering), Remesh (ray-parity voxels, surface nets, smoothing) |
| `hive.s` | The Hive path tracer's scene: a world-space triangle soup with auto-smoothed corner normals and material snapshots, a binned-SAH BVH collapsed to 4-wide nodes, SSE ray traversal (nearest and any hit) |
| `inflate.s` | Inflate (RFC 1951) and the zlib wrapper: 10-bit Huffman lookup with a canonical slow path |
| `imgread.s` | Images in memory (header + pixels), the PNG reader (all colour types, depths, filters, Adam7, tRNS) and the Radiance HDR reader |
| `jpeg.s` | Baseline JPEG: Huffman, SSE float IDCT, bilinear chroma upsampling, YCbCr |
| `exr.s` | OpenEXR writer: half-float scanlines, ZIP blocks through png.s's deflate |
| `image.s` | The scene's images: load, name, save, `image.*` operators |
| `expr.s` | Expressions with units (recursive descent, doubles): lengths to scene units, angles to radians, functions, parameter names |
| `cad.s` | The CAD document (copy-on-write, shared with undo): scene units, parameters with cached evaluation and cycle detection, `param.*` / `scene.units` operators, the CADD chunk |
| `sketch.s` | Sketch blocks (points, lines, circles, arcs, constraints), the residual equations, the Levenberg-Marquardt solver per component, rank / null-space DOF analysis, deletion with compaction |
| `sketchobj.s` | Sketch objects: creation, display meshes, status-coloured drawing, `cad_rebuild`, the SKCH chunk |
| `prof.s` | Profiles from sketches: closed loops (welded ends, arcs and circles tessellated, even-odd nesting), ear clipping with hole bridging, prisms, revolutions, offsets, hole circles; meshes oriented by signed volume |
| `feature.s` | The feature tree (records in the CAD document): pad, pocket, revolve, hole, shell, fillet, chamfer, linear / circular patterns, replayed in order with `mesh_boolean` and `build_bevel` into each body |
| `measure.s` | Mass properties (area, signed-tetrahedron volume, centre of mass, mass from material density) in world space, `object.measure`, the measure tool (vertex-snapped clicks: distance, angle) |
| `sdf.s` | Signed-distance shapes: node graph (primitives, lattices, smooth booleans, shells, transforms, extruded profiles), parallel sampling, marching tetrahedra (six per cube, orientation from tetrahedron parity: always manifold) |
| `fab.s` | 3MF export (a zip written by hand: stored and deflated parts, CRC-32, central directory; millimetres, Z up), DXF and SVG of sketches |
| `drawing.s` | Drawings to PDF: three third-angle views, per-view depth buffers for hidden lines, sharp / boundary / silhouette edges, dimensions, title block, a hand-written PDF with an exact xref |
| `sculpt.s` | Sculpt mode: a BVH of ~1024-triangle leaves (vertex lists with owned vertices first), parallel brush dabs over the leaves in reach (atomic float sums, per-leaf slots for the undo deltas), normals refreshed once a frame in the dirty sphere, tile-parallel drawing (splats with a stride for dense leaves, triangles for near ones) from per-leaf splat records kept while the view stays; during a stroke the leaves keep their splat strides and a tile cache (the viewport's colour and depth after the last frame) supplies every tile no changed leaf covers, old rectangle or new), ray picking nearest leaf first, mask and X symmetry |
| `dyntopo.s` | Dynamic topology for sculpt mode: a growable working copy of the triangles; per dab region an edge hash of the leaves around, longest-edge bisection over the detail size, edge collapse under 0.4 of it (link condition, valence, no flips or slivers), then only the touched leaves' triangle / vertex lists (moved within the pools when they outgrow their room), vertex ownership, boxes; at stroke end the copy becomes the object's mesh |
| `multires.s` | Multiresolution: per-level displacements on the object (`OB_MRES`, a reference-counted block shared with undo like meshes, with the base topology's fingerprint) added by subsurf after each level; sculpting level k on a copy whose stroke moves land in D_k; propagate down (subsurf in fit mode: each level the finest's vertices); the MRES chunk |
| `uv.s` | UV maps: loop topology (next, twin through a directed-edge hash), islands and UV vertices by union-find across non-seam edges, LSCM per island (each triangle in its own plane, two pinned vertices, matrix-free Jacobi-preconditioned conjugate gradients in doubles), smart projection (flood fill within 66 degrees of a seed's normal), packing (texel density, smallest box over 2-degree turns, skyline), seams, measures (angle / area distortion, flips, overlap on a grid) |
| `uved.s` | The UV editor area: the layout over the unit square (view pan / zoom), island picking by point-in-UV-triangle, island transforms from a saved copy of the UVs (confirm / cancel, one undo step), per-triangle heat maps (area share ratio on a log scale, worst corner angle error) filled in physical pixels, texel density; keys flagged `OPF_UV` win over a UV editor |
| `nodeed.s` | The node editor area: the active object's geometry node tree (first Geometry Nodes modifier; Tab: its material) or its material's graph, laid out (stored positions, else columns by depth), boxes with output / value / input rows, sockets coloured by kind, Bezier wires (links carry the output index), hit testing, drags (move, wire from an output / input / material socket, value, pan) applied through the `material.*` / `tree.*` operators or, for live drags, with one undo step pushed at the first motion; the Shift+A menu; Shift-click selection, Ctrl+G (`tree.group`), Tab into / out of groups |
| `ntree.s` | Node trees: a reference-counted block of 4 KiB records (48 nodes in the shader graph layout, links = node + output << 16) shared with undo steps and copied on change; nodes, links (loops refused by a reachability check; numbers never change), values, places; the NTRE chunk; `nt_ver` for modifier caches |
| `geonodes.s` | Geometry nodes (distribute points on faces: per-triangle counts from area x density, parallel placement by hash, a grid-hash thinning, point normals in `ME_PNRM`; instance on points: parallel matrices aligned / turned / scaled): type metadata, `tree.*` operators, evaluation pulled from the Group Output with one mesh per node (primitives, transform, join, set position, extrude, subdivide, boolean, merge; groups: the outer level's state saved, 8 levels, fields compiled across the boundary with per-level memos), `gn_make_group` (a selection into a new tree, outside links through the group input), the field compiler (position / normal / index / value / combine / separate / math / vector math / noise / random into VM registers; vectors as three) |
| `fieldvm.s` | The field VM: 24-byte instructions over 64 scalar registers, run 256 elements at a time (one SSE loop per instruction; pow / mod / sin / cos / noise / random per element), blocks in parallel, results written to the caller's arrays |
| `fvjit.s` | The field JIT: a program run over >= 1024 elements is compiled (cached by an FNV hash of its instructions, outputs and mode) from templates assembled in the same file (AVX 8 lanes, SSE 4) with placeholder displacements / immediates / addresses patched on copy; one loop over a whole 256-element block, each instruction emitted for 8 groups side by side so chains of dependent instructions overlap, registers in the thread's frame (`r * stride + group * size`), inputs and outputs straight to their arrays, pow / mod / sin / cos / noise / random through `fv_scalar1` (the interpreter's own); fresh RW pages made RX after writing (never both); partial blocks stay interpreted; the self-test compares random programs bit for bit (VM, SSE, AVX) |
| `copilot.s` | The procedural co-pilot: the geometry node catalogue (`gn_meta` / `gn_defaults` as JSON), trees as JSON (links as node + output, constants, values, places), the proposal (an undo group held open across MCP requests: accept closes it, revert closes it and undoes the step), the viewport banner with Accept / Revert (Enter / Esc, clicks), MCP prompts (`procedural`); `mcp.s` routes its tools, the `bee://graphs` resource and `prompts/*` here |
| `anim.s` | Animation: one reference-counted block (shared with undo steps as `ST_ANIM`, copied on change; the ANIM chunk) of up to 1024 curves - a channel (object uid / material / modifier / node tree, and what in it) and a run of 32-byte keys (frame, value, handles, interpolation) kept sorted; auto-clamped handles; evaluation by span search and, for Bezier spans, Newton on x(t); applying a frame writes every curve's value through the same setters scripts use (`mat_set`, `mod_param_set`, `nt_set`, object fields); playback by the clock from `ui_draw` (`an_tick`), the frame kept dirty while playing; the Timeline area (ruler, ticks, keys, scrubbing); `anim.*` operators |
| `asset.s` | Assets: `.beea` files in `~/BeeModel/assets` (a tree with the groups it runs, group numbers made file-relative; or a material record), loading with new names and renumbered groups, the folder listed with `getdents64`, the Asset Browser area |
| `inst.s` | Instances: a reference-counted block on a mesh (`ME_INST`: up to 8 prototype meshes, a 3x4 matrix and a prototype id per instance), merge / transform / realize; the viewport pass `inst_draw` (per instance: camera transform and projected sphere -> a depth-tested square under ~3 px, else the prototype's front faces from a per-instance vertex cache with stepped edge functions; instances binned into 16-px tiles, tiles drawn in parallel) |
| `curve.s` | Curves: a reference-counted block on a mesh (`ME_CURVE`: 32 splines, 48-byte control points with handles, radius, tilt, handle type, selection), copied when shared (`cv_edit`) and the mesh made again (`cv_rebuild`, and the curves using it as a profile); auto / vector handles, Bezier sampling per span; chains (evaluated splines, or a mesh's consecutive 2-point polygons) and the sweep (parallel-transported frames with the closing twist spread and tilt, rings of a profile scaled by the radius, quads, caps); resample / trim / fillet on chains for the curve nodes; `curve.*` operators; curve edit mode (`cve_*`: overlay, picking, Ctrl+click extrusion to the view plane, the transform hooks `edit_tm_*` forward to); the CURV chunk writes the block as it is |
| `procgen.s` | Procedural generators: the terrain node (rows of fBm / ridged Perlin octaves in parallel on a grid), terrace, droplet erosion (heights normalized, bilinear height / gradient, inertia, capacity from slope x speed x water, deposit bilinear, erosion through a radius-2.5 brush clamped at the original floor); L-systems (a replacement table per character, rewriting with a length bound, a 3D turtle with a branch stack writing curve.s chains, swept as hexagonal tubes or lines); wave function collapse (options = tile x distinct quarter turns, at most 64 as a bitmask per cell, face signatures as sums of splitmix hashes of quantized face points, a compatibility mask per option and side, lowest-count cell with random ties, stack propagation, restarts) |
| `paint.s` | Texture painting: the target (first image node of the material), projected dabs (triangles meeting the brush on screen, their UV-space texels with a 1.5-texel bleed, barycentric camera points depth-tested against the viewport), UV-space dabs from the UV editor, world-space dabs for scripts, a stroke history of changed rectangles (images are not in scene undo) |
| `layers.s` | Paint layers on an 8-bit image (`IM_LAYERS`): base + up to 15 layers with alpha, opacity, blend mode, visibility; the image holds the composite (per texel as painted, per rectangle on undo / changes); ILAY chunk with an RGBA PNG per layer (`png_encode_rgba`) |
| `vcol.s` | Vertex colours (`ME_VCOL`, one per vertex, own mapping): tinting (per-triangle average in the solid rasterizer, barycentric linear colour in the preview and the path tracer's per-triangle table), vertex paint dabs (projected, depth-tested; an undo step per stroke, mesh copied on write), the MVCL chunk; OBJ colours and glTF `COLOR_0` |
| `bake.s` | Baking high to low: the hive BVH built over the high object alone (`hv_only`), the low mesh's world corner normals (hive's `corner_normals` on a temporary `hv_tv`); per low triangle x 16 row bands in parallel, texels by UV barycentrics, a ray from the cage along -N; normal (high smooth normal in the UV tangent frame), AO (48 cosine rays, `hv_occluded`), curvature (8 probes: smooth-normal turn along the probe direction, falling off = convex); dilation 8 rings; one texture-paint history step (`pt_record`) |
| `print.s` | Printability: wall thickness per face (rays inward through a triangle grid, cached), the thin-wall overlay classes, `mesh.print_check` |
| `sketchui.s` | Sketch mode: tools, snapping and inference, picking, point dragging, constraint keys, dimensions, the overlay |
| `gltf.s` | glTF 2.0: export (.glb chunks or .gltf with base64), import (node tree baked, welded, PBR + KHR extensions, data: / external / GLB buffers) on the lazy JSON reader |
| `mtl.s` | MTL import for OBJ: principled values from Kd Ke Ni d Tr Ns Tf Pr Pm Pc Pcr, map_Kd as a texture graph |
| `graph.s` | Shader graphs: node storage in the material record, evaluation (Perlin fBm noise, checker, gradient, mix, ramp, math, images), sockets, Blinn bump, tangent-space normal maps, stable topological sorting (links in any direction, loops refused), node deletion with renumbering, node positions (`ND_POS`, `GR_OUTPOS`) (frame from the triangle's UVs; texels back to bytes with `tx_unlin`), editing and the `material.node*` operators |
| `texture.s` | Image lookups (bilinear, repeating, sRGB table) and object-space box projection |
| `env.s` | The world: HDRI lookups, a 2D CDF for importance sampling, SH9 irradiance and a blurred copy for the preview, `world.*` operators |
| `denoise.s` | Hive's denoiser: demodulation by albedo, variance from luminance moments, five edge-avoiding à-trous passes guided by normal, depth and luminance, in parallel rows |
| `render.s` | The Render window: `render.start / stop / pass / save / settings`, the time-sliced `render_tick` the main loop calls, and the Render editor (the chosen pass fit to the area, with a status line) |
| `hive_pt.s` | Hive's light transport: path tracing with next-event estimation and MIS over sky, sun, point and emissive-triangle lights; the principled BSDF (Lambert, GGX, rough dielectric, clearcoat); parallel progressive passes with albedo, normal and depth AOVs, ACES resolve, `render.image` |
| `preview.s` | Material preview: shades the rasterizer's visibility buffer per pixel (ray / triangle barycentrics, auto-smoothed corner normals, principled BSDF, studio environment, ACES) |
| `material.s` | Principled materials: a reference-counted, copy-on-write block shared with undo steps, per-object assignment (`OB_MAT`), the MATS / OMAT chunks, MTL values, the Properties section and the `material.*` operators |
| `repair.s` | Mesh analysis (edges by face count and direction, faces by area and overhang, loose vertices), the View › Show … overlays, and `mesh.repair`: merge by distance (spatial hash), degenerate and duplicate faces, hole filling from boundary loops, consistent outward normals (flood fill plus signed volume per part) |
| `bool.s` | Mesh booleans: snapping to a dyadic grid, exact 128-bit orient3d with a symbolic perturbation of the second mesh (along its normals, plus a per-vertex tie breaker), grid-accelerated triangle pairs, welding, per-triangle constrained triangulation, region flooding and exact ray-parity classification (rays walk a per-mesh grid of triangles); the `object.boolean` operators, the Boolean modifier's evaluation and `manifold` |
| `subsurf.s` | Catmull–Clark on corner arrays: level 0 is hashed once, deeper levels are derived arithmetically, every pass runs in parallel; topology is cached so edits only recompute positions; multires entries add each level's displacements after it is made, or fit them to targets |
| `agent.s` | Agent safety: permission tiers (read-only / edit / files) and their operators, the activity ring, the AI Activity editor, one-click revert |
| `script.s` | BeeScript: lexer, one-pass bytecode compiler, stack VM (doubles, texts, nil), semispace text heap, scene builtins, macro recorder |
| `png.s` | PNG encoder: Sub/Up row filters, deflate (LZ77 hash matching, fixed Huffman), CRC-32, Adler-32 |
| `formats.s` | `.bee`, OBJ and STL import/export, file operators, autosave |
| `json.s` | Lazy JSON reader (walks text on demand) and writer on the growable buffer |
| `mcp.s` | MCP server: unix socket, JSON-RPC dispatch, tools, resources; `--mcp-bridge` relay |
| `log.s` | String builder (`fmt_*`) and the console ring buffer |
| `font.s` | Embedded 8×16 bitmap font |

Shared headers: `const.inc` (syscalls, protocol opcodes, layout metrics,
colours) and `macros.inc` (the operator record and the `OPERATOR` macro).
`build/version.inc` is generated from `VERSION` by `build.sh`.

## Calling convention

The code follows the System V AMD64 ABI:

* Arguments go in `rdi, rsi, rdx, rcx, r8, r9`; results come back in `rax`
  (`eax` for 32-bit values). Floats are passed in `xmm0`, `xmm1`, and so on.
* `rbx, rbp, r12–r15` are callee-saved. Everything else may be clobbered,
  including all `xmm` registers.
* The direction flag is always clear (we rely on `rep stosd` / `rep movsb`).
* Stack alignment is kept at 16 bytes at `_start`. Leaf routines and the current
  code do not use aligned SSE spills, so routines may push an odd number of
  registers. Any future code that does aligned stack stores must realign first.
* Globals are addressed RIP-relative (`[rip+sym]`). Indexed access to a global
  array goes through `lea reg, [rip+sym]` first, because RIP-relative
  addressing cannot take an index register.

## The operator spine

Every user-visible action is an **operator**: one 64-byte record declared with
the `OPERATOR` macro in any module.

```asm
OPERATOR op_view_grid, "view.toggle_grid", "Ground Grid", op_toggle_flag, \
         op_check_flag, show_grid, KEY_G, doc="Show or hide the ground grid and axes"
```

| Field | Meaning |
|-------|---------|
| `name` | Stable id (`area.verb`). It will become the BeeScript function and MCP tool name. |
| `label` | Text shown in menus, buttons and the console |
| `exec` | `fn(rdi = arg, rsi = op)` |
| `check` | Optional `fn(rdi = arg) -> eax 0/1`; it makes the operator a toggle (check mark, active state) |
| `arg` | 64-bit argument shared by `exec` and `check` (a flag address, a tool index, …) |
| `key` | Evdev key code, plus modifiers `KM_CTRL`, `KM_SHIFT`, `KM_ALT` |
| `flags` | `OPF_QUIET`, `OPF_AI_SAFE`, `OPF_UNDO` |
| `doc` | One-line description |

The macro emits each record into the `bee_ops` linker section. `ld` concatenates
the records from all modules and provides `__start_bee_ops` / `__stop_bee_ops`,
so the table needs no central registration list. From that one table:

* **menus** and the **tool pane** are lists of operator pointers (`ui.s`);
* **check marks** and **active-tool highlighting** come from `check`;
* **shortcut labels** are generated from `key` by `fmt_key` (e.g. `Ctrl+Shift+Z`);
* the **keymap** is `dispatch_key`, which matches the exact modifier set;
* **Help › Keyboard Shortcuts** (F1) is generated from the table;
* `beemodel --list-ops` prints the table, which CI checks.

Coming next on top of the same table: the F3 command palette (#6), BeeScript
bindings and MCP tools (phase 3).

### Adding an action

1. Write the exec function (plus a check function if it is a toggle).
2. Add one `OPERATOR` line next to the code it drives.
3. Reference the operator from a menu list (`items_*`) or `tool_ops` in `ui.s`
   if it should appear there. The key binding works without this step.

## Keyboard

The compositor sends its XKB keymap as text through `wl_keyboard.keymap`
(the fd travels as `SCM_RIGHTS`, which is why `wayland.s` keeps a queue of
received fds). `keyboard.s` parses the keycode names and the first group of
every `key <NAME> { [ … ] }` into a 256 × 4-level table of code points. It
also reads the index of the `LevelThree` and `Alt` virtual modifiers, so
AltGr works however the compositor serializes it.

* **Typing** (`kb_sym`): Shift picks level 2, Caps Lock flips letters only,
  and AltGr adds 2. Dead keys compose with the next character (`kb_compose`).
* **Shortcuts** (`dispatch_key`): a letter key is first translated to the
  QWERTY position carrying the same letter (`kb_layout_code`). Bindings are
  written as QWERTY codes, but they follow the label on the key: Ctrl+Z is
  Undo on AZERTY and QWERTZ too.
* **Repeat**: only while a text field has focus, using the compositor's
  `repeat_info` rate and delay.

## Text

`text.s` loads a sans font for the UI and a monospace font for the console.
It looks in the usual system paths (Noto, DejaVu, Liberation); override with
`BEEMODEL_FONT` / `BEEMODEL_MONO_FONT` (a `.ttf` path, or `none`). No font is
embedded, which keeps the binary small. Without a usable font, everything falls
back to the 8×16 bitmap font.

`ttf.s` reads TrueType outlines (`glyf`, including composite glyphs such as
accented letters). It flattens the quadratic curves and accumulates signed
edge coverage into a float buffer; a prefix sum then gives exact pixel area
coverage. A small gamma table keeps light text on the dark theme from looking
thin. Rendered glyphs (8-bit alpha) are cached per font and code point in a
hash table backed by a 4 MiB arena, and are alpha-blended into the framebuffer.

Text is proportional, so layout code measures with `text_width` /
`text_width_n` instead of assuming 8-pixel cells.

## HiDPI / fractional scaling

When the compositor offers `wp_fractional_scale_v1` and `wp_viewporter`,
BeeModel receives a preferred scale (in 1/120 steps, e.g. 180 = 150%):

* the shm buffer is allocated at **physical** size (`phys_w × phys_h`) and a
  `wp_viewport` destination maps it back onto the **logical** window size;
* all UI code (layout, hit testing, input) stays in logical coordinates;
  pointer events already arrive that way;
* only the primitives convert to physical pixels: `fill_rect`, `set_clip`,
  `draw_line`, `fill_vgradient`, `draw_text` (one 16.16 multiply, skipped at
  100%). Rectangles scale their *edges*, so adjacent panes stay seamless;
* fonts are re-rasterized at the physical size, and the 3D projection works in
  physical pixels, so text and geometry are sharp rather than upscaled.

The `*_px` variants (`fill_rect_px`, `draw_line_px`, `set_clip_px`) take
physical coordinates directly.

## Threads & memory

`jobs_init` starts one worker per CPU (minus the UI thread). The workers are
created with a raw `clone(CLONE_VM|CLONE_THREAD|…)` on their own 256 KiB stacks,
and `BEEMODEL_THREADS=n` overrides the count. Idle workers sleep in
`futex_wait`, so an idle BeeModel uses 0% CPU.

`parallel_for(fn, ctx, count, grain)` publishes a job. Workers and the caller
claim `grain`-sized chunks with one `lock xadd` each; that dynamic claiming
balances uneven work the way work stealing does for data-parallel loops. The
caller returns once every chunk is done. A chunk function receives
`(ctx, begin, end, thread index, scratch arena)`. The thread's scratch arena is
reset before each chunk, and `jobs_cancel` stops further claiming. Nested calls
run inline. The viewport background is the first user, with rows filled in
parallel; the Phase 2 rasterizer will be the main one.

Memory: `arena_*` is a bump allocator over a reserved (`MAP_NORESERVE`)
range. Reset is O(1), and anything touched beyond 1 MiB is given back with
`MADV_DONTNEED`. The frame arena resets every frame. `pool_*` stores
fixed-size slots with a free list. A handle is
`generation << 24 | index`, so a freed handle can never reach the slot's next
occupant. This is the basis for the scene ECS.

## Areas & editors

The content region is a binary tree (`areas.s`, max 32 nodes). A node is
either a **split** (`K_HSPLIT` side by side, `K_VSPLIT` stacked, with a 16.16
ratio for the first child) or a **leaf area** hosting an editor: 3D Viewport,
Tools, Outliner, Properties or Console. `area_layout` assigns rectangles
recursively (minimum 60 px per side), `area_hit` walks the tree for splitters,
area headers and editor contents, and `area_draw_all` draws headers, editor
bodies (each clipped to its area) and splitters.

Every area header has an editor-type menu (it reuses the operator-driven
dropdown) plus maximize, split side by side, split stacked and close. Splitting
moves the node's content to a new slot and turns the node into a split, so
references stay valid. Closing lets the sibling take the parent's slot. Each
3D Viewport area has its own camera (`cam_load` / `cam_store` swap it in and
out of the globals the viewport code uses), and Properties shows the camera of
the viewport you last used. The area under the pointer is the **active area**
that area operators act on.

## Command palette

F3 opens `palette.s`: a text field (a second instance of `textfield.s`; field
state is swapped with `tf_select`) and up to 14 operators ranked by label
prefix, then word or id prefix, then substring, then subsequence. Anything in
the operator table, including future operators, is searchable automatically.

## Scene & meshes

Objects live in a `mem.s` pool, so a handle is `generation << 24 | index`. An
ordered list of handles keeps the outliner order. An object is 128 bytes:
name, location, rotation (Euler XYZ, radians), scale, colour, mesh pointer,
flags and type (mesh, light, camera). `obj_matrix` builds the 3×4 world
matrix `T · Rz·Ry·Rx · S`. Names are made unique Blender-style (`Cube`,
`Cube.001`, …).

A mesh is a single `mmap` block: a header, then flat arrays of positions,
polygon offsets and loops (vertex indices per polygon, so n-gons are
native), unique edges and a fan triangulation. `mesh_finish` derives the
edges (hash table in the frame arena), the triangles and the bounding box.
The primitives (cube, plane, grid, UV sphere, cylinder, cone, torus, plus
the camera and light gizmos) are generated in code.

In wireframe mode (Z) the viewport draws each object's edges through its
matrix. In solid mode (the default) meshes go through the rasterizer
below; lights and cameras stay wireframes. A click in a viewport (press and
release without moving more than 3 px) picks the object under the pointer
from the ID buffer. Dragging still orbits.

## Solid rasterizer

`raster.s` renders every mesh object into the viewport canvas (physical
pixels) in five passes. Every pass except the cheap bookkeeping runs on all
cores through `parallel_for`:

1. **records**: one entry per mesh object (triangle base, camera-space vertex
   array) and a global triangle numbering;
2. **vertices**: one combined `view · model` 3×4 matrix per object, applied
   to every vertex;
3. **triangles**: in static chunks. Each triangle is flat-shaded (two-sided
   headlight), near-plane clipped (Sutherland–Hodgman, up to 2 output
   triangles), projected, and culled when it is off the canvas or covers no
   pixel centre. Kept triangles are written compactly into the chunk's own
   output range, so no atomics are needed and the order is deterministic;
4. **binning**: into 16×16 tiles with a per-(chunk, tile) count matrix;
   the prefix sum gives every chunk private cursors, so filling is also
   atomic-free and keeps triangle order;
5. **raster**: tiles in parallel, 4 pixels per step with SSE edge functions;
   depth is 1/z (perspective correct) and every pixel also gets its object ID.

A post-pass draws a 2 px selection outline wherever the ID changes next to a
selected object (orange, or gold for the active object). Picking re-runs the
passes in ID-only mode and reads the pixel under the cursor.

On the reference machine (32 threads) a scene of about 1.2 M triangles
orbits at 8–9 ms per frame at 1280×800. The output is identical for any
thread count, so golden images stay exact.

## Transforms

`transform.s` implements Blender-style modal transforms. G, R and S (or
dragging a handle of the Move / Rotate / Scale tool gizmo) snapshot the
selected objects' location, rotation and scale and compute a pivot at their
median point. Every update starts again from the snapshot, so Esc or a right
click restores the originals exactly, and nothing drifts.

* **Grab:** free movement happens in the view plane at the pivot's depth.
  With X / Y / Z, the pointer motion is projected onto the axis' on-screen
  direction (pixels per world unit), so the object follows the mouse.
* **Rotate:** uses the pointer's angle around the pivot on screen,
  accumulated across ±π, around the constrained axis (Y if none). The angle
  is flipped when the axis points away from the viewer. Locations orbit the
  pivot, and the Euler component of that axis changes.
* **Scale:** the ratio of the pointer's distance to the pivot now and at
  the start, per axis or uniform, relative to the pivot.
* **Ctrl snapping:** 1 m, 15°, 0.1 steps.
* **Numeric input:** typed text (`G X 2.5 ⏎`) replaces the mouse value. It
  accepts the digit row, the keypad, `.` `,` and `-`.

While a transform runs it receives every pointer, button and key event.

## Undo / redo

Before an operator flagged `OPF_UNDO` runs, `run_op` calls `undo_push`. A
transform records its step when it starts and drops it again on cancel, and
operators that end up changing nothing drop theirs too. A step is a snapshot
of every object record (128 bytes) in outliner order, plus which one was
active, stored in its own mapping.

Meshes are immutable and reference counted (`mesh_ref` / `mesh_unref`), so
snapshots and duplicated objects share geometry instead of copying it. Undo
pushes the current scene onto the redo stack and rebuilds the scene from the
step (`pool_clear`, then re-create the objects). Redo is the mirror image.
The history keeps at most 256 steps and 64 MiB and drops the oldest step
when full. `edit.undo_history` lists the steps in the console.

## Files

Operators take an optional text argument from the command line
(`file.save ~/models/chair.bee`). The console splits at the first space,
copies the argument, and `op_arg` points at it while the operator runs.
Operators that need a path but get none pre-fill the command line
(`file.open ~/BeeModel/`), since there is no file dialog yet. Saves write
`<path>.tmp` and `rename` it into place, so a crash can never leave a
half-written file.

* `.bee` is chunked binary (`BEEM`, version, then `MESH` / `OBJS` / `VIEW`
  chunks of tag + size + data). Each shared mesh is written once.
  Unknown chunks are skipped. The loader checks every size, offset and
  index against the file before touching the scene.
* OBJ export writes world-space vertices and n-gon faces per mesh object.
  Import reads one object: `v`, and `f` with `v/vt/vn` and negative indices.
* STL export is binary. Import detects binary or ASCII and welds identical
  corners back into shared vertices with a hash table.
* `view.screenshot` (Shift+F12) writes the last presented frame as a PNG
  (zlib stored blocks, with our own CRC-32 and Adler-32).
* Every 25 recorded changes the scene is autosaved to
  `$XDG_CACHE_HOME/beemodel/autosave.bee`; `file.recover` loads it.

## MCP server

At start-up the app listens on `$XDG_RUNTIME_DIR/beemodel-<pid>.sock`, and
the symlink `beemodel.sock` points at the newest instance. Each connection
sends newline-delimited JSON-RPC 2.0, which is exactly the MCP stdio framing.
`beemodel --mcp-bridge` therefore only relays bytes between stdin/stdout and
the socket; Claude Code and other clients launch it like a normal stdio
server.

The listener and its clients are part of the main `poll`, so requests run on
the UI thread between frames. Agents need no locking and see exactly what the
user sees. Every change goes through `run_op` or `undo_push`, which makes it
undoable like a user action.

* `json.s` does not build a tree: `j_find`, `j_str`, `j_num`, `j_first`
  and `j_next` walk the request text on demand.
* Responses are written with the `wb_*` buffer. `buf_swap` gives the server
  its own response and text buffers, so a tool that writes files does not
  collide with the reply.
* `tools/list` = curated tools (static schemas) + one `op_<id>` tool per
  operator flagged `OPF_AI_SAFE`. Exit, for example, is not agent-safe.
* `tools/call` returns the tool's own text plus every console line the
  call produced, so agents see the same feedback as the user.

## Event loop & rendering

`main.s` loops over: flush outgoing requests, `poll` the Wayland socket and the
key-repeat `timerfd`, dispatch whatever is ready, and render if something
changed. `render` draws into whichever of the
two shm buffers is free, then attaches, damages, requests a frame callback and
commits. It does not draw again until the frame callback arrives, so rendering
never outpaces the display, and CPU use is 0% while idle.

While a render runs (`hv_active`), `poll` does not wait. Each turn
`render_tick` gives Hive about 14 ms (`hive_tick`), in bands of rows across
the job threads. Each row counts its own samples, so a partly done pass
resolves correctly. The Render editor resolves the image only when it draws,
so samples that arrive between frames cost nothing extra.

## Testing

`tools/fakewl.py` is a fake Wayland compositor. It starts the real binary,
injects pointer and keyboard input, checks pixels, cursor shapes and the exit
code, and saves screenshots. CI runs it on every PR, together with
`ci/check-binary.sh` (static binary, no shared libraries, no RWX segments, size
budget, operator table sanity).
