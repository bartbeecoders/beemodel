# BeeModel

[![CI](https://github.com/bartbeecoders/beemodel/actions/workflows/ci.yml/badge.svg)](https://github.com/bartbeecoders/beemodel/actions/workflows/ci.yml)
[![Release](https://img.shields.io/github/v/release/bartbeecoders/beemodel)](https://github.com/bartbeecoders/beemodel/releases)

A shell for a 3D modeling tool, written entirely in x86-64 assembly (GNU as,
Intel syntax). It uses no libc, no libwayland and no toolkit. The program talks to
the Linux kernel through raw syscalls and to the compositor through the Wayland
wire protocol on a UNIX socket.

```
./build.sh          # assemble + link  -> build/beemodel  (~300 KB static ELF)
./build.sh debug    # same, with symbols (for gdb)
./run.sh            # rebuilds if sources changed, then starts the app
```

Requirements: `as` + `ld` (binutils) and a Wayland compositor (Hyprland, sway, GNOME, KDE...).

### Download a release

Prebuilt static binaries are attached to each [GitHub release](https://github.com/bartbeecoders/beemodel/releases):

```
curl -LO https://github.com/bartbeecoders/beemodel/releases/download/v0.8.0/beemodel-0.8.0-linux-x86_64.bin
chmod +x beemodel-0.8.0-linux-x86_64.bin && ./beemodel-0.8.0-linux-x86_64.bin
```

## What's in the shell

| Area | Details |
|------|---------|
| Title bar | Client-side decoration: logo, title, minimize / maximize-restore / close. Drag to move; double-click to maximize. Edges resize floating windows. |
| Menu bar | File, Edit, View, Create, Mesh, AI, Help dropdowns. Hover switches between open menus, check marks show toggles, shortcuts are listed, Esc closes. |
| Panes | Tools (left), Outliner + Properties (right), Console (bottom). Drag the splitters to resize; View menu shows/hides each pane. |
| Canvas | Software 3D viewport (solid shading or wireframe): perspective orbit camera, ground grid, XYZ axes, orientation gizmo. LMB orbit, MMB or Shift+LMB pan, wheel zoom, F reset, G grid. |
| Status bar | Last command, framebuffer size, window size. |

Keys: Q/W/E/R tools, T tools pane, N outliner pane, G grid, F reset camera,
F1 list all shortcuts, Ctrl+L clear console, Esc close menu, Ctrl+Q quit.
Shortcuts follow your keyboard layout (Ctrl+Z is the key labelled Z on AZERTY too).

The window is divided into **areas** like Blender's. Drag the splitters
between them. Each area's header lets you switch its editor (3D Viewport,
Tools, Outliner, Properties, Console), maximize it (Ctrl+Space), split it side
by side or top/bottom, or close it. Every viewport keeps its own camera.

The default scene has a Camera, a Light and a Cube. Add objects from the
Create menu or the tools area, click objects in the viewport or the outliner
to select them (Shift extends), **A** selects all or none, **X** / **Del**
deletes and **Shift+D** duplicates. Properties shows the active object's
transform and mesh statistics.

The viewport is solid-shaded by a multithreaded software rasterizer (Z toggles
wireframe). Move, rotate and scale objects like in Blender: **G**, **R**,
**S**, then optionally **X/Y/Z** to lock an axis, **Ctrl** to snap, or type a
value (`G X 2 ⏎`). **Enter** / left click confirms, **Esc** / right click
cancels. The Move / Rotate / Scale tools (Shift+W/E/R) show gizmos you can
drag. The grid toggle is **Shift+G**. **Ctrl+Z** / **Ctrl+Shift+Z** undo and
redo every change (create, delete, duplicate, transforms). Selected objects get an orange outline, the active one gold.

**Tab** switches the active mesh into **edit mode**:

- **Select modes.** **1 / 2 / 3** pick vertices, edges or faces. Click to select;
  **Shift**+click extends, **A** selects all or none, **Ctrl+I** inverts.
- **Selection tools.** **B** then drag box-selects (**Ctrl** subtracts),
  **Alt**+click selects an edge loop and **Ctrl+L** grows the selection to
  linked geometry.
- **Transforms.** **G / R / S** move, rotate and scale the selection, with the same
  constraints, snapping and typed values as objects.
- **Undo.** Every edit is undoable.
- **Visibility.** Hidden vertices and edges are neither drawn nor picked; wireframe mode (Z)
  shows and picks everything.

Modeling tools, also in the **Mesh** menu:

| Key | Tool |
|---|---|
| **E** | Extrude the selected faces and slide them along the normal (edges extrude to new faces) |
| **Alt+E** | Extrude every face along its own normal |
| **I** | Inset faces; move the mouse or type a thickness |
| **X** / **Del** | Delete vertices, edges or faces, by select mode |
| **Ctrl+X** | Dissolve into n-gons |
| **M** | Merge at the centre; collapse and merge-by-distance are in the menu |
| **F** | Fill a hole or make a face |
| **Shift+D** | Duplicate the selected faces |
| **Shift+N** | Recalculate normals |
| **Ctrl+R** | Loop cut: hover an edge, the wheel sets the number of cuts, click to cut |
| **Ctrl+B** | Bevel the selected edges: drag the width, the wheel sets segments |
| **K** | Knife: click points across the visible faces, Enter cuts |

The menu also has Subdivide, Flip Normals, Bisect (a plane cut), Bridge Edge Loops (joins two
boundary loops) and Spin (sweeps a profile around the **3D cursor**). **Shift+right click**
places the 3D cursor on the surface or the ground, and new objects are created there.

Typed values work like in transforms (`E 1 ⏎`, `I 0.2 ⏎`), and each tool is a single undo step.

**Modifiers** are non-destructive operations on a mesh. The Properties editor lists the active
object's stack.

- **Add** opens the list of types; each modifier has buttons to switch it on or off, move it up or
  down, apply it or remove it.
- **Drag** a value to change it; one drag is one undo step.
- **Ctrl+2** adds a Subdivision Surface.

| Modifier | Does |
|---|---|
| Mirror | Mirrors along an axis, merging vertices at the seam |
| Array | Repeats the mesh, offset relative to its size |
| Solidify | Adds a shell along the normals, with rims on open edges |
| Subsurf | Catmull–Clark subdivision; cached and parallel, so level 3 of a 100k-quad mesh updates in about 19 ms after an edit |
| Bevel | Bevels edges sharper than an angle |
| Decimate | Reduces to a ratio of the vertices |
| Remesh | Rebuilds the surface as voxel-based quads |
| Boolean | Union, difference or intersection with another object's mesh; follows that object when it moves |
| Multires | Subdivision levels that keep sculpted detail as displacements: sculpt at any level, finer levels follow; *Propagate Down* gives coarser levels the finest shape |

**Booleans.** Edit › Boolean Union / Difference / Intersect combine the active mesh with another
selected one: the other mesh is used up, and the operation is one undo step. They use exact
integer predicates with a symbolic perturbation, so they stay correct on degenerate input:

- faces lying on faces;
- identical meshes;
- primitives rotated by a quarter turn typed as `1.570796`.

Faces on faces come out the way you would want: a flush cut goes through, touching solids fuse,
and A − A is empty. A stress corpus in CI checks the volume identities and closed results on
every change.

**Materials** follow the principled model the renderer uses:

- base colour, metallic, roughness, specular and IOR;
- transmission;
- emission and its strength;
- clearcoat and its roughness;
- alpha.

The Material section of Properties shows the active mesh's material.

- **+ New** makes one.
- **Drag** the name to pick another material, or drag a value to change it.
- **x** removes it.

The solid viewport shows the base colour; **View › Material Preview** (Shift+Z) shades every pixel
with the full material under a studio environment. Materials are saved in `.bee` files and exported as MTL next to an OBJ. Scripts use
`material`, `matset`, `matget`, `assign` and `matof`; agents see them in `scene_summary` and use
the `material.*` operators.

**Rendering.** Hive is BeeModel's path tracer (CPU, every core). It renders what the camera object
sees (or the viewport, without one) with the same principled materials:

- glass refracts;
- metal reflects;
- clearcoat shines;
- emissive faces light the scene;
- light objects act as point lights;
- a studio sky and sun light everything.

`render.image <path> [width height samples]`, or `render(path, w, h, samples)` from a script,
writes a PNG. A 480 × 270 image with 64 samples takes about a third of a second on 32 threads.

**F12** renders into a Render area beside the viewport, refining while you keep working; **Esc**
stops. A finished or stopped render is denoised (guided by the albedo, normal and depth
passes; Render › Denoise turns it off), so 16 samples look close to 256. The Render menu
switches passes (beauty, albedo, normal, depth) and saves them
(`render.save <path> [pass]`, PNG or linear half-float `.exr`); `render.settings <width>
<height> <samples>` sets the size and samples, which are saved with the scene.

**Images.** `image.load <path>` reads PNG (every colour type, depth and interlacing), baseline
JPEG and Radiance HDR files, all with BeeModel's own decoders; `image.save <name> <path>`
writes PNG or OpenEXR. `material.texture <material> <image> [size]` puts an image on a material
(box-projected until meshes get UVs), and `world.hdri <image>` lights the scene with an
equirectangular HDRI (`world.strength`, `world.rotation`). Hive importance-samples it, and the
material preview uses it too. Image paths and the world are saved with the scene.

**Parameters and units.** `scene.units mm` makes one unit a millimetre. `param.set wall 2mm` and
`param.set width 10*wall + 1cm` define parameters with expressions and units. Change `wall` and
everything that depends on it follows. The parameters are listed in Properties, saved with the
scene, and part of undo.

**Sketches.** `sketch("Base", "XY")` (or Create in a script) makes a sketch object. Tab enters
sketch mode, which has these tools and keys:

- **Tools:** L draws lines, O circles and R rectangles.
- **Constraints:** C H V E P N T F M add them.
- **Dimensions:** D, then type a value or an expression such as `width`.
- **Other:** X deletes; dragging a point moves it while the solver keeps the constraints.

A damped Newton solver keeps every constraint. Lines are blue while free and light when fully
constrained, conflicts are red, and the status line counts the remaining degrees of freedom. Change a
parameter and the sketch follows.

**Shader graphs.** A material can hold a small node graph that drives its base colour,
roughness, metallic, emission and normal:

```
m = material("Stone")
n = node(m, "noise", 3, 5, 0.55)
r = node(m, "ramp")
link(m, n, r, 1)
nodeset(m, r, 2, 0.6, 0.15, 0.05)
socket(m, "base", r)
b = node(m, "bump", 2, 0.2)
link(m, n, b, 1)
socket(m, "normal", b)
```

The node types are image, noise, checker, gradient, mix, ramp, math, bump and normalmap. Agents see
the graph in `scene_summary` and edit it with the `material.node*` commands.

The **Node Editor** (any area's type menu) shows the active object's material graph as boxes and
wires, laid out by depth until you move them. **Shift+A** adds a node at the pointer, dragging a
header moves it, dragging from an output to an input or a Material Output socket links them (from a
linked input it picks the link up; dropped on empty space it is gone), dragging a value sideways
changes it, **X** deletes the selected node, middle or empty-space drags pan, Home fits. Links may go
either way: the graph keeps itself in evaluation order and refuses loops. Every change is an undo
step and an operator (`material.link`, `material.node_move`, `material.node_delete`, ...), and
`nodeinfo(...)` reads the graph back in scripts.

**Analysis and repair.** View › Show Normals / Non-manifold / Boundary Edges / Degenerate Faces /
Overhangs mark problems on the active mesh, with a count of each in the viewport.

Edit › Repair Mesh (`mesh.repair [distance]`) works in object and edit mode, as one undo step:

1. merges vertices closer than the distance;
2. removes faces without area and duplicate faces;
3. fills holes;
4. makes the normals consistent and points them outwards;
5. drops loose vertices.

It reports what it did. Scripts and agents read the counts with `analyze(name, what)`.

Modifiers are saved in `.bee` files. Scripts use `modifier`, `modset`, `modapply` and `modremove`;
agents see an object's modifiers in `scene_summary`.

The **redo panel** (bottom left of the viewport) shows the values of the last tool:
distance, thickness, width and segments, cuts, steps and angle.

- **Drag** a value, or scroll over it, and the tool runs again with the new value.
- **F9** puts the values on the command line to type.
- Agents can call `edit.redo_last "values"`.

It all stays one undo step.
Scripts and agents call the same operators with the value as the argument:
`op("mesh.inset", 0.1)`.

Files: **Ctrl+S** saves (`.bee`), **Ctrl+O** opens, and File › Import / Export
handle **OBJ** (with MTL materials), **STL** and **glTF 2.0** (`.glb` / `.gltf`, with PBR
materials). For making things there is **3MF** for 3D printers (millimetres,
Z up), **DXF** and **SVG** of a sketch, and **PDF** drawings (front / top /
right views with hidden lines and dimensions). Commands take paths on the command line, for
example `file.save ~/BeeModel/chair.bee` or `file.import_stl ~/part.stl`.
Without a path, the command line opens pre-filled. **Shift+F12** saves a PNG
screenshot. The scene autosaves every 25 changes (`file.recover` restores
it).

### AI agents (MCP)

BeeModel is an MCP server. While it runs, an agent such as Claude Code can
inspect and edit the scene you are looking at. Every change is undoable.

```
claude mcp add beemodel -- /path/to/beemodel --mcp-bridge
```

For Claude Desktop (or any MCP client using stdio), add this to its config:

```json
{ "mcpServers": { "beemodel": { "command": "/path/to/beemodel", "args": ["--mcp-bridge"] } } }
```

Full details: [docs/MCP.md](docs/MCP.md). `--mcp-bridge` relays stdio to the running app's socket
(`$XDG_RUNTIME_DIR/beemodel.sock`; `BEEMODEL_SOCKET` overrides it, and
`BEEMODEL_NO_MCP=1` turns the server off). Tools:

* `scene_summary` and `create_primitive`;
* `set_transform`, `select` and `delete`;
* `run_operator`, `undo` and `redo`;
* `viewport_capture`, so the agent can see the scene: it returns a PNG of the
  viewport (or of the whole window, with `area: "window"`);
* `script_eval`, which runs BeeScript (see below) as one undo step;
* every agent-safe operator as `op_<id>`, for example `op_file_save`.

The scene is also available as the resource `bee://scene`.

Agents work under three safeguards:

- **Permissions.** The **AI** menu sets what agents may do:
  - *Read Only*: look at the scene;
  - *Edit Scene* (the default): look at and edit it;
  - *Edit + Files*: also open, save, import, export and take screenshots.

  The status bar shows the current level and how many agents are connected. To start with a
  different level, set `BEEMODEL_AGENT_PERMISSION=read|edit|files`.
- **Change sets.** Each agent request is one named undo step, such as `Agent: set_transform`.
- **AI Activity.** **AI → AI Activity Pane** lists recent agent calls: their status, whether they
  changed the scene, and the result. Its **Revert last agent change** button undoes the newest
  change set.

### CAD and fabrication

Parts are designed from **parameters** (`param.set wall 2mm`, expressions with
units) and **sketches** with constraints and dimensions (Tab enters sketch
mode on a sketch object). **Features** turn sketches into solids: pad, pocket,
revolve, hole, shell, fillet, chamfer, linear and circular patterns, and
lattice infill. The tree rebuilds when any parameter or sketch changes, and
undo and `.bee` files keep it.

```
op("scene.units", "mm")
param("w", "80mm")
s = sketch("Base", "XZ")
r = rect(s, 0, 0, 80, 50)
con(s, "length", r, "w")
b = pad("Case", s, "30mm")
fillet("Case", "4mm", "vertical")
shell("Case", b, "2mm")
param("w", "100mm")             # the case widens; rounds and walls follow
```

[tests/enclosure.bees](tests/enclosure.bees) is a complete printable enclosure
(case, lid with lip and vents) built this way.

To make things:
- **3MF** for printers: File › Export 3MF writes millimetres, Z up.
- **DXF / SVG** of a sketch.
- **PDF drawings**: front, top and right views with hidden lines and dimensions.
- **Print check** (Edit menu): reports whether the part is closed, the
  thinnest wall, overhangs and size. *View › Show Thin Walls* marks walls
  under a minimum.
- **Measure tool** (Shift+M): distances and angles. `object.measure`
  reports volume, area, mass (from material density) and centre of mass.
- **Signed-distance shapes** (`sunion`, `sgyroid`, `smesh`, ...): blend and
  lattice shapes into closed meshes.

### Sculpting

Ctrl+Tab puts the active mesh in **sculpt mode**. It handles tens of
millions of vertices: on a 25M-vertex mesh, stroke frames take 11 ms at the
median and stay under 16.7 ms (60 fps) at the 95th percentile on a 32-thread
desktop ([tests/sculpt20m.py](tests/sculpt20m.py)). While you stroke, only
the parts of the mesh the brush changed are projected and drawn again.
Brushes: X draw,
C clay strips, Shift+C crease, I inflate, G grab, K snake hook, S smooth
(Shift with any brush), Shift+T flatten, P pinch, L layer, M mask (Alt+M
clears, Ctrl+I inverts). `[` `]` size the brush, Shift+`[` `]` its strength,
Ctrl inverts it, Shift+X mirrors strokes across X. Each stroke is one undo
step that stores only the vertices it moved. Scripts sculpt too:
`sculpt("Ball", "draw", 0, 1, 0.3, 0.2, 1, 0.3, 0.3, 0.5)`.

**Multiresolution**: with a Multires modifier first in the stack, sculpt
mode sculpts its `level` (0: the base cage). A stroke becomes displacements
at that level, so finer levels keep their own detail on top and coarser
levels keep their shape; `multires.propagate_down` refits the coarser
levels to the finest. The displacements are saved in `.bee` files and
undo with the stroke.

**Dynamic topology** (Ctrl+D): brushes split edges longer than the detail
size and collapse shorter ones as they go, so detail appears where you
sculpt (Ctrl+`[` `]` set the detail, in screen pixels). The mesh becomes
triangles; each stroke's undo step keeps the mesh before it.

A **pen tablet** works through the Wayland tablet protocol: pressure scales
the strength (and, with *Pressure: Radius*, the radius) through a soft,
linear or hard curve (`sculpt.pressure_curve`); the eraser end inverts the
brush; the stylus buttons are the middle and right mouse buttons. Shift+S
cycles a **stabilizer** (off, 10, 25, 50 px): the stroke trails the pointer
on a string, so wobbles shorter than it never reach the surface. Without a
tablet nothing changes: the mouse is full pressure.

### UV maps

In edit mode, **Ctrl+E** marks the edges between selected vertices as UV
seams (red; Ctrl+Shift+E clears them) and *Seams from Sharp Edges* marks
every edge over 30 degrees. **U** unwraps along the seams with least
squares conformal maps (our own sparse conjugate-gradient solver, per
island), **Shift+U** projects groups of faces facing alike flat, and both
pack the islands into the unit square: one texel density, each island
turned to its smallest box, placed on a skyline. UVs and seams are saved in
`.bee` files and exported to OBJ (`vt`) and glTF (`TEXCOORD_0`). Image
textures follow the UVs in the material preview and the path tracer (an
image node's size 1 covers the unit square once; meshes without UVs keep
box projection). `image.new <name> [width height]` makes an image to paint
on; new and painted images are saved inside the `.bee` file as PNG.

The **UV Editor** (any area's type menu) shows the active mesh's layout over
the unit square: a click selects the island under the pointer (Shift adds),
**A** all / none, **G** / **S** / **R** move, scale and rotate the selected
islands (a click or Enter keeps it, right click or Esc puts it back), middle
drag pans, the wheel zooms, Home fits. **D** cycles a distortion heat map
(area: blue where the UVs are squeezed, red where stretched; angle), and
the header gives the islands and the texel density of a 1024 px map.

### Texture painting

**Shift+Tab** paints the active mesh's texture - the first image in its
material - through its UVs (Shift+Z shows it in the material preview). A
stroke in the viewport is projected onto the surface: only what you see
is painted, and island borders get a texel and a half of bleed so seams do
not show. In the UV editor the same brush paints the image directly, shown
under the layout. `[` `]` size the brush, Shift+`[` `]` its strength,
`paint.color r g b` sets the colour; Ctrl+Z / Ctrl+Shift+Z step through the
strokes. Scripts paint with `paint(object, x, y, z, radius [, r, g, b])`.

Paint **layers**: Shift+N adds a transparent layer above (painted from then
on), PageUp / PageDown pick the layer painted, `paint.layer_merge`
flattens. Each layer has an opacity, a blend mode (normal, multiply, add)
and can be hidden (`layer(image, ...)` in scripts); the image is their
composite, and the stack is saved in the `.bee` file.

**Vertex colours**: Shift+V paints the active mesh's vertices with the same
brush (visible ones only; each stroke is an undo step). They tint the
material - per triangle in the solid view, smoothly in the material
preview and the path tracer - and go to OBJ (`v x y z r g b`), glTF
(`COLOR_0`) and `.bee` files. Scripts: `vpaint(...)`, `vcol(...)`.

**Baking**: `object.bake <low> <high> <normal|ao|curvature> <image>
[distance]` (or `bake(...)` in scripts) bakes a high-poly mesh's detail
into an image through the low-poly mesh's UVs, with the path tracer's BVH:
a tangent-space normal map, ambient occlusion (48 rays per texel), or
curvature (light convex, dark concave). Rays start a cage distance outside
the low surface (5% of its size unless given); island borders are dilated
so seams do not show. A bake is one texture-paint undo step. 1024 x 1024
from a 127k-triangle mesh: about 0.2 s for normals, 0.7 s for AO. A
`normalmap` shader node (an image node into it, it into the `normal`
socket) shades the low mesh with the baked detail.

[tests/sculpt_paint.bees](tests/sculpt_paint.bees) is the whole workflow:
it sculpts a creature head, bakes its normal, AO and curvature maps into a
light head, and paints that head with a base coat and a multiplied moss
layer (AO in the material, the normal map on top). It then gives a pedestal
vertex colours, saves the scene and renders it.

### BeeScript

BeeScript is a small scripting language built into BeeModel. Lines typed in the console that are not
operator ids run as BeeScript:

```
for i in 0..10 { add("cube", "Step" + i, i * 2m, 0, 0) }
fn twice(a) { return a * 2 }
```

Numbers carry units (`2m`, `20cm`, `45deg`), and a whole run is one undo step.
**Edit → Record Macro** records your actions as a script. Scripts can also run without a window:
`beemodel --eval '...'` or `beemodel --run file.bees`. The full reference is in
[docs/BEESCRIPT.md](docs/BEESCRIPT.md).

Press **F3** for the command palette: type part of any command name and press
Enter.

Press **Enter** to type into the console command line. Any operator id runs
(e.g. `view.toggle_grid`). Tab completes and cycles through ids, Up/Down
browse the history, and `console.list_ops` lists every id. Run `beemodel --list-ops` to
see every operator with its id, binding and description.

## Performance & memory

* **Event driven**: the app blocks in `recvmsg()`. It redraws only when state
  changes, and the compositor's frame callbacks pace the redraws. CPU use is 0% while idle.
* **Footprint**: about 60 KB of private memory. The only large allocation is the
  shared framebuffer (2 × W×H×4, one memfd). When the window shrinks, the freed
  tail of that memory goes back to the kernel (`MADV_REMOVE`). At 1280×800 the
  whole process uses about 4 MB.
* **Rendering**: `rep stosd` span fills, a clipped 8×16 bitmap font, Bresenham
  lines with near-plane and Liang–Barsky clipping, and SSE scalar math. Sin and cos
  come from the x87 `fsincos` instruction instead of libm.
* **Cursors**: set through `wp_cursor_shape_v1`, so the app needs no cursor theme
  or image loading.

## Source layout

```
src/main.s      entry point, CLI flags, event loop (a render slice per turn)
src/wayland.s   socket, message encode/decode, SCM_RIGHTS, shm buffers, dispatch, tablets
src/draw.s      framebuffer primitives: rects, gradient, text, lines, clipping
src/ui.s        layout, hit testing, input, menus, status bar
src/areas.s     area tree, editors, splitting / closing / maximizing
src/palette.s   F3 command palette (fuzzy operator search)
src/ops.s       operator spine: operator table, runner, keymap, --list-ops
src/keyboard.s  XKB keymap parser, levels, dead keys, layout-aware shortcuts, key repeat
src/textfield.s UTF-8 text field (console command line)
src/ttf.s       TrueType parser, anti-aliased rasterizer, glyph cache
src/text.s      font selection, UTF-8 text drawing and measurement
src/font.s      embedded bitmap font (data in src/font.inc)
src/jobs.s      worker threads, futex, parallel_for
src/mem.s       arenas and generational-handle pools
src/log.s       string builder + console log
src/selftest.s  --selftest unit tests + benchmark
src/scene.s     objects, selection, transforms, object operators
src/undo.s      undo / redo snapshots
src/redo.s      adjust-last-operation panel
src/transform.s G / R / S modal transforms, constraints, numeric input
src/viewport.s  camera, projection, grid / axes / gizmos, overlays
src/raster.s    multithreaded triangle rasterizer, depth + visibility buffers
src/preview.s   material preview shading (principled, studio or HDRI, graphs)
src/mesh.s      polygon meshes and primitive generators
src/edit.s      edit mode: selection, picking, overlays
src/meshops.s   mesh operators (extrude, inset, loop cut, ...)
src/meshops2.s  more mesh operators (bevel, bridge, ...)
src/subsurf.s   Catmull-Clark subdivision
src/mods.s      modifier stack (+ mods2.s)
src/bool.s      exact mesh booleans (snapped, 128-bit orient3d, per-triangle CDT)
src/repair.s    mesh analysis and repair
src/material.s  principled materials (copy-on-write, undoable), Properties UI
src/graph.s     shader graphs: nodes, sockets, evaluation, bump, normal maps, sorting
src/texture.s   image lookups, box projection
src/env.s       the world: HDRI lookups, importance sampling, SH irradiance
src/hive.s      Hive path tracer: triangle soup, SAH BVH4, SSE traversal
src/hive_pt.s   Hive light transport: NEE + MIS, principled BSDF, passes
src/denoise.s   edge-avoiding a-trous denoiser (albedo / normal / depth)
src/render.s    the Render window and render.* operators
src/image.s     the scene's images, image.* operators
src/imgread.s   PNG and Radiance HDR readers
src/inflate.s   inflate + zlib
src/jpeg.s      baseline JPEG decoder
src/png.s       PNG encoder (row filters, LZ77 + Huffman deflate)
src/exr.s       OpenEXR writer (half floats, ZIP)
src/formats.s   .bee files, OBJ / STL import + export, file operators
src/mtl.s       MTL import (OBJ materials)
src/gltf.s      glTF 2.0 import / export
src/expr.s      expressions with units
src/cad.s       the CAD document: units, parameters, the feature records
src/sketch.s    sketches and the constraint solver
src/sketchobj.s sketch objects, display, rebuild
src/sketchui.s  sketch mode
src/prof.s      profiles from sketches: loops, caps, prisms, revolutions
src/feature.s   the feature tree and its rebuild
src/measure.s   mass properties, the measure tool
src/sdf.s       signed-distance shapes, marching tetrahedra
src/fab.s       3MF export, DXF / SVG of sketches
src/drawing.s   PDF drawings: views, hidden lines, dimensions
src/print.s     printability: wall thickness, print check
src/sculpt.s    sculpt mode: leaf BVH, brushes, delta undo, splat drawing
src/dyntopo.s   dynamic topology: edge split / collapse under the brush
src/multires.s  multiresolution: per-level displacements, level sculpting
src/uv.s        UV maps: seams, LSCM unwrap (CG solver), smart projection, packing
src/uved.s      the UV editor area: islands, transforms, heat map, texel density
src/nodeed.s    the node editor area: shader graphs drawn and edited
src/paint.s     texture painting: projected dabs, UV-space dabs, stroke history
src/layers.s    paint layers: stack, blend modes, composite, saving
src/vcol.s      vertex colours: vertex paint, tinting, files
src/bake.s      baking normal / AO / curvature maps, high to low
src/json.s      lazy JSON reader + writer
src/fileio.s    paths, files, the write buffer
src/mcp.s       MCP server (unix socket, JSON-RPC) and the --mcp-bridge relay
src/agent.s     agent permissions, activity log, revert
src/script.s    BeeScript: lexer, one-pass compiler, stack VM, builtins, macros
src/const.inc   syscalls, opcodes, layout metrics, theme colours
src/macros.inc  operator record layout + OPERATOR macro
```

Text is rendered with your system's TrueType fonts (Noto / DejaVu /
Liberation, found automatically). Set `BEEMODEL_FONT` / `BEEMODEL_MONO_FONT`
to a `.ttf` path to choose others, or to `none` for the built-in bitmap font.

BeeModel uses every core: worker threads (one per CPU) sleep until there is
parallel work. `BEEMODEL_THREADS=n` limits them. `beemodel --selftest` runs
the built-in allocator and job-system tests and a small benchmark.

Each `.s` file is a separate module linked by `ld`. See
[docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) for the calling convention, the
operator spine and how to add an action.

## Dev tools (optional, Python; not needed to build or run)

* `tools/genfont.py` regenerates `src/font.inc` from a PSF console font.
* `tools/genkeysyms.py` regenerates `src/keysyms.inc` (keysym names → Unicode).
* `tests/keymaps/*.xkb` are real US, Belgian and German keymaps, used by the
  headless tests.
* Golden images (`tests/golden/*.png`) are compared pixel by pixel when the
  harness runs with `BEEMODEL_GOLDEN=check` and the bitmap font
  (`BEEMODEL_FONT=none BEEMODEL_MONO_FONT=none`), which keeps them identical on
  every machine. After an intended visual change, regenerate them with
  `BEEMODEL_GOLDEN=update` and review the PNG diff in the PR. The harness also
  enforces budgets: first frame < 500 ms, input-to-frame latency < 16 ms,
  private memory < 16 MiB.
* `tools/fakewl.py` is a headless fake Wayland compositor. It runs the app,
  injects pointer and keyboard input, and saves PNG screenshots of each step to
  `build/shots/` (needs Pillow). It tests the app in isolation, without touching
  your desktop.

## Development workflow

* `main` is always releasable. All work happens on a branch (`feat/…`, `fix/…`,
  `ci/…`) and is merged through a pull request once CI is green.
* CI (`.github/workflows/ci.yml`) runs on every PR and push to `main`. It builds
  release and debug binaries, runs `ci/check-binary.sh` (static, no shared
  libraries, no RWX segments, size budget of 256 KiB) and runs the headless UI test.
  Screenshots are uploaded as a workflow artifact.
* **Releasing:** bump `VERSION`, move the `[Unreleased]` notes in `CHANGELOG.md`
  into a new version section, and merge via a PR. Then tag:
  `git tag -a v0.2.0 -m "BeeModel 0.2.0" && git push origin v0.2.0`.
  The release workflow checks that the tag matches `VERSION`, builds, tests and
  packages the app (`./package.sh`), and publishes a GitHub release with notes
  taken from the changelog.
