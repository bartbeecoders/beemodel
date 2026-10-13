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
.equ NTYPES,    9
.equ IR_NAME,   0

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
ne_kind_col:    .long COL_NE_SOCK_G, COL_NE_SOCK_V, COL_NE_SOCK_N, COL_NE_SOCK_C
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
s_op_socket:    .asciz "material.socket"
s_op_node:      .asciz "material.node"
s_op_delete:    .asciz "material.node_delete"
s_op_set:       .asciz "material.node_set"
s_undo_move:    .asciz "Move Node"
s_undo_value:   .asciz "Change Node Value"
s_none_w:       .asciz "none"
# display names by type (1..9) and the output's sockets
.align 8
ne_titles:      .quad 0, t_image, t_noise, t_checker, t_grad, t_mix, t_ramp, t_math, t_bump, t_nmap
t_image:        .asciz "Image Texture"
t_noise:        .asciz "Noise Texture"
t_checker:      .asciz "Checker Texture"
t_grad:         .asciz "Gradient Texture"
t_mix:          .asciz "Mix"
t_ramp:         .asciz "Color Ramp"
t_math:         .asciz "Math"
t_bump:         .asciz "Bump"
t_nmap:         .asciz "Normal Map"
ne_out_names:   .quad o_base, o_metal, o_rough, o_emit, o_normal
o_base:         .asciz "Base Color"
o_metal:        .asciz "Metallic"
o_rough:        .asciz "Roughness"
o_emit:         .asciz "Emission"
o_normal:       .asciz "Normal"
# per type (as geonodes.s's gn_meta): input names (3), input kinds (0
#   geometry, 1 value, 2 vector, 3 colour), value names (4), value kinds (0
#   number, 1 choice, 2 image, 3 whole number), the choices, output names
#   (3), output kinds
ne_meta:        .quad 0, 0, 0, 0, 0, 0, 0
                .quad in_image, ik_vec1, pn_image, pk_image, 0, so_color, sk_col
                .quad in_noise, ik_vec1, pn_noise, pk_noise, 0, so_color, sk_col
                .quad in_checker, ik_col2, pn_scale, pk_num1, 0, so_color, sk_col
                .quad in_none, ik_vec1, pn_grad, pk_grad, ch_axis, so_color, sk_col
                .quad in_mix, ik_mix, pn_mode, pk_choice, ch_mix, so_color, sk_col
                .quad in_ramp, ik_mix, pn_ramp, pk_num2, 0, so_color, sk_col
                .quad in_math, ik_val2, pn_op, pk_choice, ch_math, so_value, sk_val
                .quad in_bump, ik_val2, pn_bump, pk_num2, 0, so_normal, sk_vec
                .quad in_nmap, ik_col2, pn_strength, pk_num1, 0, so_normal, sk_vec
so_color:       .quad s_ne_color, 0, 0
so_value:       .quad s_ne_value, 0, 0
so_normal:      .quad s_ne_normal, 0, 0
sk_col:         .byte 3, 0, 0, 0
sk_val:         .byte 1, 0, 0, 0
sk_vec:         .byte 2, 0, 0, 0
in_none:        .quad 0, 0, 0
in_image:       .quad i_vector, 0, 0
in_noise:       .quad i_offset, 0, 0
in_checker:     .quad i_color1, i_color2, 0
in_mix:         .quad i_factor, i_color1, i_color2
in_ramp:        .quad i_factor, i_color0, i_color1
in_math:        .quad i_value1, i_value2, 0
in_bump:        .quad i_height, 0, 0
in_nmap:        .quad i_color, 0, 0
ik_vec1:        .byte 2, 2, 2
ik_col2:        .byte 3, 3, 3
ik_mix:         .byte 1, 3, 3
ik_val2:        .byte 1, 1, 1
pn_image:       .quad p_image, p_size, 0, 0
pn_noise:       .quad p_scale, p_detail, p_rough, 0
pn_scale:       .quad p_scale, 0, 0, 0
pn_grad:        .quad p_axis, p_scale, p_offset, 0
pn_mode:        .quad p_mode, 0, 0, 0
pn_ramp:        .quad p_pos0, p_pos1, 0, 0
pn_op:          .quad p_op, 0, 0, 0
pn_bump:        .quad p_strength, p_distance, 0, 0
pn_strength:    .quad p_strength, 0, 0, 0
pk_image:       .byte 2, 0, 0, 0
pk_noise:       .byte 0, 3, 0, 0
pk_num1:        .byte 0, 0, 0, 0
pk_num2:        .byte 0, 0, 0, 0
pk_grad:        .byte 1, 0, 0, 0
pk_choice:      .byte 1, 0, 0, 0
.align 8
ch_axis:        .quad 3, c_x, c_y, c_z
ch_mix:         .quad 5, c_mix, c_add, c_mul, c_sub, c_screen
ch_math:        .quad 10, c_add, c_sub, c_mul, c_div, c_pow, c_min, c_max, c_gt, c_sin, c_abs
i_vector:       .asciz "Vector"
i_offset:       .asciz "Offset"
i_color:        .asciz "Color"
i_color0:       .asciz "Color 0"
i_color1:       .asciz "Color 1"
i_color2:       .asciz "Color 2"
i_factor:       .asciz "Factor"
i_value1:       .asciz "Value 1"
i_value2:       .asciz "Value 2"
i_height:       .asciz "Height"
p_image:        .asciz "Image"
p_size:         .asciz "Size"
p_scale:        .asciz "Scale"
p_detail:       .asciz "Detail"
p_rough:        .asciz "Roughness"
p_axis:         .asciz "Axis"
p_offset:       .asciz "Offset"
p_mode:         .asciz "Mode"
p_pos0:         .asciz "Position 0"
p_pos1:         .asciz "Position 1"
p_op:           .asciz "Operation"
p_strength:     .asciz "Strength"
p_distance:     .asciz "Distance"
c_x:            .asciz "X"
c_y:            .asciz "Y"
c_z:            .asciz "Z"
c_mix:          .asciz "Mix"
c_add:          .asciz "Add"
c_mul:          .asciz "Multiply"
c_sub:          .asciz "Subtract"
c_screen:       .asciz "Screen"
c_div:          .asciz "Divide"
c_pow:          .asciz "Power"
c_min:          .asciz "Minimum"
c_max:          .asciz "Maximum"
c_gt:           .asciz "Greater Than"
c_sin:          .asciz "Sine"
c_abs:          .asciz "Absolute"

.section .bss
.align 8
ne_panx:        .skip 4                 # the view: where graph (0, 0) is
ne_pany:        .skip 4                 #  (from the body's top left)
ne_mat:         .skip 4                 # the material shown (-1: none)
ne_n:           .skip 4                 # its nodes when drawn
ne_lx:          .skip 4*49              # their boxes on screen (0: the output)
ne_ly:          .skip 4*49
ne_lh:          .skip 4*49
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
ne_x0:          .skip 4                 # the press
ne_y0:          .skip 4
ne_a0:          .skip 4                 # what was there: x / y / pan / value
ne_b0:          .skip 4
ne_undone:      .skip 4                 # the drag has its undo step
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
OPERATOR op_ne_fit,    "node.view_fit", "Fit Node View", do_ne_fit, key=KEY_HOME, flags=OPF_AI_SAFE|OPF_QUIET|OPF_NODE, doc="Node editor: every node in view"

# ne_rec -> rax = the record shown (0: none): the active object's geometry
#   node tree (its first Geometry Nodes modifier's) unless the material is
#   asked for (Tab), else its material's graph; ne_kind, ne_mat (the tree or
#   material index), ne_maxn set
ne_rec:
    push    rbx
    mov     dword ptr [rip+ne_mat], -1
    mov     dword ptr [rip+ne_kind], 0
    mov     dword ptr [rip+ne_maxn], 12
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
    mov     rdx, [rbx+OB_MODS]          # a Geometry Nodes modifier with a tree
    test    rdx, rdx
    jz      3f
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
    mov     eax, NTYPES
    cmp     dword ptr [rip+ne_kind], 0
    je      1f
    mov     eax, [rip+gn_ntypes]
1:  ret

# ne_title(edi=type) -> rax = its name
ne_title:
    lea     rax, [rip+ne_titles]
    cmp     dword ptr [rip+ne_kind], 0
    je      1f
    lea     rax, [rip+gn_titles]
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
    lea     rcx, [rip+ne_meta]
    cmp     dword ptr [rip+ne_kind], 0
    je      1f
    lea     rcx, [rip+gn_meta]
1:  add     rax, rcx
9:  ret

# ne_nouts(edi=type) -> eax = its outputs
ne_nouts:
    call    ne_meta_of
    test    rax, rax
    jz      8f
    mov     rcx, [rax+40]
    xor     eax, eax
1:  cmp     eax, 3
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
    lea     r8, [rip+ne_lh]
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
6:  mov     dword ptr [rip+ne_lh], NHDR+5*NROW+6   # the material output
    cmp     dword ptr [rip+ne_kind], 0
    je      61f
    mov     dword ptr [rip+ne_lh], 0    # (trees: none)
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
7:  xor     ecx, ecx                    # on screen
8:  cmp     ecx, r12d
    ja      9f
    lea     r8, [rip+ne_gx]
    mov     eax, [r8+rcx*4]
    add     eax, [rip+ne_bx]
    add     eax, [rip+ne_panx]
    lea     r8, [rip+ne_lx]
    mov     [r8+rcx*4], eax
    lea     r8, [rip+ne_gy]
    mov     eax, [r8+rcx*4]
    add     eax, [rip+ne_by]
    add     eax, [rip+ne_pany]
    lea     r8, [rip+ne_ly]
    mov     [r8+rcx*4], eax
    inc     ecx
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
    add     eax, NW
    lea     r8, [rip+ne_ly]
    mov     edx, [r8+rdi*4]
    add     edx, NHDR+NROW/2
    imul    esi, esi, NROW
    add     edx, esi
    ret

# ne_in_xy(rbx=record, edi=node (0: the output), esi=input k / socket) ->
#   eax, edx = that input socket on screen
ne_in_xy:
    lea     r8, [rip+ne_lx]
    mov     eax, [r8+rdi*4]
    lea     r8, [rip+ne_ly]
    mov     edx, [r8+rdi*4]
    add     edx, NHDR+NROW/2
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
1:  imul    esi, esi, NROW
    add     edx, esi
    ret

# ne_wire(edi, esi = from, edx, ecx = to, r8d = colour) - a curve
ne_wire:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    push    rbp
    sub     rsp, 56
    mov     [rsp], edi
    mov     [rsp+4], esi
    mov     [rsp+8], edx
    mov     [rsp+12], ecx
    mov     [rsp+16], r8d
    mov     eax, edx                    # handle length: max(40, |dx| / 2)
    sub     eax, edi
    cdq
    xor     eax, edx
    sub     eax, edx
    shr     eax, 1
    cmp     eax, 40
    jge     1f
    mov     eax, 40
1:  mov     [rsp+20], eax
    mov     r12d, [rsp]                 # previous point
    mov     r13d, [rsp+4]
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
    cvtss2si r14d, xmm8
    cvtss2si r15d, xmm9
    mov     edi, r12d
    mov     esi, r13d
    mov     edx, r14d
    mov     ecx, r15d
    mov     r8d, [rsp+16]
    call    draw_line
    mov     r12d, r14d
    mov     r13d, r15d
    inc     ebx
    jmp     2b
9:  add     rsp, 56
    pop     rbp
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# ne_sock(edi=x, esi=y, edx=colour) - a socket
ne_sock:
    sub     rsp, 8
    mov     r8d, edx
    sub     edi, NSOCK_R
    sub     esi, NSOCK_R
    mov     edx, 2*NSOCK_R+1
    mov     ecx, 2*NSOCK_R+1
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
    cmp     ecx, 2
    je      2f
    cmp     ecx, 4
    je      4f
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
1:  cvtss2si eax, xmm0              # a choice
    mov     rcx, [r14+32]
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
    mov     eax, [rip+ne_panx]
    cdq
    mov     ecx, 40
    idiv    ecx
    add     edx, 40
    mov     r12d, edx                   # first column offset
    mov     eax, [rip+ne_pany]
    cdq
    idiv    ecx
    add     edx, 40
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
    add     r14d, 40
    jmp     2b
21: add     ebx, 40
    jmp     1b
3:  call    ne_rec
    test    rax, rax
    jz      .Lnd_none
    mov     rbx, rax
    mov     rdi, rbx
    call    ne_layout
    # header line: the material or tree, the keys
    mov     edi, [rip+ed_x]
    add     edi, 8
    mov     esi, [rip+ed_y]
    add     esi, 3
    lea     rdx, [rip+s_ne_head]
    cmp     dword ptr [rip+ne_kind], 0
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
    mov     edi, r15d
    mov     esi, ecx
    call    ne_out_xy
    mov     [rsp], eax
    mov     [rsp+4], edx
    mov     edi, r12d
    mov     esi, r14d
    call    ne_in_xy
    mov     edi, [rsp]
    mov     esi, [rsp+4]
    mov     ecx, edx
    mov     edx, eax
    mov     r8d, COL_NE_WIRE
    call    ne_wire
43: inc     r14d
    jmp     41b
44: inc     r12d
    jmp     4b
45: xor     r14d, r14d
    cmp     dword ptr [rip+ne_kind], 0  # (trees: no material sockets)
    jne     5f
46: cmp     r14d, 5
    jae     5f
    mov     r15d, [rbx+GR_SOCK+r14*4]
    test    r15d, r15d
    jz      47f
    cmp     r15d, [rip+ne_n]
    ja      47f
    mov     edi, r15d
    xor     esi, esi
    call    ne_out_xy
    mov     [rsp], eax
    mov     [rsp+4], edx
    xor     edi, edi
    mov     esi, r14d
    call    ne_in_xy
    mov     edi, [rsp]
    mov     esi, [rsp+4]
    mov     ecx, edx
    mov     edx, eax
    mov     r8d, COL_NE_WIRE
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
69: cmp     dword ptr [rip+ne_menu], 0
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
    mov     edx, NW+2
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
    mov     edx, NW
    lea     r8, [rip+ne_lh]
    mov     ecx, [r8+rbx*4]
    mov     r8d, COL_NE_BODY
    call    fill_rect
    lea     r8, [rip+ne_lx]
    mov     edi, [r8+rbx*4]
    lea     r8, [rip+ne_ly]
    mov     esi, [r8+rbx*4]
    mov     edx, NW
    mov     ecx, NHDR
    mov     r8d, r12d
    call    fill_rect
    lea     r8, [rip+ne_lx]
    mov     edi, [r8+rbx*4]
    add     edi, 6
    lea     r8, [rip+ne_ly]
    mov     esi, [r8+rbx*4]
    add     esi, 3
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
    mov     esi, COL_NE_GRP             # (trees: groups, group in / out,
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
11: mov     esi, COL_NE_TEX
    cmp     ecx, 5
    jb      1f
    mov     esi, COL_NE_CONV
    cmp     ecx, 8
    jb      1f
    mov     esi, COL_NE_VEC
1:  mov     [rsp+24], esi
    mov     edi, ecx
    call    ne_title
    mov     rdx, rax
    mov     edi, r12d
    mov     esi, [rsp+24]
    call    ne_box
    lea     r8, [rip+ne_lx]
    mov     eax, [r8+r12*4]
    mov     [rsp+8], eax                # x
    lea     r8, [rip+ne_ly]
    mov     eax, [r8+r12*4]
    add     eax, NHDR
    mov     [rsp+12], eax               # row 0's top
    # the outputs
    xor     r15d, r15d
5:  cmp     r15d, [rsp+20]
    jae     6f
    imul    edx, r15d, NROW
    add     edx, [rsp+12]
    add     edx, 2
    mov     esi, [rsp+8]
    add     esi, NW-10
    mov     rax, [r14+40]
    mov     rdi, [rax+r15*8]
    mov     ecx, COL_TEXT
    call    ne_right_text
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
    imul    eax, eax, NROW
    add     eax, [rsp+12]
    mov     [rsp+16], eax
    mov     edi, [rsp+8]                # a field behind it
    add     edi, 6
    mov     esi, eax
    add     esi, 1
    mov     edx, NW-12
    mov     ecx, NROW-2
    mov     r8d, COL_FIELD
    call    fill_rect
    mov     rax, [r14+16]
    mov     rdx, [rax+r15*8]
    mov     edi, [rsp+8]
    add     edi, 10
    mov     esi, [rsp+16]
    add     esi, 2
    mov     ecx, COL_TEXT_DIM
    call    draw_text
    mov     edi, r12d
    mov     esi, r15d
    call    ne_value_text
    mov     rdi, rax
    mov     esi, [rsp+8]
    add     esi, NW-10
    mov     edx, [rsp+16]
    add     edx, 2
    mov     ecx, COL_TEXT
    call    ne_right_text
    inc     r15d
    jmp     2b
    # the inputs
3:  xor     r15d, r15d
4:  cmp     r15d, [rsp]
    jae     .Ldn_out
    mov     eax, [rsp+4]
    add     eax, [rsp+20]
    add     eax, r15d
    imul    eax, eax, NROW
    add     eax, [rsp+12]
    mov     [rsp+16], eax
    mov     rax, [r14+8]                # socket colour by kind
    movzx   ebp, byte ptr [rax+r15]
    lea     rax, [rip+ne_kind_col]
    mov     edx, [rax+rbp*4]
    mov     edi, [rsp+8]
    mov     esi, [rsp+16]
    add     esi, NROW/2
    call    ne_sock
    mov     rax, [r14]
    mov     rdx, [rax+r15*8]
    mov     edi, [rsp+8]
    add     edi, 10
    mov     esi, [rsp+16]
    add     esi, 2
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
    add     edi, NW-34
    mov     esi, [rsp+16]
    add     esi, 4
    mov     edx, 24
    mov     ecx, NROW-8
    call    fill_rect
    jmp     49f
45: movss   xmm0, [r13+ND_IN+rax+4]     # a value: the number
    call    ne_fmt_num
    lea     rdi, [rip+fmt_buf]
    mov     esi, [rsp+8]
    add     esi, NW-10
    mov     edx, [rsp+16]
    add     edx, 2
    mov     ecx, COL_TEXT_DIM
    call    ne_right_text
    jmp     49f
46: cmp     dword ptr [rip+ne_kind], 0  # a vector (trees): x y z
    je      49f
    lea     rdi, [rip+s_ne_implicit]    # (noise unlinked: the position)
    cmp     dword ptr [r13+ND_TYPE], 24
    jne     47f
    test    r15d, r15d
    jz      48f
47: lea     rsi, [r13+ND_IN+rax+4]
    call    ne_fmt_vec
    lea     rdi, [rip+fmt_buf]
48:
    mov     esi, [rsp+8]
    add     esi, NW-10
    mov     edx, [rsp+16]
    add     edx, 2
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
1:  cmp     r12d, 5
    jae     9f
    xor     edi, edi
    mov     esi, r12d
    call    ne_in_xy
    mov     r13d, eax
    mov     r14d, edx
    mov     edi, eax
    mov     esi, edx
    mov     edx, COL_NE_SOCK_C
    cmp     r12d, 4
    jne     2f
    mov     edx, COL_NE_SOCK_N
2:  cmp     r12d, 1
    je      21f
    cmp     r12d, 2
    jne     22f
21: mov     edx, COL_NE_SOCK_V
22: call    ne_sock
    lea     rax, [rip+ne_out_names]
    mov     rdx, [rax+r12*8]
    lea     edi, [r13+10]
    lea     esi, [r14-NROW/2+2]
    mov     ecx, COL_TEXT
    call    draw_text
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
    mov     ecx, COL_TEXT_DIM
    call    draw_text
    call    ne_menu_item                # (the one under the pointer)
    mov     r13d, eax
    call    ne_ntypes
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
    cmp     ebx, r13d
    jne     2f
    mov     edi, r15d
    mov     esi, r12d
    mov     edx, MENU_W
    mov     ecx, NROW
    mov     r8d, COL_HOVER
    call    fill_rect
2:  mov     edi, ebx
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
    call    ne_ntypes
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
    call    ne_ntypes                   # (past the last: none)
    cmp     ebx, eax
    ja      8f
    mov     eax, ebx
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
31: cmp     r15d, 5
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
    cmp     eax, NHDR
    jae     43f
    mov     eax, 1
    mov     edx, r14d
    jmp     .Lnh_out
43: test    r14d, r14d
    jz      48f
    sub     eax, NHDR
    xor     edx, edx
    mov     ecx, NROW
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
    cmp     eax, NW
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
    jz      .Lnp_pan
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
    mov     dword ptr [rip+ne_drag], 2
    jmp     .Lnp_taken
21: mov     dword ptr [rip+ne_drag], 3
    jmp     .Lnp_taken
3:  cmp     eax, 4
    jne     4f
    call    ne_rec                      # a material socket: picked up too
    mov     ecx, [rip+ne_dk]
    mov     r14d, [rax+GR_SOCK+rcx*4]
    test    r14d, r14d
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
    mov     [rip+ne_dn], r14d
    mov     dword ptr [rip+ne_dk], 0
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
6:  mov     dword ptr [rip+ne_drag], 1  # the header or body: moved
    mov     ecx, [rip+ne_dn]
    lea     r8, [rip+ne_gx]
    mov     eax, [r8+rcx*4]
    mov     [rip+ne_a0], eax
    lea     r8, [rip+ne_gy]
    mov     eax, [r8+rcx*4]
    mov     [rip+ne_b0], eax
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
ne_out_sock:    .quad sk_base, sk_metal, sk_rough, sk_emit, sk_normal
sk_base:        .asciz "base"
sk_metal:       .asciz "metallic"
sk_rough:       .asciz "roughness"
sk_emit:        .asciz "emission"
sk_normal:      .asciz "normal"
.text

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
2:  cmp     eax, 1
    jne     3f
    call    ne_first_change             # move: its place in the record
    mov     edi, [rip+ne_mat]
    mov     esi, [rip+ne_dn]
    mov     edx, r12d
    sub     edx, [rip+ne_x0]
    add     edx, [rip+ne_a0]
    mov     ecx, r13d
    sub     ecx, [rip+ne_y0]
    add     ecx, [rip+ne_b0]
    call    ne_place
    jmp     .Lnm_yes
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

# ne_first_change - the drag's undo step, once
ne_first_change:
    cmp     dword ptr [rip+ne_undone], 0
    jne     9f
    mov     dword ptr [rip+ne_undone], 1
    sub     rsp, 8
    lea     rdi, [rip+s_undo_value]
    cmp     dword ptr [rip+ne_drag], 1
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
    cmp     r13d, 1
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
    jmp     9f
.Lnr_from_out:                          # onto an input or a material socket
    mov     edi, r12d
    mov     esi, r13d
    call    ne_hit
    cmp     eax, 3
    je      1f
    cmp     eax, 6                      # (an input's row will do)
    je      1f
    cmp     eax, 4
    jne     9f
    mov     edi, [rip+ne_dn]            # material.socket
    mov     esi, ecx
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
    cmp     eax, 2
    jne     9f
    mov     edi, edx
    mov     esi, [rip+ne_dk]
    call    ne_socket
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
    call    ne_arg_done
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
    sub     rsp, 8
    mov     ebx, edi
    mov     r12d, esi
    call    ne_arg_start
    lea     rax, [rip+ne_out_sock]
    mov     rdi, [rax+r12*8]
    call    fmt_str
    mov     edi, ' '
    call    fmt_char
    mov     edi, ebx
    call    fmt_int
    call    ne_arg_done
    lea     rdi, [rip+s_op_socket]
    call    ne_run
    add     rsp, 8
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
    call    ne_run2
    call    ne_rec                      # added: placed at the menu
    test    rax, rax
    jz      9f
    cmp     [rax+GR_N], r12d
    jbe     9f
    inc     r12d
    mov     [rip+ne_sel], r12d
    mov     edi, [rip+ne_mat]
    mov     esi, r12d
    mov     edx, [rip+ne_mx]
    sub     edx, [rip+ne_bx]
    sub     edx, [rip+ne_panx]
    mov     ecx, [rip+ne_my]
    sub     ecx, [rip+ne_by]
    sub     ecx, [rip+ne_pany]
    call    ne_place
9:  add     rsp, 8
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
    cmp     dword ptr [rip+ne_kind], 0
    je      2f
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
    imul    edi, edi, 40
    add     [rip+ne_pany], edi
    mov     dword ptr [rip+dirty], 1
    ret

# nodeed_key(edi = evdev) -> eax = 1 (the open menu takes every key: Esc
#   closes it)
nodeed_key:
    cmp     edi, KEY_ESC
    jne     1f
    mov     dword ptr [rip+ne_menu], 0
1:  mov     dword ptr [rip+dirty], 1
    mov     eax, 1
    ret

do_ne_add_menu:
    sub     rsp, 8
    call    ne_rec
    test    rax, rax
    jz      9f
    mov     dword ptr [rip+ne_menu], 1
    mov     eax, [rip+ptr_x]
    mov     [rip+ne_mx], eax
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
1:  bsr     r12, rbx
    jz      8f
    btr     rbx, r12
    test    r12d, r12d
    jz      8f
    call    ne_rec
    test    rax, rax
    jz      8f
    cmp     r12d, [rax+GR_N]
    ja      1b
    call    ne_arg_start
    mov     edi, r12d
    call    fmt_int
    call    ne_arg_done
    lea     rdi, [rip+s_op_delete]
    lea     rsi, [rip+s_tp_delete]
    call    ne_run2
    jmp     1b
8:  mov     dword ptr [rip+ne_sel], 0
    mov     qword ptr [rip+ne_selm], 0
9:  add     rsp, 8
    pop     r12
    pop     rbx
    ret

# node.group (Ctrl+G) - tree.group with the selection
do_ne_group:
    push    rbx
    push    r12
    sub     rsp, 8
    call    ne_rec
    test    rax, rax
    jz      9f
    cmp     dword ptr [rip+ne_kind], 0
    je      9f
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
    push    rbx
    push    r12
    push    r13
    call    ne_rec
    test    rax, rax
    jz      9f
    mov     rdi, rax
    call    ne_layout
    mov     r12d, 0x7fffffff            # the smallest graph x, y
    mov     r13d, 0x7fffffff
    xor     ecx, ecx
    cmp     dword ptr [rip+ne_kind], 0  # (trees: no output node)
    je      1f
    inc     ecx
1:  cmp     ecx, [rip+ne_n]
    ja      2f
    lea     r8, [rip+ne_gx]
    mov     eax, [r8+rcx*4]
    cmp     eax, r12d
    cmovl   r12d, eax
    lea     r8, [rip+ne_gy]
    mov     eax, [r8+rcx*4]
    cmp     eax, r13d
    cmovl   r13d, eax
    inc     ecx
    jmp     1b
2:  mov     eax, 20
    sub     eax, r12d
    mov     [rip+ne_panx], eax
    mov     eax, 20
    sub     eax, r13d
    mov     [rip+ne_pany], eax
    mov     dword ptr [rip+dirty], 1
9:  pop     r13
    pop     r12
    pop     rbx
    ret

.section .note.GNU-stack,"",@progbits
