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
    call    plat_madvise
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
    call    prefs_load                  # ~/.config/beemodel/prefs (env wins)
    call    th_init
    call    recent_load                 # File > Open Recent
    call    area_init
    call    wsp_init                    # workspaces: the last session's, or the built-in ones
    lea     rdi, [rip+frame_arena]
    mov     rsi, FRAME_ARENA_BYTES
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
    call    clip_init                   # (the clipboard's data device)
    call    kb_timer_init
    call    mcp_init
    call    gpu_prewarm                 # (the GPU helper starts meanwhile)
    mov     rdi, [rip+link_target]      # --link host:port: mirror that session
    test    rdi, rdi
    jz      1f
    call    link_connect_arg
1:  lea     rdi, [rip+s_log_hello]
    call    log_line
    lea     rdi, [rip+s_log_hello2]
    call    log_line
    mov     rax, [rip+open_target]      # beemodel scene.bee
    test    rax, rax
    jz      2f
    push    qword ptr [rip+op_arg]
    push    rax
    mov     [rip+op_arg], rax
    lea     rdi, [rip+op_file_open]
    call    run_op
    pop     rax
    pop     qword ptr [rip+op_arg]
2:

    call    help_start                  # the welcome screen (no file opened)
    mov     dword ptr [rip+toast_on], 1 # (from now on messages are toasts)
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
    mov     [rip+n_mcpfds], eax
    lea     rdi, [rip+pollfds+16]       # + the live link's
    lea     rdi, [rdi+rax*8]
    call    link_pollfds
    add     [rip+n_mcpfds], eax
    lea     rdi, [rip+pollfds+16]       # + co-editing's
    mov     eax, [rip+n_mcpfds]
    lea     rdi, [rdi+rax*8]
    call    co_pollfds
    add     [rip+n_mcpfds], eax
    lea     rdi, [rip+pollfds+16]       # + the AI connection's child
    mov     eax, [rip+n_mcpfds]
    lea     rdi, [rdi+rax*8]
    call    ai_pollfds
    add     eax, [rip+n_mcpfds]
    lea     esi, [rax+2]
    lea     rdi, [rip+pollfds]
    mov     edx, -1
    cmp     dword ptr [rip+vg_state], 1 # virtualizing: look now and then
    jne     3f
    mov     edx, 50
3:  cmp     dword ptr [rip+wp_pending], 0  # world cells waiting: look soon
    je      30f
    mov     edx, 16
30: cmp     dword ptr [rip+pl_on], 1    # playing: every frame
    jne     302f
    mov     edx, 8
302:cmp     dword ptr [rip+lb_busy], 0  # a thumbnail being made: look
    je      301f
    mov     edx, 50
301:call    vd_streaming                # cluster pages on their way: look
    test    eax, eax                    #  every frame
    jz      31f
    mov     edx, 16
31: push    rdx                         # an AI child running: look often
    push    rsi
    call    ai_proc_running
    pop     rsi
    pop     rdx
    test    eax, eax
    jz      38f
    cmp     edx, -1
    je      39f
    cmp     edx, 50
    jle     38f
39: mov     edx, 50
38: cmp     dword ptr [rip+hv_active], 0  # rendering: just look, never wait
    jne     31f
    cmp     dword ptr [rip+lv_busy], 0  # (the live viewport's samples too)
    je      32f
31: xor     edx, edx
32: push    rdx                         # a tooltip due: wake up for it
    push    rsi
    call    tip_wait
    pop     rsi
    pop     rdx
    test    eax, eax
    js      34f
    cmp     edx, -1
    je      33f
    cmp     eax, edx
    jge     34f
33: mov     edx, eax
34: push    rdx                         # (and a view gliding: viewanim.s)
    push    rsi
    call    va_wait
    pop     rsi
    pop     rdx
    test    eax, eax
    js      341f
    cmp     edx, -1
    je      342f
    cmp     eax, edx
    jge     341f
342:mov     edx, eax
341:push    rdx                         # (and a toast to take down)
    push    rsi
    call    toast_wait
    pop     rsi
    pop     rdx
    test    eax, eax
    js      36f
    cmp     edx, -1
    je      37f
    cmp     eax, edx
    jge     36f
37: mov     edx, eax
36: push    rdx                         # (and a held pie key)
    push    rsi
    call    pie_wait
    pop     rsi
    pop     rdx
    test    eax, eax
    js      0f
    cmp     edx, -1
    je      35f
    cmp     eax, edx
    jge     0f
35: mov     edx, eax
0:  lea     rdi, [rip+pollfds]
    mov     eax, SYS_POLL
    syscall
    cmp     rax, -4                     # EINTR
    je      .Lloop
    test    word ptr [rip+pollfds+6], POLLIN|POLLERR|POLLHUP
    jz      1f
    mov     dword ptr [rip+wl_dispatching], 1   # (long jobs wait: jobui.s)
    call    wl_read_dispatch
    mov     dword ptr [rip+wl_dispatching], 0
    call    job_pending                 # a long job a key or click asked for
1:  test    word ptr [rip+pollfds+14], POLLIN
    jz      2f
    call    kb_on_timer
2:  lea     rdi, [rip+pollfds+16]
    call    mcp_handle
    call    link_tick                   # the live link: peers, changes out
    call    co_tick                     # co-editing: operations in and out
    call    ai_tick                     # the AI connection's child: its output
    cmp     dword ptr [rip+quit_flag], 0
    jne     .Lquit
    call    render_tick                 # a slice of the progressive render
    call    live_tick                   # the live viewport: more samples
    call    vg_tick                     # a cluster DAG built in the background
    call    vd_poll                     # cluster pages that came in: drawn
    xor     edi, edi                    # world cells in and out for the camera
    call    wp_tick
    call    lb_tick                     # library thumbnails, one at a time
    call    play_tick                   # play mode: the player, the scene on
    call    va_tick                     # a view gliding to its new place
    call    tip_tick                    # a tooltip whose time has come
    call    pie_tick                    # a pie key held long enough
    call    toast_tick                  # a toast whose time is up
    call    team_pending                # a button's operator, between frames
    cmp     dword ptr [rip+dirty], 0
    je      .Lloop
    call    render
    jmp     .Lloop

.Lquit:
    call    wsp_persist                 # (the layout, for next time)
    call    ai_proc_kill                # (an AI connection's child goes too)
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
    lea     rsi, [rip+s_arg_link]
    call    str_eq
    test    eax, eax
    jnz     .Lcli_link
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
    cmp     byte ptr [rbx], '-'         # beemodel scene.bee: open it in the window
    je      1f
    mov     [rip+open_target], rbx
    ret
1:  lea     rdi, [rip+e_bad_arg]
    call    write_err
    mov     rdi, rbx
    call    write_err
    lea     rdi, [rip+s_newline]
    call    fatal
.Lcli_link:                             # --link host:port: the window, mirroring
    test    r12, r12
    jz      .Lcli_need
    mov     [rip+link_target], r12
    ret
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
    mov     rsi, FRAME_ARENA_BYTES
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
    call    plat_write
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
    mov     rsi, FRAME_ARENA_BYTES
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
    call    plat_write
    ret

.section .bss
.align 8
open_target:    .skip 8                 # (beemodel scene.bee: the file to open)
.align 8
pollfds:        .skip 8*32              # struct pollfd: Wayland, repeat timer, MCP, link
n_mcpfds:       .skip 4

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
s_arg_link:     .asciz "--link"
e_need_arg:     .asciz "beemodel: --eval needs BeeScript code, --run a file, --link an address\n"
s_ver_prefix:   .asciz "beemodel "
e_bad_arg:      .asciz "beemodel: unknown argument: "
s_help:         .ascii "Usage: beemodel [scene.bee]   (open a scene in the window)\n"
                .ascii "       beemodel --version | --list-ops | --selftest | --mcp-bridge | --help\n"
                .ascii "       beemodel --eval 'BeeScript' | --run file.bees   (no window)\n"
                .ascii "       beemodel --link host:port | unix:<path>   (mirror a session's live link)\n"
                .ascii "BeeModel - 3D modeling shell in pure x86-64 assembly (Wayland).\n"
                .asciz "Needs a Wayland session (WAYLAND_DISPLAY).\n"
.include "version.inc"
.text

.section .note.GNU-stack,"",@progbits
