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
| `wayland.s` | Socket, message encoding/decoding, `SCM_RIGHTS`, shm buffers, event dispatch, frame pacing |
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
| `mesh.s` | Polygon meshes (loops, n-gons), edge/triangle derivation, primitive generators |
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

The viewport draws each object's edges through its matrix (unselected first,
then the selection in orange and the active object in gold). A click in a
viewport (press and release without moving more than 3 px) picks the object
with the smallest projected bounds under the pointer. Dragging still
orbits.

## Event loop & rendering

`main.s` loops over: flush outgoing requests, `poll` the Wayland socket and the
key-repeat `timerfd`, dispatch whatever is ready, and render if something
changed. `render` draws into whichever of the
two shm buffers is free, then attaches, damages, requests a frame callback and
commits. It does not draw again until the frame callback arrives, so rendering
never outpaces the display, and CPU use is 0% while idle.

## Testing

`tools/fakewl.py` is a fake Wayland compositor. It starts the real binary,
injects pointer and keyboard input, checks pixels, cursor shapes and the exit
code, and saves screenshots. CI runs it on every PR, together with
`ci/check-binary.sh` (static binary, no shared libraries, no RWX segments, size
budget, operator table sanity).
