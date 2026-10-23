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
.equ PTAB_N, 12                         # (the last, Landscape: only for a landscape)
.equ OUTL_MAXROWS, 256
.include "macros.inc"

# exports
.globl nodes
.globl area_cams
.globl props_tab
.globl close_leaf
.globl node_ptr
.globl ed_node
.globl area_layout
.globl area_hit
.globl area_draw_all
.globl area_drag
.globl area_node_rect
.globl draw_leaf
.globl cam_load
.globl cam_store
.globl area_init
.globl area_root
.globl area_maxed
.globl active_area
.globl vp_area
.globl area_is_viewport
.globl cam_ptr
.globl outl_rename
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
area_ortho:     .skip MAX_NODES*4           # each viewport: orthographic (not saved)
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
s_ed_versions:  .asciz "Versions"
s_ed_prefs:     .asciz "Preferences"
s_ed_help:      .asciz "Help"
s_ed_ai:        .asciz "AI Assistant"
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
editor_names:   .quad s_ed_viewport, s_ed_tools, s_ed_outliner, s_ed_props, s_ed_console, s_ed_activity, s_ed_render, s_ed_uved, s_ed_nodes, s_ed_assets, s_ed_timeline, s_ed_dopesheet, s_ed_graph, s_ed_versions, s_ed_prefs, s_ed_help, s_ed_ai
editor_draw:    .quad ed_viewport_draw, ed_tools_draw, ed_outliner_draw, ed_props_draw, ed_console_draw, ed_activity_draw, ed_render_draw, ed_uved_draw, ed_nodes_draw, ed_assets_draw, ed_timeline_draw, ed_dopesheet_draw, ed_graph_draw, ed_versions_draw, ed_prefs_draw, ed_help_draw, ed_ai_draw
area_btn_ops:   .quad op_area_close, op_area_split_stack, op_area_split_side, op_area_maximize
items_area:     .quad op_area_type_vp, op_area_type_tools, op_area_type_outl
                .quad op_area_type_props, op_area_type_console, op_area_type_activity, op_area_type_render
                .quad op_area_type_uved, op_area_type_nodes, op_area_type_assets, op_area_type_timeline
                .quad op_area_type_dopesheet, op_area_type_graph, op_area_type_versions, op_area_type_prefs, op_area_type_help, op_area_type_ai
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
OPERATOR op_area_type_versions,"area.type_versions", "Versions", op_area_type, op_check_area_type, ED_VERSIONS, doc="Show the scene's versions (branches, commits, merges) and collaboration in the active area"
OPERATOR op_area_type_prefs,"area.type_preferences", "Preferences", op_area_type, op_check_area_type, ED_PREFS, doc="Show the preferences in the active area"
OPERATOR op_area_type_ai,"area.type_ai", "AI Assistant", op_area_type, op_check_area_type, ED_AI, doc="Show the AI Assistant in the active area: describe what to build"
OPERATOR op_area_type_help,"area.type_help", "Help", op_area_type, op_check_area_type, ED_HELP, doc="Show what the pointer rests on - what it does, its shortcut - in the active area"
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
    lea     rax, [rip+area_ortho]
    mov     ecx, [rax+rdi*4]
    mov     [rip+cam_ortho], ecx
    call    cam_ptr
    lea     rdx, [rip+cam_yaw]
    jmp     1f
cam_store:
    test    edi, edi
    js      9f
    lea     rax, [rip+area_ortho]
    mov     ecx, [rip+cam_ortho]
    mov     [rax+rdi*4], ecx
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

# area_is_viewport(edi=node) -> eax = 1 when it is a leaf showing a 3D
#   viewport (live.s: does the live view's owner still exist)
area_is_viewport:
    xor     eax, eax
    cmp     edi, MAX_NODES
    jae     9f
    call    node_ptr
    cmp     byte ptr [rax+N_KIND], K_LEAF
    jne     8f
    cmp     byte ptr [rax+N_ED], ED_VIEWPORT
    jne     8f
    mov     eax, 1
    ret
8:  xor     eax, eax
9:  ret

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
    mov     ecx, ebx                    # the top-left corner (8 px): join
    sub     ecx, [rax+N_X]
    cmp     ecx, 8
    jae     1f
    mov     ecx, r12d
    sub     ecx, [rax+N_Y]
    cmp     ecx, 8
    jae     1f
    mov     eax, HIT_AREA_CORNER
    mov     edx, r13d
    jmp     .Lah_ret
1:
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
    jmp     .Lah_ret                    # (the redo panel: widgets)
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
.Lah_tools:                             # (its rows are widgets)
    jmp     .Lah_pane2
.Lah_outliner:
    mov     eax, r12d                   # row under the pointer -> object (a
    sub     eax, [rip+ed_y]             #  folder row: -1, its widgets)
    sub     eax, 4
    js      .Lah_pane2
    xor     edx, edx
    mov     ecx, ROW_H
    div     ecx
    cmp     eax, [rip+outl_rows]
    jae     .Lah_pane2
    lea     rcx, [rip+outl_map]
    cmp     dword ptr [rcx+rax*4], 0
    jl      .Lah_pane2
    mov     eax, r12d
    sub     eax, [rip+ed_y]
    sub     eax, 4
    js      .Lah_pane2
    xor     edx, edx
    mov     ecx, ROW_H
    div     ecx
    cmp     eax, [rip+outl_rows]
    jae     .Lah_pane2
    lea     rcx, [rip+outl_map]
    mov     edx, [rcx+rax*4]
    mov     eax, HIT_OUTLINER
    jmp     .Lah_ret
.Lah_props:                             # (the physics panel: widgets now)
    mov     eax, -1
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
    jne     51f
    mov     edi, [r12+N_X]
    add     edi, TYPE_BTN_W+6
    mov     esi, [r12+N_Y]
    mov     edx, [r12+N_X]
    add     edx, [r12+N_W]
    sub     edx, 4*HDR_BTN_W+10
    call    vp_header_tools
    jmp     5f
51: cmp     eax, ED_TIMELINE            # the timeline: transport, range
    jne     53f
    mov     edi, [r12+N_X]
    add     edi, TYPE_BTN_W+6
    mov     esi, [r12+N_Y]
    mov     edx, [r12+N_X]
    add     edx, [r12+N_W]
    sub     edx, 4*HDR_BTN_W+10
    call    tl_header_tools
    jmp     5f
53: cmp     eax, ED_DOPESHEET           # the key editors: the key menu
    je      54f
    cmp     eax, ED_GRAPH
    jne     55f
54: mov     edi, [r12+N_X]
    add     edi, TYPE_BTN_W+6
    mov     esi, [r12+N_Y]
    mov     edx, [r12+N_X]
    add     edx, [r12+N_W]
    sub     edx, 4*HDR_BTN_W+10
    call    ae_header_tools
    jmp     5f
55: cmp     eax, ED_RENDER              # the Render area: Render, Stop, ...
    jne     56f
    mov     edi, [r12+N_X]
    add     edi, TYPE_BTN_W+6
    mov     esi, [r12+N_Y]
    mov     edx, [r12+N_X]
    add     edx, [r12+N_W]
    sub     edx, 4*HDR_BTN_W+10
    call    rn_header_tools
    jmp     5f
56: cmp     eax, ED_ASSETS              # the Asset Browser: search, kind, Save
    jne     57f
    mov     edi, [r12+N_X]
    add     edi, TYPE_BTN_W+6
    mov     esi, [r12+N_Y]
    mov     edx, [r12+N_X]
    add     edx, [r12+N_W]
    sub     edx, 4*HDR_BTN_W+10
    call    lb_header_tools
    jmp     5f
57: cmp     eax, ED_ACTIVITY            # AI Activity: permission, a proposal
    jne     58f
    mov     edi, [r12+N_X]
    add     edi, TYPE_BTN_W+6
    mov     esi, [r12+N_Y]
    mov     edx, [r12+N_X]
    add     edx, [r12+N_W]
    sub     edx, 4*HDR_BTN_W+10
    call    act_header_tools
    jmp     5f
58: cmp     eax, ED_UVED                # the UV editor: its tools
    jne     52f
    mov     edi, [r12+N_X]
    add     edi, TYPE_BTN_W+6
    mov     esi, [r12+N_Y]
    mov     edx, [r12+N_X]
    add     edx, [r12+N_W]
    sub     edx, 4*HDR_BTN_W+10
    call    uv_header_tools
    jmp     5f
52: cmp     eax, ED_NODES               # the node editor: its tree, New, Add
    jne     5f
    mov     edi, [r12+N_X]
    add     edi, TYPE_BTN_W+6
    mov     esi, [r12+N_Y]
    mov     edx, [r12+N_X]
    add     edx, [r12+N_W]
    sub     edx, 4*HDR_BTN_W+10
    call    ne_header_tools
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
    sub     rsp, 32
    call    tools_list                  # the mode's tools
    mov     r14, rax                    # entries
    mov     r15d, edx                   # count
    mov     dword ptr [rip+tools_sel], -1
    mov     r12d, [rip+ed_y]            # y
    add     r12d, 10
    xor     ebx, ebx
.Ltd_entry:
    cmp     ebx, r15d
    jae     .Ltd_done
    mov     r13, [r14+rbx*8]
    test    r13, r13                    # a gap
    jnz     1f
    add     r12d, 8
    jmp     .Ltd_next
1:  cmp     qword ptr [r13], 2          # a caption
    jne     2f
    mov     edi, [rip+ed_x]
    add     edi, 12
    lea     esi, [r12+5]
    mov     rdx, [r13+8]
    mov     ecx, COL_TEXT_DIM
    call    draw_small
    add     r12d, 28
    jmp     .Ltd_next
2:  lea     rdi, [rip+wd_tool_row]      # an operator: a row
    mov     esi, [rip+ed_x]
    add     esi, 8
    mov     edx, r12d
    mov     ecx, [rip+ed_w]
    sub     ecx, 16
    lea     r8, [rip+tools_sel]
    mov     r9d, ebx
    call    wg
    mov     rdi, r13
    call    wg_set_op
    mov     rdi, [r13+OP_LABEL]
    call    wg_set_label
    mov     dword ptr [rsp], COL_TEXT   # lit while it is the current one
    mov     dword ptr [rsp+4], COL_TEXT_DIM
    mov     rdi, r13
    call    op_checked
    cmp     eax, 1
    jne     3f
    mov     edi, [rip+ed_x]
    add     edi, 8
    mov     esi, r12d
    mov     edx, [rip+ed_w]
    sub     edx, 16
    mov     ecx, TOOL_BTN_H
    mov     r8d, COL_ACCENT
    mov     r9d, FIELD_R
    call    fill_rrect
    mov     dword ptr [rsp], COL_TEXT_DARK
    mov     dword ptr [rsp+4], COL_TEXT_DARK
    jmp     4f
3:  mov     rdi, r13                    # greyed when it cannot run now
    call    op_poll
    test    rax, rax
    jz      4f
    mov     dword ptr [rsp], COL_TEXT_OFF
    mov     dword ptr [rsp+4], COL_TEXT_OFF
4:  mov     rdi, r13                    # icon, label, shortcut
    call    tool_icon
    mov     edx, eax
    mov     edi, [rip+ed_x]
    add     edi, 13
    lea     esi, [r12+5]
    mov     r8d, [rsp]
    call    draw_icon
    mov     edi, [rip+ed_x]
    add     edi, 34
    lea     esi, [r12+5]
    mov     rdx, [r13+OP_LABEL]
    mov     ecx, [rsp]
    call    draw_text
    mov     [rsp+16], eax               # where the label ends
    mov     rdi, r13                    # (the key in use: prefs.s)
    call    key_eff
    mov     edi, eax
    call    fmt_key
    test    rax, rax
    jz      5f
    mov     [rsp+8], rax
    mov     rdi, rax
    call    text_width
    mov     edi, [rip+ed_x]
    add     edi, [rip+ed_w]
    sub     edi, 16
    sub     edi, eax
    mov     eax, [rsp+16]               # (no room: the tooltip has it)
    add     eax, 8
    cmp     edi, eax
    jl      5f
    lea     esi, [r12+5]
    mov     rdx, [rsp+8]
    mov     ecx, [rsp+4]
    call    draw_text
5:  add     r12d, TOOL_BTN_H+TOOL_BTN_GAP
.Ltd_next:
    inc     ebx
    jmp     .Ltd_entry
.Ltd_done:
    add     rsp, 32
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# tools_list -> rax = the Tools pane's entries for the mode, edx = count
tools_list:
    sub     rsp, 8
    lea     rax, [rip+tl_sketch]
    mov     edx, [rip+tl_sketch_c]
    cmp     dword ptr [rip+skm_obj], 0
    jne     9f
    lea     rax, [rip+tl_curve]
    mov     edx, [rip+tl_curve_c]
    cmp     dword ptr [rip+cve_obj], 0
    jne     9f
    lea     rax, [rip+tl_arm]
    mov     edx, [rip+tl_arm_c]
    cmp     dword ptr [rip+arm_mode], 0
    jne     9f
    lea     rax, [rip+tl_lsculpt]       # (a landscape: its brushes, paint)
    mov     edx, [rip+tl_lsculpt_c]
    cmp     dword ptr [rip+sc_land], 0
    jne     9f
    lea     rax, [rip+tl_sculpt]
    mov     edx, [rip+tl_sculpt_c]
    cmp     dword ptr [rip+sc_obj], 0
    jne     9f
    lea     rax, [rip+tl_paint]
    mov     edx, [rip+tl_paint_c]
    cmp     dword ptr [rip+pt_obj], 0
    jne     9f
    lea     rdi, [rip+op_wpaint_mode]
    call    op_checked
    lea     rcx, [rip+tl_wpaint]
    mov     edx, [rip+tl_wpaint_c]
    cmp     eax, 1
    mov     rax, rcx
    je      9f
    lea     rax, [rip+tl_edit]
    mov     edx, [rip+tl_edit_c]
    cmp     dword ptr [rip+edit_obj], 0
    jne     9f
    lea     rax, [rip+tl_object]
    mov     edx, [rip+tl_object_c]
9:  add     rsp, 8
    ret

# tool_icon(rdi=operator) -> eax = its icon (a dot when it has none)
tool_icon:
    lea     rcx, [rip+tool_icon_tab]
1:  mov     rdx, [rcx]
    test    rdx, rdx
    jz      2f
    cmp     rdx, rdi
    je      3f
    add     rcx, 16
    jmp     1b
2:  mov     eax, ICON_DOT
    ret
3:  mov     eax, [rcx+8]
    ret

# tools_cb(rdi=&tools_sel, esi=row) - run the row's operator
tools_cb:
    push    rsi
    call    tools_list
    pop     rsi
    mov     rdi, [rax+rsi*8]
    jmp     run_op_ui

ed_outliner_draw:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    sub     rsp, 16
    mov     eax, [rip+ed_x]             # (where its rows are: drag feedback)
    mov     [rip+outl_x0], eax
    mov     eax, [rip+ed_y]
    mov     [rip+outl_y0], eax
    mov     eax, [rip+ed_w]
    mov     [rip+outl_w0], eax
    call    outl_order                  # the tree's order (parent.s)
    xor     ebx, ebx                    # visible row
    mov     r15d, [rip+outl_scroll]     # objects to skip (scrolled past)
    mov     dword ptr [rsp+8], 0        # position in that order
    mov     dword ptr [rip+outl_rows], 0
    mov     dword ptr [rip+outl_eye_sel], -1
1:  mov     eax, [rsp+8]
    cmp     eax, [rip+po_n]
    jae     .Lod_done
    lea     rcx, [rip+po_ord]           # the object there, its depth
    mov     r13d, [rcx+rax*4]
    lea     rcx, [rip+po_dep]
    mov     ecx, [rcx+rax*4]
    imul    ecx, ecx, 14                # (indented: 14 a level, and room for
    cmp     dword ptr [rip+po_tree], 0  #  the fold arrows in a tree)
    je      11f
    add     ecx, 12
11: mov     [rsp+12], ecx
    test    r13d, 0x40000000            # a folder (parent.s OO_FOLDER)
    jnz     .Lod_folder
    mov     edi, r13d
    call    obj_at
    mov     r14, rax
    mov     rdi, r14                    # the filter: names containing it
    call    outl_match
    test    eax, eax
    jz      .Lod_next
    test    r15d, r15d
    jz      2f
    dec     r15d
    jmp     .Lod_next
2:  mov     edi, ebx
    call    row_y
    mov     r12d, eax
    mov     ecx, [rip+ed_y]
    add     ecx, [rip+ed_h]
    cmp     r12d, ecx
    jge     .Lod_done
    cmp     ebx, OUTL_MAXROWS
    jae     .Lod_done
    lea     rax, [rip+outl_map]         # this row is that object
    mov     [rax+rbx*4], r13d
    inc     dword ptr [rip+outl_rows]
    mov     r8d, COL_ACCENT_DARK
    test    dword ptr [r14+OB_FLAGS], OBF_SELECTED
    jnz     3f
    mov     edi, HIT_OUTLINER
    mov     esi, r13d
    call    is_hot
    test    eax, eax
    jz      4f
    mov     r8d, COL_HOVER
3:  mov     edi, [rip+ed_x]
    add     edi, 4
    mov     esi, r12d
    mov     edx, [rip+ed_w]
    sub     edx, 8
    mov     ecx, ROW_H
    call    fill_rect
4:  lea     rax, [rip+po_kids]          # a parent: its fold arrow
    cmp     dword ptr [rax+r13*4], 0
    je      41f
    lea     rdi, [rip+wd_outl_fold]
    mov     esi, [rip+ed_x]
    add     esi, [rsp+12]
    sub     esi, 10
    lea     edx, [r12-1]
    mov     ecx, 18
    lea     r8, [rip+outl_eye_sel]
    mov     r9d, r13d
    call    wg
    test    eax, eax
    jz      42f
    xor     dword ptr [r14+OB_FLAGS], OBF_COLLAPSED
    mov     dword ptr [rip+redraw_again], 1  # (while drawing: another frame)
42: mov     edi, [rip+ed_x]
    add     edi, [rsp+12]
    sub     edi, 9
    lea     esi, [r12+2]
    mov     edx, ICON_CHEVRON_DOWN
    test    dword ptr [r14+OB_FLAGS], OBF_COLLAPSED
    jz      43f
    mov     edx, ICON_CHEVRON_RIGHT
43: mov     r8d, COL_TEXT_DIM
    call    draw_icon
41: mov     edi, [rip+ed_x]             # its colour, its type
    add     edi, 14
    add     edi, [rsp+12]
    lea     esi, [r12+6]
    mov     edx, 8
    mov     ecx, 8
    mov     r8d, [r14+OB_COLOR]
    call    fill_rect
    mov     eax, [r14+OB_TYPE]
    cmp     eax, OT_FIELD
    jbe     5f
    xor     eax, eax
5:  lea     rcx, [rip+type_icons]
    mov     edx, [rcx+rax*4]
    mov     edi, [rip+ed_x]
    add     edi, 27
    add     edi, [rsp+12]
    lea     esi, [r12+2]
    mov     r8d, COL_TEXT_DIM
    call    draw_icon
    lea     rax, [rip+obj_list]         # being renamed: a text field
    mov     eax, [rax+r13*4]
    mov     [rsp], eax
    cmp     eax, [rip+outl_ren]
    jne     6f
    test    eax, eax
    jz      6f
    lea     rdi, [rip+wd_outl_name]
    mov     esi, [rip+ed_x]
    add     esi, 46
    add     esi, [rsp+12]
    lea     edx, [r12-1]
    mov     ecx, [rip+ed_w]
    sub     ecx, 128
    mov     r8, r14
    xor     r9d, r9d
    call    wg
    cmp     dword ptr [rip+outl_ren_go], 0
    je      7f
    mov     dword ptr [rip+outl_ren_go], 0
    call    wg_edit_last
    jmp     7f
6:  mov     ecx, COL_TEXT               # its name: the active one in gold,
    mov     eax, [rsp]                  #  a hidden one dimmed
    cmp     eax, [rip+active_obj]
    jne     61f
    mov     ecx, COL_ACTIVE
61: test    dword ptr [r14+OB_FLAGS], OBF_HIDDEN
    jz      62f
    mov     ecx, COL_TEXT_OFF
62: mov     edi, [rip+ed_x]
    add     edi, 48
    add     edi, [rsp+12]
    lea     esi, [r12+2]
    mov     rdx, r14
    call    draw_text
7:  lea     rdi, [rip+wd_outl_eye]      # the eye: shown / hidden
    mov     esi, [rip+ed_x]
    add     esi, [rip+ed_w]
    sub     esi, 30
    lea     edx, [r12-1]
    mov     ecx, 22
    lea     r8, [rip+outl_eye_sel]
    mov     r9d, r13d
    call    wg
    mov     edi, [rip+ed_x]
    add     edi, [rip+ed_w]
    sub     edi, 27
    lea     esi, [r12+2]
    mov     edx, ICON_EYE
    mov     r8d, COL_TEXT_DIM
    test    dword ptr [r14+OB_FLAGS], OBF_HIDDEN
    jz      8f
    mov     edx, ICON_EYE_OFF
    mov     r8d, COL_TEXT_OFF
8:  call    draw_icon
    lea     rdi, [rip+wd_outl_cam]      # the camera: rendered / left out
    mov     esi, [rip+ed_x]
    add     esi, [rip+ed_w]
    sub     esi, 54
    lea     edx, [r12-1]
    mov     ecx, 22
    lea     r8, [rip+outl_eye_sel]
    mov     r9d, r13d
    call    wg
    mov     edi, [rip+ed_x]
    add     edi, [rip+ed_w]
    sub     edi, 51
    lea     esi, [r12+2]
    mov     edx, ICON_RENDER_ON
    mov     r8d, COL_TEXT_DIM
    test    dword ptr [r14+OB_FLAGS], OBF_NORENDER
    jz      81f
    mov     edx, ICON_CAMERA
    mov     r8d, COL_TEXT_OFF
81: call    draw_icon
    lea     rdi, [rip+wd_outl_lock]     # the lock
    mov     esi, [rip+ed_x]
    add     esi, [rip+ed_w]
    sub     esi, 78
    lea     edx, [r12-1]
    mov     ecx, 22
    lea     r8, [rip+outl_eye_sel]
    mov     r9d, r13d
    call    wg
    mov     edi, [rip+ed_x]
    add     edi, [rip+ed_w]
    sub     edi, 75
    lea     esi, [r12+2]
    mov     edx, ICON_UNLOCK
    mov     r8d, COL_TEXT_OFF
    test    dword ptr [r14+OB_FLAGS], OBF_LOCKED
    jz      82f
    mov     edx, ICON_LOCK
    mov     r8d, COL_TEXT_DIM
82: call    draw_icon
    inc     ebx
.Lod_next:
    inc     dword ptr [rsp+8]
    jmp     1b
.Lod_folder:                            # ---- a folder's row ----
    test    r15d, r15d
    jz      21f
    dec     r15d
    jmp     .Lod_next
21: mov     edi, ebx
    call    row_y
    mov     r12d, eax
    mov     ecx, [rip+ed_y]
    add     ecx, [rip+ed_h]
    cmp     r12d, ecx
    jge     .Lod_done
    cmp     ebx, OUTL_MAXROWS
    jae     .Lod_done
    lea     rax, [rip+outl_map]         # (not an object: its widgets take
    mov     dword ptr [rax+rbx*4], -1   #  the clicks)
    inc     dword ptr [rip+outl_rows]
    and     r13d, 0xffff
    mov     edi, r13d
    call    fd_rec
    test    rax, rax
    jz      .Lod_fnext
    mov     r14, rax
    mov     eax, [r14]                  # the folder picked: lit
    cmp     eax, [rip+fd_active]
    jne     22f
    mov     edi, [rip+ed_x]
    add     edi, 4
    mov     esi, r12d
    mov     edx, [rip+ed_w]
    sub     edx, 8
    mov     ecx, ROW_H
    mov     r8d, COL_ACCENT_DARK
    call    fill_rect
22: lea     rdi, [rip+wd_outl_frow]     # the row: pick it (its objects
    mov     esi, [rip+ed_x]             #  selected), twice: rename it
    add     esi, 4
    add     esi, [rsp+12]
    add     esi, 10
    lea     edx, [r12-1]
    mov     ecx, [rip+ed_w]
    sub     ecx, 96
    sub     ecx, [rsp+12]
    lea     r8, [rip+outl_fsel]
    mov     dword ptr [r8], -1
    mov     r9d, r13d
    call    wg
    lea     rdi, [r14+16]               # (FR_NAME, for ui_tree)
    call    wg_set_label
    lea     rdi, [rip+wd_outl_ffold]    # its fold arrow
    mov     esi, [rip+ed_x]
    add     esi, [rsp+12]
    sub     esi, 10
    lea     edx, [r12-1]
    mov     ecx, 18
    xor     r8d, r8d
    mov     r9d, r13d
    call    wg
    test    eax, eax
    jz      23f
    mov     edi, r13d
    mov     esi, 1
    call    fd_toggle
    mov     dword ptr [rip+redraw_again], 1
    jmp     .Lod_fnext                  # (the block may have moved)
23: mov     edi, [rip+ed_x]
    add     edi, [rsp+12]
    sub     edi, 9
    lea     esi, [r12+2]
    mov     edx, ICON_CHEVRON_DOWN
    test    dword ptr [r14+8], 1        # (FR_FLG 1: folded)
    jz      24f
    mov     edx, ICON_CHEVRON_RIGHT
24: mov     r8d, COL_TEXT_DIM
    call    draw_icon
    mov     edi, [rip+ed_x]             # its icon
    add     edi, 14
    add     edi, [rsp+12]
    lea     esi, [r12+2]
    mov     edx, ICON_FOLDER
    mov     r8d, COL_ACCENT
    call    draw_icon
    lea     eax, [r13+1]                # being renamed: a text field
    cmp     eax, [rip+outl_fren]
    jne     25f
    lea     rdi, [rip+wd_outl_fname]
    mov     esi, [rip+ed_x]
    add     esi, 34
    add     esi, [rsp+12]
    lea     edx, [r12-1]
    mov     ecx, [rip+ed_w]
    sub     ecx, 128
    lea     r8, [rip+outl_fname]
    xor     r9d, r9d
    call    wg
    cmp     dword ptr [rip+outl_fren_go], 0
    je      26f
    mov     dword ptr [rip+outl_fren_go], 0
    call    wg_edit_last
    jmp     26f
25: mov     edi, [rip+ed_x]             # its name
    add     edi, 36
    add     edi, [rsp+12]
    lea     esi, [r12+2]
    lea     rdx, [r14+16]
    mov     ecx, COL_TEXT
    call    draw_text
26: xor     ecx, ecx                    # its eye, camera, lock (for all inside)
27: mov     [rsp], ecx
    lea     rax, [rip+fd_toggles]
    mov     rdi, [rax+rcx*8]
    mov     esi, [rip+ed_x]
    add     esi, [rip+ed_w]
    imul    eax, ecx, 24
    sub     esi, 30
    sub     esi, eax
    lea     edx, [r12-1]
    mov     ecx, 22
    xor     r8d, r8d
    mov     r9d, r13d
    call    wg
    test    eax, eax
    jz      28f
    lea     rdi, [rip+s_u_folder]
    call    undo_push
    mov     ecx, [rsp]
    mov     esi, 2
    shl     esi, cl
    mov     edi, r13d
    call    fd_toggle
    mov     dword ptr [rip+redraw_again], 1
    jmp     .Lod_fnext
28: mov     ecx, [rsp]
    mov     edi, [rip+ed_x]
    add     edi, [rip+ed_w]
    imul    eax, ecx, 24
    sub     edi, 27
    sub     edi, eax
    lea     esi, [r12+2]
    mov     eax, 2
    shl     eax, cl
    lea     rdx, [rip+fd_icons]         # on (the flag set) / off
    lea     rdx, [rdx+rcx*8]
    mov     r8d, COL_TEXT_DIM
    test    [r14+8], eax
    jz      29f
    add     rdx, 4
    mov     r8d, COL_TEXT_OFF
29: mov     edx, [rdx]
    call    draw_icon
    mov     ecx, [rsp]
    inc     ecx
    cmp     ecx, 3
    jb      27b
.Lod_fnext:
    inc     ebx
    jmp     .Lod_next
.Lod_done:
    lea     rdi, [rip+wd_outl_filter]   # the filter, at the bottom
    mov     esi, [rip+ed_x]
    add     esi, 6
    mov     edx, [rip+ed_y]
    add     edx, [rip+ed_h]
    sub     edx, WG_H+4
    mov     ecx, [rip+ed_w]
    sub     ecx, 12+32
    lea     r8, [rip+outl_filter]
    xor     r9d, r9d
    call    wg
    cmp     byte ptr [rip+outl_filter], 0
    jne     .Lod_ren
    call    wg_editing                  # (a hint while it is empty)
    test    eax, eax
    jnz     .Lod_ren
    mov     edi, [rip+ed_x]
    add     edi, 14
    mov     esi, [rip+ed_y]
    add     esi, [rip+ed_h]
    sub     esi, WG_H+1
    lea     rdx, [rip+s_filter_hint]
    mov     ecx, COL_TEXT_OFF
    call    draw_small
    lea     rdi, [rip+wd_outl_fnew]     # + a folder (the selection into it)
    mov     esi, [rip+ed_x]
    add     esi, [rip+ed_w]
    sub     esi, 34
    mov     edx, [rip+ed_y]
    add     edx, [rip+ed_h]
    sub     edx, WG_H+4
    mov     ecx, 28
    xor     r8d, r8d
    xor     r9d, r9d
    call    wg
.Lod_ren:
    cmp     dword ptr [rip+outl_fren], 0  # a folder's rename that ended: done
    je      91f
    cmp     dword ptr [rip+outl_fren_go], 0
    jne     91f
    call    wg_editing
    test    eax, eax
    jnz     91f
    mov     dword ptr [rip+outl_fren], 0
91: cmp     dword ptr [rip+outl_ren], 0 # a rename that ended: done
    je      9f
    cmp     dword ptr [rip+outl_ren_go], 0
    jne     9f
    call    wg_editing
    test    eax, eax
    jnz     9f
    mov     dword ptr [rip+outl_ren], 0
9:  add     rsp, 16
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# outl_toggle(edi=object index) - Ctrl+click: selected or not, the others
#   kept (selected: it becomes the active one)
.globl outl_toggle
outl_toggle:
    push    rbx
    mov     ebx, edi
    call    obj_at
    xor     dword ptr [rax+OB_FLAGS], OBF_SELECTED
    lea     rcx, [rip+obj_list]
    mov     ecx, [rcx+rbx*4]
    test    dword ptr [rax+OB_FLAGS], OBF_SELECTED
    jz      1f
    mov     [rip+active_obj], ecx
    jmp     9f
1:  cmp     ecx, [rip+active_obj]
    jne     9f
    mov     dword ptr [rip+active_obj], 0
9:  mov     dword ptr [rip+dirty], 1
    pop     rbx
    ret

# outl_frow_cb(rdi, esi=folder index) - a click picks the folder and selects
#   what is in it; a second click on it within 400 ms renames it
outl_frow_cb:
    push    rbx
    push    r12
    sub     rsp, 8
    mov     ebx, esi
    call    mono_ns
    mov     r12, rax
    cmp     ebx, [rip+outl_fclick]
    jne     1f
    sub     rax, [rip+outl_fclick_t]
    cmp     rax, 400000000
    ja      1f
    mov     dword ptr [rip+outl_fclick], -1
    mov     edi, ebx                    # rename: the field with its name
    call    fd_rec
    test    rax, rax
    jz      9f
    lea     rsi, [rax+16]
    lea     rdi, [rip+outl_fname]
    mov     ecx, 32
    rep     movsb
    lea     eax, [rbx+1]
    mov     [rip+outl_fren], eax
    mov     dword ptr [rip+outl_fren_go], 1
    jmp     9f
1:  mov     [rip+outl_fclick], ebx
    mov     [rip+outl_fclick_t], r12
    mov     edi, ebx
    call    fd_rec
    test    rax, rax
    jz      9f
    mov     edi, [rax]
    mov     [rip+fd_active], edi
    call    fd_select
9:  mov     dword ptr [rip+dirty], 1
    add     rsp, 8
    pop     r12
    pop     rbx
    ret

# outl_fren_cb(rdi=the name typed) - the folder renamed (its own undo step)
outl_fren_cb:
    push    rbx
    mov     rbx, rdi
    mov     edi, [rip+outl_fren]
    dec     edi
    js      9f
    call    fd_rec
    test    rax, rax
    jz      9f
    mov     eax, [rax]
    mov     [rip+fd_active], eax
    mov     rax, rbx
    lea     rdi, [rip+op_fd_ren]
    call    run_with_arg
9:  mov     dword ptr [rip+outl_fren], 0
    pop     rbx
    ret

# outl_drag_draw - while an outliner row is dragged: the row or folder that
#   would take it lit, and at the pointer a label: what is dragged, and what
#   letting go does there
.globl outl_drag_draw
outl_drag_draw:
    cmp     dword ptr [rip+drag_mode], DRAG_OUTL
    jne     9f
    cmp     dword ptr [rip+outl_dragging], 0
    je      9f
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    sub     rsp, 16
    call    reset_clip
    mov     edi, [rip+outl_drag]        # the one dragged
    call    obj_at
    test    rax, rax
    jz      .Lodd_out
    mov     rbx, rax
    xor     r12d, r12d                  # the others selected with it
    xor     ecx, ecx
1:  cmp     ecx, [rip+obj_count]
    jae     2f
    push    rcx
    push    rcx
    mov     edi, ecx
    call    obj_at
    pop     rcx
    pop     rcx
    inc     ecx
    test    dword ptr [rax+OB_FLAGS], OBF_SELECTED
    jz      1b
    cmp     rax, rbx
    je      1b
    inc     r12d
    jmp     1b
2:  lea     r14, [rip+s_dg_out]         # r14 = the line saying what happens
    xor     r15d, r15d                  # (0: nothing; 1: into a folder)
    call    outl_drop_folder            # a folder row: lit, "Into it"
    test    eax, eax
    js      3f
    mov     edi, eax
    call    fd_rec
    test    rax, rax
    jz      3f
    lea     r13, [rax+16]               # (its name)
    mov     edi, [rip+ptr_x]
    mov     esi, [rip+ptr_y]
    call    wg_hit
    mov     edi, eax
    call    wg_find
    test    rax, rax
    jz      3f
    mov     edi, [rax+8]                # (E_X, E_Y, E_W, E_H)
    sub     edi, 4
    mov     esi, [rax+12]
    mov     edx, [rax+16]
    add     edx, 4
    mov     ecx, [rax+20]
    call    drag_box
    call    fmt_reset
    lea     rdi, [rip+s_dg_into]
    call    fmt_str
    mov     rdi, r13
    call    fmt_str
    lea     r14, [rip+fmt_buf]
    mov     r15d, 1
    jmp     5f
3:  mov     edi, [rip+ptr_x]            # an object's row: "Child of it"
    mov     esi, [rip+ptr_y]
    call    hit_test
    cmp     eax, HIT_OUTLINER
    jne     4f
    test    edx, edx
    js      4f
    cmp     edx, [rip+outl_drag]
    je      41f
    mov     r13d, edx
    xor     ecx, ecx                    # its row
31: cmp     ecx, [rip+outl_rows]
    jae     41f
    lea     rax, [rip+outl_map]
    cmp     [rax+rcx*4], r13d
    je      32f
    inc     ecx
    jmp     31b
32: mov     esi, ecx
    imul    esi, ROW_H
    add     esi, [rip+outl_y0]
    add     esi, 4
    mov     edi, [rip+outl_x0]
    add     edi, 4
    mov     edx, [rip+outl_w0]
    sub     edx, 8
    mov     ecx, ROW_H
    call    drag_box
    mov     edi, r13d
    call    obj_at
    mov     r13, rax
    call    fmt_reset
    lea     rdi, [rip+s_dg_child]
    call    fmt_str
    mov     rdi, r13
    call    fmt_str
    lea     rdi, [rip+fmt_buf]          # (a copy: the name line uses fmt_buf)
    lea     rsi, [rip+outl_ghost+64]
    xchg    rdi, rsi
    mov     ecx, 63
    rep     movsb
    mov     byte ptr [rdi], 0
    lea     r14, [rip+outl_ghost+64]
    jmp     5f
41: xor     r14d, r14d                  # (onto itself: nothing)
    jmp     5f
4:  mov     edi, [rip+hit_area]         # the outliner's empty part: "No parent,
    test    edi, edi                    #  no folder"; elsewhere nothing
    js      41b
    call    area_editor
    cmp     eax, ED_OUTLINER
    jne     41b
5:  lea     rax, [rip+fmt_buf]          # (keep the action across the name line)
    cmp     r14, rax
    jne     51f
    lea     rdi, [rip+outl_ghost+64]    # the action out of fmt_buf
    mov     rsi, rax
    mov     ecx, 63
    rep     movsb
    mov     byte ptr [rdi], 0
    lea     r14, [rip+outl_ghost+64]
51: call    fmt_reset                   # the name line: "Ball and 2 more"
    mov     rdi, rbx
    call    fmt_str
    test    r15d, r15d
    jz      52f
    test    r12d, r12d
    jz      52f
    lea     rdi, [rip+s_dg_more]
    call    fmt_str
    mov     edi, r12d
    call    fmt_int
    lea     rdi, [rip+s_dg_more2]
    call    fmt_str
52: lea     rdi, [rip+outl_ghost]
    lea     rsi, [rip+fmt_buf]
    mov     ecx, 63
    rep     movsb
    mov     byte ptr [rdi], 0
    lea     rdi, [rip+outl_ghost]       # the label's width
    call    text_width
    mov     r13d, eax
    test    r14, r14
    jz      53f
    mov     rdi, r14
    call    text_width_small
    cmp     eax, r13d
    cmova   r13d, eax
53: add     r13d, 40
    mov     edi, [rip+ptr_x]            # the label, below right of the pointer
    add     edi, 16
    mov     esi, [rip+ptr_y]
    add     esi, 14
    mov     edx, r13d
    mov     ecx, 26
    test    r14, r14
    jz      54f
    mov     ecx, 42
54: mov     r8d, COL_ACCENT
    call    popup_frame
    mov     eax, [rbx+OB_TYPE]          # its type's icon, its name
    cmp     eax, OT_FIELD
    jbe     55f
    xor     eax, eax
55: lea     rcx, [rip+type_icons]
    mov     edx, [rcx+rax*4]
    mov     edi, [rip+ptr_x]
    add     edi, 24
    mov     esi, [rip+ptr_y]
    add     esi, 18
    mov     r8d, COL_ACCENT
    call    draw_icon
    mov     edi, [rip+ptr_x]
    add     edi, 46
    mov     esi, [rip+ptr_y]
    add     esi, 18
    lea     rdx, [rip+outl_ghost]
    mov     ecx, COL_TEXT
    call    draw_text
    test    r14, r14
    jz      .Lodd_out
    mov     edi, [rip+ptr_x]
    add     edi, 46
    mov     esi, [rip+ptr_y]
    add     esi, 38
    mov     rdx, r14
    mov     ecx, COL_TEXT_DIM
    call    draw_small
.Lodd_out:
    add     rsp, 16
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
9:  ret

# drag_box(edi=x, esi=y, edx=w, ecx=h) - a drop target: two accent frames
drag_box:
    push    rbx
    push    r12
    push    r13
    push    r14
    sub     rsp, 8
    mov     ebx, edi
    mov     r12d, esi
    mov     r13d, edx
    mov     r14d, ecx
    mov     r8d, COL_ACCENT
    call    rect_outline
    lea     edi, [rbx+1]
    lea     esi, [r12+1]
    lea     edx, [r13-2]
    lea     ecx, [r14-2]
    mov     r8d, COL_ACCENT
    call    rect_outline
    add     rsp, 8
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# outl_drop_folder -> eax = the folder index under the pointer (a folder row),
#   -1 none
outl_drop_folder:
    sub     rsp, 8
    mov     edi, [rip+ptr_x]
    mov     esi, [rip+ptr_y]
    call    wg_hit
    test    eax, eax
    jz      8f
    mov     edi, eax
    call    wg_find
    test    rax, rax
    jz      8f
    lea     rcx, [rip+wd_outl_frow]
    cmp     [rax+32], rcx               # (E_DESC)
    jne     8f
    mov     eax, [rax+40]               # (E_SUB: the folder's index)
    add     rsp, 8
    ret
8:  mov     eax, -1
    add     rsp, 8
    ret

# outl_drop - an outliner row dragged and let go: onto another row, it
#   becomes that object's child; onto the outliner's empty part, it has no
#   parent any more (one undo step; it stays where it is)
.globl outl_drop
.globl outl_drag
.globl outl_dragging
outl_drop:
    push    rbx
    push    r12
    sub     rsp, 8
    mov     dword ptr [rip+drag_mode], 0
    cmp     dword ptr [rip+outl_dragging], 0
    je      9f
    mov     dword ptr [rip+outl_dragging], 0
    mov     dword ptr [rip+dirty], 1
    call    outl_drop_folder            # onto a folder: the selection in it
    test    eax, eax
    js      60f
    mov     edi, eax
    call    fd_rec
    test    rax, rax
    jz      9f
    mov     eax, [rax]
    push    rax
    push    rax
    lea     rdi, [rip+s_u_folder]
    call    undo_push
    pop     rax
    pop     rax
    xor     ebx, ebx
61: cmp     ebx, [rip+obj_count]
    jae     9f
    push    rax
    push    rax
    mov     edi, ebx
    call    obj_at
    mov     rdi, rax
    pop     rsi
    pop     rsi
    push    rsi
    push    rsi
    inc     ebx
    test    dword ptr [rdi+OB_FLAGS], OBF_SELECTED
    jz      62f
    call    fd_set_obj
62: pop     rax
    pop     rax
    jmp     61b
60: mov     edi, [rip+ptr_x]
    mov     esi, [rip+ptr_y]
    call    hit_test
    mov     ebx, edx
    cmp     eax, HIT_OUTLINER
    je      1f
    mov     edi, [rip+hit_area]         # the outliner, not on a row: no parent
    test    edi, edi
    js      9f
    call    area_editor
    cmp     eax, ED_OUTLINER
    jne     9f
    lea     rdi, [rip+s_u_parent]
    call    undo_push
    mov     edi, [rip+outl_drag]
    call    obj_at
    mov     dword ptr [rax+OB_FOLDER], 0    # (and out of its folder)
    mov     rdi, rax
    xor     esi, esi
    call    par_set
    jmp     9f
1:  cmp     ebx, [rip+outl_drag]        # onto another row: under it
    je      9f
    lea     rdi, [rip+s_u_parent]
    call    undo_push
    mov     edi, ebx
    call    obj_at
    mov     r12, rax
    mov     edi, [rip+outl_drag]
    call    obj_at
    mov     rdi, rax
    mov     rsi, r12
    call    par_set
    test    eax, eax
    jnz     9f
    call    undo_drop_last              # (its own descendant: no)
    lea     rdi, [rip+s_par_loop]
    call    log_line
9:  add     rsp, 8
    pop     r12
    pop     rbx
    ret

# outl_range(edi=object index) - Shift+click: the rows from the active one to
#   this one (those the filter shows), the clicked one active
.globl outl_range
outl_range:
    push    rbx
    push    r12
    push    r13
    push    r14
    sub     rsp, 8
    mov     [rsp], edi                  # clicked
    mov     r12d, edi
    mov     r13d, edi                   # the active one's index (else itself)
    xor     ebx, ebx
1:  cmp     ebx, [rip+obj_count]
    jae     2f
    lea     rax, [rip+obj_list]
    mov     eax, [rax+rbx*4]
    cmp     eax, [rip+active_obj]
    jne     11f
    mov     r13d, ebx
    jmp     2f
11: inc     ebx
    jmp     1b
2:  cmp     r13d, r12d                  # lo .. hi
    jle     3f
    xchg    r13d, r12d
3:  call    select_none
    mov     ebx, r13d
4:  cmp     ebx, r12d
    jg      5f
    mov     edi, ebx
    call    obj_at
    mov     r14, rax
    mov     rdi, rax
    call    outl_match
    test    eax, eax
    jz      41f
    or      dword ptr [r14+OB_FLAGS], OBF_SELECTED
41: inc     ebx
    jmp     4b
5:  mov     eax, [rsp]              # the clicked one: active
    lea     rcx, [rip+obj_list]
    mov     eax, [rcx+rax*4]
    mov     [rip+active_obj], eax
    mov     dword ptr [rip+dirty], 1
    add     rsp, 8
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# outl_match(rdi=object) -> eax = 1 if its name contains the filter text
#   (any case; an empty filter takes all)
outl_match:
    lea     rsi, [rip+outl_filter]
    cmp     byte ptr [rsi], 0
    je      8f
1:  xor     ecx, ecx                    # does the filter start here?
2:  movzx   eax, byte ptr [rsi+rcx]
    test    eax, eax
    jz      8f
    movzx   edx, byte ptr [rdi+rcx]
    test    edx, edx
    jz      9f
    or      eax, 0x20
    or      edx, 0x20
    cmp     eax, edx
    jne     3f
    inc     ecx
    jmp     2b
3:  inc     rdi
    cmp     byte ptr [rdi], 0
    jne     1b
9:  xor     eax, eax
    ret
8:  mov     eax, 1
    ret

# outl_eye_cb(rdi=ptr, esi=object index) - show / hide it (one undo step)
outl_eye_cb:
    push    rbx
    mov     ebx, esi
    lea     rdi, [rip+s_u_hide]
    call    undo_push
    mov     edi, ebx
    call    obj_at
    xor     dword ptr [rax+OB_FLAGS], OBF_HIDDEN
    test    dword ptr [rax+OB_FLAGS], OBF_HIDDEN
    jz      9f
    and     dword ptr [rax+OB_FLAGS], ~OBF_SELECTED   # (hidden: not selected)
9:  pop     rbx
    ret

# outl_cam_cb / outl_lock_cb(rdi=ptr, esi=object index) - renders leave it
#   out / clicks in the viewport pass through it (one undo step each)
outl_cam_cb:
    mov     ecx, OBF_NORENDER
    lea     rdi, [rip+s_u_render]
    jmp     outl_flag
outl_lock_cb:
    mov     ecx, OBF_LOCKED
    lea     rdi, [rip+s_u_lock]
outl_flag:
    push    rbx
    push    r12
    sub     rsp, 8
    mov     ebx, esi
    mov     r12d, ecx
    call    undo_push
    mov     edi, ebx
    call    obj_at
    xor     [rax+OB_FLAGS], r12d
    mov     dword ptr [rip+dirty], 1
    add     rsp, 8
    pop     r12
    pop     rbx
    ret

outl_name_cb:                           # rdi = the new name
    mov     rsi, rdi
    mov     edi, [rip+outl_ren]
    jmp     obj_rename

# outl_rename(edi=object handle) - its outliner row becomes a text field
#   (no outliner on screen: the Properties name field)
outl_rename:
    push    rbx
    mov     ebx, edi
    test    ebx, ebx
    jz      9f
    mov     edi, ED_OUTLINER
    call    op_has_editor
    test    eax, eax
    jz      1f
    mov     [rip+outl_ren], ebx
    mov     dword ptr [rip+outl_ren_go], 1
    mov     dword ptr [rip+dirty], 1
    jmp     9f
1:  mov     edi, ebx                    # (Properties: it must be the active one)
    mov     [rip+active_obj], edi
    lea     rdi, [rip+s_obj_name_w]
    call    wg_edit_named
9:  pop     rbx
    ret

do_rename:                              # F2: the active object
    mov     edi, [rip+active_obj]
    jmp     outl_rename

# outl_filter_cb(rdi=typed text)
outl_filter_cb:
    mov     rsi, rdi
    lea     rdi, [rip+outl_filter]
    mov     dword ptr [rip+outl_scroll], 0
    xor     ecx, ecx
1:  mov     al, [rsi+rcx]
    mov     [rdi+rcx], al
    test    al, al
    jz      2f
    inc     ecx
    cmp     ecx, 31
    jb      1b
    mov     byte ptr [rdi+rcx], 0
2:  ret

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
1:  cmp     eax, PTAB_N-1               # Landscape: while one is active
    jne     2f
    call    land_is_active
    mov     ecx, eax
    mov     eax, PTAB_N-1
    test    rcx, rcx
    jnz     2f
    xor     eax, eax
2:  lea     rcx, [rip+props_pages]
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
    mov     eax, [rbx+OB_COLOR]         # its colour: a swatch (the picker)
    lea     rdi, [rip+props_objc]
    call    cpk_put
    lea     rdi, [rip+wd_obj_color]
    lea     r8, [rip+props_objc]
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
    mov     rdi, rbx                    # its parent (parent.s)
    call    par_props_row
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
113:mov     rdi, rbx                    # a curve: its values
    call    curve_props
    mov     rdi, rbx                    # a light / camera: its settings
    call    lcam_props
    test    dword ptr [rbx+OB_FLAGS], OBF_REFIMG  # a reference image: its own
    jz      114f
    mov     edi, r12d
    mov     rsi, rbx
    call    ref_props
    mov     r12d, eax
    add     r12d, 6
114:mov     edi, r12d                   # a text object: its text (textui.s)
    mov     rsi, rbx
    call    tx_props
    mov     r12d, eax
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
    add     r12d, 12
    mov     edi, [rip+active_obj]       # its Print Check findings (printui.s)
    call    obj_get
    test    rax, rax
    jz      .Lpp_done
    mov     rdi, rax
    call    print_props
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
    mov     edi, eax                    # cloth, wind, joints, the cache
    call    sim_props
    mov     r12d, eax
    jmp     .Lpp_done
.Lpp_cad:
    mov     edi, r12d
    call    cadui_props
    mov     r12d, eax
    jmp     .Lpp_done
.Lpp_scene:
    call    props_scene
    jmp     .Lpp_done
.Lpp_render:
    call    props_render
    jmp     .Lpp_done
.Lpp_anim:
    mov     edi, r12d
    call    animui_props
    mov     r12d, eax
    jmp     .Lpp_done
.Lpp_rig:
    mov     edi, r12d
    call    rigui_props
    mov     r12d, eax
    jmp     .Lpp_done
.Lpp_land:
    mov     edi, r12d
    call    land_props
    mov     r12d, eax
    jmp     .Lpp_done
.Lpp_part:
    mov     edi, r12d
    call    part_props
    mov     r12d, eax
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
    cmp     ebx, PTAB_N-1               # (Landscape: only for a landscape)
    jne     11f
    call    land_is_active
    test    rax, rax
    jz      9f
11: lea     rax, [rip+ptab_descs]
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
    call    world_sky_row               # the world: sky or HDRI, strength, turn
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
    call    images_props
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
    call    render_more                 # bounces, the GPU, the engine panels
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

props_objc_cb:                          # rdi = &props_objc: the colour picked
    push    rbx
    call    cpk_rgb_of
    mov     ebx, eax
    mov     edi, [rip+active_obj]
    call    obj_get
    test    rax, rax
    jz      8f
    mov     [rax+OB_COLOR], ebx
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
    jmp     th_choose

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
vp_shade_lbl:   .quad s_sh_solid, s_sh_wire, s_sh_mat, s_sh_rend
s_sh_solid:     .asciz "Solid"
s_sh_wire:      .asciz "Wireframe"
s_sh_mat:       .asciz "Material Preview"
s_sh_rend:      .asciz "Rendered"
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
props_objc:     .skip 12                # the object colour, linear (the swatch)
props_arg:      .skip 64
.section .rodata
s_p_color:      .asciz "Colour"
s_pg_scene:     .asciz "Scene"
s_pg_render:    .asciz "Render"
s_u_mm:         .asciz "Millimetres"
s_u_cm:         .asciz "Centimetres"
s_u_m:          .asciz "Metres"
s_u_in:         .asciz "Inches"
k_u_mm:         .asciz "mm"
k_u_cm:         .asciz "cm"
k_u_m:          .asciz "m"
k_u_in:         .asciz "in"
.align 8
fd_toggles:     .quad wd_outl_feye, wd_outl_fcam, wd_outl_flock
fd_icons:       .long ICON_EYE, ICON_EYE_OFF, ICON_RENDER_ON, ICON_CAMERA, ICON_UNLOCK, ICON_LOCK
.align 4
unit_mm_tab:    .float 1.0, 10.0, 1000.0, 25.4
ptab_icons:     .long ICON_OBJECT, ICON_MODIFIER, ICON_MATERIAL, ICON_PHYSICS, ICON_SKETCH
                .long ICON_WORLD, ICON_RENDERED, ICON_WIRE, ICON_KEY, ICON_ARMATURE, ICON_SPARKLE, ICON_GRID
.align 8
unit_lbl:       .quad s_u_mm, s_u_cm, s_u_m, s_u_in
unit_kw:        .quad k_u_mm, k_u_cm, k_u_m, k_u_in
ptab_descs:     .quad wd_pt0, wd_pt1, wd_pt2, wd_pt3, wd_pt4, wd_pt5, wd_pt6, wd_pt7, wd_pt8, wd_pt9, wd_pt11, wd_pt10
props_pages:    .quad .Lpp_object, .Lpp_mods, .Lpp_mat, .Lpp_phys, .Lpp_cad, .Lpp_scene, .Lpp_render, .Lpp_view
                .quad .Lpp_anim, .Lpp_rig, .Lpp_part, .Lpp_land
.text
WIDGET wd_pt0, WK_ROW, "props.tab.object", "Object", tip="Name, place, rotation, size, visibility and colour of the active object"
WIDGET wd_pt1, WK_ROW, "props.tab.modifiers", "Modifiers", tip="The modifier stack: mirror, array, subdivision, booleans, geometry nodes ..."
WIDGET wd_pt2, WK_ROW, "props.tab.material", "Material", tip="The object's material: colour, roughness, metal, emission, textures"
WIDGET wd_pt3, WK_ROW, "props.tab.physics", "Physics", tip="Rigid bodies, joints, shatter, cloth, the physics world and the simulation cache"
WIDGET wd_pt4, WK_ROW, "props.tab.cad", "CAD", tip="Parameters and the features of parts"
WIDGET wd_pt5, WK_ROW, "props.tab.scene", "Scene", tip="Units, the world's light and the frame range"
WIDGET wd_pt6, WK_ROW, "props.tab.render", "Render", tip="Render size, samples and denoising, Render and Save"
WIDGET wd_pt7, WK_ROW, "props.tab.viewport", "Viewport", tip="Shading, grid, theme and the viewport camera"
WIDGET wd_pt8, WK_ROW, "props.tab.animation", "Animation", tip="Shape keys, actions and layers, drivers, onion skins, motion paths"
WIDGET wd_pt11, WK_ROW, "props.tab.particles", "Particles", tip="Particle systems on the active object: emission, motion, look, collisions, liquid, the cache"
WIDGET wd_pt10, WK_ROW, "props.tab.landscape", "Landscape", tip="The landscape's size, layers, paint, sea and files"
WIDGET wd_pt9, WK_ROW, "props.tab.rig", "Rig", tip="Bones and their pose, constraints, parenting to an armature"
WIDGET wd_props_scroll, WK_SCROLL, "props.page"
WIDGET wd_obj_vis,   WK_TOGGLE, "object.visible", "Visible", cb=props_vis_cb, undo="Hide", tip="Show or hide the object (H hides the selection, Alt+H shows all)"
WIDGET wd_obj_color, WK_COLOR, "object.color", cb=props_objc_cb, undo="Colour", tip="The object's colour in the viewport: click for the colour picker"
WIDGET wd_sc_units, WK_ENUM, "scene.units", "Units", cb=props_units_cb, aux=unit_lbl, n=4, tip="What one scene unit is (typed lengths with units convert)"
WIDGET wd_sc_wstr, WK_FLOAT, "world.strength", "World strength", 0.0, 1000.0, 0.01, 3, WGF_CLAMP, undo="World", tip="How bright the world (sky or HDRI) lights the scene", def=1.0
WIDGET wd_sc_wrot, WK_FLOAT, "world.rotation", "World rotation", step=0.00872665, dec=1, flags=WGF_DEG, undo="World", tip="Turns the world image about the vertical axis", def=0.0
WIDGET wd_sc_fstart, WK_INT, "scene.frame_start", "Start frame", -100000.0, 100000.0, 0.2, 0, cb=props_range_cb, tip="The first frame of the animation"
WIDGET wd_sc_fend, WK_INT, "scene.frame_end", "End frame", -100000.0, 100000.0, 0.2, 0, cb=props_range_cb, tip="The last frame of the animation"
WIDGET wd_sc_fps, WK_INT, "scene.fps", "Frames per second", 1.0, 1000.0, 0.1, 0, WGF_CLAMP, cb=props_range_cb, tip="Playback speed"
WIDGET wd_rn_w, WK_INT, "render.width", "Width", 1.0, 8192.0, 1.0, 0, WGF_CLAMP, tip="The render's width in pixels"
WIDGET wd_rn_h, WK_INT, "render.height", "Height", 1.0, 8192.0, 1.0, 0, WGF_CLAMP, tip="The render's height in pixels"
WIDGET wd_rn_spp, WK_INT, "render.samples", "Samples", 1.0, 65536.0, 1.0, 0, WGF_CLAMP, tip="Samples per pixel: more is cleaner and slower"
WIDGET wd_rn_dn, WK_TOGGLE, "render.denoise", "Denoise", tip="Clean up the noise of the finished render"
WIDGET wd_rn_go, WK_BUTTON, "render.start", "Render (F12)", flags=WGF_PRIMARY, aux=op_render_start
WIDGET wd_rn_save, WK_BUTTON, "render.save", "Save Render...", aux=op_render_save
.section .bss
.align 4
tools_sel:      .skip 4
.section .rodata
s_t_add:        .asciz "ADD"
s_t_select:     .asciz "SELECT"
s_t_brushes:    .asciz "BRUSHES"
s_t_tools:      .asciz "TOOLS"
s_t_constr:     .asciz "CONSTRAIN"
s_t_layers:     .asciz "LAYERS"
s_t_lpaint:     .asciz "PAINT"
.align 8
cap_add:        .quad 2, s_t_add
cap_select:     .quad 2, s_t_select
cap_brushes:    .quad 2, s_t_brushes
cap_tools:      .quad 2, s_t_tools
cap_constr:     .quad 2, s_t_constr
cap_layers:     .quad 2, s_t_layers
cap_lpaint:     .quad 2, s_t_lpaint
tl_object:      .quad op_tool_select, op_tool_move, op_tool_rotate, op_tool_scale, cap_add
                .quad op_add_cube, op_add_sphere, op_add_cylinder, op_add_plane, op_add_light, op_add_camera
                .quad 0, op_view_measure, op_cursor_reset
.equ tl_object_n, (. - tl_object) / 8
tl_edit:        .quad op_m_extrude, op_m_extrude_ind, op_m_inset, op_m_bevel, op_m_loopcut, op_m_knife
                .quad op_m_bisect, op_m_spin, op_m_subdivide, op_m_bridge, op_m_fill, op_m_dissolve, cap_select
                .quad op_mesh_all, op_mesh_box, op_mesh_linked, op_mesh_inv
.equ tl_edit_n, (. - tl_edit) / 8
tl_sculpt:      .quad op_sb_draw, op_sb_clay, op_sb_crease, op_sb_inflate, op_sb_grab, op_sb_snake
                .quad op_sb_smooth, op_sb_flatten, op_sb_pinch, op_sb_layer, op_sb_mask, 0
                .quad op_s_mclear, op_s_minv, op_s_dyn
.equ tl_sculpt_n, (. - tl_sculpt) / 8
tl_lsculpt:     .quad op_lt_raise, op_lt_lower, op_lt_smooth, op_lt_flatten, op_lt_ramp, op_lt_noise
                .quad op_lt_erode, cap_lpaint, op_lt_rock, op_lt_grass, op_lt_sand, op_lt_snow
                .quad op_lt_dirt, op_lt_gravel, op_lt_moss, op_lt_mud, op_lt_auto
.equ tl_lsculpt_n, (. - tl_lsculpt) / 8
tl_paint:       .quad op_pt_color, op_pt_rad_up, op_pt_rad_dn, op_pt_str_up, op_pt_str_dn, cap_layers
                .quad op_pt_ladd, op_pt_lup, op_pt_ldn, op_pt_lmerge
.equ tl_paint_n, (. - tl_paint) / 8
tl_wpaint:      .quad op_pt_weight
.equ tl_wpaint_n, (. - tl_wpaint) / 8
tl_sketch:      .quad op_sk_line, op_sk_circle, op_sk_rect, op_sk_dimkey, op_sk_del, cap_constr
                .quad op_sk_coin, op_sk_hor, op_sk_ver, op_sk_eq, op_sk_par
                .quad op_sk_perp, op_sk_tan, op_sk_fix, op_sk_mid
.equ tl_sketch_n, (. - tl_sketch) / 8
tl_curve:       .quad op_cv_extrude, op_cv_subdiv, op_cv_delete, op_cv_cyclic, op_cv_handle, op_cv_selall
                .quad 0, op_cv_tomesh
.equ tl_curve_n, (. - tl_curve) / 8
tl_arm:         .quad op_arm_extrude, op_arm_delete, op_arm_selall, 0, op_arm_key, op_arm_clearr, op_arm_autow
.equ tl_arm_n, (. - tl_arm) / 8
.align 4
tl_object_c:    .long tl_object_n
tl_edit_c:      .long tl_edit_n
tl_sculpt_c:    .long tl_sculpt_n
tl_lsculpt_c:   .long tl_lsculpt_n
tl_paint_c:     .long tl_paint_n
tl_wpaint_c:    .long tl_wpaint_n
tl_sketch_c:    .long tl_sketch_n
tl_curve_c:     .long tl_curve_n
tl_arm_c:       .long tl_arm_n
.align 8
tool_icon_tab:  .quad op_tool_select, ICON_SELECT, op_tool_move, ICON_MOVE, op_tool_rotate, ICON_ROTATE
                .quad op_tool_scale, ICON_SCALE, op_add_cube, ICON_CUBE, op_add_sphere, ICON_SPHERE
                .quad op_add_cylinder, ICON_CYLINDER, op_add_plane, ICON_PLANE, op_add_light, ICON_LIGHT
                .quad op_add_camera, ICON_CAMERA, op_view_measure, ICON_MEASURE, op_cursor_reset, ICON_CURSOR
                .quad op_m_extrude, ICON_EXTRUDE, op_m_extrude_ind, ICON_EXTRUDE, op_m_inset, ICON_INSET
                .quad op_m_bevel, ICON_BEVEL, op_m_loopcut, ICON_LOOPCUT, op_m_knife, ICON_KNIFE
                .quad op_m_bisect, ICON_KNIFE, op_m_spin, ICON_ROTATE, op_m_subdivide, ICON_GRID
                .quad op_mesh_all, ICON_SELECT, op_mesh_box, ICON_SELECT
                .quad op_sb_draw, ICON_BRUSH, op_sb_clay, ICON_BRUSH, op_sb_crease, ICON_BRUSH
                .quad op_sb_inflate, ICON_SPHERE, op_sb_grab, ICON_MOVE, op_sb_snake, ICON_CURVE
                .quad op_sb_smooth, ICON_BRUSH, op_sb_flatten, ICON_PLANE, op_sb_pinch, ICON_BRUSH
                .quad op_sb_layer, ICON_BRUSH, op_sb_mask, ICON_SCULPT
                .quad op_pt_color, ICON_PAINT, op_pt_ladd, ICON_PLUS, op_pt_weight, ICON_WEIGHT
                .quad op_sk_line, ICON_SKETCH, op_sk_circle, ICON_TORUS, op_sk_rect, ICON_PLANE
                .quad op_sk_dimkey, ICON_MEASURE, op_sk_del, ICON_CLOSE, op_cv_extrude, ICON_EXTRUDE
                .quad op_cv_delete, ICON_CLOSE, op_cv_tomesh, ICON_MESH, op_arm_extrude, ICON_EXTRUDE
                .quad op_arm_delete, ICON_CLOSE, op_arm_key, ICON_KEY, op_arm_autow, ICON_WEIGHT
                .quad 0, 0
.text
.section .bss
.align 4
outl_rows:      .skip 4                 # rows drawn, and their objects
outl_map:       .skip OUTL_MAXROWS*4
outl_drag:      .skip 4                 # a row pressed: its object
outl_dragging:  .skip 4                 #  and dragged
outl_eye_sel:   .skip 4
outl_ren:       .skip 4                 # the object being renamed (handle)
outl_ren_go:    .skip 4                 #  (start typing when drawn)
outl_fren:      .skip 4                 # the folder being renamed (index + 1)
outl_fren_go:   .skip 4
outl_fsel:      .skip 4                 # (folder rows: none stays lit)
outl_fclick:    .skip 4                 # the folder row clicked last,
outl_fclick_t:  .skip 8                 #  when (a second click: rename)
outl_fname:     .skip 64
outl_x0:        .skip 4                 # the outliner last drawn: its rows' place
outl_y0:        .skip 4
outl_w0:        .skip 4
outl_ghost:     .skip 128               # the drag's label
outl_filter:    .skip 32
.section .rodata
s_u_parent:     .asciz "Parent"
s_u_folder:     .asciz "Folder"
s_dg_more:      .asciz " and "
s_dg_more2:     .asciz " more"
s_dg_into:      .asciz "Into "
s_dg_child:     .asciz "Child of "
s_dg_out:       .asciz "No parent, no folder"
s_par_loop:     .asciz "  an object cannot go under its own child"
s_u_render:     .asciz "Render / Leave Out"
s_u_lock:       .asciz "Lock"
s_u_hide:       .asciz "Hide"
s_obj_name_w:   .asciz "object.name"
s_filter_hint:  .asciz "Filter by name"
.align 4
type_icons:     .long ICON_MESH, ICON_LIGHT, ICON_CAMERA, ICON_SKETCH, ICON_ARMATURE, ICON_PHYSICS
.text
OPERATOR op_rename, "object.rename", "Rename", do_rename, key=KEY_F1+1, flags=OPF_QUIET, doc="Rename the active object: its outliner row (or the Properties name) becomes a text field (F2, or double-click a row)"
WIDGET wd_outl_name, WK_TEXT, "outliner.name", "Name", flags=WGF_COMPACT, cb=outl_name_cb, undo="Rename"
WIDGET wd_outl_eye,  WK_ROW, "outliner.visible", "Show / Hide", cb=outl_eye_cb, tip="Show or hide this object in the viewport"
WIDGET wd_outl_fold, WK_BUTTON, "outliner.fold", "Fold / Unfold", flags=WGF_NODRAW, tip="Show or hide this object's children"
WIDGET wd_outl_frow, WK_ROW, "outliner.folder", cb=outl_frow_cb, tip="A folder: click to pick it and select what is in it, twice to rename it. Drop objects here to move them in"
WIDGET wd_outl_ffold, WK_BUTTON, "outliner.folder_fold", "Fold / Unfold", flags=WGF_NODRAW, tip="Show or hide what is in this folder"
WIDGET wd_outl_fname, WK_TEXT, "outliner.folder_name", "Name", flags=WGF_COMPACT, cb=outl_fren_cb
WIDGET wd_outl_feye, WK_BUTTON, "outliner.folder_visible", "Show / Hide", flags=WGF_NODRAW, tip="Show or hide everything in this folder"
WIDGET wd_outl_fcam, WK_BUTTON, "outliner.folder_render", "Render / Leave Out", flags=WGF_NODRAW, tip="Render everything in this folder, or leave it out"
WIDGET wd_outl_flock, WK_BUTTON, "outliner.folder_lock", "Lock / Unlock", flags=WGF_NODRAW, tip="Lock everything in this folder against selection and edits"
WIDGET wd_outl_fnew, WK_BUTTON, "outliner.new_folder", "+", aux=op_fd_new, tip="A new folder, the selected objects in it (Ctrl+G)"
WIDGET wd_outl_cam,  WK_ROW, "outliner.render", "Render / Leave Out", cb=outl_cam_cb, tip="Include this object in renders, or leave it out (it still shows in the viewport)"
WIDGET wd_outl_lock, WK_ROW, "outliner.lock", "Lock / Unlock", cb=outl_lock_cb, tip="Lock: clicks in the viewport pass through it (select it here instead)"
WIDGET wd_outl_filter, WK_TEXT, "outliner.filter", "Filter", cb=outl_filter_cb, tip="Show only the objects whose name contains this (Enter)"
WIDGET wd_tool_row, WK_ROW, "tools.row", cb=tools_cb
WIDGET wd_vp_sec,     WK_SECTION, "props.viewport", "Viewport"
WIDGET wd_vp_shading, WK_ENUM,   "viewport.shading", aux=vp_shade_lbl, n=4
WIDGET wd_vp_grid,    WK_TOGGLE, "viewport.grid", "Ground grid"
WIDGET wd_vp_theme,   WK_ENUM,   "ui.theme", cb=vp_theme_cb, aux=th_labels, n=TH_N, flags=WGF_THEMES
WIDGET wd_vp_yaw,     WK_FLOAT,  "viewport.yaw", "Yaw", step=0.00872665, dec=1, flags=WGF_DEG
WIDGET wd_vp_pitch,   WK_FLOAT,  "viewport.pitch", "Pitch", -1.55, 1.55, 0.00872665, 1, WGF_DEG|WGF_CLAMP
WIDGET wd_vp_dist,    WK_FLOAT,  "viewport.distance", "Distance", 1.5, 20000.0, 0.05, 2, WGF_CLAMP
WIDGET wd_obj_name,  WK_TEXT,  "object.name", , flags=WGF_COMPACT, cb=props_rename, undo="Rename", tip="The object's name. Click to type a new one (names stay unique: Cube.001)"
WIDGET wd_obj_loc,   WK_FLOAT, "object.location", , step=0.01, dec=3, flags=WGF_COMPACT, cb=props_xform, undo="Move", tip="Where the object is, in scene units. Drag sideways (Shift: finer, Ctrl: steps), or click and type a value or expression: 25mm, 2*pi", def=0.0
WIDGET wd_obj_rot,   WK_FLOAT, "object.rotation", , step=0.00872665, dec=1, flags=WGF_COMPACT|WGF_DEG, cb=props_xform, undo="Rotate", tip="Euler XYZ rotation in degrees. Drag sideways, or click and type: 90, 45+15, 1.2rad", def=0.0
WIDGET wd_obj_scale, WK_FLOAT, "object.scale", , step=0.005, dec=3, flags=WGF_COMPACT, cb=props_xform, undo="Scale", tip="Size along each axis (1 = as modelled). Drag sideways, or click and type a factor", def=1.0

.section .note.GNU-stack,"",@progbits
