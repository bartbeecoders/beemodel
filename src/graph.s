# =============================================================================
#  BeeModel - shader graphs: small node graphs inside a material
#
#  A material record holds up to 48 nodes after its principled values. Each
#  node has a type, three inputs (a constant colour, or a link to one of an
#  earlier node's outputs: node + 1, the output in bits 16..23) and four
#  parameters; every output is a colour and a value. Thirteen Material
#  Output pins (GR_PINS, linked the same way) take node results in place of
#  the material's own base colour, metallic, specular, roughness, emission,
#  opacity, ambient occlusion, clear coat and its roughness, transmission,
#  IOR and opacity mask, and the normal (a bump or normal map node). Only
#  the nodes that lead to a pin are evaluated.
#
#    1 image     p0 image + 1, p1 size (object units per repeat)
#    2 noise     p0 scale, p1 detail (octaves), p2 roughness; in0 = offset
#    3 checker   p0 scale; in0, in1 = the two colours
#    4 gradient  p0 axis (0 x, 1 y, 2 z), p1 scale, p2 offset
#    5 mix       p0 mode (0 mix, 1 add, 2 multiply, 3 subtract, 4 screen);
#                in0 = factor, in1, in2 = colours
#    6 ramp      in0 = factor, in1 / in2 = colours at p0 / p1
#    7 math      p0 op (0 add 1 subtract 2 multiply 3 divide 4 power 5 min
#                6 max 7 greater 8 sine 9 absolute); in0, in1 = values
#    8 bump      in0 = height; p0 strength, p1 distance
#    9 normalmap in0 = a tangent-space normal map's colour (an image node);
#                p0 strength. The tangent frame comes from the mesh's UVs
#                (OpenGL: green = +v), as baking writes it
#
#  Coordinates are object space (noise, checker, gradient) or the box
#  projection (image). Nodes evaluate in order, so a link always points to
#  an earlier node and graphs cannot loop. Bump re-evaluates the graph a
#  little along both triangle edges and tilts the normal (Blinn).
# =============================================================================
.intel_syntax noprefix
.include "const.inc"
.include "macros.inc"

.globl graph_shade
.globl fbm
.globl perlin
.globl graph_add
.globl graph_link
.globl graph_set
.globl graph_socket
.globl graph_clear
.globl graph_own
.globl graph_info
.globl graph_value
.globl graph_link_any
.globl graph_delete
.globl graph_sort
.globl op_mat_node_delete
.globl op_mat_node_move
.globl graph_type_index
.globl graph_socket_index
.globl graph_type_names
.globl graph_ntypes
.globl graph_socket_names
.globl op_mat_node
.globl op_mat_link
.globl op_mat_node_set
.globl op_mat_socket
.globl op_mat_nodes_clear

.equ GR_N,      128                     # u32 node count
.equ GR_SOCK,   132                     # u32[5]: v0.12's sockets (now GR_PINS)
.equ GR_NODES,  160
.equ NODE_SZ,   72
.equ ND_TYPE,   0
.equ ND_IN,     4                       # 3 x (u32 link, f32[3] value)
.equ ND_P,      52                      # f32[4]
.equ ND_POS,    68                      # i16 x, y in the node editor (0, 0: not placed)
.equ GR_OUTPOS,  152                     # i16 x, y: the material output node
.equ MAX_NODES, 48
.equ NOUTS,     4                       # outputs a node can have
.equ MA_BASE_,  32                      # (material.s: the principled values)
.equ MA_METAL_, 44
.equ MA_ROUGH_, 48
.equ MA_SPEC_,  52
.equ MA_IOR_,   56
.equ MA_TRANS_, 60
.equ MA_EMIT_,  64
.equ MA_ESTR_,  76
.equ MA_COAT_,  80
.equ MA_COATR_, 84
.equ MA_ALPHA_, 88
.equ T_IMAGE,   1
.equ T_NOISE,   2
.equ T_CHECKER, 3
.equ T_GRAD,    4
.equ T_MIX,     5
.equ T_RAMP,    6
.equ T_MATH,    7
.equ T_BUMP,    8
.equ T_NMAP,    9
.equ NTYPES,    9
# the shading context (callers fill the first part)
.equ SC_P0O,    0                       # object-space corner, edges
.equ SC_E1O,    12
.equ SC_E2O,    24
.equ SC_U,      36
.equ SC_V,      40
.equ SC_PU,     44                      # dp/du, dp/dv in the normal's space
.equ SC_PV,     56
.equ SC_N,      68                      # the shading normal (in / out)
.equ SC_BASE,   80                      # results
.equ SC_METAL,  92
.equ SC_ROUGH,  96
.equ SC_EMIT,   100
.equ SC_FLAGS,  112                     # bit p: pin p drove the copy (PIN_NORMAL: SC_N)
.equ SC_UVP,    120                     # the triangle's UVs (6 floats) or 0:
                                        #  box projection
.equ SC_SZ,     128
# evaluation frame
.equ EV_P,      0                       # object position
.equ EV_UV,     12
.equ EV_LIVE,   24                      # u64: the nodes to evaluate
.equ EV_VAL,    32                      # 48 x 4 outputs x (rgb, value)
.equ EV_SZ,     32 + 16*NOUTS*MAX_NODES

.section .rodata
.align 8
graph_type_names:
                .quad s_t_image, s_t_noise, s_t_checker, s_t_grad, s_t_mix, s_t_ramp, s_t_math, s_t_bump, s_t_nmap, 0
graph_socket_names:                     # the pins, in PIN_* order
                .quad s_s_base, s_s_metal, s_s_spec, s_s_rough, s_s_emit, s_s_alpha
                .quad s_s_bump, s_s_ao, s_s_coat, s_s_coatr, s_s_trans, s_s_ior, s_s_mask, 0
graph_ntypes:   .long NTYPES
# per pin: the copy's offset, and how its value goes there (0 the colour, 1
#   the value clamped to 0..1, 2 to 1..3, 3 the emission colour)
pin_off:        .short MA_BASE_, MA_METAL_, MA_SPEC_, MA_ROUGH_, MA_EMIT_, MA_ALPHA_
                .short 0, MA_RT_AO, MA_COAT_, MA_COATR_, MA_TRANS_, MA_IOR_, MA_RT_MASK
pin_kind:       .byte 0, 1, 1, 1, 3, 1, 9, 1, 1, 1, 1, 2, 1
s_t_image:      .asciz "image"
s_t_noise:      .asciz "noise"
s_t_checker:    .asciz "checker"
s_t_grad:       .asciz "gradient"
s_t_mix:        .asciz "mix"
s_t_ramp:       .asciz "ramp"
s_t_math:       .asciz "math"
s_t_bump:       .asciz "bump"
s_t_nmap:       .asciz "normalmap"
s_s_base:       .asciz "base"
s_s_metal:      .asciz "metallic"
s_s_rough:      .asciz "roughness"
s_s_emit:       .asciz "emission"
s_s_bump:       .asciz "normal"
s_s_spec:       .asciz "specular"
s_s_alpha:      .asciz "opacity"
s_s_ao:         .asciz "ao"
s_s_coat:       .asciz "clearcoat"
s_s_coatr:      .asciz "coat_roughness"
s_s_trans:      .asciz "transmission"
s_s_ior:        .asciz "ior"
s_s_mask:       .asciz "mask"
# defaults per type: p0..p3, in0..in2 values (3 each)
.align 4
node_defaults:
    .float 0, 1, 0, 0,     0, 0, 0,  0, 0, 0,  0, 0, 0                  # image
    .float 4, 3, 0.5, 0,   0, 0, 0,  0, 0, 0,  0, 0, 0                  # noise
    .float 2, 0, 0, 0,     0.8, 0.8, 0.8,  0.2, 0.2, 0.2,  0, 0, 0      # checker
    .float 1, 1, 0, 0,     0, 0, 0,  0, 0, 0,  0, 0, 0                  # gradient
    .float 0, 0, 0, 0,     0.5, 0.5, 0.5,  0.8, 0.8, 0.8,  0.2, 0.2, 0.2   # mix
    .float 0, 1, 0, 0,     0.5, 0.5, 0.5,  0, 0, 0,  1, 1, 1            # ramp
    .float 0, 0, 0, 0,     0, 0, 0,  0, 0, 0,  0, 0, 0                  # math
    .float 1, 0.05, 0, 0,  0, 0, 0,  0, 0, 0,  0, 0, 0                  # bump
    .float 1, 0, 0, 0,     0.5, 0.5, 1,  0, 0, 0,  0, 0, 0              # normalmap
gf_one:         .float 1.0
gf_half:        .float 0.5
gf_zero:        .float 0.0
gf_two:         .float 2.0
gf_six:         .float 6.0
gf_three:       .float 3.0
gf_15:          .float 15.0
gf_10:          .float 10.0
gf_eps:         .float 0.001                # bump: the step in object units
gf_tiny:        .float 1.0e-12
gf_maxd:        .float 0.1
gf_lum:         .float 0.2126, 0.7152, 0.0722
gf_noff:        .float 17.31, 41.77, 7.13   # colour noise: shifted samples
gf_noff2:       .float 31.59, 3.23, 23.41
.align 16
gf_abs:         .long 0x7fffffff, 0, 0, 0
gf_sign:        .long 0x80000000, 0, 0, 0
# Ken Perlin's permutation
perm:   .byte 151,160,137,91,90,15,131,13,201,95,96,53,194,233,7,225,140,36,103,30,69,142
        .byte 8,99,37,240,21,10,23,190,6,148,247,120,234,75,0,26,197,62,94,252,219,203,117
        .byte 35,11,32,57,177,33,88,237,149,56,87,174,20,125,136,171,168,68,175,74,165,71
        .byte 134,139,48,27,166,77,146,158,231,83,111,229,122,60,211,133,230,220,105,92,41
        .byte 55,46,245,40,244,102,143,54,65,25,63,161,1,216,80,73,209,76,132,187,208,89
        .byte 18,169,200,196,135,130,116,188,159,86,164,100,109,198,173,186,3,64,52,217,226
        .byte 250,124,123,5,202,38,147,118,126,255,82,85,212,207,206,59,227,47,16,58,17,182
        .byte 189,28,42,223,183,170,213,119,248,152,2,44,154,163,70,221,153,101,155,167,43
        .byte 172,9,129,22,39,253,19,98,108,110,79,113,224,232,178,185,112,104,218,246,97
        .byte 228,251,34,242,193,238,210,144,12,191,179,162,241,81,51,145,235,249,14,239
        .byte 107,49,192,214,31,181,199,106,157,184,84,204,176,115,121,50,45,127,4,150,254
        .byte 138,236,205,93,222,114,67,29,24,72,243,141,128,195,78,66,215,61,156,180

.section .bss
gw_word:        .skip 64

.section .rodata
s_g_need:       .asciz "  material.node <material> image|noise|checker|gradient|mix|ramp|math|bump [values]"
s_g_full:       .asciz "  a material holds 48 nodes"
s_g_node:       .asciz "  node "
s_g_linkneed:   .asciz "  material.link <material> <from node> <to node> <input 1-3> [output 0-3] (no loops)"
s_g_delneed:    .asciz "  material.node_delete <material> <node>"
s_g_moveneed:   .asciz "  material.node_move <material> <node (0: the output)> <x> <y>"
s_g_setneed:    .asciz "  material.node_set <material> <node> <slot: 1-3 inputs, 4-7 values> <x> [y z]"
s_g_sockneed:   .asciz "  material.socket <material> base|metallic|specular|roughness|emission|opacity|normal|ao|clearcoat|coat_roughness|transmission|ior|mask <node|none> [output 0-3]"
s_g_ok:         .asciz "  graph: "
s_g_noimage:    .asciz "  no image named "
s_g_unknown:    .asciz "  no material named "
s_g_none:       .asciz "none"

OPERATOR op_mat_node, "material.node", "Add Shader Node", do_mat_node, flags=OPF_AI_SAFE|OPF_UNDO, doc="Add a node to a material's graph: material.node <material> <type> [values] (image: <image> [size])"
OPERATOR op_mat_link, "material.link", "Link Shader Nodes", do_mat_link, flags=OPF_AI_SAFE|OPF_UNDO, doc="Feed a node into another node's input: material.link <material> <from> <to> <input 1-3> [output 0-3] (any order; the graph is kept in evaluation order)"
OPERATOR op_mat_node_set, "material.node_set", "Set Shader Node Value", do_mat_node_set, flags=OPF_AI_SAFE|OPF_UNDO, doc="Set a node input (1-3) or value (4-7): material.node_set <material> <node> <slot> <x> [y z]"
OPERATOR op_mat_socket, "material.socket", "Connect Material Socket", do_mat_socket, flags=OPF_AI_SAFE|OPF_UNDO, doc="Drive a Material Output pin by a node: material.socket <material> base|metallic|specular|roughness|emission|opacity|normal|ao|clearcoat|coat_roughness|transmission|ior|mask <node|none> [output 0-3]"
OPERATOR op_mat_node_delete, "material.node_delete", "Delete Shader Node", do_mat_node_delete, flags=OPF_AI_SAFE|OPF_UNDO, doc="Remove a node from a material's graph (its links go): material.node_delete <material> <node>"
OPERATOR op_mat_node_move, "material.node_move", "Move Shader Node", do_mat_node_move, flags=OPF_AI_SAFE|OPF_UNDO|OPF_QUIET, doc="Place a node in the node editor: material.node_move <material> <node (0: the output)> <x> <y>"
OPERATOR op_mat_nodes_clear, "material.nodes_clear", "Clear Shader Nodes", do_mat_nodes_clear, flags=OPF_AI_SAFE|OPF_UNDO, doc="Remove a material's graph: material.nodes_clear <material>"

.text

# =============================================================================
#  Noise: improved Perlin noise, fBm
# =============================================================================
# fade(xmm0) -> xmm0 = t^3 (t (6 t - 15) + 10)
fade:
    movaps  xmm1, xmm0
    mulss   xmm1, [rip+gf_six]
    subss   xmm1, [rip+gf_15]
    mulss   xmm1, xmm0
    addss   xmm1, [rip+gf_10]
    mulss   xmm1, xmm0
    mulss   xmm1, xmm0
    mulss   xmm1, xmm0
    movaps  xmm0, xmm1
    ret

# pm(eax) -> eax = perm[eax & 255]
.macro PM reg
    and     eax, 255
    movzx   eax, byte ptr [r11+rax]
.endm

# grad(eax=hash, xmm0..2 = x y z) -> xmm0
grad:
    and     eax, 15
    movaps  xmm3, xmm0                  # u = h < 8 ? x : y
    cmp     eax, 8
    jb      1f
    movaps  xmm3, xmm1
1:  movaps  xmm4, xmm1                  # v = h < 4 ? y : (h == 12 or 14 ? x : z)
    cmp     eax, 4
    jb      3f
    movaps  xmm4, xmm2
    cmp     eax, 12
    je      2f
    cmp     eax, 14
    jne     3f
2:  movaps  xmm4, xmm0
3:  test    eax, 1
    jz      4f
    xorps   xmm3, [rip+gf_sign]
4:  test    eax, 2
    jz      5f
    xorps   xmm4, [rip+gf_sign]
5:  addss   xmm3, xmm4
    movaps  xmm0, xmm3
    ret

# perlin(rdi=p[3]) -> xmm0 in about -1..1
perlin:
    push    rbx
    push    r12
    push    r13
    push    r14
    sub     rsp, 72
    lea     r11, [rip+perm]
    xor     ecx, ecx                    # cell (wrapped), fraction, fade
1:  movss   xmm0, [rdi+rcx*4]
    cvttss2si eax, xmm0
    cvtsi2ss xmm1, eax
    comiss  xmm1, xmm0
    jbe     2f
    dec     eax
    cvtsi2ss xmm1, eax
2:  subss   xmm0, xmm1
    and     eax, 255
    mov     [rsp+rcx*4], eax            # X Y Z
    movss   [rsp+12+rcx*4], xmm0        # x y z
    call    fade
    movss   [rsp+24+rcx*4], xmm0        # u v w
    inc     ecx
    cmp     ecx, 3
    jb      1b
    # hashes: A = p[X] + Y, AA = p[A] + Z, AB = p[A+1] + Z, B = p[X+1] + Y, ...
    mov     eax, [rsp]
    PM      eax
    add     eax, [rsp+4]
    mov     ebx, eax                    # A
    PM      eax
    add     eax, [rsp+8]
    mov     r12d, eax                   # AA
    lea     eax, [rbx+1]
    PM      eax
    add     eax, [rsp+8]
    mov     r13d, eax                   # AB
    mov     eax, [rsp]
    inc     eax
    PM      eax
    add     eax, [rsp+4]
    mov     ebx, eax                    # B
    PM      eax
    add     eax, [rsp+8]
    mov     r14d, eax                   # BA
    lea     eax, [rbx+1]
    PM      eax
    add     eax, [rsp+8]
    mov     ebx, eax                    # BB
    # the eight corners: grad(p[..], x - i, y - j, z - k)
    # corner order: (0,0,0) AA, (1,0,0) BA, (0,1,0) AB, (1,1,0) BB, then +1 z
    lea     r8, [rsp+36]                # results g[8]
    xor     r9d, r9d
3:  mov     eax, r12d                   # pick the hash
    test    r9d, 1
    jz      31f
    mov     eax, r14d
31: test    r9d, 2
    jz      33f
    mov     eax, r13d
    test    r9d, 1
    jz      33f
    mov     eax, ebx
33: test    r9d, 4
    jz      34f
    inc     eax
34: PM      eax
    movss   xmm0, [rsp+12]
    movss   xmm1, [rsp+16]
    movss   xmm2, [rsp+20]
    test    r9d, 1
    jz      35f
    subss   xmm0, [rip+gf_one]
35: test    r9d, 2
    jz      36f
    subss   xmm1, [rip+gf_one]
36: test    r9d, 4
    jz      37f
    subss   xmm2, [rip+gf_one]
37: call    grad
    movss   [r8+r9*4], xmm0
    inc     r9d
    cmp     r9d, 8
    jb      3b
    # trilinear with the fades
    movss   xmm5, [rsp+24]              # u
    xor     ecx, ecx
4:  movss   xmm0, [r8+rcx*8]            # pairs along x
    movss   xmm1, [r8+rcx*8+4]
    subss   xmm1, xmm0
    mulss   xmm1, xmm5
    addss   xmm0, xmm1
    movss   [r8+rcx*4], xmm0
    inc     ecx
    cmp     ecx, 4
    jb      4b
    movss   xmm5, [rsp+28]              # v
    xor     ecx, ecx
5:  movss   xmm0, [r8+rcx*8]
    movss   xmm1, [r8+rcx*8+4]
    subss   xmm1, xmm0
    mulss   xmm1, xmm5
    addss   xmm0, xmm1
    movss   [r8+rcx*4], xmm0
    inc     ecx
    cmp     ecx, 2
    jb      5b
    movss   xmm0, [r8]                  # w
    movss   xmm1, [r8+4]
    subss   xmm1, xmm0
    mulss   xmm1, [rsp+32]
    addss   xmm0, xmm1
    add     rsp, 72
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# fbm(rdi=p[3], xmm0=scale, ecx=octaves, xmm1=roughness) -> xmm0 in 0..1
fbm:
    push    rbx
    push    r12
    sub     rsp, 56
    mov     rbx, rdi
    mov     r12d, ecx
    test    r12d, r12d
    jg      1f
    mov     r12d, 1
1:  cmp     r12d, 8
    jle     2f
    mov     r12d, 8
2:  movss   [rsp+16], xmm0              # frequency
    movss   [rsp+20], xmm1              # gain
    mov     dword ptr [rsp+24], 0x3f800000  # amplitude
    mov     dword ptr [rsp+28], 0       # sum
    mov     dword ptr [rsp+32], 0       # sum of amplitudes
3:  xor     ecx, ecx
4:  movss   xmm0, [rbx+rcx*4]
    mulss   xmm0, [rsp+16]
    movss   [rsp+rcx*4], xmm0
    inc     ecx
    cmp     ecx, 3
    jb      4b
    lea     rdi, [rsp]
    call    perlin
    mulss   xmm0, [rsp+24]
    addss   xmm0, [rsp+28]
    movss   [rsp+28], xmm0
    movss   xmm0, [rsp+24]
    addss   xmm0, [rsp+32]
    movss   [rsp+32], xmm0
    movss   xmm0, [rsp+24]
    mulss   xmm0, [rsp+20]
    movss   [rsp+24], xmm0
    movss   xmm0, [rsp+16]
    mulss   xmm0, [rip+gf_two]
    movss   [rsp+16], xmm0
    dec     r12d
    jnz     3b
    movss   xmm0, [rsp+28]              # 0.5 + 0.5 sum / amplitudes
    divss   xmm0, [rsp+32]
    mulss   xmm0, [rip+gf_half]
    addss   xmm0, [rip+gf_half]
    maxss   xmm0, [rip+gf_zero]
    minss   xmm0, [rip+gf_one]
    add     rsp, 56
    pop     r12
    pop     rbx
    ret

# =============================================================================
#  Evaluation
# =============================================================================
# node_in(rbx=record, r12=node, ecx=input, r13=frame) -> xmm0..2 colour, xmm3 value
node_in:
    imul    eax, ecx, 16
    lea     rdx, [r12+ND_IN+rax]
    mov     eax, [rdx]
    test    ax, ax
    jz      1f
    call    out_slot                    # a link: that output's result
    lea     rdx, [r13+rax]
    movss   xmm0, [rdx]
    movss   xmm1, [rdx+4]
    movss   xmm2, [rdx+8]
    movss   xmm3, [rdx+12]
    ret
1:  movss   xmm0, [rdx+4]               # a constant: value = its x
    movss   xmm1, [rdx+8]
    movss   xmm2, [rdx+12]
    movss   xmm3, xmm0
    ret

# out_slot(eax=link) -> eax = the frame offset of that output's result
out_slot:
    mov     edx, eax
    movzx   eax, ax
    dec     eax
    shl     eax, 6                      # (16 NOUTS bytes a node)
    shr     edx, 16
    and     edx, NOUTS-1
    shl     edx, 4
    lea     eax, [rax+rdx+EV_VAL]
    ret

# put(xmm0..2) - the node's colour, value = luminance (r13 frame, r14d node)
put_col:
    mov     eax, r14d
    shl     eax, 6
    lea     rdx, [r13+EV_VAL+rax]
    movss   [rdx], xmm0
    movss   [rdx+4], xmm1
    movss   [rdx+8], xmm2
    mulss   xmm0, [rip+gf_lum]
    mulss   xmm1, [rip+gf_lum+4]
    mulss   xmm2, [rip+gf_lum+8]
    addss   xmm0, xmm1
    addss   xmm0, xmm2
    movss   [rdx+12], xmm0
    ret

# put_val(xmm0) - grey colour and value
put_val:
    mov     eax, r14d
    shl     eax, 6
    lea     rdx, [r13+EV_VAL+rax]
    movss   [rdx], xmm0
    movss   [rdx+4], xmm0
    movss   [rdx+8], xmm0
    movss   [rdx+12], xmm0
    ret

# graph_eval(rdi=record, rsi=frame with EV_P, EV_UV filled) - every node
graph_eval:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    sub     rsp, 64
    mov     rbx, rdi
    mov     r13, rsi
    xor     r14d, r14d
.Lge_node:
    cmp     r14d, [rbx+GR_N]
    jae     .Lge_out
    cmp     r14d, MAX_NODES
    jae     .Lge_out
    bt      qword ptr [r13+EV_LIVE], r14
    jnc     .Lge_next                   # (it leads to no pin)
    imul    r12d, r14d, NODE_SZ
    lea     r12, [rbx+GR_NODES+r12]
    mov     eax, [r12+ND_TYPE]
    cmp     eax, T_IMAGE
    je      .Lge_image
    cmp     eax, T_NOISE
    je      .Lge_noise
    cmp     eax, T_CHECKER
    je      .Lge_checker
    cmp     eax, T_GRAD
    je      .Lge_grad
    cmp     eax, T_MIX
    je      .Lge_mix
    cmp     eax, T_RAMP
    je      .Lge_ramp
    cmp     eax, T_MATH
    je      .Lge_math
    cmp     eax, T_BUMP
    je      .Lge_bump
    cmp     eax, T_NMAP
    je      .Lge_nmap
    xorps   xmm0, xmm0
    call    put_val
    jmp     .Lge_next

.Lge_image:
    cvttss2si edi, dword ptr [r12+ND_P]
    dec     edi
    js      .Lge_black
    call    image_ptr
    test    rax, rax
    jz      .Lge_black
    mov     [rsp+48], rax
    movss   xmm2, [r12+ND_P+4]          # size
    xorps   xmm3, xmm3
    comiss  xmm2, xmm3
    ja      1f
    movss   xmm2, [rip+gf_one]
1:  movss   [rsp+56], xmm2
    movss   xmm0, [r13+EV_UV]           # uv (or a linked vector)
    movss   xmm1, [r13+EV_UV+4]
    cmp     dword ptr [r12+ND_IN], 0
    je      2f
    xor     ecx, ecx
    call    node_in
2:  divss   xmm0, [rsp+56]
    divss   xmm1, [rsp+56]
    mov     rdi, [rsp+48]
    lea     rsi, [rsp]
    call    tex_sample
    movss   xmm0, [rsp]
    movss   xmm1, [rsp+4]
    movss   xmm2, [rsp+8]
    call    put_col
    jmp     .Lge_next
.Lge_black:
    xorps   xmm0, xmm0
    call    put_val
    jmp     .Lge_next

.Lge_noise:
    xor     ecx, ecx                    # p + offset (in0)
    call    node_in
    addss   xmm0, [r13+EV_P]
    addss   xmm1, [r13+EV_P+4]
    addss   xmm2, [r13+EV_P+8]
    movss   [rsp], xmm0
    movss   [rsp+4], xmm1
    movss   [rsp+8], xmm2
    lea     rdi, [rsp]
    movss   xmm0, [r12+ND_P]
    cvttss2si ecx, dword ptr [r12+ND_P+4]
    movss   xmm1, [r12+ND_P+8]
    call    fbm
    movss   [rsp+16], xmm0              # r = the value; g, b shifted
    xor     ecx, ecx
3:  movss   xmm0, [rsp+rcx*4]
    lea     rax, [rip+gf_noff]
    addss   xmm0, [rax+rcx*4]
    movss   [rsp+32+rcx*4], xmm0
    inc     ecx
    cmp     ecx, 3
    jb      3b
    lea     rdi, [rsp+32]
    movss   xmm0, [r12+ND_P]
    cvttss2si ecx, dword ptr [r12+ND_P+4]
    movss   xmm1, [r12+ND_P+8]
    call    fbm
    movss   [rsp+20], xmm0
    xor     ecx, ecx
4:  movss   xmm0, [rsp+rcx*4]
    lea     rax, [rip+gf_noff2]
    addss   xmm0, [rax+rcx*4]
    movss   [rsp+32+rcx*4], xmm0
    inc     ecx
    cmp     ecx, 3
    jb      4b
    lea     rdi, [rsp+32]
    movss   xmm0, [r12+ND_P]
    cvttss2si ecx, dword ptr [r12+ND_P+4]
    movss   xmm1, [r12+ND_P+8]
    call    fbm
    movss   xmm2, xmm0
    movss   xmm0, [rsp+16]
    movss   xmm1, [rsp+20]
    call    put_col
    mov     eax, r14d                   # value = the first channel
    shl     eax, 6
    movss   xmm0, [rsp+16]
    movss   [r13+EV_VAL+rax+12], xmm0
    jmp     .Lge_next

.Lge_checker:
    xor     ecx, ecx                    # parity of floor(p scale)
    xor     r15d, r15d
5:  movss   xmm0, [r13+EV_P+rcx*4]
    mulss   xmm0, [r12+ND_P]
    cvttss2si eax, xmm0
    cvtsi2ss xmm1, eax
    comiss  xmm1, xmm0
    jbe     51f
    dec     eax
51: add     r15d, eax
    inc     ecx
    cmp     ecx, 3
    jb      5b
    and     r15d, 1
    mov     ecx, r15d
    call    node_in
    call    put_col
    mov     eax, r14d
    shl     eax, 6
    cvtsi2ss xmm0, r15d
    movss   [r13+EV_VAL+rax+12], xmm0
    jmp     .Lge_next

.Lge_grad:
    cvttss2si eax, dword ptr [r12+ND_P]
    cmp     eax, 2
    jbe     6f
    mov     eax, 1
6:  movss   xmm0, [r13+EV_P+rax*4]
    mulss   xmm0, [r12+ND_P+4]
    mulss   xmm0, [rip+gf_half]
    addss   xmm0, [rip+gf_half]
    addss   xmm0, [r12+ND_P+8]
    maxss   xmm0, [rip+gf_zero]
    minss   xmm0, [rip+gf_one]
    call    put_val
    jmp     .Lge_next

.Lge_mix:
    xor     ecx, ecx
    call    node_in
    maxss   xmm3, [rip+gf_zero]
    minss   xmm3, [rip+gf_one]
    movss   [rsp+48], xmm3              # factor
    mov     ecx, 1
    call    node_in
    movss   [rsp], xmm0
    movss   [rsp+4], xmm1
    movss   [rsp+8], xmm2
    mov     ecx, 2
    call    node_in
    movss   [rsp+16], xmm0
    movss   [rsp+20], xmm1
    movss   [rsp+24], xmm2
    cvttss2si r15d, dword ptr [r12+ND_P]
    xor     ecx, ecx
7:  movss   xmm0, [rsp+rcx*4]           # a
    movss   xmm1, [rsp+16+rcx*4]        # b -> op(a, b)
    cmp     r15d, 1
    jne     71f
    addss   xmm1, xmm0
    jmp     75f
71: cmp     r15d, 2
    jne     72f
    mulss   xmm1, xmm0
    jmp     75f
72: cmp     r15d, 3
    jne     73f
    movss   xmm2, xmm0
    subss   xmm2, xmm1
    movss   xmm1, xmm2
    jmp     75f
73: cmp     r15d, 4                     # screen: 1 - (1 - a)(1 - b)
    jne     75f
    movss   xmm2, [rip+gf_one]
    subss   xmm2, xmm0
    movss   xmm4, [rip+gf_one]
    subss   xmm4, xmm1
    mulss   xmm2, xmm4
    movss   xmm1, [rip+gf_one]
    subss   xmm1, xmm2
75: subss   xmm1, xmm0                  # a + (op - a) factor
    mulss   xmm1, [rsp+48]
    addss   xmm0, xmm1
    movss   [rsp+32+rcx*4], xmm0
    inc     ecx
    cmp     ecx, 3
    jb      7b
    movss   xmm0, [rsp+32]
    movss   xmm1, [rsp+36]
    movss   xmm2, [rsp+40]
    call    put_col
    jmp     .Lge_next

.Lge_ramp:
    xor     ecx, ecx
    call    node_in
    subss   xmm3, [r12+ND_P]            # t = (f - p0) / (p1 - p0)
    movss   xmm4, [r12+ND_P+4]
    subss   xmm4, [r12+ND_P]
    movaps  xmm5, xmm4
    andps   xmm5, [rip+gf_abs]
    comiss  xmm5, [rip+gf_tiny]
    jbe     8f
    divss   xmm3, xmm4
8:  maxss   xmm3, [rip+gf_zero]
    minss   xmm3, [rip+gf_one]
    movss   [rsp+48], xmm3
    mov     ecx, 1
    call    node_in
    movss   [rsp], xmm0
    movss   [rsp+4], xmm1
    movss   [rsp+8], xmm2
    mov     ecx, 2
    call    node_in
    movss   xmm3, [rsp+48]
    subss   xmm0, [rsp]
    mulss   xmm0, xmm3
    addss   xmm0, [rsp]
    subss   xmm1, [rsp+4]
    mulss   xmm1, xmm3
    addss   xmm1, [rsp+4]
    subss   xmm2, [rsp+8]
    mulss   xmm2, xmm3
    addss   xmm2, [rsp+8]
    call    put_col
    jmp     .Lge_next

.Lge_math:
    xor     ecx, ecx
    call    node_in
    movss   [rsp], xmm3
    mov     ecx, 1
    call    node_in
    movss   xmm1, xmm3                  # b
    movss   xmm0, [rsp]                 # a
    cvttss2si eax, dword ptr [r12+ND_P]
    cmp     eax, 1
    jb      90f
    je      91f
    cmp     eax, 3
    jb      92f
    je      93f
    cmp     eax, 5
    jb      94f
    je      95f
    cmp     eax, 7
    jb      96f
    je      97f
    cmp     eax, 8
    je      98f
    andps   xmm0, [rip+gf_abs]          # 9: |a|
    jmp     99f
90: addss   xmm0, xmm1
    jmp     99f
91: subss   xmm0, xmm1
    jmp     99f
92: mulss   xmm0, xmm1
    jmp     99f
93: movaps  xmm2, xmm1
    andps   xmm2, [rip+gf_abs]
    comiss  xmm2, [rip+gf_tiny]
    jbe     931f
    divss   xmm0, xmm1
    jmp     99f
931:xorps   xmm0, xmm0
    jmp     99f
94: xorps   xmm2, xmm2                  # a^b (a > 0), x87
    comiss  xmm0, xmm2
    jbe     931b
    movss   [rsp], xmm0
    movss   [rsp+4], xmm1
    fld     dword ptr [rsp+4]
    fld     dword ptr [rsp]
    fyl2x
    fld     st(0)
    frndint
    fsub    st(1), st(0)
    fxch    st(1)
    f2xm1
    fld1
    faddp   st(1), st(0)
    fscale
    fstp    st(1)
    fstp    dword ptr [rsp]
    movss   xmm0, [rsp]
    jmp     99f
95: minss   xmm0, xmm1
    jmp     99f
96: maxss   xmm0, xmm1
    jmp     99f
97: comiss  xmm0, xmm1                  # a > b: 1 / 0
    movss   xmm0, [rip+gf_one]
    ja      99f
    xorps   xmm0, xmm0
    jmp     99f
98: movss   [rsp], xmm0                 # sin a
    fld     dword ptr [rsp]
    fsin
    fstp    dword ptr [rsp]
    movss   xmm0, [rsp]
99: call    put_val
    jmp     .Lge_next

.Lge_nmap:
    xor     ecx, ecx                    # its colour: the map's
    call    node_in
    call    put_col
    jmp     .Lge_next

.Lge_bump:
    xor     ecx, ecx                    # value = height x distance
    call    node_in
    mulss   xmm3, [r12+ND_P+4]
    movaps  xmm0, xmm3
    call    put_val

.Lge_next:
    inc     r14d
    jmp     .Lge_node
.Lge_out:
    add     rsp, 64
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# at(rbx=record, r12=SC, xmm0=u, xmm1=v, r13=frame) - EV_P and EV_UV there,
#   then evaluate (uv from the corners' box projection kept at SC+SC_SZ)
at:
    movss   xmm2, [rip+gf_one]
    subss   xmm2, xmm0
    subss   xmm2, xmm1                  # w0
    xor     ecx, ecx
1:  movss   xmm3, [r12+SC_E1O+rcx*4]    # p = p0 + u e1 + v e2
    mulss   xmm3, xmm0
    movss   xmm4, [r12+SC_E2O+rcx*4]
    mulss   xmm4, xmm1
    addss   xmm3, xmm4
    addss   xmm3, [r12+SC_P0O+rcx*4]
    movss   [r13+EV_P+rcx*4], xmm3
    inc     ecx
    cmp     ecx, 3
    jb      1b
    xor     ecx, ecx
2:  movss   xmm3, [r12+SC_SZ+rcx*4]     # uv = w0 uv0 + u uv1 + v uv2
    mulss   xmm3, xmm2
    movss   xmm4, [r12+SC_SZ+8+rcx*4]
    mulss   xmm4, xmm0
    addss   xmm3, xmm4
    movss   xmm4, [r12+SC_SZ+16+rcx*4]
    mulss   xmm4, xmm1
    addss   xmm3, xmm4
    movss   [r13+EV_UV+rcx*4], xmm3
    inc     ecx
    cmp     ecx, 2
    jb      2b
    mov     rdi, rbx
    mov     rsi, r13
    jmp     graph_eval

# cross(rdi=a, rsi=b, rdx=out)
cross:
    movss   xmm0, [rdi+4]
    mulss   xmm0, [rsi+8]
    movss   xmm1, [rdi+8]
    mulss   xmm1, [rsi+4]
    subss   xmm0, xmm1
    movss   xmm2, [rdi+8]
    mulss   xmm2, [rsi]
    movss   xmm1, [rdi]
    mulss   xmm1, [rsi+8]
    subss   xmm2, xmm1
    movss   xmm3, [rdi]
    mulss   xmm3, [rsi+4]
    movss   xmm1, [rdi+4]
    mulss   xmm1, [rsi]
    subss   xmm3, xmm1
    movss   [rdx], xmm0
    movss   [rdx+4], xmm2
    movss   [rdx+8], xmm3
    ret

# len3(rdi) -> xmm0
len3:
    movss   xmm0, [rdi]
    mulss   xmm0, xmm0
    movss   xmm1, [rdi+4]
    mulss   xmm1, xmm1
    addss   xmm0, xmm1
    movss   xmm1, [rdi+8]
    mulss   xmm1, xmm1
    addss   xmm0, xmm1
    sqrtss  xmm0, xmm0
    ret

# graph_live(rbx=record, rax=the nodes wanted) -> rax = them and every
#   node feeding them (links point to earlier nodes: one pass down)
graph_live:
    mov     ecx, [rbx+GR_N]
1:  dec     ecx
    js      9f
    bt      rax, rcx
    jnc     1b
    imul    edx, ecx, NODE_SZ
    lea     rdx, [rbx+GR_NODES+rdx+ND_IN]
    xor     r8d, r8d
2:  movzx   r9d, word ptr [rdx]
    dec     r9d
    js      3f
    bts     rax, r9
3:  add     rdx, 16
    inc     r8d
    cmp     r8d, 3
    jb      2b
    jmp     1b
9:  ret

# graph_shade(rdi=material record, rsi=SC (+ 24 bytes after it for the
#   box coordinates), rdx=a copy of its principled values (128 bytes, to
#   change), ecx=1: coverage only (no normal)) -> eax = 1 if the material
#   has a graph; the pins' results in the copy (emission without a strength
#   gets 1), the normal in SC_N, SC_FLAGS which ones
graph_shade:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    push    rbp
    sub     rsp, EV_SZ+152
    mov     rbx, rdi
    mov     r12, rsi
    mov     [rsp+EV_SZ+136], rdx        # the copy
    mov     [rsp+EV_SZ+144], ecx        # the mode
    mov     dword ptr [r12+SC_FLAGS], 0
    xor     eax, eax
    test    rbx, rbx
    jz      .Lgs_out
    cmp     dword ptr [rbx+GR_N], 0
    je      .Lgs_out
    lea     r13, [rsp]                  # the frame
    lea     r15, [rsp+EV_SZ]            # corners p1 p2 (24), sums (scratch)
    xor     eax, eax                    # the nodes that lead to a pin
    xor     ecx, ecx
76: cmp     ecx, NPINS
    jae     79f
    cmp     ecx, PIN_NORMAL
    jne     77f
    test    dword ptr [rsp+EV_SZ+144], 1
    jnz     78f
77: movzx   edx, word ptr [rbx+GR_PINS+rcx*4]
    dec     edx
    js      78f
    bts     rax, rdx
78:inc     ecx
    jmp     76b
79: call    graph_live
    mov     [r13+EV_LIVE], rax
    xor     ecx, ecx                    # the box coordinates of the corners
1:  movss   xmm0, [r12+SC_P0O+rcx*4]
    movss   xmm1, xmm0
    addss   xmm0, [r12+SC_E1O+rcx*4]
    movss   [r15+rcx*4], xmm0
    addss   xmm1, [r12+SC_E2O+rcx*4]
    movss   [r15+12+rcx*4], xmm1
    inc     ecx
    cmp     ecx, 3
    jb      1b
    mov     rsi, [r12+SC_UVP]           # the mesh's UVs, else a box
    test    rsi, rsi
    jz      11f
    lea     rdi, [r12+SC_SZ]
    mov     ecx, 6
    rep     movsd
    jmp     12f
11: lea     rdi, [r12+SC_P0O]
    mov     rsi, r15
    lea     rdx, [r15+12]
    lea     rcx, [r12+SC_SZ]
    call    box_uv
12:
    movss   xmm0, [r12+SC_U]            # the point itself
    movss   xmm1, [r12+SC_V]
    call    at
    # the pins into the copy
    mov     r14, [rsp+EV_SZ+136]
    xor     ebp, ebp
2:  cmp     ebp, NPINS
    jae     3f
    mov     eax, [rbx+GR_PINS+rbp*4]
    test    ax, ax
    jz      29f
    cmp     ax, [rbx+GR_N]
    ja      29f
    lea     rcx, [rip+pin_kind]
    movzx   ecx, byte ptr [rcx+rbp]
    cmp     ecx, 9                      # (the normal: below)
    je      29f
    call    out_slot
    lea     rsi, [r13+rax]
    lea     rdi, [rip+pin_off]
    movzx   edi, word ptr [rdi+rbp*2]
    add     rdi, r14
    test    ecx, 1                      # (kinds 1 and 3 here)
    jz      21f
    cmp     ecx, 1
    je      22f
    mov     rax, [rsi]                  # 3: emission (no strength yet: 1)
    mov     [rdi], rax
    mov     eax, [rsi+8]
    mov     [rdi+8], eax
    xorps   xmm0, xmm0
    comiss  xmm0, [r14+MA_ESTR_]
    jb      28f
    mov     dword ptr [r14+MA_ESTR_], 0x3f800000
    jmp     28f
21: cmp     ecx, 2
    je      23f
    mov     rax, [rsi]                  # 0: the colour
    mov     [rdi], rax
    mov     eax, [rsi+8]
    mov     [rdi+8], eax
    jmp     28f
22: movss   xmm0, [rsi+12]              # 1: the value, 0..1
    maxss   xmm0, [rip+gf_zero]
    minss   xmm0, [rip+gf_one]
    movss   [rdi], xmm0
    jmp     28f
23: movss   xmm0, [rsi+12]              # 2: 1..3 (IOR)
    maxss   xmm0, [rip+gf_one]
    minss   xmm0, [rip+gf_three]
    movss   [rdi], xmm0
28: bts     dword ptr [r12+SC_FLAGS], ebp
29: inc     ebp
    jmp     2b
3:  # the normal: a bump node's height, a little along both edges
    test    dword ptr [rsp+EV_SZ+144], 1
    jnz     .Lgs_done
    mov     eax, [rbx+GR_PINS+PIN_NORMAL*4]
    movzx   eax, ax
    test    eax, eax
    jz      .Lgs_done
    cmp     eax, [rbx+GR_N]
    ja      .Lgs_done
    dec     eax
    mov     r14d, eax                   # the bump node
    imul    eax, eax, NODE_SZ
    cmp     dword ptr [rbx+GR_NODES+rax+ND_TYPE], T_NMAP
    je      .Lgs_nmap
    cmp     dword ptr [rbx+GR_NODES+rax+ND_TYPE], T_BUMP
    jne     .Lgs_done
    movss   xmm0, [rbx+GR_NODES+rax+ND_P]   # strength
    movss   [r15+24], xmm0
    mov     eax, r14d
    shl     eax, 6
    movss   xmm0, [r13+EV_VAL+rax+12]   # h
    movss   [r15+28], xmm0
    xor     eax, eax                    # from here on only its height
    bts     rax, r14
    call    graph_live
    mov     [r13+EV_LIVE], rax
    lea     rdi, [r12+SC_E1O]           # du = eps / |e1o|, dv = eps / |e2o|
    call    len3
    movss   xmm1, [rip+gf_eps]
    maxss   xmm0, [rip+gf_tiny]
    divss   xmm1, xmm0
    minss   xmm1, [rip+gf_maxd]
    movss   [r15+32], xmm1
    lea     rdi, [r12+SC_E2O]
    call    len3
    movss   xmm1, [rip+gf_eps]
    maxss   xmm0, [rip+gf_tiny]
    divss   xmm1, xmm0
    minss   xmm1, [rip+gf_maxd]
    movss   [r15+36], xmm1
    movss   xmm0, [r12+SC_U]            # h(u + du)
    addss   xmm0, [r15+32]
    movss   xmm1, [r12+SC_V]
    call    at
    mov     eax, r14d
    shl     eax, 6
    movss   xmm0, [r13+EV_VAL+rax+12]
    subss   xmm0, [r15+28]
    divss   xmm0, [r15+32]
    movss   [r15+40], xmm0              # dh/du
    movss   xmm0, [r12+SC_U]            # h(v + dv)
    movss   xmm1, [r12+SC_V]
    addss   xmm1, [r15+36]
    call    at
    mov     eax, r14d
    shl     eax, 6
    movss   xmm0, [r13+EV_VAL+rax+12]
    subss   xmm0, [r15+28]
    divss   xmm0, [r15+36]
    movss   [r15+44], xmm0              # dh/dv
    # Blinn: N = Pu x Pv; D = (hu (N x Pv) - hv (N x Pu)) / |N|^2
    lea     rdi, [r12+SC_PU]
    lea     rsi, [r12+SC_PV]
    lea     rdx, [r15+48]               # N
    call    cross
    lea     rdi, [r15+48]
    call    len3
    mulss   xmm0, xmm0
    comiss  xmm0, [rip+gf_tiny]
    jbe     .Lgs_done
    movss   xmm1, [rip+gf_one]
    divss   xmm1, xmm0
    movss   [r15+60], xmm1              # 1 / |N|^2
    lea     rdi, [r15+48]
    lea     rsi, [r12+SC_PV]
    lea     rdx, [r15+64]               # N x Pv
    call    cross
    lea     rdi, [r15+48]
    lea     rsi, [r12+SC_PU]
    lea     rdx, [r15+76]               # N x Pu
    call    cross
    # the side: N against the shading normal
    movss   xmm0, [r15+48]
    mulss   xmm0, [r12+SC_N]
    movss   xmm1, [r15+52]
    mulss   xmm1, [r12+SC_N+4]
    addss   xmm0, xmm1
    movss   xmm1, [r15+56]
    mulss   xmm1, [r12+SC_N+8]
    addss   xmm0, xmm1
    movss   xmm5, [r15+24]              # strength, signed by the side
    xorps   xmm1, xmm1
    comiss  xmm0, xmm1
    jae     4f
    xorps   xmm5, [rip+gf_sign]
4:  mulss   xmm5, [r15+60]
    xor     ecx, ecx                    # n' = n + s D, normalised
5:  movss   xmm0, [r15+64+rcx*4]
    mulss   xmm0, [r15+40]
    movss   xmm1, [r15+76+rcx*4]
    mulss   xmm1, [r15+44]
    subss   xmm0, xmm1
    mulss   xmm0, xmm5
    addss   xmm0, [r12+SC_N+rcx*4]
    movss   [r15+88+rcx*4], xmm0
    inc     ecx
    cmp     ecx, 3
    jb      5b
    lea     rdi, [r15+88]
    call    len3
    comiss  xmm0, [rip+gf_tiny]
    jbe     .Lgs_done
    movss   xmm1, [rip+gf_one]
    divss   xmm1, xmm0
    xor     ecx, ecx
6:  movss   xmm0, [r15+88+rcx*4]
    mulss   xmm0, xmm1
    movss   [r12+SC_N+rcx*4], xmm0
    inc     ecx
    cmp     ecx, 3
    jb      6b
    or      dword ptr [r12+SC_FLAGS], 1 << PIN_NORMAL
.Lgs_done:
    mov     eax, 1
.Lgs_out:
    add     rsp, EV_SZ+152
    pop     rbp
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret
.Lgs_nmap:                              # (r14d: the node; colour evaluated)
    mov     rsi, [r12+SC_UVP]
    test    rsi, rsi
    jz      .Lgs_done
    movss   xmm4, [rbx+GR_NODES+rax+ND_P]   # strength
    mov     eax, r14d                   # t = 2 c - 1 (x, y x strength)
    shl     eax, 6
    lea     rdx, [r13+EV_VAL+rax]
    xor     ecx, ecx
1:  movss   xmm0, [rdx+rcx*4]
    push    rcx                         # (the map's bytes, not colours;
    push    rdx                         #  xmm4 is kept)
    call    tx_unlin
    pop     rdx
    pop     rcx
    addss   xmm0, xmm0
    subss   xmm0, [rip+gf_one]
    cmp     ecx, 2
    je      2f
    mulss   xmm0, xmm4
2:  movss   [r15+48+rcx*4], xmm0
    inc     ecx
    cmp     ecx, 3
    jb      1b
    movss   xmm0, [rsi+8]               # du1 dv1 du2 dv2, det
    subss   xmm0, [rsi]
    movss   xmm1, [rsi+12]
    subss   xmm1, [rsi+4]
    movss   xmm2, [rsi+16]
    subss   xmm2, [rsi]
    movss   xmm3, [rsi+20]
    subss   xmm3, [rsi+4]
    movss   xmm4, xmm0
    mulss   xmm4, xmm3
    movss   xmm5, xmm2
    mulss   xmm5, xmm1
    subss   xmm4, xmm5
    movss   xmm5, xmm4
    andps   xmm5, [rip+gf_abs]
    comiss  xmm5, [rip+gf_tiny]
    jbe     .Lgs_done
    movss   xmm5, [rip+gf_one]
    divss   xmm5, xmm4
    xor     ecx, ecx                    # T = (Pu dv2 - Pv dv1) / det,
3:  movss   xmm6, [r12+SC_PU+rcx*4]     # B = (Pv du1 - Pu du2) / det
    mulss   xmm6, xmm3
    movss   xmm7, [r12+SC_PV+rcx*4]
    mulss   xmm7, xmm1
    subss   xmm6, xmm7
    mulss   xmm6, xmm5
    movss   [r15+24+rcx*4], xmm6
    movss   xmm6, [r12+SC_PV+rcx*4]
    mulss   xmm6, xmm0
    movss   xmm7, [r12+SC_PU+rcx*4]
    mulss   xmm7, xmm2
    subss   xmm6, xmm7
    mulss   xmm6, xmm5
    movss   [r15+36+rcx*4], xmm6
    inc     ecx
    cmp     ecx, 3
    jb      3b
    lea     rdi, [r15+24]               # both without their N part, unit
    call    nm_ortho
    lea     rdi, [r15+36]
    call    nm_ortho
    xor     ecx, ecx                    # n' = tx T + ty B + tz N
4:  movss   xmm0, [r15+24+rcx*4]
    mulss   xmm0, [r15+48]
    movss   xmm1, [r15+36+rcx*4]
    mulss   xmm1, [r15+52]
    addss   xmm0, xmm1
    movss   xmm1, [r12+SC_N+rcx*4]
    mulss   xmm1, [r15+56]
    addss   xmm0, xmm1
    movss   [r15+60+rcx*4], xmm0
    inc     ecx
    cmp     ecx, 3
    jb      4b
    lea     rdi, [r15+60]
    call    len3
    comiss  xmm0, [rip+gf_tiny]
    jbe     .Lgs_done
    movss   xmm1, [rip+gf_one]
    divss   xmm1, xmm0
    xor     ecx, ecx
5:  movss   xmm0, [r15+60+rcx*4]
    mulss   xmm0, xmm1
    movss   [r12+SC_N+rcx*4], xmm0
    inc     ecx
    cmp     ecx, 3
    jb      5b
    or      dword ptr [r12+SC_FLAGS], 1 << PIN_NORMAL
    jmp     .Lgs_done

# nm_ortho(rdi=vector; r12 = SC) - without its SC_N part, unit (0 stays 0)
nm_ortho:
    movss   xmm0, [rdi]
    mulss   xmm0, [r12+SC_N]
    movss   xmm1, [rdi+4]
    mulss   xmm1, [r12+SC_N+4]
    addss   xmm0, xmm1
    movss   xmm1, [rdi+8]
    mulss   xmm1, [r12+SC_N+8]
    addss   xmm0, xmm1
    xor     ecx, ecx
1:  movss   xmm1, [r12+SC_N+rcx*4]
    mulss   xmm1, xmm0
    movss   xmm2, [rdi+rcx*4]
    subss   xmm2, xmm1
    movss   [rdi+rcx*4], xmm2
    inc     ecx
    cmp     ecx, 3
    jb      1b
    call    len3
    comiss  xmm0, [rip+gf_tiny]
    jbe     3f
    movss   xmm1, [rip+gf_one]
    divss   xmm1, xmm0
    xor     ecx, ecx
2:  movss   xmm0, [rdi+rcx*4]
    mulss   xmm0, xmm1
    movss   [rdi+rcx*4], xmm0
    inc     ecx
    cmp     ecx, 3
    jb      2b
3:  ret

# =============================================================================
#  Editing (callers have made the material block their own: mat_cow)
# =============================================================================
# graph_type_index(rdi=name) -> eax = type (1..) or -1
graph_type_index:
    lea     rsi, [rip+graph_type_names]
    jmp     name_index
# graph_socket_index(rdi=name) -> eax = socket (0..4) or -1
graph_socket_index:
    lea     rsi, [rip+graph_socket_names]
    call    name_index
    test    eax, eax
    js      1f
    dec     eax
1:  ret
# name_index(rdi=name, rsi=table) -> eax = 1-based position or -1
name_index:
    push    rbx
    push    r12
    push    r13
    mov     r12, rdi
    mov     r13, rsi
    xor     ebx, ebx
1:  mov     rsi, [r13+rbx*8]
    test    rsi, rsi
    jz      2f
    mov     rdi, r12
    call    str_eq
    test    eax, eax
    jnz     3f
    inc     ebx
    jmp     1b
2:  mov     eax, -1
    jmp     9f
3:  lea     eax, [rbx+1]
9:  pop     r13
    pop     r12
    pop     rbx
    ret

# own(edi=material) -> rax = its record, writable (0 if none)
graph_own:
own:
    push    rbx
    mov     ebx, edi
    call    mat_count
    cmp     ebx, eax
    jae     8f
    xor     edi, edi
    call    mat_cow
    test    rax, rax
    jz      8f
    mov     edi, ebx
    call    mat_get
    mov     dword ptr [rip+dirty], 1
    pop     rbx
    ret
8:  xor     eax, eax
    pop     rbx
    ret

# graph_add(edi=material, esi=type) -> eax = node number (1..12) or -1
graph_add:
    push    rbx
    push    r12
    sub     rsp, 8
    mov     r12d, esi
    lea     eax, [rsi-1]
    cmp     eax, NTYPES
    jae     8f
    call    own
    test    rax, rax
    jz      8f
    mov     rbx, rax
    mov     eax, [rbx+GR_N]
    cmp     eax, MAX_NODES
    jae     8f
    imul    ecx, eax, NODE_SZ
    lea     rdi, [rbx+GR_NODES+rcx]
    push    rdi
    xor     eax, eax                    # clear it
    mov     ecx, NODE_SZ/4
    rep     stosd
    pop     rdi
    mov     [rdi+ND_TYPE], r12d
    lea     eax, [r12-1]                # defaults: p0..p3, the inputs' values
    imul    eax, eax, 52
    lea     rsi, [rip+node_defaults]
    add     rsi, rax
    mov     rax, [rsi]
    mov     [rdi+ND_P], rax
    mov     rax, [rsi+8]
    mov     [rdi+ND_P+8], rax
    xor     ecx, ecx
1:  imul    edx, ecx, 16
    imul    r8d, ecx, 12
    mov     rax, [rsi+16+r8]
    mov     [rdi+ND_IN+rdx+4], rax
    mov     eax, [rsi+24+r8]
    mov     [rdi+ND_IN+rdx+12], eax
    inc     ecx
    cmp     ecx, 3
    jb      1b
    inc     dword ptr [rbx+GR_N]
    mov     eax, [rbx+GR_N]
    jmp     9f
8:  mov     eax, -1
9:  add     rsp, 8
    pop     r12
    pop     rbx
    ret

# graph_link(edi=material, esi=from node, edx=to node, ecx=input 1..3) -> eax = 1
graph_link:
    push    rbx
    push    r12
    push    r13
    push    r14
    sub     rsp, 8
    mov     r12d, esi
    mov     r13d, edx
    mov     r14d, ecx
    call    own
    test    rax, rax
    jz      8f
    mov     rbx, rax
    test    r12d, r12d                  # 1 <= from < to <= n, input 1..3
    jle     8f
    cmp     r12d, r13d
    jae     8f
    cmp     r13d, [rbx+GR_N]
    ja      8f
    lea     eax, [r14-1]
    cmp     eax, 3
    jae     8f
    lea     ecx, [r13-1]
    imul    ecx, ecx, NODE_SZ
    shl     eax, 4
    add     ecx, eax
    mov     [rbx+GR_NODES+rcx+ND_IN], r12d
    mov     eax, 1
    jmp     9f
8:  xor     eax, eax
9:  add     rsp, 8
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# graph_set(edi=material, esi=node, edx=slot 1..7, rcx=float[3] values,
#   r8d=how many) -> eax = 1. Slots 1-3 set an input's constant (and unlink
#   it), 4-7 the values p0..p3.
graph_set:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    mov     r12d, esi
    mov     r13d, edx
    mov     r14, rcx
    mov     r15d, r8d
    call    own
    test    rax, rax
    jz      8f
    mov     rbx, rax
    test    r12d, r12d
    jle     8f
    cmp     r12d, [rbx+GR_N]
    ja      8f
    lea     eax, [r12-1]
    imul    eax, eax, NODE_SZ
    lea     rdi, [rbx+GR_NODES+rax]
    lea     eax, [r13-1]
    cmp     eax, 3
    jae     2f
    shl     eax, 4                      # an input
    lea     rdi, [rdi+ND_IN+rax]
    mov     dword ptr [rdi], 0
    mov     eax, [r14]
    mov     [rdi+4], eax                # one value: all three
    mov     [rdi+8], eax
    mov     [rdi+12], eax
    cmp     r15d, 3
    jb      7f
    mov     eax, [r14+4]
    mov     [rdi+8], eax
    mov     eax, [r14+8]
    mov     [rdi+12], eax
    jmp     7f
2:  lea     eax, [r13-4]                # a value
    cmp     eax, 4
    jae     8f
    mov     ecx, [r14]
    mov     [rdi+ND_P+rax*4], ecx
7:  mov     eax, 1
    jmp     9f
8:  xor     eax, eax
9:  pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# graph_socket(edi=material, esi=pin (PIN_*), edx=node (0 = none), ecx=its
#   output 0..3) -> eax = 1
graph_socket:
    push    rbx
    push    r12
    push    r13
    mov     r12d, esi
    mov     r13d, edx
    mov     ebx, ecx
    call    own
    test    rax, rax
    jz      8f
    cmp     r12d, NPINS
    jae     8f
    cmp     r13d, [rax+GR_N]
    ja      8f
    test    r13d, r13d
    js      8f
    jz      1f
    cmp     ebx, NOUTS
    jae     8f
    shl     ebx, 16
    or      r13d, ebx
1:  mov     [rax+GR_PINS+r12*4], r13d
    mov     eax, 1
    jmp     9f
8:  xor     eax, eax
9:  pop     r13
    pop     r12
    pop     rbx
    ret

# graph_info(edi=material, esi=node, edx=what, ecx=k) -> eax: what 0 the
#   node count, 1 the node's type, 2 the node feeding its input k (1..3;
#   0: none), 3 the node driving pin k (PIN_*), 4 its x, 5 its y (node 0:
#   the output), 6 the output (0..) feeding input k, 7 the output driving
#   pin k - -1 when there is no such thing
graph_info:
    push    rbx
    push    r12
    push    r13
    push    r14
    sub     rsp, 8
    mov     r12d, esi
    mov     r13d, edx
    mov     r14d, ecx
    call    mat_count
    cmp     edi, eax
    mov     eax, -1
    jae     9f
    call    mat_get
    test    rax, rax
    jz      8f
    mov     rbx, rax
    mov     eax, [rbx+GR_N]
    test    r13d, r13d
    jz      9f
    cmp     r13d, 3
    je      86f
    cmp     r13d, 7
    jne     1f
86: cmp     r14d, NPINS
    jae     8f
    mov     eax, [rbx+GR_PINS+r14*4]
    cmp     r13d, 7
    je      87f
    movzx   eax, ax
    jmp     9f
87: shr     eax, 16
    jmp     9f
1:  lea     rdx, [rbx+GR_OUTPOS]        # the node (0: the output)
    test    r12d, r12d
    jz      2f
    js      8f
    cmp     r12d, [rbx+GR_N]
    ja      8f
    lea     ecx, [r12-1]
    imul    ecx, ecx, NODE_SZ
    lea     rdx, [rbx+GR_NODES+rcx]
    cmp     r13d, 1
    jne     11f
    mov     eax, [rdx+ND_TYPE]
    jmp     9f
11: cmp     r13d, 2
    je      111f
    cmp     r13d, 6
    jne     12f
111:lea     eax, [r14-1]
    cmp     eax, 3
    jae     8f
    shl     eax, 4
    mov     eax, [rdx+ND_IN+rax]
    cmp     r13d, 6
    je      112f
    movzx   eax, ax
    jmp     9f
112:shr     eax, 16
    jmp     9f
12: add     rdx, ND_POS
2:  cmp     r13d, 4
    jne     3f
    movsx   eax, word ptr [rdx]
    jmp     9f
3:  cmp     r13d, 5
    jne     8f
    movsx   eax, word ptr [rdx+2]
    jmp     9f
8:  mov     eax, -1
9:  add     rsp, 8
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# graph_value(edi=material, esi=node, edx=value 1..4) -> xmm0 (0 if none)
graph_value:
    push    rbx
    push    r12
    push    r13
    mov     r12d, esi
    mov     r13d, edx
    xorps   xmm0, xmm0
    call    mat_count
    cmp     edi, eax
    jae     9f
    call    mat_get
    test    rax, rax
    jz      9f
    test    r12d, r12d
    jle     9f
    cmp     r12d, [rax+GR_N]
    ja      9f
    lea     ecx, [r13-1]
    cmp     ecx, 4
    jae     9f
    lea     edx, [r12-1]
    imul    edx, edx, NODE_SZ
    add     rax, rdx
    movss   xmm0, [rax+GR_NODES+ND_P+rcx*4]
9:  pop     r13
    pop     r12
    pop     rbx
    ret

# graph_sort(rdi=record) -> eax = 1: the nodes in evaluation order (every
#   link from an earlier node; among the ready ones the lowest first), links
#   and sockets renumbered; 0: a loop (nothing changed)
graph_sort:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    sub     rsp, NODE_SZ*MAX_NODES+128
    mov     rbx, rdi
    mov     r12d, [rbx+GR_N]
    lea     rdi, [rsp]                  # placed: [rsp + 0..47], new index
    mov     ecx, 64                     #  of each old one: [rsp + 64..]
    xor     eax, eax
    rep     stosb
    xor     r13d, r13d                  # placed so far
.Lgsrt_round:
    cmp     r13d, r12d
    jae     .Lgsrt_permute
    xor     r14d, r14d                  # the lowest ready one
1:  cmp     r14d, r12d
    jae     .Lgsrt_loop
    cmp     byte ptr [rsp+r14], 0
    jne     3f
    imul    eax, r14d, NODE_SZ
    lea     rdx, [rbx+GR_NODES+rax+ND_IN]
    xor     ecx, ecx
2:  movzx   eax, word ptr [rdx]
    test    eax, eax
    jz      21f
    dec     eax
    cmp     eax, r12d
    jae     21f
    cmp     byte ptr [rsp+rax], 0       # (an input not placed yet)
    je      3f
21: add     rdx, 16
    inc     ecx
    cmp     ecx, 3
    jb      2b
    mov     byte ptr [rsp+r14], 1       # ready: next in order
    mov     [rsp+64+r14], r13b
    inc     r13d
    jmp     .Lgsrt_round
3:  inc     r14d
    jmp     1b
.Lgsrt_loop:
    xor     eax, eax
    jmp     .Lgsrt_out
.Lgsrt_permute:
    lea     rsi, [rbx+GR_NODES]         # a copy, then each to its place
    lea     rdi, [rsp+128]
    imul    ecx, r12d, NODE_SZ
    rep     movsb
    xor     r14d, r14d
4:  cmp     r14d, r12d
    jae     6f
    movzx   eax, byte ptr [rsp+64+r14]
    imul    eax, eax, NODE_SZ
    lea     rdi, [rbx+GR_NODES+rax]
    imul    eax, r14d, NODE_SZ
    lea     rsi, [rsp+128+rax]
    mov     ecx, NODE_SZ
    rep     movsb
    inc     r14d
    jmp     4b
6:  xor     r14d, r14d                  # links renumbered
7:  cmp     r14d, r12d
    jae     8f
    imul    eax, r14d, NODE_SZ
    lea     rdx, [rbx+GR_NODES+rax+ND_IN]
    xor     ecx, ecx
71: movzx   eax, word ptr [rdx]
    test    eax, eax
    jz      72f
    dec     eax
    movzx   eax, byte ptr [rsp+64+rax]
    inc     eax
    mov     [rdx], ax
72: add     rdx, 16
    inc     ecx
    cmp     ecx, 3
    jb      71b
    inc     r14d
    jmp     7b
8:  xor     ecx, ecx                    # and the pins
81: movzx   eax, word ptr [rbx+GR_PINS+rcx*4]
    test    eax, eax
    jz      82f
    dec     eax
    movzx   eax, byte ptr [rsp+64+rax]
    inc     eax
    mov     [rbx+GR_PINS+rcx*4], ax
82: inc     ecx
    cmp     ecx, NPINS
    jb      81b
    mov     eax, 1
.Lgsrt_out:
    add     rsp, NODE_SZ*MAX_NODES+128
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# graph_link_any(edi=material, esi=from, edx=to, ecx=input 1..3, r8d=from's
#   output 0..3) -> eax = the node fed, renumbered (0: no such nodes, or the
#   link would make a loop - nothing changed)
graph_link_any:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    push    rbp
    sub     rsp, 8
    mov     ebp, r8d
    mov     r12d, esi
    mov     r13d, edx
    mov     r14d, ecx
    call    own
    test    rax, rax
    jz      8f
    mov     rbx, rax
    test    r12d, r12d
    jle     8f
    test    r13d, r13d
    jle     8f
    cmp     r12d, r13d
    je      8f
    cmp     r12d, [rbx+GR_N]
    ja      8f
    cmp     r13d, [rbx+GR_N]
    ja      8f
    lea     eax, [r14-1]
    cmp     eax, 3
    jae     8f
    lea     ecx, [r13-1]
    imul    ecx, ecx, NODE_SZ
    shl     eax, 4
    add     ecx, eax
    lea     r15, [rbx+GR_NODES+rcx+ND_IN]
    cmp     ebp, NOUTS
    jae     8f
    mov     eax, [r15]                  # (kept to put back)
    push    rax
    push    rax
    mov     eax, ebp
    shl     eax, 16
    or      eax, r12d
    mov     [r15], eax
    lea     ecx, [r13-1]                # the fed node marked to find it after
    imul    ecx, ecx, NODE_SZ
    or      dword ptr [rbx+GR_NODES+rcx+ND_TYPE], 0x80000000
    mov     rdi, rbx
    call    graph_sort
    test    eax, eax
    jnz     1f
    pop     rax                         # a loop: back as it was
    pop     rax
    mov     [r15], eax
    lea     ecx, [r13-1]
    imul    ecx, ecx, NODE_SZ
    and     dword ptr [rbx+GR_NODES+rcx+ND_TYPE], 0x7fffffff
    jmp     8f
1:  pop     rax
    pop     rax
    xor     ecx, ecx                    # where the fed node went
2:  imul    edx, ecx, NODE_SZ
    test    dword ptr [rbx+GR_NODES+rdx+ND_TYPE], 0x80000000
    jnz     3f
    inc     ecx
    cmp     ecx, [rbx+GR_N]
    jb      2b
    jmp     8f
3:  and     dword ptr [rbx+GR_NODES+rdx+ND_TYPE], 0x7fffffff
    lea     eax, [rcx+1]
    jmp     9f
8:  xor     eax, eax
9:  add     rsp, 8
    pop     rbp
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# graph_delete(edi=material, esi=node) -> eax = 1: the node gone, the
#   later ones one down, links and sockets to it unplugged
graph_delete:
    push    rbx
    push    r12
    sub     rsp, 8
    mov     r12d, esi
    call    own
    test    rax, rax
    jz      8f
    mov     rbx, rax
    test    r12d, r12d
    jle     8f
    cmp     r12d, [rbx+GR_N]
    ja      8f
    imul    eax, r12d, NODE_SZ          # the later ones down
    lea     rsi, [rbx+GR_NODES+rax]
    lea     rdi, [rsi-NODE_SZ]
    mov     ecx, [rbx+GR_N]
    sub     ecx, r12d
    imul    ecx, ecx, NODE_SZ
    rep     movsb
    dec     dword ptr [rbx+GR_N]
    mov     edi, [rbx+GR_N]             # (the last record cleared)
    imul    edi, edi, NODE_SZ
    lea     rdi, [rbx+GR_NODES+rdi]
    xor     eax, eax
    mov     ecx, NODE_SZ
    rep     stosb
    xor     ecx, ecx
1:  cmp     ecx, [rbx+GR_N]
    jae     4f
    imul    eax, ecx, NODE_SZ
    lea     rdx, [rbx+GR_NODES+rax+ND_IN]
    xor     r8d, r8d
2:  movzx   eax, word ptr [rdx]
    cmp     eax, r12d
    jb      3f
    jne     21f
    mov     dword ptr [rdx], 0          # fed by it: its constant again
    jmp     3f
21: dec     word ptr [rdx]
3:  add     rdx, 16
    inc     r8d
    cmp     r8d, 3
    jb      2b
    inc     ecx
    jmp     1b
4:  xor     ecx, ecx
5:  movzx   eax, word ptr [rbx+GR_PINS+rcx*4]
    cmp     eax, r12d
    jb      7f
    jne     6f
    mov     dword ptr [rbx+GR_PINS+rcx*4], 0
    jmp     7f
6:  dec     word ptr [rbx+GR_PINS+rcx*4]
7:  inc     ecx
    cmp     ecx, NPINS
    jb      5b
    mov     eax, 1
    jmp     9f
8:  xor     eax, eax
9:  add     rsp, 8
    pop     r12
    pop     rbx
    ret

# graph_clear(edi=material) -> eax = 1
graph_clear:
    sub     rsp, 8
    call    own
    test    rax, rax
    jz      8f
    lea     rdi, [rax+GR_N]
    xor     eax, eax
    mov     ecx, (MA_SZ-GR_N)/4
    rep     stosd
    mov     eax, 1
    add     rsp, 8
    ret
8:  xor     eax, eax
    add     rsp, 8
    ret

# =============================================================================
#  Operators
# =============================================================================
# next_word(rsi=text) -> gw_word = the next word, rsi after it, eax = length
next_word:
    lea     rdi, [rip+gw_word]
    xor     ecx, ecx
    test    rsi, rsi
    jz      3f
1:  cmp     byte ptr [rsi], ' '
    jne     2f
    inc     rsi
    jmp     1b
2:  mov     al, [rsi]
    test    al, al
    jz      3f
    cmp     al, ' '
    je      3f
    cmp     ecx, 62
    jae     21f
    mov     [rdi+rcx], al
    inc     ecx
21: inc     rsi
    jmp     2b
3:  mov     byte ptr [rdi+rcx], 0
    mov     eax, ecx
    ret

# arg_mat(rsi=text) -> eax = material (or -1, logged), rsi after the name
arg_mat:
    call    next_word
    push    rsi
    lea     rdi, [rip+gw_word]
    call    mat_find
    pop     rsi
    test    eax, eax
    jns     1f
    push    rax
    lea     rdi, [rip+s_g_unknown]
    lea     rsi, [rip+gw_word]
    call    log_pair
    pop     rax
1:  ret

# arg_num(rsi=text) -> xmm0, eax = 1 if a number, rsi after it
arg_num:
    lea     rdx, [rsi+64]
    jmp     parse_float

# say(edi=node) - "graph: node N"
say_node:
    push    rbx
    mov     ebx, edi
    call    fmt_reset
    lea     rdi, [rip+s_g_ok]
    call    fmt_str
    lea     rdi, [rip+s_g_node]
    add     rdi, 2
    call    fmt_str
    mov     edi, ebx
    call    fmt_int
    lea     rdi, [rip+fmt_buf]
    call    log_line
    pop     rbx
    ret

# material.node <material> <type> [values...]  (image: <image> [size])
do_mat_node:
    push    rbx
    push    r12
    push    r13
    push    r14
    sub     rsp, 40
    mov     rsi, [rip+op_arg]
    call    arg_mat
    test    eax, eax
    js      .Lmn_drop
    mov     r12d, eax
    call    next_word
    mov     r13, rsi
    lea     rdi, [rip+gw_word]
    call    graph_type_index
    test    eax, eax
    js      .Lmn_need
    mov     r14d, eax
    mov     edi, r12d
    mov     esi, eax
    call    graph_add
    test    eax, eax
    js      .Lmn_full
    mov     ebx, eax
    cmp     r14d, T_IMAGE               # image: a name first
    jne     2f
    mov     rsi, r13
    call    next_word
    mov     r13, rsi
    test    eax, eax
    jz      2f
    lea     rdi, [rip+gw_word]
    call    image_find
    test    eax, eax
    js      .Lmn_noimage
    inc     eax
    cvtsi2ss xmm0, eax
    movss   [rsp], xmm0
    mov     edi, r12d
    mov     esi, ebx
    mov     edx, 4
    lea     rcx, [rsp]
    mov     r8d, 1
    call    graph_set
    mov     dword ptr [rsp+32], 5       # then the size: p1
    jmp     3f
2:  mov     dword ptr [rsp+32], 4       # values from p0
3:  mov     rsi, r13
    call    arg_num
    test    eax, eax
    jz      4f
    mov     r13, rsi
    movss   [rsp], xmm0
    mov     edi, r12d
    mov     esi, ebx
    mov     edx, [rsp+32]
    lea     rcx, [rsp]
    mov     r8d, 1
    call    graph_set
    inc     dword ptr [rsp+32]
    cmp     dword ptr [rsp+32], 8
    jb      3b
4:  mov     edi, ebx
    call    say_node
    jmp     9f
.Lmn_noimage:
    lea     rdi, [rip+s_g_noimage]
    lea     rsi, [rip+gw_word]
    call    log_pair
    jmp     .Lmn_drop
.Lmn_full:
    lea     rdi, [rip+s_g_full]
    call    log_line
    jmp     .Lmn_drop
.Lmn_need:
    lea     rdi, [rip+s_g_need]
    call    log_line
.Lmn_drop:
    call    undo_drop_last
9:  add     rsp, 40
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# material.link <material> <from> <to> <input>
do_mat_link:
    push    rbx
    push    r12
    sub     rsp, 24
    mov     rsi, [rip+op_arg]
    call    arg_mat
    test    eax, eax
    js      .Lml_drop
    mov     r12d, eax
    xor     ebx, ebx
1:  push    rbx
    call    arg_num
    pop     rbx
    test    eax, eax
    jz      .Lml_need
    cvttss2si eax, xmm0
    mov     [rsp+rbx*4], eax
    inc     ebx
    cmp     ebx, 3
    jb      1b
    xor     eax, eax                    # [output 0..]: 0 based
    mov     [rsp+12], eax
    call    arg_num
    test    eax, eax
    jz      2f
    cvttss2si eax, xmm0
    test    eax, eax
    js      .Lml_need
    mov     [rsp+12], eax
2:  mov     edi, r12d
    mov     esi, [rsp]
    mov     edx, [rsp+4]
    mov     ecx, [rsp+8]
    mov     r8d, [rsp+12]
    call    graph_link_any
    test    eax, eax
    jz      .Lml_need
    mov     edi, eax
    call    say_node
    jmp     9f
.Lml_need:
    lea     rdi, [rip+s_g_linkneed]
    call    log_line
.Lml_drop:
    call    undo_drop_last
9:  add     rsp, 24
    pop     r12
    pop     rbx
    ret

# material.node_set <material> <node> <slot> <x> [y z]
do_mat_node_set:
    push    rbx
    push    r12
    push    r13
    sub     rsp, 32
    mov     rsi, [rip+op_arg]
    call    arg_mat
    test    eax, eax
    js      .Lmv_drop
    mov     r12d, eax
    call    arg_num
    test    eax, eax
    jz      .Lmv_need
    cvttss2si r13d, xmm0                # node
    call    arg_num
    test    eax, eax
    jz      .Lmv_need
    cvttss2si eax, xmm0
    mov     [rsp+16], eax               # slot
    xor     ebx, ebx
1:  push    rbx
    call    arg_num
    pop     rbx
    test    eax, eax
    jz      2f
    movss   [rsp+rbx*4], xmm0
    inc     ebx
    cmp     ebx, 3
    jb      1b
2:  test    ebx, ebx
    jz      .Lmv_need
    mov     edi, r12d
    mov     esi, r13d
    mov     edx, [rsp+16]
    lea     rcx, [rsp]
    mov     r8d, ebx
    call    graph_set
    test    eax, eax
    jz      .Lmv_need
    mov     edi, r13d
    call    say_node
    jmp     9f
.Lmv_need:
    lea     rdi, [rip+s_g_setneed]
    call    log_line
.Lmv_drop:
    call    undo_drop_last
9:  add     rsp, 32
    pop     r13
    pop     r12
    pop     rbx
    ret

# material.socket <material> <socket> <node|none>
do_mat_socket:
    push    rbx
    push    r12
    sub     rsp, 8
    mov     rsi, [rip+op_arg]
    call    arg_mat
    test    eax, eax
    js      .Lmk_drop
    mov     r12d, eax
    call    next_word
    push    rsi
    lea     rdi, [rip+gw_word]
    call    graph_socket_index
    pop     rsi
    test    eax, eax
    js      .Lmk_need
    mov     ebx, eax
    call    next_word
    mov     [rsp], rsi                  # (the text after it)
    xor     edx, edx                    # none: 0
    lea     rdi, [rip+gw_word]
    push    rsi
    lea     rsi, [rip+s_g_none]
    call    str_eq
    pop     rsi
    test    eax, eax
    jnz     1f
    lea     rsi, [rip+gw_word]
    call    arg_num
    test    eax, eax
    jz      .Lmk_need
    cvttss2si edx, xmm0
1:  mov     rsi, [rsp]                  # [output 0..]
    push    rdx
    call    arg_num
    pop     rdx
    xor     ecx, ecx
    test    eax, eax
    jz      11f
    cvttss2si ecx, xmm0
    test    ecx, ecx
    js      .Lmk_need
11: mov     edi, r12d
    mov     esi, ebx
    call    graph_socket
    test    eax, eax
    jz      .Lmk_need
    lea     rdi, [rip+s_g_ok]
    lea     rax, [rip+graph_socket_names]
    mov     rsi, [rax+rbx*8]
    call    log_pair
    jmp     9f
.Lmk_need:
    lea     rdi, [rip+s_g_sockneed]
    call    log_line
.Lmk_drop:
    call    undo_drop_last
9:  add     rsp, 8
    pop     r12
    pop     rbx
    ret

# material.node_delete <material> <node>
do_mat_node_delete:
    sub     rsp, 24
    mov     rsi, [rip+op_arg]
    call    arg_mat
    test    eax, eax
    js      8f
    mov     [rsp], eax
    call    arg_num
    test    eax, eax
    jz      7f
    cvttss2si esi, xmm0
    mov     edi, [rsp]
    call    graph_delete
    test    eax, eax
    jz      7f
    add     rsp, 24
    ret
7:  lea     rdi, [rip+s_g_delneed]
    call    log_line
8:  call    undo_drop_last
    add     rsp, 24
    ret

# material.node_move <material> <node (0: output)> <x> <y>
do_mat_node_move:
    push    rbx
    sub     rsp, 16
    mov     rsi, [rip+op_arg]
    call    arg_mat
    test    eax, eax
    js      8f
    mov     [rsp], eax
    call    arg_num
    test    eax, eax
    jz      7f
    cvttss2si ebx, xmm0
    call    arg_num
    test    eax, eax
    jz      7f
    cvttss2si eax, xmm0
    mov     [rsp+4], eax
    call    arg_num
    test    eax, eax
    jz      7f
    cvttss2si eax, xmm0
    mov     [rsp+8], eax
    mov     edi, [rsp]
    mov     esi, ebx
    mov     edx, [rsp+4]
    mov     ecx, [rsp+8]
    call    graph_place
    test    eax, eax
    jz      7f
    add     rsp, 16
    pop     rbx
    ret
7:  lea     rdi, [rip+s_g_moveneed]
    call    log_line
8:  call    undo_drop_last
    add     rsp, 16
    pop     rbx
    ret

# graph_place(edi=material, esi=node (0: the output), edx=x, ecx=y) -> eax = 1
.globl graph_place
graph_place:
    push    rbx
    push    r12
    push    r13
    mov     ebx, esi
    mov     r12d, edx
    mov     r13d, ecx
    call    own
    test    rax, rax
    jz      8f
    test    r12w, r12w                  # ((0, 0) means not placed)
    jnz     1f
    test    r13w, r13w
    jnz     1f
    mov     r13d, 1
1:  lea     rdx, [rax+GR_OUTPOS]
    test    ebx, ebx
    jz      2f
    js      8f
    cmp     ebx, [rax+GR_N]
    ja      8f
    lea     ecx, [rbx-1]
    imul    ecx, ecx, NODE_SZ
    lea     rdx, [rax+GR_NODES+rcx+ND_POS]
2:  mov     [rdx], r12w
    mov     [rdx+2], r13w
    mov     eax, 1
    jmp     9f
8:  xor     eax, eax
9:  pop     r13
    pop     r12
    pop     rbx
    ret

# material.nodes_clear <material>
do_mat_nodes_clear:
    sub     rsp, 8
    mov     rsi, [rip+op_arg]
    call    arg_mat
    test    eax, eax
    js      1f
    mov     edi, eax
    call    graph_clear
    lea     rdi, [rip+s_g_ok]
    lea     rsi, [rip+s_g_none]
    call    log_pair
    add     rsp, 8
    ret
1:  call    undo_drop_last
    add     rsp, 8
    ret

.section .note.GNU-stack,"",@progbits
