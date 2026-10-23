# 3D text

Titles, signs, labels, logos and counters as real geometry. A **text
object** is an ordinary mesh object whose mesh also carries the text it
was made from. Drawing, materials, modifiers, rendering, export, physics
and 3D printing all see the mesh. Change the text, its font or its size
and the mesh is built again; edit the mesh itself and it becomes a plain
mesh.

Text can be animated letter by letter (typed on, growing, rising,
dropping, waving), can count (`{frame}`, `{floor(time)}`), and is
something the AI can add, read and change.

The code is in these files:
- `src/text3d.s`: the text block, the fonts, the outlines collected from
  the TrueType engine, the layout, the solids, the animation channels,
  `text.add` / `text.set` / `text.to_mesh`, the TEXT chunk.
- `src/textui.s`: the Text section of Properties › Object.
- `src/ttf.s`: the TrueType engine (shared with the UI). Its contour
  walker calls hooks (`ol_begin`, `ol_line`, `ol_end`) instead of
  rasterizing.
- `src/prof.s`: loops nested into material and holes, holes bridged into
  their outline, ear clipping, the inset for bevels (shared with sketch
  profiles).

The tests are in `tests/text.py`.

## Adding text

From the menus:
- **Add › Text** adds "Text" at the 3D cursor and selects it.
- **Properties › Object › Text** (for a text object): the body, the font,
  size, depth, bevel, alignment, letter spacing, line height, slant,
  quality, then **Letter by letter**: reveal, how letters appear, over
  how many letters, wave, wavelength, phase. Then **Convert to Mesh**.
- **Object › Convert Text to Mesh** (greyed out unless a text is active).

From scripts and the console:

```
op("text.add", "'Hello world' size 0.5 depth 0.1")
t = active()                                  # its name (Text, Text.001 ...)
move(t, 0, 1, 0)
op("text.set", "'New words' font 'DejaVu Serif Bold' bevel 0.01 align left")
print(text(t))                                # what it says
text_set(t, "Second\nversion")                # change what it says
op("text.to_mesh")                            # the active text: a plain mesh
```

`text.add` takes the body first, quoted (`"..."` or `'...'`), or as bare
words (`text.add Hello World size 2`). `text.set` changes the **active**
text object and needs the body quoted or after `body` (`text.set body Hi`),
so a mistyped setting is reported instead of becoming the text. In a
quoted body, `\n` starts a new line and `\"` / `\'` are quotes.

| Setting | Default | What it does |
|---|---|---|
| `size` | 1 | The em: the height of a line from descenders to ascenders (m) |
| `depth` | 0.2 | How thick the letters are (m); 0: flat |
| `bevel` | 0 | A 45° chamfer round the front and back edges (m; at most half the depth) |
| `font` | default | A font's name (`'Noto Serif Bold'`), a `.ttf` path, or `default` |
| `align` | center | `left`, `center` or `right` of the origin |
| `spacing` | 0 | Extra room between letters (em) |
| `line` | 1.2 | From one line's baseline to the next (em) |
| `slant` | 0 | Leans the letters (italic): sideways per unit up |
| `quality` | 1 | How finely curves are cut (0.25 to 8) |
| `reveal` | 1 | How much of the text shows (0 to 1 of the letters) |
| `mode` | pop | How letters appear: `pop` (a typewriter), `scale`, `rise`, `drop` |
| `soft` | 1 | Over how many letters one appears (scale, rise, drop) |
| `wave` | 0 | Letters bob up and down by this much (em) |
| `wavelength` | 8 | Letters per wave |
| `phase` | 0 | Where along the wave the first letter is (turns) |

## Layout

The text stands in the XY plane and is read from the front (+Z, Numpad 1).
The last line's baseline sits on the object's origin and earlier lines
stack upwards, so a title added on the ground stands on it. Lines are
aligned left, centred or right of the origin; letters advance by the
font's advance widths (no kerning).

## Fonts

The default font is the interface's sans face (Noto Sans, DejaVu Sans or
Liberation Sans, whichever is installed), or `$BEEMODEL_TEXT_FONT` (a
`.ttf` path, or `none` for the built-in block font).

Properties › Text lists every `.ttf` file under `/usr/share/fonts`,
`/usr/local/share/fonts`, `~/.local/share/fonts` and `~/.fonts`, by file
name. In scripts, a font is named like its file, ignoring case, spaces,
hyphens and underscores: `'DejaVu Sans Bold'` finds `DejaVuSans-Bold.ttf`.
A path (with a `/`, `~` allowed) is used as it is. A font that can't be
found or read falls back to the default, and the console says so.

Fonts are TrueType outlines (`glyf`), simple and composite glyphs, with
cmap formats 4 and 12. OpenType fonts with CFF outlines (most `.otf`) and
collections (`.ttc`) are not read.

**The block font.** Without a TrueType font, or for a character the font
doesn't have, the built-in 8×16 bitmap font is extruded pixel by pixel.
Where two pixels touch only at a corner each keeps its own vertex, so the
mesh stays closed.

## How the mesh is made

1. The body is expanded (placeholders, below).
2. For each glyph, the TrueType engine walks its contours. Quadratic
   curves are flattened to 256 × quality units per em. The edges are
   collected as loops instead of being rasterized.
3. The loops are nested by containment. Material loops turn
   anticlockwise and holes clockwise, so an `o`, a `B` and an `8` keep
   their holes.
4. Each simple glyph, and each part of a composite one (an accent, a
   ring), is made solid on its own, so parts that overlap stay closed.
   - Walls go round every loop.
   - Each material loop gets front and back caps, with its holes bridged
     in and the result ear-clipped.
   - The solid is centred on z = 0.
5. With a bevel, the caps are inset by the bevel (mitred corners) and
   chamfers join them to the walls. Where the inset loops would cross
   (thin strokes; the bowl of a `d` meeting its stem), that glyph's bevel
   is halved until they don't.

Every mesh is closed and outward-facing: `manifold()` is 1 and
`volume()` is positive.

**Speed.** A 1,026-character text (122,000 vertices) builds in about 27 ms
(38 characters a millisecond) on a Ryzen 9 7950X, on one thread. With a bevel it takes
about 55 ms; at quality 2, about 41 ms. A bevelled, waving 40-character
title rebuilds in about 1 ms a frame during playback.

## Animation

Every value in the table except the font and alignment is a channel,
keyframed as `text:<name>:<value>`:

```
op("anim.key", "text:Title:reveal 1 0 linear")     # typed on over 2 s
op("anim.key", "text:Title:reveal 48 1 linear")
op("anim.key", "text:Title:phase 1 0 linear")      # the wave travels twice
op("anim.key", "text:Title:phase 48 2 linear")
print(keyed("text:Title:reveal", 24))
```

In Properties › Text, **I** over a value keys it, and so does **Insert
Keyframe** in its right-click menu. Keyed text shows in the curve
editor as "Title reveal".

**Reveal** shows the first `reveal × N` letters (spaces count). With
**pop**, letters appear at once, like a typewriter. With **scale**,
**rise** and **drop**, each letter takes `soft` letters' worth of the
reveal to grow from nothing, rising from below or dropping from above
as it does. The **wave** moves letter *i* up by
`wave × sin(2π (phase + i / wavelength))`.

A frame sets all its keyed values first and then builds each text once
(after drivers and constraints).

### Placeholders: counters and clocks

An expression in curly brackets in the body is worked out whenever the
text is built, and on every frame:

| In the body | Shows |
|---|---|
| `Frame {frame}` | Frame 37 |
| `{floor(time)} s` | 1 s (time = frame / fps) |
| `{floor(time / 60)}:{floor(time) - 60 * floor(time / 60)}` | 0:12 |
| `Score {frame * 10}` | Score 370 |
| `{{literal}}` | {literal} |

Expressions are the CAD parameters' (`sin`, `floor`, `round`, `min` ...,
`pi`, units). Names are `frame`, `time` and `fps`, then the CAD
parameters. Whole numbers show without decimals; others show up to three.
An expression that can't be worked out stays as typed. The mesh is built
again only when the text it reads changes.

## The AI

`text.add`, `text.set` and `text.to_mesh` are MCP tools
(`op_text_add` ...). The scene summary (and Ask AI's context) shows each
text object's body and settings:

```
"text":{"body":"Hello\nWorld","font":"default","align":"center","mode":"pop",
        "size":0.5,"depth":0.1,"bevel":0,...,"reveal":1,...}
```

so "change the title to Goodbye", "make the sign thicker" or "type the
title on letter by letter" can find the text and change it. The
Assistant's instructions say how to add, place, change and animate text.

## Files

A TEXT chunk holds each text mesh's block (the mesh's index, then the
block from its version on). The mesh is saved too. A file opened on a
machine without its font still shows the saved letters, until the text is
changed (then the default font is used).

## Limits

- A simple glyph whose own contours overlap (rare in static fonts; common
  in variable fonts) can get the wrong holes.
- No kerning, ligatures, right-to-left text or shaping: one glyph per
  code point, left to right.
- The body holds 2,047 bytes of UTF-8.
