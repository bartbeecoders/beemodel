# =============================================================================
#  BeeModel - right-click on a widget: a field's menu (Reset to Default,
#  Copy / Paste Value, Insert Keyframe, Copy Data Path) or, in the file
#  browser, a file's (filebrowser.s: fb_row_menu).
# =============================================================================
.intel_syntax noprefix
.include "const.inc"
.include "macros.inc"
.include "widgets.inc"

.globl wg_ctx_open

# (widget list entries: widgets.s)
.equ E_KIND,    4
.equ E_DESC,    32
.equ E_SUB,     40

.section .bss
.align 4
ctx_wid:        .skip 4                 # the field the menu is for

.section .rodata
.align 8
ctx_field:      .quad op_fld_reset, 0, op_fld_copy, op_fld_paste, 0, op_fld_key, op_fld_path
.equ ctx_field_n, (. - ctx_field) / 8
s_no_def:       .asciz "This field has no default value"
s_no_val:       .asciz "Colours: copy and paste the hex code"
s_no_key:       .asciz "Only numbers and colours can be keyed"
s_no_path:      .asciz "This field has no data path for scripts"
s_gone:         .asciz "The field is no longer shown"

.text
OPERATOR op_fld_reset, "field.reset", "Reset to Default", fld_reset, flags=OPF_HIDDEN|OPF_QUIET, poll=poll_fld_reset, doc="The field's value back to its default (one undo step)"
OPERATOR op_fld_copy, "field.copy", "Copy Value", fld_copy, flags=OPF_HIDDEN|OPF_QUIET, poll=poll_fld_val, doc="The value to the clipboard (Ctrl+C over a field)"
OPERATOR op_fld_paste, "field.paste", "Paste Value", fld_paste, flags=OPF_HIDDEN|OPF_QUIET, poll=poll_fld_val, doc="The clipboard into the field, as if typed (Ctrl+V over a field)"
OPERATOR op_fld_key, "field.insert_key", "Insert Keyframe", fld_key, flags=OPF_HIDDEN|OPF_QUIET, poll=poll_fld_key, doc="A key for this value at the current frame (I over a field)"
OPERATOR op_fld_path, "field.copy_path", "Copy Data Path", fld_path, flags=OPF_HIDDEN|OPF_QUIET, poll=poll_fld_key, doc="Its path for scripts and anim.key (Cube:x, material:Steel:roughness) to the clipboard"

# wg_ctx_open(edi=widget id) - its menu, if it has one
wg_ctx_open:
    push    rbx
    mov     ebx, edi
    call    wg_find
    test    rax, rax
    jz      9f
    mov     rcx, [rax+E_DESC]
    lea     rdx, [rip+wd_fb_row]        # a file in the browser
    cmp     rcx, rdx
    jne     1f
    mov     edi, [rax+E_SUB]
    call    fb_row_menu
    jmp     9f
1:  mov     ecx, [rax+E_KIND]           # a value
    cmp     ecx, WK_FLOAT
    je      2f
    cmp     ecx, WK_INT
    je      2f
    cmp     ecx, WK_SLIDER
    je      2f
    cmp     ecx, WK_TEXT
    je      2f
    cmp     ecx, WK_COLOR
    jne     9f
2:  mov     [rip+ctx_wid], ebx
    lea     rdi, [rip+ctx_field]
    mov     esi, ctx_field_n
    call    ctx_open_list
9:  pop     rbx
    ret

# fld -> rax = the field's entry this frame (0: gone)
fld:
    mov     edi, [rip+ctx_wid]
    jmp     wg_find

fld_kind:                               # -> eax = its kind (0: gone)
    sub     rsp, 8
    call    fld
    add     rsp, 8
    test    rax, rax
    jz      1f
    mov     eax, [rax+E_KIND]
1:  ret

poll_fld_reset:
    sub     rsp, 8
    call    fld
    add     rsp, 8
    test    rax, rax
    jz      8f
    mov     rdi, rax
    sub     rsp, 8
    call    wg_has_def
    add     rsp, 8
    test    eax, eax
    jz      7f
    xor     eax, eax
    ret
7:  lea     rax, [rip+s_no_def]
    ret
8:  lea     rax, [rip+s_gone]
    ret

poll_fld_val:
    sub     rsp, 8
    call    fld_kind
    add     rsp, 8
    test    eax, eax
    jz      8f
    cmp     eax, WK_COLOR
    je      7f
    xor     eax, eax
    ret
7:  lea     rax, [rip+s_no_val]
    ret
8:  lea     rax, [rip+s_gone]
    ret

poll_fld_key:
    sub     rsp, 8
    call    fld_kind
    add     rsp, 8
    test    eax, eax
    jz      8f
    cmp     eax, WK_TEXT
    je      7f
    xor     eax, eax
    ret
7:  lea     rax, [rip+s_no_key]
    ret
8:  lea     rax, [rip+s_gone]
    ret

fld_reset:
    sub     rsp, 8
    call    fld
    test    rax, rax
    jz      9f
    mov     rdi, rax
    call    wg_val_reset
9:  add     rsp, 8
    ret

fld_copy:
    sub     rsp, 8
    call    fld
    test    rax, rax
    jz      9f
    mov     rdi, rax
    call    wg_val_copy
9:  add     rsp, 8
    ret

fld_paste:
    sub     rsp, 8
    call    fld
    test    rax, rax
    jz      9f
    mov     rdi, rax
    call    wg_val_paste
9:  add     rsp, 8
    ret

fld_key:
    sub     rsp, 8
    mov     edi, [rip+ctx_wid]
    call    field_key
    add     rsp, 8
    ret

fld_path:
    sub     rsp, 8
    mov     dword ptr [rip+fk_copy], 1
    mov     edi, [rip+ctx_wid]
    call    field_key
    mov     dword ptr [rip+fk_copy], 0
    test    eax, eax
    jnz     9f
    lea     rdi, [rip+s_no_path]
    call    log_line
9:  add     rsp, 8
    ret

.section .note.GNU-stack,"",@progbits
