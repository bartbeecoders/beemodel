# =============================================================================
#  BeeModel - expressions with units: "10*wall + 2mm", "sin(30deg)"
#
#    expr    := term { (+|-) term }
#    term    := unary { (*|/) unary }
#    unary   := (-|+) unary | power
#    power   := primary [ ^ unary ]
#    primary := number [unit] | ( expr ) [unit] | name ( args ) | name
#
#  Lengths become scene units (mm cm m in ft), angles radians (deg rad);
#  plain numbers stay as typed. Names are pi, e, or parameters (cad.s
#  evaluates those, with cycle detection; a driver's variables come first,
#  rig.s). Functions: sin cos tan asin acos atan sqrt abs min max floor
#  ceil round. Doubles throughout.
# =============================================================================
.intel_syntax noprefix
.include "const.inc"

.globl expr_eval
.globl expr_err
.globl expr_unit_mm

.section .rodata
.align 8
xd_zero:        .double 0.0
xd_one:         .double 1.0
xd_ten:         .double 10.0
xd_half:        .double 0.5
xd_pi:          .double 3.14159265358979323846
xd_e:           .double 2.71828182845904523536
xd_deg:         .double 0.017453292519943295
.align 16
xd_abs:         .quad 0x7fffffffffffffff, 0
# units: name (8 bytes, zero padded), mm per unit (0: an angle factor follows)
units_tab:
                .ascii "mm\0\0\0\0\0\0"
                .double 1.0
                .ascii "cm\0\0\0\0\0\0"
                .double 10.0
                .ascii "m\0\0\0\0\0\0\0"
                .double 1000.0
                .ascii "in\0\0\0\0\0\0"
                .double 25.4
                .ascii "ft\0\0\0\0\0\0"
                .double 304.8
                .ascii "deg\0\0\0\0\0"
                .double -1.0
                .ascii "rad\0\0\0\0\0"
                .double -2.0
                .quad 0
funcs_tab:      .ascii "sin\0\0\0\0\0", "cos\0\0\0\0\0", "tan\0\0\0\0\0", "asin\0\0\0\0"
                .ascii "acos\0\0\0\0", "atan\0\0\0\0", "sqrt\0\0\0\0", "abs\0\0\0\0\0"
                .ascii "floor\0\0\0", "ceil\0\0\0\0", "round\0\0\0", "min\0\0\0\0\0"
                .ascii "max\0\0\0\0\0"
                .quad 0
e_x_syntax:     .asciz "syntax error"
e_x_paren:      .asciz "missing )"
e_x_name:       .asciz "unknown name"
e_x_func:       .asciz "unknown function"
e_x_args:       .asciz "wrong number of arguments"
e_x_trail:      .asciz "unexpected text after the expression"
e_x_deep:       .asciz "expression too deep"
e_x_math:       .asciz "not a number (domain or division)"

.section .data
.align 8
expr_unit_mm:   .double 1000.0          # mm per scene unit (cad.s keeps it)

.section .bss
.align 8
expr_err:       .skip 8                 # the last error message (0 = none)
ex_p:           .skip 8                 # cursor
ex_depth:       .skip 4
ex_word:        .skip 32

.text

# ws - skip spaces
ws:
    mov     rax, [rip+ex_p]
1:  cmp     byte ptr [rax], ' '
    je      2f
    cmp     byte ptr [rax], 9
    jne     3f
2:  inc     rax
    jmp     1b
3:  mov     [rip+ex_p], rax
    ret

# fail(rdi=message) - remember the first error
fail:
    cmp     qword ptr [rip+expr_err], 0
    jne     1f
    mov     [rip+expr_err], rdi
1:  xorpd   xmm0, xmm0
    ret

# ident -> eax = length of a name at ex_p (letters, digits, _), copied to
#   ex_word (8-byte padded); ex_p moves past it
ident:
    mov     rsi, [rip+ex_p]
    lea     rdi, [rip+ex_word]
    xor     eax, eax
    mov     [rdi], rax
    mov     [rdi+8], rax
    mov     [rdi+16], rax
    mov     [rdi+24], rax
    xor     ecx, ecx
1:  movzx   eax, byte ptr [rsi+rcx]
    mov     edx, eax
    or      edx, 0x20
    sub     edx, 'a'
    cmp     edx, 26
    jb      2f
    cmp     eax, '_'
    je      2f
    test    ecx, ecx                    # digits after the first
    jz      3f
    lea     edx, [rax-'0']
    cmp     edx, 10
    jae     3f
2:  cmp     ecx, 31
    jae     21f
    mov     [rdi+rcx], al
21: inc     ecx
    jmp     1b
3:  add     [rip+ex_p], rcx
    mov     eax, ecx
    ret

# number -> xmm0 (ex_p at a digit or '.')
number:
    mov     rsi, [rip+ex_p]
    xorpd   xmm0, xmm0
    movsd   xmm2, [rip+xd_ten]
1:  movzx   eax, byte ptr [rsi]         # integer part
    sub     eax, '0'
    cmp     eax, 10
    jae     2f
    mulsd   xmm0, xmm2
    cvtsi2sd xmm1, eax
    addsd   xmm0, xmm1
    inc     rsi
    jmp     1b
2:  cmp     byte ptr [rsi], '.'
    jne     4f
    inc     rsi
    movsd   xmm3, [rip+xd_one]          # fraction
3:  movzx   eax, byte ptr [rsi]
    sub     eax, '0'
    cmp     eax, 10
    jae     4f
    divsd   xmm3, xmm2
    cvtsi2sd xmm1, eax
    mulsd   xmm1, xmm3
    addsd   xmm0, xmm1
    inc     rsi
    jmp     3b
4:  movzx   eax, byte ptr [rsi]         # exponent: e or E, then a digit/sign
    or      eax, 0x20
    cmp     eax, 'e'
    jne     9f
    movzx   eax, byte ptr [rsi+1]
    xor     r8d, r8d
    mov     rdx, rsi
    inc     rdx
    cmp     eax, '-'
    jne     41f
    mov     r8d, 1
    inc     rdx
    jmp     42f
41: cmp     eax, '+'
    jne     42f
    inc     rdx
42: movzx   eax, byte ptr [rdx]
    sub     eax, '0'
    cmp     eax, 10
    jae     9f                          # "e" alone: not an exponent (a unit?)
    xor     ecx, ecx
43: movzx   eax, byte ptr [rdx]
    sub     eax, '0'
    cmp     eax, 10
    jae     44f
    imul    ecx, ecx, 10
    add     ecx, eax
    inc     rdx
    cmp     ecx, 400
    jb      43b
44: mov     rsi, rdx
45: test    ecx, ecx
    jz      9f
    test    r8d, r8d
    jnz     46f
    mulsd   xmm0, xmm2
    dec     ecx
    jmp     45b
46: divsd   xmm0, xmm2
    dec     ecx
    jmp     45b
9:  mov     [rip+ex_p], rsi
    ret

# unit(xmm0) -> xmm0 scaled by a unit name right after (if any)
unit:
    sub     rsp, 24
    movsd   [rsp], xmm0
    call    ws
    mov     rax, [rip+ex_p]
    mov     [rsp+8], rax                # (back here if it is no unit)
    movzx   eax, byte ptr [rax]
    or      eax, 0x20
    sub     eax, 'a'
    cmp     eax, 26
    jae     8f
    call    ident
    mov     rax, [rip+ex_word]
    lea     rcx, [rip+units_tab]
1:  mov     rdx, [rcx]
    test    rdx, rdx
    jz      7f
    cmp     rdx, rax
    je      2f
    add     rcx, 16
    jmp     1b
2:  movsd   xmm1, [rcx+8]
    movsd   xmm0, [rsp]
    xorpd   xmm2, xmm2
    comisd  xmm1, xmm2
    jb      3f
    mulsd   xmm0, xmm1                  # a length: mm, then scene units
    movsd   xmm1, [rip+expr_unit_mm]
    comisd  xmm1, xmm2
    jbe     9f
    divsd   xmm0, xmm1
    jmp     9f
3:  movsd   xmm2, [rip+xd_one]          # -1: degrees, -2: radians
    xorpd   xmm3, xmm3
    subsd   xmm3, xmm2
    comisd  xmm1, xmm3
    jne     9f
    mulsd   xmm0, [rip+xd_deg]
    jmp     9f
7:  mov     rax, [rsp+8]                # not a unit: put the name back
    mov     [rip+ex_p], rax
8:  movsd   xmm0, [rsp]
9:  add     rsp, 24
    ret

# parse_expr -> xmm0
parse_expr:
    sub     rsp, 24
    inc     dword ptr [rip+ex_depth]
    cmp     dword ptr [rip+ex_depth], 64
    ja      8f
    call    parse_term
1:  movsd   [rsp], xmm0
    call    ws
    mov     rax, [rip+ex_p]
    movzx   ecx, byte ptr [rax]
    cmp     ecx, '+'
    je      2f
    cmp     ecx, '-'
    jne     9f
2:  inc     qword ptr [rip+ex_p]
    mov     [rsp+8], ecx
    call    parse_term
    movsd   xmm1, xmm0
    movsd   xmm0, [rsp]
    cmp     dword ptr [rsp+8], '+'
    jne     3f
    addsd   xmm0, xmm1
    jmp     1b
3:  subsd   xmm0, xmm1
    jmp     1b
8:  lea     rdi, [rip+e_x_deep]
    call    fail
    movsd   [rsp], xmm0
9:  movsd   xmm0, [rsp]
    dec     dword ptr [rip+ex_depth]
    add     rsp, 24
    ret

parse_term:
    sub     rsp, 24
    call    parse_unary
1:  movsd   [rsp], xmm0
    call    ws
    mov     rax, [rip+ex_p]
    movzx   ecx, byte ptr [rax]
    cmp     ecx, '*'
    je      2f
    cmp     ecx, '/'
    jne     9f
2:  inc     qword ptr [rip+ex_p]
    mov     [rsp+8], ecx
    call    parse_unary
    movsd   xmm1, xmm0
    movsd   xmm0, [rsp]
    cmp     dword ptr [rsp+8], '*'
    jne     3f
    mulsd   xmm0, xmm1
    jmp     1b
3:  divsd   xmm0, xmm1
    jmp     1b
9:  movsd   xmm0, [rsp]
    add     rsp, 24
    ret

parse_unary:
    sub     rsp, 8
    call    ws
    mov     rax, [rip+ex_p]
    cmp     byte ptr [rax], '-'
    jne     1f
    inc     qword ptr [rip+ex_p]
    call    parse_unary
    xorpd   xmm1, xmm1
    subsd   xmm1, xmm0
    movsd   xmm0, xmm1
    add     rsp, 8
    ret
1:  cmp     byte ptr [rax], '+'
    jne     2f
    inc     qword ptr [rip+ex_p]
    call    parse_unary
    add     rsp, 8
    ret
2:  call    parse_pow
    add     rsp, 8
    ret

parse_pow:
    sub     rsp, 24
    call    parse_primary
    movsd   [rsp], xmm0
    call    ws
    mov     rax, [rip+ex_p]
    cmp     byte ptr [rax], '^'
    jne     9f
    inc     qword ptr [rip+ex_p]
    call    parse_unary
    movsd   [rsp+8], xmm0               # a^b = 2^(b log2 a), a > 0
    fld     qword ptr [rsp+8]
    fld     qword ptr [rsp]
    xorpd   xmm1, xmm1
    movsd   xmm0, [rsp]
    comisd  xmm0, xmm1
    jbe     8f
    fyl2x
    fld     st(0)
    frndint
    fsub    st(1), st(0)
    fxch    st(1)
    f2xm1
    fld1
    faddp   st(1), st(0)
    fscale
    fstp    st(1)
    fstp    qword ptr [rsp]
    jmp     9f
8:  fstp    st(0)
    fstp    st(0)
    xorpd   xmm0, xmm0                  # 0^b = 0 (b > 0); negatives: domain
    movsd   [rsp], xmm0
9:  movsd   xmm0, [rsp]
    add     rsp, 24
    ret

parse_primary:
    push    rbx
    sub     rsp, 32
    call    ws
    mov     rax, [rip+ex_p]
    movzx   ecx, byte ptr [rax]
    cmp     ecx, '('
    jne     1f
    inc     qword ptr [rip+ex_p]
    call    parse_expr
    movsd   [rsp], xmm0
    call    ws
    mov     rax, [rip+ex_p]
    cmp     byte ptr [rax], ')'
    jne     .Lpp_paren
    inc     qword ptr [rip+ex_p]
    movsd   xmm0, [rsp]
    call    unit
    jmp     .Lpp_out
1:  lea     edx, [rcx-'0']
    cmp     edx, 10
    jb      2f
    cmp     ecx, '.'
    jne     3f
2:  call    number
    call    unit
    jmp     .Lpp_out
3:  mov     edx, ecx
    or      edx, 0x20
    sub     edx, 'a'
    cmp     edx, 26
    jb      4f
    cmp     ecx, '_'
    jne     .Lpp_syntax
4:  call    ident
    call    ws
    mov     rax, [rip+ex_p]
    cmp     byte ptr [rax], '('
    je      .Lpp_call
    mov     rax, [rip+ex_word]          # constants, then parameters
    cmp     qword ptr [rip+ex_word+8], 0
    jne     5f
    cmp     rax, 0x6970                 # "pi"
    jne     41f
    movsd   xmm0, [rip+xd_pi]
    jmp     .Lpp_out
41: cmp     rax, 0x65                   # "e"
    jne     5f
    movsd   xmm0, [rip+xd_e]
    jmp     .Lpp_out
5:  mov     rax, [rip+ex_p]             # (cad.s may evaluate other text)
    mov     [rsp+24], rax
    mov     eax, [rip+ex_depth]
    mov     [rsp+16], eax
    mov     rax, [rip+expr_name_hook]   # (a driver's variables: rig.s)
    test    rax, rax
    jz      51f
    lea     rdi, [rip+ex_word]
    call    rax
    test    eax, eax
    jnz     52f
51: lea     rdi, [rip+ex_word]
    call    param_lookup                # -> xmm0, eax = 1 if known
52: mov     rcx, [rsp+24]
    mov     [rip+ex_p], rcx
    mov     ecx, [rsp+16]
    mov     [rip+ex_depth], ecx
    test    eax, eax
    jnz     .Lpp_out
    lea     rdi, [rip+e_x_name]
    call    fail
    jmp     .Lpp_out
.Lpp_call:
    inc     qword ptr [rip+ex_p]
    mov     rax, [rip+ex_word]          # which function
    lea     rcx, [rip+funcs_tab]
    xor     ebx, ebx
6:  mov     rdx, [rcx+rbx*8]
    test    rdx, rdx
    jz      .Lpp_nofunc
    cmp     qword ptr [rip+ex_word+8], 0
    jne     .Lpp_nofunc
    cmp     rdx, rax
    je      7f
    inc     ebx
    jmp     6b
7:  call    parse_expr                  # the first argument
    movsd   [rsp], xmm0
    call    ws
    mov     rax, [rip+ex_p]
    cmp     ebx, 11                     # min, max: two
    jb      8f
    cmp     byte ptr [rax], ','
    jne     .Lpp_args
    inc     qword ptr [rip+ex_p]
    call    parse_expr
    movsd   [rsp+8], xmm0
    call    ws
    mov     rax, [rip+ex_p]
8:  cmp     byte ptr [rax], ')'
    jne     .Lpp_paren
    inc     qword ptr [rip+ex_p]
    movsd   xmm0, [rsp]
    cmp     ebx, 11
    jne     81f
    minsd   xmm0, [rsp+8]
    jmp     .Lpp_out
81: cmp     ebx, 12
    jne     82f
    maxsd   xmm0, [rsp+8]
    jmp     .Lpp_out
82: fld     qword ptr [rsp]             # the x87 ones
    cmp     ebx, 0
    jne     83f
    fsin
    jmp     .Lpp_x87
83: cmp     ebx, 1
    jne     84f
    fcos
    jmp     .Lpp_x87
84: cmp     ebx, 2
    jne     85f
    fptan
    fstp    st(0)
    jmp     .Lpp_x87
85: cmp     ebx, 5                      # atan: atan2(x, 1)
    jne     86f
    fld1
    fpatan
    jmp     .Lpp_x87
86: cmp     ebx, 3                      # asin x = atan2(x, sqrt(1 - x^2)),
    je      861f                        # acos x = atan2(sqrt(1 - x^2), x)
    cmp     ebx, 4
    jne     87f
861:fstp    st(0)
    movsd   xmm0, [rsp]
    mulsd   xmm0, xmm0
    movsd   xmm1, [rip+xd_one]
    subsd   xmm1, xmm0
    xorpd   xmm0, xmm0
    maxsd   xmm1, xmm0
    sqrtsd  xmm1, xmm1
    movsd   [rsp+8], xmm1
    cmp     ebx, 4
    je      862f
    fld     qword ptr [rsp]             # asin: atan(x / s)
    fld     qword ptr [rsp+8]
    fpatan
    jmp     .Lpp_x87
862:fld     qword ptr [rsp+8]           # acos: atan(s / x)
    fld     qword ptr [rsp]
    fpatan
    jmp     .Lpp_x87
87: fstp    st(0)                       # the SSE ones
    movsd   xmm0, [rsp]
    cmp     ebx, 6
    jne     88f
    sqrtsd  xmm0, xmm0
    jmp     .Lpp_out
88: cmp     ebx, 7
    jne     89f
    andpd   xmm0, [rip+xd_abs]
    jmp     .Lpp_out
89: cmp     ebx, 10                     # round: floor(x + 0.5)
    jne     891f
    addsd   xmm0, [rip+xd_half]
    mov     ebx, 8
891:cvttsd2si rax, xmm0                 # floor (8) / ceil (9)
    cvtsi2sd xmm1, rax
    cmp     ebx, 9
    je      892f
    comisd  xmm1, xmm0
    jbe     893f
    subsd   xmm1, [rip+xd_one]
    jmp     893f
892:comisd  xmm1, xmm0
    jae     893f
    addsd   xmm1, [rip+xd_one]
893:movsd   xmm0, xmm1
    jmp     .Lpp_out
.Lpp_x87:
    fstp    qword ptr [rsp]
    movsd   xmm0, [rsp]
    jmp     .Lpp_out
.Lpp_nofunc:
    lea     rdi, [rip+e_x_func]
    call    fail
    jmp     .Lpp_out
.Lpp_args:
    lea     rdi, [rip+e_x_args]
    call    fail
    jmp     .Lpp_out
.Lpp_paren:
    lea     rdi, [rip+e_x_paren]
    call    fail
    jmp     .Lpp_out
.Lpp_syntax:
    lea     rdi, [rip+e_x_syntax]
    call    fail
.Lpp_out:
    add     rsp, 32
    pop     rbx
    ret

# expr_eval(rdi=text) -> xmm0 = value (double), eax = 1 ok (else expr_err)
#   Re-entrant through param_lookup (which saves the cursor).
expr_eval:
    push    rbx
    push    r12
    sub     rsp, 24
    mov     rbx, [rip+ex_p]             # (a nested evaluation keeps ours)
    mov     r12d, [rip+ex_depth]
    mov     [rip+ex_p], rdi
    cmp     r12d, 0
    jne     1f
    mov     qword ptr [rip+expr_err], 0
1:  call    parse_expr
    movsd   [rsp], xmm0
    call    ws
    mov     rax, [rip+ex_p]
    cmp     byte ptr [rax], 0
    je      2f
    lea     rdi, [rip+e_x_trail]
    call    fail
2:  movsd   xmm0, [rsp]                 # NaN / inf: an error
    ucomisd xmm0, xmm0
    jp      3f
    movsd   xmm1, xmm0
    andpd   xmm1, [rip+xd_abs]
    mov     rax, 0x7fefffffffffffff
    movq    xmm2, rax
    comisd  xmm1, xmm2
    jbe     4f
3:  lea     rdi, [rip+e_x_math]
    call    fail
4:  xor     eax, eax
    cmp     qword ptr [rip+expr_err], 0
    sete    al
    movsd   xmm0, [rsp]
    mov     [rip+ex_p], rbx
    mov     [rip+ex_depth], r12d
    add     rsp, 24
    pop     r12
    pop     rbx
    ret

.section .note.GNU-stack,"",@progbits
