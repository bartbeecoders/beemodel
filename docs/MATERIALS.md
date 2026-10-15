# Materials

BeeModel's materials are physically based (PBR) and can be driven by a node
graph in the style of Unreal Engine's material editor. This page covers the
material model, the node editor, every node type, parameters and instances,
material functions, texture sets and presets, baking, exchange with other
programs, the GPU, and scripting.

## The material model

Every material holds principled values, the same ones the path tracer, the
material preview and glTF use:

| Value | Meaning |
|---|---|
| Base colour | the surface colour (linear RGB) |
| Metallic | 0 a dielectric (plastic, wood, paint), 1 bare metal |
| Roughness | 0 a mirror finish, 1 matte |
| Specular | how strongly dielectrics reflect (0.5 for most) |
| IOR | index of refraction (glass 1.5, water 1.33) |
| Transmission | light passing through (glass, water) |
| Emission, strength | the light it gives off |
| Clear coat, coat roughness | a varnish layer on top |
| Alpha | opacity |
| Blend | **Opaque**, **Masked** (holes where the opacity mask is below the clip value) or **Translucent** (light passes as much as the opacity lets it) |
| One-sided | back faces let rays through (leaves, decals, open shells) |
| Mask clip | for masked materials: the opacity below which the surface is a hole (0 means 1/3) |

A material with a graph keeps these values: each Material Output pin that a
node drives overrides its value at every point, the others stay as set.

## The node editor

Make any area a **Node Editor** (its type menu). It shows the active object's
material: nodes as boxes with their inputs on the left and outputs on the
right, wires between them, and the **Material Output** with its 13 pins.

- **Adding:** Shift+A opens the add menu at the pointer: type to search, or
  pick from its columns (Input, Texture, Math, Vector, Colour, Utility,
  Parameters, Functions). **Palette** in the header shows the same list docked
  at the side; drag a node from it onto the canvas. Quick keys arm a node and
  a click places it: **1** Constant, **3** Color, **T** Texture Sample, **L**
  Lerp, **M** Multiply, **A** Add, **D** Divide, **E** Power, **O** One Minus,
  **P** Panner, **N** Normalize, **U** Texture Coordinate, **B** Bump.
- **Wiring:** drag from an output to an input or a Material Output pin. From
  a linked input the drag picks the wire up; dropped on empty space it is
  gone. Double-click a wire to add a Reroute node on it. Links may point any
  way: the graph keeps itself in evaluation order and refuses loops.
- **Editing values:** drag a value sideways, or select the node and use its
  fields in the Material tab (Properties), which also names parameters.
- **Selecting and arranging:** click, Shift-click, or drag a box on empty
  space. Drag a header to move the selection. Ctrl+C / Ctrl+V
  copy and paste (also into another material), Shift+D duplicates, Ctrl+X
  cuts, X deletes, H collapses, C wraps the selection in a comment frame.
  The context menu (right-click) aligns and distributes.
- **Viewing:** the wheel zooms about the pointer, middle drags pan, Home
  frames everything, F frames the selection; a minimap shows where you are.
- **Previews:** **Preview** shows the material on a sphere, cube or plane in
  the corner, updated as you edit; **Thumbnails** shows each node's output
  under it. The status line counts the nodes, those that reach the output
  and the texture samples, and warns about nodes that lead nowhere and
  texture samples without an image.
- **Functions:** Ctrl+G turns the selection into a material function; Tab on
  a Material Function node edits it, Tab again goes back (see below).

Every change is one undo step and an operator (`material.node`,
`material.link`, `material.node_move`, `material.node_set`,
`material.socket`, `material.node_delete`, ...).

## Node types

Values are numbers unless noted; vector inputs left unlinked mean the
point's own coordinates (UV for 2D patterns and panners, the object
position for 3D ones).

**Input**

| Node | Values | Outputs |
|---|---|---|
| Texture Coordinate | tiling u, v; offset u, v | UV, U, V |
| Position | space (object, world) | vector, X, Y, Z |
| Normal | | the shading normal |
| Camera | | the direction to the eye |
| Vertex Color | | the mesh's vertex colour (no tint afterwards) |
| Time | speed | seconds |
| Constant | value | value |
| Color | (its input) | colour |
| Fresnel | exponent, base | value |

**Texture**: Texture Sample (image, size, sampler colour / data / normal, wrap
repeat / clamp / mirror; outputs colour, R, G, B, alpha), Noise (scale, detail,
roughness), Checker (scale; two colours), Gradient (axis x / y / z / radial /
spherical, scale, offset), Voronoi (scale, randomness, F1 / F2 / edge;
distance, cell colour), Brick (scale, mortar, offset; colour, fac), Wave
(scale, distortion, bands / rings, axis; fac, colour), White Noise, Triplanar
Sample (image, size, sharpness, sampler).

**Math**: Math with 31 operations (add, subtract, multiply, divide, power,
min, max, greater, less, sine, cosine, tangent, abs, sqrt, floor, ceil,
fraction, round, sign, one minus, saturate, clamp, lerp, step, smoothstep,
modulo, exp, log, atan2, negate, multiply-add) on the inputs' values.

**Vector**: Vector Math (component-wise math, scale, dot, cross, normalize,
length, distance, reflect, lerp, one minus, saturate, power), Separate,
Combine, Mapping (rotation in degrees; offset, scale), Panner (speed u, v),
Rotator (centre, speed), Bump (strength, distance: the height input bends the
normal), Normal Map (strength; green OpenGL +Y or DirectX -Y).

**Colour**: Mix (mix, add, multiply, subtract, screen, overlay, darken,
lighten, difference, soft light, divide), Color Ramp, Hue/Saturation,
Invert, Brightness/Contrast, Desaturate, Gamma, Blackbody (kelvin).

**Utility**: Reroute.

**Parameters**: Scalar Parameter, Vector Parameter, Texture Parameter (see
below).

**Functions**: Function Input, Function Output, Material Function.

**Material Output pins**: base colour, metallic, specular, roughness,
emission, opacity (translucent materials), normal (a Bump or Normal Map
node), ambient occlusion (the preview's ambient light), clear coat, coat
roughness, transmission, IOR, opacity mask (masked materials).

## Parameters and instances

Scalar, Vector and Texture Parameter nodes carry a name (their title). A
**material instance** (Material tab: **New Instance**, or
`material.instance <material> [name]`) shares its parent's graph and values
and shows only the parameters, each with an override box: typing a value
overrides it, clearing the box takes the parent's value again. Edits to the
parent reach every instance at once; instances of instances work.
Parameters can be keyed: `key("material:Blue:Wear", 10, 0.5)`.

## Material functions

A material function is a graph from Function Input nodes (In 1..3) to a
Function Output (Out 1..3). A **Material Function** node in any material
runs it with its three inputs and gives its three outputs, so one function
can serve many materials, and an edit to it changes all of them.

- Select nodes and press **Ctrl+G** (or `material.make_function <material>
  <node>...`): they move into a new function `<material>_fn`; what fed them
  from outside comes in through its inputs, what was used outside leaves
  through its outputs, and one Material Function node takes their place.
- **Tab** on a Material Function node edits the function (the header reads
  "Function:"); Tab again returns. The preview shows its Out 1.
- `material.function_new [name]` starts an empty one (In 1 wired to Out 1).
- Calls nest 8 deep; a function that calls itself gives black there.

## Texture sets and presets

**Texture Set...** in the Material tab (`material.import_textures <image>
[name]`) builds a material from a PBR texture set as Substance, Quixel,
Poly Haven or ambientCG name them: pick any one image; its siblings are found
by the word after the shared prefix: base colour (albedo, basecolor, diffuse,
color), normal (with `dx`: DirectX), roughness or gloss (inverted), metallic,
ambient occlusion, height (a bump node when there is no normal map),
emissive, opacity (the material becomes masked) and packed ORM / ARM maps.
Resolution words such as `2k` are skipped.

**Preset...** (`material.preset <name> [material]`) gives a material one of
20 looks: gold, silver, copper, chrome, aluminium, plastic, rubber, glass,
frosted glass, water, ceramic, car paint, skin, clay, emissive, and the
procedural wood, marble, concrete, fabric and leather.

## Baking

**Bake to Maps** in the Material tab (`material.bake <object> [size] [apply]`)
evaluates the material's graph at every texel of the object's UVs into four
images: `<material>_base` (sRGB, with alpha), `_orm` (occlusion, roughness,
metallic), `_normal` (tangent space) and `_emissive`. With `apply` the
material then samples them: what a game engine or another program reads.

## Exchange

- **glTF 2.0** import reads the mesh UVs and the five texture slots (base
  colour, metallic-roughness, normal, occlusion, emissive) with
  `KHR_texture_transform`, from GLB buffer views, data: URIs or files, into a
  graph. Export embeds the maps as PNG textures: a pin driven straight by a
  texture sample exports that image; a graph doing more is baked (512 x 512)
  through the UVs of an object using it.
- **OBJ / MTL** write and read `map_Kd`, `map_Pr`, `map_Pm` (`-imfchan` for
  the channels of a packed map), `map_Ke`, `norm` / `map_Bump` and `map_d`,
  with the images as files beside the MTL.
- **Assets:** `material.save_asset <material>` stores a material with its
  graph in the asset library.

## Rendering

The path tracer (`render.image`) and the material preview (Shift+Z)
evaluate graphs at every shading point. The GPU path tracer evaluates them
too when the scene's graphs use textures, patterns, math, mixes, bump and
normal maps (docs/GPU.md); other graphs render on the CPU.

Graphs are compiled once per edit: nodes that do not depend on the shading
point (constants, parameters and the math on them) are evaluated once, and
the Noise node computes its channels four-wide. A 40-node game-style
material previews at about 2.2x the cost of a plain principled one while
orbiting.

## Scripting and agents

BeeScript (docs/BEESCRIPT.md): `material`, `matset`, `matget`, `node`,
`link`, `nodeset`, `socket`, `nodeinfo`, `nodeval` (evaluate a node at a
point), `instance`, `matparam`, and every operator through `op`.

```
m = material("Rust")
t = node(m, "texcoord", 4, 4)
n = node(m, "noise", 6, 4, 0.5)
w = node(m, "scalarparam", "Wear", 0.4)
r = node(m, "math", 21)                  # lerp
nodeset(m, r, 1, 0.3)
nodeset(m, r, 2, 0.9)
link(m, n, r, 3)
socket(m, "roughness", r)
b = node(m, "bump", 0.5, 0.02)
link(m, n, b, 1)
socket(m, "normal", b)
```

Agents (docs/MCP.md) read every material in `scene_summary`, the node
catalogue in `material_node_types`, one graph in `material_graph`, and
replace a graph from the same JSON with `material_graph_set`.
