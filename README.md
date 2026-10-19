# BeeModel

[![CI](https://github.com/bartbeecoders/beemodel/actions/workflows/ci.yml/badge.svg)](https://github.com/bartbeecoders/beemodel/actions/workflows/ci.yml)
[![Release](https://img.shields.io/github/v/release/bartbeecoders/beemodel)](https://github.com/bartbeecoders/beemodel/releases)

A shell for a 3D modeling tool, written entirely in x86-64 assembly (GNU as,
Intel syntax). It uses no libc, no libwayland and no toolkit. The program talks to
the Linux kernel through raw syscalls and to the compositor through the Wayland
wire protocol on a UNIX socket.

```
scripts/build.sh        # assemble + link  -> build/beemodel  (~300 KB static ELF)
scripts/build.sh debug  # same, with symbols (for gdb)
scripts/run.sh          # rebuilds if sources changed, then starts the app
```

Requirements: `as` + `ld` (binutils) and a Wayland compositor (Hyprland, sway, GNOME, KDE...).

### Download a release

Prebuilt static binaries are attached to each [GitHub release](https://github.com/bartbeecoders/beemodel/releases):

```
curl -LO https://github.com/bartbeecoders/beemodel/releases/download/v0.21.0/beemodel-0.21.0-linux-x86_64.bin
chmod +x beemodel-0.21.0-linux-x86_64.bin && ./beemodel-0.21.0-linux-x86_64.bin
```

## What's in the shell

| Area | Details |
|------|---------|
| Title bar | Client-side decoration: logo, title, minimize / maximize-restore / close. Drag to move; double-click to maximize. Edges resize floating windows. |
| Menu bar | File, Edit, View, Select, Add, Object, Mesh, Render, AI, Help, with submenus, then the workspace tabs (Modeling, Sculpt, CAD, Shading, Animation, World, your own). F10 / Alt+letter open them from the keyboard. |
| Areas | Any area can be any editor: 3D Viewport, Tools, Outliner, Properties, Console, Timeline, Dope Sheet, Graph, Node, UV, Render, Asset Browser, AI Activity, Versions, Preferences, Help. Split, join (drag a corner), swap (drag a header), maximize. |
| 3D Viewport | Software renderer with a header (mode, select mode, shading, grid, snap), a navigation gizmo, quick actions in an empty scene, right-click menus, a Z pie. |
| Properties | Object, Modifiers, Material, Physics, CAD, Scene, Render, Viewport, Animation and Rig tabs (and Landscape for a landscape): every feature as fields, buttons and pickers, in sections that fold. |
| Status bar | What the mouse and keys do now; scene size, AI permission, render progress, peers; toasts for messages. |

Every command is in a menu, a panel or a dialog with a form; tooltips say what
anything does and why it is greyed. Keys: F3 search every command, F1 every
shortcut, F6 next area, Tab through a panel's or dialog's fields, Ctrl+Z / Ctrl+Shift+Z.
The full tour: [docs/UI.md](docs/UI.md).
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
with the full material under a studio environment. **View › Rendered** draws the viewport on the GPU
(the optional helper): a raycast every frame while you orbit or edit, then path-traced samples once
the view is still ([docs/GPU.md](docs/GPU.md#rendered-shading-the-live-viewport)). Materials are saved in `.bee` files and exported as MTL next to an OBJ. Scripts use
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

**The GPU helper.** `beemodel-gpu`, an optional second program, lets a Vulkan GPU take the path
tracer's samples and the virtualized-geometry rasterizer's tiles. BeeModel itself still links
nothing: it talks to the helper over a socket and shared memory. The GPU computes the same
samples as the CPU, so the images agree, and the default scene comes out pixel-identical.
Without the helper, without a usable GPU, or if the helper fails mid-render, everything runs on
the CPU as before. Unpack the release's `beemodel-gpu` archive next to `beemodel` to use it;
[docs/GPU.md](docs/GPU.md) describes it.

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

**Shader graphs.** A material can hold a node graph, Unreal-style, that drives any of its 13
Material Output pins (base colour, metallic, specular, roughness, emission, opacity, normal, ambient
occlusion, clear coat, transmission, IOR, opacity mask ...):

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

There are 42 node types (textures, patterns, inputs, 31 math operations, vector math, colour
adjustments, bump and normal maps, parameters, functions), parameters with material instances,
material functions shared by many materials, PBR texture-set import, 20 presets, baking to texture
maps, glTF and OBJ texture maps both ways, and graphs on the GPU path tracer: see
[docs/MATERIALS.md](docs/MATERIALS.md). Agents see the graphs in `scene_summary`, read and write
them as JSON with `material_graph` / `material_graph_set`, and use the `material.*` operators.

The **Node Editor** (any area's type menu) shows the active object's material graph as boxes and
wires, laid out by depth until you move them, with a live preview and per-node thumbnails.
**Shift+A** adds a node at the pointer (type to search), dragging a
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
handle **OBJ** (with MTL materials), **STL**, **glTF 2.0** (`.glb` / `.gltf`, with PBR
materials) and **Blender** (`.blend`). Blender files from 2.80 to 5.x open natively,
compressed ones too: their meshes, UVs, cameras, lights, and materials with their images.
They save through Blender, run in the background ([docs/BLEND.md](docs/BLEND.md)). Files
dropped on the window are imported by their kind. For making things there is **3MF** for 3D printers (millimetres,
Z up), **DXF** and **SVG** of a sketch, and **PDF** drawings (front / top /
right views with hidden lines and dimensions). Commands take paths on the command line, for
example `file.save ~/BeeModel/chair.bee` or `file.import_stl ~/part.stl`.
Without a path, the command line opens pre-filled. **Shift+F12** saves a PNG
screenshot. The scene autosaves every 25 changes (`file.recover` restores
it).

### The AI Assistant

Describe a world, a model or a change, and BeeModel builds it while you watch.

- **Ctrl+Shift+Space** opens the AI workspace. Type a prompt and press Enter.
- The assistant uses Claude Code, the Grok CLI or OpenRouter (any model). Each one acts through BeeModel's own tools.
- Each request is one undo step, with a **Revert** button.
- Connections, models and keys are set and tested in **Edit › Preferences › AI**. The OpenRouter key is kept in a 0600 secrets file.

The guide is [docs/AI.md](docs/AI.md).

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
* every agent-safe operator as `op_<id>`, for example `op_file_save`;
* the procedural co-pilot: `node_types` (the node catalogue), `describe_graph`, and
  `propose_begin` / `propose_end` / `proposal_status`. An agent builds a node setup, the
  viewport shows it with an **Accept** / **Revert** banner (Enter / Esc), and either way it is
  one undo step. The MCP prompt `procedural` hands an agent this flow for a goal, and
  `build_world` hands it the AI Assistant's world-building instructions.

The scene is also available as the resource `bee://scene`, and the node trees as `bee://graphs`.

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

**The B-rep kernel.** `op("cad.kernel", "on")` makes the features build exact
solids instead of meshes:

- **Geometry:** NURBS and analytic surfaces (planes, cylinders, cones,
  spheres, tori), trimmed by loops of edges.
- **Operations:** booleans through surface-surface intersection, fillets
  and chamfers on straight edges.
- **Display:** an adaptive, watertight tessellation.

Volumes and areas are integrated exactly over the trimmed faces;
`brep(name, "volume")` returns them. The enclosure above builds on it. See
[docs/BREP.md](docs/BREP.md).

**STEP.** `file.export_step` writes the solids as STEP (ISO 10303-21, AP214):
one part in place, or several as an assembly with their placements, colours
and units. `file.import_step` reads STEP parts and assemblies, analytic or
NURBS, from other CAD systems back into the kernel. Volumes survive a round
trip through FreeCAD to 1e-6.

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

### Geometry nodes

A **Geometry Nodes** modifier runs a node tree on the mesh below it: the Group Input is that
mesh, the Group Output what the object shows. Nodes make and change geometry - grid, cube, UV
sphere, cylinder, mesh line, transform, join, set position, extrude, subdivision surface, mesh
boolean, merge by distance - and **fields** give a value or vector per point: position, normal,
index, value, combine / separate XYZ, math, vector math, noise and random. A field compiles to
a small program for the field VM, which runs it 256 points at a time in SSE loops across the
job threads (noise on a million-point grid: about 25 ms on top of making the grid). Programs run
on enough points are compiled to machine code at run time by a template JIT (AVX, else SSE;
`BEEMODEL_JIT=0` turns it off, `=sse` keeps to SSE): 1M points x 42 instructions take ~2 ms on
one core against ~4.7 ms in the VM, and the self-test checks the JIT bit for bit against the VM
on random programs. Trees are
saved in `.bee` files and undo with the scene; the Node Editor shows the active object's tree
(Tab switches to its material).

```
t = gtree("Terrain")
o = gnode(t, "output")
g = gnode(t, "grid", 6, 60)            # size, subdivisions
sp = gnode(t, "set_position")
n = gnode(t, "noise", 0.6, 3)          # scale, detail
c = gnode(t, "combine_xyz")
glink(t, g, sp, 1)                     # from, to, input [, output]
glink(t, n, c, 2)                      # noise -> Y
glink(t, c, sp, 3)                     # -> Offset
glink(t, sp, o, 1)
m = modifier("Cube", "geometry")
modset("Cube", m, "tree", t)
```

**Scattering and instancing.** *Distribute Points on Faces* scatters points by area and density
(a seed; a minimum distance thins them) and the points keep their faces' normals. *Instance on
Points* places another geometry at every point - aligned to the normal or up, turned at random,
scaled by a field - as **instances**: one prototype mesh and a matrix each, never copied. The
viewport draws them directly (instances under ~3 pixels as depth-tested squares, bigger ones as
their triangles, binned into screen tiles across the threads): a million are placed in about
12 ms and orbit at about 35 ms a frame on a 32-thread desktop. *Realize Instances* turns them into
plain geometry; the path tracer takes them as triangles (4 million at most).

**Curves.** *Create > Bezier Curve / Bezier Circle / Path* adds a curve: Bezier or poly splines
of control points with handles (auto, aligned, vector or free; auto handles make a 4-point circle
round), a resolution per span, a radius and a tilt per point. **Tab** edits the points: click
selects (Shift adds), **G / R / S** move them and their handles, **E** extrudes an end, **Ctrl+click**
adds a point at the pointer, **W** subdivides (the shape kept), **X** deletes, **V** cycles the
handle type, **Alt+C** opens or closes a spline. `curve.set bevel 0.1` sweeps it into a tube
(`sides`, `fill` caps), `curve.set profile <curve>` along another curve's shape, with frames that
stay upright on the ground and spread a closed path's twist. What a curve makes is an ordinary
mesh, so modifiers, materials, rendering and export just work (OBJ writes a bare curve as `l`
lines); `curve.to_mesh` turns it into that mesh for good. The curve nodes - Curve Line, Curve Circle, Curve to Mesh,
Resample, Trim, Fillet, Curve to Points - work on chains of 2-point polygons, so a Geometry
Nodes modifier on a curve object reads its curve:

```
delete("Cube")
c = curve("circle", "Rail")
t = gtree("Fence")
i = gnode(t, "input")                  # the curve the modifier is on
o = gnode(t, "output")
tube = gnode(t, "curve_to_mesh", 0.04, 8)
glink(t, i, tube, 1)                   # the rail: a tube along it
cp = gnode(t, "curve_to_points", 12)   # 12 upright points along it
glink(t, i, cp, 1)
post = gnode(t, "cylinder", 0.03, 0.8)
ip = gnode(t, "instance", 0, 0, 0)
glink(t, cp, ip, 1)
glink(t, post, ip, 2)
j = gnode(t, "join")
glink(t, tube, j, 1)
glink(t, ip, j, 2)
glink(t, j, o, 1)
m = modifier("Rail", "geometry")
modset("Rail", m, "tree", t)
print(instances("Rail"))               # 12
```

**Procedural generators.** The *Terrain* node makes a heightfield from octaves of noise (smooth
or ridged), *Terrace* steps it, *Erosion* runs water droplets over it that carve gullies and fill
valleys (100k droplets in well under a second). L-systems grow plants:

```
lsystem("Fern", "X", "X=F+[[X]-X]-F[-FX]+X; F=FF", 5, 25, 0.05, 0.03)   # tapering tubes
```

and wave function collapse lays out tiles: `wfc("Town", 12, 12, 1, 7, "Road Corner Grass House")`
fills a 12 x 12 grid with those objects in four turns each, so that what touches matches - which
faces fit is read from the tiles' own vertices, no rules to write.

[tests/procedural.bees](tests/procedural.bees) puts it together: one tree makes an eroded
valley with scattered rocks and L-system plants, a second sweeps a curve into a rail with posts,
a third scatters a million blades of grass (placed in ~15 ms, orbiting at ~11 ms a frame); the
scene is saved and rendered.

**Animation.** Anything a script can set can be keyed. **I** keys the selected objects'
location, rotation and scale at the current frame. **Space** plays the frame range at the scene's
fps, **Left** / **Right** step through it, and the **Timeline** area shows the keys and scrubs when
you drag in it. Keys blend with auto-clamped Bezier curves (never overshooting), linearly or in steps:

```
key("Cube:x", 1, 0)
key("Cube:x", 25, 4)                   # Bezier by default
key("material:Red:roughness", 1, 0.1)
key("node:Valley:3:4", 1, 2)           # a node value: the terrain's height
key("node:Valley:3:4", 50, 8, "linear")
frame(13)                              # the scene at frame 13
```

The **Dope Sheet** shows each curve's keys in a row (drag to retime, Shift+D to copy, X to
delete); the **Graph Editor** shows the curves with their Bezier handles (drag keys and handles).
`anim.action` keeps keys as a reusable clip and `anim.layer` plays clips on top of each other on
any object - replace or add, with an influence and repeats.

**Armatures.** *Create > Armature* makes a skeleton. In armature edit mode (**Tab**) you click
joints, move them with G / R / S and **E**xtrude new bones; in pose mode (**Ctrl+Tab**) you turn
bones and **I** keys them. `arm.parent <mesh> <armature>` skins a mesh with automatic weights
(bone heat diffusion); the Armature modifier deforms it by linear blend or dual quaternion
skinning, and **Ctrl+W** paints weights over a heat map.

**Cloth.** `cloth.add` makes a mesh cloth (or a soft body that keeps its volume), `cloth.pin
above x 0.95` holds an edge, and other objects become colliders. Play past the start and it
hangs, drapes over what is below it, folds onto itself without passing through and blows in
the wind (`cloth.world wind 0 0 8`).

**Mechanisms.** CAD parts can be joined to move: `mech.joint revolute Gear world value angle`
turns a gear by a parameter, `gear 1 -2` makes a second follow, a slider from it is a rack, and
limits hold a joint. Key a parameter (`key("param:angle", 1, 0)`) and the whole assembly moves
over the timeline. Its features rebuild with it, and parts that run into each other are
reported.

**Physics.** `rigid.add` makes the selected objects rigid bodies: boxes, spheres, capsules,
convex hulls, or compounds of convex parts cut from the mesh; static ones can also be any mesh
(a landscape of 100 000 triangles) or an endless plane. They fall, collide, rest and sleep when
you play past the scene's start, and come back when you return to it. Every instance of an
object's geometry nodes can be a body: 10 800 balls poured into a box, 5000 bricks. Towers and
pyramids stand, fast bodies stop at thin walls, collision groups and materials (rubber, ice,
wood, metal, stone) set what meets what and how. Joints (fixed, hinge, point, slider) tie them
together or to the world, with limits, motors and a strength past which they break. The result
is the same bit for bit on any number of threads. The Properties area's **Physics** tab
sets all of it up without typing, in sections that fold: the body (type, shape, material
preset, mass, friction, bounce, damping, start velocity, group; a change goes to every
selected body), its joints (each one's type, pivot, axis, limits, motor and breaking force),
shatter, the world's gravity and steps, cloth and the simulation cache. How the solver works:
[docs/PHYSICS.md](docs/PHYSICS.md); `tools/physbench.py` times it.

**Ground and landscapes.** Add › Ground is an endless floor: a fading grid in the viewport, a
shadow catcher in renders (the shadows over a transparent background, saved as RGBA PNGs), and
a floor for rigid bodies, cloth and the player. Add › Landscape › Flat, Hills, Mountains,
Canyon, Dunes or Island is a heightfield of up to 4097 x 4097 samples built from a stack of
layers - generate (fBm, ridged, billow, Voronoi cells), erode (droplets, thermal), terrace,
sculpted, flatten - that stays editable: a 1025 x 1025 landscape is generated and eroded in
about 0.2 s. Sculpt mode on it has landscape brushes (raise, lower, smooth, flatten, ramp,
noise, erode) and paint layers (rock, grass, sand, snow ...) with an Auto Paint by height and
slope that shows in the viewport and in renders. As a rigid body it is an exact heightfield
collider (its triangles made on the fly under whatever moves: 1000 balls roll down a 4097 x 4097
mountain), each paint layer with its own friction; the island's sea floats what is lighter than
water. Heightmaps come in and go out as 16-bit PNG or EXR, and a landscape splits into tiles
that world partition streams. The **Landscape** tab in Properties edits it all: the layer
stack (values, order, eyes), paint layers with their colours and rules, the sea, the files.
[docs/LANDSCAPE.md](docs/LANDSCAPE.md).

**Workflow.** Nine UI themes (Dark, Light, High contrast, Honey, Graphite, Nord, Solarized
Dark and Light, Dracula) and an accent colour of your own; every colour is a swatch that opens
a picker (square, hue, R G B and H S V numbers, hex, eyedropper, recent and scene colours).
The file dialog has favourites, the mounted drives with their free space, recent folders,
back / forward, the folder's parts as buttons, sortable size and date columns, a filter, hidden
files and image previews. The outliner has folders (Ctrl+G) with their own eye, camera and lock.
Reference images (Add › Reference Image..., or drop a picture on the window) sit behind or in
front of the scene to model over, in every shading mode.

**Shatter.** Object › Physics › Shatter... breaks a mesh into shards (Voronoi cells, evenly or
around a point), bricks (a running bond, with a mortar gap) or balls (packed inside it); its
form draws the cells on the object before anything is cut. Every piece is a closed mesh object
and a convex rigid body of the right mass; a 100 000-triangle vase goes into 500 shards in about
0.1 s. Glue ties touching pieces with joints that break at a strength per area, so a ball
thrown at a glued brick wall knocks out a hole and the rest stands. An object can also wait
whole until something hits it hard enough and break while it plays. Presets (brick wall, glass,
stone, gravel), a Shatter section in Properties › Physics to re-cut with other settings, and
`shatter()` in BeeScript. [docs/SHATTER.md](docs/SHATTER.md).

**Attractors and force fields.** Add › Force Field places an attractor (pulls, or pushes, by
the inverse square), a gravity zone with its own down, gusty wind, a vortex with lift and
inflow, curl-noise turbulence or drag; each has a falloff, a keyframable strength and the
collision groups it acts on. Rigid bodies feel them at their centre of mass, cloth on every
particle (wind as air), and an orbit keeps its radius within 0.1% over ten turns. Bodies can
attract each other (a Barnes-Hut octree: 5445 of them at about 500 steps a second), and in play
mode the player's down follows the pull, so a sphere with an attractor is a planet to walk
round. View › Force Field Arrows and Lines draw the pull; presets Planet, Black Hole, Tornado,
Breeze; `field()` and `force()` in BeeScript. [docs/FIELDS.md](docs/FIELDS.md).

**Simulation cache.** Rigid bodies and cloth keep every frame they reach, so scrubbing back
plays them instead of simulating again; an edit to the setup starts it over. `sim.bake` keeps
the whole frame range (saved with the file) until `sim.free`, and the timeline shows what is
cached.

[tests/animation.bees](tests/animation.bees) puts it together: a character modelled from SDF
shapes is skinned to a 12-bone armature and walks on IK legs, a keyed parameter turns a gear pair,
1000 boxes fall into a heap and a tablecloth drapes over a table. 10 s are baked, the scene is
saved and three frames are rendered; reopened, it plays at ~10 ms a frame.

**Rigging.** Constraints copy, track, limit or parent an object to another
(`constraint.add Cam track_to Target`). An IK constraint on a bone makes its chain reach for a
target and bend towards a pole (`constraint.add Rig:Hand ik Goal chain 2 pole Knee`); drag the
target with G and the arm follows. Drivers set one property from an expression of others
(`anim.driver Door:ry a=Handle:rz a*2`), shape keys store a mesh's poses to blend and key
(`shape.add Smile`), and `anim.motion_paths` and `anim.onion` show motion in the viewport.

**Node groups.** A Group node runs another tree as one node: inside, the Group Input gives the
group node's geometry, value and vector (fields from outside reach in), the Group Output is what
it returns; groups nest. In the node editor, Shift-click several nodes and **Ctrl+G** moves them
into a new group; **Tab** on a group node goes inside, Tab again comes back (`tree.group` does it
from scripts and agents).

**Assets.** `tree.save_asset <tree>` saves a tree with every group it runs, `material.save_asset
<material>` a material with its graph, to `~/BeeModel/assets`; `asset.load <name>` adds one to
any scene.

**Content library.** `lib.save` keeps any kind of asset in `~/BeeModel/library`: `object`
(the selected objects, modifiers applied, with their materials as assets they depend on),
`material`, `tree`, `rig` (an armature with its skinned meshes), `action` and `scene`, with
`#tags`. Assets are stored by content: each blob is named by the hash of its bytes, so the
same content is stored once, whoever saves it. Thumbnails are path-traced in a background
process. The **Asset Browser** area shows the library as tiles; click the header to search
(`lib.search stone`; names, kinds and tags), and the selected asset shows what it uses and what
uses it (`lib.deps`). Drag a tile into a viewport and the asset lands on the surface under the
pointer; a double click places it at the 3D cursor (`lib.place Gate 10 0 0`). `lib.pack
metal.bee metal` writes a pack (a `.bee` file with a manifest, each blob once, thumbnails),
and `lib.import` merges one; `lib.add <folder>` lists another library too. Every operation is an
MCP tool (`op_lib_save`, `op_lib_place`, ...), and BeeScript has `lib(k)`, `libfind(words, i)`
and `libinfo(asset, what)`. See [tests/library.py](tests/library.py).

**Play mode.** F5 plays the scene from the view: a first-person walk (a capsule that falls
under the rigid body world's gravity, climbs steps and walkable slopes, and is stopped by
walls) or, with F, a fly camera. The mouse is captured (a locked pointer with relative
motion); WASD moves, Shift runs, Space jumps. Simulations and animations run live. Esc stops
and asks: K keeps the changes as one undo step, D discards them (as in Unreal's Play In
Editor). `play.start [walk|fly] [x y z]` / `play.stop [keep|discard]` / `play.mode` are MCP
tools too, and BeeScript plays from scripts with `playstep`, `playlook` and `playinfo`. See
[tests/play.py](tests/play.py).

**Logic graphs.** Objects get behaviour from node graphs that run in play mode: events (Begin
Play, On Tick, On Key, On Overlap, On Hit, On Timer, On Message) start chains of actions
(Move, Rotate, Set Property, Spawn, Destroy, Play Action, Apply Impulse, Set Visibility, Send
Message, Set Variable, Branch), fed by data nodes (Variable, Math, Info, Get Property).
`logic.new Door` makes a graph, `logic.node Door overlap` adds nodes, `tree.link` wires them,
`logic.attach Door Door` runs it on an object (a Logic modifier); the node editor shows it,
and the graph is saved in the `.bee` file. The graphs run every fixed step, deterministic and
sandboxed (a node budget a step, objects only by name), and the player rides moving platforms.
BeeScript reads them with `logic(k)` and `logicvar(object, k)`; `playkey` presses keys.
`object.hide` (H) / `object.reveal` (Alt+H) hide objects. See [tests/logic.py](tests/logic.py).

**Light probes and lightmaps.** `probe.add irradiance 0 1 0 9 1 9 7 3 7` places an irradiance
volume (a grid of spherical-harmonic probes over a box), `probe.add reflection 5 1.5 0 2.5 1.5
3` a reflection probe (a cube map, box-projected); `probe.bake` traces them with the path
tracer, and the material preview then takes its light from them: shade under a roof, colour
bleeding from a red wall, the room in a mirror. `lightmap.bake 512 64` gives every mesh a
second UV set, packs them into one atlas and traces the light falling on every texel
(denoised, dilated); `lightmap.save lightmap.exr` (or `.png`). The glTF export is engine-ready:
point lights as `KHR_lights_punctual`, the lightmap embedded and mapped with `TEXCOORD_1`,
`MOZ_lightmap` and `KHR_texture_transform`, emission beyond 1 with
`KHR_materials_emissive_strength`; it passes the Khronos glTF validator. See
[tests/lighting.py](tests/lighting.py).

**Live link.** `link.serve` streams the scene over a socket (TCP on localhost, `lan` for the
network, or `unix:<path>`): a snapshot when a peer connects, then every change as a small
binary message - transforms, vertex deltas, meshes, materials, renames, deletions - well under
a millisecond on localhost. `beemodel --link 127.0.0.1:7461` opens a second BeeModel that
mirrors the first; a game engine plugin reads the same stream ([docs/LIVELINK.md](docs/LIVELINK.md),
reference reader [tools/livelink.py](tools/livelink.py)). Readers that fall behind get their
transforms coalesced. See [tests/livelink.py](tests/livelink.py).

**Versions.** A saved scene keeps its history beside it (`<file>.vc/`, content-addressed:
unchanged meshes cost nothing). `vc.commit "a message"`, `vc.branch idea`, `vc.switch idea`,
`vc.log`; `vc.diff main` lists what differs - objects added, removed, changed and which
properties - and draws the other version as ghosts over the scene (`side`: beside it).
`vc.merge idea` merges three-way per object and property; the same property changed on both
sides shows in the merge panel (ours / theirs), then `vc.commit`. Agents use the same operators
over MCP to work on a branch of their own and propose it. See [tests/versions.py](tests/versions.py).

**Co-editing.** `co.host` starts a live session, `co.join host:port` joins it from another
BeeModel - peer to peer, no server. Everyone edits at once: objects, transforms, materials,
meshes (moves of different vertices merge), node graphs; a CRDT settles every conflict the same
way everywhere. Ctrl+Z undoes only your own edits. You see the others' cameras, cursors and
selections in their colours, and `co.follow` keeps your view on someone's. An AI agent joins
as a peer of its own (`co.agent on`: what MCP tools change is the agent's, with its own undo).
See [tests/coedit.py](tests/coedit.py).

### Virtualized geometry

**Cluster LOD DAG.** `vgeo.build` prepares the active mesh for virtualized rendering, as Nanite
does. It splits the mesh into clusters of up to 128 triangles, then repeatedly groups
neighbouring clusters, simplifies each group to half its triangles with the group's border
held, and splits the result into new clusters, until one cluster is left. Every cluster keeps
its bounds and an error that only grows towards the root. Picking clusters by "error <= t <
parent error" (projected from the camera or not) gives a crack-free mesh at any detail. The DAG
builds in the background (about 120 ms per million triangles on 32 threads) and is saved with
the file. `vgeo.extract 3` (a level) or `vgeo.extract 0.01` (an error) adds a cut as a mesh
with its clusters coloured.

**Drawing a billion triangles.** A mesh with a DAG is drawn through a fresh cut every frame,
at one pixel of error from the camera (`vgeo.error 0.5` for finer cuts). Clusters outside the
view are dropped, and so are clusters hidden behind last frame's depth; the ones that came into
view are drawn in a second pass, so moving the camera never opens holes. `vgeo.proxy` lets the
full mesh go: a few thousand triangles (the DAG's roots) stand in for it in the file, the
exporters and the path tracer, while the viewport keeps drawing every detail. A DAG read from a
`.bee` file stays mapped from it: cluster pages are read in as the view needs them and the
least recently used ones are given back past the budget (`vgeo.budget 2048`, in MB). Until a
page arrives, coarser clusters stand in, still without cracks. `vgeo.view clusters` colours the
clusters. A landscape of 64 unique million-triangle tiles strewn with 960 linked copies of
million-triangle boulders (1.05 billion source triangles) flies at about 6 ms a frame on 32
threads, and the process never holds more than 900 MB
([tests/billion.py](tests/billion.py)).

### World partition

`world.partition 50` splits a saved scene into 50 m cells on the ground; each cell's plain mesh
objects (no modifiers, rig, curve or shape keys) go to their own file beside the scene
(`world.cells/<x>_<z>.cell`, cluster DAGs included). Cells within the loading radius of the camera
(`world.radius`) stream in, nearest first; cells far behind go out, and when the loaded cells' meshes
pass the budget (`world.budget`, in MB) the farthest go too. A cell that changed is written before
it goes, and an object moved into a cell that is not loaded pulls that cell in, so objects cross
borders freely. Unloaded cells show as boxes, and a minimap in the viewport's corner shows every
cell (loaded, changed, on disk), the camera and its radius (`world.minimap`). Streaming starts the
undo history afresh. A 32 x 32 map of 4096 objects is made, edited and flown over under an 8 MB
budget in [tests/world.py](tests/world.py).

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
src/jobui.s     long jobs: the status bar's chip, frames while they run
src/mem.s       arenas and generational-handle pools
src/log.s       string builder + console log
src/selftest.s  --selftest unit tests + benchmark
src/scene.s     objects, selection, transforms, object operators
src/undo.s      undo / redo snapshots
src/redo.s      adjust-last-operation panel
src/parent.s    parenting: children follow their parent, the outliner's tree
src/folder.s    the outliner's folders: the block, FOLD chunks, their operators
src/orient.s    pivot point and transform orientation, 3x3 rotation helpers
src/viewanim.s  view transitions, Frame Selected, Reduce motion
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
src/hive_pt.s   Hive light transport: NEE + MIS, principled BSDF, passes, light shapes
src/lshape.s    the viewport's light shapes (radius, cone, sun, area)
src/gpu.s       the optional GPU helper from this side: start, shared memory, fallback
src/live.s      Rendered shading: the live viewport on the GPU (raycast, then samples)
src/gpu/        beemodel-gpu: helper.s (Vulkan), pt.comp / raster.comp, spv.s (SPIR-V)
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
src/blend.s     Blender files: the .blend reader (SDNA, blocks, meshes, materials)
src/blendx.s    saving .blend files through Blender
src/expr.s      expressions with units
src/cad.s       the CAD document: units, parameters, the feature records
src/sketch.s    sketches and the constraint solver
src/sketchobj.s sketch objects, display, rebuild
src/sketchui.s  sketch mode
src/prof.s      profiles from sketches: loops, caps, prisms, revolutions
src/feature.s   the feature tree and its rebuild
src/nurbs.s     B-rep kernel: NURBS / analytic curves and surfaces, knots, degrees
src/brep.s      B-rep topology, pcurves, orientation, exact volume and area
src/bbuild.s    B-rep solids from sketches: exact profiles, prisms, revolutions
src/bssi.s      surface-surface intersection (closed forms, traced curves)
src/bbool.s     B-rep booleans: sections, face division, classification
src/bfillet.s   B-rep fillets and chamfers on straight edges between planes
src/btess.s     watertight tessellation, inside / outside by ray parity
src/bfeat.s     the feature tree replayed in the kernel (cad.kernel on)
src/nbcheck.s   NURBS self-checks (nurbscheck)
src/bdebug.s    kernel debugging dumps (BEEMODEL_BREP_KEEP)
src/step.s      STEP export: AP214 B-rep solids, assemblies, colours, units
src/stepread.s  STEP import: the Part 21 parser, solids, assemblies
src/measure.s   mass properties, the measure tool
src/sdf.s       signed-distance shapes, marching tetrahedra
src/fab.s       3MF export, DXF / SVG of sketches
src/drawing.s   PDF drawings: views, hidden lines, dimensions
src/print.s     printability: wall thickness, print check
src/printui.s   Print Check's findings panel (Show: select and frame)
src/thumb.s     scene pictures in .bee files for the file browser
src/ctxui.s     right-click menus on fields
src/sculpt.s    sculpt mode: leaf BVH, brushes, delta undo, splat drawing
src/dyntopo.s   dynamic topology: edge split / collapse under the brush
src/multires.s  multiresolution: per-level displacements, level sculpting
src/uv.s        UV maps: seams, LSCM unwrap (CG solver), smart projection, packing
src/uved.s      the UV editor area: islands, transforms, heat map, texel density
src/nodeed.s    the node editor area: shader graphs and node trees drawn and edited
src/ntree.s     node trees: the block, nodes, links, files
src/geonodes.s  geometry nodes: evaluation, field compiler, tree.* operators
src/fieldvm.s   the field VM: per-point programs in SSE blocks
src/fvjit.s     the field JIT: templates to x86-64 (AVX / SSE), differential self-test
src/asset.s     assets: trees and materials saved, loaded (.beea files, library blobs)
src/library.s   the content library: blobs by hash, kinds, thumbnails, packs, the Asset Browser
src/play.s      play mode: the capsule walker, fly camera, captured mouse, keep / discard
src/logic.s     logic graphs: event / action / data nodes, the play-mode VM
src/probe.s     light probes: SH irradiance volumes, reflection cube maps, baked by Hive
src/lightmap.s  the lightmap baker: second UVs, the atlas, traced texels, EXR / PNG
src/link.s      the live link: the scene streamed to peers, mirroring a session
src/vc.s        versioned scenes: commits, branches, the visual diff, three-way merge
src/cosync.s    live co-editing: the CRDT, peers, per-author undo, presence
src/cotree.s    co-editing node graphs: trees as sets, nodes as sequences
src/inst.s      instances: the block, realizing, the viewport's instance pass
src/curve.s     curves: splines, sweeps, curve edit mode, the curve nodes
src/procgen.s   terrain, erosion, L-systems, wave function collapse
src/paint.s     texture painting: projected dabs, UV-space dabs, stroke history
src/layers.s    paint layers: stack, blend modes, composite, saving
src/vcol.s      vertex colours: vertex paint, tinting, files
src/bake.s      baking normal / AO / curvature maps, high to low
src/json.s      lazy JSON reader + writer
src/fileio.s    paths, files, the write buffer
src/mcp.s       MCP server (unix socket, JSON-RPC) and the --mcp-bridge relay
src/copilot.s   the procedural co-pilot: node catalogue, graphs as JSON, proposals
src/ai.s        the AI Assistant: Claude Code / Grok / OpenRouter connections, transcript, area
src/aiproc.s    a child process for the AI connections (pipes, stop), HTTPS through curl
src/anim.s      animation: keyframes, F-curves, playback, actions and layers, the Timeline
src/animed.s    the Dope Sheet and the Graph Editor
src/arm.s       armatures: bones, poses, skinning (LBS / DQS), automatic weights, modes
src/rig.s       constraints, IK (FABRIK / CCD), drivers, motion paths, onion skins
src/shape.s     shape keys
src/clip.s      contact points between polytopes: faces clipped
src/collide.s   convex collision: support functions, GJK, EPA
src/mech.s      mechanisms: revolute / slider joints, gears, limits, collisions
src/cloth.s     cloth and soft bodies: XPBD, pins, colliders, self collision, wind
src/rbody.s     rigid bodies: broad phase, contact manifolds, the solver, islands, joints,
                heightfields, water
src/ground.s    the Ground: an endless floor, a shadow catcher
src/landscape.s landscapes: the heightfield block, its layers, presets, the display mesh
src/lsculpt.s   sculpting and painting landscapes: brushes, paint layers, Auto Paint
src/landio.s    landscapes in and out: PNG / EXR heightmaps, to a mesh, tiles
src/shatter.s   shatter: closed meshes cut into convex cells (clipping, caps, a tree of cells)
src/shatterop.s shatter: the operator, its patterns, pieces, bodies, glue, the form's preview
src/fields.s    force fields: the objects, their settings, the pull at a point, gizmos, overlay
src/fieldui.s   the Force Field section of Properties › Physics
src/nbody.s     bodies that attract each other: a Barnes-Hut octree of masses
src/physui.s    the Physics tab: rigid body, joints, shatter, world (sections of widgets)
src/landui.s    the Landscape tab: size, the layer stack, paint layers, sea and files
src/refimg.s    reference images: adding them, drawing them in screen space, their panel
src/simcache.s  the simulation cache: frames kept, played back, baked, saved
src/vgeo.s      virtualized geometry: the cluster LOD DAG (meshlets, groups, simplification)
src/vgdraw.s    virtualized geometry: per-frame cuts, frustum and occlusion culling, streaming
src/world.s     world partition: grid cells saved apart, streamed by camera distance, the minimap
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
the built-in allocator, job-system and field-JIT tests and small benchmarks.

Each `.s` file is a separate module linked by `ld`. See
[docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) for the calling convention, the
operator spine and how to add an action.

## Dev tools (optional, Python; not needed to build or run)

* `tools/genfont.py` regenerates `src/font.inc` from a PSF console font.
* `tools/genkeysyms.py` regenerates `src/keysyms.inc` (keysym names → Unicode).
* `tools/genspv.py` compiles the GPU helper's shaders (`src/gpu/*.comp`, with
  `glslc`) into `src/gpu/spv.s`.
* `tools/genmatnodes.py` regenerates the material node catalogue in
  `src/matnodes.s` (names, kinds, choices, defaults) from its node list.
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
  libraries, no RWX segments, size budget of 1.5 MiB) and runs the headless UI test.
  Screenshots are uploaded as a workflow artifact.
* **Releasing:** bump `VERSION`, move the `[Unreleased]` notes in `CHANGELOG.md`
  into a new version section, and merge via a PR. Then tag:
  `git tag -a v0.2.0 -m "BeeModel 0.2.0" && git push origin v0.2.0`.
  The release workflow checks that the tag matches `VERSION`, builds, tests and
  packages the app (`scripts/package.sh`), and publishes a GitHub release with notes
  taken from the changelog.

## License

BeeModel is released under the [MIT License](LICENSE).
