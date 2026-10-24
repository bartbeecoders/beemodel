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

.equ SYS_MPROTECT_, 10
.equ SYS_MREMAP_,   25
.equ SYS_MINCORE_,  27

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

.section .note.GNU-stack,"",@progbits
