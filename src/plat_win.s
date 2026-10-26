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
.include "plat_win.inc"

.globl win_start
.globl plat_self_path
.globl plat_mmap
.globl plat_munmap
.globl plat_mprotect
.globl plat_mremap
.globl plat_mincore
.globl plat_madvise
.globl plat_read
.globl plat_write
.globl plat_pwrite64
.globl plat_open
.globl plat_openat
.globl plat_close
.globl plat_stat
.globl plat_fstat
.globl plat_newfstatat
.globl plat_access
.globl plat_ftruncate
.globl plat_getdents64
.globl plat_chdir
.globl plat_rename
.globl plat_mkdir
.globl plat_rmdir
.globl plat_unlink
.globl plat_readlink
.globl plat_chmod
.globl plat_statfs
.globl plat_exit_group
.globl plat_getpid
.globl plat_thread_start
.globl plat_futex
.globl plat_sched_getaffinity
.globl plat_clock_gettime
.globl plat_nanosleep
.globl plat_time
.globl plat_gettid
.globl plat_poll
.globl plat_win_msgfd
.globl plat_win_frame_due
.globl plat_timerfd_create
.globl plat_timerfd_settime
.globl plat_pipe2
.globl plat_socketpair
.globl plat_fcntl
.globl plat_sendto
.globl plat_spawn
.globl plat_wait4
.globl plat_kill
.globl plat_path_in
.globl plat_path_sep
.globl plat_exe_ext

.equ CP_UTF8,           65001
.equ MEM_COMMIT_RESERVE, 0x3000
.equ MEM_COMMIT,        0x1000
.equ MEM_RESERVE,       0x2000
.equ MEM_DECOMMIT,      0x4000
.equ MEM_RELEASE,       0x8000
.equ MEM_FREE,          0x10000
.equ PAGE_READWRITE,    4
.equ MBI_BASE,          0               # MEMORY_BASIC_INFORMATION
.equ MBI_ALLOC,         8
.equ MBI_SIZE,          24
.equ MBI_STATE,         32
.equ MBI_PROTECT,       36
.equ EXC_ACCESS_VIOLATION, 0xC0000005
.equ MAP_SHARED_,       0x01            # Linux mmap flags
.equ MAP_FIXED_,        0x10
.equ MAP_ANONYMOUS_,    0x20
.equ MAP_NORESERVE_,    0x4000
.equ MAP_STACK_,        0x20000
.equ MADV_DONTNEED_,    4
.equ NR_MAX,            1024
.equ MBI_TYPE,          40
.equ MEM_MAPPED,        0x40000
.equ PAGE_WRITECOPY,    0x08
.equ PAGE_EXECUTE_WRITECOPY, 0x80
.equ FILE_MAP_COPY,     1
.equ MAP_PRIVATE_,      0x02
.equ O_ACCMODE_,        3               # Linux open flags
.equ O_CREAT_,          0x40
.equ O_EXCL_,           0x80
.equ O_TRUNC_,          0x200
.equ O_DIRECTORY_,      0x10000
.equ GENERIC_READ,      0x80000000
.equ GENERIC_WRITE,     0x40000000
.equ FILE_SHARE_ALL,    7               # read, write, delete
.equ CREATE_NEW,        1
.equ CREATE_ALWAYS,     2
.equ OPEN_EXISTING,     3
.equ OPEN_ALWAYS,       4
.equ TRUNCATE_EXISTING, 5
.equ FILE_ATTRIBUTE_READONLY, 0x01
.equ FILE_ATTRIBUTE_DIRECTORY, 0x10
.equ FILE_ATTRIBUTE_NORMAL, 0x80
.equ FILE_ATTRIBUTE_REPARSE_POINT, 0x400
.equ IO_REPARSE_TAG_SYMLINK, 0xA000000C
.equ FILE_BEGIN,        0
.equ FILE_CURRENT,      1
.equ MOVEFILE_REPLACE_EXISTING, 1
.equ ERROR_FILE_NOT_FOUND, 2
.equ ERROR_HANDLE_EOF,  38
.equ ERROR_BROKEN_PIPE, 109
.equ DT_DIR_,           4
.equ DT_REG_,           8
.equ DT_LNK_,           10
.equ EACCES_,           13
.equ ENOTDIR_,          20
.equ EISDIR_,           21
.equ EMFILE_,           24
.equ ENAMETOOLONG_,     36
.equ TB_ENTRY,          0               # a new thread's block (plat_thread_start)
.equ TB_ARG,            8
.equ TB_TOP,            16
.equ TB_BOTTOM,         24
.equ TB_TID,            32
.equ TB_SIZE,           48
.equ CREATE_SUSPENDED,  4
.equ ALL_PROCESSOR_GROUPS, 0xffff
.equ FUTEX_WAKE_,       1
.equ FUTEX_PRIVATE_,    128
.equ ERROR_TIMEOUT,     1460
.equ WAIT_TIMEOUT,      258
.equ EAGAIN_,           11
.equ ETIMEDOUT_,        110
.equ FD_MAX,            1024            # fd_tab: {handle, kind, aux}, 32 bytes
.equ FD_HANDLE,         0
.equ FD_KIND,           8
.equ FD_AUX,            16
.equ K_FILE,            1
.equ K_DIR,             2
.equ K_MSG,             3               # the window's message queue (plat_poll)
.equ K_TIMER,           4               # a timerfd: aux its due time (ns, 0: not armed)
.equ FD_TIVL,           24              #  and here its interval (ns, 0: once)
.equ TFD_TIMER_ABSTIME_, 1
.equ CREATE_WAITABLE_TIMER_HIGH_RESOLUTION, 2
.equ TIMER_ALL_ACCESS,  0x1F0003
.equ K_PIPE,            5               # our end of a pipe: aux its PB_* block
.equ OV_EVENT,          24              # OVERLAPPED.hEvent
.equ PB_OV,             0               # a pipe's block: the read's OVERLAPPED,
.equ PB_WOV,            32              #  a write's, a read on its way, the
.equ PB_PEND,           64              #  end come, O_NONBLOCK, the bytes read
.equ PB_EOF,            68              #  and not yet taken (from PB_HEAD in
.equ PB_NONBLOCK,       72              #  PB_BUF)
.equ PB_HEAD,           76
.equ PB_LEN,            80
.equ PB_BUF,            128
.equ PB_CAP,            65536
.equ PB_SIZE,           PB_BUF+PB_CAP
.equ PIPE_BUF_BYTES,    65536
.equ PIPE_ACCESS_INBOUND, 1
.equ PIPE_ACCESS_DUPLEX, 3
.equ FILE_FLAG_OVERLAPPED, 0x40000000
.equ FILE_FLAG_FIRST_PIPE_INSTANCE, 0x80000
.equ PIPE_REJECT_REMOTE_CLIENTS, 8
.equ ERROR_IO_INCOMPLETE, 996
.equ ERROR_IO_PENDING,  997
.equ F_GETFL_,          3
.equ F_SETFL_,          4
.equ O_NONBLOCK_,       0x800
.equ POLL_PIPES,        60              # pipes plat_poll waits on at once
.equ STARTF_USESTDHANDLES, 0x100
.equ CREATE_UNICODE_ENVIRONMENT, 0x400
.equ EXTENDED_STARTUPINFO_PRESENT, 0x80000
.equ CREATE_NO_WINDOW,  0x8000000
.equ PROC_THREAD_ATTRIBUTE_HANDLE_LIST, 0x20002
.equ DUPLICATE_SAME_ACCESS, 2
.equ ENOENT_,           2
.equ ESRCH_,            3
.equ E2BIG_,            7
.equ ECHILD_,           10
.equ PROC_MAX,          64              # proc_tab: {pid, signal sent, handle}
.equ PT_PID,            0
.equ PT_SIG,            4
.equ PT_HANDLE,         8
.equ SP_PATH,           0               # plat_spawn's scratch block: the
.equ SP_CWD,            0x4000          #  program, the working directory, the
.equ SP_CMD,            0x8000          #  command line and environment in
.equ SP_CMD_UNITS,      32768           #  UTF-16, and either in UTF-8 first
.equ SP_ENVW,           0x18000
.equ SP_ENV_UNITS,      0x20000
.equ SP_U8,             0x58000
.equ SP_U8_CAP,         0x28000
.equ SP_ARG,            0x80000         # (an argument, in Windows' form)
.equ SP_ARG_CAP,        0x10000
.equ SP_SIZE,           0x90000
.equ SI_FLAGS,          60              # STARTUPINFOEXW
.equ SI_STDIN,          80
.equ SI_STDOUT,         88
.equ SI_STDERR,         96
.equ SI_ALIST,          104
.equ SI_SIZE,           112
.equ ALIST_ROOM,        256
.equ SPN_PATH8,         80              # plat_spawn's frame (below: the
.equ SPN_CWD8,          88              #  calls' arguments)
.equ SPN_DUP,           96
.equ SPN_ALIST,         120
.equ SPN_ENV,           128
.equ SPN_CWDW,          136
.equ SPN_RES,           144
.equ SPN_ASIZE,         152
.equ SPN_PI,            160
.equ SPN_HLIST,         192
.equ SPN_SI,            224
.equ SPN_ABUF,          336
.equ SPN_FRAME,         608
.equ POLLOUT_,          4
.equ POLLNVAL_,         0x20
.equ DS_HANDLE,         0               # a listing (K_DIR): FindFirstFileW's
.equ DS_PEND,           8               #  handle, an entry found but not yet
.equ DS_DONE,           12              #  given, the end reached, the last
.equ DS_INO,            16              #  d_ino, WIN32_FIND_DATAW, the
.equ DS_FIND,           32              #  pattern (path\*)
.equ DS_PAT,            640
.equ DS_DRV,            24              # "/" listed: the drives still to give (bit 31: it is that)
.equ DS_SIZE,           16384
.equ WPATH_UNITS,       4104            # a path in UTF-16, with its 0
.equ L_SCR,             64              # a path routine's WENTER L_SIZE frame
.equ L_W1,              192
.equ L_W2,              192+WPATH_UNITS*2
.equ L_SIZE,            192+WPATH_UNITS*4-32
.equ ENOMEM_,           12
.equ EINVAL_,           22
.equ EFAULT_,           14
.equ STD_INPUT_HANDLE,  -10             # -11 out, -12 err
.equ ENOSYS_,           38
.equ EBADF_,            9
.equ EIO_,              5
.equ SELF_WCHARS,       32768

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
    mov     ecx, 1                      # first in line: memory first touched
    lea     rdx, [rip+win_veh]
    call    [rip+__imp_AddVectoredExceptionHandler]
    lea     rcx, [rip+qpc_freq]         # (CLOCK_MONOTONIC's unit)
    call    [rip+__imp_QueryPerformanceFrequency]
    xor     ecx, ecx                    # plat_poll's timer: to the ms, not
    xor     edx, edx                    #  Windows' 15.6 ms tick (Windows 10
    mov     r8d, CREATE_WAITABLE_TIMER_HIGH_RESOLUTION  # 1803+; else a plain one)
    mov     r9d, TIMER_ALL_ACCESS
    call    [rip+__imp_CreateWaitableTimerExW]
    test    rax, rax
    jnz     2f
    xor     ecx, ecx
    xor     edx, edx
    xor     r8d, r8d
    mov     r9d, TIMER_ALL_ACCESS
    call    [rip+__imp_CreateWaitableTimerExW]
2:  mov     [rip+poll_timer], rax
    lea     rbx, [rip+fd_tab]           # fds 0-2: the standard handles
    mov     r12d, STD_INPUT_HANDLE
1:  mov     ecx, r12d
    call    [rip+__imp_GetStdHandle]
    mov     [rbx+FD_HANDLE], rax
    mov     dword ptr [rbx+FD_KIND], K_FILE
    add     rbx, 32
    dec     r12d
    cmp     r12d, STD_INPUT_HANDLE-3
    jne     1b
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
    call    argv_paths
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
    shr     edi, 1                      #  (and win_env's two)
    add     edi, 4
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
    call    win_env
    mov     edi, ebx
    mov     rsi, r12
    call    bee_main                    # (does not return)

# win_env: what the program looks for on Linux, from what Windows has.
# HOME: BEEMODEL_HOME (a portable home; also how tests under Wine, which
# drops HOME, give one), else HOME as it is (Git Bash sets it), else
# USERPROFILE. So ~/BeeModel, ~/.config/beemodel and ~/.cache/beemodel sit
# in the user's folder as on Linux, as git and ssh keep theirs.
# XDG_RUNTIME_DIR: TEMP, unless set. Both in the program's form (/ for \,
# as the code splits paths at /; /C:/... for C:\..., plat_path_in).
# Keeps rbx, r12-r15.
win_env:
    mov     rdx, [rip+envp]             # names in capitals: Windows' are
1:  mov     rsi, [rdx]                  #  case-blind (Path is PATH), the
    test    rsi, rsi                    #  code's getenv is not
    jz      4f
    cmp     byte ptr [rsi], '='         # (=C:=C:\x, the drives' folders)
    je      3f
2:  mov     al, [rsi]
    test    al, al
    jz      3f
    cmp     al, '='
    je      3f
    lea     ecx, [rax-'a']
    cmp     cl, 'z'-'a'
    ja      21f
    sub     al, 'a'-'A'
    mov     [rsi], al
21: inc     rsi
    jmp     2b
3:  add     rdx, 8
    jmp     1b
4:  lea     rdi, [rip+s_bmhome]
    call    env_get
    test    rax, rax
    jnz     1f
    lea     rdi, [rip+s_homeq]
    call    env_get
    test    rax, rax
    jnz     2f
    lea     rdi, [rip+s_uprof]
    call    env_get
    test    rax, rax
    jz      2f
1:  mov     rsi, rax
    lea     rdi, [rip+s_homeq]
    call    env_put
2:  lea     rdi, [rip+s_xdgrt]
    call    env_get
    test    rax, rax
    jnz     3f
    lea     rdi, [rip+s_tempq]
    call    env_get
    test    rax, rax
    jz      3f
    mov     rsi, rax
    lea     rdi, [rip+s_xdgrt]
    call    env_put
3:  ret

# env_get(rdi="NAME=") -> rax = its value, or 0; rdx = its envp slot (or
#   the end's)
env_get:
    mov     rdx, [rip+envp]
1:  mov     rsi, [rdx]
    test    rsi, rsi
    jz      4f
    xor     ecx, ecx
2:  mov     al, [rdi+rcx]
    test    al, al
    jz      3f
    cmp     al, [rsi+rcx]
    jne     5f
    inc     ecx
    jmp     2b
3:  lea     rax, [rsi+rcx]
    ret
5:  add     rdx, 8
    jmp     1b
4:  xor     eax, eax
    ret

# env_put(rdi="NAME=", rsi=value): NAME=value (plat_path_in's) in place of NAME's
#   entry, or after the last
env_put:
    push    rbx
    push    r12
    push    r13
    mov     r12, rdi
    mov     r13, rsi
    xor     ecx, ecx                    # the size
1:  cmp     byte ptr [rdi+rcx], 0
    je      2f
    inc     ecx
    jmp     1b
2:  xor     edx, edx
3:  cmp     byte ptr [rsi+rdx], 0
    je      4f
    inc     edx
    jmp     3b
4:  lea     edi, [rcx+rdx+2]
    call    win_alloc
    mov     rbx, rax
    mov     rdi, rax
    mov     rsi, r12
5:  mov     al, [rsi]
    test    al, al
    jz      6f
    mov     [rdi], al
    inc     rsi
    inc     rdi
    jmp     5b
6:  push    rdi
    mov     rsi, r13
7:  mov     al, [rsi]
    mov     [rdi], al
    inc     rsi
    inc     rdi
    test    al, al
    jnz     7b
    pop     rdi                         # (the program's form)
    call    plat_path_in
    mov     rdi, r12
    call    env_get
    test    rax, rax
    mov     [rdx], rbx
    jnz     9f
    mov     qword ptr [rdx+8], 0
9:  pop     r13
    pop     r12
    pop     rbx
    ret

# argv_paths(ebx = argc, r12 = argv): arguments that are Windows paths
#   (C:\... or C:/..., .\... or ..\...) in the program's form, as Explorer
#   and terminals give them (plat_path_in); keeps rbx, r12-r15
argv_paths:
    push    r13
    push    r14
    push    r15
    mov     r13d, 1
1:  cmp     r13d, ebx
    jae     9f
    mov     r14, [r12+r13*8]
    movzx   eax, byte ptr [r14]
    cmp     eax, '.'
    jne     2f
    lea     rcx, [r14+1]                # .\ or ..\
    cmp     byte ptr [rcx], '.'
    jne     11f
    inc     rcx
11: cmp     byte ptr [rcx], '\\'
    je      4f
    jmp     8f
2:  or      eax, 0x20                   # X:\ or X:/
    sub     eax, 'a'
    cmp     eax, 'z'-'a'
    ja      8f
    cmp     byte ptr [r14+1], ':'
    jne     8f
    cmp     byte ptr [r14+2], '\\'
    je      4f
    cmp     byte ptr [r14+2], '/'
    jne     8f
4:  xor     r15d, r15d                  # a copy, a byte longer
5:  cmp     byte ptr [r14+r15], 0
    je      6f
    inc     r15d
    jmp     5b
6:  lea     edi, [r15+2]
    call    win_alloc
    mov     rdi, rax
    mov     rsi, r14
    lea     ecx, [r15+1]
    rep movsb
    mov     rdi, rax
    call    plat_path_in
    mov     [r12+r13*8], rdi
8:  inc     r13d
    jmp     1b
9:  pop     r15
    pop     r14
    pop     r13
    ret

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
    lea     r9d, [r12-2]
    call    w2u
    mov     byte ptr [rbx+rax], 0
    mov     rdi, rbx                    # (the program's form)
    call    plat_path_in
2:  cmp     byte ptr [rbx+r13], 0
    je      1f
    inc     r13d
    jmp     2b
1:  mov     eax, r13d
    pop     r13
    pop     r12
    pop     rbx
    ret

# ---- memory -------------------------------------------------------------------
# Anonymous private mappings only (files: W3b, shared memory: W6). A plain
# one is reserved and committed at once. A MAP_NORESERVE one (the frame
# arena, the simulation ranges) is only reserved and goes in nr_tab; when a
# thread touches it, win_veh commits that 64 KiB and the access runs again,
# as Linux backs such pages on first touch. Stacks (MAP_STACK) are committed
# whole: a fault on a stack has no stack to be handled on.

# VQ reg: VirtualQuery(reg) into the MEMORY_BASIC_INFORMATION at [rsp+32]
# (needs WENTER 64 or more) -> eax = 0 when the address is out of range
.macro VQ reg
    mov     rcx, \reg
    lea     rdx, [rsp+32]
    mov     r8d, 48
    call    [rip+__imp_VirtualQuery]
.endm

plat_mmap:
    test    r10d, MAP_SHARED_|MAP_FIXED_
    jnz     9f
    test    r10d, MAP_ANONYMOUS_
    jz      mmap_file
    test    rsi, rsi
    jz      8f
    WENTER 16
    lea     rax, [rip+prot_map]
    mov     ecx, edx
    and     ecx, 7
    movzx   r9d, byte ptr [rax+rcx]     # flProtect
    mov     [rsp+32], r9
    lea     rdx, [rsi+4095]             # dwSize
    and     rdx, -4096
    mov     [rsp+40], rdx
    xor     ecx, ecx
    mov     r8d, MEM_COMMIT|MEM_RESERVE
    mov     eax, r10d
    and     eax, MAP_NORESERVE_|MAP_STACK_
    cmp     eax, MAP_NORESERVE_
    jne     1f
    mov     r8d, MEM_RESERVE
1:  call    [rip+__imp_VirtualAlloc]
    test    rax, rax
    jz      2f
    mov     ecx, [rbp-48]               # (the saved r10: the flags)
    and     ecx, MAP_NORESERVE_|MAP_STACK_
    cmp     ecx, MAP_NORESERVE_
    jne     2f
    mov     rdi, rax
    mov     rsi, [rsp+40]
    mov     rdx, [rsp+32]
    call    nr_add
2:  WLEAVE
    test    rax, rax
    jz      7f
    ret
7:  mov     rax, -ENOMEM_
    ret
8:  mov     rax, -EINVAL_
    ret
9:  mov     rax, -ENOSYS_
    ret

# mmap_file: a private mapping of a file, a copy-on-write view of it
# (FILE_MAP_COPY, so plat_mprotect can make it writable); from offset r9
# (a multiple of 64 KiB on Windows), the file at least as long as the view
mmap_file:
    push    rdi
    mov     edi, r8d
    call    fd_entry
    pop     rdi
    test    rax, rax
    jz      8f
    cmp     dword ptr [rax+FD_KIND], K_FILE
    jne     8f
    push    rbx
    push    r12
    WENTER 32
    mov     rcx, [rax+FD_HANDLE]
    xor     edx, edx
    mov     r8d, PAGE_WRITECOPY
    xor     r9d, r9d
    mov     qword ptr [rsp+32], 0
    mov     qword ptr [rsp+40], 0
    call    [rip+__imp_CreateFileMappingW]
    test    rax, rax
    jnz     1f
    call    w_errno
    jmp     7f
1:  mov     rbx, rax
    mov     rcx, rax
    mov     edx, FILE_MAP_COPY
    mov     r9, [rbp+SV_R9]
    mov     r8, r9
    shr     r8, 32
    mov     rax, [rbp+SV_RSI]
    mov     [rsp+32], rax
    call    [rip+__imp_MapViewOfFile]
    mov     r12, rax
    test    rax, rax
    jnz     2f
    call    w_errno
    mov     r12, rax
2:  mov     rcx, rbx
    call    [rip+__imp_CloseHandle]     # (the view keeps the mapping)
    mov     rax, r12
    cmp     rax, -4096
    jae     7f
    test    dword ptr [rbp+SV_RDX], 2   # read-only, unless PROT_WRITE
    jnz     7f
    mov     rcx, r12
    mov     rdx, [rbp+SV_RSI]
    mov     eax, [rbp+SV_RDX]
    and     eax, 7
    lea     r8, [rip+prot_map]
    movzx   r8d, byte ptr [r8+rax]
    lea     r9, [rsp+40]
    call    [rip+__imp_VirtualProtect]
    mov     rax, r12
7:  WLEAVE
    pop     r12
    pop     rbx
    ret
8:  mov     rax, -EBADF_
    ret

# plat_munmap: an allocation the range covers whole is released; of one it
# covers in part, its pages are decommitted (and the allocation released
# once none is left, unless it is in nr_tab)
plat_munmap:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    WENTER 64
    mov     rbx, rdi                    # rbx = start, r12 = here, r13 = end
    and     rbx, -4096
    mov     r12, rbx
    lea     r13, [rdi+rsi+4095]
    and     r13, -4096
.Lmu_next:
    cmp     r12, r13
    jae     .Lmu_done
    VQ      r12
    test    eax, eax
    jz      .Lmu_done
    cmp     dword ptr [rsp+32+MBI_STATE], MEM_FREE
    jne     1f
    mov     r12, [rsp+32+MBI_BASE]
    add     r12, [rsp+32+MBI_SIZE]
    jmp     .Lmu_next
1:  mov     r14, [rsp+32+MBI_ALLOC]     # r14 = the allocation, r15 = its end
    mov     eax, [rsp+32+MBI_TYPE]
    mov     [rsp+88], eax
    call    .Lmu_alloc_end
    cmp     dword ptr [rsp+88], MEM_MAPPED
    jne     11f
    cmp     r14, rbx                    # a file's view: unmapped whole or
    jb      12f                         #  not at all (Windows cannot cut
    cmp     r15, r13                    #  one; it goes with the last part)
    ja      12f
    mov     rcx, r14
    call    [rip+__imp_UnmapViewOfFile]
12: mov     r12, r15
    cmp     r12, r13
    cmova   r12, r13
    jmp     .Lmu_next
11: cmp     r14, rbx
    jb      2f
    cmp     r15, r13
    ja      2f
    mov     rcx, r14                    # all of it
    xor     edx, edx
    mov     r8d, MEM_RELEASE
    call    [rip+__imp_VirtualFree]
    mov     rdi, r14
    call    nr_del
    mov     r12, r15
    jmp     .Lmu_next
2:  mov     rdx, r15                    # part of it
    cmp     rdx, r13
    cmova   rdx, r13
    mov     r15, rdx
    sub     rdx, r12
    mov     rcx, r12
    mov     r8d, MEM_DECOMMIT
    call    [rip+__imp_VirtualFree]
    mov     r12, r15
    mov     rdi, r14
    call    nr_find
    test    rax, rax
    jnz     .Lmu_next
    mov     [rsp+80], r12
    mov     r12, r14
3:  VQ      r12                         # anything still committed?
    test    eax, eax
    jz      4f
    cmp     [rsp+32+MBI_ALLOC], r14
    jne     4f
    cmp     dword ptr [rsp+32+MBI_STATE], MEM_COMMIT
    je      5f
    mov     r12, [rsp+32+MBI_BASE]
    add     r12, [rsp+32+MBI_SIZE]
    jmp     3b
4:  mov     rcx, r14                    # no: release it
    xor     edx, edx
    mov     r8d, MEM_RELEASE
    call    [rip+__imp_VirtualFree]
5:  mov     r12, [rsp+80]
    jmp     .Lmu_next
.Lmu_done:
    WLEAVE
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    xor     eax, eax
    ret
# r15 = the end of allocation r14 (its regions in a row); a call inside
# plat_munmap's frame, so the information block is at [rsp+8+32]. (The
# shadow space goes below the return address.)
.Lmu_alloc_end:
    mov     r15, r14
1:  mov     rcx, r15
    lea     rdx, [rsp+8+32]
    mov     r8d, 48
    sub     rsp, 40
    call    [rip+__imp_VirtualQuery]
    add     rsp, 40
    test    eax, eax
    jz      2f
    cmp     [rsp+8+32+MBI_ALLOC], r14
    jne     2f
    mov     r15, [rsp+8+32+MBI_BASE]
    add     r15, [rsp+8+32+MBI_SIZE]
    jmp     1b
2:  ret

# plat_mprotect: on a file's view, writable is copy-on-write
plat_mprotect:
    WENTER 64
    VQ      [rbp+SV_RDI]
    mov     rdx, [rbp+SV_RDX]
    and     edx, 7
    lea     rax, [rip+prot_map]
    movzx   r8d, byte ptr [rax+rdx]
    cmp     dword ptr [rsp+32+MBI_TYPE], MEM_MAPPED
    jne     2f
    test    edx, 2
    jz      2f
    mov     r8d, PAGE_WRITECOPY
    test    edx, 4
    jz      2f
    mov     r8d, PAGE_EXECUTE_WRITECOPY
2:  mov     rcx, [rbp+SV_RDI]
    mov     rdx, [rbp+SV_RSI]
    lea     r9, [rsp+80]                # (the old protection)
    call    [rip+__imp_VirtualProtect]
    WLEAVE
    test    eax, eax
    jz      1f
    xor     eax, eax
    ret
1:  mov     rax, -ENOMEM_
    ret

# plat_madvise: MADV_DONTNEED and MADV_REMOVE give the pages back; read
# again they are zero, as on Linux (in nr_tab: committed again on touch;
# elsewhere: at once). Other advice is a hint Windows does without.
plat_madvise:
    cmp     edx, MADV_DONTNEED_
    je      1f
    cmp     edx, MADV_REMOVE
    je      1f
    xor     eax, eax
    ret
1:  push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    WENTER 64
    mov     r12, rdi
    and     r12, -4096
    lea     r13, [rdi+rsi+4095]
    and     r13, -4096
2:  cmp     r12, r13
    jae     4f
    VQ      r12
    test    eax, eax
    jz      4f
    mov     r15, [rsp+32+MBI_BASE]
    add     r15, [rsp+32+MBI_SIZE]
    cmp     r15, r13
    cmova   r15, r13
    cmp     dword ptr [rsp+32+MBI_STATE], MEM_COMMIT
    jne     3f
    cmp     dword ptr [rsp+32+MBI_TYPE], MEM_MAPPED
    je      3f                          # (a file's view keeps its pages)
    mov     r14, [rsp+32+MBI_ALLOC]
    mov     ebx, [rsp+32+MBI_PROTECT]
    mov     rcx, r12
    mov     rdx, r15
    sub     rdx, r12
    mov     r8d, MEM_DECOMMIT
    call    [rip+__imp_VirtualFree]
    mov     rdi, r14
    call    nr_find
    test    rax, rax
    jnz     3f
    mov     rcx, r12
    mov     rdx, r15
    sub     rdx, r12
    mov     r8d, MEM_COMMIT
    mov     r9d, ebx
    call    [rip+__imp_VirtualAlloc]
3:  mov     r12, r15
    jmp     2b
4:  WLEAVE
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    xor     eax, eax
    ret

# plat_mremap(rdi=old, rsi=its size, rdx=new size, r10=MREMAP_MAYMOVE):
# smaller in place; bigger always moves (a new mapping, the bytes copied,
# the old one unmapped), so without MREMAP_MAYMOVE it fails
plat_mremap:
    push    rbx
    push    r12
    push    r13
    WENTER 64
    mov     rbx, rdi
    lea     r12, [rsi+4095]             # r12 = old size, r13 = new
    and     r12, -4096
    lea     r13, [rdx+4095]
    and     r13, -4096
    cmp     r13, r12
    ja      2f
    jae     1f
    lea     rdi, [rbx+r13]
    mov     rsi, r12
    sub     rsi, r13
    call    plat_munmap
1:  mov     rax, rbx
    jmp     9f
2:  mov     rax, -ENOMEM_
    test    r10d, 1
    jz      9f
    VQ      rbx
    test    eax, eax
    mov     rax, -EFAULT_
    jz      9f
    xor     ecx, ecx
    mov     rdx, r13
    mov     r8d, MEM_COMMIT|MEM_RESERVE
    mov     r9d, [rsp+32+MBI_PROTECT]
    call    [rip+__imp_VirtualAlloc]
    test    rax, rax
    jz      8f
    mov     r13, rax
    mov     rdi, rax
    mov     rsi, rbx
    mov     rcx, r12
    rep movsb
    mov     rdi, rbx
    mov     rsi, r12
    call    plat_munmap
    mov     rax, r13
    jmp     9f
8:  mov     rax, -ENOMEM_
9:  WLEAVE
    pop     r13
    pop     r12
    pop     rbx
    ret

# plat_mincore: a committed page counts as in memory
plat_mincore:
    push    r12
    push    r13
    push    r14
    WENTER 64
    mov     r12, rdi
    lea     r13, [rdi+rsi+4095]
    and     r13, -4096
    mov     r14, rdx
1:  cmp     r12, r13
    jae     3f
    VQ      r12
    test    eax, eax
    jz      4f
    mov     eax, [rsp+32+MBI_STATE]
    cmp     eax, MEM_FREE
    je      4f
    cmp     eax, MEM_COMMIT
    sete    al
    mov     rcx, [rsp+32+MBI_BASE]
    add     rcx, [rsp+32+MBI_SIZE]
    cmp     rcx, r13
    cmova   rcx, r13
2:  mov     [r14], al
    inc     r14
    add     r12, 4096
    cmp     r12, rcx
    jb      2b
    jmp     1b
3:  xor     eax, eax
    jmp     5f
4:  mov     rax, -ENOMEM_
5:  WLEAVE
    pop     r14
    pop     r13
    pop     r12
    ret

# nr_tab: the MAP_NORESERVE allocations, NR_MAX entries {base, end, Windows
# protection}; a free entry has end 0. Changed under nr_lock; win_veh reads
# it without (an entry's end is written last and cleared first).
.macro SPIN_LOCK var
1:  lock bts dword ptr [rip+\var], 0
    jnc     2f
    pause
    jmp     1b
2:
.endm

# nr_add(rdi=base, rsi=size, rdx=protection); keeps all but rcx, r11. A
# full table: the range is committed instead (Windows may refuse that).
nr_add:
    SPIN_LOCK nr_lock
    lea     r11, [rip+nr_tab]
    xor     ecx, ecx
1:  cmp     qword ptr [r11+8], 0
    je      2f
    add     r11, 24
    inc     ecx
    cmp     ecx, NR_MAX
    jb      1b
    mov     dword ptr [rip+nr_lock], 0
    push    rax
    WENTER
    mov     rcx, rdi
    mov     r9, rdx
    mov     rdx, rsi
    mov     r8d, MEM_COMMIT
    call    [rip+__imp_VirtualAlloc]
    WLEAVE
    pop     rax
    ret
2:  mov     [r11], rdi
    mov     [r11+16], rdx
    lea     rcx, [rdi+rsi]
    mov     [r11+8], rcx
    mov     dword ptr [rip+nr_lock], 0
    ret

# nr_del(rdi=base): its entry goes; keeps all but rcx, r11
nr_del:
    SPIN_LOCK nr_lock
    lea     r11, [rip+nr_tab]
    xor     ecx, ecx
1:  cmp     qword ptr [r11+8], 0
    je      2f
    cmp     [r11], rdi
    jne     2f
    mov     qword ptr [r11+8], 0
    jmp     3f
2:  add     r11, 24
    inc     ecx
    cmp     ecx, NR_MAX
    jb      1b
3:  mov     dword ptr [rip+nr_lock], 0
    ret

# nr_find(rdi=base) -> rax = its entry, or 0; keeps all but rcx, r11
nr_find:
    lea     rax, [rip+nr_tab]
    xor     ecx, ecx
1:  cmp     qword ptr [rax+8], 0
    je      2f
    cmp     [rax], rdi
    je      3f
2:  add     rax, 24
    inc     ecx
    cmp     ecx, NR_MAX
    jb      1b
    xor     eax, eax
3:  ret

# win_veh(rcx=EXCEPTION_POINTERS) -> eax = -1 (go on) or 0 (not ours): the
# vectored exception handler, in the Windows convention. An access fault on
# a reserved page of an nr_tab range commits the 64 KiB around it (within
# the range); any other fault is left to Windows, a real crash as before.
win_veh:
    mov     rax, [rcx]                  # the EXCEPTION_RECORD
    cmp     dword ptr [rax], EXC_ACCESS_VIOLATION
    jne     8f
    cmp     dword ptr [rax+24], 2       # NumberParameters
    jb      8f
    mov     rdx, [rax+40]               # ExceptionInformation[1]: the address
    lea     r8, [rip+nr_tab]
    xor     r9d, r9d
1:  mov     r10, [r8+8]
    test    r10, r10
    jz      2f
    cmp     rdx, [r8]
    jb      2f
    cmp     rdx, r10
    jb      3f
2:  add     r8, 24
    inc     r9d
    cmp     r9d, NR_MAX
    jb      1b
8:  xor     eax, eax
    ret
3:  push    rbx
    push    rsi
    push    rdi
    push    rbp
    mov     rbp, rsp
    and     rsp, -16
    sub     rsp, 96
    mov     rbx, rdx
    mov     rsi, [r8]
    mov     rdi, r10
    mov     eax, [r8+16]
    mov     [rsp+80], eax
    VQ      rbx
    test    eax, eax
    jz      5f
    cmp     dword ptr [rsp+32+MBI_STATE], MEM_RESERVE
    je      4f
    cmp     dword ptr [rsp+32+MBI_STATE], MEM_COMMIT
    jne     5f
    mov     eax, [rsp+80]               # committed meanwhile by another thread
    cmp     [rsp+32+MBI_PROTECT], eax   #  that touched the same 64 KiB: run
    jne     5f                          #  the access again (any other page
    mov     eax, -1                     #  committed: a real fault)
    jmp     6f
4:
    mov     rcx, rbx
    and     rcx, -0x10000
    cmp     rcx, rsi
    cmovb   rcx, rsi
    lea     rdx, [rcx+0x10000]
    cmp     rdx, rdi
    cmova   rdx, rdi
    sub     rdx, rcx
    mov     r8d, MEM_COMMIT
    mov     r9d, [rsp+80]
    call    [rip+__imp_VirtualAlloc]
    test    rax, rax
    jz      5f
    mov     eax, -1                     # EXCEPTION_CONTINUE_EXECUTION
    jmp     6f
5:  xor     eax, eax                    # EXCEPTION_CONTINUE_SEARCH
6:  mov     rsp, rbp
    pop     rbp
    pop     rdi
    pop     rsi
    pop     rbx
    ret

# ---- files and directories -----------------------------------------------------
# An fd is an index into fd_tab: {handle, kind, aux}. 0-2 are the standard
# handles (set at the start). K_FILE: a handle ReadFile and WriteFile take
# (files, the console; pipes and sockets come in W6). K_DIR: a directory
# opened for listing, aux its DS_* block (FindFirstFileW / FindNextFileW).
# Paths arrive in UTF-8 and go to Windows in UTF-16 (u2w_at); '/' works as
# a separator there as it is.
#
# A routine that takes a path keeps WENTER L_SIZE: [rsp+L_SCR] 128 bytes for
# Windows' answers, [rsp+L_W1] and [rsp+L_W2] a path each.

# fd_entry(edi=fd) -> rax = its fd_tab entry, 0 if it is no open fd; keeps
#   all but rax, rcx
fd_entry:
    cmp     edi, FD_MAX
    jae     1f
    mov     eax, edi
    shl     rax, 5
    lea     rcx, [rip+fd_tab]
    add     rax, rcx
    cmp     dword ptr [rax+FD_KIND], 0
    je      1f
    ret
1:  xor     eax, eax
    ret

# fd_alloc(rdi=handle, esi=kind, rdx=aux) -> eax = the lowest free fd, or
#   -EMFILE; keeps all but rax, rcx, r11
fd_alloc:
    SPIN_LOCK fd_lock
    lea     r11, [rip+fd_tab]
    xor     eax, eax
1:  cmp     dword ptr [r11+FD_KIND], 0
    je      2f
    add     r11, 32
    inc     eax
    cmp     eax, FD_MAX
    jb      1b
    mov     dword ptr [rip+fd_lock], 0
    mov     rax, -EMFILE_
    ret
2:  mov     [r11+FD_HANDLE], rdi
    mov     [r11+FD_AUX], rdx
    mov     [r11+FD_KIND], esi
    mov     dword ptr [rip+fd_lock], 0
    ret

# u2w_at(rdi=UTF-8 path, rsi=room for WPATH_UNITS units) -> eax = the units
#   written with the 0, 0 when it does not fit; keeps rbx, rbp, rsi, rdi,
#   r12-r15. Called from a WENTER frame (rsp 16-byte aligned there).
#   "/C:/..." (the program's form of a drive's path, see plat_path_in) is
#   C:/..., and "/C:" the drive's root, C:\.
u2w_at:
    sub     rsp, 56
    mov     r8, rdi
    call    drive_form
    jnz     1f
    inc     r8                          # (past the /)
1:  mov     ecx, CP_UTF8
    xor     edx, edx
    mov     r9d, -1
    mov     [rsp+32], rsi
    mov     dword ptr [rsp+40], WPATH_UNITS
    call    [rip+__imp_MultiByteToWideChar]
    cmp     eax, 3                      # "C:" alone: its root
    jne     2f
    cmp     word ptr [rsi+2], ':'
    jne     2f
    mov     dword ptr [rsi+4], '\\'
    mov     eax, 4
2:  add     rsp, 56
    ret

# drive_form(rdi = UTF-8 path) -> ZF set when it is "/X:" or "/X:/...";
#   keeps all but rax, flags
drive_form:
    test    rdi, rdi                    # (no path: not one)
    jz      7f
    cmp     byte ptr [rdi], '/'
    jne     9f
    movzx   eax, byte ptr [rdi+1]
    or      eax, 0x20
    sub     eax, 'a'
    cmp     eax, 'z'-'a'
    ja      8f
    cmp     byte ptr [rdi+2], ':'
    jne     9f
    movzx   eax, byte ptr [rdi+3]
    test    eax, eax
    jz      9f
    cmp     eax, '/'
    je      9f
    cmp     eax, '\\'
9:  ret
7:  or      eax, 1                      # (ZF clear)
    ret
8:  test    rdi, rdi                    # (ZF clear)
    ret

# plat_path_in(rdi = a path from Windows or typed in, 0-ended, with room
#   for one byte more) - into the program's form, in place: / for \, and a
#   drive's path C:/x as /C:/x, so that / stands for the drives above them
#   all (plat_open lists them) and the code's /-rooted paths work; keeps all
#   but rax, rcx, r11. (Linux: as it is.)
plat_path_in:
    push    rdx
    xor     ecx, ecx                    # \ -> /, and the length
1:  mov     al, [rdi+rcx]
    test    al, al
    jz      2f
    cmp     al, '\\'
    jne     11f
    mov     byte ptr [rdi+rcx], '/'
11: inc     ecx
    jmp     1b
2:  movzx   eax, byte ptr [rdi]         # X: at the start: / before it
    or      eax, 0x20
    sub     eax, 'a'
    cmp     eax, 'z'-'a'
    ja      9f
    cmp     byte ptr [rdi+1], ':'
    jne     9f
    movzx   eax, byte ptr [rdi+2]
    test    eax, eax
    jz      3f
    cmp     eax, '/'
    jne     9f
3:  mov     dl, [rdi+rcx]               # (from the 0 down)
    mov     [rdi+rcx+1], dl
    dec     ecx
    jns     3b
    mov     byte ptr [rdi], '/'
9:  pop     rdx
    ret

# w_errno -> rax = -errno for GetLastError's error (EIO for one not in
#   err_map); keeps rbx, rbp, rsi, rdi, r12-r15. From a WENTER frame.
w_errno:
    sub     rsp, 40
    call    [rip+__imp_GetLastError]
    add     rsp, 40
# w_errno_of(eax=a Windows error) -> rax = -errno
w_errno_of:
    lea     rcx, [rip+err_map]
1:  movzx   edx, word ptr [rcx]
    test    edx, edx
    jz      2f
    cmp     eax, edx
    je      3f
    add     rcx, 4
    jmp     1b
2:  mov     rax, -EIO_
    ret
3:  movzx   eax, word ptr [rcx+2]
    neg     rax
    ret

# WPATH reg, at, fail: the UTF-8 path in reg to UTF-16 at [rsp+at]; to fail
# (rax = -ENAMETOOLONG) when it does not convert
.macro WPATH reg, at, fail
    mov     rdi, \reg
    lea     rsi, [rsp+\at]
    call    u2w_at
    test    eax, eax
    jnz     1f
    mov     rax, -ENAMETOOLONG_
    jmp     \fail
1:
.endm

# plat_open(rdi=path, esi=flags, edx=mode): O_RDONLY / O_WRONLY / O_RDWR,
#   O_CREAT, O_EXCL, O_TRUNC, O_DIRECTORY; O_CLOEXEC is how Windows works
#   anyway, the mode is not used. A directory opened to read becomes a
#   listing (K_DIR). Files are shared for reading, writing and deleting, as
#   on Linux.
plat_open:
    WENTER L_SIZE
    mov     rax, [rbp+SV_RDI]           # "/" to list: the drives
    cmp     word ptr [rax], '/'
    jne     0f
    test    dword ptr [rbp+SV_RSI], O_ACCMODE_
    jz      .Lop_dir
0:  WPATH   [rbp+SV_RDI], L_W1, 9f
    mov     [rsp+L_SCR], eax            # (its units)
    lea     rcx, [rsp+L_W1]
    call    [rip+__imp_GetFileAttributesW]
    mov     r9d, [rbp+SV_RSI]           # the flags
    cmp     eax, -1
    je      2f
    test    eax, FILE_ATTRIBUTE_DIRECTORY
    jz      1f
    test    r9d, O_ACCMODE_             # a directory: to list, not to write
    jz      .Lop_dir
    mov     rax, -EISDIR_
    jmp     9f
1:  test    r9d, O_DIRECTORY_
    jz      3f
    mov     rax, -ENOTDIR_
    jmp     9f
2:  test    r9d, O_DIRECTORY_           # there is nothing (or no way there)
    jz      3f
    call    w_errno
    jmp     9f
3:  mov     eax, r9d                    # a file
    and     eax, O_ACCMODE_
    mov     edx, GENERIC_READ
    cmp     eax, 1
    jb      4f
    mov     edx, GENERIC_WRITE
    je      4f
    mov     edx, GENERIC_READ|GENERIC_WRITE
4:  mov     eax, r9d
    and     eax, O_CREAT_|O_EXCL_|O_TRUNC_
    mov     ecx, OPEN_EXISTING
    cmp     eax, O_TRUNC_
    jne     5f
    mov     ecx, TRUNCATE_EXISTING
5:  test    eax, O_CREAT_
    jz      6f
    mov     ecx, OPEN_ALWAYS
    test    eax, O_TRUNC_
    jz      51f
    mov     ecx, CREATE_ALWAYS
51: test    eax, O_EXCL_
    jz      6f
    mov     ecx, CREATE_NEW
6:  mov     [rsp+32], rcx               # dwCreationDisposition
    mov     qword ptr [rsp+40], FILE_ATTRIBUTE_NORMAL
    mov     qword ptr [rsp+48], 0
    lea     rcx, [rsp+L_W1]
    mov     r8d, FILE_SHARE_ALL
    xor     r9d, r9d
    call    [rip+__imp_CreateFileW]
    cmp     rax, -1
    jne     7f
    call    w_errno
    jmp     9f
7:  mov     rdi, rax
    mov     esi, K_FILE
    xor     edx, edx
    call    fd_alloc
    test    eax, eax
    jns     9f
    mov     rcx, rdi                    # (no fd free)
    call    [rip+__imp_CloseHandle]
    mov     rax, -EMFILE_
    jmp     9f
.Lop_dir:
    xor     edi, edi                    # its listing block
    mov     esi, DS_SIZE
    mov     edx, PROT_RW
    mov     r10d, MAP_ANONYMOUS_|MAP_PRIVATE_
    mov     r8, -1
    xor     r9d, r9d
    call    plat_mmap
    cmp     rax, -4096
    ja      9f
    mov     rdx, rax
    mov     rcx, [rbp+SV_RDI]
    cmp     word ptr [rcx], '/'
    jne     0f
    mov     [rsp+L_SCR+8], rdx
    call    [rip+__imp_GetLogicalDrives]
    test    eax, eax                    # (none known, as under Wine without
    jnz     1f                          #  its mount manager: each root tried)
    mov     [rsp+L_SCR+16], rbx
    xor     ebx, ebx
    mov     dword ptr [rsp+L_W1], 0x3A0041   # "A:\"
    mov     dword ptr [rsp+L_W1+4], '\\'
2:  lea     rcx, [rsp+L_W1]
    call    [rip+__imp_GetFileAttributesW]
    cmp     eax, -1
    je      3f
    movzx   ecx, word ptr [rsp+L_W1]
    sub     ecx, 'A'
    bts     ebx, ecx
3:  inc     word ptr [rsp+L_W1]
    cmp     word ptr [rsp+L_W1], 'Z'
    jbe     2b
    mov     eax, ebx
    mov     rbx, [rsp+L_SCR+16]
1:  mov     rdx, [rsp+L_SCR+8]
    or      eax, 0x80000000
    mov     [rdx+DS_DRV], eax
    jmp     82f
0:  lea     rdi, [rax+DS_PAT]           # the pattern: the path, \*
    lea     rsi, [rsp+L_W1]
    mov     ecx, [rsp+L_SCR]
    dec     ecx
    rep movsw
    cmp     rdi, rdx
    je      8f
    cmp     word ptr [rdi-2], '\\'
    je      81f
    cmp     word ptr [rdi-2], '/'
    je      81f
8:  mov     word ptr [rdi], '\\'
    add     rdi, 2
81: mov     dword ptr [rdi], '*'        # '*', 0
82: xor     edi, edi
    mov     esi, K_DIR
    call    fd_alloc
    test    eax, eax
    jns     9f
    mov     rdi, rdx
    mov     esi, DS_SIZE
    call    plat_munmap
    mov     rax, -EMFILE_
9:  WLEAVE
    ret

# plat_openat(edi=dirfd, rsi=path, edx=flags, r10d=mode): every caller
#   passes AT_FDCWD, so it is plat_open
plat_openat:
    push    rdi
    push    rsi
    mov     rdi, rsi
    mov     esi, edx
    call    plat_open
    pop     rsi
    pop     rdi
    ret

plat_close:
    call    fd_entry
    test    rax, rax
    jz      8f
    WENTER
    mov     rdi, rax
    cmp     dword ptr [rdi+FD_KIND], K_DIR
    je      1f
    cmp     dword ptr [rdi+FD_KIND], K_TIMER
    je      3f
    cmp     dword ptr [rdi+FD_KIND], K_PIPE
    jne     11f
    call    pipe_close
    jmp     3f
11: mov     rcx, [rdi+FD_HANDLE]
    call    [rip+__imp_CloseHandle]
    jmp     3f
1:  mov     rsi, [rdi+FD_AUX]
    mov     rcx, [rsi+DS_HANDLE]
    test    rcx, rcx
    jz      2f
    call    [rip+__imp_FindClose]
2:  push    rdi
    push    rdi
    mov     rdi, rsi
    mov     esi, DS_SIZE
    call    plat_munmap
    pop     rdi
    pop     rdi
3:  mov     dword ptr [rdi+FD_KIND], 0  # free
    WLEAVE
    xor     eax, eax
    ret
8:  mov     rax, -EBADF_
    ret

# plat_read / plat_write(edi=fd, rsi=bytes, rdx=how many) -> rax = how many
#   moved; a closed pipe reads as the end (0)
plat_read:
    push    rbx
    lea     rbx, [rip+__imp_ReadFile]
    jmp     1f
plat_write:
    push    rbx
    lea     rbx, [rip+__imp_WriteFile]
1:  call    fd_entry
    test    rax, rax
    jz      7f
    cmp     dword ptr [rax+FD_KIND], K_FILE
    jne     5f
    WENTER 16
    mov     rcx, [rax+FD_HANDLE]
    mov     r8, rdx
    mov     edx, 0x7ffff000             # (at most, as Linux)
    cmp     r8, rdx
    cmova   r8, rdx
    mov     rdx, rsi
    lea     r9, [rsp+40]
    mov     dword ptr [r9], 0
    mov     qword ptr [rsp+32], 0
    call    [rbx]
    test    eax, eax
    mov     eax, [rsp+40]
    jnz     2f
    call    [rip+__imp_GetLastError]
    cmp     eax, ERROR_BROKEN_PIPE
    je      3f
    cmp     eax, ERROR_HANDLE_EOF
    je      3f
    call    w_errno_of
    jmp     2f
3:  xor     eax, eax
2:  WLEAVE
    pop     rbx
    ret
5:  lea     rcx, [rip+__imp_ReadFile]
    cmp     dword ptr [rax+FD_KIND], K_PIPE
    jne     51f
    cmp     rbx, rcx
    pop     rbx
    je      pipe_read
    jmp     pipe_write
51: cmp     dword ptr [rax+FD_KIND], K_TIMER
    jne     6f
    cmp     rbx, rcx
    jne     4f
    pop     rbx
    jmp     timer_read
4:  mov     rax, -EINVAL_
    pop     rbx
    ret
6:  mov     rax, -EISDIR_
    pop     rbx
    ret
7:  mov     rax, -EBADF_
    pop     rbx
    ret

# fd_seek(rcx=handle, rdx=position or 0, r8d=FILE_BEGIN / FILE_CURRENT) ->
#   rax = the position after; from a WENTER frame
fd_seek:
    sub     rsp, 56
    mov     r9, r8
    lea     r8, [rsp+40]
    call    [rip+__imp_SetFilePointerEx]
    mov     rax, [rsp+40]
    add     rsp, 56
    ret

# plat_pwrite64(edi=fd, rsi=bytes, rdx=how many, r10=at): Windows moves the
#   file position where Linux does not, so it is put back
plat_pwrite64:
    call    fd_entry
    test    rax, rax
    jz      8f
    push    rbx
    push    r12
    push    r13
    WENTER 16
    mov     rbx, [rax+FD_HANDLE]
    mov     rcx, rbx
    xor     edx, edx
    mov     r8d, FILE_CURRENT
    call    fd_seek
    mov     r12, rax
    mov     rcx, rbx
    mov     rdx, [rbp+SV_R10]
    mov     r8d, FILE_BEGIN
    call    fd_seek
    mov     rcx, rbx
    mov     rdx, [rbp+SV_RSI]
    mov     r8, [rbp+SV_RDX]
    lea     r9, [rsp+40]
    mov     dword ptr [r9], 0
    mov     qword ptr [rsp+32], 0
    call    [rip+__imp_WriteFile]
    mov     r13d, [rsp+40]
    test    eax, eax
    jnz     1f
    call    w_errno
    mov     r13, rax
1:  mov     rcx, rbx
    mov     rdx, r12
    mov     r8d, FILE_BEGIN
    call    fd_seek
    mov     rax, r13
    WLEAVE
    pop     r13
    pop     r12
    pop     rbx
    ret
8:  mov     rax, -EBADF_
    ret

# plat_ftruncate(edi=fd, rsi=length), the file position kept
plat_ftruncate:
    call    fd_entry
    test    rax, rax
    jz      8f
    push    rbx
    push    r12
    push    r13
    WENTER
    mov     rbx, [rax+FD_HANDLE]
    mov     rcx, rbx
    xor     edx, edx
    mov     r8d, FILE_CURRENT
    call    fd_seek
    mov     r12, rax
    mov     rcx, rbx
    mov     rdx, [rbp+SV_RSI]
    mov     r8d, FILE_BEGIN
    call    fd_seek
    mov     rcx, rbx
    call    [rip+__imp_SetEndOfFile]
    xor     r13d, r13d
    test    eax, eax
    jnz     1f
    call    w_errno
    mov     r13, rax
1:  mov     rcx, rbx
    mov     rdx, r12
    mov     r8d, FILE_BEGIN
    call    fd_seek
    mov     rax, r13
    WLEAVE
    pop     r13
    pop     r12
    pop     rbx
    ret
8:  mov     rax, -EBADF_
    ret

# fill_stat(rdi=struct stat, rsi=Windows' answer: attributes at 0, the
#   creation, access and write FILETIMEs at 4, 12, 20; rdx=size, rcx=inode):
#   st_ino, st_nlink, st_mode (a folder 040755, a file 0100644, read-only
#   without the write bits), st_size, st_blksize, st_blocks and the times;
#   keeps all but rax, rcx, rdx, r8-r11
fill_stat:
    mov     r8, rdx
    mov     r9, rcx
    push    rdi
    mov     ecx, 18
    xor     eax, eax
    rep stosq
    pop     rdi
    mov     [rdi+8], r9
    mov     qword ptr [rdi+16], 1
    mov     eax, [rsi]
    mov     edx, 0100644
    test    eax, FILE_ATTRIBUTE_DIRECTORY
    jz      1f
    mov     edx, 040755
1:  test    eax, FILE_ATTRIBUTE_READONLY
    jz      2f
    and     edx, ~0222
2:  mov     [rdi+24], edx
    mov     [rdi+48], r8
    mov     qword ptr [rdi+56], 4096
    lea     rax, [r8+511]
    shr     rax, 9
    mov     [rdi+64], rax
    mov     rax, [rsi+12]               # st_atime
    call    ft_unix
    mov     [rdi+72], rax
    mov     [rdi+80], rdx
    mov     rax, [rsi+20]               # st_mtime
    call    ft_unix
    mov     [rdi+88], rax
    mov     [rdi+96], rdx
    mov     rax, [rsi+4]                # st_ctime (the creation)
    call    ft_unix
    mov     [rdi+104], rax
    mov     [rdi+112], rdx
    ret
# ft_unix(rax=FILETIME) -> rax = seconds since 1970, rdx = nanoseconds
ft_unix:
    mov     r10, 116444736000000000     # 1601 -> 1970 in 100 ns
    sub     rax, r10
    jb      1f
    xor     edx, edx
    mov     r10d, 10000000
    div     r10
    imul    rdx, rdx, 100
    ret
1:  xor     eax, eax
    xor     edx, edx
    ret

# plat_stat(rdi=path, rsi=struct stat)
plat_stat:
    WENTER L_SIZE
    WPATH   [rbp+SV_RDI], L_W1, 9f
    lea     rcx, [rsp+L_W1]
    xor     edx, edx                    # GetFileExInfoStandard
    lea     r8, [rsp+L_SCR]
    call    [rip+__imp_GetFileAttributesExW]
    test    eax, eax
    jnz     1f
    call    w_errno
    jmp     9f
1:  mov     rdi, [rbp+SV_RSI]
    lea     rsi, [rsp+L_SCR]
    mov     edx, [rsi+28]               # nFileSizeHigh, Low
    shl     rdx, 32
    mov     eax, [rsi+32]
    or      rdx, rax
    xor     ecx, ecx
    call    fill_stat
    xor     eax, eax
9:  WLEAVE
    ret

# plat_newfstatat(edi=dirfd, rsi=path, rdx=struct stat, r10d=flags): every
#   caller passes AT_FDCWD
plat_newfstatat:
    push    rdi
    push    rsi
    mov     rdi, rsi
    mov     rsi, rdx
    call    plat_stat
    pop     rsi
    pop     rdi
    ret

# plat_fstat(edi=fd, rsi=struct stat): a handle Windows tells nothing about
#   (the console, a pipe) is a character device; a listing is a folder
plat_fstat:
    call    fd_entry
    test    rax, rax
    jz      8f
    WENTER 128
    cmp     dword ptr [rax+FD_KIND], K_DIR
    je      2f
    mov     rcx, [rax+FD_HANDLE]
    lea     rdx, [rsp+64]
    call    [rip+__imp_GetFileInformationByHandle]
    test    eax, eax
    jz      1f
    mov     rdi, [rbp+SV_RSI]
    lea     rsi, [rsp+64]
    mov     edx, [rsi+32]               # nFileSizeHigh, Low
    shl     rdx, 32
    mov     eax, [rsi+36]
    or      rdx, rax
    mov     ecx, [rsi+44]               # nFileIndexHigh, Low: the inode
    shl     rcx, 32
    mov     eax, [rsi+48]
    or      rcx, rax
    call    fill_stat
    jmp     3f
1:  mov     edx, 020666
    jmp     21f
2:  mov     edx, 040755
21: mov     rdi, [rbp+SV_RSI]
    mov     ecx, 18
    xor     eax, eax
    rep stosq
    mov     rdi, [rbp+SV_RSI]
    mov     [rdi+24], edx
    mov     qword ptr [rdi+16], 1
3:  xor     eax, eax
    WLEAVE
    ret
8:  mov     rax, -EBADF_
    ret

# plat_access(rdi=path, esi=F_OK / R_OK / W_OK / X_OK): there is a file; a
#   read-only one is not W_OK. (X_OK: Windows runs any file it can.)
plat_access:
    WENTER L_SIZE
    WPATH   [rbp+SV_RDI], L_W1, 9f
    lea     rcx, [rsp+L_W1]
    call    [rip+__imp_GetFileAttributesW]
    cmp     eax, -1
    jne     1f
    call    w_errno
    jmp     9f
1:  mov     ecx, eax
    xor     eax, eax
    test    dword ptr [rbp+SV_RSI], 2   # W_OK
    jz      9f
    and     ecx, FILE_ATTRIBUTE_READONLY|FILE_ATTRIBUTE_DIRECTORY
    cmp     ecx, FILE_ATTRIBUTE_READONLY
    jne     9f
    mov     rax, -EACCES_
9:  WLEAVE
    ret

# plat_getdents64(edi=fd, rsi=buffer, edx=its size) -> rax = the bytes of
#   linux_dirent64 records written {d_ino, d_off, d_reclen, d_type, name},
#   0 at the end. An entry that does not fit waits for the next call.
plat_getdents64:
    call    fd_entry
    test    rax, rax
    jz      .Lgd_badf
    cmp     dword ptr [rax+FD_KIND], K_DIR
    jne     .Lgd_notdir
    push    rbx
    push    r12
    push    r13
    push    r14
    WENTER 64
    mov     rbx, [rax+FD_AUX]
    mov     r12, rsi                    # r12 = the buffer, r13d its size,
    mov     r13d, edx                   # r14 = where
    xor     r14d, r14d
    cmp     dword ptr [rbx+DS_DONE], 0
    jne     .Lgd_out
    cmp     dword ptr [rbx+DS_DRV], 0
    jne     .Lgd_drives
    cmp     qword ptr [rbx+DS_HANDLE], 0
    jne     .Lgd_next
    lea     rcx, [rbx+DS_PAT]
    lea     rdx, [rbx+DS_FIND]
    call    [rip+__imp_FindFirstFileW]
    cmp     rax, -1
    jne     1f
    call    [rip+__imp_GetLastError]
    mov     dword ptr [rbx+DS_DONE], 1
    cmp     eax, ERROR_FILE_NOT_FOUND
    je      .Lgd_out
    call    w_errno_of
    mov     r14, rax
    jmp     .Lgd_out
1:  mov     [rbx+DS_HANDLE], rax
    mov     dword ptr [rbx+DS_PEND], 1
.Lgd_next:
    cmp     dword ptr [rbx+DS_PEND], 0
    jne     2f
    mov     rcx, [rbx+DS_HANDLE]
    lea     rdx, [rbx+DS_FIND]
    call    [rip+__imp_FindNextFileW]
    test    eax, eax
    jnz     11f
    mov     dword ptr [rbx+DS_DONE], 1
    jmp     .Lgd_out
11: mov     dword ptr [rbx+DS_PEND], 1
2:  mov     eax, r13d                   # the name, if it fits
    sub     eax, r14d
    sub     eax, 20
    jle     .Lgd_full
    mov     [rsp+40], rax               # cbMultiByte
    lea     rax, [r12+r14+19]
    mov     [rsp+32], rax               # lpMultiByteStr
    xor     eax, eax
    mov     [rsp+48], rax
    mov     [rsp+56], rax
    mov     ecx, CP_UTF8
    xor     edx, edx
    lea     r8, [rbx+DS_FIND+44]        # cFileName
    mov     r9d, -1
    call    [rip+__imp_WideCharToMultiByte]
    test    eax, eax
    jz      .Lgd_full
    lea     ecx, [rax+19+7]             # d_reclen
    and     ecx, -8
    lea     eax, [r14+rcx]
    cmp     eax, r13d
    ja      .Lgd_full
    lea     rdx, [r12+r14]
    inc     qword ptr [rbx+DS_INO]
    mov     r8, [rbx+DS_INO]
    mov     [rdx], r8                   # d_ino
    mov     [rdx+8], rax                # d_off
    mov     [rdx+16], cx                # d_reclen
    mov     r8d, [rbx+DS_FIND]          # d_type
    mov     r9b, DT_DIR_
    test    r8d, FILE_ATTRIBUTE_DIRECTORY
    jnz     3f
    mov     r9b, DT_REG_
    test    r8d, FILE_ATTRIBUTE_REPARSE_POINT
    jz      3f
    cmp     dword ptr [rbx+DS_FIND+36], IO_REPARSE_TAG_SYMLINK
    jne     3f
    mov     r9b, DT_LNK_
3:  mov     [rdx+18], r9b
    mov     r14d, eax
    mov     dword ptr [rbx+DS_PEND], 0
    jmp     .Lgd_next
.Lgd_drives:                            # "/": a folder "X:" a drive
    mov     eax, [rbx+DS_DRV]
    and     eax, 0x3FFFFFF
    jz      .Lgd_out
    bsf     ecx, eax
    lea     eax, [r14+24]
    cmp     eax, r13d
    ja      .Lgd_full
    btr     dword ptr [rbx+DS_DRV], ecx
    lea     rdx, [r12+r14]
    inc     qword ptr [rbx+DS_INO]
    mov     r8, [rbx+DS_INO]
    mov     [rdx], r8                   # d_ino
    mov     [rdx+8], rax                # d_off
    mov     word ptr [rdx+16], 24       # d_reclen
    mov     byte ptr [rdx+18], DT_DIR_
    add     ecx, 'A'
    mov     [rdx+19], cl
    mov     dword ptr [rdx+20], ':'
    mov     r14d, eax
    jmp     .Lgd_drives
.Lgd_full:
    test    r14, r14
    jnz     .Lgd_out
    mov     r14, -EINVAL_               # (not even one fits)
.Lgd_out:
    mov     rax, r14
    WLEAVE
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret
.Lgd_badf:
    mov     rax, -EBADF_
    ret
.Lgd_notdir:
    mov     rax, -ENOTDIR_
    ret

# PATHCALL name, api: plat_<name>(rdi=path) -> 0 or -errno, as <api>(path)
# (with rdx = 0: CreateDirectoryW's attributes)
.macro PATHCALL name, api
plat_\name:
    WENTER L_SIZE
    WPATH   [rbp+SV_RDI], L_W1, 9f
    lea     rcx, [rsp+L_W1]
    xor     edx, edx
    call    [rip+__imp_\api]
    test    eax, eax
    mov     eax, 0
    jnz     9f
    call    w_errno
9:  WLEAVE
    ret
.endm
PATHCALL chdir, SetCurrentDirectoryW
PATHCALL mkdir, CreateDirectoryW
PATHCALL rmdir, RemoveDirectoryW
PATHCALL unlink, DeleteFileW

# plat_rename(rdi=from, rsi=to): over what is there, as on Linux
plat_rename:
    WENTER L_SIZE
    WPATH   [rbp+SV_RDI], L_W1, 9f
    WPATH   [rbp+SV_RSI], L_W2, 9f
    lea     rcx, [rsp+L_W1]
    lea     rdx, [rsp+L_W2]
    mov     r8d, MOVEFILE_REPLACE_EXISTING
    call    [rip+__imp_MoveFileExW]
    test    eax, eax
    mov     eax, 0
    jnz     9f
    call    w_errno
9:  WLEAVE
    ret

# plat_chmod(rdi=path, esi=mode): the callers make folders their owner's
#   only (0700), which a user's folders on Windows are; the file must exist
plat_chmod:
    WENTER L_SIZE
    WPATH   [rbp+SV_RDI], L_W1, 9f
    lea     rcx, [rsp+L_W1]
    call    [rip+__imp_GetFileAttributesW]
    cmp     eax, -1
    mov     eax, 0
    jne     9f
    call    w_errno
9:  WLEAVE
    ret

# plat_readlink: nothing on Windows is read as a link (the one caller,
#   plat_self_path, has its own way)
plat_readlink:
    mov     rax, -EINVAL_
    ret

# plat_statfs(rdi=path, rsi=struct statfs): the free space, in 4 KiB
#   blocks (f_bsize, f_blocks, f_bfree, f_bavail, f_namelen, f_frsize)
plat_statfs:
    WENTER L_SIZE
    WPATH   [rbp+SV_RDI], L_W1, 9f
    lea     rcx, [rsp+L_W1]
    lea     rdx, [rsp+L_SCR]            # to us
    lea     r8, [rsp+L_SCR+8]           # in all
    lea     r9, [rsp+L_SCR+16]          # free
    call    [rip+__imp_GetDiskFreeSpaceExW]
    test    eax, eax
    jnz     1f
    call    w_errno
    jmp     9f
1:  mov     rdi, [rbp+SV_RSI]
    mov     ecx, 15
    xor     eax, eax
    rep stosq
    mov     rdi, [rbp+SV_RSI]
    mov     qword ptr [rdi+8], 4096
    mov     qword ptr [rdi+72], 4096
    mov     qword ptr [rdi+64], 255
    mov     rax, [rsp+L_SCR+8]
    shr     rax, 12
    mov     [rdi+16], rax
    mov     rax, [rsp+L_SCR+16]
    shr     rax, 12
    mov     [rdi+24], rax
    mov     rax, [rsp+L_SCR]
    shr     rax, 12
    mov     [rdi+32], rax
    xor     eax, eax
9:  WLEAVE
    ret

# ---- threads, futexes, time -------------------------------------------------------
# plat_thread_start(rdi=entry, rsi=arg, rdx=stack top, rcx=tid word or 0)
#   -> eax = the new thread's id, or -errno. Not the syscall contract: an
#   ordinary call (rax, rcx, rdx, rsi, rdi, r8-r11 are not kept). The thread
#   runs entry(rdi=arg) on the given stack (a MAP_STACK mapping: committed
#   whole), entered with rsp 16-byte aligned before the call, and ends when
#   entry returns. A tid word gets the thread's id before it runs, and 0 and
#   a wake (WakeByAddressAll) when it has ended, as CLONE_CHILD_SETTID and
#   CLONE_CHILD_CLEARTID do on Linux.
#
#   Windows starts the thread on a small stack of its own in win_thread,
#   which moves to the given stack and points the thread's TEB stack bounds
#   at it (StackBase gs:[8], StackLimit gs:[16]), so that exception dispatch
#   and the stack probes inside Windows see the stack the thread is on;
#   it puts them back before the thread ends.
plat_thread_start:
    push    rbx
    push    r12
    push    r13
    mov     rbx, rdx                    # the block, on top of the new stack:
    sub     rbx, TB_SIZE                #  {entry, arg, top, bottom, tid word}
    and     rbx, -16
    mov     [rbx+TB_ENTRY], rdi
    mov     [rbx+TB_ARG], rsi
    mov     [rbx+TB_TOP], rbx
    mov     [rbx+TB_TID], rcx
    WENTER 96
    lea     rcx, [rdx-1]                # the stack's bottom: its allocation
    lea     rdx, [rsp+32]
    mov     r8d, 48
    call    [rip+__imp_VirtualQuery]
    mov     rax, [rsp+32+MBI_ALLOC]
    mov     [rbx+TB_BOTTOM], rax
    xor     ecx, ecx                    # CreateThread, suspended
    mov     edx, 0x10000                # (its own small stack, for the start)
    lea     r8, [rip+win_thread]
    mov     r9, rbx
    mov     qword ptr [rsp+32], CREATE_SUSPENDED
    lea     rax, [rsp+88]
    mov     [rsp+40], rax               # lpThreadId
    call    [rip+__imp_CreateThread]
    test    rax, rax
    jnz     1f
    call    w_errno
    jmp     9f
1:  mov     r12, rax
    mov     r13d, [rsp+88]
    mov     rcx, [rbx+TB_TID]           # the tid word, before it runs
    test    rcx, rcx
    jz      2f
    mov     [rcx], r13d
2:  mov     rcx, r12
    call    [rip+__imp_ResumeThread]
    mov     rcx, r12
    call    [rip+__imp_CloseHandle]
    mov     eax, r13d
9:  WLEAVE
    pop     r13
    pop     r12
    pop     rbx
    ret

# win_thread(rcx=the block): a new thread's start, in the Windows convention
win_thread:
    push    rbx
    push    rbp
    push    rsi
    push    rdi
    push    r12
    push    r13
    push    r14
    push    r15
    sub     rsp, 168                    # xmm6-xmm15 (Windows keeps them)
    movdqu  [rsp], xmm6
    movdqu  [rsp+16], xmm7
    movdqu  [rsp+32], xmm8
    movdqu  [rsp+48], xmm9
    movdqu  [rsp+64], xmm10
    movdqu  [rsp+80], xmm11
    movdqu  [rsp+96], xmm12
    movdqu  [rsp+112], xmm13
    movdqu  [rsp+128], xmm14
    movdqu  [rsp+144], xmm15
    mov     rbx, rcx
    mov     r12, gs:[8]                 # Windows' bounds, for the end
    mov     r13, gs:[16]
    mov     r14, rsp
    mov     r15, [rbx+TB_TID]           # (the block may be gone by the end)
    mov     rax, [rbx+TB_TOP]
    mov     gs:[8], rax
    mov     rax, [rbx+TB_BOTTOM]
    mov     gs:[16], rax
    mov     rdi, [rbx+TB_ARG]
    mov     rax, [rbx+TB_ENTRY]
    mov     rsp, rbx                    # (16-byte aligned)
    call    rax
    mov     rsp, r14
    mov     gs:[8], r12
    mov     gs:[16], r13
    test    r15, r15
    jz      1f
    mov     dword ptr [r15], 0          # the tid word: 0, and a wake
    mov     rcx, r15
    sub     rsp, 32                     # (rsp is 16-byte aligned here)
    call    [rip+__imp_WakeByAddressAll]
    add     rsp, 32
1:  movdqu  xmm6, [rsp]
    movdqu  xmm7, [rsp+16]
    movdqu  xmm8, [rsp+32]
    movdqu  xmm9, [rsp+48]
    movdqu  xmm10, [rsp+64]
    movdqu  xmm11, [rsp+80]
    movdqu  xmm12, [rsp+96]
    movdqu  xmm13, [rsp+112]
    movdqu  xmm14, [rsp+128]
    movdqu  xmm15, [rsp+144]
    add     rsp, 168
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rdi
    pop     rsi
    pop     rbp
    pop     rbx
    xor     eax, eax
    ret

# plat_futex(rdi=the word, esi=op, edx=val, r10=timeout or 0): FUTEX_WAIT
#   (-EAGAIN when the word is not val, -ETIMEDOUT after the relative
#   timeout) and FUTEX_WAKE (val 1: one waiter, else all; gives 0, as
#   WaitOnAddress cannot count them), private or not
plat_futex:
    mov     eax, esi
    and     eax, ~FUTEX_PRIVATE_
    cmp     eax, FUTEX_WAKE_
    je      .Lfx_wake
    test    eax, eax
    jnz     .Lfx_nosys
    cmp     [rdi], edx
    jne     .Lfx_again
    WENTER 16
    mov     [rsp+32], edx               # the value it is to have
    mov     r9d, -1                     # INFINITE
    test    r10, r10
    jz      1f
    mov     rax, [r10]                  # tv_sec * 1000 + tv_nsec rounded up
    imul    rax, rax, 1000
    mov     rcx, [r10+8]
    add     rcx, 999999
    mov     r8, rax
    mov     rax, rcx
    xor     edx, edx
    mov     ecx, 1000000
    div     rcx
    add     rax, r8
    mov     r9d, 0xfffffffe             # (just short of INFINITE)
    cmp     rax, r9
    cmovb   r9d, eax
1:  mov     rcx, [rbp+SV_RDI]
    lea     rdx, [rsp+32]
    mov     r8d, 4
    call    [rip+__imp_WaitOnAddress]
    test    eax, eax
    mov     eax, 0
    jnz     2f
    call    [rip+__imp_GetLastError]
    cmp     eax, ERROR_TIMEOUT
    je      3f
    cmp     eax, WAIT_TIMEOUT           # (Wine's answer)
    je      3f
    call    w_errno_of
    jmp     2f
3:  mov     rax, -ETIMEDOUT_
2:  WLEAVE
    ret
.Lfx_wake:
    WENTER
    mov     rcx, rdi
    cmp     edx, 1
    je      1f
    call    [rip+__imp_WakeByAddressAll]
    jmp     2f
1:  call    [rip+__imp_WakeByAddressSingle]
2:  WLEAVE
    xor     eax, eax
    ret
.Lfx_again:
    mov     rax, -EAGAIN_
    ret
.Lfx_nosys:
    mov     rax, -ENOSYS_
    ret

# plat_sched_getaffinity(edi=pid, esi=bytes, rdx=mask) -> rax = the bytes
#   written: a bit for each processor Windows gives the program
plat_sched_getaffinity:
    WENTER
    mov     ecx, ALL_PROCESSOR_GROUPS
    call    [rip+__imp_GetActiveProcessorCount]
    mov     rdi, [rbp+SV_RDX]
    mov     ecx, [rbp+SV_RSI]
    shl     ecx, 3
    cmp     eax, ecx
    cmova   eax, ecx
    mov     r8d, eax
    mov     ecx, [rbp+SV_RSI]
    xor     eax, eax
    rep stosb
    mov     rdi, [rbp+SV_RDX]
    xor     ecx, ecx
1:  cmp     ecx, r8d
    jae     2f
    bts     dword ptr [rdi], ecx
    inc     ecx
    jmp     1b
2:  mov     eax, [rbp+SV_RSI]
    WLEAVE
    ret

# plat_clock_gettime(edi=clock, rsi=struct timespec): CLOCK_REALTIME from
#   the system time; every other clock (the callers' CLOCK_MONOTONIC) from
#   the performance counter
plat_clock_gettime:
    WENTER 16
    test    edi, edi
    jnz     1f
    lea     rcx, [rsp+32]
    call    [rip+__imp_GetSystemTimePreciseAsFileTime]
    mov     rax, [rsp+32]
    call    ft_unix
    jmp     2f
1:  lea     rcx, [rsp+32]
    call    [rip+__imp_QueryPerformanceCounter]
    mov     rax, [rsp+32]
    mov     rcx, [rip+qpc_freq]
    xor     edx, edx
    div     rcx                         # seconds, and the counts left over
    mov     r8, rax
    mov     rax, rdx
    mov     edx, 1000000000
    mul     rdx
    div     rcx
    mov     rdx, rax
    mov     rax, r8
2:  mov     rsi, [rbp+SV_RSI]
    mov     [rsi], rax
    mov     [rsi+8], rdx
    WLEAVE
    xor     eax, eax
    ret

# plat_time(rdi=where or 0) -> rax = seconds since 1970
plat_time:
    push    rdi
    push    rsi
    sub     rsp, 24
    xor     edi, edi
    mov     rsi, rsp
    call    plat_clock_gettime
    mov     rax, [rsp]
    add     rsp, 24
    pop     rsi
    pop     rdi
    test    rdi, rdi
    jz      1f
    mov     [rdi], rax
1:  ret

# plat_nanosleep(rdi=struct timespec, rsi=rest or 0): in milliseconds,
#   rounded up (Sleep)
plat_nanosleep:
    WENTER
    mov     rax, [rdi+8]
    add     rax, 999999
    xor     edx, edx
    mov     ecx, 1000000
    div     rcx
    imul    rcx, [rdi], 1000
    add     rcx, rax
    call    [rip+__imp_Sleep]
    WLEAVE
    xor     eax, eax
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

# ---- poll ------------------------------------------------------------------------
# plat_win_msgfd(rdi=the window's wait routine) -> eax = an fd standing for
#   the thread's message queue, for plat_poll. The routine is called in the
#   Windows convention: ecx = handles, rdx = where they are, r8d =
#   milliseconds (-1 forever) -> eax = MsgWaitForMultipleObjectsEx's answer
#   (ecx: messages are waiting). (The window, plat_win_wnd.s, has the user32
#   side, so the tests' programs link without it.)
plat_win_msgfd:
    mov     [rip+msg_wait], rdi
    push    rdx
    push    rsi
    push    rdi
    xor     edi, edi
    mov     esi, K_MSG
    xor     edx, edx
    call    fd_alloc
    pop     rdi
    pop     rsi
    pop     rdx
    ret

# plat_poll(rdi=pollfds, esi=count, edx=timeout ms, -1 forever) -> rax = the
#   fds with news. Files and directories are always ready, as on Linux; a
#   timerfd is when its time has come; the message queue (one per call)
#   when messages wait or the window's next frame is due (plat_win_frame_due,
#   told once). The wait ends at the first of the timeout and those times,
#   on the high-resolution timer: Windows' own timeouts go by its tick
#   (15.6 ms), too coarse for play mode's 8 ms or a frame's 16.7. Our end
#   of a pipe when data or its end has come (the wait takes its read's
#   event; at most POLL_PIPES of them). Sockets: W6b.
plat_poll:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    WENTER  32+8*(POLL_PIPES+4)         # [rsp+48] the timer's due time, [rsp+56] now,
                                        #  [rsp+64] where the handles start: [rsp+72]
                                        #  the timer, [rsp+80...] the pipes'
    mov     r12, rdi
    mov     r13d, esi
    call    w_now_ns
    mov     [rsp+56], rax
    mov     r15, -1                     # the wait's end (ns), -1: none
    mov     ecx, [rbp+SV_RDX]
    test    ecx, ecx
    js      1f
    imul    rcx, rcx, 1000000
    add     rcx, rax
    mov     r15, rcx
1:  mov     r8, rax
    lea     r10, [rsp+80]
    call    poll_scan
    lea     rax, [rsp+80]               # edi = handles to wait on, esi = ms
    mov     [rsp+64], rax
    sub     r10, rax
    shr     r10, 3
    mov     edi, r10d
    xor     esi, esi
    test    ebx, ebx                    # news already: only a look at the queue
    jnz     4f
    mov     esi, -1
    cmp     r15, -1
    je      4f
    mov     rax, r15
    sub     rax, [rsp+56]
    jbe     3f
    cmp     qword ptr [rip+poll_timer], 0
    je      2f
    add     rax, 99                     # (in 100 ns, from now: negative)
    xor     edx, edx
    mov     ecx, 100
    div     rcx
    neg     rax
    mov     [rsp+48], rax
    mov     rcx, [rip+poll_timer]
    lea     rdx, [rsp+48]
    xor     r8d, r8d
    xor     r9d, r9d
    mov     qword ptr [rsp+32], 0
    mov     qword ptr [rsp+40], 0
    call    [rip+__imp_SetWaitableTimer]
    test    eax, eax
    jz      21f
    mov     rax, [rip+poll_timer]       # the timer too, and no timeout
    mov     [rsp+72], rax
    lea     rax, [rsp+72]
    mov     [rsp+64], rax
    inc     edi
    jmp     4f
21: mov     rax, r15                    # no timer: Windows' timeout, rounded up
    sub     rax, [rsp+56]
2:  add     rax, 999999
    xor     edx, edx
    mov     ecx, 1000000
    div     rcx
    mov     esi, eax
    jmp     4f
3:  xor     esi, esi
4:  test    r14d, r14d
    js      6f
    mov     ecx, edi                    # the queue (and the handles)
    mov     rdx, [rsp+64]
    mov     r8d, esi
    call    [rip+msg_wait]
    cmp     eax, edi                    # WAIT_OBJECT_0 + n: messages
    jne     7f
    lea     rax, [r12+r14*8]
    cmp     word ptr [rax+6], 0
    jne     7f
    mov     word ptr [rax+6], POLLIN
    inc     ebx
    jmp     7f
6:  test    ebx, ebx                    # no queue
    jnz     8f
    test    edi, edi
    jz      61f
    mov     ecx, edi
    mov     rdx, [rsp+64]
    xor     r8d, r8d
    mov     r9d, esi
    call    [rip+__imp_WaitForMultipleObjects]
    jmp     7f
61: mov     ecx, esi
    call    [rip+__imp_Sleep]
7:  test    ebx, ebx                    # woken by the time: whose has come
    jnz     8f
    call    w_now_ns
    mov     r8, rax
    lea     r10, [rsp+80]
    call    poll_scan
8:  mov     eax, ebx
    WLEAVE
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# poll_scan(r12 = pollfds, r13d = count, r8 = now, r10 = where the pipes'
#   events go) -> ebx = the fds with news (their revents set), r14d = the
#   queue's entry or -1, r15 = lowered to the first time to come, r10 after
#   the events of pipes with a read on its way; keeps rbp, r12, r13; rax,
#   rcx, rdx, rsi, rdi, r9 lost
poll_scan:
    xor     ebx, ebx
    mov     r14d, -1
    xor     esi, esi
1:  cmp     esi, r13d
    jae     9f
    lea     r9, [r12+rsi*8]
    mov     word ptr [r9+6], 0
    mov     edi, [r9]
    test    edi, edi                    # (negative: ignored)
    js      4f
    call    fd_entry
    test    rax, rax
    jnz     2f
    mov     word ptr [r9+6], POLLNVAL_
    inc     ebx
    jmp     4f
2:  mov     ecx, [rax+FD_KIND]
    cmp     ecx, K_MSG
    je      5f
    cmp     ecx, K_TIMER
    je      6f
    cmp     ecx, K_PIPE
    je      10f
    movzx   ecx, word ptr [r9+4]        # files: always ready
    and     ecx, POLLIN|POLLOUT_
    mov     [r9+6], cx
    test    ecx, ecx
    jz      4f
    inc     ebx
4:  inc     esi
    jmp     1b
5:  mov     r14d, esi                   # the queue: the frame's time
    mov     rax, [rip+plat_win_frame_due]
    jmp     7f
6:  mov     rax, [rax+FD_AUX]           # a timer: its time
7:  test    rax, rax                    # (0: none)
    jz      4b
    cmp     r8, rax
    jae     8f
    cmp     rax, r15
    jae     4b
    mov     r15, rax
    jmp     4b
8:  test    word ptr [r9+4], POLLIN     # come
    jz      4b
    cmp     ecx, K_MSG
    jne     81f
    mov     qword ptr [rip+plat_win_frame_due], 0   # (told once)
81: mov     word ptr [r9+6], POLLIN
    inc     ebx
    jmp     4b
10: movzx   ecx, word ptr [r9+4]        # a pipe: writing waits for room itself;
    and     ecx, POLLOUT_               #  reading when data or the end is there,
    test    word ptr [r9+4], POLLIN     #  else its read's event is waited on
    jz      12f
    push    rcx
    push    rax
    call    pipe_ready
    mov     edx, eax
    pop     rax
    pop     rcx
    test    edx, edx
    jz      11f
    or      ecx, POLLIN
    jmp     12f
11: mov     rdx, [rax+FD_AUX]
    mov     rdx, [rdx+PB_OV+OV_EVENT]
    mov     [r10], rdx
    add     r10, 8
12: mov     [r9+6], cx
    test    ecx, ecx
    jz      4b
    inc     ebx
    jmp     4b
9:  ret

# w_now_ns -> rax = the monotonic clock in ns (what plat_clock_gettime
#   gives); from a WENTER frame: rcx, rdx, r8-r11 lost
w_now_ns:
    sub     rsp, 40
    lea     rcx, [rsp+32]
    call    [rip+__imp_QueryPerformanceCounter]
    mov     rax, [rsp+32]
    mov     ecx, 1000000000
    mul     rcx
    div     qword ptr [rip+qpc_freq]
    add     rsp, 40
    ret

# mono_now -> rax = the same, keeping all but rax, rcx, r11
mono_now:
    WENTER
    call    w_now_ns
    WLEAVE
    ret

# ---- timers --------------------------------------------------------------------
# A timerfd is its due time and interval in fd_tab: plat_poll waits for the
# first one to come, read counts what has come since.
# plat_timerfd_create(edi=clock, esi=flags) -> rax = the fd (the clock is
#   the monotonic one; never readable, read says -EAGAIN until it is due)
plat_timerfd_create:
    push    rdx
    push    rsi
    push    rdi
    xor     edi, edi
    mov     esi, K_TIMER
    xor     edx, edx
    call    fd_alloc
    test    eax, eax
    js      1f
    mov     edi, eax
    call    fd_entry
    mov     qword ptr [rax+FD_TIVL], 0
    mov     eax, edi
1:  pop     rdi
    pop     rsi
    pop     rdx
    ret

# plat_timerfd_settime(edi=fd, esi=flags, rdx=struct itimerspec {interval,
#   value}, r10=the old one or 0) -> rax = 0; a value of 0 disarms it
plat_timerfd_settime:
    call    fd_entry
    test    rax, rax
    jz      8f
    cmp     dword ptr [rax+FD_KIND], K_TIMER
    jne     7f
    push    rbx
    push    r12
    mov     rbx, rax
    test    r10, r10                    # (the old one: not kept, said 0)
    jz      1f
    mov     qword ptr [r10], 0
    mov     qword ptr [r10+8], 0
    mov     qword ptr [r10+16], 0
    mov     qword ptr [r10+24], 0
1:  imul    rax, [rdx], 1000000000
    add     rax, [rdx+8]
    mov     [rbx+FD_TIVL], rax
    imul    r12, [rdx+16], 1000000000
    add     r12, [rdx+24]
    jz      3f
    test    esi, TFD_TIMER_ABSTIME_
    jnz     2f
    call    mono_now
    add     r12, rax
2:  mov     [rbx+FD_AUX], r12
    jmp     4f
3:  mov     qword ptr [rbx+FD_AUX], 0
4:  xor     eax, eax
    pop     r12
    pop     rbx
    ret
7:  mov     rax, -EINVAL_
    ret
8:  mov     rax, -EBADF_
    ret

# timer_read(rax = its fd_tab entry, rsi = 8 bytes, rdx = their size) ->
#   rax = 8 and how many times it came since (u64), or -EAGAIN
timer_read:
    cmp     rdx, 8
    jb      7f
    push    rbx
    push    r12
    mov     rbx, rax
    call    mono_now
    mov     rcx, [rbx+FD_AUX]
    test    rcx, rcx
    jz      6f
    sub     rax, rcx
    jb      6f
    mov     r12, [rbx+FD_TIVL]
    test    r12, r12
    jnz     1f
    mov     qword ptr [rbx+FD_AUX], 0   # once: done
    mov     eax, 1
    jmp     2f
1:  push    rdx
    xor     edx, edx
    div     r12                         # whole intervals since it came
    inc     rax
    mov     rcx, rax
    imul    rcx, r12
    add     [rbx+FD_AUX], rcx           # (the next time)
    pop     rdx
2:  mov     [rsi], rax
    mov     eax, 8
    pop     r12
    pop     rbx
    ret
6:  mov     rax, -EAGAIN_
    pop     r12
    pop     rbx
    ret
7:  mov     rax, -EINVAL_
    ret

# ---- pipes -----------------------------------------------------------------------
# A pipe is a named pipe of its own (\\.\pipe\beemodel-<pid>-<n>): our end
# (fd[0], K_PIPE) is overlapped, with a read always on its way into the
# block's buffer, so plat_poll can wait on its event among the others; the
# other end (fd[1], K_FILE) is a plain handle, for a child (anonymous pipes
# can be neither waited on nor read without blocking). plat_pipe2's is one
# way (fd[1] writes, fd[0] reads); plat_socketpair's both ways (ffmpeg's
# stdin: we write the frames on fd[0]).

# plat_pipe2(rdi=int fds[2], esi=flags) -> rax = 0 or -errno
plat_pipe2:
    push    rsi
    xor     esi, esi
    call    pipe_pair
    pop     rsi
    ret

# plat_socketpair(edi=domain, esi=type, edx=protocol, r10=int sv[2]):
#   AF_UNIX streams only, as a pipe both ways (sockets and the GPU helper's
#   packets: W6b, W6c)
plat_socketpair:
    cmp     edi, 1                      # AF_UNIX
    jne     8f
    mov     eax, esi
    and     eax, 0xf
    cmp     eax, 1                      # SOCK_STREAM
    jne     8f
    push    rdi
    push    rsi
    mov     rdi, r10
    mov     esi, 1
    call    pipe_pair
    pop     rsi
    pop     rdi
    ret
8:  mov     rax, -ENOSYS_
    ret

# pipe_pair(rdi=int fds[2], esi=1: both ways) -> rax = 0 or -errno
pipe_pair:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    WENTER  128                         # [rsp+64] the name (UTF-16)
    mov     r12, rdi
    mov     r13d, esi
    mov     rbx, -1                     # (the handles: none yet)
    mov     r14, -1
    xor     r15d, r15d                  # (the block)
    lea     rdi, [rsp+64]               # the name
    lea     rsi, [rip+s_pipename]
1:  movzx   eax, word ptr [rsi]
    test    eax, eax
    jz      2f
    mov     [rdi], ax
    add     rsi, 2
    add     rdi, 2
    jmp     1b
2:  call    [rip+__imp_GetCurrentProcessId]
    call    hex_w
    mov     word ptr [rdi], '-'
    add     rdi, 2
    mov     eax, 1
    lock xadd [rip+pipe_n], eax
    call    hex_w
    mov     word ptr [rdi], 0
    lea     rcx, [rsp+64]               # our end
    mov     edx, PIPE_ACCESS_INBOUND|FILE_FLAG_OVERLAPPED|FILE_FLAG_FIRST_PIPE_INSTANCE
    test    r13d, r13d
    jz      3f
    mov     edx, PIPE_ACCESS_DUPLEX|FILE_FLAG_OVERLAPPED|FILE_FLAG_FIRST_PIPE_INSTANCE
3:  mov     r8d, PIPE_REJECT_REMOTE_CLIENTS     # (bytes, waiting)
    mov     r9d, 1
    mov     dword ptr [rsp+32], PIPE_BUF_BYTES
    mov     dword ptr [rsp+40], PIPE_BUF_BYTES
    mov     dword ptr [rsp+48], 0
    mov     qword ptr [rsp+56], 0
    call    [rip+__imp_CreateNamedPipeW]
    cmp     rax, -1
    je      .Lpp_err
    mov     rbx, rax
    lea     rcx, [rsp+64]               # the other end
    mov     edx, GENERIC_WRITE
    test    r13d, r13d
    jz      4f
    mov     edx, GENERIC_READ|GENERIC_WRITE
4:  xor     r8d, r8d
    xor     r9d, r9d
    mov     qword ptr [rsp+32], OPEN_EXISTING
    mov     qword ptr [rsp+40], 0
    mov     qword ptr [rsp+48], 0
    call    [rip+__imp_CreateFileW]
    cmp     rax, -1
    je      .Lpp_err
    mov     r14, rax
    xor     ecx, ecx                    # the block
    mov     edx, PB_SIZE
    mov     r8d, MEM_COMMIT_RESERVE
    mov     r9d, PAGE_READWRITE
    call    [rip+__imp_VirtualAlloc]
    test    rax, rax
    jz      .Lpp_nomem
    mov     r15, rax
    xor     ecx, ecx                    # its events (manual reset)
    mov     edx, 1
    xor     r8d, r8d
    xor     r9d, r9d
    call    [rip+__imp_CreateEventW]
    mov     [r15+PB_OV+OV_EVENT], rax
    xor     ecx, ecx
    mov     edx, 1
    xor     r8d, r8d
    xor     r9d, r9d
    call    [rip+__imp_CreateEventW]
    mov     [r15+PB_WOV+OV_EVENT], rax
    mov     rdi, rbx                    # the fds
    mov     esi, K_PIPE
    mov     rdx, r15
    call    fd_alloc
    test    eax, eax
    js      .Lpp_out
    mov     [r12], eax
    mov     rdi, r14
    mov     esi, K_FILE
    xor     edx, edx
    call    fd_alloc
    test    eax, eax
    js      .Lpp_full
    mov     [r12+4], eax
    xor     eax, eax
    jmp     .Lpp_ret
.Lpp_full:                              # (the first fd back, then all)
    mov     [rsp+48], rax
    mov     edi, [r12]
    call    plat_close
    mov     rcx, r14
    call    [rip+__imp_CloseHandle]
    mov     rax, [rsp+48]
    jmp     .Lpp_ret
.Lpp_nomem:
    mov     rax, -ENOMEM_
    jmp     .Lpp_out
.Lpp_err:
    call    w_errno
.Lpp_out:
    mov     [rsp+48], rax               # (what to say)
    cmp     rbx, -1
    je      5f
    mov     rcx, rbx
    call    [rip+__imp_CloseHandle]
5:  cmp     r14, -1
    je      6f
    mov     rcx, r14
    call    [rip+__imp_CloseHandle]
6:  test    r15, r15
    jz      7f
    mov     rcx, [r15+PB_OV+OV_EVENT]
    call    [rip+__imp_CloseHandle]
    mov     rcx, [r15+PB_WOV+OV_EVENT]
    call    [rip+__imp_CloseHandle]
    mov     rcx, r15
    xor     edx, edx
    mov     r8d, MEM_RELEASE
    call    [rip+__imp_VirtualFree]
7:  mov     rax, [rsp+48]
.Lpp_ret:
    WLEAVE
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# hex_w(eax, rdi = where) - eax as 8 hex digits in UTF-16; rdi after them
hex_w:
    mov     ecx, 8
1:  rol     eax, 4
    mov     edx, eax
    and     edx, 15
    add     edx, '0'
    cmp     edx, '9'
    jbe     2f
    add     edx, 'a'-'9'-1
2:  mov     [rdi], dx
    add     rdi, 2
    dec     ecx
    jnz     1b
    ret

# pipe_start(rbx = a K_PIPE entry) - a read on its way into the block,
#   unless one is, data waits or the end has come; from a WENTER frame
pipe_start:
    sub     rsp, 40
    mov     rdx, [rbx+FD_AUX]
    cmp     dword ptr [rdx+PB_PEND], 0
    jne     9f
    cmp     dword ptr [rdx+PB_EOF], 0
    jne     9f
    cmp     dword ptr [rdx+PB_LEN], 0
    jne     9f
    lea     rax, [rdx+PB_OV]
    mov     [rsp+32], rax
    mov     rcx, [rbx+FD_HANDLE]
    lea     rdx, [rdx+PB_BUF]
    mov     r8d, PB_CAP
    xor     r9d, r9d
    call    [rip+__imp_ReadFile]
    test    eax, eax                    # (done at once: told as on its way)
    jnz     1f
    call    [rip+__imp_GetLastError]
    cmp     eax, ERROR_IO_PENDING
    je      1f
    mov     rdx, [rbx+FD_AUX]           # (a broken pipe: the end)
    mov     dword ptr [rdx+PB_EOF], 1
    jmp     9f
1:  mov     rdx, [rbx+FD_AUX]
    mov     dword ptr [rdx+PB_PEND], 1
9:  add     rsp, 40
    ret

# pipe_done(rbx = a K_PIPE entry, ecx = 1: wait for it) - the read on its
#   way, if it has come: its bytes into the block, or the end; from a
#   WENTER frame
pipe_done:
    sub     rsp, 56
    mov     rdx, [rbx+FD_AUX]
    cmp     dword ptr [rdx+PB_PEND], 0
    je      9f
    mov     r9d, ecx
    mov     rcx, [rbx+FD_HANDLE]
    lea     rdx, [rdx+PB_OV]
    lea     r8, [rsp+40]
    mov     dword ptr [r8], 0
    call    [rip+__imp_GetOverlappedResult]
    mov     rdx, [rbx+FD_AUX]
    test    eax, eax
    jz      2f
    mov     eax, [rsp+40]
    mov     [rdx+PB_LEN], eax
    mov     dword ptr [rdx+PB_HEAD], 0
    mov     dword ptr [rdx+PB_PEND], 0
    jmp     9f
2:  call    [rip+__imp_GetLastError]
    mov     rdx, [rbx+FD_AUX]
    cmp     eax, ERROR_IO_INCOMPLETE
    je      9f
    mov     dword ptr [rdx+PB_PEND], 0
    mov     dword ptr [rdx+PB_EOF], 1
9:  add     rsp, 56
    ret

# pipe_ready(rax = a K_PIPE entry) -> eax = 1 when data or the end is
#   there (else its read is on its way: plat_poll waits on its event); keeps
#   all but rax, rcx, r11
pipe_ready:
    push    rbx
    mov     rbx, rax
    WENTER
    mov     esi, 2                      # (a read of 0 bytes: once more)
1:  call    pipe_start
    xor     ecx, ecx
    call    pipe_done
    mov     rdx, [rbx+FD_AUX]
    mov     eax, 1
    cmp     dword ptr [rdx+PB_LEN], 0
    jne     9f
    cmp     dword ptr [rdx+PB_EOF], 0
    jne     9f
    xor     eax, eax
    cmp     dword ptr [rdx+PB_PEND], 0
    jne     9f
    dec     esi
    jnz     1b
9:  WLEAVE
    pop     rbx
    ret

# pipe_read(rax = a K_PIPE entry, rsi = bytes, rdx = how many) -> rax = how
#   many, 0 at the end, -EAGAIN when none (O_NONBLOCK) or else it waits
pipe_read:
    push    rbx
    push    r12
    push    r13
    mov     rbx, rax
    WENTER
    mov     r12, [rbx+FD_AUX]
1:  mov     eax, [r12+PB_LEN]
    test    eax, eax
    jnz     5f
    cmp     dword ptr [r12+PB_EOF], 0
    jne     4f
    call    pipe_start
    mov     ecx, [r12+PB_NONBLOCK]
    xor     ecx, 1
    call    pipe_done
    mov     eax, [r12+PB_LEN]
    test    eax, eax
    jnz     5f
    cmp     dword ptr [r12+PB_EOF], 0
    jne     4f
    cmp     dword ptr [r12+PB_PEND], 0
    je      1b                          # (0 bytes came: again)
    mov     rax, -EAGAIN_
    jmp     9f
4:  xor     eax, eax
    jmp     9f
5:  mov     r13, [rbp+SV_RDX]           # min(what waits, what is asked)
    cmp     r13, rax
    cmova   r13, rax
    mov     rdi, [rbp+SV_RSI]
    mov     eax, [r12+PB_HEAD]
    lea     rsi, [r12+PB_BUF+rax]
    mov     rcx, r13
    rep     movsb
    add     [r12+PB_HEAD], r13d
    sub     [r12+PB_LEN], r13d
    jnz     6f
    call    pipe_start                  # (the next one on its way)
6:  mov     rax, r13
9:  WLEAVE
    pop     r13
    pop     r12
    pop     rbx
    ret

# pipe_write(rax = a K_PIPE entry, rsi = bytes, rdx = how many) -> rax = how
#   many written (all: it waits for room), or -errno (-EPIPE: no reader)
pipe_write:
    push    rbx
    mov     rbx, rax
    WENTER  32
    mov     rcx, [rbx+FD_HANDLE]
    mov     r8, rdx
    mov     edx, 0x7ffff000
    cmp     r8, rdx
    cmova   r8, rdx
    mov     rdx, rsi
    xor     r9d, r9d
    mov     rax, [rbx+FD_AUX]
    lea     rax, [rax+PB_WOV]
    mov     [rsp+32], rax
    call    [rip+__imp_WriteFile]
    test    eax, eax
    jnz     1f
    call    [rip+__imp_GetLastError]
    cmp     eax, ERROR_IO_PENDING
    jne     8f
1:  mov     rcx, [rbx+FD_HANDLE]
    mov     rdx, [rbx+FD_AUX]
    lea     rdx, [rdx+PB_WOV]
    lea     r8, [rsp+48]
    mov     dword ptr [r8], 0
    mov     r9d, 1
    call    [rip+__imp_GetOverlappedResult]
    test    eax, eax
    jz      7f
    mov     eax, [rsp+48]
    jmp     9f
7:  call    [rip+__imp_GetLastError]
8:  call    w_errno_of
9:  WLEAVE
    pop     rbx
    ret

# pipe_close(rdi = a K_PIPE entry) - its read called off, its handles and
#   block gone; from a WENTER frame (rbx kept)
pipe_close:
    push    rbx
    sub     rsp, 48
    mov     rbx, rdi
    mov     rdx, [rbx+FD_AUX]
    cmp     dword ptr [rdx+PB_PEND], 0
    je      1f
    mov     rcx, [rbx+FD_HANDLE]
    lea     rdx, [rdx+PB_OV]
    call    [rip+__imp_CancelIoEx]
    mov     ecx, 1
    call    pipe_done
1:  mov     rcx, [rbx+FD_HANDLE]
    call    [rip+__imp_CloseHandle]
    mov     rdx, [rbx+FD_AUX]
    mov     rcx, [rdx+PB_OV+OV_EVENT]
    call    [rip+__imp_CloseHandle]
    mov     rdx, [rbx+FD_AUX]
    mov     rcx, [rdx+PB_WOV+OV_EVENT]
    call    [rip+__imp_CloseHandle]
    mov     rcx, [rbx+FD_AUX]
    xor     edx, edx
    mov     r8d, MEM_RELEASE
    call    [rip+__imp_VirtualFree]
    mov     rdi, rbx
    add     rsp, 48
    pop     rbx
    ret

# plat_fcntl(edi=fd, esi=cmd, rdx=arg): F_GETFL and F_SETFL's O_NONBLOCK on
#   a pipe (aiproc.s); the rest says 0 (sockets: W6b)
plat_fcntl:
    call    fd_entry
    test    rax, rax
    jz      8f
    cmp     dword ptr [rax+FD_KIND], K_PIPE
    jne     7f
    mov     rcx, [rax+FD_AUX]
    cmp     esi, F_GETFL_
    je      2f
    cmp     esi, F_SETFL_
    jne     7f
    xor     eax, eax
    test    edx, O_NONBLOCK_
    setnz   al
    mov     [rcx+PB_NONBLOCK], eax
    xor     eax, eax
    ret
2:  xor     eax, eax
    cmp     dword ptr [rcx+PB_NONBLOCK], 0
    je      3f
    mov     eax, O_NONBLOCK_
3:  ret
7:  xor     eax, eax
    ret
8:  mov     rax, -EBADF_
    ret

# plat_sendto(edi=fd, rsi=bytes, rdx=how many, r10d=flags, r8=to, r9d=its
#   size): on a pipe (video.s's frames to ffmpeg) a write; sockets: W6b
plat_sendto:
    call    fd_entry
    test    rax, rax
    jz      8f
    cmp     dword ptr [rax+FD_KIND], K_PIPE
    je      pipe_write
    cmp     dword ptr [rax+FD_KIND], K_FILE
    je      plat_write
    mov     rax, -ENOSYS_
    ret
8:  mov     rax, -EBADF_
    ret

# ---- child processes ------------------------------------------------------------
# plat_spawn(rdi=path, rsi=argv, rdx=envp, rcx=fd map, r8=working directory
#   or 0) -> rax = the child's pid, or -errno (an ordinary call, as on
#   Linux). CreateProcessW, with argv joined into a command line by the
#   rules the C runtime splits it by (win_start's), envp as a UTF-16 block,
#   and the map's fds 0..2 as the child's standard handles: each an
#   inheritable copy, and the only handles it inherits. A path without its
#   .exe finds the one with. Arguments and the environment go in Windows'
#   form of a drive's path (win_form: /C:/x as C:/x). fd 3 (the GPU helper's): W6c. The child gets no
#   console window of its own. Its process handle waits in proc_tab for
#   wait4 and kill.
plat_spawn:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    push    rbp
    mov     rbp, rsp
    and     rsp, -16
    sub     rsp, SPN_FRAME
    mov     [rsp+SPN_PATH8], rdi
    mov     r12, rsi
    mov     r13, rdx
    mov     r14, rcx
    mov     [rsp+SPN_CWD8], r8
    mov     qword ptr [rsp+SPN_DUP], 0
    mov     qword ptr [rsp+SPN_DUP+8], 0
    mov     qword ptr [rsp+SPN_DUP+16], 0
    mov     qword ptr [rsp+SPN_ALIST], 0
    xor     ecx, ecx                    # the scratch block
    mov     edx, SP_SIZE
    mov     r8d, MEM_COMMIT_RESERVE
    mov     r9d, PAGE_READWRITE
    call    [rip+__imp_VirtualAlloc]
    test    rax, rax
    jz      .Lsp_nomem
    mov     rbx, rax
    # the program: its path, or with .exe
    mov     rdi, [rsp+SPN_PATH8]
    lea     rsi, [rbx+SP_PATH]
    call    u2w_at
    test    eax, eax
    jz      .Lsp_long
    mov     r15d, eax
    lea     rcx, [rbx+SP_PATH]
    call    [rip+__imp_GetFileAttributesW]
    cmp     eax, -1
    je      1f
    test    eax, FILE_ATTRIBUTE_DIRECTORY
    jz      2f
1:  cmp     r15d, WPATH_UNITS-4
    jae     .Lsp_noent
    lea     rdi, [rbx+SP_PATH+r15*2-2]
    mov     dword ptr [rdi], 0x0065002e         # ".e"
    mov     dword ptr [rdi+4], 0x00650078       # "xe"
    mov     word ptr [rdi+8], 0
    lea     rcx, [rbx+SP_PATH]
    call    [rip+__imp_GetFileAttributesW]
    cmp     eax, -1
    je      .Lsp_noent
    test    eax, FILE_ATTRIBUTE_DIRECTORY
    jnz     .Lsp_noent
2:  # the command line, in UTF-8 first
    lea     rdi, [rbx+SP_U8]
    lea     r15, [rbx+SP_U8+SP_U8_CAP-8]
    mov     r8, r12
.Lsp_arg:
    mov     rsi, [r8]
    test    rsi, rsi
    jz      .Lsp_argend
    cmp     r8, r12
    je      3f
    mov     byte ptr [rdi], ' '
    inc     rdi
3:  mov     r10, rdi
    lea     rdi, [rbx+SP_ARG]
    push    r15
    lea     r15, [rbx+SP_ARG+SP_ARG_CAP]
    call    win_form
    pop     r15
    jc      .Lsp_long
    mov     rdi, r10
    lea     rsi, [rbx+SP_ARG]
    call    quote_arg
    jc      .Lsp_long
    add     r8, 8
    jmp     .Lsp_arg
.Lsp_argend:
    mov     byte ptr [rdi], 0
    lea     rax, [rbx+SP_U8]
    sub     rdi, rax
    lea     r9d, [rdi+1]                # (with its 0)
    mov     ecx, CP_UTF8
    xor     edx, edx
    lea     r8, [rbx+SP_U8]
    lea     rax, [rbx+SP_CMD]
    mov     [rsp+32], rax
    mov     dword ptr [rsp+40], SP_CMD_UNITS
    call    [rip+__imp_MultiByteToWideChar]
    test    eax, eax
    jz      .Lsp_long
    # the environment: "A=b" 0 ... 0, in UTF-8 first
    mov     qword ptr [rsp+SPN_ENV], 0
    test    r13, r13
    jz      5f
    lea     rdi, [rbx+SP_U8]
    mov     r8, r13
4:  mov     rsi, [r8]
    test    rsi, rsi
    jz      41f
    call    win_form
    jc      .Lsp_long
    add     r8, 8
    jmp     4b
41: mov     byte ptr [rdi], 0
    lea     rax, [rbx+SP_U8]
    cmp     rdi, rax                    # (none at all: 0 0)
    jne     43f
    mov     byte ptr [rdi+1], 0
    inc     rdi
43: sub     rdi, rax
    lea     r9d, [rdi+1]
    mov     ecx, CP_UTF8
    xor     edx, edx
    lea     r8, [rbx+SP_U8]
    lea     rax, [rbx+SP_ENVW]
    mov     [rsp+32], rax
    mov     dword ptr [rsp+40], SP_ENV_UNITS
    call    [rip+__imp_MultiByteToWideChar]
    test    eax, eax
    jz      .Lsp_long
    lea     rax, [rbx+SP_ENVW]
    mov     [rsp+SPN_ENV], rax
5:  # the working directory
    mov     qword ptr [rsp+SPN_CWDW], 0
    mov     rdi, [rsp+SPN_CWD8]
    test    rdi, rdi
    jz      6f
    lea     rsi, [rbx+SP_CWD]
    call    u2w_at
    test    eax, eax
    jz      .Lsp_long
    lea     rax, [rbx+SP_CWD]
    mov     [rsp+SPN_CWDW], rax
6:  # the child's standard handles: inheritable copies
    xor     r15d, r15d
.Lsp_h:
    mov     edi, [r14+r15*4]
    cmp     edi, PS_NULL
    je      .Lsp_null
    cmp     edi, PS_KEEP
    jne     61f
    mov     edi, r15d                   # (ours: 0..2)
61: call    fd_entry
    test    rax, rax
    jz      .Lsp_null
    mov     rdx, [rax+FD_HANDLE]
    test    rdx, rdx                    # (none: as from Explorer)
    jz      .Lsp_null
    cmp     rdx, -1
    je      .Lsp_null
    call    dup_inherit
    test    rax, rax
    jnz     .Lsp_got
.Lsp_null:
    lea     rcx, [rip+s_nul]
    mov     edx, GENERIC_READ|GENERIC_WRITE
    mov     r8d, FILE_SHARE_ALL
    lea     r9, [rip+sa_inherit]
    mov     qword ptr [rsp+32], OPEN_EXISTING
    mov     qword ptr [rsp+40], 0
    mov     qword ptr [rsp+48], 0
    call    [rip+__imp_CreateFileW]
    cmp     rax, -1
    jne     .Lsp_got
    xor     eax, eax
.Lsp_got:
    mov     [rsp+SPN_DUP+r15*8], rax
    inc     r15d
    cmp     r15d, 3
    jb      .Lsp_h
    # STARTUPINFOEXW: those handles, and the list of what it inherits
    lea     rdi, [rsp+SPN_SI]
    xor     eax, eax
    mov     ecx, SI_SIZE/8
    rep     stosq
    mov     dword ptr [rsp+SPN_SI], SI_SIZE
    mov     dword ptr [rsp+SPN_SI+SI_FLAGS], STARTF_USESTDHANDLES
    mov     rax, [rsp+SPN_DUP]
    mov     [rsp+SPN_SI+SI_STDIN], rax
    mov     rax, [rsp+SPN_DUP+8]
    mov     [rsp+SPN_SI+SI_STDOUT], rax
    mov     rax, [rsp+SPN_DUP+16]
    mov     [rsp+SPN_SI+SI_STDERR], rax
    lea     rdi, [rsp+SPN_HLIST]        # (distinct, non-zero)
    xor     r15d, r15d
    xor     ecx, ecx
7:  mov     rax, [rsp+SPN_DUP+rcx*8]
    test    rax, rax
    jz      71f
    mov     [rdi+r15*8], rax
    inc     r15d
71: inc     ecx
    cmp     ecx, 3
    jb      7b
    mov     qword ptr [rsp+SPN_ASIZE], ALIST_ROOM
    lea     rcx, [rsp+SPN_ABUF]
    mov     edx, 1
    xor     r8d, r8d
    lea     r9, [rsp+SPN_ASIZE]
    call    [rip+__imp_InitializeProcThreadAttributeList]
    test    eax, eax
    jz      8f
    lea     rcx, [rsp+SPN_ABUF]
    mov     [rsp+SPN_ALIST], rcx
    mov     [rsp+SPN_SI+SI_ALIST], rcx
    test    r15d, r15d
    jz      8f
    xor     edx, edx
    mov     r8d, PROC_THREAD_ATTRIBUTE_HANDLE_LIST
    lea     r9, [rsp+SPN_HLIST]
    lea     eax, [r15*8]
    mov     [rsp+32], rax
    mov     qword ptr [rsp+40], 0
    mov     qword ptr [rsp+48], 0
    call    [rip+__imp_UpdateProcThreadAttribute]
8:  lea     rcx, [rbx+SP_PATH]          # and off it goes
    lea     rdx, [rbx+SP_CMD]
    xor     r8d, r8d
    xor     r9d, r9d
    mov     qword ptr [rsp+32], 1
    mov     qword ptr [rsp+40], CREATE_UNICODE_ENVIRONMENT|EXTENDED_STARTUPINFO_PRESENT|CREATE_NO_WINDOW
    mov     rax, [rsp+SPN_ENV]
    mov     [rsp+48], rax
    mov     rax, [rsp+SPN_CWDW]
    mov     [rsp+56], rax
    lea     rax, [rsp+SPN_SI]
    mov     [rsp+64], rax
    lea     rax, [rsp+SPN_PI]
    mov     [rsp+72], rax
    call    [rip+__imp_CreateProcessW]
    test    eax, eax
    jnz     9f
    call    w_errno
    mov     [rsp+SPN_RES], rax
    jmp     .Lsp_clean
9:  mov     rcx, [rsp+SPN_PI+8]         # (its thread: not needed)
    call    [rip+__imp_CloseHandle]
    mov     edi, [rsp+SPN_PI+16]        # pid, its handle -> proc_tab
    mov     rsi, [rsp+SPN_PI]
    call    proc_add
    mov     eax, [rsp+SPN_PI+16]
    mov     [rsp+SPN_RES], rax
.Lsp_clean:
    xor     r15d, r15d
1:  mov     rcx, [rsp+SPN_DUP+r15*8]
    test    rcx, rcx
    jz      2f
    call    [rip+__imp_CloseHandle]
2:  inc     r15d
    cmp     r15d, 3
    jb      1b
    mov     rcx, [rsp+SPN_ALIST]
    test    rcx, rcx
    jz      3f
    call    [rip+__imp_DeleteProcThreadAttributeList]
3:  mov     rcx, rbx
    xor     edx, edx
    mov     r8d, MEM_RELEASE
    call    [rip+__imp_VirtualFree]
    mov     rax, [rsp+SPN_RES]
.Lsp_ret:
    mov     rsp, rbp
    pop     rbp
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret
.Lsp_long:
    mov     qword ptr [rsp+SPN_RES], -E2BIG_
    jmp     .Lsp_clean
.Lsp_noent:
    mov     qword ptr [rsp+SPN_RES], -ENOENT_
    jmp     .Lsp_clean
.Lsp_nomem:
    mov     rax, -ENOMEM_
    jmp     .Lsp_ret

# dup_inherit(rdx = a handle) -> rax = an inheritable copy, or 0; from an
#   aligned frame (rsp 16-byte aligned at the call)
dup_inherit:
    push    rbx
    sub     rsp, 64
    mov     rbx, rdx
    call    [rip+__imp_GetCurrentProcess]
    mov     rcx, rax
    mov     rdx, rbx
    mov     r8, rax
    lea     r9, [rsp+56]
    mov     qword ptr [r9], 0
    mov     dword ptr [rsp+32], 0
    mov     dword ptr [rsp+40], 1       # inheritable
    mov     dword ptr [rsp+48], DUPLICATE_SAME_ACCESS
    call    [rip+__imp_DuplicateHandle]
    test    eax, eax
    jz      1f
    mov     rax, [rsp+56]
1:  add     rsp, 64
    pop     rbx
    ret

# win_form(rsi = a text, rdi = where, r15 = the room's end) -> rdi after
#   its 0, CF set when it does not fit. The program's form of a drive's path
#   (/C:/x, plat_path_in) as Windows writes it, C:/x, where one starts: at
#   the start, after @ (curl's -H @file) or after = (--x=path, HOME=...).
win_form:
    xor     edx, edx                    # (the byte before: 0 at the start)
1:  cmp     rdi, r15
    jae     9f
    mov     al, [rsi]
    cmp     al, '/'
    jne     3f
    test    edx, edx
    jz      2f
    cmp     dl, '@'
    je      2f
    cmp     dl, '='
    jne     3f
2:  movzx   ecx, byte ptr [rsi+1]
    or      ecx, 0x20
    sub     ecx, 'a'
    cmp     ecx, 'z'-'a'
    ja      3f
    cmp     byte ptr [rsi+2], ':'
    jne     3f
    mov     cl, [rsi+3]
    test    cl, cl
    jz      21f
    cmp     cl, '/'
    jne     3f
21: inc     rsi                         # (the / dropped)
    mov     al, [rsi]
3:  mov     [rdi], al
    inc     rdi
    inc     rsi
    test    al, al
    jz      8f
    mov     dl, al
    jmp     1b
8:  clc
    ret
9:  stc
    ret

# quote_arg(rsi = an argument, rdi = where, r15 = the room's end) -> rdi
#   after it, CF set when it does not fit. Quoted when it is empty or has a
#   space, tab or "; inside the quotes a " gets a \, as do the \s before one
#   or before the closing quote (so the C runtime splits it back as it was).
quote_arg:
    push    rsi
    xor     ecx, ecx                    # needs quotes?
    cmp     byte ptr [rsi], 0
    je      2f
1:  mov     al, [rsi]
    test    al, al
    jz      5f                          # no: as it is
    cmp     al, ' '
    je      2f
    cmp     al, 9
    je      2f
    cmp     al, '"'
    je      2f
    inc     rsi
    jmp     1b
5:  pop     rsi
6:  lodsb
    test    al, al
    jz      8f
    cmp     rdi, r15
    jae     9f
    stosb
    jmp     6b
2:  pop     rsi
    cmp     rdi, r15
    jae     9f
    mov     byte ptr [rdi], '"'
    inc     rdi
3:  xor     edx, edx                    # \s in a row
31: mov     al, [rsi]
    cmp     al, '\\'
    jne     32f
    inc     edx
    inc     rsi
    jmp     31b
32: lea     rcx, [rdi+rdx*2+4]
    cmp     rcx, r15
    jae     9f
    mov     ecx, edx
    test    al, al
    jz      34f
    cmp     al, '"'
    jne     33f
    lea     ecx, [rdx*2+1]              # before a ": doubled, and one for it
33: test    ecx, ecx
    jz      35f
    mov     byte ptr [rdi], '\\'
    inc     rdi
    dec     ecx
    jmp     33b
35: mov     [rdi], al
    inc     rdi
    inc     rsi
    jmp     3b
34: lea     ecx, [rdx*2]                # before the closing quote: doubled
36: test    ecx, ecx
    jz      37f
    mov     byte ptr [rdi], '\\'
    inc     rdi
    dec     ecx
    jmp     36b
37: mov     byte ptr [rdi], '"'
    inc     rdi
8:  clc
    ret
9:  stc
    ret

# proc_add(edi = pid, rsi = its process handle) - into proc_tab (full:
#   the handle is closed, and wait4 will not know it)
proc_add:
    SPIN_LOCK proc_lock
    lea     rax, [rip+proc_tab]
    xor     ecx, ecx
1:  cmp     dword ptr [rax+PT_PID], 0
    je      2f
    add     rax, 16
    inc     ecx
    cmp     ecx, PROC_MAX
    jb      1b
    mov     dword ptr [rip+proc_lock], 0
    sub     rsp, 8
    WENTER
    mov     rcx, rsi
    call    [rip+__imp_CloseHandle]
    WLEAVE
    add     rsp, 8
    ret
2:  mov     [rax+PT_HANDLE], rsi
    mov     dword ptr [rax+PT_SIG], 0
    mov     [rax+PT_PID], edi
    mov     dword ptr [rip+proc_lock], 0
    ret

# proc_find(edi = pid) -> rax = its proc_tab entry, or 0; keeps all but
#   rax, rcx
proc_find:
    test    edi, edi
    jle     8f
    lea     rax, [rip+proc_tab]
    xor     ecx, ecx
1:  cmp     [rax+PT_PID], edi
    je      9f
    add     rax, 16
    inc     ecx
    cmp     ecx, PROC_MAX
    jb      1b
8:  xor     eax, eax
9:  ret

# plat_wait4(edi=pid, rsi=int status or 0, edx=options, r10=rusage) -> rax
#   = the pid when it has ended (its status as Linux gives it: the exit
#   code << 8, or the signal kill sent), 0 with WNOHANG while it runs,
#   -ECHILD when it is no child of ours
plat_wait4:
    call    proc_find
    test    rax, rax
    jz      8f
    push    rbx
    mov     rbx, rax
    WENTER  16
    mov     rcx, [rbx+PT_HANDLE]
    mov     edx, -1
    test    dword ptr [rbp+SV_RDX], 1   # WNOHANG
    jz      1f
    xor     edx, edx
1:  call    [rip+__imp_WaitForSingleObject]
    cmp     eax, WAIT_TIMEOUT
    jne     2f
    xor     eax, eax
    jmp     9f
2:  mov     rcx, [rbx+PT_HANDLE]
    lea     rdx, [rsp+32]
    mov     dword ptr [rdx], 0
    call    [rip+__imp_GetExitCodeProcess]
    mov     eax, [rsp+32]
    and     eax, 0xff
    shl     eax, 8
    mov     ecx, [rbx+PT_SIG]
    test    ecx, ecx
    jz      3f
    mov     eax, ecx
3:  mov     rsi, [rbp+SV_RSI]
    test    rsi, rsi
    jz      4f
    mov     [rsi], eax
4:  mov     rcx, [rbx+PT_HANDLE]
    call    [rip+__imp_CloseHandle]
    mov     eax, [rbx+PT_PID]
    mov     dword ptr [rbx+PT_PID], 0   # (free)
9:  WLEAVE
    pop     rbx
    ret
8:  mov     rax, -ECHILD_
    ret

# plat_kill(edi=pid, esi=signal) -> rax = 0: TERM and KILL alike end it
#   (TerminateProcess; Windows has no signals), 0 asks if it is there
plat_kill:
    call    proc_find
    test    rax, rax
    jz      8f
    test    esi, esi
    jz      7f
    push    rbx
    mov     rbx, rax
    WENTER
    mov     [rbx+PT_SIG], esi
    mov     rcx, [rbx+PT_HANDLE]
    lea     edx, [rsi+128]              # (its exit code: 128 + the signal)
    call    [rip+__imp_TerminateProcess]
    WLEAVE
    pop     rbx
7:  xor     eax, eax
    ret
8:  mov     rax, -ESRCH_
    ret

# ---- the rest: W6b (sockets; symlink, used only by mcp.s), W6c (the
#      GPU helper's shared memory and packets)
NOSYS plat_symlink
NOSYS plat_socket
NOSYS plat_connect
NOSYS plat_bind
NOSYS plat_listen
NOSYS plat_accept4
NOSYS plat_setsockopt
NOSYS plat_sendmsg
NOSYS plat_recvmsg
NOSYS plat_memfd_create
NOSYS plat_getrandom

.section .bss
.align 8
self_w:         .skip SELF_WCHARS*2     # GetModuleFileNameW's answer
.align 8
nr_tab:         .skip NR_MAX*24         # the MAP_NORESERVE allocations
nr_lock:        .skip 4
.align 8
fd_tab:         .skip FD_MAX*32
fd_lock:        .skip 4
.align 8
qpc_freq:       .skip 8                 # performance counts a second
msg_wait:       .skip 8                 # the window's wait (plat_win_msgfd)
poll_timer:     .skip 8                 # plat_poll's (high-resolution) timer
plat_win_frame_due: .skip 8             # the window's next frame (ns, 0: none)
.align 8
proc_tab:       .skip PROC_MAX*16       # children: {pid, signal sent, handle}
proc_lock:      .skip 4
pipe_n:         .skip 4                 # pipes made (their names)

.section .data
.align 8
sa_inherit:     .long 24, 0             # SECURITY_ATTRIBUTES: inheritable
                .quad 0
                .long 1, 0

.section .rodata
s_pipename:     .string16 "\\\\.\\pipe\\beemodel-"
s_nul:          .string16 "NUL"
s_bmhome:       .asciz "BEEMODEL_HOME="
plat_path_sep:  .asciz ";"              # (between PATH's directories: aiproc.s)
plat_exe_ext:   .asciz ".exe"            # (a program's file may end in it)
s_homeq:        .asciz "HOME="
s_uprof:        .asciz "USERPROFILE="
s_xdgrt:        .asciz "XDG_RUNTIME_DIR="
s_tempq:        .asciz "TEMP="
# Linux PROT_* (read 1, write 2, exec 4) -> Windows PAGE_*
prot_map:       .byte 0x01, 0x02, 0x04, 0x04, 0x10, 0x20, 0x40, 0x40
# Windows errors -> errno, {error, errno} words; others are EIO
.balign 2
err_map:
    .short 2, 2,   3, 2,   15, 2,   123, 2,   161, 2      # not found: ENOENT
    .short 5, 13,  19, 30,  32, 13,  33, 13               # EACCES, EROFS
    .short 6, 9                                           # EBADF
    .short 8, 12,  14, 12                                 # ENOMEM
    .short 17, 18                                         # EXDEV
    .short 39, 28, 112, 28                                # ENOSPC
    .short 80, 17, 183, 17                                # EEXIST
    .short 87, 22                                         # EINVAL
    .short 109, 32, 232, 32                               # EPIPE
    .short 145, 39                                        # ENOTEMPTY
    .short 206, 36                                        # ENAMETOOLONG
    .short 267, 20                                        # ENOTDIR
    .short 0

# ---- the imports (the macros: plat_win.inc) ------------------------------------
DLL 1, KERNEL32.dll
IMPORT 1, AddVectoredExceptionHandler
IMPORT 1, CancelIoEx
IMPORT 1, CloseHandle
IMPORT 1, CreateDirectoryW
IMPORT 1, CreateEventW
IMPORT 1, CreateFileMappingW
IMPORT 1, CreateFileW
IMPORT 1, CreateNamedPipeW
IMPORT 1, CreateProcessW
IMPORT 1, CreateThread
IMPORT 1, CreateWaitableTimerExW
IMPORT 1, DeleteFileW
IMPORT 1, DeleteProcThreadAttributeList
IMPORT 1, DuplicateHandle
IMPORT 1, ExitProcess
IMPORT 1, FindClose
IMPORT 1, FindFirstFileW
IMPORT 1, FindNextFileW
IMPORT 1, FreeConsole
IMPORT 1, GetActiveProcessorCount
IMPORT 1, GetCommandLineW
IMPORT 1, GetConsoleProcessList
IMPORT 1, GetCurrentProcess
IMPORT 1, GetCurrentProcessId
IMPORT 1, GetCurrentThreadId
IMPORT 1, GetDiskFreeSpaceExW
IMPORT 1, GetEnvironmentStringsW
IMPORT 1, GetExitCodeProcess
IMPORT 1, GetFileAttributesExW
IMPORT 1, GetFileAttributesW
IMPORT 1, GetFileInformationByHandle
IMPORT 1, GetLastError
IMPORT 1, GetLogicalDrives
IMPORT 1, GetModuleFileNameW
IMPORT 1, GetModuleHandleW
IMPORT 1, GetOverlappedResult
IMPORT 1, GetStdHandle
IMPORT 1, GetSystemTimePreciseAsFileTime
IMPORT 1, GlobalAlloc
IMPORT 1, GlobalFree
IMPORT 1, GlobalLock
IMPORT 1, GlobalUnlock
IMPORT 1, InitializeProcThreadAttributeList
IMPORT 1, MapViewOfFile
IMPORT 1, MoveFileExW
IMPORT 1, MultiByteToWideChar
IMPORT 1, QueryPerformanceCounter
IMPORT 1, QueryPerformanceFrequency
IMPORT 1, ReadFile
IMPORT 1, RemoveDirectoryW
IMPORT 1, ResumeThread
IMPORT 1, SetConsoleOutputCP
IMPORT 1, SetCurrentDirectoryW
IMPORT 1, SetEndOfFile
IMPORT 1, SetFilePointerEx
IMPORT 1, SetWaitableTimer
IMPORT 1, Sleep
IMPORT 1, TerminateProcess
IMPORT 1, UnmapViewOfFile
IMPORT 1, UpdateProcThreadAttribute
IMPORT 1, VirtualAlloc
IMPORT 1, VirtualFree
IMPORT 1, VirtualProtect
IMPORT 1, VirtualQuery
IMPORT 1, WaitForMultipleObjects
IMPORT 1, WaitForSingleObject
IMPORT 1, WideCharToMultiByte
IMPORT 1, WriteFile
DLL_END 1

DLL 2, api-ms-win-core-synch-l1-2-0.dll # (WaitOnAddress: not in kernel32)
IMPORT 2, WaitOnAddress
IMPORT 2, WakeByAddressAll
IMPORT 2, WakeByAddressSingle
DLL_END 2
