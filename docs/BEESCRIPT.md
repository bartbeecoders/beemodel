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
| `op(id, [arg])` | Runs any operator, e.g. `op("file.save", "~/a.bee")` |
| `edit(name)` / `edit()` | Enters edit mode on a mesh (it becomes active) / leaves edit mode |
| `verts(name)` `edges(name)` `faces(name)` | Mesh sizes |
| `vpos(name, i, axis)` | A vertex coordinate in object space; axis is `0`-`2` or `"x"` / `"y"` / `"z"` |
| `selected(name)` | How many vertices are selected (the edit-mode selection) |
| `vsel(name, i)` | 1 if vertex `i` is selected |
| `vselect(name, i...)` | Selects exactly these vertices; `vselect(name)` deselects all |

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
