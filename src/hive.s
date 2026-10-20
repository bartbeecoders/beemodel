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
.globl hv_query
.globl hv_trace
.globl hv_occluded
.globl hv_n
.globl hv_ns
.globl hv_sp
.globl hv_tv
.globl hv_tn
.globl hv_tm
.globl hv_to
.globl hv_tuv
.globl hv_tvc
.globl hv_ncatch
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
.equ C_STACK,   0               # a BVH build context: its stack (node, start, end)
.equ C_TOP,     8               # 1: the top (children: to the frontier or tasks)
.equ C_PAR,     24              # 1: big nodes' passes over chunks in parallel
.equ C_SCALE,   12              # the bins: 16 / extent, the axis' minimum
.equ C_CMIN,    16
.equ C_NEXT,    20              # the next free BVH2 node (its own block)
.equ BN_MIN,    16              # a bin: count, its box's min and max (a
.equ BN_MAX,    32              #  vector each: min at +4 overlapped max.x,
.equ BN_SZ,     48              #  which kept the last primitive's)
.equ C_BINS,    64              # NBINS bins
.equ C_LR,      C_BINS+NBINS*BN_SZ  # sweep: left area, right area
.equ C_SZ,      C_LR+NBINS*8
.equ PB_SHIFT,  6
.equ PB_K,      1<<PB_SHIFT     # chunks of a big node's parallel passes
.equ BVH_PB_MIN, 65536          # a node this big at the top: its passes in parallel
.equ BVH_PAR_N, 32768           # fewer primitives: all on one thread
.equ BVH_CUT_MIN, 2048
.equ N2_SZ,     32              # BVH2 node: min[3] max[3] a b
.equ N4_SZ,     128             # BVH4 node: minx maxx miny maxy minz maxz [4] child[4]
.equ NBUF,      32
.equ MAX_POINTS, 64
.equ HV_SMAX,   16000000          # spheres the path tracer takes

.section .bss
hv_camuid:      .skip 4
.align 8
hv_ready:       .skip 4
hv_n:           .skip 4             # triangles
hv_ns:          .skip 4             # spheres (particles drawn as balls): their
hv_sp:          .skip 8             #  primitives follow the triangles' (hv_n + k);
hv_spk:         .skip 4             #  SP_SZ bytes each (const.inc), being filled
hv_build_ms:    .skip 8             # the last hive_build (ms: all of it, its BVH)
hv_bvh_ms:      .skip 8
hv_t0:          .skip 8
hv_t1:          .skip 8
hv_nmats:       .skip 4
hv_npoints:     .skip 4
.align 8
hv_tv:          .skip 8             # f32[n][9]  v0 e1 e2
hv_tn:          .skip 8             # f32[n][9]  corner normals
hv_tm:          .skip 8             # u32[n]     material (0 = default)
hv_to:          .skip 8             # f32[n][9]  object-space v0, e1, e2 (shader graphs)
hv_tuv:         .skip 8             # f32[n][6]  UVs (u0 NaN: none, box)
hv_tvc:         .skip 8             # u32[n][3]  vertex colours (0: none)
hv_ncatch:      .skip 4             # shadow-catcher objects (hv_tm | HV_CATCH)
hv_only:        .skip 8             # set: only this object (baking)
hv_ibud:        .skip 4             # instance triangles still allowed
hv_mats:        .skip 8             # material snapshots (MA_SZ bytes, 0 = default)
hv_cut:         .skip 4             # some material is masked, translucent or
                                    #  one-sided: rays test what they hit
hv_nodes:       .skip 8             # BVH4
hv_root:        .skip 4             # root reference
hv_nn4:         .skip 4
hv_cam:         .skip 64            # origin, right, up, forward, tan_h, flags
hv_points:      .skip MAX_POINTS*64 # light objects: 16 floats each - position,
                                    #  colour x power, type, size, direction (it
                                    #  shines along), a cone's / sun's cos, the
                                    #  area's half-edge axis, a spot's inner cos
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
b_cut:          .skip 4             # nodes under this many: tasks (0: none)
fr_n:           .skip 4             # the level's nodes
.align 8
fr_cur:         .skip 8             # (node, start, end) of this level
fr_next:        .skip 8             #  and the next
b_tasks:        .skip 8             # (node, start, end, its first node)
b_ctxs:         .skip 8             # C_SZ each: a thread's index + 1
pb_start:       .skip 4             # a big node's parallel passes
pb_end:         .skip 4
pb_axis:        .skip 4
pb_cmin:        .skip 4
pb_scale:       .skip 4
pb_split:       .skip 4
pb_mid:         .skip 4
.align 8
b_ptmp:         .skip 8             # u32[n]: big nodes' partitions
pb_off:         .skip PB_K*8        # a chunk's left and right places
ro_new:         .skip 7*8           # reorder_tris's new arrays
.align 64
b_topnext:      .skip 64            # the top's next node (atomic: a line each)
b_ntask:        .skip 64
fr_nn:          .skip 64            # the next level's nodes
b_ctx0:         .skip C_SZ          # the top's context
pb_part:        .skip PB_K*64       # a chunk's box and centroid box
pb_bins:        .skip PB_K*NBINS*BN_SZ  # a chunk's bins

.section .rodata
.align 4
hv_ptiny:       .float 1.0e-12
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
hf_sun_power:   .float 3.0                 # a sun: its irradiance at power 1
hf_halfk:       .float 0.5
hf_45:          .float 45.0
hf_inner:       .float 0.8
hf_d2r_half:    .float 0.0087266463        # degrees -> radians, halved
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
    xor     eax, eax                    # (nothing points at the freed pages:
    mov     [rip+hv_n], eax             #  an empty scene uploads zeros)
    mov     [rip+hv_nmats], eax
    mov     [rip+hv_nn4], eax
    mov     [rip+hv_tv], rax
    mov     [rip+hv_tn], rax
    mov     [rip+hv_tm], rax
    mov     [rip+hv_to], rax
    mov     [rip+hv_tuv], rax
    mov     [rip+hv_tvc], rax
    mov     [rip+hv_mats], rax
    mov     [rip+hv_nodes], rax
    mov     [rip+b_cent], rax
    mov     [rip+b_box], rax
    mov     [rip+b_prim], rax
    pop     rbx
    ret

# =============================================================================
#  hive_build -> eax = 1 (the scene as of now)
# =============================================================================
# hv_query(edi=k) -> eax (gpu(k)): 15 the last scene build's milliseconds,
#   16 its BVH's, 17 its triangles, 18 where the render is and why (HW_*)
hv_query:
    mov     eax, [rip+hv_build_ms]
    cmp     edi, 15
    je      9f
    mov     eax, [rip+hv_bvh_ms]
    cmp     edi, 16
    je      9f
    mov     eax, [rip+hv_n]
    cmp     edi, 17
    je      9f
    mov     eax, [rip+hv_why]
    cmp     edi, 18
    je      9f
    mov     eax, [rip+hv_ns]
    cmp     edi, 19
    je      9f
    xor     eax, eax
9:  ret

hive_build:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    push    rbp
    sub     rsp, 56
    call    now_ms
    mov     [rip+hv_t0], rax
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
2:  call    hv_part_count               # particles (particles.s): their
    add     r12d, eax                   #  triangles; hv_ns their balls
    mov     [rip+hv_n], r12d
    mov     dword ptr [rip+hv_spk], 0
    mov     eax, r12d
    add     eax, [rip+hv_ns]
    test    eax, eax
    jz      .Lhb_empty
    cmp     dword ptr [rip+hv_ns], 0    # the spheres' records
    je      21f
    imul    edi, [rip+hv_ns], SP_SZ
    add     edi, 64
    call    hv_map
    test    rax, rax
    jz      .Lhb_fail
    mov     [rip+hv_sp], rax
21:
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
    mov     eax, r12d                   # the build's: every primitive
    add     eax, [rip+hv_ns]
    mov     [rsp+16], eax
    imul    edi, eax, 12
    add     edi, 64
    call    hv_map
    test    rax, rax
    jz      .Lhb_fail
    mov     [rip+b_cent], rax
    imul    edi, [rsp+16], 24
    add     edi, 64
    call    hv_map
    test    rax, rax
    jz      .Lhb_fail
    mov     [rip+b_box], rax
    mov     edi, [rsp+16]
    lea     edi, [rdi*4+64]
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
    mov     dword ptr [rip+hv_ncatch], 0
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
    test    dword ptr [r14+OB_FLAGS], OBF_CATCH
    jz      2f
    or      eax, HV_CATCH               # (a shadow catcher's triangles)
    inc     dword ptr [rip+hv_ncatch]
2:  mov     [rsp+8], eax                # material + 1
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
.Lhb_lights:                            # light objects (16 floats each)
    call    hv_part_emit                # (the particles first)
    mov     dword ptr [rip+hv_npoints], 0
    xor     ebx, ebx
7:  cmp     ebx, [rip+obj_count]
    jae     .Lhb_bvh
    mov     edi, ebx
    call    obj_at
    cmp     dword ptr [rax+OB_TYPE], OT_LIGHT
    jne     71f
    test    dword ptr [rax+OB_FLAGS], OBF_HIDDEN|OBF_NORENDER
    jnz     71f
    mov     ecx, [rip+hv_npoints]
    cmp     ecx, MAX_POINTS
    jae     71f
    mov     rdi, rax
    shl     ecx, 6
    lea     rsi, [rip+hv_points]
    add     rsi, rcx
    call    hv_light
    inc     dword ptr [rip+hv_npoints]
71: inc     ebx
    jmp     7b
.Lhb_bvh:
    call    now_ms
    mov     [rip+hv_t1], rax
    call    build_bvh
    test    eax, eax
    jz      .Lhb_fail
    call    now_ms
    mov     rcx, rax
    sub     rax, [rip+hv_t1]
    mov     [rip+hv_bvh_ms], rax
    sub     rcx, [rip+hv_t0]
    mov     [rip+hv_build_ms], rcx
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

# hv_light(rdi=light object, rsi=its 16 floats) - where it is, how strong,
#   its type and shape (lcam.s), the way it shines (its -Z)
.globl hv_light
hv_light:
    push    rbx
    push    r12
    push    r13
    sub     rsp, 64
    mov     rbx, rdi
    mov     r12, rsi
    mov     rax, [rbx+OB_LOC]           # 0: the position
    mov     [r12], rax
    mov     eax, [rbx+OB_LOC+8]
    mov     [r12+8], eax
    mov     edi, [rbx+OB_UID]           # 3: colour x power (x the default)
    lea     rsi, [r12+12]
    call    lc_light
    mov     edi, [rbx+OB_UID]           # 6: type, 7: size, [rsp+48] the cone
    call    lc_shape
    mov     r13d, eax
    cvtsi2ss xmm2, eax
    movss   [r12+24], xmm2
    movss   [r12+28], xmm0
    movss   [rsp+48], xmm1
    movss   xmm0, [rip+hf_pt_power]     # (a point's strength; a sun's)
    cmp     r13d, 1
    jne     1f
    movss   xmm0, [rip+hf_sun_power]
1:  xor     ecx, ecx
2:  movss   xmm1, [r12+12+rcx*4]
    mulss   xmm1, xmm0
    movss   [r12+12+rcx*4], xmm1
    inc     ecx
    cmp     ecx, 3
    jb      2b
    mov     rdi, rbx                    # 8: the direction: -Z (the matrix's
    lea     rsi, [rsp]                  #  third column), 12: X for an area
    call    obj_matrix
    xor     ecx, ecx
3:  imul    edx, ecx, 16
    movss   xmm0, [rsp+rdx+8]
    xorps   xmm0, [rip+hf_signm]
    movss   [r12+32+rcx*4], xmm0
    movss   xmm0, [rsp+rdx]
    movss   [r12+48+rcx*4], xmm0
    inc     ecx
    cmp     ecx, 3
    jb      3b
    lea     rdi, [r12+32]
    call    hv_unit
    lea     rdi, [r12+48]
    call    hv_unit
    movss   xmm0, [r12+28]              # the area: X x half its edge (1 m: 0)
    xorps   xmm1, xmm1
    comiss  xmm0, xmm1
    ja      4f
    movss   xmm0, [rip+hf_one]
4:  mulss   xmm0, [rip+hf_halfk]
    xor     ecx, ecx
5:  movss   xmm1, [r12+48+rcx*4]
    mulss   xmm1, xmm0
    movss   [r12+48+rcx*4], xmm1
    inc     ecx
    cmp     ecx, 3
    jb      5b
    mov     dword ptr [r12+44], 0x3f800000   # 11: cos: the sun's half angle,
    mov     dword ptr [r12+60], 0x3f800000   #  a spot's outer, 15: inner
    cmp     r13d, 1
    jne     6f
    movss   xmm0, [r12+28]              # the sun: half its angle (deg)
    mulss   xmm0, [rip+hf_d2r_half]
    call    hv_cos
    movss   [r12+44], xmm0
    jmp     9f
6:  cmp     r13d, 2
    jne     9f
    movss   xmm0, [rsp+48]              # a spot: its cone (0: 45 deg)
    xorps   xmm1, xmm1
    comiss  xmm0, xmm1
    ja      61f
    movss   xmm0, [rip+hf_45]
61: mulss   xmm0, [rip+hf_d2r_half]
    movss   [rsp+52], xmm0
    call    hv_cos
    movss   [r12+44], xmm0
    movss   xmm0, [rsp+52]              # (soft: inner at 80% of it)
    mulss   xmm0, [rip+hf_inner]
    call    hv_cos
    movss   [r12+60], xmm0
9:  add     rsp, 64
    pop     r13
    pop     r12
    pop     rbx
    ret

hv_cos:                                 # xmm0 -> cos xmm0
    sub     rsp, 8
    movss   [rsp], xmm0
    fld     dword ptr [rsp]
    fcos
    fstp    dword ptr [rsp]
    movss   xmm0, [rsp]
    add     rsp, 8
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

# hv_part_count -> eax = the triangles the particles add (whole ones while
#   the instance budget lasts; hv_ibud spent); hv_ns = their balls (spheres,
#   up to HV_SMAX)
hv_part_count:
    push    rbx
    push    r12
    push    r13
    push    r14
    sub     rsp, 8
    xor     r13d, r13d
    mov     dword ptr [rip+hv_ns], 0
    xor     ebx, ebx
    cmp     qword ptr [rip+hv_only], 0  # (a bake of one object: none)
    jne     9f
1:  cmp     ebx, [rip+pt_ns]
    jae     9f
    mov     edi, ebx
    inc     ebx
    call    pt_render
    test    rax, rax
    jz      1b
    mov     r12, rax
    mov     rdi, rax
    call    inst_pids
    mov     r14, rax
    xor     ecx, ecx
2:  cmp     ecx, [r12+4]                # (IB_N)
    jae     1b
    movzx   eax, byte ptr [r14+rcx]
    mov     rdx, [r12+24+rax*8]         # (IB_PROTO)
    cmp     rdx, [rip+pt_sphere]        # a ball: a sphere (no triangles)
    jne     3f
    cmp     dword ptr [rip+hv_ns], HV_SMAX
    jae     9f
    inc     dword ptr [rip+hv_ns]
    inc     ecx
    jmp     2b
3:  mov     eax, [rdx+ME_NTRIS]
    cmp     eax, [rip+hv_ibud]
    ja      9f
    sub     [rip+hv_ibud], eax
    add     r13d, eax
    inc     ecx
    jmp     2b
9:  mov     eax, r13d
    add     rsp, 8
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# hv_part_emit (hive_build's r13 = the next global triangle, advanced) -
#   each particle system's instances (already in the world) as triangles,
#   tinted by each particle's colour; balls get round normals
hv_part_emit:
    push    rbx
    push    r12
    push    r14
    push    r15
    push    rbp
    sub     rsp, 128    # [0] system [8] colours [16] material [20] instance
                        # [24] first triangle [32] mark [40] its centre
    mov     dword ptr [rsp], 0
    cmp     qword ptr [rip+hv_only], 0  # (a bake of one object: none)
    jne     .Lpe_out
.Lpe_sys:
    mov     edi, [rsp]
    cmp     edi, [rip+pt_ns]
    jae     .Lpe_out
    inc     dword ptr [rsp]
    call    pt_render
    test    rax, rax
    jz      .Lpe_sys
    mov     r12, rax
    mov     [rsp+8], rdx
    mov     [rsp+16], ecx
    mov     dword ptr [rsp+20], 0
.Lpe_one:
    mov     ecx, [rsp+20]
    cmp     ecx, [r12+4]
    jae     .Lpe_sys
    mov     rdi, r12
    call    inst_pids
    mov     ecx, [rsp+20]
    movzx   eax, byte ptr [rax+rcx]
    mov     r15, [r12+24+rax*8]         # the prototype
    cmp     r15, [rip+pt_sphere]        # a ball: a sphere
    je      .Lpe_sph
    mov     eax, [r15+ME_NTRIS]
    cmp     eax, [rip+hv_ibud]
    ja      .Lpe_out
    sub     [rip+hv_ibud], eax
    imul    eax, ecx, 48                # its matrix (the world)
    lea     rbx, [r12+128+rax]          # (IB_DATA)
    mov     eax, [rbx+12]
    mov     [rsp+40], eax
    mov     eax, [rbx+28]
    mov     [rsp+44], eax
    mov     eax, [rbx+44]
    mov     [rsp+48], eax
    call    fa_mark
    mov     [rsp+32], rax
    lea     rdi, [rip+frame_arena]      # its points, placed
    mov     esi, [r15+ME_NVERTS]
    imul    esi, esi, 12
    add     esi, 16
    call    arena_alloc
    test    rax, rax
    jz      .Lpe_rel
    mov     rbp, rax
    xor     ecx, ecx
2:  cmp     ecx, [r15+ME_NVERTS]
    jae     3f
    imul    eax, ecx, 12
    mov     rdx, [r15+ME_POS]
    add     rdx, rax
    lea     rdi, [rbp+rax]
    xor     r8d, r8d
21: movss   xmm0, [rbx+r8]
    mulss   xmm0, [rdx]
    movss   xmm1, [rbx+r8+4]
    mulss   xmm1, [rdx+4]
    addss   xmm0, xmm1
    movss   xmm1, [rbx+r8+8]
    mulss   xmm1, [rdx+8]
    addss   xmm0, xmm1
    addss   xmm0, [rbx+r8+12]
    mov     eax, r8d
    shr     eax, 2
    movss   [rdi+rax], xmm0
    add     r8d, 16
    cmp     r8d, 48
    jb      21b
    inc     ecx
    jmp     2b
3:  mov     [rsp+24], r13d              # its triangles: material, colour
    xor     r14d, r14d
4:  cmp     r14d, [r15+ME_NTRIS]
    jae     5f
    mov     edi, r14d
    mov     esi, r13d
    call    put_tri
    mov     eax, [rsp+16]
    mov     rdx, [rip+hv_tm]
    mov     [rdx+r13*4], eax
    mov     rdx, [rsp+8]
    mov     ecx, [rsp+20]
    mov     eax, [rdx+rcx*4]
    imul    rdx, r13, 12
    add     rdx, [rip+hv_tvc]
    mov     [rdx], eax
    mov     [rdx+4], eax
    mov     [rdx+8], eax
    inc     r13d
    inc     r14d
    jmp     4b
5:  cmp     r15, [rip+pt_sphere]        # a ball: normals from its centre
    jne     7f
    mov     ecx, [rsp+24]
6:  cmp     ecx, r13d
    jae     .Lpe_rel
    mov     eax, ecx
    lea     rax, [rax+rax*8]
    mov     r8, [rip+hv_tv]
    lea     r8, [r8+rax*4]              # v0 e1 e2
    mov     r9, [rip+hv_tn]
    lea     r9, [r9+rax*4]
    xor     edx, edx
61: xor     r10d, r10d
62: movss   xmm0, [r8+r10*4]            # the corner, less the centre
    test    edx, edx
    jz      63f
    lea     eax, [rdx+rdx*2]
    add     eax, r10d
    addss   xmm0, [r8+rax*4]
63: subss   xmm0, [rsp+40+r10*4]
    movss   [rsp+56+r10*4], xmm0
    inc     r10d
    cmp     r10d, 3
    jb      62b
    movss   xmm0, [rsp+56]
    mulss   xmm0, xmm0
    movss   xmm1, [rsp+60]
    mulss   xmm1, xmm1
    addss   xmm0, xmm1
    movss   xmm1, [rsp+64]
    mulss   xmm1, xmm1
    addss   xmm0, xmm1
    sqrtss  xmm0, xmm0
    maxss   xmm0, [rip+hv_ptiny]
    lea     eax, [rdx+rdx*2]
    xor     r10d, r10d
64: movss   xmm1, [rsp+56+r10*4]
    divss   xmm1, xmm0
    lea     r11d, [rax+r10]
    movss   [r9+r11*4], xmm1
    inc     r10d
    cmp     r10d, 3
    jb      64b
    inc     edx
    cmp     edx, 3
    jb      61b
    inc     ecx
    jmp     6b
7:  mov     edi, [rsp+24]
    call    corner_normals
.Lpe_rel:
    mov     rdi, [rsp+32]
    call    fa_release
    inc     dword ptr [rsp+20]
    jmp     .Lpe_one
.Lpe_sph:                               # centre, radius (its matrix: the unit
    mov     eax, [rip+hv_spk]           #  ball scaled), material, colour
    cmp     eax, [rip+hv_ns]
    jae     .Lpe_skip
    inc     dword ptr [rip+hv_spk]
    mov     r8d, eax
    imul    rdx, r8, SP_SZ
    add     rdx, [rip+hv_sp]
    mov     ecx, [rsp+20]
    imul    eax, ecx, 48
    lea     rax, [r12+128+rax]          # (IB_DATA: 3 x 4, rows)
    mov     r9d, [rax+12]
    mov     [rdx+SP_C], r9d
    mov     r9d, [rax+28]
    mov     [rdx+SP_C+4], r9d
    mov     r9d, [rax+44]
    mov     [rdx+SP_C+8], r9d
    movss   xmm0, [rax]                 # |column 0|
    mulss   xmm0, xmm0
    movss   xmm1, [rax+16]
    mulss   xmm1, xmm1
    addss   xmm0, xmm1
    movss   xmm1, [rax+32]
    mulss   xmm1, xmm1
    addss   xmm0, xmm1
    sqrtss  xmm0, xmm0
    movss   [rdx+SP_R], xmm0
    mov     eax, [rsp+16]
    mov     [rdx+SP_MAT], eax
    xor     eax, eax
    mov     r9, [rsp+8]
    test    r9, r9
    jz      2f
    mov     eax, [r9+rcx*4]
2:  mov     [rdx+SP_COL], eax
    xor     eax, eax
    mov     [rdx+SP_VEL], rax
    mov     [rdx+SP_VEL+8], rax
    mov     [rdx+SP_VEL+16], rax
    mov     [rdx+SP_VEL+24], eax
    mov     eax, r8d                    # its box and centre (primitive hv_n + k)
    add     eax, [rip+hv_n]
    lea     r9, [rax+rax*2]
    mov     r10, [rip+b_cent]
    lea     r10, [r10+r9*4]
    mov     r11, [rip+b_box]
    lea     r11, [r11+r9*8]
    xor     ecx, ecx
1:  movss   xmm1, [rdx+SP_C+rcx*4]
    movss   [r10+rcx*4], xmm1
    movss   xmm2, xmm1
    subss   xmm2, xmm0
    movss   [r11+rcx*4], xmm2
    addss   xmm1, xmm0
    movss   [r11+12+rcx*4], xmm1
    inc     ecx
    cmp     ecx, 3
    jb      1b
.Lpe_skip:
    inc     dword ptr [rsp+20]
    jmp     .Lpe_one
.Lpe_out:
    add     rsp, 128
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
#  BVH build: binned SAH over centroids (BVH2), then collapse to 4-wide.
#  The top is built a level at a time: big nodes on this thread with their
#  bounds and bins over PB_K chunks in parallel, the rest of the level's
#  nodes on every thread at once. Nodes under b_cut primitives become tasks
#  that the workers build, each in its own context (bins, sweep, stack). A task
#  of c primitives gets a block of 2c - 2 nodes for its own (no shared
#  counter: an atomic one next to b_prim's line made more threads slower).
#  Each subtree partitions only its own range of b_prim, so the leaves are
#  the same on any number of threads
# =============================================================================
build_bvh:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    push    rbp
    sub     rsp, 24
    mov     ebx, [rip+hv_n]             # triangles, then spheres
    add     ebx, [rip+hv_ns]
    mov     rdi, [rip+b_prim]           # prims in order
    xor     ecx, ecx
1:  cmp     ecx, ebx
    jae     2f
    mov     [rdi+rcx*4], ecx
    inc     ecx
    jmp     1b
2:  lea     edi, [rbx*2+8]              # BVH2 nodes: at most 2n - 1
    shl     edi, 5
    call    hv_map
    test    rax, rax
    jz      .Lbb_fail
    mov     [rip+b_n2], rax
    lea     edi, [rbx*2+8]              # the top's stack: (node, start, end)
    imul    edi, edi, 12
    call    hv_map
    test    rax, rax
    jz      .Lbb_fail
    mov     [rip+b_stack], rax
    mov     dword ptr [rip+b_nn2], 1    # the root
    cmp     ebx, BVH_PB_MIN             # big nodes' partitions go through here
    jb      21f
    lea     edi, [rbx*4+64]
    call    hv_map
    test    rax, rax
    jz      .Lbb_fail
    mov     [rip+b_ptmp], rax
21:
    mov     dword ptr [rip+b_cut], 0
    mov     dword ptr [rip+b_ntask], 0
    mov     ecx, [rip+n_workers]        # the cut: n / (8 threads), 2048 at
    test    ecx, ecx                    #  least (none: one thread, or small)
    jz      5f
    cmp     ebx, BVH_PAR_N
    jb      5f
    inc     ecx
    shl     ecx, 3
    mov     eax, ebx
    xor     edx, edx
    div     ecx
    cmp     eax, BVH_CUT_MIN
    jae     22f
    mov     eax, BVH_CUT_MIN
22: cmp     eax, BVH_PB_MIN             # (big nodes only on this thread)
    jb      3f
    mov     eax, BVH_PB_MIN-1
3:  mov     [rip+b_cut], eax
    mov     ecx, eax                    # a level's nodes over the cut: n /
    mov     eax, ebx                    #  cut at most (disjoint)
    xor     edx, edx
    div     ecx
    lea     edi, [rax+16]
    imul    edi, edi, 12
    mov     [rsp+8], edi
    call    hv_map
    test    rax, rax
    jz      .Lbb_fail
    mov     [rip+fr_cur], rax
    mov     edi, [rsp+8]
    call    hv_map
    test    rax, rax
    jz      .Lbb_fail
    mov     [rip+fr_next], rax
    lea     edi, [rbx+16]               # tasks: one a primitive at most
    shl     edi, 4
    call    hv_map
    test    rax, rax
    jz      .Lbb_fail
    mov     [rip+b_tasks], rax
    mov     eax, [rip+n_workers]        # contexts: a thread's index + 1 (-1:
    add     eax, 2                      #  nested, inline), each a stack of
    mov     [rsp], eax                  #  2 cut + 16 entries
    imul    edi, eax, C_SZ
    add     edi, 64
    call    hv_map
    test    rax, rax
    jz      .Lbb_fail
    add     rax, 63
    and     rax, -64
    mov     [rip+b_ctxs], rax
    mov     eax, [rip+b_cut]
    lea     eax, [rax*2+16]
    imul    eax, eax, 12
    mov     [rsp+4], eax
    mov     edi, eax
    imul    edi, [rsp]
    call    hv_map
    test    rax, rax
    jz      .Lbb_fail
    mov     rdi, [rip+b_ctxs]
    mov     ecx, [rsp]
4:  mov     [rdi+C_STACK], rax
    mov     dword ptr [rdi+C_TOP], 0
    mov     dword ptr [rdi+C_PAR], 0
    mov     edx, [rsp+4]
    add     rax, rdx
    add     rdi, C_SZ
    dec     ecx
    jnz     4b
    mov     rax, [rip+fr_cur]           # the top: the root, a level at a time
    mov     dword ptr [rax], 0
    mov     dword ptr [rax+4], 0
    mov     [rax+8], ebx
    mov     dword ptr [rip+fr_n], 1
    mov     dword ptr [rip+b_topnext], 1
    lea     rdi, [rip+b_ctx0]
    mov     rax, [rip+b_stack]
    mov     [rdi+C_STACK], rax
    mov     dword ptr [rdi+C_TOP], 1
    mov     dword ptr [rdi+C_PAR], 1
.Lbb_level:
    cmp     dword ptr [rip+fr_n], 0
    je      .Lbb_top_done
    mov     dword ptr [rip+fr_nn], 0
    xor     ebp, ebp                    # big ones here, their passes in parallel
51: cmp     ebp, [rip+fr_n]
    jae     52f
    mov     rax, [rip+fr_cur]
    lea     rcx, [rbp+rbp*2]
    lea     rsi, [rax+rcx*4]
    mov     eax, [rsi+8]
    sub     eax, [rsi+4]
    cmp     eax, BVH_PB_MIN
    jb      53f
    lea     rdi, [rip+b_ctx0]
    mov     rdx, [rdi+C_STACK]
    mov     rax, [rsi]
    mov     [rdx], rax
    mov     eax, [rsi+8]
    mov     [rdx+8], eax
    mov     esi, 1
    call    bvh_loop
53: inc     ebp
    jmp     51b
52: lea     rdi, [rip+fr_job]           # the rest on every thread
    xor     esi, esi
    mov     edx, [rip+fr_n]
    mov     ecx, 1
    call    parallel_for
    mov     rax, [rip+fr_cur]           # the next level
    mov     rcx, [rip+fr_next]
    mov     [rip+fr_cur], rcx
    mov     [rip+fr_next], rax
    mov     eax, [rip+fr_nn]
    mov     [rip+fr_n], eax
    jmp     .Lbb_level
5:  lea     rdi, [rip+b_ctx0]           # (small, or one thread: all here)
    mov     rax, [rip+b_stack]
    mov     [rdi+C_STACK], rax
    mov     dword ptr [rdi+C_TOP], 0
    mov     dword ptr [rdi+C_PAR], 0
    mov     dword ptr [rdi+C_NEXT], 1   # (the root taken)
    mov     dword ptr [rax], 0
    mov     dword ptr [rax+4], 0
    mov     [rax+8], ebx
    mov     esi, 1
    call    bvh_loop
    mov     eax, [rip+b_ctx0+C_NEXT]
    mov     [rip+b_nn2], eax
    jmp     6f
.Lbb_top_done:
    mov     eax, [rip+b_topnext]        # (the nodes, the tasks' blocks too)
    mov     [rip+b_nn2], eax
    mov     edx, [rip+b_ntask]          # the subtrees, on every thread
    test    edx, edx
    jz      6f
    lea     rdi, [rip+bvh_task]
    xor     esi, esi
    mov     ecx, 1
    call    parallel_for
6:  call    collapse4
    test    eax, eax
    jz      .Lbb_fail
    call    reorder_tris
    mov     eax, 1
    jmp     9f
.Lbb_fail:
    xor     eax, eax
9:  add     rsp, 24
    pop     rbp
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# fr_job(esi=first, edx=end, ecx=thread index) - split those nodes of the
#   level (parallel_for's chunk; the big ones are done)
fr_job:
    push    rbx
    push    r12
    push    r13
    mov     ebx, esi
    mov     r13d, edx
    lea     eax, [rcx+1]
    imul    eax, eax, C_SZ
    mov     r12, [rip+b_ctxs]
    add     r12, rax
    mov     dword ptr [r12+C_TOP], 1
    mov     dword ptr [r12+C_PAR], 0
1:  cmp     ebx, r13d
    jae     9f
    mov     rax, [rip+fr_cur]
    lea     rcx, [rbx+rbx*2]
    lea     rsi, [rax+rcx*4]
    mov     eax, [rsi+8]
    sub     eax, [rsi+4]
    cmp     eax, BVH_PB_MIN
    jae     2f
    mov     rdi, [r12+C_STACK]
    mov     rax, [rsi]
    mov     [rdi], rax
    mov     eax, [rsi+8]
    mov     [rdi+8], eax
    mov     rdi, r12
    mov     esi, 1
    call    bvh_loop
2:  inc     ebx
    jmp     1b
9:  pop     r13
    pop     r12
    pop     rbx
    ret

# bvh_task(esi=first task, edx=end, ecx=thread index) - build those subtrees
#   (parallel_for's chunk: b_tasks entries, in the thread's context)
bvh_task:
    push    rbx
    push    r12
    push    r13
    mov     ebx, esi
    mov     r13d, edx
    lea     eax, [rcx+1]
    imul    eax, eax, C_SZ
    mov     r12, [rip+b_ctxs]
    add     r12, rax
    mov     dword ptr [r12+C_TOP], 0
    mov     dword ptr [r12+C_PAR], 0
1:  cmp     ebx, r13d
    jae     9f
    mov     rsi, rbx
    shl     rsi, 4
    add     rsi, [rip+b_tasks]
    mov     rdi, [r12+C_STACK]
    mov     rax, [rsi]
    mov     [rdi], rax
    mov     eax, [rsi+8]
    mov     [rdi+8], eax
    mov     eax, [rsi+12]               # its block of nodes
    mov     [r12+C_NEXT], eax
    mov     rdi, r12
    mov     esi, 1
    call    bvh_loop
    inc     ebx
    jmp     1b
9:  pop     r13
    pop     r12
    pop     rbx
    ret

# bvh_loop(rdi=context, esi=entries on its stack) - split until leaves; at
#   the top (C_TOP) one split, its children to the next level or, under
#   b_cut, to the tasks with their blocks of nodes (top_child). (bin_sweep
#   reads this frame: box at +0, centroid box at +32, count at +64)
bvh_loop:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    push    rbp
    sub     rsp, 104
    mov     r12, rdi
    mov     r13d, esi                   # stack depth
.Lbb_pop:
    test    r13d, r13d
    jz      .Lbb_done
    dec     r13d
    mov     rax, [r12+C_STACK]
    lea     rcx, [r13+r13*2]
    mov     ebx, [rax+rcx*4]            # node
    mov     r14d, [rax+rcx*4+4]         # start
    mov     r15d, [rax+rcx*4+8]         # end
    # bounds and centroid bounds
    mov     eax, r15d
    sub     eax, r14d
    cmp     eax, BVH_PB_MIN             # (a big node: in parallel; only the
    jb      31f                         #  top's context sees them)
    call    bvh_pbounds
    jmp     4f
31: movaps  xmm0, [rip+hf_inf]          # box min (x y z in lanes)
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
    test    ebx, ebx                    # the root, with triangles and spheres:
    jnz     43f                         #  split between them (each side's
    cmp     dword ptr [rip+hv_ns], 0    #  leaves are of one kind)
    je      43f
    mov     eax, [rip+hv_n]
    test    eax, eax
    jz      43f
    mov     [rsp+72], eax
    jmp     .Lbb_children
43:
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
    movss   xmm7, [rip+hf_nbins]        # scale = 16 / extent (a hair less)
    divss   xmm7, [rsp+68]
    movss   [rsp+76], xmm7
    movss   [r12+C_SCALE], xmm7
    mov     eax, [rsp+32+rbp*4]         # the axis' centroid minimum
    mov     [r12+C_CMIN], eax
    cmp     dword ptr [rsp+64], BVH_PB_MIN  # (a big node: in parallel)
    jb      50f
    call    bvh_pbins
    jmp     7f
50: lea     rdi, [r12+C_BINS]           # clear
    call    bins_clear
    mov     ecx, r14d
6:  cmp     ecx, r15d
    jae     7f
    mov     rax, [rip+b_prim]
    mov     eax, [rax+rcx*4]
    call    bin_of
    mov     edx, eax
    imul    edx, edx, BN_SZ
    lea     rdi, [r12+C_BINS]
    add     rdi, rdx
    inc     dword ptr [rdi]
    mov     rax, [rip+b_prim]
    mov     eax, [rax+rcx*4]
    mov     rdx, [rip+b_box]
    lea     r8, [rax+rax*2]
    lea     rdx, [rdx+r8*8]
    movups  xmm0, [rdi+BN_MIN]
    movups  xmm4, [rdx]
    minps   xmm0, xmm4
    movups  [rdi+BN_MIN], xmm0
    movups  xmm1, [rdi+BN_MAX]
    movups  xmm4, [rdx+12]
    maxps   xmm1, xmm4
    movups  [rdi+BN_MAX], xmm1
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
    cmp     dword ptr [rsp+64], BVH_PB_MIN  # a big node: a stable partition
    jb      72f                         #  in parallel (the same on any
    call    bvh_ppart                   #  number of threads)
    mov     r8d, eax
    jmp     81f
72: mov     r8d, r14d                   # partition by bin < split
    lea     r9d, [r15-1]
8:  cmp     r8d, r9d
    jg      81f
    mov     rdx, [rip+b_prim]
    mov     eax, [rdx+r8*4]
    call    bin_of
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
    cmp     dword ptr [r12+C_TOP], 0
    je      84f
    mov     eax, 2                      # the top: two new nodes (shared)
    lock xadd [rip+b_topnext], eax
    mov     rcx, [rip+b_n2]
    mov     edx, ebx
    shl     edx, 5
    mov     [rcx+rdx+24], eax
    mov     dword ptr [rcx+rdx+28], 0
    mov     [rsp+84], eax
    mov     edi, eax                    # left: start .. split
    mov     esi, r14d
    mov     edx, [rsp+72]
    call    top_child
    mov     edi, [rsp+84]               # right: split .. end
    inc     edi
    mov     esi, [rsp+72]
    mov     edx, r15d
    call    top_child
    jmp     .Lbb_pop
84: mov     eax, [r12+C_NEXT]           # two new nodes
    add     dword ptr [r12+C_NEXT], 2
    mov     rcx, [rip+b_n2]
    mov     edx, ebx
    shl     edx, 5
    mov     [rcx+rdx+24], eax           # left (right = left + 1)
    mov     dword ptr [rcx+rdx+28], 0
    mov     rcx, [r12+C_STACK]          # push both
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
.Lbb_done:
    add     rsp, 104
    pop     rbp
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# top_child(edi=node, esi=start, edx=end) - a child at the top: over b_cut
#   to the next level, else a task with its block of 2 count - 2 nodes
top_child:
    mov     eax, edx
    sub     eax, esi
    cmp     eax, [rip+b_cut]
    jbe     1f
    mov     ecx, 1
    lock xadd [rip+fr_nn], ecx
    mov     rax, [rip+fr_next]
    lea     rcx, [rcx+rcx*2]
    lea     rax, [rax+rcx*4]
    mov     [rax], edi
    mov     [rax+4], esi
    mov     [rax+8], edx
    ret
1:  lea     r8d, [rax*2-2]
    lock xadd [rip+b_topnext], r8d
    mov     ecx, 1
    lock xadd [rip+b_ntask], ecx
    shl     rcx, 4
    add     rcx, [rip+b_tasks]
    mov     [rcx], edi
    mov     [rcx+4], esi
    mov     [rcx+8], edx
    mov     [rcx+12], r8d
    ret

# bvh_ppart(eax=split bin; r14d / r15d, after bvh_pbins) -> eax = the first
#   primitive right of the split: a stable partition of the node's range of
#   b_prim, each chunk's places from its bins' counts, through b_ptmp
bvh_ppart:
    push    rbx
    mov     [rip+pb_split], eax
    lea     rsi, [rip+pb_bins]          # each chunk's left count
    lea     rdi, [rip+pb_off]
    xor     ecx, ecx
    xor     r9d, r9d                    # all the left
1:  xor     eax, eax
    xor     edx, edx
2:  cmp     edx, [rip+pb_split]
    jae     3f
    mov     r8d, edx
    imul    r8d, r8d, BN_SZ
    add     eax, [rsi+r8]
    inc     edx
    jmp     2b
3:  mov     [rdi+rcx*8], eax
    add     r9d, eax
    add     rsi, NBINS*BN_SZ
    inc     ecx
    cmp     ecx, PB_K
    jb      1b
    mov     r10d, r14d                  # the places: left from start, right
    lea     r11d, [r14+r9]              #  from start + all the left
    mov     [rip+pb_mid], r11d          # (the split)
    xor     ebx, ebx
4:  mov     edi, ebx
    call    pb_range
    lea     rsi, [rip+pb_off]
    mov     eax, [rsi+rbx*8]            # left count -> left place
    mov     [rsi+rbx*8], r10d
    add     r10d, eax
    sub     edx, ecx                    # right count -> right place
    sub     edx, eax
    mov     [rsi+rbx*8+4], r11d
    add     r11d, edx
    inc     ebx
    cmp     ebx, PB_K
    jb      4b
    lea     rdi, [rip+pb_part_job]
    xor     esi, esi
    mov     edx, PB_K
    mov     ecx, 1
    call    parallel_for
    lea     rdi, [rip+pb_back_job]
    xor     esi, esi
    mov     edx, PB_K
    mov     ecx, 1
    call    parallel_for
    mov     eax, [rip+pb_mid]
    pop     rbx
    ret

# pb_part_job(esi=first chunk, edx=end) - each chunk's primitives to their
#   places in b_ptmp (pb_off: left, right), in order
pb_part_job:
    push    rbx
    push    r12
    push    r13
    push    r14
    mov     ebx, esi
    mov     r12d, edx
1:  cmp     ebx, r12d
    jae     9f
    mov     edi, ebx
    call    pb_range
    lea     rax, [rip+pb_off]
    mov     r13d, [rax+rbx*8]           # left place
    mov     r14d, [rax+rbx*8+4]         # right place
    mov     r9, [rip+b_prim]
    mov     r11, [rip+b_cent]
    mov     rdi, [rip+b_ptmp]
    mov     esi, [rip+pb_axis]
    movss   xmm2, [rip+pb_cmin]
    movss   xmm3, [rip+pb_scale]
2:  cmp     ecx, edx
    jae     3f
    mov     r10d, [r9+rcx*4]
    lea     r8, [r10+r10*2]
    lea     rax, [r11+r8*4]
    movss   xmm0, [rax+rsi*4]           # (bin_of)
    subss   xmm0, xmm2
    mulss   xmm0, xmm3
    cvttss2si eax, xmm0
    test    eax, eax
    jns     4f
    xor     eax, eax
4:  cmp     eax, NBINS-1
    jbe     5f
    mov     eax, NBINS-1
5:  cmp     eax, [rip+pb_split]
    jae     6f
    mov     [rdi+r13*4], r10d
    inc     r13d
    jmp     7f
6:  mov     [rdi+r14*4], r10d
    inc     r14d
7:  inc     ecx
    jmp     2b
3:  inc     ebx
    jmp     1b
9:  pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# pb_back_job(esi=first chunk, edx=end) - b_ptmp's range back into b_prim
pb_back_job:
    push    rbx
    push    r12
    mov     ebx, esi
    mov     r12d, edx
1:  cmp     ebx, r12d
    jae     9f
    mov     edi, ebx
    call    pb_range
    mov     r9, [rip+b_prim]
    mov     r10, [rip+b_ptmp]
2:  cmp     ecx, edx
    jae     3f
    mov     eax, [r10+rcx*4]
    mov     [r9+rcx*4], eax
    inc     ecx
    jmp     2b
3:  inc     ebx
    jmp     1b
9:  pop     r12
    pop     rbx
    ret

# bins_clear(rdi=NBINS bins) - empty: count 0, boxes inside out
bins_clear:
    xor     ecx, ecx
1:  mov     dword ptr [rdi], 0
    movaps  xmm0, [rip+hf_inf]
    movups  [rdi+BN_MIN], xmm0
    movaps  xmm0, [rip+hf_ninf]
    movups  [rdi+BN_MAX], xmm0
    add     rdi, BN_SZ
    inc     ecx
    cmp     ecx, NBINS
    jb      1b
    ret

# bvh_pbounds(r14d=start, r15d=end) -> xmm0 / xmm1 the box, xmm2 / xmm3 the
#   centroids' box: PB_K chunks in parallel, merged
bvh_pbounds:
    sub     rsp, 8
    mov     [rip+pb_start], r14d
    mov     [rip+pb_end], r15d
    lea     rdi, [rip+pb_bounds_job]
    xor     esi, esi
    mov     edx, PB_K
    mov     ecx, 1
    call    parallel_for
    movaps  xmm0, [rip+hf_inf]
    movaps  xmm1, [rip+hf_ninf]
    movaps  xmm2, [rip+hf_inf]
    movaps  xmm3, [rip+hf_ninf]
    lea     rax, [rip+pb_part]
    xor     ecx, ecx
1:  minps   xmm0, [rax]
    maxps   xmm1, [rax+16]
    minps   xmm2, [rax+32]
    maxps   xmm3, [rax+48]
    add     rax, 64
    inc     ecx
    cmp     ecx, PB_K
    jb      1b
    add     rsp, 8
    ret

# pb_range(edi=chunk) -> ecx = its first primitive, edx = its end (pb_start
#   .. pb_end in PB_K parts)
pb_range:
    mov     r8d, [rip+pb_end]
    sub     r8d, [rip+pb_start]
    mov     eax, edi
    imul    rax, r8
    shr     rax, PB_SHIFT
    add     eax, [rip+pb_start]
    mov     ecx, eax
    lea     eax, [rdi+1]
    imul    rax, r8
    shr     rax, PB_SHIFT
    add     eax, [rip+pb_start]
    mov     edx, eax
    ret

# pb_bounds_job(esi=first chunk, edx=end) - each chunk's boxes into pb_part
pb_bounds_job:
    push    rbx
    push    r12
    mov     ebx, esi
    mov     r12d, edx
1:  cmp     ebx, r12d
    jae     9f
    mov     edi, ebx
    call    pb_range
    movaps  xmm0, [rip+hf_inf]
    movaps  xmm1, [rip+hf_ninf]
    movaps  xmm2, [rip+hf_inf]
    movaps  xmm3, [rip+hf_ninf]
    mov     r9, [rip+b_prim]
    mov     r10, [rip+b_box]
    mov     r11, [rip+b_cent]
2:  cmp     ecx, edx
    jae     3f
    mov     eax, [r9+rcx*4]
    lea     r8, [rax+rax*2]
    movups  xmm4, [r10+r8*8]
    minps   xmm0, xmm4
    movups  xmm4, [r10+r8*8+12]
    maxps   xmm1, xmm4
    movups  xmm4, [r11+r8*4]
    minps   xmm2, xmm4
    maxps   xmm3, xmm4
    inc     ecx
    jmp     2b
3:  mov     eax, ebx
    shl     eax, 6
    lea     rcx, [rip+pb_part]
    add     rcx, rax
    movaps  [rcx], xmm0
    movaps  [rcx+16], xmm1
    movaps  [rcx+32], xmm2
    movaps  [rcx+48], xmm3
    inc     ebx
    jmp     1b
9:  pop     r12
    pop     rbx
    ret

# bvh_pbins(r12=context, r14d=start, r15d=end, ebp=axis) - the context's bins
#   (C_SCALE, C_CMIN set): PB_K chunks' bins in parallel, merged
bvh_pbins:
    sub     rsp, 8
    mov     [rip+pb_start], r14d
    mov     [rip+pb_end], r15d
    mov     [rip+pb_axis], ebp
    mov     eax, [r12+C_SCALE]
    mov     [rip+pb_scale], eax
    mov     eax, [r12+C_CMIN]
    mov     [rip+pb_cmin], eax
    lea     rdi, [rip+pb_bins_job]
    xor     esi, esi
    mov     edx, PB_K
    mov     ecx, 1
    call    parallel_for
    lea     rdi, [r12+C_BINS]           # merged: counts, then min, then max
    call    bins_clear
    lea     rsi, [rip+pb_bins]
    xor     ecx, ecx
1:  lea     rdi, [r12+C_BINS]
    xor     edx, edx
2:  mov     eax, [rsi]
    add     [rdi], eax
    movups  xmm0, [rdi+BN_MIN]
    movups  xmm1, [rsi+BN_MIN]
    minps   xmm0, xmm1
    movups  [rdi+BN_MIN], xmm0
    movups  xmm0, [rdi+BN_MAX]
    movups  xmm1, [rsi+BN_MAX]
    maxps   xmm0, xmm1
    movups  [rdi+BN_MAX], xmm0
    add     rsi, BN_SZ
    add     rdi, BN_SZ
    inc     edx
    cmp     edx, NBINS
    jb      2b
    inc     ecx
    cmp     ecx, PB_K
    jb      1b
    add     rsp, 8
    ret

# pb_bins_job(esi=first chunk, edx=end) - each chunk's bins into pb_bins (as
#   bin_of: pb_axis, pb_cmin, pb_scale)
pb_bins_job:
    push    rbx
    push    r12
    push    r13
    mov     ebx, esi
    mov     r12d, edx
1:  cmp     ebx, r12d
    jae     9f
    mov     eax, ebx
    imul    eax, eax, NBINS*BN_SZ       # (a chunk's bins)
    lea     r13, [rip+pb_bins]
    add     r13, rax
    mov     rdi, r13
    call    bins_clear
    mov     edi, ebx
    call    pb_range
    mov     r9, [rip+b_prim]
    mov     r10, [rip+b_box]
    mov     r11, [rip+b_cent]
    mov     esi, [rip+pb_axis]
    movss   xmm2, [rip+pb_cmin]
    movss   xmm3, [rip+pb_scale]
2:  cmp     ecx, edx
    jae     3f
    mov     eax, [r9+rcx*4]
    lea     r8, [rax+rax*2]
    lea     rax, [r11+r8*4]
    movss   xmm0, [rax+rsi*4]
    subss   xmm0, xmm2
    mulss   xmm0, xmm3
    cvttss2si eax, xmm0
    test    eax, eax
    jns     4f
    xor     eax, eax
4:  cmp     eax, NBINS-1
    jbe     5f
    mov     eax, NBINS-1
5:  imul    eax, eax, BN_SZ
    lea     rdi, [r13+rax]
    inc     dword ptr [rdi]
    movups  xmm0, [rdi+BN_MIN]
    movups  xmm4, [r10+r8*8]
    minps   xmm0, xmm4
    movups  [rdi+BN_MIN], xmm0
    movups  xmm1, [rdi+BN_MAX]
    movups  xmm4, [r10+r8*8+12]
    maxps   xmm1, xmm4
    movups  [rdi+BN_MAX], xmm1
    inc     ecx
    jmp     2b
3:  inc     ebx
    jmp     1b
9:  pop     r13
    pop     r12
    pop     rbx
    ret

# bin_of(eax=prim; ebp = axis; r12 = context: C_CMIN, C_SCALE) -> eax = bin
bin_of:
    mov     rdx, [rip+b_cent]
    lea     r10, [rax+rax*2]
    lea     rdx, [rdx+r10*4]
    movss   xmm0, [rdx+rbp*4]
    movss   xmm1, [r12+C_CMIN]
    subss   xmm0, xmm1
    mulss   xmm0, [r12+C_SCALE]
    cvttss2si eax, xmm0
    test    eax, eax
    jns     1f
    xor     eax, eax
1:  cmp     eax, NBINS-1
    jbe     2f
    mov     eax, NBINS-1
2:  ret

# bin_sweep - (r12 = context; bvh_loop's [rsp+..] one level up: count at
#   +64) -> eax = the best split bin, or 0 when a leaf costs less
bin_sweep:
    push    rbx
    sub     rsp, 16
    # left: running box and count -> area * count at each split
    movaps  xmm0, [rip+hf_inf]
    movaps  xmm1, [rip+hf_ninf]
    xor     ecx, ecx
    xor     ebx, ebx                    # running count
    lea     rdi, [r12+C_BINS]
1:  cmp     ecx, NBINS-1
    jae     2f
    movups  xmm2, [rdi+BN_MIN]
    minps   xmm0, xmm2
    movups  xmm2, [rdi+BN_MAX]
    maxps   xmm1, xmm2
    add     ebx, [rdi]
    call    half_area                   # xmm0/xmm1 -> xmm4 (keeps both)
    cvtsi2ss xmm5, ebx
    mulss   xmm4, xmm5
    lea     rdx, [r12+C_LR]
    movss   [rdx+rcx*8], xmm4
    add     rdi, BN_SZ
    inc     ecx
    jmp     1b
2:  movaps  xmm0, [rip+hf_inf]          # right, from the end
    movaps  xmm1, [rip+hf_ninf]
    xor     ebx, ebx
    mov     ecx, NBINS-1
    lea     rdi, [r12+C_BINS+(NBINS-1)*BN_SZ]
3:  test    ecx, ecx
    jz      4f
    movups  xmm2, [rdi+BN_MIN]
    minps   xmm0, xmm2
    movups  xmm2, [rdi+BN_MAX]
    maxps   xmm1, xmm2
    add     ebx, [rdi]
    call    half_area
    cvtsi2ss xmm5, ebx
    mulss   xmm4, xmm5
    lea     rdx, [r12+C_LR]
    movss   [rdx+rcx*8-4], xmm4         # split at ecx: right part from bin ecx
    sub     rdi, BN_SZ
    dec     ecx
    jmp     3b
4:  movss   xmm6, [rip+hf_big]          # best = min over splits 1..15
    xor     eax, eax
    mov     ecx, 1
5:  cmp     ecx, NBINS
    jae     6f
    lea     rdx, [r12+C_LR]
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
#   them directly; the spheres' records too (b_prim from hv_n on)
reorder_tris:
    push    rbx
    push    r12
    push    r13
    mov     r12d, [rip+hv_n]
    lea     rbx, [rip+ro_new]           # the new arrays: positions, normals,
    imul    edi, r12d, 36               #  object space (shader graphs)
    add     edi, 64
    call    hv_map
    mov     [rbx], rax
    imul    edi, r12d, 36
    add     edi, 64
    call    hv_map
    mov     [rbx+8], rax
    imul    edi, r12d, 36
    add     edi, 64
    call    hv_map
    mov     [rbx+16], rax
    imul    edi, r12d, 24               # UVs, colours, materials
    add     edi, 64
    call    hv_map
    mov     [rbx+24], rax
    imul    edi, r12d, 12
    add     edi, 64
    call    hv_map
    mov     [rbx+32], rax
    lea     edi, [r12*4+64]
    call    hv_map
    mov     [rbx+40], rax
    mov     qword ptr [rbx+48], 0       # spheres
    mov     eax, [rip+hv_ns]
    test    eax, eax
    jz      1f
    imul    edi, eax, SP_SZ
    add     edi, 64
    call    hv_map
    mov     [rbx+48], rax
    test    rax, rax
    jz      9f
1:  xor     ecx, ecx                    # (any one missing: as they were)
2:  cmp     qword ptr [rbx+rcx*8], 0
    je      9f
    inc     ecx
    cmp     ecx, 6
    jb      2b
    lea     rdi, [rip+ro_job]           # every primitive, in parallel
    xor     esi, esi
    mov     edx, r12d
    add     edx, [rip+hv_ns]
    mov     ecx, 4096
    call    parallel_for
    mov     rax, [rbx]
    mov     [rip+hv_tv], rax
    mov     rax, [rbx+8]
    mov     [rip+hv_tn], rax
    mov     rax, [rbx+16]
    mov     [rip+hv_to], rax
    mov     rax, [rbx+24]
    mov     [rip+hv_tuv], rax
    mov     rax, [rbx+32]
    mov     [rip+hv_tvc], rax
    mov     rax, [rbx+40]
    mov     [rip+hv_tm], rax
    mov     rax, [rbx+48]
    test    rax, rax
    jz      9f
    mov     [rip+hv_sp], rax
9:  pop     r13
    pop     r12
    pop     rbx
    ret

# ro_job(esi=first, edx=end) - leaf position i takes primitive b_prim[i]'s
#   records (triangles: every per-triangle array; spheres: theirs)
ro_job:
    push    rbx
    push    r12
    lea     r12, [rip+ro_new]
    mov     r11d, [rip+hv_n]
    mov     r10, [rip+b_prim]
1:  cmp     esi, edx
    jae     9f
    mov     eax, [r10+rsi*4]
    cmp     esi, r11d
    jae     5f
    lea     r8, [rax+rax*8]             # 36 bytes: positions, normals, object
    lea     r9, [rsi+rsi*8]
    mov     rcx, [rip+hv_tv]
    mov     rbx, [r12]
    movups  xmm0, [rcx+r8*4]
    movups  xmm1, [rcx+r8*4+16]
    mov     ecx, [rcx+r8*4+32]
    movups  [rbx+r9*4], xmm0
    movups  [rbx+r9*4+16], xmm1
    mov     [rbx+r9*4+32], ecx
    mov     rcx, [rip+hv_tn]
    mov     rbx, [r12+8]
    movups  xmm0, [rcx+r8*4]
    movups  xmm1, [rcx+r8*4+16]
    mov     ecx, [rcx+r8*4+32]
    movups  [rbx+r9*4], xmm0
    movups  [rbx+r9*4+16], xmm1
    mov     [rbx+r9*4+32], ecx
    mov     rcx, [rip+hv_to]
    mov     rbx, [r12+16]
    movups  xmm0, [rcx+r8*4]
    movups  xmm1, [rcx+r8*4+16]
    mov     ecx, [rcx+r8*4+32]
    movups  [rbx+r9*4], xmm0
    movups  [rbx+r9*4+16], xmm1
    mov     [rbx+r9*4+32], ecx
    lea     r8, [rax+rax*2]             # 24 bytes: UVs
    lea     r9, [rsi+rsi*2]
    mov     rcx, [rip+hv_tuv]
    mov     rbx, [r12+24]
    movups  xmm0, [rcx+r8*8]
    mov     rcx, [rcx+r8*8+16]
    movups  [rbx+r9*8], xmm0
    mov     [rbx+r9*8+16], rcx
    mov     rcx, [rip+hv_tvc]           # 12 bytes: colours
    mov     rbx, [r12+32]
    mov     r8, [rcx+r8*4]
    mov     [rbx+r9*4], r8
    lea     r8, [rax+rax*2]
    mov     r8d, [rcx+r8*4+8]
    mov     [rbx+r9*4+8], r8d
    mov     rcx, [rip+hv_tm]            # the material
    mov     rbx, [r12+40]
    mov     ecx, [rcx+rax*4]
    mov     [rbx+rsi*4], ecx
    inc     esi
    jmp     1b
5:  sub     eax, r11d                   # a sphere: its 48 bytes
    imul    rax, rax, SP_SZ
    add     rax, [rip+hv_sp]
    mov     ecx, esi
    sub     ecx, r11d
    imul    rcx, rcx, SP_SZ
    add     rcx, [r12+48]
    movups  xmm0, [rax]
    movups  xmm1, [rax+16]
    movups  xmm2, [rax+32]
    movups  [rcx], xmm0
    movups  [rcx+16], xmm1
    movups  [rcx+32], xmm2
    inc     esi
    jmp     1b
9:  pop     r12
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
    mov     ecx, [rip+hv_n]
    add     ecx, [rip+hv_ns]
    test    ecx, ecx
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
    cmp     edi, [rip+hv_n]             # (a leaf of spheres)
    jae     72f
    call    tri_hit                     # xmm0 = t, xmm1 = u, xmm2 = v; eax
    jmp     73f
72: call    sph_hit
73:
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

# sph_hit(edi=primitive >= hv_n; rbx = ray) -> eax = 1 with xmm0 = t (the
#   nearer crossing past epsilon: from inside, the far one), xmm1 = xmm2 = 0.
#   From the closest approach (Ray Tracing Gems ch. 7): k = (oc . d) / d^2,
#   l = oc - k d, h = r^2 - l^2, t = -k -+ sqrt(h / d^2); b^2 - ac loses
#   most of its digits for small, far balls. pt.comp's sph_hit: the same steps
sph_hit:
    sub     edi, [rip+hv_n]
    imul    rax, rdi, SP_SZ
    add     rax, [rip+hv_sp]
    movss   xmm3, [rbx+RAY_O]           # oc = o - c
    subss   xmm3, [rax+SP_C]
    movss   xmm4, [rbx+RAY_O+4]
    subss   xmm4, [rax+SP_C+4]
    movss   xmm5, [rbx+RAY_O+8]
    subss   xmm5, [rax+SP_C+8]
    movss   xmm6, [rbx+RAY_D]           # a = d . d
    mulss   xmm6, xmm6
    movss   xmm7, [rbx+RAY_D+4]
    mulss   xmm7, xmm7
    addss   xmm6, xmm7
    movss   xmm7, [rbx+RAY_D+8]
    mulss   xmm7, xmm7
    addss   xmm6, xmm7
    comiss  xmm6, [rip+hf_tiny]
    jbe     8f
    movss   xmm9, [rip+hf_one]          # inv = 1 / a
    divss   xmm9, xmm6
    movss   xmm7, xmm3                  # b = oc . d
    mulss   xmm7, [rbx+RAY_D]
    movss   xmm8, xmm4
    mulss   xmm8, [rbx+RAY_D+4]
    addss   xmm7, xmm8
    movss   xmm8, xmm5
    mulss   xmm8, [rbx+RAY_D+8]
    addss   xmm7, xmm8
    mulss   xmm7, xmm9                  # k = b inv
    movss   xmm8, xmm7                  # l = oc - k d
    mulss   xmm8, [rbx+RAY_D]
    subss   xmm3, xmm8
    movss   xmm8, xmm7
    mulss   xmm8, [rbx+RAY_D+4]
    subss   xmm4, xmm8
    movss   xmm8, xmm7
    mulss   xmm8, [rbx+RAY_D+8]
    subss   xmm5, xmm8
    mulss   xmm3, xmm3                  # h = r^2 - l . l
    mulss   xmm4, xmm4
    addss   xmm3, xmm4
    mulss   xmm5, xmm5
    addss   xmm3, xmm5
    movss   xmm8, [rax+SP_R]
    mulss   xmm8, xmm8
    subss   xmm8, xmm3
    xorps   xmm3, xmm3
    comiss  xmm8, xmm3
    jb      8f
    mulss   xmm8, xmm9                  # s = sqrt(h inv)
    sqrtss  xmm8, xmm8
    movss   xmm0, xmm7                  # t = -(k + s), else s - k
    addss   xmm0, xmm8
    xorps   xmm0, [rip+hf_sign]
    comiss  xmm0, [rip+hf_eps_t]
    ja      1f
    movss   xmm0, xmm8
    subss   xmm0, xmm7
    comiss  xmm0, [rip+hf_eps_t]
    jbe     8f
1:  xorps   xmm1, xmm1
    xorps   xmm2, xmm2
    mov     eax, 1
    ret
8:  xor     eax, eax
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

.section .rodata
.align 16
hf_signm:       .long 0x80000000, 0, 0, 0

.section .note.GNU-stack,"",@progbits
