# =============================================================================
#  BeeModel - the window on Windows: window.s's wnd_* on Win32, and the
#  clipboard (clip_copy, clip_paste). Linked into build/beemodel.exe in
#  place of wayland.s and clipboard.s.
#
#  One top-level window whose client area is all of it (WM_NCCALCSIZE): the
#  UI draws its own title bar and edges, and a press on them hands the move
#  or resize to Windows (WM_NCLBUTTONDOWN), so snapping works. Frames are
#  drawn into one XRGB buffer and shown with StretchDIBits; a timer stands
#  in for Wayland's frame callback. Per-monitor DPI aware: the scale is the
#  monitor's DPI / 96, as Wayland's fractional scale. Keys arrive as scan
#  codes, turned into the evdev codes the UI uses; the text they type comes
#  from keyboard.s's table, filled here from the Windows layout (ToUnicode),
#  so dead keys and AltGr work as on Linux. The thread's message queue is
#  an fd plat_poll waits on (plat_win_msgfd).
#
#  Windows calls wnd_proc in its own convention; it keeps what Windows
#  expects kept (rbx, rbp, rsi, rdi, r12-r15, xmm6-xmm15) around the UI's
#  code. The wnd_* routines keep what the plat_* contract keeps (WENTER).
# =============================================================================
.intel_syntax noprefix
.include "const.inc"
.include "plat_win.inc"

.globl wnd_open
.globl wnd_fd
.globl wnd_flush
.globl wnd_dispatch
.globl wnd_pump
.globl wnd_ready
.globl wnd_buffer
.globl wnd_present
.globl wnd_move
.globl wnd_resize
.globl wnd_minimize
.globl wnd_maximize_toggle
.globl wnd_lock_pointer
.globl wnd_unlock_pointer
.globl set_cursor
.globl clip_init
.globl clip_copy
.globl clip_paste
.globl s_log_hello
.globl s_about2
.globl s_help_plat

.equ CP_UTF8,           65001
.equ WM_SIZE,           0x05
.equ WM_SETFOCUS,       0x07
.equ WM_KILLFOCUS,      0x08
.equ WM_PAINT,          0x0F
.equ WM_CLOSE,          0x10
.equ WM_ERASEBKGND,     0x14
.equ WM_SETCURSOR,      0x20
.equ WM_GETMINMAXINFO,  0x24
.equ WM_NCCALCSIZE,     0x83
.equ WM_NCACTIVATE,     0x86
.equ WM_NCLBUTTONDOWN,  0xA1
.equ WM_INPUT,          0xFF
.equ WM_KEYDOWN,        0x100
.equ WM_KEYUP,          0x101
.equ WM_SYSKEYDOWN,     0x104
.equ WM_SYSKEYUP,       0x105
.equ WM_KEYLAST,        0x109
.equ WM_TIMER,          0x113
.equ WM_MOUSEMOVE,      0x200
.equ WM_LBUTTONDOWN,    0x201
.equ WM_LBUTTONUP,      0x202
.equ WM_RBUTTONDOWN,    0x204
.equ WM_RBUTTONUP,      0x205
.equ WM_MBUTTONDOWN,    0x207
.equ WM_MBUTTONUP,      0x208
.equ WM_MOUSEWHEEL,     0x20A
.equ WM_XBUTTONDOWN,    0x20B
.equ WM_XBUTTONUP,      0x20C
.equ WM_MOUSEHWHEEL,    0x20E
.equ WM_ENTERSIZEMOVE,  0x231
.equ WM_EXITSIZEMOVE,   0x232
.equ WM_DROPFILES,      0x233
.equ WM_POINTERUPDATE,  0x245
.equ WM_POINTERDOWN,    0x246
.equ WM_POINTERUP,      0x247
.equ PEN_FLAG_INVERTED, 2
.equ PEN_FLAG_ERASER,   4
.equ PEN_MASK_PRESSURE, 1
.equ MI_WP_SIGNATURE,   0xFF515700      # (mouse messages made from a pen or touch)
.equ WS_EX_ACCEPTFILES, 0x10
.equ WM_MOUSELEAVE,     0x2A3
.equ WM_DPICHANGED,     0x2E0
.equ WS_OVERLAPPEDWINDOW, 0xCF0000
.equ CW_USEDEFAULT,     0x80000000
.equ SIZE_MINIMIZED,    1
.equ SIZE_MAXIMIZED,    2
.equ HTCLIENT,          1
.equ HTCAPTION,         2
.equ SW_MAXIMIZE,       3
.equ SW_MINIMIZE,       6
.equ SW_RESTORE,        9
.equ SW_SHOWNORMAL,     1
.equ SWP_NOSIZE,        0x01
.equ SWP_NOMOVE,        0x02
.equ SWP_NOZORDER,      0x04
.equ SWP_NOACTIVATE,    0x10
.equ SWP_FRAMECHANGED,  0x20
.equ SM_CXSIZEFRAME,    32
.equ SM_CYSIZEFRAME,    33
.equ SM_CXPADDEDBORDER, 92
.equ SM_CXVIRTUALSCREEN, 78
.equ SM_CYVIRTUALSCREEN, 79
.equ DPI_PER_MONITOR_V2, -4
.equ PM_REMOVE,         1
.equ QS_ALLINPUT,       0x4FF
.equ MWMO_INPUTAVAILABLE, 4
.equ SRCCOPY,           0xCC0020
.equ IDC_ARROW,         32512
.equ IDI_APPLICATION,   32512
.equ TME_LEAVE,         2
.equ RID_INPUT,         0x10000003
.equ RIDEV_REMOVE,      1
.equ MOUSE_MOVE_ABSOLUTE, 1
.equ CF_UNICODETEXT,    13
.equ GMEM_MOVEABLE,     2
.equ VK_SHIFT,          0x10
.equ VK_CONTROL,        0x11
.equ VK_MENU,           0x12
.equ VK_PAUSE,          0x13
.equ VK_CAPITAL,        0x14
.equ VK_F4,             0x73
.equ VK_NUMLOCK,        0x90
.equ VK_LSHIFT,         0xA0
.equ VK_LCONTROL,       0xA2
.equ VK_RCONTROL,       0xA3
.equ VK_LMENU,          0xA4
.equ VK_RMENU,          0xA5
.equ MAPVK_VSC_TO_VK,   1
.equ MAPVK_VK_TO_VSC_EX, 4
.equ FRAME_MS,          10              # the frame timer in Windows' move / resize loop
.equ MONITOR_DEFAULTTONEAREST, 2
.equ MONITORINFOEX_SIZE, 104
.equ MI_DEVICE,         40              # MONITORINFOEXW.szDevice
.equ ENUM_CURRENT_SETTINGS, -1
.equ DEVMODE_SIZE,      220             # DEVMODEW
.equ DM_SIZE,           68
.equ DM_FREQUENCY,      184
.equ WM_DISPLAYCHANGE,  0x7E
.equ CLIP_CAP,          65536
.equ BTN_SIDE,          0x113
.equ BTN_EXTRA,         0x114

.section .bss
.align 8
hwnd:           .skip 8
hinst:          .skip 8
fb:             .skip 8                 # the frame buffer (XRGB), fb_cap bytes
fb_cap:         .skip 8
cur_h:          .skip 8                 # the cursor shown in the window
msg:            .skip 48                # MSG
pmsg:           .skip 48                # (a look at the next one)
ps:             .skip 80                # PAINTSTRUCT
rc:             .skip 16                # RECT
pt:             .skip 8                 # POINT
tme:            .skip 24                # TRACKMOUSEEVENT
rid:            .skip 16                # RAWINPUTDEVICE
rawbuf:         .skip 64                # RAWINPUT (a mouse's)
peninfo:        .skip 128               # POINTER_PEN_INFO
bmi:            .skip 48                # BITMAPINFO (32 bits, top-down)
wc:             .skip 80                # WNDCLASSEXW
ks:             .skip 256               # a keyboard state (the keymap)
wbuf:           .skip 16                # ToUnicode's answer
wtitle:         .skip 128
clip_tmp:       .skip CLIP_CAP*4
dpi:            .skip 4
mon_info:       .skip MONITORINFOEX_SIZE
dev_mode:       .skip DEVMODE_SIZE
.align 8
frame_last:     .skip 8                 # the last frame's time (ns)
cli_w:          .skip 4                 # the client area, pixels
cli_h:          .skip 4
buf_w:          .skip 4                 # the frame shown (phys_w x phys_h then)
buf_h:          .skip 4
msgfd:          .skip 4
frame_pending:  .skip 4
in_sizemove:    .skip 4                 # Windows' move / resize loop runs
minimized:      .skip 4                 # (no frames then, as Wayland gives none)
tracking:       .skip 4                 # TrackMouseEvent asked for the leave
buttons:        .skip 4                 # held: 1 left, 2 right, 4 middle, 8, 16 side
serial:         .skip 4
ralt_time:      .skip 4                 # when right Alt last went (AltGr's
ralt_seen:      .skip 4                 #  fake left Ctrl comes with it)
altgr:          .skip 4                 # the layout has AltGr symbols
locked:         .skip 4                 # the pointer captured (play mode)
abs_x:          .skip 4                 # (absolute raw input, as over RDP:
abs_y:          .skip 4                 #  the last position)
abs_have:       .skip 4

.section .data
.align 8
frame_ns:       .quad 16666667          # a refresh (frame_rate)

.section .rodata
s_class:        .string16 "BeeModel"
e_window:       .asciz "beemodel: cannot create the window\n"
e_fb:           .asciz "beemodel: no memory for the frame\n"
# what the program says about its platform (main.s, ops.s)
s_log_hello:    .asciz "BeeModel shell started - x86-64 assembly, Win32, zero libraries"
s_about2:       .asciz "Written in x86-64 assembly: it calls Win32 directly,"
s_help_plat:    .asciz "BeeModel - 3D modeling shell in pure x86-64 assembly (Windows).\n"
# cursor-shape-v1 shapes (0..34) -> IDC_* - IDC_ARROW
.balign 2
cursor_map:
    .short 0, 0, 0, 139, 137, 138, 2, 3, 3, 1, 1       # -, default .. vertical_text
    .short 0, 0, 134, 136, 136, 137, 134               # alias .. grabbing
    .short 132, 133, 131, 130, 133, 130, 131, 132      # e, n, ne, nw, s, se, sw, w
    .short 132, 133, 131, 130, 132, 133, 134, 0, 0     # ew, ns, nesw, nwse, col, row, all, zoom
.equ CURSOR_SHAPES, 35
# the edges wnd_resize gets (1 top, 2 bottom, 4 left, 8 right) -> HT*
resize_ht:      .byte 0, 12, 15, 0, 10, 13, 16, 0, 11, 14, 17, 0, 0, 0, 0, 0
# extended scan codes -> evdev
ext_map:        .byte 0x1C, 96, 0x1D, 97, 0x35, 98, 0x37, 99, 0x38, 100
                .byte 0x47, 102, 0x48, 103, 0x49, 104, 0x4B, 105, 0x4D, 106
                .byte 0x4F, 107, 0x50, 108, 0x51, 109, 0x52, 110, 0x53, 111
                .byte 0x5B, 125, 0x5C, 126, 0x5D, 127, 0x45, 69, 0
# the character a dead key gives on its own -> keyboard.s's dead kind
.balign 4
dead_map:       .long '`', 1, 0xb4, 2, 0x27, 2, '^', 3, '~', 4, 0xa8, 5, '"', 5
                .long 0xb0, 6, 0x2da, 6, 0x2c7, 7, 0xb8, 8, 0

.text

# ---- opening ------------------------------------------------------------------
# wnd_open - the window, shown, with the layout's keymap and the message fd
wnd_open:
    push    rbx
    WENTER  64
    mov     rcx, DPI_PER_MONITOR_V2
    call    [rip+__imp_SetProcessDpiAwarenessContext]
    lea     rcx, [rip+wbuf]             # started from Explorer: the console
    mov     edx, 4                      #  made for us goes (from a terminal,
    call    [rip+__imp_GetConsoleProcessList]   # it stays: --help prints)
    cmp     eax, 1
    jne     1f
    call    [rip+__imp_FreeConsole]
1:  xor     ecx, ecx
    call    [rip+__imp_GetModuleHandleW]
    mov     [rip+hinst], rax
    lea     rbx, [rip+wc]
    mov     dword ptr [rbx], 80         # cbSize
    lea     rax, [rip+wnd_proc]
    mov     [rbx+8], rax
    mov     rax, [rip+hinst]
    mov     [rbx+24], rax
    xor     ecx, ecx
    mov     edx, IDI_APPLICATION
    call    [rip+__imp_LoadIconW]
    mov     [rbx+32], rax
    mov     [rbx+72], rax
    lea     rax, [rip+s_class]
    mov     [rbx+64], rax
    mov     rcx, rbx
    call    [rip+__imp_RegisterClassExW]
    mov     ecx, CP_UTF8                # the title, in UTF-16
    xor     edx, edx
    lea     r8, [rip+s_app_title]
    mov     r9d, -1
    lea     rax, [rip+wtitle]
    mov     [rsp+32], rax
    mov     dword ptr [rsp+40], 64
    call    [rip+__imp_MultiByteToWideChar]
    call    [rip+__imp_GetDpiForSystem]
    mov     [rip+dpi], eax
    mov     edi, DEF_W
    call    from_96
    mov     [rsp+48], eax
    mov     edi, DEF_H
    call    from_96
    mov     [rsp+56], eax
    mov     ecx, WS_EX_ACCEPTFILES      # (files dropped on it: WM_DROPFILES)
    lea     rdx, [rip+s_class]
    mov     r9d, WS_OVERLAPPEDWINDOW
    lea     r8, [rip+wtitle]
    mov     dword ptr [rsp+32], CW_USEDEFAULT
    mov     dword ptr [rsp+40], CW_USEDEFAULT
    xor     eax, eax
    mov     [rsp+64], rax
    mov     [rsp+72], rax
    mov     rax, [rip+hinst]
    mov     [rsp+80], rax
    mov     qword ptr [rsp+88], 0
    call    [rip+__imp_CreateWindowExW]
    test    rax, rax
    jz      8f
    mov     [rip+hwnd], rax
    mov     rcx, rax                    # the monitor it is on: its scale
    call    [rip+__imp_GetDpiForWindow]
    mov     [rip+dpi], eax
    call    apply_dpi
    call    frame_rate
    mov     edi, DEF_W                  # no frame: all client (WM_NCCALCSIZE),
    call    from_96                     #  at the size for that scale
    mov     [rsp+32], eax
    mov     edi, DEF_H
    call    from_96
    mov     [rsp+40], eax
    mov     rcx, [rip+hwnd]
    xor     edx, edx
    xor     r8d, r8d
    xor     r9d, r9d
    mov     dword ptr [rsp+48], SWP_FRAMECHANGED|SWP_NOMOVE|SWP_NOZORDER|SWP_NOACTIVATE
    call    [rip+__imp_SetWindowPos]
    call    km_build
    lea     rdi, [rip+msg_wait]
    call    plat_win_msgfd
    mov     [rip+msgfd], eax
    xor     ecx, ecx
    mov     edx, IDC_ARROW
    call    [rip+__imp_LoadCursorW]
    mov     [rip+cur_h], rax
    mov     rcx, [rip+hwnd]
    mov     edx, SW_SHOWNORMAL
    call    [rip+__imp_ShowWindow]
    mov     rcx, [rip+hwnd]
    call    [rip+__imp_UpdateWindow]
    WLEAVE
    pop     rbx
    ret
8:  lea     rdi, [rip+e_window]
    call    fatal

# from_96(edi = 96-dpi pixels) -> eax = at the window's dpi; keeps all but rax, rdx
from_96:
    mov     eax, edi
    imul    eax, [rip+dpi]
    add     eax, 48
    xor     edx, edx
    push    rcx
    mov     ecx, 96
    div     ecx
    pop     rcx
    ret

# to_96(edi = pixels, signed) -> eax = at 96 dpi (the platform's logical
#   units, comp_w's); keeps all but rax, rdx
to_96:
    mov     eax, edi
    imul    eax, eax, 96
    cdq
    idiv    dword ptr [rip+dpi]
    ret

# apply_dpi - dpi gives the UI its scale (Wayland's 1/120 units: dpi*5/4)
apply_dpi:
    sub     rsp, 8
    mov     edi, [rip+dpi]
    imul    edi, edi, 5
    shr     edi, 2
    call    set_ui_scale
    test    eax, eax
    jz      9f
    call    fonts_resize                # re-rasterize fonts for the new scale
    call    win_from_comp
    mov     dword ptr [rip+dirty], 1
9:  add     rsp, 8
    ret

# km_build - keyboard.s's table (evdev code x 4 levels: plain, Shift, AltGr,
#   Shift+AltGr) from the layout in use, through ToUnicode. The keypad is
#   left out: kb_text has it. Called from a WENTER frame.
km_build:
    push    rbx
    push    r12
    push    r13
    push    rbp
    mov     rbp, rsp
    and     rsp, -16
    sub     rsp, 48
    mov     ebx, 1                      # the code (= the scan code up to 0x58)
1:  cmp     ebx, 55                     # (KP *)
    je      7f
    cmp     ebx, 71                     # (KP 7 .. KP .)
    jb      2f
    cmp     ebx, 83
    jbe     7f
2:  mov     ecx, ebx
    mov     edx, MAPVK_VSC_TO_VK
    call    [rip+__imp_MapVirtualKeyW]
    test    eax, eax
    jz      7f
    mov     r12d, eax                   # vk
    xor     r13d, r13d                  # level
3:  lea     rdi, [rip+ks]
    xor     eax, eax
    mov     ecx, 32
    rep     stosq
    lea     rdi, [rip+ks]
    test    r13d, 1
    jz      4f
    mov     byte ptr [rdi+VK_SHIFT], 0x80
    mov     byte ptr [rdi+VK_LSHIFT], 0x80
4:  test    r13d, 2
    jz      5f
    mov     byte ptr [rdi+VK_CONTROL], 0x80
    mov     byte ptr [rdi+VK_LCONTROL], 0x80
    mov     byte ptr [rdi+VK_MENU], 0x80
    mov     byte ptr [rdi+VK_RMENU], 0x80
5:  mov     ecx, r12d
    mov     edx, ebx
    lea     r8, [rip+ks]
    lea     r9, [rip+wbuf]
    mov     dword ptr [rsp+32], 8
    mov     dword ptr [rsp+40], 4       # (the keyboard's state left as it is)
    call    [rip+__imp_ToUnicode]
    xor     ecx, ecx                    # ecx = the symbol
    test    eax, eax
    jz      6f
    js      51f
    movzx   ecx, word ptr [rip+wbuf]
    mov     edx, ecx                    # a surrogate pair: one code point
    and     edx, 0xFC00
    cmp     edx, 0xD800
    jne     52f
    cmp     eax, 2
    jb      52f
    movzx   edx, word ptr [rip+wbuf+2]
    sub     ecx, 0xD800
    shl     ecx, 10
    lea     ecx, [rcx+rdx+0x10000-0xDC00]
52: cmp     ecx, 0x20                   # control characters type nothing
    jb      53f
    cmp     ecx, 0x7f
    jne     6f
53: xor     ecx, ecx
    jmp     6f
51: movzx   eax, word ptr [rip+wbuf]    # a dead key: its kind
    lea     rdx, [rip+dead_map]
54: mov     r8d, [rdx]
    test    r8d, r8d
    jz      6f
    cmp     r8d, eax
    je      55f
    add     rdx, 8
    jmp     54b
55: mov     ecx, [rdx+4]
    or      ecx, 0x80000000
6:  mov     eax, ebx
    shl     eax, 4
    lea     rdx, [rip+km_syms]
    add     rdx, rax
    mov     [rdx+r13*4], ecx
    cmp     r13d, 2                     # an AltGr symbol: right Alt is AltGr
    jb      61f
    test    ecx, ecx
    jz      61f
    mov     dword ptr [rip+altgr], 1
61: inc     r13d
    cmp     r13d, 4
    jb      3b
7:  inc     ebx
    cmp     ebx, 0x58
    jbe     1b
    mov     dword ptr [rip+km_loaded], 1
    mov     rsp, rbp
    pop     rbp
    pop     r13
    pop     r12
    pop     rbx
    ret

# msg_wait(ecx = handles, rdx = where, r8d = ms, -1 forever) -> eax =
#   WAIT_OBJECT_0 + ecx when messages wait; plat_poll calls it in the
#   Windows convention. Windows names the lowest signalled index, so a
#   handle that keeps coming (a child streaming into a pipe) would hide the
#   messages behind it: when one is named, the queue is asked too
#   (GetQueueStatus), and messages waiting are said first (the handle's
#   news is found by the next poll at once)
msg_wait:
    sub     rsp, 56
    mov     [rsp+40], ecx
    mov     r9d, QS_ALLINPUT
    mov     dword ptr [rsp+32], MWMO_INPUTAVAILABLE
    call    [rip+__imp_MsgWaitForMultipleObjectsEx]
    cmp     eax, [rsp+40]               # (a handle's: WAIT_OBJECT_0 + i)
    jae     9f
    mov     [rsp+44], eax
    mov     ecx, QS_ALLINPUT
    call    [rip+__imp_GetQueueStatus]
    shr     eax, 16                     # (what is in the queue now)
    test    eax, eax
    mov     eax, [rsp+44]
    jz      9f
    mov     eax, [rsp+40]
9:  add     rsp, 56
    ret

# ---- the window interface (window.s) ----------------------------------------------
wnd_fd:
    mov     eax, [rip+msgfd]
    ret

wnd_flush:
    ret

# wnd_dispatch, wnd_pump - every message waiting, to wnd_proc
wnd_dispatch:
wnd_pump:
    WENTER  16
1:  lea     rcx, [rip+msg]
    xor     edx, edx
    xor     r8d, r8d
    xor     r9d, r9d
    mov     dword ptr [rsp+32], PM_REMOVE
    call    [rip+__imp_PeekMessageW]
    test    eax, eax
    jz      9f
    lea     rcx, [rip+msg]
    call    [rip+__imp_DispatchMessageW]
    jmp     1b
9:  WLEAVE
    ret

# wnd_ready -> eax = 1 unless the next frame is not due yet (its time,
#   plat_win_frame_due, or the timer in Windows' move / resize loop) or the
#   window is minimized
wnd_ready:
    mov     eax, [rip+frame_pending]
    or      eax, [rip+minimized]
    jnz     8f
    cmp     qword ptr [rip+plat_win_frame_due], 0
    je      9f
    push    rdi
    push    rsi
    push    rdx
    call    mono_ns
    pop     rdx
    pop     rsi
    pop     rdi
    cmp     rax, [rip+plat_win_frame_due]
    jb      8f
    mov     qword ptr [rip+plat_win_frame_due], 0
9:  mov     eax, 1
    ret
8:  xor     eax, eax
    ret

# wnd_buffer -> rax = the frame buffer, big enough for phys_w x phys_h
wnd_buffer:
    push    rdi
    push    rsi
    push    rdx
    push    r10
    push    r8
    push    r9
    mov     eax, [rip+phys_w]
    imul    eax, [rip+phys_h]
    shl     rax, 2
    cmp     rax, [rip+fb_cap]
    jbe     2f
    add     rax, 0x1FFFFF               # (in 2 MiB steps)
    and     rax, -0x200000
    push    rax
    push    rax
    mov     rdi, [rip+fb]
    test    rdi, rdi
    jz      1f
    mov     rsi, [rip+fb_cap]
    call    plat_munmap
1:  xor     edi, edi
    mov     rsi, [rsp]
    mov     edx, PROT_RW
    mov     r10d, 0x22                  # MAP_PRIVATE | MAP_ANONYMOUS
    mov     r8d, -1
    xor     r9d, r9d
    call    plat_mmap
    pop     rcx
    pop     rcx
    cmp     rax, -4096
    ja      8f
    mov     [rip+fb], rax
    mov     [rip+fb_cap], rcx
2:  mov     rax, [rip+fb]
    pop     r9
    pop     r8
    pop     r10
    pop     rdx
    pop     rsi
    pop     rdi
    ret
8:  lea     rdi, [rip+e_fb]
    call    fatal

# wnd_present - the frame to the window; the next one after the timer
wnd_present:
    WENTER  16
    mov     eax, [rip+phys_w]
    mov     [rip+buf_w], eax
    mov     eax, [rip+phys_h]
    mov     [rip+buf_h], eax
    mov     rcx, [rip+hwnd]
    call    [rip+__imp_GetDC]
    push    rax
    push    rax
    mov     rcx, rax
    call    blit
    pop     rdx
    pop     rdx
    mov     rcx, [rip+hwnd]
    call    [rip+__imp_ReleaseDC]
    cmp     dword ptr [rip+in_sizemove], 0
    jne     3f
    call    mono_ns                     # the next frame a refresh after this
    mov     rcx, [rip+frame_last]       #  one's time, keeping the beat; late
    add     rcx, [rip+frame_ns]         #  by less than a refresh: at once;
    cmp     rcx, rax                    #  after a pause: a refresh from now
    jae     2f
    mov     rdx, rax
    sub     rdx, rcx
    mov     rcx, rax
    cmp     rdx, [rip+frame_ns]
    jb      2f
    add     rcx, [rip+frame_ns]
2:  mov     [rip+frame_last], rcx
    mov     [rip+plat_win_frame_due], rcx
    WLEAVE
    ret
3:  mov     dword ptr [rip+frame_pending], 1    # (Windows' loop: its timer)
    mov     rcx, [rip+hwnd]
    mov     edx, 1
    mov     r8d, FRAME_MS
    xor     r9d, r9d
    call    [rip+__imp_SetTimer]
    WLEAVE
    ret

# frame_rate - frame_ns from the refresh rate of the monitor the window is
#   on (what Wayland's frame callback keeps to); 60 Hz when Windows does not
#   say; keeps rbx, rsi, rdi, r12-r15
frame_rate:
    push    rbp
    mov     rbp, rsp
    and     rsp, -16
    sub     rsp, 32
    mov     rcx, [rip+hwnd]
    mov     edx, MONITOR_DEFAULTTONEAREST
    call    [rip+__imp_MonitorFromWindow]
    mov     rcx, rax
    lea     rdx, [rip+mon_info]
    mov     dword ptr [rdx], MONITORINFOEX_SIZE
    call    [rip+__imp_GetMonitorInfoW]
    test    eax, eax
    jz      9f
    lea     rcx, [rip+mon_info+MI_DEVICE]
    mov     edx, ENUM_CURRENT_SETTINGS
    lea     r8, [rip+dev_mode]
    mov     word ptr [r8+DM_SIZE], DEVMODE_SIZE
    mov     word ptr [r8+DM_SIZE+2], 0
    call    [rip+__imp_EnumDisplaySettingsW]
    test    eax, eax
    jz      9f
    mov     ecx, [rip+dev_mode+DM_FREQUENCY]
    cmp     ecx, 24                     # (0 or 1: the hardware's default)
    jb      9f
    cmp     ecx, 1000
    ja      9f
    mov     eax, 1000000000
    xor     edx, edx
    div     ecx
    mov     [rip+frame_ns], rax
9:  mov     rsp, rbp
    pop     rbp
    ret

# blit(rcx = DC) - the last frame onto the client area (stretched by the
#   pixel or two the scale rounds off); keeps rbx, rsi, rdi, r12-r15
blit:
    push    rbp
    mov     rbp, rsp
    and     rsp, -16
    sub     rsp, 112
    cmp     qword ptr [rip+fb], 0
    je      9f
    cmp     dword ptr [rip+buf_w], 0
    je      9f
    lea     rax, [rip+bmi]
    mov     dword ptr [rax], 40
    mov     edx, [rip+buf_w]
    mov     [rax+4], edx
    mov     edx, [rip+buf_h]
    neg     edx                         # top-down
    mov     [rax+8], edx
    mov     dword ptr [rax+12], 0x200001   # 1 plane, 32 bits
    mov     dword ptr [rax+16], 0       # BI_RGB
    xor     edx, edx
    xor     r8d, r8d
    mov     r9d, [rip+cli_w]
    mov     eax, [rip+cli_h]
    mov     [rsp+32], eax
    mov     dword ptr [rsp+40], 0
    mov     dword ptr [rsp+48], 0
    mov     eax, [rip+buf_w]
    mov     [rsp+56], eax
    mov     eax, [rip+buf_h]
    mov     [rsp+64], eax
    mov     rax, [rip+fb]
    mov     [rsp+72], rax
    lea     rax, [rip+bmi]
    mov     [rsp+80], rax
    mov     dword ptr [rsp+88], 0       # DIB_RGB_COLORS
    mov     dword ptr [rsp+96], SRCCOPY
    call    [rip+__imp_StretchDIBits]
9:  mov     rsp, rbp
    pop     rbp
    ret

# wnd_move(edi = serial), wnd_resize(edi = serial, esi = edges): Windows
#   moves or resizes the window with the pointer (its own loop, until the
#   button goes up; that release then reaches the UI as usual)
wnd_move:
    push    rbx
    mov     ebx, HTCAPTION
    jmp     1f
wnd_resize:
    push    rbx
    and     esi, 15
    lea     rax, [rip+resize_ht]
    movzx   ebx, byte ptr [rax+rsi]
    test    ebx, ebx
    jz      9f
1:  WENTER
    call    [rip+__imp_ReleaseCapture]
    mov     dword ptr [rip+buttons], 0
    lea     rcx, [rip+pt]
    call    [rip+__imp_GetCursorPos]
    mov     rcx, [rip+hwnd]
    mov     edx, WM_NCLBUTTONDOWN
    mov     r8d, ebx
    call    pt_lparam
    mov     r9, rax
    call    [rip+__imp_SendMessageW]
    lea     rcx, [rip+pt]               # (the release, where it happened)
    call    [rip+__imp_GetCursorPos]
    mov     rcx, [rip+hwnd]
    lea     rdx, [rip+pt]
    call    [rip+__imp_ScreenToClient]
    mov     rcx, [rip+hwnd]
    mov     edx, WM_LBUTTONUP
    xor     r8d, r8d
    call    pt_lparam
    mov     r9, rax
    call    [rip+__imp_PostMessageW]
    WLEAVE
9:  pop     rbx
    ret

# pt_lparam -> rax = pt as an lParam (x and y, 16 bits each)
pt_lparam:
    movzx   eax, word ptr [rip+pt+4]
    shl     eax, 16
    mov     ax, [rip+pt]
    ret

wnd_minimize:
    mov     eax, SW_MINIMIZE
    jmp     1f
wnd_maximize_toggle:
    mov     eax, SW_MAXIMIZE
    test    dword ptr [rip+win_flags], 1
    jz      1f
    mov     eax, SW_RESTORE
1:  WENTER
    mov     rcx, [rip+hwnd]
    mov     edx, eax
    call    [rip+__imp_ShowWindow]
    WLEAVE
    ret

# wnd_lock_pointer -> eax = 1: the pointer kept in the window and hidden,
#   its raw motion (WM_INPUT) to play_look
wnd_lock_pointer:
    cmp     dword ptr [rip+locked], 0
    jne     8f
    WENTER
    lea     rcx, [rip+rid]              # the mouse (usage page 1, usage 2)
    mov     dword ptr [rcx], 0x00020001
    mov     dword ptr [rcx+4], 0
    mov     rax, [rip+hwnd]
    mov     [rcx+8], rax
    mov     edx, 1
    mov     r8d, 16
    call    [rip+__imp_RegisterRawInputDevices]
    call    clip_to_window
    mov     dword ptr [rip+locked], 1
    mov     dword ptr [rip+abs_have], 0
    mov     dword ptr [rip+cur_shape], -1
    mov     qword ptr [rip+cur_h], 0
    xor     ecx, ecx
    call    [rip+__imp_SetCursor]
    WLEAVE
8:  mov     eax, 1
    ret

# clip_to_window - ClipCursor to the client area (from a WENTER frame)
clip_to_window:
    sub     rsp, 40
    mov     rcx, [rip+hwnd]
    lea     rdx, [rip+rc]
    call    [rip+__imp_GetClientRect]
    mov     rcx, [rip+hwnd]
    xor     edx, edx
    lea     r8, [rip+rc]
    mov     r9d, 2
    call    [rip+__imp_MapWindowPoints]
    lea     rcx, [rip+rc]
    call    [rip+__imp_ClipCursor]
    add     rsp, 40
    ret

# wnd_unlock_pointer - the pointer free again (its cursor back on the next move)
wnd_unlock_pointer:
    cmp     dword ptr [rip+locked], 0
    je      9f
    WENTER
    lea     rcx, [rip+rid]
    mov     dword ptr [rcx], 0x00020001
    mov     dword ptr [rcx+4], RIDEV_REMOVE
    mov     qword ptr [rcx+8], 0
    mov     edx, 1
    mov     r8d, 16
    call    [rip+__imp_RegisterRawInputDevices]
    xor     ecx, ecx
    call    [rip+__imp_ClipCursor]
    mov     dword ptr [rip+locked], 0
    mov     dword ptr [rip+cur_shape], -1
    mov     edi, 1
    call    set_cursor
    WLEAVE
9:  ret

# set_cursor(edi = cursor-shape-v1 shape, -1 none) - only when it changes
set_cursor:
    cmp     edi, [rip+cur_shape]
    je      9f
    mov     [rip+cur_shape], edi
    WENTER
    xor     eax, eax
    test    edi, edi
    js      2f
    xor     eax, eax
    cmp     edi, CURSOR_SHAPES
    jae     1f
    lea     rax, [rip+cursor_map]
    movzx   eax, word ptr [rax+rdi*2]
1:  lea     edx, [rax+IDC_ARROW]
    xor     ecx, ecx
    call    [rip+__imp_LoadCursorW]
2:  mov     [rip+cur_h], rax
    mov     eax, [rip+tracking]         # the pointer over the window: now
    or      eax, [rip+buttons]
    jz      3f
    mov     rcx, [rip+cur_h]
    call    [rip+__imp_SetCursor]
3:  WLEAVE
9:  ret

# ---- the clipboard ------------------------------------------------------------------
clip_init:
    ret

# clip_copy(rdi = text, esi = bytes) - it becomes the clipboard (UTF-16,
#   lines ended by CR LF, as Windows programs expect)
clip_copy:
    push    rbx
    push    r12
    WENTER  32
    cmp     esi, CLIP_CAP-1
    jbe     1f
    mov     esi, CLIP_CAP-1
1:  lea     rbx, [rip+clip_tmp]         # LF -> CR LF, in UTF-8 first
    xor     ecx, ecx
    xor     edx, edx
2:  cmp     ecx, esi
    jae     4f
    mov     al, [rdi+rcx]
    test    al, al
    jz      4f
    cmp     al, 10
    jne     3f
    mov     byte ptr [rbx+rdx], 13
    inc     edx
3:  mov     [rbx+rdx], al
    inc     edx
    inc     ecx
    jmp     2b
4:  mov     byte ptr [rbx+rdx], 0
    inc     edx
    mov     r12d, edx                   # bytes with the 0: units enough
    mov     ecx, GMEM_MOVEABLE
    lea     edx, [r12+r12]
    call    [rip+__imp_GlobalAlloc]
    test    rax, rax
    jz      9f
    mov     rbx, rax
    mov     rcx, rax
    call    [rip+__imp_GlobalLock]
    mov     ecx, CP_UTF8
    xor     edx, edx
    lea     r8, [rip+clip_tmp]
    mov     r9d, -1
    mov     [rsp+32], rax
    mov     [rsp+40], r12
    call    [rip+__imp_MultiByteToWideChar]
    mov     rcx, rbx
    call    [rip+__imp_GlobalUnlock]
    call    clip_open
    test    eax, eax
    jz      8f
    call    [rip+__imp_EmptyClipboard]
    mov     ecx, CF_UNICODETEXT
    mov     rdx, rbx
    call    [rip+__imp_SetClipboardData]
    mov     r12, rax
    call    [rip+__imp_CloseClipboard]
    test    r12, r12                    # (the clipboard owns it now)
    jnz     9f
8:  mov     rcx, rbx
    call    [rip+__imp_GlobalFree]
9:  WLEAVE
    pop     r12
    pop     rbx
    ret

# clip_open -> eax = 1 when the clipboard is ours to use (another program
#   may hold it a moment: a few tries)
clip_open:
    push    rbx
    sub     rsp, 32
    mov     ebx, 10
1:  mov     rcx, [rip+hwnd]
    call    [rip+__imp_OpenClipboard]
    test    eax, eax
    jnz     9f
    dec     ebx
    jz      9f
    mov     ecx, 5
    call    [rip+__imp_Sleep]
    jmp     1b
9:  add     rsp, 32
    pop     rbx
    ret

# clip_paste(rdi = dest, esi = capacity) -> eax = bytes (0-ended; 0 if none);
#   CR LF comes back as LF
clip_paste:
    push    rbx
    push    r12
    push    r13
    push    r14
    WENTER  32
    mov     r13, rdi
    mov     r14d, esi
    xor     r12d, r12d                  # bytes
    mov     ecx, CF_UNICODETEXT
    call    [rip+__imp_IsClipboardFormatAvailable]
    test    eax, eax
    jz      8f
    call    clip_open
    test    eax, eax
    jz      8f
    mov     ecx, CF_UNICODETEXT
    call    [rip+__imp_GetClipboardData]
    test    rax, rax
    jz      7f
    mov     rbx, rax
    mov     rcx, rax
    call    [rip+__imp_GlobalLock]
    test    rax, rax
    jz      7f
    mov     ecx, CP_UTF8
    xor     edx, edx
    mov     r8, rax
    mov     r9d, -1
    lea     rax, [rip+clip_tmp]
    mov     [rsp+32], rax
    mov     dword ptr [rsp+40], CLIP_CAP*4-1
    mov     qword ptr [rsp+48], 0
    mov     qword ptr [rsp+56], 0
    call    [rip+__imp_WideCharToMultiByte]
    mov     byte ptr [rip+clip_tmp+CLIP_CAP*4-1], 0
    mov     rcx, rbx
    call    [rip+__imp_GlobalUnlock]
    lea     rsi, [rip+clip_tmp]         # into dest, without the CRs
    lea     edx, [r14-1]
1:  cmp     r12d, edx
    jae     7f
    mov     al, [rsi]
    inc     rsi
    test    al, al
    jz      7f
    cmp     al, 13
    jne     2f
    cmp     byte ptr [rsi], 10
    je      1b
2:  mov     [r13+r12], al
    inc     r12d
    jmp     1b
7:  call    [rip+__imp_CloseClipboard]
8:  test    r14d, r14d
    jz      9f
    mov     byte ptr [r13+r12], 0
9:  mov     eax, r12d
    WLEAVE
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# ---- the window procedure ------------------------------------------------------------
# wnd_proc(rcx = hwnd, edx = message, r8 = wParam, r9 = lParam) -> rax, in
#   the Windows convention. r12-r15 hold the four while a message is handled.
wnd_proc:
    push    rbp
    mov     rbp, rsp
    push    rbx
    push    rsi
    push    rdi
    push    r12
    push    r13
    push    r14
    push    r15
    sub     rsp, 288
    and     rsp, -16
    movdqa  [rsp+112], xmm6
    movdqa  [rsp+128], xmm7
    movdqa  [rsp+144], xmm8
    movdqa  [rsp+160], xmm9
    movdqa  [rsp+176], xmm10
    movdqa  [rsp+192], xmm11
    movdqa  [rsp+208], xmm12
    movdqa  [rsp+224], xmm13
    movdqa  [rsp+240], xmm14
    movdqa  [rsp+256], xmm15
    mov     r12, rcx
    mov     r13d, edx
    mov     r14, r8
    mov     r15, r9
    cmp     r13d, WM_MOUSEMOVE
    je      .Lp_motion
    cmp     r13d, WM_INPUT
    je      .Lp_input
    cmp     r13d, WM_KEYDOWN
    jb      1f
    cmp     r13d, WM_SYSKEYUP
    jbe     .Lp_key
1:  cmp     r13d, WM_LBUTTONDOWN
    jb      2f
    cmp     r13d, WM_MOUSEHWHEEL
    jbe     .Lp_button
2:  cmp     r13d, WM_TIMER
    je      .Lp_timer
    cmp     r13d, WM_SETCURSOR
    je      .Lp_setcursor
    cmp     r13d, WM_SIZE
    je      .Lp_size
    cmp     r13d, WM_PAINT
    je      .Lp_paint
    cmp     r13d, WM_ERASEBKGND
    je      .Lp_one
    cmp     r13d, WM_NCCALCSIZE
    je      .Lp_nccalc
    cmp     r13d, WM_NCACTIVATE
    je      .Lp_ncactivate
    cmp     r13d, WM_GETMINMAXINFO
    je      .Lp_minmax
    cmp     r13d, WM_MOUSELEAVE
    je      .Lp_leave
    cmp     r13d, WM_CLOSE
    je      .Lp_close
    cmp     r13d, WM_KILLFOCUS
    je      .Lp_killfocus
    cmp     r13d, WM_ENTERSIZEMOVE
    je      .Lp_entersm
    cmp     r13d, WM_EXITSIZEMOVE
    je      .Lp_exitsm
    cmp     r13d, WM_DPICHANGED
    je      .Lp_dpi
    cmp     r13d, WM_DISPLAYCHANGE
    je      .Lp_display
    cmp     r13d, WM_DROPFILES
    je      .Lp_drop
    cmp     r13d, WM_POINTERUPDATE
    jb      3f
    cmp     r13d, WM_POINTERUP
    jbe     .Lp_pointer
3:.Lp_def:
    mov     rcx, r12
    mov     edx, r13d
    mov     r8, r14
    mov     r9, r15
    call    [rip+__imp_DefWindowProcW]
    jmp     .Lp_ret
.Lp_one:
    mov     eax, 1
    jmp     .Lp_ret
.Lp_zero:
    xor     eax, eax
.Lp_ret:
    movdqa  xmm6, [rsp+112]
    movdqa  xmm7, [rsp+128]
    movdqa  xmm8, [rsp+144]
    movdqa  xmm9, [rsp+160]
    movdqa  xmm10, [rsp+176]
    movdqa  xmm11, [rsp+192]
    movdqa  xmm12, [rsp+208]
    movdqa  xmm13, [rsp+224]
    movdqa  xmm14, [rsp+240]
    movdqa  xmm15, [rsp+256]
    lea     rsp, [rbp-56]
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rdi
    pop     rsi
    pop     rbx
    pop     rbp
    ret

.Lp_size:                               # the client area's new size
    xor     eax, eax
    cmp     r14d, SIZE_MINIMIZED
    sete    al
    mov     [rip+minimized], eax
    je      .Lp_zero
    movzx   eax, r15w
    mov     [rip+cli_w], eax
    mov     eax, r15d
    shr     eax, 16
    mov     [rip+cli_h], eax
    mov     edi, [rip+cli_w]
    call    to_96
    mov     ecx, 1
    test    eax, eax
    cmovle  eax, ecx
    mov     [rip+comp_w], eax
    mov     edi, [rip+cli_h]
    call    to_96
    mov     ecx, 1
    test    eax, eax
    cmovle  eax, ecx
    mov     [rip+comp_h], eax
    xor     eax, eax
    cmp     r14d, SIZE_MAXIMIZED
    sete    al
    mov     [rip+win_flags], eax
    call    win_from_comp
    mov     dword ptr [rip+configured], 1
    mov     dword ptr [rip+dirty], 1
    cmp     dword ptr [rip+in_sizemove], 0  # resizing: drawn as it goes
    je      .Lp_zero
    mov     dword ptr [rip+frame_pending], 0
    call    render
    jmp     .Lp_zero

.Lp_paint:                              # the last frame again
    mov     rcx, r12
    lea     rdx, [rip+ps]
    call    [rip+__imp_BeginPaint]
    mov     rcx, rax
    call    blit
    mov     rcx, r12
    lea     rdx, [rip+ps]
    call    [rip+__imp_EndPaint]
    jmp     .Lp_zero

.Lp_display:                            # a new refresh rate, perhaps
    call    frame_rate
    jmp     .Lp_def

.Lp_timer:                              # the frame timer (Windows' loop)
    cmp     r14, 1
    jne     .Lp_def
    mov     rcx, r12
    mov     edx, 1
    call    [rip+__imp_KillTimer]
    mov     dword ptr [rip+frame_pending], 0
    cmp     dword ptr [rip+in_sizemove], 0  # (Windows' loop runs: draw here)
    je      .Lp_zero
    cmp     dword ptr [rip+dirty], 0
    je      .Lp_zero
    call    render
    jmp     .Lp_zero

.Lp_entersm:
    mov     dword ptr [rip+in_sizemove], 1
    jmp     .Lp_zero
.Lp_exitsm:
    mov     dword ptr [rip+in_sizemove], 0
    call    frame_rate                  # (perhaps on another monitor now)
    mov     dword ptr [rip+dirty], 1
    jmp     .Lp_zero

.Lp_nccalc:                             # all of it is client area; maximized,
    test    r14, r14                    #  less the frame Windows puts off-screen
    jz      .Lp_def
    mov     rcx, r12
    call    [rip+__imp_IsZoomed]
    test    eax, eax
    jz      .Lp_zero
    mov     ecx, SM_CXSIZEFRAME
    mov     edx, [rip+dpi]
    call    [rip+__imp_GetSystemMetricsForDpi]
    mov     ebx, eax
    mov     ecx, SM_CXPADDEDBORDER
    mov     edx, [rip+dpi]
    call    [rip+__imp_GetSystemMetricsForDpi]
    add     ebx, eax
    add     [r15], ebx
    add     [r15+4], ebx
    sub     [r15+8], ebx
    sub     [r15+12], ebx
    jmp     .Lp_zero

.Lp_ncactivate:                         # (no caption to repaint)
    mov     r15, -1
    jmp     .Lp_def

.Lp_minmax:
    mov     edi, MIN_W
    call    from_96
    mov     [r15+24], eax
    mov     edi, MIN_H
    call    from_96
    mov     [r15+28], eax
    jmp     .Lp_zero

.Lp_dpi:                                # another monitor: its scale, the size
    movzx   eax, r14w                   #  Windows suggests
    mov     [rip+dpi], eax
    call    apply_dpi
    call    frame_rate
    mov     rcx, r12
    xor     edx, edx
    mov     r8d, [r15]
    mov     r9d, [r15+4]
    mov     eax, [r15+8]
    sub     eax, [r15]
    mov     [rsp+32], eax
    mov     eax, [r15+12]
    sub     eax, [r15+4]
    mov     [rsp+40], eax
    mov     dword ptr [rsp+48], SWP_NOZORDER|SWP_NOACTIVATE
    call    [rip+__imp_SetWindowPos]
    jmp     .Lp_zero

.Lp_pointer:                            # a pen: its pressure and its end; the
    movzx   ecx, r14w                   #  mouse messages Windows makes of it
    lea     rdx, [rip+peninfo]          #  then move and click (mouse_or_pen)
    call    [rip+__imp_GetPointerPenInfo]
    test    eax, eax
    jz      .Lp_def                     # (touch: as a mouse)
    mov     dword ptr [rip+in_pen], 1
    xor     eax, eax
    test    dword ptr [rip+peninfo+96], PEN_FLAG_INVERTED|PEN_FLAG_ERASER
    setnz   al
    mov     [rip+in_eraser], eax
    mov     eax, 0x3f800000             # 1.0 without a pressure
    test    dword ptr [rip+peninfo+100], PEN_MASK_PRESSURE
    jz      1f
    cvtsi2ss xmm0, dword ptr [rip+peninfo+104]
    mulss   xmm0, [rip+pen_scale]       # (0..1024)
    movd    eax, xmm0
1:  mov     [rip+in_pressure], eax
    jmp     .Lp_def

# mouse_or_pen - a mouse message: full pressure, no eraser, unless Windows
#   made it from a pen (its pressure then stays as WM_POINTER set it)
mouse_or_pen:
    sub     rsp, 40
    call    [rip+__imp_GetMessageExtraInfo]
    and     eax, 0xFFFFFF00
    cmp     eax, MI_WP_SIGNATURE
    je      9f
    call    mouse_input
9:  add     rsp, 40
    ret

.Lp_drop:                               # files dropped: each to drop_one
    mov     rcx, r14                    # (wParam: the drop's DROPFILES, in
    call    [rip+__imp_GlobalLock]      #  global memory: no shell32 needed)
    test    rax, rax
    jz      3f
    mov     rbx, rax
    cmp     dword ptr [rbx+16], 0       # fWide: the names in UTF-16
    je      2f
    mov     r13d, [rbx]                 # pFiles: the names, each 0-ended,
    add     r13, rbx                    #  an empty one last
1:  cmp     word ptr [r13], 0
    je      2f
    mov     ecx, CP_UTF8
    xor     edx, edx
    mov     r8, r13
    mov     r9d, -1
    lea     rax, [rip+drop_path]
    mov     [rsp+32], rax
    mov     dword ptr [rsp+40], 1020
    mov     qword ptr [rsp+48], 0
    mov     qword ptr [rsp+56], 0
    call    [rip+__imp_WideCharToMultiByte]
    test    eax, eax
    jz      12f
    lea     rdi, [rip+drop_path]        # (the program's form: /C:/...)
    call    plat_path_in
    call    drop_one
12: add     r13, 2                      # the next name
    cmp     word ptr [r13-2], 0
    jne     12b
    jmp     1b
2:  mov     rcx, r14
    call    [rip+__imp_GlobalUnlock]
3:  mov     rcx, r14                    # (as DragFinish)
    call    [rip+__imp_GlobalFree]
    jmp     .Lp_zero

.Lp_setcursor:
    cmp     r15w, HTCLIENT
    jne     .Lp_def
    mov     rcx, [rip+cur_h]
    call    [rip+__imp_SetCursor]
    jmp     .Lp_one

.Lp_close:
    call    request_quit                # (unsaved changes: asks first)
    jmp     .Lp_zero

.Lp_killfocus:
    call    kb_repeat_stop
    mov     dword ptr [rip+key_mods], 0
    jmp     .Lp_zero

.Lp_motion:
    cmp     dword ptr [rip+tracking], 0 # (to hear when it leaves)
    jne     1f
    lea     rcx, [rip+tme]
    mov     dword ptr [rcx], 24
    mov     dword ptr [rcx+4], TME_LEAVE
    mov     [rcx+8], r12
    mov     dword ptr [rcx+16], 0
    call    [rip+__imp_TrackMouseEvent]
    mov     dword ptr [rip+tracking], 1
    mov     rcx, [rip+cur_h]            # (back in: our cursor)
    call    [rip+__imp_SetCursor]
1:  call    mouse_or_pen
    call    ptr_ui
    call    ui_motion
    jmp     .Lp_zero

# ptr_ui -> edi, esi = lParam's position in the UI's units
ptr_ui:
    movsx   edi, r15w
    call    to_96
    mov     ebx, eax
    mov     eax, r15d
    sar     eax, 16
    mov     edi, eax
    call    to_96
    mov     esi, eax
    mov     edi, ebx
    jmp     pr_ptr

.Lp_leave:
    mov     dword ptr [rip+tracking], 0
    call    ui_leave
    jmp     .Lp_zero

.Lp_button:                             # buttons and wheels
    cmp     r13d, WM_MOUSEWHEEL
    je      .Lp_wheel
    cmp     r13d, WM_MOUSEHWHEEL
    je      .Lp_hwheel
    mov     eax, r13d
    sub     eax, WM_LBUTTONDOWN         # 0 1 left, 3 4 right, 6 7 middle
    xor     edx, edx
    mov     ecx, 3
    div     ecx                         # eax = which, edx = 0 down, 1 up
    cmp     r13d, WM_XBUTTONDOWN        # (10 11: the side buttons)
    jb      0f
    mov     eax, 3
    mov     edx, r13d
    sub     edx, WM_XBUTTONDOWN
0:  cmp     edx, 2
    jae     .Lp_def                     # (double clicks: none asked for)
    xor     esi, esi
    test    edx, edx
    sete    sil                         # state
    lea     rcx, [rip+btn_map]
    mov     edi, [rcx+rax*8]            # evdev button
    mov     ebx, [rcx+rax*8+4]          # its bit
    cmp     eax, 3
    jne     1f
    mov     eax, r14d                   # XBUTTON1 / 2
    shr     eax, 16
    cmp     eax, 2
    jne     1f
    mov     edi, BTN_EXTRA
    shl     ebx, 1
1:  mov     r13d, edi
    test    esi, esi
    jz      2f
    cmp     dword ptr [rip+buttons], 0  # held: the window keeps the mouse
    jne     11f                         # (Windows keeps rsi: the state)
    mov     rcx, r12
    call    [rip+__imp_SetCapture]
11: or      [rip+buttons], ebx
    jmp     3f
2:  not     ebx
    and     [rip+buttons], ebx
    jnz     3f
    call    [rip+__imp_ReleaseCapture]
3:  call    mouse_or_pen
    call    [rip+__imp_GetMessageTime]
    mov     ecx, eax
    inc     dword ptr [rip+serial]
    mov     edx, [rip+serial]
    mov     edi, r13d
    call    ui_button
    cmp     r13d, BTN_SIDE
    jb      .Lp_zero
    jmp     .Lp_one                     # (XBUTTON: TRUE)

.Lp_wheel:                              # Wayland's axis: 10 a notch, down > 0
    xor     edi, edi
    mov     eax, r14d
    sar     eax, 16
    neg     eax
    jmp     1f
.Lp_hwheel:
    mov     edi, 1
    mov     eax, r14d
    sar     eax, 16
1:  shl     eax, 5                      # 120 a notch -> 15.0 (24.8 fixed)
    mov     esi, eax
    call    ui_axis
    jmp     .Lp_zero

.Lp_input:                              # raw mouse motion (play mode)
    cmp     dword ptr [rip+locked], 0
    je      .Lp_def
    mov     rcx, r15
    mov     edx, RID_INPUT
    lea     r8, [rip+rawbuf]
    lea     r9, [rsp+48]
    mov     dword ptr [r9], 64
    mov     dword ptr [rsp+32], 24      # sizeof RAWINPUTHEADER
    call    [rip+__imp_GetRawInputData]
    cmp     eax, 64
    ja      .Lp_def
    cmp     dword ptr [rip+rawbuf], 0   # RIM_TYPEMOUSE
    jne     .Lp_def
    mov     esi, [rip+rawbuf+36]        # lLastX, lLastY
    mov     edi, [rip+rawbuf+40]
    test    word ptr [rip+rawbuf+24], MOUSE_MOVE_ABSOLUTE
    jz      2f
    mov     eax, [rip+abs_x]            # absolute (0..65535 over the desktop,
    mov     ecx, [rip+abs_y]            #  as remote desktop sends): the change
    mov     [rip+abs_x], esi
    mov     [rip+abs_y], edi
    cmp     dword ptr [rip+abs_have], 0
    mov     dword ptr [rip+abs_have], 1
    je      .Lp_def
    sub     esi, eax
    sub     edi, ecx
    mov     r13d, edi
    mov     ebx, esi
    mov     ecx, SM_CXVIRTUALSCREEN
    call    [rip+__imp_GetSystemMetrics]
    imul    ebx, eax
    sar     ebx, 16
    mov     ecx, SM_CYVIRTUALSCREEN
    call    [rip+__imp_GetSystemMetrics]
    imul    r13d, eax
    sar     r13d, 16
    mov     esi, ebx
    mov     edi, r13d
2:  cvtsi2ss xmm0, esi
    cvtsi2ss xmm1, edi
    call    play_look
    jmp     .Lp_def

.Lp_key:
    mov     ebx, r13d                   # ebx = 1 down, 0 up
    and     ebx, 1
    xor     ebx, 1
    cmp     r13d, WM_SYSKEYDOWN         # Alt+F4: Windows makes it WM_CLOSE
    jne     1f
    cmp     r14d, VK_F4
    je      .Lp_def
1:  mov     eax, r15d                   # the scan code, extended or not
    shr     eax, 16
    movzx   esi, al
    mov     edi, r15d
    shr     edi, 24
    and     edi, 1
    cmp     r14d, VK_MENU               # right Alt: when (its fake Ctrl)
    jne     2f
    test    edi, edi
    jz      2f
    call    [rip+__imp_GetMessageTime]
    mov     [rip+ralt_time], eax
    mov     dword ptr [rip+ralt_seen], 1
    jmp     4f
2:  cmp     r14d, VK_CONTROL            # left Ctrl sent with right Alt: AltGr's
    jne     4f
    test    edi, edi
    jnz     4f
    call    fake_ctrl
    test    eax, eax
    jnz     .Lp_zero
4:  call    key_code                    # eax = evdev
    test    eax, eax
    jz      .Lp_zero
    mov     r13d, eax
    call    key_mods_now
    test    ebx, ebx
    jz      5f
    test    r15d, 1 << 30               # held down: Windows repeats it
    jz      5f
    cmp     r13d, [rip+rep_code]        # (when the UI asked for repeats)
    jne     .Lp_zero
    mov     edi, r13d
    call    ui_key_repeat
    jmp     .Lp_zero
5:  mov     edi, r13d
    mov     esi, ebx
    call    ui_key
    jmp     .Lp_zero

# fake_ctrl -> eax = 1 when this left Ctrl comes with right Alt (AltGr on
#   a layout that has it): the right Alt just went, or is next in line
fake_ctrl:
    push    rbx
    sub     rsp, 48
    call    [rip+__imp_GetMessageTime]
    mov     ebx, eax
    cmp     dword ptr [rip+ralt_seen], 0
    je      1f
    cmp     eax, [rip+ralt_time]
    je      8f
1:  lea     rcx, [rip+pmsg]
    xor     edx, edx
    mov     r8d, WM_KEYDOWN
    mov     r9d, WM_KEYLAST
    mov     dword ptr [rsp+32], 0       # PM_NOREMOVE
    call    [rip+__imp_PeekMessageW]
    test    eax, eax
    jz      9f
    cmp     qword ptr [rip+pmsg+16], VK_MENU
    jne     7f
    test    dword ptr [rip+pmsg+24], 1 << 24
    jz      7f
    cmp     [rip+pmsg+32], ebx
    je      8f
7:  xor     eax, eax
    jmp     9f
8:  mov     eax, 1
9:  add     rsp, 48
    pop     rbx
    ret

# key_code(esi = scan code, edi = extended, r14 = virtual key) -> eax =
#   the evdev code, 0 for a key the UI does not know
key_code:
    sub     rsp, 40
    test    esi, esi                    # no scan code: from the virtual key
    jnz     1f
    mov     ecx, r14d
    mov     edx, MAPVK_VK_TO_VSC_EX
    call    [rip+__imp_MapVirtualKeyW]
    movzx   esi, al
    xor     edi, edi
    cmp     ah, 0xE0
    sete    dil
1:  mov     eax, 119                    # Pause, Num Lock: by their keys
    cmp     r14d, VK_PAUSE
    je      9f
    mov     eax, 69
    cmp     r14d, VK_NUMLOCK
    je      9f
    test    edi, edi
    jnz     2f
    xor     eax, eax
    cmp     esi, 0x58                   # the main block: the same numbers
    ja      9f
    mov     eax, esi
    jmp     9f
2:  lea     rcx, [rip+ext_map]
3:  movzx   eax, byte ptr [rcx]
    test    eax, eax
    jz      9f
    cmp     eax, esi
    je      4f
    add     rcx, 2
    jmp     3b
4:  movzx   eax, byte ptr [rcx+1]
9:  add     rsp, 40
    ret

# key_mods_now - key_mods and mods_locked, as Wayland's modifiers event
#   gives them (Shift 1, Ctrl 4, Alt 8, AltGr 0x80; Caps Lock locked 2)
key_mods_now:
    push    rbx
    push    r12
    sub     rsp, 40
    xor     ebx, ebx
    mov     ecx, VK_SHIFT
    call    [rip+__imp_GetKeyState]
    test    ax, 0x8000
    jz      1f
    or      ebx, MOD_SHIFT
1:  mov     ecx, VK_RCONTROL
    call    [rip+__imp_GetKeyState]
    test    ax, 0x8000
    jz      2f
    or      ebx, MOD_CTRL
2:  mov     ecx, VK_LMENU
    call    [rip+__imp_GetKeyState]
    test    ax, 0x8000
    jz      3f
    or      ebx, MOD_ALT
3:  xor     r12d, r12d                  # r12 = AltGr held
    mov     ecx, VK_RMENU
    call    [rip+__imp_GetKeyState]
    test    ax, 0x8000
    jz      5f
    cmp     dword ptr [rip+altgr], 0
    je      4f
    or      ebx, 0x80
    inc     r12d
    jmp     5f
4:  or      ebx, MOD_ALT
5:  test    r12d, r12d                  # (AltGr's left Ctrl is not one)
    jnz     6f
    mov     ecx, VK_LCONTROL
    call    [rip+__imp_GetKeyState]
    test    ax, 0x8000
    jz      6f
    or      ebx, MOD_CTRL
6:  mov     [rip+key_mods], ebx
    mov     ecx, VK_CAPITAL
    call    [rip+__imp_GetKeyState]
    and     eax, 1
    add     eax, eax
    mov     [rip+mods_locked], eax
    add     rsp, 40
    pop     r12
    pop     rbx
    ret

.section .rodata
.balign 4
btn_map:        .long BTN_LEFT, 1, BTN_RIGHT, 2, BTN_MIDDLE, 4, BTN_SIDE, 8
pen_scale:      .float 0.0009765625     # 1 / 1024

# ---- the imports ------------------------------------------------------------------
DLL 3, USER32.dll
IMPORT 3, BeginPaint
IMPORT 3, ClipCursor
IMPORT 3, CloseClipboard
IMPORT 3, CreateWindowExW
IMPORT 3, DefWindowProcW
IMPORT 3, DispatchMessageW
IMPORT 3, EnumDisplaySettingsW
IMPORT 3, EmptyClipboard
IMPORT 3, EndPaint
IMPORT 3, GetClientRect
IMPORT 3, GetClipboardData
IMPORT 3, GetCursorPos
IMPORT 3, GetDC
IMPORT 3, GetDpiForSystem
IMPORT 3, GetDpiForWindow
IMPORT 3, GetKeyState
IMPORT 3, GetMessageExtraInfo
IMPORT 3, GetMessageTime
IMPORT 3, GetMonitorInfoW
IMPORT 3, GetQueueStatus
IMPORT 3, GetPointerPenInfo
IMPORT 3, GetRawInputData
IMPORT 3, GetSystemMetrics
IMPORT 3, GetSystemMetricsForDpi
IMPORT 3, IsClipboardFormatAvailable
IMPORT 3, IsZoomed
IMPORT 3, KillTimer
IMPORT 3, LoadCursorW
IMPORT 3, LoadIconW
IMPORT 3, MapVirtualKeyW
IMPORT 3, MapWindowPoints
IMPORT 3, MonitorFromWindow
IMPORT 3, MsgWaitForMultipleObjectsEx
IMPORT 3, OpenClipboard
IMPORT 3, PeekMessageW
IMPORT 3, PostMessageW
IMPORT 3, RegisterClassExW
IMPORT 3, RegisterRawInputDevices
IMPORT 3, ReleaseCapture
IMPORT 3, ReleaseDC
IMPORT 3, ScreenToClient
IMPORT 3, SendMessageW
IMPORT 3, SetCapture
IMPORT 3, SetClipboardData
IMPORT 3, SetCursor
IMPORT 3, SetProcessDpiAwarenessContext
IMPORT 3, SetTimer
IMPORT 3, SetWindowPos
IMPORT 3, ShowWindow
IMPORT 3, ToUnicode
IMPORT 3, TrackMouseEvent
IMPORT 3, UpdateWindow
DLL_END 3

DLL 4, GDI32.dll
IMPORT 4, StretchDIBits
DLL_END 4

.section .note.GNU-stack,"",@progbits
