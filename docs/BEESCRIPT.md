# BeeScript

BeeScript is BeeModel's built-in scripting language. You can use it in three places:

* **The console.** Any line that is not an operator id runs as BeeScript. Variables and functions stay defined between lines, like a REPL.
* **Macros.** **Edit → Record Macro** (`script.record`) turns what you do into a script, and `script.run` plays it back.
* **Agents.** The `script_eval` MCP tool runs BeeScript for an AI agent.

It is compiled to bytecode in one pass and runs on a small stack VM, both written in assembly (`src/script.s`). A whole run is **one undo step**, however many changes it makes.

```
# a row of ten cubes, 2 m apart, each a little taller
for i in 0..10 {
    c = add("cube", "Step" + i, i * 2m, 0, 0)
    scale(c, 1, 1 + i * 0.2, 1)
}

fn ring(n, r) {
    for i in 0..n {
        a = i * 360deg / n
        add("sphere", "R" + i, cos(a) * r, 1, sin(a) * r)
    }
}
ring(12, 6m)
```

## Values

| Type | Examples | Notes |
|---|---|---|
| number | `3`, `2.5`, `1e-3`, `45deg`, `20cm` | 64-bit floats |
| text | `"Box"`, `'it\'s'` | escapes: `\n` `\t` `\"` `\'` `\\` |
| nil | `nil` | "no value" |

* `true` and `false` are `1` and `0`; `pi` is π.
* `nil`, `0` and `""` count as false. Everything else is true.

### Units

A unit written straight after a number is converted when the script is read:

| Unit | Converts to |
|---|---|
| `m` | meters (1) |
| `cm`, `mm`, `km` | meters (0.01, 0.001, 1000) |
| `deg` | radians: `45deg` is `0.785…` |
| `rad` | radians (1) |

Lengths are in meters and angles in radians, so `90deg / 1deg` is `90`.

## Syntax

```
x = 1                 # assignment; also += -= *= /=
a + b  a - b  a * b  a / b  a % b      # % takes the sign of the divisor
"Box" + 3             # "Box3": + joins whenever one side is a text
== != < <= > >=       # comparisons give 1 or 0
and  or  not          # and / or short-circuit and return an operand

if x > 2 { ... } else if x > 1 { ... } else { ... }
while x < 10 { x += 1 }
for i in 0..10 { ... }          # 0, 1, ... 9
break  continue

fn area(w, h) { return w * h }  # top level only; can call itself
```

* Statements end at a newline or `;`.
* Inside `( )` a newline is just a space.
* `#` starts a comment that runs to the end of the line.

### Variables

* Top-level variables are global and persist across console lines.
* Inside a function, assigning to a name makes a local variable. Reading a name that has no local falls back to the global.

## Built-in functions

### Scene

| Function | What it does |
|---|---|
| `add(type, [name], [x, y, z])` | Adds a `cube`, `sphere`, `cylinder`, `cone`, `torus`, `plane`, `grid`, `light` or `camera`; returns its name |
| `move(name, x, y, z)` | Sets the location |
| `rotate(name, x, y, z)` | Sets the Euler XYZ rotation, in radians (`rotate(c, 0, 45deg, 0)`) |
| `scale(name, x, y, z)` | Sets the scale; `scale(name, s)` scales uniformly |
| `get(name, prop)` | Reads `x` `y` `z` (location), `rx` `ry` `rz` (rotation) or `sx` `sy` `sz` (scale) |
| `set(name, prop, value)` | Writes one of those properties |
| `select(names...)` | Selects exactly these objects; the last one is active. `select()` deselects all |
| `delete(names...)` | Deletes the objects |
| `rename(old, new)` | Renames an object; returns the unique name it got (`Box.001`) |
| `exists(name)` | 1 if an object has that name, else 0 |
| `count()` | The number of objects |
| `name(i)` | The name of the `i`-th object in the outliner, starting at 0 |
| `active()` | The active object's name, or `nil` |
| `op(id, [arg])` | Runs any operator, e.g. `op("file.save", "~/a.bee")` or, in edit mode, `op("mesh.extrude", 2)`. Modeling operators take their values as text: `op("mesh.bevel", "0.2 3")`, `op("mesh.loopcut", "0 1 2")` (an edge as two vertex indices, plus the number of cuts), `op("mesh.bisect", "0 1 0  0 1 0")` (a world point and normal), `op("mesh.spin", "16 360 x")` |
| `edit(name)` / `edit()` | Enters edit mode on a mesh (it becomes active) / leaves edit mode |
| `verts(name)` `edges(name)` `faces(name)` | Mesh sizes |
| `vpos(name, i, axis)` | A vertex coordinate in object space; axis is `0`-`2` or `"x"` / `"y"` / `"z"` |
| `selected(name)` | How many vertices are selected (the edit-mode selection) |
| `vsel(name, i)` / `vsel(name, i, flag)` | 1 if vertex `i` is selected / select or deselect it |
| `volume(name)` | Signed mesh volume; it is negative when the normals point inwards |
| `vmove(name, i, x, y, z)` | Moves a vertex (object space) |
| `vselect(name, i...)` | Selects exactly these vertices; `vselect(name)` deselects all |
| `boolean(a, b, kind)` | `a` becomes `a` union / difference / intersect `b` (`"union"`, `"difference"`, `"intersect"`); `b` is deleted. One undo step |
| `manifold(name)` | 1 if the mesh is closed and consistently oriented (every edge used once in each direction) |
| `analyze(name, what)` | Counts `"boundary"` edges (one face), `"nonmanifold"` edges (more than two faces, or two facing the same way), `"degenerate"` faces (no area), `"loose"` vertices (no face) or `"overhang"` faces (facing down steeper than 45°, or the angle `view.show_overhangs` was given) |
| `material(name)` | The material with that name, created (with default values) if there is none; returns its name |
| `matset(mat, param, value [, g, b])` | Sets a material value: `base`, `metallic`, `roughness`, `specular`, `ior`, `transmission`, `emission`, `strength`, `clearcoat`, `coat_roughness`, `alpha`, `density` (g/cm^3, for mass). Colours (`base`, `emission`) take three numbers, linear 0-1 |
| `matget(mat, param [, component])` | Reads one material value |
| `assign(object, mat)` | Gives a mesh a material; `""` removes it |
| `matof(object)` | The name of its material, or `nil` |
| `image(path)` | Loads a PNG, JPEG or Radiance HDR image into the scene; returns its name |
| `imgsize(image, axis)` | Width (axis 0) or height (1) |
| (textures, world) | `op("material.texture", "Wood " + img + " 0.5")`, `op("world.hdri", sky)`, `op("world.strength", 2)` |
| `sketch(name, plane [, offset])` | A new sketch object on the `"XY"`, `"XZ"` or `"YZ"` plane; returns its name |
| `point(s, x, y)`, `line(s, x1, y1, x2, y2)` or `line(s, p1, p2)`, `circle(s, cx, cy, r)`, `arc(s, cx, cy, r, from, to)`, `rect(s, x, y, w, h)` | Sketch geometry (numbers or expressions); return point / entity indices. `rect` adds its corner, horizontal and vertical constraints and returns the first of its four lines |
| `pt(s, entity, which)` | An entity's point: line 0 start, 1 end; circle 0 centre; arc 0 centre, 1 start, 2 end |
| `con(s, type, a [, b [, c]] [, value])` | A constraint: `coincident`, `horizontal`, `vertical`, `parallel`, `perpendicular`, `equal`, `tangent`, `fixed`, `distance`, `hdistance`, `vdistance`, `length`, `radius`, `diameter`, `angle`, `online`, `oncircle`, `midpoint`, `symmetric`. Point constraints take point indices, the others entities; dimensions end with a value or an expression text (kept, so parameters drive it) |
| `dof(s)`, `conflicts(s)`, `sx(s, p)`, `sy(s, p)`, `sr(s, e)`, `skinfo(s, "points" \| "entities" \| "constraints")` | The solved sketch: degrees of freedom left, conflicting constraints, coordinates, radii, sizes |
| `param(name [, expression])` | Sets a parameter (an expression with units, e.g. `"10*wall + 2mm"`, or a number) and returns its value in scene units; with one argument, reads it |
| `expr(text)` | Evaluates an expression with units and parameters (lengths in scene units, angles in radians) |
| `pad(body, sketch, distance [, "symmetric" \| "reverse"])` | Extrudes the sketch's closed profiles along its normal into the body (a mesh object, made when missing); returns the feature's index |
| `pocket(body, sketch, depth [, "through" \| "reverse" \| "symmetric"])` | Cuts the profiles into the body, down from the sketch |
| `revolve(body, sketch, angle [, "u" \| "v"])` | Turns the profiles about the sketch's u (default) or v axis; a full turn closes |
| `hole(body, sketch, diameter [, depth])` | A hole at every loose point of the sketch (no depth: through) |
| `shell(body, pad, wall [, "bottom"])` | Hollows a pad: walls of that thickness, open at the top (or the bottom) |
| `fillet(body, radius [, edges])`, `chamfer(body, size [, edges])` | Rounds / cuts the body's sharp edges: `"all"` (default), `"vertical"`, `"horizontal"`, `"top"` or `"bottom"` (Y is up) |
| `pattern(body, feature, count, step, axis [, "circular"])` | Repeats an earlier pad, pocket, hole, revolve or shell along `"x"`, `"y"` or `"z"` (step = spacing), or about that axis through the origin (step = the total angle; 0 = a full turn) |
| `feature(i, slot, value)` | Changes a feature's value: slot 0 the first value (distance, depth, diameter, wall, radius, step), 1 the second (a hole's depth), 3 suppressed (1) or not (0); returns its status |
| `area(object)`, `mass(object)`, `centroid(object, axis)` | Mass properties in world space and scene units: surface area, mass in grams (volume x the material's `density` in g/cm^3; no material: 1), centre of mass (`"x"`, `"y"`, `"z"` or 0..2) |
| `fangle(object, face a, face b)` | The angle between two faces' normals (radians; `deg()` converts) |
| `thinnest(object)` | The thinnest wall (scene units): from every face straight in to the next face; `nil` when nothing is behind any face |
| `sculpt(object, brush, x1, y1, z1, x2, y2, z2, radius, strength)` | A sculpt stroke from one world point to the other (enters sculpt mode on the object): `"draw"`, `"clay strips"`, `"crease"`, `"inflate"`, `"grab"`, `"snake hook"`, `"smooth"`, `"flatten"`, `"pinch"`, `"layer"` or `"mask"`; radius in scene units, strength 0..1 (negative inverts). One undo step |
| `unwrap(object [, "smart"])` | UV-unwraps the mesh: least squares conformal maps along its seams (or a smart projection of faces facing alike), islands packed into 0..1; returns the islands |
| `uvpack(object)` | Packs its UV islands again: same texel density, smallest boxes, inside 0..1 |
| `seams(object, "mark" \| "clear" \| "sharp" \| "none")` | UV seams: mark / clear the edges between selected vertices, every edge sharper than 30 degrees, or none; returns the seam edges |
| `uvstat(object, what)` | A measure of its UVs: `"islands"`, `"angle"` (mean angle distortion, degrees), `"area"` (area distortion, 0..2), `"flipped"` (triangles turned over), `"overlap"` (share of UV area covered twice), `"inside"` (1: all in 0..1); -1 without UVs |
| `frames()`, `frametime(k [, 1])` | How many frames have been drawn; how long the k-th last one took to draw (0 = the latest, up to 255 back), in milliseconds; with 1: the input work before it (sculpt strokes) |
| `measurement()` | The measure tool's current result (Shift+M in the viewport): the distance between two clicked points, the angle at the middle one of three (radians), or `nil` |
| `infill(body, shell, "gyroid" \| "grid", cell, wall)` | A lattice filling a shell's cavity (reaching a quarter wall into the walls), kept as its own closed shell in the body; slicers join overlapping shells |
| `features()`, `fstatus(i)` | The number of features; a feature's status: 0 ok, 1 sketch missing, 2 no closed profile, 3 the geometry failed, 4 a value does not evaluate, 5 nothing to work on, 6 bad reference, 7 suppressed, 8 body missing |
| `node(material, type [, values...])` | Adds a shader node and returns its number (1..12). Types: `image` (image name, size), `noise` (scale, detail, roughness), `checker` (scale), `gradient` (axis 0/1/2, scale, offset), `mix` (mode 0 mix 1 add 2 multiply 3 subtract 4 screen), `ramp` (position 0, position 1), `math` (op 0 add 1 subtract 2 multiply 3 divide 4 power 5 min 6 max 7 greater 8 sine 9 abs), `bump` (strength, distance), `normalmap` (strength; input 1: a tangent-space normal map's image node) |
| `nodeinfo(material, node, what [, k])` | Reads the graph: `"count"`, `"type"` (1 image .. 9 normalmap), `"link"` (the node feeding input k), `"socket"` (the node driving socket k, 0 base .. 4 normal), `"x"` / `"y"` (its place in the node editor; node 0 is the output), `"value"` (value k, 1..4); -1 when there is none |
| `gtree(name)` | The geometry node tree with that name (made when there is none); returns its number for `modset(object, i, "tree", t)` |
| `gnode(tree, type [, values...])` | Adds a node; returns its number (numbers never change). Types: `input`, `output`, `grid` (size, subdivisions), `cube` (size), `sphere` (radius), `cylinder` (radius, depth), `line` (count, offset x y z), `transform` (rotation x y z degrees; inputs 2 translation, 3 scale), `join`, `set_position` (inputs: geometry, selection, offset), `extrude` (distance), `subdivide` (level), `boolean` (0 union 1 difference 2 intersect), `merge` (distance), `realize`, `position`, `normal`, `index`, `value` (value), `combine_xyz`, `separate_xyz`, `math` (op 0 add .. 14 modulo), `vector_math` (op 0 add 1 subtract 2 multiply 3 scale 4 cross 5 dot 6 length 7 normalize 8 distance 9 mix), `noise` (scale, detail, roughness; outputs fac, color), `random` (min, max, seed), `group` (the tree it runs, by number; inputs geometry, value, vector - inside, the Group Input's three outputs), `distribute` (density, seed, minimum distance; output: points with normals), `instance` (rotation 0 fixed / 1 random, align 0 up / 1 normal, seed; inputs points, instance, scale), `curve_line` (inputs: start, end), `curve_circle` (resolution, radius; in the XZ plane), `curve_to_mesh` (radius, sides, fill caps; inputs curve, profile curve), `resample` (count, or length between points), `trim` (start, end: factors of the length), `fillet` (radius, segments a corner), `curve_to_points` (count; 0: the points as they are), `terrain` (size, resolution, height, seed; input "noise" = scale, detail, ridged 0..1), `terrace` (steps, smooth), `erode` (droplets, strength, seed; on a grid such as the terrain's), `lsystem` (preset 0 plant 1 bush 2 tree 3 Koch island, iterations, radius - 0: lines, step). A curve is a chain of 2-point polygons; the Group Input of a curve object's modifier is its curve |
| `glink(tree, from, to, input [, output])` | Feeds output 0.. of `from` into input 1..3 of `to`; a loop is an error |
| `gset(tree, node, slot, x [, y, z])` | An input's constant (slots 1-3) or a value (4-7) |
| `ginfo(tree, node, what [, k])` | As `nodeinfo`, for a tree: `"count"`, `"type"`, `"link"`, `"output"` (which output the link into input k takes), `"x"`, `"y"`, `"value"` |
| `curve(kind [, name])` | A new curve object at the origin, selected and active; returns its name. Kinds: `"bezier"` (two points), `"circle"` (four, closed), `"path"` (a poly spline of five), `"empty"`. Then `op("curve.point", "x y z")` adds points (object space) to its spline, `op("curve.spline", "poly cyclic")` starts another, `op("curve.set", "bevel 0.1")` / `"sides 8"` / `"fill 1"` / `"resolution 12"` / `"profile Ring"` / `"cyclic 1"` sets values, and `curve.select`, `curve.move`, `curve.extrude`, `curve.subdivide`, `curve.delete`, `curve.handle`, `curve.tilt`, `curve.radius`, `curve.to_mesh` edit it |
| `cpoints(name)`, `cpos(name, i, axis)`, `clength(name)` | A curve's control point count (-1: not a curve); control point i's `"x"`, `"y"` or `"z"` (object space; `nil` when there is none); the length of what it makes |
| `lsystem(name, axiom, rules, iterations, angle [, step [, radius]])` | A new object drawn by an L-system: `rules` like `"X=F+[[X]-X]-F[-FX]+X; F=FF"` rewrite the axiom `iterations` times (at most 8 million characters), then a turtle starting at the origin heading up reads it: `F`/`G` draw a step, `f` moves, `+ -` turn, `& ^` pitch, `\ /` roll by `angle` degrees, `\|` turns round, `[ ]` open and close a branch (thinner by 0.7), `!` thins. Without a radius: lines (a curve for the curve nodes); with one: hexagonal tubes. Returns its name |
| `wfc(name, nx, nz, layers, seed, tiles)` | Wave function collapse: a new object of tile objects (`tiles`: their names in one text, up to 16) on an nx x nz grid, `layers` high. A tile is its object's mesh, turned and scaled like the object (wherever it stands), in a cell from -0.5 to 0.5 on each axis; with its four quarter turns. Two tiles fit side by side (or on top) when the vertices on their touching faces coincide. Returns its name, or `nil` when no arrangement is found in 20 tries |
| `frame([n])` | The frame the scene shows; with `n`, goes there first (every keyed property takes its value at that frame) |
| `key(path, frame [, value [, interpolation]])` | Keys a property at a frame (no value: its value now; interpolation `"bezier"` (default: auto-clamped handles), `"linear"` or `"constant"`); returns how many keys its curve has. Paths: `"Cube:x"`, `y`, `z`, `rx` .. `rz` (radians), `sx` .. `sz`; `"material:Red:roughness"` (`:k` picks a colour component); `"modifier:Cube:0:levels"` (index, parameter); `"node:Tree:3:5"` (tree, node, slot 1-3 an input's constant (`:k` a component), 4-7 a value); `"bone:Rig:Upper:rz"` (a bone's pose: `x` .. `sz` in its own axes); `"shape:Cube:Smile"` (a shape key's value); `"param:angle"` (a CAD parameter: keyed, it rebuilds what uses it) |
| `unkey(path, frame)` | Removes that key (1 when there was one) |
| `keyed(path, frame)` | The value the property's curve gives at a frame, `nil` when it has none |
| `armature([name])` | A new armature (one bone, `Bone`, from the origin up 1 m), selected and active; returns its name. Bones: `op("arm.bone", "Upper Bone 0 1 0 0 2 0")` (name, parent or `-`, head, tail; a head on the parent's tail joins them); poses: `op("arm.pose", "Upper rot 0 0 90")` (`loc` / `rot` degrees / `scale`, in the bone's own axes); skinning: `op("arm.parent", "Body Rig")` (an Armature modifier and automatic weights; add `dual` for dual quaternions), `modset(mesh, i, "mode", 1)` |
| `bones(name)` | An armature's bone count (-1: not an armature) |
| `clothinfo(k)` | The cloth simulation: 0 cloths, 1 particles, 2 constraints, 3 colours in use, 4 the last frame's simulation time (ms), 5 collisions in the last step, 6 collider triangles. Set up with `op("cloth.add", "cloth")` on the selected meshes (`soft`, `collider`; `stretch` / `bend` / `volume` compliances, `mass`, `damping`, `thickness`, `friction`, `self`), `op("cloth.pin", "above x 0.95")` and `op("cloth.world", "wind 0 0 5 substeps 10")`; `evpos` reads the simulated vertices |
| `joint(n [, 1])` | Mechanism joint n's value (1..; radians or scene units), with 1: 1 when it is held at a limit; nil when there is no such joint. Joints: `op("mech.joint", "revolute Gear1 world axis 0 1 0 value angle")`, `op("mech.joint", "revolute Gear2 world axis 0 1 0 gear 1 -2")`, `op("mech.joint", "slider Rack world axis 1 0 0 gear 1 1 min -1 max 1")`; key a parameter with `key("param:angle", 1, 0)` |
| `collisions()` | How many pairs of parts collide now (each moving part against every other mesh) |
| `rigid(name, prop)` | An object's rigid body setting: `"type"` (1 active, 2 passive), `"shape"` (0 box, 1 sphere, 2 capsule, 3 hull, 4 compound), `"mass"`, `"friction"`, `"bounce"`, `"damping"`; nil when it is not a body |
| `cacheinfo(k)` | The simulation cache: 0 rigid body frames, 1 cloth frames, 2 MB in use, 3 rigid bodies baked, 4 cloth baked, 5 full, 6 the budget (MB). Frames are kept as `frame(n)` simulates and played back when it goes back; `op("sim.bake")` keeps the frame range (`rigid`, `cloth`), `op("sim.free")` lets it go, `op("sim.cache", "budget 2048")` sets the memory budget |
| `vgstat(k)` | The last frame's drawing through cluster DAGs: 0 objects drawn through DAGs, 1 clusters drawn, 2 their triangles, 3 clusters culled by the frustum, 4 occluded in the last frame's depth, 5 of those drawn after all, 6 the objects' source triangles, 7 MB of cluster pages in memory, 8 the budget (MB, `op("vgeo.budget", "2048")`), 9 pages on their way, 10 pages read in all, 11 pages given back in all, 12 refinements waiting for pages, 13 ms for the cuts, 14 streamed DAGs, 15 the error allowed (pixels, `op("vgeo.error", "1")`), 16 with `op("vgeo.view", "check")`: the first object's cut crack-free (1, 0; -1: not all of it in view) |
| `view(yaw, pitch, distance, x, y, z)` | Sets the viewport camera: degrees round and above its target `x y z`, metres from it |
| `vgeo(name, k)` | An object's cluster LOD DAG (`op("vgeo.build")`): 0 state (0 none, 1 building, 2 ready, 3 out of date), 1 clusters, 2 levels, 3 groups, 4 source triangles, 5 the top level's triangles, 6 build ms, 7 KB, 8 the largest error, 9 roots, 10 / 11 the most triangles / vertices in a cluster, 12 every cut crack-free (1), 13 triangles in all clusters, 14 level 0 clusters; 100 + L, 200 + L, 300 + L: level L's triangles, clusters, largest error |
| `rbinfo(k)` | The rigid body simulation: 0 bodies, 1 contact points, 2 awake bodies, 3 islands, 4 the last frame's simulation time (ms), 5 manifolds, 6 steps, 7 parts. Bodies come from `op("rigid.add", "active box")` on the selected objects (`passive`; `sphere` `capsule` `hull` `compound`; `mass` `friction` `bounce` `damping`), joints from `op("rigid.joint", "hinge Door world pivot 0 1 0 axis 0 1 0")` (`fixed`, `point`), the world from `op("rigid.world", "gravity 0 -9.81 0 rate 120 iterations 10")`; `frame(n)` simulates up to frame n |
| `bonepos(armature, bone, axis)` | Where a bone's tail is, posed (IK too), in the world |
| `prop(path)` | What any property is now, by its animation path (`"Cube:x"`, `"shape:Cube:Smile"`, ...); nil when the path names nothing |
| `shapes(name)` | A mesh's shape keys, the Basis too (0: none). Make them with `op("shape.add", "Smile")` (stores the mesh as it is; edit it, then `shape.add` again stores the edit and brings the Basis back), set them with `op("shape.set", "Smile 0.5")` or key `"shape:Cube:Smile"` |
| `weight(mesh, vertex, bone)` | A vertex's skin weight for a bone (by number, 0..) |
| `wpaint(mesh, x, y, z, radius, bone, weight)` | Paints skin weight for a bone around a world point (one undo step); 0 when the mesh has no armature |
| `evpos(mesh, vertex, axis)` | A vertex's position as shown: after modifiers (skinning, ...); `vpos` gives the base mesh's |
| `instances(name)` | How many instances the object's evaluated mesh carries (geometry nodes) |
| `link(material, from, to, input)` | Feeds node `from` into input 1..3 of node `to` and returns `to`'s number (either order: the graph re-sorts itself, so linking backwards renumbers nodes; a loop is an error) |
| `nodeset(material, node, slot, x [, y, z])` | Sets an input's constant (slots 1-3; one value fills all three) or a value (slots 4-7 = the type's values above) |
| `socket(material, socket, node)` | Drives `base`, `metallic`, `roughness`, `emission` or `normal` (a bump or normalmap node) by a node; `nil` unplugs |
| `imgset(image, x, y, r, g, b [, a])` | Sets an 8-bit image's pixel (0..255); the image is then saved inside `.bee` files |
| `paint(object, x, y, z, radius [, r, g, b])` | A dab of texture paint around that world point (radius in scene units, colour 0..255, else the brush colour) on the object's material image; one stroke in the paint history; 0 when there is no image to paint |
| `layer(image, op [, layer [, value]])` | Paint layers: `"count"`, `"add"` (a transparent layer above, made active; returns its number), `"active"` (with a layer: paint it; without: which one), `"opacity"` (0..1), `"blend"` (0 normal, 1 multiply, 2 add), `"visible"` (0 / 1), `"remove"`, `"merge"` (flatten into the image) |
| `vpaint(object, x, y, z, radius [, r, g, b])` | Vertex paint around that world point (one undo step) |
| `vcol(object, vertex, channel)` | A vertex colour's red, green, blue or alpha (0..3; 0..255), -1 without colours |
| `bake(low, high, kind, image [, distance])` | Bake the high mesh's `"normal"`, `"ao"` or `"curvature"` map into the image through the low mesh's UVs (cage distance: 5% of the low mesh's size unless given); the texels baked, -1 without UVs or for a float image. Undo: `op("paint.undo")` |
| `uvmap(object, su, sv, du, dv)` | Every UV of the mesh becomes (u su + du, v sv + dv): tiling, offsets |
| `imgpixel(image, x, y, channel)` | A pixel's red, green, blue or alpha (0..3): 0..255 for 8-bit images, linear values for HDR |
| `render(path [, width, height, samples, denoise])` | Path-traces the scene with Hive into a PNG (the camera object, or the viewport's view), denoised when `denoise` is 1; returns the milliseconds. Defaults 640 x 360, 64 samples, no denoising |
| `modifier(name, type)` | Adds `mirror`, `array`, `solidify`, `subsurf`, `bevel`, `decimate`, `remesh`, `boolean`, `multires` or `geometry` (geometry nodes: `modset(name, i, "tree", t)` picks the tree); returns its index. A boolean takes the other selected mesh as its object |
| `modset(name, i, param, value)` | Sets a value, e.g. `modset(c, 0, "levels", 3)`; an object value is a name: `modset(c, 0, "object", "Cutter")` |
| `modapply(name, i)` / `modremove(name, i)` | Applies a modifier to the mesh / removes it |
| `modcount(name)` | Number of modifiers in the stack |
| `everts(name)` / `efaces(name)` | Vertex and face counts after the modifiers |
| `clock()` | Milliseconds (monotonic), for timing |

Rigging runs through operators: `op("constraint.add", "Cube copy_location Target axes xz")` (also
`copy_rotation`, `copy_scale`, `track_to` (`track -z up y`), `limit_location` / `limit_rotation` /
`limit_scale` (`min x y z max x y z`, rotations in degrees), `child_of`, and on a bone `ik`:
`op("constraint.add", "Rig:Hand ik Goal chain 2 pole Knee solver fabrik")`), `constraint.remove`,
`constraint.set <n> influence 0.5`. Drivers: `op("anim.driver", "Door:ry a=Handle:rz a*2 + sin(frame/10)")`.
Constraints and drivers apply before each builtin a script calls, so it reads their results.

The modifier values are:

| Modifier | Values |
|---|---|
| mirror | `axis` (0-2), `merge` |
| array | `count`, `x`, `y`, `z` (offset relative to the size) |
| solidify | `thickness` |
| subsurf | `levels` |
| bevel | `width`, `segments`, `angle` |
| decimate | `ratio` |
| remesh | `voxel` |
| boolean | `object` (a name), `operation` (0 union, 1 difference, 2 intersect) |
| multires | `levels` (1-6), `level` (the one shown and sculpted; 0 the base) |

```
add("cube", "Plate", 0, 0, 0)
scale("Plate", 2, 0.2, 2)
for i in 0..4 {
  add("cylinder", "Hole", i - 1.5, 0, 0)
  scale("Hole", 0.3, 1, 0.3)
  boolean("Plate", "Hole", "difference")
}
print(faces("Plate"), manifold("Plate"))
```

Features make a parametric part: values may be expression texts, so every
feature follows the parameters and sketches it uses, and the whole tree
rebuilds in order whenever one of them changes:

```
op("scene.units", "mm")
param("w", "60mm")
param("wall", "2mm")
s = sketch("Base", "XZ")
r = rect(s, 0, 0, 60, 40)
con(s, "length", r, "w")
b = pad("Box", s, "30mm")
fillet("Box", "3mm", "vertical")
shell("Box", b, "wall")
f = sketch("Front", "XY")
point(f, 30, 15)
hole("Box", f, "5mm", "4mm")
param("w", "80mm")              # the box grows, rounds and holes follow
```

Fillets and chamfers work on the faces next to the edges they round; a face
that a hole or pocket has turned into a ring cannot take a round yet, so
round edges before cutting into the faces next to them (the feature then
reports status 3 and leaves the body as it was).

### Signed-distance shapes

Shapes made of signed distance fields (numbers are shape ids; lengths may be
expressions with units). They combine smoothly and turn into closed meshes:

| Function | Shape |
|---|---|
| `ssphere(r)`, `sbox(x, y, z [, rounding])`, `scyl(r, height)`, `storus(R, r)` | Primitives at the origin (full sizes; cylinder and torus about Y) |
| `sgyroid(cell, wall)`, `sgrid(cell, strut diameter)` | Endless lattices (intersect them with a solid before meshing) |
| `sunion(a, b [, k])`, `ssub(a, b [, k])`, `sisect(a, b [, k])` | Booleans; `k` > 0 blends them over that radius |
| `sshell(a, wall)` | A wall of that thickness centred on the surface |
| `smove(a, x, y, z)`, `srot(a, rx, ry, rz)` | Moved / turned copies (radians, Euler XYZ) |
| `sdist(a, x, y, z)` | The signed distance at a point (negative inside) |
| `smesh(name, a [, cells])` | A new mesh object: the shape sampled on a grid (`cells` along the largest side, default 64, at most 512, in parallel) and meshed by marching tetrahedra - always closed and manifold |
| `sclear()` | Forgets every shape (ids start again) |

```
b = sunion(smove(ssphere(1), 0, 1.6, 0), sbox(2.4, 1.2, 2.4, 0.2), 0.5)
smesh("Knob", ssub(b, smove(scyl(0.4, 6), 0, 1, 0)), 96)
```

### Math and text

| Function | What it does |
|---|---|
| `sin` `cos` `tan` `atan2(y, x)` | Trigonometry, in radians |
| `sqrt` `pow(x, y)` `abs` `floor` | Usual math |
| `round` | Rounds half up |
| `min(...)` `max(...)` | Smallest or largest of the arguments |
| `deg(x)` `rad(x)` | Converts radians to degrees, and degrees to radians |
| `rand()` | A random number in `[0, 1)` |
| `seed(n)` | Makes `rand()` repeatable |
| `print(...)` | Prints its arguments, separated by spaces |
| `str(x)` | Converts a value to text |
| `num(text)` | Converts text to a number; units are allowed: `num("2cm")` is `0.02`. Returns `nil` if the text isn't a number |
| `len(text)` | The length of a text |

## Console, macros and the command line

**Console**

* An operator id runs the operator, as before: `file.save ~/a.bee`.
* Anything else is BeeScript.
* If the last statement is an expression, its value is echoed (`= 42`).

**Macros**

1. Run `script.record` (Edit → Record Macro). The status-bar dot turns red.
2. Work as usual. Each scene operator becomes `op("…")`. Each selection click becomes `select(…)`. Each finished G / R / S becomes `move` / `rotate` / `scale` with the final values.
3. Run `script.record` again. The macro is saved to `~/BeeModel/scripts/macro.bees`.
4. `script.run` plays it back. `script.run <file>` runs any `.bees` file.

**Command line**

`beemodel --eval 'code'` and `beemodel --run file.bees` run a script against the default scene without opening a window. Output goes to stdout. The exit code is 1 on errors.

`script.reset` forgets all variables and functions.

## Limits and safety

* **Endless loops.** A run stops after 500 million VM steps, about half a second.
* **Recursion.** Calls nest at most 2048 deep.
* **Source size.** A script can be up to 64 KiB.
* **Operators a script can't run:** undo / redo (the script is itself one undo step), interactive transforms (`transform.*`) and `script.*` operators.
* **Agent scripts** (`script_eval`) may only run operators marked agent-safe. For example, `op("file.exit")` is refused.
* **Errors** report the line, for example `error: line 3: no object named Box`. Changes made before the error stay, and remain one undo step.
