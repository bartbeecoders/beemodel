# =============================================================================
#  BeeModel - the program's start on Linux. Apart from src/plat_linux.s (the
#  GPU helper links that one too, with the C runtime's own start) because
#  the kernel enters here with argc, argv and envp on the stack.
# =============================================================================
.intel_syntax noprefix
.include "const.inc"

.globl _start

.text
_start:
    lea     rdi, [rip+__bss_start]      # big, mostly idle buffers: keep THP
    and     rdi, -4096                  # from backing them with 2 MiB pages
    lea     rsi, [rip+_end]
    sub     rsi, rdi
    mov     edx, MADV_NOHUGEPAGE
    call    plat_madvise
    mov     rdi, [rsp]                  # argc
    lea     rsi, [rsp+8]                # argv
    lea     rax, [rsi+rdi*8+8]          # envp = argv + argc + 1
    mov     [rip+envp], rax
    and     rsp, -16
    call    bee_main                    # (does not return)

.section .note.GNU-stack,"",@progbits
