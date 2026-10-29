# OpenUSD

BeeModel reads OpenUSD natively: binary crate files (`.usdc`, binary
`.usd`), text files (`.usda`), and the stages they compose. Nothing outside
BeeModel is needed - no OpenUSD library, no Python.

**File › Import › USD...**, a dropped file, or `file.import_usd <path>`
brings a stage's meshes in, with their materials and physics, into an
outliner folder named after the file. Online assets
([LIBRARIES.md](LIBRARIES.md)) come in the same way.

## What is read

| | |
|---|---|
| Crate files | versions 0.4 .. 0.x: tokens, strings, fields, field sets, the path tree, specs; LZ4 and the 2-bit integer coding; values inlined, at offsets or compressed (ints, floats as ints, float tables) |
| Text files | prims (`def` / `over` / `class`), properties (`.connect`, `.timeSamples`), relationships, variant sets, metadata, values by declared type |
| Composition | sublayers, references and payloads (other files, internal prims, default prims), variant selections, instanceable prims; relationship targets mapped through each reference; inactive prims and classes left out |
| Transforms | `xformOpOrder` with translate, scale, rotateX/Y/Z, rotate in all six orders, orient, transform; `!invert!` pivots; `!resetXformStack!`; Z up and `metersPerUnit` |
| Meshes | polygons, `leftHanded` winding, `primvars:st` (vertex or faceVarying, indexed or not); GeomSubsets: an object for each bound material |
| Materials | UsdPreviewSurface: colour, metallic, roughness, emission, opacity (below 1: transmission), ior; UsdUVTexture maps (base, metallic-roughness from one texture's b and g - glTF's and SimReady's ORM -, normal, emission) with a UsdTransform2d's tiling |
| Physics | UsdPhysics: rigid bodies, MassAPI masses, collision approximations (convexHull -> hull, boundingCube -> box, boundingSphere -> sphere, the rest compound), physics materials (friction, restitution), kinematic bodies passive; revolute, prismatic, fixed and spherical joints with pivots, axes and limits |

Not read: animation (time samples), skeletons, curves and points, MDL
shaders (UsdPreviewSurface is used), `.usdz` archives. A driven joint
(`PhysicsDriveAPI`) is held where it starts: BeeModel's motors are no
position springs. Parts of an articulated asset share a collision group
that skips itself, and none is lighter than a tenth of the heaviest, so
long joint chains hold together.

## Checked against OpenUSD

`tests/usd.py` compares what BeeModel reads with `tests/usd_ref.py`, a
plain Python crate reader that matches OpenUSD's own (checked with `pxr`):
every spec and field of `tests/fixtures/usd/types.usdc`. A `.usda` and the
`.usdc` that `usdcat` makes of it read alike. The fixture stage's meshes
have OpenUSD's face counts and world bounds (`golden.json`, from
`tests/usd_stage_ref.py`; checked again when `pxr` is installed). Damaged
and deeply nested files read without a crash.

Nine NVIDIA SimReady assets, checked the same way, have every mesh where
OpenUSD puts it. Their 58 MB rack, 88 objects, imports in 80 ms; textures
take most of an asset's time (PNG decoding).

`file.usd_dump <in> <out>` writes a layer's specs and fields as text.
