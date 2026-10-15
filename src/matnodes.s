# =============================================================================
#  BeeModel - material nodes: the node catalogue and the newer evaluators
#
#  The material graph's node types (graph.s keeps the first nine and the
#  evaluation loop): their script names, titles, inputs, values, outputs,
#  defaults, header colours and categories - one row each, read by the node
#  editor, scripts and agents - and the evaluation of types 10 onwards:
#
#    inputs   texture coordinate (tiling, offset), position (object or
#             world), normal, camera vector, vertex colour, time, constant,
#             colour, Fresnel
#    vector   vector math (20 operations), separate, combine, mapping,
#             panner, rotator
#    texture  Voronoi (F1, F2, edge; the cell's colour), brick, wave, white
#             noise, triplanar image sampling
#    colour   hue / saturation / value, invert, brightness / contrast,
#             desaturation, gamma, blackbody
#
#  math_op is the Math node's scalar operation (31 of them: arithmetic,
#  trigonometry, rounding, clamp, lerp, step, smoothstep ...), shared with
#  vector math. Unlinked vector inputs mean the point's own coordinates
#  where a texture would use them (UV for 2D patterns and panners, the
#  object position for 3D ones).
# =============================================================================
.intel_syntax noprefix
.include "const.inc"

.globl graph_type_names
.globl graph_ntypes
.globl mn_titles
.globl mn_meta
.globl mn_color
.globl mn_cat
.globl mn_cat_names
.globl mn_defaults
.globl mn_eval
.globl math_op

.equ ND_TYPE,   0
.equ ND_IN,     4
.equ ND_P,      52
.equ SC_N,      68                      # (graph.s: the shading context)
.equ SC_FLAGS,  112
.equ SC_WP,     152
.equ SC_WV,     164
.equ SC_VC,     176
.equ SCF_VCOL,  0x80000000              # the graph reads the vertex colour
.equ EV_P,      0
.equ EV_UV,     12
.equ EV_SC,     32
.equ MN_NTYPES, 42                      # (the node list below: checked there)

.section .rodata
.align 16
mf_abs:         .long 0x7fffffff, 0x7fffffff, 0x7fffffff, 0x7fffffff
mf_sign:        .long 0x80000000, 0, 0, 0
mf_one:         .float 1.0
mf_half:        .float 0.5
mf_zero:        .float 0.0
mf_two:         .float 2.0
mf_three:       .float 3.0
mf_six:         .float 6.0
mf_tiny:        .float 1.0e-12
mf_eps:         .float 1.0e-6
mf_deg:         .float 0.017453293
mf_2pi:         .float 6.2831853
mf_inv24:       .float 4.656613e-10         # 2^-31 (hash -> 0..1)
mf_lum:         .float 0.2126, 0.7152, 0.0722
mf_big:         .float 1.0e30
mf_inv255:      .float 0.003921569
mf_hund:        .float 0.01
# blackbody (Tanner Helland's fit, in sRGB bytes)
bb_r1:          .float 329.698727446
bb_r2:          .float -0.1332047592
bb_g1:          .float 99.4708025861
bb_g2:          .float -161.1195681661
bb_g3:          .float 288.1221695283
bb_g4:          .float -0.0755148492
bb_b1:          .float 138.5177312231
bb_b2:          .float -305.0447927307
bb_66:          .float 66.0
bb_60:          .float 60.0
bb_19:          .float 19.0
bb_10:          .float 10.0
bb_255:         .float 255.0

.text

# =============================================================================
#  Scalar helpers (x87 where SSE has nothing)
# =============================================================================
# fexp2 - st0 = 2^st0
fexp2:
    fld     st(0)
    frndint
    fsub    st(1), st(0)
    fxch    st(1)
    f2xm1
    fld1
    faddp   st(1), st(0)
    fscale
    fstp    st(1)
    ret

# fpow(xmm0=a, xmm1=b) -> xmm0 = a^b (a <= 0: 0)
fpow:
    xorps   xmm2, xmm2
    comiss  xmm0, xmm2
    jbe     8f
    sub     rsp, 24
    movss   [rsp], xmm0
    movss   [rsp+4], xmm1
    fld     dword ptr [rsp+4]
    fld     dword ptr [rsp]
    fyl2x
    call    fexp2
    fstp    dword ptr [rsp]
    movss   xmm0, [rsp]
    add     rsp, 24
    ret
8:  xorps   xmm0, xmm0
    ret

# floorss(xmm0) -> xmm0 = floor
floorss:
    roundss xmm0, xmm0, 1
    ret

# =============================================================================
#  math_op(eax=operation, xmm0=a, xmm1=b, xmm2=c) -> xmm0
# =============================================================================
math_op:
    sub     rsp, 40
    movss   [rsp], xmm0
    movss   [rsp+4], xmm1
    movss   [rsp+8], xmm2
    cmp     eax, 30
    ja      .Lmo_a
    lea     rcx, [rip+mo_jump]
    movsxd  rax, dword ptr [rcx+rax*4]
    add     rax, rcx
    jmp     rax
mo_jump:
    .long .Lmo_add-mo_jump, .Lmo_sub-mo_jump, .Lmo_mul-mo_jump, .Lmo_div-mo_jump
    .long .Lmo_pow-mo_jump, .Lmo_min-mo_jump, .Lmo_max-mo_jump, .Lmo_gt-mo_jump
    .long .Lmo_sin-mo_jump, .Lmo_abs-mo_jump, .Lmo_cos-mo_jump, .Lmo_tan-mo_jump
    .long .Lmo_sqrt-mo_jump, .Lmo_floor-mo_jump, .Lmo_ceil-mo_jump, .Lmo_frac-mo_jump
    .long .Lmo_round-mo_jump, .Lmo_sign-mo_jump, .Lmo_omin-mo_jump, .Lmo_sat-mo_jump
    .long .Lmo_clamp-mo_jump, .Lmo_lerp-mo_jump, .Lmo_step-mo_jump, .Lmo_sstep-mo_jump
    .long .Lmo_mod-mo_jump, .Lmo_exp-mo_jump, .Lmo_log-mo_jump, .Lmo_atan2-mo_jump
    .long .Lmo_lt-mo_jump, .Lmo_neg-mo_jump, .Lmo_madd-mo_jump
.Lmo_add:
    addss   xmm0, xmm1
    jmp     .Lmo_out
.Lmo_sub:
    subss   xmm0, xmm1
    jmp     .Lmo_out
.Lmo_mul:
    mulss   xmm0, xmm1
    jmp     .Lmo_out
.Lmo_div:
    movaps  xmm2, xmm1
    andps   xmm2, [rip+mf_abs]
    comiss  xmm2, [rip+mf_tiny]
    jbe     .Lmo_zero
    divss   xmm0, xmm1
    jmp     .Lmo_out
.Lmo_pow:
    call    fpow
    jmp     .Lmo_out
.Lmo_min:
    minss   xmm0, xmm1
    jmp     .Lmo_out
.Lmo_max:
    maxss   xmm0, xmm1
    jmp     .Lmo_out
.Lmo_gt:
    comiss  xmm0, xmm1
    ja      .Lmo_one
    jmp     .Lmo_zero
.Lmo_lt:
    comiss  xmm0, xmm1
    jb      .Lmo_one
    jmp     .Lmo_zero
.Lmo_sin:
    fld     dword ptr [rsp]
    fsin
    jmp     .Lmo_x87
.Lmo_cos:
    fld     dword ptr [rsp]
    fcos
    jmp     .Lmo_x87
.Lmo_tan:
    fld     dword ptr [rsp]
    fptan
    fstp    st(0)
    jmp     .Lmo_x87
.Lmo_abs:
    andps   xmm0, [rip+mf_abs]
    jmp     .Lmo_out
.Lmo_sqrt:
    maxss   xmm0, [rip+mf_zero]
    sqrtss  xmm0, xmm0
    jmp     .Lmo_out
.Lmo_floor:
    roundss xmm0, xmm0, 1
    jmp     .Lmo_out
.Lmo_ceil:
    roundss xmm0, xmm0, 2
    jmp     .Lmo_out
.Lmo_frac:
    roundss xmm1, xmm0, 1
    subss   xmm0, xmm1
    jmp     .Lmo_out
.Lmo_round:
    roundss xmm0, xmm0, 0
    jmp     .Lmo_out
.Lmo_sign:
    xorps   xmm1, xmm1
    comiss  xmm0, xmm1
    ja      .Lmo_one
    jb      1f
    jmp     .Lmo_zero
1:  movss   xmm0, [rip+mf_one]
    xorps   xmm0, [rip+mf_sign]
    jmp     .Lmo_out
.Lmo_omin:
    movss   xmm1, [rip+mf_one]
    subss   xmm1, xmm0
    movss   xmm0, xmm1
    jmp     .Lmo_out
.Lmo_sat:
    maxss   xmm0, [rip+mf_zero]
    minss   xmm0, [rip+mf_one]
    jmp     .Lmo_out
.Lmo_clamp:                             # clamp(a, b, c)
    maxss   xmm0, xmm1
    minss   xmm0, xmm2
    jmp     .Lmo_out
.Lmo_lerp:                              # a + (b - a) c
    subss   xmm1, xmm0
    mulss   xmm1, xmm2
    addss   xmm0, xmm1
    jmp     .Lmo_out
.Lmo_step:                              # b >= a: 1
    comiss  xmm1, xmm0
    jae     .Lmo_one
    jmp     .Lmo_zero
.Lmo_sstep:                             # t = sat((c - a) / (b - a)); t t (3 - 2 t)
    subss   xmm2, xmm0
    subss   xmm1, xmm0
    movaps  xmm3, xmm1
    andps   xmm3, [rip+mf_abs]
    comiss  xmm3, [rip+mf_tiny]
    jbe     .Lmo_zero
    divss   xmm2, xmm1
    maxss   xmm2, [rip+mf_zero]
    minss   xmm2, [rip+mf_one]
    movss   xmm0, [rip+mf_three]
    movss   xmm1, xmm2
    addss   xmm1, xmm1
    subss   xmm0, xmm1
    mulss   xmm0, xmm2
    mulss   xmm0, xmm2
    jmp     .Lmo_out
.Lmo_mod:                               # a - b trunc(a / b)
    movaps  xmm3, xmm1
    andps   xmm3, [rip+mf_abs]
    comiss  xmm3, [rip+mf_tiny]
    jbe     .Lmo_zero
    movss   xmm3, xmm0
    divss   xmm3, xmm1
    roundss xmm3, xmm3, 3
    mulss   xmm3, xmm1
    subss   xmm0, xmm3
    jmp     .Lmo_out
.Lmo_exp:                               # 2^(a log2 e)
    fld     dword ptr [rsp]
    fldl2e
    fmulp   st(1), st(0)
    call    fexp2
    jmp     .Lmo_x87
.Lmo_log:                               # ln a (a <= 0: 0)
    xorps   xmm1, xmm1
    comiss  xmm0, xmm1
    jbe     .Lmo_zero
    fldln2
    fld     dword ptr [rsp]
    fyl2x
    jmp     .Lmo_x87
.Lmo_atan2:                             # atan2(a, b)
    fld     dword ptr [rsp]
    fld     dword ptr [rsp+4]
    fpatan
    jmp     .Lmo_x87
.Lmo_neg:
    xorps   xmm0, [rip+mf_sign]
    jmp     .Lmo_out
.Lmo_madd:                              # a b + c
    mulss   xmm0, xmm1
    addss   xmm0, xmm2
    jmp     .Lmo_out
.Lmo_x87:
    fstp    dword ptr [rsp+16]
    movss   xmm0, [rsp+16]
    jmp     .Lmo_out
.Lmo_one:
    movss   xmm0, [rip+mf_one]
    jmp     .Lmo_out
.Lmo_zero:
    xorps   xmm0, xmm0
    jmp     .Lmo_out
.Lmo_a:
    movss   xmm0, [rsp]
.Lmo_out:
    add     rsp, 40
    ret

# =============================================================================
#  Hashing (Voronoi, bricks, white noise)
# =============================================================================
# ihash(eax) -> eax mixed (murmur's finaliser)
ihash:
    mov     ecx, eax
    shr     ecx, 16
    xor     eax, ecx
    imul    eax, eax, 0x85ebca6b
    mov     ecx, eax
    shr     ecx, 13
    xor     eax, ecx
    imul    eax, eax, 0xc2b2ae35
    mov     ecx, eax
    shr     ecx, 16
    xor     eax, ecx
    ret

# hash3i(edi, esi, edx = cell) -> eax
hash3i:
    imul    eax, edi, 73856093
    imul    esi, esi, 19349663
    xor     eax, esi
    imul    edx, edx, 83492791
    xor     eax, edx
    jmp     ihash

# h01(eax) -> xmm0 in 0..1, eax mixed again (for the next one)
h01:
    call    ihash
    mov     ecx, eax
    shr     ecx, 1
    cvtsi2ss xmm0, ecx
    mulss   xmm0, [rip+mf_inv24]
    ret

# =============================================================================
#  mn_eval(eax=type; rbx=record, r12=node, r13=frame, r14d=its index) -
#  types 10 onwards (graph.s's helpers write the outputs)
# =============================================================================
.equ T_FIRST,   10
mn_eval:
    push    rbp
    push    r15
    sub     rsp, 136
    mov     rbp, [r13+EV_SC]
    sub     eax, T_FIRST
    cmp     eax, MN_NTYPES-T_FIRST+1
    jae     .Lmn_zero
    lea     rcx, [rip+mn_jump]
    movsxd  rax, dword ptr [rcx+rax*4]
    add     rax, rcx
    jmp     rax
mn_jump:
    .long .Lmn_texcoord-mn_jump, .Lmn_position-mn_jump, .Lmn_normal-mn_jump, .Lmn_camera-mn_jump
    .long .Lmn_vcolor-mn_jump, .Lmn_time-mn_jump, .Lmn_constant-mn_jump, .Lmn_color-mn_jump
    .long .Lmn_fresnel-mn_jump, .Lmn_vmath-mn_jump, .Lmn_separate-mn_jump, .Lmn_combine-mn_jump
    .long .Lmn_mapping-mn_jump, .Lmn_panner-mn_jump, .Lmn_rotator-mn_jump, .Lmn_voronoi-mn_jump
    .long .Lmn_hsv-mn_jump, .Lmn_invert-mn_jump, .Lmn_brightcon-mn_jump, .Lmn_desat-mn_jump
    .long .Lmn_gamma-mn_jump, .Lmn_blackbody-mn_jump, .Lmn_brick-mn_jump, .Lmn_wave-mn_jump
    .long .Lmn_whitenoise-mn_jump, .Lmn_triplanar-mn_jump, .Lmn_reroute-mn_jump
    .long .Lmn_sparam-mn_jump, .Lmn_vparam-mn_jump, .Lmn_zero-mn_jump
    .long .Lmn_fninput-mn_jump, .Lmn_zero-mn_jump, .Lmn_fncall-mn_jump
.Lmn_zero:
    xorps   xmm0, xmm0
    call    gr_putv
.Lmn_out:
    add     rsp, 136
    pop     r15
    pop     rbp
    ret

# ---- small helpers for the node bodies ------------------------------------
# linked(ecx=input) -> ZF clear when linked
.macro LINKED k
    test    word ptr [r12+ND_IN+16*\k], 0xffff
.endm

# vec_out(rsi=float[3]) - output 0 = the vector (value: x), 1..3 = x y z
vec_out:
    push    rsi
    sub     rsp, 16
    mov     r15, rsi
    mov     dword ptr [rsp], 1
1:  mov     eax, [rsp]
    movss   xmm0, [r15+rax*4-4]
    movss   xmm1, xmm0
    movss   xmm2, xmm0
    movss   xmm3, xmm0
    mov     ecx, eax
    call    gr_out
    inc     dword ptr [rsp]
    cmp     dword ptr [rsp], 4
    jb      1b
    movss   xmm0, [r15]
    movss   xmm1, [r15+4]
    movss   xmm2, [r15+8]
    movss   xmm3, xmm0
    xor     ecx, ecx
    call    gr_out
    add     rsp, 16
    pop     rsi
    ret

# in_vec(ecx=input, edx=0: else the UV, 1: else the object position) ->
#   [rsi] float[3]: the linked vector, or the point's own
in_vec:
    push    rsi
    imul    eax, ecx, 16
    test    word ptr [r12+ND_IN+rax], 0xffff
    jz      1f
    call    gr_in
    pop     rsi
    movss   [rsi], xmm0
    movss   [rsi+4], xmm1
    movss   [rsi+8], xmm2
    ret
1:  pop     rsi
    test    edx, edx
    jnz     2f
    mov     rax, [r13+EV_UV]
    mov     [rsi], rax
    mov     dword ptr [rsi+8], 0
    ret
2:  mov     rax, [r13+EV_P]
    mov     [rsi], rax
    mov     eax, [r13+EV_P+8]
    mov     [rsi+8], eax
    ret

# scene_time -> xmm0 = seconds at the scene's frame
scene_time:
    call    an_range
    movss   xmm1, [rip+an_frame]
    subss   xmm1, [rip+mf_one]
    divss   xmm1, xmm0
    movss   xmm0, xmm1
    ret

# ---- inputs ----------------------------------------------------------------
.Lmn_texcoord:                          # (u tu + ou, v tv + ov)
    movss   xmm0, [r13+EV_UV]
    mulss   xmm0, [r12+ND_P]
    addss   xmm0, [r12+ND_P+8]
    movss   [rsp], xmm0
    movss   xmm0, [r13+EV_UV+4]
    mulss   xmm0, [r12+ND_P+4]
    addss   xmm0, [r12+ND_P+12]
    movss   [rsp+4], xmm0
    mov     dword ptr [rsp+8], 0
    lea     rsi, [rsp]
    call    vec_out
    jmp     .Lmn_out

.Lmn_position:                          # object or world
    lea     rsi, [r13+EV_P]
    cmp     dword ptr [r12+ND_P], 0x3f000000
    jl      1f
    lea     rsi, [rbp+SC_WP]
1:  call    vec_out
    jmp     .Lmn_out

.Lmn_normal:
    lea     rsi, [rbp+SC_N]
    call    vec_out
    jmp     .Lmn_out

.Lmn_camera:
    lea     rsi, [rbp+SC_WV]
    call    vec_out
    jmp     .Lmn_out

.Lmn_vcolor:
    or      dword ptr [rbp+SC_FLAGS], SCF_VCOL  # (no tint after the graph)
    movss   xmm0, [rbp+SC_VC]
    movss   xmm1, [rbp+SC_VC+4]
    movss   xmm2, [rbp+SC_VC+8]
    call    gr_put
    jmp     .Lmn_out

.Lmn_time:
    call    scene_time
    mulss   xmm0, [r12+ND_P]
    call    gr_putv
    jmp     .Lmn_out

.Lmn_constant:
    movss   xmm0, [r12+ND_P]
    call    gr_putv
    jmp     .Lmn_out

.Lmn_color:
    xor     ecx, ecx
    call    gr_in
    call    gr_put
    jmp     .Lmn_out

.Lmn_fresnel:                           # base + (1 - base)(1 - n.v)^exp
    lea     rsi, [rbp+SC_N]
    LINKED  0
    jz      1f
    xor     ecx, ecx
    call    gr_in
    movss   [rsp], xmm0
    movss   [rsp+4], xmm1
    movss   [rsp+8], xmm2
    lea     rdi, [rsp]
    call    unit3m
    lea     rsi, [rsp]
1:  movss   xmm0, [rsi]
    mulss   xmm0, [rbp+SC_WV]
    movss   xmm1, [rsi+4]
    mulss   xmm1, [rbp+SC_WV+4]
    addss   xmm0, xmm1
    movss   xmm1, [rsi+8]
    mulss   xmm1, [rbp+SC_WV+8]
    addss   xmm0, xmm1
    andps   xmm0, [rip+mf_abs]          # (either side)
    minss   xmm0, [rip+mf_one]
    movss   xmm1, [rip+mf_one]
    subss   xmm1, xmm0
    movss   xmm0, xmm1
    movss   xmm1, [r12+ND_P]
    call    fpow
    movss   xmm1, [rip+mf_one]
    subss   xmm1, [r12+ND_P+4]
    mulss   xmm0, xmm1
    addss   xmm0, [r12+ND_P+4]
    call    gr_putv
    jmp     .Lmn_out

# unit3m(rdi=v[3]) - normalised (0 stays 0)
unit3m:
    movss   xmm0, [rdi]
    mulss   xmm0, xmm0
    movss   xmm1, [rdi+4]
    mulss   xmm1, xmm1
    addss   xmm0, xmm1
    movss   xmm1, [rdi+8]
    mulss   xmm1, xmm1
    addss   xmm0, xmm1
    sqrtss  xmm0, xmm0
    comiss  xmm0, [rip+mf_tiny]
    jbe     9f
    movss   xmm1, [rip+mf_one]
    divss   xmm1, xmm0
    xor     ecx, ecx
1:  movss   xmm0, [rdi+rcx*4]
    mulss   xmm0, xmm1
    movss   [rdi+rcx*4], xmm0
    inc     ecx
    cmp     ecx, 3
    jb      1b
9:  ret

# ---- vector ----------------------------------------------------------------
# frame: a at 0, b at 16, c at 32 (value at +12), the result at 48
.Lmn_vmath:
    xor     r15d, r15d
1:  mov     ecx, r15d
    call    gr_in
    mov     eax, r15d
    shl     eax, 4
    movss   [rsp+rax], xmm0
    movss   [rsp+rax+4], xmm1
    movss   [rsp+rax+8], xmm2
    movss   [rsp+rax+12], xmm3
    inc     r15d
    cmp     r15d, 3
    jb      1b
    cvttss2si eax, dword ptr [r12+ND_P]
    cmp     eax, 9
    je      .Lvm_scale
    cmp     eax, 10
    je      .Lvm_dot
    cmp     eax, 11
    je      .Lvm_cross
    cmp     eax, 12
    je      .Lvm_norm
    cmp     eax, 13
    je      .Lvm_len
    cmp     eax, 14
    je      .Lvm_dist
    cmp     eax, 15
    je      .Lvm_reflect
    lea     rcx, [rip+vm_map]           # component-wise: math_op's
    cmp     eax, 19
    ja      .Lmn_zero
    movzx   eax, byte ptr [rcx+rax]
    mov     [rsp+96], eax
    xor     r15d, r15d
2:  movss   xmm0, [rsp+r15*4]
    movss   xmm1, [rsp+16+r15*4]
    movss   xmm2, [rsp+44]              # (lerp: c's value)
    mov     eax, [rsp+96]
    call    math_op
    movss   [rsp+48+r15*4], xmm0
    inc     r15d
    cmp     r15d, 3
    jb      2b
.Lvm_vec:
    lea     rsi, [rsp+48]
    call    vec_out
    movss   xmm0, [rsp+48]              # (value: the luminance)
    movss   xmm1, [rsp+52]
    movss   xmm2, [rsp+56]
    call    gr_put
    jmp     .Lmn_out
.Lvm_scal:                              # a scalar result in xmm0
    call    gr_putv
    jmp     .Lmn_out
.Lvm_scale:
    movss   xmm3, [rsp+28]              # b's value
    xor     ecx, ecx
3:  movss   xmm0, [rsp+rcx*4]
    mulss   xmm0, xmm3
    movss   [rsp+48+rcx*4], xmm0
    inc     ecx
    cmp     ecx, 3
    jb      3b
    jmp     .Lvm_vec
.Lvm_dot:
    lea     rdi, [rsp]
    lea     rsi, [rsp+16]
    call    dotm
    jmp     .Lvm_scal
.Lvm_cross:
    movss   xmm0, [rsp+4]
    mulss   xmm0, [rsp+24]
    movss   xmm1, [rsp+8]
    mulss   xmm1, [rsp+20]
    subss   xmm0, xmm1
    movss   [rsp+48], xmm0
    movss   xmm0, [rsp+8]
    mulss   xmm0, [rsp+16]
    movss   xmm1, [rsp]
    mulss   xmm1, [rsp+24]
    subss   xmm0, xmm1
    movss   [rsp+52], xmm0
    movss   xmm0, [rsp]
    mulss   xmm0, [rsp+20]
    movss   xmm1, [rsp+4]
    mulss   xmm1, [rsp+16]
    subss   xmm0, xmm1
    movss   [rsp+56], xmm0
    jmp     .Lvm_vec
.Lvm_norm:
    mov     rax, [rsp]
    mov     [rsp+48], rax
    mov     eax, [rsp+8]
    mov     [rsp+56], eax
    lea     rdi, [rsp+48]
    call    unit3m
    jmp     .Lvm_vec
.Lvm_len:
    lea     rdi, [rsp]
    mov     rsi, rdi
    call    dotm
    sqrtss  xmm0, xmm0
    jmp     .Lvm_scal
.Lvm_dist:
    xor     ecx, ecx
4:  movss   xmm0, [rsp+rcx*4]
    subss   xmm0, [rsp+16+rcx*4]
    movss   [rsp+48+rcx*4], xmm0
    inc     ecx
    cmp     ecx, 3
    jb      4b
    lea     rdi, [rsp+48]
    mov     rsi, rdi
    call    dotm
    sqrtss  xmm0, xmm0
    jmp     .Lvm_scal
.Lvm_reflect:                           # a - 2 (a.n) n, n = b normalised
    lea     rdi, [rsp+16]
    call    unit3m
    lea     rdi, [rsp]
    lea     rsi, [rsp+16]
    call    dotm
    addss   xmm0, xmm0
    xor     ecx, ecx
5:  movss   xmm1, [rsp+16+rcx*4]
    mulss   xmm1, xmm0
    movss   xmm2, [rsp+rcx*4]
    subss   xmm2, xmm1
    movss   [rsp+48+rcx*4], xmm2
    inc     ecx
    cmp     ecx, 3
    jb      5b
    jmp     .Lvm_vec

# dotm(rdi, rsi) -> xmm0
dotm:
    movss   xmm0, [rdi]
    mulss   xmm0, [rsi]
    movss   xmm1, [rdi+4]
    mulss   xmm1, [rsi+4]
    addss   xmm0, xmm1
    movss   xmm1, [rdi+8]
    mulss   xmm1, [rsi+8]
    addss   xmm0, xmm1
    ret

.Lmn_separate:                          # x y z: values
    xor     ecx, ecx
    call    gr_in
    movss   [rsp], xmm0
    movss   [rsp+4], xmm1
    movss   [rsp+8], xmm2
    xor     r15d, r15d
1:  movss   xmm0, [rsp+r15*4]
    movss   xmm1, xmm0
    movss   xmm2, xmm0
    movss   xmm3, xmm0
    mov     ecx, r15d
    call    gr_out
    inc     r15d
    cmp     r15d, 3
    jb      1b
    jmp     .Lmn_out

.Lmn_combine:                           # three values -> a vector / colour
    xor     ecx, ecx
    call    gr_in
    movss   [rsp], xmm3
    mov     ecx, 1
    call    gr_in
    movss   [rsp+4], xmm3
    mov     ecx, 2
    call    gr_in
    movss   xmm2, xmm3
    movss   xmm0, [rsp]
    movss   xmm1, [rsp+4]
    call    gr_put
    jmp     .Lmn_out

.Lmn_mapping:                           # scale, turn (degrees, about z), offset
    xor     ecx, ecx
    xor     edx, edx
    lea     rsi, [rsp]
    call    in_vec
    mov     ecx, 2
    call    gr_in
    mulss   xmm0, [rsp]
    mulss   xmm1, [rsp+4]
    mulss   xmm2, [rsp+8]
    movss   [rsp], xmm0
    movss   [rsp+4], xmm1
    movss   [rsp+8], xmm2
    movss   xmm0, [r12+ND_P]
    mulss   xmm0, [rip+mf_deg]
    call    turn2
    mov     ecx, 1
    call    gr_in
    addss   xmm0, [rsp]
    addss   xmm1, [rsp+4]
    addss   xmm2, [rsp+8]
    movss   [rsp], xmm0
    movss   [rsp+4], xmm1
    movss   [rsp+8], xmm2
    lea     rsi, [rsp]
    call    vec_out
    jmp     .Lmn_out

# turn2(xmm0=angle; [rsp+8] = x y in the caller's frame) - x y turned
turn2:
    sub     rsp, 24
    movss   [rsp], xmm0
    fld     dword ptr [rsp]
    fsincos                             # st0 cos, st1 sin
    fstp    dword ptr [rsp+4]
    fstp    dword ptr [rsp+8]
    movss   xmm2, [rsp+4]               # cos
    movss   xmm3, [rsp+8]               # sin
    movss   xmm0, [rsp+32]              # x (the caller's [rsp])
    movss   xmm1, [rsp+36]              # y
    movss   xmm4, xmm0
    mulss   xmm4, xmm2
    movss   xmm5, xmm1
    mulss   xmm5, xmm3
    subss   xmm4, xmm5                  # x c - y s
    mulss   xmm0, xmm3
    mulss   xmm1, xmm2
    addss   xmm0, xmm1                  # x s + y c
    movss   [rsp+32], xmm4
    movss   [rsp+36], xmm0
    add     rsp, 24
    ret

# node_t(ecx=input) -> xmm0: its value when linked, else the scene's time
node_t:
    imul    eax, ecx, 16
    test    word ptr [r12+ND_IN+rax], 0xffff
    jz      scene_time
    call    gr_in
    movss   xmm0, xmm3
    ret

.Lmn_panner:                            # uv + t speed
    xor     ecx, ecx
    xor     edx, edx
    lea     rsi, [rsp]
    call    in_vec
    mov     ecx, 1
    call    node_t
    movss   xmm1, xmm0
    mulss   xmm0, [r12+ND_P]
    addss   xmm0, [rsp]
    movss   [rsp], xmm0
    mulss   xmm1, [r12+ND_P+4]
    addss   xmm1, [rsp+4]
    movss   [rsp+4], xmm1
    lea     rsi, [rsp]
    call    vec_out
    jmp     .Lmn_out

.Lmn_rotator:                           # about (cu, cv) by t speed
    xor     ecx, ecx
    xor     edx, edx
    lea     rsi, [rsp]
    call    in_vec
    movss   xmm0, [rsp]
    subss   xmm0, [r12+ND_P]
    movss   [rsp], xmm0
    movss   xmm0, [rsp+4]
    subss   xmm0, [r12+ND_P+4]
    movss   [rsp+4], xmm0
    mov     ecx, 1
    call    node_t
    mulss   xmm0, [r12+ND_P+8]
    call    turn2
    movss   xmm0, [rsp]
    addss   xmm0, [r12+ND_P]
    movss   [rsp], xmm0
    movss   xmm0, [rsp+4]
    addss   xmm0, [r12+ND_P+4]
    movss   [rsp+4], xmm0
    lea     rsi, [rsp]
    call    vec_out
    jmp     .Lmn_out

# ---- textures --------------------------------------------------------------
# Voronoi: p (scaled) at 0, its cell at 16 (ints), F1 at 32, F2 36, the
#   nearest cell's hash 40, the loop's offset at 48..
.Lmn_voronoi:
    xor     ecx, ecx
    mov     edx, 1
    lea     rsi, [rsp]
    call    in_vec
    xor     ecx, ecx
1:  movss   xmm0, [rsp+rcx*4]
    mulss   xmm0, [r12+ND_P]
    movss   [rsp+rcx*4], xmm0
    roundss xmm1, xmm0, 1
    cvttss2si eax, xmm1
    mov     [rsp+16+rcx*4], eax
    inc     ecx
    cmp     ecx, 3
    jb      1b
    movss   xmm0, [rip+mf_big]
    movss   [rsp+32], xmm0
    movss   [rsp+36], xmm0
    mov     dword ptr [rsp+40], 0
    mov     dword ptr [rsp+48], -1      # dx dy dz
    mov     dword ptr [rsp+52], -1
    mov     dword ptr [rsp+56], -1
.Lvo_cell:
    mov     edi, [rsp+16]
    add     edi, [rsp+48]
    mov     esi, [rsp+20]
    add     esi, [rsp+52]
    mov     edx, [rsp+24]
    add     edx, [rsp+56]
    mov     [rsp+64], edi
    mov     [rsp+68], esi
    mov     [rsp+72], edx
    call    hash3i
    mov     [rsp+76], eax               # (its id)
    xorps   xmm7, xmm7                  # the distance^2
    xor     r15d, r15d
2:  mov     eax, [rsp+76]
    add     eax, r15d
    imul    eax, eax, 0x27d4eb2f
    call    h01                         # the point: cell + 0.5 + (h - 0.5) r
    subss   xmm0, [rip+mf_half]
    mulss   xmm0, [r12+ND_P+4]
    addss   xmm0, [rip+mf_half]
    cvtsi2ss xmm1, dword ptr [rsp+64+r15*4]
    addss   xmm0, xmm1
    subss   xmm0, [rsp+r15*4]
    mulss   xmm0, xmm0
    addss   xmm7, xmm0
    inc     r15d
    cmp     r15d, 3
    jb      2b
    sqrtss  xmm7, xmm7
    comiss  xmm7, [rsp+32]
    jae     3f
    movss   xmm0, [rsp+32]              # a new nearest: the old one second
    movss   [rsp+36], xmm0
    movss   [rsp+32], xmm7
    mov     eax, [rsp+76]
    mov     [rsp+40], eax
    jmp     4f
3:  comiss  xmm7, [rsp+36]
    jae     4f
    movss   [rsp+36], xmm7
4:  inc     dword ptr [rsp+48]          # the next of the 27
    cmp     dword ptr [rsp+48], 1
    jle     .Lvo_cell
    mov     dword ptr [rsp+48], -1
    inc     dword ptr [rsp+52]
    cmp     dword ptr [rsp+52], 1
    jle     .Lvo_cell
    mov     dword ptr [rsp+52], -1
    inc     dword ptr [rsp+56]
    cmp     dword ptr [rsp+56], 1
    jle     .Lvo_cell
    movss   xmm0, [rsp+32]              # F1, F2 or F2 - F1
    cvttss2si eax, dword ptr [r12+ND_P+8]
    cmp     eax, 1
    jne     5f
    movss   xmm0, [rsp+36]
5:  cmp     eax, 2
    jne     6f
    movss   xmm0, [rsp+36]
    subss   xmm0, [rsp+32]
6:  movss   [rsp+80], xmm0
    mov     eax, [rsp+40]               # the cell's colour
    xor     eax, 0x5bd1e995
    call    h01
    movss   [rsp+84], xmm0
    call    h01
    movss   [rsp+88], xmm0
    call    h01
    movss   xmm2, xmm0
    movss   xmm0, [rsp+84]
    movss   xmm1, [rsp+88]
    movss   xmm3, xmm0
    mov     ecx, 1
    call    gr_out
    movss   xmm0, [rsp+80]
    call    gr_putv
    jmp     .Lmn_out

.Lmn_whitenoise:                        # a hash of the point itself
    xor     ecx, ecx
    mov     edx, 1
    lea     rsi, [rsp]
    call    in_vec
    mov     edi, [rsp]
    mov     esi, [rsp+4]
    mov     edx, [rsp+8]
    call    hash3i
    call    h01
    movss   [rsp+16], xmm0
    call    h01
    movss   [rsp+20], xmm0
    call    h01
    movss   [rsp+24], xmm0
    movss   xmm0, [rsp+16]              # (output 1: the colour)
    movss   xmm1, [rsp+20]
    movss   xmm2, [rsp+24]
    movss   xmm3, xmm0
    mov     ecx, 1
    call    gr_out
    movss   xmm0, [rsp+16]
    call    gr_putv
    jmp     .Lmn_out

# brick: (u, v) scaled; rows half as high, every other one shifted
.Lmn_brick:
    xor     ecx, ecx
    xor     edx, edx
    lea     rsi, [rsp]
    call    in_vec
    movss   xmm0, [rsp]
    mulss   xmm0, [r12+ND_P]
    movss   xmm1, [rsp+4]
    mulss   xmm1, [r12+ND_P]
    addss   xmm1, xmm1
    roundss xmm2, xmm1, 1               # the row
    cvttss2si eax, xmm2
    mov     [rsp+16], eax
    subss   xmm1, xmm2
    movss   [rsp+20], xmm1              # y in the row
    test    eax, 1
    jz      1f
    addss   xmm0, [r12+ND_P+8]          # (odd rows: shifted)
1:  roundss xmm2, xmm0, 1
    cvttss2si eax, xmm2
    mov     [rsp+24], eax               # the brick
    subss   xmm0, xmm2
    movss   [rsp+28], xmm0              # x in the brick
    movss   xmm3, [r12+ND_P+4]          # mortar: near any edge
    xor     r15d, r15d
    comiss  xmm0, xmm3
    jb      2f
    movss   xmm4, [rip+mf_one]
    subss   xmm4, xmm3
    comiss  xmm0, xmm4
    ja      2f
    addss   xmm3, xmm3                  # (rows are half as high)
    movss   xmm0, [rsp+20]
    comiss  xmm0, xmm3
    jb      2f
    movss   xmm4, [rip+mf_one]
    subss   xmm4, xmm3
    comiss  xmm0, xmm4
    ja      2f
    jmp     3f
2:  mov     r15d, 1
3:  test    r15d, r15d
    jz      4f
    mov     ecx, 2                      # the mortar's colour, fac 1
    call    gr_in
    jmp     5f
4:  mov     edi, [rsp+24]               # a brick: its colour, a little
    mov     esi, [rsp+16]               #  lighter or darker
    xor     edx, edx
    call    hash3i
    call    h01
    mulss   xmm0, [rip+bb_tint+4]
    addss   xmm0, [rip+bb_tint]
    movss   [rsp+32], xmm0
    mov     ecx, 1
    call    gr_in
    mulss   xmm0, [rsp+32]
    mulss   xmm1, [rsp+32]
    mulss   xmm2, [rsp+32]
5:  movss   [rsp+40], xmm0
    movss   [rsp+44], xmm1
    movss   [rsp+48], xmm2
    cvtsi2ss xmm0, r15d
    movss   xmm1, xmm0
    movss   xmm2, xmm0
    movss   xmm3, xmm0
    mov     ecx, 1
    call    gr_out
    movss   xmm0, [rsp+40]
    movss   xmm1, [rsp+44]
    movss   xmm2, [rsp+48]
    call    gr_put
    jmp     .Lmn_out

.Lmn_wave:                              # 1/2 + sin(2 pi (s x + d noise)) / 2
    xor     ecx, ecx
    mov     edx, 1
    lea     rsi, [rsp]
    call    in_vec
    cvttss2si eax, dword ptr [r12+ND_P+8]   # bands: along an axis, rings
    test    eax, eax
    jnz     1f
    cvttss2si eax, dword ptr [r12+ND_P+12]
    cmp     eax, 2
    jbe     11f
    xor     eax, eax
11: movss   xmm0, [rsp+rax*4]
    jmp     2f
1:  lea     rdi, [rsp]
    mov     rsi, rdi
    call    dotm
    sqrtss  xmm0, xmm0
2:  mulss   xmm0, [r12+ND_P]
    movss   [rsp+16], xmm0
    movss   xmm0, [r12+ND_P+4]
    xorps   xmm1, xmm1
    comiss  xmm0, xmm1
    je      3f
    lea     rdi, [rsp]                  # distortion: fBm at the point
    movss   xmm0, [r12+ND_P]
    mov     ecx, 2
    movss   xmm1, [rip+mf_half]
    call    fbm
    subss   xmm0, [rip+mf_half]
    mulss   xmm0, [r12+ND_P+4]
    addss   xmm0, [rsp+16]
    movss   [rsp+16], xmm0
3:  movss   xmm0, [rsp+16]
    mulss   xmm0, [rip+mf_2pi]
    movss   [rsp+16], xmm0
    fld     dword ptr [rsp+16]
    fsin
    fstp    dword ptr [rsp+16]
    movss   xmm0, [rsp+16]
    mulss   xmm0, [rip+mf_half]
    addss   xmm0, [rip+mf_half]
    movss   [rsp+20], xmm0
    movss   xmm1, xmm0
    movss   xmm2, xmm0
    movss   xmm3, xmm0
    mov     ecx, 1
    call    gr_out
    movss   xmm0, [rsp+20]
    call    gr_putv
    jmp     .Lmn_out

# triplanar: three box projections of the world point, by the normal
.Lmn_triplanar:
    cvttss2si edi, dword ptr [r12+ND_P]
    dec     edi
    js      .Lmn_zero
    call    image_ptr
    test    rax, rax
    jz      .Lmn_zero
    mov     [rsp+120], rax
    xor     ecx, ecx                    # weights |n|^k, summing to 1
    xorps   xmm6, xmm6
1:  movss   xmm0, [rbp+SC_N+rcx*4]
    andps   xmm0, [rip+mf_abs]
    movss   xmm1, [r12+ND_P+8]
    push    rcx
    sub     rsp, 8
    movss   [rsp], xmm6
    call    fpow
    movss   xmm6, [rsp]
    add     rsp, 8
    pop     rcx
    movss   [rsp+64+rcx*4], xmm0
    addss   xmm6, xmm0
    inc     ecx
    cmp     ecx, 3
    jb      1b
    maxss   xmm6, [rip+mf_tiny]
    movss   xmm0, [r12+ND_P+4]          # size (0: 1)
    xorps   xmm1, xmm1
    comiss  xmm0, xmm1
    ja      2f
    movss   xmm0, [rip+mf_one]
2:  movss   [rsp+80], xmm0
    movss   [rsp+84], xmm6
    xorps   xmm0, xmm0
    movaps  [rsp+96], xmm0              # the sum (rgba)
    xor     r15d, r15d                  # x: (z, y), y: (x, z), z: (x, y)
3:  lea     rax, [rip+tp_axes]
    movzx   ecx, byte ptr [rax+r15*2]
    movzx   edx, byte ptr [rax+r15*2+1]
    movss   xmm0, [rbp+SC_WP+rcx*4]
    divss   xmm0, [rsp+80]
    movss   xmm1, [rbp+SC_WP+rdx*4]
    divss   xmm1, [rsp+80]
    xor     edx, edx
    cmp     dword ptr [r12+ND_P+12], 0x3f000000
    jl      31f
    mov     edx, 1
31: mov     rdi, [rsp+120]
    lea     rsi, [rsp+48]
    call    tex_sample4
    movss   xmm1, [rsp+64+r15*4]        # += its weight x the sample
    divss   xmm1, [rsp+84]
    shufps  xmm1, xmm1, 0
    movups  xmm0, [rsp+48]
    mulps   xmm0, xmm1
    addps   xmm0, [rsp+96]
    movaps  [rsp+96], xmm0
    inc     r15d
    cmp     r15d, 3
    jb      3b
    movss   xmm0, [rsp+108]             # alpha
    movss   xmm1, xmm0
    movss   xmm2, xmm0
    movss   xmm3, xmm0
    mov     ecx, 1
    call    gr_out
    movss   xmm0, [rsp+96]
    movss   xmm1, [rsp+100]
    movss   xmm2, [rsp+104]
    call    gr_put
    jmp     .Lmn_out

# ---- utility ---------------------------------------------------------------
.Lmn_reroute:                           # its input, as it is (the value too)
    xor     ecx, ecx
    call    gr_in
    xor     ecx, ecx
    call    gr_out
    jmp     .Lmn_out

# ---- functions (matfunc.s) --------------------------------------------------
.Lmn_fninput:
    call    mf_input
    jmp     .Lmn_out
.Lmn_fncall:
    call    mf_call
    jmp     .Lmn_out

# ---- parameters (their names: in the unused input constants) ----------------
.Lmn_sparam:                            # its value
    movss   xmm0, [r12+ND_P]
    call    gr_putv
    jmp     .Lmn_out
.Lmn_vparam:                            # its colour
    movss   xmm0, [r12+ND_P]
    movss   xmm1, [r12+ND_P+4]
    movss   xmm2, [r12+ND_P+8]
    call    gr_put
    jmp     .Lmn_out

# ---- colour ----------------------------------------------------------------
.Lmn_hsv:                               # shift hue, scale saturation, value
    xor     ecx, ecx
    call    gr_in
    movss   [rsp], xmm0
    movss   [rsp+4], xmm1
    movss   [rsp+8], xmm2
    movss   [rsp+16], xmm0
    movss   [rsp+20], xmm1
    movss   [rsp+24], xmm2
    lea     rdi, [rsp+16]
    call    rgb_hsv
    movss   xmm0, [rsp+16]              # h + shift, wrapped
    addss   xmm0, [r12+ND_P]
    roundss xmm1, xmm0, 1
    subss   xmm0, xmm1
    movss   [rsp+16], xmm0
    movss   xmm0, [rsp+20]
    mulss   xmm0, [r12+ND_P+4]
    maxss   xmm0, [rip+mf_zero]
    minss   xmm0, [rip+mf_one]
    movss   [rsp+20], xmm0
    movss   xmm0, [rsp+24]
    mulss   xmm0, [r12+ND_P+8]
    maxss   xmm0, [rip+mf_zero]
    movss   [rsp+24], xmm0
    lea     rdi, [rsp+16]
    call    hsv_rgb
    movss   xmm3, [r12+ND_P+12]         # mix by the factor
    jmp     .Lmn_mixout

# .Lmn_mixout: [rsp] the input colour, [rsp+16] the result, xmm3 = factor
.Lmn_mixout:
    xor     ecx, ecx
1:  movss   xmm0, [rsp+16+rcx*4]
    subss   xmm0, [rsp+rcx*4]
    mulss   xmm0, xmm3
    addss   xmm0, [rsp+rcx*4]
    movss   [rsp+16+rcx*4], xmm0
    inc     ecx
    cmp     ecx, 3
    jb      1b
.Lmn_putres:
    movss   xmm0, [rsp+16]
    movss   xmm1, [rsp+20]
    movss   xmm2, [rsp+24]
    call    gr_put
    jmp     .Lmn_out

.Lmn_invert:
    xor     ecx, ecx
    call    gr_in
    movss   [rsp], xmm0
    movss   [rsp+4], xmm1
    movss   [rsp+8], xmm2
    xor     ecx, ecx
1:  movss   xmm0, [rip+mf_one]
    subss   xmm0, [rsp+rcx*4]
    movss   [rsp+16+rcx*4], xmm0
    inc     ecx
    cmp     ecx, 3
    jb      1b
    movss   xmm3, [r12+ND_P]
    jmp     .Lmn_mixout

.Lmn_brightcon:                         # max(0, (1 + c) x + b - c / 2)
    xor     ecx, ecx
    call    gr_in
    movss   [rsp], xmm0
    movss   [rsp+4], xmm1
    movss   [rsp+8], xmm2
    movss   xmm4, [rip+mf_one]
    addss   xmm4, [r12+ND_P+4]
    movss   xmm5, [r12+ND_P+4]
    mulss   xmm5, [rip+mf_half]
    movss   xmm6, [r12+ND_P]
    subss   xmm6, xmm5
    xor     ecx, ecx
1:  movss   xmm0, [rsp+rcx*4]
    mulss   xmm0, xmm4
    addss   xmm0, xmm6
    maxss   xmm0, [rip+mf_zero]
    movss   [rsp+16+rcx*4], xmm0
    inc     ecx
    cmp     ecx, 3
    jb      1b
    jmp     .Lmn_putres

.Lmn_desat:                             # towards its luminance
    xor     ecx, ecx
    call    gr_in
    movss   [rsp], xmm0
    movss   [rsp+4], xmm1
    movss   [rsp+8], xmm2
    mulss   xmm0, [rip+mf_lum]
    mulss   xmm1, [rip+mf_lum+4]
    mulss   xmm2, [rip+mf_lum+8]
    addss   xmm0, xmm1
    addss   xmm0, xmm2
    movss   [rsp+16], xmm0
    movss   [rsp+20], xmm0
    movss   [rsp+24], xmm0
    movss   xmm3, [r12+ND_P]
    jmp     .Lmn_mixout

.Lmn_gamma:
    xor     ecx, ecx
    call    gr_in
    movss   [rsp], xmm0
    movss   [rsp+4], xmm1
    movss   [rsp+8], xmm2
    xor     r15d, r15d
1:  movss   xmm0, [rsp+r15*4]
    movss   xmm1, [r12+ND_P]
    call    fpow
    movss   [rsp+16+r15*4], xmm0
    inc     r15d
    cmp     r15d, 3
    jb      1b
    jmp     .Lmn_putres

.Lmn_blackbody:                         # t = K / 100: sRGB bytes, then linear
    movss   xmm0, [r12+ND_P]
    mulss   xmm0, [rip+mf_hund]
    maxss   xmm0, [rip+bb_10]
    movss   [rsp+32], xmm0
    comiss  xmm0, [rip+bb_66]
    ja      1f
    movss   xmm0, [rip+bb_255]          # t <= 66: r 255, g from ln t
    movss   [rsp+16], xmm0
    movss   xmm0, [rsp+32]
    mov     eax, 26
    call    math_op
    mulss   xmm0, [rip+bb_g1]
    addss   xmm0, [rip+bb_g2]
    movss   [rsp+20], xmm0
    jmp     2f
1:  movss   xmm0, [rsp+32]              # t > 66: r, g from (t - 60)^k
    subss   xmm0, [rip+bb_60]
    movss   [rsp+36], xmm0
    movss   xmm1, [rip+bb_r2]
    call    fpow
    mulss   xmm0, [rip+bb_r1]
    movss   [rsp+16], xmm0
    movss   xmm0, [rsp+36]
    movss   xmm1, [rip+bb_g4]
    call    fpow
    mulss   xmm0, [rip+bb_g3]
    movss   [rsp+20], xmm0
2:  movss   xmm0, [rip+bb_255]          # b: 255 above 66, 0 below 19, else
    movss   [rsp+24], xmm0              #  from ln (t - 10)
    movss   xmm0, [rsp+32]
    comiss  xmm0, [rip+bb_66]
    jae     4f
    xorps   xmm1, xmm1
    movss   [rsp+24], xmm1
    comiss  xmm0, [rip+bb_19]
    jbe     4f
    subss   xmm0, [rip+bb_10]
    mov     eax, 26
    call    math_op
    mulss   xmm0, [rip+bb_b1]
    addss   xmm0, [rip+bb_b2]
    movss   [rsp+24], xmm0
4:  xor     r15d, r15d
5:  movss   xmm0, [rsp+16+r15*4]
    maxss   xmm0, [rip+mf_zero]
    minss   xmm0, [rip+bb_255]
    mulss   xmm0, [rip+mf_inv255]
    call    srgb_to_lin
    movss   [rsp+16+r15*4], xmm0
    inc     r15d
    cmp     r15d, 3
    jb      5b
    jmp     .Lmn_putres

# rgb_hsv(rdi=float[3]) - in place: h (0..1), s, v
rgb_hsv:
    movss   xmm0, [rdi]                 # max, min
    movss   xmm1, [rdi+4]
    movss   xmm2, [rdi+8]
    movss   xmm3, xmm0
    maxss   xmm3, xmm1
    maxss   xmm3, xmm2                  # v
    movss   xmm4, xmm0
    minss   xmm4, xmm1
    minss   xmm4, xmm2
    movss   xmm5, xmm3
    subss   xmm5, xmm4                  # delta
    xorps   xmm6, xmm6                  # s = delta / v
    comiss  xmm3, [rip+mf_tiny]
    jbe     1f
    movss   xmm6, xmm5
    divss   xmm6, xmm3
1:  xorps   xmm7, xmm7                  # h
    comiss  xmm5, [rip+mf_tiny]
    jbe     5f
    comiss  xmm0, xmm3                  # r max: (g - b) / d
    jne     2f
    movss   xmm7, xmm1
    subss   xmm7, xmm2
    divss   xmm7, xmm5
    jmp     4f
2:  comiss  xmm1, xmm3                  # g max: 2 + (b - r) / d
    jne     3f
    movss   xmm7, xmm2
    subss   xmm7, xmm0
    divss   xmm7, xmm5
    addss   xmm7, [rip+mf_two]
    jmp     4f
3:  movss   xmm7, xmm0                  # b max: 4 + (r - g) / d
    subss   xmm7, xmm1
    divss   xmm7, xmm5
    addss   xmm7, [rip+mf_two]
    addss   xmm7, [rip+mf_two]
4:  divss   xmm7, [rip+mf_six]          # / 6, into 0..1
    xorps   xmm0, xmm0
    comiss  xmm7, xmm0
    jae     5f
    addss   xmm7, [rip+mf_one]
5:  movss   [rdi], xmm7
    movss   [rdi+4], xmm6
    movss   [rdi+8], xmm3
    ret

# hsv_rgb(rdi=float[3]) - in place
hsv_rgb:
    movss   xmm0, [rdi]                 # h 6: sector i, f
    mulss   xmm0, [rip+mf_six]
    roundss xmm1, xmm0, 1
    subss   xmm0, xmm1                  # f
    cvttss2si eax, xmm1
    xor     edx, edx                    # i mod 6
    mov     ecx, 6
    cdq
    idiv    ecx
    test    edx, edx
    jns     1f
    add     edx, 6
1:  movss   xmm5, [rdi+8]               # v
    movss   xmm6, [rdi+4]               # s
    movss   xmm2, [rip+mf_one]          # p = v (1 - s)
    subss   xmm2, xmm6
    mulss   xmm2, xmm5
    movss   xmm3, xmm6                  # q = v (1 - s f)
    mulss   xmm3, xmm0
    movss   xmm4, [rip+mf_one]
    subss   xmm4, xmm3
    mulss   xmm4, xmm5
    movss   xmm3, xmm4
    movss   xmm4, [rip+mf_one]          # t = v (1 - s (1 - f))
    subss   xmm4, xmm0
    mulss   xmm4, xmm6
    movss   xmm7, [rip+mf_one]
    subss   xmm7, xmm4
    mulss   xmm7, xmm5
    movss   xmm4, xmm7
    # (r, g, b) by sector: 0 v t p, 1 q v p, 2 p v t, 3 p q v, 4 t p v, 5 v p q
    cmp     edx, 0
    jne     2f
    movss   [rdi], xmm5
    movss   [rdi+4], xmm4
    movss   [rdi+8], xmm2
    ret
2:  cmp     edx, 1
    jne     3f
    movss   [rdi], xmm3
    movss   [rdi+4], xmm5
    movss   [rdi+8], xmm2
    ret
3:  cmp     edx, 2
    jne     4f
    movss   [rdi], xmm2
    movss   [rdi+4], xmm5
    movss   [rdi+8], xmm4
    ret
4:  cmp     edx, 3
    jne     5f
    movss   [rdi], xmm2
    movss   [rdi+4], xmm3
    movss   [rdi+8], xmm5
    ret
5:  cmp     edx, 4
    jne     6f
    movss   [rdi], xmm4
    movss   [rdi+4], xmm2
    movss   [rdi+8], xmm5
    ret
6:  movss   [rdi], xmm5
    movss   [rdi+4], xmm2
    movss   [rdi+8], xmm3
    ret

.section .rodata
# vector math's component-wise operations -> math_op's
vm_map:         .byte 0, 1, 2, 3, 5, 6, 9, 13, 15, 0, 0, 0, 0, 0, 0, 0, 21, 18, 19, 4
tp_axes:        .byte 2, 1, 0, 2, 0, 1      # triplanar: (u, v) per projection
.align 4
bb_tint:        .float 0.8, 0.4             # bricks: 0.8 .. 1.2 of the colour

# ---- generated from the node list: names, titles, metadata, defaults ----
.section .rodata
.align 8
.if MN_NTYPES - 42
.error "MN_NTYPES at the top of matnodes.s must be 42"
.endif
graph_ntypes:   .long MN_NTYPES
graph_type_names:
                .quad mns_0, mns_1, mns_2, mns_3, mns_4, mns_5
                .quad mns_6, mns_7, mns_8, mns_9, mns_10, mns_11
                .quad mns_12, mns_13, mns_14, mns_15, mns_16, mns_17
                .quad mns_18, mns_19, mns_20, mns_21, mns_22, mns_23
                .quad mns_24, mns_25, mns_26, mns_27, mns_28, mns_29
                .quad mns_30, mns_31, mns_32, mns_33, mns_34, mns_35
                .quad mns_36, mns_37, mns_38, mns_39, mns_40, mns_41
                .quad 0
mn_titles:      .quad 0
                .quad mns_42, mns_43, mns_44, mns_45, mns_46, mns_47
                .quad mns_48, mns_49, mns_50, mns_51, mns_52, mns_53
                .quad mns_54, mns_55, mns_56, mns_57, mns_58, mns_59
                .quad mns_60, mns_61, mns_62, mns_63, mns_64, mns_65
                .quad mns_66, mns_67, mns_68, mns_69, mns_70, mns_71
                .quad mns_72, mns_73, mns_74, mns_75, mns_76, mns_77
                .quad mns_78, mns_79, mns_80, mns_81, mns_82, mns_83
# per type (as geonodes.s's gn_meta): input names (3), input kinds, value
#   names (4), value kinds (0 number, 1 choice, 6 the second choice list,
#   2 image, 3 whole number, 4 a function), the choices (lists one after the other: a
#   count, then the names), output names (8), output kinds
mn_meta:        .quad 0, 0, 0, 0, 0, 0, 0
                .quad mi_image, mik_image, mv_image, mvk_image, mc_image, mo_image, mok_image
                .quad mi_noise, mik_noise, mv_noise, mvk_noise, 0, mo_noise, mok_noise
                .quad mi_checker, mik_checker, mv_checker, mvk_checker, 0, mo_checker, mok_checker
                .quad mi_gradient, mik_gradient, mv_gradient, mvk_gradient, mc_gradient, mo_gradient, mok_gradient
                .quad mi_mix, mik_mix, mv_mix, mvk_mix, mc_mix, mo_mix, mok_mix
                .quad mi_ramp, mik_ramp, mv_ramp, mvk_ramp, 0, mo_ramp, mok_ramp
                .quad mi_math, mik_math, mv_math, mvk_math, mc_math, mo_math, mok_math
                .quad mi_bump, mik_bump, mv_bump, mvk_bump, 0, mo_bump, mok_bump
                .quad mi_normalmap, mik_normalmap, mv_normalmap, mvk_normalmap, mc_normalmap, mo_normalmap, mok_normalmap
                .quad mi_texcoord, mik_texcoord, mv_texcoord, mvk_texcoord, 0, mo_texcoord, mok_texcoord
                .quad mi_position, mik_position, mv_position, mvk_position, mc_position, mo_position, mok_position
                .quad mi_normal, mik_normal, mv_normal, mvk_normal, 0, mo_normal, mok_normal
                .quad mi_camera, mik_camera, mv_camera, mvk_camera, 0, mo_camera, mok_camera
                .quad mi_vcolor, mik_vcolor, mv_vcolor, mvk_vcolor, 0, mo_vcolor, mok_vcolor
                .quad mi_time, mik_time, mv_time, mvk_time, 0, mo_time, mok_time
                .quad mi_constant, mik_constant, mv_constant, mvk_constant, 0, mo_constant, mok_constant
                .quad mi_color, mik_color, mv_color, mvk_color, 0, mo_color, mok_color
                .quad mi_fresnel, mik_fresnel, mv_fresnel, mvk_fresnel, 0, mo_fresnel, mok_fresnel
                .quad mi_vmath, mik_vmath, mv_vmath, mvk_vmath, mc_vmath, mo_vmath, mok_vmath
                .quad mi_separate, mik_separate, mv_separate, mvk_separate, 0, mo_separate, mok_separate
                .quad mi_combine, mik_combine, mv_combine, mvk_combine, 0, mo_combine, mok_combine
                .quad mi_mapping, mik_mapping, mv_mapping, mvk_mapping, 0, mo_mapping, mok_mapping
                .quad mi_panner, mik_panner, mv_panner, mvk_panner, 0, mo_panner, mok_panner
                .quad mi_rotator, mik_rotator, mv_rotator, mvk_rotator, 0, mo_rotator, mok_rotator
                .quad mi_voronoi, mik_voronoi, mv_voronoi, mvk_voronoi, mc_voronoi, mo_voronoi, mok_voronoi
                .quad mi_hsv, mik_hsv, mv_hsv, mvk_hsv, 0, mo_hsv, mok_hsv
                .quad mi_invert, mik_invert, mv_invert, mvk_invert, 0, mo_invert, mok_invert
                .quad mi_brightcon, mik_brightcon, mv_brightcon, mvk_brightcon, 0, mo_brightcon, mok_brightcon
                .quad mi_desaturate, mik_desaturate, mv_desaturate, mvk_desaturate, 0, mo_desaturate, mok_desaturate
                .quad mi_gamma, mik_gamma, mv_gamma, mvk_gamma, 0, mo_gamma, mok_gamma
                .quad mi_blackbody, mik_blackbody, mv_blackbody, mvk_blackbody, 0, mo_blackbody, mok_blackbody
                .quad mi_brick, mik_brick, mv_brick, mvk_brick, 0, mo_brick, mok_brick
                .quad mi_wave, mik_wave, mv_wave, mvk_wave, mc_wave, mo_wave, mok_wave
                .quad mi_whitenoise, mik_whitenoise, mv_whitenoise, mvk_whitenoise, 0, mo_whitenoise, mok_whitenoise
                .quad mi_triplanar, mik_triplanar, mv_triplanar, mvk_triplanar, mc_triplanar, mo_triplanar, mok_triplanar
                .quad mi_reroute, mik_reroute, mv_reroute, mvk_reroute, 0, mo_reroute, mok_reroute
                .quad mi_scalarparam, mik_scalarparam, mv_scalarparam, mvk_scalarparam, 0, mo_scalarparam, mok_scalarparam
                .quad mi_vectorparam, mik_vectorparam, mv_vectorparam, mvk_vectorparam, 0, mo_vectorparam, mok_vectorparam
                .quad mi_textureparam, mik_textureparam, mv_textureparam, mvk_textureparam, mc_textureparam, mo_textureparam, mok_textureparam
                .quad mi_fninput, mik_fninput, mv_fninput, mvk_fninput, mc_fninput, mo_fninput, mok_fninput
                .quad mi_fnoutput, mik_fnoutput, mv_fnoutput, mvk_fnoutput, 0, mo_fnoutput, mok_fnoutput
                .quad mi_fncall, mik_fncall, mv_fncall, mvk_fncall, 0, mo_fncall, mok_fncall
mi_image:      .quad mns_84, 0, 0
mv_image:      .quad mns_85, mns_86, mns_87, mns_88
mo_image:      .quad mns_58, mns_89, mns_90, mns_91, mns_92, 0, 0, 0
mc_image:      .quad 3, mns_93, mns_94, mns_53, 3, mns_95, mns_96, mns_97
mi_noise:      .quad mns_98, 0, 0
mv_noise:      .quad mns_99, mns_100, mns_101, 0
mo_noise:      .quad mns_58, 0, 0, 0, 0, 0, 0, 0
mi_checker:    .quad mns_102, mns_103, 0
mv_checker:    .quad mns_99, 0, 0, 0
mo_checker:    .quad mns_58, 0, 0, 0, 0, 0, 0, 0
mi_gradient:   .quad 0, 0, 0
mv_gradient:   .quad mns_104, mns_99, mns_98, 0
mo_gradient:   .quad mns_58, 0, 0, 0, 0, 0, 0, 0
mc_gradient:   .quad 5, mns_105, mns_106, mns_107, mns_108, mns_109
mi_mix:        .quad mns_110, mns_102, mns_103
mv_mix:        .quad mns_111, 0, 0, 0
mo_mix:        .quad mns_58, 0, 0, 0, 0, 0, 0, 0
mc_mix:        .quad 11, mns_46, mns_112, mns_113, mns_114, mns_115, mns_116, mns_117, mns_118, mns_119, mns_120, mns_121
mi_ramp:       .quad mns_110, mns_122, mns_102
mv_ramp:       .quad mns_123, mns_124, 0, 0
mo_ramp:       .quad mns_58, 0, 0, 0, 0, 0, 0, 0
mi_math:       .quad mns_125, mns_91, mns_126
mv_math:       .quad mns_127, 0, 0, 0
mo_math:       .quad mns_128, 0, 0, 0, 0, 0, 0, 0
mc_math:       .quad 31, mns_112, mns_114, mns_113, mns_121, mns_129, mns_130, mns_131, mns_132, mns_133, mns_134, mns_135, mns_136, mns_137, mns_138, mns_139, mns_140, mns_141, mns_142, mns_143, mns_144, mns_96, mns_145, mns_146, mns_147, mns_148, mns_149, mns_150, mns_151, mns_152, mns_153, mns_154
mi_bump:       .quad mns_155, 0, 0
mv_bump:       .quad mns_156, mns_157, 0, 0
mo_bump:       .quad mns_53, 0, 0, 0, 0, 0, 0, 0
mi_normalmap:  .quad mns_58, 0, 0
mv_normalmap:  .quad mns_156, mns_158, 0, 0
mo_normalmap:  .quad mns_53, 0, 0, 0, 0, 0, 0, 0
mc_normalmap:  .quad 2, mns_159, mns_160
mi_texcoord:   .quad 0, 0, 0
mv_texcoord:   .quad mns_161, mns_162, mns_163, mns_164
mo_texcoord:   .quad mns_84, mns_165, mns_166, 0, 0, 0, 0, 0
mi_position:   .quad 0, 0, 0
mv_position:   .quad mns_167, 0, 0, 0
mo_position:   .quad mns_52, mns_105, mns_106, mns_107, 0, 0, 0, 0
mc_position:   .quad 2, mns_168, mns_169
mi_normal:     .quad 0, 0, 0
mv_normal:     .quad 0, 0, 0, 0
mo_normal:     .quad mns_53, mns_105, mns_106, mns_107, 0, 0, 0, 0
mi_camera:     .quad 0, 0, 0
mv_camera:     .quad 0, 0, 0, 0
mo_camera:     .quad mns_170, 0, 0, 0, 0, 0, 0, 0
mi_vcolor:     .quad 0, 0, 0
mv_vcolor:     .quad 0, 0, 0, 0
mo_vcolor:     .quad mns_58, 0, 0, 0, 0, 0, 0, 0
mi_time:       .quad 0, 0, 0
mv_time:       .quad mns_171, 0, 0, 0
mo_time:       .quad mns_56, 0, 0, 0, 0, 0, 0, 0
mi_constant:   .quad 0, 0, 0
mv_constant:   .quad mns_128, 0, 0, 0
mo_constant:   .quad mns_128, 0, 0, 0, 0, 0, 0, 0
mi_color:      .quad mns_58, 0, 0
mv_color:      .quad 0, 0, 0, 0
mo_color:      .quad mns_58, 0, 0, 0, 0, 0, 0, 0
mi_fresnel:    .quad mns_53, 0, 0
mv_fresnel:    .quad mns_149, mns_172, 0, 0
mo_fresnel:    .quad mns_173, 0, 0, 0, 0, 0, 0, 0
mi_vmath:      .quad mns_125, mns_91, mns_126
mv_vmath:      .quad mns_127, 0, 0, 0
mo_vmath:      .quad mns_170, mns_105, mns_106, mns_107, 0, 0, 0, 0
mc_vmath:      .quad 20, mns_112, mns_114, mns_113, mns_121, mns_130, mns_131, mns_134, mns_138, mns_140, mns_99, mns_174, mns_175, mns_176, mns_177, mns_157, mns_178, mns_145, mns_143, mns_144, mns_129
mi_separate:   .quad mns_170, 0, 0
mv_separate:   .quad 0, 0, 0, 0
mo_separate:   .quad mns_105, mns_106, mns_107, 0, 0, 0, 0, 0
mi_combine:    .quad mns_105, mns_106, mns_107
mv_combine:    .quad 0, 0, 0, 0
mo_combine:    .quad mns_170, 0, 0, 0, 0, 0, 0, 0
mi_mapping:    .quad mns_170, mns_98, mns_99
mv_mapping:    .quad mns_179, 0, 0, 0
mo_mapping:    .quad mns_170, 0, 0, 0, 0, 0, 0, 0
mi_panner:     .quad mns_84, mns_56, 0
mv_panner:     .quad mns_180, mns_181, 0, 0
mo_panner:     .quad mns_84, 0, 0, 0, 0, 0, 0, 0
mi_rotator:    .quad mns_84, mns_56, 0
mv_rotator:    .quad mns_182, mns_183, mns_171, 0
mo_rotator:    .quad mns_84, 0, 0, 0, 0, 0, 0, 0
mi_voronoi:    .quad mns_170, 0, 0
mv_voronoi:    .quad mns_99, mns_184, mns_185, 0
mo_voronoi:    .quad mns_157, mns_58, 0, 0, 0, 0, 0, 0
mc_voronoi:    .quad 3, mns_186, mns_187, mns_188
mi_hsv:        .quad mns_58, 0, 0
mv_hsv:        .quad mns_189, mns_190, mns_128, mns_110
mo_hsv:        .quad mns_58, 0, 0, 0, 0, 0, 0, 0
mi_invert:     .quad mns_58, 0, 0
mv_invert:     .quad mns_110, 0, 0, 0
mo_invert:     .quad mns_58, 0, 0, 0, 0, 0, 0, 0
mi_brightcon:  .quad mns_58, 0, 0
mv_brightcon:  .quad mns_191, mns_192, 0, 0
mo_brightcon:  .quad mns_58, 0, 0, 0, 0, 0, 0, 0
mi_desaturate: .quad mns_58, 0, 0
mv_desaturate: .quad mns_140, 0, 0, 0
mo_desaturate: .quad mns_58, 0, 0, 0, 0, 0, 0, 0
mi_gamma:      .quad mns_58, 0, 0
mv_gamma:      .quad mns_71, 0, 0, 0
mo_gamma:      .quad mns_58, 0, 0, 0, 0, 0, 0, 0
mi_blackbody:  .quad 0, 0, 0
mv_blackbody:  .quad mns_193, 0, 0, 0
mo_blackbody:  .quad mns_58, 0, 0, 0, 0, 0, 0, 0
mi_brick:      .quad mns_170, mns_194, mns_195
mv_brick:      .quad mns_99, mns_195, mns_98, 0
mo_brick:      .quad mns_58, mns_173, 0, 0, 0, 0, 0, 0
mi_wave:       .quad mns_170, 0, 0
mv_wave:       .quad mns_99, mns_196, mns_197, mns_104
mo_wave:       .quad mns_173, mns_58, 0, 0, 0, 0, 0, 0
mc_wave:       .quad 2, mns_198, mns_199, 3, mns_105, mns_106, mns_107
mi_whitenoise: .quad mns_170, 0, 0
mv_whitenoise: .quad 0, 0, 0, 0
mo_whitenoise: .quad mns_128, mns_58, 0, 0, 0, 0, 0, 0
mi_triplanar:  .quad 0, 0, 0
mv_triplanar:  .quad mns_85, mns_86, mns_200, mns_87
mo_triplanar:  .quad mns_58, mns_92, 0, 0, 0, 0, 0, 0
mc_triplanar:  .quad 2, mns_93, mns_94
mi_reroute:    .quad mns_201, 0, 0
mv_reroute:    .quad 0, 0, 0, 0
mo_reroute:    .quad mns_202, 0, 0, 0, 0, 0, 0, 0
mi_scalarparam: .quad 0, 0, 0
mv_scalarparam: .quad mns_128, mns_203, mns_204, 0
mo_scalarparam: .quad mns_128, 0, 0, 0, 0, 0, 0, 0
mi_vectorparam: .quad 0, 0, 0
mv_vectorparam: .quad mns_89, mns_90, mns_91, 0
mo_vectorparam: .quad mns_58, 0, 0, 0, 0, 0, 0, 0
mi_textureparam: .quad mns_84, 0, 0
mv_textureparam: .quad mns_85, mns_86, mns_87, mns_88
mo_textureparam: .quad mns_58, mns_89, mns_90, mns_91, mns_92, 0, 0, 0
mc_textureparam: .quad 3, mns_93, mns_94, mns_53, 3, mns_95, mns_96, mns_97
mi_fninput:    .quad mns_205, 0, 0
mv_fninput:    .quad mns_206, 0, 0, 0
mo_fninput:    .quad mns_128, 0, 0, 0, 0, 0, 0, 0
mc_fninput:    .quad 3, mns_207, mns_208, mns_209
mi_fnoutput:   .quad mns_210, mns_211, mns_212
mv_fnoutput:   .quad 0, 0, 0, 0
mo_fnoutput:   .quad 0, 0, 0, 0, 0, 0, 0, 0
mi_fncall:     .quad mns_207, mns_208, mns_209
mv_fncall:     .quad mns_213, 0, 0, 0
mo_fncall:     .quad mns_210, mns_211, mns_212, 0, 0, 0, 0, 0
mik_image:     .byte 2, 0, 0
mvk_image:     .byte 2, 0, 1, 6
mok_image:     .byte 3, 1, 1, 1, 1, 0, 0, 0
mik_noise:     .byte 2, 0, 0
mvk_noise:     .byte 0, 3, 0, 0
mok_noise:     .byte 3, 0, 0, 0, 0, 0, 0, 0
mik_checker:   .byte 3, 3, 0
mvk_checker:   .byte 0, 0, 0, 0
mok_checker:   .byte 3, 0, 0, 0, 0, 0, 0, 0
mik_gradient:  .byte 0, 0, 0
mvk_gradient:  .byte 1, 0, 0, 0
mok_gradient:  .byte 3, 0, 0, 0, 0, 0, 0, 0
mik_mix:       .byte 1, 3, 3
mvk_mix:       .byte 1, 0, 0, 0
mok_mix:       .byte 3, 0, 0, 0, 0, 0, 0, 0
mik_ramp:      .byte 1, 3, 3
mvk_ramp:      .byte 0, 0, 0, 0
mok_ramp:      .byte 3, 0, 0, 0, 0, 0, 0, 0
mik_math:      .byte 1, 1, 1
mvk_math:      .byte 1, 0, 0, 0
mok_math:      .byte 1, 0, 0, 0, 0, 0, 0, 0
mik_bump:      .byte 1, 0, 0
mvk_bump:      .byte 0, 0, 0, 0
mok_bump:      .byte 2, 0, 0, 0, 0, 0, 0, 0
mik_normalmap: .byte 3, 0, 0
mvk_normalmap: .byte 0, 1, 0, 0
mok_normalmap: .byte 2, 0, 0, 0, 0, 0, 0, 0
mik_texcoord:  .byte 0, 0, 0
mvk_texcoord:  .byte 0, 0, 0, 0
mok_texcoord:  .byte 2, 1, 1, 0, 0, 0, 0, 0
mik_position:  .byte 0, 0, 0
mvk_position:  .byte 1, 0, 0, 0
mok_position:  .byte 2, 1, 1, 1, 0, 0, 0, 0
mik_normal:    .byte 0, 0, 0
mvk_normal:    .byte 0, 0, 0, 0
mok_normal:    .byte 2, 1, 1, 1, 0, 0, 0, 0
mik_camera:    .byte 0, 0, 0
mvk_camera:    .byte 0, 0, 0, 0
mok_camera:    .byte 2, 0, 0, 0, 0, 0, 0, 0
mik_vcolor:    .byte 0, 0, 0
mvk_vcolor:    .byte 0, 0, 0, 0
mok_vcolor:    .byte 3, 0, 0, 0, 0, 0, 0, 0
mik_time:      .byte 0, 0, 0
mvk_time:      .byte 0, 0, 0, 0
mok_time:      .byte 1, 0, 0, 0, 0, 0, 0, 0
mik_constant:  .byte 0, 0, 0
mvk_constant:  .byte 0, 0, 0, 0
mok_constant:  .byte 1, 0, 0, 0, 0, 0, 0, 0
mik_color:     .byte 3, 0, 0
mvk_color:     .byte 0, 0, 0, 0
mok_color:     .byte 3, 0, 0, 0, 0, 0, 0, 0
mik_fresnel:   .byte 2, 0, 0
mvk_fresnel:   .byte 0, 0, 0, 0
mok_fresnel:   .byte 1, 0, 0, 0, 0, 0, 0, 0
mik_vmath:     .byte 2, 2, 2
mvk_vmath:     .byte 1, 0, 0, 0
mok_vmath:     .byte 2, 1, 1, 1, 0, 0, 0, 0
mik_separate:  .byte 2, 0, 0
mvk_separate:  .byte 0, 0, 0, 0
mok_separate:  .byte 1, 1, 1, 0, 0, 0, 0, 0
mik_combine:   .byte 1, 1, 1
mvk_combine:   .byte 0, 0, 0, 0
mok_combine:   .byte 2, 0, 0, 0, 0, 0, 0, 0
mik_mapping:   .byte 2, 2, 2
mvk_mapping:   .byte 0, 0, 0, 0
mok_mapping:   .byte 2, 0, 0, 0, 0, 0, 0, 0
mik_panner:    .byte 2, 1, 0
mvk_panner:    .byte 0, 0, 0, 0
mok_panner:    .byte 2, 0, 0, 0, 0, 0, 0, 0
mik_rotator:   .byte 2, 1, 0
mvk_rotator:   .byte 0, 0, 0, 0
mok_rotator:   .byte 2, 0, 0, 0, 0, 0, 0, 0
mik_voronoi:   .byte 2, 0, 0
mvk_voronoi:   .byte 0, 0, 1, 0
mok_voronoi:   .byte 1, 3, 0, 0, 0, 0, 0, 0
mik_hsv:       .byte 3, 0, 0
mvk_hsv:       .byte 0, 0, 0, 0
mok_hsv:       .byte 3, 0, 0, 0, 0, 0, 0, 0
mik_invert:    .byte 3, 0, 0
mvk_invert:    .byte 0, 0, 0, 0
mok_invert:    .byte 3, 0, 0, 0, 0, 0, 0, 0
mik_brightcon: .byte 3, 0, 0
mvk_brightcon: .byte 0, 0, 0, 0
mok_brightcon: .byte 3, 0, 0, 0, 0, 0, 0, 0
mik_desaturate: .byte 3, 0, 0
mvk_desaturate: .byte 0, 0, 0, 0
mok_desaturate: .byte 3, 0, 0, 0, 0, 0, 0, 0
mik_gamma:     .byte 3, 0, 0
mvk_gamma:     .byte 0, 0, 0, 0
mok_gamma:     .byte 3, 0, 0, 0, 0, 0, 0, 0
mik_blackbody: .byte 0, 0, 0
mvk_blackbody: .byte 0, 0, 0, 0
mok_blackbody: .byte 3, 0, 0, 0, 0, 0, 0, 0
mik_brick:     .byte 2, 3, 3
mvk_brick:     .byte 0, 0, 0, 0
mok_brick:     .byte 3, 1, 0, 0, 0, 0, 0, 0
mik_wave:      .byte 2, 0, 0
mvk_wave:      .byte 0, 0, 1, 6
mok_wave:      .byte 1, 3, 0, 0, 0, 0, 0, 0
mik_whitenoise: .byte 2, 0, 0
mvk_whitenoise: .byte 0, 0, 0, 0
mok_whitenoise: .byte 1, 3, 0, 0, 0, 0, 0, 0
mik_triplanar: .byte 0, 0, 0
mvk_triplanar: .byte 2, 0, 0, 1
mok_triplanar: .byte 3, 1, 0, 0, 0, 0, 0, 0
mik_reroute:   .byte 3, 0, 0
mvk_reroute:   .byte 0, 0, 0, 0
mok_reroute:   .byte 3, 0, 0, 0, 0, 0, 0, 0
mik_scalarparam: .byte 0, 0, 0
mvk_scalarparam: .byte 0, 0, 0, 0
mok_scalarparam: .byte 1, 0, 0, 0, 0, 0, 0, 0
mik_vectorparam: .byte 0, 0, 0
mvk_vectorparam: .byte 0, 0, 0, 0
mok_vectorparam: .byte 3, 0, 0, 0, 0, 0, 0, 0
mik_textureparam: .byte 2, 0, 0
mvk_textureparam: .byte 2, 0, 1, 6
mok_textureparam: .byte 3, 1, 1, 1, 1, 0, 0, 0
mik_fninput:   .byte 3, 0, 0
mvk_fninput:   .byte 1, 0, 0, 0
mok_fninput:   .byte 3, 0, 0, 0, 0, 0, 0, 0
mik_fnoutput:  .byte 3, 3, 3
mvk_fnoutput:  .byte 0, 0, 0, 0
mok_fnoutput:  .byte 0, 0, 0, 0, 0, 0, 0, 0
mik_fncall:    .byte 3, 3, 3
mvk_fncall:    .byte 4, 0, 0, 0
mok_fncall:    .byte 3, 3, 3, 0, 0, 0, 0, 0
# header colours, categories (0 input, 1 texture, 2 math, 3 vector, 4 colour, 5 utility)
.align 4
mn_color:       .long 0
                .long 0x6b4f96               # image
                .long 0x6b4f96               # noise
                .long 0x6b4f96               # checker
                .long 0x6b4f96               # gradient
                .long 0x2f6589               # mix
                .long 0x2f6589               # ramp
                .long 0x2f6589               # math
                .long 0x6a3b63               # bump
                .long 0x6a3b63               # normalmap
                .long 0x9a4a3c               # texcoord
                .long 0x9a4a3c               # position
                .long 0x9a4a3c               # normal
                .long 0x9a4a3c               # camera
                .long 0x9a4a3c               # vcolor
                .long 0x9a4a3c               # time
                .long 0x9a4a3c               # constant
                .long 0x9a4a3c               # color
                .long 0x9a4a3c               # fresnel
                .long 0x6a3b63               # vmath
                .long 0x6a3b63               # separate
                .long 0x6a3b63               # combine
                .long 0x6a3b63               # mapping
                .long 0x6a3b63               # panner
                .long 0x6a3b63               # rotator
                .long 0x6b4f96               # voronoi
                .long 0x8a6d1f               # hsv
                .long 0x8a6d1f               # invert
                .long 0x8a6d1f               # brightcon
                .long 0x8a6d1f               # desaturate
                .long 0x8a6d1f               # gamma
                .long 0x8a6d1f               # blackbody
                .long 0x6b4f96               # brick
                .long 0x6b4f96               # wave
                .long 0x6b4f96               # whitenoise
                .long 0x6b4f96               # triplanar
                .long 0x4a5560               # reroute
                .long 0x3d6b47               # scalarparam
                .long 0x3d6b47               # vectorparam
                .long 0x3d6b47               # textureparam
                .long 0x2f6e6e               # fninput
                .long 0x2f6e6e               # fnoutput
                .long 0x2f6e6e               # fncall
mn_cat:         .byte 0, 1, 1, 1, 1, 4, 4, 2, 3, 3, 0, 0, 0, 0, 0, 0, 0, 0, 0, 3, 3, 3, 3, 3, 3, 1, 4, 4, 4, 4, 4, 4, 1, 1, 1, 1, 5, 6, 6, 6, 7, 7, 7
.align 8
mn_cat_names:   .quad mns_206, mns_214, mns_48, mns_170, mns_93, mns_215, mns_216, mns_217, 0
# defaults per type: p0..p3, the inputs' values (3 each)
.align 4
mn_defaults:
    .float 0.0, 1.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0    # image
    .float 4.0, 3.0, 0.5, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0    # noise
    .float 2.0, 0.0, 0.0, 0.0, 0.8, 0.8, 0.8, 0.2, 0.2, 0.2, 0.0, 0.0, 0.0    # checker
    .float 1.0, 1.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0    # gradient
    .float 0.0, 0.0, 0.0, 0.0, 0.5, 0.5, 0.5, 0.8, 0.8, 0.8, 0.2, 0.2, 0.2    # mix
    .float 0.0, 1.0, 0.0, 0.0, 0.5, 0.5, 0.5, 0.0, 0.0, 0.0, 1.0, 1.0, 1.0    # ramp
    .float 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0    # math
    .float 1.0, 0.05, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0    # bump
    .float 1.0, 0.0, 0.0, 0.0, 0.5, 0.5, 1.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0    # normalmap
    .float 1.0, 1.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0    # texcoord
    .float 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0    # position
    .float 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0    # normal
    .float 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0    # camera
    .float 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0    # vcolor
    .float 1.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0    # time
    .float 0.5, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0    # constant
    .float 0.0, 0.0, 0.0, 0.0, 0.8, 0.8, 0.8, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0    # color
    .float 5.0, 0.04, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0    # fresnel
    .float 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0    # vmath
    .float 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0    # separate
    .float 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0    # combine
    .float 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 1.0, 1.0, 1.0    # mapping
    .float 0.1, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0    # panner
    .float 0.5, 0.5, 0.25, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0    # rotator
    .float 5.0, 1.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0    # voronoi
    .float 0.0, 1.0, 1.0, 1.0, 0.8, 0.8, 0.8, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0    # hsv
    .float 1.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0    # invert
    .float 0.0, 0.0, 0.0, 0.0, 0.8, 0.8, 0.8, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0    # brightcon
    .float 1.0, 0.0, 0.0, 0.0, 0.8, 0.8, 0.8, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0    # desaturate
    .float 1.0, 0.0, 0.0, 0.0, 0.8, 0.8, 0.8, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0    # gamma
    .float 6500.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0    # blackbody
    .float 4.0, 0.03, 0.5, 0.0, 0.0, 0.0, 0.0, 0.6, 0.25, 0.15, 0.8, 0.8, 0.8    # brick
    .float 4.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0    # wave
    .float 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0    # whitenoise
    .float 0.0, 1.0, 4.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0    # triplanar
    .float 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0    # reroute
    .float 0.5, 0.0, 1.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0    # scalarparam
    .float 0.8, 0.8, 0.8, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0    # vectorparam
    .float 0.0, 1.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0    # textureparam
    .float 0.0, 0.0, 0.0, 0.0, 0.5, 0.5, 0.5, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0    # fninput
    .float 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0    # fnoutput
    .float 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0    # fncall
# the strings
mns_0:          .asciz "image"
mns_1:          .asciz "noise"
mns_2:          .asciz "checker"
mns_3:          .asciz "gradient"
mns_4:          .asciz "mix"
mns_5:          .asciz "ramp"
mns_6:          .asciz "math"
mns_7:          .asciz "bump"
mns_8:          .asciz "normalmap"
mns_9:          .asciz "texcoord"
mns_10:         .asciz "position"
mns_11:         .asciz "normal"
mns_12:         .asciz "camera"
mns_13:         .asciz "vcolor"
mns_14:         .asciz "time"
mns_15:         .asciz "constant"
mns_16:         .asciz "color"
mns_17:         .asciz "fresnel"
mns_18:         .asciz "vmath"
mns_19:         .asciz "separate"
mns_20:         .asciz "combine"
mns_21:         .asciz "mapping"
mns_22:         .asciz "panner"
mns_23:         .asciz "rotator"
mns_24:         .asciz "voronoi"
mns_25:         .asciz "hsv"
mns_26:         .asciz "invert"
mns_27:         .asciz "brightcon"
mns_28:         .asciz "desaturate"
mns_29:         .asciz "gamma"
mns_30:         .asciz "blackbody"
mns_31:         .asciz "brick"
mns_32:         .asciz "wave"
mns_33:         .asciz "whitenoise"
mns_34:         .asciz "triplanar"
mns_35:         .asciz "reroute"
mns_36:         .asciz "scalarparam"
mns_37:         .asciz "vectorparam"
mns_38:         .asciz "textureparam"
mns_39:         .asciz "fninput"
mns_40:         .asciz "fnoutput"
mns_41:         .asciz "fncall"
mns_42:         .asciz "Texture Sample"
mns_43:         .asciz "Noise Texture"
mns_44:         .asciz "Checker Texture"
mns_45:         .asciz "Gradient Texture"
mns_46:         .asciz "Mix"
mns_47:         .asciz "Color Ramp"
mns_48:         .asciz "Math"
mns_49:         .asciz "Bump"
mns_50:         .asciz "Normal Map"
mns_51:         .asciz "Texture Coordinate"
mns_52:         .asciz "Position"
mns_53:         .asciz "Normal"
mns_54:         .asciz "Camera Vector"
mns_55:         .asciz "Vertex Color"
mns_56:         .asciz "Time"
mns_57:         .asciz "Constant"
mns_58:         .asciz "Color"
mns_59:         .asciz "Fresnel"
mns_60:         .asciz "Vector Math"
mns_61:         .asciz "Separate"
mns_62:         .asciz "Combine"
mns_63:         .asciz "Mapping"
mns_64:         .asciz "Panner"
mns_65:         .asciz "Rotator"
mns_66:         .asciz "Voronoi Texture"
mns_67:         .asciz "Hue/Saturation"
mns_68:         .asciz "Invert"
mns_69:         .asciz "Bright/Contrast"
mns_70:         .asciz "Desaturation"
mns_71:         .asciz "Gamma"
mns_72:         .asciz "Blackbody"
mns_73:         .asciz "Brick Texture"
mns_74:         .asciz "Wave Texture"
mns_75:         .asciz "White Noise"
mns_76:         .asciz "Triplanar Sample"
mns_77:         .asciz "Reroute"
mns_78:         .asciz "Scalar Parameter"
mns_79:         .asciz "Vector Parameter"
mns_80:         .asciz "Texture Parameter"
mns_81:         .asciz "Function Input"
mns_82:         .asciz "Function Output"
mns_83:         .asciz "Material Function"
mns_84:         .asciz "UV"
mns_85:         .asciz "Image"
mns_86:         .asciz "Size"
mns_87:         .asciz "Sampler"
mns_88:         .asciz "Wrap"
mns_89:         .asciz "R"
mns_90:         .asciz "G"
mns_91:         .asciz "B"
mns_92:         .asciz "Alpha"
mns_93:         .asciz "Colour"
mns_94:         .asciz "Data"
mns_95:         .asciz "Repeat"
mns_96:         .asciz "Clamp"
mns_97:         .asciz "Mirror"
mns_98:         .asciz "Offset"
mns_99:         .asciz "Scale"
mns_100:        .asciz "Detail"
mns_101:        .asciz "Roughness"
mns_102:        .asciz "Color 1"
mns_103:        .asciz "Color 2"
mns_104:        .asciz "Axis"
mns_105:        .asciz "X"
mns_106:        .asciz "Y"
mns_107:        .asciz "Z"
mns_108:        .asciz "Radial"
mns_109:        .asciz "Spherical"
mns_110:        .asciz "Factor"
mns_111:        .asciz "Mode"
mns_112:        .asciz "Add"
mns_113:        .asciz "Multiply"
mns_114:        .asciz "Subtract"
mns_115:        .asciz "Screen"
mns_116:        .asciz "Overlay"
mns_117:        .asciz "Darken"
mns_118:        .asciz "Lighten"
mns_119:        .asciz "Difference"
mns_120:        .asciz "Soft Light"
mns_121:        .asciz "Divide"
mns_122:        .asciz "Color 0"
mns_123:        .asciz "Position 0"
mns_124:        .asciz "Position 1"
mns_125:        .asciz "A"
mns_126:        .asciz "C"
mns_127:        .asciz "Operation"
mns_128:        .asciz "Value"
mns_129:        .asciz "Power"
mns_130:        .asciz "Minimum"
mns_131:        .asciz "Maximum"
mns_132:        .asciz "Greater Than"
mns_133:        .asciz "Sine"
mns_134:        .asciz "Absolute"
mns_135:        .asciz "Cosine"
mns_136:        .asciz "Tangent"
mns_137:        .asciz "Square Root"
mns_138:        .asciz "Floor"
mns_139:        .asciz "Ceil"
mns_140:        .asciz "Fraction"
mns_141:        .asciz "Round"
mns_142:        .asciz "Sign"
mns_143:        .asciz "One Minus"
mns_144:        .asciz "Saturate"
mns_145:        .asciz "Lerp"
mns_146:        .asciz "Step"
mns_147:        .asciz "Smoothstep"
mns_148:        .asciz "Modulo"
mns_149:        .asciz "Exponent"
mns_150:        .asciz "Logarithm"
mns_151:        .asciz "Arctan2"
mns_152:        .asciz "Less Than"
mns_153:        .asciz "Negate"
mns_154:        .asciz "Multiply Add"
mns_155:        .asciz "Height"
mns_156:        .asciz "Strength"
mns_157:        .asciz "Distance"
mns_158:        .asciz "Green"
mns_159:        .asciz "OpenGL (+Y)"
mns_160:        .asciz "DirectX (-Y)"
mns_161:        .asciz "Tiling U"
mns_162:        .asciz "Tiling V"
mns_163:        .asciz "Offset U"
mns_164:        .asciz "Offset V"
mns_165:        .asciz "U"
mns_166:        .asciz "V"
mns_167:        .asciz "Space"
mns_168:        .asciz "Object"
mns_169:        .asciz "World"
mns_170:        .asciz "Vector"
mns_171:        .asciz "Speed"
mns_172:        .asciz "Base"
mns_173:        .asciz "Fac"
mns_174:        .asciz "Dot Product"
mns_175:        .asciz "Cross Product"
mns_176:        .asciz "Normalize"
mns_177:        .asciz "Length"
mns_178:        .asciz "Reflect"
mns_179:        .asciz "Rotation"
mns_180:        .asciz "Speed U"
mns_181:        .asciz "Speed V"
mns_182:        .asciz "Centre U"
mns_183:        .asciz "Centre V"
mns_184:        .asciz "Randomness"
mns_185:        .asciz "Feature"
mns_186:        .asciz "F1"
mns_187:        .asciz "F2"
mns_188:        .asciz "Edge"
mns_189:        .asciz "Hue"
mns_190:        .asciz "Saturation"
mns_191:        .asciz "Bright"
mns_192:        .asciz "Contrast"
mns_193:        .asciz "Kelvin"
mns_194:        .asciz "Brick"
mns_195:        .asciz "Mortar"
mns_196:        .asciz "Distortion"
mns_197:        .asciz "Kind"
mns_198:        .asciz "Bands"
mns_199:        .asciz "Rings"
mns_200:        .asciz "Sharpness"
mns_201:        .asciz "In"
mns_202:        .asciz "Out"
mns_203:        .asciz "Min"
mns_204:        .asciz "Max"
mns_205:        .asciz "Preview"
mns_206:        .asciz "Input"
mns_207:        .asciz "In 1"
mns_208:        .asciz "In 2"
mns_209:        .asciz "In 3"
mns_210:        .asciz "Out 1"
mns_211:        .asciz "Out 2"
mns_212:        .asciz "Out 3"
mns_213:        .asciz "Function"
mns_214:        .asciz "Texture"
mns_215:        .asciz "Utility"
mns_216:        .asciz "Parameters"
mns_217:        .asciz "Functions"

.section .note.GNU-stack,"",@progbits
