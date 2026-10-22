# Decisions

The questions the masterplan left open, and what was decided for v1.0.
Each decision is final for the 1.x versions unless it says otherwise.
The plan behind them is `Vibecoding/BeeModel-2.0-Plan.html` (stage D).

## D1 · BeeScript keeps its own syntax, frozen for 1.x

*Decided 2026-10-22 ([#293](https://github.com/bartbeecoders/beemodel/issues/293)).*

**Question.** Should BeeScript look like Python or like Lua?

**Decision.** Neither. BeeScript stays its own small language: expressions as in Python,
blocks in braces, `fn`, `for i in a..b`, and units written after numbers (`20cm`, `45deg`).
AI agents write it reliably, and its errors say what to do instead
(`there are no lists: write each item, or loop with for i in 0..n`).

**What follows.**

* The grammar is written out in [BEESCRIPT.md](BEESCRIPT.md#grammar).
* The syntax is frozen for 1.x. Nothing that runs today changes meaning. Built-ins,
  operator ids and optional trailing arguments may be added.
* Hexadecimal numbers (`0xff8800`) were added before the freeze. The docs already
  described colours that way, and agents write them.
* `tests/beescript.py` runs 50 tasks the way an agent writes them. Every 1.x version
  must run them without an error and with the same answers.

## D2 · BeeModel's keymap stays the default, with a Blender 4.x preset

*Decided 2026-10-22 ([#294](https://github.com/bartbeecoders/beemodel/issues/294)).*

**Question.** Should the default keymap copy Blender's, or be BeeModel's own with a
Blender preset?

**Decision.** BeeModel's own keymap stays the default. It is already close to Blender's
for most keys, and copying Blender's would take away some of its own shortcuts
(Shift+Tab texture paint, F reset camera, Shift+Q/W/E/R tools). A **Blender 4.x** preset
changes only the keys that differ.

**What follows.**

* The preset is in Preferences › Keymap and on the welcome screen. The welcome screen
  offers it with or without Alt + left button as the middle button (laptops).
  `prefs.keymap blender | beemodel` sets it from the console or a script.
* The preset is stored as ordinary key overrides, plus `keymap 1` in the prefs file, so
  you can still change any key afterwards.
* [UI.md](UI.md#the-blender-4x-keymap) lists every difference and why.
