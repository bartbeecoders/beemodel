# Particles and liquid

A **particle system** belongs to an object, its emitter. It makes rain,
snow, sparks, confetti, fountains and smoke-free splashes, and with
**liquid** on it is water (or oil, or honey) that flows, splashes and is
meshed into a surface each frame. An object can have several systems.

The code is in these files:
- `src/particles.s`: the systems' settings, the particles, emitting,
  moving, collisions and events, drawing, renders, the surface, the
  cache, the presets.
- `src/liquid.s`: the liquid solver (position-based fluids).
- `src/partui.s`: the Particles tab of Properties.
- `src/sdf.s`: `sdf_fmesh`, the mesher the surface uses.

The tests are in `tests/particles.py` (and `tests/gpu.py` for a render on
the GPU against the CPU).

## Adding particles

From the menus:
- **Add › Particles ›** Rain, Snow, Sparks, Confetti, Fountain, Water Tank:
  an emitter at the 3D cursor with that preset (see [Presets](#presets)),
  and **Particle System** for an empty one on the active object.
- **Properties › Particles** (the sparkle tab) for the active object: Add
  System... (a preset or an empty system), the system picked by number,
  Remove, then sections that fold: Emission, Motion, Look, Collisions,
  Liquid and Cache (Bake, Free).

From scripts:

```
op("particles.add", "rate 500 speed 3 spread 20 life 2")   # on the active object
op("particles.add", "fountain rate 200")                    # a preset, then changes
op("particles.set", "system 2 color ff8020 color_end 2040ff")
op("particles.remove", "system 2")
emit("Cube", "from volume burst 10000 speed 0 life 5")      # BeeScript: its number
emit("Cube", "sparks", "rate 50")                           # a preset and changes
print(particles(0))                                         # particles alive
```

`particles.add` and `particles.set` take these words, in any order (a
preset's name may come first):

| Word | Value | Notes |
|---|---|---|
| `from` | `faces` `volume` `verts` `point` `events` `fill` | where they are born (below) |
| `rate` | a second | born steadily from `start` to `end` |
| `burst` | how many | all at once at `start` |
| `start`, `end` | frames | |
| `life` | seconds | |
| `life_random` | 0..1 | some live shorter, by up to this part |
| `speed` | m/s | along the normal, or the direction |
| `speed_random` | 0..1 | faster or slower by up to this part |
| `normal` | | along the surface's normal (or the point's +Y) |
| `direction` | x y z | along this (the object's axes, so turning it aims it) |
| `spread` | degrees | a cone round the way they go |
| `size` | m | how big (a liquid: its spacing) |
| `size_random` | 0..1 | |
| `size_end` | a factor | the size at the end of its life |
| `color`, `color_end` | RRGGBB | the colour, and the one it ends with |
| `drag` | 1/s | the air slows them: v / (1 + drag dt) a step |
| `gravity` | a factor | 1: as everything else; 0: they float |
| `group` | 0..15 | the force fields that act on them (their collision group) |
| `seed` | a number | another pattern of random values |
| `max` | how many | at most so many at once |
| `name` | text | (events name the system they come from) |
| `draw` | `points` `sprites` `objects` | see [Drawing](#drawing-and-rendering) |
| `point_px` | 1..8 | points: pixels across |
| `objects` | `A,B,C` | drawn as these objects (up to 8, picked by id) |
| `align` | `random` `velocity` | objects: turned at random, or along their way |
| `render` | `on` `off` | off: only in the viewport |
| `collide` | `on` `off` | see [Collisions](#collisions-and-events) |
| `bounce`, `friction` | 0..1 | |
| `on_hit` | `bounce` `die` `stick` `split` | |
| `split` | how many | a hit splits it into this many |
| `events` | `born` `hit` `died` `spray` and a name | born of another system's events |
| `per` | how many | particles an event |
| `inherit` | a factor | of the other particle's velocity |
| `liquid` | `on` `off` | see [Liquid](#liquid) |
| `viscosity` | `water` `oil` `honey`, or a number | |
| `vorticity`, `tension` | numbers | |
| `substeps`, `iterations` | numbers | the liquid solver's |
| `domain` | `x0 y0 z0 x1 y1 z1`, an object's name, or `off` | the liquid's box |
| `density` | kg/m³ | the liquid's rest density (1000) |
| `surface` | `on` `off` | meshed into a surface each frame |
| `resolution` | a factor | the surface grid's spacing (x the particles') |
| `spray_speed`, `spray_neighbours` | m/s, a number | where the surface breaks |
| `on`, `off` | | off: none are born |

## Being born

- **faces**: on the mesh's faces, more on bigger ones (their area in the
  world), along the face's normal.
- **volume**: inside the closed mesh (tried at random in its box until a
  ray along +X crosses it an odd number of times), outwards from its
  centre.
- **verts**: at its vertices, along their normals.
- **point**: at the object's origin, along its +Y.
- **fill**: a lattice at the spacing (`size`) inside the mesh, all at once:
  how liquids start.
- **events**: from another system's events (below).

At a rate, particle number `j` is born at `start + j / rate`, so a stream
is smooth between frames: each one is moved on from its own moment of
birth. A burst is born at `start`. Each particle's random values (where
on the surface, the cone, its speed, life and size) come from a hash of
the system's seed and its id: the same on any number of threads.

## Moving

One step a frame, from the scene's start. Each particle feels gravity (×
its `gravity`) or, when there are force fields, their sum at its place
([FIELDS.md](FIELDS.md)), then drag:

```
x += v dt + a dt² / 2
v  = (v + a dt) / (1 + drag dt)
```

That is exact for a steady pull, so a fountain's arc is the ballistic
curve. The dead (`age >= life`) are dropped. Going back on the timeline
plays the cached frames ([The cache](#the-cache)); a change to the systems,
their emitters or the fields simulates again.

The particles live in blocks of 4096, 1024 blocks: 4 million at most.
Every block steps in parallel, four particles at a time with SSE when
nothing but gravity pulls.

## Drawing and rendering

The viewport draws each system:
- **points**: squares of `point_px` pixels;
- **sprites**: round, their size, shaded like a ball;
- **objects**: instances of up to 8 objects (`objects Leaf,Twig`), each
  particle one of them by its id, scaled by its size, turned at random or
  along its velocity.

The colour goes from `color` to `color_end` over a particle's life when
an end colour is set, and the size towards `size × size_end`. Points and
sprites are drawn by the CPU into a buffer of depth-and-colour keys (the
nearest wins), so the picture is the same on any number of threads.

Renders (Hive and the GPU helper) show each particle as a small ball
(an exact sphere of its size: one primitive, 48 bytes, where a mesh ball
would take 20 triangles) or as its object, tinted by its colour, in the
material of its emitter (objects mode: the first object's). Up to 16
million balls a render; an emissive ball is a light, sampled by the cone
it fills. `render off` leaves a system out. A liquid with its surface on
renders as the surface instead.

## Collisions and events

With `collide on`, each particle's way through the step is cast against:
- the **Ground** (a plane at its height);
- **landscapes** (their heights; a hit is put on the surface);
- the triangles of **rigid bodies** and **cloth colliders**.

On a hit it bounces (`bounce`, `friction`; too slow to leave, it rests
there), dies, sticks (and stays) or splits into `split` new particles
going on from the bounce.

Each hit, death, birth (and a liquid's spray) is an **event**. A system
made `from events` is born of another's:

```
emit("Cloud", "rate 4000 life 4 collide on on_hit die name Rain")
emit("Cloud", "from events events hit Rain per 3 speed 2 spread 50 life 0.4 name Splash")
```

Events are kept in the order of the blocks, so the same on any number of
threads. Rain on a landscape never ends below it, and every hit makes its
three splashes (the test).

## Liquid

`liquid on` makes a system water: position-based fluids (Macklin and
Müller). Its `size` is the particles' spacing; their mass makes a lattice
at that spacing exactly the rest density. Each frame, in `substeps` (8):

1. predict: v += a dt, p = x + v dt;
2. find each particle's neighbours (a hash grid, cells the kernel's size,
   h = 2 spacings);
3. `iterations` (2) of the density constraint: each particle's lambda
   from its density, then its push, then the domain and the bodies;
4. the colliders (the ground, landscapes, rigid bodies' and cloth
   colliders' triangles);
5. v = (p − x) / dt, XSPH viscosity (per 1/60 s: the same over any number
   of substeps), vorticity confinement.

The **domain** (`domain x0 y0 z0 x1 y1 z1`, or an object's box) and the
Ground are walls: a lattice of the liquid beyond them adds to the density
of particles near them, so the water rests at its true depth. Moving rigid
bodies of one box, ball or capsule push the liquid out of themselves and
are pushed back, so a light box floats and a heavy one sinks.

`viscosity water` (0.02), `oil` (0.2), `honey` (0.6), or a number.
`tension` adds the tensile term (drops hold together), `vorticity` keeps
swirls alive. Liquid particles live until the end (their `life` is not
used).

## The surface

With `surface on` a liquid is meshed each frame: a density field on a grid
over its particles (each adds (1 − r²/R²)³ out to two spacings, the field
at half the lattice's density), splatted in parallel by z slab, then
marching tetrahedra (the SDF mesher). The surface is closed and manifold.
The emitter shows it while the particles run, so the viewport, renders
and exporters see it, and it gets the water material when it has none.

Where the surface breaks, fast particles with few neighbours are **spray**
events: `emit("Tank", "from events events spray Water per 1 inherit 1 life 0.5")`
makes foam.

```
op("file.export_liquid", "~/water/frame 1 120")    # frame_0001.obj ...
```

writes the active object's surface (or mesh) as an OBJ file a frame. (glTF
morph targets are not written: the surface's triangles change every
frame.)

## The cache

Like rigid bodies and cloth, particles keep every frame they reach in the
simulation cache: channel 2 for particles, channel 3 for liquids. A frame
is each system's bounds, then 20 bytes a particle (its place and velocity
in 16 bits inside them, how far through its life, its size, its id).
Scrubbing back plays those frames (surfaces are meshed again); going on
past the cache simulates again from the start.

```
op("sim.bake", "particles liquid")    # or Properties › Particles › Cache › Bake
op("sim.free", "particles")
print(cacheinfo(7), cacheinfo(8))     # frames cached: particles, liquid
```

A bake is saved with the file (the SIMC chunk), and a reopened file plays
the same frames.

## Presets

| Preset | The emitter | The system |
|---|---|---|
| Rain | a 10 m plane 8 m up | 3000 a second, falling, die where they land |
| Snow | a 10 m plane 8 m up | 400 a second, drifting down, stick where they land |
| Sparks | a small ball | 300 a second, fast, short-lived, yellow to red, bounce |
| Confetti | a small ball | 600 at once, drifting down |
| Fountain | a low cylinder | 600 a second upwards, blue to white, bounce |
| Water Tank | a 1 m block | liquid filling it, in a box twice its size, with its surface |

## In BeeScript

| Builtin | |
|---|---|
| `emit(object [, preset or settings [, settings]])` | a new system on it: its number |
| `particles(k [, i])` | 0 alive, 1 systems running, 2 the last frame's time (ms), 3 the last step's, 4 blocks in use, 5 steps; particle i: 6-8 its place, 9-11 velocity, 12 age, 13 life, 14 size, 15 id, 16 colour; 17 the last viewport draw (ms), 18 particles drawn, 19 hits so far, system i: 20 born of events, 21 its hits, 22 its particles; the liquid solver: 23 its last frame (ms), 24 the most neighbours, 25 a particle's mass, 26 the kernel's size, 27 the densest (ρ / ρ0); system i's surface: 32 its meshing (ms), 33 its triangles |
| `cacheinfo(k)` | 7 particles' frames, 8 liquids', 9 / 10 baked |

## Numbers

From `tools/physbench.py` (`BENCH_ONLY=particles,liquid`) on a Ryzen 9
7950X (16 cores, 32 threads):

| | 1 thread | 4 threads | 8 threads | 32 threads |
|---|---|---|---|---|
| 1M particles, a step | 0.74 ms | 0.56 ms | 0.77 ms | 0.69 ms |
| a dam break of 200k liquid particles, a frame (its surface meshed) | 2299 (110) ms | 628 (51) ms | 347 (42) ms | 188 (34) ms |

The plan's budgets (8 threads): 1M particles step in under 10 ms; 200k
liquid particles under 1 s a frame, plus 200 ms meshing. The particles'
step is bound by memory, not threads. The surface's time grows as the
water spreads: about 140 ms on 8 threads once the dam has broken
(tests/particles.py). Each scene ends with the same hash on every thread
count.
