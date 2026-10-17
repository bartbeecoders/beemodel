# =============================================================================
#  BeeModel - the widget toolkit: buttons, toggles, number fields, sliders,
#  text fields, dropdown lists, collapsible sections, tabs and scrolled
#  regions, all with the same look and the same mouse and keyboard rules.
#
#  Immediate mode. A panel calls wg(desc, x, y, w, ptr, sub) while it draws;
#  the call draws the widget for the value at ptr and records its rectangle
#  in this frame's list. Input between frames is matched against that list,
#  so panels need no hit testing of their own. A widget's id is a hash of its
#  descriptor's name and the sub index, stable from frame to frame.
#
#  Rules (UI plan, "Mouse & keyboard rules"):
#    drag a number sideways to scrub it (Shift: fine, Ctrl: whole steps x10);
#    click it to type a value or an expression (25mm, 2*pi, 90 in a degree
#    field); Enter confirms, Esc cancels, Tab / Shift+Tab move on;
#    Ctrl+wheel steps a number or an option; the wheel scrolls a region.
#  A scrub, a typed value or a toggle is one undo step when the descriptor
#  names one. ui_tree (MCP) lists every widget of the frame, for agents and
#  tests.
# =============================================================================
.intel_syntax noprefix
.include "const.inc"
.include "macros.inc"
.include "widgets.inc"

# exports
.globl wg
.globl wg_frame
.globl wg_hit
.globl wg_cursor
.globl wg_press
.globl wg_drag
.globl wg_release
.globl wg_wheel
.globl wg_key
.globl wg_editing
.globl wg_by_enter
.globl wg_commit
.globl wg_pop_draw
.globl wg_pop_hit
.globl wg_pop_press
.globl wg_pop_open
.globl wg_scroll_begin
.globl wg_scroll_end
.globl wg_tree_json
.globl wg_ftoa
.globl wg_desc_of
.globl wg_find
.globl wg_clicked
.globl wg_n
.globl wg_set_label
.globl wg_set_op
.globl wg_edit_last
.globl wg_edit_named
.globl wg_op_of
.globl wg_clip_key

.equ WG_MAX,    768
.equ WG_SZ,     64
.equ E_ID,      0
.equ E_KIND,    4
.equ E_X,       8
.equ E_Y,       12
.equ E_W,       16
.equ E_H,       20
.equ E_PTR,     24
.equ E_DESC,    32
.equ E_SUB,     40
.equ E_DRAWX,   44              # (scroll: content top; thumb: track y)
.equ E_AUX,     48              # (scroll: content height; a row: its text)
.equ E_OP,      56              # a row's operator (tooltips), 0 none
.equ CLOSED_N,  64
.equ POP_ROW,   22
.equ SCROLL_N,  4               # nested scrolled regions

.section .bss
.align 8
wg_list:        .skip WG_MAX*WG_SZ
wg_n:           .skip 4
wg_active:      .skip 4             # id pressed (0 = none)
wg_scrubbed:    .skip 4
wg_kfocus:      .skip 4             # the widget with the keyboard focus (0: none)
wg_x0:          .skip 4
wg_y0:          .skip 4
wg_v0:          .skip 4             # value when the press began
wg_clicked:     .skip 4             # a button's id, reported by its next wg
wg_edit:        .skip 4             # id being typed into
wg_by_enter:    .skip 4             # the commit is Enter's
wg_pop_open:    .skip 4
wg_pop_hot:     .skip 4
wg_pop_x:       .skip 4
wg_pop_y:       .skip 4
wg_pop_w:       .skip 4
wg_closed:      .skip CLOSED_N*4    # ids of closed sections
.align 8
wg_act_e:       .skip WG_SZ         # entry being pressed / dragged
wg_edit_e:      .skip WG_SZ         # entry being typed into
wg_pop_e:       .skip WG_SZ         # the enum whose list is open
wg_sc_depth:    .skip 4
.align 8
wg_sc_stack:    .skip SCROLL_N*32   # clip (4 x i32), entry index, top y
wg_txt:         .skip 64

.section .rodata
s_secret_set:   .asciz "(set)"
s_secret_none:  .asciz ""
.align 4
f_1:            .float 1.0
f_0:            .float 0.0
f_tenth:        .float 0.1
f_ten:          .float 10.0
f_half:         .float 0.5
f_r2d:          .float 57.29577951
.align 8
d_d2r:          .double 0.017453292519943295
d_pow10:        .double 1.0, 10.0, 100.0, 1000.0, 10000.0, 100000.0, 1000000.0
d_half:         .double 0.5
s_deg:          .asciz "\xc2\xb0"
s_deg_bm:       .asciz " deg"
s_bad_value:    .asciz "not a value: "
# ui_tree JSON
j_tree_a:       .asciz "{\"widgets\":["
j_tree_b:       .asciz "]}"
k_name:         .asciz "name"
k_sub:          .asciz ",\"sub\":"
k_kind:         .asciz ",\"kind\":"
k_x:            .asciz ",\"x\":"
k_y:            .asciz ",\"y\":"
k_w:            .asciz ",\"w\":"
k_h:            .asciz ",\"h\":"
k_value:        .asciz ",\"value\":"
k_label:        .asciz ",\"label\":"
k_edit:         .asciz ",\"editing\":true"
k_focus:        .asciz ",\"focused\":true"
k_list:         .asciz ",\"sub\":-1,\"kind\":\"list\",\"x\":"
j_null:         .asciz "null"
kn_button:      .asciz "button"
kn_toggle:      .asciz "toggle"
kn_float:       .asciz "float"
kn_int:         .asciz "int"
kn_slider:      .asciz "slider"
kn_text:        .asciz "text"
kn_enum:        .asciz "enum"
kn_section:     .asciz "section"
kn_tabs:        .asciz "tabs"
kn_scroll:      .asciz "scroll"
kn_thumb:       .asciz "scrollbar"
kn_row:         .asciz "row"
kn_path:        .asciz "path"
kn_color:       .asciz "color"
kn_pad:         .asciz "pad"
.align 8
kind_names:     .quad 0, kn_button, kn_toggle, kn_float, kn_int, kn_slider, kn_text
                .quad kn_enum, kn_section, kn_tabs, kn_scroll, kn_thumb, kn_row, kn_path
                .quad kn_color, kn_pad

.text

# -----------------------------------------------------------------------------
# wg_frame - a new frame: the list starts empty
# -----------------------------------------------------------------------------
wg_frame:
    mov     dword ptr [rip+wg_n], 0
    mov     dword ptr [rip+wg_sc_depth], 0
    ret

# wg_id(rdi=desc, esi=sub) -> eax = nonzero id
wg_id:
    mov     rax, [rdi+WD_NAME]
    mov     rcx, rax
    shr     rcx, 32
    xor     eax, ecx
    imul    eax, eax, 0x9e3779b1
    mov     ecx, esi
    imul    ecx, ecx, 0x85ebca6b
    xor     eax, ecx
    mov     ecx, eax
    shr     ecx, 15
    xor     eax, ecx
    or      eax, 1
    ret

# wg_find(edi=id) -> rax = entry in this frame's list, 0 if none
wg_find:
    lea     rax, [rip+wg_list]
    mov     ecx, [rip+wg_n]
1:  test    ecx, ecx
    jz      2f
    cmp     [rax+E_ID], edi
    je      9f
    add     rax, WG_SZ
    dec     ecx
    jmp     1b
2:  xor     eax, eax
9:  ret

# wg_set_label(rdi=text) - the widget just drawn shows this label in ui_tree
#   (rows whose text is not in their descriptor: file names)
wg_set_label:
    mov     eax, [rip+wg_n]
    test    eax, eax
    jz      1f
    dec     eax
    imul    eax, eax, WG_SZ
    lea     rcx, [rip+wg_list]
    mov     [rcx+rax+E_AUX], rdi
1:  ret

# wg_set_op(rdi=operator) - the widget just drawn stands for it (tooltips)
wg_set_op:
    mov     eax, [rip+wg_n]
    test    eax, eax
    jz      1f
    dec     eax
    imul    eax, eax, WG_SZ
    lea     rcx, [rip+wg_list]
    mov     [rcx+rax+E_OP], rdi
1:  ret

# wg_edit_last - start typing into the widget just drawn (inline rename)
wg_edit_last:
    mov     eax, [rip+wg_n]
    test    eax, eax
    jz      1f
    dec     eax
    imul    eax, eax, WG_SZ
    lea     rdi, [rip+wg_list]
    add     rdi, rax
    jmp     edit_begin
1:  ret

# wg_edit_named(rdi=descriptor name) - start typing into that widget, if
#   it is on screen
wg_edit_named:
    push    rbx
    push    r12
    sub     rsp, 8
    mov     r12, rdi
    lea     rbx, [rip+wg_list]
    mov     ecx, [rip+wg_n]
1:  test    ecx, ecx
    jz      9f
    push    rcx
    mov     rax, [rbx+E_DESC]
    mov     rdi, [rax+WD_NAME]
    mov     rsi, r12
    call    str_eq
    pop     rcx
    test    eax, eax
    jnz     2f
    add     rbx, WG_SZ
    dec     ecx
    jmp     1b
2:  mov     rdi, rbx
    call    edit_begin
9:  add     rsp, 8
    pop     r12
    pop     rbx
    ret

# wg_op_of(edi=id) -> rax = the operator that widget stands for, or 0
wg_op_of:
    call    wg_find
    test    rax, rax
    jz      1f
    mov     rax, [rax+E_OP]
1:  ret

# wg_desc_of(edi=id) -> rax = that widget's descriptor, 0 if not on screen
wg_desc_of:
    call    wg_find
    test    rax, rax
    jz      1f
    mov     rax, [rax+E_DESC]
1:  ret

# wg_add(rdi=desc, esi=x, edx=y, ecx=w, r8d=h, r9=ptr, [r10d]=sub, eax=id)
#   -> rax = entry (0 when the list is full)
wg_add:
    push    rbx
    mov     ebx, [rip+wg_n]
    cmp     ebx, WG_MAX
    jae     8f
    inc     dword ptr [rip+wg_n]
    imul    ebx, ebx, WG_SZ
    push    rax
    lea     rax, [rip+wg_list]
    add     rbx, rax
    pop     rax
    mov     [rbx+E_ID], eax
    mov     eax, [rdi+WD_KIND]
    mov     [rbx+E_KIND], eax
    mov     [rbx+E_X], esi
    mov     [rbx+E_Y], edx
    mov     [rbx+E_W], ecx
    mov     [rbx+E_H], r8d
    mov     [rbx+E_PTR], r9
    mov     [rbx+E_DESC], rdi
    mov     [rbx+E_SUB], r10d
    mov     [rbx+E_DRAWX], esi
    mov     qword ptr [rbx+E_AUX], 0
    mov     qword ptr [rbx+E_OP], 0
    mov     rax, rbx
    pop     rbx
    ret
8:  xor     eax, eax
    pop     rbx
    ret

# -----------------------------------------------------------------------------
# wg(rdi=desc, esi=x, edx=y, ecx=w, r8=ptr, r9d=sub) -> eax
#   buttons: 1 the frame after a click; sections: 1 while open; else 0
# -----------------------------------------------------------------------------
wg:
    push    rbx
    push    rbp
    push    r12
    push    r13
    push    r14
    push    r15
    sub     rsp, 40
    mov     rbx, rdi                    # desc
    mov     r12d, esi                   # x
    mov     r13d, edx                   # y
    mov     r14d, ecx                   # w
    mov     r15, r8                     # ptr
    mov     [rsp], r9d                  # sub
    mov     esi, r9d
    call    wg_id
    mov     ebp, eax                    # id
    mov     edx, WG_H
    test    dword ptr [rbx+WD_FLAGS], WGF_COMPACT
    jz      0f
    mov     edx, 18
0:  cmp     dword ptr [rbx+WD_KIND], WK_SECTION
    jne     11f
    mov     edx, 24
11: cmp     dword ptr [rbx+WD_KIND], WK_PAD  # (a pad: its own height)
    jne     1f
    mov     edx, [rbx+WD_N]
1:  mov     [rsp+4], edx                # h
    lea     eax, [rdx-CHAR_H]
    shr     eax, 1
    mov     [rsp+28], eax               # text offset in the row
    mov     rdi, rbx                    # record it, if any of it is visible
    mov     esi, r12d
    mov     edx, r13d
    mov     ecx, r14d
    mov     r8d, [rsp+4]
    mov     r9, r15
    mov     r10d, [rsp]
    mov     eax, ebp
    call    wg_add
    # state -> [rsp+8]: 1 hot, 2 pressed, 4 typing
    xor     eax, eax
    cmp     dword ptr [rip+hover_id], HIT_WIDGET
    jne     2f
    cmp     [rip+hover_idx], ebp
    jne     2f
    or      eax, 1
2:  cmp     [rip+wg_active], ebp
    jne     3f
    or      eax, 2
3:  cmp     [rip+wg_edit], ebp
    jne     4f
    or      eax, 4
4:  mov     [rsp+8], eax
    cmp     ebp, [rip+wg_kfocus]        # keyboard focus: a ring around it
    jne     5f
    lea     edi, [r12-2]
    lea     esi, [r13-2]
    lea     edx, [r14+4]
    mov     ecx, [rsp+4]
    add     ecx, 4
    mov     r8d, COL_FOCUS
    call    rect_outline
    lea     edi, [r12-1]
    lea     esi, [r13-1]
    lea     edx, [r14+2]
    mov     ecx, [rsp+4]
    add     ecx, 2
    mov     r8d, COL_FOCUS
    call    rect_outline
5:  mov     eax, [rbx+WD_KIND]
    cmp     eax, WK_BUTTON
    je      .Lwg_button
    cmp     eax, WK_TOGGLE
    je      .Lwg_toggle
    cmp     eax, WK_SECTION
    je      .Lwg_section
    cmp     eax, WK_ENUM
    je      .Lwg_enum
    cmp     eax, WK_TABS
    je      .Lwg_tabs
    cmp     eax, WK_ROW
    je      .Lwg_row
    cmp     eax, WK_COLOR
    je      .Lwg_color
    cmp     eax, WK_PAD
    je      .Lwg_pad
    jmp     .Lwg_field

# ---- a pad: only its hit area (the caller draws it) ---------------------------
.Lwg_pad:
    xor     eax, eax
    jmp     .Lwg_ret

# ---- a colour: the label, then a swatch of it ----------------------------------
.Lwg_color:
    mov     r8d, COL_FIELD
    test    dword ptr [rsp+8], 1
    jz      1f
    mov     r8d, COL_FIELD_HOVER
1:  mov     edi, r12d
    mov     esi, r13d
    mov     edx, r14d
    mov     ecx, [rsp+4]
    mov     r9d, FIELD_R
    call    fill_rrect
    mov     rdx, [rbx+WD_LABEL]
    test    rdx, rdx
    jz      2f
    lea     edi, [r12+8]
    mov     esi, r13d
    add     esi, [rsp+28]
    mov     ecx, COL_TEXT_DIM
    call    draw_text
2:  mov     rdi, r15                    # the swatch: the right half
    call    cpk_rgb_of
    mov     r8d, eax
    mov     eax, r14d
    shr     eax, 1
    lea     edi, [r12+rax]
    lea     esi, [r13+3]
    mov     edx, eax
    sub     edx, 3
    mov     ecx, [rsp+4]
    sub     ecx, 6
    mov     r9d, FIELD_R-1
    call    fill_rrect
    xor     eax, eax
    jmp     .Lwg_ret

# ---- a list row: lit when selected (or hot); the caller draws its content -----
.Lwg_row:
    mov     r8d, COL_ACCENT_DARK
    mov     eax, [rsp]
    cmp     eax, [r15]
    je      1f
    mov     r8d, COL_HOVER
    test    dword ptr [rsp+8], 1
    jz      2f
1:  mov     edi, r12d
    mov     esi, r13d
    mov     edx, r14d
    mov     ecx, [rsp+4]
    mov     r9d, FIELD_R
    call    fill_rrect
2:  xor     eax, eax
    jmp     .Lwg_ret

# ---- button ------------------------------------------------------------------
.Lwg_button:
    test    dword ptr [rbx+WD_FLAGS], WGF_NODRAW
    jnz     5f
    test    dword ptr [rbx+WD_FLAGS], WGF_ICON
    jnz     .Lwg_iconbtn
    mov     r8d, COL_BTN
    test    dword ptr [rbx+WD_FLAGS], WGF_PRIMARY
    jz      1f
    mov     r8d, COL_ACCENT
1:  test    dword ptr [rsp+8], 1
    jz      2f
    mov     r8d, COL_BTN_HOVER
2:  test    dword ptr [rsp+8], 2
    jz      3f
    mov     r8d, COL_ACCENT_DARK
3:  mov     edi, r12d
    mov     esi, r13d
    mov     edx, r14d
    mov     ecx, [rsp+4]
    mov     r9d, FIELD_R
    call    fill_rrect
    mov     rdi, [rbx+WD_LABEL]         # caption, centred
    test    rdi, rdi
    jz      5f
    call    text_width
    mov     edi, r14d
    sub     edi, eax
    sar     edi, 1
    add     edi, r12d
    mov     esi, r13d
    add     esi, [rsp+28]
    mov     rdx, [rbx+WD_LABEL]
    mov     ecx, COL_TEXT
    test    dword ptr [rbx+WD_FLAGS], WGF_PRIMARY
    jz      4f
    mov     ecx, COL_TEXT_DARK
4:  call    draw_text
5:  xor     eax, eax
    cmp     [rip+wg_clicked], ebp
    jne     .Lwg_ret
    mov     dword ptr [rip+wg_clicked], 0
    mov     eax, 1
    jmp     .Lwg_ret

# ---- an icon button: lit while its operator is on, greyed when it cannot run --
.Lwg_iconbtn:
    mov     dword ptr [rsp+16], COL_TEXT
    mov     rdi, [rbx+WD_AUX]
    test    rdi, rdi
    jz      3f
    call    op_checked
    cmp     eax, 1
    jne     1f
    mov     dword ptr [rsp+16], COL_ACCENT
    mov     r8d, COL_ACCENT_DARK
    jmp     2f
1:  mov     rdi, [rbx+WD_AUX]
    call    op_poll
    test    rax, rax
    jz      3f
    mov     dword ptr [rsp+16], COL_TEXT_OFF
3:  test    dword ptr [rsp+8], 1        # hover
    jz      4f
    mov     r8d, COL_BTN_HOVER
2:  mov     edi, r12d
    mov     esi, r13d
    mov     edx, r14d
    mov     ecx, [rsp+4]
    mov     r9d, FIELD_R
    call    fill_rrect
4:  mov     edi, r14d                   # the icon, centred
    sub     edi, 16
    sar     edi, 1
    add     edi, r12d
    mov     esi, [rsp+4]
    sub     esi, 16
    sar     esi, 1
    add     esi, r13d
    mov     edx, [rbx+WD_N]
    mov     r8d, [rsp+16]
    call    draw_icon
    jmp     5b

# ---- toggle ------------------------------------------------------------------
.Lwg_toggle:
    mov     r8d, COL_SEPARATOR          # box: border then inside
    test    dword ptr [rsp+8], 1
    jz      1f
    mov     r8d, COL_TEXT_DIM
1:  cmp     dword ptr [r15], 0
    je      2f
    mov     r8d, COL_ACCENT
2:  mov     edi, r12d
    lea     esi, [r13+4]
    mov     edx, 14
    mov     ecx, 14
    mov     r9d, 3
    call    fill_rrect
    cmp     dword ptr [r15], 0
    jne     3f
    lea     edi, [r12+1]
    lea     esi, [r13+5]
    mov     edx, 12
    mov     ecx, 12
    mov     r8d, COL_FIELD
    mov     r9d, 2
    call    fill_rrect
    jmp     4f
3:  lea     edi, [r12+3]                # check mark
    lea     esi, [r13+11]
    lea     edx, [r12+6]
    lea     ecx, [r13+14]
    mov     r8d, COL_TEXT_DARK
    call    draw_line_aa
    lea     edi, [r12+6]
    lea     esi, [r13+14]
    lea     edx, [r12+11]
    lea     ecx, [r13+7]
    mov     r8d, COL_TEXT_DARK
    call    draw_line_aa
    lea     edi, [r12+3]
    lea     esi, [r13+12]
    lea     edx, [r12+6]
    lea     ecx, [r13+15]
    mov     r8d, COL_TEXT_DARK
    call    draw_line_aa
    lea     edi, [r12+6]
    lea     esi, [r13+15]
    lea     edx, [r12+11]
    lea     ecx, [r13+8]
    mov     r8d, COL_TEXT_DARK
    call    draw_line_aa
4:  mov     rdx, [rbx+WD_LABEL]
    test    rdx, rdx
    jz      5f
    lea     edi, [r12+22]
    lea     esi, [r13+3]
    mov     ecx, COL_TEXT
    call    draw_text
5:  xor     eax, eax
    jmp     .Lwg_ret

# ---- section header ----------------------------------------------------------
.Lwg_section:
    test    dword ptr [rsp+8], 1
    jz      1f
    mov     edi, r12d
    mov     esi, r13d
    mov     edx, r14d
    mov     ecx, 24
    mov     r8d, COL_HOVER
    mov     r9d, FIELD_R
    call    fill_rrect
1:  mov     edi, ebp
    call    closed_find
    mov     [rsp+12], eax               # >= 0: closed
    test    eax, eax
    jns     2f
    lea     edi, [r12+5]                # open: a down-pointing chevron
    lea     esi, [r13+10]
    lea     edx, [r12+9]
    lea     ecx, [r13+14]
    mov     r8d, COL_TEXT_DIM
    call    draw_line_aa
    lea     edi, [r12+9]
    lea     esi, [r13+14]
    lea     edx, [r12+13]
    lea     ecx, [r13+10]
    mov     r8d, COL_TEXT_DIM
    call    draw_line_aa
    jmp     3f
2:  lea     edi, [r12+7]                # closed: right-pointing
    lea     esi, [r13+8]
    lea     edx, [r12+11]
    lea     ecx, [r13+12]
    mov     r8d, COL_TEXT_DIM
    call    draw_line_aa
    lea     edi, [r12+11]
    lea     esi, [r13+12]
    lea     edx, [r12+7]
    lea     ecx, [r13+16]
    mov     r8d, COL_TEXT_DIM
    call    draw_line_aa
3:  mov     rdx, [rbx+WD_LABEL]
    test    rdx, rdx
    jz      4f
    lea     edi, [r12+20]
    lea     esi, [r13+4]
    mov     ecx, COL_ACCENT
    call    draw_heading
4:  xor     eax, eax
    cmp     dword ptr [rsp+12], 0
    jns     .Lwg_ret
    mov     eax, 1
    jmp     .Lwg_ret

# ---- enum: the current option and a down arrow; click opens the list ---------
.Lwg_enum:
    mov     r8d, COL_BTN
    test    dword ptr [rsp+8], 1
    jz      1f
    mov     r8d, COL_BTN_HOVER
1:  mov     edi, r12d
    mov     esi, r13d
    mov     edx, r14d
    mov     ecx, WG_H
    mov     r9d, FIELD_R
    call    fill_rrect
    mov     rdi, rbx
    call    enum_list
    mov     ecx, [r15]
    cmp     ecx, edx
    jae     2f
    mov     rdx, [rax+rcx*8]
    lea     edi, [r12+8]
    lea     esi, [r13+3]
    mov     ecx, COL_TEXT
    call    draw_text
2:  lea     edi, [r12+r14-16]           # chevron
    lea     esi, [r13+9]
    lea     edx, [r12+r14-12]
    lea     ecx, [r13+13]
    mov     r8d, COL_TEXT_DIM
    call    draw_line_aa
    lea     edi, [r12+r14-12]
    lea     esi, [r13+13]
    lea     edx, [r12+r14-8]
    lea     ecx, [r13+9]
    mov     r8d, COL_TEXT_DIM
    call    draw_line_aa
    xor     eax, eax
    jmp     .Lwg_ret

# ---- tabs: n equal tabs, the current one raised with an accent line ----------
.Lwg_tabs:
    mov     ecx, [rbx+WD_N]
    test    ecx, ecx
    jz      9f
    mov     eax, r14d
    xor     edx, edx
    div     ecx
    mov     [rsp+16], eax               # tab width
    mov     dword ptr [rsp+20], 0       # i
1:  mov     eax, [rsp+20]
    cmp     eax, [rbx+WD_N]
    jae     9f
    imul    eax, [rsp+16]
    lea     edi, [r12+rax]
    mov     [rsp+24], edi
    mov     esi, r13d
    mov     edx, [rsp+16]
    dec     edx
    mov     ecx, WG_H
    mov     r8d, COL_PANE_HDR
    mov     eax, [rsp+20]
    cmp     eax, [r15]
    jne     2f
    mov     r8d, COL_PANE_BG
2:  call    fill_rect
    mov     eax, [rsp+20]
    cmp     eax, [r15]
    jne     3f
    mov     edi, [rsp+24]
    lea     esi, [r13+WG_H-2]
    mov     edx, [rsp+16]
    dec     edx
    mov     ecx, 2
    mov     r8d, COL_ACCENT
    call    fill_rect
3:  mov     eax, [rsp+20]               # its label, centred
    mov     rcx, [rbx+WD_AUX]
    mov     rdi, [rcx+rax*8]
    call    text_width
    mov     edi, [rsp+16]
    sub     edi, eax
    sar     edi, 1
    add     edi, [rsp+24]
    lea     esi, [r13+3]
    mov     eax, [rsp+20]
    mov     rcx, [rbx+WD_AUX]
    mov     rdx, [rcx+rax*8]
    mov     ecx, COL_TEXT_DIM
    mov     eax, [rsp+20]
    cmp     eax, [r15]
    jne     4f
    mov     ecx, COL_TEXT
4:  call    draw_text
    inc     dword ptr [rsp+20]
    jmp     1b
9:  xor     eax, eax
    jmp     .Lwg_ret

# ---- number, slider and text fields ------------------------------------------
.Lwg_field:
    mov     r8d, COL_FIELD
    test    dword ptr [rsp+8], 1
    jz      1f
    mov     r8d, COL_FIELD_HOVER
1:  test    dword ptr [rsp+8], 4        # typing: a focus ring
    jz      2f
    mov     edi, r12d
    mov     esi, r13d
    mov     edx, r14d
    mov     ecx, [rsp+4]
    mov     r8d, COL_FOCUS
    mov     r9d, FIELD_R
    call    fill_rrect
    lea     edi, [r12+1]
    lea     esi, [r13+1]
    lea     edx, [r14-2]
    mov     ecx, [rsp+4]
    sub     ecx, 2
    mov     r8d, COL_FIELD
    mov     r9d, FIELD_R-1
    call    fill_rrect
    mov     edi, r12d
    mov     esi, r13d
    add     esi, [rsp+28]
    mov     edx, r14d
    call    edit_draw
    xor     eax, eax
    jmp     .Lwg_ret
2:  mov     edi, r12d
    mov     esi, r13d
    mov     edx, r14d
    mov     ecx, [rsp+4]
    mov     r9d, FIELD_R
    call    fill_rrect
    cmp     dword ptr [rbx+WD_KIND], WK_SLIDER
    jne     3f
    movss   xmm0, [r15]                 # slider: the filled part
    subss   xmm0, [rbx+WD_MIN]
    movss   xmm1, [rbx+WD_MAX]
    subss   xmm1, [rbx+WD_MIN]
    xorps   xmm2, xmm2
    comiss  xmm1, xmm2
    jbe     3f
    divss   xmm0, xmm1
    maxss   xmm0, xmm2
    minss   xmm0, [rip+f_1]
    cvtsi2ss xmm1, r14d
    mulss   xmm0, xmm1
    cvttss2si edx, xmm0
    test    edx, edx
    jle     3f
    mov     edi, r12d
    mov     esi, r13d
    mov     ecx, [rsp+4]
    mov     r8d, COL_ACCENT_DARK
    mov     r9d, FIELD_R
    call    fill_rrect
3:  mov     rdx, [rbx+WD_LABEL]         # label on the left (a text field's
    test    rdx, rdx                    #  is a caption beside it instead)
    jz      4f
    cmp     dword ptr [rbx+WD_KIND], WK_TEXT
    je      4f
    lea     edi, [r12+7]
    mov     esi, r13d
    add     esi, [rsp+28]
    mov     ecx, COL_TEXT_DIM
    call    draw_text
4:  mov     rdi, rbx                    # value: right-aligned after a label,
    mov     rsi, r15                    #  centred without one, left for text
    lea     rdx, [rip+wg_txt]
    call    value_text
    cmp     dword ptr [rbx+WD_KIND], WK_TEXT
    jne     5f
    lea     edi, [r12+7]
    jmp     7f
5:  lea     rdi, [rip+wg_txt]
    call    text_width
    cmp     qword ptr [rbx+WD_LABEL], 0
    je      6f
    lea     edi, [r12+r14-7]
    sub     edi, eax
    jmp     7f
6:  mov     edi, r14d
    sub     edi, eax
    sar     edi, 1
    add     edi, r12d
7:  mov     esi, r13d
    add     esi, [rsp+28]
    lea     rdx, [rip+wg_txt]
    mov     ecx, COL_TEXT
    call    draw_text
    xor     eax, eax

.Lwg_ret:
    add     rsp, 40
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbp
    pop     rbx
    ret

# edit_draw(edi=x, esi=y of the text row, edx=w) - the text being typed:
#   selection, text, caret
edit_draw:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    mov     ebx, edi
    mov     r12d, esi
    mov     r13d, edx
    lea     rdi, [rip+tfi_widget]
    call    tf_select
    lea     r14d, [rbx+7]               # text origin
    mov     edi, [rip+tf_anchor]        # selection
    mov     esi, [rip+tf_caret]
    cmp     edi, esi
    je      2f
    jb      1f
    xchg    edi, esi
1:  push    rsi
    push    rdi
    call    tf_px
    mov     r15d, eax
    pop     rdi
    pop     rsi
    mov     edi, esi
    call    tf_px
    mov     edx, eax
    sub     edx, r15d
    lea     edi, [r14+r15]
    mov     esi, r12d
    mov     ecx, CHAR_H
    mov     r8d, COL_SELECTION
    call    fill_rect
2:  mov     edi, r14d
    mov     esi, r12d
    lea     rdx, [rip+tf_buf]
    mov     ecx, COL_TEXT
    call    draw_text
    mov     edi, [rip+tf_caret]         # caret
    call    tf_px
    lea     edi, [r14+rax]
    mov     esi, r12d
    mov     edx, 2
    mov     ecx, CHAR_H
    mov     r8d, COL_FOCUS
    call    fill_rect
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# value_text(rdi=desc, rsi=ptr, rdx=dest) - the value as shown
value_text:
    push    rbx
    push    r12
    push    r13
    mov     rbx, rdi
    mov     r12, rsi
    mov     r13, rdx
    mov     eax, [rbx+WD_KIND]
    cmp     eax, WK_TEXT
    je      .Lvt_text
    cmp     eax, WK_INT
    je      .Lvt_int
    movss   xmm0, [r12]
    test    dword ptr [rbx+WD_FLAGS], WGF_DEG
    jz      1f
    mulss   xmm0, [rip+f_r2d]
1:  mov     edi, [rbx+WD_DEC]
    mov     rsi, r13
    call    wg_ftoa
    test    dword ptr [rbx+WD_FLAGS], WGF_DEG
    jz      9f
    lea     rsi, [rip+s_deg]            # the degree sign (" deg" in the
    lea     rcx, [rip+fonts]            #  bitmap font)
    cmp     dword ptr [rcx+FNT_LOADED], 0
    jne     2f
    lea     rsi, [rip+s_deg_bm]
2:  mov     cl, [rsi]
    mov     [rax], cl
    inc     rax
    inc     rsi
    test    cl, cl
    jnz     2b
    jmp     9f
.Lvt_int:
    cvtsi2ss xmm0, dword ptr [r12]
    xor     edi, edi
    mov     rsi, r13
    call    wg_ftoa
    jmp     9f
.Lvt_text:
    test    dword ptr [rbx+WD_FLAGS], WGF_SECRET    # (a secret: stars)
    jz      0f
    mov     byte ptr [r13], 0
    cmp     byte ptr [r12], 0
    je      9f
    mov     rax, 0x2a2a2a2a2a2a2a2a
    mov     [r13], rax
    mov     byte ptr [r13+8], 0
    jmp     9f
0:  xor     ecx, ecx
1:  mov     al, [r12+rcx]
    mov     [r13+rcx], al
    test    al, al
    jz      9f
    inc     ecx
    cmp     ecx, 63
    jb      1b
    mov     byte ptr [r13+rcx], 0
9:  pop     r13
    pop     r12
    pop     rbx
    ret

# wg_ftoa(xmm0=float, edi=decimals 0..6, rsi=dest) -> rax = end (at the 0)
#   rounded, trailing zeros (and a bare point) dropped; "-0" shown as "0"
wg_ftoa:
    push    rbx
    push    r12
    push    r13
    mov     r12, rsi
    cmp     edi, 6
    jbe     1f
    mov     edi, 6
1:  mov     r13d, edi
    cvtss2sd xmm0, xmm0
    lea     rax, [rip+d_pow10]
    mulsd   xmm0, [rax+r13*8]
    xorpd   xmm1, xmm1
    xor     ebx, ebx                    # negative?
    comisd  xmm0, xmm1
    jae     2f
    subsd   xmm1, xmm0
    movsd   xmm0, xmm1
    mov     ebx, 1
2:  addsd   xmm0, [rip+d_half]
    cvttsd2si rax, xmm0                 # |v| x 10^dec, rounded
    test    rax, rax
    jnz     3f
    xor     ebx, ebx
3:  test    ebx, ebx
    jz      4f
    mov     byte ptr [r12], '-'
    inc     r12
4:  sub     rsp, 32                     # digits, least significant first
    xor     ecx, ecx
    mov     r8d, 10
5:  xor     edx, edx
    div     r8
    add     dl, '0'
    mov     [rsp+rcx], dl
    inc     ecx
    test    rax, rax
    jnz     5b
6:  cmp     ecx, r13d                   # at least dec+1 digits
    ja      7f
    mov     byte ptr [rsp+rcx], '0'
    inc     ecx
    jmp     6b
7:  dec     ecx                         # copy out, the point before the
    mov     al, [rsp+rcx]               #  last dec digits
    mov     [r12], al
    inc     r12
    test    ecx, ecx
    jz      8f
    cmp     ecx, r13d
    jne     7b
    mov     byte ptr [r12], '.'
    inc     r12
    jmp     7b
8:  add     rsp, 32
    test    r13d, r13d
    jz      91f
90: cmp     byte ptr [r12-1], '0'       # trim zeros, then a bare point
    jne     92f
    dec     r12
    jmp     90b
92: cmp     byte ptr [r12-1], '.'
    jne     91f
    dec     r12
91: mov     byte ptr [r12], 0
    mov     rax, r12
    pop     r13
    pop     r12
    pop     rbx
    ret

# closed_find(edi=id) -> eax = slot of a closed section, -1 if open
closed_find:
    lea     rcx, [rip+wg_closed]
    xor     eax, eax
1:  cmp     [rcx+rax*4], edi
    je      9f
    inc     eax
    cmp     eax, CLOSED_N
    jb      1b
    mov     eax, -1
9:  ret

closed_toggle:                          # edi = id
    push    rbx
    mov     ebx, edi
    call    closed_find
    test    eax, eax
    js      1f
    lea     rcx, [rip+wg_closed]
    mov     dword ptr [rcx+rax*4], 0    # open it
    jmp     9f
1:  xor     edi, edi                    # close it: take a free slot
    call    closed_find
    test    eax, eax
    js      9f
    lea     rcx, [rip+wg_closed]
    mov     [rcx+rax*4], ebx
9:  pop     rbx
    ret

# -----------------------------------------------------------------------------
# Input
# -----------------------------------------------------------------------------
# wg_hit(edi=x, esi=y) -> eax = widget id under the point (the last drawn
#   wins: it is on top), 0 if none. Scrolled regions themselves only take
#   the wheel, so they are not hits.
wg_hit:
    lea     rax, [rip+wg_list]
    xor     ecx, ecx
    cmp     dword ptr [rip+dlg_open], 0 # a dialog: only its own widgets
    je      71f
    mov     ecx, [rip+dlg_floor]
71: cmp     dword ptr [rip+cpk_on], 0    # the colour picker: only its own
    je      72f
    mov     ecx, [rip+cpk_floor]
72: cmp     dword ptr [rip+ov_on], 0    # a help overlay: only its own
    je      73f
    mov     ecx, [rip+ov_floor]
73: imul    ecx, ecx, WG_SZ
    add     rax, rcx
0:  mov     ecx, [rip+wg_n]
    imul    ecx, ecx, WG_SZ
    lea     rdx, [rip+wg_list]
    add     rcx, rdx                    # one past the end
1:  cmp     rcx, rax
    jbe     8f
    sub     rcx, WG_SZ
    cmp     dword ptr [rcx+E_KIND], WK_SCROLL
    je      1b
    mov     edx, [rcx+E_X]
    cmp     edi, edx
    jl      1b
    add     edx, [rcx+E_W]
    cmp     edi, edx
    jge     1b
    mov     edx, [rcx+E_Y]
    cmp     esi, edx
    jl      1b
    add     edx, [rcx+E_H]
    cmp     esi, edx
    jge     1b
    push    rcx                         # (only where the region shows it)
    push    rdi
    push    rsi
    call    wg_visible
    pop     rsi
    pop     rdi
    pop     rcx
    test    eax, eax
    jz      1b
    mov     eax, [rcx+E_ID]
    ret
8:  xor     eax, eax
    ret

# wg_visible(rcx=entry, edi=x, esi=y) -> eax = 1 unless a scrolled region
#   drawn before it (and containing it) hides the point
wg_visible:
    lea     rax, [rip+wg_list]
1:  cmp     rax, rcx
    jae     8f
    cmp     dword ptr [rax+E_KIND], WK_SCROLL
    jne     2f
    mov     edx, [rax+E_SUB]            # entries [this one, its end) are inside
    cmp     rcx, rax
    jb      2f
    push    rax
    imul    edx, edx, WG_SZ
    lea     r8, [rip+wg_list]
    add     r8, rdx
    pop     rax
    cmp     rcx, r8
    jae     2f
    mov     edx, [rax+E_X]
    cmp     edi, edx
    jl      7f
    add     edx, [rax+E_W]
    cmp     edi, edx
    jge     7f
    mov     edx, [rax+E_Y]
    cmp     esi, edx
    jl      7f
    add     edx, [rax+E_H]
    cmp     esi, edx
    jge     7f
2:  add     rax, WG_SZ
    jmp     1b
7:  xor     eax, eax
    ret
8:  mov     eax, 1
    ret

# wg_cursor(edi=id) -> eax = cursor shape over that widget
wg_cursor:
    cmp     edi, [rip+wg_edit]
    je      2f
    call    wg_find
    test    rax, rax
    jz      1f
    mov     ecx, [rax+E_KIND]
    cmp     ecx, WK_TEXT
    je      2f
    cmp     ecx, WK_FLOAT
    je      3f
    cmp     ecx, WK_INT
    je      3f
    cmp     ecx, WK_SLIDER
    je      3f
1:  mov     eax, CUR_POINTER
    ret
2:  mov     eax, CUR_TEXT
    ret
3:  mov     eax, CUR_EW
    ret

# wg_press(edi=id) - LMB down on a widget; the caller sets DRAG_WIDGET
wg_press:
    push    rbx
    mov     ebx, edi
    cmp     ebx, [rip+wg_edit]          # (typing into it already)
    je      9f
    call    wg_commit                   # a press elsewhere confirms typing
    mov     edi, ebx
    call    wg_find
    test    rax, rax
    jz      9f
    mov     rsi, rax
    lea     rdi, [rip+wg_act_e]
    mov     ecx, WG_SZ
    rep     movsb
    mov     [rip+wg_active], ebx
    mov     dword ptr [rip+wg_scrubbed], 0
    mov     eax, [rip+ptr_x]
    mov     [rip+wg_x0], eax
    mov     eax, [rip+ptr_y]
    mov     [rip+wg_y0], eax
    mov     rax, [rip+wg_act_e+E_PTR]
    test    rax, rax
    jz      1f
    mov     eax, [rax]
    mov     [rip+wg_v0], eax
1:  cmp     dword ptr [rip+wg_act_e+E_KIND], WK_THUMB
    jne     2f
    mov     rax, [rip+wg_act_e+E_PTR]   # thumb: remember the scroll offset
    mov     eax, [rax]
    mov     [rip+wg_v0], eax
2:  cmp     dword ptr [rip+wg_act_e+E_KIND], WK_PAD
    jne     3f
    mov     dword ptr [rip+wg_scrubbed], 1  # a pad: its value at once
    call    act_undo
    mov     edi, [rip+ptr_x]
    mov     esi, [rip+ptr_y]
    call    pad_set
3:  mov     dword ptr [rip+dirty], 1
9:  pop     rbx
    ret

# pad_set(edi=x, esi=y) - the pressed pad's value from the pointer
pad_set:
    mov     rdx, [rip+wg_act_e+E_PTR]
    test    rdx, rdx
    jz      9f
    sub     edi, [rip+wg_act_e+E_X]
    cvtsi2ss xmm0, edi
    cvtsi2ss xmm1, dword ptr [rip+wg_act_e+E_W]
    divss   xmm0, xmm1
    sub     esi, [rip+wg_act_e+E_Y]
    cvtsi2ss xmm2, esi
    cvtsi2ss xmm1, dword ptr [rip+wg_act_e+E_H]
    divss   xmm2, xmm1
    xorps   xmm1, xmm1
    maxss   xmm0, xmm1
    maxss   xmm2, xmm1
    minss   xmm0, [rip+f_1]
    minss   xmm2, [rip+f_1]
    movss   [rdx], xmm0
    movss   [rdx+4], xmm2
    jmp     act_changed
9:  ret

# wg_drag(edi=x, esi=y) - pointer motion while a widget is pressed
wg_drag:
    push    rbx
    push    r12
    sub     rsp, 8
    mov     ebx, edi
    mov     r12d, esi
    mov     eax, [rip+wg_act_e+E_KIND]
    cmp     eax, WK_THUMB
    je      .Lwd_thumb
    cmp     eax, WK_PAD
    jne     0f
    call    pad_set
    jmp     9f
0:  cmp     eax, WK_FLOAT
    je      1f
    cmp     eax, WK_INT
    je      1f
    cmp     eax, WK_SLIDER
    jne     9f
1:  mov     eax, ebx
    sub     eax, [rip+wg_x0]
    cmp     dword ptr [rip+wg_scrubbed], 0
    jne     2f
    mov     ecx, eax                    # a 3 px dead zone: a click types
    neg     ecx
    cmovl   ecx, eax
    cmp     ecx, 3
    jl      9f
    mov     dword ptr [rip+wg_scrubbed], 1
    call    act_undo
2:  mov     rcx, [rip+wg_act_e+E_DESC]
    mov     rdx, [rip+wg_act_e+E_PTR]
    cmp     dword ptr [rip+wg_act_e+E_KIND], WK_SLIDER
    je      .Lwd_slider
    mov     eax, ebx
    sub     eax, [rip+wg_x0]
    cvtsi2ss xmm0, eax                  # dx x step (x 0.1 with Shift)
    mulss   xmm0, [rcx+WD_STEP]
    test    dword ptr [rip+key_mods], MOD_SHIFT
    jz      3f
    mulss   xmm0, [rip+f_tenth]
3:  cmp     dword ptr [rip+wg_act_e+E_KIND], WK_INT
    je      .Lwd_int
    addss   xmm0, [rip+wg_v0]
    test    dword ptr [rip+key_mods], MOD_CTRL
    jz      4f
    movss   xmm1, [rcx+WD_STEP]         # Ctrl: snap to 10 steps
    mulss   xmm1, [rip+f_ten]
    divss   xmm0, xmm1
    roundss xmm0, xmm0, 0
    mulss   xmm0, xmm1
4:  call    clamp_desc
    movss   [rdx], xmm0
    jmp     8f
.Lwd_int:
    cvtsi2ss xmm1, dword ptr [rip+wg_v0]
    addss   xmm0, xmm1
    call    clamp_desc
    cvtss2si eax, xmm0
    mov     [rdx], eax
    jmp     8f
.Lwd_slider:
    mov     eax, ebx                    # the bar follows the pointer
    sub     eax, [rip+wg_act_e+E_X]
    cvtsi2ss xmm0, eax
    cvtsi2ss xmm1, dword ptr [rip+wg_act_e+E_W]
    divss   xmm0, xmm1
    movss   xmm1, [rcx+WD_MAX]
    subss   xmm1, [rcx+WD_MIN]
    mulss   xmm0, xmm1
    addss   xmm0, [rcx+WD_MIN]
    maxss   xmm0, [rcx+WD_MIN]
    minss   xmm0, [rcx+WD_MAX]
    movss   [rdx], xmm0
8:  call    act_changed
    jmp     9f
.Lwd_thumb:
    mov     eax, r12d                   # offset = v0 + dy x content / track
    sub     eax, [rip+wg_y0]
    cvtsi2ss xmm0, eax
    cvtsi2ss xmm1, dword ptr [rip+wg_act_e+E_AUX]     # content height
    mulss   xmm0, xmm1
    cvtsi2ss xmm1, dword ptr [rip+wg_act_e+E_AUX+4]   # track height
    divss   xmm0, xmm1
    cvtss2si eax, xmm0
    add     eax, [rip+wg_v0]
    mov     rdx, [rip+wg_act_e+E_PTR]
    mov     [rdx], eax                  # (clamped by wg_scroll_end)
    mov     dword ptr [rip+dirty], 1
9:  add     rsp, 8
    pop     r12
    pop     rbx
    ret

# clamp_desc(rcx=desc, xmm0) - keep a value in [min, max] when it has one
clamp_desc:
    movss   xmm1, [rcx+WD_MAX]
    comiss  xmm1, [rcx+WD_MIN]
    jbe     1f
    test    dword ptr [rcx+WD_FLAGS], WGF_CLAMP
    jz      1f
    maxss   xmm0, [rcx+WD_MIN]
    minss   xmm0, [rcx+WD_MAX]
1:  ret

# act_undo - the pressed widget's undo step (when its descriptor has one)
act_undo:
    mov     rax, [rip+wg_act_e+E_DESC]
    mov     rdi, [rax+WD_UNDO]
    test    rdi, rdi
    jz      1f
    jmp     undo_push
1:  ret

# act_changed - the pressed widget's value changed: its callback, a redraw
act_changed:
    mov     dword ptr [rip+dirty], 1
    mov     rax, [rip+wg_act_e+E_DESC]
    mov     rax, [rax+WD_CB]
    test    rax, rax
    jz      1f
    mov     rdi, [rip+wg_act_e+E_PTR]
    mov     esi, [rip+wg_act_e+E_SUB]
    jmp     rax
1:  ret

# ---- keyboard focus (a11y.s moves it) ------------------------------------------------
# wg_activate - Enter / Space on the focused widget: as a click on it
.globl wg_activate
.globl wg_kfocus
wg_activate:
    push    rbx
    sub     rsp, 16
    mov     ebx, [rip+wg_kfocus]
    test    ebx, ebx
    jz      9f
    mov     edi, ebx
    call    wg_find
    test    rax, rax
    jz      9f
    mov     rsi, rax
    lea     rdi, [rip+wg_act_e]
    mov     ecx, WG_SZ
    rep     movsb
    mov     dword ptr [rip+wg_active], 0
    mov     dword ptr [rip+dirty], 1
    jmp     .Lwr_dispatch
9:  add     rsp, 16
    pop     rbx
    ret

# wg_nudge(edi=+1 / -1) - arrows on the focused widget: a number a step
#   (x 10; a whole number: one), an option the next / previous one
.globl wg_nudge
wg_nudge:
    push    rbx
    push    r12
    sub     rsp, 8
    mov     r12d, edi
    mov     edi, [rip+wg_kfocus]
    test    edi, edi
    jz      9f
    call    wg_find
    test    rax, rax
    jz      9f
    mov     rsi, rax
    lea     rdi, [rip+wg_act_e]
    mov     ecx, WG_SZ
    rep     movsb
    mov     rbx, [rip+wg_act_e+E_DESC]
    mov     rdx, [rip+wg_act_e+E_PTR]
    test    rdx, rdx
    jz      9f
    mov     eax, [rbx+WD_KIND]
    cmp     eax, WK_ENUM
    je      .Lwn_enum
    cmp     eax, WK_INT
    je      .Lwn_int
    cmp     eax, WK_FLOAT
    je      .Lwn_float
    cmp     eax, WK_SLIDER
    jne     9f
.Lwn_float:
    call    act_undo
    mov     rdx, [rip+wg_act_e+E_PTR]
    cvtsi2ss xmm0, r12d
    mulss   xmm0, [rbx+WD_STEP]
    mulss   xmm0, [rip+f_ten]
    addss   xmm0, [rdx]
    mov     rcx, rbx
    call    clamp_desc
    cmp     dword ptr [rbx+WD_KIND], WK_SLIDER
    jne     1f
    maxss   xmm0, [rbx+WD_MIN]
    minss   xmm0, [rbx+WD_MAX]
1:  mov     rdx, [rip+wg_act_e+E_PTR]
    movss   [rdx], xmm0
    call    act_changed
    jmp     9f
.Lwn_int:
    call    act_undo
    mov     rdx, [rip+wg_act_e+E_PTR]
    mov     eax, [rdx]
    add     eax, r12d
    cvtsi2ss xmm0, eax
    mov     rcx, rbx
    call    clamp_desc
    cvtss2si eax, xmm0
    mov     rdx, [rip+wg_act_e+E_PTR]
    mov     [rdx], eax
    call    act_changed
    jmp     9f
.Lwn_enum:
    mov     rdi, rbx
    call    enum_list
    mov     ecx, edx                    # (how many)
    mov     rdx, [rip+wg_act_e+E_PTR]
    mov     eax, [rdx]
    add     eax, r12d
    js      9f
    cmp     eax, ecx
    jae     9f
    push    rax
    push    rax
    call    act_undo
    pop     rax
    pop     rax
    mov     rdx, [rip+wg_act_e+E_PTR]
    mov     [rdx], eax
    call    act_changed
9:  add     rsp, 8
    pop     r12
    pop     rbx
    ret

# wg_focus_step(edi=+1 / -1, rsi=area rect (x y w h) or 0: any) -> eax = 1
#   when a widget took the focus: the next one that can (of a dialog or an
#   overlay when one is open, else inside that rect)
.globl wg_focus_step
wg_focus_step:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    mov     r12d, edi
    mov     r13, rsi
    xor     r14d, r14d                  # the first entry in scope (a floor)
    cmp     dword ptr [rip+dlg_open], 0
    je      1f
    mov     r14d, [rip+dlg_floor]
1:  cmp     dword ptr [rip+cpk_on], 0
    je      2f
    mov     r14d, [rip+cpk_floor]
2:  cmp     dword ptr [rip+ov_on], 0
    je      3f
    mov     r14d, [rip+ov_floor]
3:  test    r14d, r14d                  # (a floor: no rect)
    jz      4f
    xor     r13d, r13d
4:  mov     r15d, [rip+wg_n]            # where the focus is now (-1: none)
    mov     ebx, -1
    mov     ecx, r14d
5:  cmp     ecx, r15d
    jae     6f
    imul    eax, ecx, WG_SZ
    lea     rdx, [rip+wg_list]
    mov     eax, [rdx+rax+E_ID]
    cmp     eax, [rip+wg_kfocus]
    jne     51f
    mov     ebx, ecx
    jmp     6f
51: inc     ecx
    jmp     5b
6:  mov     ecx, r15d                   # at most a lap
    sub     ecx, r14d
    jle     8f
    mov     [rsp-8], ecx
7:  test    ebx, ebx                    # the next one
    jns     71f
    mov     ebx, r14d                   # (none yet: the first / the last)
    test    r12d, r12d
    jns     72f
    lea     ebx, [r15-1]
    jmp     72f
71: add     ebx, r12d
    cmp     ebx, r14d
    jge     711f
    lea     ebx, [r15-1]
711:cmp     ebx, r15d
    jl      72f
    mov     ebx, r14d
72: imul    eax, ebx, WG_SZ
    lea     rdx, [rip+wg_list]
    add     rdx, rax
    mov     eax, [rdx+E_KIND]           # can it take the focus?
    cmp     eax, WK_SCROLL
    je      79f
    cmp     eax, WK_THUMB
    je      79f
    cmp     eax, WK_PAD
    je      79f
    test    r13, r13                    # inside the rect?
    jz      78f
    mov     eax, [rdx+E_X]
    cmp     eax, [r13]
    jl      79f
    mov     ecx, [r13]
    add     ecx, [r13+8]
    cmp     eax, ecx
    jge     79f
    mov     eax, [rdx+E_Y]
    cmp     eax, [r13+4]
    jl      79f
    mov     ecx, [r13+4]
    add     ecx, [r13+12]
    cmp     eax, ecx
    jge     79f
78: mov     eax, [rdx+E_ID]
    mov     [rip+wg_kfocus], eax
    mov     dword ptr [rip+dirty], 1
    mov     eax, 1
    jmp     9f
79: dec     dword ptr [rsp-8]
    jnz     7b
8:  xor     eax, eax
9:  pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# wg_release - LMB up: a press without a scrub is a click
wg_release:
    push    rbx
    sub     rsp, 16
    mov     ebx, [rip+wg_active]
    test    ebx, ebx
    jz      9f
    mov     dword ptr [rip+wg_active], 0
    mov     dword ptr [rip+dirty], 1
    cmp     dword ptr [rip+wg_scrubbed], 0
    jne     9f
    mov     edi, [rip+ptr_x]            # released elsewhere: nothing
    mov     esi, [rip+ptr_y]
    call    wg_hit
    cmp     eax, ebx
    jne     9f
.Lwr_dispatch:                          # (wg_activate comes in here too)
    mov     rcx, [rip+wg_act_e+E_DESC]
    mov     eax, [rip+wg_act_e+E_KIND]
    cmp     eax, WK_BUTTON
    je      .Lwr_button
    cmp     eax, WK_TOGGLE
    je      .Lwr_toggle
    cmp     eax, WK_SECTION
    je      .Lwr_section
    cmp     eax, WK_ENUM
    je      .Lwr_enum
    cmp     eax, WK_TABS
    je      .Lwr_tabs
    cmp     eax, WK_ROW
    je      .Lwr_row
    cmp     eax, WK_THUMB
    je      9f
    cmp     eax, WK_PAD
    je      9f
    cmp     eax, WK_COLOR
    jne     1f
    lea     rdi, [rip+wg_act_e]         # a colour: the picker
    call    cpk_open
    jmp     9f
1:  lea     rdi, [rip+wg_act_e]         # a field: type into it
    call    edit_begin
    jmp     9f
.Lwr_button:
    mov     rdi, [rcx+WD_AUX]
    test    rdi, rdi
    jz      1f
    call    run_op_ui                   # (greyed, a form or a question first)
    jmp     9f
1:  mov     [rip+wg_clicked], ebx
    jmp     9f
.Lwr_toggle:
    call    act_undo
    mov     rax, [rip+wg_act_e+E_PTR]
    xor     dword ptr [rax], 1
    call    act_changed
    jmp     9f
.Lwr_section:
    mov     edi, ebx
    call    closed_toggle
    jmp     9f
.Lwr_enum:
    lea     rsi, [rip+wg_act_e]         # open its list under it
    lea     rdi, [rip+wg_pop_e]
    mov     ecx, WG_SZ
    rep     movsb
    mov     eax, [rip+wg_pop_e+E_X]
    mov     [rip+wg_pop_x], eax
    mov     eax, [rip+wg_pop_e+E_Y]
    add     eax, [rip+wg_pop_e+E_H]
    add     eax, 2
    mov     [rip+wg_pop_y], eax
    mov     eax, [rip+wg_pop_e+E_W]
    cmp     eax, 120
    jge     2f
    mov     eax, 120
2:  mov     [rip+wg_pop_w], eax
    call    pop_h                       # (above the field when it would not fit)
    mov     ecx, [rip+wg_pop_y]
    add     ecx, eax
    cmp     ecx, [rip+win_h]
    jle     3f
    mov     ecx, [rip+wg_pop_e+E_Y]
    sub     ecx, eax
    sub     ecx, 2
    jns     21f
    xor     ecx, ecx
21: mov     [rip+wg_pop_y], ecx
3:  mov     dword ptr [rip+wg_pop_hot], -1
    mov     dword ptr [rip+wg_pop_open], 1
    jmp     9f
.Lwr_row:                               # a row: select it, its callback
    mov     rdx, [rip+wg_act_e+E_PTR]
    mov     eax, [rip+wg_act_e+E_SUB]
    mov     [rdx], eax
    call    act_changed
    jmp     9f
.Lwr_tabs:
    mov     eax, [rip+ptr_x]            # which tab
    sub     eax, [rip+wg_act_e+E_X]
    imul    eax, [rcx+WD_N]
    cdq
    idiv    dword ptr [rip+wg_act_e+E_W]
    cmp     eax, [rcx+WD_N]
    jae     9f
    mov     rdx, [rip+wg_act_e+E_PTR]
    cmp     eax, [rdx]
    je      9f
    mov     [rdx], eax
    call    act_changed
9:  add     rsp, 16
    pop     rbx
    ret

# wg_wheel(edi=id under the pointer or 0, esi=x, edx=y, ecx=notches up > 0)
#   -> eax = 1 if used: Ctrl+wheel steps the widget, the wheel scrolls the
#   innermost scrolled region under the pointer
wg_wheel:
    push    rbx
    push    r12
    push    r13
    push    r14
    sub     rsp, 8
    mov     r12d, esi
    mov     r13d, edx
    mov     r14d, ecx
    test    dword ptr [rip+key_mods], MOD_CTRL
    jz      .Lww_scroll
    test    edi, edi
    jz      .Lww_scroll
    call    wg_find
    test    rax, rax
    jz      .Lww_scroll
    mov     rsi, rax
    lea     rdi, [rip+wg_act_e]
    mov     ecx, WG_SZ
    rep     movsb
    mov     rcx, [rip+wg_act_e+E_DESC]
    mov     rdx, [rip+wg_act_e+E_PTR]
    mov     eax, [rip+wg_act_e+E_KIND]
    cmp     eax, WK_ENUM
    je      .Lww_enum
    cmp     eax, WK_INT
    je      .Lww_int
    cmp     eax, WK_FLOAT
    je      1f
    cmp     eax, WK_SLIDER
    jne     .Lww_scroll
1:  push    rcx
    push    rdx
    call    act_undo
    pop     rdx
    pop     rcx
    cvtsi2ss xmm0, r14d                 # 10 steps a notch
    mulss   xmm0, [rcx+WD_STEP]
    mulss   xmm0, [rip+f_ten]
    addss   xmm0, [rdx]
    call    clamp_desc
    cmp     dword ptr [rip+wg_act_e+E_KIND], WK_SLIDER
    jne     2f
    maxss   xmm0, [rcx+WD_MIN]
    minss   xmm0, [rcx+WD_MAX]
2:  movss   [rdx], xmm0
    jmp     .Lww_changed
.Lww_int:
    push    rcx
    push    rdx
    call    act_undo
    pop     rdx
    pop     rcx
    add     [rdx], r14d
    cvtsi2ss xmm0, dword ptr [rdx]
    call    clamp_desc
    cvtss2si eax, xmm0
    mov     [rdx], eax
    jmp     .Lww_changed
.Lww_enum:
    mov     eax, [rdx]                  # up = previous option
    sub     eax, r14d
    js      .Lww_used
    cmp     eax, [rcx+WD_N]
    jae     .Lww_used
    mov     [rdx], eax
.Lww_changed:
    call    act_changed
.Lww_used:
    mov     eax, 1
    jmp     .Lww_ret
.Lww_scroll:                            # the last region drawn under the pointer
    lea     rbx, [rip+wg_list]
    mov     eax, [rip+wg_n]
    imul    eax, eax, WG_SZ
    lea     rcx, [rbx+rax]
1:  cmp     rcx, rbx
    jbe     8f
    sub     rcx, WG_SZ
    cmp     dword ptr [rcx+E_KIND], WK_SCROLL
    jne     1b
    mov     eax, [rcx+E_X]
    cmp     r12d, eax
    jl      1b
    add     eax, [rcx+E_W]
    cmp     r12d, eax
    jge     1b
    mov     eax, [rcx+E_Y]
    cmp     r13d, eax
    jl      1b
    add     eax, [rcx+E_H]
    cmp     r13d, eax
    jge     1b
    mov     rdx, [rcx+E_PTR]            # 3 rows a notch (clamped when drawn)
    imul    eax, r14d, -3*WG_H
    add     [rdx], eax
    mov     dword ptr [rip+dirty], 1
    jmp     .Lww_used
8:  xor     eax, eax
.Lww_ret:
    add     rsp, 8
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# -----------------------------------------------------------------------------
# Typing into a field
# -----------------------------------------------------------------------------
# edit_begin(rdi=entry) - its value as text, all selected
edit_begin:
    push    rbx
    mov     rbx, rdi
    mov     rsi, rbx
    lea     rdi, [rip+wg_edit_e]
    mov     ecx, WG_SZ
    rep     movsb
    mov     eax, [rbx+E_ID]
    mov     [rip+wg_edit], eax
    lea     rdi, [rip+tfi_widget]
    call    tf_select
    mov     rdi, [rbx+E_DESC]
    mov     rsi, [rbx+E_PTR]
    lea     rdx, [rip+wg_txt]
    cmp     dword ptr [rdi+WD_KIND], WK_TEXT
    je      1f
    cmp     dword ptr [rdi+WD_KIND], WK_INT
    je      1f
    movss   xmm0, [rsi]                 # numbers: all the precision there is
    test    dword ptr [rdi+WD_FLAGS], WGF_DEG
    jz      2f
    mulss   xmm0, [rip+f_r2d]
2:  mov     edi, 6
    mov     rsi, rdx
    call    wg_ftoa
    jmp     3f
1:  call    value_text
    mov     rdi, [rbx+E_DESC]           # (a secret: typed afresh)
    test    dword ptr [rdi+WD_FLAGS], WGF_SECRET
    jz      3f
    mov     byte ptr [rip+wg_txt], 0
3:  lea     rsi, [rip+wg_txt]
    call    tf_load
    mov     dword ptr [rip+tf_anchor], 0
    mov     dword ptr [rip+dirty], 1
    pop     rbx
    ret

# wg_clip_key(edi=evdev) -> eax = 1 if used: Ctrl+C over a field copies
#   its value, Ctrl+V pastes into it (as if typed: units, expressions, undo)
wg_clip_key:
    push    rbx
    push    r12
    sub     rsp, 264
    mov     ebx, edi
    xor     r12d, r12d
    cmp     dword ptr [rip+hover_id], HIT_WIDGET
    jne     9f
    mov     eax, [rip+key_mods]
    and     eax, MOD_CTRL|MOD_ALT|MOD_SHIFT
    cmp     eax, MOD_CTRL
    jne     9f
    mov     edi, [rip+hover_idx]
    call    wg_find
    test    rax, rax
    jz      9f
    mov     ecx, [rax+E_KIND]           # (values only)
    cmp     ecx, WK_FLOAT
    je      1f
    cmp     ecx, WK_INT
    je      1f
    cmp     ecx, WK_SLIDER
    je      1f
    cmp     ecx, WK_TEXT
    jne     9f
1:  mov     [rsp], rax
    mov     edi, ebx
    call    kb_layout_code
    cmp     eax, 46                     # C
    je      2f
    cmp     eax, 47                     # V
    jne     9f
    mov     rdi, [rsp]
    call    wg_val_paste
    jmp     8f
2:  mov     rdi, [rsp]
    call    wg_val_copy
8:  mov     r12d, 1
9:  mov     eax, r12d
    add     rsp, 264
    pop     r12
    pop     rbx
    ret

# wg_val_paste(rdi=widget entry) - the clipboard typed into it and confirmed
#   (units, expressions, one undo step)
.globl wg_val_paste
wg_val_paste:
    push    rbx
    sub     rsp, 256
    mov     rbx, rdi
    mov     rdi, rsp
    mov     esi, 250
    call    clip_paste
    test    eax, eax
    jz      9f
    mov     rdi, rbx
    call    edit_begin
    mov     rsi, rsp
    call    tf_load
    call    wg_commit
9:  add     rsp, 256
    pop     rbx
    ret

# wg_val_copy(rdi=widget entry) - its value, as shown when typing, to the
#   clipboard
.globl wg_val_copy
wg_val_copy:
    sub     rsp, 8
    mov     rax, rdi
    mov     rdi, [rax+E_DESC]
    mov     rsi, [rax+E_PTR]
    lea     rdx, [rip+wg_txt]
    cmp     dword ptr [rdi+WD_KIND], WK_TEXT
    je      3f
    cmp     dword ptr [rdi+WD_KIND], WK_INT
    je      3f
    movss   xmm0, [rsi]
    test    dword ptr [rdi+WD_FLAGS], WGF_DEG
    jz      4f
    mulss   xmm0, [rip+f_r2d]
4:  mov     edi, 6
    mov     rsi, rdx
    call    wg_ftoa
    jmp     5f
3:  call    value_text
5:  lea     rdi, [rip+wg_txt]
    call    str_len
    mov     esi, eax
    lea     rdi, [rip+wg_txt]
    call    clip_copy
    add     rsp, 8
    ret

# wg_val_reset(rdi=widget entry) -> eax = 1 when the field had a default
#   (WD_DEF) and got it back, as if typed (its callback, one undo step)
.globl wg_val_reset
wg_val_reset:
    push    rbx
    sub     rsp, 80                     # (the text: edit_begin uses wg_txt)
    mov     rbx, rdi
    call    wg_has_def
    test    eax, eax
    jz      9f
    mov     rdi, [rbx+E_DESC]
    movss   xmm0, [rdi+WD_DEF]
    cmp     dword ptr [rdi+WD_KIND], WK_INT
    jne     1f
    cvtss2si eax, xmm0                  # an integer: its digits
    mov     [rsp+64], eax
    lea     rsi, [rsp+64]
    mov     rdx, rsp
    call    value_text
    jmp     2f
1:  test    dword ptr [rdi+WD_FLAGS], WGF_DEG
    jz      11f
    mulss   xmm0, [rip+f_r2d]
11: mov     edi, 6
    mov     rsi, rsp
    call    wg_ftoa
2:  mov     rdi, rbx
    call    edit_begin
    mov     rsi, rsp
    call    tf_load
    call    wg_commit
    mov     eax, 1
9:  add     rsp, 80
    pop     rbx
    ret

# wg_has_def(rdi=widget entry) -> eax = 1 for a number field with a default
.globl wg_has_def
wg_has_def:
    xor     eax, eax
    mov     rdi, [rdi+E_DESC]
    mov     ecx, [rdi+WD_KIND]
    cmp     ecx, WK_FLOAT
    je      1f
    cmp     ecx, WK_INT
    je      1f
    cmp     ecx, WK_SLIDER
    jne     9f
1:  movss   xmm0, [rdi+WD_DEF]
    ucomiss xmm0, xmm0                  # (NaN: none)
    setnp   al
9:  ret

# wg_editing -> eax = 1 while a field takes the keys
wg_editing:
    xor     eax, eax
    cmp     dword ptr [rip+wg_edit], 0
    setne   al
    ret

# wg_key(edi=evdev code) -> eax = 1 if used (always, while typing)
wg_key:
    push    rbx
    mov     ebx, edi
    lea     rdi, [rip+tfi_widget]
    call    tf_select
    mov     edi, ebx
    call    kb_sym
    mov     esi, eax
    mov     edi, ebx
    call    tf_key
    cmp     eax, 2
    je      .Lwk_enter
    cmp     eax, 3
    je      .Lwk_esc
    cmp     eax, 4
    je      .Lwk_tab
    mov     dword ptr [rip+dirty], 1
    jmp     9f
.Lwk_esc:
    mov     dword ptr [rip+wg_edit], 0
    mov     dword ptr [rip+dirty], 1
    jmp     9f
.Lwk_enter:                             # (callbacks can tell Enter apart)
    mov     dword ptr [rip+wg_by_enter], 1
    call    wg_commit
    mov     dword ptr [rip+wg_by_enter], 0
    jmp     9f
.Lwk_tab:                               # confirm, then the next field
    mov     edi, [rip+wg_edit]          # (the file browser's path: completes)
    call    wg_find
    test    rax, rax
    jz      1f
    lea     rcx, [rip+wd_fb_path]
    cmp     [rax+E_DESC], rcx
    jne     1f
    call    fb_complete
    jmp     9f
1:  mov     ebx, [rip+wg_edit]
    call    wg_commit
    mov     edi, ebx
    call    wg_find
    test    rax, rax
    jz      9f
    mov     rcx, rax
    lea     rdx, [rip+wg_list]
    mov     eax, [rip+wg_n]
    imul    eax, eax, WG_SZ
    lea     r8, [rdx+rax]               # end
    mov     r9, WG_SZ
    test    dword ptr [rip+key_mods], MOD_SHIFT
    jz      1f
    neg     r9
1:  add     rcx, r9
    cmp     rcx, rdx
    jb      9f
    cmp     rcx, r8
    jae     9f
    mov     eax, [rcx+E_KIND]
    cmp     eax, WK_FLOAT
    je      2f
    cmp     eax, WK_INT
    je      2f
    cmp     eax, WK_SLIDER
    je      2f
    cmp     eax, WK_TEXT
    jne     1b
2:  mov     rdi, rcx
    call    edit_begin
9:  mov     eax, 1
    pop     rbx
    ret

# wg_commit - confirm what was typed (nothing when no field is being typed in)
wg_commit:
    push    rbx
    push    r12
    sub     rsp, 8
    cmp     dword ptr [rip+wg_edit], 0
    je      9f
    mov     dword ptr [rip+wg_edit], 0
    mov     dword ptr [rip+dirty], 1
    lea     rdi, [rip+tfi_widget]
    call    tf_select
    lea     rsi, [rip+wg_edit_e]        # it acts as the pressed widget
    lea     rdi, [rip+wg_act_e]
    mov     ecx, WG_SZ
    rep     movsb
    mov     rbx, [rip+wg_act_e+E_DESC]
    mov     r12, [rip+wg_act_e+E_PTR]
    cmp     dword ptr [rbx+WD_KIND], WK_TEXT
    je      .Lwc_text
    lea     rdi, [rip+tf_buf]
    call    expr_eval
    test    eax, eax
    jz      .Lwc_bad
    test    dword ptr [rbx+WD_FLAGS], WGF_DEG
    jz      2f
    lea     rdi, [rip+tf_buf]           # a plain number in a degree field is
    call    has_letter                  #  degrees; "1.2rad" / "90deg" are not
    test    eax, eax
    jnz     2f
    mulsd   xmm0, [rip+d_d2r]
2:  cvtsd2ss xmm0, xmm0
    movss   [rsp], xmm0
    call    act_undo
    movss   xmm0, [rsp]
    mov     rcx, rbx
    call    clamp_desc
    cmp     dword ptr [rbx+WD_KIND], WK_INT
    je      3f
    cmp     dword ptr [rbx+WD_KIND], WK_SLIDER
    jne     4f
    maxss   xmm0, [rbx+WD_MIN]
    minss   xmm0, [rbx+WD_MAX]
4:  movss   [r12], xmm0
    jmp     8f
3:  cvtss2si eax, xmm0
    mov     [r12], eax
8:  call    act_changed
    jmp     9f
.Lwc_text:
    call    act_undo
    mov     rax, [rbx+WD_CB]            # a callback takes the new text
    test    rax, rax
    jz      1f
    lea     rdi, [rip+tf_buf]
    mov     esi, [rip+wg_act_e+E_SUB]
    call    rax
    mov     dword ptr [rip+dirty], 1
    jmp     9f
1:  xor     ecx, ecx                    # or it is copied (63 bytes at most)
    lea     rsi, [rip+tf_buf]
5:  mov     al, [rsi+rcx]
    mov     [r12+rcx], al
    test    al, al
    jz      9f
    inc     ecx
    cmp     ecx, 63
    jb      5b
    mov     byte ptr [r12+rcx], 0
    jmp     9f
.Lwc_bad:
    lea     rdi, [rip+s_bad_value]
    lea     rsi, [rip+tf_buf]
    call    log_pair
9:  add     rsp, 8
    pop     r12
    pop     rbx
    ret

# has_letter(rdi=text) -> eax = 1 if it contains a letter (a unit)
has_letter:
1:  movzx   eax, byte ptr [rdi]
    test    eax, eax
    jz      9f
    inc     rdi
    or      eax, 0x20
    cmp     eax, 'a'
    jb      1b
    cmp     eax, 'z'
    ja      1b
    mov     eax, 1
    ret
9:  xor     eax, eax
    ret

# -----------------------------------------------------------------------------
# The option list of an enum (drawn on top of everything, like a menu)
# -----------------------------------------------------------------------------
pop_h:                                  # -> eax = height of the open list
    mov     rdi, [rip+wg_pop_e+E_DESC]
    sub     rsp, 8
    call    enum_list
    add     rsp, 8
    imul    eax, edx, POP_ROW
    add     eax, 8
    ret

# enum_list(rdi=desc) -> rax = its labels, edx = how many (rdi kept)
.globl enum_list
enum_list:
    test    dword ptr [rdi+WD_FLAGS], WGF_DYN
    jnz     1f
    mov     rax, [rdi+WD_AUX]
    mov     edx, [rdi+WD_N]
    ret
1:  push    rdi
    call    [rdi+WD_AUX]
    pop     rdi
    ret

wg_pop_draw:
    cmp     dword ptr [rip+wg_pop_open], 0
    je      9f
    push    rbx
    push    r12
    push    r13
    call    pop_h
    mov     ecx, eax
    mov     edi, [rip+wg_pop_x]
    mov     esi, [rip+wg_pop_y]
    mov     edx, [rip+wg_pop_w]
    mov     r8d, COL_DROP_BORDER
    call    popup_frame
    xor     ebx, ebx
    mov     r12d, [rip+wg_pop_y]
    add     r12d, 4
1:  mov     rdi, [rip+wg_pop_e+E_DESC]
    call    enum_list
    cmp     ebx, edx
    jae     8f
    cmp     ebx, [rip+wg_pop_hot]
    jne     2f
    mov     edi, [rip+wg_pop_x]
    add     edi, 3
    mov     esi, r12d
    mov     edx, [rip+wg_pop_w]
    sub     edx, 6
    mov     ecx, POP_ROW
    mov     r8d, COL_HOVER
    mov     r9d, FIELD_R
    call    fill_rrect
2:  mov     rax, [rip+wg_pop_e+E_PTR]   # the current option: an accent bar
    cmp     ebx, [rax]
    jne     3f
    mov     edi, [rip+wg_pop_x]
    add     edi, 4
    lea     esi, [r12+5]
    mov     edx, 3
    mov     ecx, POP_ROW-10
    mov     r8d, COL_ACCENT
    call    fill_rect
3:  mov     edi, [rip+wg_pop_x]
    add     edi, 14
    lea     esi, [r12+3]
    mov     rdi, [rip+wg_pop_e+E_DESC]
    call    enum_list
    mov     rdx, [rax+rbx*8]
    mov     edi, [rip+wg_pop_x]
    add     edi, 14
    lea     esi, [r12+3]
    mov     ecx, COL_TEXT
    call    draw_text
    add     r12d, POP_ROW
    inc     ebx
    jmp     1b
8:  pop     r13
    pop     r12
    pop     rbx
9:  ret

# wg_pop_hit(edi=x, esi=y) -> eax = row, -1 inside the list but no row,
#   -2 outside it (only meaningful while wg_pop_open)
wg_pop_hit:
    mov     eax, edi
    sub     eax, [rip+wg_pop_x]
    js      8f
    cmp     eax, [rip+wg_pop_w]
    jge     8f
    push    rsi
    call    pop_h
    pop     rsi
    mov     ecx, eax
    mov     eax, esi
    sub     eax, [rip+wg_pop_y]
    js      8f
    cmp     eax, ecx
    jge     8f
    sub     eax, 4
    js      7f
    xor     edx, edx
    mov     ecx, POP_ROW
    div     ecx
    push    rax
    mov     rdi, [rip+wg_pop_e+E_DESC]
    call    enum_list
    pop     rax
    cmp     eax, edx
    jae     7f
    mov     [rip+wg_pop_hot], eax
    ret
7:  mov     dword ptr [rip+wg_pop_hot], -1
    mov     eax, -1
    ret
8:  mov     dword ptr [rip+wg_pop_hot], -1
    mov     eax, -2
    ret

# wg_pop_press(edi=row or -1 / -2) - a press while the list is open: a row
#   picks that option; anywhere else closes the list
wg_pop_press:
    mov     dword ptr [rip+wg_pop_open], 0
    mov     dword ptr [rip+dirty], 1
    test    edi, edi
    js      9f
    mov     rdx, [rip+wg_pop_e+E_PTR]
    cmp     edi, [rdx]
    je      9f
    push    rdi
    lea     rsi, [rip+wg_pop_e]
    lea     rdi, [rip+wg_act_e]
    mov     ecx, WG_SZ
    rep     movsb
    call    act_undo
    pop     rdi
    mov     rdx, [rip+wg_act_e+E_PTR]
    mov     [rdx], edi
    jmp     act_changed
9:  ret

# -----------------------------------------------------------------------------
# Scrolled regions
#   y0 = wg_scroll_begin(desc, x, y, w, h, &offset)  ... widgets at y0 + ...
#   wg_scroll_end(bottom y of the content)
# -----------------------------------------------------------------------------
# wg_scroll_begin(rdi=desc, esi=x, edx=y, ecx=w, r8d=h, r9=ptr to offset)
#   -> eax = y of the content's top (y - offset)
wg_scroll_begin:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    mov     rbx, rdi
    mov     r12d, esi
    mov     r13d, edx
    mov     r14d, ecx
    mov     r15, r9
    push    r8
    mov     esi, 0
    call    wg_id
    pop     r8
    mov     rdi, rbx                    # the region (for the wheel)
    mov     esi, r12d
    mov     edx, r13d
    mov     ecx, r14d
    mov     r9, r15
    xor     r10d, r10d
    push    r8
    call    wg_add
    pop     r8
    mov     ecx, [rip+wg_sc_depth]      # remember it and the clip
    cmp     ecx, SCROLL_N
    jae     8f
    inc     dword ptr [rip+wg_sc_depth]
    shl     ecx, 5
    lea     rdx, [rip+wg_sc_stack]
    add     rdx, rcx
    mov     [rdx+16], rax               # entry
    mov     ecx, [rip+clip_x0]
    mov     [rdx], ecx
    mov     ecx, [rip+clip_y0]
    mov     [rdx+4], ecx
    mov     ecx, [rip+clip_x1]
    mov     [rdx+8], ecx
    mov     ecx, [rip+clip_y1]
    mov     [rdx+12], ecx
    mov     eax, r13d
    sub     eax, [r15]
    mov     [rdx+24], eax               # content top
    push    rax
    push    r8
    mov     edi, r12d                   # clip to the region (inside the
    mov     esi, r13d                   #  current clip)
    lea     edx, [r12+r14]
    lea     ecx, [r13+r8]
    call    set_clip_in
    pop     r8
    pop     rax
    jmp     9f
8:  mov     eax, r13d
    sub     eax, [r15]
9:  pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# set_clip_in(edi=x0, esi=y0, edx=x1, ecx=y1) - logical, intersected with the
#   current clip
set_clip_in:
    push    rbx
    push    r12
    push    r13
    push    r14
    sub     rsp, 8
    mov     ebx, [rip+clip_x0]
    mov     r12d, [rip+clip_y0]
    mov     r13d, [rip+clip_x1]
    mov     r14d, [rip+clip_y1]
    call    set_clip
    mov     eax, [rip+clip_x0]
    cmp     eax, ebx
    cmovl   eax, ebx
    mov     [rip+clip_x0], eax
    mov     eax, [rip+clip_y0]
    cmp     eax, r12d
    cmovl   eax, r12d
    mov     [rip+clip_y0], eax
    mov     eax, [rip+clip_x1]
    cmp     eax, r13d
    cmovg   eax, r13d
    mov     [rip+clip_x1], eax
    mov     eax, [rip+clip_y1]
    cmp     eax, r14d
    cmovg   eax, r14d
    mov     [rip+clip_y1], eax
    add     rsp, 8
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# wg_scroll_end(edi=bottom y of the content) - clamps the offset, draws the
#   scrollbar (a thumb you can drag) and restores the clip
wg_scroll_end:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    mov     ecx, [rip+wg_sc_depth]
    test    ecx, ecx
    jz      9f
    dec     ecx
    mov     [rip+wg_sc_depth], ecx
    shl     ecx, 5
    lea     r15, [rip+wg_sc_stack]
    add     r15, rcx
    mov     eax, [r15]                  # restore the clip
    mov     [rip+clip_x0], eax
    mov     eax, [r15+4]
    mov     [rip+clip_y0], eax
    mov     eax, [r15+8]
    mov     [rip+clip_x1], eax
    mov     eax, [r15+12]
    mov     [rip+clip_y1], eax
    mov     rbx, [r15+16]               # the region's entry
    test    rbx, rbx
    jz      9f
    mov     eax, [rip+wg_n]             # entries after it are inside it
    mov     [rbx+E_SUB], eax
    sub     edi, [r15+24]               # content height
    mov     r12d, edi
    mov     [rbx+E_AUX], r12d
    mov     r13, [rbx+E_PTR]            # clamp the offset to [0, content - h]
    mov     eax, r12d
    sub     eax, [rbx+E_H]
    jns     1f
    xor     eax, eax
1:  cmp     [r13], eax
    jle     2f
    mov     [r13], eax
2:  cmp     dword ptr [r13], 0
    jge     3f
    mov     dword ptr [r13], 0
3:  cmp     r12d, [rbx+E_H]             # everything fits: no bar
    jle     9f
    mov     r14d, [rbx+E_H]             # thumb: h x h / content, at least 24
    mov     eax, r14d
    imul    eax, r14d
    cdq
    idiv    r12d
    cmp     eax, 24
    jge     4f
    mov     eax, 24
4:  mov     [rsp-8], eax                # (thumb height, below the red zone)
    mov     ecx, r14d                   # thumb y = y + offset x (h - thumb)
    sub     ecx, eax                    #  / (content - h)
    mov     eax, [r13]
    imul    eax, ecx
    mov     ecx, r12d
    sub     ecx, r14d
    cdq
    idiv    ecx
    add     eax, [rbx+E_Y]
    mov     r14d, eax                   # thumb y
    mov     edi, [rbx+E_X]
    add     edi, [rbx+E_W]
    sub     edi, 6
    mov     esi, r14d
    mov     edx, 4
    mov     ecx, [rsp-8]
    push    rcx
    sub     rsp, 8
    mov     r8d, COL_SEPARATOR
    mov     r9d, 2
    call    fill_rrect
    add     rsp, 8
    pop     rcx                         # the thumb as a widget (8 px wide)
    mov     r8d, ecx
    mov     rdi, [rbx+E_DESC]
    mov     esi, 1
    push    r8
    call    wg_id
    pop     r8
    push    rax
    mov     rdi, [rbx+E_DESC]
    mov     esi, [rbx+E_X]
    add     esi, [rbx+E_W]
    sub     esi, 8
    mov     edx, r14d
    mov     ecx, 8
    mov     r9, r13
    mov     r10d, 1
    pop     rax
    call    wg_add
    test    rax, rax
    jz      9f
    mov     dword ptr [rax+E_KIND], WK_THUMB
    mov     [rax+E_AUX], r12d           # content height
    mov     ecx, [rbx+E_H]
    mov     [rax+E_AUX+4], ecx          # track height
9:  pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# -----------------------------------------------------------------------------
# wg_tree_json - this frame's widgets as JSON (appended to wb), for ui_tree
# -----------------------------------------------------------------------------
wg_tree_json:
    push    rbx
    push    r12
    push    r13
    sub     rsp, 16
    lea     rsi, [rip+j_tree_a]
    call    wb_str
    lea     rbx, [rip+wg_list]
    xor     r12d, r12d
1:  cmp     r12d, [rip+wg_n]
    jae     8f
    test    r12d, r12d
    jz      2f
    mov     edi, ','
    call    wb_char
2:  mov     r13, [rbx+E_DESC]
    mov     edi, '{'
    call    wb_char
    lea     rsi, [rip+k_name]
    call    jb_key
    mov     rsi, [r13+WD_NAME]
    call    jb_q
    lea     rsi, [rip+k_sub]
    call    wb_str
    mov     edi, [rbx+E_SUB]
    cmp     dword ptr [rbx+E_KIND], WK_SCROLL
    jne     3f
    xor     edi, edi
3:  movsxd  rdi, edi
    call    wb_int
    lea     rsi, [rip+k_kind]
    call    wb_str
    mov     eax, [rbx+E_KIND]
    lea     rcx, [rip+kind_names]
    mov     rsi, [rcx+rax*8]
    call    jb_q
    lea     rsi, [rip+k_x]
    call    wb_str
    movsxd  rdi, dword ptr [rbx+E_X]
    call    wb_int
    lea     rsi, [rip+k_y]
    call    wb_str
    movsxd  rdi, dword ptr [rbx+E_Y]
    call    wb_int
    lea     rsi, [rip+k_w]
    call    wb_str
    movsxd  rdi, dword ptr [rbx+E_W]
    call    wb_int
    lea     rsi, [rip+k_h]
    call    wb_str
    movsxd  rdi, dword ptr [rbx+E_H]
    call    wb_int
    mov     rsi, [r13+WD_LABEL]
    cmp     dword ptr [rbx+E_KIND], WK_ROW  # (a row: its own text, if set)
    jne     31f
    cmp     qword ptr [rbx+E_AUX], 0
    je      31f
    mov     rsi, [rbx+E_AUX]
31: test    rsi, rsi
    jz      4f
    push    rsi
    lea     rsi, [rip+k_label]
    call    wb_str
    pop     rsi
    call    jb_q
4:  lea     rsi, [rip+k_value]
    call    wb_str
    mov     rax, [rbx+E_PTR]
    mov     ecx, [rbx+E_KIND]
    test    rax, rax
    jz      .Ltj_null
    cmp     ecx, WK_FLOAT
    je      .Ltj_float
    cmp     ecx, WK_SLIDER
    je      .Ltj_float
    cmp     ecx, WK_TEXT
    je      .Ltj_text
    cmp     ecx, WK_INT
    je      .Ltj_int
    cmp     ecx, WK_TOGGLE
    je      .Ltj_int
    cmp     ecx, WK_ENUM
    je      .Ltj_int
    cmp     ecx, WK_TABS
    je      .Ltj_int
    cmp     ecx, WK_SCROLL
    je      .Ltj_int
    cmp     ecx, WK_COLOR
    je      .Ltj_color
.Ltj_null:
    lea     rsi, [rip+j_null]
    call    wb_str
    jmp     5f
.Ltj_float:
    movss   xmm0, [rax]
    call    jb_num
    jmp     5f
.Ltj_int:
    movsxd  rdi, dword ptr [rax]
    call    wb_int
    jmp     5f
.Ltj_color:                             # "#rrggbb"
    mov     rdi, rax
    lea     rsi, [rip+wg_txt]
    call    cpk_hex_of
    lea     rsi, [rip+wg_txt]
    call    jb_q
    jmp     5f
.Ltj_text:
    mov     rsi, rax
    mov     rcx, [rbx+E_DESC]           # (a secret: only whether there is one)
    test    dword ptr [rcx+WD_FLAGS], WGF_SECRET
    jz      0f
    lea     rsi, [rip+s_secret_set]
    cmp     byte ptr [rax], 0
    jne     0f
    lea     rsi, [rip+s_secret_none]
0:  call    jb_q
5:  mov     eax, [rbx+E_ID]
    cmp     eax, [rip+wg_kfocus]        # (the keyboard's focus)
    jne     51f
    lea     rsi, [rip+k_focus]
    call    wb_str
    mov     eax, [rbx+E_ID]
51: cmp     eax, [rip+wg_edit]
    jne     6f
    lea     rsi, [rip+k_edit]
    call    wb_str
6:  mov     edi, '}'
    call    wb_char
    add     rbx, WG_SZ
    inc     r12d
    jmp     1b
8:  mov     edi, r12d                   # the menus (bar, open lists, a pie)
    call    mn_json
    add     r12d, eax
    mov     edi, r12d                   # a tooltip on screen: one more
    call    tip_json
    cmp     dword ptr [rip+tip_shown], 0
    je      80f
    inc     r12d
80: cmp     dword ptr [rip+wg_pop_open], 0  # an open option list: one more,
    je      81f                         #  sub -1, kind "list"
    test    r12d, r12d
    jz      82f
    mov     edi, ','
    call    wb_char
82: mov     edi, '{'
    call    wb_char
    lea     rsi, [rip+k_name]
    call    jb_key
    mov     rax, [rip+wg_pop_e+E_DESC]
    mov     rsi, [rax+WD_NAME]
    call    jb_q
    lea     rsi, [rip+k_list]
    call    wb_str
    movsxd  rdi, dword ptr [rip+wg_pop_x]
    call    wb_int
    lea     rsi, [rip+k_y]
    call    wb_str
    movsxd  rdi, dword ptr [rip+wg_pop_y]
    call    wb_int
    lea     rsi, [rip+k_w]
    call    wb_str
    movsxd  rdi, dword ptr [rip+wg_pop_w]
    call    wb_int
    lea     rsi, [rip+k_h]
    call    wb_str
    call    pop_h
    movsxd  rdi, eax
    call    wb_int
    mov     edi, '}'
    call    wb_char
81: lea     rsi, [rip+j_tree_b]
    call    wb_str
    add     rsp, 16
    pop     r13
    pop     r12
    pop     rbx
    ret

.section .note.GNU-stack,"",@progbits
