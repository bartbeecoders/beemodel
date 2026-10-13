# =============================================================================
#  BeeModel - the field VM: per-element programs for geometry nodes.
#
#  A field (a value or vector per point, made of position, normal, index,
#  math, noise and random nodes) compiles to a small program over scalar
#  registers (a vector is three). The interpreter runs it a block of 256
#  elements at a time: each instruction is one tight SSE loop over the
#  block, so the dispatch costs once per 256 elements, and the blocks are
#  spread over the job threads. Transcendentals, noise and hashing run per
#  element inside the same loops.
#
#  An instruction is 24 bytes: op, dst, a, b, c (registers), three spare
#  bytes, four immediates. The context (fv_ctx) names the inputs (structure
#  of arrays), the element count and where registers go when a block ends.
# =============================================================================
.intel_syntax noprefix
.include "const.inc"

.globl fv_run
.globl fv_ctx

.equ FV_B,      256                     # elements per block
.equ FV_REGS,   64
.equ FV_THREADS, 65                     # (the last: a nested call)
.equ IN_SZ,     24
# ops
.equ OP_CONST,  1
.equ OP_PX,     2
.equ OP_PY,     3
.equ OP_PZ,     4
.equ OP_NX,     5
.equ OP_NY,     6
.equ OP_NZ,     7
.equ OP_INDEX,  8
.equ OP_ADD,    10
.equ OP_SUB,    11
.equ OP_MUL,    12
.equ OP_DIV,    13
.equ OP_MIN,    14
.equ OP_MAX,    15
.equ OP_LT,     16
.equ OP_GT,     17
.equ OP_POW,    18
.equ OP_MOD,    19
.equ OP_ABS,    20
.equ OP_SQRT,   21
.equ OP_FLOOR,  22
.equ OP_SIN,    23
.equ OP_COS,    24
.equ OP_NOISE,  26
.equ OP_RAND,   27
.equ OP_MOV,    28
.equ OP_SEL,    29                      # dst = c > 0.5 ? a : b
# the context
.equ FC_N,      0                       # elements
.equ FC_PROG,   8                       # instructions,
.equ FC_NINS,   16                      #  how many
.equ FC_IN,     24                      # px py pz nx ny nz index (7 pointers)
.equ FC_NOUT,   80                      # outputs: how many,
.equ FC_OUT,    88                      #  (register u32, pad, pointer) x 8
.equ FC_SZ,     88+16*8

.section .rodata
.align 16
fv_abs:         .long 0x7fffffff, 0x7fffffff, 0x7fffffff, 0x7fffffff
fv_ones:        .float 1.0, 1.0, 1.0, 1.0
fv_tiny:        .float 1.0e-20
fv_inv24:       .float 5.9604645e-8
fv_noff:        .float 0, 0, 0, 17.31, 41.77, 7.13, 31.59, 3.23, 23.41

.section .bss
.align 64
fv_ctx:         .skip FC_SZ
.align 64
fv_scratch:     .skip FV_THREADS*FV_REGS*FV_B*4

.text

# fv_run - run fv_ctx's program over its elements (parallel)
fv_run:
    sub     rsp, 8
    mov     edx, [rip+fv_ctx+FC_N]
    add     edx, FV_B-1
    shr     edx, 8                      # blocks
    jz      9f
    lea     rdi, [rip+fv_job]
    xor     esi, esi
    mov     ecx, 2
    call    parallel_for
9:  add     rsp, 8
    ret

# fv_job(rdi=ctx, esi=first block, edx=end, ecx=thread)
fv_job:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    push    rbp
    sub     rsp, 56
    mov     [rsp], esi
    mov     [rsp+4], edx
    test    ecx, ecx
    jns     1f
    mov     ecx, FV_THREADS-1
1:  cmp     ecx, FV_THREADS-1
    jbe     2f
    mov     ecx, FV_THREADS-1
2:  imul    rcx, rcx, FV_REGS*FV_B*4
    lea     rbp, [rip+fv_scratch]
    add     rbp, rcx                    # this thread's registers
.Lfj_block:
    mov     eax, [rsp]
    cmp     eax, [rsp+4]
    jae     .Lfj_out
    shl     eax, 8
    mov     [rsp+8], eax                # first element
    mov     ecx, [rip+fv_ctx+FC_N]
    sub     ecx, eax
    cmp     ecx, FV_B
    jbe     3f
    mov     ecx, FV_B
3:  mov     [rsp+12], ecx               # elements in it
    add     ecx, 3                      # (whole SSE groups)
    shr     ecx, 2
    mov     [rsp+16], ecx
    mov     r12, [rip+fv_ctx+FC_PROG]
    mov     r13d, [rip+fv_ctx+FC_NINS]
.Lfj_ins:
    test    r13d, r13d
    jz      .Lfj_outs
    movzx   eax, byte ptr [r12]
    movzx   ebx, byte ptr [r12+1]       # dst
    shl     ebx, 10                     # * FV_B * 4
    add     rbx, rbp
    movzx   r14d, byte ptr [r12+2]      # a
    shl     r14d, 10
    add     r14, rbp
    movzx   r15d, byte ptr [r12+3]      # b
    shl     r15d, 10
    add     r15, rbp
    mov     ecx, [rsp+16]               # groups of four
    cmp     eax, OP_CONST
    je      .Lop_const
    cmp     eax, OP_INDEX
    jbe     .Lop_load
    cmp     eax, OP_ADD
    je      .Lop_add
    cmp     eax, OP_SUB
    je      .Lop_sub
    cmp     eax, OP_MUL
    je      .Lop_mul
    cmp     eax, OP_DIV
    je      .Lop_div
    cmp     eax, OP_MIN
    je      .Lop_min
    cmp     eax, OP_MAX
    je      .Lop_max
    cmp     eax, OP_LT
    je      .Lop_lt
    cmp     eax, OP_GT
    je      .Lop_gt
    cmp     eax, OP_ABS
    je      .Lop_abs
    cmp     eax, OP_SQRT
    je      .Lop_sqrt
    cmp     eax, OP_FLOOR
    je      .Lop_floor
    cmp     eax, OP_MOV
    je      .Lop_mov
    cmp     eax, OP_SEL
    je      .Lop_sel
    jmp     .Lop_scalar                 # pow mod sin cos noise rand
.Lop_next:
    add     r12, IN_SZ
    dec     r13d
    jmp     .Lfj_ins

.Lop_const:
    movss   xmm0, [r12+8]
    shufps  xmm0, xmm0, 0
1:  movaps  [rbx], xmm0
    add     rbx, 16
    dec     ecx
    jnz     1b
    jmp     .Lop_next
.Lop_load:                              # px py pz nx ny nz index
    sub     eax, OP_PX
    lea     rsi, [rip+fv_ctx+FC_IN]
    mov     rsi, [rsi+rax*8]
    test    rsi, rsi
    jz      .Lop_zero
    mov     edx, [rsp+8]
    lea     rsi, [rsi+rdx*4]
    mov     ecx, [rsp+12]
    mov     rdi, rbx
    rep     movsd
    jmp     .Lop_next
.Lop_zero:
    xorps   xmm0, xmm0
1:  movaps  [rbx], xmm0
    add     rbx, 16
    dec     ecx
    jnz     1b
    jmp     .Lop_next
.macro BINOP name, insn
\name:
1:  movaps  xmm0, [r14]
    \insn   xmm0, [r15]
    movaps  [rbx], xmm0
    add     r14, 16
    add     r15, 16
    add     rbx, 16
    dec     ecx
    jnz     1b
    jmp     .Lop_next
.endm
    BINOP   .Lop_add, addps
    BINOP   .Lop_sub, subps
    BINOP   .Lop_mul, mulps
    BINOP   .Lop_min, minps
    BINOP   .Lop_max, maxps
.Lop_div:                               # (0 where b is 0)
1:  movaps  xmm0, [r14]
    movaps  xmm1, [r15]
    xorps   xmm2, xmm2
    cmpneqps xmm2, xmm1
    divps   xmm0, xmm1
    andps   xmm0, xmm2
    movaps  [rbx], xmm0
    add     r14, 16
    add     r15, 16
    add     rbx, 16
    dec     ecx
    jnz     1b
    jmp     .Lop_next
.Lop_lt:
1:  movaps  xmm0, [r14]
    cmpltps xmm0, [r15]
    andps   xmm0, [rip+fv_ones]
    movaps  [rbx], xmm0
    add     r14, 16
    add     r15, 16
    add     rbx, 16
    dec     ecx
    jnz     1b
    jmp     .Lop_next
.Lop_gt:
1:  movaps  xmm0, [r15]
    cmpltps xmm0, [r14]
    andps   xmm0, [rip+fv_ones]
    movaps  [rbx], xmm0
    add     r14, 16
    add     r15, 16
    add     rbx, 16
    dec     ecx
    jnz     1b
    jmp     .Lop_next
.Lop_abs:
1:  movaps  xmm0, [r14]
    andps   xmm0, [rip+fv_abs]
    movaps  [rbx], xmm0
    add     r14, 16
    add     rbx, 16
    dec     ecx
    jnz     1b
    jmp     .Lop_next
.Lop_sqrt:
1:  movaps  xmm0, [r14]
    xorps   xmm1, xmm1
    maxps   xmm0, xmm1
    sqrtps  xmm0, xmm0
    movaps  [rbx], xmm0
    add     r14, 16
    add     rbx, 16
    dec     ecx
    jnz     1b
    jmp     .Lop_next
.Lop_floor:
1:  roundps xmm0, [r14], 1
    movaps  [rbx], xmm0
    add     r14, 16
    add     rbx, 16
    dec     ecx
    jnz     1b
    jmp     .Lop_next
.Lop_mov:
1:  movaps  xmm0, [r14]
    movaps  [rbx], xmm0
    add     r14, 16
    add     rbx, 16
    dec     ecx
    jnz     1b
    jmp     .Lop_next
.Lop_sel:                               # c > 0.5 ? a : b
    movzx   eax, byte ptr [r12+4]
    shl     eax, 10
    add     rax, rbp
1:  movaps  xmm2, [rax]
    movaps  xmm3, [rip+fv_ones]
    mulps   xmm3, [rip+fv_halfs]
    cmpltps xmm3, xmm2                  # 0.5 < c
    movaps  xmm0, [r14]
    andps   xmm0, xmm3
    andnps  xmm3, [r15]
    orps    xmm0, xmm3
    movaps  [rbx], xmm0
    add     r14, 16
    add     r15, 16
    add     rbx, 16
    add     rax, 16
    dec     ecx
    jnz     1b
    jmp     .Lop_next

# the per-element ones: pow, mod, sin, cos, noise, rand
.Lop_scalar:
    mov     [rsp+20], eax
    xor     r8d, r8d
.Lsc_el:
    cmp     r8d, [rsp+12]
    jae     .Lop_next
    mov     [rsp+24], r8d
    movss   xmm0, [r14+r8*4]
    movss   xmm1, [r15+r8*4]
    mov     eax, [rsp+20]
    cmp     eax, OP_POW
    je      .Lsc_pow
    cmp     eax, OP_MOD
    je      .Lsc_mod
    cmp     eax, OP_SIN
    je      .Lsc_sin
    cmp     eax, OP_COS
    je      .Lsc_cos
    cmp     eax, OP_NOISE
    je      .Lsc_noise
    cmp     eax, OP_RAND
    je      .Lsc_rand
    xorps   xmm0, xmm0
    jmp     .Lsc_put
.Lsc_pow:                               # a^b = 2^(b log2 a), a > 0 (else 0)
    xorps   xmm2, xmm2
    comiss  xmm0, xmm2
    jbe     .Lsc_zero
    movss   [rsp+28], xmm1
    movss   [rsp+32], xmm0
    fld     dword ptr [rsp+28]
    fld     dword ptr [rsp+32]
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
    fstp    dword ptr [rsp+28]
    movss   xmm0, [rsp+28]
    jmp     .Lsc_put
.Lsc_zero:
    xorps   xmm0, xmm0
    jmp     .Lsc_put
.Lsc_mod:                               # a - b floor(a / b)
    xorps   xmm2, xmm2
    comiss  xmm1, xmm2
    je      .Lsc_zero
    movss   xmm2, xmm0
    divss   xmm2, xmm1
    roundss xmm2, xmm2, 1
    mulss   xmm2, xmm1
    subss   xmm0, xmm2
    jmp     .Lsc_put
.Lsc_sin:
    movss   [rsp+28], xmm0
    fld     dword ptr [rsp+28]
    fsin
    fstp    dword ptr [rsp+28]
    movss   xmm0, [rsp+28]
    jmp     .Lsc_put
.Lsc_cos:
    movss   [rsp+28], xmm0
    fld     dword ptr [rsp+28]
    fcos
    fstp    dword ptr [rsp+28]
    movss   xmm0, [rsp+28]
    jmp     .Lsc_put
.Lsc_noise:                             # fbm(a, b, c + offsets)
    movzx   eax, byte ptr [r12+4]
    shl     eax, 10
    add     rax, rbp
    cvttss2si ecx, [r12+20]             # offset set 0..2
    and     ecx, 3
    cmp     ecx, 2
    jbe     1f
    xor     ecx, ecx
1:  lea     ecx, [rcx+rcx*2]
    lea     rdx, [rip+fv_noff]
    addss   xmm0, [rdx+rcx*4]
    addss   xmm1, [rdx+rcx*4+4]
    movss   xmm2, [rax+r8*4]
    addss   xmm2, [rdx+rcx*4+8]
    movss   [rsp+32], xmm0
    movss   [rsp+36], xmm1
    movss   [rsp+40], xmm2
    lea     rdi, [rsp+32]
    movss   xmm0, [r12+8]               # scale, detail, roughness
    cvttss2si ecx, [r12+12]
    movss   xmm1, [r12+16]
    call    fbm
    mov     r8d, [rsp+24]
    jmp     .Lsc_put
.Lsc_rand:                              # hash(index, seed) -> min..max
    cvttss2si eax, xmm0
    cvttss2si edx, [r12+8]
    imul    eax, eax, 0x27d4eb2d
    imul    edx, edx, 0x165667b1
    xor     eax, edx
    mov     edx, eax
    shr     edx, 15
    xor     eax, edx
    imul    eax, eax, 0x2c1b3c6d
    mov     edx, eax
    shr     edx, 12
    xor     eax, edx
    imul    eax, eax, 0x297a2d39
    mov     edx, eax
    shr     edx, 15
    xor     eax, edx
    shr     eax, 8
    cvtsi2ss xmm0, eax
    mulss   xmm0, [rip+fv_inv24]
    movss   xmm1, [r12+16]              # min + (max - min) u
    subss   xmm1, [r12+12]
    mulss   xmm0, xmm1
    addss   xmm0, [r12+12]
.Lsc_put:
    mov     r8d, [rsp+24]
    movss   [rbx+r8*4], xmm0
    inc     r8d
    jmp     .Lsc_el

.Lfj_outs:                              # the block's results out
    xor     r13d, r13d
1:  cmp     r13d, [rip+fv_ctx+FC_NOUT]
    jae     .Lfj_next
    mov     eax, r13d
    shl     eax, 4
    lea     rdx, [rip+fv_ctx+FC_OUT]
    mov     ecx, [rdx+rax]              # register
    mov     rdi, [rdx+rax+8]            # destination array
    shl     ecx, 10
    lea     rsi, [rbp+rcx]
    mov     eax, [rsp+8]
    lea     rdi, [rdi+rax*4]
    mov     ecx, [rsp+12]
    rep     movsd
    inc     r13d
    jmp     1b
.Lfj_next:
    inc     dword ptr [rsp]
    jmp     .Lfj_block
.Lfj_out:
    add     rsp, 56
    pop     rbp
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

.section .rodata
.align 16
fv_halfs:       .float 0.5, 0.5, 0.5, 0.5

.section .note.GNU-stack,"",@progbits
