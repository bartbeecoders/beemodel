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

Editor types: 3D Viewport, Tools, Outliner, Properties, Console, Timeline, Dope Sheet, Graph Editor, Node Editor, UV Editor, Render, Asset Browser, AI Activity, Versions, Preferences and Help.

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
| I over a field | Insert a keyframe for that value |
| Right-click | A context menu: in the viewport, on outliner rows, on area headers, on asset tiles |
| Hold Z in the viewport | A pie menu for the shading |
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

## Menus and dialogs

The menu bar holds every command, in File, Edit, View, Select, Add, Object, Mesh, Render, AI and Help. A command that needs values opens a **dialog** with a form. The values you typed are kept for next time. Commands that read or write files open the **file browser**:

- folders come first;
- a click picks, and a double-click (or Enter) opens or takes;
- Backspace goes up;
- the path field takes a typed folder or file;
- saving over a file asks first.

Exports add their own options: selected objects only, the up axis and the scale.

**File › Open Recent** lists the last eight scenes. New, Open and Exit ask "Save changes?" when the scene has changes.

## The 3D viewport

The header has:

- the **mode** (Object, Edit, Sculpt, Texture / Vertex / Weight Paint);
- vertex / edge / face select in edit mode;
- **shading** (Wireframe, Solid, Material Preview);
- the ground grid and snapping.

The **navigation gizmo** in the top-right corner turns the view: click a ball to look along that axis. Numpad 1, 3 and 7 do the same, with Ctrl for the opposite side. An empty scene offers quick actions in the middle of the viewport: Add a Cube, Start a Sketch, Open, Import and the templates.

The **Tools** area follows the mode. In object mode it holds the transform tools and Add. In edit mode it has the mesh tools, in sculpt mode the brushes, and in sketch mode the sketch tools and constraints. Each row shows its shortcut and is lit while its tool is on. In sculpt and paint modes, a brush bar at the bottom of the viewport has the radius, strength, colour, swatches, symmetry and pressure.

## Properties

The tabs down the left side of Properties are:

| Tab | What it holds |
|---|---|
| **Object** | Name, location, rotation, scale, visibility, colour. Also a light's power and colour, a camera's lens and "Render from This Camera", and a curve's shape |
| **Modifiers** | The stack (on / off, order, Apply, remove) with every value, including object and node-tree pickers |
| **Material** | Material picker and New, base colour, metallic, roughness, transmission, emission and more. Images, and the paint layer stack while texture painting |
| **Physics** | Rigid bodies, cloth and soft bodies, colliders, joints, wind, the simulation cache |
| **CAD** | Parameters (expressions), the feature tree with sizes you can edit and a health dot, units, the B-rep kernel, mechanism joints, measuring |
| **Scene** | Units, the world's sky (studio or an HDRI), its strength, the frame range |
| **Render** | Size, samples, denoise, bounces, the GPU, Render and Save; virtualized geometry, world partition, light probes, lightmaps, play mode |
| **Viewport** | Shading, grid, theme, camera |
| **Animation** | Shape keys, actions and layers, drivers, onion skins, motion paths |
| **Rig** | The armature's bones and pose, constraints, Parent to Armature |

**Colour fields** open a picker with a saturation / value square, a hue strip, the old and new colour, a hex code, and **Pick**, which takes the next colour you click anywhere on screen.

## Other editors

- **Outliner.** Each row has a type icon, the name (gold when active) and an eye. Double-click a row or press F2 to rename. The filter field at the bottom finds objects by name.
- **Timeline.** Play, step and the frame range, plus auto-key, which keys every confirmed move.
- **Dope Sheet / Graph Editor.** Interpolation, handles, duplicate and delete for the selected keys.
- **Node Editor.** The header chooses the graph (a material or a node tree). The Add menu filters as you type.
- **UV Editor.** Unwrap, Pack, Select All, the stretch heat map. More is in Mesh › UV.
- **Render.** Render, Stop, Save, Denoise, the pass shown, the samples done.
- **Asset Browser.** Search, a kind filter, Save to Library. Right-click a tile to place it, tag it, show its dependencies or remove it.
- **Versions.** Commit, branches, merge with conflict choices, history. It also handles collaboration (host, join, follow a peer, let an agent join) and the live link.
- **AI Activity.** What agents did, their permission, and Accept / Revert for a waiting proposal.
- **Help.** Everything about whatever the pointer last rested on.

## The status bar

The left side shows what the mouse and keys do right now, as key chips. On the right are the scene's size, the AI permission (click it for the AI menu), the progress of a render and who is co-editing.

Messages show as **toasts** above the status bar for four seconds:

- **green** for results;
- **amber** for problems.

Click a toast to open the console.

## Preferences

**Edit › Preferences** opens a Preferences area. Everything in it is saved to `~/.config/beemodel/prefs` as soon as it changes.

| Section | Settings |
|---|---|
| **Interface** | Theme (Dark, Light, High contrast), UI scale 75–200 %, tooltip delay, colour-blind-safe axis colours, the welcome screen |
| **Input** | Alt + left button as the middle button, orbit speed |
| **Keymap** | Search, Set (then press the key), Clear, Reset All Keys. It warns you when a key is already taken |
| **System** | Worker threads, the GPU, the JIT |
| **Files** | Autosave interval, library folders |
| **AI** | The agents' permission at start-up, the MCP server |

## Accessibility

- Every text and background pair in every theme has a contrast of at least 4.5:1. The High contrast theme goes further.
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
- the keymap choice (BeeModel, or laptop, where Alt + left button pans).

**Help › Welcome Screen** brings it back. To skip it at start-up, turn off "Show this at start" or set `BEEMODEL_WELCOME=0`.

## For agents and tests

The MCP tool `ui_tree` lists every widget on screen: its name, kind, position, label, value, focus and tooltip. Agents use it to see the UI. The fakewl tests use it to click widgets by name instead of by coordinates.

The `walkthrough_ui` scenario models a part, adds a CAD feature, a material and a render, then saves and reopens the scene. It does all of this with clicks and keys only. `ui_bench` measures frame times while the busiest panels redraw. They take about 3 ms here, against a 16 ms budget.
