# The live link protocol (version 1)

BeeModel streams its scene over a socket so another BeeModel can mirror it
and a game engine can show it as it is being made. This is everything a
reader needs; [tools/livelink.py](../tools/livelink.py) is a complete
reference reader in Python (about 150 lines) and
[tests/livelink.py](../tests/livelink.py) checks both ends.

## Connecting

The editor serves with `link.serve`:

| Command | Listens on |
|---|---|
| `link.serve` | TCP `127.0.0.1:7461` |
| `link.serve 9000` | TCP `127.0.0.1:9000` |
| `link.serve lan 9000` | TCP port 9000 on every interface (the LAN) |
| `link.serve unix:/run/user/1000/bee.sock` | a UNIX socket |

`link.stop` ends it. Another BeeModel mirrors a session with
`beemodel --link 127.0.0.1:9000` (or `link.connect` from a running one;
`link.disconnect` stops). Addresses are IPv4 numbers or `localhost`.

A reader connects and sends HELLO; the editor answers with its HELLO, a
snapshot of the whole scene, then the changes as they happen. Up to 8
readers at a time; TCP_NODELAY is on.

## Messages

Every message is

    u32 length      bytes that follow (the type and the payload)
    u8  type
    ... payload

All numbers are little-endian; `f32` is IEEE single precision; names are
32 bytes, UTF-8, zero-padded. Readers skip messages of types they do not
know (the length says how far).

| Type | Name | Payload |
|---|---|---|
| 1 | HELLO | `char[4] "BEEL"`, `u16 version` (1), `u16 role` (0 the editor, 1 a mirror or reader), `u32 peer` (the editor's process id), `name[32]` ("BeeModel") |
| 2 | SNAP_BEGIN | `u32 objects`, `u32 meshes`, `u32 materials` - forget the scene: what follows until SNAP_END is all of it |
| 3 | SNAP_END | - |
| 4 | TICK | `u64` the editor's CLOCK_MONOTONIC (ns) when the changes after it were found |
| 10 | OBJECT | `u32 uid`, `u32 type` (0 mesh, 1 light, 2 camera, 3 sketch, 4 armature), `u32 flags` (0x200 hidden), `u32 colour` (0xRRGGBB), `i32 material` (-1: none), `u32 mesh` (the mesh's id: the object's uid; 0: none), `name[32]`, `f32 location[3]`, `f32 rotation[3]` (radians, applied X then Y then Z: R = Rz Ry Rx), `f32 scale[3]` - a new object, or all of an object again |
| 11 | DELETE | `u32 uid` - the object and its mesh are gone |
| 12 | TRANSFORM | `u32 uid`, `f32 location[3]`, `f32 rotation[3]`, `f32 scale[3]` |
| 13 | PROPERTY | `u32 uid`, `u32 key`, 32 bytes: key 1 `name[32]`, 2 `i32 material`, 3 `u32 flags`, 4 `u32 colour` |
| 20 | MESH | `u32 mesh`, `u32 vertices`, `u32 polygons`, `u32 loops`, `u32 has UVs`; `f32 position[3]` per vertex; `u32 start` per polygon and one more (polygon `i` is loops `start[i]` .. `start[i+1]`); `u32 vertex` per loop; if UVs: `f32 uv[2]` per loop |
| 21 | MESH_DELTA | `u32 mesh`, `u32 ranges`; per range `u32 first`, `u32 count`, `f32 position[3]` per vertex - vertices that moved, the topology as it was |
| 30 | MATERIAL | `u32 index`, `name[32]`, then 15 `f32`: base colour r g b, metallic, roughness, specular, IOR, transmission, emission r g b, emission strength, clearcoat, clearcoat roughness, alpha |

A mesh is sent before the OBJECT that uses it, materials before both.
Meshes are the objects' evaluated meshes - modifiers applied - in object
space; polygons may have any number of corners (triangulate them as a fan,
or as you like). Coordinates are BeeModel's: right-handed, Y up, metres.

## What is sent when

The editor compares its scene with what it last sent, every turn of its
event loop: new objects send MESH then OBJECT, moved ones TRANSFORM,
renamed / re-materialled / hidden / recoloured ones PROPERTY, objects whose
vertices moved MESH_DELTA (the runs of changed vertices), other mesh changes
the whole MESH, removed objects DELETE, new or changed materials MATERIAL.
A TICK starts each turn's changes. On localhost a change reaches a reader
in well under a millisecond (`tests/livelink.py` measures it).

## Backpressure

Each reader has its own queue. A reader more than 256 KiB behind gets no
TRANSFORM messages for a while: the objects that moved are remembered, and
when the reader has caught up it gets one TRANSFORM each, with the latest
place. Everything else (objects, meshes, materials, deletions) always comes,
in order. A reader 64 MiB behind is dropped.

## Writing an engine plugin

1. Connect, send HELLO (role 1), read the editor's HELLO and check the
   version.
2. On SNAP_BEGIN clear what you show; build meshes and materials as they
   come, make an entity per OBJECT, bind its mesh (by id) and material (by
   index).
3. Apply the rest as it arrives: TRANSFORM to the entity, MESH_DELTA to the
   vertex buffer (just the ranges), MESH replaces the mesh, DELETE removes.
4. Read on every frame without blocking; the stream is never ahead of the
   editor by more than its last change.
