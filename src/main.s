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
.globl write_out
_start:
    mov     rax, [rsp]                  # argc
    lea     rax, [rsp+rax*8+16]         # envp = argv + argc + 1
    mov     [rip+envp], rax
    cmp     qword ptr [rsp], 2
    jb      1f
    mov     rbx, [rsp+16]               # argv[1]
    and     rsp, -16
    call    handle_cli_args             # --version / --help exit here
1:  and     rsp, -16

    call    text_init
    call    area_init
    lea     rdi, [rip+frame_arena]
    mov     esi, FRAME_ARENA_BYTES
    call    arena_init
    call    scene_init
    call    jobs_init
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
    call    kb_timer_init
    lea     rdi, [rip+s_log_hello]
    call    log_line
    lea     rdi, [rip+s_log_hello2]
    call    log_line

.Lloop:
    mov     edi, -1
    call    wl_flush
    # sleep until the compositor talks to us or the key-repeat timer fires
    lea     rdi, [rip+pollfds]
    mov     eax, [rip+sock_fd]
    mov     [rdi], eax
    mov     dword ptr [rdi+4], POLLIN
    mov     eax, [rip+rep_fd]
    mov     [rdi+8], eax
    mov     dword ptr [rdi+12], POLLIN
    mov     esi, 2
    mov     edx, -1
    mov     eax, SYS_POLL
    syscall
    cmp     rax, -4                     # EINTR
    je      .Lloop
    test    word ptr [rip+pollfds+6], POLLIN|POLLERR|POLLHUP
    jz      1f
    call    wl_read_dispatch
1:  test    word ptr [rip+pollfds+14], POLLIN
    jz      2f
    call    kb_on_timer
2:  cmp     dword ptr [rip+quit_flag], 0
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

# handle_cli_args(rbx = argv[1])
handle_cli_args:
    mov     rdi, rbx
    lea     rsi, [rip+s_arg_version]
    call    str_eq
    test    eax, eax
    jnz     .Lcli_version
    mov     rdi, rbx
    lea     rsi, [rip+s_arg_v]
    call    str_eq
    test    eax, eax
    jnz     .Lcli_version
    mov     rdi, rbx
    lea     rsi, [rip+s_arg_selftest]
    call    str_eq
    test    eax, eax
    jnz     .Lcli_selftest
    mov     rdi, rbx
    lea     rsi, [rip+s_arg_list_ops]
    call    str_eq
    test    eax, eax
    jnz     .Lcli_list_ops
    mov     rdi, rbx
    lea     rsi, [rip+s_arg_help]
    call    str_eq
    test    eax, eax
    jnz     .Lcli_help
    mov     rdi, rbx
    lea     rsi, [rip+s_arg_h]
    call    str_eq
    test    eax, eax
    jnz     .Lcli_help
    lea     rdi, [rip+e_bad_arg]
    call    write_err
    mov     rdi, rbx
    call    write_err
    lea     rdi, [rip+s_newline]
    call    fatal
.Lcli_version:
    lea     rdi, [rip+s_ver_prefix]
    call    write_out
    lea     rdi, [rip+s_version]
    call    write_out
    lea     rdi, [rip+s_newline]
    call    write_out
    jmp     .Lquit
.Lcli_selftest:
    call    jobs_init
    call    selftest
    mov     edi, eax
    mov     eax, SYS_EXIT_GROUP
    syscall
.Lcli_list_ops:
    call    list_ops
    jmp     .Lquit
.Lcli_help:
    lea     rdi, [rip+s_help]
    call    write_out
    jmp     .Lquit

# write_out(rdi=asciz) - write a string to stdout
write_out:
    mov     rsi, rdi
    call    str_len
    mov     edx, eax
    mov     edi, 1
    mov     eax, SYS_WRITE
    syscall
    ret

.section .bss
.align 8
pollfds:        .skip 16                # struct pollfd[2]

.section .rodata
s_arg_version:  .asciz "--version"
s_arg_v:        .asciz "-v"
s_arg_list_ops: .asciz "--list-ops"
s_arg_selftest: .asciz "--selftest"
s_arg_help:     .asciz "--help"
s_arg_h:        .asciz "-h"
s_ver_prefix:   .asciz "beemodel "
e_bad_arg:      .asciz "beemodel: unknown argument: "
s_help:         .ascii "Usage: beemodel [--version | --list-ops | --selftest | --help]\n"
                .ascii "BeeModel - 3D modeling shell in pure x86-64 assembly (Wayland).\n"
                .asciz "Needs a Wayland session (WAYLAND_DISPLAY).\n"
.include "version.inc"
.text

.section .note.GNU-stack,"",@progbits
