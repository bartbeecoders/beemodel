# =============================================================================
#  BeeModel - workspaces: named layouts of areas (the area tree, which area
#  is active, the viewports' cameras, the Properties tab), shown as tabs in
#  the menu bar: Modeling, Sculpt, CAD, Shading, Animation, World, and
#  custom ones (+). Ctrl+PageUp / PageDown switch. They are kept in .bee
#  files (WSPC) and in ~/.config/beemodel/workspaces (the last ones used,
#  for a new scene).
#
#  Areas are also joined by dragging an area's top-left corner into its
#  neighbour, and swapped by dragging one's header onto another.
# =============================================================================
.intel_syntax noprefix
.include "const.inc"
.include "macros.inc"
.include "widgets.inc"
.include "icons.inc"

.globl wsp_init
.globl wsp_tabs_draw
.globl wsp_write
.globl wsp_ai
.globl wsp_read
.globl wsp_persist
.globl wsp_area_drop
.globl wsp_drag_src
.globl wsp_drag_kind

.equ MAX_NODES, 32                      # (areas.s)
.equ N_SZ,      32
.equ N_KIND,    0
.equ N_ED,      1
.equ N_PARENT,  2
.equ N_A,       8
.equ N_B,       9
.equ K_LEAF,    1
.equ K_HSPLIT,  2
.equ K_VSPLIT,  3
.equ NO_NODE,   0xff
.equ CAM_SZ,    24
.equ WS_MAX,    12
.equ WS_SZ,     2048
.equ WS_NAME,   0                       # 24
.equ WS_ROOT,   24
.equ WS_ACT,    28
.equ WS_VP,     32
.equ WS_MAXED,  36
.equ WS_PTAB,   40
.equ WS_NODES,  64                      # MAX_NODES x N_SZ
.equ WS_CAMS,   WS_NODES+MAX_NODES*N_SZ # MAX_NODES x CAM_SZ
.equ WS_FILE,   WS_CAMS+MAX_NODES*CAM_SZ

.macro NODE kind, ed, parent, ratio, a, b
    .byte \kind, \ed, \parent, 0
    .long \ratio
    .byte \a, \b, 0, 0
    .long 0, 0, 0, 0, 0
.endm

.section .bss
.align 8
wsp_tab:        .skip WS_MAX*WS_SZ
wsp_n:          .skip 4
wsp_cur:        .skip 4
wsp_drag_src:   .skip 4                 # an area dragged (its header / corner)
wsp_drag_kind:  .skip 4                 # 0 swap, 1 join
wsp_path:       .skip 512
wsp_name:       .skip 32
wsp_sel:        .skip 4
.align 8
wsp_fbuf:       .skip 8+WS_MAX*WS_FILE

.section .rodata
s_cfgdir:       .asciz "/.config/beemodel"
s_wfile:        .asciz "/workspaces"
n_model:        .asciz "Modeling"
n_sculpt:       .asciz "Sculpt"
n_cad:          .asciz "CAD"
n_shading:      .asciz "Shading"
n_anim:         .asciz "Animation"
n_world:        .asciz "World"
n_custom:       .asciz "Custom"
n_ai:           .asciz "AI"
s_ws_full:      .asciz "  12 workspaces at most"
s_ws_last:      .asciz "  the last workspace cannot go"
s_ws_bad:       .asciz "  workspace.set <number from 1 | name>"
s_no_join:      .asciz "  only two areas side by side (or stacked) join"
.align 8
# the built-in layouts: name, nodes, root, the Properties tab
presets:        .quad n_model, 0, 0
                .quad n_sculpt, lay_sculpt, 0
                .quad n_cad, lay_cad, 4
                .quad n_shading, lay_shading, 2
                .quad n_anim, lay_anim, 8
                .quad n_world, lay_world, 5, 0
# Sculpt: tools | viewport
lay_sculpt:
    NODE K_HSPLIT, 0,           NO_NODE, 10794, 1, 2
    NODE K_LEAF,   ED_TOOLS,    0,       0,     0, 0
    NODE K_LEAF,   ED_VIEWPORT, 0,       0,     0, 0
    .long -1
# CAD: tools | viewport | (outliner / properties)
lay_cad:
    NODE K_HSPLIT, 0,           NO_NODE, 10794, 1, 2
    NODE K_LEAF,   ED_TOOLS,    0,       0,     0, 0
    NODE K_HSPLIT, 0,           0,       45000, 3, 4
    NODE K_LEAF,   ED_VIEWPORT, 2,       0,     0, 0
    NODE K_VSPLIT, 0,           2,       14000, 5, 6
    NODE K_LEAF,   ED_OUTLINER, 4,       0,     0, 0
    NODE K_LEAF,   ED_PROPS,    4,       0,     0, 0
    .long -1
# Shading: (viewport / node editor) | properties
lay_shading:
    NODE K_HSPLIT, 0,           NO_NODE, 50000, 1, 2
    NODE K_VSPLIT, 0,           0,       36000, 3, 4
    NODE K_LEAF,   ED_PROPS,    0,       0,     0, 0
    NODE K_LEAF,   ED_VIEWPORT, 1,       0,     0, 0
    NODE K_LEAF,   ED_NODES,    1,       0,     0, 0
    .long -1
# Animation: (viewport / (dope sheet / timeline)) | properties
lay_anim:
    NODE K_HSPLIT, 0,           NO_NODE, 50000, 1, 2
    NODE K_VSPLIT, 0,           0,       40000, 3, 4
    NODE K_LEAF,   ED_PROPS,    0,       0,     0, 0
    NODE K_LEAF,   ED_VIEWPORT, 1,       0,     0, 0
    NODE K_VSPLIT, 0,           1,       45000, 5, 6
    NODE K_LEAF,   ED_DOPESHEET, 4,      0,     0, 0
    NODE K_LEAF,   ED_TIMELINE, 4,       0,     0, 0
    .long -1
# World: (viewport / asset browser) | properties
lay_world:
    NODE K_HSPLIT, 0,           NO_NODE, 50000, 1, 2
    NODE K_VSPLIT, 0,           0,       44000, 3, 4
    NODE K_LEAF,   ED_PROPS,    0,       0,     0, 0
    NODE K_LEAF,   ED_VIEWPORT, 1,       0,     0, 0
    NODE K_LEAF,   ED_ASSETS,   1,       0,     0, 0
    .long -1
# AI (made by ai.mode): viewport | (AI Assistant / outliner)
lay_ai:
    NODE K_HSPLIT, 0,           NO_NODE, 40000, 1, 2
    NODE K_LEAF,   ED_VIEWPORT, 0,       0,     0, 0
    NODE K_VSPLIT, 0,           0,       47000, 3, 4
    NODE K_LEAF,   ED_AI,       2,       0,     0, 0
    NODE K_LEAF,   ED_OUTLINER, 2,       0,     0, 0
    .long -1

.text
OPERATOR op_ws_next, "workspace.next", "Next Workspace", do_ws_step, arg=1, key=KEY_PAGEDOWN|KM_CTRL, flags=OPF_QUIET|OPF_AI_SAFE, doc="The workspace to the right (Ctrl+PageDown)"
OPERATOR op_ws_prev, "workspace.prev", "Previous Workspace", do_ws_step, arg=-1, key=KEY_PAGEUP|KM_CTRL, flags=OPF_QUIET|OPF_AI_SAFE, doc="The workspace to the left (Ctrl+PageUp)"
OPERATOR op_ws_new, "workspace.new", "New Workspace", do_ws_new, flags=OPF_QUIET|OPF_AI_SAFE, doc="A new workspace: a copy of this one's layout (workspace.new [name])"
OPERATOR op_ws_set, "workspace.set", "Workspace", do_ws_set, flags=OPF_QUIET|OPF_AI_SAFE, doc="Switch to a workspace: workspace.set <number from 1 | name>"
OPERATOR op_ws_rename, "workspace.rename", "Rename Workspace...", do_ws_rename, flags=OPF_QUIET|OPF_AI_SAFE, form=form_wsname, doc="Rename this workspace: workspace.rename <name>"
OPERATOR op_ws_delete, "workspace.delete", "Delete Workspace", do_ws_delete, flags=OPF_QUIET|OPF_AI_SAFE, doc="Remove this workspace (not the last one)"

# ---- records ----------------------------------------------------------------------
wsp_rec:                                # edi = index -> rax
    imul    eax, edi, WS_SZ
    lea     rcx, [rip+wsp_tab]
    add     rax, rcx
    ret

# wsp_take(edi=index) - the layout in use into that record
wsp_take:
    push    rbx
    call    wsp_rec
    mov     rbx, rax
    mov     eax, [rip+area_root]
    mov     [rbx+WS_ROOT], eax
    mov     eax, [rip+active_area]
    mov     [rbx+WS_ACT], eax
    mov     eax, [rip+vp_area]
    mov     [rbx+WS_VP], eax
    mov     eax, [rip+area_maxed]
    mov     [rbx+WS_MAXED], eax
    mov     eax, [rip+props_tab]
    mov     [rbx+WS_PTAB], eax
    lea     rsi, [rip+nodes]
    lea     rdi, [rbx+WS_NODES]
    mov     ecx, MAX_NODES*N_SZ
    rep     movsb
    lea     rsi, [rip+area_cams]
    lea     rdi, [rbx+WS_CAMS]
    mov     ecx, MAX_NODES*CAM_SZ
    rep     movsb
    pop     rbx
    ret

# wsp_give(edi=index) - that record becomes the layout in use
wsp_give:
    push    rbx
    call    wsp_rec
    mov     rbx, rax
    mov     eax, [rbx+WS_ROOT]
    mov     [rip+area_root], eax
    mov     eax, [rbx+WS_ACT]
    mov     [rip+active_area], eax
    mov     eax, [rbx+WS_VP]
    mov     [rip+vp_area], eax
    mov     eax, [rbx+WS_MAXED]
    mov     [rip+area_maxed], eax
    mov     eax, [rbx+WS_PTAB]
    mov     [rip+props_tab], eax
    lea     rsi, [rbx+WS_NODES]
    lea     rdi, [rip+nodes]
    mov     ecx, MAX_NODES*N_SZ
    rep     movsb
    lea     rsi, [rbx+WS_CAMS]
    lea     rdi, [rip+area_cams]
    mov     ecx, MAX_NODES*CAM_SZ
    rep     movsb
    mov     dword ptr [rip+dirty], 1
    pop     rbx
    ret

# wsp_init - the workspaces of the last session, or the built-in ones
wsp_init:
    push    rbx
    push    r12
    push    r13
    call    wsp_load_file
    test    eax, eax
    jnz     9f
    xor     ebx, ebx                    # the built-in ones
    lea     r12, [rip+presets]
1:  mov     rax, [r12]
    test    rax, rax
    jz      8f
    mov     edi, ebx
    call    wsp_take                    # (from the default layout, its cameras)
    mov     edi, ebx
    call    wsp_rec
    mov     r13, rax
    lea     rdi, [r13+WS_NAME]
    mov     rsi, [r12]
    call    wcpy
    mov     rsi, [r12+8]                # its nodes (none: the default's)
    test    rsi, rsi
    jz      4f
    lea     rdi, [r13+WS_NODES]         # (the rest emptied)
    xor     eax, eax
    mov     ecx, MAX_NODES*N_SZ
    rep     stosb
    lea     rdi, [r13+WS_NODES]
    xor     ecx, ecx
2:  cmp     dword ptr [rsi], -1
    je      3f
    mov     rax, [rsi]                  # 32 bytes a node
    mov     [rdi], rax
    mov     rax, [rsi+8]
    mov     [rdi+8], rax
    mov     rax, [rsi+16]
    mov     [rdi+16], rax
    mov     rax, [rsi+24]
    mov     [rdi+24], rax
    add     rsi, N_SZ
    add     rdi, N_SZ
    inc     ecx
    jmp     2b
3:  mov     dword ptr [r13+WS_ROOT], 0
    mov     dword ptr [r13+WS_MAXED], -1
    lea     rdi, [r13+WS_NODES]         # the active area: its viewport
    xor     ecx, ecx
31: cmp     byte ptr [rdi+N_KIND], K_LEAF
    jne     32f
    cmp     byte ptr [rdi+N_ED], ED_VIEWPORT
    je      33f
32: add     rdi, N_SZ
    inc     ecx
    cmp     ecx, MAX_NODES
    jb      31b
    xor     ecx, ecx
33: mov     [r13+WS_ACT], ecx
    mov     [r13+WS_VP], ecx
4:  mov     rax, [r12+16]
    mov     [r13+WS_PTAB], eax
    inc     ebx
    add     r12, 24
    jmp     1b
8:  mov     [rip+wsp_n], ebx
    mov     dword ptr [rip+wsp_cur], 0
9:  pop     r13
    pop     r12
    pop     rbx
    ret

# wsp_switch(edi=index) - keep this one's layout, show that one
wsp_switch:
    push    rbx
    mov     ebx, edi
    cmp     ebx, [rip+wsp_n]
    jae     9f
    cmp     ebx, [rip+wsp_cur]
    je      9f
    mov     edi, [rip+wsp_cur]
    call    wsp_take
    mov     [rip+wsp_cur], ebx
    mov     edi, ebx
    call    wsp_give
    call    wsp_persist
9:  pop     rbx
    ret

# wsp_ai - the AI workspace shown (made the first time: a viewport, the AI
#   Assistant and the outliner)
wsp_ai:
    push    rbx
    push    r12
    sub     rsp, 8
    xor     ebx, ebx                    # there already?
1:  cmp     ebx, [rip+wsp_n]
    jae     2f
    mov     edi, ebx
    call    wsp_rec
    lea     rdi, [rax+WS_NAME]
    lea     rsi, [rip+n_ai]
    call    str_eq
    test    eax, eax
    jnz     8f
    inc     ebx
    jmp     1b
2:  cmp     ebx, WS_MAX
    jae     9f
    mov     edi, [rip+wsp_cur]          # this one kept, copied (its cameras)
    call    wsp_take
    mov     edi, [rip+wsp_cur]
    call    wsp_rec
    mov     r12, rax
    mov     edi, ebx
    call    wsp_rec
    mov     rdi, rax
    mov     rsi, r12
    mov     ecx, WS_SZ
    rep     movsb
    mov     edi, ebx
    call    wsp_rec
    mov     r12, rax
    lea     rdi, [r12+WS_NAME]
    lea     rsi, [rip+n_ai]
    call    wcpy
    lea     rdi, [r12+WS_NODES]         # its layout
    xor     eax, eax
    mov     ecx, MAX_NODES*N_SZ
    rep     stosb
    lea     rdi, [r12+WS_NODES]
    lea     rsi, [rip+lay_ai]
3:  cmp     dword ptr [rsi], -1
    je      4f
    mov     ecx, N_SZ
    rep     movsb
    jmp     3b
4:  mov     dword ptr [r12+WS_ROOT], 0
    mov     dword ptr [r12+WS_MAXED], -1
    mov     dword ptr [r12+WS_ACT], 3   # (the AI Assistant)
    mov     dword ptr [r12+WS_VP], 1
    inc     dword ptr [rip+wsp_n]
    mov     [rip+wsp_cur], ebx          # (this one was just kept)
    mov     edi, ebx
    call    wsp_give
    call    wsp_persist
    mov     dword ptr [rip+dirty], 1
    jmp     9f
8:  mov     edi, ebx
    call    wsp_switch
9:  add     rsp, 8
    pop     r12
    pop     rbx
    ret

# ---- operators ----------------------------------------------------------------------
do_ws_step:                             # rdi = +1 / -1
    mov     eax, [rip+wsp_cur]
    add     eax, edi
    jns     1f
    mov     eax, [rip+wsp_n]
    dec     eax
1:  cmp     eax, [rip+wsp_n]
    jb      2f
    xor     eax, eax
2:  mov     edi, eax
    jmp     wsp_switch

do_ws_new:
    push    rbx
    mov     ebx, [rip+wsp_n]
    cmp     ebx, WS_MAX
    jae     8f
    mov     edi, [rip+wsp_cur]          # a copy of this one, after it all
    call    wsp_take
    mov     edi, [rip+wsp_cur]
    call    wsp_rec
    mov     rsi, rax
    mov     edi, ebx
    call    wsp_rec
    mov     rdi, rax
    mov     ecx, WS_SZ
    rep     movsb
    mov     edi, ebx                    # its name: the argument, or Custom n
    call    wsp_rec
    lea     rdi, [rax+WS_NAME]
    mov     rsi, [rip+op_arg]
    test    rsi, rsi
    jz      1f
    cmp     byte ptr [rsi], 0
    jne     2f
1:  push    rdi
    call    fmt_reset
    lea     rdi, [rip+n_custom]
    call    fmt_str
    mov     edi, ' '
    call    fmt_char
    lea     edi, [rbx-5]
    call    fmt_int
    pop     rdi
    lea     rsi, [rip+fmt_buf]
2:  call    wcpy
    inc     dword ptr [rip+wsp_n]
    mov     [rip+wsp_cur], ebx
    call    wsp_persist
    mov     dword ptr [rip+dirty], 1
    pop     rbx
    ret
8:  lea     rdi, [rip+s_ws_full]
    call    log_line
    pop     rbx
    ret

do_ws_set:                              # a number from 1, or a name
    push    rbx
    mov     rsi, [rip+op_arg]
    test    rsi, rsi
    jz      8f
    movzx   eax, byte ptr [rsi]
    sub     eax, '1'
    cmp     eax, 8
    ja      3f
    mov     edi, eax
    cmp     byte ptr [rsi+1], 0
    jne     3f
    call    wsp_switch
    pop     rbx
    ret
3:  xor     ebx, ebx                    # by name
4:  cmp     ebx, [rip+wsp_n]
    jae     8f
    mov     edi, ebx
    call    wsp_rec
    lea     rdi, [rax+WS_NAME]
    mov     rsi, [rip+op_arg]
    call    str_eq
    test    eax, eax
    jnz     5f
    inc     ebx
    jmp     4b
5:  mov     edi, ebx
    call    wsp_switch
    pop     rbx
    ret
8:  lea     rdi, [rip+s_ws_bad]
    call    log_line
    pop     rbx
    ret

do_ws_rename:
    sub     rsp, 8
    mov     rsi, [rip+op_arg]
    test    rsi, rsi
    jz      9f
    cmp     byte ptr [rsi], 0
    je      9f
    mov     edi, [rip+wsp_cur]
    call    wsp_rec
    lea     rdi, [rax+WS_NAME]
    mov     rsi, [rip+op_arg]
    call    wcpy
    call    wsp_persist
    mov     dword ptr [rip+dirty], 1
9:  add     rsp, 8
    ret

do_ws_delete:
    push    rbx
    cmp     dword ptr [rip+wsp_n], 1
    jbe     8f
    mov     ebx, [rip+wsp_cur]          # the later ones move down
    mov     edi, ebx
    call    wsp_rec
    mov     rdi, rax
    lea     rsi, [rax+WS_SZ]
    mov     ecx, [rip+wsp_n]
    sub     ecx, ebx
    dec     ecx
    imul    ecx, ecx, WS_SZ
    rep     movsb
    dec     dword ptr [rip+wsp_n]
    mov     eax, [rip+wsp_n]            # show the one now in its place
    cmp     ebx, eax
    jb      1f
    lea     ebx, [rax-1]
1:  mov     [rip+wsp_cur], ebx
    mov     edi, ebx
    call    wsp_give
    call    wsp_persist
    pop     rbx
    ret
8:  lea     rdi, [rip+s_ws_last]
    call    log_line
    pop     rbx
    ret

# ---- the tabs in the menu bar ------------------------------------------------------------
WIDGET wd_wsp_tab, WK_ROW, "workspace.tab", cb=tab_cb, tip="Switch workspace (Ctrl+PageUp / PageDown)"
WIDGET wd_wsp_add, WK_BUTTON, "workspace.add", flags=WGF_ICON|WGF_COMPACT, aux=op_ws_new, n=ICON_PLUS, tip="A new workspace from this layout"

# wsp_tabs_draw - after the menus in the menu bar (a tab a workspace, +)
wsp_tabs_draw:
    push    rbx
    push    r12
    push    r13
    lea     rax, [rip+menu_x]
    mov     r12d, [rax+NUM_MENUS*4]
    add     r12d, 24
    xor     ebx, ebx
1:  cmp     ebx, [rip+wsp_n]
    jae     3f
    mov     edi, ebx
    call    wsp_rec
    lea     r13, [rax+WS_NAME]
    mov     rdi, r13
    call    text_width
    lea     ecx, [rax+20]
    mov     eax, [rip+win_w]
    sub     eax, 60
    lea     edx, [r12+rcx]
    cmp     edx, eax
    jg      3f
    push    rcx
    push    rcx
    lea     rdi, [rip+wd_wsp_tab]
    mov     esi, r12d
    mov     edx, TITLE_H+1
    mov     eax, [rip+wsp_cur]          # (the rows' own copy: a click sets it
    mov     [rip+wsp_sel], eax          #  before the switch keeps this layout)
    lea     r8, [rip+wsp_sel]
    mov     r9d, ebx
    call    wg
    mov     rdi, r13
    call    wg_set_label
    lea     edi, [r12+10]
    mov     esi, TITLE_H+4
    mov     rdx, r13
    mov     ecx, COL_TEXT
    cmp     ebx, [rip+wsp_cur]
    jne     2f
    mov     ecx, COL_ACCENT
2:  call    draw_text
    pop     rcx
    pop     rcx
    lea     r12d, [r12+rcx+2]
    inc     ebx
    jmp     1b
3:  lea     rdi, [rip+wd_wsp_add]
    mov     esi, r12d
    mov     edx, TITLE_H+3
    mov     ecx, 20
    xor     r8d, r8d
    xor     r9d, r9d
    call    wg
    pop     r13
    pop     r12
    pop     rbx
    ret

tab_cb:                                 # a tab: esi = which
    mov     edi, esi
    jmp     wsp_switch

# ---- files ----------------------------------------------------------------------------
# WSPC: the count, the current one, the records (the one in use taken first)
wsp_write:
    push    rbx
    sub     rsp, 16
    mov     edi, [rip+wsp_cur]
    call    wsp_take
    mov     edi, [rip+wsp_n]
    call    wb_u32
    mov     edi, [rip+wsp_cur]
    call    wb_u32
    xor     ebx, ebx                    # (each record's first WS_FILE bytes)
1:  cmp     ebx, [rip+wsp_n]
    jae     9f
    mov     edi, ebx
    call    wsp_rec
    mov     rsi, rax
    mov     edx, WS_FILE
    call    wb_bytes
    inc     ebx
    jmp     1b
9:  add     rsp, 16
    pop     rbx
    ret

# wsp_read(rdi=chunk, esi=size) - the workspaces of a .bee file
wsp_read:
    push    rbx
    push    r12
    push    r13
    mov     rbx, rdi
    mov     r12d, esi
    cmp     r12d, 8
    jb      9f
    mov     r13d, [rbx]
    test    r13d, r13d
    jz      9f
    cmp     r13d, WS_MAX
    ja      9f
    imul    eax, r13d, WS_FILE
    add     eax, 8
    cmp     eax, r12d
    ja      9f
    mov     [rip+wsp_n], r13d
    mov     eax, [rbx+4]
    cmp     eax, r13d
    jb      1f
    xor     eax, eax
1:  mov     [rip+wsp_cur], eax
    lea     r12, [rbx+8]
    xor     ebx, ebx
2:  cmp     ebx, r13d
    jae     3f
    mov     edi, ebx
    call    wsp_rec
    mov     rdi, rax
    mov     rsi, r12
    mov     ecx, WS_FILE
    rep     movsb
    add     r12, WS_FILE
    inc     ebx
    jmp     2b
3:  mov     edi, [rip+wsp_cur]
    call    wsp_give
9:  pop     r13
    pop     r12
    pop     rbx
    ret

# wsp_persist - ~/.config/beemodel/workspaces (the same bytes as WSPC)
wsp_persist:
    push    rbx
    push    r12
    sub     rsp, 8
    mov     edi, [rip+wsp_cur]
    call    wsp_take
    call    wsp_cfg
    mov     ebx, [rip+wsp_n]            # count, current, the records
    imul    ebx, ebx, WS_FILE
    add     ebx, 8
    lea     r12, [rip+wsp_fbuf]
    mov     eax, [rip+wsp_n]
    mov     [r12], eax
    mov     eax, [rip+wsp_cur]
    mov     [r12+4], eax
    lea     rdi, [r12+8]
    xor     ecx, ecx
1:  cmp     ecx, [rip+wsp_n]
    jae     2f
    push    rcx
    push    rdi
    mov     edi, ecx
    call    wsp_rec
    pop     rdi
    pop     rcx
    mov     rsi, rax
    push    rcx
    mov     ecx, WS_FILE
    rep     movsb
    pop     rcx
    inc     ecx
    jmp     1b
2:  lea     rdi, [rip+wsp_path]
    mov     rsi, r12
    mov     edx, ebx
    call    file_write_atomic
9:  add     rsp, 8
    pop     r12
    pop     rbx
    ret

# wsp_load_file -> eax = 1 when the last session's workspaces were read
wsp_load_file:
    push    rbx
    push    r12
    sub     rsp, 8
    call    wsp_cfg
    lea     rdi, [rip+wsp_path]
    call    file_read
    test    rax, rax
    jz      8f
    mov     rbx, rax
    mov     r12, rdx
    mov     rdi, rax
    mov     esi, edx
    call    wsp_read
    mov     rdi, rbx
    mov     rsi, r12
    call    file_unmap
    xor     eax, eax
    cmp     dword ptr [rip+wsp_n], 0
    setne   al
    jmp     9f
8:  xor     eax, eax
9:  add     rsp, 8
    pop     r12
    pop     rbx
    ret

wsp_cfg:                                # -> wsp_path
    sub     rsp, 8
    lea     rdi, [rip+s_cfgdir]
    call    home_join
    lea     rdi, [rip+wsp_path]
    mov     rsi, rax
    call    wcpy
    lea     rsi, [rip+s_wfile]
    call    wcpy
    add     rsp, 8
    ret

wcpy:                                   # rdi = dest, rsi = text -> rdi at its 0 (23 max for names)
1:  mov     al, [rsi]
    mov     [rdi], al
    test    al, al
    jz      2f
    inc     rsi
    inc     rdi
    jmp     1b
2:  ret

# =============================================================================
#  Joining and swapping areas by dragging
# =============================================================================
# wsp_area_drop(edi=x, esi=y) - the drag ends over another area: swap the
#   two (a header was dragged) or join them (a corner: the other one goes
#   when it is this one's sibling)
wsp_area_drop:
    push    rbx
    push    r12
    sub     rsp, 8
    call    area_hit
    mov     ebx, [rip+hit_area]         # the area under the pointer
    mov     r12d, [rip+wsp_drag_src]
    test    ebx, ebx
    js      9f
    cmp     ebx, r12d
    je      9f
    mov     edi, r12d
    call    node_ptr
    cmp     byte ptr [rax+N_KIND], K_LEAF
    jne     9f
    mov     rdx, rax
    push    rdx
    mov     edi, ebx
    call    node_ptr
    pop     rdx
    cmp     byte ptr [rax+N_KIND], K_LEAF
    jne     9f
    cmp     dword ptr [rip+wsp_drag_kind], 1
    je      .Ldrop_join
    mov     cl, [rdx+N_ED]              # swap: the editors and the cameras
    mov     ch, [rax+N_ED]
    mov     [rdx+N_ED], ch
    mov     [rax+N_ED], cl
    mov     edi, r12d
    call    cam_ptr
    push    rax
    mov     edi, ebx
    call    cam_ptr
    pop     rdx
    mov     ecx, CAM_SZ
1:  mov     r8b, [rax]
    mov     r9b, [rdx]
    mov     [rax], r9b
    mov     [rdx], r8b
    inc     rax
    inc     rdx
    dec     ecx
    jnz     1b
    mov     [rip+active_area], ebx
    jmp     8f
.Ldrop_join:                            # join: the other one must be the sibling
    mov     cl, [rdx+N_PARENT]
    cmp     cl, [rax+N_PARENT]
    je      2f
    lea     rdi, [rip+s_no_join]
    call    log_line
    jmp     9f
2:  mov     edi, ebx
    call    close_leaf
    mov     dword ptr [rip+area_maxed], -1
8:  mov     dword ptr [rip+dirty], 1
    call    area_layout
9:  add     rsp, 8
    pop     r12
    pop     rbx
    ret

.section .note.GNU-stack,"",@progbits
