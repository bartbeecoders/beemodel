# =============================================================================
#  BeeModel - solid viewport rasterizer.
#
#  1. setup   : mesh vertices -> camera space; triangles are near-plane
#               clipped, projected and flat shaded (two-sided headlight)
#  2. binning : triangles are counted and filled into 64x64 tiles (two passes,
#               submission order preserved)
#  3. raster  : tiles are rasterized in parallel (parallel_for); 4 pixels per
#               step with SSE edge functions; 1/z depth buffer + object-ID
#               buffer
#  4. outline : a parallel post-pass draws the selection outline from the
#               ID buffer (selected = orange, active = gold)
#  The ID buffer also serves exact click picking (raster_pick).
# =============================================================================
.intel_syntax noprefix
.include "const.inc"

# exports
.globl raster_scene
.globl raster_pick
.globl vp_shading
.globl rs_depth
.globl rs_x0
.globl rs_y0
.globl rs_w
.globl rs_h
.globl rs_tri
.globl rs_tris
.globl rs_objs
.globl rs_nobjs
.globl rs_id
.globl rs_toff
.globl rs_entries
.globl rs_ntiles
.globl rs_ntx
.globl rs_nty
.globl rs_mode
.globl rs_noclear

.equ TILE_SHIFT,    4
.equ TILE,          1 << TILE_SHIFT
.equ TRI_SZ,        48              # x0 y0 x1 y1 x2 y2 w0 w1 w2 color id pad
.equ RO_CV,         0               # per-object record for the setup jobs
.equ RO_MESH,       8
.equ RO_BASE,       16
.equ RO_NTRIS,      20
.equ RO_ID,         24
.equ RO_COL,        28
.equ RO_OBJ,        32
.equ RO_PSEL,       40              # edit mode: selected-polygon flags
.equ RO_TFIRST,     48              # its first triangle / vertex in the mesh
.equ RO_VFIRST,     52              #   (a DAG cut's second batch)
.equ RO_SZ,         56
.equ VI_MESH,       16              # (vgdraw.s: an object drawn through its DAG)
.equ VI_REC,        24
.equ VI_V2,         176
.equ VI_T2,         180
.equ CHUNKS,    128
.equ BUF_ROUND,     0x100000
.equ MAP_ANON_PRIV, 0x22

.section .data
.align 4
vp_shading:     .long 0             # 0 = solid, 1 = wireframe, 2 = material,
                                    #  3 = rendered (live.s)

.section .bss
.align 8
rs_depth:       .skip 8
rs_id:          .skip 8
rs_tri:         .skip 8             # visibility buffer: triangle record + 1
rs_tdelta:      .skip 8             # rs_tri - rs_id
rs_cap:         .skip 8
rs_tris:        .skip 8
rs_toff:        .skip 8
rs_entries:     .skip 8
rs_sel:         .skip 8
rs_x0:          .skip 4
rs_y0:          .skip 4
rs_w:           .skip 4
rs_h:           .skip 4
rs_ntx:         .skip 4
rs_nty:         .skip 4
rs_ntris:       .skip 4
rs_cap_tris:    .skip 4
rs_mode:        .skip 4             # 0 = colour + id, 1 = id only
rs_nobjs:       .skip 4
rs_total:       .skip 4
rs_ntiles:      .skip 4
.align 8
rs_objs:        .skip 8
rs_cursor:      .skip 8
rs_counts:      .skip 8
rs_chunk:       .skip 4
rs_tbase:       .skip 4             # the batch's first output slot
rs_noclear:     .skip 4             # 1: a second batch over the first
rs_ccount:      .skip 4*CHUNKS

.section .rodata
.align 16
rf_absm:        .long 0x7fffffff, 0x7fffffff, 0x7fffffff, 0x7fffffff
rf_lane:        .float 0.5, 1.5, 2.5, 3.5
rf_four:        .float 4.0, 4.0, 4.0, 4.0
rf_lanei:       .long 0, 1, 2, 3
rf_one:         .float 1.0
rf_half:        .float 0.5
rf_amb:         .float 0.28
rf_dif:         .float 0.72
rf_eps:         .float 1.0e-6

.text

# -----------------------------------------------------------------------------
# ensure_buffers(edi=pixels) - persistent depth + id buffers (grow only)
# -----------------------------------------------------------------------------
rs_ensure:
    push    rbx
    mov     ebx, edi
    shl     rbx, 2
    cmp     rbx, [rip+rs_cap]
    jbe     9f
    add     rbx, BUF_ROUND-1
    and     rbx, -BUF_ROUND
    mov     rdi, [rip+rs_depth]
    test    rdi, rdi
    jz      1f
    mov     rsi, [rip+rs_cap]
    mov     eax, SYS_MUNMAP
    syscall
    mov     rdi, [rip+rs_id]
    mov     rsi, [rip+rs_cap]
    mov     eax, SYS_MUNMAP
    syscall
    mov     rdi, [rip+rs_tri]
    mov     rsi, [rip+rs_cap]
    mov     eax, SYS_MUNMAP
    syscall
1:  xor     edi, edi
    mov     rsi, rbx
    mov     edx, PROT_RW
    mov     r10d, MAP_ANON_PRIV
    mov     r8d, -1
    xor     r9d, r9d
    mov     eax, SYS_MMAP
    syscall
    mov     [rip+rs_depth], rax
    xor     edi, edi
    mov     rsi, rbx
    mov     edx, PROT_RW
    mov     r10d, MAP_ANON_PRIV
    mov     r8d, -1
    xor     r9d, r9d
    mov     eax, SYS_MMAP
    syscall
    mov     [rip+rs_id], rax
    xor     edi, edi
    mov     rsi, rbx
    mov     edx, PROT_RW
    mov     r10d, MAP_ANON_PRIV
    mov     r8d, -1
    xor     r9d, r9d
    mov     eax, SYS_MMAP
    syscall
    mov     [rip+rs_tri], rax
    sub     rax, [rip+rs_id]
    mov     [rip+rs_tdelta], rax
    mov     [rip+rs_cap], rbx
9:  pop     rbx
    ret

# -----------------------------------------------------------------------------
# raster_scene(edi=mode) - mesh objects of the scene into the current clip
# rectangle (= the viewport canvas, physical). Needs cam_setup.
# -----------------------------------------------------------------------------
raster_scene:
    push    rbx
    push    rbp
    push    r12
    push    r13
    push    r14
    push    r15
    sub     rsp, 8
    mov     [rip+rs_mode], edi
    mov     eax, [rip+clip_x0]
    mov     [rip+rs_x0], eax
    mov     ecx, [rip+clip_x1]
    sub     ecx, eax
    mov     [rip+rs_w], ecx
    mov     eax, [rip+clip_y0]
    mov     [rip+rs_y0], eax
    mov     edx, [rip+clip_y1]
    sub     edx, eax
    mov     [rip+rs_h], edx
    test    ecx, ecx
    jle     .Lrs_out
    test    edx, edx
    jle     .Lrs_out
    imul    ecx, edx
    mov     edi, ecx
    call    rs_ensure
    call    vgd_begin                   # objects drawn through cluster DAGs

    # ---- pass A: one record per mesh object, triangle numbering --------------
    xor     r12d, r12d                  # mesh objects
    xor     r13d, r13d                  # total triangles
    xor     ebx, ebx
1:  cmp     ebx, [rip+obj_count]
    jae     2f
    mov     edi, ebx
    call    obj_at
    cmp     dword ptr [rax+OB_TYPE], OT_MESH
    jne     11f
    test    dword ptr [rax+OB_FLAGS], OBF_HIDDEN|OBF_GROUND
    jnz     11f                         # (the Ground: a grid, viewport.s)
    lea     rcx, [rip+obj_list]         # (the sculpt object draws itself)
    mov     ecx, [rcx+rbx*4]
    cmp     ecx, [rip+sc_obj]
    je      11f
    inc     r12d
    mov     rdi, rax
    call    obj_eval
    mov     rdi, rax                    # (or the cut of its DAG)
    mov     esi, ebx
    call    vgd_swap
    add     r13d, [rax+ME_NTRIS]
11: inc     ebx
    jmp     1b
2:  mov     [rip+rs_nobjs], r12d
    mov     [rip+rs_total], r13d
    call    vgd_n                       # (records for a second batch too)
    lea     rdi, [rip+frame_arena]
    lea     esi, [r12+rax+1]
    imul    esi, esi, RO_SZ
    call    arena_alloc
    mov     [rip+rs_objs], rax
    test    rax, rax
    jz      .Lrs_out
    call    vgd_extra                   # (and its triangles)
    add     eax, r13d
    lea     eax, [rax*2+1]              # clipping can split a triangle in two
    mov     ecx, FRAME_ARENA_BYTES/2/TRI_SZ  # (at most half the frame arena:
    cmp     eax, ecx                    #  past that a huge mesh draws the
    cmova   eax, ecx                    #  triangles that fit)
    mov     [rip+rs_cap_tris], eax
    lea     rdi, [rip+frame_arena]
    imul    esi, eax, TRI_SZ
    call    arena_alloc
    mov     [rip+rs_tris], rax
    test    rax, rax
    jz      .Lrs_out
    mov     dword ptr [rip+rs_ntris], 0
    mov     r14, [rip+rs_objs]          # fill the records
    xor     r13d, r13d                  # running triangle base
    xor     ebx, ebx
3:  cmp     ebx, [rip+obj_count]
    jae     4f
    mov     edi, ebx
    call    obj_at
    cmp     dword ptr [rax+OB_TYPE], OT_MESH
    jne     31f
    test    dword ptr [rax+OB_FLAGS], OBF_HIDDEN|OBF_GROUND
    jnz     31f
    lea     rcx, [rip+obj_list]
    mov     ecx, [rcx+rbx*4]
    cmp     ecx, [rip+sc_obj]
    je      31f
    mov     [r14+RO_OBJ], rax
    xor     ecx, ecx                    # the edit object tints its selection
    cmp     dword ptr [rip+rs_mode], 0  # (colour pass only)
    jne     32f
    cmp     rax, [rip+edit_ro_obj]
    jne     32f
    mov     rcx, [rip+edit_psel]
32: mov     [r14+RO_PSEL], rcx
    mov     rdi, rax
    call    obj_eval
    mov     rdi, rax
    mov     esi, ebx
    call    vgd_swap
    mov     r15, rax
    mov     [rsp], rdx                  # (drawn through its DAG: the record)
    test    rdx, rdx
    jz      33f
    mov     [rdx+VI_REC], r14
33: mov     [r14+RO_MESH], r15
    mov     [r14+RO_BASE], r13d
    mov     qword ptr [r14+RO_TFIRST], 0
    mov     ecx, [r15+ME_NTRIS]
    mov     [r14+RO_NTRIS], ecx
    add     r13d, ecx
    lea     ecx, [rbx+1]
    mov     [r14+RO_ID], ecx
    mov     rdi, [r14+RO_OBJ]           # its material's colour
    call    mat_display_color
    mov     [r14+RO_COL], eax
    lea     rdi, [rip+frame_arena]      # camera-space vertices
    imul    esi, [r15+ME_NVERTS], 12
    cmp     qword ptr [rsp], 0
    je      34f
    imul    esi, [r15+ME_CAPV], 12      # (room for the second batch's)
34: call    arena_alloc
    mov     [r14+RO_CV], rax
    test    rax, rax
    jz      .Lrs_out
    add     r14, RO_SZ
31: inc     ebx
    jmp     3b
4:  mov     dword ptr [rip+rs_tbase], 0
    mov     dword ptr [rip+rs_noclear], 0
    call    rs_batch
    test    eax, eax
    jz      .Lrs_out
    # ---- objects drawn through DAGs: what the first batch uncovered ----------
    call    vgd_pass2
    test    eax, eax
    jz      .Lrs_post
    mov     r12d, [rip+rs_nobjs]        # their records after the first ones
    imul    r14d, r12d, RO_SZ
    add     r14, [rip+rs_objs]
    mov     r15, r14
    xor     r13d, r13d                  # its triangles
    xor     ebp, ebp                    # its records
    xor     ebx, ebx
5:  call    vgd_n
    cmp     ebx, eax
    jae     6f
    mov     edi, ebx
    call    vgd_inst
    inc     ebx
    mov     rsi, [rax+VI_REC]
    test    rsi, rsi
    jz      5b
    mov     rcx, [rax+VI_MESH]
    mov     edx, [rcx+ME_NTRIS]
    sub     edx, [rax+VI_T2]
    jbe     5b
    mov     rdi, r14
    mov     ecx, RO_SZ/8
    rep     movsq
    mov     [r14+RO_BASE], r13d
    mov     [r14+RO_NTRIS], edx
    add     r13d, edx
    mov     ecx, [rax+VI_T2]
    mov     [r14+RO_TFIRST], ecx
    mov     ecx, [rax+VI_V2]
    mov     [r14+RO_VFIRST], ecx
    add     r14, RO_SZ
    inc     ebp
    jmp     5b
6:  test    ebp, ebp
    jz      .Lrs_post
    mov     eax, [rip+rs_total]         # after the first batch's slots
    add     eax, eax
    mov     [rip+rs_tbase], eax
    mov     [rip+rs_objs], r15
    mov     [rip+rs_nobjs], ebp
    mov     [rip+rs_total], r13d
    mov     dword ptr [rip+rs_noclear], 1
    call    rs_batch
    imul    eax, r12d, RO_SZ            # all the records again
    sub     [rip+rs_objs], rax
    add     [rip+rs_nobjs], r12d
    mov     dword ptr [rip+rs_noclear], 0
    mov     dword ptr [rip+rs_tbase], 0
.Lrs_post:
    cmp     dword ptr [rip+rs_mode], 0
    jne     .Lrs_out
    cmp     dword ptr [rip+vp_shading], 3   # rendered: the GPU's image
    jne     2f                              #  (live.s), else as material
    call    lv_shade                        #  preview
    test    eax, eax
    jnz     1f
    call    preview_shade
    jmp     1f
2:  cmp     dword ptr [rip+vp_shading], 2   # material preview: shade
    jne     1f
    call    preview_shade
1:
    call    build_sel_table
    test    rax, rax
    jz      .Lrs_out
    lea     rdi, [rip+outline_rows]
    xor     esi, esi
    mov     edx, [rip+rs_h]
    mov     ecx, 32
    call    parallel_for
.Lrs_out:
    add     rsp, 8
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbp
    pop     rbx
    ret

# rs_batch -> eax = 1: the records [rs_objs, + rs_nobjs) with rs_total
#   triangles set up, binned and rasterized (from slot rs_tbase; over what
#   is there when rs_noclear); 0: out of frame memory
rs_batch:
    push    rbx
    push    rbp
    push    r12
    push    r13
    push    r14
    push    r15
    sub     rsp, 8
    # ---- pass B: vertices -> camera space (parallel over objects) ------------
    lea     rdi, [rip+job_verts]
    xor     esi, esi
    mov     edx, [rip+rs_nobjs]
    mov     ecx, 1
    call    parallel_for
    # ---- pass C: triangle setup (parallel over all triangles) -----------------
    mov     eax, [rip+rs_total]         # static chunks, compact output each
    add     eax, CHUNKS-1
    xor     edx, edx
    mov     ecx, CHUNKS
    div     ecx
    inc     eax
    mov     [rip+rs_chunk], eax
    lea     rdi, [rip+job_tris]
    xor     esi, esi
    mov     edx, CHUNKS
    mov     ecx, 1
    call    parallel_for
    # ---- binning: count, prefix sum, fill (count and fill in parallel) -------
    mov     eax, [rip+rs_w]
    add     eax, TILE-1
    shr     eax, TILE_SHIFT
    mov     [rip+rs_ntx], eax
    mov     ecx, [rip+rs_h]
    add     ecx, TILE-1
    shr     ecx, TILE_SHIFT
    mov     [rip+rs_nty], ecx
    imul    eax, ecx
    mov     r12d, eax                   # tiles
    mov     [rip+rs_ntiles], eax
    lea     rdi, [rip+frame_arena]
    lea     esi, [rax*8+8]              # offsets + cursors
    call    arena_alloc
    test    rax, rax
    jz      .Lrb_fail
    mov     [rip+rs_toff], rax
    lea     rdi, [rip+frame_arena]      # counts[chunk][tile]
    imul    esi, r12d, CHUNKS*4
    call    arena_alloc
    test    rax, rax
    jz      .Lrb_fail
    mov     [rip+rs_counts], rax
    mov     rdi, rax
    imul    ecx, r12d, CHUNKS
    xor     eax, eax
    rep     stosd
    lea     rdi, [rip+job_count]
    xor     esi, esi
    mov     edx, CHUNKS
    mov     ecx, 1
    call    parallel_for
    # prefix: tile-major, chunk order inside a tile (keeps triangle order)
    mov     rdx, [rip+rs_toff]
    mov     r8, [rip+rs_counts]
    xor     eax, eax                    # running offset
    xor     ecx, ecx                    # tile
71: cmp     ecx, r12d
    jae     73f
    mov     [rdx+rcx*4], eax
    xor     r9d, r9d                    # chunk
72: cmp     r9d, CHUNKS
    jae     721f
    mov     r10d, r9d
    imul    r10d, r12d
    add     r10d, ecx
    mov     r11d, [r8+r10*4]
    mov     [r8+r10*4], eax             # becomes this chunk's cursor
    add     eax, r11d
    inc     r9d
    jmp     72b
721:inc     ecx
    jmp     71b
73: mov     [rdx+r12*4], eax
    lea     rdi, [rip+frame_arena]
    lea     esi, [rax*4+4]
    call    arena_alloc
    test    rax, rax
    jz      .Lrb_fail
    mov     [rip+rs_entries], rax
    lea     rdi, [rip+job_fill]
    xor     esi, esi
    mov     edx, CHUNKS
    mov     ecx, 1
    call    parallel_for

    call    vgd_n                       # the tiles on the GPU (frames with
    mov     edi, eax                    #  DAG-drawn objects), else here
    call    gpu_rs_tiles
    test    eax, eax
    jnz     74f
    lea     rdi, [rip+raster_tiles]
    xor     esi, esi
    mov     edx, r12d
    mov     ecx, 1
    call    parallel_for
74: mov     eax, 1
    jmp     9f
.Lrb_fail:
    xor     eax, eax
9:  add     rsp, 8
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbp
    pop     rbx
    ret

# tri_tiles(edi=tri) -> eax = 1 if on screen; r8d..r11d = tile range (inclusive)
tri_tiles:
    imul    rax, rdi, TRI_SZ
    add     rax, [rip+rs_tris]
    cmp     dword ptr [rax+40], 0
    je      .Ltt_none
    movss   xmm0, [rax]                 # bbox
    movss   xmm1, xmm0
    minss   xmm0, [rax+8]
    maxss   xmm1, [rax+8]
    minss   xmm0, [rax+16]
    maxss   xmm1, [rax+16]
    movss   xmm2, [rax+4]
    movss   xmm3, xmm2
    minss   xmm2, [rax+12]
    maxss   xmm3, [rax+12]
    minss   xmm2, [rax+20]
    maxss   xmm3, [rax+20]
    cvttss2si r8d, xmm0
    cvttss2si r10d, xmm1
    cvttss2si r9d, xmm2
    cvttss2si r11d, xmm3
    xor     eax, eax
    test    r10d, r10d
    js      9f
    test    r11d, r11d
    js      9f
    cmp     r8d, [rip+rs_w]
    jge     9f
    cmp     r9d, [rip+rs_h]
    jge     9f
    xor     ecx, ecx
    cmp     r8d, ecx
    cmovl   r8d, ecx
    cmp     r9d, ecx
    cmovl   r9d, ecx
    mov     ecx, [rip+rs_w]
    dec     ecx
    cmp     r10d, ecx
    cmovg   r10d, ecx
    mov     ecx, [rip+rs_h]
    dec     ecx
    cmp     r11d, ecx
    cmovg   r11d, ecx
    shr     r8d, TILE_SHIFT
    shr     r9d, TILE_SHIFT
    shr     r10d, TILE_SHIFT
    shr     r11d, TILE_SHIFT
    mov     eax, 1
9:  ret
.Ltt_none:
    xor     eax, eax
    ret

# -----------------------------------------------------------------------------
# job_verts(ctx, esi=first object, edx=end) - camera-space positions with one
# combined matrix C = view * model per object
# -----------------------------------------------------------------------------
job_verts:
    push    rbx
    push    rbp
    push    r12
    push    r13
    push    r14
    push    r15
    sub     rsp, 104
    mov     ebx, esi
    mov     r12d, edx
.Ljv_obj:
    cmp     ebx, r12d
    jae     .Ljv_out
    imul    r13, rbx, RO_SZ
    add     r13, [rip+rs_objs]
    mov     rdi, [r13+RO_OBJ]
    mov     rsi, rsp                    # model matrix at [rsp]
    call    obj_matrix
    # C[r][c] = basis_r . M[.][c] ; C[r][3] = basis_r . (M[.][3] - eye)
    lea     r14, [rsp+48]               # C at [rsp+48]
    xor     ecx, ecx                    # row r: right, up, fwd
1:  lea     rax, [rip+right]
    cmp     ecx, 1
    jne     11f
    lea     rax, [rip+up]
11: cmp     ecx, 2
    jne     12f
    lea     rax, [rip+fwd]
12: xor     edx, edx                    # column
2:  movss   xmm0, [rax]
    mulss   xmm0, [rsp+rdx*4]
    movss   xmm1, [rax+4]
    mulss   xmm1, [rsp+16+rdx*4]
    addss   xmm0, xmm1
    movss   xmm1, [rax+8]
    mulss   xmm1, [rsp+32+rdx*4]
    addss   xmm0, xmm1
    imul    r8, rcx, 16
    add     r8, r14
    movss   [r8+rdx*4], xmm0
    inc     edx
    cmp     edx, 3
    jb      2b
    movss   xmm0, [rsp+12]              # translation
    subss   xmm0, [rip+eye]
    mulss   xmm0, [rax]
    movss   xmm1, [rsp+28]
    subss   xmm1, [rip+eye+4]
    mulss   xmm1, [rax+4]
    addss   xmm0, xmm1
    movss   xmm1, [rsp+44]
    subss   xmm1, [rip+eye+8]
    mulss   xmm1, [rax+8]
    addss   xmm0, xmm1
    movss   [r8+12], xmm0
    inc     ecx
    cmp     ecx, 3
    jb      1b
    mov     r15, [r13+RO_MESH]
    mov     eax, [r13+RO_VFIRST]        # (a second batch: its vertices)
    imul    rax, rax, 12
    mov     rsi, [r15+ME_POS]
    add     rsi, rax
    mov     rdi, [r13+RO_CV]
    add     rdi, rax
    mov     ecx, [r15+ME_NVERTS]
    sub     ecx, [r13+RO_VFIRST]
3:  test    ecx, ecx
    jz      .Ljv_next
    movss   xmm3, [rsi]
    movss   xmm4, [rsi+4]
    movss   xmm5, [rsi+8]
    xor     edx, edx
4:  imul    r8, rdx, 16
    add     r8, r14
    movss   xmm0, [r8]
    mulss   xmm0, xmm3
    movss   xmm1, [r8+4]
    mulss   xmm1, xmm4
    addss   xmm0, xmm1
    movss   xmm1, [r8+8]
    mulss   xmm1, xmm5
    addss   xmm0, xmm1
    addss   xmm0, [r8+12]
    movss   [rdi+rdx*4], xmm0
    inc     edx
    cmp     edx, 3
    jb      4b
    add     rsi, 12
    add     rdi, 12
    dec     ecx
    jmp     3b
.Ljv_next:
    inc     ebx
    jmp     .Ljv_obj
.Ljv_out:
    add     rsp, 104
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbp
    pop     rbx
    ret

# job_tris(ctx, esi=first chunk, edx=end) - triangles of a static chunk; the
# kept ones are written compactly from slot 2 * first triangle of the chunk
job_tris:
    push    rbx
    push    rbp
    push    r12
    push    r13
    push    r14
    push    r15
    sub     rsp, 24
    mov     [rsp], esi
    mov     [rsp+4], edx
.Ljt_chunk:
    mov     eax, [rsp]
    cmp     eax, [rsp+4]
    jae     .Ljt_out
    mov     ebx, eax                    # t = first triangle of the chunk
    imul    ebx, [rip+rs_chunk]
    mov     r12d, ebx
    add     r12d, [rip+rs_chunk]
    cmp     r12d, [rip+rs_total]
    cmova   r12d, [rip+rs_total]
    lea     ebp, [rbx+rbx]              # output cursor
    add     ebp, [rip+rs_tbase]
    mov     [rsp+8], ebp
    xor     ecx, ecx                    # binary search: last object with base <= t
    mov     edx, [rip+rs_nobjs]
1:  mov     eax, edx
    sub     eax, ecx
    cmp     eax, 1
    jbe     2f
    lea     eax, [rcx+rdx]
    shr     eax, 1
    imul    r8, rax, RO_SZ
    add     r8, [rip+rs_objs]
    cmp     [r8+RO_BASE], ebx
    ja      11f
    mov     ecx, eax
    jmp     1b
11: mov     edx, eax
    jmp     1b
2:  mov     r13d, ecx                   # object index
.Ljt_loop:
    cmp     ebx, r12d
    jae     .Ljt_done
    cmp     r13d, [rip+rs_nobjs]
    jae     .Ljt_done
    imul    r14, r13, RO_SZ
    add     r14, [rip+rs_objs]
    mov     eax, ebx
    sub     eax, [r14+RO_BASE]
    cmp     eax, [r14+RO_NTRIS]
    jb      3f
    inc     r13d                        # past this object's triangles
    jmp     .Ljt_loop
3:  add     eax, [r14+RO_TFIRST]        # (in its mesh)
    mov     r15, [r14+RO_MESH]
    mov     [rsp+20], eax               # the local triangle
    mov     ecx, [r14+RO_COL]
    mov     [rsp+16], ecx
    mov     rcx, [r14+RO_PSEL]          # selected polygon (edit mode)?
    test    rcx, rcx
    jz      31f
    mov     rdx, [r15+ME_TPOLY]
    mov     edx, [rdx+rax*4]
    cmp     byte ptr [rcx+rdx], 0
    je      31f
    mov     dword ptr [rsp+16], COL_FACE_SEL
31: cmp     dword ptr [rsp+16], COL_FACE_SEL  # vertex colours tint it
    je      311f
    cmp     dword ptr [rip+vp_on], 2    # (weight paint: the weights' heat)
    jne     312f
    mov     rdi, r15
    mov     esi, [rsp+20]
    call    wp_tint
    test    eax, eax
    js      312f
    mov     [rsp+16], eax
    mov     eax, [rsp+20]
    jmp     311f
312:mov     eax, [rsp+20]
    cmp     qword ptr [r15+ME_VCOL], 0
    je      311f
    mov     rdi, r15
    mov     esi, [rsp+20]
    mov     edx, [rsp+16]
    call    vcol_avg
    mov     [rsp+16], eax
    mov     eax, [rsp+20]
311:mov     rcx, [r15+ME_TRIS]
    imul    rax, rax, 12
    mov     edi, [rcx+rax]
    mov     esi, [rcx+rax+4]
    mov     edx, [rcx+rax+8]
    mov     r8, [r14+RO_CV]
    imul    rdi, rdi, 12
    imul    rsi, rsi, 12
    imul    rdx, rdx, 12
    add     rdi, r8
    add     rsi, r8
    add     rdx, r8
    mov     ecx, [rsp+16]
    mov     r8d, [r14+RO_ID]
    mov     r9d, ebp
    call    setup_tri                   # eax = triangles kept (0..2)
    test    eax, eax                    # their records: the local triangle
    jz      34f
    imul    rcx, rbp, TRI_SZ
    add     rcx, [rip+rs_tris]
    mov     edx, [rsp+20]
    mov     [rcx+44], edx
    cmp     eax, 2
    jb      34f
    mov     [rcx+TRI_SZ+44], edx
34: add     ebp, eax
    inc     ebx
    jmp     .Ljt_loop
.Ljt_done:
    mov     eax, [rsp]                  # kept count of this chunk
    sub     ebp, [rsp+8]
    lea     rcx, [rip+rs_ccount]
    mov     [rcx+rax*4], ebp
    inc     dword ptr [rsp]
    jmp     .Ljt_chunk
.Ljt_out:
    add     rsp, 24
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbp
    pop     rbx
    ret

# job_count / job_fill (ctx, esi=first chunk, edx=end) - tile binning; each
# chunk owns one row of counts[chunk][tile], so no atomics are needed
job_count:
    xor     eax, eax
    jmp     bin_chunks
job_fill:
    mov     eax, 1
bin_chunks:
    push    rbx
    push    rbp
    push    r12
    push    r13
    push    r14
    push    r15
    sub     rsp, 8
    mov     [rsp], eax                  # 0 = count, 1 = fill
    mov     r14d, esi                   # chunk
    mov     r15d, edx
.Lbc_chunk:
    cmp     r14d, r15d
    jae     .Lbc_out
    mov     ebx, r14d                   # kept triangles of this chunk
    imul    ebx, [rip+rs_chunk]
    add     ebx, ebx
    add     ebx, [rip+rs_tbase]
    lea     rax, [rip+rs_ccount]
    mov     r12d, [rax+r14*4]
    add     r12d, ebx
    mov     eax, r14d                   # this chunk's row
    imul    eax, [rip+rs_ntiles]
    mov     r13, [rip+rs_counts]
    lea     r13, [r13+rax*4]
    mov     rbp, [rip+rs_entries]
1:  cmp     ebx, r12d
    jae     .Lbc_next
    mov     edi, ebx
    call    tri_tiles
    test    eax, eax
    jz      5f
2:  cmp     r9d, r11d
    jg      5f
    mov     ecx, r8d
3:  cmp     ecx, r10d
    jg      4f
    mov     eax, r9d
    imul    eax, [rip+rs_ntx]
    add     eax, ecx
    cmp     dword ptr [rsp], 0
    jne     31f
    inc     dword ptr [r13+rax*4]       # count
    jmp     32f
31: mov     edx, [r13+rax*4]            # fill at the cursor
    inc     dword ptr [r13+rax*4]
    mov     [rbp+rdx*4], ebx
32: inc     ecx
    jmp     3b
4:  inc     r9d
    jmp     2b
5:  inc     ebx
    jmp     1b
.Lbc_next:
    inc     r14d
    jmp     .Lbc_chunk
.Lbc_out:
    add     rsp, 8
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbp
    pop     rbx
    ret

# -----------------------------------------------------------------------------
# setup_tri(rdi, rsi, rdx = camera-space vertices, ecx=base colour, r8d=id,
#           r9d=triangle number) - flat shade, near-plane clip, emit into the
#   fixed output slots 2t and 2t+1 (id 0 = empty slot): no atomics needed
# -----------------------------------------------------------------------------
setup_tri:
    push    rbx
    push    r12
    push    r13
    sub     rsp, 64                     # [rsp] colour, [rsp+4] id, [rsp+8] slot,
    mov     [rsp+4], r8d                # [rsp+16] clip polygon
    mov     [rsp+8], r9d                # next output slot
    mov     dword ptr [rsp+12], 0       # kept
    mov     r13d, ecx
    # flat normal n = (p1-p0) x (p2-p0); brightness = amb + dif * |n.z| / |n|
    movss   xmm0, [rsi]
    subss   xmm0, [rdi]                 # e1
    movss   xmm1, [rsi+4]
    subss   xmm1, [rdi+4]
    movss   xmm2, [rsi+8]
    subss   xmm2, [rdi+8]
    movss   xmm3, [rdx]
    subss   xmm3, [rdi]                 # e2
    movss   xmm4, [rdx+4]
    subss   xmm4, [rdi+4]
    movss   xmm5, [rdx+8]
    subss   xmm5, [rdi+8]
    movss   xmm6, xmm1                  # nx = e1y*e2z - e1z*e2y
    mulss   xmm6, xmm5
    movss   xmm7, xmm2
    mulss   xmm7, xmm4
    subss   xmm6, xmm7
    movss   xmm8, xmm2                  # ny = e1z*e2x - e1x*e2z
    mulss   xmm8, xmm3
    movss   xmm7, xmm0
    mulss   xmm7, xmm5
    subss   xmm8, xmm7
    movss   xmm9, xmm0                  # nz = e1x*e2y - e1y*e2x
    mulss   xmm9, xmm4
    movss   xmm7, xmm1
    mulss   xmm7, xmm3
    subss   xmm9, xmm7
    mulss   xmm6, xmm6
    mulss   xmm8, xmm8
    addss   xmm6, xmm8
    movss   xmm7, xmm9
    mulss   xmm7, xmm7
    addss   xmm6, xmm7
    sqrtss  xmm6, xmm6
    maxss   xmm6, [rip+rf_eps]
    andps   xmm9, [rip+rf_absm]
    divss   xmm9, xmm6                  # |cos|
    mulss   xmm9, [rip+rf_dif]
    addss   xmm9, [rip+rf_amb]
    xor     r8d, r8d                    # shade the base colour
    mov     ecx, 16
1:  mov     r9d, r13d
    shr     r9d, cl
    and     r9d, 255
    cvtsi2ss xmm0, r9d
    mulss   xmm0, xmm9
    cvttss2si r9d, xmm0
    cmp     r9d, 255
    jbe     2f
    mov     r9d, 255
2:  shl     r9d, cl
    or      r8d, r9d
    sub     ecx, 8
    jns     1b
    mov     [rsp], r8d
    # near-plane clipping into the local polygon (Sutherland-Hodgman)
    lea     r12, [rsp+16]
    xor     ebx, ebx
    push    rdi
    push    rsi
    push    rdx
    mov     r8, rdi                     # edges p0->p1, p1->p2, p2->p0
    mov     r9, rsi
    call    clip_edge
    mov     r8, [rsp+8]
    mov     r9, [rsp]
    call    clip_edge
    mov     r8, [rsp]
    mov     r9, [rsp+16]
    call    clip_edge
    add     rsp, 24
    cmp     ebx, 3
    jb      9f
    lea     rdi, [r12]                  # fan: (0,1,2) and (0,2,3)
    lea     rsi, [r12+12]
    lea     rdx, [r12+24]
    mov     ecx, [rsp]
    mov     r8d, [rsp+4]
    mov     r9d, [rsp+8]
    call    emit_tri
    add     [rsp+8], eax
    add     [rsp+12], eax
    cmp     ebx, 4
    jb      9f
    lea     rdi, [r12]
    lea     rsi, [r12+24]
    lea     rdx, [r12+36]
    mov     ecx, [rsp]
    mov     r8d, [rsp+4]
    mov     r9d, [rsp+8]
    call    emit_tri
    add     [rsp+12], eax
9:  mov     eax, [rsp+12]
    add     rsp, 64
    pop     r13
    pop     r12
    pop     rbx
    ret

# clip_edge(r8=a, r9=b) - append to the polygon at r12 (count ebx): a if
# inside, the crossing if the edge crosses the near plane
clip_edge:
    movss   xmm0, [r8+8]
    movss   xmm1, [r9+8]
    movss   xmm2, [rip+f_near]
    comiss  xmm0, xmm2
    jb      1f
    lea     rax, [rbx+rbx*2]            # a inside: keep it
    mov     rcx, [r8]
    mov     [r12+rax*4], rcx
    mov     ecx, [r8+8]
    mov     [r12+rax*4+8], ecx
    inc     ebx
    comiss  xmm1, xmm2
    jae     9f
    jmp     2f
1:  comiss  xmm1, xmm2
    jb      9f
2:  movss   xmm3, xmm2                  # crossing: t = (near - za) / (zb - za)
    subss   xmm3, xmm0
    subss   xmm1, xmm0
    divss   xmm3, xmm1
    lea     rax, [rbx+rbx*2]
    movss   xmm4, [r9]
    subss   xmm4, [r8]
    mulss   xmm4, xmm3
    addss   xmm4, [r8]
    movss   [r12+rax*4], xmm4
    movss   xmm4, [r9+4]
    subss   xmm4, [r8+4]
    mulss   xmm4, xmm3
    addss   xmm4, [r8+4]
    movss   [r12+rax*4+4], xmm4
    movss   [r12+rax*4+8], xmm2
    inc     ebx
9:  ret

# emit_tri(rdi, rsi, rdx = camera-space vertices in front, ecx=colour,
#          r8d=id, r9d=output slot)
emit_tri:
    mov     eax, r9d
    cmp     eax, [rip+rs_cap_tris]
    jae     9f
    imul    rax, rax, TRI_SZ
    add     rax, [rip+rs_tris]
    mov     [rax+36], ecx
    mov     [rax+40], r8d
    mov     r8, rdi
    xor     ecx, ecx
    call    emit_vert
    mov     r8, rsi
    mov     ecx, 1
    call    emit_vert
    mov     r8, rdx
    mov     ecx, 2
    call    emit_vert
    # cull: off the canvas, or so small that no pixel centre is inside
    movss   xmm0, [rax]
    movss   xmm1, xmm0
    minss   xmm0, [rax+8]
    maxss   xmm1, [rax+8]
    minss   xmm0, [rax+16]
    maxss   xmm1, [rax+16]
    movss   xmm2, [rax+4]
    movss   xmm3, xmm2
    minss   xmm2, [rax+12]
    maxss   xmm3, [rax+12]
    minss   xmm2, [rax+20]
    maxss   xmm3, [rax+20]
    movss   xmm4, [rip+rf_half]
    subss   xmm0, xmm4                  # first pixel centre >= min:  ceil(min-0.5)
    roundss xmm0, xmm0, 10
    subss   xmm1, xmm4                  # last pixel centre <= max:  floor(max-0.5)
    roundss xmm1, xmm1, 9
    comiss  xmm0, xmm1
    ja      8f
    subss   xmm2, xmm4
    roundss xmm2, xmm2, 10
    subss   xmm3, xmm4
    roundss xmm3, xmm3, 9
    comiss  xmm2, xmm3
    ja      8f
    xorps   xmm4, xmm4
    comiss  xmm1, xmm4
    jb      8f
    comiss  xmm3, xmm4
    jb      8f
    cvtsi2ss xmm4, dword ptr [rip+rs_w]
    comiss  xmm0, xmm4
    jae     8f
    cvtsi2ss xmm4, dword ptr [rip+rs_h]
    comiss  xmm2, xmm4
    jae     8f
    mov     eax, 1
    ret
8:  xor     eax, eax
    ret
9:  xor     eax, eax
    ret
# emit_vert(r8=camera-space vertex, ecx=slot, rax=record) - canvas-relative px
emit_vert:
    movss   xmm2, [rip+rf_one]
    divss   xmm2, [r8+8]                # w = 1/z
    movss   [rax+24+rcx*4], xmm2
    mulss   xmm2, [rip+vp_focal]
    movss   xmm0, [r8]
    mulss   xmm0, xmm2
    addss   xmm0, [rip+vp_cx]
    cvtsi2ss xmm1, dword ptr [rip+rs_x0]
    subss   xmm0, xmm1
    movss   [rax+rcx*8], xmm0
    movss   xmm0, [r8+4]
    mulss   xmm0, xmm2
    movss   xmm1, [rip+vp_cy]
    subss   xmm1, xmm0
    cvtsi2ss xmm0, dword ptr [rip+rs_y0]
    subss   xmm1, xmm0
    movss   [rax+rcx*8+4], xmm1
    ret
# -----------------------------------------------------------------------------
# raster_tiles(rdi=ctx, esi=first tile, edx=end) - job body
# -----------------------------------------------------------------------------
raster_tiles:
    push    rbx
    push    r12
    mov     ebx, esi
    mov     r12d, edx
1:  cmp     ebx, r12d
    jae     9f
    mov     edi, ebx
    call    raster_tile
    inc     ebx
    jmp     1b
9:  pop     r12
    pop     rbx
    ret

# raster_tile(edi=tile)
raster_tile:
    push    rbx
    push    rbp
    push    r12
    push    r13
    push    r14
    push    r15
    sub     rsp, 24
    mov     eax, edi
    xor     edx, edx
    div     dword ptr [rip+rs_ntx]
    mov     r12d, edx
    shl     r12d, TILE_SHIFT                     # px0
    mov     r13d, eax
    shl     r13d, TILE_SHIFT                     # py0
    lea     r14d, [r12+TILE]
    cmp     r14d, [rip+rs_w]
    cmovg   r14d, [rip+rs_w]            # px1
    lea     r15d, [r13+TILE]
    cmp     r15d, [rip+rs_h]
    cmovg   r15d, [rip+rs_h]            # py1
    mov     [rsp], edi
    # clear depth and id for the tile (not under a second batch)
    mov     ebx, r13d
    cmp     dword ptr [rip+rs_noclear], 0
    jne     2f
1:  cmp     ebx, r15d
    jae     2f
    mov     eax, ebx
    imul    eax, [rip+rs_w]
    add     eax, r12d
    mov     ecx, r14d
    sub     ecx, r12d
    mov     rdi, [rip+rs_depth]
    lea     rdi, [rdi+rax*4]
    push    rax
    push    rcx
    xor     eax, eax
    rep     stosd
    pop     rcx
    pop     rax
    mov     rdi, [rip+rs_id]
    lea     rdi, [rdi+rax*4]
    push    rax
    push    rcx
    xor     eax, eax
    rep     stosd
    pop     rcx
    pop     rax
    mov     rdi, [rip+rs_tri]
    lea     rdi, [rdi+rax*4]
    xor     eax, eax
    rep     stosd
    inc     ebx
    jmp     1b
2:  mov     edi, [rsp]                  # triangles of this tile
    mov     rax, [rip+rs_toff]
    mov     ebx, [rax+rdi*4]
    mov     ebp, [rax+rdi*4+4]
3:  cmp     ebx, ebp
    jae     9f
    mov     rax, [rip+rs_entries]
    mov     eax, [rax+rbx*4]
    imul    rdi, rax, TRI_SZ
    add     rdi, [rip+rs_tris]
    mov     esi, r12d
    mov     edx, r13d
    mov     ecx, r14d
    mov     r8d, r15d
    call    raster_tri
    inc     ebx
    jmp     3b
9:  add     rsp, 24
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbp
    pop     rbx
    ret

# -----------------------------------------------------------------------------
# raster_tri(rdi=triangle, esi=x0, edx=y0, ecx=x1, r8d=y1 clip rect) - 4 px/step
# -----------------------------------------------------------------------------
raster_tri:
    push    rbx
    push    rbp
    push    r12
    push    r13
    push    r14
    push    r15
    mov     rax, rsp                    # 16-byte aligned frame for SSE spills
    sub     rsp, 208
    and     rsp, -16
    mov     [rsp+192], rax
    mov     rbx, rdi
    mov     r9, rdx                     # record index + 1 (visibility buffer;
    mov     r10, rcx                    #  the clip rect stays in edx / ecx)
    mov     rax, rdi
    sub     rax, [rip+rs_tris]
    xor     edx, edx
    mov     ecx, TRI_SZ
    div     rcx
    inc     eax
    mov     [rsp+152], eax
    mov     rdx, r9
    mov     rcx, r10
    # local copies (v1/v2 swapped for clockwise triangles)
    movss   xmm0, [rbx]
    movss   xmm1, [rbx+4]
    movss   xmm2, [rbx+8]
    movss   xmm3, [rbx+12]
    movss   xmm4, [rbx+16]
    movss   xmm5, [rbx+20]
    movss   xmm6, [rbx+24]
    movss   xmm7, [rbx+28]
    movss   xmm8, [rbx+32]
    # area = (x1-x0)(y2-y0) - (y1-y0)(x2-x0)
    movss   xmm9, xmm2
    subss   xmm9, xmm0
    movss   xmm10, xmm5
    subss   xmm10, xmm1
    mulss   xmm9, xmm10
    movss   xmm10, xmm3
    subss   xmm10, xmm1
    movss   xmm11, xmm4
    subss   xmm11, xmm0
    mulss   xmm10, xmm11
    subss   xmm9, xmm10
    xorps   xmm10, xmm10
    comiss  xmm9, xmm10
    ja      1f
    jb      0f
    jmp     .Lrt_out                    # degenerate
0:  movss   xmm10, xmm2                 # swap v1 <-> v2
    movss   xmm2, xmm4
    movss   xmm4, xmm10
    movss   xmm10, xmm3
    movss   xmm3, xmm5
    movss   xmm5, xmm10
    movss   xmm10, xmm7
    movss   xmm7, xmm8
    movss   xmm8, xmm10
    xorps   xmm10, xmm10
    subss   xmm10, xmm9
    movss   xmm9, xmm10
1:  movss   xmm10, [rip+rf_one]
    divss   xmm10, xmm9                 # 1 / area
    # pixel bounds within the clip rect
    movss   xmm11, xmm0
    minss   xmm11, xmm2
    minss   xmm11, xmm4
    cvttss2si r12d, xmm11
    movss   xmm11, xmm0
    maxss   xmm11, xmm2
    maxss   xmm11, xmm4
    cvttss2si r13d, xmm11
    inc     r13d                        # exclusive
    movss   xmm11, xmm1
    minss   xmm11, xmm3
    minss   xmm11, xmm5
    cvttss2si r14d, xmm11
    movss   xmm11, xmm1
    maxss   xmm11, xmm3
    maxss   xmm11, xmm5
    cvttss2si r15d, xmm11
    inc     r15d
    cmp     r12d, esi
    cmovl   r12d, esi
    cmp     r14d, edx
    cmovl   r14d, edx
    cmp     r13d, ecx
    cmovg   r13d, ecx
    cmp     r15d, r8d
    cmovg   r15d, r8d
    cmp     r12d, r13d
    jge     .Lrt_out
    cmp     r14d, r15d
    jge     .Lrt_out
    # edge equations: Ei(p) = Ai*px + Bi*py + Ci
    #   E0 (v1->v2): A = y1-y2, B = x2-x1, C = x1*y2 - x2*y1
    #   E1 (v2->v0): A = y2-y0, B = x0-x2, C = x2*y0 - x0*y2
    #   E2 (v0->v1): A = y0-y1, B = x1-x0, C = x0*y1 - x1*y0
    movss   xmm11, xmm3
    subss   xmm11, xmm5
    movss   [rsp], xmm11                # A0
    movss   xmm11, xmm4
    subss   xmm11, xmm2
    movss   [rsp+4], xmm11              # B0
    movss   xmm11, xmm2
    mulss   xmm11, xmm5
    movss   xmm12, xmm4
    mulss   xmm12, xmm3
    subss   xmm11, xmm12
    movss   [rsp+8], xmm11              # C0
    movss   xmm11, xmm5
    subss   xmm11, xmm1
    movss   [rsp+12], xmm11             # A1
    movss   xmm11, xmm0
    subss   xmm11, xmm4
    movss   [rsp+16], xmm11             # B1
    movss   xmm11, xmm4
    mulss   xmm11, xmm1
    movss   xmm12, xmm0
    mulss   xmm12, xmm5
    subss   xmm11, xmm12
    movss   [rsp+20], xmm11             # C1
    movss   xmm11, xmm1
    subss   xmm11, xmm3
    movss   [rsp+24], xmm11             # A2
    movss   xmm11, xmm2
    subss   xmm11, xmm0
    movss   [rsp+28], xmm11             # B2
    movss   xmm11, xmm0
    mulss   xmm11, xmm3
    movss   xmm12, xmm2
    mulss   xmm12, xmm1
    subss   xmm11, xmm12
    movss   [rsp+32], xmm11             # C2
    # per-vertex 1/z scaled by 1/area (so w = sum Ei * wi')
    mulss   xmm6, xmm10
    mulss   xmm7, xmm10
    mulss   xmm8, xmm10
    shufps  xmm6, xmm6, 0
    shufps  xmm7, xmm7, 0
    shufps  xmm8, xmm8, 0
    movaps  [rsp+48], xmm6
    movaps  [rsp+64], xmm7
    movaps  [rsp+80], xmm8
    # 4-pixel steps: dE = 4*A broadcast
    movss   xmm11, [rsp]
    shufps  xmm11, xmm11, 0
    mulps   xmm11, [rip+rf_four]
    movaps  [rsp+96], xmm11
    movss   xmm11, [rsp+12]
    shufps  xmm11, xmm11, 0
    mulps   xmm11, [rip+rf_four]
    movaps  [rsp+112], xmm11
    movss   xmm11, [rsp+24]
    shufps  xmm11, xmm11, 0
    mulps   xmm11, [rip+rf_four]
    movaps  [rsp+128], xmm11
    mov     eax, [rbx+36]
    mov     [rsp+144], eax              # colour
    mov     eax, [rbx+40]
    mov     [rsp+148], eax              # id
    mov     ebp, r14d                   # y
.Lrt_row:
    cmp     ebp, r15d
    jge     .Lrt_out
    # E at (x0 + lane + 0.5, y + 0.5) for the four lanes
    cvtsi2ss xmm0, ebp
    addss   xmm0, [rip+rf_half]         # py
    cvtsi2ss xmm1, r12d
    shufps  xmm1, xmm1, 0
    addps   xmm1, [rip+rf_lane]         # px lanes
    movss   xmm2, [rsp+4]               # E0 = A0*px + (B0*py + C0)
    mulss   xmm2, xmm0
    addss   xmm2, [rsp+8]
    shufps  xmm2, xmm2, 0
    movss   xmm3, [rsp]
    shufps  xmm3, xmm3, 0
    mulps   xmm3, xmm1
    addps   xmm2, xmm3                  # E0
    movss   xmm3, [rsp+16]
    mulss   xmm3, xmm0
    addss   xmm3, [rsp+20]
    shufps  xmm3, xmm3, 0
    movss   xmm4, [rsp+12]
    shufps  xmm4, xmm4, 0
    mulps   xmm4, xmm1
    addps   xmm3, xmm4                  # E1
    movss   xmm4, [rsp+28]
    mulss   xmm4, xmm0
    addss   xmm4, [rsp+32]
    shufps  xmm4, xmm4, 0
    movss   xmm5, [rsp+24]
    shufps  xmm5, xmm5, 0
    mulps   xmm5, xmm1
    addps   xmm4, xmm5                  # E2
    mov     eax, ebp                    # row bases
    imul    eax, [rip+rs_w]
    mov     r8, rax                     # buffer index of (0, y)
    mov     eax, [rip+rs_y0]
    add     eax, ebp
    imul    eax, [rip+fb_w]
    add     eax, [rip+rs_x0]
    mov     r9, rax                     # framebuffer index of (0, y)
    mov     r10d, r12d                  # x
.Lrt_px:
    cmp     r10d, r13d
    jge     .Lrt_nextrow
    xorps   xmm9, xmm9                  # inside = all Ei >= 0
    movaps  xmm5, xmm2
    cmpps   xmm5, xmm9, 5               # nlt: E0 >= 0
    movaps  xmm6, xmm3
    cmpps   xmm6, xmm9, 5
    andps   xmm5, xmm6
    movaps  xmm6, xmm4
    cmpps   xmm6, xmm9, 5
    andps   xmm5, xmm6
    movmskps eax, xmm5
    mov     ecx, r13d                   # lanes past the right edge are off
    sub     ecx, r10d
    cmp     ecx, 4
    jae     1f
    mov     edx, 1
    shl     edx, cl
    dec     edx
    and     eax, edx
1:  test    eax, eax
    jz      .Lrt_step
    # w = E0*w0' + E1*w1' + E2*w2'
    movaps  xmm6, xmm2
    mulps   xmm6, [rsp+48]
    movaps  xmm7, xmm3
    mulps   xmm7, [rsp+64]
    addps   xmm6, xmm7
    movaps  xmm7, xmm4
    mulps   xmm7, [rsp+80]
    addps   xmm6, xmm7
    movaps  [rsp+160], xmm6
    mov     r11, [rip+rs_depth]
    lea     rcx, [r8+r10]
    lea     r11, [r11+rcx*4]            # depth at x
    mov     rdx, [rip+rs_id]
    lea     rdx, [rdx+rcx*4]
    mov     rcx, [rip+fb_ptr]
    lea     rdi, [r9+r10]
    lea     rcx, [rcx+rdi*4]            # framebuffer at x
    xor     edi, edi                    # lane
2:  bt      eax, edi
    jnc     3f
    movss   xmm7, [rsp+160+rdi*4]
    comiss  xmm7, [r11+rdi*4]
    jbe     3f
    movss   [r11+rdi*4], xmm7
    mov     esi, [rsp+148]
    mov     [rdx+rdi*4], esi
    mov     esi, [rsp+152]              # its triangle
    add     rdx, [rip+rs_tdelta]
    mov     [rdx+rdi*4], esi
    sub     rdx, [rip+rs_tdelta]
    cmp     dword ptr [rip+rs_mode], 0
    jne     3f
    mov     esi, [rsp+144]
    mov     [rcx+rdi*4], esi
3:  inc     edi
    cmp     edi, 4
    jb      2b
.Lrt_step:
    addps   xmm2, [rsp+96]
    addps   xmm3, [rsp+112]
    addps   xmm4, [rsp+128]
    add     r10d, 4
    jmp     .Lrt_px
.Lrt_nextrow:
    inc     ebp
    jmp     .Lrt_row
.Lrt_out:
    mov     rsp, [rsp+192]
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbp
    pop     rbx
    ret

# -----------------------------------------------------------------------------
# Selection outline
# -----------------------------------------------------------------------------
# build_sel_table -> rax = byte per id (0 none, 1 selected, 2 active)
build_sel_table:
    push    rbx
    lea     rdi, [rip+frame_arena]
    mov     esi, [rip+obj_count]
    add     esi, 2
    call    arena_alloc
    mov     [rip+rs_sel], rax
    test    rax, rax
    jz      9f
    mov     byte ptr [rax], 0
    xor     ebx, ebx
1:  cmp     ebx, [rip+obj_count]
    jae     8f
    mov     edi, ebx
    call    obj_at
    xor     ecx, ecx
    test    dword ptr [rax+OB_FLAGS], OBF_SELECTED
    jz      2f
    mov     ecx, 1
    lea     rdx, [rip+obj_list]
    mov     edx, [rdx+rbx*4]
    cmp     edx, [rip+active_obj]
    jne     2f
    mov     ecx, 2
2:  mov     rax, [rip+rs_sel]
    mov     [rax+rbx+1], cl
    inc     ebx
    jmp     1b
8:  mov     rax, [rip+rs_sel]
9:  pop     rbx
    ret

# outline_rows(rdi=ctx, esi=first row, edx=end) - 2 px outline straddling the
# silhouette of selected objects
outline_rows:
    push    rbx
    push    rbp
    push    r12
    push    r13
    push    r14
    push    r15
    mov     ebx, esi
    mov     r12d, edx
    mov     r13, [rip+rs_id]
    mov     r14, [rip+rs_sel]
    mov     r15d, [rip+rs_w]
1:  cmp     ebx, r12d
    jae     9f
    xor     ebp, ebp                    # x
2:  cmp     ebp, r15d
    jae     8f
    mov     eax, ebx
    imul    eax, r15d
    add     eax, ebp
    mov     ecx, [r13+rax*4]            # id here
    xor     r8d, r8d                    # strongest neighbouring state
    # neighbours with a different id: take the max selection state of the
    # pair (this pixel's own state counts when it borders something else)
    test    ebp, ebp
    jz      21f
    mov     edx, [r13+rax*4-4]
    call    .Lol_pair
21: lea     edx, [rbp+1]
    cmp     edx, r15d
    jae     22f
    mov     edx, [r13+rax*4+4]
    call    .Lol_pair
22: test    ebx, ebx
    jz      23f
    mov     edx, eax
    sub     edx, r15d
    mov     edx, [r13+rdx*4]
    call    .Lol_pair
23: lea     edx, [rbx+1]
    cmp     edx, [rip+rs_h]
    jae     24f
    lea     edx, [rax+r15]
    mov     edx, [r13+rdx*4]
    call    .Lol_pair
24: test    r8d, r8d
    jz      3f
    mov     edx, COL_SELECTED
    cmp     r8d, 2
    jne     25f
    mov     edx, COL_ACTIVE
25: mov     eax, [rip+rs_y0]
    add     eax, ebx
    imul    eax, [rip+fb_w]
    add     eax, [rip+rs_x0]
    add     eax, ebp
    mov     rdi, [rip+fb_ptr]
    mov     [rdi+rax*4], edx
3:  inc     ebp
    jmp     2b
8:  inc     ebx
    jmp     1b
9:  pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbp
    pop     rbx
    ret
# ecx = own id, edx = neighbour id -> r8d = max(r8d, state of either if they differ)
.Lol_pair:
    cmp     ecx, edx
    je      1f
    movzx   r9d, byte ptr [r14+rcx]
    cmp     r9d, r8d
    cmova   r8d, r9d
    movzx   r9d, byte ptr [r14+rdx]
    cmp     r9d, r8d
    cmova   r8d, r9d
1:  ret

# -----------------------------------------------------------------------------
# raster_pick(edi=x, esi=y logical) -> eax = id (list index + 1) or 0.
# The caller has set the clip to the viewport canvas and run cam_setup.
# -----------------------------------------------------------------------------
raster_pick:
    push    rbx
    push    r12
    sub     rsp, 8
    call    to_px
    mov     ebx, eax
    mov     edi, esi
    call    to_px
    mov     r12d, eax
    mov     edi, 1                      # id buffer only
    call    raster_scene
    xor     eax, eax
    sub     ebx, [rip+rs_x0]
    js      9f
    cmp     ebx, [rip+rs_w]
    jge     9f
    sub     r12d, [rip+rs_y0]
    js      9f
    cmp     r12d, [rip+rs_h]
    jge     9f
    mov     eax, r12d
    imul    eax, [rip+rs_w]
    add     eax, ebx
    mov     rcx, [rip+rs_id]
    mov     eax, [rcx+rax*4]
9:  add     rsp, 8
    pop     r12
    pop     rbx
    ret

.section .note.GNU-stack,"",@progbits
