# =============================================================================
#  BeeModel - menus: the drop-down menus of the menu bar, their submenus,
#  right-click context menus and pie menus.
#
#  A menu is a list of entries: an operator, 0 (a separator) or a submenu (a
#  SUBMENU record: tag 1, label, entries, count). menu_open says which list
#  is open (ui.s: the bar's menus, the editor-type menu, the modifier types,
#  MENU_CTX for a context menu). One submenu can be open beside it.
#
#  Mouse: hover highlights and opens submenus, release runs. Keyboard: Up /
#  Down move, Right opens a submenu (or the next menu of the bar), Left goes
#  back, Enter runs, Esc closes one level; F10 opens the bar, Alt+letter a
#  menu by its first letter. Items that cannot run now are greyed (op_poll).
#
#  Pie menus: hold a pie key (Z: shading) and the choices appear around the
#  pointer; release over one to pick it. A quick tap still does the key's
#  plain action, so nothing changes for people who never hold it.
# =============================================================================
.intel_syntax noprefix
.include "const.inc"
.include "macros.inc"
.include "icons.inc"

# exports
.globl mn_layout
.globl mn_hit
.globl mn_draw
.globl mn_hover
.globl mn_release
.globl mn_key
.globl mn_close
.globl mn_bar_key
.globl ctx_open_for
.globl mn_json
.globl pie_try
.globl pie_release_key
.globl pie_wait
.globl pie_tick
.globl pie_on
.globl pie_hit
.globl pie_hover
.globl pie_press
.globl pie_draw
.globl pie_close
.globl l1_items

.equ KEY_UP,      103
.equ KEY_DOWN,    108
.equ KEY_LEFT,    105
.equ KEY_RIGHT,   106
.equ KEY_KPENTER, 96
.equ PIE_R,     96                      # distance of the choices from the centre
.equ PIE_DEAD,  22                      # no choice this close to it
.equ PIE_HOLD,  200                     # ms a pie key must be held



.section .bss
.align 4
mn_last:        .skip 4                 # menu_open as last laid out
mn_sub:         .skip 4                 # the open submenu's index, -1 none
mn_sel0:        .skip 4                 # highlighted entry, -1 none
mn_sel1:        .skip 4
mn_focus:       .skip 4                 # the keyboard's level (0 / 1)
mn_fresh:       .skip 4                 # a context menu just opened by a press
l1_x:           .skip 4
l1_y:           .skip 4
l1_w:           .skip 4
l1_h:           .skip 4
l1_count:       .skip 4
.align 8
l1_items:       .skip 8
# pie
pie_on:         .skip 4
pie_armed:      .skip 4                 # key held, not open yet (its code)
pie_cx:         .skip 4
pie_cy:         .skip 4
pie_sel:        .skip 4
pie_n:          .skip 4
.align 8
pie_items:      .skip 8
pie_t0:         .skip 8
pie_bx:         .skip 4*8               # each choice's box
pie_by:         .skip 4*8
pie_bw:         .skip 4*8

.section .data
.align 4
mn_init_done:   .long 0

.section .rodata
s_more:         .asciz ">"
j_menu_a:       .asciz "{\"name\":\"menu."
j_menu_b:       .asciz "\",\"sub\":"
j_kind_menu:    .asciz ",\"kind\":\"menu\""
j_kind_item:    .asciz ",\"kind\":\"menuitem\",\"level\":"
j_kind_pie:     .asciz ",\"kind\":\"pieitem\""
j_x:            .asciz ",\"x\":"
j_y:            .asciz ",\"y\":"
j_w:            .asciz ",\"w\":"
j_h:            .asciz ",\"h\":"
j_label:        .asciz ",\"label\":"
j_why:          .asciz ",\"why\":"
j_null:         .asciz "null"
j_item_a:       .asciz "{\"name\":"
j_sub_name:     .asciz "\"submenu\""
j_pie_name:     .asciz "\"pie\""
j_end:          .asciz "}"

# ---- the lists --------------------------------------------------------------------
.section .rodata
.align 2
pie_dir:        .byte -1,0, 1,0, 0,1, 0,-1, -1,-1, 1,-1, -1,1, 1,1
pie_diag:       .byte 10, 10, 10, 10, 7, 7, 7, 7
.align 8
pie_shading:    .quad op_shade_solid, op_shade_wire, op_shade_mat
.equ pie_shading_n, (. - pie_shading) / 8

ctx_object:     .quad op_duplicate, op_delete, 0, op_hide, op_reveal, 0
                .quad op_edit_toggle, 0, sub_boolean, op_repair, 0, op_obj_measure
.equ ctx_object_n, (. - ctx_object) / 8
ctx_edit:       .quad op_m_extrude, op_m_inset, op_m_bevel, op_m_loopcut, op_m_knife, 0
                .quad op_m_subdivide, op_m_fill, op_m_bridge, sub_merge, sub_mdelete, 0
                .quad op_m_flip, op_m_recalc, 0, op_edit_toggle
.equ ctx_edit_n, (. - ctx_edit) / 8
ctx_outliner:   .quad op_duplicate, op_delete, 0, op_hide, op_reveal
.equ ctx_outliner_n, (. - ctx_outliner) / 8
ctx_header:     .quad op_area_split_side, op_area_split_stack, op_area_maximize, op_area_close
.equ ctx_header_n, (. - ctx_header) / 8

sub_bool_l:     .quad op_bool_union, op_bool_diff, op_bool_isect
sub_merge_l:    .quad op_m_merge_c, op_m_merge_col, op_m_merge_d
sub_mdel_l:     .quad op_m_del_v, op_m_del_e, op_m_del_f

.text
SUBMENU sub_boolean, "Boolean", sub_bool_l, 3
SUBMENU sub_merge, "Merge", sub_merge_l, 3
SUBMENU sub_mdelete, "Delete", sub_mdel_l, 3


.text

# ---- entries ----------------------------------------------------------------------
# label_of(rdi=entry) -> rax = its label
label_of:
    cmp     qword ptr [rdi], SUBTAG
    jne     1f
    mov     rax, [rdi+SUB_LABEL]
    ret
1:  mov     rax, [rdi+OP_LABEL]
    ret

# list_h(rdi=entries, esi=count) -> eax = the list's height (with padding)
list_h:
    mov     eax, 8
1:  test    esi, esi
    jz      9f
    mov     ecx, MENU_ITEM_H
    cmp     qword ptr [rdi], 0
    jne     2f
    mov     ecx, MENU_SEP_H
2:  add     eax, ecx
    add     rdi, 8
    dec     esi
    jmp     1b
9:  ret

# list_y(rdi=entries, esi=index) -> eax = the entry's offset from the top
list_y:
    mov     eax, 4
1:  test    esi, esi
    jz      9f
    mov     ecx, MENU_ITEM_H
    cmp     qword ptr [rdi], 0
    jne     2f
    mov     ecx, MENU_SEP_H
2:  add     eax, ecx
    add     rdi, 8
    dec     esi
    jmp     1b
9:  ret

# list_at(rdi=entries, esi=count, edx=y offset) -> eax = entry, -1 none
list_at:
    cmp     edx, 4                      # (the top padding is no entry)
    jl      8f
    mov     ecx, 4
    xor     eax, eax
1:  cmp     eax, esi
    jae     8f
    mov     r8d, MENU_ITEM_H
    cmp     qword ptr [rdi+rax*8], 0
    jne     2f
    mov     r8d, MENU_SEP_H
2:  add     ecx, r8d
    cmp     edx, ecx
    jl      3f
    inc     eax
    jmp     1b
3:  cmp     qword ptr [rdi+rax*8], 0
    jne     9f
8:  mov     eax, -1
9:  ret

# level0 -> rax = entries, edx = count of the open menu
level0:
    mov     ecx, [rip+menu_open]
    lea     rax, [rip+menu_counts]
    mov     edx, [rax+rcx*4]
    lea     rax, [rip+menu_items]
    mov     rax, [rax+rcx*8]
    ret

# ---- layout -----------------------------------------------------------------------
# mn_layout - the open menu's rectangle (drop_*) and its submenu's (l1_*)
mn_layout:
    push    rbx
    push    r12
    sub     rsp, 8
    mov     eax, [rip+menu_open]
    cmp     eax, [rip+mn_last]          # another menu: nothing highlighted
    je      1f
    mov     [rip+mn_last], eax
    mov     dword ptr [rip+mn_sub], -1
    mov     dword ptr [rip+mn_sel0], -1
    mov     dword ptr [rip+mn_sel1], -1
    mov     dword ptr [rip+mn_focus], 0
1:  test    eax, eax
    js      9f
    cmp     eax, MENU_MODADD            # pop-ups: at the pointer (md_x, md_y)
    jb      2f
    mov     ecx, [rip+md_y]
    mov     [rip+drop_y], ecx
    mov     ecx, [rip+md_x]
    jmp     4f
2:  cmp     eax, MENU_AREA              # the editor type: under the header
    jne     3f
    mov     edi, [rip+active_area]
    call    area_node_rect
    mov     ecx, [rax+16]
    add     ecx, PANE_HDR_H
    mov     [rip+drop_y], ecx
    mov     ecx, [rax+12]
    jmp     4f
3:  lea     rcx, [rip+menu_x]           # the bar: under its title
    mov     ecx, [rcx+rax*4]
    mov     dword ptr [rip+drop_y], TITLE_H+MENU_H
4:  mov     edx, [rip+win_w]
    sub     edx, MENU_DROP_W
    cmp     ecx, edx
    cmovg   ecx, edx
    test    ecx, ecx
    jns     5f
    xor     ecx, ecx
5:  mov     [rip+drop_x], ecx
    mov     dword ptr [rip+drop_w], MENU_DROP_W
    call    level0
    mov     rdi, rax
    mov     esi, edx
    call    list_h
    mov     [rip+drop_h], eax
    mov     ecx, [rip+win_h]            # keep it on screen
    sub     ecx, eax
    sub     ecx, 2
    cmp     [rip+drop_y], ecx
    jle     6f
    mov     [rip+drop_y], ecx
6:  mov     esi, [rip+mn_sub]           # the submenu, beside its entry
    test    esi, esi
    js      9f
    call    level0
    mov     rbx, [rax+rsi*8]
    mov     rax, [rbx+SUB_ITEMS]
    mov     [rip+l1_items], rax
    mov     eax, [rbx+SUB_COUNT]
    mov     [rip+l1_count], eax
    call    level0
    mov     rdi, rax
    call    list_y
    add     eax, [rip+drop_y]
    sub     eax, 4
    mov     [rip+l1_y], eax
    mov     dword ptr [rip+l1_w], MENU_DROP_W
    mov     rdi, [rip+l1_items]
    mov     esi, [rip+l1_count]
    call    list_h
    mov     [rip+l1_h], eax
    mov     ecx, [rip+win_h]
    sub     ecx, eax
    sub     ecx, 2
    cmp     [rip+l1_y], ecx
    jle     7f
    mov     [rip+l1_y], ecx
7:  mov     eax, [rip+drop_x]           # right of the menu, or left of it
    add     eax, MENU_DROP_W-3
    mov     ecx, eax
    add     ecx, MENU_DROP_W
    cmp     ecx, [rip+win_w]
    jle     8f
    mov     eax, [rip+drop_x]
    sub     eax, MENU_DROP_W-3
8:  mov     [rip+l1_x], eax
9:  add     rsp, 8
    pop     r12
    pop     rbx
    ret

# ---- hit testing ----------------------------------------------------------------
# mn_hit(edi=x, esi=y) -> eax = HIT_SUBITEM / HIT_MENU_ITEM / HIT_DROPDOWN,
#   edx = entry (-1: padding, a separator); eax = 0 when not in a menu
mn_hit:
    cmp     dword ptr [rip+menu_open], 0
    jl      8f
    cmp     dword ptr [rip+mn_sub], 0
    jl      2f
    mov     eax, edi                    # the submenu is on top
    sub     eax, [rip+l1_x]
    js      2f
    cmp     eax, [rip+l1_w]
    jge     2f
    mov     edx, esi
    sub     edx, [rip+l1_y]
    js      2f
    cmp     edx, [rip+l1_h]
    jge     2f
    push    rdi
    mov     rdi, [rip+l1_items]
    push    rsi
    mov     esi, [rip+l1_count]
    call    list_at
    pop     rsi
    pop     rdi
    mov     edx, eax
    mov     eax, HIT_SUBITEM
    ret
2:  mov     eax, edi
    sub     eax, [rip+drop_x]
    js      8f
    cmp     eax, [rip+drop_w]
    jge     8f
    mov     edx, esi
    sub     edx, [rip+drop_y]
    js      8f
    cmp     edx, [rip+drop_h]
    jge     8f
    push    rdx
    call    level0
    mov     rdi, rax
    mov     esi, edx
    pop     rdx
    call    list_at
    mov     edx, eax
    mov     eax, HIT_MENU_ITEM
    test    edx, edx
    jns     9f
    mov     eax, HIT_DROPDOWN
9:  ret
8:  xor     eax, eax
    ret

# mn_hover(edi=hit, esi=entry) - the pointer highlights, opens submenus
mn_hover:
    cmp     dword ptr [rip+menu_open], 0
    jl      9f
    cmp     edi, HIT_SUBITEM
    jne     1f
    cmp     esi, [rip+mn_sel1]
    je      9f
    mov     [rip+mn_sel1], esi
    mov     dword ptr [rip+mn_focus], 1
    mov     dword ptr [rip+dirty], 1
    ret
1:  cmp     edi, HIT_MENU_ITEM
    jne     9f
    cmp     esi, [rip+mn_sel0]
    je      9f
    mov     [rip+mn_sel0], esi
    mov     dword ptr [rip+mn_focus], 0
    mov     dword ptr [rip+dirty], 1
    call    level0                      # a submenu entry opens it, another
    mov     rax, [rax+rsi*8]            #  entry closes the open one
    cmp     qword ptr [rax], SUBTAG
    jne     2f
    mov     [rip+mn_sub], esi
    mov     dword ptr [rip+mn_sel1], -1
    jmp     ui_layout
2:  mov     dword ptr [rip+mn_sub], -1
9:  ret

# mn_close - every menu level closes
mn_close:
    mov     dword ptr [rip+menu_open], -1
    mov     dword ptr [rip+mn_sub], -1
    mov     dword ptr [rip+mn_sel0], -1
    mov     dword ptr [rip+mn_sel1], -1
    mov     dword ptr [rip+dirty], 1
    ret

# mn_release(edi=hit, esi=entry) -> eax = 1 if it was for a menu entry: a
#   submenu opens (and stays), an operator runs (or says why it cannot)
mn_release:
    push    rbx
    cmp     dword ptr [rip+mn_fresh], 0 # the release of the click that opened
    je      0f                          #  a context menu picks nothing unless
    mov     dword ptr [rip+mn_fresh], 0 #  the pointer moved on
    mov     eax, [rip+ptr_x]
    sub     eax, [rip+md_x]
    mov     ecx, eax
    neg     ecx
    cmovl   ecx, eax
    mov     eax, [rip+ptr_y]
    sub     eax, [rip+md_y]
    mov     edx, eax
    neg     edx
    cmovl   edx, eax
    add     ecx, edx
    cmp     ecx, 4
    jl      8f
0:
    cmp     edi, HIT_SUBITEM
    jne     1f
    test    esi, esi
    js      8f
    mov     rax, [rip+l1_items]
    mov     rbx, [rax+rsi*8]
    jmp     3f
1:  cmp     edi, HIT_MENU_ITEM
    jne     7f
    test    esi, esi
    js      8f
    call    level0
    mov     rbx, [rax+rsi*8]
    cmp     qword ptr [rbx], SUBTAG
    jne     3f
    mov     [rip+mn_sub], esi           # a submenu: open it, keyboard on it
    mov     [rip+mn_sel0], esi
    mov     dword ptr [rip+mn_sel1], -1
    mov     dword ptr [rip+dirty], 1
    call    ui_layout
    jmp     8f
3:  call    mn_close
    mov     rdi, rbx
    call    run_op_ui
8:  mov     eax, 1
    pop     rbx
    ret
7:  xor     eax, eax
    pop     rbx
    ret

# ---- keyboard ---------------------------------------------------------------------
# mn_key(edi=evdev) -> eax = 1 if a menu used the key
mn_key:
    cmp     dword ptr [rip+menu_open], 0
    jl      .Lmk_no
    push    rbx
    mov     ebx, edi
    cmp     ebx, KEY_ESC
    je      .Lmk_esc
    cmp     ebx, KEY_DOWN
    je      .Lmk_down
    cmp     ebx, KEY_UP
    je      .Lmk_up
    cmp     ebx, KEY_RIGHT
    je      .Lmk_right
    cmp     ebx, KEY_LEFT
    je      .Lmk_left
    cmp     ebx, KEY_ENTER
    je      .Lmk_enter
    cmp     ebx, KEY_KPENTER
    je      .Lmk_enter
    pop     rbx
.Lmk_no:
    xor     eax, eax
    ret
.Lmk_esc:
    cmp     dword ptr [rip+mn_sub], 0
    jl      1f
    cmp     dword ptr [rip+mn_focus], 0
    je      1f
    mov     dword ptr [rip+mn_sub], -1  # back to the menu
    mov     dword ptr [rip+mn_focus], 0
    mov     dword ptr [rip+dirty], 1
    jmp     .Lmk_yes
1:  call    mn_close
    jmp     .Lmk_yes
.Lmk_down:
    mov     esi, 1
    jmp     .Lmk_move
.Lmk_up:
    mov     esi, -1
.Lmk_move:
    call    focus_list                  # rdi = entries, edx = count, rcx = &sel
    mov     eax, [rcx]
    mov     r8d, edx
1:  add     eax, esi                    # the next entry that is not a separator
    cmp     eax, -1
    jg      2f
    lea     eax, [r8-1]
2:  cmp     eax, r8d
    jl      3f
    xor     eax, eax
3:  cmp     qword ptr [rdi+rax*8], 0
    je      1b
    mov     [rcx], eax
    mov     dword ptr [rip+dirty], 1
    jmp     .Lmk_yes
.Lmk_right:
    cmp     dword ptr [rip+mn_focus], 0
    jne     .Lmk_yes
    mov     esi, [rip+mn_sel0]          # on a submenu entry: into it
    test    esi, esi
    js      1f
    call    level0
    mov     rax, [rax+rsi*8]
    cmp     qword ptr [rax], SUBTAG
    jne     1f
    call    open_sub_kb
    jmp     .Lmk_yes
1:  mov     edi, 1                      # else the next menu of the bar
    call    bar_step
    jmp     .Lmk_yes
.Lmk_left:
    cmp     dword ptr [rip+mn_focus], 0
    je      1f
    mov     dword ptr [rip+mn_sub], -1
    mov     dword ptr [rip+mn_focus], 0
    mov     dword ptr [rip+dirty], 1
    jmp     .Lmk_yes
1:  mov     edi, -1
    call    bar_step
    jmp     .Lmk_yes
.Lmk_enter:
    cmp     dword ptr [rip+mn_focus], 0
    jne     1f
    mov     esi, [rip+mn_sel0]
    test    esi, esi
    js      .Lmk_yes
    call    level0
    mov     rax, [rax+rsi*8]
    cmp     qword ptr [rax], SUBTAG
    jne     2f
    call    open_sub_kb
    jmp     .Lmk_yes
2:  mov     edi, HIT_MENU_ITEM
    call    mn_release
    jmp     .Lmk_yes
1:  mov     esi, [rip+mn_sel1]
    test    esi, esi
    js      .Lmk_yes
    mov     edi, HIT_SUBITEM
    call    mn_release
.Lmk_yes:
    mov     eax, 1
    pop     rbx
    ret

# focus_list -> rdi = the keyboard level's entries, edx = count, rcx = &sel
focus_list:
    cmp     dword ptr [rip+mn_focus], 0
    je      1f
    mov     rdi, [rip+l1_items]
    mov     edx, [rip+l1_count]
    lea     rcx, [rip+mn_sel1]
    ret
1:  push    rsi
    call    level0
    pop     rsi
    mov     rdi, rax
    lea     rcx, [rip+mn_sel0]
    ret

# open_sub_kb - open the highlighted submenu, keyboard in it on its first
open_sub_kb:
    mov     eax, [rip+mn_sel0]
    mov     [rip+mn_sub], eax
    mov     dword ptr [rip+mn_focus], 1
    mov     dword ptr [rip+mn_sel1], 0
    mov     dword ptr [rip+dirty], 1
    jmp     ui_layout

# bar_step(edi = +1 / -1) - the next / previous menu of the bar
bar_step:
    mov     eax, [rip+menu_open]
    cmp     eax, NUM_MENUS
    jae     9f                          # (pop-ups have no neighbours)
    add     eax, edi
    jns     1f
    mov     eax, NUM_MENUS-1
1:  cmp     eax, NUM_MENUS
    jb      2f
    xor     eax, eax
2:  jmp     open_bar
9:  ret

# open_bar(eax = menu) - from the keyboard: its first entry highlighted
open_bar:
    mov     [rip+menu_open], eax
    push    rax
    call    ui_layout                   # (resets the levels)
    pop     rax
    mov     dword ptr [rip+mn_sel0], 0
    mov     dword ptr [rip+dirty], 1
    ret

# mn_bar_key(edi=evdev) -> eax = 1 if it opened a menu: F10 the first one,
#   Alt+letter the one whose title starts with that letter
mn_bar_key:
    cmp     edi, KEY_F1+9
    jne     1f
    xor     eax, eax
    call    open_bar
    mov     eax, 1
    ret
1:  mov     eax, [rip+key_mods]
    and     eax, MOD_ALT|MOD_CTRL|MOD_SHIFT
    cmp     eax, MOD_ALT
    jne     8f
    push    rbx
    push    r12
    sub     rsp, 8
    mov     ebx, edi
    call    kb_layout_code              # an operator on Alt+that key keeps it
    or      eax, KM_ALT
    lea     rcx, [rip+__start_bee_ops]
    lea     rdx, [rip+__stop_bee_ops]
4:  cmp     rcx, rdx
    jae     5f
    cmp     [rcx+OP_KEY], eax
    je      7f
    add     rcx, OP_SIZE
    jmp     4b
5:  mov     edi, ebx
    call    kb_sym                      # the letter (layout aware)
    or      eax, 0x20
    mov     ebx, eax
    xor     r12d, r12d
2:  cmp     r12d, NUM_MENUS
    jae     7f
    lea     rax, [rip+menu_titles]
    mov     rax, [rax+r12*8]
    movzx   eax, byte ptr [rax]
    or      eax, 0x20
    cmp     eax, ebx
    je      3f
    inc     r12d
    jmp     2b
3:  mov     eax, r12d
    call    open_bar
    mov     eax, 1
    jmp     6f
7:  xor     eax, eax
6:  add     rsp, 8
    pop     r12
    pop     rbx
    ret
8:  xor     eax, eax
    ret

# ---- drawing ----------------------------------------------------------------------
# mn_draw - the open menu and its submenu
mn_draw:
    cmp     dword ptr [rip+menu_open], 0
    jl      9f
    sub     rsp, 8
    call    level0
    mov     edi, [rip+drop_x]
    mov     esi, [rip+drop_y]
    mov     ecx, [rip+drop_h]
    mov     r8, rax
    mov     r9d, edx
    mov     edx, [rip+drop_w]
    push    qword ptr [rip+mn_sub]      # (the open submenu's entry stays lit)
    push    qword ptr [rip+mn_sel0]
    call    draw_list
    add     rsp, 16
    cmp     dword ptr [rip+mn_sub], 0
    jl      1f
    mov     edi, [rip+l1_x]
    mov     esi, [rip+l1_y]
    mov     edx, [rip+l1_w]
    mov     ecx, [rip+l1_h]
    mov     r8, [rip+l1_items]
    mov     r9d, [rip+l1_count]
    push    -1
    push    qword ptr [rip+mn_sel1]
    call    draw_list
    add     rsp, 16
1:  add     rsp, 8
9:  ret

# draw_list(edi=x, esi=y, edx=w, ecx=h, r8=entries, r9d=count,
#   [rsp+8]=highlighted entry, [rsp+16]=an entry lit as open)
draw_list:
    push    rbx
    push    rbp
    push    r12
    push    r13
    push    r14
    push    r15
    sub     rsp, 24
    mov     eax, [rsp+80]               # highlighted
    mov     [rsp], eax
    mov     eax, [rsp+88]               # open
    mov     [rsp+4], eax
    mov     r15d, edi                   # x
    mov     r12d, esi                   # y
    mov     [rsp+8], edx                # w
    mov     r14, r8                     # entries
    mov     r13d, r9d                   # count
    mov     r8d, COL_DROP_BORDER
    call    popup_frame
    add     r12d, 4
    xor     ebx, ebx
.Ldl_item:
    cmp     ebx, r13d
    jae     .Ldl_done
    mov     rbp, [r14+rbx*8]
    test    rbp, rbp
    jnz     1f
    lea     edi, [r15+8]                # a separator
    lea     esi, [r12+4]
    mov     edx, [rsp+8]
    sub     edx, 16
    mov     ecx, 1
    mov     r8d, COL_SEPARATOR
    call    fill_rect
    add     r12d, MENU_SEP_H
    jmp     .Ldl_next
1:  cmp     ebx, [rsp]                  # highlighted (or its submenu open)
    je      2f
    cmp     ebx, [rsp+4]
    jne     3f
2:  lea     edi, [r15+3]
    mov     esi, r12d
    mov     edx, [rsp+8]
    sub     edx, 6
    mov     ecx, MENU_ITEM_H
    mov     r8d, COL_HOVER
    mov     r9d, FIELD_R
    call    fill_rrect
    lea     edi, [r15+3]
    lea     esi, [r12+5]
    mov     edx, 3
    mov     ecx, MENU_ITEM_H-10
    mov     r8d, COL_ACCENT
    call    fill_rect
3:  mov     dword ptr [rsp+12], COL_TEXT
    cmp     qword ptr [rbp], SUBTAG
    je      5f
    mov     rdi, rbp                    # an operator: greyed when it cannot
    call    op_poll                     #  run now; a check mark when on
    test    rax, rax
    jz      4f
    mov     dword ptr [rsp+12], COL_TEXT_OFF
4:  mov     rdi, rbp
    call    op_checked
    cmp     eax, 1
    jne     5f
    lea     edi, [r15+9]
    lea     esi, [r12+4]
    mov     edx, ICON_CHECK
    mov     r8d, COL_ACCENT
    call    draw_icon
5:  lea     edi, [r15+28]               # the label
    lea     esi, [r12+4]
    mov     rdi, rbp
    call    label_of
    mov     rdx, rax
    lea     edi, [r15+28]
    lea     esi, [r12+4]
    mov     ecx, [rsp+12]
    call    draw_text
    cmp     qword ptr [rbp], SUBTAG     # a submenu: a chevron on the right
    jne     6f
    mov     edi, r15d
    add     edi, [rsp+8]
    sub     edi, 22
    lea     esi, [r12+4]
    mov     edx, ICON_CHEVRON_RIGHT
    mov     r8d, COL_TEXT_DIM
    call    draw_icon
    jmp     7f
6:  mov     edi, [rbp+OP_KEY]           # an operator: its shortcut
    call    fmt_key
    test    rax, rax
    jz      7f
    mov     [rsp+16], rax
    mov     rdi, rax
    call    text_width
    mov     edi, r15d
    add     edi, [rsp+8]
    sub     edi, 12
    sub     edi, eax
    lea     esi, [r12+4]
    mov     rdx, [rsp+16]
    mov     ecx, COL_TEXT_DIM
    cmp     dword ptr [rsp+12], COL_TEXT_OFF
    jne     61f
    mov     ecx, COL_TEXT_OFF
61: call    draw_text
7:  add     r12d, MENU_ITEM_H
.Ldl_next:
    inc     ebx
    jmp     .Ldl_item
.Ldl_done:
    add     rsp, 24
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbp
    pop     rbx
    ret

# ---- context menus ----------------------------------------------------------------
# ctx_open_for(edi=hit id, esi=index) -> eax = 1 if a context menu opened at
#   the pointer for what is under it
ctx_open_for:
    push    rbx
    xor     eax, eax
    lea     rbx, [rip+ctx_object]
    mov     ecx, ctx_object_n
    cmp     edi, HIT_CANVAS
    jne     1f
    cmp     dword ptr [rip+edit_obj], 0
    je      5f
    lea     rbx, [rip+ctx_edit]
    mov     ecx, ctx_edit_n
    jmp     5f
1:  cmp     edi, HIT_OUTLINER
    jne     11f
    lea     rbx, [rip+ctx_outliner]
    mov     ecx, ctx_outliner_n
    jmp     5f
11: cmp     edi, HIT_ASSETS             # an asset tile (teamui.s)
    jne     2f
    lea     rbx, [rip+ctx_assets]
    mov     ecx, [rip+ctx_assets_n]
    jmp     5f
2:  cmp     edi, HIT_AREA_HDR
    je      3f
    cmp     edi, HIT_AREA_TYPE
    jne     9f
3:  lea     rbx, [rip+ctx_header]
    mov     ecx, ctx_header_n
5:  lea     rax, [rip+menu_items]       # the context menu's slot
    mov     [rax+MENU_CTX*8], rbx
    lea     rax, [rip+menu_counts]
    mov     [rax+MENU_CTX*4], ecx
    mov     eax, [rip+ptr_x]
    mov     [rip+md_x], eax
    mov     eax, [rip+ptr_y]
    mov     [rip+md_y], eax
    mov     dword ptr [rip+menu_open], MENU_CTX
    mov     dword ptr [rip+mn_fresh], 1
    mov     dword ptr [rip+dirty], 1
    call    ui_layout
    mov     eax, 1
9:  pop     rbx
    ret

# ---- ui_tree ----------------------------------------------------------------------
# mn_json(edi = entries before) -> eax = entries written: the bar's menus,
#   the open menu's entries (level 0, 1) and an open pie's choices
mn_json:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    mov     r15d, edi                   # entries so far
    xor     r14d, r14d                  # written
    xor     ebx, ebx
1:  cmp     ebx, NUM_MENUS              # the bar
    jae     2f
    call    jcomma
    lea     rsi, [rip+j_menu_a]
    call    wb_str
    lea     rax, [rip+menu_titles]
    mov     rsi, [rax+rbx*8]
    call    wb_str
    lea     rsi, [rip+j_menu_b]
    call    wb_str
    mov     edi, ebx
    call    wb_int
    lea     rsi, [rip+j_kind_menu]
    call    wb_str
    lea     rax, [rip+menu_x]
    mov     edi, [rax+rbx*4]
    mov     esi, TITLE_H
    mov     edx, [rax+rbx*4+4]
    sub     edx, edi
    mov     ecx, MENU_H
    call    jrect
    lea     rsi, [rip+j_label]
    call    wb_str
    lea     rax, [rip+menu_titles]
    mov     rsi, [rax+rbx*8]
    call    jb_q
    lea     rsi, [rip+j_end]
    call    wb_str
    inc     ebx
    jmp     1b
2:  cmp     dword ptr [rip+menu_open], 0
    jl      5f
    call    level0
    mov     rdi, rax
    mov     esi, edx
    mov     edx, [rip+drop_x]
    mov     ecx, [rip+drop_y]
    xor     r8d, r8d
    call    jlist
    cmp     dword ptr [rip+mn_sub], 0
    jl      5f
    mov     rdi, [rip+l1_items]
    mov     esi, [rip+l1_count]
    mov     edx, [rip+l1_x]
    mov     ecx, [rip+l1_y]
    mov     r8d, 1
    call    jlist
5:  cmp     dword ptr [rip+pie_on], 0   # the pie
    je      8f
    xor     ebx, ebx
6:  cmp     ebx, [rip+pie_n]
    jae     8f
    call    jcomma
    lea     rsi, [rip+j_item_a]
    call    wb_str
    mov     rax, [rip+pie_items]
    mov     rax, [rax+rbx*8]
    mov     rsi, [rax+OP_NAME]
    call    jb_q
    lea     rsi, [rip+j_menu_b+1]       # ,"sub":
    call    wb_str
    mov     edi, ebx
    call    wb_int
    lea     rsi, [rip+j_kind_pie]
    call    wb_str
    lea     rax, [rip+pie_bx]
    mov     edi, [rax+rbx*4]
    lea     rax, [rip+pie_by]
    mov     esi, [rax+rbx*4]
    lea     rax, [rip+pie_bw]
    mov     edx, [rax+rbx*4]
    mov     ecx, MENU_ITEM_H
    call    jrect
    lea     rsi, [rip+j_label]
    call    wb_str
    mov     rax, [rip+pie_items]
    mov     rax, [rax+rbx*8]
    mov     rsi, [rax+OP_LABEL]
    call    jb_q
    lea     rsi, [rip+j_end]
    call    wb_str
    inc     ebx
    jmp     6b
8:  mov     eax, r14d
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# (helpers of mn_json: r14d counts, r15d = entries before it)
jcomma:
    mov     eax, r14d
    add     eax, r15d
    inc     r14d
    test    eax, eax
    jz      1f
    mov     edi, ','
    jmp     wb_char
1:  ret

jrect:                                  # edi x, esi y, edx w, ecx h
    push    rsi
    push    rdx
    push    rcx
    push    rdi
    lea     rsi, [rip+j_x]
    call    wb_str
    pop     rdi
    movsxd  rdi, edi
    call    wb_int
    lea     rsi, [rip+j_y]
    call    wb_str
    mov     rdi, [rsp+16]
    movsxd  rdi, edi
    call    wb_int
    lea     rsi, [rip+j_w]
    call    wb_str
    mov     rdi, [rsp+8]
    movsxd  rdi, edi
    call    wb_int
    lea     rsi, [rip+j_h]
    call    wb_str
    mov     rdi, [rsp]
    movsxd  rdi, edi
    call    wb_int
    add     rsp, 24
    ret

# jlist(rdi=entries, esi=count, edx=x, ecx=y, r8d=level) - the entries
jlist:
    push    rbx
    push    rbp
    push    r12
    push    r13
    sub     rsp, 24
    mov     r12, rdi
    mov     r13d, esi
    mov     [rsp], edx
    mov     [rsp+4], ecx
    mov     [rsp+8], r8d
    xor     ebx, ebx
1:  cmp     ebx, r13d
    jae     9f
    mov     rbp, [r12+rbx*8]
    test    rbp, rbp
    jz      8f
    call    jcomma
    lea     rsi, [rip+j_item_a]
    call    wb_str
    cmp     qword ptr [rbp], SUBTAG
    jne     2f
    lea     rsi, [rip+j_sub_name]
    call    wb_str
    jmp     3f
2:  mov     rsi, [rbp+OP_NAME]
    call    jb_q
3:  lea     rsi, [rip+j_menu_b+1]       # ,"sub":
    call    wb_str
    mov     edi, ebx
    call    wb_int
    lea     rsi, [rip+j_kind_item]
    call    wb_str
    mov     edi, [rsp+8]
    call    wb_int
    mov     rdi, r12
    mov     esi, ebx
    call    list_y
    mov     esi, eax
    add     esi, [rsp+4]
    mov     edi, [rsp]
    mov     edx, MENU_DROP_W
    mov     ecx, MENU_ITEM_H
    call    jrect
    lea     rsi, [rip+j_label]
    call    wb_str
    mov     rdi, rbp
    call    label_of
    mov     rsi, rax
    call    jb_q
    cmp     qword ptr [rbp], SUBTAG
    je      4f
    lea     rsi, [rip+j_why]
    call    wb_str
    mov     rdi, rbp
    call    op_poll
    mov     rsi, rax
    test    rsi, rsi
    jz      5f
    call    jb_q
    jmp     4f
5:  lea     rsi, [rip+j_null]
    call    wb_str
4:  lea     rsi, [rip+j_end]
    call    wb_str
8:  inc     ebx
    jmp     1b
9:  add     rsp, 24
    pop     r13
    pop     r12
    pop     rbp
    pop     rbx
    ret

# ---- pie menus --------------------------------------------------------------------
# pie_try(edi=evdev) -> eax = 1 if the key is a pie key (it waits: a hold
#   opens the pie, a tap does the plain action on release)
pie_try:
    xor     eax, eax
    cmp     dword ptr [rip+pie_on], 0
    jne     9f
    cmp     edi, KEY_Z                  # Z: shading
    jne     9f
    test    dword ptr [rip+key_mods], MOD_ALT|MOD_CTRL|MOD_SHIFT
    jnz     9f
    cmp     dword ptr [rip+hit_area], 0 # (over the 3D viewport)
    jl      9f
    push    rdi
    mov     edi, [rip+hit_area]
    call    area_editor
    pop     rdi
    cmp     eax, ED_VIEWPORT
    jne     8f
    mov     [rip+pie_armed], edi
    lea     rax, [rip+pie_shading]
    mov     [rip+pie_items], rax
    mov     dword ptr [rip+pie_n], pie_shading_n
    sub     rsp, 8
    call    mono_ns
    add     rsp, 8
    mov     [rip+pie_t0], rax
    mov     eax, 1
    ret
8:  xor     eax, eax
9:  ret

# pie_wait -> eax = ms until an armed pie opens, -1 if none
pie_wait:
    mov     eax, -1
    cmp     dword ptr [rip+pie_armed], 0
    je      9f
    sub     rsp, 8
    call    mono_ns
    add     rsp, 8
    sub     rax, [rip+pie_t0]
    xor     edx, edx
    mov     ecx, 1000000
    div     rcx
    mov     ecx, PIE_HOLD
    sub     ecx, eax
    xor     eax, eax
    test    ecx, ecx
    cmovg   eax, ecx
    inc     eax
9:  ret

# pie_tick - an armed pie whose hold is long enough opens at the pointer
pie_tick:
    cmp     dword ptr [rip+pie_armed], 0
    je      9f
    sub     rsp, 8
    call    pie_wait
    add     rsp, 8
    cmp     eax, 1
    ja      9f
    jmp     pie_open
9:  ret

pie_open:
    push    rbx
    push    r12
    push    r13
    mov     eax, [rip+ptr_x]
    mov     [rip+pie_cx], eax
    mov     eax, [rip+ptr_y]
    mov     [rip+pie_cy], eax
    mov     dword ptr [rip+pie_on], 1
    mov     dword ptr [rip+pie_sel], -1
    mov     dword ptr [rip+dirty], 1
    xor     ebx, ebx                    # place the choices: W E S N NW NE SW SE
1:  cmp     ebx, [rip+pie_n]
    jae     9f
    mov     rax, [rip+pie_items]
    mov     rax, [rax+rbx*8]
    mov     rdi, [rax+OP_LABEL]
    call    text_width
    add     eax, 28
    lea     rcx, [rip+pie_bw]
    mov     [rcx+rbx*4], eax
    mov     r12d, eax
    lea     rcx, [rip+pie_dir]
    movsx   eax, byte ptr [rcx+rbx*2]   # direction x, y in -1..1
    movsx   edx, byte ptr [rcx+rbx*2+1]
    imul    eax, PIE_R
    imul    edx, PIE_R*3/4
    add     eax, [rip+pie_cx]
    add     edx, [rip+pie_cy]
    mov     ecx, r12d                   # box centred there (sides: hung off it)
    shr     ecx, 1
    sub     eax, ecx
    lea     rcx, [rip+pie_dir]
    movsx   r8d, byte ptr [rcx+rbx*2]
    imul    r8d, r12d
    sar     r8d, 1
    add     eax, r8d
    sub     edx, MENU_ITEM_H/2
    lea     rcx, [rip+pie_bx]
    mov     [rcx+rbx*4], eax
    lea     rcx, [rip+pie_by]
    mov     [rcx+rbx*4], edx
    inc     ebx
    jmp     1b
9:  mov     dword ptr [rip+pie_armed], 0
    pop     r13
    pop     r12
    pop     rbx
    ret

pie_close:
    mov     dword ptr [rip+pie_on], 0
    mov     dword ptr [rip+pie_armed], 0
    mov     dword ptr [rip+dirty], 1
    ret

# pie_release_key(edi=evdev) -> eax = 1 if it was the pie key: a tap does
#   the key's own action, a release over a choice runs it
pie_release_key:
    cmp     edi, [rip+pie_armed]
    jne     1f
    test    edi, edi
    jz      1f
    mov     dword ptr [rip+pie_armed], 0  # a tap: the plain key
    sub     rsp, 8
    call    dispatch_key
    add     rsp, 8
    mov     eax, 1
    ret
1:  cmp     dword ptr [rip+pie_on], 0
    je      8f
    cmp     edi, KEY_Z
    jne     8f
    mov     eax, [rip+pie_sel]          # released over a choice: pick it;
    test    eax, eax                    #  over the centre: it stays for a click
    js      7f
    jmp     pie_run
7:  mov     eax, 1
    ret
8:  xor     eax, eax
    ret

# pie_run(eax = choice) - runs it, closes the pie
pie_run:
    push    rbx
    mov     rcx, [rip+pie_items]
    mov     rbx, [rcx+rax*8]
    call    pie_close
    mov     rdi, rbx
    call    run_op_ui
    mov     eax, 1
    pop     rbx
    ret

# pie_hit(edi=x, esi=y) -> eax = the choice in that direction, -1 at the centre
pie_hit:
    push    rbx
    push    r12
    sub     edi, [rip+pie_cx]
    sub     esi, [rip+pie_cy]
    mov     eax, edi
    imul    eax, eax
    mov     ecx, esi
    imul    ecx, ecx
    add     eax, ecx
    cmp     eax, PIE_DEAD*PIE_DEAD
    jge     1f
    mov     eax, -1
    jmp     9f
1:  mov     ebx, -1                     # the choice whose direction is closest
    mov     r12d, 0x80000000            # (largest dot product)
    xor     ecx, ecx
2:  cmp     ecx, [rip+pie_n]
    jae     8f
    lea     rax, [rip+pie_dir]
    movsx   edx, byte ptr [rax+rcx*2]
    movsx   r8d, byte ptr [rax+rcx*2+1]
    imul    edx, edi
    imul    r8d, esi
    add     edx, r8d
    lea     rax, [rip+pie_diag]         # (diagonals are longer: scale back)
    movzx   r8d, byte ptr [rax+rcx]
    imul    edx, r8d
    cmp     edx, r12d
    jle     3f
    mov     r12d, edx
    mov     ebx, ecx
3:  inc     ecx
    jmp     2b
8:  mov     eax, ebx
9:  pop     r12
    pop     rbx
    ret

# pie_hover(edi=x, esi=y) - the choice under the pointer lights up
pie_hover:
    sub     rsp, 8
    call    pie_hit
    add     rsp, 8
    cmp     eax, [rip+pie_sel]
    je      1f
    mov     [rip+pie_sel], eax
1:  mov     dword ptr [rip+dirty], 1    # (the pointer line follows)
    ret

# pie_press(edi=button) - LMB picks the lit choice, any other closes it
pie_press:
    cmp     edi, BTN_LEFT
    jne     pie_close
    mov     eax, [rip+pie_sel]
    test    eax, eax
    js      pie_close
    jmp     pie_run

# pie_draw - a ring at the centre, a line to the pointer, the choices
pie_draw:
    cmp     dword ptr [rip+pie_on], 0
    je      9f
    push    rbx
    push    r12
    push    r13
    mov     edi, [rip+pie_cx]
    mov     esi, [rip+pie_cy]
    mov     edx, 12
    mov     r8d, COL_DROP_BORDER
    call    fill_circle
    mov     edi, [rip+pie_cx]
    mov     esi, [rip+pie_cy]
    mov     edx, 10
    mov     r8d, COL_DROP_BG
    call    fill_circle
    cmp     dword ptr [rip+pie_sel], 0
    jl      1f
    mov     edi, [rip+pie_cx]
    mov     esi, [rip+pie_cy]
    mov     edx, [rip+ptr_x]
    mov     ecx, [rip+ptr_y]
    mov     r8d, COL_ACCENT
    call    draw_line_aa
1:  xor     ebx, ebx
2:  cmp     ebx, [rip+pie_n]
    jae     8f
    lea     rax, [rip+pie_bx]
    mov     edi, [rax+rbx*4]
    lea     rax, [rip+pie_by]
    mov     esi, [rax+rbx*4]
    lea     rax, [rip+pie_bw]
    mov     edx, [rax+rbx*4]
    mov     ecx, MENU_ITEM_H
    mov     r8d, COL_DROP_BORDER
    cmp     ebx, [rip+pie_sel]
    jne     3f
    mov     r8d, COL_ACCENT
3:  call    popup_frame
    lea     rax, [rip+pie_bx]
    mov     edi, [rax+rbx*4]
    add     edi, 14
    lea     rax, [rip+pie_by]
    mov     esi, [rax+rbx*4]
    add     esi, 4
    mov     rax, [rip+pie_items]
    mov     rax, [rax+rbx*8]
    mov     rdx, [rax+OP_LABEL]
    mov     ecx, COL_TEXT
    cmp     ebx, [rip+pie_sel]
    jne     4f
    mov     ecx, COL_ACCENT
4:  call    draw_text
    inc     ebx
    jmp     2b
8:  pop     r13
    pop     r12
    pop     rbx
9:  ret

.section .note.GNU-stack,"",@progbits
