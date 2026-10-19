# =============================================================================
#  BeeModel - the liquid solver (stage P4): position-based fluids.
#
#  A particle system with liquid on is water (or oil, or honey): each frame
#  its particles (gathered by particles.s into lq_x, lq_v) are moved in a
#  few substeps. Each substep:
#    predict    v += a dt, p = x + v dt
#    neighbours a hash grid of cells the kernel's size (counting sort, in
#               the particles' order), up to 64 neighbours each within h
#    iterations density constraints (Macklin & Muller 2013): lambda_i =
#               -C_i / (sum |grad C|^2 + eps), C = rho / rho0 - 1 (not below
#               0); dp_i = (m / rho0) sum (lambda_i + lambda_j + s_corr)
#               grad W (s_corr: the tensile term, surface tension); then the
#               domain box, and moving rigid bodies push the liquid out and
#               are pushed back (their impulses summed per chunk, in order)
#    colliders  the step's path cast against the ground, landscapes and
#               triangles (particles.s pc_cast)
#    velocity   v = (p - x) / dt, XSPH viscosity, vorticity confinement
#  The kernels are poly6 for density and spiky for gradients, h = 2 x the
#  spacing; the particles' mass makes a lattice at that spacing exactly the
#  rest density. Everything per particle runs in parallel; the sums are in
#  a fixed order, so the same on any number of threads.
# =============================================================================
.intel_syntax noprefix
.include "const.inc"
.include "macros.inc"

.globl lq_room
.globl lq_solve
.globl lq_x
.globl lq_v
.globl lq_info
.globl lq_reset
.globl lq_nn

.equ LQ_MAXN,   4194304
.equ NB,        96                      # neighbours at most
.equ GRAIN,     2048
.equ MAXB,      16                      # moving bodies the liquid pushes
.equ MAXCH,     LQ_MAXN/GRAIN           # chunks (impulse sums)
.equ WT,        32                      # the walls' table: steps over h
.equ MAXW,      8                       # walls
.equ MAP_NORES, 0x4022
# the record's liquid settings (const.inc PS_*)

.macro DOT3 d, s
    dpps    \d, \s, 0x71
.endm
.macro CROSS d, a, b, t
    movaps  \d, \b
    shufps  \d, \d, 0xC9
    mulps   \d, \a
    movaps  \t, \a
    shufps  \t, \t, 0xC9
    mulps   \t, \b
    subps   \d, \t
    shufps  \d, \d, 0xC9
.endm
.macro LQPTR reg, arr, idx              # &arr[idx] (vec4 arrays)
    mov     \reg, \idx
    shl     \reg, 4
    add     \reg, [rip+\arr]
.endm

.section .bss
.align 16
lq_acc:         .skip 16                # gravity x its factor
lq_gadj:        .skip 16                # gravity x (factor - 1)
lq_dmin:        .skip 16                # the domain (+/- a particle's radius)
lq_dmax:        .skip 16
lq_bc:          .skip 16*MAXB           # each body: its centre, half size
lq_bh:          .skip 16*MAXB           #  (w: its rounding), rotation rows
lq_br:          .skip 48*MAXB
lq_bmin:        .skip 16*MAXB           #  bounds (grown by a radius)
lq_bmax:        .skip 16*MAXB
lq_bc0:         .skip 16*MAXB           # where each was the frame before
lq_bc1:         .skip 16*MAXB           #  and is now
lq_pc:          .skip 16*MAXB           # (kept: the last frame's centres)
lq_pobj:        .skip 8*MAXB
lq_wall:        .skip 16*MAXW           # each wall: its normal into the liquid
                                        #  (w: its offset: s = n.p - w)
lq_wd:          .skip 4*(WT+2)          # a wall's density at s (sum of W),
lq_wg:          .skip 4*(WT+2)          #  its grad W along the normal
.align 8
lq_x:           .skip 8                 # positions, velocities (vec4)
lq_v:           .skip 8
lq_p:           .skip 8                 # predicted
lq_dp:          .skip 8
lq_w:           .skip 8                 # vorticity
lq_v2:          .skip 8
lq_lam:         .skip 8                 # f32
lq_rho:         .skip 8
lq_cell:        .skip 8                 # u32: the bucket
lq_sort:        .skip 8                 #  particles by bucket
lq_start:       .skip 8                 #  each bucket's first (u32, table + 1)
lq_nb:          .skip 8                 # neighbours (NB u32 each)
lq_nn:          .skip 8                 #  how many
lq_imp:         .skip 8                 # impulses: chunk x body (vec4)
lq_bobj:        .skip 8*MAXB            # each body's object
lq_bptr:        .skip 8*MAXB            #  and itself (rbody.s)
.align 4
lq_cap:         .skip 4
lq_n:           .skip 4
lq_mask:        .skip 4                 # buckets - 1
lq_h:           .skip 4
lq_h2:          .skip 4
lq_ih:          .skip 4
lq_k6:          .skip 4
lq_ks:          .skip 4
lq_m:           .skip 4                 # mass
lq_mr:          .skip 4                 # mass / rest density
lq_rho0:        .skip 4
lq_eps:         .skip 4
lq_wdq:         .skip 4                 # W(0.2 h)
lq_tk:          .skip 4                 # the tensile term's k
lq_dt:          .skip 4                 # the substep
lq_idt:         .skip 4
lq_rp:          .skip 4                 # a particle's radius
lq_dom:         .skip 4
lq_visc:        .skip 4
lq_vort:        .skip 4
lq_fields:      .skip 4
lq_gbit:        .skip 4
lq_nbd:         .skip 4                 # bodies
lq_ms:          .skip 4                 # the last solve (ms)
lq_nmax:        .skip 4                 # the most neighbours a particle had
lq_nw:          .skip 4                 # walls
lq_np:          .skip 4                 # (kept centres)
lq_rmax:        .skip 4                 # the densest (rho / rho0, the last substep's
                                        #  last iteration; a statistic)
lq_rmaxi:       .skip 4
.align 8
lq_tjob:        .skip 8                 # (time in the jobs, ns)
.align 4
lq_fdt:         .skip 4                 # the frame's step

.section .rodata
.align 16
lq_xyz:         .long -1, -1, -1, 0
lq_abs:         .long 0x7fffffff, 0x7fffffff, 0x7fffffff, 0
lq_sgn:         .long 0x80000000, 0x80000000, 0x80000000, 0
lq_one4:        .float 1, 1, 1, 0
lq_c128:        .float 128, 128, 128, 128
.align 4
lq_pi:          .float 3.14159265
lq_315:         .float 315.0
lq_64:          .float 64.0
lq_45:          .float 45.0
lq_onef:        .float 1.0
lq_two:         .float 2.0
lq_02:          .float 0.2
lq_epsk:        .float 0.01
lq_tiny:        .float 1.0e-12
lq_apk:         .float 0.001
lq_r2min:       .float 1.0e-10
lq_k:           .float 0.001
lq_d1000:       .float 1000.0
lq_pushk:       .float 1.0
lq_hx:          .long 73856093
lq_hy:          .long 19349663
lq_hz:          .long 83492791

.text

# lq_map(rsi=bytes) -> rax (0: none)
lq_map:
    xor     edi, edi
    mov     edx, PROT_RW
    mov     r10d, MAP_NORES
    mov     r8, -1
    xor     r9d, r9d
    mov     eax, SYS_MMAP
    syscall
    cmp     rax, -4096
    jb      1f
    xor     eax, eax
1:  ret

# lq_room(edi=particles) -> eax = 1 when the arrays have room for them
lq_room:
    cmp     edi, LQ_MAXN
    ja      8f
    cmp     dword ptr [rip+lq_cap], 0
    jne     7f
    push    rbx
    lea     rbx, [rip+lq_tab]
1:  mov     rax, [rbx]                  # (each array: where, bytes a particle)
    test    rax, rax
    jz      2f
    mov     esi, [rbx+8]
    imul    rsi, rsi, LQ_MAXN
    add     rsi, 4096
    push    rax
    call    lq_map
    pop     rcx
    test    rax, rax
    jz      3f
    mov     [rcx], rax
    add     rbx, 16
    jmp     1b
2:  mov     esi, MAXCH*MAXB*16
    call    lq_map
    test    rax, rax
    jz      3f
    mov     [rip+lq_imp], rax
    mov     dword ptr [rip+lq_cap], LQ_MAXN
    pop     rbx
7:  mov     eax, 1
    ret
3:  pop     rbx
8:  xor     eax, eax
    ret

.section .rodata
.align 8
lq_tab:         .quad lq_x, 16, lq_v, 16, lq_p, 16, lq_dp, 16, lq_w, 16, lq_v2, 16
                .quad lq_lam, 4, lq_rho, 4, lq_cell, 4, lq_sort, 4, lq_start, 16
                .quad lq_nb, NB*4, lq_nn, 4, 0, 0
.text

# lq_info(edi=k) -> xmm0: 0 the last solve (ms), 1 the most neighbours, 2
#   the mass, 3 the kernel's size
lq_info:
    xorps   xmm0, xmm0
    cmp     edi, 0
    jne     1f
    movss   xmm0, [rip+lq_ms]
    ret
1:  cmp     edi, 1
    jne     2f
    cvtsi2ss xmm0, dword ptr [rip+lq_nmax]
    ret
2:  cmp     edi, 2
    jne     3f
    movss   xmm0, [rip+lq_m]
    ret
3:  cmp     edi, 3
    jne     4f
    movss   xmm0, [rip+lq_h]
    ret
4:  cmp     edi, 4
    jne     5f
    movss   xmm0, [rip+lq_rmax]
    ret
5:  cmp     edi, 8                      # 8: the jobs' share (ms)
    jne     51f
    cvtsi2ss xmm0, qword ptr [rip+lq_tjob]
    mulss   xmm0, [rip+lq_k]
    mulss   xmm0, [rip+lq_k]
    ret
51: cmp     edi, 7                      # 5..7: where the densest is
    ja      6f
    mov     eax, [rip+lq_rmaxi]
    shl     rax, 4
    add     rax, [rip+lq_x]
    sub     edi, 5
    movss   xmm0, [rax+rdi*4]
6:  ret

# w6(xmm0=r^2) -> xmm0 = poly6 W (0 past h) (leaf: xmm1)
w6:
    movss   xmm1, [rip+lq_h2]
    subss   xmm1, xmm0
    xorps   xmm0, xmm0
    comiss  xmm1, xmm0
    jbe     1f
    movss   xmm0, xmm1
    mulss   xmm0, xmm1
    mulss   xmm0, xmm1
    mulss   xmm0, [rip+lq_k6]
1:  ret

# apart(r12d=i, r8d=j, xmm9=p_i - p_j, xmm10=its length squared; xmm0 =
#   the same) - two at one place get a small way apart (odd in i - j: the
#   pair's two sides agree) (leaf: xmm1 xmm2, ecx, edx, r9)
apart:
    comiss  xmm10, [rip+lq_r2min]
    jae     9f
    mov     ecx, r12d
    sub     ecx, r8d
    mov     edx, ecx
    sar     edx, 31                     # the sign
    xor     ecx, edx
    sub     ecx, edx                    # |i - j|
    imul    ecx, ecx, -1640531535
    mov     r9d, ecx
    and     r9d, 255
    cvtsi2ss xmm9, r9d
    shr     ecx, 8
    mov     r9d, ecx
    and     r9d, 255
    cvtsi2ss xmm1, r9d
    shr     ecx, 8
    and     ecx, 255
    cvtsi2ss xmm2, ecx
    unpcklps xmm9, xmm1
    movlhps xmm9, xmm2
    subps   xmm9, [rip+lq_c128]
    andps   xmm9, [rip+lq_xyz]
    test    edx, edx
    jz      1f
    xorps   xmm9, [rip+lq_sgn]
1:  movss   xmm1, [rip+lq_apk]          # length: 1/1000 of h
    mulss   xmm1, [rip+lq_h]
    divss   xmm1, [rip+lq_c128]
    shufps  xmm1, xmm1, 0
    mulps   xmm9, xmm1
    andps   xmm9, [rip+lq_xyz]
    movaps  xmm10, xmm9
    DOT3    xmm10, xmm10
    maxss   xmm10, [rip+lq_tiny]
    movss   xmm0, xmm10
9:  ret

# gw(xmm0=d (vec4, p_i - p_j), xmm1=r) -> xmm0 = spiky grad W (vec4) (leaf:
#   xmm2)
gw:
    movss   xmm2, [rip+lq_h]
    subss   xmm2, xmm1
    mulss   xmm2, xmm2
    mulss   xmm2, [rip+lq_ks]
    maxss   xmm1, [rip+lq_tiny]
    divss   xmm2, xmm1
    shufps  xmm2, xmm2, 0
    mulps   xmm0, xmm2
    andps   xmm0, [rip+lq_xyz]
    ret

# hash(xmm0=point) -> eax = its cell's bucket (leaf: xmm1, ecx, edx)
hash:
    movss   xmm1, [rip+lq_ih]
    shufps  xmm1, xmm1, 0
    mulps   xmm1, xmm0
    roundps xmm1, xmm1, 1
    cvtps2dq xmm1, xmm1
# hashc(xmm1=cell (ints)) -> eax
hashc:
    movd    eax, xmm1
    imul    eax, [rip+lq_hx]
    pshufd  xmm0, xmm1, 0x55
    movd    ecx, xmm0
    imul    ecx, [rip+lq_hy]
    xor     eax, ecx
    pshufd  xmm0, xmm1, 0xAA
    movd    ecx, xmm0
    imul    ecx, [rip+lq_hz]
    xor     eax, ecx
    and     eax, [rip+lq_mask]
    ret

# clampd(xmm0=point) -> xmm0 inside the domain (leaf)
clampd:
    cmp     dword ptr [rip+lq_dom], 0
    je      1f
    maxps   xmm0, [rip+lq_dmin]
    minps   xmm0, [rip+lq_dmax]
    andps   xmm0, [rip+lq_xyz]
1:  ret

# =============================================================================
#  lq_solve(edi=particles, rsi=its settings, xmm0=the frame's step (s),
#    rdx=gravity x factor (vec4), rcx=gravity x (factor - 1), r8d=its
#    group's bit) - lq_x and lq_v moved on
# =============================================================================
lq_solve:
    push    rbp
    mov     rbp, rsp
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    and     rsp, -16
    sub     rsp, 64
    mov     [rip+lq_n], edi
    mov     r12, rsi
    movss   [rsp], xmm0
    movss   [rip+lq_fdt], xmm0
    movups  xmm1, [rdx]
    andps   xmm1, [rip+lq_xyz]
    movaps  [rip+lq_acc], xmm1
    movups  xmm1, [rcx]
    andps   xmm1, [rip+lq_xyz]
    movaps  [rip+lq_gadj], xmm1
    mov     [rip+lq_gbit], r8d
    call    now_ns
    mov     [rsp+8], rax
    mov     qword ptr [rip+lq_tjob], 0
    mov     edi, [rip+lq_n]
    test    edi, edi
    jz      .Lls_time
    mov     eax, [rip+fl_n]
    mov     [rip+lq_fields], eax
    call    lq_consts
    call    lq_bodies
    mov     ecx, [rip+lq_n]             # buckets: a power of two, >= 2n
    shl     ecx, 1
    mov     eax, 1024
1:  cmp     eax, ecx
    jae     2f
    shl     eax, 1
    jmp     1b
2:  dec     eax
    mov     [rip+lq_mask], eax
    mov     rdi, [rip+lq_imp]           # no impulses yet
    mov     ecx, MAXCH*MAXB*4
    xor     eax, eax
    rep     stosd
    mov     ebx, [r12+PS_LSUB]          # substeps
    cmp     ebx, 1
    jge     3f
    mov     ebx, 1
3:  cmp     ebx, 32
    jle     4f
    mov     ebx, 32
4:  cvtsi2ss xmm1, ebx
    movss   xmm0, [rsp]
    divss   xmm0, xmm1
    movss   [rip+lq_dt], xmm0
    movss   xmm1, [rip+lq_onef]
    divss   xmm1, xmm0
    movss   [rip+lq_idt], xmm1
    mulss   xmm0, [rip+lq_v60]          # viscosity: per 1/60 s, whatever the
    mulss   xmm0, [r12+PS_VISC]         #  substeps
    movss   [rip+lq_visc], xmm0
    mov     dword ptr [rip+lq_nmax], 0
    mov     r14d, ebx                   # (K)
.Lls_sub:
    test    ebx, ebx
    jz      .Lls_done
    dec     ebx
    mov     edi, r14d
    sub     edi, ebx
    dec     edi
    mov     esi, r14d
    call    lq_place_bodies
    lea     rdi, [rip+j_predict]
    call    lq_run
    lea     rdi, [rip+j_hash]
    call    lq_run
    call    lq_sort_cells
    lea     rdi, [rip+j_nbrs]
    call    lq_run
    mov     r13d, [r12+PS_LITER]        # iterations
    cmp     r13d, 1
    jge     5f
    mov     r13d, 1
5:  cmp     r13d, 50
    jle     6f
    mov     r13d, 50
6:  mov     dword ptr [rip+lq_rmax], 0
    lea     rdi, [rip+j_lambda]
    call    lq_run
    lea     rdi, [rip+j_delta]
    call    lq_run
    lea     rdi, [rip+j_apply]
    call    lq_run
    dec     r13d
    jnz     6b
    cmp     dword ptr [rip+pc_any], 0
    je      7f
    lea     rdi, [rip+j_collide]
    call    lq_run
7:  lea     rdi, [rip+j_vel]
    call    lq_run
    lea     rdi, [rip+j_xsph]
    call    lq_run
    xorps   xmm0, xmm0
    comiss  xmm0, [rip+lq_vort]
    jae     8f
    lea     rdi, [rip+j_vort]
    call    lq_run
8:  lea     rdi, [rip+j_commit]
    call    lq_run
    jmp     .Lls_sub
.Lls_done:
    call    lq_push_bodies
    call    lq_keep
.Lls_time:
    call    now_ns
    sub     rax, [rsp+8]
    cvtsi2ss xmm0, rax
    mulss   xmm0, [rip+lq_k]
    mulss   xmm0, [rip+lq_k]
    movss   [rip+lq_ms], xmm0
    lea     rsp, [rbp-40]
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    pop     rbp
    ret

# lq_run(rdi=job) - over every particle, in chunks of GRAIN
lq_run:
    push    rbx
    push    r12
    sub     rsp, 8
    mov     rbx, rdi
    call    now_ns
    mov     r12, rax
    mov     rdi, rbx
    xor     esi, esi
    mov     edx, [rip+lq_n]
    mov     ecx, GRAIN
    call    parallel_for
    call    now_ns
    sub     rax, r12
    add     [rip+lq_tjob], rax
    add     rsp, 8
    pop     r12
    pop     rbx
    ret

# lq_consts (r12 = settings) - the kernel, the mass, the rest
lq_consts:
    push    rbx
    sub     rsp, 16
    movss   xmm0, [r12+PS_SIZE]         # spacing d, h = 2 d
    maxss   xmm0, [rip+lq_k]
    movss   xmm1, xmm0
    mulss   xmm1, [rip+lq_half]
    movss   [rip+lq_rp], xmm1
    addss   xmm0, xmm0
    movss   [rip+lq_h], xmm0
    movss   xmm1, xmm0
    mulss   xmm1, xmm0
    movss   [rip+lq_h2], xmm1
    movss   xmm2, [rip+lq_onef]
    divss   xmm2, xmm0
    movss   [rip+lq_ih], xmm2
    movss   xmm2, xmm1                  # h^9 = (h^2)^4 h
    mulss   xmm2, xmm1
    mulss   xmm2, xmm2
    mulss   xmm2, xmm0
    movss   xmm3, [rip+lq_64]
    mulss   xmm3, [rip+lq_pi]
    mulss   xmm3, xmm2
    movss   xmm4, [rip+lq_315]
    divss   xmm4, xmm3
    movss   [rip+lq_k6], xmm4
    movss   xmm2, xmm1                  # h^6
    mulss   xmm2, xmm1
    mulss   xmm2, xmm1
    mulss   xmm2, [rip+lq_pi]
    movss   xmm4, [rip+lq_45]
    divss   xmm4, xmm2
    xorps   xmm4, [rip+lq_sgn]
    movss   [rip+lq_ks], xmm4
    movss   xmm0, [r12+PS_DENS]         # the rest density
    maxss   xmm0, [rip+lq_onef]
    movss   [rip+lq_rho0], xmm0
    xorps   xmm6, xmm6                  # a lattice at d: its sum of W, and
    xorps   xmm7, xmm7                  #  of |grad W|^2
    mov     ebx, -2
1:  cmp     ebx, 2
    jg      4f
    mov     ecx, -2
2:  cmp     ecx, 2
    jg      31f
    mov     edx, -2
3:  cmp     edx, 2
    jg      21f
    cvtsi2ss xmm0, ebx
    cvtsi2ss xmm1, ecx
    cvtsi2ss xmm2, edx
    unpcklps xmm0, xmm1
    movlhps xmm0, xmm2
    movss   xmm1, [r12+PS_SIZE]
    maxss   xmm1, [rip+lq_k]
    shufps  xmm1, xmm1, 0
    mulps   xmm0, xmm1
    andps   xmm0, [rip+lq_xyz]
    movaps  [rsp], xmm0
    DOT3    xmm0, xmm0
    movss   xmm5, xmm0                  # r^2
    push    rcx
    push    rdx
    call    w6
    addss   xmm6, xmm0
    sqrtss  xmm1, xmm5
    movaps  xmm0, [rsp+16]
    xorps   xmm3, xmm3
    comiss  xmm1, [rip+lq_tiny]
    jbe     35f
    comiss  xmm1, [rip+lq_h]
    jae     35f
    call    gw
    DOT3    xmm0, xmm0
    addss   xmm7, xmm0
35: pop     rdx
    pop     rcx
    inc     edx
    jmp     3b
21: inc     ecx
    jmp     2b
31: inc     ebx
    jmp     1b
4:  movss   xmm0, [rip+lq_rho0]         # m: the lattice is at rest density
    maxss   xmm6, [rip+lq_tiny]
    divss   xmm0, xmm6
    movss   [rip+lq_m], xmm0
    divss   xmm0, [rip+lq_rho0]
    movss   [rip+lq_mr], xmm0
    mulss   xmm7, xmm0                  # eps: a part of the lattice's sum
    mulss   xmm7, xmm0
    mulss   xmm7, [rip+lq_epsk]
    maxss   xmm7, [rip+lq_tiny]
    movss   [rip+lq_eps], xmm7
    movss   xmm0, [rip+lq_h]            # W(0.2 h)
    mulss   xmm0, [rip+lq_02]
    mulss   xmm0, xmm0
    call    w6
    maxss   xmm0, [rip+lq_tiny]
    movss   [rip+lq_wdq], xmm0
    call    lq_walls
    movss   xmm0, [r12+PS_TENS]         # (in lambda's units: of the lattice's sum)
    mulss   xmm0, [rip+lq_mr]
    mulss   xmm0, [rip+lq_mr]
    divss   xmm0, [rip+lq_eps]
    mulss   xmm0, [rip+lq_epsk]
    movss   [rip+lq_tk], xmm0

    mov     eax, [r12+PS_VORT]
    mov     [rip+lq_vort], eax
    mov     eax, [r12+PS_DOMON]         # the domain, less a radius
    and     eax, 1
    mov     [rip+lq_dom], eax
    movss   xmm1, [rip+lq_rp]
    shufps  xmm1, xmm1, 0
    movups  xmm0, [r12+PS_DOMAIN]
    andps   xmm0, [rip+lq_xyz]
    addps   xmm0, xmm1
    andps   xmm0, [rip+lq_xyz]
    movaps  [rip+lq_dmin], xmm0
    movups  xmm0, [r12+PS_DOMAIN+12]
    andps   xmm0, [rip+lq_xyz]
    subps   xmm0, xmm1
    andps   xmm0, [rip+lq_xyz]
    movaps  [rip+lq_dmax], xmm0
    add     rsp, 16
    pop     rbx
    ret

.section .rodata
.align 4
lq_half:        .float 0.5
lq_wt:          .float 32.0
lq_v60:         .float 60.0
.text

# lq_walls (r12 = settings) - the walls (the domain's faces, the ground) and
#   what a half-space of the lattice beyond one adds at a distance s:
#   rows at s + d/2, s + 3d/2 ... deep
lq_walls:
    push    rbx
    push    r13
    push    r14
    sub     rsp, 48
    xor     ebx, ebx                    # the table
1:  cmp     ebx, WT+1
    ja      5f
    cvtsi2ss xmm0, ebx
    mulss   xmm0, [rip+lq_h]
    divss   xmm0, [rip+lq_wt]
    movss   [rsp+32], xmm0              # s
    xorps   xmm6, xmm6                  # sum W
    xorps   xmm7, xmm7                  # sum grad (along n)
    xor     r13d, r13d                  # rows
2:  cmp     r13d, 3
    jae     4f
    cvtsi2ss xmm0, r13d
    addss   xmm0, [rip+lq_half]
    mulss   xmm0, [r12+PS_SIZE]
    addss   xmm0, [rsp+32]
    movss   [rsp+36], xmm0              # depth
    mov     r14d, -2
21: cmp     r14d, 2
    jg      3f
    mov     ecx, -2
22: cmp     ecx, 2
    jg      23f
    cvtsi2ss xmm0, r14d
    cvtsi2ss xmm2, ecx
    movss   xmm1, [rsp+36]
    movss   xmm3, [r12+PS_SIZE]
    mulss   xmm0, xmm3
    mulss   xmm2, xmm3
    divss   xmm1, xmm3                  # (y in spacings, multiplied back)
    mulss   xmm1, xmm3
    unpcklps xmm0, xmm1
    movlhps xmm0, xmm2
    andps   xmm0, [rip+lq_xyz]
    movaps  [rsp], xmm0
    DOT3    xmm0, xmm0
    movss   [rsp+40], xmm0
    push    rcx
    push    rcx
    call    w6
    addss   xmm6, xmm0
    movss   xmm1, [rsp+56]
    sqrtss  xmm1, xmm1
    comiss  xmm1, [rip+lq_h]
    jae     24f
    movaps  xmm0, [rsp+16]
    call    gw
    shufps  xmm0, xmm0, 0x55
    addss   xmm7, xmm0
24: pop     rcx
    pop     rcx
    inc     ecx
    jmp     22b
23: inc     r14d
    jmp     21b
3:  inc     r13d
    jmp     2b
4:  lea     rax, [rip+lq_wd]
    movss   [rax+rbx*4], xmm6
    lea     rax, [rip+lq_wg]
    movss   [rax+rbx*4], xmm7
    inc     ebx
    jmp     1b
5:  xor     ebx, ebx                    # the walls
    lea     r13, [rip+lq_wall]
    test    dword ptr [r12+PS_DOMON], 1
    jz      7f
    xor     r14d, r14d                  # min faces: n = +e, w = min
6:  cmp     r14d, 3
    jae     7f
    xorps   xmm0, xmm0
    movaps  [r13], xmm0
    mov     eax, [rip+lq_onef]
    mov     [r13+r14*4], eax
    mov     eax, [r12+PS_DOMAIN+r14*4]
    mov     [r13+12], eax
    add     r13, 16
    xorps   xmm0, xmm0                  # max faces: n = -e, w = -max
    movaps  [r13], xmm0
    mov     eax, [rip+lq_onef]
    or      eax, 0x80000000
    mov     [r13+r14*4], eax
    mov     eax, [r12+PS_DOMAIN+12+r14*4]
    xor     eax, 0x80000000
    mov     [r13+12], eax
    add     r13, 16
    add     ebx, 2
    inc     r14d
    jmp     6b
7:  cmp     dword ptr [rip+pc_gnd], 0   # the ground: a floor
    je      8f
    xorps   xmm0, xmm0
    movaps  [r13], xmm0
    mov     eax, [rip+lq_onef]
    mov     [r13+4], eax
    mov     eax, [rip+pc_gy]
    mov     [r13+12], eax
    inc     ebx
8:  mov     [rip+lq_nw], ebx
    add     rsp, 48
    pop     r14
    pop     r13
    pop     rbx
    ret

# walls(xmm6=point) -> xmm0 = the walls' sum of W there, xmm1 = their sum
#   of grad W (vec4) (leaf: xmm2..5, eax, ecx, rdx)
walls:
    xorps   xmm0, xmm0
    xorps   xmm1, xmm1
    xor     ecx, ecx
1:  cmp     ecx, [rip+lq_nw]
    jae     9f
    mov     eax, ecx
    shl     eax, 4
    lea     rdx, [rip+lq_wall]
    add     rdx, rax
    inc     ecx
    movaps  xmm2, xmm6
    DOT3    xmm2, [rdx]
    subss   xmm2, [rdx+12]              # s
    xorps   xmm3, xmm3
    maxss   xmm2, xmm3
    comiss  xmm2, [rip+lq_h]
    jae     1b
    mulss   xmm2, [rip+lq_wt]
    divss   xmm2, [rip+lq_h]
    cvttss2si eax, xmm2
    cvtsi2ss xmm3, eax
    subss   xmm2, xmm3                  # the fraction
    lea     r8, [rip+lq_wd]
    movss   xmm3, [r8+rax*4+4]
    subss   xmm3, [r8+rax*4]
    mulss   xmm3, xmm2
    addss   xmm3, [r8+rax*4]
    addss   xmm0, xmm3
    lea     r8, [rip+lq_wg]
    movss   xmm3, [r8+rax*4+4]
    subss   xmm3, [r8+rax*4]
    mulss   xmm3, xmm2
    addss   xmm3, [r8+rax*4]
    shufps  xmm3, xmm3, 0
    movaps  xmm4, [rdx]
    andps   xmm4, [rip+lq_xyz]
    mulps   xmm3, xmm4
    addps   xmm1, xmm3
    jmp     1b
9:  ret

# lq_bodies - the moving rigid bodies made of one box, ball or capsule:
#   where they are now (bodies made of more parts, or meshes, are left to
#   the colliders)
lq_bodies:
    push    rbx
    push    r12
    push    r13
    mov     dword ptr [rip+lq_nbd], 0
    cmp     dword ptr [rip+rb_on], 0
    je      9f
    xor     ebx, ebx
1:  cmp     ebx, [rip+rb_nb]
    jae     9f
    imul    r12, rbx, 368               # (rbody.s BD_SZ)
    add     r12, [rip+rb_bd]
    inc     ebx
    cmp     dword ptr [r12+236], 1      # (BD_TYPE) moving
    jne     1b
    cmp     dword ptr [r12+252], 1      # (BD_NP) one part
    jne     1b
    mov     eax, [r12+248]              # (BD_P0)
    shl     rax, 6                      # (PT_SZ)
    add     rax, [rip+rb_pt]
    mov     r13, rax
    cmp     dword ptr [r13], 0          # (PT_TYPE) a box core with a radius
    jne     1b
    mov     ecx, [rip+lq_nbd]
    cmp     ecx, MAXB
    jae     9f
    inc     dword ptr [rip+lq_nbd]
    mov     rax, [r12+256]              # (BD_OBJ)
    lea     rdx, [rip+lq_bobj]
    mov     [rdx+rcx*8], rax
    lea     rdx, [rip+lq_bptr]
    mov     [rdx+rcx*8], r12
    imul    rdx, rcx, 48                # its rotation
    lea     rax, [rip+lq_br]
    add     rdx, rax
    movaps  xmm0, [r12+128]             # (BD_R)
    movaps  [rdx], xmm0
    movaps  xmm1, [r12+144]
    movaps  [rdx+16], xmm1
    movaps  xmm2, [r12+160]
    movaps  [rdx+32], xmm2
    movaps  xmm3, [r13+48]              # its centre: P + R off
    movaps  xmm4, xmm3
    DOT3    xmm4, xmm0
    movaps  xmm5, xmm3
    DOT3    xmm5, xmm1
    movaps  xmm6, xmm3
    DOT3    xmm6, xmm2
    unpcklps xmm4, xmm5
    movlhps xmm4, xmm6
    addps   xmm4, [r12]
    andps   xmm4, [rip+lq_xyz]
    shl     ecx, 4
    lea     rax, [rip+lq_bc]
    movaps  [rax+rcx], xmm4
    lea     rax, [rip+lq_bc1]
    movaps  [rax+rcx], xmm4
    lea     rax, [rip+lq_bc0]           # the frame before: kept, or here
    movaps  [rax+rcx], xmm4
    xor     edx, edx
31: cmp     edx, [rip+lq_np]
    jae     32f
    lea     r8, [rip+lq_pobj]
    mov     r9, [r8+rdx*8]
    inc     edx
    cmp     r9, [r12+256]
    jne     31b
    mov     r8, rdx
    shl     r8, 4
    lea     r9, [rip+lq_pc]
    movaps  xmm5, [r9+r8-16]
    movaps  [rax+rcx], xmm5
32:
    movaps  xmm0, [r13+32]              # half size, rounding (+ a radius)
    andps   xmm0, [rip+lq_xyz]
    movss   xmm1, [r13+16]
    addss   xmm1, [rip+lq_rp]
    shufps  xmm1, xmm1, 0
    andps   xmm1, [rip+lq_w0]
    orps    xmm0, xmm1
    lea     rax, [rip+lq_bh]
    movaps  [rax+rcx], xmm0
    movaps  xmm0, [r12+192]             # (BD_MIN, BD_MAX) grown, and by the
    movaps  xmm1, [r12+208]             #  way it came
    movss   xmm2, [rip+lq_h]
    shufps  xmm2, xmm2, 0
    lea     rax, [rip+lq_bc1]
    movaps  xmm3, [rax+rcx]
    lea     rax, [rip+lq_bc0]
    subps   xmm3, [rax+rcx]
    andps   xmm3, [rip+lq_abs]
    addps   xmm2, xmm3
    subps   xmm0, xmm2
    addps   xmm1, xmm2
    lea     rax, [rip+lq_bmin]
    movaps  [rax+rcx], xmm0
    lea     rax, [rip+lq_bmax]
    movaps  [rax+rcx], xmm1
    jmp     1b
9:  pop     r13
    pop     r12
    pop     rbx
    ret

.section .rodata
.align 16
lq_w0:          .long 0, 0, 0, -1
.text

# lq_reset - the simulation begins again (no centres kept)
lq_reset:
    mov     dword ptr [rip+lq_np], 0
    ret

# lq_keep - the bodies' centres now, for the next frame
lq_keep:
    mov     ecx, [rip+lq_nbd]
    mov     [rip+lq_np], ecx
    xor     edx, edx
1:  cmp     edx, ecx
    jae     9f
    lea     rax, [rip+lq_bobj]
    mov     r8, [rax+rdx*8]
    lea     rax, [rip+lq_pobj]
    mov     [rax+rdx*8], r8
    mov     r8, rdx
    shl     r8, 4
    lea     rax, [rip+lq_bc1]
    movaps  xmm0, [rax+r8]
    lea     rax, [rip+lq_pc]
    movaps  [rax+r8], xmm0
    inc     edx
    jmp     1b
9:  ret

# lq_place_bodies(edi=substep k, esi=of K) - the bodies on their way:
#   c0 + (c1 - c0) (k + 1) / K
lq_place_bodies:
    lea     eax, [rdi+1]
    cvtsi2ss xmm1, eax
    cvtsi2ss xmm2, esi
    divss   xmm1, xmm2
    shufps  xmm1, xmm1, 0
    xor     edx, edx
1:  cmp     edx, [rip+lq_nbd]
    jae     9f
    mov     r8, rdx
    shl     r8, 4
    lea     rax, [rip+lq_bc1]
    movaps  xmm0, [rax+r8]
    lea     rax, [rip+lq_bc0]
    subps   xmm0, [rax+r8]
    mulps   xmm0, xmm1
    addps   xmm0, [rax+r8]
    andps   xmm0, [rip+lq_xyz]
    lea     rax, [rip+lq_bc]
    movaps  [rax+r8], xmm0
    inc     edx
    jmp     1b
9:  ret

# lq_push_bodies - each body's impulses (the chunks' in order) given to it
lq_push_bodies:
    push    rbx
    push    r12
    push    r13
    sub     rsp, 16
    xor     ebx, ebx
1:  cmp     ebx, [rip+lq_nbd]
    jae     9f
    mov     eax, [rip+lq_n]
    add     eax, GRAIN-1
    xor     edx, edx
    mov     ecx, GRAIN
    div     ecx
    mov     r12d, eax                   # chunks
    xorps   xmm0, xmm0
    xor     r13d, r13d
2:  cmp     r13d, r12d
    jae     3f
    imul    eax, r13d, MAXB
    add     eax, ebx
    shl     rax, 4
    add     rax, [rip+lq_imp]
    addps   xmm0, [rax]
    inc     r13d
    jmp     2b
3:  andps   xmm0, [rip+lq_xyz]
    movaps  xmm1, xmm0                  # at most: its way into the liquid
    DOT3    xmm1, xmm1                  #  stopped, and a frame of gravity
    sqrtss  xmm1, xmm1                  #  (the impulse comes after the frame:
    comiss  xmm1, [rip+lq_tiny]         #  no bounce out of it)
    jbe     4f
    movaps  xmm2, xmm1
    shufps  xmm2, xmm2, 0
    divps   xmm0, xmm2                  # n
    lea     rax, [rip+lq_bptr]
    mov     rax, [rax+rbx*8]
    movaps  xmm3, [rax+32]              # (BD_V) along n
    DOT3    xmm3, xmm0
    movss   xmm4, [rax+224]             # (BD_IM)
    mulss   xmm1, xmm4                  # dv
    movaps  xmm5, [rip+lq_acc]
    DOT3    xmm5, xmm5
    sqrtss  xmm5, xmm5
    mulss   xmm5, [rip+lq_fdt]          # the cap
    movss   xmm6, xmm3
    addss   xmm6, xmm1
    comiss  xmm6, xmm5
    jbe     31f
    movss   xmm1, xmm5
    subss   xmm1, xmm3
    xorps   xmm6, xmm6
    maxss   xmm1, xmm6
31: maxss   xmm4, [rip+lq_tiny]
    divss   xmm1, xmm4                  # back to an impulse
    shufps  xmm1, xmm1, 0
    mulps   xmm0, xmm1
    lea     rax, [rip+lq_bobj]
    mov     rdi, [rax+rbx*8]
    call    rb_impulse
4:
    inc     ebx
    jmp     1b
9:  add     rsp, 16
    pop     r13
    pop     r12
    pop     rbx
    ret

# lq_sort_cells - the particles by bucket (counting sort: in their order
#   within a bucket)
lq_sort_cells:
    mov     rdi, [rip+lq_start]
    mov     ecx, [rip+lq_mask]
    add     ecx, 2
    xor     eax, eax
    rep     stosd
    mov     rsi, [rip+lq_cell]
    mov     rdi, [rip+lq_start]
    mov     ecx, [rip+lq_n]
    xor     edx, edx
1:  cmp     edx, ecx
    jae     2f
    mov     eax, [rsi+rdx*4]
    inc     dword ptr [rdi+rax*4+4]
    inc     edx
    jmp     1b
2:  mov     ecx, [rip+lq_mask]          # prefix sums: starts
    inc     ecx
    xor     eax, eax
    xor     edx, edx
3:  cmp     edx, ecx
    jae     4f
    add     eax, [rdi+rdx*4+4]
    mov     [rdi+rdx*4+4], eax
    inc     edx
    jmp     3b
4:  mov     r8, [rip+lq_sort]           # fill (the counts again as cursors:
    mov     ecx, [rip+lq_n]             #  start[b] advances; put back after)
    xor     edx, edx
5:  cmp     edx, ecx
    jae     6f
    mov     eax, [rsi+rdx*4]
    mov     r9d, [rdi+rax*4]
    mov     [r8+r9*4], edx
    inc     dword ptr [rdi+rax*4]
    inc     edx
    jmp     5b
6:  mov     ecx, [rip+lq_mask]          # starts back: start[b] = end[b-1]
    inc     ecx
7:  test    ecx, ecx
    jz      8f
    mov     eax, [rdi+rcx*4-4]
    mov     [rdi+rcx*4], eax
    dec     ecx
    jmp     7b
8:  mov     dword ptr [rdi], 0
    ret

# =============================================================================
#  The jobs (ctx, esi=begin, edx=end)
# =============================================================================
.macro JOB_IN
    push    rbp
    mov     rbp, rsp
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    and     rsp, -16
    sub     rsp, 256
    mov     r12d, esi
    mov     r13d, edx
.endm
.macro JOB_OUT
    lea     rsp, [rbp-40]
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    pop     rbp
    ret
.endm

# predict: v += a dt, p = x + v dt (in the domain)
j_predict:
    JOB_IN
1:  cmp     r12d, r13d
    jae     9f
    LQPTR   rbx, lq_x, r12
    LQPTR   r14, lq_v, r12
    movaps  xmm0, [rip+lq_acc]
    cmp     dword ptr [rip+lq_fields], 0
    je      2f
    mov     rdi, rbx
    mov     rsi, r14
    mov     edx, [rip+lq_gbit]
    xor     ecx, ecx
    call    fl_accel
    addps   xmm0, [rip+lq_gadj]
2:  movss   xmm1, [rip+lq_dt]
    shufps  xmm1, xmm1, 0
    mulps   xmm0, xmm1
    addps   xmm0, [r14]
    andps   xmm0, [rip+lq_xyz]
    movaps  [r14], xmm0
    mulps   xmm0, xmm1
    addps   xmm0, [rbx]
    call    clampd
    LQPTR   rax, lq_p, r12
    movaps  [rax], xmm0
    inc     r12d
    jmp     1b
9:  JOB_OUT

# hash: each particle's bucket
j_hash:
    JOB_IN
    mov     rbx, [rip+lq_cell]
1:  cmp     r12d, r13d
    jae     9f
    LQPTR   rax, lq_p, r12
    movaps  xmm0, [rax]
    call    hash
    mov     [rbx+r12*4], eax
    inc     r12d
    jmp     1b
9:  JOB_OUT

# nbrs: the particles within h, from the 27 cells round it (each bucket once)
j_nbrs:
    JOB_IN
    xor     r15d, r15d                  # the most found in this chunk
1:  cmp     r12d, r13d
    jae     9f
    LQPTR   rax, lq_p, r12
    movaps  xmm6, [rax]                 # p_i
    movss   xmm1, [rip+lq_ih]
    shufps  xmm1, xmm1, 0
    mulps   xmm1, xmm6
    roundps xmm1, xmm1, 1
    cvtps2dq xmm7, xmm1                 # its cell
    mov     eax, r12d
    imul    rax, rax, NB*4
    add     rax, [rip+lq_nb]
    mov     r14, rax                    # its list
    xor     ebx, ebx                    # found
    mov     dword ptr [rsp+200], 0      # buckets seen
    mov     dword ptr [rsp+204], -1     # dz
2:  mov     dword ptr [rsp+208], -1     # dy
3:  mov     dword ptr [rsp+212], -1     # dx
4:  movd    xmm1, [rsp+212]
    movd    xmm2, [rsp+208]
    movd    xmm3, [rsp+204]
    punpckldq xmm1, xmm2
    punpcklqdq xmm1, xmm3
    paddd   xmm1, xmm7
    call    hashc
    mov     ecx, [rsp+200]              # seen already?
    xor     edx, edx
5:  cmp     edx, ecx
    jae     6f
    cmp     [rsp+rdx*4], eax
    je      .Lnb_next
    inc     edx
    jmp     5b
6:  mov     [rsp+rcx*4], eax
    inc     dword ptr [rsp+200]
    mov     rcx, [rip+lq_start]
    mov     r8d, [rcx+rax*4]
    mov     r9d, [rcx+rax*4+4]
    mov     r10, [rip+lq_sort]
    mov     r11, [rip+lq_p]
7:  cmp     r8d, r9d
    jae     .Lnb_next
    mov     eax, [r10+r8*4]
    inc     r8d
    cmp     eax, r12d
    je      7b
    mov     rdx, rax
    shl     rdx, 4
    movaps  xmm0, xmm6
    subps   xmm0, [r11+rdx]
    andps   xmm0, [rip+lq_xyz]
    DOT3    xmm0, xmm0
    comiss  xmm0, [rip+lq_h2]
    jae     7b
    cmp     ebx, NB
    jae     7b
    mov     [r14+rbx*4], eax
    inc     ebx
    jmp     7b
.Lnb_next:
    inc     dword ptr [rsp+212]
    cmp     dword ptr [rsp+212], 1
    jle     4b
    inc     dword ptr [rsp+208]
    cmp     dword ptr [rsp+208], 1
    jle     3b
    inc     dword ptr [rsp+204]
    cmp     dword ptr [rsp+204], 1
    jle     2b
    mov     rax, [rip+lq_nn]
    mov     [rax+r12*4], ebx
    cmp     ebx, r15d
    cmova   r15d, ebx
    inc     r12d
    jmp     1b
9:  mov     eax, [rip+lq_nmax]          # (a statistic: races are harmless)
    cmp     r15d, eax
    jbe     91f
    mov     [rip+lq_nmax], r15d
91: JOB_OUT

# lambda: each particle's density and its constraint's lambda
j_lambda:
    JOB_IN
1:  cmp     r12d, r13d
    jae     9f
    LQPTR   rax, lq_p, r12
    movaps  xmm6, [rax]
    xorps   xmm0, xmm0                  # itself: W(0)
    call    w6
    movss   [rsp+16], xmm0              # density sum (W)
    xorps   xmm7, xmm7                  # grad_i
    xorps   xmm8, xmm8                  # sum |grad_j|^2
    mov     rax, [rip+lq_nn]
    mov     r15d, [rax+r12*4]
    mov     eax, r12d
    imul    rax, rax, NB*4
    add     rax, [rip+lq_nb]
    mov     r14, rax
    xor     ebx, ebx
2:  cmp     ebx, r15d
    jae     3f
    mov     eax, [r14+rbx*4]
    inc     ebx
    mov     r8d, eax
    shl     rax, 4
    add     rax, [rip+lq_p]
    movaps  xmm0, xmm6
    subps   xmm0, [rax]
    andps   xmm0, [rip+lq_xyz]
    movaps  xmm9, xmm0
    DOT3    xmm0, xmm0
    movss   xmm10, xmm0                 # r^2
    call    apart
    call    w6
    addss   xmm0, [rsp+16]
    movss   [rsp+16], xmm0
    sqrtss  xmm1, xmm10
    movaps  xmm0, xmm9
    call    gw
    movss   xmm1, [rip+lq_mr]
    shufps  xmm1, xmm1, 0
    mulps   xmm0, xmm1                  # (m / rho0) grad W
    addps   xmm7, xmm0
    DOT3    xmm0, xmm0
    addss   xmm8, xmm0
    jmp     2b
3:  call    walls                       # the walls: a lattice beyond them
    addss   xmm0, [rsp+16]
    movss   [rsp+16], xmm0
    movss   xmm2, [rip+lq_mr]
    shufps  xmm2, xmm2, 0
    mulps   xmm1, xmm2
    addps   xmm7, xmm1
    movss   xmm0, [rsp+16]
    mulss   xmm0, [rip+lq_m]            # rho
    mov     rax, [rip+lq_rho]
    movss   [rax+r12*4], xmm0
    divss   xmm0, [rip+lq_rho0]
    movd    eax, xmm0                   # (the densest: positive floats compare
    mov     ecx, [rip+lq_rmax]          #  as integers; races are harmless)
    cmp     eax, ecx
    jbe     31f
    mov     [rip+lq_rmax], eax
    mov     [rip+lq_rmaxi], r12d
31:
    subss   xmm0, [rip+lq_onef]         # C (not below 0)
    xorps   xmm1, xmm1
    maxss   xmm0, xmm1
    DOT3    xmm7, xmm7
    addss   xmm8, xmm7
    addss   xmm8, [rip+lq_eps]
    divss   xmm0, xmm8
    xorps   xmm0, [rip+lq_sgn]
    mov     rax, [rip+lq_lam]
    movss   [rax+r12*4], xmm0
    inc     r12d
    jmp     1b
9:  JOB_OUT

# delta: dp_i = (m / rho0) sum (l_i + l_j + s_corr) grad W
j_delta:
    JOB_IN
1:  cmp     r12d, r13d
    jae     9f
    LQPTR   rax, lq_p, r12
    movaps  xmm6, [rax]
    mov     rax, [rip+lq_lam]
    movss   xmm11, [rax+r12*4]          # l_i
    xorps   xmm7, xmm7
    mov     rax, [rip+lq_nn]
    mov     r15d, [rax+r12*4]
    mov     eax, r12d
    imul    rax, rax, NB*4
    add     rax, [rip+lq_nb]
    mov     r14, rax
    xor     ebx, ebx
2:  cmp     ebx, r15d
    jae     3f
    mov     eax, [r14+rbx*4]
    inc     ebx
    mov     rcx, [rip+lq_lam]
    movss   xmm12, [rcx+rax*4]
    addss   xmm12, xmm11                # l_i + l_j
    mov     r8d, eax
    shl     rax, 4
    add     rax, [rip+lq_p]
    movaps  xmm0, xmm6
    subps   xmm0, [rax]
    andps   xmm0, [rip+lq_xyz]
    movaps  xmm9, xmm0
    DOT3    xmm0, xmm0
    movss   xmm10, xmm0
    call    apart
    call    w6                          # s_corr = -k (W / W(dq))^4
    divss   xmm0, [rip+lq_wdq]
    mulss   xmm0, xmm0
    mulss   xmm0, xmm0
    mulss   xmm0, [rip+lq_tk]
    subss   xmm12, xmm0
    sqrtss  xmm1, xmm10
    movaps  xmm0, xmm9
    call    gw
    shufps  xmm12, xmm12, 0
    mulps   xmm0, xmm12
    addps   xmm7, xmm0
    jmp     2b
3:  call    walls                       # the walls (mirrored: their lambda
    addss   xmm11, xmm11                #  as its own)
    shufps  xmm11, xmm11, 0
    mulps   xmm1, xmm11
    addps   xmm7, xmm1
    movss   xmm1, [rip+lq_mr]
    shufps  xmm1, xmm1, 0
    mulps   xmm7, xmm1
    andps   xmm7, [rip+lq_xyz]
    LQPTR   rax, lq_dp, r12
    movaps  [rax], xmm7
    inc     r12d
    jmp     1b
9:  JOB_OUT

# apply: p += dp, in the domain; the moving bodies push it out (and get
#   the opposite impulse, summed for this chunk)
j_apply:
    JOB_IN
    mov     eax, r12d                   # this chunk's impulses
    xor     edx, edx
    mov     ecx, GRAIN
    div     ecx
    imul    eax, eax, MAXB*16
    add     rax, [rip+lq_imp]
    mov     [rsp+192], rax
1:  cmp     r12d, r13d
    jae     9f
    LQPTR   rbx, lq_p, r12
    LQPTR   rax, lq_dp, r12
    movaps  xmm0, [rbx]
    addps   xmm0, [rax]
    call    clampd
    movaps  [rbx], xmm0
    xor     r14d, r14d                  # the bodies
2:  cmp     r14d, [rip+lq_nbd]
    jae     8f
    mov     r15, r14
    shl     r15, 4
    inc     r14d
    movaps  xmm0, [rbx]
    lea     rax, [rip+lq_bmin]
    movaps  xmm1, xmm0
    cmpltps xmm1, [rax+r15]
    lea     rax, [rip+lq_bmax]
    movaps  xmm2, [rax+r15]
    cmpltps xmm2, xmm0
    orps    xmm1, xmm2
    movmskps eax, xmm1
    test    eax, 7
    jnz     2b
    lea     rax, [rip+lq_bc]            # into its axes
    subps   xmm0, [rax+r15]
    andps   xmm0, [rip+lq_xyz]
    lea     rcx, [r15+r15*2]            # (48 a body)
    lea     rax, [rip+lq_br]
    add     rcx, rax
    movaps  xmm1, xmm0                  # local = R^T d = d.x r0 + d.y r1 + d.z r2
    shufps  xmm1, xmm1, 0
    mulps   xmm1, [rcx]
    movaps  xmm2, xmm0
    shufps  xmm2, xmm2, 0x55
    mulps   xmm2, [rcx+16]
    addps   xmm1, xmm2
    movaps  xmm2, xmm0
    shufps  xmm2, xmm2, 0xAA
    mulps   xmm2, [rcx+32]
    addps   xmm1, xmm2
    andps   xmm1, [rip+lq_xyz]          # local
    movaps  xmm3, xmm1
    andps   xmm3, [rip+lq_abs]
    lea     rax, [rip+lq_bh]
    movaps  xmm4, [rax+r15]             # half (w: rounding + radius)
    movaps  xmm5, xmm4
    shufps  xmm5, xmm5, 0xFF            # rad
    subps   xmm3, xmm4                  # q
    andps   xmm3, [rip+lq_xyz]
    movaps  xmm6, xmm3                  # the largest q
    movaps  xmm7, xmm3
    shufps  xmm7, xmm7, 0x55
    maxss   xmm6, xmm7
    movaps  xmm7, xmm3
    shufps  xmm7, xmm7, 0xAA
    maxss   xmm6, xmm7
    xorps   xmm7, xmm7
    comiss  xmm6, xmm7
    jae     4f
    xor     eax, eax                    # inside the core: out of its nearest
    movss   xmm7, xmm3                  #  face
    movaps  xmm8, xmm3
    shufps  xmm8, xmm8, 0x55
    comiss  xmm8, xmm7
    jbe     31f
    mov     eax, 1
    movss   xmm7, xmm8
31: movaps  xmm8, xmm3
    shufps  xmm8, xmm8, 0xAA
    comiss  xmm8, xmm7
    jbe     32f
    mov     eax, 2
    movss   xmm7, xmm8
32: movss   xmm8, xmm5                  # push = rad - q
    subss   xmm8, xmm7
    movaps  [rsp+128], xmm1
    xorps   xmm9, xmm9
    movaps  [rsp+144], xmm9
    mov     ecx, [rsp+128+rax*4]
    and     ecx, 0x80000000
    or      ecx, [rip+lq_onef]
    mov     [rsp+144+rax*4], ecx
    movaps  xmm9, [rsp+144]             # n (local)
    jmp     5f
4:  maxps   xmm3, xmm7                  # outside the core: within its rounding?
    andps   xmm3, [rip+lq_xyz]
    movaps  xmm6, xmm3
    DOT3    xmm6, xmm6
    sqrtss  xmm6, xmm6
    comiss  xmm6, xmm5
    jae     2b
    comiss  xmm6, [rip+lq_tiny]
    jbe     2b
    movss   xmm8, xmm5
    subss   xmm8, xmm6                  # push
    movaps  xmm2, xmm1                  # n = q+ with the local's signs, unit
    andps   xmm2, [rip+lq_sgn]
    orps    xmm3, xmm2
    shufps  xmm6, xmm6, 0
    divps   xmm3, xmm6
    andps   xmm3, [rip+lq_xyz]
    movaps  xmm9, xmm3
5:  lea     rcx, [r15+r15*2]            # to the world: n_w = R n
    lea     rax, [rip+lq_br]
    add     rcx, rax
    movaps  xmm0, xmm9
    DOT3    xmm0, [rcx]
    movaps  xmm1, xmm9
    DOT3    xmm1, [rcx+16]
    movaps  xmm2, xmm9
    DOT3    xmm2, [rcx+32]
    unpcklps xmm0, xmm1
    movlhps xmm0, xmm2
    andps   xmm0, [rip+lq_xyz]
    shufps  xmm8, xmm8, 0
    mulps   xmm0, xmm8                  # the push
    movaps  xmm1, [rbx]
    addps   xmm1, xmm0
    movaps  [rbx], xmm1
    movss   xmm1, [rip+lq_m]            # the body: - m push / dt
    mulss   xmm1, [rip+lq_idt]
    shufps  xmm1, xmm1, 0
    mulps   xmm0, xmm1
    mov     rax, [rsp+192]
    movaps  xmm1, [rax+r15]
    subps   xmm1, xmm0
    movaps  [rax+r15], xmm1
    jmp     2b
8:  inc     r12d
    jmp     1b
9:  JOB_OUT

# collide: the substep's path against the scene's colliders
j_collide:
    JOB_IN
1:  cmp     r12d, r13d
    jae     9f
    LQPTR   rax, lq_x, r12
    movaps  xmm0, [rax]
    movaps  [rsp], xmm0
    LQPTR   rbx, lq_p, r12
    movaps  xmm0, [rbx]
    movaps  [rsp+64], xmm0
    lea     rdi, [rsp]
    call    pc_cast
    test    eax, eax
    jz      2f
    movss   xmm0, [rip+lq_rp]           # on the surface, a radius off it
    shufps  xmm0, xmm0, 0
    mulps   xmm0, [rsp+96]
    addps   xmm0, [rsp+80]
    andps   xmm0, [rip+lq_xyz]
    movaps  [rbx], xmm0
2:  inc     r12d
    jmp     1b
9:  JOB_OUT

# vel: v = (p - x) / dt
j_vel:
    JOB_IN
    movss   xmm1, [rip+lq_idt]
    shufps  xmm1, xmm1, 0
1:  cmp     r12d, r13d
    jae     9f
    LQPTR   rax, lq_p, r12
    movaps  xmm0, [rax]
    LQPTR   rax, lq_x, r12
    subps   xmm0, [rax]
    mulps   xmm0, xmm1
    andps   xmm0, [rip+lq_xyz]
    LQPTR   rax, lq_v, r12
    movaps  [rax], xmm0
    inc     r12d
    jmp     1b
9:  JOB_OUT

# xsph: v2_i = v_i + c sum (m / rho_j) (v_j - v_i) W; the vorticity w_i =
#   sum (m / rho_j) (v_j - v_i) x grad W
j_xsph:
    JOB_IN
1:  cmp     r12d, r13d
    jae     9f
    LQPTR   rax, lq_p, r12
    movaps  xmm6, [rax]
    LQPTR   rax, lq_v, r12
    movaps  xmm11, [rax]                # v_i
    xorps   xmm7, xmm7                  # the viscosity sum
    xorps   xmm13, xmm13                # the vorticity
    mov     rax, [rip+lq_nn]
    mov     r15d, [rax+r12*4]
    mov     eax, r12d
    imul    rax, rax, NB*4
    add     rax, [rip+lq_nb]
    mov     r14, rax
    xor     ebx, ebx
2:  cmp     ebx, r15d
    jae     3f
    mov     eax, [r14+rbx*4]
    inc     ebx
    mov     rcx, [rip+lq_rho]
    movss   xmm12, [rip+lq_m]
    movss   xmm1, [rcx+rax*4]
    maxss   xmm1, [rip+lq_tiny]
    divss   xmm12, xmm1                 # m / rho_j
    shl     rax, 4
    mov     rcx, rax
    add     rax, [rip+lq_p]
    add     rcx, [rip+lq_v]
    movaps  xmm14, [rcx]
    subps   xmm14, xmm11                # v_j - v_i
    movaps  xmm0, xmm6
    subps   xmm0, [rax]
    andps   xmm0, [rip+lq_xyz]
    movaps  xmm9, xmm0
    DOT3    xmm0, xmm0
    movss   xmm10, xmm0
    call    w6
    mulss   xmm0, xmm12
    shufps  xmm0, xmm0, 0
    mulps   xmm0, xmm14
    addps   xmm7, xmm0
    sqrtss  xmm1, xmm10
    movaps  xmm0, xmm9
    call    gw
    CROSS   xmm1, xmm14, xmm0, xmm2
    shufps  xmm12, xmm12, 0
    mulps   xmm1, xmm12
    addps   xmm13, xmm1
    jmp     2b
3:  call    walls                       # the walls: still particles there
    mulss   xmm0, [rip+lq_mr]
    shufps  xmm0, xmm0, 0
    mulps   xmm0, xmm11
    subps   xmm7, xmm0
    movss   xmm0, [rip+lq_visc]
    shufps  xmm0, xmm0, 0
    mulps   xmm7, xmm0
    addps   xmm7, xmm11
    andps   xmm7, [rip+lq_xyz]
    LQPTR   rax, lq_v2, r12
    movaps  [rax], xmm7
    andps   xmm13, [rip+lq_xyz]
    LQPTR   rax, lq_w, r12
    movaps  [rax], xmm13
    inc     r12d
    jmp     1b
9:  JOB_OUT

# vort: f = eps (N x w), N = eta / |eta|, eta = sum (m / rho_j) |w_j| grad W
j_vort:
    JOB_IN
1:  cmp     r12d, r13d
    jae     9f
    LQPTR   rax, lq_p, r12
    movaps  xmm6, [rax]
    xorps   xmm7, xmm7
    mov     rax, [rip+lq_nn]
    mov     r15d, [rax+r12*4]
    mov     eax, r12d
    imul    rax, rax, NB*4
    add     rax, [rip+lq_nb]
    mov     r14, rax
    xor     ebx, ebx
2:  cmp     ebx, r15d
    jae     3f
    mov     eax, [r14+rbx*4]
    inc     ebx
    mov     rcx, [rip+lq_rho]
    movss   xmm12, [rip+lq_m]
    movss   xmm1, [rcx+rax*4]
    maxss   xmm1, [rip+lq_tiny]
    divss   xmm12, xmm1
    shl     rax, 4
    mov     rcx, rax
    add     rax, [rip+lq_p]
    add     rcx, [rip+lq_w]
    movaps  xmm13, [rcx]
    DOT3    xmm13, xmm13
    sqrtss  xmm13, xmm13
    mulss   xmm12, xmm13
    movaps  xmm0, xmm6
    subps   xmm0, [rax]
    andps   xmm0, [rip+lq_xyz]
    movaps  xmm9, xmm0
    DOT3    xmm0, xmm0
    sqrtss  xmm1, xmm0
    movaps  xmm0, xmm9
    call    gw
    shufps  xmm12, xmm12, 0
    mulps   xmm0, xmm12
    addps   xmm7, xmm0
    jmp     2b
3:  movaps  xmm0, xmm7
    DOT3    xmm0, xmm0
    comiss  xmm0, [rip+lq_tiny]
    jbe     4f
    sqrtss  xmm0, xmm0
    shufps  xmm0, xmm0, 0
    divps   xmm7, xmm0                  # N
    LQPTR   rax, lq_w, r12
    movaps  xmm1, [rax]
    CROSS   xmm2, xmm7, xmm1, xmm3
    movss   xmm0, [rip+lq_vort]
    mulss   xmm0, [rip+lq_dt]
    shufps  xmm0, xmm0, 0
    mulps   xmm2, xmm0
    andps   xmm2, [rip+lq_xyz]
    LQPTR   rax, lq_v2, r12
    addps   xmm2, [rax]
    movaps  [rax], xmm2
4:  inc     r12d
    jmp     1b
9:  JOB_OUT

# commit: x = p, v = v2
j_commit:
    JOB_IN
1:  cmp     r12d, r13d
    jae     9f
    LQPTR   rax, lq_p, r12
    movaps  xmm0, [rax]
    LQPTR   rax, lq_x, r12
    movaps  [rax], xmm0
    LQPTR   rax, lq_v2, r12
    movaps  xmm0, [rax]
    LQPTR   rax, lq_v, r12
    movaps  [rax], xmm0
    inc     r12d
    jmp     1b
9:  JOB_OUT

.section .note.GNU-stack,"",@progbits
