# Changelog

All notable changes to BeeModel are documented here.
The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the
project uses [Semantic Versioning](https://semver.org/).

## [Unreleased]

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
