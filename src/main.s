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
    lea     rdi, [rip+__bss_start]      # big, mostly idle buffers: keep THP
    and     rdi, -4096                  # from backing them with 2 MiB pages
    lea     rsi, [rip+_end]
    sub     rsi, rdi
    mov     edx, MADV_NOHUGEPAGE
    mov     eax, SYS_MADVISE
    syscall
    mov     rax, [rsp]                  # argc
    lea     rax, [rsp+rax*8+16]         # envp = argv + argc + 1
    mov     [rip+envp], rax
    cmp     qword ptr [rsp], 2
    jb      1f
    mov     rbx, [rsp+16]               # argv[1]
    mov     r12, [rsp+24]               # argv[2] (0 if absent)
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
    call    mcp_init
    lea     rdi, [rip+s_log_hello]
    call    log_line
    lea     rdi, [rip+s_log_hello2]
    call    log_line

    mov     dword ptr [rip+vg_async], 1 # (the window: DAGs build in the background)
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
    lea     rdi, [rip+pollfds+16]       # + MCP listener and clients
    call    mcp_pollfds
    lea     esi, [rax+2]
    lea     rdi, [rip+pollfds]
    mov     edx, -1
    cmp     dword ptr [rip+vg_state], 1 # virtualizing: look now and then
    jne     3f
    mov     edx, 50
3:  cmp     dword ptr [rip+wp_pending], 0  # world cells waiting: look soon
    je      30f
    mov     edx, 16
30: cmp     dword ptr [rip+lb_busy], 0  # a thumbnail being made: look
    je      301f
    mov     edx, 50
301:call    vd_streaming                # cluster pages on their way: look
    test    eax, eax                    #  every frame
    jz      31f
    mov     edx, 16
31: cmp     dword ptr [rip+hv_active], 0  # rendering: just look, never wait
    je      0f
    xor     edx, edx
0:  mov     eax, SYS_POLL
    syscall
    cmp     rax, -4                     # EINTR
    je      .Lloop
    test    word ptr [rip+pollfds+6], POLLIN|POLLERR|POLLHUP
    jz      1f
    call    wl_read_dispatch
1:  test    word ptr [rip+pollfds+14], POLLIN
    jz      2f
    call    kb_on_timer
2:  lea     rdi, [rip+pollfds+16]
    call    mcp_handle
    cmp     dword ptr [rip+quit_flag], 0
    jne     .Lquit
    call    render_tick                 # a slice of the progressive render
    call    vg_tick                     # a cluster DAG built in the background
    call    vd_poll                     # cluster pages that came in: drawn
    xor     edi, edi                    # world cells in and out for the camera
    call    wp_tick
    call    lb_tick                     # library thumbnails, one at a time
    cmp     dword ptr [rip+dirty], 0
    je      .Lloop
    call    render
    jmp     .Lloop

.Lquit:
    call    mcp_shutdown
    xor     edi, edi
    mov     eax, SYS_EXIT_GROUP
    syscall

.Lmissing:
    lea     rdi, [rip+e_globals]
    call    fatal

# handle_cli_args(rbx = argv[1], r12 = argv[2])
handle_cli_args:
    mov     rdi, rbx
    lea     rsi, [rip+s_arg_eval]
    call    str_eq
    test    eax, eax
    jnz     .Lcli_eval
    mov     rdi, rbx
    lea     rsi, [rip+s_arg_run]
    call    str_eq
    test    eax, eax
    jnz     .Lcli_run
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
    lea     rsi, [rip+s_arg_bridge]
    call    str_eq
    test    eax, eax
    jnz     .Lcli_bridge
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
.Lcli_bridge:
    call    mcp_bridge
    mov     edi, eax
    mov     eax, SYS_EXIT_GROUP
    syscall
.Lcli_selftest:
    sub     rsp, 8                      # (16-byte aligned calls)
    lea     rdi, [rip+frame_arena]      # (meshes made by the tests)
    mov     esi, FRAME_ARENA_BYTES
    call    arena_init
    call    jobs_init
    call    selftest
    mov     edi, eax
    mov     eax, SYS_EXIT_GROUP
    syscall
.Lcli_eval:                             # beemodel --eval 'code'
    sub     rsp, 8
    test    r12, r12
    jz      .Lcli_need
    call    headless_init
    mov     rdi, r12
    xor     esi, esi
    call    script_eval
    jmp     .Lcli_script_out
.Lcli_run:                              # beemodel --run file.bees
    sub     rsp, 8
    test    r12, r12
    jz      .Lcli_need
    call    headless_init
    mov     rdi, r12
    call    script_run_file
.Lcli_script_out:                       # what the script printed -> stdout
    mov     r13d, eax
    mov     edi, 1
    lea     rsi, [rip+script_out]
    mov     edx, [rip+script_out_len]
    mov     eax, SYS_WRITE
    syscall
    mov     edi, r13d
    mov     eax, SYS_EXIT_GROUP
    syscall
.Lcli_need:
    lea     rdi, [rip+e_need_arg]
    call    fatal
.Lcli_list_ops:
    call    list_ops
    jmp     .Lquit
.Lcli_help:
    lea     rdi, [rip+s_help]
    call    write_out
    jmp     .Lquit

# headless_init - the scene without a window (--eval / --run)
headless_init:
    sub     rsp, 8
    call    text_init
    call    area_init
    lea     rdi, [rip+frame_arena]
    mov     esi, FRAME_ARENA_BYTES
    call    arena_init
    call    scene_init
    call    jobs_init
    add     rsp, 8
    ret

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
pollfds:        .skip 8*16              # struct pollfd: Wayland, repeat timer, MCP

.section .rodata
s_arg_version:  .asciz "--version"
s_arg_v:        .asciz "-v"
s_arg_list_ops: .asciz "--list-ops"
s_arg_selftest: .asciz "--selftest"
s_arg_bridge:   .asciz "--mcp-bridge"
s_arg_help:     .asciz "--help"
s_arg_h:        .asciz "-h"
s_arg_eval:     .asciz "--eval"
s_arg_run:      .asciz "--run"
e_need_arg:     .asciz "beemodel: --eval needs BeeScript code, --run a file\n"
s_ver_prefix:   .asciz "beemodel "
e_bad_arg:      .asciz "beemodel: unknown argument: "
s_help:         .ascii "Usage: beemodel [--version | --list-ops | --selftest | --mcp-bridge | --help]\n"
                .ascii "       beemodel --eval 'BeeScript' | --run file.bees   (no window)\n"
                .ascii "BeeModel - 3D modeling shell in pure x86-64 assembly (Wayland).\n"
                .asciz "Needs a Wayland session (WAYLAND_DISPLAY).\n"
.include "version.inc"
.text

.section .note.GNU-stack,"",@progbits
