# =============================================================================
#  BeeModel - NURBS checks (BeeScript nurbscheck(k) -> the largest error)
#
#    0  a rational quadratic arc lies on its circle (radius, plane)
#    1  knot insertion leaves the curve where it was
#    2  degree elevation leaves the curve where it was
#    3  curve derivatives against central differences (relative)
#    4  a revolved NURBS cylinder lies on the cylinder; inserting knots and
#       raising degrees in u and v leaves the surface where it was
#    5  surface derivatives Su, Sv against central differences (relative)
#    6  a NURBS torus (a revolved NURBS circle) lies on the torus
# =============================================================================
.intel_syntax noprefix
.include "const.inc"
.include "brep.inc"

.globl nb_check

.section .rodata
.align 16
nc_absm:        .quad 0x7fffffffffffffff, 0x7fffffffffffffff
nc_one:         .double 1.0
nc_two:         .double 2.0
nc_three:       .double 3.0
nc_h:           .double 1.0e-6
nc_ins:         .double 0.37
nc_2pi:         .double 6.28318530717958647692
nc_a0:          .double 0.3
nc_a1:          .double 4.0
nc_tiny:        .double 1.0e-300
# the arc's frame: O (1, 2, 3), X, Y
nc_arcf:        .double 1, 2, 3,  1, 0, 0,  0, 1, 0
# a cylinder's frame: O, X, Y, Z
nc_cylf:        .double 0, 0, 0,  1, 0, 0,  0, 1, 0,  0, 0, 1
nc_l0:          .double 1, 0, 0
nc_l1:          .double 1, 0, 2
# the torus's tube: centre (3, 0, 0), X, Z
nc_tubf:        .double 3, 0, 0,  1, 0, 0,  0, 0, 1

.section .bss
.align 8
nc_err:         .skip 8
nc_a:           .skip 8                 # curves / surfaces being compared
nc_b:           .skip 8
nc_p:           .skip 72
nc_q:           .skip 72
nc_r:           .skip 72

.text

# upd(xmm0=error) - nc_err = max(nc_err, |error|)
upd:
    andpd   xmm0, [rip+nc_absm]
    maxsd   xmm0, [rip+nc_err]
    movsd   [rip+nc_err], xmm0
    ret

# nb_check(edi=which) -> xmm0 = the largest error found
nb_check:
    push    rbx
    push    r12
    push    r13
    sub     rsp, 16
    mov     ebx, edi
    call    bk_init
    xorpd   xmm0, xmm0
    movsd   [rip+nc_err], xmm0
    lea     rdi, [rip+nc_arcf]          # the arc most checks use
    movsd   xmm0, [rip+nc_two]
    movsd   xmm1, [rip+nc_a0]
    movsd   xmm2, [rip+nc_a1]
    call    nb_arc
    mov     [rip+nc_a], rax
    cmp     ebx, 0
    je      .Lnc_arc
    cmp     ebx, 1
    je      .Lnc_insert
    cmp     ebx, 2
    je      .Lnc_elevate
    cmp     ebx, 3
    je      .Lnc_deriv
    cmp     ebx, 4
    je      .Lnc_cyl
    cmp     ebx, 5
    je      .Lnc_sderiv
    cmp     ebx, 6
    je      .Lnc_torus
    jmp     .Lnc_out
.Lnc_arc:
    xor     r12d, r12d
1:  cmp     r12d, 50
    ja      .Lnc_out
    call    tpar
    mov     rdi, [rip+nc_a]
    lea     rsi, [rip+nc_p]
    call    crv_eval
    lea     rdi, [rip+nc_p]             # | |P - O| - r |
    lea     rsi, [rip+nc_arcf]
    call    v3dist
    subsd   xmm0, [rip+nc_two]
    call    upd
    movsd   xmm0, [rip+nc_p+16]         # z - 3
    subsd   xmm0, [rip+nc_three]
    call    upd
    inc     r12d
    jmp     1b
.Lnc_insert:
    mov     rdi, [rip+nc_a]
    movsd   xmm0, [rip+nc_ins]
    mov     esi, 2
    call    nb_insert
    mov     [rip+nc_b], rax
    jmp     .Lnc_same
.Lnc_elevate:
    mov     rdi, [rip+nc_a]
    call    nb_elevate
    test    rax, rax
    jz      .Lnc_bad
    mov     [rip+nc_b], rax
    mov     rdi, rax                    # and once more
    call    nb_elevate
    test    rax, rax
    jz      .Lnc_bad
    mov     [rip+nc_b], rax
.Lnc_same:
    xor     r12d, r12d
2:  cmp     r12d, 50
    ja      .Lnc_out
    call    tpar
    movsd   [rsp], xmm0
    mov     rdi, [rip+nc_a]
    lea     rsi, [rip+nc_p]
    call    crv_eval
    movsd   xmm0, [rsp]
    mov     rdi, [rip+nc_b]
    lea     rsi, [rip+nc_q]
    call    crv_eval
    lea     rdi, [rip+nc_p]
    lea     rsi, [rip+nc_q]
    call    v3dist
    call    upd
    inc     r12d
    jmp     2b
.Lnc_deriv:
    xor     r12d, r12d
3:  cmp     r12d, 48
    ja      .Lnc_out
    inc     r12d
    call    tpar
    dec     r12d
    movsd   [rsp], xmm0
    mov     rdi, [rip+nc_a]
    lea     rsi, [rip+nc_p]
    call    crv_eval
    movsd   xmm0, [rsp]                 # C(t + h), C(t - h)
    addsd   xmm0, [rip+nc_h]
    mov     rdi, [rip+nc_a]
    lea     rsi, [rip+nc_q]
    call    crv_eval
    movsd   xmm0, [rsp]
    subsd   xmm0, [rip+nc_h]
    mov     rdi, [rip+nc_a]
    lea     rsi, [rip+nc_r]
    call    crv_eval
    lea     rdi, [rip+nc_q]             # first: (C+ - C-) / 2h against C'
    lea     rsi, [rip+nc_r]
    lea     rdx, [rip+nc_p+24]
    lea     rcx, [rip+nc_h]
    mov     r8d, 0
    call    fd_err
    lea     rdi, [rip+nc_q+24]          # second: (C'+ - C'-) / 2h against C''
    lea     rsi, [rip+nc_r+24]
    lea     rdx, [rip+nc_p+48]
    lea     rcx, [rip+nc_h]
    call    fd_err
    inc     r12d
    jmp     3b
.Lnc_cyl:
    lea     rdi, [rip+nc_l0]            # the line (1, 0, 0) - (1, 0, 2)
    lea     rsi, [rip+nc_l1]            #  turned a full turn
    call    nb_line
    mov     rdi, rax
    lea     rsi, [rip+nc_cylf]
    xorpd   xmm0, xmm0
    movsd   xmm1, [rip+nc_2pi]
    call    ns_revolve
    test    rax, rax
    jz      .Lnc_bad
    mov     [rip+nc_a], rax
    mov     dword ptr [rsp+8], 0        # on the cylinder
    call    cyl_grid
    mov     rdi, [rip+nc_a]             # knots in u and v, degrees raised:
    xor     esi, esi                    #  the same surface
    movsd   xmm0, [rip+nc_ins]
    mov     edx, 1
    call    ns_insert
    test    rax, rax
    jz      .Lnc_bad
    mov     rdi, rax
    mov     esi, 1
    movsd   xmm0, [rip+nc_ins]
    addsd   xmm0, [rip+nc_ins]
    mov     edx, 1
    call    ns_insert
    test    rax, rax
    jz      .Lnc_bad
    mov     rdi, rax
    xor     esi, esi
    call    ns_elevate
    test    rax, rax
    jz      .Lnc_bad
    mov     rdi, rax
    mov     esi, 1
    call    ns_elevate
    test    rax, rax
    jz      .Lnc_bad
    mov     [rip+nc_b], rax
    mov     dword ptr [rsp+8], 1        # (against the first)
    call    cyl_grid
    jmp     .Lnc_out
.Lnc_sderiv:
    lea     rdi, [rip+nc_tubf]          # a torus: the tube revolved
    movsd   xmm0, [rip+nc_one]
    xorpd   xmm1, xmm1
    movsd   xmm2, [rip+nc_2pi]
    call    nb_arc
    mov     rdi, rax
    lea     rsi, [rip+nc_cylf]
    xorpd   xmm0, xmm0
    movsd   xmm1, [rip+nc_2pi]
    call    ns_revolve
    test    rax, rax
    jz      .Lnc_bad
    mov     [rip+nc_a], rax
    xor     r12d, r12d
4:  cmp     r12d, 7
    jae     .Lnc_out
    xor     r13d, r13d
5:  cmp     r13d, 7
    jae     6f
    call    uvpar
    movsd   [rsp], xmm0
    movsd   [rsp+8], xmm1
    mov     rdi, [rip+nc_a]
    lea     rsi, [rip+nc_p]
    call    srf_eval
    movsd   xmm0, [rsp]                 # u +- h
    addsd   xmm0, [rip+nc_h]
    movsd   xmm1, [rsp+8]
    mov     rdi, [rip+nc_a]
    lea     rsi, [rip+nc_q]
    call    srf_eval
    movsd   xmm0, [rsp]
    subsd   xmm0, [rip+nc_h]
    movsd   xmm1, [rsp+8]
    mov     rdi, [rip+nc_a]
    lea     rsi, [rip+nc_r]
    call    srf_eval
    lea     rdi, [rip+nc_q]
    lea     rsi, [rip+nc_r]
    lea     rdx, [rip+nc_p+24]
    lea     rcx, [rip+nc_h]
    call    fd_err
    movsd   xmm0, [rsp]                 # v +- h
    movsd   xmm1, [rsp+8]
    addsd   xmm1, [rip+nc_h]
    mov     rdi, [rip+nc_a]
    lea     rsi, [rip+nc_q]
    call    srf_eval
    movsd   xmm0, [rsp]
    movsd   xmm1, [rsp+8]
    subsd   xmm1, [rip+nc_h]
    mov     rdi, [rip+nc_a]
    lea     rsi, [rip+nc_r]
    call    srf_eval
    lea     rdi, [rip+nc_q]
    lea     rsi, [rip+nc_r]
    lea     rdx, [rip+nc_p+48]
    lea     rcx, [rip+nc_h]
    call    fd_err
    inc     r13d
    jmp     5b
6:  inc     r12d
    jmp     4b
.Lnc_torus:
    lea     rdi, [rip+nc_tubf]
    movsd   xmm0, [rip+nc_one]
    xorpd   xmm1, xmm1
    movsd   xmm2, [rip+nc_2pi]
    call    nb_arc
    mov     rdi, rax
    lea     rsi, [rip+nc_cylf]
    xorpd   xmm0, xmm0
    movsd   xmm1, [rip+nc_2pi]
    call    ns_revolve
    test    rax, rax
    jz      .Lnc_bad
    mov     [rip+nc_a], rax
    xor     r12d, r12d
7:  cmp     r12d, 9
    jae     .Lnc_out
    xor     r13d, r13d
8:  cmp     r13d, 9
    jae     81f
    call    uvpar
    mov     rdi, [rip+nc_a]
    lea     rsi, [rip+nc_p]
    call    srf_eval
    movsd   xmm0, [rip+nc_p]            # (sqrt(x^2 + y^2) - 3)^2 + z^2 - 1
    mulsd   xmm0, xmm0
    movsd   xmm1, [rip+nc_p+8]
    mulsd   xmm1, xmm1
    addsd   xmm0, xmm1
    sqrtsd  xmm0, xmm0
    subsd   xmm0, [rip+nc_three]
    mulsd   xmm0, xmm0
    movsd   xmm1, [rip+nc_p+16]
    mulsd   xmm1, xmm1
    addsd   xmm0, xmm1
    subsd   xmm0, [rip+nc_one]
    call    upd
    inc     r13d
    jmp     8b
81: inc     r12d
    jmp     7b
.Lnc_bad:
    movsd   xmm0, [rip+nc_one]
    movsd   [rip+nc_err], xmm0
.Lnc_out:
    movsd   xmm0, [rip+nc_err]
    add     rsp, 16
    pop     r13
    pop     r12
    pop     rbx
    ret

# tpar(r12d=i of 50) -> xmm0 = i / 50
tpar:
    cvtsi2sd xmm0, r12d
    mov     eax, 50
    cvtsi2sd xmm1, eax
    divsd   xmm0, xmm1
    ret

# uvpar(r12d, r13d) -> xmm0, xmm1 = (i + 0.5) / 8 in each (inside, away
#   from knots and ends)
uvpar:
    cvtsi2sd xmm0, r12d
    addsd   xmm0, [rip+nc_one]
    mov     eax, 9
    cvtsi2sd xmm2, eax
    divsd   xmm0, xmm2
    cvtsi2sd xmm1, r13d
    addsd   xmm1, [rip+nc_one]
    divsd   xmm1, xmm2
    ret

# fd_err(rdi=f+, rsi=f-, rdx=the derivative, rcx=&h) - the relative error
#   of the derivative against (f+ - f-) / 2h
fd_err:
    push    rbx
    sub     rsp, 32
    mov     rbx, rdx
    movsd   xmm7, [rcx]
    addsd   xmm7, xmm7
    xor     eax, eax
1:  movsd   xmm0, [rdi+rax*8]
    subsd   xmm0, [rsi+rax*8]
    divsd   xmm0, xmm7
    subsd   xmm0, [rbx+rax*8]
    movsd   [rsp+rax*8], xmm0
    inc     eax
    cmp     eax, 3
    jb      1b
    lea     rdi, [rsp]
    call    v3len
    movsd   [rsp+24], xmm0
    mov     rdi, rbx
    call    v3len
    maxsd   xmm0, [rip+nc_one]
    movsd   xmm1, xmm0
    movsd   xmm0, [rsp+24]
    divsd   xmm0, xmm1
    call    upd
    add     rsp, 32
    pop     rbx
    ret

# cyl_grid(the caller's [rsp+8]: 0 on the cylinder / 1 against nc_b) - a
#   9 x 9 grid of the surface's parameters
cyl_grid:
    push    rbx
    push    r12
    push    r13
    sub     rsp, 16
    mov     ebx, [rsp+16+24+8+8]
    xor     r12d, r12d
1:  cmp     r12d, 9
    jae     9f
    xor     r13d, r13d
2:  cmp     r13d, 9
    jae     4f
    call    uvpar
    movsd   [rsp], xmm0
    movsd   [rsp+8], xmm1
    mov     rdi, [rip+nc_a]
    lea     rsi, [rip+nc_p]
    call    srf_eval
    test    ebx, ebx
    jnz     3f
    movsd   xmm0, [rip+nc_p]            # sqrt(x^2 + y^2) - 1
    mulsd   xmm0, xmm0
    movsd   xmm1, [rip+nc_p+8]
    mulsd   xmm1, xmm1
    addsd   xmm0, xmm1
    sqrtsd  xmm0, xmm0
    subsd   xmm0, [rip+nc_one]
    call    upd
    jmp     31f
3:  movsd   xmm0, [rsp]
    movsd   xmm1, [rsp+8]
    mov     rdi, [rip+nc_b]
    lea     rsi, [rip+nc_q]
    call    srf_eval
    lea     rdi, [rip+nc_p]
    lea     rsi, [rip+nc_q]
    call    v3dist
    call    upd
31: inc     r13d
    jmp     2b
4:  inc     r12d
    jmp     1b
9:  add     rsp, 16
    pop     r13
    pop     r12
    pop     rbx
    ret

.section .note.GNU-stack,"",@progbits
