# =============================================================================
#  BeeModel - preferences: the Preferences editor and ~/.config/beemodel/
#  prefs (a "word value" line each, read at start-up, written on a change).
#
#    Interface  theme, UI scale (75 - 200 % on top of the compositor's),
#               tooltip delay
#    Input      Alt + left button as the middle one, orbit speed
#    Keymap     every operator's key: search, Set (the next key pressed),
#               Clear, Reset All; a key already taken is said
#    System     threads, the GPU, the JIT (threads, JIT: at the next start)
#    Files      autosave, library folders
#    AI         the agents' permission at start, MCP on / off (next start)
#
#  The Preferences dialog (Edit > Preferences, Ctrl+Comma) and the
#  Preferences area show the same thing: a search, the categories, and the
#  category's settings with Reset to Defaults.
#
#  Keys set here are overrides of the operators' own (bee_ops is read-only):
#  key_eff gives the key in use.
# =============================================================================
.intel_syntax noprefix
.include "const.inc"
.include "macros.inc"
.include "widgets.inc"

.globl pr_scale
.globl pr_emu3
.globl pr_orbit
.globl pr_autosave
.globl pr_threads
.globl pr_jit
.globl pr_mcp
.globl pr_tier
.globl tip_ms
.globl prefs_load
.globl prefs_save
.globl key_eff
.globl pr_capture
.globl prefs_key
.globl ed_prefs_draw
.globl pr_scene_defaults
.globl ai_extra
.globl ai_or_key
.globl ai_gk_model
.globl ai_gk_path
.globl ai_cl_model
.globl ai_cl_path
.globl ai_or_model
.globl ai_or_url
.globl ai_or_steps
.globl ai_gk_turns
.globl ai_cl_turns
.globl ai_prov
.globl prefs_dlg_draw

.equ MAXK,      128
.equ PK_SZ,     16                      # an override: the operator, its key

.section .data
.align 4
pr_scale:       .long 100               # the UI scale (%)
pr_emu3:        .long 0                 # Alt + left = middle button
pr_orbit:       .float 1.0              # orbit speed
pr_autosave:    .long 25                # changes between autosaves (0: never)
pr_threads:     .long 0                 # worker threads (0: one a CPU)
pr_jit:         .long 1
pr_mcp:         .long 1
pr_tier:        .long -1                # the agents' permission at start (-1: env)
tip_ms:         .long 500               # the rest before a tooltip
pr_grid:        .float 1.0              # Viewport: grid spacing (m), field of
pr_fov:         .long 50                #  view (degrees, vertical), clip start
pr_near:        .float 0.05             #  (m)
pr_rw:          .long 960               # Rendering: new scenes' size, samples,
pr_rh:          .long 540               #  denoise
pr_rspp:        .long 128
pr_rdn:         .long 1
ai_prov:        .long 0                 # AI: the connection (0 Claude Code, 1
ai_cl_turns:    .long 40                #  Grok CLI, 2 OpenRouter), turn limits
ai_gk_turns:    .long 40
ai_or_steps:    .long 30
ai_or_url:      .asciz "https://openrouter.ai/api/v1"
                .skip 256-29
ai_or_model:    .asciz "anthropic/claude-sonnet-4.5"
                .skip 256-28

.section .bss
.align 8
pr_keys:        .skip MAXK*PK_SZ
pr_nkey:        .skip 4
pr_capture:     .skip 8                 # the operator waiting for a key
pr_tab:         .skip 4
pr_scroll:      .skip 4
pr_sel_scale:   .skip 4
pr_theme:       .skip 4
pr_gpu:         .skip 4
pr_tierv:       .skip 4
pr_search:      .skip 64
ai_cl_path:     .skip 256               # AI: paths (empty: on PATH), models
ai_cl_model:    .skip 256               #  (empty: the CLI's own), the key
ai_gk_path:     .skip 256
ai_gk_model:    .skip 256
ai_or_key:      .skip 256
ai_extra:       .skip 256               # added to the system prompt
pr_find:        .skip 64                # the Preferences' search
pf_shown:       .skip 4
                 # settings drawn (a search: none?)
pr_path:        .skip 512
pr_buf:         .skip 16384
pr_line:        .skip 64
pr_words:       .skip 64

.section .rodata
s_cfgdir:       .asciz "/.config/beemodel"
s_prefs:        .asciz "/prefs"
s_secrets:      .asciz "/secrets"
w_orkey:        .asciz "openrouter_key"
s_h_interface:  .asciz "Interface"
s_h_input:      .asciz "Input"
s_h_keymap:     .asciz "Keymap"
s_h_system:     .asciz "System"
s_h_files:      .asciz "Files"
s_h_ai:         .asciz "AI"
s_restart:      .asciz "Takes effect when BeeModel starts again."
s_rn_hint:      .asciz "For new scenes: a scene keeps its own (the Render area)."
s_press:        .asciz "press a key (Esc: never mind)"
s_none:         .asciz "-"
s_taken:        .asciz "  that key is also: "
s_dark:         .asciz "Dark"
s_light:        .asciz "Light"
s_contrast:     .asciz "High contrast"
s_75:           .asciz "75 %"
s_100:          .asciz "100 %"
s_125:          .asciz "125 %"
s_150:          .asciz "150 %"
s_175:          .asciz "175 %"
s_200:          .asciz "200 %"
s_tr:           .asciz "Read only"
s_te:           .asciz "May edit"
s_tf:           .asciz "Edit and files"
s_p_claude:     .asciz "Claude Code"
s_p_grok:       .asciz "Grok CLI"
s_p_or:         .asciz "OpenRouter"
s_h_cl:         .asciz "Claude Code"
s_h_gk:         .asciz "Grok CLI"
s_h_or:         .asciz "OpenRouter"
s_h_agents:     .asciz "Agents"
c_prov:         .asciz "The AI Assistant uses"
s_tenv:         .asciz "As started (BEEMODEL_AGENT_PERMISSION)"
s_more:         .asciz "type to narrow the list"
# the file's words
w_scale:        .asciz "scale"
w_theme:        .asciz "theme"
w_tip:          .asciz "tooltip_ms"
w_emu3:         .asciz "emulate_middle"
w_orbit:        .asciz "orbit_speed"
w_autosave:     .asciz "autosave"
w_threads:      .asciz "threads"
w_jit:          .asciz "jit"
w_gpu:          .asciz "gpu"
w_mcp:          .asciz "mcp"
w_tier:         .asciz "agent_permission"
w_key:          .asciz "key"
w_welcome:      .asciz "welcome"
w_cbaxes:       .asciz "colorblind_axes"
w_grid:         .asciz "grid"
w_gridsz:       .asciz "grid_size"
w_fov:          .asciz "fov"
w_near:         .asciz "clip_start"
w_rw:           .asciz "render_width"
w_rh:           .asciz "render_height"
w_rspp:         .asciz "render_samples"
w_rdn:          .asciz "render_denoise"
w_aiprov:       .asciz "ai_connection"
w_clpath:       .asciz "claude_path"
w_clmodel:      .asciz "claude_model"
w_clturns:      .asciz "claude_turns"
w_gkpath:       .asciz "grok_path"
w_gkmodel:      .asciz "grok_model"
w_gkturns:      .asciz "grok_turns"
w_orurl:        .asciz "openrouter_url"
w_ormodel:      .asciz "openrouter_model"
w_orsteps:      .asciz "openrouter_steps"
w_aiextra:      .asciz "ai_prompt"
.align 8
l_tabs:         .quad s_h_interface, s_h_input, s_h_keymap, s_h_system, s_h_files, s_h_ai
l_theme:        .quad s_dark, s_light, s_contrast
l_scale:        .quad s_75, s_100, s_125, s_150, s_175, s_200
scales:         .long 75, 100, 125, 150, 175, 200
l_tier:         .quad s_tenv, s_tr, s_te, s_tf
l_prov:         .quad s_p_claude, s_p_grok, s_p_or
# word, variable, kind (0 int, 1 float)
pr_vars:        .quad w_scale, pr_scale, 0, w_tip, tip_ms, 0, w_emu3, pr_emu3, 0
                .quad w_orbit, pr_orbit, 1, w_autosave, pr_autosave, 0
                .quad w_threads, pr_threads, 0, w_jit, pr_jit, 0, w_mcp, pr_mcp, 0
                .quad w_tier, pr_tier, 0, w_theme, th_id, 0, w_gpu, pr_gpu_on, 0
                .quad w_welcome, pr_welcome, 0, w_cbaxes, pr_cbaxes, 0
                .quad w_grid, show_grid, 0, w_gridsz, pr_grid, 1, w_fov, pr_fov, 0
                .quad w_near, pr_near, 1, w_rw, pr_rw, 0, w_rh, pr_rh, 0
                .quad w_rspp, pr_rspp, 0, w_rdn, pr_rdn, 0
                .quad w_aiprov, ai_prov, 0, w_clturns, ai_cl_turns, 0, w_gkturns, ai_gk_turns, 0
                .quad w_orsteps, ai_or_steps, 0
                .quad w_clpath, ai_cl_path, 2, w_clmodel, ai_cl_model, 2
                .quad w_gkpath, ai_gk_path, 2, w_gkmodel, ai_gk_model, 2
                .quad w_orurl, ai_or_url, 2, w_ormodel, ai_or_model, 2, w_aiextra, ai_extra, 2, 0

.section .data
.align 4
pr_gpu_on:      .long 1                 # (gpu_off is its opposite)
pf_pick:        .long -1                # a category picked while searching

.text
OPERATOR op_edit_prefs, "edit.preferences", "Preferences...", do_prefs_open, key=51|KM_CTRL, doc="Open the Preferences (Ctrl+Comma): interface, input, keymap, system, files and the AI connections"

OPERATOR op_ui_scale, "view.ui_scale", "UI Scale", do_ui_scale, flags=OPF_AI_SAFE|OPF_QUIET, doc="Make everything bigger or smaller, on top of the screen's own scale: view.ui_scale <75..200> (percent; kept in the preferences)"

# do_ui_scale - view.ui_scale <percent>
do_ui_scale:
    sub     rsp, 8
    mov     rsi, [rip+op_arg]
    test    rsi, rsi
    jz      9f
    mov     rdx, rsi                    # (to its end)
1:  cmp     byte ptr [rdx], 0
    je      2f
    inc     rdx
    jmp     1b
2:  call    parse_float
    test    eax, eax
    jz      9f
    cvttss2si eax, xmm0
    mov     [rip+pr_scale], eax
    call    pr_apply                    # (clamped)
    call    scale_now
9:  add     rsp, 8
    ret

# scale_now - the UI scale in use, now
scale_now:
    sub     rsp, 8
    call    win_from_comp
    call    ui_scale_apply
    call    fonts_resize
    call    prefs_save
    add     rsp, 8
    mov     dword ptr [rip+redraw_again], 1
    mov     dword ptr [rip+dirty], 1
    ret

# do_prefs_open - the Preferences dialog (dialog.s)
do_prefs_open:
    jmp     dlg_open_prefs

# ---- key overrides ----------------------------------------------------------------
# key_eff(rdi=op) -> eax = its key in use (an override, or its own); keeps
#   every other register
key_eff:
    push    rcx
    push    rdx
    lea     rdx, [rip+pr_keys]
    mov     ecx, [rip+pr_nkey]
1:  test    ecx, ecx
    jz      2f
    cmp     [rdx], rdi
    je      3f
    add     rdx, PK_SZ
    dec     ecx
    jmp     1b
3:  mov     eax, [rdx+8]
    pop     rdx
    pop     rcx
    ret
2:  mov     eax, [rdi+OP_KEY]
    pop     rdx
    pop     rcx
    ret

# key_set(rdi=op, esi=key) - an override (the op's own key: none kept)
key_set:
    lea     rdx, [rip+pr_keys]
    mov     ecx, [rip+pr_nkey]
1:  test    ecx, ecx
    jz      2f
    cmp     [rdx], rdi
    je      3f
    add     rdx, PK_SZ
    dec     ecx
    jmp     1b
2:  mov     eax, [rip+pr_nkey]
    cmp     eax, MAXK
    jae     9f
    inc     dword ptr [rip+pr_nkey]
    mov     [rdx], rdi
3:  mov     [rdx+8], esi
    cmp     esi, [rdi+OP_KEY]           # (back to its own: drop it)
    jne     9f
    mov     ecx, [rip+pr_nkey]          # the last one moves into its place
    dec     ecx
    mov     [rip+pr_nkey], ecx
    shl     ecx, 4
    lea     rax, [rip+pr_keys]
    mov     rsi, [rax+rcx]
    mov     [rdx], rsi
    mov     esi, [rax+rcx+8]
    mov     [rdx+8], esi
9:  ret

# prefs_key(edi=evdev key) -> eax = 1 when it was taken: the key waited for
prefs_key:
    mov     rax, [rip+pr_capture]
    test    rax, rax
    jnz     1f
    xor     eax, eax
    ret
1:  push    rbx
    push    r12
    sub     rsp, 8
    mov     ebx, edi
    cmp     ebx, KEY_ESC                # never mind
    je      8f
    cmp     ebx, 29                     # (modifiers alone: wait on)
    je      9f
    cmp     ebx, 42
    je      9f
    cmp     ebx, 54
    je      9f
    cmp     ebx, 56
    je      9f
    cmp     ebx, 97
    je      9f
    cmp     ebx, 100
    je      9f
    mov     edi, ebx                    # the binding, as the keymap reads it
    call    kb_layout_code
    mov     r12d, eax
    call    kb_canon_mods
    shl     eax, 16
    or      r12d, eax
    mov     rdi, [rip+pr_capture]
    mov     esi, r12d
    call    key_set
    call    key_conflict
    call    prefs_save
8:  mov     qword ptr [rip+pr_capture], 0
9:  mov     dword ptr [rip+dirty], 1
    mov     eax, 1
    add     rsp, 8
    pop     r12
    pop     rbx
    ret

# key_conflict(r12d=key; pr_capture = the op) - says which other operators
#   have that key too (a warning toast)
key_conflict:
    push    rbx
    push    r13
    sub     rsp, 8
    lea     rbx, [rip+__start_bee_ops]
1:  lea     rax, [rip+__stop_bee_ops]
    cmp     rbx, rax
    jae     9f
    cmp     rbx, [rip+pr_capture]
    je      2f
    mov     rdi, rbx
    call    key_eff
    cmp     eax, r12d
    jne     2f
    call    fmt_reset
    lea     rdi, [rip+s_taken]
    call    fmt_str
    mov     rdi, [rbx+OP_LABEL]
    call    fmt_str
    mov     dword ptr [rip+toast_warn], 1
    lea     rdi, [rip+fmt_buf]
    call    log_line
    jmp     9f
2:  add     rbx, OP_SIZE
    jmp     1b
9:  add     rsp, 8
    pop     r13
    pop     rbx
    ret

# ---- the file ---------------------------------------------------------------------
pr_file:                                # -> pr_path
    sub     rsp, 8
    lea     rdi, [rip+s_cfgdir]
    call    home_join
    lea     rdi, [rip+pr_path]
    mov     rsi, rax
    call    pcpy
    lea     rsi, [rip+s_prefs]
    call    pcpy
    add     rsp, 8
    ret

# prefs_load - at start-up (before the window, the threads and MCP)
prefs_load:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    call    pr_file
    lea     rdi, [rip+pr_path]
    call    file_read
    test    rax, rax
    jz      9f
    mov     rbx, rax
    lea     r12, [rax+rdx]              # (the end)
    mov     r14, rax
    mov     r15, rdx
.Lpl_line:
    cmp     rbx, r12
    jae     .Lpl_done
    mov     rsi, rbx                    # the word
    lea     rdi, [rip+pr_line]
    xor     ecx, ecx
1:  cmp     rsi, r12
    jae     2f
    mov     al, [rsi]
    cmp     al, ' '
    je      2f
    cmp     al, 10
    je      2f
    cmp     ecx, 62
    jae     11f
    mov     [rdi+rcx], al
    inc     ecx
11: inc     rsi
    jmp     1b
2:  mov     byte ptr [rdi+rcx], 0
    mov     rbx, rsi
    lea     rdi, [rip+pr_line]          # "key <op> <code>"
    lea     rsi, [rip+w_key]
    call    str_eq
    test    eax, eax
    jnz     .Lpl_key
    lea     r13, [rip+pr_vars]          # a variable
3:  mov     rsi, [r13]
    test    rsi, rsi
    jz      .Lpl_next
    lea     rdi, [rip+pr_line]
    call    str_eq
    test    eax, eax
    jnz     4f
    add     r13, 24
    jmp     3b
4:  cmp     qword ptr [r13+16], 2   # text: the rest of the line
    jne     41f
    mov     rdi, [r13+8]
    call    pr_rest
    jmp     .Lpl_next
41: mov     rsi, rbx
    mov     rdx, r12
    call    parse_float
    mov     rbx, rsi
    test    eax, eax
    jz      .Lpl_next
    mov     rdi, [r13+8]
    cmp     qword ptr [r13+16], 1
    je      5f
    cvttss2si eax, xmm0
    mov     [rdi], eax
    jmp     .Lpl_next
5:  movss   [rdi], xmm0
    jmp     .Lpl_next
.Lpl_key:
    mov     rsi, rbx                    # the operator's name
6:  cmp     rsi, r12
    jae     .Lpl_next
    cmp     byte ptr [rsi], ' '
    jne     61f
    inc     rsi
    jmp     6b
61: lea     rdi, [rip+pr_words]
    xor     ecx, ecx
62: cmp     rsi, r12
    jae     63f
    mov     al, [rsi]
    cmp     al, ' '
    je      63f
    cmp     al, 10
    je      63f
    cmp     ecx, 62
    jae     621f
    mov     [rdi+rcx], al
    inc     ecx
621:inc     rsi
    jmp     62b
63: mov     byte ptr [rdi+rcx], 0
    mov     rdx, r12
    call    parse_float
    mov     rbx, rsi
    test    eax, eax
    jz      .Lpl_next
    cvttss2si r13d, xmm0
    lea     rdi, [rip+pr_words]
    call    find_op_by_name
    test    rax, rax
    jz      .Lpl_next
    mov     rdi, rax
    mov     esi, r13d
    call    key_set
.Lpl_next:
    cmp     rbx, r12                    # on past the line
    jae     .Lpl_done
    mov     al, [rbx]
    inc     rbx
    cmp     al, 10
    jne     .Lpl_next
    jmp     .Lpl_line
.Lpl_done:
    mov     rdi, r14
    mov     rsi, r15
    call    file_unmap
    call    sec_load                    # (the secrets: their own file)
    call    pr_apply
9:  pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# pr_apply - what the values mean now (sane ranges, the GPU, the theme)
pr_apply:
    sub     rsp, 8
    mov     eax, [rip+pr_scale]         # 75 .. 200 %
    cmp     eax, 75
    jge     1f
    mov     eax, 75
1:  cmp     eax, 200
    jle     2f
    mov     eax, 200
2:  mov     [rip+pr_scale], eax
    mov     eax, [rip+pr_gpu_on]
    xor     eax, 1
    and     eax, 1
    mov     [rip+gpu_off], eax
    mov     edi, [rip+th_id]
    cmp     edi, 2
    jbe     3f
    xor     edi, edi
3:  call    th_set
    movss   xmm0, [rip+pr_grid]         # the viewport: grid, clip, field of view
    maxss   xmm0, [rip+pf_gmin]
    movss   [rip+pr_grid], xmm0
    movss   [rip+vp_grid], xmm0
    movss   xmm0, [rip+pr_near]
    maxss   xmm0, [rip+pf_nmin]
    movss   [rip+pr_near], xmm0
    movss   [rip+vp_near], xmm0
    mov     eax, [rip+pr_fov]           # 10 .. 120 degrees: k = 0.5 / tan(fov / 2)
    cmp     eax, 10
    jge     4f
    mov     eax, 10
4:  cmp     eax, 120
    jle     5f
    mov     eax, 120
5:  mov     [rip+pr_fov], eax
    mov     dword ptr [rip+vp_focal_k], 0x3f88f5c3  # (50: the lens it always had)
    cmp     eax, 50
    je      6f
    mov     [rsp], eax
    fild    dword ptr [rsp]
    fmul    dword ptr [rip+pf_deg2]
    fptan
    fstp    st(0)
    fld     dword ptr [rip+pf_half]
    fdivrp  st(1), st(0)
    fstp    dword ptr [rip+vp_focal_k]
6:  mov     dword ptr [rip+dirty], 1
    add     rsp, 8
    ret

# pr_scene_defaults - a new scene's render settings: the preferences' (a leaf:
#   scene_defaults calls it unaligned)
pr_scene_defaults:
    mov     eax, [rip+pr_rw]
    mov     [rip+rn_w], eax
    mov     eax, [rip+pr_rh]
    mov     [rip+rn_h], eax
    mov     eax, [rip+pr_rspp]
    mov     [rip+rn_spp], eax
    mov     eax, [rip+pr_rdn]
    mov     [rip+rn_denoise], eax
    ret

# prefs_save - the file, from the values now
prefs_save:
    push    rbx
    push    r12
    push    r13
    lea     rbx, [rip+pr_buf]           # the end of the text
    mov     eax, [rip+gpu_off]
    xor     eax, 1
    mov     [rip+pr_gpu_on], eax
    lea     r12, [rip+pr_vars]
1:  mov     rsi, [r12]
    test    rsi, rsi
    jz      3f
    mov     rdi, rbx
    call    pcpy
    mov     byte ptr [rdi], ' '
    inc     rdi
    mov     rbx, rdi
    call    fmt_reset
    mov     rax, [r12+8]
    cmp     qword ptr [r12+16], 2       # (text: as it is)
    jne     11f
    mov     rdi, rbx
    mov     rsi, rax
    call    pcpy
    mov     byte ptr [rdi], 10
    lea     rbx, [rdi+1]
    add     r12, 24
    jmp     1b
11: cmp     qword ptr [r12+16], 1
    je      2f
    mov     edi, [rax]
    call    fmt_int
    jmp     21f
2:  movss   xmm0, [rax]
    call    fmt_val3
21: mov     rdi, rbx
    lea     rsi, [rip+fmt_buf]
    call    pcpy
    mov     byte ptr [rdi], 10
    lea     rbx, [rdi+1]
    add     r12, 24
    jmp     1b
3:  xor     r12d, r12d                  # the keys: "key <op> <code>"
4:  cmp     r12d, [rip+pr_nkey]
    jae     5f
    mov     eax, r12d
    shl     eax, 4
    lea     r13, [rip+pr_keys]
    add     r13, rax
    mov     rdi, rbx
    lea     rsi, [rip+w_key]
    call    pcpy
    mov     byte ptr [rdi], ' '
    inc     rdi
    mov     rax, [r13]
    mov     rsi, [rax+OP_NAME]
    call    pcpy
    mov     byte ptr [rdi], ' '
    inc     rdi
    mov     rbx, rdi
    call    fmt_reset
    mov     edi, [r13+8]
    call    fmt_int
    mov     rdi, rbx
    lea     rsi, [rip+fmt_buf]
    call    pcpy
    mov     byte ptr [rdi], 10
    lea     rbx, [rdi+1]
    inc     r12d
    jmp     4b
5:  call    pr_file
    lea     rdi, [rip+pr_path]
    lea     rsi, [rip+pr_buf]
    mov     rdx, rbx
    sub     rdx, rsi
    call    file_write_atomic
    pop     r13
    pop     r12
    pop     rbx
    ret

# pr_rest(rdi=out[256]; rbx = the line after its word, r12 = the end) - the
#   rest of the line, without the space before it (rbx moved on)
pr_rest:
    cmp     rbx, r12
    jae     3f
    cmp     byte ptr [rbx], ' '
    jne     1f
    inc     rbx
1:  xor     ecx, ecx
2:  cmp     rbx, r12
    jae     3f
    mov     al, [rbx]
    cmp     al, 10
    je      3f
    cmp     al, 13
    je      21f
    cmp     ecx, 255
    jae     21f
    mov     [rdi+rcx], al
    inc     ecx
21: inc     rbx
    jmp     2b
3:  mov     byte ptr [rdi+rcx], 0
    ret

# ---- the secrets: ~/.config/beemodel/secrets, 0600, never in prefs --------------
# sec_path -> pr_path = the secrets file
sec_path:
    sub     rsp, 8
    lea     rdi, [rip+s_cfgdir]
    call    home_join
    lea     rdi, [rip+pr_path]
    mov     rsi, rax
    call    pcpy
    lea     rsi, [rip+s_secrets]
    call    pcpy
    add     rsp, 8
    ret

# sec_load - "openrouter_key <key>"
sec_load:
    push    rbx
    push    r12
    push    r13
    call    sec_path
    lea     rdi, [rip+pr_path]
    call    file_read
    test    rax, rax
    jz      9f
    mov     r13, rax
    mov     rbx, rax
    lea     r12, [rax+rdx]
    push    rdx
    push    rdx
1:  cmp     rbx, r12                    # each line: its word, then the key
    jae     8f
    lea     rdi, [rip+pr_line]
    xor     ecx, ecx
2:  cmp     rbx, r12
    jae     3f
    mov     al, [rbx]
    cmp     al, ' '
    je      3f
    cmp     al, 10
    je      3f
    cmp     ecx, 62
    jae     21f
    mov     [rdi+rcx], al
    inc     ecx
21: inc     rbx
    jmp     2b
3:  mov     byte ptr [rdi+rcx], 0
    lea     rdi, [rip+pr_line]
    lea     rsi, [rip+w_orkey]
    call    str_eq
    test    eax, eax
    jz      4f
    lea     rdi, [rip+ai_or_key]
    call    pr_rest
4:  cmp     rbx, r12                    # (on past the line)
    jae     8f
    mov     al, [rbx]
    inc     rbx
    cmp     al, 10
    jne     4b
    jmp     1b
8:  pop     rsi
    pop     rsi
    mov     rdi, r13
    call    file_unmap
9:  pop     r13
    pop     r12
    pop     rbx
    ret

# sec_save - the secrets file (owner only)
sec_save:
    push    rbx
    lea     rdi, [rip+pr_buf]
    lea     rsi, [rip+w_orkey]
    call    pcpy
    mov     byte ptr [rdi], ' '
    inc     rdi
    lea     rsi, [rip+ai_or_key]
    call    pcpy
    mov     byte ptr [rdi], 10
    lea     rbx, [rdi+1]
    call    sec_path
    lea     rdi, [rip+pr_path]
    lea     rsi, [rip+pr_buf]
    mov     rdx, rbx
    sub     rdx, rsi
    call    file_write_private
    pop     rbx
    ret

pcpy:                                   # rdi = dest, rsi = text -> rdi at its 0
1:  mov     al, [rsi]
    mov     [rdi], al
    test    al, al
    jz      2f
    inc     rsi
    inc     rdi
    jmp     1b
2:  ret

# =============================================================================
#  The Preferences editor
# =============================================================================
WIDGET wd_pf_find, WK_TEXT, "prefs.search", "Search", tip="Find a setting in every category (its name or what it does)"
WIDGET wd_pf_c0, WK_ROW, "prefs.category.interface", "Interface"
WIDGET wd_pf_c1, WK_ROW, "prefs.category.viewport", "Viewport"
WIDGET wd_pf_c2, WK_ROW, "prefs.category.input", "Input"
WIDGET wd_pf_c3, WK_ROW, "prefs.category.keymap", "Keymap"
WIDGET wd_pf_c4, WK_ROW, "prefs.category.rendering", "Rendering"
WIDGET wd_pf_c5, WK_ROW, "prefs.category.system", "System"
WIDGET wd_pf_c6, WK_ROW, "prefs.category.files", "Files"
WIDGET wd_pf_c7, WK_ROW, "prefs.category.ai", "AI"
WIDGET wd_pf_grid, WK_TOGGLE, "prefs.grid", "Ground grid and axes", cb=save_cb, tip="The floor grid and the X / Z axes in the 3D viewport (Shift+G)"
WIDGET wd_pf_gridsz, WK_FLOAT, "prefs.grid_size", "Grid spacing (m)", 0.01, 1000.0, 0.01, 2, WGF_CLAMP, cb=apply_cb, tip="The distance between the grid's lines (every fifth is brighter)"
WIDGET wd_pf_fov, WK_INT, "prefs.fov", "Field of view (degrees)", 10.0, 120.0, 0.2, 0, WGF_CLAMP, cb=apply_cb, tip="How wide the 3D viewport sees, top to bottom (50: a normal lens)"
WIDGET wd_pf_near, WK_FLOAT, "prefs.clip_start", "Clip start (m)", 0.001, 10.0, 0.001, 3, WGF_CLAMP, cb=apply_cb, tip="Nothing closer to the viewport's eye than this is drawn"
WIDGET wd_pf_rw, WK_INT, "prefs.render_width", "Width (px)", 16.0, 8192.0, 1.0, 0, WGF_CLAMP, cb=save_cb, tip="New scenes render this wide (each scene keeps its own)"
WIDGET wd_pf_rh, WK_INT, "prefs.render_height", "Height (px)", 16.0, 8192.0, 1.0, 0, WGF_CLAMP, cb=save_cb, tip="New scenes render this high"
WIDGET wd_pf_rspp, WK_INT, "prefs.render_samples", "Samples", 1.0, 65536.0, 1.0, 0, WGF_CLAMP, cb=save_cb, tip="New scenes' samples per pixel"
WIDGET wd_pf_rdn, WK_TOGGLE, "prefs.render_denoise", "Denoise the finished render", cb=save_cb, tip="New scenes clean up the noise when a render ends"
WIDGET wd_pf_reset, WK_BUTTON, "prefs.reset", "Reset to Defaults", tip="Every setting of this category back to how BeeModel comes"
WIDGET wd_pf_close, WK_BUTTON, "prefs.close", "Close", flags=WGF_PRIMARY, aux=op_dlg_cancel, tip="Close the preferences (Esc): every change is already kept"
WIDGET wd_pf_scroll, WK_SCROLL, "prefs.page"
WIDGET wd_pf_theme, WK_ENUM, "prefs.theme", cb=theme_cb, aux=l_theme, n=3, tip="The colours of the whole window"
WIDGET wd_pf_scale, WK_ENUM, "prefs.ui_scale", cb=scale_cb, aux=l_scale, n=6, tip="Everything bigger or smaller, on top of the screen's own scale"
WIDGET wd_pf_cb,   WK_TOGGLE, "prefs.colorblind_axes", "Colour-blind-safe axis colours", cb=save_cb, tip="X, Y, Z in orange, sky blue and purple instead of red, green and blue"
WIDGET wd_pf_tip,  WK_INT, "prefs.tooltip_ms", "Tooltip delay (ms)", 0.0, 5000.0, 2.0, 0, WGF_CLAMP, cb=save_cb
WIDGET wd_pf_emu3, WK_TOGGLE, "prefs.emulate_middle", "Alt + left button is the middle button", cb=save_cb, tip="Orbit with Alt + drag on a touchpad or a two-button mouse"
WIDGET wd_pf_orbit, WK_FLOAT, "prefs.orbit_speed", "Orbit speed", 0.1, 5.0, 0.005, 2, WGF_CLAMP, cb=save_cb
WIDGET wd_pf_search, WK_TEXT, "prefs.key_search", "Find", tip="Part of an operator's name or label"
WIDGET wd_pf_kset, WK_BUTTON, "prefs.key_set", "Set", flags=WGF_COMPACT, tip="Then press the key (with Ctrl / Shift / Alt) for it"
WIDGET wd_pf_kclr, WK_BUTTON, "prefs.key_clear", "Clear", flags=WGF_COMPACT, tip="No key for it"
WIDGET wd_pf_kreset, WK_BUTTON, "prefs.keys_reset", "Reset All Keys", tip="Every operator back to its own key"
WIDGET wd_pf_threads, WK_INT, "prefs.threads", "Worker threads (0: one a CPU)", 0.0, 255.0, 0.05, 0, WGF_CLAMP, cb=save_cb
WIDGET wd_pf_gpu,  WK_TOGGLE, "prefs.gpu", "Render on the GPU when there is one", cb=gpu_cb
WIDGET wd_pf_jit,  WK_TOGGLE, "prefs.jit", "Compile node programs to machine code (JIT)", cb=save_cb
WIDGET wd_pf_autosave, WK_INT, "prefs.autosave", "Autosave every N changes (0: never)", 0.0, 10000.0, 0.1, 0, WGF_CLAMP, cb=save_cb
WIDGET wd_pf_libadd, WK_BUTTON, "prefs.library_add", "Add Library Folder...", aux=op_lb_add
WIDGET wd_pf_tier, WK_ENUM, "prefs.agent_permission", cb=tier_cb, aux=l_tier, n=4, tip="What AI agents may do when BeeModel starts"
WIDGET wd_pf_mcp,  WK_TOGGLE, "prefs.mcp", "Listen for MCP clients (AI agents)", cb=save_cb
WIDGET wd_pf_aiprov, WK_ENUM, "prefs.ai_connection", cb=save_cb, aux=l_prov, n=3, tip="Which connection the AI Assistant uses"
WIDGET wd_pf_clpath, WK_TEXT, "prefs.claude_path", "Program", cb=cb_clpath, tip="The claude program (empty: the one on PATH)"
WIDGET wd_pf_clmodel, WK_TEXT, "prefs.claude_model", "Model", cb=cb_clmodel, tip="A model name or alias such as sonnet or opus (empty: Claude Code's default)"
WIDGET wd_pf_clturns, WK_INT, "prefs.claude_turns", "Turns at most", 1.0, 500.0, 0.2, 0, WGF_CLAMP, cb=save_cb, tip="How many rounds of tool calls one request may take"
WIDGET wd_pf_gkpath, WK_TEXT, "prefs.grok_path", "Program", cb=cb_gkpath, tip="The grok program (empty: the one on PATH)"
WIDGET wd_pf_gkmodel, WK_TEXT, "prefs.grok_model", "Model", cb=cb_gkmodel, tip="A Grok model name (empty: the CLI's default)"
WIDGET wd_pf_gkturns, WK_INT, "prefs.grok_turns", "Turns at most", 1.0, 500.0, 0.2, 0, WGF_CLAMP, cb=save_cb, tip="How many rounds of tool calls one request may take"
WIDGET wd_pf_orkey, WK_TEXT, "prefs.openrouter_key", "API key", flags=WGF_SECRET, cb=cb_orkey, tip="Your OpenRouter key: kept in ~/.config/beemodel/secrets (yours alone to read), never shown or logged (empty: OPENROUTER_API_KEY)"
WIDGET wd_pf_ormodel, WK_TEXT, "prefs.openrouter_model", "Model", cb=cb_ormodel, tip="Any OpenRouter model id with tool calling, such as anthropic/claude-sonnet-4.5 or openai/gpt-4.1"
WIDGET wd_pf_orurl, WK_TEXT, "prefs.openrouter_url", "Address", cb=cb_orurl, tip="The API's address (another OpenAI-compatible server works too)"
WIDGET wd_pf_orsteps, WK_INT, "prefs.openrouter_steps", "Steps at most", 1.0, 500.0, 0.2, 0, WGF_CLAMP, cb=save_cb, tip="How many rounds of tool calls one request may take"
WIDGET wd_pf_aiextra, WK_TEXT, "prefs.ai_prompt", "Also tell the AI", cb=cb_aiextra, tip="Text added to every request's instructions (a style, units, what to avoid)"

.section .rodata
.align 8
pf_cats:        .quad wd_pf_c0, wd_pf_c1, wd_pf_c2, wd_pf_c3, wd_pf_c4, wd_pf_c5, wd_pf_c6, wd_pf_c7
pf_pages:       .quad .Lpf_interface, .Lpf_viewport, .Lpf_input, .Lpf_keymap, .Lpf_render, .Lpf_system, .Lpf_files, .Lpf_ai
# the defaults, by category: category, variable, value (Reset to Defaults)
pf_defs:        .quad 0, th_id, 0, 0, pr_scale, 100, 0, tip_ms, 500, 0, pr_cbaxes, 0
                .quad 1, show_grid, 1, 1, pr_grid, 0x3f800000, 1, pr_fov, 50, 1, pr_near, 0x3d4ccccd
                .quad 2, pr_emu3, 0, 2, pr_orbit, 0x3f800000
                .quad 3, pr_nkey, 0
                .quad 4, pr_rw, 960, 4, pr_rh, 540, 4, pr_rspp, 128, 4, pr_rdn, 1
                .quad 5, pr_threads, 0, 5, pr_jit, 1, 5, pr_gpu_on, 1
                .quad 6, pr_autosave, 25
                .quad 7, pr_tier, -1, 7, pr_mcp, 1, 7, ai_prov, 0, 7, ai_cl_turns, 40
                .quad 7, ai_gk_turns, 40, 7, ai_or_steps, 30
                .quad -1
s_pf_title:     .asciz "Preferences"
s_pf_found:     .asciz "Settings found"
s_pf_nothing:   .asciz "No setting matches."
s_pf_hint:      .asciz "Search settings"
c_theme:        .asciz "Theme"
c_scale:        .asciz "UI scale"
c_tier:         .asciz "AI agents may"
.align 4
pf_gmin:        .float 0.01
pf_nmin:        .float 0.001
pf_deg2:        .float 0.008726646          # pi / 360: half the angle, radians
pf_half:        .float 0.5
.text

# pf_body(edi=x, esi=y, edx=w, ecx=h) - the category list (with the search
#   above it) and the page beside it, in that rectangle (the Preferences
#   area, or the dialog)
.equ PF_SIDE,   176
pf_body:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    push    rbp
    sub     rsp, 24
    mov     eax, [rip+ed_x]             # (the area's rectangle, kept)
    mov     [rsp], eax
    mov     eax, [rip+ed_y]
    mov     [rsp+4], eax
    mov     eax, [rip+ed_w]
    mov     [rsp+8], eax
    mov     eax, [rip+ed_h]
    mov     [rsp+12], eax
    mov     ebx, edi
    mov     ebp, esi
    mov     r14d, edx
    mov     r15d, ecx
    lea     r12d, [rbp+8]
    lea     rdi, [rip+wd_pf_find]       # search
    lea     esi, [rbx+8]
    mov     edx, r12d
    mov     ecx, PF_SIDE-16
    lea     r8, [rip+pr_find]
    xor     r9d, r9d
    call    wg
    cmp     byte ptr [rip+pr_find], 0   # (a hint while it is empty)
    jne     61f
    call    wg_editing
    test    eax, eax
    jnz     61f
    lea     edi, [rbx+16]
    lea     esi, [r12+3]
    lea     rdx, [rip+s_pf_hint]
    mov     ecx, COL_TEXT_OFF
    call    draw_small
61: add     r12d, WG_H+12
    mov     eax, [rip+pf_pick]          # a category picked while searching
    mov     dword ptr [rip+pf_pick], -1
    test    eax, eax
    js      0f
    cmp     byte ptr [rip+pr_find], 0
    je      0f
    mov     [rip+pr_tab], eax
    mov     byte ptr [rip+pr_find], 0
    mov     dword ptr [rip+pr_scroll], 0
0:  xor     r13d, r13d                  # the categories
1:  cmp     r13d, 8
    jae     2f
    lea     rax, [rip+pf_cats]
    mov     rdi, [rax+r13*8]
    lea     esi, [rbx+8]
    mov     edx, r12d
    mov     ecx, PF_SIDE-16
    lea     r8, [rip+pr_tab]
    cmp     byte ptr [rip+pr_find], 0   # (searching: none lit; a pick ends
    je      10f                         #  the search)
    lea     r8, [rip+pf_pick]
10: mov     r9d, r13d
    call    wg
11: lea     rax, [rip+pf_cats]
    mov     rax, [rax+r13*8]
    mov     rdx, [rax+WD_LABEL]
    lea     edi, [rbx+18]
    lea     esi, [r12+5]
    mov     ecx, COL_TEXT
    cmp     r13d, [rip+pr_tab]
    jne     12f
    cmp     byte ptr [rip+pr_find], 0
    jne     12f
    mov     ecx, COL_ACCENT
12: call    draw_small
    add     r12d, WG_H+4
    inc     r13d
    jmp     1b
2:  lea     edi, [rbx+PF_SIDE]          # a line between
    mov     esi, ebp
    mov     edx, 1
    mov     ecx, r15d
    mov     r8d, COL_SEPARATOR
    call    fill_rect
    lea     eax, [rbx+PF_SIDE+4]        # the page: the rest
    mov     [rip+ed_x], eax
    mov     [rip+ed_y], ebp
    mov     eax, r14d
    sub     eax, PF_SIDE+4
    mov     [rip+ed_w], eax
    mov     [rip+ed_h], r15d
    call    pf_page
    mov     eax, [rsp]
    mov     [rip+ed_x], eax
    mov     eax, [rsp+4]
    mov     [rip+ed_y], eax
    mov     eax, [rsp+8]
    mov     [rip+ed_w], eax
    mov     eax, [rsp+12]
    mov     [rip+ed_h], eax
    add     rsp, 24
    pop     rbp
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# ed_prefs_draw - the Preferences area: the same as the dialog
ed_prefs_draw:
    sub     rsp, 8
    mov     edi, [rip+ed_x]
    mov     esi, [rip+ed_y]
    mov     edx, [rip+ed_w]
    mov     ecx, [rip+ed_h]
    call    pf_body
    add     rsp, 8
    ret

# prefs_dlg_draw - the Preferences dialog's box (dialog.s has dimmed the
#   window): a title, Close, the categories and the page
prefs_dlg_draw:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    mov     r14d, [rip+win_w]           # as big as fits, at most 900 x 640
    sub     r14d, 60
    cmp     r14d, 900
    jle     1f
    mov     r14d, 900
1:  mov     r15d, [rip+win_h]
    sub     r15d, 60
    cmp     r15d, 640
    jle     2f
    mov     r15d, 640
2:  mov     ebx, [rip+win_w]            # centred
    sub     ebx, r14d
    sar     ebx, 1
    mov     r12d, [rip+win_h]
    sub     r12d, r15d
    sar     r12d, 1
    mov     edi, ebx
    mov     esi, r12d
    mov     edx, r14d
    mov     ecx, r15d
    mov     r8d, COL_DROP_BORDER
    call    popup_frame
    lea     edi, [rbx+18]               # the title, Close
    lea     esi, [r12+14]
    lea     rdx, [rip+s_pf_title]
    mov     ecx, COL_TEXT
    call    draw_heading
    lea     rdi, [rip+wd_pf_close]
    lea     esi, [rbx+r14-100]
    lea     edx, [r12+10]
    mov     ecx, 88
    xor     r8d, r8d
    xor     r9d, r9d
    call    wg
    lea     edi, [rbx+2]                # the body
    lea     esi, [r12+44]
    lea     edx, [r14-4]
    lea     ecx, [r15-48]
    call    pf_body
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# pf_page - the category's settings (the search: every category's that
#   match) in ed_x .. ed_h, with Reset to Defaults
pf_page:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    push    rbp
    sub     rsp, 8
    mov     dword ptr [rip+pf_shown], 0
    mov     r12d, [rip+ed_y]
    add     r12d, 8
    cmp     byte ptr [rip+pr_find], 0   # its title (or the search's)
    jne     1f
    mov     eax, [rip+pr_tab]
    cmp     eax, 7
    jbe     71f
    xor     eax, eax
    mov     [rip+pr_tab], eax
71: lea     rcx, [rip+pf_cats]
    mov     rax, [rcx+rax*8]
    mov     rdx, [rax+WD_LABEL]
    jmp     2f
1:  lea     rdx, [rip+s_pf_found]
2:  mov     edi, [rip+ed_x]
    add     edi, 14
    lea     esi, [r12+4]
    mov     ecx, COL_ACCENT
    call    draw_heading
    cmp     byte ptr [rip+pr_find], 0   # Reset to Defaults (a category)
    jne     3f
    lea     rdi, [rip+wd_pf_reset]
    mov     esi, [rip+ed_x]
    add     esi, [rip+ed_w]
    sub     esi, 170
    mov     edx, r12d
    mov     ecx, 156
    xor     r8d, r8d
    xor     r9d, r9d
    call    wg
    test    eax, eax
    jz      3f
    mov     edi, [rip+pr_tab]
    call    pf_reset
3:  add     r12d, WG_H+10
    lea     rdi, [rip+wd_pf_scroll]
    mov     esi, [rip+ed_x]
    mov     edx, r12d
    mov     ecx, [rip+ed_w]
    mov     r8d, [rip+ed_y]
    add     r8d, [rip+ed_h]
    sub     r8d, r12d
    lea     r9, [rip+pr_scroll]
    call    wg_scroll_begin
    mov     r12d, eax
    call    pnl_begin
    cmp     byte ptr [rip+pr_find], 0
    jne     .Lpf_all
    mov     eax, [rip+pr_tab]
    lea     rcx, [rip+pf_pages]
    lea     rax, [rcx+rax*8]
    call    [rax]
    jmp     .Lpf_done
.Lpf_all:                               # searching: every category's matches
    xor     ebx, ebx
4:  cmp     ebx, 8
    jae     5f
    lea     rcx, [rip+pf_pages]
    call    [rcx+rbx*8]
    inc     ebx
    jmp     4b
5:  cmp     dword ptr [rip+pf_shown], 0
    jne     .Lpf_done
    lea     rdx, [rip+s_pf_nothing]
    call    pnl_hint
.Lpf_done:
    mov     edi, r12d
    call    wg_scroll_end
    add     rsp, 8
    pop     rbp
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# pf_item(rdi=desc, r8=ptr, rdx=caption or 0) -> eax (wg's) - one setting
#   (searching: only if it matches), its caption at the left when given
pf_item:
    push    rbx
    push    r13
    push    r14
    mov     rbx, rdi
    mov     r13, r8
    mov     r14, rdx
    test    r14, r14                    # (a text field: its label as the
    jnz     1f                          #  caption)
    cmp     dword ptr [rbx+WD_KIND], WK_TEXT
    jne     1f
    mov     r14, [rbx+WD_LABEL]
1:
    cmp     byte ptr [rip+pr_find], 0
    je      2f
    mov     rdi, r14
    call    pf_match
    test    eax, eax
    jnz     2f
    mov     rdi, [rbx+WD_LABEL]
    call    pf_match
    test    eax, eax
    jnz     2f
    mov     rdi, [rbx+WD_TIP]
    call    pf_match
    test    eax, eax
    jnz     2f
    mov     rdi, [rbx+WD_NAME]
    call    pf_match
    test    eax, eax
    jnz     2f
    xor     eax, eax
    jmp     9f
2:  inc     dword ptr [rip+pf_shown]
    test    r14, r14
    jz      3f
    mov     rdx, r14
    call    pnl_caption
    mov     rdi, rbx
    mov     r8, r13
    call    pnl_right
    add     r12d, WG_H+4
    jmp     9f
3:  mov     rdi, rbx
    mov     r8, r13
    call    pnl_full
9:  pop     r14
    pop     r13
    pop     rbx
    ret

# pf_match(rdi=text or 0) -> eax = 1 when the search is in it
pf_match:
    xor     eax, eax
    test    rdi, rdi
    jz      1f
    lea     rsi, [rip+pr_find]
    jmp     has_word
1:  ret

# pf_head(rdx=heading) - a page's sub-heading (not while searching)
pf_head:
    cmp     byte ptr [rip+pr_find], 0
    jne     1f
    jmp     pnl_heading
1:  ret

# pf_reset(edi=category) - its settings back to the defaults
pf_reset:
    push    rbx
    push    r12
    sub     rsp, 8
    mov     r12d, edi
    lea     rbx, [rip+pf_defs]
1:  mov     rax, [rbx]
    cmp     rax, -1
    je      2f
    cmp     eax, r12d
    jne     11f
    mov     rcx, [rbx+8]
    mov     rax, [rbx+16]
    mov     [rcx], eax
11: add     rbx, 24
    jmp     1b
2:  call    pr_apply                    # (the theme, the GPU)
    call    scale_now                   # (the fonts; saved)
    add     rsp, 8
    pop     r12
    pop     rbx
    ret

# ---- the pages (r12d: the row; pnl_ set) --------------------------------------------
.Lpf_interface:
    push    rbx
    mov     eax, [rip+th_id]
    mov     [rip+pr_theme], eax
    lea     rdi, [rip+wd_pf_theme]
    lea     r8, [rip+pr_theme]
    lea     rdx, [rip+c_theme]
    call    pf_item
    xor     ecx, ecx                    # the scale: its place in the list
    lea     rax, [rip+scales]
1:  cmp     ecx, 5
    jae     2f
    mov     edx, [rax+rcx*4]
    cmp     edx, [rip+pr_scale]
    jge     2f
    inc     ecx
    jmp     1b
2:  mov     [rip+pr_sel_scale], ecx
    lea     rdi, [rip+wd_pf_scale]
    lea     r8, [rip+pr_sel_scale]
    lea     rdx, [rip+c_scale]
    call    pf_item
    lea     rdi, [rip+wd_pf_tip]
    lea     r8, [rip+tip_ms]
    xor     edx, edx
    call    pf_item
    lea     rdi, [rip+wd_pf_cb]
    lea     r8, [rip+pr_cbaxes]
    xor     edx, edx
    call    pf_item
    pop     rbx
    ret

.Lpf_viewport:
    push    rbx
    lea     rdi, [rip+wd_pf_grid]
    lea     r8, [rip+show_grid]
    xor     edx, edx
    call    pf_item
    lea     rdi, [rip+wd_pf_gridsz]
    lea     r8, [rip+pr_grid]
    xor     edx, edx
    call    pf_item
    lea     rdi, [rip+wd_pf_fov]
    lea     r8, [rip+pr_fov]
    xor     edx, edx
    call    pf_item
    lea     rdi, [rip+wd_pf_near]
    lea     r8, [rip+pr_near]
    xor     edx, edx
    call    pf_item
    pop     rbx
    ret

.Lpf_render:
    push    rbx
    lea     rdi, [rip+wd_pf_rw]
    lea     r8, [rip+pr_rw]
    xor     edx, edx
    call    pf_item
    lea     rdi, [rip+wd_pf_rh]
    lea     r8, [rip+pr_rh]
    xor     edx, edx
    call    pf_item
    lea     rdi, [rip+wd_pf_rspp]
    lea     r8, [rip+pr_rspp]
    xor     edx, edx
    call    pf_item
    lea     rdi, [rip+wd_pf_rdn]
    lea     r8, [rip+pr_rdn]
    xor     edx, edx
    call    pf_item
    cmp     byte ptr [rip+pr_find], 0
    jne     1f
    lea     rdx, [rip+s_rn_hint]
    call    pnl_hint
1:  pop     rbx
    ret

.Lpf_input:
    push    rbx
    lea     rdi, [rip+wd_pf_emu3]
    lea     r8, [rip+pr_emu3]
    xor     edx, edx
    call    pf_item
    lea     rdi, [rip+wd_pf_orbit]
    lea     r8, [rip+pr_orbit]
    xor     edx, edx
    call    pf_item
    pop     rbx
    ret

.Lpf_keymap:
    push    rbx
    push    r14
    push    r15
    sub     rsp, 16
    lea     r15, [rip+pr_search]        # (searching: the search narrows it)
    cmp     byte ptr [rip+pr_find], 0
    je      0f
    lea     r15, [rip+pr_find]
    jmp     1f
0:  lea     rdi, [rip+wd_pf_search]
    lea     r8, [rip+pr_search]
    call    pnl_full
    lea     rdi, [rip+wd_pf_kreset]
    xor     r8d, r8d
    call    pnl_full
    test    eax, eax
    jz      1f
    mov     dword ptr [rip+pr_nkey], 0
    call    prefs_save
1:  lea     rbx, [rip+__start_bee_ops]  # the operators: label, key, Set, Clear
    xor     r14d, r14d                  # (rows shown)
2:  lea     rax, [rip+__stop_bee_ops]
    cmp     rbx, rax
    jae     8f
    cmp     r14d, 60
    jae     7f
    test    dword ptr [rbx+OP_FLAGS], OPF_HIDDEN
    jnz     6f
    cmp     byte ptr [r15], 0           # the search: in its name or label
    je      3f
    mov     rdi, [rbx+OP_NAME]
    mov     rsi, r15
    call    has_word
    test    eax, eax
    jnz     3f
    mov     rdi, [rbx+OP_LABEL]
    mov     rsi, r15
    call    has_word
    test    eax, eax
    jz      6f
3:  inc     dword ptr [rip+pf_shown]
    mov     edi, [rip+pnl_x]
    lea     esi, [r12+3]
    mov     rdx, [rbx+OP_LABEL]
    mov     ecx, COL_TEXT
    call    draw_small
    lea     rdx, [rip+s_press]          # its key, or "press a key"
    cmp     rbx, [rip+pr_capture]
    je      4f
    mov     rdi, rbx
    call    key_eff
    mov     edi, eax
    lea     rdx, [rip+s_none]
    test    edi, edi
    jz      4f
    call    fmt_key
    mov     rdx, rax
    test    rdx, rdx
    jnz     4f
    lea     rdx, [rip+s_none]
4:  mov     [rsp], rdx
    mov     eax, [rip+pnl_w]
    imul    eax, eax, 45
    xor     edx, edx
    mov     ecx, 100
    div     ecx
    mov     rdx, [rsp]
    mov     edi, eax
    add     edi, [rip+pnl_x]
    lea     esi, [r12+3]
    mov     ecx, COL_ACCENT
    call    draw_small_keyed
    mov     esi, [rip+pnl_x]            # Set | Clear
    add     esi, [rip+pnl_w]
    sub     esi, 110
    lea     rdi, [rip+wd_pf_kset]
    mov     ecx, 52
    mov     edx, r12d
    xor     r8d, r8d
    mov     r9d, r14d
    call    wg
    test    eax, eax
    jz      5f
    mov     [rip+pr_capture], rbx
5:  mov     esi, [rip+pnl_x]
    add     esi, [rip+pnl_w]
    sub     esi, 54
    lea     rdi, [rip+wd_pf_kclr]
    mov     ecx, 54
    mov     edx, r12d
    xor     r8d, r8d
    mov     r9d, r14d
    call    wg
    test    eax, eax
    jz      51f
    mov     rdi, rbx
    xor     esi, esi
    call    key_set
    call    prefs_save
51: add     r12d, 22
    inc     r14d
6:  add     rbx, OP_SIZE
    jmp     2b
7:  cmp     byte ptr [rip+pr_find], 0
    jne     8f
    lea     rdx, [rip+s_more]
    call    pnl_hint
8:  add     rsp, 16
    pop     r15
    pop     r14
    pop     rbx
    ret

.Lpf_system:
    push    rbx
    lea     rdi, [rip+wd_pf_threads]
    lea     r8, [rip+pr_threads]
    xor     edx, edx
    call    pf_item
    mov     eax, [rip+gpu_off]
    xor     eax, 1
    mov     [rip+pr_gpu], eax
    lea     rdi, [rip+wd_pf_gpu]
    lea     r8, [rip+pr_gpu]
    xor     edx, edx
    call    pf_item
    lea     rdi, [rip+wd_pf_jit]
    lea     r8, [rip+pr_jit]
    xor     edx, edx
    call    pf_item
    cmp     byte ptr [rip+pr_find], 0
    jne     1f
    lea     rdx, [rip+s_restart]
    call    pnl_hint
1:  pop     rbx
    ret

.Lpf_files:
    push    rbx
    lea     rdi, [rip+wd_pf_autosave]
    lea     r8, [rip+pr_autosave]
    xor     edx, edx
    call    pf_item
    lea     rdi, [rip+wd_pf_libadd]
    xor     r8d, r8d
    xor     edx, edx
    call    pf_item
    pop     rbx
    ret

.Lpf_ai:
    push    rbx
    lea     rdi, [rip+wd_pf_aiprov]
    lea     r8, [rip+ai_prov]
    lea     rdx, [rip+c_prov]
    call    pf_item
    lea     rdi, [rip+wd_pf_aiextra]
    lea     r8, [rip+ai_extra]
    xor     edx, edx
    call    pf_item
    lea     rdx, [rip+s_h_cl]
    call    pf_head
    lea     rdi, [rip+wd_pf_clpath]
    lea     r8, [rip+ai_cl_path]
    xor     edx, edx
    call    pf_item
    lea     rdi, [rip+wd_pf_clmodel]
    lea     r8, [rip+ai_cl_model]
    xor     edx, edx
    call    pf_item
    lea     rdi, [rip+wd_pf_clturns]
    lea     r8, [rip+ai_cl_turns]
    xor     edx, edx
    call    pf_item
    lea     rdx, [rip+s_h_gk]
    call    pf_head
    lea     rdi, [rip+wd_pf_gkpath]
    lea     r8, [rip+ai_gk_path]
    xor     edx, edx
    call    pf_item
    lea     rdi, [rip+wd_pf_gkmodel]
    lea     r8, [rip+ai_gk_model]
    xor     edx, edx
    call    pf_item
    lea     rdi, [rip+wd_pf_gkturns]
    lea     r8, [rip+ai_gk_turns]
    xor     edx, edx
    call    pf_item
    lea     rdx, [rip+s_h_or]
    call    pf_head
    lea     rdi, [rip+wd_pf_orkey]
    lea     r8, [rip+ai_or_key]
    xor     edx, edx
    call    pf_item
    lea     rdi, [rip+wd_pf_ormodel]
    lea     r8, [rip+ai_or_model]
    xor     edx, edx
    call    pf_item
    lea     rdi, [rip+wd_pf_orurl]
    lea     r8, [rip+ai_or_url]
    xor     edx, edx
    call    pf_item
    lea     rdi, [rip+wd_pf_orsteps]
    lea     r8, [rip+ai_or_steps]
    xor     edx, edx
    call    pf_item
    lea     rdx, [rip+s_h_agents]
    call    pf_head
    mov     eax, [rip+pr_tier]
    inc     eax
    mov     [rip+pr_tierv], eax
    lea     rdi, [rip+wd_pf_tier]
    lea     r8, [rip+pr_tierv]
    lea     rdx, [rip+c_tier]
    call    pf_item
    lea     rdi, [rip+wd_pf_mcp]
    lea     r8, [rip+pr_mcp]
    xor     edx, edx
    call    pf_item
    cmp     byte ptr [rip+pr_find], 0
    jne     1f
    lea     rdx, [rip+s_restart]
    call    pnl_hint
1:  pop     rbx
    ret

draw_small_keyed:                       # (the key's text)
    jmp     draw_small

# has_word(rdi=text, rsi=word) -> eax = 1 when the word is in it (any case)
has_word:
1:  xor     ecx, ecx
2:  movzx   eax, byte ptr [rsi+rcx]
    test    eax, eax
    jz      7f
    movzx   edx, byte ptr [rdi+rcx]
    test    edx, edx
    jz      8f
    or      eax, 0x20
    or      edx, 0x20
    cmp     eax, edx
    jne     3f
    inc     ecx
    jmp     2b
3:  inc     rdi
    cmp     byte ptr [rdi], 0
    jne     1b
8:  xor     eax, eax
    ret
7:  mov     eax, 1
    ret

# ---- callbacks: a change is saved at once ------------------------------------------
# the texts (longer than a field keeps by itself): copied, then saved
.macro TEXTCB name, buf
\name:
    lea     rsi, [rip+\buf]
    jmp     text_cb
.endm
TEXTCB cb_clpath, ai_cl_path
TEXTCB cb_clmodel, ai_cl_model
TEXTCB cb_gkpath, ai_gk_path
TEXTCB cb_gkmodel, ai_gk_model
TEXTCB cb_ormodel, ai_or_model
TEXTCB cb_orurl, ai_or_url
TEXTCB cb_aiextra, ai_extra
text_cb:                                # rdi = the text, rsi = where (256)
    xor     ecx, ecx
1:  mov     al, [rdi+rcx]
    mov     [rsi+rcx], al
    test    al, al
    jz      2f
    inc     ecx
    cmp     ecx, 255
    jb      1b
    mov     byte ptr [rsi+rcx], 0
2:  jmp     save_cb
cb_orkey:                               # the key: the secrets file only
    lea     rsi, [rip+ai_or_key]
    xor     ecx, ecx
1:  mov     al, [rdi+rcx]
    mov     [rsi+rcx], al
    test    al, al
    jz      2f
    inc     ecx
    cmp     ecx, 255
    jb      1b
    mov     byte ptr [rsi+rcx], 0
2:  sub     rsp, 8
    call    sec_save
    add     rsp, 8
    ret
apply_cb:                               # (what it means now: the viewport)
    sub     rsp, 8
    call    pr_apply
    call    prefs_save
    add     rsp, 8
    ret
save_cb:
    sub     rsp, 8
    call    prefs_save
    add     rsp, 8
    ret
theme_cb:                               # rdi = &pr_theme
    mov     edi, [rdi]
    sub     rsp, 8
    call    th_set
    call    prefs_save
    add     rsp, 8
    mov     dword ptr [rip+dirty], 1
    ret
scale_cb:                               # rdi = &pr_sel_scale: the UI scale
    mov     eax, [rdi]
    lea     rcx, [rip+scales]
    mov     eax, [rcx+rax*4]
    mov     [rip+pr_scale], eax
    jmp     scale_now
gpu_cb:                                 # rdi = &pr_gpu
    mov     eax, [rdi]
    xor     eax, 1
    mov     [rip+gpu_off], eax
    jmp     save_cb
tier_cb:                                # rdi = &pr_tierv
    mov     eax, [rdi]
    dec     eax
    mov     [rip+pr_tier], eax
    jmp     save_cb

.section .note.GNU-stack,"",@progbits
