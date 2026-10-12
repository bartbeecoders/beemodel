# BeeModel

[![CI](https://github.com/bartbeecoders/beemodel/actions/workflows/ci.yml/badge.svg)](https://github.com/bartbeecoders/beemodel/actions/workflows/ci.yml)
[![Release](https://img.shields.io/github/v/release/bartbeecoders/beemodel)](https://github.com/bartbeecoders/beemodel/releases)

A shell for a 3D modeling tool, written entirely in x86-64 assembly (GNU as,
Intel syntax). It uses no libc, no libwayland and no toolkit. The program talks to
the Linux kernel through raw syscalls and to the compositor through the Wayland
wire protocol on a UNIX socket.

```
./build.sh          # assemble + link  -> build/beemodel  (~25 KB static ELF)
./build.sh debug    # same, with symbols (for gdb)
./run.sh            # rebuilds if sources changed, then starts the app
```

Requirements: `as` + `ld` (binutils) and a Wayland compositor (Hyprland, sway, GNOME, KDE...).

### Download a release

Prebuilt static binaries are attached to each [GitHub release](https://github.com/bartbeecoders/beemodel/releases):

```
curl -LO https://github.com/bartbeecoders/beemodel/releases/download/v0.1.0/beemodel-0.1.0-linux-x86_64.bin
chmod +x beemodel-0.1.0-linux-x86_64.bin && ./beemodel-0.1.0-linux-x86_64.bin
```

## What's in the shell

| Area | Details |
|------|---------|
| Title bar | Client-side decoration: logo, title, minimize / maximize-restore / close. Drag to move; double-click to maximize. Edges resize floating windows. |
| Menu bar | File, Edit, View, Create, Help dropdowns. Hover switches between open menus, check marks show toggles, shortcuts are listed, Esc closes. |
| Panes | Tools (left), Outliner + Properties (right), Console (bottom). Drag the splitters to resize; View menu shows/hides each pane. |
| Canvas | Software 3D viewport: perspective orbit camera, ground grid, XYZ axes, demo wireframe cube, orientation gizmo. LMB orbit, MMB or Shift+LMB pan, wheel zoom, F reset, G grid. |
| Status bar | Last command, framebuffer size, window size. |

Keys: Q/W/E/R tools, T tools pane, N outliner pane, G grid, F reset camera,
F1 list all shortcuts, Esc close menu, Ctrl+Q quit. Run `beemodel --list-ops` to
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
src/log.s       string builder + console log
src/font.s      embedded font (data in src/font.inc, see tools/genfont.py)
src/const.inc   syscalls, opcodes, layout metrics, theme colours
src/macros.inc  operator record layout + OPERATOR macro
```

Each `.s` file is a separate module linked by `ld`. See
[docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) for the calling convention, the
operator spine and how to add an action.

## Dev tools (optional, Python; not needed to build or run)

* `tools/genfont.py` regenerates `src/font.inc` from a PSF console font.
* `tools/fakewl.py` is a headless fake Wayland compositor. It runs the app,
  injects pointer and keyboard input, and saves PNG screenshots of each step to
  `build/shots/` (needs Pillow). It tests the app in isolation, without touching
  your desktop.

## Development workflow

* `main` is always releasable. All work happens on a branch (`feat/…`, `fix/…`,
  `ci/…`) and is merged through a pull request once CI is green.
* CI (`.github/workflows/ci.yml`) runs on every PR and push to `main`. It builds
  release and debug binaries, runs `ci/check-binary.sh` (static, no shared
  libraries, no RWX segments, size budget of 64 KiB) and runs the headless UI test.
  Screenshots are uploaded as a workflow artifact.
* **Releasing:** bump `VERSION`, move the `[Unreleased]` notes in `CHANGELOG.md`
  into a new version section, and merge via a PR. Then tag:
  `git tag -a v0.2.0 -m "BeeModel 0.2.0" && git push origin v0.2.0`.
  The release workflow checks that the tag matches `VERSION`, builds, tests and
  packages the app (`./package.sh`), and publishes a GitHub release with notes
  taken from the changelog.
