# =============================================================================
#  BeeModel - material preview: the viewport shaded with each object's
#  principled material under a studio environment.
#
#  The rasterizer leaves a visibility buffer (the triangle record of each
#  pixel). This pass shades every covered pixel: the camera ray meets the
#  source triangle (exact barycentrics, also for near-clipped triangles),
#  per-corner normals smooth faces closer than 30 degrees (a cube stays
#  sharp, a sphere turns round), and the principled BSDF is lit by a
#  sky / ground environment (split-sum approximation) and three softbox
#  lights fixed in the world; then ACES tone mapping. Rows run in parallel.
# =============================================================================
.intel_syntax noprefix
.include "const.inc"

# exports
.globl preview_shade

.equ RO_CV,     0
.equ RO_MESH,   8
.equ RO_BASE,   16
.equ RO_NTRIS,  20
.equ RO_ID,     24
.equ RO_OBJ,    32
.equ RO_SZ,     48
.equ TRI_SZ,    48
# shading scratch (per call, on the stack): see sh_* offsets
.equ SH_N,      0               # world normal
.equ SH_V,      12              # world view vector (to the eye)
.equ SH_BASE,   24
.equ SH_METAL,  36
.equ SH_ROUGH,  40
.equ SH_SPEC,   44
.equ SH_IOR,    48
.equ SH_TRANS,  52
.equ SH_EMIT,   56              # emission * strength
.equ SH_COAT,   68
.equ SH_COATR,  72
.equ SH_OUT,    76              # colour out
.equ SH_F0,     88
.equ SH_DIFF,   100
.equ SH_NV,     112
.equ SH_R,      116             # reflection direction
.equ SH_TMP,    128             # 32 bytes
.equ SH_SZ,     176

.section .bss
.align 8
pv_map:         .skip 8             # object id -> record index
pv_cn:          .skip 8             # per record: corner normals (camera)
pv_mat:         .skip 8             # per record: material record or 0
pv_mapn:        .skip 4

.section .rodata
.align 16
pf_absm:        .long 0x7fffffff, 0, 0, 0
pf_sign:        .long 0x80000000, 0, 0, 0
pf_one:         .float 1.0
pf_half:        .float 0.5
pf_zero:        .float 0.0
pf_eps:         .float 1.0e-4
pf_cos30:       .float 0.8660254
pf_inv_pi:      .float 0.31830989
pf_255:         .float 255.0
pf_two:         .float 2.0
pf_four:        .float 4.0
pf_008:         .float 0.08
pf_004:         .float 0.04
pf_five:        .float 5.0
pf_amin:        .float 0.003
pf_soft:        .float 0.04             # softbox size (widens the lobe)
pf_m928:        .float -9.28
pf_c0:          .float -1.0, -0.0275, -0.572, 0.022
pf_c1:          .float 1.0, 0.0425, 1.04, -0.04
pf_m104:        .float -1.04
pf_p104:        .float 1.04
pf_aces_a:      .float 2.51
pf_aces_b:      .float 0.03
pf_aces_c:      .float 2.43
pf_aces_d:      .float 0.59
pf_aces_e:      .float 0.14
pf_expo:        .float 1.0
# environment (linear)
env_zenith:     .float 0.34, 0.46, 0.74
env_horizon:    .float 0.72, 0.74, 0.78
env_ground:     .float 0.20, 0.19, 0.17
env_sky_irr:    .float 0.46, 0.50, 0.60
env_gnd_irr:    .float 0.20, 0.19, 0.17
# softbox lights: direction (to the light, world, unit), colour * intensity
lights:         .float 0.5246, 0.7343, 0.4302,  1.7, 1.65, 1.55
                .float -0.6230, 0.3560, -0.6963, 0.6, 0.7, 0.95
                .float -0.6670, 0.2665, 0.6960,  0.3, 0.3, 0.32
mat_default:    .float 0.8, 0.8, 0.8, 0.0, 0.5, 0.5, 1.45, 0.0
                .float 0.0, 0.0, 0.0, 0.0, 0.0, 0.03, 1.0

.text

# =============================================================================
# preview_shade - after the rasterizer (vp_shading = 2)
# =============================================================================
preview_shade:
    push    rbx
    push    r12
    push    r13
    sub     rsp, 16
    call    tex_init
    call    env_prep
    mov     edi, [rip+obj_count]        # object id (scene index + 1) -> record
    lea     esi, [rdi*4+8]
    lea     rdi, [rip+frame_arena]
    call    arena_alloc
    test    rax, rax
    jz      9f
    mov     [rip+pv_map], rax
    mov     ecx, [rip+obj_count]
    inc     ecx
    mov     rdi, rax
    mov     eax, -1
    rep     stosd
    mov     edi, [rip+rs_nobjs]
    lea     esi, [rdi*8+8]
    lea     rdi, [rip+frame_arena]
    call    arena_alloc
    test    rax, rax
    jz      9f
    mov     [rip+pv_cn], rax
    mov     edi, [rip+rs_nobjs]
    lea     esi, [rdi*8+8]
    lea     rdi, [rip+frame_arena]
    call    arena_alloc
    test    rax, rax
    jz      9f
    mov     [rip+pv_mat], rax
    xor     ebx, ebx                    # records: map, material, normals
1:  cmp     ebx, [rip+rs_nobjs]
    jae     2f
    imul    r12, rbx, RO_SZ
    add     r12, [rip+rs_objs]
    mov     eax, [r12+RO_ID]
    mov     rcx, [rip+pv_map]
    mov     [rcx+rax*4], ebx
    mov     rdi, [r12+RO_OBJ]
    call    mat_of
    xor     ecx, ecx
    test    eax, eax
    js      11f
    mov     edi, eax
    call    mat_get
    mov     rcx, rax
11: mov     rax, [rip+pv_mat]
    mov     [rax+rbx*8], rcx
    mov     rax, [r12+RO_MESH]          # corner normals: 36 bytes a triangle
    mov     esi, [rax+ME_NTRIS]
    imul    esi, esi, 36
    add     esi, 16
    lea     rdi, [rip+frame_arena]
    call    arena_alloc
    mov     rcx, [rip+pv_cn]
    mov     [rcx+rbx*8], rax
    inc     ebx
    jmp     1b
2:  lea     rdi, [rip+job_normals]      # normals, one object per job
    xor     esi, esi
    mov     edx, [rip+rs_nobjs]
    mov     ecx, 1
    call    parallel_for
    lea     rdi, [rip+job_shade]        # then the pixels, by rows
    xor     esi, esi
    mov     edx, [rip+rs_h]
    mov     ecx, 8
    call    parallel_for
9:  add     rsp, 16
    pop     r13
    pop     r12
    pop     rbx
    ret

# =============================================================================
# job_normals(ctx, esi=first record, edx=end, ecx=thread, r8=arena) - corner
#   normals in camera space: per corner the area-weighted normals of the
#   triangles at that vertex within 30 degrees of this one
# =============================================================================
job_normals:
    push    rbx
    push    rbp
    push    r12
    push    r13
    push    r14
    push    r15
    sub     rsp, 104
    mov     [rsp], esi
    mov     [rsp+4], edx
    mov     [rsp+8], r8                 # this thread's arena
.Ljn_obj:
    mov     eax, [rsp]
    cmp     eax, [rsp+4]
    jae     .Ljn_out
    imul    r12, rax, RO_SZ
    add     r12, [rip+rs_objs]
    mov     r13, [r12+RO_MESH]
    mov     rcx, [rip+pv_cn]
    mov     r14, [rcx+rax*8]            # out
    test    r14, r14
    jz      .Ljn_next
    mov     rbp, [r12+RO_CV]
    mov     rdi, [rsp+8]                # face normals (unnormalized) f32[3]
    mov     esi, [r13+ME_NTRIS]
    imul    esi, esi, 12
    add     esi, 16
    call    arena_alloc
    test    rax, rax
    jz      .Ljn_flat
    mov     [rsp+16], rax
    mov     rdi, [rsp+8]                # vertex -> triangles (CSR)
    mov     esi, [r13+ME_NVERTS]
    lea     esi, [rsi*4+8]
    call    arena_alloc
    test    rax, rax
    jz      .Ljn_flat
    mov     [rsp+24], rax
    mov     rdi, rax
    mov     ecx, [r13+ME_NVERTS]
    inc     ecx
    xor     eax, eax
    rep     stosd
    mov     rdi, [rsp+8]
    mov     esi, [r13+ME_NTRIS]
    imul    esi, esi, 12
    add     esi, 8
    call    arena_alloc
    test    rax, rax
    jz      .Ljn_flat
    mov     [rsp+32], rax
    # face normals and counts
    xor     ebx, ebx
1:  cmp     ebx, [r13+ME_NTRIS]
    jae     2f
    mov     edi, ebx
    call    tri_cn                      # xmm0..2 = (p1-p0) x (p2-p0), camera
    mov     rax, [rsp+16]
    lea     rcx, [rbx+rbx*2]
    movss   [rax+rcx*4], xmm0
    movss   [rax+rcx*4+4], xmm1
    movss   [rax+rcx*4+8], xmm2
    mov     rax, [r13+ME_TRIS]
    mov     rdx, [rsp+24]
    mov     edi, [rax+rcx*4]
    inc     dword ptr [rdx+rdi*4+4]
    mov     edi, [rax+rcx*4+4]
    inc     dword ptr [rdx+rdi*4+4]
    mov     edi, [rax+rcx*4+8]
    inc     dword ptr [rdx+rdi*4+4]
    inc     ebx
    jmp     1b
2:  mov     rdx, [rsp+24]               # prefix sums
    xor     eax, eax
    xor     ecx, ecx
3:  cmp     ecx, [r13+ME_NVERTS]
    jae     4f
    add     eax, [rdx+rcx*4+4]
    mov     [rdx+rcx*4+4], eax
    inc     ecx
    jmp     3b
4:  xor     ebx, ebx                    # fill (cursors), then shift back
5:  cmp     ebx, [r13+ME_NTRIS]
    jae     6f
    xor     r15d, r15d
51: mov     rax, [r13+ME_TRIS]
    lea     rcx, [rbx+rbx*2]
    add     rcx, r15
    mov     edi, [rax+rcx*4]
    mov     rdx, [rsp+24]
    mov     ecx, [rdx+rdi*4]
    inc     dword ptr [rdx+rdi*4]
    mov     rax, [rsp+32]
    mov     [rax+rcx*4], ebx
    inc     r15d
    cmp     r15d, 3
    jb      51b
    inc     ebx
    jmp     5b
6:  mov     rdx, [rsp+24]
    mov     ecx, [r13+ME_NVERTS]
61: test    ecx, ecx
    jz      62f
    mov     eax, [rdx+rcx*4-4]
    mov     [rdx+rcx*4], eax
    dec     ecx
    jmp     61b
62: mov     dword ptr [rdx], 0
    # corner normals
    xor     ebx, ebx
.Ljn_tri:
    cmp     ebx, [r13+ME_NTRIS]
    jae     .Ljn_next
    mov     rax, [rsp+16]               # this face's unit normal
    lea     rcx, [rbx+rbx*2]
    lea     rsi, [rax+rcx*4]
    lea     rdi, [rsp+48]
    call    unit3
    xor     r15d, r15d                  # corner
.Ljn_corner:
    cmp     r15d, 3
    jae     .Ljn_tnext
    xorps   xmm4, xmm4                  # sum
    xorps   xmm5, xmm5
    xorps   xmm6, xmm6
    mov     rax, [r13+ME_TRIS]
    lea     rcx, [rbx+rbx*2]
    add     rcx, r15
    mov     edi, [rax+rcx*4]            # the vertex
    mov     rdx, [rsp+24]
    mov     ecx, [rdx+rdi*4]
    mov     edx, [rdx+rdi*4+4]
    mov     [rsp+40], edx
7:  cmp     ecx, [rsp+40]
    jae     8f
    mov     rax, [rsp+32]
    mov     eax, [rax+rcx*4]            # a triangle at the vertex
    mov     rsi, [rsp+16]
    lea     rax, [rax+rax*2]
    lea     rsi, [rsi+rax*4]
    lea     rdi, [rsp+64]
    push    rcx
    call    unit3                       # its unit normal; xmm3 = |n| (area*2)
    pop     rcx
    movss   xmm0, [rsp+64]              # within 30 degrees of this face?
    mulss   xmm0, [rsp+48]
    movss   xmm1, [rsp+68]
    mulss   xmm1, [rsp+52]
    addss   xmm0, xmm1
    movss   xmm1, [rsp+72]
    mulss   xmm1, [rsp+56]
    addss   xmm0, xmm1
    comiss  xmm0, [rip+pf_cos30]
    jb      71f
    movss   xmm0, [rsp+64]              # area weighted
    mulss   xmm0, xmm3
    addss   xmm4, xmm0
    movss   xmm0, [rsp+68]
    mulss   xmm0, xmm3
    addss   xmm5, xmm0
    movss   xmm0, [rsp+72]
    mulss   xmm0, xmm3
    addss   xmm6, xmm0
71: inc     ecx
    jmp     7b
8:  movss   [rsp+80], xmm4
    movss   [rsp+84], xmm5
    movss   [rsp+88], xmm6
    lea     rsi, [rsp+80]
    lea     rdi, [rsp+80]
    call    unit3
    xorps   xmm0, xmm0                  # nothing (degenerate): the face's
    comiss  xmm3, xmm0
    ja      81f
    mov     rax, [rsp+48]
    mov     [rsp+80], rax
    mov     eax, [rsp+56]
    mov     [rsp+88], eax
81: lea     rcx, [rbx+rbx*2]            # out[tri][corner]
    add     rcx, r15
    lea     rcx, [rcx+rcx*2]
    mov     rax, [rsp+80]
    mov     [r14+rcx*4], rax
    mov     eax, [rsp+88]
    mov     [r14+rcx*4+8], eax
    inc     r15d
    jmp     .Ljn_corner
.Ljn_tnext:
    inc     ebx
    jmp     .Ljn_tri
.Ljn_flat:                              # (no memory: face normals only)
    xor     ebx, ebx
9:  cmp     ebx, [r13+ME_NTRIS]
    jae     .Ljn_next
    mov     edi, ebx
    call    tri_cn
    movss   [rsp+80], xmm0
    movss   [rsp+84], xmm1
    movss   [rsp+88], xmm2
    lea     rsi, [rsp+80]
    lea     rdi, [rsp+80]
    call    unit3
    lea     rcx, [rbx+rbx*2]
    lea     rcx, [rcx+rcx*2]
    xor     edx, edx
91: mov     rax, [rsp+80]
    mov     [r14+rcx*4], rax
    mov     eax, [rsp+88]
    mov     [r14+rcx*4+8], eax
    add     rcx, 3
    inc     edx
    cmp     edx, 3
    jb      91b
    inc     ebx
    jmp     9b
.Ljn_next:
    inc     dword ptr [rsp]
    jmp     .Ljn_obj
.Ljn_out:
    add     rsp, 104
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbp
    pop     rbx
    ret

# tri_cn(edi=triangle; r13 = mesh, rbp = camera-space vertices) -> xmm0..2 =
#   (p1 - p0) x (p2 - p0)
tri_cn:
    mov     rax, [r13+ME_TRIS]
    lea     rcx, [rdi+rdi*2]
    mov     edx, [rax+rcx*4]
    mov     esi, [rax+rcx*4+4]
    mov     edi, [rax+rcx*4+8]
    lea     rdx, [rdx+rdx*2]
    lea     rsi, [rsi+rsi*2]
    lea     rdi, [rdi+rdi*2]
    lea     rdx, [rbp+rdx*4]
    lea     rsi, [rbp+rsi*4]
    lea     rdi, [rbp+rdi*4]
    movss   xmm3, [rsi]                 # e1
    subss   xmm3, [rdx]
    movss   xmm4, [rsi+4]
    subss   xmm4, [rdx+4]
    movss   xmm5, [rsi+8]
    subss   xmm5, [rdx+8]
    movss   xmm6, [rdi]                 # e2
    subss   xmm6, [rdx]
    movss   xmm7, [rdi+4]
    subss   xmm7, [rdx+4]
    movss   xmm8, [rdi+8]
    subss   xmm8, [rdx+8]
    movss   xmm0, xmm4                  # e1 x e2
    mulss   xmm0, xmm8
    movss   xmm9, xmm5
    mulss   xmm9, xmm7
    subss   xmm0, xmm9
    movss   xmm1, xmm5
    mulss   xmm1, xmm6
    movss   xmm9, xmm3
    mulss   xmm9, xmm8
    subss   xmm1, xmm9
    movss   xmm2, xmm3
    mulss   xmm2, xmm7
    movss   xmm9, xmm4
    mulss   xmm9, xmm6
    subss   xmm2, xmm9
    ret

# unit3(rsi=float[3] in, rdi=out) -> out = unit vector, xmm3 = the length
unit3:
    movss   xmm0, [rsi]
    movss   xmm1, [rsi+4]
    movss   xmm2, [rsi+8]
    movss   xmm3, xmm0
    mulss   xmm3, xmm0
    movss   xmm7, xmm1
    mulss   xmm7, xmm1
    addss   xmm3, xmm7
    movss   xmm7, xmm2
    mulss   xmm7, xmm2
    addss   xmm3, xmm7
    sqrtss  xmm3, xmm3
    xorps   xmm7, xmm7
    comiss  xmm3, xmm7
    jbe     1f
    movss   xmm7, [rip+pf_one]
    divss   xmm7, xmm3
    mulss   xmm0, xmm7
    mulss   xmm1, xmm7
    mulss   xmm2, xmm7
1:  movss   [rdi], xmm0
    movss   [rdi+4], xmm1
    movss   [rdi+8], xmm2
    ret

# =============================================================================
# job_shade(ctx, esi=first row, edx=end) - every covered pixel
# =============================================================================
job_shade:
    push    rbx
    push    rbp
    push    r12
    push    r13
    push    r14
    push    r15
    sub     rsp, SH_SZ+120
    mov     [rsp+SH_SZ], esi
    mov     [rsp+SH_SZ+4], edx
.Ljs_row:
    mov     eax, [rsp+SH_SZ]
    cmp     eax, [rsp+SH_SZ+4]
    jae     .Ljs_out
    mov     r12d, eax                   # y (buffer)
    xor     r13d, r13d                  # x
.Ljs_px:
    cmp     r13d, [rip+rs_w]
    jae     .Ljs_rnext
    mov     eax, r12d
    imul    eax, [rip+rs_w]
    add     eax, r13d
    mov     rcx, [rip+rs_tri]
    mov     ebx, [rcx+rax*4]            # triangle record + 1
    test    ebx, ebx
    jz      .Ljs_pnext
    dec     ebx
    imul    rbx, rbx, TRI_SZ
    add     rbx, [rip+rs_tris]
    mov     eax, [rbx+40]               # object id -> record
    mov     rcx, [rip+pv_map]
    mov     ebp, [rcx+rax*4]
    test    ebp, ebp
    js      .Ljs_pnext
    imul    r14, rbp, RO_SZ
    add     r14, [rip+rs_objs]
    mov     r15d, [rbx+44]              # the source triangle (local)
    mov     r8, [r14+RO_MESH]
    cmp     r15d, [r8+ME_NTRIS]
    jae     .Ljs_pnext
    # the camera ray through the pixel centre: d = (dx, dy, 1)
    cvtsi2ss xmm0, r13d
    addss   xmm0, [rip+pf_half]
    cvtsi2ss xmm1, dword ptr [rip+rs_x0]
    addss   xmm0, xmm1
    subss   xmm0, [rip+vp_cx]
    divss   xmm0, [rip+vp_focal]
    movss   [rsp+SH_SZ+8], xmm0
    cvtsi2ss xmm1, r12d
    addss   xmm1, [rip+pf_half]
    cvtsi2ss xmm2, dword ptr [rip+rs_y0]
    addss   xmm1, xmm2
    movss   xmm2, [rip+vp_cy]
    subss   xmm2, xmm1
    divss   xmm2, [rip+vp_focal]
    movss   [rsp+SH_SZ+12], xmm2
    mov     dword ptr [rsp+SH_SZ+16], 0x3f800000
    call    ray_bary                    # u, v at [rsp+SH_SZ+20 / 24], t at 28
    test    eax, eax
    jz      .Ljs_pnext
    call    pixel_normal                # world N, V into the scratch
    mov     rax, [rip+pv_mat]           # material values
    mov     rsi, [rax+rbp*8]
    call    load_material
    mov     rax, [rip+pv_mat]           # a textured base
    mov     rdi, [rax+rbp*8]
    test    rdi, rdi
    jz      1f
    cmp     dword ptr [rdi+92], 0
    je      1f
    lea     rsi, [rsp]
    call    pv_texture
1:  lea     rdi, [rsp]
    call    shade
    mov     eax, r12d                   # write the pixel
    add     eax, [rip+rs_y0]
    imul    eax, [rip+fb_w]
    add     eax, r13d
    add     eax, [rip+rs_x0]
    mov     rcx, [rip+fb_ptr]
    mov     edx, [rsp+SH_OUT+12]
    mov     [rcx+rax*4], edx
.Ljs_pnext:
    inc     r13d
    jmp     .Ljs_px
.Ljs_rnext:
    inc     dword ptr [rsp+SH_SZ]
    jmp     .Ljs_row
.Ljs_out:
    add     rsp, SH_SZ+120
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbp
    pop     rbx
    ret

# pv_texture(rdi=material record, rsi=job_shade's frame; r14 = object
#   record, r15d = local triangle) - SH_BASE from the box-projected image
pv_texture:
    push    rbx
    push    r12
    sub     rsp, 40
    mov     rbx, rdi
    mov     r12, rsi
    mov     r8, [r14+RO_MESH]
    mov     rax, [r8+ME_TRIS]
    lea     rcx, [r15+r15*2]
    mov     edx, [rax+rcx*4]
    mov     esi, [rax+rcx*4+4]
    mov     edi, [rax+rcx*4+8]
    mov     r9, [r8+ME_POS]
    lea     rdx, [rdx+rdx*2]
    lea     rsi, [rsi+rsi*2]
    lea     rdi, [rdi+rdi*2]
    lea     rdi, [r9+rdi*4]             # p2 -> rdx below
    lea     rsi, [r9+rsi*4]
    lea     rax, [r9+rdx*4]
    mov     rdx, rdi
    mov     rdi, rax
    lea     rcx, [rsp]
    call    box_uv
    movss   xmm2, [rip+pf_one]          # uv = w0 uv0 + u uv1 + v uv2
    subss   xmm2, [r12+SH_SZ+20]
    subss   xmm2, [r12+SH_SZ+24]
    xor     ecx, ecx
1:  movss   xmm0, [rsp+rcx*4]
    mulss   xmm0, xmm2
    movss   xmm1, [rsp+8+rcx*4]
    mulss   xmm1, [r12+SH_SZ+20]
    addss   xmm0, xmm1
    movss   xmm1, [rsp+16+rcx*4]
    mulss   xmm1, [r12+SH_SZ+24]
    addss   xmm0, xmm1
    movss   [rsp+24+rcx*4], xmm0
    inc     ecx
    cmp     ecx, 2
    jb      1b
    mov     rdi, rbx
    movss   xmm0, [rsp+24]
    movss   xmm1, [rsp+28]
    lea     rsi, [r12+SH_BASE]
    call    mat_texel
    add     rsp, 40
    pop     r12
    pop     rbx
    ret

# ray_bary - (job_shade's frame, one level up) the ray d against the source
#   triangle r15d of record r14: u v t; eax = 0 when parallel
ray_bary:
    lea     r9, [rsp+8]                 # job_shade's rsp
    mov     r8, [r14+RO_MESH]
    mov     rax, [r8+ME_TRIS]
    lea     rcx, [r15+r15*2]
    mov     edx, [rax+rcx*4]
    mov     esi, [rax+rcx*4+4]
    mov     edi, [rax+rcx*4+8]
    mov     r10, [r14+RO_CV]
    lea     rdx, [rdx+rdx*2]
    lea     rsi, [rsi+rsi*2]
    lea     rdi, [rdi+rdi*2]
    lea     rdx, [r10+rdx*4]            # p0
    lea     rsi, [r10+rsi*4]            # p1
    lea     rdi, [r10+rdi*4]            # p2
    movss   xmm3, [rsi]                 # e1 = p1 - p0
    subss   xmm3, [rdx]
    movss   xmm4, [rsi+4]
    subss   xmm4, [rdx+4]
    movss   xmm5, [rsi+8]
    subss   xmm5, [rdx+8]
    movss   xmm6, [rdi]                 # e2 = p2 - p0
    subss   xmm6, [rdx]
    movss   xmm7, [rdi+4]
    subss   xmm7, [rdx+4]
    movss   xmm8, [rdi+8]
    subss   xmm8, [rdx+8]
    movss   xmm10, [r9+SH_SZ+8]         # d
    movss   xmm11, [r9+SH_SZ+12]
    movss   xmm12, [r9+SH_SZ+16]
    movss   xmm0, xmm11                 # p = d x e2
    mulss   xmm0, xmm8
    movss   xmm9, xmm12
    mulss   xmm9, xmm7
    subss   xmm0, xmm9
    movss   xmm1, xmm12
    mulss   xmm1, xmm6
    movss   xmm9, xmm10
    mulss   xmm9, xmm8
    subss   xmm1, xmm9
    movss   xmm2, xmm10
    mulss   xmm2, xmm7
    movss   xmm9, xmm11
    mulss   xmm9, xmm6
    subss   xmm2, xmm9
    movss   xmm9, xmm3                  # det = e1 . p
    mulss   xmm9, xmm0
    movss   xmm13, xmm4
    mulss   xmm13, xmm1
    addss   xmm9, xmm13
    movss   xmm13, xmm5
    mulss   xmm13, xmm2
    addss   xmm9, xmm13
    movss   xmm13, xmm9
    andps   xmm13, [rip+pf_absm]
    comiss  xmm13, [rip+pf_zero]
    jbe     8f
    movss   xmm13, [rip+pf_one]
    divss   xmm13, xmm9                 # inv
    movss   xmm14, [rdx]                # s = origin - p0 = -p0
    xorps   xmm14, [rip+pf_sign]
    movss   xmm15, [rdx+4]
    xorps   xmm15, [rip+pf_sign]
    movss   xmm9, [rdx+8]
    xorps   xmm9, [rip+pf_sign]
    mulss   xmm0, xmm14                 # u = s . p * inv
    mulss   xmm1, xmm15
    addss   xmm0, xmm1
    mulss   xmm2, xmm9
    addss   xmm0, xmm2
    mulss   xmm0, xmm13
    movss   [r9+SH_SZ+20], xmm0
    movss   xmm0, xmm15                 # q = s x e1
    mulss   xmm0, xmm5
    movss   xmm1, xmm9
    mulss   xmm1, xmm4
    subss   xmm0, xmm1
    movss   xmm1, xmm9
    mulss   xmm1, xmm3
    movss   xmm2, xmm14
    mulss   xmm2, xmm5
    subss   xmm1, xmm2
    movss   xmm2, xmm14
    mulss   xmm2, xmm4
    movss   xmm9, xmm15
    mulss   xmm9, xmm3
    subss   xmm2, xmm9
    movss   xmm9, xmm10                 # v = d . q * inv
    mulss   xmm9, xmm0
    movss   xmm14, xmm11
    mulss   xmm14, xmm1
    addss   xmm9, xmm14
    movss   xmm14, xmm12
    mulss   xmm14, xmm2
    addss   xmm9, xmm14
    mulss   xmm9, xmm13
    movss   [r9+SH_SZ+24], xmm9
    mulss   xmm0, xmm6                  # t = e2 . q * inv
    mulss   xmm1, xmm7
    addss   xmm0, xmm1
    mulss   xmm2, xmm8
    addss   xmm0, xmm2
    mulss   xmm0, xmm13
    movss   [r9+SH_SZ+28], xmm0
    mov     eax, 1
    ret
8:  xor     eax, eax
    ret

# pixel_normal - (job_shade's frame) the interpolated corner normal and the
#   view vector, both turned to world space, into SH_N / SH_V
pixel_normal:
    lea     r9, [rsp+8]
    movss   xmm0, [r9+SH_SZ+20]         # clamp u, v to the triangle
    maxss   xmm0, [rip+pf_zero]
    minss   xmm0, [rip+pf_one]
    movss   xmm1, [r9+SH_SZ+24]
    maxss   xmm1, [rip+pf_zero]
    minss   xmm1, [rip+pf_one]
    movss   xmm2, [rip+pf_one]
    subss   xmm2, xmm0
    subss   xmm2, xmm1                  # w0 = 1 - u - v
    maxss   xmm2, [rip+pf_zero]
    mov     rax, [rip+pv_cn]
    mov     rax, [rax+rbp*8]
    lea     rcx, [r15+r15*2]
    lea     rcx, [rcx+rcx*2]
    lea     rax, [rax+rcx*4]            # n0 n1 n2
    xor     ecx, ecx
1:  movss   xmm3, [rax+rcx*4]
    mulss   xmm3, xmm2
    movss   xmm4, [rax+12+rcx*4]
    mulss   xmm4, xmm0
    addss   xmm3, xmm4
    movss   xmm4, [rax+24+rcx*4]
    mulss   xmm4, xmm1
    addss   xmm3, xmm4
    movss   [r9+SH_TMP+rcx*4], xmm3     # camera-space normal
    inc     ecx
    cmp     ecx, 3
    jb      1b
    # view vector (camera space): -d, normalized; flip N toward it
    movss   xmm0, [r9+SH_SZ+8]
    xorps   xmm0, [rip+pf_sign]
    movss   [r9+SH_TMP+12], xmm0
    movss   xmm0, [r9+SH_SZ+12]
    xorps   xmm0, [rip+pf_sign]
    movss   [r9+SH_TMP+16], xmm0
    movss   xmm0, [r9+SH_SZ+16]
    xorps   xmm0, [rip+pf_sign]
    movss   [r9+SH_TMP+20], xmm0
    push    r9
    lea     rsi, [r9+SH_TMP]
    lea     rdi, [r9+SH_TMP]
    call    unit3
    mov     r9, [rsp]
    lea     rsi, [r9+SH_TMP+12]
    lea     rdi, [r9+SH_TMP+12]
    call    unit3
    pop     r9
    movss   xmm0, [r9+SH_TMP]           # n . v < 0: the back side
    mulss   xmm0, [r9+SH_TMP+12]
    movss   xmm1, [r9+SH_TMP+4]
    mulss   xmm1, [r9+SH_TMP+16]
    addss   xmm0, xmm1
    movss   xmm1, [r9+SH_TMP+8]
    mulss   xmm1, [r9+SH_TMP+20]
    addss   xmm0, xmm1
    comiss  xmm0, [rip+pf_zero]
    jae     2f
    xor     ecx, ecx
11: movss   xmm1, [r9+SH_TMP+rcx*4]
    xorps   xmm1, [rip+pf_sign]
    movss   [r9+SH_TMP+rcx*4], xmm1
    inc     ecx
    cmp     ecx, 3
    jb      11b
2:  lea     rsi, [r9+SH_TMP]            # to world: x right + y up + z fwd
    lea     rdi, [r9+SH_N]
    call    cam_to_world
    lea     rsi, [r9+SH_TMP+12]
    lea     rdi, [r9+SH_V]
    call    cam_to_world
    ret

# cam_to_world(rsi=camera-space direction, rdi=out world)
cam_to_world:
    xor     ecx, ecx
1:  lea     rax, [rip+right]
    movss   xmm0, [rax+rcx*4]
    mulss   xmm0, [rsi]
    lea     rax, [rip+up]
    movss   xmm1, [rax+rcx*4]
    mulss   xmm1, [rsi+4]
    addss   xmm0, xmm1
    lea     rax, [rip+fwd]
    movss   xmm1, [rax+rcx*4]
    mulss   xmm1, [rsi+8]
    addss   xmm0, xmm1
    movss   [rdi+rcx*4], xmm0
    inc     ecx
    cmp     ecx, 3
    jb      1b
    ret

# load_material(rsi=record or 0) - job_shade's scratch (one level up)
load_material:
    lea     r9, [rsp+8]
    test    rsi, rsi
    jnz     1f
    lea     rsi, [rip+mat_default]
    sub     rsi, 32                     # (laid out like a record from +32)
1:  xor     ecx, ecx                    # base metallic roughness specular
2:  mov     eax, [rsi+32+rcx*4]         #  ior transmission
    mov     [r9+SH_BASE+rcx*4], eax
    inc     ecx
    cmp     ecx, 8
    jb      2b
    xor     ecx, ecx                    # emission * strength
3:  movss   xmm0, [rsi+64+rcx*4]
    mulss   xmm0, [rsi+76]
    movss   [r9+SH_EMIT+rcx*4], xmm0
    inc     ecx
    cmp     ecx, 3
    jb      3b
    mov     eax, [rsi+80]
    mov     [r9+SH_COAT], eax
    mov     eax, [rsi+84]
    mov     [r9+SH_COATR], eax
    ret

# =============================================================================
# shade(rdi=scratch) - the principled BSDF under the studio environment;
#   SH_OUT + 12 = the 0xRRGGBB pixel
# =============================================================================
shade:
    push    rbx
    push    r12
    sub     rsp, 104
    mov     rbx, rdi
    # n.v
    lea     rdi, [rbx+SH_N]
    lea     rsi, [rbx+SH_V]
    call    dot3
    maxss   xmm0, [rip+pf_eps]
    movss   [rbx+SH_NV], xmm0
    # F0 = mix(0.08 specular, base, metallic); diffuse = base (1-m)(1-t)
    movss   xmm7, [rbx+SH_METAL]
    movss   xmm6, [rip+pf_one]
    subss   xmm6, xmm7
    movss   xmm5, [rip+pf_one]
    subss   xmm5, [rbx+SH_TRANS]
    mulss   xmm5, xmm6
    movss   xmm4, [rbx+SH_SPEC]
    mulss   xmm4, [rip+pf_008]
    xor     ecx, ecx
1:  movss   xmm0, [rbx+SH_BASE+rcx*4]
    movss   xmm1, xmm0
    mulss   xmm1, xmm7
    movss   xmm2, xmm4
    mulss   xmm2, xmm6
    addss   xmm1, xmm2
    movss   [rbx+SH_F0+rcx*4], xmm1
    mulss   xmm0, xmm5
    movss   [rbx+SH_DIFF+rcx*4], xmm0
    inc     ecx
    cmp     ecx, 3
    jb      1b
    # reflection R = 2 (n.v) n - v
    movss   xmm0, [rbx+SH_NV]
    addss   xmm0, xmm0
    xor     ecx, ecx
2:  movss   xmm1, [rbx+SH_N+rcx*4]
    mulss   xmm1, xmm0
    subss   xmm1, [rbx+SH_V+rcx*4]
    movss   [rbx+SH_R+rcx*4], xmm1
    inc     ecx
    cmp     ecx, 3
    jb      2b
    # ---- environment: diffuse irradiance(n) + specular radiance(R) ----------
    lea     rdi, [rbx+SH_N]
    lea     rsi, [rsp]                  # irr(n)
    call    env_irr
    lea     rdi, [rbx+SH_R]
    lea     rsi, [rsp+16]               # sky(R)
    call    env_sky
    lea     rdi, [rbx+SH_R]
    lea     rsi, [rsp+32]               # irr(R)
    call    env_irr
    movss   xmm0, [rbx+SH_ROUGH]        # blur: mix(sky, irr, rough^2 ... )
    mulss   xmm0, xmm0
    call    split_sum                   # xmm0 = A, xmm1 = B for (rough, n.v)
    movss   [rsp+48], xmm0
    movss   [rsp+52], xmm1
    xor     ecx, ecx
3:  movss   xmm0, [rbx+SH_ROUGH]        # env radiance along R
    mulss   xmm0, xmm0
    movss   xmm1, [rsp+32+rcx*4]
    subss   xmm1, [rsp+16+rcx*4]
    mulss   xmm1, xmm0
    addss   xmm1, [rsp+16+rcx*4]
    movss   xmm2, [rbx+SH_F0+rcx*4]     # (F0 A + B) env
    mulss   xmm2, [rsp+48]
    addss   xmm2, [rsp+52]
    mulss   xmm2, xmm1
    movss   xmm3, [rbx+SH_DIFF+rcx*4]   # + diffuse irr
    mulss   xmm3, [rsp+rcx*4]
    addss   xmm2, xmm3
    movss   [rbx+SH_OUT+rcx*4], xmm2
    inc     ecx
    cmp     ecx, 3
    jb      3b
    # ---- transmission: the environment through, tinted (approx.) ------------
    movss   xmm7, [rbx+SH_TRANS]
    comiss  xmm7, [rip+pf_zero]
    jbe     4f
    lea     rdi, [rbx+SH_V]             # behind = sky(-v)
    lea     rsi, [rsp+64]
    call    env_sky_neg
    movss   xmm6, [rip+pf_one]          # (1 - F) t (1 - m)
    subss   xmm6, [rsp+48]
    subss   xmm6, [rsp+52]
    maxss   xmm6, [rip+pf_zero]
    mulss   xmm6, xmm7
    movss   xmm5, [rip+pf_one]
    subss   xmm5, [rbx+SH_METAL]
    mulss   xmm6, xmm5
    xor     ecx, ecx
41: movss   xmm0, [rsp+64+rcx*4]
    mulss   xmm0, [rbx+SH_BASE+rcx*4]
    mulss   xmm0, xmm6
    addss   xmm0, [rbx+SH_OUT+rcx*4]
    movss   [rbx+SH_OUT+rcx*4], xmm0
    inc     ecx
    cmp     ecx, 3
    jb      41b
4:  # ---- softbox lights (the studio only) ---------------------------------------
    xor     r12d, r12d
    cmp     dword ptr [rip+env_on], 0
    jne     6f
5:  cmp     r12d, 3
    jae     6f
    imul    eax, r12d, 24
    lea     rsi, [rip+lights]
    add     rsi, rax
    mov     rdi, rbx
    movss   xmm0, [rbx+SH_ROUGH]
    lea     rdx, [rbx+SH_F0]
    lea     rcx, [rbx+SH_DIFF]
    call    light_ggx
    inc     r12d
    jmp     5b
6:  # ---- clearcoat: a second, clear layer on top ------------------------------
    movss   xmm7, [rbx+SH_COAT]
    comiss  xmm7, [rip+pf_zero]
    jbe     7f
    xor     ecx, ecx                    # F0 = 0.04 coat layer, no diffuse
    mov     eax, 0x3d23d70a             # 0.04
61: mov     [rsp+80+rcx*4], eax
    mov     dword ptr [rsp+92+rcx*4], 0
    inc     ecx
    cmp     ecx, 3
    jb      61b
    movss   xmm0, [rbx+SH_COATR]
    mulss   xmm0, xmm0
    call    split_sum
    movss   xmm2, [rip+pf_004]          # coat env: (0.04 A + B) sky(R) * coat
    mulss   xmm2, xmm0
    addss   xmm2, xmm1
    mulss   xmm2, xmm7
    xor     ecx, ecx
62: movss   xmm0, [rsp+16+rcx*4]
    mulss   xmm0, xmm2
    addss   xmm0, [rbx+SH_OUT+rcx*4]
    movss   [rbx+SH_OUT+rcx*4], xmm0
    inc     ecx
    cmp     ecx, 3
    jb      62b
    cmp     dword ptr [rip+env_on], 0
    jne     7f
    xor     r12d, r12d                  # coat highlights of the key light
    lea     rsi, [rip+lights]
    mov     rdi, rbx
    movss   xmm0, [rbx+SH_COATR]
    lea     rdx, [rsp+80]
    lea     rcx, [rsp+92]
    call    light_ggx_k                 # (scaled by the coat weight)
7:  # ---- emission, exposure, ACES, gamma -------------------------------------
    xor     ecx, ecx
    xor     r12d, r12d                  # the packed pixel
8:  movss   xmm0, [rbx+SH_OUT+rcx*4]
    addss   xmm0, [rbx+SH_EMIT+rcx*4]
    mulss   xmm0, [rip+pf_expo]
    maxss   xmm0, [rip+pf_zero]
    movss   xmm1, xmm0                  # x (2.51x + .03) / (x (2.43x + .59) + .14)
    mulss   xmm1, [rip+pf_aces_a]
    addss   xmm1, [rip+pf_aces_b]
    mulss   xmm1, xmm0
    movss   xmm2, xmm0
    mulss   xmm2, [rip+pf_aces_c]
    addss   xmm2, [rip+pf_aces_d]
    mulss   xmm2, xmm0
    addss   xmm2, [rip+pf_aces_e]
    divss   xmm1, xmm2
    minss   xmm1, [rip+pf_one]
    maxss   xmm1, [rip+pf_zero]
    sqrtss  xmm1, xmm1                  # ~ sRGB
    mulss   xmm1, [rip+pf_255]
    addss   xmm1, [rip+pf_half]
    cvttss2si eax, xmm1
    shl     r12d, 8
    or      r12d, eax
    inc     ecx
    cmp     ecx, 3
    jb      8b
    mov     [rbx+SH_OUT+12], r12d
    add     rsp, 104
    pop     r12
    pop     rbx
    ret

# light_ggx(rdi=scratch, rsi=light (dir, colour), xmm0=roughness, rdx=F0[3],
#   rcx=diffuse[3]) - adds diffuse/pi + GGX specular, both times n.l and the
#   light colour, to SH_OUT. light_ggx_k: specular only, times the coat
#   weight (diffuse colour 0 handles the rest)
light_ggx_k:
    push    rbx
    push    r12
    push    r13
    sub     rsp, 48
    movss   xmm7, [rdi+SH_COAT]
    movss   [rsp+40], xmm7
    jmp     lg_body
light_ggx:
    push    rbx
    push    r12
    push    r13
    sub     rsp, 48
    mov     dword ptr [rsp+40], 0x3f800000
lg_body:
    mov     rbx, rdi
    mov     r12, rsi
    mov     r13, rdx
    mov     [rsp+32], rcx
    mulss   xmm0, xmm0                  # alpha = r^2, widened by the softbox
    addss   xmm0, [rip+pf_soft]
    maxss   xmm0, [rip+pf_amin]
    movss   [rsp], xmm0
    mov     rdi, r12                    # n.l
    lea     rsi, [rbx+SH_N]
    call    dot3
    comiss  xmm0, [rip+pf_zero]
    jbe     9f
    movss   [rsp+4], xmm0
    xor     ecx, ecx                    # h = norm(l + v)
1:  movss   xmm0, [r12+rcx*4]
    addss   xmm0, [rbx+SH_V+rcx*4]
    movss   [rsp+8+rcx*4], xmm0
    inc     ecx
    cmp     ecx, 3
    jb      1b
    lea     rsi, [rsp+8]
    lea     rdi, [rsp+8]
    call    unit3
    lea     rdi, [rsp+8]                # n.h, v.h
    lea     rsi, [rbx+SH_N]
    call    dot3
    maxss   xmm0, [rip+pf_zero]
    movss   [rsp+20], xmm0
    lea     rdi, [rsp+8]
    lea     rsi, [rbx+SH_V]
    call    dot3
    maxss   xmm0, [rip+pf_zero]
    movss   [rsp+24], xmm0
    # D = a2 / (pi (nh^2 (a2 - 1) + 1)^2)
    movss   xmm0, [rsp]
    mulss   xmm0, xmm0                  # a2
    movss   xmm1, [rsp+20]
    mulss   xmm1, xmm1
    movss   xmm2, xmm0
    subss   xmm2, [rip+pf_one]
    mulss   xmm1, xmm2
    addss   xmm1, [rip+pf_one]
    mulss   xmm1, xmm1
    divss   xmm0, xmm1
    mulss   xmm0, [rip+pf_inv_pi]
    movss   [rsp+28], xmm0              # D
    # G (Schlick-Smith, k = a / 2) / (4 nl nv)
    movss   xmm2, [rsp]
    mulss   xmm2, [rip+pf_half]         # k
    movss   xmm3, [rip+pf_one]
    subss   xmm3, xmm2                  # 1 - k
    movss   xmm4, [rsp+4]               # nl (1-k) + k
    mulss   xmm4, xmm3
    addss   xmm4, xmm2
    movss   xmm5, [rbx+SH_NV]
    mulss   xmm5, xmm3
    addss   xmm5, xmm2
    mulss   xmm4, xmm5
    mulss   xmm4, [rip+pf_four]
    movss   xmm0, [rsp+28]
    divss   xmm0, xmm4                  # D G / (4 nl nv) * (nl nv / ...) (nl
    movss   [rsp+28], xmm0              #  multiplies below)
    # Fresnel weight (1 - v.h)^5
    movss   xmm0, [rip+pf_one]
    subss   xmm0, [rsp+24]
    movss   xmm1, xmm0
    mulss   xmm1, xmm1
    mulss   xmm1, xmm1
    mulss   xmm1, xmm0                  # ^5
    xor     ecx, ecx
2:  movss   xmm2, [rip+pf_one]          # F = F0 + (1 - F0) w
    subss   xmm2, [r13+rcx*4]
    mulss   xmm2, xmm1
    addss   xmm2, [r13+rcx*4]
    mulss   xmm2, [rsp+28]              # spec
    mulss   xmm2, [rsp+40]              # (coat weight)
    mov     rax, [rsp+32]               # + diffuse / pi
    movss   xmm3, [rax+rcx*4]
    mulss   xmm3, [rip+pf_inv_pi]
    addss   xmm2, xmm3
    mulss   xmm2, [rsp+4]               # n.l
    mulss   xmm2, [r12+12+rcx*4]        # light colour
    addss   xmm2, [rbx+SH_OUT+rcx*4]
    movss   [rbx+SH_OUT+rcx*4], xmm2
    inc     ecx
    cmp     ecx, 3
    jb      2b
9:  add     rsp, 48
    pop     r13
    pop     r12
    pop     rbx
    ret

# dot3(rdi, rsi) -> xmm0
dot3:
    movss   xmm0, [rdi]
    mulss   xmm0, [rsi]
    movss   xmm1, [rdi+4]
    mulss   xmm1, [rsi+4]
    addss   xmm0, xmm1
    movss   xmm1, [rdi+8]
    mulss   xmm1, [rsi+8]
    addss   xmm0, xmm1
    ret

# env_irr(rdi=direction, rsi=out[3]) - ground .. sky irradiance by n.y
env_irr:
    cmp     dword ptr [rip+env_on], 0   # an HDRI world: its SH irradiance
    jne     env_irr_pv
    movss   xmm0, [rdi+4]
    mulss   xmm0, [rip+pf_half]
    addss   xmm0, [rip+pf_half]         # t = 0.5 + 0.5 y
    xor     ecx, ecx
1:  lea     rax, [rip+env_gnd_irr]
    movss   xmm1, [rax+rcx*4]
    lea     rax, [rip+env_sky_irr]
    movss   xmm2, [rax+rcx*4]
    subss   xmm2, xmm1
    mulss   xmm2, xmm0
    addss   xmm2, xmm1
    movss   [rsi+rcx*4], xmm2
    inc     ecx
    cmp     ecx, 3
    jb      1b
    ret

# env_sky(rdi=direction, rsi=out[3]) - horizon .. zenith above, ground below
env_sky:
    cmp     dword ptr [rip+env_on], 0   # an HDRI world: its blurred copy
    jne     env_spec_pv
    movss   xmm0, [rdi+4]
    jmp     es_body
env_sky_neg:                            # (the direction negated)
    cmp     dword ptr [rip+env_on], 0
    je      1f
    sub     rsp, 24
    movss   xmm0, [rdi]
    xorps   xmm0, [rip+pf_sign]
    movss   [rsp], xmm0
    movss   xmm0, [rdi+4]
    xorps   xmm0, [rip+pf_sign]
    movss   [rsp+4], xmm0
    movss   xmm0, [rdi+8]
    xorps   xmm0, [rip+pf_sign]
    movss   [rsp+8], xmm0
    lea     rdi, [rsp]
    call    env_spec_pv
    add     rsp, 24
    ret
1:  movss   xmm0, [rdi+4]
    xorps   xmm0, [rip+pf_sign]
es_body:
    comiss  xmm0, [rip+pf_zero]
    jbe     2f
    sqrtss  xmm0, xmm0                  # t = sqrt(y)
    xor     ecx, ecx
1:  lea     rax, [rip+env_horizon]
    movss   xmm1, [rax+rcx*4]
    lea     rax, [rip+env_zenith]
    movss   xmm2, [rax+rcx*4]
    subss   xmm2, xmm1
    mulss   xmm2, xmm0
    addss   xmm2, xmm1
    movss   [rsi+rcx*4], xmm2
    inc     ecx
    cmp     ecx, 3
    jb      1b
    ret
2:  lea     rax, [rip+env_ground]
    mov     rcx, [rax]
    mov     [rsi], rcx
    mov     ecx, [rax+8]
    mov     [rsi+8], ecx
    ret

# split_sum(xmm0=roughness, n.v from the scratch at rbx) -> xmm0 = A, xmm1 = B
#   (Karis' analytic fit of the pre-integrated environment BRDF)
split_sum:
    sub     rsp, 24
    movss   xmm2, xmm0                  # r = rough c0 + c1 (4 lanes)
    shufps  xmm2, xmm2, 0
    movups  xmm3, [rip+pf_c0]
    mulps   xmm2, xmm3
    movups  xmm3, [rip+pf_c1]
    addps   xmm2, xmm3
    movups  [rsp], xmm2
    movss   xmm0, [rbx+SH_NV]           # exp2(-9.28 n.v)
    mulss   xmm0, [rip+pf_m928]
    call    exp2f_
    movss   xmm1, [rsp]                 # min(r.x^2, e) r.x + r.y
    mulss   xmm1, xmm1
    minss   xmm1, xmm0
    mulss   xmm1, [rsp]
    addss   xmm1, [rsp+4]               # a004
    movss   xmm0, xmm1                  # A = -1.04 a004 + r.z
    mulss   xmm0, [rip+pf_m104]
    addss   xmm0, [rsp+8]
    mulss   xmm1, [rip+pf_p104]         # B = 1.04 a004 + r.w
    addss   xmm1, [rsp+12]
    add     rsp, 24
    ret

# exp2f_(xmm0) -> xmm0 = 2^x (x87)
exp2f_:
    sub     rsp, 8
    movss   [rsp], xmm0
    fld     dword ptr [rsp]
    fld     st(0)
    frndint
    fsub    st(1), st(0)
    fxch    st(1)
    f2xm1
    fld1
    faddp   st(1), st(0)
    fscale
    fstp    st(1)
    fstp    dword ptr [rsp]
    movss   xmm0, [rsp]
    add     rsp, 8
    ret

.section .note.GNU-stack,"",@progbits
