# =============================================================================
#  BeeModel - the window, whatever draws it: the state the UI reads (size,
#  scale, input pressure, frame times), drawing a frame, and the small
#  helpers every platform shares. The platform's window (wayland.s on Linux,
#  plat_win_wnd.s on Windows) provides the wnd_* routines:
#
#    wnd_open                 the window, shown; fatal when there is none
#    wnd_fd -> eax            the fd to poll for its events
#    wnd_flush                send what is queued
#    wnd_dispatch             read and handle its events (the fd was ready)
#    wnd_pump                 handle what came in, never waiting
#    wnd_ready -> eax         1 when a frame may be drawn now
#    wnd_buffer -> rax        XRGB pixels for phys_w x phys_h, 0: none free
#    wnd_present              show the buffer wnd_buffer gave
#    wnd_move(edi=serial)     the user moves the window (a press on the title)
#    wnd_resize(edi=serial, esi=edges: 1 top, 2 bottom, 4 left, 8 right)
#    wnd_minimize, wnd_maximize_toggle
#    wnd_lock_pointer -> eax  1: the pointer captured, relative motion to
#                             play_look; wnd_unlock_pointer frees it
#    set_cursor(edi=shape)    a cursor-shape-v1 shape
#
#  and calls the UI (ui_motion, ui_button, ui_axis, ui_key, ui_leave,
#  request_quit, play_look) as events come in, after comp_w / comp_h,
#  win_from_comp, set_ui_scale and configured when the size or scale changes.
# =============================================================================
.intel_syntax noprefix
.include "const.inc"

.globl redraw_again
.globl write_err
.globl in_pressure
.globl in_eraser
.globl in_pen
.globl fr_ns
.globl fr_count
.globl fr_work
.globl fr_wk
.globl getenv
.globl envp
.globl fatal
.globl dirty
.globl quit_flag
.globl render
.globl s_newline
.globl str_eq
.globl win_flags
.globl win_w
.globl win_h
.globl comp_w
.globl comp_h
.globl phys_w
.globl phys_h
.globl configured
.globl win_from_comp
.globl pr_ptr
.globl mouse_input
.globl mono_ns

.section .data
.align 4
in_pressure:    .float 1.0              # the pen's pressure 0..1 (mouse: 1)

.section .bss
redraw_again:   .skip 4                 # drawing wants another frame (set while drawing)
.align 64
.equ FR_RING, 256
fr_ns:          .skip FR_RING*8         # the last frames' drawing times
fr_count:       .skip 4                 # frames drawn
.align 8
fr_wk:          .skip FR_RING*8         # their input work (sculpt strokes)
fr_work:        .skip 8                 # (since the last frame)
.align 8
fr_t0:          .skip 8
envp:           .skip 8
in_eraser:      .skip 4                 # 1: the pen's eraser end
in_pen:         .skip 4                 # 1: a tablet tool was seen

# window state
win_w:          .skip 4                 # the UI's size (its units)
win_h:          .skip 4
comp_w:         .skip 4                 # the size the platform gave (logical)
comp_h:         .skip 4
phys_w:         .skip 4                 # the buffer's (pixels)
phys_h:         .skip 4
win_flags:      .skip 4                 # bit0 maximized, bit1 tiled/fullscreen
configured:     .skip 4                 # the window has a size: drawing may start
dirty:          .skip 4
quit_flag:      .skip 4

.section .rodata
.align 4
sf_one_w:       .float 1.0
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
    call    plat_write
    ret

# fatal(rdi=asciz) - print and exit(1)
fatal:
    call    write_err
    mov     edi, 1
    call    plat_exit_group

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

# mouse_input - a pointer event: full pressure, no eraser
mouse_input:
    mov     eax, [rip+sf_one_w]
    mov     [rip+in_pressure], eax
    mov     dword ptr [rip+in_eraser], 0
    ret

# -----------------------------------------------------------------------------
# render - draw the whole UI into a free buffer and show it
# -----------------------------------------------------------------------------
render:
    cmp     dword ptr [rip+configured], 0
    je      9f
    call    wnd_ready                   # (e.g. waiting for the frame callback)
    test    eax, eax
    jz      9f
    push    rbx
    lea     rdi, [rip+frame_arena]
    call    arena_reset
    mov     edi, [rip+win_w]            # buffer is physical: logical x scale
    call    to_px
    mov     [rip+phys_w], eax
    mov     edi, [rip+win_h]
    call    to_px
    mov     [rip+phys_h], eax
    call    wnd_buffer
    test    rax, rax
    jz      8f                          # none free: retry on release
    mov     [rip+fb_ptr], rax
    mov     eax, [rip+phys_w]
    mov     [rip+fb_w], eax
    mov     eax, [rip+phys_h]
    mov     [rip+fb_h], eax
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
    call    wnd_present
    mov     dword ptr [rip+dirty], 0
    mov     eax, [rip+an_play]          # playing: the next frame too
    or      eax, [rip+redraw_again]     # (or drawing asked for one)
    mov     dword ptr [rip+redraw_again], 0
    or      [rip+dirty], eax
8:  pop     rbx
9:  ret

# win_from_comp - win_w / win_h from the platform's size and the UI scale
win_from_comp:
    mov     eax, [rip+comp_w]
    imul    eax, eax, 100
    xor     edx, edx
    div     dword ptr [rip+pr_scale]
    mov     [rip+win_w], eax
    mov     eax, [rip+comp_h]
    imul    eax, eax, 100
    xor     edx, edx
    div     dword ptr [rip+pr_scale]
    mov     [rip+win_h], eax
    ret

# pr_ptr(edi=x, esi=y) -> edi, esi in our units (the UI scale)
pr_ptr:
    cmp     dword ptr [rip+pr_scale], 100
    je      9f
    mov     eax, edi
    imul    eax, eax, 100
    cdq
    idiv    dword ptr [rip+pr_scale]
    mov     edi, eax
    mov     eax, esi
    imul    eax, eax, 100
    cdq
    idiv    dword ptr [rip+pr_scale]
    mov     esi, eax
9:  ret

# mono_ns -> rax = monotonic clock, nanoseconds
mono_ns:
    sub     rsp, 24
    mov     edi, 1                      # CLOCK_MONOTONIC
    mov     rsi, rsp
    call    plat_clock_gettime
    mov     rax, [rsp]
    imul    rax, rax, 1000000000
    add     rax, [rsp+8]
    add     rsp, 24
    ret

.section .note.GNU-stack,"",@progbits
