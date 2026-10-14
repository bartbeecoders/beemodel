# The B-rep kernel

`cad.kernel on` makes CAD features build exact solids, not meshes. Pads,
pockets, holes, revolves, shells, fillets, chamfers and patterns then
produce boundary representations: NURBS and analytic surfaces trimmed by
loops of edges. Each solid's tessellation is what the viewport shows.

The switch is saved with the scene (the CAD document's `CD_KERNEL`).
Turning it off brings back the mesh replay. If the kernel cannot build a
feature for a body, that body keeps the mesh replay's result and the other
bodies stay exact. BeeScript's `brep(name, what)` reports on an object's
solid.

## Geometry (`nurbs.s`)

| Kind | Parametrisation |
|---|---|
| line | O + t X |
| circle, ellipse | O + R1 cos t X + R2 sin t Y |
| NURBS curve | rational B-spline: homogeneous control points (w x, w y, w z, w), clamped knots |
| plane | O + u X + v Y |
| cylinder | O + R (cos u X + sin u Y) + v Z |
| cone | O + (R + v sin a)(cos u X + sin u Y) + v cos a Z |
| sphere | O + R cos v (cos u X + sin u Y) + R sin v Z |
| torus | O + (R + r cos v)(cos u X + sin u Y) + r sin v Z |
| NURBS surface | rational tensor-product B-spline |

These are the parametrisations STEP and OpenCASCADE use. The basis
functions and their derivatives follow The NURBS Book (A2.2 / A2.3).
`crv_eval` gives the point and two derivatives, and `srf_eval` gives the
point with Su and Sv. The NURBS operations are:

- `nb_insert`: knot insertion (Boehm, A5.1).
- `nb_elevate`: degree elevation. It splits the curve into Bezier pieces,
  raises each and joins them again.
- `ns_insert`, `ns_elevate`: the same for a surface, one row of control
  points at a time.
- `nb_arc`: a circular arc as a rational quadratic (A7.1).
- `ns_revolve`: revolves a NURBS profile into a surface.

Everything is computed in doubles. `nurbscheck(k)` runs the self-checks
in `nbcheck.s`.

## Topology (`brep.s`)

A body is a run of faces. Each record type holds:

- **Face:** a surface, a sense, and a run of loops; the first loop is the
  outer one.
- **Loop:** a run of coedges.
- **Coedge:** an edge, the direction it walks it, and its pcurve: the edge's
  curve in the face's (u, v).
- **Edge:** a curve, a parameter range, and two vertices.

Records live in arenas and refer to each other by index, and every rebuild
starts the arenas over.

A face's outside is Su x Sv, or the opposite when its sense is 1. Seen
from outside, outer loops turn counter-clockwise and holes clockwise, so a
valid solid walks every edge once in each direction. `bd_check` verifies
this and that every loop closes.

How a pcurve is made depends on the edge and the surface:

- On a plane, a line or conic maps to its affine image, which is exact.
- On a revolved surface, an iso-parametric edge maps to a straight line in
  (u, v), which is also exact.
- An edge that is already a polyline gives a polyline pcurve through its
  own points.
- Anything else gives an adaptive polyline.

Points at a pole take u from their neighbour. Periodic surfaces are split
into patches of at most half a turn, so no face needs a seam.

Volume and area come from Green's theorem in (u, v). The volume is
`1/3 ∮ G dv`, where `G = ∫ S · (Su x Sv) du`, and the area uses `|Su x Sv|`
instead. Both use 8-point Gauss-Legendre quadrature along each pcurve
piece and across u. The results are exact to rounding for analytic
geometry: the tests see errors around 1e-15.

## Solids from sketches (`bbuild.s`)

`bp_build` finds a sketch's closed loops exactly: lines and arcs chained
end to end, with whole circles as two half arcs. It nests them even-odd and
turns material loops counter-clockwise and holes clockwise. `bp_place` maps
the sketch plane through the object's transform (and a pattern's) in
doubles.

- **`bp_prism`:** a plane or cylinder per profile element, plus the
  profile itself as the caps.
- **`bp_revolve`:** turns the profile about the sketch's u or v axis. Lines
  become cylinders, planes or cones; arcs become spheres or tori. The
  surface is split into patches of at most half a turn, with poles where
  the profile touches the axis and caps for part turns.

Faces are oriented by asking the profile whether a point just off them
lies inside the solid. The test is exact, arcs included.

## Intersections (`bssi.s`)

`ssi(fa, fb)` returns the curves where two faces' surfaces meet, as dense
polylines. Every point lies on both surfaces and carries its (u, v) on
each.

Five cases are solved in closed form and keep their exact curve:

- plane and plane
- a cylinder across its axis, or along it, against a plane
- a sphere against a plane
- a cone across its axis against a plane

Everything else is traced:

1. The signed distance to the second surface is sampled on a grid over the
   smaller face.
2. Its zero contour is followed cell by cell (marching squares).
3. Each point is pulled onto both surfaces by intersecting their tangent
   planes, which converges quadratically.
4. Points are added wherever the polyline strays from the curve by more
   than 1e-7 of the model's size, including on the segment that closes a
   loop.

## Booleans (`bbool.s`)

1. Both solids are tessellated. Every pair of faces whose boxes meet is
   intersected, except faces on the same plane, which are paired instead.
2. Each section is cut where it crosses either face's boundary. The
   crossing is found exactly on the boundary edge: a bracketed root of the
   distance to the other surface along it. It becomes a vertex that splits
   that edge.
   - Vertices weld to any existing vertex within 1e-8 of the size.
   - A touch with no sign change makes no crossing. The transversal side
     makes that vertex exactly, and `snap_vertices` splits every edge any
     new or existing vertex lies on.
3. Pieces inside both faces become edges. If a piece runs along one face's
   boundary, that face's edges along it are put into the other face
   instead.
4. Each face that was cut is divided. Its boundary pieces (walked one way)
   and the section edges and paired face's edges inside it (walked both
   ways) are traced into cycles in (u, v), turning the sharpest way at each
   vertex. Outer cycles, with the holes nested inside them, are the
   regions.
5. Each region is classified at its deepest point (the farthest from its
   boundary on a 24 x 24 grid). The point is outside or inside the other
   solid (a ray-parity vote over its tessellation), or on a paired face
   facing the same or the opposite way.
   - **Union** keeps A outside B, B outside A, and A on B facing the same
     way.
   - **Difference** keeps A outside B, A on B facing the opposite way, and
     B inside A turned inside out.
6. The result must pass `bd_check`, or the feature falls back to the mesh.

## Fillets and chamfers (`bfillet.s`)

These work on straight edges between two planes. The selector chooses the
edges: all sharp ones, vertical, horizontal, top or bottom, as for meshes.
Each edge's corner is a prism along the edge. Its cross-section is bounded
by the faces' planes and the rolling ball's arc: a cylinder tangent to both
planes, set back by `r / tan(half the angle between the faces)`. For a
chamfer the arc is a line.

A convex edge loses that material: a difference, with the prism reaching
past the edge's ends. A concave edge gains it: a union, with the prism
exactly as long as the edge. Edges meeting at a corner would need blends,
so those features fall back to the mesh.

## Tessellation (`btess.s`)

Every edge is sampled once, at 15 degrees on conics and refined to a chord
height of 2e-4 of the size, so the two faces of an edge share its points.

Each face is triangulated in its (u, v), scaled by the surface's metric:

1. Its holes are bridged into the outer loop and the result is ear-clipped
   (prof.s).
2. Edge flips that never cross the boundary make the triangulation
   Delaunay.
3. Curved faces get points inside, at the sampling step, each inserted with
   flips.

Triangles turn so their normals point outwards. The result is watertight:
every triangle edge is used exactly twice, once each way.

## STEP (`step.s`, `stepread.s`)

`file.export_step <path>` writes every object with a solid (built by the
kernel or imported) as ISO 10303-21, AP214 (`AUTOMOTIVE_DESIGN`):

- **Geometry:** lines, circles, ellipses and B-spline curves; planes,
  cylinders, cones, spheres, tori and B-spline surfaces, rational ones as
  the complex instances STEP needs. Our parametrisations are STEP's, so
  each is written as it is.
- **Topology:** an advanced B-rep (`MANIFOLD_SOLID_BREP`) per solid. Pole
  edges are left out, as STEP expects.
- **Products:** each solid is a product named after its object, with its
  colour as a styled item.
- **Placement:** one solid is written in place, its object's transform
  applied. Several make an assembly: each object a component placed by its
  transform (`NEXT_ASSEMBLY_USAGE_OCCURRENCE` and
  `ITEM_DEFINED_TRANSFORMATION`).
- **Units:** the scene's (millimetres, centimetres, metres, or inches as a
  conversion-based unit); angles in radians.
- **Precision:** reals carry 17 significant digits, so they come back to
  the last bit.

`file.import_step <path>` (an undo step) reads Part 21 with its own parser:
simple and complex instances, typed values, comments. Every solid becomes a
kernel body:

- Faces get their pcurves from their surfaces.
- Seamed faces get pcurves that continue round the seam.
- Poles get the degenerate edges STEP leaves out.
- A face bounded only by meridians takes the side of the turn its loop's
  direction gives.
- Lengths are converted from the file's unit, the one its context assigns,
  to the scene's.

Each placed instance of a solid becomes a mesh object, its tessellation,
named after its product. It gets its assembly placement (through every
level of the assembly) as the object's transform, and the solid's colour.
`brep()` and `file.export_step` see the solid, so a part goes back out
exact. The parsed file is kept for the session, so the solids are built
again after each kernel reset. A saved `.bee` keeps the meshes; import again
for the exact solids.

[tests/step.py](../tests/step.py) round-trips an assembly of every analytic
surface, placed, turned and coloured, and the enclosure's case:

- **Our own round trip:** volumes and areas to 1e-9 (about 1e-15 seen), the same faces,
  placements and colours.
- **Units:** the case read into a centimetre scene, and an inch scene
  exported.
- **Through FreeCAD (or OpenCASCADE):** reading both files (volumes to 1e-6,
  each solid where we put it), writing them again for us to read (to 1e-6),
  and its every-face-NURBS version of the case (to 1e-6).

## BeeScript

| Call | Result |
|---|---|
| `op("cad.kernel", "on")` / `"off"` | The switch (an undo step, saved with the file) |
| `brep(name, what)` | Reports on the object's solid. `what` is one of: `"volume"`, `"area"`, `"faces"`, `"edges"`, `"vertices"`, `"loops"`, `"valid"`, `"watertight"`, `"triangles"`, `"tessvolume"` (the triangles' volume), `"kernel"` (1 when it has a solid), `"error"` (why the last boolean failed), or how many faces are `"planes"`, `"cylinders"`, `"cones"`, `"spheres"`, `"tori"`, `"nurbs"`. Without a solid it returns nil. |
| `nurbscheck(k)` | The largest error of NURBS check `k` (`nbcheck.s`) |
| `op("file.export_step", path)` / `op("file.import_step", path)` | STEP out and in |
| `get(name, "color")` / `set(name, "color", rgb)` | The object's colour, `0xRRGGBB` as a number (what STEP writes and reads) |

Setting `BEEMODEL_BREP_KEEP=1` keeps boolean results even when they are
not valid, and dumps their topology and each face's arrangement to stderr
(`bdebug.s`).
