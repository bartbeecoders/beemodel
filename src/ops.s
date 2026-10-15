# =============================================================================
#  BeeModel - operator spine: the application's operator table, the runner,
#  key dispatch and shortcut formatting.
#
#  Add an action = add one OPERATOR line (in any module) and reference it from
#  a menu or tool list if it should appear there. Its key binding, shortcut
#  label, console echo and --list-ops entry come for free.
# =============================================================================
.intel_syntax noprefix
.include "const.inc"
.include "macros.inc"

.globl run_op
.globl op_checked
.globl op_poll
.globl poll_undo
.globl poll_redo
.globl poll_sel
.globl poll_two
.globl poll_render
.globl poll_rendering
.globl poll_revert
.globl dispatch_key
.globl fmt_key
.globl list_ops
.globl op_toggle_flag
.globl op_check_flag
.globl find_op_by_name
.globl op_quiet
.globl key_chars

# ---- File ---------------------------------------------------------------------
OPERATOR op_file_exit,  "file.exit",  "Exit",      op_exit, key=KEY_Q|KM_CTRL, flags=OPF_CONFIRM, doc="Quit BeeModel"
# ---- Edit ---------------------------------------------------------------------
OPERATOR op_edit_prefs, "edit.preferences", "Preferences...", op_todo, doc="Open the preferences editor"
# ---- Tools --------------------------------------------------------------------
OPERATOR op_tool_select, "tool.select", "Select", op_set_tool, op_check_tool, 0, KEY_Q|KM_SHIFT, doc="Selection tool"
OPERATOR op_tool_move,   "tool.move",   "Move",   op_set_tool, op_check_tool, 1, KEY_W|KM_SHIFT, doc="Move tool"
OPERATOR op_tool_rotate, "tool.rotate", "Rotate", op_set_tool, op_check_tool, 2, KEY_E|KM_SHIFT, doc="Rotate tool"
OPERATOR op_tool_scale,  "tool.scale",  "Scale",  op_set_tool, op_check_tool, 3, KEY_R|KM_SHIFT, doc="Scale tool"
# ---- Console ------------------------------------------------------------------
OPERATOR op_console_focus, "console.focus", "Command Line", do_console_focus, key=KEY_ENTER, flags=OPF_QUIET|OPF_AI_SAFE, doc="Focus the console command line"
OPERATOR op_console_clear, "console.clear", "Clear Console", do_console_clear, key=KEY_L|KM_CTRL, flags=OPF_QUIET|OPF_AI_SAFE, doc="Clear the console log"
OPERATOR op_console_ops,   "console.list_ops", "List Operators", do_console_list_ops, doc="List every operator id in the console"
# ---- Help ---------------------------------------------------------------------
OPERATOR op_help_keys,  "help.shortcuts", "Keyboard Shortcuts", op_shortcuts, key=KEY_F1, doc="List all key bindings in the console"
OPERATOR op_help_about, "help.about",     "About BeeModel",     op_about, doc="Show version information"

.section .rodata
s_log_prompt:   .asciz "> "
s_nl:           .asciz "\n"
s_log_todo:     .asciz "  not implemented yet - waiting for the modeling core"
s_about_ver:    .asciz "  BeeModel "
s_about1:       .asciz "  A 3D modeling shell written in pure x86-64 assembly"
s_about2:       .asciz "  Talks the Wayland wire protocol directly; no libc, no toolkits"
s_keys_mouse:   .asciz "  Mouse: LMB orbit | MMB or Shift+LMB pan | wheel zoom | Esc closes menus"
s_two_sp:       .asciz "  "
s_k_ctrl:       .asciz "Ctrl+"
s_k_shift:      .asciz "Shift+"
s_k_alt:        .asciz "Alt+"
s_k_esc:        .asciz "Esc"
s_k_bksp:       .asciz "Backspace"
s_k_tab:        .asciz "Tab"
s_k_enter:      .asciz "Enter"
s_k_space:      .asciz "Space"
s_k_home:       .asciz "Home"
s_k_del:        .asciz "Del"
s_need_edit:    .asciz "works in edit mode - select a mesh and press Tab"
s_need_object:  .asciz "works in object mode - press Tab to leave edit mode"
s_no_undo:      .asciz "there is nothing to undo"
s_no_redo:      .asciz "there is nothing to redo"
s_no_sel:       .asciz "select an object first"
s_need_two:     .asciz "select two or more meshes (the active one keeps the result)"
s_no_render:    .asciz "render first (F12)"
s_not_rendering: .asciz "no render is running"
s_no_revert_p:  .asciz "the last change was not an agent's"
s_k_up:       .asciz "Up"
s_k_pgup:     .asciz "PgUp"
s_k_left:     .asciz "Left"
s_k_right:    .asciz "Right"
s_k_end:      .asciz "End"
s_k_down:     .asciz "Down"
s_k_pgdn:     .asciz "PgDn"
s_k_ins:      .asciz "Ins"
s_k_kpmul:    .asciz "Num*"
s_k_kpminus:  .asciz "Num-"
s_k_kpplus:   .asciz "Num+"
s_k_kpdot:    .asciz "Num."
s_k_kpenter:  .asciz "NumEnter"
s_k_kpslash:  .asciz "Num/"
s_k_kp0:      .asciz "Num0"
s_k_kp1:      .asciz "Num1"
s_k_kp2:      .asciz "Num2"
s_k_kp3:      .asciz "Num3"
s_k_kp4:      .asciz "Num4"
s_k_kp5:      .asciz "Num5"
s_k_kp6:      .asciz "Num6"
s_k_kp7:      .asciz "Num7"
s_k_kp8:      .asciz "Num8"
s_k_kp9:      .asciz "Num9"
s_k_f11:        .asciz "F11"
s_k_f12:        .asciz "F12"
s_k_unknown:    .asciz "Key?"

# evdev codes 0..57 -> printable character (0 = see key_special)
key_chars:
    .byte 0, 0
    .ascii "1234567890-="
    .byte 0, 0
    .ascii "QWERTYUIOP[]"
    .byte 0, 0
    .ascii "ASDFGHJKL;'`"
    .byte 0
    .ascii "\\ZXCVBNM,./"
    .byte 0, '*', 0, 0
.equ KEY_CHARS_N, . - key_chars
.align 8
key_special:                            # code:u64, name:ptr
    .quad 1, s_k_esc
    .quad 14, s_k_bksp
    .quad 15, s_k_tab
    .quad 28, s_k_enter
    .quad 57, s_k_space
    .quad 87, s_k_f11
    .quad 88, s_k_f12
    .quad 102, s_k_home
    .quad 103, s_k_up
    .quad 104, s_k_pgup
    .quad 105, s_k_left
    .quad 106, s_k_right
    .quad 107, s_k_end
    .quad 108, s_k_down
    .quad 109, s_k_pgdn
    .quad 110, s_k_ins
    .quad 111, s_k_del
    .quad 55, s_k_kpmul
    .quad 74, s_k_kpminus
    .quad 78, s_k_kpplus
    .quad 79, s_k_kp1
    .quad 80, s_k_kp2
    .quad 81, s_k_kp3
    .quad 75, s_k_kp4
    .quad 76, s_k_kp5
    .quad 77, s_k_kp6
    .quad 71, s_k_kp7
    .quad 72, s_k_kp8
    .quad 73, s_k_kp9
    .quad 82, s_k_kp0
    .quad 83, s_k_kpdot
    .quad 96, s_k_kpenter
    .quad 98, s_k_kpslash
    .quad 0, 0

.section .bss
.align 4
op_quiet:       .skip 4
keybuf:         .skip 32
linebuf:        .skip 160

.text

# -----------------------------------------------------------------------------
# run_op(rdi=op) - echo to the console, execute, request a redraw
# -----------------------------------------------------------------------------
run_op:
    push    rbx
    mov     rbx, rdi
    test    dword ptr [rbx+OP_FLAGS], OPF_QUIET
    jnz     1f
    cmp     dword ptr [rip+op_quiet], 0     # scripts run operators silently
    jne     1f
    lea     rdi, [rip+s_log_prompt]
    mov     rsi, [rbx+OP_LABEL]
    call    log_pair
1:  test    dword ptr [rbx+OP_FLAGS], OPF_UNDO
    jz      2f
    mov     rdi, [rbx+OP_LABEL]         # record the scene before the change
    call    undo_push
2:  call    fa_mark                     # its scratch memory goes back after
    push    rbp                         # (the operator gets an aligned stack,
    mov     rbp, rsp                    #  whoever calls: keys, MCP, scripts)
    and     rsp, -16
    push    rax
    sub     rsp, 8
    mov     rdi, [rbx+OP_ARG]
    mov     rsi, rbx
    call    [rbx+OP_EXEC]
    add     rsp, 8
    pop     rdi
    mov     rsp, rbp
    pop     rbp
    call    fa_release
    call    rig_eval                    # (drivers and constraints follow)
    mov     dword ptr [rip+dirty], 1
    mov     rdi, rbx                    # macro recording
    call    macro_op
    pop     rbx
    ret

# -----------------------------------------------------------------------------
# op_poll(rdi=op) -> rax = 0 if it can run now, else why not (asciz). Menus,
#   tool buttons and the palette grey out what cannot run and say why. An
#   OPF_EDIT operator needs edit mode, an OPF_OBJECT one object mode; then
#   the operator's own OP_POLL, if it has one. (run_op itself does not ask:
#   scripts and agents get the operator's own message.)
# -----------------------------------------------------------------------------
op_poll:
    mov     eax, [rdi+OP_FLAGS]
    test    eax, OPF_EDIT
    jz      1f
    cmp     dword ptr [rip+edit_obj], 0
    jne     1f
    lea     rax, [rip+s_need_edit]
    ret
1:  test    eax, OPF_OBJECT
    jz      2f
    cmp     dword ptr [rip+edit_obj], 0
    je      2f
    lea     rax, [rip+s_need_object]
    ret
2:  mov     rax, [rdi+OP_POLL]
    test    rax, rax
    jz      3f
    mov     rdi, [rdi+OP_ARG]
    jmp     rax
3:  xor     eax, eax
    ret

# ---- polls ---------------------------------------------------------------------
poll_undo:
    xor     eax, eax
    cmp     dword ptr [rip+co_on], 0    # (co-editing keeps its own history)
    jne     1f
    cmp     dword ptr [rip+undo_depth], 0
    jne     1f
    lea     rax, [rip+s_no_undo]
1:  ret
poll_redo:
    xor     eax, eax
    cmp     dword ptr [rip+co_on], 0
    jne     1f
    cmp     dword ptr [rip+redo_depth], 0
    jne     1f
    lea     rax, [rip+s_no_redo]
1:  ret
poll_sel:                               # an object selected
    call    sel_objects
    test    eax, eax
    jz      1f
    xor     eax, eax
    ret
1:  lea     rax, [rip+s_no_sel]
    ret
poll_two:                               # two or more
    call    sel_objects
    cmp     eax, 2
    jb      1f
    xor     eax, eax
    ret
1:  lea     rax, [rip+s_need_two]
    ret
poll_render:
    xor     eax, eax
    cmp     dword ptr [rip+rn_have], 0
    jne     1f
    lea     rax, [rip+s_no_render]
1:  ret
poll_rendering:
    xor     eax, eax
    cmp     dword ptr [rip+hv_active], 0
    jne     1f
    lea     rax, [rip+s_not_rendering]
1:  ret
poll_revert:
    sub     rsp, 8
    call    revertable
    add     rsp, 8
    test    eax, eax
    jz      1f
    xor     eax, eax
    ret
1:  lea     rax, [rip+s_no_revert_p]
    ret

# sel_objects -> eax = selected objects
sel_objects:
    push    rbx
    push    r12
    sub     rsp, 8
    xor     ebx, ebx
    xor     r12d, r12d
1:  cmp     ebx, [rip+obj_count]
    jae     2f
    mov     edi, ebx
    call    obj_at
    test    dword ptr [rax+OB_FLAGS], OBF_SELECTED
    jz      3f
    inc     r12d
3:  inc     ebx
    jmp     1b
2:  mov     eax, r12d
    add     rsp, 8
    pop     r12
    pop     rbx
    ret

# op_checked(rdi=op) -> eax = 1 checked, 0 unchecked, -1 not a toggle
op_checked:
    mov     rax, [rdi+OP_CHECK]
    test    rax, rax
    jz      1f
    mov     rdi, [rdi+OP_ARG]
    jmp     rax
1:  mov     eax, -1
    ret

# dispatch_key(edi=evdev code) -> eax = 1 if an operator handled it
dispatch_key:
    push    rbx
    call    kb_layout_code              # letters follow the active layout
    mov     ebx, eax
    call    kb_canon_mods
    shl     eax, 16
    or      eax, ebx
    pop     rbx
    mov     ecx, OPF_UV                 # over a UV editor, its keys first
    push    rax
    call    uved_active
    mov     ecx, eax
    pop     rax
    test    ecx, ecx
    mov     ecx, OPF_UV
    jnz     100f
    push    rax                         # over a dope sheet / graph editor
    call    animed_active
    mov     ecx, eax
    pop     rax
    test    ecx, ecx
    mov     ecx, OPF_ANIMED
    jnz     100f
    push    rax                         # over a node editor: its keys
    call    nodeed_active
    mov     ecx, eax
    pop     rax
    test    ecx, ecx
    mov     ecx, OPF_NODE
    jnz     100f
    mov     ecx, OPF_ARM                # armature modes: their keys first
    cmp     dword ptr [rip+arm_mode], 0
    jne     100f
    mov     ecx, OPF_CURVE              # curve edit mode: its keys first
    cmp     dword ptr [rip+cve_obj], 0
    jne     100f
    mov     ecx, OPF_SKETCH             # sketch / sculpt / paint mode: their
    cmp     dword ptr [rip+skm_obj], 0  #  keys first
    jne     100f
    mov     ecx, OPF_PAINT
    cmp     dword ptr [rip+pt_obj], 0
    jne     100f
    mov     ecx, OPF_SCULPT
    cmp     dword ptr [rip+sc_obj], 0
    je      0f
100: lea     rdi, [rip+__start_bee_ops]
    lea     rdx, [rip+__stop_bee_ops]
101: cmp     rdi, rdx
    jae     0f
    cmp     [rdi+OP_KEY], eax
    jne     102f
    test    [rdi+OP_FLAGS], ecx
    jnz     6f
102: add     rdi, OP_SIZE
    jmp     101b
0:  lea     rdi, [rip+__start_bee_ops]
    lea     rdx, [rip+__stop_bee_ops]
1:  cmp     rdi, rdx
    jae     2f
    cmp     [rdi+OP_KEY], eax
    je      3f
4:  add     rdi, OP_SIZE
    jmp     1b
2:  xor     eax, eax
    ret
3:  test    dword ptr [rdi+OP_FLAGS], OPF_SKETCH|OPF_SCULPT|OPF_UV|OPF_PAINT|OPF_NODE|OPF_CURVE|OPF_ANIMED|OPF_ARM # (not outside their modes)
    jnz     4b
    cmp     dword ptr [rip+edit_obj], 0 # the same key can mean different
    je      5f                          # things in object and edit mode
    test    dword ptr [rdi+OP_FLAGS], OPF_OBJECT
    jnz     4b
    jmp     6f
5:  test    dword ptr [rdi+OP_FLAGS], OPF_EDIT
    jnz     4b
6:  sub     rsp, 8                      # (the operator gets an aligned stack;
    call    run_op_ui                   #  a key is the UI: poll, form, "Save?")
    add     rsp, 8
    mov     eax, 1
    ret

# find_op_by_name(rdi=asciz id) -> rax = operator or 0
find_op_by_name:
    push    rbx
    push    r12
    mov     r12, rdi
    lea     rbx, [rip+__start_bee_ops]
1:  lea     rax, [rip+__stop_bee_ops]
    cmp     rbx, rax
    jae     3f
    mov     rdi, r12
    mov     rsi, [rbx+OP_NAME]
    call    str_eq
    test    eax, eax
    jnz     2f
    add     rbx, OP_SIZE
    jmp     1b
2:  mov     rax, rbx
    jmp     4f
3:  xor     eax, eax
4:  pop     r12
    pop     rbx
    ret

# -----------------------------------------------------------------------------
# fmt_key(edi=binding) -> rax = asciz like "Ctrl+Shift+Z" (static), 0 if none
# -----------------------------------------------------------------------------
fmt_key:
    test    edi, edi
    jnz     1f
    xor     eax, eax
    ret
1:  push    rbx
    push    r12
    mov     ebx, edi
    lea     r12, [rip+keybuf]
    test    ebx, KM_CTRL
    jz      2f
    lea     rsi, [rip+s_k_ctrl]
    call    kb_append
2:  test    ebx, KM_SHIFT
    jz      3f
    lea     rsi, [rip+s_k_shift]
    call    kb_append
3:  test    ebx, KM_ALT
    jz      4f
    lea     rsi, [rip+s_k_alt]
    call    kb_append
4:  movzx   eax, bx                     # key code
    cmp     eax, KEY_CHARS_N
    jae     5f
    lea     rcx, [rip+key_chars]
    movzx   ecx, byte ptr [rcx+rax]
    test    ecx, ecx
    jz      5f
    mov     [r12], cl
    inc     r12
    jmp     9f
5:  cmp     eax, KEY_F1                 # F1..F10 = 59..68
    jb      6f
    cmp     eax, KEY_F1+9
    ja      6f
    mov     byte ptr [r12], 'F'
    inc     r12
    sub     eax, KEY_F1-1
    cmp     eax, 10
    jb      51f
    mov     byte ptr [r12], '1'
    inc     r12
    sub     eax, 10
51: add     al, '0'
    mov     [r12], al
    inc     r12
    jmp     9f
6:  lea     rcx, [rip+key_special]
61: mov     rdx, [rcx]
    test    rdx, rdx
    jz      62f
    cmp     rdx, rax
    je      63f
    add     rcx, 16
    jmp     61b
62: lea     rsi, [rip+s_k_unknown]
    call    kb_append
    jmp     9f
63: mov     rsi, [rcx+8]
    call    kb_append
9:  mov     byte ptr [r12], 0
    lea     rax, [rip+keybuf]
    pop     r12
    pop     rbx
    ret

# kb_append(rsi=asciz) - append at r12 (caller-owned cursor)
kb_append:
1:  mov     al, [rsi]
    test    al, al
    jz      2f
    mov     [r12], al
    inc     r12
    inc     rsi
    jmp     1b
2:  ret

# -----------------------------------------------------------------------------
# list_ops - print the operator table to stdout (beemodel --list-ops)
#   <id> <shortcut> <label> - <doc>
# -----------------------------------------------------------------------------
list_ops:
    push    rbx
    push    r12
    push    r13
    lea     rbx, [rip+__start_bee_ops]
1:  lea     rax, [rip+__stop_bee_ops]
    cmp     rbx, rax
    jae     9f
    call    fmt_reset
    mov     rdi, [rbx+OP_NAME]
    call    fmt_str
    mov     edi, 24
    call    fmt_pad
    mov     edi, [rbx+OP_KEY]
    call    fmt_key
    test    rax, rax
    jz      2f
    mov     rdi, rax
    call    fmt_str
2:  mov     edi, 40
    call    fmt_pad
    mov     rdi, [rbx+OP_LABEL]
    call    fmt_str
    mov     edi, ' '
    call    fmt_char
    mov     edi, 62
    call    fmt_pad
    lea     rdi, [rip+fmt_buf]          # the doc goes out on its own: no limit
    call    write_out
    mov     rdi, [rbx+OP_DOC]
    call    write_out
    lea     rdi, [rip+s_nl]
    call    write_out
    add     rbx, OP_SIZE
    jmp     1b
9:  pop     r13
    pop     r12
    pop     rbx
    ret

# =============================================================================
#  Operator implementations: exec(rdi=arg, rsi=op), check(rdi=arg) -> eax
# =============================================================================
op_todo:
    lea     rdi, [rip+s_log_todo]
    jmp     log_line

op_exit:
    mov     dword ptr [rip+quit_flag], 1
    ret

# toggles a u32 flag whose address is the operator argument
op_toggle_flag:
    xor     dword ptr [rdi], 1
    ret
op_check_flag:
    mov     eax, [rdi]
    ret

op_set_tool:
    mov     [rip+active_tool], edi
    ret
op_check_tool:
    xor     eax, eax
    cmp     edi, [rip+active_tool]
    sete    al
    ret

do_console_focus:
    call    console_ensure
    mov     edi, 1
    jmp     tf_set_focus

do_console_clear:
    mov     dword ptr [rip+log_head], 0
    ret

do_console_list_ops:
    push    rbx
    lea     rbx, [rip+__start_bee_ops]
1:  lea     rax, [rip+__stop_bee_ops]
    cmp     rbx, rax
    jae     9f
    call    fmt_reset
    lea     rdi, [rip+s_two_sp]
    call    fmt_str
    mov     rdi, [rbx+OP_NAME]
    call    fmt_str
    mov     edi, 26
    call    fmt_pad
    mov     rdi, [rbx+OP_LABEL]
    call    fmt_str
    lea     rdi, [rip+fmt_buf]
    call    log_line
    add     rbx, OP_SIZE
    jmp     1b
9:  pop     rbx
    ret

op_about:
    lea     rdi, [rip+s_about_ver]
    lea     rsi, [rip+s_version]
    call    log_pair
    lea     rdi, [rip+s_about1]
    call    log_line
    lea     rdi, [rip+s_about2]
    jmp     log_line

# op_shortcuts - every bound operator, generated from the table
op_shortcuts:
    push    rbx
    lea     rdi, [rip+s_keys_mouse]
    call    log_line
    lea     rbx, [rip+__start_bee_ops]
1:  lea     rax, [rip+__stop_bee_ops]
    cmp     rbx, rax
    jae     9f
    mov     edi, [rbx+OP_KEY]
    test    edi, edi
    jz      2f
    call    fmt_reset
    lea     rdi, [rip+s_two_sp]
    call    fmt_str
    mov     edi, [rbx+OP_KEY]
    call    fmt_key
    mov     rdi, rax
    call    fmt_str
    mov     edi, 18
    call    fmt_pad
    mov     rdi, [rbx+OP_LABEL]
    call    fmt_str
    lea     rdi, [rip+fmt_buf]
    call    log_line
2:  add     rbx, OP_SIZE
    jmp     1b
9:  pop     rbx
    ret

.section .note.GNU-stack,"",@progbits
