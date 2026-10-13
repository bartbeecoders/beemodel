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
| `matset(mat, param, value [, g, b])` | Sets a material value: `base`, `metallic`, `roughness`, `specular`, `ior`, `transmission`, `emission`, `strength`, `clearcoat`, `coat_roughness`, `alpha`. Colours (`base`, `emission`) take three numbers, linear 0-1 |
| `matget(mat, param [, component])` | Reads one material value |
| `assign(object, mat)` | Gives a mesh a material; `""` removes it |
| `matof(object)` | The name of its material, or `nil` |
| `image(path)` | Loads a PNG, JPEG or Radiance HDR image into the scene; returns its name |
| `imgsize(image, axis)` | Width (axis 0) or height (1) |
| (textures, world) | `op("material.texture", "Wood " + img + " 0.5")`, `op("world.hdri", sky)`, `op("world.strength", 2)` |
| `node(material, type [, values...])` | Adds a shader node and returns its number (1..12). Types: `image` (image name, size), `noise` (scale, detail, roughness), `checker` (scale), `gradient` (axis 0/1/2, scale, offset), `mix` (mode 0 mix 1 add 2 multiply 3 subtract 4 screen), `ramp` (position 0, position 1), `math` (op 0 add 1 subtract 2 multiply 3 divide 4 power 5 min 6 max 7 greater 8 sine 9 abs), `bump` (strength, distance) |
| `link(material, from, to, input)` | Feeds node `from` into input 1..3 of a later node `to` |
| `nodeset(material, node, slot, x [, y, z])` | Sets an input's constant (slots 1-3; one value fills all three) or a value (slots 4-7 = the type's values above) |
| `socket(material, socket, node)` | Drives `base`, `metallic`, `roughness`, `emission` or `normal` (a bump node) by a node; `nil` unplugs |
| `imgpixel(image, x, y, channel)` | A pixel's red, green, blue or alpha (0..3): 0..255 for 8-bit images, linear values for HDR |
| `render(path [, width, height, samples, denoise])` | Path-traces the scene with Hive into a PNG (the camera object, or the viewport's view), denoised when `denoise` is 1; returns the milliseconds. Defaults 640 x 360, 64 samples, no denoising |
| `modifier(name, type)` | Adds `mirror`, `array`, `solidify`, `subsurf`, `bevel`, `decimate`, `remesh` or `boolean`; returns its index. A boolean takes the other selected mesh as its object |
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
