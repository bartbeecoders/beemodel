# =============================================================================
#  BeeModel - 3D modeling tool shell
#  Pure x86-64 Linux assembly (GNU as, Intel syntax). No libc, no libraries:
#  raw syscalls + the Wayland wire protocol over a UNIX socket.
#
#  Event loop: block in recvmsg() -> dispatch events -> redraw only when
#  something changed and the compositor asked for a new frame. Idle = 0% CPU.
# =============================================================================
.intel_syntax noprefix

.include "const.inc"

.text
.globl _start
_start:
    mov     rax, [rsp]                  # argc
    lea     rax, [rsp+rax*8+16]         # envp = argv + argc + 1
    mov     [rip+envp], rax
    and     rsp, -16

    call    wl_connect

    call    alloc_id                    # wl_display.get_registry
    mov     [rip+id_registry], eax
    mov     edx, eax
    mov     edi, 1
    mov     esi, WL_DISPLAY_GET_REGISTRY
    call    msg1
    call    wl_roundtrip                # globals arrive -> bound on the fly

    cmp     dword ptr [rip+id_compositor], 0
    je      .Lmissing
    cmp     dword ptr [rip+id_shm], 0
    je      .Lmissing
    cmp     dword ptr [rip+id_wm_base], 0
    je      .Lmissing

    call    create_window
    lea     rdi, [rip+s_log_hello]
    call    log_line
    lea     rdi, [rip+s_log_hello2]
    call    log_line

.Lloop:
    mov     edi, -1
    call    wl_flush
    call    wl_read_dispatch
    cmp     dword ptr [rip+quit_flag], 0
    jne     .Lquit
    cmp     dword ptr [rip+dirty], 0
    je      .Lloop
    call    render
    jmp     .Lloop

.Lquit:
    xor     edi, edi
    mov     eax, SYS_EXIT_GROUP
    syscall

.Lmissing:
    lea     rdi, [rip+e_globals]
    call    fatal

.include "wayland.s"
.include "draw.s"
.include "viewport.s"
.include "ui.s"

.section .rodata
.include "font.inc"

.section .note.GNU-stack,"",@progbits
