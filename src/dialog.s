# =============================================================================
#  BeeModel - dialogs: a modal box over a dimmed window, for
#    - operator forms: an operator that takes values (render size, frame
#      range, rigid body settings ...) and is run from a menu, a button, a
#      key or the palette without them gets a form built from its FORM
#      record (forms.s) - fields drawn with the widget toolkit, OK runs the
#      operator with the values as its argument text, Cancel / Esc closes;
#      the values stay for next time;
#    - "Save changes?" before New, Open and Exit (and the window's close
#      button) when the scene has unsaved changes: Save, Don't Save, Cancel.
#  Scripts, the console and agents call run_op and never see a dialog.
# =============================================================================
.intel_syntax noprefix
.include "const.inc"
.include "macros.inc"
.include "widgets.inc"

# exports
.globl dlg_open
.globl dlg_open_form
.globl dlg_open_confirm
.globl dlg_draw
.globl dlg_key
.globl dlg_floor
.globl dlg_close
.globl dlg_parg
.globl dlg_run_pending

.equ DLG_FORM,      1
.equ DLG_CONFIRM,   2
.equ DLG_FILE,      3                   # the file browser (filebrowser.s)
.equ DLG_W,         460
.equ VAL_SZ,        64                  # each field's value slot
.equ MAXF,          16
.equ FM_TITLE,      0                   # FORM record: title, values, count,
.equ FM_VALS,       8                   #  then the fields
.equ FM_N,          16
.equ FM_FIELDS,     24
.equ FF_DESC,       0                   # a field: its widget, the text before
.equ FF_PREFIX,     8                   #  its value, keywords (an enum), the
.equ FF_KW,         16                  #  default
.equ FF_DEF,        24
.equ FF_SZ,         32

.section .bss
.align 8
dlg_open:       .skip 4
dlg_kind:       .skip 4
dlg_floor:      .skip 4                 # (widgets.s: below this index no hits)
dlg_h:          .skip 4
.align 8
dlg_op:         .skip 8                 # the operator (form) / to do (confirm)
dlg_form:       .skip 8
dlg_arg:        .skip 512
dlg_title:      .skip 160
dlg_parg:       .skip 512               # the argument the asking operator had

.section .rodata
s_ok:           .asciz "OK"
s_cancel:       .asciz "Cancel"
s_save:         .asciz "Save"
s_dont:         .asciz "Don't Save"
s_save_q:       .asciz "Save changes to "
s_untitled_q:   .asciz "this scene"
s_q:            .asciz "?"
s_lost:         .asciz "Your changes are lost if you don't save them."
s_space:        .asciz " "

.text

OPERATOR op_dlg_ok,     "dialog.ok",     "OK",         dlg_ok,     flags=OPF_QUIET|OPF_HIDDEN, doc="Confirm the open dialog"
OPERATOR op_dlg_alt,    "dialog.dont_save", "Don't Save", dlg_dont,  flags=OPF_QUIET|OPF_HIDDEN, doc="Go on without saving"
OPERATOR op_dlg_cancel, "dialog.cancel", "Cancel",     dlg_cancel, flags=OPF_QUIET|OPF_HIDDEN, doc="Close the open dialog"

WIDGET wd_dlg_ok,     WK_BUTTON, "dialog.ok", "OK", flags=WGF_PRIMARY, aux=op_dlg_ok
WIDGET wd_dlg_save,   WK_BUTTON, "dialog.save", "Save", flags=WGF_PRIMARY, aux=op_dlg_ok
WIDGET wd_dlg_dont,   WK_BUTTON, "dialog.dont_save", "Don't Save", aux=op_dlg_alt
WIDGET wd_dlg_cancel, WK_BUTTON, "dialog.cancel", "Cancel", aux=op_dlg_cancel

# dlg_open_form(rdi=operator) - its form, with the values of last time (or
#   the defaults the first time)
dlg_open_form:
    push    rbx
    push    r12
    push    r13
    mov     [rip+dlg_op], rdi
    mov     rbx, [rdi+OP_FORM]
    mov     rsi, [rbx+FM_FIELDS+FF_DESC]    # a file: the browser instead
    cmp     dword ptr [rsi+WD_KIND], WK_PATH
    jne     0f
    mov     rdx, [rbx+FM_FIELDS+FF_KW]      # (its default file name)
    call    fb_open
    mov     dword ptr [rip+dlg_kind], DLG_FILE
    mov     dword ptr [rip+dlg_open], 1
    mov     dword ptr [rip+dirty], 1
    pop     r13
    pop     r12
    pop     rbx
    ret
0:
    mov     [rip+dlg_form], rbx
    mov     r12, [rbx+FM_VALS]
    cmp     dword ptr [r12+MAXF*VAL_SZ], 0  # first time: the defaults
    jne     2f
    mov     dword ptr [r12+MAXF*VAL_SZ], 1
    xor     r13d, r13d
1:  cmp     r13d, [rbx+FM_N]
    jae     2f
    mov     eax, r13d
    imul    eax, FF_SZ
    lea     rcx, [rbx+FM_FIELDS+rax]
    mov     rdx, [rcx+FF_DESC]
    mov     eax, r13d
    imul    eax, VAL_SZ
    lea     rdi, [r12+rax]
    movss   xmm0, [rcx+FF_DEF]
    mov     esi, [rdx+WD_KIND]
    cmp     esi, WK_TEXT                # text: the default text (FF_KW)
    jne     5f
    mov     rsi, [rcx+FF_KW]
    cmp     rsi, FK_ACTIVE
    jbe     4f
    call    copy63
    jmp     4f
5:  cmp     esi, WK_FLOAT
    je      3f
    cmp     esi, WK_SLIDER
    je      3f
    cvttss2si eax, xmm0                 # ints, toggles, options: whole numbers
    mov     [rdi], eax
    jmp     4f
3:  movss   [rdi], xmm0
4:  inc     r13d
    jmp     1b
2:  xor     r13d, r13d                  # FK_ACTIVE text: the active object's
6:  cmp     r13d, [rbx+FM_N]            #  name, each time
    jae     8f
    mov     eax, r13d
    imul    eax, FF_SZ
    lea     rcx, [rbx+FM_FIELDS+rax]
    cmp     qword ptr [rcx+FF_KW], FK_ACTIVE
    jne     7f
    mov     rdx, [rcx+FF_DESC]
    cmp     dword ptr [rdx+WD_KIND], WK_TEXT
    jne     7f
    mov     eax, r13d
    imul    eax, VAL_SZ
    lea     rdi, [r12+rax]
    mov     byte ptr [rdi], 0
    push    rdi
    mov     edi, [rip+active_obj]
    call    obj_get
    pop     rdi
    test    rax, rax
    jz      7f
    mov     rsi, rax                    # (OB_NAME)
    call    copy63
7:  inc     r13d
    jmp     6b
8:  mov     dword ptr [rip+dlg_kind], DLG_FORM
    mov     dword ptr [rip+dlg_open], 1
    mov     dword ptr [rip+dirty], 1
    pop     r13
    pop     r12
    pop     rbx
    ret

# dlg_open_confirm(rdi=operator to run after) - "Save changes to x?"
dlg_open_confirm:
    mov     [rip+dlg_op], rdi
    lea     rdi, [rip+dlg_parg]         # (keep its argument: Open Recent)
    mov     byte ptr [rdi], 0
    mov     rsi, [rip+op_arg]
    test    rsi, rsi
    jz      1f
    mov     ecx, 511
2:  mov     al, [rsi]
    mov     [rdi], al
    test    al, al
    jz      1f
    inc     rsi
    inc     rdi
    dec     ecx
    jnz     2b
    mov     byte ptr [rdi], 0
1:
    mov     dword ptr [rip+dlg_kind], DLG_CONFIRM
    mov     dword ptr [rip+dlg_open], 1
    mov     dword ptr [rip+dirty], 1
    ret

dlg_close:
    mov     dword ptr [rip+dlg_open], 0
    mov     dword ptr [rip+dlg_floor], 0
    mov     dword ptr [rip+dirty], 1
    jmp     wg_commit                   # (a field still being typed in)

# ---- the buttons -----------------------------------------------------------------
dlg_cancel:
    jmp     dlg_close

dlg_ok:
    push    rbx
    call    wg_commit                   # what is typed counts
    mov     rbx, [rip+dlg_op]
    cmp     dword ptr [rip+dlg_kind], DLG_CONFIRM
    je      .Lok_save
    call    form_arg                    # a form: run with its values
    call    dlg_close
    push    qword ptr [rip+op_arg]
    lea     rax, [rip+dlg_arg]
    mov     [rip+op_arg], rax
    mov     rdi, rbx
    call    run_op
    pop     qword ptr [rip+op_arg]
    pop     rbx
    ret
.Lok_save:                              # save, then what was asked
    call    dlg_close
    cmp     byte ptr [rip+cur_path], 0  # (no file yet: the browser asks
    jne     1f                          #  where, then goes on)
    lea     rdi, [rip+op_file_saveas]
    call    dlg_open_form
    mov     [rip+fb_after], rbx
    pop     rbx
    ret
1:  lea     rdi, [rip+op_file_save]
    call    run_op
    cmp     dword ptr [rip+scene_modified], 0
    jne     9f                          # (not saved: a path is still asked for)
    mov     rdi, rbx
    call    dlg_run_pending
9:  pop     rbx
    ret

dlg_dont:                               # go on without saving
    push    rbx
    mov     rbx, [rip+dlg_op]
    call    dlg_close
    mov     rdi, rbx
    call    dlg_run_pending
    pop     rbx
    ret

# dlg_run_pending(rdi=operator) - run it with the argument it had when it
#   asked "Save changes?"
dlg_run_pending:
    push    qword ptr [rip+op_arg]
    lea     rax, [rip+dlg_parg]
    mov     [rip+op_arg], rax
    call    run_op
    pop     qword ptr [rip+op_arg]
    ret

# dlg_key(edi=evdev) -> eax = 1 (a dialog takes every key): Enter is OK (or
#   Save), Esc is Cancel, Tab starts typing in the first field
dlg_key:
    cmp     dword ptr [rip+dlg_open], 0
    je      8f
    cmp     dword ptr [rip+dlg_kind], DLG_FILE
    je      fb_key
    sub     rsp, 8
    cmp     edi, KEY_ESC
    jne     1f
    call    dlg_close
    jmp     9f
1:  cmp     edi, KEY_ENTER
    je      2f
    cmp     edi, 96                     # (keypad Enter)
    jne     9f
2:  lea     rdi, [rip+op_dlg_ok]
    call    run_op
9:  add     rsp, 8
    mov     eax, 1
    ret
8:  xor     eax, eax
    ret

# form_arg - dlg_arg = the form's values as the operator's argument text
form_arg:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    mov     rbx, [rip+dlg_form]
    mov     r12, [rbx+FM_VALS]
    lea     r14, [rip+dlg_arg]          # the end of the text
    mov     byte ptr [r14], 0
    xor     r13d, r13d
.Lfa_field:
    cmp     r13d, [rbx+FM_N]
    jae     .Lfa_done
    mov     eax, r13d
    imul    eax, FF_SZ
    lea     r15, [rbx+FM_FIELDS+rax]    # the field
    mov     eax, r13d
    imul    eax, VAL_SZ
    lea     rcx, [r12+rax]              # its value
    mov     rdx, [r15+FF_DESC]
    mov     eax, [rdx+WD_KIND]
    test    dword ptr [r15+28], FF_CHANGED  # (an optional one at its default:
    jz      0f                              #  the operator's own default)
    cmp     eax, WK_FLOAT
    je      .Lfa_flt
    cmp     eax, WK_SLIDER
    je      .Lfa_flt
    cvttss2si edx, dword ptr [r15+FF_DEF]
    cmp     [rcx], edx
    je      .Lfa_next
    jmp     0f
.Lfa_flt:
    movss   xmm0, [rcx]
    ucomiss xmm0, [r15+FF_DEF]
    je      .Lfa_next
0:
    cmp     eax, WK_TOGGLE              # a toggle: its word when on
    jne     1f
    cmp     dword ptr [rcx], 0
    je      .Lfa_next
    call    put_space
    mov     rsi, [r15+FF_PREFIX]
    call    put_str
    jmp     .Lfa_next
1:  push    rcx
    push    rax
    call    put_space
    mov     rsi, [r15+FF_PREFIX]        # "mass " ...
    test    rsi, rsi
    jz      11f
    call    put_str
    call    put_space
11: pop     rax
    pop     rcx
    cmp     eax, WK_ENUM
    jne     2f
    mov     eax, [rcx]                  # an option: its keyword
    mov     rdx, [r15+FF_KW]
    mov     rsi, [rdx+rax*8]
    call    put_str
    jmp     .Lfa_next
2:  cmp     eax, WK_TEXT            # text: quoted when it has spaces
    jne     3f
    mov     rsi, rcx
    xor     edx, edx
    cmp     byte ptr [rsi], 0           # (empty: "" keeps its place)
    sete    dl
21: mov     al, [rsi]
    test    al, al
    jz      22f
    inc     rsi
    cmp     al, ' '
    jne     21b
    inc     edx
22: test    edx, edx
    jz      23f
    mov     byte ptr [r14], '"'
    inc     r14
23: push    rdx
    push    rdx
    mov     rsi, rcx
    call    put_str
    pop     rdx
    pop     rdx
    test    edx, edx
    jz      .Lfa_next
    mov     word ptr [r14], '"'
    inc     r14
    jmp     .Lfa_next
3:  cmp     eax, WK_INT
    jne     4f
    cvtsi2ss xmm0, dword ptr [rcx]
    xor     edi, edi
    jmp     5f
4:  movss   xmm0, [rcx]
    mov     edi, 6
5:  mov     rsi, r14
    call    wg_ftoa
    mov     r14, rax
.Lfa_next:
    inc     r13d
    jmp     .Lfa_field
.Lfa_done:
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# doc_plain -> rdi = the operator's doc up to its syntax ("Hollow a part: cad.shell
#   <pad> ..." -> "Hollow a part"), in dlg_title
doc_plain:
    mov     rax, [rip+dlg_op]
    mov     rsi, [rax+OP_DOC]
    mov     r8, [rax+OP_NAME]
    lea     rdi, [rip+dlg_title]
    xor     ecx, ecx
1:  mov     al, [rsi+rcx]               # does "<name>" start here?
    test    al, al
    jz      5f
    xor     edx, edx
    lea     r10, [rsi+rcx]
2:  mov     r9b, [r8+rdx]
    test    r9b, r9b
    jz      4f
    cmp     r9b, [r10+rdx]
    jne     3f
    inc     edx
    jmp     2b
3:  cmp     ecx, 158
    jae     5f
    mov     [rdi+rcx], al
    inc     ecx
    jmp     1b
4:  test    ecx, ecx                    # yes: drop it and the ": " before
    jz      6f
    cmp     byte ptr [rdi+rcx-1], ' '
    je      41f
    cmp     byte ptr [rdi+rcx-1], ':'
    jne     5f
41: dec     ecx
    jmp     4b
5:  mov     byte ptr [rdi+rcx], 0
    ret
6:  mov     rdi, rsi                    # (all syntax: as it is)
    ret

copy63:                                 # rdi = dest, rsi = text (63 max)
    mov     ecx, 63
1:  mov     al, [rsi]
    test    al, al
    jz      2f
    mov     [rdi], al
    inc     rsi
    inc     rdi
    dec     ecx
    jnz     1b
2:  mov     byte ptr [rdi], 0
    ret

put_space:                              # (not at the start)
    lea     rax, [rip+dlg_arg]
    cmp     r14, rax
    je      1f
    mov     byte ptr [r14], ' '
    inc     r14
    mov     byte ptr [r14], 0
1:  ret

put_str:                                # rsi = text or 0 -> at r14
    test    rsi, rsi
    jz      2f
1:  mov     al, [rsi]
    test    al, al
    jz      2f
    mov     [r14], al
    inc     rsi
    inc     r14
    jmp     1b
2:  mov     byte ptr [r14], 0
    ret

# ---- drawing ----------------------------------------------------------------------
# dlg_draw - the dimmed window and the box; its widgets are the only ones
#   that take the pointer while it is open
dlg_draw:
    cmp     dword ptr [rip+dlg_open], 0
    je      .Ldd_ret
    cmp     dword ptr [rip+dlg_kind], DLG_FILE
    jne     0f
    sub     rsp, 8
    call    reset_clip                  # (the browser: dimmed window too)
    xor     edi, edi
    xor     esi, esi
    mov     edx, [rip+win_w]
    mov     ecx, [rip+win_h]
    mov     r8d, COL_SHADOW
    mov     r9d, 110
    call    fill_rect_a
    mov     eax, [rip+wg_n]
    mov     [rip+dlg_floor], eax
    add     rsp, 8
    jmp     fb_draw
0:  push    rbx
    push    rbp
    push    r12
    push    r13
    push    r14
    push    r15
    sub     rsp, 24
    call    reset_clip
    xor     edi, edi                    # dim everything
    xor     esi, esi
    mov     edx, [rip+win_w]
    mov     ecx, [rip+win_h]
    mov     r8d, COL_SHADOW
    mov     r9d, 110
    call    fill_rect_a
    mov     eax, [rip+wg_n]             # widgets from here on are the dialog's
    mov     [rip+dlg_floor], eax
    # the box: a title, the text, the fields, the buttons
    mov     r15d, 104                   # height without fields (confirm too)
    cmp     dword ptr [rip+dlg_kind], DLG_FORM
    jne     1f
    mov     rax, [rip+dlg_form]
    mov     eax, [rax+FM_N]
    imul    eax, WG_H+8
    add     r15d, eax
    add     r15d, 28                    # (the doc line)
1:  mov     [rip+dlg_h], r15d
    mov     ebx, [rip+win_w]            # centred
    sub     ebx, DLG_W
    sar     ebx, 1
    mov     ebp, [rip+win_h]
    sub     ebp, r15d
    sar     ebp, 1
    mov     edi, ebx
    mov     esi, ebp
    mov     edx, DLG_W
    mov     ecx, r15d
    mov     r8d, COL_DROP_BORDER
    call    popup_frame
    lea     r12d, [rbp+16]              # y
    cmp     dword ptr [rip+dlg_kind], DLG_CONFIRM
    je      .Ldd_confirm
    # ---- a form
    mov     rax, [rip+dlg_op]
    mov     rdx, [rax+OP_LABEL]
    lea     edi, [rbx+18]
    mov     esi, r12d
    mov     ecx, COL_TEXT
    call    draw_heading
    add     r12d, 24
    mov     edi, FONT_SMALL             # its doc, one line (the tooltip has it all)
    call    text_use
    mov     [rsp], eax
    call    doc_plain
    mov     esi, DLG_W-36
    lea     edx, [rbx+18]
    mov     ecx, r12d
    mov     r8d, COL_TEXT_DIM
    call    wrap_text_1
    mov     edi, [rsp]
    call    text_use
    add     r12d, 32
    mov     r14, [rip+dlg_form]
    xor     r13d, r13d
.Ldd_field:
    cmp     r13d, [r14+FM_N]
    jae     .Ldd_buttons
    mov     eax, r13d
    imul    eax, FF_SZ
    lea     r15, [r14+FM_FIELDS+rax]
    mov     rdi, [r15+FF_DESC]
    mov     eax, [rdi+WD_KIND]
    lea     esi, [rbx+18]               # x
    mov     ecx, DLG_W-36               # w
    cmp     eax, WK_ENUM                # options and text: a caption first
    je      2f
    cmp     eax, WK_TEXT
    jne     3f
2:  mov     rdx, [rdi+WD_LABEL]
    lea     edi, [rbx+18]
    lea     esi, [r12+3]
    mov     ecx, COL_TEXT_DIM
    call    draw_text
    mov     rdi, [r15+FF_DESC]
    lea     esi, [rbx+150]
    mov     ecx, DLG_W-168
3:  mov     edx, r12d
    mov     rax, [r14+FM_VALS]
    mov     r8d, r13d
    imul    r8d, VAL_SZ
    add     r8, rax
    xor     r9d, r9d
    call    wg
    add     r12d, WG_H+8
    inc     r13d
    jmp     .Ldd_field
.Ldd_confirm:                           # ---- "Save changes to x?"
    lea     rdi, [rip+dlg_title]
    lea     rsi, [rip+s_save_q]
    call    cpy
    lea     rdi, [rip+cur_path]
    call    basename
    mov     rsi, rax
    cmp     byte ptr [rsi], 0
    jne     4f
    lea     rsi, [rip+s_untitled_q]
4:  call    cat
    lea     rsi, [rip+s_q]
    call    cat
    lea     edi, [rbx+18]
    mov     esi, r12d
    lea     rdx, [rip+dlg_title]
    mov     ecx, COL_TEXT
    call    draw_heading
    add     r12d, 28
    lea     edi, [rbx+18]
    mov     esi, r12d
    lea     rdx, [rip+s_lost]
    mov     ecx, COL_TEXT_DIM
    call    draw_text
.Ldd_buttons:                           # bottom right: [Cancel] [OK]
    mov     r12d, ebp
    add     r12d, [rip+dlg_h]
    sub     r12d, WG_H+16
    cmp     dword ptr [rip+dlg_kind], DLG_CONFIRM
    je      5f
    lea     rdi, [rip+wd_dlg_cancel]
    lea     esi, [rbx+DLG_W-200]
    mov     edx, r12d
    mov     ecx, 88
    xor     r8d, r8d
    xor     r9d, r9d
    call    wg
    lea     rdi, [rip+wd_dlg_ok]
    lea     esi, [rbx+DLG_W-104]
    mov     edx, r12d
    mov     ecx, 88
    xor     r8d, r8d
    xor     r9d, r9d
    call    wg
    jmp     8f
5:  lea     rdi, [rip+wd_dlg_dont]      # [Don't Save]    [Cancel] [Save]
    lea     esi, [rbx+18]
    mov     edx, r12d
    mov     ecx, 110
    xor     r8d, r8d
    xor     r9d, r9d
    call    wg
    lea     rdi, [rip+wd_dlg_cancel]
    lea     esi, [rbx+DLG_W-200]
    mov     edx, r12d
    mov     ecx, 88
    xor     r8d, r8d
    xor     r9d, r9d
    call    wg
    lea     rdi, [rip+wd_dlg_save]
    lea     esi, [rbx+DLG_W-104]
    mov     edx, r12d
    mov     ecx, 88
    xor     r8d, r8d
    xor     r9d, r9d
    call    wg
8:  add     rsp, 24
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbp
    pop     rbx
.Ldd_ret:
    ret

# wrap_text_1(rdi=text, esi=w, edx=x, ecx=y, r8d=colour) - the first line of
#   it that fits (with "..." when cut)
wrap_text_1:
    test    rdi, rdi
    jz      9f
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    mov     rbx, rdi
    mov     r12d, esi
    mov     r13d, edx
    mov     r14d, ecx
    mov     r15d, r8d
    lea     rdi, [rip+dlg_title]        # (as a scratch line)
    mov     rsi, rbx
    call    cpy
    lea     rdi, [rip+dlg_title]        # shorten until it fits
1:  call    text_width
    cmp     eax, r12d
    jle     3f
    lea     rdi, [rip+dlg_title]
    call    str_len
    cmp     eax, 4
    jle     3f
    lea     rcx, [rip+dlg_title]
    mov     dword ptr [rcx+rax-4], 0x2e2e2e  # "..."
    lea     rdi, [rip+dlg_title]
    jmp     1b
3:  mov     edi, r13d
    mov     esi, r14d
    lea     rdx, [rip+dlg_title]
    mov     ecx, r15d
    call    draw_text
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
9:  ret

cpy:                                    # rdi = dest, rsi = text (159 max)
    xor     ecx, ecx
1:  mov     al, [rsi+rcx]
    mov     [rdi+rcx], al
    test    al, al
    jz      2f
    inc     ecx
    cmp     ecx, 159
    jb      1b
    mov     byte ptr [rdi+rcx], 0
2:  ret

cat:                                    # dlg_title += rsi
    lea     rdi, [rip+dlg_title]
    push    rsi
    call    str_len
    pop     rsi
    lea     rdi, [rip+dlg_title]
    add     rdi, rax
    jmp     cpy

.section .note.GNU-stack,"",@progbits
