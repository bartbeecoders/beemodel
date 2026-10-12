# Changelog

All notable changes to BeeModel are documented here.
The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the
project uses [Semantic Versioning](https://semver.org/).

## [Unreleased]

### Added
- MCP server for AI agents. The running app listens on
  `$XDG_RUNTIME_DIR/beemodel.sock`, and `beemodel --mcp-bridge` connects
  Claude Code / Claude Desktop over stdio. Tools: `scene_summary`,
  `create_primitive`, `set_transform`, `select`, `delete`, `run_operator`,
  `undo`, `redo`, plus every agent-safe operator as `op_<id>`. Resource:
  `bee://scene`. Agent edits are undoable and echoed in the console.
- `viewport_capture` MCP tool. The UI is rendered off-screen, so the image
  shows the scene right after the agent's last edit. The tool returns an MCP
  image block holding the viewport (or the whole window) as a PNG.
- Own JSON reader / writer.

### Changed
- PNG files are now compressed. The encoder picks a Sub or Up filter per row
  and then deflates the data (LZ77 plus fixed Huffman codes). A 1280×800
  screenshot drops from about 3 MB to about 150 KB.

## [0.3.0] - 2026-10-12

Phase 2 of the masterplan, "Scene, viewport & files": BeeModel becomes a
small but real 3D editor.

### Added
- Scene with real objects: a Blender-like default scene (Camera, Light,
  Cube); objects have a name, location, rotation, scale and a mesh.
- Polygon meshes with n-gons, derived edges and triangles; primitives: cube,
  plane, grid, UV sphere, cylinder, cone, torus.
- Selection: click in the viewport or the outliner (Shift extends), A to
  select all / none; X / Delete removes, Shift+D duplicates (unique names
  like Cube.001).
- The outliner lists the scene's objects and scrolls; Properties shows the
  active object's transform and mesh statistics.
- Solid shading: a multithreaded tile rasterizer (parallel setup, binning
  and rasterization, SSE 4-pixel edge functions, depth and object-ID
  buffers) with Blender-style selection outlines. About 1.2 M triangles
  render in 8–9 ms at 1280×800 on 32 threads, with output identical for any
  thread count. Z toggles wireframe.
- Exact click picking from the ID buffer.
- Modal transforms like Blender's: G / R / S with X/Y/Z constraints, Ctrl
  snapping (1 m, 15°, 0.1), typed values, Enter / LMB to confirm and Esc /
  RMB to cancel. Move / Rotate / Scale tool gizmos can be dragged.
- Undo / redo (Ctrl+Z / Ctrl+Shift+Z) for create, delete, duplicate and
  transforms. Snapshots share reference-counted meshes; the history is
  bounded (256 steps / 64 MiB). Edit › Undo History lists the steps.
- Files: native `.bee` save / open (chunked, atomic writes, validated on
  load), OBJ import / export, STL import (binary + ASCII, welded) / export,
  PNG screenshots (F12), autosave every 25 changes, `file.recover`. The
  title bar shows the current file.
- Operators accept a text argument from the command line
  (`file.save ~/x.bee`); without one, the command line opens pre-filled.
- Shift+D shares the mesh with the original (copy-on-write arrives with
  edit mode), so duplicates cost almost no memory.
### Fixed
- Keymap parser: the word "aliases" inside the keycodes section name was
  taken for an `alias` statement, which swallowed the Escape and **1** keys
  (& on AZERTY). Digits now all type correctly.

### Changed
- G, R and S now start transforms (Blender layout). The grid toggle moved to
  Shift+G, and the tools to Shift+Q / W / E / R.
- Binary size budget raised from 64 KiB to 256 KiB (now ~67 KB); the
  masterplan target remains < 2 MB for v1.0.
- Arenas keep memory that is in use resident instead of releasing it every
  frame (released after sustained low use).

## [0.2.0] - 2026-10-12

Phase 1 of the masterplan, "Foundations": the runtime every modeling feature
will build on.

### Added
- Operator spine: every action is declared once with the `OPERATOR` macro and
  collected by the linker into one table. Menus, tool buttons, check marks,
  shortcut labels and the keymap are all driven by it.
- `--list-ops` prints every operator (id, key binding, label, description).
- New key bindings: T (tools pane), N (outliner pane), F1 (shortcut list in the
  console), Ctrl+N/O/S/Z, Ctrl+Shift+Z.
- docs/ARCHITECTURE.md: modules, calling convention, how to add an operator.
- Real keyboard support without libxkbcommon: the XKB keymap sent by the
  compositor is parsed in assembly. Shift / Caps Lock / AltGr levels and dead
  keys (accents) work for any layout.
- Layout-aware shortcuts: bindings follow the key label, so Ctrl+Z is Undo on
  AZERTY and QWERTZ keyboards too.
- Key repeat using the compositor's rate and delay (timerfd).
- Console command line: a UTF-8 text field with caret, selection (Shift,
  Ctrl+A), history (Up/Down) and Tab completion of operator ids. Enter runs any
  operator by id.
- New operators: console.focus (Enter), console.clear (Ctrl+L),
  console.list_ops.
- TrueType text, with no FreeType: our own TrueType parser (cmap 4/12,
  composite glyphs), an anti-aliased signed-area rasterizer, a glyph cache and
  alpha blending. The UI uses a proportional sans font and the console a
  monospace font, both loaded from the system (Noto / DejaVu / Liberation).
- Full Unicode text (UTF-8): accented and international characters display
  correctly. `BEEMODEL_FONT` / `BEEMODEL_MONO_FONT` select fonts; `none`
  keeps the bitmap font.
- HiDPI / fractional scaling (`wp_fractional_scale_v1` + `wp_viewporter`):
  the UI renders natively at 125%, 150%, 200% and other scales, with crisp
  text and geometry instead of compositor upscaling.
- Job system: worker threads on every core (raw `clone` + `futex`, 0% CPU
  when idle) and `parallel_for` with atomic chunk claiming; the viewport
  background is already filled in parallel. `BEEMODEL_THREADS` limits the
  thread count.
- Memory: bump arenas (per frame and per thread, giving memory back to the
  kernel after spikes) and pools with generational handles.
- `--selftest`: built-in tests for the allocators and the job system, plus a
  benchmark (12× faster with 32 threads on the reference machine). Runs in
  CI.
- Area system like Blender's: the window is a tree of resizable areas. Each
  area has a header to switch its editor (3D Viewport, Tools, Outliner,
  Properties, Console) and to maximize (Ctrl+Space), split side by side or
  top/bottom, or close it. Each viewport has its own camera.
- Command palette (F3): fuzzy search over every command, showing its id and
  shortcut. Up/Down select, Enter runs.

### Changed
- Tools / Outliner / Console toggles (T, N, View menu) now add and remove
  areas; the Properties pane is now its own area.

### Testing
- Golden-image regression tests (pixel diff against `tests/golden`).
- Performance and memory budgets checked in CI: first frame in about 4 ms,
  median input-to-frame latency about 0.6 ms at 1280×800, about 2.3 MiB of
  private memory.

### Changed
- Source split into separate modules (object files) with explicit exports.
- Help › Keyboard Shortcuts is generated from the operator table.
- Redo is now Ctrl+Shift+Z.

## [0.1.0] - 2026-10-12

First release: the application shell that the 3D modeling tool will be built on.

### Added
- Native Wayland client in pure x86-64 assembly with no libraries: raw syscalls and
  a hand-written wire protocol (`wl_compositor`, `wl_shm`, `xdg_wm_base`, `wl_seat`,
  `wp_cursor_shape_v1`).
- Title bar drawn by the app: move by dragging, double-click to maximize,
  minimize/maximize/close buttons, edge resizing for floating windows.
- Menu system with File, Edit, View, Create and Help dropdowns, hover switching,
  check marks and shortcut hints.
- Resizable Tools, Outliner/Properties and Console panes with draggable splitters;
  each pane can be shown or hidden from the View menu.
- 3D viewport canvas: orbit/pan/zoom camera, perspective projection with near-plane
  and Liang–Barsky clipping, ground grid, axes, orientation gizmo and a demo cube.
- Status bar, console log, keyboard shortcuts (Q/W/E/R, G, F, Esc, Ctrl+Q).
- `--version` and `--help` command-line flags.
- Event-driven rendering paced by frame callbacks: 0% CPU when idle, double-buffered
  shared-memory framebuffer, about 60 KB of private memory.
- `build.sh`, `run.sh` and `package.sh` scripts.
- Headless test harness (fake Wayland compositor) and GitHub Actions CI and release
  pipelines.

[Unreleased]: https://github.com/bartbeecoders/beemodel/compare/v0.3.0...HEAD
[0.3.0]: https://github.com/bartbeecoders/beemodel/compare/v0.2.0...v0.3.0
[0.2.0]: https://github.com/bartbeecoders/beemodel/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/bartbeecoders/beemodel/releases/tag/v0.1.0
