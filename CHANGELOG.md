# Changelog

All notable changes to BeeModel are documented here.
The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the
project uses [Semantic Versioning](https://semver.org/).

## [Unreleased]

### Added
- **Online model libraries** (milestone 28, #407-#414): the Asset
  Browser's sources go round the local library and online ones, starting
  with NVIDIA SimReady (2673 CC-BY 4.0 assets on Hugging Face). Its
  catalog and thumbnails load in the background; a double-click or a drag
  downloads an asset (only what an import needs, cached under
  ~/BeeModel/cache) and places it with its textured materials, masses,
  colliders and joints, saved into the local library too. `lib.sources`,
  `lib.source`, `lib.refresh`, `lib.get`, `lib.stop`;
  ~/BeeModel/sources.txt adds datasets in SimReady's layout
  ([docs/LIBRARIES.md](docs/LIBRARIES.md)).
- **Auto factory demo** (`Vibecoding/demos/auto-factory.bees`): a car
  assembly hall of NVIDIA SimReady assets. `lib.get ... static nosave`
  places assets without physics or a library copy; USD textures are kept
  at most `file.usd_texture_size` a side (1024; shrunk once, cached);
  BeeScript's `get` / `set` read and add to the selection (`select`).
- **OpenUSD import** (File > Import > USD, `file.import_usd`): binary and
  text layers read natively, stages composed (sublayers, references,
  payloads, variants, instancing), meshes, UsdPreviewSurface materials and
  UsdPhysics bodies and joints. Checked against OpenUSD itself
  ([docs/USD.md](docs/USD.md)).
- **Path-traced playback in Rendered shading.** While the animation plays,
  each new frame's scene goes up at once and is path-traced on the GPU,
  Preferences › Viewport › Rendered playback samples of it (4;
  `view.rendered_playback <0..64>`), denoised, instead of the raycast; a
  frame shown again gets more. Light scenes play every frame in real time
  (the wrecking ball at 74 window frames a second at 1920 x 1080 on an RTX
  4080 SUPER). 0 keeps the raycast.
- **Camera View** (Numpad 0, View › Camera View, the camera button under
  the navigation gizmo, `view.camera [0|1]`): the viewport looks through
  the camera that renders - its lens and roll - and follows it while the
  animation plays, so an animation is seen as it will render; with
  Rendered shading, path-traced as it plays. The render's frame is fitted
  into the viewport and the rest dimmed. Orbiting, panning, zooming or a
  view change leaves it from where the camera is.
- **The Wave node on the GPU** (`graph.glsl`), so the wood preset's
  scenes trace there, in renders and in Rendered shading, instead of on
  the CPU.
- **Chess cascade demo** (`Vibecoding/demos/chess-cascade.bees`): SDF
  chess pieces, dominoes, a bowling ball and a glass pawn that shatters.

### Fixed
- **Duplicates lost their material** (and folder): Shift+D copies looked
  plain grey.
- **Image limits**: a scene held 256 images (now 2048) with paths of up
  to 215 characters (now ~980: an online asset's are long), the GPU saw 64
  (now 1024) - beyond them textures came out black or wrong.
- **A crash in the joint solver** with big jointed islands (stage jobs
  entered `jr_prestep` with the stack 8 bytes off 16).
- **Library thumbnails** that are not square were sampled past their
  rows, and one that failed to load marked the wrong asset.
- **A crash when a body broke on impact** while the animation played,
  was scrubbed or was stepped through MCP: `an_apply` and MCP's
  `handle_message` called on with the stack 8 bytes off 16, and the
  solver keeps vectors on the stack. `an_apply` now aligns its own.

## [1.2.1] - 2026-10-27

Image to 3D: a mesh from a photo, through the optional Hi3D addon.

### Added
- **Image to 3D (the Hi3D addon).** AI › Model from Image (Hi3D)...
  (`object.from_image <image> [512 | 1024 | 1536]`) makes a mesh
  from a photo, and Object › Refine from Image (Hi3D)...
  (`object.refine_from_image`) carves a photo's detail into the active
  mesh. `src/hi3d.s` runs the addon's helper in the background: a status
  bar chip shows how far it is and stops it (`object.from_image_stop`), and
  the mesh comes in as one undo step. The helper (`addons/hi3d/`,
  `install.sh`) runs TripoSR for the rough shape and Hi3D v1.0 for the
  detail on an NVIDIA GPU. Powered by Hi3D 1.0. See docs/HI3D.md.
  `tests/hi3d.py` tests it with a stand-in helper.

## [1.2.0] - 2026-10-27

BeeModel runs on Windows 11: every release now has a Windows build
(`beemodel-1.2.0-windows-x86_64.zip`, see [docs/WINDOWS.md](docs/WINDOWS.md))
next to the Linux one. Also in 1.2.0: 3D text (stage T), render to video
(stage C), reference images from a folder of drawings or a PDF, a local
Ollama connection for the AI Assistant, and a UI review.

### Added (Windows 11 port, W1-W7)
- **beemodel.exe**: the same program from the same sources, only the
  platform layer differs: `src/plat_win.s` (memory committed on fault,
  UTF-16 files, threads and `WaitOnAddress`, child processes and pipes,
  Winsock sockets including `AF_UNIX`, the event loop on a high-resolution
  timer) and `src/plat_win_wnd.s` (a Win32 window: drawing, mouse,
  keyboard layouts and dead keys, per-monitor DPI, the clipboard, dropped
  files, the pen). It imports only Windows' own DLLs, no C runtime.
  `.bee` files, BeeScript, MCP (`--mcp-bridge`), the live link and
  co-editing work between Windows and Linux; a headless render is the
  Linux image byte for byte.
- **beemodel-gpu.exe**: the GPU helper, which loads `vulkan-1.dll` when it
  runs; without it renders stay on the CPU.
- Home, preferences and cache under `%USERPROFILE%` as on Linux
  (`~/BeeModel`, `~/.config/beemodel`, `~/.cache/beemodel`), or
  `BEEMODEL_HOME`; Segoe UI and Consolas as the UI fonts; curl, Claude
  Code, zstd, ffmpeg and poppler found on `Path`.
- The release has `beemodel-<version>-windows-x86_64.zip`
  (`scripts/package.sh`). CI checks the build under Wine
  (`ci/check-exe.sh`, the platform layer's `tests/win/`), and CI and the
  release run `ci/check-windows.ps1` against the zip on GitHub's Windows
  runner (`.github/workflows/windows.yml`). docs/WINDOWS.md.
- The executables are not code-signed yet: SmartScreen may ask once
  (More info › Run anyway).

### Added (reference images from drawings)
- **Add › Reference Images from Folder...** (`object.add_references`): a
  folder of PDFs and images, or one PDF of many pages, as an architect's
  office sends them. PDF pages are drawn and read through poppler; each
  page is sorted by its name or title block (elevations and their side,
  plans and their level, sections, site...), sized from its scale, and
  set up around the building in a folder of its own. It runs as a job
  with a progress chip.
- **AI › Line Up References with AI** (`object.references_ai`), MCP
  `reference_view`, `object.reference_pin` and `object.reference_kind`:
  the AI checks a set and lines its drawings up.

### Changed (AI prompt)
- The AI Assistant's prompt takes several lines: it wraps, grows to 10
  lines, keeps a paste's line breaks (Shift+Enter breaks a line) and
  holds 4000 bytes (was one line of 240).

### Added
- **AI Assistant: Ollama (local)**, a fourth connection next to OpenRouter.
  It runs OpenRouter's in-process tool loop against Ollama on this machine
  (Preferences › AI › Ollama (local): Model, Address, Steps at most; Test
  Ollama says whether it runs and has the model). No key is sent, and the
  model is asked not to think (`"reasoning_effort": "none"`): a thinking
  model otherwise answered inside its reasoning, which is not shown, and a
  fine-tuned BeeModel model built worse with it.

### Changed
- **AI instructions: the placeholder Cube.** The world-building
  instructions (AI Assistant and MCP's `build_world`) now say what to do
  with a new scene's 2 m Cube: delete it before building something new,
  unless the request mentions it, and never build into objects that stay.
  Models used to build around the origin, inside the Cube.

### Added (stage T, 3D text, #387-#390)
- **Add › Text** and `text.add ["body"] [size] [depth] [font] ...`: 3D text
  from the system's TrueType fonts (or the built-in block font), standing
  in the XY plane on its last baseline. The meshes are closed and face
  outwards, and letters keep their holes. A text object is a mesh that
  carries its text, so undo, saving (the TEXT chunk), modifiers, rendering
  and export work as for any mesh.
- **Properties › Object › Text:** the body, font (every `.ttf` found;
  fonts can be named: `font 'DejaVu Serif Bold'`), size, depth, a bevel,
  alignment, spacing, line height, slant and quality.
  **Object › Convert Text to Mesh** (`text.to_mesh`).
- **Animated text:** `text:<name>:size|depth|bevel|spacing|line|quality|reveal|soft|wave|wavelength|phase|slant`
  channels (I over a value keys it). Reveal types the text on (pop,
  scale, rise, drop over a soft width), and a wave runs through the
  letters. `{frame}`, `{time}` or any expression in braces in the body is
  worked out every frame.
- **For the AI:** a text object's body and settings are in
  `scene_summary`, and the instructions cover text. BeeScript `text(name)`
  and `text_set(name, body)`.
- `font_load_at`, and outline hooks in the TrueType engine (`ol_begin`,
  `ol_line`, `ol_end`).

### Added (stage C, render to video, #394-#396)
- **Render › Render Animation...**: the save dialog (`animation.mp4`), then
  the animation's frames at the render settings, as a long job: the status
  bar shows how far it is, and **Esc** stops it, keeping the frames done.
- `render.animation <file> [first last]` makes a video when the name ends
  in `.mp4`, `.mov`, `.mkv` (H.264), `.webm` (VP9) or `.gif` (its own
  palette), through ffmpeg (on `PATH`, or `$BEEMODEL_FFMPEG`): raw frames
  on its stdin while the next frame renders, no PNGs in between. ffmpeg's
  first line shows when it fails (its log: `~/.cache/beemodel/ffmpeg.log`);
  without ffmpeg the console says what works without it.
- `.apng`: an animated PNG written by BeeModel itself (no ffmpeg needed).
- `.png`: a folder of frames named like the file (`shot.png`: `shot/0001.png`).
- Esc during a long job asks it to stop (`job_stop`); render animations
  listen to it.
- docs/VIDEO.md; `tests/video.py`.

### Changed
- The release binary may be up to 2 MB (`ci/check-binary.sh`), as the
  masterplan allows from 1.0; it was 1.5 MiB.

### Fixed (UI review)
- The welcome screen's keymap list opened under the welcome screen, so
  it seemed to do nothing; option lists now show over it.
- Option lists are as wide as their longest option (and stay in the
  window); a closed option field cuts its value short with "..." before
  the arrow.
- Menus and submenus are as wide as their longest label with its
  shortcut (AI Assistant, Extrude Individual Faces ran into theirs).
- **Help › About BeeModel** shows an About box (it only wrote to the
  console).
- Held keys repeat in the command palette: Up / Down keep moving,
  Backspace keeps deleting.
- The file browser cuts long names short before the Size column, and a
  click on the preview shows the picture big: the wheel zooms in about
  the pointer, a drag moves it, Fit / Close or Esc go back.
- Panel hints wrap to the panel's width instead of running off it;
  button captions and section titles too wide for their space end in "...".
- A narrow area drops header buttons (maximize first) rather than cover
  its title; a short outliner's rows no longer show through its filter.

## [1.1.0] - 2026-10-23

Ask AI about the selection, issues Q1-Q5 (#374-#378): a prompt at the
pointer about what is selected, answered by the AI Assistant's connection
as one undo step.

### Added
- Ask AI about the selection (stage Q, #374-#377): **Alt+right-click** an
  object, or **Ask AI...** at the top of the viewport's right-click menu,
  opens a prompt at the pointer. The request goes to the AI Assistant's
  connection with what is selected (objects as `scene_summary` lists them,
  or the selected vertices and faces in edit mode), and comes back as one
  undo step. Up / Down bring back the last prompts; quick buttons for
  Bigger, Smaller, Material... and Copy Around; `ai.ask <prompt>` from the
  console.
- **Only the selection** (on by default): the AI is asked to keep to the
  selection, and objects outside it that it changed or deleted anyway are
  named in a warning.
- While the AI works, the status bar shows the request (click: Stop); its
  answer shows as a message.
- `scene_summary` (and `bee://scene`) give each mesh's `size`: its box with
  its modifiers, times its scale.
- A toast's message is in `ui_tree` (the `status.toast` button's label).

## [1.0.0] - 2026-10-22

The decisions, issues D1-D7 (#293-#299): the questions the masterplan left
open are settled in [docs/DECISIONS.md](docs/DECISIONS.md), and 1.0 makes
promises for every 1.x version:

- **Files.** A `.bee` file saved by 1.0 opens in every later version.
  `tests/compat.py` opens a 1.0 file with a bit of everything and checks
  it, from now on in every CI run.
- **BeeScript.** The grammar is frozen (docs/BEESCRIPT.md). Nothing that
  runs changes meaning; built-ins may be added. `tests/beescript.py`: 50
  agent tasks.
- **MCP.** Tools are only added, none removed or renamed. The schema is
  published as docs/mcp-tools.json and checked against the server.

### Added
- docs/DECISIONS.md: the decisions for v1.0 (stage D of the 2.0 plan).
- BeeScript's grammar, written out in docs/BEESCRIPT.md, and frozen for
  1.x (D1, #293): nothing that runs changes meaning, built-ins may be
  added. `tests/beescript.py` runs 50 tasks the way an agent writes them.
- Hexadecimal numbers in BeeScript: `set(c, "color", 0xff8800)`.
- A Blender 4.x keymap preset (D2, #294): Preferences > Keymap, the
  welcome screen (also with Alt + left as the middle button) or
  `prefs.keymap blender`. It changes only the keys that differ from
  Blender's; docs/UI.md lists them.
- docs/mcp-tools.json (D3, #295): every MCP tool with its input as JSON
  Schema, published in the release archive and checked against the running
  server by `tests/mcp_schema.py`. The README states the MIT License.
- Mates (D4, #296): `asm.mate coincident | concentric | distance` places
  a part against another by faces, or by an axis in the object's own
  space; with mechanism joints, a light assembly that moves.
  `tests/assembly.py`.
- D5 (#297), recorded in docs/DECISIONS.md: the GPU helper stays
  optional and the CPU is the reference for every GPU path.
- A session key for co-editing (D6, #298): `co.key <pass phrase> | new`
  (Team panel > Session Key...). Peers without it, or with another, are
  refused, and every message is authenticated (SipHash-2-4, per-connection
  keys from nonces, counters against replay). docs/LIVELINK.md documents it,
  and how to work over the internet through SSH or WireGuard.
- `tests/compat.py` and tests/fixtures/compat/v1.0.bee (D7, #299): the
  file every later version must open as 1.0 saved it.

## [0.24.0] - 2026-10-21

The viewport on the GPU, issues VP1-VP5 (#363-#367): playing an animation
in Solid, Material Preview and Rendered now keeps up at 2560 x 1440.
[docs/GPU.md](docs/GPU.md); `tools/playbench.py` times it. Window frames a
second while playing, on an RTX 4080 SUPER (v0.23.0 -> v0.24.0):

| demo | Solid | Material Preview | Rendered |
|---|---|---|---|
| dam break | 4 -> 130 | 3 -> 135 | 4 -> 71 |
| rainstorm | 80 -> 185 | 23 -> 181 | 20 -> 27 |
| leaf-twister | 77 -> 131 | 45 -> 144 | 45 -> 76 |
| fireworks | 218 -> 218 | 75 -> 214 | 130 -> 169 |

### Added
- The 3D viewport drawn by the GPU helper (VP1, #363): Solid and Material
  Preview (shader graphs, textures, bump and normal maps, vertex colours,
  HDRI worlds) on a Vulkan graphics pipeline, each mesh's triangles kept
  on the GPU while it does not change; the colour, depth and object ids
  come back, so overlays, the outline and clicks work as before. The
  helper imports BeeModel's shared memory where the device can
  (`VK_EXT_external_memory_host`). `BEEMODEL_GPU_VIEW=off` keeps the CPU's
  viewport; edit and paint modes, virtualized geometry and light probes
  stay on the CPU. `gpu(27..32)`.
- Instances and particles in the same pass (VP2, #364): geometry-node and
  rigid-body instances and particle objects as instanced draws, points and
  sprites as quads made on the GPU. The rainstorm in Material Preview 46 ->
  5 ms a frame.
- Liquids solved on the GPU (VP3, #365): `src/gpu/liq.comp`, liquid.s's
  solver phase by phase (the dam break 67 -> 6 ms a frame);
  `BEEMODEL_GPU_LIQUID=off`, force fields and landscape colliders keep the
  CPU's. The viewport marches a liquid's field instead of meshing its
  surface. `gpu(33..35)`.
- `tools/playbench.py`: the demos played in the viewport at 2560 x 1440 in
  each shading (VP5, #367).

### Changed
- Rendered shading keeps up while playing (VP4, #366): the live view
  builds its scene as a render does (no CPU BVH with RTX, liquids as
  fields), fingerprints a liquid by its particles instead of meshing it,
  and no longer counts a slot's first allocation as build time (the dam
  break showed a still image until playback stopped).

### Fixed
- A liquid's surface was meshed every frame by the viewport's DAG scan,
  its wires' check and the live view's fingerprint even when nothing drew
  the mesh (30 ms each time in the dam break).
- `pt_stamp` dropped the particles' step count, so the live view noticed a
  liquid's steps only through its re-meshed surface.

## [0.23.0] - 2026-10-20

Rendering performance, issues H1-H15 (#346-#360): every demo scene renders
on the GPU, with RTX where there is one, and animations render faster.
[docs/GPU.md](docs/GPU.md); `tools/renderbench.py` times it. A warm render
at 960 x 540, 16 samples, on an RTX 4080 SUPER: rainstorm 1377 -> 103 ms,
dam-break 1201 -> 63 ms, leaf-twister 313 -> 27 ms, fireworks 122 -> 24 ms.

### Added
- A render device setting (H1, #346): Properties › Render › Device and
  Preferences › System › Render device (`render.device auto|rtx|gpu|cpu`).
  Each render says where it ran and why ("Last render: on the CPU (a
  shadow catcher)"), in the Render panel, the Render area's header and the
  console; `gpu(15..18)`.
- On the GPU now, instead of the CPU: shadow catchers such as the Ground
  (H2, #347), HDRI worlds (H3, #348) and the Vertex Color node (H4, #349),
  each matching the CPU's image.
- The GPU helper starts with the window and builds its kernels before the
  first render asks (H5, #350).
- RTX (H10, #355): on a card with hardware ray tracing, renders and
  Rendered shading trace with ray queries; the images match the compute
  path's. Rainstorm frame: 165 -> 96 ms.
- Motion blur from particle velocities (H11, #356): `render.motion_blur
  <shutter>` (Properties › Render › Motion blur): rain streaks.
- Animation rendering (H12, #357): `render_frames(folder [, first, last,
  w, h, samples, denoise])` and `render.animation <folder> [first last]`.
  The next frame is simulated and built while the GPU traces one: the
  rainstorm 109 -> 78 ms a frame. `render.sh` uses it.
- Sample reuse between animation frames (H14, #359): `render.sample_reuse
  <frames>` (Properties › Render › Sample reuse). Later frames trace
  samples / (frames + 1) new samples and keep the frame before's where a
  pixel sees the same surface. A still scene with a panning camera at 16
  samples and reuse 3 comes out closer to the reference than 16 new
  samples a frame, at a quarter of the cost. Moving objects keep only
  their own samples (the camera is reprojected, objects are not).

### Changed
- Particle balls are exact spheres, not 20-triangle balls (H6, #351): the
  rainstorm's scene build 1025 -> 206 ms.
- BVHs are built on every thread (H7, #352), and each object keeps its own
  BVH between renders while it does not change (H8, #353): the rainstorm's
  BVH 949 -> 39 ms, its scene build on a third render 15 ms.
- The scene stays on the GPU between renders (H9, #354): only the 4 KiB
  blocks that changed go up (a rainstorm frame sends 7.7 of its 100 MB).
- A liquid's surface is traced on the GPU from its density field instead
  of being meshed every frame (H13, #358): the dam break 157 -> 109 ms a
  frame. It is still meshed for the viewport, CPU renders and exports.

### Fixed
- A new scene started with the last session's viewport cameras: a camera
  left far off made every new scene's viewport look empty.
- The window's early helper start was ready too late again on a cold
  driver cache (about 7.5 s since the RTX kernels came): with RTX it no
  longer builds the compute path's graph kernel, which Auto never uses
  (ready in under 5 s).
- Saving a partitioned world from the window crashed: the thumbnail taken
  first overwrote the path its cells were to be saved beside.
- A saved file's Denoise setting was read back only when its sample count
  was large enough (the count was compared instead of the chunk's size).
- After the scene stayed on the GPU (H9), particles growing within their
  buffer's spare room left the bytes after them unsent; with liquid fields
  read from there (H13) the GPU could lose its device (fireworks frame
  107, then the CPU took over).

## [0.22.1] - 2026-10-19

Particle demos, a cache fix for keyed force fields, and the website.

### Added
- Particle demo scenes in `Vibecoding/demos/`: fireworks (chained died
  events, glowing through Vertex Color → Emission), dam-break (liquid,
  surface, foam, floating crates), leaf-twister (leaves drawn as objects
  in a keyed vortex) and rainstorm (hit events on a landscape and a roof,
  keyed wind).
- The website (`BeeModelHome/`, beemodel.hideterms.com): features, a tour,
  the demo films, renders, downloads and every release's notes; now with
  particles and liquid and the four particle films.

### Fixed
- A force field moved by keys, or with a keyed strength, changed the
  simulation cache's key every frame, so particles and rigid bodies (and
  cloth, whose key mixes the same hash) simulated again from the start on
  each frame (leaf-twister reached 930 ms a frame; 60 balls 62 ms by frame
  100). The key now takes such a field's animation instead of
  where it is and its strength now (`fl_mix`, `an_fkeyed`).

## [0.22.0] - 2026-10-19

Stage P of the 2.0 plan (`Vibecoding/BeeModel-2.0-Plan.html`): particles
and liquid, issues P1-P7 (#337-#343). [docs/PARTICLES.md](docs/PARTICLES.md).

### Added
- Particle systems (P1, #337): any object emits from its faces (by area),
  its volume, its vertices or its origin, at a rate between two frames
  (each particle moved on from its own moment of birth) or all at once,
  with a lifetime, a speed along the normal or a direction, a cone of
  spread, a size and a colour, each as random as asked (a hash of the
  seed and the id). Gravity, the force fields and drag; one step a frame,
  exact for a steady pull (a fountain follows the ballistic curve to
  1e-3). Up to 4M particles in pooled blocks, stepped in parallel (1M in
  about 0.2 ms), the same on any number of threads. `particles.add`,
  `particles.set`, `particles.remove`; BeeScript `emit()` and
  `particles(k, i)`. Systems undo, save (a PSYS chunk) and copy with a
  duplicate.
- Drawing and rendering them (P2, #338): points, sprites (round, their
  size) or instances of up to 8 objects (at random or along their way),
  with the colour and the size changing over their life; 1M points draw
  in about 1 ms, the same picture on any number of threads. Renders show
  them as tinted balls or their objects; the GPU helper renders them the
  same (100k instanced leaves, tests/gpu.py).
- Collisions and events (P3, #339): particles hit the Ground, landscapes,
  rigid bodies and cloth colliders (a segment cast a step: none passes
  through) and bounce, die, stick or split. Births, hits and deaths are
  events a second system is born of: rain that splashes, sparks that
  throw sparks.
- Liquid (P4, #340): position-based fluids (src/liquid.s) with water, oil
  and honey viscosities, vorticity confinement and surface tension; a
  domain box and the Ground as walls, the scene's colliders, and moving
  rigid bodies pushed both ways (a light box floats, a heavy one sinks).
  A dam break of 200k particles runs at about 350 ms a frame on 8
  threads; at rest the level is flat within one particle radius. `from
  fill` puts particles on a lattice inside the emitter.
- The liquid's surface (P5, #341): meshed each frame (a smoothed density
  field, marching tetrahedra) into a closed, manifold surface that its
  emitter shows and renders, with the water material; spray where it
  breaks feeds foam; `file.export_liquid` writes an OBJ a frame. The dam
  break meshes in about 140 ms on 8 threads.
- The Particles tab and presets (P6, #342): **Add › Particles ›** Rain,
  Snow, Sparks, Confetti, Fountain, Water Tank; Properties › Particles
  (systems, Emission, Motion, Look, Collisions, Liquid, Cache with Bake and
  Free). The simulation cache keeps particles (channel 2) and liquids
  (channel 3), plays them back when scrubbing, bakes them
  (`sim.bake particles liquid`) and saves them with the file.

### Fixed
- Material Preview is no longer much slower than Solid on big meshes: each
  mesh's smooth corner normals are kept between frames (made again only
  when the mesh changes) and turned into the view in parallel - 31 ms to
  3 ms a frame with a 127 000-face sphere.
- A huge mesh (millions of triangles, e.g. an Array of a dense mesh) no
  longer clips the viewport: the triangles past ~5.6 million, and every
  object after them, were dropped (the triangle slots were capped by a
  1 GiB frame arena; it reserves 16 GiB of address space now, used as
  touched).

## [0.21.0] - 2026-10-19

Stage A of the 2.0 plan (`Vibecoding/BeeModel-2.0-Plan.html`): attractors
and force fields, issues A1-A6 (#329-#334). [docs/FIELDS.md](docs/FIELDS.md).

### Added
- Force field objects (A1, #329): **Add › Force Field ›** Attractor (strength /
  distance squared, softened near its centre, or strength / distance; a
  negative strength pushes), Gravity Zone (a box or sphere whose down is its
  -Y), Wind (along its +X, with gusts), Vortex (turning round its +Y, with
  lift and inflow), Turbulence (curl noise) and Drag. Each has a falloff
  (none, radius, smooth), a strength that keys (`field:Name:strength`), the
  collision groups it acts on, and an on/off switch. They draw a gizmo of
  their kind and their reach. A Force Field section in Properties ›
  Physics, `field.add_<type>` and `field.set`, BeeScript `field()` and
  `force(x, y, z)`. Fields undo, save (a FLDS chunk) and copy with a
  duplicate.
- Fields on everything (A2, #330): rigid bodies feel the sum at their
  centre of mass each substep (velocity first, so a circular orbit keeps
  its radius within 0.1% over ten turns); cloth and soft bodies per
  particle, with wind fields as air for each triangle. World › Gravity
  switches the world's gravity off for space scenes. Changing a field runs
  the simulation again (the cache's key).
- Bodies that attract each other (A3, #331): **Attracts the others** on a
  rigid body (`rigid.add attracts`), G in World (`rigid.world g`). A
  Barnes-Hut octree once a step, the pulls across the workers, given as a
  leapfrog kick: two bodies orbit their common centre within 0.04%; 5445
  attracting bodies run at about 500 steps a second (physbench `nbody`).
  `rbinfo(22-24)`.
- Walk on a planet (A4, #332): in play mode the player's up follows the
  pull where it stands and the camera turns with it, so walking round a
  sphere with an attractor brings you back to where you started. Logic
  nodes **Set Strength** and **Field** (the pull at a point).
  `playinfo(16-18)`: the player's up.
- Seeing the fields (A5, #333): **View › Force Field Arrows** (the pull on a
  grid round the fields) and **View › Force Field Lines** (streamlines from
  the selected objects). Presets Planet (a sphere with its core, the
  world's gravity off), Black Hole, Tornado and Breeze, also as
  `field("tornado")`. `fieldinfo(k)`.

### Fixed
- A new armature's colour no longer comes from past the end of the
  per-type colour table.

## [0.20.0] - 2026-10-19

"UI round 2": the interface before the rest of the 2.0 plan
(`Vibecoding/BeeModel-UI2-Plan.html`), issues W1-W11 (#317-#327).

### Fixed
- **Picking a theme** (#317): a dropdown inside a dialog (Preferences'
  Theme, UI scale, the AI provider ...) opened under the dialog and took
  clicks unseen. Lists are drawn over dialogs now. A theme picked from the
  View menu or the Viewport panel is kept in the preferences too.
- The numeric keypad types values in fields, the console and the palette
  (#326).
- The AI Assistant reaching its turn limit (`error_max_turns`, Claude Code
  or Grok CLI) now says so and how to go on ("continue" resumes the
  session), and the default limit is 100 turns (was 40).
- Grok CLI no longer calls BeeModel's tools by their bare names (rejected as
  "not a valid MCP tool name"): its rules name them `beemodel__...` and say
  that a failed call does not mean BeeModel is disconnected.
- The AI Assistant's transcript can be selected: drag over the text, or
  double-click a message; Ctrl+C or Copy copies just the selection (Copy
  with nothing selected still copies everything).
- Rendered shading no longer flickers while an animation plays: it shows a
  raycast each frame until the scene holds still for 150 ms, then the
  path-traced samples.

### Added
- **More themes** (#318): Honey, Graphite, Nord, Solarized Dark, Solarized
  Light and Dracula, nine in all, each list showing a strip of every
  theme's colours.
- **A colour picker for every colour** (#319): R G B and H S V numbers, the
  ten colours used last (kept) and the scene's own; copy, paste and reset
  on any colour field; the object colour and the paint colour form are
  swatches; an accent colour of your own for any theme.
- **A clearer Physics panel** (#320): built from widgets in sections that
  fold (Rigid Body, Joints, Shatter, World, Cloth, Cloth World, the cache)
  under a status line. Type and shape before Add Rigid Body; dropdowns,
  units, start velocity and group; changes go to every selected body.
  Joints are listed and edited (type, the other body, pivot, axis, limits,
  motor, breaking force). Shatter gains seed, glue painting, the gap and
  the cut faces' colour; the cache says what is cached or baked.
- **A Landscape panel** (#321): a Landscape tab for a landscape: size and
  samples; the layer stack with eyes, the picked layer's values, Add, Up,
  Down, Remove (`landscape.layer up|down`); paint layers with their colour,
  friction, bounce and rules; Add Sea, import, export, to mesh, tiles.
  Add › Water (`landscape.add_water`); the presets ask size, samples and
  seed; the sculpt shelf paints all eight materials.
- **A more powerful file dialog** (#322): favourites, drives (mounted under
  /run/media, /media, /mnt, with their free space), recent folders (kept in
  `~/.config/beemodel/places`), back and forward, the folder's parts as
  buttons, size and modified columns sorted by a click, a filter box,
  hidden files (Ctrl+H), all files, image previews.
- **Folders in the outliner** (#323): nested groups that never move their
  objects, each with an eye, camera and lock for all inside; Ctrl+G, Move to
  Folder..., drag and drop, rename, fold; saved (FOLD) and undone;
  `folder()`, `infolder()`, `folders()`. Dragging a row shows a label at
  the pointer (what is dragged, what letting go does) and lights the row or
  folder that would take it (#327).
- **Reference images** (#324): Add › Reference Image... (or a picture
  dropped on the window, or `refimage()`): square to the view, upright,
  drawn in every shading mode behind or in front of the scene, with an
  opacity, the sides it shows, and orthographic-only or square-on-only
  views; not rendered.
- Demo scenes in `Vibecoding/demos`: a wrecking ball through a glued brick
  wall, exhibits that break on impact, a rockfall on an island; `play.sh`
  and `render.sh` (an MP4 through each demo's camera).

## [0.19.0] - 2026-10-18

"Shatter": stage S of the 2.0 plan (`Vibecoding/BeeModel-2.0-Plan.html`,
planned as v1.2.0; released before stage D's v1.0.0), issues S1-S7
(#309-#315). How it works: `docs/SHATTER.md`, `docs/PHYSICS.md`; the
benchmark: `tools/physbench.py` (shatter).

### Added
- **Cutting a closed mesh into cells** (#309): `object.shatter`. Each cell
  (a set of planes) is clipped from the mesh in doubles, and each plane's
  hole is filled at once, so every piece is closed. The holes are filled
  by bridging, ear clipping and merging back into convex polygons. A tree
  of cells cuts big meshes once near each cell, in parallel. Results:
  - the pieces' volumes add up to the original's within 1e-6, with no
    slivers;
  - 500 cells of a 49 000-triangle vase take about 54 ms;
  - an open mesh is repaired first.

  `mesh.separate_loose` (Mesh › Separate) splits a mesh into its loose
  parts.
- **The three patterns** (#310):
  - **shards**: Voronoi cells from seeds inside the mesh, spread evenly,
    gathered around a point (`at`, `cursor`) or near the `surface`;
  - **bricks**: a running bond in the object's axes, set by `size` or
    `counts`, with `offset`, a mortar `gap` and `jitter`;
  - **balls**: packed on a face-centred cubic lattice inside the mesh, none
    overlapping.

  `inner r g b` colours the cut faces. Each piece keeps the original's
  material.
- **Every piece a rigid body** (#311). Each piece is an active convex-hull
  body whose mass is its volume × the density (from `density`, else the
  material). Its centre of mass and inertia come from the hull itself. The
  pieces are children of the hidden original, and one undo step brings the
  original back. Piles of shards settle and sleep.
- **Glue** (#312): `glue N/m2 [paint]`. A fixed joint ties every two pieces
  whose cut faces meet and breaks at the strength × the shared area. Joints
  now break inside the solve, so a 30 kg ball at 20 m/s knocks a hole the
  size of the ball in a glued brick wall and the rest stands. Up to 16 384
  joints are allowed (ANIM v3 saves only those in use).
- **Shatter while it runs** (#313): `impact N s`. The object stays whole
  until a blow that hard, then breaks in the same step, where it was hit.
  Its pieces are made and glued beforehand, so no frame takes over 16 ms.
  A logic graph's **Shatter** node breaks it on demand. The cache keeps
  which objects are broken. New `rbinfo` keys 17-21 report the fastest
  body, joint rows and impact groups.
- **The Shatter form and panel** (#314):
  - Object › Physics › **Shatter...** opens a form that draws the cells as
    outlines on the object while it is open;
  - presets: Brick wall, Glass, Stone, Gravel balls (`preset`);
  - a **Shatter** section in Properties › Physics to re-cut with other
    settings (`again`);
  - BeeScript `shatter(name, pattern, count [, options])`, `shinfo(k)`,
    `get(name, "hidden")`, and `rigid(name, "x0")` / `"y0"` / `"z0"`.
- `tests/shatter.py` checks all of it, the form and the panel with clicks
  in the fake compositor. `tools/physbench.py` times a 99 072-triangle vase
  cut into 500 shards: 455 / 163 / 121 / 105 ms on 1 / 4 / 8 / 32 threads.

### Changed
- Seeds and balls are tested inside the mesh through a grid of its
  triangles, as seen along the test ray: 250 ms became 12 ms on the
  100 000-triangle vase.
- Hidden objects are not rigid bodies, except originals that wait to
  shatter.
- The joint list in Properties › Physics shows its first 6 joints.

### Notes
- Balls are not cut: they are spheres that fit inside the mesh, and the
  preview draws nothing for them.
- A lone thin wedge-shaped shard can rock on the ground for a long time
  before it sleeps.

## [0.18.0] - 2026-10-18

"Ground and landscape": stage G of the 2.0 plan (`Vibecoding/BeeModel-2.0-Plan.html`,
planned as v1.1.0; released before stage D's v1.0.0), issues G1-G7
(#301-#307). How it works: `docs/LANDSCAPE.md`, `docs/PHYSICS.md`; the
benchmark: `tools/physbench.py` (mountain).

### Added
- **The Ground** (#301): Add › Ground (`create.ground [height h]`), an
  endless floor, one a scene. The viewport draws it as a grid that fades
  with the distance from the view's centre. Renders make it a **shadow
  catcher**: the film has alpha (no sky behind objects, the shadows caught
  on the ground); the render window shows it over checks, and `render.save`
  and `render()` write RGBA PNGs. It is a passive plane rigid body (friction
  0.5), a cloth collider, and the player walks on it.
- **Landscapes** (#302): Add › Landscape, `landscape.add`. A heightfield of
  65 to 4097 samples a side over a chosen size, kept with its mesh (undo,
  copies, saving) and built from a stack of layers that stays editable:
  generate (fBm, ridged, billow, Voronoi cells), erode (droplets, then
  thermal), terrace, sculpted, flatten (round areas), heightmap; each with
  a strength, hidden or shown (`landscape.layer add|set|remove|hide|show`;
  `landscape.set size|res|detail`). A 1025 x 1025 landscape is generated and
  eroded in about 0.2 s, and a layer above the erosion changes in about
  4 ms (the erosion's result is cached). `landscape(name, k)`,
  `height(name, x, z)`.
- **Sculpting and painting landscapes** (#303). Sculpt mode on a landscape
  has its own tools, at its full resolution: raise, lower, smooth,
  flatten, ramp (a straight slope from where the stroke begins to where it
  ends), noise and erode, into a Sculpted layer; a stroke is one undo step.
  Paint layers (rock, grass, sand, snow, dirt, gravel, moss, mud: a colour,
  friction, bounce and a height and slope rule) are painted with clicks or
  by **Auto Paint** (rock on the slopes, grass on the flat ...); the blend
  shows in the viewport and in both path tracers. `landscape.brush`,
  `landscape.paint`.
- **The heightfield collider** (#304). A landscape made a passive mesh body
  is not cut into triangles: each step, the cells under whatever moves
  become triangles on the fly, in slots kept while in use, and contacts
  work as on a mesh. Each paint layer has its own friction and bounce (a
  box slides further on rock than on grass). Cloth lands on landscapes by
  their heights. 1000 balls roll down a 4097 x 4097 mountain, none under its
  surface, 10 s simulated in 2.4 s.
- **Presets and water** (#305): Add › Landscape › Flat, Hills, Mountains,
  Canyon, Dunes, Island. The island comes with its sea: a **Water** plane
  (the water material, rippled) that floats what is lighter than water - a
  wooden box floats, a stone one sinks - and that the player does not walk
  on. Generate gains `island` and `offset`. The welcome screen's Terrain
  template is a Hills landscape.
- **Heightmaps in and out** (#306): `landscape.import` (16-bit or 8-bit PNG,
  grey or colour; OpenEXR scanlines, half or float, uncompressed or ZIP),
  `landscape.export` (16-bit grey PNG - a PNG made so round-trips exactly -
  float EXR, or the paint as RGBA PNGs), `landscape.to_mesh [full]`, and
  `landscape.tiles k`, which splits a landscape into k x k landscapes that
  world partition streams (its cell files keep them as landscapes).
- `tests/landscape.py` checks all of it (with clicks on the fake compositor
  for the brushes, the paint and the menus); `tools/physbench.py` times the
  mountain.

### Notes
- A landscape is drawn at up to 513 samples a side (every 2nd, 4th ...
  sample of a bigger one); the tile LOD drawing the plan names is not done.
- Landscape painting lives in its sculpt mode's tools, not in Paint mode.

## [0.17.0] - 2026-10-17

"The solver": stage R of the 2.0 plan (`Vibecoding/BeeModel-2.0-Plan.html`),
issues R1-R7 (#286-#292). How it works: `docs/PHYSICS.md`; the benchmark:
`tools/physbench.py`.

### Added
- **The rigid-body solver takes each step in substeps** (#286, "soft step"):
  4 by default (`rigid.world substeps n`, Properties › Physics › World ›
  Substeps), with soft contacts that push overlaps apart as a damped spring
  (twice as stiff against static bodies) and a relax pass, restitution once
  at the end. Contacts between boxes and hulls are found by **clipping their
  faces** (`src/clip.s`): a box resting on another touches at its four
  corners. A tower of 20 boxes and a 10-layer brick pyramid stand (they
  used to topple), and a 100 kg box rests on a 1 kg one. `tests/solver.py`.
- **10 000 rigid bodies** (#287). Instances are bodies: `rigid.add ...
  instances` (Properties › Physics › Bodies) makes each instance of an
  object's geometry nodes a body shaped like its prototype; they move in
  the viewport and the renders, are baked into the cache and played back.
  Up to 4096 objects can be bodies (was 1024; files save only those in use
  and older files open). The broad phase is a hash grid, pairs are looked
  up in parallel in a hash kept between steps, and a big island's contacts
  are coloured and solved across the threads (the same result on any
  number of them). Contacts start further apart for fast bodies, so small
  ones no longer pass through each other; spheres collide exactly. 10 800
  balls poured into a box: 10 s simulated in about 26 s on 8 threads (4000
  took 23 s before); 5000 bricks settle at about 27 fps; 1000 tumbling
  boxes in 2.7 s (was 6.2). `instpos(object, i, k)`; `rbinfo(8..14)`.
- **Mesh and plane colliders** (#288). A passive rigid body can be its
  **mesh** - any shape, each triangle a collider, found through a tree - or
  an endless **plane** (`rigid.add passive mesh`, `passive plane`;
  Properties › Physics › shape). Edges inside a flat surface don't catch:
  a contact there takes the face's normal, so a box slides over a ramp of
  thousands of triangles without a bump. Balls and boxes in a bowl, boxes
  on a staircase, 1000 balls on a terrain of 100 000 triangles at about
  50 fps on 8 threads, a box landing on a plane 500 m out.
- **Fast bodies, groups and materials** (#289). A body that moves more
  than half its size in a step is stopped short of static bodies by
  continuous collision, and contacts start as far apart as two bodies can
  close in a step: a 1 cm ball at 300 m/s and a tumbling box at 60 m/s
  stop at a 1 cm wall. Collision groups: `rigid.add ... group n collide m`
  (16 groups; m the groups it meets). Physics materials: `material
  rubber|ice|wood|metal|stone` and Properties › Physics › Material. A
  starting velocity: `rigid.add ... velocity x y z`.
- **Breakable joints, limits, motors and sliders** (#290). `rigid.joint
  ... break f` breaks a joint whose load passes f newtons (it is gone for
  the rest of the run; `rbinfo(15)` counts them); `limits lo hi` stops a
  hinge (degrees) or a slider (metres) there; `motor speed force` turns a
  hinge (degrees a second) or moves a slider (metres a second) with at
  most that torque or force. A new `slider` joint keeps two bodies on a
  line, turning together (Add Joint › Type › Slider).
- **The same result on any number of threads** (#291): 1000 tumbling
  boxes, 5000 bricks and the joint tests end bit for bit the same on 1, 4,
  8 and 32 threads; `rbinfo(16)` hashes every body's state to show it.
- **The MIT License** (`LICENSE`, also in the release archive). The
  2.0 plan (`Vibecoding/BeeModel-2.0-Plan.html`): the masterplan's open
  questions, then physics - the solver, ground and landscapes, shatter,
  attractors, particles, smoke and fire.

### Fixed
- Rigid bodies: a body given an impulse when play began (Logic › Apply
  Impulse) did not move - the bodies were made again on the next frame.
  Continuous collision skips a body touching what it is checked against
  where its step began (it rests or slides on it).
- Rigid bodies: a thin passive box (under 5 cm) was made 25 cm deep on
  every thin axis - meant for floors, it also thickened thin walls
  towards whatever came at them. Only a floor's own Y now; a passive body
  with no bounce no longer stops what comes at it short of it.
- Sculpting: each thread's sums for a dab (the area's weight, centre and
  normal) get a cache line of their own. Two threads shared one, and how
  much that cost depended on where the linker put them (a brush frame took
  4.1 ms instead of 2.6 when unrelated data moved).
- `parallel_for`: a worker still leaving one call could take a chunk of
  the next - with the old chunk size, or past the old count - and part of
  it ran twice (a crash, or a different result, when many calls with
  different sizes ran back to back: the rigid-body steps). A chunk is now
  claimed by compare-and-swap on one word that holds the call's generation
  and the next index; the caller closes the last call's claim before it
  writes the next. The self-test runs 3000 calls back to back.

## [0.16.0] - 2026-10-17

"UI follow-ups": the parts of the UI plan (phase 11) left open at v0.12.0,
issues F1-F18 (#267-#284; `Vibecoding/BeeModel-UI-Plan.html`, section
Status), and Rendered shading.

### Added
- **Text fields:** Ctrl+Left / Right jump by word (Shift selects), Ctrl+Backspace /
  Delete remove a word.
- **File browser:** Tab completes a folder or file name in the path field (a
  second Tab lists the matches); opening a scene shows a picture of it - saving
  from the window keeps a 192 x 120 picture of the 3D viewport in the `.bee`
  file (THMB, its first chunk).
- **Pie menus** for the mode (hold Ctrl+Tab) and for the 3D cursor and snapping
  (hold Shift+S: Cursor to Selected, Selection to Cursor, Selection to Grid,
  Snap, Reset 3D Cursor - also in Object > Snap); a tap keeps the key's own
  action. `mode.object` / `mode.edit` / ... operators.
- **Context menus** on fields (Reset to Default, Copy / Paste Value, Insert
  Keyframe, Copy Data Path), in the timeline (playback, Start / End at This
  Frame), the dope sheet and graph editor (interpolation, handles, duplicate,
  delete), and on files in the file browser (Open, Rename, Delete, New Folder,
  Copy Path); context menus show over dialogs.
- **The redo panel** is made of widget fields: drag, type a value or an
  expression, an axis from a list.
- **The 3D viewport's header:** View / Select / Object (Mesh) menus, a pivot
  point and orientation menu - Median Point, 3D Cursor, Individual Origins,
  Active Object; Global, Local, View, Normal (`view.pivot`,
  `view.orientation`) - which moves and turns follow, and an Overlays menu
  (grid, Text Info, Statistics, Navigation Gizmo, the mesh checks).
- **The navigation gizmo:** drag a ball to orbit; zoom and pan handles under
  it; an orthographic view (Numpad 5, `view.toggle_ortho`).
- **Views glide** to an axis, a reset camera or the new **Frame Selected**
  (Numpad .); Preferences > Interface > **Reduce motion** makes them jump.
- **Sculpting:** brush falloff curves (smooth, sphere, root, sharp, linear,
  constant; `sculpt.falloff`), the dynamic-topology detail in the brush bar,
  and **symmetry across Y and Z** as well as X, in any combination
  (`sculpt.symmetry xyz`).
- **Status bar chips for long jobs** - map, probe, lightmap and simulation
  bakes and imports - with their progress; the window keeps drawing while they
  run. A chip for the live link (click: the Versions editor).
- **CAD:** reorder features in the feature tree (up / down buttons,
  `cad.feature_move`); a feature that now needs a later one is marked.
- **Print Check** shows its findings in Properties > Object, each with a Show
  button that selects those edges or faces and frames them.
- **Outliner:** a lock (viewport clicks pass through) and a camera (left out of
  renders) next to the eye; Ctrl+click toggles a row, Shift+click selects a
  range.
- **Parenting:** Ctrl+P / Alt+P (Object > Parent), a Parent field in
  Properties > Object, the outliner as a tree (fold arrows, drag a row onto
  another). Children keep their world transforms and follow their parent's
  changes, whatever makes them; parents are kept in `.bee` files (PRNT).
  BeeScript `parent(name)`, `issel(name)`.
- **Lights:** a type - point, sun, spot, area - and a size: a radius gives
  soft shadows, a sun its angle, an area light its edge; a spot's cone. Both
  path tracers sample them alike; the viewport draws each light's shape;
  Properties > Object and `light.set type / size / angle`.
- **Export Drawing (PDF) options:** the sheet (A4, A3, A2, Letter; landscape or
  portrait), the views (front, top, right and an isometric view), the scale
  (fit, or 2:1 .. 1:100) and the title block's title and author, with today's
  date; `drawing.options` for scripts.
- **The welcome screen** shows the version.
- **Scripts:** `scripts/build.sh`, `scripts/run.sh`, `scripts/package.sh`
  (moved from the root) and `scripts/deploy-omarchy.sh`, which builds and
  installs BeeModel on Omarchy with its bar plugin (`omarchy-plugin/`).
- **Rendered shading:** a fourth viewport shading, drawn on the GPU (the
  optional `beemodel-gpu` helper). While the view or the scene changes, one
  raycast a frame: the sun and point lights with hard shadows through the
  real BSDF, the sky with short-range occlusion and a rough first bounce,
  mirrors and glass followed. Once the view is still, Hive's path-traced
  samples accumulate on the GPU up to Preferences › Viewport › Rendered
  samples (64; 0 keeps the raycast alone), denoised on the GPU every frame
  (the F12 render's guided à-trous filter; Preferences › Viewport ›
  Rendered denoise, `view.rendered_denoise`). The selection outline and the
  overlays stay on top. The scene goes up again only when it changes (a
  fingerprint of objects, mesh versions, lights, materials and undo steps);
  a slow-to-build scene waits for the change to end. An F12 render runs
  beside it. Without the helper Rendered shows Material Preview. In the
  header, the Z pie, View › Rendered, Properties › Viewport;
  `view.shading_rendered`, `view.rendered_samples <n>`,
  `view.rendered_denoise [0|1]`; `gpu(7)`..`gpu(14)`.
  See [docs/GPU.md](docs/GPU.md#rendered-shading-the-live-viewport).
- **The AI Assistant's Copy** button (`ai.copy`): the whole conversation on
  the clipboard.
- `walkthrough16_ui`: the new pieces driven with clicks and keys only:
  outliner Ctrl+click, Ctrl+P, the lock, a spot light, the snap pie,
  Numpad ., save and reopen with the scene's picture.

### Fixed
- A GPU render of a scene with nothing to render (every mesh hidden, left out
  of renders or deleted) after an earlier render could crash: the upload read
  the last scene's freed arrays. They are cleared when Hive lets them go.
- The AI Assistant: a stream line longer than its buffer (an image from
  `viewport_capture`) is left out with a note instead of spilling base64
  into the conversation; a result's later lines are indented.
- BeeScript's "unexpected character" names the character, and explains that
  there are no lists for `[` and `]`; the AI's instructions say so too.

## [0.15.0] - 2026-10-16

Phase 14, "Blender files" (`Vibecoding/BeeModel-Blend-Plan.html`).
BeeModel opens `.blend` files natively and saves them through Blender. The
guide is [docs/BLEND.md](docs/BLEND.md).

### Added (Blender files)
- **The .blend reader (B1, #258):**
  - both headers: the 12-byte one, and Blender 5's 17-byte one with 64-bit
    block lengths;
  - zstd files through the `zstd` program, gzip ones through BeeModel's
    inflate;
  - every field looked up by name in the file's DNA, with Blender's old
    names as alternatives;
  - pointers matched within the ID being read (Blender 5 numbers each ID's
    data on its own).
- **Meshes (B2, #259):** all three layouts (`MVert` / `MPoly` / `MLoop`;
  `CustomData` layers in 3.4–4.x; `AttributeStorage` in 5.x). Positions,
  n-gons, the active UV map and material indices, checked against the
  file's block sizes.
- **Objects, cameras and lights (B3, #260):**
  - the current scene's view layer, with excluded collections skipped;
  - world matrices from location, any rotation mode, scale, their deltas
    and the parent chain with its inverse, turned from Z up to Y up and
    taken apart into place, rotation and scale (baked into the mesh when
    it shears);
  - an object per material used;
  - camera lens and the scene's camera;
  - light colour and power.
- **Materials and images (B4, #261):** Principled BSDF values. Image
  Texture nodes on base colour and emission, and a Normal Map node's image,
  become texture maps. Images come from the file (packed) or from beside it.
- **Import everywhere (B5, #262):**
  - `file.import_blend`;
  - File › Import › Import Blender...;
  - the file browser's `.blend` filter;
  - **files dropped on the window** (`text/uri-list` over the Wayland data
    device): `.blend`, glTF, OBJ, STL and STEP are imported, and `.bee`
    opens when nothing is unsaved.
- **Export through Blender (B6, #263):** `file.export_blend` and File ›
  Export › Export Blender...:
  - glTF goes to a private folder, and Blender runs in the background
    (merge vertices, join triangles into quads, save);
  - a message says when it is saved, or shows Blender's error;
  - the Blender program is set in Preferences › Files;
  - the glTF export now writes cameras.
- BeeScript `get` / `set` of a camera's `lens` and a light's `power` and
  colour (`lr`, `lg`, `lb`).
- **Tests (B7, #264):** `tests/blend.py`, with fixtures and expected values
  from Blender 5.2 and 4.2 (zstd, plain and gzip). It covers the window's
  menu and drop, and runs an export round trip and a million-triangle
  import when Blender is installed.

## [0.14.0] - 2026-10-16

Phase 13, "AI first" (`Vibecoding/BeeModel-AI-Plan.html`): the AI comes
inside the app. Describe a world, a model or a change, and an AI Assistant
builds it in the scene through BeeModel's own tools, over Claude Code, the
Grok CLI or OpenRouter. A real Preferences dialog holds every setting,
connections included. The guide is [docs/AI.md](docs/AI.md).

### Added (AI first)
- **The Preferences dialog (A1, #246):** Edit › Preferences and Ctrl+,
  open a modal dialog. It has a search across every category, eight
  categories (Interface, Viewport, Input, Keymap, Rendering, System, Files,
  AI) and Reset to Defaults per category. The Preferences area shows the
  same view.
- **More settings (A2, #247):** the viewport's grid size, field of view
  and clip start; the default render resolution, samples and denoise. Each
  one is saved and applied.
- **AI connections (A3, #248):**
  - the default connection;
  - Claude Code and Grok: program, model and turn limit;
  - OpenRouter: key, model, address and step limit;
  - text added to every request.

  The OpenRouter key is masked and kept only in `~/.config/beemodel/secrets`
  (mode 0600), with `OPENROUTER_API_KEY` as the fallback.
- **Child processes and HTTPS (A4, #249):** one child at a time. Its output
  is read from the main loop without waiting, and Stop ends it (TERM, then
  KILL). HTTPS goes through `curl`: the body and the key's header are in
  private files, never on a command line.
- **Claude Code (A5, #250):** `claude -p` with `stream-json`, an MCP
  configuration naming `beemodel --mcp-bridge` for this instance,
  `--strict-mcp-config --allowedTools mcp__beemodel`, the turn limit and the
  instructions. Follow-ups use `--resume`.
- **Grok CLI (A6, #251):** `grok -p` with `streaming-messages-json`. It
  runs in its own agent directory with a `.grok/config.toml`, which it
  loads because it runs with `--trust`. Its shell, file, sub-agent and web
  tools are turned off. Follow-ups use `-r`.
- **OpenRouter (A7, #252):** chat completions with the curated MCP tools as
  functions (not the 600 single-operator tools). BeeModel runs each tool
  call in-process (`mcp_local`, under the same permission, undo and AI
  Activity as other agents) until the model answers or the step limit is
  reached.
- **The AI Assistant area and the AI workspace (A8, #253):**
  - the connection picker, New, Revert, the transcript (text, tool calls,
    results, errors), the prompt (Enter sends), Send and Stop;
  - Ctrl+Shift+Space and AI › AI Assistant open it; the first time, they
    make the AI workspace (a viewport, the assistant, the outliner);
  - each request is one undo step, `Agent: <prompt>`;
  - `ai.transcript` prints the conversation.

  Preferences › AI has Test buttons for the three connections.
- **Prompt to world (A9, #254):** the world-building instructions (the
  conventions, the look-plan-build-check loop, and BeeScript recipes for
  primitives, materials, terrain, scattering, lights and a camera) go with
  every request. They are also the MCP prompt `build_world`.
- **Tests (A10, #255):** `tests/ai.py` runs Claude Code and Grok
  stand-ins and a localhost OpenRouter, with no network and no account.

## [0.13.0] - 2026-10-15

Phase 12, "PBR materials and a material editor"
(`Vibecoding/BeeModel-Materials-Plan.html`): materials are physically based
and driven by node graphs edited the way Unreal Engine's material editor
works: a 42-node catalogue, a zoomable canvas with live previews,
parameters and material instances, shared material functions, texture-set
import, presets, baking to texture maps, glTF and OBJ texture exchange, and
graphs on the GPU path tracer. The guide is [docs/MATERIALS.md](docs/MATERIALS.md).

### Added (PBR materials and material editor)
- **Material records v2 (M1, #228):** materials grow to 4 KiB: graphs of
  48 nodes, links that take a node's output 0..3, and a Material Output
  with 13 pins (base, metallic, specular, roughness, emission, opacity,
  normal, ambient occlusion, clear coat, coat roughness, transmission, IOR,
  opacity mask). Blend modes (opaque, masked, translucent), one-sided
  materials and the mask clip value, in the Material tab, `matset` and
  glTF (`alphaMode`, `alphaCutoff`, `doubleSided`). The path tracer lets
  rays and shadows through holes and translucent surfaces; the preview
  takes specular, IOR (F0) and AO from nodes. v0.12 files and `.beea`
  material assets open unchanged.
- **Node catalogue (M2, #229):** 35 node types (from 9) with several
  outputs each: texture coordinate, position, normal, camera vector,
  vertex colour, time, constant, colour, Fresnel; vector math, separate,
  combine, mapping, panner, rotator; Voronoi, brick, wave, white noise,
  triplanar; hue / saturation, invert, brightness / contrast,
  desaturation, gamma, blackbody; 31 math operations; 11 mix modes;
  radial and spherical gradients. Texture Sample gives colour, R, G, B and
  alpha, reads images as colour (sRGB) or data, and repeats, clamps or
  mirrors. Node headers are coloured by category. `nodeval()` evaluates
  any node at a point.
- **Node canvas (M4, #231):** zoom about the pointer with the text sized
  to match, Home / F to frame everything or the selection, box select,
  moving a whole selection, copy / paste (into other materials too),
  duplicate, cut, collapse (H), comment frames (C) that carry their
  nodes, reroute knots (double-click a wire), cutting wires (Alt+click,
  an Alt+drag knife), dropping a wire in empty space to add the node it
  feeds, wire colours by what they carry, align and distribute, a
  minimap and a right-click node menu. One undo step each.
- **Material editor (M5, #232):** the add menu in a column per category
  with shortcuts that preset an operation (Add, Multiply, Lerp, Dot
  Product ...), a palette beside the canvas (search, click or drag to
  add), Unreal's quick keys (1, 3, T, U, A, M, D, E, L, O, N, P, B, then a
  click), the selected node's values as fields in the Material tab, a
  value clicked twice typed in the console, `node.zoom`, and Material
  Output pins the blend mode doesn't use dimmed.
- **Live previews (M6, #233):** a preview pane with the material on a
  sphere, cube or plane (drag to turn, click for the next shape), a
  thumbnail of every node's output, and a stats line with warnings
  (nodes that lead nowhere, texture samples without an image). Each edit
  re-renders them within a frame: 9 ms for 24 nodes (budget 16 ms).
- **Parameters and material instances (M7, #234):** Scalar, Vector and
  Texture Parameter nodes with names; `material.instance` (Material tab:
  New Instance) makes an instance that shares its parent's graph and
  values and overrides parameters (override boxes in the Material tab,
  `matparam`, `material.param`, `material.param_reset`); parent edits
  reach every instance, instances of instances work, parameters can be
  keyed (`material:Blue:Wear`), and everything is saved. 100 instances of
  one material render in one image, each with its own colour.
- **Texture sets and presets (M9, #236):** `material.import_textures`
  (Material tab: Texture Set...) builds a PBR material from any one image
  of a texture set: its siblings are found by name (base colour, normal,
  roughness or gloss, metallic, AO, height, emission, opacity, packed
  ORM / ARM; `_2k`, `_dx` and the like understood) and wired through
  Texture Sample, Normal Map and Bump nodes. The Normal Map node reads
  DirectX (-Y) maps too. `material.preset` (Material tab: Preset...) gives
  a material one of 20 looks, from gold and glass to procedural wood,
  marble, concrete, fabric and leather.
- **Materials for scripts, agents and docs (M12, #239):** MCP tools
  `material_node_types` (the catalogue), `material_graph` and
  `material_graph_set` (a graph as JSON, read and written; a loop or an
  unknown type is refused and nothing changes); `scene_summary` gives each
  node's place and parameter name. docs/MATERIALS.md describes the whole
  system; tests/materials.py walks through it (texture set, preset,
  baking, instances, a shared function, a masked leaf, the file and glTF).
- **Shader graphs on the GPU (M10, #237):** the GPU path tracer
  evaluates material graphs (textures, patterns, math, mixes, bump and
  normal maps; a second kernel built only when a scene has graphs) and
  lets rays through masked, translucent and one-sided materials. A
  textured, bumped, normal-mapped and masked scene renders the CPU's image
  (99.8% of pixels identical); graphs with other nodes stay on the CPU.
- **Faster material graphs (M3, #230):** each graph is compiled per edit:
  nodes that do not depend on the shading point (math, mixes, colours,
  parameters fed only by such nodes) are evaluated once and their results
  copied in; the Noise node runs its three channels four-wide (SSE, the
  same numbers as before); node dispatch is a table. A 40-node game-style
  material previews at about 2.2x a principled one while orbiting (was
  3x); a heavy procedural one (noise, voronoi, wave, bump) at about 7.6x
  (was 10x). The path tracer renders the product shot 26% faster than
  v0.12. `--selftest` checks the four-wide noise and the folding on random
  graphs.
- **Material functions (M8, #235):** a material function is a graph from
  Function Input nodes (In 1..3) to a Function Output (Out 1..3); a
  Material Function node runs it inline with its inputs, so one function
  can serve many materials and an edit to it reaches all of them. In the
  node editor, Ctrl+G turns the selected nodes into a function (links from
  outside become its inputs, what was used outside its outputs) and Tab
  on a Material Function node edits the function (Tab again: back).
  `material.function_new`, `material.make_function`; calls nest 8 deep.
- **Material baking, glTF and OBJ texture maps (M11, #238):**
  `material.bake <object> [size] [apply]` (Material tab: Bake to Maps)
  bakes a material's node graph through the object's UVs into base
  colour, ORM, tangent-space normal and emissive maps; with `apply` the
  material samples them. glTF import reads `TEXCOORD_0` and the five
  texture slots (base colour, metallic-roughness, normal, occlusion,
  emissive) with `KHR_texture_transform`, from GLB buffer views, data:
  URIs or files; export embeds the maps as PNGs, image graphs as they are
  and procedural ones baked. MTL gains `map_Pr`, `map_Pm`, `map_Ke`,
  `norm` / `map_Bump` and `map_d` both ways (`-imfchan` for packed maps).
  A helmet-style fixture round-trips with its textures, and Blender reads
  our maps.

## [0.12.0] - 2026-10-15

Phase 11, "UI & usability" (`Vibecoding/BeeModel-UI-Plan.html`): every
feature is one click away. You never need the console: each command has a
menu entry, a panel or a dialog, and the window works with the mouse or the
keyboard alone. The tour is in [docs/UI.md](docs/UI.md).

### Added (UI and usability)
- **Look:** Dark, Light and High contrast themes, all text at 4.5:1 or
  more; anti-aliased rounded shapes and shadows; font roles; 94 vector icons
  (U1-U2, U5).
- **Widget toolkit:** fields that scrub, take typed values and expressions,
  copy and paste, and key with I; toggles, sliders, option lists, colour
  fields with a picker (hue, square, hex, Pick from the screen), sections,
  tabs, scrolled regions; one undo step per change. The MCP tool `ui_tree`
  lists every widget for agents and tests (U3, U9, U17).
- **Help in place:** tooltips with the shortcut, what it does and why it is
  greyed; a status bar with the keys that work now and toasts; F1 for every
  shortcut; a Help area; a welcome screen with templates, samples and
  recent files; quick actions in an empty viewport (U4, U14, U25).
- **Menus and dialogs:** two-level menus (File ... Help), right-click menus,
  a Z pie; forms for every command that takes values; "Save changes?"; a
  file browser with export options; Open Recent (U6-U8, U15).
- **Editors:** a Properties editor with Object, Modifiers, Material,
  Physics, CAD, Scene, Render, Viewport, Animation and Rig tabs; a viewport
  header and navigation gizmo; a tool shelf that follows the mode; brush
  bars; an outliner with icons, eyes, rename and a filter; headers for the
  node, UV, timeline, dope sheet, graph, render and asset editors; new
  Versions, Preferences and Help editors (U10-U13, U16-U22).
- **Feature panels:** CAD features, parameters and joints; materials, the
  world, images and modifiers; paint colour and layers, weight and bones,
  UVs and baking; keys, shape keys, actions, drivers, constraints and
  bones; cloth, joints and the simulation cache; render, GPU, virtualized
  geometry, world partition, probes, lightmaps and play mode; a light's
  power and colour and a camera's lens (saved as LCAM); the asset library,
  versions, co-editing, the live link and the agents (U16-U22).
- **Preferences** saved in `~/.config/beemodel/prefs`: theme, UI scale
  (75-200 %), tooltip delay, keymap overrides, input, threads, GPU, JIT,
  autosave, library folders, the agents and MCP (U23).
- **Workspaces:** Modeling, Sculpt, CAD, Shading, Animation and World plus
  your own, as tabs in the menu bar; swap and join areas by dragging (U24).
- **Keyboard and accessibility:** F6 between areas, Tab / Shift+Tab through
  any panel's or dialog's widgets, Enter / Space / arrows on the focused
  one; colour-blind-safe axis colours (U26).
- **Tests:** a fakewl scenario per step, driven through `ui_tree` names,
  and `walkthrough_ui`: model, a CAD feature, a material, a render, save and
  reopen with clicks and keys only (U27).

### Performance (UI)
- **UI frames:** with the Object, Modifiers, Material or Render tab on
  screen and the pointer moving over it, a frame takes 1.4-3.5 ms (median,
  1280 x 800, software rendering); the budget is 16 ms (`ui_bench`).
- **Size:** the binary is about 1.08 MB; the budget went to 1.5 MiB.

## [0.11.0] - 2026-10-15

Phase 10 of the masterplan, "Engine-grade & collaboration". BeeModel scales
up and opens up to teams:

- **Scale:** cluster LOD DAGs (virtualized geometry) drawn through a new cut
  every frame, world partition streaming and a content library.
- **Play:** play mode with walk and fly, logic graphs, light probes and
  lightmaps, and a live link that streams the scene over a socket.
- **Teams:** versioned scenes (commit, branch, visual diff, three-way
  merge) and live CRDT co-editing for two users and an AI agent.
- **CAD:** an exact B-rep / NURBS kernel and STEP import and export.
- **GPU:** the optional `beemodel-gpu` helper path-traces and rasterizes on
  Vulkan, a second release asset; BeeModel itself still links nothing.

The exit checks: 1.05 billion source triangles fly at 5.8 ms a frame
(median) in an 851 MB process (`tests/billion.py`, budget 8 GB); two users
and an agent edit one scene and converge to identical documents
(`tests/coedit.py`); STEP parts and assemblies round-trip through FreeCAD to
1e-6 (`tests/step.py`).

### Added
- **Cluster LOD DAG** (virtualized geometry, part 1, #143). `vgeo.build`
  turns the active mesh into meshlets: clusters of up to 128 triangles and
  128 vertices, grown over their neighbours and seeded in Morton order.
  - **Levels:** each level groups neighbouring clusters, by shared edges and
    up to 1024 triangles, preferring edges across the old group borders so
    those get simplified too. Each group is simplified to half its triangles
    (area-weighted quadrics, half-edge collapses), with the group's border
    locked and no collapse that folds a pillow. It is then split into new
    clusters. This repeats until one cluster is left (a 1M-triangle sculpt:
    14 levels, one root of ~120 triangles).
  - **Errors:** every cluster keeps its bounds and the error and LOD sphere
    of the group that made it and of its parents' group. Errors only grow up
    the DAG and the spheres nest, so any cut is crack-free. The self-test
    checks every level, 16 error thresholds and 24 cameras on a torus, a
    rippled 1M-triangle grid and 216 separate cubes.
  - **Storage:** one block, shared by the mesh's copies, saved in a VGEO
    chunk that starts on a page of the `.bee` file. In the window it is built
    on a background thread while the UI keeps drawing: about 120 ms per
    million triangles on 32 threads. Editing the mesh makes it out of date.
  - **Operators and scripts:** `vgeo.extract <level | error>` adds a cut as
    a mesh with its clusters coloured, `vgeo.clear` drops the DAG, and
    BeeScript's `vgeo(name, k)` reports on it.
- **Drawing cluster DAGs** (virtualized geometry, part 2, #144). A mesh with
  a DAG is drawn through a new cut every frame (`src/vgdraw.s`).
  - **Cuts:** from the roots down, a group is refined while its error,
    projected from the camera, is over one pixel (`vgeo.error`). Each object
    is cut on its own thread; the chosen clusters are decoded into a mesh in
    the frame arena (64 clusters a job) and rasterized like any other.
  - **Culling:** a group whose LOD sphere is outside the frustum is skipped
    whole, and so is each cluster outside it. A cluster hidden behind last
    frame's depth pyramid (seen from last frame's camera) waits. After the
    first batch is drawn, the pyramid is built from this frame's depth, and
    the waiting clusters that are visible after all are drawn in a second
    batch.
  - **Streaming:** a DAG read from a `.bee` file stays mapped from it.
    Cluster data comes in 64 KiB pages, read ahead (madvise) when a group
    needs them and counted in once they are in memory. Past the budget
    (`vgeo.budget`, default 2 GB), the least recently used pages are given
    back; the roots' pages always stay. A group whose members are not in yet
    is drawn as the clusters it made, which keeps the cut crack-free.
  - **Proxies:** `vgeo.proxy` replaces the mesh, everywhere it is used, by
    its DAG's roots (welded), and the DAG goes with it. Files and memory
    then hold the DAG only.
  - **The exit check:** [tests/billion.py](tests/billion.py) builds 64
    unique million-triangle terrain tiles and 8 boulders, places 960 linked
    copies (1.05 billion source triangles, a 2.1 GB file), reopens it and
    flies over it. Frames take 5.8 ms at the median (8.2 ms at the 95th
    percentile) on 32 threads. The process peaks at 851 MB, with 64 MB of
    pages under a small budget.
  - **Tools:** `vgeo.view clusters | shaded | off | check` (check: the
    drawn cut against level 0, for cracks), BeeScript `vgstat(k)` (the last
    frame's cut, culling and streaming) and `view(yaw, pitch, distance, x,
    y, z)` (the viewport camera). The zoom now goes out to 20 km.
- **World partition** (#145). `world.partition <cell size> [radius]`
  splits a saved scene into grid cells on the ground (`src/world.s`).
  - **Cells:** plain mesh objects belong to the cell under them. Each cell
    is its own file beside the scene (`<name>.cells/<x>_<z>.cell`: meshes,
    UVs, colours, cluster DAGs and objects). The scene file keeps
    everything else and an index of the cells; on opening, the cells
    directory is read too.
  - **Streaming:** each pass of the main loop (and `world.update` in
    scripts) unloads cells past 1.25 x the radius, loads the cells in reach
    nearest first (two a pass) while the budget (`world.budget`) allows, and
    unloads the farthest while the budget is passed.
  - **Edits:** a fingerprint of each cell's objects tells a changed cell,
    which is written before it unloads. An object moved into a cell that is
    not loaded pulls that cell in, so objects cross borders. Saving writes
    the changed cells and keeps their objects out of the scene file; saving
    elsewhere copies the cells along. Streaming starts the undo history
    afresh (`undo_clear`).
  - **Showing it:** unloaded cells are drawn as boxes in the viewport, and a
    minimap (`world.minimap`) shows every cell (loaded, changed, on disk),
    the camera and its radius. BeeScript `world(k)` reports.
  - [tests/world.py](tests/world.py) makes a 32 x 32 map of 4096 objects
    while partitioned (1024 cell files), flies over it under an 8 MB budget
    at ~3 ms a frame, edits on the way, and checks the edits after flying
    away, flying back, saving and opening again.
- **Content library** (#146). The Asset Browser grows into a content browser
  over libraries of assets kept by their content (`src/library.s`).
  - **Assets:** `lib.save object|rig|scene [name] [#tag ...]` and
    `lib.save material|tree|action <name>`. Objects keep their meshes as
    evaluated, UVs, colours and cluster DAGs, with their materials saved as
    assets they depend on; rigs keep the armature, the skinned meshes and
    their weights; actions keep their curves; scenes are whole `.bee` files.
  - **Content-addressed:** each blob is `blobs/<hash>.bee`, named by a
    64-bit hash of its bytes, so identical content is stored once. An
    asset's id hashes its kind, name, blob and dependencies. `index.txt`
    lists the assets; `lib.add <folder>` adds more libraries.
  - **Placing:** `lib.place <asset> [x y z]` (default: the 3D cursor) brings
    in dependencies first, places objects selected, rebinds rig meshes, and
    plays an action on the active object. Dragging a tile into a viewport
    places the asset on the surface under the pointer; a double click places
    it at the cursor.
  - **Thumbnails:** path-traced by a child process
    (`beemodel --eval 'op("lib.thumbnail", id)'`), one at a time, while the
    window goes on; `lib.thumbnails` makes them all now.
  - **Finding things:** tags (`lib.tag Pillar #heavy -old`), search
    (`lib.search`: every word in the name, kind or tags), dependencies
    (`lib.deps`, and the browser's uses / used by).
  - **Packs:** `lib.pack <file.bee> [search]` writes the matching assets and
    what they use: a manifest, each blob once, the thumbnails. `lib.import`
    checks each blob against its hash and adds only what is new.
  - **Everywhere:** every operation is an MCP tool (`op_lib_*`; packs and
    library folders need the agent's file permission). BeeScript gets
    `lib(k)`, `libfind(words, i)` and `libinfo(asset, what)`.
    [tests/library.py](tests/library.py) checks the blob names against the
    hash, packs into a fresh library, background thumbnails, dropping into
    the viewport, and MCP.
- **Play mode** (#147). F5 (`play.start [walk|fly] [x y z]`) snapshots the
  scene and plays it from the view (`src/play.s`).
  - **Walking:** a capsule (0.3 m radius, eyes at 1.6 m) under the rigid
    body world's gravity, in fixed 1/120 s steps against every mesh
    (a per-mesh grid of triangles, built on first use). It stands on
    slopes up to about 50 degrees and slides off steeper ones, is stopped
    by walls, climbs steps up to 0.4 m and keeps to the ground going down
    a slope. WASD moves, Shift runs, Space jumps; F switches to a fly
    camera (Space / C up and down).
  - **Captured mouse:** the pointer is locked
    (`zwp_pointer_constraints_v1`) and its relative motion
    (`zwp_relative_pointer_v1`) turns the view; the cursor is hidden.
  - **Live scene:** the frame runs on in real time, so rigid bodies, cloth,
    keyed animation and rigs play while you walk.
  - **Leaving:** Esc frees the mouse and asks: K keeps what happened as one
    undo step, D (or Esc) discards it, the scene, the frame and the view
    as they were. `play.stop [keep|discard]` does the same from scripts.
  - **Scripted:** every operation is an MCP tool (`op_play_start`,
    `op_play_stop`, `op_play_mode`); BeeScript gets `playstep(seconds,
    forward, right, up, run)`, `playlook(yaw, pitch)` and `playinfo(k)`.
    [tests/play.py](tests/play.py) walks a small level (walls, stairs, a
    ramp, a slope too steep, falling boxes, a keyed spinner) and plays it
    in a window with keys, mouse motion and MCP.
  - `run_op` gives every operator an aligned stack, whoever calls it (keys,
    MCP, scripts).
- **Logic graphs** (#148). Event nodes that run in play mode
  (`src/logic.s`), edited in the node editor like the other graphs.
  - **Nodes:** events (Begin Play, On Tick, On Key, On Overlap, On Hit, On
    Timer, On Message), actions (Move, Rotate, Set Property, Spawn,
    Destroy, Play Action, Apply Impulse, Set Visibility, Send Message, Set
    Variable, Branch) and data (Variable, Math with 18 operations, Info:
    time, location, the player, distance, random..., Get Property). Run
    inputs chain actions after the event or action before them; names
    (messages, objects, properties, actions) are kept in the graph.
  - **Attached:** `logic.new`, `logic.node`, `logic.name`, `logic.attach`
    (a Logic modifier on the object); links and values with `tree.link` /
    `tree.node_set`. Graphs are node trees, so they are saved in the
    `.bee` file and undone like the rest.
  - **The VM:** every fixed play step (1/120 s) runs each object's graph
    in a fixed order, then delivers the messages sent. It is
    deterministic (random is a hash of the step, node and object) and
    sandboxed: 4096 nodes a step (the rest of the step is skipped), 256
    messages a step, 256 spawns, objects only by name.
  - **Play mode around it:** the player rides what it stands on (moving
    platforms), contacts report hits, the rigid body world runs live (no
    cached frames) and takes impulses, scripted `playstep` advances in
    1/60 s frames as the window does, and `playkey(code, down)` presses
    keys. An action layer that has played out now holds its last pose.
  - **Hidden objects:** `object.hide` (H) and `object.reveal` (Alt+H); hidden
    objects are not drawn, rendered, picked or collided with. Destroy and
    Set Visibility use the same flag.
  - The node editor shows an object's logic graph (before its geometry
    tree; Tab: the material): red events, green actions, blue data, white
    run sockets; Shift+A lists the logic nodes; pressing a name value
    puts `logic.name ...` in the console to finish.
  - [tests/logic.py](tests/logic.py): a door that opens, a pickup that is
    counted, a spawn on E, a pushed ball, a moving platform; saved and
    opened again, run twice to the same result, a message storm cut off at
    the budget; the node editor, F5 and MCP in a window.
- **Lighting tools** (#149): light probes, a lightmap baker, glTF for
  engines.
  - **Light probes** (`src/probe.s`): `probe.add irradiance|reflection
    [x y z] [half size] [grid points]`, `probe.bake [rays]`. Irradiance
    volumes keep a grid of L2 spherical harmonics (convolved with the
    cosine lobe), reflection probes a 6 x 32 x 32 cube map; both are baked
    by the path tracer (a new `trace_ray`: a path from any point along any
    direction) in parallel. The material preview takes its diffuse light
    from the smallest volume around a point (trilinear) and its
    reflections from a reflection probe's box (box-projected); where a
    volume lights it, the studio softboxes are left out. The probes are
    drawn as boxes in the viewport, kept in undo and saved (PRBE).
  - **Lightmaps** (`src/lightmap.s`): `lightmap.bake [size] [rays]` gives
    every visible mesh a second UV set (a smart projection of a copy,
    packed), places the objects in one atlas by their area, traces the
    irradiance at every covered texel (cosine-weighted, from just above
    the surface), denoises (a-trous, normal, distance and luminance
    weights) and dilates; `lightmap.save` writes OpenEXR or PNG. Saved in
    the `.bee` file (LMAP), not in undo.
  - **glTF for engines:** light objects as `KHR_lights_punctual`; a baked
    lightmap as an embedded PNG, the second UVs as `TEXCOORD_1` and a
    material per lightmapped object with `MOZ_lightmap` whose
    `KHR_texture_transform` is the object's atlas region;
    `KHR_materials_emissive_strength` as before.
  - BeeScript: `probe(k)`, `probeinfo(n, what)`, `probesample(...)` (the
    probes, or irradiance traced directly as the reference),
    `lightmap(k)`, `lmsample(object, x, y, z, c)`.
  - [tests/lighting.py](tests/lighting.py): probes and the lightmap
    checked against traced irradiance (shade, colour bleeding,
    reflections), undo, saving, PNG and EXR, the export through the
    Khronos glTF validator (no errors, no warnings), the preview lit by
    the probes.
- **Live link** (#150): the scene streamed over a socket (`src/link.s`).
  - `link.serve [port] | lan [port] | unix:<path>` serves a versioned
    binary stream: HELLO, a snapshot (materials, meshes, objects), then the
    changes - OBJECT, DELETE, TRANSFORM, PROPERTY (name, material, hidden,
    colour), MESH, MESH_DELTA (only the runs of vertices that moved),
    MATERIAL - each turn of the event loop after a TICK with the editor's
    clock. Changes are found by comparing the scene with what was sent.
  - `beemodel --link host:port` (or `link.connect`) mirrors a session;
    `docs/LIVELINK.md` documents the protocol for engine plugins and
    `tools/livelink.py` is a reference reader.
  - Under a millisecond on localhost; a reader that falls behind gets its
    transforms coalesced (one, the latest, per object once it catches up).
  - [tests/livelink.py](tests/livelink.py): snapshot, latency, deltas,
    topology changes, a mirror, backpressure, a late reader, a UNIX socket.
- **Versioned scenes** (#151): commit, branch, diff and merge `.bee` files
  (`src/vc.s`).
  - **History:** beside the saved file, `<file>.vc/` keeps content-addressed
    blobs (whole scenes, each object's mesh, manifests: an entry per object
    and a hash per mergeable chunk), commits (text: scene, manifest,
    parents, time, message; named by their hash) and the branches.
    `vc.commit [message]`, `vc.branch`, `vc.switch` (refused with changes
    unless `force`), `vc.log`.
  - **Visual diff:** `vc.diff [branch | commit] [overlay | side]` lists
    objects added, removed and changed (which properties; meshes with their
    vertex counts) in a panel and on the console, and draws the other
    version as ghosts - over the scene or beside it.
  - **Three-way merge:** `vc.merge <branch>` from the common ancestor, per
    object and property (transform, name, material, hidden, colour, mesh)
    and per chunk (materials, node trees, animation, light probes): one
    side's change is taken, different changes to the same thing are
    conflicts for the merge panel (ours / theirs buttons, `vc.resolve`);
    `vc.commit` makes the merge commit (two parents), `vc.abort` gives up.
  - Every operation is an MCP tool: an agent can branch, work and propose
    its branch for the user to diff and merge. BeeScript: `vcinfo(k)`,
    `vctext(what, row)`.
  - [tests/versions.py](tests/versions.py): commits, branches, the diff,
    merges with and without conflicts, the store, the panel's buttons,
    ghosts over and beside the scene, an agent's branch over MCP.
- **Live co-editing** (#152): two users and an AI agent on one scene
  (`src/cosync.s`, `src/cotree.s`).
  - `co.host [port]` starts a session, `co.join host:port` joins any of its
    peers (`co.host` on a peer in a session lets others join there too);
    operations are relayed peer to peer, each kept once - no server.
  - **The CRDT:** objects are elements with unique ids (alive by their
    latest add / delete, in an RGA sequence for the object list); name,
    material, transform, hidden and colour are last-writer-wins registers
    (Lamport clock, the peer below); a mesh is a topology generation plus a
    position register per vertex (moves of different vertices merge);
    materials are registers by name; node trees are a set by name with
    their nodes in an RGA sequence (content and links by node id one
    register each).
  - Edits of any kind become operations by comparing the scene with the
    document every turn of the event loop; remote operations update the
    document, then the scene.
  - **Undo per author:** Ctrl+Z in a session undoes your own last edit (as
    new operations: others' later edits stay); redo likewise.
  - **The agent:** `co.agent on` makes what MCP tools change a peer of its
    own, with its own undo and presence (the objects it last touched).
  - **Presence:** every peer's camera, 3D cursor and selection are drawn in
    its colour; `co.follow <peer>` keeps your view on theirs.
  - The co-editing messages are in docs/LIVELINK.md. BeeScript:
    `costat(k)`, `cohash()` (the document's hash), plus `viewinfo(k)` and
    `objtype(object)`.
  - [tests/coedit.py](tests/coedit.py): three peers in a chain (one the
    agent): joining, concurrent edits of one property, vertex merges, node
    graphs edited at once, per-author undo and redo, presence and follow,
    and a fuzz of hundreds of random concurrent edits converging to
    identical documents (by hash) and scenes.
- **The B-rep kernel** (#153): `cad.kernel on` makes CAD features build
  exact solids instead of meshes (docs/BREP.md). The switch is saved with
  the scene.
  - **Geometry:**
    - Curves are lines, circles, ellipses or NURBS; surfaces are planes,
      cylinders, cones, spheres, tori or rational NURBS, all in the STEP
      parametrisations.
    - NURBS evaluation with derivatives, knot insertion, and degree
      elevation of curves and surfaces.
  - **Topology:**
    - Bodies, faces trimmed by loops, coedges with pcurves, edges and
      vertices.
    - Volume and area are integrated exactly over the trimmed faces (Green's
      theorem in (u, v)).
  - **Solids from sketches:** pads, pockets, holes, shells and revolves are
    built from the sketches' exact lines and arcs, with patches of at most
    half a turn and poles on the axis.
  - **Booleans:**
    - The surface-surface intersection is in closed form for the
      plane / quadric cases and traced (marching squares, Newton onto both
      surfaces) otherwise.
    - Each face is divided in (u, v) and its regions classified;
      coplanar, tangent and along-edge contacts are handled.
  - **Fillets and chamfers:** straight edges between two planes.
  - **Tessellation:** adaptive, watertight and Delaunay in the surfaces'
    metric; it is what the viewport shows.
  - A body the kernel cannot build (e.g. infill, or fillets meeting at a
    corner) keeps the mesh replay's result.
  - **BeeScript:** `brep(name, what)` and `nurbscheck(k)`.
  - [tests/brep.py](tests/brep.py) checks:
    - the NURBS self-checks;
    - closed-form volumes and areas of pads and revolves, to about 1e-15;
    - booleans: a hole drilled across a rod against an independent
      integral (3e-8);
    - fillets and chamfers;
    - the enclosure walkthrough on the kernel, before and after a parameter
      change: valid and watertight;
    - the switch in saved files.
- **STEP import and export** (#154), our own Part 21 reader and writer
  (docs/BREP.md):
  - `file.export_step` writes B-rep solids as AP214:
    - geometry: planes, cylinders, cones, spheres, tori, B-spline surfaces
      and curves, rational or not;
    - one part in place, or several as an assembly with their placements;
    - each solid's name and colour, and the scene's units (millimetres,
      centimetres, metres, inches).
  - `file.import_step` reads parts and assemblies:
    - analytic or NURBS faces, seams and poles;
    - placements through every level, names, colours, and the file's
      units converted to the scene's.
    - Imported solids are kernel bodies, so `brep()` and the export see
      them.
  - BeeScript's `get` and `set` take `"color"`.
  - [tests/step.py](tests/step.py) checks:
    - our own round trip: volumes and areas to 1e-9 (about 1e-15 seen), placements, colours
      and units;
    - FreeCAD (or OpenCASCADE) reading our part and assembly (volumes to
      1e-6, each solid in place);
    - its re-export, and its every-face-NURBS version, read back to 1e-6.
  - CI installs FreeCAD from its PPA for the round trips.
- **The GPU helper** (#155): `beemodel-gpu`, an optional second program and
  release asset, links the Vulkan loader. BeeModel still links nothing and
  talks to it over a socket and shared memory (docs/GPU.md).
  - **Path tracing:** Hive's samples run on the GPU. The shader is a
    line-for-line port with the same random streams, so the images agree
    with the CPU's: the default scene is pixel-identical, and a scene of
    glass, metal, clearcoat and lights differs by 0.01 levels on average.
    128 samples at 1080p take 0.9 s on an RTX 4080 SUPER, against 9.8 s on
    32 CPU threads.
  - **Rasterization:** for frames drawn through cluster DAGs, the viewport
    rasterizer's tile stage runs on the GPU, pixel-identical to the CPU.
  - **Fallback:** without the helper, without a usable device, for scenes
    the GPU kernels do not cover (an HDRI world, shader graphs), or if the
    helper fails mid-render, the CPU paths go on from where they were.
  - **Choice of device:** a discrete GPU first, then an integrated or virtual
    one; llvmpipe only with `BEEMODEL_GPU=any`. `BEEMODEL_GPU=off` turns it
    off, and BeeScript's `gpu(k)` reports on it.
  - [tests/gpu.py](tests/gpu.py) checks the fallbacks, the path tracer
    against the CPU (also denoised), the helper dying mid-render, and the
    rasterized frame; CI runs it on llvmpipe.
- **Job system:** `parallel_for` is shared by the UI thread and one
  background thread (`job_spawn`), which take turns.

### Fixed
- `modapply` in a script gave its scratch memory back only at the end of the
  script: a script applying many large geometry node modifiers ran out of
  frame memory (a flat result, then a crash).
- Leaving sculpt mode now marks the mesh as changed, so caches keyed by its
  version see the strokes.

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

[Unreleased]: https://github.com/bartbeecoders/beemodel/compare/v1.2.1...HEAD
[1.2.1]: https://github.com/bartbeecoders/beemodel/compare/v1.2.0...v1.2.1
[1.2.0]: https://github.com/bartbeecoders/beemodel/compare/v1.1.0...v1.2.0
[1.1.0]: https://github.com/bartbeecoders/beemodel/compare/v1.0.0...v1.1.0
[1.0.0]: https://github.com/bartbeecoders/beemodel/compare/v0.24.0...v1.0.0
[0.24.0]: https://github.com/bartbeecoders/beemodel/compare/v0.23.0...v0.24.0
[0.23.0]: https://github.com/bartbeecoders/beemodel/compare/v0.22.1...v0.23.0
[0.22.1]: https://github.com/bartbeecoders/beemodel/compare/v0.22.0...v0.22.1
[0.22.0]: https://github.com/bartbeecoders/beemodel/compare/v0.21.0...v0.22.0
[0.21.0]: https://github.com/bartbeecoders/beemodel/compare/v0.20.0...v0.21.0
[0.20.0]: https://github.com/bartbeecoders/beemodel/compare/v0.19.0...v0.20.0
[0.19.0]: https://github.com/bartbeecoders/beemodel/compare/v0.18.0...v0.19.0
[0.18.0]: https://github.com/bartbeecoders/beemodel/compare/v0.17.0...v0.18.0
[0.17.0]: https://github.com/bartbeecoders/beemodel/compare/v0.16.0...v0.17.0
[0.16.0]: https://github.com/bartbeecoders/beemodel/compare/v0.15.0...v0.16.0
[0.15.0]: https://github.com/bartbeecoders/beemodel/compare/v0.14.0...v0.15.0
[0.14.0]: https://github.com/bartbeecoders/beemodel/compare/v0.13.0...v0.14.0
[0.13.0]: https://github.com/bartbeecoders/beemodel/compare/v0.12.0...v0.13.0
[0.12.0]: https://github.com/bartbeecoders/beemodel/compare/v0.11.0...v0.12.0
[0.11.0]: https://github.com/bartbeecoders/beemodel/compare/v0.10.0...v0.11.0
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
