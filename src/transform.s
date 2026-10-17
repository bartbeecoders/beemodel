# =============================================================================
#  BeeModel - transforms: Blender-style modal grab / rotate / scale (G R S)
#  with axis constraints (X Y Z), snapping (Ctrl), numeric input, cancel
#  (Esc / RMB) and on-screen gizmos for the Move / Rotate / Scale tools.
#
#  The selection is snapshotted when a transform starts; every update starts
#  from the snapshot, so cancelling is exact and nothing drifts.
# =============================================================================
.intel_syntax noprefix
.include "const.inc"
.include "macros.inc"

# exports
.globl tm_mode
.globl tm_area
.globl tm_drag
.globl tm_start
.globl tm_motion
.globl tm_key
.globl tm_confirm
.globl tm_cancel
.globl tm_draw
.globl gizmo_draw
.globl gizmo_pick
.globl gizmo_hover
.globl vp_prepare
.globl tm_custom
.globl tm_noundo
.globl tm_start_value
.globl tm_vint
.globl tm_axis
.globl tm_value
.globl tm_wheel

.equ TM_MAX,        MAX_OBJECTS
.equ TS_H,          0               # snapshot entry: handle, loc, rot, scale
.equ TS_XF,         4
.equ TS_SZ,         40
.equ GIZMO_PX,      80              # handle length on screen (logical px)

.section .bss
.align 8
tm_snap:        .skip TM_MAX*TS_SZ
tr_ra:          .skip 36                # turning about an axis: its matrix,
tr_r0:          .skip 36                #  an object's, a location
tr_v:           .skip 12
tm_mode:        .skip 4             # 0 none, 1 grab, 2 rotate, 3 scale, 4 value
tm_noundo:      .skip 4             # the caller already recorded the undo step
tm_vint:        .skip 4             # value mode: an integer the wheel changes (0 = none)
.align 8
tm_vfn:         .skip 8             # value mode: apply(xmm0 = value)
tm_vcancel:     .skip 8
tm_vconfirm:    .skip 8
tm_axis:        .skip 4             # 0 free, 1 X, 2 Y, 3 Z
tm_drag:        .skip 4             # started by a gizmo drag: release confirms
tm_area:        .skip 4
tm_n:           .skip 4
tm_numlen:      .skip 4
gizmo_hover:    .skip 4
tm_pivot:       .skip 12
tm_sx:          .skip 4             # start pointer (physical)
tm_sy:          .skip 4
tm_mx:          .skip 4             # current pointer (physical)
tm_my:          .skip 4
tm_cx:          .skip 4             # pivot on screen
tm_cy:          .skip 4
tm_depth:       .skip 4             # pivot depth
tm_prev:        .skip 4             # rotate: previous pointer angle
tm_accum:       .skip 4             # rotate: accumulated angle
tm_value:       .skip 12            # applied amount (for display)
tm_num:         .skip 16
tm_text:        .skip 96
g_tmp:          .skip 48

.section .rodata
.align 4
tf_one:         .float 1.0
tf_half:        .float 0.5
tf_ten:         .float 10.0
tf_deg2rad:     .float 0.017453293
tf_rad2deg:     .float 57.29578
tf_step:        .float 0.2617994        # 15 degrees
tf_pi:          .float 3.1415927
tf_2pi:         .float 6.2831853
tf_far:         .float 1000.0
tf_pick:        .float 8.0
tf_big:         .float 1.0e30
tf_ring:        .float 0.9
tf_box:         .float 0.08
s_move:         .asciz "Move"
s_rotate:       .asciz "Rotate"
s_scale:        .asciz "Scale"
s_ax:           .asciz "  XYZN"
s_sep:          .asciz "  "
s_deg:          .asciz " deg"
s_comma:        .asciz ", "
s_cursor:       .asciz "|"
s_hint:         .asciz "    X/Y/Z axis   Ctrl snap   type a value   Enter / LMB confirm   Esc / RMB cancel"
s_none:         .asciz "  nothing selected"
s_cancelled:    .asciz "  transform cancelled"
s_times:        .asciz "   segments "
.align 16
tf_absm:        .long 0x7fffffff, 0, 0, 0

.section .data
.align 8
mode_names:     .quad 0, s_move, s_rotate, s_scale, 0   # 4: value mode (label set at start)
axis_vec:       .float 1,0,0,  0,1,0,  0,0,1
tm_custom:      .float 0,1,0                # axis 4: a direction set by the caller (normal)
axis_col:       .long COL_AXIS_X, COL_AXIS_Y, COL_AXIS_Z, COL_ACCENT
.section .rodata

OPERATOR op_grab,   "transform.grab",   "Grab / Move", op_tm_start, arg=1, key=KEY_G, flags=OPF_QUIET, doc="Move the selection (X/Y/Z constrain, Ctrl snaps)"
OPERATOR op_rotate, "transform.rotate", "Rotate",      op_tm_start, arg=2, key=KEY_R, flags=OPF_QUIET, doc="Rotate the selection with the mouse"
OPERATOR op_scale,  "transform.scale",  "Scale",       op_tm_start, arg=3, key=KEY_S, flags=OPF_QUIET, doc="Scale the selection with the mouse"

.section .data
.align 4
.globl snap_on
snap_on:        .long 0                 # snapping on without Ctrl (viewport header)
.text

# tm_comp -> eax = nonzero in a component mode (mesh or curve edit mode):
#   the edit_tm_* functions move the selected parts (eax only)
tm_comp:
    mov     eax, [rip+edit_obj]
    or      eax, [rip+cve_obj]
    or      eax, [rip+arm_mode]
    ret

op_tm_start:
    xor     esi, esi
    xor     edx, edx
    jmp     tm_start

# vp_prepare(edi=area) - canvas + camera of a viewport area for projections
vp_prepare:
    push    rbx
    mov     ebx, edi
    call    area_node_rect
    mov     ecx, [rax+12]
    mov     [rip+cvs_x0], ecx
    add     ecx, [rax+20]
    mov     [rip+cvs_x1], ecx
    mov     ecx, [rax+16]
    add     ecx, PANE_HDR_H
    mov     [rip+cvs_y0], ecx
    mov     ecx, [rax+16]
    add     ecx, [rax+24]
    mov     [rip+cvs_y1], ecx
    mov     edi, ebx
    call    cam_load
    call    cam_setup
    pop     rbx
    ret

# proj_world(rdi=world vec3) -> xmm0 = x, xmm1 = y (physical), xmm2 = depth
proj_world:
    sub     rsp, 24
    lea     rsi, [rip+g_tmp]
    call    to_cam
    movss   xmm2, [rip+g_tmp+8]
    maxss   xmm2, [rip+f_near]
    movss   [rip+g_tmp+8], xmm2
    lea     rdi, [rip+g_tmp]
    lea     rsi, [rsp]
    call    project
    movss   xmm0, [rsp]
    movss   xmm1, [rsp+4]
    movss   xmm2, [rip+g_tmp+8]
    add     rsp, 24
    ret

# atan2_(xmm0=y, xmm1=x) -> xmm0
atan2_:
    sub     rsp, 8
    movss   [rsp], xmm0
    movss   [rsp+4], xmm1
    fld     dword ptr [rsp]
    fld     dword ptr [rsp+4]
    fpatan
    fstp    dword ptr [rsp]
    movss   xmm0, [rsp]
    add     rsp, 8
    ret

# round_to(xmm0=value, xmm1=step) -> xmm0
round_to:
    divss   xmm0, xmm1
    roundss xmm0, xmm0, 0
    mulss   xmm0, xmm1
    ret

# pointer_px(edi=x, esi=y logical) -> tm_mx / tm_my
pointer_px:
    push    rsi
    call    to_px
    cvtsi2ss xmm0, eax
    movss   [rip+tm_mx], xmm0
    pop     rdi
    call    to_px
    cvtsi2ss xmm0, eax
    movss   [rip+tm_my], xmm0
    ret

# tm_snapping -> eax = 1 while snapping: the Snap toggle, inverted by Ctrl
tm_snapping:
    xor     eax, eax
    test    dword ptr [rip+key_mods], MOD_CTRL
    setnz   al
    xor     eax, [rip+snap_on]
    ret

# -----------------------------------------------------------------------------
# tm_start(edi=mode, esi=axis, edx=drag)
# -----------------------------------------------------------------------------
tm_start:
    push    rbx
    push    r12
    push    r13
    push    r14
    sub     rsp, 8
    cmp     dword ptr [rip+tm_mode], 0
    jne     .Lts_out
    mov     r12d, edi
    mov     r13d, esi
    mov     r14d, edx
    mov     edi, [rip+vp_area]          # needs a viewport for the projection
    test    edi, edi
    js      .Lts_out
    call    area_editor
    cmp     eax, ED_VIEWPORT
    jne     .Lts_out
    call    tm_comp
    test    eax, eax # edit mode: the selected vertices
    je      0f
    cmp     dword ptr [rip+tm_noundo], 0
    jne     81f
    lea     rcx, [rip+mode_names]
    mov     rdi, [rcx+r12*8]
    call    undo_push
81: lea     rdi, [rip+tm_pivot]
    call    edit_tm_snapshot
    mov     [rip+tm_n], eax
    test    eax, eax
    jnz     .Lts_common
    cmp     dword ptr [rip+tm_noundo], 0
    jne     82f
    call    undo_drop_last
82: mov     dword ptr [rip+tm_noundo], 0
    lea     rdi, [rip+s_none]
    call    log_line
    jmp     .Lts_out
0:  # snapshot the selection, pivot = median of the locations
    xorps   xmm0, xmm0
    movss   [rip+tm_pivot], xmm0
    movss   [rip+tm_pivot+4], xmm0
    movss   [rip+tm_pivot+8], xmm0
    mov     dword ptr [rip+tm_n], 0
    xor     ebx, ebx
1:  cmp     ebx, [rip+obj_count]
    jae     2f
    mov     edi, ebx
    call    obj_at
    test    dword ptr [rax+OB_FLAGS], OBF_SELECTED
    jz      11f
    push    rax                         # (a selected parent moves it: not twice)
    push    rax
    mov     rdi, rax
    call    par_selected_ancestor
    test    eax, eax
    pop     rax
    pop     rax
    jnz     11f
    mov     ecx, [rip+tm_n]
    imul    rdi, rcx, TS_SZ
    lea     rdx, [rip+tm_snap]
    add     rdi, rdx
    lea     rdx, [rip+obj_list]
    mov     edx, [rdx+rbx*4]
    mov     [rdi+TS_H], edx
    lea     rsi, [rax+OB_LOC]
    add     rdi, TS_XF
    mov     ecx, 36
    rep     movsb
    movss   xmm0, [rax+OB_LOC]
    addss   xmm0, [rip+tm_pivot]
    movss   [rip+tm_pivot], xmm0
    movss   xmm0, [rax+OB_LOC+4]
    addss   xmm0, [rip+tm_pivot+4]
    movss   [rip+tm_pivot+4], xmm0
    movss   xmm0, [rax+OB_LOC+8]
    addss   xmm0, [rip+tm_pivot+8]
    movss   [rip+tm_pivot+8], xmm0
    inc     dword ptr [rip+tm_n]
11: inc     ebx
    jmp     1b
2:  mov     eax, [rip+tm_n]
    test    eax, eax
    jnz     3f
    lea     rdi, [rip+s_none]
    call    log_line
    jmp     .Lts_out
3:  cvtsi2ss xmm1, eax
    xor     ecx, ecx
4:  lea     rdx, [rip+tm_pivot]
    movss   xmm0, [rdx+rcx*4]
    divss   xmm0, xmm1
    movss   [rdx+rcx*4], xmm0
    inc     ecx
    cmp     ecx, 3
    jb      4b
    lea     rcx, [rip+mode_names]       # one undo step for the whole transform
    mov     rdi, [rcx+r12*8]
    call    undo_push
.Lts_common:
    mov     edi, [rip+vp_area]
    mov     [rip+tm_area], edi
    call    vp_prepare
    lea     rdi, [rip+tm_pivot]         # the pivot and the axes chosen (orient.s)
    call    pivot_fix
    call    orient_setup
    lea     rdi, [rip+tm_pivot]
    call    proj_world
    movss   [rip+tm_cx], xmm0
    movss   [rip+tm_cy], xmm1
    movss   [rip+tm_depth], xmm2
    mov     edi, [rip+ptr_x]
    mov     esi, [rip+ptr_y]
    call    pointer_px
    movss   xmm0, [rip+tm_mx]
    movss   [rip+tm_sx], xmm0
    movss   xmm0, [rip+tm_my]
    movss   [rip+tm_sy], xmm0
    movss   xmm0, [rip+tm_sy]           # rotate: starting angle
    subss   xmm0, [rip+tm_cy]
    xorps   xmm1, xmm1
    subss   xmm1, xmm0
    movss   xmm0, xmm1
    movss   xmm1, [rip+tm_sx]
    subss   xmm1, [rip+tm_cx]
    call    atan2_
    movss   [rip+tm_prev], xmm0
    xorps   xmm0, xmm0
    movss   [rip+tm_accum], xmm0
    mov     [rip+tm_mode], r12d
    mov     [rip+tm_axis], r13d
    mov     [rip+tm_drag], r14d
    mov     dword ptr [rip+tm_numlen], 0
    call    tm_update
.Lts_out:
    add     rsp, 8
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# tm_start_value(rdi=apply, rsi=cancel, rdx=confirm, rcx=label) - a modal
#   value (inset thickness, extrude distance...) for the edit selection: the
#   pointer's distance change to the selection centre, typed digits, Ctrl
#   snaps to 0.1. apply(xmm0) rebuilds from the caller's source each update.
#   The caller's operator already recorded the undo step.
tm_start_value:
    push    rbx
    sub     rsp, 16
    cmp     dword ptr [rip+tm_mode], 0
    jne     9f
    mov     [rip+tm_vfn], rdi
    mov     [rip+tm_vcancel], rsi
    mov     [rip+tm_vconfirm], rdx
    mov     [rip+mode_names+32], rcx
    mov     edi, [rip+vp_area]
    test    edi, edi
    js      9f
    lea     rdi, [rip+tm_pivot]
    call    edit_median
    mov     edi, [rip+vp_area]
    mov     [rip+tm_area], edi
    call    vp_prepare
    lea     rdi, [rip+tm_pivot]
    call    proj_world
    movss   [rip+tm_cx], xmm0
    movss   [rip+tm_cy], xmm1
    movss   [rip+tm_depth], xmm2
    mov     edi, [rip+ptr_x]
    mov     esi, [rip+ptr_y]
    call    pointer_px
    movss   xmm0, [rip+tm_mx]
    movss   [rip+tm_sx], xmm0
    movss   xmm0, [rip+tm_my]
    movss   [rip+tm_sy], xmm0
    mov     dword ptr [rip+tm_mode], 4
    mov     dword ptr [rip+tm_axis], 0
    mov     dword ptr [rip+tm_drag], 0
    mov     dword ptr [rip+tm_numlen], 0
    mov     dword ptr [rip+tm_noundo], 0
    call    tm_update
9:  add     rsp, 16
    pop     rbx
    ret

# tm_wheel(edi=+1 / -1) - value mode: change the integer (segments, cuts)
tm_wheel:
    cmp     dword ptr [rip+tm_mode], 4
    jne     9f
    cmp     dword ptr [rip+tm_vint], 0
    je      9f
    mov     eax, [rip+tm_vint]
    sub     eax, edi                    # wheel up (negative) adds
    cmp     eax, 1
    jge     1f
    mov     eax, 1
1:  cmp     eax, 64
    jle     2f
    mov     eax, 64
2:  mov     [rip+tm_vint], eax
    jmp     tm_update
9:  ret

# tm_motion(edi=x, esi=y logical)
tm_motion:
    call    pointer_px
    jmp     tm_update

# restore - put every snapshotted transform back
restore:
    cmp     dword ptr [rip+tm_mode], 4  # value mode rebuilds from its source
    jne     0f
    ret
0:  call    tm_comp
    test    eax, eax
    jne     edit_tm_restore
    push    rbx
    xor     ebx, ebx
1:  cmp     ebx, [rip+tm_n]
    jae     9f
    imul    rcx, rbx, TS_SZ
    lea     rax, [rip+tm_snap]
    add     rcx, rax
    push    rcx
    mov     edi, [rcx+TS_H]
    call    obj_get
    pop     rsi
    test    rax, rax
    jz      2f
    add     rsi, TS_XF
    lea     rdi, [rax+OB_LOC]
    mov     ecx, 36
    rep     movsb
2:  inc     ebx
    jmp     1b
9:  pop     rbx
    ret

# parse_num(rsi=text, ecx=len) -> xmm0 (sign, digits, one decimal point)
parse_num:
    xorps   xmm0, xmm0                  # value
    movss   xmm2, [rip+tf_one]          # fraction scale
    xor     edx, edx                    # seen '.'
    xor     r8d, r8d                    # negative
    xor     eax, eax
1:  cmp     eax, ecx
    jae     8f
    movzx   r9d, byte ptr [rsi+rax]
    inc     eax
    cmp     r9d, '-'
    jne     2f
    xor     r8d, 1
    jmp     1b
2:  cmp     r9d, '.'
    jne     3f
    mov     edx, 1
    jmp     1b
3:  sub     r9d, '0'
    cmp     r9d, 9
    ja      1b
    cvtsi2ss xmm1, r9d
    test    edx, edx
    jnz     4f
    mulss   xmm0, [rip+tf_ten]
    addss   xmm0, xmm1
    jmp     1b
4:  divss   xmm2, [rip+tf_ten]
    mulss   xmm1, xmm2
    addss   xmm0, xmm1
    jmp     1b
8:  test    r8d, r8d
    jz      9f
    xorps   xmm1, xmm1
    subss   xmm1, xmm0
    movss   xmm0, xmm1
9:  ret

# -----------------------------------------------------------------------------
# tm_update - recompute the transform from the snapshot
# -----------------------------------------------------------------------------
tm_update:
    push    rbx
    push    r12
    push    r13
    sub     rsp, 48
    mov     dword ptr [rip+dirty], 1
    mov     edi, [rip+tm_area]
    call    vp_prepare
    call    restore
    mov     eax, [rip+tm_mode]
    cmp     eax, 1
    je      .Ltu_grab
    cmp     eax, 2
    je      .Ltu_rotate
    cmp     eax, 3
    je      .Ltu_scale
    cmp     eax, 4
    je      .Ltu_value
    jmp     .Ltu_out

# ---- value mode: |pointer distance change| in world units at the pivot ---------------
.Ltu_value:
    cmp     dword ptr [rip+tm_numlen], 0
    je      1f
    lea     rsi, [rip+tm_num]
    mov     ecx, [rip+tm_numlen]
    call    parse_num
    jmp     3f
1:  movss   xmm0, [rip+tm_mx]
    subss   xmm0, [rip+tm_cx]
    mulss   xmm0, xmm0
    movss   xmm1, [rip+tm_my]
    subss   xmm1, [rip+tm_cy]
    mulss   xmm1, xmm1
    addss   xmm0, xmm1
    sqrtss  xmm0, xmm0
    movss   xmm2, [rip+tm_sx]
    subss   xmm2, [rip+tm_cx]
    mulss   xmm2, xmm2
    movss   xmm1, [rip+tm_sy]
    subss   xmm1, [rip+tm_cy]
    mulss   xmm1, xmm1
    addss   xmm2, xmm1
    sqrtss  xmm2, xmm2
    subss   xmm0, xmm2
    andps   xmm0, [rip+tf_absm]
    mulss   xmm0, [rip+tm_depth]
    divss   xmm0, [rip+vp_focal]
    call    tm_snapping                 # (Ctrl inverts the Snap toggle)
    test    eax, eax
    jz      3f
    movss   xmm1, [rip+tf_one]
    divss   xmm1, [rip+tf_ten]
    call    round_to
3:  movss   [rip+tm_value], xmm0
    call    [rip+tm_vfn]
    jmp     .Ltu_text

# ---- grab: delta vector in [rsp] ----------------------------------------------------
.Ltu_grab:
    mov     eax, [rip+tm_axis]
    cmp     dword ptr [rip+tm_numlen], 0
    je      1f
    lea     rsi, [rip+tm_num]           # typed: along the axis (X when free)
    mov     ecx, [rip+tm_numlen]
    call    parse_num
    mov     eax, [rip+tm_axis]
    test    eax, eax
    jnz     11f
    inc     eax
11: jmp     .Ltg_axis_amount
1:  test    eax, eax
    jz      .Ltg_free
    # constrained: project the pointer motion onto the axis' screen direction
    lea     rcx, [rip+tm_basis]         # (the orientation's axes)
    lea     rdx, [rax+rax*2-3]
    lea     rcx, [rcx+rdx*4]
    movss   xmm0, [rip+tm_pivot]        # pivot + axis
    addss   xmm0, [rcx]
    movss   [rsp+32], xmm0
    movss   xmm0, [rip+tm_pivot+4]
    addss   xmm0, [rcx+4]
    movss   [rsp+36], xmm0
    movss   xmm0, [rip+tm_pivot+8]
    addss   xmm0, [rcx+8]
    movss   [rsp+40], xmm0
    lea     rdi, [rsp+32]
    call    proj_world
    subss   xmm0, [rip+tm_cx]           # d = screen px per world unit
    subss   xmm1, [rip+tm_cy]
    movss   xmm2, [rip+tm_mx]
    subss   xmm2, [rip+tm_sx]
    movss   xmm3, [rip+tm_my]
    subss   xmm3, [rip+tm_sy]
    mulss   xmm2, xmm0                  # amount = (m . d) / (d . d)
    mulss   xmm3, xmm1
    addss   xmm2, xmm3
    mulss   xmm0, xmm0
    mulss   xmm1, xmm1
    addss   xmm0, xmm1
    maxss   xmm0, [rip+f_near]
    divss   xmm2, xmm0
    movss   xmm0, xmm2
    cmp     dword ptr [rip+key_mods], 0
    call    tm_snapping                 # (Ctrl inverts the Snap toggle)
    test    eax, eax
    jz      2f
    movss   xmm1, [rip+tf_one]
    call    round_to
2:  mov     eax, [rip+tm_axis]
.Ltg_axis_amount:                       # xmm0 = amount, eax = axis
    xorps   xmm1, xmm1
    movss   [rsp], xmm1
    movss   [rsp+4], xmm1
    movss   [rsp+8], xmm1
    lea     rdx, [rip+tm_custom]
    cmp     eax, 4
    je      1f
    lea     rdx, [rip+tm_basis]         # X / Y / Z of the orientation
    lea     rax, [rax+rax*2-3]
    lea     rdx, [rdx+rax*4]
1:  xor     ecx, ecx                    # along that direction
2:
    movss   xmm1, [rdx+rcx*4]
    mulss   xmm1, xmm0
    movss   [rsp+rcx*4], xmm1
    inc     ecx
    cmp     ecx, 3
    jb      2b
    jmp     .Ltg_apply
.Ltg_free:                              # in the view plane at pivot depth
    movss   xmm4, [rip+tm_depth]
    divss   xmm4, [rip+vp_focal]        # world per physical pixel
    movss   xmm5, [rip+tm_mx]
    subss   xmm5, [rip+tm_sx]
    mulss   xmm5, xmm4                  # right amount
    movss   xmm6, [rip+tm_my]
    subss   xmm6, [rip+tm_sy]
    mulss   xmm6, xmm4                  # down amount
    xor     ecx, ecx
3:  lea     rax, [rip+right]
    movss   xmm0, [rax+rcx*4]
    mulss   xmm0, xmm5
    lea     rax, [rip+up]
    movss   xmm1, [rax+rcx*4]
    mulss   xmm1, xmm6
    subss   xmm0, xmm1
    call    tm_snapping                 # (Ctrl inverts the Snap toggle)
    test    eax, eax
    jz      31f
    push    rcx
    movss   xmm1, [rip+tf_one]
    call    round_to
    pop     rcx
31: movss   [rsp+rcx*4], xmm0
    inc     ecx
    cmp     ecx, 3
    jb      3b
.Ltg_apply:
    lea     rsi, [rsp]
    lea     rdi, [rip+tm_value]
    mov     rax, [rsi]
    mov     [rdi], rax
    mov     eax, [rsi+8]
    mov     [rdi+8], eax
    call    tm_comp
    test    eax, eax
    je      0f
    lea     rdi, [rsp]
    call    edit_tm_grab
    jmp     .Ltu_text
0:  xor     ebx, ebx
4:  cmp     ebx, [rip+tm_n]
    jae     .Ltu_text
    imul    rcx, rbx, TS_SZ
    lea     rax, [rip+tm_snap]
    mov     edi, [rax+rcx+TS_H]
    call    obj_get
    test    rax, rax
    jz      41f
    xor     ecx, ecx
5:  movss   xmm0, [rax+OB_LOC+rcx*4]
    addss   xmm0, [rsp+rcx*4]
    movss   [rax+OB_LOC+rcx*4], xmm0
    inc     ecx
    cmp     ecx, 3
    jb      5b
41: inc     ebx
    jmp     4b

# ---- rotate around the axis (Y when free) -------------------------------------------
.Ltu_rotate:
    mov     r12d, [rip+tm_axis]
    test    r12d, r12d
    jnz     1f
    mov     r12d, 2
1:  cmp     dword ptr [rip+tm_numlen], 0
    je      2f
    lea     rsi, [rip+tm_num]
    mov     ecx, [rip+tm_numlen]
    call    parse_num
    mulss   xmm0, [rip+tf_deg2rad]
    jmp     .Ltr_have
2:  movss   xmm0, [rip+tm_my]           # pointer angle around the pivot
    subss   xmm0, [rip+tm_cy]
    xorps   xmm1, xmm1
    subss   xmm1, xmm0
    movss   xmm0, xmm1
    movss   xmm1, [rip+tm_mx]
    subss   xmm1, [rip+tm_cx]
    call    atan2_
    movss   xmm1, xmm0                  # delta wrapped into (-pi, pi]
    subss   xmm1, [rip+tm_prev]
    movss   [rip+tm_prev], xmm0
    comiss  xmm1, [rip+tf_pi]
    jbe     21f
    subss   xmm1, [rip+tf_2pi]
21: xorps   xmm2, xmm2
    subss   xmm2, [rip+tf_pi]
    comiss  xmm1, xmm2
    jae     22f
    addss   xmm1, [rip+tf_2pi]
22: addss   xmm1, [rip+tm_accum]
    movss   [rip+tm_accum], xmm1
    movss   xmm0, xmm1
    lea     rcx, [rip+tm_basis]         # facing away from the viewer: flip
    lea     rdx, [r12+r12*2-3]
    lea     rcx, [rcx+rdx*4]
    movss   xmm1, [rcx]
    mulss   xmm1, [rip+fwd]
    movss   xmm2, [rcx+4]
    mulss   xmm2, [rip+fwd+4]
    addss   xmm1, xmm2
    movss   xmm2, [rcx+8]
    mulss   xmm2, [rip+fwd+8]
    addss   xmm1, xmm2
    xorps   xmm2, xmm2
    comiss  xmm1, xmm2
    jbe     23f
    xorps   xmm1, xmm1
    subss   xmm1, xmm0
    movss   xmm0, xmm1
23: call    tm_snapping                 # (Ctrl inverts the Snap toggle)
    test    eax, eax
    jz      .Ltr_have
    movss   xmm1, [rip+tf_step]
    call    round_to
.Ltr_have:                              # xmm0 = angle (radians), r12d = axis
    movss   [rip+tm_value], xmm0
    movss   [rsp+16], xmm0
    call    sincos                      # xmm0 = sin, xmm1 = cos
    movss   [rsp+20], xmm0
    movss   [rsp+24], xmm1
    # the two other components rotate: (a, b) = (Y,Z) for X, (Z,X) for Y, (X,Y) for Z
    mov     eax, r12d
    mov     r13d, eax                   # a index
    cmp     eax, 3
    jb      3f
    xor     r13d, r13d
3:  lea     eax, [r13+1]                # b index
    cmp     eax, 3
    jb      31f
    xor     eax, eax
31: mov     [rsp+28], eax
    call    tm_comp
    test    eax, eax
    je      0f
    mov     edi, r12d
    movss   xmm0, [rsp+20]
    movss   xmm1, [rsp+24]
    lea     rsi, [rip+tm_pivot]
    call    edit_tm_rotate
    jmp     .Ltu_text
0:  cmp     dword ptr [rip+tm_orient], 0  # another orientation: about
    jne     .Ltr_axis                   #  that axis (orient.s)
    xor     ebx, ebx
4:  cmp     ebx, [rip+tm_n]
    jae     .Ltu_text
    imul    rcx, rbx, TS_SZ
    lea     rax, [rip+tm_snap]
    mov     edi, [rax+rcx+TS_H]
    call    obj_get
    test    rax, rax
    jz      41f
    movss   xmm0, [rax+OB_ROT+r12*4-4]  # Euler component += angle
    addss   xmm0, [rsp+16]
    movss   [rax+OB_ROT+r12*4-4], xmm0
    cmp     dword ptr [rip+tm_pvmode], 2  # (individual origins: they stay)
    je      41f
    mov     ecx, [rsp+28]               # orbit the location around the pivot
    lea     rdx, [rip+tm_pivot]
    movss   xmm2, [rax+OB_LOC+r13*4]
    subss   xmm2, [rdx+r13*4]           # da
    movss   xmm3, [rax+OB_LOC+rcx*4]
    subss   xmm3, [rdx+rcx*4]           # db
    movss   xmm4, xmm2                  # a' = da cos - db sin
    mulss   xmm4, [rsp+24]
    movss   xmm5, xmm3
    mulss   xmm5, [rsp+20]
    subss   xmm4, xmm5
    addss   xmm4, [rdx+r13*4]
    movss   [rax+OB_LOC+r13*4], xmm4
    mulss   xmm2, [rsp+20]              # b' = da sin + db cos
    mulss   xmm3, [rsp+24]
    addss   xmm2, xmm3
    addss   xmm2, [rdx+rcx*4]
    movss   [rax+OB_LOC+rcx*4], xmm2
41: inc     ebx
    jmp     4b

# rotate objects about the orientation's axis (r12d = 1..3, [rsp+16] = the
#   angle): R = Ra * R0, the location orbits the pivot (not with Individual
#   Origins). Uses [rsp+32 ..] of tm_update's frame for Ra.
.Ltr_axis:
    lea     rdi, [rip+tm_basis]
    lea     eax, [r12+r12*2-3]
    lea     rdi, [rdi+rax*4]
    movss   xmm0, [rsp+16]
    lea     rsi, [rip+tr_ra]
    call    o_axis_mat
    xor     ebx, ebx
1:  cmp     ebx, [rip+tm_n]
    jae     .Ltu_text
    imul    rcx, rbx, TS_SZ
    lea     rax, [rip+tm_snap]
    mov     edi, [rax+rcx+TS_H]
    call    obj_get
    test    rax, rax
    jz      3f
    mov     r13, rax
    lea     rdi, [r13+OB_ROT]           # the turn
    lea     rsi, [rip+tr_r0]
    call    o_euler_mat
    lea     rdi, [rip+tr_ra]
    lea     rsi, [rip+tr_r0]
    lea     rdx, [rip+tr_r0]
    call    o_mul
    lea     rdi, [rip+tr_r0]
    lea     rsi, [r13+OB_ROT]
    call    o_mat_euler
    cmp     dword ptr [rip+tm_pvmode], 2
    je      3f
    xor     ecx, ecx                    # the orbit: pivot + Ra (loc - pivot)
2:  lea     rdx, [rip+tm_pivot]
    movss   xmm0, [r13+OB_LOC+rcx*4]
    subss   xmm0, [rdx+rcx*4]
    lea     rdx, [rip+tr_v]
    movss   [rdx+rcx*4], xmm0
    inc     ecx
    cmp     ecx, 3
    jb      2b
    lea     rdi, [rip+tr_ra]
    lea     rsi, [rip+tr_v]
    lea     rdx, [rip+tr_v]
    call    o_mulv
    xor     ecx, ecx
21: lea     rdx, [rip+tr_v]
    movss   xmm0, [rdx+rcx*4]
    lea     rdx, [rip+tm_pivot]
    addss   xmm0, [rdx+rcx*4]
    movss   [r13+OB_LOC+rcx*4], xmm0
    inc     ecx
    cmp     ecx, 3
    jb      21b
3:  inc     ebx
    jmp     1b

# ---- scale relative to the pivot ------------------------------------------------------
.Ltu_scale:
    cmp     dword ptr [rip+tm_numlen], 0
    je      1f
    lea     rsi, [rip+tm_num]
    mov     ecx, [rip+tm_numlen]
    call    parse_num
    jmp     .Lsc_have
1:  movss   xmm0, [rip+tm_mx]           # |m - c| / |s - c|
    subss   xmm0, [rip+tm_cx]
    mulss   xmm0, xmm0
    movss   xmm1, [rip+tm_my]
    subss   xmm1, [rip+tm_cy]
    mulss   xmm1, xmm1
    addss   xmm0, xmm1
    sqrtss  xmm0, xmm0
    movss   xmm2, [rip+tm_sx]
    subss   xmm2, [rip+tm_cx]
    mulss   xmm2, xmm2
    movss   xmm1, [rip+tm_sy]
    subss   xmm1, [rip+tm_cy]
    mulss   xmm1, xmm1
    addss   xmm2, xmm1
    sqrtss  xmm2, xmm2
    maxss   xmm2, [rip+tf_one]
    divss   xmm0, xmm2
    call    tm_snapping                 # (Ctrl inverts the Snap toggle)
    test    eax, eax
    jz      .Lsc_have
    movss   xmm1, [rip+tf_one]
    divss   xmm1, [rip+tf_ten]
    call    round_to
.Lsc_have:
    movss   [rip+tm_value], xmm0
    movss   [rsp+16], xmm0
    call    tm_comp
    test    eax, eax
    je      0f
    mov     edi, [rip+tm_axis]
    lea     rsi, [rip+tm_pivot]
    call    edit_tm_scale
    jmp     .Ltu_text
0:
    xor     ebx, ebx
2:  cmp     ebx, [rip+tm_n]
    jae     .Ltu_text
    imul    rcx, rbx, TS_SZ
    lea     rax, [rip+tm_snap]
    mov     edi, [rax+rcx+TS_H]
    call    obj_get
    test    rax, rax
    jz      5f
    xor     ecx, ecx
3:  mov     edx, [rip+tm_axis]          # constrained: only that component
    test    edx, edx
    jz      4f
    dec     edx
    cmp     edx, ecx
    jne     41f
4:  movss   xmm0, [rax+OB_SCALE+rcx*4]
    mulss   xmm0, [rsp+16]
    movss   [rax+OB_SCALE+rcx*4], xmm0
    cmp     dword ptr [rip+tm_pvmode], 2  # (individual origins: they stay)
    je      41f
    lea     rdx, [rip+tm_pivot]
    movss   xmm0, [rax+OB_LOC+rcx*4]
    subss   xmm0, [rdx+rcx*4]
    mulss   xmm0, [rsp+16]
    addss   xmm0, [rdx+rcx*4]
    movss   [rax+OB_LOC+rcx*4], xmm0
41: inc     ecx
    cmp     ecx, 3
    jb      3b
5:  inc     ebx
    jmp     2b

# ---- status text ----------------------------------------------------------------------
.Ltu_text:
    call    fmt_reset
    mov     eax, [rip+tm_mode]
    lea     rcx, [rip+mode_names]
    mov     rdi, [rcx+rax*8]
    call    fmt_str
    mov     eax, [rip+tm_axis]
    test    eax, eax
    jz      1f
    mov     edi, ' '
    call    fmt_char
    mov     eax, [rip+tm_axis]
    lea     rcx, [rip+s_ax]
    movzx   edi, byte ptr [rcx+rax+1]
    call    fmt_char
1:  lea     rdi, [rip+s_sep]
    call    fmt_str
    cmp     dword ptr [rip+tm_numlen], 0
    je      2f
    lea     rsi, [rip+tm_num]           # typed text with a cursor
    mov     ecx, [rip+tm_numlen]
    xor     ebx, ebx
11: cmp     ebx, ecx
    jae     12f
    movzx   edi, byte ptr [rsi+rbx]
    push    rcx
    push    rsi
    call    fmt_char
    pop     rsi
    pop     rcx
    inc     ebx
    jmp     11b
12: lea     rdi, [rip+s_cursor]
    call    fmt_str
    jmp     .Ltt_done
2:  cmp     dword ptr [rip+tm_mode], 1
    jne     3f
    movss   xmm0, [rip+tm_value]
    call    fmt_fix1
    lea     rdi, [rip+s_comma]
    call    fmt_str
    movss   xmm0, [rip+tm_value+4]
    call    fmt_fix1
    lea     rdi, [rip+s_comma]
    call    fmt_str
    movss   xmm0, [rip+tm_value+8]
    call    fmt_fix1
    jmp     .Ltt_done
3:  cmp     dword ptr [rip+tm_mode], 2
    jne     4f
    movss   xmm0, [rip+tm_value]
    mulss   xmm0, [rip+tf_rad2deg]
    call    fmt_fix1
    lea     rdi, [rip+s_deg]
    call    fmt_str
    jmp     .Ltt_done
4:  movss   xmm0, [rip+tm_value]        # scale: two decimals
    mulss   xmm0, [rip+tf_ten]
    call    fmt_fix1
    mov     eax, [rip+fmt_pos]          # "12.5" -> "1.25"
    lea     rcx, [rip+fmt_buf]
    cmp     eax, 3
    jb      .Ltt_done
    mov     dl, [rcx+rax-3]
    mov     [rcx+rax-2], dl
    mov     byte ptr [rcx+rax-3], '.'
.Ltt_done:
    cmp     dword ptr [rip+tm_mode], 4  # value mode: "   segments 3"
    jne     6f
    cmp     dword ptr [rip+tm_vint], 0
    je      6f
    lea     rdi, [rip+s_times]
    call    fmt_str
    mov     edi, [rip+tm_vint]
    call    fmt_int
6:  lea     rsi, [rip+fmt_buf]          # keep a copy for the overlay

    lea     rdi, [rip+tm_text]
    mov     ecx, 95
5:  mov     al, [rsi]
    mov     [rdi], al
    test    al, al
    jz      .Ltu_out
    inc     rsi
    inc     rdi
    dec     ecx
    jnz     5b
    mov     byte ptr [rdi], 0
.Ltu_out:
    add     rsp, 48
    pop     r13
    pop     r12
    pop     rbx
    ret

# -----------------------------------------------------------------------------
# tm_key(edi=evdev) - keys while a transform runs (all are consumed)
# -----------------------------------------------------------------------------
tm_key:
    push    rbx
    mov     ebx, edi
    cmp     ebx, KEY_ESC
    jne     1f
    call    tm_cancel
    jmp     9f
1:  cmp     ebx, KEY_ENTER
    je      11f
    cmp     ebx, 96
    jne     2f
11: call    tm_confirm
    jmp     9f
2:  cmp     ebx, 14                     # Backspace
    jne     3f
    cmp     dword ptr [rip+tm_numlen], 0
    je      8f
    dec     dword ptr [rip+tm_numlen]
    jmp     8f
3:  mov     edi, ebx                    # X / Y / Z by the key label
    call    kb_layout_code
    mov     ecx, 1
    cmp     eax, KEY_X
    je      31f
    mov     ecx, 2
    cmp     eax, 21                     # Y
    je      31f
    mov     ecx, 3
    cmp     eax, KEY_Z
    jne     4f
31: xor     eax, eax                    # same axis again: free
    cmp     ecx, [rip+tm_axis]
    cmove   ecx, eax
    mov     [rip+tm_axis], ecx
    jmp     8f
4:  # numbers: physical digit row, keypad, or the typed character
    mov     eax, ebx
    cmp     eax, 2
    jb      41f
    cmp     eax, 11
    ja      41f
    add     eax, '1'-2
    cmp     eax, '9'+1
    jne     5f
    mov     eax, '0'
    jmp     5f
41: lea     rcx, [rip+kp_chars]
    cmp     ebx, 71
    jb      42f
    cmp     ebx, 83
    ja      42f
    movzx   eax, byte ptr [rcx+rbx-71]
    test    eax, eax
    jnz     5f
42: mov     edi, ebx
    call    kb_sym
    cmp     eax, ','
    jne     43f
    mov     eax, '.'
43: cmp     eax, '-'
    je      5f
    cmp     eax, '.'
    je      5f
    cmp     eax, '0'
    jb      8f
    cmp     eax, '9'
    ja      8f
5:  mov     ecx, [rip+tm_numlen]
    cmp     ecx, 15
    jae     8f
    lea     rdx, [rip+tm_num]
    mov     [rdx+rcx], al
    inc     dword ptr [rip+tm_numlen]
8:  call    tm_update
9:  mov     eax, 1
    pop     rbx
    ret

.section .rodata
#           71   72   73   74   75   76   77   78   79   80   81   82   83
kp_chars: .byte '7', '8', '9', '-', '4', '5', '6', 0, '1', '2', '3', '0', '.'
.text

tm_confirm:
    cmp     dword ptr [rip+tm_mode], 0
    je      9f
    call    tm_update
    call    lastop_confirm              # the redo panel's values
    cmp     dword ptr [rip+tm_mode], 4
    jne     0f
    call    [rip+tm_vconfirm]
    jmp     2f
0:  call    tm_comp
    test    eax, eax
    je      1f
    call    edit_tm_end                 # bounding box after a component edit
    jmp     2f
1:  mov     edi, [rip+tm_mode]
    call    macro_transform
    call    autokey_confirm             # (auto-key: the objects get keys)
2:  mov     dword ptr [rip+tm_noundo], 0
    mov     dword ptr [rip+tm_mode], 0
    mov     dword ptr [rip+tm_drag], 0
    lea     rdi, [rip+tm_text]          # drop the input cursor from the log
    call    str_len
    lea     rcx, [rip+tm_text]
    test    eax, eax
    jz      1f
    cmp     byte ptr [rcx+rax-1], '|'
    jne     1f
    mov     byte ptr [rcx+rax-1], 0
1:  lea     rdi, [rip+s_sep]
    lea     rsi, [rip+tm_text]
    call    log_pair
    mov     dword ptr [rip+dirty], 1
9:  ret

tm_cancel:
    cmp     dword ptr [rip+tm_mode], 0
    je      9f
    call    lastop_cancel
    cmp     dword ptr [rip+tm_mode], 4
    jne     1f
    call    [rip+tm_vcancel]
    jmp     2f
1:  call    restore
2:  cmp     dword ptr [rip+tm_noundo], 0
    jne     3f
    call    undo_drop_last
3:  mov     dword ptr [rip+tm_noundo], 0
    mov     dword ptr [rip+tm_mode], 0
    mov     dword ptr [rip+tm_drag], 0
    lea     rdi, [rip+s_cancelled]
    call    log_line
    mov     dword ptr [rip+dirty], 1
9:  ret

# -----------------------------------------------------------------------------
# tm_draw - inside the viewport being drawn: constraint line + status text
# -----------------------------------------------------------------------------
tm_draw:
    cmp     dword ptr [rip+tm_mode], 0
    je      9f
    mov     eax, [rip+ed_node]
    cmp     eax, [rip+tm_area]
    jne     9f
    push    rbx
    mov     eax, [rip+tm_axis]
    test    eax, eax
    jz      2f
    lea     rcx, [rip+axis_vec]         # long line through the pivot
    lea     rdx, [rax+rax*2-3]
    lea     rcx, [rcx+rdx*4]
    xor     edx, edx
1:  movss   xmm0, [rcx+rdx*4]
    mulss   xmm0, [rip+tf_far]
    lea     rax, [rip+tm_pivot]
    movss   xmm1, [rax+rdx*4]
    movss   xmm2, xmm1
    subss   xmm1, xmm0
    addss   xmm2, xmm0
    lea     rax, [rip+lp0]
    movss   [rax+rdx*4], xmm1
    lea     rax, [rip+lp1]
    movss   [rax+rdx*4], xmm2
    inc     edx
    cmp     edx, 3
    jb      1b
    mov     eax, [rip+tm_axis]
    lea     rcx, [rip+axis_col]
    mov     edx, [rcx+rax*4-4]
    call    line3d
2:  mov     edi, [rip+cvs_x0]           # "Move X  1.5|   hints"
    add     edi, 10
    mov     esi, [rip+cvs_y0]
    add     esi, 46
    lea     rdx, [rip+tm_text]
    mov     ecx, COL_ACTIVE
    call    draw_text
    mov     edi, eax
    mov     esi, [rip+cvs_y0]
    add     esi, 46
    lea     rdx, [rip+s_hint]
    mov     ecx, COL_TEXT_DIM
    call    draw_text
    pop     rbx
9:  ret

# -----------------------------------------------------------------------------
# Gizmos (Move / Rotate / Scale tools) at the selection's median point
# -----------------------------------------------------------------------------
# gizmo_origin -> eax = 1 and g_tmp[0..2] = origin, xmm0 = handle length
# (world units) when the active tool has a gizmo and something is selected
gizmo_origin:
    push    rbx
    push    r12
    sub     rsp, 8
    xor     eax, eax
    mov     ecx, [rip+active_tool]
    test    ecx, ecx
    jz      9f
    call    tm_comp
    test    eax, eax # edit mode: the selected vertices
    je      0f
    lea     rdi, [rip+g_tmp+16]
    call    edit_median
    test    eax, eax
    jz      9f
    jmp     .Lgo_len
0:
    xorps   xmm0, xmm0
    movss   [rsp], xmm0                 # count
    lea     rdx, [rip+g_tmp+16]
    movss   [rdx], xmm0
    movss   [rdx+4], xmm0
    movss   [rdx+8], xmm0
    xor     r12d, r12d
    xor     ebx, ebx
1:  cmp     ebx, [rip+obj_count]
    jae     2f
    mov     edi, ebx
    call    obj_at
    test    dword ptr [rax+OB_FLAGS], OBF_SELECTED
    jz      11f
    inc     r12d
    lea     rdx, [rip+g_tmp+16]
    xor     ecx, ecx
12: movss   xmm0, [rdx+rcx*4]
    addss   xmm0, [rax+OB_LOC+rcx*4]
    movss   [rdx+rcx*4], xmm0
    inc     ecx
    cmp     ecx, 3
    jb      12b
11: inc     ebx
    jmp     1b
2:  xor     eax, eax
    test    r12d, r12d
    jz      9f
    cvtsi2ss xmm1, r12d
    lea     rdx, [rip+g_tmp+16]
    xor     ecx, ecx
3:  movss   xmm0, [rdx+rcx*4]
    divss   xmm0, xmm1
    movss   [rdx+rcx*4], xmm0
    inc     ecx
    cmp     ecx, 3
    jb      3b
.Lgo_len:
    lea     rdi, [rip+g_tmp+16]         # length = GIZMO_PX on screen
    call    proj_world
    mov     eax, GIZMO_PX
    cvtsi2ss xmm0, eax
    cvtsi2ss xmm1, dword ptr [rip+ui_s120]
    mulss   xmm0, xmm1
    mov     eax, 120
    cvtsi2ss xmm1, eax
    divss   xmm0, xmm1
    mulss   xmm0, xmm2                  # * depth / focal
    divss   xmm0, [rip+vp_focal]
    mov     eax, 1
9:  add     rsp, 8
    pop     r12
    pop     rbx
    ret

# gizmo_segment(ebx=axis 0..2, r12d=segment, xmm7=length) -> lp0 / lp1 (world)
#   move / scale: one segment origin -> origin + axis * length
#   rotate:       48 segments of a ring around the axis
gizmo_segment:
    lea     rdx, [rip+g_tmp+16]
    cmp     dword ptr [rip+active_tool], 2
    je      2f
    lea     rcx, [rip+axis_vec]
    lea     rax, [rbx+rbx*2]
    lea     rcx, [rcx+rax*4]
    xor     eax, eax
1:  movss   xmm0, [rdx+rax*4]
    lea     r8, [rip+lp0]
    movss   [r8+rax*4], xmm0
    movss   xmm1, [rcx+rax*4]
    mulss   xmm1, xmm7
    addss   xmm0, xmm1
    lea     r8, [rip+lp1]
    movss   [r8+rax*4], xmm0
    inc     eax
    cmp     eax, 3
    jb      1b
    ret
2:  push    rdx
    sub     rsp, 16
    movss   [rsp+8], xmm7
    mov     eax, r12d                   # angle a0, a1
    cvtsi2ss xmm0, eax
    mulss   xmm0, [rip+tf_2pi]
    mov     eax, 48
    cvtsi2ss xmm1, eax
    divss   xmm0, xmm1
    call    sincos
    movss   [rsp], xmm0
    movss   [rsp+4], xmm1
    lea     r8, [rip+lp0]
    call    ring_point
    lea     eax, [r12+1]
    cvtsi2ss xmm0, eax
    mulss   xmm0, [rip+tf_2pi]
    mov     eax, 48
    cvtsi2ss xmm1, eax
    divss   xmm0, xmm1
    call    sincos
    movss   [rsp], xmm0
    movss   [rsp+4], xmm1
    lea     r8, [rip+lp1]
    call    ring_point
    add     rsp, 16
    pop     rdx
    ret
# ring_point(r8=out, [rsp+8]=sin, [rsp+12]=cos, [rsp+16]=length) - point on
# the ring around axis ebx: the two other components get r*cos and r*sin
ring_point:
    lea     rdx, [rip+g_tmp+16]
    movss   xmm2, [rsp+16]
    mulss   xmm2, [rip+tf_ring]
    xor     eax, eax
1:  movss   xmm0, [rdx+rax*4]
    movss   [r8+rax*4], xmm0
    inc     eax
    cmp     eax, 3
    jb      1b
    lea     eax, [rbx+1]                # a = next axis, b = the one after
    cmp     eax, 3
    jb      2f
    xor     eax, eax
2:  lea     ecx, [rax+1]
    cmp     ecx, 3
    jb      3f
    xor     ecx, ecx
3:  movss   xmm0, [rsp+12]
    mulss   xmm0, xmm2
    addss   xmm0, [r8+rax*4]
    movss   [r8+rax*4], xmm0
    movss   xmm0, [rsp+8]
    mulss   xmm0, xmm2
    addss   xmm0, [r8+rcx*4]
    movss   [r8+rcx*4], xmm0
    ret

# gizmo_draw - in the viewport being drawn (camera already set up)
gizmo_draw:
    cmp     dword ptr [rip+tm_mode], 0
    jne     .Lgd_ret
    push    rbx
    push    r12
    push    r13
    sub     rsp, 16
    call    gizmo_origin
    test    eax, eax
    jz      .Lgd_out
    movss   [rsp], xmm0                 # length
    xor     ebx, ebx                    # axis
.Lgd_axis:
    lea     rcx, [rip+axis_col]
    mov     r13d, [rcx+rbx*4]
    lea     eax, [rbx+1]
    cmp     eax, [rip+gizmo_hover]
    jne     1f
    mov     r13d, COL_ACTIVE            # hovered handle in gold
1:  mov     r12d, 0
    mov     eax, 1
    cmp     dword ptr [rip+active_tool], 2
    jne     2f
    mov     eax, 48
2:  mov     [rsp+4], eax                # segment count
3:  movss   xmm7, [rsp]
    call    gizmo_segment
    mov     edx, r13d
    call    line3d
    inc     r12d
    cmp     r12d, [rsp+4]
    jb      3b
    cmp     dword ptr [rip+active_tool], 2
    je      5f
    lea     rdi, [rip+lp1]              # handle tip: arrow box / scale cube
    call    proj_world
    cvttss2si edi, xmm0
    cvttss2si esi, xmm1
    mov     eax, 3
    cmp     dword ptr [rip+active_tool], 3
    jne     4f
    mov     eax, 5
4:  sub     edi, eax
    sub     esi, eax
    lea     edx, [rax+rax+1]
    mov     ecx, edx
    mov     r8d, r13d
    call    fill_rect_px
5:  inc     ebx
    cmp     ebx, 3
    jb      .Lgd_axis
.Lgd_out:
    add     rsp, 16
    pop     r13
    pop     r12
    pop     rbx
.Lgd_ret:
    ret

# gizmo_pick(edi=x, esi=y logical) -> eax = axis 1..3 under the pointer, or 0.
# The caller has run vp_prepare for the viewport.
gizmo_pick:
    push    rbx
    push    r12
    push    r13
    sub     rsp, 48
    call    pointer_px                  # tm_mx / tm_my = pointer
    call    gizmo_origin
    test    eax, eax
    jz      .Lgp_none
    movss   [rsp], xmm0                 # length
    movss   xmm0, [rip+tf_big]
    movss   [rsp+4], xmm0               # best distance
    mov     dword ptr [rsp+8], 0        # best axis
    xor     ebx, ebx
.Lgp_axis:
    xor     r12d, r12d
    mov     r13d, 1
    cmp     dword ptr [rip+active_tool], 2
    jne     1f
    mov     r13d, 48
1:  movss   xmm7, [rsp]
    call    gizmo_segment
    lea     rdi, [rip+lp0]
    call    proj_world
    movss   [rsp+16], xmm0
    movss   [rsp+20], xmm1
    lea     rdi, [rip+lp1]
    call    proj_world
    movss   [rsp+24], xmm0
    movss   [rsp+28], xmm1
    # distance from the pointer to the segment
    movss   xmm2, [rsp+24]              # d = b - a
    subss   xmm2, [rsp+16]
    movss   xmm3, [rsp+28]
    subss   xmm3, [rsp+20]
    movss   xmm4, [rip+tm_mx]           # p - a
    subss   xmm4, [rsp+16]
    movss   xmm5, [rip+tm_my]
    subss   xmm5, [rsp+20]
    movss   xmm0, xmm4                  # t = clamp((p-a).d / d.d, 0, 1)
    mulss   xmm0, xmm2
    movss   xmm1, xmm5
    mulss   xmm1, xmm3
    addss   xmm0, xmm1
    movss   xmm1, xmm2
    mulss   xmm1, xmm2
    movss   xmm6, xmm3
    mulss   xmm6, xmm3
    addss   xmm1, xmm6
    maxss   xmm1, [rip+f_near]
    divss   xmm0, xmm1
    xorps   xmm1, xmm1
    maxss   xmm0, xmm1
    minss   xmm0, [rip+tf_one]
    mulss   xmm2, xmm0                  # p - (a + t d)
    mulss   xmm3, xmm0
    subss   xmm4, xmm2
    subss   xmm5, xmm3
    mulss   xmm4, xmm4
    mulss   xmm5, xmm5
    addss   xmm4, xmm5
    sqrtss  xmm4, xmm4
    comiss  xmm4, [rsp+4]
    jae     2f
    movss   [rsp+4], xmm4
    lea     eax, [rbx+1]
    mov     [rsp+8], eax
2:  inc     r12d
    cmp     r12d, r13d
    jb      1b
    inc     ebx
    cmp     ebx, 3
    jb      .Lgp_axis
    mov     eax, [rsp+8]                # close enough?
    mov     ecx, 8
    cvtsi2ss xmm0, ecx
    cvtsi2ss xmm1, dword ptr [rip+ui_s120]
    mulss   xmm0, xmm1
    mov     ecx, 120
    cvtsi2ss xmm1, ecx
    divss   xmm0, xmm1
    comiss  xmm0, [rsp+4]
    ja      9f
.Lgp_none:
    xor     eax, eax
9:  add     rsp, 48
    pop     r13
    pop     r12
    pop     rbx
    ret

.section .note.GNU-stack,"",@progbits
