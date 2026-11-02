# =============================================================================
#  BeeModel - docking and floating panels (#419, stage 1).
#
#  Docking: an area's header dragged onto another area shows where it goes:
#  the left, right, top or bottom band of that area (the dragged one moves
#  there, the target split in two) or its middle (the two swap). The tree is
#  rearranged; editors and viewport cameras go with their areas.
#
#  Floating: Area > Float takes an area out of the tree; it floats over the
#  window as a panel (a leaf node with NF_FLOAT, outside the tree, its own
#  rectangle; N_Z orders the panels). Its header moves it, its left, right
#  and bottom edges resize it, its header's dock button (or Area > Dock)
#  puts it back beside the area under it, and dragged over an area it shows
#  five dock guides: released on one, it docks there (the middle: swaps).
#  Panels are drawn after the tree, and hit first; while the pointer is on
#  one, only its widgets answer (wg_hit: float_wg_filter). They are kept
#  with the workspace (its nodes), like every other area.
# =============================================================================
.intel_syntax noprefix
.include "const.inc"
.include "macros.inc"
.include "icons.inc"

.equ N_KIND,    0                       # (areas.s)
.equ N_ED,      1
.equ N_PARENT,  2
.equ N_FLAGS,   3
.equ N_RATIO,   4
.equ N_A,       8
.equ N_B,       9
.equ N_Z,       10
.equ N_X,       12
.equ N_Y,       16
.equ N_W,       20
.equ N_H,       24
.equ N_SZ,      32
.equ K_LEAF,    1
.equ K_HSPLIT,  2
.equ K_VSPLIT,  3
.equ MAX_NODES, 32
.equ NO_NODE,   0xff
.equ CAM_SZ,    24
.equ NF_FLOAT,  1
.equ NF_WINDOW, 2                       # (and in a window of its own)
.equ N_WND,     11                      # that window's slot
.equ PW_MAX,    4

.equ FL_MINW,   220                     # a floating panel's smallest size
.equ FL_MINH,   140
.equ FL_EDGE,   5                       # the resize band inside its edges
.equ GD,        30                      # a dock guide
.equ GD_STEP,   34                      # guide to guide
.equ ZONE_EDGE, 300                     # the bands: 30% of the area (1/1000)

# zones: 0 the middle (swap), 1 left, 2 right, 3 top, 4 bottom

.globl area_is_float
.globl float_hit
.globl float_wg_filter
.globl dock_draw
.globl dock_clamp
.globl dock_press
.globl dock_begin_move
.globl dock_begin_resize
.globl dock_motion
.globl dock_drop
.globl area_json
.globl ah_tree
.globl dk_ref

.section .data
.align 4
dk_tgt:         .long -1                # the tree's area under the dragged one
dk_zone:        .long -1                #  and where it would go (-1: nowhere)
dk_ref:         .long -1                # (close_leaf keeps it on its area)
flt_wall_lo:    .long 0                 # every panel's widgets: [lo, hi)
flt_wall_hi:    .long 0

.section .bss
.align 4
ah_tree:        .skip 4                 # 1: area_hit sees the tree alone
fl_offx:        .skip 4                 # a move: the pointer from the corner
fl_offy:        .skip 4
fl_px:          .skip 4                 # a resize: the press, its rectangle
fl_py:          .skip 4
fl_r0:          .skip 16
fl_edges:       .skip 4
flt_wlo:        .skip MAX_NODES*4       # each panel's widgets
flt_whi:        .skip MAX_NODES*4
dk_cam:         .skip 32                # dock_into / float: the area's view

.section .rodata
.align 4
gd_dx:          .long 0, -GD_STEP, GD_STEP, 0, 0
gd_dy:          .long 0, 0, 0, -GD_STEP, GD_STEP
gd_glyph:       .long 7, 7, 16, 16      # the middle: a square
                .long 4, 4, 11, 22      # left: the left half
                .long 15, 4, 11, 22
                .long 4, 4, 22, 11
                .long 4, 15, 22, 11
s_no_float:     .asciz "  the last area cannot float"
s_dock_room:    .asciz "  no room to dock it"
s_not_float:    .asciz "the active area is not a floating panel"
j_area_a:       .asciz "{\"name\":\"area\",\"sub\":"
j_area_k:       .asciz ",\"kind\":\"area\""
j_area_lbl:     .asciz ",\"label\":"
j_area_fl:      .asciz ",\"value\":\"float\"}"
j_area_dk:      .asciz ",\"value\":\"docked\"}"
j_area_wn:      .asciz ",\"value\":\"window\"}"
j_area_x:       .asciz ",\"x\":"
j_area_y:       .asciz ",\"y\":"
j_area_w:       .asciz ",\"w\":"
j_area_h:       .asciz ",\"h\":"

OPERATOR op_area_float, "area.float", "Float Area", op_float_x, poll=poll_float, doc="Take the active area out of the layout: it floats over the window as a panel you can move and resize (its header's dock button puts it back)"
OPERATOR op_area_dock,  "area.dock",  "Dock Area",  op_dock_x,  poll=poll_dock,  doc="Put the active floating panel back into the layout, beside the area under it"

.text

# area_is_float(edi=node) -> eax = 1 for a floating panel
area_is_float:
    xor     eax, eax
    cmp     edi, MAX_NODES
    jae     9f
    call    node_ptr
    cmp     byte ptr [rax+N_KIND], K_LEAF
    jne     8f
    test    byte ptr [rax+N_FLAGS], NF_FLOAT
    jz      8f
    mov     eax, 1
    ret
8:  xor     eax, eax
9:  ret

# float_next(edi=key) -> eax = the panel with the smallest key (z * 64 +
#   index) above edi, or -1; edx = its key. From -1: the lowest one.
float_next:
    mov     r8d, -1
    mov     r9d, 0x7fffffff
    xor     ecx, ecx
    lea     r10, [rip+nodes]
1:  cmp     byte ptr [r10+N_KIND], K_LEAF
    jne     2f
    test    byte ptr [r10+N_FLAGS], NF_FLOAT
    jz      2f
    test    byte ptr [r10+N_FLAGS], NF_WINDOW   # (in a window of its own)
    jnz     2f
    movzx   eax, byte ptr [r10+N_Z]
    shl     eax, 6
    or      eax, ecx
    cmp     eax, edi
    jle     2f
    cmp     eax, r9d
    jge     2f
    mov     r9d, eax
    mov     r8d, ecx
2:  add     r10, N_SZ
    inc     ecx
    cmp     ecx, MAX_NODES
    jb      1b
    mov     eax, r8d
    mov     edx, r9d
    ret

# float_maxz -> eax = the highest panel's z (0: no panels)
float_maxz:
    xor     eax, eax
    xor     ecx, ecx
    lea     rdx, [rip+nodes]
1:  cmp     byte ptr [rdx+N_KIND], K_LEAF
    jne     2f
    test    byte ptr [rdx+N_FLAGS], NF_FLOAT
    jz      2f
    movzx   r8d, byte ptr [rdx+N_Z]
    cmp     r8d, eax
    cmova   eax, r8d
2:  add     rdx, N_SZ
    inc     ecx
    cmp     ecx, MAX_NODES
    jb      1b
    ret

# float_renumber -> eax = panels: z 1, 2, ... in their order
float_renumber:
    push    rbx
    push    r12
    sub     rsp, 40
    mov     ebx, -1
    xor     r12d, r12d
1:  mov     edi, ebx
    call    float_next
    test    eax, eax
    js      2f
    mov     [rsp+r12], al
    inc     r12d
    mov     ebx, edx
    cmp     r12d, 32
    jb      1b
2:  xor     ebx, ebx
3:  cmp     ebx, r12d
    jae     9f
    movzx   edi, byte ptr [rsp+rbx]
    call    node_ptr
    lea     edx, [rbx+1]
    mov     [rax+N_Z], dl
    inc     ebx
    jmp     3b
9:  mov     eax, r12d
    add     rsp, 40
    pop     r12
    pop     rbx
    ret

# float_raise(edi=node) - that panel on top of the others
float_raise:
    push    rbx
    push    r12
    sub     rsp, 8
    mov     ebx, edi
    call    area_is_float
    test    eax, eax
    jz      9f
    call    float_maxz
    mov     r12d, eax
    mov     edi, ebx
    call    node_ptr
    movzx   ecx, byte ptr [rax+N_Z]
    cmp     ecx, r12d                   # (already the top one)
    jne     1f
    test    ecx, ecx
    jnz     9f
1:  cmp     r12d, 250
    jb      2f
    call    float_renumber
    mov     r12d, eax
2:  mov     edi, ebx
    call    node_ptr
    lea     ecx, [r12+1]
    mov     [rax+N_Z], cl
    mov     dword ptr [rip+dirty], 1
9:  add     rsp, 8
    pop     r12
    pop     rbx
    ret

# float_hit(edi=x, esi=y) -> eax = the topmost panel there, or -1; edx = the
#   edges the point is on (2 bottom, 4 left, 8 right: a resize)
float_hit:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    mov     r12d, edi
    mov     r13d, esi
    mov     r14d, -1
    mov     ebx, -1
1:  mov     edi, ebx
    call    float_next
    test    eax, eax
    js      8f
    mov     ebx, edx
    mov     r15d, eax
    mov     edi, eax
    call    node_ptr
    mov     ecx, r12d
    sub     ecx, [rax+N_X]
    js      1b
    cmp     ecx, [rax+N_W]
    jge     1b
    mov     ecx, r13d
    sub     ecx, [rax+N_Y]
    js      1b
    cmp     ecx, [rax+N_H]
    jge     1b
    mov     r14d, r15d                  # (a higher one wins)
    jmp     1b
8:  xor     edx, edx
    test    r14d, r14d
    js      9f
    mov     edi, r14d
    call    node_ptr
    xor     edx, edx
    mov     ecx, r12d
    sub     ecx, [rax+N_X]
    cmp     ecx, FL_EDGE
    jge     1f
    or      edx, 4
1:  mov     ecx, [rax+N_X]
    add     ecx, [rax+N_W]
    sub     ecx, r12d
    cmp     ecx, FL_EDGE
    jg      2f
    or      edx, 8
2:  mov     ecx, [rax+N_Y]
    add     ecx, [rax+N_H]
    sub     ecx, r13d
    cmp     ecx, FL_EDGE
    jg      9f
    or      edx, 2
9:  mov     eax, r14d
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# float_wg_filter(edi=x, esi=y) -> eax = 0 every widget, 1 only [edx, ecx),
#   2 all but [edx, ecx) (widgets.s wg_hit: a panel hides what is under it)
float_wg_filter:
    push    rbx
    push    rdi
    push    rsi
    call    pw_cur_node                 # (a panel's window: that panel's)
    pop     rsi
    pop     rdi
    test    eax, eax
    jns     0f
    call    float_hit
0:
    test    eax, eax
    js      1f
    lea     rcx, [rip+flt_wlo]
    mov     edx, [rcx+rax*4]
    lea     rcx, [rip+flt_whi]
    mov     ecx, [rcx+rax*4]
    mov     eax, 1
    pop     rbx
    ret
1:  mov     edx, [rip+flt_wall_lo]
    mov     ecx, [rip+flt_wall_hi]
    xor     eax, eax
    cmp     edx, ecx
    jae     9f
    mov     eax, 2
9:  pop     rbx
    ret

# dock_clamp - every panel inside the content region (area_layout)
dock_clamp:
    push    rbx
    xor     ebx, ebx
1:  mov     edi, ebx
    call    area_is_float
    test    eax, eax
    jz      8f
    mov     edi, ebx
    call    node_ptr
    test    byte ptr [rax+N_FLAGS], NF_WINDOW   # (its own window's size)
    jnz     8f
    mov     r8d, [rip+win_w]            # the room: w, h
    mov     r9d, [rip+cont_y1]
    sub     r9d, [rip+cont_y0]
    mov     ecx, [rax+N_W]              # the size: at least the minimum, at
    cmp     ecx, FL_MINW                #  most the room
    jge     2f
    mov     ecx, FL_MINW
2:  cmp     ecx, r8d
    cmovg   ecx, r8d
    mov     [rax+N_W], ecx
    mov     ecx, [rax+N_H]
    cmp     ecx, FL_MINH
    jge     3f
    mov     ecx, FL_MINH
3:  cmp     ecx, r9d
    cmovg   ecx, r9d
    mov     [rax+N_H], ecx
    mov     ecx, r8d                    # the place
    sub     ecx, [rax+N_W]
    mov     edx, [rax+N_X]
    cmp     edx, ecx
    cmovg   edx, ecx
    test    edx, edx
    jns     4f
    xor     edx, edx
4:  mov     [rax+N_X], edx
    mov     ecx, [rip+cont_y1]
    sub     ecx, [rax+N_H]
    mov     edx, [rax+N_Y]
    cmp     edx, ecx
    cmovg   edx, ecx
    cmp     edx, [rip+cont_y0]
    jge     5f
    mov     edx, [rip+cont_y0]
5:  mov     [rax+N_Y], edx
8:  inc     ebx
    cmp     ebx, MAX_NODES
    jb      1b
    pop     rbx
    ret

# -----------------------------------------------------------------------------
# Drawing (area_draw_all, after the tree)
# -----------------------------------------------------------------------------
dock_draw:
    push    rbx
    push    r12
    push    r13
    mov     eax, [rip+wg_n]
    mov     [rip+flt_wall_lo], eax
    mov     ebx, -1
1:  mov     edi, ebx
    call    float_next
    test    eax, eax
    js      8f
    mov     ebx, edx
    mov     r12d, eax
    mov     edi, eax
    call    node_ptr
    mov     r13, rax
    call    reset_clip
    mov     edi, [r13+N_X]              # a shadow
    add     edi, 5
    mov     esi, [r13+N_Y]
    add     esi, 5
    mov     edx, [r13+N_W]
    mov     ecx, [r13+N_H]
    xor     r8d, r8d
    mov     r9d, 80
    call    fill_rect_a
    mov     edi, [r13+N_X]              # a frame (the accent: the active one)
    dec     edi
    mov     esi, [r13+N_Y]
    dec     esi
    mov     edx, [r13+N_W]
    add     edx, 2
    mov     ecx, [r13+N_H]
    add     ecx, 2
    mov     r8d, COL_SEPARATOR
    cmp     r12d, [rip+active_area]
    jne     2f
    mov     r8d, COL_ACCENT
2:  call    fill_rect
    lea     rax, [rip+flt_wlo]
    mov     ecx, [rip+wg_n]
    mov     [rax+r12*4], ecx
    mov     edi, r12d
    call    draw_leaf
    call    reset_clip
    lea     rax, [rip+flt_whi]
    mov     ecx, [rip+wg_n]
    mov     [rax+r12*4], ecx
    jmp     1b
8:  call    pw_draw_all                 # the panels in windows of their own
    mov     eax, [rip+wg_n]
    mov     [rip+flt_wall_hi], eax
    call    dock_overlay
    pop     r13
    pop     r12
    pop     rbx
    ret

# zone_rect(edi=area, esi=zone) -> edi x, esi y, edx w, ecx h: where it goes
zone_rect:
    push    rsi
    call    node_ptr
    pop     rsi
    mov     edi, [rax+N_X]
    mov     r8d, [rax+N_Y]
    mov     edx, [rax+N_W]
    mov     ecx, [rax+N_H]
    cmp     esi, 1
    je      1f
    cmp     esi, 2
    je      2f
    cmp     esi, 3
    je      3f
    cmp     esi, 4
    je      4f
    jmp     9f
1:  shr     edx, 1
    jmp     9f
2:  mov     r9d, edx
    shr     r9d, 1
    add     edi, r9d
    sub     edx, r9d
    jmp     9f
3:  shr     ecx, 1
    jmp     9f
4:  mov     r9d, ecx
    shr     r9d, 1
    add     r8d, r9d
    sub     ecx, r9d
9:  mov     esi, r8d
    ret

# guide_xy(edi=area, esi=guide) -> edi x, esi y: that dock guide's corner
guide_xy:
    push    rsi
    call    node_ptr
    pop     rsi
    mov     edi, [rax+N_W]
    shr     edi, 1
    add     edi, [rax+N_X]
    sub     edi, GD/2
    mov     ecx, [rax+N_H]
    shr     ecx, 1
    add     ecx, [rax+N_Y]
    sub     ecx, GD/2
    lea     rax, [rip+gd_dx]
    add     edi, [rax+rsi*4]
    lea     rax, [rip+gd_dy]
    add     ecx, [rax+rsi*4]
    mov     esi, ecx
    ret

# guide_hit(edi=area, esi=x, edx=y) -> eax = the guide there, or -1
guide_hit:
    push    rbx
    push    r12
    push    r13
    push    r14
    sub     rsp, 8
    mov     r12d, edi
    mov     r13d, esi
    mov     r14d, edx
    xor     ebx, ebx
1:  mov     edi, r12d
    mov     esi, ebx
    call    guide_xy
    mov     eax, r13d
    sub     eax, edi
    js      2f
    cmp     eax, GD
    jge     2f
    mov     eax, r14d
    sub     eax, esi
    js      2f
    cmp     eax, GD
    jge     2f
    mov     eax, ebx
    jmp     9f
2:  inc     ebx
    cmp     ebx, 5
    jb      1b
    mov     eax, -1
9:  add     rsp, 8
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# region_zone(edi=area, esi=x, edx=y) -> eax = the zone the point is in: a
#   band along an edge (30%), else the middle
region_zone:
    push    rbx
    push    r12
    sub     rsp, 8
    mov     ebx, esi
    mov     r12d, edx
    call    node_ptr
    mov     r8, rax
    mov     eax, ebx                    # fx = (x - X) * 1000 / W
    sub     eax, [r8+N_X]
    imul    eax, eax, 1000
    cdq
    mov     ecx, [r8+N_W]
    cmp     ecx, 1
    jge     1f
    mov     ecx, 1
1:  idiv    ecx
    mov     r9d, eax
    mov     eax, r12d                   # fy
    sub     eax, [r8+N_Y]
    imul    eax, eax, 1000
    cdq
    mov     ecx, [r8+N_H]
    cmp     ecx, 1
    jge     2f
    mov     ecx, 1
2:  idiv    ecx
    mov     r10d, eax
    mov     eax, 0                      # the nearest edge
    mov     edx, ZONE_EDGE
    cmp     r9d, edx                    # left: fx
    jge     3f
    mov     edx, r9d
    mov     eax, 1
3:  mov     ecx, 1000                   # right: 1000 - fx
    sub     ecx, r9d
    cmp     ecx, edx
    jge     4f
    mov     edx, ecx
    mov     eax, 2
4:  cmp     r10d, edx                   # top: fy
    jge     5f
    mov     edx, r10d
    mov     eax, 3
5:  mov     ecx, 1000                   # bottom
    sub     ecx, r10d
    cmp     ecx, edx
    jge     9f
    mov     eax, 4
9:  add     rsp, 8
    pop     r12
    pop     rbx
    ret

# dock_overlay - while an area is dragged: where it would go
dock_overlay:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    cmp     dword ptr [rip+drag_mode], DRAG_AREA
    jne     9f
    mov     ebx, [rip+dk_tgt]
    test    ebx, ebx
    js      9f
    call    reset_clip
    mov     r12d, [rip+dk_zone]
    test    r12d, r12d
    js      5f
    mov     edi, ebx                    # the place, tinted, with an outline
    mov     esi, r12d
    call    zone_rect
    mov     r13d, edi
    mov     r14d, esi
    mov     r15d, edx
    push    rcx
    push    rcx
    mov     r8d, COL_ACCENT
    mov     r9d, 60
    call    fill_rect_a
    pop     rcx
    pop     rcx
    push    rcx
    push    rcx
    mov     edi, r13d                   # top, bottom
    mov     esi, r14d
    mov     edx, r15d
    mov     ecx, 2
    mov     r8d, COL_ACCENT
    call    fill_rect
    mov     rcx, [rsp]
    mov     edi, r13d
    lea     esi, [r14+rcx-2]
    mov     edx, r15d
    mov     ecx, 2
    mov     r8d, COL_ACCENT
    call    fill_rect
    mov     rcx, [rsp]                  # left, right
    mov     edi, r13d
    mov     esi, r14d
    mov     edx, 2
    mov     r8d, COL_ACCENT
    call    fill_rect
    mov     rcx, [rsp]
    lea     edi, [r13+r15-2]
    mov     esi, r14d
    mov     edx, 2
    mov     r8d, COL_ACCENT
    call    fill_rect
    pop     rcx
    pop     rcx
5:  cmp     dword ptr [rip+wsp_drag_kind], 2    # a panel moved: the guides
    jne     9f
    xor     r13d, r13d
6:  mov     edi, ebx
    mov     esi, r13d
    call    guide_xy
    mov     r14d, edi
    mov     r15d, esi
    mov     edx, GD
    mov     ecx, GD
    mov     r8d, COL_PANE_HDR
    mov     r9d, 235
    cmp     r13d, r12d
    jne     7f
    mov     r8d, COL_ACCENT
7:  call    fill_rect_a
    lea     rax, [rip+gd_glyph]         # what it does, drawn
    mov     ecx, r13d
    shl     ecx, 4
    add     rax, rcx
    mov     edi, r14d
    add     edi, [rax]
    mov     esi, r15d
    add     esi, [rax+4]
    mov     edx, [rax+8]
    mov     ecx, [rax+12]
    mov     r8d, COL_ACCENT
    cmp     r13d, r12d
    jne     8f
    mov     r8d, COL_PANE_HDR
8:  call    fill_rect
    inc     r13d
    cmp     r13d, 5
    jb      6b
9:  pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# -----------------------------------------------------------------------------
# Input
# -----------------------------------------------------------------------------
# dock_press(edi=x, esi=y) - a press on a panel brings it to the top
dock_press:
    sub     rsp, 8
    call    float_hit
    test    eax, eax
    js      9f
    mov     edi, eax
    call    float_raise
9:  add     rsp, 8
    ret

# dock_begin_move(edi=panel) - its header pressed: it follows the pointer
dock_begin_move:
    push    rbx
    mov     ebx, edi
    call    area_is_window              # (a window of its own: moved by the
    test    eax, eax                    #  compositor)
    jz      0f
    mov     edi, ebx
    call    node_ptr
    movzx   edi, byte ptr [rax+N_WND]
    mov     esi, [rip+press_serial]
    call    pw_move
    pop     rbx
    ret
0:
    call    float_raise
    mov     edi, ebx
    call    node_ptr
    mov     ecx, [rip+ptr_x]
    sub     ecx, [rax+N_X]
    mov     [rip+fl_offx], ecx
    mov     ecx, [rip+ptr_y]
    sub     ecx, [rax+N_Y]
    mov     [rip+fl_offy], ecx
    mov     dword ptr [rip+wsp_drag_kind], 2
    jmp     dock_begin

# dock_begin_resize(edi=panel | edges << 8) - an edge pressed: a resize
dock_begin_resize:
    push    rbx
    mov     ebx, edi
    shr     edi, 8
    mov     [rip+fl_edges], edi
    and     ebx, 0xff
    mov     edi, ebx                    # (a window of its own: resized by
    call    area_is_window              #  the compositor)
    test    eax, eax
    jz      0f
    mov     edi, ebx
    call    node_ptr
    movzx   edi, byte ptr [rax+N_WND]
    mov     esi, [rip+press_serial]
    mov     edx, [rip+fl_edges]
    call    pw_resize
    pop     rbx
    ret
0:
    mov     edi, ebx
    call    float_raise
    mov     edi, ebx
    call    node_ptr
    mov     ecx, [rip+ptr_x]
    mov     [rip+fl_px], ecx
    mov     ecx, [rip+ptr_y]
    mov     [rip+fl_py], ecx
    mov     rcx, [rax+N_X]
    mov     [rip+fl_r0], rcx
    mov     rcx, [rax+N_W]
    mov     [rip+fl_r0+8], rcx
    mov     dword ptr [rip+wsp_drag_kind], 3
dock_begin:                             # (rbx pushed: the panel)
    mov     [rip+wsp_drag_src], ebx
    mov     [rip+active_area], ebx
    mov     dword ptr [rip+drag_mode], DRAG_AREA
    mov     dword ptr [rip+dk_tgt], -1
    mov     dword ptr [rip+dk_zone], -1
    mov     dword ptr [rip+dirty], 1
    pop     rbx
    ret

# outside_main(edi=x, esi=y) -> eax = 1 when the point is out of the main
#   window (a drag goes on outside it)
outside_main:
    mov     eax, 1
    test    edi, edi
    js      9f
    test    esi, esi
    js      9f
    cmp     edi, [rip+win_w]
    jge     9f
    cmp     esi, [rip+win_h]
    jge     9f
    xor     eax, eax
9:  ret

# tree_leaf_at(edi=x, esi=y) -> eax = the tree's area there (panels aside)
tree_leaf_at:
    sub     rsp, 8
    mov     dword ptr [rip+ah_tree], 1
    call    area_hit
    mov     dword ptr [rip+ah_tree], 0
    mov     eax, [rip+hit_area]
    add     rsp, 8
    ret

# dock_motion(edi=x, esi=y) -> eax = the cursor: an area's header or a
#   panel dragged (where it would go), a panel moved or resized
dock_motion:
    push    rbx
    push    r12
    push    r13
    mov     ebx, edi
    mov     r12d, esi
    mov     dword ptr [rip+dirty], 1
    mov     eax, [rip+wsp_drag_kind]
    cmp     eax, 3
    je      .Ldm_resize
    cmp     eax, 1
    je      .Ldm_join
    cmp     eax, 2
    jne     .Ldm_target
    mov     edi, [rip+wsp_drag_src]     # a panel moved
    call    node_ptr
    mov     ecx, ebx
    sub     ecx, [rip+fl_offx]
    mov     [rax+N_X], ecx
    mov     ecx, r12d
    sub     ecx, [rip+fl_offy]
    mov     [rax+N_Y], ecx
    call    dock_clamp
.Ldm_target:                            # the area under the pointer, the zone
    mov     dword ptr [rip+dk_tgt], -1
    mov     dword ptr [rip+dk_zone], -1
    mov     edi, ebx
    mov     esi, r12d
    call    outside_main                # (out of the window: a window of its
    test    eax, eax                    #  own when released)
    jnz     8f
    mov     edi, ebx
    mov     esi, r12d
    call    tree_leaf_at
    mov     r13d, eax
    mov     dword ptr [rip+dk_zone], -1
    mov     [rip+dk_tgt], eax
    test    eax, eax
    js      8f
    cmp     eax, [rip+wsp_drag_src]
    jne     1f
    mov     dword ptr [rip+dk_tgt], -1
    jmp     8f
1:  mov     edi, r13d
    mov     esi, ebx
    mov     edx, r12d
    cmp     dword ptr [rip+wsp_drag_kind], 2
    je      2f
    call    region_zone                 # a header: the bands, the middle
    jmp     3f
2:  call    guide_hit                   # a panel: the guides alone
3:  mov     [rip+dk_zone], eax
8:  mov     eax, CUR_GRABBING
    jmp     9f
.Ldm_join:
    mov     eax, CUR_GRABBING
    jmp     9f
.Ldm_resize:
    mov     edi, [rip+wsp_drag_src]
    call    node_ptr
    mov     r13, rax
    mov     ecx, ebx                    # dx, dy
    sub     ecx, [rip+fl_px]
    mov     edx, r12d
    sub     edx, [rip+fl_py]
    test    dword ptr [rip+fl_edges], 4 # the left edge: x and w (the right
    jz      1f                          #  edge stays)
    mov     eax, [rip+fl_r0+8]
    sub     eax, ecx
    cmp     eax, FL_MINW
    jge     11f
    mov     eax, FL_MINW
11: mov     [r13+N_W], eax
    mov     r8d, [rip+fl_r0]
    add     r8d, [rip+fl_r0+8]
    sub     r8d, eax
    mov     [r13+N_X], r8d
1:  test    dword ptr [rip+fl_edges], 8 # the right edge: w
    jz      2f
    mov     eax, [rip+fl_r0+8]
    add     eax, ecx
    cmp     eax, FL_MINW
    jge     21f
    mov     eax, FL_MINW
21: mov     [r13+N_W], eax
2:  test    dword ptr [rip+fl_edges], 2 # the bottom edge: h
    jz      3f
    mov     eax, [rip+fl_r0+12]
    add     eax, edx
    cmp     eax, FL_MINH
    jge     31f
    mov     eax, FL_MINH
31: mov     [r13+N_H], eax
3:  call    dock_clamp
    mov     ecx, [rip+fl_edges]         # the cursor: the edges' one
    mov     eax, CUR_NS
    cmp     ecx, 2
    je      9f
    mov     eax, CUR_NESW
    cmp     ecx, 6
    je      9f
    mov     eax, CUR_NWSE
    cmp     ecx, 10
    je      9f
    mov     eax, CUR_EW
9:  pop     r13
    pop     r12
    pop     rbx
    ret

# dock_drop(edi=x, esi=y) - the drag ends (workspace.s wsp_area_drop): a
#   header or a panel over a place docks there (the middle: a swap)
dock_drop:
    push    rbx
    push    r12
    push    r13
    mov     ebx, edi
    mov     r12d, esi
    mov     eax, [rip+wsp_drag_kind]
    cmp     eax, 3
    je      8f
    cmp     eax, 2                      # a panel out of the main window: its
    jne     0f                          #  own window
    mov     edi, ebx
    mov     esi, r12d
    call    outside_main
    test    eax, eax
    jz      0f
    call    pw_supported
    test    eax, eax
    jz      8f
    mov     edi, [rip+wsp_drag_src]
    call    pw_open_node
    jmp     8f
0:  mov     edi, ebx
    mov     esi, r12d
    call    tree_leaf_at
    mov     r13d, eax
    test    eax, eax
    js      8f
    cmp     eax, [rip+wsp_drag_src]
    je      8f
    mov     edi, r13d
    mov     esi, ebx
    mov     edx, r12d
    cmp     dword ptr [rip+wsp_drag_kind], 2
    je      1f
    call    region_zone
    jmp     2f
1:  call    guide_hit
    test    eax, eax
    js      8f
2:  test    eax, eax
    jnz     3f
    mov     edi, [rip+wsp_drag_src]     # the middle: the two swap
    mov     esi, r13d
    call    area_swap
    jmp     8f
3:  mov     edi, [rip+wsp_drag_src]
    mov     esi, r13d
    mov     edx, eax
    call    dock_into
8:  mov     dword ptr [rip+dk_tgt], -1
    mov     dword ptr [rip+dk_zone], -1
    mov     dword ptr [rip+dirty], 1
    call    area_layout
    pop     r13
    pop     r12
    pop     rbx
    ret

# -----------------------------------------------------------------------------
# Rearranging
# -----------------------------------------------------------------------------
# view_save(edi=area) / view_give(edi=area): its camera, orthographic and
#   Camera View, kept in dk_cam meanwhile
view_save:
    push    rbx
    mov     ebx, edi
    call    cam_ptr
    mov     rcx, [rax]
    mov     [rip+dk_cam], rcx
    mov     rcx, [rax+8]
    mov     [rip+dk_cam+8], rcx
    mov     rcx, [rax+16]
    mov     [rip+dk_cam+16], rcx
    lea     rax, [rip+area_ortho]
    mov     ecx, [rax+rbx*4]
    mov     [rip+dk_cam+24], ecx
    lea     rax, [rip+area_camv]
    mov     ecx, [rax+rbx*4]
    mov     [rip+dk_cam+28], ecx
    pop     rbx
    ret
view_give:
    push    rbx
    mov     ebx, edi
    call    cam_ptr
    mov     rcx, [rip+dk_cam]
    mov     [rax], rcx
    mov     rcx, [rip+dk_cam+8]
    mov     [rax+8], rcx
    mov     rcx, [rip+dk_cam+16]
    mov     [rax+16], rcx
    lea     rax, [rip+area_ortho]
    mov     ecx, [rip+dk_cam+24]
    mov     [rax+rbx*4], ecx
    lea     rax, [rip+area_camv]
    mov     ecx, [rip+dk_cam+28]
    mov     [rax+rbx*4], ecx
    pop     rbx
    ret

# area_swap(edi=a, esi=b) - the two areas trade editors and views; b is
#   active (what was in a)
area_swap:
    push    rbx
    push    r12
    sub     rsp, 8
    mov     ebx, edi
    mov     r12d, esi
    call    view_save                   # a's view aside
    mov     edi, r12d                   # b's view -> a
    call    cam_ptr
    mov     rsi, rax
    mov     edi, ebx
    call    cam_ptr
    mov     rcx, [rsi]
    mov     [rax], rcx
    mov     rcx, [rsi+8]
    mov     [rax+8], rcx
    mov     rcx, [rsi+16]
    mov     [rax+16], rcx
    lea     rax, [rip+area_ortho]
    mov     ecx, [rax+r12*4]
    mov     [rax+rbx*4], ecx
    lea     rax, [rip+area_camv]
    mov     ecx, [rax+r12*4]
    mov     [rax+rbx*4], ecx
    mov     edi, r12d                   # a's -> b
    call    view_give
    mov     edi, ebx                    # the editors
    call    node_ptr
    mov     rdx, rax
    mov     edi, r12d
    call    node_ptr
    mov     cl, [rdx+N_ED]
    mov     ch, [rax+N_ED]
    mov     [rdx+N_ED], ch
    mov     [rax+N_ED], cl
    mov     eax, [rip+vp_area]          # the viewport Properties shows goes too
    cmp     eax, ebx
    jne     1f
    mov     [rip+vp_area], r12d
    jmp     2f
1:  cmp     eax, r12d
    jne     2f
    mov     [rip+vp_area], ebx
2:  mov     [rip+active_area], r12d
    mov     dword ptr [rip+dirty], 1
    add     rsp, 8
    pop     r12
    pop     rbx
    ret

# free_nodes -> eax = unused node slots
free_nodes:
    xor     eax, eax
    xor     ecx, ecx
    lea     rdx, [rip+nodes]
1:  cmp     byte ptr [rdx+N_KIND], 0
    jne     2f
    inc     eax
2:  add     rdx, N_SZ
    inc     ecx
    cmp     ecx, MAX_NODES
    jb      1b
    ret

# dock_into(edi=area, esi=target, edx=zone 1..4) -> eax = the area in its new
#   place, or -1: it leaves its place (a panel: the panel goes) and the
#   target is split, the area on that side of it
dock_into:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    mov     ebx, edi
    mov     r12d, esi
    mov     r13d, edx
    call    node_ptr
    movzx   r14d, byte ptr [rax+N_ED]   # the editor
    movzx   r15d, byte ptr [rax+N_FLAGS]
    test    r15d, NF_FLOAT              # a panel needs two free slots (the
    jz      1f                          #  tree's area frees two itself)
    call    free_nodes
    cmp     eax, 2
    jae     1f
    lea     rdi, [rip+s_dock_room]
    call    log_line
    mov     eax, -1
    jmp     9f
1:  mov     edi, ebx
    call    view_save
    test    r15d, NF_FLOAT
    jz      2f
    mov     edi, ebx                    # a panel: its slot freed
    call    node_ptr
    mov     byte ptr [rax+N_KIND], 0
    mov     byte ptr [rax+N_FLAGS], 0
    jmp     3f
2:  mov     [rip+dk_ref], r12d          # the tree's: closed (the target may
    mov     edi, ebx                    #  move to its parent's slot)
    call    close_leaf
    mov     r12d, [rip+dk_ref]
    mov     dword ptr [rip+dk_ref], -1
    test    eax, eax
    jz      8f
3:  test    r12d, r12d
    js      8f
    mov     esi, K_HSPLIT               # left / right: side by side
    cmp     r13d, 3
    jb      4f
    mov     esi, K_VSPLIT
4:  xor     r8d, r8d                    # left, top: the area first
    cmp     r13d, 1
    je      5f
    cmp     r13d, 3
    jne     6f
5:  mov     r8d, 1
6:  mov     edi, r12d
    mov     edx, 32768
    mov     ecx, r14d
    call    split_with
    test    eax, eax
    js      8f
    mov     ebx, eax
    mov     edi, eax
    call    view_give
    mov     [rip+active_area], ebx
    cmp     r14d, ED_VIEWPORT
    jne     7f
    mov     [rip+vp_area], ebx
7:  mov     dword ptr [rip+area_maxed], -1
    mov     dword ptr [rip+dirty], 1
    mov     eax, ebx
    jmp     9f
8:  mov     eax, -1
9:  pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# -----------------------------------------------------------------------------
# Operators
# -----------------------------------------------------------------------------
op_can_float:                           # a tree's area, not the last one
    mov     edi, [rip+active_area]
    xor     eax, eax
    test    edi, edi
    js      9f
    cmp     edi, [rip+area_root]
    je      9f
    push    rdi
    call    area_is_float
    pop     rdi
    test    eax, eax
    jnz     8f
    call    node_ptr
    cmp     byte ptr [rax+N_KIND], K_LEAF
    jne     8f
    mov     eax, 1
    ret
8:  xor     eax, eax
9:  ret

poll_float:                             # -> 0, or why not
    sub     rsp, 8
    call    op_can_float
    add     rsp, 8
    test    eax, eax
    lea     rax, [rip+s_no_float+2]
    jz      9f
    xor     eax, eax
9:  ret

poll_dock:
    sub     rsp, 8
    mov     edi, [rip+active_area]
    call    area_is_float
    add     rsp, 8
    test    eax, eax
    lea     rax, [rip+s_not_float]
    jz      9f
    xor     eax, eax
9:  ret

# op_float_x - the active area floats: out of the tree, a panel a little
#   below and to the right of where it was (at most 3/5 of the window)
op_float_x:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    sub     rsp, 16
    call    op_can_float
    test    eax, eax
    jnz     1f
    lea     rdi, [rip+s_no_float]
    call    log_line
    jmp     9f
1:  mov     ebx, [rip+active_area]
    mov     edi, ebx
    call    node_ptr
    movzx   r12d, byte ptr [rax+N_ED]
    mov     r13d, [rax+N_X]
    mov     r14d, [rax+N_Y]
    mov     r15d, [rax+N_W]
    mov     ecx, [rax+N_H]
    mov     [rsp], ecx
    mov     edi, ebx
    call    view_save
    mov     edi, ebx
    call    close_leaf
    test    eax, eax
    jz      9f
    call    node_alloc
    test    eax, eax
    js      9f
    mov     ebx, eax
    call    float_maxz
    mov     [rsp+4], eax
    mov     edi, ebx
    call    node_ptr
    mov     byte ptr [rax+N_KIND], K_LEAF
    mov     [rax+N_ED], r12b
    mov     byte ptr [rax+N_PARENT], NO_NODE
    mov     byte ptr [rax+N_FLAGS], NF_FLOAT
    mov     dword ptr [rax+N_RATIO], 0
    mov     byte ptr [rax+N_A], 0
    mov     byte ptr [rax+N_B], 0
    mov     ecx, [rsp+4]
    inc     ecx
    mov     [rax+N_Z], cl
    add     r13d, 24
    add     r14d, 24
    mov     [rax+N_X], r13d
    mov     [rax+N_Y], r14d
    mov     ecx, [rip+win_w]            # (3/5 of the room at most)
    imul    ecx, ecx, 3
    mov     r8d, 5
    push    rax
    mov     eax, ecx
    cdq
    idiv    r8d
    mov     ecx, eax
    pop     rax
    cmp     r15d, ecx
    cmovg   r15d, ecx
    mov     [rax+N_W], r15d
    mov     ecx, [rip+cont_y1]
    sub     ecx, [rip+cont_y0]
    imul    ecx, ecx, 3
    push    rax
    mov     eax, ecx
    cdq
    idiv    r8d
    mov     ecx, eax
    pop     rax
    mov     edx, [rsp]
    cmp     edx, ecx
    cmovg   edx, ecx
    mov     [rax+N_H], edx
    mov     edi, ebx
    call    view_give
    mov     [rip+active_area], ebx
    cmp     r12d, ED_VIEWPORT
    jne     2f
    mov     [rip+vp_area], ebx
2:  mov     dword ptr [rip+area_maxed], -1
    call    area_layout
    mov     dword ptr [rip+dirty], 1
9:  add     rsp, 16
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# op_dock_x - the active panel docks beside the area under its middle (on
#   the side its middle is on)
op_dock_x:
    push    rbx
    push    r12
    push    r13
    mov     ebx, [rip+active_area]
    mov     edi, ebx
    call    area_is_window
    test    eax, eax
    jz      0f
    mov     edi, ebx
    call    pw_dock_node
    jmp     9f
0:
    mov     edi, ebx
    call    area_is_float
    test    eax, eax
    jz      9f
    mov     edi, ebx
    call    node_ptr
    mov     r12d, [rax+N_W]
    shr     r12d, 1
    add     r12d, [rax+N_X]
    mov     r13d, [rax+N_H]
    shr     r13d, 1
    add     r13d, [rax+N_Y]
    mov     edi, r12d
    mov     esi, r13d
    call    tree_leaf_at
    test    eax, eax
    js      9f
    mov     esi, eax
    push    rsi
    mov     edi, eax
    call    node_ptr
    pop     rsi
    mov     edx, 2                      # the right half: on the right
    mov     ecx, [rax+N_W]
    shr     ecx, 1
    add     ecx, [rax+N_X]
    cmp     r12d, ecx
    jge     1f
    mov     edx, 1
1:  mov     edi, ebx
    call    dock_into
    call    area_layout
9:  pop     r13
    pop     r12
    pop     rbx
    ret

# -----------------------------------------------------------------------------
# ui_tree (menus.s mn_json): an entry an area - its editor, rectangle, and
#   whether it floats
# area_json(edi = entries before) -> eax = entries written
# -----------------------------------------------------------------------------
area_json:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    mov     r15d, edi
    xor     r14d, r14d
    xor     ebx, ebx
1:  mov     edi, ebx
    call    node_ptr
    mov     r12, rax
    cmp     byte ptr [r12+N_KIND], K_LEAF
    jne     8f
    mov     eax, r14d
    add     eax, r15d
    inc     r14d
    test    eax, eax
    jz      2f
    mov     edi, ','
    call    wb_char
2:  lea     rsi, [rip+j_area_a]
    call    wb_str
    mov     edi, ebx
    call    wb_int
    lea     rsi, [rip+j_area_k]
    call    wb_str
    lea     rsi, [rip+j_area_x]
    call    wb_str
    movsxd  rdi, dword ptr [r12+N_X]
    call    wb_int
    lea     rsi, [rip+j_area_y]
    call    wb_str
    movsxd  rdi, dword ptr [r12+N_Y]
    call    wb_int
    lea     rsi, [rip+j_area_w]
    call    wb_str
    movsxd  rdi, dword ptr [r12+N_W]
    call    wb_int
    lea     rsi, [rip+j_area_h]
    call    wb_str
    movsxd  rdi, dword ptr [r12+N_H]
    call    wb_int
    lea     rsi, [rip+j_area_lbl]
    call    wb_str
    movzx   eax, byte ptr [r12+N_ED]
    lea     rcx, [rip+editor_names]
    mov     rsi, [rcx+rax*8]
    call    jb_q
    lea     rsi, [rip+j_area_dk]
    test    byte ptr [r12+N_FLAGS], NF_FLOAT
    jz      3f
    lea     rsi, [rip+j_area_fl]
    test    byte ptr [r12+N_FLAGS], NF_WINDOW
    jz      3f
    lea     rsi, [rip+j_area_wn]
3:  call    wb_str
8:  inc     ebx
    cmp     ebx, MAX_NODES
    jb      1b
    mov     eax, r14d
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret


# =============================================================================
#  Panel windows (#419 stage 2): a floating panel in a window of its own
#  (NF_WINDOW, its slot in N_WND), which can go to another monitor. Area >
#  Open in New Window, or a panel dragged out of the main window, makes one;
#  its header moves the window, its edges resize it, closing it (or its dock
#  button) docks the area back. Its area is drawn in the same frame as the
#  main window, into the panel window's buffer (fb swapped), and the windows
#  are shown after (pw_present_all). Input says which window it is in
#  (wnd_enter: cur_wnd 0 the main window, slot + 1 a panel's); menus, lists,
#  pies and tooltips opened there are drawn there (ovl_wnd, ovl_enter).
# =============================================================================
.globl cur_wnd
.globl ovl_wnd
.globl ht_ovl
.globl wnd_enter
.globl pw_configure
.globl pw_closed
.globl pw_present_all
.globl pw_close_all
.globl pw_scrub
.globl pw_cur_node
.globl pw_edge_hit
.globl area_is_window
.globl ovl_enter
.globl ovl_leave
.globl op_area_window
.globl pw_release

.section .data
.align 4
pw_node:        .long -1, -1, -1, -1    # each slot's area (-1: free)

.section .bss
.align 8
cur_wnd:        .skip 4                 # the window input is in
ovl_wnd:        .skip 4                 #  and the one menus and the like are in
ht_ovl:         .skip 4                 # (hit_test: they are in this one)
pw_cw:          .skip PW_MAX*4          # each slot's logical size (configured)
pw_ch:          .skip PW_MAX*4
pw_drawn:       .skip PW_MAX*4          # drawn this frame: shown after
pw_fb:          .skip PW_MAX*8          #  into this buffer, of
pw_pw:          .skip PW_MAX*4          #  these pixels
pw_ph:          .skip PW_MAX*4
pw_sv:          .skip 32                # the main window's fb, size (swapped)
pw_svon:        .skip 4

.section .rodata
s_no_window:    .asciz "  no window for it (four panel windows at most)"
s_pw_none:      .asciz "panels in windows of their own are not on this system yet"
s_pw_why:       .asciz "the active area is already in a window of its own"

OPERATOR op_area_window, "area.new_window", "Open in New Window", op_window_x, poll=poll_window, doc="Put the active area in a window of its own, which you can move to another monitor; closing that window puts the area back"

.text

# area_is_window(edi=node) -> eax = 1 for a panel in a window of its own
area_is_window:
    xor     eax, eax
    cmp     edi, MAX_NODES
    jae     9f
    call    node_ptr
    cmp     byte ptr [rax+N_KIND], K_LEAF
    jne     8f
    test    byte ptr [rax+N_FLAGS], NF_WINDOW
    jz      8f
    mov     eax, 1
    ret
8:  xor     eax, eax
9:  ret

# ovl_open -> eax = 1 while a menu, an option list, a pie, the wheel or the
#   colour picker is open (they stay in the window they opened in)
ovl_open:
    mov     eax, 1
    cmp     dword ptr [rip+menu_open], 0
    jge     9f
    cmp     dword ptr [rip+wg_pop_open], 0
    jne     9f
    cmp     dword ptr [rip+pie_on], 0
    jne     9f
    cmp     dword ptr [rip+wh_on], 0
    jne     9f
    cmp     dword ptr [rip+cpk_on], 0
    jne     9f
    xor     eax, eax
9:  ret

# wnd_enter(edi=window) - the pointer is in that window now (the platform)
wnd_enter:
    mov     [rip+cur_wnd], edi
    sub     rsp, 8
    call    ovl_open
    add     rsp, 8
    test    eax, eax
    jnz     9f
    mov     eax, [rip+cur_wnd]
    mov     [rip+ovl_wnd], eax
9:  ret

# pw_cur_node -> eax = the panel of the window input is in, -1: the main one
pw_cur_node:
    mov     eax, [rip+cur_wnd]
    dec     eax
    js      8f
    cmp     eax, PW_MAX
    jae     8f
    lea     rcx, [rip+pw_node]
    mov     eax, [rcx+rax*4]
    ret
8:  mov     eax, -1
    ret

# pw_configure(edi=slot, esi=w, edx=h) - the platform: its size (logical)
pw_configure:
    cmp     edi, PW_MAX
    jae     9f
    lea     rax, [rip+pw_cw]
    mov     [rax+rdi*4], esi
    lea     rax, [rip+pw_ch]
    mov     [rax+rdi*4], edx
    mov     dword ptr [rip+dirty], 1
9:  ret

# pw_closed(edi=slot) - the user closed it: its area docks back
pw_closed:
    cmp     edi, PW_MAX
    jae     9f
    lea     rax, [rip+pw_node]
    mov     edi, [rax+rdi*4]
    test    edi, edi
    js      9f
    jmp     pw_dock_node
9:  ret

# pw_release(edi=node) - its window closed; it is a panel in the main window
#   again (or about to dock: the caller's)
pw_release:
    push    rbx
    push    r12
    sub     rsp, 8
    mov     ebx, edi
    call    area_is_window
    test    eax, eax
    jz      9f
    mov     edi, ebx
    call    node_ptr
    movzx   r12d, byte ptr [rax+N_WND]
    and     byte ptr [rax+N_FLAGS], ~NF_WINDOW
    mov     dword ptr [rax+N_X], 40     # (somewhere in the main window)
    mov     ecx, [rip+cont_y0]
    add     ecx, 40
    mov     [rax+N_Y], ecx
    cmp     r12d, PW_MAX
    jae     9f
    lea     rax, [rip+pw_node]
    mov     dword ptr [rax+r12*4], -1
    lea     rax, [rip+pw_drawn]
    mov     dword ptr [rax+r12*4], 0
    mov     edi, r12d
    call    pw_close
    lea     eax, [r12+1]                # (input in it: the main window's now)
    cmp     eax, [rip+cur_wnd]
    jne     1f
    xor     edi, edi
    call    wnd_enter
1:  lea     eax, [r12+1]
    cmp     eax, [rip+ovl_wnd]
    jne     2f
    mov     dword ptr [rip+ovl_wnd], 0
2:  call    dock_clamp
    mov     dword ptr [rip+dirty], 1
9:  add     rsp, 8
    pop     r12
    pop     rbx
    ret

# pw_dock_node(edi=node) - its window closed, it docks beside the area in
#   the middle of the main window
pw_dock_node:
    push    rbx
    mov     ebx, edi
    call    pw_release
    mov     edi, [rip+win_w]
    shr     edi, 1
    mov     esi, [rip+cont_y0]
    add     esi, [rip+cont_y1]
    shr     esi, 1
    call    tree_leaf_at
    test    eax, eax
    js      9f
    mov     esi, eax
    mov     edi, ebx
    mov     edx, 2
    call    dock_into
    call    area_layout
9:  pop     rbx
    ret

# pw_close_all - every panel window closed, its area a panel in the main
#   window (the workspace changes)
pw_close_all:
    push    rbx
    xor     ebx, ebx
1:  lea     rax, [rip+pw_node]
    mov     edi, [rax+rbx*4]
    test    edi, edi
    js      2f
    call    pw_release
2:  inc     ebx
    cmp     ebx, PW_MAX
    jb      1b
    pop     rbx
    ret

# pw_scrub - no area in a window (a layout just read: its windows are gone)
pw_scrub:
    lea     rcx, [rip+nodes]
    xor     eax, eax
1:  and     byte ptr [rcx+N_FLAGS], ~NF_WINDOW
    add     rcx, N_SZ
    inc     eax
    cmp     eax, MAX_NODES
    jb      1b
    ret

# pw_open_node(edi=node) -> eax = 0, -1: that floating panel into a window
pw_open_node:
    push    rbx
    push    r12
    push    r13
    mov     ebx, edi
    xor     r12d, r12d                  # a free slot
    lea     rax, [rip+pw_node]
1:  cmp     dword ptr [rax+r12*4], 0
    jl      2f
    inc     r12d
    cmp     r12d, PW_MAX
    jb      1b
3:  lea     rdi, [rip+s_no_window]
    call    log_line
    mov     eax, -1
    jmp     9f
2:  mov     edi, ebx
    call    node_ptr
    mov     r13, rax
    mov     eax, [r13+N_W]              # its size, in the platform's units
    imul    eax, [rip+pr_scale]
    xor     edx, edx
    mov     ecx, 100
    div     ecx
    mov     esi, eax
    mov     eax, [r13+N_H]
    imul    eax, [rip+pr_scale]
    xor     edx, edx
    div     ecx
    mov     edx, eax
    lea     rax, [rip+pw_cw]
    mov     [rax+r12*4], esi
    lea     rax, [rip+pw_ch]
    mov     [rax+r12*4], edx
    movzx   eax, byte ptr [r13+N_ED]    # titled by its editor
    lea     rcx, [rip+editor_names]
    mov     rcx, [rcx+rax*8]
    mov     edi, r12d
    call    pw_open
    test    eax, eax
    jnz     3b
    lea     rax, [rip+pw_node]
    mov     [rax+r12*4], ebx
    or      byte ptr [r13+N_FLAGS], NF_WINDOW
    mov     [r13+N_WND], r12b
    mov     [rip+active_area], ebx
    mov     dword ptr [rip+dirty], 1
    xor     eax, eax
9:  pop     r13
    pop     r12
    pop     rbx
    ret

poll_window:
    sub     rsp, 8
    call    pw_supported
    test    eax, eax
    lea     rax, [rip+s_pw_none]
    jz      9f
    mov     edi, [rip+active_area]
    call    area_is_window
    test    eax, eax
    lea     rax, [rip+s_pw_why]
    jnz     9f
    mov     edi, [rip+active_area]      # a panel, or an area that can float
    call    area_is_float
    test    eax, eax
    jnz     8f
    call    poll_float
    jmp     9f
8:  xor     eax, eax
9:  add     rsp, 8
    ret

# op_window_x - the active area in a window of its own (floated first)
op_window_x:
    sub     rsp, 8
    mov     edi, [rip+active_area]
    call    area_is_window
    test    eax, eax
    jnz     9f
    mov     edi, [rip+active_area]
    call    area_is_float
    test    eax, eax
    jnz     1f
    call    op_float_x
    mov     edi, [rip+active_area]
    call    area_is_float
    test    eax, eax
    jz      9f
1:  mov     edi, [rip+active_area]
    call    pw_open_node
9:  add     rsp, 8
    ret

# pw_logical(edi=slot) -> eax = w, edx = h in the UI's units
pw_logical:
    lea     rax, [rip+pw_ch]
    mov     ecx, [rax+rdi*4]
    lea     rax, [rip+pw_cw]
    mov     eax, [rax+rdi*4]
    push    rcx
    imul    eax, eax, 100
    xor     edx, edx
    div     dword ptr [rip+pr_scale]
    pop     rcx
    push    rax
    mov     eax, ecx
    imul    eax, eax, 100
    xor     edx, edx
    div     dword ptr [rip+pr_scale]
    mov     edx, eax
    pop     rax
    ret

# fb_save / fb_restore - the main window's framebuffer and size aside
fb_save:
    cmp     dword ptr [rip+pw_svon], 0
    jne     9f
    mov     rax, [rip+fb_ptr]
    mov     [rip+pw_sv], rax
    mov     eax, [rip+fb_w]
    mov     [rip+pw_sv+8], eax
    mov     eax, [rip+fb_h]
    mov     [rip+pw_sv+12], eax
    mov     eax, [rip+win_w]
    mov     [rip+pw_sv+16], eax
    mov     eax, [rip+win_h]
    mov     [rip+pw_sv+20], eax
    mov     dword ptr [rip+pw_svon], 1
9:  ret
fb_restore:
    cmp     dword ptr [rip+pw_svon], 0
    je      9f
    mov     rax, [rip+pw_sv]
    mov     [rip+fb_ptr], rax
    mov     eax, [rip+pw_sv+8]
    mov     [rip+fb_w], eax
    mov     eax, [rip+pw_sv+12]
    mov     [rip+fb_h], eax
    mov     eax, [rip+pw_sv+16]
    mov     [rip+win_w], eax
    mov     eax, [rip+pw_sv+20]
    mov     [rip+win_h], eax
    mov     dword ptr [rip+pw_svon], 0
    sub     rsp, 8
    call    reset_clip
    add     rsp, 8
9:  ret

# fb_use(edi=slot) - draw into that panel window (its buffer, its size)
fb_use:
    push    rbx
    mov     ebx, edi
    call    fb_save
    lea     rax, [rip+pw_fb]
    mov     rax, [rax+rbx*8]
    mov     [rip+fb_ptr], rax
    lea     rax, [rip+pw_pw]
    mov     eax, [rax+rbx*4]
    mov     [rip+fb_w], eax
    lea     rax, [rip+pw_ph]
    mov     eax, [rax+rbx*4]
    mov     [rip+fb_h], eax
    mov     edi, ebx
    call    pw_logical
    mov     [rip+win_w], eax
    mov     [rip+win_h], edx
    call    reset_clip
    pop     rbx
    ret

# pw_draw_all - each panel window's area into its buffer (dock_draw: after
#   the main window's panels; shown by pw_present_all)
pw_draw_all:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    xor     ebx, ebx
1:  lea     rax, [rip+pw_drawn]
    mov     dword ptr [rax+rbx*4], 0
    lea     rax, [rip+pw_node]
    mov     r12d, [rax+rbx*4]
    test    r12d, r12d
    js      8f
    mov     edi, ebx
    call    pw_ready
    test    eax, eax
    jnz     2f
    mov     dword ptr [rip+redraw_again], 1     # (its frame later)
    jmp     8f
2:  mov     edi, ebx
    call    pw_logical
    mov     r13d, eax                   # w, h (the UI's units)
    mov     r14d, edx
    mov     edi, r13d
    call    to_px
    mov     r15d, eax
    mov     edi, r14d
    call    to_px
    lea     rcx, [rip+pw_pw]
    mov     [rcx+rbx*4], r15d
    lea     rcx, [rip+pw_ph]
    mov     [rcx+rbx*4], eax
    mov     edi, ebx
    mov     esi, r15d
    mov     edx, eax
    call    pw_buffer
    test    rax, rax
    jnz     3f
    mov     dword ptr [rip+redraw_again], 1
    jmp     8f
3:  lea     rcx, [rip+pw_fb]
    mov     [rcx+rbx*8], rax
    mov     edi, r12d                   # its area: all of the window
    call    node_ptr
    mov     dword ptr [rax+N_X], 0
    mov     dword ptr [rax+N_Y], 0
    mov     [rax+N_W], r13d
    mov     [rax+N_H], r14d
    mov     edi, ebx
    call    fb_use
    lea     rax, [rip+flt_wlo]
    mov     ecx, [rip+wg_n]
    mov     [rax+r12*4], ecx
    mov     edi, r12d
    call    draw_leaf
    lea     rax, [rip+flt_whi]
    mov     ecx, [rip+wg_n]
    mov     [rax+r12*4], ecx
    call    fb_restore
    lea     rax, [rip+pw_drawn]
    mov     dword ptr [rax+rbx*4], 1
8:  inc     ebx
    cmp     ebx, PW_MAX
    jb      1b
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# pw_present_all - the panel windows drawn this frame shown (window.s render)
pw_present_all:
    push    rbx
    xor     ebx, ebx
1:  lea     rax, [rip+pw_drawn]
    cmp     dword ptr [rax+rbx*4], 0
    je      2f
    mov     dword ptr [rax+rbx*4], 0
    mov     edi, ebx
    call    pw_present
2:  inc     ebx
    cmp     ebx, PW_MAX
    jb      1b
    pop     rbx
    ret

# ovl_enter / ovl_leave - menus and the like drawn in the window they are
#   in (ui_draw); nothing to do for the main window's
ovl_enter:
    mov     edi, [rip+ovl_wnd]
    dec     edi
    js      9f
    cmp     edi, PW_MAX
    jae     9f
    lea     rax, [rip+pw_drawn]
    cmp     dword ptr [rax+rdi*4], 0
    je      9f
    jmp     fb_use
9:  ret
ovl_leave:
    jmp     fb_restore

# pw_edge_hit(edi=x, esi=y) -> eax = the edges of the panel window input is
#   in that the point is on (2 bottom, 4 left, 8 right), edx = its node
pw_edge_hit:
    push    rbx
    push    r12
    sub     rsp, 8
    mov     ebx, edi
    mov     r12d, esi
    call    pw_cur_node
    mov     r8d, eax
    xor     eax, eax
    test    r8d, r8d
    js      9f
    push    r8
    mov     edi, r8d
    call    node_ptr
    pop     r8
    xor     edx, edx
    cmp     ebx, FL_EDGE
    jge     1f
    or      edx, 4
1:  mov     ecx, [rax+N_W]
    sub     ecx, ebx
    cmp     ecx, FL_EDGE
    jg      2f
    or      edx, 8
2:  mov     ecx, [rax+N_H]
    sub     ecx, r12d
    cmp     ecx, FL_EDGE
    jg      3f
    or      edx, 2
3:  mov     eax, edx
9:  mov     edx, r8d
    add     rsp, 8
    pop     r12
    pop     rbx
    ret

.section .note.GNU-stack,"",@progbits
