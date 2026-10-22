# =============================================================================
#  BeeModel - built-in self-test (beemodel --selftest): arenas, pools and the
#  job system, plus a small serial vs parallel benchmark. Used by CI.
# =============================================================================
.intel_syntax noprefix
.include "const.inc"

# exports
.globl selftest

.equ SYS_CLOCK_GETTIME, 228
.equ BENCH_N,           8000000

.section .bss
.align 8
t_arena:    .skip ARENA_SZ
t_pool:     .skip POOL_SZ
t_mask:     .skip 8
t_fails:    .skip 4
t_passes:   .skip 4
t_handle:   .skip 4
t_arr:      .skip 8
ts:         .skip 16
t_start:    .skip 8

.section .rodata
s_hdr:      .asciz "BeeModel self-test\n"
s_ok:       .asciz "  ok   "
s_fail:     .asciz "  FAIL "
s_nl:       .asciz "\n"
s_t1:       .asciz "arena: 16-byte aligned bump allocation"
s_t2:       .asciz "arena: reset reuses the block"
s_t3:       .asciz "arena: refuses allocations past capacity"
s_t4:       .asciz "pool: handles resolve to distinct slots"
s_t5:       .asciz "pool: freed handle becomes stale"
s_t6:       .asciz "pool: slot reuse gets a new generation"
s_t7:       .asciz "pool: full pool returns handle 0"
s_t8:       .asciz "parallel_for: every element written exactly once"
s_t9:       .asciz "parallel_for: work spread over worker threads"
.align 4
ps_grains:  .long 1, 256, 16, 3
s_t9b:      .asciz "parallel_for: 3000 calls back to back, the grain changing - every element run once each time"
s_t10:      .asciz "field JIT: 150 random programs give the VM's bits (SSE and AVX paths)"
s_jit:      .asciz "field program, 1M elements x 42 instructions: VM "
s_jit2:     .asciz " ms, JIT "
s_jit3:     .asciz " ms ("
s_avx:      .asciz "AVX)\n"
s_sse:      .asciz "SSE)\n"
s_off:      .asciz "off)\n"
s_workers:  .asciz "  workers: "
s_threads:  .asciz " | threads that ran chunks: "
s_serial:   .asciz "  bench (8M elements): serial "
s_par:      .asciz " ms, parallel "
s_speed:    .asciz " ms, speed-up x"
s_ms_end:   .asciz "\n"
s_t11:      .asciz "SipHash-2-4 (co-editing's session key): the reference vector"
.align 8
sh_msg:     .byte 8, 9, 10, 11, 12, 13, 14      # bytes 8..14 (0..7: the first word)
s_sum_ok:   .asciz "all self-tests passed\n"
s_sum_bad:  .asciz "self-test FAILED\n"

.text

# check(eax=condition, rdi=label)
# pf_stress -> eax = 1 when 3000 parallel_for calls in a row, their count
#   and grain changing each time (1, 256, 16, 3), ran every element exactly
#   once in each (a worker late from one call must not run the next's
#   elements twice)
.equ PS_N,      4096
pf_stress:
    push    rbx
    push    r12
    push    r13
    mov     rdi, [rip+t_arr]
    xor     eax, eax
    mov     ecx, PS_N
    rep     stosd
    xor     ebx, ebx
1:  cmp     ebx, 3000
    jae     3f
    mov     eax, ebx                    # count: 1000 + (round % 7) 400
    xor     edx, edx
    mov     ecx, 7
    div     ecx
    imul    edx, edx, 400
    add     edx, 1000
    mov     r12d, edx
    mov     eax, ebx                    # grain
    and     eax, 3
    lea     rcx, [rip+ps_grains]
    mov     ecx, [rcx+rax*4]
    lea     rdi, [rip+ps_job]
    xor     esi, esi
    mov     edx, r12d
    call    parallel_for
    inc     ebx
    jmp     1b
3:  xor     ebx, ebx                    # element i: the rounds that reached it
    mov     r12, [rip+t_arr]
4:  cmp     ebx, 3400
    jae     8f
    xor     ecx, ecx                    # expected: rounds with count > i
    xor     r13d, r13d
5:  cmp     ecx, 7
    jae     6f
    imul    eax, ecx, 400
    add     eax, 1000
    cmp     ebx, eax
    jae     51f
    mov     eax, 3000                   # rounds with this remainder
    sub     eax, ecx
    add     eax, 6
    xor     edx, edx
    push    rcx
    mov     ecx, 7
    div     ecx
    pop     rcx
    add     r13d, eax
51: inc     ecx
    jmp     5b
6:  cmp     [r12+rbx*4], r13d
    jne     9f
    inc     ebx
    jmp     4b
8:  mov     eax, 1
    jmp     91f
9:  xor     eax, eax
91: pop     r13
    pop     r12
    pop     rbx
    ret
ps_job:
1:  cmp     esi, edx
    jae     9f
    mov     rax, [rip+t_arr]
    lock inc dword ptr [rax+rsi*4]
    inc     esi
    jmp     1b
9:  ret

check:
    push    rbx
    mov     rbx, rdi
    test    eax, eax
    jz      1f
    inc     dword ptr [rip+t_passes]
    lea     rdi, [rip+s_ok]
    jmp     2f
1:  inc     dword ptr [rip+t_fails]
    lea     rdi, [rip+s_fail]
2:  call    write_out
    mov     rdi, rbx
    call    write_out
    lea     rdi, [rip+s_nl]
    call    write_out
    pop     rbx
    ret

# now_us -> rax = monotonic microseconds
now_us:
    mov     edi, 1
    lea     rsi, [rip+ts]
    mov     eax, SYS_CLOCK_GETTIME
    syscall
    mov     rax, [rip+ts]
    imul    rax, rax, 1000000
    mov     rcx, rax
    mov     rax, [rip+ts+8]
    xor     edx, edx
    mov     r8d, 1000
    div     r8
    add     rax, rcx
    ret

# job: arr[i] = hash(i), and record which thread ran it
fill_job:
    mov     rax, rcx
    test    eax, eax
    js      1f
    lock bts qword ptr [rip+t_mask], rax
1:  mov     r9, [rip+t_arr]
2:  cmp     esi, edx
    jae     9f
    mov     eax, esi                    # a little real work per element
    mov     r10d, 24
3:  imul    eax, eax, 0x2c1b3c6d
    xor     eax, 0x297a2d39
    rol     eax, 7
    dec     r10d
    jnz     3b
    mov     [r9+rsi*4], eax
    inc     esi
    jmp     2b
9:  ret

# expected(esi=i) -> eax, mirrors fill_job
expected:
    mov     eax, esi
    mov     r10d, 24
1:  imul    eax, eax, 0x2c1b3c6d
    xor     eax, 0x297a2d39
    rol     eax, 7
    dec     r10d
    jnz     1b
    ret

selftest:
    push    rbx
    push    r12
    push    r13
    push    r14
    sub     rsp, 8
    lea     rdi, [rip+s_hdr]
    call    write_out

    # ---- arena -----------------------------------------------------------------
    lea     rdi, [rip+t_arena]
    mov     esi, 0x100000
    call    arena_init
    lea     rdi, [rip+t_arena]
    mov     esi, 10
    call    arena_alloc
    mov     rbx, rax
    lea     rdi, [rip+t_arena]
    mov     esi, 100
    call    arena_alloc
    mov     r12, rax
    xor     eax, eax
    test    rbx, rbx
    jz      1f
    test    r12, 15
    jnz     1f
    lea     rcx, [rbx+16]
    cmp     r12, rcx
    jne     1f
    inc     eax
1:  lea     rdi, [rip+s_t1]
    call    check
    lea     rdi, [rip+t_arena]
    call    arena_reset
    lea     rdi, [rip+t_arena]
    mov     esi, 64
    call    arena_alloc
    xor     ecx, ecx
    cmp     rax, rbx
    sete    cl
    mov     eax, ecx
    lea     rdi, [rip+s_t2]
    call    check
    lea     rdi, [rip+t_arena]
    mov     esi, 0x200000
    call    arena_alloc
    xor     ecx, ecx
    test    rax, rax
    sete    cl
    mov     eax, ecx
    lea     rdi, [rip+s_t3]
    call    check

    # ---- pool ------------------------------------------------------------------
    lea     rdi, [rip+t_pool]
    mov     esi, 24
    mov     edx, 100
    call    pool_init
    lea     rdi, [rip+t_pool]
    call    pool_alloc
    mov     ebx, eax                    # h1
    lea     rdi, [rip+t_pool]
    call    pool_alloc
    mov     r12d, eax                   # h2
    lea     rdi, [rip+t_pool]
    mov     esi, ebx
    call    pool_get
    mov     r13, rax
    lea     rdi, [rip+t_pool]
    mov     esi, r12d
    call    pool_get
    xor     ecx, ecx
    test    r13, r13
    jz      2f
    test    rax, rax
    jz      2f
    cmp     rax, r13
    je      2f
    inc     ecx
2:  mov     eax, ecx
    lea     rdi, [rip+s_t4]
    call    check
    lea     rdi, [rip+t_pool]
    mov     esi, ebx
    call    pool_free
    lea     rdi, [rip+t_pool]
    mov     esi, ebx
    call    pool_get
    xor     ecx, ecx
    test    rax, rax
    sete    cl
    mov     eax, ecx
    lea     rdi, [rip+s_t5]
    call    check
    lea     rdi, [rip+t_pool]
    call    pool_alloc                  # reuses h1's slot
    mov     r14d, eax
    xor     ecx, ecx
    mov     edx, eax
    and     edx, 0xffffff
    mov     r8d, ebx
    and     r8d, 0xffffff
    cmp     edx, r8d
    jne     3f
    cmp     eax, ebx
    je      3f
    lea     rdi, [rip+t_pool]
    mov     esi, r14d
    call    pool_get
    xor     ecx, ecx
    test    rax, rax
    setnz   cl
3:  mov     eax, ecx
    lea     rdi, [rip+s_t6]
    call    check
    mov     r13d, 2                     # fill the pool up
4:  lea     rdi, [rip+t_pool]
    call    pool_alloc
    test    eax, eax
    jz      5f
    inc     r13d
    jmp     4b
5:  xor     eax, eax
    cmp     r13d, 100
    sete    al
    lea     rdi, [rip+s_t7]
    call    check

    # ---- job system ------------------------------------------------------------
    lea     rdi, [rip+t_arena]
    mov     esi, BENCH_N*4+64
    call    arena_init
    lea     rdi, [rip+t_arena]
    mov     esi, BENCH_N*4
    call    arena_alloc
    mov     [rip+t_arr], rax
    # serial reference timing
    call    now_us
    mov     r12, rax
    mov     rdi, -1
    xor     esi, esi
    mov     edx, BENCH_N
    mov     ecx, -1
    call    fill_job
    call    now_us
    sub     rax, r12
    mov     r13, rax                    # serial us
    # parallel
    mov     rdi, [rip+t_arr]            # poison so missed elements show
    mov     eax, 0xdeadbeef
    mov     ecx, BENCH_N
    rep     stosd
    mov     qword ptr [rip+t_mask], 0
    call    now_us
    mov     r12, rax
    lea     rdi, [rip+fill_job]
    xor     esi, esi
    mov     edx, BENCH_N
    mov     ecx, 16384
    call    parallel_for
    call    now_us
    sub     rax, r12
    mov     r14, rax                    # parallel us
    xor     ebx, ebx                    # verify
    mov     r12, [rip+t_arr]
6:  cmp     ebx, BENCH_N
    jae     7f
    mov     esi, ebx
    call    expected
    cmp     eax, [r12+rbx*4]
    jne     8f
    inc     ebx
    jmp     6b
7:  mov     eax, 1
    jmp     81f
8:  xor     eax, eax
81: lea     rdi, [rip+s_t8]
    call    check
    popcnt  rbx, [rip+t_mask]           # threads that ran chunks
    xor     eax, eax
    cmp     dword ptr [rip+n_workers], 0
    jne     82f
    inc     eax                         # no workers: nothing to spread
    jmp     83f
82: cmp     ebx, 2
    setae   al
83: lea     rdi, [rip+s_t9]
    call    check
    call    pf_stress
    lea     rdi, [rip+s_t9b]
    call    check
    call    fmt_reset
    lea     rdi, [rip+s_workers]
    call    fmt_str
    mov     edi, [rip+n_workers]
    call    fmt_int
    lea     rdi, [rip+s_threads]
    call    fmt_str
    mov     edi, ebx
    call    fmt_int
    mov     edi, 10
    call    fmt_char
    lea     rdi, [rip+fmt_buf]
    call    write_out
    call    fmt_reset
    lea     rdi, [rip+s_serial]
    call    fmt_str
    cvtsi2ss xmm0, r13
    divss   xmm0, [rip+f_1000]
    call    fmt_fix1
    lea     rdi, [rip+s_par]
    call    fmt_str
    cvtsi2ss xmm0, r14
    divss   xmm0, [rip+f_1000]
    call    fmt_fix1
    lea     rdi, [rip+s_speed]
    call    fmt_str
    cvtsi2ss xmm0, r13
    cvtsi2ss xmm1, r14
    maxss   xmm1, [rip+f_one_]
    divss   xmm0, xmm1
    call    fmt_fix1
    lea     rdi, [rip+s_ms_end]
    call    fmt_str
    lea     rdi, [rip+fmt_buf]
    call    write_out

    call    fvj_selftest                # the field JIT against the VM
    lea     rdi, [rip+s_t10]
    call    check
    mov     edi, 1000000
    call    fvj_bench
    mov     r13, rax
    mov     r14, rdx
    call    fmt_reset
    lea     rdi, [rip+s_jit]
    call    fmt_str
    cvtsi2ss xmm0, r13
    divss   xmm0, [rip+f_1000]
    call    fmt_fix1
    lea     rdi, [rip+s_jit2]
    call    fmt_str
    cvtsi2ss xmm0, r14
    divss   xmm0, [rip+f_1000]
    call    fmt_fix1
    lea     rdi, [rip+s_jit3]
    call    fmt_str
    lea     rdi, [rip+s_off]
    cmp     dword ptr [rip+fvj_mode], 1
    jb      1f
    lea     rdi, [rip+s_sse]
    je      1f
    lea     rdi, [rip+s_avx]
1:  call    fmt_str
    lea     rdi, [rip+fmt_buf]
    call    write_out

    lea     rdi, [rip+sh_msg]           # SipHash-2-4, key 00..0f, message
    mov     esi, 7                      #  00..0e: a129ca6149be45e5
    mov     rdx, 0x0706050403020100
    mov     rcx, 0x0f0e0d0c0b0a0908
    mov     r8, 0x0706050403020100
    call    siphash
    mov     rcx, 0xa129ca6149be45e5
    cmp     rax, rcx
    sete    al
    movzx   eax, al
    lea     rdi, [rip+s_t11]
    call    check

    lea     rdi, [rip+check]            # cluster LOD DAGs: crack-free cuts
    call    vg_selftest
    lea     rdi, [rip+check]            # material programs: SIMD noise,
    call    mp_selftest                 #  folded constants
    xor     eax, eax
    cmp     dword ptr [rip+t_fails], 0
    sete    al
    lea     rdi, [rip+s_sum_ok]
    test    eax, eax
    jnz     9f
    lea     rdi, [rip+s_sum_bad]
9:  call    write_out
    xor     eax, eax
    cmp     dword ptr [rip+t_fails], 0
    setne   al
    add     rsp, 8
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

.section .rodata
f_1000:     .float 1000.0
f_one_:     .float 1.0

.section .note.GNU-stack,"",@progbits
