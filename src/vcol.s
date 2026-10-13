# =============================================================================
#  BeeModel - vertex colours
#
#  A mesh may carry a colour per vertex (ME_VCOL, 0xAARRGGBB, sRGB). They
#  tint its material: the solid viewport multiplies each triangle's flat
#  colour by its corners' average; the material preview and the path
#  tracer multiply the base colour by the colour interpolated across the
#  triangle (in linear light).
#
#  Vertex paint (Shift+V) shares texture paint's brush and keys: a dab
#  projects the vertices and blends those inside the brush and in front of
#  the viewport's depth buffer towards the brush colour. Each stroke is a
#  scene undo step (the mesh is copied on write, as edit mode does).
# =============================================================================
.intel_syntax noprefix
.include "const.inc"
.include "macros.inc"

.globl vcol_avg
.globl vcol_lin
.globl vcol_lin3
.globl vp_on
.globl vp_stroke_start
.globl vp_dab
.globl vp_dab_world
.globl mvcl_write
.globl mvcl_read

.section .rodata
.align 4
vc_inv255:      .float 0.003921569
vc_one:         .float 1.0
vc_half:        .float 0.5
vc_depth:       .float 0.985
s_vp:           .asciz "Vertex Paint"
s_vp_on:        .asciz "  vertex paint: "

.section .bss
.align 8
vp_on:          .skip 4                 # 1: paint mode paints vertices

.text
OPERATOR op_vpaint_mode, "object.vertex_paint", "Vertex Paint", do_vpaint_mode, check=vpaint_check, key=KEY_V|KM_SHIFT, flags=OPF_AI_SAFE|OPF_QUIET, doc="Paint the active mesh's vertex colours (Shift+V toggles)"

vpaint_check:
    xor     eax, eax
    cmp     dword ptr [rip+pt_obj], 0
    je      1f
    mov     eax, [rip+vp_on]
1:  ret

do_vpaint_mode:
    push    rbx
    cmp     dword ptr [rip+pt_obj], 0
    je      1f
    mov     dword ptr [rip+pt_obj], 0   # (off, whichever paint it was)
    mov     dword ptr [rip+vp_on], 0
    jmp     9f
1:  call    active_mesh_obj
    test    rax, rax
    jz      9f
    mov     rbx, rax
    cmp     dword ptr [rip+edit_obj], 0
    je      2f
    call    edit_exit
2:  cmp     dword ptr [rip+sc_obj], 0
    je      3f
    call    sculpt_exit
3:  mov     eax, [rip+active_obj]
    mov     [rip+pt_obj], eax
    mov     dword ptr [rip+vp_on], 1
    lea     rdi, [rip+s_vp_on]
    mov     rsi, rbx
    call    log_pair
9:  mov     dword ptr [rip+dirty], 1
    pop     rbx
    ret

# vcol_avg(rdi=mesh, esi=triangle, edx=colour 0x..RRGGBB) -> eax = the colour
#   times its corners' average (unchanged without vertex colours)
vcol_avg:
    mov     eax, edx
    mov     r8, [rdi+ME_VCOL]
    test    r8, r8
    jz      9f
    push    rbx
    mov     rax, [rdi+ME_TRIS]
    lea     ecx, [rsi+rsi*2]
    lea     r9, [rax+rcx*4]
    xor     ebx, ebx                    # out
    mov     ecx, 16                     # channel shift
1:  xor     r10d, r10d                  # sum of the corners
    xor     r11d, r11d
2:  mov     eax, [r9+r11*4]
    mov     eax, [r8+rax*4]
    shr     eax, cl
    and     eax, 0xff
    add     r10d, eax
    inc     r11d
    cmp     r11d, 3
    jb      2b
    mov     eax, edx                    # colour x average / 255
    shr     eax, cl
    and     eax, 0xff
    imul    eax, r10d
    push    rdx
    xor     edx, edx
    mov     r11d, 765
    div     r11d
    pop     rdx
    shl     eax, cl
    or      ebx, eax
    sub     ecx, 8
    jns     1b
    mov     eax, ebx
    pop     rbx
9:  ret

# vcol_lin(rdi=mesh, esi=triangle, xmm0=u, xmm1=v, rdx=out float[3]) -> eax =
#   1: the vertex colour there in linear light (corners 1 - u - v, u, v)
vcol_lin:
    xor     eax, eax
    mov     r8, [rdi+ME_VCOL]
    test    r8, r8
    jz      9f
    sub     rsp, 24
    mov     rax, [rdi+ME_TRIS]
    lea     ecx, [rsi+rsi*2]
    lea     r9, [rax+rcx*4]
    xor     ecx, ecx
1:  mov     eax, [r9+rcx*4]
    mov     eax, [r8+rax*4]
    mov     [rsp+rcx*4], eax
    inc     ecx
    cmp     ecx, 3
    jb      1b
    lea     rsi, [rsp]
    call    vcol_lin3
    add     rsp, 24
    mov     eax, 1
9:  ret

# vcol_lin3(rsi=3 colours, xmm0=u, xmm1=v, rdx=out float[3]) - linear,
#   interpolated
vcol_lin3:
    push    rbx
    push    r12
    push    r13
    sub     rsp, 32
    mov     rbx, rsi
    mov     r12, rdx
    movss   xmm2, [rip+vc_one]          # weights
    subss   xmm2, xmm0
    subss   xmm2, xmm1
    movss   [rsp], xmm2
    movss   [rsp+4], xmm0
    movss   [rsp+8], xmm1
    xor     r13d, r13d                  # channel: r g b (shifts 16 8 0)
1:  xorps   xmm3, xmm3
    movss   [rsp+12], xmm3
    xor     ecx, ecx
2:  mov     eax, [rbx+rcx*4]
    push    rcx
    mov     ecx, 16
    imul    edx, r13d, 8
    sub     ecx, edx
    shr     eax, cl
    pop     rcx
    and     eax, 0xff
    cvtsi2ss xmm0, eax
    mulss   xmm0, [rip+vc_inv255]
    push    rcx
    push    rcx
    call    srgb_to_lin
    pop     rcx
    pop     rcx
    mulss   xmm0, [rsp+rcx*4]
    addss   xmm0, [rsp+12]
    movss   [rsp+12], xmm0
    inc     ecx
    cmp     ecx, 3
    jb      2b
    movss   xmm0, [rsp+12]
    movss   [r12+r13*4], xmm0
    inc     r13d
    cmp     r13d, 3
    jb      1b
    add     rsp, 32
    pop     r13
    pop     r12
    pop     rbx
    ret

# =============================================================================
#  Vertex paint
# =============================================================================
# vp_stroke_start -> rax = the mesh painted (an undo step, copied on write,
#   with colours; 0: none)
vp_stroke_start:
    push    rbx
    mov     edi, [rip+pt_obj]
    call    obj_get
    test    rax, rax
    jz      8f
    mov     rbx, rax
    cmp     dword ptr [rbx+OB_TYPE], OT_MESH
    jne     8f
    lea     rdi, [rip+s_vp]
    call    undo_push
    mov     rdi, [rbx+OB_MESH]          # unshared (the step keeps the old)
    cmp     dword ptr [rdi+ME_REFS], 1
    jbe     1f
    call    mesh_copy
    test    rax, rax
    jz      8f
    mov     rdi, [rbx+OB_MESH]
    mov     [rbx+OB_MESH], rax
    call    mesh_unref
1:  mov     rdi, [rbx+OB_MESH]
    call    mesh_vcol_alloc
    test    rax, rax
    jz      8f
    mov     rax, [rbx+OB_MESH]
    pop     rbx
    ret
8:  xor     eax, eax
    pop     rbx
    ret

# vp_dab(xmm0 = x, xmm1 = y physical, xmm2 = radius physical) - the
#   vertices inside the brush and in front blend towards the colour
vp_dab:
    push    rbx
    push    r12
    push    r13
    sub     rsp, 48
    movss   [rsp], xmm0
    movss   [rsp+4], xmm1
    movss   [rsp+8], xmm2
    mov     edi, [rip+pt_obj]
    call    obj_get
    test    rax, rax
    jz      9f
    mov     rbx, [rax+OB_MESH]
    cmp     qword ptr [rbx+ME_VCOL], 0
    je      9f
    call    pt_mat
    xor     r12d, r12d
1:  cmp     r12d, [rbx+ME_NVERTS]
    jae     8f
    lea     rax, [r12+r12*2]
    shl     rax, 2
    add     rax, [rbx+ME_POS]
    mov     rsi, rax
    lea     rdi, [rsp+16]
    call    pt_cam
    movss   xmm2, [rsp+24]
    comiss  xmm2, [rip+f_near]
    jb      7f
    movss   xmm0, [rsp+16]
    movss   xmm1, [rsp+20]
    call    pt_screen
    movss   [rsp+28], xmm2              # 1/z
    movss   xmm3, xmm0
    subss   xmm3, [rsp]
    mulss   xmm3, xmm3
    movss   xmm4, xmm1
    subss   xmm4, [rsp+4]
    mulss   xmm4, xmm4
    addss   xmm3, xmm4
    movss   xmm4, [rsp+8]
    mulss   xmm4, xmm4
    comiss  xmm3, xmm4
    jae     7f
    divss   xmm3, xmm4                  # falloff
    movss   xmm5, [rip+vc_one]
    subss   xmm5, xmm3
    mulss   xmm5, xmm5
    mulss   xmm5, [rip+pt_strength]
    movss   [rsp+32], xmm5
    cvttss2si eax, xmm0                 # in front?
    sub     eax, [rip+rs_x0]
    cvttss2si edx, xmm1
    sub     edx, [rip+rs_y0]
    cmp     eax, [rip+rs_w]
    jae     7f
    cmp     edx, [rip+rs_h]
    jae     7f
    imul    edx, [rip+rs_w]
    add     edx, eax
    mov     rax, [rip+rs_depth]
    movss   xmm0, [rax+rdx*4]
    mulss   xmm0, [rip+vc_depth]
    comiss  xmm0, [rsp+28]
    ja      7f
    mov     edi, r12d
    movss   xmm0, [rsp+32]
    call    vp_blend
7:  inc     r12d
    jmp     1b
8:  inc     dword ptr [rbx+ME_VER]
    call    eval_flush
    mov     dword ptr [rip+dirty], 1
9:  add     rsp, 48
    pop     r13
    pop     r12
    pop     rbx
    ret

# vp_blend(rbx=mesh, edi=vertex, xmm0=amount) - towards the brush colour
vp_blend:
    mov     r8, [rbx+ME_VCOL]
    lea     r8, [r8+rdi*4]
    mov     r9d, [r8]
    mov     r10d, [rip+pt_col]
    xor     r11d, r11d
    xor     ecx, ecx
1:  mov     eax, r9d
    shr     eax, cl
    and     eax, 0xff
    cvtsi2ss xmm1, eax
    mov     eax, r10d
    shr     eax, cl
    and     eax, 0xff
    cvtsi2ss xmm2, eax
    subss   xmm2, xmm1
    mulss   xmm2, xmm0
    addss   xmm1, xmm2
    addss   xmm1, [rip+vc_half]
    cvttss2si eax, xmm1
    shl     eax, cl
    or      r11d, eax
    add     ecx, 8
    cmp     ecx, 24
    jb      1b
    or      r11d, 0xff000000
    mov     [r8], r11d
    ret

# vp_dab_world(edi=object, rsi=world point, xmm0=radius world) -> eax = 1:
#   for scripts: the vertices within the radius (no screen), one undo step
vp_dab_world:
    push    rbx
    push    r12
    push    r13
    push    r14
    sub     rsp, 88
    movss   [rsp+76], xmm0
    mov     rax, [rsi]
    mov     [rsp+64], rax
    mov     eax, [rsi+8]
    mov     [rsp+72], eax
    mov     eax, [rip+pt_obj]
    mov     [rsp+80], eax
    mov     [rip+pt_obj], edi
    call    vp_stroke_start
    test    rax, rax
    jz      8f
    mov     rbx, rax
    mov     edi, [rip+pt_obj]
    call    obj_get
    mov     rdi, rax
    lea     rsi, [rsp]
    call    obj_matrix
    xor     r12d, r12d                  # each vertex, in world space
1:  cmp     r12d, [rbx+ME_NVERTS]
    jae     7f
    lea     rax, [r12+r12*2]
    shl     rax, 2
    add     rax, [rbx+ME_POS]
    lea     rdi, [rsp]
    mov     rsi, rax
    lea     rdx, [rsp+48]
    call    xform_point
    xorps   xmm3, xmm3
    xor     ecx, ecx
2:  movss   xmm0, [rsp+48+rcx*4]
    subss   xmm0, [rsp+64+rcx*4]
    mulss   xmm0, xmm0
    addss   xmm3, xmm0
    inc     ecx
    cmp     ecx, 3
    jb      2b
    movss   xmm4, [rsp+76]
    mulss   xmm4, xmm4
    comiss  xmm3, xmm4
    jae     6f
    divss   xmm3, xmm4
    movss   xmm0, [rip+vc_one]
    subss   xmm0, xmm3
    mulss   xmm0, xmm0
    mulss   xmm0, [rip+pt_strength]
    mov     edi, r12d
    call    vp_blend
6:  inc     r12d
    jmp     1b
7:  inc     dword ptr [rbx+ME_VER]
    call    eval_flush
    mov     dword ptr [rip+dirty], 1
    mov     eax, [rsp+80]
    mov     [rip+pt_obj], eax
    mov     eax, 1
    jmp     9f
8:  mov     eax, [rsp+80]
    mov     [rip+pt_obj], eax
    xor     eax, eax
9:  add     rsp, 88
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# =============================================================================
#  Files: MVCL - per mesh (mesh_tab order) with colours: index, vertices,
#  the colours
# =============================================================================
mvcl_write:
    push    rbx
    push    r12
    sub     rsp, 8
    xor     ebx, ebx
1:  cmp     ebx, [rip+n_mesh_tab]
    jae     9f
    lea     rax, [rip+mesh_tab]
    mov     r12, [rax+rbx*8]
    cmp     qword ptr [r12+ME_VCOL], 0
    je      2f
    mov     edi, ebx
    call    wb_u32
    mov     edi, [r12+ME_NVERTS]
    call    wb_u32
    mov     rsi, [r12+ME_VCOL]
    mov     edx, [r12+ME_NVERTS]
    shl     edx, 2
    call    wb_bytes
2:  inc     ebx
    jmp     1b
9:  add     rsp, 8
    pop     r12
    pop     rbx
    ret

mvcl_read:
    push    rbx
    push    r12
    push    r13
    push    r14
    sub     rsp, 8
    mov     r12, rdi
    mov     r13d, esi
1:  cmp     r13d, 8
    jb      9f
    mov     r14d, [r12+4]
    cmp     r14d, 0x10000000
    jae     9f
    lea     eax, [r14*4+8]
    cmp     eax, r13d
    ja      9f
    mov     ecx, [r12]
    cmp     ecx, [rip+n_mesh_tab]
    jae     2f
    lea     rax, [rip+mesh_tab]
    mov     rbx, [rax+rcx*8]
    cmp     r14d, [rbx+ME_NVERTS]
    jne     2f
    mov     rdi, rbx
    call    mesh_vcol_alloc
    test    rax, rax
    jz      2f
    mov     rdi, rax
    lea     rsi, [r12+8]
    mov     ecx, r14d
    rep     movsd
2:  lea     eax, [r14*4+8]
    add     r12, rax
    sub     r13d, eax
    jmp     1b
9:  add     rsp, 8
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret
