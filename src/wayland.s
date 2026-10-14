# =============================================================================
#  BeeModel - Wayland wire protocol, written directly against the socket.
#
#  Message = [object id:u32][size<<16 | opcode:u32][args...], all little-endian,
#  strings = u32 length (incl. NUL) + bytes padded to 4. File descriptors travel
#  as SCM_RIGHTS ancillary data. No libwayland - everything is hand rolled.
# =============================================================================
.intel_syntax noprefix
.include "const.inc"

# exports
.globl write_err
.globl in_pressure
.globl in_eraser
.globl in_pen
.globl fr_ns
.globl fr_count
.globl fr_work
.globl fr_wk
.globl getenv
.globl sock_fd
.globl alloc_id
.globl create_window
.globl dirty
.globl wl_lock_pointer
.globl wl_unlock_pointer
.globl e_globals
.globl envp
.globl fatal
.globl id_compositor
.globl id_registry
.globl id_seat
.globl id_shm
.globl id_toplevel
.globl id_wm_base
.globl msg0
.globl msg1
.globl msg2
.globl msg3
.globl pool_size
.globl quit_flag
.globl render
.globl s_newline
.globl set_cursor
.globl str_eq
.globl win_flags
.globl win_h
.globl win_w
.globl wl_connect
.globl wl_flush
.globl wl_read_dispatch
.globl wl_roundtrip
.globl write_err

.section .data
.align 4
next_id:        .long 2                 # 1 is always wl_display
in_pressure:    .float 1.0              # the pen's pressure 0..1 (mouse: 1)

.section .bss
.align 64
.equ FR_RING, 256
fr_ns:          .skip FR_RING*8         # the last frames' drawing times
fr_count:       .skip 4                 # frames drawn
.align 8
fr_wk:          .skip FR_RING*8         # their input work (sculpt strokes)
fr_work:        .skip 8                 # (since the last frame)
.align 8
fr_t0:          .skip 8
sbuf:           .skip SBUF_SIZE
rbuf:           .skip RBUF_SIZE
rctl:           .skip 256
sctl:           .skip 24
.align 8
envp:           .skip 8
smsg:           .skip 56                # struct msghdr (send)
siov:           .skip 16                # struct iovec  (send)
rmsg:           .skip 56                # struct msghdr (recv)
riov:           .skip 16
sock_addr:      .skip 112               # struct sockaddr_un
slen:           .skip 4
msg_start:      .skip 4
rlen:           .skip 4
sock_fd:        .skip 4
fdq:            .skip 64
fdq_n:          .skip 4

# protocol object ids (0 = not created)
id_registry:    .skip 4
id_compositor:  .skip 4
id_shm:         .skip 4
id_wm_base:     .skip 4
id_seat:        .skip 4
id_cursor_mgr:  .skip 4
id_constraints: .skip 4                 # zwp_pointer_constraints_v1
id_relmgr:      .skip 4                 # zwp_relative_pointer_manager_v1
id_locked:      .skip 4                 # (play mode: the locked pointer,
id_relptr:      .skip 4                 #  its relative motion)
id_surface:     .skip 4
id_xdg_surface: .skip 4
id_toplevel:    .skip 4
id_pointer:     .skip 4
id_keyboard:    .skip 4
id_cursor_dev:  .skip 4
id_pool:        .skip 4
id_buf:         .skip 8                 # two wl_buffers (double buffering)
id_frame_cb:    .skip 4
id_sync_cb:     .skip 4
id_tab_mgr:     .skip 4                 # zwp_tablet_manager_v2
id_tab_seat:    .skip 4
tab_tool:       .skip TAB_TOOLS*4       # the tools the seat has (ids)
tab_type:       .skip TAB_TOOLS*4       # their types (0x140 pen, 0x141 eraser)
tab_cdev:       .skip TAB_TOOLS*4       # their cursor-shape devices
tab_x:          .skip 4                 # the frame being collected
tab_y:          .skip 4
tab_ev:         .skip 4                 # 1 moved, 2 down, 4 up
tab_serial:     .skip 4
in_eraser:      .skip 4                 # 1: the pen's eraser end
in_pen:         .skip 4                 # 1: a tablet tool was seen
sync_done:      .skip 4

# window state
win_w:          .skip 4
phys_w:         .skip 4
phys_h:         .skip 4
id_fscale_mgr:  .skip 4
id_viewporter:  .skip 4
id_fscale:      .skip 4
id_viewport:    .skip 4
win_h:          .skip 4
pend_w:         .skip 4
pend_h:         .skip 4
pend_flags:     .skip 4
win_flags:      .skip 4                 # bit0 maximized, bit1 tiled/fullscreen
configured:     .skip 4
dirty:          .skip 4
frame_pending:  .skip 4
quit_flag:      .skip 4

# shm
shm_fd:         .skip 4
pool_size:      .skip 4
buf_w:          .skip 4
buf_h:          .skip 4
buf_busy:       .skip 8
.align 8
pool_ptr:       .skip 8

.section .rodata
.align 4
tool_ops:                               # zwp_tablet_tool_v2 events
    .long .Ltl_type - tool_ops, ev_done - tool_ops, ev_done - tool_ops
    .long ev_done - tool_ops, ev_done - tool_ops, .Ltl_removed - tool_ops
    .long .Ltl_in - tool_ops, .Ltl_out - tool_ops, .Ltl_down - tool_ops
    .long .Ltl_up - tool_ops, .Ltl_motion - tool_ops, .Ltl_pressure - tool_ops
    .long ev_done - tool_ops, ev_done - tool_ops, ev_done - tool_ops
    .long ev_done - tool_ops, ev_done - tool_ops, .Ltl_button - tool_ops
    .long .Ltl_frame - tool_ops
tab_pmax:       .float 65535.0
sf_one_w:       .float 1.0
s_env_wd:       .asciz "WAYLAND_DISPLAY="
s_env_xdg:      .asciz "XDG_RUNTIME_DIR="
s_wayland0:     .asciz "wayland-0"
s_compositor:   .asciz "wl_compositor"
s_shm:          .asciz "wl_shm"
s_wm_base:      .asciz "xdg_wm_base"
s_seat:         .asciz "wl_seat"
s_cursor_mgr:   .asciz "wp_cursor_shape_manager_v1"
s_constraints:  .asciz "zwp_pointer_constraints_v1"
.align 4
sf_fix:         .float 0.00390625       # (24.8 fixed point)
s_relmgr:       .asciz "zwp_relative_pointer_manager_v1"
s_fscale_mgr:   .asciz "wp_fractional_scale_manager_v1"
s_viewporter:   .asciz "wp_viewporter"
s_tab_mgr:      .asciz "zwp_tablet_manager_v2"
s_memfd_name:   .asciz "beemodel-fb"
e_connect:      .asciz "beemodel: cannot connect to the Wayland display\n"
e_lost:         .asciz "beemodel: Wayland connection lost\n"
e_globals:      .asciz "beemodel: compositor lacks wl_compositor / wl_shm / xdg_wm_base\n"
e_shm:          .asciz "beemodel: shared memory allocation failed\n"
e_proto:        .asciz "beemodel: protocol error: "
s_newline:      .asciz "\n"

.text

# -----------------------------------------------------------------------------
# write_err(rdi=asciz) - write a string to stderr
# -----------------------------------------------------------------------------
write_err:
    mov     rsi, rdi
    xor     edx, edx
1:  cmp     byte ptr [rsi+rdx], 0
    je      2f
    inc     edx
    jmp     1b
2:  mov     edi, 2
    mov     eax, SYS_WRITE
    syscall
    ret

# fatal(rdi=asciz) - print and exit(1)
fatal:
    call    write_err
    mov     edi, 1
    mov     eax, SYS_EXIT_GROUP
    syscall

# -----------------------------------------------------------------------------
# getenv(rdi="NAME=") -> rax = value pointer or 0
# -----------------------------------------------------------------------------
getenv:
    mov     r8, [rip+envp]
1:  mov     rsi, [r8]
    test    rsi, rsi
    jz      4f
    xor     ecx, ecx
2:  mov     al, [rdi+rcx]
    test    al, al
    jz      3f                          # whole prefix matched
    cmp     al, [rsi+rcx]
    jne     5f
    inc     ecx
    jmp     2b
3:  lea     rax, [rsi+rcx]
    ret
5:  add     r8, 8
    jmp     1b
4:  xor     eax, eax
    ret

# -----------------------------------------------------------------------------
# str_eq(rdi, rsi) -> eax = 1 if equal
# -----------------------------------------------------------------------------
str_eq:
    xor     ecx, ecx
1:  mov     al, [rdi+rcx]
    cmp     al, [rsi+rcx]
    jne     2f
    test    al, al
    jz      3f
    inc     ecx
    jmp     1b
2:  xor     eax, eax
    ret
3:  mov     eax, 1
    ret

# -----------------------------------------------------------------------------
# wl_connect - open the compositor socket
# -----------------------------------------------------------------------------
wl_connect:
    push    rbx
    push    r12
    lea     rbx, [rip+sock_addr]
    mov     word ptr [rbx], AF_UNIX
    lea     r12, [rbx+2]                # write cursor into sun_path

    lea     rdi, [rip+s_env_wd]
    call    getenv
    test    rax, rax
    jnz     1f
    lea     rax, [rip+s_wayland0]
1:  push    rax
    cmp     byte ptr [rax], '/'         # absolute socket path?
    je      3f
    lea     rdi, [rip+s_env_xdg]
    call    getenv
    test    rax, rax
    jz      9f
2:  mov     cl, [rax]                   # copy XDG_RUNTIME_DIR
    test    cl, cl
    jz      21f
    mov     [r12], cl
    inc     r12
    inc     rax
    jmp     2b
21: mov     byte ptr [r12], '/'
    inc     r12
3:  pop     rax
4:  mov     cl, [rax]                   # append display name
    mov     [r12], cl
    inc     r12
    inc     rax
    test    cl, cl
    jnz     4b

    mov     edi, AF_UNIX
    mov     esi, SOCK_STREAM_CLOEXEC
    xor     edx, edx
    mov     eax, SYS_SOCKET
    syscall
    test    eax, eax
    js      9f
    mov     [rip+sock_fd], eax
    mov     edi, eax
    mov     rsi, rbx
    mov     edx, 110
    mov     eax, SYS_CONNECT
    syscall
    test    eax, eax
    jnz     9f
    pop     r12
    pop     rbx
    ret
9:  lea     rdi, [rip+e_connect]
    call    fatal

# -----------------------------------------------------------------------------
# Message building
# -----------------------------------------------------------------------------
alloc_id:
    mov     eax, [rip+next_id]
    inc     dword ptr [rip+next_id]
    ret

# msg_begin(edi=object, esi=opcode)
msg_begin:
    mov     eax, [rip+slen]
    cmp     eax, SBUF_FLUSH_AT
    jb      1f
    push    rdi
    push    rsi
    mov     edi, -1
    call    wl_flush
    pop     rsi
    pop     rdi
    mov     eax, [rip+slen]
1:  mov     [rip+msg_start], eax
    lea     rcx, [rip+sbuf]
    mov     [rcx+rax], edi
    mov     [rcx+rax+4], esi
    add     eax, 8
    mov     [rip+slen], eax
    ret

# put_u32(edi)
put_u32:
    mov     eax, [rip+slen]
    lea     rcx, [rip+sbuf]
    mov     [rcx+rax], edi
    add     eax, 4
    mov     [rip+slen], eax
    ret

# put_str(rdi=asciz)
put_str:
    xor     ecx, ecx
1:  cmp     byte ptr [rdi+rcx], 0
    je      2f
    inc     ecx
    jmp     1b
2:  inc     ecx                         # include NUL
    mov     eax, [rip+slen]
    lea     rdx, [rip+sbuf]
    mov     [rdx+rax], ecx
    add     eax, 4
    lea     r8, [rdx+rax]
    xor     r9d, r9d
3:  mov     r10b, [rdi+r9]
    mov     [r8+r9], r10b
    inc     r9d
    cmp     r9d, ecx
    jb      3b
    add     ecx, 3
    and     ecx, -4
4:  cmp     r9d, ecx
    jae     5f
    mov     byte ptr [r8+r9], 0
    inc     r9d
    jmp     4b
5:  add     eax, ecx
    mov     [rip+slen], eax
    ret

msg_end:
    mov     eax, [rip+slen]
    mov     ecx, [rip+msg_start]
    mov     edx, eax
    sub     edx, ecx
    shl     edx, 16
    lea     r8, [rip+sbuf]
    or      [r8+rcx+4], edx
    ret

# Convenience: send a message with 0..3 u32 args.
# msg0(edi=obj, esi=op)
msg0:
    call    msg_begin
    jmp     msg_end
# msg1(edi=obj, esi=op, edx=a)
msg1:
    push    rdx
    call    msg_begin
    pop     rdi
    call    put_u32
    jmp     msg_end
# msg2(edi=obj, esi=op, edx=a, ecx=b)
msg2:
    push    rcx
    push    rdx
    call    msg_begin
    pop     rdi
    call    put_u32
    pop     rdi
    call    put_u32
    jmp     msg_end
# msg3(edi=obj, esi=op, edx=a, ecx=b, r8d=c)
msg3:
    push    r8
    push    rcx
    push    rdx
    call    msg_begin
    pop     rdi
    call    put_u32
    pop     rdi
    call    put_u32
    pop     rdi
    call    put_u32
    jmp     msg_end

# -----------------------------------------------------------------------------
# wl_flush(edi = fd to pass or -1)
# -----------------------------------------------------------------------------
wl_flush:
    push    rbx
    mov     ebx, edi
1:  mov     eax, [rip+slen]
    test    eax, eax
    jz      9f
    lea     rsi, [rip+smsg]
    lea     rcx, [rip+siov]
    lea     rdx, [rip+sbuf]
    mov     [rcx], rdx
    mov     [rcx+8], rax
    mov     qword ptr [rsi], 0
    mov     qword ptr [rsi+8], 0
    mov     [rsi+16], rcx
    mov     qword ptr [rsi+24], 1
    mov     qword ptr [rsi+32], 0
    mov     qword ptr [rsi+40], 0
    mov     qword ptr [rsi+48], 0
    test    ebx, ebx
    js      2f
    lea     rdx, [rip+sctl]
    mov     qword ptr [rdx], 20         # cmsg_len = CMSG_LEN(4)
    mov     dword ptr [rdx+8], SOL_SOCKET
    mov     dword ptr [rdx+12], SCM_RIGHTS
    mov     [rdx+16], ebx
    mov     [rsi+32], rdx
    mov     qword ptr [rsi+40], 24      # CMSG_SPACE(4)
2:  mov     edi, [rip+sock_fd]
    mov     edx, MSG_NOSIGNAL
    mov     eax, SYS_SENDMSG
    syscall
    cmp     rax, -4                     # EINTR -> retry
    je      1b
    cmp     rax, -11                    # EAGAIN -> retry
    je      1b
    test    rax, rax
    js      8f
    mov     ebx, -1                     # fd went out with the first chunk
    mov     ecx, [rip+slen]
    sub     ecx, eax                    # bytes left
    mov     [rip+slen], ecx
    jz      9f
    lea     rdi, [rip+sbuf]             # shift the unsent tail down
    lea     rsi, [rdi+rax]
    rep     movsb
    jmp     1b
9:  pop     rbx
    ret
8:  lea     rdi, [rip+e_lost]
    call    fatal

# -----------------------------------------------------------------------------
# wl_read_dispatch - block for one recvmsg and dispatch all complete messages
# -----------------------------------------------------------------------------
wl_read_dispatch:
    push    rbx
    push    r12
    push    r13
1:  lea     rsi, [rip+rmsg]
    lea     rcx, [rip+riov]
    lea     rdx, [rip+rbuf]
    mov     eax, [rip+rlen]
    add     rdx, rax
    mov     [rcx], rdx
    mov     edx, RBUF_SIZE
    sub     edx, eax
    mov     [rcx+8], rdx
    mov     qword ptr [rsi], 0
    mov     qword ptr [rsi+8], 0
    mov     [rsi+16], rcx
    mov     qword ptr [rsi+24], 1
    lea     rdx, [rip+rctl]
    mov     [rsi+32], rdx
    mov     qword ptr [rsi+40], 256
    mov     qword ptr [rsi+48], 0
    mov     edi, [rip+sock_fd]
    mov     edx, MSG_CMSG_CLOEXEC
    mov     eax, SYS_RECVMSG
    syscall
    cmp     rax, -4
    je      1b
    test    rax, rax
    jle     8f
    add     [rip+rlen], eax

    # Queue the fds we were handed; the message that owns them (only
    # wl_keyboard.keymap today) pops them in order, as libwayland does.
    lea     r12, [rip+rctl]
    mov     r13, [rip+rmsg+40]
    add     r13, r12                    # end of control data
2:  lea     rax, [r12+16]
    cmp     rax, r13
    ja      5f
    mov     rbx, [r12]                  # cmsg_len
    cmp     rbx, 16
    jb      5f
    cmp     dword ptr [r12+8], SOL_SOCKET
    jne     4f
    cmp     dword ptr [r12+12], SCM_RIGHTS
    jne     4f
    lea     rcx, [rbx-16]
    shr     rcx, 2
    lea     rdx, [r12+16]
3:  test    rcx, rcx
    jz      4f
    push    rcx
    push    rdx
    mov     edi, [rdx]
    call    fdq_push
    pop     rdx
    pop     rcx
    add     rdx, 4
    dec     rcx
    jmp     3b
4:  add     rbx, 7
    and     rbx, -8
    add     r12, rbx
    jmp     2b

5:  # parse messages
    xor     ebx, ebx                    # offset
6:  mov     eax, [rip+rlen]
    sub     eax, ebx
    cmp     eax, 8
    jb      7f
    lea     r12, [rip+rbuf]
    add     r12, rbx
    mov     r13d, [r12+4]
    shr     r13d, 16                    # size
    cmp     r13d, 8
    jb      8f
    cmp     r13d, eax
    ja      7f                          # incomplete
    mov     edi, [r12]
    movzx   esi, word ptr [r12+4]
    lea     rdx, [r12+8]
    lea     ecx, [r13-8]
    call    wl_dispatch
    add     ebx, r13d
    jmp     6b
7:  # move leftover partial message to the front
    mov     ecx, [rip+rlen]
    sub     ecx, ebx
    mov     [rip+rlen], ecx
    jz      9f
    lea     rdi, [rip+rbuf]
    lea     rsi, [rdi+rbx]
    rep     movsb
9:  pop     r13
    pop     r12
    pop     rbx
    ret
8:  lea     rdi, [rip+e_lost]
    call    fatal

# fdq_push(edi=fd) - queue a received fd (oldest is closed if the queue is full)
fdq_push:
    mov     eax, [rip+fdq_n]
    cmp     eax, 16
    jb      1f
    push    rdi
    mov     edi, [rip+fdq]
    mov     eax, SYS_CLOSE
    syscall
    call    fdq_pop_raw
    pop     rdi
    mov     eax, [rip+fdq_n]
1:  lea     rcx, [rip+fdq]
    mov     [rcx+rax*4], edi
    inc     dword ptr [rip+fdq_n]
    ret

# fdq_pop -> eax = oldest queued fd or -1
fdq_pop:
    mov     eax, -1
    cmp     dword ptr [rip+fdq_n], 0
    je      1f
    mov     eax, [rip+fdq]
fdq_pop_raw:
    push    rax
    lea     rcx, [rip+fdq]
    xor     edx, edx
2:  lea     r8d, [rdx+1]
    cmp     r8d, [rip+fdq_n]
    jae     3f
    mov     r9d, [rcx+r8*4]
    mov     [rcx+rdx*4], r9d
    inc     edx
    jmp     2b
3:  dec     dword ptr [rip+fdq_n]
    pop     rax
1:  ret

# -----------------------------------------------------------------------------
# wl_roundtrip - wl_display.sync and wait for its done event
# -----------------------------------------------------------------------------
wl_roundtrip:
    call    alloc_id
    mov     [rip+id_sync_cb], eax
    mov     dword ptr [rip+sync_done], 0
    mov     edx, eax
    mov     edi, 1
    mov     esi, WL_DISPLAY_SYNC
    call    msg1
1:  mov     edi, -1
    call    wl_flush
    call    wl_read_dispatch
    cmp     dword ptr [rip+sync_done], 0
    je      1b
    ret

# -----------------------------------------------------------------------------
# bind(edi=global name, rsi=interface, edx=version) -> eax = new id
# -----------------------------------------------------------------------------
wl_bind:
    push    rbx
    push    r12
    push    r13
    push    r14
    mov     r12d, edi
    mov     r13, rsi
    mov     r14d, edx
    call    alloc_id
    mov     ebx, eax
    mov     edi, [rip+id_registry]
    mov     esi, WL_REGISTRY_BIND
    call    msg_begin
    mov     edi, r12d
    call    put_u32
    mov     rdi, r13
    call    put_str
    mov     edi, r14d
    call    put_u32
    mov     edi, ebx
    call    put_u32
    call    msg_end
    mov     eax, ebx
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# -----------------------------------------------------------------------------
# wl_dispatch(edi=object, esi=opcode, rdx=payload, ecx=payload size)
# -----------------------------------------------------------------------------
wl_dispatch:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    mov     r12, rdx                    # payload
    mov     r13d, esi                   # opcode

    cmp     edi, 1
    je      ev_display
    cmp     edi, [rip+id_registry]
    je      ev_registry
    cmp     edi, [rip+id_pointer]
    je      ev_pointer
    cmp     edi, [rip+id_frame_cb]
    je      ev_frame_done
    cmp     edi, [rip+id_buf]
    je      ev_buf0
    cmp     edi, [rip+id_buf+4]
    je      ev_buf1
    cmp     edi, [rip+id_keyboard]
    je      ev_keyboard
    cmp     edi, [rip+id_wm_base]
    je      ev_wm_base
    cmp     edi, [rip+id_xdg_surface]
    je      ev_xdg_surface
    cmp     edi, [rip+id_toplevel]
    je      ev_toplevel
    cmp     edi, [rip+id_seat]
    je      ev_seat
    cmp     edi, [rip+id_sync_cb]
    je      ev_sync_done
    cmp     edi, [rip+id_fscale]
    je      ev_fscale
    cmp     edi, [rip+id_tab_seat]
    je      ev_tab_seat
    cmp     dword ptr [rip+id_relptr], 0
    je      0f
    cmp     edi, [rip+id_relptr]
    je      ev_relptr
0:
    cmp     edi, 0xff000000             # objects the compositor made: tools
    jb      ev_done
    lea     r15, [rip+tab_tool]
    xor     ebx, ebx
1:  cmp     edi, [r15+rbx*4]
    je      ev_tool
    inc     ebx
    cmp     ebx, TAB_TOOLS
    jb      1b
ev_done:
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

ev_display:
    test    r13d, r13d
    jnz     ev_done                     # delete_id: ids are never reused
    lea     rdi, [rip+e_proto]
    call    write_err
    lea     rdi, [r12+12]               # error message string
    call    write_err
    lea     rdi, [rip+s_newline]
    call    fatal

ev_registry:
    test    r13d, r13d
    jnz     ev_done                     # global_remove: ignored
    mov     r14d, [r12]                 # global name
    mov     ecx, [r12+4]
    add     ecx, 3
    and     ecx, -4
    mov     r15d, [r12+8+rcx]           # advertised version
    lea     rbx, [r12+8]                # interface string

    mov     rdi, rbx
    lea     rsi, [rip+s_compositor]
    call    str_eq
    test    eax, eax
    jz      1f
    mov     edx, 4
    cmp     r15d, edx
    cmovb   edx, r15d
    lea     rsi, [rip+s_compositor]
    mov     edi, r14d
    call    wl_bind
    mov     [rip+id_compositor], eax
    jmp     ev_done
1:  mov     rdi, rbx
    lea     rsi, [rip+s_shm]
    call    str_eq
    test    eax, eax
    jz      2f
    mov     edx, 1
    lea     rsi, [rip+s_shm]
    mov     edi, r14d
    call    wl_bind
    mov     [rip+id_shm], eax
    jmp     ev_done
2:  mov     rdi, rbx
    lea     rsi, [rip+s_wm_base]
    call    str_eq
    test    eax, eax
    jz      3f
    mov     edx, 2
    cmp     r15d, edx
    cmovb   edx, r15d
    lea     rsi, [rip+s_wm_base]
    mov     edi, r14d
    call    wl_bind
    mov     [rip+id_wm_base], eax
    jmp     ev_done
3:  cmp     dword ptr [rip+id_seat], 0  # first seat only
    jne     4f
    mov     rdi, rbx
    lea     rsi, [rip+s_seat]
    call    str_eq
    test    eax, eax
    jz      4f
    mov     edx, 5
    cmp     r15d, edx
    cmovb   edx, r15d
    lea     rsi, [rip+s_seat]
    mov     edi, r14d
    call    wl_bind
    mov     [rip+id_seat], eax
    call    tab_seat
    jmp     ev_done
4:  mov     rdi, rbx
    lea     rsi, [rip+s_fscale_mgr]
    call    str_eq
    test    eax, eax
    jz      41f
    mov     edx, 1
    lea     rsi, [rip+s_fscale_mgr]
    mov     edi, r14d
    call    wl_bind
    mov     [rip+id_fscale_mgr], eax
    jmp     ev_done
41: mov     rdi, rbx
    lea     rsi, [rip+s_viewporter]
    call    str_eq
    test    eax, eax
    jz      42f
    mov     edx, 1
    lea     rsi, [rip+s_viewporter]
    mov     edi, r14d
    call    wl_bind
    mov     [rip+id_viewporter], eax
    jmp     ev_done
42: mov     rdi, rbx
    lea     rsi, [rip+s_tab_mgr]
    call    str_eq
    test    eax, eax
    jz      43f
    mov     edx, 1
    lea     rsi, [rip+s_tab_mgr]
    mov     edi, r14d
    call    wl_bind
    mov     [rip+id_tab_mgr], eax
    call    tab_seat
    jmp     ev_done
43: mov     rdi, rbx
    lea     rsi, [rip+s_constraints]
    call    str_eq
    test    eax, eax
    jz      44f
    mov     edx, 1
    lea     rsi, [rip+s_constraints]
    mov     edi, r14d
    call    wl_bind
    mov     [rip+id_constraints], eax
    jmp     ev_done
44: mov     rdi, rbx
    lea     rsi, [rip+s_relmgr]
    call    str_eq
    test    eax, eax
    jz      45f
    mov     edx, 1
    lea     rsi, [rip+s_relmgr]
    mov     edi, r14d
    call    wl_bind
    mov     [rip+id_relmgr], eax
    jmp     ev_done
45: mov     rdi, rbx
    lea     rsi, [rip+s_cursor_mgr]
    call    str_eq
    test    eax, eax
    jz      ev_done
    mov     edx, 1
    lea     rsi, [rip+s_cursor_mgr]
    mov     edi, r14d
    call    wl_bind
    mov     [rip+id_cursor_mgr], eax
    jmp     ev_done

ev_fscale:                              # preferred_scale(scale / 120)
    mov     edi, [r12]
    call    set_ui_scale
    test    eax, eax
    jz      ev_done
    mov     edi, FONT_UI                # re-rasterize fonts for the new scale
    mov     esi, UI_FONT_PX
    call    font_set_size
    mov     edi, FONT_MONO
    mov     esi, MONO_FONT_PX
    call    font_set_size
    mov     dword ptr [rip+dirty], 1
    jmp     ev_done

ev_sync_done:
    mov     dword ptr [rip+sync_done], 1
    jmp     ev_done

ev_frame_done:
    mov     dword ptr [rip+frame_pending], 0
    mov     dword ptr [rip+id_frame_cb], 0
    jmp     ev_done

ev_buf0:
    mov     dword ptr [rip+buf_busy], 0
    jmp     ev_done
ev_buf1:
    mov     dword ptr [rip+buf_busy+4], 0
    jmp     ev_done

ev_wm_base:                             # ping -> pong
    mov     edi, [rip+id_wm_base]
    mov     esi, XDG_WM_BASE_PONG
    mov     edx, [r12]
    call    msg1
    jmp     ev_done

ev_xdg_surface:                         # configure(serial)
    mov     edi, [rip+id_xdg_surface]
    mov     esi, XDG_SURFACE_ACK_CONFIGURE
    mov     edx, [r12]
    call    msg1
    mov     eax, [rip+pend_w]
    test    eax, eax
    jnz     1f
    mov     eax, [rip+win_w]
    test    eax, eax
    jnz     1f
    mov     eax, DEF_W
1:  mov     [rip+win_w], eax
    mov     eax, [rip+pend_h]
    test    eax, eax
    jnz     2f
    mov     eax, [rip+win_h]
    test    eax, eax
    jnz     2f
    mov     eax, DEF_H
2:  mov     [rip+win_h], eax
    mov     eax, [rip+pend_flags]
    mov     [rip+win_flags], eax
    mov     dword ptr [rip+configured], 1
    mov     dword ptr [rip+dirty], 1
    jmp     ev_done

ev_toplevel:
    cmp     r13d, 1
    je      ev_close
    test    r13d, r13d
    jnz     ev_done
    mov     eax, [r12]
    mov     [rip+pend_w], eax
    mov     eax, [r12+4]
    mov     [rip+pend_h], eax
    mov     ecx, [r12+8]                # states array byte length
    shr     ecx, 2
    lea     rsi, [r12+12]
    xor     edx, edx
1:  test    ecx, ecx
    jz      3f
    mov     eax, [rsi]
    cmp     eax, 1                      # maximized
    jne     2f
    or      edx, 1
2:  cmp     eax, 2                      # fullscreen
    je      21f
    cmp     eax, 5                      # tiled_left..tiled_bottom (5..8)
    jb      22f
    cmp     eax, 8
    ja      22f
21: or      edx, 2
22: add     rsi, 4
    dec     ecx
    jmp     1b
3:  mov     [rip+pend_flags], edx
    jmp     ev_done
ev_close:
    mov     dword ptr [rip+quit_flag], 1
    jmp     ev_done

ev_seat:
    test    r13d, r13d
    jnz     ev_done                     # 'name' event ignored
    mov     ebx, [r12]                  # capabilities
    test    ebx, 1
    jz      1f
    cmp     dword ptr [rip+id_pointer], 0
    jne     1f
    call    alloc_id
    mov     [rip+id_pointer], eax
    mov     edx, eax
    mov     edi, [rip+id_seat]
    mov     esi, WL_SEAT_GET_POINTER
    call    msg1
    cmp     dword ptr [rip+id_cursor_mgr], 0
    je      1f
    call    alloc_id
    mov     [rip+id_cursor_dev], eax
    mov     edx, eax
    mov     ecx, [rip+id_pointer]
    mov     edi, [rip+id_cursor_mgr]
    mov     esi, CURSOR_MGR_GET_POINTER
    call    msg2
1:  test    ebx, 2
    jz      ev_done
    cmp     dword ptr [rip+id_keyboard], 0
    jne     ev_done
    call    alloc_id
    mov     [rip+id_keyboard], eax
    mov     edx, eax
    mov     edi, [rip+id_seat]
    mov     esi, WL_SEAT_GET_KEYBOARD
    call    msg1
    jmp     ev_done

ev_pointer:
    cmp     r13d, 0
    je      10f
    cmp     r13d, 1
    je      11f
    cmp     r13d, 2
    je      12f
    cmp     r13d, 3
    je      13f
    cmp     r13d, 4
    je      14f
    jmp     ev_done
10: mov     eax, [r12]                  # enter(serial, surface, x, y)
    mov     [rip+enter_serial], eax
    mov     dword ptr [rip+cur_shape], 0
    mov     edi, [r12+8]
    sar     edi, 8
    mov     esi, [r12+12]
    sar     esi, 8
    call    ui_motion
    jmp     ev_done
11: call    ui_leave
    jmp     ev_done
12: call    mouse_input
    mov     edi, [r12+4]                # motion(time, x, y)
    sar     edi, 8
    mov     esi, [r12+8]
    sar     esi, 8
    call    ui_motion
    jmp     ev_done
13: call    mouse_input
    mov     edi, [r12+8]                # button(serial, time, button, state)
    mov     esi, [r12+12]
    mov     edx, [r12]
    mov     ecx, [r12+4]
    call    ui_button
    jmp     ev_done
14: mov     edi, [r12+4]                # axis(time, axis, value)
    mov     esi, [r12+8]
    call    ui_axis
    jmp     ev_done

# tablets (zwp_tablet_v2): tools come and go on the tablet seat; a tool's
#   events are collected until its frame, then given to the UI as pointer
#   motion and the left button (stylus buttons: middle and right), with
#   in_pressure and in_eraser set for the brushes
ev_tab_seat:
    cmp     r13d, 1                     # tool_added(id)
    jne     ev_done
    lea     r15, [rip+tab_tool]         # (tab_type, tab_cdev follow)
    xor     ebx, ebx
1:  cmp     dword ptr [r15+rbx*4], 0
    je      2f
    inc     ebx
    cmp     ebx, TAB_TOOLS
    jb      1b
    jmp     ev_done                     # (no room: ignored)
2:  mov     eax, [r12]
    mov     [r15+rbx*4], eax
    mov     dword ptr [r15+rbx*4+TAB_TOOLS*4], TOOL_PEN
    mov     dword ptr [r15+rbx*4+TAB_TOOLS*8], 0
    cmp     dword ptr [rip+id_cursor_mgr], 0
    je      ev_done
    call    alloc_id
    mov     [r15+rbx*4+TAB_TOOLS*8], eax
    mov     edx, eax
    mov     ecx, [r15+rbx*4]
    mov     edi, [rip+id_cursor_mgr]
    mov     esi, CURSOR_MGR_GET_TABLET_TOOL
    call    msg2
    jmp     ev_done

ev_tool:                                # ebx = the tool's slot
    cmp     r13d, 18
    ja      ev_done
    lea     rax, [rip+tool_ops]
    movsxd  rcx, dword ptr [rax+r13*4]
    add     rax, rcx
    jmp     rax
.Ltl_type:
    mov     eax, [r12]
    mov     [r15+rbx*4+TAB_TOOLS*4], eax
    jmp     ev_done
.Ltl_removed:
    mov     dword ptr [r15+rbx*4], 0
    jmp     ev_done
.Ltl_in:                                # proximity_in(serial, tablet, surface)
    mov     dword ptr [rip+in_pen], 1
    xor     eax, eax
    cmp     dword ptr [r15+rbx*4+TAB_TOOLS*4], TOOL_ERASER
    sete    al
    mov     [rip+in_eraser], eax
    mov     edi, [r15+rbx*4+TAB_TOOLS*8]   # the same cursor as the mouse's
    test    edi, edi
    jz      ev_done
    mov     edx, [r12]
    mov     ecx, [rip+cur_shape]
    test    ecx, ecx
    jnz     1f
    mov     ecx, 1
1:  mov     esi, CURSOR_DEV_SET_SHAPE
    call    msg2
    jmp     ev_done
.Ltl_out:
    mov     dword ptr [rip+in_eraser], 0
    jmp     ev_done
.Ltl_down:
    mov     eax, [r12]
    mov     [rip+tab_serial], eax
    or      dword ptr [rip+tab_ev], 2
    jmp     ev_done
.Ltl_up:
    or      dword ptr [rip+tab_ev], 4
    jmp     ev_done
.Ltl_motion:                            # motion(x, y) (fixed 24.8)
    mov     eax, [r12]
    sar     eax, 8
    mov     [rip+tab_x], eax
    mov     eax, [r12+4]
    sar     eax, 8
    mov     [rip+tab_y], eax
    or      dword ptr [rip+tab_ev], 1
    jmp     ev_done
.Ltl_pressure:                          # pressure(0..65535)
    cvtsi2ss xmm0, dword ptr [r12]
    divss   xmm0, [rip+tab_pmax]
    movss   [rip+in_pressure], xmm0
    jmp     ev_done
.Ltl_button:                            # button(serial, button, state)
    mov     edi, BTN_MIDDLE
    cmp     dword ptr [r12+4], BTN_STYLUS
    je      1f
    mov     edi, BTN_RIGHT
    cmp     dword ptr [r12+4], BTN_STYLUS2
    jne     ev_done
1:  mov     esi, [r12+8]
    mov     edx, [r12]
    xor     ecx, ecx
    call    ui_button
    jmp     ev_done
.Ltl_frame:                             # frame(time): what was collected
    mov     r14d, [r12]
    mov     ebx, [rip+tab_ev]
    mov     dword ptr [rip+tab_ev], 0
    test    ebx, 1
    jz      1f
    mov     edi, [rip+tab_x]
    mov     esi, [rip+tab_y]
    call    ui_motion
1:  test    ebx, 2
    jz      2f
    mov     edi, BTN_LEFT
    mov     esi, 1
    mov     edx, [rip+tab_serial]
    mov     ecx, r14d
    call    ui_button
2:  test    ebx, 4
    jz      ev_done
    mov     edi, BTN_LEFT
    xor     esi, esi
    mov     edx, [rip+tab_serial]
    mov     ecx, r14d
    call    ui_button
    jmp     ev_done

# ev_relptr - relative_motion(utime hi, lo, dx, dy, dx unaccelerated, dy
#   unaccelerated): play mode turns the view (unaccelerated, 24.8 fixed)
ev_relptr:
    test    r13d, r13d
    jnz     ev_done
    cvtsi2ss xmm0, dword ptr [r12+16]
    cvtsi2ss xmm1, dword ptr [r12+20]
    mulss   xmm0, [rip+sf_fix]
    mulss   xmm1, [rip+sf_fix]
    call    play_look
    jmp     ev_done

# wl_lock_pointer -> eax = 1 when the pointer is locked in the window, its
#   cursor hidden and its relative motion coming (the compositor has both)
wl_lock_pointer:
    xor     eax, eax
    cmp     dword ptr [rip+id_constraints], 0
    je      9f
    cmp     dword ptr [rip+id_relmgr], 0
    je      9f
    cmp     dword ptr [rip+id_pointer], 0
    je      9f
    cmp     dword ptr [rip+id_locked], 0
    jne     8f
    push    rbx
    call    alloc_id                    # lock_pointer(id, surface, pointer,
    mov     [rip+id_locked], eax        #  region none, persistent)
    mov     edi, [rip+id_constraints]
    mov     esi, 1
    call    msg_begin
    mov     edi, [rip+id_locked]
    call    put_u32
    mov     edi, [rip+id_surface]
    call    put_u32
    mov     edi, [rip+id_pointer]
    call    put_u32
    xor     edi, edi
    call    put_u32
    mov     edi, 2
    call    put_u32
    call    msg_end
    call    alloc_id                    # get_relative_pointer(id, pointer)
    mov     [rip+id_relptr], eax
    mov     edx, eax
    mov     ecx, [rip+id_pointer]
    mov     edi, [rip+id_relmgr]
    mov     esi, 1
    call    msg2
    mov     edi, [rip+id_pointer]       # no cursor: set_cursor(serial, none)
    xor     esi, esi
    call    msg_begin
    mov     edi, [rip+enter_serial]
    call    put_u32
    xor     edi, edi
    call    put_u32
    xor     edi, edi
    call    put_u32
    xor     edi, edi
    call    put_u32
    call    msg_end
    mov     dword ptr [rip+cur_shape], -1
    pop     rbx
8:  mov     eax, 1
9:  ret

# wl_unlock_pointer - the pointer free again (its cursor back on the next move)
wl_unlock_pointer:
    cmp     dword ptr [rip+id_locked], 0
    je      9f
    mov     edi, [rip+id_locked]
    xor     esi, esi
    call    msg0
    mov     edi, [rip+id_relptr]
    xor     esi, esi
    call    msg0
    mov     dword ptr [rip+id_locked], 0
    mov     dword ptr [rip+id_relptr], 0
    mov     dword ptr [rip+cur_shape], -1
9:  ret

# tab_seat - once there are a seat and a tablet manager: the tablet seat
tab_seat:
    cmp     dword ptr [rip+id_tab_seat], 0
    jne     1f
    cmp     dword ptr [rip+id_tab_mgr], 0
    je      1f
    cmp     dword ptr [rip+id_seat], 0
    je      1f
    call    alloc_id
    mov     [rip+id_tab_seat], eax
    mov     edx, eax
    mov     ecx, [rip+id_seat]
    mov     edi, [rip+id_tab_mgr]
    mov     esi, TAB_MGR_GET_SEAT
    call    msg2
1:  ret

# mouse_input - a pointer event: full pressure, no eraser
mouse_input:
    mov     eax, [rip+sf_one_w]
    mov     [rip+in_pressure], eax
    mov     dword ptr [rip+in_eraser], 0
    ret

ev_keyboard:
    cmp     r13d, 3
    je      1f
    test    r13d, r13d
    je      2f
    cmp     r13d, 2
    je      3f
    cmp     r13d, 5
    je      4f
    cmp     r13d, 4
    jne     ev_done
    mov     eax, [r12+4]                # modifiers(serial, depressed, latched, locked, group)
    mov     [rip+key_mods], eax
    mov     eax, [r12+8]
    mov     [rip+mods_latched], eax
    mov     eax, [r12+12]
    mov     [rip+mods_locked], eax
    jmp     ev_done
2:  call    fdq_pop                     # keymap(format, fd, size)
    mov     esi, eax
    test    esi, esi
    js      ev_done
    mov     edi, [r12]
    mov     edx, [r12+4]
    call    kb_keymap
    jmp     ev_done
3:  call    kb_repeat_stop              # leave
    jmp     ev_done
4:  mov     eax, [r12]                  # repeat_info(rate, delay)
    mov     [rip+rep_rate], eax
    mov     eax, [r12+4]
    mov     [rip+rep_delay], eax
    jmp     ev_done
1:  mov     edi, [r12+8]                # key(serial, time, key, state)
    mov     esi, [r12+12]
    call    ui_key
    jmp     ev_done

# -----------------------------------------------------------------------------
# create_window - wl_surface + xdg_surface + xdg_toplevel
# -----------------------------------------------------------------------------
create_window:
    call    alloc_id
    mov     [rip+id_surface], eax
    mov     edx, eax
    mov     edi, [rip+id_compositor]
    mov     esi, WL_COMPOSITOR_CREATE_SURFACE
    call    msg1

    cmp     dword ptr [rip+id_fscale_mgr], 0
    je      1f
    cmp     dword ptr [rip+id_viewporter], 0
    je      1f
    call    alloc_id
    mov     [rip+id_fscale], eax
    mov     edx, eax
    mov     ecx, [rip+id_surface]
    mov     edi, [rip+id_fscale_mgr]
    mov     esi, WP_FSCALE_MGR_GET
    call    msg2
    call    alloc_id
    mov     [rip+id_viewport], eax
    mov     edx, eax
    mov     ecx, [rip+id_surface]
    mov     edi, [rip+id_viewporter]
    mov     esi, WP_VIEWPORTER_GET
    call    msg2
1:  call    alloc_id
    mov     [rip+id_xdg_surface], eax
    mov     edx, eax
    mov     ecx, [rip+id_surface]
    mov     edi, [rip+id_wm_base]
    mov     esi, XDG_WM_BASE_GET_XDG_SURFACE
    call    msg2

    call    alloc_id
    mov     [rip+id_toplevel], eax
    mov     edx, eax
    mov     edi, [rip+id_xdg_surface]
    mov     esi, XDG_SURFACE_GET_TOPLEVEL
    call    msg1

    mov     edi, [rip+id_toplevel]
    mov     esi, XDG_TOPLEVEL_SET_TITLE
    call    msg_begin
    lea     rdi, [rip+s_app_title]
    call    put_str
    call    msg_end

    mov     edi, [rip+id_toplevel]
    mov     esi, XDG_TOPLEVEL_SET_APP_ID
    call    msg_begin
    lea     rdi, [rip+s_app_id]
    call    put_str
    call    msg_end

    mov     edi, [rip+id_toplevel]
    mov     esi, XDG_TOPLEVEL_SET_MIN_SIZE
    mov     edx, MIN_W
    mov     ecx, MIN_H
    call    msg2

    mov     edi, [rip+id_surface]
    mov     esi, WL_SURFACE_COMMIT
    jmp     msg0

# -----------------------------------------------------------------------------
# ensure_buffers - (re)create the two wl_buffers for win_w x win_h
# -----------------------------------------------------------------------------
ensure_buffers:
    push    rbx
    push    r12
    push    r13
    mov     eax, [rip+phys_w]
    cmp     eax, [rip+buf_w]
    jne     1f
    mov     eax, [rip+phys_h]
    cmp     eax, [rip+buf_h]
    jne     1f
    cmp     dword ptr [rip+id_buf], 0
    jne     9f
1:  # destroy the old buffers
    mov     edi, [rip+id_buf]
    test    edi, edi
    jz      2f
    mov     esi, WL_BUFFER_DESTROY
    call    msg0
    mov     edi, [rip+id_buf+4]
    mov     esi, WL_BUFFER_DESTROY
    call    msg0
2:  mov     r12d, [rip+phys_w]
    shl     r12d, 2                     # stride
    mov     r13d, r12d
    imul    r13d, [rip+phys_h]           # bytes per buffer
    lea     ebx, [r13+r13]              # bytes needed for both
    cmp     ebx, [rip+pool_size]
    jbe     5f

    # grow: round up, ftruncate, remap
    add     ebx, POOL_ROUND-1
    and     ebx, -POOL_ROUND
    cmp     dword ptr [rip+shm_fd], 0
    jne     3f
    lea     rdi, [rip+s_memfd_name]
    mov     esi, MFD_CLOEXEC
    mov     eax, SYS_MEMFD_CREATE
    syscall
    test    eax, eax
    js      8f
    mov     [rip+shm_fd], eax
3:  mov     edi, [rip+shm_fd]
    mov     esi, ebx
    mov     eax, SYS_FTRUNCATE
    syscall
    test    eax, eax
    jnz     8f
    mov     rdi, [rip+pool_ptr]
    test    rdi, rdi
    jz      4f
    mov     esi, [rip+pool_size]
    mov     eax, SYS_MUNMAP
    syscall
4:  xor     edi, edi
    mov     esi, ebx
    mov     edx, PROT_RW
    mov     r10d, MAP_SHARED
    mov     r8d, [rip+shm_fd]
    xor     r9d, r9d
    mov     eax, SYS_MMAP
    syscall
    cmp     rax, -4096
    ja      8f
    mov     [rip+pool_ptr], rax
    mov     [rip+pool_size], ebx
    cmp     dword ptr [rip+id_pool], 0
    jne     41f
    call    alloc_id
    mov     [rip+id_pool], eax
    mov     edx, eax
    mov     edi, [rip+id_shm]
    mov     esi, WL_SHM_CREATE_POOL
    call    msg_begin
    mov     edi, [rip+id_pool]
    call    put_u32
    mov     edi, ebx
    call    put_u32
    call    msg_end
    mov     edi, [rip+shm_fd]           # the fd rides along with this message
    call    wl_flush
    jmp     6f
41: mov     edi, [rip+id_pool]
    mov     esi, WL_SHM_POOL_RESIZE
    mov     edx, ebx
    call    msg1
    jmp     6f

5:  # shrinking: give the unused tail of the pool back to the kernel
    mov     eax, [rip+pool_size]
    add     ebx, 4095
    and     ebx, -4096
    sub     eax, ebx
    cmp     eax, 0x400000               # only bother for >= 4 MiB
    jb      6f
    mov     rdi, [rip+pool_ptr]
    add     rdi, rbx
    mov     esi, eax
    mov     edx, MADV_REMOVE
    mov     eax, SYS_MADVISE
    syscall

6:  # two buffers: offsets 0 and r13
    xor     ebx, ebx
7:  call    alloc_id
    lea     rcx, [rip+id_buf]
    mov     [rcx+rbx*4], eax
    lea     rcx, [rip+buf_busy]
    mov     dword ptr [rcx+rbx*4], 0
    mov     edi, [rip+id_pool]
    mov     esi, WL_SHM_POOL_CREATE_BUFFER
    push    rax
    call    msg_begin
    pop     rdi
    call    put_u32                     # new_id
    mov     edi, r13d
    imul    edi, ebx
    call    put_u32                     # offset
    mov     edi, [rip+phys_w]
    call    put_u32
    mov     edi, [rip+phys_h]
    call    put_u32
    mov     edi, r12d
    call    put_u32                     # stride
    mov     edi, WL_SHM_FORMAT_XRGB8888
    call    put_u32
    call    msg_end
    inc     ebx
    cmp     ebx, 2
    jb      7b
    mov     eax, [rip+phys_w]
    mov     [rip+buf_w], eax
    mov     eax, [rip+phys_h]
    mov     [rip+buf_h], eax
9:  pop     r13
    pop     r12
    pop     rbx
    ret
8:  lea     rdi, [rip+e_shm]
    call    fatal

# -----------------------------------------------------------------------------
# render - draw the whole UI into a free buffer and commit it
# -----------------------------------------------------------------------------
render:
    cmp     dword ptr [rip+configured], 0
    je      9f
    cmp     dword ptr [rip+frame_pending], 0
    jne     9f                          # wait for the compositor's frame callback
    push    rbx
    lea     rdi, [rip+frame_arena]
    call    arena_reset
    mov     edi, [rip+win_w]            # buffer is physical: logical x scale
    call    to_px
    mov     [rip+phys_w], eax
    mov     edi, [rip+win_h]
    call    to_px
    mov     [rip+phys_h], eax
    call    ensure_buffers
    xor     ebx, ebx
    cmp     dword ptr [rip+buf_busy], 0
    je      1f
    inc     ebx
    cmp     dword ptr [rip+buf_busy+4], 0
    jne     8f                          # both busy: retry on release
1:  mov     eax, [rip+phys_w]
    mov     [rip+fb_w], eax
    mov     ecx, [rip+phys_h]
    mov     [rip+fb_h], ecx
    imul    eax, ecx
    shl     rax, 2
    imul    rax, rbx
    add     rax, [rip+pool_ptr]
    mov     [rip+fb_ptr], rax
    call    mono_ns
    mov     [rip+fr_t0], rax
    call    ui_draw
    call    mono_ns                     # how long it took (frametime())
    sub     rax, [rip+fr_t0]
    mov     ecx, [rip+fr_count]
    and     ecx, FR_RING-1
    lea     rdx, [rip+fr_ns]
    mov     [rdx+rcx*8], rax
    mov     rax, [rip+fr_work]
    lea     rdx, [rip+fr_wk]
    mov     [rdx+rcx*8], rax
    mov     qword ptr [rip+fr_work], 0
    inc     dword ptr [rip+fr_count]

    lea     rcx, [rip+buf_busy]
    mov     dword ptr [rcx+rbx*4], 1
    lea     rcx, [rip+id_buf]
    mov     edx, [rcx+rbx*4]
    mov     edi, [rip+id_surface]
    mov     esi, WL_SURFACE_ATTACH
    xor     ecx, ecx
    xor     r8d, r8d
    call    msg3
    mov     edi, [rip+id_viewport]      # map the buffer onto the logical size
    test    edi, edi
    jz      1f
    mov     esi, WP_VIEWPORT_SET_DESTINATION
    mov     edx, [rip+win_w]
    mov     ecx, [rip+win_h]
    call    msg2
1:  mov     edi, [rip+id_surface]
    mov     esi, WL_SURFACE_DAMAGE
    call    msg_begin
    xor     edi, edi
    call    put_u32
    xor     edi, edi
    call    put_u32
    mov     edi, [rip+win_w]
    call    put_u32
    mov     edi, [rip+win_h]
    call    put_u32
    call    msg_end
    call    alloc_id
    mov     [rip+id_frame_cb], eax
    mov     edx, eax
    mov     edi, [rip+id_surface]
    mov     esi, WL_SURFACE_FRAME
    call    msg1
    mov     edi, [rip+id_surface]
    mov     esi, WL_SURFACE_COMMIT
    call    msg0
    mov     dword ptr [rip+frame_pending], 1
    mov     dword ptr [rip+dirty], 0
    mov     eax, [rip+an_play]          # playing: the next frame too
    or      [rip+dirty], eax
8:  pop     rbx
9:  ret

# mono_ns -> rax = monotonic clock, nanoseconds
.globl mono_ns
mono_ns:
    sub     rsp, 24
    mov     edi, 1                      # CLOCK_MONOTONIC
    mov     rsi, rsp
    mov     eax, 228                    # clock_gettime
    syscall
    mov     rax, [rsp]
    imul    rax, rax, 1000000000
    add     rax, [rsp+8]
    add     rsp, 24
    ret

# -----------------------------------------------------------------------------
# set_cursor(edi = cursor-shape-v1 shape) - only sends when it changes
# -----------------------------------------------------------------------------
set_cursor:
    cmp     edi, [rip+cur_shape]
    je      9f
    cmp     dword ptr [rip+id_cursor_dev], 0
    je      9f
    mov     [rip+cur_shape], edi
    mov     ecx, edi
    mov     edx, [rip+enter_serial]
    mov     edi, [rip+id_cursor_dev]
    mov     esi, CURSOR_DEV_SET_SHAPE
    jmp     msg2
9:  ret

.section .note.GNU-stack,"",@progbits
