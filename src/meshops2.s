# =============================================================================
#  BeeModel - more modeling tools: loop cut, knife and bisect (plane cuts),
#  bridge edge loops, spin around the 3D cursor, bevel; the 3D cursor itself
#  and the interactive "edit tool" modes (loop cut and knife) the UI routes
#  pointer, wheel and keys to.
# =============================================================================
.intel_syntax noprefix
.include "const.inc"
.include "macros.inc"

# exports
.globl etool
.globl etool_motion
.globl etool_press
.globl etool_key
.globl etool_wheel
.globl etool_cancel
.globl etool_draw
.globl etool_setup
.globl world_px
.globl view_ray
.globl tmp3
.globl cursor_pos
.globl cursor_place
.globl cursor_draw
.globl build_bevel
.globl bv_angle
.globl bv_cos
.globl bv_pred
.globl eh_get

.equ KEY_R,     19
.equ KEY_B,     48
.equ KEY_K,     37
.equ KEY_SPACE, 57
.equ RING_MAX,  32768
.equ KN_MAX,    64                  # knife points
.equ ET_LOOP,   1
.equ ET_KNIFE,  2
.equ ET_MEASURE, 3                      # measure.s

.section .data
.align 4
cursor_pos:     .float 0, 0, 0
lc_cuts:        .long 1

.section .bss
.align 8
rA:             .skip RING_MAX*4    # ring edges: side A / side B vertices
rB:             .skip RING_MAX*4
rF:             .skip RING_MAX*4    # ring faces (between edge k and k+1)
fwdA:           .skip RING_MAX*4    # scratch for the backward walk
fwdB:           .skip RING_MAX*4
fwdF:           .skip RING_MAX*4
kn_pts:         .skip KN_MAX*8      # knife points (logical x, y)
pw:             .skip 8             # plane cut: world positions
pd:             .skip 8             # plane cut: signed distances
pc_n:           .skip 12            # plane (world): normal, offset
pc_off:         .skip 4
pc_s0:          .skip 8             # knife segment on screen (physical)
pc_s1:          .skip 8
etool:          .skip 4
r_m:            .skip 4             # ring edges
r_nf:           .skip 4             # ring faces
r_closed:       .skip 4
lc_valid:       .skip 4
lc_a:           .skip 4
lc_b:           .skip 4
kn_n:           .skip 4
pc_limit:       .skip 4             # 1: knife (segment range + visibility)
ptr_lx:         .skip 4             # pointer (logical) for previews
ptr_ly:         .skip 4
tmp3:           .skip 64

.section .rodata
.align 4
m2_one:         .float 1.0
m2_half:        .float 0.5
m2_zero:        .float 0.0
m2_eps:         .float 1.0e-5
m2_tiny:        .float 1.0e-12
m2_d2r:         .float 0.017453292
m2_2pi:         .float 6.2831853
m2_minsin:      .float 0.05
m2_clamp:       .float 0.45
m2_bevel0:      .float 0.1
m2_r10:         .float 10.0
m2_snap2:       .float 100.0        # knife vertex snap: 10 px
s_lc_hint:      .asciz "Loop Cut: hover an edge, wheel = number of cuts, click to cut, Esc cancels"
s_kn_hint:      .asciz "Knife: click points across faces, Enter cuts, Esc cancels"
s_no_ring:      .asciz "  loop cut: hover an edge between quads"
s_no_edge:      .asciz "  loop cut: pass the edge as two vertex indices: mesh.loopcut \"a b [cuts]\""
s_bridge_need:  .asciz "  bridge: select two closed edge loops (boundaries) with the same vertex count"
s_spin_need:    .asciz "  spin: select edges (a profile) to spin around the 3D cursor"
s_bevel_need:   .asciz "  bevel: select edges between two faces"
s_cut_none:     .asciz "  the cut crossed no faces"
s_lbl_bevel:    .asciz "Bevel"
s_lbl_loop:     .asciz "Loop Cut"
s_lbl_knife:    .asciz "Knife"
.align 8

OPERATOR op_m_loopcut, "mesh.loopcut", "Loop Cut", do_loopcut, key=KEY_R|KM_CTRL, flags=OPF_AI_SAFE|OPF_EDIT, doc="Cut a ring of quads: Ctrl+R then click; scripts: mesh.loopcut \"a b [cuts]\"", params=p_loopcut
OPERATOR op_m_knife, "mesh.knife", "Knife", do_knife, key=KEY_K, flags=OPF_EDIT|OPF_QUIET, doc="Draw a cut across the visible faces: click points, Enter cuts"
OPERATOR op_m_bisect, "mesh.bisect", "Bisect", do_bisect, flags=OPF_AI_SAFE|OPF_UNDO|OPF_EDIT, doc="Cut the mesh with a plane: mesh.bisect \"px py pz nx ny nz\" (world; default: horizontal through the 3D cursor)", form=form_bisect
OPERATOR op_m_bevel, "mesh.bevel", "Bevel", do_bevel, key=KEY_B|KM_CTRL, flags=OPF_AI_SAFE|OPF_UNDO|OPF_EDIT, doc="Bevel the selected edges: drag the width, wheel = segments; scripts: mesh.bevel \"width [segments]\"", params=p_bevel
OPERATOR op_m_bridge, "mesh.bridge", "Bridge Edge Loops", do_bridge, flags=OPF_AI_SAFE|OPF_UNDO|OPF_EDIT, doc="Join two selected boundary loops with a band of quads"
OPERATOR op_m_spin, "mesh.spin", "Spin", do_spin, flags=OPF_AI_SAFE|OPF_UNDO|OPF_EDIT, doc="Sweep the selected edges around the 3D cursor: mesh.spin \"[steps] [degrees] [x|y|z]\" (12 360 y)", params=p_spin, form=form_spin
OPERATOR op_cursor_reset, "view.cursor_reset", "Reset 3D Cursor", do_cursor_reset, flags=OPF_AI_SAFE, doc="Put the 3D cursor back at the origin (Shift+right click places it)"

.text

# =============================================================================
#  3D cursor
# =============================================================================
do_cursor_reset:
    xorps   xmm0, xmm0
    movss   [rip+cursor_pos], xmm0
    movss   [rip+cursor_pos+4], xmm0
    movss   [rip+cursor_pos+8], xmm0
    mov     dword ptr [rip+dirty], 1
    ret

# view_ray(edi=x, esi=y logical, rdi.. ) -> tmp3[0..2] = world direction of
#   the pointer ray (not normalized; forward component 1)
view_ray:
    sub     rsp, 8
    call    to_px
    cvtsi2ss xmm0, eax
    mov     edi, esi
    call    to_px
    cvtsi2ss xmm1, eax
    subss   xmm0, [rip+vp_cx]           # xc = (px - cx) / f
    divss   xmm0, [rip+vp_focal]
    movss   xmm2, [rip+vp_cy]           # yc = (cy - py) / f
    subss   xmm2, xmm1
    divss   xmm2, [rip+vp_focal]
    xor     ecx, ecx
    lea     r8, [rip+right]
    lea     r9, [rip+up]
    lea     r10, [rip+fwd]
1:  movss   xmm3, [r8+rcx*4]
    mulss   xmm3, xmm0
    movss   xmm4, [r9+rcx*4]
    mulss   xmm4, xmm2
    addss   xmm3, xmm4
    addss   xmm3, [r10+rcx*4]
    lea     rax, [rip+tmp3]
    movss   [rax+rcx*4], xmm3
    inc     ecx
    cmp     ecx, 3
    jb      1b
    add     rsp, 8
    ret

# cursor_place(edi=x, esi=y logical) - on the surface under the pointer
#   (depth buffer), else on the ground plane. Needs cam_setup + clip.
cursor_place:
    push    rbx
    push    r12
    sub     rsp, 24
    mov     ebx, edi
    mov     r12d, esi
    call    view_ray
    mov     edi, ebx                    # surface depth at the pixel?
    call    to_px
    mov     ecx, eax
    mov     edi, r12d
    call    to_px
    mov     edx, eax
    sub     ecx, [rip+rs_x0]
    js      2f
    cmp     ecx, [rip+rs_w]
    jge     2f
    sub     edx, [rip+rs_y0]
    js      2f
    cmp     edx, [rip+rs_h]
    jge     2f
    cmp     dword ptr [rip+vp_shading], 1
    je      2f
    imul    edx, [rip+rs_w]
    add     edx, ecx
    mov     rax, [rip+rs_depth]
    movss   xmm0, [rax+rdx*4]           # 1/z
    xorps   xmm1, xmm1
    comiss  xmm0, xmm1
    jbe     2f
    movss   xmm1, [rip+m2_one]
    divss   xmm1, xmm0                  # z: point = eye + ray * z
    jmp     3f
2:  movss   xmm0, [rip+tmp3+4]          # ground: eye.y + t ray.y = 0
    xorps   xmm2, xmm2
    comiss  xmm0, xmm2
    jae     9f                          # looking up: keep the cursor
    movss   xmm1, [rip+eye+4]
    divss   xmm1, xmm0
    xorps   xmm2, xmm2
    subss   xmm2, xmm1
    movss   xmm1, xmm2
3:  xor     ecx, ecx
    lea     r8, [rip+tmp3]
    lea     r9, [rip+eye]
    lea     r10, [rip+cursor_pos]
4:  movss   xmm0, [r8+rcx*4]
    mulss   xmm0, xmm1
    addss   xmm0, [r9+rcx*4]
    movss   [r10+rcx*4], xmm0
    inc     ecx
    cmp     ecx, 3
    jb      4b
    mov     dword ptr [rip+dirty], 1
9:  add     rsp, 24
    pop     r12
    pop     rbx
    ret

# world_px(rdi=world float[3]) -> xmm0, xmm1 = physical px, xmm2 = 1/z
#   (xmm2 = 0 behind the camera)
world_px:
    movss   xmm3, [rdi]
    subss   xmm3, [rip+eye]
    movss   xmm4, [rdi+4]
    subss   xmm4, [rip+eye+4]
    movss   xmm5, [rdi+8]
    subss   xmm5, [rip+eye+8]
    movss   xmm2, xmm3                  # z = d . fwd
    mulss   xmm2, [rip+fwd]
    movss   xmm6, xmm4
    mulss   xmm6, [rip+fwd+4]
    addss   xmm2, xmm6
    movss   xmm6, xmm5
    mulss   xmm6, [rip+fwd+8]
    addss   xmm2, xmm6
    comiss  xmm2, [rip+f_near]
    jae     1f
    xorps   xmm0, xmm0
    xorps   xmm1, xmm1
    xorps   xmm2, xmm2
    ret
1:  movss   xmm6, [rip+m2_one]
    divss   xmm6, xmm2
    movss   xmm2, xmm6                  # 1/z
    mulss   xmm6, [rip+vp_focal]
    movss   xmm0, xmm3                  # x = d . right
    mulss   xmm0, [rip+right]
    movss   xmm7, xmm4
    mulss   xmm7, [rip+right+4]
    addss   xmm0, xmm7
    movss   xmm7, xmm5
    mulss   xmm7, [rip+right+8]
    addss   xmm0, xmm7
    mulss   xmm0, xmm6
    addss   xmm0, [rip+vp_cx]
    movss   xmm1, xmm3                  # y = d . up
    mulss   xmm1, [rip+up]
    movss   xmm7, xmm4
    mulss   xmm7, [rip+up+4]
    addss   xmm1, xmm7
    movss   xmm7, xmm5
    mulss   xmm7, [rip+up+8]
    addss   xmm1, xmm7
    mulss   xmm1, xmm6
    movss   xmm7, [rip+vp_cy]
    subss   xmm7, xmm1
    movss   xmm1, xmm7
    ret

# cursor_draw - red / white ring with a cross (in the viewport being drawn)
cursor_draw:
    push    rbx
    push    r12
    push    r13
    push    r14
    sub     rsp, 24
    lea     rdi, [rip+cursor_pos]
    call    world_px
    xorps   xmm3, xmm3
    comiss  xmm2, xmm3
    jbe     9f
    cvttss2si r12d, xmm0
    cvttss2si r13d, xmm1
    mov     edi, 10
    call    to_px
    mov     r14d, eax                   # radius
    xor     ebx, ebx                    # 16 segments, alternating colours
1:  cmp     ebx, 16
    jae     2f
    cvtsi2ss xmm0, ebx
    mulss   xmm0, [rip+m2_2pi]
    mov     eax, 16
    cvtsi2ss xmm1, eax
    divss   xmm0, xmm1
    call    sincos
    cvtsi2ss xmm2, r14d
    mulss   xmm0, xmm2
    mulss   xmm1, xmm2
    cvttss2si eax, xmm1
    add     eax, r12d
    mov     [rsp], eax
    cvttss2si eax, xmm0
    add     eax, r13d
    mov     [rsp+4], eax
    lea     eax, [rbx+1]
    cvtsi2ss xmm0, eax
    mulss   xmm0, [rip+m2_2pi]
    mov     eax, 16
    cvtsi2ss xmm1, eax
    divss   xmm0, xmm1
    call    sincos
    cvtsi2ss xmm2, r14d
    mulss   xmm0, xmm2
    mulss   xmm1, xmm2
    cvttss2si edx, xmm1
    add     edx, r12d
    cvttss2si ecx, xmm0
    add     ecx, r13d
    mov     edi, [rsp]
    mov     esi, [rsp+4]
    mov     r8d, 0xe04040
    test    ebx, 1
    jz      11f
    mov     r8d, 0xffffff
11: call    draw_line_px
    inc     ebx
    jmp     1b
2:  lea     edi, [r12+r14+4]            # cross
    sub     edi, r14d
    sub     edi, r14d
    sub     edi, 8
    mov     esi, r13d
    lea     edx, [r12+r14+4]
    mov     ecx, r13d
    mov     r8d, 0x101010
    call    draw_line_px
    mov     edi, r12d
    mov     esi, r13d
    sub     esi, r14d
    sub     esi, 4
    mov     edx, r12d
    lea     ecx, [r13+r14+4]
    mov     r8d, 0x101010
    call    draw_line_px
9:  add     rsp, 24
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# =============================================================================
#  Edit tools (loop cut, knife): the UI forwards pointer, wheel and keys
# =============================================================================
etool_setup:                            # camera + clip of the last viewport
    sub     rsp, 8
    mov     edi, [rip+vp_area]
    test    edi, edi
    js      1f
    mov     [rip+drag_node], edi
    call    vp_setup_drag
1:  add     rsp, 8
    ret

etool_motion:                           # edi, esi = logical pointer
    push    rbx
    mov     [rip+ptr_lx], edi
    mov     [rip+ptr_ly], esi
    mov     dword ptr [rip+dirty], 1
    cmp     dword ptr [rip+etool], ET_LOOP
    jne     9f
    call    etool_setup                 # loop cut: the ring under the pointer
    mov     edi, [rip+ptr_lx]
    mov     esi, [rip+ptr_ly]
    call    edit_pick_edge
    mov     dword ptr [rip+lc_valid], 0
    test    eax, eax
    js      8f
    mov     ebx, eax
    mov     [rip+lc_a], eax
    mov     [rip+lc_b], edx
    push    rdx
    call    edit_get
    pop     rdx
    test    rax, rax
    jz      8f
    push    rbx
    mov     rbx, [rax+OB_MESH]
    mov     edi, [rsp]
    mov     esi, edx
    call    ring_find
    pop     rbx
    test    eax, eax
    jz      8f
    mov     dword ptr [rip+lc_valid], 1
8:  call    reset_clip
9:  pop     rbx
    ret

etool_wheel:                            # edi = -1 / +1
    cmp     dword ptr [rip+etool], ET_LOOP
    jne     9f
    mov     eax, [rip+lc_cuts]
    sub     eax, edi
    cmp     eax, 1
    jge     1f
    mov     eax, 1
1:  cmp     eax, 32
    jle     2f
    mov     eax, 32
2:  mov     [rip+lc_cuts], eax
    mov     dword ptr [rip+dirty], 1
9:  ret

etool_cancel:
    mov     dword ptr [rip+etool], 0
    call    measure_reset
    mov     dword ptr [rip+kn_n], 0
    mov     dword ptr [rip+lc_valid], 0
    mov     dword ptr [rip+dirty], 1
    ret

# etool_press(edi=modifiers) - a left click in the viewport
etool_press:
    cmp     dword ptr [rip+etool], ET_MEASURE
    je      measure_press
    push    rbx
    cmp     dword ptr [rip+etool], ET_LOOP
    jne     2f
    cmp     dword ptr [rip+lc_valid], 0  # cut the previewed ring
    je      9f
    lea     rdi, [rip+s_lbl_loop]
    call    undo_push
    call    edit_get
    test    rax, rax
    jz      1f
    mov     rbx, [rax+OB_MESH]
    mov     edi, [rip+lc_cuts]
    call    loopcut_build
    call    lc_report
1:  call    etool_cancel
    jmp     9f
2:  cmp     dword ptr [rip+etool], ET_KNIFE
    jne     9f
    mov     eax, [rip+kn_n]             # knife: add a point (snapped to vertices)
    cmp     eax, KN_MAX
    jae     9f
    lea     rcx, [rip+kn_pts]
    mov     edx, [rip+ptr_x]
    mov     [rcx+rax*8], edx
    mov     edx, [rip+ptr_y]
    mov     [rcx+rax*8+4], edx
    inc     dword ptr [rip+kn_n]
    mov     dword ptr [rip+dirty], 1
9:  pop     rbx
    ret

# etool_key(edi=evdev) -> eax = 1 if the tool used it
etool_key:
    cmp     edi, KEY_ESC
    je      1f
    cmp     dword ptr [rip+etool], ET_KNIFE
    jne     8f
    cmp     edi, KEY_ENTER
    je      2f
    cmp     edi, KEY_SPACE
    je      2f
    cmp     edi, 96                     # keypad Enter
    je      2f
8:  xor     eax, eax
    ret
1:  call    etool_cancel
    mov     eax, 1
    ret
2:  sub     rsp, 8
    call    knife_apply
    call    etool_cancel
    add     rsp, 8
    mov     eax, 1
    ret

# etool_draw - previews (in the viewport being drawn)
etool_draw:
    cmp     dword ptr [rip+etool], ET_MEASURE
    je      measure_draw
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    sub     rsp, 48
    mov     eax, [rip+etool]
    test    eax, eax
    jz      .Letd_out
    mov     edi, [rip+cvs_x0]           # hint line
    add     edi, 10
    mov     esi, [rip+cvs_y0]
    add     esi, 62
    lea     rdx, [rip+s_lc_hint]
    cmp     dword ptr [rip+etool], ET_LOOP
    je      1f
    lea     rdx, [rip+s_kn_hint]
1:  mov     ecx, COL_ACTIVE
    call    draw_text
    cmp     dword ptr [rip+etool], ET_KNIFE
    je      .Letd_knife
    cmp     dword ptr [rip+lc_valid], 0
    je      .Letd_out
    call    edit_get
    test    rax, rax
    jz      .Letd_out
    mov     rbx, [rax+OB_MESH]
    call    ex_setup
    xor     r12d, r12d                  # ring face k: lines at each fraction
2:  cmp     r12d, [rip+r_nf]
    jae     .Letd_out
    mov     r13d, 1
3:  cmp     r13d, [rip+lc_cuts]
    ja      4f
    mov     edi, r12d
    mov     esi, r13d
    lea     rdx, [rsp]
    call    ring_point                  # edge k at cut j -> world
    lea     edi, [r12+1]
    mov     esi, r13d
    lea     rdx, [rsp+16]
    call    ring_point
    mov     rax, [rsp]
    mov     [rip+lp0], rax
    mov     eax, [rsp+8]
    mov     [rip+lp0+8], eax
    mov     rax, [rsp+16]
    mov     [rip+lp1], rax
    mov     eax, [rsp+24]
    mov     [rip+lp1+8], eax
    mov     edx, 0xf5e020
    call    line3d
    inc     r13d
    jmp     3b
4:  inc     r12d
    jmp     2b
.Letd_knife:
    xor     r12d, r12d                  # the polyline, then to the pointer
5:  mov     eax, [rip+kn_n]
    test    eax, eax
    jz      .Letd_out
    lea     rcx, [rip+kn_pts]
    lea     edx, [r12+1]
    cmp     edx, eax
    jae     6f
    mov     edi, [rcx+r12*8]
    mov     esi, [rcx+r12*8+4]
    mov     edx, [rcx+r12*8+8]
    mov     ecx, [rcx+r12*8+12]
    mov     r8d, 0xf5e020
    call    draw_line
    inc     r12d
    jmp     5b
6:  lea     rcx, [rip+kn_pts]
    mov     edi, [rcx+r12*8]
    mov     esi, [rcx+r12*8+4]
    mov     edx, [rip+ptr_x]
    mov     ecx, [rip+ptr_y]
    mov     r8d, 0x8a8030
    call    draw_line
.Letd_out:
    add     rsp, 48
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# ring_point(edi=ring edge k, esi=cut j, rdx=out world) - point j/(n+1) on it
ring_point:
    push    rbx
    push    r12
    sub     rsp, 24
    mov     r12, rdx
    mov     ecx, [rip+r_m]              # closed rings wrap
    cmp     edi, ecx
    jb      1f
    xor     edi, edi
1:  lea     rax, [rip+rA]
    mov     r8d, [rax+rdi*4]
    lea     rax, [rip+rB]
    mov     r9d, [rax+rdi*4]
    cvtsi2ss xmm6, esi
    mov     eax, [rip+lc_cuts]
    inc     eax
    cvtsi2ss xmm7, eax
    divss   xmm6, xmm7                  # t
    mov     rax, [rbx+ME_POS]
    lea     r8, [r8+r8*2]
    lea     r9, [r9+r9*2]
    xor     ecx, ecx
2:  movss   xmm0, [rax+r9*4]
    subss   xmm0, [rax+r8*4]
    mulss   xmm0, xmm6
    addss   xmm0, [rax+r8*4]
    movss   [rsp+rcx*4], xmm0
    inc     r8
    inc     r9
    inc     ecx
    cmp     ecx, 3
    jb      2b
    lea     rsi, [rsp]
    mov     rdx, r12
    call    ex_to_world
    add     rsp, 24
    pop     r12
    pop     rbx
    ret

# =============================================================================
#  Loop cut
# =============================================================================
do_loopcut:
    push    rbx
    push    r12
    sub     rsp, 32
    call    interactive
    test    eax, eax
    jz      1f
    call    need_edit                   # interactive: the hover tool
    test    rax, rax
    jz      9f
    mov     dword ptr [rip+etool], ET_LOOP
    mov     dword ptr [rip+lc_valid], 0
    mov     dword ptr [rip+lc_cuts], 1
    mov     dword ptr [rip+dirty], 1
    jmp     9f
1:  call    need_edit                   # scripts: "a b [cuts]"
    test    rax, rax
    jz      9f
    mov     rbx, rax
    lea     rdi, [rsp]
    mov     esi, 3
    call    arg_nums
    cmp     eax, 2
    jb      .Llc_args
    mov     ecx, 1
    cmp     eax, 3
    jb      2f
    cvttss2si ecx, [rsp+8]
2:  mov     [rip+lc_cuts], ecx
    cvttss2si edi, [rsp]
    cvttss2si esi, [rsp+4]
    mov     eax, [rbx+ME_NVERTS]
    cmp     edi, eax
    jae     .Llc_args
    cmp     esi, eax
    jae     .Llc_args
    call    ring_find
    test    eax, eax
    jz      .Llc_ring
    cvttss2si eax, [rsp]
    mov     [rip+lc_a], eax
    cvttss2si eax, [rsp+4]
    mov     [rip+lc_b], eax
    lea     rdi, [rip+s_lbl_loop]
    call    undo_push
    mov     edi, [rip+lc_cuts]
    call    loopcut_build
    call    lc_report
    jmp     9f
.Llc_args:
    lea     rdi, [rip+s_no_edge]
    call    log_line
    jmp     9f
.Llc_ring:
    lea     rdi, [rip+s_no_ring]
    call    log_line
9:  add     rsp, 32
    pop     r12
    pop     rbx
    ret

# lc_report - the redo panel: edge a b and the cuts
lc_report:
    sub     rsp, 24
    cvtsi2ss xmm0, dword ptr [rip+lc_a]
    movss   [rsp], xmm0
    cvtsi2ss xmm0, dword ptr [rip+lc_b]
    movss   [rsp+4], xmm0
    cvtsi2ss xmm0, dword ptr [rip+lc_cuts]
    movss   [rsp+8], xmm0
    lea     rdi, [rip+op_m_loopcut]
    lea     rsi, [rsp]
    mov     edx, 3
    call    lastop_set
    add     rsp, 24
    ret

# arg_nums(rdi=out float[], esi=max) -> eax = count of numbers in op_arg
arg_nums:
    push    rbx
    push    r12
    push    r13
    mov     rbx, rdi
    mov     r12d, esi
    xor     r13d, r13d
    mov     rsi, [rip+op_arg]
    test    rsi, rsi
    jz      9f
1:  cmp     r13d, r12d
    jae     9f
2:  mov     al, [rsi]                   # skip separators and letters
    test    al, al
    jz      9f
    cmp     al, '-'
    je      3f
    cmp     al, '.'
    je      3f
    sub     al, '0'
    cmp     al, 9
    jbe     3f
    inc     rsi
    jmp     2b
3:  mov     rdx, rsi
    add     rdx, 64
    push    rsi
    call    parse_float
    pop     rcx
    cmp     rsi, rcx
    jne     4f
    inc     rsi                         # no progress: skip a character
    jmp     1b
4:  movss   [rbx+r13*4], xmm0
    inc     r13d
    jmp     1b
9:  mov     eax, r13d
    pop     r13
    pop     r12
    pop     rbx
    ret

# ring_find(rbx=mesh, edi=a, esi=b) -> eax = 1 if (a, b) lies in a ring of
#   quads; rA / rB = ring edges with consistent sides, rF = faces between
#   them, r_m edges, r_nf faces, r_closed
ring_find:
    push    r12
    push    r13
    push    r14
    push    r15
    push    rbp
    sub     rsp, 32
    mov     [rsp], edi
    mov     [rsp+4], esi
    push    rdi
    push    rsi
    call    edge_faces
    pop     rsi
    pop     rdi
    test    eax, eax
    jz      .Lrf_no
    mov     edi, [rsp]
    mov     esi, [rsp+4]
    call    ef_find
    test    eax, eax
    js      .Lrf_no
    mov     ebp, eax                    # slot of the start edge
    mov     dword ptr [rip+r_closed], 0
    # forward from f1: rA/rB[0] = start
    lea     rax, [rip+rA]
    mov     ecx, [rsp]
    mov     [rax], ecx
    lea     rax, [rip+rB]
    mov     ecx, [rsp+4]
    mov     [rax], ecx
    mov     rcx, [rip+ef_f1]
    mov     edi, [rcx+rbp*4]
    lea     r12, [rip+rA]
    lea     r13, [rip+rB]
    lea     r14, [rip+rF]
    call    ring_walk                   # eax = edges added after index 0
    mov     r15d, eax                   # forward count
    cmp     dword ptr [rip+r_closed], 0
    jne     .Lrf_done
    # backward from f2 into the scratch arrays, then prepend reversed
    mov     rcx, [rip+ef_f2]
    mov     edi, [rcx+rbp*4]
    test    edi, edi
    js      .Lrf_done
    lea     rax, [rip+fwdA]
    mov     ecx, [rsp]
    mov     [rax], ecx
    lea     rax, [rip+fwdB]
    mov     ecx, [rsp+4]
    mov     [rax], ecx
    push    r15
    lea     r12, [rip+fwdA]
    lea     r13, [rip+fwdB]
    lea     r14, [rip+fwdF]
    call    ring_walk
    pop     r15
    mov     r12d, eax                   # backward count
    test    r12d, r12d
    jz      .Lrf_done
    mov     eax, r12d                   # make room: shift forward data
    add     eax, r15d
    cmp     eax, RING_MAX-2
    jae     .Lrf_no
    lea     r8, [rip+rA]
    lea     r9, [rip+rB]
    lea     r10, [rip+rF]
    mov     ecx, r15d                   # edges 0..fw -> +bw
1:  mov     eax, [r8+rcx*4]
    lea     edx, [rcx+r12]
    mov     [r8+rdx*4], eax
    mov     eax, [r9+rcx*4]
    mov     [r9+rdx*4], eax
    dec     ecx
    jns     1b
    mov     ecx, r15d                   # faces 0..fw-1 -> +bw
    dec     ecx
    js      2f
11: mov     eax, [r10+rcx*4]
    lea     edx, [rcx+r12]
    mov     [r10+rdx*4], eax
    dec     ecx
    jns     11b
2:  lea     r11, [rip+fwdA]             # backward edge i (1..bw) -> index bw - i
    lea     rsi, [rip+fwdB]
    lea     rdi, [rip+fwdF]
    mov     ecx, 1
3:  cmp     ecx, r12d
    ja      4f
    mov     edx, r12d
    sub     edx, ecx
    mov     eax, [r11+rcx*4]
    mov     [r8+rdx*4], eax
    mov     eax, [rsi+rcx*4]
    mov     [r9+rdx*4], eax
    mov     eax, [rdi+rcx*4-4]          # face between bw edges i-1 and i
    mov     [r10+rdx*4], eax
    inc     ecx
    jmp     3b
4:  add     r15d, r12d
.Lrf_done:
    lea     eax, [r15+1]                # edges
    mov     [rip+r_m], eax
    mov     [rip+r_nf], r15d            # faces (+1 if closed: set below)
    cmp     dword ptr [rip+r_closed], 0
    je      5f
    mov     eax, [rip+r_m]              # closed: last edge == first (dropped)
    dec     eax
    mov     [rip+r_m], eax
    mov     [rip+r_nf], eax
5:  xor     eax, eax
    cmp     dword ptr [rip+r_nf], 0
    setne   al
    jmp     9f
.Lrf_no:
    xor     eax, eax
9:  add     rsp, 32
    pop     rbp
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    ret

# ring_walk(edi=first face, r12/r13/r14 = A / B / F arrays with [0] set)
#   -> eax = edges added. Stops at a non-quad, a boundary or back at the
#   start (r_closed = 1, the start edge is then repeated at the end).
ring_walk:
    push    rbx
    push    rbp
    push    r15
    sub     rsp, 16
    xor     ebp, ebp                    # count
    mov     r15d, edi                   # face
.Lrw_step:
    test    r15d, r15d
    js      .Lrw_out
    cmp     ebp, RING_MAX/2-4
    jae     .Lrw_out
    mov     rsi, [rbx+ME_POFF]
    mov     ecx, [rsi+r15*4]
    mov     edx, [rsi+r15*4+4]
    sub     edx, ecx
    cmp     edx, 4
    jne     .Lrw_out
    mov     rsi, [rbx+ME_LOOPS]
    lea     rsi, [rsi+rcx*4]            # q0..q3
    mov     r8d, [r12+rbp*4]            # current A
    mov     r9d, [r13+rbp*4]            # current B
    xor     ecx, ecx                    # find i with {q_i, q_i+1} = {A, B}
1:  cmp     ecx, 4
    jae     .Lrw_out
    mov     eax, [rsi+rcx*4]
    lea     edx, [rcx+1]
    and     edx, 3
    mov     edx, [rsi+rdx*4]
    cmp     eax, r8d
    jne     2f
    cmp     edx, r9d
    je      3f                          # q_i = A, q_i+1 = B
2:  cmp     eax, r9d
    jne     21f
    cmp     edx, r8d
    je      4f                          # q_i = B, q_i+1 = A
21: inc     ecx
    jmp     1b
3:  lea     edx, [rcx+3]                # A' = q_i+3, B' = q_i+2
    and     edx, 3
    mov     r10d, [rsi+rdx*4]
    lea     edx, [rcx+2]
    and     edx, 3
    mov     r11d, [rsi+rdx*4]
    jmp     5f
4:  lea     edx, [rcx+2]                # A' = q_i+2, B' = q_i+3
    and     edx, 3
    mov     r10d, [rsi+rdx*4]
    lea     edx, [rcx+3]
    and     edx, 3
    mov     r11d, [rsi+rdx*4]
5:  mov     [r14+rbp*4], r15d           # face between edge count and count+1
    inc     ebp
    mov     [r12+rbp*4], r10d
    mov     [r13+rbp*4], r11d
    lea     rax, [rip+rA]               # back at the start? (closed)
    cmp     r10d, [rax]
    jne     6f
    lea     rax, [rip+rB]
    cmp     r11d, [rax]
    jne     6f
    mov     dword ptr [rip+r_closed], 1
    jmp     .Lrw_out
6:  mov     [rsp], r15d                 # the next face across (A', B')
    mov     edi, r10d
    mov     esi, r11d
    call    ef_find
    test    eax, eax
    js      .Lrw_stop
    mov     rcx, [rip+ef_cnt]
    cmp     dword ptr [rcx+rax*4], 2
    jne     .Lrw_stop
    mov     rcx, [rip+ef_f1]
    mov     edx, [rcx+rax*4]
    cmp     edx, [rsp]
    jne     7f
    mov     rcx, [rip+ef_f2]
    mov     edx, [rcx+rax*4]
7:  mov     r15d, edx
    jmp     .Lrw_step
.Lrw_stop:
    mov     r15d, -1
    jmp     .Lrw_step
.Lrw_out:
    mov     eax, ebp
    add     rsp, 16
    pop     r15
    pop     rbp
    pop     rbx
    ret

# loopcut_build(edi=cuts) - rbx = mesh, the ring in rA / rB / rF
loopcut_build:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    push    rbp
    sub     rsp, 72
    mov     [rsp+64], edi               # n cuts
    mov     r12d, edi
    mov     eax, [rip+r_m]
    imul    eax, r12d
    mov     [rsp+60], eax               # new vertices
    mov     edi, [rbx+ME_NVERTS]
    add     edi, eax
    add     edi, 8
    mov     esi, [rbx+ME_NLOOPS]
    mov     eax, [rip+r_nf]
    lea     ecx, [r12+1]
    imul    eax, ecx
    shl     eax, 2
    add     esi, eax
    mov     eax, [rsp+60]
    lea     esi, [rsi+rax*2+8]
    mov     edx, [rbx+ME_NPOLYS]
    mov     eax, [rip+r_nf]
    imul    eax, r12d
    lea     edx, [rdx+rax+8]
    call    mesh_new
    test    rax, rax
    jz      9f
    mov     r14, rax
    mov     rdi, r14
    mov     rsi, rbx
    call    copy_verts
    mov     rdi, r14
    call    clear_vsel
    mov     ebp, [rbx+ME_NVERTS]        # cut vertex (k, j) = base + k n + j - 1
    mov     [rsp+56], ebp
    xor     r15d, r15d                  # k
1:  cmp     r15d, [rip+r_m]
    jae     2f
    mov     r13d, 1
11: cmp     r13d, r12d
    ja      12f
    lea     rax, [rip+rA]
    mov     r8d, [rax+r15*4]
    lea     rax, [rip+rB]
    mov     r9d, [rax+r15*4]
    cvtsi2ss xmm6, r13d
    lea     eax, [r12+1]
    cvtsi2ss xmm7, eax
    divss   xmm6, xmm7
    mov     rax, [rbx+ME_POS]
    lea     r8, [r8+r8*2]
    lea     r9, [r9+r9*2]
    xor     ecx, ecx
13: movss   xmm0, [rax+r9*4]
    subss   xmm0, [rax+r8*4]
    mulss   xmm0, xmm6
    addss   xmm0, [rax+r8*4]
    movss   [rsp+rcx*4], xmm0
    inc     r8
    inc     r9
    inc     ecx
    cmp     ecx, 3
    jb      13b
    mov     rdi, r14
    lea     rsi, [rsp]
    mov     edx, 1
    call    add_vert_at
    inc     r13d
    jmp     11b
12: inc     r15d
    jmp     1b
2:  # which faces are ring faces (k), which edges are ring edges
    mov     edi, [rbx+ME_NPOLYS]
    mov     esi, -1
    call    fa_fill
    test    rax, rax
    jz      .Llb_fail
    mov     [rsp+40], rax               # face -> ring index
    xor     ecx, ecx
21: cmp     ecx, [rip+r_nf]
    jae     22f
    lea     rax, [rip+rF]
    mov     edx, [rax+rcx*4]
    mov     rax, [rsp+40]
    mov     [rax+rdx*4], ecx
    inc     ecx
    jmp     21b
22: mov     edi, [rip+r_m]
    add     edi, 4
    call    eh_new
    test    rax, rax
    jz      .Llb_fail
    mov     [rsp+48], rax               # ring edge -> k
    xor     r15d, r15d
23: cmp     r15d, [rip+r_m]
    jae     3f
    lea     rax, [rip+rA]
    mov     edi, [rax+r15*4]
    lea     rax, [rip+rB]
    mov     esi, [rax+r15*4]
    call    ukey
    mov     rsi, rax
    mov     rdi, [rsp+48]
    call    eh_slot
    mov     [rax], r15d
    inc     r15d
    jmp     23b
3:  xor     r15d, r15d                  # polygons
.Llb_poly:
    cmp     r15d, [rbx+ME_NPOLYS]
    jae     .Llb_commit
    mov     rax, [rsp+40]
    mov     eax, [rax+r15*4]
    test    eax, eax
    js      .Llb_other
    # ring face k: strips between edge k and k+1
    mov     [rsp+32], eax               # k
    lea     ecx, [rax+1]                # k+1 (wraps when closed)
    cmp     ecx, [rip+r_m]
    jb      31f
    xor     ecx, ecx
31: mov     [rsp+36], ecx
    lea     rdx, [rip+rA]               # does the face run A_k -> B_k?
    mov     edi, [rdx+rax*4]
    lea     rdx, [rip+rB]
    mov     esi, [rdx+rax*4]
    mov     edx, r15d
    call    face_runs
    mov     [rsp+28], eax
    xor     r13d, r13d                  # j = 0 .. n
32: cmp     r13d, r12d
    ja      .Llb_next
    mov     edi, [rsp+32]
    mov     esi, r13d
    call    row_vert                    # P(k, j)
    mov     [rsp], eax
    mov     edi, [rsp+32]
    lea     esi, [r13+1]
    call    row_vert
    mov     [rsp+4], eax
    mov     edi, [rsp+36]
    lea     esi, [r13+1]
    call    row_vert
    mov     [rsp+8], eax
    mov     edi, [rsp+36]
    mov     esi, r13d
    call    row_vert
    mov     [rsp+12], eax
    cmp     dword ptr [rsp+28], 0
    jne     33f
    mov     eax, [rsp]                  # B -> A face: reverse the quad
    mov     ecx, [rsp+4]
    mov     [rsp], ecx
    mov     [rsp+4], eax
    mov     eax, [rsp+8]
    mov     ecx, [rsp+12]
    mov     [rsp+8], ecx
    mov     [rsp+12], eax
33: mov     rdi, r14
    lea     rsi, [rsp]
    mov     edx, 4
    call    mesh_add_poly
    inc     r13d
    jmp     32b
.Llb_other:                             # others: ring edges get the cut vertices
    mov     rsi, [rbx+ME_POFF]
    mov     ecx, [rsi+r15*4]
    mov     edx, [rsi+r15*4+4]
    mov     [rsp+16], ecx
    mov     [rsp+20], edx
    xor     ebp, ebp                    # output count (scr)
4:  cmp     ecx, [rsp+20]
    jae     45f
    mov     [rsp+24], ecx
    mov     rsi, [rbx+ME_LOOPS]
    mov     edi, [rsi+rcx*4]
    lea     rax, [rip+scr]
    mov     [rax+rbp*4], edi
    inc     ebp
    lea     eax, [rcx+1]
    cmp     eax, [rsp+20]
    jb      41f
    mov     eax, [rsp+16]
41: mov     esi, [rsi+rax*4]
    mov     [rsp+8], edi
    mov     [rsp+12], esi
    call    ukey
    lea     rsi, [rax+1]                # look up without inserting
    mov     rdi, [rsp+48]
    call    eh_get
    test    eax, eax
    js      44f
    mov     [rsp+32], eax               # k: insert n points
    lea     rdx, [rip+rA]
    mov     ecx, [rdx+rax*4]
    xor     edx, edx                    # ascending if this edge runs A -> B
    cmp     ecx, [rsp+8]
    jne     42f
    mov     edx, 1
42: mov     [rsp+28], edx
    mov     r13d, 1
43: cmp     r13d, r12d
    ja      44f
    mov     esi, r13d
    cmp     dword ptr [rsp+28], 0
    jne     431f
    mov     esi, r12d
    sub     esi, r13d
    inc     esi
431:mov     edi, [rsp+32]
    call    row_vert
    lea     rcx, [rip+scr]
    mov     [rcx+rbp*4], eax
    inc     ebp
    inc     r13d
    jmp     43b
44: mov     ecx, [rsp+24]
    inc     ecx
    jmp     4b
45: mov     rdi, r14
    lea     rsi, [rip+scr]
    mov     edx, ebp
    call    mesh_add_poly
.Llb_next:
    inc     r15d
    jmp     .Llb_poly
.Llb_commit:
    mov     rdi, r14
    call    mo_commit
    jmp     9f
.Llb_fail:
    mov     rdi, r14
    call    mesh_unref
9:  add     rsp, 72
    pop     rbp
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# row_vert(edi=ring edge k, esi=row j 0..n+1) -> eax = vertex: A_k, the
#   cut vertices, B_k (frame of loopcut_build one level up: n at [rsp+8+64],
#   base at [rsp+8+56])
row_vert:
    cmp     edi, [rip+r_m]
    jb      1f
    xor     edi, edi
1:  test    esi, esi
    jnz     2f
    lea     rax, [rip+rA]
    mov     eax, [rax+rdi*4]
    ret
2:  mov     ecx, [rsp+8+64]
    cmp     esi, ecx
    jbe     3f
    lea     rax, [rip+rB]
    mov     eax, [rax+rdi*4]
    ret
3:  mov     eax, edi
    imul    eax, ecx
    add     eax, esi
    dec     eax
    add     eax, [rsp+8+56]
    ret

# face_runs(edi=a, esi=b, edx=polygon of rbx) -> eax = 1 if it runs a -> b
face_runs:
    mov     r8, [rbx+ME_POFF]
    mov     ecx, [r8+rdx*4]
    mov     r9d, [r8+rdx*4+4]
    mov     r10d, ecx
    mov     r8, [rbx+ME_LOOPS]
1:  cmp     ecx, r9d
    jae     8f
    cmp     [r8+rcx*4], edi
    jne     2f
    lea     eax, [rcx+1]
    cmp     eax, r9d
    jb      11f
    mov     eax, r10d
11: cmp     [r8+rax*4], esi
    jne     2f
    mov     eax, 1
    ret
2:  inc     ecx
    jmp     1b
8:  xor     eax, eax
    ret

# eh_get(rdi=table, rsi=key+1) -> eax = value or -1 (no insert)
eh_get:
    mov     r8, [rdi]
    mov     rax, rsi
    imul    rax, rax, 0x2545f491
    shr     rax, 13
    and     rax, r8
1:  mov     rcx, [rdi+8+rax*8]
    test    rcx, rcx
    jz      2f
    cmp     rcx, rsi
    je      3f
    inc     rax
    and     rax, r8
    jmp     1b
2:  mov     eax, -1
    ret
3:  lea     rcx, [r8+1]
    lea     rcx, [rdi+8+rcx*8]
    mov     eax, [rcx+rax*4]
    ret

# =============================================================================
#  Plane cuts: bisect (scripts / menu) and the knife (screen segments)
# =============================================================================
do_knife:
    sub     rsp, 8
    call    need_edit
    test    rax, rax
    jz      9f
    mov     dword ptr [rip+etool], ET_KNIFE
    mov     dword ptr [rip+kn_n], 0
    mov     dword ptr [rip+dirty], 1
9:  add     rsp, 8
    ret

# knife_apply - each segment is a plane through the eye and its two pointer
#   rays, limited to the segment and to visible faces
knife_apply:
    push    rbx
    push    r12
    push    r13
    sub     rsp, 32
    cmp     dword ptr [rip+kn_n], 2
    jb      9f
    call    etool_setup
    lea     rdi, [rip+s_lbl_knife]
    call    undo_push
    xor     r12d, r12d                  # segments
    xor     r13d, r13d                  # cuts made
1:  lea     eax, [r12+1]
    cmp     eax, [rip+kn_n]
    jae     8f
    lea     rcx, [rip+kn_pts]
    mov     edi, [rcx+r12*8]
    mov     esi, [rcx+r12*8+4]
    call    view_ray
    mov     rax, [rip+tmp3]
    mov     [rsp], rax
    mov     eax, [rip+tmp3+8]
    mov     [rsp+8], eax
    lea     rcx, [rip+kn_pts]
    mov     edi, [rcx+r12*8+8]
    mov     esi, [rcx+r12*8+12]
    call    view_ray
    # n = ray0 x ray1 ; offset = n . eye
    movss   xmm0, [rsp+4]
    mulss   xmm0, [rip+tmp3+8]
    movss   xmm1, [rsp+8]
    mulss   xmm1, [rip+tmp3+4]
    subss   xmm0, xmm1
    movss   [rip+pc_n], xmm0
    movss   xmm0, [rsp+8]
    mulss   xmm0, [rip+tmp3]
    movss   xmm1, [rsp]
    mulss   xmm1, [rip+tmp3+8]
    subss   xmm0, xmm1
    movss   [rip+pc_n+4], xmm0
    movss   xmm0, [rsp]
    mulss   xmm0, [rip+tmp3+4]
    movss   xmm1, [rsp+4]
    mulss   xmm1, [rip+tmp3]
    subss   xmm0, xmm1
    movss   [rip+pc_n+8], xmm0
    lea     rdi, [rip+pc_n]
    call    normalize
    movss   xmm0, [rip+pc_n]
    mulss   xmm0, [rip+eye]
    movss   xmm1, [rip+pc_n+4]
    mulss   xmm1, [rip+eye+4]
    addss   xmm0, xmm1
    movss   xmm1, [rip+pc_n+8]
    mulss   xmm1, [rip+eye+8]
    addss   xmm0, xmm1
    movss   [rip+pc_off], xmm0
    lea     rcx, [rip+kn_pts]           # segment on screen (physical)
    mov     edi, [rcx+r12*8]
    call    to_px
    cvtsi2ss xmm0, eax
    movss   [rip+pc_s0], xmm0
    lea     rcx, [rip+kn_pts]
    mov     edi, [rcx+r12*8+4]
    call    to_px
    cvtsi2ss xmm0, eax
    movss   [rip+pc_s0+4], xmm0
    lea     rcx, [rip+kn_pts]
    mov     edi, [rcx+r12*8+8]
    call    to_px
    cvtsi2ss xmm0, eax
    movss   [rip+pc_s1], xmm0
    lea     rcx, [rip+kn_pts]
    mov     edi, [rcx+r12*8+12]
    call    to_px
    cvtsi2ss xmm0, eax
    movss   [rip+pc_s1+4], xmm0
    mov     dword ptr [rip+pc_limit], 1
    call    plane_cut
    add     r13d, eax
    inc     r12d
    jmp     1b
8:  call    reset_clip
    test    r13d, r13d
    jnz     9f
    lea     rdi, [rip+s_cut_none]
    call    mo_fail
9:  add     rsp, 32
    pop     r13
    pop     r12
    pop     rbx
    ret

# mesh.bisect "px py pz nx ny nz" (world) - default: horizontal through the
#   3D cursor
do_bisect:
    sub     rsp, 40
    call    need_edit
    test    rax, rax
    jz      .Lbs_drop
    lea     rdi, [rsp]
    mov     esi, 6
    call    arg_nums
    cmp     eax, 6
    je      1f
    mov     rax, [rip+cursor_pos]
    mov     [rsp], rax
    mov     eax, [rip+cursor_pos+8]
    mov     [rsp+8], eax
    xorps   xmm0, xmm0
    movss   [rsp+12], xmm0
    movss   [rsp+20], xmm0
    movss   xmm0, [rip+m2_one]
    movss   [rsp+16], xmm0
1:  mov     rax, [rsp+12]
    mov     [rip+pc_n], rax
    mov     eax, [rsp+20]
    mov     [rip+pc_n+8], eax
    lea     rdi, [rip+pc_n]
    call    normalize
    movss   xmm0, [rip+pc_n]
    mulss   xmm0, [rsp]
    movss   xmm1, [rip+pc_n+4]
    mulss   xmm1, [rsp+4]
    addss   xmm0, xmm1
    movss   xmm1, [rip+pc_n+8]
    mulss   xmm1, [rsp+8]
    addss   xmm0, xmm1
    movss   [rip+pc_off], xmm0
    mov     dword ptr [rip+pc_limit], 0
    call    plane_cut
    test    eax, eax
    jnz     9f
    lea     rdi, [rip+s_cut_none]
    call    mo_fail
    jmp     9f
.Lbs_drop:
    call    undo_drop_last
9:  add     rsp, 40
    ret

# pc_pass(rdi=world point) -> eax = 1 if a cut point there counts (knife:
#   within the segment and visible)
pc_pass:
    mov     eax, 1
    cmp     dword ptr [rip+pc_limit], 0
    je      9f
    sub     rsp, 8
    call    world_px
    add     rsp, 8
    xor     eax, eax
    xorps   xmm3, xmm3
    comiss  xmm2, xmm3
    jbe     9f
    movss   xmm4, [rip+pc_s1]           # t = (p - s0) . d / d . d
    subss   xmm4, [rip+pc_s0]
    movss   xmm5, [rip+pc_s1+4]
    subss   xmm5, [rip+pc_s0+4]
    movss   xmm6, xmm0
    subss   xmm6, [rip+pc_s0]
    mulss   xmm6, xmm4
    movss   xmm7, xmm1
    subss   xmm7, [rip+pc_s0+4]
    mulss   xmm7, xmm5
    addss   xmm6, xmm7
    mulss   xmm4, xmm4
    mulss   xmm5, xmm5
    addss   xmm4, xmm5
    maxss   xmm4, [rip+m2_tiny]
    divss   xmm6, xmm4
    comiss  xmm6, xmm3
    jb      9f
    comiss  xmm6, [rip+m2_one]
    ja      9f
    sub     rsp, 8
    call    visible
    add     rsp, 8
9:  ret

# plane_cut -> eax = 1 if anything was cut. The edit mesh is cut by the
#   plane pc_n . x = pc_off (world): crossing points become vertices, faces
#   with exactly two cut points split in two.
plane_cut:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    push    rbp
    sub     rsp, 72
    call    edit_get
    test    rax, rax
    jz      .Lpc_none
    mov     rbx, [rax+OB_MESH]
    call    ex_setup
    mov     edi, [rbx+ME_NVERTS]        # world positions, distances, cut flags
    imul    edi, edi, 12
    call    fa
    test    rax, rax
    jz      .Lpc_none
    mov     [rip+pw], rax
    mov     edi, [rbx+ME_NVERTS]
    shl     edi, 2
    call    fa
    test    rax, rax
    jz      .Lpc_none
    mov     [rip+pd], rax
    mov     edi, [rbx+ME_NVERTS]
    call    fa
    test    rax, rax
    jz      .Lpc_none
    mov     [rsp+64], rax               # cut-point flags for original vertices
    xor     r12d, r12d
1:  cmp     r12d, [rbx+ME_NVERTS]
    jae     2f
    imul    rsi, r12, 12
    add     rsi, [rbx+ME_POS]
    imul    rdx, r12, 12
    add     rdx, [rip+pw]
    call    ex_to_world
    imul    rax, r12, 12
    add     rax, [rip+pw]
    movss   xmm0, [rax]
    mulss   xmm0, [rip+pc_n]
    movss   xmm1, [rax+4]
    mulss   xmm1, [rip+pc_n+4]
    addss   xmm0, xmm1
    movss   xmm1, [rax+8]
    mulss   xmm1, [rip+pc_n+8]
    addss   xmm0, xmm1
    subss   xmm0, [rip+pc_off]
    mov     rcx, [rip+pd]
    movss   [rcx+r12*4], xmm0
    andps   xmm0, [rip+m2_absm]          # on the plane: a cut point itself
    comiss  xmm0, [rip+m2_eps]
    ja      11f
    mov     rdi, rax
    call    pc_pass
    mov     rcx, [rsp+64]
    mov     [rcx+r12], al
11: inc     r12d
    jmp     1b
2:  # crossing edges -> new vertices (hash: edge -> vertex)
    mov     edi, [rbx+ME_NEDGES]
    add     edi, 4
    call    eh_new
    test    rax, rax
    jz      .Lpc_none
    mov     [rsp+56], rax
    mov     edi, [rbx+ME_NVERTS]
    add     edi, [rbx+ME_NEDGES]
    add     edi, 8
    mov     esi, [rbx+ME_NLOOPS]
    add     esi, [rbx+ME_NEDGES]
    add     esi, [rbx+ME_NEDGES]
    add     esi, [rbx+ME_NPOLYS]
    add     esi, [rbx+ME_NPOLYS]
    add     esi, 8
    mov     edx, [rbx+ME_NPOLYS]
    add     edx, [rbx+ME_NPOLYS]
    add     edx, 8
    call    mesh_new
    test    rax, rax
    jz      .Lpc_none
    mov     r14, rax
    mov     rdi, r14
    mov     rsi, rbx
    call    copy_verts
    mov     rdi, r14
    call    clear_vsel
    mov     rcx, [rsp+64]               # on-plane cut points stay selected
    mov     rdx, [r14+ME_VSEL]
    xor     eax, eax
21: cmp     eax, [rbx+ME_NVERTS]
    jae     22f
    mov     r8b, [rcx+rax]
    mov     [rdx+rax], r8b
    inc     eax
    jmp     21b
22: xor     r15d, r15d                  # anything cut?
    xor     r12d, r12d
3:  cmp     r12d, [rbx+ME_NEDGES]
    jae     4f
    mov     rcx, [rbx+ME_EDGES]
    mov     edi, [rcx+r12*8]
    mov     esi, [rcx+r12*8+4]
    mov     rcx, [rip+pd]
    movss   xmm0, [rcx+rdi*4]
    movss   xmm1, [rcx+rsi*4]
    movss   xmm2, xmm0
    andps   xmm2, [rip+m2_absm]
    comiss  xmm2, [rip+m2_eps]
    jbe     39f
    movss   xmm2, xmm1
    andps   xmm2, [rip+m2_absm]
    comiss  xmm2, [rip+m2_eps]
    jbe     39f
    movss   xmm2, xmm0
    mulss   xmm2, xmm1
    xorps   xmm3, xmm3
    comiss  xmm2, xmm3
    jae     39f                         # same side
    movss   xmm2, xmm0                  # t = d0 / (d0 - d1)
    subss   xmm2, xmm1
    divss   xmm0, xmm2
    movss   [rsp+48], xmm0
    mov     [rsp+40], edi
    mov     [rsp+44], esi
    mov     rax, [rip+pw]               # world crossing point -> filter
    imul    rdi, rdi, 12
    imul    rsi, rsi, 12
    xor     ecx, ecx
31: movss   xmm1, [rax+rsi]
    subss   xmm1, [rax+rdi]
    mulss   xmm1, xmm0
    addss   xmm1, [rax+rdi]
    movss   [rsp+rcx*4], xmm1
    add     rdi, 4
    add     rsi, 4
    inc     ecx
    cmp     ecx, 3
    jb      31b
    lea     rdi, [rsp]
    call    pc_pass
    test    eax, eax
    jz      39f
    mov     edi, [rsp+40]               # local point (linear in t)
    mov     esi, [rsp+44]
    mov     rax, [rbx+ME_POS]
    imul    rdi, rdi, 12
    imul    rsi, rsi, 12
    movss   xmm0, [rsp+48]
    xor     ecx, ecx
32: movss   xmm1, [rax+rsi]
    subss   xmm1, [rax+rdi]
    mulss   xmm1, xmm0
    addss   xmm1, [rax+rdi]
    movss   [rsp+16+rcx*4], xmm1
    add     rdi, 4
    add     rsi, 4
    inc     ecx
    cmp     ecx, 3
    jb      32b
    mov     rdi, r14
    lea     rsi, [rsp+16]
    mov     edx, 1
    call    add_vert_at
    mov     ebp, eax
    mov     edi, [rsp+40]
    mov     esi, [rsp+44]
    call    ukey
    mov     rsi, rax
    mov     rdi, [rsp+56]
    call    eh_slot
    mov     [rax], ebp
    inc     r15d
39: inc     r12d
    jmp     3b
4:  # faces: insert crossings; two cut points -> split
    xor     r12d, r12d
.Lpc_poly:
    cmp     r12d, [rbx+ME_NPOLYS]
    jae     .Lpc_commit
    mov     rsi, [rbx+ME_POFF]
    mov     ecx, [rsi+r12*4]
    mov     edx, [rsi+r12*4+4]
    mov     [rsp+40], ecx
    mov     [rsp+44], edx
    xor     ebp, ebp                    # loop length in scr
    mov     dword ptr [rsp+32], 0       # cut points found
4:  cmp     ecx, [rsp+44]
    jae     46f
    mov     [rsp+48], ecx
    mov     rsi, [rbx+ME_LOOPS]
    mov     edi, [rsi+rcx*4]
    lea     rax, [rip+scr]
    mov     [rax+rbp*4], edi
    mov     r8, [rsp+64]                # original vertex on the plane?
    cmp     byte ptr [r8+rdi], 0
    je      41f
    call    pc_mark
41: inc     ebp
    lea     eax, [rcx+1]
    cmp     eax, [rsp+44]
    jb      42f
    mov     eax, [rsp+40]
42: mov     esi, [rsi+rax*4]
    call    ukey
    lea     rsi, [rax+1]
    mov     rdi, [rsp+56]
    call    eh_get
    test    eax, eax
    js      45f
    lea     rcx, [rip+scr]
    mov     [rcx+rbp*4], eax
    call    pc_mark
    inc     ebp
45: mov     ecx, [rsp+48]
    inc     ecx
    jmp     4b
46: cmp     dword ptr [rsp+32], 2       # exactly two, not neighbours: split
    jne     .Lpc_whole
    mov     eax, [rsp+24]               # positions i < j
    mov     ecx, [rsp+28]
    mov     edx, ecx
    sub     edx, eax
    cmp     edx, 1
    jbe     .Lpc_whole
    lea     edx, [rbp-1]
    sub     edx, ecx
    add     edx, eax
    jz      .Lpc_whole                  # (j = last, i = first: neighbours)
    lea     rsi, [rip+scr]              # part 1: i .. j
    lea     rsi, [rsi+rax*4]
    mov     edx, ecx
    sub     edx, eax
    inc     edx
    mov     rdi, r14
    call    mesh_add_poly
    mov     eax, [rsp+24]               # part 2: j .. end, 0 .. i
    mov     ecx, [rsp+28]
    lea     rdi, [rip+scr]
    lea     rsi, [rip+scr+SCR2*4]
    xor     edx, edx
47: cmp     ecx, ebp
    jae     48f
    mov     r8d, [rdi+rcx*4]
    mov     [rsi+rdx*4], r8d
    inc     edx
    inc     ecx
    jmp     47b
48: xor     ecx, ecx
49: cmp     ecx, eax
    ja      491f
    mov     r8d, [rdi+rcx*4]
    mov     [rsi+rdx*4], r8d
    inc     edx
    inc     ecx
    jmp     49b
491:mov     rdi, r14
    call    mesh_add_poly
    inc     r15d
    jmp     .Lpc_pnext
.Lpc_whole:
    mov     rdi, r14
    lea     rsi, [rip+scr]
    mov     edx, ebp
    call    mesh_add_poly
.Lpc_pnext:
    inc     r12d
    jmp     .Lpc_poly
.Lpc_commit:
    test    r15d, r15d
    jz      .Lpc_drop
    mov     rdi, r14
    call    mo_commit
    mov     eax, 1
    jmp     9f
.Lpc_drop:
    mov     rdi, r14
    call    mesh_unref
.Lpc_none:
    xor     eax, eax
9:  add     rsp, 72
    pop     rbp
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# pc_mark - record loop position ebp as a cut point (up to two kept at
#   plane_cut's [rsp+24] / [rsp+28], count at [rsp+32]; one frame up)
pc_mark:
    mov     eax, [rsp+8+32]
    cmp     eax, 2
    jae     1f
    mov     [rsp+8+24+rax*4], ebp
1:  inc     dword ptr [rsp+8+32]
    ret

.equ SCR2, 32768

# =============================================================================
#  Bridge two boundary loops
# =============================================================================
do_bridge:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    push    rbp
    sub     rsp, 56
    call    need_edit
    test    rax, rax
    jz      .Lbr_drop
    mov     rbx, rax
    call    edge_faces
    test    eax, eax
    jz      .Lbr_drop
    mov     edi, [rbx+ME_NVERTS]        # next[] along boundary edges, reversed
    mov     esi, -1
    call    fa_fill
    test    rax, rax
    jz      .Lbr_drop
    mov     r12, rax
    xor     r13d, r13d                  # edges
    xor     r15d, r15d
1:  cmp     r15d, [rbx+ME_NPOLYS]
    jae     2f
    mov     rsi, [rbx+ME_POFF]
    mov     ecx, [rsi+r15*4]
    mov     edx, [rsi+r15*4+4]
    mov     [rsp], ecx
    mov     [rsp+4], edx
11: cmp     ecx, [rsp+4]
    jae     19f
    mov     [rsp+8], ecx
    mov     rsi, [rbx+ME_LOOPS]
    mov     edi, [rsi+rcx*4]
    lea     eax, [rcx+1]
    cmp     eax, [rsp+4]
    jb      12f
    mov     eax, [rsp]
12: mov     esi, [rsi+rax*4]
    mov     r8, [rbx+ME_VSEL]
    mov     al, [r8+rdi]
    and     al, [r8+rsi]
    jz      18f
    mov     [rsp+12], edi
    mov     [rsp+16], esi
    call    ef_find
    test    eax, eax
    js      18f
    mov     rcx, [rip+ef_cnt]
    cmp     dword ptr [rcx+rax*4], 1
    jne     18f
    mov     edi, [rsp+12]               # face a -> b: the loop runs a -> b
    mov     esi, [rsp+16]
    mov     [r12+rdi*4], esi
    inc     r13d
18: mov     ecx, [rsp+8]
    inc     ecx
    jmp     11b
19: inc     r15d
    jmp     1b
2:  # two loops: walk from the first unvisited start twice
    cmp     r13d, 6
    jb      .Lbr_need
    test    r13d, 1
    jnz     .Lbr_need
    mov     ebp, r13d
    shr     ebp, 1                      # n per loop
    cmp     ebp, SCR2/2
    ja      .Lbr_need
    lea     r14, [rip+scr]              # loop A at scr[0..n), B at scr[n..2n)
    xor     r15d, r15d                  # loops found
    xor     ecx, ecx
3:  cmp     ecx, [rbx+ME_NVERTS]
    jae     5f
    cmp     dword ptr [r12+rcx*4], -1
    je      4f
    cmp     r15d, 2
    jae     .Lbr_need
    mov     eax, r15d                   # walk this loop, consuming it
    imul    eax, ebp
    lea     r8, [r14+rax*4]
    xor     edx, edx
    mov     edi, ecx
31: cmp     edx, ebp
    jae     .Lbr_need
    mov     [r8+rdx*4], edi
    inc     edx
    mov     esi, [r12+rdi*4]
    mov     dword ptr [r12+rdi*4], -1
    mov     edi, esi
    test    edi, edi
    js      .Lbr_need
    cmp     edi, ecx
    jne     31b
    cmp     edx, ebp
    jne     .Lbr_need
    inc     r15d
4:  inc     ecx
    jmp     3b
5:  cmp     r15d, 2
    jne     .Lbr_need
    # best offset o: B runs opposite, b'_i = B[(o - i) mod n]
    mov     dword ptr [rsp+20], 0       # best o
    movss   xmm0, [rip+m2_big]
    movss   [rsp+24], xmm0
    xor     r15d, r15d                  # o
6:  cmp     r15d, ebp
    jae     7f
    xorps   xmm7, xmm7
    xor     ecx, ecx                    # i
61: cmp     ecx, ebp
    jae     63f
    mov     eax, r15d
    sub     eax, ecx
    jns     62f
    add     eax, ebp
62: mov     edx, ebp
    add     edx, eax
    mov     edx, [r14+rdx*4]            # b'_i
    mov     eax, [r14+rcx*4]            # a_i
    mov     rsi, [rbx+ME_POS]
    lea     rax, [rax+rax*2]
    lea     rdx, [rdx+rdx*2]
    movss   xmm0, [rsi+rax*4]
    subss   xmm0, [rsi+rdx*4]
    mulss   xmm0, xmm0
    addss   xmm7, xmm0
    movss   xmm0, [rsi+rax*4+4]
    subss   xmm0, [rsi+rdx*4+4]
    mulss   xmm0, xmm0
    addss   xmm7, xmm0
    movss   xmm0, [rsi+rax*4+8]
    subss   xmm0, [rsi+rdx*4+8]
    mulss   xmm0, xmm0
    addss   xmm7, xmm0
    inc     ecx
    jmp     61b
63: comiss  xmm7, [rsp+24]
    jae     64f
    movss   [rsp+24], xmm7
    mov     [rsp+20], r15d
64: inc     r15d
    jmp     6b
7:  mov     edi, [rbx+ME_NVERTS]        # build: everything + the band
    mov     esi, [rbx+ME_NLOOPS]
    lea     esi, [rsi+rbp*4+8]
    mov     edx, [rbx+ME_NPOLYS]
    lea     edx, [rdx+rbp+8]
    call    mesh_new
    test    rax, rax
    jz      .Lbr_drop
    mov     r13, rax
    mov     rdi, r13
    mov     rsi, rbx
    call    copy_verts
    xor     r15d, r15d
8:  cmp     r15d, [rbx+ME_NPOLYS]
    jae     81f
    mov     rdi, r13
    mov     rsi, rbx
    mov     edx, r15d
    xor     ecx, ecx
    xor     r8d, r8d
    call    poly_copy
    inc     r15d
    jmp     8b
81: xor     r15d, r15d                  # quads a_i+1 a_i b'_i b'_i+1
82: cmp     r15d, ebp
    jae     83f
    mov     eax, r15d
    call    bridge_b                    # eax = b'_i
    mov     [rsp+40], eax
    lea     eax, [r15+1]
    cmp     eax, ebp
    jb      821f
    xor     eax, eax
821:mov     [rsp+44], eax               # i+1
    call    bridge_b
    mov     [rsp+36], eax               # b'_i+1
    mov     eax, [rsp+44]
    mov     eax, [r14+rax*4]
    mov     [rsp], eax
    mov     eax, [r14+r15*4]
    mov     [rsp+4], eax
    mov     eax, [rsp+40]
    mov     [rsp+8], eax
    mov     eax, [rsp+36]
    mov     [rsp+12], eax
    mov     rdi, r13
    lea     rsi, [rsp]
    mov     edx, 4
    call    mesh_add_poly
    inc     r15d
    jmp     82b
83: mov     rdi, r13
    call    mo_commit
    jmp     9f
.Lbr_need:
    lea     rdi, [rip+s_bridge_need]
    call    mo_fail
    jmp     9f
.Lbr_drop:
    call    undo_drop_last
9:  add     rsp, 56
    pop     rbp
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# bridge_b(eax=i) -> eax = b'_i = B[(o - i) mod n] (do_bridge's frame one
#   level up: o at [rsp+8+20], n in ebp, scr in r14)
bridge_b:
    mov     ecx, [rsp+8+20]
    sub     ecx, eax
    jns     1f
    add     ecx, ebp
1:  add     ecx, ebp
    mov     eax, [r14+rcx*4]
    ret

# =============================================================================
#  Spin: sweep the selected edges around the 3D cursor
# =============================================================================
do_spin:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    push    rbp
    sub     rsp, 120
    call    need_edit
    test    rax, rax
    jz      .Lsp_drop
    mov     rbx, rax
    lea     rdi, [rsp]                  # [steps, degrees]
    mov     esi, 2
    call    arg_nums
    mov     dword ptr [rsp+8], 12       # steps
    movss   xmm0, [rip+m2_360]
    movss   [rsp+12], xmm0              # degrees
    cmp     eax, 1
    jb      1f
    cvttss2si ecx, [rsp]
    cmp     ecx, 1
    jl      1f
    cmp     ecx, 512
    jg      1f
    mov     [rsp+8], ecx
    cmp     eax, 2
    jb      1f
    movss   xmm0, [rsp+4]
    movss   [rsp+12], xmm0
1:  xorps   xmm0, xmm0                  # axis (world): y unless "x" / "z"
    movss   [rsp+16], xmm0
    movss   [rsp+24], xmm0
    movss   xmm1, [rip+m2_one]
    movss   [rsp+20], xmm1
    mov     rsi, [rip+op_arg]
    test    rsi, rsi
    jz      3f
2:  mov     al, [rsi]
    test    al, al
    jz      3f
    or      al, 0x20
    cmp     al, 'x'
    jne     21f
    movss   [rsp+16], xmm1
    movss   [rsp+20], xmm0
    jmp     3f
21: cmp     al, 'z'
    jne     22f
    movss   [rsp+24], xmm1
    movss   [rsp+20], xmm0
    jmp     3f
22: inc     rsi
    jmp     2b
3:  # profile: edges with both ends selected
    mov     r8, [rbx+ME_EDGES]
    mov     r9, [rbx+ME_VSEL]
    xor     r12d, r12d                  # selected edges
    xor     ecx, ecx
4:  cmp     ecx, [rbx+ME_NEDGES]
    jae     5f
    mov     eax, [r8+rcx*8]
    mov     edx, [r8+rcx*8+4]
    mov     al, [r9+rax]
    and     al, [r9+rdx]
    movzx   eax, al
    add     r12d, eax
    inc     ecx
    jmp     4b
5:  test    r12d, r12d
    jz      .Lsp_need
    mov     edi, [rbx+ME_NVERTS]        # ring slot of each selected vertex
    mov     esi, -1
    call    fa_fill
    test    rax, rax
    jz      .Lsp_drop
    mov     r13, rax
    xor     r14d, r14d                  # selected vertices
    mov     r9, [rbx+ME_VSEL]
    xor     ecx, ecx
51: cmp     ecx, [rbx+ME_NVERTS]
    jae     52f
    cmp     byte ptr [r9+rcx], 0
    je      511f
    mov     [r13+rcx*4], r14d
    inc     r14d
511:inc     ecx
    jmp     51b
52: # closed (360): steps rings, the last joins the first; else steps + 1
    mov     dword ptr [rsp+28], 0       # closed?
    movss   xmm0, [rsp+12]
    andps   xmm0, [rip+m2_absm]
    comiss  xmm0, [rip+m2_359]
    jb      53f
    mov     dword ptr [rsp+28], 1
53: mov     eax, [rsp+8]
    mov     ecx, eax
    cmp     dword ptr [rsp+28], 0
    jne     54f
    inc     ecx                         # rings including the original
54: mov     [rsp+32], ecx               # rings
    mov     edi, ecx
    dec     edi
    imul    edi, r14d
    add     edi, [rbx+ME_NVERTS]
    add     edi, 8
    mov     esi, [rbx+ME_NLOOPS]
    mov     eax, [rsp+8]
    imul    eax, r12d
    lea     esi, [rsi+rax*4+8]
    mov     edx, [rbx+ME_NPOLYS]
    lea     edx, [rdx+rax+8]
    call    mesh_new
    test    rax, rax
    jz      .Lsp_drop
    mov     r15, rax
    mov     rdi, r15
    mov     rsi, rbx
    call    copy_verts
    call    ex_setup
    # cursor and axis in world space; rings k = 1 .. rings-1
    mov     ebp, 1
6:  cmp     ebp, [rsp+32]
    jae     7f
    cvtsi2ss xmm0, ebp                  # angle = degrees * k / steps
    mulss   xmm0, [rsp+12]
    cvtsi2ss xmm1, dword ptr [rsp+8]
    divss   xmm0, xmm1
    mulss   xmm0, [rip+m2_d2r]
    call    sincos
    movss   [rsp+36], xmm0              # sin
    movss   [rsp+40], xmm1              # cos
    xor     ecx, ecx                    # every selected vertex
61: cmp     ecx, [rbx+ME_NVERTS]
    jae     69f
    cmp     dword ptr [r13+rcx*4], -1
    je      68f
    mov     [rsp+44], ecx
    imul    rsi, rcx, 12
    add     rsi, [rbx+ME_POS]
    lea     rdx, [rsp+48]
    call    ex_to_world
    # d = p - c ; p' = c + d cos + (a x d) sin + a (a . d)(1 - cos)
    xor     ecx, ecx
62: movss   xmm0, [rsp+48+rcx*4]
    lea     rax, [rip+cursor_pos]
    subss   xmm0, [rax+rcx*4]
    movss   [rsp+60+rcx*4], xmm0
    inc     ecx
    cmp     ecx, 3
    jb      62b
    movss   xmm3, [rsp+16]              # a . d
    mulss   xmm3, [rsp+60]
    movss   xmm4, [rsp+20]
    mulss   xmm4, [rsp+64]
    addss   xmm3, xmm4
    movss   xmm4, [rsp+24]
    mulss   xmm4, [rsp+68]
    addss   xmm3, xmm4
    movss   xmm4, [rip+m2_one]
    subss   xmm4, [rsp+40]
    mulss   xmm3, xmm4                  # (a . d)(1 - cos)
    movss   xmm0, [rsp+20]              # a x d
    mulss   xmm0, [rsp+68]
    movss   xmm1, [rsp+24]
    mulss   xmm1, [rsp+64]
    subss   xmm0, xmm1
    movss   [rsp+72], xmm0
    movss   xmm0, [rsp+24]
    mulss   xmm0, [rsp+60]
    movss   xmm1, [rsp+16]
    mulss   xmm1, [rsp+68]
    subss   xmm0, xmm1
    movss   [rsp+76], xmm0
    movss   xmm0, [rsp+16]
    mulss   xmm0, [rsp+64]
    movss   xmm1, [rsp+20]
    mulss   xmm1, [rsp+60]
    subss   xmm0, xmm1
    movss   [rsp+80], xmm0
    xor     ecx, ecx
63: movss   xmm0, [rsp+60+rcx*4]
    mulss   xmm0, [rsp+40]
    movss   xmm1, [rsp+72+rcx*4]
    mulss   xmm1, [rsp+36]
    addss   xmm0, xmm1
    movss   xmm1, [rsp+16+rcx*4]
    mulss   xmm1, xmm3
    addss   xmm0, xmm1
    lea     rax, [rip+cursor_pos]
    addss   xmm0, [rax+rcx*4]
    movss   [rsp+84+rcx*4], xmm0
    inc     ecx
    cmp     ecx, 3
    jb      63b
    lea     rsi, [rsp+84]
    lea     rdx, [rsp+96]
    call    ex_to_local
    mov     rdi, r15
    lea     rsi, [rsp+96]
    xor     edx, edx
    cmp     ebp, [rsp+8]                # the last ring stays selected
    jne     64f
    mov     edx, 1
64: call    add_vert_at
    mov     ecx, [rsp+44]
68: inc     ecx
    jmp     61b
69: inc     ebp
    jmp     6b
7:  # faces: original polygons, then a quad per profile edge per step
    xor     ebp, ebp
71: cmp     ebp, [rbx+ME_NPOLYS]
    jae     72f
    mov     rdi, r15
    mov     rsi, rbx
    mov     edx, ebp
    xor     ecx, ecx
    xor     r8d, r8d
    call    poly_copy
    inc     ebp
    jmp     71b
72: xor     ebp, ebp                    # step k: ring k -> ring k+1
73: cmp     ebp, [rsp+8]
    jae     .Lsp_commit
    xor     ecx, ecx                    # edges
74: cmp     ecx, [rbx+ME_NEDGES]
    jae     79f
    mov     [rsp+44], ecx
    mov     r8, [rbx+ME_EDGES]
    mov     edi, [r8+rcx*8]
    mov     esi, [r8+rcx*8+4]
    cmp     dword ptr [r13+rdi*4], -1
    je      78f
    cmp     dword ptr [r13+rsi*4], -1
    je      78f
    mov     [rsp+100], edi
    mov     [rsp+104], esi
    mov     edx, ebp
    call    spin_vert                   # a_k
    mov     [rsp+60], eax
    mov     edi, [rsp+104]
    mov     edx, ebp
    call    spin_vert                   # b_k
    mov     [rsp+64], eax
    mov     edi, [rsp+104]
    lea     edx, [rbp+1]
    call    spin_vert                   # b_k+1
    mov     [rsp+68], eax
    mov     edi, [rsp+100]
    lea     edx, [rbp+1]
    call    spin_vert                   # a_k+1
    mov     [rsp+72], eax
    mov     rdi, r15
    lea     rsi, [rsp+60]
    mov     edx, 4
    call    mesh_add_poly
78: mov     ecx, [rsp+44]
    inc     ecx
    jmp     74b
79: inc     ebp
    jmp     73b
.Lsp_commit:
    mov     rdi, r15
    call    mo_commit
    call    merge_seam                  # (open spins over 360 already join)
    call    recalc_all
    cvtsi2ss xmm0, dword ptr [rsp+8]    # the redo panel: steps, angle, axis
    movss   [rsp+60], xmm0
    movss   xmm0, [rsp+12]
    movss   [rsp+64], xmm0
    mov     eax, 1                      # axis index: the non-zero component
    xorps   xmm1, xmm1
    ucomiss xmm1, [rsp+16]
    jne     71f
    ucomiss xmm1, [rsp+24]
    je      72f
    mov     eax, 2
    jmp     72f
71: xor     eax, eax
72: cvtsi2ss xmm0, eax
    movss   [rsp+68], xmm0
    lea     rdi, [rip+op_m_spin]
    lea     rsi, [rsp+60]
    mov     edx, 3
    call    lastop_set
    jmp     9f
.Lsp_need:
    lea     rdi, [rip+s_spin_need]
    call    mo_fail
    jmp     9f
.Lsp_drop:
    call    undo_drop_last
9:  add     rsp, 120
    pop     rbp
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# spin_vert(edi=original vertex, edx=ring k) -> eax = its vertex in ring k
#   (ring 0 and, when closed, ring "steps" are the original; do_spin's frame
#   one level up: steps [rsp+8+8], rings [rsp+8+32]; r13 = ring slots,
#   r14 = selected count, rbx = source mesh)
spin_vert:
    test    edx, edx
    jz      2f
    cmp     edx, [rsp+8+32]
    jb      1f
    xor     edx, edx                    # closed: wraps to the original
    jmp     2f
1:  mov     eax, edx
    dec     eax
    imul    eax, r14d
    add     eax, [r13+rdi*4]
    add     eax, [rbx+ME_NVERTS]
    ret
2:  mov     eax, edi
    ret

# merge_seam - nothing to do: closed spins reuse the original ring
merge_seam:
    ret

# =============================================================================
#  Bevel: chamfer the selected edges (segments round them)
# =============================================================================
do_bevel:
    push    rbx
    sub     rsp, 16
    call    need_edit
    test    rax, rax
    jz      .Lbv_drop
    mov     rbx, rax
    call    edge_faces
    test    eax, eax
    jz      .Lbv_drop
    call    bevel_count
    test    eax, eax
    jz      .Lbv_need
    mov     [rip+bv_src], rbx           # source mesh (ref held while modal)
    mov     rdi, rbx
    call    mesh_ref
    call    interactive
    test    eax, eax
    jz      1f
    mov     dword ptr [rip+tm_vint], 1  # segments, the wheel changes them
    lea     rdi, [rip+op_m_bevel]
    mov     esi, 3
    call    lastop_pending
    lea     rdi, [rip+bv_apply]
    lea     rsi, [rip+bv_cancel]
    lea     rdx, [rip+bv_confirm]
    lea     rcx, [rip+s_lbl_bevel]
    call    tm_start_value
    jmp     9f
1:  lea     rdi, [rsp]                  # scripts: "width [segments]"
    mov     esi, 2
    call    arg_nums
    movss   xmm0, [rip+m2_bevel0]
    mov     dword ptr [rip+tm_vint], 1
    test    eax, eax
    jz      2f
    movss   xmm0, [rsp]
    cmp     eax, 2
    jb      2f
    cvttss2si ecx, [rsp+4]
    cmp     ecx, 1
    jl      2f
    cmp     ecx, 64
    jg      2f
    mov     [rip+tm_vint], ecx
2:  movss   [rsp], xmm0                 # (width, segments) for the redo panel
    cvtsi2ss xmm1, dword ptr [rip+tm_vint]
    movss   [rsp+4], xmm1
    call    bv_apply
    call    bv_confirm
    mov     dword ptr [rip+tm_vint], 0
    lea     rdi, [rip+op_m_bevel]
    lea     rsi, [rsp]
    mov     edx, 2
    call    lastop_set
    jmp     9f
.Lbv_need:
    lea     rdi, [rip+s_bevel_need]
    call    mo_fail
    jmp     9f
.Lbv_drop:
    call    undo_drop_last
9:  add     rsp, 16
    pop     rbx
    ret

# bevel_count(rbx=mesh, edge_faces built) -> eax = edges to bevel
bevel_count:
    xor     eax, eax
    mov     r8, [rbx+ME_EDGES]
    mov     r9, [rbx+ME_VSEL]
    xor     ecx, ecx
1:  cmp     ecx, [rbx+ME_NEDGES]
    jae     9f
    mov     edx, [r8+rcx*8]
    mov     r10d, [r8+rcx*8+4]
    mov     dl, [r9+rdx]
    and     dl, [r9+r10]
    jz      2f
    inc     eax
2:  inc     ecx
    jmp     1b
9:  ret

bv_apply:                               # xmm0 = width
    sub     rsp, 8
    mov     rdi, [rip+bv_src]
    test    rdi, rdi
    jz      9f
    mov     esi, [rip+tm_vint]
    call    build_bevel
    test    rax, rax
    jz      9f
    mov     rdi, rax
    call    mo_commit
9:  add     rsp, 8
    ret
bv_cancel:
    sub     rsp, 8
    mov     rdi, [rip+bv_src]
    mov     qword ptr [rip+bv_src], 0
    test    rdi, rdi
    jz      9f
    call    edit_replace
9:  mov     dword ptr [rip+tm_vint], 0
    add     rsp, 8
    ret
bv_confirm:
    sub     rsp, 8
    mov     rdi, [rip+bv_src]
    mov     qword ptr [rip+bv_src], 0
    call    mesh_unref
    mov     dword ptr [rip+tm_vint], 0
    add     rsp, 8
    ret

.section .bss
.align 8
bv_src:         .skip 8
bv_w:           .skip 4
bv_seg:         .skip 4
bv_bev:         .skip 8             # per edge slot: beveled
bv_cpt:         .skip 8             # per loop: the corner's own point
bv_along:       .skip 8             # hash (v -> other) : point moved along that edge
bv_arc:         .skip 8             # per edge slot: 2 ends x (segments - 1) arc points
bv_dst:         .skip 8
bv_angle:       .skip 4             # 1: bevel edges sharper than bv_cos
bv_cos:         .skip 4
.align 8
bv_pred:        .skip 8
bv_done:        .skip 8
bv_arch:        .skip 8             # hash: an arc's two ends -> who made it             # per vertex: a face closed its round             # 0, or fn(edi, esi = edge ends, rdx = mesh) -> eax
.text

# build_bevel(rdi=src, esi=segments, xmm0=width) -> rax = new mesh
build_bevel:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    push    rbp
    sub     rsp, 104
    mov     rbx, rdi
    movss   [rip+bv_w], xmm0
    cmp     esi, 1
    jge     1f
    mov     esi, 1
1:  mov     [rip+bv_seg], esi
    call    edge_faces
    test    eax, eax
    jz      .Lbb_fail
    # beveled slots: selected (both ends) with two faces
    mov     edi, [rip+ef_n]
    call    fa
    test    rax, rax
    jz      .Lbb_fail
    mov     [rip+bv_bev], rax
    mov     r8, [rbx+ME_EDGES]
    xor     r12d, r12d
2:  cmp     r12d, [rbx+ME_NEDGES]
    jae     3f
    mov     rax, [rbx+ME_VSEL]
    mov     edi, [r8+r12*8]
    mov     esi, [r8+r12*8+4]
    cmp     dword ptr [rip+bv_angle], 0  # modifier: by angle, not selection
    jne     22f
    mov     cl, [rax+rdi]
    and     cl, [rax+rsi]
    jz      21f
22: push    r8
    call    ef_find
    pop     r8
    test    eax, eax
    js      21f
    mov     rcx, [rip+ef_cnt]
    cmp     dword ptr [rcx+rax*4], 2
    jne     21f
    cmp     dword ptr [rip+bv_angle], 0
    je      23f
    push    r8
    push    rax
    call    sharp_edge                  # eax = 1 if the faces meet sharply
    mov     ecx, eax
    pop     rax
    pop     r8
    test    ecx, ecx
    jz      21f
    cmp     qword ptr [rip+bv_pred], 0  # and a caller's test (features)
    je      23f
    push    r8
    push    rax
    mov     edi, [r8+r12*8]
    mov     esi, [r8+r12*8+4]
    mov     rdx, rbx
    call    [rip+bv_pred]
    mov     ecx, eax
    pop     rax
    pop     r8
    test    ecx, ecx
    jz      21f
23: mov     rcx, [rip+bv_bev]
    mov     byte ptr [rcx+rax], 1
21: inc     r12d
    jmp     2b
3:  # the new mesh: generous capacities
    mov     eax, [rip+bv_seg]
    inc     eax
    imul    eax, [rbx+ME_NEDGES]
    mov     edi, [rbx+ME_NLOOPS]
    add     edi, eax
    add     edi, edi
    add     edi, [rbx+ME_NVERTS]
    add     edi, 16
    mov     esi, [rbx+ME_NLOOPS]
    lea     esi, [rsi+rax*2]
    shl     esi, 2
    add     esi, 16
    mov     edx, [rbx+ME_NPOLYS]
    add     edx, [rbx+ME_NVERTS]
    add     edx, eax
    add     edx, 16
    call    mesh_new
    test    rax, rax
    jz      .Lbb_fail
    mov     r14, rax
    mov     [rip+bv_dst], rax
    mov     rdi, r14
    mov     rsi, rbx
    call    copy_verts
    mov     rdi, r14
    call    clear_vsel
    mov     edi, [rbx+ME_NLOOPS]        # corner points
    mov     esi, -1
    call    fa_fill
    test    rax, rax
    jz      .Lbb_fail2
    mov     [rip+bv_cpt], rax
    mov     edi, [rbx+ME_NLOOPS]
    add     edi, [rbx+ME_NLOOPS]
    call    eh_new
    test    rax, rax
    jz      .Lbb_fail2
    mov     [rip+bv_along], rax
    # ---- pass 1: each corner touching a beveled edge gets its point -------
    xor     r15d, r15d                  # polygon
.Lbb_p1:
    cmp     r15d, [rbx+ME_NPOLYS]
    jae     .Lbb_arcs
    mov     rsi, [rbx+ME_POFF]
    mov     eax, [rsi+r15*4]
    mov     [rsp], eax                  # first
    mov     eax, [rsi+r15*4+4]
    mov     [rsp+4], eax                # end
    mov     r12d, [rsp]                 # loop L
4:  cmp     r12d, [rsp+4]
    jae     .Lbb_p1n
    call    corner_ids                  # [rsp+8+..]: u v w (one level up)
    mov     edi, [rsp+12]               # u
    mov     esi, [rsp+16]               # v
    call    is_bev
    mov     [rsp+24], eax               # bp
    mov     edi, [rsp+16]
    mov     esi, [rsp+20]               # w
    call    is_bev
    mov     [rsp+28], eax               # bn
    mov     ecx, [rsp+24]
    or      ecx, eax
    jz      49f
    call    corner_point                # xmm: computes and stores bv_cpt[L]
49: inc     r12d
    jmp     4b
.Lbb_p1n:
    inc     r15d
    jmp     .Lbb_p1
.Lbb_arcs:
    mov     edi, [rbx+ME_NVERTS]        # vertices whose round is closed (no patch)
    call    fa
    test    rax, rax
    jz      .Lbb_fail2
    mov     [rip+bv_done], rax
    # ---- arc points per beveled edge end (segments > 1) --------------------
    mov     eax, [rip+bv_seg]
    dec     eax
    shl     eax, 3                      # 2 ends x (s - 1) x 4 bytes
    imul    eax, [rip+ef_n]
    lea     edi, [rax+16]
    call    fa
    test    rax, rax
    jz      .Lbb_fail2
    mov     [rip+bv_arc], rax
    cmp     dword ptr [rip+bv_seg], 1
    je      .Lbb_faces
    mov     edi, [rip+ef_n]             # arcs by their two ends (shared)
    add     edi, edi
    call    eh_new
    test    rax, rax
    jz      .Lbb_fail2
    mov     [rip+bv_arch], rax
    mov     r8, [rbx+ME_EDGES]
    xor     r12d, r12d                  # edges
5:  cmp     r12d, [rbx+ME_NEDGES]
    jae     .Lbb_faces
    mov     r8, [rbx+ME_EDGES]
    mov     edi, [r8+r12*8]
    mov     esi, [r8+r12*8+4]
    mov     [rsp+32], edi
    mov     [rsp+36], esi
    call    ef_find
    test    eax, eax
    js      59f
    mov     rcx, [rip+bv_bev]
    cmp     byte ptr [rcx+rax], 0
    je      59f
    mov     [rsp+40], eax               # slot
    xor     ebp, ebp                    # end 0 = lo vertex, 1 = hi
51: cmp     ebp, 2
    jae     59f
    mov     edi, [rsp+32+rbp*4]         # the end vertex
    mov     [rsp+44], edi
    mov     rcx, [rip+ef_f1]            # P1 = cpt of F1 at v, P2 = of F2
    mov     eax, [rsp+40]
    mov     edx, [rcx+rax*4]
    mov     esi, edi
    mov     edi, edx
    call    corner_of                   # eax = loop index of face edi at v esi
    mov     rcx, [rip+bv_cpt]
    mov     eax, [rcx+rax*4]
    mov     [rsp+48], eax
    mov     rcx, [rip+ef_f2]
    mov     eax, [rsp+40]
    mov     edi, [rcx+rax*4]
    mov     esi, [rsp+44]
    call    corner_of
    mov     rcx, [rip+bv_cpt]
    mov     eax, [rcx+rax*4]
    mov     [rsp+52], eax
    call    arc_share                   # the same two ends at this corner:
    test    eax, eax                    #  one arc (rounded edges meeting)
    jnz     58f
    mov     r13d, 1                     # j = 1 .. s - 1
52: cmp     r13d, [rip+bv_seg]
    jae     58f
    cvtsi2ss xmm6, r13d                 # t
    cvtsi2ss xmm7, dword ptr [rip+bv_seg]
    divss   xmm6, xmm7
    movss   xmm5, [rip+m2_one]
    subss   xmm5, xmm6                  # 1 - t
    mov     rax, [r14+ME_POS]
    mov     ecx, [rsp+48]
    lea     rcx, [rcx+rcx*2]
    lea     r9, [rax+rcx*4]             # P1
    mov     ecx, [rsp+52]
    lea     rcx, [rcx+rcx*2]
    lea     r10, [rax+rcx*4]            # P2
    mov     ecx, [rsp+44]
    lea     rcx, [rcx+rcx*2]
    mov     rax, [rbx+ME_POS]
    lea     r11, [rax+rcx*4]            # v (control point)
    xor     ecx, ecx
53: movss   xmm0, [r9+rcx*4]            # (1-t)^2 P1 + 2 t (1-t) v + t^2 P2
    mulss   xmm0, xmm5
    mulss   xmm0, xmm5
    movss   xmm1, [r11+rcx*4]
    mulss   xmm1, xmm5
    mulss   xmm1, xmm6
    addss   xmm1, xmm1
    addss   xmm0, xmm1
    movss   xmm1, [r10+rcx*4]
    mulss   xmm1, xmm6
    mulss   xmm1, xmm6
    addss   xmm0, xmm1
    movss   [rsp+56+rcx*4], xmm0
    inc     ecx
    cmp     ecx, 3
    jb      53b
    mov     rdi, r14
    lea     rsi, [rsp+56]
    mov     edx, 1
    call    add_vert_at
    mov     ecx, [rsp+40]               # arc[slot][end][j - 1]
    mov     edx, [rip+bv_seg]
    dec     edx
    imul    ecx, edx
    shl     ecx, 1
    mov     r8d, ebp
    imul    r8d, edx
    add     ecx, r8d
    add     ecx, r13d
    dec     ecx
    mov     rdx, [rip+bv_arc]
    mov     [rdx+rcx*4], eax
    inc     r13d
    jmp     52b
58: inc     ebp
    jmp     51b
59: inc     r12d
    jmp     5b
.Lbb_faces:
    # ---- faces: corners replaced by their points -----------------------------
    xor     r15d, r15d
6:  cmp     r15d, [rbx+ME_NPOLYS]
    jae     .Lbb_strips
    mov     rsi, [rbx+ME_POFF]
    mov     eax, [rsi+r15*4]
    mov     [rsp], eax
    mov     eax, [rsi+r15*4+4]
    mov     [rsp+4], eax
    xor     ebp, ebp                    # output length (scr)
    mov     r12d, [rsp]
61: cmp     r12d, [rsp+4]
    jae     65f
    call    corner_ids
    call    corner_rep                  # appends to scr at ebp
    inc     r12d
    jmp     61b
65: call    dedupe_scr                  # ebp = length without repeats
    cmp     ebp, 3
    jb      66f
    mov     rdi, r14
    lea     rsi, [rip+scr]
    mov     edx, ebp
    call    mesh_add_poly
66: inc     r15d
    jmp     6b
.Lbb_strips:
    # ---- strips across each beveled edge -----------------------------------
    xor     r12d, r12d
7:  cmp     r12d, [rbx+ME_NEDGES]
    jae     .Lbb_corners
    mov     r8, [rbx+ME_EDGES]
    mov     edi, [r8+r12*8]
    mov     esi, [r8+r12*8+4]
    mov     [rsp+32], edi
    mov     [rsp+36], esi
    call    ef_find
    test    eax, eax
    js      79f
    mov     rcx, [rip+bv_bev]
    cmp     byte ptr [rcx+rax], 0
    je      79f
    mov     [rsp+40], eax
    xor     r13d, r13d                  # j = 0 .. s - 1: quad rows j, j+1
71: cmp     r13d, [rip+bv_seg]
    jae     79f
    mov     edi, 0                      # end 0 (lo), row j
    mov     esi, r13d
    call    strip_pt
    mov     [rsp+56], eax
    mov     edi, 1
    mov     esi, r13d
    call    strip_pt
    mov     [rsp+60], eax
    mov     edi, 1
    lea     esi, [r13+1]
    call    strip_pt
    mov     [rsp+64], eax
    mov     edi, 0
    lea     esi, [r13+1]
    call    strip_pt
    mov     [rsp+68], eax
    call    strip_orient                # reverse if it faces inwards
    mov     rdi, r14
    lea     rsi, [rsp+56]
    mov     edx, 4
    call    mesh_add_poly
    inc     r13d
    jmp     71b
79: inc     r12d
    jmp     7b
.Lbb_corners:
    # ---- corner patches where the points around a vertex leave a hole ------
    mov     edi, [rbx+ME_NVERTS]
    call    fa
    test    rax, rax
    jz      .Lbb_done
    mov     [rsp+88], rax               # vertex has a beveled edge
    mov     r8, [rbx+ME_EDGES]
    xor     ecx, ecx
8:  cmp     ecx, [rbx+ME_NEDGES]
    jae     81f
    push    rcx
    mov     r8, [rbx+ME_EDGES]
    mov     edi, [r8+rcx*8]
    mov     esi, [r8+rcx*8+4]
    push    rdi
    push    rsi
    call    ef_find
    pop     rsi
    pop     rdi
    pop     rcx
    test    eax, eax
    js      80f
    mov     rdx, [rip+bv_bev]
    cmp     byte ptr [rdx+rax], 0
    je      80f
    mov     rdx, [rsp+88]
    mov     byte ptr [rdx+rdi], 1
    mov     byte ptr [rdx+rsi], 1
80: inc     ecx
    jmp     8b
81: xor     r15d, r15d                  # every loop starting a fan walk
82: cmp     r15d, [rbx+ME_NVERTS]
    jae     .Lbb_done
    mov     rdx, [rsp+88]
    cmp     byte ptr [rdx+r15], 0
    je      89f
    mov     rdx, [rip+bv_done]
    cmp     byte ptr [rdx+r15], 0
    jne     89f
    mov     edi, r15d
    call    corner_patch
89: inc     r15d
    jmp     82b
.Lbb_done:
    mov     rax, r14
    jmp     9f
.Lbb_fail2:
    mov     rdi, r14
    call    mesh_unref
.Lbb_fail:
    xor     eax, eax
9:  add     rsp, 104
    pop     rbp
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# sharp_edge(eax=edge slot) -> eax = 1 if its two faces' normals differ by
#   more than the bevel modifier's angle (bv_cos = cos(angle))
sharp_edge:
    push    rbx
    push    r12
    sub     rsp, 24
    mov     r12d, eax
    mov     rdi, rbx
    mov     rcx, [rip+ef_f1]
    mov     esi, [rcx+r12*4]
    call    poly_normal
    lea     rdi, [rip+nrm]
    call    normalize
    mov     rax, [rip+nrm]
    mov     [rsp], rax
    mov     eax, [rip+nrm+8]
    mov     [rsp+8], eax
    mov     rdi, rbx
    mov     rcx, [rip+ef_f2]
    mov     esi, [rcx+r12*4]
    call    poly_normal
    lea     rdi, [rip+nrm]
    call    normalize
    movss   xmm0, [rsp]
    mulss   xmm0, [rip+nrm]
    movss   xmm1, [rsp+4]
    mulss   xmm1, [rip+nrm+4]
    addss   xmm0, xmm1
    movss   xmm1, [rsp+8]
    mulss   xmm1, [rip+nrm+8]
    addss   xmm0, xmm1
    xor     eax, eax
    comiss  xmm0, [rip+bv_cos]
    setb    al
    add     rsp, 24
    pop     r12
    pop     rbx
    ret

# corner_ids - for loop r12d of polygon [rsp+8], [rsp+12] (build_bevel's
#   frame one level up): u v w at [rsp+8+12 / 16 / 20]
corner_ids:
    mov     rsi, [rbx+ME_LOOPS]
    mov     eax, r12d
    dec     eax
    cmp     eax, [rsp+8]
    jge     1f
    mov     eax, [rsp+8+4]
    dec     eax
1:  mov     eax, [rsi+rax*4]
    mov     [rsp+8+12], eax             # u
    mov     eax, [rsi+r12*4]
    mov     [rsp+8+16], eax             # v
    lea     eax, [r12+1]
    cmp     eax, [rsp+8+4]
    jb      2f
    mov     eax, [rsp+8]
2:  mov     eax, [rsi+rax*4]
    mov     [rsp+8+20], eax             # w
    ret

# is_bev(edi=a, esi=b) -> eax = 1 if that edge is beveled
is_bev:
    sub     rsp, 8
    call    ef_find
    add     rsp, 8
    test    eax, eax
    js      1f
    mov     rcx, [rip+bv_bev]
    movzx   eax, byte ptr [rcx+rax]
    ret
1:  xor     eax, eax
    ret

# corner_point - build_bevel pass 1: loop r12d with u v w and bp / bn at
#   [rsp+8+12 .. 28] (one level up) gets its offset point in bv_cpt
corner_point:
    push    rbp
    sub     rsp, 80
    mov     rax, [rbx+ME_POS]           # dp = norm(u - v), dn = norm(w - v)
    mov     ecx, [rsp+80+16+12]
    lea     rcx, [rcx+rcx*2]
    lea     r8, [rax+rcx*4]             # u
    mov     ecx, [rsp+80+16+16]
    lea     rcx, [rcx+rcx*2]
    lea     r9, [rax+rcx*4]             # v
    mov     ecx, [rsp+80+16+20]
    lea     rcx, [rcx+rcx*2]
    lea     r10, [rax+rcx*4]            # w
    xor     ecx, ecx
1:  movss   xmm0, [r8+rcx*4]
    subss   xmm0, [r9+rcx*4]
    movss   [rsp+rcx*4], xmm0           # dp
    movss   xmm0, [r10+rcx*4]
    subss   xmm0, [r9+rcx*4]
    movss   [rsp+16+rcx*4], xmm0        # dn
    movss   xmm0, [r9+rcx*4]
    movss   [rsp+32+rcx*4], xmm0        # v
    inc     ecx
    cmp     ecx, 3
    jb      1b
    lea     rdi, [rsp]                  # the edge lengths, for the clamp
    call    vlen3
    movss   [rsp+64], xmm0
    lea     rdi, [rsp+16]
    call    vlen3
    movss   [rsp+68], xmm0
    lea     rdi, [rsp]
    call    normalize
    lea     rdi, [rsp+16]
    call    normalize
    movss   xmm0, [rsp+4]               # s = |dp x dn|
    mulss   xmm0, [rsp+24]
    movss   xmm1, [rsp+8]
    mulss   xmm1, [rsp+20]
    subss   xmm0, xmm1
    mulss   xmm0, xmm0
    movss   xmm2, [rsp+8]
    mulss   xmm2, [rsp+16]
    movss   xmm1, [rsp]
    mulss   xmm1, [rsp+24]
    subss   xmm2, xmm1
    mulss   xmm2, xmm2
    addss   xmm0, xmm2
    movss   xmm2, [rsp]
    mulss   xmm2, [rsp+20]
    movss   xmm1, [rsp+4]
    mulss   xmm1, [rsp+16]
    subss   xmm2, xmm1
    mulss   xmm2, xmm2
    addss   xmm0, xmm2
    sqrtss  xmm0, xmm0
    maxss   xmm0, [rip+m2_minsin]
    movss   xmm1, [rip+bv_w]
    divss   xmm1, xmm0
    movss   [rsp+48], xmm1              # k = width / sin
    mov     eax, [rsp+80+16+24]         # bp
    mov     edx, [rsp+80+16+28]         # bn
    test    eax, eax
    jz      .Lcp_along_prev
    test    edx, edx
    jz      .Lcp_along_next
    movss   xmm0, [rsp+64]              # both: no further than 45% of the
    minss   xmm0, [rsp+68]              #  shorter edge (clamped: points of
    mulss   xmm0, [rip+m2_clamp]        #  neighbouring corners never cross)
    minss   xmm0, [rsp+48]
    movss   [rsp+48], xmm0
    xor     ecx, ecx                    # v + (dp + dn) k, a new point
2:  movss   xmm0, [rsp+rcx*4]
    addss   xmm0, [rsp+16+rcx*4]
    mulss   xmm0, [rsp+48]
    addss   xmm0, [rsp+32+rcx*4]
    movss   [rsp+52+rcx*4], xmm0
    inc     ecx
    cmp     ecx, 3
    jb      2b
    mov     rdi, [rip+bv_dst]
    lea     rsi, [rsp+52]
    mov     edx, 1
    call    add_vert_at
    jmp     .Lcp_store
.Lcp_along_next:                        # bp only: slide along v -> w
    lea     rbp, [rsp+16]
    mov     esi, [rsp+80+16+20]
    movss   xmm0, [rsp+68]
    jmp     3f
.Lcp_along_prev:                        # bn only: slide along v -> u
    lea     rbp, [rsp]
    mov     esi, [rsp+80+16+12]
    movss   xmm0, [rsp+64]
3:  mulss   xmm0, [rip+m2_clamp]        # at most 45% of that edge
    minss   xmm0, [rsp+48]
    movss   [rsp+48], xmm0
    mov     edi, [rsp+80+16+16]         # shared per (v, other): the first wins
    call    dkey
    mov     rsi, rax
    mov     rdi, [rip+bv_along]
    call    eh_slot
    cmp     dword ptr [rax], -1
    jne     .Lcp_have
    push    rax
    sub     rsp, 8
    xor     ecx, ecx
4:  movss   xmm0, [rbp+rcx*4]
    mulss   xmm0, [rsp+16+48]
    addss   xmm0, [rsp+16+32+rcx*4]
    movss   [rsp+16+52+rcx*4], xmm0
    inc     ecx
    cmp     ecx, 3
    jb      4b
    mov     rdi, [rip+bv_dst]
    lea     rsi, [rsp+16+52]
    mov     edx, 1
    call    add_vert_at
    add     rsp, 8
    pop     rcx
    mov     [rcx], eax
    jmp     .Lcp_store
.Lcp_have:
    mov     eax, [rax]
.Lcp_store:
    mov     rcx, [rip+bv_cpt]
    mov     [rcx+r12*4], eax
    add     rsp, 80
    pop     rbp
    ret

# vlen3(rdi=float[3]) -> xmm0 = length
vlen3:
    movss   xmm0, [rdi]
    mulss   xmm0, xmm0
    movss   xmm1, [rdi+4]
    mulss   xmm1, xmm1
    addss   xmm0, xmm1
    movss   xmm1, [rdi+8]
    mulss   xmm1, xmm1
    addss   xmm0, xmm1
    sqrtss  xmm0, xmm0
    ret

# corner_of(edi=polygon, esi=vertex) -> eax = its loop index (of rbx)
corner_of:
    mov     r8, [rbx+ME_POFF]
    mov     ecx, [r8+rdi*4]
    mov     edx, [r8+rdi*4+4]
    mov     r8, [rbx+ME_LOOPS]
1:  cmp     ecx, edx
    jae     2f
    cmp     [r8+rcx*4], esi
    je      2f
    inc     ecx
    jmp     1b
2:  mov     eax, ecx
    ret

# corner_rep - append the representation of loop r12d (u v w at [rsp+8+12])
#   to scr at ebp: its own point, or for an untouched corner the points
#   slid along its two edges (else the vertex itself). build_bevel's frame is
#   one level up.
corner_rep:
    mov     rcx, [rip+bv_cpt]
    mov     eax, [rcx+r12*4]
    test    eax, eax
    js      1f
    lea     rcx, [rip+scr]
    mov     [rcx+rbp*4], eax
    inc     ebp
    ret
1:  sub     rsp, 8
    mov     edi, [rsp+16+16]            # v -> u
    mov     esi, [rsp+16+12]
    call    along_or_v
    lea     rcx, [rip+scr]
    mov     [rcx+rbp*4], eax
    inc     ebp
    mov     [rsp], eax
    mov     edi, [rsp+16+16]            # v -> w
    mov     esi, [rsp+16+20]
    call    along_or_v
    mov     [rsp+4], eax
    mov     edi, [rsp+16+16]            # (a rounded edge ending here: its arc
    mov     esi, [rsp]                  #  between the two)
    mov     edx, eax
    call    arc_fill
    mov     eax, [rsp+4]
    lea     rcx, [rip+scr]
    mov     [rcx+rbp*4], eax
    inc     ebp
    add     rsp, 8
    ret

# arc_share (build_bevel's arc pass: slot [rsp+8+40], end ebp, ends P1 / P2
#   at [rsp+8+48 / 52]) -> eax = 1 if an earlier edge end made the arc between
#   these two points: its points are used (in this direction); else 0 and
#   this one is registered
arc_share:
    push    r12
    push    r13
    sub     rsp, 8
    mov     edi, [rsp+32+48]
    mov     esi, [rsp+32+52]
    call    ukey
    mov     rsi, rax
    mov     rdi, [rip+bv_arch]
    call    eh_slot
    xor     ecx, ecx                    # this one runs high -> low?
    mov     r8d, [rsp+32+48]
    cmp     r8d, [rsp+32+52]
    seta    cl
    mov     r12d, [rsp+32+40]           # our arc base: (slot * 2 + end) (s - 1)
    lea     r12d, [r12+r12]
    add     r12d, ebp
    mov     r13d, [rip+bv_seg]
    dec     r13d
    test    edx, edx
    jnz     1f
    lea     edx, [r12+r12]              # new: (slot * 2 + end) * 2 + dir
    add     edx, ecx
    mov     [rax], edx
    xor     eax, eax
    jmp     9f
1:  mov     edx, [rax]                  # theirs
    mov     eax, edx
    and     edx, 1
    shr     eax, 1
    imul    eax, r13d                   # their base
    imul    r12d, r13d                  # ours
    mov     rsi, [rip+bv_arc]
    xor     r8d, r8d                    # k = 0 .. s - 2
2:  cmp     r8d, r13d
    jae     8f
    mov     r9d, r8d                    # same direction: k, else s - 2 - k
    cmp     edx, ecx
    je      3f
    lea     r9d, [r13-1]
    sub     r9d, r8d
3:  add     r9d, eax
    mov     r9d, [rsi+r9*4]
    lea     r10d, [r12+r8]
    mov     [rsi+r10*4], r9d
    inc     r8d
    jmp     2b
8:  mov     eax, [rsp+32+44]            # v: no corner patch
    mov     rcx, [rip+bv_done]
    mov     byte ptr [rcx+rax], 1
    mov     eax, 1
9:  add     rsp, 8
    pop     r13
    pop     r12
    ret

# arc_fill(edi=v, esi=a, edx=b) - when a beveled edge ends at v with its strip
#   running from a to b (or back), its arc points go into scr at ebp, a to b
#   (a face at v that touches none of the edge's faces closes the round)
arc_fill:
    cmp     dword ptr [rip+bv_seg], 1
    jbe     99f
    cmp     esi, edx
    je      99f
    cmp     esi, edi
    je      99f
    cmp     edx, edi
    je      99f
    push    r12
    push    r13
    push    r14
    push    r15
    sub     rsp, 24
    mov     r12d, edi
    mov     r13d, esi
    mov     r14d, edx
    xor     r15d, r15d                  # edges
1:  cmp     r15d, [rbx+ME_NEDGES]
    jae     9f
    mov     r8, [rbx+ME_EDGES]
    mov     edi, [r8+r15*8]
    mov     esi, [r8+r15*8+4]
    xor     ecx, ecx                    # which end is v
    cmp     edi, r12d
    je      2f
    mov     ecx, 1
    cmp     esi, r12d
    jne     8f
2:  mov     [rsp], ecx
    call    ef_find
    test    eax, eax
    js      8f
    mov     rcx, [rip+bv_bev]
    cmp     byte ptr [rcx+rax], 0
    je      8f
    mov     [rsp+4], eax                # slot
    mov     rcx, [rip+ef_f1]            # its strip's ends at v
    mov     edi, [rcx+rax*4]
    mov     esi, r12d
    call    corner_of
    mov     rcx, [rip+bv_cpt]
    mov     eax, [rcx+rax*4]
    mov     [rsp+8], eax
    mov     rcx, [rip+ef_f2]
    mov     eax, [rsp+4]
    mov     edi, [rcx+rax*4]
    mov     esi, r12d
    call    corner_of
    mov     rcx, [rip+bv_cpt]
    mov     eax, [rcx+rax*4]
    mov     edx, 1                      # forwards
    cmp     [rsp+8], r13d
    jne     3f
    cmp     eax, r14d
    je      4f
3:  mov     edx, -1                     # backwards
    cmp     [rsp+8], r14d
    jne     8f
    cmp     eax, r13d
    jne     8f
4:  mov     [rsp+12], edx
    mov     rcx, [rip+bv_done]          # (no corner patch here then)
    mov     byte ptr [rcx+r12], 1
    mov     ecx, [rip+bv_seg]           # arc[slot][end][j - 1], j = 1 .. s - 1
    dec     ecx
    mov     eax, [rsp+4]
    imul    eax, ecx
    shl     eax, 1
    mov     edx, [rsp]
    imul    edx, ecx
    add     eax, edx                    # arc[slot][end][0]
    mov     r8d, 0                      # k = 0 .. s - 2
    cmp     dword ptr [rsp+12], 0
    jg      5f
    lea     r8d, [rcx-1]
5:  test    r8d, r8d
    js      9f
    cmp     r8d, ecx
    jae     9f
    cmp     ebp, 65536 - 8              # (scr: SCR_MAX)
    jae     9f
    lea     edx, [rax+r8]
    mov     rsi, [rip+bv_arc]
    mov     edx, [rsi+rdx*4]
    lea     rsi, [rip+scr]
    mov     [rsi+rbp*4], edx
    inc     ebp
    add     r8d, [rsp+12]
    jmp     5b
8:  inc     r15d
    jmp     1b
9:  add     rsp, 24
    pop     r15
    pop     r14
    pop     r13
    pop     r12
99: ret

# along_or_v(edi=v, esi=other) -> eax = point slid from v towards other, or v
along_or_v:
    push    rdi
    call    dkey
    lea     rsi, [rax+1]
    mov     rdi, [rip+bv_along]
    call    eh_get
    pop     rdi
    test    eax, eax
    jns     1f
    mov     eax, edi
1:  ret

# dedupe_scr - drop repeated neighbours in scr[0..ebp) (cyclic)
dedupe_scr:
    lea     rsi, [rip+scr]
    test    ebp, ebp
    jz      9f
    mov     ecx, 1
    mov     edx, 1                      # write position
1:  cmp     ecx, ebp
    jae     2f
    mov     eax, [rsi+rcx*4]
    cmp     eax, [rsi+rdx*4-4]
    je      11f
    mov     [rsi+rdx*4], eax
    inc     edx
11: inc     ecx
    jmp     1b
2:  mov     ebp, edx
3:  cmp     ebp, 1
    jbe     9f
    mov     eax, [rsi+rbp*4-4]
    cmp     eax, [rsi]
    jne     9f
    dec     ebp
    jmp     3b
9:  ret

# strip_pt(edi=end 0 lo / 1 hi, esi=row j 0..s) -> eax = vertex: row 0 = F1's
#   corner point, row s = F2's, between: the arc. Edge ends at build_bevel's
#   [rsp+8+32 / 36], slot at [rsp+8+40] (one level up).
strip_pt:
    push    rbx
    push    r12
    push    r13
    mov     r12d, edi
    mov     r13d, esi
    test    esi, esi
    jz      1f
    cmp     esi, [rip+bv_seg]
    jae     2f
    mov     ecx, [rsp+24+8+40]          # arc[slot][end][j - 1]
    mov     edx, [rip+bv_seg]
    dec     edx
    imul    ecx, edx
    shl     ecx, 1
    mov     eax, r12d
    imul    eax, edx
    add     ecx, eax
    add     ecx, r13d
    dec     ecx
    mov     rdx, [rip+bv_arc]
    mov     eax, [rdx+rcx*4]
    jmp     9f
1:  mov     rcx, [rip+ef_f1]
    jmp     3f
2:  mov     rcx, [rip+ef_f2]
3:  mov     eax, [rsp+24+8+40]
    mov     edi, [rcx+rax*4]
    mov     esi, [rsp+24+8+32+r12*4]
    call    corner_of
    mov     rcx, [rip+bv_cpt]
    mov     eax, [rcx+rax*4]
9:  pop     r13
    pop     r12
    pop     rbx
    ret

# strip_orient - the quad at build_bevel's [rsp+8+56..68] (row 0 on F1's
#   side) must run against F1 along the edge (slot [rsp+8+40], ends [rsp+8+
#   32 / 36]): F1 walks end 0 -> end 1, so the strip walks back - decided
#   by the topology, not by the quad's shape (which twists next to slivers)
strip_orient:
    push    r12
    push    r13
    sub     rsp, 40
    mov     rcx, [rip+ef_f1]
    mov     eax, [rsp+64+40]
    mov     r12d, [rcx+rax*4]           # F1
    mov     edi, r12d
    mov     esi, [rsp+64+32]            # where end 0 is in F1
    call    corner_of
    mov     r8, [rbx+ME_POFF]
    lea     ecx, [rax+1]                # the corner after it
    cmp     ecx, [r8+r12*4+4]
    jb      1f
    mov     ecx, [r8+r12*4]
1:  mov     r9, [rbx+ME_LOOPS]
    mov     ecx, [r9+rcx*4]
    lea     r8, [rsp+64+56]
    cmp     ecx, [rsp+64+36]            # F1 walks end 0 -> end 1: reverse
    jne     9f
    mov     ecx, [r8+4]                 # p0 p3 p2 p1
    mov     edx, [r8+12]
    mov     [r8+4], edx
    mov     [r8+12], ecx
9:  add     rsp, 40
    pop     r13
    pop     r12
    ret

# corner_patch(edi=vertex) - walk the faces around v, collecting their
#   points and the arcs between them; three or more distinct points close
#   the hole with a polygon (oriented like the faces around it)
corner_patch:
    push    r12
    push    r13
    push    r14
    push    r15
    push    rbp
    sub     rsp, 48
    mov     r12d, edi
    # a face containing v, preferably at the start of an open fan
    mov     rsi, [rbx+ME_LOOPS]
    xor     ecx, ecx
1:  cmp     ecx, [rbx+ME_NLOOPS]
    jae     .Lcpa_out
    cmp     [rsi+rcx*4], r12d
    je      2f
    inc     ecx
    jmp     1b
2:  mov     edi, ecx
    call    loop_face                   # eax = polygon of loop ecx
    mov     r13d, eax                   # start face
    # rewind: step backwards (across the edge entering v) until a boundary
    mov     r14d, r13d
    xor     r15d, r15d                  # guard
3:  inc     r15d
    cmp     r15d, 256
    ja      4f
    mov     edi, r14d
    mov     esi, r12d
    call    corner_of
    mov     edi, eax
    call    prev_vert                   # eax = u (the vertex before v)
    mov     edi, r12d
    mov     esi, eax
    call    other_face                  # across (u, v), not r14
    test    eax, eax
    js      4f
    cmp     eax, r13d
    je      41f                         # closed fan: any start is fine
    mov     r14d, eax
    jmp     3b
41: mov     r14d, r13d
4:  mov     r13d, r14d                  # walk forward from r13
    xor     ebp, ebp                    # points in scr
    xor     r15d, r15d
5:  inc     r15d
    cmp     r15d, 256
    ja      .Lcpa_close
    mov     [rsp], r14d
    mov     edi, r14d                   # this face's representation at v
    mov     esi, r12d
    call    corner_of
    mov     [rsp+4], eax
    call    rep_of_loop                 # appends to scr (1 or 2 points)
    mov     edi, [rsp+4]
    call    next_vert                   # w: the next edge (v, w)
    mov     [rsp+8], eax
    mov     edi, r12d
    mov     esi, eax
    call    is_bev
    test    eax, eax
    jz      6f
    mov     edi, r12d                   # arcs across (v, w) from this face
    mov     esi, [rsp+8]
    mov     edx, [rsp]
    call    append_arc
6:  mov     edi, r12d                   # next face across (v, w)
    mov     esi, [rsp+8]
    mov     r14d, [rsp]
    call    other_face
    test    eax, eax
    js      .Lcpa_close
    cmp     eax, r13d
    je      .Lcpa_close
    mov     r14d, eax
    jmp     5b
.Lcpa_close:
    call    dedupe_scr
    cmp     ebp, 3
    jb      .Lcpa_out
    # orientation: face it like the first face around v
    mov     rdi, rbx
    mov     esi, r13d
    call    poly_normal
    mov     rax, [rip+nrm]
    mov     [rsp+16], rax
    mov     eax, [rip+nrm+8]
    mov     [rsp+24], eax
    call    scr_normal                  # nrm = Newell of scr points (in r14 dst)
    movss   xmm0, [rip+nrm]
    mulss   xmm0, [rsp+16]
    movss   xmm1, [rip+nrm+4]
    mulss   xmm1, [rsp+20]
    addss   xmm0, xmm1
    movss   xmm1, [rip+nrm+8]
    mulss   xmm1, [rsp+24]
    addss   xmm0, xmm1
    xorps   xmm1, xmm1
    comiss  xmm0, xmm1
    jae     7f
    lea     rsi, [rip+scr]              # reverse
    xor     ecx, ecx
    lea     edx, [rbp-1]
61: cmp     ecx, edx
    jge     7f
    mov     eax, [rsi+rcx*4]
    mov     r8d, [rsi+rdx*4]
    mov     [rsi+rcx*4], r8d
    mov     [rsi+rdx*4], eax
    inc     ecx
    dec     edx
    jmp     61b
7:  mov     rdi, [rip+bv_dst]
    lea     rsi, [rip+scr]
    mov     edx, ebp
    call    mesh_add_poly
.Lcpa_out:
    add     rsp, 48
    pop     rbp
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    ret

# loop_face(edi=loop) -> eax = polygon (binary search over offsets)
loop_face:
    mov     r8, [rbx+ME_POFF]
    xor     ecx, ecx
    mov     edx, [rbx+ME_NPOLYS]
1:  mov     eax, edx
    sub     eax, ecx
    cmp     eax, 1
    jbe     2f
    lea     eax, [rcx+rdx]
    shr     eax, 1
    cmp     [r8+rax*4], edi
    ja      11f
    mov     ecx, eax
    jmp     1b
11: mov     edx, eax
    jmp     1b
2:  mov     eax, ecx
    ret

# prev_vert(edi=loop) / next_vert(edi=loop) -> eax = neighbouring vertex
prev_vert:
    push    rdi
    call    loop_face
    pop     rdi
    mov     r8, [rbx+ME_POFF]
    mov     ecx, [r8+rax*4]
    lea     edx, [rdi-1]
    cmp     edx, ecx
    jge     1f
    mov     edx, [r8+rax*4+4]
    dec     edx
1:  mov     r8, [rbx+ME_LOOPS]
    mov     eax, [r8+rdx*4]
    ret
next_vert:
    push    rdi
    call    loop_face
    pop     rdi
    mov     r8, [rbx+ME_POFF]
    lea     edx, [rdi+1]
    cmp     edx, [r8+rax*4+4]
    jb      1f
    mov     edx, [r8+rax*4]
1:  mov     r8, [rbx+ME_LOOPS]
    mov     eax, [r8+rdx*4]
    ret

# other_face(edi=a, esi=b, r14d=this face) -> eax = the face across, or -1
other_face:
    sub     rsp, 8
    call    ef_find
    add     rsp, 8
    test    eax, eax
    js      9f
    mov     rcx, [rip+ef_cnt]
    cmp     dword ptr [rcx+rax*4], 2
    jne     8f
    mov     rcx, [rip+ef_f1]
    mov     edx, [rcx+rax*4]
    cmp     edx, r14d
    jne     1f
    mov     rcx, [rip+ef_f2]
    mov     edx, [rcx+rax*4]
1:  mov     eax, edx
    ret
8:  mov     eax, -1
9:  ret

# rep_of_loop(eax=loop) - like corner_rep, for corner_patch (appends at ebp)
rep_of_loop:
    mov     rcx, [rip+bv_cpt]
    mov     edx, [rcx+rax*4]
    test    edx, edx
    js      1f
    lea     rcx, [rip+scr]
    mov     [rcx+rbp*4], edx
    inc     ebp
    ret
1:  push    r12
    push    r13
    sub     rsp, 8
    mov     r12d, eax
    mov     edi, eax
    call    prev_vert
    mov     r13d, eax
    mov     rsi, [rbx+ME_LOOPS]
    mov     edi, [rsi+r12*4]            # v
    mov     esi, r13d
    call    along_or_v
    lea     rcx, [rip+scr]
    mov     [rcx+rbp*4], eax
    inc     ebp
    mov     edi, r12d
    call    next_vert
    mov     esi, eax
    mov     rcx, [rbx+ME_LOOPS]
    mov     edi, [rcx+r12*4]
    call    along_or_v
    lea     rcx, [rip+scr]
    mov     [rcx+rbp*4], eax
    inc     ebp
    add     rsp, 8
    pop     r13
    pop     r12
    ret

# append_arc(edi=v, esi=w, edx=face we come from) - the arc points at v of
#   the beveled edge (v, w), ordered from that face's side
append_arc:
    push    r12
    push    r13
    push    r14
    push    r15
    sub     rsp, 8
    cmp     dword ptr [rip+bv_seg], 1
    jbe     9f
    mov     r12d, edi
    mov     r13d, esi
    mov     r15d, edx
    call    ef_find
    test    eax, eax
    js      9f
    mov     r14d, eax                   # slot
    xor     ecx, ecx                    # end: 0 if v is the lower index
    cmp     r12d, r13d
    jb      1f
    mov     ecx, 1
1:  mov     edx, [rip+bv_seg]
    dec     edx                         # s - 1 arcs
    mov     eax, r14d
    imul    eax, edx
    shl     eax, 1
    mov     r8d, ecx
    imul    r8d, edx
    add     eax, r8d
    mov     rsi, [rip+bv_arc]
    lea     rsi, [rsi+rax*4]            # arcs j = 1 .. s-1 (F1 -> F2)
    mov     rcx, [rip+ef_f1]
    cmp     [rcx+r14*4], r15d
    jne     3f
    xor     ecx, ecx                    # from F1: ascending
2:  cmp     ecx, edx
    jae     9f
    mov     eax, [rsi+rcx*4]
    lea     r8, [rip+scr]
    mov     [r8+rbp*4], eax
    inc     ebp
    inc     ecx
    jmp     2b
3:  mov     ecx, edx                    # from F2: descending
4:  test    ecx, ecx
    jz      9f
    dec     ecx
    mov     eax, [rsi+rcx*4]
    lea     r8, [rip+scr]
    mov     [r8+rbp*4], eax
    inc     ebp
    jmp     4b
9:  add     rsp, 8
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    ret

# scr_normal - nrm = Newell normal of the points scr[0..ebp) of bv_dst
scr_normal:
    mov     r8, [rip+bv_dst]
    mov     r8, [r8+ME_POS]
    lea     r9, [rip+scr]
    xorps   xmm0, xmm0
    xorps   xmm1, xmm1
    xorps   xmm2, xmm2
    xor     ecx, ecx
1:  cmp     ecx, ebp
    jae     2f
    mov     eax, [r9+rcx*4]
    lea     edx, [rcx+1]
    cmp     edx, ebp
    jb      11f
    xor     edx, edx
11: mov     edx, [r9+rdx*4]
    lea     rax, [rax+rax*2]
    lea     rax, [r8+rax*4]
    lea     rdx, [rdx+rdx*2]
    lea     rdx, [r8+rdx*4]
    movss   xmm3, [rax+4]
    subss   xmm3, [rdx+4]
    movss   xmm4, [rax+8]
    addss   xmm4, [rdx+8]
    mulss   xmm3, xmm4
    addss   xmm0, xmm3
    movss   xmm3, [rax+8]
    subss   xmm3, [rdx+8]
    movss   xmm4, [rax]
    addss   xmm4, [rdx]
    mulss   xmm3, xmm4
    addss   xmm1, xmm3
    movss   xmm3, [rax]
    subss   xmm3, [rdx]
    movss   xmm4, [rax+4]
    addss   xmm4, [rdx+4]
    mulss   xmm3, xmm4
    addss   xmm2, xmm3
    inc     ecx
    jmp     1b
2:  movss   [rip+nrm], xmm0
    movss   [rip+nrm+4], xmm1
    movss   [rip+nrm+8], xmm2
    ret

.section .rodata
.align 16
m2_absm:        .long 0x7fffffff, 0, 0, 0
m2_big:         .float 1.0e30
m2_360:         .float 360.0
m2_359:         .float 359.9

.section .note.GNU-stack,"",@progbits
