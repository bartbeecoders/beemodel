# Attractors and force fields

Gravity is something you can place. A **force field** is an object that
pushes and pulls rigid bodies, cloth and soft bodies:
- an **Attractor** pulls towards its centre (or pushes);
- a **Gravity Zone** has its own "down" inside it;
- **Wind** blows, in gusts;
- a **Vortex** turns things round its axis;
- **Turbulence** swirls them;
- **Drag** slows them down.

Rigid bodies can also **attract each other** (N-body gravity), and in play
mode the player's down follows the pull where it stands, so a sphere with
an attractor is a small planet to walk round.

The code is in these files:
- `src/fields.s`: the field objects, their settings, the sum of the
  fields at a point, the gizmos, the overlay, the presets.
- `src/fieldui.s`: the Force Field section of Properties › Physics.
- `src/nbody.s`: bodies that attract each other (a Barnes-Hut octree).
- `src/rbody.s`, `src/cloth.s`: where the fields act on bodies and cloth.
- `src/play.s`: the player's frame, which turns with the pull.

The tests are in `tests/fields.py`.

## Adding a field

From the menus:
- **Add › Force Field ›** Attractor, Gravity Zone, Wind, Vortex,
  Turbulence, Drag, then the presets: Planet, Black Hole, Tornado, Breeze.
  The field is made at the 3D cursor and selected.
- **Properties › Physics** for a field: a **Force Field** section with its
  type, **On**, its strength, falloff and radius, the type's own values,
  and the collision group it acts on; then the **World** section.
- **View › Force Field Arrows** and **View › Force Field Lines** show the
  fields (see [Seeing them](#seeing-them)).

From scripts:

```
op("field.add_attractor", "strength 50 soft 0.2")
op("field.add_vortex", "strength 12 lift 6 inflow 3 falloff smooth radius 6")
op("field.set", "strength 20 groups 1,2")          # the active field
op("field.set", "off")
field("wind", "Gale", "strength 8 gust 0.5")      # BeeScript: its name
field("tornado")                                  # a preset
print(force(2, 0, 0))                             # the pull there (m/s2)
print(force(2, 0, 0, "y"))                        # one axis of it
```

`field.set` takes, in any order:

| Word | Value | Notes |
|---|---|---|
| `type` | `attractor` `zone` `wind` `vortex` `turbulence` `drag` | another type, with that type's defaults |
| `strength` | m/s² | keyframable as `field:Name:strength` |
| `falloff` | `none` `radius` `smooth` | radius: whole inside, nothing past it; smooth: (1 - (d/r)²)² |
| `radius`, `size` | m | the reach (times the object's X scale); a zone's half size |
| `law` | `square` `linear` | an attractor's pull: s / d² or s / d |
| `soft` | m | an attractor's soft core |
| `shape` | `box` `sphere` | a gravity zone's shape |
| `gust` | 0..1 | how much wind rises and falls |
| `lift`, `inflow` | m/s² | a vortex's pull along its axis, and towards it |
| `scale` | m | the size of turbulence's swirls |
| `seed` | a whole number | another pattern (turbulence, gusts) |
| `groups` | `all`, or `0,3,5` | the collision groups it acts on |
| `on`, `off` | | |

## The types

Each field sits where its object is. The object's rotation aims it and its
scale sizes its reach. At a point `p`, with `d = p - c` (the field's centre
`c`) and `f` the falloff at the distance:

| Type | Acceleration |
|---|---|
| Attractor | `-s f d / (|d|² + soft²)^1.5`, or `-s f d / (|d|² + soft²)` with `law linear`. The strength is the pull at 1 m; a negative one pushes away. |
| Gravity Zone | Inside its box (half size: radius × the object's scale, along its axes) or sphere: `-s` along the object's +Y. This replaces the world's gravity there. The first zone a point is in wins. |
| Wind | `s f` along the object's +X. With gusts, the strength rises and falls by up to `gust × s`, smoothly over a few seconds. |
| Vortex | `f (s t - inflow r̂ + lift a)`: `a` is the object's +Y, `r` the part of `d` square to it, `t = a × r̂`. The falloff is by the distance from the axis. |
| Turbulence | `s f` times the curl of three Perlin noise potentials at `p / scale` (moving slowly with time). A curl has no divergence: it swirls without gathering things in one place. |
| Drag | `-s f v` (the velocity) |

The world's gravity is added to the sum, unless a gravity zone replaces it.
**World › Gravity** in Properties › Physics turns it off for space scenes
(`rigid.world gravity 0 0 0`); the fields still act.

## On bodies, cloth and the player

- **Rigid bodies** feel the sum at their centre of mass, each substep,
  before they move (symplectic: velocity first, then position), so an
  orbit keeps its energy. A field acts on the collision groups its
  `groups` names. Bodies feel wind as an acceleration.
- **Cloth and soft bodies** feel the sum on each particle. Wind is air for
  them: each triangle feels its drag as for the world's wind (Cloth
  World), at the speed the wind fields give at its centre. So a sheet
  blows out and flutters rather than sliding as a whole. They are in
  group 0.
- **The player** (play mode) feels the sum at its middle. See
  [Walking on a planet](#walking-on-a-planet).

The fields are taken once a step as they are then: where their objects
are, their strengths (keyed or not), the gusts at that time. They are part
of the simulation cache's key, so moving a field or changing it runs the
simulation again.

## Bodies that attract each other

A rigid body marked **Attracts the others** (Properties › Physics, or
`rigid.add attracts`) pulls every other moving body by its mass:
`a = G m d / (|d|² + 0.01)^1.5`. G is the world's (**World › G**,
`rigid.world g 0.5`). It is 1 by default, which is game scale, not
6.67e-11. Passive bodies can attract too, like a planet that stays put.

Each step, the attracting bodies go into an octree of masses (Barnes-Hut).
A cell whose size is under half its distance pulls as one mass at its
centre. Each moving body's pull is summed from the tree across the worker
threads. The step's pull is given as one kick in its first substep, and
the very first step gets half a kick (leapfrog). So two bodies keep their
orbit (within 0.04% over 4.5 orbits in the test), and the result is the
same on any number of threads. `rbinfo(22)` is how many bodies attract,
`rbinfo(23)` the tree's cells and `rbinfo(24)` the ms the tree and pulls
took.

## Walking on a planet

In play mode the player has a frame of its own. Its up points against the
pull where it stands, from the fields and gravity at its middle. When
nothing pulls, up stays as it is. When the pull changes direction, the
frame turns towards it at up to 6 radians a second, so walking round a
sphere turns it smoothly. These all work in that frame:
- walking, running and jumping;
- standing on the ground, sliding along walls, stepping up and snapping
  down;
- the capsule itself.

The viewport's camera turns with it. Looking around (the mouse,
`playlook`) is relative to the ground the player stands on.

**Add › Force Field › Planet** makes a 10 m sphere with an attractor at
its centre (9.81 m/s² at its surface) and turns the world's gravity off.
Start play on top of it and walk. `playinfo(16)`, `(17)` and `(18)` are
the player's up.

Logic graphs have two nodes for fields:
- **Set Strength** (an action) sets a field's strength (its Object name)
  to its Value.
- **Field** (data) gives the pull at its Point: **Force** (a vector) and
  its **Size**.

## Seeing them

Each field object draws a gizmo of its kind:
- an attractor: arrows in (or out when it pushes);
- a gravity zone: its box or sphere and its down;
- wind: arrows along +X;
- a vortex: its axis, rings and the way it turns;
- turbulence: a wavy line;
- drag: two rings.

Three circles show the reach when the field has a falloff.

**View › Force Field Arrows** draws the fields' pull as arrows on a 9 × 5 ×
9 grid round them, without gravity. The arrows are sized by the square
root of the pull against the largest one. **View › Force Field Lines**
draws streamlines from 16 seeds round each selected object, followed along
the pull (80 steps of 0.25 m). Lines from a cube by a tornado spiral up
round its axis. `fieldinfo(k)` gives:
- 0: the fields in the scene;
- 1: the arrows drawn;
- 2: the line segments drawn;
- 3: the largest pull the overlay showed.

## Presets

| Preset | What it adds |
|---|---|
| Planet | a 10 m sphere and an attractor (`strength 981 soft 1`) at its centre; the world's gravity off |
| Black Hole | an attractor `strength 2000 soft 0.2 falloff smooth radius 8` |
| Tornado | a vortex `strength 15 lift 8 inflow 4 falloff smooth radius 6` |
| Breeze | wind `strength 2 gust 0.6` |

## Files

Each field's settings are a 64-byte record found by its object's uid. The
records are kept in one reference-counted block, copied on write, like
the lights' settings. Undo steps share it, and `.bee` files keep it as a
`FLDS` chunk (older files have none). A duplicated field copies its
record. The strength's keys are animation curves of kind 8
(`field:Name:strength`).

## Numbers

From `tools/physbench.py` (`BENCH_ONLY=nbody`) on a Ryzen 9 7950X: 5445
bodies that attract each other, one step and then the tree and pulls
alone. The run ends with the same hash on every thread count.

| | 1 thread | 4 threads | 8 threads | 32 threads |
|---|---|---|---|---|
| a step | 7.04 ms | 3.29 ms | 2.03 ms | 1.91 ms |
| the tree and pulls | 5.84 ms | 1.92 ms | 1.18 ms | 0.81 ms |
