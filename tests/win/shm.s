# =============================================================================
#  BeeModel - the Windows platform layer's shared memory and packets, the
#  GPU helper's way (Vibecoding/BeeModel-Win11-Port-Plan.html, W6c): a
#  SOCK_SEQPACKET socketpair, a memfd mapped MAP_SHARED, passed to a child
#  on its fd 3 with SCM_RIGHTS. Linked with src/plat_win.s into
#  build/test-shm.exe by scripts/build.sh; run by ci/check-exe.sh under Wine
#  and in the Windows 11 VM. The child is this program again (mode "peer").
#  Prints a line per check; the exit code is the number that failed.
# =============================================================================
.intel_syntax noprefix

.globl bee_main
.globl envp

.equ POLLIN,        1
.equ PS_KEEP,       -1
.equ AF_UNIX,       1
.equ SEQPACKET,     0x80005             # SOCK_SEQPACKET | SOCK_CLOEXEC
.equ PROT_RW,       3
.equ MAP_SHARED,    1
.equ SIZE,          1 << 20
.equ MSG,           64

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
    cmp     edi, 2                      # the child?
    jl      1f
    mov     rdi, [rsi+8]
    lea     rsi, [rip+m_peer]
    call    streq
    jz      child
1:  lea     rdi, [rip+self]
    mov     esi, 4096
    call    plat_self_path
    lea     rax, [rip+self]
    mov     [rip+av], rax

    mov     edi, AF_UNIX
    mov     esi, SEQPACKET
    xor     edx, edx
    lea     r10, [rip+sv]
    call    plat_socketpair
    test    rax, rax
    CHECK   z, "socketpair(AF_UNIX, SOCK_SEQPACKET)"
    lea     rdi, [rip+s_name]
    mov     esi, 1                      # MFD_CLOEXEC
    call    plat_memfd_create
    mov     ebx, eax
    cmp     eax, 3
    CHECK   ge, "memfd_create: an fd"
    mov     edi, ebx
    mov     esi, SIZE
    call    plat_ftruncate
    test    rax, rax
    CHECK   z, "ftruncate it to 1 MiB"
    xor     edi, edi
    mov     esi, SIZE
    mov     edx, PROT_RW
    mov     r10d, MAP_SHARED
    mov     r8d, ebx
    xor     r9d, r9d
    call    plat_mmap
    mov     r12, rax
    cmp     rax, -4096
    CHECK   b, "mmap it MAP_SHARED"
    mov     dword ptr [r12], 0x11223344     # ours, at both ends of it
    mov     dword ptr [r12+SIZE-4], 0x55667788

    # the child, with the other end on its fd 3
    lea     rax, [rip+m_peer]
    mov     [rip+av+8], rax
    mov     dword ptr [rip+fmap], PS_KEEP
    mov     dword ptr [rip+fmap+4], PS_KEEP
    mov     dword ptr [rip+fmap+8], PS_KEEP
    mov     eax, [rip+sv+4]
    mov     [rip+fmap+12], eax
    lea     rdi, [rip+self]
    lea     rsi, [rip+av]
    mov     rdx, [rip+envp]
    lea     rcx, [rip+fmap]
    xor     r8d, r8d
    call    plat_spawn
    mov     r14d, eax
    test    eax, eax
    CHECK   g, "the child started, its fd 3 the other end"
    mov     edi, [rip+sv+4]
    call    plat_close

    # two messages at once: the memfd with the first
    mov     dword ptr [rip+msg], 1
    mov     edi, ebx
    call    sendm
    cmp     rax, MSG
    CHECK   e, "sendmsg 64 bytes with SCM_RIGHTS (the memfd)"
    mov     dword ptr [rip+msg], 2
    mov     edi, -1
    call    sendm
    cmp     rax, MSG
    CHECK   e, "and 64 more without"
    mov     edi, ebx
    call    plat_close

    # its answer: 64 bytes, and its mark in the shared memory
    lea     rdi, [rip+pfd]
    mov     eax, [rip+sv]
    mov     [rdi], eax
    mov     dword ptr [rdi+4], POLLIN
    mov     esi, 1
    mov     edx, 10000
    call    plat_poll
    cmp     rax, 1
    CHECK   e, "poll: its answer came"
    mov     edi, [rip+sv]
    lea     rsi, [rip+buf]
    mov     edx, 4096
    call    plat_read
    cmp     rax, MSG
    CHECK   e, "read: one message, 64 bytes"
    mov     eax, [rip+buf]
    mov     [rip+status], eax
    cmp     dword ptr [rip+buf], 0
    CHECK   e, "the child: two messages, apart; the fd with the first; our bytes in it"
    mov     eax, [rip+buf]              # (what went wrong there: its bits)
    test    eax, eax
    jz      1f
    lea     rdi, [rip+s_bits+24]
    lea     r8, [rip+hexd]
    mov     ecx, 2
2:  mov     edx, eax
    and     edx, 15
    movzx   edx, byte ptr [r8+rdx]
    mov     [rdi+rcx-1], dl
    shr     eax, 4
    dec     ecx
    jnz     2b
    mov     edi, 1
    lea     rsi, [rip+s_bits]
    mov     edx, 27
    call    plat_write
1:
    cmp     dword ptr [r12+1000], 0x99aabbcc
    CHECK   e, "its bytes in our mapping: the memory is shared"
    mov     edi, r14d
    lea     rsi, [rip+status]
    xor     edx, edx
    xor     r10d, r10d
    call    plat_wait4
    mov     edi, [rip+sv]
    call    plat_close
    mov     rdi, r12
    mov     esi, SIZE
    call    plat_munmap
    test    rax, rax
    CHECK   z, "munmap the view"

    mov     edi, [rip+fails]
    call    plat_exit_group

# sendm(edi = fd to pass or -1) -> rax: plat_sendmsg of msg (64 bytes) on sv[0]
sendm:
    lea     rax, [rip+msg]
    mov     [rip+iov], rax
    mov     qword ptr [rip+iov+8], MSG
    lea     rsi, [rip+mh]
    lea     rax, [rip+iov]
    mov     [rsi+16], rax
    mov     qword ptr [rsi+24], 1
    mov     qword ptr [rsi+32], 0
    mov     qword ptr [rsi+40], 0
    test    edi, edi
    js      1f
    lea     rax, [rip+ctl]
    mov     qword ptr [rax], 20
    mov     dword ptr [rax+8], 1
    mov     dword ptr [rax+12], 1
    mov     [rax+16], edi
    mov     [rsi+32], rax
    mov     qword ptr [rsi+40], 24
1:  mov     edi, [rip+sv]
    xor     edx, edx
    jmp     plat_sendmsg

# recvm -> rax: plat_recvmsg on fd 3 into msg, the control message into ctl
#   (room 64; [mh+40] its length after)
recvm:
    lea     rax, [rip+msg]
    mov     [rip+iov], rax
    mov     qword ptr [rip+iov+8], MSG
    lea     rsi, [rip+mh]
    lea     rax, [rip+iov]
    mov     [rsi+16], rax
    mov     qword ptr [rsi+24], 1
    lea     rax, [rip+ctl]
    mov     [rsi+32], rax
    mov     qword ptr [rsi+40], 64
    mov     edi, 3
    xor     edx, edx
    jmp     plat_recvmsg

# the child: fd 3 -> two messages, the memfd with the first; its bytes
#   checked, ours written; the answer: 64 bytes, the first word what went
#   wrong (bits; 0: nothing)
child:
    xor     ebx, ebx
    call    recvm
    cmp     rax, MSG
    je      1f
    or      ebx, 1
1:  cmp     dword ptr [rip+msg], 1
    je      2f
    or      ebx, 2
2:  mov     r13d, -1
    cmp     qword ptr [rip+mh+40], 20   # SCM_RIGHTS, one fd
    jb      3f
    cmp     dword ptr [rip+ctl+12], 1
    jne     3f
    mov     r13d, [rip+ctl+16]
3:  test    r13d, r13d
    jns     4f
    or      ebx, 4
    jmp     6f
4:  xor     edi, edi
    mov     esi, SIZE
    mov     edx, PROT_RW
    mov     r10d, MAP_SHARED
    mov     r8d, r13d
    xor     r9d, r9d
    call    plat_mmap
    cmp     rax, -4096
    jb      5f
    or      ebx, 8
    jmp     6f
5:  mov     r12, rax
    mov     edi, r13d
    call    plat_close
    cmp     dword ptr [r12], 0x11223344
    jne     51f
    cmp     dword ptr [r12+SIZE-4], 0x55667788
    je      52f
51: or      ebx, 16
52: mov     dword ptr [r12+1000], 0x99aabbcc
6:  call    recvm                       # the second: no fd
    cmp     rax, MSG
    je      7f
    or      ebx, 32
7:  cmp     dword ptr [rip+msg], 2
    jne     71f
    cmp     qword ptr [rip+mh+40], 0
    je      72f
71: or      ebx, 64
72: lea     rdi, [rip+msg]              # the answer
    xor     eax, eax
    mov     ecx, MSG/8
    rep     stosq
    mov     [rip+msg], ebx
    mov     edi, 3
    lea     rsi, [rip+msg]
    mov     edx, MSG
    call    plat_write
    mov     edi, ebx
    call    plat_exit_group

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
m_peer:   .asciz "peer"
s_name:   .asciz "test-shm"
hexd:     .ascii "0123456789abcdef"

.section .data
s_bits:   .ascii "       the child said 0x..\n"

.section .bss
.align 8
envp:      .skip 8
fails:     .skip 4
status:    .skip 4
.align 8
av:        .skip 8*4
fmap:      .skip 16
sv:        .skip 8
pfd:       .skip 8
mh:        .skip 56
iov:       .skip 16
ctl:       .skip 64
msg:       .skip MSG
self:      .skip 4096
buf:       .skip 4096
