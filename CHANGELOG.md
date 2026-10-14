# Changelog

All notable changes to BeeModel are documented here.
The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the
project uses [Semantic Versioning](https://semver.org/).

## [Unreleased]

## [0.10.0] - 2026-10-14

Phase 9 of the masterplan, "Animation & simulation". Scenes move:

- **Keyframes:** Bezier, linear and constant F-curves on anything a script
  can set, with a timeline, a dope sheet, a graph editor and action layers.
- **Rigging:** armatures with automatic (bone heat) weights, linear blend
  and dual quaternion skinning, pose and weight paint modes, constraints,
  IK (FABRIK / CCD, poles), drivers, shape keys, motion paths and onion
  skins.
- **Mechanisms:** CAD parts on revolute and slider joints, gears and racks,
  limits and collision checks, driven by keyed parameters.
- **Rigid bodies:** boxes, spheres, capsules, hulls and convex compounds
  with GJK / EPA contacts, persistent manifolds, islands solved in parallel,
  sleeping and joints, set up from a Physics panel.
- **Cloth and soft bodies (XPBD):** pins, colliders, self collision, wind
  and volume, with coloured constraint batches solved in parallel.
- **Simulation cache:** frames kept and played back, bakes saved in the
  file, invalidated by edits.

The exit checks:
- **`tools/fakewl.py`:** 1000 boxes tumbling into a heap simulate 10 s in
  less than 10 s.
- **`tests/animation.bees`:** builds a character (a 178,656-vertex SDF body
  skinned to a 12-bone armature, IK legs on keyed feet: a walk cycle), a
  gear pair turned by a keyed parameter, 1000 rigid boxes and a draping
  tablecloth. It bakes 10 s, saves and renders three frames.
  `tests/animation.py` checks the numbers and the reopened bake, then plays
  the saved scene in a window: each frame stepped in under 16.7 ms (60 fps).

Benchmark on a 32-thread desktop (Ryzen 9 7950X):
- **The rigged character:** a played frame of the whole walkthrough scene
  (keys, IK, skinning 178k vertices, the mechanism, the baked bodies and
  cloth) evaluates in 7.0 ms; in the window, stepped and drawn, 10.1 ms at
  the median.
- **1000 rigid boxes:** 10 s simulated in 5.9 s (4 threads: 6.7 s; 1
  thread: 8.2 s). Baked with the cloth and the rig over 239 frames in 9.0 s,
  then scrubbed back at 3.1 ms a frame.
- **Cloth:** a 6561-particle sheet colliding with a ball, the floor and
  itself simulates 4 s in 3.0 s.
- **Animation walkthrough:** 16.7 s end to end, three 480x270 frames
  rendered in 0.9 s.

### Added
- The simulation cache:
  - **Cached frames:** rigid bodies and cloth keep each whole frame as the simulation reaches it. Scrubbing back plays the cached frames instead of simulating again, and the scene's start keeps them. Cloth vertices are stored as 16 bits a coordinate within each cloth's bounds (half the memory; within 0.2 mm on a 2 m flag).
  - **Invalidation:** the cache belongs to a key made from the settings, pins, the objects' start places and meshes, and the animation (keys, layers, drivers, constraints, mechanism joints). An edit that changes the key drops it, and the simulation starts again.
  - **Bake:** `sim.bake [rigid|cloth]` simulates the frame range and keeps it whatever changes until `sim.free [rigid|cloth]`. A baked cache is saved in the `.bee` file (SIMC), and past its end it holds the last frame.
  - **Memory:** all channels share a budget (`sim.cache budget MB`, 1024 MB by default); a channel that would go over it stops recording. `sim.cache` reports what is held.
  - **Timeline:** a line under the ruler shows the cached frames, brighter when baked.
  - **Speed:** 1000 boxes scrub back at under 2 ms a frame from a 6.4 MB cache of 239 frames.
  - **BeeScript:** `cacheinfo(k)`.
- Keyframes and the timeline:
  - **Keys:** anything a script can set can be keyed: object transforms, material values, modifier parameters, node inputs and values.
  - **F-curves:** Bezier with auto-clamped handles (flat at extremes, never overshooting), linear or constant interpolation.
  - **Keys in the window:** I keys the selected objects' location, rotation and scale at the frame; Alt+I removes those keys.
  - **Frames:** setting a frame shows the scene there. Space plays (looping over the frame range at the scene's fps), Left / Right step, Shift+Left / Right jump to the ends.
  - **Timeline area:** shows the frame, the range, the ticks and the selected objects' keys; dragging in it scrubs.
  - **Storage:** keys and the range are saved in `.bee` files (ANIM) and undo with the scene.
  - **Operators:** `anim.*` (insert_key, delete_key, key, unkey, frame, play, range, interpolation).
- Armatures and skinning:
  - **Armatures:** bones (rest head, tail and roll, parents, joined chains) and poses (location, Euler rotation, scale in the bone's axes). *Create > Armature*, `arm.bone`, `arm.pose`.
  - **Armature edit mode (Tab):** click joints, G / R / S, E extrudes a joined bone, X deletes (skin weights follow).
  - **Pose mode (Ctrl+Tab):** click bones, G / R / S in their own frames, I keys them, Alt+R clears. Bone poses are animation channels (`bone:Rig:Upper:rz`).
  - **Armature modifier:** deforms a mesh by four weights a vertex, with linear blend or dual quaternion skinning, in parallel.
  - **Automatic weights:** by bone heat: each bone's heat equation is solved on the mesh, and the four strongest bones are kept. `arm.parent <mesh> <armature>` sets up both.
  - **Weight paint (Ctrl+W):** paints the active bone's weights, shown as a heat map. `paint.weight` sets the value; BeeScript has `wpaint`.
  - **BeeScript:** `armature`, `bones`, `weight`, `evpos`. Bones are saved in ARMT and weights in MWGT.
- Cloth and soft bodies (XPBD):
  - **Objects:** `cloth.add [cloth|soft|collider] [stretch c] [bend c] [volume c] [mass m] [damping d] [thickness t] [friction f] [self]` on the selected meshes. Compliances are in m/N; 0 is stiff.
  - **Constraints:** stretch on every triangle edge; bend between the far corners of triangles sharing an edge; a soft body's closed mesh also keeps its volume. Constraints are coloured into batches with no shared particle, and big batches are solved in parallel.
  - **Pins:** `cloth.pin selected | all | none | above <axis> <value> | below <axis> <value>` sets a mesh's pin group (saved in MPIN). Pinned vertices hold to the object as it moves.
  - **Collisions:** cloth keeps its thickness from collider objects' triangles (a spatial hash; very large triangles are checked by every particle) with friction. With `self` it also keeps off itself and other self-colliding cloth (a particle hash; rest neighbours are left out), resolved in parallel.
  - **Forces:** gravity (the physics world's) and wind as drag on each triangle (`cloth.world wind x y z`). Each step (60 a second) is cut into 10 substeps (`cloth.world substeps n rate n`).
  - **Timeline:** like rigid bodies it runs from the scene's start; while it runs an object shows its simulated mesh.
  - **Speed:** a 6561-particle sheet colliding with a ball, the floor and itself simulates 4 s in 3.0 s.
  - **BeeScript:** `clothinfo(k)`.
- Mechanisms for CAD assemblies:
  - **Joints:** `mech.joint <revolute|slider> <part> <parent|world> [pivot x y z] [axis x y z]` moves a part about or along an axis, relative to its parent part. The part as it is when joined is its place at 0. Parts can be chained: an arm on a gear turns with it.
  - **Values:** a joint is driven by an expression of CAD parameters, units and `frame` (`value angle`, `value crank * 2`, `value frame * 3deg`), or by another joint times a ratio (`gear 1 -2` for a gear pair; a slider from a revolute joint is a rack). `min` / `max` limits hold it, and it says when it is held. Also `mech.set`, `mech.remove`, `mech.list`.
  - **Parameters animate:** CAD parameters are animation channels (`param:angle`), so a keyed parameter moves the whole mechanism over the timeline and rebuilds the sketches and features that use it.
  - **Collisions:** after the parts move, each moving part is checked against every other mesh. A triangle edge passing strictly through the other part counts; touching faces do not. A pair that starts colliding is reported in the console. `mech.check` lists them now.
  - **BeeScript:** `joint(n [, 1])` reads a joint's value, or whether it is held at a limit; `collisions()` counts the colliding pairs.
- Rigid body physics:
  - **Bodies:** `rigid.add [active|passive] [box|sphere|capsule|hull|compound] [mass m] [friction f] [bounce b] [damping d]` on the selected objects. Active bodies fall and collide; passive ones are collided with. A thin passive box (a ground plane) gets depth below its top.
  - **Shapes:** a box, sphere or capsule; the mesh's convex hull; or a compound, where the mesh is cut into up to 16 convex parts until each is close to its hull (a ball drops through a torus's hole).
  - **Collision:** sweep and prune, then GJK and EPA on the parts. Contact manifolds of up to four points are kept between steps; for boxes and hulls more points are found by tilting one shape about the contact.
  - **Solver:** sequential impulses with warm starting, friction, restitution, speculative contacts and Baumgarte correction (overlaps part at most 1 m/s). Islands of touching or jointed bodies are solved in parallel, and an island at rest for half a second sleeps.
  - **Joints:** `rigid.joint <fixed|hinge|point> <object> <object|world> [pivot x y z] [axis x y z]`. `rigid.world` sets gravity, the step rate (120 a second) and iterations (10).
  - **Timeline:** the simulation runs as the frame passes the scene's start, from where the objects are there. Going back to the start puts them back. Settings are saved with the scene.
  - **Speed:** 1000 boxes tumbling into a heap simulate 10 s in 6.2 s on a 32-thread desktop; the slowest frame takes 34 ms of the 41.7 ms a 24 fps frame allows. On 4 threads it takes 6.7 s.
  - **Physics panel:** the Properties area has a Physics section for the active mesh. **+ Rigid Body** makes it a body. Buttons switch Active / Passive and step through the shapes. Mass, friction, bounce and damping are fields you drag. Its joints are listed with x to remove them, followed by the world's gravity, steps a second and iterations, and a line on what the simulation is doing while it plays. **x** removes the body.
  - **BeeScript:** `rigid(name, prop)` reads a body's type, shape, mass, friction, bounce or damping; `rbinfo(k)` reports bodies, contact points, awake bodies, islands, frame time, manifolds, steps and parts.
- Rigging:
  - **Object constraints:** copy location / rotation / scale (chosen axes, optionally added to the object's own), track to (an axis at the target, another up), limit location / rotation / scale, child of. Each has an influence and can be muted. They work on the object's own transform, so moving or keying a constrained object still works. `constraint.add`, `constraint.remove`, `constraint.set`, `constraint.list`.
  - **IK:** a bone's chain (any length) reaches for a target object, by FABRIK or CCD, and bends towards an optional pole object. The rest of the armature and skinned meshes follow, and so does dragging the target. `constraint.add Rig:Hand ik Goal chain 2 pole Knee`.
  - **Drivers:** a property set by an expression (with units and functions) of named other properties and `frame`, e.g. `anim.driver Door:ry a=Handle:rz a*2`. Any animation path can be driven or drive.
  - **Shape keys:** relative to the Basis, mixed before the modifiers. `shape.add Smile` stores the mesh as a key; edit, then `shape.add Smile` again stores the edit and brings the Basis back. Values (`shape:Cube:Smile`) can be keyed and driven. Saved in MSHK; constraints and drivers are saved with the animation.
  - **Motion paths:** the selected objects' (in pose mode, the selected bones') paths over the frame range, with a dot a frame and larger dots at keys. `anim.motion_paths`.
  - **Onion skins:** the active object a few frames before (red) and after (green), as wires that follow playback. `anim.onion 2 2 4`.
  - **BeeScript:** `prop(path)` (any property by its animation path), `bonepos`, `shapes`.
- Dope Sheet, Graph Editor and action layers:
  - **Dope Sheet:** a row of keys for each curve. Click selects (Shift adds), a drag moves the selected keys by whole frames, Shift+D copies them ten frames on, X deletes, A selects all or none.
  - **Graph Editor:** every curve fitted to the view, with a selected key's Bezier handles. Dragging a key moves it in frame and value; dragging a handle shapes it and makes it free.
  - **Key operators:** `anim.select_keys`, `move_keys`, `scale_keys`, `duplicate_keys`, `delete_keys`, `handle_type`, `handle`.
  - **Actions:** `anim.action <name>` keeps the selected objects' keys as a clip. `anim.layer <action> [object] [start] [influence] [replace|add] [repeat]` plays it on top of the scene, NLA-style, and `layer_set` / `layer_remove` change layers. Actions and layers are saved in the ANIM chunk. **BeeScript:** `frame`, `key`, `unkey`, `keyed`, with paths like `"Cube:x"`, `"material:Red:roughness"`, `"modifier:Cube:0:levels"` and `"node:Tree:3:5"`.

## [0.9.0] - 2026-10-13

Phase 8 of the masterplan, "Nodes & procedural". BeeModel builds geometry
from node graphs:

- **Node editor:** shader graphs and geometry node trees as boxes and
  wires, with groups and an asset library.
- **Geometry nodes:** 39 node types run by a Geometry Nodes modifier. Their
  fields compile to a block-vectorized VM, and a template JIT turns hot
  programs into AVX / SSE machine code.
- **Scattering and instancing:** a million instances, placed in
  milliseconds and drawn without being realized.
- **Curves:** Bezier and poly splines, edited in a curve edit mode and
  swept into tubes or along profiles, plus curve nodes.
- **Generators:** terrain with erosion, L-systems and wave function
  collapse.
- **Procedural co-pilot:** AI agents build node setups as proposals that
  the user accepts or reverts in one step.

The exit checks:
- **`tools/fakewl.py` (instancing):** places a million instances in under
  200 ms and orbits 100k of them in the window.
- **`tests/procedural.bees`:** builds an eroded valley with scattered rocks
  and L-system plants from one tree, a curve rail with posts from a second,
  and a meadow of a million instances from a third. It saves and renders
  the scene. `tests/procedural.py` checks the numbers, the budgets and the
  reopened file.

Benchmark on a 32-thread desktop (Ryzen 9 7950X):
- **A million instances:** placed in 13–16 ms (scattered by area, then a
  matrix each). The viewport orbits them at 11.4 ms a frame at the median
  (14.1 ms at the 95th percentile): small ones become depth-tested splats,
  near ones their triangles, binned into tiles across the threads.
- **Field programs:** 1M points x 42 instructions take 4.7 ms in the VM on
  one core, 2.0 ms compiled (AVX), and 0.3 ms compiled on all cores.
- **Procedural walkthrough:** 1.5 s end to end. That covers a 200 x 200
  terrain with 200k erosion droplets and 401 rocks and plants (0.26 s), the
  rail, the meadow, the save and a 960x540 render.

### Added
- The Node Editor area: the active material's shader graph as boxes, sockets
  and wires. Shift+A adds a node at the pointer; header drags move nodes;
  socket drags link, pick up and unplug links and drive the Material Output;
  value drags edit numbers, choices and images; X deletes; middle or
  empty-space drags pan, Home fits. Positions are kept in the material (saved
  and undone with it); unplaced nodes are laid out by depth.
- Shader graph links may go either way: the graph keeps itself in evaluation
  order and refuses loops (`material.link`). New operators
  `material.node_delete`, `material.node_move`; BeeScript `nodeinfo`.
- Geometry nodes:
  - **Modifier:** a Geometry Nodes modifier runs a node tree on the mesh
    below it.
  - **Nodes:** 15 geometry nodes (primitives, transform, join, set
    position, extrude, subdivide, boolean, merge by distance) and 10 field
    nodes (position, normal, index, value, combine / separate XYZ, math,
    vector math, noise, random).
  - **Field VM:** fields compile to programs for a block-vectorized SSE VM
    run across the job threads.
  - **Storage:** trees are saved in `.bee` files (NTRE) and undo with the
    scene.
  - **Editing:** the node editor shows the active object's tree (Tab: its
    material). Operators `tree.*`; BeeScript `gtree`, `gnode`, `glink`,
    `gset`, `ginfo`.
- Node groups: a Group node runs another tree (geometry, value and vector
  through its Group Input; fields cross the boundary; 8 levels deep).
  Shift-click and Ctrl+G make one from the selection (`tree.group`), Tab
  goes into a group and back.
- Scattering and instancing:
  - **Distribute Points on Faces:** by area and density, with a seed. An
    optional minimum distance thins the points, and the points keep their
    faces' normals.
  - **Instance on Points:** places a geometry at every point, aligned to
    the normal or up, turned at random, scaled by a field. Instances stay
    instances (a prototype and a matrix each) until *Realize Instances*.
  - **Viewport:** draws instances without realizing them. Instances under
    3 px become depth-tested squares, the others their front faces, binned
    into tiles. A million are placed in ~12 ms and orbit at ~35 ms a frame
    on 32 threads.
  - **Path tracer:** takes instances as triangles, up to 4 million.
  - **BeeScript:** `instances()`.
- Curves:
  - **Objects:** Bezier and poly splines (*Create > Bezier Curve / Bezier
    Circle / Path*, `curve.add`) with a resolution per span and, per
    point, a radius, a tilt and a handle type (auto, aligned, vector,
    free). A curve object's mesh is what the curve makes, so modifiers,
    materials, rendering and export work on it unchanged.
  - **Sweeps:** a bevel radius and sides (with caps) or a profile curve
    sweep it into a mesh. Frames are parallel transported from the world
    up, a closed path's twist is spread over it, and tilt turns them.
  - **Curve edit mode (Tab):** click / Shift-click selection of points
    and handles, G / R / S, E extrude, Ctrl+click to add a point, W
    subdivide (the shape kept), X delete, V handle type, Alt+C cyclic.
  - **Operators:** `curve.*` (add, set, point, spline, select, move,
    extrude, subdivide, delete, cyclic, handle, tilt, radius, to_mesh).
    **BeeScript:** `curve`, `cpoints`, `cpos`, `clength`.
  - **Files:** curves are saved in `.bee` files (CURV). OBJ export writes
    bare curves as `l` lines, and import reads them back as 2-point
    polygons.
  - **Curve nodes:** Curve Line, Curve Circle, Curve to Mesh (a profile
    curve or a round tube), Resample Curve, Trim Curve, Fillet Curve and
    Curve to Points (upright point normals for instancing). In geometry
    nodes a curve is a chain of 2-point polygons.
  - The node editor's Shift+A menu wraps into columns.
- Procedural generators:
  - **Terrain nodes:**
    - *Terrain* is a heightfield grid from octaves of Perlin noise, smooth (fBm) or ridged, mixed.
    - *Terrace* sets flat steps with smooth risers.
    - *Erosion* is hydraulic erosion by droplets that carry sediment down slopes and drop it where they slow, through a brush, deterministic per seed; 100k droplets on a 64 x 64 grid take ~75 ms.
  - **L-systems:** BeeScript `lsystem(name, axiom, rules, iterations, angle [, step, radius])` rewrites the axiom by rules. A 3D turtle (F f + - & ^ \ / | [ ] !) draws lines, or tubes that thin with every branch. The *L-System* node has plant, bush, tree and Koch island presets.
  - **Wave function collapse:** `wfc(name, nx, nz, layers, seed, "tiles")` fills a 2D or 3D grid with tile objects in four turns. Which tiles may touch comes from the vertices on their faces, with no rules to write. A contradiction restarts with the next seed.
- A template JIT for field programs: a program run over 1024 or more points
  is compiled to x86-64 at run time from code templates, with AVX (8 lanes)
  or SSE (4 lanes), and cached. 1M points x 42 instructions take ~2 ms on
  one core instead of ~4.7 ms in the VM. `BEEMODEL_JIT=0` / `=sse` choose
  the path. `--selftest` runs 150 random programs through the VM and both
  paths and compares every output bit.
- The procedural co-pilot (MCP):
  - **Tools:** `node_types` lists the node catalogue (sockets, values, choices, defaults). `describe_graph` and the `bee://graphs` resource give trees as JSON.
  - **Proposals:** `propose_begin` / `propose_end` / `proposal_status` let an agent build a node setup the user previews in the viewport. A banner offers Accept (Enter) and Revert (Esc); the proposal is one undo step either way.
  - **Prompt:** the MCP prompt `procedural` gives an agent this flow for a goal.
- Assets: `tree.save_asset` (with the groups the tree runs) and
  `material.save_asset` write to `~/BeeModel/assets`; `asset.load` adds one
  to any scene, `asset.list` lists them; the Asset Browser area adds one
  with a click.

## [0.8.0] - 2026-10-13

Phase 7 of the masterplan, "Sculpting, texturing & UV". BeeModel sculpts
dense meshes and paints them:

- **Sculpting:** a sculpt mode for meshes of tens of millions of vertices,
  with eleven brushes, pen pressure, a stabilizer, dynamic topology and
  multiresolution levels.
- **UVs:** seams, LSCM unwrapping, smart projection, packing and a UV
  editor with a distortion heat map.
- **Painting:** texture painting through the UVs (in the viewport and the UV
  editor) on layers, and vertex colours.
- **Baking:** normal, ambient occlusion and curvature maps from a high-poly
  mesh to a low-poly one with the path tracer's BVH, and a `normalmap`
  shader node that uses them.

The exit checks:
- **`tests/sculpt20m.py`** sculpts a 25.2M-vertex mesh in the window with
  four strokes.
- **`tests/sculpt_paint.bees`** sculpts a creature head and bakes it into a
  light head's maps. It then paints the light head on two layers, gives a
  pedestal vertex colours, saves everything to one `.bee` file and renders
  it. `tests/sculpt_paint.py` checks every step and the reopened file.

Benchmark on a 32-thread desktop (Ryzen 9 7950X):
- **Strokes at 60 fps on 25.2M vertices:** frames that place brush dabs
  (brush work plus drawing) take 11.2 ms at the median and 15.8–16.4 ms at
  the 95th percentile, under the 16.7 ms of 60 fps. Frames in between take
  2.3 ms to draw. During a stroke only the BVH leaves the brush changed are
  projected again, and only the screen tiles they cover (where they were
  and where they are) are drawn again.
- **Memory:** the mesh as BeeModel keeps it takes 2.76 GB, and the whole
  process while sculpting takes 2.82 GB (1.02×). The peak, while entering
  sculpt mode, is 3.6 GB (1.3×). Measured against the bare data (positions
  plus quad indices, 672 MB) the process takes 4.2×: the general mesh
  format's per-loop data is most of it, and slimming it is future work.
- **Sculpt and paint walkthrough:** 5.5 s end to end. That covers ten
  strokes on 127k vertices, 1024² normal, AO and curvature maps in 0.75 s
  together, 288 paint dabs, the save and a 960×540 render.

### Added
- Sculpt mode (Ctrl+Tab):
  - **Structure:** BVH leaves of about a thousand triangles, per-vertex
    normals, and undo steps that store only the moved vertices.
  - **Brushes:** draw, clay strips, crease, inflate, grab, snake hook,
    smooth, flatten, pinch, layer and mask; X symmetry.
  - **Drawing:** cached splat records per leaf, drawn in parallel screen
    tiles. During a stroke each leaf keeps its splat density, and only the
    tiles of the changed leaves are drawn again; the rest comes from a copy
    of the last frame.
  - **Input:** tablet pressure (strength / radius, three curves), the
    eraser end and a stroke stabilizer.
  - **Dynamic topology** (Ctrl+D): longest-edge splits and safe collapses
    to a detail size in pixels.
  - **Multiresolution:** per-level displacements, sculpting at any level,
    propagation to coarser levels, saved in `.bee` files.
  - **BeeScript:** `sculpt`, `frames`, `frametime` (`frametime(k, 1)`: a
    frame's brush work).
- UV maps:
  - **Seams:** marked or from sharp edges.
  - **Unwrapping:** least squares conformal maps (own sparse CG solver) and
    smart projection, with islands packed into the unit square.
  - **UV editor:** island selection, move / scale / rotate, and an
    area / angle distortion heat map.
  - **Files:** OBJ `vt` and glTF `TEXCOORD_0`.
- Textures through UVs in the material preview and the path tracer;
  `image.new`; images saved inside `.bee` files as PNG.
- Texture painting (Shift+Tab):
  - **Strokes:** projected viewport strokes that paint only what is
    visible, plus strokes in the UV editor, with an undo history.
  - **Layers:** opacity, normal / multiply / add blending and visibility,
    with the stack saved in `.bee` files.
- Vertex colours (Shift+V):
  - **Shading:** per triangle in solid view, smooth in the preview and the
    path tracer.
  - **Files:** OBJ `v x y z r g b`, glTF `COLOR_0` and `.bee`.
- Baking (`object.bake`, `bake(...)`):
  - **Maps:** tangent-space normal maps, ambient occlusion (48 rays) and
    curvature.
  - **Method:** a cage distance and dilated island borders. A bake is one
    texture-paint undo step.
- A `normalmap` shader node: a tangent-space normal map (as baking writes
  it) tilts the shading normal in the preview and the path tracer.
- `tests/sculpt20m.py` and `tests/sculpt_paint.py` in CI.

### Fixed
- Drawing a mesh of more than ~45M triangles in object mode overflowed
  the rasterizer's triangle buffer (a 32-bit size) and crashed. Huge
  meshes now draw the triangles that fit in half the frame arena.

## [0.7.0] - 2026-10-13

Phase 6 of the masterplan, "CAD & digital fabrication". BeeModel designs
parts to make:

- **Parametric parts:** parameters with units drive constrained sketches.
- **Features:** pads, pockets, holes, shells, fillets and patterns, in a
  tree that rebuilds whenever anything changes.
- **Implicit shapes:** signed-distance blends and lattices.
- **Output:** 3MF for printers, DXF / SVG of sketches, and PDF drawings.

The exit check, `tests/enclosure.bees`, designs an electronics enclosure
from dimensioned sketches: a filleted, shelled case with a cable hole, and
a lid with a fitted lip and vents. All dimensions are parameters. Changing
the width (80 to 100 mm) rebuilds everything, and both 3MF files are read
by lib3mf in strict mode and sliced by PrusaSlicer in CI.

Benchmark on a 32-thread desktop:
- **Enclosure:** both bodies (10 features) are built, rebuilt after the
  parameter change and exported twice as 3MF plus a PDF drawing in
  0.65 s in total.
- **Gyroid lattice:** a 96-cell mesh (250k triangles) in 0.1 s.
- **Gyroid infill:** an infill for a 60 × 40 × 30 mm shelled box in
  0.3 s.

### Added
- The feature tree:
  - **Features:** pad (symmetric / reverse), pocket (through / reverse /
    symmetric), revolve (full or partial), hole (at a sketch's loose
    points), shell (open top or bottom), fillet and chamfer with edge
    selectors (all / vertical / horizontal / top / bottom), linear and
    circular patterns, and infill.
  - **How it works:** features live in the CAD document (undo, `.bee`)
    and refer to bodies and sketches by persistent object ids. The tree
    replays in order with exact booleans and bevels after any change.
  - **Values and status:** values may be expressions. Each feature
    reports a status (ok, missing sketch, no profile, geometry failed,
    ...), and a feature that would open a closed body fails without
    changing it.
  - **Where to see it:** Properties and `scene_summary`.
  - **BeeScript:** `pad pocket revolve hole shell fillet chamfer pattern
    infill feature features fstatus`.
- Profiles from sketches (`prof.s`):
  - **Loops:** closed loops with welded ends, arcs and circles
    tessellated, and even-odd nesting into material and holes.
  - **Caps:** ear clipping with hole bridging (n-gon caps when there is
    no hole).
  - **Solids:** prisms, revolutions and inward offsets.
- Measurement and mass properties:
  - **Tool:** the measure tool (Shift+M) snaps to vertices or the
    surface and gives the distance with its components, and the angle at
    a middle point.
  - **Mass properties:** area, volume, centre of mass and mass, from a
    new per-material `density` (g/cm^3), in world space and scene units.
  - **Reporting:** `object.measure` sends them to the console, the
    status bar and agents.
  - **BeeScript:** `area mass centroid fangle measurement`.
- The SDF / F-rep kernel (`sdf.s`):
  - **Shapes:** sphere, box (rounded), cylinder, torus, and gyroid and
    strut-grid lattices.
  - **Operations:** smooth union, subtraction and intersection, shells,
    moves and turns, and extruded profiles.
  - **Meshing:** the field is sampled on all threads and meshed by
    marching tetrahedra, so the result is always closed and manifold.
  - **BeeScript:** `ssphere sbox scyl storus sgyroid sgrid sunion ssub
    sisect sshell smove srot sdist smesh sclear`.
- Fabrication output:
  - **3MF:** a zip written by our own code (deflate, CRC-32) with every
    mesh in millimetres, Z up.
  - **DXF and SVG** of a sketch (construction geometry on its own layer
    or dashed).
  - **PDF drawings:** front, top and right views in third-angle
    projection with hidden lines dashed (a depth buffer per view),
    sharp and silhouette edges, overall dimensions and a title block,
    written by hand with an exact xref.
- Printability:
  - **Wall thickness:** measured per face with rays through a triangle
    grid. *View › Show Thin Walls* colours faces under the minimum red
    and under twice it yellow.
  - **Print check:** `mesh.print_check` reports whether the part is
    closed, the thinnest wall, the overhang area (excluding the bed) and
    the size.
  - **BeeScript:** `thinnest()`.
- `tests/enclosure.py`: the walkthrough, checked by our own 3MF reader,
  by lib3mf (strict) and by PrusaSlicer. It runs in CI and in
  `ci/local.sh`.
- Sketches with a constraint solver:
  - **Sketch objects:** a new object type on the XY, XZ or YZ plane (with
    an offset), placed by the object's transform. It holds points, lines,
    circles and arcs in a copy-on-write block that undo shares.
  - **Constraints:** coincident, horizontal, vertical, parallel,
    perpendicular, equal, tangent, fixed, distance (also horizontal /
    vertical), length, radius, diameter, angle, point on line / circle,
    midpoint and symmetric. Dimensions may be expressions, so parameters
    drive them.
  - **Solver:** damped Gauss-Newton (Levenberg-Marquardt) in doubles,
    one connected group of unknowns at a time. The Jacobian's rank gives
    the degrees of freedom left and which points and entities are fully
    constrained. Equations that stay unsatisfied are conflicts.
  - **Sketch mode** (Tab):
    - tools: L lines (chains reuse points and level / plumb segments
      become horizontal / vertical), O circles, R rectangles;
    - click to select, drag points as the sketch solves;
    - constraint keys C H V E P N T F M, D for a dimension typed on the
      command line (expressions too), X to delete;
    - entities coloured by status, constraint labels, and a status line
      with the DOF.
  - **Scripts and files:**
    - BeeScript `sketch`, `point`, `line`, `circle`, `arc`, `rect`, `pt`,
      `con`, `dof`, `conflicts`, `sx`, `sy`, `sr`, `skinfo`;
    - sketches re-solve when parameters or units change;
    - saved in `.bee` (SKCH);
    - shown in Properties and to agents in `scene_summary`.
- Parameters, expressions and scene units, the base of the CAD phase:
  - **Units:** `scene.units mm|cm|m|in` sets what one scene unit is
    (metres by default).
  - **Expressions:** `+ - * / ^`, parentheses, units (`mm cm m in ft`
    for lengths in scene units, `deg rad` for angles), `pi`, `e`, and
    sin cos tan asin acos atan sqrt abs floor ceil round min max.
  - **Parameters:** `param.set <name> <expression>` (for example
    `width = 10*wall + 2mm`), `param.remove`, `param.list`. Values are
    evaluated on demand and cached. A cycle, a syntax error or an
    unknown name is refused, and the scene keeps its last good state.
  - **Where they live:** parameters belong to a copy-on-write CAD
    document that undo shares, like the materials, and that is saved in
    `.bee` (CADD chunk). Properties lists them with their values.
  - **Scripts and agents:** BeeScript `param(name [, expression])` and
    `expr(text)`; `scene_summary` shows the units and the parameters.

### Changed
- Booleans:
  - **Edge points:** a point within 1e-7 of an edge's length splits it
    in the triangulation. A constraint through a vertex is split there.
  - **Classification:** rays walk a grid of triangles, so large meshes
    classify in milliseconds. Flat triangles are not crossed.
  - **Capacity:** room for more intersection segments.
- Feature booleans clean their result: vertices closer than 1e-4 of the
  size are welded and flat triangles go into their neighbours, so chains
  of booleans stay robust.
- `mesh_finish` fans skip flat ears, so polygons with corners in a line
  triangulate without zero-area triangles.
- Bevels:
  - partial edge sets with several segments are manifold;
  - the faces at a rounded edge's ends take the arc;
  - rounded edges meeting at a corner share it.

## [0.6.0] - 2026-10-13

Phase 5 of the masterplan, "Materials & rendering". BeeModel renders:

- **Materials:** principled materials, optionally with shader graphs.
- **Hive:** a CPU path tracer with a denoiser and HDRI lighting.
- **Render window:** stays interactive while it refines.
- **Files:** readers and writers for the usual image formats, and glTF.

A product-shot benchmark runs in CI. It renders a studio scene (car paint,
gold, glass, a light strip, a noise-bumped plinth) to convergence: 32
samples plus the denoiser stay within 4.5 levels RMS of a 512-sample
reference. At 1920 × 1080 that takes about 5 s on 32 threads (the budget is
10 s, scaled to the runner's cores). The same scene also renders at 1080p in
the Render area while the viewport is orbited, with a median frame time of
about 15 ms.

### Added
- The product-shot scene (`tests/product_shot.bees`) and its benchmark
  (fakewl `product_shot`).
- The render's resolve (tone mapping into the Render area) runs on all
  cores and only redoes the rows that have new samples. While a 1080p render
  runs, frames take about 15 ms on 4 threads.
- glTF 2.0 and MTL:
  - **Export:** `file.export_gltf <path>` writes `.glb` (binary chunks)
    or `.gltf` (base64 buffer). Mesh objects become nodes with
    translation, a quaternion from our Euler angles, and scale, plus u32
    triangles and positions with bounds. Materials become
    metallic-roughness PBR with emission (KHR_materials_emissive_strength
    above 1), transmission, IOR and clearcoat. Blender reads the files.
  - **Import:** `file.import_gltf <path>` reads `.glb` and `.gltf` with
    embedded, `data:` or external buffers. It walks the default scene's
    node tree (TRS or matrices) and bakes each triangle primitive's world
    transform into a new object. Equal positions are welded, so meshes
    stay connected, and materials map back with their extensions.
  - **MTL with OBJ:** OBJ import reads `mtllib` and assigns the first
    `usemtl`. The MTL reader handles Kd, Ke, Ni, d / Tr, Ns (to
    roughness), Tf, the PBR keys Pr / Pm / Pc / Pcr and map_Kd (the image
    becomes the base colour).
- Shader graphs: a material can hold up to 12 nodes.
  - **Nodes:** image, noise (Perlin fBm), checker, gradient, mix (mix /
    add / multiply / subtract / screen), colour ramp, math (ten
    operations) and bump.
  - **Sockets:** nodes drive the base colour, metallic, roughness,
    emission and the normal.
  - **Evaluation:** Hive and the material preview evaluate graphs per
    shading point. Coordinates are object space, or the box projection
    for images. Bump re-evaluates the graph a little along the
    triangle's edges and tilts the normal (Blinn).
  - **Safety:** links only point to earlier nodes, so graphs cannot loop.
  - **Editing:**
    - BeeScript `node`, `link`, `nodeset`, `socket`;
    - operators `material.node / link / node_set / socket / nodes_clear`;
    - every change is undoable.
  - **Agents:** `scene_summary` shows each graph (nodes, values, inputs,
    links, sockets).
  - **Files:** graphs are saved in `.bee` (MGRF; damaged graphs are
    cleared).
  - **Textures:** `material.texture` now builds a one-node graph.
  - **Records:** material records are now 1 KiB in memory. The MATS chunk
    keeps its 128-byte records, so 0.5 files still open.
- Image textures and an HDRI world:
  - **Textures:** `material.texture <material> <image|none> [size]` gives
    a material a base-colour image. Until UVs arrive it is box-projected in
    object space (per face, by its normal) and sampled bilinearly and
    repeating, with 8-bit images decoded from sRGB. Hive and the material
    preview both show it.
  - **HDRI world:** `world.hdri <image|none>`, `world.strength`,
    `world.rotation` light the scene with an equirectangular image instead
    of the studio sky and sun.
    - Hive importance-samples the HDRI through a 2D CDF (luminance ×
      sin θ) with MIS. In a flat HDRI a white diffuse sphere vanishes (the
      white-furnace test).
    - The material preview takes irradiance from 9 spherical-harmonic
      coefficients and reflections from a blurred copy, and turns off its
      softboxes.
  - **Files:** `.bee` keeps the image paths (IMGS, reloaded in order;
    missing files keep their place) and the world (WRLD).
  - **Agents:** `scene_summary` lists the images, each material's texture
    and the world.
- Image files, all with our own code:
  - **inflate:** stored, fixed and dynamic Huffman blocks, with a 10-bit
    lookup table.
  - **PNG reader:** every colour type and bit depth, all five filters,
    Adam7 interlacing and tRNS.
  - **JPEG decoder:** baseline (SOF0/1), any chroma subsampling, restart
    markers, SSE float IDCT, libjpeg-style fancy upsampling. It matches
    Pillow to within 3 levels.
  - **Radiance HDR reader:** RGBE, RLE or flat, top-down or bottom-up.
  - **OpenEXR writer:** half floats, ZIP blocks (predictor + deflate).
    `oiiotool` reads the files.
  - **Commands:** `image.load` / `image.save` (PNG or EXR);
    `render.save <path>.exr` writes linear passes.
  - **BeeScript:** `image(path)`, `imgsize`, `imgpixel`.
  - **Agents:** image commands need file access.
  - **Tests:** `tests/image_io.py` checks 30 PNG variants exactly, eight
    JPEG kinds against Pillow, HDR exactly and EXR round trips.
- A denoiser for Hive renders: an edge-avoiding à-trous wavelet filter
  (after Dammertz et al. and SVGF):
  - **Guides:** the albedo, normal and depth passes. It filters the
    lighting only (radiance ÷ albedo), so colours and edges stay sharp.
  - **Strength:** set by the noise. A per-pixel variance comes from the
    luminance moments of the samples, so converged renders pass through
    almost unchanged.
  - **Results:** 16 samples + denoise get about as close to the reference
    as 256 samples. 1080p denoises in about 50 ms.
  - **Where:** Render › Denoise (`render.denoise`, on by default, saved
    in `.bee`) denoises a render when it finishes or is stopped;
    `render.image <path> w h spp 1` and `render(path, w, h, spp, 1)` too.
- The Render window:
  - **F12** (Render › Render) starts a progressive render in a Render area
    beside the viewport, opening the area if needed. The main loop spends
    about 14 ms of each turn on more samples, in bands of rows, so the UI
    stays live at any resolution. **Esc** (or Render › Stop) stops it.
  - **Status line:** size, samples so far, time and the shown pass.
  - **Passes:** albedo, normal and depth from the first hit, next to the
    beauty pass. `render.pass` switches between them, and
    `render.save <path> [pass]` writes any of them as PNG.
  - **Settings:** `render.settings <w> <h> <samples>` (default
    960 × 540 × 128), saved in `.bee` (RNDR chunk).
  - **Agents** can start, stop and inspect renders with edit access;
    saving needs file access.
  - **Editor type:** Render is a new editor type (`area.type_render`).
- Materials with principled parameters:
  - base colour, metallic, roughness, specular, IOR;
  - transmission;
  - emission and its strength;
  - clearcoat and its roughness;
  - alpha.

  Where they appear:
  - **Scene:** one material table, shared with undo (copy-on-write), and
    a per-object assignment.
  - **Properties › Material:** + New, drag the name to pick another
    material, drag values, x to remove.
  - **Viewport:** solid shading shows the base colour.
  - **Files:** saved in `.bee` (MATS and OMAT chunks) and exported as
    MTL with OBJ.
  - **Scripts and agents:** BeeScript `material`, `matset`, `matget`,
    `assign`, `matof`; the `material.new / assign / set / remove`
    operators; materials in `scene_summary`.
- Hive, a path tracer (CPU, all cores):
  - **Scene and BVH:** a world-space triangle soup with auto-smoothed
    normals, and a binned-SAH BVH collapsed to 4-wide nodes traversed with
    SSE.
  - **Light transport:** path tracing with next-event estimation and
    multiple importance sampling over the studio sky (cosine), a sun disc,
    light objects (points) and emissive triangles (area × power).
  - **Materials:** the principled BSDF covers Lambert, GGX reflection
    (metallic workflow), rough dielectric transmission with Fresnel and
    total internal reflection, and clearcoat.
  - **Sampling:** Russian roulette and a firefly clamp.
  - **Output:** progressive passes into a float buffer, ACES resolve,
    `render.image` and BeeScript `render()`. Agents need file access to
    render.
  - **Tests:** a white-furnace energy check, a convergence check and a
    time budget.
- Material preview, a viewport mode (View › Material Preview, Shift+Z):
  - every pixel is shaded with its object's principled material (Lambert +
    GGX specular with Fresnel, clearcoat, approximate transmission,
    emission);
  - lighting is a studio environment (sky / ground, split-sum
    approximation) plus three softbox lights, then ACES tone mapping;
  - the rasterizer now keeps a visibility buffer (the triangle of each
    pixel), and the shading pass works from it;
  - per-corner normals smooth faces closer than 30°, so cubes stay sharp
    and spheres look round;
  - a 300k-triangle scene orbits in about 6 ms on 32 threads, with a CI
    budget.

### Changed
- The screenshot moved from F12 to **Shift+F12**; F12 now renders.

### Fixed
- Hive's table of its own mappings had room for 8 entries but accepted 16.
  Renders that needed a ninth buffer (the denoiser's, a file's) could
  overwrite the variables after it.
- Hive's per-triangle texture data (box UVs) were not reordered with the
  BVH's leaf order, so textures on multi-triangle meshes came out
  scrambled. The object-space data that replaces them is reordered.

## [0.5.0] - 2026-10-13

Phase 4 of the masterplan, "Polygon modeling". BeeModel becomes a modeler: edit
mode with the usual tools, adjustable last operations, a modifier stack,
robust booleans, and mesh analysis and repair.

A hard-surface walkthrough runs in CI on every change. It builds a part from
the keyboard and the menus:

1. a pocket (inset, extrude);
2. a through hole (boolean);
3. rounded edges (Bevel modifier).

It checks that the part is closed, then saves, reopens and exports it.

### Added
- Edit mode (Tab) for mesh objects:
  - vertex, edge and face select modes (1 / 2 / 3);
  - click, Shift+click, select all / none (A), invert (Ctrl+I), box select
    (B, Ctrl subtracts), edge loops (Alt+click) and select linked (Ctrl+L);
  - G / R / S on the selection, with axis constraints, snapping, typed values
    and gizmos;
  - overlays (edges, vertex dots, face dots, a tint on selected faces) that are
    depth tested against the rasterizer's depth buffer, so hidden elements are
    neither drawn nor picked.

  Geometry is copy-on-write, so undo snapshots keep the previous mesh.
- BeeScript mesh functions: `edit`, `verts`, `edges`, `faces`, `vpos`,
  `selected`, `vsel`, `vselect`, `volume`.
- Mesh operators (edit mode, Mesh menu). Each one is a single undo step.
  - **Building:** extrude region (E, slides along the normal), extrude edges,
    extrude individual faces (Alt+E), inset (I), duplicate (Shift+D),
    subdivide.
  - **Removing:** delete vertices / edges / faces (X), dissolve into n-gons
    (Ctrl+X).
  - **Merging:** at center (M), collapse, by distance.
  - **Faces and normals:** fill / make face (F), flip normals, recalculate
    normals (Shift+N, consistent and outwards).

  Scripts and agents pass the distance as the operator argument.
- More modeling tools:
  - **loop cut** (Ctrl+R): a hover preview, the wheel sets the number of
    cuts; scripts pass an edge and a count;
  - **bevel** (Ctrl+B): the width is dragged or typed, the wheel adds
    segments for round profiles, and corner patches close the gaps where
    beveled edges meet;
  - **knife** (K) for cuts through the visible faces, and **bisect** for a
    plane cut; both use one plane-cut core;
  - **bridge edge loops** between two boundary loops;
  - **spin**, which sweeps a profile around the 3D cursor (steps, angle,
    axis).
- Modifier stack: Mirror, Array, Solidify, Subdivision Surface, Bevel,
  Decimate and Remesh.
  - Non-destructive and cached per object.
  - Edited in the Properties editor (add, toggle, reorder, apply, remove,
    drag values); undoable.
  - Saved in `.bee` files (MODS chunk).
  - Scriptable: `modifier`, `modset`, `modapply`, `modremove`, `modcount`,
    `everts`, `efaces`.
  - Shown to agents in `scene_summary`.

  Subdivision is a parallel Catmull–Clark with cached topology. On a
  102,400-quad mesh, level 3 (6.5 M faces) builds in about 125 ms, and an
  edit updates it in about 19 ms.
- BeeScript: `vmove` (move a vertex) and `clock()`.
- Mesh booleans: union, difference and intersection that stay exact on
  degenerate input (faces on faces, edges on edges, identical meshes,
  angles typed to six decimals).
  - Edit › Boolean Union / Difference / Intersect and `object.boolean
    union|difference|intersect [keep]` combine the active mesh with another
    selected one, as one undo step.
  - A Boolean modifier reads another object's mesh and follows it when that
    object moves; it is saved in `.bee` files.
  - BeeScript `boolean(a, b, kind)` and `manifold(name)`.
  - Exact integer predicates with a symbolic perturbation. Faces lying on
    each other resolve as expected: a flush cut goes through, touching
    solids fuse, and A − A is empty.
  - A stress corpus runs in CI. It checks the volume identities and closed
    results on 300 cases (general position, coincident and identical
    operands). A sphere with 63k triangles minus one with 16k takes about
    40 ms.
- Performance budgets for the modeling core run in CI
  (`tests/perf_modeling.bees`). The local times are:

  | Operation | Size | Time |
  |---|---|---|
  | Subdivision build | 508k faces | ~11 ms |
  | Subdivision update | same mesh | ~1 ms |
  | Analysis | 127k faces | ~10 ms |
  | Repair | 127k faces | ~75 ms |
  | Boolean | 254k triangles | ~170 ms |
- Redo panel: adjust the last operation. Extrude, individual extrude,
  inset, bevel, loop cut, merge by distance and spin report their values.
  Drag or scroll a value, use F9 to type, or call `edit.redo_last
  "values"` (also for agents): the operator runs again from its undo
  snapshot and stays one undo step.
- 3D cursor: Shift+right click places it on the surface or the ground; new
  objects are created there. View › Reset 3D Cursor puts it back.
- Keys can depend on the mode (operator flags `OPF_EDIT` / `OPF_OBJECT`):
  X, A, F and Shift+D mean the mesh versions in edit mode. Home resets the
  camera in either mode.
- Mesh analysis and repair.
  - **Overlays** for the active mesh (View › Show …), with counts in the
    viewport:
    - face normals;
    - non-manifold edges (more than two faces, or two facing the same way);
    - boundary edges;
    - degenerate faces;
    - overhangs (faces facing down steeper than 45°, or a given angle).
  - **Edit › Repair Mesh** (`mesh.repair [distance]`), in object or edit
    mode, as one undo step. It merges by distance, removes degenerate and
    duplicate faces, fills holes, makes the normals consistent and
    outward, and drops loose vertices, then reports what it changed.
  - BeeScript `analyze(name, what)` for scripts and agents.

### Changed
- Meshes store a vertex selection and a triangle-to-polygon map.

### Fixed
- Cylinder and cone caps and the whole torus were wound inwards, and the
  plane and grid faced down. All primitives now face out (up).
- Bevel (the tool and the modifier) is fixed for widths larger than nearby
  edges, such as around a hole cut by a boolean, where thin triangles meet
  the beveled edge:
  - offsets are clamped so neighbouring corner points never cross;
  - the strips across beveled edges are oriented from the topology, not
    from their shape.

  The result stays closed.

## [0.4.0] - 2026-10-13

Phase 3 of the masterplan, "AI-native layer": AI agents become first-class
users of BeeModel. They can see, script and edit the scene, under
permissions the user controls, and the user can revert their changes.

### Added
- MCP server for AI agents. The running app listens on
  `$XDG_RUNTIME_DIR/beemodel.sock`, and `beemodel --mcp-bridge` connects
  Claude Code / Claude Desktop over stdio. Tools: `scene_summary`,
  `create_primitive`, `set_transform`, `select`, `delete`, `run_operator`,
  `undo`, `redo`, plus every agent-safe operator as `op_<id>`. Resource:
  `bee://scene`. Agent edits are undoable and echoed in the console.
- `viewport_capture` MCP tool. The UI is rendered off-screen, so the image
  shows the scene right after the agent's last edit. The tool returns an MCP
  image block holding the viewport (or the whole window) as a PNG.
- BeeScript, a scripting language compiled in one pass to bytecode for a
  stack VM. It has numbers with units (`2m`, `45deg`), texts, variables, `if`,
  `while`, `for i in 0..n`, functions and recursion, plus scene, math and text
  builtins. Reference: `docs/BEESCRIPT.md`.
  - Console lines that are not operator ids run as BeeScript, with REPL-style
    echo; variables and functions persist between lines.
  - A script run is one undo step: undo now supports grouped changes.
  - Macro recording (Edit → Record Macro) saves operators, selection clicks
    and G/R/S results as BeeScript in `~/BeeModel/scripts/macro.bees`;
    `script.run` plays a macro or any `.bees` file back.
  - `script_eval` MCP tool. Agent scripts may only run agent-safe operators.
  - `beemodel --eval 'code'` / `--run file.bees` run scripts without a window.
- Safe agent edits:
  - **Permission tiers** (read-only / edit / files), set in the new AI menu
    and enforced for every tool, `run_operator` and `script_eval`. The
    default is edit, so file access must be granted by the user. The status
    bar shows the tier and how many agents are connected.
  - **Change sets.** Each agent request is one undo step, labeled
    `Agent: <tool>`. Undo steps now keep their own copy of the label.
  - **AI Activity editor** (AI → AI Activity Pane, or any area's editor
    menu). It lists recent agent calls and has a one-click
    **Revert last agent change** button (`agent.revert`).
- Own JSON reader / writer, with a strict RFC 8259 validator for incoming
  messages.
- MCP conformance suite in CI. It drives a full session through
  `--mcp-bridge` like Claude Code does, and checks:
  - tool schemas and the result shape of every curated tool;
  - JSON-RPC error codes (-32700 / -32600 / -32601);
  - id echo, split writes and 60 KiB requests;
  - UTF-8 round trips and concurrent clients.
- `docs/MCP.md`: connecting Claude Code / Claude Desktop, and the tools,
  permissions and protocol details.

### Changed
- `--list-ops` no longer truncates long descriptions.
- PNG files are now compressed. The encoder picks a Sub or Up filter per row
  and then deflates the data (LZ77 plus fixed Huffman codes). A 1280×800
  screenshot drops from about 3 MB to about 150 KB.
- `.bss` is excluded from transparent huge pages, so the large, mostly idle
  script buffers cost no memory until they are used.

## [0.3.0] - 2026-10-12

Phase 2 of the masterplan, "Scene, viewport & files": BeeModel becomes a
small but real 3D editor.

### Added
- Scene with real objects: a Blender-like default scene (Camera, Light,
  Cube); objects have a name, location, rotation, scale and a mesh.
- Polygon meshes with n-gons, derived edges and triangles; primitives: cube,
  plane, grid, UV sphere, cylinder, cone, torus.
- Selection: click in the viewport or the outliner (Shift extends), A to
  select all / none; X / Delete removes, Shift+D duplicates (unique names
  like Cube.001).
- The outliner lists the scene's objects and scrolls; Properties shows the
  active object's transform and mesh statistics.
- Solid shading: a multithreaded tile rasterizer (parallel setup, binning
  and rasterization, SSE 4-pixel edge functions, depth and object-ID
  buffers) with Blender-style selection outlines. About 1.2 M triangles
  render in 8–9 ms at 1280×800 on 32 threads, with output identical for any
  thread count. Z toggles wireframe.
- Exact click picking from the ID buffer.
- Modal transforms like Blender's: G / R / S with X/Y/Z constraints, Ctrl
  snapping (1 m, 15°, 0.1), typed values, Enter / LMB to confirm and Esc /
  RMB to cancel. Move / Rotate / Scale tool gizmos can be dragged.
- Undo / redo (Ctrl+Z / Ctrl+Shift+Z) for create, delete, duplicate and
  transforms. Snapshots share reference-counted meshes; the history is
  bounded (256 steps / 64 MiB). Edit › Undo History lists the steps.
- Files: native `.bee` save / open (chunked, atomic writes, validated on
  load), OBJ import / export, STL import (binary + ASCII, welded) / export,
  PNG screenshots (F12), autosave every 25 changes, `file.recover`. The
  title bar shows the current file.
- Operators accept a text argument from the command line
  (`file.save ~/x.bee`); without one, the command line opens pre-filled.
- Shift+D shares the mesh with the original (copy-on-write arrives with
  edit mode), so duplicates cost almost no memory.
### Fixed
- Keymap parser: the word "aliases" inside the keycodes section name was
  taken for an `alias` statement, which swallowed the Escape and **1** keys
  (& on AZERTY). Digits now all type correctly.

### Changed
- G, R and S now start transforms (Blender layout). The grid toggle moved to
  Shift+G, and the tools to Shift+Q / W / E / R.
- Binary size budget raised from 64 KiB to 256 KiB (now ~67 KB); the
  masterplan target remains < 2 MB for v1.0.
- Arenas keep memory that is in use resident instead of releasing it every
  frame (released after sustained low use).

## [0.2.0] - 2026-10-12

Phase 1 of the masterplan, "Foundations": the runtime every modeling feature
will build on.

### Added
- Operator spine: every action is declared once with the `OPERATOR` macro and
  collected by the linker into one table. Menus, tool buttons, check marks,
  shortcut labels and the keymap are all driven by it.
- `--list-ops` prints every operator (id, key binding, label, description).
- New key bindings: T (tools pane), N (outliner pane), F1 (shortcut list in the
  console), Ctrl+N/O/S/Z, Ctrl+Shift+Z.
- docs/ARCHITECTURE.md: modules, calling convention, how to add an operator.
- Real keyboard support without libxkbcommon: the XKB keymap sent by the
  compositor is parsed in assembly. Shift / Caps Lock / AltGr levels and dead
  keys (accents) work for any layout.
- Layout-aware shortcuts: bindings follow the key label, so Ctrl+Z is Undo on
  AZERTY and QWERTZ keyboards too.
- Key repeat using the compositor's rate and delay (timerfd).
- Console command line: a UTF-8 text field with caret, selection (Shift,
  Ctrl+A), history (Up/Down) and Tab completion of operator ids. Enter runs any
  operator by id.
- New operators: console.focus (Enter), console.clear (Ctrl+L),
  console.list_ops.
- TrueType text, with no FreeType: our own TrueType parser (cmap 4/12,
  composite glyphs), an anti-aliased signed-area rasterizer, a glyph cache and
  alpha blending. The UI uses a proportional sans font and the console a
  monospace font, both loaded from the system (Noto / DejaVu / Liberation).
- Full Unicode text (UTF-8): accented and international characters display
  correctly. `BEEMODEL_FONT` / `BEEMODEL_MONO_FONT` select fonts; `none`
  keeps the bitmap font.
- HiDPI / fractional scaling (`wp_fractional_scale_v1` + `wp_viewporter`):
  the UI renders natively at 125%, 150%, 200% and other scales, with crisp
  text and geometry instead of compositor upscaling.
- Job system: worker threads on every core (raw `clone` + `futex`, 0% CPU
  when idle) and `parallel_for` with atomic chunk claiming; the viewport
  background is already filled in parallel. `BEEMODEL_THREADS` limits the
  thread count.
- Memory: bump arenas (per frame and per thread, giving memory back to the
  kernel after spikes) and pools with generational handles.
- `--selftest`: built-in tests for the allocators and the job system, plus a
  benchmark (12× faster with 32 threads on the reference machine). Runs in
  CI.
- Area system like Blender's: the window is a tree of resizable areas. Each
  area has a header to switch its editor (3D Viewport, Tools, Outliner,
  Properties, Console) and to maximize (Ctrl+Space), split side by side or
  top/bottom, or close it. Each viewport has its own camera.
- Command palette (F3): fuzzy search over every command, showing its id and
  shortcut. Up/Down select, Enter runs.

### Changed
- Tools / Outliner / Console toggles (T, N, View menu) now add and remove
  areas; the Properties pane is now its own area.

### Testing
- Golden-image regression tests (pixel diff against `tests/golden`).
- Performance and memory budgets checked in CI: first frame in about 4 ms,
  median input-to-frame latency about 0.6 ms at 1280×800, about 2.3 MiB of
  private memory.

### Changed
- Source split into separate modules (object files) with explicit exports.
- Help › Keyboard Shortcuts is generated from the operator table.
- Redo is now Ctrl+Shift+Z.

## [0.1.0] - 2026-10-12

First release: the application shell that the 3D modeling tool will be built on.

### Added
- Native Wayland client in pure x86-64 assembly with no libraries: raw syscalls and
  a hand-written wire protocol (`wl_compositor`, `wl_shm`, `xdg_wm_base`, `wl_seat`,
  `wp_cursor_shape_v1`).
- Title bar drawn by the app: move by dragging, double-click to maximize,
  minimize/maximize/close buttons, edge resizing for floating windows.
- Menu system with File, Edit, View, Create and Help dropdowns, hover switching,
  check marks and shortcut hints.
- Resizable Tools, Outliner/Properties and Console panes with draggable splitters;
  each pane can be shown or hidden from the View menu.
- 3D viewport canvas: orbit/pan/zoom camera, perspective projection with near-plane
  and Liang–Barsky clipping, ground grid, axes, orientation gizmo and a demo cube.
- Status bar, console log, keyboard shortcuts (Q/W/E/R, G, F, Esc, Ctrl+Q).
- `--version` and `--help` command-line flags.
- Event-driven rendering paced by frame callbacks: 0% CPU when idle, double-buffered
  shared-memory framebuffer, about 60 KB of private memory.
- `build.sh`, `run.sh` and `package.sh` scripts.
- Headless test harness (fake Wayland compositor) and GitHub Actions CI and release
  pipelines.

[Unreleased]: https://github.com/bartbeecoders/beemodel/compare/v0.10.0...HEAD
[0.10.0]: https://github.com/bartbeecoders/beemodel/compare/v0.9.0...v0.10.0
[0.9.0]: https://github.com/bartbeecoders/beemodel/compare/v0.8.0...v0.9.0
[0.8.0]: https://github.com/bartbeecoders/beemodel/compare/v0.7.0...v0.8.0
[0.7.0]: https://github.com/bartbeecoders/beemodel/compare/v0.6.0...v0.7.0
[0.6.0]: https://github.com/bartbeecoders/beemodel/compare/v0.5.0...v0.6.0
[0.5.0]: https://github.com/bartbeecoders/beemodel/compare/v0.4.0...v0.5.0
[0.4.0]: https://github.com/bartbeecoders/beemodel/compare/v0.3.0...v0.4.0
[0.3.0]: https://github.com/bartbeecoders/beemodel/compare/v0.2.0...v0.3.0
[0.2.0]: https://github.com/bartbeecoders/beemodel/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/bartbeecoders/beemodel/releases/tag/v0.1.0
