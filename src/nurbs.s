# =============================================================================
#  BeeModel - NURBS curves and surfaces: the B-rep kernel's geometry
#
#  Curves are lines, circles, ellipses or NURBS; surfaces are planes,
#  cylinders, cones, spheres, tori or NURBS (rational, tensor product). The
#  analytic ones are evaluated in closed form with the parametrisations STEP
#  and OpenCASCADE use, so they round-trip exactly:
#
#    plane     O + u X + v Y
#    cylinder  O + R (cos u X + sin u Y) + v Z
#    cone      O + (R + v sin a)(cos u X + sin u Y) + v cos a Z
#    sphere    O + R cos v (cos u X + sin u Y) + R sin v Z
#    torus     O + (R + r cos v)(cos u X + sin u Y) + r sin v Z
#
#  NURBS keep homogeneous control points (w x, w y, w z, w) and clamped knot
#  vectors; evaluation is de Boor's basis functions with their derivatives
#  (The NURBS Book, A2.2 / A2.3), knot insertion is Boehm's (A5.1), degree
#  elevation splits into Bezier pieces, raises each and joins them again.
#  Surfaces do both one row of control points at a time. Everything is in
#  doubles; the kernel's memory is a set of arenas reset by each rebuild.
# =============================================================================
.intel_syntax noprefix
.include "const.inc"

.globl bk_init
.globl bk_reset
.globl bk_data
.globl kc_new
.globl ks_new
.globl bk_cv
.globl bk_sf
.globl dsincos
.globl datan2
.globl lin3
.globl v3sub
.globl v3add
.globl v3dot
.globl v3cross
.globl v3len
.globl v3norm
.globl v3scale
.globl v3axpy
.globl v3dist
.globl nb_span
.globl nb_ders
.globl crv_eval
.globl srf_eval
.globl nb_insert
.globl nb_elevate
.globl ns_insert
.globl ns_elevate
.globl nb_arc
.globl ns_revolve
.globl nb_line
.globl nk_one
.globl nk_half
.globl nk_pi
.globl nk_2pi
.globl nk_hpi
.globl nk_abs
.globl nk_neg

.include "brep.inc"

.equ MAXP,      15                      # highest degree
.equ ROW,       128                     # nb_ders: bytes per derivative row

.section .rodata
.align 16
nk_abs:         .quad 0x7fffffffffffffff, 0x7fffffffffffffff
nk_neg:         .quad 0x8000000000000000, 0x8000000000000000
nk_one:         .double 1.0
nk_half:        .double 0.5
nk_two:         .double 2.0
nk_pi:          .double 3.14159265358979323846
nk_2pi:         .double 6.28318530717958647692
nk_hpi:         .double 1.57079632679489661923
nk_qpi:         .double 0.78539816339744830962
nk_tiny:        .double 1.0e-12

.section .bss
.align 8
bk_d:           .skip ARENA_SZ          # knots, control points, scratch
bk_cv:          .skip ARENA_SZ          # curves (CV_SZ each: indices)
bk_sf:          .skip ARENA_SZ          # surfaces (SF_SZ each)
bk_ready:       .skip 4

.text

# =============================================================================
#  Memory
# =============================================================================
# bk_init - the arenas (once)
bk_init:
    cmp     dword ptr [rip+bk_ready], 0
    jne     9f
    sub     rsp, 8
    lea     rdi, [rip+bk_d]
    mov     rsi, 0x80000000
    call    arena_init
    lea     rdi, [rip+bk_cv]
    mov     rsi, 0x10000000
    call    arena_init
    lea     rdi, [rip+bk_sf]
    mov     rsi, 0x10000000
    call    arena_init
    mov     dword ptr [rip+bk_ready], 1
    add     rsp, 8
9:  ret

# bk_reset - everything the last rebuild made goes
bk_reset:
    sub     rsp, 8
    call    bk_init
    lea     rdi, [rip+bk_d]
    call    arena_reset
    lea     rdi, [rip+bk_cv]
    call    arena_reset
    lea     rdi, [rip+bk_sf]
    call    arena_reset
    add     rsp, 8
    ret

# bk_data(rdi=bytes) -> rax = 16-byte aligned memory (not cleared)
bk_data:
    sub     rsp, 8
    mov     rsi, rdi
    lea     rdi, [rip+bk_d]
    call    arena_alloc
    add     rsp, 8
    ret

# kc_new -> rax = a cleared curve; ks_new -> rax = a cleared surface
kc_new:
    sub     rsp, 8
    lea     rdi, [rip+bk_cv]
    mov     esi, CV_SZ
    call    arena_alloc
    mov     ecx, CV_SZ/8
    jmp     1f
ks_new:
    sub     rsp, 8
    lea     rdi, [rip+bk_sf]
    mov     esi, SF_SZ
    call    arena_alloc
    mov     ecx, SF_SZ/8
1:  test    rax, rax
    jz      2f
    mov     rdi, rax
    mov     rdx, rax
    xor     eax, eax
    rep     stosq
    mov     rax, rdx
2:  add     rsp, 8
    ret

# =============================================================================
#  Small helpers (doubles; 3-vectors are 3 doubles in memory)
# =============================================================================
# dsincos(xmm0=a) -> xmm0 = sin a, xmm1 = cos a
dsincos:
    movsd   [rsp-8], xmm0
    fld     qword ptr [rsp-8]
    fsincos
    fstp    qword ptr [rsp-8]
    fstp    qword ptr [rsp-16]
    movsd   xmm1, [rsp-8]
    movsd   xmm0, [rsp-16]
    ret

# datan2(xmm0=y, xmm1=x) -> xmm0 = the angle (-pi .. pi)
datan2:
    movsd   [rsp-8], xmm0
    movsd   [rsp-16], xmm1
    fld     qword ptr [rsp-8]
    fld     qword ptr [rsp-16]
    fpatan
    fstp    qword ptr [rsp-8]
    movsd   xmm0, [rsp-8]
    ret

# lin3(rdi=out, rsi=O or 0, rdx=A, xmm0=a, rcx=B or 0, xmm1=b, r8=C or 0,
#   xmm2=c): out = O + a A + b B + c C (out may be any of them)
lin3:
    xorpd   xmm3, xmm3
    xorpd   xmm4, xmm4
    xorpd   xmm5, xmm5
    test    rsi, rsi
    jz      1f
    movsd   xmm3, [rsi]
    movsd   xmm4, [rsi+8]
    movsd   xmm5, [rsi+16]
1:  movsd   xmm6, [rdx]
    mulsd   xmm6, xmm0
    addsd   xmm3, xmm6
    movsd   xmm6, [rdx+8]
    mulsd   xmm6, xmm0
    addsd   xmm4, xmm6
    movsd   xmm6, [rdx+16]
    mulsd   xmm6, xmm0
    addsd   xmm5, xmm6
    test    rcx, rcx
    jz      2f
    movsd   xmm6, [rcx]
    mulsd   xmm6, xmm1
    addsd   xmm3, xmm6
    movsd   xmm6, [rcx+8]
    mulsd   xmm6, xmm1
    addsd   xmm4, xmm6
    movsd   xmm6, [rcx+16]
    mulsd   xmm6, xmm1
    addsd   xmm5, xmm6
2:  test    r8, r8
    jz      3f
    movsd   xmm6, [r8]
    mulsd   xmm6, xmm2
    addsd   xmm3, xmm6
    movsd   xmm6, [r8+8]
    mulsd   xmm6, xmm2
    addsd   xmm4, xmm6
    movsd   xmm6, [r8+16]
    mulsd   xmm6, xmm2
    addsd   xmm5, xmm6
3:  movsd   [rdi], xmm3
    movsd   [rdi+8], xmm4
    movsd   [rdi+16], xmm5
    ret

# v3sub(rdi=out, rsi=a, rdx=b): a - b;  v3add: a + b
v3sub:
    movsd   xmm0, [rsi]
    subsd   xmm0, [rdx]
    movsd   xmm1, [rsi+8]
    subsd   xmm1, [rdx+8]
    movsd   xmm2, [rsi+16]
    subsd   xmm2, [rdx+16]
    jmp     1f
v3add:
    movsd   xmm0, [rsi]
    addsd   xmm0, [rdx]
    movsd   xmm1, [rsi+8]
    addsd   xmm1, [rdx+8]
    movsd   xmm2, [rsi+16]
    addsd   xmm2, [rdx+16]
1:  movsd   [rdi], xmm0
    movsd   [rdi+8], xmm1
    movsd   [rdi+16], xmm2
    ret

# v3dot(rdi=a, rsi=b) -> xmm0
v3dot:
    movsd   xmm0, [rdi]
    mulsd   xmm0, [rsi]
    movsd   xmm1, [rdi+8]
    mulsd   xmm1, [rsi+8]
    addsd   xmm0, xmm1
    movsd   xmm1, [rdi+16]
    mulsd   xmm1, [rsi+16]
    addsd   xmm0, xmm1
    ret

# v3cross(rdi=out, rsi=a, rdx=b): a x b (out may be a or b)
v3cross:
    movsd   xmm0, [rsi+8]               # ay bz - az by
    mulsd   xmm0, [rdx+16]
    movsd   xmm3, [rsi+16]
    mulsd   xmm3, [rdx+8]
    subsd   xmm0, xmm3
    movsd   xmm1, [rsi+16]              # az bx - ax bz
    mulsd   xmm1, [rdx]
    movsd   xmm3, [rsi]
    mulsd   xmm3, [rdx+16]
    subsd   xmm1, xmm3
    movsd   xmm2, [rsi]                 # ax by - ay bx
    mulsd   xmm2, [rdx+8]
    movsd   xmm3, [rsi+8]
    mulsd   xmm3, [rdx]
    subsd   xmm2, xmm3
    movsd   [rdi], xmm0
    movsd   [rdi+8], xmm1
    movsd   [rdi+16], xmm2
    ret

# v3len(rdi) -> xmm0
v3len:
    mov     rsi, rdi
    call    v3dot
    sqrtsd  xmm0, xmm0
    ret

# v3dist(rdi=a, rsi=b) -> xmm0 = |a - b|
v3dist:
    movsd   xmm0, [rdi]
    subsd   xmm0, [rsi]
    mulsd   xmm0, xmm0
    movsd   xmm1, [rdi+8]
    subsd   xmm1, [rsi+8]
    mulsd   xmm1, xmm1
    addsd   xmm0, xmm1
    movsd   xmm1, [rdi+16]
    subsd   xmm1, [rsi+16]
    mulsd   xmm1, xmm1
    addsd   xmm0, xmm1
    sqrtsd  xmm0, xmm0
    ret

# v3norm(rdi) - made unit length in place -> xmm0 = the old length
v3norm:
    push    rdi
    call    v3len
    pop     rdi
    xorpd   xmm1, xmm1
    ucomisd xmm0, xmm1
    je      9f
    movsd   xmm1, [rip+nk_one]
    divsd   xmm1, xmm0
    movsd   xmm2, [rdi]
    mulsd   xmm2, xmm1
    movsd   [rdi], xmm2
    movsd   xmm2, [rdi+8]
    mulsd   xmm2, xmm1
    movsd   [rdi+8], xmm2
    movsd   xmm2, [rdi+16]
    mulsd   xmm2, xmm1
    movsd   [rdi+16], xmm2
9:  ret

# v3scale(rdi=out, rsi=a, xmm0=s): s a;  v3axpy(rdi=out, rsi=a, xmm0=s): out += s a
v3scale:
    movsd   xmm1, [rsi]
    mulsd   xmm1, xmm0
    movsd   [rdi], xmm1
    movsd   xmm1, [rsi+8]
    mulsd   xmm1, xmm0
    movsd   [rdi+8], xmm1
    movsd   xmm1, [rsi+16]
    mulsd   xmm1, xmm0
    movsd   [rdi+16], xmm1
    ret
v3axpy:
    movsd   xmm1, [rsi]
    mulsd   xmm1, xmm0
    addsd   xmm1, [rdi]
    movsd   [rdi], xmm1
    movsd   xmm1, [rsi+8]
    mulsd   xmm1, xmm0
    addsd   xmm1, [rdi+8]
    movsd   [rdi+8], xmm1
    movsd   xmm1, [rsi+16]
    mulsd   xmm1, xmm0
    addsd   xmm1, [rdi+16]
    movsd   [rdi+16], xmm1
    ret

# =============================================================================
#  B-spline basis
# =============================================================================
# nb_span(edi=n: the last control point's index, esi=p, xmm0=u, rdx=knots)
#   -> eax = the knot span holding u (p .. n)
nb_span:
    lea     eax, [rdi+1]
    comisd  xmm0, [rdx+rax*8]
    jb      1f
    mov     eax, edi
    ret
1:  comisd  xmm0, [rdx+rsi*8]
    ja      2f
    mov     eax, esi
    ret
2:  mov     r8d, esi                    # low
    lea     r9d, [rdi+1]                # high
3:  lea     eax, [r8+r9]
    shr     eax, 1
    comisd  xmm0, [rdx+rax*8]
    jb      4f
    comisd  xmm0, [rdx+rax*8+8]
    jb      9f
    mov     r8d, eax
    jmp     3b
4:  mov     r9d, eax
    jmp     3b
9:  ret

# nb_ders(edi=span, esi=p, edx=derivatives 0..2, xmm0=u, rcx=knots,
#   r8=out) - the p + 1 non-zero basis functions and their derivatives:
#   out[k * 16 + j] (doubles) is the k-th derivative of N(span - p + j)
.equ ND_NDU,   0                        # ndu[j][r] at j * 128 + r * 8
.equ ND_LEFT,  2048
.equ ND_RIGHT, 2176
.equ ND_A,     2304                     # a[s][j] at s * 128 + j * 8
.equ ND_U,     2560
.equ ND_RK,    2568
.equ ND_PK,    2572
nb_ders:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    push    rbp
    sub     rsp, 2584
    mov     ebx, edi
    mov     r12d, esi
    mov     r13d, edx
    mov     r14, rcx
    mov     r15, r8
    movsd   [rsp+ND_U], xmm0
    # rows 1 .. nd start at zero (derivatives above p stay zero)
    mov     ecx, 1
1:  cmp     ecx, r13d
    ja      3f
    xor     edx, edx
2:  cmp     edx, r12d
    ja      21f
    mov     eax, ecx
    shl     eax, 7
    lea     eax, [rax+rdx*8]
    mov     qword ptr [r15+rax], 0
    inc     edx
    jmp     2b
21: inc     ecx
    jmp     1b
3:  cmp     r13d, r12d
    jbe     4f
    mov     r13d, r12d
4:  mov     rax, [rip+nk_one]
    mov     [rsp+ND_NDU], rax
    mov     ecx, 1                      # j
.Lnd_j:
    cmp     ecx, r12d
    ja      .Lnd_jdone
    lea     eax, [rbx+1]                # left[j] = u - U[span + 1 - j]
    sub     eax, ecx
    movsd   xmm1, [rsp+ND_U]
    subsd   xmm1, [r14+rax*8]
    movsd   [rsp+ND_LEFT+rcx*8], xmm1
    lea     eax, [rbx+rcx]              # right[j] = U[span + j] - u
    movsd   xmm1, [r14+rax*8]
    subsd   xmm1, [rsp+ND_U]
    movsd   [rsp+ND_RIGHT+rcx*8], xmm1
    xorpd   xmm2, xmm2                  # saved
    xor     edx, edx                    # r
.Lnd_r:
    cmp     edx, ecx
    jae     .Lnd_rdone
    movsd   xmm3, [rsp+ND_RIGHT+rdx*8+8]
    mov     eax, ecx
    sub     eax, edx
    movsd   xmm4, [rsp+ND_LEFT+rax*8]
    movsd   xmm5, xmm3                  # ndu[j][r] = right[r+1] + left[j-r]
    addsd   xmm5, xmm4
    mov     eax, ecx
    shl     eax, 7
    lea     eax, [rax+rdx*8]
    movsd   [rsp+rax], xmm5
    mov     eax, edx                    # temp = ndu[r][j-1] / ndu[j][r]
    shl     eax, 7
    lea     eax, [rax+rcx*8-8]
    movsd   xmm6, [rsp+rax]
    divsd   xmm6, xmm5
    movsd   xmm7, xmm3                  # ndu[r][j] = saved + right[r+1] temp
    mulsd   xmm7, xmm6
    addsd   xmm7, xmm2
    add     eax, 8
    movsd   [rsp+rax], xmm7
    movsd   xmm2, xmm4                  # saved = left[j-r] temp
    mulsd   xmm2, xmm6
    inc     edx
    jmp     .Lnd_r
.Lnd_rdone:
    mov     eax, ecx
    shl     eax, 7
    lea     eax, [rax+rcx*8]
    movsd   [rsp+rax], xmm2
    inc     ecx
    jmp     .Lnd_j
.Lnd_jdone:
    xor     ecx, ecx                    # the functions: ndu[j][p]
5:  cmp     ecx, r12d
    ja      6f
    mov     eax, ecx
    shl     eax, 7
    lea     eax, [rax+r12*8]
    movsd   xmm0, [rsp+rax]
    movsd   [r15+rcx*8], xmm0
    inc     ecx
    jmp     5b
6:  test    r13d, r13d
    jz      .Lnd_out
    xor     r9d, r9d                    # r
.Lnd_dr:
    cmp     r9d, r12d
    ja      .Lnd_scale
    mov     rax, [rip+nk_one]
    mov     [rsp+ND_A], rax
    xor     r10d, r10d                  # s1 (byte offset of its row)
    mov     r11d, ROW                   # s2
    mov     edi, 1                      # k
.Lnd_dk:
    cmp     edi, r13d
    ja      .Lnd_drnext
    xorpd   xmm0, xmm0                  # d
    mov     eax, r9d
    sub     eax, edi
    mov     [rsp+ND_RK], eax            # rk = r - k
    mov     edx, r12d
    sub     edx, edi
    mov     [rsp+ND_PK], edx            # pk = p - k
    cmp     r9d, edi
    jl      1f
    lea     rsi, [rsp+ND_A]             # a[s2][0] = a[s1][0] / ndu[pk+1][rk]
    movsd   xmm1, [rsi+r10]
    mov     eax, edx
    inc     eax
    shl     eax, 7
    mov     esi, [rsp+ND_RK]
    lea     eax, [rax+rsi*8]
    divsd   xmm1, [rsp+rax]
    lea     rsi, [rsp+ND_A]
    movsd   [rsi+r11], xmm1
    mov     eax, [rsp+ND_RK]            # d = a[s2][0] ndu[rk][pk]
    shl     eax, 7
    mov     esi, [rsp+ND_PK]
    lea     eax, [rax+rsi*8]
    mulsd   xmm1, [rsp+rax]
    movsd   xmm0, xmm1
1:  mov     ecx, 1                      # j1
    mov     eax, [rsp+ND_RK]
    cmp     eax, -1
    jge     2f
    neg     eax
    mov     ecx, eax
2:  mov     eax, r9d                    # j2
    dec     eax
    cmp     eax, [rsp+ND_PK]
    jg      3f
    lea     r8d, [rdi-1]
    jmp     4f
3:  mov     r8d, r12d
    sub     r8d, r9d
4:  cmp     ecx, r8d
    jg      5f
    lea     rsi, [rsp+ND_A]
    add     rsi, r10
    movsd   xmm1, [rsi+rcx*8]           # (a[s1][j] - a[s1][j-1])
    subsd   xmm1, [rsi+rcx*8-8]
    mov     eax, [rsp+ND_PK]            #  / ndu[pk+1][rk+j]
    inc     eax
    shl     eax, 7
    mov     edx, [rsp+ND_RK]
    add     edx, ecx
    lea     eax, [rax+rdx*8]
    divsd   xmm1, [rsp+rax]
    lea     rsi, [rsp+ND_A]
    add     rsi, r11
    movsd   [rsi+rcx*8], xmm1
    shl     edx, 7                      # d += a[s2][j] ndu[rk+j][pk]
    mov     eax, [rsp+ND_PK]
    lea     eax, [rdx+rax*8]
    mulsd   xmm1, [rsp+rax]
    addsd   xmm0, xmm1
    inc     ecx
    jmp     4b
5:  cmp     r9d, [rsp+ND_PK]
    jg      7f
    lea     rsi, [rsp+ND_A]             # a[s2][k] = -a[s1][k-1] / ndu[pk+1][r]
    add     rsi, r10
    movsd   xmm1, [rsi+rdi*8-8]
    xorpd   xmm1, [rip+nk_neg]
    mov     eax, [rsp+ND_PK]
    inc     eax
    shl     eax, 7
    lea     eax, [rax+r9*8]
    divsd   xmm1, [rsp+rax]
    lea     rsi, [rsp+ND_A]
    add     rsi, r11
    movsd   [rsi+rdi*8], xmm1
    mov     eax, r9d                    # d += a[s2][k] ndu[r][pk]
    shl     eax, 7
    mov     edx, [rsp+ND_PK]
    lea     eax, [rax+rdx*8]
    mulsd   xmm1, [rsp+rax]
    addsd   xmm0, xmm1
7:  mov     eax, edi                    # ders[k][r] = d
    shl     eax, 7
    lea     eax, [rax+r9*8]
    movsd   [r15+rax], xmm0
    xchg    r10, r11
    inc     edi
    jmp     .Lnd_dk
.Lnd_drnext:
    inc     r9d
    jmp     .Lnd_dr
.Lnd_scale:
    cvtsi2sd xmm1, r12d                 # times p (p - 1) ...
    mov     edi, 1
8:  cmp     edi, r13d
    ja      .Lnd_out
    xor     ecx, ecx
81: cmp     ecx, r12d
    ja      82f
    mov     eax, edi
    shl     eax, 7
    lea     eax, [rax+rcx*8]
    movsd   xmm0, [r15+rax]
    mulsd   xmm0, xmm1
    movsd   [r15+rax], xmm0
    inc     ecx
    jmp     81b
82: mov     eax, r12d
    sub     eax, edi
    cvtsi2sd xmm2, eax
    mulsd   xmm1, xmm2
    inc     edi
    jmp     8b
.Lnd_out:
    add     rsp, 2584
    pop     rbp
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# =============================================================================
#  Curves
# =============================================================================
# crv_eval(rdi=curve, xmm0=t, rsi=out: 9 doubles) - the point, the first
#   and the second derivative
crv_eval:
    mov     eax, [rdi+CV_TYPE]
    cmp     eax, CT_LINE
    je      .Lce_line
    cmp     eax, CT_CIRCLE
    je      .Lce_conic
    cmp     eax, CT_ELLIPSE
    je      .Lce_conic
    cmp     eax, CT_NURBS
    je      crv_nurbs
    mov     rdi, rsi                    # (unknown: zero)
    mov     ecx, 9
    xor     eax, eax
    rep     stosq
    ret
.Lce_line:
    push    rbx
    push    r12
    sub     rsp, 8
    mov     rbx, rdi
    mov     r12, rsi
    mov     rdi, rsi
    lea     rsi, [rbx+CV_O]
    lea     rdx, [rbx+CV_X]
    xor     ecx, ecx
    xor     r8d, r8d
    call    lin3
    mov     rax, [rbx+CV_X]
    mov     [r12+24], rax
    mov     rax, [rbx+CV_X+8]
    mov     [r12+32], rax
    mov     rax, [rbx+CV_X+16]
    mov     [r12+40], rax
    xor     eax, eax
    mov     [r12+48], rax
    mov     [r12+56], rax
    mov     [r12+64], rax
    add     rsp, 8
    pop     r12
    pop     rbx
    ret
.Lce_conic:
    push    rbx
    push    r12
    sub     rsp, 40
    mov     rbx, rdi
    mov     r12, rsi
    call    dsincos
    movsd   xmm2, [rbx+CV_R1]           # a, b
    movsd   xmm3, xmm2
    cmp     dword ptr [rbx+CV_TYPE], CT_ELLIPSE
    jne     1f
    movsd   xmm3, [rbx+CV_R2]
1:  movsd   xmm4, xmm2                  # a cos, b sin, a sin, b cos
    mulsd   xmm4, xmm1
    movsd   [rsp], xmm4
    movsd   xmm4, xmm3
    mulsd   xmm4, xmm0
    movsd   [rsp+8], xmm4
    mulsd   xmm2, xmm0
    movsd   [rsp+16], xmm2
    mulsd   xmm3, xmm1
    movsd   [rsp+24], xmm3
    mov     rdi, r12                    # P = O + a c X + b s Y
    lea     rsi, [rbx+CV_O]
    lea     rdx, [rbx+CV_X]
    movsd   xmm0, [rsp]
    lea     rcx, [rbx+CV_Y]
    movsd   xmm1, [rsp+8]
    xor     r8d, r8d
    call    lin3
    lea     rdi, [r12+24]               # D1 = -a s X + b c Y
    xor     esi, esi
    lea     rdx, [rbx+CV_X]
    movsd   xmm0, [rsp+16]
    xorpd   xmm0, [rip+nk_neg]
    lea     rcx, [rbx+CV_Y]
    movsd   xmm1, [rsp+24]
    xor     r8d, r8d
    call    lin3
    lea     rdi, [r12+48]               # D2 = -a c X - b s Y
    xor     esi, esi
    lea     rdx, [rbx+CV_X]
    movsd   xmm0, [rsp]
    xorpd   xmm0, [rip+nk_neg]
    lea     rcx, [rbx+CV_Y]
    movsd   xmm1, [rsp+8]
    xorpd   xmm1, [rip+nk_neg]
    xor     r8d, r8d
    call    lin3
    add     rsp, 40
    pop     r12
    pop     rbx
    ret

# crv_nurbs(rdi=curve, xmm0=t, rsi=out) - a rational B-spline curve
crv_nurbs:
    push    rbx
    push    r12
    push    r13
    push    r14
    sub     rsp, 520                    # ders (3 rows), A0..A2 (4 doubles)
    mov     rbx, rdi
    mov     r12, rsi
    mov     r13d, [rbx+CV_DEG]
    mov     r14, [rbx+CV_KN]
    movsd   xmm1, [r14+r13*8]           # t into [U[p], U[n+1]]
    maxsd   xmm0, xmm1
    mov     eax, [rbx+CV_N]
    minsd   xmm0, [r14+rax*8]
    movsd   [rsp+480], xmm0
    lea     edi, [rax-1]
    mov     esi, r13d
    mov     rdx, r14
    call    nb_span
    mov     [rsp+488], eax
    mov     edi, eax
    mov     esi, r13d
    mov     edx, 2
    movsd   xmm0, [rsp+480]
    mov     rcx, r14
    lea     r8, [rsp]
    call    nb_ders
    # A[k] = sum_j ders[k][j] Pw[span - p + j]
    mov     eax, [rsp+488]
    sub     eax, r13d
    shl     rax, 5
    add     rax, [rbx+CV_CP]            # the first control point used
    xor     ecx, ecx                    # k
1:  cmp     ecx, 2
    ja      4f
    xorpd   xmm0, xmm0
    xorpd   xmm1, xmm1
    xor     edx, edx                    # j
    mov     r8, rax
2:  cmp     edx, r13d
    ja      3f
    mov     r9d, ecx
    shl     r9d, 7
    lea     r9d, [r9+rdx*8]
    movsd   xmm2, [rsp+r9]
    unpcklpd xmm2, xmm2
    movupd  xmm3, [r8]
    mulpd   xmm3, xmm2
    addpd   xmm0, xmm3
    movupd  xmm3, [r8+16]
    mulpd   xmm3, xmm2
    addpd   xmm1, xmm3
    add     r8, 32
    inc     edx
    jmp     2b
3:  mov     r9d, ecx
    shl     r9d, 5
    movupd  [rsp+384+r9], xmm0
    movupd  [rsp+400+r9], xmm1
    inc     ecx
    jmp     1b
4:  lea     rdi, [rsp+384]
    mov     rsi, r12
    call    rational
    add     rsp, 520
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# rational(rdi=A0, A1, A2 (4 doubles each, homogeneous), rsi=out[9]) - the
#   point and two derivatives of the projected curve
rational:
    movsd   xmm7, [rdi+24]              # w
    movsd   xmm6, [rip+nk_one]
    divsd   xmm6, xmm7                  # 1 / w
    xor     ecx, ecx
1:  movsd   xmm0, [rdi+rcx*8]           # C0 = A0 / w
    mulsd   xmm0, xmm6
    movsd   [rsi+rcx*8], xmm0
    movsd   xmm1, [rdi+56]              # C1 = (A1 - w1 C0) / w
    mulsd   xmm1, xmm0
    movsd   xmm2, [rdi+32+rcx*8]
    subsd   xmm2, xmm1
    mulsd   xmm2, xmm6
    movsd   [rsi+24+rcx*8], xmm2
    movsd   xmm3, [rdi+56]              # C2 = (A2 - 2 w1 C1 - w2 C0) / w
    addsd   xmm3, xmm3
    mulsd   xmm3, xmm2
    movsd   xmm4, [rdi+88]
    mulsd   xmm4, xmm0
    movsd   xmm5, [rdi+64+rcx*8]
    subsd   xmm5, xmm3
    subsd   xmm5, xmm4
    mulsd   xmm5, xmm6
    movsd   [rsi+48+rcx*8], xmm5
    inc     ecx
    cmp     ecx, 3
    jb      1b
    ret

# =============================================================================
#  Surfaces
# =============================================================================
# srf_eval(rdi=surface, xmm0=u, xmm1=v, rsi=out: 9 doubles) - the point and
#   the partial derivatives Su, Sv
srf_eval:
    push    rbx
    push    r12
    sub     rsp, 104
    mov     rbx, rdi
    mov     r12, rsi
    movsd   [rsp], xmm0
    movsd   [rsp+8], xmm1
    mov     eax, [rbx+SF_TYPE]
    cmp     eax, ST_NURBS
    je      .Lse_nurbs
    cmp     eax, ST_PLANE
    je      .Lse_plane
    call    dsincos                     # cos u, sin u
    movsd   [rsp+16], xmm0              # su
    movsd   [rsp+24], xmm1              # cu
    movsd   xmm0, [rsp+8]
    call    dsincos
    movsd   [rsp+32], xmm0              # sv
    movsd   [rsp+40], xmm1              # cv
    mov     eax, [rbx+SF_TYPE]
    cmp     eax, ST_CYL
    je      .Lse_cyl
    cmp     eax, ST_CONE
    je      .Lse_cone
    cmp     eax, ST_SPHERE
    je      .Lse_sphere
    cmp     eax, ST_TORUS
    je      .Lse_torus
    mov     rdi, r12
    mov     ecx, 9
    xor     eax, eax
    rep     stosq
    jmp     .Lse_out
.Lse_plane:
    mov     rdi, r12
    lea     rsi, [rbx+SF_O]
    lea     rdx, [rbx+SF_X]
    lea     rcx, [rbx+SF_Y]
    xor     r8d, r8d
    call    lin3
    lea     rdi, [r12+24]
    lea     rsi, [rbx+SF_X]
    movsd   xmm0, [rip+nk_one]
    call    v3scale
    lea     rdi, [r12+48]
    lea     rsi, [rbx+SF_Y]
    movsd   xmm0, [rip+nk_one]
    call    v3scale
    jmp     .Lse_out
.Lse_cyl:
    movsd   xmm0, [rbx+SF_R1]           # rho = R; the axis term v
    movsd   [rsp+48], xmm0
    movsd   xmm0, [rsp+8]
    movsd   [rsp+56], xmm0
    call    ring
    lea     rdi, [r12+48]               # Sv = Z
    lea     rsi, [rbx+SF_Z]
    movsd   xmm0, [rip+nk_one]
    call    v3scale
    jmp     .Lse_out
.Lse_cone:
    movsd   xmm0, [rsp+8]               # rho = R + v sin a, axis v cos a
    mulsd   xmm0, [rbx+SF_SA]
    addsd   xmm0, [rbx+SF_R1]
    movsd   [rsp+48], xmm0
    movsd   xmm0, [rsp+8]
    mulsd   xmm0, [rbx+SF_CA]
    movsd   [rsp+56], xmm0
    call    ring
    lea     rdi, [r12+48]               # Sv = sin a (cu X + su Y) + cos a Z
    xor     esi, esi
    lea     rdx, [rbx+SF_X]
    movsd   xmm0, [rsp+24]
    mulsd   xmm0, [rbx+SF_SA]
    lea     rcx, [rbx+SF_Y]
    movsd   xmm1, [rsp+16]
    mulsd   xmm1, [rbx+SF_SA]
    lea     r8, [rbx+SF_Z]
    movsd   xmm2, [rbx+SF_CA]
    call    lin3
    jmp     .Lse_out
.Lse_sphere:
    movsd   xmm0, [rbx+SF_R1]           # rho = R cv, axis R sv
    mulsd   xmm0, [rsp+40]
    movsd   [rsp+48], xmm0
    movsd   xmm0, [rbx+SF_R1]
    mulsd   xmm0, [rsp+32]
    movsd   [rsp+56], xmm0
    call    ring
    movsd   xmm3, [rbx+SF_R1]           # Sv = -R sv (cu X + su Y) + R cv Z
    jmp     .Lse_meridian
.Lse_torus:
    movsd   xmm0, [rbx+SF_R2]           # rho = R + r cv, axis r sv
    mulsd   xmm0, [rsp+40]
    addsd   xmm0, [rbx+SF_R1]
    movsd   [rsp+48], xmm0
    movsd   xmm0, [rbx+SF_R2]
    mulsd   xmm0, [rsp+32]
    movsd   [rsp+56], xmm0
    call    ring
    movsd   xmm3, [rbx+SF_R2]           # Sv = -r sv (cu X + su Y) + r cv Z
.Lse_meridian:
    movsd   [rsp+64], xmm3
    lea     rdi, [r12+48]
    xor     esi, esi
    lea     rdx, [rbx+SF_X]
    movsd   xmm0, [rsp+32]
    mulsd   xmm0, xmm3
    mulsd   xmm0, [rsp+24]
    xorpd   xmm0, [rip+nk_neg]
    lea     rcx, [rbx+SF_Y]
    movsd   xmm1, [rsp+32]
    mulsd   xmm1, xmm3
    mulsd   xmm1, [rsp+16]
    xorpd   xmm1, [rip+nk_neg]
    lea     r8, [rbx+SF_Z]
    movsd   xmm2, [rsp+40]
    mulsd   xmm2, [rsp+64]
    call    lin3
    jmp     .Lse_out
.Lse_nurbs:
    mov     rdi, rbx
    mov     rsi, r12
    movsd   xmm0, [rsp]
    movsd   xmm1, [rsp+8]
    call    srf_nurbs
.Lse_out:
    add     rsp, 104
    pop     r12
    pop     rbx
    ret

# ring - srf_eval's revolved surfaces: P = O + rho (cu X + su Y) + h Z and
#   Su = rho (-su X + cu Y), from its frame (rho [rsp+48], h [rsp+56] there)
ring:
    lea     r9, [rsp+8]                 # srf_eval's frame
    mov     rdi, r12
    lea     rsi, [rbx+SF_O]
    lea     rdx, [rbx+SF_X]
    movsd   xmm0, [r9+48]
    mulsd   xmm0, [r9+24]
    lea     rcx, [rbx+SF_Y]
    movsd   xmm1, [r9+48]
    mulsd   xmm1, [r9+16]
    lea     r8, [rbx+SF_Z]
    movsd   xmm2, [r9+56]
    sub     rsp, 8
    call    lin3
    add     rsp, 8
    lea     r9, [rsp+8]
    lea     rdi, [r12+24]
    xor     esi, esi
    lea     rdx, [rbx+SF_X]
    movsd   xmm0, [r9+48]
    mulsd   xmm0, [r9+16]
    xorpd   xmm0, [rip+nk_neg]
    lea     rcx, [rbx+SF_Y]
    movsd   xmm1, [r9+48]
    mulsd   xmm1, [r9+24]
    xor     r8d, r8d
    sub     rsp, 8
    call    lin3
    add     rsp, 8
    ret

# srf_nurbs(rdi=surface, xmm0=u, xmm1=v, rsi=out) - a rational B-spline
#   surface: S00, S10, S01 summed in homogeneous space, then projected
.equ SN_NU,   0                         # basis in u (2 rows of 128)
.equ SN_NV,   256                       # basis in v
.equ SN_S,    512                       # S00, S10, S01 (4 doubles each)
.equ SN_U,    608
.equ SN_V,    616
.equ SN_SU,   624
.equ SN_SV,   628
srf_nurbs:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    push    rbp
    sub     rsp, 648
    mov     rbx, rdi
    mov     r12, rsi
    mov     eax, [rbx+SF_DU]            # u, v into the knot ranges
    mov     rcx, [rbx+SF_KU]
    maxsd   xmm0, [rcx+rax*8]
    mov     eax, [rbx+SF_NU]
    minsd   xmm0, [rcx+rax*8]
    movsd   [rsp+SN_U], xmm0
    mov     eax, [rbx+SF_DV]
    mov     rcx, [rbx+SF_KV]
    maxsd   xmm1, [rcx+rax*8]
    mov     eax, [rbx+SF_NV]
    minsd   xmm1, [rcx+rax*8]
    movsd   [rsp+SN_V], xmm1
    mov     edi, [rbx+SF_NU]
    dec     edi
    mov     esi, [rbx+SF_DU]
    movsd   xmm0, [rsp+SN_U]
    mov     rdx, [rbx+SF_KU]
    call    nb_span
    mov     [rsp+SN_SU], eax
    mov     edi, eax
    mov     esi, [rbx+SF_DU]
    mov     edx, 1
    movsd   xmm0, [rsp+SN_U]
    mov     rcx, [rbx+SF_KU]
    lea     r8, [rsp+SN_NU]
    call    nb_ders
    mov     edi, [rbx+SF_NV]
    dec     edi
    mov     esi, [rbx+SF_DV]
    movsd   xmm0, [rsp+SN_V]
    mov     rdx, [rbx+SF_KV]
    call    nb_span
    mov     [rsp+SN_SV], eax
    mov     edi, eax
    mov     esi, [rbx+SF_DV]
    mov     edx, 1
    movsd   xmm0, [rsp+SN_V]
    mov     rcx, [rbx+SF_KV]
    lea     r8, [rsp+SN_NV]
    call    nb_ders
    xorpd   xmm0, xmm0
    lea     rdi, [rsp+SN_S]
    mov     ecx, 12
1:  movsd   [rdi+rcx*8-8], xmm0
    loop    1b
    xor     r13d, r13d                  # i
.Lsn_i:
    cmp     r13d, [rbx+SF_DU]
    ja      .Lsn_proj
    mov     eax, [rsp+SN_SU]            # row = (su - pu + i) nv + sv - pv
    sub     eax, [rbx+SF_DU]
    add     eax, r13d
    imul    eax, [rbx+SF_NV]
    add     eax, [rsp+SN_SV]
    sub     eax, [rbx+SF_DV]
    shl     rax, 5
    add     rax, [rbx+SF_CP]
    xorpd   xmm0, xmm0                  # t0 = sum Nv0 Pw, t1 = sum Nv1 Pw
    xorpd   xmm1, xmm1
    xorpd   xmm2, xmm2
    xorpd   xmm3, xmm3
    xor     ecx, ecx
2:  cmp     ecx, [rbx+SF_DV]
    ja      3f
    movsd   xmm4, [rsp+SN_NV+rcx*8]
    unpcklpd xmm4, xmm4
    movsd   xmm5, [rsp+SN_NV+ROW+rcx*8]
    unpcklpd xmm5, xmm5
    movupd  xmm6, [rax]
    movupd  xmm7, [rax+16]
    movapd  xmm8, xmm6
    mulpd   xmm8, xmm4
    addpd   xmm0, xmm8
    movapd  xmm8, xmm7
    mulpd   xmm8, xmm4
    addpd   xmm1, xmm8
    mulpd   xmm6, xmm5
    addpd   xmm2, xmm6
    mulpd   xmm7, xmm5
    addpd   xmm3, xmm7
    add     rax, 32
    inc     ecx
    jmp     2b
3:  movsd   xmm4, [rsp+SN_NU+r13*8]     # S00 += Nu0 t0, S10 += Nu1 t0,
    unpcklpd xmm4, xmm4                 #  S01 += Nu0 t1
    movsd   xmm5, [rsp+SN_NU+ROW+r13*8]
    unpcklpd xmm5, xmm5
    movapd  xmm6, xmm0
    mulpd   xmm6, xmm4
    movupd  xmm7, [rsp+SN_S]
    addpd   xmm7, xmm6
    movupd  [rsp+SN_S], xmm7
    movapd  xmm6, xmm1
    mulpd   xmm6, xmm4
    movupd  xmm7, [rsp+SN_S+16]
    addpd   xmm7, xmm6
    movupd  [rsp+SN_S+16], xmm7
    movapd  xmm6, xmm0
    mulpd   xmm6, xmm5
    movupd  xmm7, [rsp+SN_S+32]
    addpd   xmm7, xmm6
    movupd  [rsp+SN_S+32], xmm7
    movapd  xmm6, xmm1
    mulpd   xmm6, xmm5
    movupd  xmm7, [rsp+SN_S+48]
    addpd   xmm7, xmm6
    movupd  [rsp+SN_S+48], xmm7
    mulpd   xmm2, xmm4
    movupd  xmm7, [rsp+SN_S+64]
    addpd   xmm7, xmm2
    movupd  [rsp+SN_S+64], xmm7
    mulpd   xmm3, xmm4
    movupd  xmm7, [rsp+SN_S+80]
    addpd   xmm7, xmm3
    movupd  [rsp+SN_S+80], xmm7
    inc     r13d
    jmp     .Lsn_i
.Lsn_proj:
    movsd   xmm7, [rsp+SN_S+24]         # w
    movsd   xmm6, [rip+nk_one]
    divsd   xmm6, xmm7
    xor     ecx, ecx
4:  movsd   xmm0, [rsp+SN_S+rcx*8]      # S = S00 / w
    mulsd   xmm0, xmm6
    movsd   [r12+rcx*8], xmm0
    movsd   xmm1, [rsp+SN_S+56]         # Su = (S10 - w10 S) / w
    mulsd   xmm1, xmm0
    movsd   xmm2, [rsp+SN_S+32+rcx*8]
    subsd   xmm2, xmm1
    mulsd   xmm2, xmm6
    movsd   [r12+24+rcx*8], xmm2
    movsd   xmm1, [rsp+SN_S+88]         # Sv = (S01 - w01 S) / w
    mulsd   xmm1, xmm0
    movsd   xmm2, [rsp+SN_S+64+rcx*8]
    subsd   xmm2, xmm1
    mulsd   xmm2, xmm6
    movsd   [r12+48+rcx*8], xmm2
    inc     ecx
    cmp     ecx, 3
    jb      4b
    add     rsp, 648
    pop     rbp
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# =============================================================================
#  Knot insertion, degree elevation
# =============================================================================
# nb_new(edi=degree, esi=control points) -> rax = a NURBS curve with room for
#   its knots and control points (filled by the caller), or 0
nb_new:
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
    test    rax, rax
    jz      8f
    mov     [rbx+CV_KN], rax
    mov     edi, r13d
    shl     edi, 5
    call    bk_data
    test    rax, rax
    jz      8f
    mov     [rbx+CV_CP], rax
    mov     rax, rbx
    jmp     9f
8:  xor     eax, eax
9:  pop     r13
    pop     r12
    pop     rbx
    ret

# nb_mult(rdi=curve, xmm0=u) -> eax = how often u is a knot
nb_mult:
    mov     ecx, [rdi+CV_N]
    add     ecx, [rdi+CV_DEG]
    inc     ecx
    mov     rdx, [rdi+CV_KN]
    xor     eax, eax
1:  dec     ecx
    js      9f
    ucomisd xmm0, [rdx+rcx*8]
    jne     1b
    jp      1b
    inc     eax
    jmp     1b
9:  ret

# nb_insert(rdi=curve, xmm0=u, esi=times) -> rax = the same curve with u
#   inserted (at most up to multiplicity p), or the curve itself when it
#   cannot take more
.equ NI_RW,   0                         # (p + 1) homogeneous points
.equ NI_U,    512
.equ NI_K,    520
.equ NI_S,    524
.equ NI_R,    528
.equ NI_L,    532
nb_insert:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    push    rbp
    sub     rsp, 552
    mov     rbx, rdi
    movsd   [rsp+NI_U], xmm0
    mov     [rsp+NI_R], esi
    mov     r12d, [rbx+CV_DEG]          # p
    call    nb_mult
    mov     [rsp+NI_S], eax
    mov     ecx, r12d                   # r <= p - s
    sub     ecx, eax
    cmp     [rsp+NI_R], ecx
    jle     1f
    mov     [rsp+NI_R], ecx
1:  cmp     dword ptr [rsp+NI_R], 0
    jle     .Lni_same
    mov     rax, [rbx+CV_KN]            # strictly inside the knot range
    movsd   xmm0, [rsp+NI_U]
    comisd  xmm0, [rax+r12*8]
    jbe     .Lni_same
    mov     ecx, [rbx+CV_N]
    comisd  xmm0, [rax+rcx*8]
    jae     .Lni_same
    mov     edi, [rbx+CV_N]
    dec     edi
    mov     esi, r12d
    mov     rdx, [rbx+CV_KN]
    call    nb_span
    mov     [rsp+NI_K], eax
    mov     edi, r12d
    mov     esi, [rbx+CV_N]
    add     esi, [rsp+NI_R]
    call    nb_new
    test    rax, rax
    jz      .Lni_same
    mov     r13, rax
    mov     eax, [rbx+CV_DIM]
    mov     [r13+CV_DIM], eax
    # knots: U[0..k], u r times, U[k+1..]
    mov     r14, [rbx+CV_KN]
    mov     r15, [r13+CV_KN]
    xor     ecx, ecx
2:  cmp     ecx, [rsp+NI_K]
    ja      3f
    mov     rax, [r14+rcx*8]
    mov     [r15+rcx*8], rax
    inc     ecx
    jmp     2b
3:  mov     edx, 1
    mov     rax, [rsp+NI_U]
4:  cmp     edx, [rsp+NI_R]
    jg      5f
    mov     ecx, [rsp+NI_K]
    add     ecx, edx
    mov     [r15+rcx*8], rax
    inc     edx
    jmp     4b
5:  mov     ecx, [rsp+NI_K]             # i = k + 1 .. n + p + 1 (n: last index)
    inc     ecx
    mov     edx, [rbx+CV_N]
    add     edx, r12d                   # (N - 1) + p + 1
6:  cmp     ecx, edx
    ja      7f
    mov     rax, [r14+rcx*8]
    mov     esi, ecx
    add     esi, [rsp+NI_R]
    mov     [r15+rsi*8], rax
    inc     ecx
    jmp     6b
7:  # control points that stay: Q[i] = P[i] for i <= k - p, Q[i + r] = P[i]
    #   for i >= k - s
    mov     r14, [rbx+CV_CP]
    mov     r15, [r13+CV_CP]
    xor     ecx, ecx
    mov     edx, [rsp+NI_K]
    sub     edx, r12d
8:  cmp     ecx, edx
    jg      9f
    mov     eax, ecx
    shl     eax, 5
    movupd  xmm0, [r14+rax]
    movupd  xmm1, [r14+rax+16]
    movupd  [r15+rax], xmm0
    movupd  [r15+rax+16], xmm1
    inc     ecx
    jmp     8b
9:  mov     ecx, [rsp+NI_K]
    sub     ecx, [rsp+NI_S]
10: cmp     ecx, [rbx+CV_N]
    jge     11f
    mov     eax, ecx
    shl     eax, 5
    movupd  xmm0, [r14+rax]
    movupd  xmm1, [r14+rax+16]
    mov     esi, ecx
    add     esi, [rsp+NI_R]
    shl     esi, 5
    movupd  [r15+rsi], xmm0
    movupd  [r15+rsi+16], xmm1
    inc     ecx
    jmp     10b
11: # Rw[i] = P[k - p + i], i = 0 .. p - s
    xor     ecx, ecx
    mov     edx, r12d
    sub     edx, [rsp+NI_S]
12: cmp     ecx, edx
    jg      13f
    mov     eax, [rsp+NI_K]
    sub     eax, r12d
    add     eax, ecx
    shl     eax, 5
    movupd  xmm0, [r14+rax]
    movupd  xmm1, [r14+rax+16]
    mov     eax, ecx
    shl     eax, 5
    movupd  [rsp+NI_RW+rax], xmm0
    movupd  [rsp+NI_RW+rax+16], xmm1
    inc     ecx
    jmp     12b
13: mov     rbp, [rbx+CV_KN]            # the old knots
    mov     r8d, 1                      # j
.Lni_j:
    cmp     r8d, [rsp+NI_R]
    jg      .Lni_jdone
    mov     eax, [rsp+NI_K]             # L = k - p + j
    sub     eax, r12d
    add     eax, r8d
    mov     [rsp+NI_L], eax
    xor     ecx, ecx                    # i = 0 .. p - j - s
.Lni_i:
    mov     edx, r12d
    sub     edx, r8d
    sub     edx, [rsp+NI_S]
    cmp     ecx, edx
    jg      .Lni_idone
    mov     eax, [rsp+NI_L]             # alpha = (u - U[L+i]) / (U[i+k+1] - U[L+i])
    add     eax, ecx
    movsd   xmm2, [rbp+rax*8]
    movsd   xmm0, [rsp+NI_U]
    subsd   xmm0, xmm2
    mov     edx, ecx
    add     edx, [rsp+NI_K]
    movsd   xmm1, [rbp+rdx*8+8]
    subsd   xmm1, xmm2
    divsd   xmm0, xmm1
    movsd   xmm1, [rip+nk_one]
    subsd   xmm1, xmm0
    unpcklpd xmm0, xmm0
    unpcklpd xmm1, xmm1
    mov     eax, ecx                    # Rw[i] = alpha Rw[i+1] + (1 - alpha) Rw[i]
    shl     eax, 5
    movupd  xmm2, [rsp+NI_RW+rax+32]
    movupd  xmm3, [rsp+NI_RW+rax+48]
    mulpd   xmm2, xmm0
    mulpd   xmm3, xmm0
    movupd  xmm4, [rsp+NI_RW+rax]
    movupd  xmm5, [rsp+NI_RW+rax+16]
    mulpd   xmm4, xmm1
    mulpd   xmm5, xmm1
    addpd   xmm2, xmm4
    addpd   xmm3, xmm5
    movupd  [rsp+NI_RW+rax], xmm2
    movupd  [rsp+NI_RW+rax+16], xmm3
    inc     ecx
    jmp     .Lni_i
.Lni_idone:
    movupd  xmm0, [rsp+NI_RW]           # Q[L] = Rw[0]
    movupd  xmm1, [rsp+NI_RW+16]
    mov     eax, [rsp+NI_L]
    shl     eax, 5
    movupd  [r15+rax], xmm0
    movupd  [r15+rax+16], xmm1
    mov     eax, r12d                   # Q[k + r - j - s] = Rw[p - j - s]
    sub     eax, r8d
    sub     eax, [rsp+NI_S]
    shl     eax, 5
    movupd  xmm0, [rsp+NI_RW+rax]
    movupd  xmm1, [rsp+NI_RW+rax+16]
    mov     eax, [rsp+NI_K]
    add     eax, [rsp+NI_R]
    sub     eax, r8d
    sub     eax, [rsp+NI_S]
    shl     eax, 5
    movupd  [r15+rax], xmm0
    movupd  [r15+rax+16], xmm1
    inc     r8d
    jmp     .Lni_j
.Lni_jdone:
    mov     ecx, [rsp+NI_L]             # Q[i] = Rw[i - L], i = L+1 .. k-s-1
    inc     ecx
14: mov     edx, [rsp+NI_K]
    sub     edx, [rsp+NI_S]
    dec     edx
    cmp     ecx, edx
    jg      15f
    mov     eax, ecx
    sub     eax, [rsp+NI_L]
    shl     eax, 5
    movupd  xmm0, [rsp+NI_RW+rax]
    movupd  xmm1, [rsp+NI_RW+rax+16]
    mov     eax, ecx
    shl     eax, 5
    movupd  [r15+rax], xmm0
    movupd  [r15+rax+16], xmm1
    inc     ecx
    jmp     14b
15: mov     rax, r13
    jmp     .Lni_out
.Lni_same:
    mov     rax, rbx
.Lni_out:
    add     rsp, 552
    pop     rbp
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# nb_elevate(rdi=curve) -> rax = the same curve one degree higher, or 0:
#   knots made p-fold (Bezier pieces), each piece raised, joined with
#   (p+1)-fold knots
nb_elevate:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    push    rbp
    sub     rsp, 40
    mov     rbx, rdi
    mov     r12d, [rbx+CV_DEG]
    lea     eax, [r12+1]
    cmp     eax, MAXP
    ja      .Lne_fail
    # the distinct inner knots (into the scratch arena)
    mov     edi, [rbx+CV_N]
    shl     edi, 3
    add     edi, 8
    call    bk_data
    test    rax, rax
    jz      .Lne_fail
    mov     r14, rax
    xor     r15d, r15d                  # how many
    mov     r13, [rbx+CV_KN]
    lea     ecx, [r12+1]
1:  cmp     ecx, [rbx+CV_N]
    jae     3f
    movsd   xmm0, [r13+rcx*8]
    comisd  xmm0, [r13+r12*8]           # (not the start value)
    jbe     2f
    test    r15d, r15d
    jz      11f
    ucomisd xmm0, [r14+r15*8-8]
    je      2f
11: movsd   [r14+r15*8], xmm0
    inc     r15d
2:  inc     ecx
    jmp     1b
3:  mov     [rsp], r15d
    mov     [rsp+8], r14
    xor     ebp, ebp                    # make each p-fold
4:  cmp     ebp, r15d
    jae     5f
    mov     rdi, rbx
    movsd   xmm0, [r14+rbp*8]
    call    nb_mult
    mov     esi, r12d
    sub     esi, eax
    jle     41f
    mov     rdi, rbx
    movsd   xmm0, [r14+rbp*8]
    call    nb_insert
    mov     rbx, rax
41: inc     ebp
    jmp     4b
5:  lea     eax, [r15+1]                # pieces
    mov     [rsp+4], eax
    imul    eax, r12d                   # (the Bezier form has p n + 1 points)
    inc     eax
    cmp     eax, [rbx+CV_N]
    jne     .Lne_fail
    lea     edi, [r12+1]
    mov     esi, [rsp+4]
    lea     eax, [r12+1]
    imul    esi, eax
    inc     esi
    call    nb_new
    test    rax, rax
    jz      .Lne_fail
    mov     r13, rax
    mov     eax, [rbx+CV_DIM]
    mov     [r13+CV_DIM], eax
    # knots: a (p+2 times), each inner value (p+1 times), b (p+2 times)
    mov     rdi, [r13+CV_KN]
    mov     rsi, [rbx+CV_KN]
    mov     rax, [rsi+r12*8]            # a
    lea     ecx, [r12+2]
6:  stosq
    loop    6b
    xor     edx, edx
7:  cmp     edx, r15d
    jae     8f
    mov     rax, [r14+rdx*8]
    lea     ecx, [r12+1]
71: stosq
    loop    71b
    inc     edx
    jmp     7b
8:  mov     eax, [rbx+CV_N]
    mov     rax, [rsi+rax*8]            # b
    lea     ecx, [r12+2]
81: stosq
    loop    81b
    # each piece Q0..Qp -> R0..R(p+1): Ri = i/(p+1) Q(i-1) + (1 - i/(p+1)) Qi
    lea     eax, [r12+1]
    cvtsi2sd xmm7, eax
    xor     ebp, ebp                    # piece
.Lne_piece:
    cmp     ebp, [rsp+4]
    jae     .Lne_done
    mov     eax, ebp
    imul    eax, r12d
    shl     rax, 5
    add     rax, [rbx+CV_CP]
    mov     r8, rax                     # Q0
    lea     eax, [r12+1]
    imul    eax, ebp
    shl     rax, 5
    add     rax, [r13+CV_CP]
    mov     r9, rax                     # R0
    xor     ecx, ecx
9:  lea     eax, [r12+1]
    cmp     ecx, eax
    ja      10f
    cvtsi2sd xmm0, ecx
    divsd   xmm0, xmm7                  # alpha
    movsd   xmm1, [rip+nk_one]
    subsd   xmm1, xmm0
    unpcklpd xmm0, xmm0
    unpcklpd xmm1, xmm1
    xorpd   xmm2, xmm2
    xorpd   xmm3, xmm3
    mov     eax, ecx
    shl     eax, 5
    test    ecx, ecx
    jz      91f
    movupd  xmm4, [r8+rax-32]
    movupd  xmm5, [r8+rax-16]
    mulpd   xmm4, xmm0
    mulpd   xmm5, xmm0
    addpd   xmm2, xmm4
    addpd   xmm3, xmm5
91: cmp     ecx, r12d
    ja      92f
    movupd  xmm4, [r8+rax]
    movupd  xmm5, [r8+rax+16]
    mulpd   xmm4, xmm1
    mulpd   xmm5, xmm1
    addpd   xmm2, xmm4
    addpd   xmm3, xmm5
92: movupd  [r9+rax], xmm2
    movupd  [r9+rax+16], xmm3
    inc     ecx
    jmp     9b
10: inc     ebp
    jmp     .Lne_piece
.Lne_done:
    mov     rax, r13
    jmp     .Lne_out
.Lne_fail:
    xor     eax, eax
.Lne_out:
    add     rsp, 40
    pop     rbp
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# ns_rows(rdi=surface, esi=direction 0 u / 1 v, rdx=curve operation
#   (rdi=curve, xmm0, esi) -> rax, xmm0, ecx = its arguments) -> rax = a new
#   surface: the operation applied to every row of control points along the
#   direction, or 0
.equ NR_OP,   0
.equ NR_T,    8
.equ NR_R,    16
.equ NR_DIR,  20
.equ NR_NEW,  24                        # the new surface
.equ NR_ROWS, 32
.equ NR_LEN,  36                        # control points per row (before)
.equ NR_TMP,  40                        # the row as a curve
ns_rows:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    push    rbp
    sub     rsp, 56
    mov     rbx, rdi
    mov     [rsp+NR_OP], rdx
    movsd   [rsp+NR_T], xmm0
    mov     [rsp+NR_R], ecx
    mov     [rsp+NR_DIR], esi
    mov     eax, [rbx+SF_NV]            # u rows: one per v index, nu long
    mov     ecx, [rbx+SF_NU]
    test    esi, esi
    jz      1f
    xchg    eax, ecx
1:  mov     [rsp+NR_ROWS], eax
    mov     [rsp+NR_LEN], ecx
    mov     edi, [rbx+SF_DU]            # the row curve
    test    esi, esi
    jz      2f
    mov     edi, [rbx+SF_DV]
2:  mov     esi, ecx
    call    nb_new
    test    rax, rax
    jz      .Lnr_fail
    mov     [rsp+NR_TMP], rax
    mov     rdi, [rax+CV_KN]            # its knots: the surface's
    mov     rsi, [rbx+SF_KU]
    cmp     dword ptr [rsp+NR_DIR], 0
    je      3f
    mov     rsi, [rbx+SF_KV]
3:  mov     ecx, [rax+CV_N]
    add     ecx, [rax+CV_DEG]
    inc     ecx
    rep     movsq
    call    ks_new
    test    rax, rax
    jz      .Lnr_fail
    mov     [rsp+NR_NEW], rax
    mov     rdi, rax                    # a copy of the header
    mov     rsi, rbx
    mov     ecx, SF_SZ/8
    rep     movsq
    xor     r12d, r12d                  # row
.Lnr_row:
    cmp     r12d, [rsp+NR_ROWS]
    jae     .Lnr_done
    mov     r13, [rsp+NR_TMP]           # gather the row
    mov     rdi, [r13+CV_CP]
    xor     ecx, ecx
4:  cmp     ecx, [rsp+NR_LEN]
    jae     5f
    mov     eax, ecx                    # u: P[c nv + row]; v: P[row nv + c]
    imul    eax, [rbx+SF_NV]
    add     eax, r12d
    cmp     dword ptr [rsp+NR_DIR], 0
    je      41f
    mov     eax, r12d
    imul    eax, [rbx+SF_NV]
    add     eax, ecx
41: shl     rax, 5
    add     rax, [rbx+SF_CP]
    movupd  xmm0, [rax]
    movupd  xmm1, [rax+16]
    mov     eax, ecx
    shl     eax, 5
    movupd  [rdi+rax], xmm0
    movupd  [rdi+rax+16], xmm1
    inc     ecx
    jmp     4b
5:  mov     rdi, r13
    movsd   xmm0, [rsp+NR_T]
    mov     esi, [rsp+NR_R]
    call    [rsp+NR_OP]
    test    rax, rax
    jz      .Lnr_fail
    mov     r14, rax                    # the row after
    mov     r15, [rsp+NR_NEW]
    test    r12d, r12d
    jnz     6f
    mov     eax, [r14+CV_N]             # first row: the new sizes, knots,
    mov     ecx, [r14+CV_DEG]           #  room for the control points
    cmp     dword ptr [rsp+NR_DIR], 0
    jne     51f
    mov     [r15+SF_NU], eax
    mov     [r15+SF_DU], ecx
    mov     rax, [r14+CV_KN]
    mov     [r15+SF_KU], rax
    jmp     52f
51: mov     [r15+SF_NV], eax
    mov     [r15+SF_DV], ecx
    mov     rax, [r14+CV_KN]
    mov     [r15+SF_KV], rax
52: mov     edi, [r15+SF_NU]
    imul    edi, [r15+SF_NV]
    shl     edi, 5
    call    bk_data
    test    rax, rax
    jz      .Lnr_fail
    mov     [r15+SF_CP], rax
6:  mov     eax, [r14+CV_N]             # every row must come out alike
    mov     ecx, [r15+SF_NU]
    cmp     dword ptr [rsp+NR_DIR], 0
    je      61f
    mov     ecx, [r15+SF_NV]
61: cmp     eax, ecx
    jne     .Lnr_fail
    mov     rsi, [r14+CV_CP]            # scatter it
    xor     ecx, ecx
7:  cmp     ecx, [r14+CV_N]
    jae     8f
    mov     eax, ecx
    imul    eax, [r15+SF_NV]
    add     eax, r12d
    cmp     dword ptr [rsp+NR_DIR], 0
    je      71f
    mov     eax, r12d
    imul    eax, [r15+SF_NV]
    add     eax, ecx
71: shl     rax, 5
    add     rax, [r15+SF_CP]
    mov     edx, ecx
    shl     edx, 5
    movupd  xmm0, [rsi+rdx]
    movupd  xmm1, [rsi+rdx+16]
    movupd  [rax], xmm0
    movupd  [rax+16], xmm1
    inc     ecx
    jmp     7b
8:  inc     r12d
    jmp     .Lnr_row
.Lnr_done:
    mov     rax, [rsp+NR_NEW]
    jmp     .Lnr_out
.Lnr_fail:
    xor     eax, eax
.Lnr_out:
    add     rsp, 56
    pop     rbp
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# ns_insert(rdi=surface, esi=direction, xmm0=knot, edx=times) -> rax
ns_insert:
    mov     ecx, edx
    lea     rdx, [rip+nb_insert]
    jmp     ns_rows

# ns_elevate(rdi=surface, esi=direction) -> rax
ns_elevate:
    lea     rdx, [rip+nb_elevate]
    jmp     ns_rows

# =============================================================================
#  Construction
# =============================================================================
# nb_line(rdi=a, rsi=b: 3 doubles) -> rax = the segment as a degree 1 NURBS
nb_line:
    push    rbx
    push    r12
    push    r13
    mov     r12, rdi
    mov     r13, rsi
    mov     edi, 1
    mov     esi, 2
    call    nb_new
    test    rax, rax
    jz      9f
    mov     rbx, rax
    mov     rdi, [rbx+CV_KN]
    xorpd   xmm0, xmm0
    movsd   [rdi], xmm0
    movsd   [rdi+8], xmm0
    movsd   xmm0, [rip+nk_one]
    movsd   [rdi+16], xmm0
    movsd   [rdi+24], xmm0
    mov     rdi, [rbx+CV_CP]
    movupd  xmm1, [r12]
    movupd  [rdi], xmm1
    mov     rax, [r12+16]
    mov     [rdi+16], rax
    movsd   [rdi+24], xmm0
    movupd  xmm1, [r13]
    movupd  [rdi+32], xmm1
    mov     rax, [r13+16]
    mov     [rdi+48], rax
    movsd   [rdi+56], xmm0
    mov     rax, rbx
9:  pop     r13
    pop     r12
    pop     rbx
    ret

# nb_arc(rdi=O, X, Y (9 doubles), xmm0=r, xmm1=a0, xmm2=a1) -> rax = the
#   circular arc as a rational quadratic NURBS (pieces of at most 90
#   degrees, The NURBS Book A7.1), parameter 0 .. 1
.equ NA_F,    0                         # O X Y
.equ NA_R,    72
.equ NA_A,    80                        # the running angle
.equ NA_D,    88                        # the piece's angle
.equ NA_W,    96                        # cos (d / 2)
.equ NA_T,    104                       # r tan (d / 2)
.equ NA_N,    112                       # pieces
.equ NA_P0,   120                       # the last point, its tangent
.equ NA_T0,   144
.equ NA_P2,   168
.equ NA_T2,   192
.equ NA_S,    224                       # arc_at: sin, cos
.equ NA_C,    232
nb_arc:
    push    rbx
    push    r12
    push    r13
    sub     rsp, 256
    mov     rsi, rdi
    lea     rdi, [rsp+NA_F]
    mov     ecx, 9
    rep     movsq
    movsd   [rsp+NA_R], xmm0
    movsd   [rsp+NA_A], xmm1
    subsd   xmm2, xmm1                  # pieces: ceil(sweep / 90 deg), 1 .. 4
    movsd   xmm0, xmm2
    andpd   xmm0, [rip+nk_abs]
    divsd   xmm0, [rip+nk_hpi]
    subsd   xmm0, [rip+nk_tiny]
    cvttsd2si eax, xmm0
    inc     eax
    cmp     eax, 1
    jge     1f
    mov     eax, 1
1:  cmp     eax, 4
    jle     2f
    mov     eax, 4
2:  mov     [rsp+NA_N], eax
    cvtsi2sd xmm3, eax
    divsd   xmm2, xmm3
    movsd   [rsp+NA_D], xmm2
    mulsd   xmm2, [rip+nk_half]
    movsd   xmm0, xmm2
    call    dsincos
    movsd   [rsp+NA_W], xmm1
    divsd   xmm0, xmm1
    mulsd   xmm0, [rsp+NA_R]
    movsd   [rsp+NA_T], xmm0
    mov     esi, [rsp+NA_N]
    lea     esi, [rsi*2+1]
    mov     edi, 2
    call    nb_new
    test    rax, rax
    jz      .Lna_out
    mov     rbx, rax
    mov     rdi, [rbx+CV_KN]            # knots 0 0 0 (j/n j/n) 1 1 1
    xorpd   xmm0, xmm0
    movsd   [rdi], xmm0
    movsd   [rdi+8], xmm0
    movsd   [rdi+16], xmm0
    add     rdi, 24
    mov     ecx, 1
3:  cmp     ecx, [rsp+NA_N]
    jae     4f
    cvtsi2sd xmm0, ecx
    cvtsi2sd xmm1, dword ptr [rsp+NA_N]
    divsd   xmm0, xmm1
    movsd   [rdi], xmm0
    movsd   [rdi+8], xmm0
    add     rdi, 16
    inc     ecx
    jmp     3b
4:  movsd   xmm0, [rip+nk_one]
    movsd   [rdi], xmm0
    movsd   [rdi+8], xmm0
    movsd   [rdi+16], xmm0
    lea     rdi, [rsp+NA_P0]            # the first point
    lea     rsi, [rsp+NA_T0]
    call    arc_at
    mov     r12, [rbx+CV_CP]
    lea     rsi, [rsp+NA_P0]
    movsd   xmm0, [rip+nk_one]
    call    put_w
    xor     r13d, r13d
.Lna_piece:
    cmp     r13d, [rsp+NA_N]
    jae     .Lna_done
    movsd   xmm0, [rsp+NA_A]
    addsd   xmm0, [rsp+NA_D]
    movsd   [rsp+NA_A], xmm0
    lea     rdi, [rsp+NA_P2]
    lea     rsi, [rsp+NA_T2]
    call    arc_at
    lea     rdi, [rsp+NA_P0]            # the middle point: P0 + T0 r tan(d/2)
    lea     rsi, [rsp+NA_T0]
    movsd   xmm0, [rsp+NA_T]
    call    v3axpy
    lea     rsi, [rsp+NA_P0]
    movsd   xmm0, [rsp+NA_W]
    call    put_w
    lea     rsi, [rsp+NA_P2]
    movsd   xmm0, [rip+nk_one]
    call    put_w
    lea     rdi, [rsp+NA_P0]
    lea     rsi, [rsp+NA_P2]
    mov     ecx, 6
    rep     movsq
    inc     r13d
    jmp     .Lna_piece
.Lna_done:
    mov     rax, rbx
.Lna_out:
    add     rsp, 256
    pop     r13
    pop     r12
    pop     rbx
    ret
# arc_at(rdi=point, rsi=tangent) - nb_arc's circle at its running angle
arc_at:
    push    rbx
    push    r12
    push    r13
    lea     r13, [rsp+32]               # nb_arc's frame
    mov     rbx, rdi
    mov     r12, rsi
    movsd   xmm0, [r13+NA_A]
    call    dsincos
    movsd   [r13+NA_S], xmm0
    movsd   [r13+NA_C], xmm1
    mov     rdi, rbx
    lea     rsi, [r13+NA_F]
    lea     rdx, [r13+NA_F+24]
    movsd   xmm0, [r13+NA_C]
    mulsd   xmm0, [r13+NA_R]
    lea     rcx, [r13+NA_F+48]
    movsd   xmm1, [r13+NA_S]
    mulsd   xmm1, [r13+NA_R]
    xor     r8d, r8d
    call    lin3
    mov     rdi, r12
    xor     esi, esi
    lea     rdx, [r13+NA_F+24]
    movsd   xmm0, [r13+NA_S]
    xorpd   xmm0, [rip+nk_neg]
    lea     rcx, [r13+NA_F+48]
    movsd   xmm1, [r13+NA_C]
    xor     r8d, r8d
    call    lin3
    pop     r13
    pop     r12
    pop     rbx
    ret
# put_w(r12=cursor, rsi=point, xmm0=w) - (w x, w y, w z, w); r12 advances
put_w:
    movsd   xmm1, [rsi]
    mulsd   xmm1, xmm0
    movsd   [r12], xmm1
    movsd   xmm1, [rsi+8]
    mulsd   xmm1, xmm0
    movsd   [r12+8], xmm1
    movsd   xmm1, [rsi+16]
    mulsd   xmm1, xmm0
    movsd   [r12+16], xmm1
    movsd   [r12+24], xmm0
    add     r12, 32
    ret

# ns_revolve(rdi=profile curve (NURBS: x radial, z along the axis), rsi=frame
#   O X Y Z (12 doubles), xmm0=a0, xmm1=a1) -> rax = the surface of
#   revolution as a NURBS surface (u around, v along the profile), or 0
ns_revolve:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    push    rbp
    sub     rsp, 136
    mov     rbx, rdi
    mov     r12, rsi
    lea     rdi, [rsp]                  # a unit arc in the XY plane at 0
    xorpd   xmm2, xmm2
    movsd   [rsp], xmm2
    movsd   [rsp+8], xmm2
    movsd   [rsp+16], xmm2
    movsd   xmm3, [rip+nk_one]
    movsd   [rsp+24], xmm3
    movsd   [rsp+32], xmm2
    movsd   [rsp+40], xmm2
    movsd   [rsp+48], xmm2
    movsd   [rsp+56], xmm3
    movsd   [rsp+64], xmm2
    movsd   xmm2, xmm1
    movsd   xmm1, xmm0
    movsd   xmm0, xmm3
    call    nb_arc
    test    rax, rax
    jz      .Lnv_fail
    mov     r13, rax
    call    ks_new
    test    rax, rax
    jz      .Lnv_fail
    mov     r14, rax
    mov     dword ptr [r14+SF_TYPE], ST_NURBS
    mov     dword ptr [r14+SF_DU], 2
    mov     eax, [rbx+CV_DEG]
    mov     [r14+SF_DV], eax
    mov     eax, [r13+CV_N]
    mov     [r14+SF_NU], eax
    mov     eax, [rbx+CV_N]
    mov     [r14+SF_NV], eax
    mov     rax, [r13+CV_KN]
    mov     [r14+SF_KU], rax
    mov     rax, [rbx+CV_KN]
    mov     [r14+SF_KV], rax
    mov     edi, [r14+SF_NU]
    imul    edi, [r14+SF_NV]
    shl     edi, 5
    call    bk_data
    test    rax, rax
    jz      .Lnv_fail
    mov     [r14+SF_CP], rax
    mov     r15, rax
    xor     ebp, ebp                    # i around
.Lnv_i:
    cmp     ebp, [r14+SF_NU]
    jae     .Lnv_done
    mov     eax, ebp                    # the arc's point (cos, sin) and weight
    shl     eax, 5
    add     rax, [r13+CV_CP]
    movsd   xmm7, [rax+24]
    movsd   xmm5, [rax]
    divsd   xmm5, xmm7
    movsd   [rsp+72], xmm5              # ax
    movsd   xmm5, [rax+8]
    divsd   xmm5, xmm7
    movsd   [rsp+80], xmm5              # ay
    movsd   [rsp+88], xmm7              # wa
    xor     ecx, ecx                    # j along the profile
.Lnv_j:
    cmp     ecx, [r14+SF_NV]
    jae     .Lnv_inext
    mov     [rsp+96], ecx
    mov     eax, ecx
    shl     eax, 5
    add     rax, [rbx+CV_CP]
    movsd   xmm7, [rax+24]              # wp
    movsd   xmm4, [rax]
    divsd   xmm4, xmm7                  # px (radial)
    movsd   xmm5, [rax+16]
    divsd   xmm5, xmm7                  # pz (axial)
    mulsd   xmm7, [rsp+88]
    movsd   [rsp+104], xmm7             # w = wa wp
    movsd   xmm0, xmm4                  # P = O + px ax X + px ay Y + pz Z
    mulsd   xmm0, [rsp+72]
    movsd   xmm1, xmm4
    mulsd   xmm1, [rsp+80]
    movsd   xmm2, xmm5
    lea     rdi, [rsp+112]
    lea     rsi, [r12+24]
    movsd   xmm3, xmm0
    mov     rsi, r12
    lea     rdx, [r12+24]
    lea     rcx, [r12+48]
    lea     r8, [r12+72]
    call    lin3
    mov     eax, ebp
    imul    eax, [r14+SF_NV]
    add     eax, [rsp+96]
    shl     rax, 5
    add     rax, r15
    movsd   xmm7, [rsp+104]
    movsd   xmm0, [rsp+112]
    mulsd   xmm0, xmm7
    movsd   [rax], xmm0
    movsd   xmm0, [rsp+120]
    mulsd   xmm0, xmm7
    movsd   [rax+8], xmm0
    movsd   xmm0, [rsp+128]
    mulsd   xmm0, xmm7
    movsd   [rax+16], xmm0
    movsd   [rax+24], xmm7
    mov     ecx, [rsp+96]
    inc     ecx
    jmp     .Lnv_j
.Lnv_inext:
    inc     ebp
    jmp     .Lnv_i
.Lnv_done:
    mov     rax, r14
    jmp     .Lnv_out
.Lnv_fail:
    xor     eax, eax
.Lnv_out:
    add     rsp, 136
    pop     rbp
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

.section .note.GNU-stack,"",@progbits
