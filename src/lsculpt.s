# =============================================================================
#  BeeModel - sculpting and painting landscapes.
#
#  Sculpt mode on a landscape (sculpt.s hands it here: sc_land) works on
#  the heightfield itself, at its full resolution, through the topmost
#  Sculpted layer (one is added when there is none): each dab changes that
#  layer's offsets and, so the stroke shows at once, the heights and the
#  display mesh's vertices under it; when the stroke ends the stack is
#  evaluated again from that layer. A stroke works on its own copy of the
#  block and the mesh, so it is one undo step.
#
#  Brushes: raise, lower, smooth (towards the neighbours), flatten (to the
#  height where the stroke began), ramp (from where the stroke began to
#  where it ends: a straight slope a brush wide), noise, erode (droplet
#  erosion in a window around the dab).
#
#  Paint: up to 8 paint layers, each a material (rock, grass, sand, snow,
#  dirt, gravel, moss, mud) with a colour, friction and bounce, and a rule
#  (the heights and slopes it covers) for auto paint. The splat map keeps 8
#  weights a sample (0..255, together at most 255; the rest is unpainted).
#  A paint dab adds the layer's weight and lowers the others. The display
#  mesh's vertex colours show the blend - in the viewport and in both path
#  tracers, which tint the material by them.
# =============================================================================
.intel_syntax noprefix
.include "const.inc"
.include "macros.inc"
.include "landscape.inc"

.globl sc_land
.globl ls_tool
.globl ls_enter
.globl ls_press
.globl ls_drag
.globl ls_release
.globl ls_vcol
.globl ls_tool_name
.globl ls_mats

.equ T_RAISE,   0
.equ T_LOWER,   1
.equ T_SMOOTH,  2
.equ T_FLAT,    3
.equ T_RAMP,    4
.equ T_NOISE,   5
.equ T_ERODE,   6
.equ T_PAINT,   8                       # + the material

.section .rodata
.align 16
ls_absm:        .long 0x7fffffff, 0, 0, 0
ls_one:         .float 1.0
ls_half:        .float 0.5
ls_zero:        .float 0.0
ls_tiny:        .float 1.0e-6
ls_tenth:       .float 0.1
ls_20th:        .float 0.05
ls_quarter:     .float 0.25
ls_fifth:       .float 0.2
ls_two:         .float 2.0
ls_255:         .float 255.0
ls_128:         .float 128.0
ls_big:         .float 1.0e30
ls_rate:        .float 0.3
ls_r2d:         .float 57.29578
ls_soft_h:      .float 0.05
ls_soft_s:      .float 5.0
ls_nseed:       .float 0.37
ls_defr:        .float 10.0
ls_defs:        .float 0.5
s_land_on:      .asciz "  sculpt mode: landscape (brushes and paint)"
s_ls_undo:      .asciz "Landscape Stroke"
s_ls_bad:       .asciz "  landscape: not understood: "
s_ls_full:      .asciz "  landscape: 8 paint layers at most"
s_ls_mem:       .asciz "  landscape: out of memory"
k_ls_to:        .asciz "to"
k_ls_radius:    .asciz "radius"
k_ls_strength:  .asciz "strength"
k_ls_add:       .asciz "add"
k_ls_auto:      .asciz "auto"
k_ls_rule:      .asciz "rule"
k_ls_remove:    .asciz "remove"
k_ls_height:    .asciz "height"
k_ls_slope:     .asciz "slope"
k_ls_colour:    .asciz "colour"
k_ls_friction:  .asciz "friction"
k_ls_bounce:    .asciz "bounce"
tn_raise:       .asciz "raise"
tn_lower:       .asciz "lower"
tn_smooth:      .asciz "smooth"
tn_flatten:     .asciz "flatten"
tn_ramp:        .asciz "ramp"
tn_noise:       .asciz "noise"
tn_erode:       .asciz "erode"
mn_rock:        .asciz "rock"
mn_grass:       .asciz "grass"
mn_sand:        .asciz "sand"
mn_snow:        .asciz "snow"
mn_dirt:        .asciz "dirt"
mn_gravel:      .asciz "gravel"
mn_moss:        .asciz "moss"
mn_mud:         .asciz "mud"
.align 8
ls_tnames:      .quad tn_raise, tn_lower, tn_smooth, tn_flatten, tn_ramp, tn_noise, tn_erode, 0
ls_mnames:      .quad mn_rock, mn_grass, mn_sand, mn_snow, mn_dirt, mn_gravel, mn_moss, mn_mud, 0
# the materials: a paint layer's defaults (LP_ record: material, colour,
#   friction, bounce, heights lo hi (0..1 of the range), slopes lo hi (deg))
.align 4
ls_mats:        .long 0, 0x7a736b
                .float 0.7, 0.1, 0, 0, 30, 90
                .long 1, 0x5b7f32
                .float 0.6, 0.05, 0, 0, 0, 30
                .long 2, 0xd8c08a
                .float 0.5, 0.0, 0, 0.15, 0, 20
                .long 3, 0xf2f4f7
                .float 0.15, 0.0, 0.8, 1.0, 0, 0
                .long 4, 0x6e5137
                .float 0.6, 0.0, 0, 0, 15, 35
                .long 5, 0x8d8a83
                .float 0.7, 0.1, 0, 0, 0, 0
                .long 6, 0x4a5f2a
                .float 0.6, 0.0, 0, 0, 0, 0
                .long 7, 0x4a3b2b
                .float 0.8, 0.0, 0, 0.1, 0, 0

OPERATOR op_lt_raise,   "landscape.tool_raise",   "Raise",   do_lt, arg=T_RAISE,   check=lt_check, flags=OPF_AI_SAFE|OPF_QUIET, doc="Landscape sculpting: raise the ground under the brush"
OPERATOR op_lt_lower,   "landscape.tool_lower",   "Lower",   do_lt, arg=T_LOWER,   check=lt_check, flags=OPF_AI_SAFE|OPF_QUIET, doc="Landscape sculpting: lower the ground under the brush"
OPERATOR op_lt_smooth,  "landscape.tool_smooth",  "Smooth",  do_lt, arg=T_SMOOTH,  check=lt_check, flags=OPF_AI_SAFE|OPF_QUIET, doc="Landscape sculpting: smooth the ground towards its neighbours"
OPERATOR op_lt_flatten, "landscape.tool_flatten", "Flatten", do_lt, arg=T_FLAT,    check=lt_check, flags=OPF_AI_SAFE|OPF_QUIET, doc="Landscape sculpting: flatten to the height where the stroke began"
OPERATOR op_lt_ramp,    "landscape.tool_ramp",    "Ramp",    do_lt, arg=T_RAMP,    check=lt_check, flags=OPF_AI_SAFE|OPF_QUIET, doc="Landscape sculpting: a straight slope from where the stroke begins to where it ends"
OPERATOR op_lt_noise,   "landscape.tool_noise",   "Noise",   do_lt, arg=T_NOISE,   check=lt_check, flags=OPF_AI_SAFE|OPF_QUIET, doc="Landscape sculpting: roughen the ground with noise"
OPERATOR op_lt_erode,   "landscape.tool_erode",   "Erode",   do_lt, arg=T_ERODE,   check=lt_check, flags=OPF_AI_SAFE|OPF_QUIET, doc="Landscape sculpting: droplet erosion under the brush"
OPERATOR op_lt_rock,    "landscape.paint_rock",   "Rock",    do_lt, arg=T_PAINT+0, check=lt_check, flags=OPF_AI_SAFE|OPF_QUIET, doc="Landscape painting: paint rock (a paint layer is added when there is none)"
OPERATOR op_lt_grass,   "landscape.paint_grass",  "Grass",   do_lt, arg=T_PAINT+1, check=lt_check, flags=OPF_AI_SAFE|OPF_QUIET, doc="Landscape painting: paint grass"
OPERATOR op_lt_sand,    "landscape.paint_sand",   "Sand",    do_lt, arg=T_PAINT+2, check=lt_check, flags=OPF_AI_SAFE|OPF_QUIET, doc="Landscape painting: paint sand"
OPERATOR op_lt_snow,    "landscape.paint_snow",   "Snow",    do_lt, arg=T_PAINT+3, check=lt_check, flags=OPF_AI_SAFE|OPF_QUIET, doc="Landscape painting: paint snow"
OPERATOR op_lt_dirt,    "landscape.paint_dirt",   "Dirt",    do_lt, arg=T_PAINT+4, check=lt_check, flags=OPF_AI_SAFE|OPF_QUIET, doc="Landscape painting: paint dirt"
OPERATOR op_lt_gravel,  "landscape.paint_gravel", "Gravel",  do_lt, arg=T_PAINT+5, check=lt_check, flags=OPF_AI_SAFE|OPF_QUIET, doc="Landscape painting: paint gravel"
OPERATOR op_lt_moss,    "landscape.paint_moss",   "Moss",    do_lt, arg=T_PAINT+6, check=lt_check, flags=OPF_AI_SAFE|OPF_QUIET, doc="Landscape painting: paint moss"
OPERATOR op_lt_mud,     "landscape.paint_mud",    "Mud",     do_lt, arg=T_PAINT+7, check=lt_check, flags=OPF_AI_SAFE|OPF_QUIET, doc="Landscape painting: paint mud"
OPERATOR op_lt_auto,    "landscape.paint_auto",   "Auto Paint", do_lp_auto, flags=OPF_AI_SAFE|OPF_UNDO, doc="Paint the active landscape by its paint layers' rules (height and slope; rock on slopes, grass on the flat, ...)"
OPERATOR op_ls_brush,   "landscape.brush",        "Landscape Brush", do_ls_brush, flags=OPF_AI_SAFE|OPF_UNDO, doc="One dab on the active landscape: landscape.brush <raise|lower|smooth|flatten|noise|erode|rock|grass|sand|snow|dirt|gravel|moss|mud> x z [radius r (10)] [strength s (0.5)]; landscape.brush ramp x z to x2 z2 [radius r] (world x, z)"
OPERATOR op_ls_paint,   "landscape.paint",        "Landscape Paint Layers", do_ls_paint, flags=OPF_AI_SAFE|OPF_UNDO, doc="The active landscape's paint layers: landscape.paint add <rock|grass|sand|snow|dirt|gravel|moss|mud> [colour r g b] [friction f] [bounce b] | rule <i> [height lo hi (0..1)] [slope lo hi (degrees)] | remove <i> | auto"

.section .bss
.align 8
sc_land:        .skip 4                 # 1: sculpt mode is on a landscape
ls_tool:        .skip 4
ls_on:          .skip 4                 # a stroke
ls_paint:       .skip 4                 # (painting: the layer)
ls_obj:         .skip 8
ls_blk:         .skip 8
ls_sl:          .skip 4                 # the Sculpted layer
ls_d:           .skip 4                 # the display mesh: samples a side,
ls_step:        .skip 4                 #  every step-th sample
ls_hit:         .skip 12                # picked: x, z (its space), height
ls_depth:       .skip 4                 #  and its camera depth
ls_a:           .skip 12                # the stroke's start (x z h)
ls_b:           .skip 12                # its last dab
ls_r:           .skip 4                 # radius (its space)
ls_s:           .skip 4                 # strength
ls_rng:         .skip 4
.text

# ls_enter(rdi=object) -> eax = 1 if it is a landscape (sculpting it)
ls_enter:
    sub     rsp, 8
    call    la_of
    test    rax, rax
    jz      8f
    mov     dword ptr [rip+sc_land], 1
    mov     dword ptr [rip+ls_on], 0
    lea     rdi, [rip+s_land_on]
    call    log_line
    mov     eax, 1
    add     rsp, 8
    ret
8:  mov     dword ptr [rip+sc_land], 0
    xor     eax, eax
    add     rsp, 8
    ret

# ls_tool_name -> rax = the active tool's name
ls_tool_name:
    mov     eax, [rip+ls_tool]
    cmp     eax, T_PAINT
    jae     1f
    lea     rcx, [rip+ls_tnames]
    mov     rax, [rcx+rax*8]
    ret
1:  sub     eax, T_PAINT
    and     eax, 7
    lea     rcx, [rip+ls_mnames]
    mov     rax, [rcx+rax*8]
    ret

do_lt:
    mov     [rip+ls_tool], edi
    mov     dword ptr [rip+dirty], 1
    ret
lt_check:
    xor     eax, eax
    cmp     [rip+ls_tool], edi
    sete    al
    ret

# -----------------------------------------------------------------------------
# ls_pick(edi, esi = logical pointer) -> eax = 1 if the ray under it meets
#   the sculpted landscape: ls_hit (its space), ls_depth; ls_obj
# -----------------------------------------------------------------------------
ls_pick:
    push    rbx
    push    r12
    push    r13
    push    r14
    sub     rsp, 104                    # +0 origin, +16 direction (its
    mov     ebx, esi                    #  space), +32 t, +36 t end, +40 dt,
    call    to_px                       #  +44 f before, +48 world dir
    cvtsi2ss xmm0, eax
    mov     edi, ebx
    call    to_px
    cvtsi2ss xmm1, eax
    subss   xmm0, [rip+vp_cx]           # u, v
    divss   xmm0, [rip+vp_focal]
    movss   xmm2, [rip+vp_cy]
    subss   xmm2, xmm1
    divss   xmm2, [rip+vp_focal]
    xor     ecx, ecx                    # d = right u + up v + fwd
1:  lea     rax, [rip+right]
    movss   xmm3, [rax+rcx*4]
    mulss   xmm3, xmm0
    lea     rax, [rip+up]
    movss   xmm4, [rax+rcx*4]
    mulss   xmm4, xmm2
    addss   xmm3, xmm4
    lea     rax, [rip+fwd]
    addss   xmm3, [rax+rcx*4]
    movss   [rsp+48+rcx*4], xmm3
    inc     ecx
    cmp     ecx, 3
    jb      1b
    mov     edi, [rip+sc_obj]
    call    obj_get
    mov     r12, rax
    mov     rdi, rax
    call    la_of
    test    rax, rax
    jnz     11f
    mov     edi, [rip+active_obj]       # (undo made the objects anew, with
    mov     [rip+sc_obj], edi           #  other handles: the active one is
    call    obj_get                     #  the landscape)
    mov     r12, rax
    mov     rdi, rax
    call    la_of
    test    rax, rax
    jz      8f
11: mov     [rip+ls_obj], r12
    mov     r13, rax
    xor     ecx, ecx                    # into its space: (p - loc) / scale
2:  lea     rax, [rip+eye]
    movss   xmm0, [rax+rcx*4]
    subss   xmm0, [r12+OB_LOC+rcx*4]
    divss   xmm0, [r12+OB_SCALE+rcx*4]
    movss   [rsp+rcx*4], xmm0
    movss   xmm0, [rsp+48+rcx*4]
    divss   xmm0, [r12+OB_SCALE+rcx*4]
    movss   [rsp+16+rcx*4], xmm0
    inc     ecx
    cmp     ecx, 3
    jb      2b
    # the box: x, z within the size, y within the heights (+- 1)
    movss   xmm6, [r13+LB_SIZE]
    mulss   xmm6, [rip+ls_half]         # half
    xorps   xmm7, xmm7                  # t0
    movss   xmm5, [rip+ls_big]          # t1
    xor     ecx, ecx
3:  movss   xmm0, xmm6                  # lo, hi on this axis
    xorps   xmm1, xmm1
    subss   xmm1, xmm6
    cmp     ecx, 1
    jne     31f
    movss   xmm1, [r13+LB_HMIN]
    subss   xmm1, [rip+ls_one]
    movss   xmm0, [r13+LB_HMAX]
    addss   xmm0, [rip+ls_one]
31: movss   xmm2, [rsp+16+rcx*4]        # d
    movaps  xmm3, xmm2
    andps   xmm3, [rip+ls_absm]
    comiss  xmm3, [rip+ls_tiny]
    ja      32f
    movss   xmm3, [rsp+rcx*4]           # parallel: inside or never
    comiss  xmm3, xmm1
    jb      8f
    comiss  xmm3, xmm0
    ja      8f
    jmp     34f
32: subss   xmm1, [rsp+rcx*4]           # (lo - o) / d, (hi - o) / d
    divss   xmm1, xmm2
    subss   xmm0, [rsp+rcx*4]
    divss   xmm0, xmm2
    movaps  xmm3, xmm1
    minss   xmm3, xmm0
    maxss   xmm1, xmm0
    maxss   xmm7, xmm3
    minss   xmm5, xmm1
34: inc     ecx
    cmp     ecx, 3
    jb      3b
    comiss  xmm7, xmm5
    jae     8f
    movss   [rsp+32], xmm7
    movss   [rsp+36], xmm5
    movss   xmm0, [r13+LB_SIZE]         # dt: half a cell along the ray
    mov     eax, [r13+LB_N]
    dec     eax
    cvtsi2ss xmm1, eax
    divss   xmm0, xmm1
    mulss   xmm0, [rip+ls_half]
    movss   xmm1, [rsp+16]
    mulss   xmm1, xmm1
    movss   xmm2, [rsp+20]
    mulss   xmm2, xmm2
    addss   xmm1, xmm2
    movss   xmm2, [rsp+24]
    mulss   xmm2, xmm2
    addss   xmm1, xmm2
    sqrtss  xmm1, xmm1
    divss   xmm0, xmm1
    movss   [rsp+40], xmm0
    mov     r14d, 200000                # (steps at most)
    movss   xmm0, [rsp+32]
    call    ls_f                        # f = y - h
    movss   [rsp+44], xmm0
4:  dec     r14d
    jz      8f
    movss   xmm0, [rsp+32]
    addss   xmm0, [rsp+40]
    comiss  xmm0, [rsp+36]
    ja      8f
    movss   [rsp+32], xmm0
    call    ls_f
    xorps   xmm1, xmm1
    comiss  xmm0, xmm1
    jbe     5f
    movss   [rsp+44], xmm0
    jmp     4b
5:  movss   xmm0, [rsp+32]              # crossed: halve 16 times
    movss   [rsp+64], xmm0              # (hi)
    subss   xmm0, [rsp+40]
    movss   [rsp+68], xmm0              # (lo, above)
    mov     r14d, 16
6:  movss   xmm0, [rsp+64]
    addss   xmm0, [rsp+68]
    mulss   xmm0, [rip+ls_half]
    movss   [rsp+72], xmm0
    call    ls_f
    movss   xmm1, [rsp+72]
    xorps   xmm2, xmm2
    comiss  xmm0, xmm2
    jbe     61f
    movss   [rsp+68], xmm1
    jmp     62f
61: movss   [rsp+64], xmm1
62: dec     r14d
    jnz     6b
    movss   xmm0, [rsp+64]              # the hit
    movss   xmm1, [rsp+16]
    mulss   xmm1, xmm0
    addss   xmm1, [rsp]
    movss   [rip+ls_hit], xmm1
    movss   xmm1, [rsp+24]
    mulss   xmm1, xmm0
    addss   xmm1, [rsp+8]
    movss   [rip+ls_hit+4], xmm1
    movss   xmm0, [rip+ls_hit]
    movss   xmm1, [rip+ls_hit+4]
    mov     rdi, r13
    call    la_height
    movss   [rip+ls_hit+8], xmm0
    movss   xmm0, [rsp+64]              # the camera depth: t (d . fwd)
    movss   xmm1, [rsp+48]
    mulss   xmm1, [rip+fwd]
    movss   xmm2, [rsp+52]
    mulss   xmm2, [rip+fwd+4]
    addss   xmm1, xmm2
    movss   xmm2, [rsp+56]
    mulss   xmm2, [rip+fwd+8]
    addss   xmm1, xmm2
    mulss   xmm0, xmm1
    movss   [rip+ls_depth], xmm0
    mov     eax, 1
    jmp     9f
8:  xor     eax, eax
9:  add     rsp, 104
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret
# ls_f(xmm0=t; caller's frame: origin, direction at +8/+24 of its rsp, r13
#   the block) -> xmm0 = the ray's y - the ground's height there
ls_f:
    lea     rax, [rsp+8]                # (the caller's rsp)
    movss   xmm3, xmm0
    movss   xmm0, [rax+16]
    mulss   xmm0, xmm3
    addss   xmm0, [rax]
    movss   xmm1, [rax+24]
    mulss   xmm1, xmm3
    addss   xmm1, [rax+8]
    movss   xmm2, [rax+20]
    mulss   xmm2, xmm3
    addss   xmm2, [rax+4]
    sub     rsp, 24
    movss   [rsp], xmm2
    mov     rdi, r13
    call    la_height
    movss   xmm1, [rsp]
    subss   xmm1, xmm0
    movaps  xmm0, xmm1
    add     rsp, 24
    ret

# -----------------------------------------------------------------------------
# ls_begin(rdi=object, esi=tool) -> eax = 1: the stroke's own block (a
#   Sculpted layer, or the paint layer, made when missing) and display mesh
# -----------------------------------------------------------------------------
ls_begin:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    sub     rsp, 16
    mov     rbx, rdi
    mov     r15d, esi
    mov     [rip+ls_obj], rdi
    call    la_of
    test    rax, rax
    jz      8f
    mov     r12, rax
    xor     r14d, r14d                  # want
    mov     dword ptr [rsp], 0          # (a new layer: 1 sculpted, 2 paint)
    cmp     r15d, T_PAINT
    jae     3f
    mov     eax, [r12+LB_NL]            # the topmost Sculpted layer
1:  dec     eax
    js      2f
    imul    rcx, rax, LY_SZ
    cmp     dword ptr [r12+LB_LAY+rcx+LY_TYPE], 4
    jne     1b
    mov     [rip+ls_sl], eax
    jmp     5f
2:  cmp     dword ptr [r12+LB_NL], LA_MAXL
    jae     8f
    mov     r14d, 2
    mov     dword ptr [rsp], 1
    mov     eax, [r12+LB_NL]
    mov     [rip+ls_sl], eax
    jmp     5f
3:  mov     r13d, r15d                  # paint: the material's layer
    sub     r13d, T_PAINT
    cmp     qword ptr [r12+LB_SPLAT], 0
    jne     31f
    or      r14d, 1
31: xor     eax, eax
32: cmp     eax, [r12+LB_NP]
    jae     33f
    imul    rcx, rax, LP_SZ
    cmp     [r12+LB_PAINT+rcx+LP_MAT], r13d
    je      34f
    inc     eax
    jmp     32b
33: cmp     dword ptr [r12+LB_NP], LA_MAXP
    jae     8f
    mov     dword ptr [rsp], 2
    mov     eax, [r12+LB_NP]
34: mov     [rip+ls_paint], eax
5:  mov     rdi, r12
    mov     esi, [r12+LB_N]
    mov     edx, r14d
    call    la_make
    test    rax, rax
    jz      8f
    mov     r12, rax
    cmp     dword ptr [rsp], 1          # the new Sculpted layer, on top
    jne     6f
    mov     eax, [r12+LB_NL]
    imul    rdi, rax, LY_SZ
    lea     rdi, [r12+LB_LAY+rdi]
    mov     dword ptr [rdi+LY_TYPE], 4
    mov     dword ptr [rdi+LY_FLG], 0
    mov     eax, [rip+ls_one]
    mov     [rdi+LY_STR], eax
    mov     rax, [rip+lv_extra]
    mov     [rdi+LY_DATA], rax
    inc     dword ptr [r12+LB_NL]
6:  cmp     dword ptr [rsp], 2          # the new paint layer
    jne     7f
    mov     edi, r13d
    mov     rsi, r12
    call    ls_add_paint
7:  mov     rdi, rbx
    mov     rsi, r12
    call    la_obj_set
    mov     [rip+ls_blk], r12
    mov     rdi, r12
    call    la_unref                    # (the mesh holds it)
    mov     rax, [rbx+OB_MESH]          # the display: its step
    cvtsi2ss xmm0, dword ptr [rax+ME_NVERTS]
    sqrtss  xmm0, xmm0
    cvtss2si ecx, xmm0
    mov     [rip+ls_d], ecx
    dec     ecx
    mov     eax, [r12+LB_N]
    dec     eax
    xor     edx, edx
    div     ecx
    mov     [rip+ls_step], eax
    cmp     qword ptr [r12+LB_SPLAT], 0 # (painted: colours to change)
    je      71f
    mov     rdi, rax
    mov     rdi, [rbx+OB_MESH]
    call    mesh_vcol_alloc
71: mov     eax, 1
    jmp     9f
8:  xor     eax, eax
9:  add     rsp, 16
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# ls_add_paint(edi=material, rsi=block) -> eax = the new paint layer's index
ls_add_paint:
    mov     eax, [rsi+LB_NP]
    imul    rcx, rax, LP_SZ
    lea     rcx, [rsi+LB_PAINT+rcx]
    and     edi, 7
    shl     edi, 5
    lea     rdx, [rip+ls_mats]
    add     rdx, rdi
    mov     r8, [rdx]
    mov     [rcx], r8
    mov     r8, [rdx+8]
    mov     [rcx+8], r8
    mov     r8, [rdx+16]
    mov     [rcx+16], r8
    mov     r8, [rdx+24]
    mov     [rcx+24], r8
    inc     dword ptr [rsi+LB_NP]
    ret

# ls_end - the stroke done: the stack again from the Sculpted layer (a
#   height brush), a new display
ls_end:
    sub     rsp, 8
    cmp     dword ptr [rip+ls_tool], T_PAINT
    jae     9f
    mov     rdi, [rip+ls_blk]
    mov     esi, [rip+ls_sl]
    call    la_eval
    mov     rdi, [rip+ls_obj]
    mov     rsi, [rip+ls_blk]
    call    la_obj_set
9:  mov     dword ptr [rip+dirty], 1
    add     rsp, 8
    ret

# -----------------------------------------------------------------------------
# ls_region(xmm0=x, xmm1=z, xmm2=reach) -> the samples it covers: r8d i0,
#   r9d i1, r10d j0, r11d j1 (inclusive; i0 > i1: none); xmm6 the cell,
#   xmm7 half the size (ls_blk)
# -----------------------------------------------------------------------------
ls_region:
    mov     rax, [rip+ls_blk]
    movss   xmm7, [rax+LB_SIZE]
    mov     ecx, [rax+LB_N]
    dec     ecx
    cvtsi2ss xmm6, ecx
    movss   xmm3, xmm7
    divss   xmm3, xmm6
    movaps  xmm6, xmm3                  # cell
    mulss   xmm7, [rip+ls_half]
    addss   xmm0, xmm7
    addss   xmm1, xmm7
    movaps  xmm3, xmm0
    subss   xmm3, xmm2
    divss   xmm3, xmm6
    roundss xmm3, xmm3, 1
    cvttss2si r8d, xmm3
    addss   xmm0, xmm2
    divss   xmm0, xmm6
    roundss xmm0, xmm0, 2
    cvttss2si r9d, xmm0
    movaps  xmm3, xmm1
    subss   xmm3, xmm2
    divss   xmm3, xmm6
    roundss xmm3, xmm3, 1
    cvttss2si r10d, xmm3
    addss   xmm1, xmm2
    divss   xmm1, xmm6
    roundss xmm1, xmm1, 2
    cvttss2si r11d, xmm1
    xor     eax, eax
    cmp     r8d, eax
    cmovl   r8d, eax
    cmp     r10d, eax
    cmovl   r10d, eax
    cmp     r9d, ecx
    cmovg   r9d, ecx
    cmp     r11d, ecx
    cmovg   r11d, ecx
    ret

# -----------------------------------------------------------------------------
# ls_dab(xmm0=x, xmm1=z (its space), xmm2=radius, xmm3=strength) - the tool
# -----------------------------------------------------------------------------
ls_dab:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    push    rbp
    sub     rsp, 88                     # +0 x, +4 z, +8 r, +12 s, +16 i0,
    movss   [rsp], xmm0                 #  +20 i1, +24 j0, +28 j1, +32 cell,
    movss   [rsp+4], xmm1               #  +36 half size, +40 N, +44 the
    movss   [rsp+8], xmm2               #  layer's 1 / strength, +48 dx
    movss   [rsp+12], xmm3
    cmp     dword ptr [rip+ls_tool], T_ERODE
    jne     1f
    call    ls_erode_local
    jmp     .Lld_show
1:  call    ls_region
    mov     [rsp+16], r8d
    mov     [rsp+20], r9d
    mov     [rsp+24], r10d
    mov     [rsp+28], r11d
    movss   [rsp+32], xmm6
    movss   [rsp+36], xmm7
    mov     rbx, [rip+ls_blk]
    mov     eax, [rbx+LB_N]
    mov     [rsp+40], eax
    mov     r12, [rbx+LB_H]             # heights
    add     r12, rbx
    xor     r13d, r13d                  # the Sculpted layer's offsets
    cmp     dword ptr [rip+ls_tool], T_PAINT
    jae     2f
    mov     eax, [rip+ls_sl]
    imul    rax, rax, LY_SZ
    mov     r13, [rbx+LB_LAY+rax+LY_DATA]
    add     r13, rbx
    movss   xmm0, [rip+ls_one]
    movss   xmm1, [rbx+LB_LAY+rax+LY_STR]
    maxss   xmm1, [rip+ls_tiny]
    divss   xmm0, xmm1
    movss   [rsp+44], xmm0
2:  mov     r14d, [rsp+24]              # j
.Lld_row:
    cmp     r14d, [rsp+28]
    jg      .Lld_show
    mov     r15d, [rsp+16]              # i
.Lld_col:
    cmp     r15d, [rsp+20]
    jg      .Lld_nrow
    cvtsi2ss xmm0, r15d                 # w = (1 - d^2 / r^2)^2 s
    mulss   xmm0, [rsp+32]
    subss   xmm0, [rsp+36]
    subss   xmm0, [rsp]
    cvtsi2ss xmm1, r14d
    mulss   xmm1, [rsp+32]
    subss   xmm1, [rsp+36]
    subss   xmm1, [rsp+4]
    mulss   xmm0, xmm0
    mulss   xmm1, xmm1
    addss   xmm0, xmm1
    movss   xmm1, [rsp+8]
    mulss   xmm1, xmm1
    divss   xmm0, xmm1
    movss   xmm1, [rip+ls_one]
    subss   xmm1, xmm0
    xorps   xmm2, xmm2
    comiss  xmm1, xmm2
    jbe     .Lld_next
    mulss   xmm1, xmm1
    mulss   xmm1, [rsp+12]              # (xmm1 = w)
    mov     eax, r14d
    imul    eax, [rsp+40]
    add     eax, r15d
    mov     ebp, eax                    # the sample
    mov     ecx, [rip+ls_tool]
    cmp     ecx, T_PAINT
    jae     .Lld_paint
    movss   xmm3, [r12+rbp*4]           # h
    cmp     ecx, T_RAISE
    jne     3f
    movss   xmm0, [rsp+8]               # raise: w r / 10
    mulss   xmm0, [rip+ls_tenth]
    mulss   xmm0, xmm1
    jmp     .Lld_put
3:  cmp     ecx, T_LOWER
    jne     4f
    xorps   xmm0, xmm0
    movss   xmm2, [rsp+8]
    mulss   xmm2, [rip+ls_tenth]
    mulss   xmm2, xmm1
    subss   xmm0, xmm2
    jmp     .Lld_put
4:  cmp     ecx, T_SMOOTH
    jne     5f
    mov     eax, r15d                   # the four neighbours' mean
    test    eax, eax
    jz      41f
    dec     eax
41: mov     edx, r14d
    imul    edx, [rsp+40]
    add     eax, edx
    movss   xmm0, [r12+rax*4]
    mov     eax, r15d
    inc     eax
    cmp     eax, [rsp+40]
    jb      42f
    dec     eax
42: add     eax, edx
    addss   xmm0, [r12+rax*4]
    mov     eax, r14d
    test    eax, eax
    jz      43f
    dec     eax
43: imul    eax, [rsp+40]
    add     eax, r15d
    addss   xmm0, [r12+rax*4]
    mov     eax, r14d
    inc     eax
    cmp     eax, [rsp+40]
    jb      44f
    dec     eax
44: imul    eax, [rsp+40]
    add     eax, r15d
    addss   xmm0, [r12+rax*4]
    mulss   xmm0, [rip+ls_quarter]
    subss   xmm0, xmm3
    mulss   xmm0, xmm1
    jmp     .Lld_put
5:  cmp     ecx, T_FLAT
    jne     6f
    movss   xmm0, [rip+ls_a+8]          # flatten: half way to the start's
    subss   xmm0, xmm3                  #  height
    mulss   xmm0, xmm1
    mulss   xmm0, [rip+ls_half]
    jmp     .Lld_put
6:  cmp     ecx, T_NOISE
    jne     .Lld_next
    movss   [rsp+48], xmm1              # noise: w r / 20 perlin(2 p / r)
    cvtsi2ss xmm0, r15d
    mulss   xmm0, [rsp+32]
    divss   xmm0, [rsp+8]
    mulss   xmm0, [rip+ls_two]
    movss   [rsp+56], xmm0
    movss   xmm0, [rip+ls_nseed]
    movss   [rsp+60], xmm0
    cvtsi2ss xmm0, r14d
    mulss   xmm0, [rsp+32]
    divss   xmm0, [rsp+8]
    mulss   xmm0, [rip+ls_two]
    movss   [rsp+64], xmm0
    lea     rdi, [rsp+56]
    call    perlin
    mulss   xmm0, [rsp+48]
    mulss   xmm0, [rsp+8]
    mulss   xmm0, [rip+ls_20th]
.Lld_put:                               # h += d, offsets += d / strength
    movss   xmm1, [r12+rbp*4]
    addss   xmm1, xmm0
    movss   [r12+rbp*4], xmm1
    mulss   xmm0, [rsp+44]
    addss   xmm0, [r13+rbp*4]
    movss   [r13+rbp*4], xmm0
    jmp     .Lld_next
.Lld_paint:
    mov     rdi, [rbx+LB_SPLAT]
    add     rdi, rbx
    lea     rdi, [rdi+rbp*8]
    mov     esi, [rip+ls_paint]
    movaps  xmm0, xmm1
    call    ls_splat
.Lld_next:
    inc     r15d
    jmp     .Lld_col
.Lld_nrow:
    inc     r14d
    jmp     .Lld_row
.Lld_show:
    movss   xmm0, [rsp]
    movss   xmm1, [rsp+4]
    movss   xmm2, [rsp+8]
    mulss   xmm2, [rip+ls_two]          # (erode reaches a little further)
    call    ls_region
    call    ls_show
    add     rsp, 88
    pop     rbp
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# ls_splat(rdi=a sample's 8 weights, esi=layer, xmm0=w) - the layer gains
#   w x 128, the others give way so they stay at most 255 together
ls_splat:
    mulss   xmm0, [rip+ls_128]
    cvtss2si eax, xmm0
    movzx   ecx, byte ptr [rdi+rsi]
    add     eax, ecx
    cmp     eax, 255
    jbe     1f
    mov     eax, 255
1:  mov     [rdi+rsi], al
    mov     r8d, 255                    # room left for the others
    sub     r8d, eax
    xor     r9d, r9d                    # theirs
    xor     ecx, ecx
2:  cmp     ecx, esi
    je      3f
    movzx   edx, byte ptr [rdi+rcx]
    add     r9d, edx
3:  inc     ecx
    cmp     ecx, 8
    jb      2b
    cmp     r9d, r8d
    jbe     9f
    xor     ecx, ecx                    # scaled down: w x room / theirs
4:  cmp     ecx, esi
    je      5f
    movzx   eax, byte ptr [rdi+rcx]
    imul    eax, r8d
    xor     edx, edx
    div     r9d
    mov     [rdi+rcx], al
5:  inc     ecx
    cmp     ecx, 8
    jb      4b
9:  ret

# ls_erode_local - droplets in a square window around the dab ([rsp+8..]
#   of ls_dab: x, z, r, s), mixed back by the falloff
ls_erode_local:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    push    rbp
    sub     rsp, 72                     # +0 ci, +4 cj, +8 rad (samples),
    mov     rbx, [rip+ls_blk]           #  +12 W, +16 min, +20 range, +24
    lea     rbp, [rsp+72+48+8]          #  bytes, +28 N, +32 cell
    movss   xmm6, [rbx+LB_SIZE]         # (rbp: the dab's x, z, r, s)
    mov     eax, [rbx+LB_N]
    mov     [rsp+28], eax
    dec     eax
    cvtsi2ss xmm7, eax
    divss   xmm6, xmm7
    movss   [rsp+32], xmm6
    movss   xmm0, [rbx+LB_SIZE]
    mulss   xmm0, [rip+ls_half]
    movss   xmm1, [rbp]
    addss   xmm1, xmm0
    divss   xmm1, xmm6
    cvtss2si eax, xmm1
    mov     [rsp], eax
    movss   xmm1, [rbp+4]
    addss   xmm1, xmm0
    divss   xmm1, xmm6
    cvtss2si eax, xmm1
    mov     [rsp+4], eax
    movss   xmm1, [rbp+8]
    divss   xmm1, xmm6
    roundss xmm1, xmm1, 2
    cvttss2si eax, xmm1
    cmp     eax, 3
    jge     1f
    mov     eax, 3
1:  cmp     eax, 255
    jle     2f
    mov     eax, 255
2:  mov     [rsp+8], eax
    lea     r12d, [rax*2+1]
    mov     [rsp+12], r12d
    mov     eax, r12d
    imul    eax, eax
    shl     eax, 2
    add     eax, 4095
    and     eax, -4096
    mov     [rsp+24], eax
    xor     edi, edi
    mov     esi, eax
    mov     edx, PROT_RW
    mov     r10d, MAP_ANON_PRIV
    mov     r8d, -1
    xor     r9d, r9d
    call    plat_mmap
    cmp     rax, -4096
    ja      9f
    mov     r13, rax                    # the window
    mov     r14, [rbx+LB_H]
    add     r14, rbx
    movss   xmm4, [rip+ls_big]          # copied (clamped at the edges)
    xorps   xmm5, xmm5
    subss   xmm5, xmm4
    xor     r15d, r15d
3:  cmp     r15d, r12d
    jae     4f
    xor     ecx, ecx
31: cmp     ecx, r12d
    jae     32f
    call    ls_win_sample
    movss   xmm0, [r14+rax*4]
    mov     eax, r15d
    imul    eax, r12d
    add     eax, ecx
    movss   [r13+rax*4], xmm0
    minss   xmm4, xmm0
    maxss   xmm5, xmm0
    inc     ecx
    jmp     31b
32: inc     r15d
    jmp     3b
4:  movss   [rsp+16], xmm4
    subss   xmm5, xmm4
    maxss   xmm5, [rip+ls_tiny]
    movss   [rsp+20], xmm5
    mov     eax, r12d                   # 0..1
    imul    eax, eax
    mov     ecx, eax
5:  test    ecx, ecx
    jz      6f
    dec     ecx
    movss   xmm0, [r13+rcx*4]
    subss   xmm0, xmm4
    divss   xmm0, xmm5
    movss   [r13+rcx*4], xmm0
    jmp     5b
6:  mov     [rip+er_h], r13
    mov     [rip+er_n], r12d
    inc     dword ptr [rip+ls_rng]
    mov     eax, [rip+ls_rng]
    imul    eax, eax, 0x9E3779B1
    or      eax, 1
    mov     [rip+er_rng], eax
    mov     edi, r12d                   # droplets: W^2 s / 2
    imul    edi, r12d
    cvtsi2ss xmm0, edi
    mulss   xmm0, [rbp+12]
    mulss   xmm0, [rip+ls_half]
    cvttss2si edi, xmm0
    inc     edi
    movss   xmm0, [rip+ls_rate]
    call    er_run
    mov     r15, [rip+ls_blk]           # back: h += (e - h) w (in the radius)
    xor     r15d, r15d
7:  cmp     r15d, r12d
    jae     8f
    xor     ecx, ecx
71: cmp     ecx, r12d
    jae     72f
    mov     eax, ecx                    # (inside the landscape only)
    sub     eax, [rsp+8]
    add     eax, [rsp]
    js      79f
    cmp     eax, [rsp+28]
    jae     79f
    mov     edx, r15d
    sub     edx, [rsp+8]
    add     edx, [rsp+4]
    js      79f
    cmp     edx, [rsp+28]
    jae     79f
    imul    edx, [rsp+28]
    add     edx, eax                    # the sample
    mov     eax, ecx                    # w: (1 - d^2 / R^2)^2 s
    sub     eax, [rsp+8]
    cvtsi2ss xmm0, eax
    mov     eax, r15d
    sub     eax, [rsp+8]
    cvtsi2ss xmm1, eax
    mulss   xmm0, xmm0
    mulss   xmm1, xmm1
    addss   xmm0, xmm1
    cvtsi2ss xmm1, dword ptr [rsp+8]
    mulss   xmm1, xmm1
    divss   xmm0, xmm1
    movss   xmm1, [rip+ls_one]
    subss   xmm1, xmm0
    xorps   xmm2, xmm2
    comiss  xmm1, xmm2
    jbe     79f
    mulss   xmm1, xmm1
    mulss   xmm1, [rbp+12]
    mov     eax, r15d
    imul    eax, r12d
    add     eax, ecx
    movss   xmm0, [r13+rax*4]
    mulss   xmm0, [rsp+20]
    addss   xmm0, [rsp+16]
    subss   xmm0, [r14+rdx*4]
    mulss   xmm0, xmm1
    movss   xmm2, [r14+rdx*4]
    addss   xmm2, xmm0
    movss   [r14+rdx*4], xmm2
    mov     eax, [rip+ls_sl]            # and the layer's offsets
    imul    rax, rax, LY_SZ
    mov     rsi, [rbx+LB_LAY+rax+LY_DATA]
    add     rsi, rbx
    movss   xmm2, [rbx+LB_LAY+rax+LY_STR]
    maxss   xmm2, [rip+ls_tiny]
    divss   xmm0, xmm2
    addss   xmm0, [rsi+rdx*4]
    movss   [rsi+rdx*4], xmm0
79: inc     ecx
    jmp     71b
72: inc     r15d
    jmp     7b
8:  mov     rdi, r13
    mov     esi, [rsp+24]
    call    plat_munmap
9:  add     rsp, 72
    pop     rbp
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret
# ls_win_sample(ecx=column, r15d=row of the window; [rsp+8..] of
#   ls_erode_local) -> eax = the sample (clamped)
ls_win_sample:
    lea     rdx, [rsp+8]                # (the caller's frame)
    mov     eax, ecx
    sub     eax, [rdx+8]
    add     eax, [rdx]
    xor     r8d, r8d
    cmp     eax, r8d
    cmovl   eax, r8d
    mov     r8d, [rdx+28]
    dec     r8d
    cmp     eax, r8d
    cmovg   eax, r8d
    mov     r9d, r15d
    sub     r9d, [rdx+8]
    add     r9d, [rdx+4]
    xor     r10d, r10d
    cmp     r9d, r10d
    cmovl   r9d, r10d
    cmp     r9d, r8d
    cmovg   r9d, r8d
    imul    r9d, [rdx+28]
    add     eax, r9d
    ret

# ls_ramp(ls_a = start x z h, ls_b = end, xmm0=half width, xmm1=strength) -
#   a straight slope between them
ls_ramp:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    push    rbp
    sub     rsp, 88                     # +0 half width, +4 s, +8 dx, +12
    movss   [rsp], xmm0                 #  dz, +16 |d|^2, +20 i0, +24 i1,
    movss   [rsp+4], xmm1               #  +28 j0, +32 j1, +36 cell, +40
    movss   xmm2, [rip+ls_b]            #  half size, +44 N, +48 1/strength
    subss   xmm2, [rip+ls_a]
    movss   [rsp+8], xmm2
    movss   xmm3, [rip+ls_b+4]
    subss   xmm3, [rip+ls_a+4]
    movss   [rsp+12], xmm3
    mulss   xmm2, xmm2
    mulss   xmm3, xmm3
    addss   xmm2, xmm3
    maxss   xmm2, [rip+ls_tiny]
    movss   [rsp+16], xmm2
    movss   xmm0, [rip+ls_a]            # the region: the box of both, + w
    addss   xmm0, [rip+ls_b]
    mulss   xmm0, [rip+ls_half]
    movss   xmm1, [rip+ls_a+4]
    addss   xmm1, [rip+ls_b+4]
    mulss   xmm1, [rip+ls_half]
    movss   xmm2, [rsp+16]
    sqrtss  xmm2, xmm2
    mulss   xmm2, [rip+ls_half]
    addss   xmm2, [rsp]
    movss   [rsp+52], xmm0
    movss   [rsp+56], xmm1
    movss   [rsp+60], xmm2
    call    ls_region
    mov     [rsp+20], r8d
    mov     [rsp+24], r9d
    mov     [rsp+28], r10d
    mov     [rsp+32], r11d
    movss   [rsp+36], xmm6
    movss   [rsp+40], xmm7
    mov     rbx, [rip+ls_blk]
    mov     eax, [rbx+LB_N]
    mov     [rsp+44], eax
    mov     r12, [rbx+LB_H]
    add     r12, rbx
    mov     eax, [rip+ls_sl]
    imul    rax, rax, LY_SZ
    mov     r13, [rbx+LB_LAY+rax+LY_DATA]
    add     r13, rbx
    movss   xmm0, [rip+ls_one]
    movss   xmm1, [rbx+LB_LAY+rax+LY_STR]
    maxss   xmm1, [rip+ls_tiny]
    divss   xmm0, xmm1
    movss   [rsp+48], xmm0
    mov     r14d, [rsp+28]
1:  cmp     r14d, [rsp+32]
    jg      9f
    mov     r15d, [rsp+20]
2:  cmp     r15d, [rsp+24]
    jg      8f
    cvtsi2ss xmm0, r15d                 # p - a
    mulss   xmm0, [rsp+36]
    subss   xmm0, [rsp+40]
    subss   xmm0, [rip+ls_a]
    cvtsi2ss xmm1, r14d
    mulss   xmm1, [rsp+36]
    subss   xmm1, [rsp+40]
    subss   xmm1, [rip+ls_a+4]
    movaps  xmm2, xmm0                  # t = (p - a).d / |d|^2, 0..1
    mulss   xmm2, [rsp+8]
    movaps  xmm3, xmm1
    mulss   xmm3, [rsp+12]
    addss   xmm2, xmm3
    divss   xmm2, [rsp+16]
    maxss   xmm2, [rip+ls_zero]
    minss   xmm2, [rip+ls_one]
    movss   xmm3, [rsp+8]               # p - (a + t d): across
    mulss   xmm3, xmm2
    subss   xmm0, xmm3
    movss   xmm3, [rsp+12]
    mulss   xmm3, xmm2
    subss   xmm1, xmm3
    mulss   xmm0, xmm0
    mulss   xmm1, xmm1
    addss   xmm0, xmm1
    movss   xmm1, [rsp]
    mulss   xmm1, xmm1
    divss   xmm0, xmm1
    movss   xmm1, [rip+ls_one]          # w: 1 over the inner half, then
    subss   xmm1, xmm0                  #  (1 - d^2 / w^2)^2 x 4 capped
    xorps   xmm3, xmm3
    comiss  xmm1, xmm3
    jbe     7f
    mulss   xmm1, xmm1
    mulss   xmm1, [rip+ls_two]
    mulss   xmm1, [rip+ls_two]
    minss   xmm1, [rip+ls_one]
    mulss   xmm1, [rsp+4]
    movss   xmm0, [rip+ls_b+8]          # target: ha + t (hb - ha)
    subss   xmm0, [rip+ls_a+8]
    mulss   xmm0, xmm2
    addss   xmm0, [rip+ls_a+8]
    mov     eax, r14d
    imul    eax, [rsp+44]
    add     eax, r15d
    subss   xmm0, [r12+rax*4]
    mulss   xmm0, xmm1
    movss   xmm1, [r12+rax*4]
    addss   xmm1, xmm0
    movss   [r12+rax*4], xmm1
    mulss   xmm0, [rsp+48]
    addss   xmm0, [r13+rax*4]
    movss   [r13+rax*4], xmm0
7:  inc     r15d
    jmp     2b
8:  inc     r14d
    jmp     1b
9:  movss   xmm0, [rsp+52]
    movss   xmm1, [rsp+56]
    movss   xmm2, [rsp+60]
    call    ls_region
    call    ls_show
    add     rsp, 88
    pop     rbp
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# -----------------------------------------------------------------------------
# ls_show(r8d i0, r9d i1, r10d j0, r11d j1) - the display mesh's vertices
#   on those samples follow (heights; colours when painted)
# -----------------------------------------------------------------------------
ls_show:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    push    rbp
    sub     rsp, 24
    mov     rbx, [rip+ls_blk]
    mov     rax, [rip+ls_obj]
    mov     r12, [rax+OB_MESH]
    mov     ecx, [rip+ls_step]
    test    ecx, ecx
    jz      9f
    lea     eax, [r8+rcx-1]             # columns ceil(i0 / s) .. i1 / s
    xor     edx, edx
    div     ecx
    mov     [rsp], eax
    mov     eax, r9d
    xor     edx, edx
    div     ecx
    mov     [rsp+4], eax
    lea     eax, [r10+rcx-1]
    xor     edx, edx
    div     ecx
    mov     r14d, eax                   # row
    mov     eax, r11d
    xor     edx, edx
    div     ecx
    mov     [rsp+8], eax
    mov     r13, [rbx+LB_H]
    add     r13, rbx
1:  cmp     r14d, [rsp+8]
    ja      8f
    mov     r15d, [rsp]
2:  cmp     r15d, [rsp+4]
    ja      7f
    mov     eax, r14d                   # the sample
    imul    eax, [rip+ls_step]
    imul    eax, [rbx+LB_N]
    mov     ecx, r15d
    imul    ecx, [rip+ls_step]
    add     eax, ecx
    mov     ebp, eax
    mov     ecx, r14d                   # the vertex
    imul    ecx, [rip+ls_d]
    add     ecx, r15d
    mov     edx, [r13+rbp*4]
    lea     rax, [rcx+rcx*2]
    mov     rsi, [r12+ME_POS]
    mov     [rsi+rax*4+4], edx
    mov     rsi, [r12+ME_VCOL]
    test    rsi, rsi
    jz      3f
    cmp     qword ptr [rbx+LB_SPLAT], 0
    je      3f
    push    rcx
    push    rsi
    mov     rdi, rbx
    mov     esi, ebp
    call    ls_colour
    pop     rsi
    pop     rcx
    mov     [rsi+rcx*4], eax
3:  inc     r15d
    jmp     2b
7:  inc     r14d
    jmp     1b
8:  mov     rdi, r12
    call    mesh_bbox
    inc     dword ptr [r12+ME_VER]
    mov     dword ptr [rip+dirty], 1
9:  add     rsp, 24
    pop     rbp
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# ls_colour(rdi=block, esi=sample) -> eax = 0xFFRRGGBB: the paint layers'
#   colours by their weights, white for the rest
ls_colour:
    push    rbx
    mov     r8, [rdi+LB_SPLAT]
    add     r8, rdi
    lea     r8, [r8+rsi*8]
    xor     ebx, ebx                    # out
    mov     ecx, 16                     # channel shift
1:  xor     r9d, r9d                    # sum w c, sum w
    xor     r10d, r10d
    xor     r11d, r11d
2:  cmp     r11d, [rdi+LB_NP]
    jae     3f
    movzx   eax, byte ptr [r8+r11]
    add     r10d, eax
    imul    rdx, r11, LP_SZ
    mov     edx, [rdi+LB_PAINT+rdx+LP_COL]
    shr     edx, cl
    and     edx, 255
    imul    eax, edx
    add     r9d, eax
    inc     r11d
    jmp     2b
3:  mov     eax, 255                    # + white for the rest
    sub     eax, r10d
    jns     31f
    xor     eax, eax
31: imul    eax, eax, 255
    add     eax, r9d
    xor     edx, edx
    mov     r10d, 255
    div     r10d
    cmp     eax, 255
    jbe     32f
    mov     eax, 255
32: shl     eax, cl
    or      ebx, eax
    sub     ecx, 8
    jns     1b
    mov     eax, ebx
    or      eax, 0xff000000
    pop     rbx
    ret

# ls_vcol(rdi=block, rsi=display mesh) - its vertex colours from the splat
#   map (none: left as they are)
ls_vcol:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    sub     rsp, 16
    mov     rbx, rdi
    mov     r12, rsi
    cmp     qword ptr [rbx+LB_SPLAT], 0
    je      9f
    cmp     dword ptr [rbx+LB_NP], 0
    je      9f
    mov     rdi, r12
    call    mesh_vcol_alloc
    test    rax, rax
    jz      9f
    mov     r15, rax
    cvtsi2ss xmm0, dword ptr [r12+ME_NVERTS]
    sqrtss  xmm0, xmm0
    cvtss2si ecx, xmm0
    mov     [rsp], ecx                  # D
    dec     ecx
    jle     9f
    mov     eax, [rbx+LB_N]
    dec     eax
    xor     edx, edx
    div     ecx
    mov     [rsp+4], eax                # step
    xor     r13d, r13d
1:  cmp     r13d, [rsp]
    jae     9f
    xor     r14d, r14d
2:  cmp     r14d, [rsp]
    jae     3f
    mov     esi, r13d
    imul    esi, [rsp+4]
    imul    esi, [rbx+LB_N]
    mov     eax, r14d
    imul    eax, [rsp+4]
    add     esi, eax
    mov     rdi, rbx
    call    ls_colour
    mov     ecx, r13d
    imul    ecx, [rsp]
    add     ecx, r14d
    mov     [r15+rcx*4], eax
    inc     r14d
    jmp     2b
3:  inc     r13d
    jmp     1b
9:  add     rsp, 16
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# -----------------------------------------------------------------------------
# The stroke under the pointer (sculpt.s: sculpt_press / drag / release)
# -----------------------------------------------------------------------------
# ls_press(edi, esi = logical pointer) -> eax = 1 if a stroke began
ls_press:
    push    rbx
    push    r12
    sub     rsp, 8
    mov     ebx, edi
    mov     r12d, esi
    call    ls_pick
    test    eax, eax
    jz      8f
    lea     rdi, [rip+s_ls_undo]
    call    undo_push
    mov     rdi, [rip+ls_obj]
    mov     esi, [rip+ls_tool]
    call    ls_begin
    test    eax, eax
    jz      8f
    movss   xmm0, [rip+sc_radius]       # the radius: pixels at its depth
    mulss   xmm0, [rip+ls_depth]
    divss   xmm0, [rip+vp_focal]
    mov     rax, [rip+ls_obj]
    divss   xmm0, [rax+OB_SCALE]
    movss   [rip+ls_r], xmm0
    mov     eax, [rip+sc_strength]
    mov     [rip+ls_s], eax
    mov     rax, [rip+ls_hit]
    mov     [rip+ls_a], rax
    mov     [rip+ls_b], rax
    mov     eax, [rip+ls_hit+8]
    mov     [rip+ls_a+8], eax
    mov     [rip+ls_b+8], eax
    mov     dword ptr [rip+ls_on], 1
    mov     dword ptr [rip+sc_stroking], 1
    cmp     dword ptr [rip+ls_tool], T_RAMP
    je      7f
    call    ls_dab_hit
7:  mov     eax, 1
    jmp     9f
8:  xor     eax, eax
9:  add     rsp, 8
    pop     r12
    pop     rbx
    ret

# ls_dab_hit - a dab at ls_hit
ls_dab_hit:
    sub     rsp, 8
    movss   xmm0, [rip+ls_hit]
    movss   xmm1, [rip+ls_hit+4]
    movss   xmm2, [rip+ls_r]
    movss   xmm3, [rip+ls_s]
    call    ls_dab
    mov     rax, [rip+ls_hit]
    mov     [rip+ls_b], rax
    mov     eax, [rip+ls_hit+8]
    mov     [rip+ls_b+8], eax
    add     rsp, 8
    ret

# ls_drag(edi, esi = logical pointer): dabs a fifth of the radius apart
#   (the ramp: where it ends)
ls_drag:
    sub     rsp, 8
    cmp     dword ptr [rip+ls_on], 0
    je      9f
    call    ls_pick
    test    eax, eax
    jz      9f
    cmp     dword ptr [rip+ls_tool], T_RAMP
    jne     1f
    mov     rax, [rip+ls_hit]
    mov     [rip+ls_b], rax
    mov     eax, [rip+ls_hit+8]
    mov     [rip+ls_b+8], eax
    jmp     9f
1:  movss   xmm0, [rip+ls_hit]
    subss   xmm0, [rip+ls_b]
    movss   xmm1, [rip+ls_hit+4]
    subss   xmm1, [rip+ls_b+4]
    mulss   xmm0, xmm0
    mulss   xmm1, xmm1
    addss   xmm0, xmm1
    sqrtss  xmm0, xmm0
    movss   xmm1, [rip+ls_r]
    mulss   xmm1, [rip+ls_fifth]
    comiss  xmm0, xmm1
    jb      9f
    call    ls_dab_hit
9:  add     rsp, 8
    ret

# ls_release - the stroke ends (a ramp is laid now)
ls_release:
    sub     rsp, 8
    cmp     dword ptr [rip+ls_on], 0
    je      9f
    cmp     dword ptr [rip+ls_tool], T_RAMP
    jne     1f
    movss   xmm0, [rip+ls_r]
    movss   xmm1, [rip+ls_one]
    call    ls_ramp
1:  call    ls_end
    mov     dword ptr [rip+ls_on], 0
    mov     dword ptr [rip+sc_stroking], 0
9:  add     rsp, 8
    ret

# =============================================================================
#  Operators
# =============================================================================
# ls_local(rdi=object, xmm0=x, xmm1=z world) -> xmm0, xmm1 in its space
ls_local:
    subss   xmm0, [rdi+OB_LOC]
    divss   xmm0, [rdi+OB_SCALE]
    subss   xmm1, [rdi+OB_LOC+8]
    divss   xmm1, [rdi+OB_SCALE+8]
    ret

# ls_tool_word -> eax = the tool im_word names (-1: none)
ls_tool_word:
    sub     rsp, 8
    lea     rsi, [rip+ls_tnames]
    call    la_word
    test    eax, eax
    jns     9f
    lea     rsi, [rip+ls_mnames]
    call    la_word
    test    eax, eax
    js      9f
    add     eax, T_PAINT
9:  add     rsp, 8
    ret

# do_ls_brush - landscape.brush <tool> x z [to x2 z2] [radius r] [strength s]
do_ls_brush:
    push    rbx
    push    r12
    push    r13
    push    r14
    sub     rsp, 40                     # +0 x z, +8 x2 z2, +16 r, +20 s,
    call    la_active                   #  +24 tool, +28 ramp
    test    rax, rax
    jz      9f
    mov     rbx, rax
    mov     eax, [rip+ls_defr]
    mov     [rsp+16], eax
    mov     eax, [rip+ls_defs]
    mov     [rsp+20], eax
    mov     dword ptr [rsp+28], 0
    mov     r12, [rip+op_arg]
    mov     rsi, r12
    call    im_next_word
    mov     r12, rsi
    test    eax, eax
    jz      .Llb_bad
    call    ls_tool_word
    test    eax, eax
    js      .Llb_bad
    mov     [rsp+24], eax
    mov     rsi, r12
    call    la_num
    test    eax, eax
    jz      .Llb_bad
    movss   [rsp], xmm0
    call    la_num
    test    eax, eax
    jz      .Llb_bad
    movss   [rsp+4], xmm0
    mov     r12, rsi
1:  mov     rsi, r12
    call    im_next_word
    mov     r12, rsi
    test    eax, eax
    jz      5f
    lea     rdi, [rip+im_word]
    lea     rsi, [rip+k_ls_to]
    call    str_eq
    test    eax, eax
    jz      2f
    mov     rsi, r12
    call    la_num
    test    eax, eax
    jz      .Llb_bad
    movss   [rsp+8], xmm0
    call    la_num
    test    eax, eax
    jz      .Llb_bad
    movss   [rsp+12], xmm0
    mov     r12, rsi
    mov     dword ptr [rsp+28], 1
    jmp     1b
2:  lea     rdi, [rip+im_word]
    lea     rsi, [rip+k_ls_radius]
    call    str_eq
    mov     r13d, 16
    test    eax, eax
    jnz     3f
    lea     rdi, [rip+im_word]
    lea     rsi, [rip+k_ls_strength]
    call    str_eq
    mov     r13d, 20
    test    eax, eax
    jz      .Llb_bad
3:  mov     rsi, r12
    call    la_num
    mov     r12, rsi
    test    eax, eax
    jz      .Llb_bad
    movss   [rsp+r13], xmm0
    jmp     1b
5:  mov     eax, [rsp+24]               # a ramp needs its end
    cmp     eax, T_RAMP
    jne     51f
    cmp     dword ptr [rsp+28], 0
    je      .Llb_bad
51: mov     r14d, [rip+ls_tool]         # (the UI's tool, kept)
    mov     [rip+ls_tool], eax
    mov     rdi, rbx
    mov     esi, eax
    call    ls_begin
    test    eax, eax
    jz      .Llb_mem
    movss   xmm0, [rsp]                 # start, end: in its space, heights
    movss   xmm1, [rsp+4]
    mov     rdi, rbx
    call    ls_local
    movss   [rip+ls_a], xmm0
    movss   [rip+ls_a+4], xmm1
    mov     rdi, [rip+ls_blk]
    call    la_height
    movss   [rip+ls_a+8], xmm0
    movss   xmm0, [rsp+8]
    movss   xmm1, [rsp+12]
    mov     rdi, rbx
    call    ls_local
    movss   [rip+ls_b], xmm0
    movss   [rip+ls_b+4], xmm1
    mov     rdi, [rip+ls_blk]
    call    la_height
    movss   [rip+ls_b+8], xmm0
    movss   xmm2, [rsp+16]
    divss   xmm2, [rbx+OB_SCALE]
    cmp     dword ptr [rip+ls_tool], T_RAMP
    jne     6f
    movaps  xmm0, xmm2
    movss   xmm1, [rip+ls_one]
    call    ls_ramp
    jmp     7f
6:  movss   xmm0, [rip+ls_a]
    movss   xmm1, [rip+ls_a+4]
    movss   xmm3, [rsp+20]
    call    ls_dab
7:  call    ls_end
    mov     [rip+ls_tool], r14d
    jmp     9f
.Llb_mem:
    mov     [rip+ls_tool], r14d
    lea     rdi, [rip+s_ls_mem]
    call    log_line
    jmp     9f
.Llb_bad:
    lea     rdi, [rip+s_ls_bad]
    mov     rsi, [rip+op_arg]
    call    log_pair
9:  add     rsp, 40
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# do_ls_paint - landscape.paint add <material> [colour r g b] [friction f]
#   [bounce b] | rule <i> [height lo hi] [slope lo hi] | remove <i> | auto
do_ls_paint:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    sub     rsp, 32
    call    la_active
    test    rax, rax
    jz      9f
    mov     r14, rax
    mov     r15, rdx
    mov     r12, [rip+op_arg]
    mov     rsi, r12
    call    im_next_word
    mov     r12, rsi
    test    eax, eax
    jz      .Llp_bad
    lea     rdi, [rip+im_word]
    lea     rsi, [rip+k_ls_auto]
    call    str_eq
    test    eax, eax
    jz      1f
    call    do_lp_auto
    jmp     9f
1:  lea     rdi, [rip+im_word]
    lea     rsi, [rip+k_ls_add]
    call    str_eq
    test    eax, eax
    jz      3f
    mov     rsi, r12                    # add <material>
    call    im_next_word
    mov     r12, rsi
    test    eax, eax
    jz      .Llp_bad
    lea     rsi, [rip+ls_mnames]
    call    la_word
    test    eax, eax
    js      .Llp_bad
    mov     r13d, eax
    cmp     dword ptr [r15+LB_NP], LA_MAXP
    jae     .Llp_full
    mov     rdi, r15
    mov     esi, [r15+LB_N]
    mov     edx, 1
    call    la_make
    test    rax, rax
    jz      .Llp_mem
    mov     rbx, rax
    mov     edi, r13d
    mov     rsi, rbx
    call    ls_add_paint
    mov     r13d, eax
    jmp     .Llp_keys
3:  xor     r13d, r13d                  # rule / remove <i>
    lea     rdi, [rip+im_word]
    lea     rsi, [rip+k_ls_rule]
    call    str_eq
    test    eax, eax
    jnz     31f
    lea     rdi, [rip+im_word]
    lea     rsi, [rip+k_ls_remove]
    call    str_eq
    test    eax, eax
    jz      .Llp_bad
    inc     r13d
31: mov     [rsp+16], r13d
    mov     rsi, r12
    call    la_num
    mov     r12, rsi
    test    eax, eax
    jz      .Llp_bad
    cvttss2si r13d, xmm0
    test    r13d, r13d
    js      .Llp_bad
    cmp     r13d, [r15+LB_NP]
    jae     .Llp_bad
    mov     rdi, r15
    mov     esi, [r15+LB_N]
    xor     edx, edx
    call    la_make
    test    rax, rax
    jz      .Llp_mem
    mov     rbx, rax
    cmp     dword ptr [rsp+16], 1
    jne     .Llp_keys
    imul    rdi, r13, LP_SZ             # remove: the ones after move down,
    lea     rdi, [rbx+LB_PAINT+rdi]     #  and so do their weights
    lea     rsi, [rdi+LP_SZ]
    mov     ecx, [rbx+LB_NP]
    sub     ecx, r13d
    dec     ecx
    shl     ecx, 5
    rep     movsb
    dec     dword ptr [rbx+LB_NP]
    mov     rdi, [rbx+LB_SPLAT]
    test    rdi, rdi
    jz      .Llp_done
    add     rdi, rbx
    mov     ecx, [rbx+LB_N]
    imul    rcx, rcx
4:  test    rcx, rcx
    jz      .Llp_done
    mov     edx, r13d
41: cmp     edx, 7
    jae     42f
    mov     al, [rdi+rdx+1]
    mov     [rdi+rdx], al
    inc     edx
    jmp     41b
42: mov     byte ptr [rdi+7], 0
    add     rdi, 8
    dec     rcx
    jmp     4b
.Llp_keys:                              # the layer's keys
    imul    rax, r13, LP_SZ
    lea     r13, [rbx+LB_PAINT+rax]
5:  mov     rsi, r12
    call    im_next_word
    mov     r12, rsi
    test    eax, eax
    jz      .Llp_done
    lea     rdi, [rip+im_word]
    lea     rsi, [rip+k_ls_height]
    call    str_eq
    test    eax, eax
    jz      51f
    lea     rdi, [r13+LP_HLO]
    call    ls_two_nums
    test    eax, eax
    jz      .Llp_badb
    jmp     5b
51: lea     rdi, [rip+im_word]
    lea     rsi, [rip+k_ls_slope]
    call    str_eq
    test    eax, eax
    jz      52f
    lea     rdi, [r13+LP_SLO]
    call    ls_two_nums
    test    eax, eax
    jz      .Llp_badb
    jmp     5b
52: lea     rdi, [rip+im_word]
    lea     rsi, [rip+k_ls_friction]
    call    str_eq
    test    eax, eax
    jz      53f
    mov     rsi, r12
    call    la_num
    mov     r12, rsi
    test    eax, eax
    jz      .Llp_badb
    movss   [r13+LP_FRIC], xmm0
    jmp     5b
53: lea     rdi, [rip+im_word]
    lea     rsi, [rip+k_ls_bounce]
    call    str_eq
    test    eax, eax
    jz      54f
    mov     rsi, r12
    call    la_num
    mov     r12, rsi
    test    eax, eax
    jz      .Llp_badb
    movss   [r13+LP_BOUNCE], xmm0
    jmp     5b
54: lea     rdi, [rip+im_word]
    lea     rsi, [rip+k_ls_colour]
    call    str_eq
    test    eax, eax
    jz      .Llp_badb
    xor     r14d, r14d                  # (r, g, b 0..1 -> 0xRRGGBB)
    mov     dword ptr [rsp+16], 3
55: mov     rsi, r12
    call    la_num
    mov     r12, rsi
    test    eax, eax
    jz      .Llp_badb
    maxss   xmm0, [rip+ls_zero]
    minss   xmm0, [rip+ls_one]
    mulss   xmm0, [rip+ls_255]
    cvtss2si eax, xmm0
    shl     r14d, 8
    or      r14d, eax
    dec     dword ptr [rsp+16]
    jnz     55b
    mov     [r13+LP_COL], r14d
    jmp     5b
.Llp_done:
    call    la_active
    mov     rdi, rax
    mov     rsi, rbx
    call    la_obj_set
    mov     rdi, rbx
    call    la_unref
    jmp     9f
.Llp_badb:
    mov     rdi, rbx
    call    la_unref
.Llp_bad:
    lea     rdi, [rip+s_ls_bad]
    mov     rsi, [rip+op_arg]
    call    log_pair
    jmp     9f
.Llp_full:
    lea     rdi, [rip+s_ls_full]
    call    log_line
    jmp     9f
.Llp_mem:
    lea     rdi, [rip+s_ls_mem]
    call    log_line
9:  add     rsp, 32
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# ls_two_nums(rdi=out f32[2]; r12 the text) -> eax = 1, r12 past them
ls_two_nums:
    push    rbx
    mov     rbx, rdi
    mov     rsi, r12
    call    la_num
    test    eax, eax
    jz      9f
    movss   [rbx], xmm0
    call    la_num
    test    eax, eax
    jz      9f
    movss   [rbx+4], xmm0
    mov     r12, rsi
    mov     eax, 1
9:  pop     rbx
    ret

# do_lp_auto - landscape.paint_auto: every sample's weights by the paint
#   layers' rules (a soft edge: 5% of the range, 5 degrees); none fits: the
#   first layer
do_lp_auto:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    push    rbp
    sub     rsp, 104                    # +0 N, +4 cell, +8 lo, +12 range,
    call    la_active                   #  +16 j, +20 i, +24 slope, +28 h,
    test    rax, rax                    #  +32 m[8], +64 sum
    jz      9f
    mov     r14, rax
    cmp     dword ptr [rdx+LB_NP], 0
    je      9f
    mov     rdi, rdx
    mov     esi, [rdx+LB_N]
    mov     edx, 1
    call    la_make
    test    rax, rax
    jz      9f
    mov     rbx, rax
    mov     eax, [rbx+LB_N]
    mov     [rsp], eax
    dec     eax
    cvtsi2ss xmm1, eax
    movss   xmm0, [rbx+LB_SIZE]
    divss   xmm0, xmm1
    movss   [rsp+4], xmm0
    movss   xmm0, [rbx+LB_HMIN]
    movss   [rsp+8], xmm0
    movss   xmm1, [rbx+LB_HMAX]
    subss   xmm1, xmm0
    maxss   xmm1, [rip+ls_tiny]
    movss   [rsp+12], xmm1
    mov     r12, [rbx+LB_H]
    add     r12, rbx
    mov     r13, [rbx+LB_SPLAT]
    add     r13, rbx
    xor     r15d, r15d                  # j
1:  cmp     r15d, [rsp]
    jae     8f
    xor     ebp, ebp                    # i
2:  cmp     ebp, [rsp]
    jae     7f
    mov     eax, r15d                   # slope: atan |grad| (central)
    imul    eax, [rsp]
    add     eax, ebp
    movss   xmm0, [r12+rax*4]
    subss   xmm0, [rsp+8]
    divss   xmm0, [rsp+12]
    movss   [rsp+28], xmm0              # h (0..1)
    mov     ecx, ebp
    test    ecx, ecx
    jz      21f
    dec     ecx
21: mov     edx, ebp
    inc     edx
    cmp     edx, [rsp]
    jb      22f
    dec     edx
22: mov     eax, r15d
    imul    eax, [rsp]
    lea     r8, [r12+rax*4]
    movss   xmm0, [r8+rdx*4]
    subss   xmm0, [r8+rcx*4]
    sub     edx, ecx
    cvtsi2ss xmm2, edx
    mulss   xmm2, [rsp+4]
    divss   xmm0, xmm2
    mov     ecx, r15d
    test    ecx, ecx
    jz      23f
    dec     ecx
23: mov     edx, r15d
    inc     edx
    cmp     edx, [rsp]
    jb      24f
    dec     edx
24: mov     eax, edx
    imul    eax, [rsp]
    add     eax, ebp
    movss   xmm1, [r12+rax*4]
    mov     eax, ecx
    imul    eax, [rsp]
    add     eax, ebp
    subss   xmm1, [r12+rax*4]
    sub     edx, ecx
    cvtsi2ss xmm2, edx
    mulss   xmm2, [rsp+4]
    divss   xmm1, xmm2
    mulss   xmm0, xmm0
    mulss   xmm1, xmm1
    addss   xmm0, xmm1
    sqrtss  xmm0, xmm0
    movss   [rsp+24], xmm0
    fld     dword ptr [rsp+24]
    fld1
    fpatan
    fstp    dword ptr [rsp+24]
    movss   xmm0, [rsp+24]
    mulss   xmm0, [rip+ls_r2d]
    movss   [rsp+24], xmm0
    xorps   xmm7, xmm7                  # each layer's fit
    xor     ecx, ecx
3:  cmp     ecx, [rbx+LB_NP]
    jae     4f
    imul    rdx, rcx, LP_SZ
    lea     rdx, [rbx+LB_PAINT+rdx]
    movss   xmm0, [rsp+28]
    movss   xmm1, [rdx+LP_HLO]
    movss   xmm2, [rdx+LP_HHI]
    movss   xmm3, [rip+ls_soft_h]
    call    ls_fit
    movss   [rsp+72], xmm0
    movss   xmm0, [rsp+24]
    movss   xmm1, [rdx+LP_SLO]
    movss   xmm2, [rdx+LP_SHI]
    movss   xmm3, [rip+ls_soft_s]
    call    ls_fit
    mulss   xmm0, [rsp+72]
    movss   xmm1, [rdx+LP_HLO]          # (a layer without a rule: none)
    comiss  xmm1, [rdx+LP_HHI]
    jb      31f
    movss   xmm1, [rdx+LP_SLO]
    comiss  xmm1, [rdx+LP_SHI]
    jb      31f
    xorps   xmm0, xmm0
31: movss   [rsp+32+rcx*4], xmm0
    addss   xmm7, xmm0
    inc     ecx
    jmp     3b
4:  mov     eax, r15d                   # the weights
    imul    eax, [rsp]
    add     eax, ebp
    lea     rdi, [r13+rax*8]
    mov     qword ptr [rdi], 0
    comiss  xmm7, [rip+ls_tiny]
    ja      41f
    mov     byte ptr [rdi], 255
    jmp     6f
41: xor     ecx, ecx
5:  cmp     ecx, [rbx+LB_NP]
    jae     6f
    movss   xmm0, [rsp+32+rcx*4]
    divss   xmm0, xmm7
    mulss   xmm0, [rip+ls_255]
    cvttss2si eax, xmm0
    mov     [rdi+rcx], al
    inc     ecx
    jmp     5b
6:  inc     ebp
    jmp     2b
7:  inc     r15d
    jmp     1b
8:  mov     rdi, r14
    mov     rsi, rbx
    call    la_obj_set
    mov     rdi, rbx
    call    la_unref
9:  add     rsp, 104
    pop     rbp
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# ls_fit(xmm0=v, xmm1=lo, xmm2=hi, xmm3=soft) -> xmm0 = 1 inside lo..hi,
#   fading over soft outside; lo >= hi: 1 (no rule on it)
ls_fit:
    comiss  xmm1, xmm2
    jae     8f
    movaps  xmm4, xmm0                  # min(v - lo, hi - v) / soft + 0.5
    subss   xmm4, xmm1
    subss   xmm2, xmm0
    minss   xmm4, xmm2
    divss   xmm4, xmm3
    addss   xmm4, [rip+ls_half]
    maxss   xmm4, [rip+ls_zero]
    minss   xmm4, [rip+ls_one]
    movaps  xmm0, xmm4
    ret
8:  movss   xmm0, [rip+ls_one]
    ret

.section .note.GNU-stack,"",@progbits
