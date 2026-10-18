# =============================================================================
#  BeeModel - shatter: cutting a closed mesh into convex cells.
#
#  A cell is a set of planes (n.x <= d inside). A solid is convex polygons
#  (the mesh's triangles to start with) and is clipped by one plane after
#  another, in doubles: each vertex is in, on (within the tolerance) or
#  out; a polygon with nothing out is kept, one with nothing in goes, the
#  rest are clipped (Sutherland-Hodgman; the point on a cut edge is made
#  once, from the edge's ends in order, so both its polygons share it).
#  What is kept is closed but for holes in the plane: the edges of kept
#  polygons that lie in the plane and have no twin. Those are chained into
#  loops (the other way round) and filled: outer loops wind counter-
#  clockwise seen from outside, holes clockwise; a convex loop is one
#  polygon; otherwise each hole is bridged into the smallest outer loop
#  around it, the ring is ear clipped (reflex corners in a grid) and the
#  triangles are joined again into convex polygons (Hertel-Mehlhorn).
#  Every step keeps the solid closed, so after the last plane the piece is
#  (mesh inside the cell), a cell wholly inside the mesh included. The
#  parts of a piece that do not touch (a concave mesh) become pieces of
#  their own.
#
#  The cells go into a tree (split at their centres' median); each node's
#  solid is its parent's clipped by the node's box, level by level, so a
#  cell is cut from its leaf's small solid, not the whole mesh. Cells and
#  nodes are cut in parallel, each in its thread's arena; the pieces (float
#  vertices from the piece's centre, polygons with the plane that made
#  them) go to the main thread, which makes the meshes (shatterop.s).
# =============================================================================
.intel_syntax noprefix
.include "const.inc"

.globl sh_src_set
.globl sh_src_free
.globl sh_cut_all
.globl sh_res
.globl sh_nres
.globl sh_res_free
.globl sh_inside
.globl sh_src_p
.globl sh_src_t
.globl sh_src_nv
.globl sh_src_nt
.globl sh_src_min
.globl sh_src_max
.globl sh_src_vol
.globl sh_tol
.globl sh_seeds
.globl sh_nseeds
.globl sh_cpl
.globl sh_cpn
.globl sh_cbb
.globl sh_cells_alloc
.globl sh_cells_free
.globl sh_mode
.globl sh_open_edges
.globl tris_open
.globl polys_open
.globl sh_cnt

.equ VX_SZ,     24                      # a vertex: x y z (doubles)
.equ TR_SZ,     16                      # a triangle: a b c, tag (the source)
.equ PR_SZ,     16                      # a polygon (convex): its first loop,
.equ PR_FIRST,  0                       #  how many, its tag (0: the surface;
.equ PR_CNT,    4                       #  else the plane that made it)
.equ PR_TAG,    8
.equ PLN_SZ,    40                      # a plane: n (3 doubles), d, tag
.equ PLN_TAG,   32
.equ CPL_MAX,   128                     # planes a cell at most
.equ NAR,       65                      # arenas: one a thread, one inline
.equ ARCAP,     0x40000000              # 1 GiB of address space each
.equ MAP_ANON_PRIV, 0x22
.equ CL_IN,     0
.equ CL_ON,     1
.equ CL_OUT,    2
# a cut (in its arena): its solid
.equ CX_AR,     0                       # the arena
.equ CX_V,      8                       # vertices (VX_SZ)
.equ CX_P,      16                      # polygons (PR_SZ)
.equ CX_L,      24                      # their loops (u32 vertices)
.equ CX_NV,     32
.equ CX_NP,     36
.equ CX_NL,     40
.equ CX_FAIL,   44                      # out of room
.equ CX_RAR,    48                      # the thread's arena for results
.equ CX_SZ,     64
# a cell's result: how many pieces, then each: its counts, volume, centre;
#   its vertices (floats, from the centre), polygons (count, tag), loops
.equ PP_N,      0
.equ PP_HDR,    8
.equ PH_NV,     0
.equ PH_NP,     4
.equ PH_NL,     8
.equ PH_VOL,    16
.equ PH_C,      24
.equ PH_SZ,     48
# a tree node
.equ TN_FIRST,  0                       # its cells: from, how many (tree order)
.equ TN_CNT,    4
.equ TN_PAR,    8                       # its parent (-1: the root)
.equ TN_LEV,    12
.equ TN_LEAF,   16
.equ TN_NV,     20                      # its solid: counts,
.equ TN_NP,     24
.equ TN_NL,     28
.equ TN_V,      32                      #  arrays (the root: the mesh's; the
                                        #  others in the results' arenas)
.equ TN_P,      40
.equ TN_L,      48
.equ TN_MIN,    72                      # its box (doubles)
.equ TN_MAX,    96
.equ TN_SZ,     128
# clip_plane's frame
.equ CF_PL,     0
.equ CF_S,      8                       # double per vertex: n.v - d
.equ CF_CL,     16                      # u8 per vertex: in on out
.equ CF_RM,     24                      # u32 per vertex: its new index (-1)
.equ CF_VO,     32                      # the new vertices,
.equ CF_ONP,    40                      #  u8 each: in the plane
.equ CF_PO,     48                      # the new polygons
.equ CF_EK,     56                      # cut edges: keys (u64),
.equ CF_EV,     64                      #  their points (u32)
.equ CF_EM,     72                      #  mask
.equ CF_NVO,    80
.equ CF_NPO,    84
.equ CF_NIN,    88
.equ CF_NOUT,   92
.equ CF_NSTR,   96
.equ CF_NTCH,   100
.equ CF_NKEEP,  104
.equ CF_TAG,    108
.equ CF_LO,     112                     # the new loops
.equ CF_NLO,    120
.equ CF_CAPP,   124                     # room for polygons, loops
.equ CF_CAPL,   128
.equ CF_LSUM,   132                     # loops of the kept and cut ones
.equ CF_BSUM,   136                     # edges of the touching and cut ones
.equ CF_VIN,    144
.equ CF_PIN,    152
.equ CF_LIN,    160
.equ CF_NVIN,   168
.equ CF_NPIN,   172
.equ CF_SZ,     192
# cap_build's frame
.equ CB_BE,     0                       # boundary edges (from, to) the cap's way
.equ CB_NB,     8
.equ CB_HK,     16                      # from-vertex hash: keys,
.equ CB_HV,     24                      #  the first edge,
.equ CB_HM,     32                      #  mask
.equ CB_ENX,    40                      # the next edge from the same vertex
.equ CB_USED,   48
.equ CB_RID,    56                      # the rings: vertex,
.equ CB_RX,     64                      #  x, y in the plane,
.equ CB_RY,     72
.equ CB_NXT,    80                      #  next, previous
.equ CB_PRV,    88
.equ CB_NR,     96
.equ CB_NL,     100
.equ CB_LST,    104                     # loops: a ring entry,
.equ CB_LCN,    112                     #  how many,
.equ CB_LAR,    120                     #  area (double),
.equ CB_LOUT,   128                     #  a hole's outer loop (-1),
.equ CB_LMX,    136                     #  the entry with the largest x
.equ CB_U,      144                     # the plane's axes (3 doubles each)
.equ CB_W,      168
.equ CB_CF,     192
.equ CB_CX,     200
.equ CB_MARK,   208                     # u32 per entry (bridges; then reflex)
.equ CB_NREF,   216                     # reflex corners in the ring
.equ CB_GH,     224                     # a grid of the reflex corners: heads,
.equ CB_GN,     232                     #  next (-1 ends), cells a side,
.equ CB_GS,     240                     #  its corner, cells per unit
.equ CB_GX,     248
.equ CB_GY,     256
.equ CB_GIX,    264
.equ CB_GIY,    272
.equ CB_NBR,    280                     # holes bridged into the ring
.equ CB_T0,     284                     # its first triangle, loop
.equ CB_L0,     288
.equ CB_SZ,     304

.section .rodata
.align 16
sd_absmask:     .quad 0x7fffffffffffffff, 0
sd_one:         .double 1.0
sd_half:        .double 0.5
sd_zero:        .double 0.0
sd_06:          .double 0.6
sd_sixth:       .double 0.16666666666666666
sd_big:         .double 1.0e300
sd_tolr:        .double 1.0e-9              # the tolerance: this of the size
sd_pad:         .double 0.01                # the cell box: 1% beyond the mesh
sd_ray:         .double 0.5773502691896258, 0.5773674398219341, 0.5773330981405107
sd_tiny:        .double 1.0e-300
sd_volr:        .double 1.0e-12             # pieces under this of the volume go
sd_under:       .double 0.999999
sd_hair:        .double 10000.0
sd_near:        .double 0.02
sd_100:         .double 100.0
sd_flat:        .double 1.0e-12             # a corner's sine^2 under this: straight

.section .bss
.align 16
sh_ar:          .skip ARENA_SZ*NAR
sh_arok:        .skip NAR
.align 16
sh_rar:         .skip ARENA_SZ*NAR      # results (pieces, nodes' solids): kept
sh_rarok:       .skip NAR               #  until the next cut
.align 8
sh_src_p:       .skip 8                 # the mesh: vertices (VX_SZ),
sh_src_t:       .skip 8                 #  triangles (TR_SZ),
sh_src_pp:      .skip 8                 #  the same as polygons, loops
sh_src_pl:      .skip 8
sh_src_ppb:     .skip 8
sh_src_pb:      .skip 8                 #  (their mappings' sizes)
sh_src_tb:      .skip 8
sh_src_nv:      .skip 4
sh_src_nt:      .skip 4
sh_src_min:     .skip 24                # its bounds (doubles)
sh_src_max:     .skip 24
sh_src_vol:     .skip 8
sh_tol:         .skip 8
sh_mode:        .skip 4                 # 0: planes per cell (sh_cellpl), 1:
                                        #  Voronoi cells of sh_seeds
sh_nres:        .skip 4                 # cells
sh_res:         .skip 8                 # per cell: its result (mapping), size
sh_seeds:       .skip 8                 # doubles x y z (VX_SZ)
sh_nseeds:      .skip 4
sh_open_edges:  .skip 4                 # the mesh's edges without a twin
sh_ncell:       .skip 4                 # cells:
.align 8
sh_cpl:         .skip 8                 #  their planes (CPL_MAX each),
sh_cpn:         .skip 8                 #  how many (u32; 0: none),
sh_cbb:         .skip 8                 #  their bounds (6 doubles)
tr_nodes:       .skip 8                 # the tree: nodes (TN_SZ),
tr_bytes:       .skip 8
tr_order:       .skip 8                 #  the cells in its order,
tr_leaf:        .skip 8                 #  each cell's leaf,
tr_keys:        .skip 8
tr_stack:       .skip 8
tr_nn:          .skip 4
tr_levels:      .skip 4
tr_level:       .skip 4
.align 8
sh_tlap:        .skip 8
sh_fam:         .skip 8
sh_cnt:         .skip 64                # (the phases' ns: 1 cells, 2 tree,
                                        #  3 levels, 4 cells from leaves)

.text

# -----------------------------------------------------------------------------
# small helpers
# -----------------------------------------------------------------------------
# sh_map(rsi=bytes) -> rax = zeroed mapping or 0
sh_map:
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

# sh_unmap(rdi=mapping, rsi=bytes)
sh_unmap:
    test    rdi, rdi
    jz      1f
    add     rsi, 4095
    and     rsi, -4096
    jz      1f
    mov     eax, SYS_MUNMAP
    syscall
1:  ret

# cx_alloc(rbx=cut, rsi=bytes) -> rax (0: out of room, CX_FAIL set)
cx_alloc:
    mov     rdi, [rbx+CX_AR]
    add     rsi, 16
    call    arena_alloc
    test    rax, rax
    jnz     1f
    mov     dword ptr [rbx+CX_FAIL], 1
1:  ret

# hbits(eax=at least) -> ecx = a power of two >= 2 * that (at least 16)
hpow:
    mov     ecx, 16
    add     eax, eax
1:  cmp     ecx, eax
    jae     2f
    add     ecx, ecx
    jmp     1b
2:  ret

# hslot(rax=key, ecx=mask) -> rdx = its first slot
.macro HSLOT key, mask, out
    mov     \out, \key
    imul    \out, \out, -0x61C8864F
    shr     \out, 7
    xor     \out, \key
    imul    \out, \out, -0x7A143595
    shr     \out, 11
    and     \out, \mask
.endm

# -----------------------------------------------------------------------------
# sh_src_set(rdi=finished mesh) -> eax = 1 (0: no memory): its vertices and
#   triangles in doubles, its bounds, volume, the tolerance; sh_open_edges
#   = the edges with no twin (0: closed)
# -----------------------------------------------------------------------------
sh_src_set:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    mov     rbx, rdi
    call    sh_src_free
    mov     eax, [rbx+ME_NVERTS]
    mov     [rip+sh_src_nv], eax
    imul    rsi, rax, VX_SZ
    mov     [rip+sh_src_pb], rsi
    call    sh_map
    test    rax, rax
    jz      8f
    mov     [rip+sh_src_p], rax
    mov     eax, [rbx+ME_NTRIS]
    mov     [rip+sh_src_nt], eax
    mov     rsi, rax
    shl     rsi, 4
    mov     [rip+sh_src_tb], rsi
    call    sh_map
    test    rax, rax
    jz      8f
    mov     [rip+sh_src_t], rax
    movsd   xmm6, [rip+sd_big]          # vertices, bounds
    movsd   xmm7, xmm6
    movsd   xmm8, xmm6
    movsd   xmm9, xmm6
    xorpd   xmm9, xmm9
    subsd   xmm9, xmm6
    movsd   xmm10, xmm9
    movsd   xmm11, xmm9
    mov     rsi, [rbx+ME_POS]
    mov     rdi, [rip+sh_src_p]
    xor     ecx, ecx
1:  cmp     ecx, [rip+sh_src_nv]
    jae     2f
    cvtss2sd xmm0, [rsi]
    cvtss2sd xmm1, [rsi+4]
    cvtss2sd xmm2, [rsi+8]
    movsd   [rdi], xmm0
    movsd   [rdi+8], xmm1
    movsd   [rdi+16], xmm2
    minsd   xmm6, xmm0
    minsd   xmm7, xmm1
    minsd   xmm8, xmm2
    maxsd   xmm9, xmm0
    maxsd   xmm10, xmm1
    maxsd   xmm11, xmm2
    add     rsi, 12
    add     rdi, VX_SZ
    inc     ecx
    jmp     1b
2:  movsd   [rip+sh_src_min], xmm6
    movsd   [rip+sh_src_min+8], xmm7
    movsd   [rip+sh_src_min+16], xmm8
    movsd   [rip+sh_src_max], xmm9
    movsd   [rip+sh_src_max+8], xmm10
    movsd   [rip+sh_src_max+16], xmm11
    subsd   xmm9, xmm6                  # the tolerance: 1e-9 of the size
    subsd   xmm10, xmm7
    subsd   xmm11, xmm8
    maxsd   xmm9, xmm10
    maxsd   xmm9, xmm11
    mulsd   xmm9, [rip+sd_tolr]
    maxsd   xmm9, [rip+sd_tiny]
    movsd   [rip+sh_tol], xmm9
    mov     rsi, [rbx+ME_TRIS]          # triangles
    mov     rdi, [rip+sh_src_t]
    xor     ecx, ecx
3:  cmp     ecx, [rip+sh_src_nt]
    jae     4f
    mov     eax, [rsi]
    mov     [rdi], eax
    mov     eax, [rsi+4]
    mov     [rdi+4], eax
    mov     eax, [rsi+8]
    mov     [rdi+8], eax
    mov     dword ptr [rdi+12], 0
    add     rsi, 12
    add     rdi, TR_SZ
    inc     ecx
    jmp     3b
4:  mov     eax, [rip+sh_src_nt]        # polygons: each triangle, its loops
    imul    rsi, rax, PR_SZ+12
    mov     [rip+sh_src_ppb], rsi
    call    sh_map
    test    rax, rax
    jz      8f
    mov     [rip+sh_src_pp], rax
    mov     ecx, [rip+sh_src_nt]
    shl     rcx, 4
    add     rcx, rax
    mov     [rip+sh_src_pl], rcx
    xor     edx, edx
44: cmp     edx, [rip+sh_src_nt]
    jae     45f
    lea     r8d, [rdx+rdx*2]
    mov     [rax+PR_FIRST], r8d
    mov     dword ptr [rax+PR_CNT], 3
    mov     dword ptr [rax+PR_TAG], 0
    add     rax, PR_SZ
    inc     edx
    jmp     44b
45: mov     rdi, [rip+sh_src_p]
    mov     rsi, [rip+sh_src_t]
    mov     edx, [rip+sh_src_nt]
    call    tri_volume
    xorpd   xmm1, xmm1                  # inside out: turned
    comisd  xmm0, xmm1
    jae     41f
    subsd   xmm1, xmm0
    movsd   xmm0, xmm1
    mov     rsi, [rip+sh_src_t]
    mov     ecx, [rip+sh_src_nt]
    test    ecx, ecx
    jz      41f
42: mov     eax, [rsi+4]
    mov     edx, [rsi+8]
    mov     [rsi+4], edx
    mov     [rsi+8], eax
    add     rsi, TR_SZ
    dec     ecx
    jnz     42b
41: movsd   [rip+sh_src_vol], xmm0
    mov     rcx, [rip+sh_src_pl]        # the loops: the triangles as they
    mov     rsi, [rip+sh_src_t]         #  are now
    xor     edx, edx
46: cmp     edx, [rip+sh_src_nt]
    jae     47f
    lea     r8d, [rdx+rdx*2]
    mov     r9d, [rsi]
    mov     [rcx+r8*4], r9d
    mov     r9d, [rsi+4]
    mov     [rcx+r8*4+4], r9d
    mov     r9d, [rsi+8]
    mov     [rcx+r8*4+8], r9d
    add     rsi, TR_SZ
    inc     edx
    jmp     46b
47:
    mov     rdi, [rip+sh_src_t]
    mov     esi, [rip+sh_src_nt]
    call    tris_open
    mov     [rip+sh_open_edges], eax
    mov     eax, 1
    jmp     9f
8:  call    sh_src_free
    xor     eax, eax
9:  pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

sh_src_free:
    mov     rdi, [rip+sh_src_p]
    mov     rsi, [rip+sh_src_pb]
    call    sh_unmap
    mov     rdi, [rip+sh_src_t]
    mov     rsi, [rip+sh_src_tb]
    call    sh_unmap
    mov     rdi, [rip+sh_src_pp]
    mov     rsi, [rip+sh_src_ppb]
    call    sh_unmap
    xor     eax, eax
    mov     [rip+sh_src_p], rax
    mov     [rip+sh_src_t], rax
    mov     [rip+sh_src_pp], rax
    mov     [rip+sh_src_nv], eax
    mov     [rip+sh_src_nt], eax
    ret

# tri_volume(rdi=vertices, rsi=triangles, edx=count) -> xmm0 = the volume
#   (signed tetrahedra from the first vertex)
tri_volume:
    xorpd   xmm0, xmm0
    test    edx, edx
    jz      9f
    mov     eax, [rsi]                  # the origin: a vertex of it
    imul    rax, rax, VX_SZ
    movsd   xmm13, [rdi+rax]
    movsd   xmm14, [rdi+rax+8]
    movsd   xmm15, [rdi+rax+16]
1:  call    tet6
    addsd   xmm0, xmm10
    add     rsi, TR_SZ
    dec     edx
    jnz     1b
    mulsd   xmm0, [rip+sd_sixth]
9:  ret

# tet6(rdi=vertices, rsi=triangle; xmm13-15 = origin) -> xmm10 = six times
#   the tetrahedron's signed volume (xmm1-12 used)
tet6:
    mov     eax, [rsi]
    imul    rax, rax, VX_SZ
    movsd   xmm1, [rdi+rax]
    subsd   xmm1, xmm13
    movsd   xmm2, [rdi+rax+8]
    subsd   xmm2, xmm14
    movsd   xmm3, [rdi+rax+16]
    subsd   xmm3, xmm15
    mov     eax, [rsi+4]
    imul    rax, rax, VX_SZ
    movsd   xmm4, [rdi+rax]
    subsd   xmm4, xmm13
    movsd   xmm5, [rdi+rax+8]
    subsd   xmm5, xmm14
    movsd   xmm6, [rdi+rax+16]
    subsd   xmm6, xmm15
    mov     eax, [rsi+8]
    imul    rax, rax, VX_SZ
    movsd   xmm7, [rdi+rax]
    subsd   xmm7, xmm13
    movsd   xmm8, [rdi+rax+8]
    subsd   xmm8, xmm14
    movsd   xmm9, [rdi+rax+16]
    subsd   xmm9, xmm15
    movsd   xmm10, xmm5                 # a . (b x c)
    mulsd   xmm10, xmm9
    movsd   xmm11, xmm6
    mulsd   xmm11, xmm8
    subsd   xmm10, xmm11
    mulsd   xmm10, xmm1
    movsd   xmm11, xmm6
    mulsd   xmm11, xmm7
    movsd   xmm12, xmm4
    mulsd   xmm12, xmm9
    subsd   xmm11, xmm12
    mulsd   xmm11, xmm2
    addsd   xmm10, xmm11
    movsd   xmm11, xmm4
    mulsd   xmm11, xmm8
    movsd   xmm12, xmm5
    mulsd   xmm12, xmm7
    subsd   xmm11, xmm12
    mulsd   xmm11, xmm3
    addsd   xmm10, xmm11
    ret

# tris_open(rdi=triangles (TR_SZ), esi=count) -> eax = their directed
#   edges with no opposite one (0: closed; -1: no memory)
tris_open:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    mov     r13, rdi
    mov     ebx, esi
    lea     eax, [rbx+rbx*2]
    call    hpow
    mov     r14d, ecx
    lea     r15d, [rcx-1]
    push    rcx
    call    fa_mark
    mov     [rip+sh_fam], rax
    pop     rsi
    shl     rsi, 3
    push    rsi
    lea     rdi, [rip+frame_arena]
    call    arena_alloc
    pop     rcx
    test    rax, rax
    jz      8f
    mov     r12, rax
    mov     rdi, rax
    shr     ecx, 3
    xor     eax, eax
    rep     stosq
    mov     rsi, r13                    # every directed edge in
    xor     ecx, ecx
1:  cmp     ecx, ebx
    jae     3f
    xor     r8d, r8d
2:  mov     eax, [rsi+r8*4]
    lea     r9d, [r8+1]
    cmp     r9d, 3
    jb      21f
    xor     r9d, r9d
21: mov     edx, [rsi+r9*4]
    shl     rax, 32
    or      rax, rdx
    inc     rax
    HSLOT   rax, r15, rdx
22: mov     r10, [r12+rdx*8]
    test    r10, r10
    jz      23f
    cmp     r10, rax
    je      24f
    inc     rdx
    and     rdx, r15
    jmp     22b
23: mov     [r12+rdx*8], rax
24: inc     r8d
    cmp     r8d, 3
    jb      2b
    add     rsi, TR_SZ
    inc     ecx
    jmp     1b
3:  xor     ebx, ebx                    # those whose opposite is not
    xor     ecx, ecx
4:  cmp     ecx, r14d
    jae     7f
    mov     rax, [r12+rcx*8]
    test    rax, rax
    jz      6f
    dec     rax
    rol     rax, 32                     # (b, a)
    inc     rax
    HSLOT   rax, r15, rdx
5:  mov     r10, [r12+rdx*8]
    test    r10, r10
    jz      51f
    cmp     r10, rax
    je      6f
    inc     rdx
    and     rdx, r15
    jmp     5b
51: inc     ebx
6:  inc     ecx
    jmp     4b
7:  mov     rdi, [rip+sh_fam]
    call    fa_release
    mov     eax, ebx
    jmp     9f
8:  mov     eax, -1
9:  pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# polys_open(rdi=polygons (count, tag: 8 bytes each), rsi=loops, edx=count)
#   -> eax = their directed edges with no opposite one (0: closed)
polys_open:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    push    rbp
    sub     rsp, 8
    mov     r13, rdi
    mov     rbp, rsi
    mov     ebx, edx
    xor     eax, eax                    # loops in all
    xor     ecx, ecx
1:  cmp     ecx, ebx
    jae     2f
    add     eax, [r13+rcx*8]
    inc     ecx
    jmp     1b
2:  call    hpow
    mov     r14d, ecx
    lea     r15d, [rcx-1]
    push    rcx
    call    fa_mark
    mov     [rip+sh_fam], rax
    pop     rsi
    shl     rsi, 3
    push    rsi
    lea     rdi, [rip+frame_arena]
    call    arena_alloc
    pop     rcx
    test    rax, rax
    jz      8f
    mov     r12, rax
    mov     rdi, rax
    shr     ecx, 3
    xor     eax, eax
    rep     stosq
    xor     ecx, ecx                    # every directed edge in
    xor     r10d, r10d                  # (first loop of the polygon)
3:  cmp     ecx, ebx
    jae     5f
    mov     r9d, [r13+rcx*8]            # count
    xor     r8d, r8d
4:  cmp     r8d, r9d
    jae     49f
    lea     eax, [r10+r8]
    mov     eax, [rbp+rax*4]
    lea     edx, [r8+1]
    cmp     edx, r9d
    jb      41f
    xor     edx, edx
41: add     edx, r10d
    mov     edx, [rbp+rdx*4]
    shl     rax, 32
    or      rax, rdx
    inc     rax
    HSLOT   rax, r15, rdx
42: mov     r11, [r12+rdx*8]
    test    r11, r11
    jz      43f
    cmp     r11, rax
    je      44f
    inc     rdx
    and     rdx, r15
    jmp     42b
43: mov     [r12+rdx*8], rax
44: inc     r8d
    jmp     4b
49: add     r10d, r9d
    inc     ecx
    jmp     3b
5:  xor     ebx, ebx                    # those whose opposite is not
    xor     ecx, ecx
6:  cmp     ecx, r14d
    jae     7f
    mov     rax, [r12+rcx*8]
    test    rax, rax
    jz      69f
    dec     rax
    rol     rax, 32
    inc     rax
    HSLOT   rax, r15, rdx
61: mov     r11, [r12+rdx*8]
    test    r11, r11
    jz      62f
    cmp     r11, rax
    je      69f
    inc     rdx
    and     rdx, r15
    jmp     61b
62: inc     ebx
69: inc     ecx
    jmp     6b
7:  mov     rdi, [rip+sh_fam]
    call    fa_release
    mov     eax, ebx
    jmp     9f
8:  mov     eax, -1
9:  add     rsp, 8
    pop     rbp
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# -----------------------------------------------------------------------------
# sh_inside(xmm0, xmm1, xmm2 = a point, doubles) -> eax = 1 inside the
#   source: a ray's crossings, odd
# -----------------------------------------------------------------------------
sh_inside:
    push    rbx
    sub     rsp, 32
    movsd   [rsp], xmm0
    movsd   [rsp+8], xmm1
    movsd   [rsp+16], xmm2
    xor     ebx, ebx
    mov     rsi, [rip+sh_src_t]
    mov     rdi, [rip+sh_src_p]
    mov     ecx, [rip+sh_src_nt]
    test    ecx, ecx
    jz      9f
1:  mov     eax, [rsi]                  # Moller-Trumbore: e1 = b - a,
    imul    rax, rax, VX_SZ             #  e2 = c - a
    lea     r8, [rdi+rax]
    mov     eax, [rsi+4]
    imul    rax, rax, VX_SZ
    lea     r9, [rdi+rax]
    mov     eax, [rsi+8]
    imul    rax, rax, VX_SZ
    lea     r10, [rdi+rax]
    movsd   xmm3, [r9]
    subsd   xmm3, [r8]
    movsd   xmm4, [r9+8]
    subsd   xmm4, [r8+8]
    movsd   xmm5, [r9+16]
    subsd   xmm5, [r8+16]
    movsd   xmm6, [r10]
    subsd   xmm6, [r8]
    movsd   xmm7, [r10+8]
    subsd   xmm7, [r8+8]
    movsd   xmm8, [r10+16]
    subsd   xmm8, [r8+16]
    # p = dir x e2
    movsd   xmm9, [rip+sd_ray+8]
    mulsd   xmm9, xmm8
    movsd   xmm0, [rip+sd_ray+16]
    mulsd   xmm0, xmm7
    subsd   xmm9, xmm0                  # px
    movsd   xmm10, [rip+sd_ray+16]
    mulsd   xmm10, xmm6
    movsd   xmm0, [rip+sd_ray]
    mulsd   xmm0, xmm8
    subsd   xmm10, xmm0                 # py
    movsd   xmm11, [rip+sd_ray]
    mulsd   xmm11, xmm7
    movsd   xmm0, [rip+sd_ray+8]
    mulsd   xmm0, xmm6
    subsd   xmm11, xmm0                 # pz
    movsd   xmm12, xmm3                 # det = e1 . p
    mulsd   xmm12, xmm9
    movsd   xmm0, xmm4
    mulsd   xmm0, xmm10
    addsd   xmm12, xmm0
    movsd   xmm0, xmm5
    mulsd   xmm0, xmm11
    addsd   xmm12, xmm0
    movsd   xmm0, xmm12
    andpd   xmm0, [rip+sd_absmask]
    comisd  xmm0, [rip+sd_tiny]
    jbe     7f
    movsd   xmm13, [rsp]                # t = o - a
    subsd   xmm13, [r8]
    movsd   xmm14, [rsp+8]
    subsd   xmm14, [r8+8]
    movsd   xmm15, [rsp+16]
    subsd   xmm15, [r8+16]
    movsd   xmm0, xmm13                 # u = t . p / det
    mulsd   xmm0, xmm9
    movsd   xmm1, xmm14
    mulsd   xmm1, xmm10
    addsd   xmm0, xmm1
    movsd   xmm1, xmm15
    mulsd   xmm1, xmm11
    addsd   xmm0, xmm1
    divsd   xmm0, xmm12
    xorpd   xmm1, xmm1
    comisd  xmm0, xmm1
    jb      7f
    comisd  xmm0, [rip+sd_one]
    ja      7f
    movsd   xmm2, xmm0                  # (u)
    # q = t x e1
    movsd   xmm9, xmm14
    mulsd   xmm9, xmm5
    movsd   xmm0, xmm15
    mulsd   xmm0, xmm4
    subsd   xmm9, xmm0
    movsd   xmm10, xmm15
    mulsd   xmm10, xmm3
    movsd   xmm0, xmm13
    mulsd   xmm0, xmm5
    subsd   xmm10, xmm0
    movsd   xmm11, xmm13
    mulsd   xmm11, xmm4
    movsd   xmm0, xmm14
    mulsd   xmm0, xmm3
    subsd   xmm11, xmm0
    movsd   xmm0, [rip+sd_ray]          # v = dir . q / det
    mulsd   xmm0, xmm9
    movsd   xmm1, [rip+sd_ray+8]
    mulsd   xmm1, xmm10
    addsd   xmm0, xmm1
    movsd   xmm1, [rip+sd_ray+16]
    mulsd   xmm1, xmm11
    addsd   xmm0, xmm1
    divsd   xmm0, xmm12
    xorpd   xmm1, xmm1
    comisd  xmm0, xmm1
    jb      7f
    addsd   xmm0, xmm2
    comisd  xmm0, [rip+sd_one]
    ja      7f
    movsd   xmm0, xmm6                  # t = e2 . q / det
    mulsd   xmm0, xmm9
    movsd   xmm1, xmm7
    mulsd   xmm1, xmm10
    addsd   xmm0, xmm1
    movsd   xmm1, xmm8
    mulsd   xmm1, xmm11
    addsd   xmm0, xmm1
    divsd   xmm0, xmm12
    xorpd   xmm1, xmm1
    comisd  xmm0, xmm1
    jbe     7f
    inc     ebx
7:  add     rsi, TR_SZ
    dec     ecx
    jnz     1b
9:  mov     eax, ebx
    and     eax, 1
    add     rsp, 32
    pop     rbx
    ret

# -----------------------------------------------------------------------------
# clip_plane(rbx=cut, rsi=plane) - the cut's solid on the plane's inner side
#   (closed again: the hole filled with polygons tagged with the plane's)
# -----------------------------------------------------------------------------
clip_plane:
    push    rbp
    mov     rbp, rsp
    push    r12
    push    r13
    push    r14
    push    r15
    sub     rsp, CF_SZ
    and     rsp, -16
    mov     r15, rsp
    mov     [r15+CF_PL], rsi
    mov     eax, [rsi+PLN_TAG]
    mov     [r15+CF_TAG], eax
    mov     rax, [rbx+CX_V]
    mov     [r15+CF_VIN], rax
    mov     rax, [rbx+CX_P]
    mov     [r15+CF_PIN], rax
    mov     rax, [rbx+CX_L]
    mov     [r15+CF_LIN], rax
    mov     eax, [rbx+CX_NV]
    mov     [r15+CF_NVIN], eax
    mov     eax, [rbx+CX_NP]
    mov     [r15+CF_NPIN], eax
    test    eax, eax
    jz      .Lcp_done
    mov     esi, [r15+CF_NVIN]          # the sides
    shl     rsi, 3
    call    cx_alloc
    test    rax, rax
    jz      .Lcp_done
    mov     [r15+CF_S], rax
    mov     esi, [r15+CF_NVIN]
    call    cx_alloc
    test    rax, rax
    jz      .Lcp_done
    mov     [r15+CF_CL], rax
    mov     rsi, [r15+CF_PL]
    movsd   xmm4, [rsi]
    movsd   xmm5, [rsi+8]
    movsd   xmm6, [rsi+16]
    movsd   xmm7, [rsi+24]
    movsd   xmm8, [rip+sh_tol]
    xorpd   xmm9, xmm9
    subsd   xmm9, xmm8
    mov     r12, [r15+CF_VIN]
    mov     r13, [r15+CF_S]
    mov     r14, [r15+CF_CL]
    xor     ecx, ecx
    xor     r8d, r8d                    # in, out
    xor     r9d, r9d
1:  cmp     ecx, [r15+CF_NVIN]
    jae     2f
    imul    rax, rcx, VX_SZ
    movsd   xmm0, [r12+rax]
    mulsd   xmm0, xmm4
    movsd   xmm1, [r12+rax+8]
    mulsd   xmm1, xmm5
    addsd   xmm0, xmm1
    movsd   xmm1, [r12+rax+16]
    mulsd   xmm1, xmm6
    addsd   xmm0, xmm1
    subsd   xmm0, xmm7
    movsd   [r13+rcx*8], xmm0
    mov     edx, CL_OUT
    comisd  xmm0, xmm8
    ja      11f
    mov     edx, CL_IN
    comisd  xmm0, xmm9
    jb      12f
    mov     edx, CL_ON
    jmp     13f
11: inc     r9d
    jmp     13f
12: inc     r8d
13: mov     [r14+rcx], dl
    inc     ecx
    jmp     1b
2:  test    r9d, r9d                    # nothing out: as it is
    jz      .Lcp_done
    test    r8d, r8d                    # nothing in: nothing
    jnz     3f
    xor     eax, eax
    mov     [rbx+CX_NV], eax
    mov     [rbx+CX_NP], eax
    mov     [rbx+CX_NL], eax
    jmp     .Lcp_done
3:  xor     eax, eax                    # the polygons: kept, touching, cut
    mov     [r15+CF_NSTR], eax
    mov     [r15+CF_NTCH], eax
    mov     [r15+CF_NKEEP], eax
    mov     [r15+CF_LSUM], eax
    mov     [r15+CF_BSUM], eax
    mov     r13, [r15+CF_PIN]
    xor     r14d, r14d
4:  cmp     r14d, [r15+CF_NPIN]
    jae     5f
    call    poly_mask                   # eax: bit 0 in, 1 on, 2 out
    mov     ecx, [r13+PR_CNT]
    test    eax, 4
    jnz     41f
    inc     dword ptr [r15+CF_NKEEP]
    add     [r15+CF_LSUM], ecx
    test    eax, 2
    jz      42f
    inc     dword ptr [r15+CF_NTCH]
    add     [r15+CF_BSUM], ecx
    jmp     42f
41: test    eax, 1
    jz      42f
    inc     dword ptr [r15+CF_NSTR]
    lea     ecx, [rcx+2]
    add     [r15+CF_LSUM], ecx
    add     [r15+CF_BSUM], ecx
42: add     r13, PR_SZ
    inc     r14d
    jmp     4b
5:  mov     esi, [r15+CF_NVIN]          # room
    shl     rsi, 2
    call    cx_alloc
    test    rax, rax
    jz      .Lcp_done
    mov     [r15+CF_RM], rax
    mov     rdi, rax
    mov     ecx, [r15+CF_NVIN]
    mov     eax, -1
    rep     stosd
    mov     eax, [r15+CF_NSTR]
    add     eax, eax
    add     eax, [r15+CF_NVIN]
    add     eax, 8
    mov     r12d, eax
    imul    rsi, rax, VX_SZ
    call    cx_alloc
    test    rax, rax
    jz      .Lcp_done
    mov     [r15+CF_VO], rax
    mov     esi, r12d
    call    cx_alloc
    test    rax, rax
    jz      .Lcp_done
    mov     [r15+CF_ONP], rax
    mov     eax, [r15+CF_BSUM]          # polygons: the kept and cut ones +
    lea     eax, [rax+rax*2+16]         #  the cap's (a triangle an edge in
    mov     ecx, [r15+CF_NKEEP]         #  the plane and two a hole at most)
    add     ecx, [r15+CF_NSTR]
    add     eax, ecx
    mov     [r15+CF_CAPP], eax
    mov     rsi, rax
    shl     rsi, 4
    call    cx_alloc
    test    rax, rax
    jz      .Lcp_done
    mov     [r15+CF_PO], rax
    mov     eax, [r15+CF_BSUM]          # loops: theirs + 3 a cap triangle
    imul    eax, eax, 9
    add     eax, [r15+CF_LSUM]
    add     eax, 64
    mov     [r15+CF_CAPL], eax
    mov     rsi, rax
    shl     rsi, 2
    call    cx_alloc
    test    rax, rax
    jz      .Lcp_done
    mov     [r15+CF_LO], rax
    mov     eax, [r15+CF_NSTR]          # the cut edges' points
    add     eax, eax
    call    hpow
    lea     eax, [rcx-1]
    mov     [r15+CF_EM], eax
    mov     r12d, ecx
    mov     rsi, rcx
    shl     rsi, 3
    call    cx_alloc
    test    rax, rax
    jz      .Lcp_done
    mov     [r15+CF_EK], rax
    mov     rdi, rax
    mov     ecx, r12d
    xor     eax, eax
    rep     stosq
    mov     rsi, r12
    shl     rsi, 2
    call    cx_alloc
    test    rax, rax
    jz      .Lcp_done
    mov     [r15+CF_EV], rax
    xor     eax, eax
    mov     [r15+CF_NVO], eax
    mov     [r15+CF_NPO], eax
    mov     [r15+CF_NLO], eax
    mov     r13, [r15+CF_PIN]           # the polygons
    xor     r14d, r14d
6:  cmp     r14d, [r15+CF_NPIN]
    jae     .Lcp_cap
    call    poly_mask
    test    eax, 4
    jnz     62f
    mov     eax, [r15+CF_NLO]           # kept: its corners, anew
    mov     [r15+CF_SZ-8], eax          # (start)
    xor     r12d, r12d
61: cmp     r12d, [r13+PR_CNT]
    jae     68f
    mov     eax, [r13+PR_FIRST]
    add     eax, r12d
    mov     rcx, [r15+CF_LIN]
    mov     edi, [rcx+rax*4]
    call    cf_vert
    call    cf_put
    inc     r12d
    jmp     61b
62: test    eax, 1
    jz      69f
    mov     eax, [r15+CF_NLO]           # cut: Sutherland-Hodgman
    mov     [r15+CF_SZ-8], eax
    xor     r12d, r12d                  # (corner)
63: cmp     r12d, [r13+PR_CNT]
    jae     68f
    mov     eax, [r13+PR_FIRST]
    add     eax, r12d
    mov     rcx, [r15+CF_LIN]
    mov     edi, [rcx+rax*4]            # i
    lea     edx, [r12+1]
    cmp     edx, [r13+PR_CNT]
    jb      631f
    xor     edx, edx
631:add     edx, [r13+PR_FIRST]
    mov     esi, [rcx+rdx*4]            # j
    mov     rcx, [r15+CF_CL]
    movzx   r8d, byte ptr [rcx+rdi]
    movzx   r9d, byte ptr [rcx+rsi]
    cmp     r8d, CL_OUT
    je      64f
    push    rdi
    push    rsi
    push    r8
    push    r9
    call    cf_vert
    call    cf_put
    pop     r9
    pop     r8
    pop     rsi
    pop     rdi
64: mov     eax, r8d                    # an edge from in to out (or back)
    add     eax, r9d
    cmp     eax, CL_OUT
    jne     65f
    cmp     r8d, CL_ON
    je      65f
    call    cf_cut
    call    cf_put
65: inc     r12d
    jmp     63b
68: mov     eax, [r15+CF_NLO]           # the polygon (3 corners at least)
    mov     ecx, [r15+CF_SZ-8]
    sub     eax, ecx
    cmp     eax, 3
    jae     681f
    mov     [r15+CF_NLO], ecx
    jmp     69f
681:mov     edx, [r15+CF_NPO]
    cmp     edx, [r15+CF_CAPP]
    jae     69f
    inc     dword ptr [r15+CF_NPO]
    shl     rdx, 4
    add     rdx, [r15+CF_PO]
    mov     [rdx+PR_FIRST], ecx
    mov     [rdx+PR_CNT], eax
    mov     eax, [r13+PR_TAG]
    mov     [rdx+PR_TAG], eax
69: add     r13, PR_SZ
    inc     r14d
    jmp     6b
.Lcp_cap:
    mov     rax, [r15+CF_VO]            # the result, then its hole filled
    mov     [rbx+CX_V], rax
    mov     eax, [r15+CF_NVO]
    mov     [rbx+CX_NV], eax
    mov     rax, [r15+CF_PO]
    mov     [rbx+CX_P], rax
    mov     rax, [r15+CF_LO]
    mov     [rbx+CX_L], rax
    mov     rsi, r15
    call    cap_build
    mov     eax, [r15+CF_NPO]
    mov     [rbx+CX_NP], eax
    mov     eax, [r15+CF_NLO]
    mov     [rbx+CX_NL], eax
.Lcp_done:
    lea     rsp, [rbp-32]
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbp
    ret

# cf_put(eax=vertex; r15 = frame) - a loop of the polygon being made
cf_put:
    mov     ecx, [r15+CF_NLO]
    cmp     ecx, [r15+CF_CAPL]
    jae     1f
    mov     rdx, [r15+CF_LO]
    mov     [rdx+rcx*4], eax
    inc     dword ptr [r15+CF_NLO]
1:  ret

# poly_mask(r13=polygon, r15=frame) -> eax = its corners' sides (bits)
poly_mask:
    mov     rsi, [r15+CF_CL]
    mov     r10, [r15+CF_LIN]
    mov     r8d, [r13+PR_FIRST]
    mov     r9d, [r13+PR_CNT]
    add     r9d, r8d
    xor     eax, eax
1:  cmp     r8d, r9d
    jae     2f
    mov     edi, [r10+r8*4]
    movzx   ecx, byte ptr [rsi+rdi]
    mov     edx, 1
    shl     edx, cl
    or      eax, edx
    inc     r8d
    jmp     1b
2:  ret

# cf_vert(edi=old vertex) -> eax = its new index (made on first use)
cf_vert:
    mov     rcx, [r15+CF_RM]
    mov     eax, [rcx+rdi*4]
    cmp     eax, -1
    jne     9f
    mov     eax, [r15+CF_NVO]
    mov     [rcx+rdi*4], eax
    inc     dword ptr [r15+CF_NVO]
    mov     rcx, [r15+CF_VIN]
    imul    rdx, rdi, VX_SZ
    imul    r8, rax, VX_SZ
    add     r8, [r15+CF_VO]
    movsd   xmm0, [rcx+rdx]
    movsd   [r8], xmm0
    movsd   xmm0, [rcx+rdx+8]
    movsd   [r8+8], xmm0
    movsd   xmm0, [rcx+rdx+16]
    movsd   [r8+16], xmm0
    mov     rcx, [r15+CF_CL]
    movzx   edx, byte ptr [rcx+rdi]
    cmp     edx, CL_ON
    sete    dl
    mov     rcx, [r15+CF_ONP]
    mov     [rcx+rax], dl
9:  ret

# cf_cut(edi=vertex, esi=vertex: one in, one out) -> eax = the point between
#   (one for the edge, made from its ends in order)
cf_cut:
    push    r12
    push    r13
    cmp     edi, esi
    jbe     1f
    xchg    edi, esi
1:  mov     r12d, edi
    mov     r13d, esi
    mov     rax, r12
    shl     rax, 32
    or      rax, r13
    inc     rax
    mov     ecx, [r15+CF_EM]
    HSLOT   rax, rcx, rdx
    mov     r8, [r15+CF_EK]
2:  mov     r9, [r8+rdx*8]
    test    r9, r9
    jz      3f
    cmp     r9, rax
    je      4f
    inc     rdx
    and     rdx, rcx
    jmp     2b
4:  mov     r8, [r15+CF_EV]
    mov     eax, [r8+rdx*4]
    jmp     9f
3:  mov     [r8+rdx*8], rax
    mov     eax, [r15+CF_NVO]
    inc     dword ptr [r15+CF_NVO]
    mov     r8, [r15+CF_EV]
    mov     [r8+rdx*4], eax
    mov     rcx, [r15+CF_ONP]
    mov     byte ptr [rcx+rax], 1
    mov     rcx, [r15+CF_S]             # t = s_lo / (s_lo - s_hi)
    movsd   xmm0, [rcx+r12*8]
    movsd   xmm1, xmm0
    subsd   xmm1, [rcx+r13*8]
    divsd   xmm0, xmm1
    mov     rcx, [r15+CF_VIN]
    imul    rdx, r12, VX_SZ
    imul    r9, r13, VX_SZ
    imul    r8, rax, VX_SZ
    add     r8, [r15+CF_VO]
    xor     r10d, r10d
5:  movsd   xmm1, [rcx+r9]
    movsd   xmm2, [rcx+rdx]
    subsd   xmm1, xmm2
    mulsd   xmm1, xmm0
    addsd   xmm1, xmm2
    movsd   [r8+r10], xmm1
    add     rdx, 8
    add     r9, 8
    add     r10, 8
    cmp     r10, 24
    jb      5b
9:  pop     r13
    pop     r12
    ret

# -----------------------------------------------------------------------------
# cap_build(rbx=cut, rsi=clip frame) - the edges of the new triangles that
#   lie in the plane and have no twin, chained into loops and filled
# -----------------------------------------------------------------------------
cap_build:
    push    rbp
    mov     rbp, rsp
    push    r12
    push    r13
    push    r14
    push    r15
    sub     rsp, CB_SZ
    and     rsp, -16
    mov     r14, rsi                    # (the clip frame)
    mov     r15, rsp
    mov     [r15+CB_CF], r14
    mov     [r15+CB_CX], rbx
    xor     r12d, r12d                  # edges in the plane: how many
    mov     rsi, [r14+CF_PO]
    xor     ecx, ecx
1:  cmp     ecx, [r14+CF_NPO]
    jae     2f
    call    cb_count
    add     r12d, eax
    add     rsi, PR_SZ
    inc     ecx
    jmp     1b
2:  test    r12d, r12d
    jz      .Lcb_done
    mov     eax, r12d                   # all of them in a set (u << 32 | v)
    call    hpow
    lea     eax, [rcx-1]
    mov     [r15+CB_HM], eax
    mov     r13d, ecx
    mov     rsi, rcx
    shl     rsi, 3
    call    cx_alloc
    test    rax, rax
    jz      .Lcb_done
    mov     [r15+CB_HK], rax
    mov     rdi, rax
    mov     ecx, r13d
    xor     eax, eax
    rep     stosq
    mov     esi, r12d                   # (and a list)
    shl     rsi, 3
    call    cx_alloc
    test    rax, rax
    jz      .Lcb_done
    mov     [r15+CB_BE], rax
    mov     r13, rax
    mov     rsi, [r14+CF_PO]
    xor     ecx, ecx
3:  cmp     ecx, [r14+CF_NPO]
    jae     4f
    xor     r8d, r8d
31: cmp     r8d, [rsi+PR_CNT]
    jae     35f
    mov     r9, [r14+CF_LO]
    mov     eax, [rsi+PR_FIRST]
    add     eax, r8d
    mov     eax, [r9+rax*4]             # u
    lea     r10d, [r8+1]
    cmp     r10d, [rsi+PR_CNT]
    jb      32f
    xor     r10d, r10d
32: add     r10d, [rsi+PR_FIRST]
    mov     edx, [r9+r10*4]             # v
    mov     rdi, [r14+CF_ONP]
    cmp     byte ptr [rdi+rax], 0
    je      34f
    cmp     byte ptr [rdi+rdx], 0
    je      34f
    mov     [r13], eax
    mov     [r13+4], edx
    add     r13, 8
    shl     rax, 32
    or      rax, rdx
    inc     rax
    push    rcx
    push    rsi
    mov     ecx, [r15+CB_HM]
    HSLOT   rax, rcx, rdx
    mov     rdi, [r15+CB_HK]
33: mov     r10, [rdi+rdx*8]
    test    r10, r10
    jz      331f
    cmp     r10, rax
    je      332f
    inc     rdx
    and     rdx, rcx
    jmp     33b
331:mov     [rdi+rdx*8], rax
332:pop     rsi
    pop     rcx
34: inc     r8d
    jmp     31b
35: add     rsi, PR_SZ
    inc     ecx
    jmp     3b
4:  mov     r13, [r15+CB_BE]            # those with no twin, turned: the
    xor     ecx, ecx                    #  cap's edges (in place)
    xor     r8d, r8d
41: cmp     ecx, r12d
    jae     45f
    mov     eax, [r13+rcx*8+4]          # (v, u)
    mov     edx, [r13+rcx*8]
    mov     r9, rax
    shl     r9, 32
    or      r9, rdx
    inc     r9
    push    rcx
    mov     ecx, [r15+CB_HM]
    HSLOT   r9, rcx, r10
    mov     rdi, [r15+CB_HK]
42: mov     r11, [rdi+r10*8]
    test    r11, r11
    jz      43f
    cmp     r11, r9
    je      44f
    inc     r10
    and     r10, rcx
    jmp     42b
43: pop     rcx                         # no twin: (v, u) is the cap's
    mov     [r13+r8*8], eax
    mov     [r13+r8*8+4], edx
    inc     r8d
    jmp     46f
44: pop     rcx
46: inc     ecx
    jmp     41b
45: mov     [r15+CB_NB], r8d
    cmp     r8d, 3
    jb      .Lcb_done
    call    cb_loops
    test    eax, eax
    jz      .Lcb_done
    call    cb_fill
.Lcb_done:
    lea     rsp, [rbp-32]
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbp
    ret

# cb_count(rsi=polygon; r14 = clip frame) -> eax = its edges in the plane
cb_count:
    push    rcx
    mov     rdi, [r14+CF_ONP]
    mov     r9, [r14+CF_LO]
    mov     r8d, [rsi+PR_FIRST]
    mov     r10d, [rsi+PR_CNT]
    add     r10d, r8d
    xor     eax, eax
    mov     edx, [r9+r10*4-4]           # (the last corner: the first edge's)
    movzx   r11d, byte ptr [rdi+rdx]
1:  cmp     r8d, r10d
    jae     2f
    mov     edx, [r9+r8*4]
    movzx   ecx, byte ptr [rdi+rdx]
    and     r11d, ecx
    add     eax, r11d
    mov     r11d, ecx
    inc     r8d
    jmp     1b
2:  pop     rcx
    ret

# cb_loops(r15=cap frame, r14=clip frame) -> eax = 1: the edges chained
#   into rings, their points in the plane, each loop's area
cb_loops:
    push    r12
    push    r13
    mov     eax, [r15+CB_NB]            # from-vertex hash
    call    hpow
    lea     eax, [rcx-1]
    mov     [r15+CB_HM], eax
    mov     r12d, ecx
    mov     rsi, rcx
    shl     rsi, 2
    call    cx_alloc
    test    rax, rax
    jz      8f
    mov     [r15+CB_HK], rax
    mov     rdi, rax
    mov     ecx, r12d
    xor     eax, eax
    rep     stosd
    mov     rsi, r12
    shl     rsi, 2
    call    cx_alloc
    test    rax, rax
    jz      8f
    mov     [r15+CB_HV], rax
    mov     esi, [r15+CB_NB]
    shl     rsi, 2
    call    cx_alloc
    test    rax, rax
    jz      8f
    mov     [r15+CB_ENX], rax
    mov     esi, [r15+CB_NB]
    call    cx_alloc
    test    rax, rax
    jz      8f
    mov     [r15+CB_USED], rax
    mov     rdi, rax
    mov     ecx, [r15+CB_NB]
    xor     eax, eax
    rep     stosb
    mov     eax, [r15+CB_NB]            # rings: an entry an edge, two more
    imul    r12d, eax, 3                #  a bridge
    add     r12d, 16
    mov     esi, r12d
    shl     rsi, 2
    call    cx_alloc
    test    rax, rax
    jz      8f
    mov     [r15+CB_RID], rax
    mov     esi, r12d
    shl     rsi, 3
    call    cx_alloc
    test    rax, rax
    jz      8f
    mov     [r15+CB_RX], rax
    mov     esi, r12d
    shl     rsi, 3
    call    cx_alloc
    test    rax, rax
    jz      8f
    mov     [r15+CB_RY], rax
    mov     esi, r12d
    shl     rsi, 2
    call    cx_alloc
    test    rax, rax
    jz      8f
    mov     [r15+CB_NXT], rax
    mov     esi, r12d
    shl     rsi, 2
    call    cx_alloc
    test    rax, rax
    jz      8f
    mov     [r15+CB_PRV], rax
    mov     esi, r12d
    shl     rsi, 2
    call    cx_alloc
    test    rax, rax
    jz      8f
    mov     [r15+CB_MARK], rax
    mov     eax, [r15+CB_NB]            # loops: a third of the edges at most
    xor     edx, edx
    mov     ecx, 3
    div     ecx
    lea     r12d, [rax+2]
    mov     esi, r12d
    shl     rsi, 2
    call    cx_alloc
    test    rax, rax
    jz      8f
    mov     [r15+CB_LST], rax
    mov     esi, r12d
    shl     rsi, 2
    call    cx_alloc
    test    rax, rax
    jz      8f
    mov     [r15+CB_LCN], rax
    mov     esi, r12d
    shl     rsi, 3
    call    cx_alloc
    test    rax, rax
    jz      8f
    mov     [r15+CB_LAR], rax
    mov     esi, r12d
    shl     rsi, 2
    call    cx_alloc
    test    rax, rax
    jz      8f
    mov     [r15+CB_LOUT], rax
    mov     esi, r12d
    shl     rsi, 2
    call    cx_alloc
    test    rax, rax
    jz      8f
    mov     [r15+CB_LMX], rax
    mov     r13d, r12d                  # (room for loops)
    mov     rsi, [r15+CB_BE]            # the hash: from -> first edge
    mov     r8, [r15+CB_HK]
    mov     r9, [r15+CB_HV]
    mov     r10, [r15+CB_ENX]
    mov     ecx, [r15+CB_HM]
    xor     r11d, r11d
1:  cmp     r11d, [r15+CB_NB]
    jae     2f
    mov     eax, [rsi+r11*8]
    inc     eax
    HSLOT   rax, rcx, rdx
11: mov     edi, [r8+rdx*4]
    test    edi, edi
    jz      12f
    cmp     edi, eax
    je      13f
    inc     rdx
    and     rdx, rcx
    jmp     11b
12: mov     [r8+rdx*4], eax
    mov     dword ptr [r10+r11*4], -1
    mov     [r9+rdx*4], r11d
    jmp     14f
13: mov     edi, [r9+rdx*4]
    mov     [r10+r11*4], edi
    mov     [r9+rdx*4], r11d
14: inc     r11d
    jmp     1b
2:  call    cb_axes
    xor     eax, eax
    mov     [r15+CB_NR], eax
    mov     [r15+CB_NL], eax
    xor     r12d, r12d                  # each unused edge starts a loop
3:  cmp     r12d, [r15+CB_NB]
    jae     7f
    mov     rax, [r15+CB_USED]
    cmp     byte ptr [rax+r12], 0
    jne     69f
    mov     eax, [r15+CB_NL]
    cmp     eax, r13d
    jae     7f
    mov     ecx, [r15+CB_NR]            # its first entry
    mov     rdx, [r15+CB_LST]
    mov     [rdx+rax*4], ecx
    mov     rsi, [r15+CB_BE]
    mov     r9d, [rsi+r12*8]            # (the start vertex)
    mov     r10d, r12d                  # the edge
4:  mov     rax, [r15+CB_USED]
    mov     byte ptr [rax+r10], 1
    mov     eax, [r15+CB_NR]            # an entry: its from-vertex
    inc     dword ptr [r15+CB_NR]
    mov     ecx, [rsi+r10*8]
    mov     rdx, [r15+CB_RID]
    mov     [rdx+rax*4], ecx
    mov     ecx, [rsi+r10*8+4]          # the next edge from its to-vertex
    cmp     ecx, r9d
    je      6f
    lea     eax, [rcx+1]
    push    r9
    mov     r9d, [r15+CB_HM]
    HSLOT   rax, r9, rdx
    pop     r9
    mov     r8, [r15+CB_HK]
5:  mov     edi, [r8+rdx*4]
    test    edi, edi
    jz      6f
    cmp     edi, eax
    je      51f
    inc     rdx
    mov     edi, [r15+CB_HM]
    and     rdx, rdi
    jmp     5b
51: mov     r8, [r15+CB_HV]
    mov     r10d, [r8+rdx*4]
    mov     r8, [r15+CB_ENX]
    mov     rdi, [r15+CB_USED]
52: cmp     r10d, -1
    je      6f
    cmp     byte ptr [rdi+r10], 0
    je      4b
    mov     r10d, [r8+r10*4]
    jmp     52b
6:  mov     eax, [r15+CB_NL]            # the loop's count, ring links
    mov     rdx, [r15+CB_LST]
    mov     ecx, [rdx+rax*4]
    mov     edx, [r15+CB_NR]
    sub     edx, ecx
    cmp     edx, 3
    jae     61f
    mov     [r15+CB_NR], ecx            # (fewer than 3: nothing to fill)
    jmp     69f
61: mov     rdi, [r15+CB_LCN]
    mov     [rdi+rax*4], edx
    inc     dword ptr [r15+CB_NL]
    mov     r8, [r15+CB_NXT]
    mov     r9, [r15+CB_PRV]
    mov     r10d, ecx                   # entries ecx .. ecx+edx-1
    lea     r11d, [rcx+rdx-1]
62: cmp     r10d, r11d
    ja      63f
    lea     eax, [r10+1]
    cmp     r10d, r11d
    jne     621f
    mov     eax, ecx
621:mov     [r8+r10*4], eax
    mov     [r9+rax*4], r10d
    inc     r10d
    jmp     62b
63: mov     r10d, ecx                   # their places in the plane
64: cmp     r10d, r11d
    ja      69f
    mov     rax, [r15+CB_RID]
    mov     eax, [rax+r10*4]
    imul    rax, rax, VX_SZ
    add     rax, [r14+CF_VO]
    movsd   xmm0, [rax]
    mulsd   xmm0, [r15+CB_U]
    movsd   xmm1, [rax+8]
    mulsd   xmm1, [r15+CB_U+8]
    addsd   xmm0, xmm1
    movsd   xmm1, [rax+16]
    mulsd   xmm1, [r15+CB_U+16]
    addsd   xmm0, xmm1
    mov     rdx, [r15+CB_RX]
    movsd   [rdx+r10*8], xmm0
    movsd   xmm0, [rax]
    mulsd   xmm0, [r15+CB_W]
    movsd   xmm1, [rax+8]
    mulsd   xmm1, [r15+CB_W+8]
    addsd   xmm0, xmm1
    movsd   xmm1, [rax+16]
    mulsd   xmm1, [r15+CB_W+16]
    addsd   xmm0, xmm1
    mov     rdx, [r15+CB_RY]
    movsd   [rdx+r10*8], xmm0
    mov     rdx, [r15+CB_MARK]
    mov     dword ptr [rdx+r10*4], 0
    inc     r10d
    jmp     64b
69: inc     r12d
    jmp     3b
7:  xor     r12d, r12d                  # each loop's area, largest x
71: cmp     r12d, [r15+CB_NL]
    jae     79f
    mov     edi, r12d
    call    cb_area
    mov     rax, [r15+CB_LAR]
    movsd   [rax+r12*8], xmm0
    mov     rax, [r15+CB_LMX]
    mov     [rax+r12*4], edx
    mov     rax, [r15+CB_LOUT]
    mov     dword ptr [rax+r12*4], -1
    inc     r12d
    jmp     71b
79: mov     eax, 1
    jmp     9f
8:  xor     eax, eax
9:  pop     r13
    pop     r12
    ret

# cb_axes - u, w in the plane with u x w = n
cb_axes:
    mov     rax, [r14+CF_PL]
    movsd   xmm0, [rax]                 # a = x unless n is near it, then y
    andpd   xmm0, [rip+sd_absmask]
    xorpd   xmm3, xmm3
    xorpd   xmm4, xmm4
    xorpd   xmm5, xmm5
    comisd  xmm0, [rip+sd_06]
    jae     1f
    movsd   xmm3, [rip+sd_one]
    jmp     2f
1:  movsd   xmm4, [rip+sd_one]
2:  movsd   xmm0, [rax]                 # u = a - n (n.a)
    mulsd   xmm0, xmm3
    movsd   xmm1, [rax+8]
    mulsd   xmm1, xmm4
    addsd   xmm0, xmm1
    movsd   xmm1, [rax]
    mulsd   xmm1, xmm0
    subsd   xmm3, xmm1
    movsd   xmm1, [rax+8]
    mulsd   xmm1, xmm0
    subsd   xmm4, xmm1
    movsd   xmm1, [rax+16]
    mulsd   xmm1, xmm0
    subsd   xmm5, xmm1
    movsd   xmm0, xmm3
    mulsd   xmm0, xmm3
    movsd   xmm1, xmm4
    mulsd   xmm1, xmm4
    addsd   xmm0, xmm1
    movsd   xmm1, xmm5
    mulsd   xmm1, xmm5
    addsd   xmm0, xmm1
    sqrtsd  xmm0, xmm0
    movsd   xmm1, [rip+sd_one]
    divsd   xmm1, xmm0
    mulsd   xmm3, xmm1
    mulsd   xmm4, xmm1
    mulsd   xmm5, xmm1
    movsd   [r15+CB_U], xmm3
    movsd   [r15+CB_U+8], xmm4
    movsd   [r15+CB_U+16], xmm5
    movsd   xmm0, [rax+8]               # w = n x u
    mulsd   xmm0, xmm5
    movsd   xmm1, [rax+16]
    mulsd   xmm1, xmm4
    subsd   xmm0, xmm1
    movsd   [r15+CB_W], xmm0
    movsd   xmm0, [rax+16]
    mulsd   xmm0, xmm3
    movsd   xmm1, [rax]
    mulsd   xmm1, xmm5
    subsd   xmm0, xmm1
    movsd   [r15+CB_W+8], xmm0
    movsd   xmm0, [rax]
    mulsd   xmm0, xmm4
    movsd   xmm1, [rax+8]
    mulsd   xmm1, xmm3
    subsd   xmm0, xmm1
    movsd   [r15+CB_W+16], xmm0
    ret

# cb_area(edi=loop) -> xmm0 = its area (counter-clockwise: positive), edx =
#   its entry with the largest x
cb_area:
    mov     rax, [r15+CB_LST]
    mov     ecx, [rax+rdi*4]            # first
    mov     r8d, ecx
    mov     r9, [r15+CB_RX]
    mov     r10, [r15+CB_RY]
    mov     r11, [r15+CB_NXT]
    xorpd   xmm0, xmm0
    mov     edx, ecx
    movsd   xmm2, [r9+rcx*8]
1:  mov     esi, [r11+rcx*4]
    movsd   xmm1, [r9+rcx*8]            # x_i y_j - x_j y_i
    mulsd   xmm1, [r10+rsi*8]
    movsd   xmm3, [r9+rsi*8]
    mulsd   xmm3, [r10+rcx*8]
    subsd   xmm1, xmm3
    addsd   xmm0, xmm1
    movsd   xmm1, [r9+rcx*8]
    comisd  xmm1, xmm2
    jbe     2f
    movsd   xmm2, xmm1
    mov     edx, ecx
2:  mov     ecx, esi
    cmp     ecx, r8d
    jne     1b
    mulsd   xmm0, [rip+sd_half]
    ret

# cb_fill(r15=cap frame, r14=clip frame) - the loops into triangles: holes
#   into the smallest outer loop around them, then ear clipping
cb_fill:
    push    r12
    push    r13
    sub     rsp, 8
    xor     r12d, r12d                  # each hole: its outer loop
1:  cmp     r12d, [r15+CB_NL]
    jae     2f
    mov     rax, [r15+CB_LAR]
    movsd   xmm0, [rax+r12*8]
    xorpd   xmm1, xmm1
    comisd  xmm0, xmm1
    jae     19f
    mov     edi, r12d
    call    cb_outer_of
    mov     rcx, [r15+CB_LOUT]
    mov     [rcx+r12*4], eax
19: inc     r12d
    jmp     1b
2:  xor     r12d, r12d                  # each outer loop: its holes in, by
3:  cmp     r12d, [r15+CB_NL]           #  their largest x, then clipped
    jae     7f
    mov     rax, [r15+CB_LAR]
    movsd   xmm0, [rax+r12*8]
    xorpd   xmm1, xmm1
    comisd  xmm0, xmm1
    jae     4f
    mov     rcx, [r15+CB_LOUT]          # a hole with no outer loop: alone
    cmp     dword ptr [rcx+r12*4], -1
    jne     69f
    mov     dword ptr [r15+CB_NBR], 1
    jmp     6f
4:  mov     dword ptr [r15+CB_NBR], 0
41: mov     edi, r12d                   # the next hole of it: the largest x
    call    cb_next_hole
    test    eax, eax
    js      6f
    mov     r13d, eax
    mov     rcx, [r15+CB_LOUT]          # (bridged: no longer a hole)
    mov     dword ptr [rcx+r13*4], -2
    mov     edi, r12d
    mov     esi, r13d
    call    cb_bridge
    inc     dword ptr [r15+CB_NBR]
    jmp     41b
6:  mov     rax, [r15+CB_LST]
    mov     edi, [rax+r12*4]
    call    cb_clip
69: inc     r12d
    jmp     3b
7:  add     rsp, 8
    pop     r13
    pop     r12
    ret

# cb_outer_of(edi=hole) -> eax = the smallest outer loop around its point
#   with the largest x (else the largest outer loop; -1: none)
cb_outer_of:
    push    r12
    push    r13
    push    r14
    sub     rsp, 48                     # +0 area, +8 best's, +16 the largest
    mov     rax, [r15+CB_LMX]           #  area, +24 x, +32 y
    mov     eax, [rax+rdi*4]
    mov     rcx, [r15+CB_RX]
    movsd   xmm0, [rcx+rax*8]
    movsd   [rsp+24], xmm0
    mov     rcx, [r15+CB_RY]
    movsd   xmm0, [rcx+rax*8]
    movsd   [rsp+32], xmm0
    mov     r12d, -1                    # best
    mov     r14d, -1                    # the largest
    movsd   xmm0, [rip+sd_big]
    movsd   [rsp+8], xmm0
    xorpd   xmm0, xmm0
    movsd   [rsp+16], xmm0
    xor     r13d, r13d
1:  cmp     r13d, [r15+CB_NL]
    jae     8f
    mov     rax, [r15+CB_LAR]
    movsd   xmm0, [rax+r13*8]
    xorpd   xmm1, xmm1
    comisd  xmm0, xmm1
    jb      7f
    movsd   [rsp], xmm0
    comisd  xmm0, [rsp+16]
    jbe     2f
    movsd   [rsp+16], xmm0
    mov     r14d, r13d
2:  movsd   xmm0, [rsp]
    comisd  xmm0, [rsp+8]
    jae     7f
    mov     edi, r13d
    movsd   xmm0, [rsp+24]
    movsd   xmm1, [rsp+32]
    call    cb_pip
    test    eax, eax
    jz      7f
    movsd   xmm0, [rsp]
    movsd   [rsp+8], xmm0
    mov     r12d, r13d
7:  inc     r13d
    jmp     1b
8:  mov     eax, r12d
    cmp     eax, -1
    jne     9f
    mov     eax, r14d
9:  add     rsp, 48
    pop     r14
    pop     r13
    pop     r12
    ret

# cb_pip(edi=loop, xmm0, xmm1 = a point) -> eax = 1 inside it (crossings
#   of a ray along +x)
cb_pip:
    mov     rax, [r15+CB_LST]
    mov     ecx, [rax+rdi*4]
    mov     r8d, ecx
    mov     r9, [r15+CB_RX]
    mov     r10, [r15+CB_RY]
    mov     r11, [r15+CB_NXT]
    xor     eax, eax
1:  mov     esi, [r11+rcx*4]
    movsd   xmm2, [r10+rcx*8]           # yi > y != yj > y
    movsd   xmm3, [r10+rsi*8]
    xor     edx, edx
    comisd  xmm2, xmm1
    seta    dl
    xor     edi, edi
    comisd  xmm3, xmm1
    seta    dil
    cmp     edx, edi
    je      2f
    movsd   xmm4, xmm1                  # x at y: xi + (y - yi)(xj - xi)/(yj - yi)
    subsd   xmm4, xmm2
    movsd   xmm5, [r9+rsi*8]
    subsd   xmm5, [r9+rcx*8]
    mulsd   xmm4, xmm5
    subsd   xmm3, xmm2
    divsd   xmm4, xmm3
    addsd   xmm4, [r9+rcx*8]
    comisd  xmm4, xmm0
    jbe     2f
    xor     eax, 1
2:  mov     ecx, esi
    cmp     ecx, r8d
    jne     1b
    ret

# cb_next_hole(edi=outer loop) -> eax = its unbridged hole with the largest
#   x, or -1
cb_next_hole:
    mov     eax, -1
    movsd   xmm1, [rip+sd_big]
    xorpd   xmm0, xmm0
    subsd   xmm0, xmm1                  # (-big)
    xor     ecx, ecx
    mov     r8, [r15+CB_LOUT]
    mov     r9, [r15+CB_LMX]
    mov     r10, [r15+CB_RX]
1:  cmp     ecx, [r15+CB_NL]
    jae     9f
    cmp     [r8+rcx*4], edi
    jne     2f
    mov     edx, [r9+rcx*4]
    movsd   xmm1, [r10+rdx*8]
    comisd  xmm1, xmm0
    jbe     2f
    movsd   xmm0, xmm1
    mov     eax, ecx
2:  inc     ecx
    jmp     1b
9:  ret

# cb_bridge(edi=outer loop, esi=hole) - the hole joined to the outer ring by
#   two edges between its point with the largest x and the nearest point of
#   the ring that sees it
cb_bridge:
    push    rbx
    push    r12
    push    r13
    push    r14
    sub     rsp, 40
    mov     r12d, edi
    mov     rax, [r15+CB_LMX]
    mov     r13d, [rax+rsi*4]           # M
    mov     [rsp+32], esi
    mov     rax, [r15+CB_RX]
    movsd   xmm6, [rax+r13*8]
    mov     rax, [r15+CB_RY]
    movsd   xmm7, [rax+r13*8]
    movsd   [rsp], xmm6
    movsd   [rsp+8], xmm7
    mov     rax, [r15+CB_LST]           # the outer ring's entries: unmarked
    mov     ebx, [rax+r12*4]
    mov     ecx, ebx
    mov     rdx, [r15+CB_MARK]
    mov     r8, [r15+CB_NXT]
1:  mov     dword ptr [rdx+rcx*4], 0
    mov     ecx, [r8+rcx*4]
    cmp     ecx, ebx
    jne     1b
    mov     r14d, -1                    # the nearest one found (any)
2:  mov     ecx, ebx                    # the nearest unmarked one
    mov     r9d, -1
    movsd   xmm5, [rip+sd_big]
3:  mov     rdx, [r15+CB_MARK]
    cmp     dword ptr [rdx+rcx*4], 0
    jne     4f
    mov     rax, [r15+CB_RX]
    movsd   xmm0, [rax+rcx*8]
    subsd   xmm0, [rsp]
    mulsd   xmm0, xmm0
    mov     rax, [r15+CB_RY]
    movsd   xmm1, [rax+rcx*8]
    subsd   xmm1, [rsp+8]
    mulsd   xmm1, xmm1
    addsd   xmm0, xmm1
    comisd  xmm0, xmm5
    jae     4f
    movsd   xmm5, xmm0
    mov     r9d, ecx
4:  mov     rax, [r15+CB_NXT]
    mov     ecx, [rax+rcx*4]
    cmp     ecx, ebx
    jne     3b
    cmp     r9d, -1
    je      6f
    cmp     r14d, -1
    jne     41f
    mov     r14d, r9d
41: mov     rdx, [r15+CB_MARK]
    mov     dword ptr [rdx+r9*4], 1
    mov     [rsp+16], r9d
    mov     edi, r9d                    # seen from M?
    mov     esi, r13d
    mov     edx, r12d
    mov     ecx, [rsp+32]
    call    cb_sees
    mov     r9d, [rsp+16]
    test    eax, eax
    jz      2b
    mov     r14d, r9d
6:  cmp     r14d, -1
    je      9f
    mov     ecx, [r15+CB_NR]            # splice: a = P, b = M; a2, b2 new
    lea     eax, [rcx+2]
    mov     [r15+CB_NR], eax
    mov     r8d, ecx                    # a2
    lea     r9d, [rcx+1]                # b2
    mov     edi, r14d
    mov     esi, r8d
    call    cb_dup
    mov     edi, r13d
    mov     esi, r9d
    call    cb_dup
    mov     r10, [r15+CB_NXT]
    mov     r11, [r15+CB_PRV]
    mov     eax, [r10+r14*4]            # an = a.next
    mov     edx, [r11+r13*4]            # bp = b.prev
    mov     [r10+r14*4], r13d           # a.next = b, b.prev = a
    mov     [r11+r13*4], r14d
    mov     [r10+r8*4], eax             # a2.next = an, an.prev = a2
    mov     [r11+rax*4], r8d
    mov     [r10+r9*4], r8d             # b2.next = a2, a2.prev = b2
    mov     [r11+r8*4], r9d
    mov     [r10+rdx*4], r9d            # bp.next = b2, b2.prev = bp
    mov     [r11+r9*4], edx
9:  add     rsp, 40
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# cb_dup(edi=entry, esi=new entry) - a copy of it
cb_dup:
    mov     rax, [r15+CB_RID]
    mov     edx, [rax+rdi*4]
    mov     [rax+rsi*4], edx
    mov     rax, [r15+CB_RX]
    movsd   xmm0, [rax+rdi*8]
    movsd   [rax+rsi*8], xmm0
    mov     rax, [r15+CB_RY]
    movsd   xmm0, [rax+rdi*8]
    movsd   [rax+rsi*8], xmm0
    mov     rax, [r15+CB_MARK]
    mov     dword ptr [rax+rsi*4], 1
    ret

# cb_sees(edi=P, esi=M, edx=outer loop, ecx=hole) -> eax = 1 when the
#   segment P M crosses no edge of the outer ring nor of the holes still
#   to bridge into it
cb_sees:
    push    rbx
    push    r12
    push    r13
    push    r14
    sub     rsp, 56
    mov     r12d, edi
    mov     r13d, esi
    mov     [rsp+40], edx
    mov     [rsp+48], ecx
    mov     rax, [r15+CB_LST]           # the outer ring (with the holes
    mov     edi, [rax+rdx*4]            #  bridged so far)
    call    cb_ring_hits
    test    eax, eax
    jnz     8f
    xor     r14d, r14d                  # this hole, those still to bridge
1:  cmp     r14d, [r15+CB_NL]
    jae     7f
    cmp     r14d, [rsp+48]
    je      2f
    mov     rax, [r15+CB_LOUT]
    mov     ecx, [rax+r14*4]
    cmp     ecx, [rsp+40]
    jne     3f
2:  mov     rax, [r15+CB_LST]
    mov     edi, [rax+r14*4]
    call    cb_ring_hits
    test    eax, eax
    jnz     8f
3:  inc     r14d
    jmp     1b
7:  mov     eax, 1
    jmp     9f
8:  xor     eax, eax
9:  add     rsp, 56
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# cb_ring_hits(edi=an entry; r12d = P, r13d = M) -> eax = 1 when an edge of
#   its ring crosses P M (edges at either's place don't count)
cb_ring_hits:
    push    rbx
    mov     ebx, edi
    mov     ecx, edi
    mov     r8, [r15+CB_RX]
    mov     r9, [r15+CB_RY]
    mov     r10, [r15+CB_NXT]
1:  mov     edx, [r10+rcx*4]
    mov     edi, ecx                    # (a, b) = (ecx, edx)
    mov     esi, r12d
    call    cb_same
    jz      5f
    mov     esi, r13d
    call    cb_same
    jz      5f
    mov     edi, edx
    mov     esi, r12d
    call    cb_same
    jz      5f
    mov     esi, r13d
    call    cb_same
    jz      5f
    movsd   xmm0, [r8+r12*8]            # o1 = orient(P, M, a), o2 = (P, M, b)
    movsd   xmm1, [r9+r12*8]
    movsd   xmm2, [r8+r13*8]
    movsd   xmm3, [r9+r13*8]
    movsd   xmm4, [r8+rcx*8]
    movsd   xmm5, [r9+rcx*8]
    call    orient2
    movsd   xmm8, xmm6
    movsd   xmm4, [r8+rdx*8]
    movsd   xmm5, [r9+rdx*8]
    call    orient2
    mulsd   xmm8, xmm6
    xorpd   xmm7, xmm7
    comisd  xmm8, xmm7
    jae     5f
    movsd   xmm0, [r8+rcx*8]            # o3 = (a, b, P), o4 = (a, b, M)
    movsd   xmm1, [r9+rcx*8]
    movsd   xmm2, [r8+rdx*8]
    movsd   xmm3, [r9+rdx*8]
    movsd   xmm4, [r8+r12*8]
    movsd   xmm5, [r9+r12*8]
    call    orient2
    movsd   xmm8, xmm6
    movsd   xmm4, [r8+r13*8]
    movsd   xmm5, [r9+r13*8]
    call    orient2
    mulsd   xmm8, xmm6
    comisd  xmm8, xmm7
    jae     5f
    mov     eax, 1
    pop     rbx
    ret
5:  mov     ecx, edx
    cmp     ecx, ebx
    jne     1b
    xor     eax, eax
    pop     rbx
    ret

# cb_same(edi, esi = entries) -> ZF set when at the same place
cb_same:
    movsd   xmm0, [r8+rdi*8]
    ucomisd xmm0, [r8+rsi*8]
    jne     1f
    jp      1f
    movsd   xmm0, [r9+rdi*8]
    ucomisd xmm0, [r9+rsi*8]
    jne     1f
    jp      1f
    cmp     eax, eax                    # (ZF)
    ret
1:  test    esp, esp                    # (ZF clear: rsp is never 0)
    ret

# orient2f(xmm0,1 = a; xmm2,3 = b; xmm4,5 = c) -> xmm6 = (b - a) x (c - a),
#   eax = 1 when the corner is straight (its sine under 1e-10)
orient2f:
    call    orient2
    movsd   xmm9, xmm2                  # |b - a|^2 |c - b|^2 1e-20 >= o^2
    subsd   xmm9, xmm0
    mulsd   xmm9, xmm9
    movsd   xmm10, xmm3
    subsd   xmm10, xmm1
    mulsd   xmm10, xmm10
    addsd   xmm9, xmm10
    movsd   xmm10, xmm4
    subsd   xmm10, xmm2
    mulsd   xmm10, xmm10
    movsd   xmm11, xmm5
    subsd   xmm11, xmm3
    mulsd   xmm11, xmm11
    addsd   xmm10, xmm11
    mulsd   xmm9, xmm10
    mulsd   xmm9, [rip+sd_flat]
    movsd   xmm10, xmm6
    mulsd   xmm10, xmm10
    xor     eax, eax
    comisd  xmm10, xmm9
    setbe   al
    ret

# orient2(xmm0,1 = a; xmm2,3 = b; xmm4,5 = c) -> xmm6 = (b - a) x (c - a)
orient2:
    movsd   xmm6, xmm2
    subsd   xmm6, xmm0
    movsd   xmm9, xmm5
    subsd   xmm9, xmm1
    mulsd   xmm6, xmm9
    movsd   xmm9, xmm3
    subsd   xmm9, xmm1
    movsd   xmm10, xmm4
    subsd   xmm10, xmm0
    mulsd   xmm9, xmm10
    subsd   xmm6, xmm9
    ret

# cb_clip(edi=an entry) - its ring cut into triangles (ear clipping: a
#   corner that turns left with no reflex corner in its triangle; with no
#   ear left, the next corner anyway)
cb_clip:
    push    rbx
    push    r12
    push    r13
    push    r14
    sub     rsp, 8
    mov     ebx, edi                    # the current corner
    xor     r12d, r12d                  # how many, which are reflex
    mov     dword ptr [r15+CB_NREF], 0
    mov     r13d, edi
1:  inc     r12d
    mov     edi, r13d
    call    cb_reflex
    mov     rdx, [r15+CB_MARK]
    mov     [rdx+r13*4], eax
    add     [r15+CB_NREF], eax
    mov     r10, [r15+CB_NXT]
    mov     r13d, [r10+r13*4]
    cmp     r13d, ebx
    jne     1b
    cmp     dword ptr [r15+CB_NREF], 0  # convex (and no holes): one polygon
    jne     11f
    cmp     dword ptr [r15+CB_NBR], 0
    jne     11f
    mov     edi, ebx
    call    cb_emit_ring
    jmp     9f
11: mov     eax, [r14+CF_NPO]           # (the triangles from here: merged
    mov     [r15+CB_T0], eax            #  into convex polygons after)
    mov     eax, [r14+CF_NLO]
    mov     [r15+CB_L0], eax
    mov     edi, ebx                    # (the grid of reflex corners)
    call    cb_grid
    xor     r13d, r13d                  # corners tried since the last ear
2:  cmp     r12d, 3
    jbe     8f
    mov     edi, ebx
    call    cb_is_ear
    test    eax, eax
    jnz     3f
    inc     r13d
    cmp     r13d, r12d
    jbe     4f
3:  mov     edi, ebx                    # an ear (or forced)
    call    cb_emit
    mov     r10, [r15+CB_NXT]
    mov     r11, [r15+CB_PRV]
    mov     eax, [r11+rbx*4]
    mov     ecx, [r10+rbx*4]
    mov     [r10+rax*4], ecx
    mov     [r11+rcx*4], eax
    mov     rdx, [r15+CB_MARK]          # (it no longer counts)
    mov     r8d, [rdx+rbx*4]
    sub     [r15+CB_NREF], r8d
    mov     dword ptr [rdx+rbx*4], 0
    mov     ebx, ecx
    mov     edi, eax                    # its neighbours turn anew
    call    cb_reflag
    mov     edi, ebx
    call    cb_reflag
    dec     r12d
    xor     r13d, r13d
    jmp     2b
4:  mov     r10, [r15+CB_NXT]
    mov     ebx, [r10+rbx*4]
    jmp     2b
8:  cmp     r12d, 3
    jne     81f
    mov     edi, ebx
    call    cb_emit
81: call    cb_merge
9:  add     rsp, 8
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# cb_merge - the ring's triangles (from CB_T0) joined into convex polygons:
#   each one grows over a neighbour across one of its edges while it stays
#   convex (Hertel-Mehlhorn, greedily)
.equ MG_SV,     0                       # slots: vertex,
.equ MG_SN,     8                       #  next
.equ MG_TS,     16                      # each triangle: its first slot (-1:
.equ MG_HK,     24                      #  taken); edges: keys, triangles
.equ MG_HV,     32
.equ MG_HM,     40
.equ MG_NS,     44
.equ MG_NT,     48
.equ MG_P,      52                      # (the polygon growing: a slot)
.equ MG_SZ,     64
cb_merge:
    push    rbx
    push    r12
    push    r13
    push    rbp
    sub     rsp, MG_SZ+8
    mov     rbp, rsp
    mov     rbx, [r15+CB_CX]
    mov     eax, [r14+CF_NPO]
    sub     eax, [r15+CB_T0]
    cmp     eax, 2
    jb      .Lmg_out
    mov     [rbp+MG_NT], eax
    lea     r12d, [rax*4+8]             # slots: three a triangle, one more
    mov     esi, r12d                   #  a merge (fewer)
    shl     rsi, 3
    call    cx_alloc
    test    rax, rax
    jz      .Lmg_out
    mov     [rbp+MG_SV], rax
    lea     rax, [rax+r12*4]
    mov     [rbp+MG_SN], rax
    mov     esi, [rbp+MG_NT]
    shl     rsi, 2
    call    cx_alloc
    test    rax, rax
    jz      .Lmg_out
    mov     [rbp+MG_TS], rax
    mov     eax, [rbp+MG_NT]            # edges: 3 a triangle
    lea     eax, [rax+rax*2]
    call    hpow
    lea     eax, [rcx-1]
    mov     [rbp+MG_HM], eax
    mov     r12d, ecx
    mov     rsi, rcx
    shl     rsi, 3
    call    cx_alloc
    test    rax, rax
    jz      .Lmg_out
    mov     [rbp+MG_HK], rax
    mov     rdi, rax
    mov     ecx, r12d
    xor     eax, eax
    rep     stosq
    mov     rsi, r12
    shl     rsi, 2
    call    cx_alloc
    test    rax, rax
    jz      .Lmg_out
    mov     [rbp+MG_HV], rax
    xor     r12d, r12d                  # the triangles' slots, edges
    mov     dword ptr [rbp+MG_NS], 0
1:  cmp     r12d, [rbp+MG_NT]
    jae     2f
    mov     eax, [r15+CB_T0]
    add     eax, r12d
    shl     rax, 4
    add     rax, [r14+CF_PO]
    mov     r8d, [rax+PR_FIRST]
    mov     r9, [r14+CF_LO]
    mov     ecx, [rbp+MG_NS]
    mov     rdx, [rbp+MG_TS]
    mov     [rdx+r12*4], ecx
    xor     r10d, r10d
11: mov     eax, [r9+r8*4]
    mov     rdx, [rbp+MG_SV]
    lea     r11d, [rcx+r10]
    mov     [rdx+r11*4], eax
    lea     eax, [r10+1]
    cmp     eax, 3
    jb      12f
    xor     eax, eax
12: add     eax, ecx
    mov     rdx, [rbp+MG_SN]
    mov     [rdx+r11*4], eax
    inc     r8d
    inc     r10d
    cmp     r10d, 3
    jb      11b
    add     dword ptr [rbp+MG_NS], 3
    mov     edi, ecx                    # its edges (a -> b: slot a)
    call    mg_add_edges
    inc     r12d
    jmp     1b
2:  mov     eax, [r15+CB_T0]            # rewritten from here
    mov     [r14+CF_NPO], eax
    mov     eax, [r15+CB_L0]
    mov     [r14+CF_NLO], eax
    xor     r12d, r12d                  # each triangle not taken: a polygon
3:  cmp     r12d, [rbp+MG_NT]
    jae     .Lmg_out
    mov     rdx, [rbp+MG_TS]
    mov     eax, [rdx+r12*4]
    cmp     eax, -1
    je      39f
    mov     dword ptr [rdx+r12*4], -1
    mov     [rbp+MG_P], eax
4:  xor     r13d, r13d                  # a pass over its edges: grown?
    mov     ebx, [rbp+MG_P]
41: mov     rdx, [rbp+MG_SN]
    mov     esi, [rdx+rbx*4]            # (x, y)
    mov     edi, ebx
    call    mg_try
    or      r13d, eax
    mov     rdx, [rbp+MG_SN]
    mov     ebx, [rdx+rbx*4]
    cmp     ebx, [rbp+MG_P]
    jne     41b
    test    r13d, r13d
    jnz     4b
    call    mg_emit
39: inc     r12d
    jmp     3b
.Lmg_out:
    add     rsp, MG_SZ+8
    pop     rbp
    pop     r13
    pop     r12
    pop     rbx
    ret

# mg_add_edges(edi=a slot of a triangle; rbp = merge frame, r12d = it)
mg_add_edges:
    mov     ecx, edi
    xor     r10d, r10d
1:  mov     rdx, [rbp+MG_SN]
    mov     r8d, [rdx+rcx*4]            # next slot
    mov     rdx, [rbp+MG_SV]
    mov     eax, [rdx+rcx*4]
    mov     r9d, [rdx+r8*4]
    shl     rax, 32
    or      rax, r9
    inc     rax
    mov     r9d, [rbp+MG_HM]
    HSLOT   rax, r9, rdx
    mov     r11, [rbp+MG_HK]
2:  cmp     qword ptr [r11+rdx*8], 0
    je      3f
    inc     rdx
    and     rdx, r9
    jmp     2b
3:  mov     [r11+rdx*8], rax
    mov     r11, [rbp+MG_HV]
    mov     [r11+rdx*4], r12d
    mov     ecx, r8d
    inc     r10d
    cmp     r10d, 3
    jb      1b
    ret

# mg_try(edi=slot x, esi=slot y: an edge of the polygon) -> eax = 1 when
#   the triangle across it (not taken) was grown over: x -> w -> y
mg_try:
    push    rbx
    push    r12
    push    r13
    sub     rsp, 16
    mov     r12d, edi
    mov     r13d, esi
    mov     rdx, [rbp+MG_SV]            # the triangle with (y, x)
    mov     eax, [rdx+r13*4]
    mov     ecx, [rdx+r12*4]
    shl     rax, 32
    or      rax, rcx
    inc     rax
    mov     ecx, [rbp+MG_HM]
    HSLOT   rax, rcx, rdx
    mov     r8, [rbp+MG_HK]
1:  mov     r9, [r8+rdx*8]
    test    r9, r9
    jz      8f
    cmp     r9, rax
    je      2f
    inc     rdx
    and     rdx, rcx
    jmp     1b
2:  mov     r8, [rbp+MG_HV]
    mov     ebx, [r8+rdx*4]             # T
    mov     r8, [rbp+MG_TS]
    mov     ecx, [r8+rbx*4]
    cmp     ecx, -1
    je      8f
    mov     rdx, [rbp+MG_SV]            # w: T's corner that is neither
    mov     r10d, [rdx+r12*4]
    mov     r11d, [rdx+r13*4]
    xor     r9d, r9d
3:  mov     eax, [rdx+rcx*4]
    cmp     eax, r10d
    je      31f
    cmp     eax, r11d
    jne     4f
31: mov     r8, [rbp+MG_SN]
    mov     ecx, [r8+rcx*4]
    inc     r9d
    cmp     r9d, 3
    jb      3b
    jmp     8f
4:  mov     [rsp], eax                  # (w's vertex)
    mov     edi, r12d                   # convex after? the corners at x, w, y
    mov     esi, eax
    mov     edx, r13d
    call    mg_convex
    test    eax, eax
    jz      8f
    mov     r8, [rbp+MG_TS]             # yes: T is taken, w goes in
    mov     dword ptr [r8+rbx*4], -1
    mov     ecx, [rbp+MG_NS]
    inc     dword ptr [rbp+MG_NS]
    mov     rdx, [rbp+MG_SV]
    mov     eax, [rsp]
    mov     [rdx+rcx*4], eax
    mov     rdx, [rbp+MG_SN]
    mov     [rdx+rcx*4], r13d
    mov     [rdx+r12*4], ecx
    mov     eax, 1
    jmp     9f
8:  xor     eax, eax
9:  add     rsp, 16
    pop     r13
    pop     r12
    pop     rbx
    ret

# mg_convex(edi=slot x, esi=vertex w, edx=slot y) -> eax = 1 when the
#   polygon with w between x and y turns left (or goes straight) at x, w, y
mg_convex:
    push    rbx
    push    r12
    push    r13
    push    r14
    sub     rsp, 8
    mov     r12d, edi
    mov     r13d, esi
    mov     ebx, edx                    # (y)
    mov     r8d, edi                    # the slot before x
1:  mov     rax, [rbp+MG_SN]
    mov     ecx, [rax+r8*4]
    cmp     ecx, r12d
    je      2f
    mov     r8d, ecx
    jmp     1b
2:  mov     rax, [rbp+MG_SV]            # (p, x, w)
    mov     edi, [rax+r8*4]
    mov     esi, [rax+r12*4]
    mov     edx, r13d
    call    mg_turn
    test    eax, eax
    jz      8f
    mov     rax, [rbp+MG_SV]            # (x, w, y)
    mov     edi, [rax+r12*4]
    mov     esi, r13d
    mov     edx, [rax+rbx*4]
    call    mg_turn
    test    eax, eax
    jz      8f
    mov     rax, [rbp+MG_SN]            # (w, y, q)
    mov     ecx, [rax+rbx*4]
    mov     rax, [rbp+MG_SV]
    mov     edi, r13d
    mov     esi, [rax+rbx*4]
    mov     edx, [rax+rcx*4]
    call    mg_turn
    test    eax, eax
    jz      8f
    mov     eax, 1
    jmp     9f
8:  xor     eax, eax
9:  add     rsp, 8
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# mg_xy(edi=vertex; r14 = clip frame, r15 = cap frame) -> xmm0, xmm1 = its
#   place in the plane
mg_xy:
    mov     eax, edi
    imul    rax, rax, VX_SZ
    add     rax, [r14+CF_VO]
    movsd   xmm0, [rax]
    mulsd   xmm0, [r15+CB_U]
    movsd   xmm2, [rax+8]
    mulsd   xmm2, [r15+CB_U+8]
    addsd   xmm0, xmm2
    movsd   xmm2, [rax+16]
    mulsd   xmm2, [r15+CB_U+16]
    addsd   xmm0, xmm2
    movsd   xmm1, [rax]
    mulsd   xmm1, [r15+CB_W]
    movsd   xmm2, [rax+8]
    mulsd   xmm2, [r15+CB_W+8]
    addsd   xmm1, xmm2
    movsd   xmm2, [rax+16]
    mulsd   xmm2, [r15+CB_W+16]
    addsd   xmm1, xmm2
    ret

# mg_turn(edi, esi, edx = vertices a, b, c) -> eax = 1 unless it turns
#   right by more than the reflex test's tolerance
mg_turn:
    sub     rsp, 56
    mov     [rsp+48], esi
    mov     [rsp+52], edx
    call    mg_xy
    movsd   [rsp], xmm0
    movsd   [rsp+8], xmm1
    mov     edi, [rsp+48]
    call    mg_xy
    movsd   [rsp+16], xmm0
    movsd   [rsp+24], xmm1
    mov     edi, [rsp+52]
    call    mg_xy
    movsd   xmm4, xmm0
    movsd   xmm5, xmm1
    movsd   xmm0, [rsp]
    movsd   xmm1, [rsp+8]
    movsd   xmm2, [rsp+16]
    movsd   xmm3, [rsp+24]
    add     rsp, 56
    call    orient2
    mov     eax, 1
    xorpd   xmm7, xmm7
    comisd  xmm6, xmm7
    jae     9f
    movsd   xmm9, xmm4                  # o^2 <= d^2 |c - a|^2: as straight
    subsd   xmm9, xmm0
    mulsd   xmm9, xmm9
    movsd   xmm10, xmm5
    subsd   xmm10, xmm1
    mulsd   xmm10, xmm10
    addsd   xmm9, xmm10
    movsd   xmm10, [rip+sh_tol]
    mulsd   xmm10, [rip+sd_100]
    mulsd   xmm10, xmm10
    mulsd   xmm9, xmm10
    mulsd   xmm6, xmm6
    xor     eax, eax
    comisd  xmm6, xmm9
    setbe   al
9:  ret

# mg_emit - the polygon grown (from MG_P) out, tagged with the plane
mg_emit:
    mov     eax, [r14+CF_NPO]
    cmp     eax, [r14+CF_CAPP]
    jae     9f
    mov     r8d, [r14+CF_NLO]
    mov     r9, [r14+CF_LO]
    mov     ecx, [rbp+MG_P]
1:  mov     edx, [r14+CF_NLO]
    cmp     edx, [r14+CF_CAPL]
    jae     9f
    mov     rax, [rbp+MG_SV]
    mov     eax, [rax+rcx*4]
    mov     [r9+rdx*4], eax
    inc     dword ptr [r14+CF_NLO]
    mov     rax, [rbp+MG_SN]
    mov     ecx, [rax+rcx*4]
    cmp     ecx, [rbp+MG_P]
    jne     1b
    mov     eax, [r14+CF_NPO]
    inc     dword ptr [r14+CF_NPO]
    shl     rax, 4
    add     rax, [r14+CF_PO]
    mov     [rax+PR_FIRST], r8d
    mov     ecx, [r14+CF_NLO]
    sub     ecx, r8d
    mov     [rax+PR_CNT], ecx
    mov     ecx, [r14+CF_TAG]
    mov     [rax+PR_TAG], ecx
9:  ret

# cb_grid(edi=an entry) - its ring's reflex corners into a grid over the
#   ring's bounds (about one a cell); none when there are none
cb_grid:
    push    rbx
    push    r12
    push    r13
    mov     qword ptr [r15+CB_GH], 0
    mov     eax, [r15+CB_NREF]
    test    eax, eax
    jz      9f
    mov     rbx, [r15+CB_CX]
    mov     r12d, edi
    mov     r8, [r15+CB_RX]
    mov     r9, [r15+CB_RY]
    mov     r10, [r15+CB_NXT]
    movsd   xmm0, [r8+r12*8]            # bounds
    movsd   xmm1, [r9+r12*8]
    movsd   xmm2, xmm0
    movsd   xmm3, xmm1
    mov     ecx, r12d
1:  minsd   xmm0, [r8+rcx*8]
    maxsd   xmm2, [r8+rcx*8]
    minsd   xmm1, [r9+rcx*8]
    maxsd   xmm3, [r9+rcx*8]
    mov     ecx, [r10+rcx*4]
    cmp     ecx, r12d
    jne     1b
    movsd   [r15+CB_GX], xmm0
    movsd   [r15+CB_GY], xmm1
    cvtsi2sd xmm4, dword ptr [r15+CB_NREF]  # cells a side: sqrt(reflex) + 1
    sqrtsd  xmm4, xmm4
    cvttsd2si eax, xmm4
    inc     eax
    cmp     eax, 1024
    jbe     2f
    mov     eax, 1024
2:  mov     [r15+CB_GS], eax
    cvtsi2sd xmm4, eax
    subsd   xmm2, xmm0                  # cells per unit (a hair under, so
    subsd   xmm3, xmm1                  #  the far side is in the last)
    maxsd   xmm2, [rip+sd_tiny]
    maxsd   xmm3, [rip+sd_tiny]
    movsd   xmm5, xmm4
    mulsd   xmm5, [rip+sd_under]
    movsd   xmm6, xmm5
    divsd   xmm5, xmm2
    divsd   xmm6, xmm3
    movsd   [r15+CB_GIX], xmm5
    movsd   [r15+CB_GIY], xmm6
    imul    eax, eax                    # heads (-1)
    push    rax
    mov     esi, eax
    shl     rsi, 2
    call    cx_alloc
    pop     rcx
    test    rax, rax
    jz      9f
    mov     r13, rax
    mov     rdi, rax
    mov     eax, -1
    rep     stosd
    mov     esi, [r15+CB_NR]            # next: one an entry (the ring's room)
    shl     rsi, 2
    call    cx_alloc
    test    rax, rax
    jz      9f
    mov     [r15+CB_GN], rax
    mov     [r15+CB_GH], r13
    mov     ecx, r12d                   # each reflex corner in its cell
3:  mov     rax, [r15+CB_MARK]
    cmp     dword ptr [rax+rcx*4], 0
    je      4f
    mov     r8, [r15+CB_RX]
    mov     r9, [r15+CB_RY]
    movsd   xmm0, [r8+rcx*8]
    movsd   xmm1, [r9+rcx*8]
    call    cb_cell
    mov     rdx, [r15+CB_GN]
    mov     r8d, [r13+rax*4]
    mov     [rdx+rcx*4], r8d
    mov     [r13+rax*4], ecx
4:  mov     r10, [r15+CB_NXT]
    mov     ecx, [r10+rcx*4]
    cmp     ecx, r12d
    jne     3b
9:  pop     r13
    pop     r12
    pop     rbx
    ret

# cb_cxy(xmm0 = x, xmm1 = y) -> eax = column, edx = row (clamped)
cb_cxy:
    subsd   xmm0, [r15+CB_GX]
    mulsd   xmm0, [r15+CB_GIX]
    cvttsd2si eax, xmm0
    subsd   xmm1, [r15+CB_GY]
    mulsd   xmm1, [r15+CB_GIY]
    cvttsd2si edx, xmm1
    mov     r11d, [r15+CB_GS]
    dec     r11d
    test    eax, eax
    jns     1f
    xor     eax, eax
1:  cmp     eax, r11d
    jle     2f
    mov     eax, r11d
2:  test    edx, edx
    jns     3f
    xor     edx, edx
3:  cmp     edx, r11d
    jle     4f
    mov     edx, r11d
4:  ret

# cb_cell(xmm0, xmm1 = a point) -> eax = its cell
cb_cell:
    call    cb_cxy
    imul    edx, [r15+CB_GS]
    add     eax, edx
    ret

# cb_reflag(edi=corner) - whether it is reflex, again (and the count)
cb_reflag:
    push    rbx
    mov     ebx, edi
    call    cb_reflex
    mov     rdx, [r15+CB_MARK]
    sub     eax, [rdx+rbx*4]
    add     [r15+CB_NREF], eax
    add     [rdx+rbx*4], eax
    pop     rbx
    ret

# cb_reflex(edi=corner) -> eax = 1 when it turns right (prev, it, next)
cb_reflex:
    mov     r10, [r15+CB_NXT]
    mov     r11, [r15+CB_PRV]
    mov     r8, [r15+CB_RX]
    mov     r9, [r15+CB_RY]
    mov     eax, [r11+rdi*4]
    mov     ecx, [r10+rdi*4]
    movsd   xmm0, [r8+rax*8]
    movsd   xmm1, [r9+rax*8]
    movsd   xmm2, [r8+rdi*8]
    movsd   xmm3, [r9+rdi*8]
    movsd   xmm4, [r8+rcx*8]
    movsd   xmm5, [r9+rcx*8]
    call    orient2
    xor     eax, eax
    xorpd   xmm7, xmm7
    comisd  xmm6, xmm7
    jae     1f
    movsd   xmm9, xmm4                  # reflex when it is further than 1e-7
    subsd   xmm9, xmm0                  #  of the size off the line of its
    mulsd   xmm9, xmm9                  #  neighbours: o^2 > d^2 |c - a|^2
    movsd   xmm10, xmm5
    subsd   xmm10, xmm1
    mulsd   xmm10, xmm10
    addsd   xmm9, xmm10
    movsd   xmm10, [rip+sh_tol]
    mulsd   xmm10, [rip+sd_100]
    mulsd   xmm10, xmm10
    mulsd   xmm9, xmm10
    mulsd   xmm6, xmm6
    comisd  xmm6, xmm9
    seta    al
1:  ret

# cb_is_ear(edi=corner) -> eax = 1: it turns left and no reflex corner of
#   the ring is in its triangle
cb_is_ear:
    push    rbx
    push    r12
    push    r13
    push    r14
    sub     rsp, 24
    mov     r13d, edi                   # b
    mov     r10, [r15+CB_NXT]
    mov     r11, [r15+CB_PRV]
    mov     r12d, [r11+rdi*4]           # a
    mov     r14d, [r10+rdi*4]           # c
    mov     r8, [r15+CB_RX]
    mov     r9, [r15+CB_RY]
    movsd   xmm0, [r8+r12*8]
    movsd   xmm1, [r9+r12*8]
    movsd   xmm2, [r8+r13*8]
    movsd   xmm3, [r9+r13*8]
    movsd   xmm4, [r8+r14*8]
    movsd   xmm5, [r9+r14*8]
    call    orient2f
    test    eax, eax                    # (straight: no ear)
    jnz     8f
    xorpd   xmm7, xmm7
    comisd  xmm6, xmm7
    jbe     8f
    cmp     dword ptr [r15+CB_NREF], 0
    je      7f
    cmp     qword ptr [r15+CB_GH], 0
    je      7f
    movsd   xmm0, [r8+r12*8]            # the triangle's cells
    minsd   xmm0, [r8+r13*8]
    minsd   xmm0, [r8+r14*8]
    movsd   xmm1, [r9+r12*8]
    minsd   xmm1, [r9+r13*8]
    minsd   xmm1, [r9+r14*8]
    call    cb_cxy
    mov     [rsp], eax                  # (x0, y0 | x1 << 16, y1 << 16)
    mov     [rsp+4], edx
    movsd   xmm0, [r8+r12*8]
    maxsd   xmm0, [r8+r13*8]
    maxsd   xmm0, [r8+r14*8]
    movsd   xmm1, [r9+r12*8]
    maxsd   xmm1, [r9+r13*8]
    maxsd   xmm1, [r9+r14*8]
    call    cb_cxy
    shl     eax, 16
    or      [rsp], eax
    shl     edx, 16
    or      [rsp+4], edx
    movzx   eax, word ptr [rsp+4]       # rows y0 .. y1
    mov     [rsp+8], eax
10: movzx   eax, word ptr [rsp+6]
    cmp     [rsp+8], eax
    ja      7f
    movzx   eax, word ptr [rsp]         # columns x0 .. x1
    mov     [rsp+12], eax
11: movzx   eax, word ptr [rsp+2]
    cmp     [rsp+12], eax
    ja      19f
    mov     eax, [rsp+8]
    imul    eax, [r15+CB_GS]
    add     eax, [rsp+12]
    mov     rdx, [r15+CB_GH]
    mov     ebx, [rdx+rax*4]
1:  cmp     ebx, -1
    je      18f
    mov     rax, [r15+CB_MARK]
    cmp     dword ptr [rax+rbx*4], 0
    je      6f
    cmp     ebx, r12d
    je      6f
    cmp     ebx, r13d
    je      6f
    cmp     ebx, r14d
    je      6f
    mov     edi, ebx
    mov     esi, r12d
    call    cb_same
    jz      6f
    mov     esi, r13d
    call    cb_same
    jz      6f
    mov     esi, r14d
    call    cb_same
    jz      6f
    movsd   xmm12, [r8+rbx*8]           # inside (a, b, c), edges included
    movsd   xmm13, [r9+rbx*8]
    movsd   xmm0, [r8+r12*8]
    movsd   xmm1, [r9+r12*8]
    movsd   xmm2, [r8+r13*8]
    movsd   xmm3, [r9+r13*8]
    movsd   xmm4, xmm12
    movsd   xmm5, xmm13
    call    orient2
    xorpd   xmm7, xmm7
    comisd  xmm6, xmm7
    jb      6f
    movsd   xmm0, [r8+r13*8]
    movsd   xmm1, [r9+r13*8]
    movsd   xmm2, [r8+r14*8]
    movsd   xmm3, [r9+r14*8]
    call    orient2
    comisd  xmm6, xmm7
    jb      6f
    movsd   xmm0, [r8+r14*8]
    movsd   xmm1, [r9+r14*8]
    movsd   xmm2, [r8+r12*8]
    movsd   xmm3, [r9+r12*8]
    call    orient2
    comisd  xmm6, xmm7
    jae     8f
6:  mov     rdx, [r15+CB_GN]
    mov     ebx, [rdx+rbx*4]
    jmp     1b
18: inc     dword ptr [rsp+12]
    jmp     11b
19: inc     dword ptr [rsp+8]
    jmp     10b
7:  mov     eax, 1
    jmp     9f
8:  xor     eax, eax
9:  add     rsp, 24
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# cb_emit(edi=corner) - the triangle (prev, it, next) tagged with the plane
#   (none when two of its corners are one vertex)
cb_emit:
    mov     r10, [r15+CB_NXT]
    mov     r11, [r15+CB_PRV]
    mov     rax, [r15+CB_RID]
    mov     ecx, [r11+rdi*4]
    mov     ecx, [rax+rcx*4]
    mov     edx, [rax+rdi*4]
    mov     esi, [r10+rdi*4]
    mov     esi, [rax+rsi*4]
    cmp     ecx, edx
    je      9f
    cmp     edx, esi
    je      9f
    cmp     ecx, esi
    je      9f
    mov     eax, [r14+CF_NPO]
    cmp     eax, [r14+CF_CAPP]
    jae     9f
    mov     r8d, [r14+CF_NLO]
    lea     r9d, [r8+3]
    cmp     r9d, [r14+CF_CAPL]
    ja      9f
    inc     dword ptr [r14+CF_NPO]
    mov     [r14+CF_NLO], r9d
    shl     rax, 4
    add     rax, [r14+CF_PO]
    mov     [rax+PR_FIRST], r8d
    mov     dword ptr [rax+PR_CNT], 3
    mov     r9d, [r14+CF_TAG]
    mov     [rax+PR_TAG], r9d
    mov     rax, [r14+CF_LO]
    mov     [rax+r8*4], ecx
    mov     [rax+r8*4+4], edx
    mov     [rax+r8*4+8], esi
9:  ret

# cb_emit_ring(edi=an entry) - its whole ring as one polygon (convex; one
#   vertex twice in a row is once)
cb_emit_ring:
    mov     eax, [r14+CF_NPO]
    cmp     eax, [r14+CF_CAPP]
    jae     9f
    mov     r8d, [r14+CF_NLO]           # (its first loop)
    mov     r9, [r14+CF_LO]
    mov     r10, [r15+CB_NXT]
    mov     r11, [r15+CB_RID]
    mov     ecx, edi
    mov     esi, -1                     # (the last vertex put)
1:  mov     edx, [r11+rcx*4]
    cmp     edx, esi
    je      2f
    mov     eax, [r14+CF_NLO]
    cmp     eax, [r14+CF_CAPL]
    jae     9f
    mov     [r9+rax*4], edx
    inc     dword ptr [r14+CF_NLO]
    mov     esi, edx
2:  mov     ecx, [r10+rcx*4]
    cmp     ecx, edi
    jne     1b
    mov     eax, [r14+CF_NLO]           # (the last as the first: once)
    lea     ecx, [rax-1]
    cmp     ecx, r8d
    jbe     3f
    mov     edx, [r9+rcx*4]
    cmp     edx, [r9+r8*4]
    jne     3f
    dec     dword ptr [r14+CF_NLO]
    dec     eax
3:  sub     eax, r8d
    cmp     eax, 3
    jae     4f
    mov     [r14+CF_NLO], r8d
    jmp     9f
4:  mov     ecx, [r14+CF_NPO]
    inc     dword ptr [r14+CF_NPO]
    shl     rcx, 4
    add     rcx, [r14+CF_PO]
    mov     [rcx+PR_FIRST], r8d
    mov     [rcx+PR_CNT], eax
    mov     eax, [r14+CF_TAG]
    mov     [rcx+PR_TAG], eax
9:  ret

# -----------------------------------------------------------------------------
# A cell: its planes, then the mesh cut by them, then its pieces out
# -----------------------------------------------------------------------------
# sh_arena(ecx=thread index) -> rax = its arena (made on first use), reset
sh_arena:
    push    rbx
    mov     ebx, ecx
    cmp     ebx, NAR-1
    jb      1f
    mov     ebx, NAR-1
1:  imul    rax, rbx, ARENA_SZ
    lea     rdi, [rip+sh_ar]
    add     rdi, rax
    lea     rax, [rip+sh_arok]
    cmp     byte ptr [rax+rbx], 0
    jne     2f
    push    rdi
    mov     rsi, ARCAP
    call    arena_init
    pop     rdi
    lea     rax, [rip+sh_arok]
    mov     byte ptr [rax+rbx], 1
2:  push    rdi
    call    arena_reset
    imul    rax, rbx, ARENA_SZ          # (and its results' arena: rdx)
    lea     rdx, [rip+sh_rar]
    add     rdx, rax
    pop     rax
    pop     rbx
    ret

# sh_rar_reset - every thread's results' arena empty (made on first use)
sh_rar_reset:
    push    rbx
    xor     ebx, ebx
1:  cmp     ebx, NAR
    jae     9f
    imul    rdi, rbx, ARENA_SZ
    lea     rax, [rip+sh_rar]
    add     rdi, rax
    lea     rax, [rip+sh_rarok]
    cmp     byte ptr [rax+rbx], 0
    jne     2f
    mov     byte ptr [rax+rbx], 1
    mov     rsi, ARCAP
    call    arena_init
    jmp     3f
2:  call    arena_reset
3:  inc     ebx
    jmp     1b
9:  pop     rbx
    ret

# sh_ralloc(rbx=cut, rsi=bytes) -> rax: in the thread's results' arena
#   (zeroed; 0: no room)
sh_ralloc:
    push    rsi
    mov     rdi, [rbx+CX_RAR]
    call    arena_alloc
    pop     rcx
    test    rax, rax
    jz      1f
    push    rax
    mov     rdi, rax
    xor     eax, eax
    rep     stosb
    pop     rax
1:  ret

# sh_cut_all(edx=cells) -> eax = 1: every cell cut, sh_res filled. The
#   cells' planes and bounds first (Voronoi cells: made here), then a tree
#   over them (split at the median of their centres, along the longest
#   side), each node's solid cut from its parent's by the node's box (a
#   hair larger than its cells' bounds), level by level; each cell is cut
#   from its leaf's solid at last
sh_cut_all:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    mov     ebx, edx
    mov     edi, 0
    call    sh_lap
    call    sh_res_free
    call    tree_free
    call    sh_rar_reset
    mov     [rip+sh_nres], ebx
    mov     rsi, rbx
    shl     rsi, 4
    call    sh_map
    test    rax, rax
    jz      8f
    mov     [rip+sh_res], rax
    cmp     dword ptr [rip+sh_mode], 1  # Voronoi: the cells' planes
    jne     1f
    mov     edi, ebx
    call    sh_cells_alloc
    test    eax, eax
    jz      8f
    lea     rdi, [rip+planes_job]
    xor     esi, esi
    mov     edx, ebx
    mov     ecx, 1
    call    parallel_for
1:  mov     edi, 1
    call    sh_lap
    call    tree_build
    test    eax, eax
    jz      8f
    mov     edi, 2
    call    sh_lap
    mov     r12d, 1                     # each level's nodes from their parents'
2:  cmp     r12d, [rip+tr_levels]
    jae     4f
    mov     [rip+tr_level], r12d
    lea     rdi, [rip+node_job]
    xor     esi, esi
    mov     edx, [rip+tr_nn]
    mov     ecx, 1
    call    parallel_for
    lea     edi, [r12-1]                # the parents' solids go (not leaves')
    call    tree_free_level
    inc     r12d
    jmp     2b
4:  mov     edi, 3
    call    sh_lap
    lea     rdi, [rip+cell_job]         # the cells from their leaves
    xor     esi, esi
    mov     edx, ebx
    mov     ecx, 1
    call    parallel_for
    mov     edi, 4
    call    sh_lap
    call    tree_free
    mov     eax, 1
    jmp     9f
8:  call    tree_free
    xor     eax, eax
9:  pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# sh_res_free - the results go (their arenas are emptied by the next cut)
sh_res_free:
    mov     rdi, [rip+sh_res]
    mov     esi, [rip+sh_nres]
    shl     rsi, 4
    call    sh_unmap
    mov     qword ptr [rip+sh_res], 0
    mov     dword ptr [rip+sh_nres], 0
    ret

# sh_lap(edi=slot) - ns since the last lap into sh_cnt[slot] (timing)
sh_lap:
    push    rbx
    mov     ebx, edi
    sub     rsp, 16
    mov     edi, 1
    mov     rsi, rsp
    mov     eax, 228
    syscall
    mov     rax, [rsp]
    imul    rax, rax, 1000000000
    add     rax, [rsp+8]
    add     rsp, 16
    mov     rcx, rax
    sub     rcx, [rip+sh_tlap]
    mov     [rip+sh_tlap], rax
    test    ebx, ebx
    jz      1f
    lea     rdx, [rip+sh_cnt]
    mov     [rdx+rbx*8], rcx
1:  pop     rbx
    ret

# sh_cells_alloc(edi=cells) -> eax = 1: room for their planes and bounds
#   (the pattern code fills them for given cells)
sh_cells_alloc:
    push    rbx
    mov     ebx, edi
    call    sh_cells_free
    mov     [rip+sh_ncell], ebx
    imul    rsi, rbx, CPL_MAX*PLN_SZ
    call    sh_map
    mov     [rip+sh_cpl], rax
    test    rax, rax
    jz      8f
    lea     rsi, [rbx*4]
    call    sh_map
    mov     [rip+sh_cpn], rax
    test    rax, rax
    jz      8f
    imul    rsi, rbx, 48
    call    sh_map
    mov     [rip+sh_cbb], rax
    test    rax, rax
    jz      8f
    mov     eax, 1
    pop     rbx
    ret
8:  call    sh_cells_free
    xor     eax, eax
    pop     rbx
    ret

sh_cells_free:
    push    rbx
    mov     ebx, [rip+sh_ncell]
    mov     rdi, [rip+sh_cpl]
    imul    rsi, rbx, CPL_MAX*PLN_SZ
    call    sh_unmap
    mov     rdi, [rip+sh_cpn]
    lea     rsi, [rbx*4]
    call    sh_unmap
    mov     rdi, [rip+sh_cbb]
    imul    rsi, rbx, 48
    call    sh_unmap
    xor     eax, eax
    mov     [rip+sh_cpl], rax
    mov     [rip+sh_cpn], rax
    mov     [rip+sh_cbb], rax
    mov     [rip+sh_ncell], eax
    pop     rbx
    ret

# planes_job(rdi, esi=begin, edx=end, ecx=thread) - Voronoi cells' planes
#   and bounds
planes_job:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    sub     rsp, 16
    mov     r12d, esi
    mov     [rsp], edx
    mov     [rsp+4], ecx
1:  cmp     r12d, [rsp]
    jae     9f
    mov     ecx, [rsp+4]
    call    sh_arena
    mov     r15, rax
    push    rdx
    push    rdx
    mov     rdi, r15
    mov     esi, CX_SZ
    call    arena_alloc
    pop     rdx
    pop     rdx
    test    rax, rax
    jz      2f
    mov     rbx, rax
    mov     [rbx+CX_AR], r15
    mov     [rbx+CX_RAR], rdx
    mov     dword ptr [rbx+CX_FAIL], 0
    mov     rax, [rip+sh_cpn]           # (none until made)
    mov     dword ptr [rax+r12*4], 0
    call    vor_planes
    test    eax, eax
    jz      2f
    cmp     r14d, CPL_MAX
    jbe     11f
    mov     r14d, CPL_MAX
11: mov     rax, [rip+sh_cpn]
    mov     [rax+r12*4], r14d
    imul    rdi, r12, CPL_MAX*PLN_SZ
    add     rdi, [rip+sh_cpl]
    mov     rsi, r13
    imul    ecx, r14d, PLN_SZ
    rep     movsb
    imul    rdi, r12, 48                # its bounds: the cell's corners
    add     rdi, [rip+sh_cbb]
    call    cx_bounds
2:  inc     r12d
    jmp     1b
9:  add     rsp, 16
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# cx_bounds(rbx=cut, rdi=out 6 doubles) - its vertices' bounds
cx_bounds:
    movsd   xmm0, [rip+sd_big]
    movsd   xmm1, xmm0
    movsd   xmm2, xmm0
    xorpd   xmm3, xmm3
    subsd   xmm3, xmm0
    movsd   xmm4, xmm3
    movsd   xmm5, xmm3
    mov     rsi, [rbx+CX_V]
    mov     ecx, [rbx+CX_NV]
    test    ecx, ecx
    jz      2f
1:  minsd   xmm0, [rsi]
    minsd   xmm1, [rsi+8]
    minsd   xmm2, [rsi+16]
    maxsd   xmm3, [rsi]
    maxsd   xmm4, [rsi+8]
    maxsd   xmm5, [rsi+16]
    add     rsi, VX_SZ
    dec     ecx
    jnz     1b
2:  movsd   [rdi], xmm0
    movsd   [rdi+8], xmm1
    movsd   [rdi+16], xmm2
    movsd   [rdi+24], xmm3
    movsd   [rdi+32], xmm4
    movsd   [rdi+40], xmm5
    ret

# ---- the tree ------------------------------------------------------------------

# tree_build -> eax = 1: tr_nodes from the cells' bounds
tree_build:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    push    rbp
    sub     rsp, 56
    call    tree_free
    mov     ebx, [rip+sh_ncell]
    test    ebx, ebx
    jz      .Ltb_fail
    lea     rsi, [rbx*8+8]              # nodes: 2n at most
    imul    rsi, rsi, TN_SZ/4
    mov     [rip+tr_bytes], rsi
    call    sh_map
    test    rax, rax
    jz      .Ltb_fail
    mov     [rip+tr_nodes], rax
    lea     rsi, [rbx*4]                # the cells in tree order, each one's leaf
    call    sh_map
    mov     [rip+tr_order], rax
    test    rax, rax
    jz      .Ltb_fail
    lea     rsi, [rbx*4]
    call    sh_map
    mov     [rip+tr_leaf], rax
    test    rax, rax
    jz      .Ltb_fail
    lea     rsi, [rbx*8]                # (sort keys)
    call    sh_map
    mov     [rip+tr_keys], rax
    test    rax, rax
    jz      .Ltb_fail
    lea     rsi, [rbx*8+64]             # (a stack of nodes to split)
    call    sh_map
    mov     [rip+tr_stack], rax
    test    rax, rax
    jz      .Ltb_fail
    mov     rdi, [rip+tr_order]
    xor     ecx, ecx
1:  cmp     ecx, ebx
    jae     2f
    mov     [rdi+rcx*4], ecx
    inc     ecx
    jmp     1b
2:  mov     dword ptr [rip+tr_nn], 1    # the root: every cell, the mesh
    mov     dword ptr [rip+tr_levels], 1
    mov     r12, [rip+tr_nodes]
    mov     dword ptr [r12+TN_FIRST], 0
    mov     [r12+TN_CNT], ebx
    mov     dword ptr [r12+TN_PAR], -1
    mov     dword ptr [r12+TN_LEV], 0
    mov     rax, [rip+sh_src_p]
    mov     [r12+TN_V], rax
    mov     rax, [rip+sh_src_pp]
    mov     [r12+TN_P], rax
    mov     rax, [rip+sh_src_pl]
    mov     [r12+TN_L], rax
    mov     eax, [rip+sh_src_nv]
    mov     [r12+TN_NV], eax
    mov     eax, [rip+sh_src_nt]
    mov     [r12+TN_NP], eax
    lea     eax, [rax+rax*2]
    mov     [r12+TN_NL], eax
    xor     edi, edi
    call    tn_box
    mov     rax, [rip+tr_stack]         # split nodes from the stack
    mov     dword ptr [rax], 0
    mov     r13d, 1
3:  test    r13d, r13d
    jz      7f
    dec     r13d
    mov     rax, [rip+tr_stack]
    mov     r14d, [rax+r13*4]           # the node
    imul    r15, r14, TN_SZ
    add     r15, [rip+tr_nodes]
    cmp     dword ptr [r15+TN_CNT], 1
    ja      4f
    mov     dword ptr [r15+TN_LEAF], 1  # a leaf: its cell's
    mov     eax, [r15+TN_FIRST]
    mov     rcx, [rip+tr_order]
    mov     eax, [rcx+rax*4]
    mov     rcx, [rip+tr_leaf]
    mov     [rcx+rax*4], r14d
    jmp     3b
4:  mov     edi, r14d                   # sorted along the longest side of
    call    tn_sort                     #  its cells' centres
    mov     eax, [r15+TN_CNT]           # two halves
    mov     ebp, eax
    shr     ebp, 1
    xor     ecx, ecx
5:  mov     edx, [rip+tr_nn]
    inc     dword ptr [rip+tr_nn]
    imul    rdi, rdx, TN_SZ
    add     rdi, [rip+tr_nodes]
    mov     eax, [r15+TN_FIRST]
    test    ecx, ecx
    jz      51f
    add     eax, ebp
51: mov     [rdi+TN_FIRST], eax
    mov     eax, ebp
    test    ecx, ecx
    jz      52f
    mov     eax, [r15+TN_CNT]
    sub     eax, ebp
52: mov     [rdi+TN_CNT], eax
    mov     [rdi+TN_PAR], r14d
    mov     eax, [r15+TN_LEV]
    inc     eax
    mov     [rdi+TN_LEV], eax
    inc     eax
    cmp     eax, [rip+tr_levels]
    jbe     53f
    mov     [rip+tr_levels], eax
53: push    rcx
    push    rdx
    mov     edi, edx
    call    tn_box
    pop     rdx
    pop     rcx
    mov     rax, [rip+tr_stack]
    mov     [rax+r13*4], edx
    inc     r13d
    inc     ecx
    cmp     ecx, 2
    jb      5b
    jmp     3b
7:  mov     eax, 1
    jmp     9f
.Ltb_fail:
    call    tree_free
    xor     eax, eax
9:  add     rsp, 56
    pop     rbp
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# tn_box(edi=node) - its box: its cells' bounds, a hair larger
tn_box:
    imul    rdi, rdi, TN_SZ
    add     rdi, [rip+tr_nodes]
    movsd   xmm0, [rip+sd_big]
    movsd   xmm1, xmm0
    movsd   xmm2, xmm0
    xorpd   xmm3, xmm3
    subsd   xmm3, xmm0
    movsd   xmm4, xmm3
    movsd   xmm5, xmm3
    mov     ecx, [rdi+TN_FIRST]
    mov     edx, [rdi+TN_CNT]
    add     edx, ecx
    mov     r8, [rip+tr_order]
    mov     r9, [rip+sh_cbb]
1:  cmp     ecx, edx
    jae     2f
    mov     eax, [r8+rcx*4]
    imul    rax, rax, 48
    minsd   xmm0, [r9+rax]
    minsd   xmm1, [r9+rax+8]
    minsd   xmm2, [r9+rax+16]
    maxsd   xmm3, [r9+rax+24]
    maxsd   xmm4, [r9+rax+32]
    maxsd   xmm5, [r9+rax+40]
    inc     ecx
    jmp     1b
2:  movsd   xmm6, [rip+sh_tol]          # the hair: 1e4 tolerances
    mulsd   xmm6, [rip+sd_hair]
    subsd   xmm0, xmm6
    subsd   xmm1, xmm6
    subsd   xmm2, xmm6
    addsd   xmm3, xmm6
    addsd   xmm4, xmm6
    addsd   xmm5, xmm6
    movsd   [rdi+TN_MIN], xmm0
    movsd   [rdi+TN_MIN+8], xmm1
    movsd   [rdi+TN_MIN+16], xmm2
    movsd   [rdi+TN_MAX], xmm3
    movsd   [rdi+TN_MAX+8], xmm4
    movsd   [rdi+TN_MAX+16], xmm5
    ret

# tn_sort(edi=node) - its cells in order along the longest side of their
#   centres' bounds
tn_sort:
    push    rbx
    push    r12
    push    r13
    imul    rbx, rdi, TN_SZ
    add     rbx, [rip+tr_nodes]
    mov     r8, [rip+tr_order]
    mov     r9, [rip+sh_cbb]
    xor     r12d, r12d                  # the axis: the longest of the
    xorpd   xmm7, xmm7                  #  centres' spread
    xor     r10d, r10d
1:  movsd   xmm0, [rip+sd_big]
    xorpd   xmm1, xmm1
    subsd   xmm1, xmm0
    mov     ecx, [rbx+TN_FIRST]
    mov     edx, [rbx+TN_CNT]
    add     edx, ecx
2:  cmp     ecx, edx
    jae     3f
    mov     eax, [r8+rcx*4]
    imul    rax, rax, 48
    add     rax, r9
    movsd   xmm2, [rax+r10*8]
    addsd   xmm2, [rax+r10*8+24]
    minsd   xmm0, xmm2
    maxsd   xmm1, xmm2
    inc     ecx
    jmp     2b
3:  subsd   xmm1, xmm0
    comisd  xmm1, xmm7
    jbe     4f
    movsd   xmm7, xmm1
    mov     r12d, r10d
4:  inc     r10d
    cmp     r10d, 3
    jb      1b
    mov     r13, [rip+tr_keys]          # keys: the centre (sortable bits),
    mov     ecx, [rbx+TN_FIRST]         #  the cell
    xor     r10d, r10d
5:  cmp     r10d, [rbx+TN_CNT]
    jae     6f
    lea     eax, [rcx+r10]
    mov     eax, [r8+rax*4]
    imul    rdx, rax, 48
    add     rdx, r9
    movsd   xmm2, [rdx+r12*8]
    addsd   xmm2, [rdx+r12*8+24]
    cvtsd2ss xmm2, xmm2
    movd    edx, xmm2
    mov     r11d, edx                   # negative: all bits turned, else
    sar     r11d, 31                    #  the sign bit set
    or      r11d, 0x80000000
    xor     edx, r11d
    shl     rdx, 32
    or      rdx, rax
    mov     [r13+r10*8], rdx
    inc     r10d
    jmp     5b
6:  mov     rdi, r13
    mov     esi, [rbx+TN_CNT]
    call    sort_u64
    mov     r8, [rip+tr_order]
    mov     ecx, [rbx+TN_FIRST]
    xor     r10d, r10d
7:  cmp     r10d, [rbx+TN_CNT]
    jae     9f
    mov     eax, [r13+r10*8]
    lea     edx, [rcx+r10]
    mov     [r8+rdx*4], eax
    inc     r10d
    jmp     7b
9:  pop     r13
    pop     r12
    pop     rbx
    ret

# node_job(rdi, esi=begin, edx=end, ecx=thread) - the nodes of tr_level:
#   each one's solid, its parent's cut by its box
node_job:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    sub     rsp, 16
    mov     r12d, esi
    mov     [rsp], edx
    mov     [rsp+4], ecx
1:  cmp     r12d, [rsp]
    jae     9f
    imul    r13, r12, TN_SZ
    add     r13, [rip+tr_nodes]
    mov     eax, [r13+TN_LEV]
    cmp     eax, [rip+tr_level]
    jne     2f
    mov     ecx, [rsp+4]
    call    sh_arena
    mov     r15, rax
    push    rdx
    push    rdx
    mov     rdi, r15
    mov     esi, CX_SZ
    call    arena_alloc
    pop     rdx
    pop     rdx
    test    rax, rax
    jz      2f
    mov     rbx, rax
    mov     [rbx+CX_AR], r15
    mov     [rbx+CX_RAR], rdx
    mov     dword ptr [rbx+CX_FAIL], 0
    mov     rdi, r13
    call    node_cut
2:  inc     r12d
    jmp     1b
9:  add     rsp, 16
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# node_cut(rbx=cut, rdi=node) - its parent's solid by its box's planes (those
#   inside the parent's), kept in a mapping of its own
node_cut:
    push    r12
    push    r13
    push    r14
    push    r15
    sub     rsp, 56
    mov     r12, rdi
    mov     eax, [r12+TN_PAR]
    imul    r13, rax, TN_SZ
    add     r13, [rip+tr_nodes]
    mov     rax, r13
    call    cx_from_node
    xor     r14d, r14d                  # the six faces: x <= max, -x <= -min ..
1:  cmp     r14d, 6
    jae     5f
    cmp     dword ptr [rbx+CX_NP], 0
    je      5f
    mov     r15d, r14d
    shr     r15d, 1                     # (axis)
    xorpd   xmm0, xmm0
    movsd   [rsp], xmm0
    movsd   [rsp+8], xmm0
    movsd   [rsp+16], xmm0
    mov     dword ptr [rsp+32], 0       # (tag 0)
    movsd   xmm3, [r13+TN_MAX+r15*8]    # (2% of the parent's side: closer
    subsd   xmm3, [r13+TN_MIN+r15*8]    #  to its face, no cut - a sliver
    mulsd   xmm3, [rip+sd_near]         #  slab would only add triangles)
    test    r14d, 1
    jnz     2f
    movsd   xmm1, [r12+TN_MAX+r15*8]    # max: only when inside the parent's
    addsd   xmm1, xmm3
    comisd  xmm1, [r13+TN_MAX+r15*8]
    jae     4f
    subsd   xmm1, xmm3
    movsd   xmm0, [rip+sd_one]
    movsd   [rsp+r15*8], xmm0
    movsd   [rsp+24], xmm1
    jmp     3f
2:  movsd   xmm1, [r12+TN_MIN+r15*8]
    subsd   xmm1, xmm3
    comisd  xmm1, [r13+TN_MIN+r15*8]
    jbe     4f
    addsd   xmm1, xmm3
    movsd   xmm0, [rip+sd_one]
    xorpd   xmm2, xmm2
    subsd   xmm2, xmm0
    movsd   [rsp+r15*8], xmm2
    xorpd   xmm2, xmm2
    subsd   xmm2, xmm1
    movsd   [rsp+24], xmm2
3:  lea     rsi, [rsp]
    call    clip_plane
    cmp     dword ptr [rbx+CX_FAIL], 0
    jne     8f
4:  inc     r14d
    jmp     1b
5:  mov     rdi, r12                    # its own copy
    call    node_keep
    jmp     9f
8:  mov     dword ptr [r12+TN_NP], 0    # (no room: nothing)
9:  add     rsp, 56
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    ret

# cx_from_node(rax=node; rbx = cut) - the cut starts from its solid
cx_from_node:
    mov     rcx, [rax+TN_V]
    mov     [rbx+CX_V], rcx
    mov     rcx, [rax+TN_P]
    mov     [rbx+CX_P], rcx
    mov     rcx, [rax+TN_L]
    mov     [rbx+CX_L], rcx
    mov     ecx, [rax+TN_NV]
    mov     [rbx+CX_NV], ecx
    mov     ecx, [rax+TN_NP]
    mov     [rbx+CX_NP], ecx
    mov     ecx, [rax+TN_NL]
    mov     [rbx+CX_NL], ecx
    ret

# node_keep(rdi=node; rbx = cut) - the cut's solid copied into a mapping of
#   the node's own
node_keep:
    push    r12
    mov     r12, rdi
    mov     eax, [rbx+CX_NV]
    mov     [r12+TN_NV], eax
    mov     eax, [rbx+CX_NP]
    mov     [r12+TN_NP], eax
    mov     eax, [rbx+CX_NL]
    mov     [r12+TN_NL], eax
    cmp     dword ptr [rbx+CX_NP], 0
    je      9f
    mov     eax, [rbx+CX_NV]
    imul    rsi, rax, VX_SZ
    mov     eax, [rbx+CX_NP]
    shl     rax, 4
    add     rsi, rax
    mov     eax, [rbx+CX_NL]
    lea     rsi, [rsi+rax*4]
    call    sh_ralloc
    test    rax, rax
    jz      8f
    mov     [r12+TN_V], rax
    mov     rdi, rax
    mov     rsi, [rbx+CX_V]
    mov     eax, [rbx+CX_NV]
    imul    rcx, rax, VX_SZ
    rep     movsb
    mov     [r12+TN_P], rdi
    mov     rsi, [rbx+CX_P]
    mov     eax, [rbx+CX_NP]
    mov     rcx, rax
    shl     rcx, 4
    rep     movsb
    mov     [r12+TN_L], rdi
    mov     rsi, [rbx+CX_L]
    mov     eax, [rbx+CX_NL]
    lea     rcx, [rax*4]
    rep     movsb
    jmp     9f
8:  mov     dword ptr [r12+TN_NP], 0
9:  pop     r12
    ret

# tree_free_level(edi=level) - the solids of that level's nodes that have
#   children
tree_free_level:
    push    rbx
    push    r12
    mov     r12d, edi
    xor     ebx, ebx
1:  cmp     ebx, [rip+tr_nn]
    jae     9f
    imul    rax, rbx, TN_SZ
    add     rax, [rip+tr_nodes]
    cmp     [rax+TN_LEV], r12d
    jne     2f
    cmp     dword ptr [rax+TN_LEAF], 0
    jne     2f
    mov     rdi, rax
    call    tn_free
2:  inc     ebx
    jmp     1b
9:  pop     r12
    pop     rbx
    ret

# tn_free(rdi=node) - its own solid goes
tn_free:
    push    rbx
    mov     rbx, rdi
    mov     qword ptr [rbx+TN_V], 0
    mov     dword ptr [rbx+TN_NP], 0
    pop     rbx
    ret

# tree_free - the tree and every solid in it
tree_free:
    push    rbx
    mov     rax, [rip+tr_nodes]
    test    rax, rax
    jz      8f
    xor     ebx, ebx
1:  cmp     ebx, [rip+tr_nn]
    jae     2f
    imul    rdi, rbx, TN_SZ
    add     rdi, [rip+tr_nodes]
    call    tn_free
    inc     ebx
    jmp     1b
2:  mov     rdi, [rip+tr_nodes]
    mov     rsi, [rip+tr_bytes]
    call    sh_unmap
    mov     ebx, [rip+sh_ncell]
    mov     rdi, [rip+tr_order]
    lea     rsi, [rbx*4]
    call    sh_unmap
    mov     rdi, [rip+tr_leaf]
    lea     rsi, [rbx*4]
    call    sh_unmap
    mov     rdi, [rip+tr_keys]
    lea     rsi, [rbx*8]
    call    sh_unmap
    mov     rdi, [rip+tr_stack]
    lea     rsi, [rbx*8+64]
    call    sh_unmap
8:  xor     eax, eax
    mov     [rip+tr_nodes], rax
    mov     [rip+tr_order], rax
    mov     [rip+tr_leaf], rax
    mov     [rip+tr_keys], rax
    mov     [rip+tr_stack], rax
    mov     [rip+tr_nn], eax
    pop     rbx
    ret

# cell_job(rdi=ctx, esi=begin, edx=end, ecx=thread) - cells from their leaves
cell_job:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    sub     rsp, 16
    mov     r12d, esi
    mov     r13d, edx
    mov     r14d, ecx
1:  cmp     r12d, r13d
    jae     9f
    mov     ecx, r14d
    call    sh_arena
    mov     r15, rax
    push    rdx
    push    rdx
    mov     rdi, r15
    mov     esi, CX_SZ
    call    arena_alloc
    pop     rdx
    pop     rdx
    test    rax, rax
    jz      2f
    mov     rbx, rax
    mov     [rbx+CX_AR], r15
    mov     [rbx+CX_RAR], rdx
    mov     dword ptr [rbx+CX_FAIL], 0
    mov     edi, r12d
    call    cut_cell
2:  inc     r12d
    jmp     1b
9:  add     rsp, 16
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# cut_cell(rbx=cut, edi=cell) - its leaf's solid by its planes; its pieces
cut_cell:
    push    r12
    push    r13
    push    r14
    push    r15
    sub     rsp, 8
    mov     r12d, edi
    mov     rax, [rip+sh_cpn]
    mov     r14d, [rax+r12*4]
    test    r14d, r14d
    jz      9f
    imul    r13, r12, CPL_MAX*PLN_SZ
    add     r13, [rip+sh_cpl]
    mov     rax, [rip+tr_leaf]          # its leaf's solid
    mov     eax, [rax+r12*4]
    imul    rax, rax, TN_SZ
    add     rax, [rip+tr_nodes]
    call    cx_from_node
    xor     r15d, r15d
3:  cmp     r15d, r14d
    jae     4f
    cmp     dword ptr [rbx+CX_NP], 0
    je      4f
    cmp     dword ptr [rbx+CX_FAIL], 0
    jne     9f
    imul    rsi, r15, PLN_SZ
    add     rsi, r13
    call    clip_plane
    inc     r15d
    jmp     3b
4:  cmp     dword ptr [rbx+CX_FAIL], 0
    jne     9f
    cmp     dword ptr [rbx+CX_NP], 0
    je      9f
    mov     edi, r12d
    call    put_pieces
9:  add     rsp, 8
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    ret

# vor_planes(rbx=cut, r12d=cell) -> eax = 1, r13 = its planes, r14d = how
#   many: the box around the mesh cut by the bisectors with the other seeds,
#   nearest first, until none can reach it (twice the cell's radius); the
#   planes are those that left a face
vor_planes:
    push    r15
    push    rbp
    sub     rsp, 88                     # +0 the seed, +24 R^2, +32 seeds,
    mov     eax, [rip+sh_nseeds]        #  +40 a plane; the others by
    mov     [rsp+32], eax               #  distance: keys
    mov     rsi, rax
    shl     rsi, 3
    call    cx_alloc
    test    rax, rax
    jz      .Lvp_fail
    mov     r15, rax
    imul    rax, r12, VX_SZ
    add     rax, [rip+sh_seeds]
    movsd   xmm0, [rax]
    movsd   [rsp], xmm0
    movsd   xmm0, [rax+8]
    movsd   [rsp+8], xmm0
    movsd   xmm0, [rax+16]
    movsd   [rsp+16], xmm0
    mov     rsi, [rip+sh_seeds]
    xor     ecx, ecx
1:  cmp     ecx, [rsp+32]
    jae     2f
    movsd   xmm0, [rsi]
    subsd   xmm0, [rsp]
    mulsd   xmm0, xmm0
    movsd   xmm1, [rsi+8]
    subsd   xmm1, [rsp+8]
    mulsd   xmm1, xmm1
    addsd   xmm0, xmm1
    movsd   xmm1, [rsi+16]
    subsd   xmm1, [rsp+16]
    mulsd   xmm1, xmm1
    addsd   xmm0, xmm1
    cvtsd2ss xmm0, xmm0                 # (float bits sort like the floats)
    movd    eax, xmm0
    shl     rax, 32
    or      rax, rcx
    mov     [r15+rcx*8], rax
    add     rsi, VX_SZ
    inc     ecx
    jmp     1b
2:  mov     rdi, r15
    mov     esi, [rsp+32]
    call    sort_u64
    call    box_cell                    # the box
    test    eax, eax
    jz      .Lvp_fail
    call    cell_radius
    movsd   [rsp+24], xmm0              # R^2
    xor     ebp, ebp
3:  cmp     ebp, [rsp+32]
    jae     5f
    mov     rax, [r15+rbp*8]
    mov     ecx, eax                    # j
    cmp     ecx, r12d
    je      4f
    shr     rax, 32                     # |sj - si|^2 > 4 R^2: done
    movd    xmm0, eax
    cvtss2sd xmm0, xmm0
    movsd   xmm1, [rsp+24]
    mulsd   xmm1, [rip+sd_four]
    comisd  xmm0, xmm1
    ja      5f
    lea     rdi, [rsp+40]
    mov     esi, ecx
    call    bisector
    lea     rsi, [rsp+40]
    call    clip_plane
    cmp     dword ptr [rbx+CX_FAIL], 0
    jne     .Lvp_fail
    call    cell_radius
    movsd   [rsp+24], xmm0
4:  inc     ebp
    jmp     3b
5:  mov     esi, [rbx+CX_NP]            # the planes that left faces
    imul    rsi, rsi, PLN_SZ
    call    cx_alloc
    test    rax, rax
    jz      .Lvp_fail
    mov     r13, rax
    xor     r14d, r14d
    xor     ebp, ebp                    # in the order of distance
6:  cmp     ebp, [rsp+32]
    jae     8f
    mov     rax, [r15+rbp*8]
    mov     ecx, eax
    cmp     ecx, r12d
    je      7f
    shr     rax, 32                     # (past the reach: done)
    movd    xmm0, eax
    cvtss2sd xmm0, xmm0
    movsd   xmm1, [rsp+24]
    mulsd   xmm1, [rip+sd_four]
    comisd  xmm0, xmm1
    ja      8f
    lea     edx, [rcx+1]                # its tag among the triangles?
    mov     rsi, [rbx+CX_P]
    mov     edi, [rbx+CX_NP]
61: test    edi, edi
    jz      7f
    cmp     [rsi+PR_TAG], edx
    je      62f
    add     rsi, PR_SZ
    dec     edi
    jmp     61b
62: imul    rdi, r14, PLN_SZ
    add     rdi, r13
    mov     esi, ecx
    call    bisector
    inc     r14d
7:  inc     ebp
    jmp     6b
8:  mov     eax, 1
    jmp     9f
.Lvp_fail:
    xor     eax, eax
9:  add     rsp, 88
    pop     rbp
    pop     r15
    ret

# bisector(rdi=plane out, esi=seed j; r12d = seed i) - the plane between
#   them, i's side in; tagged j + 1
bisector:
    mov     rax, [rip+sh_seeds]
    imul    rcx, r12, VX_SZ
    imul    rdx, rsi, VX_SZ
    movsd   xmm0, [rax+rdx]             # n = sj - si
    subsd   xmm0, [rax+rcx]
    movsd   xmm1, [rax+rdx+8]
    subsd   xmm1, [rax+rcx+8]
    movsd   xmm2, [rax+rdx+16]
    subsd   xmm2, [rax+rcx+16]
    movsd   xmm3, xmm0
    mulsd   xmm3, xmm0
    movsd   xmm4, xmm1
    mulsd   xmm4, xmm1
    addsd   xmm3, xmm4
    movsd   xmm4, xmm2
    mulsd   xmm4, xmm2
    addsd   xmm3, xmm4
    sqrtsd  xmm3, xmm3
    maxsd   xmm3, [rip+sd_tiny]
    movsd   xmm4, [rip+sd_one]
    divsd   xmm4, xmm3
    mulsd   xmm0, xmm4
    mulsd   xmm1, xmm4
    mulsd   xmm2, xmm4
    movsd   [rdi], xmm0
    movsd   [rdi+8], xmm1
    movsd   [rdi+16], xmm2
    movsd   xmm3, [rax+rdx]             # d = n . (si + sj) / 2
    addsd   xmm3, [rax+rcx]
    mulsd   xmm3, xmm0
    movsd   xmm4, [rax+rdx+8]
    addsd   xmm4, [rax+rcx+8]
    mulsd   xmm4, xmm1
    addsd   xmm3, xmm4
    movsd   xmm4, [rax+rdx+16]
    addsd   xmm4, [rax+rcx+16]
    mulsd   xmm4, xmm2
    addsd   xmm3, xmm4
    mulsd   xmm3, [rip+sd_half]
    movsd   [rdi+24], xmm3
    lea     eax, [rsi+1]
    mov     [rdi+PLN_TAG], eax
    ret

# box_cell(rbx=cut) -> eax = 1: the cut is the box around the mesh, 1%
#   larger (8 vertices, 12 triangles, tag 0)
box_cell:
    push    r12
    push    r13
    mov     esi, 8*VX_SZ
    call    cx_alloc
    test    rax, rax
    jz      8f
    mov     r12, rax
    mov     esi, 6*PR_SZ+24*4
    call    cx_alloc
    test    rax, rax
    jz      8f
    mov     r13, rax
    xor     ecx, ecx                    # corner k: bit 0 x, 1 y, 2 z
1:  cmp     ecx, 8
    jae     3f
    xor     edx, edx
2:  lea     r8, [rip+sh_src_min]
    movsd   xmm0, [r8+rdx*8]
    lea     r8, [rip+sh_src_max]
    movsd   xmm1, [r8+rdx*8]
    movsd   xmm2, xmm1                  # pad = 1% of the side + tol
    subsd   xmm2, xmm0
    mulsd   xmm2, [rip+sd_pad]
    addsd   xmm2, [rip+sh_tol]
    addsd   xmm2, [rip+sh_tol]
    bt      ecx, edx
    jc      21f
    subsd   xmm0, xmm2
    jmp     22f
21: movsd   xmm0, xmm1
    addsd   xmm0, xmm2
22: imul    rax, rcx, VX_SZ
    add     rax, r12
    movsd   [rax+rdx*8], xmm0
    inc     edx
    cmp     edx, 3
    jb      2b
    inc     ecx
    jmp     1b
3:  xor     ecx, ecx                    # six quads
31: mov     rax, rcx
    shl     rax, 4
    lea     edx, [rcx*4]
    mov     [r13+rax+PR_FIRST], edx
    mov     dword ptr [r13+rax+PR_CNT], 4
    mov     dword ptr [r13+rax+PR_TAG], 0
    inc     ecx
    cmp     ecx, 6
    jb      31b
    lea     rdi, [r13+6*PR_SZ]
    lea     rsi, [rip+box_quads]
    mov     ecx, 24
    rep     movsd
    mov     [rbx+CX_V], r12
    mov     [rbx+CX_P], r13
    lea     rax, [r13+6*PR_SZ]
    mov     [rbx+CX_L], rax
    mov     dword ptr [rbx+CX_NV], 8
    mov     dword ptr [rbx+CX_NP], 6
    mov     dword ptr [rbx+CX_NL], 24
    mov     eax, 1
    jmp     9f
8:  xor     eax, eax
9:  pop     r13
    pop     r12
    ret

# cell_radius(rbx=cut; r12d = seed) -> xmm0 = the most a vertex is from it,
#   squared
cell_radius:
    mov     rax, [rip+sh_seeds]
    imul    rcx, r12, VX_SZ
    movsd   xmm3, [rax+rcx]
    movsd   xmm4, [rax+rcx+8]
    movsd   xmm5, [rax+rcx+16]
    xorpd   xmm0, xmm0
    mov     rsi, [rbx+CX_V]
    mov     ecx, [rbx+CX_NV]
    test    ecx, ecx
    jz      9f
1:  movsd   xmm1, [rsi]
    subsd   xmm1, xmm3
    mulsd   xmm1, xmm1
    movsd   xmm2, [rsi+8]
    subsd   xmm2, xmm4
    mulsd   xmm2, xmm2
    addsd   xmm1, xmm2
    movsd   xmm2, [rsi+16]
    subsd   xmm2, xmm5
    mulsd   xmm2, xmm2
    addsd   xmm1, xmm2
    maxsd   xmm0, xmm1
    add     rsi, VX_SZ
    dec     ecx
    jnz     1b
9:  ret

# sort_u64(rdi=keys, esi=count) - ascending (Shell sort)
sort_u64:
    push    rbx
    mov     r8d, 1                      # gaps 1, 4, 13, 40, ...
1:  lea     eax, [r8+r8*2+1]
    cmp     eax, esi
    jae     2f
    mov     r8d, eax
    jmp     1b
2:  mov     ecx, r8d                    # i = gap .. n-1
3:  cmp     ecx, esi
    jae     6f
    mov     rax, [rdi+rcx*8]
    mov     edx, ecx
4:  cmp     edx, r8d
    jb      5f
    mov     r9d, edx
    sub     r9d, r8d
    mov     r10, [rdi+r9*8]
    cmp     r10, rax
    jbe     5f
    mov     [rdi+rdx*8], r10
    mov     edx, r9d
    jmp     4b
5:  mov     [rdi+rdx*8], rax
    inc     ecx
    jmp     3b
6:  xor     edx, edx                    # the next smaller gap
    mov     eax, r8d
    mov     ebx, 3
    div     ebx
    mov     r8d, eax
    test    r8d, r8d
    jnz     2b
    pop     rbx
    ret

# put_pieces(rbx=cut, edi=cell) - the cut's parts that touch (shared
#   vertices) as pieces into the cell's result; pieces under 1e-12 of the
#   volume go
put_pieces:
    push    rbp
    mov     rbp, rsp
    push    r12
    push    r13
    push    r14
    push    r15
    sub     rsp, 112
    and     rsp, -16
    mov     [rsp], edi                  # +0 cell, +8 parents, +16 part of each
    mov     esi, [rbx+CX_NV]            #  root, +24 parts, +32 each part's first
    shl     rsi, 2                      #  (sorted), +40 polygons sorted, +48
    call    cx_alloc                    #  result, +56 its size, +64 write,
    test    rax, rax                    #  +72 local index, +80 volume, centre
    jz      .Lpp_out
    mov     [rsp+8], rax
    mov     rdi, rax
    xor     ecx, ecx
1:  cmp     ecx, [rbx+CX_NV]
    jae     2f
    mov     [rdi+rcx*4], ecx
    inc     ecx
    jmp     1b
2:  mov     r9, [rsp+8]                 # union by polygons
    mov     rsi, [rbx+CX_P]
    xor     ecx, ecx
3:  cmp     ecx, [rbx+CX_NP]
    jae     4f
    mov     r12d, [rsi+PR_FIRST]
    mov     r13d, [rsi+PR_CNT]
    add     r13d, r12d
    mov     rax, [rbx+CX_L]
    mov     r14d, [rax+r12*4]
31: inc     r12d
    cmp     r12d, r13d
    jae     32f
    mov     rax, [rbx+CX_L]
    mov     r11d, [rax+r12*4]
    mov     edi, r14d
    call    uf_join
    jmp     31b
32: add     rsi, PR_SZ
    inc     ecx
    jmp     3b
4:  mov     esi, [rbx+CX_NV]            # roots -> part numbers
    shl     rsi, 2
    call    cx_alloc
    test    rax, rax
    jz      .Lpp_out
    mov     [rsp+16], rax
    mov     rdi, rax
    mov     ecx, [rbx+CX_NV]
    mov     eax, -1
    rep     stosd
    xor     r12d, r12d                  # parts
    mov     r9, [rsp+8]
    mov     rsi, [rbx+CX_P]
    xor     ecx, ecx
5:  cmp     ecx, [rbx+CX_NP]
    jae     6f
    call    poly_root
    mov     rdx, [rsp+16]
    cmp     dword ptr [rdx+rax*4], -1
    jne     51f
    mov     [rdx+rax*4], r12d
    inc     r12d
51: add     rsi, PR_SZ
    inc     ecx
    jmp     5b
6:  mov     [rsp+24], r12d
    lea     esi, [r12+2]                # polygons by part (counting sort)
    shl     rsi, 2
    call    cx_alloc
    test    rax, rax
    jz      .Lpp_out
    mov     [rsp+32], rax
    mov     rdi, rax
    lea     ecx, [r12+2]
    xor     eax, eax
    rep     stosd
    mov     r9, [rsp+8]
    mov     rsi, [rbx+CX_P]
    xor     ecx, ecx
7:  cmp     ecx, [rbx+CX_NP]
    jae     8f
    call    poly_root
    mov     rdx, [rsp+16]
    mov     eax, [rdx+rax*4]
    mov     rdx, [rsp+32]
    inc     dword ptr [rdx+rax*4+4]
    add     rsi, PR_SZ
    inc     ecx
    jmp     7b
8:  mov     rdx, [rsp+32]               # prefix sums
    xor     ecx, ecx
81: cmp     ecx, r12d
    jae     82f
    mov     eax, [rdx+rcx*4]
    add     [rdx+rcx*4+4], eax
    inc     ecx
    jmp     81b
82: mov     esi, [rbx+CX_NP]            # the polygons' indices, sorted
    shl     rsi, 2
    call    cx_alloc
    test    rax, rax
    jz      .Lpp_out
    mov     [rsp+40], rax
    lea     esi, [r12+2]                # (a copy of the starts to fill by)
    shl     rsi, 2
    call    cx_alloc
    test    rax, rax
    jz      .Lpp_out
    mov     r13, rax
    mov     rdi, rax
    mov     rsi, [rsp+32]
    lea     ecx, [r12+1]
    rep     movsd
    mov     r9, [rsp+8]
    mov     rsi, [rbx+CX_P]
    xor     ecx, ecx
83: cmp     ecx, [rbx+CX_NP]
    jae     84f
    call    poly_root
    mov     rdx, [rsp+16]
    mov     eax, [rdx+rax*4]
    mov     edx, [r13+rax*4]
    inc     dword ptr [r13+rax*4]
    mov     rax, [rsp+40]
    mov     [rax+rdx*4], ecx
    add     rsi, PR_SZ
    inc     ecx
    jmp     83b
84: mov     eax, [rbx+CX_NV]            # the result: room for all
    imul    rsi, rax, 12
    mov     eax, [rbx+CX_NP]
    shl     rax, 3
    add     rsi, rax
    mov     eax, [rbx+CX_NL]
    shl     rax, 2
    add     rsi, rax
    imul    rax, r12, PH_SZ
    add     rsi, rax
    add     rsi, PP_HDR+64
    mov     [rsp+56], rsi
    call    sh_ralloc
    test    rax, rax
    jz      .Lpp_out
    mov     [rsp+48], rax
    mov     dword ptr [rax+PP_N], 0
    add     rax, PP_HDR
    mov     [rsp+64], rax
    mov     esi, [rbx+CX_NV]            # local indices (-1: not yet)
    shl     rsi, 2
    call    cx_alloc
    test    rax, rax
    jz      .Lpp_out
    mov     [rsp+72], rax
    mov     rdi, rax
    mov     ecx, [rbx+CX_NV]
    mov     eax, -1
    rep     stosd
    xor     r14d, r14d                  # each part
9:  cmp     r14d, [rsp+24]
    jae     .Lpp_done
    mov     rdx, [rsp+32]
    mov     r12d, [rdx+r14*4]           # its polygons: sorted r12 .. r13
    mov     r13d, [rdx+r14*4+4]
    mov     rdi, [rbx+CX_V]             # volume, centre
    mov     rsi, [rbx+CX_P]
    mov     rdx, [rbx+CX_L]
    mov     rcx, [rsp+40]
    lea     rcx, [rcx+r12*4]
    mov     r8d, r13d
    sub     r8d, r12d
    lea     r9, [rsp+80]
    call    poly_vc
    movsd   xmm0, [rsp+80]
    movsd   xmm1, [rip+sh_src_vol]
    andpd   xmm1, [rip+sd_absmask]
    mulsd   xmm1, [rip+sd_volr]
    comisd  xmm0, xmm1
    jbe     99f
    mov     r15, [rsp+64]               # its header
    movsd   [r15+PH_VOL], xmm0
    xor     ecx, ecx
90: movsd   xmm0, [rsp+88+rcx*8]
    movsd   [r15+PH_C+rcx*8], xmm0
    inc     ecx
    cmp     ecx, 3
    jb      90b
    mov     dword ptr [r15+PH_NV], 0
    mov     eax, r13d
    sub     eax, r12d
    mov     [r15+PH_NP], eax
    mov     dword ptr [r15+PH_NL], 0
    lea     r10, [r15+PH_SZ]            # vertices, in order of use
    mov     r11, [rsp+72]
    mov     ecx, r12d
91: cmp     ecx, r13d
    jae     92f
    mov     rax, [rsp+40]
    mov     esi, [rax+rcx*4]
    shl     rsi, 4
    add     rsi, [rbx+CX_P]
    mov     edx, [rsi+PR_FIRST]
    mov     r8d, [rsi+PR_CNT]
    add     [r15+PH_NL], r8d
    add     r8d, edx
911:cmp     edx, r8d
    jae     912f
    mov     rax, [rbx+CX_L]
    mov     edi, [rax+rdx*4]
    cmp     dword ptr [r11+rdi*4], -1
    jne     913f
    mov     eax, [r15+PH_NV]
    mov     [r11+rdi*4], eax
    inc     dword ptr [r15+PH_NV]
    imul    rdi, rdi, VX_SZ
    add     rdi, [rbx+CX_V]
    imul    rax, rax, 12
    push    rcx
    xor     ecx, ecx
914:movsd   xmm0, [rdi+rcx*8]
    subsd   xmm0, [r15+PH_C+rcx*8]
    cvtsd2ss xmm0, xmm0
    movss   [r10+rax], xmm0
    add     rax, 4
    inc     ecx
    cmp     ecx, 3
    jb      914b
    pop     rcx
913:inc     edx
    jmp     911b
912:inc     ecx
    jmp     91b
92: mov     eax, [r15+PH_NV]            # polygons: count, tag
    imul    rax, rax, 12
    lea     r10, [r15+PH_SZ+rax]
    mov     eax, [r15+PH_NP]
    lea     r9, [r10+rax*8]             # (then the loops)
    mov     ecx, r12d
93: cmp     ecx, r13d
    jae     94f
    mov     rax, [rsp+40]
    mov     esi, [rax+rcx*4]
    shl     rsi, 4
    add     rsi, [rbx+CX_P]
    mov     eax, [rsi+PR_CNT]
    mov     [r10], eax
    mov     eax, [rsi+PR_TAG]
    mov     [r10+4], eax
    add     r10, 8
    mov     edx, [rsi+PR_FIRST]
    mov     r8d, [rsi+PR_CNT]
    add     r8d, edx
931:cmp     edx, r8d
    jae     932f
    mov     rax, [rbx+CX_L]
    mov     edi, [rax+rdx*4]
    mov     eax, [r11+rdi*4]
    mov     [r9], eax
    add     r9, 4
    inc     edx
    jmp     931b
932:inc     ecx
    jmp     93b
94: mov     [rsp+64], r9
    mov     rax, [rsp+48]
    inc     dword ptr [rax+PP_N]
99: inc     r14d
    jmp     9b
.Lpp_done:
    mov     ecx, [rsp]
    shl     rcx, 4
    add     rcx, [rip+sh_res]
    mov     rax, [rsp+48]
    mov     [rcx], rax
    mov     rax, [rsp+56]
    mov     [rcx+8], rax
.Lpp_out:
    lea     rsp, [rbp-32]
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbp
    ret

# uf_root(edi=vertex, r9=parents) -> eax (halving the path)
uf_root:
    mov     eax, edi
1:  mov     edx, [r9+rax*4]
    cmp     edx, eax
    je      9f
    mov     r8d, [r9+rdx*4]
    mov     [r9+rax*4], r8d
    mov     eax, r8d
    jmp     1b
9:  ret

# uf_join(edi, r11d = vertices; r9 = parents)
uf_join:
    call    uf_root
    mov     r10d, eax
    mov     edi, r11d
    call    uf_root
    cmp     eax, r10d
    je      9f
    jb      1f
    mov     [r9+rax*4], r10d
    ret
1:  mov     [r9+r10*4], eax
9:  ret

# poly_root(rsi=polygon; rbx = cut, r9 = parents) -> eax = its first
#   vertex's root
poly_root:
    mov     eax, [rsi+PR_FIRST]
    mov     rdx, [rbx+CX_L]
    mov     edi, [rdx+rax*4]
    jmp     uf_root

# poly_vc(rdi=vertices, rsi=polygons, rdx=loops, rcx=polygon indices,
#   r8d=how many, r9=out: volume, centre (4 doubles)) - fans from each
#   polygon's first corner, tetrahedra from the first vertex
poly_vc:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    sub     rsp, 64
    mov     rbx, r9
    mov     r12, rsi
    mov     r13, rdx
    mov     r14, rcx
    mov     r15d, r8d
    xorpd   xmm0, xmm0
    movsd   [rsp+16], xmm0              # sums: 6 v, 6 v x (a + b + c - 3 o)
    movsd   [rsp+24], xmm0
    movsd   [rsp+32], xmm0
    movsd   [rsp+40], xmm0
    test    r15d, r15d
    jz      .Lvc_none
    mov     eax, [r14]                  # the origin
    shl     rax, 4
    mov     eax, [r12+rax+PR_FIRST]
    mov     eax, [r13+rax*4]
    imul    rax, rax, VX_SZ
    movsd   xmm13, [rdi+rax]
    movsd   xmm14, [rdi+rax+8]
    movsd   xmm15, [rdi+rax+16]
1:  test    r15d, r15d
    jz      5f
    mov     eax, [r14]
    shl     rax, 4
    add     rax, r12
    mov     r8d, [rax+PR_FIRST]
    mov     r9d, [rax+PR_CNT]
    lea     r9d, [r8+r9-1]              # the fan's last
    mov     ecx, [r13+r8*4]
    mov     [rsp], ecx
    lea     r10d, [r8+1]
2:  cmp     r10d, r9d
    jae     4f
    mov     ecx, [r13+r10*4]
    mov     [rsp+4], ecx
    mov     ecx, [r13+r10*4+4]
    mov     [rsp+8], ecx
    lea     rsi, [rsp]
    call    tet6
    movsd   xmm0, [rsp+16]
    addsd   xmm0, xmm10
    movsd   [rsp+16], xmm0
    xor     ecx, ecx                    # (a + b + c - 3 o) x 6 v, an axis
3:  xor     edx, edx                    #  at a time (the origin turned)
    xorpd   xmm1, xmm1
31: mov     eax, [rsp+rdx*4]
    imul    rax, rax, VX_SZ
    add     rax, rdi
    addsd   xmm1, [rax+rcx*8]
    subsd   xmm1, xmm13
    inc     edx
    cmp     edx, 3
    jb      31b
    mulsd   xmm1, xmm10
    addsd   xmm1, [rsp+24+rcx*8]
    movsd   [rsp+24+rcx*8], xmm1
    movsd   xmm2, xmm13
    movsd   xmm13, xmm14
    movsd   xmm14, xmm15
    movsd   xmm15, xmm2
    inc     ecx
    cmp     ecx, 3
    jb      3b
    inc     r10d
    jmp     2b
4:  add     r14, 4
    dec     r15d
    jmp     1b
5:  movsd   xmm0, [rsp+16]
    mulsd   xmm0, [rip+sd_sixth]
    movsd   [rbx], xmm0
    movsd   xmm0, [rsp+16]
    andpd   xmm0, [rip+sd_absmask]
    comisd  xmm0, [rip+sd_tiny]
    jbe     6f
    movsd   xmm0, [rsp+16]
    mulsd   xmm0, [rip+sd_four]
    movsd   xmm1, [rsp+24]
    divsd   xmm1, xmm0
    addsd   xmm1, xmm13
    movsd   [rbx+8], xmm1
    movsd   xmm1, [rsp+32]
    divsd   xmm1, xmm0
    addsd   xmm1, xmm14
    movsd   [rbx+16], xmm1
    movsd   xmm1, [rsp+40]
    divsd   xmm1, xmm0
    addsd   xmm1, xmm15
    movsd   [rbx+24], xmm1
    jmp     9f
6:  movsd   [rbx+8], xmm13
    movsd   [rbx+16], xmm14
    movsd   [rbx+24], xmm15
    jmp     9f
.Lvc_none:
    xorpd   xmm0, xmm0
    movsd   [rbx], xmm0
    movsd   [rbx+8], xmm0
    movsd   [rbx+16], xmm0
    movsd   [rbx+24], xmm0
9:  add     rsp, 64
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

.section .rodata
.align 8
sd_four:        .double 4.0
# the box's faces (corners: bit 0 x, 1 y, 2 z), counter-clockwise seen
#   from outside
box_quads:
    .long 0, 2, 3, 1                    # z-
    .long 4, 5, 7, 6                    # z+
    .long 0, 1, 5, 4                    # y-
    .long 2, 6, 7, 3                    # y+
    .long 0, 4, 6, 2                    # x-
    .long 1, 3, 7, 5                    # x+

.section .note.GNU-stack,"",@progbits
