# =============================================================================
#  BeeModel - the platform layer, Linux version.
#
#  Every call into the operating system goes through a plat_* routine here
#  (the GPU helper, src/gpu/helper.s, links this file too): it is the only
#  file that holds a `syscall` instruction. src/plat_win.s will be the
#  Windows version of the same routines.
#
#  The contract is the Linux syscall's own, so a call site changes from
#  `mov eax, SYS_X` + `syscall` to `call plat_x` and nothing else:
#    in    rdi, rsi, rdx, r10, r8, r9 (the syscall's arguments, Linux flags
#          and structures: PROT_*, MAP_*, O_*, struct stat, ...)
#    out   rax = the result, or -errno (-4095..-1)
#    kept  every register but rax, rcx, r11; the flags are not kept
#  A call writes below rsp: callers must not keep data in the red zone.
#  The Windows version keeps the same contract and translates.
# =============================================================================
.intel_syntax noprefix
.include "const.inc"

.globl plat_self_path
.globl plat_path_in
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
.globl plat_fcntl
.globl plat_ftruncate
.globl plat_getdents64
.globl plat_chdir
.globl plat_rename
.globl plat_mkdir
.globl plat_rmdir
.globl plat_unlink
.globl plat_symlink
.globl plat_readlink
.globl plat_chmod
.globl plat_statfs
.globl plat_socket
.globl plat_socketpair
.globl plat_connect
.globl plat_bind
.globl plat_listen
.globl plat_accept4
.globl plat_setsockopt
.globl plat_sendto
.globl plat_sendmsg
.globl plat_recvmsg
.globl plat_poll
.globl plat_memfd_create
.globl plat_getrandom
.globl plat_exit_group
.globl plat_thread_start
.globl plat_spawn
.globl plat_pipe2
.globl plat_wait4
.globl plat_kill
.globl plat_getpid
.globl plat_futex
.globl plat_gettid
.globl plat_sched_getaffinity
.globl plat_clock_gettime
.globl plat_nanosleep
.globl plat_time
.globl plat_timerfd_create
.globl plat_timerfd_settime

.equ SYS_MPROTECT_, 10
.equ SYS_MREMAP_,   25
.equ SYS_MINCORE_,  27
.equ SYS_READ_,       0
.equ SYS_WRITE_,      1
.equ SYS_PWRITE64_,   18
.equ SYS_OPEN_,       2
.equ SYS_OPENAT_,     257
.equ SYS_CLOSE_,      3
.equ SYS_STAT_,       4
.equ SYS_FSTAT_,      5
.equ SYS_NEWFSTATAT_, 262
.equ SYS_ACCESS_,     21
.equ SYS_FCNTL_,      72
.equ SYS_FTRUNCATE_,  77
.equ SYS_GETDENTS64_, 217
.equ SYS_CHDIR_,      80
.equ SYS_RENAME_,     82
.equ SYS_MKDIR_,      83
.equ SYS_RMDIR_,      84
.equ SYS_UNLINK_,     87
.equ SYS_SYMLINK_,    88
.equ SYS_READLINK_,   89
.equ SYS_CHMOD_,      90
.equ SYS_STATFS_,     137
.equ SYS_SOCKET_,     41
.equ SYS_SOCKETPAIR_, 53
.equ SYS_CONNECT_,    42
.equ SYS_BIND_,       49
.equ SYS_LISTEN_,     50
.equ SYS_ACCEPT4_,    288
.equ SYS_SETSOCKOPT_, 54
.equ SYS_SENDTO_,     44
.equ SYS_SENDMSG_,    46
.equ SYS_RECVMSG_,    47
.equ SYS_POLL_,       7
.equ SYS_MEMFD_CREATE_, 319
.equ SYS_GETRANDOM_,  318
.equ SYS_EXIT_GROUP_, 231
.equ SYS_CLONE_,      56
.equ SYS_EXIT_,       60
.equ SYS_FUTEX_,      202
.equ SYS_GETTID_,     186
.equ SYS_SCHED_GETAFFINITY_, 204
.equ SYS_CLOCK_GETTIME_, 228
.equ SYS_NANOSLEEP_,  35
.equ SYS_TIME_,       201
.equ SYS_TIMERFD_CREATE_, 283
.equ SYS_TIMERFD_SETTIME_, 286
.equ SYS_FORK_,       57
.equ SYS_EXECVE_,     59
.equ SYS_DUP2_,       33
.equ SYS_CLOSE_RANGE_, 436
.equ SYS_PIPE2_,      293
.equ SYS_WAIT4_,      61
.equ SYS_KILL_,       62
.equ SYS_GETPID_,     39
.equ F_DUPFD_,        0
.equ O_RDWR_,         2
.equ ENOSYS_,         38
.equ CLONE_THREAD_FLAGS, 0x50f00        # VM|FS|FILES|SIGHAND|THREAD|SYSVSEM
.equ CLONE_TID_FLAGS,   0x01200000      # CHILD_SETTID | CHILD_CLEARTID

.section .rodata
s_devnull_:     .asciz "/dev/null"
s_self_:        .asciz "/proc/self/exe"

.text

# plat_path_in(rdi = a path typed in or given by the system) - into the
#   program's form, in place; on Linux it is in it already (Windows turns
#   \ into / and C:/x into /C:/x)
plat_path_in:
    ret

# plat_self_path(rdi=buffer, esi=its size) -> rax = the length of this
#   program's path, written there 0-ended (0: not known). An ordinary call.
plat_self_path:
    push    rbx
    mov     rbx, rdi
    mov     edx, esi
    dec     edx
    mov     rsi, rdi
    lea     rdi, [rip+s_self_]
    mov     eax, SYS_READLINK_
    syscall
    test    rax, rax
    jns     1f
    xor     eax, eax
1:  mov     byte ptr [rbx+rax], 0
    pop     rbx
    ret

# ---- memory -----------------------------------------------------------------
plat_mmap:
    mov     eax, SYS_MMAP
    syscall
    ret

plat_munmap:
    mov     eax, SYS_MUNMAP
    syscall
    ret

plat_mprotect:
    mov     eax, SYS_MPROTECT_
    syscall
    ret

plat_mremap:
    mov     eax, SYS_MREMAP_
    syscall
    ret

plat_mincore:
    mov     eax, SYS_MINCORE_
    syscall
    ret

plat_madvise:
    mov     eax, SYS_MADVISE
    syscall
    ret

# ---- files and directories --------------------------------------------------
plat_read:
    mov     eax, SYS_READ_
    syscall
    ret

plat_write:
    mov     eax, SYS_WRITE_
    syscall
    ret

plat_pwrite64:
    mov     eax, SYS_PWRITE64_
    syscall
    ret

plat_open:
    mov     eax, SYS_OPEN_
    syscall
    ret

plat_openat:
    mov     eax, SYS_OPENAT_
    syscall
    ret

plat_close:
    mov     eax, SYS_CLOSE_
    syscall
    ret

plat_stat:
    mov     eax, SYS_STAT_
    syscall
    ret

plat_fstat:
    mov     eax, SYS_FSTAT_
    syscall
    ret

plat_newfstatat:
    mov     eax, SYS_NEWFSTATAT_
    syscall
    ret

plat_access:
    mov     eax, SYS_ACCESS_
    syscall
    ret

plat_fcntl:
    mov     eax, SYS_FCNTL_
    syscall
    ret

plat_ftruncate:
    mov     eax, SYS_FTRUNCATE_
    syscall
    ret

plat_getdents64:
    mov     eax, SYS_GETDENTS64_
    syscall
    ret

plat_chdir:
    mov     eax, SYS_CHDIR_
    syscall
    ret

plat_rename:
    mov     eax, SYS_RENAME_
    syscall
    ret

plat_mkdir:
    mov     eax, SYS_MKDIR_
    syscall
    ret

plat_rmdir:
    mov     eax, SYS_RMDIR_
    syscall
    ret

plat_unlink:
    mov     eax, SYS_UNLINK_
    syscall
    ret

plat_symlink:
    mov     eax, SYS_SYMLINK_
    syscall
    ret

plat_readlink:
    mov     eax, SYS_READLINK_
    syscall
    ret

plat_chmod:
    mov     eax, SYS_CHMOD_
    syscall
    ret

plat_statfs:
    mov     eax, SYS_STATFS_
    syscall
    ret

# ---- child processes --------------------------------------------------------
# plat_spawn(rdi=path, rsi=argv, rdx=envp, rcx=fd map, r8=working directory
#   or 0) -> rax = the child's pid, or -errno. Not the syscall contract: an
#   ordinary call. The map is four dwords, what the child gets on fds 0..3:
#   one of our fds, PS_KEEP (0..2: ours as they are, 3: nothing) or PS_NULL.
#   The child gets no other fd of ours. A child that cannot run the program
#   exits with 127.
plat_spawn:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    sub     rsp, 32
    mov     [rsp+16], rdi               # path
    mov     r12, rsi
    mov     r13, rdx
    mov     r14, rcx
    mov     r15, r8
    mov     eax, SYS_FORK_
    syscall
    test    rax, rax
    jnz     9f
    # ---- the child: each fd it gets first goes to a free fd above 3, so
    #  that putting one in place cannot overwrite another's source
    xor     ebx, ebx
1:  mov     edi, [r14+rbx*4]
    cmp     edi, PS_NULL
    jne     2f
    lea     rdi, [rip+s_devnull_]
    mov     esi, O_RDWR_
    xor     edx, edx
    mov     eax, SYS_OPEN_
    syscall
    mov     edi, eax
2:  test    edi, edi
    js      3f
    mov     esi, F_DUPFD_
    mov     edx, 4
    mov     eax, SYS_FCNTL_
    syscall
    mov     edi, eax
3:  mov     [rsp+rbx*4], edi            # its stand-in (negative: none)
    inc     ebx
    cmp     ebx, 4
    jb      1b
    xor     ebx, ebx                    # into place (dup2 drops CLOEXEC)
4:  mov     edi, [rsp+rbx*4]
    test    edi, edi
    js      5f
    mov     esi, ebx
    mov     eax, SYS_DUP2_
    syscall
5:  inc     ebx
    cmp     ebx, 4
    jb      4b
    mov     ebx, 4                      # nothing else of ours (3 too, when
    cmp     dword ptr [rsp+12], 0       #  it gets nothing there)
    jge     6f
    mov     ebx, 3
6:  mov     edi, ebx
    mov     esi, -1
    xor     edx, edx
    mov     eax, SYS_CLOSE_RANGE_
    syscall
    cmp     eax, -ENOSYS_               # (before Linux 5.9: one at a time)
    jne     8f
7:  mov     edi, ebx
    mov     eax, SYS_CLOSE_
    syscall
    inc     ebx
    cmp     ebx, 1024
    jb      7b
8:  test    r15, r15
    jz      81f
    mov     rdi, r15
    mov     eax, SYS_CHDIR_
    syscall
81: mov     rdi, [rsp+16]
    mov     rsi, r12
    mov     rdx, r13
    mov     eax, SYS_EXECVE_
    syscall
    mov     edi, 127
    mov     eax, SYS_EXIT_
    syscall
9:  add     rsp, 32
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

plat_pipe2:
    mov     eax, SYS_PIPE2_
    syscall
    ret

plat_wait4:
    mov     eax, SYS_WAIT4_
    syscall
    ret

plat_kill:
    mov     eax, SYS_KILL_
    syscall
    ret

plat_getpid:
    mov     eax, SYS_GETPID_
    syscall
    ret

# ---- threads and time ---------------------------------------------------------
# plat_thread_start(rdi=entry, rsi=arg, rdx=stack top, rcx=tid word or 0)
#   -> eax = the new thread's id, or -errno. Not the syscall contract: an
#   ordinary call (rax, rcx, rdx, rsi, rdi, r8-r11 are not kept). The thread
#   runs entry(rdi=arg) on the given stack, entered with rsp 16-byte aligned
#   before the call (as parallel_for's jobs expect), and ends when entry
#   returns. A tid word gets the thread's id, and 0 and a futex wake when
#   the thread has ended.
plat_thread_start:
    sub     rdx, 16
    mov     [rdx], rdi
    mov     [rdx+8], rsi
    mov     rsi, rdx
    mov     edi, CLONE_THREAD_FLAGS
    xor     edx, edx
    xor     r10d, r10d
    test    rcx, rcx
    jz      1f
    or      edi, CLONE_TID_FLAGS
    mov     r10, rcx
1:  xor     r8d, r8d
    mov     eax, SYS_CLONE_
    syscall
    test    eax, eax
    jnz     2f
    pop     rax                         # child: entry
    pop     rdi                         #        arg
    and     rsp, -16
    call    rax
    xor     edi, edi
    mov     eax, SYS_EXIT_
    syscall
2:  ret

plat_futex:
    mov     eax, SYS_FUTEX_
    syscall
    ret

plat_gettid:
    mov     eax, SYS_GETTID_
    syscall
    ret

plat_sched_getaffinity:
    mov     eax, SYS_SCHED_GETAFFINITY_
    syscall
    ret

plat_clock_gettime:
    mov     eax, SYS_CLOCK_GETTIME_
    syscall
    ret

plat_nanosleep:
    mov     eax, SYS_NANOSLEEP_
    syscall
    ret

plat_time:
    mov     eax, SYS_TIME_
    syscall
    ret

plat_timerfd_create:
    mov     eax, SYS_TIMERFD_CREATE_
    syscall
    ret

plat_timerfd_settime:
    mov     eax, SYS_TIMERFD_SETTIME_
    syscall
    ret

# ---- sockets, shared memory, waiting, the end ---------------------------------
plat_socket:
    mov     eax, SYS_SOCKET_
    syscall
    ret

plat_socketpair:
    mov     eax, SYS_SOCKETPAIR_
    syscall
    ret

plat_connect:
    mov     eax, SYS_CONNECT_
    syscall
    ret

plat_bind:
    mov     eax, SYS_BIND_
    syscall
    ret

plat_listen:
    mov     eax, SYS_LISTEN_
    syscall
    ret

plat_accept4:
    mov     eax, SYS_ACCEPT4_
    syscall
    ret

plat_setsockopt:
    mov     eax, SYS_SETSOCKOPT_
    syscall
    ret

plat_sendto:
    mov     eax, SYS_SENDTO_
    syscall
    ret

plat_sendmsg:
    mov     eax, SYS_SENDMSG_
    syscall
    ret

plat_recvmsg:
    mov     eax, SYS_RECVMSG_
    syscall
    ret

plat_poll:
    mov     eax, SYS_POLL_
    syscall
    ret

plat_memfd_create:
    mov     eax, SYS_MEMFD_CREATE_
    syscall
    ret

plat_getrandom:
    mov     eax, SYS_GETRANDOM_
    syscall
    ret

plat_exit_group:
    mov     eax, SYS_EXIT_GROUP_
    syscall
    ret

.section .note.GNU-stack,"",@progbits
