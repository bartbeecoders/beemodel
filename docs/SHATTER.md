# Shatter

`object.shatter` breaks a mesh object into pieces: **shards** (Voronoi
cells), **bricks** (a running bond) or **balls**. Each piece is a mesh
object of its own and, unless told otherwise, a rigid body. The pieces can
be **glued** so that a blow knocks out only the part it hits. An object
can also wait **whole until it is hit** hard enough, then break while the
simulation runs.

The code is in these files:
- `src/shatter.s`: the cutter.
- `src/shatterop.s`: the operators, patterns, pieces, glue and the form's
  preview.
- `src/rbody.s`: breaking glue and shattering on impact.
- `src/physui.s`: the Shatter section of Properties › Physics.

The tests are in `tests/shatter.py`.

## Using it

From the menus:
- **Object › Physics › Shatter...** opens a form with these fields:
  pattern, preset, count, seed, glue, impact and gap. While the form is
  open, the viewport draws the cells it would cut as outlines on the
  object. The outlines are made again when a value or the object changes;
  nothing is cut until OK.
- **Properties › Physics › Shatter** (a section, closed at first) has the
  same settings for the active mesh: pattern, preset, count, seed, glue
  (and **Show glued faces**), the blow it breaks at, the bricks' gap and a
  colour for the cut faces (the colour picker). Below them is a
  **Shatter** button; on a piece it reads **Re-cut**, which brings the
  original back and breaks it again with the settings shown. The section
  shows the settings of the last shatter.

From scripts:

```
op("object.shatter", "shards count 200")
op("object.shatter", "bricks counts 10 5 1 glue 40000 density 2000")
op("object.shatter", "balls radius 0.05")
op("object.shatter", "preset glass")
op("object.shatter", "again shards count 20")      # on a piece: re-cut
shatter("Wall", "bricks", 10, "glue 40000")        # BeeScript: the pieces made
shinfo(0)                                          # the last shatter: pieces
```

The options:

| Option | Meaning |
|---|---|
| `shards` / `bricks` / `balls` | The pattern (default: shards) |
| `count n` | Shards: cells (default 50). Bricks: bricks a row, in n / 2 rows. Balls: about how many |
| `seed s` | The random seed (default 1) |
| `at x y z` / `cursor` / `surface` | Shards: seeds around a world point or the 3D cursor (closer is likelier, so the pieces are smaller there), or near the surface |
| `spread f` | How tightly the seeds gather around the point (default 0.5) |
| `size x y z` / `counts a b c` | Bricks: a brick's size, or how many along X, Y and Z (default 8 4 1) |
| `offset f` / `offset random` | Bricks: each row's shift, in bricks (default 0.5) |
| `gap g` | Bricks: a mortar gap (m) taken off every face |
| `jitter f` | Bricks: the joints moved at random, by this share of a brick |
| `radius r` | Balls: their radius (default: from the count) |
| `inner r g b` | The cut faces' colour (vertex colours of their own) |
| `density kg/m3` | The bodies' density (default: the object's material, else 1000) |
| `nobodies` | Pieces only, not rigid bodies |
| `glue N/m2 [paint]` | Fixed joints between touching pieces; `paint` shows the glued faces |
| `impact N s` | Whole until a blow of this size; then it breaks (see below) |
| `preset p` | `brickwall`, `glass`, `stone`, `gravel` (or `none`): a pattern and values that the words after it can change |
| `again` | On a piece or a shattered original: the original back, its pieces gone, then cut again |

The presets set these values:

| Preset | Pattern | Count | Glue (N/m²) | Impact (N s) | Density | Other |
|---|---|---|---|---|---|---|
| `brickwall` | bricks | 10 × 5 | 40 000 | - | 1900 | 5 mm gap, mortar-grey cut faces |
| `glass` | shards | 60 | 15 000 | 10 | 2500 | pale cut faces |
| `stone` | shards | 25 | 150 000 | - | 2600 | grey cut faces |
| `gravel` | balls | 300 | - | - | 1800 | the radii spread |

The original is hidden, not deleted, and the pieces are its children. One
undo step brings it back. `mesh.separate_loose` (Mesh › Separate › Loose
Parts) splits a mesh into its loose parts.

## Cutting

The mesh is evaluated (with its modifiers) and must be closed. An open
mesh is repaired first, by filling its holes; one that does not close is
refused. The cutter works in doubles, in the object's own space.

- **Cells.** A cell is a set of planes. For shards these are Voronoi
  cells: the bisectors to the neighbouring seeds, within a bounding box.
  For bricks they are the joints' planes. Every plane carries a tag that
  both of its sides share:

  | Planes | Tag |
  |---|---|
  | Voronoi | `1<<30 \| lo<<12 \| hi` |
  | Brick joints | `1<<24 \| row<<12 \| joint` |
  | Brick rows | `2<<24 \| row` |
  | Brick layers | `3<<24 \| layer` |

  Glue uses the tags to find which pieces meet.
- **Clipping.** A solid is a set of convex polygons, clipped plane by
  plane with Sutherland–Hodgman. A point on a cut edge is made once, so
  both of the edge's polygons share it. The hole that each plane leaves is
  filled at once:
  - its edges are chained into loops;
  - a convex loop becomes one polygon;
  - otherwise holes are bridged into their outer loop, and the ring is
    ear clipped (reflex corners kept in a grid). The triangles are then
    merged back into convex polygons (Hertel–Mehlhorn).

  Every step keeps the solid closed. A piece whose parts do not touch (a
  cell across a concave mesh) becomes one piece for each part.
- **A tree of cells.** The cells are split at the median of their centres.
  Each node's solid is its parent's, clipped to the node's box, so a cell
  is cut from a small solid near it rather than from the whole mesh.
  Nodes and cells are cut in parallel. Each thread has its own arenas for
  scratch and results, so nothing is unmapped while the threads run.
- **Inside the mesh.** Seeds and balls must lie inside the mesh. The test
  counts how many times a ray crosses the mesh; an odd count means inside.
  The ray's direction is skewed slightly so that it misses edges. For
  meshes of 256 triangles or more, the triangles are first binned into a
  2D grid, as seen along the ray (about 0.7 √n cells a side). A point
  then tests only the triangles in its own cell.
- **The checks** (`shinfo`):
  - every piece is closed (5: open edges);
  - the pieces' volumes add up to the original's (9: the relative error,
    under 1e-6);
  - no piece is a sliver (10: the smallest piece's share of the mean).

**Balls** are not cut. Spheres sit on a face-centred cubic lattice and are
kept when they are inside the mesh and clear of its surface (0.8 r, by the
distance to the nearest triangle). They all share one sphere mesh.

## Pieces and bodies

Each piece becomes a mesh object. Its origin is at its centre of volume,
and it is turned and scaled like the original. The cut faces get the
inner colour when there is one. Unless `nobodies` is given, each piece is
an active convex-hull rigid body:
- its mass is its volume × the density;
- its centre of mass and moments of inertia come from the hull itself,
  not from its bounding box;
- it keeps the original's friction, bounce and damping when the original
  was a body.

A hidden object is not a body, except an original that waits to shatter
on impact.

## Glue

`glue s` puts a fixed joint between every two pieces whose tagged faces
meet. The joint's pivot is the centre of the shared face, and it breaks
when its load passes s × the face's area. The world's area counts here:
the object's scale is applied. A wall of 10 × 5 bricks in a running bond
gets 127 joints: 47 within the rows and 80 between them.

Joints break **inside the solve**: a joint whose impulse passes its limit
in an iteration lets go at once. The blow therefore knocks out the bricks
it hits, rather than moving the whole wall as one. Up to 16 384 joints can
exist (files save only those in use: ANIM v3). `rbinfo(15)` counts the
joints broken.

## Shattering on impact

With `impact b` the original stays a whole body and its pieces wait,
hidden and dormant. Past a blow of b N s it breaks within the same step,
and the pieces take over where it was, moving as it moved. The details
are in [PHYSICS.md](PHYSICS.md#shattering-on-impact). A logic graph's
**Shatter** node breaks it on demand. The simulation cache records which
originals are broken, so scrubbing back shows the object whole again.

## Speed

`tools/physbench.py` times the `shatter` scene: a vase of 99 072
triangles cut into 500 shards. The times below are in ms, for the whole
operator and for the cut alone (the 500 objects are made, without bodies):

| Threads | 1 | 4 | 8 | 32 |
|---|---|---|---|---|
| ms | 455 / 415 | 163 / 124 | 121 / 83 | 105 / 66 |

Other figures:
- the 49k-triangle vase in `tests/shatter.py` is cut into 500 cells in
  about 54 ms;
- the inside grid cut seeding on the 100k vase from 250 ms to 12 ms.

## BeeScript

| Call | Returns |
|---|---|
| `shatter(name, pattern, count [, options])` | The number of pieces made |
| `shinfo(k)` | A figure about the last shatter (table below) |
| `get(name, "hidden")` | 1 if the object is hidden, 0 if not |

The figures `shinfo(k)` returns:

| k | Figure |
|---|---|
| 0 | pieces |
| 1 | cells |
| 2 | the pieces' volume |
| 3 | the original's volume |
| 4 | the smallest piece's volume |
| 5 | open edges in the pieces |
| 6 | ms in all |
| 7 | glue joints |
| 8 | the mesh's open edges before repair |
| 9 | the volumes' relative error |
| 10 | the smallest piece's share of the mean |
| 11-13 | ms seeding, cutting, making objects |
| 14-17 | the cut's phases |
| 18-20 | balls: the radius, the gap between them, how far past the surface |
| 21 | the pieces' mass |
| 22 | bodies |
| 23 | the outlines the form's preview draws |

## Tests

`tests/shatter.py` runs one section per stage:
- **S1:** a cube, a torus and a vase cut into 100 cells each (closed, the
  volume kept, no slivers), and an open mesh repaired.
- **S2:** bricks (their sizes, rows, the running bond, the gap, materials,
  the inner colour), 500 balls in a sphere, and shards around a point.
- **S3:** 200 bodies that fall, land and sleep; Ctrl+Z in the window.
- **S4:** a glued wall: a hole where a 20 m/s ball hits it, nothing at
  4 m/s, the same on 1 and 8 threads.
- **S5:** a vase breaks on impact in play mode with no frame over 16 ms;
  the cache; the logic node.
- **S6:** the form and its preview, the presets, `shatter()`, and the
  panel's re-cut, using clicks only.
