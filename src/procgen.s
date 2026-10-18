# =============================================================================
#  BeeModel - procedural generators: terrain, L-systems, wave function collapse
#
#  Terrain (geometry nodes): a heightfield grid from octaves of Perlin noise,
#  smooth (fBm) or ridged, mixed; terracing into flat steps with risers;
#  hydraulic erosion by droplets that pick up sediment where they speed
#  down a slope and drop it where they slow (heights in cell units, bilinear
#  gradients, a bounded number of steps each).
#
#  L-systems: an axiom rewritten by rules, then read by a 3D turtle
#  (F draw, f move, + - yaw, & ^ pitch, \ / roll, | turn round, [ ] a
#  branch, ! thinner) into chains of points with a radius each: lines (a
#  curve for the curve nodes) or, with a radius, tubes that thin with every
#  branch (curve.s sweeps them).
#
#  Wave function collapse: a grid of cells, each the set of (tile, quarter
#  turn) options still possible (one 64-bit mask); the cell with the fewest
#  is collapsed at random and the choice propagated to its neighbours. Two
#  options fit side by side when the vertices of their touching faces match
#  (a hash of the quantized face points, taken from the tile meshes - no
#  rules to write; a tile is its object's mesh turned and scaled as the
#  object is, wherever it stands, in a cell from -0.5 to 0.5 on each axis).
#  A contradiction starts again with the next seed.
# =============================================================================
.intel_syntax noprefix
.include "const.inc"
.include "macros.inc"

.globl tg_terrain
.globl tg_terrace
.globl er_run
.globl er_h
.globl er_n
.globl er_rng
.globl tg_erode
.globl tg_lsystem
.globl ls_build
.globl wfc_run

.equ ND_IN,     4
.equ ND_P,      52
.equ EP_SZ,     20
.equ CH_SZ,     12

.section .rodata
.align 16
pg_one:         .float 1.0
pg_half:        .float 0.5
pg_two:         .float 2.0
pg_zero:        .float 0.0
pg_tiny:        .float 1.0e-6
.align 16
pg_absm:        .long 0x7fffffff, 0, 0, 0
pg_s13:         .float 13.37
pg_s7:          .float 7.77
pg_s3:          .float 3.1
pg_inv32:       .float 2.3283064e-10    # 1 / 2^32
pg_n05:         .float -0.5

.section .bss
.align 16
tg_mesh:        .skip 8                 # terrain: the grid being made,
tg_n:           .skip 4                 #  its subdivisions,
tg_oct:         .skip 4                 #  octaves,
tg_scale:       .skip 4                 #  noise scale, ridged mix,
tg_ridge:       .skip 4
tg_seed:        .skip 4                 #  the seed's offset,
tg_height:      .skip 4                 #  height
.text

# pg_rand(rdi=state ptr) -> eax = 32 random bits (xorshift)
pg_rand:
    mov     eax, [rdi]
    mov     ecx, eax
    shl     ecx, 13
    xor     eax, ecx
    mov     ecx, eax
    shr     ecx, 17
    xor     eax, ecx
    mov     ecx, eax
    shl     ecx, 5
    xor     eax, ecx
    mov     [rdi], eax
    ret

# pg_randf(rdi=state ptr) -> xmm0 in 0..1
pg_randf:
    call    pg_rand
    cvtsi2ss xmm0, rax
    mulss   xmm0, [rip+pg_inv32]
    ret

# -----------------------------------------------------------------------------
# Terrain: Size, Resolution, Height, Seed; input "Noise" = scale, detail
#   (octaves), ridged (0 smooth .. 1 ridged)
# -----------------------------------------------------------------------------
# tg_terrain(rsi=node) -> rax = a new grid mesh, or 0
tg_terrain:
    push    rbx
    push    r12
    sub     rsp, 8
    mov     r12, rsi
    cvttss2si edi, [r12+ND_P+4]
    cmp     edi, 1
    jge     1f
    mov     edi, 1
1:  cmp     edi, 2048
    jle     2f
    mov     edi, 2048
2:  mov     [rip+tg_n], edi
    call    prim_grid_n
    test    rax, rax
    jz      9f
    mov     rbx, rax
    mov     [rip+tg_mesh], rax
    movss   xmm0, [r12+ND_P+8]
    movss   [rip+tg_height], xmm0
    cvttss2si eax, [r12+ND_P+12]        # the seed: an offset into the noise
    cvtsi2ss xmm0, eax
    movss   [rip+tg_seed], xmm0
    movss   xmm0, [r12+ND_IN+4]
    movss   [rip+tg_scale], xmm0
    cvttss2si eax, [r12+ND_IN+8]
    cmp     eax, 1
    jge     3f
    mov     eax, 1
3:  cmp     eax, 10
    jle     4f
    mov     eax, 10
4:  mov     [rip+tg_oct], eax
    movss   xmm0, [r12+ND_IN+12]
    maxss   xmm0, [rip+pg_zero]
    minss   xmm0, [rip+pg_one]
    movss   [rip+tg_ridge], xmm0
    lea     rdi, [rip+tg_job]           # heights, rows in parallel
    xor     esi, esi
    mov     edx, [rip+tg_n]
    inc     edx
    mov     ecx, 4
    call    parallel_for
    movss   xmm0, [r12+ND_P]            # 2 x 2 -> size x size
    mulss   xmm0, [rip+pg_half]
    mov     ecx, [rbx+ME_NVERTS]
    mov     rdx, [rbx+ME_POS]
5:  test    ecx, ecx
    jz      6f
    movss   xmm1, [rdx]
    mulss   xmm1, xmm0
    movss   [rdx], xmm1
    movss   xmm1, [rdx+8]
    mulss   xmm1, xmm0
    movss   [rdx+8], xmm1
    add     rdx, 12
    dec     ecx
    jmp     5b
6:  mov     rdi, rbx
    call    mesh_bbox
    mov     rax, rbx
9:  add     rsp, 8
    pop     r12
    pop     rbx
    ret

# tg_job(esi=begin, edx=end rows) - heights of those rows
tg_job:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    sub     rsp, 64
    mov     r12d, esi
    mov     r13d, edx
.Ltj_row:
    cmp     r12d, r13d
    jae     .Ltj_out
    xor     r14d, r14d
.Ltj_col:
    cmp     r14d, [rip+tg_n]
    ja      .Ltj_nrow
    cvtsi2ss xmm0, r14d                 # u, v in 0..1, then the noise space
    cvtsi2ss xmm1, r12d
    cvtsi2ss xmm2, dword ptr [rip+tg_n]
    divss   xmm0, xmm2
    divss   xmm1, xmm2
    mulss   xmm0, [rip+tg_scale]
    mulss   xmm1, [rip+tg_scale]
    movss   xmm2, [rip+tg_seed]
    mulss   xmm2, [rip+pg_s13]
    addss   xmm0, xmm2
    movss   [rsp+32], xmm0              # base point
    movss   xmm2, [rip+tg_seed]
    mulss   xmm2, [rip+pg_s3]
    addss   xmm2, [rip+pg_half]
    movss   [rsp+36], xmm2
    movss   xmm2, [rip+tg_seed]
    mulss   xmm2, [rip+pg_s7]
    addss   xmm1, xmm2
    movss   [rsp+40], xmm1
    mov     eax, [rip+pg_one]
    mov     [rsp+44], eax               # amplitude
    mov     [rsp+48], eax               # frequency
    xorps   xmm0, xmm0
    movss   [rsp+52], xmm0              # fbm sum
    movss   [rsp+56], xmm0              # ridged sum
    movss   [rsp+60], xmm0              # amplitudes
    xor     ebx, ebx
1:  cmp     ebx, [rip+tg_oct]
    jae     2f
    movss   xmm0, [rsp+32]
    mulss   xmm0, [rsp+48]
    movss   [rsp], xmm0
    movss   xmm0, [rsp+36]
    mulss   xmm0, [rsp+48]
    movss   [rsp+4], xmm0
    movss   xmm0, [rsp+40]
    mulss   xmm0, [rsp+48]
    movss   [rsp+8], xmm0
    lea     rdi, [rsp]
    call    perlin
    movss   xmm1, xmm0
    mulss   xmm1, [rsp+44]
    addss   xmm1, [rsp+52]
    movss   [rsp+52], xmm1
    andps   xmm0, [rip+pg_absm]         # ridged: (1 - |n|)^2
    movss   xmm1, [rip+pg_one]
    subss   xmm1, xmm0
    mulss   xmm1, xmm1
    mulss   xmm1, [rsp+44]
    addss   xmm1, [rsp+56]
    movss   [rsp+56], xmm1
    movss   xmm1, [rsp+44]
    addss   xmm1, [rsp+60]
    movss   [rsp+60], xmm1
    movss   xmm1, [rsp+44]
    mulss   xmm1, [rip+pg_half]
    movss   [rsp+44], xmm1
    movss   xmm1, [rsp+48]
    mulss   xmm1, [rip+pg_two]
    movss   [rsp+48], xmm1
    inc     ebx
    jmp     1b
2:  movss   xmm0, [rsp+52]              # f = 0.5 + 0.5 sum / A, g = ridged / A
    divss   xmm0, [rsp+60]
    mulss   xmm0, [rip+pg_half]
    addss   xmm0, [rip+pg_half]
    movss   xmm1, [rsp+56]
    divss   xmm1, [rsp+60]
    subss   xmm1, xmm0                  # t = f + (g - f) ridged
    mulss   xmm1, [rip+tg_ridge]
    addss   xmm0, xmm1
    mulss   xmm0, [rip+tg_height]
    mov     eax, [rip+tg_n]
    inc     eax
    imul    eax, r12d
    add     eax, r14d
    imul    rax, rax, 12
    mov     rcx, [rip+tg_mesh]
    add     rax, [rcx+ME_POS]
    movss   [rax+4], xmm0
    inc     r14d
    jmp     .Ltj_col
.Ltj_nrow:
    inc     r12d
    jmp     .Ltj_row
.Ltj_out:
    add     rsp, 64
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# tg_terrace(rdi=mesh, rsi=node) - Steps, Smooth: heights (Y, over the
#   mesh's range) into flat steps; a riser takes the last Smooth of a step
tg_terrace:
    push    rbx
    push    r12
    push    r13
    sub     rsp, 32
    mov     r12, rsi
    call    mesh_copy
    test    rax, rax
    jz      9f
    mov     rbx, rax
    cvttss2si eax, [r12+ND_P]
    cmp     eax, 1
    jge     1f
    mov     eax, 1
1:  cvtsi2ss xmm0, eax
    movss   [rsp], xmm0                 # steps
    movss   xmm0, [r12+ND_P+4]
    maxss   xmm0, [rip+pg_tiny]
    minss   xmm0, [rip+pg_one]
    movss   [rsp+4], xmm0               # smooth
    movss   xmm0, [rbx+ME_BMIN+4]
    movss   [rsp+8], xmm0               # y min
    movss   xmm1, [rbx+ME_BMAX+4]
    subss   xmm1, xmm0
    maxss   xmm1, [rip+pg_tiny]
    movss   [rsp+12], xmm1              # range
    mov     ecx, [rbx+ME_NVERTS]
    mov     rdx, [rbx+ME_POS]
2:  test    ecx, ecx
    jz      8f
    movss   xmm0, [rdx+4]               # t = (y - min) / range * steps
    subss   xmm0, [rsp+8]
    divss   xmm0, [rsp+12]
    mulss   xmm0, [rsp]
    roundss xmm1, xmm0, 1               # floor
    subss   xmm0, xmm1                  # fraction
    movss   xmm2, [rip+pg_one]          # riser: (frac - (1 - s)) / s, clamped
    subss   xmm2, [rsp+4]
    subss   xmm0, xmm2
    divss   xmm0, [rsp+4]
    maxss   xmm0, [rip+pg_zero]
    minss   xmm0, [rip+pg_one]
    movss   xmm2, xmm0                  # smoothstep
    mulss   xmm2, xmm0
    movss   xmm3, [rip+pg_two]
    mulss   xmm3, xmm0
    movss   xmm4, [rip+pg_one]
    addss   xmm4, [rip+pg_two]
    subss   xmm4, xmm3
    mulss   xmm2, xmm4
    addss   xmm1, xmm2
    divss   xmm1, [rsp]
    mulss   xmm1, [rsp+12]
    addss   xmm1, [rsp+8]
    movss   [rdx+4], xmm1
    add     rdx, 12
    dec     ecx
    jmp     2b
8:  mov     rdi, rbx
    call    mesh_bbox
    mov     rax, rbx
9:  add     rsp, 32
    pop     r13
    pop     r12
    pop     rbx
    ret

# -----------------------------------------------------------------------------
# Hydraulic erosion: Droplets, Strength, Seed on a grid mesh (row-major
#   (n+1)^2 vertices on the XZ plane, as the terrain and grid nodes make)
# -----------------------------------------------------------------------------
.equ ER_LIFE,   40
.section .rodata
.align 4
er_inertia:     .float 0.05
er_capacity:    .float 4.0
er_mincap:      .float 0.01
er_deposit:     .float 0.3
er_evap:        .float 0.02
er_gravity:     .float 4.0
er_w:           .float 0.000000, 0.015567, 0.029491, 0.015567, 0.000000, 0.015567, 0.064041, 0.088472, 0.064041, 0.015567, 0.029491, 0.088472, 0.147453, 0.088472, 0.029491, 0.015567, 0.064041, 0.088472, 0.064041, 0.015567, 0.000000, 0.015567, 0.029491, 0.015567, 0.000000
.section .bss
.align 8
er_h:           .skip 8                 # heights (cell units)
er_n:           .skip 4                 # vertices a row
er_rng:         .skip 4
.text

# er_at(xmm0=x, xmm1=z in cells) -> xmm0 = height, xmm1 = d/dx, xmm2 = d/dz,
#   eax = the cell's first vertex (bilinear over the four corners)
er_at:
    cvttss2si eax, xmm0
    cvttss2si ecx, xmm1
    cvtsi2ss xmm2, eax
    subss   xmm0, xmm2                  # u
    cvtsi2ss xmm2, ecx
    subss   xmm1, xmm2                  # v
    imul    ecx, [rip+er_n]
    add     eax, ecx
    mov     rdx, [rip+er_h]
    mov     ecx, [rip+er_n]
    movss   xmm3, [rdx+rax*4]           # h00
    movss   xmm4, [rdx+rax*4+4]         # h10
    lea     r8, [rax+rcx]
    movss   xmm5, [rdx+r8*4]            # h01
    movss   xmm6, [rdx+r8*4+4]          # h11
    movss   xmm2, xmm4                  # dx = (h10 - h00)(1 - v) + (h11 - h01) v
    subss   xmm2, xmm3
    movss   xmm7, [rip+pg_one]
    subss   xmm7, xmm1
    mulss   xmm2, xmm7
    movss   xmm7, xmm6
    subss   xmm7, xmm5
    mulss   xmm7, xmm1
    addss   xmm2, xmm7
    movss   [rip+er_t], xmm2
    movss   xmm2, xmm5                  # dz = (h01 - h00)(1 - u) + (h11 - h10) u
    subss   xmm2, xmm3
    movss   xmm7, [rip+pg_one]
    subss   xmm7, xmm0
    mulss   xmm2, xmm7
    movss   xmm7, xmm6
    subss   xmm7, xmm4
    mulss   xmm7, xmm0
    addss   xmm2, xmm7
    movss   xmm7, [rip+pg_one]          # h = lerp(lerp(h00, h10, u), lerp(h01, h11, u), v)
    subss   xmm7, xmm0
    mulss   xmm3, xmm7
    mulss   xmm5, xmm7
    mulss   xmm4, xmm0
    mulss   xmm6, xmm0
    addss   xmm3, xmm4
    addss   xmm5, xmm6
    movss   xmm7, [rip+pg_one]
    subss   xmm7, xmm1
    mulss   xmm3, xmm7
    mulss   xmm5, xmm1
    addss   xmm3, xmm5
    movaps  xmm0, xmm3
    movss   xmm1, [rip+er_t]
    ret

# er_brush(xmm0=amount, xmm1=x, xmm2=z in cells) - taken away around the
#   nearest vertex, radius 2.5 (no pits a droplet wide)
er_brush:
    cvtss2si eax, xmm1
    cvtss2si ecx, xmm2
    lea     r9, [rip+er_w]
    mov     rdx, [rip+er_h]
    mov     r10d, -2                    # dz
1:  cmp     r10d, 2
    jg      9f
    mov     r11d, -2                    # dx
2:  cmp     r11d, 2
    jg      5f
    lea     esi, [rax+r11]
    lea     edi, [rcx+r10]
    cmp     esi, [rip+er_n]
    jae     4f
    cmp     edi, [rip+er_n]
    jae     4f
    imul    edi, [rip+er_n]
    add     edi, esi
    lea     r8d, [r10+2]                # its weight
    imul    r8d, r8d, 5
    add     r8d, r11d
    add     r8d, 2
    movss   xmm3, [r9+r8*4]
    mulss   xmm3, xmm0
    movss   xmm4, [rdx+rdi*4]
    subss   xmm4, xmm3
    maxss   xmm4, [rip+pg_zero]         # (never below the lowest it was)
    minss   xmm4, [rdx+rdi*4]
    movss   [rdx+rdi*4], xmm4
4:  inc     r11d
    jmp     2b
5:  inc     r10d
    jmp     1b
9:  ret

# er_put(xmm0=amount, eax=cell's first vertex, xmm1=u, xmm2=v) - added to the
#   four corners by their bilinear weights
er_put:
    mov     rdx, [rip+er_h]
    mov     ecx, [rip+er_n]
    movss   xmm3, [rip+pg_one]
    subss   xmm3, xmm1                  # 1 - u
    movss   xmm4, [rip+pg_one]
    subss   xmm4, xmm2                  # 1 - v
    movss   xmm5, xmm0
    mulss   xmm5, xmm3
    mulss   xmm5, xmm4
    addss   xmm5, [rdx+rax*4]
    movss   [rdx+rax*4], xmm5
    movss   xmm5, xmm0
    mulss   xmm5, xmm1
    mulss   xmm5, xmm4
    addss   xmm5, [rdx+rax*4+4]
    movss   [rdx+rax*4+4], xmm5
    lea     r8, [rax+rcx]
    movss   xmm5, xmm0
    mulss   xmm5, xmm3
    mulss   xmm5, xmm2
    addss   xmm5, [rdx+r8*4]
    movss   [rdx+r8*4], xmm5
    movss   xmm5, xmm0
    mulss   xmm5, xmm1
    mulss   xmm5, xmm2
    addss   xmm5, [rdx+r8*4+4]
    movss   [rdx+r8*4+4], xmm5
    ret

# tg_erode(rdi=mesh, rsi=node) -> rax = an eroded copy (not a grid: a copy)
tg_erode:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    push    rbp
    sub     rsp, 104
    mov     r12, rsi
    call    mesh_copy
    test    rax, rax
    jz      .Ler_out
    mov     rbx, rax
    mov     eax, [rbx+ME_NVERTS]        # a grid? n x n, row-major on XZ
    cvtsi2sd xmm0, eax
    sqrtsd  xmm0, xmm0
    cvtsd2si ecx, xmm0
    mov     edx, ecx
    imul    edx, ecx
    cmp     edx, eax
    jne     .Ler_done
    cmp     ecx, 3
    jb      .Ler_done
    mov     [rip+er_n], ecx
    mov     rsi, [rbx+ME_POS]
    movss   xmm0, [rsi+12]              # spacing: vertex 1 - vertex 0 along X
    subss   xmm0, [rsi]
    comiss  xmm0, [rip+pg_tiny]
    jbe     .Ler_done
    movss   [rsp], xmm0
    imul    edx, ecx, 12                # vertex n: one row on (Z)
    movss   xmm1, [rsi+rdx+8]
    subss   xmm1, [rsi+8]
    subss   xmm1, xmm0
    andps   xmm1, [rip+pg_absm]
    comiss  xmm1, [rip+pg_tiny]
    ja      .Ler_done
    lea     edi, [rax*4+16]             # heights in cell units
    mov     esi, edi
    lea     rdi, [rip+frame_arena]
    call    arena_alloc
    test    rax, rax
    jz      .Ler_done
    mov     [rip+er_h], rax
    movss   xmm0, [rbx+ME_BMAX+4]       # heights 0..1 over the range
    subss   xmm0, [rbx+ME_BMIN+4]
    comiss  xmm0, [rip+pg_tiny]
    jbe     .Ler_done
    movss   [rsp], xmm0
    mov     rsi, [rbx+ME_POS]
    xor     ecx, ecx
1:  cmp     ecx, [rbx+ME_NVERTS]
    jae     2f
    imul    rdx, rcx, 12
    movss   xmm0, [rsi+rdx+4]
    subss   xmm0, [rbx+ME_BMIN+4]
    divss   xmm0, [rsp]
    movss   [rax+rcx*4], xmm0
    inc     ecx
    jmp     1b
2:  cvttss2si eax, [r12+ND_P+8]         # the seed
    imul    eax, eax, 0x9E3779B1
    or      eax, 1
    mov     [rip+er_rng], eax
    movss   xmm0, [r12+ND_P+4]
    maxss   xmm0, [rip+pg_zero]
    minss   xmm0, [rip+pg_one]
    movss   [rsp+4], xmm0               # erosion rate
    cvttss2si r13d, [r12+ND_P]          # droplets
    test    r13d, r13d
    jle     .Ler_back
    cmp     r13d, 2000000
    jle     1f
    mov     r13d, 2000000
1:  movss   xmm0, [rsp+4]
    mov     edi, r13d
    call    er_run
.Ler_back:
    mov     rax, [rip+er_h]             # heights back (world units)
    mov     rsi, [rbx+ME_POS]
    xor     ecx, ecx
1:  cmp     ecx, [rbx+ME_NVERTS]
    jae     2f
    movss   xmm0, [rax+rcx*4]
    mulss   xmm0, [rsp]
    addss   xmm0, [rbx+ME_BMIN+4]
    imul    rdx, rcx, 12
    movss   [rsi+rdx+4], xmm0
    inc     ecx
    jmp     1b
2:  mov     rdi, rbx
    call    mesh_bbox
.Ler_done:
    mov     rax, rbx
.Ler_out:
    add     rsp, 104
    pop     rbp
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# er_run(xmm0=rate, edi=droplets) - hydraulic erosion of er_h (er_n a row,
#   heights 0..1 over the range; er_rng the random state): each droplet
#   starts anywhere inside and lives up to ER_LIFE steps
er_run:
    push    r13
    push    r14
    sub     rsp, 72
    movss   [rsp+4], xmm0
    mov     r13d, edi
.Ler_drop:
    test    r13d, r13d
    jz      .Ler_rdone
    dec     r13d
    mov     eax, [rip+er_n]             # start anywhere inside
    sub     eax, 1
    cvtsi2ss xmm7, eax
    movss   [rsp+64], xmm7              # the far edge
    lea     rdi, [rip+er_rng]
    call    pg_randf
    mulss   xmm0, [rsp+64]
    movss   [rsp+8], xmm0               # x
    lea     rdi, [rip+er_rng]
    call    pg_randf
    mulss   xmm0, [rsp+64]
    movss   [rsp+12], xmm0              # z
    xorps   xmm0, xmm0
    movss   [rsp+16], xmm0              # dir x
    movss   [rsp+20], xmm0              # dir z
    movss   [rsp+32], xmm0              # sediment
    mov     eax, [rip+pg_one]
    mov     [rsp+24], eax               # speed
    mov     [rsp+28], eax               # water
    xor     r14d, r14d
.Ler_step:
    cmp     r14d, ER_LIFE
    jae     .Ler_drop
    movss   xmm0, [rsp+8]
    movss   xmm1, [rsp+12]
    call    er_at
    mov     [rsp+36], eax               # the cell
    movss   [rsp+40], xmm0              # height
    movss   xmm3, [rsp+8]               # (u, v kept for er_put)
    roundss xmm4, xmm3, 1
    subss   xmm3, xmm4
    movss   [rsp+44], xmm3
    movss   xmm3, [rsp+12]
    roundss xmm4, xmm3, 1
    subss   xmm3, xmm4
    movss   [rsp+48], xmm3
    movss   xmm3, [rip+pg_one]          # dir = dir inertia - grad (1 - inertia)
    subss   xmm3, [rip+er_inertia]
    mulss   xmm1, xmm3
    mulss   xmm2, xmm3
    movss   xmm4, [rsp+16]
    mulss   xmm4, [rip+er_inertia]
    subss   xmm4, xmm1
    movss   xmm5, [rsp+20]
    mulss   xmm5, [rip+er_inertia]
    subss   xmm5, xmm2
    movss   xmm6, xmm4
    mulss   xmm6, xmm4
    movss   xmm7, xmm5
    mulss   xmm7, xmm5
    addss   xmm6, xmm7
    sqrtss  xmm6, xmm6
    comiss  xmm6, [rip+pg_tiny]
    jbe     .Ler_drop                   # (flat: it stops)
    divss   xmm4, xmm6
    divss   xmm5, xmm6
    movss   [rsp+16], xmm4
    movss   [rsp+20], xmm5
    movss   xmm0, [rsp+8]
    addss   xmm0, xmm4
    movss   xmm1, [rsp+12]
    addss   xmm1, xmm5
    xorps   xmm2, xmm2                  # off the map: gone
    comiss  xmm0, xmm2
    jb      .Ler_drop
    comiss  xmm1, xmm2
    jb      .Ler_drop
    comiss  xmm0, [rsp+64]
    jae     .Ler_drop
    comiss  xmm1, [rsp+64]
    jae     .Ler_drop
    movss   [rsp+8], xmm0
    movss   [rsp+12], xmm1
    call    er_at
    subss   xmm0, [rsp+40]              # dh
    movss   [rsp+52], xmm0
    xorps   xmm1, xmm1                  # capacity = max(-dh speed water C, min)
    subss   xmm1, xmm0
    mulss   xmm1, [rsp+24]
    mulss   xmm1, [rsp+28]
    mulss   xmm1, [rip+er_capacity]
    maxss   xmm1, [rip+er_mincap]
    movss   [rsp+56], xmm1
    xorps   xmm2, xmm2
    comiss  xmm0, xmm2
    ja      .Ler_dep_up
    movss   xmm2, [rsp+32]
    comiss  xmm2, xmm1
    ja      .Ler_dep
    subss   xmm1, xmm2                  # erode: min((cap - sed) rate, -dh)
    mulss   xmm1, [rsp+4]
    xorps   xmm3, xmm3
    subss   xmm3, xmm0
    minss   xmm1, xmm3
    movss   xmm2, [rsp+32]
    addss   xmm2, xmm1
    movss   [rsp+32], xmm2
    movss   xmm0, xmm1
    movss   xmm1, [rsp+8]               # (the old place: before the move)
    subss   xmm1, [rsp+16]
    movss   xmm2, [rsp+12]
    subss   xmm2, [rsp+20]
    call    er_brush
    jmp     .Ler_moved
.Ler_dep_up:                            # uphill: fill the pit (up to dh)
    movss   xmm1, [rsp+32]
    minss   xmm0, xmm1
    jmp     .Ler_put_dep
.Ler_dep:                               # too much: drop part of the excess
    subss   xmm2, xmm1
    mulss   xmm2, [rip+er_deposit]
    movss   xmm0, xmm2
.Ler_put_dep:
    movss   xmm1, [rsp+32]
    subss   xmm1, xmm0
    movss   [rsp+32], xmm1
.Ler_put:
    mov     eax, [rsp+36]
    movss   xmm1, [rsp+44]
    movss   xmm2, [rsp+48]
    call    er_put
.Ler_moved:
    movss   xmm0, [rsp+24]              # speed = sqrt(max(0, s^2 - dh g))
    mulss   xmm0, xmm0
    movss   xmm1, [rsp+52]
    mulss   xmm1, [rip+er_gravity]
    subss   xmm0, xmm1
    maxss   xmm0, [rip+pg_zero]
    sqrtss  xmm0, xmm0
    movss   [rsp+24], xmm0
    movss   xmm0, [rip+pg_one]
    subss   xmm0, [rip+er_evap]
    mulss   xmm0, [rsp+28]
    movss   [rsp+28], xmm0
    inc     r14d
    jmp     .Ler_step
.Ler_rdone:
    add     rsp, 72
    pop     r14
    pop     r13
    ret

.section .bss
er_t:           .skip 4
.text

# -----------------------------------------------------------------------------
# L-systems
# -----------------------------------------------------------------------------
.equ LS_CAP,    8000000                 # characters after rewriting
.equ LS_DEPTH,  256                     # branches open at once
.equ LT_SZ,     80                      # turtle: pos, H, L, U (16 each), radius

.section .bss
.align 16
ls_rule:        .skip 8*256             # per character: its replacement,
ls_rlen:        .skip 4*256             #  and its length (0: kept as it is)
ls_has:         .skip 256
.align 16
ls_t:           .skip LT_SZ             # the turtle
ls_sin:         .skip 4
ls_cos:         .skip 4
ls_step:        .skip 4
ls_open:        .skip 4
ls_sp:          .skip 4
ls_stack:       .skip 8
ls_cap:         .skip 4                 # points room
ls_tcap:        .skip 4                 # chains room
.text

# ls_rules(rsi=text "a=xyz; b=..") - the replacement table
ls_rules:
    lea     rdi, [rip+ls_has]
    xor     eax, eax
    mov     ecx, 256
    rep     stosb
    test    rsi, rsi
    jz      9f
1:  movzx   eax, byte ptr [rsi]
    test    eax, eax
    jz      9f
    cmp     al, ' '
    je      2f
    cmp     al, ';'
    je      2f
    cmp     al, ','
    je      2f
    cmp     al, 10
    je      2f
    cmp     byte ptr [rsi+1], '='       # c=...
    jne     2f
    mov     edx, eax
    lea     r8, [rsi+2]
    mov     rcx, r8
3:  movzx   eax, byte ptr [rcx]
    test    eax, eax
    jz      4f
    cmp     al, ';'
    je      4f
    cmp     al, ','
    je      4f
    cmp     al, 10
    je      4f
    inc     rcx
    jmp     3b
4:  lea     rax, [rip+ls_rule]
    mov     [rax+rdx*8], r8
    mov     rax, rcx
    sub     rax, r8
    lea     r9, [rip+ls_rlen]
    mov     [r9+rdx*4], eax
    lea     r9, [rip+ls_has]
    mov     byte ptr [r9+rdx], 1
    mov     rsi, rcx
    jmp     1b
2:  inc     rsi
    jmp     1b
9:  ret

# ls_rewrite(rsi=axiom, edx=iterations) -> rax = the string, ecx = length
#   (frame arena; stops early before outgrowing LS_CAP), 0 when no memory
ls_rewrite:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    mov     r12, rsi
    mov     r13d, edx
    lea     rdi, [rip+frame_arena]
    mov     esi, LS_CAP+16
    call    arena_alloc
    mov     rbx, rax
    lea     rdi, [rip+frame_arena]
    mov     esi, LS_CAP+16
    call    arena_alloc
    mov     r14, rax
    test    rbx, rbx
    jz      8f
    test    r14, r14
    jz      8f
    xor     ecx, ecx                    # the axiom
1:  mov     al, [r12+rcx]
    test    al, al
    jz      2f
    cmp     ecx, LS_CAP
    jae     2f
    mov     [rbx+rcx], al
    inc     ecx
    jmp     1b
2:  mov     r15d, ecx                   # length
.Llr_iter:
    test    r13d, r13d
    jle     7f
    dec     r13d
    xor     ecx, ecx                    # the new length first
    xor     edx, edx
3:  cmp     ecx, r15d
    jae     4f
    movzx   eax, byte ptr [rbx+rcx]
    lea     r8, [rip+ls_has]
    cmp     byte ptr [r8+rax], 0
    je      31f
    lea     r8, [rip+ls_rlen]
    add     edx, [r8+rax*4]
    jmp     32f
31: inc     edx
32: cmp     edx, LS_CAP
    ja      7f                          # too long: the last one stays
    inc     ecx
    jmp     3b
4:  xor     ecx, ecx
    xor     edx, edx
5:  cmp     ecx, r15d
    jae     6f
    movzx   eax, byte ptr [rbx+rcx]
    lea     r8, [rip+ls_has]
    cmp     byte ptr [r8+rax], 0
    je      51f
    lea     r8, [rip+ls_rule]
    mov     rsi, [r8+rax*8]
    lea     r8, [rip+ls_rlen]
    mov     r9d, [r8+rax*4]
    push    rcx
    lea     rdi, [r14+rdx]
    mov     ecx, r9d
    rep     movsb
    pop     rcx
    add     edx, r9d
    jmp     52f
51: mov     [r14+rdx], al
    inc     edx
52: inc     ecx
    jmp     5b
6:  xchg    rbx, r14
    mov     r15d, edx
    jmp     .Llr_iter
7:  mov     rax, rbx
    mov     ecx, r15d
    jmp     9f
8:  xor     eax, eax
    xor     ecx, ecx
9:  pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# ls_turn(edi=offset of a, esi=offset of b, xmm0=sin) - the turtle's axes a,
#   b turned in their plane: a' = a cos + b sin, b' = b cos - a sin
ls_turn:
    lea     rax, [rip+ls_t]
    shufps  xmm0, xmm0, 0
    movss   xmm1, [rip+ls_cos]
    shufps  xmm1, xmm1, 0
    movaps  xmm2, [rax+rdi]
    movaps  xmm3, [rax+rsi]
    movaps  xmm4, xmm2
    mulps   xmm4, xmm1
    movaps  xmm5, xmm3
    mulps   xmm5, xmm0
    addps   xmm4, xmm5
    mulps   xmm3, xmm1
    mulps   xmm2, xmm0
    subps   xmm3, xmm2
    movaps  [rax+rdi], xmm4
    movaps  [rax+rsi], xmm3
    ret

# ls_point - the turtle's position onto the open chain
ls_point:
    mov     eax, [rip+ch_total]
    cmp     eax, [rip+ls_cap]
    jae     9f
    imul    rax, rax, EP_SZ
    add     rax, [rip+ch_ep]
    lea     rcx, [rip+ls_t]
    mov     rdx, [rcx]
    mov     [rax], rdx
    mov     edx, [rcx+8]
    mov     [rax+8], edx
    mov     edx, [rcx+64]
    mov     [rax+12], edx
    mov     dword ptr [rax+16], 0
    inc     dword ptr [rip+ch_total]
    mov     eax, [rip+ch_n]
    dec     eax
    imul    rax, rax, CH_SZ
    add     rax, [rip+ch_tab]
    inc     dword ptr [rax+4]
9:  ret

# ls_build(rdi=axiom, rsi=rules, edx=iterations, xmm0=angle (degrees),
#   xmm1=step, xmm2=radius) -> rax = the mesh: lines, or tubes with a radius
ls_build:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    push    rbp
    sub     rsp, 40
    movss   [rsp], xmm0
    movss   [rsp+4], xmm1
    movss   [rsp+8], xmm2
    mov     r12, rdi
    mov     r13d, edx
    cmp     r13d, 0
    jge     1f
    xor     r13d, r13d
1:  cmp     r13d, 16
    jle     2f
    mov     r13d, 16
2:  call    ls_rules
    mov     rsi, r12
    mov     edx, r13d
    call    ls_rewrite
    test    rax, rax
    jz      .Llb_fail
    mov     r12, rax
    mov     r13d, ecx
    xor     ecx, ecx                    # room: a point per F plus a start
    xor     edx, edx                    #  per chain
3:  cmp     ecx, r13d
    jae     4f
    movzx   eax, byte ptr [r12+rcx]
    cmp     al, 'F'
    je      31f
    cmp     al, 'G'
    jne     32f
31: inc     edx
32: inc     ecx
    jmp     3b
4:  lea     eax, [rdx*2+16]
    mov     [rip+ls_cap], eax
    lea     eax, [rdx+16]
    mov     [rip+ls_tcap], eax
    mov     edi, [rip+ls_cap]
    imul    rsi, rdi, EP_SZ
    lea     rdi, [rip+frame_arena]
    call    arena_alloc
    test    rax, rax
    jz      .Llb_fail
    mov     [rip+ch_ep], rax
    mov     esi, [rip+ls_tcap]
    imul    rsi, rsi, CH_SZ
    lea     rdi, [rip+frame_arena]
    call    arena_alloc
    test    rax, rax
    jz      .Llb_fail
    mov     [rip+ch_tab], rax
    mov     esi, LS_DEPTH*LT_SZ
    lea     rdi, [rip+frame_arena]
    call    arena_alloc
    test    rax, rax
    jz      .Llb_fail
    mov     [rip+ls_stack], rax
    mov     dword ptr [rip+ch_n], 0
    mov     dword ptr [rip+ch_total], 0
    mov     dword ptr [rip+ls_open], 0
    mov     dword ptr [rip+ls_sp], 0
    lea     rdi, [rip+ls_t]             # at the origin, heading up
    lea     rsi, [rip+ls_t0]
    mov     ecx, LT_SZ
    rep     movsb
    movss   xmm0, [rsp+8]
    movss   [rip+ls_t+64], xmm0
    movss   xmm0, [rsp+4]
    movss   [rip+ls_step], xmm0
    movss   xmm0, [rsp]
    mulss   xmm0, [rip+ls_deg]
    call    sincos
    movss   [rip+ls_sin], xmm0
    movss   [rip+ls_cos], xmm1
    xor     ebx, ebx
.Llb_char:
    cmp     ebx, r13d
    jae     .Llb_mesh
    movzx   eax, byte ptr [r12+rbx]
    inc     ebx
    cmp     al, 'F'
    je      .Llb_draw
    cmp     al, 'G'
    je      .Llb_draw
    cmp     al, 'f'
    je      .Llb_move
    mov     edi, 16                     # H, L about U
    mov     esi, 32
    movss   xmm0, [rip+ls_sin]
    cmp     al, '+'
    je      .Llb_turn
    xorps   xmm0, [rip+ls_neg]
    cmp     al, '-'
    je      .Llb_turn
    mov     edi, 16                     # H, U about L
    mov     esi, 48
    movss   xmm0, [rip+ls_sin]
    cmp     al, '&'
    je      .Llb_turn
    xorps   xmm0, [rip+ls_neg]
    cmp     al, '^'
    je      .Llb_turn
    mov     edi, 32                     # L, U about H
    mov     esi, 48
    movss   xmm0, [rip+ls_sin]
    cmp     al, 92                      # (a backslash)
    je      .Llb_turn
    xorps   xmm0, [rip+ls_neg]
    cmp     al, '/'
    je      .Llb_turn
    cmp     al, '|'
    je      .Llb_back
    cmp     al, '['
    je      .Llb_push
    cmp     al, ']'
    je      .Llb_pop
    cmp     al, '!'
    je      .Llb_thin
    jmp     .Llb_char
.Llb_turn:
    call    ls_turn
    jmp     .Llb_char
.Llb_back:
    lea     rax, [rip+ls_t]
    movaps  xmm0, [rax+16]
    xorps   xmm0, [rip+ls_negv]
    movaps  [rax+16], xmm0
    movaps  xmm0, [rax+32]
    xorps   xmm0, [rip+ls_negv]
    movaps  [rax+32], xmm0
    jmp     .Llb_char
.Llb_thin:
    movss   xmm0, [rip+ls_t+64]
    mulss   xmm0, [rip+ls_thin]
    movss   [rip+ls_t+64], xmm0
    jmp     .Llb_char
.Llb_draw:
    cmp     dword ptr [rip+ls_open], 0
    jne     1f
    mov     eax, [rip+ch_n]             # a new chain from here
    cmp     eax, [rip+ls_tcap]
    jae     .Llb_mesh
    imul    rax, rax, CH_SZ
    add     rax, [rip+ch_tab]
    mov     ecx, [rip+ch_total]
    mov     [rax], ecx
    mov     qword ptr [rax+4], 0
    inc     dword ptr [rip+ch_n]
    call    ls_point
    mov     dword ptr [rip+ls_open], 1
1:  call    .Llb_fwd
    call    ls_point
    jmp     .Llb_char
.Llb_move:
    call    .Llb_fwd
    mov     dword ptr [rip+ls_open], 0
    jmp     .Llb_char
.Llb_fwd:                               # pos += H step
    lea     rax, [rip+ls_t]
    movss   xmm0, [rip+ls_step]
    shufps  xmm0, xmm0, 0
    mulps   xmm0, [rax+16]
    addps   xmm0, [rax]
    movaps  [rax], xmm0
    ret
.Llb_push:
    mov     dword ptr [rip+ls_open], 0
    mov     eax, [rip+ls_sp]
    cmp     eax, LS_DEPTH
    jae     .Llb_char
    imul    rdi, rax, LT_SZ
    add     rdi, [rip+ls_stack]
    lea     rsi, [rip+ls_t]
    mov     ecx, LT_SZ
    rep     movsb
    inc     dword ptr [rip+ls_sp]
    movss   xmm0, [rip+ls_t+64]         # branches are thinner
    mulss   xmm0, [rip+ls_thin]
    movss   [rip+ls_t+64], xmm0
    jmp     .Llb_char
.Llb_pop:
    mov     dword ptr [rip+ls_open], 0
    mov     eax, [rip+ls_sp]
    test    eax, eax
    jz      .Llb_char
    dec     eax
    mov     [rip+ls_sp], eax
    imul    rsi, rax, LT_SZ
    add     rsi, [rip+ls_stack]
    lea     rdi, [rip+ls_t]
    mov     ecx, LT_SZ
    rep     movsb
    jmp     .Llb_char
.Llb_mesh:
    xorps   xmm0, xmm0
    comiss  xmm0, [rsp+8]
    jae     1f
    mov     edi, 6                      # tubes: a hexagon scaled by the radius
    movss   xmm0, [rip+pg_one]
    call    prof_circle
    mov     rsi, rax
    xor     r8d, r8d
    call    ch_sweep
    jmp     .Llb_out
1:  call    ch_to_lines
    jmp     .Llb_out
.Llb_fail:
    xor     eax, eax
.Llb_out:
    add     rsp, 40
    pop     rbp
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

.section .rodata
.align 16
ls_t0:          .float 0, 0, 0, 0,  0, 1, 0, 0,  -1, 0, 0, 0,  0, 0, 1, 0,  0, 0, 0, 0
ls_negv:        .long 0x80000000, 0x80000000, 0x80000000, 0
ls_neg:         .long 0x80000000, 0, 0, 0
ls_deg:         .float 0.017453292
ls_thin:        .float 0.7
# presets: axiom, rules, angle
.align 8
ls_presets:     .quad lp_plant_a, lp_plant_r
                .float 25, 0
                .quad lp_bush_a, lp_bush_r
                .float 22.5, 0
                .quad lp_tree_a, lp_tree_r
                .float 22.5, 0
                .quad lp_koch_a, lp_koch_r
                .float 90, 0
lp_plant_a:     .asciz "X"
lp_plant_r:     .asciz "X=F+[[X]-X]-F[-FX]+X; F=FF"
lp_bush_a:      .asciz "A"
lp_bush_r:      .asciz "A=[&FA]/////[&FA]///////[&FA]; F=S/////F; S=F"
lp_tree_a:      .asciz "F"
lp_tree_r:      .asciz "F=FF-[-F+F+F]+[+F-F-F]"
lp_koch_a:      .asciz "F-F-F-F"
lp_koch_r:      .asciz "F=F-F+F+FF-F-F+F"
.text

# tg_lsystem(rsi=node) - Preset (plant, bush, tree, Koch island),
#   Iterations, Radius (0: lines), Step
tg_lsystem:
    cvttss2si eax, [rsi+ND_P]
    cmp     eax, 3
    jbe     1f
    xor     eax, eax
1:  imul    rax, rax, 24
    lea     rcx, [rip+ls_presets]
    add     rcx, rax
    cvttss2si edx, [rsi+ND_P+4]
    movss   xmm0, [rcx+16]
    movss   xmm1, [rsi+ND_P+12]
    movss   xmm2, [rsi+ND_P+8]
    mov     rdi, [rcx]
    mov     rsi, [rcx+8]
    jmp     ls_build

# -----------------------------------------------------------------------------
# Wave function collapse
# -----------------------------------------------------------------------------
.equ WF_MAXT,   16                      # tiles
.equ WF_MAXO,   64                      # options (tile x quarter turn)
.equ WF_MAXC,   32768                   # cells
.equ WF_TRIES,  20

.globl wf_tiles
.globl wf_nt
.globl wf_nx
.globl wf_ny
.globl wf_nz
.globl wf_seed

.section .bss
.align 8
wf_tiles:       .skip 4*WF_MAXT         # the tile objects (handles)
wf_nt:          .skip 4
wf_nx:          .skip 4                 # cells along X, Z, and layers (Y)
wf_nz:          .skip 4
wf_ny:          .skip 4
wf_seed:        .skip 4
wf_no:          .skip 4                 # options
wf_rng:         .skip 4
wf_nc:          .skip 4                 # cells
wf_sp:          .skip 4
.align 8
wf_otile:       .skip WF_MAXO
wf_orot:        .skip WF_MAXO
.align 8
wf_sig:         .skip 8*6*WF_MAXO       # per option and side: the face hash
wf_comp:        .skip 8*6*WF_MAXO       # per option and side: who fits there
wf_cell:        .skip 8                 # the cells' masks
wf_stack:       .skip 8
wf_buf:         .skip 8                 # polygon corners
.align 16
wf_mat:         .skip 48*WF_MAXT        # each tile's turn and scale (no place)
wf_tv:          .skip 16
.text

# wf_tv_of(rsi=a vertex, ecx=tile) -> xmm0..2 = it through the tile's matrix
wf_tv_of:
    imul    rdi, rcx, 48
    lea     rax, [rip+wf_mat]
    add     rdi, rax
    lea     rdx, [rip+wf_tv]
    call    xform_point
    movss   xmm0, [rip+wf_tv]
    movss   xmm1, [rip+wf_tv+4]
    movss   xmm2, [rip+wf_tv+8]
    ret

# wf_rot(xmm0=x, xmm2=z, ecx=quarter turns) -> xmm0, xmm2 turned about Y
wf_rot:
    test    ecx, ecx
    jz      9f
1:  movaps  xmm3, xmm0                  # (x, z) -> (z, -x)
    movaps  xmm0, xmm2
    xorps   xmm2, xmm2
    subss   xmm2, xmm3
    dec     ecx
    jnz     1b
9:  ret

# wf_key(xmm0=a, xmm1=b) -> rax = a hash of the point quantized to 1/64
wf_key:
    mulss   xmm0, [rip+wf_q]
    mulss   xmm1, [rip+wf_q]
    cvtss2si eax, xmm0
    cvtss2si ecx, xmm1
    shl     rax, 32
    or      rax, rcx
    mov     rcx, 0x9E3779B97F4A7C15     # splitmix64
    add     rax, rcx
    mov     rcx, rax
    shr     rcx, 30
    xor     rax, rcx
    mov     rcx, 0xBF58476D1CE4E5B9
    imul    rax, rcx
    mov     rcx, rax
    shr     rcx, 27
    xor     rax, rcx
    mov     rcx, 0x94D049BB133111EB
    imul    rax, rcx
    mov     rcx, rax
    shr     rcx, 31
    xor     rax, rcx
    ret

# wf_near(xmm0=value, xmm1=target) -> ZF clear... eax = 1 when within 1/1000
wf_near:
    subss   xmm0, xmm1
    andps   xmm0, [rip+pg_absm]
    xor     eax, eax
    comiss  xmm0, [rip+wf_eps]
    setb    al
    ret

# wf_sigs(rdi=mesh, ecx=turns, rdx=out 6 hashes, r8d=tile) - each side's
#   face points
wf_sigs:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    sub     rsp, 32
    mov     rbx, rdi
    mov     r12d, ecx
    mov     r13, rdx
    mov     [rsp+16], r8d
    xor     eax, eax
    mov     rdi, r13
    mov     ecx, 6
    rep     stosq
    xor     r14d, r14d
.Lws_v:
    cmp     r14d, [rbx+ME_NVERTS]
    jae     .Lws_out
    imul    rsi, r14, 12
    add     rsi, [rbx+ME_POS]
    mov     ecx, [rsp+16]
    call    wf_tv_of
    mov     ecx, r12d
    call    wf_rot
    movss   [rsp], xmm0                 # x y z, turned
    movss   [rsp+4], xmm1
    movss   [rsp+8], xmm2
    xor     r15d, r15d                  # side
.Lws_side:
    cmp     r15d, 6
    jae     .Lws_nv
    lea     rax, [rip+wf_sides]         # coordinate, its value, key a, key b
    imul    ecx, r15d, 16
    add     rax, rcx
    mov     ecx, [rax]
    movss   xmm0, [rsp+rcx*4]
    movss   xmm1, [rax+4]
    push    rax
    sub     rsp, 8
    call    wf_near
    add     rsp, 8
    pop     rcx
    test    eax, eax
    jz      1f
    mov     eax, [rcx+8]
    movss   xmm0, [rsp+rax*4]
    mov     eax, [rcx+12]
    movss   xmm1, [rsp+rax*4]
    call    wf_key
    add     [r13+r15*8], rax
1:  inc     r15d
    jmp     .Lws_side
.Lws_nv:
    inc     r14d
    jmp     .Lws_v
.Lws_out:
    add     rsp, 32
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# wf_options -> eax = options made (tiles x distinct turns)
wf_options:
    push    rbx
    push    r12
    push    r13
    push    r14
    sub     rsp, 8
    mov     dword ptr [rip+wf_no], 0
    xor     r12d, r12d                  # tile
.Lwo_t:
    cmp     r12d, [rip+wf_nt]
    jae     .Lwo_out
    lea     rax, [rip+wf_tiles]
    mov     edi, [rax+r12*4]
    call    obj_get
    test    rax, rax
    jz      .Lwo_nt
    mov     rbx, rax
    imul    rsi, r12, 48                # its matrix without the place
    lea     rax, [rip+wf_mat]
    add     rsi, rax
    mov     rdi, rbx
    push    rsi
    sub     rsp, 8
    call    obj_matrix
    add     rsp, 8
    pop     rsi
    xor     eax, eax
    mov     [rsi+12], eax
    mov     [rsi+28], eax
    mov     [rsi+44], eax
    mov     rbx, [rbx+OB_MESH]
    test    rbx, rbx
    jz      .Lwo_nt
    xor     r13d, r13d                  # turn
.Lwo_r:
    cmp     r13d, 4
    jae     .Lwo_nt
    mov     eax, [rip+wf_no]
    cmp     eax, WF_MAXO
    jae     .Lwo_out
    imul    rdx, rax, 48
    lea     rcx, [rip+wf_sig]
    add     rdx, rcx
    mov     r14, rdx
    mov     rdi, rbx
    mov     ecx, r13d
    mov     r8d, r12d
    call    wf_sigs
    xor     ecx, ecx                    # the same as a turn already there?
1:  cmp     ecx, [rip+wf_no]
    jae     3f
    lea     rax, [rip+wf_otile]
    movzx   eax, byte ptr [rax+rcx]
    cmp     eax, r12d
    jne     2f
    imul    rsi, rcx, 48
    lea     rax, [rip+wf_sig]
    add     rsi, rax
    mov     rdi, r14
    push    rcx
    mov     ecx, 6
    repe    cmpsq
    pop     rcx
    je      .Lwo_nr
2:  inc     ecx
    jmp     1b
3:  mov     eax, [rip+wf_no]
    lea     rcx, [rip+wf_otile]
    mov     [rcx+rax], r12b
    lea     rcx, [rip+wf_orot]
    mov     [rcx+rax], r13b
    inc     dword ptr [rip+wf_no]
.Lwo_nr:
    inc     r13d
    jmp     .Lwo_r
.Lwo_nt:
    inc     r12d
    jmp     .Lwo_t
.Lwo_out:
    mov     eax, [rip+wf_no]            # who fits: side d against side d ^ 1
    xor     ecx, ecx
4:  cmp     ecx, eax
    jae     8f
    xor     edx, edx                    # side
5:  cmp     edx, 6
    jae     7f
    xor     r8d, r8d                    # mask
    imul    r9, rcx, 48
    lea     r10, [rip+wf_sig]
    add     r9, r10
    mov     r11, [r9+rdx*8]
    mov     esi, edx
    xor     esi, 1
    xor     edi, edi
6:  cmp     edi, eax
    jae     61f
    imul    r9, rdi, 48
    add     r9, r10
    cmp     [r9+rsi*8], r11
    jne     62f
    bts     r8, rdi
62: inc     edi
    jmp     6b
61: imul    r9, rcx, 48
    lea     r10, [rip+wf_comp]
    add     r9, r10
    mov     [r9+rdx*8], r8
    inc     edx
    jmp     5b
7:  inc     ecx
    jmp     4b
8:  add     rsp, 8
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# wf_neighbour(eax=cell, ecx=side) -> eax = the cell beside it (-1: none)
wf_neighbour:
    push    rbx
    mov     ebx, ecx
    xor     edx, edx                    # x, then z, then layer
    mov     ecx, [rip+wf_nx]
    div     ecx
    mov     r8d, edx                    # x
    xor     edx, edx
    mov     ecx, [rip+wf_nz]
    div     ecx
    mov     r9d, edx                    # z
    mov     r10d, eax                   # y
    cmp     ebx, 0
    jne     1f
    inc     r8d
1:  cmp     ebx, 1
    jne     2f
    dec     r8d
2:  cmp     ebx, 2
    jne     3f
    inc     r10d
3:  cmp     ebx, 3
    jne     4f
    dec     r10d
4:  cmp     ebx, 4
    jne     5f
    inc     r9d
5:  cmp     ebx, 5
    jne     6f
    dec     r9d
6:  cmp     r8d, [rip+wf_nx]
    jae     8f
    cmp     r9d, [rip+wf_nz]
    jae     8f
    cmp     r10d, [rip+wf_ny]
    jae     8f
    mov     eax, r10d
    imul    eax, [rip+wf_nz]
    add     eax, r9d
    imul    eax, [rip+wf_nx]
    add     eax, r8d
    pop     rbx
    ret
8:  mov     eax, -1
    pop     rbx
    ret

# wf_propagate -> eax = 1, or 0 on a contradiction (the stack's cells
#   narrow their neighbours until nothing changes)
wf_propagate:
    push    rbx
    push    r12
    push    r13
    push    r14
.Lwp_pop:
    mov     eax, [rip+wf_sp]
    test    eax, eax
    jz      .Lwp_ok
    dec     eax
    mov     [rip+wf_sp], eax
    mov     rcx, [rip+wf_stack]
    mov     r12d, [rcx+rax*4]           # the cell
    mov     rcx, [rip+wf_cell]
    mov     r13, [rcx+r12*8]            # its options
    xor     ebx, ebx                    # side
.Lwp_side:
    cmp     ebx, 6
    jae     .Lwp_pop
    xor     r14d, r14d                  # allowed beside it
    mov     rdx, r13
    lea     r8, [rip+wf_comp]
1:  test    rdx, rdx
    jz      2f
    tzcnt   rax, rdx
    btr     rdx, rax
    imul    rax, rax, 48
    add     rax, r8
    or      r14, [rax+rbx*8]
    jmp     1b
2:  mov     eax, r12d
    mov     ecx, ebx
    call    wf_neighbour
    test    eax, eax
    js      3f
    mov     rcx, [rip+wf_cell]
    mov     rdx, [rcx+rax*8]
    mov     r8, rdx
    and     r8, r14
    cmp     r8, rdx
    je      3f
    test    r8, r8
    jz      .Lwp_bad
    mov     [rcx+rax*8], r8
    mov     ecx, [rip+wf_sp]            # its neighbours next
    mov     rdx, [rip+wf_stack]
    mov     [rdx+rcx*4], eax
    inc     dword ptr [rip+wf_sp]
3:  inc     ebx
    jmp     .Lwp_side
.Lwp_ok:
    mov     eax, 1
    jmp     9f
.Lwp_bad:
    xor     eax, eax
9:  pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# wf_solve -> eax = 1 when every cell has one option left
wf_solve:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    mov     rax, -1                     # everything possible
    mov     ecx, [rip+wf_no]
    cmp     ecx, 64
    jae     1f
    mov     eax, 1
    shl     rax, cl
    dec     rax
1:  mov     rdi, [rip+wf_cell]
    mov     ecx, [rip+wf_nc]
    rep     stosq
.Lwv_step:
    mov     r12d, -1                    # the cell with fewest (ties: random)
    mov     r13, -1
    xor     ebx, ebx
2:  cmp     ebx, [rip+wf_nc]
    jae     3f
    mov     rcx, [rip+wf_cell]
    popcnt  rax, [rcx+rbx*8]
    cmp     eax, 1
    jbe     21f
    shl     rax, 32
    lea     rdi, [rip+wf_rng]
    push    rax
    call    pg_rand
    pop     rcx
    or      rax, rcx
    cmp     rax, r13
    jae     21f
    mov     r13, rax
    mov     r12d, ebx
21: inc     ebx
    jmp     2b
3:  test    r12d, r12d
    js      .Lwv_done
    mov     rcx, [rip+wf_cell]          # one of its options at random
    mov     r14, [rcx+r12*8]
    popcnt  rbx, r14
    lea     rdi, [rip+wf_rng]
    call    pg_rand
    xor     edx, edx
    div     ebx
4:  tzcnt   rax, r14
    test    edx, edx
    jz      5f
    btr     r14, rax
    dec     edx
    jmp     4b
5:  xor     r15d, r15d
    bts     r15, rax
    mov     rcx, [rip+wf_cell]
    mov     [rcx+r12*8], r15
    mov     rdx, [rip+wf_stack]
    mov     [rdx], r12d
    mov     dword ptr [rip+wf_sp], 1
    call    wf_propagate
    test    eax, eax
    jnz     .Lwv_step
    xor     eax, eax
    jmp     9f
.Lwv_done:
    mov     eax, 1
9:  pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# wf_mesh -> rax = the tiles placed in their cells, joined (cells centred on
#   the origin in X and Z, layers upwards), or 0
wf_mesh:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    push    rbp
    sub     rsp, 56
    xor     r12d, r12d                  # vertices, loops, polygons
    xor     r13d, r13d
    xor     r14d, r14d
    xor     ebx, ebx
1:  cmp     ebx, [rip+wf_nc]
    jae     2f
    mov     eax, ebx
    call    wf_cell_mesh
    test    rax, rax
    jz      11f
    add     r12d, [rax+ME_NVERTS]
    add     r13d, [rax+ME_NLOOPS]
    add     r14d, [rax+ME_NPOLYS]
11: inc     ebx
    jmp     1b
2:  cmp     r12d, 50000000
    ja      .Lwm_fail
    lea     edi, [r12+1]
    lea     esi, [r13+1]
    lea     edx, [r14+1]
    call    mesh_new
    test    rax, rax
    jz      .Lwm_fail
    mov     rbp, rax
    xor     ebx, ebx
.Lwm_cell:
    cmp     ebx, [rip+wf_nc]
    jae     .Lwm_done
    mov     eax, ebx
    call    wf_cell_mesh
    test    rax, rax
    jz      .Lwm_ncell
    mov     r12, rax                    # the tile's mesh, ecx = its turns
    mov     [rsp], ecx
    mov     [rsp+20], edx               # (which tile)
    mov     eax, ebx                    # the cell's place
    xor     edx, edx
    mov     ecx, [rip+wf_nx]
    div     ecx
    cvtsi2ss xmm0, edx
    cvtsi2ss xmm1, ecx
    subss   xmm1, [rip+pg_one]
    mulss   xmm1, [rip+pg_half]
    subss   xmm0, xmm1
    movss   [rsp+4], xmm0               # x
    xor     edx, edx
    mov     ecx, [rip+wf_nz]
    div     ecx
    cvtsi2ss xmm0, edx
    cvtsi2ss xmm1, ecx
    subss   xmm1, [rip+pg_one]
    mulss   xmm1, [rip+pg_half]
    subss   xmm0, xmm1
    movss   [rsp+12], xmm0              # z
    cvtsi2ss xmm0, eax
    movss   [rsp+8], xmm0               # y
    mov     eax, [rbp+ME_NVERTS]
    mov     [rsp+16], eax               # base
    xor     r13d, r13d
3:  cmp     r13d, [r12+ME_NVERTS]
    jae     4f
    imul    rsi, r13, 12
    add     rsi, [r12+ME_POS]
    mov     ecx, [rsp+20]
    call    wf_tv_of
    mov     ecx, [rsp]
    call    wf_rot
    addss   xmm0, [rsp+4]
    addss   xmm1, [rsp+8]
    addss   xmm2, [rsp+12]
    mov     rdi, rbp
    call    mesh_add_vert
    inc     r13d
    jmp     3b
4:  xor     r13d, r13d                  # polygons, their corners moved on
5:  cmp     r13d, [r12+ME_NPOLYS]
    jae     .Lwm_ncell
    mov     rax, [r12+ME_POFF]
    mov     ecx, [rax+r13*4]
    mov     edx, [rax+r13*4+4]
    sub     edx, ecx
    cmp     edx, 4096
    ja      7f
    mov     rsi, [r12+ME_LOOPS]
    mov     rdi, [rip+wf_buf]
    xor     r8d, r8d
6:  cmp     r8d, edx
    jae     61f
    lea     eax, [rcx+r8]
    mov     eax, [rsi+rax*4]
    add     eax, [rsp+16]
    mov     [rdi+r8*4], eax
    inc     r8d
    jmp     6b
61: mov     rsi, rdi
    mov     rdi, rbp
    call    mesh_add_poly
7:  inc     r13d
    jmp     5b
.Lwm_ncell:
    inc     ebx
    jmp     .Lwm_cell
.Lwm_done:
    mov     rdi, rbp
    call    mesh_finish
    mov     rax, rbp
    jmp     9f
.Lwm_fail:
    xor     eax, eax
9:  add     rsp, 56
    pop     rbp
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# wf_cell_mesh(eax=cell) -> rax = its tile's mesh (0: none), ecx = turns,
#   edx = the tile
wf_cell_mesh:
    mov     rcx, [rip+wf_cell]
    mov     rcx, [rcx+rax*8]
    tzcnt   rax, rcx
    cmp     eax, 64
    jae     8f
    lea     rcx, [rip+wf_orot]
    movzx   ecx, byte ptr [rcx+rax]
    push    rcx
    lea     rdx, [rip+wf_otile]
    movzx   eax, byte ptr [rdx+rax]
    push    rax
    lea     rdx, [rip+wf_tiles]
    mov     edi, [rdx+rax*4]
    call    obj_get
    pop     rdx
    pop     rcx
    test    rax, rax
    jz      9f
    mov     rax, [rax+OB_MESH]
    ret
8:  xor     eax, eax
9:  ret

# wfc_run(rdi=name) - wf_* set: the grid solved (up to 20 seeds) and made an
#   object -> eax = its handle, 0 when it cannot be solved
wfc_run:
    push    rbx
    push    r12
    push    r13
    mov     r12, rdi
    call    wf_options
    test    eax, eax
    jz      8f
    mov     eax, [rip+wf_nx]            # cells
    imul    eax, [rip+wf_nz]
    jo      8f
    imul    eax, [rip+wf_ny]
    jo      8f
    test    eax, eax
    jle     8f
    cmp     eax, WF_MAXC
    ja      8f
    mov     [rip+wf_nc], eax
    lea     esi, [rax*8+16]
    lea     rdi, [rip+frame_arena]
    call    arena_alloc
    test    rax, rax
    jz      8f
    mov     [rip+wf_cell], rax
    mov     esi, [rip+wf_nc]
    shl     esi, 8                      # (64 narrowings a cell at most)
    add     esi, 64
    lea     rdi, [rip+frame_arena]
    call    arena_alloc
    test    rax, rax
    jz      8f
    mov     [rip+wf_stack], rax
    mov     esi, 4096*4
    lea     rdi, [rip+frame_arena]
    call    arena_alloc
    test    rax, rax
    jz      8f
    mov     [rip+wf_buf], rax
    xor     r13d, r13d
1:  cmp     r13d, WF_TRIES
    jae     8f
    mov     eax, [rip+wf_seed]
    add     eax, r13d
    imul    eax, eax, 0x9E3779B1
    or      eax, 1
    mov     [rip+wf_rng], eax
    call    wf_solve
    test    eax, eax
    jnz     2f
    inc     r13d
    jmp     1b
2:  call    wf_mesh
    test    rax, rax
    jz      8f
    mov     edi, OT_MESH
    mov     rsi, r12
    mov     rdx, rax
    call    obj_new
    jmp     9f
8:  xor     eax, eax
9:  pop     r13
    pop     r12
    pop     rbx
    ret

.section .rodata
.align 4
wf_q:           .float 64.0
wf_eps:         .float 0.001
# per side: the coordinate tested, its value, the key's two coordinates
wf_sides:       .long 0
                .float 0.5
                .long 1, 2
                .long 0
                .float -0.5
                .long 1, 2
                .long 1
                .float 0.5
                .long 0, 2
                .long 1
                .float -0.5
                .long 0, 2
                .long 2
                .float 0.5
                .long 0, 1
                .long 2
                .float -0.5
                .long 0, 1
.text
