# =============================================================================
#  BeeModel - a template JIT for field programs (fieldvm.s).
#
#  A hot program (enough elements) is compiled once to x86-64: one loop over
#  a block of 256 elements, 8 lanes at a time with AVX (4 with SSE where the
#  CPU or the OS has no AVX), each VM instruction copied from a template
#  assembled below, its placeholders (register offsets, immediates, input /
#  output slots, call targets) patched. The VM's registers stay in the
#  thread's frame (64 x 4 groups x 32 bytes: L1; four groups side by side
#  keep chains of dependent instructions from stalling), inputs and outputs go straight to
#  their arrays, the transcendentals call the interpreter's own per-element
#  function, so both give the same bits. Code goes to fresh pages written,
#  then made executable (never both); compiled programs are kept by a hash
#  of their instructions, outputs and mode. BEEMODEL_JIT=0 turns it off,
#  =sse keeps to SSE. The self-test runs random programs through the VM and
#  each path and compares every output bit.
# =============================================================================
.intel_syntax noprefix
.include "const.inc"

.globl fvj_get
.globl fvj_mode
.globl fvj_avx
.globl fvj_compiles

.equ IN_SZ,     24
.equ FC_N,      0
.equ FC_PROG,   8
.equ FC_NINS,   16
.equ FC_IN,     24
.equ FC_NOUT,   80
.equ FC_OUT,    88
.equ OP_CONST,  1
.equ OP_PX,     2
.equ OP_INDEX,  8
.equ OP_ADD,    10
.equ OP_SUB,    11
.equ OP_MUL,    12
.equ OP_DIV,    13
.equ OP_MIN,    14
.equ OP_MAX,    15
.equ OP_LT,     16
.equ OP_GT,     17
.equ OP_ABS,    20
.equ OP_SQRT,   21
.equ OP_FLOOR,  22
.equ OP_MOV,    28
.equ OP_SEL,    29
.equ FVJ_CACHE, 32
.equ P_A,       0x11111111
.equ P_B,       0x22222222
.equ P_D,       0x33333333
.equ P_C,       0x44444444
.equ P_IMM,     0x55555555
.equ P_DISP,    0x66666666
.equ P_E,       0x12121212              # the group's byte offset
.equ FVJ_U,     8                       # groups interleaved (independent chains)
.equ P_JNZ,     0x3c3c3c3c
.equ PROT_RX,   5
.equ MAP_ANON_PRIV, 0x22
.equ SYS_MPROTECT, 10

.section .data
.align 4
fvj_mode:       .long -1                # -1 not decided, 0 off, 1 SSE, 2 AVX
fvj_avx:        .long 0                 # the CPU and OS can run AVX

.section .rodata
.align 32
fvj_k:          .float 1, 1, 1, 1, 1, 1, 1, 1                   # ones
                .float 0.5, 0.5, 0.5, 0.5, 0.5, 0.5, 0.5, 0.5   # halves
                .long 0x7fffffff, 0x7fffffff, 0x7fffffff, 0x7fffffff
                .long 0x7fffffff, 0x7fffffff, 0x7fffffff, 0x7fffffff
s_env_jit:      .asciz "BEEMODEL_JIT="
.align 8
fvj_q1:         .quad 0x7777777777777777    # placeholders: 64-bit values
fvj_q2:         .quad 0x5A5A5A5A5A5A5A5A

.section .bss
.align 8
fvj_cache:      .skip FVJ_CACHE*32      # hash, mode, entry, mapping, size
fvj_next:       .skip 4                 # (round robin)
fvj_compiles:   .skip 4                 # programs compiled (for tests)
fvj_pos:        .skip 8                 # emitting here
fvj_end:        .skip 8
pv_a:           .skip 4                 # the patch values
pv_b:           .skip 4
pv_c:           .skip 4
pv_d:           .skip 4
pv_imm:         .skip 4
pv_disp:        .skip 4
pv_e:           .skip 4
pv_q1:          .skip 8
pv_q2:          .skip 8
.text

# -----------------------------------------------------------------------------
# Templates (copied, not run here). rbp = the frame, r12 = the element,
# r13 = groups left, r14 = the context, r15 = the constants.
# -----------------------------------------------------------------------------
.macro TPL name
    .globl \name
\name:
.endm

TPL t_pro
    push    rbx
    push    rbp
    push    r12
    push    r13
    push    r14
    push    r15
    sub     rsp, 8
    mov     rbp, rdi
    mov     r12d, esi
    mov     r14, rdx
    mov     r13d, P_IMM
    movabs  r15, 0x5A5A5A5A5A5A5A5A
TPL t_pro_end

TPL t_epi_avx
    vzeroupper
TPL t_epi
    add     rsp, 8
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbp
    pop     rbx
    ret
TPL t_epi_end

# ---- AVX: 8 lanes, a register is 32 bytes ------------------------------------
TPL a_const
    mov     eax, P_IMM
    vmovd   xmm0, eax
    vshufps xmm0, xmm0, xmm0, 0
    vinsertf128 ymm0, ymm0, xmm0, 1
    vmovaps [rbp+P_D], ymm0
TPL a_load
    mov     rax, [r14+P_DISP]
    test    rax, rax
    jz      1f
    vmovups ymm0, [rax+r12*4+P_E]
    jmp     2f
1:  vxorps  ymm0, ymm0, ymm0
2:  vmovaps [rbp+P_D], ymm0
.macro ABIN name, insn
TPL \name
    vmovaps ymm0, [rbp+P_A]
    \insn   ymm0, ymm0, [rbp+P_B]
    vmovaps [rbp+P_D], ymm0
.endm
    ABIN    a_add, vaddps
    ABIN    a_sub, vsubps
    ABIN    a_mul, vmulps
    ABIN    a_min, vminps
    ABIN    a_max, vmaxps
TPL a_div
    vmovaps ymm0, [rbp+P_A]
    vmovaps ymm1, [rbp+P_B]
    vxorps  ymm2, ymm2, ymm2
    vcmpneqps ymm2, ymm2, ymm1
    vdivps  ymm0, ymm0, ymm1
    vandps  ymm0, ymm0, ymm2
    vmovaps [rbp+P_D], ymm0
TPL a_lt
    vmovaps ymm0, [rbp+P_A]
    vcmpltps ymm0, ymm0, [rbp+P_B]
    vandps  ymm0, ymm0, [r15]
    vmovaps [rbp+P_D], ymm0
TPL a_gt
    vmovaps ymm0, [rbp+P_B]
    vcmpltps ymm0, ymm0, [rbp+P_A]
    vandps  ymm0, ymm0, [r15]
    vmovaps [rbp+P_D], ymm0
TPL a_abs
    vmovaps ymm0, [rbp+P_A]
    vandps  ymm0, ymm0, [r15+64]
    vmovaps [rbp+P_D], ymm0
TPL a_sqrt
    vmovaps ymm0, [rbp+P_A]
    vxorps  ymm1, ymm1, ymm1
    vmaxps  ymm0, ymm0, ymm1
    vsqrtps ymm0, ymm0
    vmovaps [rbp+P_D], ymm0
TPL a_floor
    vroundps ymm0, [rbp+P_A], 1
    vmovaps [rbp+P_D], ymm0
TPL a_mov
    vmovaps ymm0, [rbp+P_A]
    vmovaps [rbp+P_D], ymm0
TPL a_sel
    vmovaps ymm2, [rbp+P_C]
    vmovaps ymm3, [r15+32]
    vcmpltps ymm3, ymm3, ymm2
    vandps  ymm0, ymm3, [rbp+P_A]
    vandnps ymm3, ymm3, [rbp+P_B]
    vorps   ymm0, ymm0, ymm3
    vmovaps [rbp+P_D], ymm0
TPL a_call
    vzeroupper
    movabs  rdi, 0x7777777777777777
    lea     rsi, [rbp+P_E]
    mov     edx, 8
    mov     ecx, 32*FVJ_U
    movabs  rax, 0x5A5A5A5A5A5A5A5A
    call    rax
TPL a_out
    mov     rax, [r14+P_DISP]
    vmovaps ymm0, [rbp+P_A]
    vmovups [rax+r12*4+P_E], ymm0
TPL a_tail
    add     r12d, 8*FVJ_U
    dec     r13d
    .byte   0x0f, 0x85
    .long   P_JNZ
TPL a_end
    int3                                # (a_end must not be s_const's address)

# ---- SSE: 4 lanes, a register is 16 bytes ------------------------------------
TPL s_const
    mov     eax, P_IMM
    movd    xmm0, eax
    shufps  xmm0, xmm0, 0
    movaps  [rbp+P_D], xmm0
TPL s_load
    mov     rax, [r14+P_DISP]
    test    rax, rax
    jz      1f
    movups  xmm0, [rax+r12*4+P_E]
    jmp     2f
1:  xorps   xmm0, xmm0
2:  movaps  [rbp+P_D], xmm0
.macro SBIN name, insn
TPL \name
    movaps  xmm0, [rbp+P_A]
    \insn   xmm0, [rbp+P_B]
    movaps  [rbp+P_D], xmm0
.endm
    SBIN    s_add, addps
    SBIN    s_sub, subps
    SBIN    s_mul, mulps
    SBIN    s_min, minps
    SBIN    s_max, maxps
TPL s_div
    movaps  xmm0, [rbp+P_A]
    movaps  xmm1, [rbp+P_B]
    xorps   xmm2, xmm2
    cmpneqps xmm2, xmm1
    divps   xmm0, xmm1
    andps   xmm0, xmm2
    movaps  [rbp+P_D], xmm0
TPL s_lt
    movaps  xmm0, [rbp+P_A]
    cmpltps xmm0, [rbp+P_B]
    andps   xmm0, [r15]
    movaps  [rbp+P_D], xmm0
TPL s_gt
    movaps  xmm0, [rbp+P_B]
    cmpltps xmm0, [rbp+P_A]
    andps   xmm0, [r15]
    movaps  [rbp+P_D], xmm0
TPL s_abs
    movaps  xmm0, [rbp+P_A]
    andps   xmm0, [r15+64]
    movaps  [rbp+P_D], xmm0
TPL s_sqrt
    movaps  xmm0, [rbp+P_A]
    xorps   xmm1, xmm1
    maxps   xmm0, xmm1
    sqrtps  xmm0, xmm0
    movaps  [rbp+P_D], xmm0
TPL s_floor
    roundps xmm0, [rbp+P_A], 1
    movaps  [rbp+P_D], xmm0
TPL s_mov
    movaps  xmm0, [rbp+P_A]
    movaps  [rbp+P_D], xmm0
TPL s_sel
    movaps  xmm2, [rbp+P_C]
    movaps  xmm3, [r15+32]
    cmpltps xmm3, xmm2
    movaps  xmm0, [rbp+P_A]
    andps   xmm0, xmm3
    andnps  xmm3, [rbp+P_B]
    orps    xmm0, xmm3
    movaps  [rbp+P_D], xmm0
TPL s_call
    movabs  rdi, 0x7777777777777777
    lea     rsi, [rbp+P_E]
    mov     edx, 4
    mov     ecx, 16*FVJ_U
    movabs  rax, 0x5A5A5A5A5A5A5A5A
    call    rax
TPL s_out
    mov     rax, [r14+P_DISP]
    movaps  xmm0, [rbp+P_A]
    movups  [rax+r12*4+P_E], xmm0
TPL s_tail
    add     r12d, 4*FVJ_U
    dec     r13d
    .byte   0x0f, 0x85
    .long   P_JNZ
TPL s_end

.section .rodata
.align 8
# per op (0..31): AVX template, SSE template (0: the call)
fvj_tpl:
    .quad 0, 0                          # 0
    .quad a_const, s_const              # 1 const
    .quad a_load, s_load                # 2..8 px py pz nx ny nz index
    .quad a_load, s_load
    .quad a_load, s_load
    .quad a_load, s_load
    .quad a_load, s_load
    .quad a_load, s_load
    .quad a_load, s_load
    .quad 0, 0                          # 9
    .quad a_add, s_add                  # 10
    .quad a_sub, s_sub
    .quad a_mul, s_mul
    .quad a_div, s_div
    .quad a_min, s_min
    .quad a_max, s_max
    .quad a_lt, s_lt
    .quad a_gt, s_gt                    # 17
    .quad 0, 0                          # 18 pow
    .quad 0, 0                          # 19 mod
    .quad a_abs, s_abs                  # 20
    .quad a_sqrt, s_sqrt
    .quad a_floor, s_floor              # 22
    .quad 0, 0                          # 23 sin
    .quad 0, 0                          # 24 cos
    .quad 0, 0                          # 25
    .quad 0, 0                          # 26 noise
    .quad 0, 0                          # 27 rand
    .quad a_mov, s_mov                  # 28
    .quad a_sel, s_sel                  # 29
    .quad 0, 0
    .quad 0, 0
# the template that follows each one (its end)
fvj_ends:       .quad a_const, a_load, a_add, a_sub, a_mul, a_min, a_max, a_div
                .quad a_lt, a_gt, a_abs, a_sqrt, a_floor, a_mov, a_sel, a_call
                .quad a_out, a_tail, a_end
                .quad s_const, s_load, s_add, s_sub, s_mul, s_min, s_max, s_div
                .quad s_lt, s_gt, s_abs, s_sqrt, s_floor, s_mov, s_sel, s_call
                .quad s_out, s_tail, s_end, 0
.text

# tpl_end(rsi=template) -> rdx = where it ends (the next template)
tpl_end:
    lea     rax, [rip+fvj_ends]
1:  mov     rdx, [rax]
    test    rdx, rdx
    jz      9f
    cmp     rdx, rsi
    je      2f
    add     rax, 8
    jmp     1b
2:  mov     rdx, [rax+8]
9:  ret

# -----------------------------------------------------------------------------
# Emitting
# -----------------------------------------------------------------------------
# emit(rsi=template start, rdx=end) - copied to fvj_pos, placeholders
#   patched from pv_*; 0 room left: nothing (fvj_pos passes fvj_end)
emit:
    mov     rdi, [rip+fvj_pos]
    mov     rcx, rdx
    sub     rcx, rsi
    lea     rax, [rdi+rcx]
    cmp     rax, [rip+fvj_end]
    ja      8f
    push    rdi
    rep     movsb
    pop     rsi                         # the copy
    mov     [rip+fvj_pos], rdi
    lea     rdx, [rdi-3]                # scan it
1:  cmp     rsi, rdx
    jae     9f
    lea     rax, [rsi+8]                # 64-bit ones first
    cmp     rax, rdi
    ja      3f
    mov     rax, [rsi]
    cmp     rax, [rip+fvj_q1]
    jne     2f
    mov     rax, [rip+pv_q1]
    mov     [rsi], rax
    add     rsi, 8
    jmp     1b
2:  cmp     rax, [rip+fvj_q2]
    jne     3f
    mov     rax, [rip+pv_q2]
    mov     [rsi], rax
    add     rsi, 8
    jmp     1b
3:  mov     eax, [rsi]
    lea     rcx, [rip+pv_a]
    cmp     eax, P_A
    je      4f
    lea     rcx, [rip+pv_b]
    cmp     eax, P_B
    je      4f
    lea     rcx, [rip+pv_c]
    cmp     eax, P_C
    je      4f
    lea     rcx, [rip+pv_d]
    cmp     eax, P_D
    je      4f
    lea     rcx, [rip+pv_imm]
    cmp     eax, P_IMM
    je      4f
    lea     rcx, [rip+pv_disp]
    cmp     eax, P_DISP
    je      4f
    lea     rcx, [rip+pv_e]
    cmp     eax, P_E
    je      4f
    inc     rsi
    jmp     1b
4:  mov     eax, [rcx]
    mov     [rsi], eax
    add     rsi, 4
    jmp     1b
8:  mov     rax, [rip+fvj_end]          # (full: mark it)
    inc     rax
    mov     [rip+fvj_pos], rax
9:  ret

# fvj_scalar(rdi=instruction, rsi=the group in the frame, edx=lanes,
#   ecx=register stride) - the per-element ops for one group
fvj_scalar:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    mov     rbx, rdi
    mov     r12, rsi
    mov     r13d, edx
    mov     r14d, ecx                   # register stride
    xor     r15d, r15d
1:  cmp     r15d, r13d
    jae     9f
    movzx   eax, byte ptr [rbx+2]       # a b c of this lane
    imul    eax, r14d
    lea     rax, [rax+r15*4]
    movss   xmm0, [r12+rax]
    movzx   eax, byte ptr [rbx+3]
    imul    eax, r14d
    lea     rax, [rax+r15*4]
    movss   xmm1, [r12+rax]
    movzx   eax, byte ptr [rbx+4]
    imul    eax, r14d
    lea     rax, [rax+r15*4]
    movss   xmm2, [r12+rax]
    mov     rdi, rbx
    call    fv_scalar1
    movzx   eax, byte ptr [rbx+1]
    imul    eax, r14d
    lea     rax, [rax+r15*4]
    movss   [r12+rax], xmm0
    inc     r15d
    jmp     1b
9:  pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# fvj_detect - the mode: AVX when the CPU has it and the OS saves it, else
#   SSE; BEEMODEL_JIT=0 off, =sse SSE
fvj_detect:
    push    rbx
    xor     r8d, r8d
    mov     eax, 1
    cpuid
    mov     eax, ecx
    and     eax, (1 << 27) | (1 << 28)  # OSXSAVE, AVX
    cmp     eax, (1 << 27) | (1 << 28)
    jne     1f
    xor     ecx, ecx
    xgetbv
    and     eax, 6                      # XMM and YMM state
    cmp     eax, 6
    jne     1f
    mov     r8d, 1
1:  mov     [rip+fvj_avx], r8d
    lea     eax, [r8+1]
    mov     [rip+fvj_mode], eax
    lea     rdi, [rip+s_env_jit]
    call    getenv
    test    rax, rax
    jz      9f
    cmp     byte ptr [rax], '0'
    jne     2f
    mov     dword ptr [rip+fvj_mode], 0
2:  cmp     byte ptr [rax], 's'
    jne     9f
    mov     dword ptr [rip+fvj_mode], 1
9:  pop     rbx
    ret

# fvj_hash -> rax = FNV-1a of fv_ctx's program, outputs and the mode
fvj_hash:
    mov     rax, 0xcbf29ce484222325
    mov     r8, 0x100000001b3
    mov     rsi, [rip+fv_ctx+FC_PROG]
    mov     ecx, [rip+fv_ctx+FC_NINS]
    imul    ecx, ecx, IN_SZ
1:  test    ecx, ecx
    jz      2f
    movzx   edx, byte ptr [rsi]
    xor     rax, rdx
    imul    rax, r8
    inc     rsi
    dec     ecx
    jmp     1b
2:  mov     ecx, [rip+fv_ctx+FC_NOUT]
    xor     edx, edx
3:  cmp     edx, ecx
    jae     4f
    mov     r9d, edx
    shl     r9d, 4
    lea     r10, [rip+fv_ctx+FC_OUT]
    mov     r9d, [r10+r9]
    xor     rax, r9
    imul    rax, r8
    inc     edx
    jmp     3b
4:  mov     edx, [rip+fvj_mode]
    xor     rax, rdx
    imul    rax, r8
    mov     edx, [rip+fv_ctx+FC_NINS]
    xor     rax, rdx
    imul    rax, r8
    ret

# fvj_get -> rax = fv_ctx's program compiled for this machine (cached), or
#   0 (off, or not compiled)
fvj_get:
    push    rbx
    push    r12
    push    r13
    cmp     dword ptr [rip+fvj_mode], 0
    jge     1f
    call    fvj_detect
1:  xor     eax, eax
    cmp     dword ptr [rip+fvj_mode], 0
    jle     9f
    cmp     dword ptr [rip+fv_ctx+FC_NINS], 0
    je      9f
    cmp     dword ptr [rip+fv_ctx+FC_NOUT], 8
    ja      9f
    call    fvj_hash
    mov     r12, rax
    lea     rbx, [rip+fvj_cache]
    xor     ecx, ecx
2:  cmp     ecx, FVJ_CACHE
    jae     3f
    mov     rdx, rcx
    shl     rdx, 5
    cmp     qword ptr [rbx+rdx+16], 0
    je      21f
    cmp     [rbx+rdx], r12
    jne     21f
    mov     eax, [rip+fvj_mode]
    cmp     [rbx+rdx+8], eax
    jne     21f
    mov     rax, [rbx+rdx+16]
    jmp     9f
21: inc     ecx
    jmp     2b
3:  call    fvj_compile                 # (rax = entry, rdx = mapping size)
    test    rax, rax
    jz      9f
    mov     r13, rax
    mov     ecx, [rip+fvj_next]         # into the next slot (its old code goes)
    inc     dword ptr [rip+fvj_next]
    and     ecx, FVJ_CACHE-1
    shl     rcx, 5
    add     rbx, rcx
    push    rdx
    sub     rsp, 8
    mov     rdi, [rbx+24]
    test    rdi, rdi
    jz      4f
    mov     rsi, [rbx+8]
    shr     rsi, 32
    shl     rsi, 12
    mov     eax, SYS_MUNMAP
    syscall
4:  add     rsp, 8
    pop     rdx
    mov     [rbx], r12
    mov     eax, [rip+fvj_mode]
    shr     rdx, 12                     # (pages, kept beside the mode)
    shl     rdx, 32
    or      rax, rdx
    mov     [rbx+8], rax
    mov     [rbx+16], r13
    mov     rax, [rip+fvj_mapped]
    mov     [rbx+24], rax
    mov     rax, r13
9:  pop     r13
    pop     r12
    pop     rbx
    ret

# fvj_compile -> rax = the entry (0: failed), rdx = the mapping's size.
#   The mapping: the instructions (copied: the calls read their immediates),
#   then the code. Each instruction is emitted for FVJ_U groups side by side
#   (register r, group k at r * stride + k * group size).
fvj_compile:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    push    rbp
    sub     rsp, 40
    mov     r12d, [rip+fv_ctx+FC_NINS]
    cmp     r12d, 4096
    ja      .Lfc_fail
    imul    esi, r12d, IN_SZ+128*FVJ_U  # instructions + code (generous)
    add     esi, 4096+1024+4095
    and     esi, -4096
    mov     [rsp], rsi
    xor     edi, edi
    mov     edx, PROT_RW
    mov     r10d, MAP_ANON_PRIV
    mov     r8, -1
    xor     r9d, r9d
    mov     eax, SYS_MMAP
    syscall
    cmp     rax, -4096
    jae     .Lfc_fail
    mov     rbx, rax                    # the mapping
    mov     [rip+fvj_mapped], rax
    mov     rdi, rax                    # the instructions
    mov     rsi, [rip+fv_ctx+FC_PROG]
    imul    ecx, r12d, IN_SZ
    rep     movsb
    add     rdi, 15
    and     rdi, -16
    mov     [rip+fvj_pos], rdi
    mov     r15, rdi                    # the entry
    mov     rax, rbx
    add     rax, [rsp]
    mov     [rip+fvj_end], rax
    xor     r14d, r14d                  # 0 AVX, 1 SSE (template column)
    mov     dword ptr [rsp+16], 32      # a group's bytes
    mov     r13d, 8                     # lanes
    cmp     dword ptr [rip+fvj_mode], 2
    je      1f
    mov     r14d, 1
    mov     dword ptr [rsp+16], 16
    mov     r13d, 4
1:  mov     ebp, [rsp+16]               # register stride
    imul    ebp, ebp, FVJ_U
    mov     eax, 256/FVJ_U              # the prologue: loops, constants
    xor     edx, edx
    div     r13d
    mov     [rip+pv_imm], eax
    lea     rax, [rip+fvj_k]
    mov     [rip+pv_q2], rax
    lea     rsi, [rip+t_pro]
    lea     rdx, [rip+t_pro_end]
    call    emit
    mov     rax, [rip+fvj_pos]
    mov     [rsp+8], rax                # the loop
    xor     r12d, r12d
.Lfc_ins:
    cmp     r12d, [rip+fv_ctx+FC_NINS]
    jae     .Lfc_outs
    mov     dword ptr [rsp+20], 0       # group
.Lfc_grp:
    cmp     dword ptr [rsp+20], FVJ_U
    jae     .Lfc_nins
    mov     r8d, [rsp+20]
    imul    r8d, [rsp+16]               # the group's offset
    mov     [rip+pv_e], r8d
    imul    rax, r12, IN_SZ
    lea     rcx, [rbx+rax]              # (the instruction's copy)
    movzx   eax, byte ptr [rcx+1]       # the register offsets
    imul    eax, ebp
    add     eax, r8d
    mov     [rip+pv_d], eax
    movzx   eax, byte ptr [rcx+2]
    imul    eax, ebp
    add     eax, r8d
    mov     [rip+pv_a], eax
    movzx   eax, byte ptr [rcx+3]
    imul    eax, ebp
    add     eax, r8d
    mov     [rip+pv_b], eax
    movzx   eax, byte ptr [rcx+4]
    imul    eax, ebp
    add     eax, r8d
    mov     [rip+pv_c], eax
    mov     eax, [rcx+8]
    mov     [rip+pv_imm], eax
    movzx   eax, byte ptr [rcx]         # op
    lea     edx, [rax-OP_PX]            # (loads: their slot)
    lea     edx, [rdx*8+FC_IN]
    mov     [rip+pv_disp], edx
    cmp     eax, 32
    jae     .Lfc_call
    shl     eax, 4
    lea     rdx, [rip+fvj_tpl]
    add     rdx, rax
    mov     rsi, [rdx+r14*8]
    test    rsi, rsi
    jz      .Lfc_call
    call    tpl_end
    call    emit
    jmp     .Lfc_ngrp
.Lfc_call:
    mov     [rip+pv_q1], rcx
    lea     rax, [rip+fvj_scalar]
    mov     [rip+pv_q2], rax
    lea     rsi, [rip+a_call]
    test    r14d, r14d
    jz      2f
    lea     rsi, [rip+s_call]
2:  call    tpl_end
    call    emit
.Lfc_ngrp:
    inc     dword ptr [rsp+20]
    jmp     .Lfc_grp
.Lfc_nins:
    inc     r12d
    jmp     .Lfc_ins
.Lfc_outs:
    xor     r12d, r12d
3:  cmp     r12d, [rip+fv_ctx+FC_NOUT]
    jae     4f
    mov     dword ptr [rsp+20], 0
33: cmp     dword ptr [rsp+20], FVJ_U
    jae     34f
    mov     r8d, [rsp+20]
    imul    r8d, [rsp+16]
    mov     [rip+pv_e], r8d
    mov     eax, r12d
    shl     eax, 4
    lea     rdx, [rip+fv_ctx+FC_OUT]
    mov     ecx, [rdx+rax]
    imul    ecx, ebp
    add     ecx, r8d
    mov     [rip+pv_a], ecx
    lea     eax, [rax+FC_OUT+8]
    mov     [rip+pv_disp], eax
    lea     rsi, [rip+a_out]
    test    r14d, r14d
    jz      31f
    lea     rsi, [rip+s_out]
31: call    tpl_end
    call    emit
    inc     dword ptr [rsp+20]
    jmp     33b
34: inc     r12d
    jmp     3b
4:  lea     rsi, [rip+a_tail]           # the loop's end, back to its start
    test    r14d, r14d
    jz      41f
    lea     rsi, [rip+s_tail]
41: call    tpl_end
    call    emit
    mov     rax, [rip+fvj_pos]
    cmp     rax, [rip+fvj_end]
    ja      .Lfc_unmap
    mov     rcx, [rsp+8]
    sub     rcx, rax
    mov     [rax-4], ecx
    lea     rsi, [rip+t_epi_avx]
    test    r14d, r14d
    jz      42f
    lea     rsi, [rip+t_epi]
42: lea     rdx, [rip+t_epi_end]
    call    emit
    mov     rax, [rip+fvj_pos]
    cmp     rax, [rip+fvj_end]
    ja      .Lfc_unmap
    mov     rdi, rbx                    # now executable (and no longer writable)
    mov     rsi, [rsp]
    mov     edx, PROT_RX
    mov     eax, SYS_MPROTECT
    syscall
    test    rax, rax
    jnz     .Lfc_unmap
    inc     dword ptr [rip+fvj_compiles]
    mov     rax, r15
    mov     rdx, [rsp]
    jmp     .Lfc_out
.Lfc_unmap:
    mov     rdi, rbx
    mov     rsi, [rsp]
    mov     eax, SYS_MUNMAP
    syscall
.Lfc_fail:
    xor     eax, eax
    xor     edx, edx
.Lfc_out:
    add     rsp, 40
    pop     rbp
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

.section .bss
.align 8
fvj_mapped:     .skip 8
.text

# =============================================================================
#  Self-test: random programs through the VM and each JIT path, bit for bit
# =============================================================================
.globl fvj_selftest
.globl fvj_bench

.equ TN,        1300                    # elements (5 whole blocks and a part)
.equ TK,        28                      # random instructions a program
.equ TPROGS,    150

.section .rodata
.align 4
ft_ops:         .byte 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22, 23, 24, 26, 27, 28, 29, 10
ft_n100:        .float 0.01
ft_scale:       .float 0.5
ft_three:       .float 3.0
ft_half:        .float 0.5
ft_seed:        .float 7.0
ft_m1:          .float -1.0
ft_one:         .float 1.0
ft_bench:       .byte 10, 12, 14, 15, 11, 21, 20, 13, 22, 29

.section .bss
.align 16
ft_prog:        .skip 128*IN_SZ
ft_mem:         .skip 8
ft_rng:         .skip 4
ft_fails:       .skip 4
ft_ts:          .skip 16
.text

ft_rand:
    mov     eax, [rip+ft_rng]
    mov     ecx, eax
    shl     ecx, 13
    xor     eax, ecx
    mov     ecx, eax
    shr     ecx, 17
    xor     eax, ecx
    mov     ecx, eax
    shl     ecx, 5
    xor     eax, ecx
    mov     [rip+ft_rng], eax
    ret

# ft_rmod(edi=n) -> eax = random 0..n-1
ft_rmod:
    push    rdi
    call    ft_rand
    pop     rcx
    xor     edx, edx
    div     ecx
    mov     eax, edx
    ret

# ft_ctx(rdi=memory, esi=elements, edx=instructions, ecx=outputs) - fv_ctx
#   on the test arrays: 7 inputs, then outputs, n floats each
ft_ctx:
    mov     [rip+fv_ctx+FC_N], esi
    lea     rax, [rip+ft_prog]
    mov     [rip+fv_ctx+FC_PROG], rax
    mov     [rip+fv_ctx+FC_NINS], edx
    mov     [rip+fv_ctx+FC_NOUT], ecx
    mov     r8d, esi
    shl     r8, 2                       # bytes an array
    xor     eax, eax
1:  cmp     eax, 7
    jae     2f
    lea     rdx, [rip+fv_ctx+FC_IN]
    mov     [rdx+rax*8], rdi
    add     rdi, r8
    inc     eax
    jmp     1b
2:  ret

# ft_outs(rdi=first output array, esi=elements, edx=last register, ecx=count)
ft_outs:
    shl     rsi, 2
    xor     eax, eax
1:  cmp     eax, ecx
    jae     2f
    mov     r8d, eax
    shl     r8d, 4
    lea     r9, [rip+fv_ctx+FC_OUT]
    mov     r10d, edx
    sub     r10d, eax
    mov     [r9+r8], r10d
    mov     [r9+r8+8], rdi
    add     rdi, rsi
    inc     eax
    jmp     1b
2:  ret

# fvj_selftest -> eax = 1 when every output matched (and programs were
#   compiled), edx = programs tried
fvj_selftest:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    push    rbp
    sub     rsp, 24
    mov     ebp, [rip+fvj_mode]
    cmp     ebp, 0
    jge     1f
    call    fvj_detect
    mov     ebp, [rip+fvj_mode]
1:  mov     dword ptr [rip+ft_fails], 0
    mov     dword ptr [rip+ft_rng], 0x2545F491
    mov     esi, TN*4*16                # inputs, outputs (VM), outputs (JIT)
    add     esi, 4095
    and     esi, -4096
    xor     edi, edi
    mov     edx, PROT_RW
    mov     r10d, MAP_ANON_PRIV
    mov     r8, -1
    xor     r9d, r9d
    mov     eax, SYS_MMAP
    syscall
    cmp     rax, -4096
    jae     .Lft_bad
    mov     [rip+ft_mem], rax
    mov     rbx, rax
    xor     ecx, ecx                    # inputs: -10..10, the index
2:  cmp     ecx, TN*6
    jae     3f
    push    rcx
    mov     edi, 2001
    call    ft_rmod
    pop     rcx
    sub     eax, 1000
    cvtsi2ss xmm0, eax
    mulss   xmm0, [rip+ft_n100]
    movss   [rbx+rcx*4], xmm0
    inc     ecx
    jmp     2b
3:  xor     ecx, ecx
4:  cmp     ecx, TN
    jae     5f
    cvtsi2ss xmm0, ecx
    movss   [rbx+TN*24+rcx*4], xmm0
    inc     ecx
    jmp     4b
5:  mov     dword ptr [rsp], 0          # program
.Lft_prog:
    cmp     dword ptr [rsp], TPROGS
    jae     .Lft_done
    lea     rdi, [rip+ft_prog]          # loads, a constant, random ops
    xor     eax, eax
    mov     ecx, 128*IN_SZ
    rep     stosb
    lea     r12, [rip+ft_prog]
    xor     ecx, ecx
6:  cmp     ecx, 7
    jae     7f
    imul    rax, rcx, IN_SZ
    lea     edx, [rcx+OP_PX]
    mov     [r12+rax], dl
    mov     [r12+rax+1], cl
    inc     ecx
    jmp     6b
7:  mov     edi, 2001
    call    ft_rmod
    sub     eax, 1000
    cvtsi2ss xmm0, eax
    mulss   xmm0, [rip+ft_n100]
    mov     byte ptr [r12+7*IN_SZ], OP_CONST
    mov     byte ptr [r12+7*IN_SZ+1], 7
    movss   [r12+7*IN_SZ+8], xmm0
    mov     r13d, 8
8:  cmp     r13d, 8+TK
    jae     9f
    imul    r14, r13, IN_SZ
    add     r14, r12
    mov     edi, 20
    call    ft_rmod
    lea     rcx, [rip+ft_ops]
    movzx   eax, byte ptr [rcx+rax]
    mov     [r14], al
    mov     [r14+1], r13b
    mov     edi, r13d
    call    ft_rmod
    mov     [r14+2], al
    mov     edi, r13d
    call    ft_rmod
    mov     [r14+3], al
    mov     edi, r13d
    call    ft_rmod
    mov     [r14+4], al
    movzx   eax, byte ptr [r14]
    cmp     eax, 26                     # noise: scale, detail, roughness
    jne     81f
    mov     eax, [rip+ft_scale]
    mov     [r14+8], eax
    mov     eax, [rip+ft_three]
    mov     [r14+12], eax
    mov     eax, [rip+ft_half]
    mov     [r14+16], eax
    jmp     82f
81: cmp     eax, 27                     # random: seed, min, max
    jne     82f
    mov     eax, [rip+ft_seed]
    mov     [r14+8], eax
    mov     eax, [rip+ft_m1]
    mov     [r14+12], eax
    mov     eax, [rip+ft_one]
    mov     [r14+16], eax
82: inc     r13d
    jmp     8b
9:  mov     rdi, rbx                    # the VM
    mov     esi, TN
    mov     edx, 8+TK
    mov     ecx, 3
    call    ft_ctx
    lea     rdi, [rbx+TN*4*7]
    mov     esi, TN
    mov     edx, 8+TK-1
    mov     ecx, 3
    call    ft_outs
    mov     dword ptr [rip+fvj_mode], 0
    call    fv_run
    mov     r15d, 1                     # each path
.Lft_mode:
    cmp     r15d, 2
    ja      .Lft_next
    cmp     r15d, 2
    jne     10f
    cmp     dword ptr [rip+fvj_avx], 0
    je      .Lft_next
10: cmp     r15d, ebp                   # (not above what was asked for)
    ja      .Lft_next
    lea     rdi, [rbx+TN*4*10]
    mov     esi, TN
    mov     edx, 8+TK-1
    mov     ecx, 3
    call    ft_outs
    mov     [rip+fvj_mode], r15d
    call    fv_run
    lea     rsi, [rbx+TN*4*7]
    lea     rdi, [rbx+TN*4*10]
    mov     ecx, TN*3
    repe    cmpsd
    je      11f
    inc     dword ptr [rip+ft_fails]
11: inc     r15d
    jmp     .Lft_mode
.Lft_next:
    inc     dword ptr [rsp]
    jmp     .Lft_prog
.Lft_done:
    mov     [rip+fvj_mode], ebp
    mov     rdi, rbx
    mov     esi, TN*4*16
    add     esi, 4095
    and     esi, -4096
    mov     eax, SYS_MUNMAP
    syscall
    xor     eax, eax
    cmp     dword ptr [rip+ft_fails], 0
    jne     .Lft_out
    test    ebp, ebp                    # (off: nothing to compare, fine)
    jz      12f
    cmp     dword ptr [rip+fvj_compiles], 0
    je      .Lft_out
12: mov     eax, 1
    jmp     .Lft_out
.Lft_bad:
    xor     eax, eax
.Lft_out:
    mov     edx, TPROGS
    add     rsp, 24
    pop     rbp
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# ft_us -> rax = monotonic microseconds
ft_us:
    mov     edi, 1
    lea     rsi, [rip+ft_ts]
    mov     eax, 228
    syscall
    mov     rax, [rip+ft_ts]
    imul    rax, rax, 1000000
    mov     rcx, [rip+ft_ts+8]
    shr     rcx, 3
    mov     r8, 0x20c49ba5e353f7cf      # / 125: ns -> us
    push    rax
    mov     rax, rcx
    mul     r8
    shr     rdx, 4
    pop     rax
    add     rax, rdx
    ret

# fvj_bench(edi=elements) -> rax = the VM's microseconds, rdx = the JIT's
#   (a 40-instruction arithmetic program over the index)
fvj_bench:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    push    rbp
    sub     rsp, 24
    mov     r12d, edi
    mov     ebp, [rip+fvj_mode]
    cmp     ebp, 0
    jge     1f
    call    fvj_detect
    mov     ebp, [rip+fvj_mode]
1:  mov     esi, r12d                   # inputs (the index only) and 3 outputs
    imul    rsi, rsi, 4*10
    add     rsi, 4095
    and     rsi, -4096
    mov     [rsp], rsi
    xor     edi, edi
    mov     edx, PROT_RW
    mov     r10d, MAP_ANON_PRIV
    mov     r8, -1
    xor     r9d, r9d
    mov     eax, SYS_MMAP
    syscall
    cmp     rax, -4096
    jae     .Lfb_fail
    mov     rbx, rax
    lea     rdi, [rip+ft_prog]
    xor     eax, eax
    mov     ecx, 128*IN_SZ
    rep     stosb
    lea     r13, [rip+ft_prog]
    mov     byte ptr [r13], OP_INDEX    # r0 = index, r1 = 0.5
    mov     byte ptr [r13+1], 0
    mov     byte ptr [r13+IN_SZ], OP_CONST
    mov     byte ptr [r13+IN_SZ+1], 1
    mov     eax, [rip+ft_half]
    mov     [r13+IN_SZ+8], eax
    mov     ecx, 2
2:  cmp     ecx, 42
    jae     3f
    imul    rax, rcx, IN_SZ
    add     rax, r13
    lea     edx, [rcx-2]
    and     edx, 7
    lea     r8, [rip+ft_bench]
    movzx   edx, byte ptr [r8+rdx]
    mov     [rax], dl
    mov     [rax+1], cl
    lea     edx, [rcx-1]
    mov     [rax+2], dl
    lea     edx, [rcx-2]
    shr     edx, 1
    mov     [rax+3], dl
    mov     byte ptr [rax+4], 1
    inc     ecx
    jmp     2b
3:  mov     rdi, rbx
    xor     eax, eax                    # inputs: only the index
    lea     rdx, [rip+fv_ctx+FC_IN]
4:  cmp     eax, 7
    jae     5f
    mov     qword ptr [rdx+rax*8], 0
    inc     eax
    jmp     4b
5:  mov     [rdx+6*8], rbx
    xor     ecx, ecx
6:  cmp     ecx, r12d
    jae     7f
    cvtsi2ss xmm0, ecx
    movss   [rbx+rcx*4], xmm0
    inc     ecx
    jmp     6b
7:  mov     [rip+fv_ctx+FC_N], r12d
    lea     rax, [rip+ft_prog]
    mov     [rip+fv_ctx+FC_PROG], rax
    mov     dword ptr [rip+fv_ctx+FC_NINS], 42
    mov     dword ptr [rip+fv_ctx+FC_NOUT], 3
    mov     esi, r12d
    lea     rdi, [rbx+rsi*4]
    mov     edx, 41
    mov     ecx, 3
    call    ft_outs
    mov     dword ptr [rip+fvj_mode], 0
    call    ft_us
    mov     r14, rax
    call    fv_run
    call    ft_us
    sub     rax, r14
    mov     r14, rax
    mov     [rip+fvj_mode], ebp
    call    fv_run                      # (compile once, then time it)
    call    ft_us
    mov     r15, rax
    call    fv_run
    call    ft_us
    sub     rax, r15
    mov     r15, rax
    mov     rdi, rbx
    mov     rsi, [rsp]
    mov     eax, SYS_MUNMAP
    syscall
    mov     rax, r14
    mov     rdx, r15
    jmp     .Lfb_out
.Lfb_fail:
    xor     eax, eax
    xor     edx, edx
.Lfb_out:
    mov     [rip+fvj_mode], ebp
    add     rsp, 24
    pop     rbp
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

.section .note.GNU-stack,"",@progbits
