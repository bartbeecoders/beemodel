# =============================================================================
#  BeeModel - 3D viewport: orbit camera, perspective projection, near-plane
#  and Liang-Barsky clipping, wireframe rendering. Scalar SSE math; sin/cos
#  come from the x87 FSINCOS instruction (no libm).
# =============================================================================
.intel_syntax noprefix
.include "const.inc"
.include "macros.inc"

# exports
.globl project
.globl lp1
.globl lp0
.globl line3d
.globl fwd
.globl eye
.globl world_verts
.globl vp_focal
.globl vp_cy
.globl vp_cx
.globl to_cam
.globl f_near
.globl vp_pick
.globl cam_setup
.globl cam_dist
.globl cam_pitch
.globl cam_tx
.globl cam_ty
.globl cam_tz
.globl cam_yaw
.globl f_rad2deg
.globl f_ten
.globl right
.globl up
.globl viewport_draw
.globl vp_orbit
.globl vp_pan
.globl vp_reset
.globl vp_zoom

.globl vp_near
.globl vp_focal_k
.globl vp_grid
.section .data
.align 4
cam_yaw:    .float 0.7853982
cam_pitch:  .float 0.5
cam_dist:   .float 18.0
cam_tx:     .float 0.0
cam_ty:     .float 0.0
cam_tz:     .float 0.0
vp_near:                                # clip start (preferences: everything
f_near:     .float 0.05                 #  that projects follows it)
vp_focal_k: .float 1.07                 # 0.5 / tan(fov / 2): 50deg vertical (preferences)
vp_grid:    .float 1.0                  # the ground grid's spacing (preferences)

.section .rodata
.align 4
f_zero:     .float 0.0
f_one:      .float 1.0
f_orbit_k:  .float 0.008
f_pitch_max:.float 1.55
f_pitch_min:.float -1.55
f_zoom_in:  .float 0.9090909
f_zoom_out: .float 1.1
f_dist_min: .float 1.5
f_dist_max: .float 20000.0
f_gizmo:    .float 34.0
f_axis_y:   .float 3.0
f_rad2deg:  .float 57.29578
f_ten:      .float 10.0
f_def_yaw:  .float 0.7853982
f_def_pitch:.float 0.5
f_def_dist: .float 18.0

.equ GRID_N, 10

s_vp_label: .asciz "Perspective  |  Grid 1 m"
s_ax_x:     .asciz "X"
s_ax_y:     .asciz "Y"
s_ax_z:     .asciz "Z"

.section .bss
.align 16
eye:        .skip 12
right:      .skip 12
up:         .skip 12
fwd:        .skip 12
vp_focal:   .skip 4
vp_cx:      .skip 4
vp_cy:      .skip 4
px_world:   .skip 4
sin_y:      .skip 4
cos_y:      .skip 4
sin_p:      .skip 4
cos_p:      .skip 4
lp0:        .skip 12                    # world-space line endpoints (input)
lp1:        .skip 12
la:         .skip 12                    # camera-space endpoints
lb:         .skip 12
lb_buf:     .skip 16                    # x0,y0,x1,y1 screen floats
tmpf:       .skip 4

.text

# -----------------------------------------------------------------------------
# cam_setup - build the camera basis for the current canvas rectangle
# -----------------------------------------------------------------------------
cam_setup:
    fld     dword ptr [rip+cam_yaw]
    fsincos
    fstp    dword ptr [rip+cos_y]
    fstp    dword ptr [rip+sin_y]
    fld     dword ptr [rip+cam_pitch]
    fsincos
    fstp    dword ptr [rip+cos_p]
    fstp    dword ptr [rip+sin_p]

    movss   xmm0, [rip+cos_y]           # right = (cy, 0, -sy)
    movss   [rip+right], xmm0
    xorps   xmm1, xmm1
    movss   [rip+right+4], xmm1
    subss   xmm1, [rip+sin_y]
    movss   [rip+right+8], xmm1

    movss   xmm0, [rip+sin_p]           # up = (-sp*sy, cp, -sp*cy)
    mulss   xmm0, [rip+sin_y]
    xorps   xmm1, xmm1
    subss   xmm1, xmm0
    movss   [rip+up], xmm1
    movss   xmm0, [rip+cos_p]
    movss   [rip+up+4], xmm0
    movss   xmm0, [rip+sin_p]
    mulss   xmm0, [rip+cos_y]
    xorps   xmm1, xmm1
    subss   xmm1, xmm0
    movss   [rip+up+8], xmm1

    movss   xmm0, [rip+cos_p]           # fwd = -(cp*sy, sp, cp*cy)
    mulss   xmm0, [rip+sin_y]
    xorps   xmm1, xmm1
    subss   xmm1, xmm0
    movss   [rip+fwd], xmm1
    xorps   xmm1, xmm1
    subss   xmm1, [rip+sin_p]
    movss   [rip+fwd+4], xmm1
    movss   xmm0, [rip+cos_p]
    mulss   xmm0, [rip+cos_y]
    xorps   xmm1, xmm1
    subss   xmm1, xmm0
    movss   [rip+fwd+8], xmm1

    movss   xmm2, [rip+cam_dist]        # eye = target - fwd * dist
    movss   xmm0, [rip+fwd]
    mulss   xmm0, xmm2
    movss   xmm1, [rip+cam_tx]
    subss   xmm1, xmm0
    movss   [rip+eye], xmm1
    movss   xmm0, [rip+fwd+4]
    mulss   xmm0, xmm2
    movss   xmm1, [rip+cam_ty]
    subss   xmm1, xmm0
    movss   [rip+eye+4], xmm1
    movss   xmm0, [rip+fwd+8]
    mulss   xmm0, xmm2
    movss   xmm1, [rip+cam_tz]
    subss   xmm1, xmm0
    movss   [rip+eye+8], xmm1

    # canvas in physical pixels (the projection draws straight into them)
    push    rbx
    push    r12
    push    r13
    mov     edi, [rip+cvs_x0]
    call    to_px
    mov     ebx, eax
    mov     edi, [rip+cvs_x1]
    call    to_px
    add     ebx, eax                    # x0 + x1
    mov     edi, [rip+cvs_y0]
    call    to_px
    mov     r12d, eax
    mov     edi, [rip+cvs_y1]
    call    to_px
    mov     r13d, eax
    sub     eax, r12d                   # physical height
    cvtsi2ss xmm0, eax
    mulss   xmm0, [rip+vp_focal_k]
    movss   [rip+vp_focal], xmm0        # focal length in pixels
    movss   xmm1, [rip+cam_dist]        # world units per logical pixel
    divss   xmm1, xmm0
    cvtsi2ss xmm2, dword ptr [rip+ui_s120]
    mulss   xmm1, xmm2
    divss   xmm1, [rip+f_120]
    movss   [rip+px_world], xmm1
    cvtsi2ss xmm0, ebx
    mulss   xmm0, [rip+f_half]
    movss   [rip+vp_cx], xmm0
    lea     eax, [r12+r13]
    cvtsi2ss xmm0, eax
    mulss   xmm0, [rip+f_half]
    movss   [rip+vp_cy], xmm0
    pop     r13
    pop     r12
    pop     rbx
    ret

# to_cam(rdi=world vec3, rsi=out camera-space vec3)
to_cam:
    movss   xmm0, [rdi]
    subss   xmm0, [rip+eye]
    movss   xmm1, [rdi+4]
    subss   xmm1, [rip+eye+4]
    movss   xmm2, [rdi+8]
    subss   xmm2, [rip+eye+8]
    movss   xmm3, xmm0                  # x = d . right   (right.y == 0)
    mulss   xmm3, [rip+right]
    movss   xmm4, xmm2
    mulss   xmm4, [rip+right+8]
    addss   xmm3, xmm4
    movss   [rsi], xmm3
    movss   xmm3, xmm0                  # y = d . up
    mulss   xmm3, [rip+up]
    movss   xmm4, xmm1
    mulss   xmm4, [rip+up+4]
    addss   xmm3, xmm4
    movss   xmm4, xmm2
    mulss   xmm4, [rip+up+8]
    addss   xmm3, xmm4
    movss   [rsi+4], xmm3
    movss   xmm3, xmm0                  # z = d . fwd
    mulss   xmm3, [rip+fwd]
    movss   xmm4, xmm1
    mulss   xmm4, [rip+fwd+4]
    addss   xmm3, xmm4
    movss   xmm4, xmm2
    mulss   xmm4, [rip+fwd+8]
    addss   xmm3, xmm4
    movss   [rsi+8], xmm3
    ret

# clip_near(rdi=point behind the near plane, rsi=point in front) - moves rdi
clip_near:
    movss   xmm0, [rip+vp_near]
    subss   xmm0, [rdi+8]
    movss   xmm1, [rsi+8]
    subss   xmm1, [rdi+8]
    divss   xmm0, xmm1                  # t
    movss   xmm1, [rsi]
    subss   xmm1, [rdi]
    mulss   xmm1, xmm0
    addss   xmm1, [rdi]
    movss   [rdi], xmm1
    movss   xmm1, [rsi+4]
    subss   xmm1, [rdi+4]
    mulss   xmm1, xmm0
    addss   xmm1, [rdi+4]
    movss   [rdi+4], xmm1
    movss   xmm1, [rip+vp_near]
    movss   [rdi+8], xmm1
    ret

# project(rdi=camera-space vec3, rsi=out 2 floats)
project:
    movss   xmm2, [rip+vp_focal]
    divss   xmm2, [rdi+8]
    movss   xmm0, [rdi]
    mulss   xmm0, xmm2
    addss   xmm0, [rip+vp_cx]
    movss   [rsi], xmm0
    movss   xmm1, [rdi+4]
    mulss   xmm1, xmm2
    movss   xmm0, [rip+vp_cy]
    subss   xmm0, xmm1
    movss   [rsi+4], xmm0
    ret

# lb_edge(xmm0=p, xmm1=q) ; u0 in xmm6, u1 in xmm7 ; eax=1 -> fully clipped
lb_edge:
    xorps   xmm2, xmm2
    comiss  xmm0, xmm2
    je      3f
    divss   xmm1, xmm0                  # r = q / p
    jb      1f
    minss   xmm7, xmm1                  # p > 0: leaving edge
    jmp     2f
1:  maxss   xmm6, xmm1                  # p < 0: entering edge
2:  comiss  xmm6, xmm7
    ja      4f
    xor     eax, eax
    ret
3:  comiss  xmm1, xmm2                  # parallel: outside if q < 0
    jb      4f
    xor     eax, eax
    ret
4:  mov     eax, 1
    ret

# -----------------------------------------------------------------------------
# line3d(edx=color) - draws lp0 -> lp1 (world space)
# -----------------------------------------------------------------------------
line3d:
    push    rbx
    push    r12
    sub     rsp, 8
    mov     ebx, edx
    mov     r8d, ebx                    # the active theme's colour
    call    th_map
    mov     ebx, r8d
    lea     rdi, [rip+lp0]
    lea     rsi, [rip+la]
    call    to_cam
    lea     rdi, [rip+lp1]
    lea     rsi, [rip+lb]
    call    to_cam
    movss   xmm7, [rip+vp_near]
    movss   xmm0, [rip+la+8]
    movss   xmm1, [rip+lb+8]
    comiss  xmm0, xmm7
    jae     1f
    comiss  xmm1, xmm7
    jb      9f                          # both behind the camera
    lea     rdi, [rip+la]
    lea     rsi, [rip+lb]
    call    clip_near
    jmp     2f
1:  comiss  xmm1, xmm7
    jae     2f
    lea     rdi, [rip+lb]
    lea     rsi, [rip+la]
    call    clip_near
2:  lea     r12, [rip+lb_buf]
    lea     rdi, [rip+la]
    mov     rsi, r12
    call    project
    lea     rdi, [rip+lb]
    lea     rsi, [r12+8]
    call    project

    # Liang-Barsky against the clip rect
    xorps   xmm6, xmm6                  # u0
    movss   xmm7, [rip+f_one]           # u1
    movss   xmm4, [r12+8]
    subss   xmm4, [r12]                 # dx
    movss   xmm5, [r12+12]
    subss   xmm5, [r12+4]               # dy

    xorps   xmm0, xmm0                  # left:   p=-dx q=x0-xmin
    subss   xmm0, xmm4
    cvtsi2ss xmm1, dword ptr [rip+clip_x0]
    movss   xmm2, [r12]
    subss   xmm2, xmm1
    movss   xmm1, xmm2
    call    lb_edge
    test    eax, eax
    jnz     9f
    movss   xmm0, xmm4                  # right:  p=dx q=xmax-x0
    mov     eax, [rip+clip_x1]
    dec     eax
    cvtsi2ss xmm1, eax
    subss   xmm1, [r12]
    call    lb_edge
    test    eax, eax
    jnz     9f
    xorps   xmm0, xmm0                  # top:    p=-dy q=y0-ymin
    subss   xmm0, xmm5
    cvtsi2ss xmm1, dword ptr [rip+clip_y0]
    movss   xmm2, [r12+4]
    subss   xmm2, xmm1
    movss   xmm1, xmm2
    call    lb_edge
    test    eax, eax
    jnz     9f
    movss   xmm0, xmm5                  # bottom: p=dy q=ymax-y0
    mov     eax, [rip+clip_y1]
    dec     eax
    cvtsi2ss xmm1, eax
    subss   xmm1, [r12+4]
    call    lb_edge
    test    eax, eax
    jnz     9f

    movss   xmm0, xmm4                  # x0' = x0 + u0*dx
    mulss   xmm0, xmm6
    addss   xmm0, [r12]
    cvtss2si edi, xmm0
    movss   xmm0, xmm5                  # y0' = y0 + u0*dy
    mulss   xmm0, xmm6
    addss   xmm0, [r12+4]
    cvtss2si esi, xmm0
    movss   xmm0, xmm4                  # x1' = x0 + u1*dx
    mulss   xmm0, xmm7
    addss   xmm0, [r12]
    cvtss2si edx, xmm0
    movss   xmm0, xmm5                  # y1' = y0 + u1*dy
    mulss   xmm0, xmm7
    addss   xmm0, [r12+4]
    cvtss2si ecx, xmm0
    mov     r8d, ebx
    call    draw_line_px
9:  add     rsp, 8
    pop     r12
    pop     rbx
    ret

# set_lp(xmm0..xmm2 -> lp0, xmm3..xmm5 -> lp1)
set_lp:
    movss   [rip+lp0], xmm0
    movss   [rip+lp0+4], xmm1
    movss   [rip+lp0+8], xmm2
    movss   [rip+lp1], xmm3
    movss   [rip+lp1+4], xmm4
    movss   [rip+lp1+8], xmm5
    ret

# -----------------------------------------------------------------------------
# viewport_draw - render the canvas area
# -----------------------------------------------------------------------------
viewport_draw:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    mov     edi, [rip+cvs_x0]
    mov     esi, [rip+cvs_y0]
    mov     edx, [rip+cvs_x1]
    sub     edx, edi
    mov     ecx, [rip+cvs_y1]
    sub     ecx, esi
    mov     r8d, COL_CANVAS_TOP
    mov     r9d, COL_CANVAS_BOT
    call    fill_vgradient
    mov     edi, [rip+cvs_x0]
    mov     esi, [rip+cvs_y0]
    mov     edx, [rip+cvs_x1]
    mov     ecx, [rip+cvs_y1]
    call    set_clip
    call    cam_setup

    cmp     dword ptr [rip+show_grid], 0
    je      .Lvp_object
    # ---- ground grid ---------------------------------------------------------
    mov     ebx, -GRID_N
.Lvp_grid:
    test    ebx, ebx
    jz      .Lvp_gnext                  # the axes are drawn on top later
    mov     r12d, COL_GRID
    mov     eax, ebx
    cdq
    mov     ecx, 5
    idiv    ecx
    test    edx, edx
    jnz     1f
    mov     r12d, COL_GRID_MAJOR
1:  cvtsi2ss xmm0, ebx                  # line parallel to Z at x = i
    xorps   xmm1, xmm1
    mov     eax, -GRID_N
    cvtsi2ss xmm2, eax
    movss   xmm3, xmm0
    xorps   xmm4, xmm4
    mov     eax, GRID_N
    cvtsi2ss xmm5, eax
    mulss   xmm0, [rip+vp_grid]
    mulss   xmm1, [rip+vp_grid]
    mulss   xmm2, [rip+vp_grid]
    mulss   xmm3, [rip+vp_grid]
    mulss   xmm4, [rip+vp_grid]
    mulss   xmm5, [rip+vp_grid]
    call    set_lp
    mov     edx, r12d
    call    line3d
    mov     eax, -GRID_N                # line parallel to X at z = i
    cvtsi2ss xmm0, eax
    xorps   xmm1, xmm1
    cvtsi2ss xmm2, ebx
    mov     eax, GRID_N
    cvtsi2ss xmm3, eax
    xorps   xmm4, xmm4
    movss   xmm5, xmm2
    mulss   xmm0, [rip+vp_grid]
    mulss   xmm1, [rip+vp_grid]
    mulss   xmm2, [rip+vp_grid]
    mulss   xmm3, [rip+vp_grid]
    mulss   xmm4, [rip+vp_grid]
    mulss   xmm5, [rip+vp_grid]
    call    set_lp
    mov     edx, r12d
    call    line3d
.Lvp_gnext:
    inc     ebx
    cmp     ebx, GRID_N
    jle     .Lvp_grid

    # ---- world axes ------------------------------------------------------------
    mov     eax, -GRID_N                # X (red)
    cvtsi2ss xmm0, eax
    xorps   xmm1, xmm1
    xorps   xmm2, xmm2
    neg     eax
    cvtsi2ss xmm3, eax
    xorps   xmm4, xmm4
    xorps   xmm5, xmm5
    call    set_lp
    mov     edx, COL_AXIS_X
    call    line3d
    xorps   xmm0, xmm0                  # Z (blue)
    xorps   xmm1, xmm1
    mov     eax, -GRID_N
    cvtsi2ss xmm2, eax
    xorps   xmm3, xmm3
    xorps   xmm4, xmm4
    neg     eax
    cvtsi2ss xmm5, eax
    call    set_lp
    mov     edx, COL_AXIS_Z
    call    line3d
    xorps   xmm0, xmm0                  # Y (green, up)
    xorps   xmm1, xmm1
    xorps   xmm2, xmm2
    xorps   xmm3, xmm3
    movss   xmm4, [rip+f_axis_y]
    xorps   xmm5, xmm5
    call    set_lp
    mov     edx, COL_AXIS_Y
    call    line3d

.Lvp_object:
    call    edit_prepare                # edit mode: selected faces
    cmp     dword ptr [rip+vp_shading], 1   # (wireframe: no raster)
    je      1f
    xor     edi, edi                    # solid: rasterize meshes (+ outline)
    call    raster_scene
    call    sculpt_draw                 # the sculpt mesh: its own path
    call    inst_draw                   # instances: splats and triangles
1:  call    draw_objects                # wires (all objects, or non-meshes)
    call    wp_draw                     # world cells not loaded, the minimap
    call    lb_ghost                    # a library asset being dragged in
    call    pb_draw                     # light probes: their boxes
    call    vc_draw                     # versions: the diff, the merge panel
    call    co_draw                     # co-editing: the other peers
    call    play_hud                    # play mode: the keys, or the question
    call    edit_draw                   # edit mode: edges, vertices, faces
    call    analysis_draw               # View > Show ... overlays
    call    etool_draw                  # loop cut / knife previews
    call    cursor_draw                 # the 3D cursor
    call    gizmo_draw
    call    tm_draw
    call    skm_overlay                 # sketch mode: points, labels, tools
    call    cve_overlay                 # curve edit mode: points, handles
    call    cp_draw                     # an AI proposal: Accept / Revert
    call    arm_overlay                 # armature modes: bones, joints
    call    rig_draw                    # motion paths, onion skins
    call    sculpt_overlay              # sculpt mode: the brush, settings
    call    paint_overlay               # texture paint: the same

    # ---- orientation gizmo (bottom-left) -----------------------------------
    mov     r12d, [rip+cvs_x0]
    add     r12d, 50
    mov     r13d, [rip+cvs_y1]
    sub     r13d, 50
    xor     ebx, ebx                    # axis 0..2
.Lvp_giz:
    lea     rax, [rip+right]
    movss   xmm0, [rax+rbx*4]
    mulss   xmm0, [rip+f_gizmo]
    cvtss2si r14d, xmm0
    add     r14d, r12d                  # tip x
    lea     rax, [rip+up]
    movss   xmm0, [rax+rbx*4]
    mulss   xmm0, [rip+f_gizmo]
    cvtss2si r15d, xmm0
    neg     r15d
    add     r15d, r13d                  # tip y
    lea     rax, [rip+axis_colors]
    mov     eax, [rax+rbx*4]
    mov     [rip+tmpf], eax
    mov     edi, r12d
    mov     esi, r13d
    mov     edx, r14d
    mov     ecx, r15d
    mov     r8d, eax
    call    draw_line
    lea     edi, [r12+1]
    mov     esi, r13d
    lea     edx, [r14+1]
    mov     ecx, r15d
    mov     r8d, [rip+tmpf]
    call    draw_line
    lea     edi, [r14-3]
    lea     esi, [r15-7]
    lea     rax, [rip+axis_labels]
    mov     rdx, [rax+rbx*8]
    mov     ecx, [rip+tmpf]
    call    draw_text
    inc     ebx
    cmp     ebx, 3
    jb      .Lvp_giz

    call    nav_gizmo_draw              # the navigation gizmo (vpnav.s)
    call    tool_settings_draw          # a brush mode: its settings (vpnav.s)
    mov     edi, [rip+cvs_x0]           # an empty scene: what to do first (help.s)
    mov     esi, [rip+cvs_y0]
    mov     edx, [rip+cvs_x1]
    mov     ecx, [rip+cvs_y1]
    call    vp_quick_draw

    # ---- overlay text ---------------------------------------------------------
    mov     edi, [rip+cvs_x0]
    add     edi, 10
    mov     esi, [rip+cvs_y0]
    add     esi, 8
    lea     rdx, [rip+s_vp_label]
    mov     ecx, COL_TEXT
    call    draw_text
    call    redo_draw                   # adjust the last operation (on top)
    call    reset_clip
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

.section .rodata
.align 8
axis_colors: .long COL_AXIS_X, COL_AXIS_Y, COL_AXIS_Z
.align 8
axis_labels: .quad s_ax_x, s_ax_y, s_ax_z
f_half:      .float 0.5
f_huge:      .float 1.0e30
f_nhuge:     .float -1.0e30
f_slack:     .float 4.0
f_120:       .float 120.0
.text

# -----------------------------------------------------------------------------
# Scene objects: wireframes through each object's matrix
# -----------------------------------------------------------------------------
draw_objects:
    push    rbx
    push    r12
    push    r13
    xor     r12d, r12d                  # pass 0: unselected, 1: selected
1:  xor     ebx, ebx
2:  cmp     ebx, [rip+obj_count]
    jae     6f
    mov     edi, ebx
    call    obj_at
    test    dword ptr [rax+OB_FLAGS], OBF_HIDDEN
    jnz     5f
    cmp     dword ptr [rip+vp_shading], 1   # shaded modes draw meshes raster
    je      3f
    cmp     dword ptr [rax+OB_TYPE], OT_MESH
    jne     3f
    push    rax                         # (but lines - curves - as wires)
    mov     rdi, rax
    call    edge_only
    mov     ecx, eax
    pop     rax
    test    ecx, ecx
    jz      5f
3:  mov     ecx, [rax+OB_FLAGS]
    and     ecx, OBF_SELECTED
    cmp     ecx, r12d
    jne     5f
    mov     r13d, [rax+OB_COLOR]
    test    r12d, r12d
    jz      4f
    mov     r13d, COL_SELECTED
    lea     rcx, [rip+obj_list]
    mov     ecx, [rcx+rbx*4]
    cmp     ecx, [rip+active_obj]
    jne     4f
    mov     r13d, COL_ACTIVE
4:  cmp     dword ptr [rax+OB_TYPE], OT_SKETCH
    jne     41f
    mov     rdi, rax                    # sketches: their entities, coloured
    xor     esi, esi                    #  by status when selected
    test    r12d, r12d
    jnz     42f
    mov     esi, r13d
42: call    skx_draw
    jmp     5f
41: mov     rdi, rax
    mov     esi, r13d
    call    draw_obj_wire
5:  inc     ebx
    jmp     2b
6:  inc     r12d
    cmp     r12d, 2
    jb      1b
    pop     r13
    pop     r12
    pop     rbx
    ret

# edge_only(rdi=mesh object) -> eax = 1 when what it shows has lines but no
#   faces (a curve without a bevel): drawn as a wire, picked by its bounds
edge_only:
    sub     rsp, 8
    call    obj_eval
    add     rsp, 8
    xor     ecx, ecx
    cmp     dword ptr [rax+ME_NTRIS], 0
    jne     1f
    cmp     dword ptr [rax+ME_NEDGES], 0
    setne   cl
1:  mov     eax, ecx
    ret

# world_verts(rdi=object) -> rax = world-space positions (frame arena), ecx = n
world_verts:
    push    rbx
    push    r12
    push    r13
    push    r14
    sub     rsp, 56
    mov     rbx, rdi
    mov     rsi, rsp
    call    obj_matrix
    mov     rdi, rbx                    # what is drawn: after modifiers
    call    obj_eval
    mov     r12, rax
    mov     r13d, [r12+ME_NVERTS]
    lea     rdi, [rip+frame_arena]
    imul    esi, r13d, 12
    call    arena_alloc
    mov     r14, rax
    test    rax, rax
    jz      9f
    xor     ebx, ebx
1:  cmp     ebx, r13d
    jae     9f
    imul    rcx, rbx, 12
    mov     rsi, [r12+ME_POS]
    add     rsi, rcx
    lea     rdx, [r14+rcx]
    mov     rdi, rsp
    call    xform_point
    inc     ebx
    jmp     1b
9:  mov     rax, r14
    mov     ecx, r13d
    add     rsp, 56
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# draw_obj_wire(rdi=object, esi=color)
draw_obj_wire:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    mov     r15d, esi
    push    rdi
    call    obj_eval
    pop     rdi
    mov     r12, rax
    call    world_verts
    test    rax, rax
    jz      9f
    mov     r13, rax
    xor     ebx, ebx
1:  cmp     ebx, [r12+ME_NEDGES]
    jae     9f
    mov     rcx, [r12+ME_EDGES]
    mov     eax, [rcx+rbx*8]
    imul    rax, rax, 12
    mov     rdx, [r13+rax]
    mov     [rip+lp0], rdx
    mov     edx, [r13+rax+8]
    mov     [rip+lp0+8], edx
    mov     eax, [rcx+rbx*8+4]
    imul    rax, rax, 12
    mov     rdx, [r13+rax]
    mov     [rip+lp1], rdx
    mov     edx, [r13+rax+8]
    mov     [rip+lp1+8], edx
    mov     edx, r15d
    call    line3d
    inc     ebx
    jmp     1b
9:  pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# vp_pick(edi=x, esi=y logical) -> eax = handle of the object whose projected
# bounds contain the point (smallest bounds wins), 0 if none. Needs cam_setup.
vp_pick:
    push    rdi
    push    rsi
    sub     rsp, 8
    call    raster_pick                 # exact: the ID buffer
    add     rsp, 8
    pop     rsi
    pop     rdi
    test    eax, eax
    jz      vp_pick_bounds
    lea     rcx, [rip+obj_list]
    mov     eax, [rcx+rax*4-4]
    ret
# vp_pick_bounds - lights and cameras have no surface: use projected bounds
vp_pick_bounds:
    push    rbx
    push    rbp
    push    r12
    push    r13
    push    r14
    push    r15
    sub     rsp, 40
    call    to_px
    mov     [rsp+24], eax               # physical x
    mov     edi, esi
    call    to_px
    mov     [rsp+28], eax               # physical y
    xor     ebp, ebp                    # best handle
    movss   xmm0, [rip+f_huge]
    movss   [rsp+32], xmm0              # best area
    xor     ebx, ebx
.Lpk_obj:
    cmp     ebx, [rip+obj_count]
    jae     .Lpk_done
    mov     edi, ebx
    call    obj_at
    test    dword ptr [rax+OB_FLAGS], OBF_HIDDEN
    jnz     .Lpk_next
    cmp     dword ptr [rax+OB_TYPE], OT_MESH
    jne     1f
    push    rax                         # meshes: the ID buffer, unless lines
    mov     rdi, rax
    call    edge_only
    mov     ecx, eax
    pop     rax
    test    ecx, ecx
    jz      .Lpk_next
1:  mov     rdi, rax
    call    world_verts
    test    rax, rax
    jz      .Lpk_next
    mov     r12, rax
    mov     r13d, ecx
    movss   xmm0, [rip+f_huge]          # screen bounds
    movss   [rsp], xmm0
    movss   [rsp+4], xmm0
    movss   xmm0, [rip+f_nhuge]
    movss   [rsp+8], xmm0
    movss   [rsp+12], xmm0
    xor     r14d, r14d                  # projected count
    xor     r15d, r15d
1:  cmp     r15d, r13d
    jae     3f
    imul    rdi, r15, 12
    add     rdi, r12
    lea     rsi, [rip+la]
    call    to_cam
    movss   xmm0, [rip+la+8]
    comiss  xmm0, [rip+vp_near]
    jb      2f
    lea     rdi, [rip+la]
    lea     rsi, [rsp+16]
    call    project
    movss   xmm0, [rsp+16]
    movss   xmm1, [rsp+20]
    movss   xmm2, [rsp]
    minss   xmm2, xmm0
    movss   [rsp], xmm2
    movss   xmm2, [rsp+4]
    minss   xmm2, xmm1
    movss   [rsp+4], xmm2
    movss   xmm2, [rsp+8]
    maxss   xmm2, xmm0
    movss   [rsp+8], xmm2
    movss   xmm2, [rsp+12]
    maxss   xmm2, xmm1
    movss   [rsp+12], xmm2
    inc     r14d
2:  inc     r15d
    jmp     1b
3:  test    r14d, r14d
    jz      .Lpk_next
    cvtsi2ss xmm0, dword ptr [rsp+24]   # inside (with a few pixels slack)?
    cvtsi2ss xmm1, dword ptr [rsp+28]
    movss   xmm2, [rsp]
    subss   xmm2, [rip+f_slack]
    comiss  xmm0, xmm2
    jb      .Lpk_next
    movss   xmm2, [rsp+8]
    addss   xmm2, [rip+f_slack]
    comiss  xmm0, xmm2
    ja      .Lpk_next
    movss   xmm2, [rsp+4]
    subss   xmm2, [rip+f_slack]
    comiss  xmm1, xmm2
    jb      .Lpk_next
    movss   xmm2, [rsp+12]
    addss   xmm2, [rip+f_slack]
    comiss  xmm1, xmm2
    ja      .Lpk_next
    movss   xmm0, [rsp+8]               # area of the bounds
    subss   xmm0, [rsp]
    addss   xmm0, [rip+f_slack]
    movss   xmm1, [rsp+12]
    subss   xmm1, [rsp+4]
    addss   xmm1, [rip+f_slack]
    mulss   xmm0, xmm1
    comiss  xmm0, [rsp+32]
    jae     .Lpk_next
    movss   [rsp+32], xmm0
    lea     rax, [rip+obj_list]
    mov     ebp, [rax+rbx*4]
.Lpk_next:
    inc     ebx
    jmp     .Lpk_obj
.Lpk_done:
    mov     eax, ebp
    add     rsp, 40
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbp
    pop     rbx
    ret

# -----------------------------------------------------------------------------
# Camera controls
# -----------------------------------------------------------------------------
# vp_orbit(edi=dx, esi=dy)
vp_orbit:
    cvtsi2ss xmm0, edi
    mulss   xmm0, [rip+f_orbit_k]
    movss   xmm1, [rip+cam_yaw]
    subss   xmm1, xmm0
    movss   [rip+cam_yaw], xmm1
    cvtsi2ss xmm0, esi
    mulss   xmm0, [rip+f_orbit_k]
    addss   xmm0, [rip+cam_pitch]
    maxss   xmm0, [rip+f_pitch_min]
    minss   xmm0, [rip+f_pitch_max]
    movss   [rip+cam_pitch], xmm0
    ret

# vp_pan(edi=dx, esi=dy) - drag the scene with the pointer
vp_pan:
    cvtsi2ss xmm0, edi
    mulss   xmm0, [rip+px_world]        # world dx
    cvtsi2ss xmm1, esi
    mulss   xmm1, [rip+px_world]        # world dy
    xor     eax, eax
    lea     rcx, [rip+cam_tx]
    lea     rdx, [rip+right]
    lea     r8, [rip+up]
1:  movss   xmm2, [rdx+rax*4]
    mulss   xmm2, xmm0
    movss   xmm3, [r8+rax*4]
    mulss   xmm3, xmm1
    movss   xmm4, [rcx+rax*4]
    subss   xmm4, xmm2
    addss   xmm4, xmm3
    movss   [rcx+rax*4], xmm4
    inc     eax
    cmp     eax, 3
    jb      1b
    ret

# vp_zoom(edi = >0 zoom out, <0 zoom in)
vp_zoom:
    movss   xmm0, [rip+cam_dist]
    test    edi, edi
    js      1f
    mulss   xmm0, [rip+f_zoom_out]
    jmp     2f
1:  mulss   xmm0, [rip+f_zoom_in]
2:  maxss   xmm0, [rip+f_dist_min]
    minss   xmm0, [rip+f_dist_max]
    movss   [rip+cam_dist], xmm0
    ret

# ---- viewport operators (registered into the operator spine) --------------
OPERATOR op_view_wire,      "view.toggle_wireframe", "Wireframe", op_shading_set, op_shading_is, 1, KEY_Z, doc="Switch the viewport between solid shading and wireframe"
OPERATOR op_view_matprev,   "view.toggle_material_preview", "Material Preview", op_shading_set, op_shading_is, 2, KEY_Z|KM_SHIFT, doc="Shade the viewport with each object's material under a studio light (Shift+Z)"

.text
# op_shading_set(edi=mode) - that mode, or solid when it is already on;
#   op_shading_is(edi=mode) -> eax = 1 when on
OPERATOR op_shade_solid, "view.shading_solid", "Solid", op_shading_exact, op_shading_is, 0, flags=OPF_AI_SAFE|OPF_HIDDEN, doc="Solid shading in the viewport"
OPERATOR op_shade_wire,  "view.shading_wireframe", "Wireframe", op_shading_exact, op_shading_is, 1, flags=OPF_AI_SAFE|OPF_HIDDEN, doc="Wireframe shading in the viewport"
OPERATOR op_shade_mat,   "view.shading_material", "Material Preview", op_shading_exact, op_shading_is, 2, flags=OPF_AI_SAFE|OPF_HIDDEN, doc="Shade the viewport with each object's material"
op_shading_exact:                       # (pie menu: exactly this one)
    mov     [rip+vp_shading], edi
    mov     dword ptr [rip+dirty], 1
    ret
op_shading_set:
    xor     eax, eax
    cmp     [rip+vp_shading], edi
    je      1f
    mov     eax, edi
1:  mov     [rip+vp_shading], eax
    mov     dword ptr [rip+dirty], 1
    ret
op_shading_is:
    xor     eax, eax
    cmp     [rip+vp_shading], edi
    sete    al
    ret
OPERATOR op_view_grid,      "view.toggle_grid",  "Ground Grid",  op_toggle_flag, op_check_flag, show_grid, KEY_G|KM_SHIFT, doc="Show or hide the ground grid and axes"
OPERATOR op_view_reset_cam, "view.reset_camera", "Reset Camera", op_reset_camera, key=KEY_F, flags=OPF_AI_SAFE|OPF_OBJECT, doc="Return the viewport camera to its default view (F in object mode, Home anywhere)"
OPERATOR op_view_reset_home, "view.reset_camera_home", "Reset Camera", op_reset_camera, key=102, flags=OPF_AI_SAFE|OPF_HIDDEN, doc="Return the viewport camera to its default view"
op_reset_camera:
    mov     edi, [rip+vp_area]
    call    cam_load
    call    vp_reset
    mov     edi, [rip+vp_area]
    jmp     cam_store
vp_reset:
    movss   xmm0, [rip+f_def_yaw]
    movss   [rip+cam_yaw], xmm0
    movss   xmm0, [rip+f_def_pitch]
    movss   [rip+cam_pitch], xmm0
    movss   xmm0, [rip+f_def_dist]
    movss   [rip+cam_dist], xmm0
    xorps   xmm0, xmm0
    movss   [rip+cam_tx], xmm0
    movss   [rip+cam_ty], xmm0
    movss   [rip+cam_tz], xmm0
    ret

.section .note.GNU-stack,"",@progbits
