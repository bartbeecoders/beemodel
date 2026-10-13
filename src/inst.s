# =============================================================================
#  BeeModel - instances: one mesh drawn many times.
#
#  A mesh may carry an instance block (ME_INST): up to 8 prototype meshes
#  (referenced) and, per instance, a 3x4 matrix (prototype space -> the
#  mesh's space) and its prototype. Geometry nodes make them (instance on
#  points); "realize" turns them into plain geometry.
#
#  The viewport draws them without realizing (inst_draw): every instance's
#  prototype sphere is projected once; one smaller than about a pixel is a
#  depth-tested splat, a bigger one has its prototype's triangles
#  rasterized, flat shaded. Instances are binned into screen tiles first
#  and the tiles drawn in parallel (no two threads write one pixel). The
#  path tracer gets them as triangles (hive.s, up to a budget).
#
#  The block: refs, count, prototypes, capacity, bytes, 8 prototype
#  pointers, then the matrices (48 bytes each) and the prototype bytes.
# =============================================================================
.intel_syntax noprefix
.include "const.inc"

.globl inst_new
.globl inst_ref
.globl inst_unref
.globl inst_mats
.globl inst_pids
.globl inst_proto
.globl inst_realize
.globl inst_draw
.globl inst_count
.globl inst_xform
.globl inst_merge
.globl inst_mul

.equ IB_REFS,   0
.equ IB_N,      4
.equ IB_NP,     8
.equ IB_CAP,    12
.equ IB_BYTES,  16
.equ IB_PROTO,  24
.equ IB_DATA,   128
.equ MAP_ANON_PRIV, 0x22
.equ TILE_SH,   4
.equ TILE,      16
.equ IR_SZ,     80                      # per instance (drawing): T 48, box
                                        #  16, mode, 1/z, colour, pad

.section .rodata
.align 16
in_abs:         .long 0x7fffffff, 0x7fffffff, 0x7fffffff, 0x7fffffff
in_one:         .float 1.0
in_half:        .float 0.5
in_tiny:        .float 1.0e-20
in_amb:         .float 0.25
in_dif:         .float 0.75
in_splat:       .float 0.85
in_small:       .float 3.0              # projected radius (px): a square splat
in_side:        .float 1.4              # its side / radius

.section .bss
.align 8
id_cw:          .skip 48                # object -> camera
id_ib:          .skip 8                 # the block drawn
id_col:         .skip 4                 # its object's colour
id_rec:         .skip 8                 # per instance records (frame arena)
id_ntx:         .skip 4
id_nty:         .skip 4
id_toff:        .skip 8                 # tiles -> instances (CSR)
id_tlist:       .skip 8
id_tcur:        .skip 8
id_pc:          .skip 16*8              # per prototype: centre, radius

.text

# inst_new(edi=capacity) -> rax = a block (refs 1, count 0) or 0
inst_new:
    push    rbx
    mov     ebx, edi
    mov     eax, ebx                    # bytes: header, matrices, ids
    imul    rax, rax, 49
    add     rax, IB_DATA+4095
    and     rax, -4096
    push    rax
    mov     rsi, rax
    xor     edi, edi
    mov     edx, PROT_RW
    mov     r10d, MAP_ANON_PRIV
    mov     r8, -1
    xor     r9d, r9d
    mov     eax, SYS_MMAP
    syscall
    pop     rcx
    cmp     rax, -4096
    jb      1f
    xor     eax, eax
    jmp     9f
1:  mov     dword ptr [rax+IB_REFS], 1
    mov     [rax+IB_CAP], ebx
    mov     [rax+IB_BYTES], rcx
9:  pop     rbx
    ret

inst_ref:
    test    rdi, rdi
    jz      1f
    lock inc dword ptr [rdi+IB_REFS]
1:  ret

# inst_unref(rdi=block) - the last reference frees it (and drops its
#   prototypes)
inst_unref:
    test    rdi, rdi
    jz      9f
    lock dec dword ptr [rdi+IB_REFS]
    jnz     9f
    push    rbx
    push    r12
    sub     rsp, 8
    mov     rbx, rdi
    xor     r12d, r12d
1:  cmp     r12d, [rbx+IB_NP]
    jae     2f
    mov     rdi, [rbx+IB_PROTO+r12*8]
    call    mesh_unref
    inc     r12d
    jmp     1b
2:  mov     rdi, rbx
    mov     rsi, [rbx+IB_BYTES]
    mov     eax, SYS_MUNMAP
    syscall
    add     rsp, 8
    pop     r12
    pop     rbx
9:  ret

# inst_mats(rdi=block) -> rax = the matrices; inst_pids -> the prototype ids
inst_mats:
    lea     rax, [rdi+IB_DATA]
    ret
inst_pids:
    mov     eax, [rdi+IB_CAP]
    imul    rax, rax, 48
    lea     rax, [rdi+IB_DATA+rax]
    ret

# inst_count(rdi=mesh) -> eax = its instances (0: none)
inst_count:
    mov     rax, [rdi+ME_INST]
    test    rax, rax
    jz      1f
    mov     eax, [rax+IB_N]
    ret
1:  xor     eax, eax
    ret

# inst_proto(rdi=block, rsi=mesh) -> eax = its prototype id (added, a
#   reference taken; -1: eight already)
inst_proto:
    xor     eax, eax
1:  cmp     eax, [rdi+IB_NP]
    jae     2f
    cmp     [rdi+IB_PROTO+rax*8], rsi
    je      9f
    inc     eax
    jmp     1b
2:  cmp     eax, 8
    jae     8f
    mov     [rdi+IB_PROTO+rax*8], rsi
    inc     dword ptr [rdi+IB_NP]
    push    rax
    push    rax
    mov     rdi, rsi
    call    mesh_ref
    pop     rax
    pop     rax
9:  ret
8:  mov     eax, -1
    ret

# inst_realize(rdi=mesh) -> rax = a new finished mesh: the mesh's own
#   geometry and every instance's prototype placed (no instances), or 0
inst_realize:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    push    rbp
    sub     rsp, 88
    mov     rbx, rdi
    mov     r12, [rbx+ME_INST]
    test    r12, r12
    jz      .Lir_copy
    mov     eax, [rbx+ME_NVERTS]        # the room: all of them
    mov     [rsp], eax
    mov     eax, [rbx+ME_NLOOPS]
    mov     [rsp+4], eax
    mov     eax, [rbx+ME_NPOLYS]
    mov     [rsp+8], eax
    mov     rdi, r12
    call    inst_pids
    mov     r15, rax
    xor     ecx, ecx
1:  cmp     ecx, [r12+IB_N]
    jae     2f
    movzx   eax, byte ptr [r15+rcx]
    mov     rdx, [r12+IB_PROTO+rax*8]
    mov     eax, [rdx+ME_NVERTS]
    add     [rsp], eax
    mov     eax, [rdx+ME_NLOOPS]
    add     [rsp+4], eax
    mov     eax, [rdx+ME_NPOLYS]
    add     [rsp+8], eax
    inc     ecx
    jmp     1b
2:  mov     edi, [rsp]
    add     edi, 8
    mov     esi, [rsp+4]
    add     esi, 8
    mov     edx, [rsp+8]
    add     edx, 8
    call    mesh_new
    test    rax, rax
    jz      .Lir_fail
    mov     r13, rax                    # the result
    mov     rdi, r13                    # the mesh's own: as it is
    mov     rsi, rbx
    lea     rdx, [rip+id_ident]
    call    ir_append
    mov     rdi, r12
    call    inst_mats
    mov     r14, rax
    xor     ebp, ebp
3:  cmp     ebp, [r12+IB_N]
    jae     4f
    movzx   eax, byte ptr [r15+rbp]
    mov     rsi, [r12+IB_PROTO+rax*8]
    imul    eax, ebp, 48
    lea     rdx, [r14+rax]
    mov     rdi, r13
    call    ir_append
    inc     ebp
    jmp     3b
4:  mov     rdi, r13
    call    mesh_finish
    mov     rax, r13
    jmp     9f
.Lir_copy:
    call    mesh_copy
    jmp     9f
.Lir_fail:
    xor     eax, eax
9:  add     rsp, 88
    pop     rbp
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

.section .rodata
.align 4
id_ident:       .float 1, 0, 0, 0,  0, 1, 0, 0,  0, 0, 1, 0
.text

# ir_append(rdi=into, rsi=mesh, rdx=matrix 3x4) - its vertices placed, its
#   polygons after the ones there
ir_append:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    sub     rsp, 32
    mov     rbx, rdi
    mov     r12, rsi
    mov     r13, rdx
    mov     r14d, [rbx+ME_NVERTS]       # (vertex offset)
    xor     r15d, r15d
1:  cmp     r15d, [r12+ME_NVERTS]
    jae     2f
    imul    eax, r15d, 12
    mov     rdx, [r12+ME_POS]
    add     rdx, rax
    xor     ecx, ecx
11: movss   xmm0, [r13+rcx]             # row . p + t
    mulss   xmm0, [rdx]
    movss   xmm1, [r13+rcx+4]
    mulss   xmm1, [rdx+4]
    addss   xmm0, xmm1
    movss   xmm1, [r13+rcx+8]
    mulss   xmm1, [rdx+8]
    addss   xmm0, xmm1
    addss   xmm0, [r13+rcx+12]
    shr     ecx, 2
    movss   [rsp+rcx], xmm0
    shl     ecx, 2
    add     ecx, 16
    cmp     ecx, 48
    jb      11b
    movss   xmm0, [rsp]
    movss   xmm1, [rsp+4]
    movss   xmm2, [rsp+8]
    mov     rdi, rbx
    call    mesh_add_vert
    inc     r15d
    jmp     1b
2:  mov     rdi, rbx                    # polygons, shifted
    mov     rsi, r12
    mov     edx, r14d
    xor     ecx, ecx
    call    copy_polys_off
    add     rsp, 32
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# copy_polys_off(rdi=dst, rsi=src, edx=vertex offset) - every polygon
copy_polys_off:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    sub     rsp, 1024+16
    mov     rbx, rdi
    mov     r12, rsi
    mov     r13d, edx
    xor     r15d, r15d
1:  cmp     r15d, [r12+ME_NPOLYS]
    jae     9f
    mov     rsi, [r12+ME_POFF]
    mov     ecx, [rsi+r15*4]
    mov     edx, [rsi+r15*4+4]
    mov     rsi, [r12+ME_LOOPS]
    xor     r8d, r8d
2:  cmp     ecx, edx
    jae     3f
    cmp     r8d, 255
    jae     3f
    mov     eax, [rsi+rcx*4]
    add     eax, r13d
    mov     [rsp+r8*4], eax
    inc     r8d
    inc     ecx
    jmp     2b
3:  mov     rdi, rbx
    lea     rsi, [rsp]
    mov     edx, r8d
    call    mesh_add_poly
    inc     r15d
    jmp     1b
9:  add     rsp, 1024+16
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# inst_mul(rdi=out 3x4, rsi=a 3x4, rdx=b 3x4) - a x b (affine)
inst_mul:
    xor     ecx, ecx
1:  mov     eax, ecx
    shl     eax, 4
    xor     r8d, r8d
2:  movss   xmm0, [rsi+rax]
    mulss   xmm0, [rdx+r8*4]
    movss   xmm1, [rsi+rax+4]
    mulss   xmm1, [rdx+16+r8*4]
    addss   xmm0, xmm1
    movss   xmm1, [rsi+rax+8]
    mulss   xmm1, [rdx+32+r8*4]
    addss   xmm0, xmm1
    cmp     r8d, 3
    jne     3f
    addss   xmm0, [rsi+rax+12]
3:  lea     r9d, [rax+r8*4]
    movss   [rdi+r9], xmm0
    inc     r8d
    cmp     r8d, 4
    jb      2b
    inc     ecx
    cmp     ecx, 3
    jb      1b
    ret

# inst_xform(rdi=block, rsi=matrix 3x4) -> rax = a new block: the same
#   prototypes, every matrix placed by it
inst_xform:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    mov     rbx, rdi
    mov     r12, rsi
    mov     edi, [rbx+IB_N]
    call    inst_new
    test    rax, rax
    jz      9f
    mov     r13, rax
    mov     eax, [rbx+IB_N]
    mov     [r13+IB_N], eax
    xor     r14d, r14d
1:  cmp     r14d, [rbx+IB_NP]
    jae     2f
    mov     rdi, r13
    mov     rsi, [rbx+IB_PROTO+r14*8]
    call    inst_proto
    inc     r14d
    jmp     1b
2:  mov     rdi, rbx                    # prototype ids as they were
    call    inst_pids
    mov     rsi, rax
    mov     rdi, r13
    call    inst_pids
    mov     rdi, rax
    mov     ecx, [rbx+IB_N]
    rep     movsb
    xor     r14d, r14d
3:  cmp     r14d, [rbx+IB_N]
    jae     4f
    imul    r15d, r14d, 48
    lea     rdx, [rbx+IB_DATA+r15]
    lea     rdi, [r13+IB_DATA+r15]
    mov     rsi, r12
    call    inst_mul
    inc     r14d
    jmp     3b
4:  mov     rax, r13
9:  pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# inst_merge(rdi=block or 0, rsi=block or 0) -> rax = one with both's
#   instances (a reference: one of them when the other is 0; 0 for none)
inst_merge:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    mov     rbx, rdi
    mov     r12, rsi
    test    rbx, rbx
    jnz     1f
    mov     rdi, r12
    call    inst_ref
    mov     rax, r12
    jmp     9f
1:  test    r12, r12
    jnz     2f
    mov     rdi, rbx
    call    inst_ref
    mov     rax, rbx
    jmp     9f
2:  mov     edi, [rbx+IB_N]
    add     edi, [r12+IB_N]
    call    inst_new
    test    rax, rax
    jz      9f
    mov     r13, rax
    mov     eax, [rbx+IB_N]
    add     eax, [r12+IB_N]
    mov     [r13+IB_N], eax
    mov     rdi, rbx                    # a's: as they were
    mov     rsi, r13
    xor     edx, edx
    call    im_copy
    mov     rdi, r12                    # b's: after them
    mov     rsi, r13
    mov     edx, [rbx+IB_N]
    call    im_copy
    mov     rax, r13
9:  pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# im_copy(rdi=from, rsi=into, edx=first place) - matrices and prototypes
#   (renumbered into the block's own; prototypes past eight: the first)
im_copy:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    sub     rsp, 16
    mov     rbx, rdi
    mov     r12, rsi
    mov     r13d, edx
    xor     r14d, r14d                  # prototype map at [rsp..7]
1:  cmp     r14d, [rbx+IB_NP]
    jae     2f
    mov     rdi, r12
    mov     rsi, [rbx+IB_PROTO+r14*8]
    call    inst_proto
    test    eax, eax
    jns     11f
    xor     eax, eax
11: mov     [rsp+r14], al
    inc     r14d
    jmp     1b
2:  mov     eax, r13d                   # matrices
    imul    rax, rax, 48
    lea     rdi, [r12+IB_DATA+rax]
    lea     rsi, [rbx+IB_DATA]
    mov     ecx, [rbx+IB_N]
    imul    rcx, rcx, 48
    rep     movsb
    mov     rdi, rbx
    call    inst_pids
    mov     r14, rax
    mov     rdi, r12
    call    inst_pids
    add     rax, r13
    xor     ecx, ecx
3:  cmp     ecx, [rbx+IB_N]
    jae     9f
    movzx   edx, byte ptr [r14+rcx]
    and     edx, 7
    movzx   edx, byte ptr [rsp+rdx]
    mov     [rax+rcx], dl
    inc     ecx
    jmp     3b
9:  add     rsp, 16
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# =============================================================================
#  Drawing
# =============================================================================
# inst_draw - every mesh object's instances into the viewport being drawn
#   (after the rasterizer: its colour and depth, rs_x0 / rs_y0 / rs_w / rs_h)
inst_draw:
    push    rbx
    push    r12
    sub     rsp, 8
    cmp     dword ptr [rip+rs_w], 0
    jle     9f
    cmp     dword ptr [rip+rs_h], 0
    jle     9f
    xor     ebx, ebx
1:  cmp     ebx, [rip+obj_count]
    jae     9f
    mov     edi, ebx
    call    obj_at
    cmp     dword ptr [rax+OB_TYPE], OT_MESH
    jne     2f
    mov     r12, rax
    mov     rdi, rax
    call    obj_eval
    test    rax, rax
    jz      2f
    mov     rcx, [rax+ME_INST]
    test    rcx, rcx
    jz      2f
    cmp     dword ptr [rcx+IB_N], 0
    je      2f
    mov     [rip+id_ib], rcx
    mov     rdi, r12
    call    id_object
2:  inc     ebx
    jmp     1b
9:  add     rsp, 8
    pop     r12
    pop     rbx
    ret

# id_object(rdi=object; id_ib) - its instances drawn
id_object:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    push    rbp
    sub     rsp, 104
    mov     rbx, rdi
    mov     rdi, rbx                    # its colour
    call    mat_display_color
    mov     [rip+id_col], eax
    mov     rdi, rbx                    # object -> camera
    lea     rsi, [rsp]
    call    obj_matrix
    call    id_cam                      # (rsp+8: the object matrix)
    mov     r12, [rip+id_ib]            # prototype spheres
    xor     ecx, ecx
1:  cmp     ecx, [r12+IB_NP]
    jae     2f
    mov     rdx, [r12+IB_PROTO+rcx*8]
    mov     eax, ecx
    shl     eax, 4
    lea     r8, [rip+id_pc]
    add     r8, rax
    xorps   xmm3, xmm3
    xor     r9d, r9d
11: movss   xmm0, [rdx+ME_BMIN+r9*4]
    addss   xmm0, [rdx+ME_BMAX+r9*4]
    mulss   xmm0, [rip+in_half]
    movss   [r8+r9*4], xmm0
    movss   xmm1, [rdx+ME_BMAX+r9*4]
    subss   xmm1, [rdx+ME_BMIN+r9*4]
    mulss   xmm1, xmm1
    addss   xmm3, xmm1
    inc     r9d
    cmp     r9d, 3
    jb      11b
    sqrtss  xmm3, xmm3
    mulss   xmm3, [rip+in_half]
    movss   [r8+12], xmm3
    inc     ecx
    jmp     1b
2:  lea     rdi, [rip+frame_arena]      # per instance records
    mov     esi, [r12+IB_N]
    imul    rsi, rsi, IR_SZ
    add     rsi, 64
    call    arena_alloc
    test    rax, rax
    jz      .Lio_out
    mov     [rip+id_rec], rax
    lea     rdi, [rip+id_job_project]   # pass 1: project
    xor     esi, esi
    mov     edx, [r12+IB_N]
    mov     ecx, 4096
    call    parallel_for
    mov     eax, [rip+rs_w]             # tiles
    add     eax, TILE-1
    shr     eax, TILE_SH
    mov     [rip+id_ntx], eax
    mov     ecx, [rip+rs_h]
    add     ecx, TILE-1
    shr     ecx, TILE_SH
    mov     [rip+id_nty], ecx
    imul    eax, ecx
    mov     r13d, eax                   # tiles
    lea     rdi, [rip+frame_arena]
    lea     esi, [rax*8+16]
    call    arena_alloc
    test    rax, rax
    jz      .Lio_out
    mov     [rip+id_toff], rax
    lea     rdi, [rax]
    lea     ecx, [r13*2+2]
    xor     eax, eax
    rep     stosd
    lea     rdi, [rip+id_job_count]     # pass 2: count per tile
    xor     esi, esi
    mov     edx, [r12+IB_N]
    mov     ecx, 4096
    call    parallel_for
    mov     rcx, [rip+id_toff]          # prefix sums (offsets, then cursors)
    xor     eax, eax
    xor     edx, edx
3:  cmp     edx, r13d
    jae     4f
    mov     r8d, [rcx+rdx*4+4]
    mov     [rcx+rdx*4+4], eax
    add     eax, r8d
    inc     edx
    jmp     3b
4:  mov     [rcx+r13*4+4], eax          # (the end)
    mov     ebp, eax
    lea     rdi, [rip+frame_arena]
    lea     esi, [rax*4+16]
    call    arena_alloc
    test    rax, rax
    jz      .Lio_out
    mov     [rip+id_tlist], rax
    lea     rdi, [rip+frame_arena]      # cursors
    lea     esi, [r13*4+16]
    call    arena_alloc
    test    rax, rax
    jz      .Lio_out
    mov     [rip+id_tcur], rax
    mov     rdi, rax
    mov     rsi, [rip+id_toff]
    add     rsi, 4
    mov     ecx, r13d
    rep     movsd
    lea     rdi, [rip+id_job_fill]      # pass 3: the lists
    xor     esi, esi
    mov     edx, [r12+IB_N]
    mov     ecx, 4096
    call    parallel_for
    lea     rdi, [rip+id_job_tile]      # pass 4: the tiles
    xor     esi, esi
    mov     edx, r13d
    mov     ecx, 1
    call    parallel_for
.Lio_out:
    add     rsp, 104
    pop     rbp
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# id_cam (the caller's frame: the object matrix at its rsp+8 ... wait:
#   called with the matrix at [rsp+8] here) - id_cw = view x object
id_cam:
    lea     r8, [rsp+8]                 # object matrix (3x4, rows)
    xor     ecx, ecx                    # rows: right, up, fwd
1:  lea     rax, [rip+right]
    cmp     ecx, 1
    jne     11f
    lea     rax, [rip+up]
11: cmp     ecx, 2
    jne     12f
    lea     rax, [rip+fwd]
12: mov     edx, ecx
    shl     edx, 4
    lea     r9, [rip+id_cw]
    add     r9, rdx
    xor     r10d, r10d
2:  movss   xmm0, [rax]                 # R . M[:, j]
    mulss   xmm0, [r8+r10*4]
    movss   xmm1, [rax+4]
    mulss   xmm1, [r8+16+r10*4]
    addss   xmm0, xmm1
    movss   xmm1, [rax+8]
    mulss   xmm1, [r8+32+r10*4]
    addss   xmm0, xmm1
    movss   [r9+r10*4], xmm0
    inc     r10d
    cmp     r10d, 3
    jb      2b
    movss   xmm0, [r8+12]               # R . (t - eye)
    subss   xmm0, [rip+eye]
    mulss   xmm0, [rax]
    movss   xmm1, [r8+28]
    subss   xmm1, [rip+eye+4]
    mulss   xmm1, [rax+4]
    addss   xmm0, xmm1
    movss   xmm1, [r8+44]
    subss   xmm1, [rip+eye+8]
    mulss   xmm1, [rax+8]
    addss   xmm0, xmm1
    movss   [r9+12], xmm0
    inc     ecx
    cmp     ecx, 3
    jb      1b
    ret

# id_rec_of(eax = instance) -> rdx = its record
.macro ID_REC reg, idx
    imul    \reg, \idx, IR_SZ
    add     \reg, [rip+id_rec]
.endm

# id_job_project(esi=begin, edx=end) - T = cw x M; the sphere on screen ->
#   mode (0 none, 1 splat, 2 triangles), box, 1/z
id_job_project:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    sub     rsp, 32
    mov     r12d, esi
    mov     r13d, edx
    mov     r14, [rip+id_ib]
    mov     rdi, r14
    call    inst_mats
    mov     r15, rax
1:  cmp     r12d, r13d
    jae     9f
    mov     eax, r12d
    ID_REC  rbx, rax
    mov     dword ptr [rbx+64], 0       # (none, until seen)
    imul    eax, r12d, 48
    lea     rsi, [r15+rax]              # M
    xor     ecx, ecx                    # T[r][c] = cw[r] . M[:, c] (+ t)
2:  mov     edx, ecx
    shl     edx, 4
    lea     r8, [rip+id_cw]
    add     r8, rdx
    xor     r9d, r9d
21: movss   xmm0, [r8]
    mulss   xmm0, [rsi+r9*4]
    movss   xmm1, [r8+4]
    mulss   xmm1, [rsi+16+r9*4]
    addss   xmm0, xmm1
    movss   xmm1, [r8+8]
    mulss   xmm1, [rsi+32+r9*4]
    addss   xmm0, xmm1
    cmp     r9d, 3
    jne     22f
    addss   xmm0, [r8+12]
22: lea     eax, [rdx+r9*4]
    movss   [rbx+rax], xmm0
    inc     r9d
    cmp     r9d, 4
    jb      21b
    inc     ecx
    cmp     ecx, 3
    jb      2b
    mov     rdi, r14                    # its prototype's sphere
    call    inst_pids
    movzx   eax, byte ptr [rax+r12]
    shl     eax, 4
    lea     rdx, [rip+id_pc]
    add     rdx, rax
    xor     ecx, ecx                    # centre in camera space
3:  mov     eax, ecx
    shl     eax, 4
    movss   xmm0, [rbx+rax]
    mulss   xmm0, [rdx]
    movss   xmm1, [rbx+rax+4]
    mulss   xmm1, [rdx+4]
    addss   xmm0, xmm1
    movss   xmm1, [rbx+rax+8]
    mulss   xmm1, [rdx+8]
    addss   xmm0, xmm1
    addss   xmm0, [rbx+rax+12]
    movss   [rsp+rcx*4], xmm0
    inc     ecx
    cmp     ecx, 3
    jb      3b
    movss   xmm0, [rbx]                 # scale: the largest column length
    mulss   xmm0, xmm0
    movss   xmm1, [rbx+16]
    mulss   xmm1, xmm1
    addss   xmm0, xmm1
    movss   xmm1, [rbx+32]
    mulss   xmm1, xmm1
    addss   xmm0, xmm1
    movss   xmm2, [rbx+4]
    mulss   xmm2, xmm2
    movss   xmm1, [rbx+20]
    mulss   xmm1, xmm1
    addss   xmm2, xmm1
    movss   xmm1, [rbx+36]
    mulss   xmm1, xmm1
    addss   xmm2, xmm1
    maxss   xmm0, xmm2
    movss   xmm2, [rbx+8]
    mulss   xmm2, xmm2
    movss   xmm1, [rbx+24]
    mulss   xmm1, xmm1
    addss   xmm2, xmm1
    movss   xmm1, [rbx+40]
    mulss   xmm1, xmm1
    addss   xmm2, xmm1
    maxss   xmm0, xmm2
    sqrtss  xmm0, xmm0
    mulss   xmm0, [rdx+12]              # world radius
    movss   [rsp+12], xmm0
    movss   xmm1, [rsp+8]               # z: in front of the near plane, all
    subss   xmm1, xmm0
    comiss  xmm1, [rip+f_near]
    jb      8f
    movss   xmm2, [rip+in_one]          # 1/z, projected radius, centre
    divss   xmm2, [rsp+8]
    movss   [rbx+68], xmm2
    movss   xmm3, xmm2
    mulss   xmm3, [rip+vp_focal]
    movss   xmm4, [rsp]
    mulss   xmm4, xmm3
    addss   xmm4, [rip+vp_cx]
    cvtsi2ss xmm5, dword ptr [rip+rs_x0]
    subss   xmm4, xmm5                  # x (viewport)
    movss   xmm5, [rsp+4]
    mulss   xmm5, xmm3
    movss   xmm6, [rip+vp_cy]
    subss   xmm6, xmm5
    cvtsi2ss xmm5, dword ptr [rip+rs_y0]
    subss   xmm6, xmm5                  # y
    mulss   xmm3, [rsp+12]              # radius (px)
    movss   xmm5, xmm4                  # the box
    subss   xmm5, xmm3
    cvttss2si eax, xmm5
    mov     [rbx+48], eax
    movss   xmm5, xmm4
    addss   xmm5, xmm3
    cvttss2si eax, xmm5
    inc     eax
    mov     [rbx+56], eax
    movss   xmm5, xmm6
    subss   xmm5, xmm3
    cvttss2si eax, xmm5
    mov     [rbx+52], eax
    movss   xmm5, xmm6
    addss   xmm5, xmm3
    cvttss2si eax, xmm5
    inc     eax
    mov     [rbx+60], eax
    mov     eax, [rbx+56]               # off the viewport: none
    test    eax, eax
    jle     8f
    mov     eax, [rbx+60]
    test    eax, eax
    jle     8f
    mov     eax, [rbx+48]
    cmp     eax, [rip+rs_w]
    jge     8f
    mov     eax, [rbx+52]
    cmp     eax, [rip+rs_h]
    jge     8f
    mov     dword ptr [rbx+64], 2       # triangles, or a square at the
    comiss  xmm3, [rip+in_small]        #  centre (side: 1.4 radii, 1 px at
    jae     8f                          #  least)
    mulss   xmm3, [rip+in_side]
    cvttss2si ecx, xmm3
    cmp     ecx, 1
    jge     82f
    mov     ecx, 1
82: mov     edx, ecx                    # (half, rounded down)
    shr     edx, 1
    cvttss2si eax, xmm4
    sub     eax, edx
    mov     [rbx+48], eax
    add     eax, ecx
    mov     [rbx+56], eax
    cvttss2si eax, xmm6
    sub     eax, edx
    mov     [rbx+52], eax
    add     eax, ecx
    mov     [rbx+60], eax
    cmp     dword ptr [rbx+56], 0
    jle     81f
    cmp     dword ptr [rbx+60], 0
    jle     81f
    mov     eax, [rbx+48]
    cmp     eax, [rip+rs_w]
    jge     81f
    mov     eax, [rbx+52]
    cmp     eax, [rip+rs_h]
    jge     81f
    mov     dword ptr [rbx+64], 1
    jmp     8f
81: mov     dword ptr [rbx+64], 0
8:  inc     r12d
    jmp     1b
9:  add     rsp, 32
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# id_tiles(rbx=record) -> r8d..r11d = its tile range (x0 y0 x1 y1 incl.)
id_tiles:
    mov     r8d, [rbx+48]
    test    r8d, r8d
    jns     1f
    xor     r8d, r8d
1:  sar     r8d, TILE_SH
    mov     r9d, [rbx+52]
    test    r9d, r9d
    jns     2f
    xor     r9d, r9d
2:  sar     r9d, TILE_SH
    mov     r10d, [rbx+56]
    dec     r10d
    sar     r10d, TILE_SH
    cmp     r10d, [rip+id_ntx]
    jl      3f
    mov     r10d, [rip+id_ntx]
    dec     r10d
3:  mov     r11d, [rbx+60]
    dec     r11d
    sar     r11d, TILE_SH
    cmp     r11d, [rip+id_nty]
    jl      4f
    mov     r11d, [rip+id_nty]
    dec     r11d
4:  ret

# id_job_count(esi, edx) - each instance's tiles counted
id_job_count:
    push    rbx
    push    r12
    push    r13
    mov     r12d, esi
    mov     r13d, edx
1:  cmp     r12d, r13d
    jae     9f
    ID_REC  rbx, r12
    cmp     dword ptr [rbx+64], 0
    je      8f
    call    id_tiles
    mov     rsi, [rip+id_toff]
2:  cmp     r9d, r11d
    jg      8f
    mov     ecx, r8d
3:  cmp     ecx, r10d
    jg      4f
    mov     eax, r9d
    imul    eax, [rip+id_ntx]
    add     eax, ecx
    lock inc dword ptr [rsi+rax*4+4]
    inc     ecx
    jmp     3b
4:  inc     r9d
    jmp     2b
8:  inc     r12d
    jmp     1b
9:  pop     r13
    pop     r12
    pop     rbx
    ret

# id_job_fill(esi, edx) - into the tiles' lists
id_job_fill:
    push    rbx
    push    r12
    push    r13
    mov     r12d, esi
    mov     r13d, edx
1:  cmp     r12d, r13d
    jae     9f
    ID_REC  rbx, r12
    cmp     dword ptr [rbx+64], 0
    je      8f
    call    id_tiles
    mov     rsi, [rip+id_tcur]
    mov     rdi, [rip+id_tlist]
2:  cmp     r9d, r11d
    jg      8f
    mov     ecx, r8d
3:  cmp     ecx, r10d
    jg      4f
    mov     eax, r9d
    imul    eax, [rip+id_ntx]
    add     eax, ecx
    mov     edx, 1
    lock xadd [rsi+rax*4], edx
    mov     [rdi+rdx*4], r12d
    inc     ecx
    jmp     3b
4:  inc     r9d
    jmp     2b
8:  inc     r12d
    jmp     1b
9:  pop     r13
    pop     r12
    pop     rbx
    ret

# id_job_tile(esi, edx) - each tile's instances drawn into it
id_job_tile:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    push    rbp
    sub     rsp, 40
    mov     [rsp], esi
    mov     [rsp+4], edx
.Lit_tile:
    mov     eax, [rsp]
    cmp     eax, [rsp+4]
    jae     .Lit_out
    xor     edx, edx                    # the tile's box (viewport pixels)
    div     dword ptr [rip+id_ntx]
    shl     edx, TILE_SH
    shl     eax, TILE_SH
    mov     [rsp+8], edx
    mov     [rsp+12], eax
    add     edx, TILE
    cmp     edx, [rip+rs_w]
    jle     1f
    mov     edx, [rip+rs_w]
1:  mov     [rsp+16], edx
    add     eax, TILE
    cmp     eax, [rip+rs_h]
    jle     2f
    mov     eax, [rip+rs_h]
2:  mov     [rsp+20], eax
    mov     eax, [rsp]
    mov     rcx, [rip+id_toff]
    mov     r12d, [rcx+rax*4]
    mov     r13d, [rcx+rax*4+4]
3:  cmp     r12d, r13d
    jae     .Lit_next
    mov     rcx, [rip+id_tlist]
    mov     r14d, [rcx+r12*4]
    ID_REC  rbx, r14
    cmp     dword ptr [rbx+64], 1
    jne     4f
    movss   xmm0, [rip+in_splat]        # a splat: its square, in the tile
    call    id_colour
    mov     [rsp+24], eax
    mov     eax, [rbx+52]
    cmp     eax, [rsp+12]
    jge     41f
    mov     eax, [rsp+12]
41: mov     [rsp+28], eax               # y from
    mov     eax, [rbx+60]
    cmp     eax, [rsp+20]
    jle     42f
    mov     eax, [rsp+20]
42: mov     [rsp+32], eax               # y to
    mov     r9d, [rsp+28]
43: cmp     r9d, [rsp+32]
    jge     5f
    mov     r8d, [rbx+48]
    cmp     r8d, [rsp+8]
    jge     44f
    mov     r8d, [rsp+8]
44: mov     eax, [rbx+56]
    cmp     eax, [rsp+16]
    jle     45f
    mov     eax, [rsp+16]
45: mov     [rsp+36], eax
46: cmp     r8d, [rsp+36]
    jge     47f
    movss   xmm7, [rbx+68]
    mov     eax, [rsp+24]
    call    id_plot
    inc     r8d
    jmp     46b
47: inc     r9d
    jmp     43b
4:  lea     rdi, [rsp+8]                # triangles
    mov     esi, r14d
    call    id_tris
5:  inc     r12d
    jmp     3b
.Lit_next:
    inc     dword ptr [rsp]
    jmp     .Lit_tile
.Lit_out:
    add     rsp, 40
    pop     rbp
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# id_colour(xmm0 = brightness) -> eax = the object colour scaled
id_colour:
    mov     edx, [rip+id_col]
    xor     eax, eax
    mov     ecx, 16
1:  mov     r10d, edx
    shr     r10d, cl
    and     r10d, 0xff
    cvtsi2ss xmm1, r10d
    mulss   xmm1, xmm0
    cvttss2si r10d, xmm1
    cmp     r10d, 255
    jbe     2f
    mov     r10d, 255
2:  shl     r10d, cl
    or      eax, r10d
    sub     ecx, 8
    jns     1b
    ret

# id_plot(r8d=x, r9d=y viewport, xmm7=1/z, eax=colour) - depth tested
id_plot:
    mov     r10d, r9d
    imul    r10d, [rip+rs_w]
    add     r10d, r8d
    mov     r11, [rip+rs_depth]
    comiss  xmm7, [r11+r10*4]
    jbe     1f
    movss   [r11+r10*4], xmm7
    mov     r10d, [rip+rs_y0]
    add     r10d, r9d
    imul    r10d, [rip+fb_w]
    add     r10d, [rip+rs_x0]
    add     r10d, r8d
    mov     r11, [rip+fb_ptr]
    mov     [r11+r10*4], eax
1:  ret

# id_tris(rdi=tile box x0 y0 x1 y1, esi=instance) - its prototype's
#   triangles (record T = prototype -> camera), flat shaded, clipped to the
#   tile (triangles reaching behind the eye skipped)
id_tris:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    push    rbp
    sub     rsp, 104+64*24
    mov     rbp, rdi
    mov     eax, esi
    ID_REC  rbx, rax                    # T at rbx
    mov     rdi, [rip+id_ib]
    push    rsi
    push    rsi
    call    inst_pids
    pop     rsi
    pop     rsi
    movzx   eax, byte ptr [rax+rsi]
    mov     rdi, [rip+id_ib]
    mov     r12, [rdi+IB_PROTO+rax*8]   # the prototype
    xor     r14d, r14d                  # its corners projected once (up to
    cmp     dword ptr [r12+ME_NVERTS], 64   #  64: at +112, 24 bytes each)
    ja      .Lid_nocache
    mov     r14d, 1
    xor     r15d, r15d
.Lid_vert:
    cmp     r15d, [r12+ME_NVERTS]
    jae     .Lid_nocache
    imul    eax, r15d, 12
    add     rax, [r12+ME_POS]
    imul    r8d, r15d, 24
    lea     r8, [rsp+112+r8]
    xor     ecx, ecx
1:  mov     edx, ecx
    shl     edx, 4
    movss   xmm0, [rbx+rdx]
    mulss   xmm0, [rax]
    movss   xmm1, [rbx+rdx+4]
    mulss   xmm1, [rax+4]
    addss   xmm0, xmm1
    movss   xmm1, [rbx+rdx+8]
    mulss   xmm1, [rax+8]
    addss   xmm0, xmm1
    addss   xmm0, [rbx+rdx+12]
    movss   [r8+rcx*4], xmm0
    inc     ecx
    cmp     ecx, 3
    jb      1b
    movss   xmm2, [r8+8]
    xorps   xmm7, xmm7                  # (behind the near plane: 1/z = 0)
    comiss  xmm2, [rip+f_near]
    jb      2f
    movss   xmm7, [rip+in_one]
    divss   xmm7, xmm2
2:  movss   xmm3, xmm7
    mulss   xmm3, [rip+vp_focal]
    movss   xmm0, [r8]
    mulss   xmm0, xmm3
    addss   xmm0, [rip+vp_cx]
    cvtsi2ss xmm5, dword ptr [rip+rs_x0]
    subss   xmm0, xmm5
    movss   xmm1, [r8+4]
    mulss   xmm1, xmm3
    movss   xmm4, [rip+vp_cy]
    subss   xmm4, xmm1
    cvtsi2ss xmm5, dword ptr [rip+rs_y0]
    subss   xmm4, xmm5
    movss   [r8+12], xmm0
    movss   [r8+16], xmm4
    movss   [r8+20], xmm7
    inc     r15d
    jmp     .Lid_vert
.Lid_nocache:
    xor     r13d, r13d
.Lid_tri:
    cmp     r13d, [r12+ME_NTRIS]
    jae     .Lid_out
    xor     r15d, r15d                  # corners: camera, then screen
    test    r14d, r14d
    jz      .Lid_corner
.Lid_cached:                            # (from the cache)
    lea     eax, [r13+r13*2]
    add     eax, r15d
    mov     rdx, [r12+ME_TRIS]
    mov     eax, [rdx+rax*4]
    imul    eax, eax, 24
    lea     rsi, [rsp+112+rax]
    xorps   xmm0, xmm0
    comiss  xmm0, [rsi+20]
    je      .Lid_next
    imul    edx, r15d, 12
    mov     rax, [rsi]
    mov     [rsp+64+rdx], rax
    mov     eax, [rsi+8]
    mov     [rsp+64+rdx+8], eax
    mov     rax, [rsi+12]
    mov     [rsp+rdx], rax
    mov     eax, [rsi+20]
    mov     [rsp+rdx+8], eax
    inc     r15d
    cmp     r15d, 3
    jb      .Lid_cached
    jmp     .Lid_area
.Lid_corner:
    lea     eax, [r13+r13*2]
    add     eax, r15d
    mov     rdx, [r12+ME_TRIS]
    mov     eax, [rdx+rax*4]
    lea     rax, [rax+rax*2]
    shl     rax, 2
    add     rax, [r12+ME_POS]
    xor     ecx, ecx
1:  mov     edx, ecx                    # T row . p + t
    shl     edx, 4
    movss   xmm0, [rbx+rdx]
    mulss   xmm0, [rax]
    movss   xmm1, [rbx+rdx+4]
    mulss   xmm1, [rax+4]
    addss   xmm0, xmm1
    movss   xmm1, [rbx+rdx+8]
    mulss   xmm1, [rax+8]
    addss   xmm0, xmm1
    addss   xmm0, [rbx+rdx+12]
    imul    edx, r15d, 12
    lea     edx, [rdx+rcx*4]
    movss   [rsp+64+rdx], xmm0          # camera at +64 (3 x 12)
    inc     ecx
    cmp     ecx, 3
    jb      1b
    imul    edx, r15d, 12
    movss   xmm2, [rsp+64+rdx+8]
    comiss  xmm2, [rip+f_near]
    jb      .Lid_next
    movss   xmm7, [rip+in_one]
    divss   xmm7, xmm2
    movss   xmm3, xmm7
    mulss   xmm3, [rip+vp_focal]
    movss   xmm0, [rsp+64+rdx]
    mulss   xmm0, xmm3
    addss   xmm0, [rip+vp_cx]
    cvtsi2ss xmm5, dword ptr [rip+rs_x0]
    subss   xmm0, xmm5
    movss   xmm1, [rsp+64+rdx+4]
    mulss   xmm1, xmm3
    movss   xmm4, [rip+vp_cy]
    subss   xmm4, xmm1
    cvtsi2ss xmm5, dword ptr [rip+rs_y0]
    subss   xmm4, xmm5
    movss   [rsp+rdx], xmm0
    movss   [rsp+rdx+4], xmm4
    movss   [rsp+rdx+8], xmm7
    inc     r15d
    cmp     r15d, 3
    jb      .Lid_corner
.Lid_area:                              # area (signed: back faces skipped)
    movss   xmm0, [rsp+12]
    subss   xmm0, [rsp]
    movss   xmm1, [rsp+28]
    subss   xmm1, [rsp+4]
    mulss   xmm0, xmm1
    movss   xmm1, [rsp+16]
    subss   xmm1, [rsp+4]
    movss   xmm2, [rsp+24]
    subss   xmm2, [rsp]
    mulss   xmm1, xmm2
    subss   xmm0, xmm1
    movss   [rsp+36], xmm0
    xorps   xmm1, xmm1                  # (back faces: not drawn)
    comiss  xmm0, xmm1
    jbe     .Lid_next
    andps   xmm0, [rip+in_abs]
    comiss  xmm0, [rip+in_tiny]
    jbe     .Lid_next
    # the box within the tile
    movss   xmm0, [rsp]
    minss   xmm0, [rsp+12]
    minss   xmm0, [rsp+24]
    cvttss2si eax, xmm0
    cmp     eax, [rbp]
    jge     2f
    mov     eax, [rbp]
2:  mov     [rsp+44], eax
    movss   xmm0, [rsp]
    maxss   xmm0, [rsp+12]
    maxss   xmm0, [rsp+24]
    cvttss2si eax, xmm0
    inc     eax
    cmp     eax, [rbp+8]
    jle     3f
    mov     eax, [rbp+8]
3:  mov     [rsp+48], eax
    movss   xmm0, [rsp+4]
    minss   xmm0, [rsp+16]
    minss   xmm0, [rsp+28]
    cvttss2si eax, xmm0
    cmp     eax, [rbp+4]
    jge     4f
    mov     eax, [rbp+4]
4:  mov     [rsp+52], eax
    movss   xmm0, [rsp+4]
    maxss   xmm0, [rsp+16]
    maxss   xmm0, [rsp+28]
    cvttss2si eax, xmm0
    inc     eax
    cmp     eax, [rbp+12]
    jle     5f
    mov     eax, [rbp+12]
5:  mov     [rsp+56], eax
    mov     eax, [rsp+44]               # (outside the tile: nothing)
    cmp     eax, [rsp+48]
    jge     .Lid_next
    mov     eax, [rsp+52]
    cmp     eax, [rsp+56]
    jge     .Lid_next
    call    id_face_shade               # -> [rsp+8+40] the colour
    # edge functions, stepped: w_k = (a_k x + b_k y + c_k) / area
    movss   xmm6, [rip+in_one]
    divss   xmm6, [rsp+36]              # 1 / area
    xor     ecx, ecx
6:  lea     eax, [rcx+1]                # edge (k+1 -> k+2) for corner k
    cmp     eax, 3
    jb      61f
    xor     eax, eax
61: lea     edx, [rax+1]
    cmp     edx, 3
    jb      62f
    xor     edx, edx
62: imul    eax, eax, 12
    imul    edx, edx, 12
    movss   xmm0, [rsp+rax+4]           # a = -(y2 - y1), b = x2 - x1
    subss   xmm0, [rsp+rdx+4]
    movss   xmm1, [rsp+rdx]
    subss   xmm1, [rsp+rax]
    movss   xmm2, xmm1                  # c = -(x2 - x1) y1 + (y2 - y1) x1
    mulss   xmm2, [rsp+rax+4]
    movss   xmm3, xmm0
    mulss   xmm3, [rsp+rax]
    addss   xmm2, xmm3
    xorps   xmm3, xmm3
    subss   xmm3, xmm2
    mulss   xmm0, xmm6                  # (over the area)
    mulss   xmm1, xmm6
    mulss   xmm3, xmm6
    movss   [rsp+64+rcx*4], xmm0        # a_k (camera corners no longer
    movss   [rsp+76+rcx*4], xmm1        #  needed)
    movss   [rsp+88+rcx*4], xmm3
    inc     ecx
    cmp     ecx, 3
    jb      6b
    mov     r9d, [rsp+52]
.Lid_row:
    cmp     r9d, [rsp+56]
    jge     .Lid_next
    mov     r8d, [rsp+44]
    cvtsi2ss xmm6, r8d                  # w_k at (x0 + .5, y + .5)
    addss   xmm6, [rip+in_half]
    cvtsi2ss xmm7, r9d
    addss   xmm7, [rip+in_half]
    movss   xmm0, [rsp+64]
    mulss   xmm0, xmm6
    movss   xmm1, [rsp+76]
    mulss   xmm1, xmm7
    addss   xmm0, xmm1
    addss   xmm0, [rsp+88]              # w0
    movss   xmm1, [rsp+68]
    mulss   xmm1, xmm6
    movss   xmm2, [rsp+80]
    mulss   xmm2, xmm7
    addss   xmm1, xmm2
    addss   xmm1, [rsp+92]              # w1
    movss   xmm2, [rsp+72]
    mulss   xmm2, xmm6
    movss   xmm3, [rsp+84]
    mulss   xmm3, xmm7
    addss   xmm2, xmm3
    addss   xmm2, [rsp+96]              # w2
    xorps   xmm5, xmm5
.Lid_px:
    cmp     r8d, [rsp+48]
    jge     .Lid_rnext
    comiss  xmm0, xmm5
    jb      .Lid_pnext
    comiss  xmm1, xmm5
    jb      .Lid_pnext
    comiss  xmm2, xmm5
    jb      .Lid_pnext
    movss   xmm7, xmm0                  # 1/z
    mulss   xmm7, [rsp+8]
    movss   xmm3, xmm1
    mulss   xmm3, [rsp+20]
    addss   xmm7, xmm3
    movss   xmm3, xmm2
    mulss   xmm3, [rsp+32]
    addss   xmm7, xmm3
    mov     eax, [rsp+40]
    call    id_plot
.Lid_pnext:
    addss   xmm0, [rsp+64]
    addss   xmm1, [rsp+68]
    addss   xmm2, [rsp+72]
    inc     r8d
    jmp     .Lid_px
.Lid_rnext:
    inc     r9d
    jmp     .Lid_row
.Lid_next:
    inc     r13d
    jmp     .Lid_tri
.Lid_out:
    add     rsp, 104+64*24
    pop     rbp
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# id_face_shade (id_tris' frame: camera corners at +64) -> [+40] = the
#   colour: ambient + diffuse x |n.z| / |n|
id_face_shade:
    lea     rax, [rsp+8]
    movss   xmm0, [rax+64+12]           # e1 = c1 - c0, e2 = c2 - c0
    subss   xmm0, [rax+64]
    movss   xmm1, [rax+64+16]
    subss   xmm1, [rax+64+4]
    movss   xmm2, [rax+64+20]
    subss   xmm2, [rax+64+8]
    movss   xmm3, [rax+64+24]
    subss   xmm3, [rax+64]
    movss   xmm4, [rax+64+28]
    subss   xmm4, [rax+64+4]
    movss   xmm5, [rax+64+32]
    subss   xmm5, [rax+64+8]
    movss   xmm6, xmm1                  # n = e1 x e2
    mulss   xmm6, xmm5
    movss   xmm7, xmm2
    mulss   xmm7, xmm4
    subss   xmm6, xmm7                  # nx
    movss   xmm7, xmm2
    mulss   xmm7, xmm3
    mulss   xmm5, xmm0
    subss   xmm7, xmm5                  # ny
    mulss   xmm0, xmm4
    mulss   xmm1, xmm3
    subss   xmm0, xmm1                  # nz
    movss   xmm1, xmm6
    mulss   xmm1, xmm6
    movss   xmm2, xmm7
    mulss   xmm2, xmm7
    addss   xmm1, xmm2
    movss   xmm2, xmm0
    mulss   xmm2, xmm0
    addss   xmm1, xmm2
    sqrtss  xmm1, xmm1
    maxss   xmm1, [rip+in_tiny]
    andps   xmm0, [rip+in_abs]
    divss   xmm0, xmm1
    mulss   xmm0, [rip+in_dif]
    addss   xmm0, [rip+in_amb]
    push    rax
    call    id_colour
    pop     rcx
    mov     [rcx+40], eax
    ret

# id_edge(rdi=p, rsi=q; xmm6, xmm7 = point) -> xmm0
id_edge:
    movss   xmm0, [rsi]
    subss   xmm0, [rdi]
    movss   xmm1, xmm7
    subss   xmm1, [rdi+4]
    mulss   xmm0, xmm1
    movss   xmm1, [rsi+4]
    subss   xmm1, [rdi+4]
    movss   xmm2, xmm6
    subss   xmm2, [rdi]
    mulss   xmm1, xmm2
    subss   xmm0, xmm1
    ret

.section .note.GNU-stack,"",@progbits
