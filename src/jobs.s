# =============================================================================
#  BeeModel - job system: worker threads (raw clone), futex sleeping and
#  parallel_for with dynamic chunk claiming.
#
#  parallel_for(fn, ctx, count, grain) splits [0, count) into chunks; workers
#  and the calling thread claim chunks with one atomic fetch-add each, which
#  balances uneven work like work stealing does for data-parallel loops.
#  Idle workers sleep in futex_wait (0% CPU). Each thread owns a scratch arena
#  that is reset before every chunk.
#
#  chunk fn: fn(rdi=ctx, esi=begin, edx=end, ecx=thread index, r8=scratch arena)
# =============================================================================
.intel_syntax noprefix
.include "const.inc"

# exports
.globl jobs_init
.globl parallel_for
.globl jobs_cancel
.globl n_workers
.globl thread_arena

.equ SYS_CLONE,         56
.equ SYS_EXIT,          60
.equ SYS_FUTEX,         202
.equ SYS_GETAFFINITY,   204
.equ FUTEX_WAIT_PRIV,   128
.equ FUTEX_WAKE_PRIV,   129
.equ CLONE_THREAD_FLAGS, 0x50f00        # VM|FS|FILES|SIGHAND|THREAD|SYSVSEM
.equ MAP_STACK_FLAGS,   0x24022         # private|anon|noreserve|stack
.equ STACK_BYTES,       0x40000         # 256 KiB per worker
.equ MAX_THREADS,       64
.equ SCRATCH_BYTES,     0x4000000       # 64 MiB reserved per thread (lazy)

.section .bss
.align 64
pf_gen:         .skip 64                # futex: bumped for every parallel_for
pf_active:      .skip 64                # futex: workers inside a job
pf_next:        .skip 64                # next unclaimed index
.align 8
pf_fn:          .skip 8
pf_ctx:         .skip 8
pf_count:       .skip 4
pf_grain:       .skip 4
pf_cancel:      .skip 4
pf_busy:        .skip 4
n_workers:      .skip 4
cpumask:        .skip 128
thread_arena:   .skip ARENA_SZ*MAX_THREADS

.section .rodata
s_env_threads:  .asciz "BEEMODEL_THREADS="

.text

# futex(rdi=addr, esi=op, edx=val)
futex:
    xor     r10d, r10d
    xor     r8d, r8d
    xor     r9d, r9d
    mov     eax, SYS_FUTEX
    syscall
    ret

# -----------------------------------------------------------------------------
# jobs_init - one worker per CPU (minus the UI thread); BEEMODEL_THREADS=n
# overrides (0 = run everything on the calling thread)
# -----------------------------------------------------------------------------
jobs_init:
    push    rbx
    push    r12
    push    r13
    lea     rdi, [rip+s_env_threads]
    call    getenv
    test    rax, rax
    jz      1f
    movzx   ecx, byte ptr [rax]         # empty / non-numeric: automatic
    sub     ecx, '0'
    cmp     ecx, 9
    ja      1f
    xor     ebx, ebx                    # parse the decimal override
11: movzx   ecx, byte ptr [rax]
    sub     ecx, '0'
    cmp     ecx, 9
    ja      3f
    imul    ebx, ebx, 10
    add     ebx, ecx
    inc     rax
    jmp     11b
1:  xor     edi, edi                    # sched_getaffinity(0, 128, mask)
    mov     esi, 128
    lea     rdx, [rip+cpumask]
    mov     eax, SYS_GETAFFINITY
    syscall
    xor     ebx, ebx
    test    eax, eax
    jle     3f
    lea     rdx, [rip+cpumask]
    xor     ecx, ecx
2:  popcnt  r8, [rdx+rcx*8]
    add     ebx, r8d
    inc     ecx
    cmp     ecx, 16
    jb      2b
    dec     ebx                         # leave one CPU for the UI thread
3:  cmp     ebx, MAX_THREADS-1
    jbe     4f
    mov     ebx, MAX_THREADS-1
4:  test    ebx, ebx
    jns     41f
    xor     ebx, ebx
41: mov     [rip+n_workers], ebx
    # scratch arenas for every worker + the calling thread
    xor     r12d, r12d
5:  cmp     r12d, ebx
    ja      6f
    mov     eax, r12d
    imul    eax, ARENA_SZ
    lea     rdi, [rip+thread_arena]
    add     rdi, rax
    mov     esi, SCRATCH_BYTES
    call    arena_init
    inc     r12d
    jmp     5b
6:  xor     r12d, r12d                  # spawn
7:  cmp     r12d, ebx
    jae     9f
    xor     edi, edi
    mov     esi, STACK_BYTES
    mov     edx, PROT_RW
    mov     r10d, MAP_STACK_FLAGS
    mov     r8d, -1
    xor     r9d, r9d
    mov     eax, SYS_MMAP
    syscall
    cmp     rax, -4096
    ja      8f
    lea     rdx, [rax+STACK_BYTES]
    lea     rdi, [rip+worker_main]
    mov     esi, r12d
    call    spawn_thread
    test    eax, eax
    js      8f
    inc     r12d
    jmp     7b
8:  mov     [rip+n_workers], r12d       # fewer threads than planned
9:  pop     r13
    pop     r12
    pop     rbx
    ret

# spawn_thread(rdi=entry, esi=arg, rdx=stack top) -> eax = tid (parent)
spawn_thread:
    sub     rdx, 16
    mov     [rdx], rdi
    mov     [rdx+8], rsi
    mov     rsi, rdx
    mov     edi, CLONE_THREAD_FLAGS
    xor     edx, edx
    xor     r10d, r10d
    xor     r8d, r8d
    mov     eax, SYS_CLONE
    syscall
    test    eax, eax
    jnz     1f
    pop     rax                         # child: entry
    pop     rdi                         #        arg
    and     rsp, -16
    call    rax
    xor     edi, edi
    mov     eax, SYS_EXIT
    syscall
1:  ret

# worker_main(edi=worker index) - sleep until a parallel_for is published
worker_main:
    mov     ebx, edi
    xor     r12d, r12d                  # generation already served
1:  mov     eax, [rip+pf_gen]
    cmp     eax, r12d
    jne     2f
    lea     rdi, [rip+pf_gen]
    mov     esi, FUTEX_WAIT_PRIV
    mov     edx, r12d
    call    futex
    jmp     1b
2:  mov     r12d, eax
    lock inc dword ptr [rip+pf_active]
    mov     edi, ebx
    call    pf_run
    lock dec dword ptr [rip+pf_active]
    jnz     1b
    lea     rdi, [rip+pf_active]        # last one out wakes the caller
    mov     esi, FUTEX_WAKE_PRIV
    mov     edx, 1
    call    futex
    jmp     1b

# pf_run(edi=thread index) - claim and run chunks until none are left
pf_run:
    push    rbx
    push    r12
    push    r13
    mov     ebx, edi
    mov     eax, ebx
    imul    eax, ARENA_SZ
    lea     r13, [rip+thread_arena]
    add     r13, rax
1:  cmp     dword ptr [rip+pf_cancel], 0
    jne     9f
    mov     eax, [rip+pf_grain]
    lock xadd [rip+pf_next], eax        # eax = begin
    mov     ecx, [rip+pf_count]
    cmp     eax, ecx
    jae     9f
    mov     edx, eax
    add     edx, [rip+pf_grain]
    cmp     edx, ecx
    cmova   edx, ecx                    # end
    mov     r12d, eax
    push    rdx
    mov     rdi, r13
    call    arena_reset
    pop     rdx
    mov     esi, r12d
    mov     ecx, ebx
    mov     r8, r13
    mov     rdi, [rip+pf_ctx]
    call    [rip+pf_fn]
    jmp     1b
9:  pop     r13
    pop     r12
    pop     rbx
    ret

# -----------------------------------------------------------------------------
# parallel_for(rdi=fn, rsi=ctx, edx=count, ecx=grain) - returns when done.
# Called from inside a job it runs inline (thread index -1, no scratch arena).
# -----------------------------------------------------------------------------
parallel_for:
    test    edx, edx
    jz      .Lpf_ret
    test    ecx, ecx
    jnz     1f
    mov     ecx, 1
1:  push    rbx
    push    r12
    push    r13
    push    r14
    mov     rbx, rdi                    # fn
    mov     r12, rsi                    # ctx
    mov     r13d, edx                   # count
    mov     r14d, ecx                   # grain
    cmp     dword ptr [rip+pf_busy], 0
    jne     .Lpf_nested
    cmp     dword ptr [rip+n_workers], 0
    je      .Lpf_serial
    cmp     r13d, r14d
    jbe     .Lpf_serial                 # a single chunk: nobody to wake
    mov     dword ptr [rip+pf_busy], 1
    mov     [rip+pf_fn], rbx
    mov     [rip+pf_ctx], r12
    mov     [rip+pf_count], r13d
    mov     [rip+pf_grain], r14d
    mov     dword ptr [rip+pf_cancel], 0
    mov     dword ptr [rip+pf_next], 0
    lock inc dword ptr [rip+pf_gen]     # publish (locked op = full barrier)
    lea     rdi, [rip+pf_gen]
    mov     esi, FUTEX_WAKE_PRIV
    mov     edx, 0x7fffffff
    call    futex
    mov     edi, [rip+n_workers]        # the caller works too
    call    pf_run
2:  mov     eax, [rip+pf_active]        # wait for workers still in the job
    test    eax, eax
    jz      3f
    lea     rdi, [rip+pf_active]
    mov     esi, FUTEX_WAIT_PRIV
    mov     edx, eax
    call    futex
    jmp     2b
3:  mov     dword ptr [rip+pf_busy], 0
    jmp     .Lpf_out
.Lpf_serial:                            # whole range on this thread
    mov     eax, [rip+n_workers]
    imul    eax, ARENA_SZ
    lea     rdi, [rip+thread_arena]
    add     rdi, rax
    push    rdi
    sub     rsp, 8
    call    arena_reset
    add     rsp, 8
    pop     r8
    mov     ecx, [rip+n_workers]
    jmp     4f
.Lpf_nested:
    xor     r8d, r8d
    mov     ecx, -1
4:  mov     rdi, r12
    xor     esi, esi
    mov     edx, r13d
    call    rbx
.Lpf_out:
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
.Lpf_ret:
    ret

# jobs_cancel - ask the running parallel_for to stop claiming chunks
jobs_cancel:
    mov     dword ptr [rip+pf_cancel], 1
    ret

.section .note.GNU-stack,"",@progbits
