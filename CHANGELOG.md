# Changelog

All notable changes to BeeModel are documented here.
The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the
project uses [Semantic Versioning](https://semver.org/).

## [Unreleased]

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

[Unreleased]: https://github.com/bartbeecoders/beemodel/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/bartbeecoders/beemodel/releases/tag/v0.1.0
