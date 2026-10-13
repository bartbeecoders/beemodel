# =============================================================================
#  BeeModel - sketches: 2D geometry with constraints, solved
#
#  A sketch is a scene object (OT_SKETCH) on its XY, XZ or YZ plane; its
#  data is a reference-counted block (OB_SKETCH), copy-on-write like meshes,
#  so undo snapshots share it. Points, lines, circles and arcs; constraints
#  become residual equations over the unknowns (point coordinates, radii),
#  and a damped Gauss-Newton (Levenberg-Marquardt) solves each connected
#  group of unknowns on its own, in doubles. Dimension values may be
#  expressions with units and parameters (cad.s).
#
#  After a solve, the Jacobian's rank says how many degrees of freedom are
#  left; unknowns outside its null space are fixed, so each point and entity
#  knows whether it is fully constrained. Equations still unsatisfied are
#  conflicts.
# =============================================================================
.intel_syntax noprefix
.include "const.inc"

.globl sk_new
.globl sk_ref
.globl sk_unref
.globl sk_own
.globl sk_add_point
.globl sk_add_line
.globl sk_add_circle
.globl sk_add_arc
.globl sk_add_con
.globl sk_solve
.globl sk_point_xy
.globl sk_ent_point
.globl sk_con_type
.globl sk_draw
.globl sk_display_mesh
.globl sk_plane_xyz
.globl sk_delete
.globl sk_drop_con

# the block
.equ SK_REFS,    0
.equ SK_BYTES,   4
.equ SK_PLANE,   8                      # 0 XY, 1 XZ, 2 YZ
.equ SK_NPT,     12
.equ SK_NENT,    16
.equ SK_NCON,    20
.equ SK_DOF,     24                     # after a solve (-1: never solved)
.equ SK_NBAD,    28                     # conflicting constraints
.equ SK_OFFSET,  32                     # double: along the plane's normal
.equ SK_PTS,     64
.equ MAX_PT,     256
.equ PT_SZ,      24                     # x, y (double), flags
.equ PT_X,       0
.equ PT_Y,       8
.equ PT_FLAGS,   16
.equ SK_ENTS,    SK_PTS + MAX_PT*PT_SZ
.equ MAX_ENT,    256
.equ EN_SZ,      32                     # type, p0 p1 p2, radius, flags
.equ EN_TYPE,    0
.equ EN_P0,      4
.equ EN_P1,      8
.equ EN_P2,      12
.equ EN_R,       16                     # double
.equ EN_FLAGS,   24
.equ SK_CONS,    SK_ENTS + MAX_ENT*EN_SZ
.equ MAX_CON,    256
.equ CN_SZ,      96                     # type, a b c, value, value2, flags, expr
.equ CN_TYPE,    0
.equ CN_A,       4
.equ CN_B,       8
.equ CN_C,       12
.equ CN_VAL,     16                     # double
.equ CN_VAL2,    24                     # double (fixed y, tangent side, ...)
.equ CN_FLAGS,   32
.equ CN_EXPR,    36                     # 60 bytes: the value as an expression
.equ SK_SZ,      SK_CONS + MAX_CON*CN_SZ
# flags
.equ F_FULL,     1                      # fully constrained
.equ F_BAD,      2                      # in conflict
.equ F_CONSTR,   4                      # construction geometry
# entities
.equ E_LINE,     1
.equ E_CIRCLE,   2
.equ E_ARC,      3
# constraints
.equ C_COINCIDENT, 1
.equ C_HORIZONTAL, 2
.equ C_VERTICAL,   3
.equ C_PARALLEL,   4
.equ C_PERP,       5
.equ C_EQUAL,      6
.equ C_TANGENT,    7
.equ C_FIXED,      8
.equ C_DISTANCE,   9
.equ C_HDIST,      10
.equ C_VDIST,      11
.equ C_RADIUS,     12
.equ C_ANGLE,      13
.equ C_ONLINE,     14
.equ C_ONCIRCLE,   15
.equ C_MIDPOINT,   16
.equ C_SYMMETRIC,  17
.equ C_LENGTH,     18
.equ C_DIAMETER,   19
.equ NCTYPES,      19
.equ MAP_ANON_PRIV, 0x22
.equ MAX_VARS,   MAX_PT*2 + MAX_ENT
.equ MAX_EQS,    MAX_CON*2 + MAX_ENT*2
.equ MAX_ITER,   60

.section .rodata
.align 8
sd_zero:        .double 0.0
sd_one:         .double 1.0
sd_half:        .double 0.5
sd_tiny:        .double 1.0e-300
sd_h:           .double 1.0e-7                  # finite-difference step (relative)
sd_tol:         .double 1.0e-9                  # converged residual (relative)
sd_rank:        .double 1.0e-7                  # rank tolerance (relative)
sd_null:        .double 1.0e-6
sd_mu:          .double 1.0e-10                 # regularises null directions
sd_lam0:        .double 1.0e-3
sd_up:          .double 4.0
sd_down:        .double 0.33333333333
sd_lmax:        .double 1.0e12
sd_pi:          .double 3.14159265358979323846
sd_2pi:         .double 6.28318530717958647692
.align 16
sd_abs:         .quad 0x7fffffffffffffff, 0
.align 16
sd_sign:        .quad 0x8000000000000000, 0
# equations per constraint type (index = type)
con_neq:        .byte 0, 2,1,1,1,1,1,1,2,1,1,1,1,1,1,1,2,2,1,1
.align 8
con_names:      .quad 0, cn_coin, cn_hor, cn_ver, cn_par, cn_perp, cn_eq, cn_tan, cn_fix
                .quad cn_dist, cn_hdist, cn_vdist, cn_rad, cn_ang, cn_onl, cn_onc, cn_mid
                .quad cn_sym, cn_len, cn_dia, 0
cn_coin:        .asciz "coincident"
cn_hor:         .asciz "horizontal"
cn_ver:         .asciz "vertical"
cn_par:         .asciz "parallel"
cn_perp:        .asciz "perpendicular"
cn_eq:          .asciz "equal"
cn_tan:         .asciz "tangent"
cn_fix:         .asciz "fixed"
cn_dist:        .asciz "distance"
cn_hdist:       .asciz "hdistance"
cn_vdist:       .asciz "vdistance"
cn_rad:         .asciz "radius"
cn_ang:         .asciz "angle"
cn_onl:         .asciz "online"
cn_onc:         .asciz "oncircle"
cn_mid:         .asciz "midpoint"
cn_sym:         .asciz "symmetric"
cn_len:         .asciz "length"
cn_dia:         .asciz "diameter"
.align 4
sf_seg:         .float 0.0                      # (unused)

.section .bss
.align 8
sv_sk:          .skip 8                 # the sketch being solved
sv_x:           .skip 8*MAX_VARS        # unknowns
sv_xbest:       .skip 8*MAX_VARS
sv_nv:          .skip 4
sv_neq:         .skip 4
sv_eqc:         .skip 4*MAX_EQS         # equation -> constraint (or -1 - entity)
sv_eqk:         .skip MAX_EQS           # which of its equations
sv_eqvars:      .skip 4*8*MAX_EQS       # up to 8 unknowns per equation (-1 end)
sv_eqval:       .skip 8*MAX_EQS         # constraint values (evaluated)
sv_parent:      .skip 4*MAX_VARS        # union-find
sv_comp:        .skip 4*MAX_VARS        # component id per unknown
sv_entvar:      .skip 4*MAX_ENT         # radius unknown per entity (-1)
sv_free:        .skip MAX_VARS          # 1: still free after the solve
sv_cv:          .skip 4*MAX_VARS        # this component's unknowns
sv_ce:          .skip 4*MAX_EQS         # this component's equations
sv_f:           .skip 8*MAX_EQS
sv_f2:          .skip 8*MAX_EQS
sv_scale:       .skip 8
sv_mat:         .skip 8                 # scratch mapping: J (m x n), A (n x n), g, d
sv_matsz:       .skip 8
sv_dof:         .skip 4
sv_bad:         .skip 4

.text

# =============================================================================
#  The block
# =============================================================================
sk_ref:
    test    rdi, rdi
    jz      1f
    inc     dword ptr [rdi+SK_REFS]
1:  ret
sk_unref:
    test    rdi, rdi
    jz      1f
    dec     dword ptr [rdi+SK_REFS]
    jnz     1f
    mov     esi, [rdi+SK_BYTES]
    mov     eax, SYS_MUNMAP
    syscall
1:  ret

# alloc -> rax = a zeroed block or 0
alloc:
    xor     edi, edi
    mov     esi, (SK_SZ+4095) & -4096
    mov     edx, PROT_RW
    mov     r10d, MAP_ANON_PRIV
    mov     r8d, -1
    xor     r9d, r9d
    mov     eax, SYS_MMAP
    syscall
    cmp     rax, -4096
    jbe     1f
    xor     eax, eax
    ret
1:  mov     dword ptr [rax+SK_REFS], 1
    mov     dword ptr [rax+SK_BYTES], (SK_SZ+4095) & -4096
    mov     dword ptr [rax+SK_DOF], -1
    ret

# sk_new(edi=plane) -> rax = a new block
sk_new:
    push    rbx
    mov     ebx, edi
    call    alloc
    test    rax, rax
    jz      1f
    mov     [rax+SK_PLANE], ebx
1:  pop     rbx
    ret

# sk_own(rdi=object) -> rax = its sketch, ours to change (copied if shared)
sk_own:
    push    rbx
    push    r12
    sub     rsp, 8
    mov     r12, rdi
    mov     rbx, [r12+OB_SKETCH]
    test    rbx, rbx
    jz      8f
    cmp     dword ptr [rbx+SK_REFS], 1
    je      7f
    call    alloc
    test    rax, rax
    jz      8f
    mov     rdi, rax
    mov     rsi, rbx
    mov     ecx, SK_SZ
    rep     movsb
    sub     rdi, SK_SZ
    mov     dword ptr [rdi+SK_REFS], 1
    mov     [r12+OB_SKETCH], rdi
    push    rdi
    mov     rdi, rbx
    call    sk_unref
    pop     rbx
7:  mov     rax, rbx
    jmp     9f
8:  xor     eax, eax
9:  add     rsp, 8
    pop     r12
    pop     rbx
    ret

# sk_add_point(rdi=sketch, xmm0=x, xmm1=y doubles) -> eax = index or -1
sk_add_point:
    mov     eax, [rdi+SK_NPT]
    cmp     eax, MAX_PT
    jae     8f
    imul    ecx, eax, PT_SZ
    movsd   [rdi+SK_PTS+rcx+PT_X], xmm0
    movsd   [rdi+SK_PTS+rcx+PT_Y], xmm1
    mov     dword ptr [rdi+SK_PTS+rcx+PT_FLAGS], 0
    inc     dword ptr [rdi+SK_NPT]
    ret
8:  mov     eax, -1
    ret

# ent(rdi=sketch, esi=type, edx=p0, ecx=p1, r8d=p2, xmm0=radius) -> eax
ent:
    mov     eax, [rdi+SK_NENT]
    cmp     eax, MAX_ENT
    jae     8f
    imul    r9d, eax, EN_SZ
    lea     r9, [rdi+SK_ENTS+r9]
    mov     [r9+EN_TYPE], esi
    mov     [r9+EN_P0], edx
    mov     [r9+EN_P1], ecx
    mov     [r9+EN_P2], r8d
    movsd   [r9+EN_R], xmm0
    mov     dword ptr [r9+EN_FLAGS], 0
    inc     dword ptr [rdi+SK_NENT]
    ret
8:  mov     eax, -1
    ret

# sk_add_line(rdi=sketch, esi=point a, edx=point b) -> eax = entity
sk_add_line:
    mov     ecx, edx
    mov     edx, esi
    mov     esi, E_LINE
    mov     r8d, -1
    xorpd   xmm0, xmm0
    jmp     ent

# sk_add_circle(rdi=sketch, esi=centre, xmm0=radius) -> eax = entity
sk_add_circle:
    mov     edx, esi
    mov     esi, E_CIRCLE
    mov     ecx, -1
    mov     r8d, -1
    jmp     ent

# sk_add_arc(rdi=sketch, esi=centre, edx=start, ecx=end, xmm0=radius)
#   -> eax (counter-clockwise from start to end)
sk_add_arc:
    mov     r8d, ecx
    mov     ecx, edx
    mov     edx, esi
    mov     esi, E_ARC
    jmp     ent

# sk_add_con(rdi=sketch, esi=type, edx=a, ecx=b, r8d=c, xmm0=value,
#   r9=expression text or 0) -> eax = constraint or -1. Side information
#   (fixed position, tangent side) is taken from the current geometry.
sk_add_con:
    push    rbx
    push    r12
    mov     rbx, rdi
    mov     eax, [rbx+SK_NCON]
    cmp     eax, MAX_CON
    jae     8f
    lea     eax, [rsi-1]
    cmp     eax, NCTYPES
    jae     8f
    mov     eax, [rbx+SK_NCON]
    imul    r12d, eax, CN_SZ
    lea     r12, [rbx+SK_CONS+r12]
    mov     [r12+CN_TYPE], esi
    mov     [r12+CN_A], edx
    mov     [r12+CN_B], ecx
    mov     [r12+CN_C], r8d
    movsd   [r12+CN_VAL], xmm0
    xorpd   xmm1, xmm1
    movsd   [r12+CN_VAL2], xmm1
    mov     dword ptr [r12+CN_FLAGS], 0
    mov     byte ptr [r12+CN_EXPR], 0
    test    r9, r9
    jz      2f
    xor     ecx, ecx
1:  mov     al, [r9+rcx]
    mov     [r12+CN_EXPR+rcx], al
    test    al, al
    jz      2f
    inc     ecx
    cmp     ecx, 59
    jb      1b
    mov     byte ptr [r12+CN_EXPR+rcx], 0
2:  cmp     esi, C_FIXED                # fixed: where the point is now
    jne     3f
    imul    eax, edx, PT_SZ
    movsd   xmm0, [rbx+SK_PTS+rax+PT_X]
    movsd   [r12+CN_VAL], xmm0
    movsd   xmm0, [rbx+SK_PTS+rax+PT_Y]
    movsd   [r12+CN_VAL2], xmm0
    jmp     7f
3:  cmp     esi, C_TANGENT              # tangent: keep today's side / mode
    jne     7f
    mov     [rip+sv_sk], rbx
    call    tangent_side
    movsd   [r12+CN_VAL2], xmm0
7:  mov     eax, [rbx+SK_NCON]
    inc     dword ptr [rbx+SK_NCON]
    jmp     9f
8:  mov     eax, -1
9:  pop     r12
    pop     rbx
    ret

# tangent_side(r12=constraint; sv_sk) -> xmm0: line-circle: the side of the
#   centre (+1 / -1); circle-circle: +1 outside, -1 inside
tangent_side:
    push    rbx
    mov     rbx, [rip+sv_sk]
    mov     eax, [r12+CN_A]
    imul    eax, eax, EN_SZ
    lea     r8, [rbx+SK_ENTS+rax]       # entity a
    mov     eax, [r12+CN_B]
    imul    eax, eax, EN_SZ
    lea     r9, [rbx+SK_ENTS+rax]       # entity b
    cmp     dword ptr [r8+EN_TYPE], E_LINE
    je      1f
    cmp     dword ptr [r9+EN_TYPE], E_LINE
    jne     5f
    xchg    r8, r9                      # line first
    mov     eax, [r12+CN_A]
    mov     ecx, [r12+CN_B]
    mov     [r12+CN_A], ecx
    mov     [r12+CN_B], eax
1:  mov     eax, [r8+EN_P0]             # cross(b - a, c - a)
    call    pxy
    movsd   xmm4, xmm0
    movsd   xmm5, xmm1
    mov     eax, [r8+EN_P1]
    call    pxy
    subsd   xmm0, xmm4
    subsd   xmm1, xmm5
    movsd   xmm6, xmm0
    movsd   xmm7, xmm1
    mov     eax, [r9+EN_P0]
    call    pxy
    subsd   xmm0, xmm4
    subsd   xmm1, xmm5
    mulsd   xmm6, xmm1
    mulsd   xmm7, xmm0
    subsd   xmm6, xmm7
    movsd   xmm0, [rip+sd_one]
    xorpd   xmm1, xmm1
    comisd  xmm6, xmm1
    jae     9f
    xorpd   xmm0, [rip+sd_sign]
    jmp     9f
5:  mov     eax, [r8+EN_P0]             # two circles: outside if |c1 c2| >= r1
    call    pxy                         #  or r2 (roughly)
    movsd   xmm4, xmm0
    movsd   xmm5, xmm1
    mov     eax, [r9+EN_P0]
    call    pxy
    subsd   xmm0, xmm4
    subsd   xmm1, xmm5
    mulsd   xmm0, xmm0
    mulsd   xmm1, xmm1
    addsd   xmm0, xmm1
    sqrtsd  xmm0, xmm0
    movsd   xmm1, [r8+EN_R]
    maxsd   xmm1, [r9+EN_R]
    comisd  xmm0, xmm1
    movsd   xmm0, [rip+sd_one]
    jae     9f
    xorpd   xmm0, [rip+sd_sign]
9:  pop     rbx
    ret

# pxy(eax=point; rbx=sketch) -> xmm0, xmm1 (stored coordinates)
pxy:
    imul    eax, eax, PT_SZ
    movsd   xmm0, [rbx+SK_PTS+rax+PT_X]
    movsd   xmm1, [rbx+SK_PTS+rax+PT_Y]
    ret

# sk_point_xy(rdi=sketch, esi=point) -> xmm0, xmm1
sk_point_xy:
    imul    eax, esi, PT_SZ
    movsd   xmm0, [rdi+SK_PTS+rax+PT_X]
    movsd   xmm1, [rdi+SK_PTS+rax+PT_Y]
    ret

# sk_ent_point(rdi=sketch, esi=entity, edx=which 0..2) -> eax = point or -1
sk_ent_point:
    mov     eax, -1
    cmp     esi, [rdi+SK_NENT]
    jae     9f
    cmp     edx, 3
    jae     9f
    imul    ecx, esi, EN_SZ
    lea     rcx, [rdi+SK_ENTS+rcx]
    mov     eax, [rcx+EN_P0+rdx*4]
9:  ret

# sk_con_type(rdi=name) -> eax = type or -1
sk_con_type:
    push    rbx
    push    r12
    sub     rsp, 8
    mov     r12, rdi
    mov     ebx, 1
1:  lea     rax, [rip+con_names]
    mov     rsi, [rax+rbx*8]
    test    rsi, rsi
    jz      8f
    mov     rdi, r12
    call    str_eq
    test    eax, eax
    jnz     2f
    inc     ebx
    jmp     1b
8:  mov     ebx, -1
2:  mov     eax, ebx
    add     rsp, 8
    pop     r12
    pop     rbx
    ret

# =============================================================================
#  Equations
# =============================================================================
# The unknowns: point p -> 2p, 2p + 1; a circle / arc radius -> sv_entvar.
# X(k) is sv_x[k].
.macro VX reg, var
    movsd   \reg, [r15+\var*8]
.endm

# pv(eax=point) -> xmm0, xmm1 from the unknowns (r15 = sv_x)
pv:
    lea     ecx, [rax+rax]
    movsd   xmm0, [r15+rcx*8]
    movsd   xmm1, [r15+rcx*8+8]
    ret

# entp(eax=entity, ecx=which) -> eax = its point (rbx = sketch)
entp:
    imul    eax, eax, EN_SZ
    lea     rax, [rbx+SK_ENTS+rax]
    mov     eax, [rax+EN_P0+rcx*4]
    ret

# entr(eax=entity) -> xmm0 = its radius unknown
entr:
    lea     rcx, [rip+sv_entvar]
    mov     eax, [rcx+rax*4]
    movsd   xmm0, [r15+rax*8]
    ret

# ldir(eax=line entity) -> xmm0, xmm1 = b - a; xmm2, xmm3 = a
ldir:
    push    rax
    xor     ecx, ecx
    call    entp
    call    pv
    movsd   xmm2, xmm0
    movsd   xmm3, xmm1
    pop     rax
    mov     ecx, 1
    call    entp
    call    pv
    subsd   xmm0, xmm2
    subsd   xmm1, xmm3
    ret

# len2(xmm0, xmm1) -> xmm0 = sqrt(x^2 + y^2)
len2:
    mulsd   xmm0, xmm0
    mulsd   xmm1, xmm1
    addsd   xmm0, xmm1
    sqrtsd  xmm0, xmm0
    ret

# resid(edi=equation) -> xmm0 (rbx = sketch, r15 = sv_x)
resid:
    push    r12
    push    r13
    push    r14
    sub     rsp, 112
    lea     rax, [rip+sv_eqc]
    mov     r12d, [rax+rdi*4]           # constraint, or -1 - entity
    lea     rax, [rip+sv_eqk]
    movzx   r13d, byte ptr [rax+rdi]    # which equation of it
    lea     rax, [rip+sv_eqval]
    movsd   xmm7, [rax+rdi*8]
    movsd   [rsp+96], xmm7              # its value
    test    r12d, r12d
    js      .Lr_arc
    imul    eax, r12d, CN_SZ
    lea     r14, [rbx+SK_CONS+rax]
    mov     eax, [r14+CN_TYPE]
    cmp     eax, C_COINCIDENT
    je      .Lr_coin
    cmp     eax, C_HORIZONTAL
    je      .Lr_hor
    cmp     eax, C_VERTICAL
    je      .Lr_ver
    cmp     eax, C_PARALLEL
    je      .Lr_par
    cmp     eax, C_PERP
    je      .Lr_perp
    cmp     eax, C_EQUAL
    je      .Lr_equal
    cmp     eax, C_TANGENT
    je      .Lr_tan
    cmp     eax, C_FIXED
    je      .Lr_fixed
    cmp     eax, C_DISTANCE
    je      .Lr_dist
    cmp     eax, C_HDIST
    je      .Lr_hdist
    cmp     eax, C_VDIST
    je      .Lr_vdist
    cmp     eax, C_RADIUS
    je      .Lr_radius
    cmp     eax, C_ANGLE
    je      .Lr_angle
    cmp     eax, C_ONLINE
    je      .Lr_online
    cmp     eax, C_ONCIRCLE
    je      .Lr_oncircle
    cmp     eax, C_MIDPOINT
    je      .Lr_mid
    cmp     eax, C_SYMMETRIC
    je      .Lr_sym
    cmp     eax, C_LENGTH
    je      .Lr_len
    cmp     eax, C_DIAMETER
    je      .Lr_dia
    xorpd   xmm0, xmm0
    jmp     .Lr_out

.Lr_arc:                                # an arc's start / end on its circle
    not     r12d
    mov     eax, r12d
    xor     ecx, ecx
    call    entp
    call    pv
    movsd   [rsp], xmm0
    movsd   [rsp+8], xmm1
    lea     ecx, [r13+1]
    mov     eax, r12d
    call    entp
    call    pv
    subsd   xmm0, [rsp]
    subsd   xmm1, [rsp+8]
    call    len2
    movsd   [rsp], xmm0
    mov     eax, r12d
    call    entr
    movsd   xmm1, xmm0
    movsd   xmm0, [rsp]
    subsd   xmm0, xmm1
    jmp     .Lr_out

.Lr_coin:                               # p - q, by component
    mov     eax, [r14+CN_A]
    call    pv
    movsd   [rsp], xmm0
    movsd   [rsp+8], xmm1
    mov     eax, [r14+CN_B]
    call    pv
    test    r13d, r13d
    jnz     1f
    movsd   xmm1, [rsp]
    subsd   xmm1, xmm0
    movsd   xmm0, xmm1
    jmp     .Lr_out
1:  movsd   xmm0, [rsp+8]
    subsd   xmm0, xmm1
    jmp     .Lr_out

.Lr_hor:                                # dy of the line
    mov     eax, [r14+CN_A]
    call    ldir
    movsd   xmm0, xmm1
    jmp     .Lr_out
.Lr_ver:
    mov     eax, [r14+CN_A]
    call    ldir
    jmp     .Lr_out

.Lr_par:                                # cross(d1, d2) / (|d1| |d2|)
.Lr_perp:                               # dot(d1, d2) / (|d1| |d2|)
    mov     eax, [r14+CN_A]
    call    ldir
    movsd   [rsp], xmm0
    movsd   [rsp+8], xmm1
    mov     eax, [r14+CN_B]
    call    ldir
    movsd   [rsp+16], xmm0
    movsd   [rsp+24], xmm1
    cmp     dword ptr [r14+CN_TYPE], C_PARALLEL
    jne     1f
    movsd   xmm2, [rsp]                 # x1 y2 - y1 x2
    mulsd   xmm2, [rsp+24]
    movsd   xmm3, [rsp+8]
    mulsd   xmm3, [rsp+16]
    subsd   xmm2, xmm3
    jmp     2f
1:  movsd   xmm2, [rsp]                 # x1 x2 + y1 y2
    mulsd   xmm2, [rsp+16]
    movsd   xmm3, [rsp+8]
    mulsd   xmm3, [rsp+24]
    addsd   xmm2, xmm3
2:  movsd   [rsp+32], xmm2
    movsd   xmm0, [rsp]
    movsd   xmm1, [rsp+8]
    call    len2
    movsd   [rsp+40], xmm0
    movsd   xmm0, [rsp+16]
    movsd   xmm1, [rsp+24]
    call    len2
    mulsd   xmm0, [rsp+40]
    maxsd   xmm0, [rip+sd_tiny]
    movsd   xmm1, [rsp+32]
    divsd   xmm1, xmm0
    movsd   xmm0, xmm1
    jmp     .Lr_out

.Lr_equal:                              # lengths or radii
    mov     eax, [r14+CN_A]
    imul    eax, eax, EN_SZ
    cmp     dword ptr [rbx+SK_ENTS+rax+EN_TYPE], E_LINE
    jne     1f
    mov     eax, [r14+CN_A]
    call    ldir
    call    len2
    movsd   [rsp], xmm0
    mov     eax, [r14+CN_B]
    call    ldir
    call    len2
    movsd   xmm1, [rsp]
    subsd   xmm1, xmm0
    movsd   xmm0, xmm1
    jmp     .Lr_out
1:  mov     eax, [r14+CN_A]
    call    entr
    movsd   [rsp], xmm0
    mov     eax, [r14+CN_B]
    call    entr
    movsd   xmm1, [rsp]
    subsd   xmm1, xmm0
    movsd   xmm0, xmm1
    jmp     .Lr_out

.Lr_tan:
    mov     eax, [r14+CN_A]             # (tangent_side put the line first)
    imul    eax, eax, EN_SZ
    cmp     dword ptr [rbx+SK_ENTS+rax+EN_TYPE], E_LINE
    jne     .Lr_tancc
    mov     eax, [r14+CN_A]             # line-circle: side * dist(c, line) - r
    call    ldir
    movsd   [rsp], xmm0
    movsd   [rsp+8], xmm1
    movsd   [rsp+16], xmm2
    movsd   [rsp+24], xmm3
    mov     eax, [r14+CN_B]
    xor     ecx, ecx
    call    entp
    call    pv
    subsd   xmm0, [rsp+16]
    subsd   xmm1, [rsp+24]
    mulsd   xmm1, [rsp]                 # cross(d, c - a)
    mulsd   xmm0, [rsp+8]
    subsd   xmm1, xmm0
    movsd   [rsp+32], xmm1
    movsd   xmm0, [rsp]
    movsd   xmm1, [rsp+8]
    call    len2
    maxsd   xmm0, [rip+sd_tiny]
    movsd   xmm1, [rsp+32]
    divsd   xmm1, xmm0
    mulsd   xmm1, [r14+CN_VAL2]
    movsd   [rsp+32], xmm1
    mov     eax, [r14+CN_B]
    call    entr
    movsd   xmm1, [rsp+32]
    subsd   xmm1, xmm0
    movsd   xmm0, xmm1
    jmp     .Lr_out
.Lr_tancc:                              # circles: |c1 c2| - (r1 + s r2)
    mov     eax, [r14+CN_A]
    xor     ecx, ecx
    call    entp
    call    pv
    movsd   [rsp], xmm0
    movsd   [rsp+8], xmm1
    mov     eax, [r14+CN_B]
    xor     ecx, ecx
    call    entp
    call    pv
    subsd   xmm0, [rsp]
    subsd   xmm1, [rsp+8]
    call    len2
    movsd   [rsp+16], xmm0
    mov     eax, [r14+CN_A]
    call    entr
    movsd   [rsp+24], xmm0
    mov     eax, [r14+CN_B]
    call    entr
    movsd   xmm1, [r14+CN_VAL2]         # outside: r1 + r2, inside: |r1 - r2|
    xorpd   xmm2, xmm2
    comisd  xmm1, xmm2
    jb      1f
    addsd   xmm0, [rsp+24]
    jmp     2f
1:  subsd   xmm0, [rsp+24]
    andpd   xmm0, [rip+sd_abs]
2:  movsd   xmm1, [rsp+16]
    subsd   xmm1, xmm0
    movsd   xmm0, xmm1
    jmp     .Lr_out

.Lr_fixed:
    mov     eax, [r14+CN_A]
    call    pv
    test    r13d, r13d
    jnz     1f
    subsd   xmm0, [r14+CN_VAL]
    jmp     .Lr_out
1:  movsd   xmm0, xmm1
    subsd   xmm0, [r14+CN_VAL2]
    jmp     .Lr_out

.Lr_dist:                               # |q - p| - d
.Lr_hdist:                              # qx - px - d
.Lr_vdist:                              # qy - py - d
    mov     eax, [r14+CN_A]
    call    pv
    movsd   [rsp], xmm0
    movsd   [rsp+8], xmm1
    mov     eax, [r14+CN_B]
    call    pv
    subsd   xmm0, [rsp]
    subsd   xmm1, [rsp+8]
    mov     eax, [r14+CN_TYPE]
    cmp     eax, C_HDIST
    je      1f
    cmp     eax, C_VDIST
    je      2f
    call    len2
    jmp     1f
2:  movsd   xmm0, xmm1
1:  subsd   xmm0, [rsp+96]
    jmp     .Lr_out

.Lr_len:                                # the line's length
    mov     eax, [r14+CN_A]
    call    ldir
    call    len2
    subsd   xmm0, [rsp+96]
    jmp     .Lr_out

.Lr_radius:
    mov     eax, [r14+CN_A]
    call    entr
    subsd   xmm0, [rsp+96]
    jmp     .Lr_out
.Lr_dia:
    mov     eax, [r14+CN_A]
    call    entr
    addsd   xmm0, xmm0
    subsd   xmm0, [rsp+96]
    jmp     .Lr_out

.Lr_angle:                              # atan2(cross, dot) - a, wrapped
    mov     eax, [r14+CN_A]
    call    ldir
    movsd   [rsp], xmm0
    movsd   [rsp+8], xmm1
    mov     eax, [r14+CN_B]
    call    ldir
    movsd   xmm2, [rsp]                 # cross
    mulsd   xmm2, xmm1
    movsd   xmm3, [rsp+8]
    mulsd   xmm3, xmm0
    subsd   xmm2, xmm3
    movsd   xmm3, [rsp]                 # dot
    mulsd   xmm3, xmm0
    movsd   xmm4, [rsp+8]
    mulsd   xmm4, xmm1
    addsd   xmm3, xmm4
    movsd   [rsp+16], xmm2
    movsd   [rsp+24], xmm3
    fld     qword ptr [rsp+16]
    fld     qword ptr [rsp+24]
    fpatan
    fstp    qword ptr [rsp+16]
    movsd   xmm0, [rsp+16]
    subsd   xmm0, [rsp+96]
    movsd   xmm1, [rip+sd_pi]           # into (-pi, pi]
1:  comisd  xmm0, xmm1
    jbe     2f
    subsd   xmm0, [rip+sd_2pi]
    jmp     1b
2:  movsd   xmm2, xmm1
    xorpd   xmm2, [rip+sd_sign]
3:  comisd  xmm0, xmm2
    ja      .Lr_out
    addsd   xmm0, [rip+sd_2pi]
    jmp     3b

.Lr_online:                             # cross(d, p - a) / |d|
    mov     eax, [r14+CN_B]
    call    ldir
    movsd   [rsp], xmm0
    movsd   [rsp+8], xmm1
    movsd   [rsp+16], xmm2
    movsd   [rsp+24], xmm3
    mov     eax, [r14+CN_A]
    call    pv
    subsd   xmm0, [rsp+16]
    subsd   xmm1, [rsp+24]
    mulsd   xmm1, [rsp]
    mulsd   xmm0, [rsp+8]
    subsd   xmm1, xmm0
    movsd   [rsp+32], xmm1
    movsd   xmm0, [rsp]
    movsd   xmm1, [rsp+8]
    call    len2
    maxsd   xmm0, [rip+sd_tiny]
    movsd   xmm1, [rsp+32]
    divsd   xmm1, xmm0
    movsd   xmm0, xmm1
    jmp     .Lr_out

.Lr_oncircle:                           # |p - c| - r
    mov     eax, [r14+CN_B]
    xor     ecx, ecx
    call    entp
    call    pv
    movsd   [rsp], xmm0
    movsd   [rsp+8], xmm1
    mov     eax, [r14+CN_A]
    call    pv
    subsd   xmm0, [rsp]
    subsd   xmm1, [rsp+8]
    call    len2
    movsd   [rsp], xmm0
    mov     eax, [r14+CN_B]
    call    entr
    movsd   xmm1, [rsp]
    subsd   xmm1, xmm0
    movsd   xmm0, xmm1
    jmp     .Lr_out

.Lr_mid:                                # p - (a + b) / 2
    mov     eax, [r14+CN_B]
    call    ldir
    mulsd   xmm0, [rip+sd_half]         # a + d / 2
    mulsd   xmm1, [rip+sd_half]
    addsd   xmm0, xmm2
    addsd   xmm1, xmm3
    movsd   [rsp], xmm0
    movsd   [rsp+8], xmm1
    mov     eax, [r14+CN_A]
    call    pv
    test    r13d, r13d
    jnz     1f
    subsd   xmm0, [rsp]
    jmp     .Lr_out
1:  movsd   xmm0, xmm1
    subsd   xmm0, [rsp+8]
    jmp     .Lr_out

.Lr_sym:                                # pa, pb about line c: the midpoint on
    mov     eax, [r14+CN_C]             #  it, pb - pa across it
    call    ldir
    movsd   [rsp], xmm0
    movsd   [rsp+8], xmm1
    movsd   [rsp+16], xmm2
    movsd   [rsp+24], xmm3
    mov     eax, [r14+CN_A]
    call    pv
    movsd   [rsp+32], xmm0
    movsd   [rsp+40], xmm1
    mov     eax, [r14+CN_B]
    call    pv
    movsd   [rsp+48], xmm0
    movsd   [rsp+56], xmm1
    test    r13d, r13d
    jnz     1f
    movsd   xmm0, [rsp+32]              # m = (pa + pb) / 2; cross(d, m - a)
    addsd   xmm0, [rsp+48]
    mulsd   xmm0, [rip+sd_half]
    subsd   xmm0, [rsp+16]
    movsd   xmm1, [rsp+40]
    addsd   xmm1, [rsp+56]
    mulsd   xmm1, [rip+sd_half]
    subsd   xmm1, [rsp+24]
    mulsd   xmm1, [rsp]
    mulsd   xmm0, [rsp+8]
    subsd   xmm1, xmm0
    movsd   xmm0, xmm1
    jmp     2f
1:  movsd   xmm0, [rsp+48]              # dot(pb - pa, d)
    subsd   xmm0, [rsp+32]
    mulsd   xmm0, [rsp]
    movsd   xmm1, [rsp+56]
    subsd   xmm1, [rsp+40]
    mulsd   xmm1, [rsp+8]
    addsd   xmm0, xmm1
2:  movsd   [rsp+64], xmm0
    movsd   xmm0, [rsp]
    movsd   xmm1, [rsp+8]
    call    len2
    maxsd   xmm0, [rip+sd_tiny]
    movsd   xmm1, [rsp+64]
    divsd   xmm1, xmm0
    movsd   xmm0, xmm1
.Lr_out:
    add     rsp, 112
    pop     r14
    pop     r13
    pop     r12
    ret

# =============================================================================
#  Setup: unknowns, equations, their unknowns, components
# =============================================================================
# addvar(edi=equation slot base pointer rdi, esi=var) - append
.macro ADDV n, reg
    mov     [r9+\n*4], \reg
.endm

# pvars(eax=point, r9=list, r10d=count) -> append 2 unknowns
pvars:
    lea     ecx, [rax+rax]
    mov     [r9+r10*4], ecx
    inc     ecx
    mov     [r9+r10*4+4], ecx
    add     r10d, 2
    ret

# evars(eax=entity, r9, r10d) - the entity's points (and radius)
evars:
    push    rax
    imul    ecx, eax, EN_SZ
    lea     r11, [rbx+SK_ENTS+rcx]
    mov     eax, [r11+EN_P0]
    call    pvars
    cmp     dword ptr [r11+EN_TYPE], E_LINE
    jne     1f
    mov     eax, [r11+EN_P1]
    call    pvars
    jmp     9f
1:  pop     rax                         # a circle / arc: its radius
    push    rax
    lea     rcx, [rip+sv_entvar]
    mov     ecx, [rcx+rax*4]
    mov     [r9+r10*4], ecx
    inc     r10d
9:  pop     rax
    ret

# eq_vars(edi=equation) - fill its unknown list (r9 = list base)
eq_vars:
    push    r12
    push    r14
    imul    eax, edi, 32
    lea     r9, [rip+sv_eqvars]
    add     r9, rax
    xor     r10d, r10d
    lea     rax, [rip+sv_eqc]
    mov     r12d, [rax+rdi*4]
    test    r12d, r12d
    jns     1f
    not     r12d                        # an arc: centre, the point, radius
    mov     eax, r12d
    imul    ecx, eax, EN_SZ
    lea     r11, [rbx+SK_ENTS+rcx]
    mov     eax, [r11+EN_P0]
    call    pvars
    lea     rcx, [rip+sv_eqk]
    movzx   ecx, byte ptr [rcx+rdi]
    mov     eax, [r11+EN_P1+rcx*4]
    call    pvars
    lea     rcx, [rip+sv_entvar]
    mov     eax, [rcx+r12*4]
    mov     [r9+r10*4], eax
    inc     r10d
    jmp     9f
1:  imul    eax, r12d, CN_SZ
    lea     r14, [rbx+SK_CONS+rax]
    mov     eax, [r14+CN_TYPE]
    # point refs: coincident, fixed, distance x3: a, b points; online,
    # oncircle, midpoint: a point, b entity; symmetric: a, b points, c line;
    # the rest: entities
    cmp     eax, C_COINCIDENT
    je      2f
    cmp     eax, C_DISTANCE
    je      2f
    cmp     eax, C_HDIST
    je      2f
    cmp     eax, C_VDIST
    je      2f
    cmp     eax, C_FIXED
    je      3f
    cmp     eax, C_ONLINE
    je      4f
    cmp     eax, C_ONCIRCLE
    je      4f
    cmp     eax, C_MIDPOINT
    je      4f
    cmp     eax, C_SYMMETRIC
    je      5f
    mov     eax, [r14+CN_A]             # entities a (and b)
    call    evars
    mov     eax, [r14+CN_TYPE]
    cmp     eax, C_HORIZONTAL
    je      9f
    cmp     eax, C_VERTICAL
    je      9f
    cmp     eax, C_RADIUS
    je      9f
    cmp     eax, C_DIAMETER
    je      9f
    cmp     eax, C_LENGTH
    je      9f
    mov     eax, [r14+CN_B]
    call    evars
    jmp     9f
2:  mov     eax, [r14+CN_A]
    call    pvars
    mov     eax, [r14+CN_B]
    call    pvars
    jmp     9f
3:  mov     eax, [r14+CN_A]
    call    pvars
    jmp     9f
4:  mov     eax, [r14+CN_A]
    call    pvars
    mov     eax, [r14+CN_B]
    call    evars
    jmp     9f
5:  mov     eax, [r14+CN_A]
    call    pvars
    mov     eax, [r14+CN_B]
    call    pvars
    mov     eax, [r14+CN_C]
    call    evars
9:  cmp     r10d, 8
    jae     91f
    mov     dword ptr [r9+r10*4], -1
91: pop     r14
    pop     r12
    ret

# find(edi) -> eax = root (path halving)
find:
    lea     rcx, [rip+sv_parent]
1:  mov     eax, [rcx+rdi*4]
    cmp     eax, edi
    je      2f
    mov     edx, [rcx+rax*4]
    mov     [rcx+rdi*4], edx
    mov     edi, edx
    jmp     1b
2:  ret

# check_refs(r14=constraint) -> eax = 1 if its references exist and fit
check_refs:
    mov     eax, [r14+CN_TYPE]
    mov     ecx, [r14+CN_A]
    mov     edx, [r14+CN_B]
    cmp     eax, C_FIXED
    je      1f
    cmp     eax, C_COINCIDENT
    je      2f
    cmp     eax, C_DISTANCE
    je      2f
    cmp     eax, C_HDIST
    je      2f
    cmp     eax, C_VDIST
    je      2f
    cmp     eax, C_SYMMETRIC
    je      3f
    cmp     eax, C_ONLINE
    je      4f
    cmp     eax, C_ONCIRCLE
    je      4f
    cmp     eax, C_MIDPOINT
    je      4f
    cmp     ecx, [rbx+SK_NENT]          # entity a
    jae     8f
    cmp     eax, C_HORIZONTAL
    je      5f
    cmp     eax, C_VERTICAL
    je      5f
    cmp     eax, C_LENGTH
    je      5f
    cmp     eax, C_RADIUS
    je      6f
    cmp     eax, C_DIAMETER
    je      6f
    cmp     edx, [rbx+SK_NENT]          # entity b
    jae     8f
    cmp     eax, C_EQUAL
    je      7f
    cmp     eax, C_TANGENT
    je      71f
    imul    ecx, ecx, EN_SZ             # parallel, perpendicular, angle: lines
    cmp     dword ptr [rbx+SK_ENTS+rcx+EN_TYPE], E_LINE
    jne     8f
    imul    edx, edx, EN_SZ
    cmp     dword ptr [rbx+SK_ENTS+rdx+EN_TYPE], E_LINE
    jne     8f
    jmp     9f
1:  cmp     ecx, [rbx+SK_NPT]
    jae     8f
    jmp     9f
2:  cmp     ecx, [rbx+SK_NPT]
    jae     8f
    cmp     edx, [rbx+SK_NPT]
    jae     8f
    jmp     9f
3:  cmp     ecx, [rbx+SK_NPT]
    jae     8f
    cmp     edx, [rbx+SK_NPT]
    jae     8f
    mov     ecx, [r14+CN_C]
    cmp     ecx, [rbx+SK_NENT]
    jae     8f
    jmp     5f
4:  cmp     ecx, [rbx+SK_NPT]           # point, entity
    jae     8f
    cmp     edx, [rbx+SK_NENT]
    jae     8f
    imul    edx, edx, EN_SZ
    mov     edx, [rbx+SK_ENTS+rdx+EN_TYPE]
    cmp     eax, C_ONCIRCLE
    je      41f
    cmp     edx, E_LINE
    jne     8f
    jmp     9f
41: cmp     edx, E_LINE
    je      8f
    jmp     9f
5:  imul    ecx, ecx, EN_SZ             # a line
    cmp     dword ptr [rbx+SK_ENTS+rcx+EN_TYPE], E_LINE
    jne     8f
    jmp     9f
6:  imul    ecx, ecx, EN_SZ             # a circle or arc
    cmp     dword ptr [rbx+SK_ENTS+rcx+EN_TYPE], E_LINE
    je      8f
    jmp     9f
7:  imul    ecx, ecx, EN_SZ             # equal: two lines or two round ones
    imul    edx, edx, EN_SZ
    mov     eax, [rbx+SK_ENTS+rcx+EN_TYPE]
    cmp     eax, E_LINE
    sete    al
    mov     ecx, [rbx+SK_ENTS+rdx+EN_TYPE]
    cmp     ecx, E_LINE
    sete    cl
    cmp     al, cl
    jne     8f
    jmp     9f
71: imul    ecx, ecx, EN_SZ             # tangent: not two lines
    imul    edx, edx, EN_SZ
    cmp     dword ptr [rbx+SK_ENTS+rcx+EN_TYPE], E_LINE
    jne     9f
    cmp     dword ptr [rbx+SK_ENTS+rdx+EN_TYPE], E_LINE
    je      8f
9:  mov     eax, 1
    ret
8:  xor     eax, eax
    ret

# setup -> builds unknowns and equations of sv_sk (rbx); eax = 0 if too big
setup:
    push    r12
    push    r13
    push    r14
    push    r15
    sub     rsp, 8
    xor     r12d, r12d                  # unknowns: points
    lea     r15, [rip+sv_x]
1:  cmp     r12d, [rbx+SK_NPT]
    jae     2f
    imul    eax, r12d, PT_SZ
    movsd   xmm0, [rbx+SK_PTS+rax+PT_X]
    movsd   xmm1, [rbx+SK_PTS+rax+PT_Y]
    mov     rcx, r12
    shl     rcx, 4
    movsd   [r15+rcx], xmm0
    movsd   [r15+rcx+8], xmm1
    inc     r12d
    jmp     1b
2:  lea     r13d, [r12+r12]             # radii
    xor     r12d, r12d
3:  cmp     r12d, [rbx+SK_NENT]
    jae     4f
    imul    eax, r12d, EN_SZ
    lea     rcx, [rip+sv_entvar]
    mov     dword ptr [rcx+r12*4], -1
    cmp     dword ptr [rbx+SK_ENTS+rax+EN_TYPE], E_LINE
    je      31f
    mov     [rcx+r12*4], r13d
    movsd   xmm0, [rbx+SK_ENTS+rax+EN_R]
    movsd   [r15+r13*8], xmm0
    inc     r13d
31: inc     r12d
    jmp     3b
4:  mov     [rip+sv_nv], r13d
    xor     r14d, r14d                  # equations: arcs
    xor     r12d, r12d
5:  cmp     r12d, [rbx+SK_NENT]
    jae     6f
    imul    eax, r12d, EN_SZ
    cmp     dword ptr [rbx+SK_ENTS+rax+EN_TYPE], E_ARC
    jne     51f
    mov     eax, r12d
    not     eax
    lea     rcx, [rip+sv_eqc]
    mov     [rcx+r14*4], eax
    mov     [rcx+r14*4+4], eax
    lea     rcx, [rip+sv_eqk]
    mov     byte ptr [rcx+r14], 0
    mov     byte ptr [rcx+r14+1], 1
    add     r14d, 2
51: inc     r12d
    jmp     5b
6:  xor     r12d, r12d                  # constraints
7:  cmp     r12d, [rbx+SK_NCON]
    jae     8f
    imul    eax, r12d, CN_SZ
    lea     rcx, [rbx+SK_CONS+rax]
    and     dword ptr [rcx+CN_FLAGS], ~F_BAD
    push    r14
    mov     r14, rcx
    call    check_refs
    mov     rcx, r14
    pop     r14
    test    eax, eax
    jz      78f
    movsd   xmm0, [rcx+CN_VAL]          # the value: its expression, if any
    cmp     byte ptr [rcx+CN_EXPR], 0
    je      71f
    push    rcx
    push    rcx
    lea     rdi, [rcx+CN_EXPR]
    call    expr_eval
    pop     rcx
    pop     rcx
    test    eax, eax
    jz      78f
    movsd   [rcx+CN_VAL], xmm0          # (keep the last good value)
71: mov     eax, [rcx+CN_TYPE]
    lea     rdx, [rip+con_neq]
    movzx   edx, byte ptr [rdx+rax]
    xor     r8d, r8d
72: cmp     r8d, edx
    jae     79f
    cmp     r14d, MAX_EQS
    jae     79f
    lea     rax, [rip+sv_eqc]
    mov     [rax+r14*4], r12d
    lea     rax, [rip+sv_eqk]
    mov     [rax+r14], r8b
    lea     rax, [rip+sv_eqval]
    movsd   [rax+r14*8], xmm0
    inc     r14d
    inc     r8d
    jmp     72b
78: or      dword ptr [rcx+CN_FLAGS], F_BAD # unusable: a conflict
79: inc     r12d
    jmp     7b
8:  mov     [rip+sv_neq], r14d
    xor     r12d, r12d                  # each equation's unknowns
81: cmp     r12d, r14d
    jae     82f
    mov     edi, r12d
    call    eq_vars
    inc     r12d
    jmp     81b
82: xor     ecx, ecx                    # components (union-find)
    lea     rax, [rip+sv_parent]
83: cmp     ecx, [rip+sv_nv]
    jae     84f
    mov     [rax+rcx*4], ecx
    inc     ecx
    jmp     83b
84: xor     r12d, r12d
85: cmp     r12d, [rip+sv_neq]
    jae     89f
    imul    eax, r12d, 32
    lea     r13, [rip+sv_eqvars]
    add     r13, rax
    mov     edi, [r13]
    call    find
    mov     r15d, eax
    mov     r9d, 1
86: cmp     r9d, 8
    jae     88f
    mov     edi, [r13+r9*4]
    test    edi, edi
    js      88f
    push    r9
    call    find
    pop     r9
    lea     rcx, [rip+sv_parent]
    mov     [rcx+rax*4], r15d
    inc     r9d
    jmp     86b
88: inc     r12d
    jmp     85b
89: xor     ecx, ecx
891:cmp     ecx, [rip+sv_nv]
    jae     892f
    push    rcx
    mov     edi, ecx
    call    find
    pop     rcx
    lea     rdx, [rip+sv_comp]
    mov     [rdx+rcx*4], eax
    inc     ecx
    jmp     891b
892:mov     eax, 1
    add     rsp, 8
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    ret

# =============================================================================
#  Solving one component
# =============================================================================
# comp_resid(rdi=out f[m]) - residuals of the component's equations
#   (r12d = equations in sv_ce)
comp_resid:
    push    r13
    push    r14
    push    rbp
    mov     r14, rdi
    xor     r13d, r13d
1:  cmp     r13d, r12d
    jae     9f
    lea     rax, [rip+sv_ce]
    mov     edi, [rax+r13*4]
    call    resid
    movsd   [r14+r13*8], xmm0
    inc     r13d
    jmp     1b
9:  pop     rbp
    pop     r14
    pop     r13
    ret

# sumsq(rdi=f, ecx=m) -> xmm0
sumsq:
    xorpd   xmm0, xmm0
1:  test    ecx, ecx
    jz      9f
    dec     ecx
    movsd   xmm1, [rdi+rcx*8]
    mulsd   xmm1, xmm1
    addsd   xmm0, xmm1
    jmp     1b
9:  ret

# solve_comp(edi=component root) - LM on its unknowns; marks free unknowns
#   (sv_free) and leaves the equations' residuals in sv_f
solve_comp:
    push    r12
    push    r13
    push    r14
    push    rbp
    sub     rsp, 72
    mov     [rsp+64], edi
    xor     r13d, r13d                  # n: unknowns
    xor     ecx, ecx
1:  cmp     ecx, [rip+sv_nv]
    jae     2f
    lea     rax, [rip+sv_comp]
    cmp     [rax+rcx*4], edi
    jne     11f
    lea     rax, [rip+sv_cv]
    mov     [rax+r13*4], ecx
    inc     r13d
11: inc     ecx
    jmp     1b
2:  xor     r12d, r12d                  # m: equations
    xor     ecx, ecx
3:  cmp     ecx, [rip+sv_neq]
    jae     4f
    imul    eax, ecx, 32
    lea     rdx, [rip+sv_eqvars]
    mov     eax, [rdx+rax]
    lea     rdx, [rip+sv_comp]
    cmp     [rdx+rax*4], edi
    jne     31f
    lea     rax, [rip+sv_ce]
    mov     [rax+r12*4], ecx
    inc     r12d
31: inc     ecx
    jmp     3b
4:  mov     [rsp+56], r13d
    test    r12d, r12d                  # no equations: all free
    jz      .Lsc_allfree
    # scratch: J (m n), A (n n), M (n n), g (n), d (n), x0 (n)
    mov     eax, r12d
    imul    eax, r13d
    mov     ecx, r13d
    imul    ecx, r13d
    lea     eax, [rax+rcx*2]
    lea     eax, [rax+r13*4+16]
    shl     rax, 3
    cmp     rax, [rip+sv_matsz]
    jbe     5f
    push    rax
    mov     rdi, [rip+sv_mat]
    mov     rsi, [rip+sv_matsz]
    call    vunmap
    pop     rdi
    push    rdi
    call    vmap
    pop     rcx
    mov     [rip+sv_mat], rax
    mov     [rip+sv_matsz], rcx
    test    rax, rax
    jnz     5f
    mov     qword ptr [rip+sv_matsz], 0
    jmp     .Lsc_out
5:  mov     rbp, [rip+sv_mat]           # J
    mov     eax, r12d
    imul    eax, r13d
    lea     rax, [rbp+rax*8]
    mov     [rsp], rax                  # A
    mov     ecx, r13d
    imul    ecx, r13d
    lea     rax, [rax+rcx*8]
    mov     [rsp+48], rax               # M (the factor)
    lea     rax, [rax+rcx*8]
    mov     [rsp+8], rax                # g
    lea     rax, [rax+r13*8]
    mov     [rsp+16], rax               # d
    lea     rax, [rax+r13*8]
    mov     [rsp+24], rax               # x0
    movsd   xmm0, [rip+sd_lam0]
    movsd   [rsp+32], xmm0              # lambda
    mov     dword ptr [rsp+60], 0       # iterations
    lea     rdi, [rip+sv_f]
    call    comp_resid
    lea     rdi, [rip+sv_f]
    mov     ecx, r12d
    call    sumsq
    movsd   [rsp+40], xmm0              # cost
.Lsc_iter:
    movsd   xmm0, [rsp+40]              # converged?
    movsd   xmm1, [rip+sd_tol]
    mulsd   xmm1, [rip+sv_scale]
    mulsd   xmm1, xmm1
    comisd  xmm0, xmm1
    jbe     .Lsc_rank
    cmp     dword ptr [rsp+60], MAX_ITER
    jae     .Lsc_rank
    inc     dword ptr [rsp+60]
    call    jacobian
    call    normal_eq                   # A = J^T J, g = J^T f
.Lsc_try:
    call    lm_step                     # d from (A + lambda diag) d = -g
    test    eax, eax
    jz      .Lsc_worse
    lea     rcx, [rip+sv_x]             # x0 = x; x += d
    xor     r14d, r14d
6:  cmp     r14d, r13d
    jae     7f
    lea     rax, [rip+sv_cv]
    mov     eax, [rax+r14*4]
    movsd   xmm0, [rcx+rax*8]
    mov     rdx, [rsp+24]
    movsd   [rdx+r14*8], xmm0
    mov     rdx, [rsp+16]
    addsd   xmm0, [rdx+r14*8]
    movsd   [rcx+rax*8], xmm0
    inc     r14d
    jmp     6b
7:  lea     rdi, [rip+sv_f2]
    call    comp_resid
    lea     rdi, [rip+sv_f2]
    mov     ecx, r12d
    call    sumsq
    comisd  xmm0, [rsp+40]
    jae     .Lsc_undo
    movsd   [rsp+40], xmm0              # better: keep, lambda down
    lea     rsi, [rip+sv_f2]
    lea     rdi, [rip+sv_f]
    mov     ecx, r12d
    rep     movsq
    movsd   xmm0, [rsp+32]
    mulsd   xmm0, [rip+sd_down]
    movsd   [rsp+32], xmm0
    jmp     .Lsc_iter
.Lsc_undo:
    lea     rcx, [rip+sv_x]             # worse: back, lambda up
    xor     r14d, r14d
8:  cmp     r14d, r13d
    jae     .Lsc_worse
    lea     rax, [rip+sv_cv]
    mov     eax, [rax+r14*4]
    mov     rdx, [rsp+24]
    movsd   xmm0, [rdx+r14*8]
    movsd   [rcx+rax*8], xmm0
    inc     r14d
    jmp     8b
.Lsc_worse:
    movsd   xmm0, [rsp+32]
    mulsd   xmm0, [rip+sd_up]
    movsd   [rsp+32], xmm0
    comisd  xmm0, [rip+sd_lmax]
    ja      .Lsc_rank
    inc     dword ptr [rsp+60]
    cmp     dword ptr [rsp+60], MAX_ITER*2
    jae     .Lsc_rank
    jmp     .Lsc_try
.Lsc_rank:
    call    jacobian                    # rank and null space at the result
    call    rank_free
    jmp     .Lsc_out
.Lsc_allfree:
    xor     ecx, ecx
1:  cmp     ecx, r13d
    jae     .Lsc_out2
    lea     rax, [rip+sv_cv]
    mov     eax, [rax+rcx*4]
    lea     rdx, [rip+sv_free]
    mov     byte ptr [rdx+rax], 1
    inc     ecx
    jmp     1b
.Lsc_out2:
    add     [rip+sv_dof], r13d
.Lsc_out:
    add     rsp, 72
    pop     rbp
    pop     r14
    pop     r13
    pop     r12
    ret

# jacobian - J[i][j] = d f_i / d x_j by forward differences (solve_comp's
#   frame one level up: rbp = J, r12d = m, r13d = n; sv_f holds f)
jacobian:
    push    r14
    push    r15
    sub     rsp, 24
    lea     r15, [rip+sv_x]
    xor     r14d, r14d
1:  cmp     r14d, r13d
    jae     9f
    lea     rax, [rip+sv_cv]
    mov     eax, [rax+r14*4]
    mov     [rsp+16], eax
    movsd   xmm0, [r15+rax*8]
    movsd   [rsp], xmm0
    movsd   xmm1, xmm0                  # h = 1e-7 (1 + |x|)
    andpd   xmm1, [rip+sd_abs]
    addsd   xmm1, [rip+sd_one]
    mulsd   xmm1, [rip+sd_h]
    movsd   [rsp+8], xmm1
    addsd   xmm0, xmm1
    movsd   [r15+rax*8], xmm0
    lea     rdi, [rip+sv_f2]
    call    comp_resid
    mov     eax, [rsp+16]
    movsd   xmm0, [rsp]
    movsd   [r15+rax*8], xmm0
    xor     ecx, ecx                    # column j
2:  cmp     ecx, r12d
    jae     3f
    lea     rax, [rip+sv_f2]
    movsd   xmm0, [rax+rcx*8]
    lea     rax, [rip+sv_f]
    subsd   xmm0, [rax+rcx*8]
    divsd   xmm0, [rsp+8]
    mov     eax, ecx
    imul    eax, r13d
    add     eax, r14d
    movsd   [rbp+rax*8], xmm0
    inc     ecx
    jmp     2b
3:  inc     r14d
    jmp     1b
9:  lea     rdi, [rip+sv_f]             # (sv_f as it was)
    add     rsp, 24
    pop     r15
    pop     r14
    ret

# normal_eq - A = J^T J, g = J^T f (solve_comp frame: [rsp+8+..])
normal_eq:
    mov     r8, [rsp+8]                 # A
    mov     r9, [rsp+8+8]               # g
    xor     ecx, ecx                    # row a
1:  cmp     ecx, r13d
    jae     9f
    xor     edx, edx                    # column b
2:  cmp     edx, r13d
    jae     4f
    xorpd   xmm0, xmm0
    xor     r10d, r10d
3:  cmp     r10d, r12d
    jae     31f
    mov     eax, r10d
    imul    eax, r13d
    lea     r11d, [rax+rcx]
    movsd   xmm1, [rbp+r11*8]
    lea     r11d, [rax+rdx]
    mulsd   xmm1, [rbp+r11*8]
    addsd   xmm0, xmm1
    inc     r10d
    jmp     3b
31: mov     eax, ecx
    imul    eax, r13d
    add     eax, edx
    movsd   [r8+rax*8], xmm0
    inc     edx
    jmp     2b
4:  xorpd   xmm0, xmm0                  # g_a
    xor     r10d, r10d
    lea     r11, [rip+sv_f]
5:  cmp     r10d, r12d
    jae     51f
    mov     eax, r10d
    imul    eax, r13d
    add     eax, ecx
    movsd   xmm1, [rbp+rax*8]
    mulsd   xmm1, [r11+r10*8]
    addsd   xmm0, xmm1
    inc     r10d
    jmp     5b
51: movsd   [r9+rcx*8], xmm0
    inc     ecx
    jmp     1b
9:  ret

# lm_step -> eax = 1: d (n) from (A + lambda diag(A) + mu) d = -g by
#   Cholesky on a copy (solve_comp frame)
lm_step:
    push    r14
    push    r15
    sub     rsp, 8
    mov     r8, [rsp+24+8]              # A
    mov     r9, [rsp+24+16]             # g
    mov     r10, [rsp+24+24]            # d (the solution)
    mov     r11, [rsp+24+32]            # x0 (scratch: the factor's diagonal)
    mov     r14, [rsp+24+56]            # M
1:  xor     ecx, ecx                    # M = A + lambda diag + mu
2:  cmp     ecx, r13d
    jae     4f
    xor     edx, edx
3:  cmp     edx, r13d
    jae     31f
    mov     eax, ecx
    imul    eax, r13d
    add     eax, edx
    movsd   xmm0, [r8+rax*8]
    cmp     ecx, edx
    jne     32f
    movsd   xmm1, xmm0
    mulsd   xmm1, [rsp+24+40]           # lambda
    addsd   xmm0, xmm1
    addsd   xmm0, [rip+sd_mu]
32: movsd   [r14+rax*8], xmm0
    inc     edx
    jmp     3b
31: inc     ecx
    jmp     2b
4:  xor     ecx, ecx                    # Cholesky: M = L L^T (lower, in place)
5:  cmp     ecx, r13d
    jae     8f
    xor     edx, edx                    # j <= i
6:  cmp     edx, ecx
    ja      7f
    mov     eax, ecx                    # s = M[i][j] - sum_k L[i][k] L[j][k]
    imul    eax, r13d
    add     eax, edx
    movsd   xmm0, [r14+rax*8]
    xor     r15d, r15d
61: cmp     r15d, edx
    jae     62f
    mov     eax, ecx
    imul    eax, r13d
    add     eax, r15d
    movsd   xmm1, [r14+rax*8]
    mov     eax, edx
    imul    eax, r13d
    add     eax, r15d
    mulsd   xmm1, [r14+rax*8]
    subsd   xmm0, xmm1
    inc     r15d
    jmp     61b
62: cmp     ecx, edx
    jne     63f
    xorpd   xmm1, xmm1                  # the diagonal
    comisd  xmm0, xmm1
    jbe     .Lls_fail
    sqrtsd  xmm0, xmm0
    jmp     64f
63: mov     eax, edx                    # / L[j][j]
    imul    eax, r13d
    add     eax, edx
    divsd   xmm0, [r14+rax*8]
64: mov     eax, ecx
    imul    eax, r13d
    add     eax, edx
    movsd   [r14+rax*8], xmm0
    inc     edx
    jmp     6b
7:  inc     ecx
    jmp     5b
8:  xor     ecx, ecx                    # forward: L y = -g (y into d)
81: cmp     ecx, r13d
    jae     84f
    movsd   xmm0, [r9+rcx*8]
    xorpd   xmm0, [rip+sd_sign]
    xor     edx, edx
82: cmp     edx, ecx
    jae     83f
    mov     eax, ecx
    imul    eax, r13d
    add     eax, edx
    movsd   xmm1, [r14+rax*8]
    mulsd   xmm1, [r10+rdx*8]
    subsd   xmm0, xmm1
    inc     edx
    jmp     82b
83: mov     eax, ecx
    imul    eax, r13d
    add     eax, ecx
    divsd   xmm0, [r14+rax*8]
    movsd   [r10+rcx*8], xmm0
    inc     ecx
    jmp     81b
84: mov     ecx, r13d                   # back: L^T d = y
85: dec     ecx
    js      89f
    movsd   xmm0, [r10+rcx*8]
    lea     edx, [rcx+1]
86: cmp     edx, r13d
    jae     87f
    mov     eax, edx
    imul    eax, r13d
    add     eax, ecx
    movsd   xmm1, [r14+rax*8]
    mulsd   xmm1, [r10+rdx*8]
    subsd   xmm0, xmm1
    inc     edx
    jmp     86b
87: mov     eax, ecx
    imul    eax, r13d
    add     eax, ecx
    divsd   xmm0, [r14+rax*8]
    movsd   [r10+rcx*8], xmm0
    jmp     85b
89: mov     eax, 1
    jmp     9f
.Lls_fail:
    xor     eax, eax
9:  add     rsp, 8
    pop     r15
    pop     r14
    ret

# rank_free - row-reduce J (m x n, in place) to find the pivot columns; the
#   unknowns that some null-space vector moves are free; DOF += n - rank
rank_free:
    push    r14
    push    r15
    push    rbx
    sub     rsp, 48
    mov     dword ptr [rsp], 0          # rank (= next pivot row)
    xor     r14d, r14d                  # column
    mov     r15, [rsp+104]              # x0 area: pivot row per column (-1)
    # tolerance: relative to the largest entry
    xorpd   xmm7, xmm7
    mov     eax, r12d
    imul    eax, r13d
    xor     ecx, ecx
1:  cmp     ecx, eax
    jae     2f
    movsd   xmm0, [rbp+rcx*8]
    andpd   xmm0, [rip+sd_abs]
    maxsd   xmm7, xmm0
    inc     ecx
    jmp     1b
2:  mulsd   xmm7, [rip+sd_rank]
    addsd   xmm7, [rip+sd_tiny]
    movsd   [rsp+8], xmm7
.Lrf_col:
    cmp     r14d, r13d
    jae     .Lrf_null
    mov     dword ptr [r15+r14*4], -1
    mov     ebx, [rsp]                  # the best pivot below the rank
    cmp     ebx, r12d
    jae     .Lrf_next
    mov     ecx, ebx
    mov     r8d, -1
    xorpd   xmm6, xmm6
3:  cmp     ecx, r12d
    jae     4f
    mov     eax, ecx
    imul    eax, r13d
    add     eax, r14d
    movsd   xmm0, [rbp+rax*8]
    andpd   xmm0, [rip+sd_abs]
    comisd  xmm0, xmm6
    jbe     31f
    movsd   xmm6, xmm0
    mov     r8d, ecx
31: inc     ecx
    jmp     3b
4:  comisd  xmm6, [rsp+8]
    jbe     .Lrf_next                   # no pivot: a free column
    cmp     r8d, ebx                    # swap rows ebx, r8d
    je      5f
    xor     ecx, ecx
41: cmp     ecx, r13d
    jae     5f
    mov     eax, ebx
    imul    eax, r13d
    add     eax, ecx
    mov     edx, r8d
    imul    edx, r13d
    add     edx, ecx
    movsd   xmm0, [rbp+rax*8]
    movsd   xmm1, [rbp+rdx*8]
    movsd   [rbp+rax*8], xmm1
    movsd   [rbp+rdx*8], xmm0
    inc     ecx
    jmp     41b
5:  mov     [r15+r14*4], ebx            # normalise the pivot row, clear the
    mov     eax, ebx                    #  column in every other row
    imul    eax, r13d
    add     eax, r14d
    movsd   xmm5, [rbp+rax*8]
    xor     ecx, ecx
51: cmp     ecx, r13d
    jae     52f
    mov     eax, ebx
    imul    eax, r13d
    add     eax, ecx
    movsd   xmm0, [rbp+rax*8]
    divsd   xmm0, xmm5
    movsd   [rbp+rax*8], xmm0
    inc     ecx
    jmp     51b
52: xor     ecx, ecx                    # row r
53: cmp     ecx, r12d
    jae     56f
    cmp     ecx, ebx
    je      55f
    mov     eax, ecx
    imul    eax, r13d
    add     eax, r14d
    movsd   xmm4, [rbp+rax*8]           # factor
    xorpd   xmm0, xmm0
    ucomisd xmm4, xmm0
    je      55f
    xor     edx, edx
54: cmp     edx, r13d
    jae     55f
    mov     eax, ebx
    imul    eax, r13d
    add     eax, edx
    movsd   xmm0, [rbp+rax*8]
    mulsd   xmm0, xmm4
    mov     eax, ecx
    imul    eax, r13d
    add     eax, edx
    movsd   xmm1, [rbp+rax*8]
    subsd   xmm1, xmm0
    movsd   [rbp+rax*8], xmm1
    inc     edx
    jmp     54b
55: inc     ecx
    jmp     53b
56: inc     dword ptr [rsp]
.Lrf_next:
    inc     r14d
    jmp     .Lrf_col
.Lrf_null:
    mov     eax, r13d                   # DOF += n - rank
    sub     eax, [rsp]
    add     [rip+sv_dof], eax
    # free unknowns: a free column f moves itself and, through the reduced
    # rows, every pivot unknown whose row has a nonzero entry in f
    xor     r14d, r14d
6:  cmp     r14d, r13d
    jae     9f
    cmp     dword ptr [r15+r14*4], -1
    jne     8f
    lea     rax, [rip+sv_cv]            # f itself
    mov     eax, [rax+r14*4]
    lea     rdx, [rip+sv_free]
    mov     byte ptr [rdx+rax], 1
    xor     ecx, ecx                    # pivot columns c with R[row(c)][f] != 0
7:  cmp     ecx, r13d
    jae     8f
    mov     ebx, [r15+rcx*4]
    test    ebx, ebx
    js      71f
    mov     eax, ebx
    imul    eax, r13d
    add     eax, r14d
    movsd   xmm0, [rbp+rax*8]
    andpd   xmm0, [rip+sd_abs]
    comisd  xmm0, [rip+sd_null]
    jbe     71f
    lea     rax, [rip+sv_cv]
    mov     eax, [rax+rcx*4]
    lea     rdx, [rip+sv_free]
    mov     byte ptr [rdx+rax], 1
71: inc     ecx
    jmp     7b
8:  inc     r14d
    jmp     6b
9:  add     rsp, 48
    pop     rbx
    pop     r15
    pop     r14
    ret

# =============================================================================
#  sk_solve(rdi=sketch) -> eax = DOF left (SK_DOF), SK_NBAD conflicts; the
#   sketch's points, radii and status flags are updated
# =============================================================================
sk_solve:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    sub     rsp, 16
    mov     rbx, rdi
    mov     [rip+sv_sk], rbx
    call    setup
    mov     dword ptr [rip+sv_dof], 0
    lea     rdi, [rip+sv_free]
    xor     eax, eax
    mov     ecx, MAX_VARS
    rep     stosb
    lea     r15, [rip+sv_x]
    movsd   xmm0, [rip+sd_one]          # scale: 1 + the largest coordinate
    xor     ecx, ecx
1:  cmp     ecx, [rip+sv_nv]
    jae     2f
    movsd   xmm1, [r15+rcx*8]
    andpd   xmm1, [rip+sd_abs]
    maxsd   xmm0, xmm1
    inc     ecx
    jmp     1b
2:  movsd   [rip+sv_scale], xmm0
    xor     r14d, r14d                  # each component once (at its root)
3:  cmp     r14d, [rip+sv_nv]
    jae     4f
    lea     rax, [rip+sv_comp]
    cmp     [rax+r14*4], r14d
    jne     31f
    mov     edi, r14d
    call    solve_comp
31: inc     r14d
    jmp     3b
4:  call    mark_bad                    # equations still unsatisfied
    xor     ecx, ecx                    # write back: points
5:  cmp     ecx, [rbx+SK_NPT]
    jae     6f
    imul    eax, ecx, PT_SZ
    mov     rdx, rcx
    shl     rdx, 4
    movsd   xmm0, [r15+rdx]
    movsd   [rbx+SK_PTS+rax+PT_X], xmm0
    movsd   xmm0, [r15+rdx+8]
    movsd   [rbx+SK_PTS+rax+PT_Y], xmm0
    and     dword ptr [rbx+SK_PTS+rax+PT_FLAGS], ~F_FULL  # fully constrained:
    lea     rdx, [rip+sv_free]                          #  neither x nor y free
    mov     r8w, [rdx+rcx*2]
    test    r8w, r8w
    jnz     51f
    or      dword ptr [rbx+SK_PTS+rax+PT_FLAGS], F_FULL
51: inc     ecx
    jmp     5b
6:  xor     ecx, ecx                    # radii, entity status
61: cmp     ecx, [rbx+SK_NENT]
    jae     7f
    imul    eax, ecx, EN_SZ
    lea     r8, [rbx+SK_ENTS+rax]
    and     dword ptr [r8+EN_FLAGS], ~F_FULL
    mov     edx, F_FULL                 # all its points full (and radius)
    mov     eax, [r8+EN_P0]
    call    pfull
    and     edx, eax
    cmp     dword ptr [r8+EN_TYPE], E_CIRCLE
    je      62f
    mov     eax, [r8+EN_P1]
    call    pfull
    and     edx, eax
    cmp     dword ptr [r8+EN_TYPE], E_LINE
    je      63f
    mov     eax, [r8+EN_P2]
    call    pfull
    and     edx, eax
62: lea     rax, [rip+sv_entvar]        # radius
    mov     eax, [rax+rcx*4]
    movsd   xmm0, [r15+rax*8]
    movsd   [r8+EN_R], xmm0
    lea     r9, [rip+sv_free]
    cmp     byte ptr [r9+rax], 0
    je      63f
    xor     edx, edx
63: or      [r8+EN_FLAGS], edx
    inc     ecx
    jmp     61b
7:  mov     eax, [rip+sv_dof]           # conflicts
    mov     [rbx+SK_DOF], eax
    xor     edx, edx
    xor     ecx, ecx
71: cmp     ecx, [rbx+SK_NCON]
    jae     72f
    imul    eax, ecx, CN_SZ
    test    dword ptr [rbx+SK_CONS+rax+CN_FLAGS], F_BAD
    jz      711f
    inc     edx
711:inc     ecx
    jmp     71b
72: mov     [rbx+SK_NBAD], edx
    mov     eax, [rbx+SK_DOF]
    add     rsp, 16
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# pfull(eax=point) -> eax = F_FULL or 0 (rbx = sketch, from sv_free)
pfull:
    push    rcx
    lea     rcx, [rip+sv_free]
    mov     ax, [rcx+rax*2]
    test    ax, ax
    mov     eax, F_FULL
    jz      1f
    xor     eax, eax
1:  pop     rcx
    ret

# mark_bad - after the solve: equations whose residual stayed are conflicts
mark_bad:
    push    r12
    push    r13
    sub     rsp, 8
    lea     r15, [rip+sv_x]
    xor     r12d, r12d
1:  cmp     r12d, [rip+sv_neq]
    jae     9f
    mov     edi, r12d
    call    resid
    andpd   xmm0, [rip+sd_abs]
    movsd   xmm1, [rip+sd_tol]
    mulsd   xmm1, [rip+sv_scale]
    mulsd   xmm1, [rip+sd_up]           # (a little slack)
    mulsd   xmm1, [rip+sd_up]
    comisd  xmm0, xmm1
    jbe     2f
    lea     rax, [rip+sv_eqc]
    mov     eax, [rax+r12*4]
    test    eax, eax
    js      2f
    imul    eax, eax, CN_SZ
    or      dword ptr [rbx+SK_CONS+rax+CN_FLAGS], F_BAD
2:  inc     r12d
    jmp     1b
9:  add     rsp, 8
    pop     r13
    pop     r12
    ret

# =============================================================================
#  Deleting: entities (rdi mask), then whatever referred to them, then points
#  nothing uses any more; indices are compacted
# =============================================================================
.section .bss
dl_ent:         .skip MAX_ENT           # 1: delete (in), new index + 1 (out)
dl_pt:          .skip 4*MAX_PT          # new index of each point, -1 = gone
.text

# sk_drop_con(rdi=sketch, esi=constraint) - remove one constraint
sk_drop_con:
    cmp     esi, [rdi+SK_NCON]
    jae     9f
    mov     ecx, [rdi+SK_NCON]
    sub     ecx, esi
    dec     ecx
    imul    ecx, ecx, CN_SZ
    imul    eax, esi, CN_SZ
    push    rdi
    lea     rsi, [rdi+SK_CONS+rax+CN_SZ]
    lea     rdi, [rdi+SK_CONS+rax]
    rep     movsb
    pop     rdi
    dec     dword ptr [rdi+SK_NCON]
9:  ret

# sk_delete(rdi=sketch, rsi=u8[MAX_ENT] mask of entities to delete, edx=
#   also delete these points: rcx = u8[MAX_PT] mask or 0)
sk_delete:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    mov     rbx, rdi
    mov     r13, rcx                    # point mask (or 0)
    lea     rdi, [rip+dl_ent]           # take the entity mask
    mov     ecx, MAX_ENT
    rep     movsb
    # points to drop: requested ones, and the entities going away with them
    lea     rdi, [rip+dl_pt]
    mov     eax, -1                     # -1: kept
    mov     ecx, MAX_PT
    rep     stosd
    xor     ecx, ecx                    # points of deleted entities: -2
101:cmp     ecx, [rbx+SK_NENT]
    jae     103f
    lea     rax, [rip+dl_ent]
    cmp     byte ptr [rax+rcx], 0
    je      102f
    imul    eax, ecx, EN_SZ
    lea     rdx, [rbx+SK_ENTS+rax]
    lea     r8, [rip+dl_pt]
    mov     eax, [rdx+EN_P0]
    call    mark_gone
    mov     eax, [rdx+EN_P1]
    call    mark_gone
    mov     eax, [rdx+EN_P2]
    call    mark_gone
102:inc     ecx
    jmp     101b
103:xor     ecx, ecx                    # unless a surviving entity uses them
1:  cmp     ecx, [rbx+SK_NENT]
    jae     3f
    lea     rax, [rip+dl_ent]
    cmp     byte ptr [rax+rcx], 0
    jne     2f
    imul    eax, ecx, EN_SZ
    lea     rdx, [rbx+SK_ENTS+rax]
    lea     r8, [rip+dl_pt]
    mov     eax, [rdx+EN_P0]
    call    mark_used
    mov     eax, [rdx+EN_P1]
    call    mark_used
    mov     eax, [rdx+EN_P2]
    call    mark_used
2:  inc     ecx
    jmp     1b
3:  test    r13, r13                    # requested points go anyway
    jz      4f
    xor     ecx, ecx
31: cmp     ecx, [rbx+SK_NPT]
    jae     4f
    cmp     byte ptr [r13+rcx], 0
    je      32f
    lea     rax, [rip+dl_pt]
    mov     dword ptr [rax+rcx*4], -2
32: inc     ecx
    jmp     31b
4:  # constraints: drop those touching deleted entities or dropped points
    xor     r12d, r12d
41: cmp     r12d, [rbx+SK_NCON]
    jae     5f
    imul    eax, r12d, CN_SZ
    lea     r14, [rbx+SK_CONS+rax]
    call    con_refs_gone
    test    eax, eax
    jz      42f
    mov     rdi, rbx
    mov     esi, r12d
    call    sk_drop_con
    jmp     41b
42: inc     r12d
    jmp     41b
5:  # new point indices (used ones, or ones a constraint still names)
    xor     ecx, ecx
    xor     edx, edx
    lea     r8, [rip+dl_pt]
51: cmp     ecx, [rbx+SK_NPT]
    jae     52f
    cmp     dword ptr [r8+rcx*4], -1
    jne     511f
    mov     [r8+rcx*4], edx             # kept: compact
    imul    eax, ecx, PT_SZ
    imul    r9d, edx, PT_SZ
    mov     r10, [rbx+SK_PTS+rax]
    mov     [rbx+SK_PTS+r9], r10
    mov     r10, [rbx+SK_PTS+rax+8]
    mov     [rbx+SK_PTS+r9+8], r10
    mov     r10, [rbx+SK_PTS+rax+16]
    mov     [rbx+SK_PTS+r9+16], r10
    inc     edx
    jmp     512f
511:mov     dword ptr [r8+rcx*4], -1
512:inc     ecx
    jmp     51b
52: mov     [rbx+SK_NPT], edx
    xor     ecx, ecx                    # entities: compact, renumber points
    xor     edx, edx
    lea     r9, [rip+dl_ent]
53: cmp     ecx, [rbx+SK_NENT]
    jae     55f
    cmp     byte ptr [r9+rcx], 0
    jne     54f
    lea     eax, [rdx+1]
    mov     [r9+rcx], al                # new index + 1 (fits: < 256)
    imul    eax, ecx, EN_SZ
    imul    r10d, edx, EN_SZ
    lea     rsi, [rbx+SK_ENTS+rax]
    lea     rdi, [rbx+SK_ENTS+r10]
    push    rcx
    mov     ecx, EN_SZ
    rep     movsb
    pop     rcx
    sub     rdi, EN_SZ
    mov     eax, [rdi+EN_P0]
    call    renum_pt
    mov     [rdi+EN_P0], eax
    mov     eax, [rdi+EN_P1]
    call    renum_pt
    mov     [rdi+EN_P1], eax
    mov     eax, [rdi+EN_P2]
    call    renum_pt
    mov     [rdi+EN_P2], eax
    inc     edx
    jmp     541f
54: mov     byte ptr [r9+rcx], 0
541:inc     ecx
    jmp     53b
55: mov     [rbx+SK_NENT], edx
    xor     r12d, r12d                  # constraints: renumber their refs
56: cmp     r12d, [rbx+SK_NCON]
    jae     9f
    imul    eax, r12d, CN_SZ
    lea     r14, [rbx+SK_CONS+rax]
    call    con_renum
    inc     r12d
    jmp     56b
9:  pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# mark_gone(eax=point or -1; r8 = dl_pt)
mark_gone:
    test    eax, eax
    js      1f
    mov     dword ptr [r8+rax*4], -2
1:  ret

# mark_used(eax=point or -1; r8 = dl_pt)
mark_used:
    test    eax, eax
    js      1f
    mov     dword ptr [r8+rax*4], -1
1:  ret

# renum_pt(eax=old or -1) -> eax = new (dl_pt), -1 stays
renum_pt:
    test    eax, eax
    js      1f
    lea     r10, [rip+dl_pt]
    mov     eax, [r10+rax*4]
1:  ret

# ref kinds per constraint type: 1 = point, 2 = entity, 0 = unused (a b c)
.section .rodata
con_kinds:      .byte 0,0,0, 1,1,0, 2,0,0, 2,0,0, 2,2,0, 2,2,0, 2,2,0, 2,2,0
                .byte 1,0,0, 1,1,0, 1,1,0, 1,1,0, 2,0,0, 2,2,0, 1,2,0, 1,2,0
                .byte 1,2,0, 1,1,2, 2,0,0, 2,0,0
.text

# con_refs_gone(r14=constraint) -> eax = 1 if it names a deleted entity or a
#   dropped point (-2 in dl_pt)
con_refs_gone:
    mov     eax, [r14+CN_TYPE]
    lea     r10, [rax+rax*2]
    lea     r11, [rip+con_kinds]
    add     r10, r11
    xor     ecx, ecx
1:  cmp     ecx, 3
    jae     8f
    movzx   edx, byte ptr [r10+rcx]
    mov     eax, [r14+CN_A+rcx*4]
    cmp     edx, 1
    jne     2f
    cmp     eax, [rbx+SK_NPT]
    jae     7f
    lea     r11, [rip+dl_pt]
    cmp     dword ptr [r11+rax*4], -2
    je      7f
    jmp     3f
2:  cmp     edx, 2
    jne     3f
    cmp     eax, [rbx+SK_NENT]
    jae     7f
    lea     r11, [rip+dl_ent]
    cmp     byte ptr [r11+rax], 0
    jne     7f
3:  inc     ecx
    jmp     1b
7:  mov     eax, 1
    ret
8:  xor     eax, eax
    ret

# con_renum(r14=constraint) - its refs to the compacted indices
con_renum:
    mov     eax, [r14+CN_TYPE]
    lea     r10, [rax+rax*2]
    lea     r11, [rip+con_kinds]
    add     r10, r11
    xor     ecx, ecx
1:  cmp     ecx, 3
    jae     9f
    movzx   edx, byte ptr [r10+rcx]
    mov     eax, [r14+CN_A+rcx*4]
    cmp     edx, 1
    jne     2f
    lea     r11, [rip+dl_pt]
    mov     eax, [r11+rax*4]
    mov     [r14+CN_A+rcx*4], eax
    jmp     3f
2:  cmp     edx, 2
    jne     3f
    lea     r11, [rip+dl_ent]
    movzx   eax, byte ptr [r11+rax]
    dec     eax
    mov     [r14+CN_A+rcx*4], eax
3:  inc     ecx
    jmp     1b
9:  ret

# =============================================================================
#  Geometry for display and features
# =============================================================================
# sk_plane_xyz(rdi=sketch, xmm0=u, xmm1=v (doubles), rsi=out float[3]) -
#   the sketch plane's local coordinates
sk_plane_xyz:
    cvtsd2ss xmm0, xmm0
    cvtsd2ss xmm1, xmm1
    movsd   xmm2, [rdi+SK_OFFSET]
    cvtsd2ss xmm2, xmm2
    mov     eax, [rdi+SK_PLANE]
    cmp     eax, 1
    je      1f
    ja      2f
    movss   [rsi], xmm0                 # XY: (u, v, offset)
    movss   [rsi+4], xmm1
    movss   [rsi+8], xmm2
    ret
1:  movss   [rsi], xmm0                 # XZ: (u, offset, -v) - v away from
    movss   [rsi+4], xmm2               #  the viewer looking down
    xorps   xmm1, [rip+sf_negmask]
    movss   [rsi+8], xmm1
    ret
2:  movss   [rsi], xmm2                 # YZ: (offset, v, -u)
    movss   [rsi+4], xmm1
    xorps   xmm0, [rip+sf_negmask]
    movss   [rsi+8], xmm0
    ret

.section .rodata
.align 16
sf_negmask:     .long 0x80000000, 0, 0, 0
.text

.section .note.GNU-stack,"",@progbits
