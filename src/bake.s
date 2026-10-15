# =============================================================================
#  BeeModel - baking maps from a high-poly mesh onto a low-poly one
#
#  bake(low, high, kind, image) fills the image through the low mesh's UVs.
#  The path tracer's BVH is built over the high mesh alone; every texel
#  inside a UV triangle of the low mesh gets its world point and smoothed
#  normal, and a ray from a little outside along the normal, back through
#  the surface, finds the high mesh (within the cage distance: 5% of the
#  low mesh's size unless given). From the hit:
#    normal     the high normal in the low triangle's tangent frame (from
#               its UVs), 0.5 + n / 2 (no hit: flat, 0.5 0.5 1)
#    ao         ambient occlusion: 24 cosine-weighted rays from the hit
#               within the cage distance x 4; the unblocked share
#    curvature  how the high surface's smooth normals turn around the hit
#               (8 probes at 1% of the size): 0.5 flat, lighter convex,
#               darker concave; probes falling off an edge count as convex
#  Texels no triangle covers are filled from their neighbours (8 passes),
#  so island borders do not show seams. Rows run in parallel.
# =============================================================================
.intel_syntax noprefix
.include "const.inc"
.include "macros.inc"

.globl bake
.globl bake_material
.globl bk_quiet

.section .rodata
s_bk_need:      .asciz "  object.bake <low> <high> <normal|ao|curvature> <image> [distance]"
s_bk_no:        .asciz "  bake: not found: "
s_bk_fail:      .asciz "  bake: the low mesh needs UVs and the image 8 bits"
s_bk_done:      .asciz "  baked texels: "
s_bk_kinds:     .asciz "normal"
                .asciz "ao"
                .asciz "curvature"
                .byte 0

OPERATOR op_object_bake, "object.bake", "Bake Maps", do_bake, doc="Bake a high mesh's normal, ambient occlusion or curvature map into an image through a low mesh's UVs: object.bake <low> <high> <normal|ao|curvature> <image> [distance]", form=form_bake

.equ IM_W,      0
.equ IM_H,      4
.equ IM_FMT,    8
.equ IM_DIRTY,  24
.equ IM_LAYERS, 32
.equ IM_DATA,   64
.equ RAY_O,     0
.equ RAY_D,     12
.equ RAY_TMAX,  24
.equ RAY_T,     28
.equ RAY_TRI,   32
.equ RAY_U,     36
.equ RAY_V,     40
.equ RAY_SZ,    64
.equ AO_N,      48
.equ BK_BASE,   3                       # material kinds: base colour (sRGB,
.equ BK_ORM,    4                       #  alpha), occlusion roughness
.equ BK_NORMAL, 5                       #  metallic, tangent-space normal,
.equ BK_EMIT,   6                       #  emission (sRGB)
.equ MA_BASE,   32
.equ MA_METAL,  44
.equ MA_ROUGH,  48
.equ MA_EMIT,   64
.equ MA_ESTR,   76
.equ MA_ALPHA,  88
.equ SC_P0O,    0                       # (graph.s's shading context)
.equ SC_E1O,    12
.equ SC_E2O,    24
.equ SC_U,      36
.equ SC_V,      40
.equ SC_PU,     44
.equ SC_PV,     56
.equ SC_N,      68
.equ SC_FLAGS,  112
.equ SC_UVP,    120
.equ SC_WP,     152
.equ SC_WV,     164
.equ SC_VC,     176
.equ CV_N,      8

.section .rodata
.align 4
bk_one:         .float 1.0
bk_half:        .float 0.5
bk_two:         .float 2.0
bk_255:         .float 255.0
bk_tiny:        .float 1.0e-12
bk_cage:        .float 0.05
bk_ao_far:      .float 4.0
bk_eps:         .float 1.0e-3
bk_bias:        .float -1.0e-4                  # (barycentrics: a hair over)
bk_curv:        .float 0.5                      # curvature: gain / CV_N (4 / 8)
bk_probe:       .float 0.01                     # probe radius / size
bk_three:       .float 3.0
bk_dirs:        .float 1, 0, 0.7071068, 0.7071068, 0, 1, -0.7071068, 0.7071068
                .float -1, 0, -0.7071068, -0.7071068, 0, -1, 0.7071068, -0.7071068
bk_2pi:         .float 6.2831853
bk_inv24:       .float 5.9604645e-8             # 2^-24
.align 16
bk_absmask:     .long 0x7fffffff, 0x7fffffff, 0x7fffffff, 0x7fffffff

.section .bss
.align 8
bk_mesh:        .skip 8                 # the low mesh,
bk_wpos:        .skip 8                 #  its world positions,
bk_wnrm:        .skip 8                 #  world corner normals
bk_img:         .skip 8                 # the image, the pixels written,
bk_pix:         .skip 8
bk_mask:        .skip 8                 #  which ones (u8)
bk_kind:        .skip 4
bk_dist:        .skip 4
bk_diag:        .skip 4
bk_count:       .skip 4
bk_mrec:        .skip 8                 # material kinds: the material record
bk_quiet:       .skip 4                 # 1: straight into the image (no
                                        #  layers, no undo: export's bakes)

.text
# bake(rdi=low object, rsi=high object, edx=kind 0 normal 1 ao 2 curvature,
#   rcx=image, xmm0=cage distance (0: 5% of the low mesh)) -> eax = texels
#   baked (-1: the low mesh has no UVs, the image is not 8-bit, or no
#   memory)
bake:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    push    rbp
    sub     rsp, 56
    mov     rbx, rdi
    mov     r12, rsi
    mov     [rip+bk_kind], edx
    mov     [rip+bk_img], rcx
    movss   [rip+bk_dist], xmm0
    mov     dword ptr [rip+bk_count], 0
    mov     rdi, rbx
    call    obj_eval
    mov     r13, rax
    mov     [rip+bk_mesh], rax
    cmp     qword ptr [r13+ME_UV], 0
    je      .Lbk_fail0
    mov     rax, [rip+bk_img]
    test    rax, rax
    jz      .Lbk_fail0
    cmp     dword ptr [rax+IM_FMT], 0
    jne     .Lbk_fail0
    call    fa_mark
    mov     [rsp+48], rax
    mov     rdi, rbx                    # low: world positions, normals
    call    world_verts
    test    rax, rax
    jz      .Lbk_fail
    mov     [rip+bk_wpos], rax
    call    bk_normals
    test    eax, eax
    jz      .Lbk_fail
    call    bk_size                     # the cage: 5% of the size
    movss   [rip+bk_diag], xmm0
    movss   xmm1, [rip+bk_dist]
    xorps   xmm2, xmm2
    comiss  xmm1, xmm2
    ja      1f
    mulss   xmm0, [rip+bk_cage]
    movss   [rip+bk_dist], xmm0
1:  cmp     dword ptr [rip+bk_kind], BK_BASE
    jae     11f                         # (a material: no high mesh)
    mov     [rip+hv_only], r12          # the high mesh alone
    call    hive_build
    mov     qword ptr [rip+hv_only], 0
    cmp     dword ptr [rip+hv_n], 0
    je      .Lbk_free
11: mov     rax, [rip+bk_img]           # where: the image (its layer)
    add     rax, IM_DATA
    cmp     dword ptr [rip+bk_quiet], 0
    jne     12f
    mov     rdi, [rip+bk_img]
    call    lay_target
12: mov     [rip+bk_pix], rax
    mov     rax, [rip+bk_img]
    mov     esi, [rax+IM_W]
    imul    esi, [rax+IM_H]
    add     esi, 16
    lea     rdi, [rip+frame_arena]
    call    arena_alloc
    test    rax, rax
    jz      .Lbk_free
    mov     [rip+bk_mask], rax
    mov     rdi, rax
    mov     rcx, [rip+bk_img]
    mov     ecx, [rcx+IM_W]
    mov     rdx, [rip+bk_img]
    imul    ecx, [rdx+IM_H]
    xor     eax, eax
    rep     stosb
    cmp     dword ptr [rip+bk_quiet], 0
    jne     13f
    mov     rdi, [rip+bk_img]           # (one texture paint undo step)
    call    pt_record
13: lea     rdi, [rip+bk_job]           # the low triangles, in parallel
    xor     esi, esi
    mov     edx, [r13+ME_NTRIS]
    shl     edx, 4
    mov     ecx, 4
    call    parallel_for
    call    bk_dilate
    mov     rdi, [rip+bk_img]
    mov     dword ptr [rdi+IM_DIRTY], 1
    cmp     dword ptr [rip+bk_quiet], 0
    jne     .Lbk_free
    call    pt_record_end
    mov     rdi, [rip+bk_img]           # done: composite, redraw
    xor     esi, esi
    xor     edx, edx
    mov     ecx, -1
    xor     r8d, r8d
    call    lay_rect
.Lbk_free:
    cmp     dword ptr [rip+bk_kind], BK_BASE
    jae     14f
    mov     dword ptr [rip+hv_ready], 0 # (the scene's BVH again next time)
    call    hv_free_all
14:
    mov     rdi, [rsp+48]
    call    fa_release
    call    eval_flush
    mov     dword ptr [rip+dirty], 1
    mov     eax, [rip+bk_count]
    jmp     9f
.Lbk_fail:
    mov     rdi, [rsp+48]
    call    fa_release
.Lbk_fail0:
    mov     eax, -1
9:  add     rsp, 56
    pop     rbp
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# ---- object.bake <low> <high> <kind> <image> [distance] ----------------------
do_bake:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    sub     rsp, 16
    mov     rsi, [rip+op_arg]
    call    im_next_word                # low, high: objects
    test    eax, eax
    jz      .Ldb_need
    mov     r15, rsi
    lea     rdi, [rip+im_word]
    call    obj_find
    test    eax, eax
    jz      .Ldb_none
    mov     edi, eax
    call    obj_get
    mov     rbx, rax
    mov     rsi, r15
    call    im_next_word
    test    eax, eax
    jz      .Ldb_need
    mov     r15, rsi
    lea     rdi, [rip+im_word]
    call    obj_find
    test    eax, eax
    jz      .Ldb_none
    mov     edi, eax
    call    obj_get
    mov     r12, rax
    mov     rsi, r15                    # the kind
    call    im_next_word
    test    eax, eax
    jz      .Ldb_need
    mov     r15, rsi
    xor     r13d, r13d
    lea     r14, [rip+s_bk_kinds]
1:  cmp     byte ptr [r14], 0
    je      .Ldb_need
    mov     rdi, r14
    lea     rsi, [rip+im_word]
    call    str_eq
    test    eax, eax
    jnz     2f
    mov     rdi, r14
    call    str_len
    lea     r14, [r14+rax+1]
    inc     r13d
    jmp     1b
2:  mov     rsi, r15                    # the image
    call    im_next_word
    test    eax, eax
    jz      .Ldb_need
    mov     r15, rsi
    lea     rdi, [rip+im_word]
    call    image_find
    test    eax, eax
    js      .Ldb_none
    mov     edi, eax
    call    image_ptr
    mov     r14, rax
    xorps   xmm0, xmm0                  # [distance]
    movss   [rsp], xmm0
    mov     rsi, r15
    call    im_next_word
    test    eax, eax
    jz      3f
    lea     rsi, [rip+im_word]
    lea     rdx, [rsi+rax]
    call    parse_float
    movss   [rsp], xmm0
3:  mov     rdi, rbx
    mov     rsi, r12
    mov     edx, r13d
    mov     rcx, r14
    movss   xmm0, [rsp]
    call    bake
    test    eax, eax
    js      .Ldb_fail
    mov     [rsp+4], eax
    call    fmt_reset
    lea     rdi, [rip+s_bk_done]
    call    fmt_str
    mov     edi, [rsp+4]
    call    fmt_int
    lea     rdi, [rip+fmt_buf]
    call    log_line
    jmp     9f
.Ldb_need:
    lea     rdi, [rip+s_bk_need]
    call    log_line
    jmp     9f
.Ldb_none:
    lea     rdi, [rip+s_bk_no]
    lea     rsi, [rip+im_word]
    call    log_pair
    jmp     9f
.Ldb_fail:
    lea     rdi, [rip+s_bk_fail]
    call    log_line
9:  add     rsp, 16
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# bk_size -> xmm0 = the low mesh's world box diagonal
bk_size:
    mov     rax, [rip+bk_mesh]
    mov     ecx, [rax+ME_NVERTS]
    mov     rdx, [rip+bk_wpos]
    movss   xmm0, [rdx]
    movss   xmm1, [rdx+4]
    movss   xmm2, [rdx+8]
    movaps  xmm3, xmm0
    movaps  xmm4, xmm1
    movaps  xmm5, xmm2
1:  test    ecx, ecx
    jz      2f
    dec     ecx
    lea     rax, [rcx+rcx*2]
    minss   xmm0, [rdx+rax*4]
    maxss   xmm3, [rdx+rax*4]
    minss   xmm1, [rdx+rax*4+4]
    maxss   xmm4, [rdx+rax*4+4]
    minss   xmm2, [rdx+rax*4+8]
    maxss   xmm5, [rdx+rax*4+8]
    jmp     1b
2:  subss   xmm3, xmm0
    subss   xmm4, xmm1
    subss   xmm5, xmm2
    mulss   xmm3, xmm3
    mulss   xmm4, xmm4
    mulss   xmm5, xmm5
    addss   xmm3, xmm4
    addss   xmm3, xmm5
    sqrtss  xmm0, xmm3
    ret

# bk_normals -> eax = 1: the low mesh's corner normals in world space, as
#   the renderer shades it (bk_wnrm: 9 floats per triangle, frame arena)
bk_normals:
    push    r15
    push    rbp
    push    rbx
    push    r12
    push    r13
    mov     r15, [rip+bk_mesh]
    mov     rbp, [rip+bk_wpos]
    lea     rdi, [rip+frame_arena]      # (it reads hv_tv: v0 e1 e2)
    mov     esi, [r15+ME_NTRIS]
    imul    esi, esi, 72
    add     esi, 16
    call    arena_alloc
    test    rax, rax
    jz      8f
    mov     r12, rax
    mov     eax, [r15+ME_NTRIS]
    imul    eax, eax, 36
    add     rax, r12
    mov     [rip+bk_wnrm], rax
    xor     ecx, ecx
1:  cmp     ecx, [r15+ME_NTRIS]
    jae     3f
    mov     rax, [r15+ME_TRIS]
    lea     edx, [rcx+rcx*2]
    lea     r8, [rax+rdx*4]
    imul    r9d, ecx, 36
    add     r9, r12
    xor     edx, edx
2:  mov     eax, [r8]                   # v0, then v1 - v0, v2 - v0
    lea     rax, [rax+rax*2]
    add     rax, rdx
    movss   xmm0, [rbp+rax*4]
    movss   [r9+rdx*4], xmm0
    mov     eax, [r8+4]
    lea     rax, [rax+rax*2]
    add     rax, rdx
    movss   xmm1, [rbp+rax*4]
    subss   xmm1, xmm0
    movss   [r9+12+rdx*4], xmm1
    mov     eax, [r8+8]
    lea     rax, [rax+rax*2]
    add     rax, rdx
    movss   xmm1, [rbp+rax*4]
    subss   xmm1, xmm0
    movss   [r9+24+rdx*4], xmm1
    inc     edx
    cmp     edx, 3
    jb      2b
    inc     ecx
    jmp     1b
3:  mov     rbx, [rip+hv_tn]            # (corner_normals: hv_tv -> hv_tn)
    mov     r13, [rip+hv_tv]
    mov     [rip+hv_tv], r12
    mov     rax, [rip+bk_wnrm]
    mov     [rip+hv_tn], rax
    xor     edi, edi
    call    corner_normals
    mov     [rip+hv_tn], rbx
    mov     [rip+hv_tv], r13
    mov     eax, 1
    jmp     9f
8:  xor     eax, eax
9:  pop     r13
    pop     r12
    pop     rbx
    pop     rbp
    pop     r15
    ret

# bk_unit(rdi=float[3]) - normalized (keeps rcx)
bk_unit:
    movss   xmm0, [rdi]
    mulss   xmm0, xmm0
    movss   xmm1, [rdi+4]
    mulss   xmm1, xmm1
    addss   xmm0, xmm1
    movss   xmm1, [rdi+8]
    mulss   xmm1, xmm1
    addss   xmm0, xmm1
    sqrtss  xmm0, xmm0
    maxss   xmm0, [rip+bk_tiny]
    movss   xmm1, [rip+bk_one]
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
    ret

# bk_job(esi=begin, edx=end) - the low triangles' texels (item: triangle
#   x 16 + band of rows)
bk_job:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    push    rbp
    sub     rsp, 232
    mov     [rsp+208], esi              # items: triangle x 16 row bands
    mov     [rsp+204], edx
.Lbj_tri:
    mov     eax, [rsp+208]
    cmp     eax, [rsp+204]
    jae     .Lbj_out
    mov     ecx, eax
    shr     eax, 4
    mov     [rsp+200], eax
    and     ecx, 15
    mov     [rsp+212], ecx
    mov     rdi, [rip+bk_mesh]          # UVs (texels), corners, normals
    mov     esi, eax
    lea     rdx, [rsp+96]
    call    tri_uvs
    mov     rbx, [rip+bk_mesh]
    mov     eax, [rsp+200]
    mov     rcx, [rbx+ME_TRIS]
    lea     eax, [rax+rax*2]
    lea     rcx, [rcx+rax*4]
    xor     edx, edx
1:  mov     eax, [rcx+rdx*4]
    lea     rax, [rax+rax*2]
    shl     rax, 2
    mov     r8, [rip+bk_wpos]
    add     r8, rax
    imul    r10d, edx, 12
    imul    r9d, [rsp+200], 36          # (corner normals: per triangle)
    add     r9, r10
    add     r9, [rip+bk_wnrm]
    mov     r11, [r8]
    mov     [rsp+r10], r11              # p: +0
    mov     r11d, [r8+8]
    mov     [rsp+r10+8], r11d
    mov     r11, [r9]
    mov     [rsp+36+r10], r11           # n: +36
    mov     r11d, [r9+8]
    mov     [rsp+36+r10+8], r11d
    inc     edx
    cmp     edx, 3
    jb      1b
    # tangent frame from the UVs: T = (e1 dv2 - e2 dv1) / det, B = (e2 du1 -
    #   e1 du2) / det  (det = du1 dv2 - du2 dv1)
    movss   xmm0, [rsp+104]             # du1, dv1, du2, dv2
    subss   xmm0, [rsp+96]
    movss   xmm1, [rsp+108]
    subss   xmm1, [rsp+100]
    movss   xmm2, [rsp+112]
    subss   xmm2, [rsp+96]
    movss   xmm3, [rsp+116]
    subss   xmm3, [rsp+100]
    movss   xmm4, xmm0
    mulss   xmm4, xmm3
    movss   xmm5, xmm2
    mulss   xmm5, xmm1
    subss   xmm4, xmm5                  # det
    movss   [rsp+188], xmm4
    movss   xmm5, xmm4
    andps   xmm5, [rip+bk_absmask]
    comiss  xmm5, [rip+bk_tiny]
    jbe     .Lbj_next
    movss   xmm5, [rip+bk_one]
    divss   xmm5, xmm4
    xor     ecx, ecx
2:  movss   xmm6, [rsp+12+rcx*4]        # e1
    subss   xmm6, [rsp+rcx*4]
    movss   xmm7, [rsp+24+rcx*4]        # e2
    subss   xmm7, [rsp+rcx*4]
    movss   xmm8, xmm6                  # T
    mulss   xmm8, xmm3
    movss   xmm9, xmm7
    mulss   xmm9, xmm1
    subss   xmm8, xmm9
    mulss   xmm8, xmm5
    movss   [rsp+72+rcx*4], xmm8
    movss   xmm8, xmm7                  # B
    mulss   xmm8, xmm0
    movss   xmm9, xmm6
    mulss   xmm9, xmm2
    subss   xmm8, xmm9
    mulss   xmm8, xmm5
    movss   [rsp+84+rcx*4], xmm8
    inc     ecx
    cmp     ecx, 3
    jb      2b
    # texels: the box of the UV triangle (x = u w, y = (1 - v) h)
    mov     rax, [rip+bk_img]
    cvtsi2ss xmm6, dword ptr [rax+IM_W]
    cvtsi2ss xmm7, dword ptr [rax+IM_H]
    xor     ecx, ecx
3:  movss   xmm0, [rsp+96+rcx*8]
    mulss   xmm0, xmm6
    movss   [rsp+120+rcx*8], xmm0
    movss   xmm0, [rip+bk_one]
    subss   xmm0, [rsp+100+rcx*8]
    mulss   xmm0, xmm7
    movss   [rsp+124+rcx*8], xmm0
    inc     ecx
    cmp     ecx, 3
    jb      3b
    movss   xmm0, [rsp+128]             # 2A (texels, signed)
    subss   xmm0, [rsp+120]
    movss   xmm1, [rsp+140]
    subss   xmm1, [rsp+124]
    mulss   xmm0, xmm1
    movss   xmm1, [rsp+136]
    subss   xmm1, [rsp+120]
    movss   xmm2, [rsp+132]
    subss   xmm2, [rsp+124]
    mulss   xmm1, xmm2
    subss   xmm0, xmm1
    movss   [rsp+144], xmm0
    andps   xmm0, [rip+bk_absmask]
    comiss  xmm0, [rip+bk_tiny]
    jbe     .Lbj_next
    movss   xmm0, [rsp+120]
    minss   xmm0, [rsp+128]
    minss   xmm0, [rsp+136]
    cvttss2si r12d, xmm0
    movss   xmm0, [rsp+120]
    maxss   xmm0, [rsp+128]
    maxss   xmm0, [rsp+136]
    cvttss2si r13d, xmm0
    movss   xmm0, [rsp+124]
    minss   xmm0, [rsp+132]
    minss   xmm0, [rsp+140]
    cvttss2si r14d, xmm0
    movss   xmm0, [rsp+124]
    maxss   xmm0, [rsp+132]
    maxss   xmm0, [rsp+140]
    cvttss2si eax, xmm0
    mov     [rsp+148], eax
    test    r12d, r12d
    jns     31f
    xor     r12d, r12d
31: mov     rax, [rip+bk_img]
    mov     eax, [rax+IM_W]
    dec     eax
    cmp     r13d, eax
    jle     32f
    mov     r13d, eax
32: test    r14d, r14d
    jns     33f
    xor     r14d, r14d
33: mov     rax, [rip+bk_img]
    mov     eax, [rax+IM_H]
    dec     eax
    cmp     [rsp+148], eax
    jle     34f
    mov     [rsp+148], eax
34: mov     rcx, [rip+bk_img]           # this item's band of rows
    mov     eax, [rsp+212]
    imul    eax, [rcx+IM_H]
    shr     eax, 4
    cmp     r14d, eax
    jge     35f
    mov     r14d, eax
35: mov     eax, [rsp+212]
    inc     eax
    imul    eax, [rcx+IM_H]
    shr     eax, 4
    dec     eax
    cmp     [rsp+148], eax
    jle     4f
    mov     [rsp+148], eax
4:  mov     r15d, r14d
41: cmp     r15d, [rsp+148]
    jg      .Lbj_next
    mov     ebp, r12d
42: cmp     ebp, r13d
    jg      49f
    cvtsi2ss xmm4, ebp
    addss   xmm4, [rip+bk_half]
    cvtsi2ss xmm5, r15d
    addss   xmm5, [rip+bk_half]
    xor     ecx, ecx                    # barycentrics (k: the edge k+1 k+2)
43: lea     edx, [rcx+1]
    cmp     edx, 3
    jb      431f
    xor     edx, edx
431:lea     r8d, [rdx+1]
    cmp     r8d, 3
    jb      432f
    xor     r8d, r8d
432:movss   xmm0, [rsp+120+r8*8]
    subss   xmm0, [rsp+120+rdx*8]
    movss   xmm1, xmm5
    subss   xmm1, [rsp+124+rdx*8]
    mulss   xmm0, xmm1
    movss   xmm1, [rsp+124+r8*8]
    subss   xmm1, [rsp+124+rdx*8]
    movss   xmm2, xmm4
    subss   xmm2, [rsp+120+rdx*8]
    mulss   xmm1, xmm2
    subss   xmm0, xmm1
    divss   xmm0, [rsp+144]
    movss   [rsp+152+rcx*4], xmm0
    comiss  xmm0, [rip+bk_bias]
    jb      48f
    inc     ecx
    cmp     ecx, 3
    jb      43b
    mov     edi, ebp
    mov     esi, r15d
    lea     rdx, [rsp]
    call    bk_texel
48: inc     ebp
    jmp     42b
49: inc     r15d
    jmp     41b
.Lbj_next:
    inc     dword ptr [rsp+208]
    jmp     .Lbj_tri
.Lbj_out:
    add     rsp, 232
    pop     rbp
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# bk_texel(edi=x, esi=y, rdx=bk_job's frame: p +0, n +36, T +72, B +84,
#   barycentrics +152) - the value there
bk_texel:
    push    rbx
    push    r12
    push    r13
    push    r14
    sub     rsp, 296
    mov     r12d, edi
    mov     r13d, esi
    mov     rbx, rdx
    xor     ecx, ecx                    # P, N (unit): interpolated
1:  xorps   xmm0, xmm0
    xorps   xmm1, xmm1
    xor     edx, edx
2:  movss   xmm2, [rbx+152+rdx*4]
    imul    eax, edx, 12
    lea     r8, [rbx+rax]
    movss   xmm3, [r8+rcx*4]
    mulss   xmm3, xmm2
    addss   xmm0, xmm3
    movss   xmm3, [r8+36+rcx*4]
    mulss   xmm3, xmm2
    addss   xmm1, xmm3
    inc     edx
    cmp     edx, 3
    jb      2b
    movss   [rsp+rcx*4], xmm0           # P +0
    movss   [rsp+12+rcx*4], xmm1        # N +12
    inc     ecx
    cmp     ecx, 3
    jb      1b
    lea     rdi, [rsp+12]
    call    bk_unit
    cmp     dword ptr [rip+bk_kind], BK_BASE
    jb      21f
    mov     rdi, rbx                    # a material: its graph there
    lea     rsi, [rsp]
    call    bk_mat
    jmp     .Lbt_write
21: lea     r14, [rsp+64]               # the ray: from P + N d, along -N
    xor     ecx, ecx
3:  movss   xmm0, [rsp+12+rcx*4]
    mulss   xmm0, [rip+bk_dist]
    addss   xmm0, [rsp+rcx*4]
    movss   [r14+RAY_O+rcx*4], xmm0
    xorps   xmm0, xmm0
    subss   xmm0, [rsp+12+rcx*4]
    movss   [r14+RAY_D+rcx*4], xmm0
    inc     ecx
    cmp     ecx, 3
    jb      3b
    movss   xmm0, [rip+bk_dist]
    addss   xmm0, xmm0
    movss   [r14+RAY_TMAX], xmm0
    mov     rdi, r14
    call    hv_trace
    mov     [rsp+60], eax               # hit?
    mov     eax, [rip+bk_kind]
    cmp     eax, 1
    je      .Lbt_ao
    cmp     eax, 2
    je      .Lbt_curv
    # normal: the high normal there in (T, B, N) of the low surface
    cmp     dword ptr [rsp+60], 0
    jne     41f
    mov     eax, 0xff8080ff             # (no hit: flat)
    jmp     .Lbt_write
41: mov     rdi, r14                    # -> [rsp+24..]
    lea     rsi, [rsp+24]
    call    bk_high_normal
    lea     rdi, [rbx+72]               # T, B made orthonormal to N
    lea     rsi, [rsp+36]
    call    bk_ortho
    lea     rdi, [rbx+84]
    lea     rsi, [rsp+48]
    call    bk_ortho
    xor     ecx, ecx                    # (n.T, n.B, n.N) -> 0.5 + c / 2
    mov     eax, 0xff
42: lea     rdx, [rsp+36]
    cmp     ecx, 1
    jne     421f
    lea     rdx, [rsp+48]
421:cmp     ecx, 2
    jne     422f
    lea     rdx, [rsp+12]
422:movss   xmm0, [rsp+24]
    mulss   xmm0, [rdx]
    movss   xmm1, [rsp+28]
    mulss   xmm1, [rdx+4]
    addss   xmm0, xmm1
    movss   xmm1, [rsp+32]
    mulss   xmm1, [rdx+8]
    addss   xmm0, xmm1
    mulss   xmm0, [rip+bk_half]
    addss   xmm0, [rip+bk_half]
    call    bk_byte
    shl     eax, 8
    or      eax, edx
    inc     ecx
    cmp     ecx, 3
    jb      42b
    jmp     .Lbt_write
.Lbt_ao:                                # the unblocked share of 24 rays
    cmp     dword ptr [rsp+60], 0
    jne     51f
    mov     eax, 0xffffffff
    jmp     .Lbt_write
51: mov     rdi, r14
    lea     rsi, [rsp+24]
    call    bk_high_normal
    movss   xmm0, [r14+RAY_T]           # the hit point
    xor     ecx, ecx
52: movss   xmm1, [r14+RAY_D+rcx*4]
    mulss   xmm1, xmm0
    addss   xmm1, [r14+RAY_O+rcx*4]
    movss   [rsp+128+rcx*4], xmm1
    inc     ecx
    cmp     ecx, 3
    jb      52b
    lea     rdi, [rsp+24]               # a frame around the high normal
    lea     rsi, [rsp+140]
    lea     rdx, [rsp+152]
    call    bk_basis
    mov     dword ptr [rsp+164], 0      # unblocked
    xor     ecx, ecx
53: cmp     ecx, AO_N
    jae     58f
    mov     [rsp+168], ecx
    mov     edi, r12d                   # (texel, ray): two numbers
    mov     esi, r13d
    mov     edx, ecx
    call    bk_rand2                    # xmm0, xmm1 in [0, 1)
    sqrtss  xmm2, xmm0                  # cosine: r = sqrt(u1), phi = 2pi u2
    movss   [rsp+172], xmm2
    mulss   xmm1, [rip+bk_2pi]
    movss   xmm0, xmm1
    call    sincos                      # xmm0 sin, xmm1 cos
    mulss   xmm0, [rsp+172]             # y = r sin, x = r cos,
    mulss   xmm1, [rsp+172]             # z = sqrt(1 - r^2)
    movss   xmm2, [rsp+172]
    mulss   xmm2, xmm2
    movss   xmm3, [rip+bk_one]
    subss   xmm3, xmm2
    maxss   xmm3, [rip+bk_tiny]
    sqrtss  xmm3, xmm3
    lea     r8, [rsp+176]               # the occlusion ray
    xor     edx, edx
54: movss   xmm4, [rsp+140+rdx*4]       # x T' + y B' + z n
    mulss   xmm4, xmm1
    movss   xmm5, [rsp+152+rdx*4]
    mulss   xmm5, xmm0
    addss   xmm4, xmm5
    movss   xmm5, [rsp+24+rdx*4]
    mulss   xmm5, xmm3
    addss   xmm4, xmm5
    movss   [r8+RAY_D+rdx*4], xmm4
    movss   xmm5, [rsp+24+rdx*4]        # from a hair above the hit
    mulss   xmm5, [rip+bk_eps]
    mulss   xmm5, [rip+bk_dist]
    addss   xmm5, [rsp+128+rdx*4]
    movss   [r8+RAY_O+rdx*4], xmm5
    inc     edx
    cmp     edx, 3
    jb      54b
    movss   xmm4, [rip+bk_dist]
    mulss   xmm4, [rip+bk_ao_far]
    movss   [r8+RAY_TMAX], xmm4
    mov     rdi, r8
    call    hv_occluded
    test    eax, eax
    jnz     55f
    inc     dword ptr [rsp+164]
55: mov     ecx, [rsp+168]
    inc     ecx
    jmp     53b
58: cvtsi2ss xmm0, dword ptr [rsp+164]
    mov     eax, AO_N
    cvtsi2ss xmm1, eax
    divss   xmm0, xmm1
    jmp     .Lbt_grey
.Lbt_curv:                              # how far the surface around falls
    cmp     dword ptr [rsp+60], 0       #  below the tangent plane there
    jne     61f
    mov     eax, 0xff808080
    jmp     .Lbt_write
61: mov     rdi, r14
    lea     rsi, [rsp+24]
    call    bk_high_normal
    movss   xmm0, [r14+RAY_T]
    xor     ecx, ecx
62: movss   xmm1, [r14+RAY_D+rcx*4]
    mulss   xmm1, xmm0
    addss   xmm1, [r14+RAY_O+rcx*4]
    movss   [rsp+128+rcx*4], xmm1
    inc     ecx
    cmp     ecx, 3
    jb      62b
    lea     rdi, [rsp+24]
    lea     rsi, [rsp+140]
    lea     rdx, [rsp+152]
    call    bk_basis
    movss   xmm0, [rip+bk_diag]         # r
    mulss   xmm0, [rip+bk_probe]
    movss   [rsp+172], xmm0
    xorps   xmm0, xmm0
    movss   [rsp+164], xmm0             # sum of the drops
    xor     ecx, ecx
63: cmp     ecx, CV_N
    jae     68f
    mov     [rsp+168], ecx
    lea     rax, [rip+bk_dirs]
    movss   xmm0, [rax+rcx*8]           # cos, sin
    movss   xmm1, [rax+rcx*8+4]
    lea     r8, [rsp+176]               # from H + (dir + n) r, along -n
    xor     edx, edx
64: movss   xmm2, [rsp+140+rdx*4]
    mulss   xmm2, xmm0
    movss   xmm3, [rsp+152+rdx*4]
    mulss   xmm3, xmm1
    addss   xmm2, xmm3
    addss   xmm2, [rsp+24+rdx*4]
    mulss   xmm2, [rsp+172]
    addss   xmm2, [rsp+128+rdx*4]
    movss   [r8+RAY_O+rdx*4], xmm2
    xorps   xmm2, xmm2
    subss   xmm2, [rsp+24+rdx*4]
    movss   [r8+RAY_D+rdx*4], xmm2
    inc     edx
    cmp     edx, 3
    jb      64b
    movss   xmm2, [rsp+172]
    mulss   xmm2, [rip+bk_three]
    movss   [r8+RAY_TMAX], xmm2
    mov     rdi, r8
    call    hv_trace
    movss   xmm0, [rip+bk_one]          # (missed: fell off, convex)
    test    eax, eax
    jz      65f
    lea     rdi, [rsp+176]              # (n' - n) . dir
    lea     rsi, [rsp+240]
    call    bk_high_normal
    mov     ecx, [rsp+168]
    lea     rax, [rip+bk_dirs]
    xorps   xmm0, xmm0
    xor     edx, edx
66: movss   xmm1, [rsp+240+rdx*4]
    subss   xmm1, [rsp+24+rdx*4]
    movss   xmm2, [rsp+140+rdx*4]
    mulss   xmm2, [rax+rcx*8]
    movss   xmm3, [rsp+152+rdx*4]
    mulss   xmm3, [rax+rcx*8+4]
    addss   xmm2, xmm3
    mulss   xmm1, xmm2
    addss   xmm0, xmm1
    inc     edx
    cmp     edx, 3
    jb      66b
65: addss   xmm0, [rsp+164]
    movss   [rsp+164], xmm0
    mov     ecx, [rsp+168]
    inc     ecx
    jmp     63b
68: movss   xmm0, [rsp+164]             # 0.5 + gain x the mean
    mulss   xmm0, [rip+bk_curv]
    addss   xmm0, [rip+bk_half]
.Lbt_grey:
    call    bk_byte
    mov     eax, edx
    imul    eax, 0x010101
    or      eax, 0xff000000
.Lbt_write:
    mov     rcx, [rip+bk_img]
    mov     edx, r13d
    imul    edx, [rcx+IM_W]
    add     edx, r12d
    mov     rcx, [rip+bk_pix]
    mov     [rcx+rdx*4], eax
    mov     rcx, [rip+bk_mask]
    mov     byte ptr [rcx+rdx], 1
    lock inc dword ptr [rip+bk_count]
    add     rsp, 296
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# bk_mat(rdi=bk_job's frame, rsi=bk_texel's: P +0, N +12) -> eax = the
#   material's texel (0xAARRGGBB) for bk_kind
bk_mat:
    push    rbx
    push    r12
    push    r13
    sub     rsp, 400                    # SC +0 (216), copy +224 (128), +352
    mov     rbx, rdi
    mov     r12, rsi
    mov     rax, [rip+bk_mesh]          # object space: p0, e1, e2
    mov     ecx, [rbx+200]
    lea     ecx, [rcx+rcx*2]
    mov     rdx, [rax+ME_TRIS]
    lea     r13, [rdx+rcx*4]
    mov     r8, [rax+ME_POS]
    xor     ecx, ecx
1:  mov     eax, [r13]
    lea     rax, [rax+rax*2]
    lea     rax, [r8+rax*4]
    movss   xmm0, [rax+rcx*4]
    movss   [rsp+SC_P0O+rcx*4], xmm0
    mov     edx, [r13+4]
    lea     rdx, [rdx+rdx*2]
    lea     rdx, [r8+rdx*4]
    movss   xmm1, [rdx+rcx*4]
    subss   xmm1, xmm0
    movss   [rsp+SC_E1O+rcx*4], xmm1
    mov     edx, [r13+8]
    lea     rdx, [rdx+rdx*2]
    lea     rdx, [r8+rdx*4]
    movss   xmm1, [rdx+rcx*4]
    subss   xmm1, xmm0
    movss   [rsp+SC_E2O+rcx*4], xmm1
    movss   xmm0, [rbx+rcx*4]           # world edges
    movss   xmm1, [rbx+12+rcx*4]
    subss   xmm1, xmm0
    movss   [rsp+SC_PU+rcx*4], xmm1
    movss   xmm1, [rbx+24+rcx*4]
    subss   xmm1, xmm0
    movss   [rsp+SC_PV+rcx*4], xmm1
    movss   xmm0, [r12+12+rcx*4]        # the normal, the point, the eye
    movss   [rsp+SC_N+rcx*4], xmm0
    movss   [rsp+SC_WV+rcx*4], xmm0
    movss   xmm0, [r12+rcx*4]
    movss   [rsp+SC_WP+rcx*4], xmm0
    mov     dword ptr [rsp+SC_VC+rcx*4], 0x3f800000
    inc     ecx
    cmp     ecx, 3
    jb      1b
    mov     eax, [rbx+156]              # barycentrics of corners 1, 2
    mov     [rsp+SC_U], eax
    mov     eax, [rbx+160]
    mov     [rsp+SC_V], eax
    lea     rax, [rbx+96]               # the triangle's UVs
    mov     [rsp+SC_UVP], rax
    mov     dword ptr [rsp+SC_FLAGS], 0
    mov     rsi, [rip+bk_mrec]          # its values, the graph over them
    lea     rdi, [rsp+224]
    mov     ecx, 32
    rep     movsd
    mov     rdi, [rip+bk_mrec]
    lea     rsi, [rsp]
    lea     rdx, [rsp+224]
    xor     ecx, ecx
    call    graph_shade
    mov     r13d, [rsp+SC_FLAGS]
    mov     eax, [rip+bk_kind]
    cmp     eax, BK_ORM
    je      .Lbm_orm
    cmp     eax, BK_NORMAL
    je      .Lbm_nrm
    cmp     eax, BK_EMIT
    je      .Lbm_emit
    movss   xmm0, [rsp+224+MA_ALPHA]    # base: alpha (or the mask), sRGB
    test    r13d, 1 << PIN_MASK
    jz      2f
    movss   xmm0, [rsp+224+MA_RT_MASK]
2:  call    bk_byte
    mov     [rsp+352], edx
    lea     rax, [rsp+224+MA_BASE]
    jmp     .Lbm_srgb
.Lbm_emit:
    xor     ecx, ecx                    # emission x strength
3:  movss   xmm0, [rsp+224+MA_EMIT+rcx*4]
    mulss   xmm0, [rsp+224+MA_ESTR]
    movss   [rsp+360+rcx*4], xmm0
    inc     ecx
    cmp     ecx, 3
    jb      3b
    mov     dword ptr [rsp+352], 255
    lea     rax, [rsp+360]
.Lbm_srgb:
    mov     [rsp+376], rax
    xor     ecx, ecx
4:  mov     [rsp+384], ecx
    mov     rax, [rsp+376]
    movss   xmm0, [rax+rcx*4]
    xorps   xmm1, xmm1
    maxss   xmm0, xmm1
    minss   xmm0, [rip+bk_one]
    call    lin_to_srgb
    call    bk_byte
    mov     eax, [rsp+352]
    shl     eax, 8
    or      eax, edx
    mov     [rsp+352], eax
    mov     ecx, [rsp+384]
    inc     ecx
    cmp     ecx, 3
    jb      4b
    mov     eax, [rsp+352]
    jmp     9f
.Lbm_orm:
    movss   xmm0, [rip+bk_one]          # occlusion, roughness, metallic
    test    r13d, 1 << PIN_AO
    jz      5f
    movss   xmm0, [rsp+224+MA_RT_AO]
5:  call    bk_byte
    mov     eax, 0xff
    shl     eax, 8
    or      eax, edx
    movss   xmm0, [rsp+224+MA_ROUGH]
    call    bk_byte
    shl     eax, 8
    or      eax, edx
    movss   xmm0, [rsp+224+MA_METAL]
    call    bk_byte
    shl     eax, 8
    or      eax, edx
    jmp     9f
.Lbm_nrm:
    mov     eax, 0xff8080ff             # (no normal of its own: flat)
    test    r13d, 1 << PIN_NORMAL
    jz      9f
    lea     rdi, [rsp+SC_N]
    call    bk_unit
    lea     rdi, [rbx+72]               # T, B orthonormal to N: +352, +364
    lea     rsi, [rsp+352]
    lea     rdx, [r12+12]
    call    bk_orth
    lea     rdi, [rbx+84]
    lea     rsi, [rsp+364]
    lea     rdx, [r12+12]
    call    bk_orth
    xor     ecx, ecx                    # (n.T, n.B, n.N) -> 0.5 + c / 2
    mov     eax, 0xff
6:  lea     rdx, [rsp+352]
    cmp     ecx, 1
    jne     61f
    lea     rdx, [rsp+364]
61: cmp     ecx, 2
    jne     62f
    lea     rdx, [r12+12]
62: movss   xmm0, [rsp+SC_N]
    mulss   xmm0, [rdx]
    movss   xmm1, [rsp+SC_N+4]
    mulss   xmm1, [rdx+4]
    addss   xmm0, xmm1
    movss   xmm1, [rsp+SC_N+8]
    mulss   xmm1, [rdx+8]
    addss   xmm0, xmm1
    mulss   xmm0, [rip+bk_half]
    addss   xmm0, [rip+bk_half]
    call    bk_byte
    shl     eax, 8
    or      eax, edx
    inc     ecx
    cmp     ecx, 3
    jb      6b
9:  add     rsp, 400
    pop     r13
    pop     r12
    pop     rbx
    ret

# bk_orth(rdi=vector, rsi=out, rdx=unit n) - the vector made orthogonal to
#   n, unit (keeps rcx)
bk_orth:
    movss   xmm0, [rdi]                 # v . n
    mulss   xmm0, [rdx]
    movss   xmm1, [rdi+4]
    mulss   xmm1, [rdx+4]
    addss   xmm0, xmm1
    movss   xmm1, [rdi+8]
    mulss   xmm1, [rdx+8]
    addss   xmm0, xmm1
    xor     eax, eax
1:  movss   xmm1, [rdx+rax*4]
    mulss   xmm1, xmm0
    movss   xmm2, [rdi+rax*4]
    subss   xmm2, xmm1
    movss   [rsi+rax*4], xmm2
    inc     eax
    cmp     eax, 3
    jb      1b
    mov     rdi, rsi
    jmp     bk_unit

# bake_material(rdi=object, esi=kind 0 base 1 orm 2 normal 3 emissive,
#   rdx=image) -> eax = texels baked (-1: no UVs, no material, not 8-bit)
bake_material:
    push    rbx
    push    r12
    push    r13
    mov     rbx, rdi
    mov     r12d, esi
    mov     r13, rdx
    call    mat_of
    test    eax, eax
    js      8f
    mov     edi, eax
    push    rax
    push    rax
    call    mat_sync_check              # (an instance: up to date)
    pop     rdi
    pop     rax
    call    mat_get
    test    rax, rax
    jz      8f
    mov     [rip+bk_mrec], rax
    mov     rdi, rbx
    mov     rsi, rbx
    lea     edx, [r12+BK_BASE]
    mov     rcx, r13
    xorps   xmm0, xmm0
    call    bake
    jmp     9f
8:  mov     eax, -1
9:  pop     r13
    pop     r12
    pop     rbx
    ret

# bk_byte(xmm0 = 0..1) -> edx = 0..255 (keeps eax, ecx)
bk_byte:
    xorps   xmm1, xmm1
    maxss   xmm0, xmm1
    minss   xmm0, [rip+bk_one]
    mulss   xmm0, [rip+bk_255]
    addss   xmm0, [rip+bk_half]
    cvttss2si edx, xmm0
    ret

# bk_high_normal(rdi=ray that hit, rsi=out) - the high triangle's corner
#   normals at (u, v), unit
bk_high_normal:
    mov     eax, [rdi+RAY_TRI]
    imul    eax, eax, 36
    mov     rcx, [rip+hv_tn]
    add     rcx, rax
    movss   xmm2, [rip+bk_one]
    subss   xmm2, [rdi+RAY_U]
    subss   xmm2, [rdi+RAY_V]
    xor     edx, edx
1:  movss   xmm0, [rcx+rdx*4]
    mulss   xmm0, xmm2
    movss   xmm1, [rcx+12+rdx*4]
    mulss   xmm1, [rdi+RAY_U]
    addss   xmm0, xmm1
    movss   xmm1, [rcx+24+rdx*4]
    mulss   xmm1, [rdi+RAY_V]
    addss   xmm0, xmm1
    movss   [rsi+rdx*4], xmm0
    inc     edx
    cmp     edx, 3
    jb      1b
    mov     rdi, rsi
    jmp     bk_unit

# bk_ortho(rdi=vector, rsi=out; [rsp+8+12] = N of bk_texel's frame) - the
#   vector without its N part, unit
bk_ortho:
    movss   xmm0, [rdi]                 # d = v . N
    mulss   xmm0, [rsp+8+12]
    movss   xmm1, [rdi+4]
    mulss   xmm1, [rsp+8+16]
    addss   xmm0, xmm1
    movss   xmm1, [rdi+8]
    mulss   xmm1, [rsp+8+20]
    addss   xmm0, xmm1
    xor     ecx, ecx
1:  movss   xmm1, [rsp+8+12+rcx*4]
    mulss   xmm1, xmm0
    movss   xmm2, [rdi+rcx*4]
    subss   xmm2, xmm1
    movss   [rsi+rcx*4], xmm2
    inc     ecx
    cmp     ecx, 3
    jb      1b
    mov     rdi, rsi
    jmp     bk_unit

# bk_basis(rdi=unit n, rsi=out t, rdx=out b) - an orthonormal frame
bk_basis:
    movss   xmm0, [rdi]                 # a = (1 0 0), or (0 1 0) when n is
    andps   xmm0, [rip+bk_absmask]      #  near x
    comiss  xmm0, [rip+bk_half]
    jae     2f
    movss   xmm0, [rdi+8]               # a = (1 0 0): t = (0, n.z, -n.y)
    xorps   xmm1, xmm1
    movss   [rsi], xmm1
    movss   [rsi+4], xmm0
    xorps   xmm0, xmm0
    subss   xmm0, [rdi+4]
    movss   [rsi+8], xmm0
    jmp     3f
2:  xorps   xmm0, xmm0                  # a = (0 1 0): t = (-n.z, 0, n.x)
    subss   xmm0, [rdi+8]
    movss   [rsi], xmm0
    xorps   xmm0, xmm0
    movss   [rsi+4], xmm0
    movss   xmm0, [rdi]
    movss   [rsi+8], xmm0
3:  push    rdi
    push    rdx
    mov     rdi, rsi
    call    bk_unit
    pop     rdx
    pop     rdi
    movss   xmm0, [rdi+4]               # b = n x t
    mulss   xmm0, [rsi+8]
    movss   xmm1, [rdi+8]
    mulss   xmm1, [rsi+4]
    subss   xmm0, xmm1
    movss   [rdx], xmm0
    movss   xmm0, [rdi+8]
    mulss   xmm0, [rsi]
    movss   xmm1, [rdi]
    mulss   xmm1, [rsi+8]
    subss   xmm0, xmm1
    movss   [rdx+4], xmm0
    movss   xmm0, [rdi]
    mulss   xmm0, [rsi+4]
    movss   xmm1, [rdi+4]
    mulss   xmm1, [rsi]
    subss   xmm0, xmm1
    movss   [rdx+8], xmm0
    ret

# bk_rand2(edi=x, esi=y, edx=i) -> xmm0, xmm1 = two numbers in [0, 1)
bk_rand2:
    imul    edi, edi, 0x27d4eb2d
    imul    esi, esi, 0x165667b1
    imul    edx, edx, 0x9e3779b9
    xor     edi, esi
    xor     edi, edx
    mov     eax, edi                    # (a hash: murmur-like mixing)
    shr     eax, 15
    xor     edi, eax
    imul    edi, edi, 0x2c1b3c6d
    mov     eax, edi
    shr     eax, 12
    xor     edi, eax
    imul    edi, edi, 0x297a2d39
    mov     eax, edi
    shr     eax, 15
    xor     eax, edi
    mov     ecx, eax
    shr     eax, 8                      # 24 bits each
    cvtsi2ss xmm0, eax
    mulss   xmm0, [rip+bk_inv24]
    imul    ecx, ecx, 0x85ebca6b
    mov     eax, ecx
    shr     eax, 13
    xor     eax, ecx
    shr     eax, 8
    cvtsi2ss xmm1, eax
    mulss   xmm1, [rip+bk_inv24]
    ret

# bk_dilate - texels no triangle covers take their covered neighbours'
#   average, 8 rings out
bk_dilate:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    push    rbp
    sub     rsp, 24
    mov     dword ptr [rsp], 8
.Lbd_pass:
    dec     dword ptr [rsp]
    js      9f
    mov     rbx, [rip+bk_img]
    xor     r13d, r13d                  # y
1:  cmp     r13d, [rbx+IM_H]
    jae     .Lbd_mark
    xor     r12d, r12d                  # x
2:  cmp     r12d, [rbx+IM_W]
    jae     8f
    mov     eax, r13d
    imul    eax, [rbx+IM_W]
    add     eax, r12d
    mov     rcx, [rip+bk_mask]
    cmp     byte ptr [rcx+rax], 0
    jne     7f
    mov     [rsp+4], eax
    xor     r14d, r14d                  # neighbours found, sums
    xor     r15d, r15d                  # (r g b packed sums in r8 r9 r10)
    xor     r8d, r8d
    xor     r9d, r9d
    xor     r10d, r10d
    xor     ebp, ebp                    # 4 neighbours: (-1 0)(1 0)(0 -1)(0 1)
3:  mov     ecx, r12d
    mov     edx, r13d
    cmp     ebp, 0
    jne     31f
    dec     ecx
31: cmp     ebp, 1
    jne     32f
    inc     ecx
32: cmp     ebp, 2
    jne     33f
    dec     edx
33: cmp     ebp, 3
    jne     34f
    inc     edx
34: cmp     ecx, [rbx+IM_W]
    jae     6f
    cmp     edx, [rbx+IM_H]
    jae     6f
    imul    edx, [rbx+IM_W]
    add     edx, ecx
    mov     rcx, [rip+bk_mask]
    cmp     byte ptr [rcx+rdx], 1       # (covered before this pass)
    jne     6f
    mov     rcx, [rip+bk_pix]
    mov     eax, [rcx+rdx*4]
    mov     ecx, eax
    shr     ecx, 16
    and     ecx, 0xff
    add     r8d, ecx
    mov     ecx, eax
    shr     ecx, 8
    and     ecx, 0xff
    add     r9d, ecx
    and     eax, 0xff
    add     r10d, eax
    inc     r14d
6:  inc     ebp
    cmp     ebp, 4
    jb      3b
    test    r14d, r14d
    jz      7f
    mov     eax, r8d                    # the average, marked 2 (this pass)
    xor     edx, edx
    div     r14d
    mov     r8d, eax
    mov     eax, r9d
    xor     edx, edx
    div     r14d
    mov     r9d, eax
    mov     eax, r10d
    xor     edx, edx
    div     r14d
    shl     r8d, 16
    shl     r9d, 8
    or      eax, r8d
    or      eax, r9d
    or      eax, 0xff000000
    mov     edx, [rsp+4]
    mov     rcx, [rip+bk_pix]
    mov     [rcx+rdx*4], eax
    mov     rcx, [rip+bk_mask]
    mov     byte ptr [rcx+rdx], 2
7:  inc     r12d
    jmp     2b
8:  inc     r13d
    jmp     1b
.Lbd_mark:                              # this pass's become covered
    mov     rcx, [rip+bk_mask]
    mov     eax, [rbx+IM_W]
    imul    eax, [rbx+IM_H]
10: test    eax, eax
    jz      .Lbd_pass
    dec     eax
    cmp     byte ptr [rcx+rax], 2
    jne     10b
    mov     byte ptr [rcx+rax], 1
    jmp     10b
9:  add     rsp, 24
    pop     rbp
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret
