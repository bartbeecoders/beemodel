# =============================================================================
#  BeeModel - B-rep topology: bodies, faces, loops, coedges, edges, vertices
#
#  A body is a run of faces; a face is part of one surface (nurbs.s), inside
#  its loops; a loop is a run of coedges; a coedge walks an edge one way and
#  carries the edge's curve in the face's (u, v) (its pcurve); an edge is part
#  of a 3D curve between two vertices. Records live in arenas (brep.inc) and
#  name each other by index; a rebuild starts them all again.
#
#  Orientation: a face's outside is Su x Sv, or its opposite when FC_SENSE
#  is 1. Seen from outside, a face's first (outer) loop turns counter-
#  clockwise and its holes clockwise, so in (u, v) the outer loop turns
#  counter-clockwise when the sense is 0 and clockwise when it is 1; every
#  edge of a closed body is walked once each way.
#
#  Builders give the surfaces, edges and loops; fc_pcurves makes the
#  pcurves (exact for lines and conics on planes and for the iso-parametric
#  edges of revolved surfaces, an adaptive polyline otherwise), fc_orient
#  turns the loops and sets the sense by asking which side of the face is
#  inside the solid. bd_volume and bd_area integrate over the faces with
#  Green's theorem in (u, v): Gauss-Legendre along each pcurve and across u.
# =============================================================================
.intel_syntax noprefix
.include "const.inc"
.include "brep.inc"

.globl br_reset
.globl bk_vx
.globl bk_ed
.globl bk_ce
.globl bk_lp
.globl bk_fc
.globl bk_bd
.globl p_vx
.globl p_ed
.globl p_ce
.globl p_lp
.globl p_fc
.globl p_bd
.globl p_cv
.globl p_sf
.globl i_cv
.globl i_sf
.globl n_vx
.globl n_ed
.globl fb_face
.globl fb_loop
.globl fb_ce
.globl bb_begin
.globl bb_end
.globl mk_line
.globl mk_conic
.globl mk_surf
.globl sf_invert
.globl sf_project
.globl sf_normal
.globl pc_make
.globl ce_uv
.globl fc_pcurves
.globl fc_orient
.globl fc_box
.globl fc_inside
.globl fc_sample
.globl bd_volume
.globl bd_area
.globl bd_check
.globl bd_flip
.globl bd_stats
.globl bs_v
.globl bs_e
.globl bs_f
.globl bs_l
.globl bs_bad
.globl lp_rev
.globl fs_pts
.globl fs_ls
.globl fs_ln
.globl fs_nl
.globl ed_mid
.globl ce_edge_dir

.equ MAXPC,     2048                    # points of a polyline pcurve
.equ FS_MAX,    16384                   # fc_sample: points of a face's loops
.equ FS_MAXL,   256

.section .rodata
.align 16
br_abs:         .quad 0x7fffffffffffffff, 0x7fffffffffffffff
br_negm:        .quad 0x8000000000000000, 0x8000000000000000
br_one:         .double 1.0
br_half:        .double 0.5
br_third:       .double 0.33333333333333333333
br_two:         .double 2.0
br_pi:          .double 3.14159265358979323846
br_2pi:         .double 6.28318530717958647692
br_hpi:         .double 1.57079632679489661923
br_lin:         .double 1.0e-10             # (relative) a pcurve is straight
br_pctol:       .double 2.0e-9              # (relative) polyline pcurves
br_pole:        .double 1.0e-11             # (relative) on a surface's pole
br_nwt:         .double 1.0e-15
br_eps:         .double 1.0e-6              # fc_orient's step off the face
br_in:          .double 1.0e-4              #  and into it
br_big:         .double 1.0e300
# Gauss-Legendre, 8 points on [-1, 1]
gl_x:           .double -0.9602898564975363, -0.7966664774136267
                .double -0.5255324099163290, -0.1834346424956498
                .double  0.1834346424956498,  0.5255324099163290
                .double  0.7966664774136267,  0.9602898564975363
gl_w:           .double  0.1012285362903763,  0.2223810344533745
                .double  0.3137066458778873,  0.3626837833783620
                .double  0.3626837833783620,  0.3137066458778873
                .double  0.2223810344533745,  0.1012285362903763

.section .bss
.align 8
bk_vx:          .skip ARENA_SZ
bk_ed:          .skip ARENA_SZ
bk_ce:          .skip ARENA_SZ
bk_lp:          .skip ARENA_SZ
bk_fc:          .skip ARENA_SZ
bk_bd:          .skip ARENA_SZ
br_ready:       .skip 4
fb_f:           .skip 4                 # the face being built
fb_l:           .skip 4                 # its loop being built
bb_first:       .skip 4
# bd_stats / bd_check
bs_v:           .skip 4
bs_e:           .skip 4
bs_f:           .skip 4
bs_l:           .skip 4
bs_bad:         .skip 4
# pc_make
.align 8
pc_t:           .skip 8*MAXPC
pc_uv:          .skip 16*MAXPC
pc_n:           .skip 4
pc_pole:        .skip MAXPC
# fc_sample: every loop of a face as (u, v) points
.align 8
fs_pts:         .skip 16*FS_MAX
fs_ls:          .skip 4*FS_MAXL
fs_ln:          .skip 4*FS_MAXL
fs_nl:          .skip 4
fs_np:          .skip 4

.text

# =============================================================================
#  Storage
# =============================================================================
# br_reset - the kernel starts empty (nurbs.s's arenas too)
br_reset:
    push    rbx
    call    bk_reset
    cmp     dword ptr [rip+br_ready], 0
    jne     2f
    lea     rbx, [rip+bk_vx]
1:  mov     rdi, rbx
    mov     rsi, 0x10000000
    call    arena_init
    add     rbx, ARENA_SZ
    lea     rax, [rip+bk_bd+ARENA_SZ]
    cmp     rbx, rax
    jb      1b
    mov     dword ptr [rip+br_ready], 1
2:  lea     rbx, [rip+bk_vx]
3:  mov     rdi, rbx
    call    arena_reset
    add     rbx, ARENA_SZ
    lea     rax, [rip+bk_bd+ARENA_SZ]
    cmp     rbx, rax
    jb      3b
    pop     rbx
    ret

# p_xx(edi=index) -> rax = the record (rcx changed)
p_vx:
    mov     rax, [rip+bk_vx+AR_BASE]
    mov     ecx, edi
    shl     rcx, 5
    add     rax, rcx
    ret
p_ed:
    mov     rax, [rip+bk_ed+AR_BASE]
    mov     ecx, edi
    shl     rcx, 6
    add     rax, rcx
    ret
p_ce:
    mov     rax, [rip+bk_ce+AR_BASE]
    mov     ecx, edi
    imul    rcx, rcx, CE_SZ
    add     rax, rcx
    ret
p_lp:
    mov     rax, [rip+bk_lp+AR_BASE]
    mov     ecx, edi
    shl     rcx, 4
    add     rax, rcx
    ret
p_fc:
    mov     rax, [rip+bk_fc+AR_BASE]
    mov     ecx, edi
    shl     rcx, 6
    add     rax, rcx
    ret
p_bd:
    mov     rax, [rip+bk_bd+AR_BASE]
    mov     ecx, edi
    shl     rcx, 6
    add     rax, rcx
    ret
p_cv:
    mov     rax, [rip+bk_cv+AR_BASE]
    mov     ecx, edi
    shl     rcx, 7
    add     rax, rcx
    ret
p_sf:
    mov     rax, [rip+bk_sf+AR_BASE]
    mov     ecx, edi
    imul    rcx, rcx, SF_SZ
    add     rax, rcx
    ret
# i_cv(rdi=curve) / i_sf(rdi=surface) -> eax = its index
i_cv:
    mov     rax, rdi
    sub     rax, [rip+bk_cv+AR_BASE]
    shr     rax, 7
    ret
i_sf:
    mov     rax, rdi
    sub     rax, [rip+bk_sf+AR_BASE]
    xor     edx, edx
    mov     ecx, SF_SZ
    div     rcx
    ret

# nw(rdi=arena, esi=size) -> rax = a cleared record, edx = its index (0 and
#   -1 when the arena is full)
nw:
    push    rbx
    push    r12
    sub     rsp, 8
    mov     rbx, rdi
    mov     r12d, esi
    call    arena_alloc
    test    rax, rax
    jz      8f
    mov     rdi, rax
    mov     ecx, r12d
    shr     ecx, 3
    mov     rsi, rax
    xor     eax, eax
    rep     stosq
    mov     rax, rsi
    sub     rax, [rbx+AR_BASE]
    xor     edx, edx
    div     r12
    mov     edx, eax
    mov     rax, rsi
    jmp     9f
8:  mov     edx, -1
9:  add     rsp, 8
    pop     r12
    pop     rbx
    ret

# next index of an arena: next_ix(rdi=arena, esi=size) -> eax
next_ix:
    mov     rax, [rdi+AR_USED]
    add     rax, 15
    and     rax, -16
    mov     ecx, esi
    xor     edx, edx
    div     rcx
    ret

# n_vx(rdi=point) -> eax = a new vertex there
n_vx:
    push    rbx
    mov     rbx, rdi
    lea     rdi, [rip+bk_vx]
    mov     esi, VX_SZ
    call    nw
    test    rax, rax
    jz      9f
    movupd  xmm0, [rbx]
    movupd  [rax], xmm0
    mov     rcx, [rbx+16]
    mov     [rax+16], rcx
9:  mov     eax, edx
    pop     rbx
    ret

# n_ed(edi=curve, esi=v0, edx=v1, xmm0=t0, xmm1=t1) -> eax = a new edge
n_ed:
    push    rbx
    push    r12
    push    r13
    sub     rsp, 16
    mov     ebx, edi
    mov     r12d, esi
    mov     r13d, edx
    movsd   [rsp], xmm0
    movsd   [rsp+8], xmm1
    lea     rdi, [rip+bk_ed]
    mov     esi, ED_SZ
    call    nw
    test    rax, rax
    jz      9f
    mov     [rax+ED_CURVE], ebx
    mov     [rax+ED_V0], r12d
    mov     [rax+ED_V1], r13d
    movsd   xmm0, [rsp]
    movsd   [rax+ED_T0], xmm0
    movsd   xmm0, [rsp+8]
    movsd   [rax+ED_T1], xmm0
    mov     dword ptr [rax+ED_AUX], -1
9:  mov     eax, edx
    add     rsp, 16
    pop     r13
    pop     r12
    pop     rbx
    ret

# fb_face(edi=surface, xmm0=u hint, xmm1=v hint (the middle of its range on
#   periodic surfaces)) -> eax = a new face, the one being built
fb_face:
    push    rbx
    sub     rsp, 16
    mov     ebx, edi
    movsd   [rsp], xmm0
    movsd   [rsp+8], xmm1
    lea     rdi, [rip+bk_fc]
    mov     esi, FC_SZ
    call    nw
    test    rax, rax
    jz      9f
    mov     [rax+FC_SURF], ebx
    movsd   xmm0, [rsp]
    movsd   [rax+FC_U0], xmm0
    movsd   [rax+FC_U1], xmm0
    movsd   xmm0, [rsp+8]
    movsd   [rax+FC_V0], xmm0
    movsd   [rax+FC_V1], xmm0
    mov     dword ptr [rax+FC_SRC], -1
    mov     [rip+fb_f], edx
    push    rax
    push    rdx
    lea     rdi, [rip+bk_lp]
    mov     esi, LP_SZ
    call    next_ix
    mov     ecx, eax
    pop     rdx
    pop     rax
    mov     [rax+FC_LOOP], ecx
9:  mov     eax, edx
    add     rsp, 16
    pop     rbx
    ret

# fb_loop -> eax = a new loop of the face being built
fb_loop:
    sub     rsp, 8
    lea     rdi, [rip+bk_lp]
    mov     esi, LP_SZ
    call    nw
    test    rax, rax
    jz      9f
    mov     [rip+fb_l], edx
    mov     ecx, [rip+fb_f]
    mov     [rax+LP_FACE], ecx
    push    rax
    push    rdx
    lea     rdi, [rip+bk_ce]
    mov     esi, CE_SZ
    call    next_ix
    mov     ecx, eax
    pop     rdx
    pop     rax
    mov     [rax+LP_FIRST], ecx
    mov     edi, [rip+fb_f]
    call    p_fc
    inc     dword ptr [rax+FC_NLOOP]
9:  mov     eax, edx
    add     rsp, 8
    ret

# fb_ce(edi=edge, esi=1: walked v1 -> v0) -> eax = a new coedge of the loop
fb_ce:
    push    rbx
    push    r12
    sub     rsp, 8
    mov     ebx, edi
    mov     r12d, esi
    lea     rdi, [rip+bk_ce]
    mov     esi, CE_SZ
    call    nw
    test    rax, rax
    jz      9f
    mov     [rax+CE_EDGE], ebx
    mov     [rax+CE_REV], r12d
    mov     dword ptr [rax+CE_PC], -1
    mov     ecx, [rip+fb_l]
    mov     [rax+CE_LOOP], ecx
    push    rdx
    sub     rsp, 8
    mov     edi, ecx
    call    p_lp
    inc     dword ptr [rax+LP_N]
    add     rsp, 8
    pop     rdx
9:  mov     eax, edx
    add     rsp, 8
    pop     r12
    pop     rbx
    ret

# bb_begin - a body starts with the next face; bb_end -> eax = the body
bb_begin:
    sub     rsp, 8
    lea     rdi, [rip+bk_fc]
    mov     esi, FC_SZ
    call    next_ix
    mov     [rip+bb_first], eax
    add     rsp, 8
    ret
bb_end:
    push    rbx
    lea     rdi, [rip+bk_fc]
    mov     esi, FC_SZ
    call    next_ix
    mov     ebx, eax
    lea     rdi, [rip+bk_bd]
    mov     esi, BD_SZ
    call    nw
    test    rax, rax
    jz      9f
    mov     ecx, [rip+bb_first]
    mov     [rax+BD_FIRST], ecx
    sub     ebx, ecx
    mov     [rax+BD_NF], ebx
9:  mov     eax, edx
    pop     rbx
    ret

# =============================================================================
#  Curves and surfaces
# =============================================================================
# mk_line(rdi=a, rsi=b) -> eax = a line from a (t = 0) towards b, xmm0 =
#   the length (b's parameter)
mk_line:
    push    rbx
    push    r12
    push    r13
    sub     rsp, 16
    mov     r12, rdi
    mov     r13, rsi
    call    kc_new
    mov     rbx, rax
    mov     dword ptr [rbx+CV_TYPE], CT_LINE
    mov     dword ptr [rbx+CV_DIM], 3
    movupd  xmm0, [r12]
    movupd  [rbx+CV_O], xmm0
    mov     rax, [r12+16]
    mov     [rbx+CV_O+16], rax
    lea     rdi, [rbx+CV_X]
    mov     rsi, r13
    mov     rdx, r12
    call    v3sub
    lea     rdi, [rbx+CV_X]
    call    v3norm
    movsd   [rsp], xmm0
    mov     rdi, rbx
    call    i_cv
    movsd   xmm0, [rsp]
    add     rsp, 16
    pop     r13
    pop     r12
    pop     rbx
    ret

# mk_conic(edi=type CT_CIRCLE / CT_ELLIPSE, rsi=O X Y (9 doubles), xmm0=R1,
#   xmm1=R2) -> eax = the curve
mk_conic:
    push    rbx
    push    r12
    push    r13
    sub     rsp, 16
    mov     r12d, edi
    mov     r13, rsi
    movsd   [rsp], xmm0
    movsd   [rsp+8], xmm1
    call    kc_new
    mov     rbx, rax
    mov     [rbx+CV_TYPE], r12d
    mov     dword ptr [rbx+CV_DIM], 3
    lea     rdi, [rbx+CV_O]
    mov     rsi, r13
    mov     ecx, 9
    rep     movsq
    movsd   xmm0, [rsp]
    movsd   [rbx+CV_R1], xmm0
    movsd   xmm0, [rsp+8]
    movsd   [rbx+CV_R2], xmm0
    mov     rdi, rbx
    call    i_cv
    add     rsp, 16
    pop     r13
    pop     r12
    pop     rbx
    ret

# mk_surf(edi=type, rsi=O X Y (9 doubles), xmm0=R1, xmm1=R2) -> eax = an
#   analytic surface (Z = X x Y; a cone's R2 is its half angle)
mk_surf:
    push    rbx
    push    r12
    push    r13
    sub     rsp, 16
    mov     r12d, edi
    mov     r13, rsi
    movsd   [rsp], xmm0
    movsd   [rsp+8], xmm1
    call    ks_new
    mov     rbx, rax
    mov     [rbx+SF_TYPE], r12d
    lea     rdi, [rbx+SF_O]
    mov     rsi, r13
    mov     ecx, 9
    rep     movsq
    lea     rdi, [rbx+SF_Z]
    lea     rsi, [rbx+SF_X]
    lea     rdx, [rbx+SF_Y]
    call    v3cross
    movsd   xmm0, [rsp]
    movsd   [rbx+SF_R1], xmm0
    movsd   xmm0, [rsp+8]
    movsd   [rbx+SF_R2], xmm0
    call    dsincos
    movsd   [rbx+SF_SA], xmm0
    movsd   [rbx+SF_CA], xmm1
    mov     rdi, rbx
    call    i_sf
    add     rsp, 16
    pop     r13
    pop     r12
    pop     rbx
    ret

# wrap(xmm0=angle, xmm1=centre) -> xmm0 = the angle within pi of the centre
wrap:
    movsd   xmm2, xmm0
    subsd   xmm2, xmm1
1:  comisd  xmm2, [rip+br_pi]
    jbe     2f
    subsd   xmm0, [rip+br_2pi]
    subsd   xmm2, [rip+br_2pi]
    jmp     1b
2:  movsd   xmm3, [rip+br_pi]
    xorpd   xmm3, [rip+br_negm]
3:  comisd  xmm2, xmm3
    jae     4f
    addsd   xmm0, [rip+br_2pi]
    addsd   xmm2, [rip+br_2pi]
    jmp     3b
4:  ret

# sf_normal(rdi=surface, xmm0=u, xmm1=v, rsi=out: P, N (6 doubles)) - the
#   point and the unit Su x Sv
sf_normal:
    push    rbx
    sub     rsp, 80
    mov     rbx, rsi
    lea     rsi, [rsp]
    call    srf_eval
    lea     rdi, [rbx+24]
    lea     rsi, [rsp+24]
    lea     rdx, [rsp+48]
    call    v3cross
    lea     rdi, [rbx+24]
    call    v3norm
    movupd  xmm0, [rsp]
    movupd  [rbx], xmm0
    mov     rax, [rsp+16]
    mov     [rbx+16], rax
    add     rsp, 80
    pop     rbx
    ret

# sf_invert(rdi=surface, rsi=point, xmm0=u hint, xmm1=v hint) -> xmm0 = u,
#   xmm1 = v of the point on the surface nearest it, eax = 1 at a pole (u
#   has no meaning there: the hint is given back)
.equ SI_D,    0                         # P - O
.equ SI_X,    24                        # its x, y, z in the frame
.equ SI_Y,    32
.equ SI_Z,    40
.equ SI_UH,   48
.equ SI_VH,   56
.equ SI_U,    64
sf_invert:
    push    rbx
    push    r12
    sub     rsp, 88
    mov     rbx, rdi
    mov     r12, rsi
    movsd   [rsp+SI_UH], xmm0
    movsd   [rsp+SI_VH], xmm1
    cmp     dword ptr [rbx+SF_TYPE], ST_NURBS
    je      .Lsi_nurbs
    lea     rdi, [rsp+SI_D]
    mov     rsi, r12
    lea     rdx, [rbx+SF_O]
    call    v3sub
    lea     rdi, [rsp+SI_D]
    lea     rsi, [rbx+SF_X]
    call    v3dot
    movsd   [rsp+SI_X], xmm0
    lea     rdi, [rsp+SI_D]
    lea     rsi, [rbx+SF_Y]
    call    v3dot
    movsd   [rsp+SI_Y], xmm0
    lea     rdi, [rsp+SI_D]
    lea     rsi, [rbx+SF_Z]
    call    v3dot
    movsd   [rsp+SI_Z], xmm0
    mov     eax, [rbx+SF_TYPE]
    cmp     eax, ST_PLANE
    jne     1f
    movsd   xmm0, [rsp+SI_X]
    movsd   xmm1, [rsp+SI_Y]
    xor     eax, eax
    jmp     .Lsi_out
1:  movsd   xmm0, [rsp+SI_Y]            # u around the axis
    movsd   xmm1, [rsp+SI_X]
    call    datan2
    movsd   xmm1, [rsp+SI_UH]
    call    wrap
    movsd   [rsp+SI_U], xmm0
    movsd   xmm2, [rsp+SI_X]            # rho
    mulsd   xmm2, xmm2
    movsd   xmm3, [rsp+SI_Y]
    mulsd   xmm3, xmm3
    addsd   xmm2, xmm3
    sqrtsd  xmm2, xmm2
    movsd   [rsp+SI_D], xmm2
    mov     eax, [rbx+SF_TYPE]
    cmp     eax, ST_CYL
    je      .Lsi_cyl
    cmp     eax, ST_CONE
    je      .Lsi_cone
    cmp     eax, ST_SPHERE
    je      .Lsi_sphere
    movsd   xmm1, [rsp+SI_D]            # torus: v = atan2(z, rho - R)
    subsd   xmm1, [rbx+SF_R1]
    movsd   xmm0, [rsp+SI_Z]
    call    datan2
    movsd   xmm1, [rsp+SI_VH]
    call    wrap
    movsd   xmm1, xmm0
    jmp     .Lsi_angle
.Lsi_cyl:
    movsd   xmm1, [rsp+SI_Z]
    jmp     .Lsi_angle
.Lsi_cone:
    movsd   xmm1, [rsp+SI_Z]            # v along the generatrix: the
    divsd   xmm1, [rbx+SF_CA]           #  nearest point on the line
    movsd   xmm0, [rsp+SI_D]            #  v = (rho - R) sin a + z cos a
    subsd   xmm0, [rbx+SF_R1]
    mulsd   xmm0, [rbx+SF_SA]
    movsd   xmm1, [rsp+SI_Z]
    mulsd   xmm1, [rbx+SF_CA]
    addsd   xmm1, xmm0
    jmp     .Lsi_angle
.Lsi_sphere:
    movsd   xmm0, [rsp+SI_Z]
    movsd   xmm1, [rsp+SI_D]
    call    datan2
    movsd   xmm1, xmm0
.Lsi_angle:
    movsd   xmm0, [rsp+SI_U]
    xor     eax, eax
    cmp     dword ptr [rbx+SF_TYPE], ST_CYL  # (a cylinder has no pole)
    je      .Lsi_out
    movsd   xmm2, [rbx+SF_R1]           # pole: rho tiny
    andpd   xmm2, [rip+br_abs]
    addsd   xmm2, [rbx+SF_R2]
    movsd   xmm3, [rsp+SI_Z]
    andpd   xmm3, [rip+br_abs]
    addsd   xmm2, xmm3
    mulsd   xmm2, [rip+br_pole]
    comisd  xmm2, [rsp+SI_D]
    jbe     .Lsi_out
    movsd   xmm0, [rsp+SI_UH]
    mov     eax, 1
    jmp     .Lsi_out
.Lsi_nurbs:
    call    nurbs_seed                  # the nearest of a grid, then Newton
    mov     rdi, rbx
    mov     rsi, r12
    call    sf_project
    xor     eax, eax
.Lsi_out:
    add     rsp, 88
    pop     r12
    pop     rbx
    ret

# nurbs_seed(rbx=surface, r12=point) -> xmm0, xmm1 = the nearest of 16 x 16
#   samples over the knot ranges
nurbs_seed:
    push    r13
    push    r14
    push    r15
    sub     rsp, 128
    movsd   xmm0, [rip+br_big]
    movsd   [rsp+72], xmm0              # best distance
    xor     r13d, r13d
1:  cmp     r13d, 16
    ja      5f
    xor     r14d, r14d
2:  cmp     r14d, 16
    ja      4f
    mov     edi, r13d
    lea     rsi, [rbx+SF_KU]
    mov     edx, [rbx+SF_DU]
    mov     ecx, [rbx+SF_NU]
    call    knot_at
    movsd   [rsp+80], xmm0
    mov     edi, r14d
    lea     rsi, [rbx+SF_KV]
    mov     edx, [rbx+SF_DV]
    mov     ecx, [rbx+SF_NV]
    call    knot_at
    movsd   [rsp+88], xmm0
    movsd   xmm1, xmm0
    movsd   xmm0, [rsp+80]
    mov     rdi, rbx
    lea     rsi, [rsp]
    call    srf_eval
    lea     rdi, [rsp]
    mov     rsi, r12
    call    v3dist
    comisd  xmm0, [rsp+72]
    jae     3f
    movsd   [rsp+72], xmm0
    movsd   xmm0, [rsp+80]
    movsd   [rsp+96], xmm0
    movsd   xmm0, [rsp+88]
    movsd   [rsp+104], xmm0
3:  inc     r14d
    jmp     2b
4:  inc     r13d
    jmp     1b
5:  movsd   xmm0, [rsp+96]
    movsd   xmm1, [rsp+104]
    add     rsp, 128
    pop     r15
    pop     r14
    pop     r13
    ret
# knot_at(edi=i of 16, rsi=&knots, edx=degree, ecx=points) -> xmm0
knot_at:
    mov     rsi, [rsi]
    movsd   xmm0, [rsi+rdx*8]
    movsd   xmm1, [rsi+rcx*8]
    subsd   xmm1, xmm0
    cvtsi2sd xmm2, edi
    mulsd   xmm1, xmm2
    mov     eax, 16
    cvtsi2sd xmm2, eax
    divsd   xmm1, xmm2
    addsd   xmm0, xmm1
    ret

# sf_project(rdi=surface, rsi=point, xmm0=u, xmm1=v start) -> xmm0, xmm1 =
#   the nearest (u, v) by Gauss-Newton (NURBS: kept in the knot ranges)
sf_project:
    push    rbx
    push    r12
    push    r13
    sub     rsp, 160
    mov     rbx, rdi
    mov     r12, rsi
    movsd   [rsp+120], xmm0
    movsd   [rsp+128], xmm1
    xor     r13d, r13d
.Lsp_it:
    cmp     r13d, 40
    jae     .Lsp_out
    movsd   xmm0, [rsp+120]
    movsd   xmm1, [rsp+128]
    mov     rdi, rbx
    lea     rsi, [rsp]
    call    srf_eval
    lea     rdi, [rsp+72]               # r = P - S
    mov     rsi, r12
    lea     rdx, [rsp]
    call    v3sub
    lea     rdi, [rsp+24]
    lea     rsi, [rsp+24]
    call    v3dot
    movsd   [rsp+96], xmm0              # a
    lea     rdi, [rsp+24]
    lea     rsi, [rsp+48]
    call    v3dot
    movsd   [rsp+104], xmm0             # b
    lea     rdi, [rsp+48]
    lea     rsi, [rsp+48]
    call    v3dot
    movsd   [rsp+112], xmm0             # c
    lea     rdi, [rsp+24]
    lea     rsi, [rsp+72]
    call    v3dot
    movsd   xmm4, xmm0                  # e
    lea     rdi, [rsp+48]
    lea     rsi, [rsp+72]
    call    v3dot
    movsd   xmm5, xmm0                  # f
    movsd   xmm6, [rsp+96]              # det = a c - b b
    mulsd   xmm6, [rsp+112]
    movsd   xmm7, [rsp+104]
    mulsd   xmm7, xmm7
    subsd   xmm6, xmm7
    movsd   xmm7, xmm6
    andpd   xmm7, [rip+br_abs]
    comisd  xmm7, [rip+br_nwt]
    jbe     .Lsp_out
    movsd   xmm0, [rsp+112]             # du = (c e - b f) / det
    mulsd   xmm0, xmm4
    movsd   xmm1, [rsp+104]
    mulsd   xmm1, xmm5
    subsd   xmm0, xmm1
    divsd   xmm0, xmm6
    movsd   xmm1, [rsp+96]              # dv = (a f - b e) / det
    mulsd   xmm1, xmm5
    movsd   xmm2, [rsp+104]
    mulsd   xmm2, xmm4
    subsd   xmm1, xmm2
    divsd   xmm1, xmm6
    movsd   xmm2, [rsp+120]
    addsd   xmm2, xmm0
    movsd   xmm3, [rsp+128]
    addsd   xmm3, xmm1
    cmp     dword ptr [rbx+SF_TYPE], ST_NURBS
    jne     1f
    mov     rax, [rbx+SF_KU]
    mov     ecx, [rbx+SF_DU]
    maxsd   xmm2, [rax+rcx*8]
    mov     ecx, [rbx+SF_NU]
    minsd   xmm2, [rax+rcx*8]
    mov     rax, [rbx+SF_KV]
    mov     ecx, [rbx+SF_DV]
    maxsd   xmm3, [rax+rcx*8]
    mov     ecx, [rbx+SF_NV]
    minsd   xmm3, [rax+rcx*8]
1:  movsd   [rsp+120], xmm2
    movsd   [rsp+128], xmm3
    andpd   xmm0, [rip+br_abs]
    andpd   xmm1, [rip+br_abs]
    addsd   xmm0, xmm1
    comisd  xmm0, [rip+br_nwt]
    jbe     .Lsp_out
    inc     r13d
    jmp     .Lsp_it
.Lsp_out:
    movsd   xmm0, [rsp+120]
    movsd   xmm1, [rsp+128]
    add     rsp, 160
    pop     r13
    pop     r12
    pop     rbx
    ret

# =============================================================================
#  Pcurves
# =============================================================================
# ed_eval(edi=edge, xmm0=t, rsi=out[9]) - its curve there
ed_eval:
    push    rsi
    sub     rsp, 16
    movsd   [rsp], xmm0
    call    p_ed
    mov     edi, [rax+ED_CURVE]
    call    p_cv
    mov     rdi, rax
    movsd   xmm0, [rsp]
    mov     rsi, [rsp+16]
    call    crv_eval
    add     rsp, 16
    pop     rsi
    ret

# ed_mid(edi=edge, rsi=out[3]) - its middle point
ed_mid:
    push    rbx
    sub     rsp, 80
    mov     rbx, rsi
    call    p_ed
    movsd   xmm0, [rax+ED_T0]
    addsd   xmm0, [rax+ED_T1]
    mulsd   xmm0, [rip+br_half]
    mov     edi, [rax+ED_CURVE]
    call    p_cv
    mov     rdi, rax
    lea     rsi, [rsp]
    call    crv_eval
    movupd  xmm0, [rsp]
    movupd  [rbx], xmm0
    mov     rax, [rsp+16]
    mov     [rbx+16], rax
    add     rsp, 80
    pop     rbx
    ret

# ce_edge_dir(edi=coedge) -> xmm0 = t at its start, xmm1 = t at its end
ce_edge_dir:
    push    rbx
    call    p_ce
    mov     rbx, rax
    mov     edi, [rbx+CE_EDGE]
    call    p_ed
    movsd   xmm0, [rax+ED_T0]
    movsd   xmm1, [rax+ED_T1]
    cmp     dword ptr [rbx+CE_REV], 0
    je      1f
    movsd   xmm2, xmm0
    movsd   xmm0, xmm1
    movsd   xmm1, xmm2
1:  pop     rbx
    ret

# ce_uv(edi=coedge, xmm0=s in 0 .. 1 along it, rsi=out[4]) - (u, v) and
#   (du, dv) / d(pcurve parameter) of its pcurve
ce_uv:
    push    rbx
    push    r12
    sub     rsp, 88
    mov     r12, rsi
    movsd   [rsp+72], xmm0
    call    p_ce
    mov     rbx, rax
    movsd   xmm0, [rbx+CE_P1]           # p = P0 + s (P1 - P0)
    subsd   xmm0, [rbx+CE_P0]
    mulsd   xmm0, [rsp+72]
    addsd   xmm0, [rbx+CE_P0]
    mov     edi, [rbx+CE_PC]
    call    p_cv
    mov     rdi, rax
    lea     rsi, [rsp]
    call    crv_eval
    movsd   xmm0, [rsp]
    movsd   [r12], xmm0
    movsd   xmm0, [rsp+8]
    movsd   [r12+8], xmm0
    movsd   xmm0, [rsp+24]
    movsd   [r12+16], xmm0
    movsd   xmm0, [rsp+32]
    movsd   [r12+24], xmm0
    add     rsp, 88
    pop     r12
    pop     rbx
    ret

# pc_make(edi=coedge, esi=face) - the coedge's pcurve on the face's surface
#   (degenerate edges are left to fc_pcurves)
.equ PM_S,    0                         # the surface
.equ PM_E,    8                         # the edge
.equ PM_C,    16                        # the coedge
.equ PM_F,    24                        # the face
.equ PM_TS,   32                        # t at the start and the end
.equ PM_TE,   40
.equ PM_UH,   48                        # hints
.equ PM_VH,   56
.equ PM_EV,   64                        # crv_eval out (9 doubles)
.equ PM_A,    136                       # scratch
.equ PM_SC,   200                       # uv scale (for tolerances)
.equ PM_K,    208
pc_make:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    push    rbp
    sub     rsp, 232
    mov     r12d, edi
    mov     r13d, esi
    call    p_ce
    mov     [rsp+PM_C], rax
    mov     edi, [rax+CE_EDGE]
    call    p_ed
    mov     [rsp+PM_E], rax
    test    dword ptr [rax+ED_FLAGS], EF_DEGEN
    jnz     .Lpm_out
    mov     edi, r13d
    call    p_fc
    mov     [rsp+PM_F], rax
    movsd   xmm0, [rax+FC_U0]
    addsd   xmm0, [rax+FC_U1]
    mulsd   xmm0, [rip+br_half]
    movsd   [rsp+PM_UH], xmm0
    movsd   xmm0, [rax+FC_V0]
    addsd   xmm0, [rax+FC_V1]
    mulsd   xmm0, [rip+br_half]
    movsd   [rsp+PM_VH], xmm0
    mov     edi, [rax+FC_SURF]
    call    p_sf
    mov     [rsp+PM_S], rax
    mov     edi, r12d
    call    ce_edge_dir
    movsd   [rsp+PM_TS], xmm0
    movsd   [rsp+PM_TE], xmm1
    mov     rax, [rsp+PM_S]
    cmp     dword ptr [rax+SF_TYPE], ST_PLANE
    je      .Lpm_plane
    # nine samples: a straight line in (u, v)?
    mov     dword ptr [rip+pc_n], 0
    xor     ebx, ebx
1:  cmp     ebx, 8
    ja      2f
    cvtsi2sd xmm0, ebx
    mov     eax, 8
    cvtsi2sd xmm1, eax
    divsd   xmm0, xmm1
    movsd   xmm1, [rsp+PM_TE]
    subsd   xmm1, [rsp+PM_TS]
    mulsd   xmm0, xmm1
    addsd   xmm0, [rsp+PM_TS]
    call    pc_push
    inc     ebx
    jmp     1b
2:  call    pc_fixpoles
    call    pc_straight
    test    eax, eax
    jz      .Lpm_poly
    # a line from the first (u, v) to the last
    call    kc_new
    mov     rbx, rax
    mov     dword ptr [rbx+CV_TYPE], CT_LINE
    mov     dword ptr [rbx+CV_DIM], 2
    lea     rsi, [rip+pc_uv]
    mov     eax, [rip+pc_n]
    dec     eax
    shl     eax, 4
    movsd   xmm0, [rsi]
    movsd   [rbx+CV_O], xmm0
    movsd   xmm1, [rsi+8]
    movsd   [rbx+CV_O+8], xmm1
    movsd   xmm2, [rsi+rax]
    subsd   xmm2, xmm0
    movsd   xmm3, [rsi+rax+8]
    subsd   xmm3, xmm1
    movsd   [rbx+CV_X], xmm2
    movsd   [rbx+CV_X+8], xmm3
    lea     rdi, [rbx+CV_X]
    call    v3norm
    mov     rax, [rsp+PM_C]
    xorpd   xmm1, xmm1
    movsd   [rax+CE_P0], xmm1
    movsd   [rax+CE_P1], xmm0
    jmp     .Lpm_set
.Lpm_poly:
    call    pc_refine
    call    pc_polyline
    test    rax, rax
    jz      .Lpm_out
    mov     rbx, rax
    mov     rax, [rsp+PM_C]
    movsd   xmm0, [rsp+PM_TS]
    movsd   [rax+CE_P0], xmm0
    movsd   xmm0, [rsp+PM_TE]
    movsd   [rax+CE_P1], xmm0
    jmp     .Lpm_set
.Lpm_plane:
    # the curve's affine image in the plane's coordinates, the same parameter
    mov     rax, [rsp+PM_E]
    mov     edi, [rax+ED_CURVE]
    call    p_cv
    mov     r14, rax
    call    kc_new
    mov     rbx, rax
    mov     rdi, rbx
    mov     rsi, r14
    mov     ecx, CV_SZ/8
    rep     movsq
    mov     dword ptr [rbx+CV_DIM], 2
    mov     r15, [rsp+PM_S]
    lea     rdi, [rbx+CV_O]             # O: a point
    mov     esi, 1
    call    plane_map
    lea     rdi, [rbx+CV_X]             # X, Y: directions
    xor     esi, esi
    call    plane_map
    lea     rdi, [rbx+CV_Y]
    xor     esi, esi
    call    plane_map
    cmp     dword ptr [r14+CV_TYPE], CT_NURBS
    jne     4f
    mov     edi, [r14+CV_N]             # homogeneous points: (w u, w v, 0, w)
    shl     edi, 5
    call    bk_data
    mov     [rbx+CV_CP], rax
    mov     rbp, rax
    xor     r13d, r13d
3:  cmp     r13d, [r14+CV_N]
    jae     4f
    mov     eax, r13d
    shl     eax, 5
    mov     rsi, [r14+CV_CP]
    movsd   xmm7, [rsi+rax+24]
    movsd   xmm0, [rsi+rax]
    divsd   xmm0, xmm7
    movsd   [rsp+PM_A], xmm0
    movsd   xmm0, [rsi+rax+8]
    divsd   xmm0, xmm7
    movsd   [rsp+PM_A+8], xmm0
    movsd   xmm0, [rsi+rax+16]
    divsd   xmm0, xmm7
    movsd   [rsp+PM_A+16], xmm0
    movsd   [rsp+PM_A+32], xmm7
    lea     rdi, [rsp+PM_A]
    mov     esi, 1
    call    plane_map
    mov     eax, r13d
    shl     eax, 5
    movsd   xmm7, [rsp+PM_A+32]
    movsd   xmm0, [rsp+PM_A]
    mulsd   xmm0, xmm7
    movsd   [rbp+rax], xmm0
    movsd   xmm0, [rsp+PM_A+8]
    mulsd   xmm0, xmm7
    movsd   [rbp+rax+8], xmm0
    xorpd   xmm0, xmm0
    movsd   [rbp+rax+16], xmm0
    movsd   [rbp+rax+24], xmm7
    inc     r13d
    jmp     3b
4:  mov     rax, [rsp+PM_C]
    movsd   xmm0, [rsp+PM_TS]
    movsd   [rax+CE_P0], xmm0
    movsd   xmm0, [rsp+PM_TE]
    movsd   [rax+CE_P1], xmm0
.Lpm_set:
    mov     rdi, rbx
    call    i_cv
    mov     rcx, [rsp+PM_C]
    mov     [rcx+CE_PC], eax
.Lpm_out:
    add     rsp, 232
    pop     rbp
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# plane_map(rdi=vector (in place), esi=1 for a point; r15=plane) - its plane
#   coordinates (u, v, 0)
plane_map:
    push    rbx
    sub     rsp, 32
    mov     rbx, rdi
    movupd  xmm0, [rbx]
    movupd  [rsp], xmm0
    mov     rax, [rbx+16]
    mov     [rsp+16], rax
    test    esi, esi
    jz      1f
    lea     rdi, [rsp]
    lea     rsi, [rsp]
    lea     rdx, [r15+SF_O]
    call    v3sub
1:  lea     rdi, [rsp]
    lea     rsi, [r15+SF_X]
    call    v3dot
    movsd   [rbx], xmm0
    lea     rdi, [rsp]
    lea     rsi, [r15+SF_Y]
    call    v3dot
    movsd   [rbx+8], xmm0
    xorpd   xmm0, xmm0
    movsd   [rbx+16], xmm0
    add     rsp, 32
    pop     rbx
    ret

# pc_push(xmm0=t; pc_make's frame) - the edge point at t, inverted, appended
pc_push:
    push    rbx
    sub     rsp, 16
    lea     rbx, [rsp+32]               # pc_make's frame
    mov     eax, [rip+pc_n]
    cmp     eax, MAXPC
    jae     9f
    lea     rcx, [rip+pc_t]
    movsd   [rcx+rax*8], xmm0
    mov     rax, [rbx+PM_E]
    mov     edi, [rax+ED_CURVE]
    call    p_cv
    mov     rdi, rax
    mov     eax, [rip+pc_n]
    lea     rcx, [rip+pc_t]
    movsd   xmm0, [rcx+rax*8]
    lea     rsi, [rbx+PM_EV]
    call    crv_eval
    mov     rdi, [rbx+PM_S]
    lea     rsi, [rbx+PM_EV]
    movsd   xmm0, [rbx+PM_UH]
    movsd   xmm1, [rbx+PM_VH]
    mov     ecx, [rip+pc_n]             # continuing: hints from the last
    test    ecx, ecx
    jz      1f
    dec     ecx
    shl     ecx, 4
    lea     rdx, [rip+pc_uv]
    movsd   xmm0, [rdx+rcx]
    movsd   xmm1, [rdx+rcx+8]
1:  call    sf_invert
    mov     ecx, [rip+pc_n]
    lea     rdx, [rip+pc_pole]
    mov     [rdx+rcx], al
    shl     ecx, 4
    lea     rdx, [rip+pc_uv]
    movsd   [rdx+rcx], xmm0
    movsd   [rdx+rcx+8], xmm1
    inc     dword ptr [rip+pc_n]
9:  add     rsp, 16
    pop     rbx
    ret

# pc_fixpoles - samples at a pole take u from their neighbour
pc_fixpoles:
    mov     ecx, [rip+pc_n]
    lea     rdx, [rip+pc_pole]
    lea     r8, [rip+pc_uv]
    xor     eax, eax
1:  cmp     eax, ecx
    jae     9f
    cmp     byte ptr [rdx+rax], 0
    je      3f
    mov     r9d, eax                    # the next (or the previous) one
    inc     r9d
    cmp     r9d, ecx
    jb      2f
    lea     r9d, [rax-1]
    test    r9d, r9d
    js      3f
2:  shl     r9d, 4
    movsd   xmm0, [r8+r9]
    mov     r10d, eax
    shl     r10d, 4
    movsd   [r8+r10], xmm0
3:  inc     eax
    jmp     1b
9:  ret

# pc_straight -> eax = 1 if the samples lie on the line from the first to
#   the last (in (u, v), relative to the chord)
pc_straight:
    lea     rsi, [rip+pc_uv]
    mov     ecx, [rip+pc_n]
    dec     ecx
    shl     ecx, 4
    movsd   xmm0, [rsi+rcx]             # chord d
    subsd   xmm0, [rsi]
    movsd   xmm1, [rsi+rcx+8]
    subsd   xmm1, [rsi+8]
    movsd   xmm2, xmm0
    mulsd   xmm2, xmm2
    movsd   xmm3, xmm1
    mulsd   xmm3, xmm3
    addsd   xmm2, xmm3
    sqrtsd  xmm2, xmm2                  # |d|
    xorpd   xmm3, xmm3
    comisd  xmm2, xmm3
    je      8f
    movsd   xmm7, xmm2                  # tolerance: |d| 1e-10 + 1e-12
    mulsd   xmm7, [rip+br_lin]
    addsd   xmm7, [rip+br_nwt]
    mov     eax, 1
1:  cmp     eax, [rip+pc_n]
    jae     9f
    mov     edx, eax
    shl     edx, 4
    movsd   xmm4, [rsi+rdx]             # cross(d, p - p0) / |d|
    subsd   xmm4, [rsi]
    movsd   xmm5, [rsi+rdx+8]
    subsd   xmm5, [rsi+8]
    mulsd   xmm4, xmm1
    mulsd   xmm5, xmm0
    subsd   xmm4, xmm5
    divsd   xmm4, xmm2
    andpd   xmm4, [rip+br_abs]
    comisd  xmm4, xmm7
    ja      8f
    inc     eax
    jmp     1b
8:  xor     eax, eax
    ret
9:  mov     eax, 1
    ret

# pc_refine(pc_make's frame) - samples added until every piece's middle lies
#   on its chord (in (u, v), relative to the face's extent)
pc_refine:
    push    rbx
    push    r12
    push    r13
    sub     rsp, 48
    lea     r13, [rsp+80]               # pc_make's frame
    # the tolerance: the samples' (u, v) extent
    lea     rsi, [rip+pc_uv]
    movsd   xmm0, [rsi]                 # min / max u, v
    movsd   xmm1, xmm0
    movsd   xmm2, [rsi+8]
    movsd   xmm3, xmm2
    xor     eax, eax
1:  cmp     eax, [rip+pc_n]
    jae     2f
    mov     edx, eax
    shl     edx, 4
    minsd   xmm0, [rsi+rdx]
    maxsd   xmm1, [rsi+rdx]
    minsd   xmm2, [rsi+rdx+8]
    maxsd   xmm3, [rsi+rdx+8]
    inc     eax
    jmp     1b
2:  subsd   xmm1, xmm0
    subsd   xmm3, xmm2
    addsd   xmm1, xmm3
    mulsd   xmm1, [rip+br_pctol]
    addsd   xmm1, [rip+br_nwt]
    movsd   [rsp+40], xmm1
    xor     ebx, ebx                    # piece i: samples i, i + 1
.Lpr_piece:
    mov     eax, [rip+pc_n]
    dec     eax
    cmp     ebx, eax
    jae     .Lpr_out
    cmp     dword ptr [rip+pc_n], MAXPC-1
    jae     .Lpr_out
    lea     rcx, [rip+pc_t]             # the middle's parameter
    movsd   xmm0, [rcx+rbx*8]
    addsd   xmm0, [rcx+rbx*8+8]
    mulsd   xmm0, [rip+br_half]
    movsd   [rsp], xmm0
    call    pc_push_tmp                 # its (u, v) at the end of the list
    mov     eax, [rip+pc_n]
    shl     eax, 4
    lea     rsi, [rip+pc_uv]
    mov     edx, ebx
    shl     edx, 4
    movsd   xmm0, [rsi+rdx]             # chord middle
    addsd   xmm0, [rsi+rdx+16]
    mulsd   xmm0, [rip+br_half]
    movsd   xmm1, [rsi+rdx+8]
    addsd   xmm1, [rsi+rdx+24]
    mulsd   xmm1, [rip+br_half]
    subsd   xmm0, [rsi+rax]
    subsd   xmm1, [rsi+rax+8]
    andpd   xmm0, [rip+br_abs]
    andpd   xmm1, [rip+br_abs]
    addsd   xmm0, xmm1
    comisd  xmm0, [rsp+40]
    jbe     .Lpr_next
    # insert it after sample i (move the rest up one)
    mov     ecx, [rip+pc_n]
    lea     r8, [rip+pc_t]
    lea     r9, [rip+pc_uv]
    lea     r10, [rip+pc_pole]
    shl     eax, 0
    mov     eax, ecx                    # the temporary slot's values
    shl     eax, 4
    movsd   xmm2, [r9+rax]
    movsd   xmm3, [r9+rax+8]
    mov     eax, ecx
    mov     r11b, [r10+rax]
3:  cmp     ecx, ebx
    jbe     4f
    cmp     ecx, ebx
    je      4f
    lea     eax, [rcx-1]
    cmp     eax, ebx
    je      4f
    movsd   xmm4, [r8+rax*8]
    movsd   [r8+rcx*8], xmm4
    mov     edx, eax
    shl     edx, 4
    movsd   xmm4, [r9+rdx]
    movsd   xmm5, [r9+rdx+8]
    mov     edx, ecx
    shl     edx, 4
    movsd   [r9+rdx], xmm4
    movsd   [r9+rdx+8], xmm5
    mov     dl, [r10+rax]
    mov     [r10+rcx], dl
    dec     ecx
    jmp     3b
4:  lea     ecx, [rbx+1]
    movsd   xmm4, [rsp]
    movsd   [r8+rcx*8], xmm4
    mov     edx, ecx
    shl     edx, 4
    movsd   [r9+rdx], xmm2
    movsd   [r9+rdx+8], xmm3
    mov     [r10+rcx], r11b
    inc     dword ptr [rip+pc_n]
    jmp     .Lpr_piece                  # (the same piece, now shorter)
.Lpr_next:
    inc     ebx
    jmp     .Lpr_piece
.Lpr_out:
    call    pc_fixpoles
    add     rsp, 48
    pop     r13
    pop     r12
    pop     rbx
    ret
# pc_push_tmp(xmm0=t) - like pc_push into slot pc_n without counting it
#   (hinted by sample ebx; pc_refine's caller frame is pc_make's)
pc_push_tmp:
    push    rbx
    push    r12
    sub     rsp, 8
    lea     r12, [rsp+24+8+48+24+8]     # pc_make's frame (pc_refine below it)
    mov     eax, [rip+pc_n]
    lea     rcx, [rip+pc_t]
    movsd   [rcx+rax*8], xmm0
    movsd   [rsp], xmm0
    mov     rax, [r12+PM_E]
    mov     edi, [rax+ED_CURVE]
    call    p_cv
    mov     rdi, rax
    movsd   xmm0, [rsp]
    lea     rsi, [r12+PM_EV]
    call    crv_eval
    mov     rdi, [r12+PM_S]
    lea     rsi, [r12+PM_EV]
    mov     ecx, ebx
    shl     ecx, 4
    lea     rdx, [rip+pc_uv]
    movsd   xmm0, [rdx+rcx]
    movsd   xmm1, [rdx+rcx+8]
    call    sf_invert
    mov     ecx, [rip+pc_n]
    lea     rdx, [rip+pc_pole]
    mov     [rdx+rcx], al
    shl     ecx, 4
    lea     rdx, [rip+pc_uv]
    movsd   [rdx+rcx], xmm0
    movsd   [rdx+rcx+8], xmm1
    add     rsp, 8
    pop     r12
    pop     rbx
    ret

# pc_polyline -> rax = the samples as a degree 1 NURBS in (u, v) over t
#   (ordered by increasing t), or 0
pc_polyline:
    push    rbx
    push    r12
    push    r13
    mov     edi, 1
    mov     esi, [rip+pc_n]
    call    nb_new_ext
    test    rax, rax
    jz      9f
    mov     rbx, rax
    mov     dword ptr [rbx+CV_DIM], 2
    mov     r12d, [rip+pc_n]
    lea     rax, [rip+pc_t]             # increasing or decreasing t?
    lea     ecx, [r12-1]
    movsd   xmm0, [rax]
    xor     r13d, r13d
    comisd  xmm0, [rax+rcx*8]
    jbe     1f
    mov     r13d, 1                     # reversed: read backwards
1:  xor     ecx, ecx
2:  cmp     ecx, r12d
    jae     3f
    mov     eax, ecx
    test    r13d, r13d
    jz      21f
    mov     eax, r12d
    dec     eax
    sub     eax, ecx
21: lea     rdx, [rip+pc_t]
    movsd   xmm0, [rdx+rax*8]
    mov     rdi, [rbx+CV_KN]
    movsd   [rdi+rcx*8+8], xmm0
    shl     eax, 4
    lea     rdx, [rip+pc_uv]
    mov     rdi, [rbx+CV_CP]
    mov     r8d, ecx
    shl     r8d, 5
    movsd   xmm0, [rdx+rax]
    movsd   [rdi+r8], xmm0
    movsd   xmm0, [rdx+rax+8]
    movsd   [rdi+r8+8], xmm0
    xorpd   xmm0, xmm0
    movsd   [rdi+r8+16], xmm0
    movsd   xmm0, [rip+br_one]
    movsd   [rdi+r8+24], xmm0
    inc     ecx
    jmp     2b
3:  mov     rdi, [rbx+CV_KN]            # end knots doubled
    movsd   xmm0, [rdi+8]
    movsd   [rdi], xmm0
    movsd   xmm0, [rdi+r12*8]
    movsd   [rdi+r12*8+8], xmm0
    mov     rax, rbx
9:  pop     r13
    pop     r12
    pop     rbx
    ret

# nb_new_ext(edi=degree, esi=points) -> rax (nurbs.s's nb_new, re-done here)
nb_new_ext:
    push    rbx
    push    r12
    push    r13
    mov     r12d, edi
    mov     r13d, esi
    call    kc_new
    test    rax, rax
    jz      9f
    mov     rbx, rax
    mov     dword ptr [rbx+CV_TYPE], CT_NURBS
    mov     dword ptr [rbx+CV_DIM], 3
    mov     [rbx+CV_DEG], r12d
    mov     [rbx+CV_N], r13d
    lea     edi, [r12+r13+1]
    shl     edi, 3
    call    bk_data
    mov     [rbx+CV_KN], rax
    mov     edi, r13d
    shl     edi, 5
    call    bk_data
    mov     [rbx+CV_CP], rax
    mov     rax, rbx
9:  pop     r13
    pop     r12
    pop     rbx
    ret

# =============================================================================
#  Faces
# =============================================================================
# fc_pcurves(edi=face) - pcurves for every coedge; a degenerate one (at a
#   pole) runs straight from where the coedge before it ends to where the
#   one after it starts
fc_pcurves:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    push    rbp
    sub     rsp, 88
    mov     r15d, edi
    call    p_fc
    mov     rbx, rax
    mov     r12d, [rbx+FC_LOOP]
    mov     r13d, [rbx+FC_NLOOP]
    add     r13d, r12d
.Lfp_loop:
    cmp     r12d, r13d
    jae     .Lfp_degen
    mov     edi, r12d
    call    p_lp
    mov     r14d, [rax+LP_FIRST]
    mov     ebp, [rax+LP_N]
    add     ebp, r14d
1:  cmp     r14d, ebp
    jae     2f
    mov     edi, r14d
    call    p_ce
    cmp     dword ptr [rax+CE_PC], -1   # (kept when it has one)
    jne     11f
    mov     edi, r14d
    mov     esi, r15d
    call    pc_make
11: inc     r14d
    jmp     1b
2:  inc     r12d
    jmp     .Lfp_loop
.Lfp_degen:
    mov     r12d, [rbx+FC_LOOP]
.Lfp_dl:
    cmp     r12d, r13d
    jae     .Lfp_out
    mov     edi, r12d
    call    p_lp
    mov     r14d, [rax+LP_FIRST]
    mov     ebp, [rax+LP_N]
    mov     [rsp+80], r14d
    mov     [rsp+84], ebp
    xor     ecx, ecx
3:  cmp     ecx, [rsp+84]
    jae     5f
    mov     [rsp+72], ecx
    mov     edi, [rsp+80]
    add     edi, ecx
    mov     [rsp+76], edi
    call    p_ce
    cmp     dword ptr [rax+CE_PC], -1
    jne     4f
    mov     edi, [rax+CE_EDGE]
    call    p_ed
    test    dword ptr [rax+ED_FLAGS], EF_DEGEN
    jz      4f
    mov     eax, [rsp+72]               # the one before ends at a
    add     eax, [rsp+84]
    dec     eax
    xor     edx, edx
    div     dword ptr [rsp+84]
    mov     edi, [rsp+80]
    add     edi, edx
    movsd   xmm0, [rip+br_one]
    lea     rsi, [rsp]
    call    ce_uv
    mov     eax, [rsp+72]               # the one after starts at b
    inc     eax
    xor     edx, edx
    div     dword ptr [rsp+84]
    mov     edi, [rsp+80]
    add     edi, edx
    xorpd   xmm0, xmm0
    lea     rsi, [rsp+32]
    call    ce_uv
    call    kc_new
    mov     r14, rax
    mov     dword ptr [r14+CV_TYPE], CT_LINE
    mov     dword ptr [r14+CV_DIM], 2
    movsd   xmm0, [rsp]
    movsd   [r14+CV_O], xmm0
    movsd   xmm1, [rsp+8]
    movsd   [r14+CV_O+8], xmm1
    movsd   xmm2, [rsp+32]
    subsd   xmm2, xmm0
    movsd   [r14+CV_X], xmm2
    movsd   xmm3, [rsp+40]
    subsd   xmm3, xmm1
    movsd   [r14+CV_X+8], xmm3
    lea     rdi, [r14+CV_X]
    call    v3norm
    movsd   [rsp+64], xmm0
    mov     rdi, r14
    call    i_cv
    mov     r14d, eax
    mov     edi, [rsp+76]
    call    p_ce
    mov     [rax+CE_PC], r14d
    xorpd   xmm0, xmm0
    movsd   [rax+CE_P0], xmm0
    movsd   xmm0, [rsp+64]
    movsd   [rax+CE_P1], xmm0
4:  mov     ecx, [rsp+72]
    inc     ecx
    jmp     3b
5:  inc     r12d
    jmp     .Lfp_dl
.Lfp_out:
    add     rsp, 88
    pop     rbp
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# fc_sample(edi=face, esi=points per curved coedge) - every loop as a
#   closed (u, v) polygon: fs_pts, loop k from fs_ls[k], fs_ln[k] points
fc_sample:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    push    rbp
    sub     rsp, 56
    mov     [rsp+40], esi
    call    p_fc
    mov     rbx, rax
    xor     eax, eax
    mov     [rip+fs_nl], eax
    mov     [rip+fs_np], eax
    mov     r12d, [rbx+FC_LOOP]
    mov     r13d, [rbx+FC_NLOOP]
    add     r13d, r12d
.Lfs_loop:
    cmp     r12d, r13d
    jae     .Lfs_out
    mov     eax, [rip+fs_nl]
    cmp     eax, FS_MAXL
    jae     .Lfs_out
    mov     ecx, [rip+fs_np]
    lea     rdx, [rip+fs_ls]
    mov     [rdx+rax*4], ecx
    mov     edi, r12d
    call    p_lp
    mov     r14d, [rax+LP_FIRST]
    mov     r15d, [rax+LP_N]
    add     r15d, r14d
1:  cmp     r14d, r15d
    jae     4f
    mov     edi, r14d                   # points: a straight pcurve 1, else n
    call    p_ce
    mov     ebp, 1
    mov     edi, [rax+CE_PC]
    cmp     edi, -1
    je      3f
    call    p_cv
    cmp     dword ptr [rax+CV_TYPE], CT_LINE
    je      2f
    mov     ebp, [rsp+40]
    cmp     dword ptr [rax+CV_TYPE], CT_NURBS
    jne     2f
    cmp     dword ptr [rax+CV_DEG], 1   # a polyline: its own points
    jne     2f
    mov     ebp, [rax+CV_N]
    dec     ebp
    cmp     ebp, 1
    jge     2f
    mov     ebp, 1
2:  xor     ecx, ecx                    # s = j / n, j = 0 .. n - 1
21: cmp     ecx, ebp
    jae     3f
    mov     [rsp+44], ecx
    mov     eax, [rip+fs_np]
    cmp     eax, FS_MAX
    jae     3f
    cvtsi2sd xmm0, ecx
    cvtsi2sd xmm1, ebp
    divsd   xmm0, xmm1
    mov     edi, r14d
    lea     rsi, [rsp]
    call    ce_uv
    mov     eax, [rip+fs_np]
    shl     eax, 4
    lea     rdx, [rip+fs_pts]
    movsd   xmm0, [rsp]
    movsd   [rdx+rax], xmm0
    movsd   xmm0, [rsp+8]
    movsd   [rdx+rax+8], xmm0
    inc     dword ptr [rip+fs_np]
    mov     ecx, [rsp+44]
    inc     ecx
    jmp     21b
3:  inc     r14d
    jmp     1b
4:  mov     eax, [rip+fs_nl]
    mov     ecx, [rip+fs_np]
    lea     rdx, [rip+fs_ls]
    sub     ecx, [rdx+rax*4]
    lea     rdx, [rip+fs_ln]
    mov     [rdx+rax*4], ecx
    inc     dword ptr [rip+fs_nl]
    inc     r12d
    jmp     .Lfs_loop
.Lfs_out:
    add     rsp, 56
    pop     rbp
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# fs_area(edi=loop of the samples) -> xmm0 = its signed area
fs_area:
    lea     rax, [rip+fs_ls]
    mov     ecx, [rax+rdi*4]
    lea     rax, [rip+fs_ln]
    mov     edx, [rax+rdi*4]
    lea     rsi, [rip+fs_pts]
    xorpd   xmm0, xmm0
    xor     r8d, r8d
1:  cmp     r8d, edx
    jae     2f
    lea     eax, [rcx+r8]
    shl     eax, 4
    lea     r9d, [r8+1]
    cmp     r9d, edx
    jb      11f
    xor     r9d, r9d
11: add     r9d, ecx
    shl     r9d, 4
    movsd   xmm1, [rsi+rax]             # x0 y1 - x1 y0
    mulsd   xmm1, [rsi+r9+8]
    movsd   xmm2, [rsi+r9]
    mulsd   xmm2, [rsi+rax+8]
    subsd   xmm1, xmm2
    addsd   xmm0, xmm1
    inc     r8d
    jmp     1b
2:  mulsd   xmm0, [rip+br_half]
    ret

# fc_inside(xmm0=u, xmm1=v) -> eax = 1 if inside the sampled loops (even-odd)
fc_inside:
    xor     eax, eax
    lea     rsi, [rip+fs_pts]
    xor     r10d, r10d                  # loop
1:  cmp     r10d, [rip+fs_nl]
    jae     9f
    lea     rdx, [rip+fs_ls]
    mov     ecx, [rdx+r10*4]
    lea     rdx, [rip+fs_ln]
    mov     edx, [rdx+r10*4]
    xor     r8d, r8d
2:  cmp     r8d, edx
    jae     5f
    lea     r9d, [rcx+r8]
    shl     r9d, 4
    lea     r11d, [r8+1]
    cmp     r11d, edx
    jb      21f
    xor     r11d, r11d
21: add     r11d, ecx
    shl     r11d, 4
    movsd   xmm2, [rsi+r9+8]            # (yi > v) != (yj > v)
    movsd   xmm3, [rsi+r11+8]
    xor     edi, edi
    comisd  xmm2, xmm1
    seta    dil
    push    rax
    xor     eax, eax
    comisd  xmm3, xmm1
    seta    al
    cmp     eax, edi
    pop     rax
    je      4f
    movsd   xmm4, xmm1                  # x at v: xi + (v - yi)(xj - xi)/(yj - yi)
    subsd   xmm4, xmm2
    movsd   xmm5, [rsi+r11]
    subsd   xmm5, [rsi+r9]
    mulsd   xmm4, xmm5
    subsd   xmm3, xmm2
    divsd   xmm4, xmm3
    addsd   xmm4, [rsi+r9]
    comisd  xmm0, xmm4
    jae     4f
    xor     eax, 1
4:  inc     r8d
    jmp     2b
5:  inc     r10d
    jmp     1b
9:  ret

# fc_orient(edi=face, rsi=classifier (rdi=point -> eax = 1 inside the
#   solid), xmm0=step off the face) - its sense, then its loops turned so
#   the outer one comes first and goes the right way round
.equ FO_F,    0
.equ FO_CL,   8
.equ FO_EPS,  16
.equ FO_UV,   24                        # the inside point
.equ FO_PN,   40                        # P, N
.equ FO_Q,    88
.equ FO_BEST, 112
.equ FO_OUT,  120
.equ FO_I,    124
fc_orient:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    push    rbp
    sub     rsp, 136
    mov     r15d, edi
    mov     [rsp+FO_CL], rsi
    movsd   [rsp+FO_EPS], xmm0
    call    p_fc
    mov     rbx, rax
    mov     edi, r15d
    mov     esi, 24
    call    fc_sample
    call    fs_inner_point
    test    eax, eax
    jz      .Lfo_out
    movsd   [rsp+FO_UV], xmm0
    movsd   [rsp+FO_UV+8], xmm1
    mov     edi, [rbx+FC_SURF]
    call    p_sf
    mov     rdi, rax
    movsd   xmm0, [rsp+FO_UV]
    movsd   xmm1, [rsp+FO_UV+8]
    lea     rsi, [rsp+FO_PN]
    call    sf_normal
    lea     rdi, [rsp+FO_PN]            # P + eps N inside: the sense is 1
    lea     rsi, [rsp+FO_PN+24]
    movsd   xmm0, [rsp+FO_EPS]
    call    v3axpy
    lea     rdi, [rsp+FO_PN]
    call    [rsp+FO_CL]
    mov     [rbx+FC_SENSE], eax
    # the outer loop: the largest area
    movsd   xmm0, [rip+br_big]
    xorpd   xmm0, xmm0
    movsd   [rsp+FO_BEST], xmm0
    mov     dword ptr [rsp+FO_OUT], 0
    xor     r12d, r12d
1:  cmp     r12d, [rip+fs_nl]
    jae     2f
    mov     edi, r12d
    call    fs_area
    andpd   xmm0, [rip+br_abs]
    comisd  xmm0, [rsp+FO_BEST]
    jbe     11f
    movsd   [rsp+FO_BEST], xmm0
    mov     [rsp+FO_OUT], r12d
11: inc     r12d
    jmp     1b
2:  xor     r12d, r12d                  # each loop: counter-clockwise (outer,
3:  cmp     r12d, [rip+fs_nl]           #  sense 0) or clockwise
    jae     4f
    mov     edi, r12d
    call    fs_area
    xor     eax, eax                    # want positive?
    cmp     r12d, [rsp+FO_OUT]
    sete    al
    xor     eax, [rbx+FC_SENSE]
    xorpd   xmm1, xmm1
    xor     ecx, ecx
    comisd  xmm0, xmm1
    seta    cl
    cmp     eax, ecx
    je      31f
    mov     edi, [rbx+FC_LOOP]
    add     edi, r12d
    call    lp_flip
31: inc     r12d
    jmp     3b
4:  mov     eax, [rsp+FO_OUT]           # the outer loop first
    test    eax, eax
    jz      .Lfo_out
    mov     edi, [rbx+FC_LOOP]
    call    p_lp
    mov     r13, rax
    mov     eax, [rsp+FO_OUT]
    shl     eax, 4
    lea     r14, [r13+rax]
    movupd  xmm0, [r13]
    movupd  xmm1, [r14]
    movupd  [r13], xmm1
    movupd  [r14], xmm0
.Lfo_out:
    add     rsp, 136
    pop     rbp
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# fs_inner_point -> xmm0, xmm1 = a point inside the sampled loops, eax = 1
#   (0: none found): beside the middle of an edge of the polygon, a little in
fs_inner_point:
    push    rbx
    push    r12
    sub     rsp, 56
    lea     rsi, [rip+fs_pts]           # the extent
    mov     eax, [rip+fs_np]
    test    eax, eax
    jz      .Lfi_none
    movsd   xmm0, [rsi]
    movsd   xmm1, xmm0
    movsd   xmm2, [rsi+8]
    movsd   xmm3, xmm2
    xor     ecx, ecx
1:  cmp     ecx, eax
    jae     2f
    mov     edx, ecx
    shl     edx, 4
    minsd   xmm0, [rsi+rdx]
    maxsd   xmm1, [rsi+rdx]
    minsd   xmm2, [rsi+rdx+8]
    maxsd   xmm3, [rsi+rdx+8]
    inc     ecx
    jmp     1b
2:  subsd   xmm1, xmm0
    subsd   xmm3, xmm2
    maxsd   xmm1, xmm3
    mulsd   xmm1, [rip+br_in]
    movsd   [rsp+48], xmm1              # the step in
    mov     ebx, 1                      # try steps 1e-4, 1e-6 of the extent
.Lfi_try:
    xor     r12d, r12d                  # edge (of loop 0's points first)
.Lfi_edge:
    mov     eax, [rip+fs_np]
    cmp     r12d, eax
    jae     .Lfi_smaller
    lea     rdx, [rip+fs_ln]            # the next point within its loop
    mov     ecx, [rdx]
    lea     rsi, [rip+fs_pts]
    mov     eax, r12d
    call    fs_next
    mov     edx, r12d
    shl     edx, 4
    shl     eax, 4
    movsd   xmm0, [rsi+rax]             # d = b - a
    subsd   xmm0, [rsi+rdx]
    movsd   xmm1, [rsi+rax+8]
    subsd   xmm1, [rsi+rdx+8]
    movsd   xmm2, xmm0
    mulsd   xmm2, xmm2
    movsd   xmm3, xmm1
    mulsd   xmm3, xmm3
    addsd   xmm2, xmm3
    sqrtsd  xmm2, xmm2
    xorpd   xmm3, xmm3
    comisd  xmm2, xmm3
    je      .Lfi_next
    movsd   xmm3, [rsp+48]              # n = (-dy, dx) step / |d|
    divsd   xmm3, xmm2
    mulsd   xmm1, xmm3
    mulsd   xmm0, xmm3
    movsd   xmm4, [rsi+rax]             # middle
    addsd   xmm4, [rsi+rdx]
    mulsd   xmm4, [rip+br_half]
    movsd   xmm5, [rsi+rax+8]
    addsd   xmm5, [rsi+rdx+8]
    mulsd   xmm5, [rip+br_half]
    movsd   [rsp], xmm4
    movsd   [rsp+8], xmm5
    movsd   [rsp+16], xmm1
    movsd   [rsp+24], xmm0
    subsd   xmm4, xmm1                  # m + n
    addsd   xmm5, xmm0
    movsd   [rsp+32], xmm4
    movsd   [rsp+40], xmm5
    movsd   xmm0, xmm4
    movsd   xmm1, xmm5
    call    fc_inside
    test    eax, eax
    jz      3f
    movsd   xmm0, [rsp+32]
    movsd   xmm1, [rsp+40]
    jmp     .Lfi_found
3:  movsd   xmm0, [rsp]                 # m - n
    addsd   xmm0, [rsp+16]
    movsd   xmm1, [rsp+8]
    subsd   xmm1, [rsp+24]
    movsd   [rsp+32], xmm0
    movsd   [rsp+40], xmm1
    call    fc_inside
    test    eax, eax
    jz      .Lfi_next
    movsd   xmm0, [rsp+32]
    movsd   xmm1, [rsp+40]
    jmp     .Lfi_found
.Lfi_next:
    inc     r12d
    jmp     .Lfi_edge
.Lfi_smaller:
    dec     ebx
    js      .Lfi_none
    movsd   xmm0, [rsp+48]
    mulsd   xmm0, [rip+br_in]
    mulsd   xmm0, [rip+br_in]
    mulsd   xmm0, [rip+br_2pi]
    movsd   [rsp+48], xmm0
    jmp     .Lfi_try
.Lfi_found:
    mov     eax, 1
    jmp     9f
.Lfi_none:
    xor     eax, eax
9:  add     rsp, 56
    pop     r12
    pop     rbx
    ret
# fs_next(eax=point) -> eax = the point after it in its loop
fs_next:
    push    rcx
    push    rdx
    push    r8
    xor     ecx, ecx
1:  cmp     ecx, [rip+fs_nl]
    jae     3f
    lea     rdx, [rip+fs_ls]
    mov     r8d, [rdx+rcx*4]
    lea     rdx, [rip+fs_ln]
    mov     edx, [rdx+rcx*4]
    add     edx, r8d
    cmp     eax, edx
    jae     2f
    inc     eax
    cmp     eax, edx
    jb      3f
    mov     eax, r8d
    jmp     3f
2:  inc     ecx
    jmp     1b
3:  pop     r8
    pop     rdx
    pop     rcx
    ret

# lp_rev(edi=loop) - its coedges in the opposite order (lp_flip also turns
#   each one round)
lp_rev:
    push    rbx
    push    r12
    push    r13
    call    p_lp
    mov     ebx, [rax+LP_FIRST]
    mov     r12d, [rax+LP_N]
    lea     r13d, [rbx+r12-1]
1:  cmp     ebx, r13d                   # swap the ends inwards
    jae     2f
    mov     edi, ebx
    call    p_ce
    mov     rsi, rax
    mov     edi, r13d
    call    p_ce
    mov     ecx, CE_SZ/8
3:  mov     rdx, [rsi+rcx*8-8]
    mov     r8, [rax+rcx*8-8]
    mov     [rsi+rcx*8-8], r8
    mov     [rax+rcx*8-8], rdx
    loop    3b
    inc     ebx
    dec     r13d
    jmp     1b
2:  pop     r13
    pop     r12
    pop     rbx
    ret

# =============================================================================
#  Bodies
# =============================================================================
# bd_flip(edi=body) - inside out: every sense flipped, every loop reversed
bd_flip:
    push    rbx
    push    r12
    push    r13
    push    r14
    sub     rsp, 8
    call    p_bd
    mov     ebx, [rax+BD_FIRST]
    mov     r12d, [rax+BD_NF]
    add     r12d, ebx
1:  cmp     ebx, r12d
    jae     9f
    mov     edi, ebx
    call    p_fc
    xor     dword ptr [rax+FC_SENSE], 1
    mov     r13d, [rax+FC_LOOP]
    mov     r14d, [rax+FC_NLOOP]
    add     r14d, r13d
2:  cmp     r13d, r14d
    jae     3f
    mov     edi, r13d
    call    lp_flip
    inc     r13d
    jmp     2b
3:  inc     ebx
    jmp     1b
9:  add     rsp, 8
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# lp_flip(edi=loop) - lp_rev, and every coedge turned round
lp_flip:
    push    rbx
    push    r12
    push    r13
    mov     ebx, edi
    call    lp_rev
    mov     edi, ebx
    call    p_lp
    mov     r12d, [rax+LP_FIRST]
    mov     r13d, [rax+LP_N]
    add     r13d, r12d
1:  cmp     r12d, r13d
    jae     9f
    mov     edi, r12d
    call    p_ce
    xor     dword ptr [rax+CE_REV], 1
    movsd   xmm0, [rax+CE_P0]
    movsd   xmm1, [rax+CE_P1]
    movsd   [rax+CE_P0], xmm1
    movsd   [rax+CE_P1], xmm0
    inc     r12d
    jmp     1b
9:  pop     r13
    pop     r12
    pop     rbx
    ret

# fc_box(edi=face) - its (u, v) box from its loops' samples
fc_box:
    push    rbx
    mov     ebx, edi
    mov     esi, 32
    call    fc_sample
    mov     edi, ebx
    call    p_fc
    mov     ecx, [rip+fs_np]
    test    ecx, ecx
    jz      9f
    lea     rsi, [rip+fs_pts]
    movsd   xmm0, [rsi]
    movsd   xmm1, xmm0
    movsd   xmm2, [rsi+8]
    movsd   xmm3, xmm2
1:  dec     ecx
    js      2f
    mov     edx, ecx
    shl     edx, 4
    minsd   xmm0, [rsi+rdx]
    maxsd   xmm1, [rsi+rdx]
    minsd   xmm2, [rsi+rdx+8]
    maxsd   xmm3, [rsi+rdx+8]
    jmp     1b
2:  movsd   [rax+FC_U0], xmm0
    movsd   [rax+FC_U1], xmm1
    movsd   [rax+FC_V0], xmm2
    movsd   [rax+FC_V1], xmm3
9:  pop     rbx
    ret

# bd_integrate(edi=body, esi=0 volume / 1 area) -> xmm0
.equ BI_KIND, 0
.equ BI_SUM,  8
.equ BI_SURF, 16
.equ BI_UREF, 24
.equ BI_CE,   32
.equ BI_A,    40                        # interval a, b
.equ BI_B,    48
.equ BI_NI,   56                        # intervals
.equ BI_UV,   64                        # ce_uv out (u, v, du, dv)
.equ BI_K,    96
.equ BI_J,    100
.equ BI_PC,   104
.equ BI_EV,   112                       # srf_eval out (9 doubles)
.equ BI_G,    184
.equ BI_S,    192
.equ BI_W,    200
.equ BI_X,    208
.equ BI_Q,    216
.equ BI_M,    224
.equ BI_F,    232
.equ BI_L,    236
.equ BI_LN,   240
.equ BI_C,    244
.equ BI_CN,   248
.equ BI_FN,   252
bd_integrate:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    push    rbp
    sub     rsp, 264
    mov     [rsp+BI_KIND], esi
    xorpd   xmm0, xmm0
    movsd   [rsp+BI_SUM], xmm0
    call    p_bd
    mov     ecx, [rax+BD_FIRST]
    mov     [rsp+BI_F], ecx
    mov     edx, [rax+BD_NF]
    add     edx, ecx
    mov     [rsp+BI_FN], edx
.Lbi_face:
    mov     eax, [rsp+BI_F]
    cmp     eax, [rsp+BI_FN]
    jae     .Lbi_out
    mov     edi, eax
    call    p_fc
    mov     rbx, rax
    movsd   xmm0, [rbx+FC_U0]           # u reference: the middle of its box
    addsd   xmm0, [rbx+FC_U1]
    mulsd   xmm0, [rip+br_half]
    movsd   [rsp+BI_UREF], xmm0
    mov     edi, [rbx+FC_SURF]
    call    p_sf
    mov     [rsp+BI_SURF], rax
    movsd   xmm0, [rip+br_one]          # area: a flipped face's loops turn
    cmp     dword ptr [rsp+BI_KIND], 0  #  the other way
    je      1f
    cmp     dword ptr [rbx+FC_SENSE], 0
    je      1f
    xorpd   xmm0, [rip+br_negm]
1:  movsd   [rsp+BI_M], xmm0
    mov     eax, [rbx+FC_LOOP]
    mov     [rsp+BI_L], eax
    add     eax, [rbx+FC_NLOOP]
    mov     [rsp+BI_LN], eax
.Lbi_loop:
    mov     eax, [rsp+BI_L]
    cmp     eax, [rsp+BI_LN]
    jae     .Lbi_fnext
    mov     edi, eax
    call    p_lp
    mov     ecx, [rax+LP_FIRST]
    mov     [rsp+BI_C], ecx
    add     ecx, [rax+LP_N]
    mov     [rsp+BI_CN], ecx
.Lbi_ce:
    mov     eax, [rsp+BI_C]
    cmp     eax, [rsp+BI_CN]
    jae     .Lbi_lnext
    mov     edi, eax
    call    p_ce
    mov     r12, rax
    mov     edi, [r12+CE_PC]
    cmp     edi, -1
    je      .Lbi_cnext
    call    p_cv
    mov     [rsp+BI_PC], rax
    # intervals over s in 0 .. 1: a polyline per piece, a conic 8, a line 1
    mov     ecx, 1
    cmp     dword ptr [rax+CV_TYPE], CT_LINE
    je      1f
    mov     ecx, 8
    cmp     dword ptr [rax+CV_TYPE], CT_NURBS
    jne     1f
    mov     ecx, [rax+CV_N]
    sub     ecx, [rax+CV_DEG]
    imul    ecx, ecx, 2
    cmp     dword ptr [rax+CV_DEG], 1
    je      1f
    shl     ecx, 2
1:  mov     [rsp+BI_NI], ecx
    mov     dword ptr [rsp+BI_K], 0
.Lbi_int:
    mov     eax, [rsp+BI_K]
    cmp     eax, [rsp+BI_NI]
    jae     .Lbi_cnext
    call    bi_bounds                   # [a, b] in s (polylines: knot pieces)
    mov     dword ptr [rsp+BI_J], 0
.Lbi_node:
    mov     eax, [rsp+BI_J]
    cmp     eax, 8
    jae     .Lbi_inext
    lea     rcx, [rip+gl_x]             # s = (a + b)/2 + x (b - a)/2
    movsd   xmm0, [rsp+BI_B]
    subsd   xmm0, [rsp+BI_A]
    mulsd   xmm0, [rip+br_half]
    movsd   [rsp+BI_W], xmm0            # (b - a) / 2
    mulsd   xmm0, [rcx+rax*8]
    movsd   xmm1, [rsp+BI_A]
    addsd   xmm1, [rsp+BI_B]
    mulsd   xmm1, [rip+br_half]
    addsd   xmm0, xmm1
    movsd   [rsp+BI_S], xmm0
    mov     edi, [rsp+BI_C]
    lea     rsi, [rsp+BI_UV]
    call    ce_uv
    # G = integral of f(w, v) dw from uref to u (4 pieces x 8 points)
    xorpd   xmm0, xmm0
    movsd   [rsp+BI_G], xmm0
    xor     r13d, r13d
.Lbi_gp:
    cmp     r13d, 4
    jae     .Lbi_gdone
    movsd   xmm0, [rsp+BI_UV]           # piece r13 of [uref, u]
    subsd   xmm0, [rsp+BI_UREF]
    mulsd   xmm0, [rip+bi_quarter]
    movsd   [rsp+BI_Q], xmm0            # its length (signed)
    xor     r14d, r14d
.Lbi_gn:
    cmp     r14d, 8
    jae     .Lbi_gpn
    lea     rcx, [rip+gl_x]
    movsd   xmm0, [rcx+r14*8]           # w = uref + q (r13 + (1 + x)/2)
    addsd   xmm0, [rip+br_one]
    mulsd   xmm0, [rip+br_half]
    cvtsi2sd xmm1, r13d
    addsd   xmm0, xmm1
    mulsd   xmm0, [rsp+BI_Q]
    addsd   xmm0, [rsp+BI_UREF]
    movsd   xmm1, [rsp+BI_UV+8]
    mov     rdi, [rsp+BI_SURF]
    lea     rsi, [rsp+BI_EV]
    call    srf_eval
    lea     rdi, [rsp+BI_X]             # Su x Sv (into the 9-double block's
    sub     rsp, 32                     #  scratch below)
    lea     rdi, [rsp]
    lea     rsi, [rsp+32+BI_EV+24]
    lea     rdx, [rsp+32+BI_EV+48]
    call    v3cross
    cmp     dword ptr [rsp+32+BI_KIND], 0
    jne     2f
    lea     rdi, [rsp]                  # volume: P . (Su x Sv)
    lea     rsi, [rsp+32+BI_EV]
    call    v3dot
    jmp     3f
2:  lea     rdi, [rsp]                  # area: |Su x Sv|
    call    v3len
3:  add     rsp, 32
    lea     rcx, [rip+gl_w]
    mulsd   xmm0, [rcx+r14*8]
    mulsd   xmm0, [rsp+BI_Q]
    mulsd   xmm0, [rip+br_half]
    addsd   xmm0, [rsp+BI_G]
    movsd   [rsp+BI_G], xmm0
    inc     r14d
    jmp     .Lbi_gn
.Lbi_gpn:
    inc     r13d
    jmp     .Lbi_gp
.Lbi_gdone:
    # sum += w_j G dv/dp dp/ds (b - a)/2; dp/ds = P1 - P0
    mov     eax, [rsp+BI_J]
    lea     rcx, [rip+gl_w]
    movsd   xmm0, [rsp+BI_G]
    mulsd   xmm0, [rcx+rax*8]
    mulsd   xmm0, [rsp+BI_UV+24]
    movsd   xmm1, [r12+CE_P1]
    subsd   xmm1, [r12+CE_P0]
    mulsd   xmm0, xmm1
    mulsd   xmm0, [rsp+BI_W]
    mulsd   xmm0, [rsp+BI_M]
    addsd   xmm0, [rsp+BI_SUM]
    movsd   [rsp+BI_SUM], xmm0
    inc     dword ptr [rsp+BI_J]
    jmp     .Lbi_node
.Lbi_inext:
    inc     dword ptr [rsp+BI_K]
    jmp     .Lbi_int
.Lbi_cnext:
    inc     dword ptr [rsp+BI_C]
    jmp     .Lbi_ce
.Lbi_lnext:
    inc     dword ptr [rsp+BI_L]
    jmp     .Lbi_loop
.Lbi_fnext:
    inc     dword ptr [rsp+BI_F]
    jmp     .Lbi_face
.Lbi_out:
    movsd   xmm0, [rsp+BI_SUM]
    cmp     dword ptr [rsp+BI_KIND], 0
    jne     1f
    mulsd   xmm0, [rip+br_third]
1:  add     rsp, 264
    pop     rbp
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# bi_bounds(eax=interval k; bd_integrate's frame, r12=coedge) - [a, b] in s:
#   k/n .. (k+1)/n, or for a polyline pcurve the k-th of its pieces (split
#   in two) mapped to s
bi_bounds:
    lea     r9, [rsp+8]                 # bd_integrate's frame
    mov     r8, [r9+BI_PC]
    cmp     dword ptr [r8+CV_TYPE], CT_NURBS
    jne     1f
    cmp     dword ptr [r8+CV_DEG], 1
    jne     1f
    mov     ecx, eax                    # piece k / 2, half k % 2
    shr     ecx, 1
    mov     rdx, [r8+CV_KN]
    movsd   xmm0, [rdx+rcx*8+8]         # its knots t_c, t_c+1 (polyline knots
    movsd   xmm1, [rdx+rcx*8+16]        #  start at index 1)
    test    eax, 1
    jz      2f
    addsd   xmm0, xmm1
    mulsd   xmm0, [rip+br_half]
    jmp     3f
2:  addsd   xmm1, xmm0
    mulsd   xmm1, [rip+br_half]
3:  movsd   xmm2, [r12+CE_P1]           # s = (t - P0) / (P1 - P0)
    subsd   xmm2, [r12+CE_P0]
    subsd   xmm0, [r12+CE_P0]
    divsd   xmm0, xmm2
    subsd   xmm1, [r12+CE_P0]
    divsd   xmm1, xmm2
    movsd   [r9+BI_A], xmm0
    movsd   [r9+BI_B], xmm1
    ret
1:  cvtsi2sd xmm0, eax
    cvtsi2sd xmm2, dword ptr [r9+BI_NI]
    divsd   xmm0, xmm2
    movsd   [r9+BI_A], xmm0
    inc     eax
    cvtsi2sd xmm1, eax
    divsd   xmm1, xmm2
    movsd   [r9+BI_B], xmm1
    ret

.section .rodata
.align 8
bi_quarter:     .double 0.25
.text

# bd_volume(edi=body) -> xmm0;  bd_area(edi=body) -> xmm0
bd_volume:
    xor     esi, esi
    jmp     bd_integrate
bd_area:
    mov     esi, 1
    jmp     bd_integrate

# bd_stats(edi=body) - bs_v, bs_e (edges used), bs_f, bs_l
bd_stats:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    mov     ebx, edi
    xor     eax, eax
    mov     [rip+bs_v], eax
    mov     [rip+bs_e], eax
    mov     [rip+bs_l], eax
    mov     [rip+bs_bad], eax
    mov     edi, ebx                    # pass 0: clear marks; 1: count
    xor     esi, esi
    call    bd_walk
    mov     edi, ebx
    mov     esi, 1
    call    bd_walk
    mov     edi, ebx
    call    p_bd
    mov     ecx, [rax+BD_NF]
    mov     [rip+bs_f], ecx
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# bd_walk(edi=body, esi=pass) - every coedge: pass 0 clears its edge's and
#   vertices' marks, pass 1 counts uses (ED_MARK: +1 forwards, +0x10000
#   backwards) and new vertices and edges; pass 2 checks the counts
bd_walk:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    push    rbp
    sub     rsp, 24
    mov     [rsp], esi
    call    p_bd
    mov     ebx, [rax+BD_FIRST]
    mov     r12d, [rax+BD_NF]
    add     r12d, ebx
.Lbw_f:
    cmp     ebx, r12d
    jae     .Lbw_out
    mov     edi, ebx
    call    p_fc
    mov     r13d, [rax+FC_LOOP]
    mov     r14d, [rax+FC_NLOOP]
    add     r14d, r13d
.Lbw_l:
    cmp     r13d, r14d
    jae     .Lbw_fn
    cmp     dword ptr [rsp], 1
    jne     1f
    inc     dword ptr [rip+bs_l]
1:  mov     edi, r13d
    call    p_lp
    mov     r15d, [rax+LP_FIRST]
    mov     ebp, [rax+LP_N]
    mov     [rsp+8], r15d
    mov     [rsp+12], ebp
    add     ebp, r15d
.Lbw_c:
    cmp     r15d, ebp
    jae     .Lbw_ln
    mov     edi, r15d
    call    p_ce
    mov     ecx, [rax+CE_REV]
    mov     [rsp+4], ecx
    mov     edi, [rax+CE_EDGE]
    call    p_ed
    mov     r8, rax
    test    dword ptr [r8+ED_FLAGS], EF_DEGEN
    jnz     .Lbw_cn
    mov     ecx, [rsp]
    cmp     ecx, 0
    jne     2f
    mov     dword ptr [r8+ED_MARK], 0   # pass 0
    mov     edi, [r8+ED_V0]
    call    p_vx
    mov     qword ptr [rax+VX_TOL], 0
    mov     edi, [r8+ED_V1]
    call    p_vx
    mov     qword ptr [rax+VX_TOL], 0
    jmp     .Lbw_cn
2:  cmp     ecx, 1
    jne     3f
    cmp     dword ptr [r8+ED_MARK], 0   # pass 1
    jne     21f
    inc     dword ptr [rip+bs_e]
21: mov     eax, 1
    cmp     dword ptr [rsp+4], 0
    je      22f
    mov     eax, 0x10000
22: add     [r8+ED_MARK], eax
    mov     edi, [r8+ED_V0]
    call    vmark
    mov     edi, [r8+ED_V1]
    call    vmark
    # the loop is closed: this coedge's end is the next one's start
    mov     eax, r15d
    inc     eax
    cmp     eax, ebp
    jb      23f
    mov     eax, [rsp+8]
23: mov     edi, eax
    call    ce_ends
    mov     [rsp+16], eax               # next's start
    mov     edi, r15d
    call    ce_ends
    cmp     edx, [rsp+16]
    je      .Lbw_cn
    inc     dword ptr [rip+bs_bad]
    jmp     .Lbw_cn
3:  cmp     dword ptr [r8+ED_MARK], 0x10001   # pass 2: once each way
    je      .Lbw_cn
    inc     dword ptr [rip+bs_bad]
    mov     dword ptr [r8+ED_MARK], 0x10001   # (counted once)
.Lbw_cn:
    inc     r15d
    jmp     .Lbw_c
.Lbw_ln:
    inc     r13d
    jmp     .Lbw_l
.Lbw_fn:
    inc     ebx
    jmp     .Lbw_f
.Lbw_out:
    add     rsp, 24
    pop     rbp
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret
# vmark(edi=vertex) - counted once (VX_TOL's high word as the mark)
vmark:
    call    p_vx
    cmp     dword ptr [rax+VX_TOL+4], 0x7ff00001
    je      9f
    mov     dword ptr [rax+VX_TOL+4], 0x7ff00001
    inc     dword ptr [rip+bs_v]
9:  ret
# ce_ends(edi=coedge) -> eax = the vertex it starts at, edx = where it ends
#   (degenerate: its vertex both)
ce_ends:
    push    rbx
    call    p_ce
    mov     ebx, [rax+CE_REV]
    mov     edi, [rax+CE_EDGE]
    call    p_ed
    mov     ecx, [rax+ED_V0]
    mov     edx, [rax+ED_V1]
    mov     eax, ecx
    test    ebx, ebx
    jz      1f
    xchg    eax, edx
1:  pop     rbx
    ret

# bd_check(edi=body) -> eax = problems: loops that do not close, edges not
#   used exactly once each way (bd_stats' counts are set too)
bd_check:
    push    rbx
    mov     ebx, edi
    call    bd_stats
    mov     edi, ebx
    mov     esi, 2
    call    bd_walk
    mov     eax, [rip+bs_bad]
    pop     rbx
    ret

.section .note.GNU-stack,"",@progbits
