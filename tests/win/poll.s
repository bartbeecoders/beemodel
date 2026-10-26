# =============================================================================
#  BeeModel - the Windows platform layer's poll and timerfds, tested on their
#  own (Vibecoding/BeeModel-Win11-Port-Plan.html, W5a). Linked with
#  src/plat_win.s into build/test-poll.exe by scripts/build.sh; run by
#  ci/check-exe.sh under Wine and in the Windows 11 VM. Prints a line per
#  check; the exit code is the number that failed.
# =============================================================================
.intel_syntax noprefix

.globl bee_main
.globl envp

.equ POLLIN,        1
.equ POLLOUT,       4
.equ POLLNVAL,      0x20
.equ TFD_FLAGS,     0x80800             # TFD_CLOEXEC | TFD_NONBLOCK
.equ EAGAIN,        11
.equ EBADF,         9

.macro CHECK cc, text
    lea     rdi, [rip+9f]
    set\cc  al
    movzx   esi, al
    call    report
    .section .rodata
9:  .asciz "\text"
    .text
.endm

# ARM fd, first ms, interval ms
.macro ARM fd, first, every
    lea     rdx, [rip+its]
    mov     qword ptr [rdx], \every / 1000
    mov     qword ptr [rdx+8], (\every % 1000) * 1000000
    mov     qword ptr [rdx+16], \first / 1000
    mov     qword ptr [rdx+24], (\first % 1000) * 1000000
    mov     edi, \fd
    xor     esi, esi
    xor     r10d, r10d
    call    plat_timerfd_settime
.endm

# POLL1 fd, events, ms -> rax, [pfd+6] the revents
.macro POLL1 fd, events, ms
    lea     rdi, [rip+pfd]
    mov     dword ptr [rdi], \fd
    mov     dword ptr [rdi+4], \events
    mov     esi, 1
    mov     edx, \ms
    call    plat_poll
.endm

.text
bee_main:
    and     rsp, -16
    push    rbx
    push    r12
    push    r13
    push    r14

    # a timerfd: not readable until it is due
    mov     edi, 1                      # CLOCK_MONOTONIC
    mov     esi, TFD_FLAGS
    call    plat_timerfd_create
    mov     ebx, eax
    cmp     eax, 3
    CHECK   ge, "timerfd_create: an fd after the standard three"
    mov     edi, ebx
    call    read8
    cmp     rax, -EAGAIN
    CHECK   e, "read before it is armed: -EAGAIN"
    ARM     ebx, 30, 0
    test    rax, rax
    CHECK   z, "timerfd_settime: once, in 30 ms"
    mov     edi, ebx
    call    read8
    cmp     rax, -EAGAIN
    CHECK   e, "read before it is due: -EAGAIN"

    # poll waits for it
    call    t0
    POLL1   ebx, POLLIN, 1000
    mov     r12, rax
    call    since_ms
    mov     r13, rax
    cmp     r12, 1
    CHECK   e, "poll on it: one fd with news"
    cmp     word ptr [rip+pfd+6], POLLIN
    CHECK   e, "its revents: POLLIN"
    cmp     r13, 25
    setge   cl
    cmp     r13, 200
    setl    al
    and     al, cl
    cmp     al, 1
    CHECK   e, "poll came back when it was due (25 .. 200 ms)"
    mov     edi, ebx
    call    read8
    cmp     rax, 8
    CHECK   e, "read: 8 bytes"
    cmp     qword ptr [rip+buf], 1
    CHECK   e, "it came once"
    mov     edi, ebx
    call    read8
    cmp     rax, -EAGAIN
    CHECK   e, "read again: -EAGAIN (once is once)"

    # not armed: poll's timeout
    call    t0
    POLL1   ebx, POLLIN, 20
    mov     r12, rax
    call    since_ms
    mov     r13, rax
    test    r12, r12
    CHECK   z, "poll on it, not armed: nothing in 20 ms"
    cmp     r13, 15
    setge   cl
    cmp     r13, 200
    setl    al
    and     al, cl
    cmp     al, 1
    CHECK   e, "and it waited the 20 ms (15 .. 200 ms)"

    # every 10 ms: read counts what came
    ARM     ebx, 10, 10
    lea     rdi, [rip+ts_55ms]
    xor     esi, esi
    call    plat_nanosleep
    mov     edi, ebx
    call    read8
    cmp     rax, 8
    CHECK   e, "every 10 ms, after 55 ms: read"
    mov     rax, [rip+buf]
    cmp     rax, 4
    setge   cl
    cmp     rax, 8
    setle   al
    and     al, cl
    cmp     al, 1
    CHECK   e, "it came 4 .. 8 times"
    POLL1   ebx, POLLIN, 1000
    cmp     rax, 1
    CHECK   e, "and comes again (poll)"
    ARM     ebx, 0, 0
    test    rax, rax
    CHECK   z, "disarmed (a value of 0)"
    lea     rdi, [rip+ts_55ms]
    xor     esi, esi
    call    plat_nanosleep
    mov     edi, ebx
    call    read8
    cmp     rax, -EAGAIN
    CHECK   e, "disarmed: no more"

    # poll's timeouts go by the ms, not Windows' 15.6 ms tick
    call    t0
    mov     r14d, 20
1:  xor     edi, edi
    xor     esi, esi
    mov     edx, 4
    call    plat_poll
    dec     r14d
    jnz     1b
    call    since_ms
    mov     r13, rax
    cmp     r13, 75
    setge   cl
    cmp     r13, 200
    setl    al
    and     al, cl
    cmp     al, 1
    CHECK   e, "20 polls of 4 ms take 80 ms (75 .. 200; Windows' tick: 312)"

    # the first of two timers ends the wait
    mov     edi, 1
    mov     esi, TFD_FLAGS
    call    plat_timerfd_create
    mov     r12d, eax
    ARM     ebx, 300, 0
    ARM     r12d, 20, 0
    call    t0
    lea     rdi, [rip+pfd]
    mov     [rdi], ebx
    mov     dword ptr [rdi+4], POLLIN
    mov     [rdi+8], r12d
    mov     dword ptr [rdi+12], POLLIN
    mov     esi, 2
    mov     edx, -1
    call    plat_poll
    mov     r14, rax
    call    since_ms
    mov     r13, rax
    cmp     r14, 1
    CHECK   e, "two timers, 300 and 20 ms: one with news"
    cmp     word ptr [rip+pfd+14], POLLIN
    sete    cl
    cmp     word ptr [rip+pfd+6], 0
    sete    al
    and     al, cl
    cmp     al, 1
    CHECK   e, "the 20 ms one"
    cmp     r13, 150
    CHECK   l, "after 20 ms, not 300"

    # files are always ready; bad fds are told, negative ones skipped
    POLL1   1, POLLOUT, 1000
    cmp     rax, 1
    sete    cl
    cmp     word ptr [rip+pfd+6], POLLOUT
    sete    al
    and     al, cl
    cmp     al, 1
    CHECK   e, "poll stdout for POLLOUT: ready"
    POLL1   999, POLLIN, 1000
    cmp     rax, 1
    sete    cl
    cmp     word ptr [rip+pfd+6], POLLNVAL
    sete    al
    and     al, cl
    cmp     al, 1
    CHECK   e, "poll fd 999: POLLNVAL"
    POLL1   -1, POLLIN, 0
    test    rax, rax
    CHECK   z, "poll fd -1: skipped"

    mov     edi, ebx
    call    plat_close
    test    rax, rax
    CHECK   z, "close the timerfd"
    mov     edi, ebx
    call    read8
    cmp     rax, -EBADF
    CHECK   e, "read after close: -EBADF"
    mov     edi, r12d
    call    plat_close

    mov     edi, [rip+fails]
    call    plat_exit_group

# read8(edi = fd) -> rax: plat_read of 8 bytes into buf
read8:
    lea     rsi, [rip+buf]
    mov     edx, 8
    jmp     plat_read

# t0 - the clock now, into ts0; since_ms -> rax = ms since t0
t0:
    mov     edi, 1
    lea     rsi, [rip+ts0]
    jmp     plat_clock_gettime
since_ms:
    sub     rsp, 8
    mov     edi, 1
    lea     rsi, [rip+ts1]
    call    plat_clock_gettime
    add     rsp, 8
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
ts_55ms:  .quad 0, 55000000

.section .bss
.align 8
envp:      .skip 8
fails:     .skip 4
.align 8
buf:       .skip 8
ts0:       .skip 16
ts1:       .skip 16
its:       .skip 32
pfd:       .skip 16
