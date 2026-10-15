# =============================================================================
#  BeeModel - material programs: constant folding
#
#  A graph is compiled once per edit (graph_ver) into what does not depend
#  on the point being shaded: nodes of a pure type (math, mix, colours,
#  parameters ...) whose links all come from such nodes. They are
#  evaluated once, and each shading call copies only the results that
#  varying nodes or the pins read into its frame, then evaluates the rest.
#  A 30-node chain of constants costs one copy per pixel.
#
#  The table (GC_N entries by record address) is shared by the render
#  threads: an entry is rebuilt by whichever thread finds it stale and can
#  take its lock (others shade without folding meanwhile), and readers check
#  its sequence number around the copy (a change: they evaluate everything).
# =============================================================================
.intel_syntax noprefix
.include "const.inc"

.globl gc_fold
.globl mp_selftest

.equ GR_N,      128
.equ GR_NODES,  160
.equ NODE_SZ,   72
.equ ND_TYPE,   0
.equ ND_IN,     4
.equ MAX_NODES, 48
.equ EV_P,      0
.equ EV_DEPTH,  20
.equ EV_LIVE,   24
.equ EV_SC,     32
.equ EV_ARGS,   40
.equ EV_VAL,    48
.equ EV_SZ,     48 + 16*8*MAX_NODES
.equ GC_N,      32
.equ GC_REC,    0                       # the record
.equ GC_VER,    8                       # its graph_ver when built
.equ GC_SEQ,    12                      # odd while being written
.equ GC_LOCK,   16
.equ GC_CONST,  24                      # u64: the constant nodes
.equ GC_FRONT,  32                      # u64: those read by the rest or pins
.equ GC_VALS,   64                      # their results (EV_VAL rows)
.equ GC_SZ,     64 + 128*MAX_NODES

.section .rodata
# node types that are pure functions of their inputs and values (1: may fold)
st_types:       .long 7, 7, 7, 5, 19, 26, 17, 16, 2, 10   # (pure ones and varying)
st_ops:         .long 0, 1, 2, 5, 6
s_st_noise:     .asciz "material programs: 4-wide noise and fbm equal the scalar ones (1024 points)"
s_st_fold:      .asciz "material programs: folded constants give the same results as evaluating all (64 random graphs)"
.align 4
st_k:           .float 0.0, 0.0, 1.0, 0.000244140625
gc_pure:        .byte 0, 0, 0, 0, 0, 1, 1, 1, 0, 0     # 0 .. 9: mix, ramp, math
                .byte 0, 0, 0, 0, 0, 0, 1, 1, 0, 1     # 10 ..: constant, color, vmath
                .byte 1, 1, 0, 0, 0, 0, 1, 1, 1, 1     # 20 ..: separate, combine, hsv ...
                .byte 1, 1, 0, 0, 0, 0, 1, 1, 1, 0     # 30 ..: gamma, blackbody, reroute, params
                .byte 0, 0, 0, 0, 0, 0, 0, 0, 0, 0     # 40 ..: functions (no)
                .byte 0, 0, 0, 0, 0, 0, 0, 0, 0, 0

.section .bss
.align 64
gc_tab:         .skip GC_SZ*GC_N
.align 4096
st_rec:         .skip MA_SZ                 # the self-test's graph
st_sc:          .skip 256
st_seed:        .skip 4
st_bad:         .skip 4

.text
# gc_fold(rbx=record, r13=frame, rax=the nodes wanted) -> rax = those still
#   to evaluate, rdx = the constant nodes left out (0: none; their results
#   that matter are in the frame)
gc_fold:
    push    r12
    push    r14
    push    r15
    mov     r15, rax
    mov     rax, rbx                    # the entry: by the record's address
    shr     rax, 12
    and     eax, GC_N-1
    imul    eax, eax, GC_SZ
    lea     r12, [rip+gc_tab]
    add     r12, rax
    mov     r14d, [r12+GC_SEQ]          # (a sequence number to check)
    test    r14d, 1
    jnz     8f
    cmp     [r12+GC_REC], rbx
    jne     1f
    mov     eax, [rip+graph_ver]
    cmp     [r12+GC_VER], eax
    je      2f
1:  call    gc_build                    # stale: build it (if it can)
    test    eax, eax
    jz      8f
    mov     r14d, [r12+GC_SEQ]
    test    r14d, 1
    jnz     8f
2:  mov     rdx, [r12+GC_CONST]
    test    rdx, rdx
    jz      8f
    mov     rcx, [r12+GC_FRONT]         # the rows read, of those wanted
    and     rcx, r15
3:  bsf     rax, rcx
    jz      4f
    btr     rcx, rax
    shl     eax, 7
    movups  xmm0, [r12+GC_VALS+rax]
    movups  xmm1, [r12+GC_VALS+rax+16]
    movups  xmm2, [r12+GC_VALS+rax+32]
    movups  xmm3, [r12+GC_VALS+rax+48]
    movups  [r13+EV_VAL+rax], xmm0
    movups  [r13+EV_VAL+rax+16], xmm1
    movups  [r13+EV_VAL+rax+32], xmm2
    movups  [r13+EV_VAL+rax+48], xmm3
    movups  xmm0, [r12+GC_VALS+rax+64]
    movups  xmm1, [r12+GC_VALS+rax+80]
    movups  xmm2, [r12+GC_VALS+rax+96]
    movups  xmm3, [r12+GC_VALS+rax+112]
    movups  [r13+EV_VAL+rax+64], xmm0
    movups  [r13+EV_VAL+rax+80], xmm1
    movups  [r13+EV_VAL+rax+96], xmm2
    movups  [r13+EV_VAL+rax+112], xmm3
    jmp     3b
4:  cmp     [r12+GC_SEQ], r14d          # (written meanwhile: no folding)
    jne     8f
    cmp     [r12+GC_REC], rbx
    jne     8f
    mov     rax, r15
    not     rdx
    and     rax, rdx
    not     rdx
    jmp     9f
8:  mov     rax, r15
    xor     edx, edx
9:  pop     r15
    pop     r14
    pop     r12
    ret

# gc_build(rbx=record, r12=entry) -> eax = 1 when built (0: another thread
#   holds it)
gc_build:
    push    rbx
    push    r13
    push    r14
    push    r15
    push    rbp
    mov     rbp, rsp                    # (an aligned frame for graph_eval)
    and     rsp, -16
    sub     rsp, EV_SZ+16
    mov     eax, 1                      # the lock
    xchg    eax, [r12+GC_LOCK]
    test    eax, eax
    jnz     .Lgb_busy
    inc     dword ptr [r12+GC_SEQ]      # (odd: being written)
    mov     [r12+GC_REC], rbx
    mov     eax, [rip+graph_ver]
    mov     [r12+GC_VER], eax
    xor     r14d, r14d                  # the constant nodes, in order
    xor     ecx, ecx
1:  cmp     ecx, [rbx+GR_N]
    jae     3f
    cmp     ecx, MAX_NODES
    jae     3f
    imul    edx, ecx, NODE_SZ
    lea     rsi, [rbx+GR_NODES+rdx]
    mov     eax, [rsi+ND_TYPE]
    cmp     eax, 60
    jae     29f
    lea     r8, [rip+gc_pure]
    cmp     byte ptr [r8+rax], 0
    je      29f
    xor     r8d, r8d                    # its links: all from constants?
2:  imul    eax, r8d, 16
    movzx   eax, word ptr [rsi+ND_IN+rax]
    test    eax, eax
    jz      21f
    dec     eax
    bt      r14, rax
    jnc     29f
21: inc     r8d
    cmp     r8d, 3
    jb      2b
    bts     r14, rcx
29: inc     ecx
    jmp     1b
3:  mov     [r12+GC_CONST], r14
    xor     r15d, r15d                  # those read by the rest, or by pins
    xor     ecx, ecx
4:  cmp     ecx, [rbx+GR_N]
    jae     5f
    cmp     ecx, MAX_NODES
    jae     5f
    bt      r14, rcx
    jc      49f
    imul    edx, ecx, NODE_SZ
    lea     rsi, [rbx+GR_NODES+rdx]
    xor     r8d, r8d
41: imul    eax, r8d, 16
    movzx   eax, word ptr [rsi+ND_IN+rax]
    test    eax, eax
    jz      42f
    dec     eax
    bt      r14, rax
    jnc     42f
    bts     r15, rax
42: inc     r8d
    cmp     r8d, 3
    jb      41b
49: inc     ecx
    jmp     4b
5:  xor     ecx, ecx
51: cmp     ecx, NPINS
    jae     52f
    movzx   eax, word ptr [rbx+GR_PINS+rcx*4]
    test    eax, eax
    jz      53f
    dec     eax
    bt      r14, rax
    jnc     53f
    bts     r15, rax
53: inc     ecx
    jmp     51b
52: mov     [r12+GC_FRONT], r15
    test    r14, r14                    # their results: evaluated once
    jz      7f
    lea     r13, [rsp]
    xor     eax, eax
    mov     [r13+EV_P], rax
    mov     [r13+EV_P+8], rax
    mov     [r13+EV_P+16], rax
    mov     [r13+EV_LIVE], r14
    mov     [r13+EV_SC], rax
    mov     [r13+EV_ARGS], rax
    mov     rdi, rbx
    mov     rsi, r13
    call    graph_eval
    mov     rcx, r15                    # (the rows that matter)
6:  bsf     rax, rcx
    jz      7f
    btr     rcx, rax
    shl     eax, 7
    lea     rsi, [r13+EV_VAL+rax]
    lea     rdi, [r12+GC_VALS+rax]
    push    rcx
    mov     ecx, 32
    rep     movsd
    pop     rcx
    jmp     6b
7:  inc     dword ptr [r12+GC_SEQ]      # (even: done)
    mov     dword ptr [r12+GC_LOCK], 0
    mov     eax, 1
    jmp     9f
.Lgb_busy:
    xor     eax, eax
9:  mov     rsp, rbp
    pop     rbp
    pop     r15
    pop     r14
    pop     r13
    pop     rbx
    ret

# st_rand -> eax = the next number (xorshift), xmm0 = a number in -8 .. 8
st_rand:
    mov     eax, [rip+st_seed]
    mov     edx, eax
    shl     edx, 13
    xor     eax, edx
    mov     edx, eax
    shr     edx, 17
    xor     eax, edx
    mov     edx, eax
    shl     edx, 5
    xor     eax, edx
    mov     [rip+st_seed], eax
    mov     edx, eax
    and     edx, 0xffff
    sub     edx, 0x8000
    cvtsi2ss xmm0, edx
    mulss   xmm0, [rip+st_k+12]
    ret

# mp_selftest(rdi=check(eax, rdi=label)) - perlin4 / fbm4 against perlin /
#   fbm, and folded graphs against unfolded ones
mp_selftest:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    push    rbp
    mov     rbp, rsp
    and     rsp, -16
    sub     rsp, 2*EV_SZ+256            # frames +0 and +EV_SZ, scratch after
    mov     r15, rdi
    mov     dword ptr [rip+st_seed], 0x2545f491
    mov     dword ptr [rip+st_bad], 0
    xor     r12d, r12d                  # 256 x 4 points
1:  cmp     r12d, 256
    jae     2f
    lea     rbx, [rsp+2*EV_SZ]          # x[4] y[4] z[4] at +0, results +48
    xor     r13d, r13d
11: call    st_rand
    movss   [rbx+r13*4], xmm0
    inc     r13d
    cmp     r13d, 12
    jb      11b
    movaps  xmm0, [rbx]
    movaps  xmm1, [rbx+16]
    movaps  xmm2, [rbx+32]
    call    perlin4
    movaps  [rbx+48], xmm0
    movaps  xmm0, [rbx]                 # (and fbm: 5 octaves, 0.6)
    movaps  xmm1, [rbx+16]
    movaps  xmm2, [rbx+32]
    mov     eax, 0x3fc00000
    movd    xmm3, eax
    mov     ecx, 5
    mov     eax, 0x3f19999a
    movd    xmm4, eax
    call    fbm4
    movaps  [rbx+64], xmm0
    xor     r13d, r13d
12: movss   xmm0, [rbx+r13*4]           # each lane: the scalar ones
    movss   [rbx+96], xmm0
    movss   xmm0, [rbx+16+r13*4]
    movss   [rbx+100], xmm0
    movss   xmm0, [rbx+32+r13*4]
    movss   [rbx+104], xmm0
    lea     rdi, [rbx+96]
    call    perlin
    ucomiss xmm0, [rbx+48+r13*4]
    je      13f
    inc     dword ptr [rip+st_bad]
13: lea     rdi, [rbx+96]
    mov     eax, 0x3fc00000
    movd    xmm0, eax
    mov     ecx, 5
    mov     eax, 0x3f19999a
    movd    xmm1, eax
    call    fbm
    ucomiss xmm0, [rbx+64+r13*4]
    je      14f
    inc     dword ptr [rip+st_bad]
14: inc     r13d
    cmp     r13d, 4
    jb      12b
    inc     r12d
    jmp     1b
2:  xor     eax, eax
    cmp     dword ptr [rip+st_bad], 0
    sete    al
    lea     rdi, [rip+s_st_noise]
    call    r15
    # 64 random graphs of 20 nodes: pure ones and varying ones
    mov     dword ptr [rip+st_bad], 0
    xor     r12d, r12d
3:  cmp     r12d, 64
    jae     8f
    lea     rbx, [rip+st_rec]
    lea     rdi, [rbx+128]              # (the graph part: cleared)
    xor     eax, eax
    mov     ecx, (MA_SZ-128)/4
    rep     stosd
    xor     r13d, r13d
4:  cmp     r13d, 20
    jae     5f
    imul    eax, r13d, NODE_SZ
    lea     r14, [rbx+GR_NODES+rax]
    call    st_rand
    xor     edx, edx
    mov     ecx, 10
    div     ecx
    lea     rax, [rip+st_types]
    mov     eax, [rax+rdx*4]
    test    r13d, r13d                  # (the first: varying)
    jnz     41f
    mov     eax, 10
41: mov     [r14+ND_TYPE], eax
    call    st_rand                     # its operation, values
    xor     edx, edx
    mov     ecx, 5
    div     ecx
    lea     rax, [rip+st_ops]
    cvtsi2ss xmm0, dword ptr [rax+rdx*4]
    movss   [r14+52], xmm0
    call    st_rand
    andps   xmm0, [rip+st_abs]
    addss   xmm0, [rip+st_k+8]
    movss   [r14+56], xmm0              # (noise: its scale; mix: a mode)
    mov     dword ptr [r14+60], 0x40000000
    xor     r8d, r8d                    # inputs: a link to an earlier node
42: mov     [rsp+2*EV_SZ+128], r8d      #  or a constant
    call    st_rand
    mov     r8d, [rsp+2*EV_SZ+128]
    imul    ecx, r8d, 16
    movss   [r14+ND_IN+rcx+4], xmm0
    movss   [r14+ND_IN+rcx+8], xmm0
    movss   [r14+ND_IN+rcx+12], xmm0
    test    r13d, r13d
    jz      43f
    test    eax, 0x10000
    jz      43f
    shr     eax, 20
    xor     edx, edx
    div     r13d
    inc     edx
    mov     [r14+ND_IN+rcx], edx
43: inc     r8d
    cmp     r8d, 3
    jb      42b
    inc     r13d
    jmp     4b
5:  mov     dword ptr [rbx+GR_N], 20
    mov     dword ptr [rbx+GR_PINS], 20    # base: the last node
    inc     dword ptr [rip+graph_ver]
    xor     r13d, r13d                  # 4 points each
6:  cmp     r13d, 4
    jae     7f
    lea     r14, [rsp]                  # frame A: everything
    call    st_frame
    xor     eax, eax
    bts     rax, 19
    push    rbx
    push    rbx
    call    gr_live
    pop     rbx
    pop     rbx
    mov     [r14+EV_LIVE], rax
    mov     rdi, rbx
    mov     rsi, r14
    call    graph_eval
    lea     r14, [rsp+EV_SZ]            # frame B: constants folded
    call    st_frame
    xor     eax, eax
    bts     rax, 19
    push    rbx
    push    rbx
    call    gr_live
    pop     rbx
    pop     rbx
    push    r13
    push    r13
    mov     r13, r14
    call    gc_fold
    pop     r13
    pop     r13
    mov     [r14+EV_LIVE], rax
    mov     rdi, rbx
    mov     rsi, r14
    call    graph_eval
    xor     ecx, ecx                    # the last node's colour and value
61: movss   xmm0, [rsp+EV_VAL+19*128+rcx*4]
    ucomiss xmm0, [rsp+EV_SZ+EV_VAL+19*128+rcx*4]
    jp      62f                         # (both NaN: fine)
    je      62f
    inc     dword ptr [rip+st_bad]
62: inc     ecx
    cmp     ecx, 4
    jb      61b
    inc     r13d
    jmp     6b
7:  inc     r12d
    jmp     3b
8:  xor     eax, eax
    cmp     dword ptr [rip+st_bad], 0
    sete    al
    lea     rdi, [rip+s_st_fold]
    call    r15
    mov     rsp, rbp
    pop     rbp
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# st_frame(r14=frame, r13d=which point) - a point, UVs, the shading context
st_frame:
    cvtsi2ss xmm0, r13d
    movss   [r14+EV_P], xmm0
    mulss   xmm0, [rip+st_k+8]
    addss   xmm0, xmm0
    movss   [r14+EV_P+4], xmm0
    movss   [r14+EV_P+8], xmm0
    movss   [r14+EV_P+12], xmm0
    movss   [r14+EV_P+16], xmm0
    mov     dword ptr [r14+EV_DEPTH], 0
    lea     rax, [rip+st_sc]
    mov     [r14+EV_SC], rax
    mov     qword ptr [r14+EV_ARGS], 0
    ret

.section .rodata
.align 16
st_abs:         .long 0x7fffffff, 0, 0, 0

.section .note.GNU-stack,"",@progbits
