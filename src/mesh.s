# =============================================================================
#  BeeModel - polygon meshes: storage, builder and primitive generators.
#
#  A mesh is one mmap'd block: a 128-byte header followed by flat arrays
#  (positions, polygon offsets, loops, unique edges, triangles). Polygons are
#  stored as loops (vertex index lists) so n-gons are first class; edges and
#  a fan triangulation are derived by mesh_finish.
# =============================================================================
.intel_syntax noprefix
.include "const.inc"

# exports
.globl mesh_new
.globl mesh_free
.globl mesh_ref
.globl mesh_unref
.globl mesh_copy
.globl mesh_uv_alloc
.globl mesh_seam_alloc
.globl mesh_uv_free
.globl mesh_vcol_alloc
.globl mesh_add_vert
.globl mesh_add_poly
.globl mesh_finish
.globl mesh_bbox
.globl prim_cube
.globl prim_plane
.globl prim_grid
.globl prim_uvsphere
.globl prim_cylinder
.globl prim_cone
.globl prim_torus
.globl prim_camera
.globl prim_light
.globl sincos

.equ MAP_ANON_PRIV, 0x22

.section .rodata
.align 4
mf_one:     .float 1.0
mf_half:    .float 0.5
mf_neg1:    .float -1.0
mf_flat:    .float 1.0e-10
mf_2pi:     .float 6.2831853
mf_pi:      .float 3.1415927
mf_big:     .float 1.0e30
mf_nbig:    .float -1.0e30
cube_v:     .float -1,-1,-1,  1,-1,-1,  1,-1,1,  -1,-1,1
            .float -1, 1,-1,  1, 1,-1,  1, 1,1,  -1, 1,1
cube_f:     .long 0,1,2,3, 7,6,5,4, 0,4,5,1, 1,5,6,2, 2,6,7,3, 3,7,4,0
cam_v:      .float 0,0,0,  -0.5,-0.35,-1,  0.5,-0.35,-1,  0.5,0.35,-1,  -0.5,0.35,-1
            .float -0.3,0.45,-1,  0.3,0.45,-1,  0,0.7,-1
cam_f:      .long 0,1,2, 0,2,3, 0,3,4, 0,4,1, 1,4,3,2, 5,6,7
light_v:    .float 0,0.25,0, 0.25,0,0, 0,0,0.25, -0.25,0,0, 0,0,-0.25, 0,-0.25,0
light_f:    .long 0,1,2, 0,2,3, 0,3,4, 0,4,1, 5,2,1, 5,3,2, 5,4,3, 5,1,4

.section .bss
.align 8
pbuf:       .skip 4*64                  # polygon index scratch

.text

# sincos(xmm0=angle) -> xmm0 = sin, xmm1 = cos
sincos:
    sub     rsp, 8
    movss   [rsp], xmm0
    fld     dword ptr [rsp]
    fsincos
    fstp    dword ptr [rsp+4]           # cos
    fstp    dword ptr [rsp]             # sin
    movss   xmm0, [rsp]
    movss   xmm1, [rsp+4]
    add     rsp, 8
    ret

# -----------------------------------------------------------------------------
# mesh_new(edi=max verts, esi=max loops, edx=max polys) -> rax = mesh or 0
# -----------------------------------------------------------------------------
mesh_new:
    push    rbx
    push    r12
    push    r13
    push    r14
    mov     r12d, edi
    mov     r13d, esi
    mov     r14d, edx
    # bytes = hdr + 12v + 4(p+1) + 4l + 8l + 12l + 4l (tri -> poly) + v (sel)
    mov     eax, r12d
    imul    rax, rax, 13
    lea     rcx, [r14+1]
    lea     rax, [rax+rcx*4]
    mov     rcx, r13
    imul    rcx, rcx, 28
    add     rax, rcx
    add     rax, ME_HDR+4095
    and     rax, -4096
    mov     rbx, rax
    xor     edi, edi
    mov     rsi, rax
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
1:  mov     [rax+ME_BYTES], rbx
    mov     dword ptr [rax+ME_REFS], 1
    mov     [rax+ME_CAPV], r12d
    mov     [rax+ME_CAPL], r13d
    mov     [rax+ME_CAPP], r14d
    call    mesh_set_ptrs
9:  pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# mesh_set_ptrs(rax=mesh) - array pointers from the capacities (rax kept)
mesh_set_ptrs:
    lea     rcx, [rax+ME_HDR]
    mov     [rax+ME_POS], rcx
    mov     edx, [rax+ME_CAPV]
    imul    rdx, rdx, 12
    add     rcx, rdx
    mov     [rax+ME_POFF], rcx
    mov     edx, [rax+ME_CAPP]
    lea     rcx, [rcx+rdx*4+4]
    mov     [rax+ME_LOOPS], rcx
    mov     edx, [rax+ME_CAPL]
    lea     rcx, [rcx+rdx*4]
    mov     [rax+ME_EDGES], rcx
    lea     rcx, [rcx+rdx*8]
    mov     [rax+ME_TRIS], rcx
    lea     rcx, [rcx+rdx*8]            # 12 bytes per loop
    lea     rcx, [rcx+rdx*4]
    mov     [rax+ME_TPOLY], rcx
    lea     rcx, [rcx+rdx*4]
    mov     [rax+ME_VSEL], rcx
    ret

# mesh_ref(rdi=mesh) / mesh_unref(rdi=mesh) - meshes are shared by objects
# and undo snapshots; the last reference frees the mesh
mesh_ref:
    test    rdi, rdi
    jz      1f
    inc     dword ptr [rdi+ME_REFS]
1:  ret
mesh_unref:
    test    rdi, rdi
    jz      1f
    dec     dword ptr [rdi+ME_REFS]
    jz      mesh_free
1:  ret

mesh_free:
    test    rdi, rdi
    jz      1f
    push    rdi
    call    mesh_forget                 # caches keyed on it let go
    mov     rdi, [rsp]                  # its UVs and seams
    call    mesh_uv_free
    pop     rdi
    mov     rsi, [rdi+ME_BYTES]
    mov     eax, SYS_MUNMAP
    syscall
1:  ret

# mesh_uv_alloc(rdi=mesh) -> rax = its UVs (made, zero, when it had none;
#   0: no memory). mesh_seam_alloc: the same for its seams.
mesh_uv_alloc:
    mov     rax, [rdi+ME_UV]
    test    rax, rax
    jnz     1f
    push    rdi
    mov     esi, [rdi+ME_CAPL]
    shl     rsi, 3
    call    uv_map
    pop     rdi
    mov     [rdi+ME_UV], rax
1:  ret
mesh_seam_alloc:
    mov     rax, [rdi+ME_SEAM]
    test    rax, rax
    jnz     1f
    push    rdi
    mov     esi, [rdi+ME_CAPL]
    call    uv_map
    pop     rdi
    mov     [rdi+ME_SEAM], rax
1:  ret

# mesh_vcol_alloc(rdi=mesh) -> rax = its vertex colours (made white when it
#   had none; 0: no memory)
mesh_vcol_alloc:
    mov     rax, [rdi+ME_VCOL]
    test    rax, rax
    jnz     1f
    push    rdi
    mov     esi, [rdi+ME_CAPV]
    shl     rsi, 2
    call    uv_map
    pop     rdi
    test    rax, rax
    jz      1f
    mov     [rdi+ME_VCOL], rax
    push    rdi
    mov     rdi, rax
    mov     rcx, [rsp]
    mov     ecx, [rcx+ME_CAPV]
    mov     eax, -1
    rep     stosd
    pop     rdi
    mov     rax, [rdi+ME_VCOL]
1:  ret

# uv_map(esi=bytes) -> rax = zeroed private mapping, or 0
uv_map:
    add     rsi, 4095
    and     rsi, -4096
    jnz     1f
    mov     esi, 4096
1:  xor     edi, edi
    mov     edx, PROT_RW
    mov     r10d, MAP_ANON_PRIV
    mov     r8, -1
    xor     r9d, r9d
    mov     eax, SYS_MMAP
    syscall
    cmp     rax, -4096
    jb      2f
    xor     eax, eax
2:  ret

# mesh_uv_free(rdi=mesh) - its UVs and seams go
mesh_uv_free:
    push    rbx
    mov     rbx, rdi
    mov     rdi, [rbx+ME_UV]
    test    rdi, rdi
    jz      1f
    mov     esi, [rbx+ME_CAPL]
    shl     rsi, 3
    call    uv_unmap
    mov     qword ptr [rbx+ME_UV], 0
1:  mov     rdi, [rbx+ME_SEAM]
    test    rdi, rdi
    jz      2f
    mov     esi, [rbx+ME_CAPL]
    call    uv_unmap
    mov     qword ptr [rbx+ME_SEAM], 0
2:  mov     rdi, [rbx+ME_VCOL]
    test    rdi, rdi
    jz      3f
    mov     esi, [rbx+ME_CAPV]
    shl     rsi, 2
    call    uv_unmap
    mov     qword ptr [rbx+ME_VCOL], 0
3:  pop     rbx
    ret
uv_unmap:
    add     rsi, 4095
    and     rsi, -4096
    jnz     1f
    mov     esi, 4096
1:  mov     eax, SYS_MUNMAP
    syscall
    ret

# mesh_copy(rdi=mesh) -> rax = independent copy
mesh_copy:
    push    rbx
    mov     rbx, rdi
    mov     edi, [rbx+ME_CAPV]
    mov     esi, [rbx+ME_CAPL]
    mov     edx, [rbx+ME_CAPP]
    call    mesh_new
    test    rax, rax
    jz      9f
    push    rax
    mov     rcx, [rbx+ME_BYTES]         # same layout: copy the whole block
    sub     rcx, ME_HDR
    lea     rsi, [rbx+ME_HDR]
    lea     rdi, [rax+ME_HDR]
    rep     movsb
    pop     rax
    mov     rcx, [rbx]                  # counts
    mov     [rax], rcx
    mov     rcx, [rbx+8]
    mov     [rax+8], rcx
    mov     ecx, [rbx+ME_NTRIS]
    mov     [rax+ME_NTRIS], ecx
    lea     rsi, [rbx+ME_BMIN]
    lea     rdi, [rax+ME_BMIN]
    mov     ecx, 24
    rep     movsb
    push    rax                         # its UVs and seams, copied
    cmp     qword ptr [rbx+ME_UV], 0
    je      1f
    mov     rdi, rax
    call    mesh_uv_alloc
    test    rax, rax
    jz      1f
    mov     rdi, rax
    mov     rsi, [rbx+ME_UV]
    mov     ecx, [rbx+ME_NLOOPS]
    shl     rcx, 3
    rep     movsb
1:  cmp     qword ptr [rbx+ME_SEAM], 0
    je      2f
    mov     rdi, [rsp]
    call    mesh_seam_alloc
    test    rax, rax
    jz      2f
    mov     rdi, rax
    mov     rsi, [rbx+ME_SEAM]
    mov     ecx, [rbx+ME_NLOOPS]
    rep     movsb
2:  cmp     qword ptr [rbx+ME_VCOL], 0  # (and vertex colours)
    je      3f
    mov     rdi, [rsp]
    call    mesh_vcol_alloc
    test    rax, rax
    jz      3f
    mov     rdi, rax
    mov     rsi, [rbx+ME_VCOL]
    mov     ecx, [rbx+ME_NVERTS]
    rep     movsd
3:  pop     rax
9:  pop     rbx
    ret

# mesh_add_vert(rdi=mesh, xmm0..2 = x y z) -> eax = index
mesh_add_vert:
    mov     eax, [rdi+ME_NVERTS]
    mov     rcx, [rdi+ME_POS]
    lea     rdx, [rax+rax*2]
    movss   [rcx+rdx*4], xmm0
    movss   [rcx+rdx*4+4], xmm1
    movss   [rcx+rdx*4+8], xmm2
    inc     dword ptr [rdi+ME_NVERTS]
    ret

# mesh_add_poly(rdi=mesh, rsi=u32 vertex indices, edx=count)
mesh_add_poly:
    mov     ecx, [rdi+ME_NPOLYS]
    mov     r8, [rdi+ME_POFF]
    mov     eax, [rdi+ME_NLOOPS]
    mov     [r8+rcx*4], eax             # start of this polygon
    mov     r9, [rdi+ME_LOOPS]
    xor     r10d, r10d
1:  cmp     r10d, edx
    jae     2f
    mov     r11d, [rsi+r10*4]
    mov     [r9+rax*4], r11d
    inc     eax
    inc     r10d
    jmp     1b
2:  mov     [rdi+ME_NLOOPS], eax
    inc     ecx
    mov     [rdi+ME_NPOLYS], ecx
    mov     [r8+rcx*4], eax             # sentinel
    ret

# -----------------------------------------------------------------------------
# ear_tris (mesh_finish: rbx mesh, r12d polygon, r13d / r14d its loops) -
#   its triangles: the fan, except that a flat ear (three corners in a line)
#   waits until it is not flat; convex polygons get exactly the fan
ear_tris:
    push    rbp
    push    r15
    sub     rsp, 1032
    mov     r9, [rbx+ME_LOOPS]
    mov     ebp, r14d                   # n
    sub     ebp, r13d
    xor     ecx, ecx
1:  cmp     ecx, ebp
    jae     2f
    lea     eax, [r13+rcx]
    mov     eax, [r9+rax*4]
    mov     [rsp+rcx*4], eax
    inc     ecx
    jmp     1b
2:  mov     r15d, 1                     # tip
    xor     r8d, r8d                    # flat ears in a row
.Let_top:
    cmp     ebp, 3
    jbe     .Let_rest
    cmp     r8d, ebp
    jae     .Let_rest
    cmp     r15d, ebp
    jb      3f
    xor     r15d, r15d
3:  lea     eax, [r15+rbp-1]            # prev, next
    xor     edx, edx
    div     ebp
    mov     r10d, edx
    lea     eax, [r15+1]
    xor     edx, edx
    div     ebp
    mov     r11d, edx
    mov     edi, [rsp+r10*4]
    mov     esi, [rsp+r15*4]
    mov     edx, [rsp+r11*4]
    call    flat3
    test    eax, eax
    jz      4f
    inc     r15d                        # flat: the next corner first
    inc     r8d
    jmp     .Let_top
4:  mov     edi, [rsp+r10*4]
    mov     esi, [rsp+r15*4]
    mov     edx, [rsp+r11*4]
    call    emit_tri
    mov     ecx, r15d                   # the tip leaves
5:  lea     eax, [rcx+1]
    cmp     eax, ebp
    jae     6f
    mov     eax, [rsp+rax*4]
    mov     [rsp+rcx*4], eax
    inc     ecx
    jmp     5b
6:  dec     ebp
    xor     r8d, r8d
    jmp     .Let_top
.Let_rest:
    mov     ecx, 1                      # what is left: a fan
7:  lea     eax, [rcx+1]
    cmp     eax, ebp
    jae     9f
    mov     edi, [rsp]
    mov     esi, [rsp+rcx*4]
    mov     edx, [rsp+rax*4]
    push    rcx
    call    emit_tri
    pop     rcx
    inc     ecx
    jmp     7b
9:  add     rsp, 1032
    pop     r15
    pop     rbp
    ret

# emit_tri(edi, esi, edx; rbx mesh, r12d polygon)
emit_tri:
    mov     ecx, [rbx+ME_NTRIS]
    lea     rax, [rcx+rcx*2]
    mov     r10, [rbx+ME_TRIS]
    mov     [r10+rax*4], edi
    mov     [r10+rax*4+4], esi
    mov     [r10+rax*4+8], edx
    mov     r10, [rbx+ME_TPOLY]
    mov     [r10+rcx*4], r12d
    inc     dword ptr [rbx+ME_NTRIS]
    ret

# flat3(edi, esi, edx = vertices; rbx mesh) -> eax = 1 if they are (nearly)
#   in a line: |(b - a) x (c - a)|^2 <= 1e-10 |b - a|^2 |c - a|^2
flat3:
    mov     rax, [rbx+ME_POS]
    lea     rdi, [rdi+rdi*2]
    lea     rsi, [rsi+rsi*2]
    lea     rdx, [rdx+rdx*2]
    movss   xmm0, [rax+rsi*4]           # u = b - a
    subss   xmm0, [rax+rdi*4]
    movss   xmm1, [rax+rsi*4+4]
    subss   xmm1, [rax+rdi*4+4]
    movss   xmm2, [rax+rsi*4+8]
    subss   xmm2, [rax+rdi*4+8]
    movss   xmm3, [rax+rdx*4]           # w = c - a
    subss   xmm3, [rax+rdi*4]
    movss   xmm4, [rax+rdx*4+4]
    subss   xmm4, [rax+rdi*4+4]
    movss   xmm5, [rax+rdx*4+8]
    subss   xmm5, [rax+rdi*4+8]
    movss   xmm6, xmm1                  # x = uy wz - uz wy
    mulss   xmm6, xmm5
    movss   xmm7, xmm2
    mulss   xmm7, xmm4
    subss   xmm6, xmm7
    mulss   xmm6, xmm6
    movss   xmm7, xmm2                  # y = uz wx - ux wz
    mulss   xmm7, xmm3
    movss   xmm8, xmm0
    mulss   xmm8, xmm5
    subss   xmm7, xmm8
    mulss   xmm7, xmm7
    addss   xmm6, xmm7
    movss   xmm7, xmm0                  # z = ux wy - uy wx
    mulss   xmm7, xmm4
    movss   xmm8, xmm1
    mulss   xmm8, xmm3
    subss   xmm7, xmm8
    mulss   xmm7, xmm7
    addss   xmm6, xmm7
    mulss   xmm0, xmm0                  # |u|^2 |w|^2 1e-10
    mulss   xmm1, xmm1
    mulss   xmm2, xmm2
    addss   xmm0, xmm1
    addss   xmm0, xmm2
    mulss   xmm3, xmm3
    mulss   xmm4, xmm4
    mulss   xmm5, xmm5
    addss   xmm3, xmm4
    addss   xmm3, xmm5
    mulss   xmm0, xmm3
    mulss   xmm0, [rip+mf_flat]
    xor     eax, eax
    comiss  xmm6, xmm0
    setbe   al
    ret

# mesh_finish(rdi=mesh) - unique edges, fan triangles, bounding box
# -----------------------------------------------------------------------------
mesh_finish:
    push    rbx
    push    rbp
    push    r12
    push    r13
    push    r14
    push    r15
    sub     rsp, 8
    mov     rbx, rdi
    # edge hash: power of two >= 2 * loops, keys (lo<<32|hi)+1 in the frame arena
    mov     eax, [rbx+ME_NLOOPS]
    add     eax, eax
    mov     ebp, 16
1:  cmp     ebp, eax
    jae     2f
    add     ebp, ebp
    jmp     1b
2:  lea     rdi, [rip+frame_arena]
    mov     esi, ebp
    shl     esi, 3
    call    arena_alloc
    mov     r15, rax                    # hash table (0 = empty)
    mov     rdi, rax
    mov     ecx, ebp
    xor     eax, eax
    rep     stosq
    mov     dword ptr [rbx+ME_NEDGES], 0
    mov     dword ptr [rbx+ME_NTRIS], 0
    xor     r12d, r12d                  # polygon
.Lmf_poly:
    cmp     r12d, [rbx+ME_NPOLYS]
    jae     .Lmf_bbox
    mov     r8, [rbx+ME_POFF]
    mov     r13d, [r8+r12*4]            # first loop
    mov     r14d, [r8+r12*4+4]          # end loop
    # fan triangles (v0, vi, vi+1); polygons with corners in a straight
    # line (cuts leave them) skip the flat ones
    mov     r9, [rbx+ME_LOOPS]
    mov     eax, r14d
    sub     eax, r13d
    cmp     eax, 4
    jb      31f
    cmp     eax, 256
    ja      31f
    call    ear_tris
    mov     r9, [rbx+ME_LOOPS]
    jmp     4f
31: lea     ecx, [r13+1]
3:  lea     eax, [rcx+1]
    cmp     eax, r14d
    jae     4f
    mov     edx, [rbx+ME_NTRIS]
    lea     rdx, [rdx+rdx*2]
    mov     r10, [rbx+ME_TRIS]
    mov     r11d, [r9+r13*4]
    mov     [r10+rdx*4], r11d
    mov     r11d, [r9+rcx*4]
    mov     [r10+rdx*4+4], r11d
    mov     r11d, [r9+rax*4]
    mov     [r10+rdx*4+8], r11d
    mov     edx, [rbx+ME_NTRIS]         # its polygon
    mov     r10, [rbx+ME_TPOLY]
    mov     [r10+rdx*4], r12d
    inc     dword ptr [rbx+ME_NTRIS]
    inc     ecx
    jmp     3b
4:  # edges (each consecutive loop pair, wrapping)
    mov     ecx, r13d
5:  cmp     ecx, r14d
    jae     .Lmf_next
    mov     eax, [r9+rcx*4]             # a
    lea     edx, [rcx+1]
    cmp     edx, r14d
    jb      6f
    mov     edx, r13d
6:  mov     edx, [r9+rdx*4]             # b
    cmp     eax, edx
    jbe     7f
    xchg    eax, edx
7:  mov     r10d, eax                   # key = (lo << 32 | hi) + 1
    shl     r10, 32
    or      r10, rdx
    inc     r10
    mov     r11, r10                    # hash slot
    imul    r11, r11, 0x2545f491
    shr     r11, 16
    lea     edi, [rbp-1]
    and     r11, rdi
8:  mov     rsi, [r15+r11*8]
    test    rsi, rsi
    jz      81f
    cmp     rsi, r10
    je      82f                         # already known
    inc     r11
    and     r11, rdi
    jmp     8b
81: mov     [r15+r11*8], r10
    mov     esi, [rbx+ME_NEDGES]
    mov     r11, [rbx+ME_EDGES]
    mov     [r11+rsi*8], eax
    mov     [r11+rsi*8+4], edx
    inc     dword ptr [rbx+ME_NEDGES]
82: inc     ecx
    jmp     5b
.Lmf_next:
    inc     r12d
    jmp     .Lmf_poly
.Lmf_bbox:
    mov     rdi, rbx
    call    mesh_bbox
    add     rsp, 8
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbp
    pop     rbx
    ret

# mesh_bbox(rdi=mesh) - bounding box of the positions
mesh_bbox:
    push    rbx
    mov     rbx, rdi
    movss   xmm0, [rip+mf_big]          # min
    movss   xmm1, xmm0
    movss   xmm2, xmm0
    movss   xmm3, [rip+mf_nbig]         # max
    movss   xmm4, xmm3
    movss   xmm5, xmm3
    mov     rsi, [rbx+ME_POS]
    mov     ecx, [rbx+ME_NVERTS]
9:  test    ecx, ecx
    jz      10f
    minss   xmm0, [rsi]
    minss   xmm1, [rsi+4]
    minss   xmm2, [rsi+8]
    maxss   xmm3, [rsi]
    maxss   xmm4, [rsi+4]
    maxss   xmm5, [rsi+8]
    add     rsi, 12
    dec     ecx
    jmp     9b
10: movss   [rbx+ME_BMIN], xmm0
    movss   [rbx+ME_BMIN+4], xmm1
    movss   [rbx+ME_BMIN+8], xmm2
    movss   [rbx+ME_BMAX], xmm3
    movss   [rbx+ME_BMAX+4], xmm4
    movss   [rbx+ME_BMAX+8], xmm5
    pop     rbx
    ret

# -----------------------------------------------------------------------------
# Primitives (Y up). Each returns rax = finished mesh.
# -----------------------------------------------------------------------------
# from_tables(rdi=floats, esi=nverts, rdx=u32 polys, ecx=npolys, r8=sizes[]
#             (byte per polygon)) -> rax
from_tables:
    push    rbx
    push    rbp
    push    r12
    push    r13
    push    r14
    push    r15
    sub     rsp, 8
    mov     r12, rdi
    mov     r13d, esi
    mov     r14, rdx
    mov     r15d, ecx
    mov     rbp, r8
    xor     eax, eax                    # total loops
    xor     ecx, ecx
1:  cmp     ecx, r15d
    jae     2f
    movzx   edx, byte ptr [rbp+rcx]
    add     eax, edx
    inc     ecx
    jmp     1b
2:  mov     edi, r13d
    mov     esi, eax
    mov     edx, r15d
    call    mesh_new
    mov     rbx, rax
    xor     ecx, ecx
3:  cmp     ecx, r13d
    jae     4f
    lea     rax, [rcx+rcx*2]
    movss   xmm0, [r12+rax*4]
    movss   xmm1, [r12+rax*4+4]
    movss   xmm2, [r12+rax*4+8]
    push    rcx
    mov     rdi, rbx
    call    mesh_add_vert
    pop     rcx
    inc     ecx
    jmp     3b
4:  xor     ecx, ecx
5:  cmp     ecx, r15d
    jae     6f
    movzx   edx, byte ptr [rbp+rcx]
    push    rcx
    push    rdx
    mov     rdi, rbx
    mov     rsi, r14
    call    mesh_add_poly
    pop     rdx
    pop     rcx
    lea     r14, [r14+rdx*4]
    inc     ecx
    jmp     5b
6:  mov     rdi, rbx
    call    mesh_finish
    mov     rax, rbx
    add     rsp, 8
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbp
    pop     rbx
    ret

.section .rodata
sz_quad6:   .byte 4,4,4,4,4,4
sz_cam:     .byte 3,3,3,3,4,3
sz_light:   .byte 3,3,3,3,3,3,3,3
.text

prim_cube:
    lea     rdi, [rip+cube_v]
    mov     esi, 8
    lea     rdx, [rip+cube_f]
    mov     ecx, 6
    lea     r8, [rip+sz_quad6]
    jmp     from_tables
prim_camera:
    lea     rdi, [rip+cam_v]
    mov     esi, 8
    lea     rdx, [rip+cam_f]
    mov     ecx, 6
    lea     r8, [rip+sz_cam]
    jmp     from_tables
prim_light:
    lea     rdi, [rip+light_v]
    mov     esi, 6
    lea     rdx, [rip+light_f]
    mov     ecx, 8
    lea     r8, [rip+sz_light]
    jmp     from_tables

prim_plane:
    mov     edi, 1
    jmp     prim_grid_n
prim_grid:
    mov     edi, 10
# prim_grid_n(edi=subdivisions) - 2x2 m on the XZ plane
prim_grid_n:
    push    rbx
    push    r12
    push    r13
    push    r14
    sub     rsp, 8
    mov     r12d, edi                   # n
    lea     eax, [r12+1]
    imul    eax, eax                    # verts
    mov     edi, eax
    mov     esi, r12d
    imul    esi, r12d
    mov     edx, esi
    shl     esi, 2
    call    mesh_new
    mov     rbx, rax
    xor     r13d, r13d                  # row (z)
1:  cmp     r13d, r12d
    ja      3f
    xor     r14d, r14d                  # column (x)
2:  cmp     r14d, r12d
    ja      21f
    cvtsi2ss xmm0, r14d                 # x = -1 + 2*c/n
    addss   xmm0, xmm0
    cvtsi2ss xmm3, r12d
    divss   xmm0, xmm3
    subss   xmm0, [rip+mf_one]
    xorps   xmm1, xmm1
    cvtsi2ss xmm2, r13d
    addss   xmm2, xmm2
    divss   xmm2, xmm3
    subss   xmm2, [rip+mf_one]
    mov     rdi, rbx
    call    mesh_add_vert
    inc     r14d
    jmp     2b
21: inc     r13d
    jmp     1b
3:  xor     r13d, r13d
4:  cmp     r13d, r12d
    jae     6f
    xor     r14d, r14d
5:  cmp     r14d, r12d
    jae     51f
    lea     ecx, [r12+1]                # quad (r,c) (r+1,c) (r+1,c+1) (r,c+1):
    mov     eax, r13d                   #  facing up (+Y)
    imul    eax, ecx
    add     eax, r14d
    lea     rdx, [rip+pbuf]
    mov     [rdx], eax
    lea     r8d, [rax+1]
    add     eax, ecx
    mov     [rdx+4], eax
    inc     eax
    mov     [rdx+8], eax
    mov     [rdx+12], r8d
    mov     rdi, rbx
    mov     rsi, rdx
    mov     edx, 4
    call    mesh_add_poly
    inc     r14d
    jmp     5b
51: inc     r13d
    jmp     4b
6:  mov     rdi, rbx
    call    mesh_finish
    mov     rax, rbx
    add     rsp, 8
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# ring_vert(rdi=mesh, ecx=i, edx=n, xmm4=radius, xmm5=y) - vertex on a circle
ring_vert:
    push    rdi
    sub     rsp, 16
    movss   [rsp], xmm4
    movss   [rsp+4], xmm5
    cvtsi2ss xmm0, ecx
    cvtsi2ss xmm1, edx
    divss   xmm0, xmm1
    mulss   xmm0, [rip+mf_2pi]
    call    sincos
    movss   xmm4, [rsp]
    movss   xmm2, xmm0                  # z = r*sin
    mulss   xmm2, xmm4
    movss   xmm0, xmm1                  # x = r*cos
    mulss   xmm0, xmm4
    movss   xmm1, [rsp+4]
    add     rsp, 16
    pop     rdi
    jmp     mesh_add_vert

# prim_cylinder / prim_cone: 32 segments, radius 1, height 2
prim_cone:
    mov     edi, 1
    jmp     prim_cyl_impl
prim_cylinder:
    xor     edi, edi
prim_cyl_impl:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    sub     rsp, 16
    mov     r15d, edi                   # 1 = cone
    mov     r12d, 32                    # segments
    mov     edi, 2*32+1
    mov     esi, 32*4+32*2
    mov     edx, 32+2
    call    mesh_new
    mov     rbx, rax
    xor     r13d, r13d                  # bottom ring at y = -1
1:  cmp     r13d, r12d
    jae     2f
    movss   xmm4, [rip+mf_one]
    movss   xmm5, [rip+mf_neg1]
    mov     rdi, rbx
    mov     ecx, r13d
    mov     edx, r12d
    call    ring_vert
    inc     r13d
    jmp     1b
2:  test    r15d, r15d
    jnz     3f
    xor     r13d, r13d                  # top ring at y = +1
21: cmp     r13d, r12d
    jae     4f
    movss   xmm4, [rip+mf_one]
    movss   xmm5, [rip+mf_one]
    mov     rdi, rbx
    mov     ecx, r13d
    mov     edx, r12d
    call    ring_vert
    inc     r13d
    jmp     21b
3:  xorps   xmm0, xmm0                  # cone apex
    movss   xmm1, [rip+mf_one]
    xorps   xmm2, xmm2
    mov     rdi, rbx
    call    mesh_add_vert
4:  xor     r13d, r13d                  # sides
5:  cmp     r13d, r12d
    jae     7f
    lea     r14, [rip+pbuf]
    lea     eax, [r13+1]
    xor     edx, edx
    div     r12d
    mov     ecx, edx                    # next index
    mov     [r14], r13d
    test    r15d, r15d
    jz      6f
    mov     [r14+4], r12d               # apex
    mov     [r14+8], ecx
    mov     rdi, rbx
    mov     rsi, r14
    mov     edx, 3
    call    mesh_add_poly
    inc     r13d
    jmp     5b
6:  lea     eax, [r13+32]
    mov     [r14+4], eax
    lea     eax, [rcx+32]
    mov     [r14+8], eax
    mov     [r14+12], ecx
    mov     rdi, rbx
    mov     rsi, r14
    mov     edx, 4
    call    mesh_add_poly
    inc     r13d
    jmp     5b
7:  # caps (n-gons), facing out: bottom forward, top reversed
    lea     r14, [rip+pbuf]
    xor     ecx, ecx
8:  cmp     ecx, r12d
    jae     9f
    mov     [r14+rcx*4], ecx
    inc     ecx
    jmp     8b
9:  mov     rdi, rbx
    mov     rsi, r14
    mov     edx, r12d
    call    mesh_add_poly
    test    r15d, r15d
    jnz     11f
    xor     ecx, ecx
10: cmp     ecx, r12d
    jae     101f
    mov     eax, 63
    sub     eax, ecx
    mov     [r14+rcx*4], eax
    inc     ecx
    jmp     10b
101:mov     rdi, rbx
    mov     rsi, r14
    mov     edx, r12d
    call    mesh_add_poly
11: mov     rdi, rbx
    call    mesh_finish
    mov     rax, rbx
    add     rsp, 16
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# prim_uvsphere: 32 segments x 16 rings, radius 1
prim_uvsphere:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    sub     rsp, 16
    mov     edi, 32*15+2
    mov     esi, 32*14*4+32*6
    mov     edx, 32*16
    call    mesh_new
    mov     rbx, rax
    xorps   xmm0, xmm0                  # 0 = top pole
    movss   xmm1, [rip+mf_one]
    xorps   xmm2, xmm2
    mov     rdi, rbx
    call    mesh_add_vert
    mov     r12d, 1                     # rings 1..15
1:  cmp     r12d, 16
    jae     3f
    cvtsi2ss xmm0, r12d                 # polar angle = pi * r / 16
    mulss   xmm0, [rip+mf_pi]
    mov     eax, 16
    cvtsi2ss xmm1, eax
    divss   xmm0, xmm1
    call    sincos
    movss   [rsp], xmm0                 # ring radius = sin
    movss   [rsp+4], xmm1               # y = cos
    xor     r13d, r13d
2:  cmp     r13d, 32
    jae     21f
    movss   xmm4, [rsp]
    movss   xmm5, [rsp+4]
    mov     rdi, rbx
    mov     ecx, r13d
    mov     edx, 32
    call    ring_vert
    inc     r13d
    jmp     2b
21: inc     r12d
    jmp     1b
3:  xorps   xmm0, xmm0                  # bottom pole = 1 + 15*32
    movss   xmm1, [rip+mf_neg1]
    xorps   xmm2, xmm2
    mov     rdi, rbx
    call    mesh_add_vert
    lea     r14, [rip+pbuf]
    xor     r13d, r13d                  # top fan
4:  cmp     r13d, 32
    jae     5f
    lea     eax, [r13+1]
    and     eax, 31
    mov     dword ptr [r14], 0
    lea     ecx, [rax+1]
    mov     [r14+4], ecx
    lea     ecx, [r13+1]
    mov     [r14+8], ecx
    mov     rdi, rbx
    mov     rsi, r14
    mov     edx, 3
    call    mesh_add_poly
    inc     r13d
    jmp     4b
5:  xor     r12d, r12d                  # quads between rings
6:  cmp     r12d, 14
    jae     8f
    xor     r13d, r13d
7:  cmp     r13d, 32
    jae     71f
    mov     eax, r12d
    shl     eax, 5
    inc     eax                         # ring r start
    lea     ecx, [r13+1]
    and     ecx, 31
    lea     edx, [rax+r13]
    mov     [r14], edx
    lea     edx, [rax+rcx]
    mov     [r14+4], edx
    lea     edx, [rax+rcx+32]
    mov     [r14+8], edx
    lea     edx, [rax+r13+32]
    mov     [r14+12], edx
    mov     rdi, rbx
    mov     rsi, r14
    mov     edx, 4
    call    mesh_add_poly
    inc     r13d
    jmp     7b
71: inc     r12d
    jmp     6b
8:  xor     r13d, r13d                  # bottom fan
9:  cmp     r13d, 32
    jae     10f
    lea     ecx, [r13+1]
    and     ecx, 31
    mov     eax, 14*32+1
    lea     edx, [rax+r13]
    mov     [r14], edx
    lea     edx, [rax+rcx]
    mov     [r14+4], edx
    mov     dword ptr [r14+8], 15*32+1
    mov     rdi, rbx
    mov     rsi, r14
    mov     edx, 3
    call    mesh_add_poly
    inc     r13d
    jmp     9b
10: mov     rdi, rbx
    call    mesh_finish
    mov     rax, rbx
    add     rsp, 16
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# prim_torus: 48 x 12, major radius 1, minor 0.25
prim_torus:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    sub     rsp, 32
    mov     edi, 48*12
    mov     esi, 48*12*4
    mov     edx, 48*12
    call    mesh_new
    mov     rbx, rax
    xor     r12d, r12d                  # major
1:  cmp     r12d, 48
    jae     4f
    cvtsi2ss xmm0, r12d
    mulss   xmm0, [rip+mf_2pi]
    mov     eax, 48
    cvtsi2ss xmm1, eax
    divss   xmm0, xmm1
    call    sincos
    movss   [rsp], xmm0                 # sin(u)
    movss   [rsp+4], xmm1               # cos(u)
    xor     r13d, r13d                  # minor
2:  cmp     r13d, 12
    jae     3f
    cvtsi2ss xmm0, r13d
    mulss   xmm0, [rip+mf_2pi]
    mov     eax, 12
    cvtsi2ss xmm1, eax
    divss   xmm0, xmm1
    call    sincos                      # xmm0 sin(v), xmm1 cos(v)
    mulss   xmm0, [rip+mf_quarter]      # y = r sin v
    mulss   xmm1, [rip+mf_quarter]
    addss   xmm1, [rip+mf_one]          # R + r cos v
    movss   [rsp+8], xmm0
    movss   xmm0, xmm1
    mulss   xmm0, [rsp+4]               # x = (R + r cos v) cos u
    movss   xmm2, xmm1
    mulss   xmm2, [rsp]                 # z = (R + r cos v) sin u
    movss   xmm1, [rsp+8]
    mov     rdi, rbx
    call    mesh_add_vert
    inc     r13d
    jmp     2b
3:  inc     r12d
    jmp     1b
4:  lea     r14, [rip+pbuf]
    xor     r12d, r12d
5:  cmp     r12d, 48
    jae     7f
    lea     eax, [r12+1]
    cmp     eax, 48
    jb      51f
    xor     eax, eax
51: imul    r15d, eax, 12               # next major ring
    imul    eax, r12d, 12
    xor     r13d, r13d
6:  cmp     r13d, 12
    jae     61f
    lea     ecx, [r13+1]
    cmp     ecx, 12
    jb      62f
    xor     ecx, ecx
62: lea     edx, [rax+r13]             # facing out
    mov     [r14], edx
    lea     edx, [rax+rcx]
    mov     [r14+4], edx
    lea     edx, [r15+rcx]
    mov     [r14+8], edx
    lea     edx, [r15+r13]
    mov     [r14+12], edx
    push    rax
    mov     rdi, rbx
    mov     rsi, r14
    mov     edx, 4
    call    mesh_add_poly
    pop     rax
    inc     r13d
    jmp     6b
61: inc     r12d
    jmp     5b
7:  mov     rdi, rbx
    call    mesh_finish
    mov     rax, rbx
    add     rsp, 32
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

.section .rodata
mf_quarter: .float 0.25

.section .note.GNU-stack,"",@progbits
