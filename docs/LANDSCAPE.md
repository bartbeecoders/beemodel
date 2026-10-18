# Ground and landscapes

Two objects give the scene something to stand on: the **Ground**, an
endless floor, and **landscapes**, heightfields you generate, erode, sculpt
and paint. Both are colliders for rigid bodies, cloth and the play-mode
player. The code is `src/ground.s`, `src/landscape.s` (the block and its
layers), `src/lsculpt.s` (brushes and paint), `src/landio.s` (heightmaps,
meshes, tiles) and the heightfield collider in `src/rbody.s`. The tests are
`tests/landscape.py`.

## The Ground

```
op("create.ground")              # Add › Ground
op("create.ground", "height -2")
```

- A 1 km square in 50 m cells on its XZ plane, flagged as the Ground. A
  scene has one: adding it again selects it.
- The viewport draws it as a grid around the view's centre that fades with
  the distance. The floor grid gives way to it, and frame-all leaves it out.
- Renders treat it as a **shadow catcher**. The film keeps an alpha:
  - camera rays that miss show no sky;
  - a hit on the Ground takes one light sample, unshadowed and shadowed
    (catchers cast no shadows themselves);
  - the alpha is (seen + catcher × (1 − shadowed / unshadowed)) / samples,
    and the colour is straight.

  The render window shows it over checks, and `render.save` and `render()`
  write RGBA PNGs. A render with a catcher in it stays on the CPU.
- It is a passive plane rigid body (friction 0.5, bounce 0; Properties ›
  Physics changes them), a cloth collider, and something the player walks
  on.

## Landscapes

```
op("landscape.add", "hills")                     # Add › Landscape › Hills
op("landscape.add", "flat res 1025 size 400")
op("landscape.layer", "add terrace steps 6 smooth 0.3")
op("landscape.layer", "set 0 noise ridged seed 7 height 80")
op("landscape.layer", "hide 1")
print(landscape("Landscape", 4), height("Landscape", 10, -20))
```

A landscape is a mesh object whose mesh carries a landscape block: N × N
samples (65 to 4097, 2^k + 1) over a square of a chosen size, centred on
the object.
- **The block is shared and copied on write, like meshes.** Undo, copies and
  saving (a LAND chunk) follow the mesh.
- **The mesh is the display.** It is a grid of every 1st, 2nd, 4th ...
  sample, at most 513 a side (`landscape.set detail n`).
- **Colliders read the full heights.**

### Layers

A non-destructive stack, bottom up, up to 8 layers. Each layer has a
strength and can be hidden.

| Layer | Keys | What it does |
|---|---|---|
| `generate` | `noise fbm\|ridged\|billow\|cells`, `seed`, `scale` (features across), `height` (m), `octaves`, `island` (1: down to the edges), `offset` (m) | adds noise, on every core |
| `erode` | `droplets` (0: a sample in 8), `rate`, `seed`, `thermal` (iterations), `talus` (degrees) | droplet erosion, then thermal erosion; the result is cached |
| `terrace` | `steps`, `smooth` | flat steps over the heights' range |
| `sculpted` | | the brushes' offsets |
| `flatten` | `height`, `at x z radius` (adds a round area) | pulls the heights to a level under its mask |
| `heightmap` | | imported heights, added |

A change above the last erosion starts from its cache. A 1025² landscape
is generated and eroded in about 210 ms, and a layer above the erosion
changes in about 4 ms.

`landscape.set size m | res n | detail n` changes the size, resamples the
arrays (bilinear), or sets the display's samples.

### Presets

`landscape.add flat | hills | mountains | canyon | dunes | island` (Add ›
Landscape):

| Preset | Layers |
|---|---|
| flat | none (to sculpt) |
| hills | fBm, erosion |
| mountains | ridged noise, harder erosion, thermal erosion |
| canyon | fBm, terraces, erosion |
| dunes | billows, slid to a 30° talus |
| island | fBm falling to the edges, under the sea; erosion; and its sea |

The island's sea is a **Water** plane: 1.5 times the landscape, at its
height, in ripples, with the water material (transmission, IOR 1.33).
Bodies below its level float.

### Sculpting and painting

Sculpt mode (Ctrl+Tab) on a landscape shows its own tools. The brushes
work on the heightfield at full resolution, through the topmost Sculpted
layer (one is added when there is none):
- **raise**, **lower**: up or down, by a tenth of the brush's radius.
- **smooth**: towards the neighbours.
- **flatten**: to the height where the stroke began.
- **ramp**: a straight slope from where the stroke begins to where it ends.
- **noise**: roughens the ground.
- **erode**: droplets in a window under the brush.

A stroke shows at once on the display mesh. When it ends, the stack is
evaluated from the Sculpted layer. A stroke is one undo step.

Painting has up to 8 paint layers, each a material with a colour, friction,
bounce and a rule (heights 0..1 of the range, slopes in degrees). The
materials and their rules:

| Material | Rule |
|---|---|
| rock | slopes 30-90° |
| grass | slopes 0-30° |
| sand | low ground (0-0.15), flat |
| snow | above 0.8 |
| dirt | slopes 15-35° |
| gravel, moss | no rule |
| mud | low ground |

- **Painting with a material** (the PAINT tools) adds its layer.
- **Auto Paint** weighs every sample by the rules: rock on the slopes,
  grass on the flat.
- **The splat map** keeps 8 weights a sample. The display mesh's vertex
  colours show the blend, which tints the material in the viewport and in
  both path tracers.

Scripts:

```
op("landscape.brush", "raise 10 -5 radius 8 strength 0.5")
op("landscape.brush", "ramp -40 30 to -10 30 radius 5")
op("landscape.paint", "add grass friction 0.6")
op("landscape.paint", "rule 0 slope 0 25")
op("landscape.paint_auto")
op("landscape.brush", "rock 12 4 radius 6")
```

### Physics

- **Rigid bodies.** A landscape made a passive mesh body
  (`rigid.add passive mesh`) is a heightfield. It is not cut into
  triangles: each step, the cells under every moving part become
  triangles on the fly (see [PHYSICS.md](PHYSICS.md)). Each triangle takes
  the friction and bounce of the paint there.
- **Cloth.** A landscape collider (`cloth.add collider`) is used by its
  heights: a particle under the ground is put back on it.
- **The player** walks on the display mesh.
- **Water.** A Water plane is a buoyancy zone. A moving body reaching below
  its level is pushed up by the water it displaces (1000 kg/m³ × g × its
  volume × the share of its height below the level), and slowed by that
  share. A wooden box (600 kg/m³) floats, about 0.6 of it under water; a
  stone one sinks.

### Heightmaps, meshes, tiles

```
op("landscape.import", "~/maps/alps.png size 2000 height 300")
op("landscape.export", "~/maps/out.png")          # 16-bit grey
op("landscape.export", "~/maps/out.exr")          # float metres
op("landscape.export", "~/maps/paint.png splat")  # RGBA weights
op("landscape.to_mesh", "full")
op("landscape.tiles", "4")
```

- **Import** reads a PNG (grey or colour, 8 or 16 bits: the first channel,
  0..1) or an OpenEXR (scanlines, none / ZIPS / ZIP, half / float / uint:
  Y, else R). Heights are base + value × height (PNG: 100 m by default;
  EXR: the values in metres). The result has 2^k + 1 samples a side and
  one Heightmap layer; the image is resampled unless it is that size.
- **Export** writes the heights as a 16-bit grey PNG (lowest..highest), so
  a PNG made that way round-trips exactly. It can also write a float EXR,
  or the splat map as RGBA PNGs (paint layers 1-4, and 5-8 in
  `<name>_2.png`).
- **`landscape.to_mesh`** makes a plain mesh: the display grid, or every
  sample (up to 2049 a side) on the surface within 1e-5.
- **`landscape.tiles k`** splits it into k × k landscapes. Each tile gets
  the heights baked into its Heightmap layer and a copy of the paint. World
  partition then streams the tiles by cell, and its cell files keep their
  landscapes.

Script reports:
- `landscape(name, k)`: 0 samples a side, 1 size, 2 layers, 3 lowest,
  4 highest, 5 display samples, 6 the last evaluation (ms), 7 paint layers,
  8 version.
- `height(name, x, z)`: the height at world x, z; `nil` off the landscape.

## Numbers

From `tools/physbench.py` and `tests/landscape.py` on a Ryzen 9 7950X:

| | |
|---|---|
| 1025² generated and eroded | about 210 ms |
| a layer above the erosion changed | about 4 ms |
| 4097² generated (fBm, 8 octaves) | 3.9 s on 1 thread, 0.6 s on 8, 0.37 s on 32 |
| 1000 balls rolling down a 4097² mountain, a frame | 39.3 ms on 1 thread, 13.5 on 4, 10.2 on 8, 10.0 on 32; the same result on each; none under its surface (1.6 mm at most) |

Not done yet: the tile LOD drawing the plan names. The display is a
uniform grid of up to 513 samples a side.
