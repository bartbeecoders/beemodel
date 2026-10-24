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
.globl plat_thread_start
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
.equ CLONE_THREAD_FLAGS, 0x50f00        # VM|FS|FILES|SIGHAND|THREAD|SYSVSEM
.equ CLONE_TID_FLAGS,   0x01200000      # CHILD_SETTID | CHILD_CLEARTID

.text

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

.section .note.GNU-stack,"",@progbits
