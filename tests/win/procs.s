# =============================================================================
#  BeeModel - the Windows platform layer's pipes and child processes, tested
#  on their own (Vibecoding/BeeModel-Win11-Port-Plan.html, W6a). Linked with
#  src/plat_win.s into build/test-procs.exe by scripts/build.sh; run by
#  ci/check-exe.sh under Wine and in the Windows 11 VM. The children are
#  this program again, in a mode its first argument names (args, exit N,
#  sleep, env, cat), so the checks need nothing installed. Prints a line
#  per check; the exit code is the number that failed.
# =============================================================================
.intel_syntax noprefix

.globl bee_main
.globl envp

.equ POLLIN,        1
.equ O_NONBLOCK,    0x800
.equ F_SETFL,       4
.equ WNOHANG,       1
.equ SIGTERM,       15
.equ EAGAIN,        11
.equ ENOENT,        2
.equ PS_KEEP,       -1
.equ PS_NULL,       -2
.equ AF_UNIX,       1
.equ SOCK_STREAM,   1

.macro CHECK cc, text
    lea     rdi, [rip+9f]
    set\cc  al
    movzx   esi, al
    call    report
    .section .rodata
9:  .asciz "\text"
    .text
.endm

# SPAWN mode, stdin fd, stdout fd -> rax = the pid (argv: self, mode, then
#   what [rip+extra] lists)
.macro SPAWN mode, fin, fout
    lea     rax, [rip+\mode]
    mov     [rip+av+8], rax
    mov     eax, \fin
    mov     [rip+fmap], eax
    mov     eax, \fout
    mov     [rip+fmap+4], eax
    mov     dword ptr [rip+fmap+8], PS_KEEP
    mov     dword ptr [rip+fmap+12], PS_KEEP
    lea     rdi, [rip+self]
    lea     rsi, [rip+av]
    mov     rdx, [rip+envp]
    lea     rcx, [rip+fmap]
    xor     r8d, r8d
    call    plat_spawn
.endm

.text
bee_main:
    and     rsp, -16
    push    rbx
    push    r12
    push    r13
    push    r14
    cmp     edi, 2                      # a child?
    jl      1f
    mov     r12, rsi
    mov     rdi, [rsi+8]
    lea     rsi, [rip+m_args]
    call    streq
    jz      child_args
    mov     rdi, [r12+8]
    lea     rsi, [rip+m_exit]
    call    streq
    jz      child_exit
    mov     rdi, [r12+8]
    lea     rsi, [rip+m_sleep]
    call    streq
    jz      child_sleep
    mov     rdi, [r12+8]
    lea     rsi, [rip+m_env]
    call    streq
    jz      child_env
    mov     rdi, [r12+8]
    lea     rsi, [rip+m_cat]
    call    streq
    jz      child_cat
1:  lea     rdi, [rip+self]
    mov     esi, 4096
    call    plat_self_path
    test    rax, rax
    CHECK   nz, "this program's path (for its children)"
    lea     rax, [rip+self]
    mov     [rip+av], rax

    # a pipe: in at one end, out at the other
    lea     rdi, [rip+fds]
    xor     esi, esi
    call    plat_pipe2
    test    rax, rax
    CHECK   z, "pipe2"
    mov     edi, [rip+fds+4]
    lea     rsi, [rip+s_hello]
    mov     edx, 5
    call    plat_write
    cmp     rax, 5
    CHECK   e, "write 5 bytes into it"
    mov     edi, [rip+fds]
    call    readbuf
    cmp     rax, 5
    sete    cl
    cmp     dword ptr [rip+buf], 'h' | 'e' << 8 | 'l' << 16 | 'l' << 24
    sete    al
    and     al, cl
    cmp     al, 1
    CHECK   e, "and read them at the other"
    mov     edi, [rip+fds]
    mov     esi, F_SETFL
    mov     edx, O_NONBLOCK
    call    plat_fcntl
    mov     edi, [rip+fds]
    call    readbuf
    cmp     rax, -EAGAIN
    CHECK   e, "O_NONBLOCK, empty: -EAGAIN"
    mov     edi, [rip+fds]
    mov     esi, 50
    call    poll1
    test    rax, rax
    CHECK   z, "poll, empty: nothing in 50 ms"
    mov     edi, [rip+fds+4]
    lea     rsi, [rip+s_hello]
    mov     edx, 5
    call    plat_write
    mov     edi, [rip+fds]
    mov     esi, 1000
    call    poll1
    cmp     rax, 1
    CHECK   e, "written: poll says POLLIN"
    mov     edi, [rip+fds+4]
    call    plat_close
    mov     edi, [rip+fds]
    call    readbuf
    cmp     rax, 5
    CHECK   e, "the writer closed: what it wrote first"
    mov     edi, [rip+fds]
    mov     esi, 1000
    call    poll1
    cmp     rax, 1
    CHECK   e, "then poll says POLLIN (the end)"
    mov     edi, [rip+fds]
    call    readbuf
    test    rax, rax
    CHECK   z, "and read says 0"
    mov     edi, [rip+fds]
    call    plat_close
    test    rax, rax
    CHECK   z, "close it"

    # a child's output through a pipe, its arguments as they were
    lea     rdi, [rip+fds]
    xor     esi, esi
    call    plat_pipe2
    mov     edi, [rip+fds]
    mov     esi, F_SETFL
    mov     edx, O_NONBLOCK
    call    plat_fcntl
    lea     rax, [rip+a1]
    mov     [rip+av+16], rax
    lea     rax, [rip+a2]
    mov     [rip+av+24], rax
    lea     rax, [rip+a3]
    mov     [rip+av+32], rax
    lea     rax, [rip+a4]
    mov     [rip+av+40], rax
    lea     rax, [rip+a5]
    mov     [rip+av+48], rax
    lea     rax, [rip+a6]
    mov     [rip+av+56], rax
    lea     rax, [rip+a7]
    mov     [rip+av+64], rax
    SPAWN   m_args, PS_NULL, [rip+fds+4]
    mov     r12, rax
    test    eax, eax
    CHECK   g, "spawn a child (its pid)"
    mov     edi, [rip+fds+4]
    call    plat_close
    mov     qword ptr [rip+av+16], 0
    call    drain                       # its output, to the end
    lea     rdi, [rip+out]
    lea     rsi, [rip+want_args]
    call    streq
    pushfq
    CHECK   z, "its arguments came as they were (drive paths in Windows' form)"
    popfq
    jz      1f
    lea     rsi, [rip+out]              # (what came instead)
    call    say
1:
    mov     edi, r12d
    lea     rsi, [rip+status]
    xor     edx, edx
    xor     r10d, r10d
    call    plat_wait4
    cmp     rax, r12
    sete    cl
    cmp     dword ptr [rip+status], 0
    sete    al
    and     al, cl
    cmp     al, 1
    CHECK   e, "wait4: it ended, exit code 0"
    mov     edi, r12d
    lea     rsi, [rip+status]
    xor     edx, edx
    xor     r10d, r10d
    call    plat_wait4
    cmp     rax, -10
    CHECK   e, "wait4 again: -ECHILD"

    # its exit code
    lea     rax, [rip+s_7]
    mov     [rip+av+16], rax
    mov     qword ptr [rip+av+24], 0
    SPAWN   m_exit, PS_NULL, PS_NULL
    mov     r12, rax
    mov     qword ptr [rip+av+16], 0
    mov     edi, r12d
    lea     rsi, [rip+status]
    xor     edx, edx
    xor     r10d, r10d
    call    plat_wait4
    cmp     dword ptr [rip+status], 7 << 8
    CHECK   e, "a child's exit code 7: status 7 << 8"

    # still running: WNOHANG; ended by kill
    SPAWN   m_sleep, PS_NULL, PS_NULL
    mov     r12, rax
    mov     edi, r12d
    lea     rsi, [rip+status]
    mov     edx, WNOHANG
    xor     r10d, r10d
    call    plat_wait4
    test    rax, rax
    CHECK   z, "wait4 WNOHANG while it runs: 0"
    mov     edi, r12d
    xor     esi, esi
    call    plat_kill
    test    rax, rax
    CHECK   z, "kill 0: it is there"
    mov     edi, r12d
    mov     esi, SIGTERM
    call    plat_kill
    test    rax, rax
    CHECK   z, "kill TERM"
    mov     edi, r12d
    lea     rsi, [rip+status]
    xor     edx, edx
    xor     r10d, r10d
    call    plat_wait4
    cmp     rax, r12
    sete    cl
    cmp     dword ptr [rip+status], SIGTERM
    sete    al
    and     al, cl
    cmp     al, 1
    CHECK   e, "it ended by the signal (status 15)"

    # the environment it is given
    lea     rdi, [rip+fds]
    xor     esi, esi
    call    plat_pipe2
    lea     rax, [rip+s_envvar]
    mov     [rip+myenv], rax
    lea     rax, [rip+m_env]
    mov     [rip+av+8], rax
    mov     dword ptr [rip+fmap], PS_NULL
    mov     eax, [rip+fds+4]
    mov     [rip+fmap+4], eax
    mov     dword ptr [rip+fmap+8], PS_KEEP
    lea     rdi, [rip+self]
    lea     rsi, [rip+av]
    lea     rdx, [rip+myenv]
    lea     rcx, [rip+fmap]
    xor     r8d, r8d
    call    plat_spawn
    mov     r12, rax
    mov     edi, [rip+fds+4]
    call    plat_close
    call    drain
    lea     rdi, [rip+out]
    lea     rsi, [rip+want_env]
    call    streq
    CHECK   z, "the environment it was given (BEE_T=/C:/ünï, as C:/ünï)"
    mov     edi, r12d
    xor     esi, esi
    xor     edx, edx
    xor     r10d, r10d
    call    plat_wait4

    # both ways (socketpair): what we send, it sends back
    mov     edi, AF_UNIX
    mov     esi, SOCK_STREAM
    xor     edx, edx
    lea     r10, [rip+sv]
    call    plat_socketpair
    test    rax, rax
    CHECK   z, "socketpair (AF_UNIX, a stream)"
    lea     rdi, [rip+fds]
    xor     esi, esi
    call    plat_pipe2
    mov     edi, [rip+fds]
    mov     esi, F_SETFL
    mov     edx, O_NONBLOCK
    call    plat_fcntl
    SPAWN   m_cat, [rip+sv+4], [rip+fds+4]
    mov     r12, rax
    mov     edi, [rip+sv+4]
    call    plat_close
    mov     edi, [rip+fds+4]
    call    plat_close
    xor     r13d, r13d                  # 40 x 100 bytes
1:  mov     edi, [rip+sv]
    lea     rsi, [rip+s_line]
    mov     edx, 100
    xor     r10d, r10d
    xor     r8d, r8d
    xor     r9d, r9d
    call    plat_sendto
    cmp     rax, 100
    jne     2f
    inc     r13d
    cmp     r13d, 40
    jb      1b
2:  cmp     r13d, 40
    CHECK   e, "sendto: 4000 bytes to its stdin"
    mov     edi, [rip+sv]
    call    plat_close
    call    drain
    cmp     dword ptr [rip+out_n], 4000
    CHECK   e, "and all 4000 came back on its stdout"
    mov     edi, r12d
    lea     rsi, [rip+status]
    xor     edx, edx
    xor     r10d, r10d
    call    plat_wait4
    cmp     dword ptr [rip+status], 0
    CHECK   e, "it ended at its stdin's end"

    # a path without .exe, and none at all
    lea     rdi, [rip+self]
    xor     ecx, ecx
1:  cmp     byte ptr [rdi+rcx], 0
    je      2f
    inc     ecx
    jmp     1b
2:  mov     byte ptr [rdi+rcx-4], 0     # (".exe" off)
    lea     rax, [rip+s_7]
    mov     [rip+av+16], rax
    SPAWN   m_exit, PS_NULL, PS_NULL
    mov     r12, rax
    test    eax, eax
    CHECK   g, "spawn by the path without .exe"
    mov     edi, r12d
    lea     rsi, [rip+status]
    xor     edx, edx
    xor     r10d, r10d
    call    plat_wait4
    cmp     dword ptr [rip+status], 7 << 8
    CHECK   e, "it ran (exit code 7)"
    lea     rdi, [rip+s_none]
    lea     rsi, [rip+av]
    mov     rdx, [rip+envp]
    lea     rcx, [rip+fmap]
    xor     r8d, r8d
    call    plat_spawn
    cmp     rax, -ENOENT
    CHECK   e, "spawn a program that is not there: -ENOENT"

    mov     edi, [rip+fails]
    call    plat_exit_group

# ---- the children ---------------------------------------------------------------
child_args:                             # [arg] per line
    lea     rbx, [r12+16]
1:  mov     rsi, [rbx]
    test    rsi, rsi
    jz      9f
    lea     rsi, [rip+s_lb]
    call    say
    mov     rsi, [rbx]
    call    say
    lea     rsi, [rip+s_rb]
    call    say
    add     rbx, 8
    jmp     1b
9:  xor     edi, edi
    call    plat_exit_group
child_exit:
    mov     rsi, [r12+16]
    xor     edi, edi
1:  movzx   eax, byte ptr [rsi]
    sub     eax, '0'
    jb      2f
    cmp     eax, 9
    ja      2f
    imul    edi, edi, 10
    add     edi, eax
    inc     rsi
    jmp     1b
2:  call    plat_exit_group
child_sleep:
    lea     rdi, [rip+ts_30s]
    xor     esi, esi
    call    plat_nanosleep
    xor     edi, edi
    call    plat_exit_group
child_env:                              # BEE_T's value
    mov     rbx, [rip+envp]
1:  mov     rdi, [rbx]
    test    rdi, rdi
    jz      9f
    lea     rsi, [rip+s_beet]
    xor     ecx, ecx
2:  mov     al, [rsi+rcx]
    test    al, al
    jz      3f
    cmp     al, [rdi+rcx]
    jne     4f
    inc     ecx
    jmp     2b
3:  lea     rsi, [rdi+rcx]
    call    say
    jmp     9f
4:  add     rbx, 8
    jmp     1b
9:  xor     edi, edi
    call    plat_exit_group
child_cat:
1:  xor     edi, edi
    lea     rsi, [rip+buf]
    mov     edx, 4096
    call    plat_read
    test    rax, rax
    jle     9f
    mov     edi, 1
    lea     rsi, [rip+buf]
    mov     rdx, rax
    call    plat_write
    jmp     1b
9:  xor     edi, edi
    call    plat_exit_group

# say(rsi = text) - to stdout
say:
    xor     edx, edx
1:  cmp     byte ptr [rsi+rdx], 0
    je      2f
    inc     edx
    jmp     1b
2:  mov     edi, 1
    jmp     plat_write

# ---- helpers --------------------------------------------------------------------
# readbuf(edi = fd) -> rax: plat_read into buf
readbuf:
    lea     rsi, [rip+buf]
    mov     edx, 4096
    jmp     plat_read

# poll1(edi = fd, esi = ms) -> rax: plat_poll for POLLIN on it
poll1:
    lea     rax, [rip+pfd]
    mov     [rax], edi
    mov     dword ptr [rax+4], POLLIN
    mov     edx, esi
    mov     rdi, rax
    mov     esi, 1
    jmp     plat_poll

# drain - what fds[0] (non-blocking) gives, into out (out_n bytes, 0-ended),
#   waiting with poll, to its end; then it is closed
drain:
    push    rbx
    mov     dword ptr [rip+out_n], 0
1:  mov     edi, [rip+fds]
    mov     esi, 10000
    call    poll1
    cmp     rax, 1
    jne     8f
2:  mov     edi, [rip+fds]
    lea     rsi, [rip+out]
    mov     eax, [rip+out_n]
    add     rsi, rax
    mov     edx, 65000
    sub     edx, eax
    call    plat_read
    cmp     rax, -EAGAIN
    je      1b
    test    rax, rax
    jle     8f
    add     [rip+out_n], eax
    jmp     2b
8:  mov     eax, [rip+out_n]
    lea     rcx, [rip+out]
    mov     byte ptr [rcx+rax], 0
    mov     edi, [rip+fds]
    call    plat_close
    pop     rbx
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
m_args:   .asciz "args"
m_exit:   .asciz "exit"
m_sleep:  .asciz "sleep"
m_env:    .asciz "env"
m_cat:    .asciz "cat"
s_hello:  .ascii "hello"
s_7:      .asciz "7"
s_lb:     .asciz "["
s_rb:     .asciz "]\n"
s_beet:   .asciz "BEE_T="
s_envvar: .asciz "BEE_T=/C:/ünï"
s_none:   .asciz "/C:/no/such/program.exe"
a1:       .asciz "two words"
a2:       .asciz "a \"quote\" in it"
a3:       .asciz "x\\y\\"                 # (C:\\... would come as /C:/..., win_start's)
a4:       .asciz ""
a5:       .asciz "ünï\\\\\"x"
a6:       .asciz "/C:/Users"                # (C:/Users to the child; its start makes it /C:/Users again)
a7:       .asciz "@/D:/x=/E:/y"
want_args:.ascii "[two words]\n[a \"quote\" in it]\n[x\\y\\]\n[]\n[ünï\\\\\"x]\n[/C:/Users]\n[@D:/x=E:/y]\n"
          .byte 0
want_env: .asciz "C:/ünï"
s_line:   .ascii "0123456789012345678901234567890123456789012345678901234567890123456789012345678901234567890123456\r\n\n"
.balign 8
ts_30s:   .quad 30, 0

.section .bss
.align 8
envp:      .skip 8
myenv:     .skip 16
fails:     .skip 4
status:    .skip 4
.align 8
av:        .skip 8*10
fmap:      .skip 16
fds:       .skip 8
sv:        .skip 8
pfd:       .skip 8
out_n:     .skip 4
self:      .skip 4096
buf:       .skip 4096
out:       .skip 65536
