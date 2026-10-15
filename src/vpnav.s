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

.equ NAV_R,     34                      # the gizmo's radius
.equ NAV_BALL,  9

.section .rodata
.align 4
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

.section .bss
.align 4
vp_mode_sel:    .skip 4                 # the header's mode choice
vp_mode_was:    .skip 4
nav_dummy:      .skip 4
nav_sx:         .skip 4*6               # each ball on screen, its depth
nav_sy:         .skip 4*6
nav_dep:        .skip 4*6

.text

OPERATOR op_align_front,  "view.align_front",  "Front View",  view_align, arg=0, key=79, flags=OPF_AI_SAFE|OPF_QUIET, doc="Look at the scene from the front (along -Z)"
OPERATOR op_align_back,   "view.align_back",   "Back View",   view_align, arg=1, key=79|KM_CTRL, flags=OPF_AI_SAFE|OPF_QUIET, doc="Look at the scene from the back"
OPERATOR op_align_right,  "view.align_right",  "Right View",  view_align, arg=2, key=81, flags=OPF_AI_SAFE|OPF_QUIET, doc="Look at the scene from the right (along -X)"
OPERATOR op_align_left,   "view.align_left",   "Left View",   view_align, arg=3, key=81|KM_CTRL, flags=OPF_AI_SAFE|OPF_QUIET, doc="Look at the scene from the left"
OPERATOR op_align_top,    "view.align_top",    "Top View",    view_align, arg=4, key=71, flags=OPF_AI_SAFE|OPF_QUIET, doc="Look down on the scene from above"
OPERATOR op_align_bottom, "view.align_bottom", "Bottom View", view_align, arg=5, key=71|KM_CTRL, flags=OPF_AI_SAFE|OPF_QUIET, doc="Look up at the scene from below"
OPERATOR op_toggle_snap,  "view.toggle_snap",  "Snap",        op_toggle_flag, op_check_flag, snap_on, flags=OPF_AI_SAFE|OPF_QUIET, doc="Snap moves, turns and scales to whole steps (Ctrl does the opposite while you drag)"

WIDGET wd_vp_mode,  WK_ENUM, "viewport.mode", "Mode", cb=vp_mode_cb, aux=mode_lbl, n=6, tip="The mode of the active object: edit, sculpt or paint it"
WIDGET wd_sm_v,     WK_BUTTON, "viewport.select_vertex", "Vertex select (1)", flags=WGF_ICON, aux=op_selmode_v, n=ICON_DOT
WIDGET wd_sm_e,     WK_BUTTON, "viewport.select_edge", "Edge select (2)", flags=WGF_ICON, aux=op_selmode_e, n=ICON_MINUS
WIDGET wd_sm_f,     WK_BUTTON, "viewport.select_face", "Face select (3)", flags=WGF_ICON, aux=op_selmode_f, n=ICON_STOP
WIDGET wd_sh_wire,  WK_BUTTON, "viewport.shading_wireframe", "Wireframe", flags=WGF_ICON, aux=op_shade_wire, n=ICON_WIRE
WIDGET wd_sh_solid, WK_BUTTON, "viewport.shading_solid", "Solid", flags=WGF_ICON, aux=op_shade_solid, n=ICON_SOLID
WIDGET wd_sh_mat,   WK_BUTTON, "viewport.shading_material", "Material Preview", flags=WGF_ICON, aux=op_shade_mat, n=ICON_MATERIAL
WIDGET wd_vh_grid,  WK_BUTTON, "viewport.grid", "Ground Grid", flags=WGF_ICON, aux=op_view_grid, n=ICON_GRID
WIDGET wd_vh_snap,  WK_BUTTON, "viewport.snap", "Snap", flags=WGF_ICON, aux=op_toggle_snap, n=ICON_SNAP
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
    add     rsp, 24
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbp
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
    add     ebx, 140
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
    add     ebx, 10
    lea     rdi, [rip+wd_vh_grid]
    call    tool_btn
    lea     rdi, [rip+wd_vh_snap]
    call    tool_btn
9:  add     rsp, 16
    pop     r13
    pop     r12
    pop     rbx
    ret

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
