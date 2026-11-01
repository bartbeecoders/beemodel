# =============================================================================
#  BeeModel - Blender files (.blend): shader node trees into material graphs
#
#  blend.s reads a material's Principled BSDF: its values, and an Image
#  Texture node straight on Base Color, Emission or a Normal Map. What
#  feeds Base Color, Metallic, Roughness or Emission Color through other
#  nodes comes here and becomes the material's own node graph (graph.s,
#  matnodes.s), made from the BSDF back, each Blender node once:
#
#    Texture Coordinate  UV; Generated, Object and Normal as Position or
#                        Normal turned to Blender's axes (Generated: the
#                        first mesh's bounds, Blender's auto texture space)
#    Mapping             point, texture and vector, folded with what feeds
#                        it into one affine map, made into nodes (three dot
#                        products, a combine, an add) only where a node
#                        takes the vector whole
#    Gradient            linear, quadratic, easing, diagonal, spherical,
#                        quadratic sphere, radial: from the vector's parts
#    Color Ramp          a chain of two-stop ramps (ease, B-spline and
#                        cardinal as linear; constant as steps)
#    Mix, MixRGB         colours (mix, add, multiply, subtract, screen,
#                        divide, difference, darken, lighten, overlay, soft
#                        light; the other modes as mix) and floats
#    Math                most operations, and its clamp
#    Voronoi             F1, F2, smooth F1 (as F1), distance to edge
#    Image Texture, Hue/Saturation/Value, Invert, RGB, Value, Reroute; a
#    node group passes its first linked input through
#
#  Anything else, or more than the graph's 48 nodes, leaves that input as
#  blend.s set it: the socket's own value.
# =============================================================================
.intel_syntax noprefix
.include "const.inc"

.globl bn_build

.equ GR_N,      128
.equ GR_NODES,  160
.equ NODE_SZ,   72
.equ ND_IN,     4
.equ BP_NMEMO,  64
.equ VEC_M,     8                       # a vector: u32 base (a node output),
.equ VEC_SZ,    136                     #  then a 4x4 map (doubles, row-major)

# graph node types (matnodes.s: graph_type_names, from 1)
.equ T_IMAGE,   1
.equ T_MIX,     5
.equ T_RAMP,    6
.equ T_MATH,    7
.equ T_TEXCO,   10
.equ T_POS,     11
.equ T_NORMAL,  12
.equ T_CONST,   16
.equ T_COLOR,   17
.equ T_VMATH,   19
.equ T_COMBINE, 21
.equ T_VORONOI, 25
.equ T_HSV,     26
.equ T_INVERT,  27
# math_op
.equ MO_ADD,    0
.equ MO_MUL,    2
.equ MO_MAX,    6
.equ MO_OMIN,   18
.equ MO_SAT,    19
.equ MO_SSTEP,  23
.equ MO_ATAN2,  27
.equ MO_MADD,   30
# vector math
.equ VM_ADD,    0
.equ VM_DOT,    10
.equ VM_LEN,    13

# the fields read here (blend.s resolves them with its own)
.macro BF var, st, path
    .pushsection .rodata
.Lbs\@: .asciz "\st"
.Lbp\@: .asciz "\path"
    .popsection
    .pushsection blend_f, "a"
    .balign 8
    .quad \var, .Lbs\@, .Lbp\@
    .popsection
    .pushsection .bss
    .balign 4
\var: .skip 4
    .popsection
.endm

BF p_nd_storage, "bNode", "storage"
BF p_nd_c1,     "bNode", "custom1"
BF p_nd_c2,     "bNode", "custom2"
BF p_nl_fromsock, "bNodeLink", "fromsock"
BF p_cb_tot,    "ColorBand", "tot"
BF p_cb_ipo,    "ColorBand", "ipotype"
BF p_cb_data,   "ColorBand", "data"
BF p_cbd_r,     "CBData", "r"
BF p_cbd_pos,   "CBData", "pos"
BF p_cbd_sz,    "CBData", ""
BF p_grad_type, "NodeTexGradient", "gradient_type"
BF p_vor_feat,  "NodeTexVoronoi", "feature"
BF p_mix_dtype, "NodeShaderMix", "data_type"
BF p_mix_blend, "NodeShaderMix", "blend_type"
BF p_svv_value, "bNodeSocketValueVector", "value"

.section .rodata
.align 8
bn_kinds:       .quad s_grad, bn_h_grad
                .quad s_ramp, bn_h_ramp
                .quad s_mixrgb, bn_h_mixrgb
                .quad s_mix, bn_h_mix
                .quad s_math, bn_h_math
                .quad s_voronoi, bn_h_voronoi
                .quad s_image, bn_h_image
                .quad s_hsv, bn_h_hsv
                .quad s_invert, bn_h_invert
                .quad s_rgb, bn_h_rgb
                .quad s_value, bn_h_value
                .quad s_texco, bn_h_vec
                .quad s_mapping, bn_h_vec
                .quad s_reroute, bn_h_pass
                .quad s_group, bn_h_pass
                .quad 0, 0
# the BSDF's inputs made into graphs: name, other name, pin
bn_pins:        .quad k_base, 0
                .long PIN_BASE, 0
                .quad k_metal, 0
                .long PIN_METAL, 0
                .quad k_rough, 0
                .long PIN_ROUGH, 0
                .quad k_emcol, k_emis
                .long PIN_EMIT, 0
                .quad 0
# Blender's blend types (MA_RAMP_*) -> the Mix node's modes
bn_blendmap:    .byte 0, 1, 2, 3, 4, 10, 8, 6, 7, 5, 0, 0, 0, 0, 0, 0, 9, 0, 0, 0
# Blender's math operations (NODE_MATH_*) -> math_op (255: none)
bn_mathmap:     .byte 0, 1, 2, 3, 8, 10, 11, 255, 255, 255, 4, 255, 5, 6, 16, 28
                .byte 7, 24, 9, 27, 13, 14, 15, 12, 255, 17, 25, 255, 255, 255
                .byte 255, 255, 255, 255, 255, 255, 30, 255, 255, 255, 255
.equ BP_NMATH, . - bn_mathmap
# Mix / MixRGB / Math inputs: name, kind (0 colour, 1 float, 2 vector; +256
#   a value only, never linked)
bn_in_mixrgb:   .quad k_fac, 1, k_col1, 0, k_col2, 0
bn_in_mixc:     .quad k_ffloat, 1, k_acol, 0, k_bcol, 0
bn_in_mixf:     .quad k_ffloat, 1, k_afloat, 1, k_bfloat, 1
bn_in_math:     .quad k_value, 1, k_value1, 1, k_value2, 1
bn_in_hsv:      .quad k_color, 0, 0, 0, 0, 0
bn_in_ramp:     .quad k_fac, 1, 0, 0, 0, 0
s_grad:         .asciz "ShaderNodeTexGradient"
s_ramp:         .asciz "ShaderNodeValToRGB"
s_mixrgb:       .asciz "ShaderNodeMixRGB"
s_mix:          .asciz "ShaderNodeMix"
s_math:         .asciz "ShaderNodeMath"
s_voronoi:      .asciz "ShaderNodeTexVoronoi"
s_image:        .asciz "ShaderNodeTexImage"
s_hsv:          .asciz "ShaderNodeHueSaturation"
s_invert:       .asciz "ShaderNodeInvert"
s_rgb:          .asciz "ShaderNodeRGB"
s_value:        .asciz "ShaderNodeValue"
s_texco:        .asciz "ShaderNodeTexCoord"
s_mapping:      .asciz "ShaderNodeMapping"
s_reroute:      .asciz "NodeReroute"
s_group:        .asciz "ShaderNodeGroup"
k_base:         .asciz "Base Color"
k_metal:        .asciz "Metallic"
k_rough:        .asciz "Roughness"
k_emcol:        .asciz "Emission Color"
k_emis:         .asciz "Emission"
k_fac:          .asciz "Fac"
k_ffloat:       .asciz "Factor_Float"
k_col1:         .asciz "Color1"
k_col2:         .asciz "Color2"
k_acol:         .asciz "A_Color"
k_bcol:         .asciz "B_Color"
k_afloat:       .asciz "A_Float"
k_bfloat:       .asciz "B_Float"
k_value:        .asciz "Value"
k_value1:       .asciz "Value_001"
k_value2:       .asciz "Value_002"
k_color:        .asciz "Color"
k_vector:       .asciz "Vector"
k_input:        .asciz "Input"
k_hue:          .asciz "Hue"
k_sat:          .asciz "Saturation"
k_scale:        .asciz "Scale"
k_random:       .asciz "Randomness"
k_loc:          .asciz "Location"
k_rot:          .asciz "Rotation"
k_uv:           .asciz "UV"
k_gen:          .asciz "Generated"
k_object:       .asciz "Object"
k_normal:       .asciz "Normal"
k_distance:     .asciz "Distance"
k_alpha:        .asciz "Alpha"
.align 4
bf_half:        .float 0.5
bf_one:         .float 1.0
bf_step:        .float 1.0e-5               # a constant ramp's step
bf_inv2pi:      .float 0.15915494
.align 8
bd_half:        .double 0.5
bd_one:         .double 1.0
bd_zero:        .double 0.0

.section .bss
.align 8
bn_tree:        .skip 8
bn_mat:         .skip 4
bn_depth:       .skip 4
bn_nmemo:       .skip 4
.align 8
bn_memo:        .skip 16*BP_NMEMO           # key (an output's old address,
                                            #  or 1..3: our own inputs), ref
bn_gen:         .skip 128                   # Position -> Generated
bn_ycol:        .skip 4*16                  # the node editor: next y a column
bn_lo:          .skip 12                    # the first mesh's bounds
bn_hi:          .skip 12

.text
# =============================================================================
# bn_build(edi=material, rsi=node tree, rdx=Principled BSDF node, ecx=pins
#   blend.s made already (bit per PIN_*)) - a graph for each BSDF input fed
#   through nodes; an input whose nodes cannot all be made keeps its value
# =============================================================================
bn_build:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    sub     rsp, 16
    mov     [rip+bn_mat], edi
    mov     [rip+bn_tree], rsi
    mov     r13, rdx
    mov     [rsp+8], ecx
    mov     dword ptr [rip+bn_nmemo], 0
    mov     dword ptr [rip+bn_depth], 0
    lea     rdi, [rip+bn_ycol]
    mov     eax, 20
    mov     ecx, 16
    rep     stosd
    call    bn_bounds
    lea     r12, [rip+bn_pins]
1:  mov     rsi, [r12]
    test    rsi, rsi
    jz      9f
    mov     ecx, [r12+16]               # made by blend.s (an image)?
    mov     eax, [rsp+8]
    bt      eax, ecx
    jc      8f
    mov     r14, r13
    call    bl_sock
    cmp     qword ptr [rip+bl_sockold], 0
    jne     2f
    mov     rsi, [r12+8]                # (Blender 3: "Emission")
    test    rsi, rsi
    jz      8f
    call    bl_sock
2:  mov     rsi, [rip+bl_sockold]
    call    bn_link
    test    rax, rax
    jz      8f
    mov     rbx, rax
    mov     edi, [rip+bn_mat]           # the nodes so far (to drop ours on
    call    graph_own                   #  failure)
    test    rax, rax
    jz      9f
    mov     eax, [rax+GR_N]
    mov     [rsp], eax
    mov     rax, rbx
    call    bn_link_ref
    test    eax, eax
    jz      7f
    mov     edx, eax
    and     edx, 0xffff
    mov     ecx, eax
    shr     ecx, 16
    mov     esi, [r12+16]
    mov     edi, [rip+bn_mat]
    call    graph_socket
    jmp     8f
7:  mov     edi, [rip+bn_mat]
    call    graph_own
    test    rax, rax
    jz      9f
    mov     ecx, [rsp]
    mov     [rax+GR_N], ecx
    mov     edi, ecx
    call    bn_memo_drop
8:  add     r12, 24
    jmp     1b
9:  add     rsp, 16
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# bn_bounds - bn_lo / bn_hi: the mesh being read (bm_pos, Blender's axes);
#   bn_gen: Position (our axes) -> Generated, as Blender's auto texture space
bn_bounds:
    sub     rsp, 264
    mov     ecx, [rip+bm_nv]
    mov     rsi, [rip+bm_pos]
    xorps   xmm0, xmm0
    movss   [rip+bn_lo], xmm0
    movss   [rip+bn_lo+4], xmm0
    movss   [rip+bn_lo+8], xmm0
    movss   [rip+bn_hi], xmm0
    movss   [rip+bn_hi+4], xmm0
    movss   [rip+bn_hi+8], xmm0
    test    ecx, ecx
    jz      3f
    test    rsi, rsi
    jz      3f
    xor     edx, edx
1:  movss   xmm0, [rsi+rdx*4]
    lea     rax, [rip+bn_lo]
    movss   [rax+rdx*4], xmm0
    lea     rax, [rip+bn_hi]
    movss   [rax+rdx*4], xmm0
    inc     edx
    cmp     edx, 3
    jb      1b
2:  xor     edx, edx
21: movss   xmm0, [rsi+rdx*4]
    lea     rax, [rip+bn_lo]
    movss   xmm1, [rax+rdx*4]
    minss   xmm1, xmm0
    movss   [rax+rdx*4], xmm1
    lea     rax, [rip+bn_hi]
    movss   xmm1, [rax+rdx*4]
    maxss   xmm1, xmm0
    movss   [rax+rdx*4], xmm1
    inc     edx
    cmp     edx, 3
    jb      21b
    add     rsi, 12
    dec     ecx
    jnz     2b
3:  lea     rdi, [rsp]                  # G: scale 1 / (2 s), offset
    lea     rsi, [rip+id_m4]            #  0.5 - loc / (2 s); s = 0: 1
    call    m4_copy
    xor     ecx, ecx
4:  lea     rax, [rip+bn_hi]
    cvtss2sd xmm0, [rax+rcx*4]
    lea     rax, [rip+bn_lo]
    cvtss2sd xmm1, [rax+rcx*4]
    movsd   xmm2, xmm0                  # 2 s = hi - lo
    subsd   xmm2, xmm1
    addsd   xmm0, xmm1                  # loc = (hi + lo) / 2
    mulsd   xmm0, [rip+bd_half]
    ucomisd xmm2, [rip+bd_zero]
    jne     41f
    movsd   xmm2, [rip+bd_one]
    addsd   xmm2, xmm2
41: movsd   xmm3, [rip+bd_one]
    divsd   xmm3, xmm2                  # k
    imul    eax, ecx, 5                 # [i][i]
    movsd   [rsp+rax*8], xmm3
    mulsd   xmm0, xmm3
    movsd   xmm1, [rip+bd_half]
    subsd   xmm1, xmm0
    lea     eax, [rcx*4+3]
    movsd   [rsp+rax*8], xmm1
    inc     ecx
    cmp     ecx, 3
    jb      4b
    lea     rdi, [rip+bn_gen]
    lea     rsi, [rsp]
    lea     rdx, [rip+ci_m4]
    call    m4_mul
    add     rsp, 264
    ret

# =============================================================================
# The memo: a Blender output made once
# =============================================================================
# bn_memo_get(rdi=key) -> eax = its ref (0: none)
bn_memo_get:
    lea     rdx, [rip+bn_memo]
    mov     ecx, [rip+bn_nmemo]
1:  test    ecx, ecx
    jz      8f
    cmp     [rdx], rdi
    je      2f
    add     rdx, 16
    dec     ecx
    jmp     1b
2:  mov     eax, [rdx+8]
    ret
8:  xor     eax, eax
    ret

# bn_memo_put(rdi=key, esi=ref)
bn_memo_put:
    mov     ecx, [rip+bn_nmemo]
    cmp     ecx, BP_NMEMO
    jae     9f
    shl     ecx, 4
    lea     rdx, [rip+bn_memo]
    mov     [rdx+rcx], rdi
    mov     [rdx+rcx+8], esi
    inc     dword ptr [rip+bn_nmemo]
9:  ret

# bn_memo_drop(edi=node count) - forget refs to nodes past it
bn_memo_drop:
    lea     rsi, [rip+bn_memo]
    mov     rdx, rsi
    mov     ecx, [rip+bn_nmemo]
    xor     r8d, r8d
1:  test    ecx, ecx
    jz      9f
    movzx   eax, word ptr [rsi+8]
    cmp     eax, edi
    ja      2f
    mov     rax, [rsi]
    mov     [rdx], rax
    mov     rax, [rsi+8]
    mov     [rdx+8], rax
    add     rdx, 16
    inc     r8d
2:  add     rsi, 16
    dec     ecx
    jmp     1b
9:  mov     [rip+bn_nmemo], r8d
    ret

# =============================================================================
# Nodes and wires
# =============================================================================
# bn_node(edi=type) -> eax = a new node (0: the graph is full), placed by
#   its depth (the BSDF's inputs right, what feeds them leftwards)
bn_node:
    push    rbx
    mov     esi, edi
    mov     edi, [rip+bn_mat]
    call    graph_add
    test    eax, eax
    jg      1f
    xor     eax, eax
    pop     rbx
    ret
1:  mov     ebx, eax
    mov     eax, [rip+bn_depth]
    cmp     eax, 15
    jbe     2f
    mov     eax, 15
2:  lea     rcx, [rip+bn_ycol]
    mov     r8d, [rcx+rax*4]
    lea     edx, [r8+110]
    mov     [rcx+rax*4], edx
    imul    eax, eax, -170
    add     eax, 1020
    cmp     eax, 20
    jge     3f
    mov     eax, 20
3:  mov     edx, eax
    mov     ecx, r8d
    mov     esi, ebx
    mov     edi, [rip+bn_mat]
    call    graph_place
    mov     eax, ebx
    pop     rbx
    ret

# bn_wire(edi=ref (node | output << 16), esi=node, edx=input 1..3) - a link
#   (from always comes before: the graph's order holds)
bn_wire:
    push    rbx
    push    r12
    push    r13
    mov     ebx, edi
    mov     r12d, esi
    mov     r13d, edx
    mov     edi, [rip+bn_mat]
    call    graph_own
    test    rax, rax
    jz      9f
    lea     ecx, [r12-1]
    imul    ecx, ecx, NODE_SZ
    lea     edx, [r13-1]
    shl     edx, 4
    add     ecx, edx
    mov     [rax+GR_NODES+rcx+ND_IN], ebx
9:  pop     r13
    pop     r12
    pop     rbx
    ret

# bn_set(edi=node, esi=slot 1..7, rdx=float[3], ecx=how many)
bn_set:
    mov     r8d, ecx
    mov     rcx, rdx
    mov     edx, esi
    mov     esi, edi
    mov     edi, [rip+bn_mat]
    jmp     graph_set

# bn_setf(edi=node, esi=slot, xmm0) - one value
bn_setf:
    sub     rsp, 24
    movss   [rsp], xmm0
    lea     rdx, [rsp]
    mov     ecx, 1
    call    bn_set
    add     rsp, 24
    ret

# bn_seti(edi=node, esi=slot, edx=a whole number) - one value
bn_seti:
    cvtsi2ss xmm0, edx
    jmp     bn_setf

# bn_put(edi=node, esi=input 1..3, edx=ref (0: the constant), rcx=float[3])
bn_put:
    test    edx, edx
    jz      1f
    xchg    edi, edx
    xchg    esi, edx                    # edi ref, esi node, edx input
    jmp     bn_wire
1:  mov     rdx, rcx
    mov     ecx, 3
    jmp     bn_set

# bn_op(edi=type, esi=operation, edx=ref a, ecx=ref b (0: xmm0 constant))
#   -> eax = a Math / Vector Math node: op(a, b) (0: full)
bn_op:
    push    rbx
    push    r12
    push    r13
    push    r14
    sub     rsp, 24
    mov     r12d, esi
    mov     r13d, edx
    mov     r14d, ecx
    movss   [rsp], xmm0
    movss   [rsp+4], xmm0
    movss   [rsp+8], xmm0
    call    bn_node
    test    eax, eax
    jz      9f
    mov     ebx, eax
    mov     edi, ebx
    mov     esi, 4
    mov     edx, r12d
    call    bn_seti
    mov     edi, ebx
    mov     esi, 1
    mov     edx, r13d
    lea     rcx, [rsp]
    call    bn_put
    mov     edi, ebx
    mov     esi, 2
    mov     edx, r14d
    lea     rcx, [rsp]
    call    bn_put
    mov     eax, ebx
9:  add     rsp, 24
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# =============================================================================
# Blender's sockets and links
# =============================================================================
# bn_link(rsi=an input socket's old address) -> rax = the link into it, or 0
bn_link:
    push    rbx
    push    r12
    sub     rsp, 8
    mov     r12, rsi
    xor     eax, eax
    test    rsi, rsi
    jz      9f
    mov     rdi, [rip+bn_tree]
    mov     eax, [rip+o_nt_links]
    call    bl_rdp
1:  test    rax, rax
    jz      9f
    mov     rbx, rax
    mov     eax, [rip+o_nl_tosock]
    cmp     [rbx+rax], r12
    je      2f
    mov     rdi, rbx
    mov     eax, [rip+o_nl_next]
    call    bl_rdp
    jmp     1b
2:  mov     rax, rbx
9:  add     rsp, 8
    pop     r12
    pop     rbx
    ret

# bn_link_ref(rax=link) -> eax = what feeds it, made (0: cannot)
bn_link_ref:
    push    rbx
    mov     rbx, rax
    mov     eax, [rip+p_nl_fromsock]
    test    eax, eax
    js      8f
    mov     rdi, rbx
    mov     eax, [rip+o_nl_from]
    call    bl_rdp
    test    rax, rax
    jz      8f
    mov     rdi, rax
    mov     eax, [rip+p_nl_fromsock]
    mov     rsi, [rbx+rax]
    call    bn_out
    pop     rbx
    ret
8:  xor     eax, eax
    pop     rbx
    ret

# bn_in(rsi=input name, edx=kind (0 colour, 1 float, 2 vector; +256: a value
#   only), rdi=float[4] for its value; r14 = the node) -> eax = ref when
#   linked, 0: the value (in rdi), -1: cannot
bn_in:
    push    rbx
    push    r12
    push    r13
    mov     ebx, edx
    mov     r13, rdi
    xorps   xmm0, xmm0
    movups  [r13], xmm0
    call    bl_sock
    mov     r12, rax
    cmp     qword ptr [rip+bl_sockold], 0
    je      8f
    test    r12, r12
    jz      5f
    movzx   eax, bl
    cmp     eax, 1
    je      2f
    cmp     eax, 2
    je      3f
    movups  xmm0, [r12]                 # rgba
    movups  [r13], xmm0
    jmp     5f
2:  mov     eax, [rip+o_sv_float]
    test    eax, eax
    js      5f
    movss   xmm0, [r12+rax]
    movss   [r13], xmm0
    movss   [r13+4], xmm0
    movss   [r13+8], xmm0
    jmp     5f
3:  mov     eax, [rip+p_svv_value]
    test    eax, eax
    js      5f
    movss   xmm0, [r12+rax]
    movss   [r13], xmm0
    movss   xmm0, [r12+rax+4]
    movss   [r13+4], xmm0
    movss   xmm0, [r12+rax+8]
    movss   [r13+8], xmm0
5:  mov     rsi, [rip+bl_sockold]
    call    bn_link
    test    rax, rax
    jz      7f
    test    ebx, 256
    jnz     8f
    call    bn_link_ref
    test    eax, eax
    jz      8f
    jmp     9f
7:  xor     eax, eax
    jmp     9f
8:  mov     eax, -1
9:  pop     r13
    pop     r12
    pop     rbx
    ret

# bn_node3(edi=type, rsi=3 x (name, kind), 0 name: none) -> eax = the node
#   with those inputs (linked or their values) in 1..3 (0: cannot)
bn_node3:
    push    rbx
    push    r12
    push    r13
    sub     rsp, 80
    mov     r12d, edi
    mov     r13, rsi
    xor     ebx, ebx
1:  mov     dword ptr [rsp+64+rbx*4], -2
    mov     eax, ebx
    shl     eax, 4
    mov     rsi, [r13+rax]
    mov     rdx, [r13+rax+8]
    test    rsi, rsi
    jz      2f
    lea     rdi, [rsp+rax]
    call    bn_in
    cmp     eax, -1
    je      8f
    mov     [rsp+64+rbx*4], eax
2:  inc     ebx
    cmp     ebx, 3
    jb      1b
    mov     edi, r12d
    call    bn_node
    test    eax, eax
    jz      8f
    mov     r12d, eax
    xor     ebx, ebx
3:  mov     edx, [rsp+64+rbx*4]
    cmp     edx, -2
    je      4f
    mov     eax, ebx
    shl     eax, 4
    lea     rcx, [rsp+rax]
    lea     esi, [rbx+1]
    mov     edi, r12d
    call    bn_put
4:  inc     ebx
    cmp     ebx, 3
    jb      3b
    mov     eax, r12d
    jmp     9f
8:  xor     eax, eax
9:  add     rsp, 80
    pop     r13
    pop     r12
    pop     rbx
    ret

# bn_val(rsi=input name, rdi=float[4]; r14 = the node) -> eax = 1: its value
#   (an input left unlinked; 0 when linked or missing)
bn_val:
    sub     rsp, 8
    mov     edx, 1+256
    call    bn_in
    add     rsp, 8
    cmp     eax, 0
    sete    al
    movzx   eax, al
    ret

# =============================================================================
# bn_out(rdi=node, rsi=its output's old address) -> eax = that output made
#   into graph nodes: ref = node | output << 16 (0: cannot)
# =============================================================================
bn_out:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    mov     r14, rdi
    mov     r12, rsi
    xor     ebx, ebx
    test    r14, r14
    jz      9f
    cmp     dword ptr [rip+bn_depth], 24
    jae     9f
    mov     rdi, r12
    call    bn_memo_get
    mov     ebx, eax
    test    eax, eax
    jnz     9f
    mov     rdi, r12                    # its output (its name)
    call    bl_ptr
    mov     r15, rax
    inc     dword ptr [rip+bn_depth]
    lea     r13, [rip+bn_kinds]
1:  mov     rsi, [r13]
    test    rsi, rsi
    jz      8f
    mov     eax, [rip+o_nd_idname]
    lea     rdi, [r14+rax]
    call    str_eq
    test    eax, eax
    jnz     2f
    add     r13, 16
    jmp     1b
2:  call    qword ptr [r13+8]                     # r14 node, r15 / r12 its output
    mov     ebx, eax
    test    eax, eax
    jz      8f
    mov     rdi, r12
    mov     esi, ebx
    call    bn_memo_put
8:  dec     dword ptr [rip+bn_depth]
9:  mov     eax, ebx
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# bn_outname(rsi=name) -> ZF set when the output (r15) has it
bn_outname:
    xor     eax, eax
    test    r15, r15
    jz      1f
    mov     eax, [rip+o_ns_name]
    lea     rdi, [r15+rax]
    call    str_eq
1:  cmp     eax, 1
    ret

# ---- vectors: a node output through an affine map -------------------------------
# bn_vec(rdi=out vector, rsi=input name, edx=when unlinked: 0 Generated, 1
#   UV, 2 cannot; r14 = the node) -> eax = 1
bn_vec:
    push    rbx
    push    r12
    push    r13
    mov     rbx, rdi
    mov     r13d, edx
    call    bl_sock
    mov     rsi, [rip+bl_sockold]
    call    bn_link
    mov     rdi, rbx
    mov     rsi, rax
    mov     edx, r13d
    call    bn_vec_link
    pop     r13
    pop     r12
    pop     rbx
    ret

# bn_vec_link(rdi=out vector, rsi=link or 0, edx=default as bn_vec) -> eax
bn_vec_link:
    push    rbx
    push    r12
    push    r13
    mov     rbx, rdi
    test    rsi, rsi
    jz      5f
    mov     r12, rsi
    mov     eax, [rip+p_nl_fromsock]
    test    eax, eax
    js      8f
    mov     r13, [r12+rax]
    mov     rdi, r12
    mov     eax, [rip+o_nl_from]
    call    bl_rdp
    test    rax, rax
    jz      8f
    mov     rdi, rbx
    mov     rsi, rax
    mov     rdx, r13
    call    bn_vec_src
    jmp     9f
5:  cmp     edx, 1                      # unlinked
    je      6f
    ja      8f
    mov     rdi, rbx                    # Generated
    lea     rsi, [rip+bn_gen]
    mov     edx, T_POS
    mov     ecx, 2
    call    bn_vec_base
    jmp     9f
6:  mov     rdi, rbx                    # UV
    lea     rsi, [rip+id_m4]
    mov     edx, T_TEXCO
    mov     ecx, 1
    call    bn_vec_base
    jmp     9f
8:  xor     eax, eax
9:  pop     r13
    pop     r12
    pop     rbx
    ret

# bn_vec_base(rdi=out vector, rsi=map, edx=node type, ecx=memo key) -> eax:
#   our Texture Coordinate / Position / Normal node (once) through the map
bn_vec_base:
    push    rbx
    push    r12
    push    r13
    push    r14
    sub     rsp, 8
    mov     rbx, rdi
    mov     r12, rsi
    mov     r13d, edx
    mov     r14d, ecx
    mov     edi, r14d
    call    bn_memo_get
    test    eax, eax
    jnz     1f
    mov     edi, r13d
    call    bn_node
    test    eax, eax
    jz      9f
    mov     edi, r14d
    mov     esi, eax
    push    rax
    push    rax
    call    bn_memo_put
    pop     rax
    pop     rax
1:  mov     [rbx], eax
    lea     rdi, [rbx+VEC_M]
    mov     rsi, r12
    call    m4_copy
    mov     eax, 1
9:  add     rsp, 8
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# bn_vec_src(rdi=out vector, rsi=node, rdx=its output's old address) -> eax
bn_vec_src:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    sub     rsp, 400
    mov     rbx, rdi
    mov     r14, rsi
    mov     r12, rdx
    mov     rdi, r12
    call    bl_ptr
    mov     r15, rax                    # the output (its name)
    mov     eax, [rip+o_nd_idname]
    lea     rdi, [r14+rax]
    lea     rsi, [rip+s_texco]
    call    str_eq
    test    eax, eax
    jnz     .Lvs_texco
    mov     eax, [rip+o_nd_idname]
    lea     rdi, [r14+rax]
    lea     rsi, [rip+s_mapping]
    call    str_eq
    test    eax, eax
    jnz     .Lvs_map
    mov     eax, [rip+o_nd_idname]
    lea     rdi, [r14+rax]
    lea     rsi, [rip+s_reroute]
    call    str_eq
    test    eax, eax
    jnz     .Lvs_reroute
    mov     rdi, r14                    # any other node: its output as it is
    mov     rsi, r12
    call    bn_out
    test    eax, eax
    jz      .Lvs_fail
    mov     [rbx], eax
    lea     rdi, [rbx+VEC_M]
    lea     rsi, [rip+id_m4]
    call    m4_copy
    jmp     .Lvs_ok
.Lvs_texco:
    lea     rsi, [rip+k_uv]
    call    bn_outname
    jnz     1f
    mov     rdi, rbx
    lea     rsi, [rip+id_m4]
    mov     edx, T_TEXCO
    mov     ecx, 1
    call    bn_vec_base
    jmp     .Lvs_ret
1:  lea     rsi, [rip+k_gen]
    call    bn_outname
    jnz     2f
    mov     rdi, rbx
    lea     rsi, [rip+bn_gen]
    mov     edx, T_POS
    mov     ecx, 2
    call    bn_vec_base
    jmp     .Lvs_ret
2:  lea     rsi, [rip+k_object]
    call    bn_outname
    jnz     3f
    mov     rdi, rbx
    lea     rsi, [rip+ci_m4]
    mov     edx, T_POS
    mov     ecx, 2
    call    bn_vec_base
    jmp     .Lvs_ret
3:  lea     rsi, [rip+k_normal]
    call    bn_outname
    jnz     .Lvs_fail
    mov     rdi, rbx
    lea     rsi, [rip+ci_m4]
    mov     edx, T_NORMAL
    mov     ecx, 3
    call    bn_vec_base
    jmp     .Lvs_ret
.Lvs_reroute:
    mov     rdi, rbx
    lea     rsi, [rip+k_input]
    xor     edx, edx
    call    bn_vec
    jmp     .Lvs_ret
.Lvs_map:
    # [rsp] location, [rsp+16] rotation, [rsp+32] scale; [rsp+64] A,
    #   [rsp+192] a factor, [rsp+320] scratch
    lea     rdi, [rsp]
    lea     rsi, [rip+k_loc]
    mov     edx, 2+256
    call    bn_in
    test    eax, eax
    jnz     .Lvs_fail
    lea     rdi, [rsp+16]
    lea     rsi, [rip+k_rot]
    mov     edx, 2+256
    call    bn_in
    test    eax, eax
    jnz     .Lvs_fail
    lea     rdi, [rsp+32]
    lea     rsi, [rip+k_scale]
    mov     edx, 2+256
    call    bn_in
    test    eax, eax
    jnz     .Lvs_fail
    mov     rdi, rbx                    # what it maps
    lea     rsi, [rip+k_vector]
    mov     edx, 2
    call    bn_vec
    test    eax, eax
    jz      .Lvs_fail
    mov     eax, [rip+p_nd_c1]          # its type
    xor     ecx, ecx
    test    eax, eax
    js      4f
    movsx   ecx, word ptr [r14+rax]
4:  mov     [rsp+48], ecx
    cmp     ecx, 3
    jae     .Lvs_fail                   # (a normal)
    lea     rdi, [rsp+64]               # R
    lea     rsi, [rsp+16]
    mov     edx, 1
    call    m4_euler
    cmp     dword ptr [rsp+48], 1
    je      .Lvs_tex
    lea     rdi, [rsp+192]              # point, vector: T R D
    lea     rsi, [rsp+32]
    xor     edx, edx
    call    bn_m4diag
    lea     rdi, [rsp+64]
    lea     rsi, [rsp+64]
    lea     rdx, [rsp+192]
    call    m4_mul
    cmp     dword ptr [rsp+48], 2
    je      .Lvs_apply
    xor     ecx, ecx
5:  cvtss2sd xmm0, [rsp+rcx*4]
    lea     eax, [rcx*4+3]
    movsd   [rsp+64+rax*8], xmm0
    inc     ecx
    cmp     ecx, 3
    jb      5b
    jmp     .Lvs_apply
.Lvs_tex:                               # texture: D^-1 R^T T(-L)
    lea     rdi, [rsp+64]
    call    bn_m4t3
    lea     rdi, [rsp+192]
    lea     rsi, [rip+id_m4]
    call    m4_copy
    xor     ecx, ecx
6:  cvtss2sd xmm0, [rsp+rcx*4]
    xorpd   xmm1, xmm1
    subsd   xmm1, xmm0
    lea     eax, [rcx*4+3]
    movsd   [rsp+192+rax*8], xmm1
    inc     ecx
    cmp     ecx, 3
    jb      6b
    lea     rdi, [rsp+64]
    lea     rsi, [rsp+64]
    lea     rdx, [rsp+192]
    call    m4_mul
    lea     rdi, [rsp+192]
    lea     rsi, [rsp+32]
    mov     edx, 1
    call    bn_m4diag
    lea     rdi, [rsp+64]
    lea     rsi, [rsp+192]
    lea     rdx, [rsp+64]
    call    m4_mul
.Lvs_apply:
    lea     rdi, [rbx+VEC_M]            # the vector's map: A x it
    lea     rsi, [rsp+64]
    lea     rdx, [rbx+VEC_M]
    call    m4_mul
.Lvs_ok:
    mov     eax, 1
    jmp     .Lvs_ret
.Lvs_fail:
    xor     eax, eax
.Lvs_ret:
    add     rsp, 400
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# bn_m4diag(rdi=out, rsi=float[3], edx=1: their inverses (0: 0))
bn_m4diag:
    push    rdi
    push    rsi
    push    rdx
    lea     rsi, [rip+id_m4]
    call    m4_copy
    pop     rdx
    pop     rsi
    pop     rdi
    xor     ecx, ecx
1:  cvtss2sd xmm0, [rsi+rcx*4]
    test    edx, edx
    jz      2f
    xorpd   xmm1, xmm1
    ucomisd xmm0, xmm1
    je      3f
    movsd   xmm1, [rip+bd_one]
    divsd   xmm1, xmm0
    movsd   xmm0, xmm1
    jmp     2f
3:  xorpd   xmm0, xmm0
2:  imul    eax, ecx, 5
    movsd   [rdi+rax*8], xmm0
    inc     ecx
    cmp     ecx, 3
    jb      1b
    ret

# bn_m4t3(rdi=m4) - its 3x3 part transposed
bn_m4t3:
    lea     rsi, [rip+bn_pairs]
    mov     ecx, 3
1:  movzx   eax, byte ptr [rsi]
    movzx   edx, byte ptr [rsi+1]
    movsd   xmm0, [rdi+rax*8]
    movsd   xmm1, [rdi+rdx*8]
    movsd   [rdi+rax*8], xmm1
    movsd   [rdi+rdx*8], xmm0
    add     rsi, 2
    dec     ecx
    jnz     1b
    ret
.section .rodata
bn_pairs:       .byte 1, 4, 2, 8, 6, 9
.text

# bn_vec_node(rdi=vector) -> eax = ref of it whole: its base, or three dot
#   products, a combine and an add (0: full)
bn_vec_node:
    push    rbx
    push    r12
    push    r13
    sub     rsp, 32
    mov     rbx, rdi
    lea     rsi, [rip+id_m4]            # the identity: the base itself
    xor     ecx, ecx
1:  movsd   xmm0, [rbx+VEC_M+rcx*8]
    ucomisd xmm0, [rsi+rcx*8]
    jne     2f
    jp      2f
    inc     ecx
    cmp     ecx, 12
    jb      1b
    mov     eax, [rbx]
    jmp     9f
2:  xor     r12d, r12d                  # the rows
3:  mov     rdi, rbx
    mov     esi, r12d
    call    bn_dot
    test    eax, eax
    jz      8f
    mov     [rsp+r12*4], eax
    inc     r12d
    cmp     r12d, 3
    jb      3b
    mov     edi, T_COMBINE
    call    bn_node
    test    eax, eax
    jz      8f
    mov     r13d, eax
    xor     r12d, r12d
4:  mov     edi, [rsp+r12*4]
    mov     esi, r13d
    lea     edx, [r12+1]
    call    bn_wire
    inc     r12d
    cmp     r12d, 3
    jb      4b
    xor     ecx, ecx                    # the offset
    xor     edx, edx
5:  lea     eax, [rcx*4+3]
    cvtsd2ss xmm0, [rbx+VEC_M+rax*8]
    movss   [rsp+16+rcx*4], xmm0
    xorps   xmm1, xmm1
    ucomiss xmm0, xmm1
    setne   al
    or      dl, al
    inc     ecx
    cmp     ecx, 3
    jb      5b
    mov     eax, r13d
    test    dl, dl
    jz      9f
    mov     edi, T_VMATH
    call    bn_node
    test    eax, eax
    jz      8f
    mov     r12d, eax
    mov     edi, r13d
    mov     esi, r12d
    mov     edx, 1
    call    bn_wire
    mov     edi, r12d
    mov     esi, 2
    lea     rdx, [rsp+16]
    mov     ecx, 3
    call    bn_set
    mov     eax, r12d                   # (its operation: add, the default)
    jmp     9f
8:  xor     eax, eax
9:  add     rsp, 32
    pop     r13
    pop     r12
    pop     rbx
    ret

# bn_dot(rdi=vector, esi=row) -> eax = a Vector Math dot product: the row's
#   part without its offset (0: full)
bn_dot:
    push    rbx
    push    r12
    push    r13
    sub     rsp, 16
    mov     rbx, rdi
    mov     r12d, esi
    mov     edi, T_VMATH
    call    bn_node
    test    eax, eax
    jz      9f
    mov     r13d, eax
    mov     edi, r13d
    mov     esi, 4
    mov     edx, VM_DOT
    call    bn_seti
    mov     edi, [rbx]
    mov     esi, r13d
    mov     edx, 1
    call    bn_wire
    imul    eax, r12d, 4
    xor     ecx, ecx
1:  lea     edx, [rax+rcx]
    cvtsd2ss xmm0, [rbx+VEC_M+rdx*8]
    movss   [rsp+rcx*4], xmm0
    inc     ecx
    cmp     ecx, 3
    jb      1b
    mov     edi, r13d
    mov     esi, 2
    lea     rdx, [rsp]
    mov     ecx, 3
    call    bn_set
    mov     eax, r13d
9:  add     rsp, 16
    pop     r13
    pop     r12
    pop     rbx
    ret

# bn_comp(rdi=vector, esi=row) -> eax = that part as a value (0: full)
bn_comp:
    push    rbx
    push    r12
    sub     rsp, 8
    mov     rbx, rdi
    mov     r12d, esi
    call    bn_dot
    test    eax, eax
    jz      9f
    lea     ecx, [r12*4+3]
    cvtsd2ss xmm0, [rbx+VEC_M+rcx*8]
    xorps   xmm1, xmm1
    ucomiss xmm0, xmm1
    jne     1f
    jp      1f
    jmp     9f
1:  mov     edx, eax
    xor     ecx, ecx
    mov     edi, T_MATH
    mov     esi, MO_ADD
    call    bn_op
9:  add     rsp, 8
    pop     r12
    pop     rbx
    ret

# =============================================================================
# The nodes (r14 = the node, r15 = the output asked for, r12 its old
#   address) -> eax = ref, 0: cannot
# =============================================================================
# Texture Coordinate, Mapping: the vector whole
bn_h_vec:
    sub     rsp, VEC_SZ+16
    lea     rdi, [rsp]
    mov     rsi, r14
    mov     rdx, r12
    call    bn_vec_src
    test    eax, eax
    jz      9f
    lea     rdi, [rsp]
    call    bn_vec_node
9:  add     rsp, VEC_SZ+16
    ret

# Reroute, a group: its first linked input
bn_h_pass:
    push    rbx
    mov     eax, [rip+o_nd_inputs]
    test    eax, eax
    js      8f
    mov     rbx, [r14+rax]
1:  test    rbx, rbx
    jz      8f
    mov     rsi, rbx
    call    bn_link
    test    rax, rax
    jnz     2f
    mov     rdi, rbx
    call    bl_ptr
    test    rax, rax
    jz      8f
    mov     ecx, [rip+o_ns_next]
    mov     rbx, [rax+rcx]
    jmp     1b
2:  call    bn_link_ref
    pop     rbx
    ret
8:  xor     eax, eax
    pop     rbx
    ret

# Gradient Texture
bn_h_grad:
    push    rbx
    push    r12
    push    r13
    sub     rsp, VEC_SZ+8
    lea     rdi, [rsp]
    lea     rsi, [rip+k_vector]
    xor     edx, edx
    call    bn_vec
    test    eax, eax
    jz      8f
    xor     ebx, ebx                    # its type
    mov     rdi, r14
    mov     eax, [rip+p_nd_storage]
    call    bl_rdp
    test    rax, rax
    jz      1f
    mov     ecx, [rip+p_grad_type]
    test    ecx, ecx
    js      1f
    mov     ebx, [rax+rcx]
1:  cmp     ebx, 6                      # (SHD_BLEND_*: 0 linear, 1 quadratic,
    je      .Lgr_sphere                 #  2 easing, 3 diagonal, 4 radial,
    cmp     ebx, 5                      #  5 quadratic sphere, 6 spherical)
    je      .Lgr_sphere
    cmp     ebx, 3
    je      .Lgr_diag
    cmp     ebx, 4
    je      .Lgr_radial
    cmp     ebx, 2
    ja      8f
    lea     rdi, [rsp]                  # linear, quadratic, easing: x
    xor     esi, esi
    call    bn_comp
    test    eax, eax
    jz      8f
    mov     r12d, eax
    cmp     ebx, 2
    je      .Lgr_ease
    mov     edi, T_MATH                 # clamped
    mov     esi, MO_SAT
    mov     edx, r12d
    xor     ecx, ecx
    xorps   xmm0, xmm0
    call    bn_op
    test    eax, eax
    jz      8f
    cmp     ebx, 1
    jne     9f
.Lgr_square:
    mov     edi, T_MATH
    mov     esi, MO_MUL
    mov     edx, eax
    mov     ecx, eax
    call    bn_op
    jmp     9f
.Lgr_ease:                              # smoothstep(0, 1, x)
    mov     edi, T_MATH
    call    bn_node
    test    eax, eax
    jz      8f
    mov     r13d, eax
    mov     edi, r13d
    mov     esi, 4
    mov     edx, MO_SSTEP
    call    bn_seti
    mov     edi, r13d
    mov     esi, 2
    movss   xmm0, [rip+bf_one]
    call    bn_setf
    mov     edi, r12d
    mov     esi, r13d
    mov     edx, 3
    call    bn_wire
    mov     eax, r13d
    jmp     9f
.Lgr_diag:                              # (x + y) / 2, clamped
    lea     rdi, [rsp]
    xor     esi, esi
    call    bn_comp
    test    eax, eax
    jz      8f
    mov     r12d, eax
    lea     rdi, [rsp]
    mov     esi, 1
    call    bn_comp
    test    eax, eax
    jz      8f
    mov     edi, T_MATH
    mov     esi, MO_ADD
    mov     edx, r12d
    mov     ecx, eax
    call    bn_op
    test    eax, eax
    jz      8f
    mov     edi, T_MATH
    mov     esi, MO_MUL
    mov     edx, eax
    xor     ecx, ecx
    movss   xmm0, [rip+bf_half]
    call    bn_op
    test    eax, eax
    jz      8f
    mov     edi, T_MATH
    mov     esi, MO_SAT
    mov     edx, eax
    xor     ecx, ecx
    xorps   xmm0, xmm0
    call    bn_op
    jmp     9f
.Lgr_radial:                            # atan2(y, x) / 2 pi + 0.5
    lea     rdi, [rsp]
    mov     esi, 1
    call    bn_comp
    test    eax, eax
    jz      8f
    mov     r12d, eax
    lea     rdi, [rsp]
    xor     esi, esi
    call    bn_comp
    test    eax, eax
    jz      8f
    mov     edi, T_MATH
    mov     esi, MO_ATAN2
    mov     edx, r12d
    mov     ecx, eax
    call    bn_op
    test    eax, eax
    jz      8f
    mov     r12d, eax
    mov     edi, T_MATH
    call    bn_node
    test    eax, eax
    jz      8f
    mov     r13d, eax
    mov     edi, r13d
    mov     esi, 4
    mov     edx, MO_MADD
    call    bn_seti
    mov     edi, r12d
    mov     esi, r13d
    mov     edx, 1
    call    bn_wire
    mov     edi, r13d
    mov     esi, 2
    movss   xmm0, [rip+bf_inv2pi]
    call    bn_setf
    mov     edi, r13d
    mov     esi, 3
    movss   xmm0, [rip+bf_half]
    call    bn_setf
    mov     eax, r13d
    jmp     9f
.Lgr_sphere:                            # max(1 - |v|, 0) (squared: 5)
    lea     rdi, [rsp]
    call    bn_vec_node
    test    eax, eax
    jz      8f
    mov     edi, T_VMATH
    mov     esi, VM_LEN
    mov     edx, eax
    xor     ecx, ecx
    xorps   xmm0, xmm0
    call    bn_op
    test    eax, eax
    jz      8f
    mov     edi, T_MATH
    mov     esi, MO_OMIN
    mov     edx, eax
    xor     ecx, ecx
    xorps   xmm0, xmm0
    call    bn_op
    test    eax, eax
    jz      8f
    mov     edi, T_MATH
    mov     esi, MO_MAX
    mov     edx, eax
    xor     ecx, ecx
    xorps   xmm0, xmm0
    call    bn_op
    test    eax, eax
    jz      8f
    cmp     ebx, 5
    je      .Lgr_square
    jmp     9f
8:  xor     eax, eax
9:  add     rsp, VEC_SZ+8
    pop     r13
    pop     r12
    pop     rbx
    ret

# Color Ramp: a chain of two-stop ramps, each taking the one before below
#   its first stop
bn_h_ramp:
    push    rbx
    push    r12
    push    r13
    push    rbp
    sub     rsp, 56
    lea     rsi, [rip+k_alpha]          # (its alpha: not made)
    call    bn_outname
    jz      8f
    mov     rdi, r14
    mov     eax, [rip+p_nd_storage]
    call    bl_rdp
    test    rax, rax
    jz      8f
    mov     rbx, rax                    # the ColorBand
    mov     eax, [rip+p_cb_tot]
    test    eax, eax
    js      8f
    movsx   ebp, word ptr [rbx+rax]
    test    ebp, ebp
    jle     8f
    cmp     ebp, 32
    jbe     1f
    mov     ebp, 32
1:  mov     eax, [rip+p_cb_ipo]
    xor     ecx, ecx
    test    eax, eax
    js      2f
    movzx   ecx, byte ptr [rbx+rax]
2:  mov     [rsp+48], ecx
    lea     rdi, [rsp]                  # its factor
    lea     rsi, [rip+k_fac]
    mov     edx, 1
    call    bn_in
    cmp     eax, -1
    je      8f
    mov     [rsp+44], eax
    cmp     ebp, 1                      # one stop: its colour
    jne     3f
    mov     edi, T_COLOR
    call    bn_node
    test    eax, eax
    jz      8f
    mov     r12d, eax
    xor     esi, esi
    call    bn_stop
    mov     edi, r12d
    mov     esi, 1
    lea     rdx, [rsp+16]
    mov     ecx, 3
    call    bn_set
    mov     eax, r12d
    jmp     9f
3:  xor     r12d, r12d                  # the ramp before
    mov     r13d, 1
4:  cmp     r13d, ebp
    jae     7f
    mov     edi, T_RAMP
    call    bn_node
    test    eax, eax
    jz      8f
    mov     [rsp+40], eax
    mov     edi, eax                    # the factor
    mov     esi, 1
    mov     edx, [rsp+44]
    lea     rcx, [rsp]
    call    bn_put
    lea     esi, [r13-1]                # below: the stop before, or the ramp
    call    bn_stop
    test    r12d, r12d
    jz      41f
    mov     edi, r12d
    mov     esi, [rsp+40]
    mov     edx, 2
    call    bn_wire
    jmp     42f
41: mov     edi, [rsp+40]
    mov     esi, 2
    lea     rdx, [rsp+16]
    mov     ecx, 3
    call    bn_set
42: movss   xmm0, [rsp+28]              # (its position)
    movss   [rsp+32], xmm0
    mov     esi, r13d                   # above: this stop
    call    bn_stop
    mov     edi, [rsp+40]
    mov     esi, 3
    lea     rdx, [rsp+16]
    mov     ecx, 3
    call    bn_set
    movss   xmm0, [rsp+32]              # p0, p1 (constant: a step at p1)
    movss   xmm1, [rsp+28]
    cmp     dword ptr [rsp+48], 4
    jne     43f
    movss   xmm0, xmm1
    addss   xmm1, [rip+bf_step]
43: movss   [rsp+36], xmm1
    mov     edi, [rsp+40]
    mov     esi, 4
    call    bn_setf
    movss   xmm0, [rsp+36]
    mov     edi, [rsp+40]
    mov     esi, 5
    call    bn_setf
    mov     r12d, [rsp+40]
    inc     r13d
    jmp     4b
7:  mov     eax, r12d
    jmp     9f
8:  xor     eax, eax
9:  add     rsp, 56
    pop     rbp
    pop     r13
    pop     r12
    pop     rbx
    ret

# bn_stop(esi=stop; rbx = the ColorBand) - the caller's [rsp+16]: r g b,
#   [rsp+28]: its position
bn_stop:
    mov     eax, [rip+p_cbd_sz]
    imul    eax, esi
    add     eax, [rip+p_cb_data]
    lea     rdx, [rbx+rax]
    mov     eax, [rip+p_cbd_r]
    movss   xmm0, [rdx+rax]
    movss   [rsp+8+16], xmm0
    movss   xmm0, [rdx+rax+4]
    movss   [rsp+8+20], xmm0
    movss   xmm0, [rdx+rax+8]
    movss   [rsp+8+24], xmm0
    mov     eax, [rip+p_cbd_pos]
    movss   xmm0, [rdx+rax]
    movss   [rsp+8+28], xmm0
    ret

# MixRGB (Blender 2.8 .. 3.3): its mode in custom1
bn_h_mixrgb:
    push    rbx
    mov     edi, T_MIX
    lea     rsi, [rip+bn_in_mixrgb]
    call    bn_node3
    test    eax, eax
    jz      9f
    mov     ebx, eax
    mov     eax, [rip+p_nd_c1]
    xor     edx, edx
    test    eax, eax
    js      1f
    movsx   edx, word ptr [r14+rax]
1:  call    bn_mode
    mov     edi, ebx
    mov     esi, 4
    call    bn_seti
    mov     eax, ebx
9:  pop     rbx
    ret

# bn_mode(edx=Blender blend type) -> edx = the Mix node's mode
bn_mode:
    cmp     edx, 19
    ja      1f
    lea     rax, [rip+bn_blendmap]
    movzx   edx, byte ptr [rax+rdx]
    ret
1:  xor     edx, edx
    ret

# Mix (Blender 3.4 on): colours or floats
bn_h_mix:
    push    rbx
    push    r12
    sub     rsp, 8
    mov     rdi, r14
    mov     eax, [rip+p_nd_storage]
    call    bl_rdp
    test    rax, rax
    jz      8f
    mov     ecx, [rip+p_mix_dtype]
    test    ecx, ecx
    js      8f
    movsx   r12d, byte ptr [rax+rcx]
    xor     ebx, ebx
    mov     ecx, [rip+p_mix_blend]
    test    ecx, ecx
    js      1f
    movsx   ebx, byte ptr [rax+rcx]
1:  lea     rsi, [rip+bn_in_mixc]
    cmp     r12d, 2                     # RGBA
    je      2f
    test    r12d, r12d                  # float (vectors: not made)
    jnz     8f
    xor     ebx, ebx
    lea     rsi, [rip+bn_in_mixf]
2:  mov     edi, T_MIX
    call    bn_node3
    test    eax, eax
    jz      8f
    mov     r12d, eax
    mov     edx, ebx
    call    bn_mode
    mov     edi, r12d
    mov     esi, 4
    call    bn_seti
    mov     eax, r12d
    jmp     9f
8:  xor     eax, eax
9:  add     rsp, 8
    pop     r12
    pop     rbx
    ret

# Math: its operation in custom1, clamp in custom2
bn_h_math:
    push    rbx
    push    r12
    sub     rsp, 8
    mov     eax, [rip+p_nd_c1]
    test    eax, eax
    js      8f
    movsx   ecx, word ptr [r14+rax]
    cmp     ecx, BP_NMATH
    jae     8f
    lea     rax, [rip+bn_mathmap]
    movzx   ebx, byte ptr [rax+rcx]
    cmp     ebx, 255
    je      8f
    mov     edi, T_MATH
    lea     rsi, [rip+bn_in_math]
    call    bn_node3
    test    eax, eax
    jz      8f
    mov     r12d, eax
    mov     edi, r12d
    mov     esi, 4
    mov     edx, ebx
    call    bn_seti
    mov     eax, r12d
    mov     ecx, [rip+p_nd_c2]          # clamped
    test    ecx, ecx
    js      9f
    test    word ptr [r14+rcx], 1
    jz      9f
    mov     edi, T_MATH
    mov     esi, MO_SAT
    mov     edx, r12d
    xor     ecx, ecx
    xorps   xmm0, xmm0
    call    bn_op
    jmp     9f
8:  xor     eax, eax
9:  add     rsp, 8
    pop     r12
    pop     rbx
    ret

# Voronoi: distance (F1, F2, to the edge) or the cell's colour
bn_h_voronoi:
    push    rbx
    push    r12
    push    r13
    sub     rsp, VEC_SZ+56
    xor     r13d, r13d                  # the output: distance, colour
    lea     rsi, [rip+k_distance]
    call    bn_outname
    jz      1f
    mov     r13d, 1
    lea     rsi, [rip+k_color]
    call    bn_outname
    jnz     8f
1:  xor     ebx, ebx                    # its feature
    mov     rdi, r14
    mov     eax, [rip+p_nd_storage]
    call    bl_rdp
    test    rax, rax
    jz      2f
    mov     ecx, [rip+p_vor_feat]
    test    ecx, ecx
    js      2f
    mov     ebx, [rax+rcx]
2:  cmp     ebx, 2                      # smooth F1: F1; edge: 2
    jne     21f
    xor     ebx, ebx
21: cmp     ebx, 3
    jne     22f
    mov     ebx, 2
22: cmp     ebx, 2
    ja      8f
    lea     rdi, [rsp+VEC_SZ]           # scale, randomness: values
    lea     rsi, [rip+k_scale]
    call    bn_val
    test    eax, eax
    jz      8f
    lea     rdi, [rsp+VEC_SZ+16]
    lea     rsi, [rip+k_random]
    mov     edx, 1+256
    call    bn_in
    test    eax, eax
    jz      3f
    cmp     qword ptr [rip+bl_sockold], 0
    jne     8f                          # (linked)
    movss   xmm0, [rip+bf_one]          # (none before 2.81: 1)
    movss   [rsp+VEC_SZ+16], xmm0
3:  lea     rdi, [rsp]
    lea     rsi, [rip+k_vector]
    xor     edx, edx
    call    bn_vec
    test    eax, eax
    jz      8f
    lea     rdi, [rsp]
    call    bn_vec_node
    test    eax, eax
    jz      8f
    mov     r12d, eax
    mov     edi, T_VORONOI
    call    bn_node
    test    eax, eax
    jz      8f
    mov     [rsp+VEC_SZ+48], eax
    mov     edi, r12d
    mov     esi, eax
    mov     edx, 1
    call    bn_wire
    mov     edi, [rsp+VEC_SZ+48]
    mov     esi, 4
    movss   xmm0, [rsp+VEC_SZ]
    call    bn_setf
    mov     edi, [rsp+VEC_SZ+48]
    mov     esi, 5
    movss   xmm0, [rsp+VEC_SZ+16]
    call    bn_setf
    mov     edi, [rsp+VEC_SZ+48]
    mov     esi, 6
    mov     edx, ebx
    call    bn_seti
    mov     eax, r13d
    shl     eax, 16
    or      eax, [rsp+VEC_SZ+48]
    jmp     9f
8:  xor     eax, eax
9:  add     rsp, VEC_SZ+56
    pop     r13
    pop     r12
    pop     rbx
    ret

# Image Texture: its image through the vector (UV unless linked)
bn_h_image:
    push    rbx
    push    r12
    push    r13
    sub     rsp, VEC_SZ+24
    xor     r13d, r13d                  # colour, alpha (output 4)
    lea     rsi, [rip+k_color]
    call    bn_outname
    jz      1f
    mov     r13d, 4
    lea     rsi, [rip+k_alpha]
    call    bn_outname
    jnz     8f
1:  mov     rdi, r14                    # its image
    mov     eax, [rip+o_nd_id]
    call    bl_rdp
    test    rax, rax
    jz      8f
    mov     ebx, [rip+bl_owner]
    mov     rdi, rax
    mov     rsi, rdx
    call    bl_image
    mov     [rip+bl_owner], ebx
    test    eax, eax
    jz      8f
    mov     ebx, eax
    xor     r12d, r12d                  # unlinked: the UVs as they are
    lea     rsi, [rip+k_vector]
    call    bl_sock
    mov     rsi, [rip+bl_sockold]
    call    bn_link
    test    rax, rax
    jz      3f
    lea     rdi, [rsp]
    mov     rsi, rax
    mov     edx, 1
    call    bn_vec_link
    test    eax, eax
    jz      8f
    lea     rdi, [rsp]
    call    bn_vec_node
    test    eax, eax
    jz      8f
    mov     r12d, eax
3:  mov     edi, T_IMAGE
    call    bn_node
    test    eax, eax
    jz      8f
    mov     [rsp+VEC_SZ], eax
    mov     edi, eax
    mov     esi, 4
    mov     edx, ebx
    call    bn_seti
    test    r12d, r12d
    jz      4f
    mov     edi, r12d
    mov     esi, [rsp+VEC_SZ]
    mov     edx, 1
    call    bn_wire
4:  mov     eax, r13d
    shl     eax, 16
    or      eax, [rsp+VEC_SZ]
    jmp     9f
8:  xor     eax, eax
9:  add     rsp, VEC_SZ+24
    pop     r13
    pop     r12
    pop     rbx
    ret

# Hue/Saturation/Value: hue + (H - 0.5), saturation x S, value x V, mixed by
#   the factor
bn_h_hsv:
    push    rbx
    sub     rsp, 64
    lea     rdi, [rsp]
    lea     rsi, [rip+k_hue]
    call    bn_val
    test    eax, eax
    jz      8f
    lea     rdi, [rsp+16]
    lea     rsi, [rip+k_sat]
    call    bn_val
    test    eax, eax
    jz      8f
    lea     rdi, [rsp+32]
    lea     rsi, [rip+k_value]
    call    bn_val
    test    eax, eax
    jz      8f
    lea     rdi, [rsp+48]
    lea     rsi, [rip+k_fac]
    call    bn_val
    test    eax, eax
    jz      8f
    mov     edi, T_HSV
    lea     rsi, [rip+bn_in_hsv]
    call    bn_node3
    test    eax, eax
    jz      8f
    mov     ebx, eax
    movss   xmm0, [rsp]
    subss   xmm0, [rip+bf_half]
    mov     edi, ebx
    mov     esi, 4
    call    bn_setf
    movss   xmm0, [rsp+16]
    mov     edi, ebx
    mov     esi, 5
    call    bn_setf
    movss   xmm0, [rsp+32]
    mov     edi, ebx
    mov     esi, 6
    call    bn_setf
    movss   xmm0, [rsp+48]
    mov     edi, ebx
    mov     esi, 7
    call    bn_setf
    mov     eax, ebx
    jmp     9f
8:  xor     eax, eax
9:  add     rsp, 64
    pop     rbx
    ret

# Invert: by its factor
bn_h_invert:
    push    rbx
    sub     rsp, 16
    lea     rdi, [rsp]
    lea     rsi, [rip+k_fac]
    call    bn_val
    test    eax, eax
    jz      8f
    mov     edi, T_INVERT
    lea     rsi, [rip+bn_in_hsv]
    call    bn_node3
    test    eax, eax
    jz      8f
    mov     ebx, eax
    movss   xmm0, [rsp]
    mov     edi, ebx
    mov     esi, 4
    call    bn_setf
    mov     eax, ebx
    jmp     9f
8:  xor     eax, eax
9:  add     rsp, 16
    pop     rbx
    ret

# RGB, Value: the output's own value
bn_h_rgb:
    push    rbx
    sub     rsp, 16
    test    r15, r15
    jz      8f
    mov     rdi, r15
    mov     eax, [rip+o_ns_value]
    call    bl_rdp
    test    rax, rax
    jz      8f
    movups  xmm0, [rax]
    movups  [rsp], xmm0
    mov     edi, T_COLOR
    call    bn_node
    test    eax, eax
    jz      8f
    mov     ebx, eax
    mov     edi, ebx
    mov     esi, 1
    lea     rdx, [rsp]
    mov     ecx, 3
    call    bn_set
    mov     eax, ebx
    jmp     9f
8:  xor     eax, eax
9:  add     rsp, 16
    pop     rbx
    ret

bn_h_value:
    push    rbx
    sub     rsp, 16
    test    r15, r15
    jz      8f
    mov     rdi, r15
    mov     eax, [rip+o_ns_value]
    call    bl_rdp
    test    rax, rax
    jz      8f
    mov     ecx, [rip+o_sv_float]
    test    ecx, ecx
    js      8f
    movss   xmm0, [rax+rcx]
    movss   [rsp], xmm0
    mov     edi, T_CONST
    call    bn_node
    test    eax, eax
    jz      8f
    mov     ebx, eax
    movss   xmm0, [rsp]
    mov     edi, ebx
    mov     esi, 4
    call    bn_setf
    mov     eax, ebx
    jmp     9f
8:  xor     eax, eax
9:  add     rsp, 16
    pop     rbx
    ret
