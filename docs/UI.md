# Using BeeModel

Everything BeeModel can do has a place in the window. The console, scripts and agents can still do it all too, but you never need them. This page is a tour of the window and the rules every part of it follows.

## The window

```
+--------------------------------------------------------------------------+
| File Edit View Select Add Object Mesh Render AI Help | Modeling Sculpt ...|  menu bar, workspace tabs
+----------+------------------------------------------------+--------------+
| Tools    | 3D Viewport   [mode] [select] [shading] [grid] | Outliner     |
|          |                                        (gizmo) |              |
|          |                                                +--------------+
|          |                                                | Properties   |
|          |                                                |  tabs        |
+----------+------------------------------------------------+              |
| Console / Timeline / ...                                  |              |
+--------------------------------------------------------------------------+
| what the mouse and keys do now                  objects  AI  render  peers|  status bar
+--------------------------------------------------------------------------+
```

The window is split into **areas**. Each area has a header with its editor type (click it to pick another), and buttons to split it, maximize it and close it. Drag the border between two areas to resize them.

- **Swap** two areas: drag one's header onto the other.
- **Join** two areas: drag an area's top-left corner into its neighbour.
- **Workspaces** are saved layouts: Modeling, Sculpt, CAD, Shading, Animation and World, plus your own (**+** after the tabs). Switch with a click on a tab or with Ctrl+PageUp / PageDown. They are saved in `.bee` files and remembered for the next session.

Editor types: 3D Viewport, Tools, Outliner, Properties, Console, Timeline, Dope Sheet, Graph Editor, Node Editor, UV Editor, Render, Asset Browser, AI Activity, AI Assistant, Versions, Preferences and Help.

## Mouse and keyboard rules

These work the same everywhere.

| Do this | To |
|---|---|
| Rest the pointer on anything | See a tooltip: its name, shortcut, what it does and, if it is greyed, why it cannot run now |
| Click a greyed item | Get the reason in the status bar |
| Drag a number field | Scrub it (Shift: finer, Ctrl: snapped steps) |
| Click a number field | Type a value or an expression: `25mm`, `2*pi`, `width/2`; angles are in degrees |
| Ctrl+wheel over a field | Step it |
| Ctrl+C / Ctrl+V over a field | Copy its value / paste into it |
| Ctrl+Left / Right while typing | Jump a word (Shift: select it); Ctrl+Backspace / Delete remove one |
| I over a field | Insert a keyframe for that value |
| Right-click | A context menu: in the viewport, on outliner rows, on area headers, on asset tiles, in the node editor, the timeline (playback, Start / End at This Frame) and the dope sheet / graph editor (interpolation, handles, duplicate, delete), on a field (Reset to Default, Copy / Paste Value, Insert Keyframe, Copy Data Path) and on a file in the file browser (Open, Rename, Delete, New Folder, Copy Path) |
| Alt+right-click in the viewport | Ask the AI about the selection: a prompt at the pointer (also **Ask AI...** in the right-click menu, see [AI.md](AI.md#ask-about-the-selection)); Shift+right-click places the 3D cursor |
| Hold Z / Ctrl+Tab / Shift+S in the viewport | A pie menu for the shading / the mode / the 3D cursor and snapping (a quick tap keeps the key's own action; Shift+S stays the stabilizer in sculpt mode) |
| F3 | Search every command |
| F1 | Every shortcut, searchable |
| F10, or Alt+letter | Open the menus from the keyboard |
| Enter / Esc | OK / Cancel in a dialog; Esc also closes menus, pickers and overlays one level at a time |
| Ctrl+Z / Ctrl+Shift+Z | Undo / redo. A drag, a typed value or a toggle is one step |

### Keyboard only

- **F6** / Shift+F6 makes the next / previous area the active one and draws a ring round it.
- **Tab** / Shift+Tab moves a focus ring through the widgets of the open dialog, picker or overlay, or else of the active area. Over a 3D viewport Tab keeps its usual meaning, edit mode.
- **Enter** or **Space** works the focused widget, the **arrow keys** step a number or an option, and **Esc** lets go of the focus.
- In menus: Up / Down, Right / Left for submenus and the next menu, Enter.

**Parenting.** **Ctrl+P** (Object > Parent) makes the selected objects children of the active one; **Alt+P** frees them. A child stays where it is, then follows its parent: when the parent moves, turns or scales - by hand, by a field, a script, an animation or physics - so does the child, and its children in turn. Parents are kept in `.bee` files; scripts use `op("object.parent_set", "child parent")` and `parent(name)`.

Views **glide** to where they go when you align to an axis (the gizmo, Numpad 1 / 3 / 7), reset the camera (Home) or frame the selection (Numpad .: the selection, or everything, in the middle of the view). **Preferences > Interface > Reduce motion** makes them jump there at once; scripts and agents always jump.

## Menus and dialogs

The menu bar holds every command, in File, Edit, View, Select, Add, Object, Mesh, Render, AI and Help. A command that needs values opens a **dialog** with a form. The values you typed are kept for next time. Commands that read or write files open the **file browser**:

- folders come first, then the files in columns: name, size and when they were changed. A click on a column's header sorts by it, and a second click turns the order round;
- a click picks, and a double-click (or Enter) opens or takes;
- Backspace goes up, **<** and **>** (Alt+Left, Alt+Right) go back and forward, and each part of the folder above the list is a button that goes there;
- the path field takes a typed folder or file, and Tab completes a name in it (when several match, a second Tab shows them in the list);
- the filter box keeps only the names with what you type in them; **Hidden files** (Ctrl+H) shows names that start with a dot, and **All files** shows every file, not only the kinds the command can take;
- the column at the left has the places (home, `~/BeeModel`, the whole computer), your **favourites** (**+ Favorite** adds the folder shown, **- Favorite** takes it out), the **drives** mounted under `/run/media`, `/media` and `/mnt` with their free space, and the last folders used. Favourites and recent folders are kept in `~/.config/beemodel/places`;
- a scene shows a picture of it beside the list (BeeModel keeps a small picture of the 3D viewport in each `.bee` file it saves from the window), and an image (PNG, JPEG, HDR) shows itself;
- saving over a file asks first.

Exports add their own options: selected objects only, the up axis and the scale. **Export Drawing (PDF)** adds the sheet (A4, A3, A2, Letter; landscape or portrait), the views (front, top, right and an isometric one), the scale (the largest that fits, or a fixed one) and the title block's title and author; the date is today's. Scripts set the same with `drawing.options`.

Files dragged from a file manager onto the window open by their kind:

- `.blend`, `.glb` / `.gltf`, `.obj`, `.stl` and `.step` are imported, each
  as one undo step;
- a `.bee` file opens when the scene has no unsaved changes;
- a `.png`, `.jpg` or `.jpeg` becomes a reference image.

**File › Open Recent** lists the last eight scenes. New, Open and Exit ask "Save changes?" when the scene has changes.

## The 3D viewport

**Reference images** are photos or drawings to model over. **Add › Reference Image...** (or an image dropped on the window, or `refimage(path [, name])`) puts one at the 3D cursor, square to the view's nearest axis (front, side or top) and upright, at the image's aspect ratio. It shows in every shading mode, solid included, and is left out of renders (its camera is off). **Properties › Object** shows its settings:

- **Opacity**;
- **Drawn**: behind the scene (objects cover it) or in front of it (to trace over);
- **Seen from**: both sides, or the front only;
- **Only in orthographic views**;
- **Only when seen square-on**, as a front, side or top reference.

Click its outline to select it; it moves, turns and scales like any object. Its image travels in its material ("Reference <image>"), so it is saved with the scene.

The header has:

- the **mode** (Object, Edit, Sculpt, Texture / Vertex / Weight Paint);
- the **View**, **Select** and **Object** menus (Mesh in edit mode), the same as in the menu bar;
- vertex / edge / face select in edit mode;
- **shading** (Wireframe, Solid, Material Preview, Rendered);
- the ground grid and snapping;
- the **pivot point and orientation** button. The pivot is what turning (R) and scaling (S) go around: the median point, the 3D cursor, each object's own origin (Individual Origins) or the active object. The orientation is what X, Y and Z mean while moving (G) or turning (R): Global, Local (the active object's axes), View (screen right, up, towards you) or Normal (edit mode: the selected faces' normal). In edit mode, turning and scaling keep to the world's axes. Scripts use `view.pivot` and `view.orientation`;
- **Overlays**: the ground grid, the text in the corner, the scene's statistics, the navigation gizmo, and the mesh checks (normals, boundary and non-manifold edges, degenerate faces).

**Force fields** (**Add › Force Field ›** Attractor, Gravity Zone, Wind, Vortex, Turbulence, Drag, and the presets Planet, Black Hole, Tornado, Breeze) each draw a gizmo of their kind and, with a falloff, three circles of their reach. **View › Force Field Arrows** draws their pull as arrows on a grid round them; **View › Force Field Lines** draws streamlines from the selected objects. [FIELDS.md](FIELDS.md).

The **navigation gizmo** in the top-right corner turns the view: click a ball to look along that axis, or drag a ball to orbit. Numpad 1, 3 and 7 do the same, with Ctrl for the opposite side. Under it, drag the magnifier up or down to zoom and the cross to pan; the grid button (or Numpad 5) switches the viewport between perspective and **orthographic**, where things do not shrink with distance. (Orthographic is a very long lens from far away: parallel lines stay parallel to within a fraction of a pixel.) An empty scene offers quick actions in the middle of the viewport: Add a Cube, Start a Sketch, Open, Import and the templates.

The **Tools** area follows the mode. In object mode it holds the transform tools and Add. In edit mode it has the mesh tools, in sculpt mode the brushes, and in sketch mode the sketch tools and constraints. Each row shows its shortcut and is lit while its tool is on. In sculpt and paint modes, a brush bar at the bottom of the viewport has the radius, strength, colour, swatches, symmetry and pressure. Sculpt symmetry mirrors strokes across the object's X, Y and Z planes, in any combination (a button for each, or `sculpt.symmetry xyz`). In sculpt mode a second row has the brush's **falloff** (Smooth, Sphere, Root, Sharp, Linear, Constant: how it fades towards its edge; `sculpt.falloff`) and, with dynamic topology on, the **detail** size in pixels.

## Properties

The tabs down the left side of Properties are:

| Tab | What it holds |
|---|---|
| **Object** | Name, location, rotation, scale, visibility, colour, the parent (the object it follows). Also a light's power, colour, type (point, sun, spot, area) and size - a point or spot light's radius softens its shadows, a sun's angle, an area light's edge - and a spot's cone; a camera's lens and "Render from This Camera"; and a curve's shape. After **Object > Print Check**, its findings: closed or not, the thinnest wall, overhangs and the size, each with a **Show** button that selects those edges or faces in edit mode and frames them |
| **Modifiers** | The stack (on / off, order, Apply, remove) with every value, including object and node-tree pickers |
| **Material** | Material picker and New, base colour, metallic, roughness, transmission, emission and more. Images, and the paint layer stack while texture painting |
| **Physics** | A status line (*Active Convex Hull, 4.2 kg, 2 joints*; *Piece of Wall*; *Not a rigid body*), then sections that fold. **Rigid Body**: the type and shape picked first, then Add Rigid Body; on a body its type, shape, *Bodies* (the object or each of its instances), *Material* (Default, Rubber, Ice, Wood, Metal, Stone: friction and bounce), mass, friction, bounce, damping, start velocity, collision group, Remove. A change goes to every selected body. **Joints**: the object's joints as a list; the one picked has its type, the body it is tied to (or the world), pivot, axis, limits, motor and breaking force; Add Joint..., Remove. A body can be marked **Attracts the others** (it pulls every other body by its mass). For a force field, its **Force Field** section instead: Type, On, Strength, Falloff and Radius, the type's own values (an attractor's pull law and soft core, a zone's shape and half size, wind's gusts, a vortex's lift and inflow, turbulence's swirl size and seed) and the group it acts on. **Shatter**, **World** (Gravity on or off, gravity as X Y Z, steps a second, iterations, substeps, G for bodies that attract), **Cloth and Soft Body** (open on cloth), **Cloth World** and **Simulation Cache** (what is cached or baked for rigid bodies and cloth) start closed |
| **Particles** | The active object's particle systems: Add System... (Rain, Snow, Sparks, Confetti, Fountain, Water Tank, or an empty one), the system picked by number with its name, Remove; then **Emission** (from faces, volume, vertices, a point, events or a fill; at a rate or all at once; how many; from and until which frame), **Motion** (lifetime, speed, spread, gravity, drag, how random), **Look** (points, sprites or objects; size and its end; the colour and the one it changes to; in renders), **Collisions**, **Liquid** (viscosity, vorticity, tension, substeps, iterations, the surface) and **Cache** (frames and memory, Bake, Free; [PARTICLES.md](PARTICLES.md)) |
| **Landscape** | Only for a landscape: what it is, then Size and Samples, the layer stack (eyes, pick, add, up, down, remove, the picked layer's values), paint layers (colour, friction, bounce, rules, Auto Paint), Sea and Files |
| **CAD** | Parameters (expressions), the feature tree with sizes you can edit, a health dot, and up / down buttons that reorder it (the part rebuilds; `cad.feature_move`), units, the B-rep kernel, mechanism joints, measuring |
| **Scene** | Units, the world's sky (studio or an HDRI), its strength, the frame range |
| **Render** | Size, samples, denoise, bounces, motion blur (the shutter), sample reuse (frames, for animation renders), the Device (Auto, GPU (RTX), GPU, CPU) and where the last render ran and why, Render and Save; virtualized geometry, world partition, light probes, lightmaps, play mode |
| **Viewport** | Shading, grid, theme, camera |
| **Animation** | Shape keys, actions and layers, drivers, onion skins, motion paths |
| **Rig** | The armature's bones and pose, constraints, Parent to Armature |

**Colour fields** are swatches: a click opens the picker. It has a saturation / value square, a hue strip, the old and new colour, a hex code, and **Pick**, which takes the next colour you click anywhere on screen. Below them:
- R G B (0–255) and H S V (degrees, percent) as numbers to drag or type;
- the ten colours used last (kept in the preferences), and the scene's own colours (its materials' base colours): a click takes one.

Right-click a colour field to copy it as `#rrggbb`, paste a hex code, or reset it to its default. Every colour in the UI works this way: materials, lights, the object colour, the paint colour (and its form), and the accent colour in Preferences › Interface.

## Other editors

- **Outliner.** Each row has a type icon, the name (gold when active), a lock (locked: clicks in the viewport pass through it), a camera (off: renders leave it out) and an eye (hidden). All three are saved in `.bee` files. Click a row to select it, Ctrl+click to add or remove it, Shift+click to select the rows from the active one to it. Children are listed under their parent, indented; the arrow folds them away. Drag a row onto another to make it that object's child, or onto the empty part of the outliner to free it. While you drag, a label at the pointer shows what is dragged and what letting go there does (Child of …, Into …, No parent, no folder), and the row or folder that would take it is lit. Double-click a row or press F2 to rename. The filter field at the bottom finds objects by name.
- **Folders** group objects without moving them. **Ctrl+G** (or the **+** beside the filter) puts the selected objects in a new folder, inside the folder picked; **Object › Move to Folder...** moves them into one by name (`none`: out). A folder row has a fold arrow and its own eye, camera and lock, which apply to everything in it. Click a folder to pick it and select what is in it; click it twice to rename it. Drag objects onto a folder to move them in, or onto the empty part of the outliner to take them out. Folders are saved in `.bee` files (a FOLD chunk) and undone like any change. `outliner.folder_delete [contents]` removes the folder picked (its objects move up a level, or go too).
- **Timeline.** Play, step and the frame range, plus auto-key, which keys every confirmed move.
- **Dope Sheet / Graph Editor.** Interpolation, handles, duplicate and delete for the selected keys.
- **Node Editor.** The header chooses the graph (a material or a node tree). The Add menu filters as you type.
  - **View.** The wheel zooms about the pointer (25–200 %); Ctrl+wheel scrolls, Shift+wheel scrolls sideways, the middle button pans. Home frames every node, F the selection. The minimap in the corner shows the whole graph; click or drag in it to go there.
  - **Select and move.** Drag in empty space for a box (Shift adds, Ctrl takes away); dragging any selected node moves them all. The right button opens the node menu.
  - **Edit.** Shift+D (or Ctrl+D) duplicates, Ctrl+C / Ctrl+V / Ctrl+X copy, paste and cut. Pasting into another material keeps the links between the pasted nodes. H collapses nodes to their headers, C puts a comment frame round the selection. Dragging a frame's title moves the nodes inside it, its corner resizes it, a click on a selected frame's title renames it, X removes it. Align Left / Top and Distribute are in the node menu.
  - **Adding nodes.** Shift+A (or Add) lists a material's nodes in a column per category (Input, Texture, Math, Vector, Colour, Utility), with shortcuts such as Add, Multiply, Lerp or Dot Product that set the operation for you; type to search. The **Palette** toggle in the header shows the same list beside the canvas with its own search field: click an entry to add it in the middle of the view, or drag it onto the canvas. As in Unreal, a key and then a click on the canvas adds a node there: 1 Constant, 3 Color, T Texture Sample, U Texture Coordinate, A Add, M Multiply, D Divide, E Power, L Lerp, O One Minus, N Normalize, P Panner, B Bump.
  - **Material functions.** Select nodes and press **Ctrl+G**: they become a material function and one Material Function node takes their place. **Tab** on a Material Function node edits the function (the header says "Function:"), Tab again goes back. The node's Function value picks which function it runs; Function Input and Function Output nodes are in the Functions column of the add menu.
  - **Presets and texture sets.** Under the material slot, **Preset...** restyles the material (or makes one) as gold, glass, car paint, wood, marble and 15 more; **Texture Set...** asks for any one image of a PBR texture set and builds the material from all its maps, found by their names.
  - **Bake to Maps** (under the texture) bakes the material's graph through the object's UVs into four 1024 x 1024 maps and makes the material sample them: what a game engine or another program can read.
  - **Parameters and instances.** Scalar, Vector and Texture Parameter nodes (the Parameters column of the add menu) carry a name, shown as their title and edited in the Material tab's node section. **New Instance** in the Material tab makes a material instance: it shares the material's graph and shows only its parameters, each with an override box; typing a value overrides it, clearing the box takes the parent's value again. Edits to the parent reach every instance at once.
  - **Previews.** A material shows in a pane in the corner, lit like the viewport's material preview. Drag it to turn it; click it for the next shape (sphere, cube, plane). Every node shows its output over a square below it. Both follow each edit at once. The line at the bottom counts the nodes, those that reach the output and the texture samples; nodes that lead nowhere and a texture sample with no image are flagged in amber. Preview and Thumbnails in the header turn them off (`node.preview 0|1 [sphere|cube|plane]`, `node.thumbnails 0|1`).
  - **Values.** Drag a value sideways, or click it twice to type it in the console. The selected node's values and its unlinked inputs also appear as fields at the top of the Material tab (Properties), where you can type numbers or expressions. The Material Output dims the pins the blend mode doesn't use.
  - **Wires.** Drop a wire in empty space to pick the node it should feed. Double-click a wire for a reroute knot. Alt+click a wire to cut it, or Alt+drag a knife across several. Wires take the colour of what they carry.
- **UV Editor.** Unwrap, Pack, Select All, the stretch heat map. More is in Mesh › UV.
- **Render.** Render, Stop, Save, Denoise, the pass shown, the samples done, and GPU or CPU.
- **Asset Browser.** Search, a kind filter, Save to Library. Right-click a tile to place it, tag it, show its dependencies or remove it.
- **Versions.** Commit, branches, merge with conflict choices, history. It also handles collaboration (host, join, follow a peer, let an agent join) and the live link.
- **AI Activity.** What agents did, their permission, and Accept / Revert for a waiting proposal.
- **Help.** Everything about whatever the pointer last rested on.

## The status bar

The left side shows what the mouse and keys do right now, as key chips. On the right are the scene's size, the AI permission (click it for the AI menu), the progress of a render, who is co-editing and the live link (serving or mirroring; click it for the Versions editor).

Long jobs (baking maps, light probes, a lightmap or a simulation, and imports) get a chip with their name and a bar filling as they go. The window keeps drawing while they run but does not take input until they finish.

Messages show as **toasts** above the status bar for four seconds:

- **green** for results;
- **amber** for problems.

Click a toast to open the console.

## AI Assistant

**Ctrl+Shift+Space** (or **AI › AI Assistant**) goes to the AI Assistant's prompt. The first time, it makes the **AI** workspace: a viewport, the AI Assistant and the outliner. The area holds:

- the connection (Claude Code, Grok or OpenRouter);
- **New**, which starts a new conversation;
- **Revert**, which undoes the AI's last request: one step;
- the transcript. Drag over it to select text, or double-click a message to select all of it; **Ctrl+C** (or **Copy**) copies the selection, and with nothing selected **Copy** copies the whole conversation;
- the prompt. **Enter** or **Send** sends it, and **Stop** ends a request that is running.

Connections are set up and tested in Preferences › AI. The guide is [AI.md](AI.md).

## Preferences

**Edit › Preferences** (**Ctrl+Comma**) opens the Preferences dialog: a search field and the categories on the left, the category's settings on the right. The search looks through every category at once (a setting's name, label and tooltip; Enter); picking a category ends it. **Reset to Defaults** puts the category back as BeeModel comes. **Close** or Esc closes it. Everything is saved to `~/.config/beemodel/prefs` as soon as it changes. A Preferences area (an area's type menu) shows the same thing.

| Category | Settings |
|---|---|
| **Interface** | Accent colour (any theme; **Theme's Accent** goes back), theme (Dark, Light, High contrast, Honey, Graphite, Nord, Solarized Dark, Solarized Light, Dracula; the list shows a strip of each one's colours), UI scale 75–200 %, tooltip delay, colour-blind-safe axis colours, the welcome screen |
| **Viewport** | The ground grid and its spacing, the field of view, the clip start, Rendered shading's samples and denoise |
| **Input** | Alt + left button as the middle button, orbit speed |
| **Keymap** | The preset (BeeModel or Blender 4.x, below), then Search, Set (then press the key), Clear, Reset All Keys. It warns you when a key is already taken |
| **Rendering** | New scenes' render width, height, samples and denoise (each scene keeps its own) |
| **System** | Worker threads, the GPU, the JIT |
| **Files** | Autosave interval, library folders |
| **AI** | The agents' permission at start-up, the MCP server |

### The Blender 4.x keymap

BeeModel's own keymap is the default, and it is already close to Blender's: G R S, Tab,
Shift+A, Shift+D, H / Alt+H, X / Delete, E, I, K, Ctrl+R, Ctrl+B, the numpad views, F3,
F9, F12, Space to play, I to key, the Ctrl+Tab mode pie and the Z shading pie all match.
The **Blender 4.x** preset (Preferences › Keymap, the welcome screen, or
`prefs.keymap blender`) changes only the keys that differ:

| Operator | BeeModel | Blender 4.x preset | Why |
|---|---|---|---|
| Wireframe | Z (tap) | Shift+Z | Blender's Z only opens the shading pie |
| Material Preview | Shift+Z | none | Shift+Z is Blender's wireframe toggle |
| Reset Camera | F | none (Home stays) | F does nothing in Blender's object mode |
| Ground Grid | Shift+G | none | Shift+G is Select Grouped |
| Texture Paint | Shift+Tab | none | Shift+Tab is snapping; the modes are on the Ctrl+Tab pie |
| Vertex Paint | Shift+V | none | Shift+V is Vertex Slide |
| Weight Paint | Ctrl+W | none | on the Ctrl+Tab pie |
| Select tool | Shift+Q | W | W is Blender's select tool |
| Move / Rotate / Scale tools | Shift+W / Shift+E / Shift+R | none | Shift+E is Edge Crease, Shift+R Repeat Last |
| Node editor: Frame Selected | F | Numpad . | as in the 3D viewport |
| Node editor: Comment Frame | C | Ctrl+J | Blender's Join in New Frame |

The preset writes these as key overrides, so they show in the Keymap list. Keys you set
yourself on other operators stay as they are. Choosing **BeeModel** again (or Reset All
Keys) takes the preset's keys back. Some Blender keys have no BeeModel operator yet
(Ctrl+A Apply, Ctrl+J Join, M Move to Collection); the F3 search finds those commands.

## Accessibility

- Every text and background pair in every theme has a contrast of at least 4.5:1. The High contrast theme goes further.
- A theme picked anywhere (Preferences, View › Theme, the Viewport panel, `view.theme <name>`) is kept in the preferences.
- The UI scale enlarges everything, independent of the compositor's scale.
- Colour-blind-safe axes swap the red / green / blue axis colours for orange, sky blue and purple (Okabe-Ito).
- The whole window works from the keyboard (see above).
- BeeModel has no animations to reduce: views snap and menus open at once.

## Getting started

The **welcome screen** at start-up offers:

- a default or empty scene;
- templates: a parametric CAD product, a rigged character, a terrain;
- samples;
- your recent files;
- the keymap choice: BeeModel or Blender 4.x, each also for a laptop (Alt + left button as the middle button).

**Help › Welcome Screen** brings it back. To skip it at start-up, turn off "Show this at start" or set `BEEMODEL_WELCOME=0`.

## For agents and tests

The MCP tool `ui_tree` lists every widget on screen: its name, kind, position, label, value, focus and tooltip. Agents use it to see the UI. The fakewl tests use it to click widgets by name instead of by coordinates.

The `walkthrough_ui` scenario models a part, adds a CAD feature, a material and a render, then saves and reopens the scene. It does all of this with clicks and keys only. `ui_bench` measures frame times while the busiest panels redraw. They take about 3 ms here, against a 16 ms budget. The `walkthrough16_ui` scenario does the same for the v0.16.0 pieces. It parents a sphere to the cube with Ctrl+click in the outliner and Ctrl+P, moves the cube, and locks it from the outliner. It makes the light a spot from its type list, then uses the snap pie and Numpad .; finally it saves the scene and picks it in Open, where its picture shows.
