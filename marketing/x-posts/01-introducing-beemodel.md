# Introducing BeeModel

The first post on the account: introduce BeeModel itself, with v0.24 as the
reason to post now. Attach `../media/beemodel-dam-break.mp4`.

## Single post

```
Meet BeeModel 🐝: a full 3D modeller written entirely in x86-64 assembly.

No libc, no toolkit, a single 1.5 MB binary. Modeling, sculpting, CAD, animation, physics, liquids and a path tracer.

v0.24 moves the viewport to the GPU. Free for Linux:

https://beemodel.hideterms.com
```

## Thread

Post 1 is the single post above. Then:

**2/**

```
It talks to the Linux kernel through raw syscalls and to Wayland straight over its socket. It uses 0% CPU when idle, a few MB of memory, and starts instantly.

It still has the layout you'd expect: Blender-style areas, edit mode, G/R/S, undo for everything.
```

**3/**

```
What's inside:
🧊 polygon modeling, sculpt & paint
📐 parametric CAD
🎬 animation & rigging
💥 rigid bodies, particles & liquids
🏔️ landscapes
✨ node materials & a path tracer
🤖 a built-in AI assistant and an MCP server
```

**4/**

```
New in v0.24: the viewport runs on Vulkan, and liquids are solved and drawn on the GPU.

The dam-break demo used to play at 4 fps at 1440p. It now plays at 130.
```

**5/**

```
MIT licensed. Download it, read the source, or break it:

https://github.com/bartbeecoders/beemodel

#assembly #3D #gamedev #opensource #linux
```
