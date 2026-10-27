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
.globl cn_build
.globl pc_fp

.equ RO_CV,     0
.equ RO_MESH,   8
.equ RO_BASE,   16
.equ RO_NTRIS,  20
.equ RO_ID,     24
.equ RO_OBJ,    32
.equ RO_SZ,     56
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
.equ SH_P,      176             # the world point (light probes)
.equ SH_PROBED, 188             # 1: an irradiance volume lit it
.equ SH_AO,     192             # ambient occlusion (a graph's; else 1)
.equ SH_SZ,     208
.equ MA_ALPHA_,  88                      # (material.s)
# kept corner normals (pc_tab): an entry
.equ PE_MESH,   0
.equ PE_FP,     8                       # the vertices' fingerprint
.equ PE_VER,    16
.equ PE_NT,     20
.equ PE_NV,     24
.equ PE_LAST,   28                      # the frame it was last used
.equ PE_DATA,   32                      # f32[3] a corner, its own space
.equ PE_BYTES,  40
.equ PE_BUILD,  48                      # the frame it was last made
.equ PE_SZ,     64
.equ PC_N,      256
.equ PC_AGE,    600                     # unused this many frames: freed
.equ CN_CHUNK,  8192                    # triangles a job turns

.macro PVCROSS d, a, b, t
    movaps  \d, \b
    shufps  \d, \d, 0xC9
    mulps   \d, \a
    movaps  \t, \a
    shufps  \t, \t, 0xC9
    mulps   \t, \b
    subps   \d, \t
    shufps  \d, \d, 0xC9
.endm

.section .bss
.align 8
pv_map:         .skip 8             # object id -> record index
pv_cn:          .skip 8             # per record: corner normals (camera)
pv_mat:         .skip 8             # per record: material record or 0
pv_mapn:        .skip 4
pv_src:         .skip 8             # per record: its kept normals, or 0
pv_k:           .skip 8             # per record: K (3 columns, aligned)
pv_build:       .skip 8             # entries to make this frame
pv_chunks:      .skip 8             # (record, first, count) to turn
pv_nbuild:      .skip 4
pc_frame:       .skip 4
.align 8
pc_tab:         .skip PC_N*PE_SZ

.section .rodata
.align 16
pf_absm:        .long 0x7fffffff, 0, 0, 0
pf_sign:        .long 0x80000000, 0, 0, 0
pf_one:         .float 1.0
pf_half:        .float 0.5
pf_zero:        .float 0.0
pf_eps:         .float 1.0e-4
pf_cos30:       .float 0.8660254
pv_tiny:        .float 1.0e-20
.align 16
pv_xyz:         .long -1, -1, -1, 0
pv_tiny4:       .float 1.0e-20, 1.0e-20, 1.0e-20, 1.0e-20
.align 4
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
2:  call    pv_normals                  # corner normals: kept, turned
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
# Corner normals: per corner the area-weighted normals of the triangles at
# that vertex within 30 degrees of this one. A mesh's are made once in its
# own space and kept (pc_tab: by the mesh, its version, counts and a
# fingerprint of its vertices - an edit, a deformation or cloth makes them
# again); each frame they are only turned into camera space (the cofactor
# of the object's camera matrix, as the cross products of its edges would
# turn), in parallel chunks. Meshes made for one frame (no mapping of their
# own: virtualized geometry's cuts) are done each frame, in camera space.
# =============================================================================

# pv_normals - (preview_shade) every record's corner normals in camera space:
#   kept meshes' made again where they changed, then turned; the others
#   made in camera space
pv_normals:
    push    rbx
    push    r12
    push    r13
    push    r14
    sub     rsp, 8
    inc     dword ptr [rip+pc_frame]
    call    pc_age
    mov     dword ptr [rip+pv_nbuild], 0
    mov     ebx, [rip+rs_nobjs]
    lea     rdi, [rip+frame_arena]
    lea     esi, [rbx*8+8]
    call    arena_alloc
    test    rax, rax
    jz      .Lpn_out
    mov     [rip+pv_src], rax
    lea     rdi, [rip+frame_arena]
    lea     esi, [rbx*8+8]
    call    arena_alloc
    test    rax, rax
    jz      .Lpn_out
    mov     [rip+pv_build], rax
    lea     rdi, [rip+frame_arena]
    imul    esi, ebx, 48
    add     esi, 16
    call    arena_alloc
    test    rax, rax
    jz      .Lpn_out
    mov     [rip+pv_k], rax
    xor     ebx, ebx                    # each record: kept, or not
    xor     r14d, r14d                  # chunks to turn
1:  cmp     ebx, [rip+rs_nobjs]
    jae     2f
    mov     rax, [rip+pv_src]
    mov     qword ptr [rax+rbx*8], 0
    imul    r12, rbx, RO_SZ
    add     r12, [rip+rs_objs]
    mov     r13, [r12+RO_MESH]
    mov     rax, [rip+pv_cn]
    cmp     qword ptr [rax+rbx*8], 0
    je      11f
    cmp     qword ptr [r13+ME_BYTES], 0 # (made for this frame: not kept)
    je      11f
    cmp     dword ptr [r13+ME_NTRIS], 0
    je      11f
    mov     rdi, r13
    call    pc_entry
    test    rax, rax
    jz      11f
    mov     rcx, [rip+pv_src]
    mov     rax, [rax+PE_DATA]
    mov     [rcx+rbx*8], rax
    mov     rdi, r12
    imul    rsi, rbx, 48
    add     rsi, [rip+pv_k]
    call    pv_kmat
    mov     eax, [r13+ME_NTRIS]
    add     eax, CN_CHUNK-1
    shr     eax, 13
    add     r14d, eax
11: inc     ebx
    jmp     1b
2:  lea     rdi, [rip+job_build]        # the changed meshes, made again
    xor     esi, esi
    mov     edx, [rip+pv_nbuild]
    mov     ecx, 1
    call    parallel_for
    lea     rdi, [rip+job_normals]      # the ones not kept
    xor     esi, esi
    mov     edx, [rip+rs_nobjs]
    mov     ecx, 1
    call    parallel_for
    test    r14d, r14d
    jz      .Lpn_out
    lea     rdi, [rip+frame_arena]      # the kept ones turned, in chunks
    mov     esi, r14d
    shl     esi, 4
    call    arena_alloc
    test    rax, rax
    jz      .Lpn_out
    mov     [rip+pv_chunks], rax
    mov     rdi, rax
    xor     ebx, ebx
    xor     r14d, r14d
3:  cmp     ebx, [rip+rs_nobjs]
    jae     5f
    mov     rax, [rip+pv_src]
    cmp     qword ptr [rax+rbx*8], 0
    je      4f
    imul    rax, rbx, RO_SZ
    add     rax, [rip+rs_objs]
    mov     rax, [rax+RO_MESH]
    mov     ecx, [rax+ME_NTRIS]
    xor     edx, edx                    # first
31: cmp     edx, ecx
    jae     4f
    mov     eax, ecx
    sub     eax, edx
    cmp     eax, CN_CHUNK
    jbe     32f
    mov     eax, CN_CHUNK
32: mov     [rdi], ebx
    mov     [rdi+4], edx
    mov     [rdi+8], eax
    add     rdi, 16
    inc     r14d
    add     edx, eax
    jmp     31b
4:  inc     ebx
    jmp     3b
5:  lea     rdi, [rip+job_xform]
    xor     esi, esi
    mov     edx, r14d
    mov     ecx, 1
    call    parallel_for
.Lpn_out:
    add     rsp, 8
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# cn_build(rdi=mesh, rsi=its vertices (f32[3]), rdx=out (36 bytes a
#   triangle), rcx=arena) - its corner normals, in the vertices' space
cn_build:
    push    rbx
    push    rbp
    push    r12
    push    r13
    push    r14
    push    r15
    sub     rsp, 72
    mov     r13, rdi
    mov     rbp, rsi
    mov     r14, rdx
    mov     [rsp], rcx                  # the arena
    mov     rdi, rcx                    # faces: unit normal, |n| (16 bytes)
    mov     esi, [r13+ME_NTRIS]
    shl     esi, 4
    add     esi, 16
    call    arena_alloc
    test    rax, rax
    jz      .Lcb_flat
    mov     [rsp+16], rax
    mov     rdi, [rsp]                  # vertex -> triangles (CSR)
    mov     esi, [r13+ME_NVERTS]
    lea     esi, [rsi*4+8]
    call    arena_alloc
    test    rax, rax
    jz      .Lcb_flat
    mov     [rsp+24], rax
    mov     rdi, rax
    mov     ecx, [r13+ME_NVERTS]
    inc     ecx
    xor     eax, eax
    rep     stosd
    mov     rdi, [rsp]
    mov     esi, [r13+ME_NTRIS]
    imul    esi, esi, 12
    add     esi, 8
    call    arena_alloc
    test    rax, rax
    jz      .Lcb_flat
    mov     [rsp+32], rax
    xor     ebx, ebx                    # faces and counts
1:  cmp     ebx, [r13+ME_NTRIS]
    jae     2f
    mov     edi, ebx
    call    tri_cn                      # xmm0..2 = (p1-p0) x (p2-p0)
    movss   xmm3, xmm0
    mulss   xmm3, xmm0
    movss   xmm4, xmm1
    mulss   xmm4, xmm1
    addss   xmm3, xmm4
    movss   xmm4, xmm2
    mulss   xmm4, xmm2
    addss   xmm3, xmm4
    sqrtss  xmm3, xmm3                  # |n|
    xorps   xmm4, xmm4
    comiss  xmm3, xmm4
    jbe     11f
    movss   xmm4, [rip+pf_one]
    divss   xmm4, xmm3
    mulss   xmm0, xmm4
    mulss   xmm1, xmm4
    mulss   xmm2, xmm4
11: mov     rax, [rsp+16]
    mov     rcx, rbx
    shl     rcx, 4
    movss   [rax+rcx], xmm0
    movss   [rax+rcx+4], xmm1
    movss   [rax+rcx+8], xmm2
    movss   [rax+rcx+12], xmm3
    mov     rax, [r13+ME_TRIS]
    lea     rcx, [rbx+rbx*2]
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
    xor     ebx, ebx                    # the corners
.Lcb_tri:
    cmp     ebx, [r13+ME_NTRIS]
    jae     .Lcb_out
    mov     rax, [rsp+16]               # this face's unit normal
    mov     rcx, rbx
    shl     rcx, 4
    movups  xmm8, [rax+rcx]
    xor     r15d, r15d
.Lcb_corner:
    cmp     r15d, 3
    jae     .Lcb_tnext
    xorps   xmm4, xmm4                  # the sum
    mov     rax, [r13+ME_TRIS]
    lea     rcx, [rbx+rbx*2]
    add     rcx, r15
    mov     edi, [rax+rcx*4]            # the vertex
    mov     rdx, [rsp+24]
    mov     ecx, [rdx+rdi*4]
    mov     edx, [rdx+rdi*4+4]
    mov     r8, [rsp+32]
    mov     r9, [rsp+16]
7:  cmp     ecx, edx
    jae     8f
    mov     eax, [r8+rcx*4]             # a face at the vertex: within 30
    shl     rax, 4                      #  degrees? its normal x |n|
    movups  xmm0, [r9+rax]
    movaps  xmm1, xmm0
    dpps    xmm1, xmm8, 0x71
    comiss  xmm1, [rip+pf_cos30]
    jb      71f
    movaps  xmm2, xmm0
    shufps  xmm2, xmm2, 0xFF
    mulps   xmm0, xmm2
    addps   xmm4, xmm0
71: inc     ecx
    jmp     7b
8:  andps   xmm4, [rip+pv_xyz]          # unit (nothing: the face's)
    movaps  xmm0, xmm4
    dpps    xmm0, xmm0, 0x7f
    movaps  xmm1, xmm8
    andps   xmm1, [rip+pv_xyz]
    comiss  xmm0, [rip+pv_tiny]
    jbe     81f
    sqrtps  xmm0, xmm0
    movaps  xmm1, xmm4
    divps   xmm1, xmm0
81: lea     rcx, [rbx+rbx*2]            # out[tri][corner]
    add     rcx, r15
    lea     rcx, [rcx+rcx*2]
    movlps  [r14+rcx*4], xmm1
    movhlps xmm1, xmm1
    movss   [r14+rcx*4+8], xmm1
    inc     r15d
    jmp     .Lcb_corner
.Lcb_tnext:
    inc     ebx
    jmp     .Lcb_tri
.Lcb_flat:                              # (no memory: face normals only)
    xor     ebx, ebx
9:  cmp     ebx, [r13+ME_NTRIS]
    jae     .Lcb_out
    mov     edi, ebx
    call    tri_cn
    movss   [rsp+48], xmm0
    movss   [rsp+52], xmm1
    movss   [rsp+56], xmm2
    lea     rsi, [rsp+48]
    lea     rdi, [rsp+48]
    call    unit3
    lea     rcx, [rbx+rbx*2]
    lea     rcx, [rcx+rcx*2]
    xor     edx, edx
91: mov     rax, [rsp+48]
    mov     [r14+rcx*4], rax
    mov     eax, [rsp+56]
    mov     [r14+rcx*4+8], eax
    add     rcx, 3
    inc     edx
    cmp     edx, 3
    jb      91b
    inc     ebx
    jmp     9b
.Lcb_out:
    add     rsp, 72
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbp
    pop     rbx
    ret

# job_normals(ctx, esi=first record, edx=end, ecx=thread, r8=arena) - the
#   records whose mesh is not kept: corner normals in camera space
job_normals:
    push    rbx
    push    r12
    push    r13
    mov     ebx, esi
    mov     r12d, edx
    mov     r13, r8
1:  cmp     ebx, r12d
    jae     9f
    mov     rax, [rip+pv_src]
    cmp     qword ptr [rax+rbx*8], 0
    jne     2f
    mov     rax, [rip+pv_cn]
    mov     rdx, [rax+rbx*8]
    test    rdx, rdx
    jz      2f
    imul    rax, rbx, RO_SZ
    add     rax, [rip+rs_objs]
    mov     rdi, [rax+RO_MESH]
    mov     rsi, [rax+RO_CV]
    mov     rcx, r13
    call    cn_build
2:  inc     ebx
    jmp     1b
9:  pop     r13
    pop     r12
    pop     rbx
    ret

# job_build(ctx, esi=first, edx=end, ecx=thread, r8=arena) - kept meshes made
#   again: their corner normals in their own space
job_build:
    push    rbx
    push    r12
    push    r13
    mov     ebx, esi
    mov     r12d, edx
    mov     r13, r8
1:  cmp     ebx, r12d
    jae     9f
    mov     rax, [rip+pv_build]
    mov     rax, [rax+rbx*8]            # an entry
    mov     rdi, [rax+PE_MESH]
    mov     rsi, [rdi+ME_POS]
    mov     rdx, [rax+PE_DATA]
    mov     rcx, r13
    call    cn_build
    inc     ebx
    jmp     1b
9:  pop     r13
    pop     r12
    pop     rbx
    ret

# job_xform(ctx, esi=first chunk, edx=end) - kept corner normals turned into
#   camera space: K n (K: the cofactor of the record's camera matrix), unit
job_xform:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    mov     ebx, esi
    mov     r12d, edx
.Ljx_chunk:
    cmp     ebx, r12d
    jae     .Ljx_out
    mov     rax, [rip+pv_chunks]
    mov     rcx, rbx
    shl     rcx, 4
    mov     r13d, [rax+rcx]             # the record
    mov     r14d, [rax+rcx+4]           # first triangle
    mov     r15d, [rax+rcx+8]           # how many
    imul    rax, r13, 48                # K's columns
    add     rax, [rip+pv_k]
    movaps  xmm5, [rax]
    movaps  xmm6, [rax+16]
    movaps  xmm7, [rax+32]
    mov     rax, [rip+pv_src]
    mov     rsi, [rax+r13*8]
    mov     rax, [rip+pv_cn]
    mov     rdi, [rax+r13*8]
    imul    rax, r14, 36
    add     rsi, rax
    add     rdi, rax
    lea     ecx, [r15+r15*2]            # corners
1:  test    ecx, ecx
    jz      .Ljx_next
    movss   xmm0, [rsi]
    shufps  xmm0, xmm0, 0
    mulps   xmm0, xmm5
    movss   xmm1, [rsi+4]
    shufps  xmm1, xmm1, 0
    mulps   xmm1, xmm6
    addps   xmm0, xmm1
    movss   xmm1, [rsi+8]
    shufps  xmm1, xmm1, 0
    mulps   xmm1, xmm7
    addps   xmm0, xmm1
    movaps  xmm1, xmm0
    dpps    xmm1, xmm1, 0x7f
    maxps   xmm1, [rip+pv_tiny4]
    sqrtps  xmm1, xmm1
    divps   xmm0, xmm1
    movlps  [rdi], xmm0
    movhlps xmm0, xmm0
    movss   [rdi+8], xmm0
    add     rsi, 12
    add     rdi, 12
    dec     ecx
    jmp     1b
.Ljx_next:
    inc     ebx
    jmp     .Ljx_chunk
.Ljx_out:
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# pc_fp(rdi=mesh) -> rax = a fingerprint of its vertices (their order counts)
pc_fp:
    mov     rsi, [rdi+ME_POS]
    mov     ecx, [rdi+ME_NVERTS]
    imul    rcx, rcx, 12
    pxor    xmm0, xmm0
    pxor    xmm1, xmm1
1:  cmp     rcx, 16
    jb      2f
    movdqu  xmm2, [rsi]
    pxor    xmm0, xmm2
    pshufd  xmm1, xmm1, 0x39
    paddd   xmm1, xmm2
    add     rsi, 16
    sub     rcx, 16
    jmp     1b
2:  cmp     rcx, 4
    jb      3f
    movd    xmm2, dword ptr [rsi]
    pxor    xmm0, xmm2
    pshufd  xmm1, xmm1, 0x39
    paddd   xmm1, xmm2
    add     rsi, 4
    sub     rcx, 4
    jmp     2b
3:  movq    rax, xmm0
    pextrq  rdx, xmm0, 1
    xor     rax, rdx
    movq    rdx, xmm1
    rol     rdx, 17
    xor     rax, rdx
    pextrq  rdx, xmm1, 1
    rol     rdx, 31
    xor     rax, rdx
    ret

# pc_entry(rdi=mesh) -> rax = its entry: kept and the same (PE_BUILD old),
#   or one to make again (PE_BUILD = this frame; its data room for it), or
#   0 (no room)
pc_entry:
    push    rbx
    push    r12
    push    r13
    push    r14
    sub     rsp, 8
    mov     r12, rdi
    call    pc_fp
    mov     r13, rax
    lea     rbx, [rip+pc_tab]           # the mesh's own entry
    xor     ecx, ecx
1:  cmp     ecx, PC_N
    jae     2f
    cmp     [rbx+PE_MESH], r12
    je      5f
    add     rbx, PE_SZ
    inc     ecx
    jmp     1b
2:  lea     rbx, [rip+pc_tab]           # none: a free one, or the least used
    xor     r14, r14
    xor     ecx, ecx
    mov     edx, -1
3:  cmp     ecx, PC_N
    jae     4f
    cmp     qword ptr [rbx+PE_MESH], 0
    je      31f
    mov     eax, [rip+pc_frame]
    sub     eax, [rbx+PE_LAST]
    cmp     eax, 1                      # (not one in use this frame)
    jb      32f
    cmp     [rbx+PE_LAST], edx
    jae     32f
    mov     edx, [rbx+PE_LAST]
    mov     r14, rbx
32: add     rbx, PE_SZ
    inc     ecx
    jmp     3b
31: mov     r14, rbx
4:  test    r14, r14
    jz      .Lpe_none
    mov     rbx, r14
    mov     [rbx+PE_MESH], r12
    mov     qword ptr [rbx+PE_FP], 0
    mov     dword ptr [rbx+PE_NT], -1   # (never the same: made again)
5:  mov     eax, [rip+pc_frame]
    mov     [rbx+PE_LAST], eax
    cmp     [rbx+PE_FP], r13
    jne     6f
    mov     eax, [r12+ME_VER]
    cmp     [rbx+PE_VER], eax
    jne     6f
    mov     eax, [r12+ME_NTRIS]
    cmp     [rbx+PE_NT], eax
    jne     6f
    mov     eax, [r12+ME_NVERTS]
    cmp     [rbx+PE_NV], eax
    je      8f                          # the same
6:  mov     eax, [rip+pc_frame]         # made again this frame (once)
    cmp     [rbx+PE_BUILD], eax
    je      8f
    mov     esi, [r12+ME_NTRIS]         # room: 36 bytes a triangle
    imul    rsi, rsi, 36
    add     rsi, 4095
    and     rsi, -4096
    cmp     rsi, [rbx+PE_BYTES]
    jbe     7f
    push    rsi
    push    rsi
    mov     rdi, [rbx+PE_DATA]
    mov     rsi, [rbx+PE_BYTES]
    test    rdi, rdi
    jz      61f
    call    plat_munmap
61: mov     qword ptr [rbx+PE_DATA], 0
    mov     qword ptr [rbx+PE_BYTES], 0
    pop     rsi
    pop     rsi
    push    rsi
    push    rsi
    xor     edi, edi
    mov     edx, PROT_RW
    mov     r10d, 0x22
    mov     r8, -1
    xor     r9d, r9d
    call    plat_mmap
    pop     rsi
    pop     rsi
    cmp     rax, -4096
    jae     .Lpe_drop
    mov     [rbx+PE_DATA], rax
    mov     [rbx+PE_BYTES], rsi
7:  mov     [rbx+PE_FP], r13
    mov     eax, [r12+ME_VER]
    mov     [rbx+PE_VER], eax
    mov     eax, [r12+ME_NTRIS]
    mov     [rbx+PE_NT], eax
    mov     eax, [r12+ME_NVERTS]
    mov     [rbx+PE_NV], eax
    mov     eax, [rip+pc_frame]
    mov     [rbx+PE_BUILD], eax
    mov     rax, [rip+pv_build]         # into the list to make
    mov     ecx, [rip+pv_nbuild]
    mov     [rax+rcx*8], rbx
    inc     dword ptr [rip+pv_nbuild]
8:  mov     rax, rbx
    jmp     9f
.Lpe_drop:
    mov     qword ptr [rbx+PE_MESH], 0
.Lpe_none:
    xor     eax, eax
9:  add     rsp, 8
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# pv_kmat(rdi=record, rsi=out: 3 columns (16-byte aligned)) - K = the
#   cofactor of its camera matrix's 3x3 C = (right, up, fwd) . M: columns
#   b x c, c x a, a x b of C's columns a b c (what the edges' cross products
#   become in camera space)
pv_kmat:
    push    rbx
    sub     rsp, 80
    mov     rbx, rsi
    mov     rdi, [rdi+RO_OBJ]
    lea     rsi, [rsp+16]               # M (3x4 rows)
    call    obj_matrix
    xor     ecx, ecx                    # C's column c: basis . M's column c
1:  movss   xmm0, [rsp+16+rcx*4]        # (M0c, M1c, M2c)
    movss   xmm1, [rsp+32+rcx*4]
    movss   xmm2, [rsp+48+rcx*4]
    movss   xmm3, [rip+right]
    mulss   xmm3, xmm0
    movss   xmm4, [rip+right+4]
    mulss   xmm4, xmm1
    addss   xmm3, xmm4
    movss   xmm4, [rip+right+8]
    mulss   xmm4, xmm2
    addss   xmm3, xmm4
    movss   [rsp+rcx*4], xmm3           # (scratch: x of each column)
    movss   xmm3, [rip+up]
    mulss   xmm3, xmm0
    movss   xmm4, [rip+up+4]
    mulss   xmm4, xmm1
    addss   xmm3, xmm4
    movss   xmm4, [rip+up+8]
    mulss   xmm4, xmm2
    addss   xmm3, xmm4
    movss   [rsp+64+rcx*4], xmm3        # (y)
    movss   xmm3, [rip+fwd]
    mulss   xmm3, xmm0
    movss   xmm4, [rip+fwd+4]
    mulss   xmm4, xmm1
    addss   xmm3, xmm4
    movss   xmm4, [rip+fwd+8]
    mulss   xmm4, xmm2
    addss   xmm3, xmm4
    lea     rax, [rbx+rcx*4]            # (z, into out: rebuilt below)
    movss   [rax+32], xmm3
    inc     ecx
    cmp     ecx, 3
    jb      1b
    # columns a b c as vectors: (x[c], y[c], z[c])
    movss   xmm0, [rsp]
    insertps xmm0, [rsp+64], 0x10
    insertps xmm0, [rbx+32], 0x20       # a
    movss   xmm1, [rsp+4]
    insertps xmm1, [rsp+68], 0x10
    insertps xmm1, [rbx+36], 0x20       # b
    movss   xmm2, [rsp+8]
    insertps xmm2, [rsp+72], 0x10
    insertps xmm2, [rbx+40], 0x20       # c
    andps   xmm0, [rip+pv_xyz]
    andps   xmm1, [rip+pv_xyz]
    andps   xmm2, [rip+pv_xyz]
    PVCROSS xmm3, xmm1, xmm2, xmm6      # b x c
    PVCROSS xmm4, xmm2, xmm0, xmm6      # c x a
    PVCROSS xmm5, xmm0, xmm1, xmm6      # a x b
    movaps  [rbx], xmm3
    movaps  [rbx+16], xmm4
    movaps  [rbx+32], xmm5
    add     rsp, 80
    pop     rbx
    ret

# pc_age - kept normals not used for PC_AGE frames go (their memory back)
pc_age:
    lea     rcx, [rip+pc_tab]
    xor     edx, edx
1:  cmp     edx, PC_N
    jae     9f
    cmp     qword ptr [rcx+PE_MESH], 0
    je      2f
    mov     eax, [rip+pc_frame]
    sub     eax, [rcx+PE_LAST]
    cmp     eax, PC_AGE
    jb      2f
    push    rcx
    push    rdx
    mov     rdi, [rcx+PE_DATA]
    mov     rsi, [rcx+PE_BYTES]
    test    rdi, rdi
    jz      11f
    call    plat_munmap
11: pop     rdx
    pop     rcx
    xor     eax, eax
    mov     [rcx+PE_MESH], rax
    mov     [rcx+PE_DATA], rax
    mov     [rcx+PE_BYTES], rax
2:  add     rcx, PE_SZ
    inc     edx
    jmp     1b
9:  ret

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
    movss   xmm0, [rsp+SH_SZ+28]        # the world point: eye + world(d t)
    xor     ecx, ecx
21: movss   xmm1, [rsp+SH_SZ+8+rcx*4]
    mulss   xmm1, xmm0
    movss   [rsp+SH_TMP+rcx*4], xmm1
    inc     ecx
    cmp     ecx, 3
    jb      21b
    lea     rsi, [rsp+SH_TMP]
    lea     rdi, [rsp+SH_P]
    call    cam_to_world
    xor     ecx, ecx
22: lea     rax, [rip+eye]
    movss   xmm0, [rax+rcx*4]
    addss   xmm0, [rsp+SH_P+rcx*4]
    movss   [rsp+SH_P+rcx*4], xmm0
    inc     ecx
    cmp     ecx, 3
    jb      22b
    mov     dword ptr [rsp+SH_PROBED], 0
    mov     rax, [rip+pv_mat]           # material values
    mov     rsi, [rax+rbp*8]
    call    load_material
    mov     rax, [rip+pv_mat]           # a shader graph
    mov     rdi, [rax+rbp*8]
    xor     eax, eax
    test    rdi, rdi
    jz      1f
    cmp     dword ptr [rdi+128], 0
    je      1f
    lea     rsi, [rsp]
    call    pv_graph
1:  test    eax, 0x80000000             # (not when the graph reads them)
    jnz     12f
    mov     rdi, [r14+RO_MESH]          # vertex colours tint the base
    cmp     qword ptr [rdi+ME_VCOL], 0
    je      12f
    movss   xmm0, [rsp+SH_SZ+20]
    movss   xmm1, [rsp+SH_SZ+24]
    sub     rsp, 16
    mov     esi, r15d
    lea     rdx, [rsp]
    call    vcol_lin
    xor     ecx, ecx
11: movss   xmm0, [rsp+16+SH_BASE+rcx*4]
    mulss   xmm0, [rsp+rcx*4]
    movss   [rsp+16+SH_BASE+rcx*4], xmm0
    inc     ecx
    cmp     ecx, 3
    jb      11b
    add     rsp, 16
12: lea     rdi, [rsp]
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

# pv_graph(rdi=material record, rsi=job_shade's frame; r14 = object record,
#   r15d = local triangle) - the material's graph at this pixel: values and
#   the normal into the scratch
pv_graph:
    push    rbx
    push    r12
    sub     rsp, 376
    mov     rbx, rdi
    mov     r12, rsi
    mov     r8, [r14+RO_MESH]           # the triangle's corners
    mov     rax, [r8+ME_TRIS]
    lea     rcx, [r15+r15*2]
    mov     edx, [rax+rcx*4]
    mov     esi, [rax+rcx*4+4]
    mov     edi, [rax+rcx*4+8]
    lea     rdx, [rdx+rdx*2]
    lea     rsi, [rsi+rsi*2]
    lea     rdi, [rdi+rdi*2]
    mov     r9, [r8+ME_POS]             # object space: p0, e1, e2
    mov     r10, [r14+RO_CV]            # camera space: edges
    xor     ecx, ecx
1:  lea     rax, [r9+rdx*4]
    movss   xmm0, [rax+rcx*4]
    movss   [rsp+rcx*4], xmm0
    lea     rax, [r9+rsi*4]
    movss   xmm1, [rax+rcx*4]
    subss   xmm1, xmm0
    movss   [rsp+12+rcx*4], xmm1
    lea     rax, [r9+rdi*4]
    movss   xmm1, [rax+rcx*4]
    subss   xmm1, xmm0
    movss   [rsp+24+rcx*4], xmm1
    lea     rax, [r10+rdx*4]
    movss   xmm0, [rax+rcx*4]
    lea     rax, [r10+rsi*4]
    movss   xmm1, [rax+rcx*4]
    subss   xmm1, xmm0
    movss   [rsp+320+rcx*4], xmm1       # (camera e1, e2 for now)
    lea     rax, [r10+rdi*4]
    movss   xmm1, [rax+rcx*4]
    subss   xmm1, xmm0
    movss   [rsp+332+rcx*4], xmm1
    inc     ecx
    cmp     ecx, 3
    jb      1b
    mov     eax, [r12+SH_SZ+20]         # u, v
    mov     [rsp+36], eax
    mov     eax, [r12+SH_SZ+24]
    mov     [rsp+40], eax
    lea     rsi, [rsp+320]              # the edges in world space
    lea     rdi, [rsp+44]
    call    cam_to_world
    lea     rsi, [rsp+332]
    lea     rdi, [rsp+56]
    call    cam_to_world
    mov     rax, [r12+SH_N]             # the normal
    mov     [rsp+68], rax
    mov     eax, [r12+SH_N+8]
    mov     [rsp+76], eax
    mov     qword ptr [rsp+120], 0      # the mesh's UVs, if it has them
    mov     rdi, [r14+RO_MESH]
    mov     esi, r15d
    lea     rdx, [rsp+344]
    call    tri_uvs
    test    eax, eax
    jz      11f
    lea     rax, [rsp+344]
    mov     [rsp+120], rax
11: mov     rax, [r12+SH_P]             # the world point, towards the eye
    mov     [rsp+152], rax
    mov     eax, [r12+SH_P+8]
    mov     [rsp+160], eax
    mov     rax, [r12+SH_V]
    mov     [rsp+164], rax
    mov     eax, [r12+SH_V+8]
    mov     [rsp+172], eax
    mov     eax, 0x3f800000             # the vertex colour (none: white)
    mov     [rsp+176], eax
    mov     [rsp+180], eax
    mov     [rsp+184], eax
    mov     rdi, [r14+RO_MESH]
    cmp     qword ptr [rdi+ME_VCOL], 0
    je      12f
    movss   xmm0, [r12+SH_SZ+20]
    movss   xmm1, [r12+SH_SZ+24]
    mov     esi, r15d
    lea     rdx, [rsp+176]
    call    vcol_lin
12: mov     rsi, rbx                    # its values, the pins over them
    lea     rdi, [rsp+192]
    mov     ecx, 32
    rep     movsd
    mov     rdi, rbx
    lea     rsi, [rsp]
    lea     rdx, [rsp+192]
    xor     ecx, ecx
    call    graph_shade
    lea     rsi, [rsp+192]
    mov     r9, r12
    call    load_values
    mov     eax, [rsp+112]              # what it drives
    test    eax, 1 << PIN_AO
    jz      5f
    mov     ecx, [rsp+192+MA_RT_AO]
    mov     [r12+SH_AO], ecx
5:  test    eax, 1 << PIN_NORMAL
    jz      6f
    mov     rcx, [rsp+68]
    mov     [r12+SH_N], rcx
    mov     ecx, [rsp+76]
    mov     [r12+SH_N+8], ecx
6:  mov     eax, [rsp+112]              # (what the graph did)
    add     rsp, 376
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
    mov     dword ptr [r9+SH_AO], 0x3f800000
    test    rsi, rsi
    jnz     load_values
    lea     rsi, [rip+mat_default]
    sub     rsi, 32                     # (laid out like a record from +32)
# load_values(rsi=record, r9=scratch) - its principled values
load_values:
    xor     ecx, ecx                    # base metallic roughness specular
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
    movss   xmm4, [rbx+SH_IOR]          # 2 spec ((ior - 1) / (ior + 1))^2
    movss   xmm3, xmm4
    subss   xmm4, [rip+pf_one]
    addss   xmm3, [rip+pf_one]
    divss   xmm4, xmm3
    mulss   xmm4, xmm4
    mulss   xmm4, [rbx+SH_SPEC]
    addss   xmm4, xmm4
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
    call    pv_irr
    lea     rdi, [rbx+SH_R]
    lea     rsi, [rsp+16]               # sky(R)
    call    pv_sky
    lea     rdi, [rbx+SH_R]
    lea     rsi, [rsp+32]               # irr(R)
    call    pv_irr
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
    mulss   xmm2, [rbx+SH_AO]           # (occluded ambient)
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
4:  # ---- softbox lights (the studio only; not where probes light it) ---------
    xor     r12d, r12d
    cmp     dword ptr [rip+env_on], 0
    jne     6f
    cmp     dword ptr [rbx+SH_PROBED], 0
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
    cmp     dword ptr [rbx+SH_PROBED], 0
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

# pv_irr(rdi=direction, rsi=out[3]; rbx = the scratch) - the irradiance / pi
#   from the light probes at the point (probe.s), else the environment's
pv_irr:
    push    r12
    push    r13
    sub     rsp, 24
    mov     r12, rdi
    mov     r13, rsi
    mov     rdx, rsi
    mov     rsi, rdi
    lea     rdi, [rbx+SH_P]
    call    pb_irr
    test    eax, eax
    jz      1f
    mov     dword ptr [rbx+SH_PROBED], 1
    jmp     9f
1:  mov     rdi, r12
    mov     rsi, r13
    call    env_irr
9:  add     rsp, 24
    pop     r13
    pop     r12
    ret

# pv_sky(rdi=direction, rsi=out[3]; rbx = the scratch) - the radiance along
#   it from a reflection probe at the point, else the environment's (the
#   direction need not be unit: made so for the probe)
pv_sky:
    push    r12
    push    r13
    sub     rsp, 40
    mov     r12, rdi
    mov     r13, rsi
    movsd   xmm0, [rdi]
    insertps xmm0, [rdi+8], 0x28
    movaps  xmm1, xmm0
    dpps    xmm1, xmm1, 0x7f
    sqrtps  xmm1, xmm1
    maxps   xmm1, [rip+pf_tiny4]
    divps   xmm0, xmm1
    movups  [rsp], xmm0
    lea     rdi, [rbx+SH_P]
    lea     rsi, [rsp]
    mov     rdx, r13
    call    pb_spec
    test    eax, eax
    jnz     9f
    mov     rdi, r12
    mov     rsi, r13
    call    env_sky
9:  add     rsp, 40
    pop     r13
    pop     r12
    ret

.section .rodata
.align 16
pf_tiny4:       .float 1.0e-8, 1.0e-8, 1.0e-8, 1.0e-8
.text

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


# =============================================================================
# preview_material(rdi=material record or 0, rsi=out u32[size x size], edx=
#   size, ecx=shape 0 sphere 1 cube 2 plane, xmm0=yaw, xmm1=pitch) - the
#   material on a shape alone, under the studio environment, as the viewport
#   preview shades it (its graph, masks and opacity too); rows in parallel.
#   The node editor's preview pane draws it.
# =============================================================================
.equ PM_SC,     208                     # (a row job's frame: the scratch, the
.equ PM_CP,     400                     #  shading context, the material's
.equ PM_UV,     528                     #  copy, the UVs, the hit)
.equ PM_PO,     552
.equ PM_NO,     564
.equ PM_TU,     576
.equ PM_TV,     588
.equ PM_D,      600
.equ PM_OO,     612
.equ PM_DO,     624
.equ PM_ROW,    640
.equ PM_END,    644
.equ PM_X,      648
.equ PM_U,      652
.equ PM_VV,     656
.equ PM_T,      660
.equ PM_FR,     712
.equ SCN_N,     68                      # (graph.s's shading context)
.equ SCN_FLAGS, 112
.equ SCN_UVP,   120
.equ SCN_WP,    152
.equ SCN_WV,    164
.equ SCN_VC,    176
.equ SCN_SZ2,   192

.section .bss
.align 8
pm_rec:         .skip 8
pm_out:         .skip 8
pm_size:        .skip 4
pm_shape:       .skip 4
pm_cy:          .skip 4                 # the shape's turn: cos, sin of yaw,
pm_sy:          .skip 4                 #  of pitch
pm_cp:          .skip 4
pm_sp:          .skip 4

.section .rodata
.align 4
pm_eye:         .float 0.0, 0.0, 3.4    # the camera, looking down -z
pm_focal:       .float 2.6
pm_cube:        .float 0.75
pm_plane:       .float 1.1
pm_h:           .float 0.002            # bump's steps (a fraction of a repeat)
pm_far:         .float 1.0e8
pm_inv2pi:      .float 0.15915494
pm_2pi:         .float 6.2831853
pm_pi:          .float 3.14159265
pm_third:       .float 0.33333334
pm_bg0:         .long 0x2a2c31
pm_bg1:         .long 0x33363c

.text
.globl preview_material
preview_material:
    push    rbx
    sub     rsp, 16
    mov     [rip+pm_rec], rdi
    mov     [rip+pm_out], rsi
    mov     [rip+pm_size], edx
    mov     [rip+pm_shape], ecx
    movss   [rsp], xmm0
    movss   [rsp+4], xmm1
    fld     dword ptr [rsp]
    fsincos
    fstp    dword ptr [rip+pm_cy]
    fstp    dword ptr [rip+pm_sy]
    fld     dword ptr [rsp+4]
    fsincos
    fstp    dword ptr [rip+pm_cp]
    fstp    dword ptr [rip+pm_sp]
    call    tex_init
    call    env_prep
    lea     rdi, [rip+job_pmat]
    xor     esi, esi
    mov     edx, [rip+pm_size]
    mov     ecx, 4
    call    parallel_for
    add     rsp, 16
    pop     rbx
    ret

# pm_toobj(rdi=v (camera), rsi=out (object)) - Ry(-yaw) Rx(-pitch) v
pm_toobj:
    movss   xmm0, [rdi]                 # x' = x
    movss   xmm1, [rdi+4]               # y' = cp y + sp z
    mulss   xmm1, [rip+pm_cp]
    movss   xmm2, [rdi+8]
    mulss   xmm2, [rip+pm_sp]
    addss   xmm1, xmm2
    movss   xmm2, [rdi+8]               # z' = -sp y + cp z
    mulss   xmm2, [rip+pm_cp]
    movss   xmm3, [rdi+4]
    mulss   xmm3, [rip+pm_sp]
    subss   xmm2, xmm3
    movss   xmm3, xmm0                  # then about y: x'' = cy x' - sy z'
    mulss   xmm3, [rip+pm_cy]
    movss   xmm4, xmm2
    mulss   xmm4, [rip+pm_sy]
    subss   xmm3, xmm4
    mulss   xmm0, [rip+pm_sy]           # z'' = sy x' + cy z'
    mulss   xmm2, [rip+pm_cy]
    addss   xmm2, xmm0
    movss   [rsi], xmm3
    movss   [rsi+4], xmm1
    movss   [rsi+8], xmm2
    ret

# pm_tocam(rdi=v (object), rsi=out (camera)) - Rx(pitch) Ry(yaw) v
pm_tocam:
    movss   xmm0, [rdi]                 # about y: x' = cy x + sy z
    mulss   xmm0, [rip+pm_cy]
    movss   xmm1, [rdi+8]
    mulss   xmm1, [rip+pm_sy]
    addss   xmm0, xmm1
    movss   xmm2, [rdi+8]               # z' = -sy x + cy z
    mulss   xmm2, [rip+pm_cy]
    movss   xmm1, [rdi]
    mulss   xmm1, [rip+pm_sy]
    subss   xmm2, xmm1
    movss   xmm1, [rdi+4]               # about x: y'' = cp y - sp z'
    mulss   xmm1, [rip+pm_cp]
    movss   xmm3, xmm2
    mulss   xmm3, [rip+pm_sp]
    subss   xmm1, xmm3
    movss   xmm3, [rdi+4]               # z'' = sp y + cp z'
    mulss   xmm3, [rip+pm_sp]
    mulss   xmm2, [rip+pm_cp]
    addss   xmm2, xmm3
    movss   [rsi], xmm0
    movss   [rsi+4], xmm1
    movss   [rsi+8], xmm2
    ret

# job_pmat(ctx, esi=first row, edx=end) - preview_material's rows
job_pmat:
    push    rbx
    push    rbp
    push    r12
    push    r13
    push    r14
    push    r15
    sub     rsp, PM_FR
    mov     [rsp+PM_ROW], esi
    mov     [rsp+PM_END], edx
    lea     rax, [rip+pm_eye]           # the eye in the object's frame
    mov     rdi, rax
    lea     rsi, [rsp+PM_OO]
    call    pm_toobj
.Lpm_row:
    mov     eax, [rsp+PM_ROW]
    cmp     eax, [rsp+PM_END]
    jae     .Lpm_out
    mov     dword ptr [rsp+PM_X], 0
.Lpm_px:
    mov     eax, [rsp+PM_X]
    cmp     eax, [rip+pm_size]
    jae     .Lpm_rnext
    # the ray: d = (x', y', -focal), x' y' in -1..1
    cvtsi2ss xmm0, eax
    addss   xmm0, [rip+pf_half]
    cvtsi2ss xmm2, dword ptr [rip+pm_size]
    divss   xmm0, xmm2
    addss   xmm0, xmm0
    subss   xmm0, [rip+pf_one]
    cvtsi2ss xmm1, dword ptr [rsp+PM_ROW]
    addss   xmm1, [rip+pf_half]
    divss   xmm1, xmm2
    addss   xmm1, xmm1
    movss   xmm3, [rip+pf_one]
    subss   xmm3, xmm1
    movss   [rsp+PM_D], xmm0
    movss   [rsp+PM_D+4], xmm3
    movss   xmm0, [rip+pm_focal]
    xorps   xmm0, [rip+pf_sign]
    movss   [rsp+PM_D+8], xmm0
    lea     rdi, [rsp+PM_D]
    call    pm_unit
    lea     rdi, [rsp+PM_D]
    lea     rsi, [rsp+PM_DO]
    call    pm_toobj
    mov     eax, [rip+pm_shape]
    cmp     eax, 1
    je      .Lpm_cube
    cmp     eax, 2
    je      .Lpm_plane
    # sphere: |o + t d| = 1
    lea     rdi, [rsp+PM_OO]
    lea     rsi, [rsp+PM_DO]
    call    pm_dot
    movss   xmm4, xmm0                  # b
    lea     rdi, [rsp+PM_OO]
    mov     rsi, rdi
    call    pm_dot
    subss   xmm0, [rip+pf_one]          # c
    movss   xmm1, xmm4
    mulss   xmm1, xmm1
    subss   xmm1, xmm0
    xorps   xmm2, xmm2
    comiss  xmm1, xmm2
    jb      .Lpm_bg
    sqrtss  xmm1, xmm1
    xorps   xmm4, [rip+pf_sign]
    subss   xmm4, xmm1                  # t = -b - sqrt
    call    pm_hitpoint                 # P_obj
    mov     rax, [rsp+PM_PO+8]          # (rsp moved: the call)
    lea     rsi, [rsp+PM_PO]            # N = P; u = atan2(x, z) / 2pi + 1/2,
    lea     rdi, [rsp+PM_NO]            #  v = acos(-y) / pi
    mov     rcx, [rsi]
    mov     [rdi], rcx
    mov     ecx, [rsi+8]
    mov     [rdi+8], ecx
    movss   xmm0, [rsp+PM_PO]
    movss   [rsp+PM_T], xmm0
    movss   xmm0, [rsp+PM_PO+8]
    movss   [rsp+PM_T+4], xmm0
    fld     dword ptr [rsp+PM_T]
    fld     dword ptr [rsp+PM_T+4]
    fpatan
    fstp    dword ptr [rsp+PM_T]
    movss   xmm0, [rsp+PM_T]
    mulss   xmm0, [rip+pm_inv2pi]
    addss   xmm0, [rip+pf_half]
    movss   [rsp+PM_U], xmm0
    movss   xmm0, [rsp+PM_PO+4]         # v = 1/2 - asin(y)... ~ (y + 1) / 2
    addss   xmm0, [rip+pf_one]
    mulss   xmm0, [rip+pf_half]
    movss   [rsp+PM_VV], xmm0
    movss   xmm0, [rsp+PM_PO+8]         # dP/du = 2 pi (z, 0, -x), dP/dv = (0, 2, 0)
    mulss   xmm0, [rip+pm_2pi]
    movss   [rsp+PM_TU], xmm0
    mov     dword ptr [rsp+PM_TU+4], 0
    movss   xmm0, [rsp+PM_PO]
    mulss   xmm0, [rip+pm_2pi]
    xorps   xmm0, [rip+pf_sign]
    movss   [rsp+PM_TU+8], xmm0
    mov     dword ptr [rsp+PM_TV], 0
    mov     dword ptr [rsp+PM_TV+4], 0x40000000
    mov     dword ptr [rsp+PM_TV+8], 0
    jmp     .Lpm_shade
.Lpm_cube:                              # slabs: [-c, c]^3
    xorps   xmm4, xmm4                  # t near
    movss   xmm5, [rip+pm_far]          # t far
    mov     dword ptr [rsp+PM_T], -1    # (the axis it entered by)
    xor     ecx, ecx
1:  movss   xmm0, [rsp+PM_DO+rcx*4]
    movaps  xmm6, xmm0
    andps   xmm6, [rip+pf_absm]
    comiss  xmm6, [rip+pf_eps]
    jb      3f
    movss   xmm1, [rip+pm_cube]         # t1 = (-c - o) / d, t2 = (c - o) / d
    movss   xmm2, xmm1
    xorps   xmm1, [rip+pf_sign]
    subss   xmm1, [rsp+PM_OO+rcx*4]
    subss   xmm2, [rsp+PM_OO+rcx*4]
    divss   xmm1, xmm0
    divss   xmm2, xmm0
    movss   xmm3, xmm1
    minss   xmm1, xmm2
    maxss   xmm2, xmm3
    comiss  xmm1, xmm4
    jbe     2f
    movss   xmm4, xmm1
    mov     [rsp+PM_T], ecx
2:  minss   xmm5, xmm2
    jmp     4f
3:  movss   xmm1, [rsp+PM_OO+rcx*4]     # (parallel: inside the slab?)
    andps   xmm1, [rip+pf_absm]
    comiss  xmm1, [rip+pm_cube]
    ja      .Lpm_bg
4:  inc     ecx
    cmp     ecx, 3
    jb      1b
    comiss  xmm4, xmm5
    ja      .Lpm_bg
    mov     eax, [rsp+PM_T]
    test    eax, eax
    js      .Lpm_bg
    call    pm_hitpoint
    mov     eax, [rsp+PM_T]             # N: that axis, its side; UV and
    xorps   xmm0, xmm0                  #  tangents by the other two axes
    movss   [rsp+PM_NO], xmm0
    movss   [rsp+PM_NO+4], xmm0
    movss   [rsp+PM_NO+8], xmm0
    movss   xmm0, [rip+pf_one]
    movss   xmm1, [rsp+PM_PO+rax*4]
    xorps   xmm2, xmm2
    comiss  xmm1, xmm2
    jae     5f
    xorps   xmm0, [rip+pf_sign]
5:  movss   [rsp+PM_NO+rax*4], xmm0
    lea     rcx, [rip+pm_faxes]         # (u, v) axes for that face
    movzx   edx, byte ptr [rcx+rax*2]
    movzx   r8d, byte ptr [rcx+rax*2+1]
    movss   xmm0, [rsp+PM_PO+rdx*4]     # u = p / 2c + 1/2
    divss   xmm0, [rip+pm_cube]
    mulss   xmm0, [rip+pf_half]
    addss   xmm0, [rip+pf_half]
    movss   [rsp+PM_U], xmm0
    movss   xmm0, [rsp+PM_PO+r8*4]
    divss   xmm0, [rip+pm_cube]
    mulss   xmm0, [rip+pf_half]
    addss   xmm0, [rip+pf_half]
    movss   [rsp+PM_VV], xmm0
    xorps   xmm0, xmm0
    movss   [rsp+PM_TU], xmm0
    movss   [rsp+PM_TU+4], xmm0
    movss   [rsp+PM_TU+8], xmm0
    movss   [rsp+PM_TV], xmm0
    movss   [rsp+PM_TV+4], xmm0
    movss   [rsp+PM_TV+8], xmm0
    movss   xmm0, [rip+pm_cube]
    addss   xmm0, xmm0
    movss   [rsp+PM_TU+rdx*4], xmm0
    movss   [rsp+PM_TV+r8*4], xmm0
    jmp     .Lpm_shade
.Lpm_plane:                             # y = 0, |x| |z| <= p
    movss   xmm0, [rsp+PM_DO+4]
    movaps  xmm1, xmm0
    andps   xmm1, [rip+pf_absm]
    comiss  xmm1, [rip+pf_eps]
    jb      .Lpm_bg
    movss   xmm4, [rsp+PM_OO+4]
    xorps   xmm4, [rip+pf_sign]
    divss   xmm4, xmm0
    xorps   xmm1, xmm1
    comiss  xmm4, xmm1
    jbe     .Lpm_bg
    call    pm_hitpoint
    movss   xmm0, [rsp+PM_PO]
    andps   xmm0, [rip+pf_absm]
    comiss  xmm0, [rip+pm_plane]
    ja      .Lpm_bg
    movss   xmm0, [rsp+PM_PO+8]
    andps   xmm0, [rip+pf_absm]
    comiss  xmm0, [rip+pm_plane]
    ja      .Lpm_bg
    xorps   xmm0, xmm0                  # N: up, facing the eye
    movss   [rsp+PM_NO], xmm0
    movss   [rsp+PM_NO+8], xmm0
    movss   xmm1, [rip+pf_one]
    comiss  xmm0, [rsp+PM_DO+4]         # (d.y > 0: from below)
    ja      6f
    xorps   xmm1, [rip+pf_sign]
6:  movss   [rsp+PM_NO+4], xmm1
    movss   xmm0, [rsp+PM_PO]
    divss   xmm0, [rip+pm_plane]
    mulss   xmm0, [rip+pf_half]
    addss   xmm0, [rip+pf_half]
    movss   [rsp+PM_U], xmm0
    movss   xmm0, [rsp+PM_PO+8]
    divss   xmm0, [rip+pm_plane]
    mulss   xmm0, [rip+pf_half]
    movss   xmm1, [rip+pf_half]
    subss   xmm1, xmm0
    movss   [rsp+PM_VV], xmm1
    movss   xmm0, [rip+pm_plane]
    addss   xmm0, xmm0
    xorps   xmm1, xmm1
    movss   [rsp+PM_TU], xmm0
    movss   [rsp+PM_TU+4], xmm1
    movss   [rsp+PM_TU+8], xmm1
    movss   [rsp+PM_TV], xmm1
    movss   [rsp+PM_TV+4], xmm1
    xorps   xmm0, [rip+pf_sign]
    movss   [rsp+PM_TV+8], xmm0
.Lpm_shade:
    # the scratch: its values, the normal and the view (camera space)
    lea     r9, [rsp]
    mov     dword ptr [r9+SH_AO], 0x3f800000
    mov     dword ptr [r9+SH_PROBED], 0
    movss   xmm0, [rip+pm_far]          # (no light probe out there)
    movss   [r9+SH_P], xmm0
    movss   [r9+SH_P+4], xmm0
    movss   [r9+SH_P+8], xmm0
    mov     rsi, [rip+pm_rec]
    test    rsi, rsi
    jnz     7f
    lea     rsi, [rip+mat_default]
    sub     rsi, 32
7:  call    load_values
    lea     rdi, [rsp+PM_NO]
    lea     rsi, [rsp+SH_N]
    call    pm_tocam
    xor     ecx, ecx
71: movss   xmm0, [rsp+PM_D+rcx*4]
    xorps   xmm0, [rip+pf_sign]
    movss   [rsp+SH_V+rcx*4], xmm0
    inc     ecx
    cmp     ecx, 3
    jb      71b
    mov     rbx, [rip+pm_rec]           # a graph: the shading context
    test    rbx, rbx
    jz      .Lpm_go
    cmp     dword ptr [rbx+128], 0
    je      .Lpm_go
    lea     r12, [rsp+PM_SC]
    mov     rdi, r12
    xor     eax, eax
    mov     ecx, SCN_SZ2/4
    rep     stosd
    xor     ecx, ecx                    # P0, e1 = Tu h, e2 = Tv h (object)
72: mov     eax, [rsp+PM_PO+rcx*4]
    mov     [r12+rcx*4], eax
    movss   xmm0, [rsp+PM_TU+rcx*4]
    mulss   xmm0, [rip+pm_h]
    movss   [r12+12+rcx*4], xmm0
    movss   xmm0, [rsp+PM_TV+rcx*4]
    mulss   xmm0, [rip+pm_h]
    movss   [r12+24+rcx*4], xmm0
    inc     ecx
    cmp     ecx, 3
    jb      72b
    lea     rdi, [r12+12]               # the edges, the normal: camera space
    lea     rsi, [r12+44]
    call    pm_tocam
    lea     rdi, [r12+24]
    lea     rsi, [r12+56]
    call    pm_tocam
    mov     rax, [rsp+SH_N]
    mov     [r12+SCN_N], rax
    mov     eax, [rsp+SH_N+8]
    mov     [r12+SCN_N+8], eax
    lea     rdi, [rsp+PM_PO]            # the point, the view, no tint
    lea     rsi, [r12+SCN_WP]
    call    pm_tocam
    mov     rax, [rsp+SH_V]
    mov     [r12+SCN_WV], rax
    mov     eax, [rsp+SH_V+8]
    mov     [r12+SCN_WV+8], eax
    mov     eax, 0x3f800000
    mov     [r12+SCN_VC], eax
    mov     [r12+SCN_VC+4], eax
    mov     [r12+SCN_VC+8], eax
    movss   xmm0, [rsp+PM_U]            # UVs: (u, v), (u + h, v), (u, v + h)
    movss   xmm1, [rsp+PM_VV]
    movss   [rsp+PM_UV], xmm0
    movss   [rsp+PM_UV+4], xmm1
    movss   [rsp+PM_UV+12], xmm1
    movss   [rsp+PM_UV+16], xmm0
    addss   xmm0, [rip+pm_h]
    addss   xmm1, [rip+pm_h]
    movss   [rsp+PM_UV+8], xmm0
    movss   [rsp+PM_UV+20], xmm1
    lea     rax, [rsp+PM_UV]
    mov     [r12+SCN_UVP], rax
    mov     rsi, rbx                    # its values, the pins over them
    lea     rdi, [rsp+PM_CP]
    mov     ecx, 32
    rep     movsd
    mov     rdi, rbx
    mov     rsi, r12
    lea     rdx, [rsp+PM_CP]
    xor     ecx, ecx
    call    graph_shade
    lea     rsi, [rsp+PM_CP]
    lea     r9, [rsp]
    call    load_values
    mov     eax, [r12+SCN_FLAGS]
    test    eax, 1 << PIN_AO
    jz      73f
    mov     ecx, [rsp+PM_CP+MA_RT_AO]
    mov     [rsp+SH_AO], ecx
73: test    eax, 1 << PIN_NORMAL
    jz      .Lpm_mask
    mov     rcx, [r12+SCN_N]
    mov     [rsp+SH_N], rcx
    mov     ecx, [r12+SCN_N+8]
    mov     [rsp+SH_N+8], ecx
.Lpm_mask:                              # masked: below the clip, the
    movss   xmm0, [rbx+MA_BLEND]        #  background; translucent: its
    cvtss2si eax, xmm0                  #  opacity over it
    cmp     eax, 1
    jne     .Lpm_go
    movss   xmm0, [rsp+PM_CP+MA_ALPHA_]
    test    dword ptr [r12+SCN_FLAGS], 1 << PIN_MASK
    jz      74f
    movss   xmm0, [rsp+PM_CP+MA_RT_MASK]
74: movss   xmm1, [rbx+MA_CLIP]
    xorps   xmm2, xmm2
    comiss  xmm1, xmm2
    ja      75f
    movss   xmm1, [rip+pm_third]
75: comiss  xmm0, xmm1
    jb      .Lpm_bg
.Lpm_go:
    lea     rdi, [rsp]
    call    shade
    mov     eax, [rsp+SH_OUT+12]
    mov     rbx, [rip+pm_rec]           # translucent: blended with the
    test    rbx, rbx                    #  background by its opacity
    jz      .Lpm_put
    movss   xmm0, [rbx+MA_BLEND]
    cvtss2si ecx, xmm0
    cmp     ecx, 2
    jne     .Lpm_put
    movss   xmm0, [rbx+MA_ALPHA_]
    cmp     dword ptr [rbx+128], 0      # (a graph: its copy's)
    je      76f
    movss   xmm0, [rsp+PM_CP+MA_ALPHA_]
76: mov     edx, eax
    call    pm_bgpix
    call    pm_blend
    jmp     .Lpm_put
.Lpm_bg:
    call    pm_bgpix
.Lpm_put:
    mov     ecx, [rsp+PM_ROW]
    imul    ecx, [rip+pm_size]
    add     ecx, [rsp+PM_X]
    mov     rdx, [rip+pm_out]
    mov     [rdx+rcx*4], eax
    inc     dword ptr [rsp+PM_X]
    jmp     .Lpm_px
.Lpm_rnext:
    inc     dword ptr [rsp+PM_ROW]
    jmp     .Lpm_row
.Lpm_out:
    add     rsp, PM_FR
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbp
    pop     rbx
    ret

# pm_hitpoint(xmm4=t; the job's frame one up) - P_obj = o + t d
pm_hitpoint:
    xor     ecx, ecx
1:  movss   xmm0, [rsp+8+PM_DO+rcx*4]
    mulss   xmm0, xmm4
    addss   xmm0, [rsp+8+PM_OO+rcx*4]
    movss   [rsp+8+PM_PO+rcx*4], xmm0
    inc     ecx
    cmp     ecx, 3
    jb      1b
    ret

# pm_bgpix(the job's frame one up) -> eax = the background: a dark checker
pm_bgpix:
    mov     eax, [rsp+8+PM_X]
    shr     eax, 3
    mov     ecx, [rsp+8+PM_ROW]
    shr     ecx, 3
    xor     eax, ecx
    test    eax, 1
    mov     eax, [rip+pm_bg0]
    jz      1f
    mov     eax, [rip+pm_bg1]
1:  ret

# pm_blend(edx=over, eax=under, xmm0=opacity) -> eax
pm_blend:
    maxss   xmm0, [rip+pf_zero]
    minss   xmm0, [rip+pf_one]
    mulss   xmm0, [rip+pf_255]
    cvtss2si r8d, xmm0                  # a, 255 - a
    mov     r9d, 255
    sub     r9d, r8d
    xor     r10d, r10d
    mov     ecx, 16
1:  mov     r11d, edx
    shr     r11d, cl
    and     r11d, 255
    imul    r11d, r8d
    mov     esi, eax
    shr     esi, cl
    and     esi, 255
    imul    esi, r9d
    add     r11d, esi
    shr     r11d, 8
    shl     r11d, cl
    or      r10d, r11d
    sub     ecx, 8
    jns     1b
    mov     eax, r10d
    ret

pm_dot:
    movss   xmm0, [rdi]
    mulss   xmm0, [rsi]
    movss   xmm1, [rdi+4]
    mulss   xmm1, [rsi+4]
    addss   xmm0, xmm1
    movss   xmm1, [rdi+8]
    mulss   xmm1, [rsi+8]
    addss   xmm0, xmm1
    ret

pm_unit:
    mov     rsi, rdi
    call    pm_dot
    sqrtss  xmm0, xmm0
    movss   xmm1, [rip+pf_one]
    divss   xmm1, xmm0
    xor     ecx, ecx
1:  movss   xmm0, [rdi+rcx*4]
    mulss   xmm0, xmm1
    movss   [rdi+rcx*4], xmm0
    inc     ecx
    cmp     ecx, 3
    jb      1b
    ret

.section .rodata
pm_faxes:       .byte 2, 1, 0, 2, 0, 1      # cube faces: (u, v) axes
.text

.section .note.GNU-stack,"",@progbits
