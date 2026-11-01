# Blender files (.blend)

BeeModel opens `.blend` files itself, with no Blender needed. It saves them
through the Blender you have installed.

## Opening

Open a file in any of these ways:

- **File › Import › Import Blender...**;
- drop it on the window;
- type `file.import_blend ~/models/house.blend`.

The import is one undo step.

**Files it reads.** Files from Blender 2.80 to 5.x:

- plain, or compressed as Blender saves them: zstd since 3.0, gzip before
  that. zstd needs the `zstd` program, which most Linux systems have;
- 64-bit and little-endian files only. Older or other files are refused
  with a message, and the scene is left as it was.

**What comes in.**

| | |
|---|---|
| The scene | The file's current scene, and the objects of its view layer. Collections excluded from the view layer are skipped |
| Collection instances | An empty set to Instance › Collection brings in that collection's objects and its child collections', placed by the empty and the collection's instance offset, as Blender draws them. The collection may be excluded from the view layer, as asset packs keep their trees and props. Each instance is a copy, named after its source (`Spruce01`, `Spruce01.001`...); instances inside instances come in too, 8 deep |
| Places | Each object is placed by its world matrix: location, rotation in any rotation mode, scale, their deltas, and the parent chain with its inverse. Blender's Z up becomes BeeModel's Y up |
| Meshes | Vertices, faces (n-gons kept) and the active UV map, as the file stores them. Modifiers are not applied, so a subdivided cube comes in as the cube. An object with several materials becomes one object per material (`Name`, `Name.001`...). Objects that share a mesh each get a copy |
| Materials | From the Principled BSDF: base colour, metallic, roughness, IOR, alpha (see-through becomes translucent), transmission, emission colour and strength. Image Texture nodes on base colour and emission become texture maps, and so does a Normal Map node's image. Images come from the file (packed) or from beside it (`//` paths). Base colour, metallic, roughness and emission fed through other nodes become the material's node graph (below). A material without nodes uses its viewport colour |
| Cameras | The lens, and which camera is the scene's |
| Lights | Colour and power: 1000 W is BeeModel's default light. A sun becomes a point light |

**Shader nodes.** What feeds the Principled BSDF's base colour, metallic,
roughness or emission colour through other nodes is rebuilt as the
material's own node graph, so procedural materials (gradients through
colour ramps, as trees and plants are often coloured) look as they do in
Blender. Open it in the Node Editor to change it. These nodes come in:

| Blender | BeeModel |
|---|---|
| Texture Coordinate | UV as Texture Coordinate; Generated, Object and Normal as Position or Normal turned to Blender's axes (Generated over the mesh's bounds, as Blender's automatic texture space) |
| Mapping | Point, Texture and Vector, any rotation: folded into the vector, made as Vector Math dot products where a node takes the vector whole |
| Gradient Texture | Every kind: linear, quadratic, easing, diagonal, spherical, quadratic sphere, radial |
| Color Ramp | Any number of stops, as Color Ramp nodes in a chain; ease, B-spline and cardinal are drawn linear, constant as steps |
| Mix, MixRGB | Colours (mix, add, multiply, subtract, screen, divide, difference, darken, lighten, overlay, soft light; other modes as mix) and floats |
| Math | Most operations, and Clamp |
| Voronoi Texture | F1, F2, smooth F1 (as F1) and distance to edge; distance and colour. The cells are BeeModel's, so the pattern differs from Blender's |
| Image Texture, Hue/Saturation/Value, Invert, RGB, Value, Reroute | As they are |
| Node group | Passes its first linked input through; the group's own nodes are not made |

An input that needs any other node (Noise, Vertex Color, Separate Color,
Voronoi's Position ...), or more than the graph's 48 nodes, keeps the
socket's own value, as before.

**Skipped and counted:** curves, text, empties that instance nothing,
Grease Pencil, volumes, animation, constraints and geometry node trees. A
mesh whose material is a volume only (a Principled Volume on the output's
Volume, nothing on its Surface), such as a fog cube, is skipped too: its
faces would draw as a solid box. The console says how many
objects came in, and how many were skipped.

## Saving

**File › Export › Export Blender...** (`file.export_blend <path>`) saves
through Blender:

1. BeeModel writes the scene as glTF to `~/.cache/beemodel/export`: meshes,
   materials with their texture maps, lights and cameras.
2. Blender runs in the background (`blender -b --factory-startup`). It
   imports the glTF with its vertices merged, joins the triangles back into
   quads, and saves the `.blend`.
3. A message says when it is saved, or shows the error Blender reported.

The window keeps working while Blender runs.

Set the Blender program in **Preferences › Files**. Leave it empty to use
the one on `PATH`. Without Blender, the export says it needs it.

Because the scene goes through glTF:

- faces are triangles on the way, and Blender's join makes quads of most of
  them again (n-gons stay triangles);
- lights are point lights;
- modifiers are applied.

## For scripts

`get(name, "lens")` reads a camera's lens. `get(name, "power")` and
`get(name, "lr")`, `"lg"`, `"lb"` read a light's power and colour. `set`
writes the same properties.

## How the reader works

A `.blend` file is Blender's memory, written block by block. Each block
records the address it had in Blender and the number of its struct type.
The DNA block at the end describes every struct: the names, types and
sizes of its fields.

BeeModel looks up every field it reads by name in that description, so new
or moved fields do no harm. The DNA keeps Blender's old names: `Lamp` for
Light, and `Image.name` for an image's file path.

Pointers are matched to blocks by those old addresses. Since Blender 5,
each ID's data blocks are numbered on their own, so a block of the ID being
read wins over another with the same address.

Meshes come in three layouts:

| Versions | Layout |
|---|---|
| Up to 3.x | `MVert`, `MPoly` and `MLoop` arrays |
| 3.4 to 4.x | Named `CustomData` layers |
| 5.x | `AttributeStorage` |

`tests/blend.py` checks all of this against what Blender itself reports,
using fixtures made by Blender 5.2 and 4.2 (`tests/fixtures/blend/make.py`;
collection instances and a fog volume: `make_instances.py`; procedural
materials, checked against Blender's own bake of each: `make_procedural.py`).
No fixture was made with a Blender older than 3.4, so the `MVert`, `MPoly`
and `MLoop` path follows the documented DNA but is untested.
