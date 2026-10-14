# =============================================================================
#  BeeModel - surface-surface intersection (the B-rep kernel's booleans)
#
#  ssi(fa, fb) appends the curves where two faces' surfaces meet, as dense
#  polylines whose every point lies on both surfaces (with its (u, v) on
#  each). Planes against planes, cylinders across or along their axis,
#  spheres and cones across theirs are solved in closed form and keep the
#  exact line or circle. Everything else is traced: the signed distance to
#  the second surface sampled on a grid over the first face (the smaller
#  one), its zero contour followed cell by cell (marching squares), every
#  point pulled onto both surfaces by intersecting their tangent planes
#  (quadratic convergence), and points added where the polyline strays from
#  the true curve. Faces whose surfaces coincide are flagged instead.
# =============================================================================
.intel_syntax noprefix
.include "const.inc"
.include "brep.inc"

.globl ss_reset
.globl ssi
.globl sf_dist
.globl ss_refine
.globl ss_n
.globl ss_rec
.globl ss_pts
.globl ss_tol
.globl fc_bbox
.globl sf_coincide

.equ SS_SZ,     48                      # a section curve
.equ SS_FA,     0
.equ SS_FB,     4
.equ SS_FIRST,  8                       # its points in ss_pts
.equ SS_N,      12
.equ SS_CLOSED, 16
.equ SS_CURVE,  20                      # an exact curve (-1: none)
.equ SP_SZ,     56                      # a point: x y z, ua va, ub vb
.equ MAXSS,     8192
.equ GRIDN,     1600                    # samples per face grid

.section .rodata
.align 16
ss_absm:        .quad 0x7fffffffffffffff, 0x7fffffffffffffff
ss_negm:        .quad 0x8000000000000000, 0x8000000000000000
ss_one:         .double 1.0
ss_half:        .double 0.5
ss_two:         .double 2.0
ss_ext:         .double 0.02            # the grid reaches past the face
ss_par:         .double 1.0e-9          # parallel / perpendicular
ss_conv:        .double 1.0e-4          # (of the tolerance) converged
ss_tiny:        .double 1.0e-14
ss_big:         .double 1.0e300
ss_2pi:         .double 6.28318530717958647692
ss_seg:         .double 0.04908738521234052     # circles: 128 points a turn
ss_four:        .double 4.0
ss_400:         .double 400.0

.section .bss
.align 8
ss_tol:         .skip 8                 # linear tolerance
ss_n:           .skip 4
ss_rec:         .skip SS_SZ*MAXSS
ss_pa:          .skip ARENA_SZ          # points (SP_SZ each)
ss_np:          .skip 4
ss_ready:       .skip 4
ss_pts:         .skip 8                 # = ss_pa's base
# the faces being intersected
.align 8
sa_f:           .skip 4
sb_f:           .skip 4
sa_s:           .skip 8                 # surfaces
sb_s:           .skip 8
sa_box:         .skip 32                # (u0, u1, v0, v1) of each
sb_box:         .skip 32
ss_swap:        .skip 4                 # the grid is on b: (u, v) swapped
# the grid
gr_nu:          .skip 4
gr_nv:          .skip 4
gr_f:           .skip 8                 # values (nu+1)(nv+1)
gr_x:           .skip 8                 # crossing per grid edge: (u, v) + link
gr_u0:          .skip 8
gr_du:          .skip 8
gr_v0:          .skip 8
gr_dv:          .skip 8

.text

ss_init:
    cmp     dword ptr [rip+ss_ready], 0
    jne     9f
    sub     rsp, 8
    lea     rdi, [rip+ss_pa]
    mov     rsi, 0x40000000
    call    arena_init
    mov     rax, [rip+ss_pa+AR_BASE]
    mov     [rip+ss_pts], rax
    mov     dword ptr [rip+ss_ready], 1
    add     rsp, 8
9:  ret

# ss_reset - no sections
ss_reset:
    sub     rsp, 8
    call    ss_init
    mov     dword ptr [rip+ss_n], 0
    mov     dword ptr [rip+ss_np], 0
    add     rsp, 8
    ret

# sp_ptr(eax=point) -> rax
sp_ptr:
    imul    rax, rax, SP_SZ
    add     rax, [rip+ss_pts]
    ret

# sp_new -> rax = a new point record (eax as index in edx), or 0
sp_new:
    mov     eax, [rip+ss_np]
    cmp     eax, 0x40000000/SP_SZ - 1
    jae     8f
    mov     edx, eax
    inc     dword ptr [rip+ss_np]
    jmp     sp_ptr
8:  xor     eax, eax
    ret

# =============================================================================
#  Distances and projections
# =============================================================================
# sf_near(rdi=surface, rsi=point, xmm0/xmm1=hint) -> xmm0, xmm1 = (u, v)
sf_near:
    cmp     dword ptr [rdi+SF_TYPE], ST_NURBS
    je      sf_project
    jmp     sf_invert

# sf_dist(rdi=surface, rsi=point, xmm0/xmm1=hint) -> xmm0 = the signed
#   distance along Su x Sv, xmm1, xmm2 = the nearest (u, v)
sf_dist:
    push    rbx
    push    r12
    sub     rsp, 72
    mov     rbx, rdi
    mov     r12, rsi
    call    sf_near
    movsd   [rsp+48], xmm0
    movsd   [rsp+56], xmm1
    mov     rdi, rbx
    lea     rsi, [rsp]
    call    sf_normal
    lea     rdi, [rsp]                  # (P - S) . N
    mov     rsi, r12
    mov     rdx, rdi
    call    v3sub
    lea     rdi, [rsp]
    lea     rsi, [rsp+24]
    call    v3dot
    movsd   xmm1, [rsp+48]
    movsd   xmm2, [rsp+56]
    add     rsp, 72
    pop     r12
    pop     rbx
    ret

# ss_refine(rdi=surface a, rsi=surface b, rdx=point record) -> eax = 1 when
#   it lies on both (to the tolerance): the tangent planes of the nearest
#   points and the plane across their line through the point, met
.equ RF_PA,   0                         # P, N on a
.equ RF_PB,   48
.equ RF_T,    96
.equ RF_X,    120
.equ RF_W,    144
.equ RF_K,    168
ss_refine:
    push    rbx
    push    r12
    push    r13
    push    r14
    sub     rsp, 200
    mov     rbx, rdi
    mov     r12, rsi
    mov     r13, rdx
    xor     r14d, r14d
.Lrf_it:
    mov     rdi, rbx                    # nearest on a
    mov     rsi, r13
    movsd   xmm0, [r13+24]
    movsd   xmm1, [r13+32]
    call    sf_near
    movsd   [r13+24], xmm0
    movsd   [r13+32], xmm1
    mov     rdi, rbx
    lea     rsi, [rsp+RF_PA]
    call    sf_normal
    mov     rdi, r12                    # on b
    mov     rsi, r13
    movsd   xmm0, [r13+40]
    movsd   xmm1, [r13+48]
    call    sf_near
    movsd   [r13+40], xmm0
    movsd   [r13+48], xmm1
    mov     rdi, r12
    lea     rsi, [rsp+RF_PB]
    call    sf_normal
    lea     rdi, [rsp+RF_PA]            # close enough?
    lea     rsi, [rsp+RF_PB]
    call    v3dist
    movsd   xmm1, [rip+ss_tol]
    mulsd   xmm1, [rip+ss_conv]
    comisd  xmm0, xmm1
    jbe     .Lrf_done
    inc     r14d
    cmp     r14d, 24
    jbe     1f
    comisd  xmm0, [rip+ss_tol]          # (stalled: close enough is enough)
    jbe     .Lrf_done
    jmp     .Lrf_fail
1:
    lea     rdi, [rsp+RF_T]             # t = Na x Nb
    lea     rsi, [rsp+RF_PA+24]
    lea     rdx, [rsp+RF_PB+24]
    call    v3cross
    lea     rdi, [rsp+RF_T]
    call    v3len
    comisd  xmm0, [rip+ss_par]
    jbe     .Lrf_fail                   # tangent
    # X = [ha (Nb x t) + hb (t x Na) + hp (Na x Nb)] / (Na . (Nb x t))
    lea     rdi, [rsp+RF_X]
    lea     rsi, [rsp+RF_PB+24]
    lea     rdx, [rsp+RF_T]
    call    v3cross                     # Nb x t
    lea     rdi, [rsp+RF_PA+24]
    lea     rsi, [rsp+RF_X]
    call    v3dot
    movsd   [rsp+RF_K], xmm0            # det
    lea     rdi, [rsp+RF_PA+24]
    lea     rsi, [rsp+RF_PA]
    call    v3dot
    movsd   [rsp+RF_K+8], xmm0          # ha
    lea     rdi, [rsp+RF_PB+24]
    lea     rsi, [rsp+RF_PB]
    call    v3dot
    movsd   [rsp+RF_K+16], xmm0         # hb
    lea     rdi, [rsp+RF_T]
    mov     rsi, r13
    call    v3dot
    movsd   [rsp+RF_K+24], xmm0         # hp
    lea     rdi, [rsp+RF_W]             # t x Na
    lea     rsi, [rsp+RF_T]
    lea     rdx, [rsp+RF_PA+24]
    call    v3cross
    mov     rdi, r13                    # P = ha (Nb x t) + hb (t x Na) + hp t
    xor     esi, esi
    lea     rdx, [rsp+RF_X]
    movsd   xmm0, [rsp+RF_K+8]
    lea     rcx, [rsp+RF_W]
    movsd   xmm1, [rsp+RF_K+16]
    lea     r8, [rsp+RF_T]
    movsd   xmm2, [rsp+RF_K+24]
    call    lin3
    movsd   xmm1, [rip+ss_one]
    divsd   xmm1, [rsp+RF_K]
    mov     rdi, r13
    mov     rsi, r13
    movsd   xmm0, xmm1
    call    v3scale
    jmp     .Lrf_it
.Lrf_done:
    lea     rdi, [rsp+RF_PA]            # the middle of the two
    lea     rsi, [rsp+RF_PB]
    mov     rdx, r13
    xor     ecx, ecx
2:  movsd   xmm0, [rdi+rcx*8]
    addsd   xmm0, [rsi+rcx*8]
    mulsd   xmm0, [rip+ss_half]
    movsd   [rdx+rcx*8], xmm0
    inc     ecx
    cmp     ecx, 3
    jb      2b
    mov     eax, 1
    jmp     .Lrf_out
.Lrf_fail:
    xor     eax, eax
.Lrf_out:
    add     rsp, 200
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# fc_bbox(edi=face, rsi=out: min xyz, max xyz) - a box around the face: its
#   edges' points and its surface sampled over its (u, v) box
fc_bbox:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    push    rbp
    sub     rsp, 104
    mov     r12, rsi
    call    p_fc
    mov     rbx, rax
    movsd   xmm0, [rip+ss_big]
    movsd   [r12], xmm0
    movsd   [r12+8], xmm0
    movsd   [r12+16], xmm0
    xorpd   xmm0, [rip+ss_negm]
    movsd   [r12+24], xmm0
    movsd   [r12+32], xmm0
    movsd   [r12+40], xmm0
    mov     edi, [rbx+FC_SURF]
    call    p_sf
    mov     r13, rax
    xor     r14d, r14d                  # 9 x 9 samples over the box
1:  cmp     r14d, 8
    ja      4f
    xor     r15d, r15d
2:  cmp     r15d, 8
    ja      3f
    cvtsi2sd xmm0, r14d
    mov     eax, 8
    cvtsi2sd xmm2, eax
    divsd   xmm0, xmm2
    movsd   xmm1, [rbx+FC_U1]
    subsd   xmm1, [rbx+FC_U0]
    mulsd   xmm0, xmm1
    addsd   xmm0, [rbx+FC_U0]
    cvtsi2sd xmm1, r15d
    divsd   xmm1, xmm2
    movsd   xmm3, [rbx+FC_V1]
    subsd   xmm3, [rbx+FC_V0]
    mulsd   xmm1, xmm3
    addsd   xmm1, [rbx+FC_V0]
    mov     rdi, r13
    lea     rsi, [rsp]
    call    srf_eval
    lea     rdi, [rsp]
    call    box_add
    inc     r15d
    jmp     2b
3:  inc     r14d
    jmp     1b
4:  mov     ebp, [rbx+FC_LOOP]          # the edges' points
    mov     eax, [rbx+FC_NLOOP]
    add     eax, ebp
    mov     [rsp+80], eax
5:  cmp     ebp, [rsp+80]
    jae     9f
    mov     edi, ebp
    call    p_lp
    mov     r14d, [rax+LP_FIRST]
    mov     r15d, [rax+LP_N]
    add     r15d, r14d
6:  cmp     r14d, r15d
    jae     8f
    mov     edi, r14d
    call    p_ce
    mov     edi, [rax+CE_EDGE]
    call    p_ed
    mov     rcx, [rax+ED_POLY]
    test    rcx, rcx
    jz      7f
    mov     edx, [rax+ED_NPOLY]
    mov     [rsp+88], edx
    mov     [rsp+96], rcx
    xor     edx, edx
61: cmp     edx, [rsp+88]
    jae     7f
    mov     [rsp+92], edx
    mov     eax, edx
    shl     eax, 5
    mov     rdi, [rsp+96]
    add     rdi, rax
    call    box_add
    mov     edx, [rsp+92]
    inc     edx
    jmp     61b
7:  inc     r14d
    jmp     6b
8:  inc     ebp
    jmp     5b
9:  add     rsp, 104
    pop     rbp
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret
# box_add(rdi=point; r12=box)
box_add:
    xor     ecx, ecx
1:  movsd   xmm0, [rdi+rcx*8]
    movsd   xmm1, [r12+rcx*8]
    minsd   xmm1, xmm0
    movsd   [r12+rcx*8], xmm1
    movsd   xmm1, [r12+24+rcx*8]
    maxsd   xmm1, xmm0
    movsd   [r12+24+rcx*8], xmm1
    inc     ecx
    cmp     ecx, 3
    jb      1b
    ret

# sf_coincide(rdi=surface, rsi=surface) -> eax = 1 if they are the same
#   plane (either way round) or the same cylinder or sphere
sf_coincide:
    push    rbx
    push    r12
    sub     rsp, 40
    mov     rbx, rdi
    mov     r12, rsi
    xor     eax, eax
    mov     ecx, [rbx+SF_TYPE]
    cmp     ecx, [r12+SF_TYPE]
    jne     9f
    cmp     ecx, ST_PLANE
    je      .Lsc_plane
    cmp     ecx, ST_CYL
    je      .Lsc_cyl
    cmp     ecx, ST_SPHERE
    je      .Lsc_sphere
    jmp     9f
.Lsc_plane:
    lea     rdi, [rbx+SF_Z]             # |Za . Zb| ~ 1, (Ob - Oa) . Za ~ 0
    lea     rsi, [r12+SF_Z]
    call    v3dot
    andpd   xmm0, [rip+ss_absm]
    movsd   xmm1, [rip+ss_one]
    subsd   xmm1, xmm0
    xor     eax, eax
    comisd  xmm1, [rip+ss_par]
    ja      9f
    call    ofs_along
    jmp     9f
.Lsc_cyl:
    lea     rdi, [rbx+SF_Z]             # parallel axes, the same radius, b's
    lea     rsi, [r12+SF_Z]             #  origin on a's axis
    call    v3dot
    andpd   xmm0, [rip+ss_absm]
    movsd   xmm1, [rip+ss_one]
    subsd   xmm1, xmm0
    xor     eax, eax
    comisd  xmm1, [rip+ss_par]
    ja      9f
    movsd   xmm0, [rbx+SF_R1]
    subsd   xmm0, [r12+SF_R1]
    andpd   xmm0, [rip+ss_absm]
    comisd  xmm0, [rip+ss_tol]
    ja      9f
    lea     rdi, [rsp]                  # d = Ob - Oa minus its part along Z
    lea     rsi, [r12+SF_O]
    lea     rdx, [rbx+SF_O]
    call    v3sub
    lea     rdi, [rsp]
    lea     rsi, [rbx+SF_Z]
    call    v3dot
    xorpd   xmm0, [rip+ss_negm]
    lea     rdi, [rsp]
    lea     rsi, [rbx+SF_Z]
    call    v3axpy
    lea     rdi, [rsp]
    call    v3len
    xor     eax, eax
    comisd  xmm0, [rip+ss_tol]
    setbe   al
    jmp     9f
.Lsc_sphere:
    movsd   xmm0, [rbx+SF_R1]
    subsd   xmm0, [r12+SF_R1]
    andpd   xmm0, [rip+ss_absm]
    xor     eax, eax
    comisd  xmm0, [rip+ss_tol]
    ja      9f
    lea     rdi, [rbx+SF_O]
    lea     rsi, [r12+SF_O]
    call    v3dist
    xor     eax, eax
    comisd  xmm0, [rip+ss_tol]
    setbe   al
9:  add     rsp, 40
    pop     r12
    pop     rbx
    ret
# ofs_along (sf_coincide's planes) -> eax = 1 if b's origin is in a's plane
ofs_along:
    sub     rsp, 40
    lea     rdi, [rsp]
    lea     rsi, [r12+SF_O]
    lea     rdx, [rbx+SF_O]
    call    v3sub
    lea     rdi, [rsp]
    lea     rsi, [rbx+SF_Z]
    call    v3dot
    andpd   xmm0, [rip+ss_absm]
    xor     eax, eax
    comisd  xmm0, [rip+ss_tol]
    setbe   al
    add     rsp, 40
    ret

# =============================================================================
#  Sections
# =============================================================================
# sc_begin -> rax = a new section record (its points start now), or 0
sc_begin:
    mov     eax, [rip+ss_n]
    cmp     eax, MAXSS
    jae     8f
    imul    eax, eax, SS_SZ
    lea     rcx, [rip+ss_rec]
    add     rax, rcx
    mov     ecx, [rip+sa_f]
    mov     edx, [rip+sb_f]
    cmp     dword ptr [rip+ss_swap], 0
    je      1f
    xchg    ecx, edx
1:  mov     [rax+SS_FA], ecx
    mov     [rax+SS_FB], edx
    mov     ecx, [rip+ss_np]
    mov     [rax+SS_FIRST], ecx
    mov     dword ptr [rax+SS_N], 0
    mov     dword ptr [rax+SS_CLOSED], 0
    mov     dword ptr [rax+SS_CURVE], -1
    ret
8:  xor     eax, eax
    ret
# sc_end(rdi=record) - counted when it has two points or more
sc_end:
    mov     eax, [rip+ss_np]
    sub     eax, [rdi+SS_FIRST]
    mov     [rdi+SS_N], eax
    cmp     eax, 2
    jb      1f
    inc     dword ptr [rip+ss_n]
    ret
1:  mov     eax, [rdi+SS_FIRST]
    mov     [rip+ss_np], eax
    ret

# sc_point(rsi=3D point, xmm0/xmm1 = (u, v) hint on the grid face) -> eax = 1
#   if added: a point on both surfaces, (u, v) on each (in a, b order)
.equ SQ_P,   0
sc_point:
    push    rbx
    sub     rsp, 80
    mov     rbx, rsi
    movsd   [rsp+64], xmm0
    movsd   [rsp+72], xmm1
    call    sp_new
    test    rax, rax
    jz      8f
    mov     rbx, rax
    movupd  xmm0, [rsi]
    movupd  [rbx], xmm0
    mov     rcx, [rsi+16]
    mov     [rbx+16], rcx
    movsd   xmm0, [rsp+64]              # hints: the grid face's (u, v) for
    movsd   xmm1, [rsp+72]              #  it, the other's box middle
    movsd   [rbx+24], xmm0
    movsd   [rbx+32], xmm1
    lea     rax, [rip+sb_box]
    movsd   xmm0, [rax]
    addsd   xmm0, [rax+8]
    mulsd   xmm0, [rip+ss_half]
    movsd   [rbx+40], xmm0
    movsd   xmm0, [rax+16]
    addsd   xmm0, [rax+24]
    mulsd   xmm0, [rip+ss_half]
    movsd   [rbx+48], xmm0
    cmp     dword ptr [rip+sp_cont], 0  # continuing a curve: the last's
    je      1f
    mov     eax, [rip+ss_np]
    sub     eax, 2
    js      1f
    call    sp_ptr
    mov     ecx, 40                     # (stored in a, b order: the other
    cmp     dword ptr [rip+ss_swap], 0  #  face's are first when swapped)
    je      11f
    mov     ecx, 24
11: movsd   xmm0, [rax+rcx]
    movsd   [rbx+40], xmm0
    movsd   xmm0, [rax+rcx+8]
    movsd   [rbx+48], xmm0
1:  mov     rdi, [rip+sa_s]
    mov     rsi, [rip+sb_s]
    mov     rdx, rbx
    call    ss_refine
    test    eax, eax
    jz      7f
    cmp     dword ptr [rip+ss_swap], 0  # stored in (face a, face b) order
    je      2f
    movupd  xmm0, [rbx+24]
    movupd  xmm1, [rbx+40]
    movupd  [rbx+24], xmm1
    movupd  [rbx+40], xmm0
2:  mov     eax, 1
    jmp     9f
7:  dec     dword ptr [rip+ss_np]       # (not on both: dropped)
8:  xor     eax, eax
9:  add     rsp, 80
    pop     rbx
    ret

.section .bss
sp_cont:        .skip 4
.text

# ssi(edi=face a, esi=face b) - their sections appended
.equ SI_BOXA, 0
.equ SI_BOXB, 48
.equ SI_T,    96
ssi:
    push    rbx
    push    r12
    push    r13
    sub     rsp, 160
    mov     [rip+sa_f], edi
    mov     [rip+sb_f], esi
    mov     dword ptr [rip+ss_swap], 0
    # the grid goes on the smaller face: swap so a is the smaller
    lea     rsi, [rsp+SI_BOXA]
    call    fc_bbox
    mov     edi, [rip+sb_f]
    lea     rsi, [rsp+SI_BOXB]
    call    fc_bbox
    lea     rdi, [rsp+SI_BOXA]
    lea     rsi, [rsp+SI_BOXA+24]
    call    v3dist
    movsd   [rsp+SI_T], xmm0
    lea     rdi, [rsp+SI_BOXB]
    lea     rsi, [rsp+SI_BOXB+24]
    call    v3dist
    comisd  xmm0, [rsp+SI_T]
    jae     1f
    mov     eax, [rip+sa_f]
    mov     ecx, [rip+sb_f]
    mov     [rip+sa_f], ecx
    mov     [rip+sb_f], eax
    mov     dword ptr [rip+ss_swap], 1
1:  mov     edi, [rip+sa_f]
    call    p_fc
    mov     rbx, rax
    mov     edi, [rbx+FC_SURF]
    call    p_sf
    mov     [rip+sa_s], rax
    lea     rdi, [rip+sa_box]
    lea     rsi, [rbx+FC_U0]
    mov     ecx, 4
    rep     movsq
    mov     edi, [rip+sb_f]
    call    p_fc
    mov     rbx, rax
    mov     edi, [rbx+FC_SURF]
    call    p_sf
    mov     [rip+sb_s], rax
    lea     rdi, [rip+sb_box]
    lea     rsi, [rbx+FC_U0]
    mov     ecx, 4
    rep     movsq
    mov     rdi, [rip+sa_s]
    mov     rsi, [rip+sb_s]
    call    sf_coincide
    test    eax, eax
    jnz     .Lsi_out                    # (the boolean handles these)
    mov     rax, [rip+sa_s]
    mov     rcx, [rip+sb_s]
    mov     edx, [rax+SF_TYPE]
    mov     r8d, [rcx+SF_TYPE]
    cmp     edx, ST_PLANE               # plane against something: maybe exact
    je      2f
    cmp     r8d, ST_PLANE
    jne     .Lsi_march
    call    exact_plane_b               # (b is the plane)
    test    eax, eax
    jnz     .Lsi_out
    jmp     .Lsi_march
2:  call    exact_plane_a
    test    eax, eax
    jnz     .Lsi_out
.Lsi_march:
    call    march
.Lsi_out:
    add     rsp, 160
    pop     r13
    pop     r12
    pop     rbx
    ret

# exact_plane_b - b is a plane: a's role and b's swapped for the exact cases
exact_plane_b:
    sub     rsp, 8
    mov     rax, [rip+sa_s]
    mov     rcx, [rip+sb_s]
    mov     [rip+sa_s], rcx
    mov     [rip+sb_s], rax
    mov     eax, [rip+sa_f]
    mov     ecx, [rip+sb_f]
    mov     [rip+sa_f], ecx
    mov     [rip+sb_f], eax
    xor     dword ptr [rip+ss_swap], 1
    lea     rdi, [rip+sa_box]           # boxes too
    lea     rsi, [rip+sb_box]
    mov     ecx, 4
1:  mov     rax, [rdi]
    mov     rdx, [rsi]
    mov     [rdi], rdx
    mov     [rsi], rax
    add     rdi, 8
    add     rsi, 8
    loop    1b
    call    exact_plane_a
    test    eax, eax
    jnz     9f
    push    rax                         # not exact: swap back for the march
    mov     rax, [rip+sa_s]
    mov     rcx, [rip+sb_s]
    mov     [rip+sa_s], rcx
    mov     [rip+sb_s], rax
    mov     eax, [rip+sa_f]
    mov     ecx, [rip+sb_f]
    mov     [rip+sa_f], ecx
    mov     [rip+sb_f], eax
    xor     dword ptr [rip+ss_swap], 1
    lea     rdi, [rip+sa_box]
    lea     rsi, [rip+sb_box]
    mov     ecx, 4
2:  mov     rax, [rdi]
    mov     rdx, [rsi]
    mov     [rdi], rdx
    mov     [rsi], rax
    add     rdi, 8
    add     rsi, 8
    loop    2b
    pop     rax
9:  add     rsp, 8
    ret

# exact_plane_a -> eax = 1 if solved: a is a plane; b a plane, or a cylinder,
#   sphere or cone across its axis, or a cylinder along it
.equ EX_N,    0                         # a's normal and offset
.equ EX_H,    24
.equ EX_C,    32                        # circle / line: O, X, Y
.equ EX_R,    104
.equ EX_P,    112                       # a point
.equ EX_D,    136
.equ EX_T,    160
.equ EX_K,    168
.equ EX_S,    176
exact_plane_a:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    sub     rsp, 224
    mov     rbx, [rip+sa_s]
    mov     r12, [rip+sb_s]
    lea     rdi, [rsp+EX_N]
    lea     rsi, [rbx+SF_Z]
    movsd   xmm0, [rip+ss_one]
    call    v3scale
    lea     rdi, [rsp+EX_N]
    lea     rsi, [rbx+SF_O]
    call    v3dot
    movsd   [rsp+EX_H], xmm0
    mov     eax, [r12+SF_TYPE]
    cmp     eax, ST_PLANE
    je      .Lex_pp
    cmp     eax, ST_CYL
    je      .Lex_cyl
    cmp     eax, ST_SPHERE
    je      .Lex_sphere
    cmp     eax, ST_CONE
    je      .Lex_cone
    jmp     .Lex_no
.Lex_pp:
    # the line: direction Na x Nb, a point on both
    lea     rdi, [rsp+EX_D]
    lea     rsi, [rsp+EX_N]
    lea     rdx, [r12+SF_Z]
    call    v3cross
    lea     rdi, [rsp+EX_D]
    call    v3norm
    comisd  xmm0, [rip+ss_par]
    jbe     .Lex_none                   # parallel planes: nothing
    # P = (ha (Nb x D) + hb (D x Na)) / (Na . (Nb x D))
    lea     rdi, [r12+SF_Z]
    lea     rsi, [r12+SF_O]
    call    v3dot
    movsd   [rsp+EX_T], xmm0            # hb
    lea     rdi, [rsp+EX_C]
    lea     rsi, [r12+SF_Z]
    lea     rdx, [rsp+EX_D]
    call    v3cross
    lea     rdi, [rsp+EX_C+24]
    lea     rsi, [rsp+EX_D]
    lea     rdx, [rsp+EX_N]
    call    v3cross
    lea     rdi, [rsp+EX_N]
    lea     rsi, [rsp+EX_C]
    call    v3dot
    movsd   [rsp+EX_K], xmm0
    lea     rdi, [rsp+EX_P]
    xor     esi, esi
    lea     rdx, [rsp+EX_C]
    movsd   xmm0, [rsp+EX_H]
    lea     rcx, [rsp+EX_C+24]
    movsd   xmm1, [rsp+EX_T]
    xor     r8d, r8d
    call    lin3
    movsd   xmm0, [rip+ss_one]
    divsd   xmm0, [rsp+EX_K]
    lea     rdi, [rsp+EX_P]
    lea     rsi, [rsp+EX_P]
    call    v3scale
    call    ex_line
    jmp     .Lex_yes
.Lex_cyl:
    lea     rdi, [rsp+EX_N]             # n . Z
    lea     rsi, [r12+SF_Z]
    call    v3dot
    movsd   [rsp+EX_T], xmm0
    andpd   xmm0, [rip+ss_absm]
    movsd   xmm1, [rip+ss_one]
    subsd   xmm1, xmm0
    comisd  xmm1, [rip+ss_par]
    jbe     .Lex_cyl_across
    comisd  xmm0, [rip+ss_par]
    jbe     .Lex_cyl_along
    jmp     .Lex_no                     # oblique: an ellipse, traced
.Lex_cyl_across:
    # the circle: centre O + ((h - n.O) / (n.Z)) Z, the cylinder's X, Y, R
    call    ex_axis_centre
    movsd   xmm0, [r12+SF_R1]
    movsd   [rsp+EX_R], xmm0
    call    ex_circle
    jmp     .Lex_yes
.Lex_sphere:
    lea     rdi, [rsp+EX_N]             # d = n . O - h; |d| < R
    lea     rsi, [r12+SF_O]
    call    v3dot
    subsd   xmm0, [rsp+EX_H]
    movsd   [rsp+EX_T], xmm0
    movsd   xmm1, [r12+SF_R1]
    mulsd   xmm1, xmm1
    mulsd   xmm0, xmm0
    subsd   xmm1, xmm0
    xorpd   xmm2, xmm2
    comisd  xmm1, xmm2
    jbe     .Lex_none
    sqrtsd  xmm1, xmm1
    movsd   [rsp+EX_R], xmm1
    lea     rdi, [rsp+EX_C]             # centre O - d n, frame in the plane
    lea     rsi, [r12+SF_O]
    lea     rdx, [rsp+EX_N]
    movsd   xmm0, [rsp+EX_T]
    xorpd   xmm0, [rip+ss_negm]
    xor     ecx, ecx
    xor     r8d, r8d
    call    lin3
    lea     rdi, [rsp+EX_C+24]
    lea     rsi, [rbx+SF_X]
    movsd   xmm0, [rip+ss_one]
    call    v3scale
    lea     rdi, [rsp+EX_C+48]
    lea     rsi, [rbx+SF_Y]
    movsd   xmm0, [rip+ss_one]
    call    v3scale
    call    ex_circle
    jmp     .Lex_yes
.Lex_cone:
    lea     rdi, [rsp+EX_N]
    lea     rsi, [r12+SF_Z]
    call    v3dot
    movsd   [rsp+EX_T], xmm0
    andpd   xmm0, [rip+ss_absm]
    movsd   xmm1, [rip+ss_one]
    subsd   xmm1, xmm0
    comisd  xmm1, [rip+ss_par]
    ja      .Lex_no
    call    ex_axis_centre              # the circle at that height:
    lea     rdi, [rsp+EX_P]             #  R + v sin a with v = z / cos a
    lea     rsi, [rsp+EX_C]
    lea     rdx, [r12+SF_O]
    call    v3sub
    lea     rdi, [rsp+EX_P]
    lea     rsi, [r12+SF_Z]
    call    v3dot
    divsd   xmm0, [r12+SF_CA]
    mulsd   xmm0, [r12+SF_SA]
    addsd   xmm0, [r12+SF_R1]
    xorpd   xmm1, xmm1
    comisd  xmm0, xmm1
    jbe     .Lex_none
    movsd   [rsp+EX_R], xmm0
    call    ex_circle
    jmp     .Lex_yes
.Lex_cyl_along:
    # lines along Z at the two places the plane cuts the circle: the axis
    # point's distance to the plane d, |d| < R; in the plane, along w = n x Z
    lea     rdi, [rsp+EX_N]
    lea     rsi, [r12+SF_O]
    call    v3dot
    subsd   xmm0, [rsp+EX_H]
    movsd   [rsp+EX_T], xmm0            # d
    movsd   xmm1, [r12+SF_R1]
    mulsd   xmm1, xmm1
    mulsd   xmm0, xmm0
    subsd   xmm1, xmm0
    movsd   xmm2, [rip+ss_tol]
    mulsd   xmm2, [r12+SF_R1]
    comisd  xmm1, xmm2
    jbe     .Lex_none                   # (touching: nothing)
    sqrtsd  xmm1, xmm1
    movsd   [rsp+EX_R], xmm1            # half chord
    lea     rdi, [rsp+EX_C+24]          # w = n x Z
    lea     rsi, [rsp+EX_N]
    lea     rdx, [r12+SF_Z]
    call    v3cross
    lea     rdi, [rsp+EX_C+24]
    call    v3norm
    lea     rdi, [rsp+EX_D]             # direction Z
    lea     rsi, [r12+SF_Z]
    movsd   xmm0, [rip+ss_one]
    call    v3scale
    xor     r13d, r13d
1:  cmp     r13d, 2
    jae     .Lex_yes
    movsd   xmm1, [rsp+EX_R]            # P = O - d n +- c w
    test    r13d, r13d
    jz      2f
    xorpd   xmm1, [rip+ss_negm]
2:  movsd   xmm0, [rsp+EX_T]
    xorpd   xmm0, [rip+ss_negm]
    lea     rdi, [rsp+EX_P]
    lea     rsi, [r12+SF_O]
    lea     rdx, [rsp+EX_N]
    lea     rcx, [rsp+EX_C+24]
    xor     r8d, r8d
    call    lin3
    call    ex_line
    inc     r13d
    jmp     1b
.Lex_none:
.Lex_yes:
    mov     eax, 1
    jmp     .Lex_out
.Lex_no:
    xor     eax, eax
.Lex_out:
    add     rsp, 224
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# ex_axis_centre (exact_plane_a's frame) - EX_C: b's axis meets a's plane;
#   EX_C+24, +48: b's X, Y
ex_axis_centre:
    push    rbx
    lea     rbx, [rsp+16]               # (the caller's frame)
    lea     rdi, [rbx+EX_N]
    lea     rsi, [r12+SF_O]
    call    v3dot
    movsd   xmm1, [rbx+EX_H]
    subsd   xmm1, xmm0
    divsd   xmm1, [rbx+EX_T]
    lea     rdi, [rbx+EX_C]
    lea     rsi, [r12+SF_O]
    lea     rdx, [r12+SF_Z]
    movsd   xmm0, xmm1
    xor     ecx, ecx
    xor     r8d, r8d
    call    lin3
    lea     rdi, [rbx+EX_C+24]
    lea     rsi, [r12+SF_X]
    movsd   xmm0, [rip+ss_one]
    call    v3scale
    lea     rdi, [rbx+EX_C+48]
    lea     rsi, [r12+SF_Y]
    movsd   xmm0, [rip+ss_one]
    call    v3scale
    pop     rbx
    ret

# ex_circle (exact_plane_a's frame) - the circle EX_C (O X Y), EX_R as a
#   closed section, 128 points
ex_circle:
    push    rbx
    push    r13
    push    r14
    push    r15
    sub     rsp, 56
    lea     rbx, [rsp+56+32+8]          # (the caller's frame)
    mov     edi, CT_CIRCLE
    lea     rsi, [rbx+EX_C]
    movsd   xmm0, [rbx+EX_R]
    movsd   xmm1, xmm0
    call    mk_conic
    mov     r15d, eax
    call    sc_begin
    test    rax, rax
    jz      9f
    mov     r14, rax
    mov     [r14+SS_CURVE], r15d
    mov     dword ptr [r14+SS_CLOSED], 1
    mov     dword ptr [rip+sp_cont], 1
    xor     r13d, r13d
1:  cmp     r13d, 128
    jae     8f
    cvtsi2sd xmm0, r13d
    mulsd   xmm0, [rip+ss_seg]
    movsd   [rsp+48], xmm0
    call    dsincos
    mulsd   xmm1, [rbx+EX_R]
    mulsd   xmm0, [rbx+EX_R]
    movsd   [rsp+40], xmm0
    movsd   xmm0, xmm1
    movsd   xmm1, [rsp+40]
    lea     rdi, [rsp]
    lea     rsi, [rbx+EX_C]
    lea     rdx, [rbx+EX_C+24]
    lea     rcx, [rbx+EX_C+48]
    xor     r8d, r8d
    call    lin3
    call    grid_hint                   # the grid face's (u, v) for it
    lea     rsi, [rsp]
    call    sc_point
    inc     r13d
    jmp     1b
8:  mov     dword ptr [rip+sp_cont], 0
    mov     rdi, r14
    call    sc_end
9:  add     rsp, 56
    pop     r15
    pop     r14
    pop     r13
    pop     rbx
    ret

# grid_hint(the caller's [rsp+8]: a point) -> xmm0, xmm1 = its (u, v) on
#   face a (the plane in the exact cases)
grid_hint:
    push    rbx
    lea     rbx, [rsp+16]
    mov     rdi, [rip+sa_s]
    mov     rsi, rbx
    lea     rax, [rip+sa_box]
    movsd   xmm0, [rax]
    addsd   xmm0, [rax+8]
    mulsd   xmm0, [rip+ss_half]
    movsd   xmm1, [rax+16]
    addsd   xmm1, [rax+24]
    mulsd   xmm1, [rip+ss_half]
    call    sf_near
    pop     rbx
    ret

# ex_line (exact_plane_a's frame) - the line through EX_P along EX_D, as an
#   open section across both faces' boxes (a little past them)
ex_line:
    push    rbx
    push    r13
    push    r14
    push    r15
    sub     rsp, 120
    lea     rbx, [rsp+120+32+8]
    # the parameter range: the faces' 3D boxes' corners projected
    mov     edi, [rip+sa_f]
    lea     rsi, [rsp]
    call    fc_bbox
    mov     edi, [rip+sb_f]
    lea     rsi, [rsp+48]
    call    fc_bbox
    movsd   xmm0, [rip+ss_big]
    movsd   [rsp+96], xmm0              # tmin
    xorpd   xmm0, [rip+ss_negm]
    movsd   [rsp+104], xmm0             # tmax
    xor     r13d, r13d                  # 16 corners
1:  cmp     r13d, 16
    jae     3f
    xor     ecx, ecx
    xorpd   xmm2, xmm2                  # (corner - P) . D
2:  mov     eax, r13d                   # bit c of the corner: min or max
    shr     eax, cl
    and     eax, 1
    imul    eax, eax, 24
    mov     edx, r13d
    and     edx, 8
    imul    edx, edx, 6                 # (box 1 at 48)
    add     eax, edx
    lea     rdx, [rcx*8]
    add     eax, edx
    movsd   xmm0, [rsp+rax]
    subsd   xmm0, [rbx+EX_P+rcx*8]
    mulsd   xmm0, [rbx+EX_D+rcx*8]
    addsd   xmm2, xmm0
    inc     ecx
    cmp     ecx, 3
    jb      2b
    movsd   xmm0, [rsp+96]
    minsd   xmm0, xmm2
    movsd   [rsp+96], xmm0
    movsd   xmm0, [rsp+104]
    maxsd   xmm0, xmm2
    movsd   [rsp+104], xmm0
    inc     r13d
    jmp     1b
3:  movsd   xmm0, [rsp+104]             # 5% past each end
    subsd   xmm0, [rsp+96]
    mulsd   xmm0, [rip+ss_ext]
    addsd   xmm0, xmm0
    addsd   xmm0, xmm0
    addsd   xmm0, [rip+ss_tol]
    movsd   xmm1, [rsp+96]
    subsd   xmm1, xmm0
    movsd   [rsp+96], xmm1
    movsd   xmm1, [rsp+104]
    addsd   xmm1, xmm0
    movsd   [rsp+104], xmm1
    lea     rdi, [rsp]                  # the exact line
    lea     rsi, [rbx+EX_P]
    lea     rdx, [rbx+EX_D]
    movsd   xmm0, [rip+ss_one]
    xor     ecx, ecx
    xor     r8d, r8d
    sub     rsp, 8
    call    lin3
    add     rsp, 8
    lea     rdi, [rbx+EX_P]
    lea     rsi, [rsp]
    call    mk_line
    mov     r15d, eax
    call    sc_begin
    test    rax, rax
    jz      9f
    mov     r14, rax
    mov     [r14+SS_CURVE], r15d
    xor     r13d, r13d                  # points: the ends and 30 between
4:  cmp     r13d, 32
    ja      8f
    cvtsi2sd xmm0, r13d
    mov     eax, 32
    cvtsi2sd xmm1, eax
    divsd   xmm0, xmm1
    movsd   xmm1, [rsp+104]
    subsd   xmm1, [rsp+96]
    mulsd   xmm0, xmm1
    addsd   xmm0, [rsp+96]
    lea     rdi, [rsp+48]
    lea     rsi, [rbx+EX_P]
    lea     rdx, [rbx+EX_D]
    xor     ecx, ecx
    xor     r8d, r8d
    call    lin3
    mov     rdi, [rip+sa_s]
    lea     rsi, [rsp+48]
    lea     rax, [rip+sa_box]
    movsd   xmm0, [rax]
    addsd   xmm0, [rax+8]
    mulsd   xmm0, [rip+ss_half]
    movsd   xmm1, [rax+16]
    addsd   xmm1, [rax+24]
    mulsd   xmm1, [rip+ss_half]
    call    sf_near
    lea     rsi, [rsp+48]
    call    sc_point
    inc     r13d
    jmp     4b
8:  mov     rdi, r14
    call    sc_end
9:  add     rsp, 120
    pop     r15
    pop     r14
    pop     r13
    pop     rbx
    ret

# =============================================================================
#  Tracing (marching squares over face a)
# =============================================================================
# gr_val(edi=i, esi=j) -> xmm0 = the value at grid node (i, j)
gr_val:
    mov     eax, [rip+gr_nu]
    inc     eax
    imul    eax, esi
    add     eax, edi
    mov     rcx, [rip+gr_f]
    movsd   xmm0, [rcx+rax*8]
    ret

# gr_uv(edi=i, esi=j) -> xmm0, xmm1
gr_uv:
    cvtsi2sd xmm0, edi
    mulsd   xmm0, [rip+gr_du]
    addsd   xmm0, [rip+gr_u0]
    cvtsi2sd xmm1, esi
    mulsd   xmm1, [rip+gr_dv]
    addsd   xmm1, [rip+gr_v0]
    ret

# march - the zero contour of the distance to b over face a's grid
.equ MA_I,    0
.equ MA_J,    4
.equ MA_EV,   8                         # srf_eval out
.equ MA_LU,   80
.equ MA_LV,   88
.equ MA_E,    96                        # crossing edge ids of a cell (4)
.equ MA_NE,   112
.equ MA_CUR,  116
.equ MA_PREV, 120
.equ MA_REC,  128
march:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    push    rbp
    sub     rsp, 152
    # the grid: the box 2% bigger each way, cells by the metric lengths
    lea     rax, [rip+sa_box]
    movsd   xmm0, [rax+8]
    subsd   xmm0, [rax]
    mulsd   xmm0, [rip+ss_ext]
    movsd   xmm1, [rax]
    subsd   xmm1, xmm0
    movsd   [rip+gr_u0], xmm1
    movsd   xmm1, [rax+8]
    addsd   xmm1, xmm0
    subsd   xmm1, [rip+gr_u0]
    movsd   [rsp+MA_LU], xmm1           # u span
    movsd   xmm0, [rax+24]
    subsd   xmm0, [rax+16]
    mulsd   xmm0, [rip+ss_ext]
    movsd   xmm1, [rax+16]
    subsd   xmm1, xmm0
    movsd   [rip+gr_v0], xmm1
    movsd   xmm1, [rax+24]
    addsd   xmm1, xmm0
    subsd   xmm1, [rip+gr_v0]
    movsd   [rsp+MA_LV], xmm1
    lea     rax, [rip+sa_box]           # metric at the middle
    movsd   xmm0, [rax]
    addsd   xmm0, [rax+8]
    mulsd   xmm0, [rip+ss_half]
    movsd   xmm1, [rax+16]
    addsd   xmm1, [rax+24]
    mulsd   xmm1, [rip+ss_half]
    mov     rdi, [rip+sa_s]
    lea     rsi, [rsp+MA_EV]
    call    srf_eval
    lea     rdi, [rsp+MA_EV+24]
    call    v3len
    mulsd   xmm0, [rsp+MA_LU]
    movsd   [rsp+MA_E], xmm0            # metric lengths Lu, Lv
    lea     rdi, [rsp+MA_EV+48]
    call    v3len
    mulsd   xmm0, [rsp+MA_LV]
    maxsd   xmm0, [rip+ss_tiny]
    movsd   xmm1, [rsp+MA_E]            # nu = sqrt(N Lu / Lv), 4 .. 400
    maxsd   xmm1, [rip+ss_tiny]
    divsd   xmm1, xmm0
    mov     eax, GRIDN
    cvtsi2sd xmm2, eax
    mulsd   xmm1, xmm2
    sqrtsd  xmm1, xmm1
    maxsd   xmm1, [rip+ss_four]
    minsd   xmm1, [rip+ss_400]
    cvttsd2si eax, xmm1
    mov     [rip+gr_nu], eax
    cvtsi2sd xmm1, eax
    divsd   xmm2, xmm1
    maxsd   xmm2, [rip+ss_four]
    minsd   xmm2, [rip+ss_400]
    cvttsd2si eax, xmm2
    mov     [rip+gr_nv], eax
    movsd   xmm0, [rsp+MA_LU]
    cvtsi2sd xmm1, dword ptr [rip+gr_nu]
    divsd   xmm0, xmm1
    movsd   [rip+gr_du], xmm0
    movsd   xmm0, [rsp+MA_LV]
    cvtsi2sd xmm1, dword ptr [rip+gr_nv]
    divsd   xmm0, xmm1
    movsd   [rip+gr_dv], xmm0
    # values
    mov     eax, [rip+gr_nu]
    inc     eax
    mov     ecx, [rip+gr_nv]
    inc     ecx
    imul    eax, ecx
    lea     edi, [rax*8+16]
    call    bk_data
    mov     [rip+gr_f], rax
    xor     r13d, r13d                  # j
1:  cmp     r13d, [rip+gr_nv]
    ja      4f
    xor     r12d, r12d                  # i
    lea     rax, [rip+sb_box]
    movsd   xmm0, [rax]
    addsd   xmm0, [rax+8]
    mulsd   xmm0, [rip+ss_half]
    movsd   [rsp+MA_LU], xmm0           # (b's hint carried along the row)
    movsd   xmm0, [rax+16]
    addsd   xmm0, [rax+24]
    mulsd   xmm0, [rip+ss_half]
    movsd   [rsp+MA_LV], xmm0
2:  cmp     r12d, [rip+gr_nu]
    ja      3f
    mov     edi, r12d
    mov     esi, r13d
    call    gr_uv
    mov     rdi, [rip+sa_s]
    lea     rsi, [rsp+MA_EV]
    call    srf_eval
    mov     rdi, [rip+sb_s]
    lea     rsi, [rsp+MA_EV]
    movsd   xmm0, [rsp+MA_LU]
    movsd   xmm1, [rsp+MA_LV]
    call    sf_dist
    movsd   [rsp+MA_LU], xmm1
    movsd   [rsp+MA_LV], xmm2
    mov     eax, [rip+gr_nu]
    inc     eax
    imul    eax, r13d
    add     eax, r12d
    mov     rcx, [rip+gr_f]
    movsd   [rcx+rax*8], xmm0
    inc     r12d
    jmp     2b
3:  inc     r13d
    jmp     1b
4:  # crossings: one slot per grid edge (u, v, link a, link b); horizontal
    # edges (i, j)-(i+1, j) first, then vertical ones
    mov     eax, [rip+gr_nu]
    inc     eax
    mov     ecx, [rip+gr_nv]
    inc     ecx
    imul    eax, ecx
    shl     eax, 1
    mov     [rsp+MA_REC], eax           # slots
    shl     eax, 5
    lea     edi, [rax+16]
    call    bk_data
    mov     [rip+gr_x], rax
    mov     rdi, rax
    mov     ecx, [rsp+MA_REC]
    shl     ecx, 2
    mov     rax, -1
    rep     stosq
    xor     r13d, r13d                  # cells: link the crossings
.Lma_j:
    cmp     r13d, [rip+gr_nv]
    jae     .Lma_trace
    xor     r12d, r12d
.Lma_i:
    cmp     r12d, [rip+gr_nu]
    jae     .Lma_jn
    mov     dword ptr [rsp+MA_NE], 0
    mov     edi, r12d                   # bottom edge (i,j)-(i+1,j)
    mov     esi, r13d
    lea     edx, [r12+1]
    mov     ecx, r13d
    call    cross_edge
    mov     edi, r12d                   # right edge (i+1,j)-(i+1,j+1)
    inc     edi
    mov     esi, r13d
    lea     edx, [r12+1]
    lea     ecx, [r13+1]
    call    cross_edge
    mov     edi, r12d                   # top edge (i,j+1)-(i+1,j+1)
    lea     esi, [r13+1]
    lea     edx, [r12+1]
    lea     ecx, [r13+1]
    call    cross_edge
    mov     edi, r12d                   # left edge (i,j)-(i,j+1)
    mov     esi, r13d
    mov     edx, r12d
    lea     ecx, [r13+1]
    call    cross_edge
    cmp     dword ptr [rsp+MA_NE], 2
    jne     5f
    mov     edi, [rsp+MA_E]
    mov     esi, [rsp+MA_E+4]
    call    link
    jmp     .Lma_in
5:  cmp     dword ptr [rsp+MA_NE], 4    # a saddle: pair by the centre's sign
    jne     .Lma_in
    mov     edi, r12d
    mov     esi, r13d
    call    gr_val
    movsd   xmm4, xmm0
    lea     edi, [r12+1]
    mov     esi, r13d
    call    gr_val
    addsd   xmm4, xmm0
    lea     edi, [r12+1]
    lea     esi, [r13+1]
    call    gr_val
    addsd   xmm4, xmm0
    mov     edi, r12d
    lea     esi, [r13+1]
    call    gr_val
    addsd   xmm4, xmm0
    movsd   [rsp+MA_EV], xmm4
    mov     edi, r12d
    mov     esi, r13d
    call    gr_val
    mulsd   xmm0, [rsp+MA_EV]
    xorpd   xmm1, xmm1
    comisd  xmm0, xmm1
    jb      6f
    mov     edi, [rsp+MA_E]             # corner (i,j) with the centre:
    mov     esi, [rsp+MA_E+4]           #  bottom-right, top-left
    call    link
    mov     edi, [rsp+MA_E+8]
    mov     esi, [rsp+MA_E+12]
    call    link
    jmp     .Lma_in
6:  mov     edi, [rsp+MA_E]             # bottom-left, right-top
    mov     esi, [rsp+MA_E+12]
    call    link
    mov     edi, [rsp+MA_E+4]
    mov     esi, [rsp+MA_E+8]
    call    link
.Lma_in:
    inc     r12d
    jmp     .Lma_i
.Lma_jn:
    inc     r13d
    jmp     .Lma_j
.Lma_trace:
    # chains: from open ends first, then closed loops
    xor     ebp, ebp                    # pass 0: ends; pass 1: the rest
.Lma_pass:
    cmp     ebp, 2
    jae     .Lma_out
    xor     ebx, ebx
.Lma_slot:
    cmp     ebx, [rsp+MA_REC]
    jae     .Lma_pnext
    mov     eax, ebx
    shl     eax, 5
    add     rax, [rip+gr_x]
    cmp     qword ptr [rax], -1         # a crossing not yet traced
    je      .Lma_snext
    cmp     dword ptr [rax+24], 0       # (traced mark)
    jne     .Lma_snext
    xor     ecx, ecx                    # links: pass 0 wants one (an open
    cmp     dword ptr [rax+16], -1      #  end), pass 1 two (closed)
    setne   cl
    xor     edx, edx
    cmp     dword ptr [rax+20], -1
    setne   dl
    add     ecx, edx
    lea     edx, [rbp+1]
    cmp     ecx, edx
    jne     .Lma_snext
    mov     edi, ebx
    mov     esi, ebp
    call    trace
.Lma_snext:
    inc     ebx
    jmp     .Lma_slot
.Lma_pnext:
    inc     ebp
    jmp     .Lma_pass
.Lma_out:
    add     rsp, 152
    pop     rbp
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# cross_edge(edi=i0, esi=j0, edx=i1, ecx=j1; march's frame) - a crossing on
#   that grid edge (made once), its id added to the cell's list
cross_edge:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    sub     rsp, 48
    lea     r15, [rsp+48+40+8]          # march's frame
    mov     ebx, edi
    mov     r12d, esi
    mov     r13d, edx
    mov     r14d, ecx
    call    gr_val
    movsd   [rsp], xmm0
    mov     edi, r13d
    mov     esi, r14d
    call    gr_val
    movsd   [rsp+8], xmm0
    xorpd   xmm2, xmm2                  # a sign change (zero counts as +)
    xor     eax, eax
    xor     ecx, ecx
    comisd  xmm0, xmm2
    setae   al
    movsd   xmm1, [rsp]
    comisd  xmm1, xmm2
    setae   cl
    cmp     eax, ecx
    je      9f
    mov     eax, [rip+gr_nu]            # the edge's id
    inc     eax
    imul    eax, r12d
    add     eax, ebx
    cmp     r12d, r14d
    je      1f
    mov     ecx, [rip+gr_nu]            # vertical: after the horizontal ones
    inc     ecx
    mov     edx, [rip+gr_nv]
    inc     edx
    imul    ecx, edx
    add     eax, ecx
1:  mov     [rsp+16], eax
    mov     ecx, eax
    shl     rcx, 5
    add     rcx, [rip+gr_x]
    cmp     qword ptr [rcx], -1
    jne     2f
    movsd   xmm0, [rsp]                 # f0 / (f0 - f1) along the edge
    movsd   xmm1, xmm0
    subsd   xmm1, [rsp+8]
    divsd   xmm0, xmm1
    movsd   [rsp+24], xmm0
    push    rcx
    sub     rsp, 8
    mov     edi, ebx
    mov     esi, r12d
    call    gr_uv
    movsd   [rsp+48], xmm0              # (this frame's [rsp+32], [rsp+40])
    movsd   [rsp+56], xmm1
    mov     edi, r13d
    mov     esi, r14d
    call    gr_uv
    add     rsp, 8
    pop     rcx
    subsd   xmm0, [rsp+32]
    mulsd   xmm0, [rsp+24]
    addsd   xmm0, [rsp+32]
    subsd   xmm1, [rsp+40]
    mulsd   xmm1, [rsp+24]
    addsd   xmm1, [rsp+40]
    movsd   [rcx], xmm0
    movsd   [rcx+8], xmm1
    mov     qword ptr [rcx+16], -1      # links (2 x i32)
    mov     dword ptr [rcx+24], 0
2:  mov     eax, [r15+MA_NE]
    cmp     eax, 4
    jae     9f
    mov     ecx, [rsp+16]
    mov     [r15+MA_E+rax*4], ecx
    inc     dword ptr [r15+MA_NE]
9:  add     rsp, 48
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# link(edi, esi = crossing ids) - joined both ways
link:
    mov     eax, edi
    shl     rax, 5
    add     rax, [rip+gr_x]
    cmp     dword ptr [rax+16], -1
    jne     1f
    mov     [rax+16], esi
    jmp     2f
1:  mov     [rax+20], esi
2:  mov     eax, esi
    shl     rax, 5
    add     rax, [rip+gr_x]
    cmp     dword ptr [rax+16], -1
    jne     3f
    mov     [rax+16], edi
    ret
3:  mov     [rax+20], edi
    ret

# trace(edi=start crossing, esi=1 closed) - a section along the links, each
#   point refined onto both surfaces; then points added where needed
trace:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    sub     rsp, 96
    mov     ebx, edi
    mov     r15d, esi
    call    sc_begin
    test    rax, rax
    jz      .Ltr_out
    mov     r14, rax
    mov     [r14+SS_CLOSED], r15d
    mov     r12d, -1                    # previous
    mov     r13d, ebx                   # current
    mov     dword ptr [rip+sp_cont], 1
.Ltr_step:
    mov     eax, r13d
    shl     rax, 5
    add     rax, [rip+gr_x]
    mov     dword ptr [rax+24], 1       # traced
    movsd   xmm0, [rax]
    movsd   xmm1, [rax+8]
    movsd   [rsp+80], xmm0
    movsd   [rsp+88], xmm1
    mov     rdi, [rip+sa_s]
    lea     rsi, [rsp]
    call    srf_eval
    lea     rsi, [rsp]
    movsd   xmm0, [rsp+80]
    movsd   xmm1, [rsp+88]
    call    sc_point
    mov     eax, r13d                   # the next: the link that is not back
    shl     rax, 5
    add     rax, [rip+gr_x]
    mov     ecx, [rax+16]
    cmp     ecx, r12d
    jne     1f
    mov     ecx, [rax+20]
1:  cmp     ecx, -1
    je      .Ltr_end
    cmp     ecx, ebx
    je      .Ltr_end                    # round to the start
    mov     edx, ecx
    shl     rdx, 5
    add     rdx, [rip+gr_x]
    cmp     dword ptr [rdx+24], 0
    jne     .Ltr_end
    mov     r12d, r13d
    mov     r13d, ecx
    jmp     .Ltr_step
.Ltr_end:
    mov     dword ptr [rip+sp_cont], 0
    mov     rdi, r14
    call    sc_end
    cmp     dword ptr [r14+SS_N], 2
    jb      .Ltr_out
    mov     rdi, r14
    call    densify
.Ltr_out:
    add     rsp, 96
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# densify(rdi=section, the last one) - points added between neighbours whose
#   middle (refined) is off their chord by more than the tolerance
densify:
    push    rbx
    push    r12
    push    r13
    push    r14
    sub     rsp, 72
    mov     rbx, rdi
    xor     r12d, r12d                  # piece k: points k, k + 1
.Ldn_piece:
    mov     eax, [rbx+SS_N]
    dec     eax
    cmp     r12d, eax
    jae     .Ldn_out
    cmp     dword ptr [rbx+SS_N], 65536
    jae     .Ldn_out
    mov     eax, [rbx+SS_FIRST]         # the middle of the pair as a new point
    add     eax, r12d
    call    sp_ptr
    mov     r13, rax
    call    sp_new
    test    rax, rax
    jz      .Ldn_out
    mov     r14, rax
    xor     ecx, ecx
1:  movsd   xmm0, [r13+rcx*8]
    addsd   xmm0, [r13+SP_SZ+rcx*8]
    mulsd   xmm0, [rip+ss_half]
    movsd   [r14+rcx*8], xmm0
    inc     ecx
    cmp     ecx, 7
    jb      1b
    mov     rdi, [rip+sa_s]             # (a, b in the record's order)
    mov     rsi, [rip+sb_s]
    cmp     dword ptr [rip+ss_swap], 0
    je      2f
    xchg    rdi, rsi
2:  mov     rdx, r14
    call    ss_refine
    dec     dword ptr [rip+ss_np]       # (the slot was only scratch)
    test    eax, eax
    jz      .Ldn_next
    xor     ecx, ecx                    # off the chord?
    xorpd   xmm2, xmm2
3:  movsd   xmm0, [r13+rcx*8]
    addsd   xmm0, [r13+SP_SZ+rcx*8]
    mulsd   xmm0, [rip+ss_half]
    subsd   xmm0, [r14+rcx*8]
    mulsd   xmm0, xmm0
    addsd   xmm2, xmm0
    inc     ecx
    cmp     ecx, 3
    jb      3b
    sqrtsd  xmm2, xmm2
    comisd  xmm2, [rip+ss_tol]
    jbe     .Ldn_next
    # insert after k: the records after it move up one
    movupd  xmm0, [r14]                 # (kept in registers: the slot is
    movupd  xmm1, [r14+16]              #  overwritten by the move)
    movupd  xmm2, [r14+32]
    movsd   xmm3, [r14+48]
    mov     eax, [rip+ss_np]            # (the last record moves to ss_np)
    call    sp_ptr
    mov     rdi, rax
    add     rdi, SP_SZ-8
    lea     rsi, [rdi-SP_SZ]
    lea     rcx, [r13+SP_SZ]            # down to point k + 1
4:  cmp     rsi, rcx
    jb      5f
    mov     rdx, [rsi]
    mov     [rdi], rdx
    sub     rsi, 8
    sub     rdi, 8
    jmp     4b
5:  movupd  [r13+SP_SZ], xmm0
    movupd  [r13+SP_SZ+16], xmm1
    movupd  [r13+SP_SZ+32], xmm2
    movsd   [r13+SP_SZ+48], xmm3
    inc     dword ptr [rip+ss_np]
    inc     dword ptr [rbx+SS_N]
    jmp     .Ldn_piece
.Ldn_next:
    inc     r12d
    jmp     .Ldn_piece
.Ldn_out:
    add     rsp, 72
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

.section .note.GNU-stack,"",@progbits
