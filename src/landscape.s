# =============================================================================
#  BeeModel - landscapes: heightfields of N x N samples (65 to 4097 a side)
#  over a square of a chosen size, centred on the object, on its XZ plane.
#
#  A landscape is a mesh object whose mesh carries a landscape block
#  (ME_LAND): one reference-counted mapping, copy-on-write like meshes, so
#  undo steps and copies share it. Every change makes a new block and a new
#  display mesh (a grid of the heights, at most 513 a side: every 2nd, 4th
#  ... sample of a bigger landscape). The block:
#
#    a header (LB_), up to 8 layers (LY_, 64 bytes), up to 8 paint layers,
#    then page-aligned arrays at offsets the header keeps (0: none): the
#    heights (f32 N x N, row-major: row j along Z, sample i along X), the
#    cache (the heights after the last erosion layer, so changes above it
#    start from there), each layer's own data (Sculpted: offsets added;
#    Flatten area: its mask), the splat map (u8 x 8 a sample).
#
#  The layers, bottom up, a non-destructive stack (each has a strength and
#  can be hidden):
#    Generate  adds noise: fBm, ridged, billow (Perlin octaves) or Voronoi
#              cells, with a seed, scale (features across) and height (m)
#    Erode     droplet erosion (procgen.s er_run) over the heights so far,
#              then thermal erosion (material slides where it is steeper
#              than the talus angle)
#    Terrace   flat steps over the heights' range, risers a Smooth fraction
#    Sculpted  the strokes' offsets
#    Flatten   pulls the heights to a level where its mask says
#  Generating runs on every core (rows); erosion runs on one (droplets
#  follow each other), and its result is cached.
# =============================================================================
.intel_syntax noprefix
.include "const.inc"
.include "macros.inc"

.globl la_ref
.globl la_unref
.globl la_of
.globl la_height
.globl la_info
.globl la_load
.globl la_make
.globl la_eval
.globl la_display
.globl la_obj_set
.globl la_wheight
.globl lv_extra
.globl la_active
.globl la_word
.globl la_num

.include "landscape.inc"

.section .rodata
.align 16
la_absm:        .long 0x7fffffff, 0, 0, 0
la_one:         .float 1.0
la_half:        .float 0.5
la_two:         .float 2.0
la_zero:        .float 0.0
la_tiny:        .float 1.0e-6
la_s13:         .float 13.37
la_s7:          .float 7.77
la_s3:          .float 3.1
la_q:           .float 0.25
la_inv16:       .float 1.52587890625e-5     # 1 / 65536
la_deg:         .float 0.017453292
la_big:         .float 1.0e30
la_nbig:        .float -1.0e30
la_fric:        .float 0.5
la_200:         .float 200.0
la_rate:        .float 0.3
la_talus:       .float 35.0
la_075:         .float 0.75
la_r1:          .float 101.0
la_r2:          .float 37.0
la_r3:          .float 67.0
la_r4:          .float 23.0
la_wave:        .float 0.03
# a new layer's parameters, by type (strength, then 10)
la_defs:        .float 1.0, 0, 1, 3, 30, 6, 0, 0, 0, 0, 0     # generate: fbm, seed 1, scale 3, 30 m, 6 octaves
                .float 1.0, 0, 0.3, 1, 0, 35, 0, 0, 0, 0, 0   # erode: droplets (0: N^2 / 8), rate, seed, thermal, talus
                .float 1.0, 8, 0.2, 0, 0, 0, 0, 0, 0, 0, 0    # terrace: steps, smooth
                .float 1.0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0      # sculpted
                .float 1.0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0      # flatten: height
                .float 1.0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0      # heightmap (imported)
s_landscape:    .asciz "Landscape"
# the presets' layers: per preset a count, then per layer its type,
#   strength and 10 parameters (12 dwords)
.align 4
la_pdata:       .long 0                                                     # flat
                .long 2                                                     # hills
                .long 1
                .float 1.0, 0, 1, 3, 30, 6, 0, 0, 0, 0, 0
                .long 2
                .float 1.0, 0, 0.3, 1, 0, 35, 0, 0, 0, 0, 0
                .long 2                                                     # mountains
                .long 1
                .float 1.0, 1, 2, 2.5, 140, 8, 0, 0, 0, 0, 0
                .long 2
                .float 1.0, 0, 0.45, 2, 6, 40, 0, 0, 0, 0, 0
                .long 3                                                     # canyon
                .long 1
                .float 1.0, 0, 4, 2, 60, 5, 0, 0, 0, 0, 0
                .long 3
                .float 1.0, 6, 0.12, 0, 0, 0, 0, 0, 0, 0, 0
                .long 2
                .float 1.0, 0, 0.35, 5, 0, 35, 0, 0, 0, 0, 0
                .long 2                                                     # dunes
                .long 1
                .float 1.0, 2, 6, 7, 7, 3, 0, 0, 0, 0, 0
                .long 2
                .float 1.0, 1, 0.1, 7, 25, 30, 0, 0, 0, 0, 0
                .long 2                                                     # island
                .long 1
                .float 1.0, 0, 9, 2.5, 50, 7, 1, -14, 0, 0, 0
                .long 2
                .float 1.0, 0, 0.3, 9, 0, 35, 0, 0, 0, 0, 0
k_la_size:      .asciz "size"
k_la_res:       .asciz "res"
k_la_seed:      .asciz "seed"
k_la_detail:    .asciz "detail"
k_la_add:       .asciz "add"
k_la_set:       .asciz "set"
k_la_remove:    .asciz "remove"
k_la_hide:      .asciz "hide"
k_la_show:      .asciz "show"
k_la_strength:  .asciz "strength"
k_la_noise:     .asciz "noise"
k_la_at:        .asciz "at"
k_flat:         .asciz "flat"
k_hills:        .asciz "hills"
k_mountains:    .asciz "mountains"
k_canyon:       .asciz "canyon"
k_dunes:        .asciz "dunes"
k_island:       .asciz "island"
s_water:        .asciz "Water"
s_wpreset:      .asciz "water"
k_generate:     .asciz "generate"
k_erode:        .asciz "erode"
k_terrace:      .asciz "terrace"
k_sculpted:     .asciz "sculpted"
k_flatten:      .asciz "flatten"
k_heightmap:    .asciz "heightmap"
k_fbm:          .asciz "fbm"
k_ridged:       .asciz "ridged"
k_billow:       .asciz "billow"
k_cells:        .asciz "cells"
k_p_seed:       .asciz "seed"
k_p_scale:      .asciz "scale"
k_p_height:     .asciz "height"
k_p_octaves:    .asciz "octaves"
k_p_droplets:   .asciz "droplets"
k_p_rate:       .asciz "rate"
k_p_thermal:    .asciz "thermal"
k_p_talus:      .asciz "talus"
k_p_steps:      .asciz "steps"
k_p_smooth:     .asciz "smooth"
k_p_island:     .asciz "island"
k_p_offset:     .asciz "offset"
.align 8
la_types:       .quad k_generate, k_erode, k_terrace, k_sculpted, k_flatten, k_heightmap, 0
la_noises:      .quad k_fbm, k_ridged, k_billow, k_cells, 0
# each type's parameter names (by slot; 0 ends)
la_pn_gen:      .quad k_la_noise, k_p_seed, k_p_scale, k_p_height, k_p_octaves, k_p_island, k_p_offset, 0
la_pn_ero:      .quad k_p_droplets, k_p_rate, k_p_seed, k_p_thermal, k_p_talus, 0
la_pn_ter:      .quad k_p_steps, k_p_smooth, 0
la_pn_none:     .quad 0
la_pn_flat:     .quad k_p_height, 0
la_pnames:      .quad la_pn_gen, la_pn_ero, la_pn_ter, la_pn_none, la_pn_flat, la_pn_none
la_presets:     .quad k_flat, k_hills, k_mountains, k_canyon, k_dunes, k_island, 0
s_la_nosel:     .asciz "  landscape: the active object is not a landscape"
s_la_bad:       .asciz "  landscape: not understood: "
s_la_full:      .asciz "  landscape: 8 layers at most"
s_la_mem:       .asciz "  landscape: out of memory"
s_la_add:       .asciz "  added "
s_la_ms:        .asciz "  landscape evaluated in "
s_la_msu:       .asciz " ms"

OPERATOR op_la_add,   "landscape.add",   "Landscape", do_la_add, flags=OPF_AI_SAFE|OPF_UNDO, doc="Add a landscape: a heightfield with a stack of layers (generate, erode, terrace, sculpted, flatten): landscape.add [flat|hills|mountains|canyon|dunes|island] [size metres (200)] [res samples a side (65-4097: 2^k + 1; 513)] [seed k]"
OPERATOR op_la_flat,  "landscape.add_flat",  "Flat",      do_la_addp, arg=0, flags=OPF_AI_SAFE|OPF_UNDO, doc="Add a flat landscape (to sculpt): landscape.add flat"
OPERATOR op_la_hills, "landscape.add_hills", "Hills",     do_la_addp, arg=1, flags=OPF_AI_SAFE|OPF_UNDO, doc="Add a landscape of eroded hills: landscape.add hills"
OPERATOR op_la_mount, "landscape.add_mountains", "Mountains", do_la_addp, arg=2, flags=OPF_AI_SAFE|OPF_UNDO, doc="Add a landscape of ridged, eroded mountains: landscape.add mountains"
OPERATOR op_la_canyon,"landscape.add_canyon", "Canyon",   do_la_addp, arg=3, flags=OPF_AI_SAFE|OPF_UNDO, doc="Add a terraced canyon landscape: landscape.add canyon"
OPERATOR op_la_dunes, "landscape.add_dunes", "Dunes",     do_la_addp, arg=4, flags=OPF_AI_SAFE|OPF_UNDO, doc="Add a landscape of dunes (billows, slid to their talus): landscape.add dunes"
OPERATOR op_la_island,"landscape.add_island", "Island",   do_la_addp, arg=5, flags=OPF_AI_SAFE|OPF_UNDO, doc="Add an island landscape and its sea: a Water plane at the landscape's height (water material, ripples; bodies below it float): landscape.add island"
OPERATOR op_la_layer, "landscape.layer", "Landscape Layer", do_la_layer, flags=OPF_AI_SAFE|OPF_UNDO, doc="Change the active landscape's layers: landscape.layer add <generate|erode|terrace|sculpted|flatten> [key value ...] | set <i> [key value ...] | remove <i> | hide <i> | show <i>. Keys: strength; generate: noise fbm|ridged|billow|cells, seed, scale, height, octaves; erode: droplets, rate, seed, thermal (iterations), talus (degrees); terrace: steps, smooth; flatten: height, at x z radius (adds a round area)"
OPERATOR op_la_set,   "landscape.set",   "Landscape Settings", do_la_set, flags=OPF_AI_SAFE|OPF_UNDO, doc="The active landscape's size and samples: landscape.set [size metres] [res samples a side] [detail display samples a side (at most)]"

.section .bss
.align 8
lv_b:           .skip 8                 # evaluating: the block,
lv_h:           .skip 8                 #  its heights,
lv_l:           .skip 8                 #  the layer
lv_n:           .skip 4
lv_inv:         .skip 4                 # 1 / (N - 1)
lv_scale:       .skip 4                 # generate: its noise space,
lv_ox:          .skip 4
lv_oz:          .skip 4
lv_oy:          .skip 4
lv_amp:         .skip 4                 #  strength x height,
lv_kind:        .skip 4                 #  the noise,
lv_oct:         .skip 4                 #  octaves,
lv_seed:        .skip 4
lv_isl:         .skip 4                 #  an island,
lv_off:         .skip 4                 #  an offset (m)
lv_extra:       .skip 8                 # la_make: the extra array's offset
.text

# -----------------------------------------------------------------------------
# la_ref(rdi=block or 0), la_unref(rdi=block or 0)
# -----------------------------------------------------------------------------
la_ref:
    test    rdi, rdi
    jz      1f
    lock inc dword ptr [rdi+LB_REFS]
1:  ret
la_unref:
    test    rdi, rdi
    jz      1f
    lock dec dword ptr [rdi+LB_REFS]
    jnz     1f
    mov     rsi, [rdi+LB_BYTES]
    mov     eax, SYS_MUNMAP
    syscall
1:  ret

# la_of(rdi=object) -> rax = its landscape block, or 0
la_of:
    xor     eax, eax
    test    rdi, rdi
    jz      1f
    cmp     dword ptr [rdi+OB_TYPE], OT_MESH
    jne     1f
    mov     rax, [rdi+OB_MESH]
    test    rax, rax
    jz      1f
    mov     rax, [rax+ME_LAND]
1:  ret

# la_arr(edi=N) -> rax = bytes of an f32 N x N array (page multiple)
la_arr:
    mov     eax, edi
    imul    rax, rax
    shl     rax, 2
    add     rax, 4095
    and     rax, -4096
    ret

# -----------------------------------------------------------------------------
# la_make(rdi=source block or 0, esi=N, edx=want: 1 the splat map, 2 one
#   more f32 array (its offset in lv_extra, zeroed)) -> rax = a new block
#   (references 1) with the source's header, layers and arrays (the same N),
#   repacked; 0 when out of memory
# -----------------------------------------------------------------------------
la_make:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    sub     rsp, 16
    mov     r12, rdi
    mov     r13d, esi
    mov     [rsp], edx
    mov     edi, r13d
    call    la_arr
    mov     r14, rax                    # one array
    lea     rbx, [rax*2+LB_DATA]        # header, heights, cache
    test    r12, r12
    jz      2f
    xor     ecx, ecx                    # the layers' arrays
1:  cmp     ecx, [r12+LB_NL]
    jae     2f
    imul    rdx, rcx, LY_SZ
    cmp     qword ptr [r12+LB_LAY+rdx+LY_DATA], 0
    je      11f
    add     rbx, r14
11: inc     ecx
    jmp     1b
2:  test    dword ptr [rsp], 1          # the splat map (8 bytes a sample)
    jnz     21f
    test    r12, r12
    jz      22f
    cmp     qword ptr [r12+LB_SPLAT], 0
    je      22f
21: lea     rbx, [rbx+r14*2]
22: test    dword ptr [rsp], 2
    jz      23f
    add     rbx, r14
23: xor     edi, edi
    mov     rsi, rbx
    mov     edx, PROT_RW
    mov     r10d, MAP_ANON_PRIV
    mov     r8d, -1
    xor     r9d, r9d
    mov     eax, SYS_MMAP
    syscall
    cmp     rax, -4096
    jbe     3f
    xor     eax, eax
    jmp     9f
3:  mov     r15, rax
    test    r12, r12                    # the header (and layers)
    jz      31f
    mov     rsi, r12
    mov     rdi, r15
    mov     ecx, LB_DATA/8
    rep     movsq
31: mov     dword ptr [r15+LB_REFS], 1
    mov     [r15+LB_N], r13d
    mov     [r15+LB_BYTES], rbx
    mov     qword ptr [r15+LB_SPLAT], 0
    mov     rbx, LB_DATA                # the next free offset
    mov     [r15+LB_H], rbx
    add     rbx, r14
    mov     [r15+LB_C], rbx
    add     rbx, r14
    test    r12, r12
    jnz     32f
    mov     dword ptr [r15+LB_CL], -1
    jmp     4f
32: mov     rsi, [r12+LB_H]             # heights and cache
    add     rsi, r12
    mov     rdi, [r15+LB_H]
    add     rdi, r15
    mov     rcx, r14
    shl     rcx, 1
    shr     rcx, 3
    rep     movsq
    xor     ecx, ecx                    # each layer's array
33: cmp     ecx, [r12+LB_NL]
    jae     34f
    imul    rdx, rcx, LY_SZ
    mov     rsi, [r12+LB_LAY+rdx+LY_DATA]
    test    rsi, rsi
    jz      331f
    mov     [r15+LB_LAY+rdx+LY_DATA], rbx
    push    rcx
    add     rsi, r12
    lea     rdi, [r15+rbx]
    mov     rcx, r14
    shr     rcx, 3
    rep     movsq
    pop     rcx
    add     rbx, r14
331:inc     ecx
    jmp     33b
34: cmp     qword ptr [r12+LB_SPLAT], 0 # the splat map
    je      4f
    mov     [r15+LB_SPLAT], rbx
    mov     rsi, [r12+LB_SPLAT]
    add     rsi, r12
    lea     rdi, [r15+rbx]
    mov     rcx, r14
    shr     rcx, 2
    rep     movsq
    lea     rbx, [rbx+r14*2]
4:  test    dword ptr [rsp], 1          # a new splat map
    jz      41f
    cmp     qword ptr [r15+LB_SPLAT], 0
    jne     41f
    mov     [r15+LB_SPLAT], rbx
    lea     rbx, [rbx+r14*2]
41: test    dword ptr [rsp], 2          # one more array
    jz      42f
    mov     [rip+lv_extra], rbx
    add     rbx, r14
42: mov     rax, r15
9:  add     rsp, 16
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# -----------------------------------------------------------------------------
# la_eval(rdi=block, esi=the first layer that changed) - the heights again
#   (from the cache when it holds a layer below that one)
# -----------------------------------------------------------------------------
la_eval:
    push    rbx
    push    r12
    push    r13
    push    r14
    sub     rsp, 8
    mov     rbx, rdi
    mov     r12d, esi
    call    now_ms
    mov     r14, rax
    mov     [rip+lv_b], rbx
    mov     rax, [rbx+LB_H]
    add     rax, rbx
    mov     [rip+lv_h], rax
    mov     eax, [rbx+LB_N]
    mov     [rip+lv_n], eax
    dec     eax
    cvtsi2ss xmm1, eax
    movss   xmm0, [rip+la_one]
    divss   xmm0, xmm1
    movss   [rip+lv_inv], xmm0
    mov     edi, [rbx+LB_N]
    call    la_arr
    mov     rcx, rax                    # (bytes of an array)
    mov     eax, [rbx+LB_CL]            # from the cache?
    test    eax, eax
    js      1f
    cmp     eax, r12d
    jge     1f
    cmp     eax, [rbx+LB_NL]
    jge     1f
    lea     r13d, [rax+1]
    mov     rsi, [rbx+LB_C]
    add     rsi, rbx
    mov     rdi, [rip+lv_h]
    shr     rcx, 3
    rep     movsq
    jmp     2f
1:  mov     rdi, [rip+lv_h]             # from nothing
    shr     rcx, 3
    xor     eax, eax
    rep     stosq
    mov     dword ptr [rbx+LB_CL], -1
    xor     r13d, r13d
2:  cmp     r13d, [rbx+LB_NL]
    jae     8f
    imul    rax, r13, LY_SZ
    lea     rax, [rbx+LB_LAY+rax]
    mov     [rip+lv_l], rax
    test    dword ptr [rax+LY_FLG], 1
    jnz     7f
    mov     ecx, [rax+LY_TYPE]
    cmp     ecx, 1
    jne     3f
    call    lg_generate
    jmp     7f
3:  cmp     ecx, 2
    jne     4f
    call    lg_erode
    mov     edi, [rbx+LB_N]             # cached: the heights after it
    call    la_arr
    mov     rcx, rax
    shr     rcx, 3
    mov     rsi, [rip+lv_h]
    mov     rdi, [rbx+LB_C]
    add     rdi, rbx
    rep     movsq
    mov     [rbx+LB_CL], r13d
    jmp     7f
4:  cmp     ecx, 3
    jne     5f
    call    lg_terrace
    jmp     7f
5:  cmp     ecx, 4                      # (sculpted, a heightmap: added)
    je      51f
    cmp     ecx, 6
    jne     6f
51: call    lg_sculpted
    jmp     7f
6:  cmp     ecx, 5
    jne     7f
    call    lg_flatten
7:  inc     r13d
    jmp     2b
8:  call    lv_range                    # the range, a new version
    movss   [rbx+LB_HMIN], xmm0
    movss   [rbx+LB_HMAX], xmm1
    inc     dword ptr [rbx+LB_VER]
    call    now_ms
    sub     rax, r14
    mov     [rbx+LB_MS], eax
    add     rsp, 8
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# lv_range -> xmm0 = the lowest height, xmm1 = the highest (lv_h, lv_n)
lv_range:
    mov     rdx, [rip+lv_h]
    mov     eax, [rip+lv_n]
    imul    rax, rax
    movss   xmm0, [rip+la_big]
    movss   xmm1, [rip+la_nbig]
1:  test    rax, rax
    jz      2f
    dec     rax
    minss   xmm0, [rdx+rax*4]
    maxss   xmm1, [rdx+rax*4]
    jmp     1b
2:  ret

# lv_count -> rax = samples (lv_n squared)
lv_count:
    mov     eax, [rip+lv_n]
    imul    rax, rax
    ret

# -----------------------------------------------------------------------------
# Generate: noise rows in parallel
# -----------------------------------------------------------------------------
lg_generate:
    sub     rsp, 8
    mov     rax, [rip+lv_l]
    movss   xmm0, [rax+LY_STR]
    mulss   xmm0, [rax+LY_P+12]         # x height
    movss   [rip+lv_amp], xmm0
    cvttss2si ecx, [rax+LY_P]
    and     ecx, 3
    mov     [rip+lv_kind], ecx
    xor     ecx, ecx                    # island, offset
    movss   xmm0, [rax+LY_P+20]
    comiss  xmm0, [rip+la_zero]
    seta    cl
    mov     [rip+lv_isl], ecx
    movss   xmm0, [rax+LY_P+24]
    mulss   xmm0, [rax+LY_STR]
    movss   [rip+lv_off], xmm0
    cvttss2si ecx, [rax+LY_P+16]
    cmp     ecx, 1
    jge     1f
    mov     ecx, 1
1:  cmp     ecx, 12
    jle     2f
    mov     ecx, 12
2:  mov     [rip+lv_oct], ecx
    movss   xmm0, [rax+LY_P+8]
    maxss   xmm0, [rip+la_tiny]
    movss   [rip+lv_scale], xmm0
    cvttss2si ecx, [rax+LY_P+4]         # the seed: an offset into the noise
    mov     [rip+lv_seed], ecx
    cvtsi2ss xmm0, ecx
    movss   xmm1, xmm0
    mulss   xmm1, [rip+la_s13]
    movss   [rip+lv_ox], xmm1
    movss   xmm1, xmm0
    mulss   xmm1, [rip+la_s7]
    movss   [rip+lv_oz], xmm1
    mulss   xmm0, [rip+la_s3]
    addss   xmm0, [rip+la_half]
    movss   [rip+lv_oy], xmm0
    lea     rdi, [rip+lg_job]
    xor     esi, esi
    mov     edx, [rip+lv_n]
    mov     ecx, 4
    call    parallel_for
    add     rsp, 8
    ret

# lg_job(rdi=ctx, esi=first row, edx=end)
lg_job:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    sub     rsp, 64                     # +0 p[3], +16 amplitude, +20
    mov     r12d, esi                   #  frequency, +24 sum, +28 amplitudes,
    mov     r13d, edx                   #  +32 u, +36 w
.Llg_row:
    cmp     r12d, r13d
    jae     .Llg_out
    xor     r14d, r14d
.Llg_col:
    cmp     r14d, [rip+lv_n]
    jae     .Llg_nrow
    cvtsi2ss xmm0, r14d                 # u, w in the noise's space
    mulss   xmm0, [rip+lv_inv]
    mulss   xmm0, [rip+lv_scale]
    addss   xmm0, [rip+lv_ox]
    movss   [rsp+32], xmm0
    cvtsi2ss xmm0, r12d
    mulss   xmm0, [rip+lv_inv]
    mulss   xmm0, [rip+lv_scale]
    addss   xmm0, [rip+lv_oz]
    movss   [rsp+36], xmm0
    cmp     dword ptr [rip+lv_kind], 3
    je      .Llg_cells
    mov     eax, [rip+la_one]
    mov     [rsp+16], eax
    mov     [rsp+20], eax
    xorps   xmm0, xmm0
    movss   [rsp+24], xmm0
    movss   [rsp+28], xmm0
    xor     ebx, ebx
1:  cmp     ebx, [rip+lv_oct]
    jae     2f
    movss   xmm1, [rsp+20]
    movss   xmm0, [rsp+32]
    mulss   xmm0, xmm1
    movss   [rsp], xmm0
    movss   xmm0, [rip+lv_oy]
    mulss   xmm0, xmm1
    movss   [rsp+4], xmm0
    movss   xmm0, [rsp+36]
    mulss   xmm0, xmm1
    movss   [rsp+8], xmm0
    lea     rdi, [rsp]
    call    perlin
    mov     eax, [rip+lv_kind]
    test    eax, eax
    jz      11f
    andps   xmm0, [rip+la_absm]
    cmp     eax, 2                      # billow: |n|
    je      11f
    movss   xmm1, [rip+la_one]          # ridged: (1 - |n|)^2
    subss   xmm1, xmm0
    mulss   xmm1, xmm1
    movaps  xmm0, xmm1
11: mulss   xmm0, [rsp+16]
    addss   xmm0, [rsp+24]
    movss   [rsp+24], xmm0
    movss   xmm0, [rsp+16]
    addss   xmm0, [rsp+28]
    movss   [rsp+28], xmm0
    movss   xmm0, [rsp+16]
    mulss   xmm0, [rip+la_half]
    movss   [rsp+16], xmm0
    movss   xmm0, [rsp+20]
    addss   xmm0, xmm0
    movss   [rsp+20], xmm0
    inc     ebx
    jmp     1b
2:  movss   xmm0, [rsp+24]
    divss   xmm0, [rsp+28]
    cmp     dword ptr [rip+lv_kind], 0  # fBm: 0.5 + 0.5 sum / A
    jne     .Llg_put
    mulss   xmm0, [rip+la_half]
    addss   xmm0, [rip+la_half]
    jmp     .Llg_put
.Llg_cells:                             # the distance to the nearest of one
    movss   xmm0, [rsp+32]              #  point in each cell (3 x 3 cells)
    roundss xmm1, xmm0, 1
    cvttss2si r8d, xmm1
    movss   xmm0, [rsp+36]
    roundss xmm1, xmm0, 1
    cvttss2si r9d, xmm1
    movss   xmm4, [rip+la_big]
    mov     r10d, -1
3:  mov     r11d, -1
4:  lea     eax, [r8+r11]               # the cell's point
    lea     ecx, [r9+r10]
    imul    eax, eax, 0x8da6b343
    imul    ecx, ecx, 0xd8163841
    xor     eax, ecx
    mov     ecx, [rip+lv_seed]
    imul    ecx, ecx, 0xcb1ab31f
    xor     eax, ecx
    mov     ecx, eax
    shr     ecx, 13
    xor     eax, ecx
    imul    eax, eax, 0x5bd1e995
    mov     ecx, eax
    shr     ecx, 15
    xor     eax, ecx
    mov     ecx, eax
    and     ecx, 0xffff
    cvtsi2ss xmm1, ecx
    mulss   xmm1, [rip+la_inv16]
    lea     ecx, [r8+r11]
    cvtsi2ss xmm2, ecx
    addss   xmm1, xmm2
    subss   xmm1, [rsp+32]
    shr     eax, 16
    cvtsi2ss xmm2, eax
    mulss   xmm2, [rip+la_inv16]
    lea     ecx, [r9+r10]
    cvtsi2ss xmm3, ecx
    addss   xmm2, xmm3
    subss   xmm2, [rsp+36]
    mulss   xmm1, xmm1
    mulss   xmm2, xmm2
    addss   xmm1, xmm2
    minss   xmm4, xmm1
    inc     r11d
    cmp     r11d, 1
    jle     4b
    inc     r10d
    cmp     r10d, 1
    jle     3b
    sqrtss  xmm0, xmm4
    minss   xmm0, [rip+la_one]
.Llg_put:
    cmp     dword ptr [rip+lv_isl], 0   # an island: down towards the edges
    je      1f                          #  (1 - r^2, r from the middle 0..1
    cvtsi2ss xmm1, r14d                 #  at the edges' middles)
    mulss   xmm1, [rip+lv_inv]
    subss   xmm1, [rip+la_half]
    cvtsi2ss xmm2, r12d
    mulss   xmm2, [rip+lv_inv]
    subss   xmm2, [rip+la_half]
    mulss   xmm1, xmm1
    mulss   xmm2, xmm2
    addss   xmm1, xmm2
    addss   xmm1, xmm1
    addss   xmm1, xmm1
    movss   xmm2, [rip+la_one]
    subss   xmm2, xmm1
    maxss   xmm2, [rip+la_zero]
    mulss   xmm0, xmm2
1:  mulss   xmm0, [rip+lv_amp]
    addss   xmm0, [rip+lv_off]
    mov     eax, r12d
    imul    eax, [rip+lv_n]
    add     eax, r14d
    mov     rcx, [rip+lv_h]
    addss   xmm0, [rcx+rax*4]
    movss   [rcx+rax*4], xmm0
    inc     r14d
    jmp     .Llg_col
.Llg_nrow:
    inc     r12d
    jmp     .Llg_row
.Llg_out:
    add     rsp, 64
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# -----------------------------------------------------------------------------
# Erode: droplets (er_run) over the heights scaled to 0..1, then thermal
#   erosion; the result mixed in by the strength
# -----------------------------------------------------------------------------
lg_erode:
    push    rbx
    push    r12
    push    r13
    push    r14
    sub     rsp, 40                     # +0 min, +4 range, +8 talus step,
    call    lv_range                    #  +12 rate
    movss   [rsp], xmm0
    subss   xmm1, xmm0
    comiss  xmm1, [rip+la_tiny]
    jbe     9f                          # (flat: nothing runs)
    movss   [rsp+4], xmm1
    mov     edi, [rip+lv_n]
    call    la_arr
    mov     r13, rax
    xor     edi, edi
    mov     rsi, rax
    mov     edx, PROT_RW
    mov     r10d, MAP_ANON_PRIV
    mov     r8d, -1
    xor     r9d, r9d
    mov     eax, SYS_MMAP
    syscall
    cmp     rax, -4096
    ja      9f
    mov     rbx, rax                    # heights 0..1
    call    lv_count
    mov     r12, rax
    mov     rdx, [rip+lv_h]
    xor     ecx, ecx
1:  cmp     rcx, r12
    jae     2f
    movss   xmm0, [rdx+rcx*4]
    subss   xmm0, [rsp]
    divss   xmm0, [rsp+4]
    movss   [rbx+rcx*4], xmm0
    inc     rcx
    jmp     1b
2:  mov     [rip+er_h], rbx
    mov     eax, [rip+lv_n]
    mov     [rip+er_n], eax
    mov     r14, [rip+lv_l]
    cvttss2si eax, [r14+LY_P+8]         # the seed
    imul    eax, eax, 0x9E3779B1
    or      eax, 1
    mov     [rip+er_rng], eax
    cvttss2si edi, [r14+LY_P]           # droplets (0: a sample in 8)
    test    edi, edi
    jg      3f
    mov     rdi, r12
    shr     rdi, 3
3:  cmp     edi, 16000000
    jle     4f
    mov     edi, 16000000
4:  movss   xmm0, [r14+LY_P+4]          # the rate
    maxss   xmm0, [rip+la_zero]
    minss   xmm0, [rip+la_one]
    call    er_run
    cvttss2si r12d, [r14+LY_P+12]       # thermal iterations
    test    r12d, r12d
    jle     6f
    cmp     r12d, 1000
    jle     41f
    mov     r12d, 1000
41: movss   xmm0, [r14+LY_P+16]         # talus: tan(angle) x cell / range
    mulss   xmm0, [rip+la_deg]
    movss   [rsp+8], xmm0
    fld     dword ptr [rsp+8]
    fptan
    fstp    st(0)
    fstp    dword ptr [rsp+8]
    mov     rax, [rip+lv_b]
    movss   xmm0, [rax+LB_SIZE]
    mulss   xmm0, [rip+lv_inv]
    mulss   xmm0, [rsp+8]
    divss   xmm0, [rsp+4]
    movss   [rsp+8], xmm0
5:  mov     rdi, rbx
    movss   xmm0, [rsp+8]
    call    lg_thermal
    dec     r12d
    jnz     5b
6:  mov     rdx, [rip+lv_h]             # back, mixed in
    call    lv_count
    mov     rcx, rax
    movss   xmm2, [r14+LY_STR]
7:  test    rcx, rcx
    jz      8f
    dec     rcx
    movss   xmm0, [rbx+rcx*4]
    mulss   xmm0, [rsp+4]
    addss   xmm0, [rsp]
    movss   xmm1, [rdx+rcx*4]
    subss   xmm0, xmm1
    mulss   xmm0, xmm2
    addss   xmm0, xmm1
    movss   [rdx+rcx*4], xmm0
    jmp     7b
8:  mov     rdi, rbx
    mov     rsi, r13
    mov     eax, SYS_MUNMAP
    syscall
9:  add     rsp, 40
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# lg_thermal(rdi=heights, xmm0=talus step) - one pass: each pair of
#   neighbours (right, below) steeper than the talus shares a quarter of
#   the excess
lg_thermal:
    mov     r8d, [rip+lv_n]
    lea     r9d, [r8-1]
    xor     r10d, r10d                  # row
1:  cmp     r10d, r8d
    jae     9f
    xor     r11d, r11d                  # column
2:  cmp     r11d, r8d
    jae     8f
    mov     eax, r10d
    imul    eax, r8d
    add     eax, r11d
    cmp     r11d, r9d                   # right
    jae     3f
    lea     ecx, [rax+1]
    call    lt_pair
3:  cmp     r10d, r9d                   # below
    jae     4f
    lea     ecx, [rax+r8]
    call    lt_pair
4:  inc     r11d
    jmp     2b
8:  inc     r10d
    jmp     1b
9:  ret
# lt_pair(eax, ecx = samples; rdi heights, xmm0 talus)
lt_pair:
    movss   xmm1, [rdi+rax*4]
    subss   xmm1, [rdi+rcx*4]           # d = a - b
    movaps  xmm2, xmm1
    andps   xmm2, [rip+la_absm]
    subss   xmm2, xmm0                  # |d| - talus
    xorps   xmm3, xmm3
    comiss  xmm2, xmm3
    jbe     1f
    mulss   xmm2, [rip+la_q]
    comiss  xmm1, xmm3
    ja      2f
    xorps   xmm3, xmm3
    subss   xmm3, xmm2
    movaps  xmm2, xmm3
2:  movss   xmm1, [rdi+rax*4]
    subss   xmm1, xmm2
    movss   [rdi+rax*4], xmm1
    movss   xmm1, [rdi+rcx*4]
    addss   xmm1, xmm2
    movss   [rdi+rcx*4], xmm1
1:  ret

# -----------------------------------------------------------------------------
# Terrace: steps over the range; a riser takes the last Smooth of a step
# -----------------------------------------------------------------------------
lg_terrace:
    sub     rsp, 24
    call    lv_range
    movss   [rsp], xmm0
    subss   xmm1, xmm0
    comiss  xmm1, [rip+la_tiny]
    jbe     9f
    movss   [rsp+4], xmm1
    mov     rax, [rip+lv_l]
    movss   xmm0, [rax+LY_P]            # steps
    maxss   xmm0, [rip+la_one]
    roundss xmm0, xmm0, 1
    movss   [rsp+8], xmm0
    movss   xmm0, [rax+LY_P+4]          # smooth
    maxss   xmm0, [rip+la_zero]
    minss   xmm0, [rip+la_one]
    movss   [rsp+12], xmm0
    movss   xmm0, [rax+LY_STR]
    movss   [rsp+16], xmm0
    call    lv_count
    mov     rcx, rax
    mov     rdx, [rip+lv_h]
1:  test    rcx, rcx
    jz      9f
    dec     rcx
    movss   xmm0, [rdx+rcx*4]           # t = (h - min) / range x steps
    subss   xmm0, [rsp]
    divss   xmm0, [rsp+4]
    mulss   xmm0, [rsp+8]
    roundss xmm1, xmm0, 1               # k
    subss   xmm0, xmm1                  # f
    movss   xmm2, [rip+la_one]          # f' = (f - (1 - s)) / s past 1 - s
    subss   xmm2, [rsp+12]
    subss   xmm0, xmm2
    xorps   xmm3, xmm3
    maxss   xmm0, xmm3
    movss   xmm3, [rsp+12]
    comiss  xmm3, [rip+la_tiny]
    jbe     2f
    divss   xmm0, xmm3
    jmp     3f
2:  xorps   xmm0, xmm0
3:  addss   xmm0, xmm1
    divss   xmm0, [rsp+8]
    mulss   xmm0, [rsp+4]
    addss   xmm0, [rsp]
    movss   xmm1, [rdx+rcx*4]
    subss   xmm0, xmm1
    mulss   xmm0, [rsp+16]
    addss   xmm0, xmm1
    movss   [rdx+rcx*4], xmm0
    jmp     1b
9:  add     rsp, 24
    ret

# Sculpted: the offsets added
lg_sculpted:
    mov     rax, [rip+lv_l]
    mov     rsi, [rax+LY_DATA]
    test    rsi, rsi
    jz      9f
    add     rsi, [rip+lv_b]
    movss   xmm2, [rax+LY_STR]
    call    lv_count
    mov     rcx, rax
    mov     rdx, [rip+lv_h]
1:  test    rcx, rcx
    jz      9f
    dec     rcx
    movss   xmm0, [rsi+rcx*4]
    mulss   xmm0, xmm2
    addss   xmm0, [rdx+rcx*4]
    movss   [rdx+rcx*4], xmm0
    jmp     1b
9:  ret

# Flatten area: h + strength mask (level - h)
lg_flatten:
    mov     rax, [rip+lv_l]
    mov     rsi, [rax+LY_DATA]
    test    rsi, rsi
    jz      9f
    add     rsi, [rip+lv_b]
    movss   xmm2, [rax+LY_STR]
    movss   xmm3, [rax+LY_P]
    call    lv_count
    mov     rcx, rax
    mov     rdx, [rip+lv_h]
1:  test    rcx, rcx
    jz      9f
    dec     rcx
    movss   xmm1, [rdx+rcx*4]
    movaps  xmm0, xmm3
    subss   xmm0, xmm1
    mulss   xmm0, [rsi+rcx*4]
    mulss   xmm0, xmm2
    addss   xmm0, xmm1
    movss   [rdx+rcx*4], xmm0
    jmp     1b
9:  ret

# -----------------------------------------------------------------------------
# la_display(rdi=block, rsi=the mesh it replaces or 0) -> rax = a new mesh:
#   a grid of every s-th sample (s a power of two: at most the display's
#   samples a side), holding a reference to the block (ME_LAND); 0 if none
# -----------------------------------------------------------------------------
la_display:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    sub     rsp, 32
    mov     rbx, rdi
    mov     r12, rsi
    mov     ecx, [rbx+LB_DISP]          # the step
    test    ecx, ecx
    jnz     1f
    mov     ecx, LA_DISP
1:  cmp     ecx, 2
    jge     11f
    mov     ecx, 2
11: mov     [rsp], ecx
    mov     r13d, 1
    mov     eax, [rbx+LB_N]
    dec     eax
2:  xor     edx, edx                    # (N - 1) / s + 1 <= display
    push    rax
    div     r13d
    inc     eax
    mov     edx, eax
    pop     rax
    cmp     edx, [rsp]
    jle     3f
    shl     r13d, 1
    jmp     2b
3:  mov     [rsp+4], r13d               # s
    mov     [rsp+8], edx                # D
    imul    edx, edx
    test    r12, r12                    # the same grid: copy it
    jz      4f
    cmp     [r12+ME_NVERTS], edx
    jne     4f
    mov     rdi, r12
    call    mesh_copy
    jmp     5f
4:  mov     edi, [rsp+8]
    dec     edi
    call    prim_grid_n
5:  test    rax, rax
    jz      9f
    mov     r14, rax
    movss   xmm0, [rbx+LB_SIZE]         # x, z: -size/2 .. size/2
    movss   [rsp+12], xmm0
    mov     eax, [rsp+8]
    dec     eax
    cvtsi2ss xmm1, eax
    divss   xmm0, xmm1
    movss   [rsp+16], xmm0              # the display's cell
    mov     r15, [rbx+LB_H]
    add     r15, rbx
    mov     rdi, [r14+ME_POS]
    xor     r8d, r8d                    # row
6:  cmp     r8d, [rsp+8]
    jae     8f
    xor     r9d, r9d
7:  cmp     r9d, [rsp+8]
    jae     71f
    cvtsi2ss xmm0, r9d
    mulss   xmm0, [rsp+16]
    movss   xmm1, [rsp+12]
    mulss   xmm1, [rip+la_half]
    subss   xmm0, xmm1
    movss   [rdi], xmm0
    cvtsi2ss xmm0, r8d
    mulss   xmm0, [rsp+16]
    subss   xmm0, xmm1
    movss   [rdi+8], xmm0
    mov     eax, r8d                    # the sample
    imul    eax, [rsp+4]
    imul    eax, [rbx+LB_N]
    mov     ecx, r9d
    imul    ecx, [rsp+4]
    add     eax, ecx
    mov     eax, [r15+rax*4]
    mov     [rdi+4], eax
    add     rdi, 12
    inc     r9d
    jmp     7b
71: inc     r8d
    jmp     6b
8:  mov     rdi, r14
    call    mesh_bbox
    mov     rdi, rbx                    # (painted: its colours)
    mov     rsi, r14
    call    ls_vcol
    inc     dword ptr [r14+ME_VER]
    mov     [r14+ME_LAND], rbx
    mov     rdi, rbx
    call    la_ref
    mov     rax, r14
9:  add     rsp, 32
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# la_obj_set(rdi=object, rsi=block) - the object shows the block (a new
#   display mesh); the caller's reference to the block stays its own
la_obj_set:
    push    rbx
    push    r12
    sub     rsp, 8
    mov     rbx, rdi
    mov     rdi, rsi
    mov     rsi, [rbx+OB_MESH]
    call    la_display
    test    rax, rax
    jz      9f
    mov     rdi, [rbx+OB_MESH]
    mov     [rbx+OB_MESH], rax
    call    mesh_unref
    mov     dword ptr [rip+dirty], 1
9:  add     rsp, 8
    pop     r12
    pop     rbx
    ret

# -----------------------------------------------------------------------------
# la_height(rdi=block, xmm0=x, xmm1=z in its space) -> xmm0 = the height
#   there (bilinear), eax = 1 if inside
# -----------------------------------------------------------------------------
la_height:
    movss   xmm2, [rdi+LB_SIZE]
    mov     eax, [rdi+LB_N]
    dec     eax
    cvtsi2ss xmm3, eax
    divss   xmm3, xmm2                  # samples a metre
    mulss   xmm2, [rip+la_half]
    addss   xmm0, xmm2
    addss   xmm1, xmm2
    mulss   xmm0, xmm3
    mulss   xmm1, xmm3
    xorps   xmm2, xmm2
    comiss  xmm0, xmm2
    jb      8f
    comiss  xmm1, xmm2
    jb      8f
    cvtsi2ss xmm2, eax
    comiss  xmm0, xmm2
    ja      8f
    comiss  xmm1, xmm2
    ja      8f
    lea     ecx, [rax-1]                # the cell (the last one at the edge)
    cvttss2si r8d, xmm0
    cmp     r8d, ecx
    cmovg   r8d, ecx
    cvttss2si r9d, xmm1
    cmp     r9d, ecx
    cmovg   r9d, ecx
    cvtsi2ss xmm2, r8d
    subss   xmm0, xmm2                  # u
    cvtsi2ss xmm2, r9d
    subss   xmm1, xmm2                  # v
    mov     rdx, [rdi+LB_H]
    add     rdx, rdi
    mov     ecx, [rdi+LB_N]
    imul    r9d, ecx
    add     r9d, r8d
    movss   xmm2, [rdx+r9*4]            # h00 h10 / h01 h11
    movss   xmm3, [rdx+r9*4+4]
    add     r9d, ecx
    movss   xmm4, [rdx+r9*4]
    movss   xmm5, [rdx+r9*4+4]
    subss   xmm3, xmm2
    mulss   xmm3, xmm0
    addss   xmm2, xmm3
    subss   xmm5, xmm4
    mulss   xmm5, xmm0
    addss   xmm4, xmm5
    subss   xmm4, xmm2
    mulss   xmm4, xmm1
    addss   xmm2, xmm4
    movaps  xmm0, xmm2
    mov     eax, 1
    ret
8:  xorps   xmm0, xmm0
    xor     eax, eax
    ret

# la_wheight(rdi=object, xmm0=x, xmm1=z in the world) -> xmm0 = the
#   landscape's height there in the world, eax = 1 if over it (its
#   location and scale; landscapes are not turned)
la_wheight:
    push    rbx
    mov     rbx, rdi
    call    la_of
    test    rax, rax
    jz      8f
    subss   xmm0, [rbx+OB_LOC]
    subss   xmm1, [rbx+OB_LOC+8]
    divss   xmm0, [rbx+OB_SCALE]
    divss   xmm1, [rbx+OB_SCALE+8]
    mov     rdi, rax
    call    la_height
    test    eax, eax
    jz      8f
    mulss   xmm0, [rbx+OB_SCALE+4]
    addss   xmm0, [rbx+OB_LOC+4]
    pop     rbx
    ret
8:  xor     eax, eax
    pop     rbx
    ret

# la_info(rdi=object, edi... esi=k) -> xmm0, eax = 1 (0: not a landscape):
#   0 samples a side, 1 size, 2 layers, 3 lowest, 4 highest, 5 display
#   samples a side, 6 the last evaluation (ms), 7 paint layers, 8 version
la_info:
    push    rbx
    push    r12
    sub     rsp, 8
    mov     ebx, esi
    mov     r12, rdi
    call    la_of
    test    rax, rax
    jz      8f
    mov     rdi, rax
    xorps   xmm0, xmm0
    cmp     ebx, 0
    jne     1f
    cvtsi2ss xmm0, dword ptr [rdi+LB_N]
    jmp     7f
1:  cmp     ebx, 1
    jne     2f
    movss   xmm0, [rdi+LB_SIZE]
    jmp     7f
2:  cmp     ebx, 2
    jne     3f
    cvtsi2ss xmm0, dword ptr [rdi+LB_NL]
    jmp     7f
3:  cmp     ebx, 3
    jne     4f
    movss   xmm0, [rdi+LB_HMIN]
    jmp     7f
4:  cmp     ebx, 4
    jne     5f
    movss   xmm0, [rdi+LB_HMAX]
    jmp     7f
5:  cmp     ebx, 5                      # (the display mesh's side)
    jne     6f
    mov     rax, [r12+OB_MESH]
    cvtsi2ss xmm0, dword ptr [rax+ME_NVERTS]
    sqrtss  xmm0, xmm0
    jmp     7f
6:  cmp     ebx, 6
    jne     61f
    cvtsi2ss xmm0, dword ptr [rdi+LB_MS]
    jmp     7f
61: cmp     ebx, 7
    jne     62f
    cvtsi2ss xmm0, dword ptr [rdi+LB_NP]
    jmp     7f
62: cmp     ebx, 8
    jne     7f
    cvtsi2ss xmm0, dword ptr [rdi+LB_VER]
7:  mov     eax, 1
    jmp     9f
8:  xor     eax, eax
9:  add     rsp, 8
    pop     r12
    pop     rbx
    ret

# -----------------------------------------------------------------------------
# la_load(rdi=data, esi=bytes) -> rax = a block made from a saved one (its
#   header checked), or 0
# -----------------------------------------------------------------------------
la_load:
    push    rbx
    push    r12
    push    r13
    mov     r12, rdi
    mov     r13d, esi
    cmp     r13d, LB_DATA
    jb      8f
    mov     eax, [r12+LB_N]
    cmp     eax, 2
    jb      8f
    cmp     eax, 4097
    ja      8f
    cmp     dword ptr [r12+LB_NL], LA_MAXL
    ja      8f
    mov     rax, [r12+LB_BYTES]
    cmp     rax, r13
    jne     8f
    mov     edi, [r12+LB_N]             # every offset inside
    call    la_arr
    mov     rbx, rax
    mov     rdi, r12
    mov     rsi, [r12+LB_H]
    call    la_off_ok
    jz      8f
    mov     rsi, [r12+LB_C]
    call    la_off_ok
    jz      8f
    xor     ecx, ecx
1:  cmp     ecx, [r12+LB_NL]
    jae     2f
    imul    rdx, rcx, LY_SZ
    mov     rsi, [r12+LB_LAY+rdx+LY_DATA]
    test    rsi, rsi
    jz      11f
    call    la_off_ok
    jz      8f
11: inc     ecx
    jmp     1b
2:  mov     rsi, [r12+LB_SPLAT]
    test    rsi, rsi
    jz      3f
    add     rsi, rbx
    call    la_off_ok
    jz      8f
3:  xor     edi, edi
    mov     esi, r13d
    mov     edx, PROT_RW
    mov     r10d, MAP_ANON_PRIV
    mov     r8d, -1
    xor     r9d, r9d
    mov     eax, SYS_MMAP
    syscall
    cmp     rax, -4096
    ja      8f
    mov     rdi, rax
    mov     rsi, r12
    mov     ecx, r13d
    rep     movsb
    mov     dword ptr [rax+LB_REFS], 1
    jmp     9f
8:  xor     eax, eax
9:  pop     r13
    pop     r12
    pop     rbx
    ret
# la_off_ok(rdi=block, rsi=offset, rbx=array bytes) -> ZF clear if the
#   array lies inside the block, after the header
la_off_ok:
    cmp     rsi, LB_DATA
    jb      8f
    lea     rax, [rsi+rbx]
    cmp     rax, [rdi+LB_BYTES]
    ja      8f
    or      eax, 1
    ret
8:  xor     eax, eax
    ret

# =============================================================================
#  Operators
# =============================================================================
# la_num(rsi=text) -> eax = 1 and xmm0, rsi past it (0: none)
la_num:
    push    rbx
    call    im_next_word
    mov     rbx, rsi
    test    eax, eax
    jz      8f
    lea     rsi, [rip+im_word]
    lea     rdx, [rsi+rax]
    call    parse_float
    mov     rsi, rbx
    pop     rbx
    ret
8:  xor     eax, eax
    mov     rsi, rbx
    pop     rbx
    ret

# la_word(rsi=list of names) -> eax = the index of im_word in it, or -1
la_word:
    push    rbx
    push    r12
    sub     rsp, 8
    mov     r12, rsi
    xor     ebx, ebx
1:  mov     rsi, [r12+rbx*8]
    test    rsi, rsi
    jz      8f
    lea     rdi, [rip+im_word]
    call    str_eq
    test    eax, eax
    jnz     2f
    inc     ebx
    jmp     1b
2:  mov     eax, ebx
    jmp     9f
8:  mov     eax, -1
9:  add     rsp, 8
    pop     r12
    pop     rbx
    ret

# la_res(xmm0=samples asked) -> eax = 2^k + 1 nearest, 65..4097
la_res:
    cvttss2si eax, xmm0
    mov     ecx, 65
1:  cmp     ecx, 4097
    jae     2f
    lea     edx, [rcx*2-1]              # the next
    mov     r8d, ecx
    add     r8d, edx
    shr     r8d, 1
    cmp     eax, r8d                    # nearer the next?
    jl      2f
    mov     ecx, edx
    jmp     1b
2:  mov     eax, ecx
    ret

# la_layer_init(rdi=layer, esi=type 1..5) - its defaults
la_layer_init:
    mov     dword ptr [rdi+LY_TYPE], esi
    mov     dword ptr [rdi+LY_FLG], 0
    mov     qword ptr [rdi+LY_DATA], 0
    lea     eax, [rsi-1]
    imul    eax, eax, 44
    lea     rcx, [rip+la_defs]
    add     rcx, rax
    mov     eax, [rcx]
    mov     [rdi+LY_STR], eax
    xor     edx, edx
1:  mov     eax, [rcx+4+rdx*4]
    mov     [rdi+LY_P+rdx*4], eax
    inc     edx
    cmp     edx, 10
    jb      1b
    ret

# la_params(rdi=block, rsi=layer, rdx=text) -> eax = 1 if understood,
#   rsi past: the layer's keys and values
la_params:
    push    rbx
    push    r12
    push    r13
    push    r14
    sub     rsp, 24
    mov     r14, rdi
    mov     rbx, rsi
    mov     r12, rdx
1:  mov     rsi, r12
    call    im_next_word
    mov     r12, rsi
    test    eax, eax
    jz      7f
    lea     rdi, [rip+im_word]
    lea     rsi, [rip+k_la_strength]
    call    str_eq
    test    eax, eax
    jz      2f
    mov     rsi, r12
    call    la_num
    mov     r12, rsi
    test    eax, eax
    jz      8f
    movss   [rbx+LY_STR], xmm0
    jmp     1b
2:  cmp     dword ptr [rbx+LY_TYPE], 1  # generate: noise <kind>
    jne     3f
    lea     rdi, [rip+im_word]
    lea     rsi, [rip+k_la_noise]
    call    str_eq
    test    eax, eax
    jz      3f
    mov     rsi, r12
    call    im_next_word
    mov     r12, rsi
    test    eax, eax
    jz      8f
    lea     rsi, [rip+la_noises]
    call    la_word
    test    eax, eax
    js      8f
    cvtsi2ss xmm0, eax
    movss   [rbx+LY_P], xmm0
    jmp     1b
3:  cmp     dword ptr [rbx+LY_TYPE], 5  # flatten: at x z radius
    jne     4f
    lea     rdi, [rip+im_word]
    lea     rsi, [rip+k_la_at]
    call    str_eq
    test    eax, eax
    jz      4f
    mov     rsi, r12
    call    la_num
    test    eax, eax
    jz      8f
    movss   [rsp], xmm0
    call    la_num
    test    eax, eax
    jz      8f
    movss   [rsp+4], xmm0
    call    la_num
    test    eax, eax
    jz      8f
    mov     r12, rsi
    movss   xmm2, xmm0
    movss   xmm0, [rsp]
    movss   xmm1, [rsp+4]
    mov     rdi, r14
    mov     rsi, rbx
    call    la_disc
    jmp     1b
4:  mov     eax, [rbx+LY_TYPE]          # a parameter by name
    dec     eax
    lea     rcx, [rip+la_pnames]
    mov     rsi, [rcx+rax*8]
    call    la_word
    test    eax, eax
    js      8f
    mov     r13d, eax
    mov     rsi, r12
    call    la_num
    mov     r12, rsi
    test    eax, eax
    jz      8f
    movss   [rbx+LY_P+r13*4], xmm0
    jmp     1b
7:  mov     eax, 1
    jmp     9f
8:  xor     eax, eax
9:  mov     rsi, r12
    add     rsp, 24
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# la_disc(rdi=block, rsi=flatten layer, xmm0=x, xmm1=z, xmm2=radius) - a
#   round area added to its mask (1 inside the inner half, smooth to 0 at
#   the edge)
la_disc:
    push    rbx
    sub     rsp, 32
    mov     rbx, [rsi+LY_DATA]
    test    rbx, rbx
    jz      9f
    add     rbx, rdi
    movss   [rsp], xmm0
    movss   [rsp+4], xmm1
    maxss   xmm2, [rip+la_tiny]
    movss   [rsp+8], xmm2
    movss   xmm3, [rdi+LB_SIZE]
    mov     eax, [rdi+LB_N]
    mov     [rsp+16], eax
    dec     eax
    cvtsi2ss xmm4, eax
    divss   xmm3, xmm4
    movss   [rsp+12], xmm3              # the cell
    xor     r8d, r8d
1:  cmp     r8d, [rsp+16]
    jae     9f
    xor     r9d, r9d
2:  cmp     r9d, [rsp+16]
    jae     8f
    cvtsi2ss xmm0, r9d                  # the sample's place
    mulss   xmm0, [rsp+12]
    movss   xmm1, [rdi+LB_SIZE]
    mulss   xmm1, [rip+la_half]
    subss   xmm0, xmm1
    subss   xmm0, [rsp]
    cvtsi2ss xmm2, r8d
    mulss   xmm2, [rsp+12]
    subss   xmm2, xmm1
    subss   xmm2, [rsp+4]
    mulss   xmm0, xmm0
    mulss   xmm2, xmm2
    addss   xmm0, xmm2
    sqrtss  xmm0, xmm0
    divss   xmm0, [rsp+8]               # d / r: 1 inside half, 0 past 1
    subss   xmm0, [rip+la_half]
    addss   xmm0, xmm0
    movss   xmm1, [rip+la_one]
    subss   xmm1, xmm0
    maxss   xmm1, [rip+la_zero]
    minss   xmm1, [rip+la_one]
    mov     eax, r8d
    imul    eax, [rsp+16]
    add     eax, r9d
    maxss   xmm1, [rbx+rax*4]
    movss   [rbx+rax*4], xmm1
    inc     r9d
    jmp     2b
8:  inc     r8d
    jmp     1b
9:  add     rsp, 32
    pop     rbx
    ret

# la_active -> rax = the active object if a landscape (rdx = its block), else 0
la_active:
    sub     rsp, 8
    mov     edi, [rip+active_obj]
    call    obj_get
    test    rax, rax
    jz      8f
    push    rax
    mov     rdi, rax
    call    la_of
    mov     rdx, rax
    pop     rax
    test    rdx, rdx
    jz      8f
    add     rsp, 8
    ret
8:  lea     rdi, [rip+s_la_nosel]
    call    log_line
    xor     eax, eax
    add     rsp, 8
    ret

# la_preset(rdi=block, esi=preset) - its layers: 0 flat (none), 1 hills,
#   2 mountains, 3 canyon, 4 dunes, 5 island (la_pdata)
la_preset:
    lea     rax, [rip+la_pdata]         # the preset's record
    xor     ecx, ecx
1:  cmp     ecx, esi
    jae     2f
    mov     edx, [rax]
    imul    edx, edx, 48
    lea     rax, [rax+rdx+4]
    inc     ecx
    jmp     1b
2:  mov     ecx, [rax]
    mov     [rdi+LB_NL], ecx
    add     rax, 4
    lea     rdx, [rdi+LB_LAY]
3:  test    ecx, ecx
    jz      9f
    mov     r8d, [rax]
    mov     [rdx+LY_TYPE], r8d
    mov     dword ptr [rdx+LY_FLG], 0
    mov     qword ptr [rdx+LY_DATA], 0
    mov     r8d, [rax+4]
    mov     [rdx+LY_STR], r8d
    xor     r9d, r9d
4:  mov     r8d, [rax+8+r9*4]
    mov     [rdx+LY_P+r9*4], r8d
    inc     r9d
    cmp     r9d, 10
    jb      4b
    add     rax, 48
    add     rdx, LY_SZ
    dec     ecx
    jmp     3b
9:  ret

# do_la_add - landscape.add [preset] [size s] [res n] [seed k]
do_la_add:
    mov     edi, 1                      # (hills, unless named)
do_la_addp:                             # (edi: the preset)
    push    rbx
    push    r12
    push    r13
    push    r14
    sub     rsp, 24
    mov     [rsp], edi                  # preset
    mov     eax, [rip+la_200]
    mov     [rsp+4], eax                # size
    mov     dword ptr [rsp+8], 513      # samples
    mov     dword ptr [rsp+12], -1      # seed (the preset's)
    mov     r12, [rip+op_arg]
1:  mov     rsi, r12
    call    im_next_word
    mov     r12, rsi
    test    eax, eax
    jz      5f
    lea     rsi, [rip+la_presets]
    call    la_word
    test    eax, eax
    js      2f
    mov     [rsp], eax
    jmp     1b
2:  lea     rdi, [rip+im_word]
    lea     rsi, [rip+k_la_size]
    call    str_eq
    mov     ebx, 4
    test    eax, eax
    jnz     3f
    lea     rdi, [rip+im_word]
    lea     rsi, [rip+k_la_res]
    call    str_eq
    mov     ebx, 8
    test    eax, eax
    jnz     3f
    lea     rdi, [rip+im_word]
    lea     rsi, [rip+k_la_seed]
    call    str_eq
    mov     ebx, 12
    test    eax, eax
    jz      .Lla_bad
3:  mov     rsi, r12
    call    la_num
    mov     r12, rsi
    test    eax, eax
    jz      .Lla_bad
    cmp     ebx, 4
    jne     4f
    maxss   xmm0, [rip+la_one]
    movss   [rsp+4], xmm0
    jmp     1b
4:  cmp     ebx, 8
    jne     41f
    call    la_res
    mov     [rsp+8], eax
    jmp     1b
41: cvttss2si eax, xmm0
    mov     [rsp+12], eax
    jmp     1b
5:  xor     edi, edi
    mov     esi, [rsp+8]
    xor     edx, edx
    call    la_make
    test    rax, rax
    jz      .Lla_mem
    mov     rbx, rax
    mov     eax, [rsp+4]
    mov     [rbx+LB_SIZE], eax
    mov     rdi, rbx
    mov     esi, [rsp]
    call    la_preset
    mov     eax, [rsp+12]               # the seed: every layer's
    test    eax, eax
    js      52f
    cvtsi2ss xmm0, eax
    xor     ecx, ecx
51: cmp     ecx, [rbx+LB_NL]
    jae     52f
    imul    rdx, rcx, LY_SZ
    cmp     dword ptr [rbx+LB_LAY+rdx+LY_TYPE], 1
    jne     511f
    movss   [rbx+LB_LAY+rdx+LY_P+4], xmm0
511:cmp     dword ptr [rbx+LB_LAY+rdx+LY_TYPE], 2
    jne     512f
    movss   [rbx+LB_LAY+rdx+LY_P+8], xmm0
512:inc     ecx
    jmp     51b
52: mov     rdi, rbx
    xor     esi, esi
    call    la_eval
    mov     rdi, rbx
    xor     esi, esi
    call    la_display
    mov     r13, rax
    mov     rdi, rbx
    call    la_unref                    # (the mesh holds it)
    test    r13, r13
    jz      .Lla_mem
    mov     edi, OT_MESH
    lea     rsi, [rip+s_landscape]
    mov     rdx, r13
    call    obj_new
    test    eax, eax
    jz      9f
    mov     r14d, eax
    mov     edi, eax
    xor     esi, esi
    call    obj_click_select
    mov     edi, r14d
    call    obj_get
    mov     rcx, [rip+cursor_pos]
    mov     [rax+OB_LOC], rcx
    mov     ecx, [rip+cursor_pos+8]
    mov     [rax+OB_LOC+8], ecx
    cmp     dword ptr [rsp], 5          # an island: its sea
    jne     53f
    mov     rdi, rax
    call    la_water
    mov     edi, r14d
    xor     esi, esi
    call    obj_click_select
    mov     edi, r14d
    call    obj_get
53: cmp     dword ptr [rip+op_quiet], 0
    jne     9f
    mov     rsi, rax
    lea     rdi, [rip+s_la_add]
    call    log_pair
    call    la_log_ms
    jmp     9f
.Lla_bad:
    lea     rdi, [rip+s_la_bad]
    mov     rsi, [rip+op_arg]
    call    log_pair
    jmp     9f
.Lla_mem:
    lea     rdi, [rip+s_la_mem]
    call    log_line
9:  add     rsp, 24
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# la_water(rdi=landscape object) - its sea: a Water plane (1.5 times the
#   landscape, at its height) in 1 m-ish ripples (a grid of 192 x 192,
#   waves 3 cm high), the water material, flagged OBF_WATER (bodies below
#   its level float: rbody.s)
la_water:
    push    rbx
    push    r12
    push    r13
    sub     rsp, 16
    mov     rbx, rdi
    call    la_of
    test    rax, rax
    jz      9f
    movss   xmm0, [rax+LB_SIZE]
    mulss   xmm0, [rip+la_075]          # half of 1.5 x the size
    movss   [rsp], xmm0
    mov     edi, 192
    call    prim_grid_n
    test    rax, rax
    jz      9f
    mov     r12, rax
    mov     ecx, [r12+ME_NVERTS]
    mov     rdx, [r12+ME_POS]
1:  test    ecx, ecx
    jz      2f
    movss   xmm0, [rdx]                 # (x, z in -1..1) -> the size
    movss   xmm2, [rdx+8]
    movss   xmm3, xmm0                  # ripples: sin(37 x + 11 z) sin(23 z - 7 x)
    mulss   xmm3, [rip+la_r1]
    movss   xmm4, xmm2
    mulss   xmm4, [rip+la_r2]
    addss   xmm3, xmm4
    movss   xmm4, xmm2
    mulss   xmm4, [rip+la_r3]
    movss   xmm5, xmm0
    mulss   xmm5, [rip+la_r4]
    subss   xmm4, xmm5
    movss   [rsp+4], xmm3
    movss   [rsp+8], xmm4
    fld     dword ptr [rsp+4]
    fsin
    fld     dword ptr [rsp+8]
    fsin
    fmulp   st(1), st(0)
    fstp    dword ptr [rsp+4]
    movss   xmm3, [rsp+4]
    mulss   xmm3, [rip+la_wave]
    movss   [rdx+4], xmm3
    mulss   xmm0, [rsp]
    movss   [rdx], xmm0
    mulss   xmm2, [rsp]
    movss   [rdx+8], xmm2
    add     rdx, 12
    dec     ecx
    jmp     1b
2:  mov     rdi, r12
    call    mesh_bbox
    mov     edi, OT_MESH
    lea     rsi, [rip+s_water]
    mov     rdx, r12
    call    obj_new
    test    eax, eax
    jz      9f
    mov     r13d, eax
    mov     edi, eax
    call    obj_get
    or      dword ptr [rax+OB_FLAGS], OBF_WATER
    mov     rcx, [rbx+OB_LOC]
    mov     [rax+OB_LOC], rcx
    mov     ecx, [rbx+OB_LOC+8]
    mov     [rax+OB_LOC+8], ecx
    mov     ecx, [rbx+OB_LOC+4]
    mov     [rax+OB_LOC+4], ecx
    mov     edi, r13d                   # the water material (active: it)
    xor     esi, esi
    call    obj_click_select
    mov     rbx, [rip+op_arg]
    lea     rax, [rip+s_wpreset]
    mov     [rip+op_arg], rax
    call    do_preset
    mov     [rip+op_arg], rbx
9:  add     rsp, 16
    pop     r13
    pop     r12
    pop     rbx
    ret

# la_log_ms - "landscape evaluated in N ms" (the active object's)
la_log_ms:
    push    rbx
    mov     edi, [rip+active_obj]
    call    obj_get
    mov     rdi, rax
    call    la_of
    test    rax, rax
    jz      9f
    mov     rbx, rax
    call    fmt_reset
    lea     rdi, [rip+s_la_ms]
    call    fmt_str
    mov     edi, [rbx+LB_MS]
    call    fmt_int
    lea     rdi, [rip+s_la_msu]
    call    fmt_str
    lea     rdi, [rip+fmt_buf]
    call    log_line
9:  pop     rbx
    ret

# do_la_layer - landscape.layer add <type> [..] | set i [..] | remove i |
#   hide i | show i
do_la_layer:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    sub     rsp, 16
    call    la_active
    test    rax, rax
    jz      9f
    mov     r14, rax                    # the object
    mov     r15, rdx                    # its block
    mov     r12, [rip+op_arg]
    mov     rsi, r12
    call    im_next_word
    mov     r12, rsi
    test    eax, eax
    jz      .Lll_bad
    lea     rdi, [rip+im_word]
    lea     rsi, [rip+k_la_add]
    call    str_eq
    test    eax, eax
    jz      .Lll_index
    # add <type>
    mov     rsi, r12
    call    im_next_word
    mov     r12, rsi
    test    eax, eax
    jz      .Lll_bad
    lea     rsi, [rip+la_types]
    call    la_word
    test    eax, eax
    js      .Lll_bad
    lea     r13d, [rax+1]               # the type
    cmp     dword ptr [r15+LB_NL], LA_MAXL
    jae     .Lll_full
    xor     edx, edx                    # (sculpted, flatten: an array)
    cmp     r13d, 4
    jb      1f
    mov     edx, 2
1:  mov     rdi, r15
    mov     esi, [r15+LB_N]
    call    la_make
    test    rax, rax
    jz      .Lll_mem
    mov     rbx, rax
    mov     eax, [rbx+LB_NL]
    mov     [rsp], eax                  # the first layer that changed
    imul    rdi, rax, LY_SZ
    lea     rdi, [rbx+LB_LAY+rdi]
    mov     [rsp+8], rdi
    mov     esi, r13d
    call    la_layer_init
    cmp     r13d, 4
    jb      2f
    mov     rdi, [rsp+8]
    mov     rax, [rip+lv_extra]
    mov     [rdi+LY_DATA], rax
2:  inc     dword ptr [rbx+LB_NL]
    mov     rdi, rbx
    mov     rsi, [rsp+8]
    mov     rdx, r12
    call    la_params
    test    eax, eax
    jz      .Lll_badb
    jmp     .Lll_done
.Lll_index:                             # set / remove / hide / show <i>
    xor     r13d, r13d
    lea     rdi, [rip+im_word]
    lea     rsi, [rip+k_la_set]
    call    str_eq
    test    eax, eax
    jnz     3f
    inc     r13d
    lea     rdi, [rip+im_word]
    lea     rsi, [rip+k_la_remove]
    call    str_eq
    test    eax, eax
    jnz     3f
    inc     r13d
    lea     rdi, [rip+im_word]
    lea     rsi, [rip+k_la_hide]
    call    str_eq
    test    eax, eax
    jnz     3f
    inc     r13d
    lea     rdi, [rip+im_word]
    lea     rsi, [rip+k_la_show]
    call    str_eq
    test    eax, eax
    jz      .Lll_bad
3:  mov     rsi, r12
    call    la_num
    mov     r12, rsi
    test    eax, eax
    jz      .Lll_bad
    cvttss2si eax, xmm0
    test    eax, eax
    js      .Lll_bad
    cmp     eax, [r15+LB_NL]
    jae     .Lll_bad
    mov     [rsp], eax
    mov     rdi, r15
    mov     esi, [r15+LB_N]
    xor     edx, edx
    call    la_make
    test    rax, rax
    jz      .Lll_mem
    mov     rbx, rax
    mov     eax, [rsp]
    imul    rdi, rax, LY_SZ
    lea     rdi, [rbx+LB_LAY+rdi]
    mov     [rsp+8], rdi
    cmp     r13d, 1
    jne     31f
    lea     rsi, [rdi+LY_SZ]            # remove: the ones above move down
    mov     ecx, [rbx+LB_NL]
    sub     ecx, [rsp]
    dec     ecx
    imul    ecx, ecx, LY_SZ
    rep     movsb
    dec     dword ptr [rbx+LB_NL]
    jmp     .Lll_done
31: cmp     r13d, 2
    jne     32f
    or      dword ptr [rdi+LY_FLG], 1
    jmp     .Lll_done
32: cmp     r13d, 3
    jne     33f
    and     dword ptr [rdi+LY_FLG], -2
    jmp     .Lll_done
33: mov     rsi, rdi                    # set
    mov     rdi, rbx
    mov     rdx, r12
    call    la_params
    test    eax, eax
    jz      .Lll_badb
.Lll_done:
    mov     rdi, rbx
    mov     esi, [rsp]
    call    la_eval
    mov     rdi, r14
    mov     rsi, rbx
    call    la_obj_set
    mov     rdi, rbx
    call    la_unref
    cmp     dword ptr [rip+op_quiet], 0
    jne     9f
    call    la_log_ms
    jmp     9f
.Lll_badb:
    mov     rdi, rbx
    call    la_unref
.Lll_bad:
    lea     rdi, [rip+s_la_bad]
    mov     rsi, [rip+op_arg]
    call    log_pair
    jmp     9f
.Lll_full:
    lea     rdi, [rip+s_la_full]
    call    log_line
    jmp     9f
.Lll_mem:
    lea     rdi, [rip+s_la_mem]
    call    log_line
9:  add     rsp, 16
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# do_la_set - landscape.set [size s] [res n] [detail d]
do_la_set:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    sub     rsp, 16
    call    la_active
    test    rax, rax
    jz      9f
    mov     r14, rax
    mov     r15, rdx
    mov     eax, [r15+LB_N]             # what it becomes
    mov     [rsp], eax
    mov     eax, [r15+LB_SIZE]
    mov     [rsp+4], eax
    mov     eax, [r15+LB_DISP]
    mov     [rsp+8], eax
    mov     r12, [rip+op_arg]
1:  mov     rsi, r12
    call    im_next_word
    mov     r12, rsi
    test    eax, eax
    jz      5f
    lea     rdi, [rip+im_word]
    lea     rsi, [rip+k_la_size]
    call    str_eq
    mov     ebx, 4
    test    eax, eax
    jnz     2f
    lea     rdi, [rip+im_word]
    lea     rsi, [rip+k_la_res]
    call    str_eq
    xor     ebx, ebx
    test    eax, eax
    jnz     2f
    lea     rdi, [rip+im_word]
    lea     rsi, [rip+k_la_detail]
    call    str_eq
    mov     ebx, 8
    test    eax, eax
    jz      .Lls_bad
2:  mov     rsi, r12
    call    la_num
    mov     r12, rsi
    test    eax, eax
    jz      .Lls_bad
    cmp     ebx, 4
    jne     3f
    maxss   xmm0, [rip+la_one]
    movss   [rsp+4], xmm0
    jmp     1b
3:  call    la_res
    mov     [rsp+rbx], eax
    jmp     1b
5:  mov     eax, [rsp]                  # new samples: every array resampled
    cmp     eax, [r15+LB_N]
    je      6f
    mov     rdi, r15
    mov     esi, eax
    call    la_resize
    jmp     7f
6:  mov     rdi, r15
    mov     esi, [r15+LB_N]
    xor     edx, edx
    call    la_make
7:  test    rax, rax
    jz      .Lls_mem
    mov     rbx, rax
    mov     eax, [rsp+4]
    mov     [rbx+LB_SIZE], eax
    mov     eax, [rsp+8]
    mov     [rbx+LB_DISP], eax
    mov     rdi, rbx
    xor     esi, esi
    call    la_eval
    mov     rdi, r14
    mov     rsi, rbx
    call    la_obj_set
    mov     rdi, rbx
    call    la_unref
    jmp     9f
.Lls_bad:
    lea     rdi, [rip+s_la_bad]
    mov     rsi, [rip+op_arg]
    call    log_pair
    jmp     9f
.Lls_mem:
    lea     rdi, [rip+s_la_mem]
    call    log_line
9:  add     rsp, 16
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# la_resize(rdi=block, esi=new N) -> rax = a new block of that many samples:
#   the header and layers, each layer's array and the splat map resampled
#   (bilinear; the splat nearest), the heights left to evaluate
la_resize:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    sub     rsp, 16
    mov     r12, rdi
    mov     r13d, esi
    mov     edi, r13d                   # bytes: as la_make counts them
    call    la_arr
    mov     r14, rax
    lea     rbx, [rax*2+LB_DATA]
    xor     ecx, ecx
1:  cmp     ecx, [r12+LB_NL]
    jae     2f
    imul    rdx, rcx, LY_SZ
    cmp     qword ptr [r12+LB_LAY+rdx+LY_DATA], 0
    je      11f
    add     rbx, r14
11: inc     ecx
    jmp     1b
2:  cmp     qword ptr [r12+LB_SPLAT], 0
    je      21f
    lea     rbx, [rbx+r14*2]
21: xor     edi, edi
    mov     rsi, rbx
    mov     edx, PROT_RW
    mov     r10d, MAP_ANON_PRIV
    mov     r8d, -1
    xor     r9d, r9d
    mov     eax, SYS_MMAP
    syscall
    cmp     rax, -4096
    jbe     3f
    xor     eax, eax
    jmp     9f
3:  mov     r15, rax
    mov     rsi, r12
    mov     rdi, r15
    mov     ecx, LB_DATA/8
    rep     movsq
    mov     dword ptr [r15+LB_REFS], 1
    mov     [r15+LB_N], r13d
    mov     [r15+LB_BYTES], rbx
    mov     dword ptr [r15+LB_CL], -1
    mov     qword ptr [r15+LB_SPLAT], 0
    mov     rbx, LB_DATA
    mov     [r15+LB_H], rbx
    add     rbx, r14
    mov     [r15+LB_C], rbx
    add     rbx, r14
    xor     ecx, ecx
4:  cmp     ecx, [r12+LB_NL]
    jae     5f
    imul    rdx, rcx, LY_SZ
    mov     rsi, [r12+LB_LAY+rdx+LY_DATA]
    test    rsi, rsi
    jz      41f
    mov     [r15+LB_LAY+rdx+LY_DATA], rbx
    push    rcx
    add     rsi, r12
    lea     rdi, [r15+rbx]
    mov     edx, [r12+LB_N]
    mov     ecx, r13d
    call    la_resample
    pop     rcx
    add     rbx, r14
41: inc     ecx
    jmp     4b
5:  mov     rsi, [r12+LB_SPLAT]         # the splat map: nearest
    test    rsi, rsi
    jz      8f
    mov     [r15+LB_SPLAT], rbx
    add     rsi, r12
    lea     rdi, [r15+rbx]
    mov     edx, [r12+LB_N]
    mov     ecx, r13d
    call    la_resample8
8:  mov     rax, r15
9:  add     rsp, 16
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# la_resample(rsi=f32 n x n, edx=n, rdi=f32 m x m out, ecx=m) - bilinear
la_resample:
    push    rbx
    push    r12
    push    r13
    push    r14
    sub     rsp, 24
    mov     r12, rsi
    mov     r13d, edx
    mov     r14, rdi
    mov     [rsp], ecx
    lea     eax, [rdx-1]                # source cells per destination cell
    cvtsi2ss xmm0, eax
    lea     eax, [rcx-1]
    cvtsi2ss xmm1, eax
    divss   xmm0, xmm1
    movss   [rsp+4], xmm0
    xor     ebx, ebx                    # row
1:  cmp     ebx, [rsp]
    jae     9f
    xor     r8d, r8d
2:  cmp     r8d, [rsp]
    jae     8f
    cvtsi2ss xmm0, r8d
    mulss   xmm0, [rsp+4]
    cvtsi2ss xmm1, ebx
    mulss   xmm1, [rsp+4]
    lea     ecx, [r13-2]
    cvttss2si r9d, xmm0
    cmp     r9d, ecx
    cmovg   r9d, ecx
    cvttss2si r10d, xmm1
    cmp     r10d, ecx
    cmovg   r10d, ecx
    cvtsi2ss xmm2, r9d
    subss   xmm0, xmm2
    cvtsi2ss xmm2, r10d
    subss   xmm1, xmm2
    imul    r10d, r13d
    add     r10d, r9d
    movss   xmm2, [r12+r10*4]
    movss   xmm3, [r12+r10*4+4]
    add     r10d, r13d
    movss   xmm4, [r12+r10*4]
    movss   xmm5, [r12+r10*4+4]
    subss   xmm3, xmm2
    mulss   xmm3, xmm0
    addss   xmm2, xmm3
    subss   xmm5, xmm4
    mulss   xmm5, xmm0
    addss   xmm4, xmm5
    subss   xmm4, xmm2
    mulss   xmm4, xmm1
    addss   xmm2, xmm4
    mov     eax, ebx
    imul    eax, [rsp]
    add     eax, r8d
    movss   [r14+rax*4], xmm2
    inc     r8d
    jmp     2b
8:  inc     ebx
    jmp     1b
9:  add     rsp, 24
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# la_resample8(rsi=u64 n x n, edx=n, rdi=out m x m, ecx=m) - nearest
la_resample8:
    push    rbx
    sub     rsp, 16
    mov     [rsp], ecx
    lea     eax, [rdx-1]
    cvtsi2ss xmm0, eax
    lea     eax, [rcx-1]
    cvtsi2ss xmm1, eax
    divss   xmm0, xmm1
    xor     ebx, ebx
1:  cmp     ebx, [rsp]
    jae     9f
    xor     r8d, r8d
2:  cmp     r8d, [rsp]
    jae     8f
    cvtsi2ss xmm1, r8d
    mulss   xmm1, xmm0
    cvtss2si r9d, xmm1
    cvtsi2ss xmm1, ebx
    mulss   xmm1, xmm0
    cvtss2si r10d, xmm1
    imul    r10d, edx
    add     r10d, r9d
    mov     rax, [rsi+r10*8]
    mov     r9d, ebx
    imul    r9d, [rsp]
    add     r9d, r8d
    mov     [rdi+r9*8], rax
    inc     r8d
    jmp     2b
8:  inc     ebx
    jmp     1b
9:  add     rsp, 16
    pop     rbx
    ret

.section .note.GNU-stack,"",@progbits
