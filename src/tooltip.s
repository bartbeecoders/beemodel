# =============================================================================
#  BeeModel - tooltips: rest the pointer on a menu item, a tool, a header
#  button or a widget for half a second and a box tells what it does - its
#  name, its shortcut, the operator's doc text and, when it cannot run now,
#  why. A press or leaving the target hides it until the next rest.
# =============================================================================
.intel_syntax noprefix
.include "const.inc"
.include "macros.inc"
.include "widgets.inc"

# exports
.globl tip_title
.globl tip_key
.globl tip_doc
.globl tip_why
.globl tip_hover
.globl wrap_text
.globl wt_hook
.globl tip_block
.globl tip_wait
.globl tip_tick
.globl tip_draw
.globl tip_shown
.globl tip_json

.equ TIP_MS,    500                     # the rest before a tooltip shows
.equ TIP_W,     340                     # the widest a tooltip gets
.equ LINE_H,    17

.section .bss
.align 8
tip_t0:         .skip 8                 # when the pointer came to rest (ns)
tip_id:         .skip 4                 # the target (hit id, index)
tip_idx:        .skip 4
tip_pending:    .skip 4
tip_shown:      .skip 4
tip_blocked:    .skip 4                 # after a press: none until it moves on
tip_title:      .skip 8                 # the content
tip_key:        .skip 8
tip_doc:        .skip 8
tip_why:        .skip 8
tip_keybuf:     .skip 32

.section .rodata
s_min:          .asciz "Minimize"
s_max:          .asciz "Maximize"
s_max_doc:      .asciz "Fill the screen with the window, or restore it (double-click the title bar)"
s_close:        .asciz "Close"
s_close_doc:    .asciz "Quit BeeModel (File > Exit)"
s_etype:        .asciz "Editor type"
s_etype_doc:    .asciz "Choose what this area shows: 3D viewport, outliner, properties, console, node editor, timeline and more"
s_why_pfx:      .asciz "Not now: "
j_tip_a:        .asciz "{\"name\":\"tooltip\",\"sub\":0,\"kind\":\"tooltip\",\"label\":"
j_tip_key:      .asciz ",\"key\":"
j_tip_doc:      .asciz ",\"value\":"
j_tip_why:      .asciz ",\"why\":"
j_null_t:       .asciz "null"

.text

# tip_hover(edi=hit id, esi=index) - the pointer is over this target now
tip_hover:
    cmp     edi, [rip+tip_id]
    jne     1f
    cmp     esi, [rip+tip_idx]
    je      9f
1:  mov     [rip+tip_id], edi
    mov     [rip+tip_idx], esi
    mov     dword ptr [rip+tip_blocked], 0
    cmp     dword ptr [rip+tip_shown], 0
    je      2f
    mov     dword ptr [rip+tip_shown], 0
    mov     dword ptr [rip+dirty], 1
2:  sub     rsp, 8
    call    tip_content                 # anything to say about it?
    mov     [rip+tip_pending], eax
    call    mono_ns
    mov     [rip+tip_t0], rax
    add     rsp, 8
9:  ret

# tip_block - a press: hide, and wait for the pointer to move on
tip_block:
    mov     dword ptr [rip+tip_blocked], 1
    mov     dword ptr [rip+tip_pending], 0
    cmp     dword ptr [rip+tip_shown], 0
    je      9f
    mov     dword ptr [rip+tip_shown], 0
    mov     dword ptr [rip+dirty], 1
9:  ret

# tip_wait -> eax = ms until a tooltip is due, -1 if none
tip_wait:
    mov     eax, -1
    cmp     dword ptr [rip+tip_pending], 0
    je      9f
    sub     rsp, 8
    call    mono_ns
    add     rsp, 8
    sub     rax, [rip+tip_t0]
    xor     edx, edx
    mov     ecx, 1000000
    div     rcx
    mov     ecx, [rip+tip_ms]           # (prefs)
    sub     ecx, eax
    xor     eax, eax
    test    ecx, ecx
    cmovg   eax, ecx
    inc     eax                         # (a millisecond late, never early)
9:  ret

# tip_tick - shows the tooltip once the pointer has rested long enough
tip_tick:
    cmp     dword ptr [rip+tip_pending], 0
    je      9f
    sub     rsp, 8
    call    tip_wait
    add     rsp, 8
    cmp     eax, 1
    ja      9f
    mov     dword ptr [rip+tip_pending], 0
    cmp     dword ptr [rip+tip_blocked], 0
    jne     9f
    mov     dword ptr [rip+tip_shown], 1
    mov     dword ptr [rip+dirty], 1
9:  ret

# tip_content -> eax = 1 if the target has something to say (sets tip_*)
tip_content:
    push    rbx
    xor     eax, eax
    mov     [rip+tip_title], rax
    mov     [rip+tip_key], rax
    mov     [rip+tip_doc], rax
    mov     [rip+tip_why], rax
    mov     ebx, [rip+tip_idx]
    mov     ecx, [rip+tip_id]
    cmp     ecx, HIT_MENU_ITEM
    je      .Ltc_menu
    cmp     ecx, HIT_SUBITEM
    je      .Ltc_sub
    cmp     ecx, HIT_TOOL
    je      .Ltc_tool
    cmp     ecx, HIT_AREA_BTN
    je      .Ltc_areabtn
    cmp     ecx, HIT_WIDGET
    je      .Ltc_widget
    cmp     ecx, HIT_AREA_TYPE
    je      .Ltc_etype
    cmp     ecx, HIT_BTN_MIN
    je      .Ltc_min
    cmp     ecx, HIT_BTN_MAX
    je      .Ltc_max
    cmp     ecx, HIT_BTN_CLOSE
    je      .Ltc_close
    jmp     .Ltc_none
.Ltc_menu:
    test    ebx, ebx
    js      .Ltc_none
    mov     eax, [rip+menu_open]
    test    eax, eax
    js      .Ltc_none
    lea     rcx, [rip+menu_items]
    mov     rcx, [rcx+rax*8]
    mov     rdi, [rcx+rbx*8]
    jmp     .Ltc_op
.Ltc_sub:
    test    ebx, ebx
    js      .Ltc_none
    mov     rcx, [rip+l1_items]
    mov     rdi, [rcx+rbx*8]
    jmp     .Ltc_op
.Ltc_tool:
    lea     rcx, [rip+tool_ops]
    mov     rdi, [rcx+rbx*8]
    jmp     .Ltc_op
.Ltc_areabtn:
    lea     rcx, [rip+area_btn_ops]
    mov     rdi, [rcx+rbx*8]
    jmp     .Ltc_op
.Ltc_widget:
    mov     edi, ebx                    # a row standing for an operator
    call    wg_op_of
    test    rax, rax
    jz      0f
    mov     rdi, rax
    jmp     .Ltc_op
0:  mov     edi, ebx
    call    wg_desc_of
    test    rax, rax
    jz      .Ltc_none
    cmp     dword ptr [rax+WD_KIND], WK_BUTTON
    jne     1f
    mov     rdi, [rax+WD_AUX]           # a button: its operator's tooltip
    test    rdi, rdi
    jnz     .Ltc_op
1:  mov     rcx, [rax+WD_TIP]           # else its own text, titled by its
    test    rcx, rcx                    #  label
    jz      .Ltc_none
    mov     [rip+tip_doc], rcx
    mov     rcx, [rax+WD_LABEL]
    mov     [rip+tip_title], rcx
    jmp     .Ltc_yes
.Ltc_etype:
    lea     rax, [rip+s_etype]
    lea     rcx, [rip+s_etype_doc]
    jmp     .Ltc_fixed
.Ltc_min:
    lea     rax, [rip+s_min]
    xor     ecx, ecx
    jmp     .Ltc_fixed
.Ltc_max:
    lea     rax, [rip+s_max]
    lea     rcx, [rip+s_max_doc]
    jmp     .Ltc_fixed
.Ltc_close:
    lea     rax, [rip+s_close]
    lea     rcx, [rip+s_close_doc]
.Ltc_fixed:
    mov     [rip+tip_title], rax
    mov     [rip+tip_doc], rcx
    jmp     .Ltc_yes
.Ltc_op:                                # rdi = operator (0: a separator)
    test    rdi, rdi
    jz      .Ltc_none
    cmp     qword ptr [rdi], SUBTAG     # (a submenu: nothing to add)
    je      .Ltc_none
    mov     rbx, rdi
    mov     rax, [rbx+OP_LABEL]
    mov     [rip+tip_title], rax
    mov     rax, [rbx+OP_DOC]
    mov     [rip+tip_doc], rax
    mov     rdi, rbx                    # (the key in use: prefs.s)
    call    key_eff
    mov     edi, eax
    call    fmt_key
    test    rax, rax
    jz      2f
    lea     rdi, [rip+tip_keybuf]       # (fmt_key's buffer is shared)
    mov     rsi, rax
    mov     ecx, 31
3:  mov     dl, [rsi]
    mov     [rdi], dl
    test    dl, dl
    jz      4f
    inc     rsi
    inc     rdi
    dec     ecx
    jnz     3b
    mov     byte ptr [rdi], 0
4:  lea     rax, [rip+tip_keybuf]
    mov     [rip+tip_key], rax
2:  mov     rdi, rbx
    call    op_poll
    mov     [rip+tip_why], rax
.Ltc_yes:
    call    help_note                   # (the Help area keeps it)
    mov     eax, 1
    pop     rbx
    ret
.Ltc_none:
    xor     eax, eax
    pop     rbx
    ret

# -----------------------------------------------------------------------------
# tip_draw - the box, below and right of the pointer, kept on screen
# -----------------------------------------------------------------------------
tip_draw:
    cmp     dword ptr [rip+tip_shown], 0
    je      .Ltd_ret
    push    rbx
    push    rbp
    push    r12
    push    r13
    push    r14
    push    r15
    sub     rsp, 24
    call    tip_content                 # (fresh: the reason may have changed)
    test    eax, eax
    jz      .Ltd_out
    # width: the title line, or the doc text wrapped at TIP_W
    mov     r12d, 0
    mov     rdi, [rip+tip_title]
    test    rdi, rdi
    jz      1f
    mov     edi, FONT_HEAD
    call    text_use
    mov     [rsp], eax
    mov     rdi, [rip+tip_title]
    call    text_width
    mov     r12d, eax
    mov     edi, [rsp]
    call    text_use
1:  mov     rdi, [rip+tip_key]
    test    rdi, rdi
    jz      2f
    call    text_width
    lea     r12d, [r12+rax+24]
2:  mov     edi, FONT_SMALL             # the doc lines
    call    text_use
    mov     [rsp], eax
    mov     rdi, [rip+tip_doc]
    mov     esi, TIP_W-20
    xor     edx, edx                    # measure only
    xor     ecx, ecx
    call    wrap_text
    mov     r13d, eax                   # lines
    cmp     edx, r12d
    cmovg   r12d, edx                   # widest
    xor     r14d, r14d                  # reason lines
    mov     rdi, [rip+tip_why]
    test    rdi, rdi
    jz      3f
    mov     esi, TIP_W-20
    xor     edx, edx
    xor     ecx, ecx
    call    wrap_text
    mov     r14d, eax
    lea     rdi, [rip+s_why_pfx]
    call    text_width
    add     edx, eax
    cmp     edx, r12d
    cmovg   r12d, edx
3:  mov     edi, [rsp]
    call    text_use
    add     r12d, 20                    # box width
    cmp     r12d, TIP_W
    jle     4f
    mov     r12d, TIP_W
4:  lea     eax, [r13+r14]              # box height
    imul    eax, LINE_H
    add     eax, 12+20
    mov     [rsp+8], eax
    mov     ebx, [rip+ptr_x]            # placed below right of the pointer,
    add     ebx, 12                     #  on screen
    mov     eax, [rip+win_w]
    sub     eax, r12d
    sub     eax, 6
    cmp     ebx, eax
    cmovg   ebx, eax
    mov     ebp, [rip+ptr_y]
    add     ebp, 22
    mov     eax, [rip+win_h]
    sub     eax, [rsp+8]
    sub     eax, 6
    cmp     ebp, eax
    jle     5f
    mov     ebp, [rip+ptr_y]            # (no room below: above it)
    sub     ebp, [rsp+8]
    sub     ebp, 8
5:  mov     edi, ebx
    mov     esi, ebp
    mov     edx, r12d
    mov     ecx, [rsp+8]
    mov     r8d, COL_DROP_BORDER
    call    popup_frame
    lea     r15d, [rbp+6]               # y
    mov     rdx, [rip+tip_title]        # title (bold) and shortcut (dim)
    test    rdx, rdx
    jz      6f
    lea     edi, [rbx+10]
    mov     esi, r15d
    mov     ecx, COL_TEXT
    call    draw_heading
6:  mov     rdi, [rip+tip_key]
    test    rdi, rdi
    jz      7f
    call    text_width
    lea     edi, [rbx+r12-10]
    sub     edi, eax
    mov     esi, r15d
    mov     rdx, [rip+tip_key]
    mov     ecx, COL_TEXT_DIM
    call    draw_text
7:  add     r15d, 20
    mov     edi, FONT_SMALL
    call    text_use
    mov     [rsp], eax
    mov     rdi, [rip+tip_doc]          # the doc, wrapped
    lea     esi, [r12-20]
    lea     edx, [rbx+10]
    mov     ecx, r15d
    mov     r8d, COL_TEXT_DIM
    call    wrap_text
    imul    eax, LINE_H
    add     r15d, eax
    mov     rdi, [rip+tip_why]          # why it cannot run now
    test    rdi, rdi
    jz      8f
    lea     edi, [rbx+10]
    mov     esi, r15d
    lea     rdx, [rip+s_why_pfx]
    mov     ecx, COL_WARN
    call    draw_text
    lea     rdi, [rip+s_why_pfx]
    call    text_width
    mov     rdi, [rip+tip_why]
    lea     esi, [r12-20]
    sub     esi, eax
    lea     edx, [rbx+10+rax]
    mov     ecx, r15d
    mov     r8d, COL_WARN
    call    wrap_text
8:  mov     edi, [rsp]
    call    text_use
.Ltd_out:
    add     rsp, 24
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbp
    pop     rbx
.Ltd_ret:
    ret

# tip_json - the tooltip on screen, for ui_tree: appended to wb as one more
#   entry, kind "tooltip" (nothing when none shows); edi = 1 if entries came
#   before it
tip_json:
    cmp     dword ptr [rip+tip_shown], 0
    je      9f
    push    rbx
    mov     ebx, edi
    call    tip_content
    test    eax, eax
    jz      8f
    test    ebx, ebx
    jz      1f
    mov     edi, ','
    call    wb_char
1:  lea     rsi, [rip+j_tip_a]
    call    wb_str
    mov     rsi, [rip+tip_title]
    call    jq_or_null
    lea     rsi, [rip+j_tip_key]
    call    wb_str
    mov     rsi, [rip+tip_key]
    call    jq_or_null
    lea     rsi, [rip+j_tip_doc]
    call    wb_str
    mov     rsi, [rip+tip_doc]
    call    jq_or_null
    lea     rsi, [rip+j_tip_why]
    call    wb_str
    mov     rsi, [rip+tip_why]
    call    jq_or_null
    mov     edi, '}'
    call    wb_char
8:  pop     rbx
9:  ret

jq_or_null:                             # rsi = text or 0
    test    rsi, rsi
    jnz     jb_q
    lea     rsi, [rip+j_null_t]
    jmp     wb_str

# wrap_text(rdi=text or 0, esi=width, edx=x (0: measure only), ecx=y,
#   r8d=colour) -> eax = lines, edx = widest line's width
#   breaks at spaces; a word wider than the line goes on a line of its own
wrap_text:
    push    rbx
    push    rbp
    push    r12
    push    r13
    push    r14
    push    r15
    sub     rsp, 40
    xor     eax, eax
    mov     [rsp+24], eax               # lines
    mov     [rsp+28], eax               # widest
    test    rdi, rdi
    jz      .Lwt_done
    mov     rbx, rdi                    # line start
    mov     r12d, esi                   # width
    mov     r13d, edx                   # x
    mov     r14d, ecx                   # y
    mov     [rsp+32], r8d
.Lwt_line:
    cmp     byte ptr [rbx], 0
    je      .Lwt_done
    cmp     byte ptr [rbx], ' '         # (no leading spaces)
    jne     1f
    inc     rbx
    jmp     .Lwt_line
1:  xor     r15d, r15d                  # bytes that fit (up to a space)
    xor     ebp, ebp                    # scan position
2:  movzx   eax, byte ptr [rbx+rbp]
    test    eax, eax
    jz      3f
    cmp     eax, ' '
    jne     4f
3:  mov     rdi, rbx                    # a word ends: does the line fit?
    mov     esi, ebp
    call    text_width_n
    cmp     eax, r12d
    jg      5f
    mov     r15d, ebp
    mov     [rsp+16], eax
    cmp     byte ptr [rbx+rbp], 0
    je      5f
4:  inc     ebp
    jmp     2b
5:  test    r15d, r15d                  # one long word: take all of it
    jnz     6f
    mov     r15d, ebp
    mov     rdi, rbx
    mov     esi, ebp
    call    text_width_n
    mov     [rsp+16], eax
6:  mov     eax, [rsp+16]
    cmp     eax, [rsp+28]
    jle     7f
    mov     [rsp+28], eax
7:  test    r13d, r13d                  # draw it (a copy: the text may
    jz      8f                          #  be read-only)
    mov     rax, [rip+wt_hook]          # (a hook first: where each line is,
    test    rax, rax                    #  e.g. a selection drawn under it)
    jz      71f
    mov     rdi, rbx
    mov     esi, r15d
    mov     edx, r13d
    mov     ecx, r14d
    call    rax
71: mov     rdi, rbx
    mov     esi, r15d
    lea     rdx, [rip+wt_buf]
    call    copy_n
    mov     edi, r13d
    mov     esi, r14d
    lea     rdx, [rip+wt_buf]
    mov     ecx, [rsp+32]
    call    draw_text
8:  add     rbx, r15
    add     r14d, LINE_H
    inc     dword ptr [rsp+24]
    jmp     .Lwt_line
.Lwt_done:
    mov     eax, [rsp+24]
    mov     edx, [rsp+28]
    add     rsp, 40
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbp
    pop     rbx
    ret

.section .bss
.align 8
wt_hook:        .skip 8                 # wrap_text: fn(rdi=line, esi=bytes, edx=x, ecx=y)
.text

# copy_n(rdi=src, esi=bytes, rdx=dest) - copies and ends the text (255 max)
copy_n:
    cmp     esi, 255
    jbe     1f
    mov     esi, 255
1:  xor     ecx, ecx
2:  cmp     ecx, esi
    jae     3f
    mov     al, [rdi+rcx]
    mov     [rdx+rcx], al
    inc     ecx
    jmp     2b
3:  mov     byte ptr [rdx+rcx], 0
    ret

.section .bss
wt_buf:         .skip 256

.section .note.GNU-stack,"",@progbits
