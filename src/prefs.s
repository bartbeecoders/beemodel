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
pr_path:        .skip 512
pr_buf:         .skip 16384
pr_line:        .skip 64
pr_words:       .skip 64

.section .rodata
s_cfgdir:       .asciz "/.config/beemodel"
s_prefs:        .asciz "/prefs"
s_h_interface:  .asciz "Interface"
s_h_input:      .asciz "Input"
s_h_keymap:     .asciz "Keymap"
s_h_system:     .asciz "System"
s_h_files:      .asciz "Files"
s_h_ai:         .asciz "AI"
s_restart:      .asciz "Takes effect when BeeModel starts again."
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
.align 8
l_tabs:         .quad s_h_interface, s_h_input, s_h_keymap, s_h_system, s_h_files, s_h_ai
l_theme:        .quad s_dark, s_light, s_contrast
l_scale:        .quad s_75, s_100, s_125, s_150, s_175, s_200
scales:         .long 75, 100, 125, 150, 175, 200
l_tier:         .quad s_tenv, s_tr, s_te, s_tf
# word, variable, kind (0 int, 1 float)
pr_vars:        .quad w_scale, pr_scale, 0, w_tip, tip_ms, 0, w_emu3, pr_emu3, 0
                .quad w_orbit, pr_orbit, 1, w_autosave, pr_autosave, 0
                .quad w_threads, pr_threads, 0, w_jit, pr_jit, 0, w_mcp, pr_mcp, 0
                .quad w_tier, pr_tier, 0, w_theme, th_id, 0, w_gpu, pr_gpu_on, 0, 0

.section .data
.align 4
pr_gpu_on:      .long 1                 # (gpu_off is its opposite)

.text
OPERATOR op_edit_prefs, "edit.preferences", "Preferences...", do_prefs_open, doc="Open the Preferences editor (beside the active area)"

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

# do_prefs_open - a Preferences area beside the active one (or that one)
do_prefs_open:
    push    qword ptr [rip+op_arg]
    mov     qword ptr [rip+op_arg], 0
    lea     rdi, [rip+op_area_split_side]
    call    run_op
    lea     rdi, [rip+op_area_type_prefs]
    call    run_op
    pop     qword ptr [rip+op_arg]
    ret

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
4:  mov     rsi, rbx
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
    add     rsp, 8
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
    cmp     qword ptr [r12+16], 1
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
WIDGET wd_pf_tabs, WK_TABS, "prefs.tabs", aux=l_tabs, n=6
WIDGET wd_pf_scroll, WK_SCROLL, "prefs.page"
WIDGET wd_pf_theme, WK_ENUM, "prefs.theme", cb=theme_cb, aux=l_theme, n=3
WIDGET wd_pf_scale, WK_ENUM, "prefs.ui_scale", cb=scale_cb, aux=l_scale, n=6, tip="Everything bigger or smaller, on top of the screen's own scale"
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

ed_prefs_draw:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    mov     r12d, [rip+ed_y]
    add     r12d, 6
    lea     rdi, [rip+wd_pf_tabs]       # the sections
    mov     esi, [rip+ed_x]
    add     esi, 8
    mov     edx, r12d
    mov     ecx, [rip+ed_w]
    sub     ecx, 16
    lea     r8, [rip+pr_tab]
    xor     r9d, r9d
    call    wg
    add     r12d, WG_H+8
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
    mov     eax, [rip+pr_tab]
    cmp     eax, 5
    ja      .Lpf_end
    lea     rcx, [rip+pf_pages]
    jmp     [rcx+rax*8]

.Lpf_interface:
    lea     rdx, [rip+s_h_interface]
    call    pnl_heading
    mov     eax, [rip+th_id]
    mov     [rip+pr_theme], eax
    lea     rdi, [rip+wd_pf_theme]
    lea     r8, [rip+pr_theme]
    call    pnl_full
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
    call    pnl_full
    lea     rdi, [rip+wd_pf_tip]
    lea     r8, [rip+tip_ms]
    call    pnl_full
    jmp     .Lpf_end

.Lpf_input:
    lea     rdx, [rip+s_h_input]
    call    pnl_heading
    lea     rdi, [rip+wd_pf_emu3]
    lea     r8, [rip+pr_emu3]
    call    pnl_full
    lea     rdi, [rip+wd_pf_orbit]
    lea     r8, [rip+pr_orbit]
    call    pnl_full
    jmp     .Lpf_end

.Lpf_keymap:
    lea     rdx, [rip+s_h_keymap]
    call    pnl_heading
    lea     rdi, [rip+wd_pf_search]
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
    cmp     byte ptr [rip+pr_search], 0 # the search: in its name or label
    je      3f
    mov     rdi, [rbx+OP_NAME]
    lea     rsi, [rip+pr_search]
    call    has_word
    test    eax, eax
    jnz     3f
    mov     rdi, [rbx+OP_LABEL]
    lea     rsi, [rip+pr_search]
    call    has_word
    test    eax, eax
    jz      6f
3:  mov     edi, [rip+pnl_x]
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
4:  mov     r15, rdx
    mov     eax, [rip+pnl_w]
    imul    eax, eax, 45
    xor     edx, edx
    mov     ecx, 100
    div     ecx
    mov     rdx, r15
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
7:  lea     rdx, [rip+s_more]
    call    pnl_hint
8:  jmp     .Lpf_end

.Lpf_system:
    lea     rdx, [rip+s_h_system]
    call    pnl_heading
    lea     rdi, [rip+wd_pf_threads]
    lea     r8, [rip+pr_threads]
    call    pnl_full
    mov     eax, [rip+gpu_off]
    xor     eax, 1
    mov     [rip+pr_gpu], eax
    lea     rdi, [rip+wd_pf_gpu]
    lea     r8, [rip+pr_gpu]
    call    pnl_full
    lea     rdi, [rip+wd_pf_jit]
    lea     r8, [rip+pr_jit]
    call    pnl_full
    lea     rdx, [rip+s_restart]
    call    pnl_hint
    jmp     .Lpf_end

.Lpf_files:
    lea     rdx, [rip+s_h_files]
    call    pnl_heading
    lea     rdi, [rip+wd_pf_autosave]
    lea     r8, [rip+pr_autosave]
    call    pnl_full
    lea     rdi, [rip+wd_pf_libadd]
    xor     r8d, r8d
    call    pnl_full
    jmp     .Lpf_end

.Lpf_ai:
    lea     rdx, [rip+s_h_ai]
    call    pnl_heading
    mov     eax, [rip+pr_tier]
    inc     eax
    mov     [rip+pr_tierv], eax
    lea     rdi, [rip+wd_pf_tier]
    lea     r8, [rip+pr_tierv]
    call    pnl_full
    lea     rdi, [rip+wd_pf_mcp]
    lea     r8, [rip+pr_mcp]
    call    pnl_full
    lea     rdx, [rip+s_restart]
    call    pnl_hint

.Lpf_end:
    mov     edi, r12d
    call    wg_scroll_end
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

.section .rodata
.align 8
pf_pages:       .quad .Lpf_interface, .Lpf_input, .Lpf_keymap, .Lpf_system, .Lpf_files, .Lpf_ai
.text

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
