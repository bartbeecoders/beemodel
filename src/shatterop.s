# =============================================================================
#  BeeModel - shatter: the operators.
#
#  object.shatter breaks the active mesh object into pieces: its evaluated
#  mesh (closed: repaired first when it is not, refused when that does not
#  close it) is cut into cells (shatter.s) and every piece becomes a mesh
#  object of its own, its origin at its centre of volume, placed where it
#  was. The original is hidden, not deleted; one undo step brings it back.
#  The patterns:
#   - shards: Voronoi cells from seeds inside the mesh: uniform, around an
#     impact point (closer likelier) or near the surface;
#   - bricks: a running bond in the object's axes (rows along Y), cut by
#     the joints' planes, a mortar gap, joints jittered;
#   - balls: no cutting - spheres on a face-centred cubic lattice, inside
#     and clear of the surface, sharing one sphere mesh.
#  An inner colour goes to the cut faces as vertex colours (their vertices
#  apart from the surface's). mesh.separate_loose splits the selected
#  meshes into their loose parts. shinfo(k) reports the last shatter.
# =============================================================================
.intel_syntax noprefix
.include "const.inc"
.include "macros.inc"

.globl sh_info
.globl op_shatter
.globl op_sep_loose
.globl so_pdata
.globl so_preview_draw

.equ VX_SZ,     24
.equ TR_SZ,     16
.equ PLN_SZ,    40                      # (shatter.s: a plane, its tag;
.equ PLN_TAG,   32                      #  planes a cell at most)
.equ CPL_MAX,   128
.equ RB_UID,    0                       # (rbody.s: a body's settings)
.equ RB_TYPE,   4
.equ RB_SHAPE,  8
.equ RB_MASS,   12
.equ RB_FRIC,   16
.equ RB_REST,   20
.equ RB_DAMP,   24
.equ RB_FLAGS,  28
.equ RB_VEL,    68
.equ RB_SZ_O,   80
.equ MA_DENS_,  92                      # (material.s: g/cm^3)
.equ JT_TYPE,   0                       # (rbody.s: a joint)
.equ JT_A,      4
.equ JT_B,      8
.equ JT_PIV,    16
.equ JT_AXIS,   28
.equ JT_BRK,    40
.equ PP_HDR,    8
.equ PH_NV,     0                       # a piece: counts, volume, centre;
.equ PH_NP,     4                       #  vertices (floats), polygons (count,
.equ PH_NL,     8                       #  tag), loops
.equ PH_VOL,    16
.equ PH_C,      24
.equ PH_SZ,     48
.equ MAXSEEDS,  4096
.equ NSTAT,     24
.equ SB_MAX,    16384                   # seeds tried at once
.equ BL_MAX,    131072                  # ball lattice points tried at once

.section .rodata
.align 8
so_inv53:       .double 1.1102230246251565e-16     # 2^-53
so_one:         .double 1.0
so_half:        .double 0.5
so_1000:        .double 1000.0
k_count:        .asciz "count"
k_seed:         .asciz "seed"
k_shards:       .asciz "shards"
k_bricks:       .asciz "bricks"
k_balls:        .asciz "balls"
k_at:           .asciz "at"
k_cursor:       .asciz "cursor"
k_surface:      .asciz "surface"
k_spread:       .asciz "spread"
k_size:         .asciz "size"
k_counts:       .asciz "counts"
k_offset:       .asciz "offset"
k_gap:          .asciz "gap"
k_jitter:       .asciz "jitter"
k_radius:       .asciz "radius"
k_inner:        .asciz "inner"
k_random:       .asciz "random"
k_density:      .asciz "density"
k_nobodies:     .asciz "nobodies"
k_glue:         .asciz "glue"
k_paint:        .asciz "paint"
k_impact:       .asciz "impact"
k_preset:       .asciz "preset"
k_again:        .asciz "again"
k_none:         .asciz "none"
k_brickwall:    .asciz "brickwall"
k_glass:        .asciz "glass"
k_stone:        .asciz "stone"
k_gravel:       .asciz "gravel"
.align 8
so_presets:     .quad k_none, k_brickwall, k_glass, k_stone, k_gravel, 0
# a preset: pattern, count, glue (N/m2), impact (N s), density, gap, spread,
#   spread given, bricks a row, rows, inner colour (0: none)
.equ PS_SZ,     44
.align 4
so_pdata:       .long 1, 50
                .float 40000.0, 0.0, 1900.0, 0.005, 0.5
                .long 0, 10, 5, 0xff9a8f84      # brick wall: mortar grey
                .long 0, 60
                .float 15000.0, 10.0, 2500.0, 0.0, 0.5
                .long 0, 8, 4, 0xffd8f0f0       # glass: on impact, pale
                .long 0, 25
                .float 150000.0, 0.0, 2600.0, 0.0, 0.5
                .long 0, 8, 4, 0xff8c8c88       # stone
                .long 2, 300
                .float 0.0, 0.0, 1800.0, 0.0, 0.5
                .long 1, 8, 4, 0                # gravel: balls, radii spread
s_sh_room:      .asciz "  shatter: no room for more rigid bodies (4096) - the rest are not bodies"
s_sh_brick:     .asciz "_brick_"
s_sh_ball:      .asciz "_ball_"
s_sh_cell:      .asciz "_shard_"
s_sh_part:      .asciz "_part_"
s_sh_none:      .asciz "  shatter: make a mesh object active"
s_sh_open:      .asciz "  shatter: the mesh is not closed even after repair (mesh.repair; open edges: "
s_sh_mem:       .asciz "  shatter: out of memory"
s_sh_bad:       .asciz "  object.shatter <shards|bricks|balls> [count n] [seed s] [at x y z | cursor | surface] [spread f] [size x y z | counts a b c] [offset f|random] [gap g] [jitter f] [radius r] [inner r g b] [density kg/m3] [nobodies] [glue N/m2 [paint]] [impact Ns] [preset brickwall|glass|stone|gravel] [again] - not understood: "
s_sh_noseed:    .asciz "  shatter: no room inside the mesh for the cells"
s_sh_done:      .asciz "  shattered into "
s_sh_pieces:    .asciz " pieces ("
s_sh_ms:        .asciz " ms)"
s_sl_none:      .asciz "  separate: select mesh objects with loose parts"
s_sl_done:      .asciz "  separated into loose parts: "

.align 8
so_kws:         .quad k_shards, k_bricks, k_balls, k_count, k_seed, k_at, k_cursor
                .quad k_surface, k_spread, k_size, k_counts, k_offset, k_gap
                .quad k_jitter, k_radius, k_inner, k_density, k_nobodies
                .quad k_glue, k_paint, k_impact, k_preset, k_again, 0
so_kwfn:        .quad .Lpa_count, .Lpa_seed, .Lpa_at, .Lpa_cursor, .Lpa_surface
                .quad .Lpa_spread, .Lpa_size, .Lpa_counts, .Lpa_offset, .Lpa_gap
                .quad .Lpa_jitter, .Lpa_radius, .Lpa_inner, .Lpa_density
                .quad .Lpa_nobodies, .Lpa_glue, .Lpa_paint, .Lpa_impact
                .quad .Lpa_preset, .Lpa_again
so_one_d:       .double 1.0
so_three:       .double 3.0
so_1em6:        .double 1.0e-6
so_01:          .double 0.01
so_001:         .double 0.01
so_055:         .double 0.55
so_sph:         .double 4.18879020478639
so_12:          .double 1.2
so_097:         .double 0.97
so_08:          .double 0.8
so_2r2:         .double 2.8284271247461903
so_big:         .double 1.0e300
so_third_d:     .double 0.3333333333333333
so_02:          .double 0.2
so_765:         .double 765.0
fcc_off:        .double 0, 0, 0,  0.5, 0.5, 0,  0.5, 0, 0.5,  0, 0.5, 0.5
.align 16
so_absf:        .long 0x7fffffff, 0x7fffffff, 0x7fffffff, 0x7fffffff
so_f0:          .float 0.0
so_f1:          .float 1.0
so_f255:        .float 255.0
so_fhalf:       .float 0.5
so_third:       .float 0.33333334
so_f1000:       .float 1000.0
so_ffric:       .float 0.5
so_fmin:        .float 1.0e-3

.section .bss
.align 8
sh_stat:        .skip 8*NSTAT           # the last shatter (shinfo)
so_rng:         .skip 8
so_t0:          .skip 8
so_tlap:        .skip 8
so_obj:         .skip 8                 # the object
so_mat:         .skip 48                # its matrix
so_name:        .skip 64
so_nbase:       .skip 32
so_ctr:         .skip 4
so_count:       .skip 4
so_seed:        .skip 4
so_first:       .skip 4                 # the first piece's handle
.align 8
so_seedsz:      .skip 8
so_imap:        .skip 8                 # a piece's cut faces' vertex copies
so_imap_rev:    .skip 8
so_ipoly:       .skip 4*256
so_cand:        .skip VX_SZ*SB_MAX      # a batch of tries,
so_cin:         .skip BL_MAX            #  which are inside (or balls' kept)
so_bpts:        .skip VX_SZ*BL_MAX      # the balls' lattice
so_br:          .skip 8
so_brad:        .skip 8*MAXSEEDS        # the balls' radii (local)
so_cdf:         .skip 8                 # the triangles' areas, summed
so_cdfsz:       .skip 8
so_imat:        .skip 96                # the object's inverse (doubles)
so_at:          .skip 24                # the impact point (local)
so_atw:         .skip 12                #  (world)
so_size:        .skip 12
so_tmp3:        .skip 12
so_counts:      .skip 12
so_joints:      .skip 8*4096            # a row of bricks' joints
.align 4
so_pat:         .skip 4                 # 0 shards, 1 bricks, 2 balls
so_atmode:      .skip 4                 # 0 uniform, 1 around a point, 2 surface
so_spread:      .skip 4
so_spreadset:   .skip 4
so_counted:     .skip 4
so_density:     .skip 4
so_nobodies:    .skip 4
so_meanscale:   .skip 4
so_lasth:       .skip 4
so_npieces:     .skip 4
so_gluef:       .skip 4                 # glue: the strength (N/m^2), painted
so_gluepaint:   .skip 4
so_impact:      .skip 4                 # on impact: the blow it breaks at
so_impactset:   .skip 4                 #  (N s)
so_preset:      .skip 4                 # the preset named (0: none)
so_again:       .skip 4                 # again: the pieces made before go
so_ngrp:        .skip 4                 # the faces' groups (GR_SZ)
so_grpcap:      .skip 4
so_grp:         .skip 8
so_grpsz:       .skip 8
so_gtol:        .skip 8
so_anim:        .skip 8
.align 8
so_pieces:      .skip 4*MAX_OBJECTS     # the pieces made: handles, volumes
so_pvol:        .skip 8*MAX_OBJECTS
so_hassize:     .skip 4
so_hascounts:   .skip 4
so_offset:      .skip 4
so_offrand:     .skip 4
so_gap:         .skip 4
so_jitter:      .skip 4
so_radius:      .skip 4
so_inner:       .skip 4
so_innerc:      .skip 4
sh_ncell_used:  .skip 4

.text
OPERATOR op_shatter, "object.shatter", "Shatter...", do_shatter, flags=OPF_AI_SAFE|OPF_UNDO, form=form_shatter, doc="Break the active mesh object into pieces, each an object (the original is hidden): object.shatter <shards|bricks|balls> [count n] [seed s] - shards: Voronoi cells [at x y z | cursor | surface] [spread f]; bricks: a running bond [counts a b c | size x y z] [offset f|random] [gap g] [jitter f]; balls: [radius r] [spread f]; [inner r g b] colours the cut faces; [glue N/m2 [paint]] ties neighbours; [impact N s]: whole until hit that hard; [preset brickwall|glass|stone|gravel]; [again]: a piece or the original: the pieces made before go first"
OPERATOR op_sep_loose, "mesh.separate_loose", "Separate By Loose Parts", do_sep_loose, flags=OPF_AI_SAFE|OPF_UNDO, doc="Split each selected mesh object into one object per loose part (parts that share no vertex)"

# sh_info(edi=k) -> xmm0 (double): the last shatter's 0 pieces, 1 cells, 2
#   the pieces' volume, 3 the original's, 4 the smallest piece's, 5 open
#   edges in the pieces, 6 ms, 7 glue joints, 8 open edges of the mesh,
#   9 |pieces' volume - its| / its, 10 the smallest piece / the mean one,
#   11-13 ms seeding, cutting, making the objects; 14-17 the cut's ms:
#   the cells, the tree, its levels, the cells from their leaves; balls:
#   18 the radius, 19 the least gap between two over a radius, 20 the most
#   one reaches past the surface over its radius
sh_info:
    xorpd   xmm0, xmm0
    cmp     edi, NSTAT
    jae     1f
    lea     rax, [rip+sh_stat]
    movsd   xmm0, [rax+rdi*8]
1:  ret

# so_lap(edi=stat) - the ms since the last lap (or the start) into it
so_lap:
    push    rbx
    mov     ebx, edi
    call    so_now
    mov     rcx, rax
    mov     rdx, [rip+so_tlap]
    test    rdx, rdx
    jnz     1f
    mov     rdx, [rip+so_t0]
1:  mov     [rip+so_tlap], rcx
    sub     rcx, rdx
    cvtsi2sd xmm0, rcx
    divsd   xmm0, [rip+so_ms]
    lea     rax, [rip+sh_stat]
    movsd   [rax+rbx*8], xmm0
    pop     rbx
    ret

# so_rand -> xmm0 = a double in [0, 1)
so_rand:
    mov     rax, [rip+so_rng]           # xorshift64*
    mov     rdx, rax
    shr     rdx, 12
    xor     rax, rdx
    mov     rdx, rax
    shl     rdx, 25
    xor     rax, rdx
    mov     rdx, rax
    shr     rdx, 27
    xor     rax, rdx
    mov     [rip+so_rng], rax
    mov     rdx, 0x2545F4914F6CDD1D
    imul    rax, rdx
    shr     rax, 11
    cvtsi2sd xmm0, rax
    mulsd   xmm0, [rip+so_inv53]
    ret

# so_seed_rng(edi=seed)
so_seed_rng:
    mov     eax, edi
    mov     rdx, 0x9E3779B97F4A7C15
    imul    rax, rdx
    inc     rax
    mov     rdx, 0x5851F42D4C957F2D
    xor     rax, rdx
    mov     [rip+so_rng], rax
    ret

# so_num(rsi=text) -> eax = 1, xmm0 (float), rsi past it
so_num:
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

# so_now -> rax = ns
so_now:
    sub     rsp, 24
    mov     edi, 1                      # CLOCK_MONOTONIC
    mov     rsi, rsp
    call    plat_clock_gettime
    mov     rax, [rsp]
    imul    rax, rax, 1000000000
    add     rax, [rsp+8]
    add     rsp, 24
    ret

# so_source(rdi=object) -> eax = 1: its evaluated mesh is the cut's source
#   (repaired when it is not closed); 0: refused (said why)
so_source:
    push    rbx
    push    r12
    sub     rsp, 8
    mov     rbx, rdi
    call    obj_eval
    test    rax, rax
    jz      7f
    mov     r12, rax
    mov     rdi, rax
    call    sh_src_set
    test    eax, eax
    jz      8f
    lea     rax, [rip+sh_stat]
    cvtsi2sd xmm0, dword ptr [rip+sh_open_edges]
    movsd   [rax+8*8], xmm0
    cmp     dword ptr [rip+sh_open_edges], 0
    je      6f
    mov     rdi, r12                    # not closed: repaired
    call    mesh_clean
    test    rax, rax
    jz      5f
    mov     r12, rax
    mov     rdi, rax
    call    sh_src_set
    mov     rdi, r12
    push    rax
    sub     rsp, 8
    call    mesh_unref
    add     rsp, 8
    pop     rax
    test    eax, eax
    jz      8f
    cmp     dword ptr [rip+sh_open_edges], 0
    je      6f
5:  call    fmt_reset
    lea     rdi, [rip+s_sh_open]
    call    fmt_str
    mov     edi, [rip+sh_open_edges]
    call    fmt_int
    mov     edi, ')'
    call    fmt_char
    lea     rdi, [rip+fmt_buf]
    call    log_line
    call    sh_src_free
    jmp     9f
6:  mov     eax, 1
    add     rsp, 8
    pop     r12
    pop     rbx
    ret
7:  lea     rdi, [rip+s_sh_none]
    call    log_line
    jmp     9f
8:  lea     rdi, [rip+s_sh_mem]
    call    log_line
9:  xor     eax, eax
    add     rsp, 8
    pop     r12
    pop     rbx
    ret

# so_diag -> xmm0 = the source's bounds' diagonal (local)
so_diag:
    xorpd   xmm0, xmm0
    xor     ecx, ecx
    lea     rax, [rip+sh_src_max]
    lea     rdx, [rip+sh_src_min]
1:  movsd   xmm1, [rax+rcx*8]
    subsd   xmm1, [rdx+rcx*8]
    mulsd   xmm1, xmm1
    addsd   xmm0, xmm1
    inc     ecx
    cmp     ecx, 3
    jb      1b
    sqrtsd  xmm0, xmm0
    ret

# so_cand_pt(rdi=3 doubles out) - a point to try as a seed: in the bounds,
#   around the impact point (closer ones likelier) or near the surface
so_cand_pt:
    push    rbx
    push    r12
    sub     rsp, 56
    mov     rbx, rdi
    mov     eax, [rip+so_atmode]
    cmp     eax, 1
    je      .Lsc_at
    cmp     eax, 2
    je      .Lsc_surf
    xor     r12d, r12d                  # anywhere in the bounds
1:  call    so_rand
    lea     rax, [rip+sh_src_max]
    movsd   xmm1, [rax+r12*8]
    lea     rax, [rip+sh_src_min]
    movsd   xmm2, [rax+r12*8]
    subsd   xmm1, xmm2
    mulsd   xmm0, xmm1
    addsd   xmm0, xmm2
    movsd   [rbx+r12*8], xmm0
    inc     r12d
    cmp     r12d, 3
    jb      1b
    jmp     9f
.Lsc_at:
2:  xor     r12d, r12d                  # a way: in the unit ball, not 0
21: call    so_rand
    addsd   xmm0, xmm0
    subsd   xmm0, [rip+so_one]
    movsd   [rsp+r12*8], xmm0
    inc     r12d
    cmp     r12d, 3
    jb      21b
    movsd   xmm0, [rsp]
    mulsd   xmm0, xmm0
    movsd   xmm1, [rsp+8]
    mulsd   xmm1, xmm1
    addsd   xmm0, xmm1
    movsd   xmm1, [rsp+16]
    mulsd   xmm1, xmm1
    addsd   xmm0, xmm1
    comisd  xmm0, [rip+so_one]
    ja      2b
    comisd  xmm0, [rip+so_1em6]
    jb      2b
    sqrtsd  xmm0, xmm0
    movsd   [rsp+24], xmm0
    call    so_rand                     # how far: the spread x the size x u^2
    mulsd   xmm0, xmm0
    movsd   [rsp+32], xmm0
    call    so_diag
    mulsd   xmm0, [rsp+32]
    cvtss2sd xmm1, [rip+so_spread]
    mulsd   xmm0, xmm1
    divsd   xmm0, [rsp+24]
    xor     ecx, ecx
22: movsd   xmm1, [rsp+rcx*8]
    mulsd   xmm1, xmm0
    lea     rax, [rip+so_at]
    addsd   xmm1, [rax+rcx*8]
    movsd   [rbx+rcx*8], xmm1
    inc     ecx
    cmp     ecx, 3
    jb      22b
    jmp     9f
.Lsc_surf:
    call    so_rand                     # a triangle by its area
    mov     ecx, [rip+sh_src_nt]
    mov     rax, [rip+so_cdf]
    mulsd   xmm0, [rax+rcx*8-8]
    xor     edx, edx                    # the first with cdf > u
    mov     r8d, ecx
3:  cmp     edx, r8d
    jae     31f
    lea     r9d, [rdx+r8]
    shr     r9d, 1
    comisd  xmm0, [rax+r9*8]
    jb      32f
    lea     edx, [r9+1]
    jmp     3b
32: mov     r8d, r9d
    jmp     3b
31: cmp     edx, ecx
    jb      33f
    lea     edx, [rcx-1]
33: mov     r12d, edx
    call    so_rand                     # a point in it
    movsd   [rsp], xmm0
    call    so_rand
    movsd   xmm1, xmm0
    movsd   xmm0, [rsp]
    movsd   xmm2, xmm0
    addsd   xmm2, xmm1
    comisd  xmm2, [rip+so_one]
    jbe     34f
    movsd   xmm2, [rip+so_one]
    subsd   xmm2, xmm0
    movsd   xmm0, xmm2
    movsd   xmm2, [rip+so_one]
    subsd   xmm2, xmm1
    movsd   xmm1, xmm2
34: movsd   [rsp], xmm0                 # u, v
    movsd   [rsp+8], xmm1
    mov     rsi, [rip+sh_src_t]
    shl     r12, 4
    add     rsi, r12
    mov     rdi, [rip+sh_src_p]
    mov     eax, [rsi]
    imul    r8, rax, VX_SZ
    mov     eax, [rsi+4]
    imul    r9, rax, VX_SZ
    mov     eax, [rsi+8]
    imul    r10, rax, VX_SZ
    add     r8, rdi
    add     r9, rdi
    add     r10, rdi
    xor     ecx, ecx                    # e1, e2 at [rsp+16], [rsp+40]?
35: movsd   xmm2, [r9+rcx*8]            # (the point; e1, e2 kept for n)
    subsd   xmm2, [r8+rcx*8]
    movsd   xmm3, [r10+rcx*8]
    subsd   xmm3, [r8+rcx*8]
    movsd   xmm4, xmm2
    mulsd   xmm4, [rsp]
    movsd   xmm5, xmm3
    mulsd   xmm5, [rsp+8]
    addsd   xmm4, xmm5
    addsd   xmm4, [r8+rcx*8]
    movsd   [rbx+rcx*8], xmm4
    inc     ecx
    cmp     ecx, 3
    jb      35b
    movsd   xmm0, [r9]                  # n = e1 x e2
    subsd   xmm0, [r8]
    movsd   xmm1, [r9+8]
    subsd   xmm1, [r8+8]
    movsd   xmm2, [r9+16]
    subsd   xmm2, [r8+16]
    movsd   xmm3, [r10]
    subsd   xmm3, [r8]
    movsd   xmm4, [r10+8]
    subsd   xmm4, [r8+8]
    movsd   xmm5, [r10+16]
    subsd   xmm5, [r8+16]
    movsd   xmm6, xmm1
    mulsd   xmm6, xmm5
    movsd   xmm7, xmm2
    mulsd   xmm7, xmm4
    subsd   xmm6, xmm7                  # nx
    movsd   xmm7, xmm2
    mulsd   xmm7, xmm3
    movsd   xmm8, xmm0
    mulsd   xmm8, xmm5
    subsd   xmm7, xmm8                  # ny
    movsd   xmm8, xmm0
    mulsd   xmm8, xmm4
    movsd   xmm9, xmm1
    mulsd   xmm9, xmm3
    subsd   xmm8, xmm9                  # nz
    movsd   xmm9, xmm6
    mulsd   xmm9, xmm6
    movsd   xmm10, xmm7
    mulsd   xmm10, xmm7
    addsd   xmm9, xmm10
    movsd   xmm10, xmm8
    mulsd   xmm10, xmm8
    addsd   xmm9, xmm10
    sqrtsd  xmm9, xmm9
    maxsd   xmm9, [rip+so_tiny]
    movsd   [rsp+16], xmm6
    movsd   [rsp+24], xmm7
    movsd   [rsp+32], xmm8
    movsd   [rsp+40], xmm9
    call    so_diag                     # in by 1% of the size
    mulsd   xmm0, [rip+so_01]
    divsd   xmm0, [rsp+40]
    xor     ecx, ecx
36: movsd   xmm1, [rsp+16+rcx*8]
    mulsd   xmm1, xmm0
    movsd   xmm2, [rbx+rcx*8]
    subsd   xmm2, xmm1
    movsd   [rbx+rcx*8], xmm2
    inc     ecx
    cmp     ecx, 3
    jb      36b
9:  add     rsp, 56
    pop     r12
    pop     rbx
    ret

# so_cdf_make -> eax = 1: so_cdf = the source triangles' areas, summed
so_cdf_make:
    push    rbx
    mov     rdi, [rip+so_cdf]
    mov     rsi, [rip+so_cdfsz]
    call    sh_unmap_g
    mov     esi, [rip+sh_src_nt]
    shl     rsi, 3
    mov     [rip+so_cdfsz], rsi
    call    sh_map_g
    mov     [rip+so_cdf], rax
    test    rax, rax
    jz      9f
    mov     rbx, rax
    xorpd   xmm15, xmm15
    mov     rsi, [rip+sh_src_t]
    mov     rdi, [rip+sh_src_p]
    xor     ecx, ecx
1:  cmp     ecx, [rip+sh_src_nt]
    jae     8f
    mov     eax, [rsi]
    imul    r8, rax, VX_SZ
    mov     eax, [rsi+4]
    imul    r9, rax, VX_SZ
    mov     eax, [rsi+8]
    imul    r10, rax, VX_SZ
    add     r8, rdi
    add     r9, rdi
    add     r10, rdi
    movsd   xmm0, [r9]
    subsd   xmm0, [r8]
    movsd   xmm1, [r9+8]
    subsd   xmm1, [r8+8]
    movsd   xmm2, [r9+16]
    subsd   xmm2, [r8+16]
    movsd   xmm3, [r10]
    subsd   xmm3, [r8]
    movsd   xmm4, [r10+8]
    subsd   xmm4, [r8+8]
    movsd   xmm5, [r10+16]
    subsd   xmm5, [r8+16]
    movsd   xmm6, xmm1
    mulsd   xmm6, xmm5
    movsd   xmm7, xmm2
    mulsd   xmm7, xmm4
    subsd   xmm6, xmm7
    mulsd   xmm6, xmm6
    movsd   xmm7, xmm2
    mulsd   xmm7, xmm3
    movsd   xmm8, xmm0
    mulsd   xmm8, xmm5
    subsd   xmm7, xmm8
    mulsd   xmm7, xmm7
    addsd   xmm6, xmm7
    movsd   xmm7, xmm0
    mulsd   xmm7, xmm4
    movsd   xmm8, xmm1
    mulsd   xmm8, xmm3
    subsd   xmm7, xmm8
    mulsd   xmm7, xmm7
    addsd   xmm6, xmm7
    sqrtsd  xmm6, xmm6
    addsd   xmm15, xmm6
    movsd   [rbx+rcx*8], xmm15
    add     rsi, 16
    inc     ecx
    jmp     1b
8:  mov     eax, 1
9:  pop     rbx
    ret

# -----------------------------------------------------------------------------
# Bricks: a running bond in the object's axes. Rows along Y, bricks along
#   X (each row's joints moved on by the offset), layers along Z; a gap
#   between bricks; joints moved by up to a jitter of a brick. A brick's
#   cell: the planes of its inner sides (each joint's plane tagged by the
#   joint: 1 << 24 | row << 12 | joint for those along X, 2 << 24 | row,
#   3 << 24 | layer).
# -----------------------------------------------------------------------------
# so_bricks -> eax = the cells (0: none)
so_bricks:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    push    rbp
    sub     rsp, 120
    cmp     dword ptr [rip+so_counted], 0   # count n: n a row, n / 2 rows
    je      91f
    cmp     dword ptr [rip+so_hascounts], 0
    jne     91f
    cmp     dword ptr [rip+so_hassize], 0
    jne     91f
    mov     eax, [rip+so_count]
    mov     [rip+so_counts], eax
    shr     eax, 1
    cmp     eax, 1
    jge     92f
    mov     eax, 1
92: mov     [rip+so_counts+4], eax
    mov     dword ptr [rip+so_counts+8], 1
91:                    # +0 sizes (3 doubles), +24 counts,
    xor     ecx, ecx                    #  +40 row, +44 joints in it, +48
1:  lea     rax, [rip+sh_src_max]       #  gaps (3 doubles), +72 cell, +80
    movsd   xmm0, [rax+rcx*8]           #  layer, +88 joint
    lea     rax, [rip+sh_src_min]
    subsd   xmm0, [rax+rcx*8]
    lea     rax, [rip+so_counts]        # the counts given, or the sizes'
    mov     edx, [rax+rcx*4]
    cmp     dword ptr [rip+so_hassize], 0
    je      2f
    cmp     dword ptr [rip+so_hascounts], 0
    jne     2f
    mov     rax, [rip+so_obj]           # (size in the world: / the scale)
    lea     r8, [rip+so_size]
    cvtss2sd xmm1, [r8+rcx*4]
    cvtss2sd xmm2, [rax+OB_SCALE+rcx*4]
    andpd   xmm2, [rip+so_abs]
    maxsd   xmm2, [rip+so_tiny]
    divsd   xmm1, xmm2
    maxsd   xmm1, [rip+so_tiny]
    movsd   xmm2, xmm0
    divsd   xmm2, xmm1
    addsd   xmm2, [rip+so_half]
    cvttsd2si edx, xmm2
    cmp     edx, 1
    jge     11f
    mov     edx, 1
11: cmp     edx, 4096
    jle     2f
    mov     edx, 4096
2:  mov     [rsp+24+rcx*4], edx
    cvtsi2sd xmm1, edx
    divsd   xmm0, xmm1
    movsd   [rsp+rcx*8], xmm0
    mov     rax, [rip+so_obj]           # the gap, local
    cvtss2sd xmm1, [rip+so_gap]
    cvtss2sd xmm2, [rax+OB_SCALE+rcx*4]
    andpd   xmm2, [rip+so_abs]
    maxsd   xmm2, [rip+so_tiny]
    divsd   xmm1, xmm2
    mulsd   xmm1, [rip+so_half]
    movsd   [rsp+48+rcx*8], xmm1
    inc     ecx
    cmp     ecx, 3
    jb      1b
    mov     eax, [rsp+24]               # cells: rows x (count + 1) x layers
    inc     eax                         #  at most
    imul    eax, [rsp+28]
    imul    eax, [rsp+32]
    cmp     eax, MAXSEEDS
    jbe     21f
    xor     eax, eax                    # (too many)
    jmp     9f
21: mov     edi, eax
    call    sh_cells_alloc
    test    eax, eax
    jz      9f
    mov     dword ptr [rsp+72], 0
    mov     dword ptr [rsp+40], 0       # each row: its joints
3:  mov     eax, [rsp+40]
    cmp     eax, [rsp+28]
    jae     8f
    cvtss2sd xmm0, [rip+so_offset]      # its offset: row x offset (mod 1), or
    cvtsi2sd xmm1, eax                  #  at random
    mulsd   xmm0, xmm1
    cmp     dword ptr [rip+so_offrand], 0
    je      31f
    call    so_rand
31: roundsd xmm1, xmm0, 1               # (floor)
    subsd   xmm0, xmm1
    mulsd   xmm0, [rsp]
    movsd   xmm1, [rip+sh_src_min]      # joints: min, min + o (when o), then
    lea     rbx, [rip+so_joints]        #  a brick on, up to max
    movsd   [rbx], xmm1
    mov     r12d, 1
    movsd   xmm2, [rsp]                 # (o less than 1% of a brick: none)
    mulsd   xmm2, [rip+so_001]
    comisd  xmm0, xmm2
    jbe     32f
    movsd   xmm3, [rsp]
    subsd   xmm3, xmm2
    comisd  xmm0, xmm3
    jae     32f
    addsd   xmm1, xmm0
    movsd   [rbx+r12*8], xmm1
    inc     r12d
32: movsd   xmm3, [rip+sh_src_max]
    subsd   xmm3, xmm2                  # (the last within 1% of max: max)
33: addsd   xmm1, [rsp]
    comisd  xmm1, xmm3
    jae     34f
    movsd   [rbx+r12*8], xmm1
    inc     r12d
    cmp     r12d, 4094
    jb      33b
34: movsd   xmm1, [rip+sh_src_max]
    movsd   [rbx+r12*8], xmm1
    inc     r12d
    mov     [rsp+44], r12d
    cvtss2sd xmm6, [rip+so_jitter]      # jitter: the inner joints, by up to
    xorpd   xmm7, xmm7                  #  half of it either way
    comisd  xmm6, xmm7
    jbe     36f
    mov     r13d, 1
35: lea     eax, [r13+1]
    cmp     eax, r12d
    jae     36f
    call    so_rand
    subsd   xmm0, [rip+so_half]
    cvtss2sd xmm6, [rip+so_jitter]
    mulsd   xmm0, xmm6
    mulsd   xmm0, [rsp]
    mulsd   xmm0, [rip+so_half]
    lea     rbx, [rip+so_joints]
    addsd   xmm0, [rbx+r13*8]
    movsd   [rbx+r13*8], xmm0
    inc     r13d
    jmp     35b
36: mov     dword ptr [rsp+80], 0       # each layer, each brick of the row
4:  mov     eax, [rsp+80]
    cmp     eax, [rsp+32]
    jae     7f
    mov     dword ptr [rsp+88], 0
5:  mov     eax, [rsp+88]
    inc     eax
    cmp     eax, [rsp+44]
    jae     6f
    call    so_brick_cell
    inc     dword ptr [rsp+88]
    jmp     5b
6:  inc     dword ptr [rsp+80]
    jmp     4b
7:  inc     dword ptr [rsp+40]
    jmp     3b
8:  mov     eax, [rsp+72]
    mov     [rip+sh_ncell_used], eax
9:  add     rsp, 120
    pop     rbp
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# so_brick_cell (so_bricks' frame one return address up: [rsp+8]) - the
#   brick between joints [+88] and [+88]+1 of row [+40], layer [+80]: its
#   bounds and the planes of its inner sides into cell [+72]
so_brick_cell:
    push    rbx
    push    r12
    push    r13
    lea     rbp, [rsp+32]               # (so_bricks' frame)
    sub     rsp, 104                    # +0 min, +24 max (doubles), +48 a plane
    lea     rax, [rip+so_joints]
    mov     ecx, [rbp+88]
    movsd   xmm0, [rax+rcx*8]
    movsd   [rsp], xmm0
    movsd   xmm0, [rax+rcx*8+8]
    movsd   [rsp+24], xmm0
    cvtsi2sd xmm0, dword ptr [rbp+40]   # y: the row
    mulsd   xmm0, [rbp+8]
    addsd   xmm0, [rip+sh_src_min+8]
    movsd   [rsp+8], xmm0
    addsd   xmm0, [rbp+8]
    movsd   [rsp+32], xmm0
    cvtsi2sd xmm0, dword ptr [rbp+80]   # z: the layer
    mulsd   xmm0, [rbp+16]
    addsd   xmm0, [rip+sh_src_min+16]
    movsd   [rsp+16], xmm0
    addsd   xmm0, [rbp+16]
    movsd   [rsp+40], xmm0
    mov     ebx, [rbp+72]               # the cell
    imul    rdi, rbx, 48                # its bounds
    add     rdi, [rip+sh_cbb]
    mov     rsi, rsp
    mov     ecx, 6
    rep     movsq
    imul    r12, rbx, CPL_MAX*PLN_SZ    # its planes
    add     r12, [rip+sh_cpl]
    xor     r13d, r13d
    xor     ecx, ecx                    # the six sides: axis, +/-
1:  cmp     ecx, 6
    jae     8f
    mov     edx, ecx
    shr     edx, 1                      # (axis)
    lea     rax, [rip+sh_src_min]       # on the bounds: no plane
    movsd   xmm0, [rax+rdx*8]
    lea     rax, [rip+sh_src_max]
    movsd   xmm1, [rax+rdx*8]
    movsd   xmm4, [rbp+rdx*8]           # (1% of a brick)
    mulsd   xmm4, [rip+so_001]
    addsd   xmm0, xmm4
    subsd   xmm1, xmm4
    test    ecx, 1
    jnz     2f
    movsd   xmm2, [rsp+24+rdx*8]        # max side: x <= max - gap
    comisd  xmm2, xmm1
    jae     7f
    subsd   xmm2, [rbp+48+rdx*8]
    movsd   xmm3, [rip+so_one]
    jmp     3f
2:  movsd   xmm2, [rsp+rdx*8]           # min side: -x <= -(min + gap)
    comisd  xmm2, xmm0
    jbe     7f
    addsd   xmm2, [rbp+48+rdx*8]
    xorpd   xmm3, xmm3
    subsd   xmm3, [rip+so_one]
    xorpd   xmm4, xmm4
    subsd   xmm4, xmm2
    movsd   xmm2, xmm4
3:  imul    rdi, r13, PLN_SZ
    add     rdi, r12
    xorpd   xmm4, xmm4
    movsd   [rdi], xmm4
    movsd   [rdi+8], xmm4
    movsd   [rdi+16], xmm4
    movsd   [rdi+rdx*8], xmm3
    movsd   [rdi+24], xmm2
    mov     eax, ecx                    # its joint's tag
    test    edx, edx
    jnz     4f
    mov     eax, [rbp+88]               # x: row << 12 | joint
    test    ecx, 1
    jnz     31f
    inc     eax
31: mov     r8d, [rbp+40]
    shl     r8d, 12
    or      eax, r8d
    or      eax, 1 << 24
    jmp     6f
4:  cmp     edx, 1
    jne     5f
    mov     eax, [rbp+40]               # y: the row boundary
    test    ecx, 1
    jnz     41f
    inc     eax
41: or      eax, 2 << 24
    jmp     6f
5:  mov     eax, [rbp+80]               # z: the layer boundary
    test    ecx, 1
    jnz     51f
    inc     eax
51: or      eax, 3 << 24
6:  mov     [rdi+PLN_TAG], eax
    inc     r13d
7:  inc     ecx
    jmp     1b
8:  mov     rax, [rip+sh_cpn]
    mov     [rax+rbx*4], r13d
    inc     dword ptr [rbp+72]
    add     rsp, 104
    pop     r13
    pop     r12
    pop     rbx
    ret

# -----------------------------------------------------------------------------
# Balls: the volume packed with spheres: the points of a face-centred
#   cubic lattice 2r apart that are inside and r (0.8 of it) from the
#   surface; r shrinks until there are enough, then the count is taken at
#   random. One sphere mesh for all; each ball the colour of the vertex
#   nearest it (or the object's).
# -----------------------------------------------------------------------------
# so_balls -> eax = balls made
so_balls:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    push    rbp
    sub     rsp, 88                     # +0 r, +8 the lattice's side a,
    mov     rax, [rip+so_obj]           #  +16 tries, +24 points, +32 kept,
    movss   xmm0, [rax+OB_SCALE]        #  +40 the mean scale, +48 sphere
    addss   xmm0, [rax+OB_SCALE+4]
    addss   xmm0, [rax+OB_SCALE+8]
    andps   xmm0, [rip+so_absf]
    mulss   xmm0, [rip+so_third]
    movss   [rip+so_meanscale], xmm0
    cvtss2sd xmm0, xmm0
    maxsd   xmm0, [rip+so_tiny]
    movsd   [rsp+40], xmm0
    cvtss2sd xmm0, [rip+so_radius]      # r: given (world), or the volume's
    xorpd   xmm1, xmm1
    comisd  xmm0, xmm1
    jbe     1f
    divsd   xmm0, [rsp+40]
    jmp     2f
1:  movsd   xmm0, [rip+sh_src_vol]      # (0.55 V / (n 4/3 pi))^(1/3)
    andpd   xmm0, [rip+so_abs]
    mulsd   xmm0, [rip+so_055]
    cvtsi2sd xmm1, dword ptr [rip+so_count]
    mulsd   xmm1, [rip+so_sph]
    divsd   xmm0, xmm1
    call    so_cbrt
2:  movsd   [rsp], xmm0
    mov     dword ptr [rsp+16], 0
3:  inc     dword ptr [rsp+16]          # the lattice for this r
    cmp     dword ptr [rsp+16], 24
    ja      .Lbl_take
    call    bl_lattice
    mov     [rsp+24], eax
    cmp     eax, BL_MAX                 # (too many points: a larger r)
    jb      31f
    movsd   xmm0, [rsp]
    mulsd   xmm0, [rip+so_12]
    movsd   [rsp], xmm0
    jmp     3b
31: test    eax, eax
    jz      34f
    push    rax
    push    rax
    call    sh_inside_prep              # (the inside test's grid)
    pop     rax
    pop     rax
    lea     rdi, [rip+ball_job]         # which are in, clear of the surface
    xor     esi, esi
    mov     edx, eax
    mov     ecx, 16
    call    parallel_for
    xor     ecx, ecx                    # kept: packed to the front
    xor     edx, edx
32: cmp     ecx, [rsp+24]
    jae     33f
    lea     rax, [rip+so_cin]
    cmp     byte ptr [rax+rcx], 0
    je      321f
    imul    rsi, rcx, VX_SZ
    lea     rax, [rip+so_bpts]
    add     rsi, rax
    imul    rdi, rdx, VX_SZ
    add     rdi, rax
    push    rcx
    mov     ecx, VX_SZ
    rep     movsb
    pop     rcx
    inc     edx
321:inc     ecx
    jmp     32b
33: mov     [rsp+32], edx
    cvtss2sd xmm0, [rip+so_radius]      # (a radius and no count: as many as
    xorpd   xmm1, xmm1                  #  fit)
    comisd  xmm0, xmm1
    jbe     331f
    cmp     dword ptr [rip+so_counted], 0
    jne     331f
    cmp     edx, MAXSEEDS
    jbe     332f
    mov     edx, MAXSEEDS
332:mov     [rip+so_count], edx
    jmp     .Lbl_take
331:cmp     edx, [rip+so_count]
    jae     .Lbl_take
    test    edx, edx                    # too few: r by (kept / n)^(1/3)
    jnz     35f
34: movsd   xmm0, [rsp]
    mulsd   xmm0, [rip+so_half]
    movsd   [rsp], xmm0
    jmp     3b
35: cvtsi2sd xmm0, edx
    cvtsi2sd xmm1, dword ptr [rip+so_count]
    divsd   xmm0, xmm1
    call    so_cbrt
    mulsd   xmm0, [rip+so_097]
    mulsd   xmm0, [rsp]
    movsd   [rsp], xmm0
    jmp     3b
.Lbl_take:
    mov     ebx, [rsp+32]               # n of them at random (a partial
    cmp     ebx, [rip+so_count]         #  shuffle)
    jbe     4f
    xor     r12d, r12d
41: cmp     r12d, [rip+so_count]
    jae     42f
    call    so_rand
    mov     eax, ebx
    sub     eax, r12d
    cvtsi2sd xmm1, eax
    mulsd   xmm0, xmm1
    cvttsd2si eax, xmm0
    add     eax, r12d                   # swap r12 and eax
    lea     rdx, [rip+so_bpts]
    imul    rsi, r12, VX_SZ
    imul    rdi, rax, VX_SZ
    add     rsi, rdx
    add     rdi, rdx
    xor     ecx, ecx
411:mov     r8, [rsi+rcx*8]
    mov     r9, [rdi+rcx*8]
    mov     [rsi+rcx*8], r9
    mov     [rdi+rcx*8], r8
    inc     ecx
    cmp     ecx, 3
    jb      411b
    inc     r12d
    jmp     41b
42: mov     ebx, [rip+so_count]
4:  xor     eax, eax
    test    ebx, ebx
    jz      .Lbl_out
    call    prim_uvsphere               # the sphere (radius 1)
    test    rax, rax
    jz      .Lbl_out
    mov     [rsp+48], rax
    xor     r12d, r12d                  # each ball
5:  cmp     r12d, ebx
    jae     6f
    call    so_nextname
    test    r12d, r12d
    jz      51f
    mov     rdi, [rsp+48]
    call    mesh_ref
51: mov     edi, OT_MESH
    lea     rsi, [rip+so_name]
    mov     rdx, [rsp+48]
    call    obj_new
    test    eax, eax
    jz      6f
    mov     [rip+so_lasth], eax
    cmp     dword ptr [rip+so_first], 0
    jne     52f
    mov     [rip+so_first], eax
52: mov     edi, eax
    call    obj_get
    mov     r13, rax
    mov     rsi, [rip+so_obj]
    mov     eax, [rsi+OB_COLOR]
    mov     [r13+OB_COLOR], eax
    mov     rax, [rsi+OB_MAT]
    mov     [r13+OB_MAT], rax
    or      dword ptr [r13+OB_FLAGS], OBF_SELECTED
    imul    r14, r12, VX_SZ             # its place: M c
    lea     rax, [rip+so_bpts]
    add     r14, rax
    lea     rax, [rip+so_mat]
    xor     ecx, ecx
53: cvtsd2ss xmm0, [r14]
    mulss   xmm0, [rax]
    cvtsd2ss xmm1, [r14+8]
    mulss   xmm1, [rax+4]
    addss   xmm0, xmm1
    cvtsd2ss xmm1, [r14+16]
    mulss   xmm1, [rax+8]
    addss   xmm0, xmm1
    addss   xmm0, [rax+12]
    movss   [r13+OB_LOC+rcx*4], xmm0
    add     rax, 16
    inc     ecx
    cmp     ecx, 3
    jb      53b
    movsd   xmm0, [rsp]                 # its radius: r (1 - spread u) x the
    cvtss2sd xmm1, [rip+so_spread]      #  mean scale
    cmp     dword ptr [rip+so_spreadset], 0
    jne     54f
    xorpd   xmm1, xmm1                  # (balls: one radius unless asked)
54: movsd   [rsp+56], xmm1
    movsd   [rsp+64], xmm0
    call    so_rand
    mulsd   xmm0, [rsp+56]
    movsd   xmm1, [rip+so_one]
    subsd   xmm1, xmm0
    mulsd   xmm1, [rsp+64]
    mulsd   xmm1, [rsp+40]
    cvtsd2ss xmm1, xmm1
    movss   [r13+OB_SCALE], xmm1
    movss   [r13+OB_SCALE+4], xmm1
    movss   [r13+OB_SCALE+8], xmm1
    lea     rax, [rip+so_brad]          # (its radius, local: for the stats)
    cvtss2sd xmm0, [r13+OB_SCALE]
    divsd   xmm0, [rsp+40]
    movsd   [rax+r12*8], xmm0
    movsd   xmm1, xmm0                  # (its volume, local)
    mulsd   xmm1, xmm0
    mulsd   xmm1, xmm0
    mulsd   xmm1, [rip+so_sph]
    movsd   xmm0, xmm1
    mov     edi, [rip+so_lasth]
    call    so_record
    mov     rdi, r14                    # the colour of the vertex nearest
    call    so_near_colour
    test    eax, eax
    jz      55f
    mov     [r13+OB_COLOR], edx
55: inc     r12d
    jmp     5b
6:  mov     [rsp+56], r12d
    lea     rcx, [rip+sh_stat]          # (the radius, world: stat 18)
    movsd   xmm0, [rsp]
    mulsd   xmm0, [rsp+40]
    movsd   [rcx+18*8], xmm0
    mov     edi, r12d
    call    so_ball_stats
    mov     eax, [rsp+56]
.Lbl_out:
    add     rsp, 88
    pop     rbp
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# so_ball_stats(edi=balls) - stat 19: the least gap between two balls over
#   the radius, 20: the most a ball reaches past the surface over its
#   radius (so_bpts, so_brad; local)
so_ball_stats:
    push    rbx
    push    r12
    push    r13
    sub     rsp, 16
    mov     ebx, edi
    movsd   xmm6, [rip+so_big]          # least gap
    xorpd   xmm7, xmm7                  # most past (or less)
    subsd   xmm7, xmm6
    xor     r12d, r12d
1:  cmp     r12d, ebx
    jae     5f
    imul    r8, r12, VX_SZ
    lea     rax, [rip+so_bpts]
    add     r8, rax
    lea     r9, [rip+so_brad]
    lea     r13d, [r12+1]
2:  cmp     r13d, ebx
    jae     3f
    imul    r10, r13, VX_SZ
    add     r10, rax
    movsd   xmm0, [r10]
    subsd   xmm0, [r8]
    mulsd   xmm0, xmm0
    movsd   xmm1, [r10+8]
    subsd   xmm1, [r8+8]
    mulsd   xmm1, xmm1
    addsd   xmm0, xmm1
    movsd   xmm1, [r10+16]
    subsd   xmm1, [r8+16]
    mulsd   xmm1, xmm1
    addsd   xmm0, xmm1
    sqrtsd  xmm0, xmm0
    subsd   xmm0, [r9+r12*8]
    subsd   xmm0, [r9+r13*8]
    divsd   xmm0, [r9+r12*8]
    minsd   xmm6, xmm0
    inc     r13d
    jmp     2b
3:  movsd   [rsp], xmm6                 # past the surface: r - distance
    movsd   [rsp+8], xmm7
    movsd   xmm0, [r8]
    movsd   xmm1, [r8+8]
    movsd   xmm2, [r8+16]
    call    sh_dist2
    sqrtsd  xmm0, xmm0
    lea     r9, [rip+so_brad]
    movsd   xmm1, [r9+r12*8]
    subsd   xmm1, xmm0
    divsd   xmm1, [r9+r12*8]
    movsd   xmm6, [rsp]
    movsd   xmm7, [rsp+8]
    maxsd   xmm7, xmm1
    inc     r12d
    jmp     1b
5:  lea     rax, [rip+sh_stat]
    movsd   [rax+19*8], xmm6
    movsd   [rax+20*8], xmm7
    add     rsp, 16
    pop     r13
    pop     r12
    pop     rbx
    ret

# bl_lattice ([rsp+8] = so_balls' r: one return address up) -> eax = the
#   lattice's points in the bounds less r (so_bpts), BL_MAX when more
bl_lattice:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    sub     rsp, 48
    movsd   xmm7, [rsp+48+48]           # r (so_balls' [rsp]: 5 pushes, ret)
    movsd   xmm6, xmm7                  # a = 2 sqrt 2 r
    mulsd   xmm6, [rip+so_2r2]
    movsd   [rsp], xmm6
    movsd   [rsp+8], xmm7
    xor     ecx, ecx                    # cells a side: (max - min - 2r) / a + 1
1:  lea     rax, [rip+sh_src_max]
    movsd   xmm0, [rax+rcx*8]
    lea     rax, [rip+sh_src_min]
    subsd   xmm0, [rax+rcx*8]
    subsd   xmm0, xmm7
    subsd   xmm0, xmm7
    xorpd   xmm1, xmm1
    maxsd   xmm0, xmm1
    divsd   xmm0, xmm6
    cvttsd2si eax, xmm0
    inc     eax
    cmp     eax, 4096
    jbe     11f
    mov     eax, 4096
11: mov     [rsp+16+rcx*4], eax
    inc     ecx
    cmp     ecx, 3
    jb      1b
    mov     eax, [rsp+16]               # (too many: say so)
    imul    eax, [rsp+20]
    jo      8f
    cmp     eax, BL_MAX
    jae     8f
    imul    eax, [rsp+24]
    jo      8f
    cmp     eax, BL_MAX/4
    jae     8f
    xor     ebx, ebx                    # points
    xor     r12d, r12d                  # i, j, k; the four of a cell
2:  cmp     r12d, [rsp+24]
    jae     7f
    xor     r13d, r13d
3:  cmp     r13d, [rsp+20]
    jae     6f
    xor     r14d, r14d
4:  cmp     r14d, [rsp+16]
    jae     5f
    xor     r15d, r15d
41: cmp     r15d, 4
    jae     42f
    lea     rax, [rip+fcc_off]
    imul    rdi, rbx, VX_SZ
    lea     rdx, [rip+so_bpts]
    add     rdi, rdx
    cvtsi2sd xmm0, r14d                 # min + r + (i + o) a
    cvtsi2sd xmm1, r13d
    cvtsi2sd xmm2, r12d
    lea     rdx, [r15+r15*2]
    addsd   xmm0, [rax+rdx*8]
    addsd   xmm1, [rax+rdx*8+8]
    addsd   xmm2, [rax+rdx*8+16]
    mulsd   xmm0, [rsp]
    mulsd   xmm1, [rsp]
    mulsd   xmm2, [rsp]
    addsd   xmm0, [rsp+8]
    addsd   xmm1, [rsp+8]
    addsd   xmm2, [rsp+8]
    addsd   xmm0, [rip+sh_src_min]
    addsd   xmm1, [rip+sh_src_min+8]
    addsd   xmm2, [rip+sh_src_min+16]
    movsd   [rdi], xmm0
    movsd   [rdi+8], xmm1
    movsd   [rdi+16], xmm2
    inc     ebx
    inc     r15d
    jmp     41b
42: inc     r14d
    jmp     4b
5:  inc     r13d
    jmp     3b
6:  inc     r12d
    jmp     2b
7:  mov     eax, ebx
    movsd   xmm0, [rsp+8]               # (r for the job)
    movsd   [rip+so_br], xmm0
    jmp     9f
8:  mov     eax, BL_MAX
9:  add     rsp, 48
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# ball_job(rdi, esi=begin, edx=end) - so_cin[i]: point i is inside and at
#   least 0.8 r from the surface
ball_job:
    push    rbx
    push    r12
    sub     rsp, 8
    mov     ebx, esi
    mov     r12d, edx
1:  cmp     ebx, r12d
    jae     9f
    imul    rax, rbx, VX_SZ
    lea     rdx, [rip+so_bpts]
    add     rax, rdx
    movsd   xmm0, [rax]
    movsd   xmm1, [rax+8]
    movsd   xmm2, [rax+16]
    call    sh_inside
    lea     rdx, [rip+so_cin]
    mov     [rdx+rbx], al
    test    eax, eax
    jz      2f
    imul    rax, rbx, VX_SZ
    lea     rdx, [rip+so_bpts]
    add     rax, rdx
    movsd   xmm0, [rax]
    movsd   xmm1, [rax+8]
    movsd   xmm2, [rax+16]
    call    sh_dist2
    movsd   xmm1, [rip+so_br]
    mulsd   xmm1, [rip+so_08]
    mulsd   xmm1, xmm1
    xor     eax, eax
    comisd  xmm0, xmm1
    setae   al
    lea     rdx, [rip+so_cin]
    mov     [rdx+rbx], al
2:  inc     ebx
    jmp     1b
9:  add     rsp, 8
    pop     r12
    pop     rbx
    ret

# so_near_colour(rdi=3 doubles, local) -> eax = 1 and edx = the colour of
#   the source's vertex nearest it (0: the mesh has no colours)
so_near_colour:
    mov     rax, [rip+so_obj]
    mov     rax, [rax+OB_MESH]
    mov     r8, [rax+ME_VCOL]
    test    r8, r8
    jz      8f
    mov     r9, [rip+sh_src_p]
    mov     ecx, [rip+sh_src_nv]
    cmp     ecx, [rax+ME_NVERTS]        # (its own mesh's vertices only)
    jne     8f
    movsd   xmm3, [rip+so_big]
    xor     edx, edx
    xor     esi, esi
1:  cmp     esi, ecx
    jae     2f
    imul    rax, rsi, VX_SZ
    movsd   xmm0, [r9+rax]
    subsd   xmm0, [rdi]
    mulsd   xmm0, xmm0
    movsd   xmm1, [r9+rax+8]
    subsd   xmm1, [rdi+8]
    mulsd   xmm1, xmm1
    addsd   xmm0, xmm1
    movsd   xmm1, [r9+rax+16]
    subsd   xmm1, [rdi+16]
    mulsd   xmm1, xmm1
    addsd   xmm0, xmm1
    comisd  xmm0, xmm3
    jae     11f
    movsd   xmm3, xmm0
    mov     edx, esi
11: inc     esi
    jmp     1b
2:  mov     edx, [r8+rdx*4]
    mov     eax, 1
    ret
8:  xor     eax, eax
    ret

# so_cbrt(xmm0) -> xmm0 = its cube root (x > 0; x87)
so_cbrt:
    sub     rsp, 8
    movsd   [rsp], xmm0
    xorpd   xmm1, xmm1
    comisd  xmm0, xmm1
    jbe     9f
    fld1                                # 2^(log2 x / 3)
    fld     qword ptr [rsp]
    fyl2x
    fdiv    qword ptr [rip+so_three]
    fld     st(0)
    frndint
    fsub    st(1), st(0)
    fxch
    f2xm1
    fld1
    faddp
    fscale
    fstp    st(1)
    fstp    qword ptr [rsp]
9:  movsd   xmm0, [rsp]
    add     rsp, 8
    ret

# so_seeds(edi=count) -> eax = seeds made: points inside the source, at
#   random in its bounds; tried in batches, in parallel, kept in order
so_seeds:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    sub     rsp, 16
    mov     r12d, edi
    mov     rdi, [rip+sh_seeds]
    mov     rsi, [rip+so_seedsz]
    call    sh_unmap_g
    mov     esi, r12d
    imul    rsi, rsi, VX_SZ
    mov     [rip+so_seedsz], rsi
    call    sh_map_g
    mov     [rip+sh_seeds], rax
    mov     dword ptr [rip+sh_nseeds], 0
    test    rax, rax
    jz      9f
    xor     ebx, ebx                    # made
    mov     r13d, r12d                  # tries: 200 a seed at most
    imul    r13d, r13d, 200
    add     r13d, 1000
1:  cmp     ebx, r12d
    jae     9f
    test    r13d, r13d
    jle     9f
    mov     r14d, r12d                  # a batch: twice those still to make
    sub     r14d, ebx
    add     r14d, r14d
    add     r14d, 32
    cmp     r14d, SB_MAX
    jbe     2f
    mov     r14d, SB_MAX
2:  sub     r13d, r14d
    xor     r15d, r15d                  # the points (in order)
3:  cmp     r15d, r14d
    jae     4f
    imul    rdi, r15, VX_SZ
    lea     rax, [rip+so_cand]
    add     rdi, rax
    call    so_cand_pt
    inc     r15d
    jmp     3b
4:  call    sh_inside_prep              # (the inside test's grid)
    lea     rdi, [rip+seed_job]         # inside? (all at once)
    xor     esi, esi
    mov     edx, r14d
    mov     ecx, 8
    call    parallel_for
    xor     r15d, r15d                  # those inside, in order
5:  cmp     r15d, r14d
    jae     1b
    cmp     ebx, r12d
    jae     9f
    lea     rax, [rip+so_cin]
    cmp     byte ptr [rax+r15], 0
    je      6f
    imul    rsi, r15, VX_SZ
    lea     rax, [rip+so_cand]
    add     rsi, rax
    imul    rdi, rbx, VX_SZ
    add     rdi, [rip+sh_seeds]
    mov     ecx, VX_SZ
    rep     movsb
    inc     ebx
    mov     [rip+sh_nseeds], ebx
6:  inc     r15d
    jmp     5b
9:  mov     eax, [rip+sh_nseeds]
    add     rsp, 16
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# seed_job(rdi, esi=begin, edx=end) - so_cin[i] = so_cand[i] is inside
seed_job:
    push    rbx
    push    r12
    sub     rsp, 8
    mov     ebx, esi
    mov     r12d, edx
1:  cmp     ebx, r12d
    jae     9f
    imul    rax, rbx, VX_SZ
    lea     rdx, [rip+so_cand]
    add     rax, rdx
    movsd   xmm0, [rax]
    movsd   xmm1, [rax+8]
    movsd   xmm2, [rax+16]
    call    sh_inside
    lea     rdx, [rip+so_cin]
    mov     [rdx+rbx], al
    inc     ebx
    jmp     1b
9:  add     rsp, 8
    pop     r12
    pop     rbx
    ret

# sh_map_g(rsi=bytes) -> rax; sh_unmap_g(rdi, rsi) (this file's own)
sh_map_g:
    add     rsi, 4095
    and     rsi, -4096
    jnz     1f
    mov     esi, 4096
1:  xor     edi, edi
    mov     edx, PROT_RW
    mov     r10d, 0x22
    mov     r8, -1
    xor     r9d, r9d
    call    plat_mmap
    cmp     rax, -4096
    jb      2f
    xor     eax, eax
2:  ret
sh_unmap_g:
    test    rdi, rdi
    jz      1f
    add     rsi, 4095
    and     rsi, -4096
    call    plat_munmap
1:  ret

# so_basename(rsi=suffix) - so_nbase = the object's name (18 at most) + it
so_basename:
    mov     rax, [rip+so_obj]
    lea     rdi, [rip+so_nbase]
    xor     ecx, ecx
1:  mov     dl, [rax+OB_NAME+rcx]
    test    dl, dl
    jz      2f
    cmp     ecx, 18
    jae     2f
    mov     [rdi+rcx], dl
    inc     ecx
    jmp     1b
2:  mov     dl, [rsi]
    mov     [rdi+rcx], dl
    test    dl, dl
    jz      3f
    inc     rsi
    inc     ecx
    jmp     2b
3:  mov     dword ptr [rip+so_ctr], 0
    ret

# so_nextname -> so_name = so_nbase + the next number
so_nextname:
    inc     dword ptr [rip+so_ctr]
    lea     rdi, [rip+so_name]
    lea     rsi, [rip+so_nbase]
1:  mov     al, [rsi]
    test    al, al
    jz      2f
    mov     [rdi], al
    inc     rsi
    inc     rdi
    jmp     1b
2:  mov     eax, [rip+so_ctr]           # digits, backwards then turned
    lea     rsi, [rdi]
3:  xor     edx, edx
    mov     ecx, 10
    div     ecx
    add     dl, '0'
    mov     [rdi], dl
    inc     rdi
    test    eax, eax
    jnz     3b
    mov     byte ptr [rdi], 0
    dec     rdi
4:  cmp     rsi, rdi
    jae     5f
    mov     al, [rsi]
    mov     cl, [rdi]
    mov     [rsi], cl
    mov     [rdi], al
    inc     rsi
    dec     rdi
    jmp     4b
5:  ret

# so_piece_next(rsi=piece header) -> rax = the next one's
so_piece_next:
    mov     eax, [rsi+PH_NV]
    imul    eax, eax, 12
    mov     ecx, [rsi+PH_NP]
    lea     eax, [rax+rcx*8]
    mov     ecx, [rsi+PH_NL]
    lea     eax, [rax+rcx*4]
    lea     rax, [rsi+PH_SZ+rax]
    ret

# so_inner_map(rbx=piece) -> eax = how many vertices the cut faces (tag
#   not 0) use, so_imap = each one's copy (index from the piece's vertex
#   count), so_imap_rev the other way; 0 without an inner colour
so_inner_map:
    xor     eax, eax
    cmp     dword ptr [rip+so_inner], 0
    jne     0f
    ret
0:  push    r12
    push    r13
    sub     rsp, 8
    mov     esi, [rbx+PH_NV]            # (frame arena: until the next frame)
    shl     rsi, 3
    lea     rdi, [rip+frame_arena]
    call    arena_alloc
    test    rax, rax
    jz      8f
    mov     [rip+so_imap], rax
    mov     ecx, [rbx+PH_NV]
    lea     rdx, [rax+rcx*4]
    mov     [rip+so_imap_rev], rdx
    mov     rdi, rax
    mov     eax, -1
    rep     stosd
    mov     eax, [rbx+PH_NV]            # the cut faces' vertices
    imul    eax, eax, 12
    lea     r8, [rbx+PH_SZ+rax]         # records
    mov     eax, [rbx+PH_NP]
    lea     r9, [r8+rax*8]              # loops
    xor     r12d, r12d                  # copies
    xor     r13d, r13d
1:  cmp     r13d, [rbx+PH_NP]
    jae     7f
    mov     ecx, [r8]
    cmp     dword ptr [r8+4], 0
    je      3f
    xor     edx, edx
2:  cmp     edx, ecx
    jae     3f
    mov     eax, [r9+rdx*4]
    mov     rsi, [rip+so_imap]
    cmp     dword ptr [rsi+rax*4], -1
    jne     21f
    mov     [rsi+rax*4], r12d
    mov     rsi, [rip+so_imap_rev]
    mov     [rsi+r12*4], eax
    inc     r12d
21: inc     edx
    jmp     2b
3:  lea     r9, [r9+rcx*4]
    add     r8, 8
    inc     r13d
    jmp     1b
7:  mov     eax, r12d
    jmp     9f
8:  xor     eax, eax
9:  add     rsp, 8
    pop     r13
    pop     r12
    ret

# so_make(rsi=piece header; so_obj, so_mat) -> eax = its object's handle
#   (0: none): its mesh (vertices from its centre, its polygons), placed at
#   the centre, turned and scaled like the original
so_make:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    sub     rsp, 32
    mov     rbx, rsi
    call    so_inner_map                # (an inner colour: the cut faces'
    mov     [rsp+8], eax                #  vertices twice, eax = how many)
    mov     edi, [rbx+PH_NV]
    add     edi, eax
    mov     esi, [rbx+PH_NL]
    mov     edx, [rbx+PH_NP]
    call    mesh_new
    test    rax, rax
    jz      8f
    mov     r12, rax
    lea     r13, [rbx+PH_SZ]            # vertices
    xor     r14d, r14d
1:  cmp     r14d, [rbx+PH_NV]
    jae     11f
    movss   xmm0, [r13]
    movss   xmm1, [r13+4]
    movss   xmm2, [r13+8]
    mov     rdi, r12
    call    mesh_add_vert
    add     r13, 12
    inc     r14d
    jmp     1b
11: xor     r14d, r14d                  # (the cut faces' copies, coloured)
12: cmp     r14d, [rsp+8]
    jae     2f
    mov     rax, [rip+so_imap_rev]
    mov     eax, [rax+r14*4]
    imul    rax, rax, 12
    lea     rax, [rbx+PH_SZ+rax]
    movss   xmm0, [rax]
    movss   xmm1, [rax+4]
    movss   xmm2, [rax+8]
    mov     rdi, r12
    call    mesh_add_vert
    inc     r14d
    jmp     12b
2:  cmp     dword ptr [rsp+8], 0
    je      21f
    mov     rdi, r12
    call    mesh_vcol_alloc
    test    rax, rax
    jz      21f
    mov     ecx, [rbx+PH_NV]
    mov     edx, [rip+so_innerc]
    or      edx, 0xff000000
    xor     r8d, r8d
22: cmp     r8d, [rsp+8]
    jae     21f
    lea     r9d, [rcx+r8]
    mov     [rax+r9*4], edx
    inc     r8d
    jmp     22b
21: mov     eax, [rbx+PH_NP]            # polygons (r13: their records, r15
    lea     r15, [r13+rax*8]            #  their loops)
    xor     r14d, r14d
3:  cmp     r14d, [rbx+PH_NP]
    jae     4f
    mov     rsi, r15
    cmp     dword ptr [rsp+8], 0        # a cut face: its vertices' copies
    je      31f
    cmp     dword ptr [r13+4], 0
    je      31f
    mov     ecx, [r13]
    cmp     ecx, 256
    ja      31f
    lea     rdi, [rip+so_ipoly]
    mov     r8, [rip+so_imap]
    xor     edx, edx
32: mov     eax, [r15+rdx*4]
    mov     eax, [r8+rax*4]
    add     eax, [rbx+PH_NV]
    mov     [rdi+rdx*4], eax
    inc     edx
    cmp     edx, ecx
    jb      32b
    mov     rsi, rdi
31: mov     rdi, r12
    mov     edx, [r13]
    call    mesh_add_poly
    mov     eax, [r13]
    lea     r15, [r15+rax*4]
    add     r13, 8
    inc     r14d
    jmp     3b
4:  call    fa_mark
    mov     r15, rax
    mov     rdi, r12
    call    mesh_finish
    mov     rdi, r15
    call    fa_release
    call    so_nextname
    mov     edi, OT_MESH
    lea     rsi, [rip+so_name]
    mov     rdx, r12
    call    obj_new
    test    eax, eax
    jz      8f
    mov     r14d, eax
    mov     edi, eax
    movsd   xmm0, [rbx+PH_VOL]
    call    so_record
    mov     edi, r14d
    call    obj_get
    mov     r15, rax
    mov     rsi, [rip+so_obj]           # like the original
    mov     eax, [rsi+OB_COLOR]
    mov     [r15+OB_COLOR], eax
    mov     rax, [rsi+OB_MAT]
    mov     [r15+OB_MAT], rax
    mov     rax, [rsi+OB_ROT]
    mov     [r15+OB_ROT], rax
    mov     eax, [rsi+OB_ROT+8]
    mov     [r15+OB_ROT+8], eax
    mov     rax, [rsi+OB_SCALE]
    mov     [r15+OB_SCALE], rax
    mov     eax, [rsi+OB_SCALE+8]
    mov     [r15+OB_SCALE+8], eax
    or      dword ptr [r15+OB_FLAGS], OBF_SELECTED
    cvtsd2ss xmm3, [rbx+PH_C]           # loc = M c
    cvtsd2ss xmm4, [rbx+PH_C+8]
    cvtsd2ss xmm5, [rbx+PH_C+16]
    lea     rax, [rip+so_mat]
    xor     ecx, ecx
5:  movss   xmm0, [rax]
    mulss   xmm0, xmm3
    movss   xmm1, [rax+4]
    mulss   xmm1, xmm4
    addss   xmm0, xmm1
    movss   xmm1, [rax+8]
    mulss   xmm1, xmm5
    addss   xmm0, xmm1
    addss   xmm0, [rax+12]
    movss   [r15+OB_LOC+rcx*4], xmm0
    add     rax, 16
    inc     ecx
    cmp     ecx, 3
    jb      5b
    mov     eax, r14d
    jmp     9f
8:  xor     eax, eax
9:  add     rsp, 32
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# so_record(edi=handle, xmm0=volume, local) - a piece made (so_pieces)
so_record:
    mov     eax, [rip+so_npieces]
    cmp     eax, MAX_OBJECTS
    jae     1f
    lea     rcx, [rip+so_pieces]
    mov     [rcx+rax*4], edi
    lea     rcx, [rip+so_pvol]
    movsd   [rcx+rax*8], xmm0
    inc     dword ptr [rip+so_npieces]
1:  ret

# so_bodies -> eax = rigid bodies made: every piece an active body (a hull;
#   a ball a sphere), its mass its volume x the density (the option's in
#   kg/m^3, else the material's, else water's), friction, bounce, damping,
#   group and starting velocity the original's when it is a body; each a
#   child of the original (hidden, folded in the outliner)
so_bodies:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    sub     rsp, 64                     # +0 friction, bounce, damping,
    mov     rax, [rip+so_obj]           #  flags, +16 velocity, +32 density,
    or      dword ptr [rax+OB_FLAGS], OBF_COLLAPSED    #  +40 |det S|
    xor     r12d, r12d                  # each piece a child of the original
1:  cmp     r12d, [rip+so_npieces]
    jae     2f
    lea     rax, [rip+so_pieces]
    mov     edi, [rax+r12*4]
    call    obj_get
    test    rax, rax
    jz      11f
    mov     rdi, rax
    mov     rsi, [rip+so_obj]
    call    par_set
11: inc     r12d
    jmp     1b
2:  xor     eax, eax
    cmp     dword ptr [rip+so_nobodies], 0
    jne     9f
    xor     edi, edi
    call    an_own_g
    test    rax, rax
    jz      .Lbo_full
    mov     rbx, rax
    mov     eax, [rip+so_ffric]         # the defaults, or the original's
    mov     [rsp], eax
    xor     eax, eax
    mov     [rsp+4], eax
    mov     [rsp+8], eax
    mov     [rsp+12], eax
    mov     [rsp+16], rax
    mov     [rsp+24], eax
    mov     rax, [rip+so_obj]
    mov     edx, [rax+OB_UID]
    xor     ecx, ecx
3:  cmp     ecx, [rbx+AN_NRB_]
    jae     4f
    imul    rax, rcx, RB_SZ_
    lea     rax, [rbx+AN_RB_+rax]
    cmp     [rax+RB_UID], edx
    je      31f
    inc     ecx
    jmp     3b
31: mov     ecx, [rax+RB_FRIC]
    mov     [rsp], ecx
    mov     ecx, [rax+RB_REST]
    mov     [rsp+4], ecx
    mov     ecx, [rax+RB_DAMP]
    mov     [rsp+8], ecx
    mov     ecx, [rax+RB_FLAGS]
    and     ecx, ~3
    mov     [rsp+12], ecx
    mov     rcx, [rax+RB_VEL]
    mov     [rsp+16], rcx
    mov     ecx, [rax+RB_VEL+8]
    mov     [rsp+24], ecx
4:  movss   xmm0, [rip+so_density]      # the density (kg/m^3)
    xorps   xmm1, xmm1
    comiss  xmm0, xmm1
    ja      43f
    movss   xmm0, [rip+so_f1000]
    mov     rdi, [rip+so_obj]
    call    mat_of
    test    eax, eax
    js      42f
    mov     edi, eax
    call    mat_get
    test    rax, rax
    jz      42f
    movss   xmm0, [rax+MA_DENS_]
    xorps   xmm1, xmm1
    comiss  xmm0, xmm1
    jbe     41f
    mulss   xmm0, [rip+so_f1000]
    jmp     43f
41: movss   xmm0, [rip+so_f1000]
    jmp     43f
42: movss   xmm0, [rip+so_f1000]
43: cvtss2sd xmm0, xmm0
    movsd   [rsp+32], xmm0
    mov     rax, [rip+so_obj]           # |det S| (local volume -> world)
    cvtss2sd xmm0, [rax+OB_SCALE]
    cvtss2sd xmm1, [rax+OB_SCALE+4]
    mulsd   xmm0, xmm1
    cvtss2sd xmm1, [rax+OB_SCALE+8]
    mulsd   xmm0, xmm1
    andpd   xmm0, [rip+so_abs]
    movsd   [rsp+40], xmm0
    xorpd   xmm0, xmm0
    movsd   [rsp+48], xmm0              # (the mass in all)
    xor     r12d, r12d                  # each piece: an entry
    xor     r13d, r13d                  # (made)
5:  cmp     r12d, [rip+so_npieces]
    jae     8f
    mov     eax, [rbx+AN_NRB_]
    cmp     eax, RB_MAX_
    jae     .Lbo_room
    lea     rcx, [rip+so_pieces]
    mov     edi, [rcx+r12*4]
    call    obj_get
    test    rax, rax
    jz      7f
    mov     r14d, [rax+OB_UID]
    mov     eax, [rbx+AN_NRB_]
    inc     dword ptr [rbx+AN_NRB_]
    imul    rdi, rax, RB_SZ_
    lea     r15, [rbx+AN_RB_+rdi]
    mov     rdi, r15
    xor     eax, eax
    mov     ecx, RB_SZ_
    rep     stosb
    mov     [r15+RB_UID], r14d
    mov     dword ptr [r15+RB_TYPE], 1
    mov     dword ptr [r15+RB_SHAPE], 3 # a hull; a ball: a sphere
    cmp     dword ptr [rip+so_pat], 2
    jne     51f
    mov     dword ptr [r15+RB_SHAPE], 1
51: lea     rcx, [rip+so_pvol]
    movsd   xmm0, [rcx+r12*8]
    andpd   xmm0, [rip+so_abs]
    cmp     dword ptr [rip+so_pat], 2   # (balls: the volume is the world's
    je      52f                         #  radius already, its scale given)
    mulsd   xmm0, [rsp+40]
    jmp     53f
52: mov     rcx, [rip+so_obj]           # (the ball's local volume x the mean
    cvtss2sd xmm1, [rip+so_meanscale]   #  scale cubed)
    mulsd   xmm0, xmm1
    mulsd   xmm0, xmm1
    mulsd   xmm0, xmm1
53: mulsd   xmm0, [rsp+32]
    movsd   xmm1, [rsp+48]
    addsd   xmm1, xmm0
    movsd   [rsp+48], xmm1
    cvtsd2ss xmm0, xmm0
    movss   [r15+RB_MASS], xmm0
    mov     eax, [rsp]
    mov     [r15+RB_FRIC], eax
    mov     eax, [rsp+4]
    mov     [r15+RB_REST], eax
    mov     eax, [rsp+8]
    mov     [r15+RB_DAMP], eax
    mov     eax, [rsp+12]
    mov     [r15+RB_FLAGS], eax
    mov     rax, [rsp+16]
    mov     [r15+RB_VEL], rax
    mov     eax, [rsp+24]
    mov     [r15+RB_VEL+8], eax
    cmp     dword ptr [rip+so_impactset], 0 # on impact: waiting for the
    je      71f                         #  original to break (hidden)
    or      dword ptr [r15+RB_FLAGS], 8
    lea     rcx, [rip+so_pieces]
    mov     edi, [rcx+r12*4]
    call    obj_get
    or      dword ptr [rax+OB_FLAGS], OBF_HIDDEN
    and     dword ptr [rax+OB_FLAGS], ~OBF_SELECTED
71: inc     r13d
7:  inc     r12d
    jmp     5b
.Lbo_room:
    lea     rdi, [rip+s_sh_room]
    call    log_line
8:  cmp     dword ptr [rip+so_impactset], 0 # on impact: the original a
    je      81f                         #  body (a hull, if it is not one) and
    mov     rdi, rbx                    #  the marker joint
    lea     rsi, [rsp]
    movsd   xmm0, [rsp+32]
    movsd   xmm1, [rsp+40]
    call    so_impact_marks
81: lea     rax, [rip+sh_stat]
    cvtsi2sd xmm0, r13d
    movsd   [rax+22*8], xmm0
    movsd   xmm0, [rsp+48]
    movsd   [rax+21*8], xmm0
    mov     eax, r13d
    jmp     9f
.Lbo_full:
    lea     rdi, [rip+s_sh_room]
    call    log_line
    xor     eax, eax
9:  add     rsp, 64
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# -----------------------------------------------------------------------------
# Glue: pieces that share a face are tied by a fixed joint that breaks at
#   the glue's strength x the face's area (N/m^2 x m^2). Each piece's cut
#   faces are grouped by their plane's tag (a Voronoi face: the pair of
#   cells; a brick's: its joint): two groups with one tag, facing each other
#   and overlapping, are a shared face; its area is the smaller one, or the
#   overlap of their bounds (bricks over two rows). Weaker towards the
#   impact point (at, cursor: down to a fifth at it), or painted: the
#   vertex colours' brightness nearest the face.
# -----------------------------------------------------------------------------
.equ GR_PIECE,  0                       # a group: the piece (so_pieces index),
.equ GR_TAG,    4                       #  the tag,
.equ GR_AREA,   8                       #  area (local),
.equ GR_C,      16                      #  area x centre (3 doubles),
.equ GR_N,      40                      #  area x normal,
.equ GR_MIN,    64                      #  bounds
.equ GR_MAX,    88
.equ GR_SZ,     112

# so_groups_alloc(edi=polygons at most) -> eax = 1
so_groups_alloc:
    push    rbx
    mov     ebx, edi
    mov     rdi, [rip+so_grp]
    mov     rsi, [rip+so_grpsz]
    call    sh_unmap_g
    mov     dword ptr [rip+so_ngrp], 0
    mov     [rip+so_grpcap], ebx
    imul    rsi, rbx, GR_SZ
    add     rsi, GR_SZ
    mov     [rip+so_grpsz], rsi
    call    sh_map_g
    mov     [rip+so_grp], rax
    test    rax, rax
    setnz   al
    movzx   eax, al
    pop     rbx
    ret

# so_groups(rbx=piece header, edi=its index in so_pieces) - its cut faces'
#   groups by tag
so_groups:
    push    rbp
    mov     rbp, rsp
    push    r12
    push    r13
    push    r14
    push    r15
    sub     rsp, 64
    and     rsp, -16
    mov     [rsp+56], edi
    cmp     qword ptr [rip+so_grp], 0
    je      9f
    mov     eax, [rip+so_ngrp]          # (this piece's groups from here)
    mov     [rsp+60], eax
    lea     r12, [rbx+PH_SZ]            # vertices (floats from the centre)
    mov     eax, [rbx+PH_NV]
    imul    eax, eax, 12
    lea     r13, [r12+rax]              # polygon records
    mov     eax, [rbx+PH_NP]
    lea     r14, [r13+rax*8]            # loops
    xor     r15d, r15d
1:  cmp     r15d, [rbx+PH_NP]
    jae     9f
    mov     eax, [r13+r15*8+4]          # tag
    test    eax, eax
    jz      8f
    mov     ecx, [rsp+60]               # its group in this piece, or a new one
2:  cmp     ecx, [rip+so_ngrp]
    jae     3f
    imul    rdx, rcx, GR_SZ
    add     rdx, [rip+so_grp]
    cmp     [rdx+GR_TAG], eax
    je      4f
    inc     ecx
    jmp     2b
3:  cmp     ecx, [rip+so_grpcap]
    jae     8f
    inc     dword ptr [rip+so_ngrp]
    imul    rdx, rcx, GR_SZ
    add     rdx, [rip+so_grp]
    push    rdx
    push    rax
    mov     rdi, rdx
    xor     eax, eax
    mov     ecx, GR_SZ/8
    rep     stosq
    pop     rax
    pop     rdx
    mov     [rdx+GR_TAG], eax
    mov     ecx, [rsp+56]
    mov     [rdx+GR_PIECE], ecx
    movsd   xmm0, [rip+so_big]
    xorpd   xmm1, xmm1
    subsd   xmm1, xmm0
    movsd   [rdx+GR_MIN], xmm0
    movsd   [rdx+GR_MIN+8], xmm0
    movsd   [rdx+GR_MIN+16], xmm0
    movsd   [rdx+GR_MAX], xmm1
    movsd   [rdx+GR_MAX+8], xmm1
    movsd   [rdx+GR_MAX+16], xmm1
4:  mov     [rsp+48], rdx               # the polygon into it: a fan
    mov     ecx, [r13+r15*8]            # (its first loop: r14 now)
    mov     [rsp+40], ecx
    mov     eax, [r14]                  # p0
    call    gp_vert
    movsd   [rsp], xmm0
    movsd   [rsp+8], xmm1
    movsd   [rsp+16], xmm2
    mov     r8d, 1
5:  lea     eax, [r8+1]
    cmp     eax, [rsp+40]
    jae     7f
    push    r8
    sub     rsp, 8
    mov     eax, [r14+r8*4]
    call    gp_vert
    movsd   xmm3, xmm0                  # a = p1 - p0
    subsd   xmm3, [rsp+16]
    movsd   xmm4, xmm1
    subsd   xmm4, [rsp+24]
    movsd   xmm5, xmm2
    subsd   xmm5, [rsp+32]
    mov     r8, [rsp+8]
    mov     eax, [r14+r8*4+4]
    call    gp_vert
    subsd   xmm0, [rsp+16]              # b = p2 - p0
    subsd   xmm1, [rsp+24]
    subsd   xmm2, [rsp+32]
    movsd   xmm6, xmm4                  # n = a x b (twice the area)
    mulsd   xmm6, xmm2
    movsd   xmm7, xmm5
    mulsd   xmm7, xmm1
    subsd   xmm6, xmm7
    movsd   xmm7, xmm5
    mulsd   xmm7, xmm0
    movsd   xmm8, xmm3
    mulsd   xmm8, xmm2
    subsd   xmm7, xmm8
    movsd   xmm8, xmm3
    mulsd   xmm8, xmm1
    movsd   xmm9, xmm4
    mulsd   xmm9, xmm0
    subsd   xmm8, xmm9
    mov     rdx, [rsp+16+48]
    movsd   xmm9, [rdx+GR_N]
    addsd   xmm9, xmm6
    movsd   [rdx+GR_N], xmm9
    movsd   xmm9, [rdx+GR_N+8]
    addsd   xmm9, xmm7
    movsd   [rdx+GR_N+8], xmm9
    movsd   xmm9, [rdx+GR_N+16]
    addsd   xmm9, xmm8
    movsd   [rdx+GR_N+16], xmm9
    mulsd   xmm6, xmm6                  # area = |n| / 2
    mulsd   xmm7, xmm7
    addsd   xmm6, xmm7
    mulsd   xmm8, xmm8
    addsd   xmm6, xmm8
    sqrtsd  xmm6, xmm6
    mulsd   xmm6, [rip+so_half]
    movsd   xmm7, [rdx+GR_AREA]
    addsd   xmm7, xmm6
    movsd   [rdx+GR_AREA], xmm7
    addsd   xmm0, xmm3                  # centre x 3 - 3 p0 = a + b
    addsd   xmm1, xmm4
    addsd   xmm2, xmm5
    mulsd   xmm0, [rip+so_third_d]
    mulsd   xmm1, [rip+so_third_d]
    mulsd   xmm2, [rip+so_third_d]
    addsd   xmm0, [rsp+16]
    addsd   xmm1, [rsp+24]
    addsd   xmm2, [rsp+32]
    mulsd   xmm0, xmm6
    mulsd   xmm1, xmm6
    mulsd   xmm2, xmm6
    addsd   xmm0, [rdx+GR_C]
    movsd   [rdx+GR_C], xmm0
    addsd   xmm1, [rdx+GR_C+8]
    movsd   [rdx+GR_C+8], xmm1
    addsd   xmm2, [rdx+GR_C+16]
    movsd   [rdx+GR_C+16], xmm2
    add     rsp, 8
    pop     r8
    inc     r8d
    jmp     5b
7:  mov     rdx, [rsp+48]               # its corners in the bounds
    xor     r8d, r8d
71: cmp     r8d, [rsp+40]
    jae     8f
    mov     eax, [r14+r8*4]
    call    gp_vert
    minsd   xmm3, xmm0
    movsd   xmm3, [rdx+GR_MIN]
    minsd   xmm3, xmm0
    movsd   [rdx+GR_MIN], xmm3
    movsd   xmm3, [rdx+GR_MIN+8]
    minsd   xmm3, xmm1
    movsd   [rdx+GR_MIN+8], xmm3
    movsd   xmm3, [rdx+GR_MIN+16]
    minsd   xmm3, xmm2
    movsd   [rdx+GR_MIN+16], xmm3
    movsd   xmm3, [rdx+GR_MAX]
    maxsd   xmm3, xmm0
    movsd   [rdx+GR_MAX], xmm3
    movsd   xmm3, [rdx+GR_MAX+8]
    maxsd   xmm3, xmm1
    movsd   [rdx+GR_MAX+8], xmm3
    movsd   xmm3, [rdx+GR_MAX+16]
    maxsd   xmm3, xmm2
    movsd   [rdx+GR_MAX+16], xmm3
    inc     r8d
    jmp     71b
8:  mov     eax, [r13+r15*8]            # the next polygon's loops
    lea     r14, [r14+rax*4]
    inc     r15d
    jmp     1b
9:  lea     rsp, [rbp-32]
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbp
    ret

# gp_vert(eax=vertex; r12 = the piece's vertices, rbx = its header) ->
#   xmm0-2: its place in the object (doubles)
gp_vert:
    imul    rax, rax, 12
    cvtss2sd xmm0, [r12+rax]
    cvtss2sd xmm1, [r12+rax+4]
    cvtss2sd xmm2, [r12+rax+8]
    addsd   xmm0, [rbx+PH_C]
    addsd   xmm1, [rbx+PH_C+8]
    addsd   xmm2, [rbx+PH_C+16]
    ret

# so_glue -> eax = glue joints made (so_glue: the strength, N/m^2)
so_glue:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    push    rbp
    sub     rsp, 200
    xor     eax, eax
    mov     [rsp+192], eax              # (made)
    movss   xmm0, [rip+so_gluef]
    xorps   xmm1, xmm1
    comiss  xmm0, xmm1
    jbe     .Lgl_out
    cmp     dword ptr [rip+so_nobodies], 0
    jne     .Lgl_out
    mov     ebx, [rip+so_ngrp]
    cmp     ebx, 2
    jb      .Lgl_out
    mov     rsi, rbx                    # the groups by tag (sort keys)
    shl     rsi, 3
    mov     [rsp+184], rsi
    call    sh_map_g
    test    rax, rax
    jz      .Lgl_out
    mov     [rsp+176], rax
    xor     ecx, ecx
1:  cmp     ecx, ebx
    jae     2f
    imul    rdx, rcx, GR_SZ
    add     rdx, [rip+so_grp]
    mov     edi, [rdx+GR_TAG]           # the centre and normal over the area
    shl     rdi, 32
    or      rdi, rcx
    mov     [rax+rcx*8], rdi
    movsd   xmm0, [rdx+GR_AREA]
    maxsd   xmm0, [rip+so_tiny]
    xor     r8d, r8d
11: movsd   xmm1, [rdx+GR_C+r8*8]
    divsd   xmm1, xmm0
    movsd   [rdx+GR_C+r8*8], xmm1
    inc     r8d
    cmp     r8d, 3
    jb      11b
    inc     ecx
    jmp     1b
2:  mov     rdi, rax
    mov     esi, ebx
    call    sort_u64
    xor     edi, edi
    call    an_own_g
    test    rax, rax
    jz      .Lgl_free
    mov     [rip+so_anim], rax          # (the anim block)
    call    so_gap_tol                  # (faces this far apart still meet)
    movsd   [rip+so_gtol], xmm0
    xor     r12d, r12d                  # runs of one tag: each pair
3:  cmp     r12d, ebx
    jae     .Lgl_free
    mov     rax, [rsp+176]
    mov     rdx, [rax+r12*8]
    shr     rdx, 32
    lea     r13d, [r12+1]               # the run's end
31: cmp     r13d, ebx
    jae     32f
    mov     rcx, [rax+r13*8]
    shr     rcx, 32
    cmp     rcx, rdx
    jne     32f
    inc     r13d
    jmp     31b
32: mov     r14d, r12d
4:  cmp     r14d, r13d
    jae     7f
    lea     r15d, [r14+1]
5:  cmp     r15d, r13d
    jae     6f
    mov     rax, [rsp+176]
    mov     edi, [rax+r14*8]
    mov     esi, [rax+r15*8]
    lea     rdx, [rsp]
    call    gl_meet
    test    eax, eax
    jz      51f
    lea     rdi, [rsp]
    call    gl_joint
    add     [rsp+192], eax
51: inc     r15d
    jmp     5b
6:  inc     r14d
    jmp     4b
7:  mov     r12d, r13d
    jmp     3b
.Lgl_free:
    mov     rdi, [rsp+176]
    mov     rsi, [rsp+184]
    call    sh_unmap_g
.Lgl_out:
    mov     eax, [rsp+192]
    lea     rcx, [rip+sh_stat]
    cvtsi2sd xmm0, eax
    movsd   [rcx+7*8], xmm0
    add     rsp, 200
    pop     rbp
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# so_gap_tol -> xmm0: how far apart two faces of a joint can be (the gap's
#   largest local reach + a hair of the size)
so_gap_tol:
    call    so_diag
    mulsd   xmm0, [rip+so_1em6]
    mov     rax, [rip+so_obj]
    cvtss2sd xmm1, [rip+so_gap]
    xor     ecx, ecx
1:  cvtss2sd xmm2, [rax+OB_SCALE+rcx*4]
    andpd   xmm2, [rip+so_abs]
    maxsd   xmm2, [rip+so_tiny]
    movsd   xmm3, xmm1
    divsd   xmm3, xmm2
    addsd   xmm3, xmm0
    maxsd   xmm0, xmm3
    inc     ecx
    cmp     ecx, 3
    jb      1b
    addsd   xmm0, [rip+so_1em6]
    ret

# gl_meet(edi, esi = groups, rdx=out: area (double), pivot (3 doubles,
#   local), pieces (2 u32)) -> eax = 1 when they are one face from two
#   pieces: facing each other, their bounds overlapping (a hair apart at
#   most, along the normal: the gap)
gl_meet:
    push    rbx
    mov     rbx, rdx
    imul    r8, rdi, GR_SZ
    add     r8, [rip+so_grp]
    imul    r9, rsi, GR_SZ
    add     r9, [rip+so_grp]
    mov     eax, [r8+GR_PIECE]
    cmp     eax, [r9+GR_PIECE]
    je      8f
    mov     [rbx+32], eax
    mov     eax, [r9+GR_PIECE]
    mov     [rbx+36], eax
    movsd   xmm0, [r8+GR_N]             # n1 . n2 < -0.9 |n1| |n2|
    mulsd   xmm0, [r9+GR_N]
    movsd   xmm1, [r8+GR_N+8]
    mulsd   xmm1, [r9+GR_N+8]
    addsd   xmm0, xmm1
    movsd   xmm1, [r8+GR_N+16]
    mulsd   xmm1, [r9+GR_N+16]
    addsd   xmm0, xmm1
    xorpd   xmm1, xmm1
    comisd  xmm0, xmm1
    jae     8f
    xor     ecx, ecx                    # the overlap: each axis (a gap's worth
    movsd   xmm6, [rip+so_gtol]         #  apart allowed), its area from the
    xorpd   xmm5, xmm5                  #  two widest
    sub     rsp, 32
1:  movsd   xmm0, [r8+GR_MAX+rcx*8]
    minsd   xmm0, [r9+GR_MAX+rcx*8]
    movsd   xmm1, [r8+GR_MIN+rcx*8]
    maxsd   xmm1, [r9+GR_MIN+rcx*8]
    movsd   xmm2, xmm0
    addsd   xmm2, xmm1
    mulsd   xmm2, [rip+so_half]
    movsd   [rbx+8+rcx*8], xmm2         # (the pivot: the overlap's middle)
    subsd   xmm0, xmm1
    movsd   xmm2, xmm6
    xorpd   xmm3, xmm3
    subsd   xmm3, xmm2
    comisd  xmm0, xmm3
    jb      81f
    maxsd   xmm0, xmm5
    movsd   [rsp+rcx*8], xmm0
    inc     ecx
    cmp     ecx, 3
    jb      1b
    movsd   xmm0, [rsp]                 # area: the two largest widths'
    mulsd   xmm0, [rsp+8]               #  product (the largest of the three
    movsd   xmm1, [rsp]                 #  products)
    mulsd   xmm1, [rsp+16]
    maxsd   xmm0, xmm1
    movsd   xmm1, [rsp+8]
    mulsd   xmm1, [rsp+16]
    maxsd   xmm0, xmm1
    add     rsp, 32
    movsd   xmm1, [r8+GR_AREA]          # and no more than either face
    minsd   xmm1, [r9+GR_AREA]
    minsd   xmm0, xmm1
    comisd  xmm0, [rip+so_tiny]
    jbe     8f
    movsd   [rbx], xmm0
    mov     eax, 1
    pop     rbx
    ret
81: add     rsp, 32
8:  xor     eax, eax
    pop     rbx
    ret

# gl_joint(rdi=gl_meet's result) -> eax = 1: a fixed joint between the two
#   pieces at the face, breaking at the strength x the area (x the falloff)
gl_joint:
    push    rbx
    push    r12
    push    r13
    sub     rsp, 48
    mov     rbx, rdi
    mov     r12, [rip+so_anim]
    mov     eax, [r12+AN_NJT_]
    cmp     eax, JT_MAX_
    jae     8f
    lea     rcx, [rip+so_pieces]        # the two objects' uids
    mov     eax, [rbx+32]
    mov     edi, [rcx+rax*4]
    call    obj_get
    test    rax, rax
    jz      8f
    mov     r13d, [rax+OB_UID]
    lea     rcx, [rip+so_pieces]
    mov     eax, [rbx+36]
    mov     edi, [rcx+rax*4]
    call    obj_get
    test    rax, rax
    jz      8f
    mov     eax, [rax+OB_UID]
    mov     [rsp], eax
    mov     eax, [r12+AN_NJT_]          # the entry
    inc     dword ptr [r12+AN_NJT_]
    imul    rdi, rax, JT_SZ_
    lea     r12, [r12+AN_JT_+rdi]
    mov     rdi, r12
    xor     eax, eax
    mov     ecx, JT_SZ_
    rep     stosb
    mov     dword ptr [r12+JT_TYPE], 1
    mov     [r12+JT_A], r13d
    mov     eax, [rsp]
    mov     [r12+JT_B], eax
    mov     eax, [rip+so_f1]            # (axis: Y)
    mov     [r12+JT_AXIS+4], eax
    lea     rax, [rip+so_mat]           # pivot = M p
    xor     ecx, ecx
1:  movss   xmm0, [rax+12]
    xor     edx, edx
2:  cvtsd2ss xmm1, [rbx+8+rdx*8]
    mulss   xmm1, [rax+rdx*4]
    addss   xmm0, xmm1
    inc     edx
    cmp     edx, 3
    jb      2b
    movss   [r12+JT_PIV+rcx*4], xmm0
    add     rax, 16
    inc     ecx
    cmp     ecx, 3
    jb      1b
    mov     rax, [rip+so_obj]           # area in the world: x |det S|^(2/3)
    cvtss2sd xmm0, [rax+OB_SCALE]
    cvtss2sd xmm1, [rax+OB_SCALE+4]
    mulsd   xmm0, xmm1
    cvtss2sd xmm1, [rax+OB_SCALE+8]
    mulsd   xmm0, xmm1
    andpd   xmm0, [rip+so_abs]
    call    so_cbrt
    mulsd   xmm0, xmm0
    mulsd   xmm0, [rbx]
    cvtss2sd xmm1, [rip+so_gluef]
    mulsd   xmm0, xmm1
    movsd   [rsp+8], xmm0
    cmp     dword ptr [rip+so_atmode], 1 # weaker near the impact point: the
    jne     3f                          #  distance / (spread x size), 0.2 - 1
    xorpd   xmm0, xmm0
    xor     ecx, ecx
21: movsd   xmm1, [rbx+8+rcx*8]
    lea     rax, [rip+so_at]
    subsd   xmm1, [rax+rcx*8]
    mulsd   xmm1, xmm1
    addsd   xmm0, xmm1
    inc     ecx
    cmp     ecx, 3
    jb      21b
    sqrtsd  xmm0, xmm0
    movsd   [rsp+16], xmm0
    call    so_diag
    cvtss2sd xmm1, [rip+so_spread]
    mulsd   xmm0, xmm1
    maxsd   xmm0, [rip+so_tiny]
    movsd   xmm1, [rsp+16]
    divsd   xmm1, xmm0
    maxsd   xmm1, [rip+so_02]
    minsd   xmm1, [rip+so_one]
    mulsd   xmm1, [rsp+8]
    movsd   [rsp+8], xmm1
3:  cmp     dword ptr [rip+so_gluepaint], 0 # painted: the brightness nearest
    je      4f                          #  the face
    lea     rdi, [rbx+8]
    call    so_near_colour
    test    eax, eax
    jz      4f
    xor     ecx, ecx                    # (r + g + b) / 765
    xor     eax, eax
31: movzx   r8d, dl
    add     eax, r8d
    shr     edx, 8
    inc     ecx
    cmp     ecx, 3
    jb      31b
    cvtsi2sd xmm0, eax
    divsd   xmm0, [rip+so_765]
    mulsd   xmm0, [rsp+8]
    movsd   [rsp+8], xmm0
4:  cvtsd2ss xmm0, [rsp+8]
    movss   xmm1, [rip+so_fmin]         # (never 0: that would be unbreakable)
    maxss   xmm0, xmm1
    movss   [r12+JT_BRK], xmm0
    mov     eax, 1
    jmp     9f
8:  xor     eax, eax
9:  add     rsp, 48
    pop     r13
    pop     r12
    pop     rbx
    ret

# so_impact_marks(rdi=anim block, rsi=the defaults (friction, bounce,
#   damping, flags, velocity), xmm0=density, xmm1=|det S|) - the original
#   an active body (as it is; else a hull of its volume x the density) and
#   a marker joint: type 5, the original, the blow it breaks at
so_impact_marks:
    push    rbx
    push    r12
    push    r13
    sub     rsp, 16
    mov     rbx, rdi
    mov     r12, rsi
    movsd   [rsp], xmm0
    movsd   [rsp+8], xmm1
    mov     rax, [rip+so_obj]
    mov     edx, [rax+OB_UID]
    xor     ecx, ecx                    # its entry
1:  cmp     ecx, [rbx+AN_NRB_]
    jae     2f
    imul    rax, rcx, RB_SZ_
    lea     rax, [rbx+AN_RB_+rax]
    cmp     [rax+RB_UID], edx
    je      3f
    inc     ecx
    jmp     1b
3:  mov     r13, rax
    jmp     4f
2:  mov     eax, [rbx+AN_NRB_]          # none: an active hull
    cmp     eax, RB_MAX_
    jae     9f
    inc     dword ptr [rbx+AN_NRB_]
    imul    rdi, rax, RB_SZ_
    lea     r13, [rbx+AN_RB_+rdi]
    mov     rdi, r13
    xor     eax, eax
    mov     ecx, RB_SZ_
    rep     stosb
    mov     rax, [rip+so_obj]
    mov     eax, [rax+OB_UID]
    mov     [r13+RB_UID], eax
    mov     dword ptr [r13+RB_TYPE], 1
    mov     dword ptr [r13+RB_SHAPE], 3
    movsd   xmm0, [rip+sh_src_vol]
    andpd   xmm0, [rip+so_abs]
    mulsd   xmm0, [rsp+8]
    mulsd   xmm0, [rsp]
    cvtsd2ss xmm0, xmm0
    movss   [r13+RB_MASS], xmm0
    mov     eax, [r12]
    mov     [r13+RB_FRIC], eax
    mov     eax, [r12+4]
    mov     [r13+RB_REST], eax
4:  or      dword ptr [r13+RB_FLAGS], 4 # (it breaks on impact: a body
    mov     eax, [rbx+AN_NJT_]          #  even hidden) the marker
    cmp     eax, JT_MAX_
    jae     9f
    inc     dword ptr [rbx+AN_NJT_]
    imul    rdi, rax, JT_SZ_
    lea     r13, [rbx+AN_JT_+rdi]
    mov     rdi, r13
    xor     eax, eax
    mov     ecx, JT_SZ_
    rep     stosb
    mov     dword ptr [r13+JT_TYPE], 5
    mov     rax, [rip+so_obj]
    mov     eax, [rax+OB_UID]
    mov     [r13+JT_A], eax
    mov     eax, [rip+so_impact]
    mov     [r13+JT_BRK], eax
9:  add     rsp, 16
    pop     r13
    pop     r12
    pop     rbx
    ret

# so_unshatter(rdi=a piece or an original) -> rax = the original, whole
#   again: shown, selected, active; its pieces (its children), their bodies
#   and joints and its marker gone
so_unshatter:
    push    rbx
    push    r12
    push    r13
    push    r14
    sub     rsp, 8
    mov     rbx, rdi
    call    par_of                      # a piece: its parent is the original
    test    rax, rax
    jz      1f
    mov     rbx, rax
1:  xor     edi, edi
    call    an_own_g
    mov     r12, rax
    test    r12, r12
    jz      5f
    mov     ecx, [r12+AN_NRB_]          # bodies of its children go (the last
2:  test    ecx, ecx                    #  into each one's place)
    jz      3f
    dec     ecx
    imul    rax, rcx, RB_SZ_
    lea     r13, [r12+AN_RB_+rax]
    push    rcx
    push    rcx
    mov     edi, [r13+RB_UID]
    call    so_is_piece
    pop     rcx
    pop     rcx
    test    eax, eax
    jz      2b
    mov     eax, [r12+AN_NRB_]
    dec     eax
    mov     [r12+AN_NRB_], eax
    imul    rsi, rax, RB_SZ_
    lea     rsi, [r12+AN_RB_+rsi]
    mov     rdi, r13
    push    rcx
    mov     ecx, RB_SZ_
    rep     movsb
    pop     rcx
    jmp     2b
3:  mov     ecx, [r12+AN_NJT_]          # joints of them, and its marker
31: test    ecx, ecx
    jz      5f
    dec     ecx
    imul    rax, rcx, JT_SZ_
    lea     r13, [r12+AN_JT_+rax]
    mov     eax, [rbx+OB_UID]
    cmp     dword ptr [r13+JT_TYPE], 5
    jne     32f
    cmp     [r13+JT_A], eax
    je      34f
32: push    rcx
    push    rcx
    mov     edi, [r13+JT_A]
    call    so_is_piece
    mov     r14d, eax
    mov     edi, [r13+JT_B]
    call    so_is_piece
    or      eax, r14d
    pop     rcx
    pop     rcx
    test    eax, eax
    jz      31b
34: mov     eax, [r12+AN_NJT_]
    dec     eax
    mov     [r12+AN_NJT_], eax
    imul    rsi, rax, JT_SZ_
    lea     rsi, [r12+AN_JT_+rsi]
    mov     rdi, r13
    push    rcx
    mov     ecx, JT_SZ_
    rep     movsb
    pop     rcx
    jmp     31b
5:  mov     ecx, [rip+obj_count]        # the children themselves
51: test    ecx, ecx
    jz      6f
    dec     ecx
    push    rcx
    push    rcx
    mov     edi, ecx
    call    obj_at
    mov     rdi, rax
    call    par_of
    pop     rcx
    pop     rcx
    cmp     rax, rbx
    jne     51b
    push    rcx
    push    rcx
    mov     edi, ecx
    call    obj_remove_at
    pop     rcx
    pop     rcx
    jmp     51b
6:  and     dword ptr [rbx+OB_FLAGS], ~OBF_HIDDEN  # the original
    or      dword ptr [rbx+OB_FLAGS], OBF_SELECTED
    xor     ecx, ecx                    # (its handle: active)
61: cmp     ecx, [rip+obj_count]
    jae     7f
    push    rcx
    push    rcx
    mov     edi, ecx
    call    obj_at
    pop     rcx
    pop     rcx
    cmp     rax, rbx
    je      62f
    inc     ecx
    jmp     61b
62: lea     rax, [rip+obj_list]
    mov     eax, [rax+rcx*4]
    mov     [rip+active_obj], eax
7:  mov     rax, rbx
    add     rsp, 8
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# so_is_piece(edi=uid; rbx = the original) -> eax = 1: a child of it
so_is_piece:
    sub     rsp, 8
    call    obj_by_uid
    test    rax, rax
    jz      8f
    mov     rdi, rax
    call    par_of
    cmp     rax, rbx
    jne     8f
    mov     eax, 1
    add     rsp, 8
    ret
8:  xor     eax, eax
    add     rsp, 8
    ret

# so_build -> eax = pieces made: every cell's pieces into objects; the
#   stats
so_build:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    sub     rsp, 16
    xor     r15d, r15d                  # pieces
    mov     dword ptr [rip+so_first], 0
    xor     edi, edi                    # (room for the faces' groups: a
    xor     ecx, ecx                    #  polygon each at most)
91: cmp     ecx, [rip+sh_nres]
    jae     93f
    mov     rax, [rip+sh_res]
    mov     rdx, rcx
    shl     rdx, 4
    mov     rsi, [rax+rdx]
    test    rsi, rsi
    jz      92f
    mov     r8d, [rsi]
    add     rsi, PP_HDR
921:test    r8d, r8d
    jz      92f
    add     edi, [rsi+PH_NP]
    push    rdi
    push    rcx
    push    r8
    call    so_piece_next
    pop     r8
    pop     rcx
    pop     rdi
    mov     rsi, rax
    dec     r8d
    jmp     921b
92: inc     ecx
    jmp     91b
93: call    so_groups_alloc
    lea     rax, [rip+sh_stat]
    xorpd   xmm0, xmm0
    movsd   [rax+2*8], xmm0
    movsd   [rax+5*8], xmm0
    movsd   xmm0, [rip+sh_src_vol]
    movsd   [rax+3*8], xmm0
    movsd   [rax+4*8], xmm0
    xor     r12d, r12d                  # cell
1:  cmp     r12d, [rip+sh_nres]
    jae     8f
    mov     rax, [rip+sh_res]
    mov     rcx, r12
    shl     rcx, 4
    mov     rbx, [rax+rcx]
    test    rbx, rbx
    jz      7f
    mov     r13d, [rbx]                 # its pieces
    add     rbx, PP_HDR
2:  test    r13d, r13d
    jz      7f
    lea     rax, [rip+sh_stat]          # volumes
    movsd   xmm0, [rbx+PH_VOL]
    movsd   xmm1, [rax+2*8]
    addsd   xmm1, xmm0
    movsd   [rax+2*8], xmm1
    minsd   xmm0, [rax+4*8]
    movsd   [rax+4*8], xmm0
    mov     eax, [rbx+PH_NV]            # open edges
    imul    eax, eax, 12
    lea     rdi, [rbx+PH_SZ+rax]
    mov     edx, [rbx+PH_NP]
    lea     rsi, [rdi+rdx*8]
    call    polys_open
    cvtsi2sd xmm0, eax
    lea     rax, [rip+sh_stat]
    addsd   xmm0, [rax+5*8]
    movsd   [rax+5*8], xmm0
    mov     rsi, rbx
    call    so_make
    test    eax, eax
    jz      3f
    push    rax
    push    rax
    mov     edi, [rip+so_npieces]       # (its faces' groups)
    dec     edi
    call    so_groups
    pop     rax
    pop     rax
    inc     r15d
    cmp     dword ptr [rip+so_first], 0
    jne     3f
    mov     [rip+so_first], eax
3:  mov     rsi, rbx                    # the next piece
    call    so_piece_next
    mov     rbx, rax
    dec     r13d
    jmp     2b
7:  inc     r12d
    jmp     1b
8:  lea     rax, [rip+sh_stat]
    cvtsi2sd xmm0, r15d
    movsd   [rax], xmm0
    movsd   xmm0, [rax+2*8]             # 9: |sum - volume| / volume
    subsd   xmm0, [rax+3*8]
    andpd   xmm0, [rip+so_abs]
    movsd   xmm1, [rax+3*8]
    maxsd   xmm1, [rip+so_tiny]
    divsd   xmm0, xmm1
    movsd   [rax+9*8], xmm0
    movsd   xmm0, [rax+4*8]             # 10: the smallest piece / the mean
    mulsd   xmm0, [rax+1*8]
    divsd   xmm0, xmm1
    movsd   [rax+10*8], xmm0
    mov     eax, r15d
    add     rsp, 16
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# so_parse -> eax = 1 when op_arg was understood: the pattern and its
#   options into so_*
so_parse:
    push    rbx
    push    r12
    push    r13
    sub     rsp, 16
    mov     r12, [rip+op_arg]
1:  mov     rsi, r12
    call    im_next_word
    mov     r12, rsi
    test    eax, eax
    jz      7f
    lea     rbx, [rip+so_kws]           # which keyword
    xor     r13d, r13d
2:  mov     rsi, [rbx+r13*8]
    test    rsi, rsi
    jz      8f
    lea     rdi, [rip+im_word]
    call    str_eq
    test    eax, eax
    jnz     3f
    inc     r13d
    jmp     2b
3:  cmp     r13d, 3                     # shards bricks balls
    jae     4f
    mov     [rip+so_pat], r13d
    jmp     1b
4:  lea     rax, [rip+so_kwfn]
    jmp     [rax+r13*8-24]
.Lpa_count:
    mov     dword ptr [rip+so_counted], 1
    call    pa_num
    jz      8f
    cvttss2si eax, xmm0
    cmp     eax, 1
    jl      8f
    cmp     eax, MAXSEEDS
    jle     5f
    mov     eax, MAXSEEDS
5:  mov     [rip+so_count], eax
    jmp     1b
.Lpa_seed:
    call    pa_num
    jz      8f
    cvttss2si eax, xmm0
    mov     [rip+so_seed], eax
    jmp     1b
.Lpa_at:
    lea     rdi, [rip+so_atw]
    call    pa_vec
    jz      8f
    mov     dword ptr [rip+so_atmode], 1
    jmp     1b
.Lpa_cursor:
    mov     rax, [rip+cursor_pos]
    mov     [rip+so_atw], rax
    mov     eax, [rip+cursor_pos+8]
    mov     [rip+so_atw+8], eax
    mov     dword ptr [rip+so_atmode], 1
    jmp     1b
.Lpa_surface:
    mov     dword ptr [rip+so_atmode], 2
    jmp     1b
.Lpa_spread:
    call    pa_num
    jz      8f
    movss   [rip+so_spread], xmm0
    mov     dword ptr [rip+so_spreadset], 1
    jmp     1b
.Lpa_size:
    lea     rdi, [rip+so_size]
    call    pa_vec
    jz      8f
    mov     dword ptr [rip+so_hassize], 1
    jmp     1b
.Lpa_counts:
    lea     rdi, [rip+so_tmp3]
    call    pa_vec
    jz      8f
    xor     ecx, ecx
6:  lea     rax, [rip+so_tmp3]
    cvttss2si eax, [rax+rcx*4]
    cmp     eax, 1
    jge     61f
    mov     eax, 1
61: cmp     eax, 4096
    jle     62f
    mov     eax, 4096
62: lea     rdx, [rip+so_counts]
    mov     [rdx+rcx*4], eax
    inc     ecx
    cmp     ecx, 3
    jb      6b
    mov     dword ptr [rip+so_hascounts], 1
    jmp     1b
.Lpa_offset:
    mov     rsi, r12                    # a number, or "random"
    call    im_next_word
    test    eax, eax
    jz      8f
    mov     r12, rsi
    mov     [rsp], eax
    lea     rdi, [rip+im_word]
    lea     rsi, [rip+k_random]
    call    str_eq
    test    eax, eax
    jz      63f
    mov     dword ptr [rip+so_offrand], 1
    jmp     1b
63: lea     rsi, [rip+im_word]
    mov     eax, [rsp]
    lea     rdx, [rsi+rax]
    call    parse_float
    test    eax, eax
    jz      8f
    movss   [rip+so_offset], xmm0
    mov     dword ptr [rip+so_offrand], 0
    jmp     1b
.Lpa_gap:
    call    pa_num
    jz      8f
    movss   [rip+so_gap], xmm0
    jmp     1b
.Lpa_jitter:
    call    pa_num
    jz      8f
    movss   [rip+so_jitter], xmm0
    jmp     1b
.Lpa_radius:
    call    pa_num
    jz      8f
    movss   [rip+so_radius], xmm0
    jmp     1b
.Lpa_density:
    call    pa_num
    jz      8f
    movss   [rip+so_density], xmm0
    jmp     1b
.Lpa_glue:
    call    pa_num
    jz      8f
    movss   [rip+so_gluef], xmm0
    jmp     1b
.Lpa_again:
    mov     dword ptr [rip+so_again], 1
    jmp     1b
.Lpa_preset:                            # a preset: its pattern and values
    mov     rsi, r12                    #  (what follows can change them)
    call    im_next_word
    mov     r12, rsi
    test    eax, eax
    jz      8f
    xor     r13d, r13d
91: lea     rax, [rip+so_presets]
    mov     rsi, [rax+r13*8]
    test    rsi, rsi
    jz      8f
    lea     rdi, [rip+im_word]
    call    str_eq
    test    eax, eax
    jnz     92f
    inc     r13d
    jmp     91b
92: mov     [rip+so_preset], r13d
    test    r13d, r13d                  # (none)
    jz      1b
    imul    rax, r13, PS_SZ
    lea     rcx, [rip+so_pdata-PS_SZ]
    add     rcx, rax
    mov     eax, [rcx]
    mov     [rip+so_pat], eax
    mov     eax, [rcx+4]
    mov     [rip+so_count], eax
    xor     edx, edx                    # (bricks: their own rows and
    cmp     dword ptr [rcx], 1          #  columns, not the count)
    setne   dl
    mov     [rip+so_counted], edx
    mov     eax, [rcx+8]
    mov     [rip+so_gluef], eax
    mov     eax, [rcx+12]
    mov     [rip+so_impact], eax
    xor     edx, edx
    test    eax, eax
    setnz   dl
    mov     [rip+so_impactset], edx
    mov     eax, [rcx+16]
    mov     [rip+so_density], eax
    mov     eax, [rcx+20]
    mov     [rip+so_gap], eax
    mov     eax, [rcx+24]
    mov     [rip+so_spread], eax
    mov     eax, [rcx+28]
    mov     [rip+so_spreadset], eax
    mov     eax, [rcx+32]
    mov     [rip+so_counts], eax
    mov     eax, [rcx+36]
    mov     [rip+so_counts+4], eax
    mov     eax, [rcx+40]               # an inner colour
    test    eax, eax
    jz      1b
    mov     [rip+so_innerc], eax
    mov     dword ptr [rip+so_inner], 1
    jmp     1b
.Lpa_impact:
    call    pa_num
    jz      8f
    movss   [rip+so_impact], xmm0
    mov     dword ptr [rip+so_impactset], 1
    jmp     1b
.Lpa_paint:
    mov     dword ptr [rip+so_gluepaint], 1
    jmp     1b
.Lpa_nobodies:
    mov     dword ptr [rip+so_nobodies], 1
    jmp     1b
.Lpa_inner:
    lea     rdi, [rip+so_tmp3]          # r g b (0..1)
    call    pa_vec
    jz      8f
    xor     ecx, ecx
    mov     edx, 0xff
64: lea     rax, [rip+so_tmp3]
    movss   xmm0, [rax+rcx*4]
    maxss   xmm0, [rip+so_f0]
    minss   xmm0, [rip+so_f1]
    mulss   xmm0, [rip+so_f255]
    cvtss2si eax, xmm0
    shl     edx, 8
    or      edx, eax
    inc     ecx
    cmp     ecx, 3
    jb      64b
    mov     [rip+so_innerc], edx
    mov     dword ptr [rip+so_inner], 1
    jmp     1b
7:  mov     eax, 1
    jmp     9f
8:  xor     eax, eax
9:  add     rsp, 16
    pop     r13
    pop     r12
    pop     rbx
    ret

# pa_num(r12=text) -> ZF clear and xmm0 when a number came (r12 past it)
pa_num:
    mov     rsi, r12
    call    so_num
    mov     r12, rsi
    test    eax, eax
    ret

# pa_vec(rdi=3 floats out; r12=text) -> ZF clear when three numbers came
pa_vec:
    push    rbx
    push    r13
    sub     rsp, 8
    mov     rbx, rdi
    xor     r13d, r13d
1:  call    pa_num
    jz      9f
    movss   [rbx+r13*4], xmm0
    inc     r13d
    cmp     r13d, 3
    jb      1b
    test    r13d, r13d                  # (ZF clear)
9:  add     rsp, 8
    pop     r13
    pop     rbx
    ret

# so_defaults - the options before any are given
so_defaults:
    xor     eax, eax
    mov     [rip+so_preset], eax
    mov     [rip+so_pat], eax
    mov     [rip+so_atmode], eax
    mov     [rip+so_hassize], eax
    mov     [rip+so_hascounts], eax
    mov     [rip+so_gap], eax
    mov     [rip+so_jitter], eax
    mov     [rip+so_radius], eax
    mov     [rip+so_inner], eax
    mov     [rip+so_offrand], eax
    mov     [rip+so_spreadset], eax
    mov     [rip+so_counted], eax
    mov     [rip+so_density], eax
    mov     [rip+so_nobodies], eax
    mov     [rip+so_gluef], eax
    mov     [rip+so_gluepaint], eax
    mov     [rip+so_impact], eax
    mov     [rip+so_impactset], eax
    mov     [rip+so_again], eax
    mov     dword ptr [rip+so_count], 50
    mov     dword ptr [rip+so_seed], 1
    mov     eax, [rip+so_fhalf]
    mov     [rip+so_offset], eax
    mov     [rip+so_spread], eax
    mov     dword ptr [rip+so_counts], 8
    mov     dword ptr [rip+so_counts+4], 4
    mov     dword ptr [rip+so_counts+8], 1
    ret

# so_inverse - so_imat (doubles, 3 x 4) = so_mat's inverse (the adjugate
#   over the determinant; t' = -inv t)
so_inverse:
    lea     rsi, [rip+so_mat]
    lea     rdi, [rip+so_imat]
    xor     ecx, ecx                    # the 3x3 in doubles: [rsp]
    sub     rsp, 72
1:  mov     eax, ecx
    xor     edx, edx
    mov     r8d, 3
    div     r8d                         # row eax, column edx
    shl     eax, 4
    lea     eax, [rax+rdx*4]
    cvtss2sd xmm0, [rsi+rax]
    movsd   [rsp+rcx*8], xmm0
    inc     ecx
    cmp     ecx, 9
    jb      1b
    # cofactors: inv[r][c] = cof[c][r] / det, a b c / d e f / g h i
    movsd   xmm0, [rsp+32]              # ei - fh
    mulsd   xmm0, [rsp+64]
    movsd   xmm1, [rsp+40]
    mulsd   xmm1, [rsp+56]
    subsd   xmm0, xmm1
    movsd   [rdi], xmm0
    movsd   xmm0, [rsp+16]              # ch - bi
    mulsd   xmm0, [rsp+56]
    movsd   xmm1, [rsp+8]
    mulsd   xmm1, [rsp+64]
    subsd   xmm0, xmm1
    movsd   [rdi+8], xmm0
    movsd   xmm0, [rsp+8]               # bf - ce
    mulsd   xmm0, [rsp+40]
    movsd   xmm1, [rsp+16]
    mulsd   xmm1, [rsp+32]
    subsd   xmm0, xmm1
    movsd   [rdi+16], xmm0
    movsd   xmm0, [rsp+40]              # fg - di
    mulsd   xmm0, [rsp+48]
    movsd   xmm1, [rsp+24]
    mulsd   xmm1, [rsp+64]
    subsd   xmm0, xmm1
    movsd   [rdi+32], xmm0
    movsd   xmm0, [rsp]                 # ai - cg
    mulsd   xmm0, [rsp+64]
    movsd   xmm1, [rsp+16]
    mulsd   xmm1, [rsp+48]
    subsd   xmm0, xmm1
    movsd   [rdi+40], xmm0
    movsd   xmm0, [rsp+16]              # cd - af
    mulsd   xmm0, [rsp+24]
    movsd   xmm1, [rsp]
    mulsd   xmm1, [rsp+40]
    subsd   xmm0, xmm1
    movsd   [rdi+48], xmm0
    movsd   xmm0, [rsp+24]              # dh - eg
    mulsd   xmm0, [rsp+56]
    movsd   xmm1, [rsp+32]
    mulsd   xmm1, [rsp+48]
    subsd   xmm0, xmm1
    movsd   [rdi+64], xmm0
    movsd   xmm0, [rsp+8]               # bg - ah
    mulsd   xmm0, [rsp+48]
    movsd   xmm1, [rsp]
    mulsd   xmm1, [rsp+56]
    subsd   xmm0, xmm1
    movsd   [rdi+72], xmm0
    movsd   xmm0, [rsp]                 # ae - bd
    mulsd   xmm0, [rsp+32]
    movsd   xmm1, [rsp+8]
    mulsd   xmm1, [rsp+24]
    subsd   xmm0, xmm1
    movsd   [rdi+80], xmm0
    movsd   xmm2, [rsp]                 # det = a A + b D + c G (A = [0],
    mulsd   xmm2, [rdi]                 #  D = [32], G = [64])
    movsd   xmm1, [rsp+8]
    mulsd   xmm1, [rdi+32]
    addsd   xmm2, xmm1
    movsd   xmm1, [rsp+16]
    mulsd   xmm1, [rdi+64]
    addsd   xmm2, xmm1
    movsd   xmm1, xmm2
    andpd   xmm1, [rip+so_abs]
    comisd  xmm1, [rip+so_tiny]
    ja      2f
    movsd   xmm2, [rip+so_one]
2:  movsd   xmm3, [rip+so_one]
    divsd   xmm3, xmm2
    # the stored cofactors are already transposed rows: [rdi] = (A, B?, ..)
    # (rows of the inverse: r0 = (ei-fh, ch-bi, bf-ce), r1, r2 as above)
    xor     ecx, ecx
3:  mov     eax, ecx
    xor     edx, edx
    mov     r8d, 3
    div     r8d
    shl     eax, 5
    lea     eax, [rax+rdx*8]
    movsd   xmm0, [rdi+rax]
    mulsd   xmm0, xmm3
    movsd   [rdi+rax], xmm0
    inc     ecx
    cmp     ecx, 9
    jb      3b
    xor     ecx, ecx                    # t' = -inv t
4:  mov     eax, ecx
    shl     eax, 5
    xorpd   xmm0, xmm0
    xor     edx, edx
41: lea     r9, [rdi+rax]
    movsd   xmm1, [r9+rdx*8]
    mov     r8d, edx
    shl     r8d, 4
    cvtss2sd xmm2, [rsi+r8+12]
    mulsd   xmm1, xmm2
    subsd   xmm0, xmm1
    inc     edx
    cmp     edx, 3
    jb      41b
    movsd   [rdi+rax+24], xmm0
    inc     ecx
    cmp     ecx, 3
    jb      4b
    add     rsp, 72
    ret

# so_tolocal(rsi=3 floats world, rdi=3 doubles out) - by so_imat
so_tolocal:
    lea     rax, [rip+so_imat]
    xor     ecx, ecx
1:  movsd   xmm0, [rax+24]
    xor     edx, edx
2:  cvtss2sd xmm1, [rsi+rdx*4]
    mulsd   xmm1, [rax+rdx*8]
    addsd   xmm0, xmm1
    inc     edx
    cmp     edx, 3
    jb      2b
    movsd   [rdi+rcx*8], xmm0
    add     rax, 32
    inc     ecx
    cmp     ecx, 3
    jb      1b
    ret

# object.shatter <shards|bricks|balls> [options] (so_parse)
do_shatter:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    sub     rsp, 16
    call    so_now
    mov     [rip+so_t0], rax
    mov     qword ptr [rip+so_tlap], 0
    lea     rdi, [rip+sh_cnt]
    xor     eax, eax
    mov     ecx, 8
    rep     stosq
    lea     rdi, [rip+sh_stat]
    xor     eax, eax
    mov     ecx, NSTAT
    rep     stosq
    call    so_defaults
    mov     dword ptr [rip+so_npieces], 0
    call    so_parse
    test    eax, eax
    jz      .Lsh_bad
    mov     edi, [rip+so_pat]           # the Physics panel: these settings
    mov     esi, [rip+so_preset]
    mov     edx, [rip+so_count]
    movss   xmm0, [rip+so_gluef]
    movss   xmm1, [rip+so_impact]
    call    sp_sync
    mov     edi, [rip+active_obj]       # the active mesh
    call    obj_get
    test    rax, rax
    jz      .Lsh_none
    cmp     dword ptr [rax+OB_TYPE], OT_MESH
    jne     .Lsh_none
    cmp     qword ptr [rax+OB_MESH], 0
    je      .Lsh_none
    mov     [rip+so_obj], rax
    cmp     dword ptr [rip+so_again], 0 # again: from the original, its
    je      24f                         #  pieces gone first
    mov     rdi, rax
    call    so_unshatter
    mov     [rip+so_obj], rax
24: mov     rdi, [rip+so_obj]
    call    so_source
    test    eax, eax
    jz      .Lsh_drop
    mov     rdi, [rip+so_obj]
    lea     rsi, [rip+so_mat]
    call    obj_matrix
    call    so_inverse
    cmp     dword ptr [rip+so_atmode], 1  # the impact point, local
    jne     1f
    lea     rsi, [rip+so_atw]
    lea     rdi, [rip+so_at]
    call    so_tolocal
1:  mov     edi, [rip+so_seed]
    call    so_seed_rng
    mov     eax, [rip+so_pat]
    cmp     eax, 1
    je      .Lsh_bricks
    cmp     eax, 2
    je      .Lsh_balls
    cmp     dword ptr [rip+so_atmode], 2  # shards: seeds, Voronoi cells
    jne     2f
    call    so_cdf_make
2:  mov     edi, [rip+so_count]
    call    so_seeds
    push    rax
    push    rax
    mov     edi, 11
    call    so_lap
    pop     rax
    pop     rax
    test    eax, eax
    jz      .Lsh_noseed
    lea     rcx, [rip+sh_stat]
    cvtsi2sd xmm0, eax
    movsd   [rcx+8], xmm0
    mov     dword ptr [rip+sh_mode], 1
    mov     edx, eax
    lea     rsi, [rip+s_sh_cell]
    jmp     .Lsh_cut
.Lsh_bricks:
    call    so_bricks
    test    eax, eax
    jz      .Lsh_mem
    mov     eax, [rip+sh_ncell_used]
    mov     [rip+sh_ncell], eax
    lea     rcx, [rip+sh_stat]
    cvtsi2sd xmm0, eax
    movsd   [rcx+8], xmm0
    mov     dword ptr [rip+sh_mode], 0
    mov     edx, eax
    lea     rsi, [rip+s_sh_brick]
.Lsh_cut:
    push    rdx
    push    rdx
    call    so_basename
    pop     rdx
    pop     rdx
    call    sh_cut_all
    push    rax
    push    rax
    mov     edi, 12
    call    so_lap
    pop     rax
    pop     rax
    test    eax, eax
    jz      .Lsh_mem
    mov     rdi, [rip+so_obj]           # the original: hidden, not selected
    cmp     dword ptr [rip+so_impactset], 0 #  (on impact: it stays, whole,
    jne     23f                         #  until it is hit)
    or      dword ptr [rdi+OB_FLAGS], OBF_HIDDEN
    and     dword ptr [rdi+OB_FLAGS], ~OBF_SELECTED
23: call    so_build
    mov     ebx, eax
    call    so_bodies
    call    so_glue
    mov     edi, 13
    call    so_lap
    jmp     .Lsh_made
.Lsh_balls:
    lea     rsi, [rip+s_sh_ball]
    call    so_basename
    mov     dword ptr [rip+so_first], 0
    call    so_balls
    mov     ebx, eax
    lea     rcx, [rip+sh_stat]
    cvtsi2sd xmm0, eax
    movsd   [rcx], xmm0
    movsd   [rcx+8], xmm0
    test    eax, eax
    jz      .Lsh_noseed
    mov     rdi, [rip+so_obj]
    or      dword ptr [rdi+OB_FLAGS], OBF_HIDDEN
    and     dword ptr [rdi+OB_FLAGS], ~OBF_SELECTED
    call    so_bodies
    mov     edi, 13
    call    so_lap
.Lsh_made:
    lea     rax, [rip+sh_stat]          # 14-17: the cut's phases (ms)
    mov     ecx, 1
22: lea     rdx, [rip+sh_cnt]
    cvtsi2sd xmm0, qword ptr [rdx+rcx*8]
    divsd   xmm0, [rip+so_ms]
    movsd   [rax+13*8+rcx*8], xmm0
    inc     ecx
    cmp     ecx, 5
    jb      22b
    call    sh_res_free
    call    sh_src_free
    mov     eax, [rip+so_first]
    test    eax, eax
    jz      21f
    cmp     dword ptr [rip+so_impactset], 0
    jne     21f
    mov     [rip+active_obj], eax
21: call    so_now
    sub     rax, [rip+so_t0]
    cvtsi2sd xmm0, rax
    divsd   xmm0, [rip+so_ms]
    lea     rax, [rip+sh_stat]
    movsd   [rax+6*8], xmm0
    call    fmt_reset
    lea     rdi, [rip+s_sh_done]
    call    fmt_str
    mov     edi, ebx
    call    fmt_int
    lea     rdi, [rip+s_sh_pieces]
    call    fmt_str
    lea     rax, [rip+sh_stat]
    cvttsd2si edi, qword ptr [rax+6*8]
    call    fmt_int
    lea     rdi, [rip+s_sh_ms]
    call    fmt_str
    lea     rdi, [rip+fmt_buf]
    call    log_line
    mov     dword ptr [rip+dirty], 1
    jmp     .Lsh_out
.Lsh_none:
    lea     rdi, [rip+s_sh_none]
    call    log_line
    jmp     .Lsh_drop
.Lsh_noseed:
    lea     rdi, [rip+s_sh_noseed]
    call    log_line
    call    sh_src_free
    jmp     .Lsh_drop
.Lsh_mem:
    lea     rdi, [rip+s_sh_mem]
    call    log_line
    call    sh_src_free
    jmp     .Lsh_drop
.Lsh_bad:
    lea     rdi, [rip+s_sh_bad]
    lea     rsi, [rip+im_word]
    call    log_pair
.Lsh_drop:
    call    undo_drop_last
.Lsh_out:
    add     rsp, 16
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# -----------------------------------------------------------------------------
# the preview: while the Shatter form is open, the cells it would cut drawn
#   as outlines (the cut faces' edges, in the world) - made again only when
#   its values or the object change
# -----------------------------------------------------------------------------
.equ PV_MAX,    32768                   # segments at most
.section .bss
.align 8
pv_seg:         .skip PV_MAX*24         # from, to (world, floats)
pv_n:           .skip 4
pv_obj:         .skip 4                 # made for: the object, its mesh,
.align 8
pv_mesh:        .skip 8                 #  the argument
pv_key:         .skip 512
.text

# so_preview_draw - in the viewport, after the overlays
so_preview_draw:
    push    rbx
    push    r12
    sub     rsp, 8
    lea     rdi, [rip+op_shatter]
    call    dlg_form_arg
    test    rax, rax
    jz      9f
    mov     rbx, rax
    mov     edi, [rip+active_obj]
    call    obj_get
    test    rax, rax
    jz      9f
    mov     r12, rax
    mov     eax, [r12+OB_UID]
    cmp     eax, [rip+pv_obj]
    jne     1f
    mov     rax, [r12+OB_MESH]
    cmp     rax, [rip+pv_mesh]
    jne     1f
    mov     rdi, rbx
    lea     rsi, [rip+pv_key]
    call    str_eq
    test    eax, eax
    jnz     2f
1:  mov     eax, [r12+OB_UID]           # made again
    mov     [rip+pv_obj], eax
    mov     rax, [r12+OB_MESH]
    mov     [rip+pv_mesh], rax
    mov     rsi, rbx
    lea     rdi, [rip+pv_key]
    mov     ecx, 511
    rep     movsb
    mov     byte ptr [rdi], 0
    mov     rdi, rbx
    mov     rsi, r12
    call    pv_make
2:  xor     ebx, ebx                    # drawn
3:  cmp     ebx, [rip+pv_n]
    jae     9f
    imul    rsi, rbx, 24
    lea     rax, [rip+pv_seg]
    add     rsi, rax
    lea     rdi, [rip+lp0]
    mov     ecx, 24
    rep     movsb
    mov     edx, 0xffffb02e
    call    line3d
    inc     ebx
    jmp     3b
9:  add     rsp, 8
    pop     r12
    pop     rbx
    ret

# pv_make(rdi=argument, rsi=object) - pv_seg, pv_n: the cells' outlines
#   (shards and bricks; balls: none)
pv_make:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    sub     rsp, 16
    mov     dword ptr [rip+pv_n], 0
    mov     r12, rsi
    mov     rax, [rip+op_arg]
    mov     [rsp], rax
    mov     [rip+op_arg], rdi
    call    so_defaults
    call    so_parse
    mov     rcx, [rsp]
    mov     [rip+op_arg], rcx
    test    eax, eax
    jz      .Lpv_out
    cmp     dword ptr [rip+so_pat], 2   # (balls: not cells)
    je      .Lpv_out
    cmp     dword ptr [r12+OB_TYPE], OT_MESH
    jne     .Lpv_out
    cmp     dword ptr [rip+so_again], 0 # again, a piece: its original
    je      1f
    mov     rdi, r12
    call    par_of
    test    rax, rax
    jz      1f
    test    dword ptr [rax+OB_FLAGS], OBF_HIDDEN
    jz      1f
    mov     r12, rax
1:  cmp     qword ptr [r12+OB_MESH], 0
    je      .Lpv_out
    mov     [rip+so_obj], r12
    mov     rdi, r12
    call    so_source
    test    eax, eax
    jz      .Lpv_out
    mov     rdi, [rip+so_obj]
    lea     rsi, [rip+so_mat]
    call    obj_matrix
    call    so_inverse
    cmp     dword ptr [rip+so_atmode], 1
    jne     2f
    lea     rsi, [rip+so_atw]
    lea     rdi, [rip+so_at]
    call    so_tolocal
2:  mov     edi, [rip+so_seed]
    call    so_seed_rng
    cmp     dword ptr [rip+so_pat], 1
    je      3f
    cmp     dword ptr [rip+so_atmode], 2
    jne     21f
    call    so_cdf_make
21: mov     edi, [rip+so_count]
    call    so_seeds
    test    eax, eax
    jz      .Lpv_src
    mov     dword ptr [rip+sh_mode], 1
    mov     edx, eax
    jmp     4f
3:  call    so_bricks
    test    eax, eax
    jz      .Lpv_src
    mov     eax, [rip+sh_ncell_used]
    mov     [rip+sh_ncell], eax
    mov     dword ptr [rip+sh_mode], 0
    mov     edx, eax
4:  call    sh_cut_all
    test    eax, eax
    jz      .Lpv_res
    xor     r13d, r13d                  # each cell's pieces
5:  cmp     r13d, [rip+sh_nres]
    jae     .Lpv_res
    mov     rax, [rip+sh_res]
    mov     rcx, r13
    shl     rcx, 4
    mov     rbx, [rax+rcx]
    test    rbx, rbx
    jz      58f
    mov     r14d, [rbx]
    add     rbx, PP_HDR
51: test    r14d, r14d
    jz      58f
    mov     eax, [rbx+PH_NV]            # r15: its polygons (count, tag),
    imul    eax, eax, 12                #  [rsp+8]: their loops
    lea     r15, [rbx+PH_SZ+rax]
    mov     eax, [rbx+PH_NP]
    lea     rax, [r15+rax*8]
    mov     [rsp+8], rax
    xor     ecx, ecx
52: cmp     ecx, [rbx+PH_NP]
    jae     57f
    mov     r8d, [r15+rcx*8]            # its corners
    cmp     dword ptr [r15+rcx*8+4], 0  # (a cut face only)
    je      56f
    xor     r9d, r9d
53: cmp     r9d, r8d
    jae     56f
    mov     eax, [rip+pv_n]
    cmp     eax, PV_MAX
    jae     .Lpv_res
    imul    rdi, rax, 24
    lea     rax, [rip+pv_seg]
    add     rdi, rax
    mov     rax, [rsp+8]
    mov     esi, [rax+r9*4]             # this corner
    call    pv_point
    lea     edx, [r9+1]
    cmp     edx, r8d
    jb      54f
    xor     edx, edx
54: mov     rax, [rsp+8]
    mov     esi, [rax+rdx*4]            # the next
    add     rdi, 12
    call    pv_point
    inc     dword ptr [rip+pv_n]
    inc     r9d
    jmp     53b
56: mov     rax, [rsp+8]                # the next polygon
    lea     rax, [rax+r8*4]
    mov     [rsp+8], rax
    inc     ecx
    jmp     52b
57: mov     rsi, rbx
    call    so_piece_next
    mov     rbx, rax
    dec     r14d
    jmp     51b
58: inc     r13d
    jmp     5b
.Lpv_res:
    call    sh_res_free
.Lpv_src:
    call    sh_src_free
.Lpv_out:
    cvtsi2sd xmm0, dword ptr [rip+pv_n] # (shinfo(23): the outlines drawn)
    lea     rax, [rip+sh_stat]
    movsd   [rax+23*8], xmm0
    add     rsp, 16
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# pv_point(rdi=out, esi=vertex; rbx=piece) - its place in the world: the
#   original's matrix x (the piece's centre + the vertex) (rcx r8 r9 kept)
pv_point:
    imul    rax, rsi, 12
    lea     rsi, [rbx+PH_SZ+rax]
    lea     rax, [rip+so_mat]
    xor     edx, edx
1:  movss   xmm0, [rax+12]
    xor     r10d, r10d
2:  cvtss2sd xmm1, [rsi+r10*4]
    addsd   xmm1, [rbx+PH_C+r10*8]
    cvtsd2ss xmm1, xmm1
    mulss   xmm1, [rax+r10*4]
    addss   xmm0, xmm1
    inc     r10d
    cmp     r10d, 3
    jb      2b
    movss   [rdi+rdx*4], xmm0
    add     rax, 16
    inc     edx
    cmp     edx, 3
    jb      1b
    ret

# -----------------------------------------------------------------------------
# mesh.separate_loose - each selected mesh with more than one loose part:
#   one object a part (its polygons, its own vertices), the original goes
# -----------------------------------------------------------------------------
do_sep_loose:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    sub     rsp, 16
    xor     r15d, r15d                  # objects made
    mov     ebx, [rip+obj_count]        # (those there before)
    xor     r12d, r12d
1:  cmp     r12d, ebx
    jae     5f
    mov     edi, r12d
    call    obj_at
    test    dword ptr [rax+OB_FLAGS], OBF_SELECTED
    jz      4f
    cmp     dword ptr [rax+OB_TYPE], OT_MESH
    jne     4f
    mov     rcx, [rax+OB_MESH]
    test    rcx, rcx
    jz      4f
    mov     [rip+so_obj], rax
    mov     rdi, rax
    call    sl_split
    test    eax, eax
    jz      4f
    add     r15d, eax
    mov     edi, r12d                   # the original goes
    call    obj_remove_at
    dec     ebx
    jmp     1b
4:  inc     r12d
    jmp     1b
5:  test    r15d, r15d
    jz      8f
    call    fmt_reset
    lea     rdi, [rip+s_sl_done]
    call    fmt_str
    mov     edi, r15d
    call    fmt_int
    lea     rdi, [rip+fmt_buf]
    call    log_line
    mov     dword ptr [rip+dirty], 1
    jmp     9f
8:  lea     rdi, [rip+s_sl_none]
    call    log_line
    call    undo_drop_last
9:  add     rsp, 16
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# sl_split(rdi=object) -> eax = objects made (0: one part, nothing done):
#   its base mesh's polygons grouped by shared vertices
sl_split:
    push    rbp
    mov     rbp, rsp
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    sub     rsp, 56                     # +0 parents, +8 part of each root,
    and     rsp, -16                    #  +16 parts, +24 local index, +32 part
    mov     rbx, [rdi+OB_MESH]
    mov     esi, [rbx+ME_NVERTS]
    test    esi, esi
    jz      .Lsl_none
    shl     rsi, 3
    call    sh_map_g
    test    rax, rax
    jz      .Lsl_none
    mov     [rsp], rax
    mov     ecx, [rbx+ME_NVERTS]
    lea     rdx, [rax+rcx*4]
    mov     [rsp+8], rdx
    xor     ecx, ecx                    # each its own
1:  cmp     ecx, [rbx+ME_NVERTS]
    jae     2f
    mov     [rax+rcx*4], ecx
    mov     dword ptr [rdx+rcx*4], -1
    inc     ecx
    jmp     1b
2:  xor     r12d, r12d                  # polygons join their vertices
    mov     r9, [rsp]
3:  cmp     r12d, [rbx+ME_NPOLYS]
    jae     4f
    mov     r8, [rbx+ME_POFF]
    mov     r13d, [r8+r12*4]
    mov     r14d, [r8+r12*4+4]
    mov     r8, [rbx+ME_LOOPS]
    mov     edi, [r8+r13*4]
    mov     r15d, edi
31: inc     r13d
    cmp     r13d, r14d
    jae     32f
    mov     r8, [rbx+ME_LOOPS]
    mov     r11d, [r8+r13*4]
    mov     edi, r15d
    call    sl_join
    jmp     31b
32: inc     r12d
    jmp     3b
4:  xor     r12d, r12d                  # roots -> parts (used vertices)
    mov     dword ptr [rsp+16], 0
41: cmp     r12d, [rbx+ME_NPOLYS]
    jae     5f
    mov     r8, [rbx+ME_POFF]
    mov     eax, [r8+r12*4]
    mov     r8, [rbx+ME_LOOPS]
    mov     edi, [r8+rax*4]
    call    sl_root
    mov     rdx, [rsp+8]
    cmp     dword ptr [rdx+rax*4], -1
    jne     42f
    mov     ecx, [rsp+16]
    mov     [rdx+rax*4], ecx
    inc     dword ptr [rsp+16]
42: inc     r12d
    jmp     41b
5:  xor     r15d, r15d
    cmp     dword ptr [rsp+16], 2
    jb      .Lsl_free
    lea     rsi, [rip+s_sh_part]
    call    so_basename
    mov     rdi, [rip+so_obj]
    lea     rsi, [rip+so_mat]
    call    obj_matrix
    mov     dword ptr [rsp+32], 0       # each part: a mesh of its polygons
6:  mov     eax, [rsp+32]
    cmp     eax, [rsp+16]
    jae     .Lsl_free
    mov     edi, eax
    mov     rsi, rbx
    lea     rdx, [rsp]
    call    sl_part
    test    eax, eax
    jz      61f
    inc     r15d
61: inc     dword ptr [rsp+32]
    jmp     6b
.Lsl_free:
    mov     rdi, [rsp]
    mov     esi, [rbx+ME_NVERTS]
    shl     rsi, 3
    call    sh_unmap_g
    mov     eax, r15d
    jmp     9f
.Lsl_none:
    xor     eax, eax
9:  lea     rsp, [rbp-40]
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    pop     rbp
    ret

# sl_root(edi=vertex, r9 = parents) -> eax
sl_root:
    mov     eax, edi
1:  mov     edx, [r9+rax*4]
    cmp     edx, eax
    je      9f
    mov     r10d, [r9+rdx*4]
    mov     [r9+rax*4], r10d
    mov     eax, r10d
    jmp     1b
9:  ret
# sl_join(edi, r11d; r9 = parents)
sl_join:
    call    sl_root
    mov     ecx, eax
    mov     edi, r11d
    call    sl_root
    cmp     eax, ecx
    je      9f
    jb      1f
    mov     [r9+rax*4], ecx
    ret
1:  mov     [r9+rcx*4], eax
9:  ret

# sl_part(edi=part, rsi=mesh, rdx=sl_split's arrays) -> eax = 1: an object
#   of that part's polygons (vertex colours and UVs kept)
sl_part:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    push    rbp
    sub     rsp, 56
    mov     [rsp], edi
    mov     rbx, rsi
    mov     rbp, rdx
    xor     r12d, r12d                  # its loops, polygons
    xor     r13d, r13d
    xor     r14d, r14d
    xor     r15d, r15d
1:  cmp     r12d, [rbx+ME_NPOLYS]
    jae     2f
    call    sl_ppart
    cmp     eax, [rsp]
    jne     11f
    inc     r15d
    mov     r8, [rbx+ME_POFF]
    mov     eax, [r8+r12*4+4]
    sub     eax, [r8+r12*4]
    add     r14d, eax
11: inc     r12d
    jmp     1b
2:  mov     edi, [rbx+ME_NVERTS]        # (vertices: at most all)
    mov     esi, r14d
    mov     edx, r15d
    call    mesh_new
    test    rax, rax
    jz      8f
    mov     [rsp+8], rax
    mov     rdi, [rbx+ME_UV]            # UVs, colours when it has them
    test    rdi, rdi
    jz      21f
    mov     rdi, rax
    call    mesh_uv_alloc
21: cmp     qword ptr [rbx+ME_VCOL], 0
    je      22f
    mov     rdi, [rsp+8]
    call    mesh_vcol_alloc
22: mov     esi, [rbx+ME_NVERTS]        # vertex map (-1)
    shl     rsi, 2
    call    sh_map_g
    test    rax, rax
    jz      8f
    mov     [rsp+16], rax
    mov     rdi, rax
    mov     ecx, [rbx+ME_NVERTS]
    mov     eax, -1
    rep     stosd
    xor     r12d, r12d
3:  cmp     r12d, [rbx+ME_NPOLYS]
    jae     5f
    call    sl_ppart
    cmp     eax, [rsp]
    jne     49f
    mov     r8, [rbx+ME_POFF]
    mov     r13d, [r8+r12*4]
    mov     r14d, [r8+r12*4+4]
    mov     r15, [rsp+8]
    mov     ecx, [r15+ME_NLOOPS]        # (its first loop in the new mesh)
    mov     [rsp+24], ecx
    xor     ecx, ecx                    # its vertices (new where first seen)
4:  cmp     r13d, r14d
    jae     45f
    mov     r8, [rbx+ME_LOOPS]
    mov     edi, [r8+r13*4]
    mov     rdx, [rsp+16]
    mov     eax, [rdx+rdi*4]
    cmp     eax, -1
    jne     41f
    mov     eax, [r15+ME_NVERTS]
    mov     [rdx+rdi*4], eax
    push    rax
    push    rcx
    push    rdi
    sub     rsp, 8
    mov     rsi, [rbx+ME_POS]
    imul    rdi, rdi, 12
    movss   xmm0, [rsi+rdi]
    movss   xmm1, [rsi+rdi+4]
    movss   xmm2, [rsi+rdi+8]
    mov     rdi, r15
    call    mesh_add_vert
    add     rsp, 8
    pop     rdi
    pop     rcx
    pop     rax
    mov     rsi, [rbx+ME_VCOL]          # (its colour)
    test    rsi, rsi
    jz      41f
    mov     r8d, [rsi+rdi*4]
    mov     rsi, [r15+ME_VCOL]
    test    rsi, rsi
    jz      41f
    mov     [rsi+rax*4], r8d
41: lea     rdx, [rip+sl_poly]
    mov     [rdx+rcx*4], eax
    inc     ecx
    inc     r13d
    cmp     ecx, 256
    jb      4b
45: mov     rdi, r15
    lea     rsi, [rip+sl_poly]
    mov     edx, ecx
    call    mesh_add_poly
    mov     rsi, [rbx+ME_UV]            # its UVs
    test    rsi, rsi
    jz      49f
    mov     rdi, [r15+ME_UV]
    test    rdi, rdi
    jz      49f
    mov     r8, [rbx+ME_POFF]
    mov     eax, [r8+r12*4]
    mov     ecx, [r8+r12*4+4]
    sub     ecx, eax
    lea     rsi, [rsi+rax*8]
    mov     eax, [rsp+24]
    lea     rdi, [rdi+rax*8]
    shl     ecx, 1
    rep     movsd
49: inc     r12d
    jmp     3b
5:  mov     rdi, [rsp+16]
    mov     esi, [rbx+ME_NVERTS]
    shl     rsi, 2
    call    sh_unmap_g
    call    fa_mark
    mov     [rsp+24], rax
    mov     rdi, [rsp+8]
    call    mesh_finish
    mov     rdi, [rsp+24]
    call    fa_release
    call    so_nextname
    mov     edi, OT_MESH
    lea     rsi, [rip+so_name]
    mov     rdx, [rsp+8]
    call    obj_new
    test    eax, eax
    jz      8f
    mov     edi, eax
    call    obj_get
    mov     rsi, [rip+so_obj]           # where the original was
    mov     rdi, rax
    push    rax
    sub     rsp, 8
    mov     ecx, OB_MESH
    call    sl_copy_head
    add     rsp, 8
    pop     rax
    or      dword ptr [rax+OB_FLAGS], OBF_SELECTED
    mov     eax, 1
    jmp     9f
8:  xor     eax, eax
9:  add     rsp, 56
    pop     rbp
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# sl_copy_head(rdi=new object, rsi=original) - location, rotation, scale,
#   colour, material
sl_copy_head:
    lea     rdx, [rsi+OB_LOC]
    lea     rcx, [rdi+OB_LOC]
    xor     eax, eax
1:  mov     r8d, [rdx+rax*4]
    mov     [rcx+rax*4], r8d
    inc     eax
    cmp     eax, 9
    jb      1b
    mov     eax, [rsi+OB_COLOR]
    mov     [rdi+OB_COLOR], eax
    mov     rax, [rsi+OB_MAT]
    mov     [rdi+OB_MAT], rax
    ret

# sl_ppart(r12d = polygon; rbx = mesh, rbp = sl_split's arrays) -> eax = its
#   part (its first vertex's root's)
sl_ppart:
    mov     r8, [rbx+ME_POFF]
    mov     eax, [r8+r12*4]
    mov     r8, [rbx+ME_LOOPS]
    mov     edi, [r8+rax*4]
    mov     r9, [rbp]
    call    sl_root
    mov     rdx, [rbp+8]
    mov     eax, [rdx+rax*4]
    ret

.section .bss
.align 4
sl_poly:        .skip 4*256

.section .rodata
.align 8
so_ms:          .double 1000000.0
.align 16
so_abs:         .quad 0x7fffffffffffffff, 0
so_tiny:        .double 1.0e-300

.section .note.GNU-stack,"",@progbits
