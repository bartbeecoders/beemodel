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
s_workers:  .asciz "  workers: "
s_threads:  .asciz " | threads that ran chunks: "
s_serial:   .asciz "  bench (8M elements): serial "
s_par:      .asciz " ms, parallel "
s_speed:    .asciz " ms, speed-up x"
s_ms_end:   .asciz "\n"
s_sum_ok:   .asciz "all self-tests passed\n"
s_sum_bad:  .asciz "self-test FAILED\n"

.text

# check(eax=condition, rdi=label)
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
