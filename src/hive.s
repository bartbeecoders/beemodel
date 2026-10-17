# =============================================================================
#  BeeModel - "Hive", the path tracer: scene, BVH and ray queries.
#
#  hive_build snapshots the scene into a triangle soup in world space
#  (v0, e1, e2 per triangle, auto-smoothed corner normals, a material index)
#  and builds a binned-SAH BVH2 that is collapsed into a 4-wide BVH: each node
#  holds the boxes of up to four children as structure-of-arrays, so one SSE
#  test checks all four. Leaves hold up to 15 triangles, stored in leaf
#  order. hv_trace finds the nearest hit, hv_occluded any hit (shadows).
#  The light transport is in hive_pt.s.
# =============================================================================
.intel_syntax noprefix
.include "const.inc"

# exports
.globl hive_build
.globl hv_trace
.globl hv_occluded
.globl hv_n
.globl hv_tv
.globl hv_tn
.globl hv_tm
.globl hv_to
.globl hv_tuv
.globl hv_tvc
.globl hv_only
.globl hv_free_all
.globl corner_normals
.globl hv_mats
.globl hv_nmats
.globl hv_cut
.globl hv_cam
.globl hv_points
.globl hv_npoints
.globl hv_ready
.globl hv_nodes
.globl hv_root
.globl hv_nn4

.equ HV_IBUDGET, 4000000          # instance triangles the path tracer takes
.equ MAP_ANON_PRIV, 0x22
.equ LEAF_MAX,  15
.equ NBINS,     16
.equ N2_SZ,     32              # BVH2 node: min[3] max[3] a b
.equ N4_SZ,     128             # BVH4 node: minx maxx miny maxy minz maxz [4] child[4]
.equ NBUF,      32
.equ MAX_POINTS, 64

.section .bss
hv_camuid:      .skip 4
.align 8
hv_ready:       .skip 4
hv_n:           .skip 4             # triangles
hv_nmats:       .skip 4
hv_npoints:     .skip 4
.align 8
hv_tv:          .skip 8             # f32[n][9]  v0 e1 e2
hv_tn:          .skip 8             # f32[n][9]  corner normals
hv_tm:          .skip 8             # u32[n]     material (0 = default)
hv_to:          .skip 8             # f32[n][9]  object-space v0, e1, e2 (shader graphs)
hv_tuv:         .skip 8             # f32[n][6]  UVs (u0 NaN: none, box)
hv_tvc:         .skip 8             # u32[n][3]  vertex colours (0: none)
hv_only:        .skip 8             # set: only this object (baking)
hv_ibud:        .skip 4             # instance triangles still allowed
hv_mats:        .skip 8             # material snapshots (MA_SZ bytes, 0 = default)
hv_cut:         .skip 4             # some material is masked, translucent or
                                    #  one-sided: rays test what they hit
hv_nodes:       .skip 8             # BVH4
hv_root:        .skip 4             # root reference
hv_nn4:         .skip 4
hv_cam:         .skip 64            # origin, right, up, forward, tan_h, flags
hv_points:      .skip MAX_POINTS*32 # point lights: position, colour * power
hv_bufs:        .skip NBUF*16       # owned mappings (ptr, bytes)
hv_nbuf:        .skip 4
# build scratch
.align 8
b_cent:         .skip 8             # f32[n][3]
b_box:          .skip 8             # f32[n][6]
b_prim:         .skip 8             # u32[n]
b_n2:           .skip 8             # BVH2 nodes
b_nn2:          .skip 4
b_stack:        .skip 8
b_bins:         .skip NBINS*32      # count, min[3], max[3], pad
b_lr:           .skip NBINS*8       # sweep: left area, right area

.section .rodata
.align 16
hf_inf:         .float 3.0e38, 3.0e38, 3.0e38, 3.0e38
hf_ninf:        .float -3.0e38, -3.0e38, -3.0e38, -3.0e38
hf_absm:        .long 0x7fffffff, 0x7fffffff, 0x7fffffff, 0x7fffffff
hf_sign:        .long 0x80000000, 0, 0, 0
hf_zero4:       .float 0, 0, 0, 0
hf_one:         .float 1.0
hf_half:        .float 0.5
hf_eps_t:       .float 1.0e-4
hf_tiny:        .float 1.0e-12
hf_big:         .float 1.0e30
hf_nbins:       .float 15.999
hf_cos30:       .float 0.8660254
hf_tanh:        .float 0.35993             # tan(39.6 deg / 2): a 50 mm lens
hf_pt_power:    .float 80.0                # point light: watts-ish / 4 pi
.text

# =============================================================================
#  Memory
# =============================================================================
# hv_map(rdi=bytes) -> rax = zeroed mapping (owned until the next build)
hv_map:
    push    rbx
    lea     rbx, [rdi+4095]
    and     rbx, -4096
    xor     edi, edi
    mov     rsi, rbx
    mov     edx, PROT_RW
    mov     r10d, MAP_ANON_PRIV
    mov     r8d, -1
    xor     r9d, r9d
    mov     eax, SYS_MMAP
    syscall
    cmp     rax, -4096
    jbe     1f
    xor     eax, eax
    jmp     9f
1:  mov     ecx, [rip+hv_nbuf]
    cmp     ecx, NBUF
    jae     9f
    shl     ecx, 4
    lea     rdx, [rip+hv_bufs]
    mov     [rdx+rcx], rax
    mov     [rdx+rcx+8], rbx
    inc     dword ptr [rip+hv_nbuf]
9:  pop     rbx
    ret

hv_free_all:
    push    rbx
    xor     ebx, ebx
1:  cmp     ebx, [rip+hv_nbuf]
    jae     2f
    mov     eax, ebx
    shl     eax, 4
    lea     rdx, [rip+hv_bufs]
    mov     rdi, [rdx+rax]
    mov     rsi, [rdx+rax+8]
    mov     eax, SYS_MUNMAP
    syscall
    inc     ebx
    jmp     1b
2:  mov     dword ptr [rip+hv_nbuf], 0
    mov     dword ptr [rip+hv_ready], 0
    pop     rbx
    ret

# =============================================================================
#  hive_build -> eax = 1 (the scene as of now)
# =============================================================================
hive_build:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    push    rbp
    sub     rsp, 56
    call    hv_free_all
    xor     r12d, r12d                  # triangles
    mov     dword ptr [rip+hv_ibud], HV_IBUDGET
    xor     ebx, ebx
1:  cmp     ebx, [rip+obj_count]
    jae     2f
    mov     edi, ebx
    call    obj_at
    cmp     dword ptr [rax+OB_TYPE], OT_MESH
    jne     11f
    test    dword ptr [rax+OB_FLAGS], OBF_HIDDEN|OBF_NORENDER
    jnz     11f
    mov     rcx, [rip+hv_only]          # (one object only: baking)
    test    rcx, rcx
    jz      10f
    cmp     rax, rcx
    jne     11f
10: mov     rdi, rax
    call    obj_eval
    add     r12d, [rax+ME_NTRIS]
    mov     rdi, rax                    # its instances: triangles (a budget)
    call    hv_inst_count
    add     r12d, eax
11: inc     ebx
    jmp     1b
2:  mov     [rip+hv_n], r12d
    test    r12d, r12d
    jz      .Lhb_empty
    imul    edi, r12d, 36
    add     edi, 64
    call    hv_map
    test    rax, rax
    jz      .Lhb_fail
    mov     [rip+hv_tv], rax
    imul    edi, r12d, 36
    add     edi, 64
    call    hv_map
    test    rax, rax
    jz      .Lhb_fail
    mov     [rip+hv_tn], rax
    lea     edi, [r12*4+64]
    call    hv_map
    test    rax, rax
    jz      .Lhb_fail
    mov     [rip+hv_tm], rax
    imul    edi, r12d, 36
    add     edi, 64
    call    hv_map
    test    rax, rax
    jz      .Lhb_fail
    mov     [rip+hv_to], rax
    imul    edi, r12d, 24
    add     edi, 64
    call    hv_map
    test    rax, rax
    jz      .Lhb_fail
    mov     [rip+hv_tuv], rax
    imul    edi, r12d, 12
    add     edi, 64
    call    hv_map
    test    rax, rax
    jz      .Lhb_fail
    mov     [rip+hv_tvc], rax
    imul    edi, r12d, 12
    add     edi, 64
    call    hv_map
    test    rax, rax
    jz      .Lhb_fail
    mov     [rip+b_cent], rax
    imul    edi, r12d, 24
    add     edi, 64
    call    hv_map
    test    rax, rax
    jz      .Lhb_fail
    mov     [rip+b_box], rax
    lea     edi, [r12*4+64]
    call    hv_map
    test    rax, rax
    jz      .Lhb_fail
    mov     [rip+b_prim], rax
    # materials: the scene's, as of now (index + 1; 0 = the default)
    mov     dword ptr [rip+hv_cut], 0
    call    mat_count
    mov     [rip+hv_nmats], eax
    lea     edi, [rax+1]
    shl     edi, MA_SHIFT
    call    hv_map
    test    rax, rax
    jz      .Lhb_fail
    mov     [rip+hv_mats], rax
    xor     ebx, ebx
3:  cmp     ebx, [rip+hv_nmats]
    jae     4f
    mov     edi, ebx
    call    mat_get
    mov     rsi, rax
    mov     rdi, [rip+hv_mats]
    lea     ecx, [rbx+1]
    shl     ecx, MA_SHIFT
    add     rdi, rcx
    mov     ecx, MA_SZ
    rep     movsb
    movss   xmm0, [rdi-MA_SZ+MA_BLEND]  # (not simply opaque)
    addss   xmm0, [rdi-MA_SZ+MA_SIDED]
    xorps   xmm1, xmm1
    comiss  xmm0, xmm1
    jbe     31f
    mov     dword ptr [rip+hv_cut], 1
31: inc     ebx
    jmp     3b
4:  # triangles, object by object
    xor     r13d, r13d                  # global triangle
    mov     dword ptr [rip+hv_ibud], HV_IBUDGET
    xor     ebx, ebx
.Lhb_obj:
    cmp     ebx, [rip+obj_count]
    jae     .Lhb_lights
    mov     edi, ebx
    call    obj_at
    cmp     dword ptr [rax+OB_TYPE], OT_MESH
    jne     .Lhb_onext
    test    dword ptr [rax+OB_FLAGS], OBF_HIDDEN|OBF_NORENDER
    jnz     .Lhb_onext
    mov     rcx, [rip+hv_only]
    test    rcx, rcx
    jz      1f
    cmp     rax, rcx
    jne     .Lhb_onext
1:  mov     r14, rax                    # object
    call    fa_mark
    mov     [rsp], rax
    mov     rdi, r14
    call    world_verts
    test    rax, rax
    jz      .Lhb_orel
    mov     rbp, rax                    # world positions
    mov     rdi, r14
    call    obj_eval
    mov     r15, rax                    # mesh
    mov     rdi, r14
    call    mat_of
    inc     eax
    mov     [rsp+8], eax                # material + 1
    mov     [rsp+12], r13d              # first triangle of this object
    xor     ecx, ecx
5:  cmp     ecx, [r15+ME_NTRIS]
    jae     6f
    push    rcx
    mov     edi, ecx
    mov     esi, r13d
    call    put_tri
    mov     eax, [rsp+8+8]
    mov     rdx, [rip+hv_tm]
    mov     [rdx+r13*4], eax
    pop     rcx
    inc     r13d
    inc     ecx
    jmp     5b
6:  mov     edi, [rsp+12]
    call    corner_normals              # (rbp, r15) -> hv_tn of the object
    mov     rdi, r14                    # then its instances
    mov     esi, [rsp+8]
    call    hv_inst_emit
.Lhb_orel:
    mov     rdi, [rsp]
    call    fa_release
.Lhb_onext:
    inc     ebx
    jmp     .Lhb_obj
.Lhb_lights:                            # light objects: points
    mov     dword ptr [rip+hv_npoints], 0
    xor     ebx, ebx
7:  cmp     ebx, [rip+obj_count]
    jae     .Lhb_bvh
    mov     edi, ebx
    call    obj_at
    cmp     dword ptr [rax+OB_TYPE], OT_LIGHT
    jne     71f
    mov     ecx, [rip+hv_npoints]
    cmp     ecx, MAX_POINTS
    jae     71f
    shl     ecx, 5
    lea     rdx, [rip+hv_points]
    add     rdx, rcx
    mov     rcx, [rax+OB_LOC]
    mov     [rdx], rcx
    mov     ecx, [rax+OB_LOC+8]
    mov     [rdx+8], ecx
    push    rdx                         # its colour x power (lcam.s), times
    push    rdx                         #  the default strength
    mov     edi, [rax+OB_UID]
    lea     rsi, [rdx+12]
    call    lc_light
    pop     rdx
    pop     rdx
    movss   xmm0, [rip+hf_pt_power]
    movss   xmm1, [rdx+12]
    mulss   xmm1, xmm0
    movss   [rdx+12], xmm1
    movss   xmm1, [rdx+16]
    mulss   xmm1, xmm0
    movss   [rdx+16], xmm1
    movss   xmm1, [rdx+20]
    mulss   xmm1, xmm0
    movss   [rdx+20], xmm1
    inc     dword ptr [rip+hv_npoints]
71: inc     ebx
    jmp     7b
.Lhb_bvh:
    call    build_bvh
    test    eax, eax
    jz      .Lhb_fail
    call    hv_camera
    mov     dword ptr [rip+hv_ready], 1
    mov     eax, 1
    jmp     9f
.Lhb_empty:
    call    hv_camera
    mov     dword ptr [rip+hv_ready], 1
    mov     eax, 1
    jmp     9f
.Lhb_fail:
    call    hv_free_all
    xor     eax, eax
9:  add     rsp, 56
    pop     rbp
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# hv_inst_count(rdi=mesh) -> eax = the triangles its instances add (whole
#   instances while the budget lasts; hv_ibud spent)
hv_inst_count:
    push    rbx
    push    r12
    push    r13
    xor     r13d, r13d
    mov     rbx, [rdi+ME_INST]
    test    rbx, rbx
    jz      9f
    mov     rdi, rbx
    call    inst_pids
    mov     r12, rax
    xor     ecx, ecx
1:  cmp     ecx, [rbx+4]                # (IB_N)
    jae     9f
    movzx   eax, byte ptr [r12+rcx]
    mov     rdx, [rbx+24+rax*8]         # (IB_PROTO)
    mov     eax, [rdx+ME_NTRIS]
    cmp     eax, [rip+hv_ibud]
    ja      9f
    sub     [rip+hv_ibud], eax
    add     r13d, eax
    inc     ecx
    jmp     1b
9:  mov     eax, r13d
    pop     r13
    pop     r12
    pop     rbx
    ret

# hv_inst_emit(rdi=object, esi=material + 1; hive_build's r13 = the next
#   global triangle, advanced) - its mesh's instances as world triangles
#   (as counted: the same budget)
hv_inst_emit:
    push    rbx
    push    r12
    push    r14
    push    r15
    push    rbp
    sub     rsp, 128
    mov     rbx, rdi
    mov     [rsp+120], esi
    mov     rdi, rbx
    call    obj_eval
    mov     r12, [rax+ME_INST]
    test    r12, r12
    jz      9f
    mov     rdi, rbx                    # the object's matrix at +0
    lea     rsi, [rsp]
    call    obj_matrix
    mov     dword ptr [rsp+112], 0      # instance
1:  mov     ecx, [rsp+112]
    cmp     ecx, [r12+4]
    jae     9f
    mov     rdi, r12
    call    inst_pids
    mov     ecx, [rsp+112]
    movzx   eax, byte ptr [rax+rcx]
    mov     r15, [r12+24+rax*8]         # the prototype
    mov     eax, [r15+ME_NTRIS]
    cmp     eax, [rip+hv_ibud]
    ja      9f
    sub     [rip+hv_ibud], eax
    lea     rdi, [rsp+48]               # W x M at +48
    lea     rsi, [rsp]
    mov     rdx, r12
    add     rdx, 128                    # (IB_DATA)
    imul    eax, ecx, 48
    add     rdx, rax
    call    inst_mul
    call    fa_mark
    mov     [rsp+104], rax
    lea     rdi, [rip+frame_arena]      # the prototype's points, placed
    mov     esi, [r15+ME_NVERTS]
    imul    esi, esi, 12
    add     esi, 16
    call    arena_alloc
    test    rax, rax
    jz      8f
    mov     rbp, rax
    xor     ecx, ecx
2:  cmp     ecx, [r15+ME_NVERTS]
    jae     3f
    imul    eax, ecx, 12
    mov     rdx, [r15+ME_POS]
    add     rdx, rax
    lea     rdi, [rbp+rax]
    xor     r8d, r8d
21: movss   xmm0, [rsp+48+r8]
    mulss   xmm0, [rdx]
    movss   xmm1, [rsp+52+r8]
    mulss   xmm1, [rdx+4]
    addss   xmm0, xmm1
    movss   xmm1, [rsp+56+r8]
    mulss   xmm1, [rdx+8]
    addss   xmm0, xmm1
    addss   xmm0, [rsp+60+r8]
    mov     eax, r8d
    shr     eax, 2
    movss   [rdi+rax], xmm0
    add     r8d, 16
    cmp     r8d, 48
    jb      21b
    inc     ecx
    jmp     2b
3:  mov     [rsp+108], r13d             # its triangles, its normals
    xor     r14d, r14d
4:  cmp     r14d, [r15+ME_NTRIS]
    jae     5f
    mov     edi, r14d
    mov     esi, r13d
    call    put_tri
    mov     eax, [rsp+120]
    mov     rdx, [rip+hv_tm]
    mov     [rdx+r13*4], eax
    inc     r13d
    inc     r14d
    jmp     4b
5:  mov     edi, [rsp+108]
    call    corner_normals
8:  mov     rdi, [rsp+104]
    call    fa_release
    inc     dword ptr [rsp+112]
    jmp     1b
9:  add     rsp, 128
    pop     rbp
    pop     r15
    pop     r14
    pop     r12
    pop     rbx
    ret

# put_tri(edi=local triangle, esi=global; r15 = mesh, rbp = world positions)
#   - v0 e1 e2, box, centroid
put_tri:
    push    rbx
    push    r12
    mov     ebx, esi
    mov     rax, [r15+ME_TRIS]
    lea     rcx, [rdi+rdi*2]
    mov     edx, [rax+rcx*4]
    mov     r8d, [rax+rcx*4+4]
    mov     r9d, [rax+rcx*4+8]
    lea     rdx, [rdx+rdx*2]
    lea     r8, [r8+r8*2]
    lea     r9, [r9+r9*2]
    push    rdi                         # UVs (none: NaN)
    push    rdx
    push    r8
    push    r9
    mov     rdx, rbx
    lea     rdx, [rdx+rdx*2]
    shl     rdx, 3
    add     rdx, [rip+hv_tuv]
    mov     dword ptr [rdx], 0x7fc00000
    mov     esi, edi
    mov     rdi, r15
    call    tri_uvs
    mov     rdi, [rsp+24]               # vertex colours (none: 0)
    mov     rax, rbx
    imul    rax, rax, 12
    add     rax, [rip+hv_tvc]
    mov     dword ptr [rax], 0
    mov     rcx, [r15+ME_VCOL]
    test    rcx, rcx
    jz      1f
    mov     rdx, [r15+ME_TRIS]
    lea     esi, [rdi+rdi*2]
    xor     r8d, r8d
2:  mov     r9d, [rdx+rsi*4]
    mov     r9d, [rcx+r9*4]
    mov     [rax+r8*4], r9d
    inc     esi
    inc     r8d
    cmp     r8d, 3
    jb      2b
1:  pop     r9
    pop     r8
    pop     rdx
    pop     rdi
    mov     rax, [r15+ME_POS]           # object space: v0, e1, e2
    lea     r10, [rbx+rbx*8]
    shl     r10, 2
    add     r10, [rip+hv_to]
    xor     ecx, ecx
2:  lea     r11, [rax+rdx*4]
    movss   xmm0, [r11+rcx*4]
    movss   [r10+rcx*4], xmm0
    lea     r11, [rax+r8*4]
    movss   xmm1, [r11+rcx*4]
    subss   xmm1, xmm0
    movss   [r10+12+rcx*4], xmm1
    lea     r11, [rax+r9*4]
    movss   xmm1, [r11+rcx*4]
    subss   xmm1, xmm0
    movss   [r10+24+rcx*4], xmm1
    inc     ecx
    cmp     ecx, 3
    jb      2b
    lea     rdx, [rbp+rdx*4]            # p0
    lea     r8, [rbp+r8*4]              # p1
    lea     r9, [rbp+r9*4]              # p2
    mov     r10, [rip+hv_tv]
    lea     r11, [rbx+rbx*8]
    lea     r10, [r10+r11*4]
    mov     r11, [rip+b_box]
    lea     r12, [rbx+rbx*2]
    lea     r11, [r11+r12*8]
    mov     rax, [rip+b_cent]
    lea     rax, [rax+r12*4]
    xor     ecx, ecx
1:  movss   xmm0, [rdx+rcx*4]
    movss   xmm1, [r8+rcx*4]
    movss   xmm2, [r9+rcx*4]
    movss   [r10+rcx*4], xmm0           # v0
    movss   xmm3, xmm1
    subss   xmm3, xmm0
    movss   [r10+12+rcx*4], xmm3        # e1
    movss   xmm3, xmm2
    subss   xmm3, xmm0
    movss   [r10+24+rcx*4], xmm3        # e2
    movss   xmm3, xmm0                  # box
    minss   xmm3, xmm1
    minss   xmm3, xmm2
    movss   [r11+rcx*4], xmm3
    movss   xmm4, xmm0
    maxss   xmm4, xmm1
    maxss   xmm4, xmm2
    movss   [r11+12+rcx*4], xmm4
    addss   xmm3, xmm4                  # centroid of the box
    mulss   xmm3, [rip+hf_half]
    movss   [rax+rcx*4], xmm3
    inc     ecx
    cmp     ecx, 3
    jb      1b
    pop     r12
    pop     rbx
    ret

# corner_normals(edi=first global triangle; r15 = mesh, rbp = world
#   positions) - per corner: area-weighted normals of the triangles at the
#   vertex within 30 degrees of this one (frame arena scratch)
corner_normals:
    push    rbx
    push    r12
    push    r13
    push    r14
    sub     rsp, 104
    mov     [rsp], edi
    mov     edi, [r15+ME_NTRIS]         # face normals (unit), lengths
    shl     edi, 4
    add     edi, 16
    lea     rsi, [rdi]
    lea     rdi, [rip+frame_arena]
    call    arena_alloc
    test    rax, rax
    jz      .Lcn_out
    mov     [rsp+8], rax
    mov     esi, [r15+ME_NVERTS]        # vertex -> triangles
    lea     esi, [rsi*4+8]
    lea     rdi, [rip+frame_arena]
    call    arena_alloc
    test    rax, rax
    jz      .Lcn_out
    mov     [rsp+16], rax
    mov     rdi, rax
    mov     ecx, [r15+ME_NVERTS]
    inc     ecx
    xor     eax, eax
    rep     stosd
    mov     esi, [r15+ME_NTRIS]
    imul    esi, esi, 12
    add     esi, 8
    lea     rdi, [rip+frame_arena]
    call    arena_alloc
    test    rax, rax
    jz      .Lcn_out
    mov     [rsp+24], rax
    xor     ebx, ebx                    # face normals + counts
1:  cmp     ebx, [r15+ME_NTRIS]
    jae     2f
    mov     eax, [rsp]                  # e1 x e2 of the stored triangle
    add     eax, ebx
    mov     r8, [rip+hv_tv]
    lea     rax, [rax+rax*8]
    lea     r8, [r8+rax*4]
    movss   xmm0, [r8+16]               # e1.y e2.z - e1.z e2.y
    mulss   xmm0, [r8+32]
    movss   xmm1, [r8+20]
    mulss   xmm1, [r8+28]
    subss   xmm0, xmm1
    movss   xmm1, [r8+20]
    mulss   xmm1, [r8+24]
    movss   xmm2, [r8+12]
    mulss   xmm2, [r8+32]
    subss   xmm1, xmm2
    movss   xmm2, [r8+12]
    mulss   xmm2, [r8+28]
    movss   xmm3, [r8+16]
    mulss   xmm3, [r8+24]
    subss   xmm2, xmm3
    movss   xmm3, xmm0                  # length
    mulss   xmm3, xmm0
    movss   xmm4, xmm1
    mulss   xmm4, xmm1
    addss   xmm3, xmm4
    movss   xmm4, xmm2
    mulss   xmm4, xmm2
    addss   xmm3, xmm4
    sqrtss  xmm3, xmm3
    movss   xmm4, [rip+hf_one]
    xorps   xmm5, xmm5
    comiss  xmm3, xmm5
    jbe     11f
    divss   xmm4, xmm3
11: mulss   xmm0, xmm4
    mulss   xmm1, xmm4
    mulss   xmm2, xmm4
    mov     rax, [rsp+8]
    mov     ecx, ebx
    shl     ecx, 4
    movss   [rax+rcx], xmm0
    movss   [rax+rcx+4], xmm1
    movss   [rax+rcx+8], xmm2
    movss   [rax+rcx+12], xmm3
    mov     rax, [r15+ME_TRIS]
    mov     rdx, [rsp+16]
    lea     rcx, [rbx+rbx*2]
    mov     edi, [rax+rcx*4]
    inc     dword ptr [rdx+rdi*4+4]
    mov     edi, [rax+rcx*4+4]
    inc     dword ptr [rdx+rdi*4+4]
    mov     edi, [rax+rcx*4+8]
    inc     dword ptr [rdx+rdi*4+4]
    inc     ebx
    jmp     1b
2:  mov     rdx, [rsp+16]               # prefix, fill, shift back
    xor     eax, eax
    xor     ecx, ecx
21: cmp     ecx, [r15+ME_NVERTS]
    jae     22f
    add     eax, [rdx+rcx*4+4]
    mov     [rdx+rcx*4+4], eax
    inc     ecx
    jmp     21b
22: xor     ebx, ebx
23: cmp     ebx, [r15+ME_NTRIS]
    jae     25f
    xor     r12d, r12d
24: mov     rax, [r15+ME_TRIS]
    lea     rcx, [rbx+rbx*2]
    add     rcx, r12
    mov     edi, [rax+rcx*4]
    mov     rdx, [rsp+16]
    mov     ecx, [rdx+rdi*4]
    inc     dword ptr [rdx+rdi*4]
    mov     rax, [rsp+24]
    mov     [rax+rcx*4], ebx
    inc     r12d
    cmp     r12d, 3
    jb      24b
    inc     ebx
    jmp     23b
25: mov     rdx, [rsp+16]
    mov     ecx, [r15+ME_NVERTS]
26: test    ecx, ecx
    jz      27f
    mov     eax, [rdx+rcx*4-4]
    mov     [rdx+rcx*4], eax
    dec     ecx
    jmp     26b
27: mov     dword ptr [rdx], 0
    xor     ebx, ebx                    # corners
.Lcn_tri:
    cmp     ebx, [r15+ME_NTRIS]
    jae     .Lcn_out
    xor     r12d, r12d
.Lcn_corner:
    cmp     r12d, 3
    jae     .Lcn_tnext
    mov     rax, [rsp+8]                # this face's normal
    mov     ecx, ebx
    shl     ecx, 4
    movss   xmm8, [rax+rcx]
    movss   xmm9, [rax+rcx+4]
    movss   xmm10, [rax+rcx+8]
    xorps   xmm4, xmm4
    xorps   xmm5, xmm5
    xorps   xmm6, xmm6
    mov     rax, [r15+ME_TRIS]
    lea     rcx, [rbx+rbx*2]
    add     rcx, r12
    mov     edi, [rax+rcx*4]
    mov     rdx, [rsp+16]
    mov     r13d, [rdx+rdi*4]
    mov     r14d, [rdx+rdi*4+4]
3:  cmp     r13d, r14d
    jae     4f
    mov     rax, [rsp+24]
    mov     eax, [rax+r13*4]
    shl     eax, 4
    add     rax, [rsp+8]
    movss   xmm0, [rax]
    mulss   xmm0, xmm8
    movss   xmm1, [rax+4]
    mulss   xmm1, xmm9
    addss   xmm0, xmm1
    movss   xmm1, [rax+8]
    mulss   xmm1, xmm10
    addss   xmm0, xmm1
    comiss  xmm0, [rip+hf_cos30]
    jb      31f
    movss   xmm3, [rax+12]
    movss   xmm0, [rax]
    mulss   xmm0, xmm3
    addss   xmm4, xmm0
    movss   xmm0, [rax+4]
    mulss   xmm0, xmm3
    addss   xmm5, xmm0
    movss   xmm0, [rax+8]
    mulss   xmm0, xmm3
    addss   xmm6, xmm0
31: inc     r13d
    jmp     3b
4:  movss   xmm3, xmm4                  # normalize (or the face's own)
    mulss   xmm3, xmm4
    movss   xmm7, xmm5
    mulss   xmm7, xmm5
    addss   xmm3, xmm7
    movss   xmm7, xmm6
    mulss   xmm7, xmm6
    addss   xmm3, xmm7
    sqrtss  xmm3, xmm3
    xorps   xmm7, xmm7
    comiss  xmm3, xmm7
    ja      41f
    movss   xmm4, xmm8
    movss   xmm5, xmm9
    movss   xmm6, xmm10
    jmp     42f
41: movss   xmm7, [rip+hf_one]
    divss   xmm7, xmm3
    mulss   xmm4, xmm7
    mulss   xmm5, xmm7
    mulss   xmm6, xmm7
42: mov     eax, [rsp]
    add     eax, ebx
    lea     rax, [rax+rax*8]
    lea     rcx, [r12+r12*2]
    add     rax, rcx
    mov     rdx, [rip+hv_tn]
    movss   [rdx+rax*4], xmm4
    movss   [rdx+rax*4+4], xmm5
    movss   [rdx+rax*4+8], xmm6
    inc     r12d
    jmp     .Lcn_corner
.Lcn_tnext:
    inc     ebx
    jmp     .Lcn_tri
.Lcn_out:
    add     rsp, 104
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# hv_camera - the scene's camera object (looking down its -Z), or the
#   viewport's; hv_cam = origin, right, up, forward (unit) and tan(fov/2)
hv_camera:
    push    rbx
    sub     rsp, 64
    mov     dword ptr [rip+hv_camuid], 0
    call    lc_camera                   # the camera that renders (lcam.s)
    test    rax, rax
    jz      5f
    mov     ecx, [rax+OB_UID]
    mov     [rip+hv_camuid], ecx
2:  mov     rdi, rax                    # its matrix: columns are the axes
    lea     rsi, [rsp]
    call    obj_matrix
    lea     rdi, [rip+hv_cam]
    xor     ecx, ecx
3:  imul    edx, ecx, 16
    mov     eax, [rsp+rdx+12]           # translation
    mov     [rdi+rcx*4], eax
    movss   xmm0, [rsp+rdx]             # x column -> right
    movss   [rdi+12+rcx*4], xmm0
    movss   xmm0, [rsp+rdx+4]           # y column -> up
    movss   [rdi+24+rcx*4], xmm0
    movss   xmm0, [rsp+rdx+8]           # -z column -> forward
    xorps   xmm0, [rip+hf_sign]
    movss   [rdi+36+rcx*4], xmm0
    inc     ecx
    cmp     ecx, 3
    jb      3b
    jmp     6f
5:  mov     edi, [rip+vp_area]          # no camera: the last viewport's
    call    cam_load
    call    cam_setup_any
    lea     rdi, [rip+hv_cam]
    xor     ecx, ecx
51: lea     rax, [rip+eye]
    mov     edx, [rax+rcx*4]
    mov     [rdi+rcx*4], edx
    lea     rax, [rip+right]
    mov     edx, [rax+rcx*4]
    mov     [rdi+12+rcx*4], edx
    lea     rax, [rip+up]
    mov     edx, [rax+rcx*4]
    mov     [rdi+24+rcx*4], edx
    lea     rax, [rip+fwd]
    mov     edx, [rax+rcx*4]
    mov     [rdi+36+rcx*4], edx
    inc     ecx
    cmp     ecx, 3
    jb      51b
6:  lea     rdi, [rip+hv_cam+12]        # unit axes
    call    hv_unit
    lea     rdi, [rip+hv_cam+24]
    call    hv_unit
    lea     rdi, [rip+hv_cam+36]
    call    hv_unit
    mov     eax, [rip+hf_tanh]
    mov     [rip+hv_cam+48], eax
    mov     edi, [rip+hv_camuid]        # a camera: its lens
    test    edi, edi
    jz      7f
    call    lc_lens_tan
    movss   [rip+hv_cam+48], xmm0
7:  add     rsp, 64
    pop     rbx
    ret

# cam_setup_any - the viewport camera vectors (eye, right, up, fwd) without
#   a canvas (cam_setup needs one: use its vector part)
cam_setup_any:
    jmp     cam_setup

# hv_unit(rdi=float[3])
hv_unit:
    movss   xmm0, [rdi]
    mulss   xmm0, xmm0
    movss   xmm1, [rdi+4]
    mulss   xmm1, xmm1
    addss   xmm0, xmm1
    movss   xmm1, [rdi+8]
    mulss   xmm1, xmm1
    addss   xmm0, xmm1
    sqrtss  xmm0, xmm0
    xorps   xmm1, xmm1
    comiss  xmm0, xmm1
    jbe     1f
    movss   xmm1, [rip+hf_one]
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
1:  ret

# =============================================================================
#  BVH build: binned SAH over centroids (BVH2), then collapse to 4-wide
# =============================================================================
build_bvh:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    push    rbp
    sub     rsp, 104
    mov     r12d, [rip+hv_n]
    mov     rdi, [rip+b_prim]           # prims in order
    xor     ecx, ecx
1:  cmp     ecx, r12d
    jae     2f
    mov     [rdi+rcx*4], ecx
    inc     ecx
    jmp     1b
2:  lea     edi, [r12*2+8]              # BVH2 nodes: at most 2n - 1
    shl     edi, 5
    call    hv_map
    test    rax, rax
    jz      .Lbb_fail
    mov     [rip+b_n2], rax
    lea     edi, [r12*2+8]              # stack: (node, start, end)
    imul    edi, edi, 12
    call    hv_map
    test    rax, rax
    jz      .Lbb_fail
    mov     [rip+b_stack], rax
    mov     dword ptr [rip+b_nn2], 1    # the root
    mov     rax, [rip+b_stack]
    mov     dword ptr [rax], 0
    mov     dword ptr [rax+4], 0
    mov     [rax+8], r12d
    mov     r13d, 1                     # stack depth
.Lbb_pop:
    test    r13d, r13d
    jz      .Lbb_collapse
    dec     r13d
    mov     rax, [rip+b_stack]
    lea     rcx, [r13+r13*2]
    mov     ebx, [rax+rcx*4]            # node
    mov     r14d, [rax+rcx*4+4]         # start
    mov     r15d, [rax+rcx*4+8]         # end
    # bounds and centroid bounds
    movaps  xmm0, [rip+hf_inf]          # box min (x y z in lanes)
    movaps  xmm1, [rip+hf_ninf]         # box max
    movaps  xmm2, [rip+hf_inf]          # centroid min
    movaps  xmm3, [rip+hf_ninf]
    mov     ecx, r14d
3:  cmp     ecx, r15d
    jae     4f
    mov     rax, [rip+b_prim]
    mov     eax, [rax+rcx*4]
    mov     rdx, [rip+b_box]
    lea     r8, [rax+rax*2]
    lea     rdx, [rdx+r8*8]
    movups  xmm4, [rdx]                 # (min xyz, max x)
    minps   xmm0, xmm4
    movups  xmm4, [rdx+12]              # (max xyz, ...)
    maxps   xmm1, xmm4
    mov     rdx, [rip+b_cent]
    lea     rdx, [rdx+r8*4]
    movups  xmm4, [rdx]
    minps   xmm2, xmm4
    maxps   xmm3, xmm4
    inc     ecx
    jmp     3b
4:  mov     rax, [rip+b_n2]             # the node's box
    mov     ecx, ebx
    shl     ecx, 5
    add     rax, rcx
    movups  [rsp], xmm0
    movups  [rsp+16], xmm1
    mov     rdx, [rsp]
    mov     [rax], rdx
    mov     edx, [rsp+8]
    mov     [rax+8], edx
    mov     rdx, [rsp+16]
    mov     [rax+12], rdx
    mov     edx, [rsp+24]
    mov     [rax+20], edx
    movups  [rsp+32], xmm2              # centroid bounds
    movups  [rsp+48], xmm3
    mov     eax, r15d
    sub     eax, r14d                   # count
    mov     [rsp+64], eax
    cmp     eax, 2
    jbe     .Lbb_leaf
    # the widest centroid axis
    xor     ebp, ebp
    movss   xmm5, [rsp+48]
    subss   xmm5, [rsp+32]
    movss   xmm6, [rsp+52]
    subss   xmm6, [rsp+36]
    comiss  xmm6, xmm5
    jbe     41f
    mov     ebp, 1
    movss   xmm5, xmm6
41: movss   xmm6, [rsp+56]
    subss   xmm6, [rsp+40]
    comiss  xmm6, xmm5
    jbe     42f
    mov     ebp, 2
    movss   xmm5, xmm6
42: movss   [rsp+68], xmm5              # extent
    comiss  xmm5, [rip+hf_tiny]
    ja      .Lbb_bins
    cmp     dword ptr [rsp+64], LEAF_MAX
    jbe     .Lbb_leaf
    mov     eax, r14d                   # all at one point: split the middle
    add     eax, r15d
    shr     eax, 1
    mov     [rsp+72], eax
    jmp     .Lbb_children
.Lbb_bins:
    lea     rdi, [rip+b_bins]           # clear
    xor     ecx, ecx
5:  mov     dword ptr [rdi], 0
    movaps  xmm0, [rip+hf_inf]
    movups  [rdi+4], xmm0
    movaps  xmm0, [rip+hf_ninf]
    movups  [rdi+16], xmm0
    add     rdi, 32
    inc     ecx
    cmp     ecx, NBINS
    jb      5b
    movss   xmm7, [rip+hf_nbins]        # scale = 16 / extent (a hair less)
    divss   xmm7, [rsp+68]
    movss   [rsp+76], xmm7
    movss   [rip+b_scale], xmm7
    mov     eax, [rsp+32+rbp*4]         # the axis' centroid minimum
    mov     [rip+b_cmin_axis], eax
    mov     ecx, r14d
6:  cmp     ecx, r15d
    jae     7f
    mov     rax, [rip+b_prim]
    mov     eax, [rax+rcx*4]
    call    bin_of
    mov     edx, eax
    shl     edx, 5
    lea     rdi, [rip+b_bins]
    add     rdi, rdx
    inc     dword ptr [rdi]
    mov     rax, [rip+b_prim]
    mov     eax, [rax+rcx*4]
    mov     rdx, [rip+b_box]
    lea     r8, [rax+rax*2]
    lea     rdx, [rdx+r8*8]
    movups  xmm0, [rdi+4]
    movups  xmm4, [rdx]
    minps   xmm0, xmm4
    movups  [rdi+4], xmm0
    movups  xmm1, [rdi+16]
    movups  xmm4, [rdx+12]
    maxps   xmm1, xmm4
    movups  [rdi+16], xmm1
    inc     ecx
    jmp     6b
7:  # sweep: left areas and counts, then right; best split
    call    bin_sweep                   # eax = best bin split (1..15) or 0
    test    eax, eax                    # (0: a leaf is cheaper)
    jnz     71f
    cmp     dword ptr [rsp+64], LEAF_MAX
    jbe     .Lbb_leaf
    mov     eax, NBINS/2                # too many for a leaf: split anyway
71: mov     [rsp+80], eax
    mov     r8d, r14d                   # partition by bin < split
    lea     r9d, [r15-1]
8:  cmp     r8d, r9d
    jg      81f
    mov     rdx, [rip+b_prim]
    mov     eax, [rdx+r8*4]
    push    r8
    push    r9
    call    bin_of
    pop     r9
    pop     r8
    cmp     eax, [rsp+80]
    jae     82f
    inc     r8d
    jmp     8b
82: mov     rdx, [rip+b_prim]
    mov     eax, [rdx+r8*4]
    mov     ecx, [rdx+r9*4]
    mov     [rdx+r8*4], ecx
    mov     [rdx+r9*4], eax
    dec     r9d
    jmp     8b
81: mov     [rsp+72], r8d
    cmp     r8d, r14d                   # one side empty: the middle
    je      83f
    cmp     r8d, r15d
    jne     .Lbb_children
83: mov     eax, r14d
    add     eax, r15d
    shr     eax, 1
    mov     [rsp+72], eax
.Lbb_children:
    mov     eax, [rip+b_nn2]            # two new nodes
    add     dword ptr [rip+b_nn2], 2
    mov     rcx, [rip+b_n2]
    mov     edx, ebx
    shl     edx, 5
    mov     [rcx+rdx+24], eax           # left (right = left + 1)
    mov     dword ptr [rcx+rdx+28], 0
    mov     rcx, [rip+b_stack]          # push both
    lea     rdx, [r13+r13*2]
    mov     [rcx+rdx*4], eax
    mov     [rcx+rdx*4+4], r14d
    mov     r8d, [rsp+72]
    mov     [rcx+rdx*4+8], r8d
    inc     r13d
    lea     rdx, [r13+r13*2]
    inc     eax
    mov     [rcx+rdx*4], eax
    mov     [rcx+rdx*4+4], r8d
    mov     [rcx+rdx*4+8], r15d
    inc     r13d
    jmp     .Lbb_pop
.Lbb_leaf:
    mov     rcx, [rip+b_n2]
    mov     edx, ebx
    shl     edx, 5
    mov     [rcx+rdx+24], r14d
    mov     eax, [rsp+64]
    or      eax, 0x80000000
    mov     [rcx+rdx+28], eax
    jmp     .Lbb_pop
.Lbb_collapse:
    call    collapse4
    test    eax, eax
    jz      .Lbb_fail
    call    reorder_tris
    mov     eax, 1
    jmp     9f
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

# bin_of(eax=prim; ebp = axis; b_cmin_axis, b_scale) -> eax = bin
bin_of:
    mov     rdx, [rip+b_cent]
    lea     r10, [rax+rax*2]
    lea     rdx, [rdx+r10*4]
    movss   xmm0, [rdx+rbp*4]
    movss   xmm1, [rip+b_cmin_axis]
    subss   xmm0, xmm1
    mulss   xmm0, [rip+b_scale]
    cvttss2si eax, xmm0
    test    eax, eax
    jns     1f
    xor     eax, eax
1:  cmp     eax, NBINS-1
    jbe     2f
    mov     eax, NBINS-1
2:  ret

# bin_sweep - (build_bvh's [rsp+..] one level up: count at +64) -> eax =
#   the best split bin, or 0 when a leaf costs less
bin_sweep:
    push    rbx
    sub     rsp, 16
    # left: running box and count -> area * count at each split
    movaps  xmm0, [rip+hf_inf]
    movaps  xmm1, [rip+hf_ninf]
    xor     ecx, ecx
    xor     ebx, ebx                    # running count
    lea     rdi, [rip+b_bins]
1:  cmp     ecx, NBINS-1
    jae     2f
    movups  xmm2, [rdi+4]
    minps   xmm0, xmm2
    movups  xmm2, [rdi+16]
    maxps   xmm1, xmm2
    add     ebx, [rdi]
    call    half_area                   # xmm0/xmm1 -> xmm4 (keeps both)
    cvtsi2ss xmm5, ebx
    mulss   xmm4, xmm5
    lea     rdx, [rip+b_lr]
    movss   [rdx+rcx*8], xmm4
    add     rdi, 32
    inc     ecx
    jmp     1b
2:  movaps  xmm0, [rip+hf_inf]          # right, from the end
    movaps  xmm1, [rip+hf_ninf]
    xor     ebx, ebx
    mov     ecx, NBINS-1
    lea     rdi, [rip+b_bins+(NBINS-1)*32]
3:  test    ecx, ecx
    jz      4f
    movups  xmm2, [rdi+4]
    minps   xmm0, xmm2
    movups  xmm2, [rdi+16]
    maxps   xmm1, xmm2
    add     ebx, [rdi]
    call    half_area
    cvtsi2ss xmm5, ebx
    mulss   xmm4, xmm5
    lea     rdx, [rip+b_lr]
    movss   [rdx+rcx*8-4], xmm4         # split at ecx: right part from bin ecx
    sub     rdi, 32
    dec     ecx
    jmp     3b
4:  movss   xmm6, [rip+hf_big]          # best = min over splits 1..15
    xor     eax, eax
    mov     ecx, 1
5:  cmp     ecx, NBINS
    jae     6f
    lea     rdx, [rip+b_lr]
    movss   xmm4, [rdx+rcx*8-8]         # left of split ecx: bins 0..ecx-1
    addss   xmm4, [rdx+rcx*8-4]         # right: bins ecx..15
    comiss  xmm4, xmm6
    jae     51f
    movss   xmm6, xmm4
    mov     eax, ecx
51: inc     ecx
    jmp     5b
6:  # the leaf: count * area(node), against 0.5 area + best (traversal step)
    movups  xmm0, [rsp+16+8+8]          # build_bvh's box min / max
    movups  xmm1, [rsp+16+8+8+16]
    call    half_area
    mov     ebx, [rsp+16+8+8+64]
    cvtsi2ss xmm5, ebx
    movss   xmm7, xmm4
    mulss   xmm7, xmm5                  # leaf cost
    mulss   xmm4, [rip+hf_half]
    addss   xmm6, xmm4                  # split cost
    comiss  xmm7, xmm6
    ja      9f
    cmp     ebx, LEAF_MAX
    ja      9f
    xor     eax, eax
9:  add     rsp, 16
    pop     rbx
    ret

# half_area(xmm0=min, xmm1=max) -> xmm4 = dx dy + dy dz + dz dx (0 if empty)
half_area:
    movaps  xmm2, xmm1
    subps   xmm2, xmm0
    xorps   xmm3, xmm3
    maxps   xmm2, xmm3
    movaps  xmm3, xmm2
    shufps  xmm3, xmm3, 0b11001001      # (y z x)
    mulps   xmm3, xmm2                  # (xy yz zx)
    movaps  xmm4, xmm3
    movhlps xmm5, xmm3
    addss   xmm4, xmm5                  # xy + zx
    shufps  xmm3, xmm3, 0b01010101
    addss   xmm4, xmm3                  # + yz
    ret

# collapse4 -> eax = 1: BVH4 nodes from the BVH2 (largest-area children are
#   opened until four)
collapse4:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    push    rbp
    sub     rsp, 72
    mov     edi, [rip+b_nn2]            # (at most nn2 / 2 + 1 BVH4 nodes)
    shr     edi, 1
    add     edi, 2
    shl     edi, 7
    call    hv_map
    test    rax, rax
    jz      .Lc4_fail
    mov     [rip+hv_nodes], rax
    mov     dword ptr [rip+hv_nn4], 0
    mov     rax, [rip+b_n2]             # the root a leaf: a node around it
    test    dword ptr [rax+28], 0x80000000
    jz      1f
    call    new_n4
    mov     r12d, eax
    xor     edi, edi                    # child 0 = BVH2 node 0 (a leaf)
    mov     esi, r12d
    xor     edx, edx
    call    set_child
    mov     dword ptr [rip+hv_root], 0
    jmp     .Lc4_ok
1:  mov     dword ptr [rip+hv_root], 0
    mov     rax, [rip+b_stack]          # stack of (BVH2 node, BVH4 node)
    mov     dword ptr [rax], 0
    call    new_n4
    mov     rax, [rip+b_stack]
    mov     dword ptr [rax+4], 0
    mov     r13d, 1
.Lc4_pop:
    test    r13d, r13d
    jz      .Lc4_ok
    dec     r13d
    mov     rax, [rip+b_stack]
    mov     ebx, [rax+r13*8]            # BVH2 internal node
    mov     r12d, [rax+r13*8+4]         # its BVH4 node
    mov     rax, [rip+b_n2]             # children list: left, right
    mov     ecx, ebx
    shl     ecx, 5
    mov     edx, [rax+rcx+24]
    mov     [rsp], edx
    inc     edx
    mov     [rsp+4], edx
    mov     r14d, 2                     # count
2:  cmp     r14d, 4
    jae     4f
    mov     r15d, -1                    # the internal child of largest area
    xorps   xmm6, xmm6
    xor     ecx, ecx
3:  cmp     ecx, r14d
    jae     31f
    mov     edx, [rsp+rcx*4]
    mov     rax, [rip+b_n2]
    shl     edx, 5
    add     rax, rdx
    test    dword ptr [rax+28], 0x80000000
    jnz     32f
    movups  xmm0, [rax]
    movups  xmm1, [rax+12]
    push    rcx
    call    half_area
    pop     rcx
    comiss  xmm4, xmm6
    jb      32f
    movss   xmm6, xmm4
    mov     r15d, ecx
32: inc     ecx
    jmp     3b
31: test    r15d, r15d
    js      4f
    mov     edx, [rsp+r15*4]            # open it
    mov     rax, [rip+b_n2]
    shl     edx, 5
    mov     eax, [rax+rdx+24]
    mov     [rsp+r15*4], eax
    inc     eax
    mov     [rsp+r14*4], eax
    inc     r14d
    jmp     2b
4:  xor     ebp, ebp                    # the slots
5:  cmp     ebp, r14d
    jae     .Lc4_pop
    mov     edi, [rsp+rbp*4]
    mov     esi, r12d
    mov     edx, ebp
    call    set_child                   # eax = new BVH4 node or -1 (leaf)
    test    eax, eax
    js      51f
    mov     rcx, [rip+b_stack]
    mov     edx, [rsp+rbp*4]
    mov     [rcx+r13*8], edx
    mov     [rcx+r13*8+4], eax
    inc     r13d
51: inc     ebp
    jmp     5b
.Lc4_ok:
    mov     eax, 1
    jmp     9f
.Lc4_fail:
    xor     eax, eax
9:  add     rsp, 72
    pop     rbp
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# new_n4 -> eax = a new BVH4 node, its four boxes empty
new_n4:
    mov     eax, [rip+hv_nn4]
    inc     dword ptr [rip+hv_nn4]
    mov     rdx, rax
    shl     rdx, 7
    add     rdx, [rip+hv_nodes]
    movaps  xmm0, [rip+hf_inf]
    movaps  xmm1, [rip+hf_ninf]
    movups  [rdx], xmm0                 # minx
    movups  [rdx+16], xmm1              # maxx
    movups  [rdx+32], xmm0
    movups  [rdx+48], xmm1
    movups  [rdx+64], xmm0
    movups  [rdx+80], xmm1
    pcmpeqd xmm2, xmm2
    movups  [rdx+96], xmm2              # children: none
    ret

# set_child(edi=BVH2 node, esi=BVH4 node, edx=slot) -> eax = a new BVH4
#   node for an internal child (to be filled), -1 for a leaf
set_child:
    push    rbx
    push    r12
    push    r13
    mov     ebx, edi
    mov     r12d, esi
    mov     r13d, edx
    mov     rax, [rip+b_n2]
    mov     ecx, ebx
    shl     ecx, 5
    add     rax, rcx
    mov     rdx, r12
    shl     rdx, 7
    add     rdx, [rip+hv_nodes]
    mov     ecx, [rax]                  # box into the lanes
    mov     [rdx+r13*4], ecx
    mov     ecx, [rax+12]
    mov     [rdx+16+r13*4], ecx
    mov     ecx, [rax+4]
    mov     [rdx+32+r13*4], ecx
    mov     ecx, [rax+16]
    mov     [rdx+48+r13*4], ecx
    mov     ecx, [rax+8]
    mov     [rdx+64+r13*4], ecx
    mov     ecx, [rax+20]
    mov     [rdx+80+r13*4], ecx
    mov     ecx, [rax+28]
    test    ecx, 0x80000000
    jz      1f
    and     ecx, 0xf                    # leaf: first | count << 27 | bit 31
    shl     ecx, 27
    or      ecx, [rax+24]
    or      ecx, 0x80000000
    mov     [rdx+96+r13*4], ecx
    mov     eax, -1
    jmp     9f
1:  push    rdx
    call    new_n4
    pop     rdx
    mov     [rdx+96+r13*4], eax
9:  pop     r13
    pop     r12
    pop     rbx
    ret

# reorder_tris - triangle arrays in leaf order (b_prim), so leaves index
#   them directly
reorder_tris:
    push    rbx
    push    r12
    push    r13
    sub     rsp, 8
    mov     r12d, [rip+hv_n]
    imul    edi, r12d, 36               # positions
    add     edi, 64
    call    hv_map
    test    rax, rax
    jz      9f
    mov     r13, rax
    xor     ebx, ebx
1:  cmp     ebx, r12d
    jae     2f
    mov     rax, [rip+b_prim]
    mov     eax, [rax+rbx*4]
    lea     rsi, [rax+rax*8]
    shl     rsi, 2
    add     rsi, [rip+hv_tv]
    lea     rdi, [rbx+rbx*8]
    lea     rdi, [r13+rdi*4]
    mov     ecx, 36
    rep     movsb
    inc     ebx
    jmp     1b
2:  mov     [rip+hv_tv], r13
    imul    edi, r12d, 36               # normals
    add     edi, 64
    call    hv_map
    test    rax, rax
    jz      9f
    mov     r13, rax
    xor     ebx, ebx
3:  cmp     ebx, r12d
    jae     4f
    mov     rax, [rip+b_prim]
    mov     eax, [rax+rbx*4]
    lea     rsi, [rax+rax*8]
    shl     rsi, 2
    add     rsi, [rip+hv_tn]
    lea     rdi, [rbx+rbx*8]
    lea     rdi, [r13+rdi*4]
    mov     ecx, 36
    rep     movsb
    inc     ebx
    jmp     3b
4:  mov     [rip+hv_tn], r13
    imul    edi, r12d, 36               # object space (shader graphs)
    add     edi, 64
    call    hv_map
    test    rax, rax
    jz      9f
    mov     r13, rax
    xor     ebx, ebx
41: cmp     ebx, r12d
    jae     42f
    mov     rax, [rip+b_prim]
    mov     eax, [rax+rbx*4]
    lea     rsi, [rax+rax*8]
    shl     rsi, 2
    add     rsi, [rip+hv_to]
    lea     rdi, [rbx+rbx*8]
    lea     rdi, [r13+rdi*4]
    mov     ecx, 36
    rep     movsb
    inc     ebx
    jmp     41b
42: mov     [rip+hv_to], r13
    imul    edi, r12d, 24               # UVs, the same order
    add     edi, 64
    call    hv_map
    test    rax, rax
    jz      9f
    mov     r13, rax
    xor     ebx, ebx
43: cmp     ebx, r12d
    jae     44f
    mov     rax, [rip+b_prim]
    mov     eax, [rax+rbx*4]
    lea     rsi, [rax+rax*2]
    shl     rsi, 3
    add     rsi, [rip+hv_tuv]
    lea     rdi, [rbx+rbx*2]
    lea     rdi, [r13+rdi*8]
    mov     ecx, 24
    rep     movsb
    inc     ebx
    jmp     43b
44: mov     [rip+hv_tuv], r13
    imul    edi, r12d, 12               # colours, the same order
    add     edi, 64
    call    hv_map
    test    rax, rax
    jz      9f
    mov     r13, rax
    xor     ebx, ebx
45: cmp     ebx, r12d
    jae     46f
    mov     rax, [rip+b_prim]
    mov     eax, [rax+rbx*4]
    imul    rsi, rax, 12
    add     rsi, [rip+hv_tvc]
    imul    rdi, rbx, 12
    add     rdi, r13
    mov     ecx, 12
    rep     movsb
    inc     ebx
    jmp     45b
46: mov     [rip+hv_tvc], r13
    lea     edi, [r12*4+64]             # materials
    call    hv_map
    test    rax, rax
    jz      9f
    mov     r13, rax
    xor     ebx, ebx
5:  cmp     ebx, r12d
    jae     6f
    mov     rax, [rip+b_prim]
    mov     eax, [rax+rbx*4]
    mov     rdx, [rip+hv_tm]
    mov     eax, [rdx+rax*4]
    mov     [r13+rbx*4], eax
    inc     ebx
    jmp     5b
6:  mov     [rip+hv_tm], r13
9:  add     rsp, 8
    pop     r13
    pop     r12
    pop     rbx
    ret

# =============================================================================
#  Ray queries. Ray block (rdi): o[3] d[3] tmax, then outputs t, tri, u, v
#  (see RAY_* offsets); 4-wide box tests, nearest child first
# =============================================================================
.equ RAY_O,     0
.equ RAY_D,     12
.equ RAY_TMAX,  24
.equ RAY_T,     28
.equ RAY_TRI,   32
.equ RAY_U,     36
.equ RAY_V,     40

# hv_trace(rdi=ray) -> eax = 1 if it hit (t, tri, u, v filled)
hv_trace:
    xor     esi, esi
    jmp     trace_common
# hv_occluded(rdi=ray) -> eax = 1 if anything is closer than tmax
hv_occluded:
    mov     esi, 1
trace_common:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    push    rbp
    mov     rbp, rsp
    sub     rsp, 768
    and     rsp, -16
    mov     rbx, rdi
    mov     [rsp+64], esi               # any-hit
    mov     dword ptr [rbx+RAY_TRI], -1
    xor     eax, eax
    cmp     dword ptr [rip+hv_n], 0
    je      .Ltr_out
    # broadcast o, 1/d; near / far offsets per axis
    xor     ecx, ecx
1:  movss   xmm0, [rbx+RAY_O+rcx*4]
    shufps  xmm0, xmm0, 0
    movaps  xmm1, xmm0
    imul    edx, ecx, 16
    movaps  [rsp+rdx], xmm0             # o x y z at 0 16 32
    movss   xmm0, [rbx+RAY_D+rcx*4]
    movss   xmm2, xmm0
    andps   xmm2, [rip+hf_absm]
    comiss  xmm2, [rip+hf_tiny]
    ja      2f
    movss   xmm0, [rip+hf_big]          # (avoid 1/0: a huge slope)
    jmp     3f
2:  movss   xmm2, [rip+hf_one]
    divss   xmm2, xmm0
    movss   xmm0, xmm2
3:  mov     eax, 0                      # near offset: 0 (min) for d >= 0
    xorps   xmm3, xmm3
    comiss  xmm0, xmm3
    jae     4f
    mov     eax, 16
4:  mov     [rsp+80+rcx*4], eax
    shufps  xmm0, xmm0, 0
    movaps  [rsp+96+rdx], xmm0          # 1/d at 96 112 128
    inc     ecx
    cmp     ecx, 3
    jb      1b
    movss   xmm0, [rbx+RAY_TMAX]
    movss   [rsp+68], xmm0              # t closest so far
    mov     dword ptr [rsp+72], 0       # hit?
    mov     eax, [rip+hv_root]          # stack at rsp+160
    mov     [rsp+160], eax
    mov     r12d, 1
.Ltr_pop:
    test    r12d, r12d
    jz      .Ltr_done
    dec     r12d
    mov     r13d, [rsp+160+r12*4]
    test    r13d, r13d
    js      .Ltr_leaf
    # node: 4 boxes at once
    mov     r14, r13
    shl     r14, 7
    add     r14, [rip+hv_nodes]
    mov     eax, [rsp+80]               # x: near / far lanes
    mov     ecx, eax
    xor     ecx, 16
    movups  xmm0, [r14+rax]
    subps   xmm0, [rsp]
    mulps   xmm0, [rsp+96]              # tnear x
    movups  xmm1, [r14+rcx]
    subps   xmm1, [rsp]
    mulps   xmm1, [rsp+96]              # tfar x
    mov     eax, [rsp+84]               # y
    mov     ecx, eax
    xor     ecx, 16
    movups  xmm2, [r14+32+rax]
    subps   xmm2, [rsp+16]
    mulps   xmm2, [rsp+112]
    maxps   xmm0, xmm2
    movups  xmm2, [r14+32+rcx]
    subps   xmm2, [rsp+16]
    mulps   xmm2, [rsp+112]
    minps   xmm1, xmm2
    mov     eax, [rsp+88]               # z
    mov     ecx, eax
    xor     ecx, 16
    movups  xmm2, [r14+64+rax]
    subps   xmm2, [rsp+32]
    mulps   xmm2, [rsp+128]
    maxps   xmm0, xmm2
    movups  xmm2, [r14+64+rcx]
    subps   xmm2, [rsp+32]
    mulps   xmm2, [rsp+128]
    minps   xmm1, xmm2
    xorps   xmm2, xmm2
    maxps   xmm0, xmm2                  # tnear >= 0
    movss   xmm2, [rsp+68]
    shufps  xmm2, xmm2, 0
    minps   xmm1, xmm2                  # tfar <= closest
    movaps  xmm2, xmm0
    cmpleps xmm2, xmm1
    movmskps eax, xmm2
    test    eax, eax
    jz      .Ltr_pop
    movaps  [rsp+144], xmm0             # tnear per lane
    # push the hit children, farthest first (insertion into the stack top)
    mov     r15d, r12d                  # where this node's pushes start
    xor     ecx, ecx
5:  bt      eax, ecx
    jnc     6f
    mov     edx, [r14+96+rcx*4]
    movss   xmm3, [rsp+144+rcx*4]
    mov     r8d, r12d                   # insert keeping descending tnear
51: cmp     r8d, r15d
    jbe     52f
    mov     r9d, [rsp+160+r8*4-4]       # (the previous entry's tnear is kept
    movss   xmm4, [rsp+416+r8*4-4]      #  in a parallel array at +416)
    comiss  xmm4, xmm3
    jae     52f
    mov     [rsp+160+r8*4], r9d
    movss   [rsp+416+r8*4], xmm4
    dec     r8d
    jmp     51b
52: mov     [rsp+160+r8*4], edx
    movss   [rsp+416+r8*4], xmm3
    inc     r12d
6:  inc     ecx
    cmp     ecx, 4
    jb      5b
    cmp     r12d, 60                    # (the stack holds 64)
    jb      .Ltr_pop
    mov     r12d, 60
    jmp     .Ltr_pop
.Ltr_leaf:
    cmp     r13d, -1
    je      .Ltr_pop
    mov     r14d, r13d                  # first, count
    and     r14d, 0x07ffffff
    mov     r15d, r13d
    shr     r15d, 27
    and     r15d, 0xf
    add     r15d, r14d
7:  cmp     r14d, r15d
    jae     .Ltr_pop
    mov     edi, r14d
    call    tri_hit                     # xmm0 = t, xmm1 = u, xmm2 = v; eax
    test    eax, eax
    jz      71f
    comiss  xmm0, [rsp+68]
    jae     71f
    movss   [rsp+68], xmm0
    mov     [rbx+RAY_TRI], r14d
    movss   [rbx+RAY_T], xmm0
    movss   [rbx+RAY_U], xmm1
    movss   [rbx+RAY_V], xmm2
    mov     dword ptr [rsp+72], 1
    cmp     dword ptr [rsp+64], 0       # any hit will do
    jne     .Ltr_done
71: inc     r14d
    jmp     7b
.Ltr_done:
    mov     eax, [rsp+72]
.Ltr_out:
    mov     rsp, rbp
    pop     rbp
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# tri_hit(edi=triangle; rbx = ray) -> eax = 1 with xmm0 = t, xmm1 = u,
#   xmm2 = v (Moeller-Trumbore on v0 e1 e2); t > epsilon. (The caller's
#   closest t is compared after.)
tri_hit:
    mov     rax, [rip+hv_tv]
    lea     rcx, [rdi+rdi*8]
    lea     rax, [rax+rcx*4]
    movss   xmm8, [rbx+RAY_D]           # p = d x e2
    movss   xmm9, [rbx+RAY_D+4]
    movss   xmm10, [rbx+RAY_D+8]
    movss   xmm0, xmm9
    mulss   xmm0, [rax+32]
    movss   xmm3, xmm10
    mulss   xmm3, [rax+28]
    subss   xmm0, xmm3
    movss   xmm1, xmm10
    mulss   xmm1, [rax+24]
    movss   xmm3, xmm8
    mulss   xmm3, [rax+32]
    subss   xmm1, xmm3
    movss   xmm2, xmm8
    mulss   xmm2, [rax+28]
    movss   xmm3, xmm9
    mulss   xmm3, [rax+24]
    subss   xmm2, xmm3
    movss   xmm3, [rax+12]              # det = e1 . p
    mulss   xmm3, xmm0
    movss   xmm4, [rax+16]
    mulss   xmm4, xmm1
    addss   xmm3, xmm4
    movss   xmm4, [rax+20]
    mulss   xmm4, xmm2
    addss   xmm3, xmm4
    movss   xmm4, xmm3
    andps   xmm4, [rip+hf_absm]
    comiss  xmm4, [rip+hf_tiny]
    jbe     8f
    movss   xmm11, [rip+hf_one]
    divss   xmm11, xmm3                 # inv
    movss   xmm4, [rbx+RAY_O]           # s = o - v0
    subss   xmm4, [rax]
    movss   xmm5, [rbx+RAY_O+4]
    subss   xmm5, [rax+4]
    movss   xmm6, [rbx+RAY_O+8]
    subss   xmm6, [rax+8]
    mulss   xmm0, xmm4                  # u
    mulss   xmm1, xmm5
    addss   xmm0, xmm1
    mulss   xmm2, xmm6
    addss   xmm0, xmm2
    mulss   xmm0, xmm11
    xorps   xmm7, xmm7
    comiss  xmm0, xmm7
    jb      8f
    comiss  xmm0, [rip+hf_one]
    ja      8f
    movss   xmm12, xmm0                 # (keep u)
    movss   xmm0, xmm5                  # q = s x e1
    mulss   xmm0, [rax+20]
    movss   xmm1, xmm6
    mulss   xmm1, [rax+16]
    subss   xmm0, xmm1
    movss   xmm1, xmm6
    mulss   xmm1, [rax+12]
    movss   xmm2, xmm4
    mulss   xmm2, [rax+20]
    subss   xmm1, xmm2
    movss   xmm2, xmm4
    mulss   xmm2, [rax+16]
    movss   xmm3, xmm5
    mulss   xmm3, [rax+12]
    subss   xmm2, xmm3
    movss   xmm13, xmm8                 # v = d . q
    mulss   xmm13, xmm0
    movss   xmm3, xmm9
    mulss   xmm3, xmm1
    addss   xmm13, xmm3
    movss   xmm3, xmm10
    mulss   xmm3, xmm2
    addss   xmm13, xmm3
    mulss   xmm13, xmm11
    comiss  xmm13, xmm7
    jb      8f
    movss   xmm3, xmm12
    addss   xmm3, xmm13
    comiss  xmm3, [rip+hf_one]
    ja      8f
    mulss   xmm0, [rax+24]              # t = e2 . q
    mulss   xmm1, [rax+28]
    addss   xmm0, xmm1
    mulss   xmm2, [rax+32]
    addss   xmm0, xmm2
    mulss   xmm0, xmm11
    comiss  xmm0, [rip+hf_eps_t]
    jbe     8f
    movss   xmm1, xmm12
    movss   xmm2, xmm13
    mov     eax, 1
    ret
8:  xor     eax, eax
    ret

.section .bss
.align 4
b_cmin_axis:    .skip 4
b_scale:        .skip 4

.section .note.GNU-stack,"",@progbits
