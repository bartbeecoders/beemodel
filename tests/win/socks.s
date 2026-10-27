# =============================================================================
#  BeeModel - the Windows platform layer's sockets, tested on their own
#  (Vibecoding/BeeModel-Win11-Port-Plan.html, W6b). Linked with
#  src/plat_win.s into build/test-socks.exe by scripts/build.sh; run by
#  ci/check-exe.sh under Wine and in the Windows 11 VM. The peer of the TCP
#  checks is this program again, in the mode "tcp" (it connects, waits
#  100 ms, sends ping and wants pong back), so poll's wait on a socket is
#  seen to end when the data comes. Prints a line per check; the exit code
#  is the number that failed.
# =============================================================================
.intel_syntax noprefix

.globl bee_main
.globl envp

.equ POLLIN,        1
.equ POLLOUT,       4
.equ O_NONBLOCK,    0x800
.equ F_GETFL,       3
.equ F_SETFL,       4
.equ EAGAIN,        11
.equ EADDRINUSE,    98
.equ ECONNREFUSED,  111
.equ EAFNOSUPPORT,  97
.equ PS_KEEP,       -1
.equ AF_UNIX,       1
.equ AF_INET,       2
.equ AF_INET6,      10
.equ SOCK_STREAM,   1
.equ SOCK_NB,       0x80801             # STREAM | NONBLOCK | CLOEXEC
.equ SOCK_CL,       0x80001             # STREAM | CLOEXEC
.equ MSG_NOSIGNAL,  0x4000
.equ PORT,          39461               # (the next one has no listener)

.macro CHECK cc, text
    lea     rdi, [rip+9f]
    set\cc  al
    movzx   esi, al
    call    report
    .section .rodata
9:  .asciz "\text"
    .text
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
    cmp     edi, 2                      # the peer?
    jl      1f
    mov     rdi, [rsi+8]
    lea     rsi, [rip+m_tcp]
    call    streq
    jz      child_tcp
1:  lea     rdi, [rip+self]
    mov     esi, 4096
    call    plat_self_path
    lea     rax, [rip+self]
    mov     [rip+av], rax

    # random bytes
    lea     rdi, [rip+buf]
    mov     esi, 32
    xor     edx, edx
    call    plat_getrandom
    cmp     rax, 32
    CHECK   e, "getrandom: 32 bytes"
    lea     rdi, [rip+buf+32]
    mov     esi, 32
    xor     edx, edx
    call    plat_getrandom
    lea     rsi, [rip+buf]
    lea     rdi, [rip+buf+32]
    mov     ecx, 32
    repe    cmpsb
    CHECK   ne, "and 32 more, not the same"
    lea     rdi, [rip+buf]
    mov     esi, 3
    xor     edx, edx
    call    plat_getrandom
    cmp     rax, 3
    CHECK   e, "getrandom: 3 bytes (less than a word)"

    # a TCP server on 127.0.0.1
    mov     edi, AF_INET6
    mov     esi, SOCK_CL
    xor     edx, edx
    call    plat_socket
    cmp     rax, -EAFNOSUPPORT
    CHECK   e, "AF_INET6: -EAFNOSUPPORT (not used)"
    mov     edi, AF_INET
    mov     esi, SOCK_NB
    xor     edx, edx
    call    plat_socket
    mov     ebx, eax
    cmp     eax, 3
    CHECK   ge, "socket(AF_INET, non-blocking): an fd"
    mov     edi, ebx
    mov     esi, 1                      # SOL_SOCKET, SO_REUSEADDR
    mov     edx, 2
    lea     r10, [rip+one]
    mov     r8d, 4
    call    plat_setsockopt
    test    rax, rax
    CHECK   z, "SO_REUSEADDR: 0"
    mov     edi, ebx
    lea     rsi, [rip+sin]
    mov     edx, 16
    call    plat_bind
    test    rax, rax
    CHECK   z, "bind 127.0.0.1:39461"
    mov     edi, ebx
    mov     esi, 8
    call    plat_listen
    test    rax, rax
    CHECK   z, "listen"
    mov     edi, AF_INET
    mov     esi, SOCK_CL
    xor     edx, edx
    call    plat_socket
    mov     r12d, eax
    mov     edi, eax
    lea     rsi, [rip+sin]
    mov     edx, 16
    call    plat_bind
    cmp     rax, -EADDRINUSE
    CHECK   e, "a second bind of the port: -EADDRINUSE"
    mov     edi, r12d
    call    plat_close
    mov     edi, ebx
    xor     esi, esi
    xor     edx, edx
    mov     r10d, O_NONBLOCK
    call    plat_accept4
    cmp     rax, -EAGAIN
    CHECK   e, "accept, nobody there: -EAGAIN"
    call    t0
    POLL1   ebx, POLLIN, 50
    mov     r12, rax
    call    since_ms
    test    r12, r12
    sete    cl
    cmp     rax, 40
    setge   al
    and     al, cl
    cmp     al, 1
    CHECK   e, "poll on it: nothing in 50 ms (and it waited)"

    # the peer: it connects, then sends ping after 100 ms
    lea     rax, [rip+m_tcp]
    mov     [rip+av+8], rax
    mov     dword ptr [rip+fmap], PS_KEEP
    mov     dword ptr [rip+fmap+4], PS_KEEP
    mov     dword ptr [rip+fmap+8], PS_KEEP
    mov     dword ptr [rip+fmap+12], PS_KEEP
    lea     rdi, [rip+self]
    lea     rsi, [rip+av]
    mov     rdx, [rip+envp]
    lea     rcx, [rip+fmap]
    xor     r8d, r8d
    call    plat_spawn
    mov     r14d, eax
    test    eax, eax
    CHECK   g, "the peer started"
    POLL1   ebx, POLLIN, 10000
    cmp     rax, 1
    CHECK   e, "it connects: poll on the server says POLLIN"
    mov     edi, ebx                    # (blocking, then O_NONBLOCK: cosync's way)
    xor     esi, esi
    xor     edx, edx
    mov     r10d, 0x80000
    call    plat_accept4
    mov     r12d, eax
    cmp     eax, 3
    CHECK   ge, "accept: its connection's fd"
    mov     edi, r12d
    mov     esi, F_SETFL
    mov     edx, O_NONBLOCK
    call    plat_fcntl
    mov     edi, r12d
    mov     esi, 6                      # IPPROTO_TCP, TCP_NODELAY
    mov     edx, 1
    lea     r10, [rip+one]
    mov     r8d, 4
    call    plat_setsockopt
    test    rax, rax
    CHECK   z, "TCP_NODELAY: 0"
    mov     edi, r12d
    mov     esi, 1                      # SO_SNDBUF
    mov     edx, 7
    lea     r10, [rip+sndbuf]
    mov     r8d, 4
    call    plat_setsockopt
    test    rax, rax
    CHECK   z, "SO_SNDBUF: 0"
    mov     edi, r12d
    call    readbuf
    cmp     rax, -EAGAIN
    CHECK   e, "read before it sends: -EAGAIN"
    call    t0
    POLL1   r12d, POLLIN, 10000
    mov     r13, rax
    call    since_ms
    cmp     r13, 1
    sete    cl
    cmp     rax, 50
    setge   al
    and     al, cl
    cmp     al, 1
    CHECK   e, "poll waits for its data (about 100 ms), then POLLIN"
    xor     edi, edi                    # into memory not yet touched (MAP_NORESERVE,
    mov     esi, 64 << 20               #  as cosync's buffers): Windows' recv cannot
    mov     edx, 3                      #  fault it in, so it is touched first
    mov     r10d, 0x4022
    mov     r8, -1
    xor     r9d, r9d
    call    plat_mmap
    lea     r13, [rax + (32 << 20) + 100]
    mov     edi, r12d
    mov     rsi, r13
    mov     edx, 4 << 20
    call    plat_read
    cmp     rax, 4
    sete    cl
    cmp     dword ptr [r13], 'p' | 'i' << 8 | 'n' << 16 | 'g' << 24
    sete    al
    and     al, cl
    cmp     al, 1
    CHECK   e, "read: ping (into reserved memory, 4 MiB asked)"
    POLL1   r12d, POLLOUT, 0
    cmp     word ptr [rip+pfd+6], POLLOUT
    CHECK   e, "poll for POLLOUT: room to write"
    mov     edi, r12d
    lea     rsi, [rip+s_pong]
    mov     edx, 4
    mov     r10d, MSG_NOSIGNAL
    xor     r8d, r8d
    xor     r9d, r9d
    call    plat_sendto
    cmp     rax, 4
    CHECK   e, "sendto: pong"
    mov     edi, r14d
    lea     rsi, [rip+status]
    xor     edx, edx
    xor     r10d, r10d
    call    plat_wait4
    cmp     dword ptr [rip+status], 0
    CHECK   e, "the peer got pong (its exit code 0)"
    POLL1   r12d, POLLIN, 5000
    cmp     rax, 1
    CHECK   e, "it has gone: poll says POLLIN"
    mov     edi, r12d
    call    readbuf
    test    rax, rax
    CHECK   z, "and read gives the end (0)"
    mov     edi, r12d
    call    plat_close
    test    rax, rax
    CHECK   z, "close the connection"
    mov     edi, ebx
    call    plat_close
    test    rax, rax
    CHECK   z, "close the server"
    mov     edi, ebx
    call    readbuf
    cmp     rax, -9
    CHECK   e, "read after close: -EBADF"

    # a blocking connect to a port nobody listens on
    mov     edi, AF_INET
    mov     esi, SOCK_CL
    xor     edx, edx
    call    plat_socket
    mov     ebx, eax
    mov     edi, eax
    lea     rsi, [rip+sin_none]
    mov     edx, 16
    call    plat_connect
    cmp     rax, -ECONNREFUSED
    CHECK   e, "connect, nobody listening: -ECONNREFUSED"
    mov     edi, ebx
    mov     esi, F_SETFL
    mov     edx, O_NONBLOCK
    call    plat_fcntl
    mov     edi, ebx
    mov     esi, F_GETFL
    xor     edx, edx
    call    plat_fcntl
    cmp     rax, O_NONBLOCK
    CHECK   e, "fcntl F_SETFL / F_GETFL: O_NONBLOCK"
    mov     edi, ebx
    call    plat_close
    mov     edi, 1                      # (not a socket)
    lea     rsi, [rip+sin]
    mov     edx, 16
    call    plat_bind
    test    rax, rax
    CHECK   s, "bind on a file: an error"

    # AF_UNIX: a server, a link to it, a client through the link
    lea     rdi, [rip+un_path]
    call    plat_unlink
    lea     rdi, [rip+ln_path]
    call    plat_unlink
    mov     edi, AF_UNIX
    mov     esi, SOCK_NB
    xor     edx, edx
    call    plat_socket
    mov     ebx, eax
    cmp     rax, -EAFNOSUPPORT          # (Wine's Winsock has no AF_UNIX: Windows 10 1803 on has)
    jne     1f
    lea     rdi, [rip+s_nounix]
    call    say
    jmp     .Lend
1:  cmp     eax, 3
    CHECK   ge, "socket(AF_UNIX): an fd"
    lea     rdi, [rip+sun]
    mov     word ptr [rdi], AF_UNIX
    add     rdi, 2
    lea     rsi, [rip+un_path]
    call    strcpy
    mov     edi, ebx
    lea     rsi, [rip+sun]
    mov     edx, 110
    call    plat_bind
    test    rax, rax
    CHECK   z, "bind test-socks.sock"
    mov     edi, ebx
    mov     esi, 4
    call    plat_listen
    test    rax, rax
    CHECK   z, "listen"
    lea     rdi, [rip+un_path]
    lea     rsi, [rip+ln_path]
    call    plat_symlink
    test    rax, rax
    CHECK   z, "symlink test-socks.link to it"
    mov     edi, AF_UNIX
    mov     esi, SOCK_CL
    xor     edx, edx
    call    plat_socket
    mov     r12d, eax
    lea     rdi, [rip+sun]
    add     rdi, 2
    lea     rsi, [rip+ln_path]
    call    strcpy
    mov     edi, r12d
    lea     rsi, [rip+sun]
    mov     edx, 110
    call    plat_connect
    test    rax, rax
    CHECK   z, "connect through the link"
    POLL1   ebx, POLLIN, 5000
    mov     edi, ebx
    xor     esi, esi
    xor     edx, edx
    xor     r10d, r10d
    call    plat_accept4
    mov     r13d, eax
    cmp     eax, 3
    CHECK   ge, "accept it"
    mov     edi, r12d
    lea     rsi, [rip+s_pong]
    mov     edx, 4
    call    plat_write
    cmp     rax, 4
    CHECK   e, "write 4 bytes"
    mov     edi, r13d                   # (blocking: it waits for them)
    call    readbuf
    cmp     rax, 4
    sete    cl
    cmp     dword ptr [rip+buf], 'p' | 'o' << 8 | 'n' << 16 | 'g' << 24
    sete    al
    and     al, cl
    cmp     al, 1
    CHECK   e, "and read them at the other end"
    mov     edi, r12d
    call    plat_close
    mov     edi, r13d
    call    plat_close
    mov     edi, ebx
    call    plat_close
    lea     rdi, [rip+ln_path]
    call    plat_unlink
    lea     rdi, [rip+un_path]
    call    plat_unlink
    test    rax, rax
    CHECK   z, "unlink the socket's file"

.Lend:
    mov     edi, [rip+fails]
    call    plat_exit_group

# the peer: connect (blocking), wait 100 ms, ping, then pong back -> exit 0
child_tcp:
    mov     edi, AF_INET
    mov     esi, SOCK_CL
    xor     edx, edx
    call    plat_socket
    mov     ebx, eax
    mov     edi, eax
    lea     rsi, [rip+sin]
    mov     edx, 16
    call    plat_connect
    test    rax, rax
    jnz     8f
    lea     rdi, [rip+ts_100ms]
    xor     esi, esi
    call    plat_nanosleep
    mov     edi, ebx
    lea     rsi, [rip+s_ping]
    mov     edx, 4
    call    plat_write
    cmp     rax, 4
    jne     8f
    mov     edi, ebx
    call    readbuf
    cmp     rax, 4
    jne     8f
    cmp     dword ptr [rip+buf], 'p' | 'o' << 8 | 'n' << 16 | 'g' << 24
    jne     8f
    mov     edi, ebx
    call    plat_close
    xor     edi, edi
    call    plat_exit_group
8:  mov     edi, 1
    call    plat_exit_group

# say(rdi = text, 0-ended) - to stdout
say:
    mov     rsi, rdi
    xor     edx, edx
1:  cmp     byte ptr [rsi+rdx], 0
    je      2f
    inc     edx
    jmp     1b
2:  mov     edi, 1
    jmp     plat_write

# readbuf(edi = fd) -> rax: plat_read of up to 4096 bytes into buf
readbuf:
    lea     rsi, [rip+buf]
    mov     edx, 4096
    jmp     plat_read

# strcpy(rdi = to, rsi = from, with its 0)
strcpy:
1:  mov     al, [rsi]
    mov     [rdi], al
    inc     rsi
    inc     rdi
    test    al, al
    jnz     1b
    ret

# streq(rdi, rsi) -> ZF set when the same
streq:
    xor     ecx, ecx
1:  mov     al, [rdi+rcx]
    cmp     al, [rsi+rcx]
    jne     9f
    inc     ecx
    test    al, al
    jnz     1b
9:  ret

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
m_tcp:    .asciz "tcp"
s_ping:   .ascii "ping"
s_pong:   .ascii "pong"
un_path:  .asciz "test-socks.sock"
ln_path:  .asciz "test-socks.link"
s_nounix: .asciz "  skip AF_UNIX: this Winsock has none (Wine)\n"
.balign 4
one:      .long 1
sndbuf:   .long 16384
.balign 8
sin:      .short AF_INET                # 127.0.0.1:PORT
          .byte PORT >> 8, PORT & 255
          .byte 127, 0, 0, 1
          .quad 0
sin_none: .short AF_INET                # 127.0.0.1:PORT+1
          .byte (PORT+1) >> 8, (PORT+1) & 255
          .byte 127, 0, 0, 1
          .quad 0
ts_100ms: .quad 0, 100000000

.section .bss
.align 8
envp:      .skip 8
fails:     .skip 4
status:    .skip 4
.align 8
av:        .skip 8*4
fmap:      .skip 16
pfd:       .skip 16
ts0:       .skip 16
ts1:       .skip 16
sun:       .skip 112
self:      .skip 4096
buf:       .skip 4096
