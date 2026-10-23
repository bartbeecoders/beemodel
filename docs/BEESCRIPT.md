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
| number | `3`, `2.5`, `.5`, `1e-3`, `45deg`, `20cm`, `0xff8800` | 64-bit floats; `0x` hexadecimal (up to 15 digits, no unit) |
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

### Grammar

The whole language, as the compiler in `src/script.s` reads it. `{ }` in the rules
means "zero or more", `[ ]` "optional", and quoted text is written as is.

```
script     = { sep } { statement sep { sep } } [ statement ]
sep        = NEWLINE | ";"
statement  = fndef                                   (top level only)
           | "if" expr block { "else" "if" expr block } [ "else" block ]
           | "while" expr block
           | "for" NAME "in" expr ".." expr block
           | "return" [ expr ]                       (at the top level: ends the script)
           | "break" | "continue"                    (inside a loop only)
           | NAME assignop expr
           | expr
fndef      = "fn" NAME "(" [ NAME { "," NAME } ] ")" block
block      = "{" { sep } { statement sep { sep } } [ statement ] "}"
assignop   = "=" | "+=" | "-=" | "*=" | "/="

expr       = and { "or" and }
and        = not { "and" not }
not        = "not" not | compare
compare    = sum [ ( "==" | "!=" | "<" | "<=" | ">" | ">=" ) sum ]
sum        = product { ( "+" | "-" ) product }
product    = unary { ( "*" | "/" | "%" ) unary }
unary      = "-" unary | primary
primary    = NUMBER | TEXT | "true" | "false" | "nil" | "pi"
           | NAME | NAME "(" [ expr { "," expr } ] ")"
           | "(" expr ")"

NUMBER     = digits [ "." digits ] [ exponent ] [ UNIT ]
           | "." digits [ exponent ] [ UNIT ]
           | "0x" hexdigits
UNIT       = "m" | "cm" | "mm" | "km" | "deg" | "rad"
TEXT       = '"' chars '"' | "'" chars "'"
NAME       = letter or "_", then letters, digits or "_"   (31 characters at most)
```

* Binding, loosest first: `or`, `and`, `not`, comparisons, `+ -`, `* / %`, unary `-`.
  So `not a == b` is `not (a == b)`, and `-2 * 3` is `(-2) * 3`.
* Comparisons don't chain: `1 < x < 3` is an error. Write `1 < x and x < 3`.
* `else` may start the next line after the `}`.
* A function can be called before the line that defines it, and can call itself.
  A function without `return` gives `nil`.
* The `for` range is evaluated once. The loop variable is an ordinary variable;
  after a loop that ran to the end it holds the end value (`for i in 0..3` leaves `i` at 3).
* Keywords: `fn if else while for in return break continue and or not true false nil pi`.
  They can't be names. A built-in's name can't be a function's name.
* There are no lists, maps, `[ ]`, `.` member access, `**` or `^`. Use `pow(x, y)`,
  and loop over indices: `for i in 0..count() { name(i) }`.

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
| `gpu(k)` | The GPU helper (docs/GPU.md): 0 running (starts it), 1 the device type (1 integrated, 2 discrete, 3 virtual, 4 CPU), 2 path tracer runs, 3 raster batches, 4 samples traced on the GPU, 5 GPU-side milliseconds, 6 the current render on the GPU; 7-14 Rendered shading's; 15 the last scene build's ms, 16 its BVH's, 17 its triangles, 18 where the last render ran and why (0 the GPU; [GPU.md](GPU.md)), 19 its spheres (particle balls), 20 objects it took from the cache, 21 KiB the last render's scene sent to the GPU, 22 Rendered shading's, 23 1 if the last render traced with RTX, 24 1 if the helper has RTX, 25 liquid surfaces the last render traced as fields, 26 the sample reuse setting (frames). `op("render.device", "auto|rtx|gpu|cpu")` picks the device, `op("render.motion_blur", "0.5")` opens the shutter for half a frame (particles streak) |
| `get(name, prop)` | Reads `x` `y` `z` (location), `rx` `ry` `rz` (rotation), `sx` `sy` `sz` (scale) or `color` (the object's colour, `0xRRGGBB` as a number); a camera's `lens` (mm); a light's `power` (1: the default light) and colour `lr` `lg` `lb`; `hidden` (1: hidden, 0 shown) |
| `set(name, prop, value)` | Writes one of those properties |
| `select(names...)` | Selects exactly these objects; the last one is active. `select()` deselects all |
| `delete(names...)` | Deletes the objects |
| `rename(old, new)` | Renames an object; returns the unique name it got (`Box.001`) |
| `exists(name)` | 1 if an object has that name, else 0 |
| `count()` | The number of objects |
| `name(i)` | The name of the `i`-th object in the outliner, starting at 0 |
| `active()` | The active object's name, or `nil` |
| `issel(name)` | 1 if that object is selected |
| `parent(name)` | The name of the object it follows (its parent), or `nil`; set with `op("object.parent_set", "child parent")` |
| `folder(name [, parent])` | The outliner folder of that name, made (inside the parent folder) when there is none; returns its name |
| `infolder(name [, folder])` | The folder the object is in, or `nil`; with a folder, it goes there (`""`: out of any; a new name makes the folder) |
| `folders()` | How many folders the outliner has |
| `refimage(path [, name])` | A reference image from the file (Add › Reference Image); returns its name, `nil` when the file does not load |
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
| `matset(mat, param, value [, g, b])` | Sets a material value: `base`, `metallic`, `roughness`, `specular`, `ior`, `transmission`, `emission`, `strength`, `clearcoat`, `coat_roughness`, `alpha`, `density` (g/cm^3, for mass), `blend` (0 opaque, 1 masked, 2 translucent), `one_sided` (0 / 1: back faces let rays through), `clip` (masked: the opacity mask's clip value, 0 meaning 1/3). Colours (`base`, `emission`) take three numbers, linear 0-1 |
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
| `node(material, type [, values...])` | Adds a shader node and returns its number (1..48); the values fill its values in order (`image`: the image's name first). Types and their values (outputs after the arrow, 0..): **textures** `image` (image, size, sampler 0 colour 1 data 2 normal, wrap 0 repeat 1 clamp 2 mirror; input 1 a UV vector -> colour, R, G, B, alpha), `noise` (scale, detail, roughness), `checker` (scale), `gradient` (axis 0 x 1 y 2 z 3 radial 4 spherical, scale, offset), `voronoi` (scale, randomness, feature 0 F1 1 F2 2 edge -> distance, cell colour), `brick` (scale, mortar, offset; inputs: vector, brick colour, mortar colour -> colour, fac), `wave` (scale, distortion, kind 0 bands 1 rings, axis -> fac, colour), `whitenoise` (-> value, colour), `triplanar` (image, size, sharpness, sampler -> colour, alpha); **inputs** `texcoord` (tiling u, v, offset u, v -> UV, U, V), `position` (space 0 object 1 world -> vector, X, Y, Z), `normal`, `camera`, `vcolor` (the vertex colour; no tint afterwards), `time` (speed), `constant` (value), `color` (input 1), `fresnel` (exponent, base; input 1 a normal); **math** `math` (op: 0 add 1 subtract 2 multiply 3 divide 4 power 5 min 6 max 7 greater 8 sine 9 abs 10 cos 11 tan 12 sqrt 13 floor 14 ceil 15 fraction 16 round 17 sign 18 one minus 19 saturate 20 clamp(a, b, c) 21 lerp(a, b, c) 22 step 23 smoothstep(a, b, c) 24 modulo 25 exp 26 log 27 atan2 28 less 29 negate 30 a b + c); **vector** `vmath` (op: 0 add 1 subtract 2 multiply 3 divide 4 min 5 max 6 abs 7 floor 8 fraction 9 scale 10 dot 11 cross 12 normalize 13 length 14 distance 15 reflect 16 lerp 17 one minus 18 saturate 19 power -> vector, X, Y, Z), `separate` (-> X, Y, Z), `combine`, `mapping` (rotation in degrees; inputs: vector, offset, scale), `panner` (speed u, v; inputs: UV, time), `rotator` (centre u, v, speed; inputs: UV, time), `bump` (strength, distance), `normalmap` (strength, green 0 OpenGL +Y 1 DirectX -Y; input 1: a tangent-space normal map's image node); **colour** `mix` (mode 0 mix 1 add 2 multiply 3 subtract 4 screen 5 overlay 6 darken 7 lighten 8 difference 9 soft light 10 divide), `ramp` (position 0, position 1), `hsv` (hue shift, saturation, value, factor), `invert` (factor), `brightcon` (brightness, contrast), `desaturate` (fraction), `gamma` (gamma), `blackbody` (kelvin). Vector inputs left unlinked mean the point's own coordinates (UV for 2D patterns and panners, the object position for 3D ones) |
| `op("material.import_textures", "<image> [name]")` | A PBR material from a texture set, for the active mesh: give any one of its images; maps sharing its name's prefix are found by the word after it (`albedo` / `basecolor` / `diffuse` / `color`, `normal` (with `dx`: DirectX), `roughness`, `gloss` (inverted), `metallic`, `ao`, `height` / `disp` / `bump` (a bump node when there is no normal map), `emissive`, `opacity` / `alpha` / `mask` (makes it masked), `orm` / `arm` (packed occlusion, roughness, metallic)); resolution words such as `2k` are skipped |
| `op("material.preset", "<preset> [material]")` | One of 20 looks for a material (none named: a new one for the active mesh): `gold` `silver` `copper` `chrome` `aluminium` `plastic` `rubber` `glass` `frosted_glass` `water` `ceramic` `car_paint` `skin` `clay` `emissive`, and the procedural `wood` `marble` `concrete` `fabric` `leather` (small node graphs) |
| `op("material.function_new", "[name]")` | A material function: a graph from Function Input nodes (`fninput`, value: which input 0..2; its Preview input shows when the function is viewed on its own) to one Function Output (`fnoutput`, inputs Out 1..3); it starts as In 1 wired to Out 1. Use it with `node(m, "fncall", "<function>")` (inputs In 1..3 -> outputs Out 1..3). Editing the function changes every material calling it; calls nest 8 deep |
| `op("material.make_function", "<material> <node> [node...]")` | Moves those nodes into a new function `<material>_fn` (up to three inputs from outside and three outputs used outside), one Material Function node in their place (the node editor's Ctrl+G) |
| `op("material.bake", "<object> [size] [apply]")` | Bakes the object's material (its node graph) through its UVs into images `<material>_base` (sRGB, with alpha), `_orm` (occlusion, roughness, metallic), `_normal` (tangent space) and `_emissive`, `size` x `size` (1024); `apply`: the material then samples them (as for game engines). glTF and OBJ export do this by themselves for graphs that are more than images |
| `instance(parent [, name])` | A material instance of `parent` (default name `<parent>_Inst`): its values and graph are the parent's, kept up to date, except the parameters it overrides; returns its name. Instances of instances work |
| `matparam(material, name [, x, y, z, w])` | A parameter node's value by its name (its first value), or sets it (an instance: overridden from then on). Parameter nodes: `node(m, "scalarparam", "Wear", 0.3)` (value, min, max), `node(m, "vectorparam", "Tint", r, g, b)`, `node(m, "textureparam", "Albedo", image, size, sampler, wrap)`; their names are keyable: `key("material:Blue:Wear", 10, 0.5)`. `op("material.param_reset", "<instance> <name>")` gives an instance the parent's value back, `op("material.node_name", "<material> <node> <name>")` renames one |
| `nodeval(material, node, k, x, y, z [, u, v])` | Evaluates the graph at a point (the object and world position x y z, UV u v, normal +y, the eye along +z) and returns node's output `k / 4`, channel `k % 4` (0..2 the colour, 3 the value): tests and agents check nodes with it |
| `nodeinfo(material, node, what [, k])` | Reads the graph: `"count"`, `"type"` (1 image .. 9 normalmap), `"link"` (the node feeding input k), `"linkout"` (which of its outputs, 0..), `"socket"` (the node driving pin k: 0 base, 1 metallic, 2 specular, 3 roughness, 4 emission, 5 opacity, 6 normal, 7 ao, 8 clearcoat, 9 coat_roughness, 10 transmission, 11 ior, 12 mask), `"socketout"` (which of its outputs), `"x"` / `"y"` (its place in the node editor; node 0 is the output), `"value"` (value k, 1..4); -1 when there is none |
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
| `joint(n [, 1])` | Mechanism joint n's value (1..; radians or scene units), with 1: 1 when it is held at a limit; nil when there is no such joint. Joints: `op("mech.joint", "revolute Gear1 world axis 0 1 0 value angle")`, `op("mech.joint", "revolute Gear2 world axis 0 1 0 gear 1 -2")`, `op("mech.joint", "slider Rack world axis 1 0 0 gear 1 1 min -1 max 1")`; key a parameter with `key("param:angle", 1, 0)`. Place parts first with mates: `op("asm.mate", "coincident Pin 32 Base 1")` (faces by number), `"concentric Wheel 33 Pin 33"`, `"distance Wheel 32 Base 1 30cm"`, `"concentric Pin 33 Base axis 0.5 0 0 0 1 0"` (an axis in the object's own space); `flip` turns the part round |
| `collisions()` | How many pairs of parts collide now (each moving part against every other mesh) |
| `rigid(name, prop)` | An object's rigid body setting: `"type"` (1 active, 2 passive), `"shape"` (0 box, 1 sphere, 2 capsule, 3 hull, 4 compound, 5 mesh, 6 plane), `"mass"`, `"friction"`, `"bounce"`, `"damping"`, `"group"`; while it runs `"x0"` `"y0"` `"z0"`: where it started; nil when it is not a body |
| `cacheinfo(k)` | The simulation cache: 0 rigid body frames, 1 cloth frames, 2 MB in use, 3 rigid bodies baked, 4 cloth baked, 5 full, 6 the budget (MB), 7 particles frames, 8 liquid frames, 9 particles baked, 10 liquid baked. Frames are kept as `frame(n)` simulates and played back when it goes back; `op("sim.bake")` keeps the frame range (`rigid`, `cloth`, `particles`, `liquid`), `op("sim.free")` lets it go, `op("sim.cache", "budget 2048")` sets the memory budget |
| `vgstat(k)` | The last frame's drawing through cluster DAGs: 0 objects drawn through DAGs, 1 clusters drawn, 2 their triangles, 3 clusters culled by the frustum, 4 occluded in the last frame's depth, 5 of those drawn after all, 6 the objects' source triangles, 7 MB of cluster pages in memory, 8 the budget (MB, `op("vgeo.budget", "2048")`), 9 pages on their way, 10 pages read in all, 11 pages given back in all, 12 refinements waiting for pages, 13 ms for the cuts, 14 streamed DAGs, 15 the error allowed (pixels, `op("vgeo.error", "1")`), 16 with `op("vgeo.view", "check")`: the first object's cut crack-free (1, 0; -1: not all of it in view) |
| `lib(k)` | The content library: 0 assets, 1 libraries, 2 thumbnails made, 3 thumbnails still to make, 4 assets matching the search. `op("lib.save", "object Gate #stone")`, `op("lib.place", "Gate 10 0 0")`, `lib.tag`, `lib.search`, `lib.deps`, `lib.pack`, `lib.import`, `lib.add`, `lib.thumbnails` (make them now) |
| `libfind(words, i)` | The `i`-th asset (from 0) whose name, kind or tags hold every word (the Asset Browser's search becomes the words), or `nil` |
| `playstep(seconds [, forward, right, up, run])` | Play mode goes on for that many seconds (fixed steps, the frame advancing) with those inputs held: forward / right / up as -1, 0 or 1 (up: jump, or rise when flying), run 1. Start with `op("play.start", "walk 0 4 0")` (or `fly`; the eye's place, else the view's), end with `op("play.stop", "keep")` (default `discard`); `op("play.mode", "fly")` switches |
| `playlook(yaw, pitch)` | Where the player looks (degrees; yaw 0 looks along -z, pitch down positive, at most 86) |
| `playinfo(k)` | Play mode: 0 state (0 off, 1 playing, 2 asking keep / discard), 1-3 the feet (x y z), 4 on the ground, 5-7 velocity, 8 mode (1 walk, 2 fly), 9 yaw, 10 pitch (degrees), 11 seconds played, 12 the frame, 13 the mouse captured, 14 steps taken, 15 meshes with a contact grid, 16-18 its up (it follows the pull where it stands: walking round a planet) |
| `playkey(code, down)` | In play mode, a key (its evdev code: 18 E, 57 Space...) goes down (1) or up (0), as from the keyboard: logic graphs' On Key nodes see it |
| `logic(k)` | Logic graphs in play mode: 0 running, 1 graphs running (one per object and Logic modifier), 2 nodes run, 3 events fired, 4 messages sent, 5 objects spawned, 6 nodes skipped past the step budget, 7 nodes the last step ran, 8 steps. Graphs: `op("logic.new", "Door")`, `op("logic.node", "Door overlap 0 0 1.5")` (types: `begin tick key overlap hit timer message move rotate set_property spawn destroy play_action impulse visibility send set_variable branch variable math info get_property`; the values after it), `op("logic.name", "Door 2 4 DoorOpen")` (a name value: node, value 4-7, text), `op("tree.link", "Door 1 2 1")` (Run is input 1), `op("logic.attach", "Door Door")` |
| `logicvar(object, k [, c])` | Variable k (0..7) of the object's logic graph in play mode (x, or component c 0..2); nil when none runs on it |
| `probe(k)` | Light probes: 0 probes, 1 baked, 2 irradiance volumes, 3 reflection probes, 4 the last bake (ms), 5 its paths, 6 grid points in all. `op("probe.add", "irradiance 0 1 0 9 1 9 7 3 7")` (centre, half size, grid points 1-8), `op("probe.add", "reflection 5 1.5 0 2.5 1.5 3")`, `op("probe.bake", "512")` (rays a point; a reflection probe's texels an eighth), `probe.remove`, `probe.clear` |
| `probeinfo(n, what)` | Probe n (from 1): 0 kind (1 irradiance, 2 reflection), 1 samples baked, 2-4 centre, 5-7 half size, 8-10 grid points; nil when there is none |
| `probesample(what, x, y, z, dx, dy, dz, c [, rays])` | Colour channel c at a point: what 0 the irradiance / pi the probes give for that normal, 1 the radiance a reflection probe gives along that direction, 2 the irradiance / pi traced there now (the reference; 1024 rays by default); nil when no probe covers the point |
| `lightmap(k)` | The lightmap: 0 objects, 1 its size, 2 texels traced, 3 the bake (ms), 4 rays a texel. `op("lightmap.bake", "512 64")` (size, rays), `op("lightmap.save", "~/lm.exr")` (`.png`: sRGB, clamped), `lightmap.clear` |
| `lmsample(object, x, y, z, c)` | The lightmap's channel c where the object's surface is nearest the point (within 5 cm): irradiance / pi; nil if none |
| `livelink(k)` | The live link: 0 serving, 1 peers synced, 2 bytes sent, 3 messages sent, 4 mirroring a session, 5 messages received, 6 transforms held back for slow peers (coalesced), 7 snapshots sent. `op("link.serve", "9000")` (`lan 9000`, `unix:/path`), `op("link.stop")`, `op("link.connect", "127.0.0.1:9000")`, `op("link.disconnect")`; the protocol: docs/LIVELINK.md |
| `vcinfo(k)` | Versions of the saved scene: 0 it has a history, 1 commits on the branch, 2 branches, 3 diff rows, 4 added, 5 removed, 6 changed, 7 merge conflicts, 8 not settled yet, 9 merging. `op("vc.commit", "message")`, `op("vc.branch", "idea")`, `op("vc.switch", "idea")` (`force`), `op("vc.diff", "main side")` (`off`), `op("vc.merge", "idea")`, `op("vc.resolve", "1 theirs")` (`all ours`), `op("vc.abort")`, `op("vc.log")` |
| `vctext(what [, row])` | Versions as text: 0 the branch, 1 a diff row ("+ Box", "~ Ball: transform mesh 482 v > 7938 v"), 2 a merge conflict ("1. Cube: transform"), 3 the last commit's message; nil when there is none |
| `costat(k)` | Co-editing: 0 in a session, 1 connections, 2 objects in the document, 3 peers seen (presence), 4 operations made, 5 applied, 6 our peer id, 7 following, 8 the agent's undo log (bytes), 9 the user's. `op("co.host", "7462")`, `op("co.join", "127.0.0.1:7462")`, `op("co.leave")`, `op("co.follow", "1")` (`off`), `op("co.agent", "on")` |
| `cohash()` | The co-editing document's hash (16 hex digits): the same on every peer once they have the same operations |
| `brep(name, what)` | The object's B-rep solid (`op("cad.kernel", "on")`; docs/BREP.md): `"volume"`, `"area"` (exact), `"faces"`, `"edges"`, `"vertices"`, `"loops"`, `"valid"` (1: each edge used once each way, loops closed), `"watertight"` (its triangles), `"triangles"`, `"tessvolume"`, `"kernel"` (1 when it has a solid), `"error"` (why the last boolean failed), or how many faces are `"planes"`, `"cylinders"`, `"cones"`, `"spheres"`, `"tori"`, `"nurbs"`; nil without a solid |
| `nurbscheck(k)` | The largest error of the kernel's NURBS check k: 0 arcs on their circles, 1 knot insertion, 2 degree elevation, 3 curve derivatives, 4 a NURBS cylinder with knots and degrees added, 5 surface derivatives, 6 a NURBS torus |
| `viewinfo(k)` | The viewport camera: 0 yaw, 1 pitch (degrees), 2 distance, 3-5 its target |
| `objtype(object)` | 0 mesh, 1 light, 2 camera, 3 sketch, 4 armature |
| `libinfo(asset, what)` | An asset's `"kind"`, `"id"`, `"blob"`, `"tags"`, `"uses"` (names), `"users"` (names) or `"thumb"` (1 when made); `nil` when there is no such asset |
| `world(k)` | The world partition (`op("world.partition", "50 120")`: cell size, loading radius): 0 on, 1 cells, 2 loaded cells, 3 MB of loaded cells' meshes, 4 the budget (MB, `op("world.budget", "512")`), 5 cells written, 6 cells loaded, 7 cells unloaded (5-7 since the start), 8 loaded cells changed, 9 partitioned objects in the scene, 10 cell size, 11 loading radius, 12 cells pulled in by objects moved into them, 13 cells in reach still waiting. `op("world.update")` streams for the camera now (the window does it every frame) |
| `view(yaw, pitch, distance, x, y, z)` | Sets the viewport camera: degrees round and above its target `x y z`, metres from it |
| `vgeo(name, k)` | An object's cluster LOD DAG (`op("vgeo.build")`): 0 state (0 none, 1 building, 2 ready, 3 out of date), 1 clusters, 2 levels, 3 groups, 4 source triangles, 5 the top level's triangles, 6 build ms, 7 KB, 8 the largest error, 9 roots, 10 / 11 the most triangles / vertices in a cluster, 12 every cut crack-free (1), 13 triangles in all clusters, 14 level 0 clusters; 100 + L, 200 + L, 300 + L: level L's triangles, clusters, largest error |
| `rbinfo(k)` | The rigid body simulation: 0 bodies, 1 contact points, 2 awake bodies, 3 islands, 4 the last frame's simulation time (ms), 5 manifolds, 6 steps, 7 parts, 8-13 the time (ms) in the broad phase, the narrow phase, islands, solving, the hash, compacting, 14 pairs that found no room, 15 joints broken, 16 a hash of every body's state (place, turn, speeds; the same on any number of threads), 17 the fastest body's speed (m/s), 18 its object's uid, 19 joint rows in the solve, 20 objects marked to shatter on impact, 21 those broken so far, 22 bodies that attract the others, 23 their octree's cells, 24 the ms the tree and pulls took, 25 1 when the frame shown was played back from the cache (then the counts are those kept with that frame, see PHYSICS.md); `1000 + 4 i + c`: contact point i's place on its first body (c 0-2) and gap (3). Bodies come from `op("rigid.add", "active box")` on the selected objects (`passive`; `sphere` `capsule` `hull` `compound`; passive `mesh` (its triangles: a static collider of any shape) and `plane` (endless, its object's XZ plane); `instances`: each instance of the object's geometry nodes a body of its prototype's shape, `object` back; `mass` `friction` `bounce` `damping`; `velocity x y z` at the start; `group n` (0-15) and `collide m` (a bit mask of the groups it meets, default all); `material default|rubber|ice|wood|metal|stone` - its friction and bounce; `attracts` - it pulls every other body by its mass, `noattract`), joints from `op("rigid.joint", "hinge Door world pivot 0 1 0 axis 0 1 0")` (`fixed`, `point`, `slider` (along its axis); `break f` (newtons: gone past that load), `limits lo hi` and `motor speed force` for hinges (degrees, degrees a second, torque) and sliders (metres, metres a second, force); the first object turns or moves from the second), the world from `op("rigid.world", "gravity 0 -9.81 0 rate 120 iterations 10 substeps 4 g 1")` (iterations a step, spread over its substeps; `g`: bodies that attract, G); `frame(n)` simulates up to frame n |
| `landscape(name, k)` | A landscape (`op("landscape.add", "hills")`, Add › Landscape): 0 samples a side, 1 size (m), 2 layers, 3 lowest, 4 highest, 5 display samples a side, 6 the last evaluation (ms), 7 paint layers, 8 version; `nil` when it is not one. Its layers change with `op("landscape.layer", "add generate noise ridged height 80")` (`set i ...`, `hide i`, `show i`, `remove i`), brushes and paint with `op("landscape.brush", "raise x z radius r")` and `op("landscape.paint", "add grass")`, heightmaps with `landscape.import` / `landscape.export`; see docs/LANDSCAPE.md. `op("create.ground")` adds the Ground |
| `text(name)` | What a text object says (its body as typed, `{frame}` placeholders and all), `nil` for other objects. Add text with `op("text.add", "'Hello' size 0.5 depth 0.1")` (then `active()` is its name), change the active one with `op("text.set", "'Bye' font 'DejaVu Serif Bold' bevel 0.01")`. [TEXT.md](TEXT.md) |
| `text_set(name, body)` | Makes a text object say that (`\n`: a new line); 1, or `nil` when it is not text |
| `field(type [, name [, settings]])` | A force field at the 3D cursor (Add › Force Field): `"attractor"`, `"zone"`, `"wind"`, `"vortex"`, `"turbulence"`, `"drag"`, or a preset `"planet"`, `"blackhole"`, `"tornado"`, `"breeze"`; settings as `field.set` takes them (`"strength 20 falloff smooth radius 5"`). Returns its name, `nil` for an unknown type. [FIELDS.md](FIELDS.md) |
| `force(x, y, z [, axis])` | The force fields' and gravity's acceleration at that point (m/s², on a still thing of group 0): its size, or one axis (`"x"`, `"y"`, `"z"` or 0-2) |
| `emit(object [, preset or settings [, settings]])` | A new particle system on the object: a preset (`"rain"`, `"snow"`, `"sparks"`, `"confetti"`, `"fountain"`, `"tank"`) and/or settings as `particles.add` takes them (`"rate 200 life 2 speed 4 spread 30"`); its number on the object, `nil` when there is no room. [PARTICLES.md](PARTICLES.md) |
| `particles(k [, i])` | The particles: 0 alive, 1 systems running, 2 the last frame's time (ms), 3 the last step's, 4 blocks in use, 5 steps done; particle i (the systems in order): 6-8 its place, 9-11 velocity, 12 age, 13 lifetime, 14 size, 15 id, 16 colour; 17 the last viewport draw (ms), 18 particles drawn, 19 hits so far; system i: 20 its particles born of events so far, 21 its hits, 22 its particles; the liquid solver: 23 its last frame (ms), 24 the most neighbours, 25 a particle's mass, 26 the kernel's size, 27 the densest (rho / rho0); 32, 33 system i's surface: its meshing (ms), its triangles |
| `fieldinfo(k)` | 0 force fields in the scene, 1 the overlay's arrows (View › Force Field Arrows, as last drawn), 2 its streamline segments, 3 the largest pull it showed |
| `shatter(name, pattern, count [, options])` | Breaks the object into `count` pieces with `object.shatter`: pattern `"shards"` (Voronoi cells), `"bricks"` (a running bond, count a row) or `"balls"`; options are its other words (`"glue 20000 impact 15"`, `"again gap 0.01"`, `"preset glass"`); the pieces made. See docs/SHATTER.md |
| `shinfo(k)` | The last shatter: 0 pieces, 1 cells, 2 their volume, 3 the original's, 4 the smallest piece's, 5 open edges in the pieces, 6 ms, 7 glue joints, 8 open edges of the mesh before repair, 9 the volume's relative error, 10 the thinnest piece (its volume / the mean), 11-13 ms seeding, cutting, making objects, 14-17 the cut's phases (ms), 18-20 balls: radius, the gap between them, how far past the surface, 21 the pieces' mass (kg), 22 bodies made, 23 the outlines the Shatter form's preview draws |
| `height(name, x, z)` | The landscape's height at world x, z (its location and scale); `nil` off it |
| `bonepos(armature, bone, axis)` | Where a bone's tail is, posed (IK too), in the world |
| `prop(path)` | What any property is now, by its animation path (`"Cube:x"`, `"shape:Cube:Smile"`, ...); nil when the path names nothing |
| `shapes(name)` | A mesh's shape keys, the Basis too (0: none). Make them with `op("shape.add", "Smile")` (stores the mesh as it is; edit it, then `shape.add` again stores the edit and brings the Basis back), set them with `op("shape.set", "Smile 0.5")` or key `"shape:Cube:Smile"` |
| `weight(mesh, vertex, bone)` | A vertex's skin weight for a bone (by number, 0..) |
| `wpaint(mesh, x, y, z, radius, bone, weight)` | Paints skin weight for a bone around a world point (one undo step); 0 when the mesh has no armature |
| `evpos(mesh, vertex, axis)` | A vertex's position as shown: after modifiers (skinning, ...); `vpos` gives the base mesh's |
| `instances(name)` | How many instances the object's evaluated mesh carries (geometry nodes) |
| `instpos(name, i, k)` | Instance i's place in the world: k 0 x, 1 y, 2 z (`nil`: no such instance). Instances that are rigid bodies (`op("rigid.add", "active sphere instances")`) move while the simulation runs |
| `link(material, from, to, input [, output])` | Feeds output 0.. of node `from` (0 unless given) into input 1..3 of node `to` and returns `to`'s number (either order: the graph re-sorts itself, so linking backwards renumbers nodes; a loop is an error) |
| `nodeset(material, node, slot, x [, y, z])` | Sets an input's constant (slots 1-3; one value fills all three) or a value (slots 4-7 = the type's values above) |
| `socket(material, pin, node [, output])` | Drives a Material Output pin by a node (its output 0.. unless given): `base`, `metallic`, `specular`, `roughness`, `emission`, `opacity` (translucent materials), `normal` (a bump or normalmap node), `ao` (ambient occlusion: the preview's ambient light), `clearcoat`, `coat_roughness`, `transmission`, `ior`, `mask` (masked materials); `nil` unplugs. A material holds 48 nodes |
| `imgset(image, x, y, r, g, b [, a])` | Sets an 8-bit image's pixel (0..255); the image is then saved inside `.bee` files |
| `paint(object, x, y, z, radius [, r, g, b])` | A dab of texture paint around that world point (radius in scene units, colour 0..255, else the brush colour) on the object's material image; one stroke in the paint history; 0 when there is no image to paint |
| `layer(image, op [, layer [, value]])` | Paint layers: `"count"`, `"add"` (a transparent layer above, made active; returns its number), `"active"` (with a layer: paint it; without: which one), `"opacity"` (0..1), `"blend"` (0 normal, 1 multiply, 2 add), `"visible"` (0 / 1), `"remove"`, `"merge"` (flatten into the image) |
| `vpaint(object, x, y, z, radius [, r, g, b])` | Vertex paint around that world point (one undo step) |
| `vcol(object, vertex, channel)` | A vertex colour's red, green, blue or alpha (0..3; 0..255), -1 without colours |
| `bake(low, high, kind, image [, distance])` | Bake the high mesh's `"normal"`, `"ao"` or `"curvature"` map into the image through the low mesh's UVs (cage distance: 5% of the low mesh's size unless given); the texels baked, -1 without UVs or for a float image. Undo: `op("paint.undo")` |
| `uvmap(object, su, sv, du, dv)` | Every UV of the mesh becomes (u su + du, v sv + dv): tiling, offsets |
| `imgpixel(image, x, y, channel)` | A pixel's red, green, blue or alpha (0..3): 0..255 for 8-bit images, linear values for HDR |
| `render_frames(folder [, first, last, width, height, samples, denoise])` | Renders every frame from `first` to `last` into `folder/0001.png` ... (the folder is made); returns the milliseconds. On the GPU the next frame is simulated and built while the GPU traces one (docs/GPU.md). Defaults: the animation's range and the render settings (`render.settings`, Render › Denoise). `op("render.animation", "<file or folder> [first last]")` does the same at the render settings, into a video when the name ends in `.mp4` `.mkv` `.mov` `.webm` `.gif` (ffmpeg) or `.apng` ([VIDEO.md](VIDEO.md)). `op("render.sample_reuse", "3")` reuses samples from up to 3 frames before where a pixel sees the same surface (each later frame traces samples / 4 new ones; `gpu(26)` says the setting) |
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

## Stability in 1.x

Decided for v1.0 (docs/DECISIONS.md, D1): the syntax above is frozen for every 1.x version.

* Nothing that runs today changes meaning: no keyword, operator, unit, precedence,
  scoping rule or built-in result changes.
* New built-in functions and new operator ids may be added, and so may new optional
  arguments at the end of a built-in's argument list. A script that defines a function
  with a name a later version makes a built-in must rename it (the error says so).
* `tests/beescript.py` runs 50 tasks the way an AI agent writes them. Each must run
  without an error and print the same answer in every 1.x version.

## Limits and safety

* **Endless loops.** A run stops after 500 million VM steps, about half a second.
* **Recursion.** Calls nest at most 2048 deep.
* **Source size.** A script can be up to 64 KiB.
* **Operators a script can't run:** undo / redo (the script is itself one undo step), interactive transforms (`transform.*`) and `script.*` operators.
* **Agent scripts** (`script_eval`) may only run operators marked agent-safe. For example, `op("file.exit")` is refused.
* **Errors** report the line, for example `error: line 3: no object named Box`. Changes made before the error stay, and remain one undo step.
