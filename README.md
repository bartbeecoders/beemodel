# BeeModel

[![CI](https://github.com/bartbeecoders/beemodel/actions/workflows/ci.yml/badge.svg)](https://github.com/bartbeecoders/beemodel/actions/workflows/ci.yml)
[![Release](https://img.shields.io/github/v/release/bartbeecoders/beemodel)](https://github.com/bartbeecoders/beemodel/releases)

A shell for a 3D modeling tool, written entirely in x86-64 assembly (GNU as,
Intel syntax). It uses no libc, no libwayland and no toolkit. The program talks to
the Linux kernel through raw syscalls and to the compositor through the Wayland
wire protocol on a UNIX socket.

```
./build.sh          # assemble + link  -> build/beemodel  (~210 KB static ELF)
./build.sh debug    # same, with symbols (for gdb)
./run.sh            # rebuilds if sources changed, then starts the app
```

Requirements: `as` + `ld` (binutils) and a Wayland compositor (Hyprland, sway, GNOME, KDE...).

### Download a release

Prebuilt static binaries are attached to each [GitHub release](https://github.com/bartbeecoders/beemodel/releases):

```
curl -LO https://github.com/bartbeecoders/beemodel/releases/download/v0.5.0/beemodel-0.5.0-linux-x86_64.bin
chmod +x beemodel-0.5.0-linux-x86_64.bin && ./beemodel-0.5.0-linux-x86_64.bin
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

The solid viewport shows the base colour. Materials are saved in `.bee` files and exported as MTL next to an OBJ. Scripts use
`material`, `matset`, `matget`, `assign` and `matof`; agents see them in `scene_summary` and use
the `material.*` operators.

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
handle **OBJ** and **STL**. Commands take paths on the command line, for
example `file.save ~/BeeModel/chair.bee` or `file.import_stl ~/part.stl`.
Without a path, the command line opens pre-filled. **F12** saves a PNG
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
src/main.s      entry point, CLI flags, event loop
src/wayland.s   socket, message encode/decode, SCM_RIGHTS, shm buffers, dispatch
src/draw.s      framebuffer primitives: rects, gradient, text, lines, clipping
src/ui.s        layout, hit testing, input, menus, panes, status bar
src/ops.s       operator spine: operator table, runner, keymap, --list-ops
src/viewport.s  camera, projection, clipping, grid/axes/gizmo (+ its operators)
src/keyboard.s  XKB keymap parser, levels, dead keys, layout-aware shortcuts, key repeat
src/textfield.s UTF-8 text field (console command line)
src/ttf.s       TrueType parser, anti-aliased rasterizer, glyph cache
src/text.s      font selection, UTF-8 text drawing and measurement
src/jobs.s      worker threads, futex, parallel_for
src/mem.s       arenas and generational-handle pools
src/selftest.s  --selftest unit tests + benchmark
src/areas.s     area tree, editors, splitting / closing / maximizing
src/palette.s   F3 command palette (fuzzy operator search)
src/scene.s     objects, selection, transforms, object operators
src/mesh.s      polygon meshes and primitive generators
src/json.s      lazy JSON reader + writer
src/mcp.s       MCP server (unix socket, JSON-RPC) and the --mcp-bridge relay
src/png.s       PNG encoder (row filters, LZ77 + Huffman deflate)
src/script.s    BeeScript: lexer, one-pass compiler, stack VM, builtins, macros
src/log.s       string builder + console log
src/font.s      embedded font (data in src/font.inc, see tools/genfont.py)
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
