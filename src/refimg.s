# =============================================================================
#  BeeModel - reference images (W8): a photo or drawing to model over.
#
#  Add > Reference Image... (object.add_reference <file>) loads the image
#  and adds a flat object at the 3D cursor, square to the view's nearest axis
#  (front, side or top), at the image's aspect ratio. It is a 2 x 2 plane
#  flagged OBF_REFIMG, left out of renders (its camera off), with a material
#  of its own that carries the image (an image node) and the opacity (its
#  alpha). The rasterizer leaves it out; ref_draw paints it in every shading
#  mode, in screen space: the quad projected, its pixels mapped back to the
#  image (perspective-correct), blended at the opacity, either behind the
#  scene (where no object is) or in front of it. Its flags:
#    OBF_REF_FRONT  in front of the scene (else behind)
#    OBF_REF_ORTHO  only in orthographic views
#    OBF_REF_AXIS   only when seen square-on (as in Blender's front / side
#                   / top references)
#    OBF_REF_BACK   seen from behind too (else from the front only)
#  It is picked in the viewport by its outline (vp_pick_bounds), moved,
#  turned and scaled like any object; Properties > Object shows its settings.
# =============================================================================
.intel_syntax noprefix
.include "const.inc"
.include "macros.inc"
.include "widgets.inc"

.globl ref_draw
.globl ref_props
.globl ref_image_of

.equ IM_W_,     0                       # (imgread.s)
.equ IM_H_,     4
.equ IM_FMT_,   8
.equ IM_DATA_,  64
.equ MA_BASE_,  32                      # (material.s)
.equ MA_ALPHA_, 88
.equ GR_NODES_, 160                     # (graph.s)
.equ GR_N_,     128
.equ NODE_SZ_,  72
.equ ND_P_,     52

.section .bss
.align 16
rf_m:           .skip 48                # the object's matrix
rf_w:           .skip 4*12              # its corners: world,
rf_c:           .skip 4*12              #  camera space,
rf_s:           .skip 4*8               #  the screen
rf_tmp:         .skip 16
.align 4
rf_opacity:     .skip 4                 # the panel's values
rf_depth:       .skip 4
rf_sides:       .skip 4
rf_ortho:       .skip 4
rf_axis:        .skip 4
rf_name:        .skip 64

.section .rodata
.align 4
rf_corner:      .float -1, 0, -1,   1, 0, -1,   1, 0, 1,   -1, 0, 1
rf_one:         .float 1.0
rf_half:        .float 0.5
rf_255:         .float 255.0
rf_near:        .float 0.01
rf_sq:          .float 0.985            # square-on: the normal within ~10 degrees
rf_absm:        .long 0x7fffffff
s_ref_mat:      .asciz "Reference "
s_ref_base:     .asciz "Reference"
s_ref_load:     .asciz "  reference image: could not load it"
s_c_ref:        .asciz "Reference image"
s_c_depth:      .asciz "Drawn"
s_c_sides:      .asciz "Seen from"
s_d_behind:     .asciz "Behind the scene"
s_d_front:      .asciz "In front of it"
s_s_both:       .asciz "Both sides"
s_s_front:      .asciz "The front only"
.align 8
l_depth:        .quad s_d_behind, s_d_front
l_sides:        .quad s_s_both, s_s_front

.text
OPERATOR op_ref_add, "object.add_reference", "Reference Image...", do_ref_add, flags=OPF_UNDO, doc="A reference image to model over: object.add_reference <image file> (PNG, JPEG, HDR) - a flat object at the 3D cursor, square to the view, not rendered", form=form_refadd
WIDGET wd_ref_op,    WK_SLIDER, "reference.opacity", "Opacity", 0.0, 1.0, 0.005, 2, WGF_CLAMP, cb=ref_op_cb, undo="Reference Image", def=1.0
WIDGET wd_ref_depth, WK_ENUM, "reference.depth", cb=ref_flag_cb, undo="Reference Image", aux=l_depth, n=2, tip="Behind the scene: objects cover it. In front: it covers them (to trace)"
WIDGET wd_ref_sides, WK_ENUM, "reference.sides", cb=ref_flag_cb, undo="Reference Image", aux=l_sides, n=2
WIDGET wd_ref_ortho, WK_TOGGLE, "reference.ortho_only", "Only in orthographic views", cb=ref_flag_cb, undo="Reference Image"
WIDGET wd_ref_axis,  WK_TOGGLE, "reference.axis_only", "Only when seen square-on", cb=ref_flag_cb, undo="Reference Image", tip="As a front, side or top reference: hidden when the view turns away"

# ---- adding one ---------------------------------------------------------------------
# do_ref_add - object.add_reference <file>
do_ref_add:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    sub     rsp, 32
    mov     rdi, [rip+op_arg]
    test    rdi, rdi
    jz      .Lra_no
    cmp     byte ptr [rdi], 0
    je      .Lra_no
    call    path_expand_any
    mov     rdi, rax
    call    image_load                  # -> its index
    test    eax, eax
    js      .Lra_no
    mov     r12d, eax
    mov     edi, eax
    call    image_ptr
    test    rax, rax
    jz      .Lra_no
    cvtsi2ss xmm0, dword ptr [rax+IM_W_] # aspect = w / h
    cvtsi2ss xmm1, dword ptr [rax+IM_H_]
    divss   xmm0, xmm1
    movss   [rsp], xmm0
    call    prim_plane                  # the plane, named after the image
    mov     rdx, rax
    mov     edi, OT_MESH
    lea     rsi, [rip+s_ref_base]
    call    obj_new
    test    eax, eax
    jz      .Lra_no
    mov     r13d, eax
    mov     edi, eax
    call    obj_get
    mov     r14, rax
    or      dword ptr [r14+OB_FLAGS], OBF_REFIMG|OBF_NORENDER|OBF_REF_BACK
    mov     dword ptr [r14+OB_COLOR], 0x808080
    lea     rsi, [rip+cursor_pos]       # at the 3D cursor
    mov     rax, [rsi]
    mov     [r14+OB_LOC], rax
    mov     eax, [rsi+8]
    mov     [r14+OB_LOC+8], eax
    movss   xmm0, [rip+cam_dist]        # as big as a third of the view
    mulss   xmm0, [rip+rf_third]
    movss   xmm1, xmm0
    mulss   xmm1, [rsp]
    movss   [r14+OB_SCALE], xmm1
    mov     eax, [rip+rf_one]
    mov     [r14+OB_SCALE+4], eax
    movss   [r14+OB_SCALE+8], xmm0
    mov     rdi, r14                    # square to the view's nearest axis
    call    ref_face_view
    mov     edi, r12d                   # its material: the image, opaque
    mov     rsi, r14
    call    ref_material
    mov     edi, r13d                   # the new one alone selected, active
    xor     esi, esi
    call    obj_click_select
    mov     dword ptr [rip+dirty], 1
    jmp     .Lra_out
.Lra_no:
    lea     rdi, [rip+s_ref_load]
    call    log_line
.Lra_out:
    add     rsp, 32
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

path_expand_any:                        # rdi = a path (~ works) -> rax
    jmp     path_expand

.section .rodata
.align 4
rf_third:       .float 0.33
rf_90:          .float 1.5707963
rf_180:         .float 3.1415927
.text

# ref_face_view(rdi=object) - its plane (normal +Y, the image's top at its
#   -Z) turned to face the view, square to its nearest axis, the image upright
ref_face_view:
    xorps   xmm0, xmm0                  # rotation x, y = 0
    movss   [rdi+OB_ROT], xmm0
    movss   [rdi+OB_ROT+4], xmm0
    movss   [rdi+OB_ROT+8], xmm0
    movss   xmm0, [rip+fwd]             # the view looks along fwd: the plane
    movss   xmm1, [rip+fwd+4]           #  faces -fwd
    movss   xmm2, [rip+fwd+8]
    movss   xmm3, xmm0
    andps   xmm3, [rip+rf_absm4]
    movss   xmm4, xmm1
    andps   xmm4, [rip+rf_absm4]
    movss   xmm5, xmm2
    andps   xmm5, [rip+rf_absm4]
    comiss  xmm4, xmm3                  # mostly up or down: top / bottom
    jb      2f
    comiss  xmm4, xmm5
    jb      2f
    xorps   xmm6, xmm6                  # looking down (fwd.y < 0): as it is
    comiss  xmm1, xmm6
    jb      9f
    mov     eax, [rip+rf_180]           # looking up: over
    mov     [rdi+OB_ROT], eax
    ret
2:  mov     eax, [rip+rf_90]            # a side view: stood up (x 90 deg),
    mov     [rdi+OB_ROT], eax           #  then turned about y to face it
    comiss  xmm3, xmm5
    jb      3f
    xorps   xmm6, xmm6                  # along x: fwd.x < 0 -> faces +x
    comiss  xmm0, xmm6
    mov     eax, [rip+rf_90]
    jb      21f
    mov     eax, [rip+rf_90]
    xor     eax, 0x80000000             # -90 deg
21: mov     [rdi+OB_ROT+4], eax
    ret
3:  xorps   xmm6, xmm6                  # along z: fwd.z < 0 -> faces +z (as
    comiss  xmm2, xmm6                  #  stood up)
    jb      9f
    mov     eax, [rip+rf_180]
    mov     [rdi+OB_ROT+4], eax
9:  ret

.section .rodata
.align 16
rf_absm4:       .long 0x7fffffff, 0x7fffffff, 0x7fffffff, 0x7fffffff
.text

# ref_material(edi=image index, rsi=object) - the object gets a material of
#   its own: "Reference <image>", an image node into the base colour
ref_material:
    push    rbx
    push    r12
    push    r13
    push    r14
    sub     rsp, 24
    mov     ebx, edi
    mov     r14, rsi
    call    fmt_reset                   # "Reference <image>"
    lea     rdi, [rip+s_ref_mat]
    call    fmt_str
    mov     edi, ebx
    call    image_rec
    mov     rdi, rax
    call    fmt_str
    lea     rdi, [rip+fmt_buf]
    call    mat_new
    test    eax, eax
    js      9f
    mov     r12d, eax
    mov     edi, r12d                   # the image node
    mov     esi, 1
    call    graph_add
    test    eax, eax
    js      9f
    mov     r13d, eax
    lea     eax, [rbx+1]                #  its image (+ 1)
    cvtsi2ss xmm0, eax
    movss   [rsp], xmm0
    mov     edi, r12d
    mov     esi, r13d
    mov     edx, 4
    lea     rcx, [rsp]
    mov     r8d, 1
    call    graph_set
    mov     edi, r12d                   #  into the base colour
    xor     esi, esi
    mov     edx, r13d
    xor     ecx, ecx
    call    graph_socket
    mov     rdi, r14
    mov     esi, r12d
    call    mat_assign
9:  add     rsp, 24
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# ref_image_of(rdi=object) -> rax = its image (the first image node of its
#   material), or 0; xmm0 = its opacity
ref_image_of:
    push    rbx
    sub     rsp, 16
    call    mat_of
    test    eax, eax
    js      8f
    mov     edi, eax
    call    mat_get
    test    rax, rax
    jz      8f
    mov     rbx, rax
    movss   xmm0, [rbx+MA_ALPHA_]
    movss   [rsp], xmm0
    xor     ecx, ecx
1:  cmp     ecx, [rbx+GR_N_]
    jae     8f
    imul    edx, ecx, NODE_SZ_
    mov     eax, [rbx+GR_NODES_+rdx]
    and     eax, 0x7fffffff
    cmp     eax, 1                      # an image node: p0 = image + 1
    jne     2f
    cvttss2si edi, dword ptr [rbx+GR_NODES_+rdx+ND_P_]
    dec     edi
    js      2f
    call    image_ptr
    test    rax, rax
    jz      8f
    movss   xmm0, [rsp]
    add     rsp, 16
    pop     rbx
    ret
2:  inc     ecx
    jmp     1b
8:  xor     eax, eax
    xorps   xmm0, xmm0
    add     rsp, 16
    pop     rbx
    ret

# =============================================================================
#  Drawing
# =============================================================================
# ref_draw - every reference image, in the viewport being drawn (after its
#   meshes: the ID buffer says where objects are)
ref_draw:
    push    rbx
    push    r12
    sub     rsp, 8
    xor     ebx, ebx
1:  cmp     ebx, [rip+obj_count]
    jae     9f
    mov     edi, ebx
    call    obj_at
    inc     ebx
    test    rax, rax
    jz      1b
    mov     ecx, [rax+OB_FLAGS]
    test    ecx, OBF_REFIMG
    jz      1b
    test    ecx, OBF_HIDDEN
    jnz     1b
    test    ecx, OBF_REF_ORTHO          # orthographic views only
    jz      2f
    cmp     dword ptr [rip+cam_ortho], 0
    je      1b
2:  mov     rdi, rax
    call    ref_one
    jmp     1b
9:  add     rsp, 8
    pop     r12
    pop     rbx
    ret

# ref_one(rdi=object) - its quad, projected and filled
ref_one:
    push    rbx
    push    rbp
    push    r12
    push    r13
    push    r14
    push    r15
    sub     rsp, 120
    mov     rbx, rdi
    call    ref_image_of
    test    rax, rax
    jz      .Lro_out
    mov     r12, rax                    # the image
    movss   [rsp+64], xmm0              # the opacity
    xorps   xmm1, xmm1
    comiss  xmm0, xmm1
    jbe     .Lro_out
    mov     rdi, rbx                    # its corners: world, camera
    lea     rsi, [rip+rf_m]
    call    obj_matrix
    xor     r13d, r13d
1:  lea     rdi, [rip+rf_m]
    lea     rsi, [rip+rf_corner]
    lea     rsi, [rsi+r13*4]
    lea     rdx, [rip+rf_w]
    lea     rdx, [rdx+r13*4]
    call    xform_point
    lea     rdi, [rip+rf_w]
    lea     rdi, [rdi+r13*4]
    lea     rsi, [rip+rf_c]
    lea     rsi, [rsi+r13*4]
    call    to_cam
    lea     rax, [rip+rf_c]             # (behind the eye: not drawn)
    movss   xmm0, [rax+r13*4+8]
    comiss  xmm0, [rip+rf_near]
    jb      .Lro_out
    add     r13d, 3
    cmp     r13d, 12
    jb      1b
    lea     rax, [rip+rf_c]             # its normal (camera space): which side
    movss   xmm0, [rax+12]              #  faces the eye; square-on?
    subss   xmm0, [rax]                 # e1 = c1 - c0, e2 = c3 - c0
    movss   xmm1, [rax+16]
    subss   xmm1, [rax+4]
    movss   xmm2, [rax+20]
    subss   xmm2, [rax+8]
    movss   xmm3, [rax+36]
    subss   xmm3, [rax]
    movss   xmm4, [rax+40]
    subss   xmm4, [rax+4]
    movss   xmm5, [rax+44]
    subss   xmm5, [rax+8]
    movss   xmm6, xmm1                  # n = e1 x e2
    mulss   xmm6, xmm5
    movss   xmm7, xmm2
    mulss   xmm7, xmm4
    subss   xmm6, xmm7                  # nx
    movss   xmm7, xmm2
    mulss   xmm7, xmm3
    movss   xmm8, xmm0
    mulss   xmm8, xmm5
    subss   xmm7, xmm8                  # ny
    movss   xmm8, xmm0
    mulss   xmm8, xmm4
    movss   xmm9, xmm1
    mulss   xmm9, xmm3
    subss   xmm8, xmm9                  # nz
    movss   xmm9, xmm6                  # (to the eye: -c0 . n > 0 is the front)
    mulss   xmm9, [rax]
    movss   xmm10, xmm7
    mulss   xmm10, [rax+4]
    addss   xmm9, xmm10
    movss   xmm10, xmm8
    mulss   xmm10, [rax+8]
    addss   xmm9, xmm10
    test    dword ptr [rbx+OB_FLAGS], OBF_REF_BACK
    jnz     2f
    xorps   xmm10, xmm10                # the front only: c0 . n < 0 (its +Y
    comiss  xmm9, xmm10                 #  side towards the eye)
    jb      2f
    jmp     .Lro_out
2:  test    dword ptr [rbx+OB_FLAGS], OBF_REF_AXIS
    jz      3f
    movss   xmm10, xmm6                 # square-on: |nz| / |n| near 1
    mulss   xmm10, xmm6
    movss   xmm11, xmm7
    mulss   xmm11, xmm7
    addss   xmm10, xmm11
    movss   xmm11, xmm8
    mulss   xmm11, xmm8
    addss   xmm10, xmm11
    sqrtss  xmm10, xmm10
    andps   xmm8, [rip+rf_absm4]
    divss   xmm8, xmm10
    comiss  xmm8, [rip+rf_sq]
    jb      .Lro_out
3:  xor     r13d, r13d                  # the screen
4:  lea     rdi, [rip+rf_c]
    lea     eax, [r13+r13*2]
    lea     rdi, [rdi+rax*4]
    lea     rsi, [rip+rf_s]
    lea     rsi, [rsi+r13*8]
    call    project
    inc     r13d
    cmp     r13d, 4
    jb      4b
    # two triangles: (0 1 2) and (0 2 3), uv (0,0) (1,0) (1,1) (0,1)
    xor     r13d, r13d
5:  mov     edi, r13d
    call    ref_tri
    inc     r13d
    cmp     r13d, 2
    jb      5b
    test    dword ptr [rbx+OB_FLAGS], OBF_SELECTED  # selected: its outline
    jz      .Lro_out
    xor     r13d, r13d
6:  lea     rsi, [rip+rf_w]
    imul    eax, r13d, 12
    mov     rcx, [rsi+rax]
    mov     [rip+lp0], rcx
    mov     ecx, [rsi+rax+8]
    mov     [rip+lp0+8], ecx
    lea     eax, [r13+1]
    and     eax, 3
    imul    eax, eax, 12
    mov     rcx, [rsi+rax]
    mov     [rip+lp1], rcx
    mov     ecx, [rsi+rax+8]
    mov     [rip+lp1+8], ecx
    mov     edx, COL_SELECTED
    call    line3d
    inc     r13d
    cmp     r13d, 4
    jb      6b
.Lro_out:
    add     rsp, 120
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbp
    pop     rbx
    ret

# ref_tri(edi=0: corners 0 1 2, 1: corners 0 2 3) - its pixels (rbx object,
#   r12 image, [rsp+8+64+8..] the caller's opacity) mapped to the image and
#   blended into the framebuffer
ref_tri:
    push    rbp
    push    r13
    push    r14
    push    r15
    sub     rsp, 136
    lea     rax, [rip+rf_tri_idx]       # the three corners
    lea     rax, [rax+rdi*8]
    mov     ecx, [rax]
    mov     [rsp], ecx                  # (corner indices packed in bytes)
    movss   xmm0, [rsp+136+32+8+64]     # the opacity (ref_one's [rsp+64])
    movss   [rsp+4], xmm0
    xor     r13d, r13d                  # for each corner k: sx sy, 1/z, u/z,
7:  movzx   eax, byte ptr [rsp+r13]     #  v/z at [rsp+16+k*20]
    lea     rcx, [rip+rf_s]
    movss   xmm0, [rcx+rax*8]
    movss   xmm1, [rcx+rax*8+4]
    lea     rcx, [rip+rf_c]
    lea     edx, [rax+rax*2]
    movss   xmm2, [rip+rf_one]
    divss   xmm2, [rcx+rdx*4+8]         # 1/z
    lea     rcx, [rip+rf_uv]
    movss   xmm3, [rcx+rax*8]
    mulss   xmm3, xmm2
    movss   xmm4, [rcx+rax*8+4]
    mulss   xmm4, xmm2
    imul    edx, r13d, 20
    movss   [rsp+16+rdx], xmm0
    movss   [rsp+16+rdx+4], xmm1
    movss   [rsp+16+rdx+8], xmm2
    movss   [rsp+16+rdx+12], xmm3
    movss   [rsp+16+rdx+16], xmm4
    inc     r13d
    cmp     r13d, 3
    jb      7b
    # the area (twice), its sign
    movss   xmm0, [rsp+16+20]           # (x1 - x0)(y2 - y0) - (x2 - x0)(y1 - y0)
    subss   xmm0, [rsp+16]
    movss   xmm1, [rsp+16+40+4]
    subss   xmm1, [rsp+16+4]
    mulss   xmm0, xmm1
    movss   xmm1, [rsp+16+40]
    subss   xmm1, [rsp+16]
    movss   xmm2, [rsp+16+20+4]
    subss   xmm2, [rsp+16+4]
    mulss   xmm1, xmm2
    subss   xmm0, xmm1
    movss   [rsp+8], xmm0
    andps   xmm0, [rip+rf_absm4]
    comiss  xmm0, [rip+rf_tiny]
    jb      .Lrt_out
    # the bounding box, clipped
    movss   xmm0, [rsp+16]
    minss   xmm0, [rsp+36]
    minss   xmm0, [rsp+56]
    cvttss2si ebp, xmm0
    movss   xmm0, [rsp+16]
    maxss   xmm0, [rsp+36]
    maxss   xmm0, [rsp+56]
    cvttss2si r14d, xmm0
    inc     r14d
    movss   xmm0, [rsp+20]
    minss   xmm0, [rsp+40]
    minss   xmm0, [rsp+60]
    cvttss2si r13d, xmm0
    movss   xmm0, [rsp+20]
    maxss   xmm0, [rsp+40]
    maxss   xmm0, [rsp+60]
    cvttss2si r15d, xmm0
    inc     r15d
    cmp     ebp, [rip+clip_x0]
    jge     1f
    mov     ebp, [rip+clip_x0]
1:  cmp     r14d, [rip+clip_x1]
    jle     2f
    mov     r14d, [rip+clip_x1]
2:  cmp     r13d, [rip+clip_y0]
    jge     3f
    mov     r13d, [rip+clip_y0]
3:  cmp     r15d, [rip+clip_y1]
    jle     4f
    mov     r15d, [rip+clip_y1]
4:  mov     [rsp+80], ebp               # x0 (kept)
.Lrt_row:
    cmp     r13d, r15d
    jge     .Lrt_out
    mov     ebp, [rsp+80]
.Lrt_px:
    cmp     ebp, r14d
    jge     .Lrt_rownext
    cvtsi2ss xmm6, ebp                  # the pixel's centre
    addss   xmm6, [rip+rf_half]
    cvtsi2ss xmm7, r13d
    addss   xmm7, [rip+rf_half]
    # barycentrics: w0 = edge(1,2), w1 = edge(2,0), w2 = edge(0,1), / area
    lea     rax, [rsp+16]
    mov     ecx, 20
    mov     edx, 40
    call    rt_edge                     # (1, 2) -> xmm0
    movss   xmm8, xmm0
    lea     rax, [rsp+16]
    mov     ecx, 40
    xor     edx, edx
    call    rt_edge                     # (2, 0)
    movss   xmm9, xmm0
    lea     rax, [rsp+16]
    xor     ecx, ecx
    mov     edx, 20
    call    rt_edge                     # (0, 1)
    movss   xmm10, xmm0
    divss   xmm8, [rsp+8]
    divss   xmm9, [rsp+8]
    divss   xmm10, [rsp+8]
    xorps   xmm11, xmm11
    comiss  xmm8, xmm11
    jb      .Lrt_next
    comiss  xmm9, xmm11
    jb      .Lrt_next
    comiss  xmm10, xmm11
    jb      .Lrt_next
    test    dword ptr [rbx+OB_FLAGS], OBF_REF_FRONT  # behind: only where no
    jnz     5f                                       #  object is
    cmp     dword ptr [rip+vp_shading], 1
    je      5f
    mov     eax, r13d
    sub     eax, [rip+rs_y0]
    js      5f
    cmp     eax, [rip+rs_h]
    jae     5f
    mov     ecx, ebp
    sub     ecx, [rip+rs_x0]
    js      5f
    cmp     ecx, [rip+rs_w]
    jae     5f
    imul    eax, [rip+rs_w]
    add     eax, ecx
    mov     rcx, [rip+rs_id]
    test    rcx, rcx
    jz      5f
    cmp     dword ptr [rcx+rax*4], 0
    jne     .Lrt_next
5:  movss   xmm0, [rsp+16+8]            # 1/z, u/z, v/z interpolated
    mulss   xmm0, xmm8
    movss   xmm1, [rsp+36+8]
    mulss   xmm1, xmm9
    addss   xmm0, xmm1
    movss   xmm1, [rsp+56+8]
    mulss   xmm1, xmm10
    addss   xmm0, xmm1                  # 1/z
    movss   xmm1, [rsp+16+12]
    mulss   xmm1, xmm8
    movss   xmm2, [rsp+36+12]
    mulss   xmm2, xmm9
    addss   xmm1, xmm2
    movss   xmm2, [rsp+56+12]
    mulss   xmm2, xmm10
    addss   xmm1, xmm2
    divss   xmm1, xmm0                  # u
    movss   xmm2, [rsp+16+16]
    mulss   xmm2, xmm8
    movss   xmm3, [rsp+36+16]
    mulss   xmm3, xmm9
    addss   xmm2, xmm3
    movss   xmm3, [rsp+56+16]
    mulss   xmm3, xmm10
    addss   xmm2, xmm3
    divss   xmm2, xmm0                  # v
    cvtsi2ss xmm3, dword ptr [r12+IM_W_] # the image's pixel (nearest)
    mulss   xmm1, xmm3
    cvttss2si ecx, xmm1
    cvtsi2ss xmm3, dword ptr [r12+IM_H_]
    mulss   xmm2, xmm3
    cvttss2si eax, xmm2
    test    ecx, ecx                    # (clamped to the image)
    jns     50f
    xor     ecx, ecx
50: mov     edx, [r12+IM_W_]
    dec     edx
    cmp     ecx, edx
    jle     51f
    mov     ecx, edx
51: test    eax, eax
    jns     52f
    xor     eax, eax
52: mov     edx, [r12+IM_H_]
    dec     edx
    cmp     eax, edx
    jle     53f
    mov     eax, edx
53: imul    eax, [r12+IM_W_]
    add     eax, ecx
    call    rt_texel                    # -> eax 0xAARRGGBB
    mov     edx, eax                    # alpha = opacity x its own
    shr     edx, 24
    cvtsi2ss xmm0, edx
    divss   xmm0, [rip+rf_255]
    mulss   xmm0, [rsp+4]
    mov     ecx, r13d                   # blend into the framebuffer
    imul    ecx, [rip+fb_w]
    add     ecx, ebp
    mov     rdx, [rip+fb_ptr]
    lea     rdx, [rdx+rcx*4]
    mov     r8d, [rdx]
    xor     r9d, r9d                    # three channels
    xor     r10d, r10d
6:  mov     ecx, r9d
    shl     ecx, 3
    mov     r11d, eax
    shr     r11d, cl
    and     r11d, 255
    cvtsi2ss xmm1, r11d                 # the image's
    mov     r11d, r8d
    shr     r11d, cl
    and     r11d, 255
    cvtsi2ss xmm2, r11d                 # what is there
    subss   xmm1, xmm2
    mulss   xmm1, xmm0
    addss   xmm1, xmm2
    cvttss2si r11d, xmm1
    shl     r11d, cl
    or      r10d, r11d
    inc     r9d
    cmp     r9d, 3
    jb      6b
    mov     [rdx], r10d
.Lrt_next:
    inc     ebp
    jmp     .Lrt_px
.Lrt_rownext:
    inc     r13d
    jmp     .Lrt_row
.Lrt_out:
    add     rsp, 136
    pop     r15
    pop     r14
    pop     r13
    pop     rbp
    ret

# rt_edge(rax=corner table, ecx / edx = the two corners' offsets; xmm6 xmm7 =
#   the point) -> xmm0 = (xb - xa)(py - ya) - (yb - ya)(px - xa)
rt_edge:
    movss   xmm0, [rax+rdx]
    subss   xmm0, [rax+rcx]
    movss   xmm1, xmm7
    subss   xmm1, [rax+rcx+4]
    mulss   xmm0, xmm1
    movss   xmm1, [rax+rdx+4]
    subss   xmm1, [rax+rcx+4]
    movss   xmm2, xmm6
    subss   xmm2, [rax+rcx]
    mulss   xmm1, xmm2
    subss   xmm0, xmm1
    ret

# rt_texel(eax=pixel index; r12 image) -> eax = 0xAARRGGBB
rt_texel:
    cmp     dword ptr [r12+IM_FMT_], 0
    jne     1f
    mov     eax, [r12+IM_DATA_+rax*4]
    ret
1:  lea     rax, [rax+rax*2]            # HDR: roughly sRGB, opaque
    lea     rsi, [r12+IM_DATA_+rax*4]
    mov     eax, 0xff
    xor     ecx, ecx
2:  movss   xmm1, [rsi+rcx*4]
    xorps   xmm2, xmm2
    maxss   xmm1, xmm2
    minss   xmm1, [rip+rf_one]
    sqrtss  xmm1, xmm1
    mulss   xmm1, [rip+rf_255]
    cvttss2si edx, xmm1
    shl     eax, 8
    or      eax, edx
    inc     ecx
    cmp     ecx, 3
    jb      2b
    ret

.section .rodata
.align 4
rf_tri_idx:     .byte 0, 1, 2, 0, 0, 0, 0, 0
                .byte 0, 2, 3, 0, 0, 0, 0, 0
rf_uv:          .float 0, 0,  1, 0,  1, 1,  0, 1
rf_tiny:        .float 0.5
.text

# =============================================================================
#  Properties > Object: its settings (r12d = y; pnl_ set)
# =============================================================================
# ref_props(edi=y, rsi=object) -> eax = y below
ref_props:
    push    rbx
    push    r12
    sub     rsp, 8
    mov     r12d, edi
    mov     rbx, rsi
    call    pnl_begin
    add     r12d, 6
    lea     rdx, [rip+s_c_ref]
    call    pnl_heading
    mov     rdi, rbx
    call    ref_image_of
    movss   [rip+rf_opacity], xmm0
    mov     eax, [rbx+OB_FLAGS]
    xor     ecx, ecx
    test    eax, OBF_REF_FRONT
    setnz   cl
    mov     [rip+rf_depth], ecx
    xor     ecx, ecx
    test    eax, OBF_REF_BACK
    setz    cl
    mov     [rip+rf_sides], ecx
    xor     ecx, ecx
    test    eax, OBF_REF_ORTHO
    setnz   cl
    mov     [rip+rf_ortho], ecx
    xor     ecx, ecx
    test    eax, OBF_REF_AXIS
    setnz   cl
    mov     [rip+rf_axis], ecx
    lea     rdi, [rip+wd_ref_op]
    lea     r8, [rip+rf_opacity]
    call    pnl_full
    lea     rdx, [rip+s_c_depth]
    call    pnl_caption
    lea     rdi, [rip+wd_ref_depth]
    lea     r8, [rip+rf_depth]
    call    pnl_right
    add     r12d, WG_H+4
    lea     rdx, [rip+s_c_sides]
    call    pnl_caption
    lea     rdi, [rip+wd_ref_sides]
    lea     r8, [rip+rf_sides]
    call    pnl_right
    add     r12d, WG_H+4
    lea     rdi, [rip+wd_ref_ortho]
    lea     r8, [rip+rf_ortho]
    call    pnl_full
    lea     rdi, [rip+wd_ref_axis]
    lea     r8, [rip+rf_axis]
    call    pnl_full
    mov     eax, r12d
    add     rsp, 8
    pop     r12
    pop     rbx
    ret

ref_op_cb:                              # the opacity: its material's alpha
    push    rbx
    sub     rsp, 16
    mov     edi, [rip+active_obj]
    call    obj_get
    test    rax, rax
    jz      9f
    mov     rdi, rax
    call    mat_of
    test    eax, eax
    js      9f
    mov     edi, eax                    # (mat_set: copied first when shared)
    mov     esi, 10                     # alpha
    xor     edx, edx
    movss   xmm0, [rip+rf_opacity]
    call    mat_set
    mov     dword ptr [rip+dirty], 1
9:  add     rsp, 16
    pop     rbx
    ret

ref_flag_cb:                            # depth, sides, ortho, axis: its flags
    sub     rsp, 8
    mov     edi, [rip+active_obj]
    call    obj_get
    add     rsp, 8
    test    rax, rax
    jz      9f
    and     dword ptr [rax+OB_FLAGS], ~(OBF_REF_FRONT|OBF_REF_BACK|OBF_REF_ORTHO|OBF_REF_AXIS)
    xor     ecx, ecx
    cmp     dword ptr [rip+rf_depth], 0
    je      1f
    or      ecx, OBF_REF_FRONT
1:  cmp     dword ptr [rip+rf_sides], 0
    jne     2f
    or      ecx, OBF_REF_BACK
2:  cmp     dword ptr [rip+rf_ortho], 0
    je      3f
    or      ecx, OBF_REF_ORTHO
3:  cmp     dword ptr [rip+rf_axis], 0
    je      4f
    or      ecx, OBF_REF_AXIS
4:  or      [rax+OB_FLAGS], ecx
    mov     dword ptr [rip+dirty], 1
9:  ret

.section .note.GNU-stack,"",@progbits
