# =============================================================================
#  BeeModel - the node editor area
#
#  Shows the shader graph of the active object's material: each node a box
#  (header, its output, its values, its inputs), the Material Output on the
#  right, wires from outputs to inputs. Shift+A adds a node at the pointer
#  (a menu); dragging a header moves a node; dragging from an output to an
#  input (or a material socket) links them, from a linked input picks the
#  link up (dropped elsewhere it is gone); dragging a value sideways
#  changes it; X / Delete removes the selected node; middle or empty-space
#  drags pan, the wheel scrolls, Home fits. Links may go either way: the
#  graph keeps itself in evaluation order and refuses loops. Positions live
#  in the material record (saved, undone with it); nodes never placed are
#  laid out by their depth in the graph.
# =============================================================================
.intel_syntax noprefix
.include "const.inc"
.include "widgets.inc"
.include "macros.inc"

.globl ed_nodes_draw
.globl nodeed_press
.globl nodeed_motion
.globl nodeed_release
.globl nodeed_wheel
.globl nodeed_key
.globl ne_drag
.globl ne_menu

.equ GR_N,      128
.equ GR_SOCK,   132
.equ GR_OUTPOS, 152
.equ GR_NODES,  160
.equ NODE_SZ,   72
.equ ND_TYPE,   0
.equ ND_IN,     4
.equ ND_P,      52
.equ ND_POS,    68
.equ IR_NAME,   0

.equ MT_GEONODES_, 10                     # (mods.s)
.equ MT_LOGIC_,  12
.equ NE_BAR,    20                      # the header line (logical px)
.equ NW,        170                     # node width
.equ NHDR,      20                      # node header
.equ NROW,      18                      # a row
.equ NSOCK_R,   4                       # socket half size
.equ COLW,      200                     # auto layout: column step
.equ MENU_W,    170
.equ MROWS,     18                      # the add menu: rows a column

.equ COL_NE_BG,     0x23262c
.equ COL_NE_GRID,   0x2b2f36
.equ COL_NE_FRBODY, 0x2b3038            # comment frames: body, title bar
.equ COL_NE_FRBAR,  0x3a4352
.equ COL_NE_BODY,   0x343841
.equ COL_NE_EDGE,   0x16181c
.equ COL_NE_TEX,    0x6b4f96            # header colours by kind
.equ COL_NE_CONV,   0x2f6589
.equ COL_NE_VEC,    0x6a3b63
.equ COL_NE_OUT,    0x8a3b3b
.equ COL_NE_WIRE,   0xb8bcc4
.equ COL_NE_SOCK_C, 0xe3c84a            # colour sockets
.equ COL_NE_SOCK_V, 0xa1a1a1            # values
.equ COL_NE_SOCK_N, 0x6363c7            # vectors / normals
.equ COL_NE_SOCK_G, 0x00d6a3            # geometry
.equ COL_NE_SOCK_R, 0xf0f0f0            # logic: run
.equ COL_NE_GEO,    0x1d725e            # geometry nodes' headers
.equ COL_NE_GRP,    0x6e5418            # group nodes

.section .rodata
.align 4
nf_hundred:     .float 100.0
nf_step:        .float 0.01
nf_half:        .float 0.5
nf_one:         .float 1.0
nf_seg:         .float 0.0625           # 1/16
nf_three:       .float 3.0
s_ne_head:      .asciz "Material: "
s_ne_keys:      .asciz "     Shift+A add  X delete  Home fit"
s_ne_none:      .asciz "Node editor: the active object's material graph (an object with a material: Properties > Material > New)"
s_ne_out:       .asciz "Material Output"
s_ne_color:     .asciz "Color"
s_ne_value:     .asciz "Value"
s_ne_normal:    .asciz "Normal"
.align 4
ne_kind_col:    .long COL_NE_SOCK_G, COL_NE_SOCK_V, COL_NE_SOCK_N, COL_NE_SOCK_C, COL_NE_SOCK_R
s_ne_noimg:     .asciz "(none)"
s_ne_implicit:  .asciz "position"
s_ne_add:       .asciz "Add node"
s_ne_full:      .asciz "  node editor: the graph is full (12 shader nodes, 48 in a tree)"
s_op_link:      .asciz "material.link"
s_tp_link:      .asciz "tree.link"
s_tp_node:      .asciz "tree.node"
s_tp_delete:    .asciz "tree.node_delete"
s_tp_set:       .asciz "tree.node_set"
s_ne_ghead:     .asciz "Geometry: "
s_ne_grhead:    .asciz "Group: "
s_ne_grkeys:    .asciz "     Shift+A add  X delete  Ctrl+G group  Tab back"
s_tp_group:     .asciz "tree.group"
s_ne_gkeys:     .asciz "     Shift+A add  X delete  Ctrl+G group  Tab material / into a group"
s_ne_tabgeo:    .asciz "  Tab geometry"
s_ne_lhead:     .asciz "Logic: "
s_ne_lkeys:     .asciz "     Shift+A add  X delete  Tab material  (runs in play mode, F5)"
s_tp_lnode:     .asciz "logic.node"
s_tp_lname:     .asciz "logic.name "
s_op_socket:    .asciz "material.socket"
s_op_node:      .asciz "material.node"
s_op_delete:    .asciz "material.node_delete"
s_op_set:       .asciz "material.node_set"
s_undo_move:    .asciz "Move Node"
s_undo_value:   .asciz "Change Node Value"
s_undo_paste:   .asciz "Paste Nodes"
s_undo_del:     .asciz "Delete Nodes"
s_undo_coll:    .asciz "Collapse Nodes"
s_undo_frame:   .asciz "Comment Frame"
s_fr_title:     .asciz "Comment"
s_op_frtitle:   .asciz "node.frame_title "
s_ne_frfull:    .asciz "  a graph holds 6 comment frames"
s_ne_frneed:    .asciz "  node.frame_title <frame 1-6> <title>"
s_undo_dup:     .asciz "Duplicate Nodes"
s_ne_copied:    .asciz "  nodes copied: "
s_ne_noroom:    .asciz "  not enough room: a graph holds 48 nodes"
s_ne_clipkind:  .asciz "  the clipboard holds nodes of another kind"
s_none_w:       .asciz "none"
# the Material Output's pins
ne_out_names:   .quad o_base, o_metal, o_spec, o_rough, o_emit, o_alpha, o_normal
                .quad o_ao, o_coat, o_coatr, o_trans, o_ior, o_mask
o_base:         .asciz "Base Color"
o_metal:        .asciz "Metallic"
o_spec:         .asciz "Specular"
o_rough:        .asciz "Roughness"
o_emit:         .asciz "Emission"
o_alpha:        .asciz "Opacity"
o_normal:       .asciz "Normal"
o_ao:           .asciz "Ambient Occlusion"
o_coat:         .asciz "Clear Coat"
o_coatr:        .asciz "Coat Roughness"
o_trans:        .asciz "Transmission"
o_ior:          .asciz "IOR"
o_mask:         .asciz "Opacity Mask"
.section .data
.align 4
.equ NZSTEPS,   12
ne_zsteps:      .long 25, 33, 50, 67, 75, 90, 100, 110, 125, 150, 175, 200
# the zoom (percent) and the sizes on screen it gives (zoom_apply); at 100 %
#   the constants above
ne_zoom:        .long 100
ne_nw:          .long NW
ne_hdr:         .long NHDR
ne_row:         .long NROW
ne_r2:          .long NROW/2
ne_hr2:         .long NHDR+NROW/2
ne_sr:          .long NSOCK_R
ne_pad:         .long 10                # text in from the box's sides
ne_ins:         .long 6                 # a value's field: in from the side
ne_ty:          .long 2                 # text in a row, in the header
ne_hy:          .long 3
ne_sw:          .long 24                # a colour swatch
ne_h6:          .long 6                 # below the last row
ne_grid:        .long 40                # the dot grid's step
ne_txt:         .long 1                 # rows' text drawn (0: zoomed far out)
.section .bss
.align 8
ne_clipk:       .skip 4                 # the node clipboard: kind (material,
ne_clipn:       .skip 4                 #  tree, logic), count, where from,
ne_clipm:       .skip 4                 #  the nodes (internal links: bit 30),
ne_clipx0:      .skip 4                 #  their places (graph units) and the
ne_clipy0:      .skip 4                 #  group's top left
ne_clipnodes:   .skip NODE_SZ*48
ne_clippos:     .skip 8*48
ne_cmap:        .skip 4*49              # (copy: old node -> clipboard place + 1)
ne_panx:        .skip 4                 # the view: where graph (0, 0) is
ne_pany:        .skip 4                 #  (from the body's top left)
ne_mat:         .skip 4                 # the material shown (-1: none)
ne_n:           .skip 4                 # its nodes when drawn
ne_lx:          .skip 4*49              # their boxes on screen (0: the output)
ne_ly:          .skip 4*49
ne_lh:          .skip 4*49
ne_gh:          .skip 4*49              # (heights in the graph: the layout)
ne_gx:          .skip 4*49              # and in the graph (laid out)
ne_gy:          .skip 4*49
ne_depth:       .skip 4*49
ne_coly:        .skip 4*16
ne_kind:        .skip 4                 # 0 a material's graph, 1 a node tree
ne_pref:        .skip 4                 # 1: the material even with a tree
ne_maxn:        .skip 4
.align 8
ne_selm:        .skip 8                 # selected nodes (bit n: node n)
ne_path:        .skip 4*8               # groups entered: their tree numbers
ne_pathn:       .skip 4
ne_sel:         .skip 4                 # the selected node (0: none)
ne_drag:        .skip 4                 # 0 none, 1 move, 2 wire from an output,
                                        #  3 wire from an input, 4 from a
                                        #  material socket, 5 a value, 6 an
                                        #  input's value, 7 pan
ne_dn:          .skip 4                 # the node dragged (or from)
ne_dk:          .skip 4                 # its socket / value
ne_fsel:        .skip 4                 # the selected comment frame + 1
ne_fmask:       .skip 8                 # nodes inside the frame being moved
ne_fx0:         .skip 4                 # its place / size when the drag began
ne_fy0:         .skip 4
ne_fwas:        .skip 4                 # it was selected already (a rename)
ne_pend:        .skip 4                 # a wire dropped in empty space: the node
ne_pnode:       .skip 4                 #  added next is linked (1 from ne_pnode's
ne_pk:          .skip 4                 #  output ne_pk, 2 into its input ne_pk,
ne_pick:        .skip 4                 #  3 to pin ne_pk); a link picked up
ne_ax:          .skip 4                 # the pointer when the add menu opened
ne_ay:          .skip 4
ne_sx:          .skip 4*49              # a selection's places when its move began
ne_sy:          .skip 4*49
ne_x0:          .skip 4                 # the press
ne_y0:          .skip 4
ne_a0:          .skip 4                 # what was there: x / y / pan / value
ne_b0:          .skip 4
ne_undone:      .skip 4                 # the drag has its undo step
ne_filt:        .skip 32                # the add menu's search text
ne_fn:          .skip 4                 #  (its length)
ne_dt:          .skip 4
ne_tsel:        .skip 4                 # the header's tree picker
.align 8
ne_tlbl:        .skip 8*80
ne_menu:        .skip 4                 # the add menu: open, where
ne_mx:          .skip 4
ne_my:          .skip 4
ne_bx:          .skip 4                 # the last drawn body
ne_by:          .skip 4
ne_bw:          .skip 4
ne_bh:          .skip 4
ne_argbuf:      .skip 160

.text
OPERATOR op_ne_add,    "node.add_menu", "Add Node...", do_ne_add_menu, key=KEY_A|KM_SHIFT, flags=OPF_AI_SAFE|OPF_QUIET|OPF_NODE, doc="Node editor: the menu of node types at the pointer"
OPERATOR op_ne_del,    "node.delete", "Delete Node", do_ne_delete, key=KEY_X, flags=OPF_AI_SAFE|OPF_QUIET|OPF_NODE, doc="Node editor: remove the selected node"
OPERATOR op_ne_del2,   "node.delete_key", "Delete Node", do_ne_delete, key=KEY_DELETE, flags=OPF_AI_SAFE|OPF_QUIET|OPF_NODE|OPF_HIDDEN, doc="Node editor: remove the selected node"
OPERATOR op_ne_tab,    "node.toggle_tree", "Material / Geometry Nodes", do_ne_tab, key=KEY_TAB, flags=OPF_AI_SAFE|OPF_QUIET|OPF_NODE, doc="Node editor: the active object's material graph or its geometry node tree"
OPERATOR op_ne_group,  "node.group", "Make Node Group", do_ne_group, key=KEY_G|KM_CTRL, flags=OPF_AI_SAFE|OPF_QUIET|OPF_NODE, doc="Node editor: the selected geometry nodes into a group (a new tree run by one node)"
OPERATOR op_ne_fit,    "node.view_fit", "Frame All", do_ne_fit, key=KEY_HOME, flags=OPF_AI_SAFE|OPF_QUIET|OPF_NODE, doc="Node editor: every node in view (zoomed to fit, at most 100 %)"
OPERATOR op_ne_copy,   "node.copy", "Copy Nodes", do_ne_copy, key=KEY_C|KM_CTRL, flags=OPF_AI_SAFE|OPF_QUIET|OPF_NODE, doc="Node editor: the selected nodes to the node clipboard (with the links between them)"
OPERATOR op_ne_paste,  "node.paste", "Paste Nodes", do_ne_paste, key=KEY_V|KM_CTRL, flags=OPF_AI_SAFE|OPF_QUIET|OPF_NODE, doc="Node editor: the clipboard's nodes at the pointer (another material or tree of the same kind too)"
OPERATOR op_ne_dup,    "node.duplicate", "Duplicate Nodes", do_ne_dup, key=KEY_D|KM_SHIFT, flags=OPF_AI_SAFE|OPF_QUIET|OPF_NODE, doc="Node editor: copies of the selected nodes, a little down and right (links into them kept)"
OPERATOR op_ne_dup2,   "node.duplicate_ctrl", "Duplicate Nodes", do_ne_dup, key=KEY_D|KM_CTRL, flags=OPF_AI_SAFE|OPF_QUIET|OPF_NODE|OPF_HIDDEN, doc="Node editor: copies of the selected nodes"
OPERATOR op_ne_cut,    "node.cut", "Cut Nodes", do_ne_cut, key=KEY_X|KM_CTRL, flags=OPF_AI_SAFE|OPF_QUIET|OPF_NODE, doc="Node editor: the selected nodes to the clipboard, then removed"
OPERATOR op_ne_coll,   "node.collapse", "Collapse Nodes", do_ne_collapse, key=KEY_H, flags=OPF_AI_SAFE|OPF_QUIET|OPF_NODE, doc="Node editor: the selected nodes shown as their headers alone (again: whole)"
OPERATOR op_ne_comment, "node.comment", "Comment Frame", do_ne_comment, key=KEY_C, flags=OPF_AI_SAFE|OPF_QUIET|OPF_NODE, doc="Node editor: a comment frame around the selected nodes (moving its title moves them)"
OPERATOR op_ne_frtitle, "node.frame_title", "Rename Comment", do_ne_frtitle, flags=OPF_AI_SAFE|OPF_UNDO|OPF_NODE, doc="Node editor: a comment frame's title: node.frame_title <frame 1-6> <title>"
OPERATOR op_ne_fsel,   "node.view_selected", "Frame Selected", do_ne_frame_sel, key=KEY_F, flags=OPF_AI_SAFE|OPF_QUIET|OPF_NODE, doc="Node editor: the selected nodes in view"

# ne_rec -> rax = the record shown (0: none): the active object's geometry
#   node tree (its first Geometry Nodes modifier's) unless the material is
#   asked for (Tab), else its material's graph; ne_kind, ne_mat (the tree or
#   material index), ne_maxn set
ne_rec:
    push    rbx
    mov     dword ptr [rip+ne_mat], -1
    mov     dword ptr [rip+ne_kind], 0
    mov     dword ptr [rip+ne_maxn], 48
    mov     ecx, [rip+ne_pathn]         # inside a group: that tree
    test    ecx, ecx
    jz      0f
    lea     rax, [rip+ne_path]
    mov     edi, [rax+rcx*4-4]
    dec     edi
    mov     [rip+ne_mat], edi
    call    nt_get
    test    rax, rax
    jz      71f
    mov     dword ptr [rip+ne_kind], 1
    mov     dword ptr [rip+ne_maxn], 48
    jmp     9f
71: mov     dword ptr [rip+ne_pathn], 0  # (gone: back out)
    mov     dword ptr [rip+ne_mat], -1
0:  mov     edi, [rip+active_obj]
    test    edi, edi
    jz      8f
    call    obj_get
    test    rax, rax
    jz      8f
    mov     rbx, rax
    cmp     dword ptr [rip+ne_pref], 0
    jne     3f
    mov     rdx, [rbx+OB_MODS]          # a Logic modifier with its graph
    test    rdx, rdx
    jz      3f
    xor     ecx, ecx
61: cmp     ecx, [rdx+4]
    jae     63f
    imul    eax, ecx, 48
    cmp     dword ptr [rdx+16+rax], 12
    jne     62f
    cvttss2si eax, [rdx+16+rax+8]
    dec     eax
    js      62f
    push    rcx
    push    rdx
    push    rax
    mov     edi, eax
    call    lg_is_logic
    mov     ecx, eax
    pop     rax
    pop     rdx
    test    ecx, ecx
    pop     rcx
    jz      62f
    mov     [rip+ne_mat], eax
    mov     edi, eax
    call    nt_get
    test    rax, rax
    jz      62f
    mov     dword ptr [rip+ne_kind], 2
    mov     dword ptr [rip+ne_maxn], 48
    jmp     9f
62: inc     ecx
    jmp     61b
63: mov     rdx, [rbx+OB_MODS]          # a Geometry Nodes modifier with a tree
    xor     ecx, ecx
1:  cmp     ecx, [rdx+4]
    jae     3f
    imul    eax, ecx, 48
    cmp     dword ptr [rdx+16+rax], 10
    jne     2f
    cvttss2si eax, [rdx+16+rax+8]
    dec     eax
    js      2f
    mov     [rip+ne_mat], eax
    mov     edi, eax
    call    nt_get
    test    rax, rax
    jz      2f
    mov     dword ptr [rip+ne_kind], 1
    mov     dword ptr [rip+ne_maxn], 48
    jmp     9f
2:  inc     ecx
    jmp     1b
3:  mov     rdi, rbx                    # the material
    call    mat_of
    mov     [rip+ne_mat], eax
    test    eax, eax
    js      8f
    mov     edi, eax
    call    mat_get
    jmp     9f
8:  xor     eax, eax
9:  pop     rbx
    ret

# ne_ntypes -> eax = the node types of the kind shown
ne_ntypes:
    mov     eax, [rip+graph_ntypes]
    cmp     dword ptr [rip+ne_kind], 0
    je      1f
    mov     eax, [rip+gn_ntypes]
    cmp     dword ptr [rip+ne_kind], 2
    jne     1f
    mov     eax, [rip+lg_ntypes]
1:  ret

# ne_title(edi=type) -> rax = its name
ne_title:
    lea     rax, [rip+mn_titles]
    cmp     dword ptr [rip+ne_kind], 0
    je      1f
    lea     rax, [rip+gn_titles]
    cmp     dword ptr [rip+ne_kind], 2
    jne     1f
    lea     rax, [rip+lg_titles]
1:  mov     rax, [rax+rdi*8]
    ret

# ne_meta_of(edi=type) -> rax = its meta row (7 pointers) or 0
ne_meta_of:
    push    rdi
    call    ne_ntypes
    pop     rdi
    mov     ecx, eax
    xor     eax, eax
    test    edi, edi
    jle     9f
    cmp     edi, ecx
    ja      9f
    imul    eax, edi, 56
    lea     rcx, [rip+mn_meta]
    cmp     dword ptr [rip+ne_kind], 0
    je      1f
    lea     rcx, [rip+gn_meta]
    cmp     dword ptr [rip+ne_kind], 2
    jne     1f
    lea     rcx, [rip+lg_meta]
1:  add     rax, rcx
9:  ret

# ne_nouts(edi=type) -> eax = its outputs
ne_nouts:
    call    ne_meta_of
    test    rax, rax
    jz      8f
    mov     rcx, [rax+40]
    mov     edx, 3                      # (materials: up to 8)
    cmp     dword ptr [rip+ne_kind], 0
    jne     0f
    mov     edx, 8
0:  xor     eax, eax
1:  cmp     eax, edx
    jae     9f
    cmp     qword ptr [rcx+rax*8], 0
    je      9f
    inc     eax
    jmp     1b
8:  xor     eax, eax
9:  ret

# ne_link_node(eax = a link) -> eax = its node (ecx = the output it takes)
ne_link_node:
    mov     ecx, eax
    shr     ecx, 16
    and     ecx, 0xff
    movzx   eax, ax
    ret

# ne_counts(edi=type) -> eax = inputs, edx = values
ne_counts:
    call    ne_meta_of
    test    rax, rax
    jz      8f
    mov     rcx, [rax]
    xor     eax, eax
1:  cmp     eax, 3
    jae     2f
    cmp     qword ptr [rcx+rax*8], 0
    je      2f
    inc     eax
    jmp     1b
2:  push    rax
    mov     edi, edi
    call    ne_meta_of
    mov     rcx, [rax+16]
    xor     edx, edx
3:  cmp     edx, 4
    jae     4f
    cmp     qword ptr [rcx+rdx*8], 0
    je      4f
    inc     edx
    jmp     3b
4:  pop     rax
    ret
8:  xor     eax, eax
    xor     edx, edx
    ret

# ne_height(edi=type) -> eax = a node's box height
ne_height:
    push    rbx
    push    r12
    sub     rsp, 8
    mov     ebx, edi
    call    ne_nouts
    mov     r12d, eax
    mov     edi, ebx
    call    ne_counts
    add     eax, edx
    add     eax, r12d
    imul    eax, eax, NROW
    add     eax, NHDR+6
    add     rsp, 8
    pop     r12
    pop     rbx
    ret

# ne_height_s(edi=type) -> eax = a node's box height on screen
ne_height_s:
    push    rbx
    push    r12
    sub     rsp, 8
    mov     ebx, edi
    call    ne_nouts
    mov     r12d, eax
    mov     edi, ebx
    call    ne_counts
    add     eax, edx
    add     eax, r12d
    imul    eax, [rip+ne_row]
    add     eax, [rip+ne_hdr]
    add     eax, [rip+ne_h6]
    add     rsp, 8
    pop     r12
    pop     rbx
    ret

# zs(eax) -> eax = eax x the zoom (rounded)
zs:
    imul    eax, [rip+ne_zoom]
    add     eax, 50
    cdq
    mov     ecx, 100
    idiv    ecx
    ret

# zoom_apply - the sizes on screen for ne_zoom (and the text's size)
zoom_apply:
    sub     rsp, 8
    mov     eax, NW
    call    zs
    mov     [rip+ne_nw], eax
    mov     eax, NHDR
    call    zs
    mov     [rip+ne_hdr], eax
    mov     eax, NROW
    call    zs
    mov     [rip+ne_row], eax
    shr     eax, 1
    mov     [rip+ne_r2], eax
    add     eax, [rip+ne_hdr]
    mov     [rip+ne_hr2], eax
    mov     eax, NSOCK_R
    call    zs
    cmp     eax, 2
    jge     1f
    mov     eax, 2
1:  mov     [rip+ne_sr], eax
    mov     eax, 10
    call    zs
    mov     [rip+ne_pad], eax
    mov     eax, 6
    call    zs
    mov     [rip+ne_ins], eax
    mov     [rip+ne_h6], eax
    mov     eax, 24
    call    zs
    mov     [rip+ne_sw], eax
    mov     eax, 40
    call    zs
    cmp     eax, 10
    jge     2f
    mov     eax, 10
2:  mov     [rip+ne_grid], eax
    mov     eax, [rip+ne_row]           # text centred in a row: CHAR_H tall
    sub     eax, CHAR_H                 #  at this zoom's size
    sar     eax, 1
    inc     eax
    mov     [rip+ne_ty], eax
    mov     eax, [rip+ne_hdr]
    sub     eax, CHAR_H
    sar     eax, 1
    inc     eax
    mov     [rip+ne_hy], eax
    mov     dword ptr [rip+ne_txt], 1   # (far out: only the titles)
    cmp     dword ptr [rip+ne_zoom], 50
    jge     3f
    mov     dword ptr [rip+ne_txt], 0
3:  mov     eax, UI_FONT_PX             # the text's size
    call    zs
    cmp     eax, 6
    jge     4f
    mov     eax, 6
4:  cmp     eax, [rip+node_font_px]
    je      5f
    mov     [rip+node_font_px], eax
    mov     edi, FONT_NODE
    mov     esi, eax
    call    font_set_size
5:  add     rsp, 8
    ret

# ne_layout(rdi=record) - every node's box (graph and screen), ne_n
ne_layout:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    push    rbp
    sub     rsp, 8
    mov     rbx, rdi
    mov     r12d, [rbx+GR_N]
    cmp     r12d, [rip+ne_maxn]
    jbe     1f
    mov     r12d, [rip+ne_maxn]
1:  mov     [rip+ne_n], r12d
    lea     rdi, [rip+ne_coly]          # columns' next free y
    mov     ecx, 16
    mov     eax, 20
    rep     stosd
    lea     rdi, [rip+ne_depth]
    mov     ecx, 49
    xor     eax, eax
    rep     stosd
    mov     ebp, 4                      # depths: 1 + the deepest input (a
.Lnl_pass:                              #  few passes: links go any way)
    xor     r13d, r13d
2:  cmp     r13d, r12d
    jae     .Lnl_passed
    imul    r14d, r13d, NODE_SZ
    lea     r14, [rbx+GR_NODES+r14]
    xor     edx, edx
    xor     ecx, ecx
3:  imul    eax, ecx, 16
    movzx   eax, word ptr [r14+ND_IN+rax]
    test    eax, eax
    jz      31f
    cmp     eax, r12d
    ja      31f
    lea     r8, [rip+ne_depth]
    mov     eax, [r8+rax*4]
    inc     eax
    cmp     eax, edx
    cmovg   edx, eax
31: inc     ecx
    cmp     ecx, 3
    jb      3b
    cmp     edx, 15
    jbe     32f
    mov     edx, 15
32: lea     r8, [rip+ne_depth]
    mov     [r8+r13*4+4], edx
    inc     r13d
    jmp     2b
.Lnl_passed:
    dec     ebp
    jnz     .Lnl_pass
    xor     r15d, r15d                  # (the deepest)
    xor     r13d, r13d                  # boxes
4:  cmp     r13d, r12d
    jae     6f
    imul    r14d, r13d, NODE_SZ
    lea     r14, [rbx+GR_NODES+r14]
    lea     r8, [rip+ne_depth]
    mov     edx, [r8+r13*4+4]
    cmp     edx, r15d
    cmova   r15d, edx
    mov     edi, [r14+ND_TYPE]
    push    rdx
    push    rdx
    call    ne_height
    pop     rdx
    pop     rdx
    test    byte ptr [rbx+NE_NFLAGS+r13], 1 # (collapsed: the header)
    jz      41f
    mov     eax, NHDR
41: lea     r8, [rip+ne_gh]
    mov     [r8+r13*4+4], eax
    movsx   ecx, word ptr [r14+ND_POS]
    movsx   esi, word ptr [r14+ND_POS+2]
    mov     edi, ecx
    or      edi, esi
    jnz     5f
    imul    ecx, edx, COLW              # not placed: its depth's column
    add     ecx, 20
    lea     r8, [rip+ne_coly]
    mov     esi, [r8+rdx*4]
    add     eax, 20
    add     [r8+rdx*4], eax
5:  lea     r8, [rip+ne_gx]
    mov     [r8+r13*4+4], ecx
    lea     r8, [rip+ne_gy]
    mov     [r8+r13*4+4], esi
    inc     r13d
    jmp     4b
6:  mov     eax, [rip+ne_row]           # the material output
    imul    eax, eax, NPINS
    add     eax, [rip+ne_hdr]
    add     eax, [rip+ne_h6]
    mov     [rip+ne_lh], eax
    mov     dword ptr [rip+ne_gh], NHDR+NPINS*NROW+6
    cmp     dword ptr [rip+ne_kind], 0
    je      61f
    mov     dword ptr [rip+ne_lh], 0    # (trees: none)
    mov     dword ptr [rip+ne_gh], 0
    mov     dword ptr [rip+ne_gx], -30000
    mov     dword ptr [rip+ne_gy], -30000
    jmp     7f
61: movsx   ecx, word ptr [rbx+GR_OUTPOS]
    movsx   esi, word ptr [rbx+GR_OUTPOS+2]
    mov     eax, ecx
    or      eax, esi
    jnz     62f
    lea     eax, [r15+1]
    test    r12d, r12d
    jnz     63f
    xor     eax, eax
63: imul    ecx, eax, COLW
    add     ecx, 20
    mov     esi, 20
62: mov     [rip+ne_gx], ecx
    mov     [rip+ne_gy], esi
7:  mov     r13d, 1                     # on screen: heights, then places
71: cmp     r13d, r12d
    ja      72f
    imul    r14d, r13d, NODE_SZ
    mov     edi, [rbx+GR_NODES+r14-NODE_SZ+ND_TYPE]
    call    ne_height_s
    test    byte ptr [rbx+NE_NFLAGS+r13-1], 1
    jz      73f
    mov     eax, [rip+ne_hdr]
73: lea     r8, [rip+ne_lh]
    mov     [r8+r13*4], eax
    inc     r13d
    jmp     71b
72: xor     r13d, r13d
8:  cmp     r13d, r12d
    ja      9f
    lea     r8, [rip+ne_gx]
    mov     eax, [r8+r13*4]
    call    zs
    add     eax, [rip+ne_bx]
    add     eax, [rip+ne_panx]
    lea     r8, [rip+ne_lx]
    mov     [r8+r13*4], eax
    lea     r8, [rip+ne_gy]
    mov     eax, [r8+r13*4]
    call    zs
    add     eax, [rip+ne_by]
    add     eax, [rip+ne_pany]
    lea     r8, [rip+ne_ly]
    mov     [r8+r13*4], eax
    inc     r13d
    jmp     8b
9:  add     rsp, 8
    pop     rbp
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# ne_out_xy(edi=node, esi=output k) -> eax, edx = that output socket
ne_out_xy:
    lea     r8, [rip+ne_lx]
    mov     eax, [r8+rdi*4]
    add     eax, [rip+ne_nw]
    lea     r8, [rip+ne_ly]
    mov     edx, [r8+rdi*4]
    test    edi, edi
    jz      1f
    test    byte ptr [rbx+NE_NFLAGS+rdi-1], 1   # (collapsed: the header's side)
    jz      1f
    mov     ecx, [rip+ne_hdr]
    shr     ecx, 1
    add     edx, ecx
    ret
1:  add     edx, [rip+ne_hr2]
    imul    esi, [rip+ne_row]
    add     edx, esi
    ret

# ne_in_xy(rbx=record, edi=node (0: the output), esi=input k / socket) ->
#   eax, edx = that input socket on screen
ne_in_xy:
    lea     r8, [rip+ne_lx]
    mov     eax, [r8+rdi*4]
    lea     r8, [rip+ne_ly]
    mov     edx, [r8+rdi*4]
    test    edi, edi
    jz      0f
    test    byte ptr [rbx+NE_NFLAGS+rdi-1], 1   # (collapsed: the header's side)
    jz      0f
    mov     ecx, [rip+ne_hdr]
    shr     ecx, 1
    add     edx, ecx
    ret
0:  add     edx, [rip+ne_hr2]
    test    edi, edi
    jz      1f
    push    rax
    push    rdx
    push    rsi
    push    rbx
    lea     eax, [rdi-1]
    imul    eax, eax, NODE_SZ
    mov     ebx, [rbx+GR_NODES+rax+ND_TYPE]
    mov     edi, ebx
    call    ne_nouts
    push    rax
    mov     edi, ebx
    call    ne_counts
    pop     rcx
    add     ecx, edx                    # after the outputs and the values
    pop     rbx
    pop     rsi
    add     esi, ecx
    pop     rdx
    pop     rax
1:  imul    esi, [rip+ne_row]
    add     edx, esi
    ret

# ne_bez(edi, esi = from, edx, ecx = to, r9 = out: 17 points, i32 x y) -
#   the wire's cubic Bezier (handles max(the grid step, |dx| / 2)), as drawn
ne_bez:
    push    rbx
    sub     rsp, 32
    mov     [rsp], edi
    mov     [rsp+4], esi
    mov     [rsp+8], edx
    mov     [rsp+12], ecx
    mov     eax, edx                    # handle length
    sub     eax, edi
    cdq
    xor     eax, edx
    sub     eax, edx
    shr     eax, 1
    cmp     eax, [rip+ne_grid]
    jge     1f
    mov     eax, [rip+ne_grid]
1:  mov     [rsp+20], eax
    mov     eax, [rsp]                  # the first point
    mov     [r9], eax
    mov     eax, [rsp+4]
    mov     [r9+4], eax
    mov     ebx, 1
2:  cmp     ebx, 16
    ja      9f
    cvtsi2ss xmm0, ebx                  # t, s = 1 - t
    mulss   xmm0, [rip+nf_seg]
    movss   xmm1, [rip+nf_one]
    subss   xmm1, xmm0
    # b0 = s^3, b1 = 3 s^2 t, b2 = 3 s t^2, b3 = t^3
    movss   xmm2, xmm1
    mulss   xmm2, xmm1
    mulss   xmm2, xmm1                  # b0
    movss   xmm3, xmm1
    mulss   xmm3, xmm1
    mulss   xmm3, xmm0
    mulss   xmm3, [rip+nf_three]        # b1
    movss   xmm4, xmm1
    mulss   xmm4, xmm0
    mulss   xmm4, xmm0
    mulss   xmm4, [rip+nf_three]        # b2
    movss   xmm5, xmm0
    mulss   xmm5, xmm0
    mulss   xmm5, xmm0                  # b3
    cvtsi2ss xmm6, dword ptr [rsp]      # x: p0, p0 + h, p3 - h, p3
    cvtsi2ss xmm7, dword ptr [rsp+20]
    movss   xmm8, xmm6
    mulss   xmm8, xmm2
    movss   xmm9, xmm6
    addss   xmm9, xmm7
    mulss   xmm9, xmm3
    addss   xmm8, xmm9
    cvtsi2ss xmm6, dword ptr [rsp+8]
    movss   xmm9, xmm6
    subss   xmm9, xmm7
    mulss   xmm9, xmm4
    addss   xmm8, xmm9
    mulss   xmm6, xmm5
    addss   xmm8, xmm6
    cvtsi2ss xmm6, dword ptr [rsp+4]    # y: p0, p0, p3, p3
    movss   xmm9, xmm2
    addss   xmm9, xmm3
    mulss   xmm9, xmm6
    cvtsi2ss xmm6, dword ptr [rsp+12]
    movss   xmm10, xmm4
    addss   xmm10, xmm5
    mulss   xmm10, xmm6
    addss   xmm9, xmm10
    cvtss2si eax, xmm8
    mov     [r9+rbx*8], eax
    cvtss2si eax, xmm9
    mov     [r9+rbx*8+4], eax
    inc     ebx
    jmp     2b
9:  add     rsp, 32
    pop     rbx
    ret

# ne_wire(edi, esi = from, edx, ecx = to, r8d = colour) - a curve
ne_wire:
    push    rbx
    push    r12
    sub     rsp, 152
    mov     r12d, r8d
    lea     r9, [rsp]
    call    ne_bez
    mov     ebx, 1
1:  mov     edi, [rsp+rbx*8-8]
    mov     esi, [rsp+rbx*8-4]
    mov     edx, [rsp+rbx*8]
    mov     ecx, [rsp+rbx*8+4]
    mov     r8d, r12d
    call    draw_line
    inc     ebx
    cmp     ebx, 16
    jbe     1b
    add     rsp, 152
    pop     r12
    pop     rbx
    ret

# ne_draw_box - the selection box being dragged (an outline)
ne_draw_box:
    push    rbx
    push    r12
    push    r13
    push    r14
    sub     rsp, 8
    mov     ebx, [rip+ne_x0]
    mov     r12d, [rip+ptr_x]
    cmp     ebx, r12d
    jle     1f
    xchg    ebx, r12d
1:  mov     r13d, [rip+ne_y0]
    mov     r14d, [rip+ptr_y]
    cmp     r13d, r14d
    jle     2f
    xchg    r13d, r14d
2:  sub     r12d, ebx                   # w, h
    inc     r12d
    sub     r14d, r13d
    inc     r14d
    mov     edi, ebx                    # top, bottom, left, right
    mov     esi, r13d
    mov     edx, r12d
    mov     ecx, 1
    mov     r8d, COL_ACCENT
    call    fill_rect
    mov     edi, ebx
    lea     esi, [r13+r14-1]
    mov     edx, r12d
    mov     ecx, 1
    mov     r8d, COL_ACCENT
    call    fill_rect
    mov     edi, ebx
    mov     esi, r13d
    mov     edx, 1
    mov     ecx, r14d
    mov     r8d, COL_ACCENT
    call    fill_rect
    lea     edi, [rbx+r12-1]
    mov     esi, r13d
    mov     edx, 1
    mov     ecx, r14d
    mov     r8d, COL_ACCENT
    call    fill_rect
    add     rsp, 8
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# ne_wire_col(edi=from node, esi=its output, edx=to node; rbx = record) ->
#   eax = the wire's colour: the output's kind, the accent at a selected node
ne_wire_col:
    mov     rax, [rip+ne_selm]
    bt      rax, rdi
    jc      8f
    bt      rax, rdx
    jc      8f
    push    rsi
    lea     eax, [rdi-1]
    imul    eax, eax, NODE_SZ
    mov     edi, [rbx+GR_NODES+rax+ND_TYPE]
    call    ne_meta_of
    pop     rsi
    test    rax, rax
    jz      7f
    mov     rax, [rax+48]               # (output kinds)
    movzx   eax, byte ptr [rax+rsi]
    cmp     eax, 4
    ja      7f
    lea     rcx, [rip+ne_kind_col]
    mov     eax, [rcx+rax*4]
    ret
7:  mov     eax, COL_NE_WIRE
    ret
8:  mov     eax, COL_ACCENT
    ret

# ne_sock(edi=x, esi=y, edx=colour) - a socket
ne_sock:
    sub     rsp, 8
    mov     r8d, edx
    sub     edi, [rip+ne_sr]
    sub     esi, [rip+ne_sr]
    mov     edx, [rip+ne_sr]
    lea     edx, [rdx*2+1]
    mov     ecx, edx
    call    fill_rect
    add     rsp, 8
    ret

# ne_fmt_num(xmm0) - a value into fmt_buf: 2 decimals (1 from 10, 0 from 100)
ne_fmt_num:
    push    rbx
    sub     rsp, 16
    movss   [rsp], xmm0
    call    fmt_reset
    movss   xmm0, [rsp]
    andps   xmm0, [rip+ne_absm]
    comiss  xmm0, [rip+nf_hundred]
    jb      1f
    cvtss2si edi, dword ptr [rsp]
    call    fmt_int
    jmp     9f
1:  movss   xmm0, [rsp]                 # x 100, rounded
    mulss   xmm0, [rip+nf_hundred]
    cvtss2si ebx, xmm0
    test    ebx, ebx
    jns     2f
    mov     edi, '-'
    call    fmt_char
    neg     ebx
2:  mov     eax, ebx
    xor     edx, edx
    mov     ecx, 100
    div     ecx
    mov     ebx, edx
    mov     edi, eax
    call    fmt_int
    mov     edi, '.'
    call    fmt_char
    mov     eax, ebx
    xor     edx, edx
    mov     ecx, 10
    div     ecx
    push    rdx
    lea     edi, [rax+'0']
    call    fmt_char
    pop     rdx
    lea     edi, [rdx+'0']
    call    fmt_char
9:  add     rsp, 16
    pop     rbx
    ret

.section .rodata
.align 16
ne_absm:        .long 0x7fffffff, 0, 0, 0
.text

# ne_right_text(rdi=text, esi=right x, edx=y, ecx=colour) - right aligned
ne_right_text:
    push    rbx
    push    r12
    push    r13
    push    r14
    sub     rsp, 8
    mov     rbx, rdi
    mov     r12d, esi
    mov     r13d, edx
    mov     r14d, ecx
    call    text_width
    mov     edi, r12d
    sub     edi, eax
    mov     esi, r13d
    mov     rdx, rbx
    mov     ecx, r14d
    call    draw_text
    add     rsp, 8
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# ne_value_text(rbx=record, edi=node, esi=value p) -> rax = its text
#   (fmt_buf or a name)
ne_value_text:
    push    r12
    push    r13
    push    r14
    lea     eax, [rdi-1]
    imul    eax, eax, NODE_SZ
    lea     r12, [rbx+GR_NODES+rax]
    mov     r13d, esi
    mov     edi, [r12+ND_TYPE]
    call    ne_meta_of
    mov     r14, rax
    mov     rcx, [r14+24]
    movzx   ecx, byte ptr [rcx+r13]
    movss   xmm0, [r12+ND_P+r13*4]
    cmp     ecx, 1
    je      1f
    cmp     ecx, 6
    je      6f
    cmp     ecx, 2
    je      2f
    cmp     ecx, 4
    je      4f
    cmp     ecx, 5
    je      5f
    cmp     ecx, 3
    jne     3f
    cvtss2si edi, xmm0                  # a whole number
    push    rdi
    call    fmt_reset
    pop     rdi
    call    fmt_int
    lea     rax, [rip+fmt_buf]
    jmp     9f
3:  call    ne_fmt_num
    lea     rax, [rip+fmt_buf]
    jmp     9f
6:  mov     rcx, [r14+32]               # the second choice list
    mov     rax, [rcx]
    lea     rcx, [rcx+rax*8+8]
    jmp     10f
1:  mov     rcx, [r14+32]               # a choice
10: cvtss2si eax, xmm0
    test    eax, eax
    jns     11f
    xor     eax, eax
11: cmp     rax, [rcx]
    jb      12f
    mov     rax, [rcx]
    dec     eax
12: mov     rax, [rcx+rax*8+8]
    jmp     9f
2:  cvtss2si edi, xmm0              # an image (index + 1)
    dec     edi
    js      21f
    cmp     edi, [rip+img_count]
    jae     21f
    call    image_rec
    lea     rax, [rax+IR_NAME]
    jmp     9f
21: lea     rax, [rip+s_ne_noimg]
    jmp     9f
4:  cvtss2si edi, xmm0                  # a tree (number)
    dec     edi
    js      21b
    call    nt_get
    test    rax, rax
    jz      21b
    jmp     9f
5:  cvtss2si esi, xmm0                  # a name (logic): its text
    mov     rdi, rbx
    call    lg_name_of
    test    rax, rax
    jnz     9f
    lea     rax, [rip+s_none_w]
9:  pop     r14
    pop     r13
    pop     r12
    ret

# ed_nodes_draw - the area body (ed_x, ed_y, ed_w, ed_h; clip set)
ed_nodes_draw:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    push    rbp
    sub     rsp, 72
    mov     eax, [rip+ed_x]
    mov     [rip+ne_bx], eax
    mov     eax, [rip+ed_y]
    add     eax, NE_BAR
    mov     [rip+ne_by], eax
    mov     eax, [rip+ed_w]
    mov     [rip+ne_bw], eax
    mov     eax, [rip+ed_h]
    sub     eax, NE_BAR
    mov     [rip+ne_bh], eax
    mov     edi, [rip+ed_x]             # background, a dot grid
    mov     esi, [rip+ed_y]
    mov     edx, [rip+ed_w]
    mov     ecx, [rip+ed_h]
    mov     r8d, COL_NE_BG
    call    fill_rect
    call    zoom_apply                  # (sizes for this zoom)
    mov     eax, [rip+ne_panx]
    cdq
    mov     ecx, [rip+ne_grid]
    idiv    ecx
    add     edx, ecx
    mov     r12d, edx                   # first column offset
    mov     eax, [rip+ne_pany]
    cdq
    idiv    ecx
    add     edx, ecx
    mov     r13d, edx
    mov     ebx, r12d
1:  cmp     ebx, [rip+ne_bw]
    jge     3f
    mov     r14d, r13d
2:  cmp     r14d, [rip+ne_bh]
    jge     21f
    mov     edi, [rip+ne_bx]
    add     edi, ebx
    mov     esi, [rip+ne_by]
    add     esi, r14d
    mov     edx, 2
    mov     ecx, 2
    mov     r8d, COL_NE_GRID
    call    fill_rect
    add     r14d, [rip+ne_grid]
    jmp     2b
21: add     ebx, [rip+ne_grid]
    jmp     1b
3:  call    ne_rec
    test    rax, rax
    jz      .Lnd_none
    mov     rbx, rax
    mov     rdi, rbx
    call    ne_layout
    mov     edi, FONT_NODE              # the canvas: text at the zoom's size
    call    text_use
    call    ne_draw_frames              # comment frames under everything
    # wires: node inputs, then the material sockets
    mov     r12d, 1
4:  cmp     r12d, [rip+ne_n]
    ja      45f
    lea     eax, [r12-1]
    imul    eax, eax, NODE_SZ
    lea     r13, [rbx+GR_NODES+rax]
    mov     edi, [r13+ND_TYPE]
    call    ne_counts
    mov     [rsp+32], eax               # inputs
    xor     r14d, r14d
41: cmp     r14d, [rsp+32]
    jae     44f
    imul    eax, r14d, 16
    mov     eax, [r13+ND_IN+rax]
    call    ne_link_node
    mov     r15d, eax
    test    r15d, r15d
    jz      43f
    cmp     r15d, [rip+ne_n]
    ja      43f
    mov     [rsp+40], ecx
    mov     edi, r15d
    mov     esi, ecx
    call    ne_out_xy
    mov     [rsp], eax
    mov     [rsp+4], edx
    mov     edi, r12d
    mov     esi, r14d
    call    ne_in_xy
    mov     [rsp+8], eax
    mov     [rsp+12], edx
    mov     edi, r15d
    mov     esi, [rsp+40]
    mov     edx, r12d
    call    ne_wire_col
    mov     r8d, eax
    mov     edi, [rsp]
    mov     esi, [rsp+4]
    mov     edx, [rsp+8]
    mov     ecx, [rsp+12]
    call    ne_wire
43: inc     r14d
    jmp     41b
44: inc     r12d
    jmp     4b
45: xor     r14d, r14d
    cmp     dword ptr [rip+ne_kind], 0  # (trees: no material sockets)
    jne     5f
46: cmp     r14d, NPINS
    jae     5f
    mov     r15d, [rbx+GR_PINS+r14*4]
    movzx   eax, r15w
    test    eax, eax
    jz      47f
    cmp     eax, [rip+ne_n]
    ja      47f
    mov     edi, eax
    mov     esi, r15d
    shr     esi, 16
    call    ne_out_xy
    mov     [rsp], eax
    mov     [rsp+4], edx
    xor     edi, edi
    mov     esi, r14d
    call    ne_in_xy
    mov     [rsp+8], eax
    mov     [rsp+12], edx
    movzx   edi, r15w
    mov     esi, r15d
    shr     esi, 16
    xor     edx, edx
    call    ne_wire_col
    mov     r8d, eax
    mov     edi, [rsp]
    mov     esi, [rsp+4]
    mov     edx, [rsp+8]
    mov     ecx, [rsp+12]
    call    ne_wire
47: inc     r14d
    jmp     46b
    # the nodes
5:  mov     r12d, 1
51: cmp     r12d, [rip+ne_n]
    ja      59f
    mov     edi, r12d
    call    ne_draw_node
    inc     r12d
    jmp     51b
59: cmp     dword ptr [rip+ne_kind], 0
    jne     591f
    call    ne_draw_output
591:
    # a wire being dragged
    mov     eax, [rip+ne_drag]
    cmp     eax, 2
    jne     61f
    mov     edi, [rip+ne_dn]
    mov     esi, [rip+ne_dk]
    call    ne_out_xy
    mov     edi, eax
    mov     esi, edx
    mov     edx, [rip+ptr_x]
    mov     ecx, [rip+ptr_y]
    mov     r8d, COL_ACCENT
    call    ne_wire
    jmp     69f
61: cmp     eax, 3
    je      62f
    cmp     eax, 4
    jne     69f
    xor     edi, edi                    # (from a material socket)
    jmp     63f
62: mov     edi, [rip+ne_dn]
63: mov     esi, [rip+ne_dk]
    call    ne_in_xy
    mov     ecx, edx
    mov     edx, eax
    mov     edi, [rip+ptr_x]
    mov     esi, [rip+ptr_y]
    mov     r8d, COL_ACCENT
    call    ne_wire
69: cmp     dword ptr [rip+ne_drag], 8  # the selection box
    jne     68f
    call    ne_draw_box
68: mov     edi, FONT_UI
    call    text_use
    mov     edi, [rip+ed_x]             # the title line over the canvas
    mov     esi, [rip+ed_y]
    mov     edx, [rip+ed_w]
    mov     ecx, NE_BAR
    mov     r8d, COL_NE_BG
    call    fill_rect
    # header line: the material or tree, the keys
    mov     edi, [rip+ed_x]
    add     edi, 8
    mov     esi, [rip+ed_y]
    add     esi, 3
    lea     rdx, [rip+s_ne_head]
    cmp     dword ptr [rip+ne_kind], 0
    je      31f
    lea     rdx, [rip+s_ne_lhead]
    cmp     dword ptr [rip+ne_kind], 2
    je      31f
    lea     rdx, [rip+s_ne_ghead]
    cmp     dword ptr [rip+ne_pathn], 0
    je      31f
    lea     rdx, [rip+s_ne_grhead]
31: mov     ecx, COL_TEXT_DIM
    call    draw_text
    mov     edi, eax
    mov     esi, [rip+ed_y]
    add     esi, 3
    mov     rdx, rbx                    # (the name is the record's start)
    mov     ecx, COL_TEXT
    call    draw_text
    mov     edi, eax
    mov     esi, [rip+ed_y]
    add     esi, 3
    lea     rdx, [rip+s_ne_keys]
    cmp     dword ptr [rip+ne_kind], 0
    je      32f
    lea     rdx, [rip+s_ne_lkeys]
    cmp     dword ptr [rip+ne_kind], 2
    je      32f
    lea     rdx, [rip+s_ne_gkeys]
    cmp     dword ptr [rip+ne_pathn], 0
    je      32f
    lea     rdx, [rip+s_ne_grkeys]
32: mov     ecx, COL_TEXT_DIM
    call    draw_text
    cmp     dword ptr [rip+ne_kind], 0  # (a material with a tree too: Tab)
    jne     33f
    cmp     dword ptr [rip+ne_pref], 0
    je      33f
    mov     edi, eax
    mov     esi, [rip+ed_y]
    add     esi, 3
    lea     rdx, [rip+s_ne_tabgeo]
    mov     ecx, COL_TEXT_DIM
    call    draw_text
33:
    cmp     dword ptr [rip+ne_menu], 0
    je      .Lnd_out
    call    ne_draw_menu
    jmp     .Lnd_out
.Lnd_none:
    mov     edi, [rip+ed_x]
    add     edi, 8
    mov     esi, [rip+ed_y]
    add     esi, 3
    lea     rdx, [rip+s_ne_none]
    mov     ecx, COL_TEXT_DIM
    call    draw_text
    mov     dword ptr [rip+ne_n], 0
.Lnd_out:
    add     rsp, 72
    pop     rbp
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# ne_box(edi=node (0: output), esi=header colour, rdx=title) - the frame,
#   header and title
ne_box:
    push    rbx
    push    r12
    push    r13
    push    r14
    sub     rsp, 8
    mov     ebx, edi
    mov     r12d, esi
    mov     r13, rdx
    lea     r8, [rip+ne_lx]
    mov     edi, [r8+rbx*4]
    sub     edi, 1
    lea     r8, [rip+ne_ly]
    mov     esi, [r8+rbx*4]
    sub     esi, 1
    mov     edx, [rip+ne_nw]
    add     edx, 2
    lea     r8, [rip+ne_lh]
    mov     ecx, [r8+rbx*4]
    add     ecx, 2
    mov     r8d, COL_NE_EDGE
    test    ebx, ebx
    jz      1f
    mov     rax, [rip+ne_selm]
    bt      rax, rbx
    jnc     1f
    mov     r8d, COL_ACCENT
1:  call    fill_rect
    lea     r8, [rip+ne_lx]
    mov     edi, [r8+rbx*4]
    lea     r8, [rip+ne_ly]
    mov     esi, [r8+rbx*4]
    mov     edx, [rip+ne_nw]
    lea     r8, [rip+ne_lh]
    mov     ecx, [r8+rbx*4]
    mov     r8d, COL_NE_BODY
    call    fill_rect
    lea     r8, [rip+ne_lx]
    mov     edi, [r8+rbx*4]
    lea     r8, [rip+ne_ly]
    mov     esi, [r8+rbx*4]
    mov     edx, [rip+ne_nw]
    mov     ecx, [rip+ne_hdr]
    mov     r8d, r12d
    call    fill_rect
    lea     r8, [rip+ne_lx]
    mov     edi, [r8+rbx*4]
    add     edi, [rip+ne_ins]
    lea     r8, [rip+ne_ly]
    mov     esi, [r8+rbx*4]
    add     esi, [rip+ne_hy]
    mov     rdx, r13
    mov     ecx, COL_TEXT
    call    draw_text
    add     rsp, 8
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# ne_draw_node(edi=node 1..n; rbx = record)
ne_draw_node:
    push    r12
    push    r13
    push    r14
    push    r15
    push    rbp
    sub     rsp, 32
    mov     r12d, edi
    lea     eax, [r12-1]
    imul    eax, eax, NODE_SZ
    lea     r13, [rbx+GR_NODES+rax]
    mov     edi, [r13+ND_TYPE]
    call    ne_meta_of
    test    rax, rax
    jz      .Ldn_out
    mov     r14, rax
    mov     edi, [r13+ND_TYPE]
    call    ne_nouts
    mov     [rsp+20], eax               # outputs
    mov     edi, [r13+ND_TYPE]
    call    ne_counts
    mov     [rsp], eax                  # inputs
    mov     [rsp+4], edx                # values
    mov     ecx, [r13+ND_TYPE]          # header colour by kind
    cmp     dword ptr [rip+ne_kind], 0
    je      11f
    cmp     dword ptr [rip+ne_kind], 2  # (logic: events, actions, data)
    jne     10f
    mov     esi, COL_NE_OUT
    cmp     ecx, 7
    jbe     1f
    mov     esi, COL_NE_GEO
    cmp     ecx, 18
    jbe     1f
    mov     esi, COL_NE_CONV
    jmp     1f
10: mov     esi, COL_NE_GRP             # (trees: groups, group in / out,
    cmp     ecx, 26                     #  geometry, fields)
    je      1f
    mov     esi, COL_NE_OUT
    cmp     ecx, 2
    jbe     1f
    mov     esi, COL_NE_GEO
    cmp     ecx, 15
    jbe     1f
    mov     esi, COL_NE_CONV
    jmp     1f
11: lea     rax, [rip+mn_color]         # (materials: by category)
    mov     esi, [rax+rcx*4]
1:  mov     [rsp+24], esi
    mov     edi, ecx
    call    ne_title
    mov     rdx, rax
    mov     edi, r12d
    mov     esi, [rsp+24]
    call    ne_box
    test    byte ptr [rbx+NE_NFLAGS+r12-1], 1   # collapsed: a socket a side
    jz      0f
    cmp     dword ptr [rsp+20], 0
    je      77f
    mov     edi, r12d
    xor     esi, esi
    call    ne_out_xy
    mov     edi, eax
    mov     esi, edx
    mov     edx, COL_NE_WIRE
    call    ne_sock
77: cmp     dword ptr [rsp], 0
    je      .Ldn_out
    mov     edi, r12d
    xor     esi, esi
    call    ne_in_xy
    mov     edi, eax
    mov     esi, edx
    mov     edx, COL_NE_WIRE
    call    ne_sock
    jmp     .Ldn_out
0:  lea     r8, [rip+ne_lx]
    mov     eax, [r8+r12*4]
    mov     [rsp+8], eax                # x
    lea     r8, [rip+ne_ly]
    mov     eax, [r8+r12*4]
    add     eax, [rip+ne_hdr]
    mov     [rsp+12], eax               # row 0's top
    # the outputs
    xor     r15d, r15d
5:  cmp     r15d, [rsp+20]
    jae     6f
    cmp     dword ptr [rip+ne_txt], 0
    je      51f
    mov     edx, r15d
    imul    edx, [rip+ne_row]
    add     edx, [rsp+12]
    add     edx, [rip+ne_ty]
    mov     esi, [rsp+8]
    add     esi, [rip+ne_nw]
    sub     esi, [rip+ne_pad]
    mov     rax, [r14+40]
    mov     rdi, [rax+r15*8]
    mov     ecx, COL_TEXT
    call    ne_right_text
51:
    mov     edi, r12d
    mov     esi, r15d
    call    ne_out_xy
    mov     edi, eax
    mov     esi, edx
    mov     rax, [r14+48]
    movzx   ecx, byte ptr [rax+r15]
    lea     rax, [rip+ne_kind_col]
    mov     edx, [rax+rcx*4]
    call    ne_sock
    inc     r15d
    jmp     5b
    # the values
6:  xor     r15d, r15d
2:  cmp     r15d, [rsp+4]
    jae     3f
    mov     eax, [rsp+20]
    add     eax, r15d
    imul    eax, [rip+ne_row]
    add     eax, [rsp+12]
    mov     [rsp+16], eax
    mov     edi, [rsp+8]                # a field behind it
    add     edi, [rip+ne_ins]
    mov     esi, eax
    add     esi, 1
    mov     edx, [rip+ne_nw]
    sub     edx, [rip+ne_ins]
    sub     edx, [rip+ne_ins]
    mov     ecx, [rip+ne_row]
    sub     ecx, 2
    mov     r8d, COL_FIELD
    call    fill_rect
    cmp     dword ptr [rip+ne_txt], 0
    je      29f
    mov     rax, [r14+16]
    mov     rdx, [rax+r15*8]
    mov     edi, [rsp+8]
    add     edi, [rip+ne_pad]
    mov     esi, [rsp+16]
    add     esi, [rip+ne_ty]
    mov     ecx, COL_TEXT_DIM
    call    draw_text
    mov     edi, r12d
    mov     esi, r15d
    call    ne_value_text
    mov     rdi, rax
    mov     esi, [rsp+8]
    add     esi, [rip+ne_nw]
    sub     esi, [rip+ne_pad]
    mov     edx, [rsp+16]
    add     edx, [rip+ne_ty]
    mov     ecx, COL_TEXT
    call    ne_right_text
29: inc     r15d
    jmp     2b
    # the inputs
3:  xor     r15d, r15d
4:  cmp     r15d, [rsp]
    jae     .Ldn_out
    mov     eax, [rsp+4]
    add     eax, [rsp+20]
    add     eax, r15d
    imul    eax, [rip+ne_row]
    add     eax, [rsp+12]
    mov     [rsp+16], eax
    mov     rax, [r14+8]                # socket colour by kind
    movzx   ebp, byte ptr [rax+r15]
    lea     rax, [rip+ne_kind_col]
    mov     edx, [rax+rbp*4]
    mov     edi, [rsp+8]
    mov     esi, [rsp+16]
    add     esi, [rip+ne_r2]
    call    ne_sock
    cmp     dword ptr [rip+ne_txt], 0
    je      49f
    mov     rax, [r14]
    mov     rdx, [rax+r15*8]
    mov     edi, [rsp+8]
    add     edi, [rip+ne_pad]
    mov     esi, [rsp+16]
    add     esi, [rip+ne_ty]
    mov     ecx, COL_TEXT
    call    draw_text
    imul    eax, r15d, 16               # unlinked: its constant
    cmp     dword ptr [r13+ND_IN+rax], 0
    jne     49f
    cmp     ebp, 1
    je      45f
    cmp     ebp, 2
    je      46f
    cmp     ebp, 3
    jne     49f
    lea     rsi, [r13+ND_IN+rax+4]      # a colour: a swatch
    call    ne_rgb
    mov     r8d, eax
    mov     edi, [rsp+8]
    add     edi, [rip+ne_nw]
    sub     edi, [rip+ne_pad]
    sub     edi, [rip+ne_sw]
    mov     esi, [rsp+16]
    mov     ecx, [rip+ne_row]
    shr     ecx, 2
    add     esi, ecx
    mov     edx, [rip+ne_sw]
    mov     ecx, [rip+ne_r2]
    call    fill_rect
    jmp     49f
45: movss   xmm0, [r13+ND_IN+rax+4]     # a value: the number
    call    ne_fmt_num
    lea     rdi, [rip+fmt_buf]
    mov     esi, [rsp+8]
    add     esi, [rip+ne_nw]
    sub     esi, [rip+ne_pad]
    mov     edx, [rsp+16]
    add     edx, [rip+ne_ty]
    mov     ecx, COL_TEXT_DIM
    call    ne_right_text
    jmp     49f
46: cmp     dword ptr [rip+ne_kind], 0  # a vector (trees): x y z
    je      49f
    lea     rdi, [rip+s_ne_implicit]    # (noise unlinked: the position)
    cmp     dword ptr [rip+ne_kind], 1
    jne     47f
    cmp     dword ptr [r13+ND_TYPE], 24
    jne     47f
    test    r15d, r15d
    jz      48f
47: lea     rsi, [r13+ND_IN+rax+4]
    call    ne_fmt_vec
    lea     rdi, [rip+fmt_buf]
48:
    mov     esi, [rsp+8]
    add     esi, [rip+ne_nw]
    sub     esi, [rip+ne_pad]
    mov     edx, [rsp+16]
    add     edx, [rip+ne_ty]
    mov     ecx, COL_TEXT_DIM
    call    ne_right_text
49: inc     r15d
    jmp     4b
.Ldn_out:
    add     rsp, 32
    pop     rbp
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    ret

# ne_fmt_vec(rsi=float[3]) - "x y z" (one decimal each) into fmt_buf
ne_fmt_vec:
    push    rbx
    push    r12
    sub     rsp, 8
    mov     r12, rsi
    call    fmt_reset
    xor     ebx, ebx
1:  movss   xmm0, [r12+rbx*4]
    call    fmt_fix1
    cmp     ebx, 2
    je      2f
    mov     edi, ' '
    call    fmt_char
2:  inc     ebx
    cmp     ebx, 3
    jb      1b
    add     rsp, 8
    pop     r12
    pop     rbx
    ret

# ne_rgb(rsi=float[3] linear) -> eax = 0xRRGGBB (sqrt as gamma)
ne_rgb:
    xor     eax, eax
    xor     ecx, ecx
1:  movss   xmm0, [rsi+rcx*4]
    xorps   xmm1, xmm1
    maxss   xmm0, xmm1
    minss   xmm0, [rip+nf_one]
    sqrtss  xmm0, xmm0
    mulss   xmm0, [rip+nf_255]
    cvtss2si edx, xmm0
    shl     eax, 8
    or      eax, edx
    inc     ecx
    cmp     ecx, 3
    jb      1b
    ret

.section .rodata
.align 4
nf_255:         .float 255.0
.text

# ne_draw_output (rbx = record) - the Material Output node
ne_draw_output:
    push    r12
    push    r13
    push    r14
    sub     rsp, 16
    xor     edi, edi
    mov     esi, COL_NE_OUT
    lea     rdx, [rip+s_ne_out]
    call    ne_box
    xor     r12d, r12d
1:  cmp     r12d, NPINS
    jae     9f
    xor     edi, edi
    mov     esi, r12d
    call    ne_in_xy
    mov     r13d, eax
    mov     r14d, edx
    mov     edi, eax
    mov     esi, edx
    mov     edx, COL_NE_SOCK_C          # colours: base, emission
    cmp     r12d, PIN_BASE
    je      22f
    cmp     r12d, PIN_EMIT
    je      22f
    mov     edx, COL_NE_SOCK_N
    cmp     r12d, PIN_NORMAL
    je      22f
    mov     edx, COL_NE_SOCK_V          # the rest: values
22: call    ne_sock
    cmp     dword ptr [rip+ne_txt], 0
    je      23f
    lea     rax, [rip+ne_out_names]
    mov     rdx, [rax+r12*8]
    mov     edi, r13d
    add     edi, [rip+ne_pad]
    mov     esi, r14d
    sub     esi, [rip+ne_r2]
    add     esi, [rip+ne_ty]
    mov     ecx, COL_TEXT
    call    draw_text
23:
    inc     r12d
    jmp     1b
9:  add     rsp, 16
    pop     r14
    pop     r13
    pop     r12
    ret

# ne_draw_menu - the node types to add, at the menu's place
ne_draw_menu:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    call    ne_menu_size
    mov     r14d, eax                   # rows
    mov     r15d, edx                   # columns
    lea     ecx, [r14+1]
    imul    ecx, ecx, NROW
    add     ecx, 6
    mov     edi, [rip+ne_mx]
    sub     edi, 1
    mov     esi, [rip+ne_my]
    sub     esi, 1
    imul    edx, r15d, MENU_W
    add     edx, 2
    mov     r8d, COL_DROP_BORDER
    call    fill_rect
    lea     ecx, [r14+1]
    imul    ecx, ecx, NROW
    add     ecx, 4
    mov     edi, [rip+ne_mx]
    mov     esi, [rip+ne_my]
    imul    edx, r15d, MENU_W
    mov     r8d, COL_DROP_BG
    call    fill_rect
    mov     edi, [rip+ne_mx]
    add     edi, 8
    mov     esi, [rip+ne_my]
    add     esi, 3
    lea     rdx, [rip+s_ne_add]
    cmp     dword ptr [rip+ne_fn], 0    # "Add" or what is typed
    je      0f
    lea     rdx, [rip+ne_filt]
0:  mov     ecx, COL_TEXT_DIM
    call    draw_text
    call    ne_menu_item                # (the one under the pointer)
    mov     r13d, eax
    call    ne_vcount
    mov     r14d, eax
    mov     ebx, 1
1:  cmp     ebx, r14d
    ja      9f
    lea     eax, [rbx-1]                # column, row
    xor     edx, edx
    mov     ecx, MROWS
    div     ecx
    imul    r15d, eax, MENU_W
    add     r15d, [rip+ne_mx]
    lea     r12d, [rdx+1]
    imul    r12d, r12d, NROW
    add     r12d, [rip+ne_my]
    add     r12d, 2
    mov     edi, ebx                    # (the k-th of those shown)
    call    ne_nth
    mov     [rip+ne_dt], eax
    cmp     eax, r13d
    jne     2f
    mov     edi, r15d
    mov     esi, r12d
    mov     edx, MENU_W
    mov     ecx, NROW
    mov     r8d, COL_HOVER
    call    fill_rect
2:  mov     edi, [rip+ne_dt]
    call    ne_title
    mov     rdx, rax
    lea     edi, [r15+12]
    lea     esi, [r12+2]
    mov     ecx, COL_TEXT
    call    draw_text
    inc     ebx
    jmp     1b
9:  pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# ne_menu_size -> eax = the add menu's rows, edx = its columns
ne_menu_size:
    sub     rsp, 8
    call    ne_vcount
    add     rsp, 8
    lea     ecx, [rax+MROWS-1]
    push    rax
    mov     eax, ecx
    xor     edx, edx
    mov     ecx, MROWS
    div     ecx
    mov     edx, eax
    pop     rax
    cmp     eax, MROWS
    jbe     1f
    mov     eax, MROWS
1:  ret

# ne_menu_item -> eax = the type under the pointer in the menu (0: none)
ne_menu_item:
    push    rbx
    mov     eax, [rip+ptr_x]
    sub     eax, [rip+ne_mx]
    js      8f
    xor     edx, edx
    mov     ecx, MENU_W
    div     ecx
    mov     ebx, eax                    # column
    mov     eax, [rip+ptr_y]
    sub     eax, [rip+ne_my]
    sub     eax, 2
    js      8f
    xor     edx, edx
    mov     ecx, NROW
    div     ecx
    test    eax, eax
    jz      8f
    cmp     eax, MROWS
    ja      8f
    imul    ebx, ebx, MROWS
    add     ebx, eax
    call    ne_vcount                   # (past the last: none)
    cmp     ebx, eax
    ja      8f
    mov     edi, ebx
    call    ne_nth
    pop     rbx
    ret
8:  xor     eax, eax
    pop     rbx
    ret

# ne_hit(edi=x, esi=y; layout of the last drawing) -> eax = what (0 none,
#   1 a node's header, 2 its output, 3 its input socket ecx, 4 a material
#   socket ecx, 5 its value ecx, 6 its input row ecx, 7 its body), edx =
#   the node (0: the output)
ne_hit:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    push    rbp
    sub     rsp, 24
    mov     r12d, edi
    mov     r13d, esi
    call    ne_rec
    test    rax, rax
    jz      .Lnh_none
    mov     rbx, rax
    # sockets first: within 7 px
    mov     r14d, 1
1:  cmp     r14d, [rip+ne_n]
    ja      3f
    lea     eax, [r14-1]                # its outputs
    imul    eax, eax, NODE_SZ
    mov     edi, [rbx+GR_NODES+rax+ND_TYPE]
    call    ne_nouts
    mov     [rsp+4], eax
    xor     r15d, r15d
12: cmp     r15d, [rsp+4]
    jae     11f
    mov     edi, r14d
    mov     esi, r15d
    call    ne_out_xy
    call    ne_near
    test    eax, eax
    jz      13f
    mov     eax, 2
    mov     edx, r14d
    mov     ecx, r15d
    jmp     .Lnh_out
13: inc     r15d
    jmp     12b
11: lea     eax, [r14-1]
    imul    eax, eax, NODE_SZ
    mov     edi, [rbx+GR_NODES+rax+ND_TYPE]
    call    ne_counts
    mov     [rsp], eax
    xor     r15d, r15d
2:  cmp     r15d, [rsp]
    jae     21f
    mov     edi, r14d
    mov     esi, r15d
    call    ne_in_xy
    call    ne_near
    test    eax, eax
    jz      22f
    mov     eax, 3
    mov     edx, r14d
    mov     ecx, r15d
    jmp     .Lnh_out
22: inc     r15d
    jmp     2b
21: inc     r14d
    jmp     1b
3:  xor     r15d, r15d                  # the material sockets
    cmp     dword ptr [rip+ne_kind], 0
    jne     4f
31: cmp     r15d, NPINS
    jae     4f
    xor     edi, edi
    mov     esi, r15d
    call    ne_in_xy
    call    ne_near
    test    eax, eax
    jz      32f
    mov     eax, 4
    xor     edx, edx
    mov     ecx, r15d
    jmp     .Lnh_out
32: inc     r15d
    jmp     31b
    # boxes, the output (drawn last: on top) first
4:  xor     r14d, r14d
    call    ne_in_box
    test    eax, eax
    jnz     41f
    mov     r14d, [rip+ne_n]
42: test    r14d, r14d
    jz      .Lnh_none
    call    ne_in_box
    test    eax, eax
    jnz     41f
    dec     r14d
    jmp     42b
41: lea     r8, [rip+ne_ly]             # which row
    mov     eax, r13d
    sub     eax, [r8+r14*4]
    cmp     eax, [rip+ne_hdr]
    jae     43f
    mov     eax, 1
    mov     edx, r14d
    jmp     .Lnh_out
43: test    r14d, r14d
    jz      48f
    sub     eax, [rip+ne_hdr]
    xor     edx, edx
    mov     ecx, [rip+ne_row]
    div     ecx
    mov     ebp, eax                    # row: outputs, then values, inputs
    lea     eax, [r14-1]
    imul    eax, eax, NODE_SZ
    mov     edi, [rbx+GR_NODES+rax+ND_TYPE]
    mov     [rsp+8], edi
    call    ne_nouts
    sub     ebp, eax
    js      48f
    mov     edi, [rsp+8]
    call    ne_counts
    mov     ecx, ebp
    cmp     ecx, edx
    jae     44f
    mov     eax, 5
    mov     edx, r14d
    jmp     .Lnh_out
44: sub     ecx, edx
    cmp     ecx, eax
    jae     48f
    mov     eax, 6
    mov     edx, r14d
    jmp     .Lnh_out
48: mov     eax, 7
    mov     edx, r14d
    jmp     .Lnh_out
.Lnh_none:
    xor     eax, eax
    xor     edx, edx
.Lnh_out:
    add     rsp, 24
    pop     rbp
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# ne_near(eax, edx = a socket; r12d, r13d = the pointer) -> eax = 1 within 7 px
ne_near:
    sub     eax, r12d
    cmp     eax, -7
    jl      8f
    cmp     eax, 7
    jg      8f
    sub     edx, r13d
    cmp     edx, -7
    jl      8f
    cmp     edx, 7
    jg      8f
    mov     eax, 1
    ret
8:  xor     eax, eax
    ret

# ne_in_box(r14d = node; r12d, r13d = the pointer) -> eax = 1 inside its box
ne_in_box:
    lea     r8, [rip+ne_lx]
    mov     eax, r12d
    sub     eax, [r8+r14*4]
    js      8f
    cmp     eax, [rip+ne_nw]
    jge     8f
    lea     r8, [rip+ne_ly]
    mov     eax, r13d
    sub     eax, [r8+r14*4]
    js      8f
    lea     r8, [rip+ne_lh]
    cmp     eax, [r8+r14*4]
    jge     8f
    mov     eax, 1
    ret
8:  xor     eax, eax
    ret

# ne_run2(rdi=the material operator, rsi=the tree one) - by what is shown
ne_run2:
    cmp     dword ptr [rip+ne_kind], 0
    je      ne_run
    mov     rdi, rsi
# ne_run(rdi=operator id; the argument in ne_argbuf) - as if typed
ne_run:
    push    rbx
    call    find_op_by_name
    test    rax, rax
    jz      9f
    mov     rbx, rax
    lea     rax, [rip+ne_argbuf]
    mov     [rip+op_arg], rax
    mov     rdi, rbx
    call    run_op
    mov     qword ptr [rip+op_arg], 0
9:  pop     rbx
    ret

# ne_arg_start - fmt_buf = the material's name and a space
ne_arg_start:
    push    rbx
    call    fmt_reset
    call    ne_rec                      # (material or tree: the name first)
    mov     rdi, rax
    call    fmt_str
    mov     edi, ' '
    call    fmt_char
    pop     rbx
    ret

# ne_arg_int(edi) - and a number with a space
ne_arg_int:
    sub     rsp, 8
    call    fmt_int
    mov     edi, ' '
    call    fmt_char
    add     rsp, 8
    ret

# ne_arg_done - fmt_buf to ne_argbuf
ne_arg_done:
    lea     rsi, [rip+fmt_buf]
    lea     rdi, [rip+ne_argbuf]
    mov     ecx, 128
    rep     movsb
    mov     byte ptr [rip+ne_argbuf+127], 0
    ret

# nodeed_press(edi=button, esi, edx = pointer) -> eax = 1 when taken
nodeed_press:
    push    rbx
    push    r12
    push    r13
    push    r14
    sub     rsp, 8
    mov     ebx, edi
    mov     r12d, esi
    mov     r13d, edx
    mov     dword ptr [rip+dirty], 1
    cmp     dword ptr [rip+ne_menu], 0  # the add menu: an item, or closed
    je      1f
    mov     dword ptr [rip+ne_menu], 0
    cmp     ebx, BTN_LEFT
    jne     .Lnp_taken
    call    ne_menu_item
    test    eax, eax
    jz      .Lnp_taken
    mov     edi, eax
    call    ne_add_node
    jmp     .Lnp_taken
1:  mov     [rip+ne_x0], r12d
    mov     [rip+ne_y0], r13d
    mov     dword ptr [rip+ne_undone], 0
    mov     dword ptr [rip+ne_pick], 0
    mov     dword ptr [rip+ne_pend], 0
    cmp     ebx, BTN_MIDDLE
    je      .Lnp_pan
    cmp     ebx, BTN_LEFT
    jne     .Lnp_no
    mov     edi, r12d
    mov     esi, r13d
    call    ne_hit
    mov     [rip+ne_dn], edx
    mov     [rip+ne_dk], ecx
    test    eax, eax
    jz      .Lnp_box
    cmp     eax, 2
    jne     2f
    mov     dword ptr [rip+ne_drag], 2  # from an output
    jmp     .Lnp_taken
2:  cmp     eax, 3
    jne     3f
    call    ne_rec                      # an input: its link picked up
    mov     rbx, rax
    mov     eax, [rip+ne_dn]
    dec     eax
    imul    eax, eax, NODE_SZ
    mov     ecx, [rip+ne_dk]
    shl     ecx, 4
    add     eax, ecx
    mov     r14d, [rbx+GR_NODES+rax+ND_IN]
    test    r14d, r14d
    jz      21f
    lea     rsi, [rbx+GR_NODES+rax+ND_IN+4]  # (unlinked: its constant)
    mov     edi, [rip+ne_dn]
    mov     edx, [rip+ne_dk]
    call    ne_unlink
    mov     eax, r14d                   # (from its node's output)
    call    ne_link_node
    mov     [rip+ne_dn], eax
    mov     [rip+ne_dk], ecx
    mov     dword ptr [rip+ne_pick], 1
    mov     dword ptr [rip+ne_drag], 2
    jmp     .Lnp_taken
21: mov     dword ptr [rip+ne_drag], 3
    jmp     .Lnp_taken
3:  cmp     eax, 4
    jne     4f
    call    ne_rec                      # a material socket: picked up too
    mov     ecx, [rip+ne_dk]
    mov     r14d, [rax+GR_PINS+rcx*4]
    test    r14w, r14w
    jz      31f
    call    ne_arg_start
    lea     rdi, [rip+ne_out_sock]
    mov     ecx, [rip+ne_dk]
    mov     rdi, [rdi+rcx*8]
    call    fmt_str
    mov     edi, ' '
    call    fmt_char
    lea     rdi, [rip+s_none_w]
    call    fmt_str
    call    ne_arg_done
    lea     rdi, [rip+s_op_socket]
    call    ne_run
    movzx   eax, r14w                   # (from its node's output)
    mov     [rip+ne_dn], eax
    shr     r14d, 16
    mov     [rip+ne_dk], r14d
    mov     dword ptr [rip+ne_pick], 1
    mov     dword ptr [rip+ne_drag], 2
    jmp     .Lnp_taken
31: mov     dword ptr [rip+ne_drag], 4
    jmp     .Lnp_taken
4:  mov     edx, [rip+ne_dn]            # on a node: selected (Shift: added,
    mov     [rip+ne_sel], edx           #  or taken out again)
    mov     rcx, [rip+ne_selm]
    test    dword ptr [rip+key_mods], MOD_SHIFT
    jz      41f
    btc     rcx, rdx
    jmp     42f
41: bt      rcx, rdx                    # (a selected one: the selection
    jc      42f                         #  stays)
    xor     ecx, ecx
    bts     rcx, rdx
42: mov     [rip+ne_selm], rcx
    cmp     eax, 5
    jne     5f
    call    ne_name_value               # (a name: typed in the console)
    test    eax, eax
    jnz     .Lnp_taken
    mov     dword ptr [rip+ne_drag], 5  # a value
    call    ne_value_ptr
    mov     eax, [rax]
    mov     [rip+ne_a0], eax
    jmp     .Lnp_taken
5:  cmp     eax, 6
    jne     6f
    call    ne_input_editable
    test    eax, eax
    jz      6f
    mov     dword ptr [rip+ne_drag], 6  # an input's number
    call    ne_value_ptr
    mov     eax, [rax]
    mov     [rip+ne_a0], eax
    jmp     .Lnp_taken
6:  mov     dword ptr [rip+ne_drag], 1  # the header or body: moved, with
    mov     rdx, [rip+ne_selm]          #  the rest of the selection
    xor     ecx, ecx
61: cmp     ecx, [rip+ne_n]
    ja      62f
    lea     r8, [rip+ne_gx]
    mov     eax, [r8+rcx*4]
    lea     r8, [rip+ne_sx]
    mov     [r8+rcx*4], eax
    lea     r8, [rip+ne_gy]
    mov     eax, [r8+rcx*4]
    lea     r8, [rip+ne_sy]
    mov     [r8+rcx*4], eax
    inc     ecx
    jmp     61b
62: mov     ecx, [rip+ne_dn]
    lea     r8, [rip+ne_gx]
    mov     eax, [r8+rcx*4]
    mov     [rip+ne_a0], eax
    lea     r8, [rip+ne_gy]
    mov     eax, [r8+rcx*4]
    mov     [rip+ne_b0], eax
    jmp     .Lnp_taken
.Lnp_box:                               # empty space: a frame's title or
    call    ne_frame_hit                #  corner, else a box to select with
    test    eax, eax
    jz      71f
    mov     ecx, [rip+ne_fsel]          # (selected already: a click renames)
    dec     ecx
    xor     r8d, r8d
    cmp     ecx, edx
    jne     70f
    inc     r8d
70: mov     [rip+ne_fwas], r8d
    lea     ecx, [rdx+1]
    mov     [rip+ne_fsel], ecx
    mov     dword ptr [rip+ne_sel], 0
    mov     qword ptr [rip+ne_selm], 0
    mov     ecx, 10                     # 10 move, 11 resize
    cmp     eax, 1
    je      72f
    mov     ecx, 11
72: mov     [rip+ne_drag], ecx
    mov     [rip+ne_dk], edx
    mov     edi, edx
    call    ne_frame_grab
    jmp     .Lnp_taken
71: mov     dword ptr [rip+ne_fsel], 0
    mov     dword ptr [rip+ne_drag], 8
    jmp     .Lnp_taken
.Lnp_pan:
    mov     dword ptr [rip+ne_sel], 0
    mov     qword ptr [rip+ne_selm], 0
    mov     dword ptr [rip+ne_drag], 7
    mov     eax, [rip+ne_panx]
    mov     [rip+ne_a0], eax
    mov     eax, [rip+ne_pany]
    mov     [rip+ne_b0], eax
.Lnp_taken:
    mov     eax, 1
    jmp     9f
.Lnp_no:
    xor     eax, eax
9:  add     rsp, 8
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

.section .rodata
.align 8
ne_out_sock:    .quad sk_base, sk_metal, sk_spec, sk_rough, sk_emit, sk_alpha, sk_normal
                .quad sk_ao, sk_coat, sk_coatr, sk_trans, sk_ior, sk_mask
sk_spec:        .asciz "specular"
sk_alpha:       .asciz "opacity"
sk_ao:          .asciz "ao"
sk_coat:        .asciz "clearcoat"
sk_coatr:       .asciz "coat_roughness"
sk_trans:       .asciz "transmission"
sk_ior:         .asciz "ior"
sk_mask:        .asciz "mask"
sk_base:        .asciz "base"
sk_metal:       .asciz "metallic"
sk_rough:       .asciz "roughness"
sk_emit:        .asciz "emission"
sk_normal:      .asciz "normal"
.text

# ne_name_value -> eax = 1 when the value pressed (ne_dn, ne_dk) is a name:
#   the console gets "logic.name <graph> <node> <slot> " to finish
ne_name_value:
    push    rbx
    xor     eax, eax
    cmp     dword ptr [rip+ne_kind], 2
    jne     9f
    call    ne_rec
    test    rax, rax
    jz      8f
    mov     rbx, rax
    mov     eax, [rip+ne_dn]
    dec     eax
    imul    eax, eax, NODE_SZ
    mov     edi, [rbx+GR_NODES+rax+ND_TYPE]
    call    ne_meta_of
    test    rax, rax
    jz      8f
    mov     rcx, [rax+24]
    mov     edx, [rip+ne_dk]
    cmp     byte ptr [rcx+rdx], 5
    jne     8f
    call    fmt_reset
    lea     rdi, [rip+s_tp_lname]
    call    fmt_str
    mov     rdi, rbx
    call    fmt_str
    mov     edi, ' '
    call    fmt_char
    mov     edi, [rip+ne_dn]
    call    fmt_int
    mov     edi, ' '
    call    fmt_char
    mov     edi, [rip+ne_dk]
    add     edi, 4
    call    fmt_int
    mov     edi, ' '
    call    fmt_char
    lea     rdi, [rip+tfi_console]
    call    tf_select
    lea     rsi, [rip+fmt_buf]
    call    tf_load
    mov     edi, 1
    call    tf_set_focus
    mov     dword ptr [rip+dirty], 1
    mov     eax, 1
    jmp     9f
8:  xor     eax, eax
9:  pop     rbx
    ret

# ne_unlink(edi=node, edx=input k (0..2), rsi=its constant) - through
#   material.node_set (its constant again: unlinked)
ne_unlink:
    push    rbx
    push    r12
    push    r13
    mov     ebx, edi
    mov     r12d, edx
    mov     r13, rsi
    call    ne_arg_start
    mov     edi, ebx
    call    ne_arg_int
    lea     edi, [r12+1]
    call    ne_arg_int
    xor     ebx, ebx
1:  movss   xmm0, [r13+rbx*4]
    call    ne_fmt_num_append
    mov     edi, ' '
    call    fmt_char
    inc     ebx
    cmp     ebx, 3
    jb      1b
    call    ne_arg_done
    lea     rdi, [rip+s_op_set]
    lea     rsi, [rip+s_tp_set]
    call    ne_run2
    pop     r13
    pop     r12
    pop     rbx
    ret

# ne_fmt_num_append(xmm0) - a number appended to fmt_buf (4 decimals)
ne_fmt_num_append:
    push    rbx
    sub     rsp, 16
    mulss   xmm0, [rip+nf_10k]
    cvtss2si ebx, xmm0
    test    ebx, ebx
    jns     1f
    mov     edi, '-'
    call    fmt_char
    neg     ebx
1:  mov     eax, ebx
    xor     edx, edx
    mov     ecx, 10000
    div     ecx
    mov     ebx, edx
    mov     edi, eax
    call    fmt_int
    mov     edi, '.'
    call    fmt_char
    mov     ecx, 1000
2:  mov     eax, ebx
    xor     edx, edx
    div     ecx
    mov     ebx, edx
    push    rcx
    push    rcx
    lea     edi, [rax+'0']
    call    fmt_char
    pop     rcx
    pop     rcx
    mov     eax, ecx
    xor     edx, edx
    mov     ecx, 10
    div     ecx
    mov     ecx, eax
    test    ecx, ecx
    jnz     2b
    add     rsp, 16
    pop     rbx
    ret

.section .rodata
.align 4
nf_10k:         .float 10000.0
.text

# ne_value_ptr -> rax = the float dragged (ne_dn, ne_dk; ne_drag 5 a
#   value, 6 an input's constant)
ne_value_ptr:
    sub     rsp, 8
    call    ne_rec
    mov     ecx, [rip+ne_dn]
    dec     ecx
    imul    ecx, ecx, NODE_SZ
    lea     rax, [rax+GR_NODES+rcx]
    mov     ecx, [rip+ne_dk]
    cmp     dword ptr [rip+ne_drag], 6
    je      1f
    lea     rax, [rax+ND_P+rcx*4]
    add     rsp, 8
    ret
1:  shl     ecx, 4
    lea     rax, [rax+ND_IN+rcx+4]
    add     rsp, 8
    ret

# ne_input_editable (ne_dn, ne_dk) -> eax = 1: an unlinked number input
ne_input_editable:
    push    rbx
    call    ne_rec
    mov     rbx, rax
    mov     ecx, [rip+ne_dn]
    dec     ecx
    imul    ecx, ecx, NODE_SZ
    lea     rbx, [rbx+GR_NODES+rcx]
    mov     eax, [rip+ne_dk]
    shl     eax, 4
    cmp     dword ptr [rbx+ND_IN+rax], 0
    jne     8f
    mov     edi, [rbx+ND_TYPE]
    call    ne_meta_of
    mov     rax, [rax+8]
    mov     ecx, [rip+ne_dk]
    cmp     byte ptr [rax+rcx], 1
    jne     8f
    mov     eax, 1
    pop     rbx
    ret
8:  xor     eax, eax
    pop     rbx
    ret

# nodeed_motion(edi, esi = pointer) -> eax = 1 when taken
nodeed_motion:
    push    rbx
    push    r12
    push    r13
    mov     r12d, edi
    mov     r13d, esi
    cmp     dword ptr [rip+ne_menu], 0  # (the menu's hover)
    je      1f
    mov     dword ptr [rip+dirty], 1
1:  mov     eax, [rip+ne_drag]
    test    eax, eax
    jz      .Lnm_no
    mov     dword ptr [rip+dirty], 1
    cmp     eax, 7
    jne     2f
    mov     eax, r12d                   # pan
    sub     eax, [rip+ne_x0]
    add     eax, [rip+ne_a0]
    mov     [rip+ne_panx], eax
    mov     eax, r13d
    sub     eax, [rip+ne_y0]
    add     eax, [rip+ne_b0]
    mov     [rip+ne_pany], eax
    jmp     .Lnm_yes
2:  cmp     eax, 10
    jb      20f
    call    ne_frame_drag
    jmp     .Lnm_yes
20: cmp     eax, 1
    jne     3f
    call    ne_first_change             # move: the places in the record
    mov     eax, r12d                   # (the pointer's travel / the zoom)
    sub     eax, [rip+ne_x0]
    call    ne_unzoom
    mov     r12d, eax
    mov     eax, r13d
    sub     eax, [rip+ne_y0]
    call    ne_unzoom
    mov     r13d, eax
    xor     ebx, ebx                    # every selected node (the pressed
21: cmp     ebx, [rip+ne_n]             #  one is)
    ja      .Lnm_yes
    mov     rax, [rip+ne_selm]
    bt      rax, rbx
    jc      22f
    cmp     ebx, [rip+ne_dn]
    jne     23f
22: lea     r8, [rip+ne_sx]
    mov     edx, [r8+rbx*4]
    add     edx, r12d
    lea     r8, [rip+ne_sy]
    mov     ecx, [r8+rbx*4]
    add     ecx, r13d
    mov     edi, [rip+ne_mat]
    mov     esi, ebx
    call    ne_place
23: inc     ebx
    jmp     21b
3:  cmp     eax, 5
    je      4f
    cmp     eax, 6
    jne     .Lnm_yes                    # (wires: only drawn)
4:  call    ne_first_change             # a value: sideways
    mov     eax, r12d
    sub     eax, [rip+ne_x0]
    call    ne_new_value
    sub     rsp, 16
    movss   [rsp], xmm0
    movss   [rsp+4], xmm0
    mov     edi, [rip+ne_mat]
    mov     esi, [rip+ne_dn]
    mov     edx, [rip+ne_dk]
    add     edx, 4                      # (values: slots 4..7)
    cmp     dword ptr [rip+ne_drag], 6
    jne     41f
    sub     edx, 3                      # (inputs: 1..3)
41: lea     rcx, [rsp]
    mov     r8d, 1
    cmp     dword ptr [rip+ne_kind], 0
    jne     42f
    call    graph_set
    jmp     43f
42: call    nt_set
43: add     rsp, 16
.Lnm_yes:
    mov     eax, 1
    jmp     9f
.Lnm_no:
    xor     eax, eax
9:  pop     r13
    pop     r12
    pop     rbx
    ret

# ne_unzoom(eax = screen pixels) -> eax = graph units
ne_unzoom:
    imul    eax, eax, 100
    cdq
    idiv    dword ptr [rip+ne_zoom]
    ret

# ne_box_select (r12d, r13d = the release; ne_x0, ne_y0 the press) - every
#   node touching the box: the selection (Shift: added to it, Ctrl: taken
#   out of it); a click in empty space: nothing selected (Shift / Ctrl:
#   kept)
ne_box_select:
    push    rbx
    push    r14
    push    r15
    mov     eax, [rip+ne_x0]            # x0 x1 (r14d r15d), y0 y1 (r8d r9d)
    mov     r14d, eax
    mov     r15d, r12d
    cmp     r14d, r15d
    jle     1f
    xchg    r14d, r15d
1:  mov     r8d, [rip+ne_y0]
    mov     r9d, r13d
    cmp     r8d, r9d
    jle     2f
    xchg    r8d, r9d
2:  mov     rdx, [rip+ne_selm]
    test    dword ptr [rip+key_mods], MOD_SHIFT|MOD_CTRL
    jnz     3f
    xor     edx, edx
3:  xor     ebx, ebx
    cmp     dword ptr [rip+ne_kind], 0  # (trees: no output node)
    je      4f
    inc     ebx
4:  cmp     ebx, [rip+ne_n]
    ja      8f
    lea     r10, [rip+ne_lx]            # box overlaps the node's
    mov     eax, [r10+rbx*4]
    cmp     eax, r15d
    jg      7f
    add     eax, [rip+ne_nw]
    cmp     eax, r14d
    jl      7f
    lea     r10, [rip+ne_ly]
    mov     eax, [r10+rbx*4]
    cmp     eax, r9d
    jg      7f
    lea     r10, [rip+ne_lh]
    add     eax, [r10+rbx*4]
    cmp     eax, r8d
    jl      7f
    bts     rdx, rbx
    test    dword ptr [rip+key_mods], MOD_CTRL
    jz      7f
    btr     rdx, rbx
7:  inc     ebx
    jmp     4b
8:  mov     [rip+ne_selm], rdx
    xor     eax, eax                    # the active one: the lowest selected
    tzcnt   rax, rdx
    jnc     9f
    xor     eax, eax
9:  mov     [rip+ne_sel], eax
    mov     dword ptr [rip+dirty], 1
    pop     r15
    pop     r14
    pop     rbx
    ret

# ne_first_change - the drag's undo step, once
ne_first_change:
    cmp     dword ptr [rip+ne_undone], 0
    jne     9f
    mov     dword ptr [rip+ne_undone], 1
    sub     rsp, 8
    lea     rdi, [rip+s_undo_value]
    cmp     dword ptr [rip+ne_drag], 10
    jb      0f
    lea     rdi, [rip+s_undo_frame]
    jmp     1f
0:  cmp     dword ptr [rip+ne_drag], 1
    jne     1f
    lea     rdi, [rip+s_undo_move]
1:  call    undo_push
    add     rsp, 8
9:  ret

# ne_new_value(eax = pointer dx) -> xmm0: the dragged value from ne_a0 -
#   numbers 0.01 a pixel, choices / images / whole numbers a step per 12 px
ne_new_value:
    push    rbx
    push    r12
    push    r13
    mov     ebx, eax
    movd    xmm0, dword ptr [rip+ne_a0]
    cmp     dword ptr [rip+ne_drag], 6
    je      .Lnv_float
    call    ne_rec                      # the value's kind
    mov     ecx, [rip+ne_dn]
    dec     ecx
    imul    ecx, ecx, NODE_SZ
    mov     edi, [rax+GR_NODES+rcx+ND_TYPE]
    call    ne_meta_of
    mov     r12, rax
    mov     rcx, [r12+24]
    mov     edx, [rip+ne_dk]
    movzx   r13d, byte ptr [rcx+rdx]
    movd    xmm0, dword ptr [rip+ne_a0]
    test    r13d, r13d
    jz      .Lnv_float
    mov     eax, ebx                    # steps
    cdq
    mov     ecx, 12
    idiv    ecx
    cvtss2si ecx, xmm0
    add     eax, ecx
    cmp     r13d, 6
    jne     11f
    mov     rcx, [r12+32]               # the second choice list
    mov     rdx, [rcx]
    mov     rcx, [rcx+rdx*8+8]
    dec     ecx
    jmp     4f
11: cmp     r13d, 1
    jne     2f
    mov     rcx, [r12+32]               # a choice: within its list
    mov     rcx, [rcx]
    dec     ecx
    jmp     4f
2:  cmp     r13d, 2
    jne     21f
    mov     ecx, [rip+img_count]        # an image: 1..count (0: none)
    jmp     4f
21: cmp     r13d, 4
    jne     3f
    push    rax                         # a tree: 1..count (0: none)
    call    nt_count
    mov     ecx, eax
    pop     rax
    jmp     4f
3:  mov     ecx, 16                     # whole: 1..16
    cmp     eax, 1
    jge     4f
    mov     eax, 1
4:  test    eax, eax
    jns     41f
    xor     eax, eax
41: cmp     eax, ecx
    jle     42f
    mov     eax, ecx
42: cvtsi2ss xmm0, eax
    jmp     9f
.Lnv_float:
    cvtsi2ss xmm1, ebx
    mulss   xmm1, [rip+nf_step]
    addss   xmm0, xmm1
    mulss   xmm0, [rip+nf_hundred]      # (to 0.01)
    roundss xmm0, xmm0, 0
    divss   xmm0, [rip+nf_hundred]
9:  pop     r13
    pop     r12
    pop     rbx
    ret

# nodeed_release(edi, esi = pointer) - a wire dropped, a drag ended
nodeed_release:
    push    rbx
    push    r12
    push    r13
    push    r14
    sub     rsp, 8
    mov     eax, [rip+ne_drag]
    test    eax, eax
    jz      9f
    mov     dword ptr [rip+ne_drag], 0
    mov     dword ptr [rip+dirty], 1
    mov     r12d, [rip+ptr_x]
    mov     r13d, [rip+ptr_y]
    cmp     eax, 2
    je      .Lnr_from_out
    cmp     eax, 3
    je      .Lnr_from_in
    cmp     eax, 4
    je      .Lnr_from_sock
    cmp     eax, 8
    je      .Lnr_box
    cmp     eax, 10                     # a frame's title clicked again: rename
    jne     9f
    cmp     dword ptr [rip+ne_undone], 0
    jne     9f
    cmp     dword ptr [rip+ne_fwas], 0
    je      9f
    call    ne_frame_rename
    jmp     9f
.Lnr_box:                               # nodes in the box (a click: none)
    call    ne_box_select
    jmp     9f
.Lnr_from_out:                          # onto an input or a material socket
    mov     edi, r12d
    mov     esi, r13d
    call    ne_hit
    test    eax, eax                    # (empty space: the add menu, the
    jnz     0f                          #  new node fed by it)
    mov     ebx, 1
    jmp     .Lnr_menu
0:  cmp     eax, 3
    je      1f
    cmp     eax, 6                      # (an input's row will do)
    je      1f
    cmp     eax, 4
    jne     9f
    mov     edi, [rip+ne_dn]            # material.socket
    mov     esi, ecx
    mov     edx, [rip+ne_dk]
    call    ne_socket
    jmp     9f
1:  mov     edi, [rip+ne_dn]            # link from to input
    mov     esi, edx
    mov     edx, ecx
    mov     ecx, [rip+ne_dk]
    call    ne_link
    jmp     9f
.Lnr_from_in:                           # onto an output
    mov     edi, r12d
    mov     esi, r13d
    call    ne_hit
    mov     ebx, 2
    test    eax, eax
    jz      .Lnr_menu
    cmp     eax, 2
    jne     9f
    mov     edi, edx
    mov     esi, [rip+ne_dn]
    mov     edx, [rip+ne_dk]
    call    ne_link
    jmp     9f
.Lnr_from_sock:
    mov     edi, r12d
    mov     esi, r13d
    call    ne_hit
    mov     ebx, 3
    test    eax, eax
    jz      .Lnr_menu
    cmp     eax, 2
    jne     9f
    mov     edi, edx
    mov     esi, [rip+ne_dk]
    mov     edx, ecx
    call    ne_socket
    jmp     9f
.Lnr_menu:                              # (ebx: the kind of wire; a link
    cmp     dword ptr [rip+ne_pick], 0  #  picked up and dropped: gone)
    jne     9f
    mov     eax, r12d                   # (barely moved: nothing)
    sub     eax, [rip+ne_x0]
    imul    eax, eax
    mov     ecx, r13d
    sub     ecx, [rip+ne_y0]
    imul    ecx, ecx
    add     eax, ecx
    cmp     eax, 64
    jb      9f
    call    do_ne_add_menu
    mov     [rip+ne_pend], ebx
    mov     eax, [rip+ne_dn]
    mov     [rip+ne_pnode], eax
    mov     eax, [rip+ne_dk]
    mov     [rip+ne_pk], eax
9:  add     rsp, 8
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# ne_link(edi=from, esi=to, edx=input 0..2, ecx=from's output) -
#   material.link / tree.link (a loop: it says so, does nothing)
ne_link:
    push    rbx
    push    r12
    push    r13
    push    r14
    sub     rsp, 8
    mov     ebx, edi
    mov     r12d, esi
    mov     r13d, edx
    mov     r14d, ecx
    cmp     ebx, r12d
    je      9f
    call    ne_arg_start
    mov     edi, ebx
    call    fmt_int
    cmp     dword ptr [rip+ne_kind], 0  # (trees: from:output)
    je      1f
    mov     edi, ':'
    call    fmt_char
    mov     edi, r14d
    call    fmt_int
1:  mov     edi, ' '
    call    fmt_char
    mov     edi, r12d
    call    ne_arg_int
    lea     edi, [r13+1]
    call    ne_arg_int
    cmp     dword ptr [rip+ne_kind], 0  # (materials: an output after it)
    jne     2f
    test    r14d, r14d
    jz      2f
    mov     edi, r14d
    call    ne_arg_int
2:  call    ne_arg_done
    lea     rdi, [rip+s_op_link]
    lea     rsi, [rip+s_tp_link]
    call    ne_run2
9:  add     rsp, 8
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# ne_socket(edi=node, esi=socket 0..4) - material.socket
ne_socket:
    push    rbx
    push    r12
    push    r13
    mov     ebx, edi
    mov     r12d, esi
    mov     r13d, edx
    call    ne_arg_start
    lea     rax, [rip+ne_out_sock]
    mov     rdi, [rax+r12*8]
    call    fmt_str
    mov     edi, ' '
    call    fmt_char
    mov     edi, ebx
    call    ne_arg_int
    test    r13d, r13d                  # (an output after the first)
    jz      1f
    mov     edi, r13d
    call    ne_arg_int
1:  call    ne_arg_done
    lea     rdi, [rip+s_op_socket]
    call    ne_run
    pop     r13
    pop     r12
    pop     rbx
    ret

# ne_add_node(edi=type) - material.node / tree.node, placed where the
#   menu was
ne_add_node:
    push    rbx
    push    r12
    sub     rsp, 8
    mov     ebx, edi
    call    ne_rec
    test    rax, rax
    jz      9f
    mov     ecx, [rax+GR_N]
    cmp     ecx, [rip+ne_maxn]
    jb      1f
    lea     rdi, [rip+s_ne_full]
    call    log_line
    jmp     9f
1:  mov     r12d, ecx
    call    ne_arg_start
    lea     rax, [rip+graph_type_names]
    cmp     dword ptr [rip+ne_kind], 0
    je      11f
    lea     rax, [rip+gn_type_names]
    cmp     dword ptr [rip+ne_kind], 2
    jne     11f
    lea     rax, [rip+lg_type_names]
11: mov     rdi, [rax+rbx*8-8]
    call    fmt_str
    cmp     dword ptr [rip+ne_kind], 0  # an image node: the first image
    jne     2f
    cmp     ebx, 1
    jne     2f
    cmp     dword ptr [rip+img_count], 0
    je      2f
    mov     edi, ' '
    call    fmt_char
    xor     edi, edi
    call    image_rec
    lea     rdi, [rax+IR_NAME]
    call    fmt_str
2:  call    ne_arg_done
    lea     rdi, [rip+s_op_node]
    lea     rsi, [rip+s_tp_node]
    cmp     dword ptr [rip+ne_kind], 2
    jne     21f
    lea     rsi, [rip+s_tp_lnode]
21: call    ne_run2
    call    ne_rec                      # added: placed at the menu
    test    rax, rax
    jz      9f
    cmp     [rax+GR_N], r12d
    jbe     9f
    inc     r12d
    mov     [rip+ne_sel], r12d          # (selected, alone)
    xor     eax, eax
    bts     rax, r12
    mov     [rip+ne_selm], rax
    mov     eax, [rip+ne_ax]            # at the pointer where the menu opened
    sub     eax, [rip+ne_bx]
    sub     eax, [rip+ne_panx]
    call    ne_unzoom
    mov     ebx, eax
    mov     eax, [rip+ne_ay]
    sub     eax, [rip+ne_by]
    sub     eax, [rip+ne_pany]
    call    ne_unzoom
    mov     ecx, eax
    mov     edx, ebx
    mov     edi, [rip+ne_mat]
    mov     esi, r12d
    call    ne_place
    mov     edi, r12d                   # a wire was dropped for it: linked
    call    ne_pend_link
9:  add     rsp, 8
    pop     r12
    pop     rbx
    ret

# ne_pend_link(edi=the node just added) - the wire that opened the menu
#   linked to it (into its first input of the wire's kind, else its first;
#   out of its first output)
ne_pend_link:
    push    rbx
    push    r12
    push    r13
    mov     ebx, edi
    mov     r12d, [rip+ne_pend]
    mov     dword ptr [rip+ne_pend], 0
    test    r12d, r12d
    jz      9f
    call    ne_rec
    test    rax, rax
    jz      9f
    mov     r13, rax
    cmp     r12d, 1
    jne     3f
    lea     eax, [rbx-1]                # from an output: the input to feed
    imul    eax, eax, NODE_SZ
    mov     edi, [r13+GR_NODES+rax+ND_TYPE]
    call    ne_meta_of
    test    rax, rax
    jz      9f
    mov     rcx, [rax]
    cmp     qword ptr [rcx], 0          # (no inputs: nothing to link)
    je      9f
    push    rax
    mov     eax, [rip+ne_pnode]         # the wire's kind
    lea     eax, [rax-1]
    imul    eax, eax, NODE_SZ
    mov     edi, [r13+GR_NODES+rax+ND_TYPE]
    call    ne_meta_of
    mov     rcx, [rax+48]
    mov     edx, [rip+ne_pk]
    movzx   edx, byte ptr [rcx+rdx]
    pop     rax
    mov     rsi, [rax+8]                # the first input of that kind
    xor     ecx, ecx
1:  mov     r8, [rax]
    cmp     qword ptr [r8+rcx*8], 0
    je      2f
    cmp     byte ptr [rsi+rcx], dl
    je      21f
    inc     ecx
    cmp     ecx, 3
    jb      1b
2:  xor     ecx, ecx
21: mov     edx, ecx
    mov     edi, [rip+ne_pnode]
    mov     esi, ebx
    mov     ecx, [rip+ne_pk]
    call    ne_link
    jmp     9f
3:  cmp     r12d, 2
    jne     4f
    mov     edi, ebx                    # into an input: from its output 0
    mov     esi, [rip+ne_pnode]
    mov     edx, [rip+ne_pk]
    xor     ecx, ecx
    call    ne_link
    jmp     9f
4:  mov     edi, ebx                    # to a pin
    mov     esi, [rip+ne_pk]
    xor     edx, edx
    call    ne_socket
9:  pop     r13
    pop     r12
    pop     rbx
    ret

# ne_place(edi=material / tree, esi=node, edx=x, ecx=y) - by what is shown
ne_place:
    cmp     dword ptr [rip+ne_kind], 0
    je      graph_place
    test    esi, esi                    # (trees: no output node)
    jz      1f
    jmp     nt_place
1:  ret

do_ne_tab:
    push    rbx
    call    ne_rec                      # a group selected: into it
    test    rax, rax
    jz      2f
    cmp     dword ptr [rip+ne_kind], 1
    jne     2f
    mov     ecx, [rip+ne_sel]
    test    ecx, ecx
    jz      2f
    cmp     ecx, [rax+GR_N]
    ja      2f
    dec     ecx
    imul    ecx, ecx, NODE_SZ
    cmp     dword ptr [rax+GR_NODES+rcx+ND_TYPE], 26
    jne     2f
    cvttss2si ebx, [rax+GR_NODES+rcx+ND_P]
    lea     edi, [rbx-1]
    test    edi, edi
    js      2f
    call    nt_get
    test    rax, rax
    jz      2f
    mov     ecx, [rip+ne_pathn]
    cmp     ecx, 8
    jae     2f
    lea     rax, [rip+ne_path]
    mov     [rax+rcx*4], ebx
    inc     dword ptr [rip+ne_pathn]
    jmp     8f
2:  cmp     dword ptr [rip+ne_pathn], 0  # inside one: back out
    je      3f
    dec     dword ptr [rip+ne_pathn]
    jmp     8f
3:  xor     dword ptr [rip+ne_pref], 1  # else the material / the tree
8:  mov     dword ptr [rip+ne_sel], 0
    mov     qword ptr [rip+ne_selm], 0
    mov     dword ptr [rip+dirty], 1
    pop     rbx
    ret

# nodeed_wheel(edi = steps) - scroll
nodeed_wheel:
    mov     dword ptr [rip+dirty], 1
    test    dword ptr [rip+key_mods], MOD_CTRL
    jz      1f
    imul    edi, edi, 40                # Ctrl: scroll
    add     [rip+ne_pany], edi
    ret
1:  test    dword ptr [rip+key_mods], MOD_SHIFT
    jz      2f
    imul    edi, edi, 40                # Shift: sideways
    add     [rip+ne_panx], edi
    ret
2:  push    rbx                         # zoom a step about the pointer
    mov     ebx, edi
    lea     rcx, [rip+ne_zsteps]
    xor     eax, eax                    # the step at (or above) the zoom
3:  mov     edx, [rcx+rax*4]
    cmp     edx, [rip+ne_zoom]
    jge     4f
    inc     eax
    cmp     eax, NZSTEPS-1
    jb      3b
4:  test    ebx, ebx                    # (wheel up, positive here: in)
    jns     5f
    dec     eax                         # (out: the step below)
    js      9f
    jmp     6f
5:  cmp     edx, [rip+ne_zoom]          # (not exactly on a step: that one)
    jne     6f
    inc     eax
    cmp     eax, NZSTEPS
    jae     9f
6:  mov     esi, [rcx+rax*4]
    mov     edi, [rip+ptr_x]
    mov     edx, [rip+ptr_y]
    call    ne_zoom_at
9:  pop     rbx
    ret

# ne_zoom_at(esi=zoom %, edi, edx = the screen point that stays put)
ne_zoom_at:
    push    rbx
    push    r12
    push    r13
    mov     ebx, esi
    mov     r12d, edi
    mov     r13d, edx
    mov     eax, r12d                   # pan' = p - b - (p - b - pan) z' / z
    sub     eax, [rip+ne_bx]
    mov     ecx, eax
    sub     eax, [rip+ne_panx]
    imul    eax, ebx
    cdq
    idiv    dword ptr [rip+ne_zoom]
    sub     ecx, eax
    mov     [rip+ne_panx], ecx
    mov     eax, r13d
    sub     eax, [rip+ne_by]
    mov     ecx, eax
    sub     eax, [rip+ne_pany]
    imul    eax, ebx
    cdq
    idiv    dword ptr [rip+ne_zoom]
    sub     ecx, eax
    mov     [rip+ne_pany], ecx
    mov     [rip+ne_zoom], ebx
    call    zoom_apply
    mov     dword ptr [rip+dirty], 1
    pop     r13
    pop     r12
    pop     rbx
    ret

# nodeed_key(edi = evdev) -> eax = 1 (the open menu takes every key: Esc
#   closes it)
nodeed_key:
    push    rbx
    mov     ebx, edi
    mov     dword ptr [rip+dirty], 1
    cmp     ebx, KEY_ESC
    jne     1f
    mov     dword ptr [rip+ne_menu], 0
    jmp     9f
1:  cmp     ebx, 14                     # Backspace: a letter less
    jne     2f
    cmp     dword ptr [rip+ne_fn], 0
    je      9f
    dec     dword ptr [rip+ne_fn]
    mov     eax, [rip+ne_fn]
    lea     rcx, [rip+ne_filt]
    mov     byte ptr [rcx+rax], 0
    jmp     9f
2:  cmp     ebx, KEY_ENTER              # Enter: the first one shown
    jne     3f
    mov     edi, 1
    call    ne_nth
    mov     dword ptr [rip+ne_menu], 0
    test    eax, eax
    jz      9f
    mov     edi, eax
    call    ne_add_node
    jmp     9f
3:  mov     edi, ebx                    # a letter: search
    call    kb_sym
    cmp     eax, ' '
    jb      9f
    cmp     eax, 127
    jae     9f
    mov     ecx, [rip+ne_fn]
    cmp     ecx, 30
    jae     9f
    lea     rdx, [rip+ne_filt]
    mov     [rdx+rcx], al
    mov     byte ptr [rdx+rcx+1], 0
    inc     dword ptr [rip+ne_fn]
9:  mov     eax, 1
    pop     rbx
    ret

# =============================================================================
#  The header: which graph (the material, or a node tree the active object
#  runs), New Tree, Add
# =============================================================================
.globl ne_header_tools
WIDGET wd_ne_tree, WK_ENUM, "node.tree", flags=WGF_DYN, cb=ne_tree_cb, aux=ne_tree_names, tip="Edit the material's nodes, or a node tree: picking one gives the active object a Geometry Nodes (or Logic) modifier running it"
WIDGET wd_ne_new,  WK_BUTTON, "node.new_tree", "New Tree", tip="A new geometry node tree, run by the active object"
WIDGET wd_ne_add,  WK_BUTTON, "node.add", "Add", tip="Add a node (Shift+A in the editor, then type to search the list)"
.section .rodata
s_ne_mat:       .asciz "Material"
s_ne_nt_undo:   .asciz "Node Tree"
.text
# ne_header_tools(edi=x, esi=header y, edx=right limit)
ne_header_tools:
    push    rbx
    push    r12
    push    r13
    mov     ebx, edi
    lea     r12d, [rsi+1]
    mov     r13d, edx
    call    ne_rec                      # what is shown
    xor     eax, eax
    cmp     dword ptr [rip+ne_kind], 0
    je      1f
    mov     eax, [rip+ne_mat]
    inc     eax
1:  mov     [rip+ne_tsel], eax
    lea     eax, [rbx+150]
    cmp     eax, r13d
    jg      9f
    lea     rdi, [rip+wd_ne_tree]
    mov     esi, ebx
    mov     edx, r12d
    mov     ecx, 150
    lea     r8, [rip+ne_tsel]
    xor     r9d, r9d
    call    wg
    add     ebx, 156
    lea     eax, [rbx+80]
    cmp     eax, r13d
    jg      9f
    lea     rdi, [rip+wd_ne_new]
    mov     esi, ebx
    mov     edx, r12d
    mov     ecx, 80
    xor     r8d, r8d
    xor     r9d, r9d
    call    wg
    test    eax, eax
    jz      2f
    call    ne_new_tree
2:  add     ebx, 86
    lea     eax, [rbx+50]
    cmp     eax, r13d
    jg      9f
    lea     rdi, [rip+wd_ne_add]
    mov     esi, ebx
    mov     edx, r12d
    mov     ecx, 50
    xor     r8d, r8d
    xor     r9d, r9d
    call    wg
    test    eax, eax
    jz      9f
    push    qword ptr [rip+ptr_x]       # the add menu, under the button
    mov     [rip+ptr_x], ebx
    lea     eax, [r12+24]
    mov     [rip+ptr_y], eax
    sub     rsp, 8
    call    do_ne_add_menu
    add     rsp, 8
    pop     rax                         # (the pointer stays where it is)
    mov     [rip+ptr_x], eax
    shr     rax, 32
    mov     [rip+ptr_y], eax
9:  pop     r13
    pop     r12
    pop     rbx
    ret

ne_tree_names:                          # -> rax = labels, edx = count
    sub     rsp, 8
    call    nt_count
    lea     rdi, [rip+ne_tlbl]
    lea     rsi, [rip+s_ne_mat]
    mov     edx, eax
    lea     rcx, [rip+nt_get]
    mov     r8d, 80
    call    pnl_list
    mov     edx, eax
    lea     rax, [rip+ne_tlbl]
    add     rsp, 8
    ret

# ne_tree_cb(rdi=&ne_tsel) - the material, or that tree on the active mesh
ne_tree_cb:
    mov     dword ptr [rip+ne_pathn], 0
    mov     eax, [rdi]
    test    eax, eax
    jnz     ne_use_tree
    mov     dword ptr [rip+ne_pref], 1
    mov     dword ptr [rip+dirty], 1
    ret
# ne_use_tree(eax=tree + 1)
ne_use_tree:
    push    rbx
    push    r12
    sub     rsp, 8
    mov     ebx, eax
    mov     dword ptr [rip+ne_pref], 0
    call    active_mesh_obj
    test    rax, rax
    jz      9f
    mov     r12, rax
    lea     rdi, [rip+s_ne_nt_undo]
    call    undo_push
    lea     edi, [rbx-1]
    call    lg_is_logic
    mov     esi, MT_GEONODES_
    test    eax, eax
    jz      1f
    mov     esi, MT_LOGIC_
1:  mov     rdi, r12
    mov     edx, ebx
    call    mod_use_tree
    mov     dword ptr [rip+dirty], 1
9:  add     rsp, 8
    pop     r12
    pop     rbx
    ret

# ne_new_tree - tree.new, then the active mesh runs it
ne_new_tree:
    sub     rsp, 8
    push    qword ptr [rip+op_arg]
    mov     qword ptr [rip+op_arg], 0
    lea     rdi, [rip+op_tree_new]
    call    run_op
    pop     qword ptr [rip+op_arg]
    call    nt_count
    mov     dword ptr [rip+ne_pathn], 0
    add     rsp, 8
    jmp     ne_use_tree                 # (eax = the new one + 1)

# ne_vis(edi=type) -> eax = 1 when its name holds the search text (any case)
ne_vis:
    mov     eax, 1
    cmp     dword ptr [rip+ne_fn], 0
    je      9f
    sub     rsp, 8
    call    ne_title
    add     rsp, 8
1:  lea     rsi, [rip+ne_filt]          # at each start in the name
    xor     ecx, ecx
2:  movzx   edx, byte ptr [rsi+rcx]
    test    edx, edx
    jz      8f                          # (all of it matched)
    movzx   r8d, byte ptr [rax+rcx]
    test    r8d, r8d
    jz      7f
    or      edx, 0x20
    or      r8d, 0x20
    cmp     edx, r8d
    jne     3f
    inc     ecx
    jmp     2b
3:  inc     rax
    cmp     byte ptr [rax], 0
    jne     1b
7:  xor     eax, eax
    ret
8:  mov     eax, 1
9:  ret

# ne_vcount -> eax = the types shown in the menu
ne_vcount:
    push    rbx
    push    r12
    sub     rsp, 8
    call    ne_ntypes
    mov     r12d, eax
    xor     ebx, ebx
    xor     eax, eax
    mov     [rsp], eax
1:  inc     ebx
    cmp     ebx, r12d
    ja      9f
    mov     edi, ebx
    call    ne_vis
    add     [rsp], eax
    jmp     1b
9:  mov     eax, [rsp]
    add     rsp, 8
    pop     r12
    pop     rbx
    ret

# ne_nth(edi=k, 1..) -> eax = the k-th type shown (0: none)
ne_nth:
    push    rbx
    push    r12
    push    r13
    mov     r13d, edi
    call    ne_ntypes
    mov     r12d, eax
    xor     ebx, ebx
1:  inc     ebx
    cmp     ebx, r12d
    ja      8f
    mov     edi, ebx
    call    ne_vis
    sub     r13d, eax
    jnz     1b
    mov     eax, ebx
    jmp     9f
8:  xor     eax, eax
9:  pop     r13
    pop     r12
    pop     rbx
    ret

do_ne_add_menu:
    sub     rsp, 8
    call    ne_rec
    test    rax, rax
    jz      9f
    mov     dword ptr [rip+ne_fn], 0    # (no search yet)
    mov     byte ptr [rip+ne_filt], 0
    mov     dword ptr [rip+ne_menu], 1
    mov     eax, [rip+ptr_x]
    mov     [rip+ne_mx], eax
    mov     [rip+ne_ax], eax
    mov     ecx, [rip+ptr_y]
    mov     [rip+ne_ay], ecx
    call    ne_menu_size                # (all of it inside the body)
    inc     eax
    imul    eax, eax, NROW
    add     eax, 6
    mov     ecx, [rip+ne_by]
    add     ecx, [rip+ne_bh]
    sub     ecx, eax
    mov     eax, [rip+ptr_y]
    cmp     eax, ecx
    jle     1f
    mov     eax, ecx
1:  cmp     eax, [rip+ne_by]
    jge     2f
    mov     eax, [rip+ne_by]
2:  mov     [rip+ne_my], eax
9:  add     rsp, 8
    ret

do_ne_delete:
    cmp     dword ptr [rip+ne_fsel], 0  # a comment frame selected: it alone
    jne     ne_frame_delete
    push    rbx
    push    r12
    sub     rsp, 8
    mov     rbx, [rip+ne_selm]          # the selected ones, last first
    mov     eax, [rip+ne_sel]
    test    rbx, rbx
    jnz     1f
    test    eax, eax
    jz      9f
    bts     rbx, rax
1:  call    ne_rec                      # one undo step for them all
    test    rax, rax
    jz      8f
    lea     rdi, [rip+s_undo_del]
    call    undo_push
2:  bsr     r12, rbx
    jz      8f
    btr     rbx, r12
    test    r12d, r12d
    jz      8f
    call    ne_rec
    test    rax, rax
    jz      8f
    cmp     r12d, [rax+GR_N]
    ja      2b
    mov     edi, [rip+ne_mat]
    mov     esi, r12d
    cmp     dword ptr [rip+ne_kind], 0
    jne     3f
    call    graph_delete
    jmp     2b
3:  call    nt_delete
    jmp     2b
8:  mov     dword ptr [rip+ne_sel], 0
    mov     qword ptr [rip+ne_selm], 0
    mov     dword ptr [rip+dirty], 1
    call    eval_flush
9:  add     rsp, 8
    pop     r12
    pop     rbx
    ret

# ne_own -> rax = the record shown, writable (copied when shared), or 0
ne_own:
    sub     rsp, 8
    call    ne_rec
    test    rax, rax
    jz      9f
    mov     edi, [rip+ne_mat]
    cmp     dword ptr [rip+ne_kind], 0
    jne     1f
    call    graph_own
    jmp     9f
1:  call    nt_own
9:  add     rsp, 8
    ret

# ne_copy -> eax = the nodes copied: the selection into the node clipboard,
#   links between them marked (bit 30: the clipboard's own numbering)
ne_copy:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    call    ne_rec
    test    rax, rax
    jz      8f
    mov     rbx, rax
    mov     rdi, rbx
    call    ne_layout                   # (the places, placed or laid out)
    lea     rdi, [rip+ne_cmap]
    xor     eax, eax
    mov     ecx, 49
    rep     stosd
    mov     r12, [rip+ne_selm]
    mov     eax, [rip+ne_sel]           # (none selected: the active one)
    test    r12, r12
    jnz     0f
    test    eax, eax
    jz      8f
    bts     r12, rax
0:  xor     r13d, r13d                  # copied so far
    mov     dword ptr [rip+ne_clipx0], 0x7fffffff
    mov     dword ptr [rip+ne_clipy0], 0x7fffffff
    mov     r14d, 1
1:  cmp     r14d, [rip+ne_n]
    ja      3f
    bt      r12, r14
    jnc     2f
    lea     eax, [r14-1]                # the node
    imul    eax, eax, NODE_SZ
    lea     rsi, [rbx+GR_NODES+rax]
    imul    edi, r13d, NODE_SZ
    lea     rax, [rip+ne_clipnodes]
    add     rdi, rax
    mov     ecx, NODE_SZ
    rep     movsb
    lea     r8, [rip+ne_gx]             # its place
    mov     eax, [r8+r14*4]
    lea     rcx, [rip+ne_clippos]
    mov     [rcx+r13*8], eax
    cmp     eax, [rip+ne_clipx0]
    jge     11f
    mov     [rip+ne_clipx0], eax
11: lea     r8, [rip+ne_gy]
    mov     eax, [r8+r14*4]
    mov     [rcx+r13*8+4], eax
    cmp     eax, [rip+ne_clipy0]
    jge     12f
    mov     [rip+ne_clipy0], eax
12: inc     r13d
    lea     rax, [rip+ne_cmap]
    mov     [rax+r14*4], r13d
2:  inc     r14d
    jmp     1b
3:  test    r13d, r13d
    jz      8f
    xor     r14d, r14d                  # links among them: renumbered
4:  cmp     r14d, r13d
    jae     7f
    imul    eax, r14d, NODE_SZ
    lea     rdx, [rip+ne_clipnodes]
    lea     rax, [rdx+rax+ND_IN]
    xor     ecx, ecx
5:  movzx   edx, word ptr [rax]
    test    edx, edx
    jz      6f
    cmp     edx, 48
    ja      6f
    lea     r8, [rip+ne_cmap]
    mov     r9d, [r8+rdx*4]
    test    r9d, r9d
    jz      6f
    mov     word ptr [rax], r9w
    or      dword ptr [rax], 0x40000000
6:  add     rax, 16
    inc     ecx
    cmp     ecx, 3
    jb      5b
    inc     r14d
    jmp     4b
7:  mov     [rip+ne_clipn], r13d
    mov     eax, [rip+ne_kind]
    mov     [rip+ne_clipk], eax
    mov     eax, [rip+ne_mat]
    mov     [rip+ne_clipm], eax
    mov     eax, r13d
    jmp     9f
8:  xor     eax, eax
9:  pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# ne_paste(edi, esi = where the group's top left goes (graph units), rdx =
#   the undo step's name) -> eax = the nodes added: the clipboard appended
#   (links among them renumbered; links from outside kept in the graph they
#   came from, else the input's constant); they become the selection
ne_paste:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    push    rbp
    sub     rsp, 24
    mov     [rsp], edi
    mov     [rsp+4], esi
    mov     [rsp+8], rdx
    call    ne_rec
    test    rax, rax
    jz      8f
    mov     r13d, [rip+ne_clipn]
    test    r13d, r13d
    jz      8f
    mov     eax, [rip+ne_kind]
    cmp     eax, [rip+ne_clipk]
    je      1f
    lea     rdi, [rip+s_ne_clipkind]
    call    log_line
    jmp     8f
1:  mov     rax, [rsp+8]
    mov     rdi, rax
    call    undo_push
    call    ne_own
    test    rax, rax
    jz      8f
    mov     rbx, rax
    mov     r12d, [rbx+GR_N]            # the first new one: r12d + 1
    lea     eax, [r12+r13]
    cmp     eax, [rip+ne_maxn]
    jbe     2f
    lea     rdi, [rip+s_ne_noroom]
    call    log_line
    call    undo_drop_last
    jmp     8f
2:  xor     ebp, ebp                    # the same graph: outside links stay
    mov     eax, [rip+ne_mat]
    cmp     eax, [rip+ne_clipm]
    jne     21f
    inc     ebp
21: xor     r14d, r14d
3:  cmp     r14d, r13d
    jae     7f
    lea     eax, [r12+r14]              # the node
    imul    eax, eax, NODE_SZ
    lea     r15, [rbx+GR_NODES+rax]
    imul    eax, r14d, NODE_SZ
    lea     rsi, [rip+ne_clipnodes]
    add     rsi, rax
    mov     rdi, r15
    mov     ecx, NODE_SZ
    rep     movsb
    xor     ecx, ecx                    # its links
4:  imul    eax, ecx, 16
    lea     rdx, [r15+ND_IN+rax]
    mov     eax, [rdx]
    test    ax, ax
    jz      6f
    test    eax, 0x40000000
    jz      5f
    and     eax, 0x00ff0000             # among them: renumbered
    mov     r8d, [rdx]
    movzx   r8d, r8w
    add     r8d, r12d
    or      eax, r8d
    mov     [rdx], eax
    jmp     6f
5:  test    ebp, ebp                    # from outside: the same graph keeps
    jz      51f                         #  it, another unplugs it
    movzx   r8d, ax
    cmp     r8d, r12d
    jbe     6f
51: mov     dword ptr [rdx], 0
6:  inc     ecx
    cmp     ecx, 3
    jb      4b
    lea     rax, [rip+ne_clippos]       # its place: as copied, moved
    mov     ecx, [rax+r14*8]
    sub     ecx, [rip+ne_clipx0]
    add     ecx, [rsp]
    mov     edx, [rax+r14*8+4]
    sub     edx, [rip+ne_clipy0]
    add     edx, [rsp+4]
    mov     eax, ecx
    or      eax, edx
    jnz     61f
    inc     edx                         # ((0, 0): not placed)
61: mov     [r15+ND_POS], cx
    mov     [r15+ND_POS+2], dx
    inc     r14d
    jmp     3b
7:  add     [rbx+GR_N], r13d
    xor     eax, eax                    # the new ones selected
    xor     ecx, ecx
71: cmp     ecx, r13d
    jae     72f
    lea     edx, [r12+rcx+1]
    bts     rax, rdx
    inc     ecx
    jmp     71b
72: mov     [rip+ne_selm], rax
    lea     eax, [r12+1]
    mov     [rip+ne_sel], eax
    mov     dword ptr [rip+dirty], 1
    call    eval_flush
    mov     eax, r13d
    jmp     9f
8:  xor     eax, eax
9:  add     rsp, 24
    pop     rbp
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# node.collapse (H) - the selection collapsed, or (all of it collapsed
#   already) whole again: one undo step
do_ne_collapse:
    push    rbx
    push    r12
    push    r13
    mov     r12, [rip+ne_selm]
    btr     r12, 0                      # (not the output)
    test    r12, r12
    jz      9f
    call    ne_rec
    test    rax, rax
    jz      9f
    mov     ecx, 1                      # all collapsed already? then whole
    mov     r13d, 1
1:  cmp     ecx, [rip+ne_n]
    ja      2f
    bt      r12, rcx
    jnc     11f
    test    byte ptr [rax+NE_NFLAGS+rcx-1], 1
    jnz     11f
    xor     r13d, r13d                  # (one is whole: collapse them all)
11: inc     ecx
    jmp     1b
2:  lea     rdi, [rip+s_undo_coll]
    call    undo_push
    call    ne_own
    test    rax, rax
    jz      9f
    mov     ecx, 1
3:  cmp     ecx, [rip+ne_n]
    ja      8f
    bt      r12, rcx
    jnc     31f
    and     byte ptr [rax+NE_NFLAGS+rcx-1], 0xfe
    test    r13d, r13d
    jnz     31f
    or      byte ptr [rax+NE_NFLAGS+rcx-1], 1
31: inc     ecx
    jmp     3b
8:  mov     dword ptr [rip+dirty], 1
9:  pop     r13
    pop     r12
    pop     rbx
    ret

# ---- comment frames ------------------------------------------------------
# ne_fr_scr(rsi=frame record) -> r8d x, r9d y, r10d w, r11d h on screen
ne_fr_scr:
    movsx   eax, word ptr [rsi]
    call    zs
    add     eax, [rip+ne_bx]
    add     eax, [rip+ne_panx]
    mov     r8d, eax
    movsx   eax, word ptr [rsi+2]
    call    zs
    add     eax, [rip+ne_by]
    add     eax, [rip+ne_pany]
    mov     r9d, eax
    movsx   eax, word ptr [rsi+4]
    call    zs
    mov     r10d, eax
    movsx   eax, word ptr [rsi+6]
    call    zs
    mov     r11d, eax
    ret

# ne_draw_frames (rbx = record) - the comment frames: a body, a title bar
#   with the title, a grip at the corner; the selected one outlined
ne_draw_frames:
    push    r12
    push    r13
    push    r14
    push    r15
    push    rbp
    sub     rsp, 16
    xor     r12d, r12d
1:  cmp     r12d, NE_NFR
    jae     9f
    imul    eax, r12d, FR_SZ
    lea     r13, [rbx+NE_FRAMES+rax]
    cmp     word ptr [r13+4], 0
    jle     8f
    mov     rsi, r13
    call    ne_fr_scr
    mov     r14d, r8d                   # x y w h
    mov     r15d, r9d
    mov     [rsp], r10d
    mov     [rsp+4], r11d
    lea     eax, [r12+1]                # (selected: an outline)
    cmp     eax, [rip+ne_fsel]
    jne     2f
    lea     edi, [r14-2]
    lea     esi, [r15-2]
    mov     edx, [rsp]
    add     edx, 4
    mov     ecx, [rsp+4]
    add     ecx, 4
    mov     r8d, COL_ACCENT
    call    fill_rect
2:  mov     edi, r14d
    mov     esi, r15d
    mov     edx, [rsp]
    mov     ecx, [rsp+4]
    mov     r8d, [r13+8]                # (its colour, else the default)
    test    r8d, r8d
    jnz     21f
    mov     r8d, COL_NE_FRBODY
21: call    fill_rect
    mov     edi, r14d
    mov     esi, r15d
    mov     edx, [rsp]
    mov     ecx, [rip+ne_hdr]
    add     ecx, 4
    mov     r8d, COL_NE_FRBAR
    call    fill_rect
    mov     edi, r14d                   # the grip
    add     edi, [rsp]
    sub     edi, 8
    mov     esi, r15d
    add     esi, [rsp+4]
    sub     esi, 8
    mov     edx, 6
    mov     ecx, 6
    mov     r8d, COL_NE_FRBAR
    call    fill_rect
    lea     edi, [r14+8]
    mov     esi, r15d
    add     esi, [rip+ne_hy]
    add     esi, 2
    lea     rdx, [r13+12]
    mov     ecx, COL_TEXT
    call    draw_text
8:  inc     r12d
    jmp     1b
9:  add     rsp, 16
    pop     rbp
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    ret

# ne_frame_hit(r12d, r13d = pointer) -> eax: 0 none, 1 a frame's title bar,
#   2 its corner; edx = the frame (the top one: the last)
ne_frame_hit:
    push    rbx
    push    r14
    sub     rsp, 8
    call    ne_rec
    test    rax, rax
    jz      8f
    mov     rbx, rax
    mov     r14d, NE_NFR
1:  dec     r14d
    js      8f
    imul    eax, r14d, FR_SZ
    lea     rsi, [rbx+NE_FRAMES+rax]
    cmp     word ptr [rsi+4], 0
    jle     1b
    call    ne_fr_scr
    mov     eax, r12d                   # inside?
    sub     eax, r8d
    js      1b
    cmp     eax, r10d
    jge     1b
    mov     ecx, r13d
    sub     ecx, r9d
    js      1b
    cmp     ecx, r11d
    jge     1b
    mov     edx, r10d                   # the corner (12 px)
    sub     edx, eax
    cmp     edx, 12
    jg      2f
    mov     edx, r11d
    sub     edx, ecx
    cmp     edx, 12
    jg      2f
    mov     eax, 2
    mov     edx, r14d
    jmp     9f
2:  mov     edx, [rip+ne_hdr]           # the title bar
    add     edx, 4
    cmp     ecx, edx
    jge     1b                          # (the body: through to a box select)
    mov     eax, 1
    mov     edx, r14d
    jmp     9f
8:  xor     eax, eax
9:  add     rsp, 8
    pop     r14
    pop     rbx
    ret

# ne_frame_grab(edi=frame) - a drag begins: its place and size, the nodes
#   inside it (their places)
ne_frame_grab:
    push    rbx
    push    r12
    push    r13
    mov     r12d, edi
    call    ne_rec
    test    rax, rax
    jz      9f
    mov     rbx, rax
    imul    eax, r12d, FR_SZ
    lea     r13, [rbx+NE_FRAMES+rax]
    movsx   eax, word ptr [r13]
    mov     [rip+ne_fx0], eax
    movsx   eax, word ptr [r13+2]
    mov     [rip+ne_fy0], eax
    cmp     dword ptr [rip+ne_drag], 11
    jne     1f
    movsx   eax, word ptr [r13+4]       # (resizing: the size)
    mov     [rip+ne_fx0], eax
    movsx   eax, word ptr [r13+6]
    mov     [rip+ne_fy0], eax
1:  xor     r8, r8                      # the nodes wholly inside
    xor     ecx, ecx
2:  cmp     ecx, [rip+ne_n]
    ja      4f
    lea     r9, [rip+ne_gx]
    mov     eax, [r9+rcx*4]
    lea     r9, [rip+ne_sx]
    mov     [r9+rcx*4], eax
    movsx   edx, word ptr [r13]
    cmp     eax, edx
    jl      3f
    add     eax, NW
    movsx   r10d, word ptr [r13+4]
    add     edx, r10d
    cmp     eax, edx
    jg      3f
    lea     r9, [rip+ne_gy]
    mov     eax, [r9+rcx*4]
    movsx   edx, word ptr [r13+2]
    cmp     eax, edx
    jl      3f
    lea     r9, [rip+ne_gh]
    add     eax, [r9+rcx*4]
    movsx   r10d, word ptr [r13+6]
    add     edx, r10d
    cmp     eax, edx
    jg      3f
    bts     r8, rcx
3:  lea     r9, [rip+ne_gy]
    mov     eax, [r9+rcx*4]
    lea     r9, [rip+ne_sy]
    mov     [r9+rcx*4], eax
    inc     ecx
    jmp     2b
4:  cmp     dword ptr [rip+ne_kind], 0  # (trees: no output node)
    je      5f
    btr     r8, 0
5:  mov     [rip+ne_fmask], r8
9:  pop     r13
    pop     r12
    pop     rbx
    ret

# ne_frame_drag (r12d, r13d = pointer) - moving a frame (and its nodes) or
#   resizing it
ne_frame_drag:
    push    rbx
    push    r14
    push    r15
    call    ne_first_change
    mov     eax, r12d
    sub     eax, [rip+ne_x0]
    call    ne_unzoom
    mov     r14d, eax
    mov     eax, r13d
    sub     eax, [rip+ne_y0]
    call    ne_unzoom
    mov     r15d, eax
    call    ne_own
    test    rax, rax
    jz      9f
    mov     ecx, [rip+ne_dk]
    imul    ecx, ecx, FR_SZ
    lea     rbx, [rax+NE_FRAMES+rcx]
    mov     eax, [rip+ne_fx0]
    add     eax, r14d
    mov     ecx, [rip+ne_fy0]
    add     ecx, r15d
    cmp     dword ptr [rip+ne_drag], 11
    jne     1f
    cmp     eax, 80                     # (a size: at least 80 x 60)
    jge     81f
    mov     eax, 80
81: cmp     ecx, 60
    jge     82f
    mov     ecx, 60
82: mov     [rbx+4], ax
    mov     [rbx+6], cx
    jmp     8f
1:  mov     [rbx], ax
    mov     [rbx+2], cx
    xor     ebx, ebx                    # the nodes inside move with it
2:  cmp     ebx, [rip+ne_n]
    ja      8f
    mov     rax, [rip+ne_fmask]
    bt      rax, rbx
    jnc     3f
    lea     r8, [rip+ne_sx]
    mov     edx, [r8+rbx*4]
    add     edx, r14d
    lea     r8, [rip+ne_sy]
    mov     ecx, [r8+rbx*4]
    add     ecx, r15d
    mov     edi, [rip+ne_mat]
    mov     esi, ebx
    call    ne_place
3:  inc     ebx
    jmp     2b
8:  mov     dword ptr [rip+dirty], 1
9:  pop     r15
    pop     r14
    pop     rbx
    ret

# ne_frame_rename - the console asks for the selected frame's title
ne_frame_rename:
    sub     rsp, 8
    call    fmt_reset
    lea     rdi, [rip+s_op_frtitle]
    call    fmt_str
    mov     edi, [rip+ne_fsel]
    call    fmt_int
    mov     edi, ' '
    call    fmt_char
    lea     rdi, [rip+tfi_console]
    call    tf_select
    lea     rsi, [rip+fmt_buf]
    call    tf_load
    mov     edi, 1
    call    tf_set_focus
    mov     dword ptr [rip+dirty], 1
    add     rsp, 8
    ret

# ne_frame_delete - the selected frame removed (one undo step)
ne_frame_delete:
    push    rbx
    lea     rdi, [rip+s_undo_frame]
    call    undo_push
    call    ne_own
    test    rax, rax
    jz      9f
    mov     ecx, [rip+ne_fsel]
    dec     ecx
    imul    ecx, ecx, FR_SZ
    lea     rdi, [rax+NE_FRAMES+rcx]
    xor     eax, eax
    mov     ecx, FR_SZ
    rep     stosb
    mov     dword ptr [rip+ne_fsel], 0
    mov     dword ptr [rip+dirty], 1
9:  pop     rbx
    ret

# node.comment (C) - a frame around the selected nodes (none: at the
#   pointer, 320 x 200); it becomes the selected one
do_ne_comment:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    call    ne_rec
    test    rax, rax
    jz      9f
    mov     rbx, rax
    mov     rdi, rbx
    call    ne_layout
    xor     r12d, r12d                  # a free slot
1:  imul    eax, r12d, FR_SZ
    cmp     word ptr [rbx+NE_FRAMES+rax+4], 0
    jle     2f
    inc     r12d
    cmp     r12d, NE_NFR
    jb      1b
    lea     rdi, [rip+s_ne_frfull]
    call    log_line
    jmp     9f
2:  mov     r13d, 0x7fffffff            # the selection's box (graph units)
    mov     r14d, 0x7fffffff
    mov     r15d, 0x80000000
    mov     r11d, 0x80000000
    mov     r10, [rip+ne_selm]
    xor     ecx, ecx
3:  cmp     ecx, [rip+ne_n]
    ja      4f
    bt      r10, rcx
    jnc     31f
    lea     r8, [rip+ne_gx]
    mov     eax, [r8+rcx*4]
    cmp     eax, r13d
    cmovl   r13d, eax
    add     eax, NW
    cmp     eax, r15d
    cmovg   r15d, eax
    lea     r8, [rip+ne_gy]
    mov     eax, [r8+rcx*4]
    cmp     eax, r14d
    cmovl   r14d, eax
    lea     r8, [rip+ne_gh]
    add     eax, [r8+rcx*4]
    cmp     eax, r11d
    cmovg   r11d, eax
31: inc     ecx
    jmp     3b
4:  cmp     r13d, r15d                  # (nothing selected: at the pointer)
    jle     5f
    mov     eax, [rip+ptr_x]
    sub     eax, [rip+ne_bx]
    sub     eax, [rip+ne_panx]
    call    ne_unzoom
    mov     r13d, eax
    lea     r15d, [rax+320]
    mov     eax, [rip+ptr_y]
    sub     eax, [rip+ne_by]
    sub     eax, [rip+ne_pany]
    call    ne_unzoom
    mov     r14d, eax
    lea     r11d, [rax+200]
    jmp     6f
5:  sub     r13d, 20                    # a margin, room for the title
    sub     r14d, NHDR+24
    add     r15d, 20
    add     r11d, 20
6:  push    r11
    lea     rdi, [rip+s_undo_frame]
    call    undo_push
    call    ne_own
    pop     r11
    test    rax, rax
    jz      9f
    imul    ecx, r12d, FR_SZ
    lea     rdi, [rax+NE_FRAMES+rcx]
    mov     [rdi], r13w
    mov     [rdi+2], r14w
    mov     eax, r15d
    sub     eax, r13d
    mov     [rdi+4], ax
    mov     eax, r11d
    sub     eax, r14d
    mov     [rdi+6], ax
    mov     dword ptr [rdi+8], 0
    lea     rsi, [rip+s_fr_title]
    lea     rdi, [rdi+12]
    mov     ecx, 8
    rep     movsb
    lea     eax, [r12+1]
    mov     [rip+ne_fsel], eax
    mov     dword ptr [rip+dirty], 1
9:  pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# node.frame_title <frame 1-6> <title>
do_ne_frtitle:
    push    rbx
    push    r12
    sub     rsp, 8
    mov     rsi, [rip+op_arg]
    test    rsi, rsi
    jz      8f
    lea     rdx, [rsi+64]
    call    parse_float
    test    eax, eax
    jz      8f
    cvttss2si r12d, xmm0
    dec     r12d
    cmp     r12d, NE_NFR
    jae     8f
1:  cmp     byte ptr [rsi], ' '
    jne     2f
    inc     rsi
    jmp     1b
2:  mov     rbx, rsi
    call    ne_own
    test    rax, rax
    jz      8f
    imul    ecx, r12d, FR_SZ
    lea     rdi, [rax+NE_FRAMES+rcx]
    cmp     word ptr [rdi+4], 0
    jle     8f
    lea     rdi, [rdi+12]
    xor     ecx, ecx
3:  mov     al, [rbx+rcx]
    mov     [rdi+rcx], al
    test    al, al
    jz      4f
    inc     ecx
    cmp     ecx, 35
    jb      3b
    mov     byte ptr [rdi+rcx], 0
4:  mov     dword ptr [rip+dirty], 1
    jmp     9f
8:  lea     rdi, [rip+s_ne_frneed]
    call    log_line
    call    undo_drop_last
9:  add     rsp, 8
    pop     r12
    pop     rbx
    ret

# node.copy (Ctrl+C)
do_ne_copy:
    push    rbx
    call    ne_copy
    test    eax, eax
    jz      9f
    mov     ebx, eax
    call    fmt_reset
    lea     rdi, [rip+s_ne_copied]
    call    fmt_str
    mov     edi, ebx
    call    fmt_int
    lea     rdi, [rip+fmt_buf]
    call    log_line
9:  pop     rbx
    ret

# node.paste (Ctrl+V) - at the pointer (outside the body: its top left)
do_ne_paste:
    sub     rsp, 8
    mov     eax, [rip+ptr_x]
    sub     eax, [rip+ne_bx]
    js      1f
    cmp     eax, [rip+ne_bw]
    jge     1f
    mov     ecx, [rip+ptr_y]
    sub     ecx, [rip+ne_by]
    js      1f
    cmp     ecx, [rip+ne_bh]
    jge     1f
    jmp     2f
1:  mov     eax, 40                     # (the body's top left)
    mov     ecx, 40
2:  sub     eax, [rip+ne_panx]          # screen -> graph
    push    rcx
    call    ne_unzoom
    pop     rcx
    mov     edi, eax
    mov     eax, ecx
    sub     eax, [rip+ne_pany]
    push    rdi
    call    ne_unzoom
    pop     rdi
    mov     esi, eax
    lea     rdx, [rip+s_undo_paste]
    call    ne_paste
    add     rsp, 8
    ret

# node.duplicate (Shift+D) - copies of the selection, 40 down and right (the
#   clipboard is left as it was)
do_ne_dup:
    push    rbx
    sub     rsp, NODE_SZ*48+8*48+32
    lea     rsi, [rip+ne_clipk]         # (the clipboard kept aside)
    lea     rdi, [rsp]
    mov     ecx, 20+NODE_SZ*48+8*48
    rep     movsb
    call    ne_copy
    test    eax, eax
    jz      8f
    mov     edi, [rip+ne_clipx0]
    add     edi, 40
    mov     esi, [rip+ne_clipy0]
    add     esi, 40
    lea     rdx, [rip+s_undo_dup]
    call    ne_paste
8:  lea     rsi, [rsp]
    lea     rdi, [rip+ne_clipk]
    mov     ecx, 20+NODE_SZ*48+8*48
    rep     movsb
    add     rsp, NODE_SZ*48+8*48+32
    pop     rbx
    ret

# node.cut (Ctrl+X)
do_ne_cut:
    sub     rsp, 8
    call    ne_copy
    test    eax, eax
    jz      9f
    call    do_ne_delete
9:  add     rsp, 8
    ret

# node.group (Ctrl+G) - tree.group with the selection
do_ne_group:
    push    rbx
    push    r12
    sub     rsp, 8
    call    ne_rec
    test    rax, rax
    jz      9f
    cmp     dword ptr [rip+ne_kind], 1
    jne     9f
    mov     rbx, [rip+ne_selm]
    test    rbx, rbx
    jz      9f
    call    ne_arg_start
1:  bsf     r12, rbx
    jz      2f
    btr     rbx, r12
    mov     edi, r12d
    call    ne_arg_int
    jmp     1b
2:  call    ne_arg_done
    lea     rdi, [rip+s_tp_group]
    call    ne_run
    mov     dword ptr [rip+ne_sel], 0
    mov     qword ptr [rip+ne_selm], 0
9:  add     rsp, 8
    pop     r12
    pop     rbx
    ret

# node.view_fit - the nodes' box at the body's top left (a margin)
do_ne_fit:
    xor     edi, edi
    jmp     ne_frame
# node.view_selected (F) - the selected nodes in view (none: all)
do_ne_frame_sel:
    mov     edi, 1
# ne_frame(edi=1: only the selected) - zoom (25 .. 100 %) and pan so the
#   nodes fill the body, centred
ne_frame:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    push    rbp
    sub     rsp, 24
    mov     ebp, edi
    call    ne_rec
    test    rax, rax
    jz      9f
    mov     rdi, rax
    call    ne_layout
    cmp     qword ptr [rip+ne_selm], 0  # (nothing selected: all)
    jne     0f
    xor     ebp, ebp
0:  mov     r12d, 0x7fffffff            # the box: x0 y0 x1 y1 (graph units)
    mov     r13d, 0x7fffffff
    mov     r14d, 0x80000000
    mov     r15d, 0x80000000
    xor     ebx, ebx
    cmp     dword ptr [rip+ne_kind], 0  # (trees: no output node)
    je      1f
    inc     ebx
1:  cmp     ebx, [rip+ne_n]
    ja      2f
    test    ebp, ebp
    jz      11f
    mov     rax, [rip+ne_selm]
    bt      rax, rbx
    jnc     12f
11: lea     r8, [rip+ne_gx]
    mov     eax, [r8+rbx*4]
    cmp     eax, r12d
    cmovl   r12d, eax
    add     eax, NW
    cmp     eax, r14d
    cmovg   r14d, eax
    lea     r8, [rip+ne_gy]
    mov     eax, [r8+rbx*4]
    cmp     eax, r13d
    cmovl   r13d, eax
    lea     r8, [rip+ne_gh]
    add     eax, [r8+rbx*4]
    cmp     eax, r15d
    cmovg   r15d, eax
12: inc     ebx
    jmp     1b
2:  cmp     r12d, r14d                  # (nothing: as it was)
    jg      9f
    mov     eax, [rip+ne_bw]            # zoom: the tighter of the two
    sub     eax, 60
    imul    eax, eax, 100
    mov     ecx, r14d
    sub     ecx, r12d
    inc     ecx
    cdq
    idiv    ecx
    mov     [rsp], eax
    mov     eax, [rip+ne_bh]
    sub     eax, 60
    imul    eax, eax, 100
    mov     ecx, r15d
    sub     ecx, r13d
    inc     ecx
    cdq
    idiv    ecx
    cmp     eax, [rsp]
    jle     3f
    mov     eax, [rsp]
3:  cmp     eax, 100
    jle     4f
    mov     eax, 100
4:  cmp     eax, 25
    jge     5f
    mov     eax, 25
5:  mov     [rip+ne_zoom], eax
    call    zoom_apply
    mov     eax, r12d                   # pan: the box's centre in the body's
    add     eax, r14d
    sar     eax, 1
    call    zs
    mov     ecx, [rip+ne_bw]
    sar     ecx, 1
    sub     ecx, eax
    mov     [rip+ne_panx], ecx
    mov     eax, r13d
    add     eax, r15d
    sar     eax, 1
    call    zs
    mov     ecx, [rip+ne_bh]
    sar     ecx, 1
    sub     ecx, eax
    mov     [rip+ne_pany], ecx
    mov     dword ptr [rip+dirty], 1
9:  add     rsp, 24
    pop     rbp
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

.section .note.GNU-stack,"",@progbits
