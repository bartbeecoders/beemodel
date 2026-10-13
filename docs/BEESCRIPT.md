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
| `gnode(tree, type [, values...])` | Adds a node; returns its number (numbers never change). Types: `input`, `output`, `grid` (size, subdivisions), `cube` (size), `sphere` (radius), `cylinder` (radius, depth), `line` (count, offset x y z), `transform` (rotation x y z degrees; inputs 2 translation, 3 scale), `join`, `set_position` (inputs: geometry, selection, offset), `extrude` (distance), `subdivide` (level), `boolean` (0 union 1 difference 2 intersect), `merge` (distance), `realize`, `position`, `normal`, `index`, `value` (value), `combine_xyz`, `separate_xyz`, `math` (op 0 add .. 14 modulo), `vector_math` (op 0 add 1 subtract 2 multiply 3 scale 4 cross 5 dot 6 length 7 normalize 8 distance 9 mix), `noise` (scale, detail, roughness; outputs fac, color), `random` (min, max, seed), `group` (the tree it runs, by number; inputs geometry, value, vector - inside, the Group Input's three outputs) |
| `glink(tree, from, to, input [, output])` | Feeds output 0.. of `from` into input 1..3 of `to`; a loop is an error |
| `gset(tree, node, slot, x [, y, z])` | An input's constant (slots 1-3) or a value (4-7) |
| `ginfo(tree, node, what [, k])` | As `nodeinfo`, for a tree: `"count"`, `"type"`, `"link"`, `"output"` (which output the link into input k takes), `"x"`, `"y"`, `"value"` |
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
