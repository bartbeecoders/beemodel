# =============================================================================
#  BeeModel - area system (Blender-style): the content region is a binary
#  tree of splits; every leaf is an "area" hosting one editor (3D Viewport,
#  Tools, Outliner, Properties, Console). Areas can be split, closed, resized,
#  maximized and switched to another editor from their header. Every 3D
#  Viewport area keeps its own camera.
# =============================================================================
.intel_syntax noprefix
.include "const.inc"
.include "macros.inc"

# exports
.globl ed_node
.globl area_layout
.globl area_hit
.globl area_draw_all
.globl area_drag
.globl area_node_rect
.globl cam_load
.globl cam_store
.globl area_init
.globl area_root
.globl area_maxed
.globl active_area
.globl vp_area
.globl hit_area
.globl drag_node
.globl ed_x
.globl ed_y
.globl ed_w
.globl ed_h
.globl items_area
.globl splitter_cursor
.globl console_ensure
.globl area_editor
.globl area_btn_ops

# node layout (32 bytes)
.equ N_KIND,    0
.equ N_ED,      1
.equ N_PARENT,  2
.equ N_RATIO,   4                       # share of child a, 16.16
.equ N_A,       8
.equ N_B,       9
.equ N_X,       12
.equ N_Y,       16
.equ N_W,       20
.equ N_H,       24
.equ N_SZ,      32
.equ K_LEAF,    1
.equ K_HSPLIT,  2                       # a | b  (side by side)
.equ K_VSPLIT,  3                       # a / b  (stacked)
.equ MAX_NODES, 32
.equ NO_NODE,   0xff
.equ MIN_AREA,  60
.equ HDR_BTN_W, 22
.equ TYPE_BTN_W, 130
.equ CAM_SZ,    24

.macro NODE kind, ed, parent, ratio, a, b
    .byte \kind, \ed, \parent, 0
    .long \ratio
    .byte \a, \b, 0, 0
    .long 0, 0, 0, 0, 0
.endm

.section .data
.align 8
# default layout:  tools | ( (viewport / console) | (outliner / properties) )
nodes:
    NODE K_HSPLIT, 0,           NO_NODE, 10794, 1, 2   # 0 root: tools | rest
    NODE K_LEAF,   ED_TOOLS,    0,       0,     0, 0   # 1
    NODE K_HSPLIT, 0,           0,       49461, 3, 4   # 2 centre | sidebar
    NODE K_VSPLIT, 0,           2,       51826, 5, 6   # 3 viewport / console
    NODE K_VSPLIT, 0,           2,       10420, 7, 8   # 4 outliner / properties
    NODE K_LEAF,   ED_VIEWPORT, 3,       0,     0, 0   # 5
    NODE K_LEAF,   ED_CONSOLE,  3,       0,     0, 0   # 6
    NODE K_LEAF,   ED_OUTLINER, 4,       0,     0, 0   # 7
    NODE K_LEAF,   ED_PROPS,    4,       0,     0, 0   # 8
    .skip (MAX_NODES-9)*N_SZ
area_root:      .long 0
area_maxed:     .long -1
active_area:    .long 5
vp_area:        .long 5                 # viewport whose camera Properties shows

.section .bss
.align 8
area_cams:      .skip MAX_NODES*CAM_SZ
ed_x:           .skip 4
ed_y:           .skip 4
ed_w:           .skip 4
ed_h:           .skip 4
ed_node:        .skip 4
hit_area:       .skip 4
drag_node:      .skip 4

.section .rodata
s_ed_viewport:  .asciz "3D Viewport"
s_ed_tools:     .asciz "Tools"
s_ed_outliner:  .asciz "Outliner"
s_ed_props:     .asciz "Properties"
s_ed_console:   .asciz "Console"
s_ed_activity:  .asciz "AI Activity"
s_h_create:     .asciz "CREATE"
s_p_camera:     .asciz "Viewport camera"
s_p_yaw:        .asciz "Yaw"
s_p_pitch:      .asciz "Pitch"
s_p_dist:       .asciz "Distance"
s_p_target:     .asciz "Target"
s_p_canvas:     .asciz "Canvas"
s_p_grid:       .asciz "Grid"
s_p_areas:      .asciz "Areas"
s_p_loc:        .asciz "Location"
s_p_rot:        .asciz "Rotation"
s_p_scale:      .asciz "Scale"
s_p_mesh:       .asciz "Mesh"
s_no_active:    .asciz "No active object"
s_v:            .asciz " v, "
s_e:            .asciz " e, "
s_f:            .asciz " f"
s_on:           .asciz "on"
s_off:          .asciz "off"
s_deg:          .asciz " deg"
s_comma:        .asciz ", "
s_xx:           .asciz " x "
s_last_area:    .asciz "  the last area cannot be closed"
s_no_room:      .asciz "  no room for more areas"
.align 8
editor_names:   .quad s_ed_viewport, s_ed_tools, s_ed_outliner, s_ed_props, s_ed_console, s_ed_activity
editor_draw:    .quad ed_viewport_draw, ed_tools_draw, ed_outliner_draw, ed_props_draw, ed_console_draw, ed_activity_draw
area_btn_ops:   .quad op_area_close, op_area_split_stack, op_area_split_side, op_area_maximize
items_area:     .quad op_area_type_vp, op_area_type_tools, op_area_type_outl
                .quad op_area_type_props, op_area_type_console, op_area_type_activity

# ---- operators ------------------------------------------------------------------
OPERATOR op_area_split_side,  "area.split_side",  "Split Area Side by Side", op_area_split, arg=K_HSPLIT, doc="Split the active area into two side by side"
OPERATOR op_area_split_stack, "area.split_stack", "Split Area Top/Bottom",   op_area_split, arg=K_VSPLIT, doc="Split the active area into two stacked areas"
OPERATOR op_area_close,       "area.close",       "Close Area",              op_area_close_x, doc="Close the active area; its neighbour takes the space"
OPERATOR op_area_maximize,    "area.maximize",    "Maximize Area",           op_area_max, op_check_maxed, key=KEY_SPACE|KM_CTRL, doc="Toggle the active area filling the window"
OPERATOR op_area_type_vp,     "area.type_viewport",   "3D Viewport", op_area_type, op_check_area_type, ED_VIEWPORT, doc="Show the 3D viewport in the active area"
OPERATOR op_area_type_tools,  "area.type_tools",      "Tools",       op_area_type, op_check_area_type, ED_TOOLS,    doc="Show the tools in the active area"
OPERATOR op_area_type_outl,   "area.type_outliner",   "Outliner",    op_area_type, op_check_area_type, ED_OUTLINER, doc="Show the outliner in the active area"
OPERATOR op_area_type_props,  "area.type_properties", "Properties",  op_area_type, op_check_area_type, ED_PROPS,    doc="Show the properties in the active area"
OPERATOR op_area_type_console,"area.type_console",    "Console",     op_area_type, op_check_area_type, ED_CONSOLE,  doc="Show the console in the active area"
OPERATOR op_area_type_activity,"area.type_activity", "AI Activity", op_area_type, op_check_area_type, ED_ACTIVITY, doc="Show what AI agents did in the active area"
OPERATOR op_view_activity, "view.toggle_activity", "AI Activity Pane", op_toggle_activity, op_has_editor, ED_ACTIVITY, 0, doc="Show or hide the AI Activity area (next to the console)"
OPERATOR op_view_tools,    "view.toggle_tools",    "Tools Pane",    op_toggle_tools,    op_has_editor, ED_TOOLS,    KEY_T, doc="Show or hide the tools area"
OPERATOR op_view_outliner, "view.toggle_outliner", "Outliner Pane", op_toggle_sidebar,  op_has_editor, ED_OUTLINER, KEY_N, doc="Show or hide the outliner and properties areas"
OPERATOR op_view_console,  "view.toggle_console",  "Console Pane",  op_toggle_console,  op_has_editor, ED_CONSOLE,  0,     doc="Show or hide the console area"

.text

# node_ptr(edi=index) -> rax
node_ptr:
    mov     eax, edi
    shl     eax, 5
    lea     rcx, [rip+nodes]
    add     rax, rcx
    ret

# cam_ptr(edi=index) -> rax
cam_ptr:
    mov     eax, edi
    imul    eax, CAM_SZ
    lea     rcx, [rip+area_cams]
    add     rax, rcx
    ret

# cam_load(edi=area) / cam_store(edi=area) - swap a viewport camera in/out of
# the globals the viewport code works on
cam_load:
    test    edi, edi
    js      9f
    call    cam_ptr
    lea     rdx, [rip+cam_yaw]
    jmp     1f
cam_store:
    test    edi, edi
    js      9f
    call    cam_ptr
    mov     rdx, rax
    lea     rax, [rip+cam_yaw]
1:  mov     rcx, [rax]
    mov     [rdx], rcx
    mov     rcx, [rax+8]
    mov     [rdx+8], rcx
    mov     rcx, [rax+16]
    mov     [rdx+16], rcx
9:  ret

# area_init - every area starts with the default camera
area_init:
    push    rbx
    xor     ebx, ebx
1:  mov     edi, ebx
    call    cam_store
    inc     ebx
    cmp     ebx, MAX_NODES
    jb      1b
    pop     rbx
    ret

# node_alloc -> eax = free node index or -1
node_alloc:
    lea     rcx, [rip+nodes]
    xor     eax, eax
1:  cmp     byte ptr [rcx], 0
    je      2f
    add     rcx, N_SZ
    inc     eax
    cmp     eax, MAX_NODES
    jb      1b
    mov     eax, -1
2:  ret

# -----------------------------------------------------------------------------
# Layout
# -----------------------------------------------------------------------------
# area_layout - assign rectangles inside the content region
area_layout:
    mov     edi, [rip+area_root]
    xor     esi, esi
    mov     edx, [rip+cont_y0]
    mov     ecx, [rip+win_w]
    mov     r8d, [rip+cont_y1]
    sub     r8d, edx
    call    layout_node
    mov     edi, [rip+area_maxed]       # a maximized area takes it all
    test    edi, edi
    js      9f
    call    node_ptr
    mov     dword ptr [rax+N_X], 0
    mov     ecx, [rip+cont_y0]
    mov     [rax+N_Y], ecx
    mov     ecx, [rip+win_w]
    mov     [rax+N_W], ecx
    mov     ecx, [rip+cont_y1]
    sub     ecx, [rip+cont_y0]
    mov     [rax+N_H], ecx
9:  ret

# split_size(edi=available, esi=ratio) -> eax = size of child a
split_size:
    mov     eax, edi
    imul    rax, rsi
    shr     rax, 16
    lea     ecx, [rdi-MIN_AREA]
    cmp     eax, ecx
    cmovg   eax, ecx
    cmp     eax, MIN_AREA
    jge     1f
    mov     eax, MIN_AREA
1:  cmp     edi, 2*MIN_AREA             # too small for minimums: halve
    jge     2f
    mov     eax, edi
    shr     eax, 1
2:  ret

# layout_node(edi=node, esi=x, edx=y, ecx=w, r8d=h)
layout_node:
    push    rbx
    push    rbp
    push    r12
    push    r13
    push    r14
    push    r15
    sub     rsp, 8
    mov     ebx, edi
    mov     r12d, esi
    mov     r13d, edx
    mov     r14d, ecx
    mov     r15d, r8d
    call    node_ptr
    mov     rbp, rax
    mov     [rbp+N_X], r12d
    mov     [rbp+N_Y], r13d
    mov     [rbp+N_W], r14d
    mov     [rbp+N_H], r15d
    movzx   eax, byte ptr [rbp+N_KIND]
    cmp     eax, K_HSPLIT
    je      1f
    cmp     eax, K_VSPLIT
    je      2f
    jmp     9f
1:  lea     edi, [r14-SPLIT]
    mov     esi, [rbp+N_RATIO]
    call    split_size
    mov     [rsp], eax                  # width of a
    movzx   edi, byte ptr [rbp+N_A]
    mov     esi, r12d
    mov     edx, r13d
    mov     ecx, eax
    mov     r8d, r15d
    call    layout_node
    movzx   edi, byte ptr [rbp+N_B]
    mov     esi, r12d
    add     esi, [rsp]
    add     esi, SPLIT
    mov     edx, r13d
    lea     ecx, [r14-SPLIT]
    sub     ecx, [rsp]
    mov     r8d, r15d
    call    layout_node
    jmp     9f
2:  lea     edi, [r15-SPLIT]
    mov     esi, [rbp+N_RATIO]
    call    split_size
    mov     [rsp], eax                  # height of a
    movzx   edi, byte ptr [rbp+N_A]
    mov     esi, r12d
    mov     edx, r13d
    mov     ecx, r14d
    mov     r8d, eax
    call    layout_node
    movzx   edi, byte ptr [rbp+N_B]
    mov     esi, r12d
    mov     edx, r13d
    add     edx, [rsp]
    add     edx, SPLIT
    mov     ecx, r14d
    lea     r8d, [r15-SPLIT]
    sub     r8d, [rsp]
    call    layout_node
9:  add     rsp, 8
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbp
    pop     rbx
    ret

# set_body(edi=leaf) - ed_* = the leaf's rectangle below its header
set_body:
    mov     [rip+ed_node], edi
    call    node_ptr
    mov     ecx, [rax+N_X]
    mov     [rip+ed_x], ecx
    mov     ecx, [rax+N_Y]
    add     ecx, PANE_HDR_H
    mov     [rip+ed_y], ecx
    mov     ecx, [rax+N_W]
    mov     [rip+ed_w], ecx
    mov     ecx, [rax+N_H]
    sub     ecx, PANE_HDR_H
    mov     [rip+ed_h], ecx
    ret

# area_editor(edi=node) -> eax = editor shown by that leaf
area_editor:
    call    node_ptr
    movzx   eax, byte ptr [rax+N_ED]
    ret

# splitter_cursor(edi=split node) -> eax = cursor shape
splitter_cursor:
    call    node_ptr
    cmp     byte ptr [rax+N_KIND], K_HSPLIT
    mov     eax, CUR_EW
    je      1f
    mov     eax, CUR_NS
1:  ret

# area_node_rect(edi=node) -> rax = node pointer (x at +12, y +16, w +20, h +24)
area_node_rect:
    jmp     node_ptr

# -----------------------------------------------------------------------------
# Hit testing inside the content region
# area_hit(edi=x, esi=y) -> eax = HIT_*, edx = index; hit_area = leaf
# -----------------------------------------------------------------------------
area_hit:
    push    rbx
    push    r12
    push    r13
    mov     ebx, edi
    mov     r12d, esi
    mov     dword ptr [rip+hit_area], -1
    mov     r13d, [rip+area_maxed]
    test    r13d, r13d
    jns     .Lah_leaf
    mov     r13d, [rip+area_root]
.Lah_walk:
    mov     edi, r13d
    call    node_ptr
    movzx   r8d, byte ptr [rax+N_KIND]
    cmp     r8d, K_LEAF
    je      .Lah_leaf
    movzx   edi, byte ptr [rax+N_A]
    push    rax
    call    node_ptr
    mov     rdx, rax                    # child a
    pop     rax
    cmp     r8d, K_HSPLIT
    jne     2f
    mov     ecx, [rdx+N_X]
    add     ecx, [rdx+N_W]              # splitter x
    cmp     ebx, ecx
    jl      .Lah_a
    add     ecx, SPLIT
    cmp     ebx, ecx
    jl      .Lah_splitter
    jmp     .Lah_b
2:  mov     ecx, [rdx+N_Y]
    add     ecx, [rdx+N_H]
    cmp     r12d, ecx
    jl      .Lah_a
    add     ecx, SPLIT
    cmp     r12d, ecx
    jl      .Lah_splitter
.Lah_b:
    movzx   r13d, byte ptr [rax+N_B]
    jmp     .Lah_walk
.Lah_a:
    movzx   r13d, byte ptr [rax+N_A]
    jmp     .Lah_walk
.Lah_splitter:
    mov     eax, HIT_SPLITTER
    mov     edx, r13d
    jmp     .Lah_ret

.Lah_leaf:
    mov     [rip+hit_area], r13d
    mov     edi, r13d
    call    set_body
    mov     edi, r13d
    call    node_ptr
    mov     ecx, [rax+N_Y]
    add     ecx, PANE_HDR_H
    cmp     r12d, ecx
    jge     .Lah_body
    # header: buttons from the right (close, stack, side, maximize)
    mov     ecx, [rax+N_X]
    add     ecx, [rax+N_W]
    sub     ecx, 4                      # right edge of the button row
    mov     edx, ecx
    sub     edx, ebx                    # distance from the right
    js      3f
    cmp     edx, 4*HDR_BTN_W
    jae     3f
    mov     eax, edx
    xor     edx, edx
    mov     ecx, HDR_BTN_W
    div     ecx
    mov     edx, eax
    mov     eax, HIT_AREA_BTN
    jmp     .Lah_ret
3:  mov     ecx, [rax+N_X]
    add     ecx, TYPE_BTN_W
    mov     edx, r13d
    mov     eax, HIT_AREA_TYPE
    cmp     ebx, ecx
    jl      .Lah_ret
    mov     eax, HIT_AREA_HDR
    jmp     .Lah_ret

.Lah_body:
    movzx   ecx, byte ptr [rax+N_ED]
    mov     edx, r13d
    mov     eax, HIT_CANVAS
    cmp     ecx, ED_VIEWPORT
    jne     1f
    mov     edi, ebx                    # the redo panel sits on the canvas
    mov     esi, r12d
    call    redo_hit
    mov     edx, r13d
    test    eax, eax
    js      0f
    mov     edx, eax
    mov     eax, HIT_REDO
    jmp     .Lah_ret
0:  mov     eax, HIT_CANVAS
    jmp     .Lah_ret
1:
    cmp     ecx, ED_TOOLS
    je      .Lah_tools
    cmp     ecx, ED_OUTLINER
    je      .Lah_outliner
    cmp     ecx, ED_CONSOLE
    je      .Lah_console
    cmp     ecx, ED_ACTIVITY
    je      .Lah_activity
.Lah_pane:
    mov     eax, HIT_PANE
    mov     edx, r13d
    jmp     .Lah_ret
.Lah_tools:
    mov     eax, [rip+ed_x]
    add     eax, 8
    cmp     ebx, eax
    jl      .Lah_pane
    add     eax, [rip+ed_w]
    sub     eax, 16
    cmp     ebx, eax
    jge     .Lah_pane
    xor     r13d, r13d
4:  mov     edi, r13d
    call    tool_y
    cmp     r12d, eax
    jl      5f
    add     eax, TOOL_BTN_H
    cmp     r12d, eax
    jge     5f
    mov     eax, HIT_TOOL
    mov     edx, r13d
    jmp     .Lah_ret
5:  inc     r13d
    cmp     r13d, NUM_TOOLS
    jb      4b
    jmp     .Lah_pane2
.Lah_outliner:
    mov     eax, r12d                   # row under the pointer -> object
    sub     eax, [rip+ed_y]
    sub     eax, 4
    js      .Lah_pane2
    xor     edx, edx
    mov     ecx, ROW_H
    div     ecx
    add     eax, [rip+outl_scroll]
    cmp     eax, [rip+obj_count]
    jae     .Lah_pane2
    mov     edx, eax
    mov     eax, HIT_OUTLINER
    jmp     .Lah_ret
.Lah_activity:
    mov     edi, ebx
    mov     esi, r12d
    call    act_btn_hit
    test    eax, eax
    jz      .Lah_pane
    mov     eax, HIT_ACT_REVERT
    mov     edx, r13d
    jmp     .Lah_ret
.Lah_console:
    call    console_field
    cmp     r12d, esi
    jl      .Lah_pane
    add     esi, TF_H
    cmp     r12d, esi
    jge     .Lah_pane
    cmp     ebx, edi
    jl      .Lah_pane
    add     edi, edx
    cmp     ebx, edi
    jge     .Lah_pane
    mov     eax, HIT_CONSOLE_INPUT
    mov     edx, [rip+ed_node]
    jmp     .Lah_ret
.Lah_pane2:
    mov     eax, HIT_PANE
    mov     edx, [rip+ed_node]
.Lah_ret:
    pop     r13
    pop     r12
    pop     rbx
    ret

# console_field -> edi = x, esi = y, edx = w of the command line (from ed_*)
console_field:
    mov     edi, [rip+ed_x]
    add     edi, 6
    mov     esi, [rip+ed_y]
    add     esi, [rip+ed_h]
    sub     esi, TF_H+6
    mov     edx, [rip+ed_w]
    sub     edx, 12
    ret

# tool_y(edi=i) -> eax ; row_y(edi=i) -> eax  (relative to the editor body)
tool_y:
    mov     eax, edi
    imul    eax, TOOL_BTN_H+TOOL_BTN_GAP
    add     eax, [rip+ed_y]
    add     eax, 10
    cmp     edi, 4
    jb      1f
    add     eax, 28                     # room for the "CREATE" caption
1:  ret
row_y:
    mov     eax, edi
    imul    eax, ROW_H
    add     eax, [rip+ed_y]
    add     eax, 4
    ret

# area_drag(edi=pointer x, esi=pointer y) - move the splitter of drag_node
area_drag:
    push    rbx
    push    r12
    mov     ebx, edi
    mov     r12d, esi
    mov     edi, [rip+drag_node]
    call    node_ptr
    cmp     byte ptr [rax+N_KIND], K_HSPLIT
    jne     1f
    mov     ecx, [rax+N_W]
    sub     ecx, SPLIT                  # available
    mov     edx, ebx
    sub     edx, [rax+N_X]
    sub     edx, SPLIT/2
    jmp     2f
1:  mov     ecx, [rax+N_H]
    sub     ecx, SPLIT
    mov     edx, r12d
    sub     edx, [rax+N_Y]
    sub     edx, SPLIT/2
2:  test    edx, edx                    # ratio = pos / available (16.16)
    jns     3f
    xor     edx, edx
3:  cmp     ecx, 1
    jl      9f
    cmp     edx, ecx
    jle     4f
    mov     edx, ecx
4:  mov     r8, rax
    mov     eax, edx
    shl     rax, 16
    xor     edx, edx
    div     rcx
    mov     [r8+N_RATIO], eax
9:  pop     r12
    pop     rbx
    ret

# -----------------------------------------------------------------------------
# Drawing
# -----------------------------------------------------------------------------
area_draw_all:
    push    rbx
    push    r12
    mov     edi, [rip+area_maxed]
    test    edi, edi
    js      1f
    call    draw_leaf
    jmp     9f
1:  xor     ebx, ebx
2:  mov     edi, ebx
    call    node_ptr
    movzx   ecx, byte ptr [rax+N_KIND]
    test    ecx, ecx
    jz      4f
    mov     edi, ebx
    cmp     ecx, K_LEAF
    jne     3f
    call    draw_leaf
    jmp     4f
3:  call    draw_splitter
4:  inc     ebx
    cmp     ebx, MAX_NODES
    jb      2b
9:  pop     r12
    pop     rbx
    ret

# draw_splitter(edi=split node)
draw_splitter:
    push    rbx
    push    r12
    push    r13
    mov     ebx, edi
    call    node_ptr
    mov     r12, rax
    movzx   edi, byte ptr [r12+N_A]
    call    node_ptr
    mov     r13d, COL_SPLIT_HOT         # hot while hovered or dragged
    cmp     dword ptr [rip+drag_mode], DRAG_SPLITTER
    jne     1f
    cmp     ebx, [rip+drag_node]
    je      2f
1:  cmp     dword ptr [rip+hover_id], HIT_SPLITTER
    jne     11f
    cmp     ebx, [rip+hover_idx]
    je      2f
11: mov     r13d, COL_SPLIT
2:  cmp     byte ptr [r12+N_KIND], K_HSPLIT
    jne     3f
    mov     edi, [rax+N_X]
    add     edi, [rax+N_W]
    mov     esi, [r12+N_Y]
    mov     edx, SPLIT
    mov     ecx, [r12+N_H]
    jmp     4f
3:  mov     edi, [r12+N_X]
    mov     esi, [rax+N_Y]
    add     esi, [rax+N_H]
    mov     edx, [r12+N_W]
    mov     ecx, SPLIT
4:  mov     r8d, r13d
    call    fill_rect
    pop     r13
    pop     r12
    pop     rbx
    ret

# draw_leaf(edi=leaf) - header + editor body
draw_leaf:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    mov     ebx, edi
    call    node_ptr
    mov     r12, rax
    mov     edi, [r12+N_X]              # header
    mov     esi, [r12+N_Y]
    mov     edx, [r12+N_W]
    mov     ecx, PANE_HDR_H
    mov     r8d, COL_PANE_HDR
    call    fill_rect
    mov     r8d, COL_SEPARATOR          # accent marks the active area
    cmp     ebx, [rip+active_area]
    jne     1f
    mov     r8d, COL_ACCENT
1:  mov     edi, [r12+N_X]
    mov     esi, [r12+N_Y]
    mov     edx, 3
    mov     ecx, PANE_HDR_H
    call    fill_rect
    # editor type button
    cmp     dword ptr [rip+hover_id], HIT_AREA_TYPE
    jne     2f
    cmp     ebx, [rip+hover_idx]
    jne     2f
    mov     edi, [r12+N_X]
    add     edi, 3
    mov     esi, [r12+N_Y]
    mov     edx, TYPE_BTN_W-3
    mov     ecx, PANE_HDR_H
    mov     r8d, COL_HOVER
    call    fill_rect
2:  movzx   eax, byte ptr [r12+N_ED]
    lea     rcx, [rip+editor_names]
    mov     rdx, [rcx+rax*8]
    mov     edi, [r12+N_X]
    add     edi, 12
    mov     esi, [r12+N_Y]
    add     esi, 4
    mov     ecx, COL_TEXT_DIM
    call    draw_text
    lea     edi, [rax+6]                # down-arrow after the name
    mov     esi, [r12+N_Y]
    add     esi, PANE_HDR_H/2-2
    mov     r13d, 0
3:  push    rdi
    push    rsi
    mov     edx, 7
    sub     edx, r13d
    sub     edx, r13d
    lea     edi, [rdi+r13]
    lea     esi, [rsi+r13]
    mov     ecx, 1
    mov     r8d, COL_TEXT_DIM
    call    fill_rect
    pop     rsi
    pop     rdi
    inc     r13d
    cmp     r13d, 4
    jb      3b
    # header buttons: 0 close, 1 split stacked, 2 split side by side, 3 maximize
    xor     r13d, r13d
4:  mov     r14d, [r12+N_X]
    add     r14d, [r12+N_W]
    sub     r14d, 4
    mov     eax, r13d
    inc     eax
    imul    eax, HDR_BTN_W
    sub     r14d, eax                   # button x
    mov     r15d, [r12+N_Y]
    add     r15d, PANE_HDR_H/2          # centre y
    cmp     dword ptr [rip+hover_id], HIT_AREA_BTN
    jne     5f
    cmp     ebx, [rip+hit_area]
    jne     5f
    cmp     r13d, [rip+hover_idx]
    jne     5f
    mov     edi, r14d
    mov     esi, [r12+N_Y]
    add     esi, 2
    mov     edx, HDR_BTN_W
    mov     ecx, PANE_HDR_H-4
    mov     r8d, COL_HOVER
    test    r13d, r13d
    jnz     41f
    mov     r8d, COL_CLOSE_HOT
41: call    fill_rect
5:  lea     edi, [r14+5]                # 12x10 icon box
    lea     esi, [r15-5]
    cmp     r13d, 0
    jne     6f
    lea     edx, [r14+15]               # close: X
    lea     ecx, [r15+5]
    mov     r8d, COL_TEXT
    call    draw_line
    lea     edi, [r14+5]
    lea     esi, [r15+5]
    lea     edx, [r14+15]
    lea     ecx, [r15-5]
    mov     r8d, COL_TEXT
    call    draw_line
    jmp     8f
6:  mov     edx, 12
    mov     ecx, 10
    mov     r8d, COL_TEXT
    call    rect_outline
    cmp     r13d, 1
    jne     61f
    lea     edi, [r14+5]                # stacked: horizontal divider
    mov     esi, r15d
    mov     edx, 12
    mov     ecx, 1
    mov     r8d, COL_TEXT
    call    fill_rect
    jmp     8f
61: cmp     r13d, 2
    jne     62f
    lea     edi, [r14+11]               # side by side: vertical divider
    lea     esi, [r15-5]
    mov     edx, 1
    mov     ecx, 10
    mov     r8d, COL_TEXT
    call    fill_rect
    jmp     8f
62: lea     edi, [r14+5]                # maximize: thick top edge
    lea     esi, [r15-5]
    mov     edx, 12
    mov     ecx, 3
    mov     r8d, COL_TEXT
    cmp     ebx, [rip+area_maxed]
    jne     63f
    mov     r8d, COL_ACCENT
63: call    fill_rect
8:  inc     r13d
    cmp     r13d, 4
    jb      4b

    # body
    mov     edi, ebx
    call    set_body
    movzx   eax, byte ptr [r12+N_ED]
    cmp     eax, ED_VIEWPORT
    je      9f                          # the viewport paints its own background
    mov     edi, [rip+ed_x]
    mov     esi, [rip+ed_y]
    mov     edx, [rip+ed_w]
    mov     ecx, [rip+ed_h]
    mov     r8d, COL_PANE_BG
    call    fill_rect
9:  mov     edi, [rip+ed_x]
    mov     esi, [rip+ed_y]
    mov     edx, [rip+ed_x]
    add     edx, [rip+ed_w]
    mov     ecx, [rip+ed_y]
    add     ecx, [rip+ed_h]
    call    set_clip
    movzx   eax, byte ptr [r12+N_ED]
    lea     rcx, [rip+editor_draw]
    call    [rcx+rax*8]
    call    reset_clip
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# ---- editors (draw into ed_x/ed_y/ed_w/ed_h; ed_node = the area) ----------------
ed_viewport_draw:
    mov     eax, [rip+ed_x]
    mov     [rip+cvs_x0], eax
    add     eax, [rip+ed_w]
    mov     [rip+cvs_x1], eax
    mov     eax, [rip+ed_y]
    mov     [rip+cvs_y0], eax
    add     eax, [rip+ed_h]
    mov     [rip+cvs_y1], eax
    mov     edi, [rip+ed_node]
    call    cam_load
    jmp     viewport_draw

ed_tools_draw:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    mov     edi, 4
    call    tool_y
    lea     esi, [rax-22]
    mov     edi, [rip+ed_x]
    add     edi, 12
    lea     rdx, [rip+s_h_create]
    mov     ecx, COL_TEXT_DIM
    call    draw_text
    xor     ebx, ebx
1:  lea     rax, [rip+tool_ops]
    mov     r15, [rax+rbx*8]            # operator
    mov     edi, ebx
    call    tool_y
    mov     r12d, eax                   # y
    mov     r13d, COL_BTN               # background
    mov     r14d, COL_TEXT              # foreground
    mov     edi, HIT_TOOL
    mov     esi, ebx
    call    is_hot
    test    eax, eax
    jz      2f
    mov     eax, [rip+ed_node]
    cmp     eax, [rip+hit_area]
    jne     2f
    mov     r13d, COL_BTN_HOVER
2:  mov     rdi, r15
    call    op_checked
    cmp     eax, 1
    jne     3f
    mov     r13d, COL_ACCENT
    mov     r14d, COL_TEXT_DARK
3:  mov     edi, [rip+ed_x]
    add     edi, 8
    mov     esi, r12d
    mov     edx, [rip+ed_w]
    sub     edx, 16
    mov     ecx, TOOL_BTN_H
    mov     r8d, r13d
    call    fill_rect
    mov     edi, [rip+ed_x]             # glyph: filled for tools, hollow for create
    add     edi, 16
    lea     esi, [r12+9]
    mov     edx, 8
    mov     ecx, 8
    mov     r8d, r14d
    cmp     ebx, 4
    jae     4f
    call    fill_rect
    jmp     5f
4:  call    rect_outline
5:  mov     edi, [rip+ed_x]
    add     edi, 34
    lea     esi, [r12+5]
    mov     rdx, [r15+OP_LABEL]
    mov     ecx, r14d
    call    draw_text
    mov     edi, [r15+OP_KEY]
    call    fmt_key
    test    rax, rax
    jz      6f
    mov     rdx, rax                    # shortcut, right aligned
    push    rdx
    mov     rdi, rax
    call    text_width
    pop     rdx
    mov     edi, [rip+ed_x]
    add     edi, [rip+ed_w]
    sub     edi, 16
    sub     edi, eax
    lea     esi, [r12+5]
    mov     ecx, COL_TEXT_DIM
    cmp     r14d, COL_TEXT_DARK
    jne     51f
    mov     ecx, COL_TEXT_DARK
51: call    draw_text
6:  inc     ebx
    cmp     ebx, NUM_TOOLS
    jb      1b
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

ed_outliner_draw:
    push    rbx
    push    r12
    push    r13
    push    r14
    xor     ebx, ebx                    # visible row
1:  mov     r13d, ebx
    add     r13d, [rip+outl_scroll]     # object index
    cmp     r13d, [rip+obj_count]
    jae     9f
    mov     edi, ebx
    call    row_y
    mov     r12d, eax
    mov     ecx, [rip+ed_y]
    add     ecx, [rip+ed_h]
    cmp     r12d, ecx
    jge     9f
    mov     edi, r13d
    call    obj_at
    mov     r14, rax
    mov     r8d, COL_ACCENT_DARK
    test    dword ptr [r14+OB_FLAGS], OBF_SELECTED
    jnz     2f
    mov     edi, HIT_OUTLINER
    mov     esi, r13d
    call    is_hot
    test    eax, eax
    jz      3f
    mov     r8d, COL_HOVER
2:  mov     edi, [rip+ed_x]
    add     edi, 4
    mov     esi, r12d
    mov     edx, [rip+ed_w]
    sub     edx, 8
    mov     ecx, ROW_H
    call    fill_rect
3:  mov     edi, [rip+ed_x]             # type icon
    add     edi, 14
    lea     esi, [r12+6]
    mov     edx, 8
    mov     ecx, 8
    mov     r8d, [r14+OB_COLOR]
    call    fill_rect
    mov     ecx, COL_TEXT               # name; the active object in gold
    lea     rax, [rip+obj_list]
    mov     eax, [rax+r13*4]
    cmp     eax, [rip+active_obj]
    jne     4f
    mov     ecx, COL_ACTIVE
4:  mov     edi, [rip+ed_x]
    add     edi, 30
    lea     esi, [r12+2]
    mov     rdx, r14
    call    draw_text
    inc     ebx
    jmp     1b
9:  pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# fmt_vec3(rdi=float[3], esi=1 to show degrees) - "x, y, z" into fmt_buf
fmt_vec3:
    push    rbx
    push    r12
    push    r13
    mov     rbx, rdi
    mov     r12d, esi
    xor     r13d, r13d
1:  movss   xmm0, [rbx+r13*4]
    test    r12d, r12d
    jz      2f
    mulss   xmm0, [rip+f_rad2deg]
2:  call    fmt_fix1
    inc     r13d
    cmp     r13d, 3
    jae     3f
    lea     rdi, [rip+s_comma]
    call    fmt_str
    jmp     1b
3:  pop     r13
    pop     r12
    pop     rbx
    ret

# prop_row(edi=y, rsi=label) - label at left, current fmt_buf as value
prop_row:
    push    rbx
    push    r12
    mov     ebx, edi
    mov     r12, rsi
    mov     edi, [rip+ed_x]
    add     edi, 14
    mov     esi, ebx
    mov     rdx, r12
    mov     ecx, COL_TEXT_DIM
    call    draw_text
    mov     edi, [rip+ed_x]
    add     edi, 100
    mov     esi, ebx
    lea     rdx, [rip+fmt_buf]
    mov     ecx, COL_TEXT
    call    draw_text
    pop     r12
    pop     rbx
    ret

ed_props_draw:
    push    rbx
    push    r12
    mov     r12d, [rip+ed_y]
    add     r12d, 8
    mov     edi, [rip+active_obj]       # ---- active object
    call    obj_get
    test    rax, rax
    jnz     11f
    mov     edi, [rip+ed_x]
    add     edi, 14
    mov     esi, r12d
    lea     rdx, [rip+s_no_active]
    mov     ecx, COL_TEXT_DIM
    call    draw_text
    add     r12d, 30
    jmp     12f
11: mov     rbx, rax
    mov     edi, [rip+ed_x]
    add     edi, 14
    mov     esi, r12d
    mov     rdx, rbx
    mov     ecx, COL_ACTIVE
    call    draw_text
    add     r12d, 20
    call    fmt_reset
    lea     rdi, [rbx+OB_LOC]
    xor     esi, esi
    call    fmt_vec3
    mov     edi, r12d
    lea     rsi, [rip+s_p_loc]
    call    prop_row
    add     r12d, 18
    call    fmt_reset
    lea     rdi, [rbx+OB_ROT]
    mov     esi, 1
    call    fmt_vec3
    mov     edi, r12d
    lea     rsi, [rip+s_p_rot]
    call    prop_row
    add     r12d, 18
    call    fmt_reset
    lea     rdi, [rbx+OB_SCALE]
    xor     esi, esi
    call    fmt_vec3
    mov     edi, r12d
    lea     rsi, [rip+s_p_scale]
    call    prop_row
    add     r12d, 18
    call    fmt_reset                   # mesh statistics
    mov     rbx, [rbx+OB_MESH]
    mov     edi, [rbx+ME_NVERTS]
    call    fmt_int
    lea     rdi, [rip+s_v]
    call    fmt_str
    mov     edi, [rbx+ME_NEDGES]
    call    fmt_int
    lea     rdi, [rip+s_e]
    call    fmt_str
    mov     edi, [rbx+ME_NPOLYS]
    call    fmt_int
    lea     rdi, [rip+s_f]
    call    fmt_str
    mov     edi, r12d
    lea     rsi, [rip+s_p_mesh]
    call    prop_row
    add     r12d, 30
12: mov     edi, [rip+vp_area]          # ---- camera of the last used viewport
    call    cam_load
    mov     edi, [rip+ed_x]
    add     edi, 14
    mov     esi, r12d
    lea     rdx, [rip+s_p_camera]
    mov     ecx, COL_ACCENT
    call    draw_text
    add     r12d, 20
    call    fmt_reset
    movss   xmm0, [rip+cam_yaw]
    call    fmt_deg
    lea     rdi, [rip+s_deg]
    call    fmt_str
    mov     edi, r12d
    lea     rsi, [rip+s_p_yaw]
    call    prop_row
    add     r12d, 18
    call    fmt_reset
    movss   xmm0, [rip+cam_pitch]
    call    fmt_deg
    lea     rdi, [rip+s_deg]
    call    fmt_str
    mov     edi, r12d
    lea     rsi, [rip+s_p_pitch]
    call    prop_row
    add     r12d, 18
    call    fmt_reset
    movss   xmm0, [rip+cam_dist]
    call    fmt_fix1
    mov     edi, r12d
    lea     rsi, [rip+s_p_dist]
    call    prop_row
    add     r12d, 18
    call    fmt_reset
    movss   xmm0, [rip+cam_tx]
    call    fmt_fix1
    lea     rdi, [rip+s_comma]
    call    fmt_str
    movss   xmm0, [rip+cam_ty]
    call    fmt_fix1
    lea     rdi, [rip+s_comma]
    call    fmt_str
    movss   xmm0, [rip+cam_tz]
    call    fmt_fix1
    mov     edi, r12d
    lea     rsi, [rip+s_p_target]
    call    prop_row
    add     r12d, 26
    call    fmt_reset                   # size of that viewport's canvas
    mov     edi, [rip+vp_area]
    test    edi, edi
    js      1f
    call    node_ptr
    mov     rbx, rax
    mov     edi, [rbx+N_W]
    call    fmt_int
    lea     rdi, [rip+s_xx]
    call    fmt_str
    mov     edi, [rbx+N_H]
    sub     edi, PANE_HDR_H
    call    fmt_int
1:  mov     edi, r12d
    lea     rsi, [rip+s_p_canvas]
    call    prop_row
    add     r12d, 18
    call    fmt_reset
    lea     rdi, [rip+s_on]
    cmp     dword ptr [rip+show_grid], 0
    jne     2f
    lea     rdi, [rip+s_off]
2:  call    fmt_str
    mov     edi, r12d
    lea     rsi, [rip+s_p_grid]
    call    prop_row
    add     r12d, 18
    call    fmt_reset                   # number of areas
    xor     ebx, ebx
    lea     rcx, [rip+nodes]
    xor     eax, eax
3:  cmp     byte ptr [rcx], K_LEAF
    jne     4f
    inc     ebx
4:  add     rcx, N_SZ
    inc     eax
    cmp     eax, MAX_NODES
    jb      3b
    mov     edi, ebx
    call    fmt_int
    mov     edi, r12d
    lea     rsi, [rip+s_p_areas]
    call    prop_row
    pop     r12
    pop     rbx
    ret

ed_console_draw:
    push    rbx
    push    r12
    push    r13
    push    r14
    mov     edi, FONT_MONO
    call    text_use
    # visible lines = min((h - 8 - field) / 18, lines logged, ring size)
    mov     eax, [rip+ed_h]
    sub     eax, 8+TF_H+6
    jle     9f
    xor     edx, edx
    mov     ecx, 18
    div     ecx
    mov     ebx, eax
    mov     eax, [rip+log_head]
    cmp     ebx, eax
    cmova   ebx, eax
    mov     eax, LOG_LINES
    cmp     ebx, eax
    cmova   ebx, eax
    test    ebx, ebx
    jz      9f
    mov     r12d, [rip+ed_y]            # newest line at the bottom
    add     r12d, [rip+ed_h]
    sub     r12d, 22+TF_H+6
    mov     r13d, [rip+log_head]
1:  dec     r13d
    mov     eax, r13d
    and     eax, LOG_LINES-1
    imul    eax, LOG_LINE_LEN
    lea     r14, [rip+log_buf]
    add     r14, rax
    mov     ecx, COL_TEXT
    cmp     byte ptr [r14], '>'
    jne     2f
    mov     ecx, COL_ACCENT
2:  mov     edi, [rip+ed_x]
    add     edi, 12
    mov     esi, r12d
    mov     rdx, r14
    call    draw_text
    sub     r12d, 18
    dec     ebx
    jnz     1b
9:  call    console_field
    push    rdi
    push    rsi
    push    rdx
    lea     rdi, [rip+tfi_console]
    call    tf_select
    pop     rdx
    pop     rsi
    pop     rdi
    call    tf_draw
    mov     edi, FONT_UI
    call    text_use
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# =============================================================================
#  Tree editing
# =============================================================================
# split_with(edi=node, esi=kind, edx=ratio, ecx=new editor, r8d=new first?)
#   -> eax = new leaf or -1. The node's content moves to a fresh slot; the node
#   becomes a split of (old content, new leaf).
split_with:
    push    rbx
    push    rbp
    push    r12
    push    r13
    push    r14
    push    r15
    sub     rsp, 8
    mov     ebx, edi
    mov     r12d, esi
    mov     r13d, edx
    mov     r14d, ecx
    mov     [rsp], r8d
    call    node_alloc
    test    eax, eax
    js      .Lsw_full
    mov     ebp, eax                    # old content goes here
    mov     edi, eax
    call    node_ptr
    mov     byte ptr [rax+N_KIND], K_LEAF   # reserve before the second alloc
    call    node_alloc
    test    eax, eax
    js      .Lsw_undo
    mov     r15d, eax                   # new leaf
    # copy node -> old
    mov     edi, ebx
    call    node_ptr
    mov     rsi, rax
    mov     edi, ebp
    call    node_ptr
    mov     rdi, rax
    mov     rcx, [rsi]
    mov     [rdi], rcx
    mov     rcx, [rsi+8]
    mov     [rdi+8], rcx
    mov     [rdi+N_PARENT], bl
    cmp     byte ptr [rdi+N_KIND], K_LEAF   # re-parent the moved children
    je      1f
    push    rdi
    movzx   edi, byte ptr [rdi+N_A]
    call    node_ptr
    mov     [rax+N_PARENT], bpl
    pop     rdi
    movzx   edi, byte ptr [rdi+N_B]
    call    node_ptr
    mov     [rax+N_PARENT], bpl
1:  mov     edi, ebx                    # move the camera with the content
    call    cam_ptr
    mov     rsi, rax
    mov     edi, ebp
    call    cam_ptr
    mov     rcx, [rsi]
    mov     [rax], rcx
    mov     rcx, [rsi+8]
    mov     [rax+8], rcx
    mov     rcx, [rsi+16]
    mov     [rax+16], rcx
    mov     edi, r15d                   # the new leaf starts with the same view
    call    cam_ptr
    mov     rdx, [rsi]
    mov     [rax], rdx
    mov     rdx, [rsi+8]
    mov     [rax+8], rdx
    mov     rdx, [rsi+16]
    mov     [rax+16], rdx
    mov     edi, r15d                   # new leaf
    call    node_ptr
    mov     byte ptr [rax+N_KIND], K_LEAF
    mov     [rax+N_ED], r14b
    mov     [rax+N_PARENT], bl
    mov     edi, ebx                    # node becomes the split
    call    node_ptr
    mov     [rax+N_KIND], r12b
    mov     [rax+N_RATIO], r13d
    mov     [rax+N_A], bpl
    mov     [rax+N_B], r15b
    cmp     dword ptr [rsp], 0
    je      2f
    mov     [rax+N_A], r15b
    mov     [rax+N_B], bpl
2:  lea     rdi, [rip+active_area]      # references to node follow its content
    call    retarget
    lea     rdi, [rip+vp_area]
    call    retarget
    lea     rdi, [rip+area_maxed]
    call    retarget
    mov     eax, r15d
    jmp     .Lsw_out
.Lsw_undo:
    mov     edi, ebp
    call    node_ptr
    mov     byte ptr [rax+N_KIND], 0
.Lsw_full:
    lea     rdi, [rip+s_no_room]
    call    log_line
    mov     eax, -1
.Lsw_out:
    add     rsp, 8
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbp
    pop     rbx
    ret
# retarget(rdi=&var): if var == ebx then var = ebp   (split_with helper)
retarget:
    cmp     [rdi], ebx
    jne     1f
    mov     [rdi], ebp
1:  ret

# close_leaf(edi=leaf) -> eax = 1 if closed. The sibling takes the parent's slot.
close_leaf:
    push    rbx
    push    rbp
    push    r12
    push    r13
    mov     ebx, edi
    cmp     ebx, [rip+area_root]
    je      .Lcl_root
    call    node_ptr
    movzx   r12d, byte ptr [rax+N_PARENT]
    mov     edi, r12d
    call    node_ptr
    movzx   ebp, byte ptr [rax+N_A]     # sibling
    cmp     ebp, ebx
    jne     1f
    movzx   ebp, byte ptr [rax+N_B]
1:  mov     edi, ebp                    # copy sibling content into the parent
    call    node_ptr
    mov     rsi, rax
    mov     edi, r12d
    call    node_ptr
    mov     dl, [rax+N_PARENT]
    mov     rcx, [rsi]
    mov     [rax], rcx
    mov     rcx, [rsi+8]
    mov     [rax+8], rcx
    mov     [rax+N_PARENT], dl
    mov     r13, rax
    cmp     byte ptr [r13+N_KIND], K_LEAF
    je      2f
    movzx   edi, byte ptr [r13+N_A]
    call    node_ptr
    mov     [rax+N_PARENT], r12b
    movzx   edi, byte ptr [r13+N_B]
    call    node_ptr
    mov     [rax+N_PARENT], r12b
2:  mov     edi, ebp                    # sibling camera moves with it
    call    cam_ptr
    mov     rsi, rax
    mov     edi, r12d
    call    cam_ptr
    mov     rcx, [rsi]
    mov     [rax], rcx
    mov     rcx, [rsi+8]
    mov     [rax+8], rcx
    mov     rcx, [rsi+16]
    mov     [rax+16], rcx
    mov     edi, ebx                    # free both slots
    call    node_ptr
    mov     byte ptr [rax+N_KIND], 0
    mov     edi, ebp
    call    node_ptr
    mov     byte ptr [rax+N_KIND], 0
    lea     rdi, [rip+active_area]      # fix references
    call    fix_ref
    lea     rdi, [rip+vp_area]
    call    fix_ref
    lea     rdi, [rip+area_maxed]
    call    fix_ref
    cmp     dword ptr [rip+area_maxed], -1
    je      3f
    mov     edi, [rip+area_maxed]       # maximized area must still be a leaf
    call    node_ptr
    cmp     byte ptr [rax+N_KIND], K_LEAF
    je      3f
    mov     dword ptr [rip+area_maxed], -1
3:  mov     edi, [rip+vp_area]          # keep vp_area on a viewport
    test    edi, edi
    js      4f
    call    node_ptr
    cmp     byte ptr [rax+N_KIND], K_LEAF
    jne     4f
    cmp     byte ptr [rax+N_ED], ED_VIEWPORT
    je      5f
4:  mov     edi, ED_VIEWPORT
    call    find_editor
    mov     [rip+vp_area], eax
5:  mov     edi, [rip+active_area]
    test    edi, edi
    js      6f
    call    node_ptr
    cmp     byte ptr [rax+N_KIND], K_LEAF
    je      7f
6:  mov     eax, [rip+vp_area]
    mov     [rip+active_area], eax
7:  mov     eax, 1
    jmp     9f
.Lcl_root:
    lea     rdi, [rip+s_last_area]
    call    log_line
    xor     eax, eax
9:  pop     r13
    pop     r12
    pop     rbp
    pop     rbx
    ret
# fix_ref(rdi=&var): closed leaf -> -1, sibling -> parent  (close_leaf helper)
fix_ref:
    mov     eax, [rdi]
    cmp     eax, ebx
    jne     1f
    mov     dword ptr [rdi], -1
    ret
1:  cmp     eax, ebp
    jne     2f
    mov     [rdi], r12d
2:  ret

# find_editor(edi=editor) -> eax = first leaf showing it, or -1
find_editor:
    lea     rcx, [rip+nodes]
    xor     eax, eax
1:  cmp     byte ptr [rcx+N_KIND], K_LEAF
    jne     2f
    movzx   edx, byte ptr [rcx+N_ED]
    cmp     edx, edi
    je      3f
2:  add     rcx, N_SZ
    inc     eax
    cmp     eax, MAX_NODES
    jb      1b
    mov     eax, -1
3:  ret

# close_all(edi=editor) - close every area showing it
close_all:
    push    rbx
    mov     ebx, edi
1:  mov     edi, ebx
    call    find_editor
    test    eax, eax
    js      9f
    mov     edi, eax
    call    close_leaf
    test    eax, eax
    jnz     1b
9:  pop     rbx
    ret

# =============================================================================
#  Operator implementations
# =============================================================================
op_area_split:                          # rdi = split kind
    mov     esi, edi
    mov     edi, [rip+active_area]
    test    edi, edi
    js      9f
    push    rsi
    push    rdi
    call    node_ptr
    movzx   ecx, byte ptr [rax+N_ED]
    pop     rdi
    pop     rsi
    mov     edx, 32768
    xor     r8d, r8d
    call    split_with
    test    eax, eax
    js      9f
    mov     [rip+active_area], eax
9:  ret

op_area_close_x:
    mov     edi, [rip+active_area]
    test    edi, edi
    js      9f
    jmp     close_leaf
9:  ret

op_area_max:
    mov     eax, [rip+active_area]
    cmp     eax, [rip+area_maxed]
    jne     1f
    mov     eax, -1
1:  mov     [rip+area_maxed], eax
    ret
op_check_maxed:
    xor     eax, eax
    cmp     dword ptr [rip+area_maxed], -1
    setne   al
    ret

op_area_type:                           # rdi = editor
    mov     esi, edi
    mov     edi, [rip+active_area]
    test    edi, edi
    js      9f
    push    rsi
    push    rdi
    call    node_ptr
    pop     rdi
    pop     rsi
    mov     [rax+N_ED], sil
    cmp     esi, ED_VIEWPORT
    jne     9f
    mov     [rip+vp_area], edi
9:  ret
op_check_area_type:
    mov     esi, edi
    mov     edi, [rip+active_area]
    xor     eax, eax
    test    edi, edi
    js      9f
    push    rsi
    call    node_ptr
    pop     rsi
    movzx   ecx, byte ptr [rax+N_ED]
    xor     eax, eax
    cmp     ecx, esi
    sete    al
9:  ret

op_has_editor:                          # rdi = editor -> 1 if shown anywhere
    call    find_editor
    xor     ecx, ecx
    test    eax, eax
    setns   cl
    mov     eax, ecx
    ret

# console_ensure - make sure some area shows the console
console_ensure:
    mov     edi, ED_CONSOLE
    call    find_editor
    test    eax, eax
    jns     1f
    jmp     op_toggle_console
1:  ret

# T: tools column on the left of everything
op_toggle_tools:
    mov     edi, ED_TOOLS
    call    find_editor
    test    eax, eax
    js      1f
    mov     edi, ED_TOOLS
    jmp     close_all
1:  mov     edi, [rip+area_root]
    mov     esi, K_HSPLIT
    mov     edx, 10794                  # ~210 px of 1280
    mov     ecx, ED_TOOLS
    mov     r8d, 1
    jmp     split_with

# N: outliner + properties column on the right
op_toggle_sidebar:
    mov     edi, ED_OUTLINER
    call    find_editor
    test    eax, eax
    jns     1f
    mov     edi, ED_PROPS
    call    find_editor
    test    eax, eax
    js      2f
1:  mov     edi, ED_OUTLINER
    call    close_all
    mov     edi, ED_PROPS
    jmp     close_all
2:  mov     edi, [rip+area_root]
    mov     esi, K_HSPLIT
    mov     edx, 52800                  # sidebar ~260 px of 1280
    mov     ecx, ED_OUTLINER
    xor     r8d, r8d
    call    split_with
    test    eax, eax
    js      9f
    mov     edi, eax
    mov     esi, K_VSPLIT
    mov     edx, 10420
    mov     ecx, ED_PROPS
    xor     r8d, r8d
    call    split_with
9:  ret

# console: below the viewport the user worked in last
# the AI Activity area: beside the console (or under the viewport)
op_toggle_activity:
    mov     edi, ED_ACTIVITY
    call    find_editor
    test    eax, eax
    js      1f
    mov     edi, ED_ACTIVITY
    jmp     close_all
1:  mov     edi, ED_CONSOLE
    call    find_editor
    test    eax, eax
    js      2f
    mov     edi, eax
    mov     esi, K_HSPLIT
    mov     edx, 32768
    mov     ecx, ED_ACTIVITY
    xor     r8d, r8d
    jmp     split_with
2:  mov     edi, [rip+vp_area]
    test    edi, edi
    jns     3f
    mov     edi, [rip+area_root]
3:  mov     esi, K_VSPLIT
    mov     edx, 51826
    mov     ecx, ED_ACTIVITY
    xor     r8d, r8d
    jmp     split_with

op_toggle_console:
    mov     edi, ED_CONSOLE
    call    find_editor
    test    eax, eax
    js      1f
    mov     edi, ED_CONSOLE
    jmp     close_all
1:  mov     edi, [rip+vp_area]
    test    edi, edi
    jns     2f
    mov     edi, [rip+area_root]
2:  mov     esi, K_VSPLIT
    mov     edx, 51826
    mov     ecx, ED_CONSOLE
    xor     r8d, r8d
    jmp     split_with

.section .note.GNU-stack,"",@progbits
