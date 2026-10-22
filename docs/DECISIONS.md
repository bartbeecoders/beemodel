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
