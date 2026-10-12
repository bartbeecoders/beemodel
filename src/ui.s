# =============================================================================
#  BeeModel - application shell: layout, client-side decorations, menus,
#  resizable panes, hit testing, input handling and the console log.
# =============================================================================

.section .data
.align 4
left_w:         .long 210
right_w:        .long 260
bottom_h:       .long 150
show_left:      .long 1
show_right:     .long 1
show_bottom:    .long 1
show_grid:      .long 1
menu_open:      .long -1
active_tool:    .long 0
selected_obj:   .long 3

.section .bss
.align 4
ptr_x:          .skip 4
ptr_y:          .skip 4
hover_id:       .skip 4
hover_idx:      .skip 4
press_id:       .skip 4
drag_mode:      .skip 4
enter_serial:   .skip 4
cur_shape:      .skip 4
key_mods:       .skip 4
last_click:     .skip 4
press_serial:   .skip 4
# layout (recomputed by ui_layout)
cont_y0:        .skip 4
cont_y1:        .skip 4
lx1:            .skip 4
mx0:            .skip 4
mx1:            .skip 4
rx0:            .skip 4
by0:            .skip 4
cvs_x0:         .skip 4
cvs_y0:         .skip 4
cvs_x1:         .skip 4
cvs_y1:         .skip 4
menu_x:         .skip 4*(NUM_MENUS+1)
drop_x:         .skip 4
drop_y:         .skip 4
drop_w:         .skip 4
drop_h:         .skip 4
# console ring buffer + string builder
log_head:       .skip 4
fmt_pos:        .skip 4
log_buf:        .skip LOG_LINES*LOG_LINE_LEN
fmt_buf:        .skip 128

.section .rodata
s_app_title:    .asciz "BeeModel"
s_app_id:       .asciz "beemodel"
s_title_sub:    .asciz "  -  untitled scene"

s_m_file:       .asciz "File"
s_m_edit:       .asciz "Edit"
s_m_view:       .asciz "View"
s_m_create:     .asciz "Create"
s_m_help:       .asciz "Help"

s_i_new:        .asciz "New Scene"
s_i_open:       .asciz "Open..."
s_i_save:       .asciz "Save"
s_i_exit:       .asciz "Exit"
s_i_undo:       .asciz "Undo"
s_i_redo:       .asciz "Redo"
s_i_prefs:      .asciz "Preferences..."
s_i_tleft:      .asciz "Tools Pane"
s_i_tright:     .asciz "Outliner Pane"
s_i_tbottom:    .asciz "Console Pane"
s_i_grid:       .asciz "Ground Grid"
s_i_resetcam:   .asciz "Reset Camera"
s_i_about:      .asciz "About BeeModel"
s_i_keys:       .asciz "Keyboard Shortcuts"

s_k_ctrl_n:     .asciz "Ctrl+N"
s_k_ctrl_o:     .asciz "Ctrl+O"
s_k_ctrl_s:     .asciz "Ctrl+S"
s_k_ctrl_q:     .asciz "Ctrl+Q"
s_k_ctrl_z:     .asciz "Ctrl+Z"
s_k_ctrl_y:     .asciz "Ctrl+Y"
s_k_g:          .asciz "G"
s_k_f:          .asciz "F"

s_t_select:     .asciz "Select"
s_t_move:       .asciz "Move"
s_t_rotate:     .asciz "Rotate"
s_t_scale:      .asciz "Scale"
s_t_cube:       .asciz "Cube"
s_t_sphere:     .asciz "Sphere"
s_t_cylinder:   .asciz "Cylinder"
s_t_plane:      .asciz "Plane"
s_t_light:      .asciz "Light"
s_t_camera:     .asciz "Camera"
s_t_grid:       .asciz "Grid"
s_k_q:          .asciz "Q"
s_k_w:          .asciz "W"
s_k_e:          .asciz "E"
s_k_r:          .asciz "R"

s_h_tools:      .asciz "TOOLS"
s_h_create:     .asciz "CREATE"
s_h_outliner:   .asciz "OUTLINER"
s_h_props:      .asciz "PROPERTIES"
s_h_console:    .asciz "CONSOLE"

s_p_camera:     .asciz "Viewport camera"
s_p_yaw:        .asciz "Yaw"
s_p_pitch:      .asciz "Pitch"
s_p_dist:       .asciz "Distance"
s_p_target:     .asciz "Target"
s_p_canvas:     .asciz "Canvas"
s_p_grid:       .asciz "Grid"
s_on:           .asciz "on"
s_off:          .asciz "off"
s_deg:          .asciz " deg"
s_comma:        .asciz ", "
s_x:            .asciz " x "
s_kib:          .asciz " KiB framebuffer   "
s_ready:        .asciz "Ready"

s_log_prompt:   .asciz "> "
s_log_tool:     .asciz "> Tool: "
s_log_sel:      .asciz "> Selected: "
s_log_todo:     .asciz "  not implemented yet - waiting for the modeling core"
s_log_create:   .asciz "  queued - mesh creation lands with the modeling core"
s_log_hello:    .asciz "BeeModel shell started - x86-64 assembly, Wayland, zero libraries"
s_log_hello2:   .asciz "Hint: drag the yellow-highlighted splitters to resize panes"
s_about1:       .asciz "  BeeModel 0.1 - a 3D modeling shell written in pure x86-64 assembly"
s_about2:       .asciz "  Talks the Wayland wire protocol directly; no libc, no toolkits"
s_keys1:        .asciz "  LMB drag orbit | MMB or Shift+LMB pan | wheel zoom"
s_keys2:        .asciz "  Q/W/E/R tools | G grid | F reset camera | Esc close menu | Ctrl+Q quit"

.align 8
menu_titles:    .quad s_m_file, s_m_edit, s_m_view, s_m_create, s_m_help
menu_items:     .quad items_file, items_edit, items_view, items_create, items_help
menu_counts:    .long 5, 4, 6, 6, 2

# item = cmd:u32, pad:u32, label:ptr, shortcut:ptr  (24 bytes)
.macro ITEM cmd, label, key
    .long \cmd, 0
    .quad \label, \key
.endm
.align 8
items_file:
    ITEM CMD_NEW,  s_i_new,  s_k_ctrl_n
    ITEM CMD_OPEN, s_i_open, s_k_ctrl_o
    ITEM CMD_SAVE, s_i_save, s_k_ctrl_s
    ITEM CMD_SEP,  0, 0
    ITEM CMD_EXIT, s_i_exit, s_k_ctrl_q
items_edit:
    ITEM CMD_UNDO,  s_i_undo,  s_k_ctrl_z
    ITEM CMD_REDO,  s_i_redo,  s_k_ctrl_y
    ITEM CMD_SEP,   0, 0
    ITEM CMD_PREFS, s_i_prefs, 0
items_view:
    ITEM CMD_TOGGLE_LEFT,   s_i_tleft,    0
    ITEM CMD_TOGGLE_RIGHT,  s_i_tright,   0
    ITEM CMD_TOGGLE_BOTTOM, s_i_tbottom,  0
    ITEM CMD_SEP,           0, 0
    ITEM CMD_TOGGLE_GRID,   s_i_grid,     s_k_g
    ITEM CMD_RESET_CAM,     s_i_resetcam, s_k_f
items_create:
    ITEM CMD_ADD_CUBE,   s_t_cube,     0
    ITEM CMD_ADD_SPHERE, s_t_sphere,   0
    ITEM CMD_ADD_CYL,    s_t_cylinder, 0
    ITEM CMD_ADD_PLANE,  s_t_plane,    0
    ITEM CMD_ADD_LIGHT,  s_t_light,    0
    ITEM CMD_ADD_CAMERA, s_t_camera,   0
items_help:
    ITEM CMD_SHORTCUTS, s_i_keys,  0
    ITEM CMD_ABOUT,     s_i_about, 0

tool_names:     .quad s_t_select, s_t_move, s_t_rotate, s_t_scale
                .quad s_t_cube, s_t_sphere, s_t_cylinder, s_t_plane, s_t_light, s_t_camera
tool_keys:      .quad s_k_q, s_k_w, s_k_e, s_k_r, 0, 0, 0, 0, 0, 0
outliner_names: .quad s_t_camera, s_t_light, s_t_grid, s_t_cube
outliner_cols:  .long 0x61afef, 0xe5c07b, 0x7f8794, COL_OBJECT

.text

# -----------------------------------------------------------------------------
# small helpers
# -----------------------------------------------------------------------------
# clamp(edi=v, esi=lo, edx=hi) -> eax  (lo wins if hi < lo)
clamp:
    mov     eax, edi
    cmp     eax, edx
    cmovg   eax, edx
    cmp     eax, esi
    cmovl   eax, esi
    ret

# tool_y(edi=i) -> eax
tool_y:
    mov     eax, edi
    imul    eax, TOOL_BTN_H+TOOL_BTN_GAP
    add     eax, [rip+cont_y0]
    add     eax, PANE_HDR_H+10
    cmp     edi, 4
    jb      1f
    add     eax, 28                     # room for the "CREATE" caption
1:  ret

# row_y(edi=i) -> eax  (outliner rows)
row_y:
    mov     eax, edi
    imul    eax, ROW_H
    add     eax, [rip+cont_y0]
    add     eax, PANE_HDR_H+4
    ret

# item_ptr(edi=menu, esi=index) -> rax
item_ptr:
    lea     rax, [rip+menu_items]
    mov     rax, [rax+rdi*8]
    lea     rcx, [rsi+rsi*2]
    lea     rax, [rax+rcx*8]
    ret

# -----------------------------------------------------------------------------
# String builder + console log
# -----------------------------------------------------------------------------
fmt_reset:
    mov     dword ptr [rip+fmt_pos], 0
    mov     byte ptr [rip+fmt_buf], 0
    ret

# fmt_char(edi=char)
fmt_char:
    mov     eax, [rip+fmt_pos]
    cmp     eax, 126
    jae     1f
    lea     rcx, [rip+fmt_buf]
    mov     [rcx+rax], dil
    mov     byte ptr [rcx+rax+1], 0
    inc     eax
    mov     [rip+fmt_pos], eax
1:  ret

# fmt_str(rdi=asciz)
fmt_str:
    push    rbx
    mov     rbx, rdi
1:  movzx   edi, byte ptr [rbx]
    test    edi, edi
    jz      2f
    call    fmt_char
    inc     rbx
    jmp     1b
2:  pop     rbx
    ret

# fmt_int(edi=signed int)
fmt_int:
    push    rbx
    sub     rsp, 16
    mov     eax, edi
    test    eax, eax
    jns     1f
    push    rax
    mov     edi, '-'
    call    fmt_char
    pop     rax
    neg     eax
1:  xor     ebx, ebx                    # digit count
    mov     ecx, 10
2:  xor     edx, edx
    div     ecx
    add     dl, '0'
    mov     [rsp+rbx], dl
    inc     ebx
    test    eax, eax
    jnz     2b
3:  dec     ebx
    movzx   edi, byte ptr [rsp+rbx]
    call    fmt_char
    test    ebx, ebx
    jnz     3b
    add     rsp, 16
    pop     rbx
    ret

# fmt_fix1(xmm0=float) - one decimal
fmt_fix1:
    push    rbx
    mulss   xmm0, [rip+f_ten]
    cvtss2si ebx, xmm0
    test    ebx, ebx
    jns     1f
    mov     edi, '-'
    call    fmt_char
    neg     ebx
1:  mov     eax, ebx
    xor     edx, edx
    mov     ecx, 10
    div     ecx
    mov     ebx, edx
    mov     edi, eax
    call    fmt_int
    mov     edi, '.'
    call    fmt_char
    lea     edi, [rbx+'0']
    call    fmt_char
    pop     rbx
    ret

# fmt_deg(xmm0=radians) - wrapped to [0,360)
fmt_deg:
    mulss   xmm0, [rip+f_rad2deg]
    mulss   xmm0, [rip+f_ten]
    cvtss2si eax, xmm0
    cdq
    mov     ecx, 3600
    idiv    ecx
    test    edx, edx
    jns     1f
    add     edx, 3600
1:  cvtsi2ss xmm0, edx
    divss   xmm0, [rip+f_ten]
    jmp     fmt_fix1

# log_line(rdi=asciz) - append to the console ring buffer
log_line:
    mov     eax, [rip+log_head]
    and     eax, LOG_LINES-1
    imul    eax, LOG_LINE_LEN
    lea     rdx, [rip+log_buf]
    add     rdx, rax
    xor     ecx, ecx
1:  mov     al, [rdi+rcx]
    mov     [rdx+rcx], al
    test    al, al
    jz      2f
    inc     ecx
    cmp     ecx, LOG_LINE_LEN-1
    jb      1b
    mov     byte ptr [rdx+rcx], 0
2:  inc     dword ptr [rip+log_head]
    mov     dword ptr [rip+dirty], 1
    ret

# log_pair(rdi=prefix, rsi=text)
log_pair:
    push    rbx
    mov     rbx, rsi
    push    rdi
    call    fmt_reset
    pop     rdi
    call    fmt_str
    mov     rdi, rbx
    call    fmt_str
    lea     rdi, [rip+fmt_buf]
    call    log_line
    pop     rbx
    ret

# -----------------------------------------------------------------------------
# ui_layout - derive every rectangle from window size + pane state
# -----------------------------------------------------------------------------
ui_layout:
    push    rbx
    push    r12
    push    r13
    mov     dword ptr [rip+cont_y0], TITLE_H+MENU_H
    mov     eax, [rip+win_h]
    sub     eax, STATUS_H
    mov     [rip+cont_y1], eax

    # horizontal: L / R widths with minimums, then shrink to fit the window
    xor     ebx, ebx                    # L
    xor     r12d, r12d                  # R
    mov     r13d, [rip+win_w]
    sub     r13d, MIN_CANVAS_W          # avail = W - splitters - min canvas
    cmp     dword ptr [rip+show_left], 0
    je      1f
    mov     ebx, [rip+left_w]
    mov     eax, MIN_LEFT
    cmp     ebx, eax
    cmovl   ebx, eax
    sub     r13d, SPLIT
1:  cmp     dword ptr [rip+show_right], 0
    je      2f
    mov     r12d, [rip+right_w]
    mov     eax, MIN_RIGHT
    cmp     r12d, eax
    cmovl   r12d, eax
    sub     r13d, SPLIT
2:  lea     eax, [rbx+r12]
    sub     eax, r13d                   # excess
    jle     4f
    test    r12d, r12d                  # take it from the right pane first
    jz      3f
    lea     ecx, [r12-MIN_RIGHT]
    cmp     ecx, eax
    cmova   ecx, eax
    sub     r12d, ecx
    sub     eax, ecx
3:  test    ebx, ebx
    jz      4f
    lea     ecx, [rbx-MIN_LEFT]
    cmp     ecx, eax
    cmova   ecx, eax
    sub     ebx, ecx
4:  cmp     dword ptr [rip+show_left], 0
    je      5f
    mov     [rip+left_w], ebx
5:  cmp     dword ptr [rip+show_right], 0
    je      6f
    mov     [rip+right_w], r12d
6:  mov     [rip+lx1], ebx
    xor     eax, eax
    test    ebx, ebx
    jz      7f
    lea     eax, [rbx+SPLIT]
7:  mov     [rip+mx0], eax
    mov     [rip+cvs_x0], eax
    mov     eax, [rip+win_w]
    sub     eax, r12d
    mov     [rip+rx0], eax
    test    r12d, r12d
    jz      8f
    sub     eax, SPLIT
8:  mov     [rip+mx1], eax
    mov     [rip+cvs_x1], eax

    # vertical: bottom console pane
    mov     dword ptr [rip+cvs_y0], TITLE_H+MENU_H
    mov     eax, [rip+cont_y1]
    cmp     dword ptr [rip+show_bottom], 0
    je      9f
    mov     edi, [rip+bottom_h]
    mov     esi, MIN_BOTTOM
    mov     edx, [rip+cont_y1]
    sub     edx, [rip+cont_y0]
    sub     edx, SPLIT+MIN_CANVAS_H
    call    clamp
    mov     [rip+bottom_h], eax
    mov     ecx, [rip+cont_y1]
    sub     ecx, eax
    mov     [rip+by0], ecx
    lea     eax, [rcx-SPLIT]
    jmp     10f
9:  mov     [rip+by0], eax
10: mov     [rip+cvs_y1], eax

    # menu bar title positions
    mov     ebx, 4
    xor     r12d, r12d
    lea     r13, [rip+menu_x]
11: mov     [r13+r12*4], ebx
    lea     rax, [rip+menu_titles]
    mov     rdi, [rax+r12*8]
    call    str_len
    lea     ebx, [rbx+rax*8+20]
    inc     r12d
    cmp     r12d, NUM_MENUS
    jb      11b
    mov     [r13+r12*4], ebx

    # dropdown rectangle
    mov     edi, [rip+menu_open]
    test    edi, edi
    js      14f
    mov     eax, [r13+rdi*4]
    mov     ecx, [rip+win_w]
    sub     ecx, MENU_DROP_W
    cmp     eax, ecx
    cmovg   eax, ecx
    mov     [rip+drop_x], eax
    mov     dword ptr [rip+drop_y], TITLE_H+MENU_H
    mov     dword ptr [rip+drop_w], MENU_DROP_W
    lea     rax, [rip+menu_counts]
    mov     ecx, [rax+rdi*4]
    lea     rax, [rip+menu_items]
    mov     rax, [rax+rdi*8]
    mov     edx, 8                      # 4px padding top + bottom
12: test    ecx, ecx
    jz      13f
    cmp     dword ptr [rax], CMD_SEP
    mov     esi, MENU_ITEM_H
    mov     edi, MENU_SEP_H
    cmove   esi, edi
    add     edx, esi
    add     rax, 24
    dec     ecx
    jmp     12b
13: mov     [rip+drop_h], edx
14: pop     r13
    pop     r12
    pop     rbx
    ret

# -----------------------------------------------------------------------------
# hit_test(edi=x, esi=y) -> eax = HIT_*, edx = index
# -----------------------------------------------------------------------------
hit_test:
    push    rbx
    push    r12
    push    r13
    push    r14
    mov     ebx, edi
    mov     r12d, esi
    call    ui_layout

    # open dropdown sits on top of everything
    mov     edi, [rip+menu_open]
    test    edi, edi
    js      .Lht_edges
    mov     eax, [rip+drop_x]
    cmp     ebx, eax
    jl      .Lht_edges
    add     eax, [rip+drop_w]
    cmp     ebx, eax
    jge     .Lht_edges
    mov     eax, [rip+drop_y]
    cmp     r12d, eax
    jl      .Lht_edges
    add     eax, [rip+drop_h]
    cmp     r12d, eax
    jge     .Lht_edges
    lea     rax, [rip+menu_counts]
    mov     r13d, [rax+rdi*4]
    lea     rax, [rip+menu_items]
    mov     r14, [rax+rdi*8]
    mov     ecx, [rip+drop_y]
    add     ecx, 4
    xor     edx, edx
1:  cmp     edx, r13d
    jae     3f
    mov     esi, MENU_ITEM_H
    cmp     dword ptr [r14], CMD_SEP
    jne     2f
    mov     esi, MENU_SEP_H
2:  add     ecx, esi
    cmp     r12d, ecx
    jl      4f
    add     r14, 24
    inc     edx
    jmp     1b
4:  mov     eax, HIT_MENU_ITEM
    cmp     dword ptr [r14], CMD_SEP
    jne     .Lht_ret
    mov     edx, -1
    jmp     .Lht_ret
3:  mov     eax, HIT_DROPDOWN
    mov     edx, -1
    jmp     .Lht_ret

.Lht_edges:
    test    dword ptr [rip+win_flags], 3
    jnz     .Lht_title
    xor     edx, edx
    cmp     r12d, EDGE
    jge     1f
    or      edx, 1
1:  mov     eax, [rip+win_h]
    sub     eax, EDGE
    cmp     r12d, eax
    jl      2f
    or      edx, 2
2:  cmp     ebx, EDGE
    jge     3f
    or      edx, 4
3:  mov     eax, [rip+win_w]
    sub     eax, EDGE
    cmp     ebx, eax
    jl      4f
    or      edx, 8
4:  mov     eax, HIT_EDGE
    test    edx, edx
    jnz     .Lht_ret

.Lht_title:
    xor     edx, edx
    cmp     r12d, TITLE_H
    jge     .Lht_menubar
    mov     ecx, [rip+win_w]
    sub     ecx, CAPTION_BTN_W
    mov     eax, HIT_BTN_CLOSE
    cmp     ebx, ecx
    jge     .Lht_ret
    sub     ecx, CAPTION_BTN_W
    mov     eax, HIT_BTN_MAX
    cmp     ebx, ecx
    jge     .Lht_ret
    sub     ecx, CAPTION_BTN_W
    mov     eax, HIT_BTN_MIN
    cmp     ebx, ecx
    jge     .Lht_ret
    mov     eax, HIT_TITLE
    jmp     .Lht_ret

.Lht_menubar:
    cmp     r12d, TITLE_H+MENU_H
    jge     .Lht_status
    lea     rcx, [rip+menu_x]
1:  cmp     edx, NUM_MENUS
    jae     2f
    cmp     ebx, [rcx+rdx*4]
    jl      2f
    cmp     ebx, [rcx+rdx*4+4]
    mov     eax, HIT_MENU_TITLE
    jl      .Lht_ret
    inc     edx
    jmp     1b
2:  mov     eax, HIT_MENUBAR
    xor     edx, edx
    jmp     .Lht_ret

.Lht_status:
    mov     eax, HIT_PANE
    mov     edx, 3
    cmp     r12d, [rip+cont_y1]
    jge     .Lht_ret

    cmp     dword ptr [rip+show_left], 0
    je      .Lht_right
    cmp     ebx, [rip+lx1]
    jge     2f
    xor     r13d, r13d                  # tool buttons
    cmp     ebx, 8
    jl      3f
    mov     eax, [rip+lx1]
    sub     eax, 8
    cmp     ebx, eax
    jge     3f
1:  mov     edi, r13d
    call    tool_y
    cmp     r12d, eax
    jl      4f
    add     eax, TOOL_BTN_H
    cmp     r12d, eax
    jge     4f
    mov     eax, HIT_TOOL
    mov     edx, r13d
    jmp     .Lht_ret
4:  inc     r13d
    cmp     r13d, NUM_TOOLS
    jb      1b
3:  mov     eax, HIT_PANE
    xor     edx, edx
    jmp     .Lht_ret
2:  mov     eax, HIT_SPLIT_L
    cmp     ebx, [rip+mx0]
    jl      .Lht_ret

.Lht_right:
    cmp     dword ptr [rip+show_right], 0
    je      .Lht_bottom
    cmp     ebx, [rip+rx0]
    jl      2f
    xor     r13d, r13d
1:  mov     edi, r13d
    call    row_y
    cmp     r12d, eax
    jl      3f
    add     eax, ROW_H
    cmp     r12d, eax
    jge     3f
    mov     eax, HIT_OUTLINER
    mov     edx, r13d
    jmp     .Lht_ret
3:  inc     r13d
    cmp     r13d, NUM_OUTLINER
    jb      1b
    mov     eax, HIT_PANE
    mov     edx, 1
    jmp     .Lht_ret
2:  mov     eax, HIT_SPLIT_R
    cmp     ebx, [rip+mx1]
    jge     .Lht_ret

.Lht_bottom:
    cmp     dword ptr [rip+show_bottom], 0
    je      .Lht_canvas
    mov     eax, HIT_PANE
    mov     edx, 2
    cmp     r12d, [rip+by0]
    jge     .Lht_ret
    mov     eax, HIT_SPLIT_B
    cmp     r12d, [rip+cvs_y1]
    jge     .Lht_ret
.Lht_canvas:
    mov     eax, HIT_CANVAS
    xor     edx, edx
.Lht_ret:
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# cursor_for(edi=hit id, esi=index) -> eax = cursor shape
cursor_for:
    mov     eax, CUR_EW
    cmp     edi, HIT_SPLIT_L
    je      9f
    cmp     edi, HIT_SPLIT_R
    je      9f
    mov     eax, CUR_NS
    cmp     edi, HIT_SPLIT_B
    je      9f
    mov     eax, CUR_CROSSHAIR
    cmp     edi, HIT_CANVAS
    je      9f
    mov     eax, CUR_DEFAULT
    cmp     edi, HIT_EDGE
    jne     9f
    lea     rax, [rip+edge_cursors]
    movzx   eax, byte ptr [rax+rsi]
9:  ret

.section .rodata
#                    0  T  B  -  L  TL BL -  R  TR BR
edge_cursors: .byte  1, 27,27, 1,26,29,28, 1,26,28,29, 1, 1, 1, 1, 1
.text

# -----------------------------------------------------------------------------
# Input: pointer motion / leave / button / axis, keyboard
# -----------------------------------------------------------------------------
# ui_motion(edi=x, esi=y)
ui_motion:
    push    rbx
    push    r12
    push    r13
    mov     ebx, edi
    sub     ebx, [rip+ptr_x]            # dx
    mov     r12d, esi
    sub     r12d, [rip+ptr_y]           # dy
    mov     [rip+ptr_x], edi
    mov     [rip+ptr_y], esi

    mov     eax, [rip+drag_mode]
    test    eax, eax
    jz      .Lmo_hover
    mov     dword ptr [rip+dirty], 1
    cmp     eax, DRAG_SPLIT_L
    jne     1f
    sub     edi, SPLIT/2
    mov     edx, [rip+win_w]
    sub     edx, SPLIT+MIN_CANVAS_W
    cmp     dword ptr [rip+show_right], 0
    je      11f
    sub     edx, [rip+right_w]
    sub     edx, SPLIT
11: mov     esi, MIN_LEFT
    call    clamp
    mov     [rip+left_w], eax
    mov     edi, CUR_EW
    jmp     .Lmo_cursor
1:  cmp     eax, DRAG_SPLIT_R
    jne     2f
    mov     eax, [rip+win_w]
    sub     eax, edi
    sub     eax, SPLIT/2
    mov     edi, eax
    mov     edx, [rip+win_w]
    sub     edx, SPLIT+MIN_CANVAS_W
    cmp     dword ptr [rip+show_left], 0
    je      21f
    sub     edx, [rip+left_w]
    sub     edx, SPLIT
21: mov     esi, MIN_RIGHT
    call    clamp
    mov     [rip+right_w], eax
    mov     edi, CUR_EW
    jmp     .Lmo_cursor
2:  cmp     eax, DRAG_SPLIT_B
    jne     3f
    mov     eax, [rip+cont_y1]
    sub     eax, esi
    sub     eax, SPLIT/2
    mov     [rip+bottom_h], eax         # clamped by ui_layout
    mov     edi, CUR_NS
    jmp     .Lmo_cursor
3:  cmp     eax, DRAG_ORBIT
    jne     4f
    mov     edi, ebx
    mov     esi, r12d
    call    vp_orbit
    mov     edi, CUR_GRABBING
    jmp     .Lmo_cursor
4:  mov     edi, ebx
    mov     esi, r12d
    call    vp_pan
    mov     edi, CUR_MOVE
    jmp     .Lmo_cursor

.Lmo_hover:
    mov     edi, [rip+ptr_x]
    mov     esi, [rip+ptr_y]
    call    hit_test
    mov     r13d, eax
    # sliding across the menu bar while a menu is open switches menus
    cmp     eax, HIT_MENU_TITLE
    jne     1f
    mov     ecx, [rip+menu_open]
    test    ecx, ecx
    js      1f
    cmp     ecx, edx
    je      1f
    mov     [rip+menu_open], edx
    mov     dword ptr [rip+dirty], 1
1:  cmp     r13d, [rip+hover_id]
    jne     2f
    cmp     edx, [rip+hover_idx]
    je      3f
2:  mov     [rip+hover_id], r13d
    mov     [rip+hover_idx], edx
    mov     dword ptr [rip+dirty], 1
3:  mov     edi, r13d
    mov     esi, edx
    call    cursor_for
    mov     edi, eax
.Lmo_cursor:
    call    set_cursor
    pop     r13
    pop     r12
    pop     rbx
    ret

ui_leave:
    mov     dword ptr [rip+hover_id], HIT_NONE
    mov     dword ptr [rip+hover_idx], -1
    mov     dword ptr [rip+cur_shape], 0
    mov     dword ptr [rip+dirty], 1
    ret

toggle_maximize:
    mov     edi, [rip+id_toplevel]
    mov     esi, XDG_TOPLEVEL_SET_MAXIMIZED
    test    dword ptr [rip+win_flags], 1
    jz      1f
    mov     esi, XDG_TOPLEVEL_UNSET_MAXIMIZED
1:  jmp     msg0

# ui_button(edi=button, esi=state, edx=serial, ecx=time)
ui_button:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    mov     r14d, edi
    mov     r15d, esi
    mov     r13d, ecx
    mov     [rip+press_serial], edx
    mov     edi, [rip+ptr_x]
    mov     esi, [rip+ptr_y]
    call    hit_test
    mov     ebx, eax
    mov     r12d, edx
    mov     dword ptr [rip+dirty], 1
    test    r15d, r15d
    jz      .Lbt_release

    # ---------------- press ----------------
    mov     eax, [rip+menu_open]
    test    eax, eax
    js      .Lbt_nomenu
    cmp     ebx, HIT_MENU_ITEM          # items fire on release
    je      .Lbt_done
    cmp     ebx, HIT_DROPDOWN
    je      .Lbt_done
    cmp     ebx, HIT_MENU_TITLE
    jne     1f
    cmp     eax, r12d
    jne     2f
1:  mov     r12d, -1                    # click outside / on open title: close
2:  mov     [rip+menu_open], r12d
    jmp     .Lbt_done

.Lbt_nomenu:
    cmp     r14d, BTN_MIDDLE
    jne     1f
    cmp     ebx, HIT_CANVAS
    jne     .Lbt_done
    mov     dword ptr [rip+drag_mode], DRAG_PAN
    mov     edi, CUR_MOVE
    call    set_cursor
    jmp     .Lbt_done
1:  cmp     r14d, BTN_LEFT
    jne     .Lbt_done

    cmp     ebx, HIT_EDGE
    jne     1f
    mov     edi, [rip+id_toplevel]
    mov     esi, XDG_TOPLEVEL_RESIZE
    mov     edx, [rip+id_seat]
    mov     ecx, [rip+press_serial]
    mov     r8d, r12d
    call    msg3
    jmp     .Lbt_done
1:  cmp     ebx, HIT_TITLE
    jne     2f
    mov     eax, r13d                   # double click toggles maximize
    sub     eax, [rip+last_click]
    cmp     dword ptr [rip+last_click], 0
    je      11f
    cmp     eax, 400
    ja      11f
    mov     dword ptr [rip+last_click], 0
    call    toggle_maximize
    jmp     .Lbt_done
11: mov     [rip+last_click], r13d
    mov     edi, [rip+id_toplevel]
    mov     esi, XDG_TOPLEVEL_MOVE
    mov     edx, [rip+id_seat]
    mov     ecx, [rip+press_serial]
    call    msg2
    jmp     .Lbt_done
2:  cmp     ebx, HIT_BTN_MIN
    jb      3f
    cmp     ebx, HIT_BTN_CLOSE
    ja      3f
    mov     [rip+press_id], ebx         # caption buttons act on release
    jmp     .Lbt_done
3:  cmp     ebx, HIT_MENU_TITLE
    jne     4f
    mov     [rip+menu_open], r12d
    jmp     .Lbt_done
4:  cmp     ebx, HIT_SPLIT_L
    jb      5f
    cmp     ebx, HIT_SPLIT_B
    ja      5f
    lea     eax, [rbx-HIT_SPLIT_L+DRAG_SPLIT_L]
    mov     [rip+drag_mode], eax
    jmp     .Lbt_done
5:  cmp     ebx, HIT_CANVAS
    jne     6f
    mov     eax, DRAG_ORBIT
    mov     ecx, DRAG_PAN
    test    dword ptr [rip+key_mods], MOD_SHIFT
    cmovnz  eax, ecx
    mov     [rip+drag_mode], eax
    mov     edi, [rip+ptr_x]
    mov     esi, [rip+ptr_y]
    call    ui_motion                   # update the cursor
    jmp     .Lbt_done
6:  cmp     ebx, HIT_TOOL
    jne     7f
    mov     edi, r12d
    call    tool_activate
    jmp     .Lbt_done
7:  cmp     ebx, HIT_OUTLINER
    jne     .Lbt_done
    mov     [rip+selected_obj], r12d
    lea     rax, [rip+outliner_names]
    mov     rsi, [rax+r12*8]
    lea     rdi, [rip+s_log_sel]
    call    log_pair
    jmp     .Lbt_done

    # ---------------- release ----------------
.Lbt_release:
    cmp     dword ptr [rip+drag_mode], 0
    je      1f
    mov     dword ptr [rip+drag_mode], 0
    mov     edi, [rip+ptr_x]
    mov     esi, [rip+ptr_y]
    call    ui_motion
1:  mov     eax, [rip+press_id]
    mov     dword ptr [rip+press_id], 0
    test    eax, eax
    jz      2f
    cmp     eax, ebx
    jne     .Lbt_done
    cmp     eax, HIT_BTN_CLOSE
    jne     11f
    mov     dword ptr [rip+quit_flag], 1
    jmp     .Lbt_done
11: cmp     eax, HIT_BTN_MAX
    jne     12f
    call    toggle_maximize
    jmp     .Lbt_done
12: mov     edi, [rip+id_toplevel]
    mov     esi, XDG_TOPLEVEL_SET_MINIMIZED
    call    msg0
    jmp     .Lbt_done
2:  cmp     dword ptr [rip+menu_open], 0
    jl      .Lbt_done
    cmp     ebx, HIT_MENU_ITEM
    jne     .Lbt_done
    test    r12d, r12d
    js      .Lbt_done
    mov     edi, [rip+menu_open]
    mov     esi, r12d
    call    item_ptr
    mov     dword ptr [rip+menu_open], -1
    mov     edi, [rax]
    mov     rsi, [rax+8]
    call    exec_cmd
.Lbt_done:
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# ui_axis(edi=axis, esi=value 24.8 fixed)
ui_axis:
    test    edi, edi
    jnz     9f
    test    esi, esi
    jz      9f
    push    rsi
    mov     edi, [rip+ptr_x]
    mov     esi, [rip+ptr_y]
    call    hit_test
    pop     rdi
    cmp     eax, HIT_CANVAS
    jne     9f
    call    vp_zoom
    mov     dword ptr [rip+dirty], 1
9:  ret

# ui_key(edi=evdev key, esi=state)
ui_key:
    cmp     esi, 1
    jne     9f
    cmp     edi, KEY_ESC
    jne     1f
    mov     dword ptr [rip+menu_open], -1
    mov     dword ptr [rip+dirty], 1
    ret
1:  test    dword ptr [rip+key_mods], MOD_CTRL
    jz      2f
    cmp     edi, KEY_Q
    jne     9f
    mov     dword ptr [rip+quit_flag], 1
    ret
2:  cmp     edi, KEY_Q                  # Q W E R = evdev 16..19 -> tools 0..3
    jb      3f
    cmp     edi, KEY_Q+3
    ja      3f
    sub     edi, KEY_Q
    jmp     tool_activate
3:  mov     esi, 0
    cmp     edi, KEY_G
    jne     4f
    mov     edi, CMD_TOGGLE_GRID
    lea     rsi, [rip+s_i_grid]
    jmp     exec_cmd
4:  cmp     edi, KEY_F
    jne     9f
    mov     edi, CMD_RESET_CAM
    lea     rsi, [rip+s_i_resetcam]
    jmp     exec_cmd
9:  ret

# tool_activate(edi=tool index)
tool_activate:
    push    rbx
    mov     ebx, edi
    lea     rax, [rip+tool_names]
    mov     rsi, [rax+rbx*8]
    cmp     ebx, 4
    jae     1f
    mov     [rip+active_tool], ebx
    lea     rdi, [rip+s_log_tool]
    call    log_pair
    pop     rbx
    ret
1:  lea     edi, [rbx-4+CMD_ADD_CUBE]
    call    exec_cmd
    pop     rbx
    ret

# -----------------------------------------------------------------------------
# exec_cmd(edi=command, rsi=label)
# -----------------------------------------------------------------------------
exec_cmd:
    push    rbx
    mov     ebx, edi
    lea     rdi, [rip+s_log_prompt]
    call    log_pair
    mov     dword ptr [rip+dirty], 1
    cmp     ebx, CMD_EXIT
    jne     1f
    mov     dword ptr [rip+quit_flag], 1
    jmp     9f
1:  cmp     ebx, CMD_TOGGLE_LEFT
    jne     2f
    xor     dword ptr [rip+show_left], 1
    jmp     9f
2:  cmp     ebx, CMD_TOGGLE_RIGHT
    jne     3f
    xor     dword ptr [rip+show_right], 1
    jmp     9f
3:  cmp     ebx, CMD_TOGGLE_BOTTOM
    jne     4f
    xor     dword ptr [rip+show_bottom], 1
    jmp     9f
4:  cmp     ebx, CMD_TOGGLE_GRID
    jne     5f
    xor     dword ptr [rip+show_grid], 1
    jmp     9f
5:  cmp     ebx, CMD_RESET_CAM
    jne     6f
    call    vp_reset
    jmp     9f
6:  cmp     ebx, CMD_ABOUT
    jne     7f
    lea     rdi, [rip+s_about1]
    call    log_line
    lea     rdi, [rip+s_about2]
    call    log_line
    jmp     9f
7:  cmp     ebx, CMD_SHORTCUTS
    jne     8f
    lea     rdi, [rip+s_keys1]
    call    log_line
    lea     rdi, [rip+s_keys2]
    call    log_line
    jmp     9f
8:  lea     rdi, [rip+s_log_todo]
    cmp     ebx, CMD_ADD_CUBE
    jb      81f
    cmp     ebx, CMD_ADD_CAMERA
    ja      81f
    lea     rdi, [rip+s_log_create]
81: call    log_line
9:  pop     rbx
    ret

# cmd_checked(edi=cmd) -> eax = 1 checked, 0 unchecked, -1 not a toggle
cmd_checked:
    lea     rax, [rip+show_left]
    cmp     edi, CMD_TOGGLE_LEFT
    je      1f
    lea     rax, [rip+show_right]
    cmp     edi, CMD_TOGGLE_RIGHT
    je      1f
    lea     rax, [rip+show_bottom]
    cmp     edi, CMD_TOGGLE_BOTTOM
    je      1f
    lea     rax, [rip+show_grid]
    cmp     edi, CMD_TOGGLE_GRID
    je      1f
    mov     eax, -1
    ret
1:  mov     eax, [rax]
    ret

# =============================================================================
#  Drawing
# =============================================================================
ui_draw:
    call    ui_layout
    call    reset_clip
    call    draw_titlebar
    call    draw_menubar
    cmp     dword ptr [rip+show_left], 0
    je      1f
    call    draw_left_pane
1:  cmp     dword ptr [rip+show_right], 0
    je      2f
    call    draw_right_pane
2:  cmp     dword ptr [rip+show_bottom], 0
    je      3f
    call    draw_bottom_pane
3:  call    viewport_draw
    call    draw_statusbar
    cmp     dword ptr [rip+menu_open], 0
    jl      4f
    call    draw_dropdown
4:  ret

# is_hot(edi=hit id, esi=index) -> eax = 1 if hovered
is_hot:
    xor     eax, eax
    cmp     edi, [rip+hover_id]
    jne     1f
    cmp     esi, [rip+hover_idx]
    jne     1f
    inc     eax
1:  ret

# splitter_color(edi=hit id, esi=drag mode) -> eax
splitter_color:
    mov     eax, COL_SPLIT_HOT
    cmp     esi, [rip+drag_mode]
    je      1f
    cmp     edi, [rip+hover_id]
    je      1f
    mov     eax, COL_SPLIT
1:  ret

# pane_header(edi=x, esi=y, edx=w, rcx=title)
pane_header:
    push    rbx
    push    r12
    push    r13
    mov     ebx, edi
    mov     r12d, esi
    mov     r13, rcx
    mov     ecx, PANE_HDR_H
    mov     r8d, COL_PANE_HDR
    call    fill_rect
    mov     edi, ebx
    mov     esi, r12d
    mov     edx, 3
    mov     ecx, PANE_HDR_H
    mov     r8d, COL_ACCENT
    call    fill_rect
    lea     edi, [rbx+12]
    lea     esi, [r12+4]
    mov     rdx, r13
    mov     ecx, COL_TEXT_DIM
    call    draw_text
    pop     r13
    pop     r12
    pop     rbx
    ret

# ---- title bar ---------------------------------------------------------------
draw_titlebar:
    push    rbx
    push    r12
    push    r13
    xor     edi, edi
    xor     esi, esi
    mov     edx, [rip+win_w]
    mov     ecx, TITLE_H
    mov     r8d, COL_TITLE_BG
    call    fill_rect

    # honeycomb cell logo
    lea     rbx, [rip+logo_rows]
    xor     r12d, r12d
1:  movzx   edi, byte ptr [rbx+r12*4]
    movzx   esi, byte ptr [rbx+r12*4+1]
    movzx   edx, byte ptr [rbx+r12*4+2]
    movzx   ecx, byte ptr [rbx+r12*4+3]
    mov     r8d, COL_ACCENT
    call    fill_rect
    inc     r12d
    cmp     r12d, 5
    jb      1b
    mov     edi, 17
    mov     esi, 14
    mov     edx, 4
    mov     ecx, 4
    mov     r8d, COL_TITLE_BG
    call    fill_rect

    mov     edi, 36
    mov     esi, 8
    lea     rdx, [rip+s_app_title]
    mov     ecx, COL_ACCENT
    call    draw_text
    mov     edi, eax
    mov     esi, 8
    lea     rdx, [rip+s_title_sub]
    mov     ecx, COL_TEXT_DIM
    call    draw_text

    # caption buttons: minimize, maximize, close
    mov     ebx, [rip+win_w]
    sub     ebx, 3*CAPTION_BTN_W        # x of first button
    xor     r12d, r12d
2:  lea     edi, [r12+HIT_BTN_MIN]
    cmp     edi, [rip+hover_id]
    jne     3f
    mov     r8d, COL_HOVER
    cmp     r12d, 2
    jne     21f
    mov     r8d, COL_CLOSE_HOT
21: mov     edi, ebx
    xor     esi, esi
    mov     edx, CAPTION_BTN_W
    mov     ecx, TITLE_H
    call    fill_rect
3:  lea     r13d, [rbx+CAPTION_BTN_W/2] # icon centre x
    cmp     r12d, 0
    jne     4f
    lea     edi, [r13-5]                # minimize: bar
    mov     esi, TITLE_H/2
    mov     edx, 10
    mov     ecx, 1
    mov     r8d, COL_TITLE_TEXT
    call    fill_rect
    jmp     8f
4:  cmp     r12d, 1
    jne     6f
    test    dword ptr [rip+win_flags], 1
    jnz     5f
    lea     edi, [r13-5]                # maximize: box
    mov     esi, TITLE_H/2-5
    mov     edx, 10
    mov     ecx, 10
    mov     r8d, COL_TITLE_TEXT
    call    rect_outline
    jmp     8f
5:  lea     edi, [r13-3]                # restore: two boxes
    mov     esi, TITLE_H/2-6
    mov     edx, 9
    mov     ecx, 9
    mov     r8d, COL_TITLE_TEXT
    call    rect_outline
    lea     edi, [r13-6]
    mov     esi, TITLE_H/2-3
    mov     edx, 9
    mov     ecx, 9
    mov     r8d, COL_TITLE_BG
    mov     eax, HIT_BTN_MAX
    cmp     eax, [rip+hover_id]
    jne     51f
    mov     r8d, COL_HOVER
51: call    fill_rect
    lea     edi, [r13-6]
    mov     esi, TITLE_H/2-3
    mov     edx, 9
    mov     ecx, 9
    mov     r8d, COL_TITLE_TEXT
    call    rect_outline
    jmp     8f
6:  lea     edi, [r13-5]                # close: X
    mov     esi, TITLE_H/2-5
    lea     edx, [r13+5]
    mov     ecx, TITLE_H/2+5
    mov     r8d, COL_TITLE_TEXT
    call    draw_line
    lea     edi, [r13-5]
    mov     esi, TITLE_H/2+5
    lea     edx, [r13+5]
    mov     ecx, TITLE_H/2-5
    mov     r8d, COL_TITLE_TEXT
    call    draw_line
8:  add     ebx, CAPTION_BTN_W
    inc     r12d
    cmp     r12d, 3
    jb      2b
    pop     r13
    pop     r12
    pop     rbx
    ret

.section .rodata
#               x  y  w  h      (14x14 hexagon at 12,9)
logo_rows: .byte 16, 9,  6, 2
           .byte 14,11, 10, 2
           .byte 12,13, 14, 6
           .byte 14,19, 10, 2
           .byte 16,21,  6, 2
.text

# ---- menu bar ----------------------------------------------------------------
draw_menubar:
    push    rbx
    push    r12
    push    r13
    xor     edi, edi
    mov     esi, TITLE_H
    mov     edx, [rip+win_w]
    mov     ecx, MENU_H
    mov     r8d, COL_MENU_BG
    call    fill_rect
    xor     ebx, ebx
    lea     r12, [rip+menu_x]
1:  mov     r13d, COL_TEXT
    mov     edi, [r12+rbx*4]
    mov     edx, [r12+rbx*4+4]
    sub     edx, edi
    cmp     ebx, [rip+menu_open]
    jne     2f
    mov     r13d, COL_ACCENT
    mov     esi, TITLE_H+2
    mov     ecx, MENU_H-2
    mov     r8d, COL_DROP_BG
    call    fill_rect
    jmp     3f
2:  push    rdi
    push    rdx
    mov     edi, HIT_MENU_TITLE
    mov     esi, ebx
    call    is_hot
    pop     rdx
    pop     rdi
    test    eax, eax
    jz      3f
    mov     esi, TITLE_H+2
    mov     ecx, MENU_H-4
    mov     r8d, COL_HOVER
    call    fill_rect
3:  mov     edi, [r12+rbx*4]
    add     edi, 10
    mov     esi, TITLE_H+4
    lea     rax, [rip+menu_titles]
    mov     rdx, [rax+rbx*8]
    mov     ecx, r13d
    call    draw_text
    inc     ebx
    cmp     ebx, NUM_MENUS
    jb      1b
    xor     edi, edi
    mov     esi, TITLE_H+MENU_H-1
    mov     edx, [rip+win_w]
    mov     ecx, 1
    mov     r8d, COL_SPLIT
    call    fill_rect
    pop     r13
    pop     r12
    pop     rbx
    ret

# ---- left pane: tools ----------------------------------------------------------
draw_left_pane:
    push    rbx
    push    r12
    push    r13
    push    r14
    xor     edi, edi
    mov     esi, [rip+cont_y0]
    mov     edx, [rip+lx1]
    mov     ecx, [rip+cont_y1]
    sub     ecx, esi
    mov     r8d, COL_PANE_BG
    call    fill_rect
    xor     edi, edi
    mov     esi, [rip+cont_y0]
    mov     edx, [rip+lx1]
    mov     ecx, [rip+cont_y1]
    call    set_clip
    xor     edi, edi
    mov     esi, [rip+cont_y0]
    mov     edx, [rip+lx1]
    lea     rcx, [rip+s_h_tools]
    call    pane_header
    mov     edi, 4
    call    tool_y
    lea     esi, [rax-22]
    mov     edi, 12
    lea     rdx, [rip+s_h_create]
    mov     ecx, COL_TEXT_DIM
    call    draw_text

    xor     ebx, ebx
1:  mov     edi, ebx
    call    tool_y
    mov     r12d, eax                   # y
    mov     r13d, COL_BTN               # background
    mov     r14d, COL_TEXT              # foreground
    mov     edi, HIT_TOOL
    mov     esi, ebx
    call    is_hot
    test    eax, eax
    jz      2f
    mov     r13d, COL_BTN_HOVER
2:  cmp     ebx, [rip+active_tool]
    jne     3f
    mov     r13d, COL_ACCENT
    mov     r14d, COL_TEXT_DARK
3:  mov     edi, 8
    mov     esi, r12d
    mov     edx, [rip+lx1]
    sub     edx, 16
    mov     ecx, TOOL_BTN_H
    mov     r8d, r13d
    call    fill_rect
    mov     edi, 16                     # glyph: filled for tools, hollow for create
    lea     esi, [r12+9]
    mov     edx, 8
    mov     ecx, 8
    mov     r8d, r14d
    cmp     ebx, 4
    jae     4f
    call    fill_rect
    jmp     5f
4:  call    rect_outline
5:  mov     edi, 34
    lea     esi, [r12+5]
    lea     rax, [rip+tool_names]
    mov     rdx, [rax+rbx*8]
    mov     ecx, r14d
    call    draw_text
    lea     rax, [rip+tool_keys]
    mov     rdx, [rax+rbx*8]
    test    rdx, rdx
    jz      6f
    mov     edi, [rip+lx1]
    sub     edi, 28
    lea     esi, [r12+5]
    mov     ecx, COL_TEXT_DIM
    cmp     ebx, [rip+active_tool]
    jne     51f
    mov     ecx, COL_TEXT_DARK
51: call    draw_text
6:  inc     ebx
    cmp     ebx, NUM_TOOLS
    jb      1b
    call    reset_clip

    mov     edi, HIT_SPLIT_L
    mov     esi, DRAG_SPLIT_L
    call    splitter_color
    mov     r8d, eax
    mov     edi, [rip+lx1]
    mov     esi, [rip+cont_y0]
    mov     edx, SPLIT
    mov     ecx, [rip+cont_y1]
    sub     ecx, esi
    call    fill_rect
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# ---- right pane: outliner + properties ----------------------------------------
# prop_row(edi=y, rsi=label) - label at left, current fmt_buf as value
prop_row:
    push    rbx
    push    r12
    mov     ebx, edi
    mov     r12, rsi
    mov     edi, [rip+rx0]
    add     edi, 14
    mov     esi, ebx
    mov     rdx, r12
    mov     ecx, COL_TEXT_DIM
    call    draw_text
    mov     edi, [rip+rx0]
    add     edi, 100
    mov     esi, ebx
    lea     rdx, [rip+fmt_buf]
    mov     ecx, COL_TEXT
    call    draw_text
    pop     r12
    pop     rbx
    ret

draw_right_pane:
    push    rbx
    push    r12
    push    r13
    mov     edi, [rip+rx0]
    mov     esi, [rip+cont_y0]
    mov     edx, [rip+right_w]
    mov     ecx, [rip+cont_y1]
    sub     ecx, esi
    mov     r8d, COL_PANE_BG
    call    fill_rect
    mov     edi, [rip+rx0]
    mov     esi, [rip+cont_y0]
    mov     edx, [rip+win_w]
    mov     ecx, [rip+cont_y1]
    call    set_clip
    mov     edi, [rip+rx0]
    mov     esi, [rip+cont_y0]
    mov     edx, [rip+right_w]
    lea     rcx, [rip+s_h_outliner]
    call    pane_header

    xor     ebx, ebx
1:  mov     edi, ebx
    call    row_y
    mov     r12d, eax
    mov     r8d, COL_ACCENT_DARK
    cmp     ebx, [rip+selected_obj]
    je      2f
    mov     edi, HIT_OUTLINER
    mov     esi, ebx
    call    is_hot
    test    eax, eax
    jz      3f
    mov     r8d, COL_HOVER
2:  mov     edi, [rip+rx0]
    add     edi, 4
    mov     esi, r12d
    mov     edx, [rip+right_w]
    sub     edx, 8
    mov     ecx, ROW_H
    call    fill_rect
3:  mov     edi, [rip+rx0]
    add     edi, 14
    lea     esi, [r12+6]
    mov     edx, 8
    mov     ecx, 8
    lea     rax, [rip+outliner_cols]
    mov     r8d, [rax+rbx*4]
    call    fill_rect
    mov     edi, [rip+rx0]
    add     edi, 30
    lea     esi, [r12+2]
    lea     rax, [rip+outliner_names]
    mov     rdx, [rax+rbx*8]
    mov     ecx, COL_TEXT
    call    draw_text
    inc     ebx
    cmp     ebx, NUM_OUTLINER
    jb      1b

    mov     edi, NUM_OUTLINER
    call    row_y
    lea     r12d, [rax+10]
    mov     edi, [rip+rx0]
    mov     esi, r12d
    mov     edx, [rip+right_w]
    lea     rcx, [rip+s_h_props]
    call    pane_header
    add     r12d, PANE_HDR_H+8
    mov     edi, [rip+rx0]
    add     edi, 14
    mov     esi, r12d
    lea     rdx, [rip+s_p_camera]
    mov     ecx, COL_ACCENT
    call    draw_text
    add     r12d, 20

    call    fmt_reset
    movss   xmm0, [rip+cam_yaw]
    call    fmt_deg
    lea     rdi, [rip+s_deg]
    call    fmt_str
    mov     edi, r12d
    lea     rsi, [rip+s_p_yaw]
    call    prop_row
    add     r12d, 18

    call    fmt_reset
    movss   xmm0, [rip+cam_pitch]
    call    fmt_deg
    lea     rdi, [rip+s_deg]
    call    fmt_str
    mov     edi, r12d
    lea     rsi, [rip+s_p_pitch]
    call    prop_row
    add     r12d, 18

    call    fmt_reset
    movss   xmm0, [rip+cam_dist]
    call    fmt_fix1
    mov     edi, r12d
    lea     rsi, [rip+s_p_dist]
    call    prop_row
    add     r12d, 18

    call    fmt_reset
    movss   xmm0, [rip+cam_tx]
    call    fmt_fix1
    lea     rdi, [rip+s_comma]
    call    fmt_str
    movss   xmm0, [rip+cam_ty]
    call    fmt_fix1
    lea     rdi, [rip+s_comma]
    call    fmt_str
    movss   xmm0, [rip+cam_tz]
    call    fmt_fix1
    mov     edi, r12d
    lea     rsi, [rip+s_p_target]
    call    prop_row
    add     r12d, 26

    call    fmt_reset
    mov     edi, [rip+cvs_x1]
    sub     edi, [rip+cvs_x0]
    call    fmt_int
    lea     rdi, [rip+s_x]
    call    fmt_str
    mov     edi, [rip+cvs_y1]
    sub     edi, [rip+cvs_y0]
    call    fmt_int
    mov     edi, r12d
    lea     rsi, [rip+s_p_canvas]
    call    prop_row
    add     r12d, 18

    call    fmt_reset
    lea     rdi, [rip+s_on]
    cmp     dword ptr [rip+show_grid], 0
    jne     4f
    lea     rdi, [rip+s_off]
4:  call    fmt_str
    mov     edi, r12d
    lea     rsi, [rip+s_p_grid]
    call    prop_row
    call    reset_clip

    mov     edi, HIT_SPLIT_R
    mov     esi, DRAG_SPLIT_R
    call    splitter_color
    mov     r8d, eax
    mov     edi, [rip+mx1]
    mov     esi, [rip+cont_y0]
    mov     edx, SPLIT
    mov     ecx, [rip+cont_y1]
    sub     ecx, esi
    call    fill_rect
    pop     r13
    pop     r12
    pop     rbx
    ret

# ---- bottom pane: console ------------------------------------------------------
draw_bottom_pane:
    push    rbx
    push    r12
    push    r13
    push    r14
    mov     edi, [rip+mx0]
    mov     esi, [rip+by0]
    mov     edx, [rip+mx1]
    sub     edx, edi
    mov     ecx, [rip+cont_y1]
    sub     ecx, esi
    mov     r8d, COL_PANE_BG
    call    fill_rect
    mov     edi, [rip+mx0]
    mov     esi, [rip+by0]
    mov     edx, [rip+mx1]
    mov     ecx, [rip+cont_y1]
    call    set_clip
    mov     edi, [rip+mx0]
    mov     esi, [rip+by0]
    mov     edx, [rip+mx1]
    sub     edx, edi
    lea     rcx, [rip+s_h_console]
    call    pane_header

    # visible lines = min((h - header - 8) / 18, lines logged, ring size)
    mov     eax, [rip+cont_y1]
    sub     eax, [rip+by0]
    sub     eax, PANE_HDR_H+8
    jle     9f
    xor     edx, edx
    mov     ecx, 18
    div     ecx
    mov     ebx, eax
    mov     eax, [rip+log_head]
    cmp     ebx, eax
    cmova   ebx, eax
    mov     eax, LOG_LINES
    cmp     ebx, eax
    cmova   ebx, eax
    test    ebx, ebx
    jz      9f
    # newest line at the bottom
    mov     r12d, [rip+cont_y1]
    sub     r12d, 22                    # y of newest line
    mov     r13d, [rip+log_head]
1:  dec     r13d
    mov     eax, r13d
    and     eax, LOG_LINES-1
    imul    eax, LOG_LINE_LEN
    lea     r14, [rip+log_buf]
    add     r14, rax
    mov     ecx, COL_TEXT
    cmp     byte ptr [r14], '>'
    jne     2f
    mov     ecx, COL_ACCENT
2:  mov     edi, [rip+mx0]
    add     edi, 12
    mov     esi, r12d
    mov     rdx, r14
    call    draw_text
    sub     r12d, 18
    dec     ebx
    jnz     1b
9:  call    reset_clip
    mov     edi, HIT_SPLIT_B
    mov     esi, DRAG_SPLIT_B
    call    splitter_color
    mov     r8d, eax
    mov     edi, [rip+mx0]
    mov     esi, [rip+cvs_y1]
    mov     edx, [rip+mx1]
    sub     edx, edi
    mov     ecx, SPLIT
    call    fill_rect
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# ---- status bar ----------------------------------------------------------------
draw_statusbar:
    push    rbx
    xor     edi, edi
    mov     esi, [rip+cont_y1]
    mov     edx, [rip+win_w]
    mov     ecx, STATUS_H
    mov     r8d, COL_STATUS_BG
    call    fill_rect
    mov     edi, 10
    mov     esi, [rip+cont_y1]
    add     esi, 8
    mov     edx, 6
    mov     ecx, 6
    mov     r8d, COL_ACCENT
    call    fill_rect
    # left: last console line (or "Ready")
    lea     rdx, [rip+s_ready]
    mov     eax, [rip+log_head]
    test    eax, eax
    jz      1f
    dec     eax
    and     eax, LOG_LINES-1
    imul    eax, LOG_LINE_LEN
    lea     rdx, [rip+log_buf]
    add     rdx, rax
1:  mov     edi, 24
    mov     esi, [rip+cont_y1]
    add     esi, 3
    mov     ecx, COL_TEXT_DIM
    call    draw_text
    # right: "<fb KiB> KiB framebuffer   W x H"
    call    fmt_reset
    mov     edi, [rip+pool_size]
    shr     edi, 10
    call    fmt_int
    lea     rdi, [rip+s_kib]
    call    fmt_str
    mov     edi, [rip+win_w]
    call    fmt_int
    lea     rdi, [rip+s_x]
    call    fmt_str
    mov     edi, [rip+win_h]
    call    fmt_int
    mov     edi, [rip+win_w]
    mov     eax, [rip+fmt_pos]
    shl     eax, 3
    sub     edi, eax
    sub     edi, 12
    mov     esi, [rip+cont_y1]
    add     esi, 3
    lea     rdx, [rip+fmt_buf]
    mov     ecx, COL_TEXT_DIM
    call    draw_text
    pop     rbx
    ret

# ---- dropdown menu --------------------------------------------------------------
draw_dropdown:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    mov     edi, [rip+drop_x]           # drop shadow
    add     edi, 4
    mov     esi, [rip+drop_y]
    add     esi, 4
    mov     edx, [rip+drop_w]
    mov     ecx, [rip+drop_h]
    mov     r8d, 0x0c0d10
    call    fill_rect
    mov     edi, [rip+drop_x]
    mov     esi, [rip+drop_y]
    mov     edx, [rip+drop_w]
    mov     ecx, [rip+drop_h]
    mov     r8d, COL_DROP_BG
    call    fill_rect
    mov     edi, [rip+drop_x]
    mov     esi, [rip+drop_y]
    mov     edx, [rip+drop_w]
    mov     ecx, [rip+drop_h]
    mov     r8d, COL_DROP_BORDER
    call    rect_outline

    mov     eax, [rip+menu_open]
    lea     rcx, [rip+menu_counts]
    mov     r13d, [rcx+rax*4]
    lea     rcx, [rip+menu_items]
    mov     r14, [rcx+rax*8]            # item pointer
    mov     r12d, [rip+drop_y]
    add     r12d, 4                     # y
    mov     r15d, [rip+drop_x]
    xor     ebx, ebx
1:  cmp     dword ptr [r14], CMD_SEP
    jne     2f
    lea     edi, [r15+8]
    lea     esi, [r12+4]
    mov     edx, [rip+drop_w]
    sub     edx, 16
    mov     ecx, 1
    mov     r8d, COL_SEPARATOR
    call    fill_rect
    add     r12d, MENU_SEP_H
    jmp     6f
2:  mov     edi, HIT_MENU_ITEM
    mov     esi, ebx
    call    is_hot
    test    eax, eax
    jz      3f
    lea     edi, [r15+2]
    mov     esi, r12d
    mov     edx, [rip+drop_w]
    sub     edx, 4
    mov     ecx, MENU_ITEM_H
    mov     r8d, COL_HOVER
    call    fill_rect
    lea     edi, [r15+2]
    mov     esi, r12d
    mov     edx, 3
    mov     ecx, MENU_ITEM_H
    mov     r8d, COL_ACCENT
    call    fill_rect
3:  mov     edi, [r14]                  # check mark for toggles
    call    cmd_checked
    cmp     eax, 1
    jne     4f
    lea     edi, [r15+9]
    lea     esi, [r12+12]
    lea     edx, [r15+12]
    lea     ecx, [r12+15]
    mov     r8d, COL_ACCENT
    call    draw_line
    lea     edi, [r15+12]
    lea     esi, [r12+15]
    lea     edx, [r15+18]
    lea     ecx, [r12+8]
    mov     r8d, COL_ACCENT
    call    draw_line
4:  lea     edi, [r15+26]
    lea     esi, [r12+4]
    mov     rdx, [r14+8]
    mov     ecx, COL_TEXT
    call    draw_text
    mov     rdi, [r14+16]               # shortcut, right aligned
    test    rdi, rdi
    jz      5f
    call    str_len
    shl     eax, 3
    mov     edi, r15d
    add     edi, [rip+drop_w]
    sub     edi, 12
    sub     edi, eax
    lea     esi, [r12+4]
    mov     rdx, [r14+16]
    mov     ecx, COL_TEXT_DIM
    call    draw_text
5:  add     r12d, MENU_ITEM_H
6:  add     r14, 24
    inc     ebx
    cmp     ebx, r13d
    jb      1b
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret
