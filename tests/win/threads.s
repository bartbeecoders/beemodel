# =============================================================================
#  BeeModel - the Windows platform layer's threads, futexes and time, tested
#  on their own (Vibecoding/BeeModel-Win11-Port-Plan.html, W3c). Linked with
#  src/plat_win.s into build/test-threads.exe by scripts/build.sh; run by
#  ci/check-exe.sh under Wine and in the Windows 11 VM. Prints a line per
#  check; the exit code is the number that failed.
# =============================================================================
.intel_syntax noprefix

.globl bee_main
.globl envp

.equ PROT_RW,       3
.equ MAP_STACK,     0x24022             # private | anonymous | noreserve | stack
.equ MAP_NORES,     0x4022
.equ STACK_BYTES,   0x40000
.equ NTHREADS,      8
.equ ADDS,          100000
.equ FUTEX_WAIT,    128                 # (private)
.equ FUTEX_WAKE,    129
.equ EAGAIN,        11
.equ ETIMEDOUT,     110

.macro CHECK cc, text
    lea     rdi, [rip+9f]
    set\cc  al
    movzx   esi, al
    call    report
    .section .rodata
9:  .asciz "\text"
    .text
.endm

.text
bee_main:
    and     rsp, -16
    push    rbx
    push    r12
    push    r13
    push    r14

    # time: the clocks
    mov     edi, 1
    lea     rsi, [rip+ts0]
    call    plat_clock_gettime
    test    rax, rax
    CHECK   z, "clock_gettime(CLOCK_MONOTONIC)"
    lea     rdi, [rip+ts_50ms]
    xor     esi, esi
    call    plat_nanosleep
    test    rax, rax
    CHECK   z, "nanosleep 50 ms"
    mov     edi, 1
    lea     rsi, [rip+ts1]
    call    plat_clock_gettime
    call    elapsed_ms                  # rax = ts1 - ts0 in ms
    mov     rbx, rax
    cmp     rax, 45
    setge   cl
    cmp     rax, 1000
    setl    al
    and     al, cl
    cmp     al, 1
    CHECK   e, "the monotonic clock saw the 50 ms go by (45 ms .. 1 s)"
    xor     edi, edi
    lea     rsi, [rip+ts0]
    call    plat_clock_gettime
    mov     rbx, [rip+ts0]
    cmp     rbx, 1700000000
    CHECK   g, "clock_gettime(CLOCK_REALTIME): today, in seconds since 1970"
    cmp     qword ptr [rip+ts0+8], 1000000000
    CHECK   b, "CLOCK_REALTIME: nanoseconds under a second"
    xor     edi, edi
    call    plat_time
    sub     rax, rbx
    cmp     rax, 2
    CHECK   be, "time(): the same second as CLOCK_REALTIME"

    # how many processors
    xor     edi, edi
    mov     esi, 128
    lea     rdx, [rip+mask]
    call    plat_sched_getaffinity
    cmp     rax, 128
    CHECK   e, "sched_getaffinity: 128 bytes of mask"
    xor     ebx, ebx
    xor     ecx, ecx
    lea     rdx, [rip+mask]
1:  popcnt  rax, [rdx+rcx*8]
    add     ebx, eax
    inc     ecx
    cmp     ecx, 16
    jb      1b
    mov     [rip+ncpu], ebx
    cmp     ebx, 1
    CHECK   ge, "sched_getaffinity: at least one processor"

    # futexes on one thread
    lea     rdi, [rip+fx_word]
    mov     esi, FUTEX_WAIT
    mov     edx, 1                      # (the word is 0)
    xor     r10d, r10d
    call    plat_futex
    cmp     rax, -EAGAIN
    CHECK   e, "futex wait on a word that changed: -EAGAIN"
    mov     edi, 1
    lea     rsi, [rip+ts0]
    call    plat_clock_gettime
    lea     rdi, [rip+fx_word]
    mov     esi, FUTEX_WAIT
    xor     edx, edx
    lea     r10, [rip+ts_50ms]
    call    plat_futex
    mov     r12, rax
    mov     edi, 1
    lea     rsi, [rip+ts1]
    call    plat_clock_gettime
    cmp     r12, -ETIMEDOUT
    CHECK   e, "futex wait, 50 ms and no wake: -ETIMEDOUT"
    call    elapsed_ms
    cmp     rax, 40
    CHECK   ge, "and it waited the 50 ms"

    # a thread with a tid word: set before it runs, 0 and a wake at its end
    call    new_stack
    mov     rdx, rax
    lea     rdi, [rip+waker]
    lea     rsi, [rip+fx_word]
    lea     rcx, [rip+tid]
    call    plat_thread_start
    mov     r12, rax
    test    eax, eax
    CHECK   g, "thread_start: a thread id"
    lea     rdi, [rip+fx_word]             # the waker sets the word and wakes us
    mov     esi, FUTEX_WAIT
    xor     edx, edx
    xor     r10d, r10d
1:  cmp     dword ptr [rip+fx_word], 0
    jne     2f
    call    plat_futex
    jmp     1b
2:  cmp     dword ptr [rip+fx_word], 7
    CHECK   e, "futex: woken by another thread, its write seen"
3:  mov     edx, [rip+tid]              # the thread's end
    test    edx, edx
    jz      4f
    lea     rdi, [rip+tid]
    mov     esi, FUTEX_WAIT
    xor     r10d, r10d
    call    plat_futex
    jmp     3b
4:  cmp     dword ptr [rip+waker_tid], r12d
    CHECK   e, "the thread's gettid is the id thread_start gave"
    cmp     dword ptr [rip+tid], 0
    CHECK   e, "the tid word went to 0 when it ended (and the wait woke)"

    # NTHREADS threads, each adding ADDS to a counter; a range touched by
    # all of them for the first time (commit on fault, on their stacks)
    xor     edi, edi
    mov     rsi, 0x40000000
    mov     edx, PROT_RW
    mov     r10d, MAP_NORES
    mov     r8, -1
    xor     r9d, r9d
    call    plat_mmap
    mov     [rip+lazy], rax
    xor     r13d, r13d
5:  call    new_stack
    mov     rdx, rax
    lea     rdi, [rip+adder]
    mov     esi, r13d
    lea     rcx, [rip+tids]
    lea     rcx, [rcx+r13*4]
    call    plat_thread_start
    inc     r13d
    cmp     r13d, NTHREADS
    jb      5b
    xor     r13d, r13d
6:  lea     rdi, [rip+tids]             # wait for each to end
    lea     rdi, [rdi+r13*4]
    mov     edx, [rdi]
    test    edx, edx
    jz      7f
    mov     esi, FUTEX_WAIT
    xor     r10d, r10d
    call    plat_futex
    jmp     6b
7:  inc     r13d
    cmp     r13d, NTHREADS
    jb      6b
    cmp     qword ptr [rip+counter], NTHREADS*ADDS
    CHECK   e, "8 threads on their own stacks: every one of 800000 locked adds counted"
    mov     rax, [rip+lazy]
    xor     ecx, ecx
    xor     edx, edx
8:  mov     rsi, rcx
    shl     rsi, 24                     # 16 MiB apart
    add     edx, [rax+rsi]
    inc     ecx
    cmp     ecx, NTHREADS
    jb      8b
    cmp     edx, NTHREADS*(NTHREADS+1)/2
    CHECK   e, "each wrote its own untouched page of a reserved range (commit on fault on any thread)"

    # NTHREADS threads at a barrier, then all into the same untouched
    # 64 KiB at once: the faults race, every one must be let through
    mov     r14d, 20                    # (20 rounds, a fresh range each)
10: xor     edi, edi
    mov     esi, 0x100000
    mov     edx, PROT_RW
    mov     r10d, MAP_NORES
    mov     r8, -1
    xor     r9d, r9d
    call    plat_mmap
    mov     [rip+lazy], rax
    mov     dword ptr [rip+ready], 0
    mov     dword ptr [rip+go], 0
    xor     r13d, r13d
11: call    new_stack
    mov     rdx, rax
    lea     rdi, [rip+racer]
    mov     esi, r13d
    lea     rcx, [rip+tids]
    lea     rcx, [rcx+r13*4]
    call    plat_thread_start
    inc     r13d
    cmp     r13d, NTHREADS
    jb      11b
12: cmp     dword ptr [rip+ready], NTHREADS
    jb      12b
    mov     dword ptr [rip+go], 1
    xor     r13d, r13d
13: lea     rdi, [rip+tids]
    lea     rdi, [rdi+r13*4]
    mov     edx, [rdi]
    test    edx, edx
    jz      14f
    mov     esi, FUTEX_WAIT
    xor     r10d, r10d
    call    plat_futex
    jmp     13b
14: inc     r13d
    cmp     r13d, NTHREADS
    jb      13b
    dec     r14d
    jnz     10b
    mov     eax, 1
    test    eax, eax
    CHECK   nz, "8 threads at once into the same untouched 64 KiB, 20 times: no fault lost"

    mov     edi, [rip+fails]
    call    plat_exit_group

# racer(edi=index): ready, wait for go, then a write at index * 4 KiB
racer:
    lock inc dword ptr [rip+ready]
1:  cmp     dword ptr [rip+go], 0
    je      1b
    mov     rax, [rip+lazy]
    shl     edi, 12
    mov     dword ptr [rax+rdi], 1
    ret

# waker(rdi=&word): 7 in the word, then a wake
waker:
    sub     rsp, 8
    push    rdi
    call    plat_gettid
    mov     [rip+waker_tid], eax
    pop     rdi
    push    rdi
    lea     rdi, [rip+ts_50ms]          # (so the main thread is asleep)
    xor     esi, esi
    call    plat_nanosleep
    pop     rdi
    mov     dword ptr [rdi], 7
    mov     esi, FUTEX_WAKE
    mov     edx, 1
    call    plat_futex
    add     rsp, 8
    ret

# adder(edi=index): ADDS locked adds, then index+1 into its page of lazy
adder:
    mov     ecx, ADDS
1:  lock inc qword ptr [rip+counter]
    dec     ecx
    jnz     1b
    mov     rax, [rip+lazy]
    movsxd  rcx, edi
    shl     rcx, 24
    inc     edi
    mov     [rax+rcx], edi
    ret

# new_stack -> rax = the top of a fresh STACK_BYTES stack
new_stack:
    sub     rsp, 8
    xor     edi, edi
    mov     esi, STACK_BYTES
    mov     edx, PROT_RW
    mov     r10d, MAP_STACK
    mov     r8, -1
    xor     r9d, r9d
    call    plat_mmap
    add     rax, STACK_BYTES
    add     rsp, 8
    ret

# elapsed_ms -> rax = ts1 - ts0 in milliseconds
elapsed_ms:
    mov     rax, [rip+ts1]
    sub     rax, [rip+ts0]
    imul    rax, rax, 1000
    mov     rcx, [rip+ts1+8]
    sub     rcx, [rip+ts0+8]
    mov     r8, rax
    mov     rax, rcx
    cqo
    mov     ecx, 1000000
    idiv    rcx
    add     rax, r8
    ret

report:
    push    rbx
    push    r12
    sub     rsp, 8
    mov     rbx, rdi
    mov     r12d, esi
    lea     rsi, [rip+s_ok]
    test    r12d, r12d
    jnz     1f
    inc     dword ptr [rip+fails]
    lea     rsi, [rip+s_fail]
1:  mov     edi, 1
    mov     edx, 7
    call    plat_write
    mov     rdi, rbx
    xor     edx, edx
2:  cmp     byte ptr [rdi+rdx], 0
    je      3f
    inc     edx
    jmp     2b
3:  mov     rsi, rbx
    mov     edi, 1
    call    plat_write
    mov     edi, 1
    lea     rsi, [rip+s_nl]
    mov     edx, 1
    call    plat_write
    add     rsp, 8
    pop     r12
    pop     rbx
    ret

.section .rodata
s_ok:     .ascii "  ok   "
s_fail:   .ascii "  FAIL "
s_nl:     .ascii "\n"
.balign 8
ts_50ms:  .quad 0, 50000000

.section .bss
.align 8
envp:      .skip 8
fails:     .skip 4
ncpu:      .skip 4
fx_word:     .skip 4
tid:       .skip 4
waker_tid: .skip 4
.align 8
counter:   .skip 8
lazy:      .skip 8
ts0:       .skip 16
ts1:       .skip 16
mask:      .skip 128
tids:      .skip 4*NTHREADS
ready:     .skip 4
go:        .skip 4
