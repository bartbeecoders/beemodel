# =============================================================================
#  BeeModel - application shell: layout, client-side decorations, menus,
#  resizable panes, hit testing, input handling and the console log.
# =============================================================================
.intel_syntax noprefix
.include "const.inc"
.include "macros.inc"

# exports
.globl vp_setup_drag
.globl ptr_y
.globl ptr_x
.globl menu_open
.globl hover_idx
.globl hover_id
.globl drag_mode
.globl cont_y1
.globl cont_y0
.globl is_hot
.globl tool_ops
.globl ui_key_repeat
.globl active_tool
.globl cur_shape
.globl cvs_x0
.globl cvs_x1
.globl cvs_y0
.globl cvs_y1
.globl enter_serial
.globl key_mods
.globl s_app_id
.globl s_app_title
.globl s_log_hello
.globl s_log_hello2
.globl show_grid
.globl ui_axis
.globl ui_button
.globl ui_draw
.globl ui_key
.globl ui_leave
.globl ui_motion

.section .data
.align 4
show_grid:      .long 1
menu_open:      .long -1
active_tool:    .long 0

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
press_x:        .skip 4
press_y:        .skip 4
press_mods:     .skip 4
# layout (recomputed by ui_layout)
cont_y0:        .skip 4
cont_y1:        .skip 4
cvs_x0:         .skip 4
cvs_y0:         .skip 4
cvs_x1:         .skip 4
cvs_y1:         .skip 4
menu_x:         .skip 4*(NUM_MENUS+1)
drop_x:         .skip 4
drop_y:         .skip 4
drop_w:         .skip 4
drop_h:         .skip 4

.section .rodata
s_app_title:    .asciz "BeeModel"
s_app_id:       .asciz "beemodel"
s_title_sub:    .asciz "  -  "
s_untitled:     .asciz "untitled scene"

s_m_file:       .asciz "File"
s_m_edit:       .asciz "Edit"
s_m_view:       .asciz "View"
s_m_create:     .asciz "Create"
s_m_help:       .asciz "Help"
s_m_ai:         .asciz "AI"
s_m_mesh:       .asciz "Mesh"
s_m_render:     .asciz "Render"
s_ai_pfx:       .asciz "AI: "
s_ai_conn:      .asciz " ("
s_ai_conn2:     .asciz " connected)"
s_ai_gap:       .asciz "     "



s_objs:         .asciz " objects"
s_obj1:         .asciz " object"
s_ready:        .asciz "Ready"

s_log_hello:    .asciz "BeeModel shell started - x86-64 assembly, Wayland, zero libraries"
s_log_hello2:   .asciz "Tip: F3 searches every command; Enter opens the console"

.align 8
menu_titles:    .quad s_m_file, s_m_edit, s_m_view, s_m_create, s_m_mesh, s_m_render, s_m_ai, s_m_help
menu_items:     .quad items_file, items_edit, items_view, items_create, items_mesh2, items_render, items_ai, items_help, items_area, items_modadd
# Item counts are computed from the lists, so a new entry always shows up.
menu_counts:    .long (items_edit - items_file) / 8, (items_view - items_edit) / 8
                .long (items_create - items_view) / 8, (items_render - items_create) / 8
                .long items_mesh2_n, (items_help - items_render) / 8, (tool_ops - items_ai) / 8
                .long (items_ai - items_help) / 8, items_area_n, items_modadd_n

# Menus and tool buttons are lists of operators (see ops.s); 0 = separator.
.align 8
items_file:     .quad op_file_new, op_file_open, op_file_save, op_file_saveas, 0
                .quad op_import_obj, op_import_stl, op_import_gltf, op_import_step, 0
                .quad op_export_obj, op_export_stl, op_export_gltf, op_export_step
                .quad op_export_3mf, op_export_dxf, op_export_svg, op_export_pdf, 0
                .quad op_screenshot, op_recover, 0, op_file_exit
items_edit:     .quad op_edit_undo, op_edit_redo, 0, op_edit_toggle, op_select_all, op_duplicate, op_delete, 0
                .quad op_bool_union, op_bool_diff, op_bool_isect, op_repair, op_print_check, 0
                .quad op_palette_open, 0, op_script_record, op_script_run, 0, op_edit_prefs
items_view:     .quad op_view_tools, op_view_outliner, op_view_console, 0
                .quad op_area_split_side, op_area_split_stack, op_area_maximize, op_area_close, 0
                .quad op_view_wire, op_view_matprev, op_view_grid, op_view_reset_cam, op_console_clear, 0
                .quad op_theme_dark, op_theme_light, op_theme_contrast, 0
                .quad op_an_normals, op_an_nonman, op_an_bound, op_an_degen, op_an_over, op_show_thin
                .quad op_view_measure
items_create:   .quad op_add_cube, op_add_sphere, op_add_cylinder, op_add_cone
                .quad op_add_torus, op_add_plane, op_add_grid, 0, op_add_bezier, op_add_ccircle
                .quad op_add_path, 0, op_add_light, op_add_camera, op_add_armature
items_render:   .quad op_render_start, op_render_stop, 0, op_render_pass, op_render_save, 0
                .quad op_render_denoise, op_render_settings
items_help:     .quad op_help_keys, op_console_ops, op_help_about
items_ai:       .quad op_view_activity, op_agent_revert, 0
                .quad op_agent_read, op_agent_edit, op_agent_files
tool_ops:       .quad op_tool_select, op_tool_move, op_tool_rotate, op_tool_scale
                .quad op_add_cube, op_add_sphere, op_add_cylinder, op_add_plane
                .quad op_add_light, op_add_camera

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

# item_op(edi=menu, esi=index) -> rax = operator (0 = separator)
item_op:
    lea     rax, [rip+menu_items]
    mov     rax, [rax+rdi*8]
    mov     rax, [rax+rsi*8]
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

    call    area_layout

    # menu bar title positions
    mov     ebx, 4
    xor     r12d, r12d
    lea     r13, [rip+menu_x]
11: mov     [r13+r12*4], ebx
    lea     rax, [rip+menu_titles]
    mov     rdi, [rax+r12*8]
    call    text_width
    lea     ebx, [rbx+rax+20]
    inc     r12d
    cmp     r12d, NUM_MENUS
    jb      11b
    mov     [r13+r12*4], ebx

    # dropdown rectangle
    mov     edi, [rip+menu_open]
    test    edi, edi
    js      14f
    cmp     edi, MENU_MODADD            # modifier types: at the Add button
    jne     17f
    mov     eax, [rip+md_y]
    mov     [rip+drop_y], eax
    mov     eax, [rip+md_x]
    jmp     16f
17: cmp     edi, MENU_AREA              # editor-type menu hangs off an area header
    jne     15f
    push    rdi
    mov     edi, [rip+active_area]
    call    area_node_rect
    pop     rdi
    mov     ecx, [rax+12]
    mov     [rip+drop_x], ecx
    mov     ecx, [rax+16]
    add     ecx, PANE_HDR_H
    mov     [rip+drop_y], ecx
    mov     eax, [rip+drop_x]
    jmp     16f
15: mov     eax, [r13+rdi*4]
    mov     dword ptr [rip+drop_y], TITLE_H+MENU_H
16: mov     ecx, [rip+win_w]
    sub     ecx, MENU_DROP_W
    cmp     eax, ecx
    cmovg   eax, ecx
    mov     [rip+drop_x], eax
    mov     dword ptr [rip+drop_w], MENU_DROP_W
    lea     rax, [rip+menu_counts]
    mov     ecx, [rax+rdi*4]
    lea     rax, [rip+menu_items]
    mov     rax, [rax+rdi*8]
    mov     edx, 8                      # 4px padding top + bottom
12: test    ecx, ecx
    jz      13f
    cmp     qword ptr [rax], 0
    mov     esi, MENU_ITEM_H
    mov     edi, MENU_SEP_H
    cmove   esi, edi
    add     edx, esi
    add     rax, 8
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
    cmp     dword ptr [rip+pal_open], 0 # the palette is the topmost layer
    je      0f
    call    palette_hit
    cmp     eax, -1
    je      0f
    mov     edx, eax
    mov     eax, HIT_PALETTE
    jmp     .Lht_ret
0:
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
    cmp     qword ptr [r14], 0
    jne     2f
    mov     esi, MENU_SEP_H
2:  add     ecx, esi
    cmp     r12d, ecx
    jl      4f
    add     r14, 8
    inc     edx
    jmp     1b
4:  mov     eax, HIT_MENU_ITEM
    cmp     qword ptr [r14], 0
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

    mov     edi, ebx
    mov     esi, r12d
    call    area_hit
.Lht_ret:
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# hit ids that show the pointing hand
.equ PTR_HITS, (1<<HIT_BTN_MIN)|(1<<HIT_BTN_MAX)|(1<<HIT_BTN_CLOSE)|(1<<HIT_MENU_TITLE)|(1<<HIT_MENU_ITEM)|(1<<HIT_TOOL)|(1<<HIT_OUTLINER)|(1<<HIT_AREA_TYPE)|(1<<HIT_AREA_BTN)|(1<<HIT_ACT_REVERT)|(1<<HIT_MODS)

# cursor_for(edi=hit id, esi=index) -> eax = cursor shape
cursor_for:
    cmp     edi, HIT_SPLITTER
    jne     1f
    mov     edi, esi
    jmp     splitter_cursor
1:
    mov     eax, CUR_CROSSHAIR
    cmp     edi, HIT_CANVAS
    je      9f
    mov     eax, CUR_TEXT
    cmp     edi, HIT_CONSOLE_INPUT
    je      9f
    mov     eax, CUR_POINTER            # a hand over things you can click
    mov     ecx, PTR_HITS
    cmp     edi, 31
    ja      2f
    bt      ecx, edi
    jc      9f
2:  mov     eax, CUR_DEFAULT
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
    cmp     dword ptr [rip+tm_mode], 0
    je      0f
    mov     [rip+ptr_x], edi
    mov     [rip+ptr_y], esi
    jmp     tm_motion
0:  cmp     dword ptr [rip+etool], 0    # edit tools follow the pointer
    je      0f
    push    rdi
    push    rsi
    sub     rsp, 8
    call    etool_motion
    add     rsp, 8
    pop     rsi
    pop     rdi
0:  cmp     dword ptr [rip+pl_on], 0    # play mode: the mouse looks
    je      0f
    push    rdi
    push    rsi
    sub     rsp, 8
    call    play_motion
    add     rsp, 8
    pop     rsi
    pop     rdi
    mov     [rip+ptr_x], edi
    mov     [rip+ptr_y], esi
    ret
0:  cmp     dword ptr [rip+lb_drag], 0  # a library tile carried
    je      0f
    mov     [rip+ptr_x], edi
    mov     [rip+ptr_y], esi
    jmp     lb_motion
0:  push    rbx
    push    r12
    push    r13
    mov     ebx, edi
    sub     ebx, [rip+ptr_x]            # dx
    mov     r12d, esi
    sub     r12d, [rip+ptr_y]           # dy
    mov     [rip+ptr_x], edi
    mov     [rip+ptr_y], esi
    cmp     dword ptr [rip+uved_tm], 0  # UV editor: a transform, a pan, a
    jne     761f                        #  paint stroke
    cmp     dword ptr [rip+uved_paint_on], 0
    jne     761f
    cmp     dword ptr [rip+uved_pan_on], 0
    je      762f
761: call    uved_motion
    jmp     .Lmo_out
762: cmp     dword ptr [rip+ae_drag], 0  # dope sheet / graph editor drags
    je      7622f
    mov     edi, [rip+ptr_x]
    mov     esi, [rip+ptr_y]
    call    ae_motion
    jmp     .Lmo_out
7622: cmp     dword ptr [rip+tl_drag], 0  # the timeline: a scrub
    je      7621f
    mov     edi, [rip+ptr_x]
    call    tl_motion
    jmp     .Lmo_out
7621: cmp     dword ptr [rip+ne_drag], 0  # node editor: a drag, the menu
    jne     763f
    cmp     dword ptr [rip+ne_menu], 0
    je      764f
763: call    nodeed_motion
    jmp     .Lmo_out
764:
    mov     eax, [rip+drag_mode]
    test    eax, eax
    jz      .Lmo_hover
    cmp     eax, DRAG_BOX
    jne     76f
    call    box_move                    # edi / esi = the pointer
    jmp     .Lmo_out
76: cmp     eax, DRAG_SKETCH
    jne     761f
    push    rdi
    push    rsi
    sub     rsp, 8
    call    vp_setup_drag
    mov     edi, [rip+ptr_x]
    mov     esi, [rip+ptr_y]
    call    skm_drag
    call    reset_clip
    add     rsp, 8
    pop     rsi
    pop     rdi
    jmp     .Lmo_out
761:cmp     eax, DRAG_SCULPT
    jne     762f
    push    rdi
    push    rsi
    sub     rsp, 8
    call    mono_ns                     # (the stroke's work: frametime)
    mov     [rsp], rax
    call    vp_setup_drag
    mov     edi, [rip+ptr_x]
    mov     esi, [rip+ptr_y]
    call    sculpt_hover
    mov     edi, [rip+ptr_x]
    mov     esi, [rip+ptr_y]
    call    sculpt_drag
    call    reset_clip
    call    mono_ns
    sub     rax, [rsp]
    add     [rip+fr_work], rax
    add     rsp, 8
    pop     rsi
    pop     rdi
    jmp     .Lmo_out
762:cmp     eax, DRAG_PAINT             # a texture paint stroke
    jne     763f
    push    rdi
    push    rsi
    sub     rsp, 8
    call    vp_setup_drag
    mov     edi, [rip+ptr_x]
    mov     esi, [rip+ptr_y]
    call    paint_drag
    call    reset_clip
    add     rsp, 8
    pop     rsi
    pop     rdi
    jmp     .Lmo_out
763:cmp     eax, DRAG_REDO
    jne     75f
    call    redo_drag_move              # edi = pointer x
    jmp     .Lmo_out
75: cmp     eax, DRAG_MODS
    jne     77f
    call    mods_drag_move
    jmp     .Lmo_out
77: cmp     eax, DRAG_PENDING
    jne     0f
    mov     ecx, edi                    # moved far enough to be a drag?
    sub     ecx, [rip+press_x]
    mov     edx, ecx
    neg     edx
    cmovs   edx, ecx
    mov     ecx, esi
    sub     ecx, [rip+press_y]
    mov     r8d, ecx
    neg     r8d
    cmovs   r8d, ecx
    add     edx, r8d
    cmp     edx, 3
    jle     .Lmo_out
    mov     eax, DRAG_ORBIT
    mov     ecx, DRAG_PAN
    test    dword ptr [rip+press_mods], MOD_SHIFT
    cmovnz  eax, ecx
    mov     [rip+drag_mode], eax
0:  mov     dword ptr [rip+dirty], 1
    cmp     eax, DRAG_SPLITTER
    jne     3f
    call    area_drag                   # edi/esi = pointer
    mov     edi, [rip+drag_node]
    call    splitter_cursor
    mov     edi, eax
    jmp     .Lmo_cursor
3:  push    rax                         # orbit / pan the dragged viewport
    mov     edi, [rip+drag_node]
    call    cam_load
    pop     rax
    mov     edi, ebx
    mov     esi, r12d
    cmp     eax, DRAG_ORBIT
    jne     4f
    call    vp_orbit
    mov     edi, [rip+drag_node]
    call    cam_store
    mov     edi, CUR_GRABBING
    jmp     .Lmo_cursor
4:  call    vp_pan
    mov     edi, [rip+drag_node]
    call    cam_store
    mov     edi, CUR_MOVE
    jmp     .Lmo_cursor

.Lmo_hover:
    mov     edi, [rip+ptr_x]
    mov     esi, [rip+ptr_y]
    call    hit_test
    mov     r13d, eax
    push    rdx
    push    rax
    mov     edi, [rip+ptr_x]            # sketch tools preview at the pointer
    mov     esi, [rip+ptr_y]
    mov     edx, [rip+hit_area]
    call    skm_hover
    mov     edi, [rip+ptr_x]            # the sculpt brush follows it
    mov     esi, [rip+ptr_y]
    call    sculpt_hover
    mov     edi, [rip+ptr_x]            # (and the paint brush)
    mov     esi, [rip+ptr_y]
    call    paint_hover
    pop     rax
    pop     rdx
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
1:  cmp     dword ptr [rip+menu_open], 0
    jge     11f
    mov     eax, [rip+hit_area]         # the area under the pointer is active
    test    eax, eax
    js      11f
    cmp     eax, [rip+active_area]
    je      11f
    mov     [rip+active_area], eax
    mov     dword ptr [rip+dirty], 1
11: cmp     r13d, HIT_CANVAS            # gizmo handle under the pointer?
    jne     14f
    push    rdx
    sub     rsp, 8
    mov     edi, edx
    call    vp_prepare
    mov     edi, [rip+ptr_x]
    mov     esi, [rip+ptr_y]
    call    gizmo_pick
    add     rsp, 8
    pop     rdx
    jmp     15f
14: xor     eax, eax
15: cmp     eax, [rip+gizmo_hover]
    je      13f
    mov     [rip+gizmo_hover], eax
    mov     dword ptr [rip+dirty], 1
13: cmp     r13d, HIT_PALETTE           # hovering a result selects it
    jne     12f
    test    edx, edx
    js      12f
    cmp     edx, [rip+pal_sel]
    je      12f
    mov     [rip+pal_sel], edx
    mov     dword ptr [rip+dirty], 1
12: cmp     r13d, [rip+hover_id]
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
.Lmo_out:
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
    cmp     dword ptr [rip+pl_on], 0    # (play mode: buttons do nothing)
    je      0f
    ret
0:  test    esi, esi                    # the merge panel's buttons first
    jz      70f
    cmp     edi, BTN_LEFT
    jne     70f
    push    rdi
    push    rsi
    push    rdx
    push    rcx
    sub     rsp, 8
    mov     edi, [rip+ptr_x]
    mov     esi, [rip+ptr_y]
    call    vc_press
    add     rsp, 8
    pop     rcx
    pop     rdx
    pop     rsi
    pop     rdi
    test    eax, eax
    jz      70f
    ret
70: push    rbx
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
    cmp     dword ptr [rip+uved_tm], 0  # a UV transform: a press ends it
    je      761f
    test    r15d, r15d
    jz      .Lbt_done
    mov     edi, r14d
    mov     esi, [rip+ptr_x]
    mov     edx, [rip+ptr_y]
    call    uved_press
    jmp     .Lbt_done
761: cmp     dword ptr [rip+tm_mode], 0
    je      0f
    test    r15d, r15d                  # transform running: LMB confirms,
    jz      .Lbt_tm_rel                 # RMB cancels, releasing a gizmo drag
    cmp     r14d, BTN_RIGHT             # confirms
    jne     .Lbt_tm_left
    call    tm_cancel
    jmp     .Lbt_done
.Lbt_tm_left:
    cmp     r14d, BTN_LEFT
    jne     .Lbt_done
    call    tm_confirm
    jmp     .Lbt_done
.Lbt_tm_rel:
    cmp     dword ptr [rip+tm_drag], 0
    je      .Lbt_done
    call    tm_confirm
    jmp     .Lbt_done
0:  call    hit_test
    mov     ebx, eax
    mov     r12d, edx
    mov     dword ptr [rip+dirty], 1
    test    r15d, r15d
    jz      .Lbt_release

    # ---------------- press ----------------
    cmp     dword ptr [rip+ne_menu], 0  # node editor (its menu takes a click)
    jne     763f
    cmp     ebx, HIT_NODES
    jne     764f
    cmp     dword ptr [rip+pal_open], 0
    jne     764f
    cmp     dword ptr [rip+menu_open], 0
    jge     764f
763: mov     edi, r14d
    mov     esi, [rip+ptr_x]
    mov     edx, [rip+ptr_y]
    call    nodeed_press
    test    eax, eax
    jnz     .Lbt_done
764: cmp     ebx, HIT_ANIMED             # dope sheet, graph editor
    jne     7642f
    cmp     dword ptr [rip+pal_open], 0
    jne     7642f
    mov     edi, [rip+active_area]
    call    area_editor
    mov     ecx, eax
    mov     edi, r14d
    mov     esi, [rip+ptr_x]
    mov     edx, [rip+ptr_y]
    call    ae_press
    test    eax, eax
    jnz     .Lbt_done
7642: cmp     ebx, HIT_TIMELINE           # the timeline: a scrub
    jne     7641f
    cmp     dword ptr [rip+pal_open], 0
    jne     7641f
    mov     edi, r14d
    mov     esi, [rip+ptr_x]
    mov     edx, [rip+ptr_y]
    call    tl_press
    test    eax, eax
    jnz     .Lbt_done
7641: cmp     ebx, HIT_ASSETS             # the asset browser: a click adds
    jne     765f
    cmp     dword ptr [rip+pal_open], 0
    jne     765f
    mov     edi, r14d
    mov     esi, [rip+ptr_x]
    mov     edx, [rip+ptr_y]
    call    assets_press
    test    eax, eax
    jnz     .Lbt_done
765: cmp     ebx, HIT_UVED               # the UV editor: select, pan
    jne     762f
    cmp     dword ptr [rip+pal_open], 0
    jne     762f
    cmp     dword ptr [rip+menu_open], 0
    jge     762f
    mov     edi, r14d
    mov     esi, [rip+ptr_x]
    mov     edx, [rip+ptr_y]
    call    uved_press
    test    eax, eax
    jnz     .Lbt_done
762: cmp     dword ptr [rip+pal_open], 0
    je      0f
    cmp     ebx, HIT_PALETTE            # click a result to run it
    jne     .Lbt_palclose
    test    r12d, r12d
    js      .Lbt_done
    mov     [rip+pal_sel], r12d
    call    palette_run
    jmp     .Lbt_done
.Lbt_palclose:
    call    palette_close               # click outside closes
    jmp     .Lbt_done
0:  cmp     ebx, HIT_CONSOLE_INPUT
    jne     1f
    mov     dword ptr [rip+menu_open], -1
    mov     edi, [rip+ptr_x]
    call    tf_click
    jmp     .Lbt_done
1:  xor     edi, edi                    # clicking anywhere else blurs it
    call    tf_set_focus
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
    mov     [rip+drag_node], r12d
    mov     [rip+vp_area], r12d
    mov     dword ptr [rip+drag_mode], DRAG_PAN
    mov     edi, CUR_MOVE
    call    set_cursor
    jmp     .Lbt_done
1:  cmp     r14d, BTN_RIGHT             # right button in a viewport
    jne     13f
    cmp     ebx, HIT_CANVAS
    jne     .Lbt_done
    cmp     dword ptr [rip+etool], 0    # cancels an edit tool,
    je      12f
    call    etool_cancel
    jmp     .Lbt_done
12: test    dword ptr [rip+key_mods], MOD_SHIFT  # Shift: places the 3D cursor
    jz      .Lbt_done
    mov     [rip+vp_area], r12d
    mov     [rip+drag_node], r12d
    call    vp_setup_drag
    mov     edi, [rip+ptr_x]
    mov     esi, [rip+ptr_y]
    call    cursor_place
    call    reset_clip
    jmp     .Lbt_done
13: cmp     r14d, BTN_LEFT
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
4:  cmp     ebx, HIT_SPLITTER
    jne     41f
    mov     [rip+drag_node], r12d
    mov     dword ptr [rip+drag_mode], DRAG_SPLITTER
    jmp     .Lbt_done
41: cmp     ebx, HIT_AREA_BTN           # area header buttons run operators
    jne     42f
    mov     eax, [rip+hit_area]
    mov     [rip+active_area], eax
    lea     rax, [rip+area_btn_ops]
    mov     rdi, [rax+r12*8]
    call    run_op
    jmp     .Lbt_done
42: cmp     ebx, HIT_AREA_TYPE          # editor type menu
    jne     5f
    mov     [rip+active_area], r12d
    mov     dword ptr [rip+menu_open], MENU_AREA
    jmp     .Lbt_done
5:  cmp     ebx, HIT_MODS               # modifier stack: buttons / fields
    jne     56f
    mov     edi, r12d
    call    mods_drag_begin
    test    r12d, 0x20000
    jz      .Lbt_done
    mov     dword ptr [rip+drag_mode], DRAG_MODS
    jmp     .Lbt_done
56: cmp     ebx, HIT_REDO               # drag a value of the redo panel
    jne     55f
    mov     edi, r12d
    call    redo_drag_begin
    mov     dword ptr [rip+drag_mode], DRAG_REDO
    jmp     .Lbt_done
55: cmp     ebx, HIT_CANVAS            # click selects, drag orbits / pans
    jne     6f
    mov     [rip+vp_area], r12d
    cmp     dword ptr [rip+etool], 0    # an edit tool takes the clicks
    je      54f
    mov     edi, [rip+key_mods]
    call    etool_press
    jmp     .Lbt_done
54:
    mov     edi, r12d                   # a gizmo handle starts a transform
    call    vp_prepare
    mov     edi, [rip+ptr_x]
    mov     esi, [rip+ptr_y]
    call    gizmo_pick
    test    eax, eax
    jz      51f
    mov     esi, eax
    mov     edi, [rip+active_tool]
    mov     edx, 1
    call    tm_start
    jmp     .Lbt_done
51: mov     [rip+drag_node], r12d
    cmp     dword ptr [rip+box_armed], 0  # B was pressed: box select
    je      52f
    cmp     dword ptr [rip+edit_obj], 0
    je      52f
    mov     dword ptr [rip+drag_mode], DRAG_BOX
    mov     edi, [rip+ptr_x]
    mov     esi, [rip+ptr_y]
    call    box_begin
    jmp     .Lbt_done
52: cmp     dword ptr [rip+sc_obj], 0   # sculpt mode: a stroke on the mesh?
    je      521f
    call    vp_setup_drag
    mov     edi, [rip+ptr_x]
    mov     esi, [rip+ptr_y]
    call    sculpt_press
    push    rax
    call    reset_clip
    pop     rax
    test    eax, eax
    jz      53f
    mov     dword ptr [rip+drag_mode], DRAG_SCULPT
    jmp     .Lbt_done
521:cmp     dword ptr [rip+pt_obj], 0   # texture paint: a stroke
    je      522f
    call    vp_setup_drag
    mov     edi, [rip+ptr_x]
    mov     esi, [rip+ptr_y]
    call    paint_press
    push    rax
    call    reset_clip
    pop     rax
    test    eax, eax
    jz      53f
    mov     dword ptr [rip+drag_mode], DRAG_PAINT
    jmp     .Lbt_done
522:cmp     dword ptr [rip+skm_obj], 0  # sketch mode: grab a point?
    je      53f
    call    vp_setup_drag
    mov     edi, [rip+ptr_x]
    mov     esi, [rip+ptr_y]
    call    skm_press
    push    rax
    call    reset_clip
    pop     rax
    test    eax, eax
    jz      53f
    mov     dword ptr [rip+drag_mode], DRAG_SKETCH
    jmp     .Lbt_done
53: mov     dword ptr [rip+drag_mode], DRAG_PENDING
    mov     eax, [rip+ptr_x]
    mov     [rip+press_x], eax
    mov     eax, [rip+ptr_y]
    mov     [rip+press_y], eax
    mov     eax, [rip+key_mods]
    mov     [rip+press_mods], eax
    jmp     .Lbt_done
6:  cmp     ebx, HIT_ACT_REVERT
    jne     61f
    lea     rdi, [rip+op_agent_revert]
    call    run_op
    jmp     .Lbt_done
61: cmp     ebx, HIT_TOOL
    jne     7f
    lea     rax, [rip+tool_ops]
    mov     rdi, [rax+r12*8]
    call    run_op
    jmp     .Lbt_done
7:  cmp     ebx, HIT_OUTLINER           # click an object row to select it
    jne     .Lbt_done
    call    edit_exit                   # (leaves edit mode)
    lea     rax, [rip+obj_list]
    mov     edi, [rax+r12*4]
    mov     esi, [rip+key_mods]
    and     esi, MOD_SHIFT
    call    obj_click_select
    call    macro_select
    jmp     .Lbt_done

    # ---------------- release ----------------
.Lbt_release:
    cmp     dword ptr [rip+lb_drag], 0  # a library tile dropped
    je      7700f
    mov     edi, ebx
    mov     esi, r12d
    call    lb_release
    jmp     .Lbt_done
7700:
    call    uved_release                # (a UV pan ends)
    call    nodeed_release              # (a node editor drag too)
    call    tl_release                  # (and a timeline scrub)
    call    ae_release                  # (and key drags)
    cmp     dword ptr [rip+drag_mode], DRAG_BOX
    jne     77f
    mov     dword ptr [rip+drag_mode], 0
    call    vp_setup_drag
    mov     edi, [rip+key_mods]
    call    box_finish
    call    reset_clip
    jmp     .Lbt_done
77: cmp     dword ptr [rip+drag_mode], DRAG_PENDING
    jne     78f
    mov     dword ptr [rip+drag_mode], 0
    call    viewport_click
    jmp     .Lbt_done
78: cmp     dword ptr [rip+drag_mode], DRAG_SCULPT
    jne     781f
    mov     dword ptr [rip+drag_mode], 0
    call    sculpt_release
    jmp     .Lbt_done
781:cmp     dword ptr [rip+drag_mode], DRAG_PAINT
    jne     782f
    mov     dword ptr [rip+drag_mode], 0
    call    paint_release
    jmp     .Lbt_done
782:cmp     dword ptr [rip+drag_mode], DRAG_SKETCH
    jne     0f
    mov     dword ptr [rip+drag_mode], 0
    call    skm_release
    jmp     .Lbt_done
0:  cmp     dword ptr [rip+drag_mode], 0
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
    call    item_op
    mov     dword ptr [rip+menu_open], -1
    test    rax, rax
    jz      .Lbt_done
    mov     rdi, rax
    call    run_op
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
    mov     edi, esi                    # direction: -1 / +1
    sar     edi, 31
    or      edi, 1
    cmp     dword ptr [rip+tm_mode], 4  # a value modal: segments / cuts
    je      tm_wheel
    cmp     dword ptr [rip+etool], 0    # an edit tool (loop cut: cuts)
    je      0f
    jmp     etool_wheel
0:  push    rsi
    mov     edi, [rip+ptr_x]
    mov     esi, [rip+ptr_y]
    call    hit_test
    pop     rdi
    cmp     eax, HIT_NODES              # the node editor scrolls
    jne     760f
    neg     edi
    jmp     nodeed_wheel
760: cmp     eax, HIT_UVED               # the UV editor zooms
    jne     761f
    neg     edi
    jmp     uved_wheel
761: cmp     eax, HIT_OUTLINER
    je      8f
    cmp     eax, HIT_PANE
    jne     7f
    push    rdi
    mov     edi, edx
    call    area_editor
    pop     rdi
    cmp     eax, ED_OUTLINER
    je      8f
    jmp     9f
7:  cmp     eax, HIT_REDO               # wheel on a redo panel value
    jne     71f
    mov     esi, edi
    sar     esi, 31
    or      esi, 1
    mov     edi, edx
    jmp     redo_wheel
71: cmp     eax, HIT_CANVAS
    jne     9f
    push    rdi
    push    rdx
    mov     [rip+vp_area], edx
    mov     edi, edx
    call    cam_load
    pop     rdx
    pop     rdi
    push    rdx
    sub     rsp, 8
    call    vp_zoom
    add     rsp, 8
    pop     rdi
    call    cam_store
    mov     dword ptr [rip+dirty], 1
9:  ret
8:  mov     eax, [rip+outl_scroll]      # outliner: 1 row per notch
    test    edi, edi
    js      81f
    inc     eax
    jmp     82f
81: dec     eax
82: mov     ecx, [rip+obj_count]
    dec     ecx
    cmp     eax, ecx
    cmovg   eax, ecx
    xor     ecx, ecx
    cmp     eax, ecx
    cmovl   eax, ecx
    mov     [rip+outl_scroll], eax
    mov     dword ptr [rip+dirty], 1
    ret

# viewport_click - LMB released without dragging: pick in that viewport
viewport_click:
    push    rbx
    call    vp_setup_drag
    mov     edi, [rip+ptr_x]            # an AI proposal's buttons
    mov     esi, [rip+ptr_y]
    call    cp_click
    test    eax, eax
    jz      99f
    call    reset_clip
    pop     rbx
    ret
99: mov     edi, [rip+ptr_x]            # armature modes: joints, bones
    mov     esi, [rip+ptr_y]
    mov     edx, [rip+press_mods]
    call    arm_click_at
    test    eax, eax
    jz      98f
    call    reset_clip
    pop     rbx
    ret
98: cmp     dword ptr [rip+cve_obj], 0  # curve edit mode: its points
    je      100f
    mov     edi, [rip+ptr_x]
    mov     esi, [rip+ptr_y]
    mov     edx, [rip+press_mods]
    call    cve_click
    call    reset_clip
    pop     rbx
    ret
100: cmp     dword ptr [rip+skm_obj], 0  # sketch mode: its tools
    je      101f
    mov     edi, [rip+ptr_x]
    mov     esi, [rip+ptr_y]
    mov     edx, [rip+press_mods]
    call    skm_click
    call    reset_clip
    pop     rbx
    ret
101: cmp     dword ptr [rip+edit_obj], 0 # edit mode: components
    je      1f
    mov     edi, [rip+ptr_x]
    mov     esi, [rip+ptr_y]
    mov     edx, [rip+press_mods]
    call    edit_click
    call    reset_clip
    pop     rbx
    ret
1:  mov     edi, [rip+ptr_x]
    mov     esi, [rip+ptr_y]
    call    vp_pick
    push    rax
    call    reset_clip
    pop     rax
    mov     edi, eax
    mov     esi, [rip+press_mods]
    and     esi, MOD_SHIFT
    call    obj_click_select
    call    macro_select
    pop     rbx
    ret

# vp_setup_drag - canvas, camera and clip of the viewport drag_node
vp_setup_drag:
    push    rbx
    mov     edi, [rip+drag_node]
    call    area_node_rect
    mov     ecx, [rax+12]               # canvas = area below its header
    mov     [rip+cvs_x0], ecx
    add     ecx, [rax+20]
    mov     [rip+cvs_x1], ecx
    mov     ecx, [rax+16]
    add     ecx, PANE_HDR_H
    mov     [rip+cvs_y0], ecx
    mov     ecx, [rax+16]
    add     ecx, [rax+24]
    mov     [rip+cvs_y1], ecx
    mov     edi, [rip+drag_node]
    call    cam_load
    call    cam_setup
    mov     edi, [rip+cvs_x0]
    mov     esi, [rip+cvs_y0]
    mov     edx, [rip+cvs_x1]
    mov     ecx, [rip+cvs_y1]
    call    set_clip
    pop     rbx
    ret

# ui_key(edi=evdev key, esi=state) - Esc closes menus, everything else is
# looked up in the operator keymap (ops.s: dispatch_key)
ui_key:
    push    rdi                         # play mode takes the keys
    push    rsi
    sub     rsp, 8
    call    play_key
    add     rsp, 8
    pop     rsi
    pop     rdi
    test    eax, eax
    jz      0f
    jmp     kb_repeat_stop              # (taken: no key repeats on, F5 too)
0:  cmp     esi, 1
    je      1f
    test    esi, esi                    # release: stop repeating that key
    jnz     9f
    cmp     edi, [rip+rep_code]
    jne     9f
    jmp     kb_repeat_stop
1:  push    rbx
    mov     ebx, edi
    call    ui_key_press
    cmp     dword ptr [rip+tf_focus], 0 # repeat only while typing
    je      2f
    lea     rax, [rip+modifier_keys]
3:  movzx   ecx, byte ptr [rax]
    test    ecx, ecx
    jz      4f
    cmp     ecx, ebx
    je      2f
    inc     rax
    jmp     3b
4:  mov     edi, ebx
    call    kb_repeat_start
2:  pop     rbx
9:  ret

# ui_key_repeat(edi=evdev) - timer tick for a held key
ui_key_repeat:
    cmp     dword ptr [rip+tf_focus], 0
    je      kb_repeat_stop
# ui_key_press(edi=evdev) - one key stroke: menus, text field, then keymap
ui_key_press:
    cmp     dword ptr [rip+tm_mode], 0  # a running transform takes every key
    jne     tm_key
    cmp     dword ptr [rip+uved_tm], 0  # (a UV one too)
    jne     uved_key
    cmp     dword ptr [rip+ne_menu], 0  # (and the node editor's menu)
    jne     nodeed_key
    push    rbx
    mov     ebx, edi
    cmp     dword ptr [rip+pal_open], 0  # the palette takes every key
    je      0f
    call    kb_sym
    mov     esi, eax
    mov     edi, ebx
    call    palette_key
    jmp     9f
0:
    cmp     ebx, KEY_ESC
    jne     1f
    cmp     dword ptr [rip+menu_open], 0
    jl      1f
    mov     dword ptr [rip+menu_open], -1
    mov     dword ptr [rip+dirty], 1
    jmp     9f
1:  cmp     dword ptr [rip+etool], 0    # edit tools: Enter / Esc / ...
    je      11f
    mov     edi, ebx
    call    etool_key
    test    eax, eax
    jnz     9f
11: cmp     dword ptr [rip+tf_focus], 0
    je      2f
    lea     rdi, [rip+tfi_console]
    call    tf_select
    mov     edi, ebx
    call    kb_sym
    mov     esi, eax
    mov     edi, ebx
    call    tf_key
    test    eax, eax
    jnz     9f
2:  mov     edi, ebx                    # an AI proposal: Enter / Esc
    call    cp_key
    test    eax, eax
    jnz     9f
    cmp     ebx, KEY_ESC                # Esc: sketch mode first
    jne     21f
    call    skm_escape
    test    eax, eax
    jnz     9f
    cmp     dword ptr [rip+hv_active], 0    # ... a running render
    je      21f
    lea     rdi, [rip+op_render_stop]
    call    run_op
    jmp     9f
    cmp     ebx, KEY_ESC                # (stops a running render)
    jne     21f
    cmp     dword ptr [rip+hv_active], 0
    je      21f
    lea     rdi, [rip+op_render_stop]
    call    run_op
    jmp     9f
21: mov     edi, ebx
    call    dispatch_key
9:  pop     rbx
    ret

.section .rodata
#                Ctrl Shift Alt RShift RCtrl RAlt Meta Caps NumLk
modifier_keys: .byte 29, 42, 56, 54, 97, 100, 125, 126, 58, 69, 0
.text

# =============================================================================
#  Drawing
# =============================================================================
ui_draw:
    call    an_tick                     # playback: the frame the clock says
    call    rig_tick                    # drivers, constraints, onion skins
    call    ui_layout
    call    reset_clip
    call    draw_titlebar
    call    draw_menubar
    call    area_draw_all
    call    draw_statusbar
    cmp     dword ptr [rip+menu_open], 0
    jl      4f
    call    draw_dropdown
4:  jmp     palette_draw

# is_hot(edi=hit id, esi=index) -> eax = 1 if hovered
is_hot:
    xor     eax, eax
    cmp     edi, [rip+hover_id]
    jne     1f
    cmp     esi, [rip+hover_idx]
    jne     1f
    inc     eax
1:  ret

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
    push    rax                         # current file name, or untitled
    lea     rdi, [rip+cur_path]
    call    basename
    mov     rdx, rax
    cmp     byte ptr [rdx], 0
    jne     1f
    lea     rdx, [rip+s_untitled]
1:  pop     rdi
    mov     esi, 8
    mov     ecx, COL_TEXT_DIM
    call    draw_text
    cmp     dword ptr [rip+scene_modified], 0
    je      5f
    lea     edi, [rax+11]               # unsaved changes: a round dot
    mov     esi, TITLE_H/2
    mov     edx, 4
    mov     r8d, COL_ACCENT
    call    fill_circle
5:
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
    cmp     dword ptr [rip+macro_on], 0     # red while recording a macro
    je      2f
    mov     r8d, COL_REC
2:  call    fill_rect
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
    call    draw_small
    # right: "3 objects     AI: edit (1 connected)"
    call    fmt_reset
    mov     edi, [rip+obj_count]
    call    fmt_int
    lea     rdi, [rip+s_objs]
    cmp     dword ptr [rip+obj_count], 1
    jne     5f
    lea     rdi, [rip+s_obj1]
5:  call    fmt_str
    lea     rdi, [rip+s_ai_gap]
    call    fmt_str
    lea     rdi, [rip+s_ai_pfx]
    call    fmt_str
    mov     edi, [rip+agent_tier]
    call    agent_tier_name
    mov     rdi, rax
    call    fmt_str
    call    mcp_clients
    test    eax, eax
    jz      3f
    push    rax
    lea     rdi, [rip+s_ai_conn]
    call    fmt_str
    pop     rdi
    call    fmt_int
    lea     rdi, [rip+s_ai_conn2]
    call    fmt_str
3:
    lea     rdi, [rip+fmt_buf]
    call    text_width
    mov     edi, [rip+win_w]
    sub     edi, eax
    sub     edi, 12
    mov     esi, [rip+cont_y1]
    add     esi, 3
    lea     rdx, [rip+fmt_buf]
    mov     ecx, COL_TEXT_DIM
    call    draw_small
    pop     rbx
    ret

# ---- dropdown menu --------------------------------------------------------------
draw_dropdown:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    mov     edi, [rip+drop_x]           # shadow, border, body
    mov     esi, [rip+drop_y]
    mov     edx, [rip+drop_w]
    mov     ecx, [rip+drop_h]
    mov     r8d, COL_DROP_BORDER
    call    popup_frame

    mov     eax, [rip+menu_open]
    lea     rcx, [rip+menu_counts]
    mov     r13d, [rcx+rax*4]
    lea     rcx, [rip+menu_items]
    mov     r14, [rcx+rax*8]            # item pointer
    mov     r12d, [rip+drop_y]
    add     r12d, 4                     # y
    mov     r15d, [rip+drop_x]
    xor     ebx, ebx
1:  cmp     qword ptr [r14], 0
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
3:  mov     rdi, [r14]                  # check mark for toggles
    call    op_checked
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
    mov     rax, [r14]
    mov     rdx, [rax+OP_LABEL]
    mov     ecx, COL_TEXT
    call    draw_text
    mov     rax, [r14]                  # shortcut derived from the binding
    mov     edi, [rax+OP_KEY]
    call    fmt_key
    test    rax, rax
    jz      5f
    push    rax
    mov     rdi, rax
    call    text_width
    mov     edi, r15d
    add     edi, [rip+drop_w]
    sub     edi, 12
    sub     edi, eax
    lea     esi, [r12+4]
    pop     rdx
    mov     ecx, COL_TEXT_DIM
    call    draw_text
5:  add     r12d, MENU_ITEM_H
6:  add     r14, 8
    inc     ebx
    cmp     ebx, r13d
    jb      1b
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

.section .note.GNU-stack,"",@progbits
