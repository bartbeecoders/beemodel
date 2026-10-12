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

## Event loop & rendering

`main.s` loops over: flush outgoing requests, block in `recvmsg`, dispatch the
events, and render if something changed. `render` draws into whichever of the
two shm buffers is free, then attaches, damages, requests a frame callback and
commits. It does not draw again until the frame callback arrives, so rendering
never outpaces the display, and CPU use is 0% while idle.

## Testing

`tools/fakewl.py` is a fake Wayland compositor. It starts the real binary,
injects pointer and keyboard input, checks pixels, cursor shapes and the exit
code, and saves screenshots. CI runs it on every PR, together with
`ci/check-binary.sh` (static binary, no shared libraries, no RWX segments, size
budget, operator table sanity).
