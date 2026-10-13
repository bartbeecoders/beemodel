# =============================================================================
#  BeeModel - UV maps: seams, unwrapping, packing
#
#  A mesh may carry UVs (ME_UV: u, v per loop) and seams (ME_SEAM: per loop,
#  the edge from it to the next loop of its polygon). Topology for UV work:
#  every loop's next and twin (the loop running the same edge backwards,
#  found through a hash of directed edges); islands are polygons joined
#  across edges that are not seams, UV vertices are loops at one vertex
#  joined across such edges (union-find), so a seam splits a vertex even
#  inside one island (a cylinder cut once).
#
#  Unwrap (LSCM, Levy et al. 2002): per island, each triangle in its own
#  plane gives two rows of the conformal energy |sum W_j (u_j + i v_j)|^2 /
#  2A; two vertices are pinned (the extremes of a planar projection, which
#  is also the start) and the normal equations are solved by conjugate
#  gradients with a Jacobi preconditioner, matrix-free (A^T A x as two
#  passes over the triangles), in doubles. Smart projection groups
#  polygons whose normals lie within 66 degrees of a seed and projects each
#  group flat. Packing scales every island to the same texel density, turns
#  it to its smallest bounding box, and places the boxes on a skyline
#  (tallest first, lowest place, then leftmost) inside the unit square.
# =============================================================================
.intel_syntax noprefix
.include "const.inc"
.include "macros.inc"

.globl uv_unwrap
.globl uv_smart
.globl uv_pack
.globl uv_seams
.globl uv_stat
.globl uv_cow
.globl uv_select_island
.globl tri_area3
.globl tri_area2
.globl angle3
.globl angle2

.equ UV_NONE,   0xffffffff

.section .rodata
.align 8
ud_one:         .double 1.0
ud_zero:        .double 0.0
ud_tiny:        .double 1.0e-300
ud_tol2:        .double 1.0e-14                 # residual^2, relative
ud_half:        .double 0.5
uf_one:         .float 1.0
uf_half:        .float 0.5
uf_tiny:        .float 1.0e-20
uf_cos66:       .float 0.4067366                # smart projection
uf_big:         .float 3.0e38
uf_nbig:        .float -3.0e38
uf_step:        .float 0.03490659               # 2 degrees
uf_deg:         .float 57.29578
uf_margin:      .float 0.01                     # packing gap, of the size
uf_widen:       .float 1.08
uf_fit:         .float 1.0001                   # (rounding at the right edge)
uf_cos30:       .float 0.8660254
uf_mone:        .float -1.0
uf_ovn:         .float 256.0
.align 16
uf_absmask:     .long 0x7fffffff, 0x7fffffff, 0x7fffffff, 0x7fffffff
hash_k:         .quad 0x9E3779B97F4A7C15
s_uv_none:      .asciz "  uv: select a mesh"
s_uv_mem:       .asciz "  uv: out of memory"
s_uv_islands:   .asciz "  uv: islands "
s_uv_seams:     .asciz "  uv: seams "

.section .bss
.align 8
ut_m:           .skip 8                 # the mesh being worked on
ut_nl:          .skip 4
ut_np:          .skip 4
ut_nisl:        .skip 4
ut_serial:      .skip 4
.align 8
ut_lpoly:       .skip 8                 # per loop: its polygon,
ut_next:        .skip 8                 #  the next loop round it,
ut_twin:        .skip 8                 #  the loop on the same edge back
ut_luv:         .skip 8                 #  its UV vertex (a root loop)
ut_lst:         .skip 8                 #  stamp, local id (per island)
ut_lid:         .skip 8
ut_puf:         .skip 8                 # per polygon: union-find, island,
ut_pisl:        .skip 8
ut_ptoff:       .skip 8                 #  first triangle (+1 sentinel)
ut_pnrm:        .skip 8                 #  unit normal, area
ut_ioff:        .skip 8                 # per island: its polygons (CSR)
ut_ipoly:       .skip 8
ut_mark:        .skip 8

.text
OPERATOR op_uv_unwrap, "uv.unwrap", "Unwrap", do_unwrap, arg=0, key=KEY_U, flags=OPF_AI_SAFE|OPF_UNDO|OPF_EDIT, doc="UV: unwrap the mesh along its seams (least squares conformal maps), then pack the islands"
OPERATOR op_uv_smart, "uv.smart_project", "Smart UV Project", do_unwrap, arg=1, key=KEY_U|KM_SHIFT, flags=OPF_AI_SAFE|OPF_UNDO|OPF_EDIT, doc="UV: project groups of faces facing alike (within 66 degrees) flat, then pack"
OPERATOR op_uv_pack, "uv.pack", "Pack Islands", do_pack, flags=OPF_AI_SAFE|OPF_UNDO|OPF_EDIT, doc="UV: same texel density, smallest boxes, packed into the unit square"
OPERATOR op_uv_mark, "uv.seam_mark", "Mark Seam", do_seams, arg=0, key=KEY_E|KM_CTRL, flags=OPF_AI_SAFE|OPF_UNDO|OPF_EDIT, doc="UV: the edges between selected vertices become seams"
OPERATOR op_uv_clear, "uv.seam_clear", "Clear Seam", do_seams, arg=1, key=KEY_E|KM_CTRL|KM_SHIFT, flags=OPF_AI_SAFE|OPF_UNDO|OPF_EDIT, doc="UV: the edges between selected vertices are no seams"
OPERATOR op_uv_sharp, "uv.seams_from_sharp", "Seams from Sharp Edges", do_seams, arg=2, flags=OPF_AI_SAFE|OPF_UNDO|OPF_EDIT, doc="UV: every edge sharper than 30 degrees becomes a seam"

# =============================================================================
#  Topology
# =============================================================================
# ut_alloc(esi=bytes) -> rax (frame arena; 0: none)
ut_alloc:
    lea     rdi, [rip+frame_arena]
    add     esi, 16
    jmp     arena_alloc

# uv_topo(rdi=mesh) -> eax = 1: loops' polygon, next, twin; polygons'
#   first triangle and unit normal (Newell) with area. (frame arena: the
#   caller releases it)
uv_topo:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    push    rbp
    sub     rsp, 24
    mov     rbx, rdi
    mov     [rip+ut_m], rdi
    mov     eax, [rbx+ME_NLOOPS]
    mov     [rip+ut_nl], eax
    mov     eax, [rbx+ME_NPOLYS]
    mov     [rip+ut_np], eax
    mov     esi, [rip+ut_nl]            # per-loop arrays
    shl     esi, 2
    call    ut_alloc
    test    rax, rax
    jz      .Lut_fail
    mov     [rip+ut_lpoly], rax
    mov     esi, [rip+ut_nl]
    shl     esi, 2
    call    ut_alloc
    test    rax, rax
    jz      .Lut_fail
    mov     [rip+ut_next], rax
    mov     esi, [rip+ut_nl]
    shl     esi, 2
    call    ut_alloc
    test    rax, rax
    jz      .Lut_fail
    mov     [rip+ut_twin], rax
    mov     esi, [rip+ut_nl]
    shl     esi, 2
    call    ut_alloc
    test    rax, rax
    jz      .Lut_fail
    mov     [rip+ut_luv], rax
    mov     esi, [rip+ut_nl]
    shl     esi, 2
    call    ut_alloc
    test    rax, rax
    jz      .Lut_fail
    mov     [rip+ut_lst], rax
    mov     rdi, rax
    mov     ecx, [rip+ut_nl]
    xor     eax, eax
    rep     stosd
    mov     esi, [rip+ut_nl]
    shl     esi, 2
    call    ut_alloc
    test    rax, rax
    jz      .Lut_fail
    mov     [rip+ut_lid], rax
    mov     dword ptr [rip+ut_serial], 0
    mov     esi, [rip+ut_np]            # per-polygon arrays
    lea     esi, [rsi*4+4]
    call    ut_alloc
    test    rax, rax
    jz      .Lut_fail
    mov     [rip+ut_puf], rax
    mov     esi, [rip+ut_np]
    lea     esi, [rsi*4+4]
    call    ut_alloc
    test    rax, rax
    jz      .Lut_fail
    mov     [rip+ut_pisl], rax
    mov     esi, [rip+ut_np]
    lea     esi, [rsi*4+8]
    call    ut_alloc
    test    rax, rax
    jz      .Lut_fail
    mov     [rip+ut_ptoff], rax
    mov     esi, [rip+ut_np]
    shl     esi, 4
    call    ut_alloc
    test    rax, rax
    jz      .Lut_fail
    mov     [rip+ut_pnrm], rax
    # loops: polygon, next
    xor     r12d, r12d
1:  cmp     r12d, [rip+ut_np]
    jae     3f
    mov     rax, [rbx+ME_POFF]
    mov     ecx, [rax+r12*4]
    mov     edx, [rax+r12*4+4]
2:  cmp     ecx, edx
    jae     21f
    mov     r8, [rip+ut_lpoly]
    mov     [r8+rcx*4], r12d
    lea     r9d, [rcx+1]
    cmp     r9d, edx
    jb      22f
    mov     r9d, [rax+r12*4]
22: mov     r8, [rip+ut_next]
    mov     [r8+rcx*4], r9d
    inc     ecx
    jmp     2b
21: inc     r12d
    jmp     1b
3:  # twins: a hash of directed edges (a b) -> loop
    mov     eax, [rip+ut_nl]
    add     eax, eax
    mov     ecx, 16
31: cmp     ecx, eax
    jae     32f
    add     ecx, ecx
    jmp     31b
32: mov     [rsp], ecx                  # slots
    lea     esi, [rcx*8]
    shl     esi, 1                      # key 8 + loop 8
    call    ut_alloc
    test    rax, rax
    jz      .Lut_fail
    mov     r13, rax
    mov     rdi, rax
    mov     ecx, [rsp]
    add     ecx, ecx
    xor     eax, eax
    rep     stosq
    xor     r12d, r12d
4:  cmp     r12d, [rip+ut_nl]
    jae     5f
    call    ut_edge_key                 # (r12 = loop) -> rax key, rcx slot
41: mov     rdx, rcx
    shl     rdx, 4
    cmp     qword ptr [r13+rdx], 0
    je      42f
    cmp     [r13+rdx], rax
    je      43f                         # (twice the same way: keep one)
    inc     ecx
    mov     edx, [rsp]
    dec     edx
    and     ecx, edx
    jmp     41b
42: mov     [r13+rdx], rax
    mov     [r13+rdx+8], r12d
43: inc     r12d
    jmp     4b
5:  xor     r12d, r12d                  # each loop: the edge back
6:  cmp     r12d, [rip+ut_nl]
    jae     7f
    mov     r8, [rip+ut_twin]
    mov     dword ptr [r8+r12*4], UV_NONE
    mov     r8, [rbx+ME_LOOPS]          # key (b a)
    mov     eax, [r8+r12*4]
    mov     r9, [rip+ut_next]
    mov     ecx, [r9+r12*4]
    mov     ecx, [r8+rcx*4]
    shl     rcx, 32
    or      rax, rcx
    inc     rax
    mov     rcx, rax
    imul    rcx, qword ptr [rip+hash_k]
    shr     rcx, 32
    mov     edx, [rsp]
    dec     edx
    and     ecx, edx
61: mov     rdx, rcx
    shl     rdx, 4
    mov     r10, [r13+rdx]
    test    r10, r10
    jz      63f
    cmp     r10, rax
    je      62f
    inc     ecx
    mov     edx, [rsp]
    dec     edx
    and     ecx, edx
    jmp     61b
62: mov     r10d, [r13+rdx+8]
    mov     r8, [rip+ut_twin]
    mov     [r8+r12*4], r10d
63: inc     r12d
    jmp     6b
7:  # polygons: first triangle (triangles come in polygon order)
    mov     rdi, [rip+ut_ptoff]
    mov     ecx, [rip+ut_np]
    inc     ecx
    xor     eax, eax
    rep     stosd
    mov     r8, [rbx+ME_TPOLY]
    mov     r9, [rip+ut_ptoff]
    xor     ecx, ecx
71: cmp     ecx, [rbx+ME_NTRIS]
    jae     72f
    mov     eax, [r8+rcx*4]
    inc     dword ptr [r9+rax*4+4]
    inc     ecx
    jmp     71b
72: xor     ecx, ecx
    xor     eax, eax
73: cmp     ecx, [rip+ut_np]
    jae     74f
    add     eax, [r9+rcx*4+4]
    mov     [r9+rcx*4+4], eax
    inc     ecx
    jmp     73b
74: # normals (Newell), areas
    xor     r12d, r12d
8:  cmp     r12d, [rip+ut_np]
    jae     .Lut_ok
    mov     rax, [rbx+ME_POFF]
    mov     r14d, [rax+r12*4]
    mov     r15d, [rax+r12*4+4]
    xorps   xmm4, xmm4
    xorps   xmm5, xmm5
    xorps   xmm6, xmm6
    mov     ebp, r14d
81: cmp     ebp, r15d
    jae     82f
    mov     edi, ebp
    call    ut_lpos                     # rax = this corner, rdx = next
    movss   xmm0, [rax+4]               # (y1 - y2)(z1 + z2) ...
    subss   xmm0, [rdx+4]
    movss   xmm1, [rax+8]
    addss   xmm1, [rdx+8]
    mulss   xmm0, xmm1
    addss   xmm4, xmm0
    movss   xmm0, [rax+8]
    subss   xmm0, [rdx+8]
    movss   xmm1, [rax]
    addss   xmm1, [rdx]
    mulss   xmm0, xmm1
    addss   xmm5, xmm0
    movss   xmm0, [rax]
    subss   xmm0, [rdx]
    movss   xmm1, [rax+4]
    addss   xmm1, [rdx+4]
    mulss   xmm0, xmm1
    addss   xmm6, xmm0
    inc     ebp
    jmp     81b
82: movss   xmm0, xmm4
    mulss   xmm0, xmm4
    movss   xmm1, xmm5
    mulss   xmm1, xmm5
    addss   xmm0, xmm1
    movss   xmm1, xmm6
    mulss   xmm1, xmm6
    addss   xmm0, xmm1
    sqrtss  xmm0, xmm0
    mov     rax, r12
    shl     rax, 4
    add     rax, [rip+ut_pnrm]
    movss   xmm1, xmm0
    mulss   xmm1, [rip+uf_half]
    movss   [rax+12], xmm1              # area
    maxss   xmm0, [rip+uf_tiny]
    movss   xmm1, [rip+uf_one]
    divss   xmm1, xmm0
    mulss   xmm4, xmm1
    mulss   xmm5, xmm1
    mulss   xmm6, xmm1
    movss   [rax], xmm4
    movss   [rax+4], xmm5
    movss   [rax+8], xmm6
    inc     r12d
    jmp     8b
.Lut_ok:
    mov     eax, 1
    jmp     9f
.Lut_fail:
    xor     eax, eax
9:  add     rsp, 24
    pop     rbp
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# ut_edge_key(r12d=loop, rbx=mesh; [rsp+8] slots) -> rax = key (a<<32|b)+1,
#   rcx = its first slot
ut_edge_key:
    mov     r8, [rbx+ME_LOOPS]
    mov     eax, [r8+r12*4]
    mov     r9, [rip+ut_next]
    mov     ecx, [r9+r12*4]
    mov     ecx, [r8+rcx*4]
    shl     rax, 32
    or      rax, rcx
    inc     rax
    mov     rcx, rax
    imul    rcx, qword ptr [rip+hash_k]
    shr     rcx, 32
    mov     edx, [rsp+8]
    dec     edx
    and     ecx, edx
    ret

# ut_lpos(edi=loop) -> rax = its vertex's position, rdx = the next loop's
ut_lpos:
    mov     r8, [rip+ut_m]
    mov     r9, [r8+ME_LOOPS]
    mov     r10, [r8+ME_POS]
    mov     eax, [r9+rdi*4]
    lea     rax, [rax+rax*2]
    lea     rax, [r10+rax*4]
    mov     r11, [rip+ut_next]
    mov     edx, [r11+rdi*4]
    mov     edx, [r9+rdx*4]
    lea     rdx, [rdx+rdx*2]
    lea     rdx, [r10+rdx*4]
    ret

# uf_find(rdi=parents, esi=x) -> eax = its root (paths halved)
uf_find:
    mov     eax, esi
1:  mov     ecx, [rdi+rax*4]
    cmp     ecx, eax
    je      2f
    mov     edx, [rdi+rcx*4]            # parent = grandparent
    mov     [rdi+rax*4], edx
    mov     eax, edx
    jmp     1b
2:  ret

# uf_join(rdi=parents, esi=a, edx=b) - the smaller root becomes the root
uf_join:
    push    rdx
    call    uf_find
    mov     r8d, eax
    pop     rsi
    call    uf_find
    cmp     eax, r8d
    je      1f
    jb      2f
    mov     [rdi+rax*4], r8d
    ret
2:  mov     [rdi+r8*4], eax
1:  ret

# ut_seam(edi=loop) -> eax = 1 when its edge is a seam (either side) or
#   has no twin
ut_seam:
    mov     r8, [rip+ut_twin]
    mov     ecx, [r8+rdi*4]
    cmp     ecx, UV_NONE
    je      1f
    mov     r8, [rip+ut_m]
    mov     r8, [r8+ME_SEAM]
    test    r8, r8
    jz      2f
    cmp     byte ptr [r8+rdi], 0
    jne     1f
    cmp     byte ptr [r8+rcx], 0
    jne     1f
2:  xor     eax, eax
    ret
1:  mov     eax, 1
    ret

# ut_islands(edi=0 by seams, 1 by equal UVs) - polygon islands (ut_pisl:
#   0..ut_nisl-1, ut_ioff / ut_ipoly), UV vertices (ut_luv: a root loop)
ut_islands:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    mov     r15d, edi
    mov     rdi, [rip+ut_puf]           # every one its own
    xor     ecx, ecx
1:  cmp     ecx, [rip+ut_np]
    jae     2f
    mov     [rdi+rcx*4], ecx
    inc     ecx
    jmp     1b
2:  mov     rdi, [rip+ut_luv]
    xor     ecx, ecx
3:  cmp     ecx, [rip+ut_nl]
    jae     4f
    mov     [rdi+rcx*4], ecx
    inc     ecx
    jmp     3b
4:  xor     r12d, r12d                  # joined across each edge
5:  cmp     r12d, [rip+ut_nl]
    jae     .Lui_count
    mov     rax, [rip+ut_twin]
    mov     r13d, [rax+r12*4]
    cmp     r13d, UV_NONE
    je      59f
    test    r15d, r15d
    jnz     51f
    mov     edi, r12d
    call    ut_seam
    test    eax, eax
    jnz     59f
    jmp     52f
51: mov     edi, r12d                   # by UVs: the edge's ends match
    mov     esi, r13d
    call    ut_uv_match
    test    eax, eax
    jz      59f
52: mov     rax, [rip+ut_lpoly]
    mov     esi, [rax+r12*4]
    mov     edx, [rax+r13*4]
    mov     rdi, [rip+ut_puf]
    call    uf_join
    mov     rax, [rip+ut_next]          # l with next(t), next(l) with t
    mov     esi, r12d
    mov     edx, [rax+r13*4]
    mov     rdi, [rip+ut_luv]
    call    uf_join
    mov     rax, [rip+ut_next]
    mov     esi, [rax+r12*4]
    mov     edx, r13d
    mov     rdi, [rip+ut_luv]
    call    uf_join
59: inc     r12d
    jmp     5b
.Lui_count:
    mov     rdi, [rip+ut_luv]           # roots, flat
    xor     r12d, r12d
6:  cmp     r12d, [rip+ut_nl]
    jae     61f
    mov     esi, r12d
    call    uf_find
    mov     [rdi+r12*4], eax
    inc     r12d
    jmp     6b
61: mov     rdi, [rip+ut_pisl]          # island numbers (-1 first)
    mov     ecx, [rip+ut_np]
    mov     eax, -1
    rep     stosd
    xor     r13d, r13d
    xor     r12d, r12d
62: cmp     r12d, [rip+ut_np]
    jae     64f
    mov     rdi, [rip+ut_puf]
    mov     esi, r12d
    call    uf_find
    mov     rdx, [rip+ut_pisl]
    mov     ecx, [rdx+rax*4]
    cmp     ecx, -1
    jne     63f
    mov     ecx, r13d
    mov     [rdx+rax*4], ecx
    inc     r13d
63: mov     [rdx+r12*4], ecx            # (root first: its number is set)
    inc     r12d
    jmp     62b
64: mov     [rip+ut_nisl], r13d
    mov     esi, r13d                   # CSR
    lea     esi, [rsi*4+8]
    call    ut_alloc
    test    rax, rax
    jz      9f
    mov     [rip+ut_ioff], rax
    mov     rdi, rax
    lea     ecx, [r13+2]
    xor     eax, eax
    rep     stosd
    mov     esi, [rip+ut_np]
    lea     esi, [rsi*4+4]
    call    ut_alloc
    test    rax, rax
    jz      9f
    mov     [rip+ut_ipoly], rax
    mov     r8, [rip+ut_ioff]
    mov     r9, [rip+ut_pisl]
    xor     ecx, ecx
65: cmp     ecx, [rip+ut_np]
    jae     66f
    mov     eax, [r9+rcx*4]
    inc     dword ptr [r8+rax*4+8]
    inc     ecx
    jmp     65b
66: xor     ecx, ecx
    xor     eax, eax
67: cmp     ecx, r13d
    jae     68f
    add     eax, [r8+rcx*4+8]
    mov     [r8+rcx*4+8], eax
    inc     ecx
    jmp     67b
68: xor     ecx, ecx
69: cmp     ecx, [rip+ut_np]
    jae     9f
    mov     eax, [r9+rcx*4]
    mov     edx, [r8+rax*4+4]
    inc     dword ptr [r8+rax*4+4]
    mov     r10, [rip+ut_ipoly]
    mov     [r10+rdx*4], ecx
    inc     ecx
    jmp     69b
9:  pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# ut_uv_match(edi=loop l, esi=its twin t) -> eax = 1 when the edge has the
#   same UVs on both sides (l = next(t), next(l) = t, bit for bit)
ut_uv_match:
    mov     r8, [rip+ut_m]
    mov     r8, [r8+ME_UV]
    test    r8, r8
    jz      8f
    mov     r9, [rip+ut_next]
    mov     ecx, [r9+rsi*4]             # next(t)
    mov     rax, [r8+rdi*8]
    cmp     rax, [r8+rcx*8]
    jne     8f
    mov     ecx, [r9+rdi*4]             # next(l)
    mov     rax, [r8+rcx*8]
    cmp     rax, [r8+rsi*8]
    jne     8f
    mov     eax, 1
    ret
8:  xor     eax, eax
    ret

# =============================================================================
#  LSCM
# =============================================================================
# per island (frame arena, released after each): triangles: 3 local ids
#   (u32) + pad, then W real / imaginary per corner (double) = 64 bytes
.equ LT_ID,     0
.equ LT_W,      16                      # wr0 wi0 wr1 wi1 wr2 wi2
.equ LT_SZ,     64

.section .bss
.align 8
ls_tri:         .skip 8
ls_nt:          .skip 4
ls_nv:          .skip 4
ls_x:           .skip 8                 # u v per local vertex (double)
ls_r:           .skip 8
ls_p:           .skip 8
ls_q:           .skip 8
ls_z:           .skip 8
ls_d:           .skip 8                 # the preconditioner (1 / diagonal)
ls_pin:         .skip 8                 # u8: pinned
ls_pos:         .skip 8                 # per local vertex: a loop
ls_axis:        .skip 36                # projection: normal, u, v axes
ls_iters:       .skip 4
ls_p0:          .skip 4                 # the island's polygons (in ut_ipoly)
ls_p1:          .skip 4
.text

# ut_corner(edi=polygon, esi=vertex) -> eax = its loop there (first match)
ut_corner:
    mov     r8, [rip+ut_m]
    mov     r9, [r8+ME_POFF]
    mov     r10, [r8+ME_LOOPS]
    mov     eax, [r9+rdi*4]
    mov     ecx, [r9+rdi*4+4]
1:  cmp     eax, ecx
    jae     2f
    cmp     [r10+rax*4], esi
    je      3f
    inc     eax
    jmp     1b
2:  mov     eax, [r9+rdi*4]
3:  ret

# lscm_island(edi=island) -> eax = 1 (0: no memory): its loops' UVs
lscm_island:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    push    rbp
    sub     rsp, 104
    mov     [rsp], edi
    inc     dword ptr [rip+ut_serial]
    mov     r15d, [rip+ut_serial]
    mov     rax, [rip+ut_ioff]          # its polygons, triangles
    mov     ecx, [rax+rdi*4]
    mov     edx, [rax+rdi*4+4]
    mov     [rsp+8], ecx
    mov     [rsp+12], edx
    mov     [rip+ls_p0], ecx
    mov     [rip+ls_p1], edx
    xor     r12d, r12d                  # triangles
    xor     r13d, r13d                  # local vertices
    mov     ebx, ecx
1:  cmp     ebx, [rsp+12]
    jae     2f
    mov     rax, [rip+ut_ipoly]
    mov     eax, [rax+rbx*4]
    mov     rdx, [rip+ut_ptoff]
    mov     ecx, [rdx+rax*4+4]
    sub     ecx, [rdx+rax*4]
    add     r12d, ecx
    mov     r8, [rip+ut_m]              # its loops' UV vertices, numbered
    mov     r9, [r8+ME_POFF]
    mov     ecx, [r9+rax*4]
    mov     edx, [r9+rax*4+4]
11: cmp     ecx, edx
    jae     12f
    mov     r10, [rip+ut_luv]
    mov     eax, [r10+rcx*4]
    mov     r10, [rip+ut_lst]
    cmp     [r10+rax*4], r15d
    je      13f
    mov     [r10+rax*4], r15d
    mov     r10, [rip+ut_lid]
    mov     [r10+rax*4], r13d
    inc     r13d
13: inc     ecx
    jmp     11b
12: inc     ebx
    jmp     1b
2:  mov     [rip+ls_nt], r12d
    mov     [rip+ls_nv], r13d
    call    fa_mark
    mov     [rsp+16], rax
    mov     esi, r12d                   # arrays
    shl     esi, 6
    call    ut_alloc
    test    rax, rax
    jz      .Lli_fail
    mov     [rip+ls_tri], rax
    lea     rbx, [rip+ls_x]             # x r p q z d: 2 doubles a vertex
    mov     ebp, 6
3:  mov     esi, r13d
    shl     esi, 4
    call    ut_alloc
    test    rax, rax
    jz      .Lli_fail
    mov     [rbx], rax
    mov     rdi, rax
    mov     ecx, r13d
    add     ecx, ecx
    xor     eax, eax
    rep     stosq
    add     rbx, 8
    dec     ebp
    jnz     3b
    mov     esi, r13d
    call    ut_alloc
    test    rax, rax
    jz      .Lli_fail
    mov     [rip+ls_pin], rax
    mov     rdi, rax
    mov     ecx, r13d
    xor     eax, eax
    rep     stosb
    mov     esi, r13d
    shl     esi, 2
    call    ut_alloc
    test    rax, rax
    jz      .Lli_fail
    mov     [rip+ls_pos], rax
    # each local vertex: a loop (for its position)
    mov     ebx, [rsp+8]
4:  cmp     ebx, [rsp+12]
    jae     5f
    mov     rax, [rip+ut_ipoly]
    mov     eax, [rax+rbx*4]
    mov     r8, [rip+ut_m]
    mov     r9, [r8+ME_POFF]
    mov     ecx, [r9+rax*4]
    mov     edx, [r9+rax*4+4]
41: cmp     ecx, edx
    jae     42f
    mov     r10, [rip+ut_luv]
    mov     eax, [r10+rcx*4]
    mov     r10, [rip+ut_lid]
    mov     eax, [r10+rax*4]
    mov     r10, [rip+ls_pos]
    mov     [r10+rax*4], ecx
    inc     ecx
    jmp     41b
42: inc     ebx
    jmp     4b
5:  call    ls_frame                    # the island's plane: start, pins
    call    ls_project
    call    ls_triangles
    cmp     dword ptr [rip+ls_nv], 3
    jb      7f
    call    ls_solve
7:  # the loops take their vertex's UV
    mov     ebx, [rsp+8]
71: cmp     ebx, [rsp+12]
    jae     8f
    mov     rax, [rip+ut_ipoly]
    mov     eax, [rax+rbx*4]
    mov     r8, [rip+ut_m]
    mov     r9, [r8+ME_POFF]
    mov     r11, [r8+ME_UV]
    mov     ecx, [r9+rax*4]
    mov     edx, [r9+rax*4+4]
72: cmp     ecx, edx
    jae     73f
    mov     r10, [rip+ut_luv]
    mov     eax, [r10+rcx*4]
    mov     r10, [rip+ut_lid]
    mov     eax, [r10+rax*4]
    shl     rax, 4
    add     rax, [rip+ls_x]
    cvtsd2ss xmm0, [rax]
    cvtsd2ss xmm1, [rax+8]
    movss   [r11+rcx*8], xmm0
    movss   [r11+rcx*8+4], xmm1
    inc     ecx
    jmp     72b
73: inc     ebx
    jmp     71b
8:  mov     rdi, [rsp+16]
    call    fa_release
    mov     eax, 1
    jmp     9f
.Lli_fail:
    mov     rdi, [rsp+16]
    call    fa_release
    xor     eax, eax
9:  add     rsp, 104
    pop     rbp
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# ls_vpos(edi=local vertex) -> rax = its position
ls_vpos:
    mov     rax, [rip+ls_pos]
    mov     eax, [rax+rdi*4]
    mov     r8, [rip+ut_m]
    mov     r9, [r8+ME_LOOPS]
    mov     eax, [r9+rax*4]
    lea     rax, [rax+rax*2]
    shl     rax, 2
    add     rax, [r8+ME_POS]
    ret

# ls_frame - the island's average normal (area weighted) and two axes
#   across it (ls_axis: n, u, v as floats)
ls_frame:
    push    rbx
    xorps   xmm4, xmm4
    xorps   xmm5, xmm5
    xorps   xmm6, xmm6
    mov     ecx, [rip+ls_p0]
    jmp     2f
1:  mov     rax, [rip+ut_ipoly]
    mov     eax, [rax+rcx*4]
    shl     rax, 4
    add     rax, [rip+ut_pnrm]
    movss   xmm0, [rax]
    mulss   xmm0, [rax+12]
    addss   xmm4, xmm0
    movss   xmm0, [rax+4]
    mulss   xmm0, [rax+12]
    addss   xmm5, xmm0
    movss   xmm0, [rax+8]
    mulss   xmm0, [rax+12]
    addss   xmm6, xmm0
    inc     ecx
2:  cmp     ecx, [rip+ls_p1]
    jb      1b
    lea     rdi, [rip+ls_axis]
    call    axes_from
    pop     rbx
    ret

# axes_from(xmm4..6 = a normal (any length), rdi = out n, u, v floats) -
#   u: the normal crossed with the world axis it is least along; v = n x u
axes_from:
    movss   xmm0, xmm4
    mulss   xmm0, xmm4
    movss   xmm1, xmm5
    mulss   xmm1, xmm5
    addss   xmm0, xmm1
    movss   xmm1, xmm6
    mulss   xmm1, xmm6
    addss   xmm0, xmm1
    sqrtss  xmm0, xmm0
    comiss  xmm0, [rip+uf_tiny]
    ja      1f
    movss   xmm6, [rip+uf_one]          # (no normal: z)
    xorps   xmm4, xmm4
    xorps   xmm5, xmm5
    movss   xmm0, [rip+uf_one]
1:  movss   xmm1, [rip+uf_one]
    divss   xmm1, xmm0
    mulss   xmm4, xmm1
    mulss   xmm5, xmm1
    mulss   xmm6, xmm1
    movss   [rdi], xmm4
    movss   [rdi+4], xmm5
    movss   [rdi+8], xmm6
    movss   xmm0, xmm4                  # |n|: the smallest component's axis
    andps   xmm0, [rip+uf_absmask]
    movss   xmm1, xmm5
    andps   xmm1, [rip+uf_absmask]
    movss   xmm2, xmm6
    andps   xmm2, [rip+uf_absmask]
    # a = axis: u = a x n
    xorps   xmm7, xmm7                  # (ax ay az) in xmm8..10
    movss   xmm8, xmm7
    movss   xmm9, xmm7
    movss   xmm10, xmm7
    comiss  xmm0, xmm1
    ja      2f
    comiss  xmm0, xmm2
    ja      3f
    movss   xmm8, [rip+uf_one]          # x smallest
    jmp     4f
2:  comiss  xmm1, xmm2
    ja      3f
    movss   xmm9, [rip+uf_one]          # y smallest
    jmp     4f
3:  movss   xmm10, [rip+uf_one]         # z smallest
4:  movss   xmm0, xmm9                  # u = a x n
    mulss   xmm0, xmm6
    movss   xmm1, xmm10
    mulss   xmm1, xmm5
    subss   xmm0, xmm1
    movss   xmm1, xmm10
    mulss   xmm1, xmm4
    movss   xmm2, xmm8
    mulss   xmm2, xmm6
    subss   xmm1, xmm2
    movss   xmm2, xmm8
    mulss   xmm2, xmm5
    movss   xmm3, xmm9
    mulss   xmm3, xmm4
    subss   xmm2, xmm3
    movss   xmm3, xmm0                  # unit
    mulss   xmm3, xmm0
    movss   xmm7, xmm1
    mulss   xmm7, xmm1
    addss   xmm3, xmm7
    movss   xmm7, xmm2
    mulss   xmm7, xmm2
    addss   xmm3, xmm7
    sqrtss  xmm3, xmm3
    maxss   xmm3, [rip+uf_tiny]
    movss   xmm7, [rip+uf_one]
    divss   xmm7, xmm3
    mulss   xmm0, xmm7
    mulss   xmm1, xmm7
    mulss   xmm2, xmm7
    movss   [rdi+12], xmm0
    movss   [rdi+16], xmm1
    movss   [rdi+20], xmm2
    movss   xmm3, xmm5                  # v = n x u
    mulss   xmm3, xmm2
    movss   xmm7, xmm6
    mulss   xmm7, xmm1
    subss   xmm3, xmm7
    movss   [rdi+24], xmm3
    movss   xmm3, xmm6
    mulss   xmm3, xmm0
    movss   xmm7, xmm4
    mulss   xmm7, xmm2
    subss   xmm3, xmm7
    movss   [rdi+28], xmm3
    movss   xmm3, xmm4
    mulss   xmm3, xmm1
    movss   xmm7, xmm5
    mulss   xmm7, xmm0
    subss   xmm3, xmm7
    movss   [rdi+32], xmm3
    ret

# ls_project - x: every local vertex projected on the island's plane; the
#   two extremes along u are pinned
ls_project:
    push    rbx
    push    r12
    push    r13
    sub     rsp, 16
    mov     dword ptr [rsp], 0          # min / max u vertex
    mov     dword ptr [rsp+4], 0
    xor     ebx, ebx
1:  cmp     ebx, [rip+ls_nv]
    jae     3f
    mov     edi, ebx
    call    ls_vpos
    lea     rdx, [rip+ls_axis]
    movss   xmm0, [rax]
    mulss   xmm0, [rdx+12]
    movss   xmm1, [rax+4]
    mulss   xmm1, [rdx+16]
    addss   xmm0, xmm1
    movss   xmm1, [rax+8]
    mulss   xmm1, [rdx+20]
    addss   xmm0, xmm1
    movss   xmm2, [rax]
    mulss   xmm2, [rdx+24]
    movss   xmm1, [rax+4]
    mulss   xmm1, [rdx+28]
    addss   xmm2, xmm1
    movss   xmm1, [rax+8]
    mulss   xmm1, [rdx+32]
    addss   xmm2, xmm1
    mov     rcx, rbx
    shl     rcx, 4
    add     rcx, [rip+ls_x]
    cvtss2sd xmm1, xmm0
    movsd   [rcx], xmm1
    cvtss2sd xmm1, xmm2
    movsd   [rcx+8], xmm1
    mov     eax, [rsp]                  # extremes
    shl     rax, 4
    add     rax, [rip+ls_x]
    movsd   xmm1, [rcx]
    comisd  xmm1, [rax]
    jae     2f
    mov     [rsp], ebx
2:  mov     eax, [rsp+4]
    shl     rax, 4
    add     rax, [rip+ls_x]
    comisd  xmm1, [rax]
    jbe     21f
    mov     [rsp+4], ebx
21: inc     ebx
    jmp     1b
3:  mov     rax, [rip+ls_pin]
    mov     ecx, [rsp]
    mov     byte ptr [rax+rcx], 1
    mov     ecx, [rsp+4]
    mov     byte ptr [rax+rcx], 1
    add     rsp, 16
    pop     r13
    pop     r12
    pop     rbx
    ret

# ls_triangles - each triangle of the island in its own plane: local ids,
#   W_j / sqrt(2A) (W0 = z2 - z1, W1 = z0 - z2, W2 = z1 - z0)
ls_triangles:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    push    rbp
    sub     rsp, 88
    xor     r14d, r14d                  # triangle out
    mov     ebx, [rip+ls_p0]
2:  cmp     ebx, [rip+ls_p1]
    jae     9f
    mov     rax, [rip+ut_ipoly]
    mov     r12d, [rax+rbx*4]           # polygon
    mov     rax, [rip+ut_ptoff]
    mov     r13d, [rax+r12*4]
    mov     eax, [rax+r12*4+4]
    mov     [rsp+80], eax
3:  cmp     r13d, [rsp+80]
    jae     8f
    mov     r15, r14
    shl     r15, 6
    add     r15, [rip+ls_tri]
    xor     ebp, ebp                    # corners: local id, position
4:  mov     r8, [rip+ut_m]
    mov     r9, [r8+ME_TRIS]
    lea     eax, [r13+r13*2]
    add     eax, ebp
    mov     esi, [r9+rax*4]             # vertex
    mov     edi, r12d
    call    ut_corner
    mov     rcx, [rip+ut_luv]
    mov     eax, [rcx+rax*4]
    mov     rcx, [rip+ut_lid]
    mov     eax, [rcx+rax*4]
    mov     [r15+LT_ID+rbp*4], eax
    mov     edi, eax
    call    ls_vpos
    imul    ecx, ebp, 12
    mov     rdx, [rax]
    mov     [rsp+rcx], rdx
    mov     edx, [rax+8]
    mov     [rsp+rcx+8], edx
    inc     ebp
    cmp     ebp, 3
    jb      4b
    # frame: x = e1 / |e1|, y = n x x; z0 = 0, z1 = (|e1|, 0), z2 = ...
    movss   xmm0, [rsp+12]              # e1
    subss   xmm0, [rsp]
    movss   xmm1, [rsp+16]
    subss   xmm1, [rsp+4]
    movss   xmm2, [rsp+20]
    subss   xmm2, [rsp+8]
    movss   xmm3, [rsp+24]              # e2
    subss   xmm3, [rsp]
    movss   xmm4, [rsp+28]
    subss   xmm4, [rsp+4]
    movss   xmm5, [rsp+32]
    subss   xmm5, [rsp+8]
    cvtss2sd xmm0, xmm0
    cvtss2sd xmm1, xmm1
    cvtss2sd xmm2, xmm2
    cvtss2sd xmm3, xmm3
    cvtss2sd xmm4, xmm4
    cvtss2sd xmm5, xmm5
    movsd   xmm6, xmm0                  # |e1|
    mulsd   xmm6, xmm0
    movsd   xmm7, xmm1
    mulsd   xmm7, xmm1
    addsd   xmm6, xmm7
    movsd   xmm7, xmm2
    mulsd   xmm7, xmm2
    addsd   xmm6, xmm7
    sqrtsd  xmm6, xmm6
    movsd   [rsp+40], xmm6              # x1
    maxsd   xmm6, [rip+ud_tiny]
    movsd   xmm7, xmm0                  # x2 = e2 . e1 / |e1|
    mulsd   xmm7, xmm3
    movsd   xmm8, xmm1
    mulsd   xmm8, xmm4
    addsd   xmm7, xmm8
    movsd   xmm8, xmm2
    mulsd   xmm8, xmm5
    addsd   xmm7, xmm8
    divsd   xmm7, xmm6
    movsd   [rsp+48], xmm7
    movsd   xmm8, xmm1                  # y2 = |e1 x e2| / |e1| (= 2A / x1)
    mulsd   xmm8, xmm5
    movsd   xmm9, xmm2
    mulsd   xmm9, xmm4
    subsd   xmm8, xmm9
    mulsd   xmm8, xmm8
    movsd   xmm9, xmm2
    mulsd   xmm9, xmm3
    movsd   xmm10, xmm0
    mulsd   xmm10, xmm5
    subsd   xmm9, xmm10
    mulsd   xmm9, xmm9
    addsd   xmm8, xmm9
    movsd   xmm9, xmm0
    mulsd   xmm9, xmm4
    movsd   xmm10, xmm1
    mulsd   xmm10, xmm3
    subsd   xmm9, xmm10
    mulsd   xmm9, xmm9
    addsd   xmm8, xmm9
    sqrtsd  xmm8, xmm8                  # 2A
    movsd   xmm9, xmm8
    divsd   xmm9, xmm6
    movsd   [rsp+56], xmm9              # y2
    comisd  xmm8, [rip+ud_tiny]         # (degenerate: no rows)
    jbe     7f
    sqrtsd  xmm8, xmm8                  # 1 / sqrt(2A)
    movsd   xmm10, [rip+ud_one]
    divsd   xmm10, xmm8
    # W0 = z2 - z1 = (x2 - x1, y2), W1 = z0 - z2 = (-x2, -y2),
    # W2 = z1 - z0 = (x1, 0)
    movsd   xmm0, [rsp+48]
    subsd   xmm0, [rsp+40]
    mulsd   xmm0, xmm10
    movsd   [r15+LT_W], xmm0
    movsd   xmm0, [rsp+56]
    mulsd   xmm0, xmm10
    movsd   [r15+LT_W+8], xmm0
    xorpd   xmm0, xmm0
    subsd   xmm0, [rsp+48]
    mulsd   xmm0, xmm10
    movsd   [r15+LT_W+16], xmm0
    xorpd   xmm0, xmm0
    subsd   xmm0, [rsp+56]
    mulsd   xmm0, xmm10
    movsd   [r15+LT_W+24], xmm0
    movsd   xmm0, [rsp+40]
    mulsd   xmm0, xmm10
    movsd   [r15+LT_W+32], xmm0
    xorpd   xmm0, xmm0
    movsd   [r15+LT_W+40], xmm0
    inc     r14d
7:  inc     r13d
    jmp     3b
8:  inc     ebx
    jmp     2b
9:  mov     [rip+ls_nt], r14d
    add     rsp, 88
    pop     rbp
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# ls_apply(rdi=in, rsi=out, edx=1: pinned inputs count, 0: they are 0) -
#   out = A^T A in (two doubles a vertex); pinned outputs are 0
ls_apply:
    push    rbx
    push    r12
    push    r13
    push    r14
    sub     rsp, 8
    mov     r12, rdi
    mov     r13, rsi
    mov     r14d, edx
    mov     rdi, rsi
    mov     ecx, [rip+ls_nv]
    add     ecx, ecx
    xor     eax, eax
    rep     stosq
    mov     rbx, [rip+ls_tri]
    mov     ecx, [rip+ls_nt]
1:  test    ecx, ecx
    jz      5f
    xorpd   xmm0, xmm0                  # re = sum wr u - wi v
    xorpd   xmm1, xmm1                  # im = sum wi u + wr v
    xor     edx, edx
2:  mov     eax, [rbx+LT_ID+rdx*4]
    test    r14d, r14d
    jnz     21f
    mov     r8, [rip+ls_pin]
    cmp     byte ptr [r8+rax], 0
    jne     3f
21: shl     rax, 4
    movsd   xmm2, [r12+rax]             # u
    movsd   xmm3, [r12+rax+8]           # v
    imul    r9d, edx, 16
    movsd   xmm4, [rbx+LT_W+r9]         # wr
    movsd   xmm5, [rbx+LT_W+r9+8]       # wi
    movsd   xmm6, xmm4
    mulsd   xmm6, xmm2
    addsd   xmm0, xmm6
    movsd   xmm6, xmm5
    mulsd   xmm6, xmm3
    subsd   xmm0, xmm6
    movsd   xmm6, xmm5
    mulsd   xmm6, xmm2
    addsd   xmm1, xmm6
    movsd   xmm6, xmm4
    mulsd   xmm6, xmm3
    addsd   xmm1, xmm6
3:  inc     edx
    cmp     edx, 3
    jb      2b
    xor     edx, edx                    # out_u += wr re + wi im,
4:  mov     eax, [rbx+LT_ID+rdx*4]      # out_v += wr im - wi re
    mov     r8, [rip+ls_pin]
    cmp     byte ptr [r8+rax], 0
    jne     41f
    shl     rax, 4
    imul    r9d, edx, 16
    movsd   xmm4, [rbx+LT_W+r9]
    movsd   xmm5, [rbx+LT_W+r9+8]
    movsd   xmm6, xmm4
    mulsd   xmm6, xmm0
    movsd   xmm7, xmm5
    mulsd   xmm7, xmm1
    addsd   xmm6, xmm7
    addsd   xmm6, [r13+rax]
    movsd   [r13+rax], xmm6
    movsd   xmm6, xmm4
    mulsd   xmm6, xmm1
    movsd   xmm7, xmm5
    mulsd   xmm7, xmm0
    subsd   xmm6, xmm7
    addsd   xmm6, [r13+rax+8]
    movsd   [r13+rax+8], xmm6
41: inc     edx
    cmp     edx, 3
    jb      4b
    add     rbx, LT_SZ
    dec     ecx
    jmp     1b
5:  add     rsp, 8
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# ls_dot(rdi, rsi) -> xmm0 = their dot product (free entries)
ls_dot:
    xorpd   xmm0, xmm0
    mov     ecx, [rip+ls_nv]
    add     ecx, ecx
1:  test    ecx, ecx
    jz      2f
    dec     ecx
    movsd   xmm1, [rdi+rcx*8]
    mulsd   xmm1, [rsi+rcx*8]
    addsd   xmm0, xmm1
    jmp     1b
2:  ret

# ls_solve - conjugate gradients on A^T A x = -A^T A x_pinned (Jacobi)
ls_solve:
    push    rbx
    push    r12
    push    r13
    sub     rsp, 48
    # the diagonal: sum over a vertex's rows of wr^2 + wi^2
    mov     rbx, [rip+ls_tri]
    mov     ecx, [rip+ls_nt]
1:  test    ecx, ecx
    jz      3f
    xor     edx, edx
2:  mov     eax, [rbx+LT_ID+rdx*4]
    shl     rax, 4
    add     rax, [rip+ls_d]
    imul    r9d, edx, 16
    movsd   xmm0, [rbx+LT_W+r9]
    mulsd   xmm0, xmm0
    movsd   xmm1, [rbx+LT_W+r9+8]
    mulsd   xmm1, xmm1
    addsd   xmm0, xmm1
    addsd   xmm0, [rax]
    movsd   [rax], xmm0
    movsd   [rax+8], xmm0
    inc     edx
    cmp     edx, 3
    jb      2b
    add     rbx, LT_SZ
    dec     ecx
    jmp     1b
3:  mov     rax, [rip+ls_d]             # inverted; pinned: 0
    xor     ecx, ecx
31: cmp     ecx, [rip+ls_nv]
    jae     32f
    mov     rdx, [rip+ls_pin]
    xorpd   xmm1, xmm1
    cmp     byte ptr [rdx+rcx], 0
    jne     311f
    movsd   xmm0, [rax]
    maxsd   xmm0, [rip+ud_tiny]
    movsd   xmm1, [rip+ud_one]
    divsd   xmm1, xmm0
311:movsd   [rax], xmm1
    movsd   [rax+8], xmm1
    add     rax, 16
    inc     ecx
    jmp     31b
32: # r = -A^T A x (x: the projection, pins included): ls_apply treats
    #   pinned inputs as 0, so take the full product here
    mov     rdi, [rip+ls_x]
    mov     rsi, [rip+ls_r]
    mov     edx, 1
    call    ls_apply
    mov     rax, [rip+ls_r]             # r = -r
    mov     ecx, [rip+ls_nv]
    add     ecx, ecx
4:  test    ecx, ecx
    jz      41f
    dec     ecx
    xorpd   xmm0, xmm0
    subsd   xmm0, [rax+rcx*8]
    movsd   [rax+rcx*8], xmm0
    jmp     4b
41: call    ls_precond                  # z = D r, p = z
    mov     rdi, [rip+ls_p]
    mov     rsi, [rip+ls_z]
    mov     ecx, [rip+ls_nv]
    add     ecx, ecx
    rep     movsq
    mov     rdi, [rip+ls_r]
    mov     rsi, [rip+ls_z]
    call    ls_dot
    movsd   [rsp], xmm0                 # rz
    mov     rdi, [rip+ls_r]
    mov     rsi, rdi
    call    ls_dot
    mulsd   xmm0, [rip+ud_tol2]
    movsd   [rsp+8], xmm0               # stop when r.r under this
    mov     dword ptr [rip+ls_iters], 0
    mov     r12d, [rip+ls_nv]           # at most 4 n + 200 iterations
    lea     r12d, [r12*4+200]
5:  dec     r12d
    js      9f
    inc     dword ptr [rip+ls_iters]
    mov     rdi, [rip+ls_p]             # q = A^T A p
    mov     rsi, [rip+ls_q]
    xor     edx, edx
    call    ls_apply
    mov     rdi, [rip+ls_p]
    mov     rsi, [rip+ls_q]
    call    ls_dot
    comisd  xmm0, [rip+ud_tiny]
    jbe     9f
    movsd   xmm1, [rsp]                 # alpha = rz / p.q
    divsd   xmm1, xmm0
    mov     rax, [rip+ls_x]
    mov     rdx, [rip+ls_p]
    mov     r8, [rip+ls_r]
    mov     r9, [rip+ls_q]
    mov     ecx, [rip+ls_nv]
    add     ecx, ecx
6:  test    ecx, ecx
    jz      61f
    dec     ecx
    movsd   xmm2, [rdx+rcx*8]           # x += alpha p (pinned p: 0)
    mulsd   xmm2, xmm1
    addsd   xmm2, [rax+rcx*8]
    movsd   [rax+rcx*8], xmm2
    movsd   xmm2, [r9+rcx*8]            # r -= alpha q
    mulsd   xmm2, xmm1
    movsd   xmm3, [r8+rcx*8]
    subsd   xmm3, xmm2
    movsd   [r8+rcx*8], xmm3
    jmp     6b
61: mov     rdi, [rip+ls_r]
    mov     rsi, rdi
    call    ls_dot
    comisd  xmm0, [rsp+8]
    jbe     9f
    call    ls_precond
    mov     rdi, [rip+ls_r]
    mov     rsi, [rip+ls_z]
    call    ls_dot
    movsd   xmm1, xmm0                  # beta = rz' / rz
    divsd   xmm1, [rsp]
    movsd   [rsp], xmm0
    mov     rax, [rip+ls_p]             # p = z + beta p
    mov     rdx, [rip+ls_z]
    mov     ecx, [rip+ls_nv]
    add     ecx, ecx
7:  test    ecx, ecx
    jz      5b
    dec     ecx
    movsd   xmm2, [rax+rcx*8]
    mulsd   xmm2, xmm1
    addsd   xmm2, [rdx+rcx*8]
    movsd   [rax+rcx*8], xmm2
    jmp     7b
9:  add     rsp, 48
    pop     r13
    pop     r12
    pop     rbx
    ret

# ls_precond - z = D r (pinned: 0)
ls_precond:
    mov     rax, [rip+ls_z]
    mov     rdx, [rip+ls_r]
    mov     r8, [rip+ls_d]
    mov     ecx, [rip+ls_nv]
    add     ecx, ecx
1:  test    ecx, ecx
    jz      2f
    dec     ecx
    movsd   xmm0, [rdx+rcx*8]
    mulsd   xmm0, [r8+rcx*8]
    movsd   [rax+rcx*8], xmm0
    jmp     1b
2:  ret


# ut_csr - per island its polygons (ut_ioff / ut_ipoly) from ut_pisl and
#   ut_nisl
ut_csr:
    push    rbx
    mov     ebx, [rip+ut_nisl]
    lea     esi, [rbx*4+8]
    call    ut_alloc
    test    rax, rax
    jz      9f
    mov     [rip+ut_ioff], rax
    mov     rdi, rax
    lea     ecx, [rbx+2]
    xor     eax, eax
    rep     stosd
    mov     esi, [rip+ut_np]
    lea     esi, [rsi*4+4]
    call    ut_alloc
    test    rax, rax
    jz      9f
    mov     [rip+ut_ipoly], rax
    mov     r8, [rip+ut_ioff]
    mov     r9, [rip+ut_pisl]
    xor     ecx, ecx
1:  cmp     ecx, [rip+ut_np]
    jae     2f
    mov     eax, [r9+rcx*4]
    inc     dword ptr [r8+rax*4+8]
    inc     ecx
    jmp     1b
2:  xor     ecx, ecx
    xor     eax, eax
3:  cmp     ecx, ebx
    jae     4f
    add     eax, [r8+rcx*4+8]
    mov     [r8+rcx*4+8], eax
    inc     ecx
    jmp     3b
4:  xor     ecx, ecx
5:  cmp     ecx, [rip+ut_np]
    jae     9f
    mov     eax, [r9+rcx*4]
    mov     edx, [r8+rax*4+4]
    inc     dword ptr [r8+rax*4+4]
    mov     r10, [rip+ut_ipoly]
    mov     [r10+rdx*4], ecx
    inc     ecx
    jmp     5b
9:  pop     rbx
    ret

# =============================================================================
#  Smart projection
# =============================================================================
# smart_islands -> eax = 1: polygons grouped by facing (a seed's normal,
#   neighbours within 66 degrees of it, flood fill), each group projected
#   flat on its seed's plane
smart_islands:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    push    rbp
    sub     rsp, 56
    mov     esi, [rip+ut_np]            # queue
    shl     esi, 2
    call    ut_alloc
    test    rax, rax
    jz      .Lsm_fail
    mov     r15, rax
    mov     rdi, [rip+ut_pisl]
    mov     ecx, [rip+ut_np]
    mov     eax, -1
    rep     stosd
    xor     ebp, ebp                    # islands
    xor     ebx, ebx                    # seed candidate
1:  cmp     ebx, [rip+ut_np]
    jae     .Lsm_csr
    mov     rax, [rip+ut_pisl]
    cmp     dword ptr [rax+rbx*4], -1
    jne     8f
    mov     [rax+rbx*4], ebp
    mov     rax, rbx                    # the seed's normal
    shl     rax, 4
    add     rax, [rip+ut_pnrm]
    movss   xmm0, [rax]
    movss   [rsp], xmm0
    movss   xmm0, [rax+4]
    movss   [rsp+4], xmm0
    movss   xmm0, [rax+8]
    movss   [rsp+8], xmm0
    mov     [r15], ebx
    xor     r12d, r12d                  # head
    mov     r13d, 1                     # tail
2:  cmp     r12d, r13d
    jae     7f
    mov     r14d, [r15+r12*4]
    inc     r12d
    mov     rax, [rip+ut_m]
    mov     rax, [rax+ME_POFF]
    mov     ecx, [rax+r14*4]
    mov     edx, [rax+r14*4+4]
3:  cmp     ecx, edx
    jae     2b
    mov     rax, [rip+ut_twin]
    mov     eax, [rax+rcx*4]
    cmp     eax, UV_NONE
    je      6f
    mov     r8, [rip+ut_lpoly]
    mov     eax, [r8+rax*4]             # the neighbour
    mov     r8, [rip+ut_pisl]
    cmp     dword ptr [r8+rax*4], -1
    jne     6f
    mov     r9, rax
    shl     r9, 4
    add     r9, [rip+ut_pnrm]
    movss   xmm0, [r9]
    mulss   xmm0, [rsp]
    movss   xmm1, [r9+4]
    mulss   xmm1, [rsp+4]
    addss   xmm0, xmm1
    movss   xmm1, [r9+8]
    mulss   xmm1, [rsp+8]
    addss   xmm0, xmm1
    comiss  xmm0, [rip+uf_cos66]
    jbe     6f
    mov     [r8+rax*4], ebp
    mov     [r15+r13*4], eax
    inc     r13d
6:  inc     ecx
    jmp     3b
7:  # project the group: u, v axes of the seed's normal
    movss   xmm4, [rsp]
    movss   xmm5, [rsp+4]
    movss   xmm6, [rsp+8]
    lea     rdi, [rsp+16]
    call    axes_from
    xor     r12d, r12d
71: cmp     r12d, r13d
    jae     74f
    mov     r14d, [r15+r12*4]
    mov     rax, [rip+ut_m]
    mov     r8, [rax+ME_POFF]
    mov     ecx, [r8+r14*4]
    mov     edx, [r8+r14*4+4]
72: cmp     ecx, edx
    jae     73f
    mov     rax, [rip+ut_m]
    mov     r8, [rax+ME_LOOPS]
    mov     r9d, [r8+rcx*4]
    lea     r9, [r9+r9*2]
    shl     r9, 2
    add     r9, [rax+ME_POS]
    mov     r10, [rax+ME_UV]
    movss   xmm0, [r9]
    mulss   xmm0, [rsp+28]
    movss   xmm1, [r9+4]
    mulss   xmm1, [rsp+32]
    addss   xmm0, xmm1
    movss   xmm1, [r9+8]
    mulss   xmm1, [rsp+36]
    addss   xmm0, xmm1
    movss   [r10+rcx*8], xmm0
    movss   xmm0, [r9]
    mulss   xmm0, [rsp+40]
    movss   xmm1, [r9+4]
    mulss   xmm1, [rsp+44]
    addss   xmm0, xmm1
    movss   xmm1, [r9+8]
    mulss   xmm1, [rsp+48]
    addss   xmm0, xmm1
    movss   [r10+rcx*8+4], xmm0
    inc     ecx
    jmp     72b
73: inc     r12d
    jmp     71b
74: inc     ebp
8:  inc     ebx
    jmp     1b
.Lsm_csr:
    mov     [rip+ut_nisl], ebp
    mov     eax, 1
    jmp     9f
.Lsm_fail:
    xor     eax, eax
9:  add     rsp, 56
    pop     rbp
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# =============================================================================
#  Packing
# =============================================================================
.section .bss
.align 8
pk_w:           .skip 8                 # per island: box width, height,
pk_h:           .skip 8                 #  place x, y (floats), order
pk_x:           .skip 8
pk_y:           .skip 8
pk_ord:         .skip 8
sk_x:           .skip 8                 # skyline segments: x, y, w
sk_y:           .skip 8
sk_w:           .skip 8
sk_n:           .skip 4
pk_width:       .skip 4
pk_margin:      .skip 4
.text

# isl_loops(edi=island, rsi=callback(ecx=loop; rbx, r12.. kept)) - every
#   loop of its polygons. The callback gets r8 = the UV array.
isl_loops:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    mov     r15, rsi
    mov     rax, [rip+ut_ioff]
    mov     ebx, [rax+rdi*4]
    mov     r12d, [rax+rdi*4+4]
1:  cmp     ebx, r12d
    jae     9f
    mov     rax, [rip+ut_ipoly]
    mov     eax, [rax+rbx*4]
    mov     rdx, [rip+ut_m]
    mov     r8, [rdx+ME_POFF]
    mov     r13d, [r8+rax*4]
    mov     r14d, [r8+rax*4+4]
2:  cmp     r13d, r14d
    jae     3f
    mov     ecx, r13d
    mov     r8, [rdx+ME_UV]
    call    r15
    mov     rdx, [rip+ut_m]
    inc     r13d
    jmp     2b
3:  inc     ebx
    jmp     1b
9:  pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# the callbacks work on pk_cur: xmm8 = cos, xmm9 = sin, xmm10..13 = box
#   (min u, min v, max u, max v), xmm14 = scale, xmm15 = (du, dv) offsets
cb_box_rot:                             # box of the turned UVs
    movss   xmm0, [r8+rcx*8]
    movss   xmm1, [r8+rcx*8+4]
    movss   xmm2, xmm0                  # u' = c u - s v
    mulss   xmm2, xmm8
    movss   xmm3, xmm1
    mulss   xmm3, xmm9
    subss   xmm2, xmm3
    mulss   xmm0, xmm9                  # v' = s u + c v
    mulss   xmm1, xmm8
    addss   xmm0, xmm1
    minss   xmm10, xmm2
    minss   xmm11, xmm0
    maxss   xmm12, xmm2
    maxss   xmm13, xmm0
    ret
cb_turn:                                # scale, turn, then offset
    movss   xmm0, [r8+rcx*8]
    movss   xmm1, [r8+rcx*8+4]
    mulss   xmm0, xmm14
    mulss   xmm1, xmm14
    movss   xmm2, xmm0
    mulss   xmm2, xmm8
    movss   xmm3, xmm1
    mulss   xmm3, xmm9
    subss   xmm2, xmm3
    mulss   xmm0, xmm9
    mulss   xmm1, xmm8
    addss   xmm0, xmm1
    movss   [r8+rcx*8], xmm2
    movss   [r8+rcx*8+4], xmm0
    ret
cb_shift:                               # + (xmm15 low: du, high: dv), / xmm14
    movss   xmm0, [r8+rcx*8]
    addss   xmm0, xmm15
    mulss   xmm0, xmm14
    movss   [r8+rcx*8], xmm0
    movaps  xmm1, xmm15
    shufps  xmm1, xmm1, 0x55
    movss   xmm0, [r8+rcx*8+4]
    addss   xmm0, xmm1
    mulss   xmm0, xmm14
    movss   [r8+rcx*8+4], xmm0
    ret

# isl_areas(edi=island) -> xmm0 = its surface area, xmm1 = its UV area
isl_areas:
    push    rbx
    push    r12
    push    r13
    push    r14
    xorps   xmm6, xmm6
    xorps   xmm7, xmm7
    mov     rax, [rip+ut_ioff]
    mov     ebx, [rax+rdi*4]
    mov     r12d, [rax+rdi*4+4]
1:  cmp     ebx, r12d
    jae     9f
    mov     rax, [rip+ut_ipoly]
    mov     eax, [rax+rbx*4]
    mov     rdx, rax
    shl     rdx, 4
    add     rdx, [rip+ut_pnrm]
    addss   xmm6, [rdx+12]
    mov     rdx, [rip+ut_m]             # shoelace over its loops
    mov     r8, [rdx+ME_POFF]
    mov     r13d, [r8+rax*4]
    mov     r14d, [r8+rax*4+4]
    mov     r9, [rdx+ME_UV]
    mov     r10, [rip+ut_next]
    xorps   xmm2, xmm2
2:  cmp     r13d, r14d
    jae     3f
    mov     r11d, [r10+r13*4]
    movss   xmm0, [r9+r13*8]            # u_i v_j - u_j v_i
    mulss   xmm0, [r9+r11*8+4]
    movss   xmm1, [r9+r11*8]
    mulss   xmm1, [r9+r13*8+4]
    subss   xmm0, xmm1
    addss   xmm2, xmm0
    inc     r13d
    jmp     2b
3:  mulss   xmm2, [rip+uf_half]
    andps   xmm2, [rip+uf_absmask]
    addss   xmm7, xmm2
    inc     ebx
    jmp     1b
9:  movss   xmm0, xmm6
    movss   xmm1, xmm7
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# isl_box(edi=island, xmm8 = cos, xmm9 = sin) -> xmm10..13 = the box
isl_box:
    movss   xmm10, [rip+uf_big]
    movss   xmm11, xmm10
    movss   xmm12, [rip+uf_nbig]
    movss   xmm13, xmm12
    lea     rsi, [rip+cb_box_rot]
    jmp     isl_loops

# pack_islands -> eax = 1: islands (ut_pisl / CSR from UV equality) at one
#   texel density, each turned to its smallest box (and upright), boxes
#   on a skyline, the whole scaled into the unit square
pack_islands:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    push    rbp
    sub     rsp, 72
    mov     ebx, [rip+ut_nisl]
    test    ebx, ebx
    jz      .Lpk_ok
    lea     r12, [rip+pk_w]             # per island arrays
    mov     ebp, 5
1:  mov     esi, ebx
    shl     esi, 2
    call    ut_alloc
    test    rax, rax
    jz      .Lpk_fail
    mov     [r12], rax
    add     r12, 8
    dec     ebp
    jnz     1b
    lea     esi, [rbx*8+16]             # skyline (at most 2 n + 1)
    lea     esi, [rsi*4]
    call    ut_alloc
    test    rax, rax
    jz      .Lpk_fail
    mov     [rip+sk_x], rax
    lea     esi, [rbx*8+16]
    lea     esi, [rsi*4]
    call    ut_alloc
    test    rax, rax
    jz      .Lpk_fail
    mov     [rip+sk_y], rax
    lea     esi, [rbx*8+16]
    lea     esi, [rsi*4]
    call    ut_alloc
    test    rax, rax
    jz      .Lpk_fail
    mov     [rip+sk_w], rax
    xorps   xmm0, xmm0                  # sum of box areas, widest
    movss   [rsp], xmm0
    movss   [rsp+4], xmm0
    xor     r12d, r12d
2:  cmp     r12d, ebx
    jae     5f
    mov     edi, r12d                   # scale: UV area = surface area
    call    isl_areas
    movss   xmm14, [rip+uf_one]
    comiss  xmm1, [rip+uf_tiny]
    jbe     21f
    divss   xmm0, xmm1
    sqrtss  xmm14, xmm0
21: movss   [rsp+8], xmm14
    # the smallest box: turns of 2 degrees up to 90
    movss   xmm0, [rip+uf_big]
    movss   [rsp+12], xmm0              # best area
    xorps   xmm0, xmm0
    movss   [rsp+16], xmm0              # best angle
    xor     r13d, r13d
3:  cmp     r13d, 45
    jae     4f
    cvtsi2ss xmm0, r13d
    mulss   xmm0, [rip+uf_step]
    movss   [rsp+20], xmm0
    call    sincos
    movss   xmm9, xmm0
    movss   xmm8, xmm1
    mov     edi, r12d
    call    isl_box
    movss   xmm0, xmm12
    subss   xmm0, xmm10
    movss   xmm1, xmm13
    subss   xmm1, xmm11
    mulss   xmm0, xmm1
    comiss  xmm0, [rsp+12]
    jae     31f
    movss   [rsp+12], xmm0
    movss   xmm0, [rsp+20]
    movss   [rsp+16], xmm0
31: inc     r13d
    jmp     3b
4:  movss   xmm0, [rsp+16]              # turn and scale it
    call    sincos
    movss   xmm9, xmm0
    movss   xmm8, xmm1
    movss   xmm14, [rsp+8]
    mov     edi, r12d
    lea     rsi, [rip+cb_turn]
    call    isl_loops
    movss   xmm8, [rip+uf_one]          # its box now
    xorps   xmm9, xmm9
    mov     edi, r12d
    call    isl_box
    movss   xmm0, xmm12
    subss   xmm0, xmm10
    movss   xmm1, xmm13
    subss   xmm1, xmm11
    comiss  xmm1, xmm0                  # taller than wide: a quarter turn
    jbe     41f
    xorps   xmm8, xmm8
    movss   xmm9, [rip+uf_one]
    movss   xmm14, [rip+uf_one]
    mov     edi, r12d
    lea     rsi, [rip+cb_turn]
    call    isl_loops
    movss   xmm8, [rip+uf_one]
    xorps   xmm9, xmm9
    mov     edi, r12d
    call    isl_box
41: xorps   xmm15, xmm15                # to the origin
    subss   xmm15, xmm10
    xorps   xmm0, xmm0
    subss   xmm0, xmm11
    unpcklps xmm15, xmm0
    movss   xmm14, [rip+uf_one]
    movss   xmm0, xmm12
    subss   xmm0, xmm10
    movss   xmm1, xmm13
    subss   xmm1, xmm11
    mov     rax, [rip+pk_w]
    movss   [rax+r12*4], xmm0
    mov     rax, [rip+pk_h]
    movss   [rax+r12*4], xmm1
    mulss   xmm1, xmm0
    addss   xmm1, [rsp]
    movss   [rsp], xmm1
    mov     edi, r12d
    lea     rsi, [rip+cb_shift]
    call    isl_loops
    mov     rax, [rip+pk_ord]
    mov     [rax+r12*4], r12d
    inc     r12d
    jmp     2b
5:  # margin and strip width
    movss   xmm0, [rsp]
    sqrtss  xmm0, xmm0
    movss   xmm1, xmm0
    mulss   xmm1, [rip+uf_margin]
    movss   [rip+pk_margin], xmm1
    movss   xmm2, xmm1                  # width: sqrt(sum (w+m)(h+m)) x 1.08
    xorps   xmm3, xmm3
    xorps   xmm6, xmm6                  # (widest)
    xor     ecx, ecx
51: cmp     ecx, ebx
    jae     52f
    mov     rax, [rip+pk_w]
    movss   xmm4, [rax+rcx*4]
    addss   xmm4, xmm2
    maxss   xmm6, xmm4
    mov     rax, [rip+pk_h]
    movss   xmm5, [rax+rcx*4]
    addss   xmm5, xmm2
    mulss   xmm4, xmm5
    addss   xmm3, xmm4
    inc     ecx
    jmp     51b
52: sqrtss  xmm3, xmm3
    mulss   xmm3, [rip+uf_widen]
    maxss   xmm3, xmm6
    movss   [rip+pk_width], xmm3
    # tallest first (insertion sort of the order)
    mov     r8, [rip+pk_ord]
    mov     r9, [rip+pk_h]
    mov     ecx, 1
53: cmp     ecx, ebx
    jae     56f
    mov     eax, [r8+rcx*4]
    movss   xmm0, [r9+rax*4]
    mov     edx, ecx
54: test    edx, edx
    jz      55f
    mov     r10d, [r8+rdx*4-4]
    comiss  xmm0, [r9+r10*4]
    jbe     55f
    mov     [r8+rdx*4], r10d
    dec     edx
    jmp     54b
55: mov     [r8+rdx*4], eax
    inc     ecx
    jmp     53b
56: # skyline: one segment (0, 0, width)
    mov     rax, [rip+sk_x]
    mov     dword ptr [rax], 0
    mov     rax, [rip+sk_y]
    mov     dword ptr [rax], 0
    mov     rax, [rip+sk_w]
    movss   xmm0, [rip+pk_width]
    movss   [rax], xmm0
    mov     dword ptr [rip+sk_n], 1
    xorps   xmm0, xmm0
    movss   [rsp+24], xmm0              # height used
    xor     r12d, r12d
6:  cmp     r12d, ebx
    jae     7f
    mov     rax, [rip+pk_ord]
    mov     r13d, [rax+r12*4]
    mov     rax, [rip+pk_w]
    movss   xmm0, [rax+r13*4]
    addss   xmm0, [rip+pk_margin]
    movss   [rsp+28], xmm0              # w'
    mov     rax, [rip+pk_h]
    movss   xmm0, [rax+r13*4]
    addss   xmm0, [rip+pk_margin]
    movss   [rsp+32], xmm0              # h'
    movss   xmm6, [rsp+28]
    movss   xmm7, [rsp+32]
    call    sky_place                   # -> xmm0 x, xmm1 y
    mov     rax, [rip+pk_x]
    movss   [rax+r13*4], xmm0
    mov     rax, [rip+pk_y]
    movss   [rax+r13*4], xmm1
    addss   xmm1, [rsp+32]
    maxss   xmm1, [rsp+24]
    movss   [rsp+24], xmm1
    inc     r12d
    jmp     6b
7:  # into the unit square: (uv + place + m / 2) / size
    movss   xmm0, [rip+pk_width]
    maxss   xmm0, [rsp+24]
    maxss   xmm0, [rip+uf_tiny]
    movss   xmm14, [rip+uf_one]
    divss   xmm14, xmm0
    movss   [rsp+36], xmm14
    xor     r12d, r12d
71: cmp     r12d, ebx
    jae     .Lpk_ok
    movss   xmm0, [rip+pk_margin]
    mulss   xmm0, [rip+uf_half]
    mov     rax, [rip+pk_x]
    movss   xmm15, [rax+r12*4]
    addss   xmm15, xmm0
    mov     rax, [rip+pk_y]
    movss   xmm1, [rax+r12*4]
    addss   xmm1, xmm0
    unpcklps xmm15, xmm1
    movss   xmm14, [rsp+36]
    mov     edi, r12d
    lea     rsi, [rip+cb_shift]
    call    isl_loops
    inc     r12d
    jmp     71b
.Lpk_ok:
    mov     eax, 1
    jmp     9f
.Lpk_fail:
    xor     eax, eax
9:  add     rsp, 72
    pop     rbp
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# sky_place(xmm6 = w', xmm7 = h') -> xmm0 = x, xmm1 = y: the lowest place
#   on the skyline (then leftmost) where the box fits in the width; the
#   skyline rises there
sky_place:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    push    rbp
    sub     rsp, 24
    movss   xmm4, [rip+uf_big]          # best y, x, segment
    movss   xmm5, xmm4
    mov     r12d, -1
    mov     r8, [rip+sk_x]
    mov     r9, [rip+sk_y]
    mov     r10, [rip+sk_w]
    xor     ebx, ebx
1:  cmp     ebx, [rip+sk_n]
    jae     4f
    movss   xmm0, [r8+rbx*4]            # x
    movss   xmm2, xmm0
    addss   xmm2, xmm6                  # right end
    movss   xmm3, [rip+pk_width]
    mulss   xmm3, [rip+uf_fit]
    comiss  xmm2, xmm3
    ja      3f
    xorps   xmm1, xmm1                  # y: the highest under the box
    mov     ecx, ebx
2:  cmp     ecx, [rip+sk_n]
    jae     21f
    movss   xmm3, [r8+rcx*4]
    comiss  xmm3, xmm2
    jae     21f
    maxss   xmm1, [r9+rcx*4]
    inc     ecx
    jmp     2b
21: comiss  xmm1, xmm4
    jb      22f
    ja      3f
    comiss  xmm0, xmm5
    jae     3f
22: movss   xmm4, xmm1
    movss   xmm5, xmm0
    mov     r12d, ebx
3:  inc     ebx
    jmp     1b
4:  cmp     r12d, -1                    # (nothing fits: on top, at 0)
    jne     5f
    xorps   xmm5, xmm5
    xorps   xmm4, xmm4
    mov     ecx, 0
41: cmp     ecx, [rip+sk_n]
    jae     5f
    maxss   xmm4, [r9+rcx*4]
    inc     ecx
    jmp     41b
5:  movss   [rsp], xmm5                 # place (x, y)
    movss   [rsp+4], xmm4
    # new skyline: segments left of x (cut), the box's top, those right of
    #   x + w' (cut)
    movss   xmm2, xmm5
    addss   xmm2, xmm6                  # x1
    movss   xmm3, xmm4
    addss   xmm3, xmm7                  # top
    mov     r13d, [rip+sk_n]
    lea     r14, [r13*4]                # (in place, through a copy at
    lea     rbx, [r8+r14]               #  [n .. 2n): the arrays have room)
    lea     r15, [r9+r14]
    lea     rbp, [r10+r14]
    mov     ecx, r13d
    xor     eax, eax
6:  cmp     eax, ecx
    jae     61f
    mov     edx, [r8+rax*4]
    mov     [rbx+rax*4], edx
    mov     edx, [r9+rax*4]
    mov     [r15+rax*4], edx
    mov     edx, [r10+rax*4]
    mov     [rbp+rax*4], edx
    inc     eax
    jmp     6b
61: xor     r11d, r11d                  # out
    xor     eax, eax
62: cmp     eax, r13d
    jae     66f
    movss   xmm0, [rbx+rax*4]        # segment [s0, s1)
    movss   xmm1, xmm0
    addss   xmm1, [rbp+rax*4]
    comiss  xmm0, xmm5                  # starts left of x
    jae     64f
    movss   [r8+r11*4], xmm0            # its part left of x
    mov     edx, [r15+rax*4]
    mov     [r9+r11*4], edx
    movss   xmm8, xmm1
    minss   xmm8, xmm5
    subss   xmm8, xmm0
    movss   [r10+r11*4], xmm8
    inc     r11d
    comiss  xmm1, xmm2                  # reaching past x1: the box, then
    jbe     65f                         #  its right part
    call    sky_box
    movss   [r8+r11*4], xmm2
    mov     edx, [r15+rax*4]
    mov     [r9+r11*4], edx
    movss   xmm8, xmm1
    subss   xmm8, xmm2
    movss   [r10+r11*4], xmm8
    inc     r11d
    jmp     65f
64: comiss  xmm0, xmm2                  # starts at or after x1: as it is
    jb      63f                         #  (the box first)
    call    sky_box
    movss   [r8+r11*4], xmm0
    mov     edx, [r15+rax*4]
    mov     [r9+r11*4], edx
    mov     edx, [rbp+rax*4]
    mov     [r10+r11*4], edx
    inc     r11d
    jmp     65f
63: comiss  xmm1, xmm2                  # inside [x, x1): its part after x1
    jbe     65f
    call    sky_box
    movss   [r8+r11*4], xmm2
    mov     edx, [r15+rax*4]
    mov     [r9+r11*4], edx
    movss   xmm8, xmm1
    subss   xmm8, xmm2
    movss   [r10+r11*4], xmm8
    inc     r11d
65: inc     eax
    jmp     62b
66: call    sky_box                     # (when nothing came after it)
    mov     [rip+sk_n], r11d
    movss   xmm0, [rsp]
    movss   xmm1, [rsp+4]
    add     rsp, 24
    pop     rbp
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# sky_box - the box's top segment, once (r11 = out; xmm5 x, xmm6 w',
#   xmm3 top; r12 = -2 once written)
sky_box:
    cmp     r12d, -2
    je      1f
    movss   [r8+r11*4], xmm5
    movss   [r9+r11*4], xmm3
    movss   [r10+r11*4], xmm6
    inc     r11d
    mov     r12d, -2
1:  ret

# =============================================================================
#  Entry points
# =============================================================================
# uv_cow(rdi=object or 0: the edit object, else the active mesh) -> rax =
#   its mesh, unshared (0: none / no memory), rdx = the object
uv_cow:
    push    rbx
    mov     rbx, rdi
    test    rbx, rbx
    jnz     1f
    call    edit_get
    mov     rbx, rax
    test    rbx, rbx
    jnz     1f
    call    active_mesh_obj
    mov     rbx, rax
    test    rbx, rbx
    jz      8f
1:  cmp     dword ptr [rbx+OB_TYPE], OT_MESH
    jne     8f
    mov     rdi, [rbx+OB_MESH]
    test    rdi, rdi
    jz      8f
    cmp     dword ptr [rdi+ME_REFS], 1
    jbe     2f
    call    mesh_copy
    test    rax, rax
    jz      8f
    mov     rdi, [rbx+OB_MESH]
    mov     [rbx+OB_MESH], rax
    call    mesh_unref
2:  mov     rax, [rbx+OB_MESH]
    mov     rdx, rbx
    pop     rbx
    ret
8:  xor     eax, eax
    xor     edx, edx
    pop     rbx
    ret

# uv_unwrap(rdi=mesh, esi=0 LSCM along seams, 1 smart projection) -> eax =
#   islands (-1: no memory); packed
uv_unwrap:
    push    rbx
    push    r12
    push    r13
    push    r14
    sub     rsp, 8
    mov     rbx, rdi
    mov     r12d, esi
    call    mesh_uv_alloc
    test    rax, rax
    jz      .Luw_mem0
    call    fa_mark
    mov     [rip+ut_mark], rax
    mov     rdi, rbx
    call    uv_topo
    test    eax, eax
    jz      .Luw_mem
    test    r12d, r12d
    jnz     3f
    xor     edi, edi                    # LSCM: islands along the seams
    call    ut_islands
    xor     r13d, r13d
1:  cmp     r13d, [rip+ut_nisl]
    jae     4f
    mov     edi, r13d
    call    lscm_island
    test    eax, eax
    jz      .Luw_mem
    inc     r13d
    jmp     1b
3:  call    smart_islands
    test    eax, eax
    jz      .Luw_mem
4:  mov     edi, 1                      # pack (islands as the UVs join)
    call    ut_islands
    call    pack_islands
    test    eax, eax
    jz      .Luw_mem
    mov     r13d, [rip+ut_nisl]
    mov     rdi, [rip+ut_mark]
    call    fa_release
    inc     dword ptr [rbx+ME_VER]
    mov     eax, r13d
    jmp     9f
.Luw_mem:
    mov     rdi, [rip+ut_mark]
    call    fa_release
.Luw_mem0:
    mov     eax, -1
9:  add     rsp, 8
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# uv_pack(rdi=mesh) -> eax = islands (-1: no UVs / memory)
uv_pack:
    push    rbx
    push    r12
    sub     rsp, 8
    mov     rbx, rdi
    cmp     qword ptr [rbx+ME_UV], 0
    je      8f
    call    fa_mark
    mov     r12, rax
    mov     rdi, rbx
    call    uv_topo
    test    eax, eax
    jz      7f
    mov     edi, 1
    call    ut_islands
    call    pack_islands
    test    eax, eax
    jz      7f
    mov     rdi, r12
    call    fa_release
    inc     dword ptr [rbx+ME_VER]
    mov     eax, [rip+ut_nisl]
    jmp     9f
7:  mov     rdi, r12
    call    fa_release
8:  mov     eax, -1
9:  add     rsp, 8
    pop     r12
    pop     rbx
    ret

# uv_seams(rdi=mesh, esi=0 mark, 1 clear (edges between selected
#   vertices), 2 every edge sharper than 30 degrees, 3 none at all) -> eax
#   = seam edges now (-1: no memory)
uv_seams:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    mov     rbx, rdi
    mov     r12d, esi
    call    mesh_seam_alloc
    test    rax, rax
    jz      .Lus_mem
    mov     r13, rax
    cmp     r12d, 3
    jne     1f
    mov     rdi, r13
    mov     ecx, [rbx+ME_NLOOPS]
    xor     eax, eax
    rep     stosb
    jmp     .Lus_count
1:  call    fa_mark
    mov     r15, rax
    mov     rdi, rbx
    call    uv_topo
    test    eax, eax
    jz      .Lus_mem2
    xor     r14d, r14d
2:  cmp     r14d, [rip+ut_nl]
    jae     .Lus_done
    cmp     r12d, 2
    je      4f
    mov     rax, [rbx+ME_LOOPS]         # between selected vertices
    mov     r8, [rbx+ME_VSEL]
    mov     ecx, [rax+r14*4]
    cmp     byte ptr [r8+rcx], 0
    je      6f
    mov     rdx, [rip+ut_next]
    mov     ecx, [rdx+r14*4]
    mov     ecx, [rax+rcx*4]
    cmp     byte ptr [r8+rcx], 0
    je      6f
    xor     eax, eax
    cmp     r12d, 0
    sete    al
    mov     [r13+r14], al
    jmp     6f
4:  mov     rax, [rip+ut_twin]          # sharp
    mov     ecx, [rax+r14*4]
    cmp     ecx, UV_NONE
    je      6f
    mov     rax, [rip+ut_lpoly]
    mov     edx, [rax+r14*4]
    mov     ecx, [rax+rcx*4]
    shl     rdx, 4
    add     rdx, [rip+ut_pnrm]
    shl     rcx, 4
    add     rcx, [rip+ut_pnrm]
    movss   xmm0, [rdx]
    mulss   xmm0, [rcx]
    movss   xmm1, [rdx+4]
    mulss   xmm1, [rcx+4]
    addss   xmm0, xmm1
    movss   xmm1, [rdx+8]
    mulss   xmm1, [rcx+8]
    addss   xmm0, xmm1
    comiss  xmm0, [rip+uf_cos30]
    jae     6f
    mov     byte ptr [r13+r14], 1
6:  inc     r14d
    jmp     2b
.Lus_done:
    mov     rdi, r15
    call    fa_release
.Lus_count:
    xor     eax, eax                    # (each edge has two sides)
    xor     ecx, ecx
7:  cmp     ecx, [rbx+ME_NLOOPS]
    jae     8f
    movzx   edx, byte ptr [r13+rcx]
    add     eax, edx
    inc     ecx
    jmp     7b
8:  inc     eax
    shr     eax, 1
    inc     dword ptr [rbx+ME_VER]
    jmp     9f
.Lus_mem2:
    mov     rdi, r15
    call    fa_release
.Lus_mem:
    mov     eax, -1
9:  pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# =============================================================================
#  Measures: uv_stat(rdi=mesh, esi=what) -> xmm0
#   0 islands, 1 mean angle distortion (degrees, per triangle corner),
#   2 area distortion (sum over triangles of |UV share - surface share|,
#   0..2), 3 triangles turned over, 4 UV area covered twice (share of the
#   covered, on a 256 x 256 grid), 5 all inside 0..1 (1 / 0); -1: no UVs
# =============================================================================
.equ OV_N, 256

uv_stat:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    push    rbp
    sub     rsp, 104
    mov     rbx, rdi
    mov     r12d, esi
    cmp     qword ptr [rbx+ME_UV], 0
    je      .Lst_none
    call    fa_mark
    mov     [rsp+96], rax
    cmp     r12d, 5
    je      .Lst_inside
    test    r12d, r12d
    jnz     1f
    mov     rdi, rbx
    call    uv_topo
    test    eax, eax
    jz      .Lst_none2
    mov     edi, 1
    call    ut_islands
    cvtsi2ss xmm0, dword ptr [rip+ut_nisl]
    jmp     .Lst_out
1:  mov     rdi, rbx
    call    uv_topo
    test    eax, eax
    jz      .Lst_none2
    cmp     r12d, 4
    jne     2f
    lea     rdi, [rip+frame_arena]      # coverage grid (u16 counts)
    mov     esi, OV_N*OV_N*2
    call    arena_alloc
    test    rax, rax
    jz      .Lst_none2
    mov     [rsp+88], rax
    mov     rdi, rax
    mov     ecx, OV_N*OV_N/4
    xor     eax, eax
    rep     stosq
2:  xorps   xmm0, xmm0                  # sums: total 3D, total UV area
    movss   [rsp+64], xmm0
    movss   [rsp+68], xmm0
    movss   [rsp+72], xmm0              # result accumulator
    mov     dword ptr [rsp+76], 0       # corners / triangles counted
    cmp     r12d, 2                     # area distortion: totals first
    jne     3f
    mov     dword ptr [rsp+80], 0       # pass 0: totals, 1: shares
    jmp     3f
3:  xor     r13d, r13d                  # triangles
.Lst_tri:
    cmp     r13d, [rbx+ME_NTRIS]
    jae     .Lst_pass
    mov     rax, [rbx+ME_TPOLY]         # corners: loops, positions, UVs
    mov     r14d, [rax+r13*4]
    xor     ebp, ebp
4:  mov     rax, [rbx+ME_TRIS]
    lea     ecx, [r13+r13*2]
    add     ecx, ebp
    mov     esi, [rax+rcx*4]
    mov     edi, r14d
    call    ut_corner
    mov     rdx, [rbx+ME_UV]
    mov     rcx, [rdx+rax*8]
    mov     [rsp+40+rbp*8], rcx         # uv
    mov     rax, [rbx+ME_TRIS]
    lea     ecx, [r13+r13*2]
    add     ecx, ebp
    mov     eax, [rax+rcx*4]
    lea     rax, [rax+rax*2]
    shl     rax, 2
    add     rax, [rbx+ME_POS]
    imul    ecx, ebp, 12
    mov     rdx, [rax]
    mov     [rsp+rcx], rdx
    mov     edx, [rax+8]
    mov     [rsp+rcx+8], edx
    inc     ebp
    cmp     ebp, 3
    jb      4b
    lea     rdi, [rsp]
    lea     rsi, [rsp+40]
    cmp     r12d, 1
    je      .Lst_angle
    cmp     r12d, 2
    je      .Lst_area
    cmp     r12d, 3
    je      .Lst_flip
    jmp     .Lst_cover
.Lst_next:
    inc     r13d
    jmp     .Lst_tri
.Lst_angle:                             # sum over corners |a3 - a2|
    xor     ebp, ebp
5:  mov     edi, ebp
    lea     rsi, [rsp]
    call    angle3
    movss   [rsp+84], xmm0
    mov     edi, ebp
    lea     rsi, [rsp+40]
    call    angle2
    subss   xmm0, [rsp+84]
    andps   xmm0, [rip+uf_absmask]
    addss   xmm0, [rsp+72]
    movss   [rsp+72], xmm0
    inc     dword ptr [rsp+76]
    inc     ebp
    cmp     ebp, 3
    jb      5b
    jmp     .Lst_next
.Lst_area:
    lea     rdi, [rsp]
    call    tri_area3
    movss   [rsp+84], xmm0
    lea     rdi, [rsp+40]
    call    tri_area2
    andps   xmm0, [rip+uf_absmask]
    cmp     dword ptr [rsp+80], 0
    jne     51f
    addss   xmm0, [rsp+68]              # pass 0: totals
    movss   [rsp+68], xmm0
    movss   xmm0, [rsp+84]
    addss   xmm0, [rsp+64]
    movss   [rsp+64], xmm0
    jmp     .Lst_next
51: maxss   xmm1, [rip+uf_tiny]         # pass 1: |uv / UV - a3 / A3|
    movss   xmm1, [rsp+68]
    maxss   xmm1, [rip+uf_tiny]
    divss   xmm0, xmm1
    movss   xmm2, [rsp+84]
    movss   xmm1, [rsp+64]
    maxss   xmm1, [rip+uf_tiny]
    divss   xmm2, xmm1
    subss   xmm0, xmm2
    andps   xmm0, [rip+uf_absmask]
    addss   xmm0, [rsp+72]
    movss   [rsp+72], xmm0
    jmp     .Lst_next
.Lst_flip:                              # UV turning against the surface
    lea     rdi, [rsp+40]
    call    tri_area2
    xorps   xmm1, xmm1
    comiss  xmm0, xmm1
    jae     .Lst_next
    movss   xmm0, [rsp+72]
    addss   xmm0, [rip+uf_one]
    movss   [rsp+72], xmm0
    jmp     .Lst_next
.Lst_cover:                             # raster the UV triangle
    mov     rdi, [rsp+88]
    lea     rsi, [rsp+40]
    call    cover_tri
    jmp     .Lst_next
.Lst_pass:
    cmp     r12d, 2
    jne     6f
    cmp     dword ptr [rsp+80], 0
    jne     6f
    mov     dword ptr [rsp+80], 1
    jmp     3b
6:  movss   xmm0, [rsp+72]
    cmp     r12d, 1
    jne     61f
    cvtsi2ss xmm1, dword ptr [rsp+76]
    maxss   xmm1, [rip+uf_one]
    divss   xmm0, xmm1
    mulss   xmm0, [rip+uf_deg]
    jmp     .Lst_out
61: cmp     r12d, 4
    jne     .Lst_out
    mov     rax, [rsp+88]               # twice / at least once
    xor     ecx, ecx
    xor     edx, edx
    xor     r8d, r8d
62: cmp     ecx, OV_N*OV_N
    jae     63f
    movzx   r9d, word ptr [rax+rcx*2]
    test    r9d, r9d
    jz      621f
    inc     edx
    cmp     r9d, 1
    jbe     621f
    inc     r8d
621:inc     ecx
    jmp     62b
63: cvtsi2ss xmm0, r8d
    cvtsi2ss xmm1, edx
    maxss   xmm1, [rip+uf_one]
    divss   xmm0, xmm1
    jmp     .Lst_out
.Lst_inside:
    movss   xmm0, [rip+uf_one]
    mov     rax, [rbx+ME_UV]
    xor     ecx, ecx
    mov     edx, [rbx+ME_NLOOPS]
    add     edx, edx
7:  cmp     ecx, edx
    jae     .Lst_out
    movss   xmm1, [rax+rcx*4]
    xorps   xmm2, xmm2
    comiss  xmm1, xmm2
    jb      71f
    comiss  xmm1, [rip+uf_one]
    ja      71f
    inc     ecx
    jmp     7b
71: xorps   xmm0, xmm0
    jmp     .Lst_out
.Lst_none2:
    mov     rdi, [rsp+96]
    call    fa_release
.Lst_none:
    movss   xmm0, [rip+uf_mone]
    jmp     9f
.Lst_out:
    movss   [rsp+84], xmm0
    mov     rdi, [rsp+96]
    call    fa_release
    movss   xmm0, [rsp+84]
9:  add     rsp, 104
    pop     rbp
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# angle3(edi=corner, rsi=three positions) -> xmm0 = its angle (radians)
angle3:
    imul    eax, edi, 12
    lea     ecx, [rdi+1]
    cmp     ecx, 3
    jb      1f
    xor     ecx, ecx
1:  imul    ecx, ecx, 12
    lea     edx, [rdi+2]
    cmp     edx, 3
    jb      2f
    sub     edx, 3
2:  imul    edx, edx, 12
    xor     r8d, r8d
    xorps   xmm4, xmm4                  # a.b, a.a, b.b
    xorps   xmm5, xmm5
    xorps   xmm6, xmm6
3:  movss   xmm0, [rsi+rcx]
    subss   xmm0, [rsi+rax]
    movss   xmm1, [rsi+rdx]
    subss   xmm1, [rsi+rax]
    movss   xmm2, xmm0
    mulss   xmm2, xmm1
    addss   xmm4, xmm2
    mulss   xmm0, xmm0
    addss   xmm5, xmm0
    mulss   xmm1, xmm1
    addss   xmm6, xmm1
    add     rsi, 4
    inc     r8d
    cmp     r8d, 3
    jb      3b
    jmp     acos_of

# angle2(edi=corner, rsi=three UVs) -> xmm0 = its angle
angle2:
    lea     eax, [rdi*8]
    lea     ecx, [rdi+1]
    cmp     ecx, 3
    jb      1f
    xor     ecx, ecx
1:  shl     ecx, 3
    lea     edx, [rdi+2]
    cmp     edx, 3
    jb      2f
    sub     edx, 3
2:  shl     edx, 3
    xorps   xmm4, xmm4
    xorps   xmm5, xmm5
    xorps   xmm6, xmm6
    xor     r8d, r8d
3:  movss   xmm0, [rsi+rcx]
    subss   xmm0, [rsi+rax]
    movss   xmm1, [rsi+rdx]
    subss   xmm1, [rsi+rax]
    movss   xmm2, xmm0
    mulss   xmm2, xmm1
    addss   xmm4, xmm2
    mulss   xmm0, xmm0
    addss   xmm5, xmm0
    mulss   xmm1, xmm1
    addss   xmm6, xmm1
    add     rsi, 4
    inc     r8d
    cmp     r8d, 2
    jb      3b
# acos_of(xmm4 = a.b, xmm5 = a.a, xmm6 = b.b) -> xmm0 = the angle (x87)
acos_of:
    mulss   xmm5, xmm6
    sqrtss  xmm5, xmm5
    maxss   xmm5, [rip+uf_tiny]
    divss   xmm4, xmm5
    maxss   xmm4, [rip+uf_mone]
    minss   xmm4, [rip+uf_one]
    sub     rsp, 8
    movss   [rsp], xmm4                 # acos c = atan2(sqrt(1 - c^2), c)
    fld     dword ptr [rsp]
    fld     st(0)
    fmul    st(0), st(0)
    fld1
    fsubrp  st(1), st(0)
    fsqrt
    fxch
    fpatan
    fstp    dword ptr [rsp]
    movss   xmm0, [rsp]
    add     rsp, 8
    ret

# tri_area3(rdi=three positions) -> xmm0 = area
tri_area3:
    movss   xmm0, [rdi+12]
    subss   xmm0, [rdi]
    movss   xmm1, [rdi+16]
    subss   xmm1, [rdi+4]
    movss   xmm2, [rdi+20]
    subss   xmm2, [rdi+8]
    movss   xmm3, [rdi+24]
    subss   xmm3, [rdi]
    movss   xmm4, [rdi+28]
    subss   xmm4, [rdi+4]
    movss   xmm5, [rdi+32]
    subss   xmm5, [rdi+8]
    movss   xmm6, xmm1                  # |e1 x e2|
    mulss   xmm6, xmm5
    movss   xmm7, xmm2
    mulss   xmm7, xmm4
    subss   xmm6, xmm7
    mulss   xmm6, xmm6
    movss   xmm7, xmm2
    mulss   xmm7, xmm3
    movss   xmm8, xmm0
    mulss   xmm8, xmm5
    subss   xmm7, xmm8
    mulss   xmm7, xmm7
    addss   xmm6, xmm7
    movss   xmm7, xmm0
    mulss   xmm7, xmm4
    movss   xmm8, xmm1
    mulss   xmm8, xmm3
    subss   xmm7, xmm8
    mulss   xmm7, xmm7
    addss   xmm6, xmm7
    sqrtss  xmm0, xmm6
    mulss   xmm0, [rip+uf_half]
    ret

# tri_area2(rdi=three UVs) -> xmm0 = signed area (counter-clockwise +)
tri_area2:
    movss   xmm0, [rdi+8]
    subss   xmm0, [rdi]
    movss   xmm1, [rdi+20]
    subss   xmm1, [rdi+4]
    mulss   xmm0, xmm1
    movss   xmm1, [rdi+16]
    subss   xmm1, [rdi]
    movss   xmm2, [rdi+12]
    subss   xmm2, [rdi+4]
    mulss   xmm1, xmm2
    subss   xmm0, xmm1
    mulss   xmm0, [rip+uf_half]
    ret

# cover_tri(rdi=grid, rsi=three UVs) - +1 on the cells whose centres lie
#   inside (either winding; on an edge: the cell's own rule, top-left)
cover_tri:
    push    rbx
    push    r12
    push    r13
    push    r14
    sub     rsp, 40
    mov     rbx, rdi
    xor     ecx, ecx                    # corners in grid units
1:  movss   xmm0, [rsi+rcx*4]
    mulss   xmm0, [rip+uf_ovn]
    movss   [rsp+rcx*4], xmm0
    inc     ecx
    cmp     ecx, 6
    jb      1b
    lea     rdi, [rsp]                  # winding
    call    tri_area2
    movss   [rsp+24], xmm0
    andps   xmm0, [rip+uf_absmask]
    comiss  xmm0, [rip+uf_tiny]
    jbe     9f
    movss   xmm0, [rsp]                 # the box, clipped
    minss   xmm0, [rsp+8]
    minss   xmm0, [rsp+16]
    cvttss2si r12d, xmm0
    movss   xmm0, [rsp]
    maxss   xmm0, [rsp+8]
    maxss   xmm0, [rsp+16]
    cvttss2si r13d, xmm0
    movss   xmm0, [rsp+4]
    minss   xmm0, [rsp+12]
    minss   xmm0, [rsp+20]
    cvttss2si r14d, xmm0
    movss   xmm0, [rsp+4]
    maxss   xmm0, [rsp+12]
    maxss   xmm0, [rsp+20]
    cvttss2si eax, xmm0
    mov     [rsp+28], eax
    test    r12d, r12d
    jns     11f
    xor     r12d, r12d
11: cmp     r13d, OV_N-1
    jle     12f
    mov     r13d, OV_N-1
12: test    r14d, r14d
    jns     13f
    xor     r14d, r14d
13: cmp     dword ptr [rsp+28], OV_N-1
    jle     2f
    mov     dword ptr [rsp+28], OV_N-1
2:  cmp     r14d, [rsp+28]
    jg      9f
    mov     r9d, r12d
3:  cmp     r9d, r13d
    jg      8f
    cvtsi2ss xmm6, r9d                  # the centre
    addss   xmm6, [rip+uf_half]
    cvtsi2ss xmm7, r14d
    addss   xmm7, [rip+uf_half]
    xor     r10d, r10d                  # each edge: the centre on the inside
    xor     ecx, ecx
4:  lea     edx, [rcx+1]
    cmp     edx, 3
    jb      41f
    xor     edx, edx
41: movss   xmm0, [rsp+rdx*8]           # (b - a) x (p - a)
    subss   xmm0, [rsp+rcx*8]
    movss   xmm1, xmm7
    subss   xmm1, [rsp+rcx*8+4]
    mulss   xmm0, xmm1
    movss   xmm1, [rsp+rdx*8+4]
    subss   xmm1, [rsp+rcx*8+4]
    movss   xmm2, xmm6
    subss   xmm2, [rsp+rcx*8]
    mulss   xmm1, xmm2
    subss   xmm0, xmm1
    mulss   xmm0, [rsp+24]              # (signed by the winding)
    xorps   xmm1, xmm1
    comiss  xmm0, xmm1
    jb      7f                          # outside
    ja      42f
    inc     r10d                        # on the edge: half of them count
42: inc     ecx
    cmp     ecx, 3
    jb      4b
    cmp     r10d, 0                     # (on an edge: only if it is the
    je      5f                          #  cell's lower-left side - skip)
    jmp     7f
5:  mov     eax, r14d
    shl     eax, 8
    add     eax, r9d
    inc     word ptr [rbx+rax*2]
7:  inc     r9d
    jmp     3b
8:  inc     r14d
    jmp     2b
9:  add     rsp, 40
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# uv_select_island(rdi=mesh, esi=polygon, rdx=per-loop flags) - its UV
#   island's loops get 1
uv_select_island:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    mov     rbx, rdi
    mov     r12d, esi
    mov     r13, rdx
    call    fa_mark
    mov     r14, rax
    mov     rdi, rbx
    call    uv_topo
    test    eax, eax
    jz      8f
    mov     edi, 1
    call    ut_islands
    mov     rax, [rip+ut_pisl]
    mov     edi, [rax+r12*4]
    mov     rax, [rip+ut_ioff]
    mov     r15d, [rax+rdi*4]
    mov     r12d, [rax+rdi*4+4]
1:  cmp     r15d, r12d
    jae     8f
    mov     rax, [rip+ut_ipoly]
    mov     eax, [rax+r15*4]
    mov     rdx, [rbx+ME_POFF]
    mov     ecx, [rdx+rax*4]
    mov     edx, [rdx+rax*4+4]
2:  cmp     ecx, edx
    jae     3f
    mov     byte ptr [r13+rcx], 1
    inc     ecx
    jmp     2b
3:  inc     r15d
    jmp     1b
8:  mov     rdi, r14
    call    fa_release
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# =============================================================================
#  Operators
# =============================================================================
do_unwrap:                              # edi = 0 unwrap, 1 smart
    push    rbx
    mov     ebx, edi
    xor     edi, edi
    call    uv_cow
    test    rax, rax
    jz      .Ldu_none
    mov     rdi, rax
    mov     esi, ebx
    call    uv_unwrap
    jmp     uv_report
.Ldu_none:
    lea     rdi, [rip+s_uv_none]
    call    log_line
    call    undo_drop_last
    pop     rbx
    ret

do_pack:
    push    rbx
    xor     edi, edi
    call    uv_cow
    test    rax, rax
    jz      .Ldu_none
    mov     rdi, rax
    call    uv_pack
# uv_report(eax = islands, -1: failed) - logs, redraws (pops rbx)
uv_report:
    test    eax, eax
    js      1f
    push    rax
    call    fmt_reset
    lea     rdi, [rip+s_uv_islands]
    call    fmt_str
    pop     rdi
    call    fmt_int
    lea     rdi, [rip+fmt_buf]
    call    log_line
    mov     dword ptr [rip+dirty], 1
    pop     rbx
    ret
1:  lea     rdi, [rip+s_uv_mem]
    call    log_line
    pop     rbx
    ret

do_seams:                               # edi = 0 mark, 1 clear, 2 sharp
    push    rbx
    mov     ebx, edi
    xor     edi, edi
    call    uv_cow
    test    rax, rax
    jz      .Ldu_none
    mov     rdi, rax
    mov     esi, ebx
    call    uv_seams
    test    eax, eax
    js      1f
    push    rax
    call    fmt_reset
    lea     rdi, [rip+s_uv_seams]
    call    fmt_str
    pop     rdi
    call    fmt_int
    lea     rdi, [rip+fmt_buf]
    call    log_line
    mov     dword ptr [rip+dirty], 1
    pop     rbx
    ret
1:  lea     rdi, [rip+s_uv_mem]
    call    log_line
    pop     rbx
    ret
