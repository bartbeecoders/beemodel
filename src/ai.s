# =============================================================================
#  BeeModel - the AI Assistant: a conversation with an AI that builds in the
#  scene through BeeModel's own tools.
#
#  Three connections (Preferences > AI):
#    - Claude Code and the Grok CLI run as a child process (aiproc.s) with an
#      MCP configuration naming "beemodel --mcp-bridge" for this instance's
#      socket; their stream of JSON lines (the same shape for both) comes
#      into the transcript; the session id is kept for follow-ups.
#    - OpenRouter (or any OpenAI-compatible server): chat completions over
#      HTTPS through curl, with the curated MCP tools as functions; the tool
#      calls are run here, in-process (mcp_local), and the results sent back
#      until the model answers or the step limit is reached.
#
#  A request is one undo step ("Agent: ..."), revertable in one click. The
#  AI Assistant area: the connection, New Conversation, Revert, the
#  transcript, the prompt (Enter sends; Shift+Enter, or a paste, makes it
#  several lines, and it grows to show them) with Send / Stop. Ctrl+Shift+Space
#  (ai.mode) goes to the prompt, making the AI workspace when no AI
#  Assistant area is shown.
# =============================================================================
.intel_syntax noprefix
.include "const.inc"
.include "macros.inc"
.include "widgets.inc"

.globl ed_ai_draw
.globl ai_send
.globl ai_send_as
.globl ai_note
.globl ai_answer
.globl ai_label
.globl ai_test
.globl ai_world_get
.globl ai_busy
.globl ai_tx_len

.equ TX_CAP,     65536                  # the transcript (entries: kind, text, 0)
.equ LINE_CAP,   262144                 # a CLI's line being read
.equ REPLY_CAP,  4194304                # curl's reply
.equ TMP_CAP,    65536
.equ K_YOU,      1
.equ K_AI,       2
.equ K_TOOL,     3
.equ K_ERR,      4
.equ K_RES,      5
.equ K_NOTE,     6
.equ LINE_H,     20
.equ PROMPT_CAP, 4000                   # the prompt's text (widgets.s ML_CAP)
.equ PROMPT_MAXL, 10                    #  and the lines it grows to

.section .bss
.align 8
ai_hist_st:     .skip 24                # OpenRouter: the messages (wb state)
ai_body_st:     .skip 24                #  a request's body
ai_tools_st:    .skip 24                #  the tools as functions
ai_req_st:      .skip 24                #  a tool call for mcp_local
ai_end:         .skip 8                 # the reply's end (j_end, kept)
ai_line_len:    .skip 8
ai_indent:      .skip 8                 # ai_add's later lines' indent
ai_line_skip:   .skip 4                 # in a line too long to read
ai_reply_len:   .skip 8
ai_tx_len:      .skip 4
ai_busy:        .skip 4                 # 1 while a request runs
ai_run:         .skip 4                 # its connection (0 1 2; 3 a test)
ai_local:       .skip 4                 # 1: OpenRouter's way, to Ollama on this machine
ai_test_which:  .skip 4
ai_stopped:     .skip 4
ai_grouped:     .skip 4                 # the request's undo group is open
ai_scroll:      .skip 4
ai_stick:       .skip 4                 # follow the newest text
ai_focus:       .skip 4                 # start typing in the prompt (ai.mode)
ai_sid_prov:    .skip 4                 # the connection ai_sid is for, + 1
ai_or_n:        .skip 4                 # OpenRouter: steps taken
ai_iserr:       .skip 4
ai_req_off:     .skip 4                 # where the request's entries start
ai_tx:          .skip TX_CAP
ai_line:        .skip LINE_CAP
ai_reply:       .skip REPLY_CAP
ai_tmp:         .skip TMP_CAP
ai_args:        .skip TMP_CAP
ai_sys:         .skip 16384             # the instructions (world prompt + extra)
ai_sid:         .skip 128
ai_label:       .skip 112
ai_prompt:      .skip PROMPT_CAP+16     # the prompt field's text
ai_path:        .skip 512               # the program run
ai_cfg:         .skip 600               # its MCP configuration file
ai_cfgarg:      .skip 600
ai_hdr:         .skip 600               # "Authorization: Bearer <key>"
ai_url:         .skip 600
ai_turns:       .skip 16
ai_type:        .skip 32
ai_name:        .skip 128
ai_cid:         .skip 128

.section .rodata
s_bearer:       .asciz "Authorization: Bearer "
s_or_env:       .asciz "OPENROUTER_API_KEY="
s_chat:         .asciz "/chat/completions"
s_keypath:      .asciz "/key"
s_modelspath:   .asciz "/models"
s_claude:       .asciz "claude"
s_grok:         .asciz "grok"
s_mcpjson:      .asciz "/mcp.json"
s_grokdir:      .asciz "/.grok"
s_groktoml:     .asciz "/.grok/config.toml"
s_strip:        .asciz "mcp__beemodel__"
s_you:          .asciz "> "
s_eq:           .asciz "  = "
s_tool_pfx:     .asciz "  "
# Claude Code
a_p:            .asciz "-p"
a_ofmt:         .asciz "--output-format"
a_sjson:        .asciz "stream-json"
a_verbose:      .asciz "--verbose"
a_mcpcfg:       .asciz "--mcp-config"
a_strict:       .asciz "--strict-mcp-config"
a_allowed:      .asciz "--allowedTools"
a_mcpbee:       .asciz "mcp__beemodel"
a_maxturns:     .asciz "--max-turns"
a_append:       .asciz "--append-system-prompt"
a_model:        .asciz "--model"
a_resume:       .asciz "--resume"
a_version:      .asciz "--version"
# Grok CLI
a_cwd:          .asciz "--cwd"
a_smjson:       .asciz "streaming-messages-json"
a_approve:      .asciz "--always-approve"
a_noweb:        .asciz "--disable-web-search"
a_notools:      .asciz "--disallowed-tools"
a_gk_deny:      .asciz "run_terminal_command,search_replace,write,read_file,list_dir,grep,kill_command_or_subagent,spawn_subagent,scheduler_create,scheduler_delete,workflow,image_gen,monitor"
a_trust:        .asciz "--trust"                # (its .grok/config.toml: loaded)
a_rules:        .asciz "--rules"
a_m:            .asciz "-m"
a_r:            .asciz "-r"
# configuration files
j_mcp_a:        .asciz "{\"mcpServers\":{\"beemodel\":{\"command\":"
j_mcp_b:        .asciz ",\"args\":[\"--mcp-bridge\"],\"env\":{\"BEEMODEL_SOCKET\":"
j_mcp_c:        .asciz "}}}}\n"
t_grok_a:       .asciz "[mcp_servers.beemodel]\ncommand = "
t_grok_b:       .asciz "\nargs = [\"--mcp-bridge\"]\nenabled = true\n\n[mcp_servers.beemodel.env]\nBEEMODEL_SOCKET = "
# OpenRouter
j_body_a:       .asciz "{\"model\":"
j_body_b:       .asciz ",\"messages\":["
j_body_c:       .asciz "],\"tools\":"
j_sys_a:        .asciz "{\"role\":\"system\",\"content\":"
j_user_a:       .asciz "{\"role\":\"user\",\"content\":"
j_asst_a:       .asciz "{\"role\":\"assistant\",\"content\":"
j_asst_b:       .asciz ",\"tool_calls\":"
j_tool_a:       .asciz "{\"role\":\"tool\",\"tool_call_id\":"
j_tool_b:       .asciz ",\"content\":"
j_fn_a:         .asciz "{\"type\":\"function\",\"function\":{\"name\":"
j_fn_b:         .asciz ",\"description\":"
j_fn_c:         .asciz ",\"parameters\":"
j_fn_d:         .asciz "}}"
j_tlist:        .asciz "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/list\"}"
j_call_a:       .asciz "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\",\"params\":{\"name\":"
j_call_b:       .asciz ",\"arguments\":"
j_empty_obj:    .asciz "{}"
j_empty_str:    .asciz "\"\""
k_type:         .asciz "type"
k_sid:          .asciz "session_id"
k_message:      .asciz "message"
k_content:      .asciz "content"
k_text:         .asciz "text"
k_name:         .asciz "name"
k_input:        .asciz "input"
k_result:       .asciz "result"
k_iserror:      .asciz "is_error"
k_isError:      .asciz "isError"
k_subtype:      .asciz "subtype"
k_error:        .asciz "error"
k_choices:      .asciz "choices"
k_tool_calls:   .asciz "tool_calls"
k_id:           .asciz "id"
k_function:     .asciz "function"
k_arguments:    .asciz "arguments"
k_tools:        .asciz "tools"
k_description:  .asciz "description"
k_schema:       .asciz "inputSchema"
k_data:         .asciz "data"
v_system:       .asciz "system"
v_assistant:    .asciz "assistant"
v_user:         .asciz "user"
v_text:         .asciz "text"
v_tool_use:     .asciz "tool_use"
v_tool_result:  .asciz "tool_result"
v_success:      .asciz "success"
v_maxturns:     .asciz "error_max_turns"
s_maxturns1:    .asciz "Stopped after "
s_maxturns2:    .asciz " turns (Preferences > AI > Turns at most). Type continue to go on from where it stopped."
s_op_pfx:       .asciz "op_"
s_run_op:       .asciz "run_operator"
s_agent:        .asciz "Agent: "
# messages
s_busy:         .asciz "  the AI is still working (Stop ends it)"
s_stopped:      .asciz "Stopped."
s_not_found_a:  .asciz " was not found: install it, or set its program in Preferences > AI."
s_no_start:     .asciz "The program could not be started."
s_no_mcp:       .asciz "BeeModel's MCP server is off (Preferences > AI): Claude Code and Grok reach the scene through it."
s_ended_a:      .asciz " ended with exit code "
s_no_key:       .asciz "No OpenRouter key: set it in Preferences > AI (or OPENROUTER_API_KEY)."
s_no_curl:      .asciz "OpenRouter needs the curl program (it is not on PATH)."
s_or_fail:      .asciz "The request to OpenRouter failed: "
s_or_bad:       .asciz "OpenRouter's reply was not understood: "
s_or_none:      .asciz "OpenRouter gave no answer."
s_or_err:       .asciz "OpenRouter: "
s_ol_fail:      .asciz "The request to Ollama failed (is it running? ollama serve): "
s_ol_bad:       .asciz "Ollama's reply was not understood: "
s_ol_none:      .asciz "Ollama gave no answer."
s_ol_err:       .asciz "Ollama: "
j_noreason:     .asciz ",\"reasoning_effort\":\"none\""
s_steps_a:      .asciz "Stopped after "
s_steps_b:      .asciz " steps (the limit is in Preferences > AI)."
s_hint:         .asciz "Describe a world, a model or a change, and press Enter. The AI builds it in the scene; each request is one undo step."
s_prompt_hint:  .asciz "Describe what to build..."
s_working:      .asciz "Working with "
s_dots:         .asciz "...  (Stop ends it)"
s_indent:       .asciz "               "    # (15)
s_too_long:     .asciz "  (a message too long to show, such as an image, was left out)"
s_nothing_rev:  .asciz "  nothing of the AI's to revert"
s_copied:       .asciz "  the AI conversation is on the clipboard"
s_nothing_copy: .asciz "  the AI conversation is empty"
n_claude:       .asciz "Claude Code"
n_grok:         .asciz "Grok"
n_or:           .asciz "OpenRouter"
n_ol:           .asciz "Ollama"
s_test_none:    .asciz ": not found (install it, or set its program in Preferences > AI)"
s_test_ok_key:  .asciz "  OpenRouter: the key works"
s_test_bad:     .asciz "  OpenRouter: "
s_test_bad_ol:  .asciz "  Ollama: "
s_test_ok_ol:   .asciz "  Ollama: it answers and has the model"
s_test_nomodel: .asciz "it answers, but has no model named "
s_test_noans:   .asciz "no answer (check the address)"
s_colon:        .asciz ": "
s_sp2:          .asciz "  "
s_tr_head:      .asciz "$ ai: "
s_tr_idle:      .asciz "idle "
s_tr_busy:      .asciz "busy "
s_tr_kinds:     .ascii "?YATERN"
.align 8
prov_names:     .quad n_claude, n_grok, n_or, n_ol

# -----------------------------------------------------------------------------
# The world-building instructions (also MCP's prompt build_world)
# -----------------------------------------------------------------------------
s_world:
    .ascii "You are the AI inside BeeModel, a 3D modeler, renderer and CAD program. You build what the user describes directly in the open scene with BeeModel's tools while they watch the viewport.\n"
    .ascii "Conventions: meters; Y is up; the ground is the XZ plane at y = 0; rotation_deg is Euler XYZ in degrees (BeeScript's rotate takes radians: write 45deg).\n"
    .ascii "Work like this:\n"
    .ascii "1. Look first: scene_summary (and viewport_capture when it matters).\n"
    .ascii "2. Plan briefly: the parts, their sizes and places. A new scene holds a placeholder Cube (2 m, at the origin): when you build something new and the request does not mention the cube, delete(\"Cube\") first and say so. Never build into objects that stay: put new things beside them.\n"
    .ascii "3. Build in batches with script_eval (BeeScript), many objects a call: add(type, name, x, y, z) with cube, sphere, cylinder, cone, torus, plane, grid, light or camera; scale(n, x, y, z); rotate(n, rx, ry, rz); move(n, x, y, z); for i in 0..10 { ... } loops; fn name(a, b) { ... } helpers. There are no lists or arrays ([...]): write each call, or loop over numbers. Materials: m = material(\"Stone\"); matset(m, \"base\", 0.5, 0.5, 0.48); matset(m, \"roughness\", 0.8); assign(object, m); a preset look: m = material(\"Planks\"); op(\"material.preset\", \"wood Planks\") (gold silver copper chrome aluminium plastic rubber glass frosted_glass water ceramic car_paint skin clay emissive wood marble concrete fabric leather). add returns the name it gave (Cube.001 when Cube is taken): keep it.\n"
    .ascii "4. Terrain and many copies with geometry nodes: t = gtree(\"Land\"); n = gnode(t, \"terrain\", 60, 128, 6, 1) (size, resolution, height, seed); o = gnode(t, \"output\"); glink(t, n, o, 1); add(\"plane\", \"Ground\"); k = modifier(\"Ground\", \"geometry\"); modset(\"Ground\", k, \"tree\", t). The distribute and instance nodes scatter objects; lsystem nodes grow plants (node_types lists them all).\n"
    .ascii "Text (titles, signs, labels, counters) is real geometry: op(\"text.add\", \"'Hello world' size 0.5 depth 0.1\"); t = active(); move(t, 0, 1, 0). It stands in the XY plane read from +Z, the last line's baseline at its origin, centred (\\n starts a line). Change it: text_set(t, \"New words\") or, on the active text, op(\"text.set\", \"'New words' font 'DejaVu Serif Bold' bevel 0.01 align left\"); text(t) reads it, scene_summary shows it. Type it on letter by letter: op(\"anim.key\", \"text:Name:reveal 1 0\") and (\"text:Name:reveal 48 1\") (mode pop, scale, rise or drop); {frame} or {floor(time)} in the body counts.\n"
    .ascii "5. Light and camera: add(\"light\", \"Sun\", 4, 8, 3) then op(\"light.set\", \"power 3\"); c = add(\"camera\", \"Shot\", 0, 2, 12), aim it with rotate(c, -10deg, 0, 0), then op(\"camera.set\", \"active\") (the new object is the active one). With an HDRI image loaded (image(path)), op(\"world.hdri\", name) and op(\"world.strength\", 1.5) light the world.\n"
    .ascii "6. Check: viewport_capture, then fix what is wrong. Keep to a few thousand objects; use instances and node trees for many copies.\n"
    .ascii "Each request of the user is one undo step they can revert in one click. Answer briefly: what you built and what they could ask for next.\0"
s_world_extra:  .asciz "\n\nThe user also asks: "
s_world_grok:   .ascii "\nYour BeeModel tools come from the MCP server named beemodel. Always call them by their full names: beemodel__scene_summary, beemodel__script_eval, beemodel__viewport_capture, beemodel__run_operator and so on (the names above are short for these; with use_tool, pass the full name). "
                .asciz "A tool call that fails says why in its error: read it and correct the call. It does not mean BeeModel disconnected, so never stop or tell the user it is disconnected because of one; try again with the right name or values.\n"
j_wp_a:         .asciz "{\"description\":\"Build a world\",\"messages\":[{\"role\":\"user\",\"content\":{\"type\":\"text\",\"text\":"
j_wp_b:         .asciz "}}]}"
s_wp_goal:      .asciz "\n\nWhat to build: "

# ---- widgets and operators ---------------------------------------------------
WIDGET wd_ai_prov, WK_ENUM, "ai.connection", cb=ai_prov_cb, aux=l_ai_prov, n=4, tip="The connection this conversation uses (set them up in Preferences > AI)"
WIDGET wd_ai_new, WK_BUTTON, "ai.new", "New", flags=WGF_COMPACT, tip="Start a new conversation (the scene stays as it is)"
WIDGET wd_ai_revert, WK_BUTTON, "ai.revert", "Revert", flags=WGF_COMPACT, tip="Undo the AI's last request (one step)"
WIDGET wd_ai_copy, WK_BUTTON, "ai.copy", "Copy", flags=WGF_COMPACT, tip="Copy the text selected in the conversation (drag over it, double-click: a whole message), or all of it"
WIDGET wd_ai_text, WK_PAD, "ai.text", cb=ai_pad_cb, tip="Drag to select text, double-click a message, Ctrl+C copies it", sect=.data
WIDGET wd_ai_scroll, WK_SCROLL, "ai.transcript"
WIDGET wd_ai_prompt, WK_TEXT, "ai.prompt", "Prompt", flags=WGF_MULTI, cb=ai_prompt_cb, tip="What to build or change. Enter sends it, Shift+Enter starts a new line", sect=.data
WIDGET wd_ai_send, WK_BUTTON, "ai.send", "Send", flags=WGF_PRIMARY, tip="Send the prompt (Enter)"
WIDGET wd_ai_stop, WK_BUTTON, "ai.stop", "Stop", tip="Stop the AI (what it did so far stays, as one undo step)"

.section .rodata
.align 8
l_ai_prov:      .quad n_claude, n_grok, n_or, n_ol

OPERATOR op_ai_send, "ai.send", "Send to the AI", do_ai_send, flags=OPF_QUIET, doc="Send a prompt to the AI Assistant: ai.send <what to build>"
OPERATOR op_ai_stop, "ai.stop", "Stop the AI", do_ai_stop, flags=OPF_QUIET, doc="Stop the AI Assistant's request"
OPERATOR op_ai_new, "ai.new", "New AI Conversation", do_ai_new, flags=OPF_QUIET, doc="Start a new conversation with the AI Assistant"
OPERATOR op_ai_copy, "ai.copy", "Copy AI Conversation", do_ai_copy, flags=OPF_QUIET, doc="Copy the AI Assistant's conversation, as shown, to the clipboard"
OPERATOR op_ai_revert, "ai.revert", "Revert AI Request", do_ai_revert, flags=OPF_QUIET, doc="Undo the AI Assistant's last request (one step)"
OPERATOR op_ai_mode, "ai.mode", "AI Assistant", do_ai_mode, key=KEY_SPACE|KM_CTRL|KM_SHIFT, flags=OPF_QUIET, doc="Go to the AI Assistant's prompt (the AI workspace when none is shown; Ctrl+Shift+Space)"
OPERATOR op_ai_transcript, "ai.transcript", "AI Transcript", do_ai_transcript, flags=OPF_QUIET|OPF_AI_SAFE, doc="Print the AI Assistant's conversation (its last 24 lines) to the console: Y you, A the AI, T a tool call, R its result, E an error, N a note"
OPERATOR op_ai_test, "ai.test", "Test AI Connection", do_ai_test, flags=OPF_QUIET, doc="Check a connection: ai.test <0 Claude Code | 1 Grok | 2 OpenRouter>"

.text
# =============================================================================
# The transcript
# =============================================================================
# ai_add(edi=kind, rsi=prefix or 0, rdx=text, ecx=bytes at most (-1: all))
#   - one entry a line (empty lines skipped); the first line gets the prefix,
#   the others as many spaces
ai_add:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    mov     r12d, edi
    mov     r13, rsi
    mov     rbx, rdx
    mov     r14d, ecx
    mov     qword ptr [rip+ai_indent], 0
    test    rsi, rsi
    jz      .Lad_line
    mov     rdi, rsi
    call    str_len
    cmp     eax, 15
    jbe     1f
    mov     eax, 15
1:  lea     rcx, [rip+s_indent+15]
    sub     rcx, rax
    mov     [rip+ai_indent], rcx
    test    rbx, rbx
    jz      .Lad_done
.Lad_line:
    test    r14d, r14d
    jz      .Lad_done
    cmp     byte ptr [rbx], 0
    je      .Lad_done
    xor     r15d, r15d                  # the line: [rbx, rbx + r15)
1:  cmp     r15d, r14d
    jae     2f
    mov     al, [rbx+r15]
    test    al, al
    jz      2f
    cmp     al, 10
    je      2f
    inc     r15d
    jmp     1b
2:  test    r15d, r15d
    jnz     3f
    test    r13, r13
    jz      .Lad_next
3:  mov     edi, r15d                   # room: kind, prefix, text (2000 at
    add     edi, 40                     #  most), 0
    call    ai_room
    mov     ecx, [rip+ai_tx_len]
    lea     rdi, [rip+ai_tx]
    add     rdi, rcx
    mov     [rdi], r12b
    inc     rdi
    mov     rsi, r13
    test    r13, r13
    jnz     31f
    mov     rsi, [rip+ai_indent]        # (a later line)
    test    rsi, rsi
    jz      4f
31: call    ai_cpy
4:  xor     ecx, ecx
5:  cmp     ecx, r15d
    jae     6f
    cmp     ecx, 2000
    jae     6f
    mov     al, [rbx+rcx]
    cmp     al, 13
    je      51f
    cmp     al, 9
    jne     52f
51: mov     al, ' '
52: mov     [rdi], al
    inc     rdi
    inc     ecx
    jmp     5b
6:  mov     byte ptr [rdi], 0
    inc     rdi
    lea     rax, [rip+ai_tx]
    sub     rdi, rax
    mov     [rip+ai_tx_len], edi
    xor     r13d, r13d
.Lad_next:
    add     rbx, r15
    sub     r14d, r15d
    cmp     byte ptr [rbx], 10
    jne     .Lad_line
    inc     rbx
    dec     r14d
    jmp     .Lad_line
.Lad_done:
    mov     dword ptr [rip+ai_stick], 1
    mov     dword ptr [rip+dirty], 1
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# ai_add_z(edi=kind, rsi=asciz) - a short note
ai_add_z:
    mov     rdx, rsi
    xor     esi, esi
    mov     ecx, -1
    jmp     ai_add

# ai_room(edi=bytes) - make room in the transcript (the oldest half goes)
ai_room:
    mov     eax, [rip+ai_tx_len]
    add     eax, edi
    cmp     eax, TX_CAP
    jb      9f
    mov     dword ptr [rip+ai_sel_a], 0 # (the text moves: no selection)
    mov     dword ptr [rip+ai_sel_b], 0
    lea     rsi, [rip+ai_tx]            # the first entry past half
    mov     ecx, TX_CAP/2
1:  cmp     ecx, [rip+ai_tx_len]
    jae     2f
    cmp     byte ptr [rsi+rcx-1], 0
    je      2f
    inc     ecx
    jmp     1b
2:  mov     edx, [rip+ai_tx_len]
    sub     edx, ecx
    jbe     3f
    sub     [rip+ai_req_off], ecx       # (the request's start moves too)
    jns     21f
    mov     dword ptr [rip+ai_req_off], 0
21: lea     rdi, [rip+ai_tx]
    add     rsi, rcx
    mov     ecx, edx
    rep     movsb
    mov     [rip+ai_tx_len], edx
    ret
3:  mov     dword ptr [rip+ai_tx_len], 0
    mov     dword ptr [rip+ai_req_off], 0
9:  ret

# ai_answer -> rax = the last request's answer: the first line of the AI's
#   last message, or its last error (edx = 1), or 0
ai_answer:
    lea     r8, [rip+ai_tx]
    mov     ecx, [rip+ai_req_off]
    xor     eax, eax                    # the answer so far
    xor     edx, edx
    xor     r9d, r9d                    # the entry before's kind
1:  cmp     ecx, [rip+ai_tx_len]
    jae     9f
    movzx   r10d, byte ptr [r8+rcx]     # an entry: kind, text, 0
    lea     r11, [r8+rcx+1]
    cmp     r10d, K_ERR
    jne     2f
    mov     rax, r11
    mov     edx, 1
    jmp     4f
2:  cmp     r10d, K_AI                  # a message's first line
    jne     4f
    cmp     r9d, K_AI
    je      4f
    cmp     edx, 1                      # (an error stays the answer)
    je      4f
    mov     rax, r11
4:  mov     r9d, r10d
5:  inc     ecx                         # to the next entry
    cmp     byte ptr [r8+rcx], 0
    jne     5b
    inc     ecx
    jmp     1b
9:  ret

# ai_cpy(rdi=dest, rsi=text) -> rdi at its 0
ai_cpy:
1:  mov     al, [rsi]
    mov     [rdi], al
    test    al, al
    jz      2f
    inc     rsi
    inc     rdi
    jmp     1b
2:  ret

# ai_add_tool(rdi=name, rsi=arguments (JSON), edx=their length)
#   - "  name {arguments}", BeeModel's MCP prefix taken off the name
ai_add_tool:
    push    rbx
    push    r12
    push    r13
    mov     rbx, rdi
    mov     r12, rsi
    mov     r13d, edx
    mov     rdi, rbx
    lea     rsi, [rip+s_strip]
    call    prefix
    test    eax, eax
    jz      1f
    add     rbx, 15
1:  lea     rdi, [rip+ai_tmp]           # name, a space, 200 of the arguments
    lea     rsi, [rip+s_tool_pfx]
    call    ai_cpy
    mov     rsi, rbx
    call    ai_cpy
    mov     byte ptr [rdi], ' '
    inc     rdi
    xor     ecx, ecx
2:  cmp     ecx, r13d
    jae     4f
    cmp     ecx, 200
    jae     3f
    mov     al, [r12+rcx]
    cmp     al, 10
    jne     21f
    mov     al, ' '
21: mov     [rdi+rcx], al
    inc     ecx
    jmp     2b
3:  mov     dword ptr [rdi+rcx], 0x2e2e2e    # "..."
    add     ecx, 3
4:  mov     byte ptr [rdi+rcx], 0
    mov     edi, K_TOOL
    lea     rsi, [rip+ai_tmp]
    call    ai_add_z
    pop     r13
    pop     r12
    pop     rbx
    ret

# =============================================================================
# A request
# =============================================================================
# ai_send(rdi=prompt) - to the connection chosen (ai_prov)
ai_send:
    mov     rsi, rdi
    xor     edx, edx
# ai_send_as(rdi=prompt shown, rsi=text sent, rdx=a note after it or 0) - the
#   same, with more sent than the transcript shows (Ask AI: the selection)
ai_send_as:
    push    rbx
    push    r12
    push    r13
    mov     rbx, rdi
    mov     r12, rsi
    mov     r13, rdx
    test    rbx, rbx
    jz      9f
1:  movzx   eax, byte ptr [rbx]         # (leading spaces, line breaks)
    test    eax, eax
    jz      2f
    cmp     eax, ' '
    ja      2f
    inc     rbx
    jmp     1b
2:  cmp     byte ptr [rbx], 0
    je      9f
1:  movzx   eax, byte ptr [r12]
    test    eax, eax
    jz      2f
    cmp     eax, ' '
    ja      2f
    inc     r12
    jmp     1b
2:  cmp     dword ptr [rip+ai_busy], 0
    jne     .Lsd_busy
    call    ai_proc_running             # (a test)
    test    eax, eax
    jnz     .Lsd_busy
    mov     edi, K_YOU
    lea     rsi, [rip+s_you]
    mov     rdx, rbx
    mov     ecx, -1
    call    ai_add
    mov     eax, [rip+ai_tx_len]
    mov     [rip+ai_req_off], eax
    test    r13, r13
    jz      21f
    mov     edi, K_NOTE
    mov     rsi, r13
    call    ai_add_z
21:
    lea     rdi, [rip+ai_label]         # one undo step: "Agent: <the prompt>"
    lea     rsi, [rip+s_agent]
    call    ai_cpy
    xor     ecx, ecx
3:  mov     al, [rbx+rcx]
    test    al, al
    jz      4f
    cmp     ecx, 60
    jae     4f
    cmp     al, ' '                     # (one line)
    jae     31f
    mov     al, ' '
31: mov     [rdi+rcx], al
    inc     ecx
    jmp     3b
4:  mov     byte ptr [rdi+rcx], 0
    lea     rdi, [rip+ai_label]
    call    undo_group_begin
    mov     dword ptr [rip+ai_grouped], 1
    mov     dword ptr [rip+ai_busy], 1
    mov     dword ptr [rip+ai_stopped], 0
    mov     dword ptr [rip+dirty], 1
    mov     eax, [rip+ai_prov]
    cmp     eax, 3
    jbe     5f
    xor     eax, eax
5:  xor     ecx, ecx                    # Ollama: OpenRouter's way, to the
    cmp     eax, 3                      #  local server
    jne     51f
    mov     ecx, 1
    mov     eax, 2
51: mov     [rip+ai_local], ecx
    mov     [rip+ai_run], eax
    mov     edi, eax                    # (Grok: its tools' full names too)
    call    ai_sys_for
    mov     edi, [rip+ai_run]
    cmp     edi, 2
    je      6f
    mov     rsi, r12
    call    ai_cli_start
    jmp     7f
6:  mov     rdi, r12
    call    ai_or_start
7:  test    eax, eax
    jnz     9f
    call    ai_finish                   # (it did not start)
    jmp     9f
.Lsd_busy:
    lea     rdi, [rip+s_busy]
    call    log_line
9:  pop     r13
    pop     r12
    pop     rbx
    ret

# ai_finish - the request is over: its undo step closed (and, from Ask AI,
#   checked for changes outside the selection)
ai_finish:
    sub     rsp, 8
    cmp     dword ptr [rip+ai_grouped], 0
    je      1f
    mov     dword ptr [rip+ai_grouped], 0
    call    undo_group_end
1:  mov     dword ptr [rip+ai_busy], 0
    mov     dword ptr [rip+dirty], 1
    call    ask_done
    add     rsp, 8
    ret

# ai_note(rdi=text) - a note in the transcript (Ask AI's)
ai_note:
    mov     rsi, rdi
    mov     edi, K_NOTE
    jmp     ai_add_z

# ai_sys_for(edi=provider) - ai_sys for that agent: Grok calls MCP tools by
#   their server-qualified names, and must not take a failed call for a
#   lost connection
ai_sys_for:
    cmp     edi, 1
    jne     ai_sys_make
    sub     rsp, 8
    lea     rdi, [rip+ai_sys]
    lea     rsi, [rip+s_world]
    call    ai_cpy
    lea     rsi, [rip+s_world_grok]
    call    ai_cpy
    jmp     1f
# ai_sys_make - ai_sys = the world instructions + the user's addition
ai_sys_make:
    sub     rsp, 8
    lea     rdi, [rip+ai_sys]
    lea     rsi, [rip+s_world]
    call    ai_cpy
1:
    cmp     byte ptr [rip+ai_extra], 0
    je      1f
    lea     rsi, [rip+s_world_extra]
    call    ai_cpy
    lea     rsi, [rip+ai_extra]
    call    ai_cpy
1:  add     rsp, 8
    ret

# ai_world_get(rsi=goal or 0) - MCP prompts/get build_world (into wb)
ai_world_get:
    push    rbx
    mov     rbx, rsi
    call    ai_sys_make
    test    rbx, rbx
    jz      1f
    cmp     byte ptr [rbx], 0
    je      1f
    lea     rdi, [rip+ai_sys]
    call    str_len
    lea     rdi, [rip+ai_sys]
    add     rdi, rax
    lea     rsi, [rip+s_wp_goal]
    call    ai_cpy
    mov     rsi, rbx
    call    ai_cpy
1:  lea     rsi, [rip+j_wp_a]
    call    wb_str
    lea     rsi, [rip+ai_sys]
    call    jb_q
    lea     rsi, [rip+j_wp_b]
    call    wb_str
    pop     rbx
    ret

# ai_prog(edi=0 Claude Code / 1 Grok) -> rax = the program's path (ai_path),
#   or 0 (a message in the transcript or the console: esi = 1 transcript)
ai_prog:
    push    rbx
    push    r12
    sub     rsp, 8
    mov     ebx, edi
    mov     r12d, esi
    lea     rdi, [rip+ai_cl_path]
    lea     rax, [rip+s_claude]
    test    ebx, ebx
    jz      1f
    lea     rdi, [rip+ai_gk_path]
    lea     rax, [rip+s_grok]
1:  cmp     byte ptr [rdi], 0
    jne     2f
    mov     rdi, rax
2:  call    ai_which
    test    rax, rax
    jz      3f
    lea     rdi, [rip+ai_path]
    mov     rsi, rax
    call    ai_cpy
    lea     rax, [rip+ai_path]
    jmp     9f
3:  call    fmt_reset                   # "<name> was not found..."
    lea     rcx, [rip+prov_names]
    mov     rdi, [rcx+rbx*8]
    test    r12d, r12d
    jnz     4f
    push    rdi
    push    rdi
    lea     rdi, [rip+s_sp2]
    call    fmt_str
    pop     rdi
    pop     rdi
    call    fmt_str
    lea     rdi, [rip+s_test_none]
    call    fmt_str
    lea     rdi, [rip+fmt_buf]
    call    ai_test_say
    xor     eax, eax
    jmp     9f
4:  call    fmt_str
    lea     rdi, [rip+s_not_found_a]
    call    fmt_str
    mov     edi, K_ERR
    lea     rsi, [rip+fmt_buf]
    call    ai_add_z
    xor     eax, eax
9:  add     rsp, 8
    pop     r12
    pop     rbx
    ret

# =============================================================================
# Claude Code and the Grok CLI
# =============================================================================
# ai_cli_start(edi=0 Claude Code / 1 Grok, rsi=prompt) -> eax = 1 started
ai_cli_start:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    mov     ebx, edi
    mov     r12, rsi
    call    mcp_listening
    test    eax, eax
    jnz     1f
    mov     edi, K_ERR
    lea     rsi, [rip+s_no_mcp]
    call    ai_add_z
    xor     eax, eax
    jmp     .Lcs_out
1:  mov     edi, ebx
    mov     esi, 1
    call    ai_prog
    test    rax, rax
    jz      .Lcs_out
    call    ai_dir_make
    mov     edi, ebx
    call    ai_cfg_write
    lea     r13, [rip+ap_argv_ai]       # the arguments
    xor     r14d, r14d
    lea     rax, [rip+ai_path]
    call    .Larg
    mov     eax, [rip+ai_cl_turns]
    test    ebx, ebx
    jz      2f
    mov     eax, [rip+ai_gk_turns]
2:  push    rax
    push    rax
    call    fmt_reset
    pop     rdi
    pop     rdi
    call    fmt_int
    lea     rdi, [rip+ai_turns]
    lea     rsi, [rip+fmt_buf]
    call    ai_cpy
    test    ebx, ebx
    jnz     .Lcs_grok
    lea     rax, [rip+a_p]              # claude -p <prompt> --output-format
    call    .Larg                       #  stream-json --verbose --mcp-config
    mov     rax, r12                    #  <file> --strict-mcp-config
    call    .Larg                       #  --allowedTools mcp__beemodel
    lea     rax, [rip+a_ofmt]           #  --max-turns N --append-system-
    call    .Larg                       #  prompt <instructions> [--model M]
    lea     rax, [rip+a_sjson]          #  [--resume <session>]
    call    .Larg
    lea     rax, [rip+a_verbose]
    call    .Larg
    lea     rax, [rip+a_mcpcfg]
    call    .Larg
    lea     rax, [rip+ai_cfg]
    call    .Larg
    lea     rax, [rip+a_strict]
    call    .Larg
    lea     rax, [rip+a_allowed]
    call    .Larg
    lea     rax, [rip+a_mcpbee]
    call    .Larg
    lea     rax, [rip+a_maxturns]
    call    .Larg
    lea     rax, [rip+ai_turns]
    call    .Larg
    lea     rax, [rip+a_append]
    call    .Larg
    lea     rax, [rip+ai_sys]
    call    .Larg
    cmp     byte ptr [rip+ai_cl_model], 0
    je      3f
    lea     rax, [rip+a_model]
    call    .Larg
    lea     rax, [rip+ai_cl_model]
    call    .Larg
3:  lea     r15, [rip+a_resume]
    jmp     .Lcs_resume
.Lcs_grok:
    lea     rax, [rip+a_cwd]            # grok --cwd <dir> -p <prompt>
    call    .Larg                       #  --output-format streaming-messages-
    lea     rax, [rip+ai_dir]           #  json --always-approve --trust
    call    .Larg                       #  --disable-web-search --disallowed-
                                        #  tools ... (no shell, no files)
    lea     rax, [rip+a_p]              #  --max-turns N --rules <instructions>
    call    .Larg                       #  [-m M] [-r <session>]
    mov     rax, r12
    call    .Larg
    lea     rax, [rip+a_ofmt]
    call    .Larg
    lea     rax, [rip+a_smjson]
    call    .Larg
    lea     rax, [rip+a_approve]
    call    .Larg
    lea     rax, [rip+a_trust]
    call    .Larg
    lea     rax, [rip+a_noweb]
    call    .Larg
    lea     rax, [rip+a_notools]
    call    .Larg
    lea     rax, [rip+a_gk_deny]
    call    .Larg
    lea     rax, [rip+a_maxturns]
    call    .Larg
    lea     rax, [rip+ai_turns]
    call    .Larg
    lea     rax, [rip+a_rules]
    call    .Larg
    lea     rax, [rip+ai_sys]
    call    .Larg
    cmp     byte ptr [rip+ai_gk_model], 0
    je      4f
    lea     rax, [rip+a_m]
    call    .Larg
    lea     rax, [rip+ai_gk_model]
    call    .Larg
4:  lea     r15, [rip+a_r]
.Lcs_resume:                            # a follow-up: the same session
    cmp     byte ptr [rip+ai_sid], 0
    je      5f
    lea     eax, [rbx+1]
    cmp     eax, [rip+ai_sid_prov]
    jne     5f
    mov     rax, r15
    call    .Larg
    lea     rax, [rip+ai_sid]
    call    .Larg
5:  mov     qword ptr [r13+r14*8], 0
    mov     qword ptr [rip+ai_line_len], 0
    mov     dword ptr [rip+ai_line_skip], 0
    lea     rax, [rip+ai_cli_data]
    mov     [rip+ai_on_data], rax
    lea     rax, [rip+ai_cli_exit]
    mov     [rip+ai_on_exit], rax
    lea     rdi, [rip+ai_path]
    mov     rsi, r13
    xor     edx, edx
    lea     rcx, [rip+ai_dir]
    call    ai_proc_spawn
    test    eax, eax
    jnz     .Lcs_out
    mov     edi, K_ERR
    lea     rsi, [rip+s_no_start]
    call    ai_add_z
    xor     eax, eax
.Lcs_out:
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret
.Larg:                                  # rax = the next argument
    mov     [r13+r14*8], rax
    inc     r14d
    ret

# ai_cfg_write(edi=0 Claude Code / 1 Grok) - its MCP configuration: the
#   bridge (this program) for this instance's socket (ai_cfg = the file)
ai_cfg_write:
    push    rbx
    push    r12
    sub     rsp, 8
    mov     ebx, edi
    lea     rdi, [rip+ai_cfg]
    lea     rsi, [rip+ai_dir]
    call    ai_cpy
    mov     r12, rdi
    test    ebx, ebx
    jz      1f
    lea     rsi, [rip+s_grokdir]        # <dir>/.grok/config.toml
    call    ai_cpy
    lea     rdi, [rip+ai_cfg]
    call    ensure_dir
    mov     rdi, r12
    lea     rsi, [rip+s_groktoml]
    call    ai_cpy
    jmp     2f
1:  lea     rsi, [rip+s_mcpjson]        # <dir>/mcp.json
    call    ai_cpy
2:  lea     rdi, [rip+ai_req_st]
    call    buf_swap
    call    wb_reset
    lea     rsi, [rip+j_mcp_a]
    test    ebx, ebx
    jz      3f
    lea     rsi, [rip+t_grok_a]
3:  call    wb_str
    lea     rsi, [rip+ai_exe]
    call    jb_q
    lea     rsi, [rip+j_mcp_b]
    test    ebx, ebx
    jz      4f
    lea     rsi, [rip+t_grok_b]
4:  call    wb_str
    lea     rsi, [rip+sock_path]
    call    jb_q
    test    ebx, ebx
    jnz     5f
    lea     rsi, [rip+j_mcp_c]
    call    wb_str
    jmp     6f
5:  mov     edi, 10
    call    wb_char
6:  lea     rdi, [rip+ai_cfg]
    mov     rsi, [rip+wb_ptr]
    mov     rdx, [rip+wb_len]
    call    file_write_private
    lea     rdi, [rip+ai_req_st]
    call    buf_swap
    add     rsp, 8
    pop     r12
    pop     rbx
    ret

# ai_cli_data(rdi=bytes, esi=count) - the child's output: each whole line
#   (a line longer than the buffer, such as an image's data, is skipped
#   whole, with a note)
ai_cli_data:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    mov     r14, rdi                    # what is left of the bytes
    mov     r15d, esi
.Lcd_fill:
    mov     ecx, r15d                   # as much as fits
    mov     rax, [rip+ai_line_len]
    mov     edx, LINE_CAP-1
    sub     rdx, rax
    cmp     rcx, rdx
    jbe     1f
    mov     rcx, rdx
1:  sub     r15d, ecx
    lea     rdi, [rip+ai_line]
    add     rdi, rax
    add     [rip+ai_line_len], rcx
    mov     rsi, r14
    rep     movsb
    mov     r14, rsi
2:  lea     rbx, [rip+ai_line]          # whole lines
    mov     r12, [rip+ai_line_len]
    xor     r13d, r13d
3:  cmp     r13, r12
    jae     6f
    cmp     byte ptr [rbx+r13], 10
    je      4f
    inc     r13
    jmp     3b
4:  mov     byte ptr [rbx+r13], 0
    cmp     dword ptr [rip+ai_line_skip], 0
    je      41f
    mov     dword ptr [rip+ai_line_skip], 0     # (the end of a skipped one)
    jmp     5f
41: mov     rdi, rbx
    mov     rsi, r13
    call    ai_cli_line
5:  lea     rsi, [rbx+r13+1]            # the rest moves up
    mov     rcx, r12
    sub     rcx, r13
    dec     rcx
    mov     [rip+ai_line_len], rcx
    mov     rdi, rbx
    rep     movsb
    jmp     2b
6:  cmp     r12, LINE_CAP-1             # a line too long for the buffer
    jb      7f
    mov     qword ptr [rip+ai_line_len], 0
    cmp     dword ptr [rip+ai_line_skip], 0
    jne     7f
    mov     dword ptr [rip+ai_line_skip], 1
    mov     edi, K_NOTE
    lea     rsi, [rip+s_too_long]
    mov     rdx, rsi
    xor     esi, esi
    mov     ecx, -1
    call    ai_add
7:  test    r15d, r15d
    jnz     .Lcd_fill
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# ai_cli_exit(edi=exit code) - the CLI is done
ai_cli_exit:
    push    rbx
    mov     ebx, edi
    mov     rsi, [rip+ai_line_len]      # a last line without its newline
    test    rsi, rsi
    jz      1f
    cmp     dword ptr [rip+ai_line_skip], 0     # (not the end of a skipped one)
    jne     11f
    lea     rdi, [rip+ai_line]
    mov     byte ptr [rdi+rsi], 0
    call    ai_cli_line
11: mov     qword ptr [rip+ai_line_len], 0
    mov     dword ptr [rip+ai_line_skip], 0
1:  cmp     dword ptr [rip+ai_run], 3
    je      .Lce_test
    cmp     dword ptr [rip+ai_stopped], 0
    je      2f
    mov     edi, K_NOTE
    lea     rsi, [rip+s_stopped]
    call    ai_add_z
    jmp     8f
2:  test    ebx, ebx
    jz      8f
    call    fmt_reset                   # "<name> ended with exit code N"
    mov     eax, [rip+ai_run]
    lea     rcx, [rip+prov_names]
    mov     rdi, [rcx+rax*8]
    call    fmt_str
    lea     rdi, [rip+s_ended_a]
    call    fmt_str
    mov     edi, ebx
    call    fmt_int
    mov     edi, K_ERR
    lea     rsi, [rip+fmt_buf]
    call    ai_add_z
8:  call    ai_finish
    pop     rbx
    ret
.Lce_test:
    mov     edi, ebx
    call    ai_test_exit
    pop     rbx
    ret

# ai_cli_line(rdi=line (0-ended), rsi=length) - one event of the stream:
#   system (the session), assistant (text, tool use), user (tool results),
#   result (the end, errors); other text is shown as it is
ai_cli_line:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    mov     rbx, rdi
    lea     r12, [rdi+rsi]
    mov     [rip+j_end], r12
    cmp     dword ptr [rip+ai_run], 3   # a test: the reply is kept whole
    je      .Lcl_keep
    mov     rsi, rbx
    call    j_ws
    cmp     byte ptr [rsi], '{'
    jne     .Lcl_raw
    mov     rbx, rsi
    mov     rdx, r12
    call    j_valid
    test    eax, eax
    jz      .Lcl_raw
    mov     [rip+j_end], r12
    mov     rsi, rbx
    lea     rdi, [rip+k_type]
    lea     rdx, [rip+ai_type]
    call    ai_field
    lea     rdi, [rip+ai_type]
    lea     rsi, [rip+v_system]
    call    str_eq
    test    eax, eax
    jnz     .Lcl_sid
    lea     rdi, [rip+ai_type]
    lea     rsi, [rip+v_assistant]
    call    str_eq
    test    eax, eax
    jnz     .Lcl_asst
    lea     rdi, [rip+ai_type]
    lea     rsi, [rip+v_user]
    call    str_eq
    test    eax, eax
    jnz     .Lcl_user
    lea     rdi, [rip+ai_type]
    lea     rsi, [rip+k_result]
    call    str_eq
    test    eax, eax
    jnz     .Lcl_result
    jmp     .Lcl_out                    # (other events: not shown)
.Lcl_raw:
    mov     edi, K_NOTE
    xor     esi, esi
    mov     rdx, rbx
    mov     rcx, r12
    sub     rcx, rbx
    call    ai_add
    jmp     .Lcl_out
.Lcl_keep:
    call    ai_or_data_line
    jmp     .Lcl_out
.Lcl_sid:
    call    .Lcl_take_sid
    jmp     .Lcl_out
.Lcl_asst:                              # message.content: text, tool_use
    mov     rsi, rbx
    lea     rdi, [rip+k_message]
    call    j_find
    test    rax, rax
    jz      .Lcl_out
    mov     rsi, rax
    lea     rdi, [rip+k_content]
    call    j_find
    test    rax, rax
    jz      .Lcl_out
    cmp     byte ptr [rax], '['
    jne     .Lcl_out
    mov     rsi, rax
    call    j_first
    mov     r13, rax
1:  test    r13, r13
    jz      .Lcl_out
    mov     rsi, r13
    lea     rdi, [rip+k_type]
    lea     rdx, [rip+ai_type]
    call    ai_field
    lea     rdi, [rip+ai_type]
    lea     rsi, [rip+v_text]
    call    str_eq
    test    eax, eax
    jz      2f
    mov     rsi, r13
    lea     rdi, [rip+k_text]
    call    ai_text
    test    eax, eax
    jle     3f
    mov     edi, K_AI
    lea     rsi, [rip+ai_tmp]
    call    ai_add_z
    jmp     3f
2:  lea     rdi, [rip+ai_type]
    lea     rsi, [rip+v_tool_use]
    call    str_eq
    test    eax, eax
    jz      3f
    mov     rsi, r13
    lea     rdi, [rip+k_name]
    lea     rdx, [rip+ai_name]
    call    ai_field
    mov     rsi, r13
    lea     rdi, [rip+k_input]
    call    j_find
    lea     rsi, [rip+j_empty_obj]
    mov     edx, 2
    test    rax, rax
    jz      21f
    mov     r14, rax
    mov     rsi, rax
    call    j_skip
    mov     rdx, rsi
    sub     rdx, r14
    mov     rsi, r14
21: lea     rdi, [rip+ai_name]
    call    ai_add_tool
3:  mov     rsi, r13
    call    j_next
    mov     r13, rax
    jmp     1b
.Lcl_user:                              # message.content: tool_result
    mov     rsi, rbx
    lea     rdi, [rip+k_message]
    call    j_find
    test    rax, rax
    jz      .Lcl_out
    mov     rsi, rax
    lea     rdi, [rip+k_content]
    call    j_find
    test    rax, rax
    jz      .Lcl_out
    cmp     byte ptr [rax], '['
    jne     .Lcl_out
    mov     rsi, rax
    call    j_first
    mov     r13, rax
4:  test    r13, r13
    jz      .Lcl_out
    mov     rsi, r13
    lea     rdi, [rip+k_type]
    lea     rdx, [rip+ai_type]
    call    ai_field
    lea     rdi, [rip+ai_type]
    lea     rsi, [rip+v_tool_result]
    call    str_eq
    test    eax, eax
    jz      6f
    mov     rsi, r13                    # its content: a text or [{text}]
    lea     rdi, [rip+k_content]
    call    j_find
    test    rax, rax
    jz      6f
    mov     r14, rax
    cmp     byte ptr [rax], '['
    jne     5f
    mov     rsi, rax
    call    j_first
    test    rax, rax
    jz      6f
    mov     rsi, rax
    lea     rdi, [rip+k_text]
    call    ai_text
    jmp     51f
5:  mov     rsi, r14
    lea     rdi, [rip+ai_tmp]
    mov     edx, TMP_CAP-1
    call    j_str
51: test    eax, eax
    jle     6f
    mov     r15d, K_RES
    mov     rsi, r13
    lea     rdi, [rip+k_iserror]
    call    j_find
    test    rax, rax
    jz      52f
    mov     rsi, rax
    call    j_bool
    test    eax, eax
    jz      52f
    mov     r15d, K_ERR
52: mov     edi, r15d
    lea     rsi, [rip+s_eq]
    lea     rdx, [rip+ai_tmp]
    mov     ecx, 160
    call    ai_add
6:  mov     rsi, r13
    call    j_next
    mov     r13, rax
    jmp     4b
.Lcl_result:                            # the end: the session; an error
    call    .Lcl_take_sid
    xor     r13d, r13d
    mov     rsi, rbx
    lea     rdi, [rip+k_iserror]
    call    j_find
    test    rax, rax
    jz      7f
    mov     rsi, rax
    call    j_bool
    mov     r13d, eax
7:  mov     rsi, rbx
    lea     rdi, [rip+k_subtype]
    lea     rdx, [rip+ai_type]
    call    ai_field
    cmp     byte ptr [rip+ai_type], 0
    je      71f
    lea     rdi, [rip+ai_type]
    lea     rsi, [rip+v_success]
    call    str_eq
    test    eax, eax
    jnz     71f
    mov     r13d, 1
71: test    r13d, r13d
    jz      .Lcl_out
    lea     rdi, [rip+ai_type]          # the turn limit: a note, and how to go
    lea     rsi, [rip+v_maxturns]       #  on (the session is kept: "continue"
    call    str_eq                      #  resumes it)
    test    eax, eax
    jz      73f
    call    fmt_reset
    lea     rdi, [rip+s_maxturns1]
    call    fmt_str
    lea     rdi, [rip+ai_turns]
    call    fmt_str
    lea     rdi, [rip+s_maxturns2]
    call    fmt_str
    mov     edi, K_NOTE
    lea     rsi, [rip+fmt_buf]
    call    ai_add_z
    jmp     .Lcl_out
73: mov     rsi, rbx
    lea     rdi, [rip+k_result]
    call    ai_text
    test    eax, eax
    jg      72f
    lea     rdi, [rip+ai_tmp]
    lea     rsi, [rip+ai_type]
    call    ai_cpy
72: mov     edi, K_ERR
    lea     rsi, [rip+ai_tmp]
    call    ai_add_z
.Lcl_out:
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret
.Lcl_take_sid:                          # session_id -> ai_sid (for --resume)
    sub     rsp, 8
    mov     rsi, rbx
    lea     rdi, [rip+k_sid]
    lea     rdx, [rip+ai_tmp]
    call    ai_field
    cmp     byte ptr [rip+ai_tmp], 0
    je      1f
    lea     rdi, [rip+ai_sid]
    lea     rsi, [rip+ai_tmp]
    mov     ecx, 120
2:  mov     al, [rsi]
    mov     [rdi], al
    test    al, al
    jz      3f
    inc     rsi
    inc     rdi
    dec     ecx
    jnz     2b
    mov     byte ptr [rdi], 0
3:  mov     eax, [rip+ai_run]
    inc     eax
    mov     [rip+ai_sid_prov], eax
1:  add     rsp, 8
    ret

# ai_field(rsi=object, rdi=key, rdx=dest (120 bytes)) - a short string
#   member, "" when it is missing or not a string
ai_field:
    push    rbx
    mov     rbx, rdx
    mov     byte ptr [rbx], 0
    call    j_find
    test    rax, rax
    jz      1f
    mov     rsi, rax
    mov     rdi, rbx
    mov     edx, 120
    call    j_str
    test    eax, eax
    jns     1f
    mov     byte ptr [rbx], 0
1:  pop     rbx
    ret

# ai_text(rsi=object, rdi=key) -> eax = length of that string member in
#   ai_tmp (unescaped), or <= 0
ai_text:
    sub     rsp, 8
    mov     byte ptr [rip+ai_tmp], 0
    call    j_find
    test    rax, rax
    jz      1f
    mov     rsi, rax
    lea     rdi, [rip+ai_tmp]
    mov     edx, TMP_CAP-1
    call    j_str
    test    eax, eax
    jns     2f
    mov     byte ptr [rip+ai_tmp], 0
    jmp     2f
1:  xor     eax, eax
2:  add     rsp, 8
    ret

# =============================================================================
# OpenRouter
# =============================================================================
# ai_or_key -> rax = the key (the setting, else OPENROUTER_API_KEY) or 0;
#   ai_hdr = its header
ai_key:
    sub     rsp, 8
    lea     rax, [rip+ai_or_key]
    cmp     byte ptr [rax], 0
    jne     1f
    lea     rdi, [rip+s_or_env]
    call    getenv
    test    rax, rax
    jz      9f
    cmp     byte ptr [rax], 0
    je      8f
1:  push    rax
    push    rax
    lea     rdi, [rip+ai_hdr]
    lea     rsi, [rip+s_bearer]
    call    ai_cpy
    pop     rsi
    pop     rsi
    xor     ecx, ecx                    # (500 at most, no line breaks)
2:  mov     al, [rsi+rcx]
    cmp     al, 32
    jb      3f
    cmp     ecx, 500
    jae     3f
    mov     [rdi+rcx], al
    inc     ecx
    jmp     2b
3:  mov     byte ptr [rdi+rcx], 0
    lea     rax, [rip+ai_hdr]
    jmp     9f
8:  xor     eax, eax
9:  add     rsp, 8
    ret

# ai_url_make(rsi=path) - ai_url = the address setting (no trailing /) + path
#   (Ollama's when ai_local)
ai_url_make:
    push    rsi
    lea     rdi, [rip+ai_url]
    lea     rsi, [rip+ai_or_url]
    cmp     dword ptr [rip+ai_local], 0
    je      3f
    lea     rsi, [rip+ai_ol_url]
3:  call    ai_cpy
    lea     rax, [rip+ai_url]
1:  cmp     rdi, rax
    jbe     2f
    cmp     byte ptr [rdi-1], '/'
    jne     2f
    dec     rdi
    mov     byte ptr [rdi], 0
    jmp     1b
2:  pop     rsi
    jmp     ai_cpy

# ai_or_start(rdi=prompt) -> eax = 1 the request is on its way
ai_or_start:
    push    rbx
    mov     rbx, rdi
    cmp     dword ptr [rip+ai_local], 0 # (Ollama: no key)
    jne     1f
    call    ai_key
    test    rax, rax
    jnz     1f
    mov     edi, K_ERR
    lea     rsi, [rip+s_no_key]
    call    ai_add_z
    xor     eax, eax
    pop     rbx
    ret
1:  lea     rsi, [rip+s_chat]
    call    ai_url_make
    cmp     qword ptr [rip+ai_tools_st+8], 0
    jne     2f
    call    ai_or_tools
2:  lea     rdi, [rip+ai_hist_st]       # the messages: (the instructions,)
    call    buf_swap                    #  the prompt
    cmp     qword ptr [rip+wb_len], 0
    jne     3f
    lea     rsi, [rip+j_sys_a]
    call    wb_str
    lea     rsi, [rip+ai_sys]
    call    jb_q
    mov     edi, '}'
    call    wb_char
3:  mov     edi, ','
    call    wb_char
    lea     rsi, [rip+j_user_a]
    call    wb_str
    mov     rsi, rbx
    call    jb_q
    mov     edi, '}'
    call    wb_char
    lea     rdi, [rip+ai_hist_st]
    call    buf_swap
    mov     dword ptr [rip+ai_or_n], 0
    call    ai_or_post
    pop     rbx
    ret

# ai_or_tools - the tools as functions: the curated MCP tools and
#   run_operator (not every operator's own tool)
ai_or_tools:
    push    rbx
    push    r12
    push    r13
    lea     rdi, [rip+j_tlist]
    call    str_len
    mov     esi, eax
    lea     rdi, [rip+j_tlist]
    call    mcp_local
    lea     rcx, [rax+rdx]
    mov     [rip+j_end], rcx
    mov     rsi, rax
    lea     rdi, [rip+k_result]
    call    j_find
    test    rax, rax
    jz      9f
    mov     rsi, rax
    lea     rdi, [rip+k_tools]
    call    j_find
    test    rax, rax
    jz      9f
    mov     rsi, rax
    call    j_first
    mov     rbx, rax
    lea     rdi, [rip+ai_tools_st]
    call    buf_swap
    call    wb_reset
    mov     edi, '['
    call    wb_char
    xor     r13d, r13d                  # how many
1:  test    rbx, rbx
    jz      8f
    mov     rsi, rbx
    lea     rdi, [rip+k_name]
    lea     rdx, [rip+ai_name]
    call    ai_field
    lea     rdi, [rip+ai_name]
    lea     rsi, [rip+s_op_pfx]
    call    prefix
    test    eax, eax
    jnz     7f
    test    r13d, r13d
    jz      2f
    mov     edi, ','
    call    wb_char
2:  inc     r13d
    lea     rsi, [rip+j_fn_a]
    call    wb_str
    lea     rsi, [rip+ai_name]
    call    jb_q
    lea     rsi, [rip+j_fn_b]
    call    wb_str
    lea     rdi, [rip+k_description]
    call    .Lot_raw
    lea     rsi, [rip+j_fn_c]
    call    wb_str
    lea     rdi, [rip+k_schema]
    call    .Lot_raw
    lea     rsi, [rip+j_fn_d]
    call    wb_str
7:  mov     rsi, rbx
    call    j_next
    mov     rbx, rax
    jmp     1b
8:  mov     edi, ']'
    call    wb_char
    lea     rdi, [rip+ai_tools_st]
    call    buf_swap
9:  pop     r13
    pop     r12
    pop     rbx
    ret
.Lot_raw:                               # rdi = key: its value as it is
    sub     rsp, 8
    mov     rsi, rbx
    call    j_find
    test    rax, rax
    jz      1f
    mov     r12, rax
    mov     rsi, rax
    call    j_skip
    mov     rdx, rsi
    sub     rdx, r12
    mov     rsi, r12
    call    wb_bytes
    add     rsp, 8
    ret
1:  lea     rsi, [rip+j_empty_obj]
    call    wb_str
    add     rsp, 8
    ret

# ai_or_post -> eax = 1: the conversation so far, sent
ai_or_post:
    push    rbx
    lea     rdi, [rip+ai_body_st]
    call    buf_swap
    call    wb_reset
    lea     rsi, [rip+j_body_a]
    call    wb_str
    lea     rsi, [rip+ai_or_model]
    cmp     dword ptr [rip+ai_local], 0
    je      2f
    lea     rsi, [rip+ai_ol_model]
2:  call    jb_q
    lea     rsi, [rip+j_body_b]
    call    wb_str
    mov     rsi, [rip+ai_hist_st]
    mov     rdx, [rip+ai_hist_st+8]
    call    wb_bytes
    lea     rsi, [rip+j_body_c]
    call    wb_str
    mov     rsi, [rip+ai_tools_st]
    mov     rdx, [rip+ai_tools_st+8]
    test    rdx, rdx
    jnz     1f
    lea     rsi, [rip+s_empty_arr]
    mov     edx, 2
1:  call    wb_bytes
    cmp     dword ptr [rip+ai_local], 0 # Ollama: no thinking (the model would
    je      3f                          #  answer in it, which is not shown)
    lea     rsi, [rip+j_noreason]
    call    wb_str
3:  mov     edi, '}'
    call    wb_char
    xor     edi, edi
    call    wb_char
    mov     rbx, [rip+wb_ptr]
    lea     rdi, [rip+ai_body_st]
    call    buf_swap
    mov     qword ptr [rip+ai_reply_len], 0
    lea     rax, [rip+ai_or_data]
    mov     [rip+ai_on_data], rax
    lea     rax, [rip+ai_or_exit]
    mov     [rip+ai_on_exit], rax
    lea     rdi, [rip+ai_url]
    mov     rsi, rbx
    lea     rdx, [rip+ai_hdr]
    cmp     dword ptr [rip+ai_local], 0
    je      4f
    xor     edx, edx                    # (Ollama: no key)
4:  call    ai_curl
    test    eax, eax
    jnz     9f
    mov     edi, K_ERR
    lea     rsi, [rip+s_no_curl]
    call    ai_add_z
    xor     eax, eax
9:  pop     rbx
    ret

# ai_or_data(rdi=bytes, esi=count) - curl's reply, kept whole
ai_or_data:
    mov     ecx, esi
    mov     rsi, rdi
    mov     rax, [rip+ai_reply_len]
    mov     edx, REPLY_CAP-1
    sub     rdx, rax
    cmp     rcx, rdx
    jbe     1f
    mov     rcx, rdx
1:  lea     rdi, [rip+ai_reply]
    add     rdi, rax
    add     [rip+ai_reply_len], rcx
    rep     movsb
    mov     rax, [rip+ai_reply_len]
    lea     rdi, [rip+ai_reply]
    mov     byte ptr [rdi+rax], 0
    ret
ai_or_data_line:                        # (rbx = a line, r12 its end: a test's)
    mov     rdi, rbx
    mov     rsi, r12
    sub     rsi, rbx
    sub     rsp, 8
    call    ai_or_data
    add     rsp, 8
    ret

# ai_or_exit(edi=curl's exit code) - the reply: the model's text, its tool
#   calls (run, answered, the conversation sent again), or an error
ai_or_exit:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    cmp     dword ptr [rip+ai_run], 3
    je      .Loe_test
    cmp     dword ptr [rip+ai_stopped], 0
    jne     .Loe_stopped
    test    edi, edi
    jz      1f
    mov     edi, K_ERR                  # curl's own message
    lea     rsi, [rip+s_or_fail]
    lea     rax, [rip+s_ol_fail]
    cmp     dword ptr [rip+ai_local], 0
    cmovne  rsi, rax
    lea     rdx, [rip+ai_reply]
    mov     ecx, 400
    call    ai_add
    jmp     .Loe_end
1:  lea     rbx, [rip+ai_reply]
    mov     r12, [rip+ai_reply_len]
    add     r12, rbx
    mov     [rip+ai_end], r12
    mov     rsi, rbx
    mov     rdx, r12
    call    j_valid
    test    eax, eax
    jz      .Loe_bad
    mov     [rip+j_end], r12
    mov     rsi, rbx
    call    j_ws
    mov     rbx, rsi
    cmp     byte ptr [rbx], '{'
    jne     .Loe_bad
    mov     rsi, rbx                    # {"error": {"message": ...}}
    lea     rdi, [rip+k_error]
    call    j_find
    test    rax, rax
    jz      2f
    mov     r13, rax
    mov     byte ptr [rip+ai_tmp], 0
    cmp     byte ptr [r13], '{'
    jne     11f
    mov     rsi, r13
    lea     rdi, [rip+k_message]
    call    ai_text
11: mov     edi, K_ERR
    lea     rsi, [rip+s_or_err]
    lea     rax, [rip+s_ol_err]
    cmp     dword ptr [rip+ai_local], 0
    cmovne  rsi, rax
    lea     rdx, [rip+ai_tmp]
    mov     ecx, 400
    call    ai_add
    jmp     .Loe_end
2:  mov     rsi, rbx                    # choices[0].message
    lea     rdi, [rip+k_choices]
    call    j_find
    test    rax, rax
    jz      .Loe_none
    cmp     byte ptr [rax], '['
    jne     .Loe_none
    mov     rsi, rax
    call    j_first
    test    rax, rax
    jz      .Loe_none
    mov     rsi, rax
    lea     rdi, [rip+k_message]
    call    j_find
    test    rax, rax
    jz      .Loe_none
    mov     r13, rax                    # the message
    mov     rsi, r13                    # its text
    lea     rdi, [rip+k_content]
    call    ai_text
    test    eax, eax
    jle     3f
    mov     edi, K_AI
    lea     rsi, [rip+ai_tmp]
    call    ai_add_z
3:  mov     rsi, r13                    # its tool calls
    lea     rdi, [rip+k_tool_calls]
    call    j_find
    xor     r14d, r14d
    test    rax, rax
    jz      4f
    cmp     byte ptr [rax], '['
    jne     4f
    mov     r14, rax
    mov     rsi, rax
    call    j_first
    test    rax, rax
    jnz     5f
    xor     r14d, r14d
4:  call    .Loe_hist_asst              # an answer: kept, the request is done
    jmp     .Loe_end
5:  mov     r15, rax                    # the first call
    call    .Loe_hist_asst
.Loe_call:
    test    r15, r15
    jz      .Loe_next
    mov     rsi, r15
    lea     rdi, [rip+k_id]
    lea     rdx, [rip+ai_cid]
    call    ai_field
    mov     rsi, r15
    lea     rdi, [rip+k_function]
    call    j_find
    test    rax, rax
    jz      .Loe_skip
    mov     r13, rax
    mov     rsi, r13
    lea     rdi, [rip+k_name]
    lea     rdx, [rip+ai_name]
    call    ai_field
    mov     rsi, r13                    # the arguments: a JSON text (or an
    lea     rdi, [rip+k_arguments]      #  object)
    call    j_find
    lea     rdi, [rip+ai_args]
    mov     byte ptr [rdi], 0
    test    rax, rax
    jz      7f
    cmp     byte ptr [rax], '"'
    jne     6f
    mov     rsi, rax
    mov     edx, TMP_CAP-1
    call    j_str
    test    eax, eax
    jns     7f
    mov     byte ptr [rip+ai_args], 0
    jmp     7f
6:  mov     r13, rax
    mov     rsi, rax
    call    j_skip
    mov     rcx, rsi
    sub     rcx, r13
    cmp     rcx, TMP_CAP-1
    jae     7f
    lea     rdi, [rip+ai_args]
    mov     rsi, r13
    mov     rdx, rcx
    rep     movsb
    mov     byte ptr [rdi], 0
7:  lea     rdi, [rip+ai_args]          # not one JSON value: {}
    call    str_len
    lea     rsi, [rip+ai_args]
    lea     rdx, [rsi+rax]
    test    eax, eax
    jz      71f
    call    j_valid
    test    eax, eax
    jnz     72f
71: lea     rdi, [rip+ai_args]
    lea     rsi, [rip+j_empty_obj]
    call    ai_cpy
72: lea     rdi, [rip+ai_args]
    call    str_len
    mov     edx, eax
    lea     rdi, [rip+ai_name]
    lea     rsi, [rip+ai_args]
    call    ai_add_tool
    call    ai_tool_run                 # -> ai_tmp, ai_iserr
    mov     edi, K_RES
    cmp     dword ptr [rip+ai_iserr], 0
    je      73f
    mov     edi, K_ERR
73: lea     rsi, [rip+s_eq]
    lea     rdx, [rip+ai_tmp]
    mov     ecx, 160
    call    ai_add
    lea     rdi, [rip+ai_hist_st]       # {"role":"tool", ...}
    call    buf_swap
    mov     edi, ','
    call    wb_char
    lea     rsi, [rip+j_tool_a]
    call    wb_str
    lea     rsi, [rip+ai_cid]
    call    jb_q
    lea     rsi, [rip+j_tool_b]
    call    wb_str
    mov     byte ptr [rip+ai_tmp+12000], 0
    lea     rsi, [rip+ai_tmp]
    call    jb_q
    mov     edi, '}'
    call    wb_char
    lea     rdi, [rip+ai_hist_st]
    call    buf_swap
    mov     rax, [rip+ai_end]           # (mcp_local read its own text)
    mov     [rip+j_end], rax
.Loe_skip:
    mov     rsi, r15
    call    j_next
    mov     r15, rax
    jmp     .Loe_call
.Loe_next:                              # again, with the results
    inc     dword ptr [rip+ai_or_n]
    cmp     dword ptr [rip+ai_stopped], 0
    jne     .Loe_stopped
    mov     eax, [rip+ai_or_n]
    mov     ecx, [rip+ai_or_steps]
    cmp     dword ptr [rip+ai_local], 0
    je      7f
    mov     ecx, [rip+ai_ol_steps]
7:  cmp     eax, ecx
    jl      8f
    call    fmt_reset
    lea     rdi, [rip+s_steps_a]
    call    fmt_str
    mov     edi, [rip+ai_or_n]
    call    fmt_int
    lea     rdi, [rip+s_steps_b]
    call    fmt_str
    mov     edi, K_NOTE
    lea     rsi, [rip+fmt_buf]
    call    ai_add_z
    jmp     .Loe_end
8:  call    ai_or_post
    test    eax, eax
    jz      .Loe_end
    jmp     .Loe_out
.Loe_bad:
    mov     edi, K_ERR
    lea     rsi, [rip+s_or_bad]
    lea     rax, [rip+s_ol_bad]
    cmp     dword ptr [rip+ai_local], 0
    cmovne  rsi, rax
    lea     rdx, [rip+ai_reply]
    mov     ecx, 300
    call    ai_add
    jmp     .Loe_end
.Loe_none:
    mov     edi, K_ERR
    lea     rsi, [rip+s_or_none]
    lea     rax, [rip+s_ol_none]
    cmp     dword ptr [rip+ai_local], 0
    cmovne  rsi, rax
    call    ai_add_z
    jmp     .Loe_end
.Loe_stopped:
    mov     edi, K_NOTE
    lea     rsi, [rip+s_stopped]
    call    ai_add_z
.Loe_end:
    call    ai_finish
.Loe_out:
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret
.Loe_test:
    call    ai_test_exit
    jmp     .Loe_out
.Loe_hist_asst:                         # the model's message, into the
    sub     rsp, 8                      #  conversation (r14: its tool calls)
    lea     rdi, [rip+ai_hist_st]
    call    buf_swap
    mov     edi, ','
    call    wb_char
    lea     rsi, [rip+j_asst_a]
    call    wb_str
    lea     rsi, [rip+ai_tmp]
    call    jb_q
    test    r14, r14
    jz      1f
    lea     rsi, [rip+j_asst_b]
    call    wb_str
    mov     rsi, r14
    call    j_skip
    mov     rdx, rsi
    sub     rdx, r14
    mov     rsi, r14
    call    wb_bytes
1:  mov     edi, '}'
    call    wb_char
    lea     rdi, [rip+ai_hist_st]
    call    buf_swap
    add     rsp, 8
    ret

# ai_tool_run - the tool ai_name with the arguments ai_args, through the MCP
#   server's own handler -> ai_tmp = its text, ai_iserr
ai_tool_run:
    push    rbx
    push    r12
    sub     rsp, 8
    mov     dword ptr [rip+ai_iserr], 1
    mov     byte ptr [rip+ai_tmp], 0
    lea     rdi, [rip+ai_req_st]
    call    buf_swap
    call    wb_reset
    lea     rsi, [rip+j_call_a]
    call    wb_str
    lea     rsi, [rip+ai_name]
    call    jb_q
    lea     rsi, [rip+j_call_b]
    call    wb_str
    lea     rsi, [rip+ai_args]
    call    wb_str
    lea     rsi, [rip+j_fn_d]
    call    wb_str
    mov     rbx, [rip+wb_ptr]
    mov     r12, [rip+wb_len]
    lea     rdi, [rip+ai_req_st]
    call    buf_swap
    mov     rdi, rbx
    mov     rsi, r12
    call    mcp_local
    lea     rcx, [rax+rdx]
    mov     [rip+j_end], rcx
    mov     rbx, rax
    mov     rsi, rbx
    lea     rdi, [rip+k_result]
    call    j_find
    test    rax, rax
    jz      5f
    mov     r12, rax
    mov     rsi, r12
    lea     rdi, [rip+k_isError]
    call    j_find
    test    rax, rax
    jz      1f
    mov     rsi, rax
    call    j_bool
    mov     [rip+ai_iserr], eax
    jmp     2f
1:  mov     dword ptr [rip+ai_iserr], 0
2:  mov     rsi, r12
    lea     rdi, [rip+k_content]
    call    j_find
    test    rax, rax
    jz      9f
    mov     rsi, rax
    call    j_first
    test    rax, rax
    jz      9f
    mov     rsi, rax
    lea     rdi, [rip+k_text]
    call    ai_text
    jmp     9f
5:  mov     rsi, rbx                    # a protocol error: its message
    lea     rdi, [rip+k_error]
    call    j_find
    test    rax, rax
    jz      9f
    mov     rsi, rax
    lea     rdi, [rip+k_message]
    call    ai_text
9:  add     rsp, 8
    pop     r12
    pop     rbx
    ret

# =============================================================================
# Test a connection (Preferences > AI)
# =============================================================================
# ai_test(edi=0 Claude Code / 1 Grok / 2 OpenRouter / 3 Ollama) - its
#   version, the key's validity, or whether Ollama has the model, as a toast
ai_test:
    push    rbx
    mov     ebx, edi
    cmp     dword ptr [rip+ai_busy], 0
    jne     .Lte_busy
    call    ai_proc_running
    test    eax, eax
    jnz     .Lte_busy
    mov     [rip+ai_test_which], ebx
    mov     qword ptr [rip+ai_reply_len], 0
    mov     byte ptr [rip+ai_reply], 0
    lea     rax, [rip+ai_or_data]
    mov     [rip+ai_on_data], rax
    xor     eax, eax
    cmp     ebx, 3
    sete    al
    mov     [rip+ai_local], eax
    je      21f
    cmp     ebx, 2
    je      2f
    mov     edi, ebx                    # <program> --version
    xor     esi, esi
    call    ai_prog
    test    rax, rax
    jz      9f
    lea     rax, [rip+ai_cli_exit]
    mov     [rip+ai_on_exit], rax
    lea     rcx, [rip+ap_argv_ai]
    lea     rax, [rip+ai_path]
    mov     [rcx], rax
    lea     rax, [rip+a_version]
    mov     [rcx+8], rax
    mov     qword ptr [rcx+16], 0
    mov     dword ptr [rip+ai_run], 3
    lea     rdi, [rip+ai_path]
    mov     rsi, rcx
    xor     edx, edx
    xor     ecx, ecx
    call    ai_proc_spawn
    jmp     9f
2:  call    ai_key                      # GET <address>/key with the key
    test    rax, rax
    jnz     3f
    lea     rdi, [rip+s_test_bad]
    lea     rsi, [rip+s_no_key]
    call    ai_test_pair
    jmp     9f
3:  lea     rsi, [rip+s_keypath]
    call    ai_url_make
    lea     rdx, [rip+ai_hdr]
    jmp     22f
21: lea     rsi, [rip+s_modelspath]     # GET <Ollama's address>/models
    call    ai_url_make
    xor     edx, edx
22: lea     rax, [rip+ai_or_exit]
    mov     [rip+ai_on_exit], rax
    mov     dword ptr [rip+ai_run], 3
    lea     rdi, [rip+ai_url]
    xor     esi, esi
    call    ai_curl
    test    eax, eax
    jnz     9f
    lea     rdi, [rip+s_test_bad]
    lea     rax, [rip+s_test_bad_ol]
    cmp     dword ptr [rip+ai_local], 0
    cmovne  rdi, rax
    lea     rsi, [rip+s_no_curl]
    call    ai_test_pair
    jmp     9f
.Lte_busy:
    lea     rdi, [rip+s_busy]
    call    log_line
9:  pop     rbx
    ret

# ai_test_exit(edi=exit code) - the test's answer, as a toast
ai_test_exit:
    push    rbx
    push    r12
    sub     rsp, 8
    mov     dword ptr [rip+ai_run], 0
    cmp     dword ptr [rip+ai_test_which], 2
    jae     .Ltx_or
    lea     rbx, [rip+ai_reply]         # the first line: "2.1.0 (Claude Code)"
    xor     ecx, ecx
1:  mov     al, [rbx+rcx]
    test    al, al
    jz      2f
    cmp     al, 10
    je      2f
    cmp     ecx, 100
    jae     2f
    inc     ecx
    jmp     1b
2:  mov     byte ptr [rbx+rcx], 0
    call    fmt_reset
    lea     rdi, [rip+s_sp2]
    call    fmt_str
    mov     eax, [rip+ai_test_which]
    lea     rcx, [rip+prov_names]
    mov     rdi, [rcx+rax*8]
    call    fmt_str
    lea     rdi, [rip+s_colon]
    call    fmt_str
    mov     rdi, rbx
    call    fmt_str
    lea     rdi, [rip+fmt_buf]
    call    ai_test_say
    jmp     9f
.Ltx_or:                                # {"data": ...}: the key works
    test    edi, edi
    jnz     5f
    lea     rbx, [rip+ai_reply]
    mov     r12, [rip+ai_reply_len]
    add     r12, rbx
    mov     rsi, rbx
    mov     rdx, r12
    call    j_valid
    test    eax, eax
    jz      5f
    mov     [rip+j_end], r12
    mov     rsi, rbx
    call    j_ws
    mov     rbx, rsi
    mov     rsi, rbx
    lea     rdi, [rip+k_data]
    call    j_find
    test    rax, rax
    jz      4f
    cmp     dword ptr [rip+ai_local], 0
    jne     .Ltx_ol
    lea     rdi, [rip+s_test_ok_key]
    call    ai_test_say
    jmp     9f
.Ltx_ol:                                # {"data": [{"id": <model>}, ...]}
    mov     rsi, rax
    call    j_first
    mov     r12, rax
6:  test    r12, r12
    jz      7f
    mov     rsi, r12
    lea     rdi, [rip+k_id]
    lea     rdx, [rip+ai_name]
    call    ai_field
    lea     rdi, [rip+ai_name]
    lea     rsi, [rip+ai_ol_model]
    call    str_eq
    test    eax, eax
    jnz     8f
    mov     rsi, r12
    call    j_next
    mov     r12, rax
    jmp     6b
8:  lea     rdi, [rip+s_test_ok_ol]
    call    ai_test_say
    jmp     9f
7:  call    fmt_reset                   # "it answers, but has no model named x"
    lea     rdi, [rip+s_test_bad_ol]
    call    fmt_str
    lea     rdi, [rip+s_test_nomodel]
    call    fmt_str
    lea     rdi, [rip+ai_ol_model]
    call    fmt_str
    lea     rdi, [rip+fmt_buf]
    call    ai_test_say
    jmp     9f
4:  mov     rsi, rbx                    # its error's message
    lea     rdi, [rip+k_error]
    call    j_find
    test    rax, rax
    jz      5f
    mov     rsi, rax
    lea     rdi, [rip+k_message]
    call    ai_text
    test    eax, eax
    jle     5f
    lea     rdi, [rip+s_test_bad]
    lea     rax, [rip+s_test_bad_ol]
    cmp     dword ptr [rip+ai_local], 0
    cmovne  rdi, rax
    lea     rsi, [rip+ai_tmp]
    call    ai_test_pair
    jmp     9f
5:  lea     rdi, [rip+s_test_bad]
    lea     rax, [rip+s_test_bad_ol]
    cmp     dword ptr [rip+ai_local], 0
    cmovne  rdi, rax
    lea     rsi, [rip+s_test_noans]
    call    ai_test_pair
9:  add     rsp, 8
    pop     r12
    pop     rbx
    ret

# ai_test_pair(rdi=prefix, rsi=text) / ai_test_say(rdi="  text") - a test's
#   answer: a toast, and a note in the transcript
ai_test_pair:
    push    rsi
    push    rdi
    call    fmt_reset
    pop     rdi
    call    fmt_str
    pop     rdi
    call    fmt_str
    lea     rdi, [rip+fmt_buf]
ai_test_say:
    push    rdi
    call    log_line
    pop     rsi
    add     rsi, 2
    mov     edi, K_NOTE
    jmp     ai_add_z

# =============================================================================
# Operators
# =============================================================================
do_ai_send:
    mov     rdi, [rip+op_arg]
    test    rdi, rdi
    jz      1f
    cmp     byte ptr [rdi], 0
    jne     2f
1:  lea     rdi, [rip+ai_prompt]        # (none: the prompt field's)
2:  sub     rsp, 8
    call    ai_send
    cmp     dword ptr [rip+ai_busy], 0
    je      3f
    mov     byte ptr [rip+ai_prompt], 0
3:  add     rsp, 8
    ret

do_ai_stop:
    cmp     dword ptr [rip+ai_busy], 0
    je      9f
    mov     dword ptr [rip+ai_stopped], 1
    sub     rsp, 8
    call    ai_proc_stop
    add     rsp, 8
9:  ret

do_ai_new:
    cmp     dword ptr [rip+ai_busy], 0
    jne     9f
    mov     dword ptr [rip+ai_tx_len], 0
    mov     dword ptr [rip+ai_sel_a], 0
    mov     dword ptr [rip+ai_sel_b], 0
    mov     byte ptr [rip+ai_sid], 0
    mov     dword ptr [rip+ai_sid_prov], 0
    mov     qword ptr [rip+ai_hist_st+8], 0
    mov     dword ptr [rip+ai_scroll], 0
    mov     dword ptr [rip+dirty], 1
9:  ret

# ai.copy - the selection, else the transcript as shown (a line an entry, a
#   blank line before each prompt but the first), becomes the clipboard
do_ai_copy:
    push    rbx
    push    r12
    push    r13
    call    ai_sel_copy
    test    eax, eax
    jnz     9f
    cmp     dword ptr [rip+ai_tx_len], 0
    jne     1f
    lea     rdi, [rip+s_nothing_copy]
    call    log_line
    jmp     9f
1:  lea     r12, [rip+ai_copy_buf]
    xor     r13d, r13d                  # bytes out
    xor     ebx, ebx                    # the entry's offset
2:  cmp     ebx, [rip+ai_tx_len]
    jae     5f
    lea     rsi, [rip+ai_tx]
    add     rsi, rbx
    cmp     byte ptr [rsi], K_YOU
    jne     3f
    test    ebx, ebx
    jz      3f
    mov     byte ptr [r12+r13], 10
    inc     r13d
3:  inc     rsi                         # (an entry is no longer than its
    inc     ebx                         #  kind and 0: the buffer holds it)
31: mov     al, [rsi]
    inc     rsi
    inc     ebx
    test    al, al
    jz      4f
    mov     [r12+r13], al
    inc     r13d
    jmp     31b
4:  mov     byte ptr [r12+r13], 10
    inc     r13d
    jmp     2b
5:  mov     rdi, r12
    mov     esi, r13d
    call    clip_copy
    lea     rdi, [rip+s_copied]
    call    log_line
9:  pop     r13
    pop     r12
    pop     rbx
    ret

do_ai_revert:
    sub     rsp, 8
    cmp     dword ptr [rip+ai_busy], 0
    jne     1f
    call    revertable
    test    eax, eax
    jz      1f
    lea     rdi, [rip+op_edit_undo]
    call    run_op
    add     rsp, 8
    ret
1:  lea     rdi, [rip+s_nothing_rev]
    call    log_line
    add     rsp, 8
    ret

do_ai_test:
    mov     rsi, [rip+op_arg]
    xor     edi, edi
    test    rsi, rsi
    jz      1f
    movzx   edi, byte ptr [rsi]
    sub     edi, '0'
    cmp     edi, 2
    jbe     1f
    xor     edi, edi
1:  jmp     ai_test

# ai.transcript - "$ ai: idle|busy <entries>", then the last 24 entries as
#   "$ <kind letter> <text>" (Y you, A the AI, T a tool, R its result, E an
#   error, N a note)
do_ai_transcript:
    push    rbx
    push    r12
    push    r13
    call    fmt_reset
    lea     rdi, [rip+s_tr_head]
    call    fmt_str
    lea     rdi, [rip+s_tr_idle]
    cmp     dword ptr [rip+ai_busy], 0
    je      1f
    lea     rdi, [rip+s_tr_busy]
1:  call    fmt_str
    xor     ebx, ebx                    # entries
    xor     ecx, ecx
2:  cmp     ecx, [rip+ai_tx_len]
    jae     3f
    inc     ebx
    lea     rdi, [rip+ai_tx]
    lea     rdi, [rdi+rcx+1]
    push    rcx
    push    rcx
    call    str_len
    pop     rcx
    pop     rcx
    lea     ecx, [rcx+rax+2]
    jmp     2b
3:  mov     edi, ebx
    call    fmt_int
    lea     rdi, [rip+fmt_buf]
    call    log_line
    lea     r12d, [rbx-24]              # skip all but the last 24
    xor     r13d, r13d                  # offset
4:  cmp     r13d, [rip+ai_tx_len]
    jae     9f
    lea     rsi, [rip+ai_tx]
    add     rsi, r13
    dec     r12d
    jns     6f
    lea     rdi, [rip+ai_trline]        # "$ K text" (80 bytes of it: "$ "
    mov     word ptr [rdi], 0x2024      #  lines are not toasts)
    movzx   eax, byte ptr [rsi]
    lea     rcx, [rip+s_tr_kinds]
    mov     al, [rcx+rax]
    mov     [rdi+2], al
    mov     byte ptr [rdi+3], ' '
    xor     ecx, ecx
5:  mov     al, [rsi+rcx+1]
    test    al, al
    jz      51f
    cmp     ecx, 80
    jae     51f
    mov     [rdi+rcx+4], al
    inc     ecx
    jmp     5b
51: mov     byte ptr [rdi+rcx+4], 0
    call    log_line
6:  lea     rdi, [rip+ai_tx]
    lea     rdi, [rdi+r13+1]
    call    str_len
    lea     r13d, [r13+rax+2]
    jmp     4b
9:  pop     r13
    pop     r12
    pop     rbx
    ret

# ai.mode - to the prompt: the AI workspace when no AI Assistant is shown
do_ai_mode:
    sub     rsp, 8
    mov     edi, ED_AI
    call    find_editor
    test    eax, eax
    jns     1f
    call    wsp_ai
1:  mov     dword ptr [rip+ai_focus], 1
    mov     dword ptr [rip+dirty], 1
    add     rsp, 8
    ret

# the prompt field: Enter sends (a click elsewhere keeps the text)
ai_prompt_cb:                           # rdi = the text
    push    rbx
    mov     rsi, rdi
    lea     rdi, [rip+ai_prompt]
    mov     ecx, PROMPT_CAP
1:  mov     al, [rsi]
    mov     [rdi], al
    test    al, al
    jz      2f
    inc     rsi
    inc     rdi
    dec     ecx
    jnz     1b
    mov     byte ptr [rdi], 0
2:  cmp     dword ptr [rip+wg_by_enter], 0
    je      9f
    lea     rdi, [rip+ai_prompt]
    call    ai_send
    cmp     dword ptr [rip+ai_busy], 0
    je      9f
    mov     byte ptr [rip+ai_prompt], 0
9:  pop     rbx
    ret

ai_prov_cb:
    jmp     prefs_save

# =============================================================================
# The AI Assistant area
# =============================================================================
# kind_col(edi=kind) -> eax = its colour
kind_col:
    mov     eax, COL_TEXT
    cmp     edi, K_YOU
    jne     1f
    mov     eax, COL_ACCENT
1:  cmp     edi, K_TOOL
    je      2f
    cmp     edi, K_RES
    je      2f
    cmp     edi, K_NOTE
    jne     3f
2:  mov     eax, COL_TEXT_DIM
3:  cmp     edi, K_ERR
    jne     4f
    mov     eax, COL_WARN
4:  ret

# ai_entries_height(esi=width) -> eax = the transcript's height
ai_entries_height:
    push    rbx
    push    r12
    push    r13
    mov     r12d, esi
    xor     r13d, r13d
    xor     ebx, ebx
1:  cmp     ebx, [rip+ai_tx_len]
    jae     9f
    lea     rdi, [rip+ai_tx]
    cmp     byte ptr [rdi+rbx], K_YOU   # (a gap before each prompt)
    jne     2f
    test    ebx, ebx
    jz      2f
    add     r13d, 10
2:  lea     rdi, [rdi+rbx+1]
    mov     esi, r12d
    xor     edx, edx
    xor     ecx, ecx
    xor     r8d, r8d
    call    wrap_text
    test    eax, eax
    jnz     3f
    mov     eax, 1
3:  imul    eax, eax, LINE_H
    add     r13d, eax
    lea     rdi, [rip+ai_tx]            # the next entry
    lea     rdi, [rdi+rbx+1]
    call    str_len
    lea     ebx, [rbx+rax+2]
    jmp     1b
9:  mov     eax, r13d
    pop     r13
    pop     r12
    pop     rbx
    ret

ed_ai_draw:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    push    rbp
    sub     rsp, 24
    mov     r12d, [rip+ed_y]
    add     r12d, 8
    call    pnl_begin
    lea     rdi, [rip+wd_ai_prov]       # the connection | New Revert
    lea     r8, [rip+ai_prov]
    call    pnl_left
    mov     eax, [rip+pnl_w]
    shr     eax, 1
    sub     eax, 15
    xor     edx, edx
    mov     ecx, 3
    div     ecx
    mov     r13d, eax                   # a button's width (New Copy Revert)
    mov     esi, [rip+pnl_x]
    mov     eax, [rip+pnl_w]
    shr     eax, 1
    add     esi, eax
    add     esi, 3
    mov     r14d, esi
    lea     rdi, [rip+wd_ai_new]
    mov     edx, r12d
    mov     ecx, r13d
    xor     r8d, r8d
    xor     r9d, r9d
    call    wg
    test    eax, eax
    jz      1f
    call    do_ai_new
1:  cmp     dword ptr [rip+ai_tx_len], 0
    je      15f
    lea     rdi, [rip+wd_ai_copy]
    lea     esi, [r14+r13+6]
    mov     edx, r12d
    mov     ecx, r13d
    xor     r8d, r8d
    xor     r9d, r9d
    call    wg
    test    eax, eax
    jz      15f
    call    do_ai_copy
15: cmp     dword ptr [rip+ai_busy], 0
    jne     2f
    call    revertable
    test    eax, eax
    jz      2f
    lea     rdi, [rip+wd_ai_revert]
    lea     esi, [r13*2+12]
    add     esi, r14d
    mov     edx, r12d
    mov     ecx, r13d
    xor     r8d, r8d
    xor     r9d, r9d
    call    wg
    test    eax, eax
    jz      2f
    call    do_ai_revert
2:  add     r12d, WG_H+8
    # the prompt (at the bottom, as tall as its lines) and the line above it
    mov     eax, [rip+ed_h]             # (its lines: 10 at most, fewer in a
    sub     eax, 160                    #  low area)
    cdq
    mov     ecx, 18
    idiv    ecx
    mov     ecx, PROMPT_MAXL
    cmp     eax, ecx
    cmovl   ecx, eax
    lea     rdi, [rip+wd_ai_prompt]
    lea     rsi, [rip+ai_prompt]
    mov     edx, [rip+pnl_w]
    sub     edx, 76
    call    wg_text_h
    mov     [rip+wd_ai_prompt+WD_N], eax
    mov     [rsp+16], eax
    mov     r15d, [rip+ed_y]
    add     r15d, [rip+ed_h]
    sub     r15d, eax
    sub     r15d, 8                     # the prompt's y
    lea     eax, [r15-22]
    mov     [rsp], eax                  # the status line's y
    sub     eax, 4
    sub     eax, r12d
    mov     [rsp+4], eax                # the transcript's height
    # the transcript: the newest text kept in view
    mov     eax, [rip+pnl_w]
    sub     eax, 10
    mov     [rsp+8], eax                # the text's width
    cmp     dword ptr [rip+ai_stick], 0
    je      3f
    mov     dword ptr [rip+ai_stick], 0
    mov     esi, [rsp+8]
    call    ai_entries_height
    sub     eax, [rsp+4]
    jns     21f
    xor     eax, eax
21: mov     [rip+ai_scroll], eax
3:  cmp     dword ptr [rsp+4], LINE_H
    jl      .Lad_prompt
    lea     rdi, [rip+wd_ai_scroll]
    mov     esi, [rip+ed_x]
    mov     edx, r12d
    mov     ecx, [rip+ed_w]
    mov     r8d, [rsp+4]
    lea     r9, [rip+ai_scroll]
    call    wg_scroll_begin
    mov     ebp, eax                    # y
    cmp     dword ptr [rip+ai_tx_len], 0
    jne     4f
    lea     rdi, [rip+s_hint]
    mov     esi, [rsp+8]
    mov     edx, [rip+pnl_x]
    mov     ecx, ebp
    mov     r8d, COL_TEXT_DIM
    call    wrap_text
    imul    eax, eax, LINE_H
    add     ebp, eax
    jmp     8f
4:  xor     ebx, ebx
    mov     dword ptr [rip+ai_nlines], 0
    lea     rax, [rip+ai_line_hook]     # (each line: where it is; the
    mov     [rip+wt_hook], rax          #  selection under it)
5:  cmp     ebx, [rip+ai_tx_len]
    jae     8f
    lea     rdi, [rip+ai_tx]
    movzx   eax, byte ptr [rdi+rbx]
    mov     [rsp+12], eax
    cmp     eax, K_YOU                  # (a gap before each prompt, not
    jne     6f                          #  before its later lines)
    test    ebx, ebx
    jz      6f
    lea     rdi, [rip+ai_tx]
    cmp     byte ptr [rdi+rbx+1], ' '
    je      6f
    add     ebp, 10
6:  mov     edi, [rsp+12]
    call    kind_col
    mov     r8d, eax
    lea     rdi, [rip+ai_tx]
    lea     rdi, [rdi+rbx+1]
    mov     esi, [rsp+8]
    mov     edx, [rip+pnl_x]
    mov     ecx, ebp
    call    wrap_text
    test    eax, eax
    jnz     7f
    mov     eax, 1
7:  imul    eax, eax, LINE_H
    add     ebp, eax
    lea     rdi, [rip+ai_tx]
    lea     rdi, [rdi+rbx+1]
    call    str_len
    lea     ebx, [rbx+rax+2]
    jmp     5b
8:  mov     qword ptr [rip+wt_hook], 0
    mov     edi, ebp
    call    wg_scroll_end
    cmp     dword ptr [rip+ai_tx_len], 0  # the text: a pad to select it in
    je      .Lad_prompt
    mov     eax, [rsp+4]
    mov     [rip+wd_ai_text+WD_N], eax
    lea     rdi, [rip+wd_ai_text]
    mov     esi, [rip+ed_x]
    mov     edx, r12d
    mov     ecx, [rip+ed_w]
    sub     ecx, 14                     # (the scrollbar stays the scrollbar's)
    lea     r8, [rip+ai_pad]
    xor     r9d, r9d
    call    wg
.Lad_prompt:
    cmp     dword ptr [rip+ai_busy], 0  # the status line
    je      9f
    call    fmt_reset
    lea     rdi, [rip+s_working]
    call    fmt_str
    mov     eax, [rip+ai_run]
    and     eax, 3
    cmp     eax, 2
    jb      81f
    ja      82f
    add     eax, [rip+ai_local]         # (OpenRouter, or Ollama)
    jmp     81f
82: xor     eax, eax
81: lea     rcx, [rip+prov_names]
    mov     rdi, [rcx+rax*8]
    call    fmt_str
    lea     rdi, [rip+s_dots]
    call    fmt_str
    mov     edi, [rip+pnl_x]
    mov     esi, [rsp]
    lea     rdx, [rip+fmt_buf]
    mov     ecx, COL_ACCENT
    call    draw_small
9:  mov     r13d, 70                    # the prompt | Send (Stop)                    # the button's width
    mov     ecx, [rip+pnl_w]
    sub     ecx, r13d
    sub     ecx, 6
    lea     rdi, [rip+wd_ai_prompt]
    mov     esi, [rip+pnl_x]
    mov     edx, r15d
    lea     r8, [rip+ai_prompt]
    xor     r9d, r9d
    call    wg
    cmp     dword ptr [rip+ai_focus], 0 # ai.mode: type here
    je      10f
    mov     dword ptr [rip+ai_focus], 0
    call    wg_edit_last
10: cmp     byte ptr [rip+ai_prompt], 0 # (a hint while it is empty)
    jne     11f
    call    wg_editing
    test    eax, eax
    jnz     11f
    mov     edi, [rip+pnl_x]
    add     edi, 8
    lea     esi, [r15+3]
    lea     rdx, [rip+s_prompt_hint]
    mov     ecx, COL_TEXT_OFF
    call    draw_small
11: lea     rdi, [rip+wd_ai_send]
    cmp     dword ptr [rip+ai_busy], 0
    je      12f
    lea     rdi, [rip+wd_ai_stop]
12: mov     esi, [rip+pnl_x]            # (beside its last line)
    add     esi, [rip+pnl_w]
    sub     esi, r13d
    mov     edx, r15d
    add     edx, [rsp+16]
    sub     edx, WG_H
    mov     ecx, r13d
    xor     r8d, r8d
    xor     r9d, r9d
    call    wg
    test    eax, eax
    jz      13f
    cmp     dword ptr [rip+ai_busy], 0
    je      14f
    call    do_ai_stop
    jmp     13f
14: mov     qword ptr [rip+op_arg], 0
    call    do_ai_send
13: add     rsp, 24
    pop     rbp
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# ---- selecting text in the conversation ------------------------------------------
.equ AI_MAXL,   4096
# ai_line_hook(rdi=line, esi=bytes, edx=x, ecx=y) - wrap_text's: the line kept
#   for hits, the selection drawn under it
ai_line_hook:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    mov     rbx, rdi
    mov     r12d, esi
    mov     r13d, edx
    mov     r14d, ecx
    lea     rax, [rip+ai_tx]
    mov     r15, rbx
    sub     r15, rax                    # its offset
    mov     eax, [rip+ai_nlines]
    cmp     eax, AI_MAXL
    jae     1f
    shl     eax, 4
    lea     rcx, [rip+ai_lines]
    mov     [rcx+rax], r15d
    mov     [rcx+rax+4], r12d
    mov     [rcx+rax+8], r13d
    mov     [rcx+rax+12], r14d
    inc     dword ptr [rip+ai_nlines]
1:  mov     eax, [rip+ai_sel_a]         # the selection over it
    mov     ecx, [rip+ai_sel_b]
    cmp     eax, ecx
    je      9f
    jl      2f
    xchg    eax, ecx                    # eax lo, ecx hi
2:  lea     edx, [r15+r12]              # the line's end
    cmp     eax, edx
    jg      9f
    cmp     ecx, r15d
    jle     9f
    sub     eax, r15d                   # from (0 when it began before)
    jns     3f
    xor     eax, eax
3:  push    rcx
    push    rax
    mov     rdi, rbx
    mov     esi, eax
    call    text_width_n
    mov     r8d, eax                    # x0 - x
    pop     rax
    pop     rcx
    sub     ecx, r15d                   # to (past the line: its end and a bit)
    xor     r9d, r9d
    cmp     ecx, r12d
    jle     4f
    mov     ecx, r12d
    mov     r9d, 6
4:  push    r8
    push    r9
    mov     rdi, rbx
    mov     esi, ecx
    call    text_width_n
    pop     r9
    pop     r8
    add     eax, r9d
    lea     edi, [r13+r8]
    lea     edx, [rax]
    sub     edx, r8d
    jle     9f
    lea     esi, [r14-1]
    mov     ecx, LINE_H
    mov     r8d, COL_SELECTION
    call    fill_rect
9:  pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# ai_hit(edi=x, esi=y) -> eax = the transcript offset nearest that point
ai_hit:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    mov     r12d, edi
    mov     r13d, esi
    mov     ecx, [rip+ai_nlines]
    test    ecx, ecx
    jz      8f
    lea     rbx, [rip+ai_lines]         # the line: the last one starting at
    mov     r14, rbx                    #  or above y (the first when above)
    xor     edx, edx
1:  cmp     edx, ecx
    jae     2f
    imul    eax, edx, 16
    cmp     [rbx+rax+12], r13d
    jg      2f
    lea     r14, [rbx+rax]
    inc     edx
    jmp     1b
2:  mov     eax, [r14+12]               # below its line (past the text): the
    add     eax, LINE_H                 #  end of it
    cmp     r13d, eax
    jl      21f
    mov     eax, [rip+ai_nlines]
    dec     eax
    shl     eax, 4
    lea     rax, [rbx+rax]
    cmp     r14, rax
    jne     21f
    mov     eax, [r14]
    add     eax, [r14+4]
    jmp     9f
21: mov     r15d, [r14]                 # the character: the most that fit
    lea     rax, [rip+ai_tx]            #  left of x (and half the next)
    lea     rbx, [rax+r15]
    xor     ecx, ecx
3:  cmp     ecx, [r14+4]
    jge     5f
    push    rcx
    push    rcx
    lea     esi, [rcx+1]
    mov     rdi, rbx
    call    text_width_n
    mov     edx, eax                    # the right of character c
    pop     rcx
    pop     rcx
    push    rcx
    push    rdx
    mov     rdi, rbx
    mov     esi, ecx
    call    text_width_n                # its left
    pop     rdx
    pop     rcx
    add     eax, edx
    shr     eax, 1                      # its middle
    add     eax, [r14+8]
    cmp     r12d, eax
    jl      5f
    inc     ecx
    jmp     3b
5:  lea     eax, [r15+rcx]
    jmp     9f
8:  xor     eax, eax
9:  pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# ai_pad_cb - pressed: the selection starts there (a double-click: the whole
#   message); dragged: it ends there
ai_pad_cb:
    push    rbx
    push    r12
    sub     rsp, 8
    mov     edi, [rip+ptr_x]
    mov     esi, [rip+ptr_y]
    call    ai_hit
    mov     ebx, eax
    mov     eax, [rip+ptr_x]            # a press: where the drag began
    cmp     eax, [rip+wg_x0]
    jne     5f
    mov     eax, [rip+ptr_y]
    cmp     eax, [rip+wg_y0]
    jne     5f
    call    mono_ns
    mov     r12, rax
    sub     rax, [rip+ai_click_t]
    cmp     rax, 400000000
    ja      2f
    mov     edi, ebx                    # twice: the message it is in
    call    ai_entry_of
    mov     [rip+ai_sel_a], eax
    mov     [rip+ai_sel_b], edx
    mov     qword ptr [rip+ai_click_t], 0
    jmp     9f
2:  mov     [rip+ai_click_t], r12
    mov     [rip+ai_sel_a], ebx
5:  mov     [rip+ai_sel_b], ebx
9:  mov     dword ptr [rip+dirty], 1
    add     rsp, 8
    pop     r12
    pop     rbx
    ret

# ai_entry_of(edi=offset) -> eax, edx = its message's text, start and end
ai_entry_of:
    lea     rcx, [rip+ai_tx]
    mov     eax, edi
1:  test    eax, eax                    # back to the kind byte after a 0
    jz      2f
    cmp     byte ptr [rcx+rax-1], 0
    je      2f
    dec     eax
    jmp     1b
2:  cmp     eax, edi                    # (the kind byte: the text after it)
    jge     21f
    inc     eax
21: test    eax, eax
    jnz     22f
    inc     eax
22: mov     edx, edi
3:  cmp     edx, [rip+ai_tx_len]
    jae     4f
    cmp     byte ptr [rcx+rdx], 0
    je      4f
    inc     edx
    jmp     3b
4:  ret

# ai_sel_copy -> eax = 1: the selection (if any) to the clipboard, its
#   messages a line each
ai_sel_copy:
    push    rbx
    push    r12
    push    r13
    mov     eax, [rip+ai_sel_a]
    mov     ecx, [rip+ai_sel_b]
    cmp     eax, ecx
    je      8f
    jl      1f
    xchg    eax, ecx
1:  mov     ebx, eax
    mov     r13d, ecx
    cmp     r13d, [rip+ai_tx_len]
    jbe     11f
    mov     r13d, [rip+ai_tx_len]
11: lea     r12, [rip+ai_copy_buf]
    xor     edx, edx
2:  cmp     ebx, r13d
    jae     4f
    lea     rcx, [rip+ai_tx]
    mov     al, [rcx+rbx]
    inc     ebx
    test    al, al
    jnz     3f
    mov     al, 10                      # a message's end: a new line, and its
    inc     ebx                         #  kind byte left out
3:  mov     [r12+rdx], al
    inc     edx
    jmp     2b
4:  mov     rdi, r12
    mov     esi, edx
    call    clip_copy
    lea     rdi, [rip+s_copied]
    call    log_line
    mov     eax, 1
    jmp     9f
8:  xor     eax, eax
9:  pop     r13
    pop     r12
    pop     rbx
    ret

# ai_sel_key(edi=evdev) -> eax = 1 when used: Ctrl+C over the AI Assistant
#   copies the text selected in it
.globl ai_sel_key
ai_sel_key:
    push    rbx
    mov     ebx, edi
    mov     eax, [rip+key_mods]
    and     eax, MOD_CTRL|MOD_ALT|MOD_SHIFT
    cmp     eax, MOD_CTRL
    jne     8f
    mov     edi, ebx
    call    kb_layout_code
    cmp     eax, 46                     # C
    jne     8f
    mov     eax, [rip+ai_sel_a]
    cmp     eax, [rip+ai_sel_b]
    je      8f
    mov     edi, [rip+ptr_x]            # the area under the pointer (hit_area
    mov     esi, [rip+ptr_y]            #  is stale over widgets)
    call    area_hit
    mov     edi, [rip+hit_area]
    test    edi, edi
    js      8f
    call    area_editor
    cmp     eax, ED_AI
    jne     8f
    call    ai_sel_copy
    pop     rbx
    ret
8:  xor     eax, eax
    pop     rbx
    ret

.section .bss
.align 8
ap_argv_ai:     .skip 8*48
ai_lines:       .skip 16*AI_MAXL        # the lines drawn: offset, bytes, x, y
ai_click_t:     .skip 8
ai_pad:         .skip 8
ai_nlines:      .skip 4
.section .data
.align 4
ai_sel_a:       .long 0                 # the selection: anchor, head (offsets)
ai_sel_b:       .long 0
.section .bss
ai_trline:      .skip 96
ai_copy_buf:    .skip TX_CAP+8
.section .rodata
s_empty_arr:    .asciz "[]"

.section .note.GNU-stack,"",@progbits
