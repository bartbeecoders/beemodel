# =============================================================================
#  BeeModel - Camera View (Numpad 0): a viewport looks through the camera
#  that renders (lc_camera) - its place, its turn (roll too) and its lens,
#  every redraw, so an animated camera is followed while the animation
#  plays. The render's frame (render.settings' width x height) is fitted
#  into the canvas and what lies outside it is dimmed. cam_setup asks
#  cv_apply for it; each viewport keeps its own switch (areas.s
#  area_camv). Orbiting, panning, zooming or a view change leaves it,
#  starting from where the camera looks (cv_leave); play mode wins.
# =============================================================================
.intel_syntax noprefix
.include "const.inc"
.include "macros.inc"

.globl cam_view
.globl cv_obj
.globl cv_apply
.globl cv_leave
.globl cv_draw
.globl cv_label

.section .data
.align 4
cam_view:   .long 0                     # this viewport: through the camera
                                        #  (per viewport: areas.s)
.section .rodata
.align 16
cv_sign:    .long 0x80000000, 0, 0, 0   # (xorps: aligned)
cv_half:    .float 0.5
cv_one:     .float 1.0
cv_tiny:    .float 1.0e-8
cv_pmax:    .float 1.55                 # (viewport.s's pitch range)
cv_pmin:    .float -1.55
s_cv_label: .asciz "Camera  |  "
s_cv_none:  .asciz "  view.camera: the scene has no camera (Add > Camera)"

.section .bss
.align 8
cv_obj:     .skip 8                     # the camera the last cam_setup looked
                                        #  through (0: none)
cv_fx:      .skip 4                     # its frame in the canvas (logical)
cv_fy:      .skip 4
cv_fw:      .skip 4
cv_fh:      .skip 4
cv_buf:     .skip 64                    # cv_label's text

.text

# cv_mat(rdi=float[12] out) -> rax = the camera that renders (0: none),
#   its matrix (row-major 3x4) at rdi
cv_mat:
    push    rbx
    mov     rbx, rdi
    call    lc_camera
    test    rax, rax
    jz      9f
    push    rax
    mov     rdi, rax
    mov     rsi, rbx
    call    obj_matrix
    pop     rax
9:  pop     rbx
    ret

# cv_unit(rdi=float[3]) - made unit length (left as it is when ~0)
cv_unit:
    movss   xmm0, [rdi]
    mulss   xmm0, xmm0
    movss   xmm1, [rdi+4]
    mulss   xmm1, xmm1
    addss   xmm0, xmm1
    movss   xmm1, [rdi+8]
    mulss   xmm1, xmm1
    addss   xmm0, xmm1
    comiss  xmm0, [rip+cv_tiny]
    jbe     9f
    sqrtss  xmm0, xmm0
    movss   xmm1, [rip+cv_one]
    divss   xmm1, xmm0
    movss   xmm0, [rdi]
    mulss   xmm0, xmm1
    movss   [rdi], xmm0
    movss   xmm0, [rdi+4]
    mulss   xmm0, xmm1
    movss   [rdi+4], xmm0
    movss   xmm0, [rdi+8]
    mulss   xmm0, xmm1
    movss   [rdi+8], xmm0
9:  ret

# cv_apply - from cam_setup, once the view's eye and basis are made: in
#   Camera View, the camera's eye, right, up, forward (its -Z) and the focal
#   length that fits the render's frame into the canvas (cv_fx ..)
cv_apply:
    push    rbp
    mov     rbp, rsp
    push    rbx
    push    r12
    push    r13
    push    r14
    and     rsp, -16
    sub     rsp, 64
    mov     qword ptr [rip+cv_obj], 0
    cmp     dword ptr [rip+cam_view], 0
    je      9f
    cmp     dword ptr [rip+pl_on], 0    # (play mode: the player's eyes)
    jne     9f
    lea     rdi, [rsp]
    call    cv_mat
    test    rax, rax
    jz      9f
    mov     [rip+cv_obj], rax
    mov     ebx, [rax+OB_UID]
    xor     ecx, ecx                    # columns: right, up, -forward
1:  imul    edx, ecx, 16
    mov     eax, [rsp+rdx+12]
    lea     rdi, [rip+eye]
    mov     [rdi+rcx*4], eax
    mov     eax, [rsp+rdx]
    lea     rdi, [rip+right]
    mov     [rdi+rcx*4], eax
    mov     eax, [rsp+rdx+4]
    lea     rdi, [rip+up]
    mov     [rdi+rcx*4], eax
    mov     eax, [rsp+rdx+8]
    xor     eax, 0x80000000
    lea     rdi, [rip+fwd]
    mov     [rdi+rcx*4], eax
    inc     ecx
    cmp     ecx, 3
    jb      1b
    lea     rdi, [rip+right]
    call    cv_unit
    lea     rdi, [rip+up]
    call    cv_unit
    lea     rdi, [rip+fwd]
    call    cv_unit

    # the frame: render width x height, as big as the canvas allows
    cvtsi2ss xmm0, dword ptr [rip+rn_w]
    cvtsi2ss xmm1, dword ptr [rip+rn_h]
    divss   xmm0, xmm1
    movss   [rsp+48], xmm0              # aspect
    mov     edi, [rip+cvs_x0]           # physical: the focal length
    call    to_px
    mov     r12d, eax
    mov     edi, [rip+cvs_x1]
    call    to_px
    sub     eax, r12d
    mov     r12d, eax                   # width
    mov     edi, [rip+cvs_y0]
    call    to_px
    mov     r13d, eax
    mov     edi, [rip+cvs_y1]
    call    to_px
    sub     eax, r13d                   # height
    cvtsi2ss xmm0, eax
    mulss   xmm0, [rsp+48]
    cvtsi2ss xmm1, r12d
    minss   xmm0, xmm1                  # the frame's width
    mulss   xmm0, [rip+cv_half]
    movss   [rsp+52], xmm0
    mov     edi, ebx                    # / tan(half the lens' view across)
    call    lc_lens_tan
    movss   xmm1, [rsp+52]
    divss   xmm1, xmm0
    movss   [rip+vp_focal], xmm1
    mov     r12d, [rip+cvs_x1]          # logical: the frame to draw
    sub     r12d, [rip+cvs_x0]
    mov     r13d, [rip+cvs_y1]
    sub     r13d, [rip+cvs_y0]
    cvtsi2ss xmm0, r13d
    mulss   xmm0, [rsp+48]
    cvtsi2ss xmm1, r12d
    minss   xmm0, xmm1
    cvttss2si r14d, xmm0                # frame width
    divss   xmm0, [rsp+48]
    cvttss2si eax, xmm0                 # frame height
    mov     [rip+cv_fw], r14d
    mov     [rip+cv_fh], eax
    sub     r13d, eax
    sar     r13d, 1
    add     r13d, [rip+cvs_y0]
    mov     [rip+cv_fy], r13d
    sub     r12d, r14d
    sar     r12d, 1
    add     r12d, [rip+cvs_x0]
    mov     [rip+cv_fx], r12d
9:  lea     rsp, [rbp-32]
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    pop     rbp
    ret

# cv_leave - the loaded viewport out of Camera View: its orbit view starts
#   where the camera is, looking where it looks (the distance kept)
cv_leave:
    cmp     dword ptr [rip+cam_view], 0
    jne     1f
    ret
1:  push    rbp
    mov     rbp, rsp
    and     rsp, -16
    sub     rsp, 80
    mov     dword ptr [rip+cam_view], 0
    mov     dword ptr [rip+dirty], 1
    lea     rdi, [rsp]
    call    cv_mat
    test    rax, rax
    jz      9f
    mov     eax, [rsp+8]                # forward = -Z column
    xor     eax, 0x80000000
    mov     [rsp+48], eax
    mov     eax, [rsp+24]
    xor     eax, 0x80000000
    mov     [rsp+52], eax
    mov     eax, [rsp+40]
    xor     eax, 0x80000000
    mov     [rsp+56], eax
    lea     rdi, [rsp+48]
    call    cv_unit
    movss   xmm0, [rsp+48]              # yaw = atan2(-f.x, -f.z)
    xorps   xmm0, [rip+cv_sign]
    movss   [rsp+64], xmm0
    movss   xmm0, [rsp+56]
    xorps   xmm0, [rip+cv_sign]
    movss   [rsp+68], xmm0
    fld     dword ptr [rsp+64]
    fld     dword ptr [rsp+68]
    fpatan
    fstp    dword ptr [rip+cam_yaw]
    movss   xmm0, [rsp+48]              # pitch = atan2(-f.y, |f.xz|)
    mulss   xmm0, xmm0
    movss   xmm1, [rsp+56]
    mulss   xmm1, xmm1
    addss   xmm0, xmm1
    sqrtss  xmm0, xmm0
    movss   [rsp+68], xmm0
    movss   xmm0, [rsp+52]
    xorps   xmm0, [rip+cv_sign]
    movss   [rsp+64], xmm0
    fld     dword ptr [rsp+64]
    fld     dword ptr [rsp+68]
    fpatan
    fstp    dword ptr [rsp+64]
    movss   xmm0, [rsp+64]
    maxss   xmm0, [rip+cv_pmin]
    minss   xmm0, [rip+cv_pmax]
    movss   [rip+cam_pitch], xmm0
    xor     ecx, ecx                    # target = eye + forward x distance
    lea     rdx, [rip+cam_tx]
2:  imul    eax, ecx, 16
    movss   xmm0, [rsp+48+rcx*4]
    mulss   xmm0, [rip+cam_dist]
    addss   xmm0, [rsp+rax+12]
    movss   [rdx+rcx*4], xmm0
    inc     ecx
    cmp     ecx, 3
    jb      2b
9:  mov     rsp, rbp
    pop     rbp
    ret

# cv_draw - over the scene: the canvas outside the camera's frame dimmed,
#   the frame's edge
cv_draw:
    cmp     qword ptr [rip+cv_obj], 0
    jne     1f
    ret
1:  push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    mov     ebx, [rip+cv_fx]
    mov     r12d, [rip+cv_fy]
    mov     r13d, [rip+cv_fw]
    mov     r14d, [rip+cv_fh]
    mov     edi, [rip+cvs_x0]           # above
    mov     esi, [rip+cvs_y0]
    mov     edx, [rip+cvs_x1]
    sub     edx, edi
    mov     ecx, r12d
    sub     ecx, esi
    call    cv_dim
    mov     edi, [rip+cvs_x0]           # below
    lea     esi, [r12+r14]
    mov     edx, [rip+cvs_x1]
    sub     edx, edi
    mov     ecx, [rip+cvs_y1]
    sub     ecx, esi
    call    cv_dim
    mov     edi, [rip+cvs_x0]           # left
    mov     esi, r12d
    mov     edx, ebx
    sub     edx, edi
    mov     ecx, r14d
    call    cv_dim
    lea     edi, [rbx+r13]              # right
    mov     esi, r12d
    mov     edx, [rip+cvs_x1]
    sub     edx, edi
    mov     ecx, r14d
    call    cv_dim
    mov     r15d, 1                     # the edge
    mov     edi, ebx
    mov     esi, r12d
    mov     edx, r13d
    mov     ecx, r15d
    call    cv_edge
    mov     edi, ebx
    lea     esi, [r12+r14-1]
    mov     edx, r13d
    mov     ecx, r15d
    call    cv_edge
    mov     edi, ebx
    mov     esi, r12d
    mov     edx, r15d
    mov     ecx, r14d
    call    cv_edge
    lea     edi, [rbx+r13-1]
    mov     esi, r12d
    mov     edx, r15d
    mov     ecx, r14d
    call    cv_edge
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# cv_dim / cv_edge(edi=x, esi=y, edx=w, ecx=h) - nothing when empty
cv_dim:
    xor     r8d, r8d
    mov     r9d, 150
    jmp     1f
cv_edge:
    mov     r8d, 0xffffff
    mov     r9d, 110
1:  test    edx, edx
    jle     9f
    test    ecx, ecx
    jle     9f
    sub     rsp, 8
    call    fill_rect_a
    add     rsp, 8
9:  ret

# cv_label -> rdx (rdi, rsi kept) = the corner text in Camera View ("Camera  |  name"), or 0
cv_label:
    xor     edx, edx
    mov     rax, [rip+cv_obj]
    test    rax, rax
    jz      9f
    push    rdi                         # (the caller's text place kept)
    push    rsi
    lea     rdi, [rip+cv_buf]
    lea     rsi, [rip+s_cv_label]
1:  mov     cl, [rsi]
    test    cl, cl
    jz      2f
    mov     [rdi], cl
    inc     rsi
    inc     rdi
    jmp     1b
2:  lea     rsi, [rax+OB_NAME]
    mov     edx, 31
3:  mov     cl, [rsi]
    mov     [rdi], cl
    test    cl, cl
    jz      4f
    inc     rsi
    inc     rdi
    dec     edx
    jnz     3b
    mov     byte ptr [rdi], 0
4:  lea     rdx, [rip+cv_buf]
    pop     rsi
    pop     rdi
9:  ret

# view.camera [0|1] - the viewport under the pointer (or the last one used)
#   through the scene's camera, or back to its own view (none: switched)
OPERATOR op_view_camera, "view.camera", "Camera View", do_cam_view, check=chk_cam_view, key=82, flags=OPF_AI_SAFE|OPF_QUIET, doc="Look through the scene's camera (the one that renders) in the viewport, following it while the animation plays; orbit, pan or zoom to leave (Numpad 0): view.camera [0|1] (none: switched)"
do_cam_view:
    push    rbx
    mov     edi, [rip+ptr_x]            # the area under the pointer, if it is a
    mov     esi, [rip+ptr_y]            #  3D viewport
    call    area_hit
    mov     ebx, [rip+hit_area]
    test    ebx, ebx
    js      0f
    mov     edi, ebx
    call    area_editor
    cmp     eax, ED_VIEWPORT
    jne     0f
    mov     [rip+vp_area], ebx
0:
    mov     edi, [rip+vp_area]
    test    edi, edi
    js      9f
    call    cam_load
    mov     ebx, [rip+cam_view]         # none: the other way
    xor     ebx, 1
    mov     rsi, [rip+op_arg]
    test    rsi, rsi
    jz      1f
    call    im_next_word
    test    eax, eax
    jz      1f
    xor     ebx, ebx
    cmp     byte ptr [rip+im_word], '0'
    je      1f
    mov     ebx, 1
1:  test    ebx, ebx
    jnz     2f
    call    cv_leave
    jmp     8f
2:  call    lc_camera
    test    rax, rax
    jnz     3f
    lea     rdi, [rip+s_cv_none]
    call    log_line
    jmp     9f
3:  mov     dword ptr [rip+cam_view], 1
8:  mov     edi, [rip+vp_area]
    call    cam_store
    mov     dword ptr [rip+dirty], 1
9:  pop     rbx
    ret

chk_cam_view:
    sub     rsp, 8
    mov     edi, [rip+vp_area]
    xor     eax, eax
    test    edi, edi
    js      9f
    call    cam_load
    mov     eax, [rip+cam_view]
9:  add     rsp, 8
    ret

.section .note.GNU-stack,"",@progbits
