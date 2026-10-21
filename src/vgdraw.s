# =============================================================================
#  BeeModel - virtualized geometry, part 2: drawing cluster LOD DAGs.
#
#  Every frame, each mesh object whose mesh has a DAG (vgeo.s) is drawn
#  through a cut of it instead of its triangles:
#
#  1. cut      : from the roots down, a cluster's group is refined while its
#                error, projected from the camera, is over vd_px pixels (the
#                LOD spheres nest and errors grow up the DAG, so a group not
#                refined has no refined descendant). A group is expanded once
#                (a bit per group), and only when its LOD sphere is in the
#                frustum and its members' pages are in memory; otherwise the
#                clusters it made stand in (always crack-free: they are what
#                the members were simplified into). One object a job.
#  2. culling  : a cluster to draw is tested against the frustum (bounds
#                sphere), then against the depth pyramid of the last frame,
#                seen from the last frame's camera. Occluded ones wait.
#  3. drawing  : the chosen clusters are decoded into a mesh in the frame
#                arena (raster.s draws it as the object's mesh; one job per 64
#                clusters). After those triangles are rasterized, the depth
#                pyramid is built from this frame's depth and the clusters that
#                waited are tested again: the ones now visible are decoded too
#                and rasterized in a second batch (no holes when the view moves).
#  4. streaming: a DAG read from a .bee file stays mapped from it (vgeo_read).
#                Its cluster data is in 64 KiB pages: a page is asked for when
#                a group needs it (madvise WILLNEED: the kernel reads ahead),
#                counted in once mincore finds it all in memory, stamped with
#                the frame whenever it is used, and given back (MADV_DONTNEED)
#                least recently used first when the pages in memory and on
#                their way would pass the budget. The roots' pages stay.
# =============================================================================
.intel_syntax noprefix
.include "const.inc"
.include "macros.inc"
.include "vgeo.inc"

.globl vd_budget
.globl vd_px
.globl vgd_begin
.globl vgd_swap
.globl vgd_pass2
.globl vgd_extra
.globl vgd_inst
.globl vgd_n
.globl vd_forget
.globl vd_drop
.globl vgd_stat
.globl vd_view
.globl vd_streaming
.globl vd_poll

# one object drawn through its DAG this frame (frame arena)
.equ VI_OBJ,    0
.equ VI_DAG,    8
.equ VI_MESH,   16                      # the mesh it is drawn as
.equ VI_REC,    24                      # its raster record (batch 1)
.equ VI_C,      32                      # camera <- model, 3 x 4
.equ VI_P,      80                      # the depth pyramid's camera <- model
.equ VI_S,      128                     # f32: the model's largest scale
.equ VI_IDX,    132                     # object index
.equ VI_L1,     136                     # clusters drawn (u32)
.equ VI_L2,     144                     # clusters that waited (occluded)
.equ VI_N1,     152
.equ VI_N2,     156
.equ VI_NV,     160                     # the mesh's vertices / triangles
.equ VI_NT,     164
.equ VI_CV,     168                     #   room for them
.equ VI_CT,     172
.equ VI_V2,     176                     # the second batch's first vertex
.equ VI_T2,     180                     #   and triangle
.equ VI_FRU,    184                     # culled by the frustum
.equ VI_OCC,    188                     # occluded in the last frame
.equ VI_FALL,   192                     # refinements waiting for pages
.equ VI_KS,     196                     # f32: focal / pixels x scale
.equ VI_SZ,     208

.equ VD_POOLS,  65                      # per thread: the cut's lists
.equ VD_POOL_BYTES, 0x10000000          # 256 MiB reserved each (lazy)
.equ VD_RQ,     4096                    # page requests a frame
.equ VD_FL,     256                     # pages on their way
.equ VD_REG,    4096                    # streamed DAGs
.equ HZ_MAXL,   24
.equ MAP_NORES, 0x4022
.equ MADV_WILLNEED, 3
.equ MADV_DONTNEED, 4
.equ SYS_MINCORE, 27
.equ SYS_CLOCK_GETTIME, 228

.section .data
.align 8
vd_budget:      .quad 0x80000000        # 2 GiB of cluster data in memory
vd_px:          .float 1.0              # the error allowed, in pixels

.section .bss
.align 16
vd_planes:      .skip 64                # frustum sides (camera space, unit)
vd_cam:         .skip 48                # eye, right, up, fwd
hz_cam:         .skip 48                #   the depth pyramid's
vd_n:           .skip 4
vd_ofn:         .skip 4
vd_inst:        .skip 8
vd_of:          .skip 8                 # per object index: its record or 0
vd_frame:       .skip 4
vd_k:           .skip 4                 # focal / pixels
vd_view:        .skip 4                 # 1: clusters coloured, 2: off
vd_ck:          .skip 4                 # check the drawn cut for cracks
vd_extra:       .skip 4
vd_res:         .skip 8                 # bytes of pages in memory
vd_flb:         .skip 8                 #   on their way
vd_pool:        .skip 16*VD_POOLS       # base, used
vd_req:         .skip 16*VD_RQ          # dag, page
vd_nreq:        .skip 4
vd_nfl:         .skip 4
vd_fl:          .skip 16*VD_FL          # dag, page, frames waited
vd_reg:         .skip 8*VD_REG
vd_nreg:        .skip 4
vd_ents:        .skip 8                 # decode: instance, cluster, vbase, tbase
vd_nent:        .skip 4
vd_t0:          .skip 8
vd_ts:          .skip 16
hz_map:         .skip 8                 # the depth pyramid (levels 1 ..)
hz_cap:         .skip 8
hz_ok:          .skip 4
hz_nl:          .skip 4
hz_w:           .skip 4
hz_h:           .skip 4
hz_f:           .skip 4
hz_cx:          .skip 4
hz_cy:          .skip 4
hz_lw:          .skip 4*(HZ_MAXL+1)
hz_lh:          .skip 4*(HZ_MAXL+1)
hz_lo:          .skip 4*(HZ_MAXL+1)     # offset in floats
# statistics (vgstat)
vs_inst:        .skip 4
vs_cl:          .skip 4
vs_tri:         .skip 4
vs_fru:         .skip 4
vs_occ:         .skip 4
vs_cl2:         .skip 4
vs_fall:        .skip 4
vs_us:          .skip 4
vs_crack:       .skip 4
vs_src:         .skip 8
vs_reqs:        .skip 8
vs_evict:       .skip 8

.section .rodata
.align 16
f_one4:         .float 1.0, 1.0, 1.0, 1.0
f_absm:         .long 0x7fffffff, 0x7fffffff, 0x7fffffff, 0x7fffffff
f_one:          .float 1.0
f_tiny:         .float 1.0e-4
f_big:          .float 3.0e38
f_thousand:     .float 1000.0
f_mb:           .float 9.5367432e-7     # 1 / 2^20

.text

# =============================================================================
#  The frame
# =============================================================================
# vgd_begin - (raster_scene, after the canvas is known) the objects drawn
#   through their DAGs: cuts, culling, the first batch decoded
vgd_begin:
    push    rbx
    push    rbp
    push    r12
    push    r13
    push    r14
    push    r15
    sub     rsp, 72
    mov     dword ptr [rip+vd_n], 0
    mov     dword ptr [rip+vd_extra], 0
    lea     rdi, [rip+vs_inst]
    mov     ecx, 8
    xor     eax, eax
    rep     stosd
    mov     qword ptr [rip+vs_src], 0
    cmp     dword ptr [rip+vp_on], 0    # (paint modes: the mesh itself)
    jne     .Lvb_out
    cmp     dword ptr [rip+vd_view], 2  # (vgeo.view off)
    je      .Lvb_out
    mov     ecx, [rip+obj_count]
    test    ecx, ecx
    jz      .Lvb_out
    mov     [rip+vd_ofn], ecx
    lea     rdi, [rip+frame_arena]
    lea     rsi, [rcx*8]
    call    arena_alloc
    test    rax, rax
    jz      .Lvb_out
    mov     [rip+vd_of], rax
    mov     rdi, rax
    mov     ecx, [rip+vd_ofn]
    xor     eax, eax
    rep     stosq
    lea     rdi, [rip+frame_arena]
    imul    esi, [rip+vd_ofn], VI_SZ
    call    arena_alloc
    test    rax, rax
    jz      .Lvb_none
    mov     [rip+vd_inst], rax
    call    now_us
    mov     [rip+vd_t0], rax
    inc     dword ptr [rip+vd_frame]
    call    vd_setup
    xor     ebx, ebx                    # objects with a DAG
.Lvb_scan:
    cmp     ebx, [rip+obj_count]
    jae     .Lvb_scanned
    mov     edi, ebx
    call    obj_at
    mov     r12, rax
    cmp     dword ptr [r12+OB_TYPE], OT_MESH
    jne     .Lvb_next
    test    dword ptr [r12+OB_FLAGS], OBF_HIDDEN
    jnz     .Lvb_next
    lea     rcx, [rip+obj_list]         # (the sculpt and edit objects: as
    mov     ecx, [rcx+rbx*4]            #  they are)
    cmp     ecx, [rip+sc_obj]
    je      .Lvb_next
    cmp     r12, [rip+edit_ro_obj]
    je      .Lvb_next
    mov     rdi, r12                    # (a liquid's surface: never a DAG,
    call    pt_field                    #  not meshed for it)
    test    rax, rax
    jnz     .Lvb_next
    mov     rdi, r12
    call    obj_eval
    test    rax, rax
    jz      .Lvb_next
    cmp     qword ptr [rax+ME_VCOL], 0  # (vertex colours: the mesh)
    jne     .Lvb_next
    mov     rdi, rax
    call    vg_live
    test    rax, rax
    jz      .Lvb_next
    mov     r13, rax
    mov     rdi, rax
    call    vd_prep
    test    eax, eax
    jz      .Lvb_next
    imul    r14d, [rip+vd_n], VI_SZ
    add     r14, [rip+vd_inst]
    mov     rdi, r14
    mov     ecx, VI_SZ/8
    xor     eax, eax
    rep     stosq
    mov     [r14+VI_OBJ], r12
    mov     [r14+VI_DAG], r13
    mov     [r14+VI_IDX], ebx
    mov     rdi, r14
    call    vd_mats
    mov     rax, [rip+vd_of]
    mov     [rax+rbx*8], r14
    inc     dword ptr [rip+vd_n]
    mov     eax, [r13+VH_STRI]
    add     [rip+vs_src], rax
.Lvb_next:
    inc     ebx
    jmp     .Lvb_scan
.Lvb_scanned:
    mov     eax, [rip+vd_n]
    mov     [rip+vs_inst], eax
    test    eax, eax
    jz      .Lvb_none
    call    vd_tick_in                  # pages that came in
    lea     rdi, [rip+vd_pool]          # the lists start again
    mov     ecx, VD_POOLS
1:  mov     qword ptr [rdi+8], 0
    add     rdi, 16
    dec     ecx
    jnz     1b
    mov     dword ptr [rip+vd_nreq], 0
    lea     rdi, [rip+job_cut]
    xor     esi, esi
    mov     edx, [rip+vd_n]
    mov     ecx, 1
    call    parallel_for
    call    vd_tick_out                 # pages asked for, the budget kept
    xor     ebx, ebx                    # the meshes they are drawn as
.Lvb_mesh:
    cmp     ebx, [rip+vd_n]
    jae     .Lvb_meshed
    imul    r14d, ebx, VI_SZ
    add     r14, [rip+vd_inst]
    lea     rdi, [rip+frame_arena]
    mov     esi, [r14+VI_CV]
    imul    esi, esi, 12
    mov     eax, [r14+VI_CT]
    imul    eax, eax, 12
    add     esi, eax
    cmp     dword ptr [rip+vd_view], 1
    jne     2f
    mov     eax, [r14+VI_CV]
    lea     esi, [rsi+rax*4+16]
2:  add     esi, ME_HDR+48
    mov     r15d, esi
    call    arena_alloc
    test    rax, rax
    jz      .Lvb_nomem
    mov     r12, rax
    mov     rdi, rax
    mov     ecx, ME_HDR/8
    xor     eax, eax
    rep     stosq
    lea     rax, [r12+ME_HDR]
    mov     [r12+ME_POS], rax
    mov     ecx, [r14+VI_CV]
    imul    ecx, ecx, 12
    lea     rax, [rax+rcx+15]
    and     rax, -16
    mov     [r12+ME_TRIS], rax
    cmp     dword ptr [rip+vd_view], 1
    jne     3f
    mov     ecx, [r14+VI_CT]
    imul    ecx, ecx, 12
    lea     rax, [rax+rcx+15]
    and     rax, -16
    mov     [r12+ME_VCOL], rax
3:  mov     eax, [r14+VI_NV]
    mov     [r12+ME_NVERTS], eax
    mov     eax, [r14+VI_NT]
    mov     [r12+ME_NTRIS], eax
    mov     eax, [r14+VI_CV]
    mov     [r12+ME_CAPV], eax
    mov     dword ptr [r12+ME_REFS], 1
    mov     [r14+VI_MESH], r12
    mov     eax, [r14+VI_CT]
    sub     eax, [r14+VI_NT]
    add     [rip+vd_extra], eax
    inc     ebx
    jmp     .Lvb_mesh
.Lvb_nomem:                             # (no room: drawn as nothing)
    mov     rax, [rip+vd_of]
    mov     ecx, [r14+VI_IDX]
    mov     qword ptr [rax+rcx*8], 0
    mov     dword ptr [r14+VI_N1], 0
    mov     dword ptr [r14+VI_N2], 0
    mov     dword ptr [r14+VI_CT], 0
    mov     dword ptr [r14+VI_NT], 0
    inc     ebx
    jmp     .Lvb_mesh
.Lvb_meshed:
    xor     edi, edi                    # the first batch's clusters
    call    vd_decode
    call    now_us
    sub     rax, [rip+vd_t0]
    mov     [rip+vs_us], eax
    jmp     .Lvb_out
.Lvb_none:
    mov     dword ptr [rip+vd_n], 0
.Lvb_out:
    add     rsp, 72
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbp
    pop     rbx
    ret

# vgd_swap(rdi=mesh, esi=object index) -> rax = the mesh to draw (the DAG's
#   cut when the object has one this frame), rdx = its record or 0
vgd_swap:
    mov     rax, rdi
    xor     edx, edx
    cmp     dword ptr [rip+vd_n], 0
    je      9f
    cmp     esi, [rip+vd_ofn]
    jae     9f
    mov     rcx, [rip+vd_of]
    mov     rcx, [rcx+rsi*8]
    test    rcx, rcx
    jz      9f
    mov     rdx, rcx
    mov     rax, [rcx+VI_MESH]
9:  ret

# vgd_extra -> eax = triangles the second batch may add
vgd_extra:
    xor     eax, eax
    cmp     dword ptr [rip+vd_n], 0
    je      1f
    mov     eax, [rip+vd_extra]
1:  ret

# vgd_n -> eax = objects drawn through DAGs; vgd_inst(edi) -> rax = record
vgd_n:
    mov     eax, [rip+vd_n]
    ret
vgd_inst:
    imul    eax, edi, VI_SZ
    add     rax, [rip+vd_inst]
    ret

# vgd_pass2 -> eax = objects with more triangles: the depth pyramid from
#   this frame's depth (also the next frame's occluders), the clusters that
#   waited tested against it, the visible ones decoded after the first batch
vgd_pass2:
    push    rbx
    push    r12
    sub     rsp, 8
    xor     r12d, r12d
    cmp     dword ptr [rip+vd_n], 0
    je      9f
    call    hz_build
    xor     ebx, ebx                    # anything waiting?
    xor     eax, eax
1:  cmp     ebx, [rip+vd_n]
    jae     2f
    mov     edi, ebx
    call    vgd_inst
    add     eax, [rax+VI_N2]
    inc     ebx
    jmp     1b
2:  push    rax
    sub     rsp, 8
    call    vd_crack                    # (vgeo.view check)
    add     rsp, 8
    pop     rax
    test    eax, eax
    jz      5f
    lea     rdi, [rip+job_occ2]
    xor     esi, esi
    mov     edx, [rip+vd_n]
    mov     ecx, 1
    call    parallel_for
    mov     edi, 1
    call    vd_decode
5:  xor     ebx, ebx                    # the meshes' counts; the statistics
3:  cmp     ebx, [rip+vd_n]
    jae     9f
    mov     edi, ebx
    call    vgd_inst
    mov     rcx, [rax+VI_MESH]
    test    rcx, rcx
    jz      4f
    mov     edx, [rax+VI_NV]
    mov     [rcx+ME_NVERTS], edx
    mov     edx, [rax+VI_NT]
    mov     [rcx+ME_NTRIS], edx
    add     [rip+vs_tri], edx
    mov     edx, [rax+VI_N1]
    add     edx, [rax+VI_N2]
    add     [rip+vs_cl], edx
    mov     edx, [rax+VI_N2]
    add     [rip+vs_cl2], edx
    mov     edx, [rax+VI_NT]
    cmp     edx, [rax+VI_T2]
    jbe     4f
    inc     r12d
4:  inc     ebx
    jmp     3b
9:  mov     eax, r12d
    add     rsp, 8
    pop     r12
    pop     rbx
    ret

# vd_crack - (vgeo.view check) the first object's cut as drawn, the waiting
#   clusters with it, against its level 0: vs_crack = 1 when the sums of
#   their directed edges agree (no crack), 0 when not, -1 when the frustum
#   took clusters away (no answer)
vd_crack:
    mov     dword ptr [rip+vs_crack], -1
    cmp     dword ptr [rip+vd_ck], 0
    je      9f
    push    rbx
    push    r12
    push    r13
    mov     rbx, [rip+vd_inst]
    mov     dword ptr [rip+vs_crack], -1
    cmp     dword ptr [rbx+VI_FRU], 0
    jne     8f
    cmp     qword ptr [rbx+VI_MESH], 0
    je      8f
    mov     r12, [rbx+VI_DAG]
    lea     rdi, [rip+frame_arena]
    mov     esi, [r12+VH_NCL]
    call    arena_alloc
    test    rax, rax
    jz      8f
    mov     r13, rax
    mov     rdi, rax
    mov     ecx, [r12+VH_NCL]
    xor     eax, eax
    rep     stosb
    mov     rsi, [rbx+VI_L1]
    mov     ecx, [rbx+VI_N1]
1:  dec     ecx
    js      2f
    mov     eax, [rsi+rcx*4]
    mov     byte ptr [r13+rax], 1
    jmp     1b
2:  mov     rsi, [rbx+VI_L2]
    mov     ecx, [rbx+VI_N2]
3:  dec     ecx
    js      4f
    mov     eax, [rsi+rcx*4]
    mov     byte ptr [r13+rax], 1
    jmp     3b
4:  mov     rdi, r12
    mov     rsi, r13
    call    vg_edges
    mov     rbx, rax
    lea     rcx, [r12+VH_SZ]            # level 0
    xor     edx, edx
5:  cmp     edx, [r12+VH_NCL]
    jae     6f
    cmp     byte ptr [rcx+CR_LEVEL], 0
    sete    byte ptr [r13+rdx]
    add     rcx, CR_SZ
    inc     edx
    jmp     5b
6:  mov     rdi, r12
    mov     rsi, r13
    call    vg_edges
    xor     ecx, ecx
    cmp     rax, rbx
    sete    cl
    mov     [rip+vs_crack], ecx
8:  pop     r13
    pop     r12
    pop     rbx
9:  ret

# vd_setup - this frame's camera: the frustum's sides, focal / pixels
vd_setup:
    lea     rax, [rip+vd_cam]
    mov     rcx, [rip+eye]
    mov     [rax], rcx
    mov     ecx, [rip+eye+8]
    mov     [rax+8], ecx
    mov     rcx, [rip+right]
    mov     [rax+12], rcx
    mov     ecx, [rip+right+8]
    mov     [rax+20], ecx
    mov     rcx, [rip+up]
    mov     [rax+24], rcx
    mov     ecx, [rip+up+8]
    mov     [rax+32], ecx
    mov     rcx, [rip+fwd]
    mov     [rax+36], rcx
    mov     ecx, [rip+fwd+8]
    mov     [rax+44], ecx
    movss   xmm0, [rip+vp_focal]
    movss   xmm1, [rip+vd_px]
    maxss   xmm1, [rip+f_tiny]
    divss   xmm0, xmm1
    movss   [rip+vd_k], xmm0
    # x / z in [al, ar], y / z in [ab, at] (canvas-relative centre)
    movss   xmm4, [rip+vp_focal]
    movss   xmm0, [rip+vp_cx]
    cvtsi2ss xmm1, dword ptr [rip+rs_x0]
    subss   xmm0, xmm1                  # cx
    movss   xmm1, [rip+vp_cy]
    cvtsi2ss xmm2, dword ptr [rip+rs_y0]
    subss   xmm1, xmm2                  # cy
    xorps   xmm2, xmm2
    subss   xmm2, xmm0
    divss   xmm2, xmm4                  # al = -cx / f
    lea     rdi, [rip+vd_planes]
    mov     eax, 0x3f800000             # left: (1, 0, -al)
    xorps   xmm3, xmm3
    subss   xmm3, xmm2
    mov     edx, 0
    call    vd_plane
    cvtsi2ss xmm2, dword ptr [rip+rs_w]
    subss   xmm2, xmm0
    divss   xmm2, xmm4                  # ar = (w - cx) / f: (-1, 0, ar)
    movss   xmm3, xmm2
    mov     eax, 0xbf800000
    add     rdi, 16
    mov     edx, 0
    call    vd_plane
    movss   xmm2, xmm1
    cvtsi2ss xmm5, dword ptr [rip+rs_h]
    subss   xmm2, xmm5
    divss   xmm2, xmm4                  # ab = (cy - h) / f: (0, 1, -ab)
    xorps   xmm3, xmm3
    subss   xmm3, xmm2
    xor     eax, eax
    add     rdi, 16
    mov     edx, 0x3f800000
    call    vd_plane
    movss   xmm3, xmm1
    divss   xmm3, xmm4                  # at = cy / f: (0, -1, at)
    xor     eax, eax
    add     rdi, 16
    mov     edx, 0xbf800000
    call    vd_plane
    ret
# vd_plane(rdi=out, eax=x, edx=y (f32 bits), xmm3=z) - normalized
vd_plane:
    movd    xmm5, eax
    movd    xmm6, edx
    unpcklps xmm5, xmm6
    movlhps xmm5, xmm3                  # x y z 0
    movaps  xmm6, xmm5
    dpps    xmm6, xmm6, 0x7f
    sqrtps  xmm6, xmm6
    divps   xmm5, xmm6
    andps   xmm5, [rip+f_xyz]
    movaps  [rdi], xmm5
    ret
.section .rodata
.align 16
f_xyz:          .long -1, -1, -1, 0
.text

# vd_mats(rdi=record) - camera <- model (and from the depth pyramid's camera),
#   the largest scale
vd_mats:
    push    rbx
    sub     rsp, 48
    mov     rbx, rdi
    mov     rdi, [rbx+VI_OBJ]
    mov     rsi, rsp
    call    obj_matrix
    mov     rdi, rsp
    lea     rsi, [rip+vd_cam]
    lea     rdx, [rbx+VI_C]
    call    basis_mat
    cmp     dword ptr [rip+hz_ok], 0
    je      1f
    mov     rdi, rsp
    lea     rsi, [rip+hz_cam]
    lea     rdx, [rbx+VI_P]
    call    basis_mat
1:  movups  xmm0, [rsp]                 # column norms
    mulps   xmm0, xmm0
    movups  xmm1, [rsp+16]
    mulps   xmm1, xmm1
    addps   xmm0, xmm1
    movups  xmm1, [rsp+32]
    mulps   xmm1, xmm1
    addps   xmm0, xmm1
    movaps  xmm1, xmm0
    shufps  xmm1, xmm1, 0x55
    maxss   xmm0, xmm1
    movhlps xmm1, xmm1
    maxss   xmm0, xmm1
    sqrtss  xmm0, xmm0
    movss   [rbx+VI_S], xmm0
    mulss   xmm0, [rip+vd_k]
    movss   [rbx+VI_KS], xmm0
    add     rsp, 48
    pop     rbx
    ret

# basis_mat(rdi=model 3 x 4, rsi=camera (eye, right, up, fwd), rdx=out 3 x 4):
#   out row r = basis_r . (M - eye)
basis_mat:
    movups  xmm0, [rdi]
    movups  xmm1, [rdi+16]
    movups  xmm2, [rdi+32]
    mov     ecx, 3
    lea     r8, [rsi+12]
1:  movss   xmm3, [r8]
    shufps  xmm3, xmm3, 0
    mulps   xmm3, xmm0
    movss   xmm4, [r8+4]
    shufps  xmm4, xmm4, 0
    mulps   xmm4, xmm1
    addps   xmm3, xmm4
    movss   xmm4, [r8+8]
    shufps  xmm4, xmm4, 0
    mulps   xmm4, xmm2
    addps   xmm3, xmm4
    movss   xmm4, [r8]                  # basis . eye
    mulss   xmm4, [rsi]
    movss   xmm5, [r8+4]
    mulss   xmm5, [rsi+4]
    addss   xmm4, xmm5
    movss   xmm5, [r8+8]
    mulss   xmm5, [rsi+8]
    addss   xmm4, xmm5
    movaps  xmm5, xmm3
    shufps  xmm5, xmm5, 0xff
    subss   xmm5, xmm4
    insertps xmm3, xmm5, 0x30
    movaps  [rdx], xmm3
    add     r8, 12
    add     rdx, 16
    dec     ecx
    jnz     1b
    ret

# sph_cam(rdi=sphere (x y z r), rsi=3 x 4 matrix, xmm7=scale) -> xmm0 = the
#   sphere in camera space (x y z r); xmm1 - xmm3 clobbered
sph_cam:
    movups  xmm1, [rdi]
    movaps  xmm3, xmm1
    shufps  xmm3, xmm3, 0xff
    mulss   xmm3, xmm7
    insertps xmm1, [rip+f_one], 0x30
    movaps  xmm0, xmm1
    dpps    xmm0, [rsi], 0xf1
    movaps  xmm2, xmm1
    dpps    xmm2, [rsi+16], 0xf2
    orps    xmm0, xmm2
    movaps  xmm2, xmm1
    dpps    xmm2, [rsi+32], 0xf4
    orps    xmm0, xmm2
    insertps xmm0, xmm3, 0x30
    ret

# frustum(xmm0=sphere in camera space) -> eax = 1 when outside
frustum:
    movaps  xmm1, xmm0
    shufps  xmm1, xmm1, 0xff            # r
    movaps  xmm2, xmm0
    shufps  xmm2, xmm2, 0xaa
    addss   xmm2, xmm1                  # z + r < near: behind
    comiss  xmm2, [rip+f_near]
    jb      8f
    xorps   xmm3, xmm3
    subss   xmm3, xmm1                  # -r
    movaps  xmm2, xmm0
    dpps    xmm2, [rip+vd_planes], 0x71
    comiss  xmm2, xmm3
    jb      8f
    movaps  xmm2, xmm0
    dpps    xmm2, [rip+vd_planes+16], 0x71
    comiss  xmm2, xmm3
    jb      8f
    movaps  xmm2, xmm0
    dpps    xmm2, [rip+vd_planes+32], 0x71
    comiss  xmm2, xmm3
    jb      8f
    movaps  xmm2, xmm0
    dpps    xmm2, [rip+vd_planes+48], 0x71
    comiss  xmm2, xmm3
    jb      8f
    xor     eax, eax
    ret
8:  mov     eax, 1
    ret

# =============================================================================
#  The cut (one object a job)
# =============================================================================
.equ JC_I,      0
.equ JC_END,    4
.equ JC_THR,    8
.equ JC_AR,     16
.equ JC_CRE,    24                      # creators
.equ JC_ST,     32                      # page states (0: not streamed)
.equ JC_STAMP,  40
.equ JC_L1,     48
.equ JC_L2,     56
.equ JC_N1,     64
.equ JC_N2,     68
.equ JC_NV1,    72
.equ JC_NT1,    76
.equ JC_NVC,    80
.equ JC_NTC,    84
.equ JC_FRU,    88
.equ JC_OCC,    92
.equ JC_FALL,   96
.equ JC_C,      100                     # the cluster
.equ JC_GR,     104                     # groups
.equ JC_MEM,    112                     # members
.equ JC_VIS,    120                     # a bit per group
.equ JC_SZ,     168
# job_cut(ctx, esi=first object, edx=end, ecx=thread, r8=scratch arena)
job_cut:
    push    rbx
    push    rbp
    push    r12
    push    r13
    push    r14
    push    r15
    sub     rsp, JC_SZ
    mov     [rsp+JC_I], esi
    mov     [rsp+JC_END], edx
    test    ecx, ecx
    jns     1f
    mov     ecx, VD_POOLS-1
1:  cmp     ecx, VD_POOLS-1
    jbe     2f
    mov     ecx, VD_POOLS-1
2:  mov     [rsp+JC_THR], ecx
    mov     [rsp+JC_AR], r8
.Ljc_inst:
    mov     eax, [rsp+JC_I]
    cmp     eax, [rsp+JC_END]
    jae     .Ljc_out
    imul    ebx, eax, VI_SZ
    add     rbx, [rip+vd_inst]
    mov     rbp, [rbx+VI_DAG]
    lea     r14, [rbp+VH_SZ]            # clusters
    mov     rax, [rbp+VH_OGR]
    add     rax, rbp
    mov     [rsp+JC_GR], rax
    mov     rax, [rbp+VH_OMEM]
    add     rax, rbp
    mov     [rsp+JC_MEM], rax
    mov     rax, [rbp+VR_CREATOR]
    mov     [rsp+JC_CRE], rax
    xor     eax, eax
    cmp     dword ptr [rbp+VR_STREAM], 0
    je      3f
    mov     rax, [rbp+VR_STATE]
3:  mov     [rsp+JC_ST], rax
    mov     rax, [rbp+VR_STAMP]
    mov     [rsp+JC_STAMP], rax
    lea     rdi, [rsp+JC_N1]
    mov     ecx, 9
    xor     eax, eax
    rep     stosd
    # scratch: a bit per group, the stack; the lists from this thread's pool
    mov     rdi, [rsp+JC_AR]
    test    rdi, rdi
    jz      .Ljc_done
    mov     esi, [rbp+VH_NGR]
    add     esi, 63
    shr     esi, 6
    shl     esi, 3
    mov     r15d, esi
    call    arena_alloc
    test    rax, rax
    jz      .Ljc_done
    mov     [rsp+JC_VIS], rax
    mov     rdi, rax
    mov     ecx, r15d
    shr     ecx, 3
    xor     eax, eax
    rep     stosq
    mov     rdi, [rsp+JC_AR]
    mov     esi, [rbp+VH_NCL]
    shl     esi, 2
    add     esi, 16
    call    arena_alloc
    test    rax, rax
    jz      .Ljc_done
    mov     r12, rax                    # stack
    mov     edi, [rsp+JC_THR]
    mov     esi, [rbp+VH_NCL]
    shl     rsi, 3
    call    pool_take
    test    rax, rax
    jz      .Ljc_done
    mov     [rsp+JC_L1], rax
    mov     ecx, [rbp+VH_NCL]
    lea     rax, [rax+rcx*4]
    mov     [rsp+JC_L2], rax
    mov     rsi, [rbp+VR_ROOTLS]        # the roots
    mov     r13d, [rbp+VR_NROOT]
    mov     rdi, r12
    mov     ecx, r13d
    rep     movsd
    movss   xmm7, [rbx+VI_S]
.Ljc_pop:
    test    r13d, r13d
    jz      .Ljc_done
    dec     r13d
    mov     ecx, [r12+r13*4]
    mov     [rsp+JC_C], ecx
    mov     r15, rcx
    shl     r15, 6
    add     r15, r14                    # its record
    mov     rax, [rsp+JC_CRE]
    mov     eax, [rax+rcx*4]
    test    eax, eax
    jz      .Ljc_draw                   # level 0: a leaf
    # the group that made it: refine while its error is over vd_px pixels
    lea     rdi, [r15+CR_LOD]
    lea     rsi, [rbx+VI_C]
    call    sph_cam
    movaps  xmm1, xmm0
    dpps    xmm1, xmm1, 0x71
    sqrtss  xmm1, xmm1
    movaps  xmm2, xmm0
    shufps  xmm2, xmm2, 0xff
    subss   xmm1, xmm2                  # distance to the sphere
    movss   xmm2, [r15+CR_ERR]
    mulss   xmm2, [rbx+VI_KS]
    comiss  xmm2, xmm1
    jbe     .Ljc_draw                   # fine enough
    mov     rcx, [rsp+JC_CRE]
    mov     edx, [rsp+JC_C]
    mov     edx, [rcx+rdx*4]
    dec     edx                         # the group
    mov     rax, [rsp+JC_VIS]
    bt      [rax], edx
    jc      .Ljc_pop                    # expanded (or culled) already
    mov     [rsp+JC_C+4-4], edx         # (JC_C: now the group)
    call    frustum
    test    eax, eax
    jz      4f
    mov     edx, [rsp+JC_C]
    mov     rax, [rsp+JC_VIS]
    bts     [rax], edx
    inc     dword ptr [rsp+JC_FRU]
    jmp     .Ljc_pop
4:  cmp     qword ptr [rsp+JC_ST], 0
    je      5f
    mov     edi, [rsp+JC_C]
    mov     rsi, rsp                    # (this frame)
    call    members_in
    test    eax, eax
    jnz     5f
    inc     dword ptr [rsp+JC_FALL]     # not yet: the clusters it made stand
    sub     r15, r14                    #  in (this one now)
    shr     r15, 6
    mov     [rsp+JC_C], r15d
    shl     r15, 6
    add     r15, r14
    jmp     .Ljc_draw
5:  mov     edx, [rsp+JC_C]
    mov     rax, [rsp+JC_VIS]
    bts     [rax], edx
    imul    rax, rdx, GR_SZ             # its members, onto the stack
    add     rax, [rsp+JC_GR]
    mov     ecx, [rax+GR_NMEM]
    mov     esi, [rax+GR_MEM]
    shl     rsi, 2
    add     rsi, [rsp+JC_MEM]
    lea     rdi, [r12+r13*4]
    add     r13d, ecx
    rep     movsd
    jmp     .Ljc_pop
.Ljc_draw:
    lea     rdi, [r15+CR_C]
    lea     rsi, [rbx+VI_C]
    call    sph_cam
    call    frustum
    test    eax, eax
    jz      6f
    inc     dword ptr [rsp+JC_FRU]
    jmp     .Ljc_pop
6:  cmp     qword ptr [rsp+JC_ST], 0
    je      7f
    mov     rdi, r15
    mov     rsi, [rsp+JC_STAMP]
    call    stamp_cl
7:  movzx   r8d, byte ptr [r15+CR_NV]
    movzx   r9d, byte ptr [r15+CR_NT]
    mov     ecx, [rsp+JC_C]
    cmp     dword ptr [rip+hz_ok], 0
    je      71f
    lea     rdi, [r15+CR_C]             # occluded in the last frame?
    lea     rsi, [rbx+VI_P]
    call    sph_cam
    call    occluded
    test    eax, eax
    jz      70f
    movzx   r8d, byte ptr [r15+CR_NV]
    movzx   r9d, byte ptr [r15+CR_NT]
    mov     ecx, [rsp+JC_C]
    mov     rax, [rsp+JC_L2]            # waits for the second batch
    mov     edx, [rsp+JC_N2]
    mov     [rax+rdx*4], ecx
    inc     dword ptr [rsp+JC_N2]
    add     [rsp+JC_NVC], r8d
    add     [rsp+JC_NTC], r9d
    inc     dword ptr [rsp+JC_OCC]
    jmp     .Ljc_pop
70: movzx   r8d, byte ptr [r15+CR_NV]
    movzx   r9d, byte ptr [r15+CR_NT]
    mov     ecx, [rsp+JC_C]
71: mov     rax, [rsp+JC_L1]
    mov     edx, [rsp+JC_N1]
    mov     [rax+rdx*4], ecx
    inc     dword ptr [rsp+JC_N1]
    add     [rsp+JC_NV1], r8d
    add     [rsp+JC_NT1], r9d
    jmp     .Ljc_pop
.Ljc_done:
    mov     rax, [rsp+JC_L1]
    mov     [rbx+VI_L1], rax
    mov     rax, [rsp+JC_L2]
    mov     [rbx+VI_L2], rax
    mov     eax, [rsp+JC_N1]
    mov     [rbx+VI_N1], eax
    mov     eax, [rsp+JC_N2]
    mov     [rbx+VI_N2], eax
    mov     eax, [rsp+JC_NV1]
    mov     [rbx+VI_NV], eax
    mov     [rbx+VI_V2], eax
    add     eax, [rsp+JC_NVC]
    mov     [rbx+VI_CV], eax
    mov     eax, [rsp+JC_NT1]
    mov     [rbx+VI_NT], eax
    mov     [rbx+VI_T2], eax
    add     eax, [rsp+JC_NTC]
    mov     [rbx+VI_CT], eax
    mov     eax, [rsp+JC_FRU]
    mov     [rbx+VI_FRU], eax
    lock add [rip+vs_fru], eax
    mov     eax, [rsp+JC_OCC]
    mov     [rbx+VI_OCC], eax
    lock add [rip+vs_occ], eax
    mov     eax, [rsp+JC_FALL]
    mov     [rbx+VI_FALL], eax
    lock add [rip+vs_fall], eax
    inc     dword ptr [rsp+JC_I]
    jmp     .Ljc_inst
.Ljc_out:
    add     rsp, JC_SZ
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbp
    pop     rbx
    ret

# members_in(edi=group, rsi=job_cut's frame) -> eax = 1 when all its
#   members' pages are in memory (they are stamped as used; missing ones
#   asked for). rbp = the DAG, r14 = its clusters.
members_in:
    push    rbx
    push    r12
    push    r13
    push    r15
    sub     rsp, 8
    mov     r15, rsi
    imul    rax, rdi, GR_SZ
    add     rax, [r15+JC_GR]
    mov     r12d, [rax+GR_NMEM]
    mov     ebx, [rax+GR_MEM]
    shl     rbx, 2
    add     rbx, [r15+JC_MEM]
    mov     dword ptr [rsp], 1
1:  test    r12d, r12d
    jz      9f
    mov     eax, [rbx]
    shl     rax, 6
    lea     rdi, [r14+rax]
    call    cl_pages                    # ecx..edx
    mov     r8, [r15+JC_ST]
    mov     r9, [r15+JC_STAMP]
    mov     r10d, [rip+vd_frame]
2:  cmp     ecx, edx
    ja      4f
    mov     [r9+rcx*4], r10d
    cmp     byte ptr [r8+rcx], 2
    jae     3f
    mov     dword ptr [rsp], 0
    cmp     byte ptr [r8+rcx], 0
    jne     3f
    xor     eax, eax                    # ask for it (once)
    mov     r11d, 1
    lock cmpxchg [r8+rcx], r11b
    jne     3f
    mov     eax, 1
    lock xadd [rip+vd_nreq], eax
    cmp     eax, VD_RQ
    jb      21f
    mov     byte ptr [r8+rcx], 0        # (too many this frame)
    jmp     3f
21: shl     rax, 4
    lea     r11, [rip+vd_req]
    mov     [r11+rax], rbp
    mov     [r11+rax+8], ecx
3:  inc     ecx
    jmp     2b
4:  add     rbx, 4
    dec     r12d
    jmp     1b
9:  mov     eax, [rsp]
    add     rsp, 8
    pop     r15
    pop     r13
    pop     r12
    pop     rbx
    ret

# cl_pages(rdi=cluster record) -> ecx = its first page, edx = its last
cl_pages:
    mov     ecx, [rdi+CR_DATA]
    shl     rcx, 4
    movzx   eax, byte ptr [rdi+CR_NV]
    shl     eax, 4
    movzx   edx, byte ptr [rdi+CR_NT]
    lea     edx, [rdx+rdx*2+15]
    and     edx, -16
    add     eax, edx
    lea     rdx, [rcx+rax-1]
    shr     rcx, VP_SHIFT
    shr     rdx, VP_SHIFT
    ret

# stamp_cl(rdi=cluster record, rsi=stamps) - its pages used this frame
stamp_cl:
    call    cl_pages
    mov     eax, [rip+vd_frame]
1:  cmp     ecx, edx
    ja      9f
    mov     [rsi+rcx*4], eax
    inc     ecx
    jmp     1b
9:  ret

# pool_take(edi=thread, rsi=bytes) -> rax = room in the thread's pool (0: none)
pool_take:
    push    rbx
    push    r12
    sub     rsp, 8
    mov     r12, rsi
    add     r12, 15
    and     r12, -16
    shl     edi, 4
    lea     rbx, [rip+vd_pool]
    add     rbx, rdi
    cmp     qword ptr [rbx], 0
    jne     1f
    xor     edi, edi                    # reserved once, touched as used
    mov     esi, VD_POOL_BYTES
    mov     edx, PROT_RW
    mov     r10d, MAP_NORES
    mov     r8, -1
    xor     r9d, r9d
    mov     eax, SYS_MMAP
    syscall
    cmp     rax, -4096
    jae     8f
    mov     [rbx], rax
1:  mov     rax, [rbx+8]
    lea     rcx, [rax+r12]
    cmp     rcx, VD_POOL_BYTES
    ja      8f
    mov     [rbx+8], rcx
    add     rax, [rbx]
    jmp     9f
8:  xor     eax, eax
9:  add     rsp, 8
    pop     r12
    pop     rbx
    ret

# =============================================================================
#  Occlusion: the depth pyramid
# =============================================================================
# occluded(xmm0=sphere in the pyramid's camera space) -> eax = 1 when every
#   pixel it may cover was nearer (1/z larger) in the pyramid
occluded:
    movaps  xmm1, xmm0
    shufps  xmm1, xmm1, 0xff            # r
    movaps  xmm2, xmm0
    shufps  xmm2, xmm2, 0xaa            # z
    movss   xmm3, xmm2
    subss   xmm3, xmm1                  # nearest z
    comiss  xmm3, [rip+f_near]
    jbe     .Loc_no
    movss   xmm4, [rip+f_one]
    divss   xmm4, xmm3                  # 1 / near z
    addss   xmm2, xmm1
    movss   xmm5, [rip+f_one]
    divss   xmm5, xmm2                  # 1 / far z
    # x: the extremes of x / z over the sphere's box
    movss   xmm2, xmm0
    subss   xmm2, xmm1                  # x - r
    call    .Loc_lo
    movss   xmm8, xmm6                  # xmin
    movss   xmm2, xmm0
    addss   xmm2, xmm1                  # x + r
    call    .Loc_hi
    movss   xmm9, xmm6                  # xmax
    movaps  xmm2, xmm0
    shufps  xmm2, xmm2, 0x55
    subss   xmm2, xmm1
    call    .Loc_lo
    movss   xmm10, xmm6                 # ymin
    movaps  xmm2, xmm0
    shufps  xmm2, xmm2, 0x55
    addss   xmm2, xmm1
    call    .Loc_hi
    movss   xmm11, xmm6                 # ymax
    movss   xmm2, [rip+hz_f]
    mulss   xmm8, xmm2
    addss   xmm8, [rip+hz_cx]           # px0
    mulss   xmm9, xmm2
    addss   xmm9, [rip+hz_cx]           # px1
    mulss   xmm11, xmm2
    movss   xmm12, [rip+hz_cy]
    subss   xmm12, xmm11                # py0
    mulss   xmm10, xmm2
    movss   xmm13, [rip+hz_cy]
    subss   xmm13, xmm10                # py1
    xorps   xmm2, xmm2
    comiss  xmm9, xmm2
    jb      .Loc_no
    comiss  xmm13, xmm2
    jb      .Loc_no
    cvtsi2ss xmm3, dword ptr [rip+hz_w]
    comiss  xmm8, xmm3
    jae     .Loc_no
    cvtsi2ss xmm3, dword ptr [rip+hz_h]
    comiss  xmm12, xmm3
    jae     .Loc_no
    maxss   xmm8, xmm2
    maxss   xmm12, xmm2
    cvttss2si r8d, xmm8                 # ix0, iy0
    cvttss2si r9d, xmm12
    mov     eax, [rip+hz_w]
    dec     eax
    cvtsi2ss xmm3, eax
    minss   xmm9, xmm3
    cvttss2si r10d, xmm9                # ix1
    mov     eax, [rip+hz_h]
    dec     eax
    cvtsi2ss xmm3, eax
    minss   xmm13, xmm3
    cvttss2si r11d, xmm13               # iy1
    mov     ecx, 1                      # the level where it covers <= 2 x 2
1:  cmp     ecx, [rip+hz_nl]
    jae     2f
    mov     eax, r10d
    shr     eax, cl
    mov     edx, r8d
    shr     edx, cl
    sub     eax, edx
    cmp     eax, 1
    ja      11f
    mov     eax, r11d
    shr     eax, cl
    mov     edx, r9d
    shr     edx, cl
    sub     eax, edx
    cmp     eax, 1
    jbe     2f
11: inc     ecx
    jmp     1b
2:  lea     rax, [rip+hz_lw]
    mov     esi, [rax+rcx*4]            # level width
    lea     rax, [rip+hz_lo]
    mov     eax, [rax+rcx*4]
    mov     rdi, [rip+hz_map]
    lea     rdi, [rdi+rax*4]
    shr     r8d, cl
    shr     r9d, cl
    shr     r10d, cl
    shr     r11d, cl
    movss   xmm6, [rip+f_big]
3:  cmp     r9d, r11d
    ja      5f
    mov     eax, r9d
    imul    eax, esi
    mov     edx, r8d
4:  cmp     edx, r10d
    ja      41f
    lea     ecx, [rax+rdx]
    minss   xmm6, [rdi+rcx*4]
    inc     edx
    jmp     4b
41: inc     r9d
    jmp     3b
5:  xor     eax, eax
    comiss  xmm4, xmm6                  # nearest 1/z < the farthest there
    setb    al
    ret
.Loc_no:
    xor     eax, eax
    ret
# xmm2 = a coordinate's low end -> xmm6 = it / z at the end that makes it least
.Loc_lo:
    xorps   xmm6, xmm6
    comiss  xmm2, xmm6
    movss   xmm6, xmm2
    jb      1f
    mulss   xmm6, xmm5                  # >= 0: / far z
    ret
1:  mulss   xmm6, xmm4                  # < 0: / near z
    ret
.Loc_hi:
    xorps   xmm6, xmm6
    comiss  xmm2, xmm6
    movss   xmm6, xmm2
    jb      1f
    mulss   xmm6, xmm4
    ret
1:  mulss   xmm6, xmm5
    ret

# hz_build - the depth pyramid from this frame's depth (min 1/z: the
#   farthest), its camera kept
hz_build:
    push    rbx
    push    r12
    push    r13
    mov     eax, [rip+rs_w]
    mov     ecx, [rip+rs_h]
    mov     [rip+hz_w], eax
    mov     [rip+hz_h], ecx
    mov     dword ptr [rip+hz_ok], 0
    lea     r8, [rip+hz_lw]
    lea     r9, [rip+hz_lh]
    lea     r10, [rip+hz_lo]
    mov     [r8], eax
    mov     [r9], ecx
    xor     edx, edx                    # floats so far
    mov     ebx, 1
1:  inc     eax
    shr     eax, 1
    inc     ecx
    shr     ecx, 1
    mov     [r8+rbx*4], eax
    mov     [r9+rbx*4], ecx
    mov     [r10+rbx*4], edx
    mov     esi, eax
    imul    esi, ecx
    add     edx, esi
    inc     ebx
    cmp     ebx, HZ_MAXL
    jae     2f
    cmp     eax, 1
    jne     1b
    cmp     ecx, 1
    jne     1b
2:  dec     ebx
    mov     [rip+hz_nl], ebx            # the top level
    lea     r12, [rdx*4+4095]
    and     r12, -4096
    cmp     r12, [rip+hz_cap]
    jbe     3f
    mov     rdi, [rip+hz_map]
    test    rdi, rdi
    jz      21f
    mov     rsi, [rip+hz_cap]
    mov     eax, SYS_MUNMAP
    syscall
21: xor     edi, edi
    mov     rsi, r12
    mov     edx, PROT_RW
    mov     r10d, 0x22
    mov     r8, -1
    xor     r9d, r9d
    mov     eax, SYS_MMAP
    syscall
    cmp     rax, -4096
    jae     8f
    mov     [rip+hz_map], rax
    mov     [rip+hz_cap], r12
3:  lea     rdi, [rip+job_hz1]          # level 1 from the depth, by rows
    xor     esi, esi
    mov     edx, [rip+hz_lh+4]
    mov     ecx, 16
    call    parallel_for
    mov     ebx, 2                      # the rest from the level below
4:  cmp     ebx, [rip+hz_nl]
    ja      5f
    lea     r8, [rip+hz_lo]
    mov     rdi, [rip+hz_map]
    mov     eax, [r8+rbx*4-4]
    lea     rdi, [rdi+rax*4]            # source
    mov     rsi, [rip+hz_map]
    mov     eax, [r8+rbx*4]
    lea     rsi, [rsi+rax*4]            # destination
    lea     r8, [rip+hz_lw]
    lea     r9, [rip+hz_lh]
    mov     edx, [r8+rbx*4-4]
    mov     ecx, [r9+rbx*4-4]
    mov     r10d, [r8+rbx*4]
    xor     r11d, r11d
    mov     r12d, [r9+rbx*4]
    call    hz_rows
    inc     ebx
    jmp     4b
5:  lea     rsi, [rip+vd_cam]           # its camera
    lea     rdi, [rip+hz_cam]
    mov     ecx, 12
    rep     movsd
    mov     eax, [rip+vp_focal]
    mov     [rip+hz_f], eax
    movss   xmm0, [rip+vp_cx]
    cvtsi2ss xmm1, dword ptr [rip+rs_x0]
    subss   xmm0, xmm1
    movss   [rip+hz_cx], xmm0
    movss   xmm0, [rip+vp_cy]
    cvtsi2ss xmm1, dword ptr [rip+rs_y0]
    subss   xmm0, xmm1
    movss   [rip+hz_cy], xmm0
    mov     dword ptr [rip+hz_ok], 1
8:  pop     r13
    pop     r12
    pop     rbx
    ret

# job_hz1(ctx, esi=first row, edx=end) - level 1 rows from the depth buffer
job_hz1:
    push    rbx
    push    r12
    sub     rsp, 8
    mov     r11d, esi
    mov     r12d, edx
    mov     rdi, [rip+rs_depth]
    mov     rsi, [rip+hz_map]
    mov     edx, [rip+rs_w]
    mov     ecx, [rip+rs_h]
    mov     r10d, [rip+hz_lw+4]
    call    hz_rows
    add     rsp, 8
    pop     r12
    pop     rbx
    ret

# hz_rows(rdi=source, edx x ecx, rsi=destination r10d wide, rows r11d ..
#   r12d) - each texel the least of its (up to) 2 x 2 source texels
hz_rows:
    push    r13
    push    r14
    push    r15
1:  cmp     r11d, r12d
    jae     9f
    lea     r13d, [r11+r11]             # source rows y0, y1 (clamped)
    lea     r14d, [r13+1]
    cmp     r14d, ecx
    jb      2f
    mov     r14d, r13d
2:  imul    r13d, edx
    imul    r14d, edx
    xor     r15d, r15d                  # x
3:  cmp     r15d, r10d
    jae     5f
    lea     eax, [r15+r15]
    lea     r8d, [rax+1]
    cmp     r8d, edx
    jb      4f
    mov     r8d, eax
4:  lea     r9d, [r13+rax]
    movss   xmm0, [rdi+r9*4]
    lea     r9d, [r13+r8]
    minss   xmm0, [rdi+r9*4]
    lea     r9d, [r14+rax]
    minss   xmm0, [rdi+r9*4]
    lea     r9d, [r14+r8]
    minss   xmm0, [rdi+r9*4]
    mov     eax, r11d
    imul    eax, r10d
    add     eax, r15d
    movss   [rsi+rax*4], xmm0
    inc     r15d
    jmp     3b
5:  inc     r11d
    jmp     1b
9:  pop     r15
    pop     r14
    pop     r13
    ret

# job_occ2(ctx, esi=first object, edx=end) - the clusters that waited,
#   tested against this frame's pyramid: the visible ones kept (in order)
job_occ2:
    push    rbx
    push    rbp
    push    r12
    push    r13
    push    r14
    push    r15
    sub     rsp, 24
    mov     [rsp], esi
    mov     [rsp+4], edx
.Ljo_inst:
    mov     eax, [rsp]
    cmp     eax, [rsp+4]
    jae     .Ljo_out
    imul    ebx, eax, VI_SZ
    add     rbx, [rip+vd_inst]
    mov     rbp, [rbx+VI_DAG]
    mov     r12, [rbx+VI_L2]
    mov     r13d, [rbx+VI_N2]
    xor     r14d, r14d                  # kept
    mov     dword ptr [rsp+8], 0        # their vertices, triangles
    mov     dword ptr [rsp+12], 0
    movss   xmm7, [rbx+VI_S]
    cmp     qword ptr [rbx+VI_MESH], 0
    jne     1f
    xor     r13d, r13d
1:  test    r13d, r13d
    jz      3f
    mov     eax, [r12]
    mov     r15, rax
    shl     r15, 6
    lea     r15, [rbp+r15+VH_SZ]
    lea     rdi, [r15+CR_C]
    lea     rsi, [rbx+VI_C]
    call    sph_cam
    call    occluded
    test    eax, eax
    jnz     2f
    mov     eax, [r12]
    mov     rcx, [rbx+VI_L2]
    mov     [rcx+r14*4], eax
    inc     r14d
    movzx   eax, byte ptr [r15+CR_NV]
    add     [rsp+8], eax
    movzx   eax, byte ptr [r15+CR_NT]
    add     [rsp+12], eax
2:  add     r12, 4
    dec     r13d
    jmp     1b
3:  mov     [rbx+VI_N2], r14d
    mov     eax, [rsp+8]
    add     [rbx+VI_NV], eax
    mov     eax, [rsp+12]
    add     [rbx+VI_NT], eax
    inc     dword ptr [rsp]
    jmp     .Ljo_inst
.Ljo_out:
    add     rsp, 24
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbp
    pop     rbx
    ret

# =============================================================================
#  Decoding clusters into the meshes drawn
# =============================================================================
# vd_decode(edi=batch: 0 the first, 1 the second) - one entry per cluster
#   (object, cluster, first vertex, first triangle), decoded in parallel
vd_decode:
    push    rbx
    push    rbp
    push    r12
    push    r13
    push    r14
    push    r15
    sub     rsp, 8
    mov     ebp, edi
    xor     ebx, ebx                    # count
    xor     r12d, r12d
1:  cmp     r12d, [rip+vd_n]
    jae     2f
    mov     edi, r12d
    call    vgd_inst
    cmp     qword ptr [rax+VI_MESH], 0
    je      11f
    mov     ecx, [rax+VI_N1]
    test    ebp, ebp
    jz      12f
    mov     ecx, [rax+VI_N2]
12: add     ebx, ecx
11: inc     r12d
    jmp     1b
2:  mov     dword ptr [rip+vd_nent], 0
    test    ebx, ebx
    jz      9f
    lea     rdi, [rip+frame_arena]
    mov     esi, ebx
    shl     rsi, 4
    call    arena_alloc
    test    rax, rax
    jz      9f
    mov     [rip+vd_ents], rax
    mov     r13, rax
    mov     [rip+vd_nent], ebx
    xor     r12d, r12d
3:  cmp     r12d, [rip+vd_n]
    jae     6f
    mov     edi, r12d
    call    vgd_inst
    mov     r14, rax
    cmp     qword ptr [r14+VI_MESH], 0
    je      5f
    mov     rsi, [r14+VI_L1]
    mov     ecx, [r14+VI_N1]
    xor     r8d, r8d                    # vertex, triangle
    xor     r9d, r9d
    test    ebp, ebp
    jz      31f
    mov     rsi, [r14+VI_L2]
    mov     ecx, [r14+VI_N2]
    mov     r8d, [r14+VI_V2]
    mov     r9d, [r14+VI_T2]
31: mov     r10, [r14+VI_DAG]
4:  test    ecx, ecx
    jz      5f
    mov     eax, [rsi]
    mov     [r13], r12d
    mov     [r13+4], eax
    mov     [r13+8], r8d
    mov     [r13+12], r9d
    shl     rax, 6
    lea     rax, [r10+rax+VH_SZ]
    movzx   edx, byte ptr [rax+CR_NV]
    add     r8d, edx
    movzx   edx, byte ptr [rax+CR_NT]
    add     r9d, edx
    add     r13, 16
    add     rsi, 4
    dec     ecx
    jmp     4b
5:  inc     r12d
    jmp     3b
6:  lea     rdi, [rip+job_decode]
    xor     esi, esi
    mov     edx, [rip+vd_nent]
    mov     ecx, 64
    call    parallel_for
9:  add     rsp, 8
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbp
    pop     rbx
    ret

# job_decode(ctx, esi=first entry, edx=end) - positions (grid -> model),
#   triangles (local + first vertex), colours (by cluster)
job_decode:
    push    rbx
    push    rbp
    push    r12
    push    r13
    push    r14
    push    r15
    sub     rsp, 8
    mov     ebx, esi
    mov     ebp, edx
.Ljd_next:
    cmp     ebx, ebp
    jae     .Ljd_out
    mov     rax, rbx
    shl     rax, 4
    add     rax, [rip+vd_ents]
    mov     edi, [rax]
    mov     r12d, [rax+4]               # cluster
    mov     r13d, [rax+8]               # first vertex
    mov     r14d, [rax+12]              # first triangle
    call    vgd_inst
    mov     r15, [rax+VI_MESH]
    mov     r10, [rax+VI_DAG]
    mov     rax, r12
    shl     rax, 6
    lea     r11, [r10+rax+VH_SZ]        # its record
    mov     eax, [r11+CR_DATA]
    shl     rax, 4
    add     rax, [r10+VH_ODATA]
    lea     rsi, [r10+rax]              # its data
    movss   xmm7, [r10+VH_STEP]
    shufps  xmm7, xmm7, 0
    movups  xmm6, [r10+VH_BMIN]
    movzx   ecx, byte ptr [r11+CR_NV]
    imul    rdi, r13, 12
    add     rdi, [r15+ME_POS]
    mov     r8d, ecx
1:  test    r8d, r8d
    jz      2f
    movdqu  xmm0, [rsi]
    cvtdq2ps xmm0, xmm0
    mulps   xmm0, xmm7
    addps   xmm0, xmm6
    movq    [rdi], xmm0
    extractps [rdi+8], xmm0, 2
    add     rsi, 16
    add     rdi, 12
    dec     r8d
    jmp     1b
2:  movzx   ecx, byte ptr [r11+CR_NT]   # triangles
    lea     ecx, [rcx+rcx*2]
    imul    rdi, r14, 12
    add     rdi, [r15+ME_TRIS]
3:  test    ecx, ecx
    jz      4f
    movzx   eax, byte ptr [rsi]
    add     eax, r13d
    mov     [rdi], eax
    inc     rsi
    add     rdi, 4
    dec     ecx
    jmp     3b
4:  mov     rdi, [r15+ME_VCOL]          # (clusters coloured)
    test    rdi, rdi
    jz      6f
    imul    eax, r12d, 0x9e3779b1
    mov     ecx, eax
    shr     ecx, 15
    xor     eax, ecx
    imul    eax, eax, 0x85ebca6b
    mov     ecx, eax
    shr     ecx, 13
    xor     eax, ecx
    or      eax, 0xff404040
    lea     rdi, [rdi+r13*4]
    movzx   ecx, byte ptr [r11+CR_NV]
    rep     stosd
6:  inc     ebx
    jmp     .Ljd_next
.Ljd_out:
    add     rsp, 8
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbp
    pop     rbx
    ret

# =============================================================================
#  The DAGs' runtime state, streaming
# =============================================================================
# vd_prep(rdi=dag) -> eax = 1: its creators, roots, page states made (once);
#   a streamed DAG is listed and its roots' pages read now and kept
vd_prep:
    mov     eax, 1
    cmp     dword ptr [rdi+VR_READY], 0
    jne     .Lvp_ret
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    push    rbp
    sub     rsp, 8
    mov     rbx, rdi
    lea     r12, [rbx+VH_SZ]            # roots: no parent
    mov     ecx, [rbx+VH_NCL]
    xor     r13d, r13d
1:  test    ecx, ecx
    jz      2f
    cmp     dword ptr [r12+CR_PERR], 0x7f7fffff
    jne     11f
    inc     r13d
11: add     r12, CR_SZ
    dec     ecx
    jmp     1b
2:  mov     [rbx+VR_NROOT], r13d
    mov     rax, [rbx+VH_DBYTES]
    add     rax, VP_BYTES-1
    shr     rax, VP_SHIFT
    mov     [rbx+VR_NPAGE], eax
    mov     r14d, eax
    mov     esi, [rbx+VH_NCL]           # creators, roots, stamps, states
    add     esi, r13d
    add     esi, r14d
    shl     rsi, 2
    add     rsi, r14
    add     rsi, 4095+64
    and     rsi, -4096
    mov     [rbx+VR_RTBYTES], rsi
    xor     edi, edi
    mov     edx, PROT_RW
    mov     r10d, 0x22
    mov     r8, -1
    xor     r9d, r9d
    mov     eax, SYS_MMAP
    syscall
    cmp     rax, -4096
    jae     .Lvp_fail
    mov     [rbx+VR_RTMAP], rax
    mov     [rbx+VR_CREATOR], rax
    mov     ecx, [rbx+VH_NCL]
    lea     rax, [rax+rcx*4]
    mov     [rbx+VR_ROOTLS], rax
    lea     rax, [rax+r13*4]
    mov     [rbx+VR_STAMP], rax
    lea     rax, [rax+r14*4]
    mov     [rbx+VR_STATE], rax
    mov     r12, [rbx+VH_OGR]           # creators: the clusters a group made
    add     r12, rbx
    mov     r15d, [rbx+VH_NGR]
    xor     ebp, ebp
3:  cmp     ebp, r15d
    jae     4f
    mov     ecx, [r12+GR_PAR]
    mov     edx, [r12+GR_NPAR]
    mov     rdi, [rbx+VR_CREATOR]
    lea     rdi, [rdi+rcx*4]
    lea     eax, [rbp+1]
    mov     ecx, edx
    rep     stosd
    add     r12, GR_SZ
    inc     ebp
    jmp     3b
4:  lea     r12, [rbx+VH_SZ]            # the roots' list
    mov     rdi, [rbx+VR_ROOTLS]
    xor     ecx, ecx
5:  cmp     ecx, [rbx+VH_NCL]
    jae     6f
    cmp     dword ptr [r12+CR_PERR], 0x7f7fffff
    jne     51f
    mov     [rdi], ecx
    add     rdi, 4
51: add     r12, CR_SZ
    inc     ecx
    jmp     5b
6:  cmp     dword ptr [rbx+VR_STREAM], 0
    je      .Lvp_ok
    cmp     dword ptr [rip+vd_nreg], VD_REG
    jae     .Lvp_unstream
    mov     eax, [rip+vd_nreg]          # listed
    lea     rcx, [rip+vd_reg]
    mov     [rcx+rax*8], rbx
    inc     eax
    mov     [rip+vd_nreg], eax
    mov     [rbx+VR_REG], eax
    xor     r12d, r12d                  # the roots' pages: read, kept
7:  cmp     r12d, r13d
    jae     .Lvp_ok
    mov     rax, [rbx+VR_ROOTLS]
    mov     eax, [rax+r12*4]
    shl     rax, 6
    lea     rdi, [rbx+rax+VH_SZ]
    call    cl_pages
8:  cmp     ecx, edx
    ja      72f
    mov     rax, [rbx+VR_STATE]
    cmp     byte ptr [rax+rcx], 3
    je      71f
    mov     byte ptr [rax+rcx], 3
    push    rcx
    push    rdx
    mov     rdi, rbx
    mov     esi, ecx
    call    page_span
    add     [rip+vd_res], rdx
81: test    rdx, rdx                    # (touched: read from the file now)
    jz      82f
    mov     cl, [rax]
    add     rax, 4096
    sub     rdx, 4096
    ja      81b
82: pop     rdx
    pop     rcx
71: inc     ecx
    jmp     8b
72: inc     r12d
    jmp     7b
.Lvp_unstream:
    mov     dword ptr [rbx+VR_STREAM], 0
.Lvp_ok:
    mov     dword ptr [rbx+VR_READY], 1
    mov     eax, 1
    jmp     9f
.Lvp_fail:
    xor     eax, eax
9:  add     rsp, 8
    pop     rbp
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
.Lvp_ret:
    ret

# page_span(rdi=dag, esi=page) -> rax = its address, rdx = its bytes
page_span:
    mov     eax, esi
    shl     rax, VP_SHIFT
    mov     rdx, [rdi+VH_DBYTES]
    sub     rdx, rax
    cmp     rdx, VP_BYTES
    jbe     1f
    mov     edx, VP_BYTES
1:  add     rdx, 4095
    and     rdx, -4096
    add     rax, [rdi+VH_ODATA]
    add     rax, rdi
    ret

# vd_streaming -> eax = pages on their way (the main loop: look soon)
vd_streaming:
    mov     eax, [rip+vd_nfl]
    ret

# vd_poll - (the main loop) pages that came in: a frame to draw them
vd_poll:
    cmp     dword ptr [rip+vd_nfl], 0
    je      9f
    sub     rsp, 8
    call    vd_tick_in
    add     rsp, 8
    test    eax, eax
    jz      9f
    mov     dword ptr [rip+dirty], 1
9:  ret

# vd_tick_in -> eax = pages on their way that are now all in memory: counted
#   in
vd_tick_in:
    push    rbx
    push    r12
    push    r13
    push    r14
    sub     rsp, 40                     # mincore's answer (16 pages)
    xor     ebx, ebx
    xor     r14d, r14d
1:  cmp     ebx, [rip+vd_nfl]
    jae     9f
    mov     r12d, ebx
    shl     r12, 4
    lea     rax, [rip+vd_fl]
    add     r12, rax
    mov     r13, [r12]
    mov     rdi, r13
    mov     esi, [r12+8]
    call    page_span
    mov     rdi, rax
    mov     rsi, rdx
    mov     rdx, rsp
    push    rsi
    mov     eax, SYS_MINCORE
    syscall
    pop     rsi
    test    rax, rax
    jnz     3f
    shr     esi, 12
    xor     ecx, ecx
2:  cmp     ecx, esi
    jae     4f
    test    byte ptr [rsp+rcx], 1
    jz      3f
    inc     ecx
    jmp     2b
3:  inc     dword ptr [r12+12]          # not yet
    cmp     dword ptr [r12+12], 120     # (asked again now and then)
    jb      31f
    mov     dword ptr [r12+12], 0
    mov     rdi, r13
    mov     esi, [r12+8]
    call    page_span
    mov     rdi, rax
    mov     rsi, rdx
    mov     edx, MADV_WILLNEED
    mov     eax, SYS_MADVISE
    syscall
31: inc     ebx
    jmp     1b
4:  inc     r14d
    mov     rdi, r13                    # in
    mov     esi, [r12+8]
    call    page_span
    sub     [rip+vd_flb], rdx
    add     [rip+vd_res], rdx
    mov     ecx, [r12+8]
    mov     rax, [r13+VR_STATE]
    mov     byte ptr [rax+rcx], 2
    mov     rax, [r13+VR_STAMP]
    mov     edx, [rip+vd_frame]
    mov     [rax+rcx*4], edx
    mov     eax, [rip+vd_nfl]           # (the last one takes its place)
    dec     eax
    mov     [rip+vd_nfl], eax
    shl     rax, 4
    lea     rcx, [rip+vd_fl]
    movups  xmm0, [rcx+rax]
    movups  [r12], xmm0
    jmp     1b
9:  mov     eax, r14d
    add     rsp, 40
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# vd_tick_out - this frame's requests: read ahead (madvise WILLNEED) while
#   the pages in memory and on their way fit the budget, the least recently
#   used ones given back to make room
vd_tick_out:
    push    rbx
    push    r12
    push    r13
    push    r14
    sub     rsp, 8
    mov     r14d, [rip+vd_nreq]
    cmp     r14d, VD_RQ
    jbe     1f
    mov     r14d, VD_RQ
1:  xor     ebx, ebx
.Lto_next:
    cmp     ebx, r14d
    jae     .Lto_out
    mov     r12d, ebx
    shl     r12, 4
    lea     rax, [rip+vd_req]
    add     r12, rax
    mov     r13, [r12]
    cmp     dword ptr [rip+vd_nfl], VD_FL
    jae     .Lto_back
    mov     rdi, r13
    mov     esi, [r12+8]
    call    page_span
    mov     rax, [rip+vd_res]           # room?
    add     rax, [rip+vd_flb]
    add     rax, rdx
    sub     rax, [rip+vd_budget]
    jbe     2f
    mov     rdi, rax
    call    vd_evict
    mov     rdi, r13
    mov     esi, [r12+8]
    call    page_span
    mov     rax, [rip+vd_res]
    add     rax, [rip+vd_flb]
    add     rax, rdx
    cmp     rax, [rip+vd_budget]
    ja      .Lto_back
2:  add     [rip+vd_flb], rdx
    mov     rsi, rdx
    mov     rdi, r13
    push    rsi
    mov     esi, [r12+8]
    call    page_span
    pop     rsi
    mov     rdi, rax
    mov     edx, MADV_WILLNEED
    mov     eax, SYS_MADVISE
    syscall
    mov     eax, [rip+vd_nfl]
    inc     dword ptr [rip+vd_nfl]
    shl     rax, 4
    lea     rcx, [rip+vd_fl]
    add     rcx, rax
    mov     [rcx], r13
    mov     eax, [r12+8]
    mov     [rcx+8], eax
    mov     dword ptr [rcx+12], 0
    inc     qword ptr [rip+vs_reqs]
    inc     ebx
    jmp     .Lto_next
.Lto_back:                              # no room: asked for again later
    mov     ecx, [r12+8]
    mov     rax, [r13+VR_STATE]
    mov     byte ptr [rax+rcx], 0
    inc     ebx
    jmp     .Lto_next
.Lto_out:
    mov     dword ptr [rip+vd_nreq], 0
    add     rsp, 8
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# vd_evict(rdi=bytes) - pages in memory not used this frame given back, the
#   least recently used first, until that much is freed (or none is left)
vd_evict:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    push    rbp
    sub     rsp, 8
    mov     r15, rdi
    mov     dword ptr [rsp], 16         # passes
.Lve_pass:
    test    r15, r15
    jle     .Lve_out
    dec     dword ptr [rsp]
    js      .Lve_out
    mov     ebp, -1                     # the oldest stamp
    xor     ebx, ebx
1:  cmp     ebx, [rip+vd_nreg]
    jae     3f
    lea     rax, [rip+vd_reg]
    mov     r12, [rax+rbx*8]
    mov     r13, [r12+VR_STATE]
    mov     r14, [r12+VR_STAMP]
    mov     ecx, [r12+VR_NPAGE]
    mov     edx, [rip+vd_frame]
2:  dec     ecx
    js      21f
    cmp     byte ptr [r13+rcx], 2
    jne     2b
    mov     eax, [r14+rcx*4]
    cmp     eax, edx
    je      2b
    cmp     eax, ebp
    cmovb   ebp, eax
    jmp     2b
21: inc     ebx
    jmp     1b
3:  cmp     ebp, -1
    je      .Lve_out
    xor     ebx, ebx                    # give those back
4:  cmp     ebx, [rip+vd_nreg]
    jae     .Lve_pass
    lea     rax, [rip+vd_reg]
    mov     r12, [rax+rbx*8]
    mov     ecx, [r12+VR_NPAGE]
5:  dec     ecx
    js      6f
    mov     r13, [r12+VR_STATE]
    cmp     byte ptr [r13+rcx], 2
    jne     5b
    mov     r14, [r12+VR_STAMP]
    cmp     [r14+rcx*4], ebp
    jne     5b
    mov     byte ptr [r13+rcx], 0
    push    rcx
    sub     rsp, 8
    mov     rdi, r12
    mov     esi, ecx
    call    page_span
    sub     [rip+vd_res], rdx
    sub     r15, rdx
    mov     rdi, rax
    mov     rsi, rdx
    mov     edx, MADV_DONTNEED
    mov     eax, SYS_MADVISE
    syscall
    inc     qword ptr [rip+vs_evict]
    add     rsp, 8
    pop     rcx
    jmp     5b
6:  inc     ebx
    jmp     4b
.Lve_out:
    add     rsp, 8
    pop     rbp
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# vd_forget(rdi=dag) - (its last reference gone) its runtime state, its
#   pages in memory and on their way, its place in the list
vd_forget:
    cmp     dword ptr [rdi+VR_READY], 0
    je      9f
    push    rbx
    push    r12
    sub     rsp, 8
    mov     rbx, rdi
    cmp     dword ptr [rbx+VR_REG], 0
    je      5f
    mov     ecx, [rbx+VR_NPAGE]         # its pages no longer counted
1:  dec     ecx
    js      2f
    mov     rax, [rbx+VR_STATE]
    cmp     byte ptr [rax+rcx], 2
    jb      1b
    push    rcx
    sub     rsp, 8
    mov     rdi, rbx
    mov     esi, ecx
    call    page_span
    sub     [rip+vd_res], rdx
    add     rsp, 8
    pop     rcx
    jmp     1b
2:  xor     r12d, r12d                  # nor on their way
3:  cmp     r12d, [rip+vd_nfl]
    jae     4f
    mov     eax, r12d
    shl     rax, 4
    lea     rcx, [rip+vd_fl]
    add     rcx, rax
    cmp     [rcx], rbx
    jne     31f
    mov     rdi, rbx
    mov     esi, [rcx+8]
    push    rcx
    sub     rsp, 8
    call    page_span
    add     rsp, 8
    pop     rcx
    sub     [rip+vd_flb], rdx
    mov     eax, [rip+vd_nfl]
    dec     eax
    mov     [rip+vd_nfl], eax
    shl     rax, 4
    lea     rdx, [rip+vd_fl]
    movups  xmm0, [rdx+rax]
    movups  [rcx], xmm0
    jmp     3b
31: inc     r12d
    jmp     3b
4:  mov     eax, [rbx+VR_REG]           # out of the list
    dec     eax
    mov     ecx, [rip+vd_nreg]
    dec     ecx
    mov     [rip+vd_nreg], ecx
    lea     rdx, [rip+vd_reg]
    mov     r8, [rdx+rcx*8]
    mov     [rdx+rax*8], r8
    inc     eax
    mov     [r8+VR_REG], eax
    mov     dword ptr [rbx+VR_REG], 0
5:  mov     rdi, [rbx+VR_RTMAP]
    mov     rsi, [rbx+VR_RTBYTES]
    mov     eax, SYS_MUNMAP
    syscall
    mov     dword ptr [rbx+VR_READY], 0
    add     rsp, 8
    pop     r12
    pop     rbx
9:  ret

# vd_drop(rdi=dag) - (after a save read all of it) a streamed DAG's pages
#   given back but the roots' and those on their way
vd_drop:
    cmp     dword ptr [rdi+VR_STREAM], 0
    je      9f
    push    rbx
    mov     rbx, rdi
    cmp     dword ptr [rbx+VR_READY], 0
    je      3f
    mov     ecx, [rbx+VR_NPAGE]
1:  dec     ecx
    js      4f
    mov     rax, [rbx+VR_STATE]
    movzx   edx, byte ptr [rax+rcx]
    cmp     edx, 1
    je      1b
    cmp     edx, 3
    je      1b
    mov     byte ptr [rax+rcx], 0
    push    rcx
    push    rdx
    mov     rdi, rbx
    mov     esi, ecx
    call    page_span
    pop     r8
    cmp     r8d, 2
    jne     2f
    sub     [rip+vd_res], rdx
2:  mov     rdi, rax
    mov     rsi, rdx
    mov     edx, MADV_DONTNEED
    mov     eax, SYS_MADVISE
    syscall
    pop     rcx
    jmp     1b
3:  mov     rdi, [rbx+VH_ODATA]         # (never drawn: all of it)
    add     rdi, rbx
    mov     rsi, [rbx+VH_DBYTES]
    add     rsi, 4095
    and     rsi, -4096
    mov     edx, MADV_DONTNEED
    mov     eax, SYS_MADVISE
    syscall
4:  pop     rbx
9:  ret

# now_us -> rax = monotonic microseconds
now_us:
    mov     edi, 1
    lea     rsi, [rip+vd_ts]
    mov     eax, SYS_CLOCK_GETTIME
    syscall
    mov     rax, [rip+vd_ts]
    imul    rax, rax, 1000000
    mov     rcx, rax
    mov     rax, [rip+vd_ts+8]
    xor     edx, edx
    mov     r8d, 1000
    div     r8
    add     rax, rcx
    ret

# =============================================================================
#  Statistics and settings
# =============================================================================
# vgd_stat(edi=k) -> xmm0: the last frame's 0 objects drawn through DAGs,
#   1 clusters drawn, 2 their triangles, 3 culled by the frustum, 4 occluded
#   in the last frame's depth (tested again), 5 of those drawn after all,
#   6 the objects' source triangles, 7 MB of cluster pages in memory, 8 the
#   budget (MB), 9 pages on their way, 10 pages read in all, 11 pages given
#   back in all, 12 refinements waiting for pages, 13 ms for the cuts, 14
#   streamed DAGs, 15 the error allowed (pixels), 16 (vgeo.view check) the
#   first object's cut crack-free (1, 0; -1: not all of it in view, or
#   not checking)
vgd_stat:
    xorps   xmm0, xmm0
    cmp     edi, 16
    je      .Lvs16
    ja      9f
    lea     rax, [rip+.Lvs_tab]
    movsxd  rcx, dword ptr [rax+rdi*4]
    add     rax, rcx
    jmp     rax
.Lvs_tab:
    .long .Lvs0-.Lvs_tab, .Lvs1-.Lvs_tab, .Lvs2-.Lvs_tab, .Lvs3-.Lvs_tab
    .long .Lvs4-.Lvs_tab, .Lvs5-.Lvs_tab, .Lvs6-.Lvs_tab, .Lvs7-.Lvs_tab
    .long .Lvs8-.Lvs_tab, .Lvs9-.Lvs_tab, .Lvs10-.Lvs_tab, .Lvs11-.Lvs_tab
    .long .Lvs12-.Lvs_tab, .Lvs13-.Lvs_tab, .Lvs14-.Lvs_tab, .Lvs15-.Lvs_tab
.Lvs0:  mov     eax, [rip+vs_inst]
        jmp     8f
.Lvs1:  mov     eax, [rip+vs_cl]
        jmp     8f
.Lvs2:  mov     eax, [rip+vs_tri]
        jmp     8f
.Lvs3:  mov     eax, [rip+vs_fru]
        jmp     8f
.Lvs4:  mov     eax, [rip+vs_occ]
        jmp     8f
.Lvs5:  mov     eax, [rip+vs_cl2]
        jmp     8f
.Lvs6:  mov     rax, [rip+vs_src]
        jmp     7f
.Lvs7:  mov     rax, [rip+vd_res]
        jmp     6f
.Lvs8:  mov     rax, [rip+vd_budget]
        jmp     6f
.Lvs9:  mov     eax, [rip+vd_nfl]
        jmp     8f
.Lvs10: mov     rax, [rip+vs_reqs]
        jmp     7f
.Lvs11: mov     rax, [rip+vs_evict]
        jmp     7f
.Lvs12: mov     eax, [rip+vs_fall]
        jmp     8f
.Lvs13: cvtsi2ss xmm0, dword ptr [rip+vs_us]
        divss   xmm0, [rip+f_thousand]
        ret
.Lvs14: mov     eax, [rip+vd_nreg]
        jmp     8f
.Lvs15: movss   xmm0, [rip+vd_px]
        ret
.Lvs16: mov     eax, [rip+vs_crack]
        jmp     8f
6:  cvtsi2ss xmm0, rax                  # bytes -> MB
    mulss   xmm0, [rip+f_mb]
    ret
7:  cvtsi2ss xmm0, rax
    ret
8:  cvtsi2ss xmm0, eax
9:  ret

OPERATOR op_vg_budget, "vgeo.budget", "Virtual Geometry Budget", do_vg_budget, flags=OPF_AI_SAFE, doc="Memory for streamed cluster pages, in MB (vgeo.budget 2048): past it the least recently used pages are given back"
OPERATOR op_vg_error, "vgeo.error", "Virtual Geometry Error", do_vg_error, flags=OPF_AI_SAFE, doc="The error a DAG cut may show, in pixels (vgeo.error 1)"
OPERATOR op_vg_view, "vgeo.view", "Show Clusters", do_vg_view, flags=OPF_AI_SAFE, doc="Colour the clusters drawn through cluster DAGs (toggles): vgeo.view clusters / shaded / off (the meshes themselves, not their DAGs) / check (the drawn cut, for cracks)"

# do_vg_budget - vgeo.budget <MB>
do_vg_budget:
    sub     rsp, 8
    call    vd_arg
    test    eax, eax
    jz      9f
    cvttss2si rax, xmm0
    cmp     rax, 1
    jge     1f
    mov     eax, 1
1:  shl     rax, 20
    mov     [rip+vd_budget], rax
    mov     rdi, [rip+vd_res]
    add     rdi, [rip+vd_flb]
    sub     rdi, rax
    jle     2f
    inc     dword ptr [rip+vd_frame]    # (nothing in use)
    call    vd_evict
2:  mov     dword ptr [rip+dirty], 1
9:  add     rsp, 8
    ret

# do_vg_error - vgeo.error <pixels>
do_vg_error:
    sub     rsp, 8
    call    vd_arg
    test    eax, eax
    jz      9f
    maxss   xmm0, [rip+f_tiny]
    movss   [rip+vd_px], xmm0
    mov     dword ptr [rip+dirty], 1
9:  add     rsp, 8
    ret

# do_vg_view - vgeo.view clusters | shaded | off (the meshes themselves) |
#   check (the first object's drawn cut, for cracks: vgstat(16)); without a
#   word: clusters coloured or not
do_vg_view:
    sub     rsp, 8
    mov     rsi, [rip+op_arg]
    test    rsi, rsi
    jz      5f
    call    im_next_word
    test    eax, eax
    jz      5f
    movzx   eax, word ptr [rip+im_word]
    cmp     ax, 0x6863                  # "ch"eck
    jne     1f
    xor     dword ptr [rip+vd_ck], 1
    jmp     9f
1:  xor     ecx, ecx
    cmp     al, 's'
    je      2f
    inc     ecx
    cmp     al, 'c'
    je      2f
    inc     ecx
    cmp     al, 'o'
    jne     5f
2:  mov     [rip+vd_view], ecx
    jmp     9f
5:  mov     eax, [rip+vd_view]          # toggled
    xor     eax, 1
    and     eax, 1
    mov     [rip+vd_view], eax
9:  mov     dword ptr [rip+dirty], 1
    add     rsp, 8
    ret

# vd_arg -> eax = 1 and xmm0 = the operator's number (0: none)
vd_arg:
    sub     rsp, 8
    mov     rsi, [rip+op_arg]
    test    rsi, rsi
    jz      8f
    call    im_next_word
    test    eax, eax
    jz      8f
    lea     rsi, [rip+im_word]
    lea     rdx, [rsi+rax]
    call    parse_float
    jmp     9f
8:  xor     eax, eax
9:  add     rsp, 8
    ret
