# BeeModel for AI agents (MCP)

BeeModel is a [Model Context Protocol](https://modelcontextprotocol.io) server.

* While the app runs, it listens on `$XDG_RUNTIME_DIR/beemodel.sock`, a link to `beemodel-<pid>.sock`. `BEEMODEL_SOCKET` overrides the path and `BEEMODEL_NO_MCP=1` turns the server off.
* `beemodel --mcp-bridge` is the stdio relay that MCP clients launch.
* Agents work on the scene the user has open, live. Every change shows up immediately and can be undone.

## Connecting

**Claude Code**

```sh
claude mcp add beemodel -- /path/to/beemodel --mcp-bridge
```

**Claude Desktop** (or any stdio MCP client): add this to the client's configuration.

```json
{ "mcpServers": { "beemodel": { "command": "/path/to/beemodel", "args": ["--mcp-bridge"] } } }
```

Start BeeModel first. The bridge connects to the newest running instance. The status bar shows `AI: edit (1 connected)` while an agent is attached.

## Tools

| Tool | What it does |
|---|---|
| `scene_summary` | Lists the objects as JSON: names, types, transforms, selection, mesh sizes, modifiers and material, plus every material with its values and shader graph (nodes, values, inputs and links, sockets), the images, the world (HDRI, strength, rotation), the scene units and parameters, sketches and the feature tree (type, body, status) |
| `create_primitive` | Adds `{type, name?, location?, rotation_deg?, scale?}`; returns the final name |
| `set_transform` | Changes `{name, location?, rotation_deg?, scale?, new_name?}` |
| `select` / `delete` | Selects or deletes `{names: [...]}`; `select` also takes `extend` |
| `viewport_capture` | Returns the viewport as a PNG image block (`area: "window"` captures the whole UI) |
| `script_eval` | Runs [BeeScript](BEESCRIPT.md) `{code}` as one undo step; returns what it prints and its last value |
| `run_operator` | Runs `{id, arg?}`: any agent-safe operator, such as `file.save` |
| `op_<id>` | Every agent-safe operator as its own tool, such as `op_view_toggle_grid` |
| `undo` / `redo` | Undoes or redoes a step (agent change sets included) |
| `node_types` | The geometry node catalogue as JSON: every type with its inputs (slots 1-3: name, kind, default), values (slots 4-7: name, kind, default, choices) and outputs (index, name, kind), and how the `tree.*` operators use them |
| `describe_graph` | A node tree `{tree?}` as JSON: its nodes with type, the link into each input (`from: {node, output}`) or its constant, the values and the place; without a name, every tree. Includes the proposal's state |
| `propose_begin` / `propose_end` | Open a proposal `{title}` (see below), and show it to the user |
| `proposal_status` | `none`, `building`, `waiting for the user`, `accepted` or `reverted` |

* Resources: `bee://scene` (JSON), `bee://graphs` (every node tree and the proposal's state, JSON).
* Prompt: `procedural` (argument `goal`) walks an agent through a co-pilot proposal.
* Units are meters, Y is up, and rotations are Euler XYZ in degrees (radians in BeeScript).

## Permissions, change sets and activity

**Permissions.** The user chooses what agents may do in the **AI** menu:

| Level | Agents may |
|---|---|
| Read Only | Use `scene_summary`, `viewport_capture` and the resources |
| Edit Scene (default) | Also use every editing tool, scene operators and BeeScript |
| Edit + Files | Also open, save, import, export, take screenshots and render images |

`BEEMODEL_AGENT_PERMISSION=read|edit|files` sets the level at startup.

Calls above the current level return `isError` with an explanation. Agents can't change the level themselves: the permission operators are not agent-safe.

**Change sets.** Each request is one undo step, labeled `Agent: <tool>`. A `script_eval` that adds a hundred objects is still one step.

**AI Activity.** **AI → AI Activity Pane** lists recent calls:

* the status: green for ok, red for error, amber for refused;
* whether the call changed the scene (an accent-colored name);
* the first line of its result.

**Revert last agent change** (`agent.revert`) undoes the newest step only if an agent made it.

## The procedural co-pilot

An agent builds node setups as a **proposal** the user previews:

1. `node_types` and `describe_graph` show what can be built and what is there.
2. `propose_begin {title}` opens it. Everything until the user decides is a single undo step, however many requests it takes.
3. The agent builds with `op_tree_new`, `op_tree_node`, `op_tree_link`, `op_tree_node_set` and `op_tree_group`. It puts a tree on an object with `script_eval` (`modifier` / `modset`), and checks the result with `viewport_capture`.
4. `propose_end` shows a banner over the viewport: **Accept** (Enter) keeps the proposal as one undo step, and **Revert** (Esc) takes all of it back. Ctrl+Z after accepting also removes it in one go.
5. `proposal_status` tells the agent the answer.

Opening, closing and reading a proposal need only the read permission. Building it needs the edit permission, as usual.

## Protocol details

* **Transport and format.**
  * Newline-delimited JSON-RPC 2.0, protocol `2025-06-18`. The server echoes the client's `protocolVersion`.
  * Capabilities: `tools`, `resources`.
  * Requests are handled on the UI thread between frames, so they never race the user's edits.
* **Validation and errors.**
  * Every message is validated strictly (RFC 8259).
  * Malformed JSON gets `-32700` with `id: null`.
  * Non-objects, batches and requests without a method get `-32600`.
  * Unknown methods get `-32601`.
  * Tool failures are results with `isError: true`, as the spec requires.
* **Ids and notifications.** Ids are echoed byte for byte: strings, large integers and 0 all work. Notifications and the client's own responses get no reply.
* **Limits.** Up to 4 clients at once; messages up to 256 KiB; BeeScript sources up to 64 KiB.

## Conformance tests

`tools/fakewl.py` runs BeeModel against a fake Wayland compositor and checks the MCP layer twice: over the socket, and through the stdio bridge the way Claude Code launches it. It runs in CI on every pull request and release.
