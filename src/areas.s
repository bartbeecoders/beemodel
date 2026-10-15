# =============================================================================
#  BeeModel - area system (Blender-style): the content region is a binary
#  tree of splits; every leaf is an "area" hosting one editor (3D Viewport,
#  Tools, Outliner, Properties, Console). Areas can be split, closed, resized,
#  maximized and switched to another editor from their header. Every 3D
#  Viewport area keeps its own camera.
# =============================================================================
.intel_syntax noprefix
.include "const.inc"
.include "widgets.inc"
.include "icons.inc"
.equ PTAB_W, 32                          # the Properties tab strip
.equ PTAB_N, 8
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
.globl cam_ptr
.globl hit_area
.globl drag_node
.globl ed_x
.globl ed_y
.globl ed_w
.globl ed_h
.globl items_area
.globl items_area_n
.globl split_with
.globl find_editor
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
s_ed_render:    .asciz "Render"
s_ed_uved:      .asciz "UV Editor"
s_ed_nodes:     .asciz "Node Editor"
s_ed_assets:    .asciz "Asset Browser"
s_ed_timeline:  .asciz "Timeline"
s_ed_dopesheet: .asciz "Dope Sheet"
s_ed_graph:     .asciz "Graph Editor"
s_h_create:     .asciz "CREATE"
s_p_loc:        .asciz "Location"
s_p_rot:        .asciz "Rotation"
s_p_scale:      .asciz "Scale"
s_p_mesh:       .asciz "Mesh"
s_p_sketch:     .asciz "Sketch"
s_p_dof:        .asciz "DOF"
s_sk_comma:     .asciz " plane, "
s_sk_ents:      .asciz " entities, "
s_sk_cons:      .asciz " constraints"
s_sk_bad:       .asciz ", conflicts "
.align 8
sk_planes_p:    .quad s_pl_xy, s_pl_xz, s_pl_yz
s_pl_xy:        .asciz "XY"
s_pl_xz:        .asciz "XZ"
s_pl_yz:        .asciz "YZ"
s_no_active:    .asciz "No active object"
s_v:            .asciz " v, "
s_e:            .asciz " e, "
s_f:            .asciz " f"
s_comma:        .asciz ", "
s_last_area:    .asciz "  the last area cannot be closed"
s_no_room:      .asciz "  no room for more areas"
.align 8
editor_names:   .quad s_ed_viewport, s_ed_tools, s_ed_outliner, s_ed_props, s_ed_console, s_ed_activity, s_ed_render, s_ed_uved, s_ed_nodes, s_ed_assets, s_ed_timeline, s_ed_dopesheet, s_ed_graph
editor_draw:    .quad ed_viewport_draw, ed_tools_draw, ed_outliner_draw, ed_props_draw, ed_console_draw, ed_activity_draw, ed_render_draw, ed_uved_draw, ed_nodes_draw, ed_assets_draw, ed_timeline_draw, ed_dopesheet_draw, ed_graph_draw
area_btn_ops:   .quad op_area_close, op_area_split_stack, op_area_split_side, op_area_maximize
items_area:     .quad op_area_type_vp, op_area_type_tools, op_area_type_outl
                .quad op_area_type_props, op_area_type_console, op_area_type_activity, op_area_type_render
                .quad op_area_type_uved, op_area_type_nodes, op_area_type_assets, op_area_type_timeline
                .quad op_area_type_dopesheet, op_area_type_graph
items_area_end:
.set items_area_n, (items_area_end - items_area) / 8

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
OPERATOR op_area_type_render,"area.type_render",   "Render",      op_area_type, op_check_area_type, ED_RENDER,   doc="Show the render in the active area"
OPERATOR op_area_type_uved,"area.type_uv_editor",  "UV Editor",   op_area_type, op_check_area_type, ED_UVED,     doc="Show the UV editor in the active area"
OPERATOR op_area_type_assets,"area.type_asset_browser", "Asset Browser", op_area_type, op_check_area_type, ED_ASSETS, doc="Show the content library (~/BeeModel/library) in the active area: search, tags, dependencies; drag an asset into a viewport"
OPERATOR op_area_type_timeline,"area.type_timeline", "Timeline", op_area_type, op_check_area_type, ED_TIMELINE, doc="Show the timeline (frames, keys, playback) in the active area"
OPERATOR op_area_type_dopesheet,"area.type_dope_sheet", "Dope Sheet", op_area_type, op_check_area_type, ED_DOPESHEET, doc="Show every curve's keys in rows in the active area"
OPERATOR op_area_type_graph,"area.type_graph_editor", "Graph Editor", op_area_type, op_check_area_type, ED_GRAPH, doc="Show the animation curves with their handles in the active area"
OPERATOR op_area_type_nodes,"area.type_node_editor", "Node Editor", op_area_type, op_check_area_type, ED_NODES,   doc="Show the node editor (the active material's shader graph) in the active area"
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
    cmp     ecx, ED_PROPS
    je      .Lah_props
    cmp     ecx, ED_ASSETS
    jne     11f
    mov     eax, HIT_ASSETS
    mov     edx, r13d
    jmp     .Lah_ret
11: cmp     ecx, ED_TIMELINE
    jne     12f
    mov     eax, HIT_TIMELINE
    mov     edx, r13d
    jmp     .Lah_ret
12: cmp     ecx, ED_DOPESHEET
    je      13f
    cmp     ecx, ED_GRAPH
    jne     2f
13: mov     eax, HIT_ANIMED
    mov     edx, r13d
    jmp     .Lah_ret
2:  cmp     ecx, ED_NODES
    jne     1f
    mov     eax, HIT_NODES
    mov     edx, r13d
    jmp     .Lah_ret
1:  cmp     ecx, ED_UVED
    jne     .Lah_pane
    mov     eax, HIT_UVED
    mov     edx, r13d
    jmp     .Lah_ret
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
.Lah_props:                             # material, modifier buttons and fields
    mov     edi, ebx
    mov     esi, r12d
    call    mats_props_hit
    test    eax, eax
    jns     1f
    mov     edi, ebx
    mov     esi, r12d
    call    mods_props_hit
    test    eax, eax
    jns     1f
    mov     edi, ebx
    mov     esi, r12d
    call    rb_props_hit
1:
    test    eax, eax
    js      .Lah_pane
    mov     edx, eax
    mov     eax, HIT_MODS
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
    movzx   eax, byte ptr [r12+N_ED]    # a 3D viewport: its tools in the header
    cmp     eax, ED_VIEWPORT
    jne     5f
    mov     edi, [r12+N_X]
    add     edi, TYPE_BTN_W+6
    mov     esi, [r12+N_Y]
    mov     edx, [r12+N_X]
    add     edx, [r12+N_W]
    sub     edx, 4*HDR_BTN_W+10
    call    vp_header_tools
5:
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
5:  mov     edi, HDR_BTN_W-16           # its icon, centred
    shr     edi, 1
    add     edi, r14d
    lea     esi, [r15-8]
    lea     rax, [rip+hdr_icons]
    mov     edx, [rax+r13*4]
    mov     r8d, COL_TEXT
    cmp     r13d, 3                     # maximize: accent while maximized
    jne     7f
    cmp     ebx, [rip+area_maxed]
    jne     7f
    mov     r8d, COL_ACCENT
7:  call    draw_icon
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

# nodeed_active -> eax = 1 when the active area is a node editor
.globl nodeed_active
nodeed_active:
    mov     edi, [rip+active_area]
    test    edi, edi
    js      1f
    call    area_editor
    cmp     eax, ED_NODES
    jne     1f
    mov     eax, 1
    ret
1:  xor     eax, eax
    ret

# animed_active -> eax = the active area's editor when it is a dope sheet or
#   a graph editor, else 0
.globl animed_active
animed_active:
    mov     edi, [rip+active_area]
    test    edi, edi
    js      1f
    sub     rsp, 8
    call    area_editor
    add     rsp, 8
    cmp     eax, ED_DOPESHEET
    je      2f
    cmp     eax, ED_GRAPH
    je      2f
1:  xor     eax, eax
2:  ret

# uved_active -> eax = 1 when the active area is a UV editor
.globl uved_active
uved_active:
    mov     edi, [rip+active_area]
    test    edi, edi
    js      1f
    call    area_editor
    cmp     eax, ED_UVED
    jne     1f
    mov     eax, 1
    ret
1:  xor     eax, eax
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
    mov     r9d, FIELD_R
    call    fill_rrect
    mov     edi, [rip+ed_x]             # its icon
    add     edi, 13
    mov     esi, TOOL_BTN_H-16
    shr     esi, 1
    add     esi, r12d
    lea     rax, [rip+tool_icons]
    mov     edx, [rax+rbx*4]
    mov     r8d, r14d
    call    draw_icon
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
.globl prop_row
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

# xyz_row(edi=y, rsi=label, rdx=float[3], rcx=widget) - a label and three
#   compact number fields (X Y Z) across the rest of the row
xyz_row:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    mov     ebx, edi
    mov     r12, rdx
    mov     r13, rcx
    mov     rdx, rsi
    mov     edi, [rip+ed_x]
    add     edi, 14
    mov     esi, ebx
    mov     ecx, COL_TEXT_DIM
    call    draw_text
    mov     eax, [rip+ed_w]             # field width: (w - 94 - 2 gaps) / 3
    sub     eax, 94+6
    xor     edx, edx
    mov     ecx, 3
    div     ecx
    mov     r15d, eax
    xor     r14d, r14d
1:  mov     rdi, r13
    mov     esi, r15d
    add     esi, 3
    imul    esi, r14d
    add     esi, [rip+ed_x]
    add     esi, 80
    lea     edx, [rbx-1]
    mov     ecx, r15d
    lea     r8, [r12+r14*4]
    mov     r9d, r14d
    call    wg
    inc     r14d
    cmp     r14d, 3
    jb      1b
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# widget callbacks: a renamed object, a moved one (drivers follow)
props_rename:                           # rdi = the new name
    mov     rsi, rdi
    mov     edi, [rip+active_obj]
    jmp     obj_rename
props_xform:
    jmp     rig_eval

ed_props_draw:
    push    rbx
    push    r12
    push    r13
    push    r14
    sub     rsp, 8
    call    props_tabs                  # the tab strip on the left
    add     dword ptr [rip+ed_x], PTAB_W  # the page beside it, scrolled
    sub     dword ptr [rip+ed_w], PTAB_W
    lea     rdi, [rip+wd_props_scroll]
    mov     esi, [rip+ed_x]
    mov     edx, [rip+ed_y]
    mov     ecx, [rip+ed_w]
    mov     r8d, [rip+ed_h]
    lea     r9, [rip+props_scroll]
    call    wg_scroll_begin
    lea     r12d, [rax+8]
    mov     eax, [rip+props_tab]
    cmp     eax, PTAB_N
    jb      1f
    xor     eax, eax
1:  lea     rcx, [rip+props_pages]
    jmp     [rcx+rax*8]

.Lpp_object:
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
    jmp     .Lpp_done
11: mov     rbx, rax
    lea     rdi, [rip+wd_obj_name]      # name, location, rotation, scale:
    mov     esi, [rip+ed_x]             #  fields (widgets.s) - drag, type, Tab
    add     esi, 10
    lea     edx, [r12-1]
    mov     ecx, [rip+ed_w]
    sub     ecx, 24
    mov     r8, rbx
    xor     r9d, r9d
    call    wg
    add     r12d, 20
    mov     edi, r12d
    lea     rsi, [rip+s_p_loc]
    lea     rdx, [rbx+OB_LOC]
    lea     rcx, [rip+wd_obj_loc]
    call    xyz_row
    add     r12d, 18
    mov     edi, r12d
    lea     rsi, [rip+s_p_rot]
    lea     rdx, [rbx+OB_ROT]
    lea     rcx, [rip+wd_obj_rot]
    call    xyz_row
    add     r12d, 18
    mov     edi, r12d
    lea     rsi, [rip+s_p_scale]
    lea     rdx, [rbx+OB_SCALE]
    lea     rcx, [rip+wd_obj_scale]
    call    xyz_row
    add     r12d, 18
    add     r12d, 6
    mov     eax, [rbx+OB_FLAGS]         # visible (not hidden)
    not     eax
    shr     eax, 9
    and     eax, 1
    mov     [rip+props_vis], eax
    lea     rdi, [rip+wd_obj_vis]
    lea     r8, [rip+props_vis]
    call    vp_row
    mov     edi, [rbx+OB_COLOR]         # its colour as #rrggbb
    call    hex_color
    lea     rdi, [rip+wd_obj_color]
    lea     r8, [rip+props_hex]
    mov     esi, [rip+ed_x]
    add     esi, 80
    mov     edx, r12d
    mov     ecx, [rip+ed_w]
    sub     ecx, 94
    xor     r9d, r9d
    call    wg
    mov     edi, [rip+ed_x]             # its caption and a swatch
    add     edi, 14
    lea     esi, [r12+3]
    lea     rdx, [rip+s_p_color]
    mov     ecx, COL_TEXT_DIM
    call    draw_text
    mov     edi, [rip+ed_x]
    add     edi, [rip+ed_w]
    sub     edi, 36
    lea     esi, [r12+4]
    mov     edx, 14
    mov     ecx, 14
    mov     r8d, [rbx+OB_COLOR]
    mov     r9d, 3
    call    fill_rrect
    add     r12d, WG_H+8
    mov     rax, [rbx+OB_SKETCH]        # a sketch: its plane, sizes, DOF
    test    rax, rax
    jz      113f
    push    rax
    sub     rsp, 8
    call    fmt_reset
    mov     rax, [rsp+8]
    mov     eax, [rax+8]
    lea     rcx, [rip+sk_planes_p]
    mov     rdi, [rcx+rax*8]
    call    fmt_str
    lea     rdi, [rip+s_sk_comma]
    call    fmt_str
    mov     rax, [rsp+8]
    mov     edi, [rax+16]
    call    fmt_int
    lea     rdi, [rip+s_sk_ents]
    call    fmt_str
    mov     rax, [rsp+8]
    mov     edi, [rax+20]
    call    fmt_int
    lea     rdi, [rip+s_sk_cons]
    call    fmt_str
    mov     edi, r12d
    lea     rsi, [rip+s_p_sketch]
    call    prop_row
    add     r12d, 18
    call    fmt_reset
    mov     rax, [rsp+8]
    mov     edi, [rax+24]
    call    fmt_int
    mov     rax, [rsp+8]
    cmp     dword ptr [rax+28], 0
    je      112f
    lea     rdi, [rip+s_sk_bad]
    call    fmt_str
    mov     rax, [rsp+8]
    mov     edi, [rax+28]
    call    fmt_int
112:mov     edi, r12d
    lea     rsi, [rip+s_p_dof]
    call    prop_row
    add     rsp, 16
    add     r12d, 12
    jmp     .Lpp_done
113:call    fmt_reset                   # mesh statistics
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
    add     r12d, 12
    jmp     .Lpp_done

.Lpp_mods:
    mov     edi, r12d
    call    mods_props_draw
    mov     r12d, eax
    jmp     .Lpp_done
.Lpp_mat:
    mov     edi, r12d
    call    mats_props_draw
    mov     r12d, eax
    jmp     .Lpp_done
.Lpp_phys:
    mov     edi, r12d
    call    rb_props_draw
    mov     r12d, eax
    jmp     .Lpp_done
.Lpp_cad:
    mov     edi, r12d
    call    cad_props_draw
    mov     edi, eax
    call    feat_props_draw
    cmp     eax, r12d                   # nothing yet: how to start
    jne     1f
    mov     edi, [rip+ed_x]
    add     edi, 14
    mov     esi, r12d
    lea     rdx, [rip+s_cad_empty]
    mov     ecx, COL_TEXT_DIM
    call    draw_small
    lea     eax, [r12+20]
1:  mov     r12d, eax
    jmp     .Lpp_done
.Lpp_scene:
    call    props_scene
    jmp     .Lpp_done
.Lpp_render:
    call    props_render
    jmp     .Lpp_done
.Lpp_view:
    lea     rdi, [rip+wd_vp_sec]
    mov     esi, [rip+ed_x]
    add     esi, 8
    mov     edx, r12d
    mov     ecx, [rip+ed_w]
    sub     ecx, 20
    xor     r8d, r8d
    xor     r9d, r9d
    call    wg
    add     r12d, 28
    test    eax, eax
    jz      .Lpp_done                   # (closed)
    lea     rdi, [rip+wd_vp_shading]
    lea     r8, [rip+vp_shading]
    call    vp_row
    lea     rdi, [rip+wd_vp_grid]
    lea     r8, [rip+show_grid]
    call    vp_row
    lea     rdi, [rip+wd_vp_theme]
    lea     r8, [rip+th_id]
    call    vp_row
    mov     edi, [rip+vp_area]          # the last used viewport's camera
    test    edi, edi
    js      .Lpp_done
    call    cam_ptr
    mov     rbx, rax
    lea     rdi, [rip+wd_vp_yaw]
    lea     r8, [rbx+0]
    call    vp_row
    lea     rdi, [rip+wd_vp_pitch]
    lea     r8, [rbx+4]
    call    vp_row
    lea     rdi, [rip+wd_vp_dist]
    lea     r8, [rbx+8]
    call    vp_row
.Lpp_done:
    lea     edi, [r12+12]
    call    wg_scroll_end
    sub     dword ptr [rip+ed_x], PTAB_W
    add     dword ptr [rip+ed_w], PTAB_W
    add     rsp, 8
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# props_tabs - the tab strip: an icon per page, the open one lit
props_tabs:
    push    rbx
    push    r12
    sub     rsp, 8
    mov     edi, [rip+ed_x]             # its background
    mov     esi, [rip+ed_y]
    mov     edx, PTAB_W-2
    mov     ecx, [rip+ed_h]
    mov     r8d, COL_MENU_BG
    call    fill_rect
    xor     ebx, ebx
1:  cmp     ebx, PTAB_N
    jae     9f
    lea     rax, [rip+ptab_descs]
    mov     rdi, [rax+rbx*8]
    mov     esi, [rip+ed_x]
    add     esi, 3
    mov     edx, ebx
    imul    edx, edx, 28
    add     edx, [rip+ed_y]
    add     edx, 6
    mov     r12d, edx
    mov     ecx, PTAB_W-8
    lea     r8, [rip+props_tab]
    mov     r9d, ebx
    call    wg
    mov     edi, [rip+ed_x]
    add     edi, (PTAB_W-2-16)/2
    lea     esi, [r12+3]
    lea     rax, [rip+ptab_icons]
    mov     edx, [rax+rbx*4]
    mov     r8d, COL_TEXT_DIM
    cmp     ebx, [rip+props_tab]
    jne     2f
    mov     r8d, COL_ACCENT
2:  call    draw_icon
    inc     ebx
    jmp     1b
9:  add     rsp, 8
    pop     r12
    pop     rbx
    ret

# props_scene - units, the world's light, the frame range (r12d = y, on)
props_scene:
    push    rbx
    sub     rsp, 16
    lea     rdx, [rip+s_pg_scene]
    call    page_heading
    call    cad_unit_mm                 # the units as a choice
    cvtsd2ss xmm0, xmm0
    xor     ecx, ecx
    lea     rax, [rip+unit_mm_tab]
1:  cmp     ecx, 3
    jae     2f
    ucomiss xmm0, [rax+rcx*4]
    je      2f
    inc     ecx
    jmp     1b
2:  mov     [rip+props_units], ecx
    lea     rdi, [rip+wd_sc_units]
    lea     r8, [rip+props_units]
    call    vp_row
    add     r12d, 4
    lea     rdi, [rip+wd_sc_wstr]
    lea     r8, [rip+env_str]
    call    vp_row
    lea     rdi, [rip+wd_sc_wrot]
    lea     r8, [rip+env_rot]
    call    vp_row
    add     r12d, 4
    call    an_range                    # the frame range
    mov     [rip+props_fstart], eax
    mov     [rip+props_fend], edx
    cvtss2si eax, xmm0
    mov     [rip+props_fps], eax
    lea     rdi, [rip+wd_sc_fstart]
    lea     r8, [rip+props_fstart]
    call    vp_row
    lea     rdi, [rip+wd_sc_fend]
    lea     r8, [rip+props_fend]
    call    vp_row
    lea     rdi, [rip+wd_sc_fps]
    lea     r8, [rip+props_fps]
    call    vp_row
    add     rsp, 16
    pop     rbx
    ret

# props_render - the render's size, samples, denoising; Render, Save
props_render:
    sub     rsp, 8
    lea     rdx, [rip+s_pg_render]
    call    page_heading
    lea     rdi, [rip+wd_rn_w]
    lea     r8, [rip+rn_w]
    call    vp_row
    lea     rdi, [rip+wd_rn_h]
    lea     r8, [rip+rn_h]
    call    vp_row
    lea     rdi, [rip+wd_rn_spp]
    lea     r8, [rip+rn_spp]
    call    vp_row
    lea     rdi, [rip+wd_rn_dn]
    lea     r8, [rip+rn_denoise]
    call    vp_row
    add     r12d, 6
    lea     rdi, [rip+wd_rn_go]
    lea     r8, [rip+props_dummy]
    call    vp_row
    lea     rdi, [rip+wd_rn_save]
    lea     r8, [rip+props_dummy]
    call    vp_row
    add     rsp, 8
    ret

# page_heading(rdx=title; r12d = y, on)
page_heading:
    mov     edi, [rip+ed_x]
    add     edi, 14
    mov     esi, r12d
    mov     ecx, COL_ACCENT
    sub     rsp, 8
    call    draw_heading
    add     rsp, 8
    add     r12d, 28
    ret

# ---- callbacks -------------------------------------------------------------------
props_vis_cb:                           # rdi = &props_vis
    mov     ecx, [rdi]
    mov     edi, [rip+active_obj]
    push    rcx
    call    obj_get
    pop     rcx
    test    rax, rax
    jz      9f
    and     dword ptr [rax+OB_FLAGS], ~OBF_HIDDEN
    test    ecx, ecx
    jnz     9f
    or      dword ptr [rax+OB_FLAGS], OBF_HIDDEN
9:  ret

props_hex_cb:                           # rdi = typed text: #rrggbb or rrggbb
    push    rbx
    mov     rbx, rdi
    cmp     byte ptr [rbx], '#'
    jne     1f
    inc     rbx
1:  xor     edx, edx
    xor     ecx, ecx
2:  movzx   eax, byte ptr [rbx+rcx]
    test    eax, eax
    jz      4f
    sub     eax, '0'
    cmp     eax, 9
    jbe     3f
    movzx   eax, byte ptr [rbx+rcx]
    or      eax, 0x20
    sub     eax, 'a'
    cmp     eax, 5
    ja      8f                          # not hex: ignored
    add     eax, 10
3:  shl     edx, 4
    or      edx, eax
    inc     ecx
    cmp     ecx, 6
    jb      2b
4:  cmp     ecx, 6
    jne     8f
    push    rdx
    mov     edi, [rip+active_obj]
    call    obj_get
    pop     rdx
    test    rax, rax
    jz      8f
    mov     [rax+OB_COLOR], edx
8:  pop     rbx
    ret

props_units_cb:                         # rdi = &props_units -> scene.units
    mov     eax, [rdi]
    lea     rcx, [rip+unit_kw]
    mov     rax, [rcx+rax*8]
    lea     rdi, [rip+op_scene_units]
    jmp     run_with_arg

props_range_cb:                         # the frame fields -> anim.range
    sub     rsp, 8
    call    fmt_reset
    mov     edi, [rip+props_fstart]
    call    fmt_int
    mov     edi, ' '
    call    fmt_char
    mov     edi, [rip+props_fend]
    call    fmt_int
    mov     edi, ' '
    call    fmt_char
    mov     edi, [rip+props_fps]
    call    fmt_int
    add     rsp, 8
    lea     rsi, [rip+fmt_buf]          # (a copy: run_op's echo uses fmt_buf)
    lea     rdi, [rip+props_arg]
    mov     ecx, 63
    rep     movsb
    mov     byte ptr [rdi], 0
    lea     rax, [rip+props_arg]
    lea     rdi, [rip+op_an_range]
    jmp     run_with_arg

# run_with_arg(rdi=operator, rax=argument text)
run_with_arg:
    push    qword ptr [rip+op_arg]
    mov     [rip+op_arg], rax
    call    run_op
    pop     qword ptr [rip+op_arg]
    ret

# hex_color(edi=0xrrggbb) -> props_hex = "#rrggbb"
hex_color:
    lea     rsi, [rip+props_hex]
    mov     byte ptr [rsi], '#'
    mov     ecx, 6
1:  mov     eax, edi
    and     eax, 15
    lea     rdx, [rip+hex_digits_p]
    mov     al, [rdx+rax]
    mov     [rsi+rcx], al
    shr     edi, 4
    dec     ecx
    jnz     1b
    mov     byte ptr [rsi+7], 0
    ret

# vp_row(rdi=widget, r8=value; r12d = y, advanced) - one full-width row
vp_row:
    mov     esi, [rip+ed_x]
    add     esi, 14
    mov     edx, r12d
    mov     ecx, [rip+ed_w]
    sub     ecx, 28
    xor     r9d, r9d
    sub     rsp, 8
    call    wg
    add     rsp, 8
    add     r12d, WG_H+4
    ret

vp_theme_cb:                            # rdi = th_id
    mov     edi, [rdi]
    jmp     th_set

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

.section .rodata
.align 4
hdr_icons:      .long ICON_CLOSE, ICON_SPLIT_V, ICON_SPLIT_H, ICON_MAXIMIZE
tool_icons:     .long ICON_SELECT, ICON_MOVE, ICON_ROTATE, ICON_SCALE, ICON_CUBE
                .long ICON_SPHERE, ICON_CYLINDER, ICON_PLANE, ICON_LIGHT, ICON_CAMERA
.align 8
vp_shade_lbl:   .quad s_sh_solid, s_sh_wire, s_sh_mat
vp_theme_lbl:   .quad s_th_d, s_th_l, s_th_c
s_sh_solid:     .asciz "Solid"
s_sh_wire:      .asciz "Wireframe"
s_sh_mat:       .asciz "Material Preview"
s_th_d:         .asciz "Dark theme"
s_th_l:         .asciz "Light theme"
s_th_c:         .asciz "High contrast"
.text
.section .bss
.align 4
props_tab:      .skip 4                 # the page shown (PTAB_*)
props_scroll:   .skip 4
props_vis:      .skip 4
props_units:    .skip 4
props_fstart:   .skip 4
props_fend:     .skip 4
props_fps:      .skip 4
props_dummy:    .skip 4
props_hex:      .skip 32
props_arg:      .skip 64
.section .rodata
s_p_color:      .asciz "Colour"
s_pg_scene:     .asciz "Scene"
s_pg_render:    .asciz "Render"
s_cad_empty:    .asciz "No parameters or features yet"
hex_digits_p:   .ascii "0123456789abcdef"
s_u_mm:         .asciz "Millimetres"
s_u_cm:         .asciz "Centimetres"
s_u_m:          .asciz "Metres"
s_u_in:         .asciz "Inches"
k_u_mm:         .asciz "mm"
k_u_cm:         .asciz "cm"
k_u_m:          .asciz "m"
k_u_in:         .asciz "in"
.align 4
unit_mm_tab:    .float 1.0, 10.0, 1000.0, 25.4
ptab_icons:     .long ICON_OBJECT, ICON_MODIFIER, ICON_MATERIAL, ICON_PHYSICS, ICON_SKETCH
                .long ICON_WORLD, ICON_RENDERED, ICON_WIRE
.align 8
unit_lbl:       .quad s_u_mm, s_u_cm, s_u_m, s_u_in
unit_kw:        .quad k_u_mm, k_u_cm, k_u_m, k_u_in
ptab_descs:     .quad wd_pt0, wd_pt1, wd_pt2, wd_pt3, wd_pt4, wd_pt5, wd_pt6, wd_pt7
props_pages:    .quad .Lpp_object, .Lpp_mods, .Lpp_mat, .Lpp_phys, .Lpp_cad, .Lpp_scene, .Lpp_render, .Lpp_view
.text
WIDGET wd_pt0, WK_ROW, "props.tab.object", "Object", tip="Name, place, rotation, size, visibility and colour of the active object"
WIDGET wd_pt1, WK_ROW, "props.tab.modifiers", "Modifiers", tip="The modifier stack: mirror, array, subdivision, booleans, geometry nodes ..."
WIDGET wd_pt2, WK_ROW, "props.tab.material", "Material", tip="The object's material: colour, roughness, metal, emission, textures"
WIDGET wd_pt3, WK_ROW, "props.tab.physics", "Physics", tip="Rigid body, joints and the physics world"
WIDGET wd_pt4, WK_ROW, "props.tab.cad", "CAD", tip="Parameters and the features of parts"
WIDGET wd_pt5, WK_ROW, "props.tab.scene", "Scene", tip="Units, the world's light and the frame range"
WIDGET wd_pt6, WK_ROW, "props.tab.render", "Render", tip="Render size, samples and denoising, Render and Save"
WIDGET wd_pt7, WK_ROW, "props.tab.viewport", "Viewport", tip="Shading, grid, theme and the viewport camera"
WIDGET wd_props_scroll, WK_SCROLL, "props.page"
WIDGET wd_obj_vis,   WK_TOGGLE, "object.visible", "Visible", cb=props_vis_cb, undo="Hide", tip="Show or hide the object (H hides the selection, Alt+H shows all)"
WIDGET wd_obj_color, WK_TEXT, "object.color", "Colour", cb=props_hex_cb, undo="Colour", tip="The object's colour in the viewport, as #rrggbb"
WIDGET wd_sc_units, WK_ENUM, "scene.units", "Units", cb=props_units_cb, aux=unit_lbl, n=4, tip="What one scene unit is (typed lengths with units convert)"
WIDGET wd_sc_wstr, WK_FLOAT, "world.strength", "World strength", 0.0, 1000.0, 0.01, 3, WGF_CLAMP, undo="World", tip="How bright the world (sky or HDRI) lights the scene"
WIDGET wd_sc_wrot, WK_FLOAT, "world.rotation", "World rotation", step=0.00872665, dec=1, flags=WGF_DEG, undo="World", tip="Turns the world image about the vertical axis"
WIDGET wd_sc_fstart, WK_INT, "scene.frame_start", "Start frame", -100000.0, 100000.0, 0.2, 0, cb=props_range_cb, tip="The first frame of the animation"
WIDGET wd_sc_fend, WK_INT, "scene.frame_end", "End frame", -100000.0, 100000.0, 0.2, 0, cb=props_range_cb, tip="The last frame of the animation"
WIDGET wd_sc_fps, WK_INT, "scene.fps", "Frames per second", 1.0, 1000.0, 0.1, 0, WGF_CLAMP, cb=props_range_cb, tip="Playback speed"
WIDGET wd_rn_w, WK_INT, "render.width", "Width", 1.0, 8192.0, 1.0, 0, WGF_CLAMP, tip="The render's width in pixels"
WIDGET wd_rn_h, WK_INT, "render.height", "Height", 1.0, 8192.0, 1.0, 0, WGF_CLAMP, tip="The render's height in pixels"
WIDGET wd_rn_spp, WK_INT, "render.samples", "Samples", 1.0, 65536.0, 1.0, 0, WGF_CLAMP, tip="Samples per pixel: more is cleaner and slower"
WIDGET wd_rn_dn, WK_TOGGLE, "render.denoise", "Denoise", tip="Clean up the noise of the finished render"
WIDGET wd_rn_go, WK_BUTTON, "render.start", "Render (F12)", flags=WGF_PRIMARY, aux=op_render_start
WIDGET wd_rn_save, WK_BUTTON, "render.save", "Save Render...", aux=op_render_save
WIDGET wd_vp_sec,     WK_SECTION, "props.viewport", "Viewport"
WIDGET wd_vp_shading, WK_ENUM,   "viewport.shading", aux=vp_shade_lbl, n=3
WIDGET wd_vp_grid,    WK_TOGGLE, "viewport.grid", "Ground grid"
WIDGET wd_vp_theme,   WK_ENUM,   "ui.theme", cb=vp_theme_cb, aux=vp_theme_lbl, n=3
WIDGET wd_vp_yaw,     WK_FLOAT,  "viewport.yaw", "Yaw", step=0.00872665, dec=1, flags=WGF_DEG
WIDGET wd_vp_pitch,   WK_FLOAT,  "viewport.pitch", "Pitch", -1.55, 1.55, 0.00872665, 1, WGF_DEG|WGF_CLAMP
WIDGET wd_vp_dist,    WK_FLOAT,  "viewport.distance", "Distance", 1.5, 20000.0, 0.05, 2, WGF_CLAMP
WIDGET wd_obj_name,  WK_TEXT,  "object.name", , flags=WGF_COMPACT, cb=props_rename, undo="Rename", tip="The object's name. Click to type a new one (names stay unique: Cube.001)"
WIDGET wd_obj_loc,   WK_FLOAT, "object.location", , step=0.01, dec=3, flags=WGF_COMPACT, cb=props_xform, undo="Move", tip="Where the object is, in scene units. Drag sideways (Shift: finer, Ctrl: steps), or click and type a value or expression: 25mm, 2*pi"
WIDGET wd_obj_rot,   WK_FLOAT, "object.rotation", , step=0.00872665, dec=1, flags=WGF_COMPACT|WGF_DEG, cb=props_xform, undo="Rotate", tip="Euler XYZ rotation in degrees. Drag sideways, or click and type: 90, 45+15, 1.2rad"
WIDGET wd_obj_scale, WK_FLOAT, "object.scale", , step=0.005, dec=3, flags=WGF_COMPACT, cb=props_xform, undo="Scale", tip="Size along each axis (1 = as modelled). Drag sideways, or click and type a factor"

.section .note.GNU-stack,"",@progbits
