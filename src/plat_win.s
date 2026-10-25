# =============================================================================
#  BeeModel - the platform layer, Windows version (W2: the start, the
#  console, the exit; everything else answers -ENOSYS until W3-W6 port it).
#
#  The same plat_* routines as src/plat_linux.s, with the same contract: the
#  Linux syscall's arguments in its registers, Linux flags and structures,
#  rax = the result or -errno, every register but rax, rcx and r11 kept
#  (xmm0-xmm15 too). Inside, a routine calls kernel32 in the Windows
#  convention: rcx, rdx, r8, r9, then the stack above 32 bytes of shadow
#  space, rsp 16-byte aligned, rax/rcx/rdx/r8-r11/xmm0-xmm5 lost.
#
#  Linked by scripts/build.sh into build/beemodel.exe from the same objects
#  as the Linux binary, with ld's PE emulation (i386pep) at a fixed image
#  base of 0x400000 below 2 GiB, as the code's 32-bit absolute addresses
#  need. The imports at the end are written out by hand, so no import
#  library or C runtime is needed.
# =============================================================================
.intel_syntax noprefix
.include "const.inc"

.globl win_start
.globl plat_self_path
.globl plat_write
.globl plat_exit_group
.globl plat_getpid
.globl plat_gettid

.equ IMAGE_BASE,        0x400000        # (scripts/build.sh links there)
.equ CP_UTF8,           65001
.equ MEM_COMMIT_RESERVE, 0x3000
.equ PAGE_READWRITE,    4
.equ STD_INPUT_HANDLE,  -10             # -11 out, -12 err
.equ ENOSYS_,           38
.equ EBADF_,            9
.equ EIO_,              5
.equ SELF_WCHARS,       32768

# WENTER locals / WLEAVE: around the calls into Windows, keep what the
# contract keeps and Windows does not (rdx, rsi, rdi, r8-r10, xmm0-xmm5),
# align the stack and leave the shadow space; [rsp+32...] holds `locals`
# bytes (a multiple of 16) for stack arguments and results.
.macro WENTER locals=0
    push    rbp
    mov     rbp, rsp
    push    rdx
    push    rsi
    push    rdi
    push    r8
    push    r9
    push    r10
    sub     rsp, 96
    movdqu  [rbp-144], xmm0
    movdqu  [rbp-128], xmm1
    movdqu  [rbp-112], xmm2
    movdqu  [rbp-96], xmm3
    movdqu  [rbp-80], xmm4
    movdqu  [rbp-64], xmm5
    and     rsp, -16
    sub     rsp, 32+\locals
.endm
.macro WLEAVE
    movdqu  xmm0, [rbp-144]
    movdqu  xmm1, [rbp-128]
    movdqu  xmm2, [rbp-112]
    movdqu  xmm3, [rbp-96]
    movdqu  xmm4, [rbp-80]
    movdqu  xmm5, [rbp-64]
    lea     rsp, [rbp-48]
    pop     r10
    pop     r9
    pop     r8
    pop     rdi
    pop     rsi
    pop     rdx
    pop     rbp
.endm

# Not ported yet: -ENOSYS
.macro NOSYS name
.globl \name
\name:
    mov     rax, -ENOSYS_
    ret
.endm

.text

# ---- the start ----------------------------------------------------------------
# Windows enters here (the PE entry point) with nothing on the stack: argv
# and envp are built from the UTF-16 command line and environment as UTF-8,
# as the Linux kernel would hand them over, and bee_main takes it from there.
win_start:
    and     rsp, -16
    sub     rsp, 32
    mov     ecx, CP_UTF8                # (our output is UTF-8)
    call    [rip+__imp_SetConsoleOutputCP]
    call    [rip+__imp_GetCommandLineW]
    mov     rdi, rax
    mov     esi, -1
    call    w2u_dup                     # rax = the line in UTF-8, edx its size
    mov     r13, rax
    mov     r14d, edx
    mov     edi, edx                    # the words: never longer than the line
    call    win_alloc
    mov     r15, rax
    mov     edi, r14d                   # argv: at most a pointer per 2 bytes
    shr     edi, 1
    add     edi, 2
    shl     edi, 3
    call    win_alloc
    mov     r12, rax
    mov     rsi, r13
    mov     rdi, r15
    call    split_args                  # ebx = argc
    call    [rip+__imp_GetEnvironmentStringsW]
    xor     esi, esi                    # its length: up to the empty entry
1:  cmp     word ptr [rax+rsi*2], 0
    jne     2f
    test    esi, esi
    jz      3f
    cmp     word ptr [rax+rsi*2-2], 0
    je      3f
2:  inc     esi
    jmp     1b
3:  inc     esi
    mov     rdi, rax
    call    w2u_dup
    mov     r13, rax                    # NAME=value\0 ... \0
    mov     edi, edx                    # envp: at most a pointer per 2 bytes
    shr     edi, 1
    add     edi, 2
    shl     edi, 3
    call    win_alloc
    mov     [rip+envp], rax
    mov     rdi, rax
4:  cmp     byte ptr [r13], 0
    je      6f
    mov     [rdi], r13
    add     rdi, 8
5:  inc     r13
    cmp     byte ptr [r13-1], 0
    jne     5b
    jmp     4b
6:  mov     qword ptr [rdi], 0
    mov     edi, ebx
    mov     rsi, r12
    call    bee_main                    # (does not return)

# split_args(rsi=the command line, rdi=room for the words, r12=room for
# argv) -> ebx = argc. The rules of the Microsoft C runtime: blanks part
# words, "..." quotes, 2n backslashes and a quote are n backslashes and a
# quote that counts, 2n+1 are n and a plain quote, "" inside quotes is a
# quote; the program's name (argv[0]) knows only quotes. Ends argv with 0.
split_args:
    xor     ebx, ebx
    mov     [r12], rdi                  # argv[0]
    inc     ebx
    xor     ecx, ecx                    # ecx = inside quotes
1:  mov     al, [rsi]
    test    al, al
    jz      3f
    inc     rsi
    cmp     al, '"'
    jne     2f
    xor     ecx, 1
    jmp     1b
2:  test    ecx, ecx
    jnz     21f
    cmp     al, ' '
    je      3f
    cmp     al, 9
    je      3f
21: mov     [rdi], al
    inc     rdi
    jmp     1b
3:  mov     byte ptr [rdi], 0
    inc     rdi
.Lsa_word:
    mov     al, [rsi]                   # the blanks between words
    cmp     al, ' '
    je      4f
    cmp     al, 9
    jne     5f
4:  inc     rsi
    jmp     .Lsa_word
5:  test    al, al
    jz      .Lsa_done
    mov     [r12+rbx*8], rdi
    inc     ebx
    xor     ecx, ecx
.Lsa_char:
    mov     al, [rsi]
    test    al, al
    jz      .Lsa_end
    test    ecx, ecx
    jnz     6f
    cmp     al, ' '
    je      .Lsa_end
    cmp     al, 9
    je      .Lsa_end
6:  cmp     al, '\\'
    je      .Lsa_bs
    cmp     al, '"'
    je      .Lsa_quote
    mov     [rdi], al
    inc     rdi
    inc     rsi
    jmp     .Lsa_char
.Lsa_quote:
    inc     rsi
    test    ecx, ecx
    jz      7f
    cmp     byte ptr [rsi], '"'         # "" inside quotes: a quote
    jne     7f
    mov     byte ptr [rdi], '"'
    inc     rdi
    inc     rsi
    jmp     .Lsa_char
7:  xor     ecx, 1
    jmp     .Lsa_char
.Lsa_bs:
    xor     edx, edx                    # edx = how many backslashes
8:  cmp     byte ptr [rsi+rdx], '\\'
    jne     9f
    inc     edx
    jmp     8b
9:  cmp     byte ptr [rsi+rdx], '"'
    je      10f
    add     rsi, rdx                    # no quote after them: as they are
11: mov     byte ptr [rdi], '\\'
    inc     rdi
    dec     edx
    jnz     11b
    jmp     .Lsa_char
10: add     rsi, rdx                    # (rsi at the quote)
    mov     eax, edx
    shr     edx, 1
    jz      13f
12: mov     byte ptr [rdi], '\\'
    inc     rdi
    dec     edx
    jnz     12b
13: test    eax, 1
    jz      .Lsa_char                   # even: the quote counts
    mov     byte ptr [rdi], '"'         # odd: a plain quote
    inc     rdi
    inc     rsi
    jmp     .Lsa_char
.Lsa_end:
    mov     byte ptr [rdi], 0
    inc     rdi
    jmp     .Lsa_word
.Lsa_done:
    mov     qword ptr [r12+rbx*8], 0
    ret

# win_alloc(edi=bytes) -> rax = fresh zeroed memory (the start's own: it
#   ends the program when there is none)
win_alloc:
    WENTER
    xor     ecx, ecx
    mov     edx, edi
    mov     r8d, MEM_COMMIT_RESERVE
    mov     r9d, PAGE_READWRITE
    call    [rip+__imp_VirtualAlloc]
    WLEAVE
    test    rax, rax
    jz      win_fail
    ret

# w2u_dup(rdi=UTF-16 text, esi=its length in units, -1: to its 0) -> rax =
#   it in UTF-8 in fresh memory, edx = the bytes (with the 0 when counted)
w2u_dup:
    push    rbx
    push    r12
    push    r13
    mov     r12, rdi
    mov     r13d, esi
    xor     r8d, r8d
    xor     r9d, r9d
    call    w2u                         # how big
    test    eax, eax
    jz      win_fail
    mov     ebx, eax
    lea     edi, [rax+1]
    call    win_alloc
    mov     rdi, r12
    mov     esi, r13d
    mov     r8, rax
    mov     r9d, ebx
    mov     r12, rax
    call    w2u
    mov     rax, r12
    mov     edx, ebx
    pop     r13
    pop     r12
    pop     rbx
    ret

# w2u(rdi=UTF-16 text, esi=units or -1, r8=out, r9d=its room, 0: only
#   count) -> eax = the bytes written (or needed); 0 on an error
w2u:
    WENTER 32
    mov     [rsp+32], r8                # lpMultiByteStr
    mov     [rsp+40], r9                # cbMultiByte
    xor     eax, eax
    mov     [rsp+48], rax               # lpDefaultChar
    mov     [rsp+56], rax               # lpUsedDefaultChar
    mov     ecx, CP_UTF8
    xor     edx, edx
    mov     r8, rdi
    mov     r9d, esi
    call    [rip+__imp_WideCharToMultiByte]
    WLEAVE
    ret

# Out of memory before anything runs: end with 1
win_fail:
    and     rsp, -16
    sub     rsp, 32
    mov     ecx, 1
    call    [rip+__imp_ExitProcess]

# plat_self_path(rdi=buffer, esi=its size) -> rax = the length of this
#   program's path, written there 0-ended (0: not known). An ordinary call.
plat_self_path:
    push    rbx
    push    r12
    push    r13
    mov     rbx, rdi
    mov     r12d, esi
    mov     byte ptr [rbx], 0
    xor     r13d, r13d
    WENTER
    xor     ecx, ecx
    lea     rdx, [rip+self_w]
    mov     r8d, SELF_WCHARS
    call    [rip+__imp_GetModuleFileNameW]
    WLEAVE
    test    eax, eax
    jz      1f
    cmp     eax, SELF_WCHARS
    jae     1f
    lea     rdi, [rip+self_w]
    mov     esi, eax
    mov     r8, rbx
    lea     r9d, [r12-1]
    call    w2u
    mov     r13d, eax
    mov     byte ptr [rbx+r13], 0
1:  mov     eax, r13d
    pop     r13
    pop     r12
    pop     rbx
    ret

# ---- files ------------------------------------------------------------------
# plat_write: the console (fds 0-2) only, so far
plat_write:
    cmp     edi, 2
    ja      2f
    WENTER 16
    mov     ecx, STD_INPUT_HANDLE       # -10 - fd
    sub     ecx, edi
    call    [rip+__imp_GetStdHandle]
    mov     rcx, rax
    mov     rdx, rsi
    mov     r8, [rbp-8]                 # (the saved rdx: how many)
    lea     r9, [rsp+40]
    mov     dword ptr [r9], 0
    mov     qword ptr [rsp+32], 0
    call    [rip+__imp_WriteFile]
    test    eax, eax                    # (the flags last through WLEAVE)
    mov     eax, [rsp+40]
    WLEAVE
    jz      1f
    ret
1:  mov     rax, -EIO_
    ret
2:  mov     rax, -EBADF_
    ret

# ---- processes ----------------------------------------------------------------
plat_exit_group:
    and     rsp, -16
    sub     rsp, 32
    mov     ecx, edi
    call    [rip+__imp_ExitProcess]

plat_getpid:
    WENTER
    call    [rip+__imp_GetCurrentProcessId]
    WLEAVE
    ret

plat_gettid:
    WENTER
    call    [rip+__imp_GetCurrentThreadId]
    WLEAVE
    ret

# ---- the rest: W3 (memory, files, threads, time), W5 (poll), W6 (processes,
#      sockets, shared memory)
NOSYS plat_mmap
NOSYS plat_munmap
NOSYS plat_mprotect
NOSYS plat_mremap
NOSYS plat_mincore
NOSYS plat_madvise
NOSYS plat_read
NOSYS plat_pwrite64
NOSYS plat_open
NOSYS plat_openat
NOSYS plat_close
NOSYS plat_stat
NOSYS plat_fstat
NOSYS plat_newfstatat
NOSYS plat_access
NOSYS plat_fcntl
NOSYS plat_ftruncate
NOSYS plat_getdents64
NOSYS plat_chdir
NOSYS plat_rename
NOSYS plat_mkdir
NOSYS plat_rmdir
NOSYS plat_unlink
NOSYS plat_symlink
NOSYS plat_readlink
NOSYS plat_chmod
NOSYS plat_statfs
NOSYS plat_socket
NOSYS plat_socketpair
NOSYS plat_connect
NOSYS plat_bind
NOSYS plat_listen
NOSYS plat_accept4
NOSYS plat_setsockopt
NOSYS plat_sendto
NOSYS plat_sendmsg
NOSYS plat_recvmsg
NOSYS plat_poll
NOSYS plat_memfd_create
NOSYS plat_getrandom
NOSYS plat_thread_start
NOSYS plat_spawn
NOSYS plat_pipe2
NOSYS plat_wait4
NOSYS plat_kill
NOSYS plat_futex
NOSYS plat_sched_getaffinity
NOSYS plat_clock_gettime
NOSYS plat_nanosleep
NOSYS plat_time
NOSYS plat_timerfd_create
NOSYS plat_timerfd_settime

.section .bss
.align 8
self_w:         .skip SELF_WCHARS*2     # GetModuleFileNameW's answer

# ---- the imports ----------------------------------------------------------------
# ld puts the .idata$N sections in order and points the PE header at them:
# $2 one entry per DLL (and an empty one to end), $4 the lookup table, $5
# the address table the loader fills (__imp_X: call [rip+__imp_X]), $6 the
# names, $7 the DLL names. Subsection n of $4/$5 is DLL n's run, ended by 0;
# src/plat_win.ld ends the $2 list.
.macro DLL n, name
    .section .idata$2,"a"
    .long   dll_ilt_\n - IMAGE_BASE, 0, 0, dll_name_\n - IMAGE_BASE, dll_iat_\n - IMAGE_BASE
    .section .idata$4,"a"
    .subsection \n
dll_ilt_\n:
    .section .idata$5,"aw"
    .subsection \n
dll_iat_\n:
    .section .idata$7,"a"
dll_name_\n: .asciz "\name"
.endm
.macro IMPORT n, func
    .section .idata$6,"a"
    .balign 2
imp_name_\func: .short 0
    .asciz "\func"
    .section .idata$4,"a"
    .subsection \n
    .quad   imp_name_\func - IMAGE_BASE
    .section .idata$5,"aw"
    .subsection \n
__imp_\func: .quad imp_name_\func - IMAGE_BASE
.endm
.macro DLL_END n
    .section .idata$4,"a"
    .subsection \n
    .quad   0
    .section .idata$5,"aw"
    .subsection \n
    .quad   0
.endm

DLL 1, KERNEL32.dll
IMPORT 1, ExitProcess
IMPORT 1, GetCommandLineW
IMPORT 1, GetCurrentProcessId
IMPORT 1, GetCurrentThreadId
IMPORT 1, GetEnvironmentStringsW
IMPORT 1, GetModuleFileNameW
IMPORT 1, GetStdHandle
IMPORT 1, SetConsoleOutputCP
IMPORT 1, VirtualAlloc
IMPORT 1, WideCharToMultiByte
IMPORT 1, WriteFile
DLL_END 1
