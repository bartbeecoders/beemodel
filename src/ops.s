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
.globl dispatch_key
.globl fmt_key
.globl list_ops
.globl op_toggle_flag
.globl op_check_flag
.globl find_op_by_name
.globl op_quiet
.globl key_chars

# ---- File ---------------------------------------------------------------------
OPERATOR op_file_exit,  "file.exit",  "Exit",      op_exit, key=KEY_Q|KM_CTRL, flags=0, doc="Quit BeeModel"
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
    .quad 111, s_k_del
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
    push    rax
    sub     rsp, 8
    mov     rdi, [rbx+OP_ARG]
    mov     rsi, rbx
    call    [rbx+OP_EXEC]
    add     rsp, 8
    pop     rdi
    call    fa_release
    mov     dword ptr [rip+dirty], 1
    mov     rdi, rbx                    # macro recording
    call    macro_op
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
    lea     rdi, [rip+__start_bee_ops]
    lea     rdx, [rip+__stop_bee_ops]
1:  cmp     rdi, rdx
    jae     2f
    cmp     [rdi+OP_KEY], eax
    je      3f
4:  add     rdi, OP_SIZE
    jmp     1b
2:  xor     eax, eax
    ret
3:  cmp     dword ptr [rip+edit_obj], 0 # the same key can mean different
    je      5f                          # things in object and edit mode
    test    dword ptr [rdi+OP_FLAGS], OPF_OBJECT
    jnz     4b
    jmp     6f
5:  test    dword ptr [rdi+OP_FLAGS], OPF_EDIT
    jnz     4b
6:  call    run_op
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
