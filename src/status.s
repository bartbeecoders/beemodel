# =============================================================================
#  BeeModel - the status bar and toasts.
#    left:  what the mouse and keys do right now (the mode, a transform,
#           play mode), as key chips with a word each;
#    right: chips - the scene's size, the AI's permission (click: the AI
#           menu), a render's progress, co-editing, the live link (click:
#           the Versions editor), a long job's progress (jobui.s);
#    toasts: what an operator reports, for four seconds above the status
#           bar, green for results, amber for problems; click one to open
#           the console.
# =============================================================================
.intel_syntax noprefix
.include "const.inc"
.include "macros.inc"
.include "widgets.inc"
.include "icons.inc"

# exports
.globl draw_statusbar
.globl toast_note
.globl toast_wait
.globl busy_wait
.globl busy_tick
.globl fps_wait
.globl fps_tick
.globl toast_tick
.globl toast_on
.globl toast_warn

.equ TOAST_MS,  4000

.equ ST_AI, 0                           # (st_seen's tasks)
.equ ST_HZ, 1
.equ ST_EX, 2
.equ ST_VG, 3
.equ ST_LB, 4
.equ ST_SEEN_N, 5
.equ FPS_N, 512                         # (a 500 Hz display counted whole)

.section .data
.align 4
fps_env:        .long -1                # BEEMODEL_FPS=0 (tests): never shown; -1 not asked yet

.section .bss
.align 8
toast_t0:       .skip 8
toast_on:       .skip 4                 # (from the first frame: startup lines are not toasts)
toast_show:     .skip 4
toast_line:     .skip 4                 # the log line shown
toast_dummy:    .skip 4
toast_warn:     .skip 4                 # the next toast is a warning (set by run_op_ui)
toast_bad:      .skip 4                 # the toast shown is one
stat_buf:       .skip 96
st_seen:        .skip 8*ST_SEEN_N       # when each background task was first
                                        #  seen at work (0: idle): its time
fps_ts:         .skip 8*FPS_N           # the frame rate (#439): the last frames' times
fps_txt:        .skip 24                #  as shown ("60 fps", "idle")
fps_last:       .skip 8                 #  the last one
fps_i:          .skip 4
fps_n:          .skip 4                 #  frames in the second before it
st_busy_t:      .skip 8                 # the last redraw for those times

.section .rodata
s_lk_serve:     .asciz "Live link: serving"
s_since:        .asciz ", "
s_secs:         .asciz " s"
s_mins:         .asciz " min "
s_left_a:       .asciz ", about "
s_left_b:       .asciz " left"
s_dots:         .asciz "..."
s_hz_stop:      .asciz " (click: stop)"
s_vg_chip:      .asciz "Virtualizing the mesh"
s_lb_chip:      .asciz "Making library thumbnails"
s_lk_mirror:    .asciz "Live link: mirroring"
.align 4
sf_100:         .float 100.0
sf_twentieth:   .float 0.05
sf_almost:      .float 0.999
sf_one_st:      .float 1.0

# hints: key, word, ... 0
h_object:       .quad k_lmb, w_select, k_drag, w_orbit, k_mmb, w_pan, k_wheel, w_zoom
                .quad k_grs, w_transform, k_rmb, w_menu, k_f3, w_search, 0
h_edit:         .quad k_lmb, w_select, k_b, w_box, k_altlmb, w_loop, k_e, w_extrude
                .quad k_rmb, w_menu, k_tab, w_objmode, 0
h_sculpt:       .quad k_lmb, w_stroke, k_ctrl, w_invert, k_shift, w_smooth, k_brk, w_radius
                .quad k_sbrk, w_strength, k_ctab, w_leave, 0
h_paint:        .quad k_lmb, w_paint, k_brk, w_radius, k_sbrk, w_strength, k_stab, w_leave, 0
h_sketch:       .quad k_lor, w_tools, k_d, w_dimension, k_x, w_delete, k_tab, w_leave, 0
h_tm:           .quad k_xyz, w_axis, k_ctrl, w_snap, k_num, w_value, k_enter, w_confirm, k_esc, w_cancel, 0
h_play:         .quad k_wasd, w_walk, k_space, w_jump, k_f, w_fly, k_esc, w_stop, 0
k_lmb:          .asciz "LMB"
k_drag:         .asciz "Drag"
k_mmb:          .asciz "MMB"
k_wheel:        .asciz "Wheel"
k_grs:          .asciz "G R S"
k_rmb:          .asciz "RMB"
k_f3:           .asciz "F3"
k_b:            .asciz "B"
k_altlmb:       .asciz "Alt+LMB"
k_e:            .asciz "E"
k_tab:          .asciz "Tab"
k_ctrl:         .asciz "Ctrl"
k_shift:        .asciz "Shift"
k_brk:          .asciz "[ ]"
k_sbrk:         .asciz "Shift+[ ]"
k_ctab:         .asciz "Ctrl+Tab"
k_stab:         .asciz "Shift+Tab"
k_lor:          .asciz "L O R"
k_d:            .asciz "D"
k_x:            .asciz "X"
k_xyz:          .asciz "X Y Z"
k_num:          .asciz "1.5"
k_enter:        .asciz "Enter"
k_esc:          .asciz "Esc"
k_wasd:         .asciz "WASD"
k_space:        .asciz "Space"
k_f:            .asciz "F"
w_select:       .asciz "select"
w_orbit:        .asciz "orbit"
w_pan:          .asciz "pan"
w_zoom:         .asciz "zoom"
w_transform:    .asciz "move / turn / scale"
w_menu:         .asciz "menu"
w_search:       .asciz "search"
w_box:          .asciz "box"
w_loop:         .asciz "loop"
w_extrude:      .asciz "extrude"
w_objmode:      .asciz "object mode"
w_stroke:       .asciz "stroke"
w_invert:       .asciz "invert"
w_smooth:       .asciz "smooth"
w_radius:       .asciz "radius"
w_strength:     .asciz "strength"
w_leave:        .asciz "leave"
w_paint:        .asciz "paint"
w_tools:        .asciz "line / circle / rect"
w_dimension:    .asciz "dimension"
w_delete:       .asciz "delete"
w_axis:         .asciz "axis"
w_snap:         .asciz "snap"
w_value:        .asciz "type a value"
w_confirm:      .asciz "confirm"
w_cancel:       .asciz "cancel"
w_walk:         .asciz "walk"
w_jump:         .asciz "jump"
w_fly:          .asciz "fly"
w_stop:         .asciz "stop"
s_objects:      .asciz " objects  "
s_object1:      .asciz " object  "
s_faces:        .asciz " faces"
s_ai:           .asciz "AI: "
s_ai_stop:      .asciz "   Stop"
s_render:       .asciz "Render "
s_pct:          .asciz "%"
s_fps:          .asciz " fps"
s_fps_idle:     .asciz "idle"
s_env_fps:      .asciz "BEEMODEL_FPS="
s_coedit:       .asciz "Co-editing"
s_rec:          .asciz "Recording macro"
s_dot3:         .asciz "..."
# a toast that reports a problem has one of these
.align 8
bad_words:      .quad bw_err, bw_fail, bw_cannot, bw_cant, bw_not, bw_no, bw_unknown, bw_missing, bw_denied, 0
bw_err:         .asciz "error"
bw_fail:        .asciz "fail"
bw_cannot:      .asciz "cannot"
bw_cant:        .asciz "can't"
bw_not:         .asciz "not "
bw_no:          .asciz "no "
bw_unknown:     .asciz "unknown"
bw_missing:     .asciz "missing"
bw_denied:      .asciz "denied"

.text

OPERATOR op_menu_ai, "menu.ai", "AI Menu", do_menu_ai, flags=OPF_QUIET|OPF_HIDDEN, doc="Open the AI menu: permissions, activity, revert"
WIDGET wd_st_ai,    WK_BUTTON, "status.ai", "AI permission", flags=WGF_NODRAW, aux=op_menu_ai, tip="What AI agents may do here (read only / edit the scene / files too). Click for the AI menu"
WIDGET wd_st_link,  WK_BUTTON, "status.link", "Live link", flags=WGF_NODRAW, aux=op_area_type_versions, tip="The live link is on. Click for the Versions editor (serve, connect, stop)"
WIDGET wd_st_aiwork, WK_BUTTON, "status.ai_working", "AI working", flags=WGF_NODRAW, aux=op_ai_stop, tip="The AI is working on this request (one undo step). Click to stop it"
WIDGET wd_st_exlib, WK_BUTTON, "status.downloads", "Downloads", flags=WGF_NODRAW, aux=op_ex_stop, tip="An online library at work: its catalog or an asset's files. Click to stop"
WIDGET wd_st_hi3d, WK_BUTTON, "status.hi3d", "Image to 3D", flags=WGF_NODRAW, aux=op_hz_stop, tip="A model being made from an image (the Hi3D addon). Click to stop it"
WIDGET wd_st_vg,    WK_BUTTON, "status.virtualizing", "Virtualizing", flags=WGF_NODRAW, tip="A mesh being made into clusters for virtualized geometry (in the background: you can go on working)"
WIDGET wd_st_lb,    WK_BUTTON, "status.thumbnails", "Library thumbnails", flags=WGF_NODRAW, tip="The content library's missing thumbnails being path-traced, one asset at a time (in the background)"
WIDGET wd_st_job,   WK_BUTTON, "status.job", "Job", flags=WGF_NODRAW, tip="A long job: the window answers again when it is done"
WIDGET wd_st_fps,   WK_BUTTON, "status.fps", "Frame rate", flags=WGF_NODRAW, tip="Frames drawn in the last second. BeeModel draws only when something changes: idle when nothing moves (Preferences > Interface turns it off)"
WIDGET wd_st_toast, WK_BUTTON, "status.toast", "Message", flags=WGF_NODRAW, aux=op_console_focus, tip="Click to open the console with every message"

do_menu_ai:
    mov     dword ptr [rip+menu_open], 8    # (the bar's AI menu)
    mov     dword ptr [rip+dirty], 1
    ret

# ---- toasts ----------------------------------------------------------------------
# toast_note(edi=log line number) - log.s: a line was written
toast_note:
    cmp     dword ptr [rip+toast_on], 0
    je      9f
    push    rbx
    mov     ebx, edi
    and     edi, LOG_LINES-1            # echoes of commands are not news
    imul    edi, LOG_LINE_LEN
    lea     rax, [rip+log_buf]
    add     rax, rdi
    movzx   ecx, word ptr [rax]
    cmp     ecx, 0x203e                 # "> "
    je      8f
    cmp     ecx, 0x2024                 # "$ "
    je      8f
    mov     rcx, rax                    # (agents' traffic: "mcp:")
1:  cmp     byte ptr [rcx], ' '
    jne     2f
    inc     rcx
    jmp     1b
2:  cmp     dword ptr [rcx], 0x3a70636d
    je      8f
    cmp     byte ptr [rax], 0
    je      8f
    mov     [rip+toast_line], ebx
    mov     dword ptr [rip+toast_show], 1
    mov     eax, [rip+toast_warn]
    mov     [rip+toast_bad], eax
    mov     dword ptr [rip+toast_warn], 0
    sub     rsp, 8
    call    mono_ns
    add     rsp, 8
    mov     [rip+toast_t0], rax
8:  pop     rbx
9:  ret

# ---- how long things take (#433) ---------------------------------------------------
# fmt_secs(edi=seconds) - "12 s", "3 min 05 s" into fmt_buf
fmt_secs:
    push    rbx
    mov     ebx, edi
    cmp     ebx, 60
    jb      1f
    mov     eax, ebx
    xor     edx, edx
    mov     ecx, 60
    div     ecx
    mov     ebx, edx
    mov     edi, eax
    call    fmt_int
    lea     rdi, [rip+s_mins]
    call    fmt_str
    cmp     ebx, 10
    jae     1f
    mov     edi, '0'
    call    fmt_char
1:  mov     edi, ebx
    call    fmt_int
    lea     rdi, [rip+s_secs]
    call    fmt_str
    pop     rbx
    ret

# fmt_dur(rdi=ns) - ", 12 s" into fmt_buf, from a second on
fmt_dur:
    cmp     rdi, 1000000000
    jb      9f
    push    rdi
    lea     rdi, [rip+s_since]
    call    fmt_str
    pop     rax
    xor     edx, edx
    mov     ecx, 1000000000
    div     rcx
    mov     edi, eax
    jmp     fmt_secs
9:  ret

# fmt_since(edi=task, esi=1 at work) - its time since it was first seen at
#   work, into fmt_buf (", 12 s"); idle: forgotten
fmt_since:
    push    rbx
    lea     rbx, [rip+st_seen]
    lea     rbx, [rbx+rdi*8]
    test    esi, esi
    jnz     1f
    mov     qword ptr [rbx], 0
    pop     rbx
    ret
1:  call    mono_ns
    cmp     qword ptr [rbx], 0
    jne     2f
    mov     [rbx], rax
2:  sub     rax, [rbx]
    mov     rdi, rax
    pop     rbx
    jmp     fmt_dur

# chip_timed_hz (fmt_buf: Image to 3D's text, hz_chip) - its time and
#   "(click: stop)" after it
chip_timed_hz:
    sub     rsp, 8
    mov     edi, ST_HZ
    mov     esi, 1
    call    fmt_since
    lea     rdi, [rip+s_hz_stop]
    call    fmt_str
    add     rsp, 8
    ret

# timed_chip(rdi=label, esi=task, edx=1 at work, rcx=its widget) (r12d:
#   the chips' edge) - a chip with the label and how long it has been at work
timed_chip:
    push    rbx
    push    r13
    push    r14
    mov     r14, rcx
    mov     rbx, rdi
    mov     r13d, esi
    mov     edi, esi
    mov     esi, edx
    test    edx, edx
    jnz     1f
    call    fmt_since                   # (idle: forgotten, no chip)
    jmp     9f
1:  call    fmt_reset
    mov     rdi, rbx
    call    fmt_str
    mov     edi, r13d
    mov     esi, 1
    call    fmt_since
    lea     rdi, [rip+stat_buf]
    lea     rsi, [rip+fmt_buf]
    call    cpy_s
    lea     rdi, [rip+stat_buf]
    mov     rsi, r14
    call    chip
9:  pop     r14
    pop     r13
    pop     rbx
    ret

# busy_any -> eax = 1 while a background task is at work (its chip's time
#   goes on)
busy_any:
    mov     eax, [rip+ai_busy]
    or      eax, [rip+hz_pid]
    or      eax, [rip+lb_busy]
    cmp     dword ptr [rip+vg_state], 1
    jne     1f
    or      eax, 1
1:  test    eax, eax
    jnz     8f
    sub     rsp, 8
    call    ex_chip
    add     rsp, 8
    test    rax, rax
    jz      9f
8:  mov     eax, 1
    ret
9:  xor     eax, eax
    ret

# busy_wait -> eax = ms until the chips' times should be drawn again (a
#   second apart), -1 when nothing is at work (main.s's wait)
busy_wait:
    sub     rsp, 8
    call    busy_any
    test    eax, eax
    jz      8f
    call    mono_ns
    sub     rax, [rip+st_busy_t]
    xor     edx, edx
    mov     ecx, 1000000
    div     rcx
    mov     ecx, 1000
    sub     ecx, eax
    xor     eax, eax
    test    ecx, ecx
    cmovg   eax, ecx
    inc     eax
    add     rsp, 8
    ret
8:  mov     eax, -1
    add     rsp, 8
    ret

# fps_on -> eax = 1 when the frame rate is shown (the preference, unless
#   BEEMODEL_FPS=0)
fps_on:
    mov     eax, [rip+fps_env]
    test    eax, eax
    jns     1f
    sub     rsp, 8
    lea     rdi, [rip+s_env_fps]
    call    getenv
    add     rsp, 8
    mov     ecx, 1
    test    rax, rax
    jz      2f
    cmp     byte ptr [rax], '0'
    jne     2f
    xor     ecx, ecx
2:  mov     [rip+fps_env], ecx
    mov     eax, ecx
1:  and     eax, [rip+pr_fps]
    ret

# fps_chip (r12d = right edge, moved left) - the frame rate (#439): this
#   frame's time kept, the frames in the second before it counted; "idle"
#   when it is the only one (BeeModel draws only when something changes)
fps_chip:
    push    rbx
    call    fps_on
    test    eax, eax
    jz      9f
    call    mono_ns
    mov     rbx, rax
    mov     [rip+fps_last], rax
    lea     rdx, [rip+fps_ts]
    mov     ecx, [rip+fps_i]
    and     ecx, FPS_N-1
    mov     [rdx+rcx*8], rax
    inc     dword ptr [rip+fps_i]
    xor     ecx, ecx
    xor     esi, esi
1:  mov     rax, rbx
    sub     rax, [rdx+rcx*8]
    cmp     rax, 1000000000
    jae     2f
    inc     esi
2:  inc     ecx
    cmp     ecx, FPS_N
    jb      1b
    mov     [rip+fps_n], esi
    call    fmt_reset
    mov     esi, [rip+fps_n]
    cmp     esi, 1
    ja      3f
    lea     rdi, [rip+s_fps_idle]
    call    fmt_str
    jmp     4f
3:  mov     edi, esi
    call    fmt_int
    lea     rdi, [rip+s_fps]
    call    fmt_str
4:  lea     rdi, [rip+fps_txt]
    lea     rsi, [rip+fmt_buf]
    call    cpy_s
    lea     rdi, [rip+fps_txt]
    lea     rsi, [rip+wd_st_fps]
    call    chip
    lea     rdi, [rip+fps_txt]          # (ui_tree: the rate)
    call    wg_set_label
9:  pop     rbx
    ret

# fps_wait -> eax = ms until a frame that lets the frame rate settle (a
#   second after the last frame, when it showed frames flowing), -1 none
fps_wait:
    sub     rsp, 8
    mov     eax, -1
    cmp     dword ptr [rip+fps_n], 1
    jbe     9f
    call    fps_on
    test    eax, eax
    mov     eax, -1
    jz      9f
    call    mono_ns
    sub     rax, [rip+fps_last]
    xor     edx, edx
    mov     ecx, 1000000
    div     rcx
    mov     ecx, 1050
    sub     ecx, eax
    xor     eax, eax
    test    ecx, ecx
    cmovg   eax, ecx
9:  add     rsp, 8
    ret

# fps_tick - that frame, when it is due
fps_tick:
    sub     rsp, 8
    call    fps_wait
    test    eax, eax
    jnz     9f
    mov     dword ptr [rip+fps_n], 0
    mov     dword ptr [rip+dirty], 1
9:  add     rsp, 8
    ret

# busy_tick - a frame a second while something is at work (its time)
busy_tick:
    sub     rsp, 8
    call    busy_wait
    cmp     eax, 1
    ja      9f
    call    mono_ns
    mov     [rip+st_busy_t], rax
    mov     dword ptr [rip+dirty], 1
9:  add     rsp, 8
    ret

# toast_wait -> eax = ms until the toast goes, -1 if none
toast_wait:
    mov     eax, -1
    cmp     dword ptr [rip+toast_show], 0
    je      9f
    sub     rsp, 8
    call    mono_ns
    add     rsp, 8
    sub     rax, [rip+toast_t0]
    xor     edx, edx
    mov     ecx, 1000000
    div     rcx
    mov     ecx, TOAST_MS
    sub     ecx, eax
    xor     eax, eax
    test    ecx, ecx
    cmovg   eax, ecx
    inc     eax
9:  ret

toast_tick:
    cmp     dword ptr [rip+toast_show], 0
    je      9f
    sub     rsp, 8
    call    toast_wait
    add     rsp, 8
    cmp     eax, 1
    ja      9f
    mov     dword ptr [rip+toast_show], 0
    mov     dword ptr [rip+dirty], 1
9:  ret

# is_bad(rdi=text) -> eax = 1 if it reads like a problem
is_bad:
    push    rbx
    push    r12
    sub     rsp, 8
    mov     r12, rdi
    lea     rbx, [rip+bad_words]
1:  mov     rsi, [rbx]
    test    rsi, rsi
    jz      8f
    mov     rdi, r12
    call    contains_ci
    test    eax, eax
    jnz     9f
    add     rbx, 8
    jmp     1b
8:  xor     eax, eax
9:  add     rsp, 8
    pop     r12
    pop     rbx
    ret

# contains_ci(rdi=text, rsi=word) -> eax = 1 if text contains it (any case)
contains_ci:
1:  cmp     byte ptr [rdi], 0
    je      8f
    xor     ecx, ecx
2:  movzx   eax, byte ptr [rsi+rcx]
    test    eax, eax
    jz      9f
    movzx   edx, byte ptr [rdi+rcx]
    or      eax, 0x20
    or      edx, 0x20
    cmp     eax, edx
    jne     3f
    inc     ecx
    jmp     2b
3:  inc     rdi
    jmp     1b
8:  xor     eax, eax
    ret
9:  mov     eax, 1
    ret

# draw_toast - above the status bar, on the right
draw_toast:
    cmp     dword ptr [rip+toast_show], 0
    je      .Ldt_ret
    push    rbx
    push    r12
    push    r13
    push    r14
    sub     rsp, 8
    mov     eax, [rip+toast_line]
    and     eax, LOG_LINES-1
    imul    eax, LOG_LINE_LEN
    lea     rbx, [rip+log_buf]
    add     rbx, rax
1:  cmp     byte ptr [rbx], ' '         # (results are indented in the console)
    jne     2f
    inc     rbx
    jmp     1b
2:  mov     rdi, rbx
    call    is_bad
    or      eax, [rip+toast_bad]
    mov     r14d, eax
    mov     rdi, rbx
    call    text_width
    lea     r12d, [rax+52]              # the box
    cmp     r12d, 560
    jle     3f
    mov     r12d, 560
3:  mov     r13d, [rip+win_w]
    sub     r13d, r12d
    sub     r13d, 12
    mov     edi, r13d
    mov     esi, [rip+cont_y1]
    sub     esi, 42
    mov     edx, r12d
    mov     ecx, 34
    mov     r8d, COL_DROP_BORDER
    call    popup_frame
    mov     edi, r13d                   # a coloured edge
    add     edi, 1
    mov     esi, [rip+cont_y1]
    sub     esi, 38
    mov     edx, 3
    mov     ecx, 26
    mov     r8d, COL_OK
    test    r14d, r14d
    jz      4f
    mov     r8d, COL_WARN
4:  call    fill_rect
    lea     edi, [r13+12]               # an icon, the text
    mov     esi, [rip+cont_y1]
    sub     esi, 33
    mov     edx, ICON_OK
    mov     r8d, COL_OK
    test    r14d, r14d
    jz      5f
    mov     edx, ICON_WARNING
    mov     r8d, COL_WARN
5:  call    draw_icon
    mov     edi, r13d
    add     edi, 36
    mov     esi, [rip+win_w]
    sub     esi, 22
    mov     edx, [rip+cont_y1]
    call    set_clip_lg
    lea     edi, [r13+36]
    mov     esi, [rip+cont_y1]
    sub     esi, 33
    mov     rdx, rbx
    mov     ecx, COL_TEXT
    call    draw_text
    call    reset_clip
    lea     rdi, [rip+wd_st_toast]      # click: the console
    mov     esi, r13d
    mov     edx, [rip+cont_y1]
    sub     edx, 42
    mov     ecx, r12d
    lea     r8, [rip+toast_dummy]
    xor     r9d, r9d
    call    wg
    mov     rdi, rbx                    # (ui_tree: its message)
    call    wg_set_label
    add     rsp, 8
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
.Ldt_ret:
    ret

# set_clip_lg(edi=x0, esi=x1, edx=y1) - clip x0..x1, 0..y1
set_clip_lg:
    mov     ecx, edx
    mov     edx, esi
    xor     esi, esi
    jmp     set_clip

# ---- the bar ---------------------------------------------------------------------
draw_statusbar:
    push    rbx
    push    r12
    push    r13
    push    r14
    sub     rsp, 8
    xor     edi, edi
    mov     esi, [rip+cont_y1]
    mov     edx, [rip+win_w]
    mov     ecx, STATUS_H
    mov     r8d, COL_STATUS_BG
    call    fill_rect
    mov     ebx, 10                     # x
    cmp     dword ptr [rip+macro_on], 0 # recording a macro: say so first
    je      1f
    mov     edi, 14
    mov     esi, [rip+cont_y1]
    add     esi, STATUS_H/2
    mov     edx, 4
    mov     r8d, COL_REC
    call    fill_circle
    mov     edi, 24
    mov     esi, [rip+cont_y1]
    add     esi, 3
    lea     rdx, [rip+s_rec]
    mov     ecx, COL_REC
    call    draw_small
    lea     ebx, [rax+16]
1:  call    hints_now                   # the keys and the mouse, now
    mov     r12, rax
2:  mov     rdx, [r12]
    test    rdx, rdx
    jz      3f
    mov     rdi, rdx                    # a key chip
    mov     r13, rdx
    call    text_width_small
    lea     r14d, [rax+10]
    mov     edi, ebx
    mov     esi, [rip+cont_y1]
    add     esi, 3
    mov     edx, r14d
    mov     ecx, STATUS_H-6
    mov     r8d, COL_BTN
    mov     r9d, 3
    call    fill_rrect
    lea     edi, [rbx+5]
    mov     esi, [rip+cont_y1]
    add     esi, 3
    mov     rdx, r13
    mov     ecx, COL_TEXT
    call    draw_small
    lea     edi, [rbx+r14+5]            # its word
    mov     esi, [rip+cont_y1]
    add     esi, 3
    mov     rdx, [r12+8]
    mov     ecx, COL_TEXT_DIM
    call    draw_small
    lea     ebx, [rax+14]
    add     r12, 16
    mov     eax, [rip+win_w]            # (not into the chips on the right)
    sub     eax, 420
    cmp     ebx, eax
    jl      2b
3:  mov     r12d, [rip+win_w]           # right to left: chips
    sub     r12d, 10
    cmp     dword ptr [rip+job_on], 0   # a long job (jobui.s): its progress
    je      31f
    call    job_chip
31: lea     rdi, [rip+s_lk_serve]       # the live link: serving, mirroring
    cmp     dword ptr [rip+lk_serving], 0
    jne     32f
    lea     rdi, [rip+s_lk_mirror]
    cmp     dword ptr [rip+lk_mstate], 0
    je      33f
32: lea     rsi, [rip+wd_st_link]
    call    chip
33: cmp     dword ptr [rip+co_on], 0    # co-editing
    je      4f
    lea     rdi, [rip+s_coedit]
    xor     esi, esi
    call    chip
4:  cmp     dword ptr [rip+hv_active], 0    # a render's progress
    je      5f
    call    fmt_reset
    lea     rdi, [rip+s_render]
    call    fmt_str
    mov     eax, [rip+hv_spp]
    imul    eax, 100
    xor     edx, edx
    mov     ecx, [rip+hv_target]
    test    ecx, ecx
    jz      41f
    div     ecx
41: mov     edi, eax
    call    fmt_int
    lea     rdi, [rip+s_pct]
    call    fmt_str
    lea     rdi, [rip+stat_buf]
    lea     rsi, [rip+fmt_buf]
    call    cpy_s
    lea     rdi, [rip+stat_buf]
    xor     esi, esi
    call    chip
5:  cmp     dword ptr [rip+ai_busy], 0  # the AI at work: its prompt, Stop
    jne     50f
    mov     edi, ST_AI
    xor     esi, esi
    call    fmt_since                   # (idle: its time forgotten)
    jmp     51f
50:
    call    fmt_reset
    lea     rdi, [rip+s_ai]
    call    fmt_str
    lea     rsi, [rip+ai_label+7]       # ("Agent: <prompt>")
    lea     rdi, [rip+stat_buf]
    mov     ecx, 36
52: mov     al, [rsi]
    mov     [rdi], al
    test    al, al
    jz      53f
    inc     rsi
    inc     rdi
    dec     ecx
    jnz     52b
    mov     byte ptr [rdi], 0
53: lea     rdi, [rip+stat_buf]
    call    fmt_str
    lea     rdi, [rip+s_dots]
    call    fmt_str
    mov     edi, ST_AI                  # (how long it has been at it)
    mov     esi, 1
    call    fmt_since
    lea     rdi, [rip+s_ai_stop]
    call    fmt_str
    lea     rdi, [rip+stat_buf]
    lea     rsi, [rip+fmt_buf]
    call    cpy_s
    lea     rdi, [rip+stat_buf]
    lea     rsi, [rip+wd_st_aiwork]
    call    chip
51: cmp     dword ptr [rip+hz_pid], 0   # Image to 3D at work: how far, Stop
    jne     56f
    mov     edi, ST_HZ
    xor     esi, esi
    call    fmt_since
    jmp     54f
56: call    hz_chip
    call    chip_timed_hz
    lea     rdi, [rip+stat_buf]
    lea     rsi, [rip+fmt_buf]
    call    cpy_s
    lea     rdi, [rip+stat_buf]
    lea     rsi, [rip+wd_st_hi3d]
    call    chip
54: call    ex_chip                     # an online source at work: how far, Stop
    test    rax, rax
    jnz     57f
    mov     edi, ST_EX
    xor     esi, esi
    call    fmt_since
    jmp     58f
57: call    fmt_reset
    mov     rdi, rax
    call    fmt_str
    mov     edi, ST_EX
    mov     esi, 1
    call    fmt_since
    lea     rdi, [rip+stat_buf]
    lea     rsi, [rip+fmt_buf]
    call    cpy_s
    lea     rdi, [rip+stat_buf]
    lea     rsi, [rip+wd_st_exlib]
    call    chip
58: lea     rdi, [rip+s_vg_chip]        # a mesh being virtualized (vgeo.s,
    mov     esi, ST_VG                  #  in the background)
    xor     edx, edx
    cmp     dword ptr [rip+vg_state], 1
    sete    dl
    lea     rcx, [rip+wd_st_vg]
    call    timed_chip
    lea     rdi, [rip+s_lb_chip]        # library thumbnails (library.s, a
    mov     esi, ST_LB                  #  child at a time)
    xor     edx, edx
    cmp     dword ptr [rip+lb_busy], 0
    setne   dl
    lea     rcx, [rip+wd_st_lb]
    call    timed_chip
55: call    fmt_reset                   # the AI's permission
    lea     rdi, [rip+s_ai]
    call    fmt_str
    mov     edi, [rip+agent_tier]
    call    agent_tier_name
    mov     rdi, rax
    call    fmt_str
    lea     rdi, [rip+stat_buf]
    lea     rsi, [rip+fmt_buf]
    call    cpy_s
    lea     rdi, [rip+stat_buf]
    lea     rsi, [rip+wd_st_ai]
    call    chip
    call    scene_stats                 # the scene's size
    lea     rdi, [rip+stat_buf]
    xor     esi, esi
    call    chip
    call    fps_chip                    # the frame rate
    call    draw_toast
    add     rsp, 8
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# job_chip (r12d = right edge, moved left) - the job's name and percentage
#   over a bar filling with its progress
job_chip:
    push    rbx
    push    r13
    push    r14
    call    fmt_reset
    mov     rdi, [rip+job_label]
    call    fmt_str
    movss   xmm0, [rip+job_frac]
    xorps   xmm1, xmm1
    comiss  xmm0, xmm1
    jb      1f
    mov     edi, ' '
    call    fmt_char
    movss   xmm0, [rip+job_frac]
    mulss   xmm0, [rip+sf_100]
    cvttss2si edi, xmm0
    call    fmt_int
    lea     rdi, [rip+s_pct]
    call    fmt_str
1:  call    mono_ns                     # how long, and how long still (once
    sub     rax, [rip+job_t0]           #  a twentieth is done, after 2 s)
    mov     r14, rax
    mov     rdi, rax
    call    fmt_dur
    movss   xmm0, [rip+job_frac]
    comiss  xmm0, [rip+sf_twentieth]
    jb      11f
    comiss  xmm0, [rip+sf_almost]
    ja      11f
    cmp     r14, 2000000000
    jb      11f
    cvtsi2ss xmm1, r14                  # left = elapsed (1 - f) / f
    movss   xmm2, [rip+sf_one_st]
    subss   xmm2, xmm0
    mulss   xmm1, xmm2
    divss   xmm1, xmm0
    cvttss2si rax, xmm1
    add     rax, 999999999              # (whole seconds, rounded up)
    lea     rdi, [rip+s_left_a]
    push    rax
    push    rax
    call    fmt_str
    pop     rdi
    pop     rax
    xor     edx, edx
    mov     rax, rdi
    mov     ecx, 1000000000
    div     rcx
    mov     edi, eax
    call    fmt_secs
    lea     rdi, [rip+s_left_b]
    call    fmt_str
11: lea     rdi, [rip+stat_buf]
    lea     rsi, [rip+fmt_buf]
    call    cpy_s
    lea     rdi, [rip+stat_buf]
    call    text_width_small
    lea     r13d, [rax+16]
    sub     r12d, r13d
    mov     edi, r12d                   # the chip
    mov     esi, [rip+cont_y1]
    add     esi, 3
    mov     edx, r13d
    mov     ecx, STATUS_H-6
    mov     r8d, COL_MENU_BG
    mov     r9d, (STATUS_H-6)/2
    call    fill_rrect
    movss   xmm0, [rip+job_frac]        # the bar along its bottom
    xorps   xmm1, xmm1
    comiss  xmm0, xmm1
    jae     12f
    mov     rax, r14                    # unknown: a piece of it gliding
    xor     edx, edx                    #  along (a frame at least every
    mov     ecx, 8000000                #  100 ms while the job reports)
    div     rcx
    mov     ecx, r13d
    shr     ecx, 2                      # (a quarter of the chip)
    lea     r8d, [r13+rcx]
    xor     edx, edx
    div     r8d
    mov     edi, edx
    sub     edi, ecx                    # x: -piece .. width
    mov     edx, ecx
    test    edi, edi
    jns     13f
    add     edx, edi
    xor     edi, edi
13: lea     eax, [rdi+rdx]
    cmp     eax, r13d
    jle     14f
    mov     edx, r13d
    sub     edx, edi
14: test    edx, edx
    jle     2f
    add     edi, r12d
    mov     esi, [rip+cont_y1]
    add     esi, STATUS_H-6
    mov     ecx, 3
    mov     r8d, COL_ACCENT
    call    fill_rect
    jmp     2f
12:
    cvtsi2ss xmm1, r13d
    mulss   xmm0, xmm1
    cvttss2si edx, xmm0
    test    edx, edx
    jz      2f
    mov     edi, r12d
    mov     esi, [rip+cont_y1]
    add     esi, STATUS_H-6
    mov     ecx, 3
    mov     r8d, COL_ACCENT
    call    fill_rect
2:  lea     edi, [r12+8]
    mov     esi, [rip+cont_y1]
    add     esi, 3
    lea     rdx, [rip+stat_buf]
    mov     ecx, COL_TEXT
    call    draw_small
    lea     rdi, [rip+wd_st_job]        # (ui_tree: it is there)
    mov     esi, r12d
    mov     edx, [rip+cont_y1]
    mov     ecx, r13d
    lea     r8, [rip+toast_dummy]
    xor     r9d, r9d
    call    wg
    sub     r12d, 6
    pop     r14
    pop     r13
    pop     rbx
    ret

# chip(rdi=text, rsi=widget to click or 0; r12d = right edge, moved left)
chip:
    push    rbx
    push    r13
    push    r14
    mov     rbx, rdi
    mov     r14, rsi
    call    text_width_small
    lea     r13d, [rax+16]
    sub     r12d, r13d
    mov     edi, r12d
    mov     esi, [rip+cont_y1]
    add     esi, 3
    mov     edx, r13d
    mov     ecx, STATUS_H-6
    mov     r8d, COL_MENU_BG
    mov     r9d, (STATUS_H-6)/2
    call    fill_rrect
    lea     edi, [r12+8]
    mov     esi, [rip+cont_y1]
    add     esi, 3
    mov     rdx, rbx
    mov     ecx, COL_TEXT_DIM
    call    draw_small
    test    r14, r14
    jz      1f
    mov     rdi, r14
    mov     esi, r12d
    mov     edx, [rip+cont_y1]
    mov     ecx, r13d
    lea     r8, [rip+toast_dummy]
    xor     r9d, r9d
    call    wg
1:  sub     r12d, 6
    pop     r14
    pop     r13
    pop     rbx
    ret

# text_width_small(rdi=text) -> eax
.globl text_width_small
text_width_small:
    push    rbx
    push    rdi
    mov     edi, FONT_SMALL
    call    text_use
    mov     ebx, eax
    pop     rdi
    call    text_width
    push    rax
    mov     edi, ebx
    call    text_use
    pop     rax
    pop     rbx
    ret

cpy_s:                                  # rdi = dest, rsi = text (95 max)
    xor     ecx, ecx
1:  mov     al, [rsi+rcx]
    mov     [rdi+rcx], al
    test    al, al
    jz      2f
    inc     ecx
    cmp     ecx, 95
    jb      1b
    mov     byte ptr [rdi+rcx], 0
2:  ret

# scene_stats - stat_buf = "3 objects  1,234 faces"
.globl scene_stats
.globl stat_buf
scene_stats:
    push    rbx
    push    r12
    sub     rsp, 8
    xor     ebx, ebx
    xor     r12d, r12d                  # faces
1:  cmp     ebx, [rip+obj_count]
    jae     2f
    mov     edi, ebx
    call    obj_at
    cmp     dword ptr [rax+OB_TYPE], OT_MESH
    jne     11f
    mov     rax, [rax+OB_MESH]
    test    rax, rax
    jz      11f
    add     r12d, [rax+ME_NPOLYS]
11: inc     ebx
    jmp     1b
2:  call    fmt_reset
    mov     edi, [rip+obj_count]
    call    fmt_int
    lea     rdi, [rip+s_objects]
    cmp     dword ptr [rip+obj_count], 1
    jne     3f
    lea     rdi, [rip+s_object1]
3:  call    fmt_str
    mov     edi, r12d
    call    fmt_int
    lea     rdi, [rip+s_faces]
    call    fmt_str
    lea     rdi, [rip+stat_buf]
    lea     rsi, [rip+fmt_buf]
    call    cpy_s
    add     rsp, 8
    pop     r12
    pop     rbx
    ret

# hints_now -> rax = the key / word pairs for what is going on
hints_now:
    lea     rax, [rip+h_tm]
    cmp     dword ptr [rip+tm_mode], 0
    jne     9f
    lea     rax, [rip+h_play]
    cmp     dword ptr [rip+pl_on], 0
    jne     9f
    lea     rax, [rip+h_sketch]
    cmp     dword ptr [rip+skm_obj], 0
    jne     9f
    lea     rax, [rip+h_sculpt]
    cmp     dword ptr [rip+sc_obj], 0
    jne     9f
    lea     rax, [rip+h_paint]
    cmp     dword ptr [rip+pt_obj], 0
    jne     9f
    lea     rax, [rip+h_edit]
    cmp     dword ptr [rip+edit_obj], 0
    jne     9f
    lea     rax, [rip+h_object]
9:  ret

.section .note.GNU-stack,"",@progbits
