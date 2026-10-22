# Physics: the rigid body solver

`rigid.add` makes the selected objects rigid bodies. When the frame goes
past the scene's start they fall, collide, rest and sleep, and they come
back when the frame returns to the start. Everything about them lives in
the animation block: the world (`AN_RW_`), up to 4096 bodies (`AN_RB_`) and
16 384 joints (`AN_JT_`; files keep those in use). So they undo, save with the file and go into the
simulation cache. The code is `src/rbody.s` (the solver),
`src/clip.s` (face clipping) and `src/physui.s` (Properties › Physics).
The tests are `tests/solver.py` (and the physics panel in `tools/fakewl.py`), and the benchmark
is `tools/physbench.py`.

Hidden objects (`object.hide`, a shattered original) are not bodies.

Particles and liquid collide with the Ground, landscapes, rigid bodies
and cloth colliders, and a liquid pushes moving bodies (they float):
[PARTICLES.md](PARTICLES.md).

Force fields (attractors, gravity zones, wind, vortex, turbulence, drag)
add to gravity each substep, and bodies marked `attracts` pull each other
(Barnes-Hut): [FIELDS.md](FIELDS.md).

## Setting it up

```
select("Box")
op("rigid.add", "active box mass 2 friction 0.5 bounce 0.1")
select("Floor")
op("rigid.add", "passive mesh")
op("rigid.joint", "hinge Door world pivot 0 1 0 axis 0 1 0 limits -90 0")
op("rigid.world", "gravity 0 -9.81 0 rate 120 iterations 10 substeps 4")
frame(120)
```

| Setting | Words | Notes |
|---|---|---|
| type | `active`, `passive` | passive bodies don't move (they can be keyed: they move with their object) |
| shape | `box` `sphere` `capsule` `hull` `compound` `mesh` `plane` | `mesh` and `plane` are passive only |
| instances | `instances`, `object` | each instance of the object's geometry nodes is a body shaped like its prototype |
| values | `mass` `friction` `bounce` `damping` | |
| material | `material default\|rubber\|ice\|wood\|metal\|stone` | sets friction and bounce |
| start | `velocity x y z` | its velocity when the run begins |
| groups | `group n` (0-15), `collide m` | m: a bit mask of the groups it meets (all by default) |
| attraction | `attracts`, `noattract` | it pulls every other moving body by its mass (`rigid.world g n`: G, 1 by default) |

Shapes:
- **Hull**: up to 64 points of the mesh, the farthest along fixed directions
  (points within 2% of its size of one kept are left out: two near
  points make the contacts flicker). A closed mesh's hull body takes the
  mesh's centre of volume and its moments (the inertia's diagonal) instead
  of its bounds' centre and box.
- **Compound**: convex pieces cut from the mesh. A triangle set is split at the middle of its longest side while some triangle lies deep inside the piece's hull.
- **Mesh**: every triangle is a collider, found through a tree. A
  landscape is a heightfield instead (below).
- **Plane**: endless, the object's XZ plane. The Ground (`create.ground`)
  is one.

Joints: `rigid.joint <type> <object> <object|world>`.

| Type | Keeps |
|---|---|
| `fixed` | the two together, as placed |
| `hinge` | a shared pivot and axis; they turn about it |
| `point` | a shared pivot (a ball joint) |
| `slider` | the two on a line along the axis, turning together |

Joint options:
- `pivot x y z`: the joint's place; by default, the first object's place.
- `axis x y z`: the joint's axis; Y by default.
- `break f`: the joint breaks once its load over a step passes f newtons. A broken joint is gone for the rest of the run.
- `limits lo hi`: where a hinge (degrees) or a slider (metres) stops.
- `motor speed force`: drives a hinge (degrees a second, at most that torque) or a slider (metres a second, at most that force).

Angles and speeds are those of the first object, measured from the second.

Script reports:
- `rigid(name, key)`: a body's settings.
- `instpos(object, i, k)`: instance i's place.
- `rbinfo(k)`, with k:
  - 0: bodies
  - 1: contact points
  - 2: awake bodies
  - 3: islands
  - 4: the last frame's time in ms
  - 5: manifolds
  - 6: steps
  - 7: parts
  - 8-13: the phases' ms
  - 14: pairs that found no room
  - 15: joints broken
  - 16: a hash of every body's state
  - 17: the fastest awake body's speed (its turn counted at its surface)
  - 18: that body's object's uid
  - 19: joints in the run
  - 20, 21: originals that shatter on impact, and those broken
  - 22-24: bodies that attract, their tree's cells, its ms
  - 25: 1 when the frame shown was played back from the cache

  Scrubbing back (or replaying a frame already simulated) plays it from the
  cache. `rbinfo` then answers for that frame, with the counts kept when it
  was simulated: bodies, contacts, awake bodies, islands, steps, the state
  hash (16), the fastest body and so on. What was not kept reads 0 then: the
  phases' ms (8-13), the attractors' (22-24) and the contact points
  (1000 + ...), and every count of a frame baked in an earlier session (a
  file's bake). `rbinfo(25)` tells the two apart.

## A step

The world steps at a fixed rate (`rate`, 120 a second by default), and a
frame runs the steps up to its time. Each step does the following:

1. **Bounds.** Each part's box in the world. It grows by how far the body can
   go in the step (|v| dt), so fast bodies find their pairs early.
2. **Broad phase.** A hash grid. Its cell is the moving bodies' average size;
   bodies more than twice that are tested against all. Entries are
   counting-sorted by bucket. A pair is found once, in the cell where the
   overlap of its bounds begins. The buckets are scanned in parallel in chunks
   of 256, counted first, then written. Pairs whose groups ignore each other
   are left out.
3. **Manifolds.** Each pair's manifold is looked up in parallel in a hash
   kept between steps. A manifold is made when new and taken out when the
   pair parts (the last one moves into its place; backward-shift deletion).
   A dense array of the manifolds' keys serves the scans.
4. **Narrow phase**, in parallel:
   - Two polytopes (boxes, hulls, triangles): their faces are clipped
     (`clip.s`: Sutherland-Hodgman on the reference face, the incident
     face's points within the contact margin). A box on a box touches at
     four corners.
   - Spheres against spheres and boxes: exact.
   - Other pairs: GJK / EPA for one point. More points come from tilting the
     smaller part about the contact. Points are kept by their body anchors
     while they are close and not sliding.
   - The margin is 2 cm plus how far the two can close in the step, so
     contacts begin before the bodies touch (speculative).
   - New points take the impulses of old ones where they were.
5. **Islands.** Union-find through the moving bodies, contacts and joints, then
   a counting sort. Islands are solved in parallel, one each.
   - A big island (128 constraints or more) is **coloured**: each constraint
     gets the first of 64 colours that neither of its moving bodies has yet.
   - The colours run as stages, one per colour per pass, on up to half the
     threads. Each thread claims blocks with an atomic counter and waits for
     the stage's last one.
   - Constraints of one colour share no moving body, so the order within a
     stage doesn't matter.
6. **Solving, in substeps** ("soft step", 4 by default). Once a step: the
   masses and each point's gap base. Each substep:
   - Gravity and damping.
   - Warm start: last time's impulses again.
   - The iterations, spread over the substeps. Each runs the joint rows,
     then friction, then the normal. The normal is speculative while the
     bodies are apart. Once they overlap, it is a soft push: a damped spring
     at up to 60 Hz, twice that against static bodies. The points are taken
     forward and back in turn.
   - Integration.
   - A relax pass: the same rows without the push, so overlaps leave no
     speed behind.

   After the last substep:
   - Restitution, only for contacts with some bounce.
   - Joints whose load passed their breaking force break.
   - Continuous collision (below).
   - Sleep: bodies slow for long enough stop until something touches them
     (under 5 cm/s, a turn counted by the speed of the body's surface:
     its turn x half its size, at most a metre).
7. **Write back.** Each body's place goes into its object or its instance.

Each contact point keeps its rows for the step: r x d and the inverse inertia
times it, for the normal and both tangents. A substep then costs a few dot
products per point.

### Joints

Joints are rows solved with the contacts. Each row works against its error
(Baumgarte), without accumulation.

| Joint | Rows |
|---|---|
| point | three linear |
| fixed | three linear, three angular (2 vec(qB qA* q0*)) |
| hinge | three linear, two angular (square to the axis) |
| slider | two linear (square to the axis), three angular |

A hinge or slider keeps where it is: the hinge's angle (2 atan2 of the
relative turn about the axis) or the slider's distance along its axis.

- **Limits** work one way: they only push the joint back in, with the speed
  that takes it back to the limit.
- **A motor** drives towards its target speed. Its impulse over a substep
  is clamped by the torque or force times the substep.
- **Breaking.** Each joint sums its row impulses over a step. Past its
  breaking force times the step's time, it breaks at once, in the middle
  of the solve: it passes no more of a blow on, so a hit breaks the glue
  near it and the rest holds. Broken: no rows, no island tie, its bodies
  collide again, for the rest of the run (`rbinfo(15)`).
- **Many joints.** Whether two bodies are tied (they don't collide then) is
  a hash of the joints' pairs; joints find their bodies through a hash of
  uids. A big island with joints is solved in stages like any other.

### Mesh colliders

A mesh body's parts are its triangles, each a 3-point hull, in a tree.

- **The tree** splits at the middle of the triangles' centres. It is walked
  with each other part's bounds.
- **Pairing.** A triangle is paired only when its closest point comes
  within the part's reach.
- **Inactive edges.** An edge shared with a neighbour in the same plane
  (within 5°) is inactive, and a contact there takes the face's normal.
  Neighbours are matched by the places of the edges' ends. A box slides
  down a ramp of 4608 triangles without catching.
- **Planes** have their own contacts: the other part's points within the
  margin, or a rounded part's core corners.

### Heightfields

A landscape (see [LANDSCAPE.md](LANDSCAPE.md)) made a passive mesh body is
not cut into triangles. Instead, triangles are made per step:
- **The cells it needs.** Before the pairs are found, the cells under every
  moving part's bounds become triangle parts on the fly. Cells above the
  landscape's highest point are skipped.
- **Their slots.** Each triangle goes into a slot of its own, 131 072 per
  landscape, through a hash from the triangle to its slot. The hash is
  rebuilt each step, and a slot unneeded for 3 steps is free again. A
  contact keeps its manifold while its triangle is in use.
- **The rest is the mesh's.** Pairs walk the cells where a mesh walks its
  tree. The narrow phase, the manifolds, the inactive edges (a neighbour
  within 5°) and continuous collision work as for a mesh's triangles.
- **Its material.** Each triangle takes the friction and bounce of the
  paint under it: the layers' by their weights, the body's for the rest.

The slots' arrays are made only when there is a landscape. 1000 balls
dropped on a 4097² mountain roll down it, and none goes under its surface
(1.6 mm at most).

### Water

A mesh object flagged as water (the island preset's sea) is a level over
its extent. Once a step, a moving body reaching below it is pushed up by
the water it displaces: 1000 kg/m³ × g × its volume × the share of its
height below the level. That share also slows it.
- **Its volume** comes from its parts: boxes, spheres and capsules as they
  are, a hull 0.7 of its bounds.
- **What floats.** A wooden box floats with about 0.6 of it under water, and
  a stone box sinks.

### Shattering on impact

An object shattered with `impact` (see [SHATTER.md](SHATTER.md)) stays a
whole body; its pieces wait as **dormant** bodies (in no collision group,
their glue asleep, hidden). A marker joint (type 5: the original, the blow
it breaks at in N s) ties them.
- **The blow.** Right after the narrow phase, before the solve, each
  contact point of the original closing at v with the two's effective mass
  m is a blow m v.
- **Breaking.** Past the threshold the original goes dormant and hidden,
  its contacts are dropped, and its pieces take its place: where it is now,
  each moving as that point of it moved, shown, their glue awake. The step
  finds its pairs and contacts again, so the blow lands on the pieces in
  the same solve and breaks the glue near it.
- **Asked to.** A logic graph's Shatter node breaks it at the next step
  (`rb_shatter_obj`; before the bodies are made, it waits with the
  impulses).
- **The cache** keeps, each frame, which originals are broken: scrubbing
  shows the original or its pieces as they were. Back at the start it is
  whole.

`rbinfo(20)`: originals that shatter on impact; `rbinfo(21)`: those broken.

### Fast bodies

A body that moved more than half its size in a step is checked against the
static parts it has manifolds with, by conservative advancement from where
the step began. Each round divides the gap by the most the body can close
in the step: its move along the normal plus its turn times its reach. The
body is put a little short of the first impact and keeps its velocity; the
next step's contact stops it.

A body that touches the part where its step began is left to that contact.
This covers a body resting or sliding on it.

A 1 cm ball at 300 m/s stops at a 1 cm wall.

## The same result on any number of threads

The result doesn't depend on the thread count:
- Pairs come out of the broad phase in a fixed order.
- Manifolds stay in the order they were made.
- Islands are solved on their own.
- A big island's stages touch different bodies in each block.
- Sums run in a fixed order.

1000 tumbling boxes, 5000 bricks and the joint scene end bit for bit the
same on 1, 4, 8 and 32 threads (`rbinfo(16)`).

## The cache

Every frame the bodies reach is kept: each object's place, and each
instance's (record version `RBV2`, mixed into the cache key). Scrubbing back
plays the frames instead of simulating again. An edit to the setup starts
it over. `sim.bake` keeps the whole frame range, saved with the file, until
`sim.free`. Files from before v0.17 (room for 1024 bodies) still open.

## Numbers

From `tools/physbench.py` on a Ryzen 9 7950X (16 cores, 32 threads):

| Scene | 1 thread | 4 threads | 8 threads | 32 threads |
|---|---|---|---|---|
| 1000 boxes into a heap, 5 s simulated | 4.35 s | 1.71 s | 0.99 s | 1.18 s |
| 10 800 balls poured into a box, 10 s | 143 s | 44.0 s | 26.6 s | 23.6 s |
| 5000 bricks settling, a frame | 229 ms | 63.6 ms | 37.4 ms | 43.5 ms |
| 1000 balls on 100 000 triangles, a frame (mean / slowest) | 54 / 99 ms | 22 / 42 ms | 19 / 32 ms | 22 / 39 ms |
| 1000 balls rolling down a 4097² landscape, a frame (mean) | 39.3 ms | 13.5 ms | 10.2 ms | 10.0 ms |
| 5445 bodies attracting each other, a step (the tree and pulls) | 7.04 (5.84) ms | 3.29 (1.92) ms | 2.03 (1.18) ms | 1.91 (0.81) ms |
| 1M particles, a step | 0.74 ms | 0.56 ms | 0.77 ms | 0.69 ms |
| a dam break of 200k liquid particles, a frame (its surface meshed) | 2299 (110) ms | 628 (51) ms | 347 (42) ms | 188 (34) ms |

Each scene ends with the same hash on every thread count. Past about 8
threads the solver is bound by memory, not arithmetic: more threads wait
on the same cache lines.

`tests/solver.py` checks these scenes, with looser time limits on CI:
- a tower of 20 boxes and a 10-layer brick pyramid stand;
- a 100 kg box rests on a 1 kg one;
- bowls, stairs, ramps and the terrain;
- fast bodies, groups and materials;
- breaking chains, motors and limits;
- the heap is the same on any number of threads.

`tests/landscape.py` checks the Ground, landscapes as colliders and water.
