# =============================================================================
#  BeeModel - job system: worker threads (plat_thread_start), futex sleeping and
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
.globl job_spawn
.globl bg_tid

.equ SYS_FUTEX,         202
.equ SYS_GETTID,        186
.equ FUTEX_WAIT,        0
.equ BG_STACK_BYTES,    0x100000        # 1 MiB for the background thread
.equ SYS_GETAFFINITY,   204
.equ FUTEX_WAIT_PRIV,   128
.equ FUTEX_WAKE_PRIV,   129
.equ MAP_STACK_FLAGS,   0x24022         # private|anon|noreserve|stack
.equ STACK_BYTES,       0x40000         # 256 KiB per worker
.equ MAX_THREADS,       64
.equ SCRATCH_BYTES,     0x4000000       # 64 MiB reserved per thread (lazy)

.section .bss
.align 64
pf_gen:         .skip 64                # futex: bumped for every parallel_for
pf_active:      .skip 64                # futex: workers inside a job
pf_next:        .skip 64                # the claim: the job's generation (high
                                        #  32 bits), the next unclaimed index
.align 8
pf_fn:          .skip 8
pf_ctx:         .skip 8
pf_count:       .skip 4
pf_grain:       .skip 4
pf_cancel:      .skip 4
pf_busy:        .skip 4
pf_lock:        .skip 4                 # futex mutex: 0 free, 1 held, 2 waited on
pf_owner:       .skip 4                 # thread id of the parallel_for running
.globl main_tid
main_tid:       .skip 4
bg_tid:         .skip 4                 # the background thread (0: none)
bg_stack:       .skip 8
n_workers:      .skip 4
cpumask:        .skip 128
thread_arena:   .skip ARENA_SZ*MAX_THREADS

.section .rodata
.align 8
pf_100ms:       .quad 0, 100000000

s_env_threads:  .asciz "BEEMODEL_THREADS="

.text

# futex(rdi=addr, esi=op, edx=val)
futex:
    xor     r10d, r10d
    xor     r8d, r8d
    xor     r9d, r9d
    call    plat_futex
    ret

# -----------------------------------------------------------------------------
# jobs_init - one worker per CPU (minus the UI thread); BEEMODEL_THREADS=n
# overrides (0 = run everything on the calling thread)
# -----------------------------------------------------------------------------
jobs_init:
    push    rbx
    push    r12
    push    r13
    call    plat_gettid
    mov     [rip+main_tid], eax
    lea     rdi, [rip+s_env_threads]
    call    getenv
    test    rax, rax
    jnz     0f
    mov     ebx, [rip+pr_threads]       # no override: the preference, if any
    test    ebx, ebx
    jz      1f
    jmp     3f
0:
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
    call    plat_sched_getaffinity
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
    call    plat_mmap
    cmp     rax, -4096
    ja      8f
    lea     rdx, [rax+STACK_BYTES]
    lea     rdi, [rip+worker_main]
    mov     esi, r12d
    xor     ecx, ecx
    call    plat_thread_start
    test    eax, eax
    js      8f
    inc     r12d
    jmp     7b
8:  mov     [rip+n_workers], r12d       # fewer threads than planned
9:  pop     r13
    pop     r12
    pop     rbx
    ret

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
    push    r14
    push    r15
    sub     rsp, 16
    mov     ebx, edi
    mov     eax, ebx
    imul    eax, ARENA_SZ
    lea     r13, [rip+thread_arena]
    add     r13, rax
    mov     r14, [rip+pf_next]          # the job: its generation
    shr     r14, 32
1:  cmp     dword ptr [rip+pf_cancel], 0
    jne     9f
    mov     rax, [rip+pf_next]          # a chunk: claimed only while the
    mov     rcx, rax                    #  claim is still this job's (a
    shr     rcx, 32                     #  worker late from the last one
    cmp     ecx, r14d                   #  must not take the next's: the
    jne     9f                          #  count, grain, next index are
    mov     edx, [rip+pf_grain]         #  written apart, the claim and its
    mov     ecx, [rip+pf_count]         #  generation at once)
    cmp     eax, ecx
    jae     9f
    lea     r15, [rax+rdx]              # (index + grain: the high half kept)
    lock cmpxchg [rip+pf_next], r15
    jnz     1b
    add     edx, eax
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
9:  add     rsp, 16
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# pf_job_wait - (the UI thread during a long job) the workers run the chunks;
#   every 100 ms (or when the last one leaves) the progress and a frame
pf_job_wait:
    push    rbx
1:  mov     edi, [rip+pf_next]          # chunks claimed so far
    mov     esi, [rip+pf_count]
    cmp     edi, esi
    cmova   edi, esi
    call    job_pf
    mov     eax, [rip+pf_next]
    cmp     eax, [rip+pf_count]
    jb      2f
    cmp     dword ptr [rip+pf_active], 0
    je      9f
2:  mov     edx, [rip+pf_active]        # sleep until a worker leaves, 100 ms at most
    lea     rdi, [rip+pf_active]
    mov     esi, FUTEX_WAIT_PRIV
    lea     r10, [rip+pf_100ms]
    xor     r8d, r8d
    xor     r9d, r9d
    call    plat_futex
    jmp     1b
9:  pop     rbx
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
    push    r15
    sub     rsp, 8                      # (jobs start with rsp as workers'
    mov     rbx, rdi                    #   do: the same parity as before) fn
    mov     r12, rsi                    # ctx
    mov     r13d, edx                   # count
    mov     r14d, ecx                   # grain
    xor     r15d, r15d                  # who asks: the UI or the background
    mov     eax, [rip+main_tid]         #   thread take turns; a worker (or
    cmp     dword ptr [rip+bg_tid], 0   #   the owner, nested) runs it inline
    je      5f                          #   (no background thread: the UI's,
    call    plat_gettid                             #   need to ask the kernel)
5:
    cmp     eax, [rip+pf_owner]
    jne     6f
    cmp     dword ptr [rip+pf_busy], 0  # (the owner inside a job it ran on
    jne     .Lpf_nested                 #   its own: in parallel, the lock
    jmp     7f                          #   still held)
6:  cmp     eax, [rip+main_tid]
    je      0f
    cmp     eax, [rip+bg_tid]
    jne     .Lpf_nested
0:  mov     r15d, eax
    call    pf_acquire
    mov     [rip+pf_owner], r15d
7:  cmp     dword ptr [rip+n_workers], 0
    je      .Lpf_serial
    cmp     r13d, r14d
    jbe     .Lpf_serial                 # a single chunk: nobody to wake
    mov     dword ptr [rip+pf_next], -1 # the last job's claim closed first
                                        #  (a late worker can read the new
                                        #  count before the new claim)
    mov     dword ptr [rip+pf_busy], 1
    mov     [rip+pf_fn], rbx
    mov     [rip+pf_ctx], r12
    mov     [rip+pf_count], r13d
    mov     [rip+pf_grain], r14d
    mov     dword ptr [rip+pf_cancel], 0
    mov     eax, [rip+pf_gen]           # the claim: the next generation, 0
    inc     eax                         #  (one store, after the rest)
    shl     rax, 32
    mov     [rip+pf_next], rax
    lock inc dword ptr [rip+pf_gen]     # publish (locked op = full barrier)
    lea     rdi, [rip+pf_gen]
    mov     esi, FUTEX_WAKE_PRIV
    mov     edx, 0x7fffffff
    call    futex
    cmp     dword ptr [rip+job_on], 0   # a long job on the UI thread: it
    je      20f                         #  shows how far the workers are
    cmp     r15d, [rip+main_tid]        #  instead of working (jobui.s)
    jne     20f
    call    pf_job_wait
    jmp     3f
20: mov     edi, [rip+n_workers]        # the caller works too
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
    test    r15d, r15d
    jz      5f
    mov     dword ptr [rip+pf_owner], 0
    call    pf_release
5:  add     rsp, 8
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
.Lpf_ret:
    ret

# pf_acquire / pf_release - the parallel_for mutex (futex, 3 states)
pf_acquire:
    xor     eax, eax
    mov     ecx, 1
    lock cmpxchg [rip+pf_lock], ecx
    jz      9f
1:  mov     eax, 2
    xchg    eax, [rip+pf_lock]
    test    eax, eax
    jz      9f
    lea     rdi, [rip+pf_lock]
    mov     esi, FUTEX_WAIT_PRIV
    mov     edx, 2
    call    futex
    jmp     1b
9:  ret
pf_release:
    lock dec dword ptr [rip+pf_lock]
    jz      9f
    mov     dword ptr [rip+pf_lock], 0
    lea     rdi, [rip+pf_lock]
    mov     esi, FUTEX_WAKE_PRIV
    mov     edx, 1
    call    futex
9:  ret

# job_spawn(rdi=fn, rsi=arg) -> eax = thread id (< 0: failed). fn(rdi=arg)
#   runs on the background thread; there is one at a time (bg_tid is set by
#   the kernel when it starts and cleared when it exits). Its parallel_for
#   calls take turns with the UI thread's.
job_spawn:
    push    rbx
    push    r12
    sub     rsp, 8
    mov     rbx, rdi
    mov     r12, rsi
1:  mov     edx, [rip+bg_tid]           # (the last one still leaving)
    test    edx, edx
    jz      2f
    lea     rdi, [rip+bg_tid]
    mov     esi, FUTEX_WAIT
    call    futex
    jmp     1b
2:  cmp     qword ptr [rip+bg_stack], 0
    jne     3f
    xor     edi, edi
    mov     esi, BG_STACK_BYTES
    mov     edx, PROT_RW
    mov     r10d, MAP_STACK_FLAGS
    mov     r8d, -1
    xor     r9d, r9d
    call    plat_mmap
    cmp     rax, -4096
    ja      9f
    mov     [rip+bg_stack], rax
3:  mov     rdx, [rip+bg_stack]
    add     rdx, BG_STACK_BYTES
    mov     rdi, rbx
    mov     rsi, r12
    lea     rcx, [rip+bg_tid]           # 0 again, and a wake, when it ends
    call    plat_thread_start
9:  add     rsp, 8
    pop     r12
    pop     rbx
    ret

# jobs_cancel - ask the running parallel_for to stop claiming chunks
jobs_cancel:
    mov     dword ptr [rip+pf_cancel], 1
    ret

.section .note.GNU-stack,"",@progbits
