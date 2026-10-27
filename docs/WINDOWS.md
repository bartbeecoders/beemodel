# BeeModel on Windows

From 1.2.0 every release has a Windows build next to the Linux one:
`beemodel-<version>-windows-x86_64.zip` on the
[releases page](https://github.com/bartbeecoders/beemodel/releases). It is the
same program from the same source files. Only the platform layer differs
(`src/plat_win.s` and `src/plat_win_wnd.s` in place of `src/plat_linux.s` and
the Wayland client), so `.bee` files, BeeScript, the MCP tools and the live
link work the same on both systems. A headless render on Windows gives the
same image as on Linux, byte for byte.

## Install and run

1. Download the zip and unpack it anywhere (no installer, no admin rights).
2. Start `beemodel.exe`.

The folder holds:

| File | What |
|---|---|
| `beemodel.exe` | the program (about 1.6 MB) |
| `beemodel-gpu.exe` | the optional GPU helper; keep it next to `beemodel.exe` |
| `README.md`, `CHANGELOG.md`, `LICENSE`, `mcp-tools.json`, `WINDOWS.md` | the docs |

It needs Windows 11 on x86-64 (Windows 10 may work but is not tested; ARM64
Windows is out: the code is x86-64 assembly). It links only Windows' own
DLLs (`kernel32`, `user32`, `gdi32`, `ws2_32`) and no C runtime.

**SmartScreen.** The executables are not code-signed yet, so the first start
of a downloaded copy may show *"Windows protected your PC"*: choose
**More info › Run anyway**. `SHA256SUMS` on the release page has the zip's
checksum (`Get-FileHash beemodel-*-windows-x86_64.zip` in PowerShell).

Started from Explorer, the program has no console window. Started from a
terminal it keeps the terminal, so `--help`, `--version`, `--eval` and
`--run` print there as on Linux:

```
beemodel.exe --version
beemodel.exe --run script.bees
beemodel.exe scene.bee
```

## Where things are kept

The same layout as on Linux, in your user folder (`%USERPROFILE%`):
`~/BeeModel` (scenes, the library), `~/.config/beemodel` (preferences) and
`~/.cache/beemodel`. Set `BEEMODEL_HOME` to another folder for a portable
copy (on a USB stick, say). In BeeScript, write paths with `/`
(`C:/Users/me/x.bee`): a `\` in a string starts an escape, as on Linux.

## Optional tools

As on Linux, some features run another program and say so when it is missing.
Put these on `Path`:

| Feature | Program |
|---|---|
| AI Assistant (OpenRouter), Preferences' key test | `curl.exe` (part of Windows) |
| AI Assistant (Claude Code) | `claude.exe` |
| AI Assistant (Ollama) | Ollama, running |
| `.blend` import of compressed files (Blender 3+) | `zstd.exe` |
| Render Animation to video (.mp4, .webm, .gif) | `ffmpeg.exe` |
| Reference images from PDFs | `pdftoppm.exe` and `pdftotext.exe` (poppler) |

## GPU

`beemodel-gpu.exe` loads `vulkan-1.dll`, which the NVIDIA, AMD and Intel
drivers install. Without it (or with `BEEMODEL_GPU=off`) the renders run on
the CPU, as on Linux. See [GPU.md](GPU.md).

## AI agents (MCP)

`beemodel.exe --mcp-bridge` is the MCP server for Claude Code and other
agents, as on Linux ([MCP.md](MCP.md)); it reaches the running BeeModel over
an `AF_UNIX` socket (Windows 10 1803 and later have them).

## Not on Windows

The Omarchy integration (`omarchy-plugin/`). Pen pressure, mixed-DPI monitors
and the clipboard with other programs were checked by hand, not by CI.

## How it is tested

CI builds `beemodel.exe` on Linux (GNU `ld` links the same objects into a PE
file) and checks it under Wine (`ci/check-exe.sh`). Every release then runs
`ci/check-windows.ps1` on GitHub's Windows runner against the zip it
publishes: the version, `--selftest`, the platform layer's tests
(`tests/win/`) and a render, a save and a reload that must give the Linux
build's image. The port's steps are in
`Vibecoding/BeeModel-Win11-Port-Plan.html`.
