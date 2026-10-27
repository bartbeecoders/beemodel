# BeeModel's own small LLM

*Design note, 2026-10-23. The question that started it:*

> Can you create our own small LLM that can understand how BeeModel works,
> and how a 3D model needs to be created? If we want to create this
> ourselves, what would it take, and how would you approach it?

## Summary

Build it as a **fine-tuned small open model**, not a model trained from
scratch, and serve it locally through the connection BeeModel already has.
BeeModel is an unusually good target for this: the model's whole output is
BeeScript and MCP tool calls, a small formal language that is documented in
`docs/BEESCRIPT.md`, `docs/MCP.md` and `docs/mcp-tools.json`, and BeeModel
itself can run, check and render every candidate answer. That verifier is
what turns a mediocre 4B model into a good domain model.

The result will be fast, offline, private and free, and strong on the
*Ask AI about the selection* class of requests. It will not match a frontier
model on open-ended scenes or long reasoning. It complements the Claude Code,
Grok and OpenRouter connections and becomes the fallback when no key is set.

## Three ways to read "our own LLM"

| Option | Cost | Verdict |
|---|---|---|
| Pretrain from scratch | Trillions of tokens, millions of euros of GPU | No. It would speak worse English than a free 1B model |
| Fine-tune a 4B to 8B open model on BeeModel data | One 24 GB GPU for hours, or a rented H100 at a few euros per hour. Under a few hundred euros per run | **Yes.** This is "our own LLM" |
| No training: a stock open model, local, with a strong prompt | Zero code. `docs/AI.md` already says any OpenAI-compatible server works for the OpenRouter connection | **Yes, first.** The baseline every later step must beat |

## What the model has to know

1. **BeeScript.** Syntax, units (meters, Y up, ground on XZ), the builtins
   in `docs/BEESCRIPT.md`: scene, materials, modifiers, geometry nodes, SDF
   shapes, text, lights, camera, animation.
2. **The curated MCP tools.** `scene_summary`, `script_eval`,
   `viewport_capture`, `run_operator`, the material and node tools. The
   600 single-operator tools are out of scope, as they are for OpenRouter.
3. **The way of working** in `docs/AI.md`: look first, plan briefly, build
   in batches with `script_eval`, look again and fix.
4. **Modelling know-how.** How to decompose "a chair", "a mug", "a cabin"
   into primitives, extrusions, insets, bevels, modifiers and materials,
   with sane proportions and things resting on each other. This is the part
   small models lack and the part the data has to teach.

## Data: the whole problem

A fine-tune needs thousands of pairs of *prompt → correct BeeScript or tool
trace*. The repo holds the docs, 8 `.bees` test scripts and a few fixtures:
a few hundred examples at best. The plan is a **data factory** with
BeeModel as the filter.

### Sources

1. **Distil from a frontier model.** Generate a few thousand prompts in
   tiers and run Claude through the MCP bridge on each, recording the tool
   trace exactly as the transcript shows it.
   - Tier 1, one-liners about a selection: *bigger*, *brushed steel*,
     *bevel these edges 2 mm*, *copy around*, *twice as tall*.
   - Tier 2, single objects: a chair, a mug, a lamp, a wheel, a bottle.
   - Tier 3, small scenes: a table with four chairs, a cabin in a clearing,
     a street light row.
   - Tier 4, edits in context: start from a saved scene, ask for a change.

   Check the provider's terms of use on training with its outputs before
   this step.
2. **Mutate what exists.** Take every `.bees` script and fixture, vary
   parameters, counts, names and materials, and write the matching
   description. Cheap and exact.
3. **Real use, opt-in.** An *Ask AI* request already yields a prompt, a
   trace and a label: Ctrl+Z on the request is a thumbs down, a follow-up
   that builds on it is a thumbs up. Off by default, stored locally,
   exported only when the user chooses.
4. **Negative examples.** Scripts that call builtins that do not exist,
   with the error BeeModel gives, paired with the corrected script. These
   teach the model what to avoid and how to recover.

### Verification, the step that matters

Every sample goes through BeeModel before it is kept:

1. Replay the trace headless: `beemodel --run sample.bees` or `--eval`.
   Drop anything that errors or times out.
2. Check the result with `scene_summary`: object count, names, sizes and
   materials against what the prompt asked for, where a rule can say so.
3. Render with `viewport_capture` and have a vision model grade the image
   against the prompt. Keep only passing samples.
4. Deduplicate near-identical prompts and traces.

Target **5 000 to 50 000 verified examples**. Below a thousand the
fine-tune will not move the needle.

### Format

One JSON line per sample, OpenAI-style chat messages: the system prompt
BeeModel sends today, the user prompt with the `scene_summary` context the
app adds, then alternating assistant tool calls and tool results, ending in
the assistant's one-line answer. Same shape as the OpenRouter connection
sends, so the model is trained on exactly what it will see.

## Training

1. **Base.** A 4B to 8B instruct model with native tool calling, Qwen 3 or
   Gemma class. Pick by running the baseline evaluation on the stock models
   first; the one that already does best on BeeScript is the one to tune.
2. **Stage 1, supervised LoRA.** Rank 16 to 64, a few epochs over the
   verified set, learning rate in the usual 1e-4 range, loss on the
   assistant turns only. Hours on one GPU.
3. **Stage 2, verifier reward.** Only if the evaluation shows gaps after
   stage 1. Sample several answers per prompt, run them through the
   verifier, keep the best as new training data (rejection sampling) or
   train GRPO-style with the verifier as reward. The reward is honest and
   cheap: the script runs, the right objects exist, the render matches.
4. **Quantise** to GGUF, Q4_K_M or Q5. A 4B model is about 2.5 GB and runs
   on CPU at usable speed; a GPU makes it instant.

## Serving: what changes in BeeModel

Almost nothing. The 2 MB binary budget rules out inference inside the app,
so the model runs in llama.cpp or Ollama as a separate process and BeeModel
talks to it over the existing OpenRouter path, the way ffmpeg is an
external dependency for video.

- **Preferences › AI:** a *Local model* preset that fills the address
  (`http://localhost:11434/v1`), the model name and an empty key, and a
  *Test* button like the others.
- **Download:** `beemodel-ai-<version>.gguf` as a release asset, with a
  one-line install in the docs. Optional; nothing breaks without it.
- **Fallback:** when no connection is configured and a local server
  answers, use it.
- **Opt-in logging** of Ask AI exchanges for the data factory, in the
  prefs, off by default.

## Evaluation first

Nothing above can be judged without a yardstick, so the first deliverable
is the evaluation set, not the model:

- 100 to 200 prompts across the four tiers, each with an automatic check:
  runs without error, expected objects and sizes within tolerance, and for
  scenes a vision grade.
- A runner that scores any OpenAI-compatible endpoint, so frontier models,
  stock open models and every fine-tune are compared on the same numbers.
- It grows from the existing harness: `tests/ai.py` and
  `tests/ai_standin.py` already drive the MCP bridge headless.

## Phases

| Phase | Work | Takes |
|---|---|---|
| 0 | Ollama with a stock model through the OpenRouter connection, a BeeScript cheat sheet in *Also tell the AI*. The evaluation set and runner. Baseline numbers for Claude, Grok and two or three stock open models | 1 week |
| 1 | The data factory: prompt generator, trace collection through the bridge, headless verifier, vision grader, dataset writer. First 5k verified samples | 2 weeks |
| 2 | Stage 1 LoRA on the best stock base, evaluate, iterate on data gaps, quantise. A model that beats its own base on the evaluation and does not hallucinate builtins | 1 week |
| 3 | Stage 2 verifier reward if needed. *Local model* preset, Test button, fallback, release asset, docs. Opt-in logging | 1 week |
| later | A vision-capable base so reference images can drive a model. Edit-mode traces at vertex level. Teach it new builtins as BeeScript grows, by re-running the factory | |

## Honest expectations

- A tuned 4B beats a stock 4B by a wide margin on BeeScript syntax and tool
  use, and will likely hallucinate fewer builtins than frontier models
  because its whole world is BeeModel.
- It loses to Claude on *a misty pine forest around a stone cabin at dusk*
  and on anything needing many steps of correction.
- Quality tracks the data. Every weak area in the evaluation is a missing
  tier in the prompt generator, not a model problem.
- Running cost is zero after training; retraining when BeeScript changes is
  a re-run of the factory and a few GPU hours.


Option 2 POC:
Lets try it out on a Qwen3.5 4B model.
Create the tooling to be able to do this (under a seperate folder: beemodel-llm)
As I'm new to all this, take me through the process step by step. 
Download all you need to do this. Write the tooling in a programming language of you choice.
Make sure that we can repeat the process, maybe later extend it to other models.

## Proof of concept (2026-10-24)

Done in the sibling project `../beemodel-llm` (Python, Unsloth; its README
is the step-by-step walkthrough). Base: Qwen3.5 4B, 16-bit LoRA r=32 on an
RTX 4080 Super, 10 GB of VRAM, 98 minutes for two epochs over 2979 generated
and verified records (tiers 1 to 5 of the design above, every record run
through `beemodel --eval` before it is kept). Merged to GGUF and registered
in Ollama as `beemodel-ai:run1-q8_0` and `beemodel-ai:run1-q4_k_m`;
BeeModel talks to it over the OpenRouter connection at
`http://localhost:11434/v1`.

Evaluation set of 110 hand-written requests, checked geometrically in
headless BeeModel:

| model | pass | Ask AI edits | single objects | scenes | edits in context | questions |
|---|---|---|---|---|---|---|
| stock qwen3.5:4b | 19.1% | 31% | 4% | 0% | 27% | 80% |
| stock + cheat sheet (phase 0) | 22.7% | 43% | 7% | 10% | 20% | 60% |
| tuned, Q8_0 | 80.9% | 91% | 78% | 60% | 80% | 80% |
| tuned, Q4_K_M | 80.9% | 91% | 78% | 60% | 80% | 80% |

Script errors fell from 299 to about 30. The remaining failures are shapes
the data factory has no family for and small height sums, which confirms
the expectation above: quality tracks the data. Not done yet: stage 2
(rejection sampling against the verifier), error-and-recovery samples,
vision grading, a held-out check for memorisation (final loss 0.003 to
0.007 is suspiciously low).
