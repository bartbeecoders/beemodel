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
.globl toast_tick
.globl toast_on
.globl toast_warn

.equ TOAST_MS,  4000

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

.section .rodata
s_lk_serve:     .asciz "Live link: serving"
s_lk_mirror:    .asciz "Live link: mirroring"
.align 4
sf_100:         .float 100.0

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
s_render:       .asciz "Render "
s_pct:          .asciz "%"
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
WIDGET wd_st_job,   WK_BUTTON, "status.job", "Job", flags=WGF_NODRAW, tip="A long job: the window answers again when it is done"
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
5:  call    fmt_reset                   # the AI's permission
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
1:  lea     rdi, [rip+stat_buf]
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
    jb      2f
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
