# =============================================================================
#  BeeModel - viewport navigation and the viewport header:
#    - view.align_*: look from the front / back / right / left / top /
#      bottom (Numpad 1 / 3 / 7, Ctrl for the opposite side);
#    - the navigation gizmo in the top-right corner of every 3D viewport:
#      the six axis directions as balls; click one to look along it;
#    - the header tools of a 3D viewport: the mode, the select mode (edit
#      mode), the shading, the grid and snapping - each a widget whose
#      tooltip names it and its shortcut.
# =============================================================================
.intel_syntax noprefix
.include "const.inc"
.include "macros.inc"
.include "widgets.inc"
.include "icons.inc"

# exports
.globl vp_header_tools
.globl nav_gizmo_draw
.globl tool_settings_draw
.globl vp_ov_text
.globl nav_press
.globl nav_release
.globl nav_zoom_drag
.globl vp_ov_stats
.globl vp_ov_gizmo

.equ NAV_R,     34                      # the gizmo's radius
.equ NAV_BALL,  9

.section .rodata
.align 4
nz_k:           .float 0.01
nz_one:         .float 1.0
# yaw, pitch per view: front back right left top bottom
align_tab:      .float 0.0, 0.0,  3.1415927, 0.0,  1.5707964, 0.0,  -1.5707964, 0.0
                .float 0.0, 1.5697,  0.0, -1.5697
s_x:            .asciz "X"
s_y:            .asciz "Y"
s_z:            .asciz "Z"
s_mode_obj:     .asciz "Object Mode"
s_mode_edit:    .asciz "Edit Mode"
s_mode_sculpt:  .asciz "Sculpt Mode"
s_mode_tex:     .asciz "Texture Paint"
s_mode_vcol:    .asciz "Vertex Paint"
s_mode_wgt:     .asciz "Weight Paint"
.align 8
mode_lbl:       .quad s_mode_obj, s_mode_edit, s_mode_sculpt, s_mode_tex, s_mode_vcol, s_mode_wgt
mode_ops:       .quad 0, op_edit_toggle, op_sculpt_mode, op_paint_mode, op_vpaint_mode, op_wpaint_mode
axis_lbl:       .quad s_x, s_y, s_z
# the gizmo's balls: +X +Y +Z -X -Y -Z, the view each one aligns to
nav_desc:       .quad wd_nav_px, wd_nav_py, wd_nav_pz, wd_nav_nx, wd_nav_ny, wd_nav_nz
.align 4
nav_col:        .long COL_AXIS_X, COL_AXIS_Y, COL_AXIS_Z

.section .data
.align 4
vp_ov_text:     .long 1                 # Overlays: the view's name and grid size,
vp_ov_stats:    .long 0                 #  the scene's size,
vp_ov_gizmo:    .long 1                 #  the navigation gizmo
.align 8
ov_list:        .quad op_view_grid, op_ov_text, op_ov_stats, op_ov_gizmo, 0
                .quad op_an_normals, op_an_bound, op_an_nonman, op_an_degen
.equ ov_list_n, (. - ov_list) / 8

.section .bss
.align 4
vp_mode_sel:    .skip 4                 # the header's mode choice
vp_mode_was:    .skip 4
nav_dummy:      .skip 4
nav_sx:         .skip 4*6               # each ball on screen, its depth
nav_sy:         .skip 4*6
nav_dep:        .skip 4*6
nav_op:         .skip 8                 # a ball pressed: its view
nav_y0:         .skip 4                 # the zoom handle: where it was pressed,
nav_d0:         .skip 4                 #  the distance then

.text

OPERATOR op_align_front,  "view.align_front",  "Front View",  view_align, arg=0, key=79, flags=OPF_AI_SAFE|OPF_QUIET, doc="Look at the scene from the front (along -Z)"
OPERATOR op_align_back,   "view.align_back",   "Back View",   view_align, arg=1, key=79|KM_CTRL, flags=OPF_AI_SAFE|OPF_QUIET, doc="Look at the scene from the back"
OPERATOR op_align_right,  "view.align_right",  "Right View",  view_align, arg=2, key=81, flags=OPF_AI_SAFE|OPF_QUIET, doc="Look at the scene from the right (along -X)"
OPERATOR op_align_left,   "view.align_left",   "Left View",   view_align, arg=3, key=81|KM_CTRL, flags=OPF_AI_SAFE|OPF_QUIET, doc="Look at the scene from the left"
OPERATOR op_align_top,    "view.align_top",    "Top View",    view_align, arg=4, key=71, flags=OPF_AI_SAFE|OPF_QUIET, doc="Look down on the scene from above"
OPERATOR op_align_bottom, "view.align_bottom", "Bottom View", view_align, arg=5, key=71|KM_CTRL, flags=OPF_AI_SAFE|OPF_QUIET, doc="Look up at the scene from below"
OPERATOR op_ov_text,  "view.overlay_text", "Text Info", op_toggle_flag, op_check_flag, vp_ov_text, flags=OPF_AI_SAFE|OPF_QUIET, doc="Show the view's name and grid size in the top left of 3D viewports"
OPERATOR op_ov_stats, "view.overlay_stats", "Statistics", op_toggle_flag, op_check_flag, vp_ov_stats, flags=OPF_AI_SAFE|OPF_QUIET, doc="Show the scene's size (objects, faces) in 3D viewports"
OPERATOR op_ov_gizmo, "view.overlay_gizmo", "Navigation Gizmo", op_toggle_flag, op_check_flag, vp_ov_gizmo, flags=OPF_AI_SAFE|OPF_QUIET, doc="Show the axis balls in the top right of 3D viewports"
OPERATOR op_vh_mview, "view.header_menu_view", "View Menu", vh_menu, arg=2, flags=OPF_HIDDEN|OPF_QUIET, doc="The View menu, from the 3D viewport's header"
OPERATOR op_vh_msel, "view.header_menu_select", "Select Menu", vh_menu, arg=3, flags=OPF_HIDDEN|OPF_QUIET, doc="The Select menu, from the 3D viewport's header"
OPERATOR op_vh_mobj, "view.header_menu_object", "Object Menu", vh_menu, arg=5, flags=OPF_HIDDEN|OPF_QUIET, doc="The Object menu (Mesh in edit mode), from the 3D viewport's header"
OPERATOR op_vh_xf, "view.header_transform", "Pivot Point and Orientation", vh_xf, flags=OPF_HIDDEN|OPF_QUIET, doc="What turning and scaling go around, and what X, Y and Z mean while moving or turning"
OPERATOR op_vh_ov, "view.header_overlays", "Overlays", vh_overlays, flags=OPF_HIDDEN|OPF_QUIET, doc="What 3D viewports draw over the scene: grid, text, statistics, gizmo, normals and mesh checks"
OPERATOR op_view_ortho, "view.toggle_ortho", "Orthographic", do_ortho, check=chk_ortho, key=76, flags=OPF_AI_SAFE|OPF_QUIET, doc="Switch the 3D viewport between perspective and orthographic (Numpad 5): no shrinking with distance, parallel lines stay parallel"
OPERATOR op_toggle_snap,  "view.toggle_snap",  "Snap",        op_toggle_flag, op_check_flag, snap_on, flags=OPF_AI_SAFE|OPF_QUIET, doc="Snap moves, turns and scales to whole steps (Ctrl does the opposite while you drag)"

WIDGET wd_ts_srad,  WK_FLOAT, "brush.radius", "Radius", 2.0, 1000.0, 0.5, 0, WGF_CLAMP, tip="The brush's radius in pixels ([ and ] change it)"
WIDGET wd_ts_sstr,  WK_SLIDER, "brush.strength", "Strength", 0.0, 1.0, 0.005, 2, tip="How strongly the brush acts (Shift+[ and Shift+])"
WIDGET wd_ts_prad,  WK_FLOAT, "paint.radius", "Radius", 1.0, 1000.0, 0.5, 0, WGF_CLAMP, tip="The brush's radius in pixels ([ and ] change it)"
WIDGET wd_ts_pstr,  WK_SLIDER, "paint.strength", "Strength", 0.0, 1.0, 0.005, 2, tip="How strongly the brush paints (Shift+[ and Shift+])"
WIDGET wd_ts_sym,   WK_BUTTON, "brush.symmetry_x", "X Symmetry (Shift+X)", flags=WGF_ICON, aux=op_s_sym, n=ICON_SPLIT_H
WIDGET wd_ts_dyn,   WK_BUTTON, "brush.dyntopo", "Dynamic Topology (Ctrl+D)", flags=WGF_ICON, aux=op_s_dyn, n=ICON_GRID
WIDGET wd_ts_lazy,  WK_BUTTON, "brush.stabilizer", "Stabilizer (Shift+S)", flags=WGF_ICON, aux=op_s_lazy, n=ICON_CURVE
WIDGET wd_ts_pstrp, WK_BUTTON, "brush.pressure_strength", "Pen pressure drives the strength", flags=WGF_ICON, aux=op_s_pstr, n=ICON_BRUSH
WIDGET wd_ts_pradp, WK_BUTTON, "brush.pressure_radius", "Pen pressure drives the radius", flags=WGF_ICON, aux=op_s_prad, n=ICON_DOT
WIDGET wd_ts_col,   WK_BUTTON, "paint.color", "Brush Colour", flags=WGF_ICON, aux=op_pt_color, n=ICON_PAINT
WIDGET wd_vp_mode,  WK_ENUM, "viewport.mode", "Mode", cb=vp_mode_cb, aux=mode_lbl, n=6, tip="The mode of the active object: edit, sculpt or paint it"
WIDGET wd_sm_v,     WK_BUTTON, "viewport.select_vertex", "Vertex select (1)", flags=WGF_ICON, aux=op_selmode_v, n=ICON_DOT
WIDGET wd_sm_e,     WK_BUTTON, "viewport.select_edge", "Edge select (2)", flags=WGF_ICON, aux=op_selmode_e, n=ICON_MINUS
WIDGET wd_sm_f,     WK_BUTTON, "viewport.select_face", "Face select (3)", flags=WGF_ICON, aux=op_selmode_f, n=ICON_STOP
WIDGET wd_sh_wire,  WK_BUTTON, "viewport.shading_wireframe", "Wireframe", flags=WGF_ICON, aux=op_shade_wire, n=ICON_WIRE
WIDGET wd_sh_solid, WK_BUTTON, "viewport.shading_solid", "Solid", flags=WGF_ICON, aux=op_shade_solid, n=ICON_SOLID
WIDGET wd_sh_mat,   WK_BUTTON, "viewport.shading_material", "Material Preview", flags=WGF_ICON, aux=op_shade_mat, n=ICON_MATERIAL
WIDGET wd_sh_rend,  WK_BUTTON, "viewport.shading_rendered", "Rendered (GPU)", flags=WGF_ICON, aux=op_shade_rend, n=ICON_RENDERED
WIDGET wd_vh_mv,    WK_BUTTON, "viewport.menu_view", "View", aux=op_vh_mview
WIDGET wd_vh_ms,    WK_BUTTON, "viewport.menu_select", "Select", aux=op_vh_msel
WIDGET wd_vh_mo,    WK_BUTTON, "viewport.menu_object", "Object", aux=op_vh_mobj
WIDGET wd_vh_mm,    WK_BUTTON, "viewport.menu_object", "Mesh", aux=op_vh_mobj
WIDGET wd_vh_ov,    WK_BUTTON, "viewport.overlays", "Overlays", flags=WGF_ICON, aux=op_vh_ov, n=ICON_OVERLAYS
WIDGET wd_vh_xf,    WK_BUTTON, "viewport.transform", "Pivot Point and Orientation", flags=WGF_ICON, aux=op_vh_xf, n=ICON_PIVOT
WIDGET wd_vh_grid,  WK_BUTTON, "viewport.grid", "Ground Grid", flags=WGF_ICON, aux=op_view_grid, n=ICON_GRID
WIDGET wd_vh_snap,  WK_BUTTON, "viewport.snap", "Snap", flags=WGF_ICON, aux=op_toggle_snap, n=ICON_SNAP
WIDGET wd_nav_zoom,  WK_BUTTON, "viewport.nav_zoom", "Zoom (drag up and down)", flags=WGF_ICON, n=ICON_SEARCH
WIDGET wd_nav_pan,   WK_BUTTON, "viewport.nav_pan", "Pan (drag)", flags=WGF_ICON, n=ICON_MOVE
WIDGET wd_nav_ortho, WK_BUTTON, "viewport.nav_ortho", "Perspective / Orthographic (Numpad 5)", flags=WGF_ICON, aux=op_view_ortho, n=ICON_GRID
WIDGET wd_nav_px,   WK_BUTTON, "viewport.nav_right", "Right View (Numpad 3)", flags=WGF_NODRAW, aux=op_align_right
WIDGET wd_nav_py,   WK_BUTTON, "viewport.nav_top", "Top View (Numpad 7)", flags=WGF_NODRAW, aux=op_align_top
WIDGET wd_nav_pz,   WK_BUTTON, "viewport.nav_front", "Front View (Numpad 1)", flags=WGF_NODRAW, aux=op_align_front
WIDGET wd_nav_nx,   WK_BUTTON, "viewport.nav_left", "Left View (Ctrl+Numpad 3)", flags=WGF_NODRAW, aux=op_align_left
WIDGET wd_nav_ny,   WK_BUTTON, "viewport.nav_bottom", "Bottom View (Ctrl+Numpad 7)", flags=WGF_NODRAW, aux=op_align_bottom
WIDGET wd_nav_nz,   WK_BUTTON, "viewport.nav_back", "Back View (Ctrl+Numpad 1)", flags=WGF_NODRAW, aux=op_align_back

# view_align(rdi = 0 front .. 5 bottom) - the viewport under the pointer (or
#   the last one used) looks that way
view_align:
    push    rbx
    push    r12
    sub     rsp, 8
    mov     ebx, edi
    mov     edi, [rip+ptr_x]            # the area under the pointer, if it is a
    mov     esi, [rip+ptr_y]            #  3D viewport
    call    area_hit
    mov     edi, [rip+hit_area]
    test    edi, edi
    js      1f
    mov     r12d, edi
    call    area_editor
    cmp     eax, ED_VIEWPORT
    jne     1f
    mov     [rip+vp_area], r12d
1:  mov     edi, [rip+vp_area]
    test    edi, edi
    js      9f
    call    cam_ptr
    lea     rcx, [rip+align_tab]
    movss   xmm0, [rcx+rbx*8]
    movss   [rax], xmm0
    movss   xmm0, [rcx+rbx*8+4]
    movss   [rax+4], xmm0
    mov     dword ptr [rip+dirty], 1
9:  add     rsp, 8
    pop     r12
    pop     rbx
    ret

# ---- the navigation gizmo ---------------------------------------------------------
# nav_gizmo_draw - top right of the canvas (viewport.s, camera set up)
nav_gizmo_draw:
    push    rbx
    push    rbp
    push    r12
    push    r13
    push    r14
    push    r15
    sub     rsp, 24
    mov     r12d, [rip+cvs_x1]          # centre
    sub     r12d, NAV_R+20
    mov     r13d, [rip+cvs_y0]
    add     r13d, NAV_R+16
    mov     eax, [rip+ptr_x]            # a disc behind it, lit under the pointer
    sub     eax, r12d
    imul    eax, eax
    mov     ecx, [rip+ptr_y]
    sub     ecx, r13d
    imul    ecx, ecx
    add     eax, ecx
    mov     ecx, 40
    cmp     eax, (NAV_R+NAV_BALL+4)*(NAV_R+NAV_BALL+4)
    jg      1f
    mov     ecx, 70
1:  mov     edi, r12d
    sub     edi, NAV_R+NAV_BALL+2
    mov     esi, r13d
    sub     esi, NAV_R+NAV_BALL+2
    mov     edx, 2*(NAV_R+NAV_BALL+2)
    push    rcx
    push    rcx
    mov     ecx, edx
    mov     r8d, COL_SHADOW
    mov     r9d, NAV_R+NAV_BALL+2
    call    fill_rrect_a
    add     rsp, 16
    xor     ebx, ebx                    # the six directions on screen
2:  cmp     ebx, 6
    jae     3f
    mov     eax, ebx
    xor     edx, edx
    mov     ecx, 3
    div     ecx                         # eax: 0 +, 1 -; edx: the axis
    mov     r14d, edx
    lea     rcx, [rip+right]
    movss   xmm0, [rcx+r14*4]
    lea     rcx, [rip+up]
    movss   xmm1, [rcx+r14*4]
    lea     rcx, [rip+fwd]
    movss   xmm2, [rcx+r14*4]
    test    eax, eax
    jz      21f
    mov     ecx, 0x80000000             # the negative side
    movd    xmm3, ecx
    xorps   xmm0, xmm3
    xorps   xmm1, xmm3
    xorps   xmm2, xmm3
21: mov     ecx, NAV_R
    cvtsi2ss xmm3, ecx
    mulss   xmm0, xmm3
    mulss   xmm1, xmm3
    cvtss2si eax, xmm0
    add     eax, r12d
    lea     rcx, [rip+nav_sx]
    mov     [rcx+rbx*4], eax
    cvtss2si eax, xmm1
    neg     eax
    add     eax, r13d
    lea     rcx, [rip+nav_sy]
    mov     [rcx+rbx*4], eax
    lea     rcx, [rip+nav_dep]
    movss   [rcx+rbx*4], xmm2
    inc     ebx
    jmp     2b
3:  mov     ebp, 0                      # two passes: away from us, then towards
.Lng_pass:
    xor     ebx, ebx
.Lng_ball:
    cmp     ebx, 6
    jae     .Lng_next_pass
    lea     rcx, [rip+nav_dep]
    movss   xmm0, [rcx+rbx*4]
    xorps   xmm1, xmm1
    comiss  xmm0, xmm1                  # > 0: pointing away
    seta    al
    movzx   eax, al
    xor     eax, 1                      # pass 0 draws the far ones
    cmp     eax, ebp
    jne     .Lng_skip
    mov     eax, ebx
    xor     edx, edx
    mov     ecx, 3
    div     ecx
    mov     r14d, edx                   # axis
    mov     r15d, eax                   # 0 positive
    lea     rcx, [rip+nav_col]
    mov     eax, [rcx+r14*4]
    mov     [rsp], eax
    lea     rcx, [rip+nav_sx]
    mov     eax, [rcx+rbx*4]
    mov     [rsp+4], eax
    lea     rcx, [rip+nav_sy]
    mov     eax, [rcx+rbx*4]
    mov     [rsp+8], eax
    test    r15d, r15d                  # positive: a line to it, a ball, a letter
    jnz     4f
    mov     edi, r12d
    mov     esi, r13d
    mov     edx, [rsp+4]
    mov     ecx, [rsp+8]
    mov     r8d, [rsp]
    call    draw_line_aa
    mov     edi, [rsp+4]
    mov     esi, [rsp+8]
    mov     edx, NAV_BALL
    mov     r8d, [rsp]
    call    fill_circle
    lea     rcx, [rip+axis_lbl]
    mov     rdi, [rcx+r14*8]
    call    text_width
    mov     edi, [rsp+4]
    sar     eax, 1
    sub     edi, eax
    mov     esi, [rsp+8]
    sub     esi, 8
    lea     rcx, [rip+axis_lbl]
    mov     rdx, [rcx+r14*8]
    mov     ecx, COL_TEXT_DARK
    call    draw_text
    jmp     5f
4:  mov     edi, [rsp+4]                # negative: a ring
    mov     esi, [rsp+8]
    mov     edx, NAV_BALL-2
    mov     r8d, [rsp]
    call    fill_circle
    mov     edi, [rsp+4]
    mov     esi, [rsp+8]
    mov     edx, NAV_BALL-4
    mov     r8d, COL_CANVAS_TOP
    call    fill_circle
5:  lea     rax, [rip+nav_desc]         # clickable
    mov     rdi, [rax+rbx*8]
    mov     esi, [rsp+4]
    sub     esi, NAV_BALL
    mov     edx, [rsp+8]
    sub     edx, NAV_BALL+2
    mov     ecx, 2*NAV_BALL
    lea     r8, [rip+nav_dummy]
    xor     r9d, r9d
    call    wg
.Lng_skip:
    inc     ebx
    jmp     .Lng_ball
.Lng_next_pass:
    inc     ebp
    cmp     ebp, 2
    jb      .Lng_pass
    lea     ebx, [r13+NAV_R+NAV_BALL+8] # under it: zoom, pan, perspective
    lea     rdi, [rip+wd_nav_zoom]
    call    nav_handle
    lea     rdi, [rip+wd_nav_pan]
    call    nav_handle
    lea     rdi, [rip+wd_nav_ortho]
    call    nav_handle
    add     rsp, 24
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbp
    pop     rbx
    ret

# nav_handle(rdi=widget; ebx = y, advanced; r12d = the gizmo's centre x)
nav_handle:
    mov     esi, r12d
    sub     esi, 12
    mov     edx, ebx
    mov     ecx, 24
    lea     r8, [rip+nav_dummy]
    xor     r9d, r9d
    sub     rsp, 8
    call    wg
    add     rsp, 8
    add     ebx, 26
    ret

# nav_area - the viewport under the pointer -> vp_area, eax = it (-1)
nav_area:
    sub     rsp, 8
    mov     edi, [rip+ptr_x]
    mov     esi, [rip+ptr_y]
    call    area_hit
    mov     eax, [rip+hit_area]
    add     rsp, 8
    test    eax, eax
    js      9f
    mov     [rip+vp_area], eax
9:  ret

# nav_press(edi=widget id) -> eax = 1 when it is the gizmo's: a ball (a click
#   looks along it, a drag orbits), the zoom or pan handle (a drag)
nav_press:
    push    rbx
    call    wg_find
    test    rax, rax
    jz      8f
    mov     rbx, [rax+32]               # (E_DESC)
    lea     rcx, [rip+nav_desc]         # a ball?
    xor     edx, edx
1:  cmp     rbx, [rcx+rdx*8]
    je      2f
    inc     edx
    cmp     edx, 6
    jb      1b
    lea     rcx, [rip+wd_nav_zoom]
    cmp     rbx, rcx
    je      3f
    lea     rcx, [rip+wd_nav_pan]
    cmp     rbx, rcx
    je      4f
8:  xor     eax, eax
    pop     rbx
    ret
2:  mov     rax, [rbx+WD_AUX]
    mov     [rip+nav_op], rax
    call    nav_area
    mov     [rip+drag_node], eax
    mov     dword ptr [rip+drag_mode], DRAG_NAV
    mov     eax, [rip+ptr_x]
    mov     [rip+press_x], eax
    mov     eax, [rip+ptr_y]
    mov     [rip+press_y], eax
    mov     dword ptr [rip+press_mods], 0
    jmp     9f
3:  call    nav_area                    # zoom: from this distance
    mov     [rip+drag_node], eax
    mov     edi, eax
    call    cam_load
    mov     eax, [rip+cam_dist]
    mov     [rip+nav_d0], eax
    mov     eax, [rip+ptr_y]
    mov     [rip+nav_y0], eax
    mov     dword ptr [rip+drag_mode], DRAG_ZOOM
    jmp     9f
4:  call    nav_area                    # pan: as a Shift drag on the canvas
    mov     [rip+drag_node], eax
    mov     dword ptr [rip+drag_mode], DRAG_PAN
9:  mov     eax, 1
    pop     rbx
    ret

# nav_zoom_drag(esi=pointer y) - up zooms in, down out (1% a pixel)
nav_zoom_drag:
    push    rbx
    mov     ebx, esi
    mov     edi, [rip+drag_node]
    call    cam_load
    mov     eax, [rip+nav_d0]
    mov     [rip+cam_dist], eax
    sub     ebx, [rip+nav_y0]           # 1 + |dy| / 100, or its inverse
    mov     eax, ebx
    neg     eax
    cmovs   eax, ebx
    cvtsi2ss xmm0, eax
    mulss   xmm0, [rip+nz_k]
    addss   xmm0, [rip+nz_one]
    test    ebx, ebx
    jns     1f
    movss   xmm1, [rip+nz_one]
    divss   xmm1, xmm0
    movss   xmm0, xmm1
1:  call    vp_zoom_by
    mov     edi, [rip+drag_node]
    call    cam_store
    mov     dword ptr [rip+dirty], 1
    pop     rbx
    ret

# nav_release - a ball pressed and let go without a drag: its view
nav_release:
    mov     dword ptr [rip+drag_mode], 0
    mov     rdi, [rip+nav_op]
    test    rdi, rdi
    jz      9f
    jmp     run_op_ui
9:  ret

# view.toggle_ortho - the viewport under the pointer (or the last one used)
do_ortho:
    sub     rsp, 8
    call    nav_area
    mov     edi, [rip+vp_area]
    test    edi, edi
    js      9f
    call    cam_load
    xor     dword ptr [rip+cam_ortho], 1
    mov     edi, [rip+vp_area]
    call    cam_store
    mov     dword ptr [rip+dirty], 1
9:  add     rsp, 8
    ret

chk_ortho:
    sub     rsp, 8
    mov     edi, [rip+vp_area]
    xor     eax, eax
    test    edi, edi
    js      9f
    call    cam_load
    mov     eax, [rip+cam_ortho]
9:  add     rsp, 8
    ret

# ---- the brush settings (sculpt, texture paint) ----------------------------------
# tool_settings_draw - a bar at the bottom of the canvas while a brush mode is
#   on: radius, strength and the brush's toggles
tool_settings_draw:
    push    rbx
    push    r12
    push    r13
    sub     rsp, 16
    xor     eax, eax
    cmp     dword ptr [rip+sc_obj], 0
    jne     1f
    cmp     dword ptr [rip+pt_obj], 0
    je      9f
    mov     eax, 1
1:  mov     [rsp], eax                  # 0 sculpt, 1 paint
    mov     ebx, [rip+cvs_x1]           # centred, 540 wide
    add     ebx, [rip+cvs_x0]
    sar     ebx, 1
    sub     ebx, 270
    mov     eax, [rip+cvs_x0]
    add     eax, 250                    # (not over the redo panel)
    cmp     ebx, eax
    cmovl   ebx, eax
    mov     r12d, [rip+cvs_y1]
    sub     r12d, 38
    mov     edi, ebx                    # its backing
    sub     edi, 6
    lea     esi, [r12-5]
    mov     edx, 552
    mov     ecx, WG_H+10
    mov     r8d, COL_PANE_BG
    mov     r9d, 8
    push    210
    push    210
    call    fill_rrect_a
    add     rsp, 16
    mov     r13d, ebx
    add     r13d, 540                   # the limit for tool_btn
    lea     rdi, [rip+wd_ts_srad]       # radius, strength
    lea     r8, [rip+sc_radius]
    cmp     dword ptr [rsp], 0
    je      2f
    lea     rdi, [rip+wd_ts_prad]
    lea     r8, [rip+pt_radius]
2:  mov     esi, ebx
    mov     edx, r12d
    mov     ecx, 150
    xor     r9d, r9d
    call    wg
    add     ebx, 158
    lea     rdi, [rip+wd_ts_sstr]
    lea     r8, [rip+sc_strength]
    cmp     dword ptr [rsp], 0
    je      3f
    lea     rdi, [rip+wd_ts_pstr]
    lea     r8, [rip+pt_strength]
3:  mov     esi, ebx
    mov     edx, r12d
    mov     ecx, 180
    cmp     dword ptr [rsp], 0          # (paint: narrower, for its colour)
    je      31f
    mov     ecx, 150
    sub     ebx, 30
31: xor     r9d, r9d
    call    wg
    add     ebx, 192
    cmp     dword ptr [rsp], 0
    jne     4f
    lea     rdi, [rip+wd_ts_sym]        # sculpt: its toggles
    call    tool_btn
    lea     rdi, [rip+wd_ts_dyn]
    call    tool_btn
    lea     rdi, [rip+wd_ts_lazy]
    call    tool_btn
    lea     rdi, [rip+wd_ts_pstrp]
    call    tool_btn
    lea     rdi, [rip+wd_ts_pradp]
    call    tool_btn
    jmp     9f
4:  cmp     dword ptr [rip+vp_on], 2    # weight paint: the weight, the bone
    je      6f
    lea     rdi, [rip+pt_col]           # paint: the colour (a picker) and
    call    ts_unpack                   #  swatches
    lea     rdi, [rip+wd_ts_colf]
    mov     esi, ebx
    mov     edx, r12d
    mov     ecx, 56
    lea     r8, [rip+ts_colf]
    xor     r9d, r9d
    call    wg
    add     ebx, 62
    xor     r13d, r13d
5:  lea     rax, [rip+ts_swatch]
    mov     r8d, [rax+r13*4]
    lea     edi, [rbx+1]
    lea     esi, [r12+2]
    mov     edx, 20
    mov     ecx, WG_H-4
    mov     r9d, 4
    call    fill_rrect
    lea     rdi, [rip+wd_ts_sw]
    mov     esi, ebx
    mov     edx, r12d
    mov     ecx, 22
    xor     r8d, r8d
    mov     r9d, r13d
    call    wg
    test    eax, eax
    jz      51f
    lea     rax, [rip+ts_swatch]
    mov     eax, [rax+r13*4]
    or      eax, 0xff000000
    mov     [rip+pt_col], eax
51: add     ebx, 24
    inc     r13d
    cmp     r13d, 6
    jb      5b
    jmp     9f
6:  lea     rdi, [rip+wd_ts_wt]
    mov     esi, ebx
    mov     edx, r12d
    mov     ecx, 96
    lea     r8, [rip+wp_value]
    xor     r9d, r9d
    call    wg
    add     ebx, 102
    call    ts_bones                    # (the armature's bones, its active one)
    lea     rdi, [rip+wd_ts_bone]
    mov     esi, ebx
    mov     edx, r12d
    mov     ecx, 120
    lea     r8, [rip+ts_bone]
    xor     r9d, r9d
    call    wg
9:  add     rsp, 16
    pop     r13
    pop     r12
    pop     rbx
    ret

# ---- the header tools ---------------------------------------------------------------
# vp_header_tools(edi=x, esi=header y, edx=right limit) - a 3D viewport's
#   header: mode | select mode (edit) | shading | grid, snap
vp_header_tools:
    push    rbx
    push    r12
    push    r13
    sub     rsp, 16
    mov     ebx, edi                    # x
    lea     r12d, [rsi+1]               # y
    mov     r13d, edx                   # limit
    xor     ecx, ecx                    # the mode now
    mov     [rsp], ecx
1:  inc     ecx
    cmp     ecx, 6
    jae     2f
    mov     [rsp+4], ecx
    lea     rax, [rip+mode_ops]
    mov     rdi, [rax+rcx*8]
    call    op_checked
    mov     ecx, [rsp+4]
    cmp     eax, 1
    jne     1b
    mov     [rsp], ecx
2:  mov     eax, [rsp]
    mov     [rip+vp_mode_sel], eax
    mov     [rip+vp_mode_was], eax
    lea     eax, [rbx+130]
    cmp     eax, r13d
    jg      9f
    lea     rdi, [rip+wd_vp_mode]
    mov     esi, ebx
    mov     edx, r12d
    mov     ecx, 130
    lea     r8, [rip+vp_mode_sel]
    xor     r9d, r9d
    call    wg
    add     ebx, 136
    lea     rdi, [rip+wd_vh_mv]         # View / Select / Object (Mesh) menus
    mov     edx, 50
    call    hdr_btn
    lea     rdi, [rip+wd_vh_ms]
    mov     edx, 56
    call    hdr_btn
    lea     rdi, [rip+wd_vh_mo]
    cmp     dword ptr [rsp], 1
    jne     21f
    lea     rdi, [rip+wd_vh_mm]
21: mov     edx, 60
    call    hdr_btn
    add     ebx, 6
    cmp     dword ptr [rsp], 1          # edit mode: vertex / edge / face
    jne     3f
    lea     rdi, [rip+wd_sm_v]
    call    tool_btn
    lea     rdi, [rip+wd_sm_e]
    call    tool_btn
    lea     rdi, [rip+wd_sm_f]
    call    tool_btn
    add     ebx, 10
3:  lea     rdi, [rip+wd_sh_wire]
    call    tool_btn
    lea     rdi, [rip+wd_sh_solid]
    call    tool_btn
    lea     rdi, [rip+wd_sh_mat]
    call    tool_btn
    lea     rdi, [rip+wd_sh_rend]
    call    tool_btn
    add     ebx, 10
    lea     rdi, [rip+wd_vh_grid]
    call    tool_btn
    lea     rdi, [rip+wd_vh_snap]
    call    tool_btn
    lea     rdi, [rip+wd_vh_xf]         # pivot and orientation (orient.s),
    call    tool_btn                    #  overlays
    lea     rdi, [rip+wd_vh_ov]
    call    tool_btn
9:  add     rsp, 16
    pop     r13
    pop     r12
    pop     rbx
    ret

# vh_menu(rdi=menu index: 2 View, 3 Select, 5 Object - Mesh in edit mode) -
#   that menu bar menu, as a menu at the header's button
vh_menu:
    sub     rsp, 8
    cmp     edi, 5
    jne     1f
    cmp     dword ptr [rip+edit_obj], 0
    je      1f
    mov     edi, 6
1:  lea     rax, [rip+menu_counts]
    mov     esi, [rax+rdi*4]
    lea     rax, [rip+menu_items]
    mov     rdi, [rax+rdi*8]
    call    ctx_open_list
    add     rsp, 8
    ret

vh_xf:
    sub     rsp, 8
    lea     rdi, [rip+xf_list]
    mov     esi, [rip+xf_list_cnt]
    call    ctx_open_list
    add     rsp, 8
    ret

vh_overlays:
    sub     rsp, 8
    lea     rdi, [rip+ov_list]
    mov     esi, ov_list_n
    call    ctx_open_list
    add     rsp, 8
    ret

# hdr_btn(rdi=widget, edx=width; ebx = x, advanced; r12d = y; r13d = limit)
hdr_btn:
    lea     eax, [rbx+rdx]
    cmp     eax, r13d
    jg      9f
    push    rdx
    mov     esi, ebx
    mov     ecx, edx
    mov     edx, r12d
    lea     r8, [rip+nav_dummy]
    xor     r9d, r9d
    call    wg
    pop     rdx
    lea     ebx, [rbx+rdx+4]
9:  ret

# tool_btn(rdi=widget; ebx = x, advanced; r12d = y; r13d = the limit)
tool_btn:
    lea     eax, [rbx+24]
    cmp     eax, r13d
    jg      9f
    mov     esi, ebx
    mov     edx, r12d
    mov     ecx, 24
    lea     r8, [rip+nav_dummy]
    xor     r9d, r9d
    sub     rsp, 8
    call    wg
    add     rsp, 8
    add     ebx, 26
9:  ret

# ---- paint colour, swatches, weight paint's bone ------------------------------------
WIDGET wd_ts_colf, WK_COLOR, "paint.colour", cb=ts_col_cb, tip="The paint colour (a click opens the colour picker)"
WIDGET wd_ts_sw,   WK_BUTTON, "paint.swatch", flags=WGF_NODRAW, tip="Paint with this colour"
WIDGET wd_ts_wt,   WK_SLIDER, "paint.weight", "Weight", 0.0, 1.0, 0.005, 2, tip="The weight painted towards (1: the bone moves it fully)"
WIDGET wd_ts_bone, WK_ENUM, "paint.bone", flags=WGF_DYN, cb=ts_bone_cb, aux=ts_bone_names, tip="The bone whose weights are painted"
.section .rodata
.align 4
ts_swatch:      .long 0xffffff, 0x101010, 0xd04020, 0xe0b030, 0x40a050, 0x3070d0
f_255v:         .float 255.0
s_nobone:       .asciz "No bone"
.section .bss
.align 16
ts_colf:        .skip 16
ts_bone:        .skip 4
.align 8
ts_arm:         .skip 8
ts_blbl:        .skip 8*130
.text
# ts_unpack(rdi=&0xAARRGGBB) -> ts_colf (linear: the display value squared)
ts_unpack:
    mov     eax, [rdi]
    mov     ecx, 2
1:  mov     edx, eax
    and     edx, 255
    cvtsi2ss xmm0, edx
    divss   xmm0, [rip+f_255v]
    mulss   xmm0, xmm0
    lea     r8, [rip+ts_colf]
    movss   [r8+rcx*4], xmm0
    shr     eax, 8
    dec     ecx
    jns     1b
    ret
ts_col_cb:                              # rdi = ts_colf -> pt_col
    sub     rsp, 8
    call    cpk_rgb_of
    or      eax, 0xff000000
    mov     [rip+pt_col], eax
    add     rsp, 8
    ret

# ts_bones - ts_arm = the bones of the painted mesh's armature, ts_bone its
#   active one + 1
ts_bones:
    sub     rsp, 8
    mov     qword ptr [rip+ts_arm], 0
    mov     dword ptr [rip+ts_bone], 0
    mov     edi, [rip+active_obj]
    call    obj_get
    test    rax, rax
    jz      9f
    mov     rdi, rax
    call    arm_mod_target
    test    rax, rax
    jz      9f
    mov     rdi, rax
    call    arm_of
    test    rax, rax
    jz      9f
    mov     [rip+ts_arm], rax
    mov     eax, [rax+8]                # (AR_ACT)
    inc     eax
    mov     [rip+ts_bone], eax
9:  add     rsp, 8
    ret
ts_bone_names:                          # -> rax = labels, edx = count
    sub     rsp, 8
    xor     edx, edx
    mov     rax, [rip+ts_arm]
    test    rax, rax
    jz      1f
    mov     edx, [rax+4]                # (AR_N)
1:  lea     rdi, [rip+ts_blbl]
    lea     rsi, [rip+s_nobone]
    lea     rcx, [rip+ts_bone_name]
    mov     r8d, 129
    call    pnl_list
    mov     edx, eax
    lea     rax, [rip+ts_blbl]
    add     rsp, 8
    ret
ts_bone_name:                           # edi = bone -> rax (its name)
    imul    eax, edi, 128
    mov     rcx, [rip+ts_arm]
    lea     rax, [rcx+64+rax]
    ret
ts_bone_cb:                             # rdi = &ts_bone: the active bone
    mov     eax, [rdi]
    dec     eax
    js      9f
    mov     rcx, [rip+ts_arm]
    test    rcx, rcx
    jz      9f
    mov     [rcx+8], eax                # (AR_ACT: no geometry changes)
    mov     dword ptr [rip+dirty], 1
9:  ret

# ---- modes and snapping (the Ctrl+Tab and Shift+S pies, menus, scripts) ---------
OPERATOR op_mode_object, "mode.object", "Object Mode", do_mode_set, check=chk_mode_set, arg=0, flags=OPF_AI_SAFE|OPF_QUIET|OPF_HIDDEN, doc="Leave edit, sculpt or paint mode"
OPERATOR op_mode_edit, "mode.edit", "Edit Mode", do_mode_set, check=chk_mode_set, arg=1, flags=OPF_AI_SAFE|OPF_QUIET|OPF_HIDDEN, doc="Edit the active mesh's vertices, edges and faces"
OPERATOR op_mode_sculpt, "mode.sculpt", "Sculpt Mode", do_mode_set, check=chk_mode_set, arg=2, flags=OPF_AI_SAFE|OPF_QUIET|OPF_HIDDEN, doc="Sculpt the active mesh with brushes"
OPERATOR op_mode_tex, "mode.texture_paint", "Texture Paint", do_mode_set, check=chk_mode_set, arg=3, flags=OPF_AI_SAFE|OPF_QUIET|OPF_HIDDEN, doc="Paint the active mesh's image texture"
OPERATOR op_mode_vcol, "mode.vertex_paint", "Vertex Paint", do_mode_set, check=chk_mode_set, arg=4, flags=OPF_AI_SAFE|OPF_QUIET|OPF_HIDDEN, doc="Paint the active mesh's vertex colours"
OPERATOR op_mode_wgt, "mode.weight_paint", "Weight Paint", do_mode_set, check=chk_mode_set, arg=5, flags=OPF_AI_SAFE|OPF_QUIET|OPF_HIDDEN, doc="Paint the active mesh's skin weights"
OPERATOR op_cursor_sel, "view.cursor_to_selected", "Cursor to Selected", do_cursor_sel, flags=OPF_AI_SAFE|OPF_OBJECT, poll=poll_sel, doc="Put the 3D cursor in the middle of the selected objects"
OPERATOR op_sel_cursor, "object.to_cursor", "Selection to Cursor", do_sel_cursor, arg=0, flags=OPF_AI_SAFE|OPF_UNDO|OPF_OBJECT, poll=poll_sel, doc="Move the selected objects to the 3D cursor, keeping their spacing"
OPERATOR op_sel_grid, "object.to_grid", "Selection to Grid", do_sel_cursor, arg=1, flags=OPF_AI_SAFE|OPF_UNDO|OPF_OBJECT, poll=poll_sel, doc="Move each selected object to the nearest point of the 1 m grid"

# mode_now -> eax = the active object's mode: 0 object, 1 edit, 2 sculpt,
#   3 texture / 4 vertex / 5 weight paint (the order of mode_ops)
.globl mode_now
mode_now:
    push    rbx
    mov     ebx, 1
1:  cmp     ebx, 6
    jae     2f
    lea     rax, [rip+mode_ops]
    mov     rdi, [rax+rbx*8]
    call    op_checked
    cmp     eax, 1
    je      3f
    inc     ebx
    jmp     1b
2:  xor     ebx, ebx
3:  mov     eax, ebx
    pop     rbx
    ret

# chk_mode_set(rdi=mode) -> eax = 1 while it is the mode
chk_mode_set:
    push    rbx
    mov     ebx, edi
    call    mode_now
    cmp     eax, ebx
    sete    al
    movzx   eax, al
    pop     rbx
    ret

# do_mode_set(rdi=mode) - leave the mode we are in, enter that one
do_mode_set:
    push    rbx
    push    r12
    sub     rsp, 8
    mov     ebx, edi
    call    mode_now
    mov     r12d, eax
    cmp     eax, ebx
    je      9f
    test    r12d, r12d
    jz      1f
    lea     rax, [rip+mode_ops]
    mov     rdi, [rax+r12*8]
    call    run_op
1:  test    ebx, ebx
    jz      9f
    lea     rax, [rip+mode_ops]
    mov     rdi, [rax+rbx*8]
    call    run_op
9:  mov     dword ptr [rip+dirty], 1
    add     rsp, 8
    pop     r12
    pop     rbx
    ret

# sel_mid -> xmm0..xmm2 = the middle of the selected objects, eax = how many
sel_mid:
    push    rbx
    push    r12
    sub     rsp, 24
    xorps   xmm0, xmm0
    movups  [rsp], xmm0
    xor     ebx, ebx
    xor     r12d, r12d
1:  cmp     ebx, [rip+obj_count]
    jae     2f
    mov     edi, ebx
    call    obj_at
    inc     ebx
    test    dword ptr [rax+OB_FLAGS], OBF_SELECTED
    jz      1b
    movups  xmm0, [rsp]
    movss   xmm1, [rax+OB_LOC]
    movss   xmm2, [rax+OB_LOC+4]
    movss   xmm3, [rax+OB_LOC+8]
    unpcklps xmm1, xmm2
    movlhps xmm1, xmm3
    addps   xmm0, xmm1
    movups  [rsp], xmm0
    inc     r12d
    jmp     1b
2:  xorps   xmm0, xmm0
    xorps   xmm1, xmm1
    xorps   xmm2, xmm2
    mov     eax, r12d
    test    eax, eax
    jz      9f
    cvtsi2ss xmm3, eax
    movss   xmm0, [rsp]
    divss   xmm0, xmm3
    movss   xmm1, [rsp+4]
    divss   xmm1, xmm3
    movss   xmm2, [rsp+8]
    divss   xmm2, xmm3
9:  add     rsp, 24
    pop     r12
    pop     rbx
    ret

# do_cursor_sel - view.cursor_to_selected
do_cursor_sel:
    sub     rsp, 8
    call    sel_mid
    add     rsp, 8
    test    eax, eax
    jz      9f
    movss   [rip+cursor_pos], xmm0
    movss   [rip+cursor_pos+4], xmm1
    movss   [rip+cursor_pos+8], xmm2
    mov     dword ptr [rip+dirty], 1
9:  ret

# do_sel_cursor(rdi=0: to the cursor, keeping the spacing; 1: each to the
#   nearest whole metre)
do_sel_cursor:
    push    rbx
    push    r12
    sub     rsp, 24
    mov     r12d, edi
    call    sel_mid
    movss   xmm3, [rip+cursor_pos]      # the step for each: cursor - middle
    subss   xmm3, xmm0
    movss   [rsp], xmm3
    movss   xmm3, [rip+cursor_pos+4]
    subss   xmm3, xmm1
    movss   [rsp+4], xmm3
    movss   xmm3, [rip+cursor_pos+8]
    subss   xmm3, xmm2
    movss   [rsp+8], xmm3
    xor     ebx, ebx
1:  cmp     ebx, [rip+obj_count]
    jae     9f
    mov     edi, ebx
    call    obj_at
    inc     ebx
    test    dword ptr [rax+OB_FLAGS], OBF_SELECTED
    jz      1b
    xor     ecx, ecx
2:  movss   xmm0, [rax+OB_LOC+rcx*4]
    test    r12d, r12d
    jnz     3f
    addss   xmm0, [rsp+rcx*4]
    jmp     4f
3:  roundss xmm0, xmm0, 0               # (to nearest)
4:  movss   [rax+OB_LOC+rcx*4], xmm0
    inc     ecx
    cmp     ecx, 3
    jb      2b
    jmp     1b
9:  mov     dword ptr [rip+dirty], 1
    add     rsp, 24
    pop     r12
    pop     rbx
    ret

# vp_mode_cb - the header's mode choice: leave the mode, enter the new one
vp_mode_cb:
    push    rbx
    mov     ebx, [rip+vp_mode_sel]
    mov     eax, [rip+vp_mode_was]
    cmp     eax, ebx
    je      9f
    test    eax, eax
    jz      1f
    lea     rcx, [rip+mode_ops]
    mov     rdi, [rcx+rax*8]
    call    run_op_ui
1:  test    ebx, ebx
    jz      9f
    lea     rcx, [rip+mode_ops]
    mov     rdi, [rcx+rbx*8]
    call    run_op_ui
9:  pop     rbx
    ret

.section .note.GNU-stack,"",@progbits
