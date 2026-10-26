# The AI Assistant

Describe a world, a model or a change in plain words, and BeeModel builds it
in the open scene while you watch. The assistant runs inside the app. It
uses one of four connections, all of which act through BeeModel's own MCP
tools (the same ones outside agents get, see [MCP.md](MCP.md)):

| Connection | How it runs | What you need |
|---|---|---|
| **Claude Code** | `claude -p` as a child process, with an MCP configuration naming `beemodel --mcp-bridge` for this instance | [Claude Code](https://claude.com/claude-code) installed and logged in |
| **Grok CLI** | `grok -p` as a child process, in its own agent directory with a `.grok/config.toml` naming the bridge | The Grok CLI installed and logged in |
| **OpenRouter** | HTTPS chat completions through `curl`. BeeModel runs the tool loop itself, in-process | An OpenRouter API key (any OpenAI-compatible server works too) and `curl` |
| **Ollama (local)** | The same as OpenRouter, sent to [Ollama](https://ollama.com) on this machine. No key is sent, and the model is asked not to think (`"reasoning_effort": "none"`) | Ollama running (`ollama serve`) with a model that calls tools, and `curl` |

## Using it

1. Press **Ctrl+Shift+Space** or pick **AI › AI Assistant**. The first time,
   this makes the **AI** workspace: a viewport, the AI Assistant and the
   outliner. The caret is placed in the prompt. Any area can also be
   turned into an AI Assistant from its editor-type menu.
2. Type what you want, for example *"a misty pine forest around a stone
   cabin at dusk"* or *"make the cabin bigger and add a chimney"*, and press
   **Enter** (or click **Send**). A prompt can have several lines:
   **Shift+Enter** starts a new one, and pasted text keeps its line breaks.
   The prompt wraps long lines, grows to show up to 10 of them and takes
   up to 4000 bytes. **Up** and **Down** move the caret between lines, and
   **Home** and **End** go to the start and end of the line.
3. The transcript shows:
   - your prompt;
   - the model's text;
   - each tool call with its arguments, and the start of its result;
   - errors.

   While the AI works, the status line says so, and **Stop** replaces Send.
   Stop ends the child process or the request at once. The window keeps
   drawing the whole time.
4. Each request is **one undo step**, named `Agent: <your prompt>`. **Revert**
   at the top of the area (or Ctrl+Z) takes the whole request back. It also
   shows in **AI Activity**, like any agent's work.
5. Follow-ups continue the same conversation:
   - Claude Code and Grok resume their session;
   - OpenRouter and Ollama are sent the whole conversation again.

   **New** starts a new conversation. It leaves the scene as it is.
6. **Copy** (or **AI › Copy AI Conversation**, operator `ai.copy`) puts the
   whole conversation on the clipboard as it is shown, one line per entry,
   to paste into a bug report or another program.

The connection picker at the top of the area chooses Claude Code, Grok,
OpenRouter or Ollama for the next request.

## Ask about the selection

To change what you are looking at, you don't need the AI workspace.
**Alt+right-click** an object in the viewport, or pick **Ask AI...** at the
top of the viewport's right-click menu (or the **AI** menu). A small box
opens at the pointer.

- Its title says what the request is about: *Ask AI about **Cube***,
  *about **3 objects***, *about **4 vertices of Cube*** in edit mode, or
  *about the scene* when nothing is selected. An object you Alt+right-click
  that was not selected is selected first.
- Type what to do (*make it twice as tall*, *brushed steel*, *bevel these
  edges 2 mm*) and press **Enter**. **Esc**, or a click outside the box,
  closes it. **Up** and **Down** bring back your last 8 prompts.
- The quick buttons ask the common things at once: **Bigger**, **Smaller**,
  **Copy Around** (eight copies in a circle). **Material...** starts the
  prompt with *Change the material to* for you to finish. In edit mode they
  extrude, inset and bevel instead.
- The box closes when the request is sent. While the AI works, the status
  bar shows the request; click it to stop. The AI's answer (its first
  line) then shows as a message, and the whole exchange is in the AI
  Assistant's conversation, so a follow-up there (*a bit more*) carries on.
- Each request is one undo step, like the Assistant's.

**What the AI is told.** The request goes with the selection: each
selected object as `scene_summary` lists it (name, type, location,
rotation, scale, size, material, modifiers), the active one first, 16 at
most. In edit mode it gets the selected vertices (and the whole faces they
make), their centre, and how the mesh operators act on them. The
transcript shows only your prompt, with a note of what it was about.

**Only the selection** (on by default, remembered): the AI is asked to
change the selected objects only, and BeeModel checks that it did. Before
the request every object is fingerprinted (its place, mesh, modifiers,
material, and a light's colour); when it ends, objects outside the
selection that changed or were deleted are named in a warning, for
example *The AI also changed Light (not selected). Ctrl+Z undoes the
request.* New objects don't count, so *put four copies around it* is fine.
A material shared with other objects counts as theirs too.

From the console or a script, `ai.ask <prompt>` sends a request about the
selection without the box. It is not an MCP tool: an agent does not start
another agent.

## Lining up reference drawings

After **Add › Reference Images from Folder...** (see [UI](UI.md)), **AI ›
Line Up References with AI** asks the AI to check the drawings and line
them up. It works on the set the selected reference belongs to, or else on
the last one imported. The request lists every reference: how it stands,
its folder, its size in metres and pixels. It also gives the AI the rules:

- Look at each page with the MCP tool `reference_view`, zooming into a
  part to read a pixel exactly.
- Re-sort a page taken for the wrong kind with `object.reference_kind
  <reference> front|back|left|right|plan|section|site|terrain|other [level
  [turn]]`. It turns the page for its new kind and moves it into that
  kind's folder.
- Pin them all to the same corner with `object.reference_pin <reference>
  <u> <v> <x> <y> <z>`, which moves the image so its pixel u,v lands on
  the point x,y,z. The origin is the building's front-left corner at
  ground level. The front faces +Z and the building runs to +X and -Z. The
  front elevation's ground line starts at 0 0 0, the rear one at W 0 -D,
  the plans' corners at their floor height.

The whole request is one undo step, like any other. You can run both
operators yourself from the console too.

## Settings: Preferences › AI

Open **Edit › Preferences** (Ctrl+,) and pick the **AI** category:

| Setting | |
|---|---|
| The AI Assistant uses | The connection used by default (the area's picker changes the same setting) |
| Also tell the AI | Text added to every request's instructions, such as a style, units, or what to avoid |
| Only the selection | The Ask AI box's toggle: keep the AI to the selected objects (stored as `ai_only_selection`) |
| Claude Code: Program, Model, Turns at most | The `claude` program (empty: the one on `PATH`), a model name or alias (empty: Claude Code's default), and how many rounds of tool calls one request may take (40) |
| Grok CLI: Program, Model, Turns at most | The same for `grok` |
| OpenRouter: API key, Model, Address, Steps at most | The key (masked), a model id with tool calling (`anthropic/claude-sonnet-4.5`), the API address (`https://openrouter.ai/api/v1`) and the step limit (30) |
| Ollama (local): Model, Address, Steps at most | A model as `ollama list` names it (`qwen3.5:4b`), Ollama's OpenAI-compatible address (`http://localhost:11434/v1`) and the step limit (30) |
| Test Claude Code / Test Grok / Test OpenRouter / Test Ollama | Runs `--version`, asks OpenRouter whether the key works (this costs nothing), or asks Ollama whether it runs and has the model. The answer shows as a message and in the transcript |
| Agents | What AI agents may do (read, edit, files), and whether the MCP server listens |

## Safety

- **The key** is kept in `~/.config/beemodel/secrets` (mode 0600). It is
  never stored in the prefs file or a `.bee` file, never shown, and never
  logged. `curl` reads it from a header file in `~/.cache/beemodel/ai`
  (a 0700 directory, the file 0600), so it never appears on a command line.
  When no key is set, `OPENROUTER_API_KEY` is used.
- **Permissions.** The assistant works under the same permission as every
  agent (**AI** menu, or Preferences › AI). The default is *Edit Scene*.
  File access is opt-in.
- **Only BeeModel's tools.**
  - Claude Code runs with `--strict-mcp-config --allowedTools mcp__beemodel`.
  - Grok runs in its own directory (`~/.cache/beemodel/ai`), without its
    shell, file, sub-agent and web tools. It runs with `--trust` so it loads
    that configuration. MCP servers in your own `~/.grok/config.toml` stay
    visible to it.
  - OpenRouter and Ollama models get the curated tools (`scene_summary`,
    `script_eval`, `viewport_capture`, `run_operator`, the material and
    node tools, ...). They do not get the 600 single-operator tools.
- **Undo.** Each request is one undo step. Changes you make while a request
  runs join that step.

## How the AI is told to work

Every request carries the world-building instructions:

- **Conventions:** meters, Y up, the ground on the XZ plane.
- **A way of working:**
  - look first (`scene_summary`, `viewport_capture`);
  - plan briefly;
  - build in batches with `script_eval` (BeeScript): primitives, materials
    and presets, terrain and scattering with geometry nodes, lights, a
    camera, the world HDRI;
  - look again and fix what is wrong.
- **Text:** `text.add`, then move it into place; `text_set` /
  `text.set` to change it; `text:Name:reveal` keys to type it on;
  `{frame}` placeholders to count. A text object's body and settings are
  in `scene_summary`, so "change the title to ..." finds it
  ([TEXT.md](TEXT.md)).

Outside agents get the same instructions as the MCP prompt `build_world`
(argument `goal`).

## Watching it from outside

`ai.transcript` prints the conversation's last 24 lines to the console, as
`$ <kind> <text>`. The kinds are:

| Kind | Meaning |
|---|---|
| `Y` | You |
| `A` | The AI |
| `T` | A tool call |
| `R` | Its result |
| `E` | An error |
| `N` | A note |

Over MCP this operator is the tool `op_ai_transcript`. The test suite reads
the conversation this way.

## Testing without accounts

`tests/ai.py` runs the whole flow without any network or account:

- Stand-ins for `claude` and `grok` (`tests/ai_standin.py`, placed on
  `PATH`) read their arguments, talk to BeeModel through the bridge and
  print the real stream formats.
- A localhost server plays OpenRouter. It answers with scripted tool calls
  and checks what it is sent. Under another path it plays Ollama: the
  same tool loop, no key, thinking off, and the model list for its Test.
